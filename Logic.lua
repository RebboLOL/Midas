-- Midas – Logic: names/category, metrics, Top Picks, ranking
local ADDON, M = ...

-- ===== Names & category (via GetItemInfo, cached) ===========================
local nameCache, catCache, tradeCache = {}, {}, {}

local function BaseID(key)
  key = tostring(key)
  if key:match("^%d+$") then return tonumber(key) end
  local id = key:match("^gr:(%d+)") or key:match("^g:(%d+)")
  if id then return tonumber(id) end
  return nil
end
M.BaseID = BaseID

function M.NameCacheDrop(itemID)
  nameCache[itemID] = nil; catCache[itemID] = nil; tradeCache[itemID] = nil
end

function M.ItemName(key)
  if nameCache[key] then return nameCache[key] end
  key = tostring(key)
  if key:match("^p:") then return "Pet " .. key end
  local id = BaseID(key)
  if not id then return "#" .. key end
  local name = M.GetItemInfo(id)
  -- client cache miss: fall back to the name remembered from our own scans.
  -- "" guards: scans of uncached items could store an empty name (shows as a
  -- blank, unsearchable row) - treat it like no name at all
  if not name or name == "" then
    local nm = M.db and M.db.names and M.db.names[id]
    name = (nm and nm ~= "" and nm) or nil
  end
  if not name then
    if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    return "Item #" .. id
  end
  -- append gear suffix
  local suffix = key:match("^gr:%d+:(.+)")
  if suffix and not suffix:match("^%d+$") then name = name .. " " .. suffix end
  nameCache[key] = name
  return name
end

function M.ItemCategory(key)
  if catCache[key] then return catCache[key] end
  local id = BaseID(key)
  if not id then return "" end
  local _, _, _, _, _, itemType, itemSubType = M.GetItemInfo(id)
  if not itemType then return "" end
  local cat = itemType
  if itemSubType and itemSubType ~= "" and itemSubType ~= itemType then
    cat = itemType .. " \194\183 " .. itemSubType
  end
  catCache[key] = cat
  return cat
end

function M.ItemQualityColor(key)
  local id = BaseID(key)
  if id then
    local q = select(3, M.GetItemInfo(id))
    if q and ITEM_QUALITY_COLORS[q] then return ITEM_QUALITY_COLORS[q] end
  end
  return ITEM_QUALITY_COLORS[1]
end

-- Only "real market" items belong in Top Picks: crafting mats, consumables,
-- recipes, ammo, bags/quivers, and BoE/BoU gear. No grey junk, no BoP/quest.
local TRADE_CLASS = { [0] = true, [1] = true, [5] = true, [6] = true, [7] = true, [9] = true, [11] = true }
local EQUIP_CLASS = { [2] = true, [4] = true }             -- weapons, armor
local BIND_OK     = { [0] = true, [2] = true, [3] = true } -- none / BoE / BoU

-- true = tradeable, false = junk/BoP, nil = item info not loaded yet (retry later)
function M.IsTradeable(key)
  local id = BaseID(key)
  if not id then return false end          -- pets etc. are not on the Classic AH
  if M.IsVendorItem and M.IsVendorItem(id) then return false end -- unlimited vendor supply
  local cached = tradeCache[key]
  if cached ~= nil then return cached end
  local _, _, quality, _, _, _, _, _, _, _, _, classID, _, bindType = M.GetItemInfo(id)
  if not classID then
    if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    return nil
  end
  local ok
  if quality and quality <= 0 then ok = false              -- grey vendor trash
  elseif TRADE_CLASS[classID] then ok = true
  elseif EQUIP_CLASS[classID] then ok = (BIND_OK[bindType or 0] == true)
  else ok = false end
  tradeCache[key] = ok
  return ok
end

-- ===== Metrics ==============================================================
local function percentile(sorted, q)
  local n = #sorted
  if n == 0 then return 0 end
  if n == 1 then return sorted[1] end
  local pos = q * (n - 1)
  local lo = math.floor(pos)
  local frac = pos - lo
  if lo + 2 > n then return sorted[n] end
  return sorted[lo + 1] + frac * (sorted[lo + 2] - sorted[lo + 1])
end

local function median(sorted)
  local n = #sorted
  if n == 0 then return 0 end
  if n % 2 == 1 then return sorted[(n + 1) / 2] end
  return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

-- ===== Sell-odds machinery (Fair price v2) ==================================
local function logit(p) return math.log(p / (1 - p)) end
local function sigmoid(z)
  if z > 30 then return 1 elseif z < -30 then return 0 end
  return 1 / (1 + math.exp(-z))
end
local function clampNum(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

local function liqLabelOf(avgQty)
  local C = M.C
  if avgQty >= (C.LIQ_FAST or 300) then return "Fast"
  elseif avgQty >= (C.LIQ_STEADY or 100) then return "Steady"
  elseif avgQty >= (C.LIQ_SLOW or 20) then return "Slow"
  else return "Illiquid" end
end

-- 7-day floor: median of the daily lowest buyouts over the 7 calendar days ending
-- at uptoDay (default: the item's newest day). Falls back to a 14-day window, then
-- to the last known low. The reference every ask is compared against.
function M.Floor7(series, uptoDay)
  if not series then return nil end
  local last = uptoDay
  if not last then
    last = -1
    for d in pairs(series) do if d > last then last = d end end
  end
  if not last or last < 0 then return nil end
  for _, span in ipairs({ 7, 14 }) do
    local lows = {}
    for d, v in pairs(series) do
      if v.low and d > last - span and d <= last then lows[#lows + 1] = v.low end
    end
    if #lows >= 2 then
      table.sort(lows)
      return median(lows)
    end
  end
  local bestD, bestL = -1, nil
  for d, v in pairs(series) do
    if v.low and d <= last and d > bestD then bestD, bestL = d, v.low end
  end
  return bestL
end

-- Trimmed short-term market base: recency-weighted average of the daily lowest
-- buyouts over the last FAIR_BASE_DAYS, EXCLUDING the days M.DemandWindow drops:
-- up-outliers above the window median x FAIR_TRIM (on thin days the "daily low"
-- can be a single overpriced ask that met no demand) and one-scan dips below
-- median / FAIR_TRIM. The recency HALF-LIFE is user-tunable (Settings > Fair price,
-- config.fairHalflife, default 7 days): shorter = Fair follows the last days,
-- longer = it smooths over the whole window.
function M.FairHalflife()
  local hl = M.db and M.db.config and tonumber(M.db.config.fairHalflife)
  if not hl or hl < 2 or hl > 14 then return 7 end
  return hl
end

local function newestDay(series, uptoDay)
  if uptoDay then return uptoDay end
  local last = -1
  for d in pairs(series) do if d > last then last = d end end
  return last
end

-- The FAIR_BASE_DAYS window behind DemandBase, ascending by day: { day, low, keep }.
-- keep = false for a no-demand spike (low > median x FAIR_TRIM) and for a one-scan
-- dip (low < median / FAIR_TRIM while the day's last scan was back above that
-- line): the daily low is the MIN over every scan and peer of the day, so one
-- sniped lowball would otherwise define it. A day whose last scan stayed low is a
-- real drop and is kept. nil with fewer than 4 days (DemandBase uses Floor7 then).
function M.DemandWindow(series, uptoDay)
  if not series then return nil end
  local C = M.C
  local last = newestDay(series, uptoDay)
  if last < 0 then return nil end
  local span = C.FAIR_BASE_DAYS or 14
  local win, lows = {}, {}
  for d, v in pairs(series) do
    if v.low and d > last - span and d <= last then
      win[#win + 1] = { day = d, low = v.low }
      lows[#lows + 1] = v.low
    end
  end
  if #win < 4 then return nil end
  table.sort(lows)
  table.sort(win, function(a, b) return a.day < b.day end)
  local med = median(lows)
  local trim = C.FAIR_TRIM or 1.5
  local hiCap, loCap = med * trim, med / trim
  for i = 1, #win do
    local e = win[i]
    local cur = series[e.day].cur
    e.keep = e.low <= hiCap and not (e.low < loCap and cur and cur >= loCap)
  end
  return win, hiCap, loCap
end

function M.DemandBase(series, uptoDay)
  if not series then return nil end
  local last = newestDay(series, uptoDay)
  if last < 0 then return nil end
  local win = M.DemandWindow(series, last)
  if not win then return M.Floor7(series, last) end
  local hl = M.FairHalflife()
  local wsum, vsum = 0, 0
  for i = 1, #win do
    local e = win[i]
    if e.keep then
      local w = 0.5 ^ ((last - e.day) / hl)
      wsum = wsum + w
      vsum = vsum + w * e.low
    end
  end
  if wsum <= 0 then return M.Floor7(series, last) end
  return vsum / wsum
end

-- Merged class anchor: shipped market prior + the user's own logged outcomes
-- (Trades.lua counters). S = sell-through observed at typical ask ratio r.
local function classAnchor(class)
  M._curveAnchor = M._curveAnchor or {}
  local a = M._curveAnchor[class]
  if a then return a end
  local C = M.C
  local pr = (C.FAIR_PRIOR and C.FAIR_PRIOR[class]) or { S = 0.40, r = 1.10, rs = 1.10 }
  local pn = C.FAIR_PRIOR_N or 24
  local s, n, sr = pr.S * pn, pn, pr.r * pn
  -- clearing level: mean ratio of SOLD listings only (prior weighted by its pseudo-
  -- sold count; counters contribute only solds that carry a ratio, see CurveCounts)
  local pnS = (pr.S * pn)
  local rsSum, rsN = (pr.rs or pr.r) * pnS, pnS
  if M.CurveCounts then
    local cs, cn, csr, ssr, sn = M.CurveCounts(class)
    s, n, sr = s + cs, n + cn, sr + csr
    rsSum, rsN = rsSum + ssr, rsN + sn
  end
  a = { S = clampNum(s / n, 0.02, 0.98), r = sr / n, n = n,
        rSold = (rsN > 0) and (rsSum / rsN) or nil }
  a.logitS = logit(a.S)
  M._curveAnchor[class] = a
  return a
end

-- Price percentiles, average quantity and the liquidity class describe the market of
-- the last STATS_DAYS before the item's newest day; `days` stays the all-time count.
local STATS_DAYS = 60

-- Cheap pre-scan: all-time day count, newest day and the STATS_DAYS average market
-- qty, with no sorting and no pow(). The whole-archive sweeps (RankAll/TopPicks) use
-- it to skip the expensive full Metrics for items that can't pass their day/qty gate
-- anyway. Without this, every refresh sorts and recency-weights every item in the
-- archive -- on a large database that trips WoW's "script ran too long" watchdog
-- (Logic.lua Metrics). M.Metrics takes days/lastDay/avgQty from here, so gating on
-- them yields an identical result set.
local function quickScan(series)
  local days, lastDay = 0, -1
  for day, v in pairs(series) do
    if v.low then
      days = days + 1
      if day > lastDay then lastDay = day end
    end
  end
  local n, qtySum, from = 0, 0, lastDay - STATS_DAYS
  for day, v in pairs(series) do
    if v.low and day > from then n = n + 1; qtySum = qtySum + (v.qty or 0) end
  end
  return days, lastDay, (n > 0 and qtySum / n or 0)
end
M.QuickScan = quickScan

-- Liquidity class of a series (the same label as Metrics')
function M.LiqClass(series)
  local _, _, avgQty = quickScan(series)
  return liqLabelOf(avgQty)
end

-- series = {day = {low,qty}}, key = item key (optional, enables the per-item
-- refinement) -> metrics (prices in copper).
--
-- Fair price v3 (trimmed market base + bounded sell-odds lift): the value anchor is
-- M.DemandBase -- the recency-weighted short-term average of daily lows with the
-- no-demand ask spikes trimmed out. The sell-odds curve (real outcomes: your sales
-- AND expired auctions vs the 7-day floor, per liquidity class + per-item record)
-- is inverted at FAIR_TARGET (~50%) and may LIFT Fair up to FAIR_LIFT_MAX above the
-- base when sales prove buyers pay more -- but never beyond ~FAIR_OVER_REALIZED x the
-- MEASURED clearing ratio (reality brake; the inversion must not extrapolate past
-- observed sales). It never cuts below the base: when even the
-- trimmed level can't reach the target odds, `fairCapped` is set -- the item is
-- oversupplied, so post less instead of pricing lower; the displayed odds
-- (`odds`/`oddsAtFair`) say so honestly. This replaced the old nudged decay-average
-- (survivor bias, sat ~8-15% too high) and the pure odds inversion (dragged the
-- illiquid mass to a fire-sale clamp ~15% below the floor).
function M.Metrics(series, key)
  -- memo: v3 metrics are not cheap (two window scans, a sort, odds maths), and some
  -- UI paths ask for many items in one frame. Results are pure functions of the
  -- archive + trade log, both of which bump _analysisGen via M.DirtyAnalysis -- so
  -- one generation-stamped cache makes every repeat call free. `false` = "no data".
  local memo
  if key then
    memo = M._mCache
    if not (memo and memo.gen == (M._analysisGen or 0)) then
      memo = { gen = M._analysisGen or 0, items = {} }
      M._mCache = memo
    end
    local hit = memo.items[key]
    if hit ~= nil then
      if hit == false then return nil end
      return hit
    end
  end
  local days, lastDay, avgQty = quickScan(series)
  if days == 0 then
    if memo then memo.items[key] = false end
    return nil
  end
  local lows, from = {}, lastDay - STATS_DAYS
  local minDay, minLow   -- day of the window low (the newest one on a tie)
  for day, v in pairs(series) do
    if v.low and day > from then
      lows[#lows + 1] = v.low
      if not minLow or v.low < minLow or (v.low == minLow and day > minDay) then
        minLow, minDay = v.low, day
      end
    end
  end
  table.sort(lows)
  local C = M.C
  local buy  = percentile(lows, 0.25)
  local sell = percentile(lows, 0.75)
  local med  = median(lows)
  local margin = buy > 0 and (sell / buy - 1) or 0
  local liq  = math.min(1, avgQty / C.QTY_REF)
  local conf = math.max(0, math.min(1, (days - 3) / (C.DAYS_REF - 3)))
  local score = math.min(margin, C.MARGIN_CAP) * liq * conf
  local lastRec = series[lastDay]
  local cur = (lastRec and (lastRec.cur or lastRec.low)) or lows[#lows]
  -- the AH showed a newer price since the newest scan (search results,
  -- Auctionator; Data.lua live prices): that one is current
  local live = key and M.FreshLive and M.FreshLive(key, lastRec, lastDay)
  if live then cur = live.p end

  -- Fair price v2: invert the sell-odds curve at the class anchor (see header).
  local liqLabel = liqLabelOf(avgQty)
  local floor7 = M.Floor7(series, lastDay) or med
  local anchor = classAnchor(liqLabel)
  local a = anchor.logitS
  local speed, maxPerDay, realizedR
  if key then
    -- per-item refinement: this item's own sold/expired record shifts the class
    -- anchor in logit space, shrunk by n/(n+6) so a few outcomes nudge, many decide
    if M.OutcomeCounts then
      local soldN, retN = M.OutcomeCounts(key)
      local ni = soldN + retN
      if ni >= (C.SELL_MIN_N or 3) then
        local si = clampNum(soldN / ni, 0.02, 0.98)
        a = a + (logit(si) - a) * (ni / (ni + 6))
      end
    end
    if M.RealizedSell then
      local _, rn, rperday, rmed = M.RealizedSell(key)
      if rn and rn >= (C.SELL_MIN_N or 3) then
        speed, maxPerDay = rperday, rperday
        realizedR = rmed                  -- where THIS item's sales really cleared
      end
    end
  end
  local slope = C.FAIR_SLOPE or 3
  local rstar = anchor.r * math.exp((a - logit(C.FAIR_TARGET or 0.50)) / slope)
  -- reality brake: a strong sell record raises the odds anchor, and the logistic
  -- inversion then EXTRAPOLATES a "target odds" price far beyond any observed sale
  -- (e.g. 85% sold at 1.1x floor -> "50% at 2x floor"). Cap the lift at the MEASURED
  -- clearing ratio (the item's own realized sales, else the class's), with headroom
  -- that scales with how far the record beats the target: a record at ~target odds
  -- pins Fair AT the clearing level, only a much stronger one earns the full +10%.
  local rCap = realizedR or anchor.rSold
  if rCap then
    local sEv = sigmoid(a)                 -- evidence sell rate at the anchor ratio
    local tol = 1 + ((C.FAIR_OVER_REALIZED or 1.10) - 1)
                * math.min(1, math.max(0, (sEv - (C.FAIR_TARGET or 0.5)) / 0.35))
    rstar = math.min(rstar, rCap * tol)
  end
  local base = M.DemandBase(series, lastDay) or floor7
  local fair, fairCapped = med, false
  if base and base > 0 and floor7 and floor7 > 0 then
    local adj = (floor7 * rstar) / base   -- odds-optimal price as a multiple of the base
    fairCapped = adj < 1                  -- odds below target even at the trimmed level
    fair = base * clampNum(adj, 1, C.FAIR_LIFT_MAX or 1.10)
  end
  if not (fair and fair > 0) then fair = med end

  -- estimated sell chance of one 48h listing at a given price (transparency)
  local lnAnchorR = math.log(anchor.r)
  local function oddsAt(price)
    if not (floor7 and floor7 > 0 and price and price > 0) then return nil end
    return sigmoid(a - slope * (math.log(price / floor7) - lnAnchorR))
  end

  local quick = math.floor(math.min(cur, fair) * (1 - (C.QUICK_UNDERCUT or 0.02)))
  if quick < 1 then quick = math.floor(fair) end

  local m = {
    min = lows[1], minDay = minDay, max = lows[#lows], med = med, buy = buy, sell = sell,
    fair = fair, quick = quick, liqLabel = liqLabel, speed = speed, maxPerDay = maxPerDay,
    floor7 = floor7, base = base, fairCapped = fairCapped, rstar = rstar,
    odds = oddsAt(cur), oddsAtFair = oddsAt(fair), oddsAtQuick = oddsAt(quick),
    avgQty = avgQty, days = days, lastDay = lastDay,
    margin = margin, liq = liq, conf = conf, score = score,
    cur = cur, delta = (fair > 0) and (cur / fair - 1) or 0,
    liveTs = live and live.ts or nil, liveQty = live and live.q or nil,
  }
  if memo then memo.items[key] = m end
  return m
end

-- Trailing Fair-price series for the chart: today's odds ratio (rstar) applied to
-- each scan day's OWN trimmed base and floor -- i.e. the same clamp maths as Metrics,
-- evaluated per day. The line hugs the spike-cleaned market level historically
-- instead of carrying today's lift back through the whole history (which painted a
-- constant offset above the market). The newest point matches Metrics' fair.
local function fairOnDay(series, day, rstar)
  local b = M.DemandBase(series, day)
  local f7 = M.Floor7(series, day)
  if not (b and b > 0 and f7 and f7 > 0) then return nil end
  return b * clampNum((f7 * rstar) / b, 1, M.C.FAIR_LIFT_MAX or 1.10)
end

-- Only called for the one charted item.
function M.FairSeries(series, key)
  local out = {}
  if not series then return out end
  local m = M.Metrics(series, key)
  if not (m and m.rstar and m.fair and m.fair > 0) then return out end
  local days = {}
  for d, v in pairs(series) do if v.low then days[#days + 1] = d end end
  table.sort(days)
  for i = 1, #days do
    local f = fairOnDay(series, days[i], m.rstar)
    if f then out[#out + 1] = { day = days[i], fair = f } end
  end
  return out
end

-- One point of FairSeries: Fair as it stood on a historic day. nil when not computable.
function M.FairAt(series, key, day)
  local m = series and day and M.Metrics(series, key)
  if not (m and m.rstar) then return nil end
  return fairOnDay(series, day, m.rstar)
end

-- Theme color key for a vs-Fair delta: below Fair = buy, above Fair = sell.
function M.DeltaColor(delta)
  local t = M.C.PICK_DELTA or 0.15
  if delta and delta <= -t then return "green" end
  if delta and delta >= t then return "red" end
  return "sub"
end

-- The item is missing from the newest scan day: its Current is a last-seen price.
function M.NotListed(m)
  if not (m and m.lastDay) then return false end
  -- a live price (seen in the AH after the item's newest scan) decides by its own day
  if m.liveTs then return M.DayOf(m.liveTs) < M.LastScanDay() end
  return m.lastDay < M.LastScanDay()
end

-- Day the item was last seen in the AH (scan or live price), for "last seen" labels.
function M.SeenDay(m)
  if m and m.liveTs then return M.DayOf(m.liveTs) end
  return m and m.lastDay
end

-- Newest days first: list {day, low, qty}, optionally capped at n
function M.RecentDays(series, n)
  local arr = {}
  for day, v in pairs(series) do
    arr[#arr + 1] = { day = day, low = v.low, qty = v.qty or 0 }
  end
  table.sort(arr, function(a, b) return a.day > b.day end)
  if n then
    for i = #arr, n + 1, -1 do arr[i] = nil end
  end
  return arr
end

-- ===== Background whole-archive analysis ====================================
-- The ranked table (Opportunities) and Top Picks both need metrics for EVERY item in
-- the archive. With thousands of items and 100k+ daily rows that is far too much for a
-- single frame -- it trips WoW's "script ran too long" watchdog (the more so since the
-- 1.15.9 client tightened the script budget). So both are computed in the BACKGROUND, a
-- few hundred items per frame via a coroutine, then cached.
--
-- STALE-WHILE-REVALIDATE: at the AH, community sync merges arrive continuously and
-- each one invalidates the analysis (M.DirtyAnalysis). An earlier version dropped
-- the tables and ABORTED the in-flight build on every change -- under steady sync
-- traffic the build never finished and Top Picks / Opportunities refreshed
-- ("analyzing...") forever. Now the last finished result stays on screen (marked
-- stale), the build always runs to completion, and if data changed underneath it
-- exactly ONE deferred follow-up build catches up.

local CHUNK = M.C.ANALYSIS_CHUNK or 300
-- Where the client has a millisecond clock (debugprofilestop), a slice ends by
-- TIME instead of by item count: 300 items took a mere 1-3 ms, so a 5,000-item
-- archive spread over ~20 frames and the start page said "analyzing market
-- data..." for a second or two at the AH. The time cap also keeps a slow PC
-- inside the client's script budget. Without the clock: the fixed CHUNK.
local SLICE_MS = M.C.ANALYSIS_SLICE_MS or 6
local SLICE_CHECK = 25   -- items between two clock reads

-- One chunked pass over the archive -> ranked list (Opportunities) + Top Picks.
local function runAnalysis()
  local C = M.C
  local clock = rawget(_G, "debugprofilestop")
  local sliceAt = clock and clock()
  local genAtStart = M._analysisGen or 0
  local realm = M.RealmKey()
  local store = M.IterItems(realm)
  -- Snapshot the key list in ONE synchronous pass (no yield): iterating the live
  -- store across frames is unsafe -- a sync merge may insert new items between
  -- chunks, and adding keys during a pairs() traversal is undefined behavior in
  -- Lua. O(#items) appends are cheap; the per-item work below re-reads the series
  -- fresh (one item is always processed within a single frame, so its day-table
  -- cannot mutate mid-iteration).
  local keys, kn = {}, 0
  for key in pairs(store) do kn = kn + 1; keys[kn] = key end
  local prog = { done = 0, total = kn }   -- the start page counts along (M.AnalysisProgress)
  M._analysisProgress = prog
  local ranked, cand, all = {}, {}, {}
  local maxDay = -1
  for i = 1, kn do
    local key = keys[i]
    local series = store[key]
    if series then
      local days, lastDay, avgQty = quickScan(series)    -- cheap gate before full Metrics
      if lastDay > maxDay then maxDay = lastDay end
      local m
      if days >= C.MIN_DAYS and avgQty >= C.RANK_MIN_QTY then
        m = M.Metrics(series, key)
        if m and m.buy >= C.RANK_MIN_PRICE and m.margin > 0 then
          ranked[#ranked + 1] = { key = key, m = m }
        end
        -- Top-Picks candidate: qty >= PICK_MIN_QTY (>= RANK_MIN_QTY, so m is already
        -- computed); the latest-scan-day test is applied after the pass, once maxDay is known.
        if m and avgQty >= C.PICK_MIN_QTY and m.fair >= C.PICK_MIN_PRICE
           and (not C.PICK_TRADEABLE_ONLY or M.IsTradeable(key) == true) then
          cand[#cand + 1] = { key = key, m = m, lastDay = lastDay }
        end
      end
      -- browse list ("all items" view): full metrics where the ranking computed
      -- them, otherwise a thin shell (fair/score render as "-"). RAM only.
      if days > 0 then
        if not m then
          local le = series[lastDay]
          m = { cur = le and (le.cur or le.low), days = days, avgQty = avgQty, lastDay = lastDay }
        end
        all[#all + 1] = { key = key, m = m }
      end
    end
    if clock then
      if i % SLICE_CHECK == 0 and clock() - sliceAt >= SLICE_MS then
        prog.done = i
        coroutine.yield()
        sliceAt = clock()
      end
    elseif i % CHUNK == 0 then
      prog.done = i
      coroutine.yield()
    end
  end
  -- Finalize Top Picks: only items on the newest scan day, with a real move.
  local last = maxDay
  local buys, sells = {}, {}
  for i = 1, #cand do
    local p = cand[i]
    if p.lastDay == last then
      local m = p.m
      if math.abs(m.cur - m.fair) >= C.PICK_MIN_MOVE then
        local rec = { key = p.key, cur = m.cur, fair = m.fair, delta = m.delta,
                      qty = math.floor(m.avgQty + 0.5), days = m.days,
                      liqLabel = m.liqLabel, speed = m.speed, quick = m.quick }
        if m.delta <= -C.PICK_DELTA then buys[#buys + 1] = rec
        elseif m.delta >= C.PICK_DELTA then sells[#sells + 1] = rec end
      end
    end
  end
  table.sort(ranked, function(a, b) return a.m.score > b.m.score end)
  table.sort(buys,  function(a, b) return a.delta < b.delta end)
  table.sort(sells, function(a, b) return a.delta > b.delta end)
  -- ALWAYS publish (a near-fresh result beats an empty tab). If the archive moved
  -- while we built, stay marked stale so the driver schedules ONE follow-up pass.
  M._analysis = { ready = true, ranked = ranked, buys = buys, sells = sells, all = all, last = last }
  M._analysisStale = (M._analysisGen or 0) ~= genAtStart
  if not M._analysisStale then
    M._lastDayCache = M._lastDayCache or {}
    M._lastDayCache[realm] = last
  end
end

-- Items done / in all of the running build; nothing while none runs.
function M.AnalysisProgress()
  local p = M._analysisJob and M._analysisProgress
  if p then return p.done, p.total end
end

-- Kick / drive the background build (one slice per frame). Refresh the open window
-- when a build finishes so the "analyzing..." state is replaced with real data.
function M.EnsureAnalysis()
  if M._importJob then return end                          -- foreign import is writing the
                                                           -- store: no pairs() walks now
  if M._analysisJob then return end                        -- already building
  if M._analysis and not M._analysisStale then return end  -- fresh, nothing to do
  M._analysisJob = coroutine.create(runAnalysis)
  if not M._analysisFrame then
    local fr = CreateFrame("Frame")
    fr:SetScript("OnUpdate", function()
      local job = M._analysisJob
      if not job then fr:Hide(); return end
      local P, clock = M.perf, rawget(_G, "debugprofilestop")
      local t0 = P and clock and clock()
      local ok, err = coroutine.resume(job)
      if t0 then P.runMs = P.runMs + (clock() - t0) end
      if not ok then
        M._analysisJob = nil; fr:Hide()
        if M.Print then M.Print("analysis error: " .. tostring(err)) end
      elseif coroutine.status(job) == "dead" then
        M._analysisJob = nil; fr:Hide()
        if P then P.runs = P.runs + 1 end
        if M.FireAPIEvent then M.FireAPIEvent("ANALYSIS_COMPLETE", {}) end
        if M.frame and M.frame:IsShown() and M.RefreshUI then M.RefreshUI() end
        -- data changed while building: catch up with ONE deferred rebuild. The
        -- delay batches rapid sync merges instead of rebuilding per message.
        -- Only where somebody looks at the result (the window, or the AH where
        -- it opens next): out in the world the stale lists wait for the next
        -- reader instead of rebuilding behind every sync burst.
        if M._analysisStale and ((M.frame and M.frame:IsShown()) or M.AHOpen) then
          C_Timer.After(2, function() if M.EnsureAnalysis then M.EnsureAnalysis() end end)
        end
      end
    end)
    M._analysisFrame = fr
  end
  M._analysisFrame:Show()
end

-- ===== Ranking (whole archive) ==============================================
function M.RankAll()
  M.EnsureAnalysis()                    -- rebuilds in the background when stale
  if M._analysis then return M._analysis.ranked end
  return {}                             -- empty only until the very first build lands
end

-- Every item with scan data on this realm, for the Watchlist tab's "all items"
-- browse view: served from the same background analysis cache as RankAll.
function M.BrowseAll()
  M.EnsureAnalysis()
  if M._analysis then return M._analysis.all or {} end
  return {}
end

-- ===== Watchlist (account-wide, shared across all your characters) ==========
function M.IsWatched(key)
  return (M.db and M.db.watch and M.db.watch[tostring(key)]) == true
end

function M.ToggleWatch(key)
  key = tostring(key)
  if not M.db then return false end
  M.db.watch = M.db.watch or {}
  M.db.config = M.db.config or {}
  local rem = M.db.config.watchRemoved or {}
  M.db.config.watchRemoved = rem
  for i = #rem, 1, -1 do if rem[i] == key then table.remove(rem, i) end end -- de-dupe
  if M.db.watch[key] then
    M.db.watch[key] = nil
    table.insert(rem, 1, key)             -- remember as recently removed (front)
    for i = #rem, 21, -1 do rem[i] = nil end
    return false
  else
    M.db.watch[key] = true                -- (re)added -> no longer "removed"
    return true
  end
end

-- Recently removed watchlist items (most recent first), for quick re-adding.
function M.RecentlyRemoved()
  return (M.db and M.db.config and M.db.config.watchRemoved) or {}
end

-- ===== Starter watchlist ====================================================
-- A curated baseline for new installs: consumables, trade goods and flip
-- classics that move on most realms. The names also seed MidasDB.names, so a
-- fresh install shows real item names before its first scan (M.ItemName falls
-- back to that store; the client's own cache catches up on its own).
M.STARTER_WATCH = {
  { 2592, "Wool Cloth" },              { 2772, "Iron Ore" },
  { 2841, "Bronze Bar" },              { 3355, "Wild Steelbloom" },
  { 3356, "Kingsblood" },              { 3387, "Limited Invulnerability Potion" },
  { 3575, "Iron Bar" },                { 3576, "Tin Bar" },
  { 3820, "Stranglekelp" },            { 3821, "Goldthorn" },
  { 3824, "Shadow Oil" },              { 3825, "Elixir of Fortitude" },
  { 3829, "Frost Oil" },               { 3860, "Mithril Bar" },
  { 3864, "Citrine" },                 { 4306, "Silk Cloth" },
  { 4338, "Mageweave Cloth" },         { 4366, "Target Dummy" },
  { 4392, "Advanced Target Dummy" },   { 5267, "Scarlet Kris" },
  { 5633, "Great Rage Potion" },       { 5634, "Free Action Potion" },
  { 6370, "Blackmouth Oil" },          { 7067, "Elemental Earth" },
  { 7068, "Elemental Fire" },          { 7076, "Essence of Earth" },
  { 8393, "Scorpok Pincer" },          { 8394, "Basilisk Brain" },
  { 8396, "Vulture Gizzard" },         { 8838, "Sungrass" },
  { 8839, "Blindweed" },               { 8845, "Ghost Mushroom" },
  { 9088, "Gift of Arthas" },          { 9172, "Invisibility Potion" },
  { 9264, "Elixir of Shadow Power" },  { 10620, "Thorium Ore" },
  { 11176, "Dream Dust" },             { 12359, "Thorium Bar" },
  { 12360, "Arcanite Bar" },           { 12363, "Arcane Crystal" },
  { 12365, "Dense Stone" },            { 12404, "Dense Sharpening Stone" },
  { 12431, "Winterfall E'ko" },        { 12436, "Frostmaul E'ko" },
  { 12811, "Righteous Orb" },          { 12820, "Winterfall Firewater" },
  { 13423, "Stonescale Oil" },         { 13442, "Mighty Rage Potion" },
  { 13444, "Major Mana Potion" },      { 13445, "Elixir of Superior Defense" },
  { 13452, "Elixir of the Mongoose" }, { 13455, "Greater Stoneshield Potion" },
  { 13457, "Greater Fire Protection Potion" },
  { 13458, "Greater Nature Protection Potion" },
  { 13463, "Dreamfoil" },              { 13467, "Icecap" },
  { 13506, "Flask of Petrification" }, { 13510, "Flask of the Titans" },
  { 13759, "Raw Nightfin Snapper" },   { 13931, "Nightfin Soup" },
  { 14047, "Runecloth" },              { 14344, "Large Brilliant Shard" },
  { 14551, "Edgemaster's Handguards" },{ 15062, "Devilsaur Leggings" },
  { 15063, "Devilsaur Gauntlets" },    { 15994, "Thorium Widget" },
  { 16023, "Masterwork Target Dummy" },{ 18262, "Elemental Sharpening Stone" },
  { 19707, "Red Hakkari Bijou" },      { 19708, "Blue Hakkari Bijou" },
  { 19709, "Yellow Hakkari Bijou" },   { 19710, "Orange Hakkari Bijou" },
  { 19711, "Green Hakkari Bijou" },    { 19712, "Purple Hakkari Bijou" },
  { 19713, "Bronze Hakkari Bijou" },   { 19714, "Silver Hakkari Bijou" },
  { 19715, "Gold Hakkari Bijou" },     { 20007, "Mageblood Potion" },
  { 20424, "Sandworm Meat" },          { 20452, "Smoked Desert Dumplings" },
  { 21023, "Dirge's Kickin' Chimaerok Chops" },
  { 184937, "Chronoboon Displacer" },
}

-- Adds the starter set to the watchlist (on=true) or removes exactly the
-- entries it added earlier (on=false) -- the user's own picks always stay.
-- Returns how many items changed. Used by the Settings checkbox and the
-- one-shot first-login seed (Core.lua).
function M.ApplyStarterWatch(on)
  local db = M.db
  if not db then return 0 end
  db.watch = db.watch or {}
  db.config = db.config or {}
  local n = 0
  if on then
    local tag = db.config.starterAdded or {}
    db.config.starterAdded = tag
    db.names = db.names or {}
    local rem = db.config.watchRemoved
    for _, it in ipairs(M.STARTER_WATCH) do
      local id, nm = it[1], it[2]
      local key = tostring(id)
      if not db.names[id] then db.names[id] = nm end
      if not db.watch[key] then
        db.watch[key] = true
        tag[key] = true
        n = n + 1
        if rem then  -- no longer "recently removed" (same de-dupe as ToggleWatch)
          for i = #rem, 1, -1 do if rem[i] == key then table.remove(rem, i) end end
        end
      end
    end
  else
    local tag = db.config.starterAdded
    if tag then
      for key in pairs(tag) do
        if db.watch[key] then db.watch[key] = nil; n = n + 1 end
      end
    end
    db.config.starterAdded = nil
  end
  return n
end

-- ===== Watchlist groups =====================================================
-- config.watchGroups = ordered array of group names; config.watchGroupOf maps
-- itemKey -> group name (absent = ungrouped); config.watchGroupFold remembers
-- folded headers. Account-wide, like the list itself. An item keeps its group
-- assignment even while off the list, so re-adding files it back in.
function M.WatchGroups()
  local cfg = M.db and M.db.config
  return (cfg and cfg.watchGroups) or {}
end

function M.WatchGroupAdd(name)
  name = name and name:gsub("^%s+", ""):gsub("%s+$", "")
  if not name or name == "" then return false end
  if #name > 24 then name = name:sub(1, 24) end
  local cfg = M.db.config
  cfg.watchGroups = cfg.watchGroups or {}
  if #cfg.watchGroups >= 20 then return false end
  for _, g in ipairs(cfg.watchGroups) do
    if g:lower() == name:lower() then return false end
  end
  table.insert(cfg.watchGroups, name)
  return true
end

function M.WatchGroupRename(old, new)
  new = new and new:gsub("^%s+", ""):gsub("%s+$", "")
  if not new or new == "" or new == old then return false end
  if #new > 24 then new = new:sub(1, 24) end
  local cfg = M.db.config
  local gs = cfg.watchGroups or {}
  for _, g in ipairs(gs) do if g:lower() == new:lower() then return false end end
  for i, g in ipairs(gs) do
    if g == old then
      gs[i] = new
      if cfg.watchGroupOf then
        for k, v in pairs(cfg.watchGroupOf) do if v == old then cfg.watchGroupOf[k] = new end end
      end
      if cfg.watchGroupFold and cfg.watchGroupFold[old] then
        cfg.watchGroupFold[old] = nil; cfg.watchGroupFold[new] = true
      end
      return true
    end
  end
  return false
end

function M.WatchGroupDelete(name)
  local cfg = M.db.config
  local gs = cfg.watchGroups or {}
  for i, g in ipairs(gs) do
    if g == name then
      table.remove(gs, i)
      if cfg.watchGroupOf then
        for k, v in pairs(cfg.watchGroupOf) do if v == name then cfg.watchGroupOf[k] = nil end end
      end
      if cfg.watchGroupFold then cfg.watchGroupFold[name] = nil end
      return true
    end
  end
  return false
end

-- assign an item to a group (nil = back to ungrouped)
function M.WatchGroupSet(key, group)
  local cfg = M.db.config
  cfg.watchGroupOf = cfg.watchGroupOf or {}
  cfg.watchGroupOf[tostring(key)] = group
end

-- Every watched item with its metrics (m = nil if no data on this realm yet)
function M.RankWatch()
  local out = {}
  local watch = M.db and M.db.watch
  if not watch then return out end
  for key in pairs(watch) do
    local series = M.GetSeries(key)
    out[#out + 1] = { key = key, m = series and M.Metrics(series, key) or nil }
  end
  table.sort(out, function(a, b)
    local as = a.m and a.m.score or -1
    local bs = b.m and b.m.score or -1
    return as > bs
  end)
  return out
end

-- ===== Top Picks today ======================================================
-- Served from the background analysis cache (see runAnalysis). Returns
-- buys, sells, lastScanDay, pending -- pending=true while the first build is running.
function M.TopPicks()
  M.EnsureAnalysis()                    -- rebuilds in the background when stale
  local a = M._analysis
  if a then return a.buys, a.sells, a.last end
  return {}, {}, M.LastScanDay(), true
end
