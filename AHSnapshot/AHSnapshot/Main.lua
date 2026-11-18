-- AH Snapshot 遊戲端：掛在 Auctionator 全掃完成事件上，讀整份拍賣列表存快照
local S = AHSnapshot
local PREFIX = "|cff33ccff[AH Snapshot]|r "

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg) end

local function Money(c)
  c = tonumber(c) or 0
  local g, s, cp = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  if g > 0 then return string.format("%dg%02ds", g, s) end
  if s > 0 then return string.format("%ds%02dc", s, cp) end
  return cp .. "c"
end

local function Safe(fn)
  if type(fn) ~= "function" then return "" end
  local ok, v = pcall(fn)
  return ok and v or ""
end

-- 拍賣場的分法跟 Auctionator 一致：Forever 是同規則（例如 "PvE"）的所有伺服器、兩個陣營共用一個拍賣場，
-- 所以任何角色掃到的資料都併在一起。讀不到 Auctionator 的分法才退回「伺服器|陣營」。
local function AHRoot()
  local ok, root = pcall(function() return Auctionator.Variables.GetConnectedRealmRoot() end)
  if ok and type(root) == "string" and root ~= "" then return root end
  return (GetRealmName() or "?") .. "|" .. (UnitFactionGroup("player") or "?")
end

local function GetAH()
  local db = AHSnapshotDB
  local rk = AHRoot()
  local sub, zone = Safe(GetSubZoneText), Safe(GetRealZoneText)
  db.realms[rk] = db.realms[rk] or { scans = {} }
  return db.realms[rk], rk, (sub ~= "" and sub or zone)
end
S.GetAH = GetAH
S.Money = Money
S.AHRoot = AHRoot

-- 掃描時間用伺服器時間，大家（不同電腦）的時間才對得起來
function S.Now()
  if type(GetServerTime) == "function" then
    local ok, t = pcall(GetServerTime)
    if ok and t then return t end
  end
  return time()
end

-- 分析用的來源（自己＋朋友），UI.lua 用
function S.GetSources(includeShared)
  return S.CollectSources(AHSnapshotDB, AHRoot(), includeShared)
end

local function SharedNames()
  local names = {}
  for src in pairs(AHSnapshotDB.shared or {}) do names[#names + 1] = src end
  table.sort(names)
  return names
end
S.SharedNames = SharedNames

-- 1.0 版用「伺服器|陣營」當鍵；新鍵還沒有資料時，把舊資料搬過去（只搬一份）
local function MigrateOldKeys()
  local db, rk = AHSnapshotDB, AHRoot()
  if db.realms[rk] and #(db.realms[rk].scans or {}) > 0 then return end
  for key, data in pairs(db.realms) do
    if key ~= rk and key:find("|", 1, true) and #(data.scans or {}) > 0 then
      db.realms[rk] = data
      db.realms[key] = nil
      return key
    end
  end
end

-- 記下物品的基本資料（名稱、品質、商店收購價、分類），分析時要用
-- Forever 是新版引擎，全域 GetItemInfo 已移除，改用 C_Item 版
local ItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function RememberItem(key, itemID, name)
  local items = AHSnapshotDB.items
  if items[key] and items[key].sell and items[key].name then return end
  local ok, iname, _, quality, _, _, _, _, maxStack, _, _, sell, classID, subclassID = pcall(ItemInfo, itemID)
  if not ok then iname, quality, maxStack, sell, classID, subclassID = nil, nil, nil, nil, nil, nil end
  items[key] = {
    name = name or iname,
    q = quality,
    sell = sell,
    cls = classID,
    sub = subclassID,
    stack = maxStack,
  }
end

-- 讀 Auctionator 全掃交來的資料。
-- Forever 用新式拍賣場（C_AuctionHouse 全掃）：每筆是 { replicateInfo, itemLink, timeLeft }，
--   timeLeft 是剩餘時間分級。Forever 實測回傳 1～4（短／中／長／很長，跟 S.TL_MIN 同編號；
--   1.1 版誤以為是 0～3 而 +1，最長那級變成 5）。保險起見遇到 0 當成 1。
-- 舊式拍賣場（經典版）：每筆是 { auctionInfo, itemLink }，沒有剩餘時間，只能比較保守地推估。
-- 兩種的 info 欄位順序相同：1 名稱、3 數量、8 起標價、10 直購價、14 賣家、17 物品 ID。
local function Capture(rawFullScan)
  local listings, hasTL = {}, false
  for _, e in ipairs(type(rawFullScan) == "table" and rawFullScan or {}) do
    local info = e.replicateInfo or e.auctionInfo or {}
    local name, count, minBid, buyout, owner, itemID = info[1], info[3], info[8], info[10], info[14], info[17]
    local key = S.ItemKey(e.itemLink, itemID)
    if key and count and count > 0 then
      local tl = nil
      if type(e.timeLeft) == "number" then
        tl = math.min(4, math.max(1, e.timeLeft))
        hasTL = true
      end
      listings[#listings + 1] = {
        key = key, count = count, buyout = buyout or 0, minBid = minBid or 0, owner = owner, tl = tl,
      }
      RememberItem(key, itemID, name)
    end
  end
  return listings, hasTL
end

-- 超過保留期的逐次掃描濃縮成每日紀錄（自己＋朋友合併後才濃縮，見 DESIGN.md）
function S.Rollup(now)
  local db = AHSnapshotDB
  local ok, err = pcall(S.RollupOld, db, AHRoot(), now or S.Now(), db.detailDays, db.dailyDays, S.LocalDayOffset())
  if not ok then db.lastError = { t = time(), err = "每日彙整失敗：" .. tostring(err) } end
end

-- 朋友資料裡的物品沒有名稱（分享檔只放物品 ID）：用 ID 向伺服器查，查到就記下來。
-- 一次查一小批，避免一口氣送出上千個查詢。
local pending, fetchTicker = {}, nil
local function FetchMissingItems()
  local db = AHSnapshotDB
  local want = {}
  for _, sh in pairs(db.shared or {}) do
    for _, a in pairs(sh) do
      for _, sc in ipairs(a.scans or {}) do
        for key in pairs(sc.items or {}) do
          local it = db.items[key]
          if not (it and it.name) and tostring(key):match("^%d+$") then want[key] = true end
        end
      end
    end
  end
  local queue = {}
  for key in pairs(want) do queue[#queue + 1] = key end
  if #queue == 0 or fetchTicker then return end
  local i = 0
  fetchTicker = C_Timer.NewTicker(0.2, function(self)
    for _ = 1, 40 do
      i = i + 1
      local key = queue[i]
      if not key then self:Cancel(); fetchTicker = nil; return end
      local id = tonumber(key)
      local ok, name = pcall(ItemInfo, id)
      if ok and name then RememberItem(key, id, name) else pending[id] = key end
    end
  end)
end

local function OnItemInfo(itemID, success)
  local key = itemID and pending[itemID]
  if not key then return end
  pending[itemID] = nil
  if success == false then return end
  local ok, name = pcall(ItemInfo, itemID)
  if ok and name then
    RememberItem(key, itemID, name)
    if S.OnDataChanged and not S.itemRefreshQueued then
      S.itemRefreshQueued = true
      C_Timer.After(1, function() S.itemRefreshQueued = nil; S.OnDataChanged() end)
    end
  end
end

local function OnScanComplete(rawFullScan)
  local ok, err = xpcall(function()
    local ah, rk, zone = GetAH()
    local listings, hasTL = Capture(rawFullScan)
    if #listings == 0 then Print("列表是空的，這次不記錄。"); return end
    local now = S.Now()
    local scan = S.ProcessScan(ah, listings, now, zone, hasTL, AHSnapshotDB.items)
    S.Rollup(now)

    local msg = string.format("已記錄 %d 筆上架、%d 種物品（%s）。", scan.n, scan.nItems, rk)
    if scan.diff == 1 then
      local sold, soldN = 0, 0
      for _, row in pairs(scan.items) do
        local f = S.ParseRow(row)
        sold, soldN = sold + f.sold, soldN + f.soldN
      end
      msg = msg .. string.format(" 距上次 %d 分鐘，推估賣出約 %d 件（%d 筆成交，估算）。",
        math.floor(scan.gap / 60), sold, soldN)
      if scan.gap > 8 * 3600 then msg = msg .. "（間隔太久，推估會偏低）" end
    else
      msg = msg .. " 第一次掃描，下次掃描起開始推估賣出量。"
    end
    if not hasTL then msg = msg .. " 本次讀不到剩餘時間，消失的拍賣都算成可能到期。" end
    Print(msg .. " 登出或 /reload 後才會寫入存檔。")
    if S.OnDataChanged then S.OnDataChanged() end
  end, function(e)
    local stack = type(debugstack) == "function" and debugstack(2, 4, 0) or ""
    return tostring(e) .. " | " .. stack
  end)
  if not ok then
    AHSnapshotDB.lastError = { t = time(), err = err }
    Print("|cffff4444記錄失敗：|r" .. tostring(err))
    Print("錯誤已存進存檔，/reload 後可交給開發者查看。")
  else
    AHSnapshotDB.lastError = nil
  end
end

-- ---- 掃描冷卻燈號（小地圖旁）----
-- Auctionator 在「開始」全掃時就記下時間（失敗也算），以它為準；讀不到才用自己的紀錄
local function LastScanTime()
  local st = Auctionator and Auctionator.SavedState
  local t = st and (st.TimeOfLastReplicateScan or st.TimeOfLastGetAllScan)
  if t then return t end
  local ah = GetAH()
  local last = ah.scans and ah.scans[#ah.scans]
  return last and last.t or nil
end

local function RemindInterval()
  return (AHSnapshotDB.remindMin or 15) * 60
end

local function WaitText()
  local left = S.SecondsUntilScan(LastScanTime(), time(), RemindInterval())
  if left <= 0 then return "現在可以全掃了。", 0 end
  local label = (AHSnapshotDB.remindMin or 15) > 15 and "距你設定的下次掃描" or "距下次可全掃"
  return label .. "還有 " .. S.FormatWait(left) .. "。", left
end

-- 紅燈＝可以掃了，綠燈＝冷卻中
local COLOR_READY = { 1, 0.15, 0.15 }
local COLOR_WAIT  = { 0.15, 0.9, 0.2 }

local icon
local function PlaceIcon()
  local angle = math.rad(AHSnapshotDB.iconAngle or 200)
  local r = (Minimap:GetWidth() / 2) + 10
  icon:ClearAllPoints()
  icon:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

local function ShowTooltip(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:ClearLines()
  GameTooltip:AddLine("AH Snapshot")
  local left = S.SecondsUntilScan(LastScanTime(), time(), RemindInterval())
  if left <= 0 then
    GameTooltip:AddLine("可以全掃了", 1, 0.3, 0.3)
  else
    GameTooltip:AddLine("冷卻中：還有 " .. S.FormatWait(left), 0.3, 1, 0.3)
  end
  local last = LastScanTime()
  if last then GameTooltip:AddLine("上次全掃：" .. date("%H:%M", last), 0.8, 0.8, 0.8) end
  local m = AHSnapshotDB.remindMin or 15
  if m > 15 then GameTooltip:AddLine("燈號間隔：" .. m .. " 分鐘", 0.8, 0.8, 0.8) end
  local ah = GetAH()
  GameTooltip:AddLine("已存 " .. #(ah.scans or {}) .. " 次掃描", 0.8, 0.8, 0.8)
  local friends = SharedNames()
  if #friends > 0 then
    GameTooltip:AddLine("朋友資料：" .. table.concat(friends, "、"), 0.8, 0.8, 0.8, true)
  end
  GameTooltip:AddLine("點擊開啟價量分析｜拖曳可沿小地圖移動", 0.5, 0.5, 0.5)
  GameTooltip:Show()
end

local function UpdateIcon()
  if not icon then return end
  local left = S.SecondsUntilScan(LastScanTime(), time(), RemindInterval())
  local c = left <= 0 and COLOR_READY or COLOR_WAIT
  icon.light:SetVertexColor(c[1], c[2], c[3], 1)
  if GameTooltip:IsOwned(icon) then ShowTooltip(icon) end  -- 指著時即時更新倒數
end

local function CreateIcon()
  if icon or not Minimap then return end
  icon = CreateFrame("Button", "AHSnapshotMinimapButton", Minimap)
  icon:SetSize(31, 31)
  icon:SetFrameStrata("MEDIUM")
  icon:SetFrameLevel(8)
  icon:RegisterForDrag("LeftButton")
  icon:SetHighlightTexture(136477) -- UI-Minimap-ZoomButton-Highlight

  -- 位置照 LibDBIcon（其他插件的小地圖按鈕），對準外框圓心
  local bg = icon:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetPoint("TOPLEFT", 7, -5)
  bg:SetTexture(136467) -- Interface\Minimap\UI-Minimap-Background

  -- 燈：白色圓形圖（暴雪頭像遮罩）當一般貼圖，再用 SetVertexColor 上色
  local light = icon:CreateTexture(nil, "ARTWORK")
  light:SetSize(14, 14)
  light:SetPoint("TOPLEFT", 10, -8)
  light:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
  icon.light = light

  local border = icon:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  border:SetTexture(136430) -- Interface\Minimap\MiniMap-TrackingBorder

  icon:SetScript("OnEnter", ShowTooltip)
  icon:SetScript("OnLeave", function() GameTooltip:Hide() end)
  icon:SetScript("OnClick", function() if S.ToggleWindow then S.ToggleWindow() end end)
  icon:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      AHSnapshotDB.iconAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
      PlaceIcon()
    end)
  end)
  icon:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

  PlaceIcon()
  if AHSnapshotDB.iconHidden then icon:Hide() end
  UpdateIcon()
  C_Timer.NewTicker(1, UpdateIcon)
end

local function SlashHandler(msg)
  msg = (msg or ""):lower()
  local cmd, arg = msg:match("^(%S*)%s*(.-)$")
  local ah, rk = GetAH()

  if cmd == "show" then
    S.ToggleWindow()
  elseif cmd == "top" then
    local days = tonumber(arg) or 7
    local all, covered = S.Analyze(S.GetSources(true), S.Now(), days, AHSnapshotDB.items)
    local list = {}
    for _, r in ipairs(all) do if r.sold > 0 then list[#list + 1] = r end end
    S.SortList(list, "soldPerDay", false)   -- 低可信度的排在可信的後面
    if #list == 0 then Print("最近 " .. days .. " 天還沒有推估資料（至少要掃兩次）。"); return end
    Print(string.format("最近 %d 天推估賣出排行（估算，有效觀察 %.1f 小時，%s）：", days, covered / 3600, rk))
    for i = 1, math.min(15, #list) do
      local r = list[i]
      local line = string.format("%2d. %s  每日約 %s 件（%d 筆成交）  中位價 %s", i, r.name or r.key,
        S.FormatEstimate(r.soldPerDay), r.soldN, Money(r.med))
      if r.lowConf then line = "|cff888888" .. line .. "  資料不足，僅供參考|r" end
      Print(line)
    end
  elseif cmd == "next" then
    Print(WaitText())
  elseif cmd == "remind" then
    if tonumber(arg) then
      AHSnapshotDB.remindMin = math.max(15, math.floor(tonumber(arg)))
      Print("全掃後 " .. AHSnapshotDB.remindMin .. " 分鐘燈號變紅（最短 15 分鐘）。")
      UpdateIcon()
    else
      Print("用法：/ahsnap remind 分鐘（目前 " .. (AHSnapshotDB.remindMin or 15) .. " 分鐘）。想推估賣出量，兩次掃描間隔 30 分～2 小時最好。")
    end
  elseif cmd == "icondebug" then
    if not icon then Print("燈號沒有建立（找不到 Minimap？）"); return end
    local l = icon.light
    Print(string.format("按鈕 顯示=%s 透明度=%.2f 層級=%s/%d 大小=%dx%d",
      tostring(icon:IsVisible()), icon:GetEffectiveAlpha(), icon:GetFrameStrata(), icon:GetFrameLevel(), icon:GetWidth(), icon:GetHeight()))
    Print(string.format("燈 貼圖=%s 顯示=%s 透明度=%.2f 顏色=%.2f,%.2f,%.2f",
      tostring(l:GetTexture()), tostring(l:IsVisible()), l:GetAlpha(), l:GetVertexColor()))
  elseif cmd == "icon" then
    AHSnapshotDB.iconHidden = not AHSnapshotDB.iconHidden
    if icon then if AHSnapshotDB.iconHidden then icon:Hide() else icon:Show() end end
    Print(AHSnapshotDB.iconHidden and "已隱藏小地圖燈號，再打 /ahsnap icon 顯示。" or "已顯示小地圖燈號。")
  elseif cmd == "share" then
    local names = SharedNames()
    if #names == 0 then
      Print("還沒有朋友的資料。朋友的資料由同步工具（AHSync）在遊戲關閉時寫進來，下次登入時匯入。")
    else
      for _, src in ipairs(names) do
        local n, last = 0, nil
        for _, a in pairs(AHSnapshotDB.shared[src]) do
          n = n + #(a.scans or {})
          local l = a.scans and a.scans[#a.scans]
          if l and (not last or l.t > last) then last = l.t end
        end
        Print(string.format("%s：%d 次掃描，最新 %s", src, n, last and date("%m/%d %H:%M", last) or "-"))
      end
    end
    Print(string.format("分享給朋友、和朋友合併的是最近 %d 天的逐次掃描；更早的濃縮成每日紀錄（只存在自己電腦）。",
      AHSnapshotDB.detailDays))
  elseif cmd == "detail" then
    local d = tonumber(arg)
    if d and d >= 1 and d <= 14 then
      AHSnapshotDB.detailDays = math.floor(d)
      Print("逐次掃描保留 " .. AHSnapshotDB.detailDays .. " 天（也是分享給朋友的天數），更早的濃縮成每日紀錄。")
      S.Rollup()
    else
      Print("用法：/ahsnap detail 天數（1～14，目前 " .. AHSnapshotDB.detailDays .. " 天）。天數越多存檔越大；朋友的資料要在這段時間內送到才算得進去。")
    end
  elseif cmd == "keep" then
    local d = tonumber(arg)
    if d and d >= 1 then
      AHSnapshotDB.dailyDays = math.floor(d)
      Print("每日紀錄保留 " .. AHSnapshotDB.dailyDays .. " 天。")
      S.Rollup()
    else
      Print("用法：/ahsnap keep 天數（目前每日紀錄保留 " .. AHSnapshotDB.dailyDays .. " 天）")
    end
  elseif cmd == "reset" then
    if arg == "confirm" then
      AHSnapshotDB.realms[rk] = nil
      Print("已清除 " .. rk .. " 的所有快照。")
    else
      Print("會清除 " .. rk .. " 的所有快照，確定請輸入 /ahsnap reset confirm")
    end
  else
    local scans = ah.scans or {}
    local last = scans[#scans]
    local nDays = 0
    for _ in pairs(ah.daily or {}) do nDays = nDays + 1 end
    Print(string.format("%s：逐次掃描 %d 次（保留 %d 天）、每日紀錄 %d 天（保留 %d 天）。",
      rk, #scans, AHSnapshotDB.detailDays, nDays, AHSnapshotDB.dailyDays))
    if last then
      Print(string.format("上次掃描：%s，%d 筆上架。", date("%m/%d %H:%M", last.t), last.n))
    end
    Print(WaitText())
    Print("在拍賣場用 Auctionator 的「Scan」做全掃，本插件會自動記錄。")
    Print("/ahsnap show 分析視窗｜top [天數] 賣出排行｜next 距下次掃描｜remind 分鐘 燈號間隔｜icon 顯示/隱藏燈號｜share 朋友資料｜detail 天數 逐次掃描保留｜keep 天數 每日紀錄保留｜reset")
  end
end

-- 登入時匯入同步工具寫進來的朋友資料，匯入後清空
local function ImportInbox()
  local text = AHSnapshotInbox
  AHSnapshotInbox = nil
  local db = AHSnapshotDB
  local now = S.Now()
  if type(text) == "string" and text ~= "" then
    local ok, added = pcall(S.ImportInbox, db, text, now, nil)
    if not ok then
      db.lastError = { t = time(), err = "匯入朋友資料失敗：" .. tostring(added) }
      Print("|cffff4444匯入朋友資料失敗：|r" .. tostring(added))
    else
      local parts = {}
      for src, n in pairs(added) do parts[#parts + 1] = src .. " " .. n .. " 次" end
      table.sort(parts)
      if #parts > 0 then Print("已匯入朋友的掃描：" .. table.concat(parts, "、")) end
    end
  end
end

-- 登出（含 /reload）時，把自己的掃描寫成文字，讓同步工具上傳
local function ExportOutbox()
  local ok, text = pcall(S.ExportOutbox, AHSnapshotDB, S.Now(), AHSnapshotDB.detailDays)
  if ok then AHSnapshotOutbox = text
  else AHSnapshotDB.lastError = { t = time(), err = "匯出失敗：" .. tostring(text) } end
  -- 物品資料改成一行字串再存（登入時展開），存檔小很多
  pcall(S.PackItems, AHSnapshotDB.items)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_LOGOUT")
f:SetScript("OnEvent", function(_, event, ...)
  if event == "GET_ITEM_INFO_RECEIVED" then OnItemInfo(...); return end
  if event == "PLAYER_LOGOUT" then
    if AHSnapshotDB and AHSnapshotDB.realms then ExportOutbox() end
    return
  end
  local isNew = AHSnapshotDB == nil
  AHSnapshotDB = AHSnapshotDB or {}
  local db = AHSnapshotDB
  if isNew then db.version = S.DB_VERSION end
  -- 舊版的賣出推估有誤：清掉推估、保留價格，只做一次
  if S.MigrateToV3(db) then
    Print("舊版的賣出推估有誤（會把撤單、部分購買算成賣出），已清除；價格與架上量紀錄都保留。下次全掃後重新開始推估。")
  end
  if S.MigrateToV4(db) then
    Print("存檔格式更新：逐次掃描保留 3 天，更早的濃縮成每日紀錄（保留 30 天），存檔不會再一直變大。可用 /ahsnap detail、/ahsnap keep 調整。")
  end
  db.version = S.DB_VERSION
  db.realms = db.realms or {}
  db.items = db.items or {}
  db.shared = db.shared or {}
  db.detailDays = db.detailDays or 3
  db.dailyDays = db.dailyDays or 30
  db.fields = S.ROW_FIELDS
  S.UnpackItems(db.items)
  MigrateOldKeys()
  ImportInbox()
  S.Rollup()
  f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  C_Timer.After(5, FetchMissingItems)

  if not (Auctionator and Auctionator.EventBus and Auctionator.FullScan and Auctionator.FullScan.Events) then
    Print("|cffff4444找不到 Auctionator，無法運作。|r")
    return
  end
  local E = Auctionator.FullScan.Events
  Auctionator.EventBus:Register({
    ReceiveEvent = function(_, eventName, rawFullScan)
      OnScanComplete(rawFullScan)
    end,
  }, { E.ScanComplete })

  SLASH_AHSNAPSHOT1 = "/ahsnap"
  SlashCmdList.AHSNAPSHOT = SlashHandler
  CreateIcon()  -- 燈號每秒依 Auctionator 的上次全掃時間更新，/reload 也會接續
end)
