-- AH Snapshot 核心邏輯：不碰遊戲 UI，只處理資料（離線測試直接載入這個檔）
AHSnapshot = AHSnapshot or {}
local S = AHSnapshot

S.DB_VERSION = 4   -- 2：加 shared（朋友資料）；3：賣出推估改成依單價分層，清掉舊推估；4：列去尾端 0、物品資料精簡、每日彙整
S.EST_VERSION = 2  -- 賣出推估演算法版本：1＝逐筆指紋（有誤，已停用），2＝依單價分層
S.ESTIMATE_ROW_FROM = 6  -- 列欄位第 6 欄起（sold 以後）是推估值；前 5 欄（量與價格）一直是正確的

-- 剩餘時間分級（插件內統一用 1～4）：1 = 30 分內、2 = 30 分～2 小時、3 = 2 小時以上、4 = 很長。
-- 新式拍賣場正式服「很長」是 12 小時以上；Forever 最長只上架 24 小時，分界未確認，
-- 所以這裡取比較保守的 8 小時（寧可少算賣出，不要把到期算成賣出）。
-- 值 = 這一級「至少還剩」幾秒。前後兩次掃描間隔比這還短就消失的拍賣，不可能是到期下架。
S.TL_MIN = { [1] = 0, [2] = 1800, [3] = 7200, [4] = 28800 }

-- 物品鍵：物品 ID，有隨機屬性（xx之猴…）就加上後綴 ID，例如 "15211:-19"
function S.ItemKey(link, itemID)
  if type(link) == "string" then
    local id, suffix = link:match("item:(%-?%d+):[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:(%-?%d*)")
    if not id then id = link:match("item:(%-?%d+)") end
    if id then
      suffix = tonumber(suffix) or 0
      if suffix ~= 0 then return id .. ":" .. suffix end
      return id
    end
  end
  if itemID and itemID ~= 0 then return tostring(itemID) end
  return nil
end

-- listings: { {key=, count=, buyout=, minBid=, owner=, tl=}, ... }
-- 回傳 byKey[key] = { 該物品的上架陣列 }
function S.GroupByKey(listings)
  local byKey = {}
  for _, l in ipairs(listings) do
    local t = byKey[l.key]
    if not t then t = {}; byKey[l.key] = t end
    t[#t + 1] = l
  end
  return byKey
end

-- 依數量加權的分位數單價（只算有直購價的）
local function WeightedQuantile(prices, q)
  -- prices: { {unit=, count=}, ... } 已排序
  local total = 0
  for _, p in ipairs(prices) do total = total + p.count end
  if total == 0 then return 0 end
  local target = total * q
  local acc = 0
  for _, p in ipairs(prices) do
    acc = acc + p.count
    if acc >= target then return p.unit end
  end
  return prices[#prices].unit
end

-- 一個物品在這次掃描的統計
function S.Aggregate(list)
  local qty, prices = 0, {}
  for _, l in ipairs(list) do
    qty = qty + l.count
    if l.buyout > 0 and l.count > 0 then
      prices[#prices + 1] = { unit = math.ceil(l.buyout / l.count), count = l.count }
    end
  end
  table.sort(prices, function(a, b) return a.unit < b.unit end)
  local minUnit = prices[1] and prices[1].unit or 0
  return {
    qty = qty,
    listings = #list,
    min = minUnit,
    p25 = WeightedQuantile(prices, 0.25),
    med = WeightedQuantile(prices, 0.5),
  }
end

-- ---- 依單價分層比對（v1.2 起；說明見 DESIGN.md「賣出推估」）----
-- Forever 的全掃沒有賣家名字，也沒有拍賣編號，所以不比對「哪一筆」，而是比對
-- 每個物品「每個直購單價有多少數量」。一層 = 同一單價的所有上架：
--   tier = { qty = 總數量, tl = { [1..4] = 各剩餘時間分級的數量 } }
-- 直購價 0（只能競標）放在單價 0 這一層：它不會被直購，消失一律算可能到期。

S.PREV_VERSION = 2

-- 單價（直購總價 ÷ 數量，無條件進位，跟 Aggregate 一致）
local function UnitOf(l)
  if not l.buyout or l.buyout <= 0 or l.count <= 0 then return 0 end
  return math.ceil(l.buyout / l.count)
end

-- 一個物品本次的上架 → 分層
function S.BuildTiers(list)
  local tiers = {}
  for _, l in ipairs(list or {}) do
    local u = UnitOf(l)
    local t = tiers[u]
    if not t then t = { qty = 0, tl = { 0, 0, 0, 0 } }; tiers[u] = t end
    t.qty = t.qty + l.count
    local b = tonumber(l.tl) or 1          -- 不知道剩餘時間就當最短（可能到期）
    if b < 1 or b > 4 then b = 1 end
    t.tl[b] = t.tl[b] + l.count
  end
  return tiers
end

-- 可堆疊商品（材料等）：物品資料的堆疊上限 > 1；不知道時看有沒有一次賣好幾個的上架
function S.IsStackable(info, list, prevFlag)
  if info and info.stack then return info.stack > 1 end
  for _, l in ipairs(list or {}) do if l.count > 1 then return true end end
  return prevFlag == true
end

-- 存成字串："2|s|單價:數量:分級1,分級2,分級3,分級4;..."（s＝可堆疊，u＝不可堆疊）
function S.PackTiers(tiers, stackable)
  local units = {}
  for u in pairs(tiers) do units[#units + 1] = u end
  table.sort(units)
  local parts = {}
  for i, u in ipairs(units) do
    local t = tiers[u]
    parts[i] = u .. ":" .. t.qty .. ":" .. table.concat(t.tl, ",")
  end
  return S.PREV_VERSION .. "|" .. (stackable and "s" or "u") .. "|" .. table.concat(parts, ";")
end

-- 解析上面的字串；不是這個格式（例如 1.1 版的逐筆指紋）回傳 nil
function S.UnpackTiers(s)
  if type(s) ~= "string" then return nil end
  local ver, flag, body = s:match("^(%d+)|(%a)|(.*)$")
  if tonumber(ver) ~= S.PREV_VERSION then return nil end
  local tiers = {}
  for u, q, a, b, c, d in body:gmatch("(%d+):(%d+):(%d+),(%d+),(%d+),(%d+)") do
    tiers[tonumber(u)] = { qty = tonumber(q), tl = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) } }
  end
  return tiers, flag == "s"
end

-- 這一層減少的數量裡，有多少「可能是到期」：剩餘時間下限 ≤ 間隔的那些分級
local function SplitDecrease(tier, dec, gap)
  local expirable = 0
  for b = 1, 4 do
    if gap >= S.TL_MIN[b] then expirable = expirable + (tier.tl[b] or 0) end
  end
  local exp = math.min(dec, expirable)   -- 先算到「可能到期」，寧可少算賣出
  return dec - exp, exp
end

-- 兩個數量算不算「一樣」（換價重上）：差距在 5% 以內
local function Close(a, b)
  return math.abs(a - b) <= math.floor(math.max(a, b) * 0.05)
end

-- 比對同一個物品前後兩次的分層。
-- 回傳 { sold, soldN, expired, repost, new, soldValue }
--   sold      ＝推估被買走的數量
--   soldN     ＝成交筆數：可堆疊商品是「被吃掉的價位層數」，不可堆疊商品是件數
--   expired   ＝可能是到期下架（分不出來的都放這裡）
--   repost    ＝撤單或換價重上（不算賣出）
--   new       ＝新上架數量
--   soldValue ＝被買走的總金額（數量 × 該層單價）
function S.DiffTiers(prev, cur, gap, stackable)
  local r = { sold = 0, soldN = 0, expired = 0, repost = 0, new = 0, soldValue = 0 }
  prev, cur = prev or {}, cur or {}

  local units, seen = {}, {}
  for u in pairs(prev) do if not seen[u] then seen[u] = true; units[#units + 1] = u end end
  for u in pairs(cur) do if not seen[u] then seen[u] = true; units[#units + 1] = u end end
  table.sort(units)

  local dec, incs = {}, {}
  for _, u in ipairs(units) do
    local d = (cur[u] and cur[u].qty or 0) - (prev[u] and prev[u].qty or 0)
    if u == 0 then
      -- 只能競標的：減少算到期，增加算新上架
      if d < 0 then r.expired = r.expired - d elseif d > 0 then r.new = r.new + d end
    elseif d < 0 then dec[u] = -d
    elseif d > 0 then incs[#incs + 1] = { unit = u, qty = d } end
  end

  -- 找一筆還沒用掉、數量相近、單價符合條件的新增，當成換價重上
  local function TakeIncrease(qty, ok)
    for _, inc in ipairs(incs) do
      if not inc.used and Close(inc.qty, qty) and ok(inc.unit) then inc.used = true; return true end
    end
    return false
  end
  local anyPrice = function() return true end

  if stackable then
    -- 買家一定從最便宜的買起：只有從最低價往上「連續被吃掉」的層才算賣出
    local bottom = true
    for _, u in ipairs(units) do
      local p = prev[u]
      if u > 0 and p and p.qty > 0 then
        local d = dec[u] or 0
        local dTotal = d
        if bottom and d > 0 then
          if TakeIncrease(d, function(iu) return iu < u end) then
            -- 同樣數量出現在更便宜的價位：賣家撤下壓價重上，不是被買
            r.repost = r.repost + d
          else
            -- 被買走一部分後剩下的壓價重上：更便宜價位的新上架先抵掉減少量（寧可少算賣出）
            local rep = 0
            for _, inc in ipairs(incs) do
              if not inc.used and inc.unit < u and rep < d then
                local take = math.min(inc.qty - (inc.taken or 0), d - rep)
                rep = rep + take
                inc.taken = (inc.taken or 0) + take
                if inc.taken >= inc.qty then inc.used = true end
              end
            end
            r.repost = r.repost + rep
            d = d - rep
            local sold, exp = SplitDecrease(p, d, gap)
            r.expired = r.expired + exp
            if sold > 0 then
              r.sold = r.sold + sold
              r.soldN = r.soldN + 1
              r.soldValue = r.soldValue + sold * u
            end
          end
          if dTotal < p.qty then bottom = false end   -- 只吃掉一部分：更貴的層買家碰不到
        elseif d > 0 then
          -- 更便宜的還在，這層卻少了：撤單（或到期），不是被買
          local _, exp = SplitDecrease(p, d, gap)
          r.expired = r.expired + exp
          r.repost = r.repost + (d - exp)
          TakeIncrease(d - exp, anyPrice)        -- 換到別的價位重上的那筆不要再算新上架
        else
          bottom = false                         -- 這層沒動：上面的層都不是被買走的
        end
      end
    end
  else
    -- 不可堆疊（裝備等）：每件 1 個，買家可以挑任何一件。沒有賣家名字，撤單也會被算成賣出。
    for _, u in ipairs(units) do
      local d = dec[u] or 0
      if u > 0 and d > 0 then
        local sold, exp = SplitDecrease(prev[u], d, gap)
        r.expired = r.expired + exp
        if sold > 0 then
          r.sold = r.sold + sold
          r.soldN = r.soldN + sold
          r.soldValue = r.soldValue + sold * u
        end
      end
    end
  end

  for _, inc in ipairs(incs) do
    if not inc.used then r.new = r.new + inc.qty - (inc.taken or 0) end
  end
  return r
end

-- 一列紀錄的欄位順序（分析工具也照這個讀）
-- 1.1 起在最後加 soldValue；舊紀錄只有前 10 欄，讀的時候缺的當 0
S.ROW_FIELDS = { "qty", "listings", "min", "p25", "med", "sold", "soldN", "expired", "repost", "new", "soldValue" }

-- 尾端的 0 不寫（讀的時候缺的欄位當 0）：大部分物品沒有賣出，可省約 1/4 空間。至少留第 1 欄。
local function TrimZeros(v)
  local n = #v
  while n > 1 and (v[n] == 0 or v[n] == "0") do v[n] = nil; n = n - 1 end
  return table.concat(v, ",")
end
S.TrimZeros = TrimZeros

function S.TrimRow(row)
  local v = {}
  for x in (row or ""):gmatch("[^,]+") do v[#v + 1] = x end
  if #v == 0 then return "0" end
  return TrimZeros(v)
end

function S.PackRow(a, d)
  local v = {}
  for i, f in ipairs(S.ROW_FIELDS) do
    v[i] = a[f] or (d and d[f]) or 0
  end
  return TrimZeros(v)
end

-- 處理一次完整掃描。
-- ah: 這個拍賣場的資料表 { prev=, prevVersion=, prevTime=, scans={} }
-- items: 物品資料（判斷可不可堆疊），可省略
-- 回傳這次的 scan 紀錄
function S.ProcessScan(ah, listings, now, zone, hasTimeLeft, items)
  items = items or {}
  local byKey = S.GroupByKey(listings)
  local gap = ah.prevTime and (now - ah.prevTime) or nil
  -- 上次快照是舊格式（1.1 版逐筆指紋）就當第一次掃描，不比對
  local canDiff = gap ~= nil and gap > 0 and ah.prev ~= nil and ah.prevVersion == S.PREV_VERSION

  local scan = { t = now, zone = zone, n = #listings, gap = gap, tl = hasTimeLeft and 1 or 0, items = {} }

  local keys = {}
  for key in pairs(byKey) do keys[key] = true end
  if canDiff then for key in pairs(ah.prev) do keys[key] = true end end

  local newPrev, nItems = {}, 0
  for key in pairs(keys) do
    local cur = byKey[key] or {}
    local a = S.Aggregate(cur)
    local curTiers = S.BuildTiers(cur)
    local prevTiers, prevFlag = nil, nil
    if canDiff then prevTiers, prevFlag = S.UnpackTiers(ah.prev[key]) end
    local stackable = S.IsStackable(items[key], cur, prevFlag)
    local d = nil
    if canDiff then d = S.DiffTiers(prevTiers, curTiers, gap, stackable) end
    if a.qty > 0 or (d and (d.sold > 0 or d.expired > 0 or d.repost > 0)) then
      scan.items[key] = S.PackRow(a, d)
      nItems = nItems + 1
    end
    if #cur > 0 then newPrev[key] = S.PackTiers(curTiers, stackable) end
  end
  scan.nItems = nItems
  scan.diff = canDiff and 1 or 0
  scan.est = S.EST_VERSION

  ah.prev = newPrev
  ah.prevVersion = S.PREV_VERSION
  ah.prevTime = now
  ah.scans = ah.scans or {}
  table.insert(ah.scans, scan)
  return scan
end

-- 刪掉超過 keepDays 天的掃描紀錄
function S.Prune(ah, now, keepDays)
  if not ah.scans then return 0 end
  local cutoff = now - keepDays * 86400
  local kept, removed = {}, 0
  for _, s in ipairs(ah.scans) do
    if s.t >= cutoff then kept[#kept + 1] = s else removed = removed + 1 end
  end
  ah.scans = kept
  return removed
end

-- ---- 掃描冷卻提醒 ----
S.SCAN_COOLDOWN = 15 * 60   -- 暴雪限制：全掃每 15 分鐘一次

-- 距離可以再掃還有幾秒（0＝現在就可以）；interval 是使用者設定的提醒間隔（秒），不得小於冷卻
function S.SecondsUntilScan(lastScan, now, interval)
  if not lastScan then return 0 end
  interval = math.max(interval or S.SCAN_COOLDOWN, S.SCAN_COOLDOWN)
  local left = lastScan + interval - now
  if left < 0 then return 0 end
  return left
end

function S.FormatWait(sec)
  sec = math.floor(sec + 0.5)
  if sec <= 0 then return "現在" end
  local h, m, s = math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60
  if h > 0 then return string.format("%d 小時 %d 分", h, m) end
  if m > 0 then return string.format("%d 分 %02d 秒", m, s) end
  return s .. " 秒"
end

-- ---- 分析 ----
-- 兩次掃描相隔超過這個秒數就不算進「觀察時間」：太久的話，大部分拍賣都可能已經到期，認不出賣出
S.MAX_DIFF_GAP = 8 * 3600

-- 推估的可信度與換算規則（說明見 DESIGN.md「估算與可信度」）
S.MIN_DAY_SECONDS = 86400   -- 換算每日時分母至少 1 天：觀察不滿一天不往上外推
S.CONF_MIN_SALES = 3        -- 成交筆數少於這個數＝低可信度
S.CONF_MIN_HOURS = 12       -- 有效觀察少於這個時數＝低可信度
-- 這些欄位是推估值：排序時低可信度的一律排在可信的後面
S.ESTIMATE_FIELDS = { sold = true, soldN = true, soldPerDay = true, avgSold = true, sellThrough = true, valuePerDay = true }

-- 推估的數量顯示：10 以上取整數，以下留一位小數
function S.FormatEstimate(v)
  if not v or v <= 0 then return "0" end
  if v >= 10 then return string.format("%d", v + 0.5) end
  return string.format("%.1f", v)
end

-- 把一列的推估欄位（sold 以後）歸零，量與價格保留
function S.ZeroEstimates(row)
  local v, i = {}, 0
  for x in (row or ""):gmatch("[^,]+") do
    i = i + 1
    v[i] = i < S.ESTIMATE_ROW_FROM and x or "0"
  end
  if i == 0 then return "0" end
  return TrimZeros(v)
end

-- 一次掃描的推估不能用（舊演算法）：推估歸零、標成不比對
function S.ClearScanEstimates(sc)
  for key, row in pairs(sc.items or {}) do sc.items[key] = S.ZeroEstimates(row) end
  sc.diff = 0
  sc.est = nil
end

-- 資料升級到第 3 版：1.0／1.1 版用逐筆指紋推估賣出，在 Forever 會把撤單、部分購買當成賣出。
-- 沒有完整的舊上架清單可以重算，所以只保留價格與架上量，推估全部清掉，舊快照也丟掉。
-- 回傳 true＝這次有做升級（呼叫端只在這時候提示一次）
function S.MigrateToV3(db)
  if (db.version or 1) >= 3 then return false end
  for _, ah in pairs(db.realms or {}) do
    for _, sc in ipairs(ah.scans or {}) do S.ClearScanEstimates(sc) end
    ah.prev, ah.prevVersion, ah.prevTime = nil, nil, nil
  end
  for _, sh in pairs(db.shared or {}) do
    for _, ah in pairs(sh) do
      for _, sc in ipairs(ah.scans or {}) do
        if (sc.est or 1) < S.EST_VERSION then S.ClearScanEstimates(sc) end
      end
    end
  end
  db.version = 3
  return true
end

-- 資料升級到第 4 版：所有列去掉尾端的 0；舊的保留天數設定（keepDays＝逐次掃描 60 天）作廢，
-- 改成「逐次掃描 detailDays 天＋每日彙整 dailyDays 天」。回傳 true＝這次有做升級
function S.MigrateToV4(db)
  if (db.version or 1) >= 4 then return false end
  local function trim(ah)
    for _, sc in ipairs(ah.scans or {}) do
      for key, row in pairs(sc.items or {}) do sc.items[key] = S.TrimRow(row) end
    end
  end
  for _, ah in pairs(db.realms or {}) do trim(ah) end
  for _, sh in pairs(db.shared or {}) do
    for _, ah in pairs(sh) do trim(ah) end
  end
  db.keepDays, db.shareKeepDays, db.outboxDays = nil, nil, nil
  db.version = 4
  return true
end

-- ---- 物品資料精簡存放 ----
-- 存檔裡每樣物品一行字串「名稱^品質^收購價^分類^子分類^堆疊」（名稱經 S.Enc 轉義，見 Share.lua），
-- 遊戲中展開成表格使用。登入時 UnpackItems，登出時 PackItems。兩種格式混在一起也讀得懂。
function S.UnpackItems(items)
  for key, v in pairs(items or {}) do
    if type(v) == "string" then
      local f = S.SplitRecord(v)
      items[key] = { name = f[1] ~= "" and S.Dec(f[1]) or nil, q = tonumber(f[2]), sell = tonumber(f[3]),
                     cls = tonumber(f[4]), sub = tonumber(f[5]), stack = tonumber(f[6]) }
    end
  end
end

function S.PackItems(items)
  for key, v in pairs(items or {}) do
    if type(v) == "table" then
      items[key] = table.concat({ S.Enc(v.name or ""), v.q or "", v.sell or "", v.cls or "", v.sub or "", v.stack or "" }, "^")
    end
  end
end

function S.ParseRow(row)
  local f, i = {}, 0
  for v in (row or ""):gmatch("[^,]+") do
    i = i + 1
    local name = S.ROW_FIELDS[i]
    if name then f[name] = tonumber(v) or 0 end
  end
  for _, name in ipairs(S.ROW_FIELDS) do f[name] = f[name] or 0 end
  return f
end

-- 最近 days 天的價量分析。回傳 (清單, 觀察秒數, 比對次數)
-- 每項：key、name、qty/listings/min/med（最新一次掃描）、sold、soldValue、expired、repost、new、
--       soldPerDay、avgSold（成交均價）、sellThrough（賣出率）、valuePerDay（每日成交額）、trend（中位價漲跌比例）、sell（商店收購價）
-- 從好幾個來源挑出不重疊的比對區間 [t-gap, t]：同一段時間只算一個人的（優先間隔短的），
-- 避免同一筆成交被兩個人各算一次。只有自己一個來源時，連續掃描本來就不重疊，等於全選。
-- 回傳 { [scan] = true }
function S.PickIntervals(sources, since, maxGap)
  local cands = {}
  for _, src in ipairs(sources) do
    for _, sc in ipairs(src.scans or {}) do
      if sc.t >= since and sc.diff == 1 and sc.gap and sc.gap > 0 and sc.gap <= maxGap then
        cands[#cands + 1] = sc
      end
    end
  end
  table.sort(cands, function(a, b)
    if a.gap ~= b.gap then return a.gap < b.gap end
    return a.t < b.t
  end)
  local picked, chosen = {}, {}
  for _, sc in ipairs(cands) do
    local s1, e1 = sc.t - sc.gap, sc.t
    local ok = true
    for _, o in ipairs(chosen) do
      if s1 < o.t and o.t - o.gap < e1 then ok = false; break end
    end
    if ok then chosen[#chosen + 1] = sc; picked[sc] = true end
  end
  return picked
end

-- 把「一個拍賣場的資料」或「來源清單」統一成來源清單 { {source=, scans=}, ... }
-- 每日紀錄（S.RollupOld 產生）跟著帶在 .daily
local function AsSources(x)
  if x and x.scans then return { { source = nil, scans = x.scans }, daily = x.daily } end
  return x or {}
end

-- 分析範圍內的每日紀錄（舊到新）：那天有一半以上落在範圍內才算
local function DailyInRange(daily, since)
  local list = {}
  for _, day in pairs(daily or {}) do
    if day.t0 and day.t0 + 43200 >= since then list[#list + 1] = day end
  end
  table.sort(list, function(a, b) return a.t0 < b.t0 end)
  return list
end

-- srcs：S.CollectSources 的結果（自己＋朋友），或單一拍賣場資料 { scans = ... }
-- 回傳 (清單, 觀察秒數, 比對次數, 用到的來源數, 用到的每日紀錄天數)
-- 每日紀錄（較舊的日子）只拿賣出相關的加總和中位價；架上量與最低價看最新一次逐次掃描。
function S.Analyze(srcs, now, days, items)
  items = items or {}
  srcs = AsSources(srcs)
  local since = now - days * 86400
  local picked = S.PickIntervals(srcs, since, S.MAX_DIFF_GAP)
  local scans, nSources = {}, 0
  for _, src in ipairs(srcs) do
    local used = false
    for _, sc in ipairs(src.scans or {}) do
      if sc.t >= since then scans[#scans + 1] = sc; used = true end
    end
    if used then nSources = nSources + 1 end
  end
  table.sort(scans, function(a, b) return a.t < b.t end)
  local latest = scans[#scans]   -- 所有來源中最新的一次
  local res, covered, nDiff = {}, 0, 0
  local function Row(key)
    local r = res[key]
    if not r then
      r = { key = key, sold = 0, soldN = 0, soldValue = 0, soldValueQty = 0, soldValueN = 0,
            expired = 0, repost = 0, new = 0 }
      res[key] = r
    end
    return r
  end

  -- 先加每日紀錄（比逐次掃描舊），中位價的「最早」才會取到最舊的
  local dailies = DailyInRange(srcs.daily, since)
  for _, day in ipairs(dailies) do
    covered = covered + (day.o or 0)
    for key, row in pairs(day.items or {}) do
      local f = S.ParseDaily(row)
      local r = Row(key)
      r.sold = r.sold + f.sold
      r.soldN = r.soldN + f.soldN
      r.expired = r.expired + f.expired
      r.repost = r.repost + f.repost
      r.new = r.new + f.new
      r.soldValue = r.soldValue + f.soldValue
      r.soldValueQty = r.soldValueQty + f.soldValueQty
      r.soldValueN = r.soldValueN + f.soldValueN
      if f.medAvg > 0 then
        r.firstMed = r.firstMed or f.medAvg
        r.lastMed = f.medAvg
      end
    end
  end

  for _, sc in ipairs(scans) do
    do
      local useDiff = picked[sc]
      if useDiff then covered = covered + sc.gap; nDiff = nDiff + 1 end
      for key, row in pairs(sc.items or {}) do
        local f = S.ParseRow(row)
        local r = Row(key)
        if useDiff then
          r.sold = r.sold + f.sold
          r.soldN = r.soldN + f.soldN        -- 成交筆數：一整疊被買走只算 1 次
          r.expired = r.expired + f.expired
          r.repost = r.repost + f.repost
          r.new = r.new + f.new
          if f.soldValue > 0 then
            r.soldValue = r.soldValue + f.soldValue
            r.soldValueQty = r.soldValueQty + f.sold
            r.soldValueN = r.soldValueN + f.soldN
          end
        end
        if f.med > 0 then
          r.firstMed = r.firstMed or f.med
          r.lastMed = f.med
        end
      end
    end
  end

  local list = {}
  for key, r in pairs(res) do
    local cur = latest and latest.t >= since and latest.items and latest.items[key]
    local f = cur and S.ParseRow(cur) or nil
    r.qty = f and f.qty or 0
    r.listings = f and f.listings or 0
    r.min = f and f.min or 0
    r.med = (f and f.med > 0) and f.med or (r.lastMed or 0)
    -- 分母至少 1 天：觀察 3 小時看到 1 筆成交，不會被放大成「一天 8 筆」。
    -- 賣出量本來就不超過觀察期間從架上消失的量，所以每日數字不會超過實際看得到的供給。
    local perDay = covered > 0 and 86400 / math.max(covered, S.MIN_DAY_SECONDS) or 0
    r.soldPerDay = r.sold * perDay
    r.avgSold = r.soldValueQty > 0 and r.soldValue / r.soldValueQty or 0
    r.sellThrough = (r.sold + r.expired) > 0 and r.sold / (r.sold + r.expired) or -1
    r.valuePerDay = r.soldValue * perDay
    -- 可信度：成交筆數太少或觀察太短 → 數字僅供參考
    r.lowConf = r.soldN < S.CONF_MIN_SALES or covered < S.CONF_MIN_HOURS * 3600
    r.avgLowConf = r.soldValueN < S.CONF_MIN_SALES
    r.observedHours = covered / 3600
    r.trend = (r.firstMed and r.firstMed > 0 and r.lastMed) and (r.lastMed - r.firstMed) / r.firstMed or 0
    local info = items[key] or {}
    r.name = info.name or key
    r.sell = info.sell or 0
    r.quality = info.q
    list[#list + 1] = r
  end
  return list, covered, nDiff, nSources, #dailies
end

-- 依欄位排序（文字欄位依名稱，數字欄位預設大到小）
-- 推估欄位（S.ESTIMATE_FIELDS）不論升降冪，低可信度的都排在可信的後面
function S.SortList(list, field, ascending)
  local est = S.ESTIMATE_FIELDS[field]
  table.sort(list, function(a, b)
    if est and (a.lowConf and true or false) ~= (b.lowConf and true or false) then
      return not a.lowConf
    end
    local x, y = a[field], b[field]
    if x == y then return (a.name or "") < (b.name or "") end
    if type(x) == "string" or type(y) == "string" then
      x, y = tostring(x), tostring(y)
    end
    if ascending then return x < y end
    return x > y
  end)
  return list
end

function S.FilterList(list, text, onlySold)
  local out = {}
  text = (text or ""):lower()
  for _, r in ipairs(list) do
    local okText = text == "" or (r.name or ""):lower():find(text, 1, true)
    local okSold = not onlySold or r.sold > 0
    if okText and okSold then out[#out + 1] = r end
  end
  return out
end

-- 某物品每次掃描的紀錄（新到舊）
-- 可傳單一拍賣場資料或來源清單；每列多一個 source（nil＝自己）
function S.History(srcs, key, limit)
  local all = {}
  for _, src in ipairs(AsSources(srcs)) do
    for _, sc in ipairs(src.scans or {}) do
      local row = sc.items and sc.items[key]
      if row then all[#all + 1] = { sc = sc, row = row, source = src.source } end
    end
  end
  table.sort(all, function(a, b) return a.sc.t > b.sc.t end)
  local out = {}
  for i = 1, math.min(limit, #all) do
    local f = S.ParseRow(all[i].row)
    f.t = all[i].sc.t
    f.diff = all[i].sc.diff
    f.source = all[i].source
    out[#out + 1] = f
  end
  -- 接著是較舊的每日紀錄（新到舊）：daily=true，qty＝當天最大架上量、min＝當天最低價、med＝當天中位價平均
  local dailies = DailyInRange(srcs.daily, -math.huge)
  for i = #dailies, 1, -1 do
    if #out >= limit then break end
    local row = dailies[i].items and dailies[i].items[key]
    if row then
      local d = S.ParseDaily(row)
      out[#out + 1] = { t = dailies[i].t0, daily = true, diff = (dailies[i].o or 0) > 0 and 1 or 0,
                        qty = d.maxQty, min = d.min, med = d.medAvg, sold = d.sold }
    end
  end
  return out
end

-- ---- 每日彙整（見 DESIGN.md「每日彙整」）----
-- 先合併、再濃縮：把自己＋朋友的逐次掃描放在一起，用 S.PickIntervals 扣掉重疊的比對區間，
-- 再把同一天的掃描濃縮成「每天每物品一列」。每日紀錄只存在自己電腦，不分享，也不和別人的每日紀錄相加。
-- dayOffset：時區秒數（台灣 +8 小時＝28800），決定一天從幾點算起。天編號 = floor((t + dayOffset) / 86400)
-- 比對區間依結束時間歸到那一天。
-- 回傳 days[天編號] = { observed = 觀察秒數, scans = 掃描數, items = { [物品鍵] = {
--   n = 出現次數, maxQty, min, medAvg, sold, soldN, soldValue, soldValueQty, soldValueN, expired, repost, new } } }
S.DAILY_SCHEMA = 1
-- 每日列的欄位順序（存檔裡逗號分隔，尾端的 0 不寫）
S.DAILY_FIELDS = { "n", "maxQty", "min", "medAvg", "sold", "soldN", "soldValue", "soldValueQty", "soldValueN",
                   "expired", "repost", "new" }

function S.RollupDaily(srcs, dayOffset)
  dayOffset = dayOffset or 0
  srcs = AsSources(srcs)
  local picked = S.PickIntervals(srcs, -math.huge, S.MAX_DIFF_GAP)
  local days = {}
  for _, src in ipairs(srcs) do
    for _, sc in ipairs(src.scans or {}) do
      local d = math.floor((sc.t + dayOffset) / 86400)
      local day = days[d]
      if not day then day = { observed = 0, scans = 0, items = {} }; days[d] = day end
      day.scans = day.scans + 1
      local use = picked[sc]
      if use then day.observed = day.observed + sc.gap end
      for key, row in pairs(sc.items or {}) do
        local f = S.ParseRow(row)
        local it = day.items[key]
        if not it then
          it = { min = 0, medSum = 0, medN = 0, maxQty = 0, sold = 0, soldN = 0, soldValue = 0, soldValueQty = 0,
                 soldValueN = 0, expired = 0, repost = 0, new = 0, n = 0 }
          day.items[key] = it
        end
        it.n = it.n + 1
        if f.min > 0 and (it.min == 0 or f.min < it.min) then it.min = f.min end
        if f.med > 0 then it.medSum = it.medSum + f.med; it.medN = it.medN + 1 end
        if f.qty > it.maxQty then it.maxQty = f.qty end
        if use then
          it.sold = it.sold + f.sold
          it.soldN = it.soldN + f.soldN
          it.expired = it.expired + f.expired
          it.repost = it.repost + f.repost
          it.new = it.new + f.new
          if f.soldValue > 0 then
            it.soldValue = it.soldValue + f.soldValue
            it.soldValueQty = it.soldValueQty + f.sold
            it.soldValueN = it.soldValueN + f.soldN
          end
        end
      end
    end
  end
  for _, day in pairs(days) do
    for _, it in pairs(day.items) do
      it.medAvg = it.medN > 0 and math.floor(it.medSum / it.medN + 0.5) or 0
      it.medSum, it.medN = nil, nil
    end
  end
  return days
end

function S.PackDaily(it)
  local v = {}
  for i, f in ipairs(S.DAILY_FIELDS) do v[i] = math.floor((it[f] or 0) + 0.5) end
  return TrimZeros(v)
end

function S.ParseDaily(row)
  local f, i = {}, 0
  for v in (row or ""):gmatch("[^,]+") do
    i = i + 1
    local name = S.DAILY_FIELDS[i]
    if name then f[name] = tonumber(v) or 0 end
  end
  for _, name in ipairs(S.DAILY_FIELDS) do f[name] = f[name] or 0 end
  return f
end

-- 時區秒數：本機時間比 UTC 快幾秒（遊戲裡呼叫，離線測試直接給數字）
function S.LocalDayOffset()
  local now = time()
  return now - time(date("!*t", now))
end

-- 某時間點所在那天的天編號
function S.DayOf(t, dayOffset) return math.floor((t + (dayOffset or 0)) / 86400) end

-- 把超過 detailDays 天的逐次掃描（自己＋朋友，同一個拍賣場）濃縮成每日紀錄，然後刪掉那些逐次掃描；
-- 每日紀錄超過 dailyDays 天的刪掉。
-- 只濃縮「整天都已經超過保留期」的日子（今天往前 detailDays 天之前的日子）。
-- ah.rolledBefore：這個時間以前的資料已經濃縮過；之後才送到的朋友掃描若落在這之前，匯入時直接丟掉（避免重算）。
-- 回傳 (新增幾天, 刪掉幾次掃描)
function S.RollupOld(db, rk, now, detailDays, dailyDays, dayOffset)
  db.realms[rk] = db.realms[rk] or { scans = {} }
  local ah = db.realms[rk]
  ah.daily = ah.daily or {}
  local today = S.DayOf(now, dayOffset)
  local cutDay = today - detailDays - 1             -- 今天以外再留滿 detailDays 整天，更早的濃縮
  local boundary = (cutDay + 1) * 86400 - dayOffset -- 這個時間以前的掃描要濃縮
  local done = ah.rolledBefore or -math.huge

  local srcs, removed = {}, 0
  local function take(scans)
    local old, keep = {}, {}
    for _, sc in ipairs(scans or {}) do
      if sc.t < boundary then
        if sc.t >= done then old[#old + 1] = sc end
        removed = removed + 1
      else
        keep[#keep + 1] = sc
      end
    end
    if #old > 0 then srcs[#srcs + 1] = { scans = old } end
    return keep
  end
  ah.scans = take(ah.scans)
  for _, sh in pairs(db.shared or {}) do
    local a = sh[rk]
    if a then
      a.scans = take(a.scans)
      local seen = {}
      for _, sc in ipairs(a.scans) do seen[sc.t] = true end
      a.seen = seen
    end
  end

  local added = 0
  if #srcs > 0 then
    for d, day in pairs(S.RollupDaily(srcs, dayOffset)) do
      if not ah.daily[d] then
        local items = {}
        for key, it in pairs(day.items) do items[key] = S.PackDaily(it) end
        ah.daily[d] = { t0 = d * 86400 - dayOffset, o = day.observed, s = day.scans, items = items }
        added = added + 1
      end
    end
  end
  if boundary > done then ah.rolledBefore = boundary end

  for d in pairs(ah.daily) do
    if d <= today - dailyDays then ah.daily[d] = nil end
  end
  -- 朋友來源整個沒資料了就移除
  for src, sh in pairs(db.shared or {}) do
    local any = false
    for k, a in pairs(sh) do
      if #(a.scans or {}) == 0 then sh[k] = nil else any = true end
    end
    if not any then db.shared[src] = nil end
  end
  return added, removed
end
