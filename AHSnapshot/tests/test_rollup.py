"""每日彙整、精簡格式、物品名稱查詢的離線測試：python -I -X utf8 tests/test_rollup.py"""
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
S = L.globals().AHSnapshot
G = L.globals()

# ---- 去尾端 0 ----
check('TrimRow 去尾端 0', S.TrimRow('20,1,100,100,100,0,0,0,20,0,0'), '20,1,100,100,100,0,0,0,20')
check('TrimRow 全 0 留一欄', S.TrimRow('0,0,0'), '0')
check('TrimRow 中間的 0 保留', S.TrimRow('0,0,0,0,0,10,1,0,0,0,5000'), '0,0,0,0,0,10,1,0,0,0,5000')
L.execute('f = AHSnapshot.ParseRow("5,1,10,10,10")')
check('短列讀起來缺的當 0', (G.f.qty, G.f.med, G.f.sold, G.f.soldValue), (5, 10, 0, 0))

# ---- 物品資料精簡存放 ----
L.execute(r'''
  its = { ["1"] = { name = "怪^名~字%", q = 2, sell = 100, cls = 4, sub = 2, stack = 1 },
          ["2"] = { name = "沒收購價", q = 1 } }
  AHSnapshot.PackItems(its)
  packed1, packed2 = its["1"], its["2"]
  AHSnapshot.UnpackItems(its)
''')
check('打包成一行字串', type(G.packed1) is str and '^' in G.packed1, True)
check('展開後內容一樣', (G.its['1'].name, G.its['1'].q, G.its['1'].sell, G.its['1'].cls, G.its['1'].sub, G.its['1'].stack),
      ('怪^名~字%', 2, 100, 4, 2, 1))
check('缺的欄位是 nil', (G.its['2'].name, G.its['2'].q, G.its['2'].sell, G.its['2'].stack), ('沒收購價', 1, None, None))
check('打包比表格短', len(G.packed1.encode()) < 40, True)

# ---- 每日彙整：先合併再濃縮 ----
# 台灣時間（+8h）。今天＝第 20000 天，逐次掃描除了今天再保留 3 整天 → 第 19996 天（含）以前要濃縮
OFF = 8 * 3600
L.execute(rf'''
  OFF = {OFF}
  DAY = function(d, h) return d * 86400 - OFF + h * 3600 end   -- 台灣時間第 d 天 h 點
  NOW = DAY(20000, 12)
  local function sc(t, gap, items) return {{ t = t, gap = gap, diff = gap and 1 or 0, n = 1, items = items }} end
  db = {{ realms = {{ PvE = {{ scans = {{
      sc(DAY(19995, 10), nil,  {{ ["1"] = "10,1,100,100,100" }}),
      sc(DAY(19995, 11), 3600, {{ ["1"] = "6,1,100,100,100,4,1,0,0,0,400" }}),   -- 自己 10:00～11:00 賣出 4
      sc(DAY(19999, 10), 3600, {{ ["1"] = "5,1,90,90,90,1,1,0,0,0,90" }}),       -- 最近：保留
    }} }} }}, items = {{}},
    shared = {{ ["小美"] = {{ PvE = {{ seen = {{}}, scans = {{
      sc(DAY(19995, 10.5), 1800, {{ ["1"] = "8,1,100,100,100,2,1,0,0,0,200" }}),  -- 和自己的區間重疊
      sc(DAY(19996, 9), 3600, {{ ["1"] = "7,1,80,80,80,3,1,0,0,0,240", ["2"] = "1,1,5,5,5" }}),
    }} }} }} }} }}
  added, removed = AHSnapshot.RollupOld(db, "PvE", NOW, 3, 30, OFF)
  ah = db.realms.PvE
  d95, d96 = ah.daily[19995], ah.daily[19996]
  p95 = AHSnapshot.ParseDaily(d95.items["1"])
  p96 = AHSnapshot.ParseDaily(d96.items["1"])
''')
check('濃縮 2 天、刪掉 4 次掃描', (G.added, G.removed), (2, 4))
check('最近的掃描保留', (len(G.ah.scans), G.ah.scans[1].t), (1, L.eval('DAY(19999, 10)')))
check('朋友的舊掃描也刪了', len(G.db.shared['小美'].PvE.scans) if G.db.shared['小美'] else 0, 0)
# 重疊的兩個區間只取一個（間隔短的：小美的 30 分鐘，賣出 2），不是 4+2
check('重疊區間不重複計算', (G.p95.sold, G.p95.soldValue, G.d95.o), (2, 200, 1800))
check('每日最低價／最大架上量', (G.p95.min, G.p95.maxQty, G.p95.n), (100, 10, 3))
check('第二天', (G.p96.sold, G.p96.min, G.d96.o), (3, 80, 3600))
check('每日紀錄記下那天開始時間', G.d95.t0, L.eval('DAY(19995, 0)'))
check('記下已濃縮到哪', G.ah.rolledBefore, L.eval('DAY(19997, 0)'))

# 晚到的朋友資料：落在已濃縮的時段 → 丟掉；之後的 → 收
L.execute(r'''
  late = "V^1^小美^1~S^PvE^" .. DAY(19995, 15) .. "^3600^1^1^1^^1^2~R^1^1,1,1,1,1,9,1~S^PvE^" .. DAY(19998, 9) .. "^3600^1^1^1^^1^2~R^1^1,1,1,1,1,1,1"
  lateAdded = AHSnapshot.ImportInbox(db, late, NOW, nil)
''')
check('已濃縮時段的晚到資料丟掉', G.lateAdded['小美'], 1)
check('沒有重複濃縮', L.eval('AHSnapshot.RollupOld(db, "PvE", NOW, 3, 30, OFF)')[0], 0)

# ---- 分析：每日紀錄＋逐次掃描 ----
L.execute(r'''
  srcs = AHSnapshot.CollectSources(db, "PvE", true)
  list7, cov7, nd7, ns7, ndays7 = AHSnapshot.Analyze(srcs, NOW, 7, {})
  list1, cov1, nd1, ns1, ndays1 = AHSnapshot.Analyze(srcs, NOW, 3, {})
  function find(list, key) for _, r in ipairs(list) do if r.key == key then return r end end end
  r7, r1 = find(list7, "1"), find(list1, "1")
  srcsOwn = AHSnapshot.CollectSources(db, "PvE", false)
  hist = AHSnapshot.History(srcsOwn, "1", 10)
''')
# 7 天：每日 2 + 3，逐次：自己 1 + 小美晚到的 1（19998 天）
check('7 天含每日紀錄', (G.r7.sold, G.ndays7), (2 + 3 + 1 + 1, 2))
check('7 天觀察時間含每日', G.cov7, 1800 + 3600 + 3600 + 3600)
check('3 天不含 4 天前的每日紀錄', (G.r1.sold, G.ndays1), (2, 0))
check('架上量看最新逐次掃描', G.r7.qty, 5)
check('中位價漲跌從最舊的每日算起', round(G.r7.trend, 2), round((90 - 100) / 100, 2))
check('明細：逐次在前、每日在後', [ (h.daily or False) for h in G.hist.values()], [False, True, True])
check('明細的每日列', (G.hist[2].qty, G.hist[2].min, G.hist[2].sold), (7, 80, 3))
check('不含朋友時每日紀錄照樣帶上', G.srcsOwn.daily is not None, True)

# ---- 每日紀錄保留天數 ----
L.execute('AHSnapshot.RollupOld(db, "PvE", NOW + 30 * 86400, 3, 30, OFF)')
check('超過保留天數的每日紀錄刪掉', L.eval('db.realms.PvE.daily[19995] == nil and db.realms.PvE.daily[19996] == nil'), True)

# ---- 匯出：一般物品不寫名稱 ----
L.execute(r'''
  dbE = { realms = { PvE = { scans = { { t = 100, gap = 60, diff = 1, n = 1, est = 2,
    items = { ["15"] = "1,1,5,5,5,0,0,0,0,0,0", ["15211:-19"] = "1,1,9,9,9" } } } } },
    items = { ["15"] = { name = "甲" }, ["15211:-19"] = { name = "猴之劍" } } }
  outE = AHSnapshot.ExportOutbox(dbE, 200, 3)
''')
check('一般物品沒有 I 紀錄', 'I^15^' in G.outE, False)
check('有後綴的物品保留名稱', 'I^15211:-19^猴之劍' in G.outE, True)
check('匯出的列去尾端 0', 'R^15^1,1,5,5,5~' in G.outE + '~', True)

# ---- 第 4 版升級 ----
L.execute(r'''
  dbV = { version = 3, keepDays = 60, shareKeepDays = 30, outboxDays = 14,
    realms = { PvE = { scans = { { t = 1, items = { ["1"] = "1,1,1,1,1,0,0,0,0,0,0" } } } } },
    shared = { ["阿明"] = { PvE = { scans = { { t = 1, items = { ["1"] = "2,1,1,1,1,0,0,0,0,0,0" } } } } } } }
  didV4 = AHSnapshot.MigrateToV4(dbV)
  again = AHSnapshot.MigrateToV4(dbV)
''')
check('升級到第 4 版只做一次', (G.didV4, G.again, G.dbV.version), (True, False, 4))
check('升級時舊列去尾端 0', (G.dbV.realms.PvE.scans[1]['items']['1'], G.dbV.shared['阿明'].PvE.scans[1]['items']['1']),
      ('1,1,1,1,1', '2,1,1,1,1'))
check('舊保留天數設定作廢', (G.dbV.keepDays, G.dbV.shareKeepDays, G.dbV.outboxDays), (None, None, None))

# ---- 遊戲端：登入升級、登出打包、查朋友物品名稱 ----
sys.path.insert(0, HERE)
src = open(os.path.join(HERE, 'test_core.py'), encoding='utf-8').read()
MOCKS = src.split("MOCKS = r'''", 1)[1].split("'''", 1)[0]
L2 = new_lua()
L2.execute(MOCKS)
L2.execute(r'''
  Auctionator.Variables = { GetConnectedRealmRoot = function() return "PvE" end }
  -- 伺服器還沒給資料的物品：第一次查不到，收到 GET_ITEM_INFO_RECEIVED 後才查得到
  known = { [2589] = true }
  C_Item.GetItemInfo = function(id)
    if not known[id] then return nil end
    return "物品"..id, nil, 1, 10, 1, "x", "y", 20, "", nil, 25, 7, 5
  end
  AHSnapshotDB = { version = 3, keepDays = 60, realms = { PvE = { scans = {
      { t = clock - 600, n = 1, items = { ["2589"] = "20,1,100,100,100,0,0,0,0,0,0" } } } } },
    items = { ["2589"] = { name = "亞麻布", q = 1, sell = 25, stack = 20 } } }
  AHSnapshotInbox = "V^1^小美^1~S^PvE^" .. (clock - 300) .. "^300^1^1^1^^1^2~R^4306^5,1,10,10,10,1,1"
''')
with open(os.path.join(ADDON, 'Main.lua'), encoding='utf-8') as f:
    L2.execute(f.read())
L2.execute(r'''
  fire_event("PLAYER_LOGIN")
  db = AHSnapshotDB
  v = db.version
  row = db.realms.PvE.scans[1].items["2589"]
  run_afters()        -- 5 秒後開始查朋友物品名稱
  tick()
  before = db.items["4306"] and db.items["4306"].name
  known[4306] = true
  fire_event("GET_ITEM_INFO_RECEIVED", 4306, true)
  after = db.items["4306"] and db.items["4306"].name
  fire_event("PLAYER_LOGOUT")
  packedType = type(db.items["2589"])
  outbox = AHSnapshotOutbox
  fire_event("PLAYER_LOGIN")   -- /reload 後重新登入
  unpackedName = db.items["2589"].name
''')
msgs = list(L2.globals().printed.values())
G2 = L2.globals()
check('登入時升級到第 4 版', (G2.v, G2.row), (4, '20,1,100,100,100'))
check('升級有提示一次', sum('存檔格式更新' in m for m in msgs), 1)
check('預設保留天數', (G2.db.detailDays, G2.db.dailyDays, G2.db.keepDays), (3, 30, None))
check('朋友物品先查不到', G2.before, None)
check('伺服器回應後補上名稱', G2.after, '物品4306')
check('登出時物品資料打包成字串', G2.packedType, 'string')
check('分享檔不含一般物品名稱', ('I^2589^' in G2.outbox, 'R^2589^20,1,100,100,100' in G2.outbox), (False, True))
check('重新登入後展開', G2.unpackedName, '亞麻布')
check('全程沒有錯誤', (any('失敗' in m for m in msgs), G2.db.lastError), (False, None))

print('全部通過' if fails == 0 else f'{fails} 項失敗')
sys.exit(1 if fails else 0)
