-- Midas - Public API for other addons (TSM external price sources, ledgers, ...)
--
-- Everything lives on the global table `MidasAPI` (created when Midas loads; no
-- embedding or LibStub needed). Conventions:
--   * prices are COPPER (integers), odds are fractions in 0..1
--   * `item` accepts an itemID (number or "1529"), a full item LINK, an
--     "item:1529"-style string, or a raw Midas archive key ("1529" /
--     "gr:<id>:<suffix>"). A link of suffixed gear resolves to its BASE item;
--     suffix variants are addressable via their gr: archive key only.
--   * every getter returns nil when Midas has no data (yet) - handle nil!
--   * returned tables are fresh copies; mutating them never corrupts Midas.
--   * results come from the same generation-cached Metrics the Midas UI uses,
--     so per-tooltip call rates are fine (GetNetWorth is heavier - don't spam it).
--
--   MidasAPI.GetFairPrice(item)       -> copper | nil    (TSM source: MidasMarket)
--   MidasAPI.GetCurrentPrice(item)    -> copper | nil    (TSM source: MidasCurrent)
--   MidasAPI.GetQuickSellPrice(item)  -> copper | nil    (TSM source: MidasQuickSell)
--   MidasAPI.GetSellOdds(item, ask?)  -> 0..1 | nil      chance ONE 48h auction at
--                                        `ask` sells; ask omitted = current price
--   MidasAPI.GetScore(item)           -> number | nil    opportunity score (rank order)
--   MidasAPI.GetMarketInfo(item)      -> table | nil     everything in one call:
--       { itemKey, fair, current, quick, median, min, max, floor7, base,
--         odds, oddsAtFair, oddsAtQuick, score, margin, confidence, delta,
--         avgQty, days, lastDay, lastSeen (epoch), liquidity ("Fast".."Illiquid"),
--         soldPerDay (your own sales/day, nil without record) }
--   MidasAPI.GetHistory(item, days?)  -> array | nil     ascending {day, time, low, qty};
--                                        `days` caps to the last N calendar days
--   MidasAPI.GetTradeStats(item)      -> table | nil     YOUR record for the item:
--       { itemKey, sold, expired, sellThrough, avgBuyPrice, boughtUnits,
--         medianSellPrice, soldListings, soldPerDay, sellability, sellRate }
--   MidasAPI.GetDepth(item)           -> table | nil     offer book (sell-side depth) of the newest scan:
--       { ts, units, listed, auctions, levels = {{price, qty, auctions, cum}...} }
--       cheapest 20 unit prices, ascending; buyout-only; no seller names;
--       units = sum over those levels, listed = ALL units on the AH, auctions = all buyout auctions
--   MidasAPI.GetDepthSnapshot()       -> table | nil     the whole newest ladder, this realm:
--       { ts, market = {client, region, realm, faction, ruleset},
--         items = { [itemID] = { auctions, listed, levels = {{price, qty, auctions}...} } } }
--   MidasAPI.GetItemKeys()            -> array           every archive key, this realm
--   MidasAPI.GetNetWorth()            -> table | nil     account totals:
--       { total, money, items, auctions, graveyard, graveyardCount,
--         characters = {{name,total,money,items,auctions}...}, graveyardChars }
--   MidasAPI.GetLastScanDay()         -> day | nil       Midas day index (days since
--                                        2020-01-01 local midnight)
--   MidasAPI.GetLastScanTime()        -> epoch | nil     your last own full scan
--   MidasAPI.GetVersion()             -> "x.y.z", API_VERSION
--   MidasAPI.IsReady()                -> boolean         false before PLAYER_LOGIN
--
--   MidasAPI.RegisterCallback(event, fn) / UnregisterCallback(event, fn)
--     fn(event, payload) is called after the fact; errors are trapped. Events:
--       "SCAN_COMPLETE"     { day, items, ts, market } own AH scan stored
--       "ANALYSIS_COMPLETE" { }                       background analysis finished
--       "IMPORT_COMPLETE"   { source, items, rows }   foreign-addon import merged
--
--   MidasAPI.RegisterImportSource(def) -> ok, err
--     Feed YOUR addon's price history INTO Midas. Same contract as the built-in
--     Auctionator/aux sources (see Import.lua): def = { name, Available, Ready,
--     Fingerprint, Keys, Rows }. Merged low=MIN / qty=MAX; your own scans win.
--
-- TSM integration: TSM passes item links to external price sources - the three
-- price getters accept them directly, so the TSM-side registration is just
-- CustomString.RegisterSource("External", "MidasMarket", ..., MidasAPI.GetFairPrice-wrapper).
local ADDON, M = ...

local API = _G.MidasAPI or {}
_G.MidasAPI = API
API.API_VERSION = 1

-- item argument -> archive key ("1529" or "gr:<id>:<suffix>"), nil if unusable
local function keyOf(item)
  local t = type(item)
  if t == "number" then
    if item <= 0 then return nil end
    return tostring(math.floor(item))
  end
  if t ~= "string" or item == "" then return nil end
  local id = item:match("|Hitem:(%d+)") or item:match("^item:(%d+)")
  if id then return id end
  if item:match("^%d+$") then return item end
  if item:match("^gr?:%d+") then return item end   -- raw archive key (gear)
  return nil
end

local function metricsOf(item)
  if not (M.db and M.GetSeries and M.Metrics) then return nil end
  local key = keyOf(item)
  if not key then return nil end
  local series = M.GetSeries(key)
  if not series then return nil end
  return M.Metrics(series, key), key
end

local function copper(v)
  if not (v and v > 0) then return nil end
  return math.floor(v + 0.5)
end

-- Status ---------------------------------------------------------------------
function API.IsReady()
  return M.db ~= nil
end

function API.GetVersion()
  return M.version, API.API_VERSION
end

-- Prices ---------------------------------------------------------------------
function API.GetFairPrice(item)
  local m = metricsOf(item)
  return m and copper(m.fair) or nil
end

function API.GetCurrentPrice(item)
  local m = metricsOf(item)
  return m and copper(m.cur) or nil
end

function API.GetQuickSellPrice(item)
  local m = metricsOf(item)
  return m and copper(m.quick) or nil
end

function API.GetSellOdds(item, ask)
  local m = metricsOf(item)
  if not m then return nil end
  if ask == nil then return m.odds end
  ask = tonumber(ask)
  local o = m.oddsAtFair
  if not (ask and ask > 0 and o and o > 0 and o < 1 and m.fair and m.fair > 0) then return nil end
  -- the model curve: logit(odds) is linear in ln(price) with slope -FAIR_SLOPE,
  -- so (fair, oddsAtFair) reconstructs Metrics' internal curve exactly
  local z = math.log(o / (1 - o)) + (M.C.FAIR_SLOPE or 3) * math.log(m.fair / ask)
  return 1 / (1 + math.exp(-z))
end

function API.GetScore(item)
  local m = metricsOf(item)
  return m and m.score or nil
end

function API.GetMarketInfo(item)
  local m, key = metricsOf(item)
  if not m then return nil end
  return {
    itemKey = key,
    fair = copper(m.fair), current = copper(m.cur), quick = copper(m.quick),
    median = copper(m.med), min = copper(m.min), max = copper(m.max),
    floor7 = copper(m.floor7), base = copper(m.base),
    odds = m.odds, oddsAtFair = m.oddsAtFair, oddsAtQuick = m.oddsAtQuick,
    score = m.score, margin = m.margin, confidence = m.conf, delta = m.delta,
    avgQty = m.avgQty, days = m.days, lastDay = m.lastDay,
    lastSeen = m.lastDay and (m.lastDay * 86400 + M.C.SCAN_DAY_0) or nil,
    liquidity = m.liqLabel, soldPerDay = m.speed,
  }
end

-- History / archive ----------------------------------------------------------
function API.GetHistory(item, days)
  if not (M.db and M.GetSeries) then return nil end
  local key = keyOf(item)
  local series = key and M.GetSeries(key)
  if not series then return nil end
  local minDay = (type(days) == "number" and days > 0) and (M.GetScanDay() - days) or nil
  local out = {}
  for d, v in pairs(series) do
    if v.low and (not minDay or d > minDay) then
      out[#out + 1] = { day = d, time = d * 86400 + M.C.SCAN_DAY_0, low = v.low, qty = v.qty or 0 }
    end
  end
  table.sort(out, function(a, b) return a.day < b.day end)
  return out
end

function API.GetItemKeys()
  if not (M.db and M.IterItems) then return {} end
  local out = {}
  for key in pairs(M.IterItems()) do out[#out + 1] = key end
  table.sort(out)
  return out
end

-- Supply ladder -----------------------------------------------------------------
function API.GetDepth(item)
  if not (M.db and M.GetDepth) then return nil end
  local key = keyOf(item)
  local id = key and (tonumber(key) or tonumber(key:match("^gr?:(%d+)")))
  local d = id and M.GetDepth(id)
  if not d then return nil end
  local levels = {}
  for i, l in ipairs(d.levels) do
    levels[i] = { price = l.price, qty = l.qty, auctions = l.auctions, cum = l.cum }
  end
  return { ts = d.ts, units = d.units, listed = d.listed, auctions = d.auctions, levels = levels }
end

function API.GetDepthSnapshot()
  local d = M.db and M.db.depth and M.db.depth[M.RealmKey()]
  if not (d and d.items) then return nil end
  local mk = d.market or {}
  local items = {}
  for id, flat in pairs(d.items) do
    local lv = {}
    for i = 2, #flat, 3 do lv[#lv + 1] = { price = flat[i], qty = flat[i + 1], auctions = flat[i + 2] } end
    items[id] = { auctions = flat[1], listed = d.qty and d.qty[id], levels = lv }
  end
  return {
    ts = d.ts,
    market = { client = mk.client, region = mk.region, realm = mk.realm, faction = mk.faction, ruleset = mk.ruleset },
    items = items,
  }
end

function API.GetLastScanDay()
  if not (M.db and M.LastScanDay) then return nil end
  local d = M.LastScanDay()
  if d and d >= 0 then return d end
  return nil
end

function API.GetLastScanTime()
  return M.db and M.db.config and M.db.config.lastIngest or nil
end

-- Own trade record ------------------------------------------------------------
function API.GetTradeStats(item)
  if not M.db then return nil end
  local key = keyOf(item)
  if not key then return nil end
  local soldN, retN = 0, 0
  if M.OutcomeCounts then soldN, retN = M.OutcomeCounts(key) end
  local avgBuy, boughtUnits, medSell, soldListings, soldPerDay
  if M.RealizedBuy then avgBuy, boughtUnits = M.RealizedBuy(key) end
  if M.RealizedSell then medSell, soldListings, soldPerDay = M.RealizedSell(key) end
  local out = {
    itemKey = key,
    sold = soldN, expired = retN,
    sellThrough = (soldN + retN) > 0 and soldN / (soldN + retN) or nil,
    avgBuyPrice = copper(avgBuy), boughtUnits = boughtUnits or 0,
    medianSellPrice = copper(medSell),
    soldListings = soldListings or 0, soldPerDay = soldPerDay or 0,
  }
  if M.Sellability then
    -- the rating is keyed by item name, not by archive key
    local tk = M.TradeKeyForID and M.TradeKeyForID(key)
    local ok, s = pcall(M.Sellability, tk or key)
    if ok and s then out.sellability, out.sellRate = s.label, s.rate end
  end
  return out
end

-- Net worth -------------------------------------------------------------------
function API.GetNetWorth()
  if not (M.db and M.NetWorth) then return nil end
  local nw = M.NetWorth()
  if not nw then return nil end
  local chars = {}
  for _, c in pairs(nw.chars or {}) do
    chars[#chars + 1] = { name = c.name, total = c.total, money = c.money,
                          items = c.items, auctions = c.auctions }
  end
  table.sort(chars, function(a, b) return (a.total or 0) > (b.total or 0) end)
  local grave = {}
  for i, g in ipairs(nw.grave or {}) do
    grave[i] = { name = g.name, total = g.total, diedAt = g.deadTs }
  end
  return {
    total = nw.total, money = nw.money, items = nw.itemsTotal, auctions = nw.auctionsTotal,
    graveyard = nw.graveTotal, graveyardCount = nw.graveCount,
    characters = chars, graveyardChars = grave,
  }
end

-- Callbacks -------------------------------------------------------------------
local callbacks = {}

function API.RegisterCallback(event, fn)
  if type(event) ~= "string" or type(fn) ~= "function" then return false end
  callbacks[event] = callbacks[event] or {}
  callbacks[event][fn] = true
  return true
end

function API.UnregisterCallback(event, fn)
  local t = callbacks[event]
  if t then t[fn] = nil end
end

-- internal: Data/Logic/Import call this at their completion points. A broken
-- foreign callback must never break Midas -> trapped, routed to the error frame.
function M.FireAPIEvent(event, payload)
  local t = callbacks[event]
  if not t then return end
  for fn in pairs(t) do
    local ok, err = pcall(fn, event, payload)
    if not ok then geterrorhandler()(err) end
  end
end

-- Import bridge ---------------------------------------------------------------
function API.RegisterImportSource(def)
  if type(def) ~= "table" or type(def.name) ~= "string"
     or type(def.Available) ~= "function" or type(def.Ready) ~= "function"
     or type(def.Fingerprint) ~= "function" or type(def.Keys) ~= "function"
     or type(def.Rows) ~= "function" then
    return false, "need { name, Available, Ready, Fingerprint, Keys, Rows } - see Import.lua"
  end
  M.RegisterImportSource(def)
  return true
end

-- /midas api ------------------------------------------------------------------
function M.PrintAPIInfo()
  local n = 0
  for _, t in pairs(callbacks) do
    for _ in pairs(t) do n = n + 1 end
  end
  M.Print("public API v" .. API.API_VERSION .. " (addon " .. M.version .. ") - global MidasAPI, "
    .. n .. " callback(s) registered. Docs: top of API.lua + README.")
end
