-- AH Snapshot 分析視窗：價量排行表＋單品明細
local S = AHSnapshot

local ROWS, ROW_H = 18, 20
local W, H = 890, 540

-- 欄位：key＝排序用欄位，fmt＝顯示方式，est＝推估值（前面加「約」，低可信度變灰色加「?」）
local COLS = {
  { key = "name",        title = "物品",           w = 180, align = "LEFT" },
  { key = "qty",         title = "架上",           w = 50,  fmt = "int" },
  { key = "min",         title = "最低價",         w = 75,  fmt = "money" },
  { key = "med",         title = "中位價",         w = 75,  fmt = "money" },
  { key = "sold",        title = "賣出(估)",       w = 60,  fmt = "int",   est = true },
  { key = "soldN",       title = "成交筆數",       w = 55,  fmt = "int" },
  { key = "soldPerDay",  title = "每日賣出(估)",   w = 80,  fmt = "dec",   est = true },
  { key = "avgSold",     title = "成交均價(估)",   w = 80,  fmt = "money", est = true, conf = "avgLowConf" },
  { key = "sellThrough", title = "賣出率(估)",     w = 65,  fmt = "pct",   est = true },
  { key = "valuePerDay", title = "每日成交額(估)", w = 100, fmt = "money", est = true },
}
local EST_NOTE = "\n\n(估)＝推估值：從上架消失推估，不是遊戲給的成交紀錄。灰色加 ? ＝成交少於 3 筆或有效觀察不到 12 小時，僅供參考。"
local TIPS = {
  qty = "最新一次掃描時架上的總數量",
  min = "最新一次掃描的最低直購單價",
  med = "最新一次掃描的中位單價（依數量加權）",
  sold = "推估被買走的數量。材料類只算從最低價往上被吃掉的部分；高價層單獨減少算撤單。裝備類沒有賣家資料，撤單沒重上也會被算進來。" .. EST_NOTE,
  soldN = "看到幾次成交：材料類是被吃掉的價位層數（一整疊被買走只算 1 次），裝備類是件數。少於 3 筆時其他推估僅供參考。",
  soldPerDay = "賣出 ÷ 有效觀察天數。觀察不滿 1 天時以 1 天計算，不往上放大，所以不會超過實際看到的量。" .. EST_NOTE,
  avgSold = "被買走那些拍賣的平均單價（實際成交價）。只來自 1～2 筆成交時容易偏差，會標成灰色。" .. EST_NOTE,
  sellThrough = "賣出 ÷（賣出＋可能到期）。越高代表上架越容易賣掉。" .. EST_NOTE,
  valuePerDay = "每日賣出 × 成交價，代表市場大小。觀察不滿 1 天時以 1 天計算，不往上放大。" .. EST_NOTE,
}

local state = { days = 7, sort = "valuePerDay", asc = false, text = "", onlySold = true, offset = 0, includeShared = true }
local frame, detail
local data, view, covered, nDiff, nSources, nDays = {}, {}, 0, 0, 1, 0

local function Bg(f, r, g, b, a)
  local t = f:CreateTexture(nil, "BACKGROUND")
  t:SetAllPoints()
  t:SetColorTexture(r, g, b, a)
  return t
end

local function Fmt(v, fmt)
  if fmt == "money" then return (v and v > 0) and S.Money(math.floor(v + 0.5)) or "-" end
  if fmt == "int" then return tostring(math.floor((v or 0) + 0.5)) end
  if fmt == "dec" then return S.FormatEstimate(v) end
  if fmt == "pct" then return (v and v >= 0) and string.format("%d%%", v * 100 + 0.5) or "-" end
  return tostring(v or "")
end

-- 推估欄位：有數字就加「約」；低可信度灰色加「?」
local function FmtCell(r, col)
  local text = Fmt(r[col.key], col.fmt)
  if not col.est then return text end
  local empty = text == "-" or text == "0" or text == "0%"
  if not empty then text = "約" .. text end
  local low = r[col.conf or "lowConf"] or r.lowConf
  if low and not empty then return "|cff888888" .. text .. "?|r" end
  if low then return "|cff888888" .. text .. "|r" end
  return text
end

local QUALITY = { [0] = "ff9d9d9d", [1] = "ffffffff", [2] = "ff1eff00", [3] = "ff0070dd", [4] = "ffa335ee", [5] = "ffff8000" }

local function ItemIDOf(key) return tonumber((tostring(key):match("^(%-?%d+)"))) end

local Refresh, ShowDetail

local function Recompute()
  data, covered, nDiff, nSources, nDays = S.Analyze(S.GetSources(state.includeShared), S.Now(), state.days, AHSnapshotDB.items)
  Refresh()
end

Refresh = function()
  if not frame then return end
  view = S.FilterList(data, state.text, state.onlySold and (nDiff > 0 or nDays > 0))  -- 還沒比對過就先顯示全部
  S.SortList(view, state.sort, state.asc)
  local maxOff = math.max(0, #view - ROWS)
  if state.offset > maxOff then state.offset = maxOff end

  for i, row in ipairs(frame.rows) do
    local r = view[state.offset + i]
    row.item = r
    if r then
      for c, col in ipairs(COLS) do
        local text
        if col.key == "name" then
          local color = QUALITY[r.quality or 1] or QUALITY[1]
          text = "|c" .. color .. (r.name or r.key) .. "|r"
        else
          text = FmtCell(r, col)
        end
        row.cells[c]:SetText(text)
      end
      row:Show()
    else
      row:Hide()
    end
  end

  for _, h in ipairs(frame.headers) do
    local mark = (h.col.key == state.sort) and (state.asc and " ^" or " v") or ""
    h.text:SetText(h.col.title .. mark)
  end
  for _, b in ipairs(frame.dayButtons) do
    b:SetText((b.days == state.days and "|cffffd100" or "") .. b.days .. " 天" .. (b.days == state.days and "|r" or ""))
  end
  frame.ahButton:SetText("拍賣場：" .. S.AHKeyLabel(S.ViewKey()))
  frame.soldToggle:SetText(state.onlySold and "只看有賣出：開" or "只看有賣出：關")
  frame.sharedToggle:SetText(state.includeShared and "包含朋友資料：開" or "包含朋友資料：關")

  local hours = covered / 3600
  local first = #view > 0 and (state.offset + 1) or 0
  frame.footer:SetText(string.format(
    "有效觀察 %.1f 小時（%d 次比對，%d 個來源%s）｜第 %d–%d 項，共 %d 項｜滾輪捲動，點一列看明細",
    hours, nDiff, nSources, nDays > 0 and string.format("＋%d 天每日紀錄", nDays) or "",
    first, math.min(state.offset + ROWS, #view), #view))
  if nDiff == 0 and nDays == 0 then
    frame.footer:SetText(S.AHKeyLabel(S.ViewKey()) .. " 拍賣場還沒有可比對的掃描：同一個拍賣場隔 30 分～2 小時再全掃一次，就會有賣出資料。")
  end
  frame.note:SetText(string.format(
    "(估)＝從上架消失推估，賣家撤單沒重上也可能被算成賣出｜觀察不滿 1 天不放大成每日｜|cff888888灰色 ?|r＝成交少於 %d 筆或觀察不到 %d 小時，僅供參考",
    S.CONF_MIN_SALES, S.CONF_MIN_HOURS))
end

local function Scroll(delta)
  state.offset = math.max(0, state.offset - delta * 3)
  Refresh()
end

local function MakeButton(parent, text, w)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
  return b
end

local function CreateDetail()
  detail = CreateFrame("Frame", "AHSnapshotDetailFrame", frame)
  detail:SetSize(400, H)
  detail:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
  Bg(detail, 0.05, 0.05, 0.07, 0.95)
  detail:EnableMouse(true)

  local close = CreateFrame("Button", nil, detail, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)

  detail.title = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  detail.title:SetPoint("TOPLEFT", 12, -12)
  detail.title:SetPoint("RIGHT", -30, 0)
  detail.title:SetJustifyH("LEFT")

  detail.summary = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  detail.summary:SetPoint("TOPLEFT", 12, -40)
  detail.summary:SetPoint("RIGHT", -12, 0)
  detail.summary:SetJustifyH("LEFT")
  detail.summary:SetSpacing(3)

  -- 歷史表：每欄一個多行文字框，才會對齊（WoW 字型不是等寬）
  detail.cols = {}
  local DCOLS = { { "時間", 80, "LEFT" }, { "架上", 45 }, { "最低價", 70 }, { "中位價", 70 }, { "賣出", 40 }, { "來源", 60, "LEFT" } }
  local dx = 12
  for i, c in ipairs(DCOLS) do
    local fs = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", dx, -190)
    fs:SetWidth(c[2])
    fs:SetJustifyH(c[3] or "RIGHT")
    fs:SetJustifyV("TOP")
    fs:SetSpacing(2)
    fs.head = c[1]
    detail.cols[i] = fs
    dx = dx + c[2] + 4
  end
  detail:Hide()
end

ShowDetail = function(r)
  if not detail then CreateDetail() end
  detail.title:SetText(r.name or r.key)
  local lines = {
    string.format("最近 %d 天（估算）：賣出約 %d、可能到期 %d、撤單/重上 %d、新上架 %d",
      state.days, r.sold, r.expired, r.repost, r.new),
    string.format("成交筆數 %d｜有效觀察 %.1f 小時｜每日賣出約 %s",
      r.soldN or 0, r.observedHours or 0, S.FormatEstimate(r.soldPerDay)),
    string.format("成交均價約 %s｜中位價 %s｜賣出率約 %s",
      Fmt(r.avgSold, "money"), Fmt(r.med, "money"), Fmt(r.sellThrough, "pct")),
    string.format("中位價變化 %s｜商店收購價 %s",
      (r.trend ~= 0 and string.format("%+d%%", r.trend * 100 + (r.trend > 0 and 0.5 or -0.5)) or "持平"),
      Fmt(r.sell, "money")),
  }
  -- 可信度說明
  if (r.soldN or 0) < S.CONF_MIN_SALES then
    lines[#lines + 1] = string.format("|cffaaaaaa只觀察到 %d 次成交，每日數字僅供參考。|r", r.soldN or 0)
  elseif (r.observedHours or 0) < S.CONF_MIN_HOURS then
    lines[#lines + 1] = string.format("|cffaaaaaa有效觀察只有 %.1f 小時，每日數字僅供參考。|r", r.observedHours or 0)
  elseif r.avgLowConf then
    lines[#lines + 1] = "|cffaaaaaa成交均價只來自 1～2 筆成交，可能有偏差。|r"
  end
  local info = AHSnapshotDB.items and AHSnapshotDB.items[r.key]
  if info and info.stack == 1 then
    lines[#lines + 1] = "|cffaaaaaa裝備類：全掃沒有賣家資料，撤單沒重上也會被算成賣出。|r"
  end
  if r.sell and r.sell > 0 and r.min > 0 and r.min < r.sell then
    lines[#lines + 1] = "|cff33ff33最低價低於商店收購價，買下直接賣店有賺|r"
  end
  detail.summary:SetText(table.concat(lines, "\n"))

  local hist = S.History(S.GetSources(state.includeShared), r.key, 22)
  local cols = {}
  for i, fs in ipairs(detail.cols) do cols[i] = { "|cffffd100" .. fs.head .. "|r" } end
  for _, h in ipairs(hist) do
    -- 每日紀錄：架上＝當天最多、最低價＝當天最低、中位價＝當天平均，來源是合併後的
    local v = { h.daily and (date("%m/%d", h.t) .. " 全天") or date("%m/%d %H:%M", h.t), tostring(h.qty),
                Fmt(h.min, "money"), Fmt(h.med, "money"),
                h.diff == 1 and tostring(h.sold) or "-", h.daily and "每日合併" or (h.source or "自己") }
    for i = 1, #cols do cols[i][#cols[i] + 1] = v[i] end
  end
  for i, fs in ipairs(detail.cols) do fs:SetText(table.concat(cols[i], "\n")) end
  detail:Show()
end

local function CreateWindow()
  frame = CreateFrame("Frame", "AHSnapshotFrame", UIParent)
  frame:SetSize(W, H)
  frame:SetPoint("CENTER", -170, 0)
  frame:SetFrameStrata("DIALOG")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetClampedToScreen(true)
  Bg(frame, 0.05, 0.05, 0.07, 0.95)
  table.insert(UISpecialFrames, "AHSnapshotFrame")  -- Esc 關閉

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 12, -12)
  title:SetText("AH Snapshot 價量分析")
  frame.title = title

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)

  -- 拍賣場切換：左鍵下一個、右鍵上一個；清單＝有資料的拍賣場＋目前所在
  local ahButton = MakeButton(frame, "", 190)
  ahButton:SetPoint("LEFT", title, "RIGHT", 16, 0)
  ahButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  local function ShowAHTip(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("拍賣場（左鍵下一個、右鍵上一個）", 1, 0.82, 0)
    local view, here = S.ViewKey(), S.AHRoot()
    for _, k in ipairs(S.ListViewKeys()) do
      local own, friends, days = S.CountAHKey(AHSnapshotDB, k)
      local line = string.format("%s%s：自己 %d 次、朋友 %d 次、每日 %d 天%s", k == view and "> " or "   ",
        S.AHKeyLabel(k), own, friends, days, k == here and "（目前所在）" or "")
      if k == view then GameTooltip:AddLine(line, 1, 0.82, 0) else GameTooltip:AddLine(line, 1, 1, 1) end
    end
    GameTooltip:AddLine("聯盟、部落、中立（藏寶海灣／加基森／永望鎮）是三個不同的拍賣場，資料分開算。", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end
  ahButton:SetScript("OnClick", function(self, button)
    local keys, cur = S.ListViewKeys(), S.ViewKey()
    if #keys == 0 then return end
    local idx = 1
    for i, k in ipairs(keys) do if k == cur then idx = i end end
    idx = idx + (button == "RightButton" and -1 or 1)
    if idx > #keys then idx = 1 elseif idx < 1 then idx = #keys end
    S.SetViewKey(keys[idx])
    if GameTooltip:IsOwned(self) then ShowAHTip(self) end
  end)
  ahButton:SetScript("OnEnter", ShowAHTip)
  ahButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.ahButton = ahButton

  -- 天數
  frame.dayButtons = {}
  local prev
  for _, d in ipairs({ 1, 3, 7, 30 }) do
    local b = MakeButton(frame, d .. " 天", 56)
    b.days = d
    if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 12, -40) end
    b:SetScript("OnClick", function() state.days = d; state.offset = 0; Recompute() end)
    frame.dayButtons[#frame.dayButtons + 1] = b
    prev = b
  end

  -- 搜尋
  local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("LEFT", prev, "RIGHT", 16, 0)
  label:SetText("搜尋")
  local box = CreateFrame("EditBox", "AHSnapshotSearchBox", frame, "InputBoxTemplate")
  box:SetSize(160, 20)
  box:SetPoint("LEFT", label, "RIGHT", 10, 0)
  box:SetAutoFocus(false)
  box:SetScript("OnTextChanged", function(self)
    state.text = self:GetText() or ""
    state.offset = 0
    Refresh()
  end)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

  local soldToggle = MakeButton(frame, "", 130)
  soldToggle:SetPoint("LEFT", box, "RIGHT", 12, 0)
  soldToggle:SetScript("OnClick", function() state.onlySold = not state.onlySold; state.offset = 0; Refresh() end)
  frame.soldToggle = soldToggle

  local sharedToggle = MakeButton(frame, "", 140)
  sharedToggle:SetPoint("LEFT", soldToggle, "RIGHT", 6, 0)
  sharedToggle:SetScript("OnClick", function()
    state.includeShared = not state.includeShared
    state.offset = 0
    Recompute()
  end)
  sharedToggle:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("包含朋友資料", 1, 0.82, 0)
    GameTooltip:AddLine(string.format("只影響最近 %d 天的逐次掃描。更早的每日紀錄是自己和朋友合併後濃縮的，一律包含。",
      AHSnapshotDB.detailDays or 3), 1, 1, 1, true)
    GameTooltip:Show()
  end)
  sharedToggle:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.sharedToggle = sharedToggle

  -- 欄位標題（點了排序）
  frame.headers = {}
  local x = 12
  for _, col in ipairs(COLS) do
    local h = CreateFrame("Button", nil, frame)
    h:SetSize(col.w, ROW_H)
    h:SetPoint("TOPLEFT", x, -72)
    h.col = col
    h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h.text:SetAllPoints()
    h.text:SetJustifyH(col.align or "RIGHT")
    h:SetScript("OnClick", function()
      if state.sort == col.key then state.asc = not state.asc
      else state.sort = col.key; state.asc = (col.key == "name") end
      state.offset = 0
      Refresh()
    end)
    if TIPS[col.key] then
      h:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(col.title)
        GameTooltip:AddLine(TIPS[col.key], 1, 1, 1, true)
        GameTooltip:Show()
      end)
      h:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    frame.headers[#frame.headers + 1] = h
    x = x + col.w + 4
  end

  -- 資料列
  frame.rows = {}
  for i = 1, ROWS do
    local row = CreateFrame("Button", nil, frame)
    row:SetSize(W - 24, ROW_H)
    row:SetPoint("TOPLEFT", 12, -72 - i * ROW_H)
    if i % 2 == 0 then Bg(row, 1, 1, 1, 0.04) end
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.15)
    row.cells = {}
    local cx = 0
    for c, col in ipairs(COLS) do
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetSize(col.w, ROW_H)
      fs:SetPoint("LEFT", cx, 0)
      fs:SetJustifyH(col.align or "RIGHT")
      fs:SetWordWrap(false)
      row.cells[c] = fs
      cx = cx + col.w + 4
    end
    row:SetScript("OnClick", function(self) if self.item then ShowDetail(self.item) end end)
    row:SetScript("OnEnter", function(self)
      local id = self.item and ItemIDOf(self.item.key)
      if id then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if not pcall(GameTooltip.SetItemByID, GameTooltip, id) then GameTooltip:AddLine(self.item.name) end
        GameTooltip:Show()
      end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.rows[i] = row
  end

  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(_, delta) Scroll(delta) end)

  local down = MakeButton(frame, "下一頁", 70)
  down:SetPoint("BOTTOMRIGHT", -12, 10)
  down:SetScript("OnClick", function() Scroll(-ROWS / 3) end)
  local up = MakeButton(frame, "上一頁", 70)
  up:SetPoint("RIGHT", down, "LEFT", -4, 0)
  up:SetScript("OnClick", function() Scroll(ROWS / 3) end)

  frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.footer:SetPoint("BOTTOMLEFT", 12, 14)
  frame.footer:SetPoint("RIGHT", up, "LEFT", -8, 0)
  frame.footer:SetJustifyH("LEFT")

  frame.note = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.note:SetPoint("BOTTOMLEFT", 12, 40)
  frame.note:SetPoint("RIGHT", -12, 0)
  frame.note:SetJustifyH("LEFT")

  frame:SetScript("OnShow", Recompute)
end

function S.ToggleWindow()
  if not frame then CreateWindow(); frame:Show(); Recompute(); return end
  if frame:IsShown() then frame:Hide() else frame:Show() end
end

-- 掃描完成後，視窗開著就更新
function S.OnDataChanged()
  if frame and frame:IsShown() then Recompute() end
end

-- 換了檢視的拍賣場：從頭顯示，明細關掉（那是別的拍賣場的）
function S.OnViewKeyChanged()
  state.offset = 0
  if detail then detail:Hide() end
  if frame and frame:IsShown() then Recompute() end
end
