"""拍賣場鍵（聯盟／部落／中立）與搬家的離線測試：python -I -X utf8 tests/test_ahkey.py"""
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


def lt(*xs):
    t = L.table()
    for i, x in enumerate(xs, 1):
        t[i] = x
    return t


# ---- 目前位置的鍵 ----
check('聯盟主城', S.MakeAHKey('PvE', 'Alliance', lt('貿易區', '暴風城')), 'PvE Alliance')
check('部落主城', S.MakeAHKey('PvE', 'Horde', lt('力量谷', '奧格瑪')), 'PvE Horde')
check('藏寶海灣（子區域）→ 中立', S.MakeAHKey('PvE', 'Alliance', lt('藏寶海灣', '荊棘谷')), 'PvE Neutral')
check('加基森（區域在後面）→ 中立', S.MakeAHKey('PvE', 'Horde', lt('', '加基森')), 'PvE Neutral')
check('永望鎮 → 中立', S.MakeAHKey('PvE', 'Horde', lt('永望鎮')), 'PvE Neutral')
check('英文地名也認得', S.MakeAHKey('PvE', 'Alliance', lt('Booty Bay')), 'PvE Neutral')
check('一般地點跟角色陣營', S.MakeAHKey('PvE', 'Alliance', lt('某個小鎮')), 'PvE Alliance')

# ---- 拆鍵 ----
check('拆新鍵', S.SplitAHKey('PvE Alliance'), ('PvE', 'Alliance', False))
check('拆 1.0 鍵', S.SplitAHKey('CAMWOW TW4 Realm 1 PvE|Horde'), ('CAMWOW TW4 Realm 1 PvE', 'Horde', True))
check('沒陣營', S.SplitAHKey('PvE'), ('PvE', None, False))
check('伺服器名有空白但沒陣營', S.SplitAHKey('Some Realm'), ('Some Realm', None, False))

# ---- 正規化（舊鍵、朋友舊版的鍵）----
check('1.3.0 的 PvE＋貿易區 → 聯盟', S.NormalizeAHKey('PvE', '貿易區'), 'PvE Alliance')
check('PvE＋鐵爐堡 → 聯盟', S.NormalizeAHKey('PvE', '鐵爐堡'), 'PvE Alliance')
check('PvE＋幽暗城 → 部落', S.NormalizeAHKey('PvE', '幽暗城'), 'PvE Horde')
check('PvE＋藏寶海灣 → 中立', S.NormalizeAHKey('PvE', '藏寶海灣'), 'PvE Neutral')
check('舊式 Auctionator 在藏寶海灣記成聯盟 → 中立', S.NormalizeAHKey('PvE Alliance', '藏寶海灣'), 'PvE Neutral')
check('有陣營的鍵照用', S.NormalizeAHKey('PvE Horde', '某個小鎮'), 'PvE Horde')
check('有陣營、沒地點', S.NormalizeAHKey('PvE Alliance', None), 'PvE Alliance')
check('認不出來 → nil（保留原鍵）', S.NormalizeAHKey('PvE', '某個小鎮'), None)
check('沒地點也沒陣營 → nil', S.NormalizeAHKey('PvE', ''), None)
check('1.0 鍵換成現在的規則名', S.NormalizeAHKey('CAMWOW TW4 Realm 1 PvE|Alliance', None, 'PvE'), 'PvE Alliance')
check('顯示名稱', (S.AHKeyLabel('PvE Alliance'), S.AHKeyLabel('PvE Neutral'), S.AHKeyLabel('PvE')),
      ('PvE 聯盟', 'PvE 中立', 'PvE（未分陣營）'))

# ---- 匯入時正規化 ----
L.execute(r'''
  NOW = 2000000000
  db = { realms = {}, items = {} }
  inbox = table.concat({
    "V^1^星星^" .. NOW,
    "S^PvE Alliance^" .. (NOW - 900) .. "^^0^1^1^貿易區^1^2", "R^1^1,1,1,1,1",
    "S^PvE Alliance^" .. (NOW - 600) .. "^^0^1^1^藏寶海灣^1^2", "R^1^2,1,1,1,1",
    "V^1^Alex^" .. NOW,
    "S^PvE^" .. (NOW - 500) .. "^^0^1^1^鐵爐堡^1^2", "R^1^3,1,1,1,1",
    "S^PvE^" .. (NOW - 400) .. "^^0^1^1^某個小鎮^1^2", "R^1^4,1,1,1,1",
    "V^1^新版^" .. NOW,
    "S^PvE Neutral^" .. (NOW - 300) .. "^^0^1^1^加基森^1^2", "R^1^5,1,1,1,1",
  }, "~")
  added = AHSnapshot.ImportInbox(db, inbox, NOW, 30)
  -- 同一筆（同時間）以新版的鍵再送一次 → 不重複
  again = AHSnapshot.ImportInbox(db, "V^1^星星^1~S^PvE Neutral^" .. (NOW - 600) .. "^^0^1^1^藏寶海灣^1^2~R^1^2,1,1,1,1", NOW, 30)
  sx = db.shared["星星"]
  ax = db.shared["Alex"]
''')
check('星星：貿易區 → 聯盟、藏寶海灣 → 中立',
      (len(G.sx['PvE Alliance'].scans), len(G.sx['PvE Neutral'].scans), G.sx['PvE Alliance'].scans[1].zone), (1, 1, '貿易區'))
check('同一筆再送不重複', G.again['星星'], None)
check('Alex：鐵爐堡 → 聯盟、認不出的留 PvE', (len(G.ax['PvE Alliance'].scans), len(G.ax['PvE'].scans)), (1, 1))
check('新版的鍵原樣收下', len(G.db.shared['新版']['PvE Neutral'].scans), 1)

# ---- 有資料的拍賣場清單、文字找鍵 ----
L.execute(r'''
  dbL = { realms = { ["PvE Alliance"] = { scans = { { t = 1 } } }, ["PvE Horde"] = { scans = {} },
                     Old = { scans = {}, daily = { [1] = {} } } },
          shared = { ["星星"] = { ["PvE Neutral"] = { scans = { { t = 2 } } }, ["Empty Alliance"] = { scans = {} } } } }
  klist = AHSnapshot.ListAHKeys(dbL)
  klistHere = AHSnapshot.ListAHKeys(dbL, "PvE Horde")
  c1 = { AHSnapshot.CountAHKey(dbL, "PvE Neutral") }
''')
check('清單：有資料的、陣營排序、沒陣營排最後', list(G.klist.values()), ['PvE Alliance', 'PvE Neutral', 'Old'])
check('目前所在沒資料也列出', list(G.klistHere.values()), ['PvE Alliance', 'PvE Horde', 'PvE Neutral', 'Old'])
check('資料量', tuple(G.c1.values()), (0, 1, 0))
check('找鍵：中文', S.FindAHKey(G.klistHere, '部落', 'PvE'), 'PvE Horde')
check('找鍵：英文縮寫', S.FindAHKey(G.klistHere, 'n', 'PvE'), 'PvE Neutral')
check('找鍵：完整名稱不分大小寫', S.FindAHKey(G.klistHere, 'pve alliance', 'PvE'), 'PvE Alliance')
check('找鍵：顯示名稱', S.FindAHKey(G.klistHere, 'old（未分陣營）', 'PvE'), 'Old')
check('找鍵：沒資料的陣營也給得出鍵', S.FindAHKey(G.klist, '部落', 'PvE'), 'PvE Horde')
check('找鍵：找不到', S.FindAHKey(G.klist, '亂打', 'PvE'), None)

# ---- 搬家：併進已經有資料的鍵 ----
L.execute(r'''
  dbM = { version = 4, realms = {
    PvE = { scans = { { t = 10, zone = "貿易區" }, { t = 20, zone = "貿易區" } },
            prev = { a = "old" }, prevVersion = 2, prevTime = 20,
            daily = { [5] = "舊的第5天", [6] = "舊的第6天" }, rolledBefore = 100 },
    ["PvE Alliance"] = { scans = { { t = 20, zone = "貿易區" }, { t = 30, zone = "貿易區" } },
            prev = { a = "new" }, prevVersion = 2, prevTime = 30,
            daily = { [6] = "新的第6天" }, rolledBefore = 200 },
  } }
  rep = AHSnapshot.MigrateToV5(dbM, "PvE")
  m = dbM.realms["PvE Alliance"]
  ts = {}
  for i, sc in ipairs(m.scans) do ts[i] = sc.t end
  again5 = AHSnapshot.MigrateToV5(dbM, "PvE")
''')
check('併進既有鍵、依 t 去重排序', list(G.ts.values()), [10, 20, 30])
check('快照留比較新的', G.m.prev.a, 'new')
check('每日紀錄：已有的那天不覆蓋、沒有的補上', (G.m.daily[5], G.m.daily[6]), ('舊的第5天', '新的第6天'))
check('rolledBefore 取早的（不丟沒濃縮的掃描）', G.m.rolledBefore, 100)
check('舊鍵移除', G.dbM.realms.PvE, None)
check('搬家報告', G.rep.PvE['PvE Alliance'], 2)
check('只升級一次', (G.again5, G.dbM.version), (None, 5))

# ---- 搬完之後，CollectSources 拿得到自己＋朋友 ----
L.execute(r'''
  dbR = { version = 4,
    realms = { PvE = { scans = { { t = 1, zone = "貿易區" }, { t = 2, zone = "貿易區" } } } },
    shared = { ["星星"] = { ["PvE Alliance"] = { scans = { { t = 3, zone = "貿易區" } } } },
               ["Alex"] = { ["PvE Alliance"] = { scans = { { t = 4, zone = "貿易區" } } } } } }
  before = AHSnapshot.CollectSources(dbR, "PvE", true)
  AHSnapshot.MigrateToV5(dbR, "PvE")
  after = AHSnapshot.CollectSources(dbR, "PvE Alliance", true)
  names = {}
  for i, s in ipairs(after) do names[i] = (s.source or "自己") .. #s.scans end
''')
check('1.3.0：自己 PvE 對不上朋友的 PvE Alliance（只有自己）', len(G.before), 1)
check('搬家後同一個拍賣場：自己＋兩位朋友', list(G.names.values()), ['自己2', 'Alex1', '星星1'])

# ---- 每日彙整：每個拍賣場分開濃縮 ----
L.execute(r'''
  OFF = 0
  NOWD = 20000 * 86400 + 12 * 3600
  dbD = { realms = {
    ["PvE Alliance"] = { scans = { { t = 19990 * 86400 + 3600, gap = 600, diff = 1, n = 1, est = 2, items = { ["1"] = "5,1,10,10,10,2,1" } } } },
    ["PvE Neutral"]  = { scans = { { t = 19990 * 86400 + 7200, gap = 600, diff = 1, n = 1, est = 2, items = { ["1"] = "9,1,99,99,99,7,1" } } } },
  } }
  for _, k in ipairs(AHSnapshot.ListAHKeys(dbD)) do AHSnapshot.RollupOld(dbD, k, NOWD, 3, 30, OFF) end
  da = AHSnapshot.ParseDaily(dbD.realms["PvE Alliance"].daily[19990].items["1"])
  dn = AHSnapshot.ParseDaily(dbD.realms["PvE Neutral"].daily[19990].items["1"])
''')
check('聯盟、中立各自濃縮不混', (G.da.sold, G.dn.sold, G.da.min, G.dn.min), (2, 7, 10, 99))

print('全部通過' if fails == 0 else f'{fails} 項失敗')
sys.exit(1 if fails else 0)
