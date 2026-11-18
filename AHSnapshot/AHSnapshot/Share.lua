-- AH Snapshot 共享：交換格式（outbox / inbox）、匯入朋友資料、合併分析用的掃描清單
-- 純資料處理，不碰遊戲 UI（離線測試直接載入）
AHSnapshot = AHSnapshot or {}
local S = AHSnapshot

-- 交換格式版本。格式說明見 DESIGN.md。
--   紀錄之間用 "~" 分隔（雲端檔案裡由同步工具換成一行一筆），欄位之間用 "^" 分隔。
--   會出問題的字元（% ^ ~ " \ 與控制字元）一律寫成 %XX，所以整段字串不需要任何 Lua 跳脫，
--   外部工具也只要找雙引號就能把它從存檔裡切出來。
--   V^格式版本^來源名字^匯出時間          一段資料的開頭（來源名字由同步工具填）
--   I^物品鍵^名稱^品質^收購價^分類^子分類^堆疊   物品資料
--   S^拍賣場鍵^t^gap^diff^tl^n^zone^列格式^推估版本  一次掃描的標頭，後面跟著它的 R
--                                     （推估版本 < 2 或沒有：只收價格與架上量，推估歸零）
--   R^物品鍵^逗號分隔的數字                 一個物品在這次掃描的價量（欄位見 S.ROW_FIELDS，只會往後加）
--   D^...                                   保留給每日彙整（尚未使用）
--   不認得的紀錄類型直接略過，舊版插件讀到新格式不會壞。
S.SHARE_FORMAT = 1
S.ROW_SCHEMA = 1           -- R 列欄位版本：1＝S.ROW_FIELDS（11 欄，只往後加）
local RS, FS = "~", "^"

function S.Enc(s)
  s = tostring(s == nil and "" or s)
  -- 不用 %c：有些環境會把中文的 UTF-8 位元組（0x80 以上）也當成控制字元
  return (s:gsub('[%%%^~"\\%z\1-\31\127]', function(c) return string.format("%%%02X", c:byte()) end))
end

function S.Dec(s)
  return ((s or ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function Split(rec)
  local f = {}
  for v in (rec .. FS):gmatch("([^%^]*)%^") do f[#f + 1] = v end
  return f
end
S.SplitRecord = Split

-- 把自己的掃描（最近 days 天）匯出成字串
function S.ExportOutbox(db, now, days)
  local since = now - days * 86400
  local out = { table.concat({ "V", S.SHARE_FORMAT, "", now }, FS) }
  local usedKeys = {}
  local body = {}
  for rk, ah in pairs(db.realms or {}) do
    for _, sc in ipairs(ah.scans or {}) do
      if sc.t >= since then
        -- 舊演算法的推估不分享：標成不比對、推估欄位歸零
        local okEst = (sc.est or 1) >= S.EST_VERSION
        body[#body + 1] = table.concat({ "S", S.Enc(rk), sc.t, sc.gap or "", okEst and (sc.diff or 0) or 0, sc.tl or 0,
          sc.n or 0, S.Enc(sc.zone), S.ROW_SCHEMA, okEst and S.EST_VERSION or 1 }, FS)
        for key, row in pairs(sc.items or {}) do
          body[#body + 1] = "R" .. FS .. S.Enc(key) .. FS .. (okEst and row or S.ZeroEstimates(row))
          usedKeys[key] = true
        end
      end
    end
  end
  for key in pairs(usedKeys) do
    local it = (db.items or {})[key]
    if it and it.name then
      out[#out + 1] = table.concat({ "I", S.Enc(key), S.Enc(it.name), it.q or "", it.sell or "",
        it.cls or "", it.sub or "", it.stack or "" }, FS)
    end
  end
  for _, line in ipairs(body) do out[#out + 1] = line end
  return table.concat(out, RS)
end

local function num(v) return tonumber(v) end

-- 匯入 inbox（可能是好幾個人的資料接在一起，每段以 V 開頭）
-- 回傳 { [來源] = 新增的掃描數 }, 新增物品資料數
function S.ImportInbox(db, text, now, keepDays)
  db.shared = db.shared or {}
  db.items = db.items or {}
  local added, newItems = {}, 0
  if type(text) ~= "string" or text == "" then return added, newItems end
  local since = now and keepDays and (now - keepDays * 86400) or nil

  local source, cur, skip = nil, nil, false
  for rec in text:gmatch("[^~]+") do
    local kind = rec:sub(1, 1)
    if rec:sub(2, 2) == FS or #rec == 1 then
      local f = Split(rec)
      if kind == "V" then
        source = S.Dec(f[3] or "")
        if source == "" then source = "?" end
        cur, skip = nil, false
      elseif kind == "I" and source then
        local key = S.Dec(f[2] or "")
        if key ~= "" and not (db.items[key] and db.items[key].name) then
          db.items[key] = { name = S.Dec(f[3] or ""), q = num(f[4]), sell = num(f[5]), cls = num(f[6]),
                            sub = num(f[7]), stack = num(f[8]) }
          newItems = newItems + 1
        end
      elseif kind == "S" and source then
        local rk, t = S.Dec(f[2] or ""), num(f[3])
        cur, skip = nil, true
        if rk ~= "" and t and (not since or t >= since) then
          db.shared[source] = db.shared[source] or {}
          local sh = db.shared[source]
          sh[rk] = sh[rk] or { scans = {}, seen = {} }
          local ah = sh[rk]
          ah.seen = ah.seen or {}
          if not ah.seen[t] then
            -- 第 10 欄是推估演算法版本；沒有或太舊＝推估不可信，只收價格與架上量
            local est = num(f[10]) or 1
            cur = { t = t, gap = num(f[4]), diff = est >= S.EST_VERSION and (num(f[5]) or 0) or 0,
                    tl = num(f[6]) or 0, n = num(f[7]) or 0, est = est >= S.EST_VERSION and est or nil,
                    zone = S.Dec(f[8] or ""), items = {}, nItems = 0, clearEst = est < S.EST_VERSION }
            ah.scans[#ah.scans + 1] = cur
            ah.seen[t] = true
            added[source] = (added[source] or 0) + 1
            skip = false
          end
        end
      elseif kind == "R" and cur and not skip then
        local key = S.Dec(f[2] or "")
        local row = f[3]
        if key ~= "" and row and row:match("^[%d,%-%.]+$") then
          cur.items[key] = cur.clearEst and S.ZeroEstimates(row) or row
          cur.nItems = cur.nItems + 1
        end
      end
      -- 其他類型（例如之後的 D）略過
    end
  end
  for _, sh in pairs(db.shared) do
    for _, ah in pairs(sh) do
      for _, sc in ipairs(ah.scans) do sc.clearEst = nil end   -- 暫用旗標不存進存檔
      table.sort(ah.scans, function(a, b) return a.t < b.t end)
    end
  end
  return added, newItems
end

-- 刪掉朋友資料中超過 keepDays 天的掃描；空的來源整個移除
function S.PruneShared(db, now, keepDays)
  local cutoff = now - keepDays * 86400
  local removed = 0
  for src, sh in pairs(db.shared or {}) do
    local any = false
    for rk, ah in pairs(sh) do
      local kept, seen = {}, {}
      for _, sc in ipairs(ah.scans or {}) do
        if sc.t >= cutoff then kept[#kept + 1] = sc; seen[sc.t] = true else removed = removed + 1 end
      end
      ah.scans, ah.seen = kept, seen
      if #kept == 0 then sh[rk] = nil else any = true end
    end
    if not any then db.shared[src] = nil end
  end
  return removed
end

-- 分析用的掃描來源：自己的＋（可選）朋友的。回傳 { {source=名字或 nil, scans=...}, ... }
function S.CollectSources(db, rk, includeShared)
  local list = { { source = nil, scans = (db.realms[rk] or {}).scans or {} } }
  if includeShared then
    local names = {}
    for src in pairs(db.shared or {}) do names[#names + 1] = src end
    table.sort(names)
    for _, src in ipairs(names) do
      local ah = db.shared[src][rk]
      if ah and #(ah.scans or {}) > 0 then list[#list + 1] = { source = src, scans = ah.scans } end
    end
  end
  return list
end
