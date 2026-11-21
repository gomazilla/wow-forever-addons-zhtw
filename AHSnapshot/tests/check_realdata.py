"""用真實存檔做模擬驗證（只讀，不寫入）：python -I -X utf8 tests/check_realdata.py [存檔路徑]
拿存檔裡最近一次快照（1.1 版逐筆格式）當期初上架，模擬一段 15 分鐘內發生的買賣，
比較新演算法的推估與模擬的正確答案。"""
import os, sys, random
from collections import defaultdict
from lupa import lua51

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, '..', 'AHSnapshot')
if len(sys.argv) > 1:
    SV = sys.argv[1]
else:
    import glob
    found = glob.glob(r'C:\Program Files (x86)\World of Warcraft\_forever_\WTF\Account\*\SavedVariables\AHSnapshot.lua')
    SV = found[0] if found else ''
if not SV or not os.path.exists(SV):
    print('找不到存檔，略過'); sys.exit(0)

L = lua51.LuaRuntime(unpack_returned_tuples=True)
with open(SV, encoding='utf-8') as f:
    L.execute(f.read())
for name in ('Core.lua', 'Share.lua'):
    with open(os.path.join(ADDON, name), encoding='utf-8') as f:
        L.execute(f.read())
G = L.globals()
db = G.AHSnapshotDB
ah = None
for k, v in db.realms.items():
    if v.prev:
        ah = v
if ah is None:
    print('存檔裡沒有快照，略過'); sys.exit(0)

# 讀出期初上架（1.1 版格式："數量:直購:起標:賣家;剩餘時間"）
items_db = db['items']
start = defaultdict(list)          # key -> [ [count, unit, tl], ... ]
owners = set()
for key, lst in ah.prev.items():
    vals = lst.values() if hasattr(lst, 'values') else []
    for e in vals:
        sig, _, tl = e.rpartition(';')
        c, b, _, owner = sig.split(':', 3)
        c, b = int(c), int(b)
        owners.add(owner)
        unit = -(-b // c) if b > 0 else 0
        # 1.1 版把原始值多加了 1（2～5），這裡還原成 1～4
        start[key].append([c, unit, max(1, min(4, int(tl) - 1)) if tl else 1])
n_list = sum(len(v) for v in start.values())


def stack_of(key):
    it = items_db[key] if key in items_db else None
    st = it.stack if it is not None else None
    if st:
        return st
    return 2 if any(c > 1 for c, _, _ in start[key]) else 1


print(f'期初：{len(start)} 種物品、{n_list} 筆上架；賣家名字種類：{sorted(owners)[:5]}')
stackables = [k for k in start if stack_of(k) > 1]
gear = [k for k in start if stack_of(k) == 1]
print(f'可堆疊 {len(stackables)} 種、不可堆疊 {len(gear)} 種')

rng = random.Random(42)
truth = defaultdict(lambda: {'sold': 0, 'cancel': 0, 'repost': 0, 'new': 0})
end = {k: [list(x) for x in v] for k, v in start.items()}

# 可堆疊：30% 物品被從最低價買走一部分；10% 有高價層撤單；10% 最低價那筆壓價重上；10% 新上架
for k in stackables:
    lst = sorted(end[k], key=lambda x: x[1])
    buyable = [x for x in lst if x[1] > 0]
    if buyable and rng.random() < 0.3:
        total = sum(x[0] for x in buyable)
        want = max(1, int(total * rng.uniform(0.02, 0.3)))
        for x in buyable:
            if want <= 0:
                break
            take = min(x[0], want)
            x[0] -= take; want -= take
            truth[k]['sold'] += take
    lst = [x for x in lst if x[0] > 0]
    buyable = [x for x in lst if x[1] > 0]
    if len(buyable) >= 3 and rng.random() < 0.1:
        x = buyable[-1]                          # 最貴的撤單
        truth[k]['cancel'] += x[0]; lst.remove(x)
    buyable = [x for x in lst if x[1] > 0]
    if buyable and rng.random() < 0.1:
        x = buyable[0]                           # 最便宜那筆撤下、便宜 1 銅重上
        if x[1] > 1:
            lst.remove(x); lst.append([x[0], x[1] - 1, 4]); truth[k]['repost'] += x[0]
    if lst and rng.random() < 0.1:
        mx = max(x[1] for x in lst)
        c = rng.randint(1, 20); lst.append([c, mx + 5, 4]); truth[k]['new'] += c
    end[k] = lst

# 不可堆疊：20% 賣掉一件；5% 撤單一件（演算法分不出來，會算成賣出）
for k in gear:
    lst = end[k]
    b = [x for x in lst if x[1] > 0]
    if b and rng.random() < 0.2:
        x = rng.choice(b); lst.remove(x); truth[k]['sold'] += 1
    b = [x for x in lst if x[1] > 0]
    if b and rng.random() < 0.05:
        x = rng.choice(b); lst.remove(x); truth[k]['cancel'] += 1

# 跑插件的 ProcessScan（新快照從期初建立）
L.execute('sim = {}; simItems = {}')
sim_items = G.simItems
for k in start:
    t = L.table()
    t.stack = stack_of(k)
    sim_items[k] = t


def to_lua(listmap):
    out = L.table()
    i = 1
    for k, lst in listmap.items():
        for c, unit, tl in lst:
            if c <= 0:
                continue
            e = L.table(); e.key = k; e.count = c; e.buyout = c * unit; e.minBid = 1; e.tl = tl
            out[i] = e; i += 1
    return out


G.L1, G.L2 = to_lua(start), to_lua(end)
L.execute('''
  s1 = AHSnapshot.ProcessScan(sim, L1, 100000, "z", true, simItems)
  s2 = AHSnapshot.ProcessScan(sim, L2, 100900, "z", true, simItems)
''')
est = defaultdict(lambda: {'sold': 0, 'soldN': 0, 'expired': 0, 'repost': 0, 'new': 0})
for k, row in G.s2['items'].items():
    f = G.AHSnapshot.ParseRow(row)
    for fld in ('sold', 'soldN', 'expired', 'repost', 'new'):
        est[k][fld] += f[fld]


def total(keys, src, fld):
    return sum(src[k][fld] for k in keys)


for label, keys in (('可堆疊', stackables), ('不可堆疊', gear)):
    print(f'\n== {label} ==')
    print(f"  正確答案：賣出 {total(keys, truth, 'sold')}、撤單 {total(keys, truth, 'cancel')}、"
          f"壓價重上 {total(keys, truth, 'repost')}、新上架 {total(keys, truth, 'new')}")
    print(f"  推估結果：賣出 {total(keys, est, 'sold')}（{total(keys, est, 'soldN')} 筆）、可能到期 {total(keys, est, 'expired')}、"
          f"撤單/重上 {total(keys, est, 'repost')}、新上架 {total(keys, est, 'new')}")
    over = [(k, truth[k]['sold'], est[k]['sold']) for k in keys if est[k]['sold'] > truth[k]['sold']]
    print(f'  推估比正確答案多的物品：{len(over)} 種', over[:5])
    under = sum(1 for k in keys if est[k]['sold'] < truth[k]['sold'])
    print(f'  推估比正確答案少的物品：{under} 種（多半是剩餘時間 30 分內的上架，被保守算成可能到期）')

# 舊演算法在同樣情境的結果（全部賣家都是 "?"，逐筆指紋比對）
old_sold = 0
for k in start:
    a = defaultdict(int)
    for c, u, tl in start[k]:
        a[(c, u)] += 1
    b = defaultdict(int)
    for c, u, tl in end[k]:
        if c > 0:
            b[(c, u)] += 1
    for sig, n in a.items():
        gone = n - min(n, b.get(sig, 0))
        old_sold += gone * sig[0]
print(f'\n對照：舊演算法（逐筆指紋）在同一情境會推估賣出約 {old_sold}（含撤單、部分購買整筆、壓價重上）')


# ---- 1.3.1 拍賣場分聯盟／部落／中立：用真實存檔模擬登入時的搬家（只在記憶體裡做，不寫檔）----
def ah_counts(title):
    print(title)
    L.execute('''
      cnt = {}
      for k, ah in pairs(AHSnapshotDB.realms or {}) do
        local d = 0
        for _ in pairs(ah.daily or {}) do d = d + 1 end
        cnt[#cnt + 1] = string.format("  自己 %-14s 逐次掃描 %3d 次、每日紀錄 %2d 天", k, #(ah.scans or {}), d)
      end
      for src, sh in pairs(AHSnapshotDB.shared or {}) do
        for k, ah in pairs(sh) do
          cnt[#cnt + 1] = string.format("  朋友 %-6s %-14s 逐次掃描 %3d 次", src, k, #(ah.scans or {}))
        end
      end
      table.sort(cnt)
    ''')
    for line in G.cnt.values():
        print(line)


print('\n== 1.3.1 拍賣場搬家模擬 ==')
ah_counts('搬家前：')
L.execute('''
  before = AHSnapshot.CollectSources(AHSnapshotDB, "PvE Alliance", true)
  report = AHSnapshot.MigrateToV5(AHSnapshotDB, "PvE")
  -- 存檔裡還沒匯入的 inbox（同步工具寫進來、下次登入才讀）也照新規則匯入
  inboxAdded = {}
  if type(AHSnapshotInbox) == "string" and AHSnapshotInbox ~= "" then
    inboxAdded = AHSnapshot.ImportInbox(AHSnapshotDB, AHSnapshotInbox, GetServerTimeSim or 0, nil)
  end
  after = AHSnapshot.CollectSources(AHSnapshotDB, "PvE Alliance", true)
''')
rep = []
if G.report:
    for old, dst in G.report.items():
        for k, n in dst.items():
            rep.append(f'{old} → {k} {n} 次')
print('搬家報告：', '、'.join(rep) or '（沒有要搬的）')
print('inbox 匯入：', dict(G.inboxAdded.items()) if G.inboxAdded else '（沒有）')
ah_counts('搬家後：')
srcs = lambda x: [f"{(x[i].source or '自己')} {len(list(x[i].scans.values()))} 次" for i in range(1, len(x) + 1)]
print('搬家前 CollectSources("PvE Alliance")：', srcs(G.before))
print('搬家後 CollectSources("PvE Alliance")：', srcs(G.after))
names = {G.after[i].source for i in range(1, len(G.after) + 1)}
ok = None in names and len(names) >= 3
print('結果：' + ('自己＋朋友都在同一個拍賣場 ✔' if ok else '還是對不上 ✘'))
L.execute('klist = AHSnapshot.ListAHKeys(AHSnapshotDB)')
print('視窗可切換的拍賣場：', [G.AHSnapshot.AHKeyLabel(k) for k in G.klist.values()])
