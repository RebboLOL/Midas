-- Midas - Datalink: the link between Midas and the Midas Companion desktop app
-- (midasmarket.app). Until 1.2.28 this was the separate addon Midas_Uplink.
--
-- Addons cannot talk to the network. After every own full scan the Datalink
-- copies the newest offer book (MidasAPI.GetDepthSnapshot) into
-- MidasUplinkDB, a SavedVariable of Midas (WTF\...\SavedVariables\Midas.lua).
-- After every complete price scan (Midas' own or another addon's, stored
-- with depth = false) it copies that scan's rows (MidasAPI.GetLastScanRows:
-- cheapest unit price and units listed per item) into a list of its own,
-- pqueue - apps before 1.3.1 (1.3.0) only read queue and never take a price scan for
-- an offer book. Quick scans (only some items) are never shared.
-- WoW writes that file on /reload or logout; the companion app picks new
-- snapshots up there.
--
-- Privacy: opt-in (off until /midas datalink on or the Settings switch). A
-- snapshot holds the market (client, region, realm, faction, ruleset) and per
-- item the listed units, buyout auctions and the 20 cheapest unit prices (a
-- price snapshot: only the listed units and the cheapest unit price). No
-- character, account, guild or seller names, no money, no bags. For the items
-- of a snapshot the game's own item data comes along: name and quality (in
-- the client language) and the basic item data (icon, type, binding, levels,
-- slot, stack size, vendor price) - the same for every player.
--
-- Server prices (the other way round): the companion app writes the daily
-- prices of the markets you play on into Prices.lua (MidasUplinkPrices,
-- loaded before this file). They are offered to the importer as the source
-- "Midas Server" - only the entry of your own market, no live price (no
-- cur/ts), so your own scans stay authoritative. Works without the upload
-- opt-in; /midas prices off turns it off. The app learns which markets to
-- fetch from MidasUplinkDB.seen (written at every login, kept on this PC; it
-- leaves it only as the query of the price download). Prices.lua also tells
-- whether the app runs: app = "<app version>", checked = <time of its last
-- successful server query>; the app writes the file even without prices.
--
-- Price history: once per market, while sharing is ON, the daily values Midas
-- keeps for the market (last 90 days, own and synced scans only, no imported
-- or server values) are prepared for the app, which sends them a single time
-- (see "price history backfill" below).
--
-- Transition: while the old addon Midas_Uplink is still loaded, the Datalink
-- stays passive (no second capture, no second import source) and says once
-- per session that the folder can go. Both addons declare MidasUplinkDB, so
-- the old addon's state is written into Midas.lua as well and carries over.
--
-- MidasUplinkDB = {
--   format  = 1,
--   addon   = M.version               Midas version that wrote the file
--   enabled = false,
--   seq     = <last snapshot number>,
--   queue   = { snapshot, ... }  oldest first, at most QUEUE_MAX
--   pqueue  = { price snapshot, ... }  oldest first, at most PQUEUE_MAX;
--             seq counts on with queue (one number per snapshot of either kind)
--   names   = { [itemID] = "Name" }   item names in the client language
--   quality = { [itemID] = 0..7 }
--   locale  = GetLocale()             names/quality are wiped when it changes
--   meta    = { [itemID] = "icon:class:sub:bind:ilvl:req:slot:stack:sell" }
--             basic item data from the game (see "item data" below); the same
--             in every client language, so it stays when the locale changes
--   metaV   = 1                       layout of the meta strings
--   prices  = true | false            server prices used by Midas (default on)
--   seen    = { ["client|region|realm|faction"] =
--               { client, region, realm, faction, ruleset, last = time() } }
--             at most SEEN_MAX, oldest dropped
--   history = { ["client|region|realm|faction"] = block }   prepared price history
--   histDone = { ["client|region|realm|faction"] = time() }  prepared once, never again
-- }
-- snapshot = { v = 1, seq, ts, addon, market = {...}, count,
--              items = { [itemID] = "listed,auctions,p1,q1,n1,p2,q2,n2,..." } }
-- p = unit buyout in copper (ascending), q = units, n = auctions at p.
-- price snapshot = { v = 1, kind = "prices", seq, ts, addon, market = {...}, count,
--                    items = { [itemID] = "listed,low" } }
-- listed = units listed (>= 0), low = cheapest unit buyout in copper (> 0);
-- items without an offer are left out.
--
-- MidasUplinkPrices = { v = 1, app, checked, written, markets = { { market = "forever/EU/pve/alliance",
--   ts, day0, match = { { client, region, realm, faction }, ... },
--   items = { [itemID] = "off:low:qty;off:low:qty;..." } }, ... } }
-- off = UTC days after day0 (UTC midnight), low = day minimum (copper),
-- qty = day maximum of listed units.
local ADDON, M = ...

local FORMAT    = 1
local QUEUE_MAX = 5
local PQUEUE_MAX = 3                  -- price snapshots kept (~6,000 short strings each)
local PQ_SAY_GAP = 1800               -- seconds between two "price scan queued" chat lines
local PRICE_MAX  = 1e11               -- above this a unit price is not believed (gold cap ~2.1e9)
local LISTED_MAX = 1e9                -- units listed above this count as unknown (0)
local LEVELS_MAX  = 20                -- server limit per item
local ITEM_ID_MAX = 10000000
local MAX_AGE     = 6 * 86400         -- older scans are not queued (server: 7 days)
local MAX_AHEAD   = 600               -- clock skew tolerated (server: 10 min)
local NAME_CHUNK  = 500               -- item lookups per frame
local META_V      = 1                 -- layout of MidasUplinkDB.meta
local SEEN_MAX    = 20                -- remembered markets
local SOURCE      = "Midas Server"    -- import source name shown by Midas
local PRICES_V    = 1
local LEGACY      = "Midas_Uplink"    -- the old separate addon
-- Midas day index: days since 2020-01-01 LOCAL midnight (M.C.SCAN_DAY_0)
local DAY_0       = time({ year = 2020, month = 1, day = 1, hour = 0 })
local PRUNE_DAYS  = 730               -- Midas history horizon (M.C.PRUNE_DAYS)
local LOW_MAX     = 5e8               -- same plausibility limits as Midas' imports
local QTY_MAX     = 1e5

M.DATALINK_URL = "https://midasmarket.app/download"

local function say(msg) M.Print("Datalink: " .. msg) end

local db
local passive = false                 -- the old Midas_Uplink addon is loaded

-- the old addon, loaded next to Midas (checked lazily: at file load time of
-- Midas it has not loaded yet, at login and later it has)
local function legacyLoaded()
  local f = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  if type(f) ~= "function" then return false end
  local ok, loaded = pcall(f, LEGACY)
  return (ok and loaded) and true or false
end

local function midasVersion() return tostring(M.version or "?") end

local function initDB()
  MidasUplinkDB = type(MidasUplinkDB) == "table" and MidasUplinkDB or {}
  db = MidasUplinkDB
  if db.format ~= FORMAT then          -- unknown/older layout: start clean
    db.queue = {}
    db.pqueue = {}
    db.format = FORMAT
  end
  db.queue = type(db.queue) == "table" and db.queue or {}
  db.pqueue = type(db.pqueue) == "table" and db.pqueue or {}
  while #db.pqueue > PQUEUE_MAX do table.remove(db.pqueue, 1) end
  db.seq = tonumber(db.seq) or 0
  if db.enabled == nil then db.enabled = false end
  if db.prices ~= false then db.prices = true end
  if type(db.seen) ~= "table" then db.seen = {} end
  if type(db.history) ~= "table" then db.history = {} end
  if type(db.histDone) ~= "table" then db.histDone = {} end
  db.addon = midasVersion()
  local loc = GetLocale and GetLocale() or "enUS"
  if db.locale ~= loc or type(db.names) ~= "table" or type(db.quality) ~= "table" then
    db.names, db.quality = {}, {}         -- other client language: start over
    db.locale = loc
  end
  if db.metaV ~= META_V or type(db.meta) ~= "table" then
    db.meta = {}                          -- other layout: collect again
    db.metaV = META_V
  end
end

-- ===== item data ==============================================================
-- meta[itemID] = "icon:class:sub:bind:ilvl:req:slot:stack:sell" (metaV = 1)
--   icon  = file ID of the icon (0 = unknown)
--   class, sub = classID, subclassID      bind = bindType
--   ilvl  = item level                    req  = required level
--   slot  = equip location ("INVTYPE_HEAD"; empty when the item is not worn)
--   stack = stack size                    sell = vendor price in copper
-- Whole numbers >= 0 only; slot only [A-Z0-9_], at most 30 characters. Nothing
-- of it depends on the client language or on the player.
-- The values come from GetItemInfo, which has the same return order on all
-- three clients (Era 11509, Forever 16001, TBC 20506), as C_Item.GetItemInfo
-- or as the global:
--   1 name, 2 link, 3 quality, 4 itemLevel, 5 itemMinLevel, 6 itemType,
--   7 itemSubType, 8 itemStackCount, 9 itemEquipLoc, 10 icon, 11 sellPrice,
--   12 classID, 13 subclassID, 14 bindType
-- GetItemInfoInstant (itemID, itemType, itemSubType, itemEquipLoc, icon,
-- classID, subclassID) fills icon, class and slot where GetItemInfo leaves
-- them out. An entry is only written when the item is in the client cache
-- (GetItemInfo answers) and class, levels, stack and price are all there;
-- otherwise the item is asked again at the next scan. An entry that exists is
-- never asked again. Like names, meta only holds items of shared snapshots
-- and stays when sharing is switched off (no player data, nothing is sent
-- while sharing is off).
local META_NUM_MAX = 2147483647         -- above this a value is not believed
local SLOT_MAX     = 30

-- whole number 0..META_NUM_MAX or nil
local function metaNum(v)
  v = tonumber(v)
  if not v or v ~= v or v < 0 or v > META_NUM_MAX then return nil end
  return math.floor(v)
end

-- equip location as sent: "" for items that are not worn (newer clients say
-- INVTYPE_NON_EQUIP or INVTYPE_NON_EQUIP_IGNORE there) and for anything odd
local function metaSlot(v)
  if type(v) ~= "string" or v == "" or #v > SLOT_MAX or v:find("[^A-Z0-9_]") then return "" end
  if v == "INVTYPE_NON_EQUIP" or v == "INVTYPE_NON_EQUIP_IGNORE" then return "" end
  return v
end

local function metaString(id, ilvl, req, stack, slot, icon, sell, class, sub, bind)
  local iicon, iclass, isub, islot
  if not metaNum(icon) or metaNum(icon) == 0 or not metaNum(class) or not metaNum(sub) or type(slot) ~= "string" then
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if fn then
      local ok, _, _, _, s, i, c, sc = pcall(fn, id)
      if ok then islot, iicon, iclass, isub = s, i, c, sc end
    end
  end
  icon = metaNum(icon)
  if not icon or icon == 0 then icon = metaNum(iicon) or 0 end
  if not metaNum(class) or not metaNum(sub) then class, sub = iclass, isub end
  class, sub = metaNum(class), metaNum(sub)
  if type(slot) ~= "string" then slot = islot end
  ilvl, req, stack, sell = metaNum(ilvl), metaNum(req), metaNum(stack), metaNum(sell)
  if not (class and sub and ilvl and req and stack and sell) then return nil end
  return string.format("%d:%d:%d:%d:%d:%d:%s:%d:%d",
    icon, class, sub, metaNum(bind) or 0, ilvl, req, metaSlot(slot), stack, sell)
end

-- Item info lookup: C_Item.GetItemInfo where present, else GetItemInfo.
-- Returns name, quality, meta string (or nil) - nil when the item is not in
-- the client cache yet.
local function itemInfo(id)
  local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not fn then return nil end
  local ok, name, _, quality, ilvl, req, _, _, stack, slot, icon, sell, class, sub, bind = pcall(fn, id)
  if ok and type(name) == "string" and name ~= "" then
    return name, tonumber(quality), metaString(id, ilvl, req, stack, slot, icon, sell, class, sub, bind)
  end
  return nil
end

-- Fallback: names Midas itself keeps (account-wide). Its seed list is English,
-- so it is only trusted on English clients.
local function midasName(id)
  local loc = db.locale or ""
  if loc ~= "enUS" and loc ~= "enGB" then return nil end
  local t = type(MidasDB) == "table" and MidasDB.names
  local nm = type(t) == "table" and t[id]
  if type(nm) == "string" and nm ~= "" then return nm end
  return nil
end

local function lookupName(id)
  local names, qual, meta = db.names, db.quality, db.meta
  if names[id] and qual[id] and meta[id] then return end
  local nm, q, mt = itemInfo(id)
  if nm then
    names[id] = nm
    if q and q >= 0 and q <= 7 then qual[id] = math.floor(q) end
    if mt and not meta[id] then meta[id] = mt end
  elseif not names[id] then
    names[id] = midasName(id)
  end
end

-- Fill names/quality/meta for every item of a snapshot that still lacks them
-- (one lookup per item for all three), NAME_CHUNK lookups per frame so a big
-- scan does not stall the client. Items the client has not cached yet are
-- retried at the next scan.
local pending, pendingN, nameJob = {}, 0, false

local function nameStep()
  local done = 0
  while pendingN > 0 and done < NAME_CHUNK do
    local id = pending[pendingN]
    pending[pendingN] = nil
    pendingN = pendingN - 1
    lookupName(id)
    done = done + 1
  end
  if pendingN > 0 then
    C_Timer.After(0, nameStep)
  else
    nameJob = false
  end
end

local function collectNames(s)
  local names, qual, meta = db.names, db.quality, db.meta
  for id in pairs(s.items) do
    if not names[id] or not qual[id] or not meta[id] then
      pendingN = pendingN + 1
      pending[pendingN] = id
    end
  end
  if nameJob or pendingN == 0 then return end
  if C_Timer and C_Timer.After then
    nameJob = true
    C_Timer.After(0, nameStep)
  else
    while pendingN > 0 do lookupName(pending[pendingN]); pending[pendingN] = nil; pendingN = pendingN - 1 end
  end
end

-- MidasAPI snapshot -> compact uplink snapshot (nil when nothing usable)
local function encode(snap)
  if type(snap) ~= "table" or type(snap.items) ~= "table" or not snap.ts then return nil end
  local mk = snap.market or {}
  if not mk.client or not mk.region or mk.region == "?" or not mk.faction then return nil end
  local items, count = {}, 0
  local parts = {}
  for id, it in pairs(snap.items) do
    local itemID = tonumber(id)
    local lv = type(it) == "table" and it.levels
    if itemID and itemID > 0 and itemID <= ITEM_ID_MAX and type(lv) == "table" then
      -- keep only valid levels: price >= 1, qty >= 1, prices strictly ascending
      local n, sumq, lastp = 2, 0, 0
      for i = 1, #lv do
        local l = lv[i]
        local p = math.floor(tonumber(type(l) == "table" and l.price) or 0)
        local q = math.floor(tonumber(type(l) == "table" and l.qty) or 0)
        local a = math.floor(tonumber(type(l) == "table" and l.auctions) or 0)
        if p >= 1 and q >= 1 and p > lastp and n < 2 + 3 * LEVELS_MAX then
          if a < 1 then a = 1 end
          parts[n + 1] = tostring(p)
          parts[n + 2] = tostring(q)
          parts[n + 3] = tostring(a)
          n = n + 3
          sumq = sumq + q
          lastp = p
        end
      end
      if n > 2 then
        local listed = math.floor(tonumber(it.listed) or 0)
        if listed < sumq then listed = sumq end
        local auctions = math.floor(tonumber(it.auctions) or 0)
        if auctions < 0 then auctions = 0 end
        parts[1] = tostring(listed)
        parts[2] = tostring(auctions)
        for i = #parts, n + 1, -1 do parts[i] = nil end
        items[itemID] = table.concat(parts, ",", 1, n)
        count = count + 1
      end
    end
  end
  if count == 0 then return nil end
  return {
    v = FORMAT,
    ts = snap.ts,
    addon = midasVersion(),
    market = { client = mk.client, region = mk.region, realm = mk.realm,
               faction = mk.faction, ruleset = mk.ruleset },
    count = count,
    items = items,
  }
end

local function push(s)
  local q = db.queue
  local last = q[#q]
  if last and last.ts == s.ts and last.market and last.market.realm == s.market.realm
     and last.market.faction == s.market.faction then
    return false                        -- same scan twice
  end
  db.seq = db.seq + 1
  s.seq = db.seq
  q[#q + 1] = s
  while #q > QUEUE_MAX do table.remove(q, 1) end
  return true
end

-- the DATALINK block of the Settings tab shows the queue lengths (UI.lua)
local function refreshBlock()
  local s = M.setUI
  if s and s.dlApp and M.RefreshDatalink then pcall(M.RefreshDatalink, s) end
end

local function capture(quiet)
  if passive or not db or not db.enabled then return end
  if not (MidasAPI and MidasAPI.GetDepthSnapshot) then return end
  local ok, snap = pcall(MidasAPI.GetDepthSnapshot)
  if not ok then geterrorhandler()(snap); return end
  local s = encode(snap)
  if not s then
    if not quiet then say("no offer book to share yet - run a full scan first.") end
    return
  end
  local now = time()
  local ts = tonumber(s.ts) or 0
  if now - ts > MAX_AGE or ts - now > MAX_AHEAD then
    if not quiet then say("the newest offer book is too old to share - run a full scan first.") end
    return
  end
  local added = push(s)
  collectNames(s)                       -- also retries names on a repeated scan
  if added then
    refreshBlock()
    say(string.format("scan queued (%d items). The companion app picks it up after the next /reload or logout.", s.count))
  elseif not quiet then
    say("the newest scan is already queued.")
  end
end

-- ===== price scans ============================================================
-- MidasAPI.GetLastScanRows -> price snapshot (nil when nothing usable)
local function encodePrices(rows)
  if type(rows) ~= "table" or rows.depth ~= false or type(rows.items) ~= "table" or not tonumber(rows.ts) then
    return nil
  end
  local mk = rows.market or {}
  if not mk.client or not mk.region or mk.region == "?" or not mk.faction then return nil end
  local items, count = {}, 0
  for id, r in pairs(rows.items) do
    local itemID = tonumber(id)
    local low = type(r) == "table" and tonumber(r.low)
    if itemID and itemID > 0 and itemID <= ITEM_ID_MAX and itemID % 1 == 0
       and low and low >= 1 and low <= PRICE_MAX then
      low = math.floor(low)
      local listed = tonumber(r.qty) or 0
      if not (listed >= 0 and listed <= LISTED_MAX) then listed = 0 end   -- also NaN
      items[itemID] = tostring(math.floor(listed)) .. "," .. tostring(low)
      count = count + 1
    end
  end
  if count == 0 then return nil end
  return {
    v = FORMAT,
    kind = "prices",
    ts = tonumber(rows.ts),
    addon = midasVersion(),
    market = { client = mk.client, region = mk.region, realm = mk.realm,
               faction = mk.faction, ruleset = mk.ruleset },
    count = count,
    items = items,
  }
end

local function sameScan(a, b)
  local ma, mb = a.market, b.market
  return a.ts == b.ts and type(ma) == "table" and type(mb) == "table" and ma.client == mb.client
    and ma.region == mb.region and ma.realm == mb.realm and ma.faction == mb.faction
end

local function pushPrices(s)
  local q = db.pqueue
  for i = 1, #q do
    if type(q[i]) == "table" and sameScan(q[i], s) then return false end   -- same scan twice
  end
  db.seq = db.seq + 1
  s.seq = db.seq
  q[#q + 1] = s
  while #q > PQUEUE_MAX do table.remove(q, 1) end
  return true
end

local lastPriceSay = 0                  -- price scans come often: one chat line per PQ_SAY_GAP

-- ts = the scan the SCAN_COMPLETE event announced (nil: whatever is newest)
local function capturePrices(ts)
  if passive or not db or not db.enabled then return end
  if not (MidasAPI and MidasAPI.GetLastScanRows) then return end
  local ok, rows = pcall(MidasAPI.GetLastScanRows)
  if not ok then geterrorhandler()(rows); return end
  if type(rows) ~= "table" or (ts and rows.ts ~= ts) then return end
  local s = encodePrices(rows)
  if not s then return end
  local now = time()
  if now - s.ts > MAX_AGE or s.ts - now > MAX_AHEAD then return end
  local added = pushPrices(s)
  collectNames(s)
  if added then refreshBlock() end
  if added and now - lastPriceSay >= PQ_SAY_GAP then
    lastPriceSay = now
    say(string.format("price scan queued (%d items). The companion app picks it up after the next /reload or logout.", s.count))
  end
end

-- ===== market memory ==========================================================
-- The market of the logged-in character with the same fields the snapshot
-- carries (Core.lua M.MarketInfo, the market every scan is filed under).
local function marketInfo()
  return M.MarketInfo()
end

-- usable like a snapshot market (encode() rejects the same cases)
local function marketOK(mk)
  return type(mk) == "table" and type(mk.client) == "string" and type(mk.region) == "string"
    and mk.region ~= "?" and type(mk.realm) == "string" and type(mk.faction) == "string"
end

local function marketKey(mk)
  return mk.client .. "|" .. mk.region .. "|" .. mk.realm .. "|" .. mk.faction
end

local function rememberMarket(mk)
  if not db or not marketOK(mk) then return end
  local seen = db.seen
  local key = marketKey(mk)
  seen[key] = { client = mk.client, region = mk.region, realm = mk.realm,
                faction = mk.faction, ruleset = mk.ruleset, last = time() }
  local n = 0
  for k, v in pairs(seen) do
    if type(v) ~= "table" then seen[k] = nil else n = n + 1 end
  end
  while n > SEEN_MAX do
    local oldK, oldT
    for k, v in pairs(seen) do
      local t = tonumber(v.last) or 0
      if k ~= key and (not oldT or t < oldT) then oldK, oldT = k, t end
    end
    if not oldK then break end
    seen[oldK] = nil
    n = n - 1
  end
end

-- ===== server prices -> Midas import source ===================================
local function pricesOn()
  return type(MidasUplinkPrices) == "table"
    and not (type(MidasUplinkDB) == "table" and MidasUplinkDB.prices == false)
end

-- The server's key of a Forever market: "forever/<region>/<ruleset>/<faction>",
-- e.g. "forever/EU/pve/alliance" - region as it is, ruleset and faction lower
-- case, the ruleset reduced to a-z, 0-9 and "-" ("RPPvP" -> "rppvp",
-- "Normal" -> "normal"). nil for every other client: Era and Anniversary
-- markets carry the realm and are only matched through the match list.
local function foreverKey(mk)
  if mk.client ~= "forever" or type(mk.ruleset) ~= "string" then return nil end
  local rs = mk.ruleset:lower():gsub("[^a-z0-9%-]", "")
  if rs == "" then return nil end
  return "forever/" .. mk.region .. "/" .. rs .. "/" .. mk.faction:lower()
end

-- The Prices.lua entry of this character's market, or nil: the entry whose
-- match list holds the market (client, region, realm, faction). On Forever an
-- entry whose market key is this character's counts as well - the companion
-- app cannot know the realm name before the first logout and then writes
-- match = {} - but an entry found through the match list comes first.
local function priceEntry()
  local P = MidasUplinkPrices
  if type(P) ~= "table" or P.v ~= PRICES_V or type(P.markets) ~= "table" then return nil end
  local mk = marketInfo()
  if not marketOK(mk) then return nil end
  local fkey = foreverKey(mk)
  local byKey
  for _, e in ipairs(P.markets) do
    if type(e) == "table" and type(e.items) == "table" and type(e.match) == "table"
       and tonumber(e.day0) and tonumber(e.ts) and (type(e.market) == "string" or type(e.market) == "number") then
      for _, m in ipairs(e.match) do
        if type(m) == "table" and m.client == mk.client and m.region == mk.region
           and m.realm == mk.realm and m.faction == mk.faction then
          return e
        end
      end
      if fkey and not byKey and e.market == fkey then byKey = e end
    end
  end
  return byKey
end

local function scanDay()
  return math.floor((time() - DAY_0) / 86400)
end

-- "off:low:qty;..." of one item -> archive key, { [midasDay] = { low, qty } } | nil.
-- A UTC day is filed under the Midas (local) day that holds its noon.
local function priceRows(e, key)
  local id = tonumber(key)
  if not id or id < 1 or id > ITEM_ID_MAX or id % 1 ~= 0 then return nil end
  local s = e.items[key]
  if type(s) ~= "string" or s == "" then return nil end
  local day0 = tonumber(e.day0)
  if not day0 then return nil end
  local base = day0 + 43200 - DAY_0
  local today = scanDay()
  local minDay = today - PRUNE_DAYS
  local out, any = {}, false
  for seg in s:gmatch("[^;]+") do
    local o, l, q = seg:match("^%s*(%d+):(%d+):(%d+)%s*$")
    if o then
      local d = math.floor((base + tonumber(o) * 86400) / 86400)
      local low, qty = tonumber(l), tonumber(q)
      if d > minDay and d <= today + 1 and low > 0 and low <= LOW_MAX then
        if qty > QTY_MAX then qty = 0 end
        local r = out[d]
        if not r then out[d] = { low, qty }; any = true
        else
          if low < r[1] then r[1] = low end
          if qty > r[2] then r[2] = qty end
        end
      end
    end
  end
  if not any then return nil end
  return string.format("%d", id), out
end

local priceSource = {
  name = SOURCE,
  -- the old Midas_Uplink registers the same source while it is loaded
  Available = function() return pricesOn() and not legacyLoaded() end,
  Ready = priceEntry,
  Fingerprint = function(e)
    -- day0 belongs in it: a longer period (14 -> 90 days) of the same server
    -- state must import again
    return "srv:" .. tostring(e.market) .. ":" .. tostring(e.ts) .. ":" .. tostring(e.day0)
  end,
  Keys = function(e)   -- one frame: a plain walk, about 6,000 keys
    local keys, n = {}, 0
    for k in pairs(e.items) do n = n + 1; keys[n] = k end
    return keys
  end,
  Rows = priceRows,
}

if MidasAPI and type(MidasAPI.RegisterImportSource) == "function" then
  pcall(MidasAPI.RegisterImportSource, priceSource)
end

-- ===== price history backfill =================================================
-- Once per market and installation, while sharing is ON: the daily values
-- (low, qty) Midas keeps for this market, last HIST_DAYS days up to yesterday,
-- go into MidasUplinkDB.history[<client|region|realm|faction>] for the
-- companion app, which sends them a single time. Only rows of real scans: a
-- row needs Midas' scan timestamp (ts) - imported rows (Auctionator, aux, the
-- "Midas Server" source) carry none. Quick-scan rows, the running day and day
-- lows equal to the loaded server price of that item and day (the import
-- merges by MIN and may have lowered an own row) stay out, so server prices
-- travel back as little as the archive allows. Midas does not mark imported
-- values (Import.lua merges low = MIN / qty = MAX into existing rows without a
-- flag): an own row whose low was lowered by an import of an OLDER server file
-- cannot be told apart. The server therefore never exports history days of an
-- item without a live day in the export window. Midas' archive is only read.
-- Midas days are LOCAL days (SCAN_DAY_0); each one is filed under the UTC day
-- that holds its noon (the inverse of the server price mapping above).
-- history[key] = { v = 1, created, addon, market = {...}, day0 = <UTC midnight>,
--   days, rows, count, items = { [itemID] = "off:low:qty;..." } }   off = UTC days after day0
-- histDone[key] = time() when the block was prepared (never prepared twice).
local HIST_V         = 1
local HIST_DAYS      = 90
local HIST_KEEP      = 7 * 86400   -- an unsent block is dropped after this
local HIST_CHUNK     = 400         -- items per frame
local HIST_ITEMS_MAX = 30000       -- server limits
local HIST_ROWS_MAX  = 400000
local HIST_DELAY     = 15          -- seconds after login: Midas finishes its own start first

local function utcDay(midasDay)
  return math.floor((DAY_0 + midasDay * 86400 + 43200) / 86400)
end

-- the store Midas keeps for this character's market (Core.lua M.RealmKey)
local function midasStore()
  if type(MidasDB) ~= "table" or type(MidasDB.realms) ~= "table" then return nil end
  return MidasDB.realms[M.RealmKey()], true
end

-- { [utcDay] = low } of one item in the loaded server prices (entry e), or nil
local function serverLows(e, id)
  local s = e and e.items and e.items[id]
  local d0 = e and tonumber(e.day0)
  if type(s) ~= "string" or not d0 then return nil end
  local base, out = math.floor(d0 / 86400), {}
  for o, l in s:gmatch("(%d+):(%d+):%d+") do out[base + tonumber(o)] = tonumber(l) end
  return out
end

local function dropOldHistory()
  if type(db.history) ~= "table" then db.history = {} end
  if type(db.histDone) ~= "table" then db.histDone = {} end
  local cut = time() - HIST_KEEP
  for k, b in pairs(db.history) do
    if type(b) ~= "table" or (tonumber(b.created) or 0) < cut then db.history[k] = nil end
  end
end

local histJob = false

local function prepareHistory(quiet)
  if passive or not db or not db.enabled or histJob then return end
  local mk = marketInfo()
  if not marketOK(mk) then return end
  local key = marketKey(mk)
  if db.histDone[key] then return end
  local store, midasLoaded = midasStore()
  if not midasLoaded then return end          -- no Midas data yet: next login
  if type(store) ~= "table" then
    db.histDone[key] = time()                 -- nothing kept for this market
    return
  end
  local keys, n = {}, 0
  for k in pairs(store) do
    local id = tonumber(k)
    if id and id >= 1 and id <= ITEM_ID_MAX and id % 1 == 0 and tostring(id) == tostring(k) then
      n = n + 1; keys[n] = k
    end
  end
  table.sort(keys, function(a, b) return tonumber(a) < tonumber(b) end)
  local today = scanDay()
  local first = today - HIST_DAYS
  local base = utcDay(first)
  local srv = priceEntry()
  local items, count, rows, i = {}, 0, 0, 0
  histJob = true

  local function finish()
    histJob = false
    db.histDone[key] = time()
    if count == 0 then
      if not quiet then say("price history: nothing to hand over for this market.") end
      return
    end
    db.history[key] = {
      v = HIST_V, created = time(), addon = midasVersion(),
      market = { client = mk.client, region = mk.region, realm = mk.realm,
                 faction = mk.faction, ruleset = mk.ruleset },
      day0 = base * 86400, days = HIST_DAYS, rows = rows, count = count, items = items,
    }
    say(string.format("price history of the last %d days prepared (%d items). The companion app sends it once, after the next /reload or logout.",
      HIST_DAYS, count))
  end

  local function step()
    if not db.enabled then histJob = false; return end   -- switched off meanwhile
    local stop = math.min(i + HIST_CHUNK, n)
    while i < stop do
      i = i + 1
      local k = keys[i]
      local it = store[k]
      if type(it) == "table" and count < HIST_ITEMS_MAX then
        local id = tonumber(k)
        local sl = srv and serverLows(srv, id)
        local segs, nd = {}, 0
        for d, rec in pairs(it) do
          if type(d) == "number" and d >= first and d < today and type(rec) == "table"
             and type(rec.ts) == "number" and not rec.quick then
            local low, qty = tonumber(rec.low), tonumber(rec.qty) or 0
            if low and low >= 1 and low <= LOW_MAX and low % 1 == 0 then
              if qty < 0 or qty > QTY_MAX or qty % 1 ~= 0 then qty = 0 end
              local u = utcDay(d)
              if not (sl and sl[u] == low) then
                nd = nd + 1
                segs[nd] = { u - base, low, qty }
              end
            end
          end
        end
        if nd > 0 and rows + nd <= HIST_ROWS_MAX then
          table.sort(segs, function(a, b) return a[1] < b[1] end)
          local parts = {}
          for j = 1, nd do
            local s = segs[j]
            parts[j] = string.format("%d:%d:%d", s[1], s[2], s[3])
          end
          items[id] = table.concat(parts, ";")
          count = count + 1
          rows = rows + nd
        end
      end
    end
    if i < n then
      C_Timer.After(0, step)
    else
      finish()
    end
  end

  C_Timer.After(0, step)
end

local function historyText()
  local mk = marketInfo()
  if not marketOK(mk) then return "Price history: no market known yet." end
  local key = marketKey(mk)
  local b = db.history and db.history[key]
  if type(b) == "table" then
    return string.format("Price history: %d items prepared %s, waiting for the companion app.",
      tonumber(b.count) or 0, date("%d.%m. %H:%M", tonumber(b.created) or 0))
  elseif db.histDone and db.histDone[key] then
    return "Price history: prepared once for this market (" .. date("%d.%m.", tonumber(db.histDone[key]) or 0)
      .. "), not prepared again."
  end
  return "Price history: not prepared yet (needs sharing ON)."
end

local function onScan(_, payload)
  if passive or not db then return end
  -- the market Midas filed the scan under (M.MarketInfo of this scan)
  if type(payload) == "table" then rememberMarket(payload.market) end
  -- SCAN_COMPLETE fires right after Midas stored the scan; copy it on the
  -- next frame so Midas finishes its own scan handling first. A price scan
  -- (depth = false) stores no offer book: its rows go into pqueue instead.
  local fn
  if type(payload) == "table" and payload.depth == false then
    local ts = tonumber(payload.ts)
    fn = function() capturePrices(ts) end
  else
    fn = function() capture(true) end
  end
  if C_Timer and C_Timer.After then
    C_Timer.After(0, fn)
  else
    fn()
  end
end

-- ===== status for chat and the Settings tab ===================================
local cntEntry, cntItems                -- item count of the last shown entry

-- the companion app that writes AddOns\Midas\Prices.lua: version 1.3.0 or newer
-- (older apps only serve the Midas_Uplink folder - it must stay until the update)
local APP_MIN = { 1, 3, 0 }
local function appReady()
  local P = MidasUplinkPrices
  local v = type(P) == "table" and type(P.app) == "string" and P.app
  if not v then return false end
  local i = 0
  for part in v:gmatch("%d+") do
    i = i + 1
    local n, want = tonumber(part), APP_MIN[i] or 0
    if n ~= want then return n > want end
    if i >= #APP_MIN then return true end
  end
  if i == 0 then return false end
  for j = i + 1, #APP_MIN do                -- "1.3" = 1.3.0
    if APP_MIN[j] > 0 then return false end
  end
  return true
end
M.DatalinkAppReady = appReady

-- everything the Settings tab shows; nil fields = unknown / none
function M.DatalinkInfo()
  local P = MidasUplinkPrices
  local info = { legacy = passive or legacyLoaded(), url = M.DATALINK_URL }
  if db then
    info.share = db.enabled == true
    info.prices = db.prices ~= false
    info.queue = type(db.queue) == "table" and #db.queue or 0
    info.pqueue = type(db.pqueue) == "table" and #db.pqueue or 0
    -- the newest snapshot kept for the app (either list)
    for _, q in ipairs({ db.queue, db.pqueue }) do
      local s = type(q) == "table" and q[#q]
      local ts = type(s) == "table" and tonumber(s.ts)
      if ts and (not info.newest or ts > info.newest) then info.newest = ts end
    end
  else
    info.share, info.prices, info.queue, info.pqueue = false, true, 0, 0
  end
  if type(P) == "table" then
    info.app = type(P.app) == "string" and P.app ~= "" and P.app or nil
    -- only a real time counts (early app runs write checked = 0: no server check yet)
    local ck = tonumber(P.checked)
    info.checked = (ck and ck > 0) and ck or nil
    info.found = true                     -- the app wrote the file (an older one: no app field)
  end
  info.appReady = appReady()
  local ok, e = pcall(priceEntry)
  if ok and e then
    if e ~= cntEntry then
      local n = 0
      for _ in pairs(e.items) do n = n + 1 end
      cntEntry, cntItems = e, n
    end
    info.market, info.priceTs, info.priceItems = tostring(e.market), tonumber(e.ts), cntItems
  end
  return info
end

local function pricesText()
  if db.prices == false then return "Server prices: OFF (/midas prices on)." end
  local e = priceEntry()
  if not e then return "Server prices: none." end
  local n = 0
  for _ in pairs(e.items) do n = n + 1 end
  return string.format("Server prices: %s from %s, %d items.",
    tostring(e.market), date("%d.%m. %H:%M", tonumber(e.ts) or 0), n)
end

local function legacyNote()
  if appReady() then
    say("the old addon Midas_Uplink is still installed - it is part of Midas now. Quit the game and delete the Midas_Uplink folder in Interface\\AddOns; your settings carry over. Until then the old addon does the sharing.")
  else
    say("the old addon Midas_Uplink is still installed - it is part of Midas now. Update the Midas Companion app (midasmarket.app/download), then quit the game and delete the Midas_Uplink folder in Interface\\AddOns; your settings carry over. Until then the old addon does the sharing.")
  end
end

local function status()
  local q = db.queue
  say(db.enabled and "sharing |cff66dd88ON|r - your scans go to midasmarket.app." or "sharing |cffff6666OFF|r - nothing is shared (/midas datalink on).")
  local info = M.DatalinkInfo()
  if info.app then
    local ck = info.checked
    say("companion app " .. info.app .. ((type(ck) == "number" and ck > 0) and (", last check " .. date("%d.%m. %H:%M", ck))
      or ", no server check yet") .. ".")
  elseif not info.found then
    say("companion app not found - get it at " .. M.DATALINK_URL)
  end
  local function line(s, kind)
    local mk = s.market or {}
    say(string.format("#%d  %s  %s/%s/%s/%s  %d items  (%s)",
      s.seq or 0, date("%d.%m. %H:%M", s.ts or 0), mk.client or "?", mk.region or "?",
      mk.ruleset or "?", mk.faction or "?", s.count or 0, kind))
  end
  local pq = db.pqueue
  if #q == 0 and #pq == 0 then
    say("queue empty.")
  else
    say(string.format("queue: %d full %s, %d price %s.", #q, #q == 1 and "scan" or "scans",
      #pq, #pq == 1 and "scan" or "scans"))
    for i = 1, #q do line(q[i], "full scan") end
    for i = 1, #pq do line(pq[i], "price scan") end
  end
  say(pricesText())
  say(historyText())
  if passive then legacyNote() end
end

-- ===== switches (slash commands and the Settings tab) =========================
function M.DatalinkSetShare(on)
  if not db then return end
  if on then
    db.enabled = true
    say("sharing ON. Each full scan (offer book) and each complete price scan is handed to the companion app - no character data.")
    capture(true)
    capturePrices(nil)
    prepareHistory(false)
  else
    db.enabled = false
    db.queue = {}
    db.pqueue = {}
    db.history = {}
    refreshBlock()
    say("sharing OFF. Queue and prepared price history cleared, nothing is shared.")
  end
  if passive then legacyNote() end
end

function M.DatalinkSetPrices(on)
  if not db then return end
  if on then
    db.prices = true
    say("server prices ON. Midas loads them at the next login or /reload.")
  else
    db.prices = false
    say("server prices OFF. Midas ignores them from the next login or /reload; prices it already loaded stay.")
  end
end

-- /midas datalink|prices|history ... (Core.lua) and /uplink ... (alias of 1.2.28's
-- Midas_Uplink). msg is lowercase and trimmed.
function M.DatalinkSlash(msg)
  if not db then return end
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  local verb, arg = msg:match("^(%S+)%s*(.-)$")
  if verb == "datalink" or verb == "on" or verb == "off" then
    local v = (verb == "datalink") and arg or verb
    if v == "on" then M.DatalinkSetShare(true)
    elseif v == "off" then M.DatalinkSetShare(false)
    elseif v == "now" then
      if passive then legacyNote() else capture(false) end
    elseif v == "clear" then
      db.queue, db.pqueue = {}, {}
      refreshBlock()
      say("queue cleared.")
    else status() end
  elseif verb == "prices" then
    if arg == "on" then M.DatalinkSetPrices(true)
    elseif arg == "off" then M.DatalinkSetPrices(false)
    else say(pricesText()) end
  elseif verb == "history" then
    say(historyText())
  elseif verb == "now" then
    if passive then legacyNote() else capture(false) end
  elseif verb == "clear" then
    db.queue, db.pqueue = {}, {}
    refreshBlock()
    say("queue cleared.")
  elseif msg == "" or verb == "status" then
    status()
  else
    say("/midas datalink on | off | status | now | clear   \194\183   /midas prices on | off | status   \194\183   /midas history")
  end
end

-- the old addon's command, kept as an alias (the old addon takes it back
-- while it is still loaded)
SLASH_MIDASUPLINK1 = "/uplink"
SlashCmdList.MIDASUPLINK = function(msg) M.DatalinkSlash(msg) end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(_, event, name)
  if event == "ADDON_LOADED" and name == ADDON then
    initDB()
  elseif event == "PLAYER_LOGIN" then
    -- the old addon's SavedVariables load after Midas' and replace the global:
    -- bind to the table that is current now
    initDB()
    passive = legacyLoaded()
    local cfg = type(MidasDB) == "table" and type(MidasDB.config) == "table" and MidasDB.config
    if passive then
      C_Timer.After(12, legacyNote)
      if cfg then cfg.datalinkNote = 1 end   -- the old addon's users know the feature
      return
    end
    -- the market memory is independent of the upload opt-in
    local ok, err = pcall(function() rememberMarket(marketInfo()) end)
    if not ok then geterrorhandler()(err) end
    dropOldHistory()
    if db.enabled then
      C_Timer.After(HIST_DELAY, function()
        local okH, errH = pcall(prepareHistory, true)
        if not okH then histJob = false; geterrorhandler()(errH) end
      end)
    end
    if MidasAPI and MidasAPI.RegisterCallback then
      MidasAPI.RegisterCallback("SCAN_COMPLETE", onScan)
    end
    -- one quiet line after the update to 1.3.0 (and on a new install)
    if cfg and cfg.datalinkNote == nil then
      cfg.datalinkNote = 1
      C_Timer.After(12, function()
        say("new in Midas 1.3.0 - share your scans with midasmarket.app and load its server prices. Settings tab > DATALINK (sharing is off until you switch it on).")
      end)
    end
  end
end)
