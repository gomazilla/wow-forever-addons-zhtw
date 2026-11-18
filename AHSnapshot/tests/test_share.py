"""AH Snapshot 共享功能離線測試：python -I -X utf8 tests/test_share.py"""
import os, sys
from lupa import lua51

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, '..', 'AHSnapshot')
fails = 0


def new_lua():
    L = lua51.LuaRuntime(unpack_returned_tuples=True)
    for name in ('Core.lua', 'Share.lua'):
        with open(os.path.join(ADDON, name), encoding='utf-8') as f:
            L.execute(f.read())
    return L


def check(name, got, want):
    global fails
    ok = got == want
    if not ok:
        fails += 1
    print(('OK  ' if ok else 'FAIL'), name, '' if ok else f'got={got!r} want={want!r}')


L = new_lua()
G = L.globals()
S = G.AHSnapshot

# ---- 轉義 ----
nasty = '名稱"引號\\反斜線^欄~列%百分比\n換行'
enc = S.Enc(nasty)
check('轉義後沒有危險字元', any(c in enc for c in '"\\^~\n'), False)
check('轉義來回一致', S.Dec(enc), nasty)
check('一般中文不轉義', S.Enc('亞麻布'), '亞麻布')

# ---- 匯出 / 匯入 來回 ----
L.execute(r'''
  NOW = 2000000000
  dbA = {
    realms = { PvE = { scans = {
      { t = NOW - 20 * 86400, gap = 1800, diff = 1, tl = 1, n = 9, zone = "舊", items = { ["1"] = "1,1,1,1,1,0,0,0,0,0,0" } },
      { t = NOW - 7200, diff = 0, tl = 1, n = 3, est = 2, zone = "貿易區", items = { ["2589"] = "20,1,100,100,100,0,0,0,0,0,0" } },
      { t = NOW - 3600, gap = 3600, diff = 1, tl = 1, n = 2, est = 2, zone = "貿易區",
        items = { ["2589"] = "10,1,90,90,90,10,1,0,0,0,1000", ["15211:-19"] = "1,1,5000,5000,5000,0,0,0,0,1,0" } },
    } } },
    items = { ["2589"] = { name = "亞麻布", q = 1, sell = 10, cls = 7, sub = 5, stack = 20 },
              ["15211:-19"] = { name = '怪"名^字~\\', q = 2 } },
  }
  out = AHSnapshot.ExportOutbox(dbA, NOW, 14)
  -- 同步工具上傳時填來源名字
  outNamed = out:gsub("^V%^1%^%^", "V^1^阿明^")
''')
out = G.out
check('outbox 沒有雙引號/反斜線/換行', any(c in out for c in '"\\\n\r'), False)
check('只匯出 14 天內', '舊' in out, False)
check('開頭是版本列', out.startswith('V^1^^'), True)

L.execute(r'''
  dbB = { realms = {}, items = { ["2589"] = { name = "已有名稱", sell = 10 } } }
  added1, newItems1 = AHSnapshot.ImportInbox(dbB, outNamed, NOW, 30)
  added2 = AHSnapshot.ImportInbox(dbB, outNamed, NOW, 30)
  shB = dbB.shared["阿明"].PvE
  n_after = #shB.scans
''')
check('匯入 2 次掃描', G.added1['阿明'], 2)
check('再匯入一次不重複', (G.added2['阿明'], G.n_after), (None, 2))
check('掃描依時間排序', G.shB.scans[1].t < G.shB.scans[2].t, True)
check('價量列原樣保留', G.shB.scans[2]['items']['2589'], '10,1,90,90,90,10,1,0,0,0,1000')
check('掃描欄位', (G.shB.scans[2].gap, G.shB.scans[2].diff, G.shB.scans[2].zone, G.shB.scans[2].nItems), (3600, 1, '貿易區', 2))
check('特殊字元名稱還原', G.dbB['items']['15211:-19'].name, '怪"名^字~\\')
check('已有的物品名稱不覆蓋', G.dbB['items']['2589'].name, '已有名稱')
check('新物品數', G.newItems1, 1)
check('沒有 prev/賣家資料', G.shB.prev, None)

# 舊演算法的推估不分享、不匯入
L.execute(r'''
  dbOld = { realms = { PvE = { scans = {
    { t = NOW - 600, gap = 600, diff = 1, n = 1, items = { ["1"] = "5,1,10,10,10,3,1,2,1,4,30" } } } } }, items = {} }
  oldOut = AHSnapshot.ExportOutbox(dbOld, NOW, 14)
  dbOldIn = { realms = {}, items = {} }
  AHSnapshot.ImportInbox(dbOldIn, (oldOut:gsub("^V%^1%^%^", "V^1^老王^")), NOW, 30)
  oldSc = dbOldIn.shared["老王"].PvE.scans[1]
  -- 舊版插件送來的（S 只有 9 欄、沒有推估版本）
  dbOldIn2 = { realms = {}, items = {} }
  AHSnapshot.ImportInbox(dbOldIn2, "V^1^舊插件^1~S^PvE^" .. (NOW - 60) .. "^600^1^1^1^^1~R^1^5,1,10,10,10,3,1,0,0,0,30", NOW, 30)
  oldSc2 = dbOldIn2.shared["舊插件"].PvE.scans[1]
''')
check('舊推估匯出時歸零、不比對', ('^1~R^1^5,1,10,10,10,0,0,0,0,0,0' in G.oldOut, '^600^0^' in G.oldOut), (True, True))
check('匯入後價格保留、推估為 0', (G.oldSc['items']['1'], G.oldSc.diff), ('5,1,10,10,10,0,0,0,0,0,0', 0))
check('沒有推估版本的資料只收價格', (G.oldSc2['items']['1'], G.oldSc2.diff, G.oldSc2.clearEst), ('5,1,10,10,10,0,0,0,0,0,0', 0, None))

# 多人接在一起、不認得的類型、壞資料
L.execute(r'''
  dbC = { realms = {}, items = {} }
  inbox = table.concat({
    "V^1^小美^" .. NOW,
    "S^PvE^" .. (NOW - 600) .. "^600^1^1^5^貿易區^1",
    "R^2589^5,1,95,95,95,3,1,0,0,0,300",
    "R^2592^不是數字",
    "D^PvE^12345^2589^未來的每日格式",
    "X^什麼都不是",
    "V^2^阿明^" .. NOW,
    "S^PvE^" .. (NOW - 300) .. "^^0^1^5^^1",
    "R^2589^7,1,99,99,99,0,0,0,0,0,0",
    "S^PvE^" .. (NOW - 40 * 86400) .. "^600^1^1^5^^1",
    "R^2589^1,1,1,1,1,0,0,0,0,0,0",
  }, "~")
  addedC = AHSnapshot.ImportInbox(dbC, inbox, NOW, 30)
  meiRows = 0
  for _ in pairs(dbC.shared["小美"].PvE.scans[1].items) do meiRows = meiRows + 1 end
''')
check('兩個來源', (G.addedC['小美'], G.addedC['阿明']), (1, 1))
check('壞的 R 列丟掉、未知類型略過', G.meiRows, 1)
check('超過保留天數不匯入', len(G.dbC.shared['阿明'].PvE.scans), 1)

# 修剪
L.execute(r'''
  removed = AHSnapshot.PruneShared(dbC, NOW + 31 * 86400, 30)
  gone = dbC.shared["小美"]
''')
check('修剪移除過期與空來源', (G.removed, G.gone), (2, None))

# ---- 合併分析：重疊區間只算一次 ----
L.execute(r'''
  local function sc(t, gap, sold, val, qty, med)
    return { t = t, gap = gap, diff = gap and 1 or 0,
      items = { ["1"] = string.format("%d,1,%d,%d,%d,%d,1,0,0,0,%d", qty, med, med, med, sold, val) } }
  end
  own = { scans = { sc(10000, nil, 0, 0, 50, 100), sc(13600, 3600, 10, 1000, 40, 100), sc(17200, 3600, 6, 600, 34, 100) } }
  -- 朋友在自己第一段 [10000,13600] 中間掃了一段 [11000,12000]（間隔短，優先），還有一段沒人覆蓋的 [20000,21000]
  friend = { scans = { sc(11000, nil, 0, 0, 45, 110), sc(12000, 1000, 4, 440, 41, 110), sc(20000, nil, 0, 0, 30, 120), sc(21000, 1000, 2, 240, 28, 120) } }
  srcs = { { source = nil, scans = own.scans }, { source = "小美", scans = friend.scans } }
  picked = AHSnapshot.PickIntervals(srcs, 0, 8 * 3600)
  pickOwn1, pickOwn2, pickF1, pickF2 = picked[own.scans[2]], picked[own.scans[3]], picked[friend.scans[2]], picked[friend.scans[4]]
  listAll, covAll, nAll, srcAll = AHSnapshot.Analyze(srcs, 21000, 7, {})
  listOwn, covOwn, nOwn, srcOwn = AHSnapshot.Analyze(own, 21000, 7, {})
  hist = AHSnapshot.History(srcs, "1", 3)
''')
check('重疊時選間隔短的朋友區間', (G.pickF1, G.pickOwn1), (True, None))
check('不重疊的都選', (G.pickOwn2, G.pickF2), (True, True))
a = G.listAll[1]
check('合併賣出＝4+6+2（不重複算自己的 10）', a.sold, 12)
check('合併觀察時間只算被選的', (G.covAll, G.nAll, G.srcAll), (1000 + 3600 + 1000, 3, 2))
check('架上量用所有來源中最新一次', (a.qty, a.med), (28, 120))
check('只看自己', (G.listOwn[1].sold, G.covOwn, G.srcOwn), (16, 7200, 1))
check('明細標出來源（新到舊）', (G.hist[1].source, G.hist[2].source, G.hist[3].source), ('小美', '小美', None))

# CollectSources
L.execute(r'''
  dbD = { realms = { PvE = own }, shared = { ["小美"] = { PvE = friend, Other = { scans = {} } }, ["阿明"] = { Other = { scans = { {t=1, items={}} } } } } }
  s1 = AHSnapshot.CollectSources(dbD, "PvE", true)
  s0 = AHSnapshot.CollectSources(dbD, "PvE", false)
''')
check('CollectSources 只收同拍賣場有資料的', (len(G.s1), G.s1[2].source, len(G.s0)), (2, '小美', 1))

# ---- 每日彙整 ----
L.execute(r'''
  local function sc(t, gap, row) return { t = t, gap = gap, diff = gap and 1 or 0, items = { ["1"] = row } } end
  -- 台灣時間（+8h）：第一天 23:00、第二天 00:30 / 01:30
  local base = 19000 * 86400 - 8 * 3600   -- 台灣時間第 19000 天 00:00
  ds = { scans = {
    sc(base - 3600, nil, "10,2,100,100,120,0,0,0,0,0,0"),
    sc(base + 1800, 5400, "8,2,90,95,110,2,1,1,0,0,200"),
    sc(base + 5400, 3600, "5,1,80,85,100,3,2,0,0,0,240"),
    sc(base + 5400 + 40000, 40000, "5,1,70,70,70,9,1,0,0,0,900"),  -- 間隔太久：不累計
  } }
  daily = AHSnapshot.RollupDaily(ds, 8 * 3600)
  d0, d1 = daily[18999], daily[19000]
  it1 = d1.items["1"]
''')
check('分到兩天', (G.d0 is not None, G.d0.scans, G.d1.scans), (True, 1, 3))
check('第一天沒有比對', (G.d0.observed, G.d0['items']['1'].sold), (0, 0))
check('第二天最低價／最大架上量', (G.it1.min, G.it1.maxQty), (70, 8))
check('第二天中位價平均', G.it1.medAvg, round((110 + 100 + 70) / 3))
check('第二天賣出（排除太久的間隔）', (G.it1.sold, G.it1.soldValue, G.it1.expired), (5, 440, 1))
check('第二天觀察秒數', G.d1.observed, 5400 + 3600)

print('全部通過' if fails == 0 else f'{fails} 項失敗')
sys.exit(1 if fails else 0)
