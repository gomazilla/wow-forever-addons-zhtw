"""AH Snapshot 離線測試：python -I -X utf8 tests/test_core.py"""
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

# ---- 物品鍵 ----
check('ItemKey 一般物品', S.ItemKey('|cffffffff|Hitem:2589:0:0:0:0:0:0:0:60|h[亞麻布]|h|r', None), '2589')
check('ItemKey 隨機後綴', S.ItemKey('|cff1eff00|Hitem:15211:0:0:0:0:0:-19:12345:60|h[x]|h|r', None), '15211:-19')
check('ItemKey 只有 itemID', S.ItemKey(None, 4306), '4306')
check('ItemKey 短連結', S.ItemKey('item:4306', None), '4306')

# 比對演算法（依單價分層）的情境測試在 tests/test_tiers.py

# ---- 統計 ----
a = L.eval('''AHSnapshot.Aggregate({
  {count=10, buyout=1000, minBid=1}, {count=1, buyout=50, minBid=1},
  {count=5, buyout=1000, minBid=1}, {count=2, buyout=0, minBid=10},
})''')
check('總量含只能競標的', a.qty, 18)
check('最低單價', a.min, 50)
check('中位單價（數量加權）', a.med, 100)
check('25% 單價', a.p25, 100)

# ---- 完整流程：兩次掃描 ----
L.execute('''
  ah = {}
  local function l(key, count, buyout, owner, tl) return {key=key, count=count, buyout=buyout, minBid=1, owner=owner, tl=tl} end
  s1 = AHSnapshot.ProcessScan(ah, { l("2589",20,2000,"甲",4), l("2589",20,2200,"乙",4), l("4306",10,5000,"丙",4) }, 1000000, "暴風城", true)
  s2 = AHSnapshot.ProcessScan(ah, { l("2589",20,2000,"甲",4) }, 1000000 + 1800, "暴風城", true)
''')
G = L.globals()
check('第一次不比對', G.s1.diff, 0)
check('第二次有比對', G.s2.diff, 1)
# 2589：更便宜的 20@100 還在、較貴的 20@110 消失 → 撤單，不是賣出
check('較貴層單獨消失算撤單', G.s2['items']['2589'], '20,1,100,100,100,0,0,0,20')
# 4306：整疊從最低價被吃掉 → 賣出 10，1 筆成交
check('全賣光的物品也留紀錄', G.s2['items']['4306'], '0,0,0,0,0,10,1,0,0,0,5000')
check('存了兩次掃描', len(G.ah.scans), 2)
check('新快照是分層格式', (G.ah.prevVersion, G.ah.prev['2589'][:4]), (2, '2|s|'))
check('掃描標上推估版本', G.s2.est, 2)

removed = L.eval('AHSnapshot.Prune(ah, 1000000 + 61 * 86400, 60)')
check('超過保留天數刪除', (removed, len(G.ah.scans)), (2, 0))

# ---- 掃描冷卻 ----
check('沒掃過＝現在可掃', S.SecondsUntilScan(None, 1000, 900), 0)
check('剛掃 5 分', S.SecondsUntilScan(1000, 1300, 900), 600)
check('提醒間隔不得小於 15 分', S.SecondsUntilScan(1000, 1300, 60), 600)
check('自訂 60 分', S.SecondsUntilScan(1000, 1300, 3600), 3300)
check('時間到', S.SecondsUntilScan(1000, 3000, 900), 0)
check('格式 分秒', S.FormatWait(605), '10 分 05 秒')
check('格式 小時', S.FormatWait(3900), '1 小時 5 分')
check('格式 秒', S.FormatWait(42), '42 秒')

# ---- 遊戲端（Main.lua）用模擬 API 跑一次 ----
MOCKS = r'''
  printed = {}
  DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) printed[#printed+1] = m end }
  GetSubZoneText = function() return "" end
  GetRealZoneText = nil  -- 缺函式也不能讓記錄失敗
  UnitFactionGroup = function() return "Alliance" end
  GetRealmName = function() return "測試伺服器" end
  clock = 1000000
  time = function() return clock end
  date = os.date
  SlashCmdList = {}
  GetItemInfo = nil  -- Forever 沒有全域版
  C_Item = {}
  C_Item.GetItemInfo = function(id) return "物品"..id, nil, 1, 10, 1, "x", "y", 20, "", nil, 25, 7, 5 end
  -- Forever 是新式拍賣場：舊式 API 不存在
  GetNumAuctionItems, GetAuctionItemInfo, GetAuctionItemLink, GetAuctionItemTimeLeft = nil, nil, nil, nil
  -- 模擬新式全掃交來的一筆：{ replicateInfo, itemLink, timeLeft(0~3) }
  function R(id, name, count, buyout, owner, band)
    return { itemLink = "|cffffffff|Hitem:"..id..":0:0:0:0:0:0:0|h[x]|h|r",
      replicateInfo = { name, nil, count, 1, true, 1, "", 1, 0, buyout, 0, nil, nil, owner, nil, 0, id, true },
      timeLeft = band }
  end
  local handlers = {}
  -- 通用介面元件：沒定義的方法一律接受、什麼都不做
  local function W(kind)
    local w = { scripts = {}, shown = true, kind = kind, w = 100, h = 20 }
    local mt = { __index = function(t, k) return function() end end }
    setmetatable(w, mt)
    w.SetScript = function(self, ev, fn) self.scripts[ev] = fn; if ev == "OnEvent" then handlers[#handlers+1] = fn end end
    w.GetScript = function(self, ev) return self.scripts[ev] end
    w.Show = function(self) local was = self.shown; self.shown = true; if not was and self.scripts.OnShow then self.scripts.OnShow(self) end end
    w.Hide = function(self) self.shown = false end
    w.IsShown = function(self) return self.shown end
    w.IsVisible = function(self) return self.shown end
    w.SetPoint = function(self, ...) self.point = { ... } end
    w.SetText = function(self, t) self.text = t end
    w.GetText = function(self) return self.text end
    w.SetVertexColor = function(self, r, g, b) self.color = { r, g, b } end
    w.SetTexture = function(self, p) self.tex = p end
    w.SetSize = function(self, a, b) self.w, self.h = a, b end
    w.GetWidth = function(self) return self.w end
    w.GetHeight = function(self) return self.h end
    w.CreateTexture = function() return W("Texture") end
    w.CreateMaskTexture = function() return W("Mask") end
    w.CreateFontString = function() return W("FontString") end
    return w
  end
  frames = {}
  CreateFrame = function(kind, name, parent, template)
    local fr = W(kind)
    fr.template = template
    if name then frames[name] = fr end
    return fr
  end
  UIParent = W("Frame")
  UISpecialFrames = {}
  Minimap = { GetWidth = function() return 140 end, GetCenter = function() return 1000, 600 end,
              GetEffectiveScale = function() return 1 end }
  GetCursorPosition = function() return 1000, 700 end  -- 小地圖正上方
  tip = { lines = {} }
  GameTooltip = {
    SetOwner = function(self, o) self.owner = o end,
    SetItemByID = function(self, id) self.lines = { "item:" .. id } end,
    ClearLines = function(self) self.lines = {} end,
    AddLine = function(self, t) self.lines[#self.lines+1] = t end,
    Show = function() end, Hide = function(self) self.owner = nil end,
    IsOwned = function(self, o) return self.owner == o end,
  }
  tickers, afters = {}, {}
  C_Timer = {
    NewTicker = function(sec, fn)
      local tk = { Cancel = function(self) self.cancelled = true end }
      tickers[#tickers+1] = { fn = fn, tk = tk }
      return tk
    end,
    After = function(sec, fn) afters[#afters+1] = fn end,
  }
  function tick() for _, t in ipairs(tickers) do if not t.tk.cancelled then t.fn(t.tk) end end end
  function run_afters() local a = afters; afters = {}; for _, fn in ipairs(a) do fn() end end
  listener = nil
  Auctionator = { SavedState = {}, FullScan = { Events = { ScanComplete = "replicate_scan_complete" } },
    EventBus = { Register = function(_, l, ev) listener = l end } }
  fire_event = function(ev, ...) for _, h in ipairs(handlers) do h(nil, ev, ...) end end
'''
L2 = new_lua()
L2.execute(MOCKS)
with open(os.path.join(ADDON, 'Main.lua'), encoding='utf-8') as f:
    L2.execute(f.read())
G2 = L2.globals()
L2.execute('fire_event("PLAYER_LOGIN")')
check('登入後掛上 Auctionator', G2.listener is not None, True)
L2.execute('''
  Auctionator.SavedState.TimeOfLastReplicateScan = clock
  listener:ReceiveEvent("replicate_scan_complete", { R(2589,"亞麻布",20,2000,"甲",3), R(2589,"亞麻布",20,2400,"乙",3) })
  clock = clock + 1200
  -- 最便宜的 20@100 被買走，較貴的 20@120 還在 → 從底部被吃掉，算賣出
  listener:ReceiveEvent("replicate_scan_complete", { R(2589,"亞麻布",20,2400,"乙",3) })
''')
msgs = list(G2.printed.values())
check('沒有錯誤訊息', any('失敗' in m for m in msgs), False)
check('第二次推估賣出約 20 件（估算）', any('推估賣出約 20 件（1 筆成交，估算）' in m for m in msgs), True)
check('記下物品資料', (G2.AHSnapshotDB['items']['2589'].name, G2.AHSnapshotDB['items']['2589'].sell), ('亞麻布', 25))

# ---- 小地圖燈號 ----
L2.execute('''
  printed = {}
  btn = frames.AHSnapshotMinimapButton
  Auctionator.SavedState.TimeOfLastReplicateScan = clock - 300   -- 5 分鐘前全掃
  tick()
  color_wait = btn.light.color
  btn.scripts.OnEnter(btn)
  tip_wait = table.concat(GameTooltip.lines, "/")
  clock = clock + 601
  tick()                                      -- 指著不放，提示要即時更新
  color_ready = btn.light.color
  tip_ready = table.concat(GameTooltip.lines, "/")
  btn.scripts.OnLeave(btn)
  -- 拖曳到小地圖正上方
  btn.scripts.OnDragStart(btn); btn.scripts.OnUpdate(btn); btn.scripts.OnDragStop(btn)
  drag_angle = AHSnapshotDB.iconAngle
  drag_y = btn.point[5]
  SlashCmdList.AHSNAPSHOT("remind 60")
  tick(); color_60 = btn.light.color
  SlashCmdList.AHSNAPSHOT("remind 15")
  SlashCmdList.AHSNAPSHOT("icon"); hidden = not btn.shown
  SlashCmdList.AHSNAPSHOT("icon"); shown_again = btn.shown
''')
G=G2
check('燈號按鈕已建立', G.btn is not None, True)
check('燈用白色圓形圖', G.btn.light.tex, r'Interface\CharacterFrame\TempPortraitAlphaMask')
check('冷卻中＝綠燈', tuple(G.color_wait.values()), (0.15, 0.9, 0.2))
check('冷卻中提示', 'AH Snapshot/冷卻中：還有 10 分 00 秒' in G.tip_wait, True)
check('時間到＝紅燈', tuple(G.color_ready.values()), (1, 0.15, 0.15))
check('提示即時更新', '可以全掃了' in G.tip_ready, True)
check('拖曳角度', round(G.drag_angle), 90)
check('拖曳位置在正上方', round(G.drag_y), 80)
check('60 分間隔仍綠燈', tuple(G.color_60.values()), (0.15, 0.9, 0.2))
check('icon 隱藏/顯示', (G.hidden, G.shown_again), (True, True))
msgs = list(G2.printed.values())
check('燈號不洗聊天框（只有 4 個指令回覆）', len(msgs), 4)
check('不再有「可以再做一次」提醒', any('可以再做一次' in m for m in msgs), False)

# 舊式拍賣場格式（沒有剩餘時間）也要能吃
L2.execute('''
  clock = clock + 1200
  listener:ReceiveEvent("replicate_scan_complete", {
    {itemLink="|cffffffff|Hitem:2589:0:0:0:0:0:0:0|h[x]|h|r", auctionInfo={"亞麻布",nil,20,1,true,1,"",1,0,2000,0,nil,nil,"甲",nil,0,2589}},
    {itemLink="|cffffffff|Hitem:2592:0:0:0:0:0:0:0|h[x]|h|r", auctionInfo={"毛料",nil,5,1,true,1,"",1,0,500,0,nil,nil,"丙",nil,0,2592}},
  })
  SlashCmdList.AHSNAPSHOT("top")
  SlashCmdList.AHSNAPSHOT("")
''')
msgs = list(G2.printed.values())
check('舊格式有提示', any('讀不到剩餘時間' in m for m in msgs), True)
check('排行指令可用、標示估算與資料不足', any('亞麻布  每日約 20 件（1 筆成交）' in m and '資料不足' in m for m in msgs), True)
check('全程沒有錯誤', any('失敗' in m for m in msgs), False)
for m in msgs:
    print('   >', m)

# ---- 跨角色：拍賣場鍵跟 Auctionator 一致，舊資料搬家 ----
L3 = new_lua()
L3.execute(MOCKS)
L3.execute('''
  Auctionator.Variables = { GetConnectedRealmRoot = function() return "PvE" end }
  AHSnapshotDB = { version = 3, realms = { ["CAMWOW TW4 Realm 1 PvE|Alliance"] = { scans = { { t = clock - 600, n = 1, items = {} } },
    prev = { ["2589"] = "2|s|100:20:0,0,0,20" }, prevVersion = 2, prevTime = clock - 600 } }, items = {} }
''')
with open(os.path.join(ADDON, 'Main.lua'), encoding='utf-8') as f:
    L3.execute(f.read())
L3.execute('''
  fire_event("PLAYER_LOGIN")
  migrated_old = AHSnapshotDB.realms["CAMWOW TW4 Realm 1 PvE|Alliance"]
  migrated_new = #AHSnapshotDB.realms["PvE"].scans
  -- 部落的掃描角色接著掃：甲那筆不見了 → 跟聯盟角色上次的掃描比對
  UnitFactionGroup = function() return "Horde" end
  printed = {}
  listener:ReceiveEvent("replicate_scan_complete", { R(2592,"毛料",5,500,"丙",3) })
  cross = table.concat(printed, "/")
  scans_after = #AHSnapshotDB.realms["PvE"].scans
''')
G3 = L3.globals()
check('舊鍵已移除', G3.migrated_old, None)
check('搬到 PvE', G3.migrated_new, 1)
check('換陣營角色也接得上（推估賣出約 20）', '推估賣出約 20 件' in G3.cross and '（PvE）' in G3.cross, True)
check('同一份紀錄', G3.scans_after, 2)

# ---- 分析計算 ----
L4 = new_lua()
L4.execute('''
  ah = { scans = {
    { t = 1000, diff = 0, items = { ["1"] = "10,2,100,100,120,0,0,0,0,0", ["2"] = "5,1,50,50,50,0,0,0,0,0" } },
    -- 舊格式（10 欄、沒有成交金額）
    { t = 1000 + 3600, diff = 1, gap = 3600, items = { ["1"] = "8,2,100,100,110,2,1,0,0,0" } },
    { t = 1000 + 7200, diff = 1, gap = 3600, items = { ["1"] = "4,1,90,90,90,4,2,2,0,0,400", ["2"] = "0,0,0,0,0,0,0,5,0,0,0" } },
    -- 間隔 10 小時：不算進觀察時間，也不累計賣出
    { t = 1000 + 7200 + 36000, diff = 1, gap = 36000, items = { ["1"] = "4,1,95,95,95,9,1,0,0,0,900" } },
  } }
  items = { ["1"] = { name = "亞麻布", sell = 80, q = 1 }, ["2"] = { name = "毛料" } }
  list, covered, nDiff = AHSnapshot.Analyze(ah, 1000 + 7200 + 36000, 7, items)
  byKey = {}
  for _, r in ipairs(list) do byKey[r.key] = r end
''')
G4 = L4.globals()
r1, r2 = G4.byKey['1'], G4.byKey['2']
check('有效觀察只算 8 小時內的間隔', (G4.covered, G4.nDiff), (7200, 2))
check('賣出累計（排除 10 小時那次）', r1.sold, 6)
check('每日賣出：觀察 2 小時不放大，以 1 天計', round(r1.soldPerDay, 2), 6.0)
check('成交均價只用有金額的紀錄', r1.avgSold, 100)
check('賣出率', round(r1.sellThrough, 3), 0.75)
check('每日成交額：不放大', round(r1.valuePerDay), 400)
check('最新價格', (r1.qty, r1.min, r1.med), (4, 95, 95))
check('中位價趨勢', round(r1.trend, 3), round((95 - 120) / 120, 3))
check('沒在最新一次的物品架上為 0', (r2.qty, r2.expired, r2.sellThrough), (0, 5, 0))
check('名稱與收購價', (r1.name, r1.sell), ('亞麻布', 80))
L4.execute('''
  sorted = AHSnapshot.SortList(AHSnapshot.FilterList(list, "", false), "expired", false)
  only = AHSnapshot.FilterList(list, "", true)
  found = AHSnapshot.FilterList(list, "毛", false)
  hist = AHSnapshot.History(ah, "1", 2)
''')
check('依欄位排序', G4.sorted[1].key, '2')
check('只看有賣出', len(G4.only), 1)
check('搜尋名稱', G4.found[1].name, '毛料')
check('明細新到舊、限筆數', (len(G4.hist), G4.hist[1].sold, G4.hist[2].soldValue), (2, 9, 400))

# ---- 分析視窗（UI.lua）實際建一次 ----
with open(os.path.join(ADDON, 'UI.lua'), encoding='utf-8') as f:
    L2.execute(f.read())
L2.execute('''
  printed = {}
  btn.scripts.OnClick(btn)                       -- 點燈號開視窗
  win = frames.AHSnapshotFrame
  row1 = win.rows[1].cells[1].text
  footer = win.footer.text
  esc = UISpecialFrames[1]
  -- 依名稱排序、搜尋、只看有賣出關掉
  win.headers[1].scripts.OnClick(win.headers[1])
  sort_head = win.headers[1].text.text
  win.soldToggle.scripts.OnClick(win.soldToggle)
  frames.AHSnapshotSearchBox.text = "毛"
  frames.AHSnapshotSearchBox.scripts.OnTextChanged(frames.AHSnapshotSearchBox)
  search_row = win.rows[1].cells[1].text
  search_row2_shown = win.rows[2].shown
  win.scripts.OnMouseWheel(win, -1)
  -- 點一列看明細
  win.rows[1].scripts.OnClick(win.rows[1])
  det = frames.AHSnapshotDetailFrame
  det_title = det.title.text
  det_hist = det.cols[1].text
  win.rows[1].scripts.OnEnter(win.rows[1])
  item_tip = GameTooltip.lines[1]
  SlashCmdList.AHSNAPSHOT("show")
  hidden_after_toggle = not win.shown
  SlashCmdList.AHSNAPSHOT("show")
  shown_again = win.shown
''')
G = G2
check('點燈號開啟視窗', G.win is not None and G.win.shown, True)
check('第一列有物品', '亞麻布' in (G.row1 or ''), True)
check('Esc 可關閉', G.esc, 'AHSnapshotFrame')
check('頁尾有觀察時數', '有效觀察' in (G.footer or ''), True)
check('點標題依名稱排序', G.sort_head, '物品 ^')
check('搜尋「毛」', ('毛料' in G.search_row, G.search_row2_shown), (True, False))
check('明細標題', G.det_title, '毛料')
check('明細有歷史', '時間' in G.det_hist and chr(10) in G.det_hist, True)
check('列上顯示物品提示', G.item_tip, 'item:2592')
check('/ahsnap show 開關', (G.hidden_after_toggle, G.shown_again), (True, True))
check('UI 全程沒有錯誤', any('失敗' in m for m in G2.printed.values()), False)

# ---- 共享：登入匯入 inbox、伺服器時間、登出寫 outbox、視窗朋友資料開關 ----
L5 = new_lua()
L5.execute(MOCKS)
L5.execute(r'''
  Auctionator.Variables = { GetConnectedRealmRoot = function() return "PvE" end }
  GetServerTime = function() return clock + 7 end     -- 伺服器時間跟本機差 7 秒
  AHSnapshotInbox = table.concat({
    "V^1^小美^" .. clock,
    "I^2592^毛料^1^25^7^5^20",
    "S^PvE^" .. (clock - 1200) .. "^^0^1^5^貿易區^1^2",
    "R^2592^5,1,500,500,500,0,0,0,0,0,0",
    "S^PvE^" .. (clock - 600) .. "^600^1^1^5^貿易區^1^2",
    "R^2592^2,1,520,520,520,3,1,0,0,0,1500",
  }, "~")
''')
with open(os.path.join(ADDON, 'Main.lua'), encoding='utf-8') as f:
    L5.execute(f.read())
with open(os.path.join(ADDON, 'UI.lua'), encoding='utf-8') as f:
    L5.execute(f.read())
L5.execute(r'''
  fire_event("PLAYER_LOGIN")
  login_msgs = table.concat(printed, "/")
  inbox_after = AHSnapshotInbox
  mei = #AHSnapshotDB.shared["小美"].PvE.scans
  mei_item = AHSnapshotDB.items["2592"].name
  listener:ReceiveEvent("replicate_scan_complete", { R(2589,"亞麻布",20,2000,"甲",3) })
  own_t = AHSnapshotDB.realms.PvE.scans[1].t
  own_prev = AHSnapshotDB.realms.PvE.prev["2589"]
  fire_event("PLAYER_LOGOUT")
  outbox = AHSnapshotOutbox
  -- 視窗：預設包含朋友資料
  SlashCmdList.AHSNAPSHOT("show")
  win = frames.AHSnapshotFrame
  foot_on = win.footer.text
  toggle_on = win.sharedToggle.text
  win.soldToggle.scripts.OnClick(win.soldToggle)          -- 顯示全部
  rows_on = 0
  for _, r in ipairs(win.rows) do if r.shown then rows_on = rows_on + 1 end end
  win.sharedToggle.scripts.OnClick(win.sharedToggle)
  toggle_off = win.sharedToggle.text
  rows_off = 0
  for _, r in ipairs(win.rows) do if r.shown then rows_off = rows_off + 1 end end
  SlashCmdList.AHSNAPSHOT("share")
  share_msgs = table.concat(printed, "/")
  btn = frames.AHSnapshotMinimapButton
  btn.scripts.OnEnter(btn)
  tip = table.concat(GameTooltip.lines, "/")
''')
G5 = L5.globals()
check('登入匯入朋友資料', (G5.mei, G5.mei_item), (2, '毛料'))
check('匯入後清空 inbox', G5.inbox_after, None)
check('匯入有提示', '已匯入朋友的掃描：小美 2 次' in G5.login_msgs, True)
check('掃描用伺服器時間', G5.own_t, G5.clock + 7)
check('剩餘時間原始值 3 存成第 3 級（不再 +1）', G5.own_prev, '2|s|100:20:0,0,20,0')
check('登出寫 outbox', (G5.outbox or '').startswith('V^1^^') and '^PvE^' in G5.outbox and 'R^2589^' in G5.outbox, True)
check('outbox 不含朋友資料', 'R^2592^' in (G5.outbox or ''), False)
check('視窗：朋友資料開、2 個來源', ('包含朋友資料：開' in G5.toggle_on, '2 個來源' in G5.foot_on), (True, True))
check('切掉朋友資料後物品變少', (G5.rows_on, G5.rows_off, '關' in G5.toggle_off), (2, 1, True))
check('/ahsnap share', '小美：2 次掃描' in G5.share_msgs, True)
check('燈號提示列出朋友', '朋友資料：小美' in G5.tip, True)

# ---- 視窗的估算標示（接 L5：朋友小美 1 筆成交 → 低可信度）----
L5.execute(r'''
  win = frames.AHSnapshotFrame
  if not win.shown then SlashCmdList.AHSNAPSHOT("show") end
  if win.sharedToggle.text:find("關") then win.sharedToggle.scripts.OnClick(win.sharedToggle) end
  heads = {}
  for i, h in ipairs(win.headers) do heads[i] = h.text.text end
  heads = table.concat(heads, "/")
  cells = {}
  for _, r in ipairs(win.rows) do
    if r.shown and r.item and r.item.key == "2592" then
      for i, c in ipairs(r.cells) do cells[i] = c.text end
      r.scripts.OnClick(r)
    end
  end
  cells = table.concat(cells, "/")
  det = table.concat({ frames.AHSnapshotDetailFrame.summary.text }, "")
  note = win.note.text
''')
check('推估欄位標 (估)', all(t in G5.heads for t in ('賣出(估)', '每日賣出(估)', '每日成交額(估)', '成交筆數')), True)
check('低可信度：灰色、約、?', '|cff888888約3?|r' in G5.cells, True)
check('明細顯示成交筆數與可信度', ('成交筆數 1' in G5.det, '只觀察到 1 次成交' in G5.det), (True, True))
check('頁尾說明估算規則', ('觀察不滿 1 天' in G5.note, '撤單' in G5.note), (True, True))

# ---- 舊存檔登入：推估清掉、只提示一次 ----
L6 = new_lua()
L6.execute(MOCKS)
L6.execute(r'''
  Auctionator.Variables = { GetConnectedRealmRoot = function() return "PvE" end }
  AHSnapshotDB = { version = 2, items = {}, realms = { PvE = {
    prev = { ["2589"] = { "20:2000:1:?;5" } }, prevTime = clock - 900,
    scans = { { t = clock - 900, gap = 900, diff = 1, n = 1, items = { ["2589"] = "20,1,100,100,100,3788,442,0,0,5131,99" } } } } } }
''')
with open(os.path.join(ADDON, 'Main.lua'), encoding='utf-8') as f:
    L6.execute(f.read())
L6.execute(r'''
  fire_event("PLAYER_LOGIN")
  m1 = table.concat(printed, "/")
  row = AHSnapshotDB.realms.PvE.scans[1].items["2589"]
  pv = AHSnapshotDB.realms.PvE.prev
  ver = AHSnapshotDB.version
  printed = {}
  fire_event("PLAYER_LOGIN")      -- 再登入一次（例如 /reload）
  m2 = table.concat(printed, "/")
  listener:ReceiveEvent("replicate_scan_complete", { R(2589,"亞麻布",20,2000,"甲",4) })
  first_msg = table.concat(printed, "/")
''')
G6 = L6.globals()
check('升級提示', '舊版的賣出推估有誤' in G6.m1, True)
check('升級後推估歸零、價格保留', G6.row, '20,1,100,100,100')
check('舊快照清掉、升到最新版本', (G6.pv, G6.ver), (None, 4))
check('提示只出現一次', '舊版的賣出推估有誤' in G6.m2, False)
check('升級後下一次全掃當第一次', '第一次掃描' in G6.first_msg, True)

print('全部通過' if fails == 0 else f'{fails} 項失敗')
sys.exit(1 if fails else 0)
