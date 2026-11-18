"""賣出推估（依單價分層）、資料升級、可信度規則測試：python -I -X utf8 tests/test_tiers.py"""
import os, sys
from lupa import lua51

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, '..', 'AHSnapshot')
fails = 0


def check(name, got, want):
    global fails
    ok = got == want
    if not ok:
        fails += 1
    print(('OK  ' if ok else 'FAIL'), name, '' if ok else f'got={got!r} want={want!r}')


L = lua51.LuaRuntime(unpack_returned_tuples=True)
for name in ('Core.lua', 'Share.lua'):
    with open(os.path.join(ADDON, name), encoding='utf-8') as f:
        L.execute(f.read())
G = L.globals()
L.execute(r'''
  -- 上架：{ 數量, 單價, 剩餘時間分級 }（直購總價＝數量×單價）
  function LS(spec)
    local out = {}
    for _, x in ipairs(spec) do out[#out+1] = { key = "1", count = x[1], buyout = x[1] * x[2], minBid = 1, tl = x[3] or 4 } end
    return out
  end
  function D(prev, cur, gap, stackable)
    local r = AHSnapshot.DiffTiers(AHSnapshot.BuildTiers(LS(prev)), AHSnapshot.BuildTiers(LS(cur)), gap or 900, stackable ~= false)
    return { r.sold, r.soldN, r.expired, r.repost, r.new, r.soldValue }
  end
''')


def d(prev, cur, gap=900, stackable=True):
    L.execute('R_ = D(%s, %s, %d, %s)' % (prev, cur, gap, 'true' if stackable else 'false'))
    return tuple(G.R_.values())


# 欄位：(賣出, 成交筆數, 可能到期, 撤單/重上, 新上架, 成交金額)
check('部分購買只算差額（200→180）', d('{{200,10}}', '{{180,10}}'), (20, 1, 0, 0, 0, 200))
check('鐵錠例子：183→168 只算 15', d('{{183,50}}', '{{168,50}}'), (15, 1, 0, 0, 0, 750))
check('從底部連續吃掉兩層', d('{{50,10},{100,12},{100,15}}', '{{60,12},{100,15}}'), (90, 2, 0, 0, 0, 50 * 10 + 40 * 12))
check('高價層單獨減少＝撤單', d('{{50,10},{100,15}}', '{{50,10}}'), (0, 0, 0, 100, 0, 0))
check('底層沒動、上層減少＝撤單', d('{{50,10},{30,12},{20,15}}', '{{50,10},{30,12},{5,15}}'), (0, 0, 0, 15, 0, 0))
check('壓價重上（底層消失、同量出現在更便宜）', d('{{20,10},{50,12}}', '{{20,9},{50,12}}'), (0, 0, 0, 20, 0, 0))
check('換到更高價重上不算新上架', d('{{50,10},{30,15}}', '{{50,10},{30,20}}'), (0, 0, 0, 30, 0, 0))
check('數量接近（5% 內）也算重上', d('{{50,10},{100,15}}', '{{50,10},{98,14}}'), (0, 0, 0, 100, 0, 0))
check('單純新上架', d('{{50,10}}', '{{50,10},{20,11}}'), (0, 0, 0, 0, 20, 0))
check('被買走一部分、同時有人新上架更貴的', d('{{50,10}}', '{{30,10},{40,13}}'), (20, 1, 0, 0, 40, 200))
check('底層減少、更便宜價位有新上架：先抵成重上（寧可少算）', d('{{50,10}}', '{{7,9}}'), (43, 1, 0, 7, 0, 430))
check('部分購買後剩下的壓價重上', d('{{100,10},{50,12}}', '{{60,9},{50,12}}'), (40, 1, 0, 60, 0, 400))
# 剩餘時間：30 分內的可能到期；8 小時以上的間隔 15 分內不可能到期
check('短單消失算可能到期', d('{{20,10,1}}', '{}'), (0, 0, 20, 0, 0, 0))
check('長短混合：先算到期，其餘算賣出', d('{{5,10,1},{15,10,4}}', '{}'), (15, 1, 5, 0, 0, 150))
check('間隔 9 小時：全部可能到期', d('{{20,10,4}}', '{}', gap=9 * 3600), (0, 0, 20, 0, 0, 0))
check('只能競標的消失算到期', d('{{5,0}}', '{}'), (0, 0, 5, 0, 0, 0))
# 不可堆疊（裝備）：逐件
check('裝備逐件：兩件消失', d('{{1,100},{1,100},{1,200}}', '{{1,100}}', stackable=False), (2, 2, 0, 0, 0, 300))
check('裝備：貴的那件消失也算賣出（沒有賣家資料）', d('{{1,100},{1,200}}', '{{1,100}}', stackable=False), (1, 1, 0, 0, 0, 200))
check('裝備：短單消失算到期', d('{{1,100,1}}', '{}', stackable=False), (0, 0, 1, 0, 0, 0))

# ---- 分層字串 ----
L.execute(r'''
  local t = AHSnapshot.BuildTiers(LS({{20,10,4},{5,10,1},{3,0,2}}))
  packed = AHSnapshot.PackTiers(t, true)
  back, flag = AHSnapshot.UnpackTiers(packed)
  oldfmt = AHSnapshot.UnpackTiers({ "20:2000:1:甲;4" })
  oldstr = AHSnapshot.UnpackTiers("20:2000:1:?;4")
''')
check('分層字串', G.packed, '2|s|0:3:0,3,0,0;10:25:5,0,0,20')
check('分層字串來回', (G.back[10].qty, G.back[10].tl[4], G.back[0].qty, G.flag), (25, 20, 3, True))
check('舊格式讀成 nil', (G.oldfmt, G.oldstr), (None, None))

# ---- 可不可堆疊 ----
L.execute(r'''
  st1 = AHSnapshot.IsStackable({ stack = 200 }, {})
  st2 = AHSnapshot.IsStackable({ stack = 1 }, LS({{5,10}}))
  st3 = AHSnapshot.IsStackable(nil, LS({{5,10}}))
  st4 = AHSnapshot.IsStackable(nil, LS({{1,10}}))
  st5 = AHSnapshot.IsStackable(nil, {}, true)
''')
check('可堆疊判斷', (G.st1, G.st2, G.st3, G.st4, G.st5), (True, False, True, False, True))

# ---- ProcessScan：舊快照當第一次 ----
L.execute(r'''
  local function l(key, count, unit, tl) return { key = key, count = count, buyout = count * unit, minBid = 1, tl = tl or 4 } end
  ahOld = { prev = { ["1"] = { "200:2000:1:?;4" } }, prevTime = 1000, scans = {} }
  s1 = AHSnapshot.ProcessScan(ahOld, { l("1", 180, 10) }, 1900, "z", true, { ["1"] = { stack = 200 } })
  s2 = AHSnapshot.ProcessScan(ahOld, { l("1", 150, 10) }, 2800, "z", true, { ["1"] = { stack = 200 } })
''')
check('舊快照：不比對', (G.s1.diff, G.s1['items']['1']), (0, '180,1,10,10,10'))
check('之後用新演算法比對', (G.s2.diff, G.s2['items']['1']), (1, '150,1,10,10,10,30,1,0,0,0,300'))

# ---- 資料升級到第 3 版 ----
L.execute(r'''
  dbv = {
    realms = { PvE = { prev = { ["1"] = { "x" } }, prevTime = 5, scans = {
      { t = 10, diff = 0, items = { ["1"] = "10,1,5,5,5,0,0,0,0,0" } },
      { t = 20, gap = 10, diff = 1, items = { ["1"] = "8,1,6,6,7,3788,442,1,0,5131,99999", ["2"] = "1,1,9,9,9,1,1,0,0,0" } },
    } } },
    shared = { ["阿明"] = { PvE = { scans = { { t = 30, gap = 10, diff = 1, items = { ["1"] = "1,1,1,1,1,9,9,9,9,9,9" } },
                                           { t = 40, gap = 10, diff = 1, est = 2, items = { ["1"] = "1,1,1,1,1,2,1,0,0,0,20" } } } } } },
  }
  mig1 = AHSnapshot.MigrateToV3(dbv)
  mig2 = AHSnapshot.MigrateToV3(dbv)
  pv = dbv.realms.PvE
''')
check('升級只做一次', (G.mig1, G.mig2, G.dbv.version), (True, False, 3))
check('推估歸零、價格保留', G.pv.scans[2]['items']['1'], '8,1,6,6,7')
check('舊 10 欄列補滿 11 欄', G.pv.scans[2]['items']['2'], '1,1,9,9,9')
check('標成不比對', (G.pv.scans[1].diff, G.pv.scans[2].diff), (0, 0))
check('舊快照丟掉', (G.pv.prev, G.pv.prevTime), (None, None))
check('朋友的舊推估清掉、新推估保留', (G.dbv.shared['阿明'].PvE.scans[1]['items']['1'], G.dbv.shared['阿明'].PvE.scans[2]['items']['1']),
      ('1,1,1,1,1', '1,1,1,1,1,2,1,0,0,0,20'))

# ---- 可信度：稀有高價品不誇大、不搶第一 ----
L.execute(r'''
  -- 13 次比對，每次 1 小時（有效觀察 13 小時）
  local scans = {}
  local t = 100000
  scans[1] = { t = t, diff = 0, items = { hot = "100,5,1000,1000,1000,0,0,0,0,0,0" } }
  for i = 1, 13 do
    t = t + 3600
    local items = { hot = "100,5,1000,1000,1000,15,2,0,0,15,15000" }   -- 每小時賣 15 個、2 筆成交，每個 10 銀
    if i == 13 then items.rare = "0,0,0,0,0,1,1,0,0,0,60000000" end    -- 稀有品：只看到 1 次成交，6000 金
    scans[#scans + 1] = { t = t, gap = 3600, diff = 1, items = items }
  end
  conf = AHSnapshot.Analyze({ scans = scans }, t, 7, {})
  byKey = {}
  for _, r in ipairs(conf) do byKey[r.key] = r end
  AHSnapshot.SortList(conf, "valuePerDay", false)
  firstKey = conf[1].key
  -- 只觀察 3 小時、1 次成交：不能放大成 8 倍
  short = AHSnapshot.Analyze({ scans = {
    { t = 0, diff = 0, items = { rare = "1,1,60000000,60000000,60000000,0,0,0,0,0,0" } },
    { t = 10800, gap = 10800 - 3600 * 2, diff = 1, items = { rare = "0,0,0,0,0,1,1,0,0,0,60000000" } },
  } }, 10800, 7, {})
''')
rare, hot = G.byKey['rare'], G.byKey['hot']
check('稀有品標低可信度（1 筆成交）', (rare.lowConf, rare.avgLowConf, rare.soldN), (True, True, 1))
check('熱賣品可信（26 筆、13 小時）', (hot.lowConf, hot.soldN, round(hot.observedHours)), (False, 26, 13))
check('稀有品每日成交額不外推（觀察不滿 1 天以 1 天計）', rare.valuePerDay, 60000000)
check('預設排序（每日成交額）熱賣品排第一', G.firstKey, 'hot')
s = G.short[1]
check('3 小時 1 次成交：每日賣出 1、成交額不放大', (s.soldPerDay, s.valuePerDay, s.lowConf), (1, 60000000, True))
check('熱賣品不受影響：每日賣出＝195／1 天', round(hot.soldPerDay), 195)
L.execute(r'''
  asc = AHSnapshot.SortList({ { name="a", soldN=1, lowConf=true }, { name="b", soldN=5, lowConf=false } }, "soldN", true)
  nm = AHSnapshot.SortList({ { name="b", lowConf=true }, { name="a", lowConf=false } }, "name", true)
''')
check('升冪排序時低可信度也排後面', G.asc[1].name, 'b')
check('非推估欄位不受可信度影響', G.nm[1].name, 'a')
check('估算數字格式', (G.AHSnapshot.FormatEstimate(0.04), G.AHSnapshot.FormatEstimate(2.345), G.AHSnapshot.FormatEstimate(12.6)), ('0.0', '2.3', '13'))

print('全部通過' if fails == 0 else f'{fails} 項失敗')
sys.exit(1 if fails else 0)
