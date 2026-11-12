-- Midas – Data: own persistent DB (MidasDB) + commit of self-scanned AH data
local ADDON, M = ...

-- Realm store inside MidasDB (create if needed)
local function Store(realm)
  realm = realm or M.RealmKey()
  M.db.realms[realm] = M.db.realms[realm] or {}
  return M.db.realms[realm]
end
M.Store = Store

-- Unit buyouts are floor(buyout / count): ammo stacks priced under 1c per unit
-- come out as 0, which every ratio downstream divides by.
local function unitPrice(c)
  if c < 1 then return 1 end
  return c
end

-- ===== Neutral auction houses =================================================
-- Scans and prices seen at a neutral AH (Core.lua M.AtNeutralAH) land in
-- M.db.realms[M.NeutralKey()] - same daily rows (low = MIN, qty = MAX, cur/ts =
-- newest), but no list, chart, alert or sync reads that key. It also keeps
-- neutral day lows out of the Auctionator/aux import (M.NeutralBlocks): both
-- addons file the neutral AH under the faction's key.
local NEUTRAL_KEEP = 60   -- days

local function noteNeutral(id, unit, qty, day, now)
  local store = Store(M.NeutralKey())
  local key = tostring(id)
  local it = store[key]; if not it then it = {}; store[key] = it end
  local rec = it[day]
  if not rec then
    it[day] = { low = unit, qty = qty or 0, cur = unit, ts = now }
  else
    if unit < rec.low then rec.low = unit end
    if (qty or 0) > (rec.qty or 0) then rec.qty = qty end
    rec.cur, rec.ts = unit, now
  end
end

-- An imported day low that is not below what the neutral AH showed on that day
-- may well be the neutral price itself: it stays out.
function M.NeutralBlocks(key, day, low)
  local ns = M.db and M.db.realms and M.db.realms[M.NeutralKey()]
  if not ns or type(low) ~= "number" then return false end
  local it = ns[tostring(key)]
  if not it then
    local base = tostring(key):match("^%a+:(%d+)")
    it = base and ns[base]
  end
  local rec = it and it[day]
  return (rec and rec.low and low >= rec.low) and true or false
end

function M.PruneNeutral()
  local ns = M.db and M.db.realms and M.db.realms[M.NeutralKey()]
  if not ns then return end
  local cut = M.GetScanDay() - NEUTRAL_KEEP
  for key, it in pairs(ns) do
    for day in pairs(it) do
      if type(day) ~= "number" or day < cut then it[day] = nil end
    end
    if next(it) == nil then ns[key] = nil end
  end
end

-- intraday tail (1W chart): last scans per item, own top-level store so the
-- daily rows (and the community sync built on them) stay byte-identical.
-- A repeat of the same low+qty only slides the newest point's ts forward.
local function intraStore()
  M.db.intra = M.db.intra or {}
  local rk = M.RealmKey()
  local istore = M.db.intra[rk]; if not istore then istore = {}; M.db.intra[rk] = istore end
  return istore
end

local function pushIntra(istore, key, low, qty, now)
  local st = istore[key]
  if not st then st = {}; istore[key] = st end
  local lp = st[#st]
  if lp and lp.low == low and lp.qty == qty then
    lp.ts = now
  else
    st[#st + 1] = { ts = now, low = low, qty = qty }
  end
  local icut = now - 8 * 86400
  while st[1] and (st[1].ts < icut or #st > 16) do table.remove(st, 1) end
end

-- Commit a scan snapshot {itemID = {low=copper, qty=n}} into MidasDB.
-- One bucket per scan day; idempotent merge (low = MIN, qty = MAX). Each record
-- also carries cur (latest scan price, last-write-wins) and ts (scan timestamp,
-- the tie-breaker that keeps cur consistent across community sync). Rows the
-- scan actually changed are handed to Comm.lua for broadcasting.
-- A scan at a neutral AH is stored apart and touches nothing else.
function M.CommitScan(acc)
  if not M.db or type(acc) ~= "table" then return end
  if M.AtNeutralAH() then
    local day, now, items = M.GetScanDay(), time(), 0
    for itemID, a in pairs(acc) do
      if a.low then items = items + 1; noteNeutral(itemID, unitPrice(a.low), a.qty, day, now) end
    end
    M.Print(string.format("Neutral auction house scan stored apart: %d items, day %s - your %s prices stay as they were.",
      items, M.DayLabel(day), UnitFactionGroup("player") or "faction"))
    return
  end
  local day = M.GetScanDay()
  local now = time()
  local store = Store()
  local rk = M.RealmKey()
  local istore = intraStore()
  M.db.names = M.db.names or {}
  local names = M.db.names
  local items, changed = 0, {}
  for itemID, a in pairs(acc) do
    -- remember scanned names for the Charts search - but never for weapons and
    -- armor (class 2/4): their auction names carry a RANDOM suffix ("of the
    -- Whale"), and the gr:-keyed chart titles would append their own on top
    if a.name and a.name ~= "" and not names[itemID] then
      local classID = GetItemInfoInstant and select(6, GetItemInfoInstant(itemID))
      if classID ~= 2 and classID ~= 4 then names[itemID] = a.name end
    end
    if a.low then
      items = items + 1
      local key = tostring(itemID)
      local low = unitPrice(a.low)
      local it = store[key]; if not it then it = {}; store[key] = it end
      pushIntra(istore, key, low, a.qty or 0, now)
      local rec = it[day]
      if not rec then
        it[day] = { low = low, qty = a.qty or 0, cur = low, ts = now }
        changed[#changed + 1] = { id = itemID, low = low, qty = a.qty or 0, cur = low }
      else
        local ch = false
        if low < rec.low then rec.low = low; ch = true end
        if (a.qty or 0) > (rec.qty or 0) then rec.qty = a.qty; ch = true end
        if rec.cur ~= low then rec.cur = low; ch = true end -- latest scan wins
        -- a quick-scan row of today is a full-scan row now (and may be shared)
        if rec.quick then rec.quick = nil; ch = true end
        rec.ts = now
        if ch then changed[#changed + 1] = { id = itemID, low = rec.low, qty = rec.qty, cur = rec.cur } end
      end
    end
  end
  -- onboarding milestones count DAYS with at least one own scan - ten scans on
  -- one day are one step, not ten (UI.lua OB_STAGES). lastIngest still holds
  -- the PREVIOUS own scan right here, so it hands us the new-day test for
  -- free. UI.lua loads after Data.lua, hence the runtime guard; the short
  -- delay lets the scan-stored chat line and the dock re-fill land first.
  if items > 0 then
    local prev = M.db.config.lastIngest
    if not prev or math.floor((prev - M.C.SCAN_DAY_0) / 86400) ~= day then
      M.db.config.scanDays = (M.db.config.scanDays or 0) + 1
      if M.OnboardScan then C_Timer.After(0.8, M.OnboardScan) end
    end
  end
  M.db.config.lastIngest = now
  -- a full scan is newer than every price the AH showed before it
  if M.db.live then M.db.live[rk] = nil end
  M.CommitDepth(acc, now)
  M.DirtyAnalysis()
  M.Print(string.format("Full scan stored: %d items, day %s.", items, M.DayLabel(day)))
  if M.CheckAlerts then M.CheckAlerts() end
  -- the sell helper at the AH ranks bags by these prices: re-fill it in place
  if M.ShowSellDock then M.ShowSellDock() end
  if M.OnScanCommitted then M.OnScanCommitted(day, changed, now) end
  if M.FireAPIEvent then M.FireAPIEvent("SCAN_COMPLETE", { day = day, items = items, ts = now, market = M.MarketInfo() }) end
  if M.frame and M.frame:IsShown() and M.RefreshUI then M.RefreshUI() end
end

-- Commit a quick scan (ScannerModern: only YOUR items, while the full snapshot
-- is slow or on cooldown) {itemID = {low, qty}}. The items it found get today's
-- daily row just like a full scan's - charts, Fair price, alerts and the 1W
-- intraday line all see them. A row only a quick scan wrote carries quick =
-- true: it never moves the newest scan day (M.LastScanDay), so every item the
-- quick scan did not reach counts as "not scanned" instead of "not listed", and
-- the community sync never offers it (a peer's newest day would jump the same
-- way). The next full scan - own or synced - of that day drops the mark.
-- Returns the number of items stored.
function M.CommitQuick(acc)
  if not M.db or type(acc) ~= "table" then return 0 end
  local day, now, items = M.GetScanDay(), time(), 0
  if M.AtNeutralAH() then
    for itemID, a in pairs(acc) do
      if a.low then items = items + 1; noteNeutral(itemID, unitPrice(a.low), a.qty, day, now) end
    end
    return items
  end
  local store = Store()
  local istore = intraStore()
  for itemID, a in pairs(acc) do
    if type(a) == "table" and type(a.low) == "number" and a.low > 0 then
      items = items + 1
      local key = tostring(itemID)
      local low, qty = unitPrice(math.floor(a.low)), a.qty or 0
      local it = store[key]; if not it then it = {}; store[key] = it end
      pushIntra(istore, key, low, qty, now)
      local rec = it[day]
      if not rec then
        it[day] = { low = low, qty = qty, cur = low, ts = now, quick = true }
      else
        -- a full-scan row of today stays one: same merge rules, no mark
        if low < rec.low then rec.low = low end
        if qty > (rec.qty or 0) then rec.qty = qty end
        rec.cur, rec.ts = low, now
      end
    end
  end
  if items == 0 then return 0 end
  M.DirtyAnalysis()
  if M.CheckAlerts then M.CheckAlerts() end
  if M.ShowSellDock then M.ShowSellDock() end
  if M.frame and M.frame:IsShown() and M.RefreshUI then M.RefreshUI() end
  return items
end

-- ===== Live prices ==========================================================
-- What the auction house itself showed after the newest full scan: the default
-- AH's search results and Auctionator's searches and scans (Live.lua). One
-- entry per item, the newest observation wins. Metrics (Logic.lua) takes it as
-- the current price whenever it is newer than the item's newest daily row; the
-- daily archive and the community sync stay scan-only, and the next own full
-- scan replaces every entry (CommitScan clears the realm's table).
-- MidasDB.live[realmKey][key] = { p = unit copper, q = units listed or nil, ts }
local LIVE_KEEP = 3 * 86400   -- older entries are dropped at login
local LIVE_SETTLE = 4         -- seconds of quiet before the whole-archive refresh

function M.LivePrice(key)
  local ls = M.db and M.db.live and M.db.live[M.RealmKey()]
  return ls and ls[tostring(key)] or nil
end

-- The live entry of an item when it is newer than the daily row `rec` of `day`
-- (rows without a timestamp - imports - count from the start of their day).
function M.FreshLive(key, rec, day)
  local e = M.LivePrice(key)
  if not (e and e.ts) then return nil end
  local rts = (rec and rec.ts) or (day and (M.C.SCAN_DAY_0 + day * 86400)) or 0
  if e.ts > rts then return e end
  return nil
end

-- scan day of a timestamp
function M.DayOf(ts)
  return math.floor((ts - M.C.SCAN_DAY_0) / 86400)
end

-- A live price is "listed now" unless a newer scan day went by without the item.
function M.LiveListed(e)
  return (e and e.ts and M.DayOf(e.ts) >= M.LastScanDay()) and true or false
end

local liveTimer = false
local function liveSettled()
  liveTimer = false
  M.DirtyAnalysis()
  if M.CheckAlerts then M.CheckAlerts() end
  if M.frame and M.frame:IsShown() and M.RefreshUI then M.RefreshUI() end
end

-- One observation: cheapest unit buyout the AH shows right now (+ units listed
-- when the source knows them). The item's own numbers update at once; lists,
-- alerts and the open window follow after a few quiet seconds.
function M.ObserveLive(itemID, unit, qty)
  if not M.db or type(unit) ~= "number" or unit <= 0 or unit > 5e9 then return end
  local id = tonumber(itemID)
  if not id then return end
  unit = unitPrice(math.floor(unit))
  if type(qty) ~= "number" or qty < 0 then qty = nil end
  -- the neutral AH's own prices never become the current price
  if M.AtNeutralAH() then noteNeutral(id, unit, qty, M.GetScanDay(), time()); return end
  local rk = M.RealmKey()
  M.db.live = M.db.live or {}
  local ls = M.db.live[rk]; if not ls then ls = {}; M.db.live[rk] = ls end
  local key = tostring(id)
  local old = ls[key]
  ls[key] = { p = unit, q = qty, ts = time() }
  if M._mCache and M._mCache.items then M._mCache.items[key] = nil end
  if old and old.p == unit and old.q == qty then return end
  if not liveTimer then
    liveTimer = true
    C_Timer.After(LIVE_SETTLE, liveSettled)
  end
end

function M.PruneLive()
  if not (M.db and M.db.live) then return end
  local cut = time() - LIVE_KEEP
  for rk, ls in pairs(M.db.live) do
    for key, e in pairs(ls) do
      if type(e) ~= "table" or not e.ts or e.ts < cut then ls[key] = nil end
    end
    if next(ls) == nil then M.db.live[rk] = nil end
  end
end

-- Supply ladder of the NEWEST scan only (no history, keeps the SV small):
-- MidasDB.depth[realmKey] = { ts, market, items = { [itemID] = { N, p1, q1, n1, p2, ... } } }
-- N = buyout auctions over ALL prices; p = unit buyout (copper, ascending),
-- q = units, n = auctions at that price (cheapest DEPTH_LEVELS prices only).
-- A new scan replaces the whole realm entry, so sold-out items drop out.
local DEPTH_LEVELS = 20

function M.CommitDepth(acc, now)
  M.db.depth = M.db.depth or {}
  local items, qty = {}, {}
  for itemID, a in pairs(acc) do
    if a.lv then
      local prices, total = {}, 0
      for p, st in pairs(a.lv) do prices[#prices + 1] = p; total = total + st[2] end
      table.sort(prices)
      local flat = { total }
      for i = 1, math.min(#prices, DEPTH_LEVELS) do
        local st = a.lv[prices[i]]
        local p, n = unitPrice(prices[i]), #flat
        if n > 1 and flat[n - 2] == p then          -- 0c folded into the 1c level
          flat[n - 1] = flat[n - 1] + st[1]; flat[n] = flat[n] + st[2]
        else
          flat[n + 1] = p; flat[n + 2] = st[1]; flat[n + 3] = st[2]
        end
      end
      items[itemID] = flat
      qty[itemID] = a.qty          -- ALL listed units, not only the stored levels
    end
  end
  M.db.depth[M.RealmKey()] = { ts = now, market = M.MarketInfo(), items = items, qty = qty }
end

-- Depth of one item on the current realm: levels = { {price, qty, auctions, cum}, ... },
-- plus ts of the scan it comes from and the item's total auction count.
-- nil when the newest scan did not list it.
function M.GetDepth(itemID)
  local d = M.db and M.db.depth and M.db.depth[M.RealmKey()]
  local flat = d and d.items and d.items[tonumber(itemID)]
  if not flat then return nil end
  local levels, cum = {}, 0
  for i = 2, #flat, 3 do
    cum = cum + flat[i + 1]
    levels[#levels + 1] = { price = flat[i], qty = flat[i + 1], auctions = flat[i + 2], cum = cum }
  end
  -- listed = every unit on the AH (scans before 1.2.3 final: the stored levels only)
  local listed = (d.qty and d.qty[tonumber(itemID)]) or cum
  return { ts = d.ts, levels = levels, units = cum, auctions = flat[1], listed = listed }
end

-- A buyout the player just made thins the stored ladder immediately - the
-- snapshot itself is only replaced by the next full scan. Returns true when
-- the bought price level was found and reduced (then the open books refresh).
function M.DepthBuyout(itemID, unit, units)
  if M.AtNeutralAH() then return false end   -- the stored ladder is your own market's
  local d = M.db and M.db.depth and M.db.depth[M.RealmKey()]
  local id = tonumber(itemID)
  local flat = d and d.items and id and d.items[id]
  if not flat or not unit then return false end
  unit = unitPrice(unit)
  for i = 2, #flat, 3 do
    if flat[i] == unit then
      flat[i + 1] = flat[i + 1] - (units or 1)
      flat[i + 2] = flat[i + 2] - 1
      flat[1] = math.max(0, (flat[1] or 1) - 1)
      if d.qty and d.qty[id] then d.qty[id] = math.max(0, d.qty[id] - (units or 1)) end
      if flat[i + 1] <= 0 or flat[i + 2] <= 0 then
        table.remove(flat, i); table.remove(flat, i); table.remove(flat, i)
      end
      return true
    end
  end
  return false
end

-- Merge rows received from other Midas users (Comm.lua). Same lattice rules as
-- CommitScan (low = MIN, qty = MAX) plus last-write-wins for cur via ts, so all
-- clients converge to the same DB regardless of message order or duplicates.
-- fromGuild relaxes the low-ball poison guard. Returns how many records improved.
-- Sync rows trickle in message by message. A changed item's own numbers update
-- at once (its metrics entry is dropped); the whole-archive refresh - ranked
-- lists, craft costs, every other cached item - follows once per burst.
local syncTimer = false
local function syncSettled()
  syncTimer = false
  M.DirtyAnalysis()
end

function M.MergeSharedRows(day, rows, fromGuild)
  if not M.db or type(rows) ~= "table" then return 0 end
  local store = Store()
  local frac = M.C.SHARE_MIN_FRAC or 0.05
  local improved = 0
  local memo = M._mCache and M._mCache.items
  for i = 1, #rows do
    local r = rows[i]
    local key = tostring(r.id)
    local low, cur = unitPrice(r.low), r.cur and unitPrice(r.cur)
    local it = store[key]
    local ref
    if it then
      ref = it[day]
      if not ref then local nk = next(it); ref = nk and it[nk] end
    end
    -- poison guard: an absurd undercut from outside the guild is dropped
    if not ((not fromGuild) and ref and ref.low and low < ref.low * frac) then
      if not it then it = {}; store[key] = it end
      local rec = it[day]
      if not rec then
        it[day] = { low = low, qty = r.qty or 0, cur = cur, ts = r.ts }
        improved = improved + 1
        if memo then memo[key] = nil end
      else
        local ch = false
        if low < rec.low then rec.low = low; ch = true end
        if (r.qty or 0) > (rec.qty or 0) then rec.qty = r.qty; ch = true end
        if cur and r.ts and r.ts > (rec.ts or 0) then
          if rec.cur ~= cur then ch = true end
          rec.cur, rec.ts = cur, r.ts
        end
        -- a peer's full scan covered this item on that day: no quick row any more
        if rec.quick then rec.quick = nil; ch = true end
        if ch then
          improved = improved + 1
          if memo then memo[key] = nil end
        end
      end
    end
  end
  if M.perf then M.perf.sync = M.perf.sync + 1 end
  if improved > 0 then
    -- a newer scan day is known at once, without the walk over the archive
    local ldc = M._lastDayCache
    local rk = M.RealmKey()
    if ldc and ldc[rk] and day > ldc[rk] then ldc[rk] = day end
    if not syncTimer then
      syncTimer = true
      C_Timer.After(LIVE_SETTLE, syncSettled)
    end
    -- price alerts also watch synced prices (debounced; sync rows trickle in)
    if M.CheckAlerts and not M._alertCheck then
      M._alertCheck = true
      C_Timer.After(2, function()
        M._alertCheck = nil
        if M.CheckAlerts then M.CheckAlerts() end
      end)
    end
    if M.frame and M.frame:IsShown() and M.RefreshUI and not M._commRefresh then
      M._commRefresh = true
      C_Timer.After(1.5, function()
        M._commRefresh = nil
        if M.frame and M.frame:IsShown() and M.RefreshUI then M.RefreshUI() end
      end)
    end
  end
  return improved
end

-- ===== Price alerts =========================================================
-- MidasDB.alerts[realm][itemKey] = { below = copper, above = copper }, set in
-- the Charts tab. Checked after every own scan and (debounced) sync merge
-- against the newest scan day's price (cur, else low). Each side fires ONCE and
-- re-arms when the price leaves the limit again.
function M.AlertFire(name, cur, limit, isBelow)
  local msg = string.format("Midas alert: %s %s %s  (limit %s)", name,
    isBelow and "down at" or "up at", M.MoneyPlain(cur), M.MoneyPlain(limit))
  M.Print(msg)
  if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] then
    pcall(RaidNotice_AddMessage, RaidWarningFrame, msg, ChatTypeInfo["RAID_WARNING"])
  end
  if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then pcall(PlaySound, SOUNDKIT.RAID_WARNING) end
end

function M.CheckAlerts()
  local realm = M.RealmKey()
  local al = M.db and M.db.alerts and M.db.alerts[realm]
  if not al or not next(al) then return end
  local store = M.db.realms and M.db.realms[realm]
  if not store then return end
  -- an item missing from the newest scan day has no live price: its last-seen
  -- one must neither fire nor re-arm an alert
  local newest = M.LastScanDay(realm)
  for key, a in pairs(al) do
    local it = store[key]
    local lastDay
    if it then
      for d in pairs(it) do if not lastDay or d > lastDay then lastDay = d end end
    end
    local rec = lastDay and lastDay >= newest and it[lastDay]
    local cur = rec and (rec.cur or rec.low)
    -- a newer price the AH showed since (Live.lua) counts while it is listed
    local lv = M.FreshLive(key, it and lastDay and it[lastDay], lastDay)
    if lv and M.LiveListed(lv) then cur = lv.p end
    if cur then
      local name = (M.ItemName and M.ItemName(key)) or tostring(key)
      -- bTs / aTs: when it fired (the Start page pins only fresh hits)
      if a.below and cur <= a.below then
        if not a.bFired then a.bFired = true; a.bTs = time(); M.AlertFire(name, cur, a.below, true) end
      else a.bFired, a.bTs = nil, nil end
      if a.above and cur >= a.above then
        if not a.aFired then a.aFired = true; a.aTs = time(); M.AlertFire(name, cur, a.above, false) end
      else a.aFired, a.aTs = nil, nil end
    end
  end
end

-- One-shot merge of a shipped price-data blob (MidasImport.lua) into our archive.
-- Lets us fold in shared scans (e.g. a guildmate's Auctionator export) without
-- touching the SavedVariables by hand. Idempotent (low = MIN, qty = MAX) and
-- guarded by a stamp so it runs exactly once per distinct import.
function M.MergeImport()
  if type(MidasImport) ~= "table" or type(MidasImport.items) ~= "table" then return end
  if not M.db then return end
  M.db.config = M.db.config or {}
  if M.db.config.importStamp == MidasImport.stamp then MidasImport = nil; return end
  local store = Store(MidasImport.realm or M.RealmKey())
  local newItems, rows = 0, 0
  for key, days in pairs(MidasImport.items) do
    local it = store[key]
    if not it then it = {}; store[key] = it; newItems = newItems + 1 end
    for day, lq in pairs(days) do
      local low, qty = lq[1], lq[2] or 0
      if type(low) == "number" then
        low = unitPrice(low)
        local cur = it[day]
        if not cur then
          it[day] = { low = low, qty = qty }; rows = rows + 1
        else
          if low < cur.low then cur.low = low end
          if qty > (cur.qty or 0) then cur.qty = qty end
        end
      end
    end
  end
  M.db.config.importStamp = MidasImport.stamp
  M.DirtyAnalysis()
  MidasImport = nil   -- free the ~1 MB blob from memory after merging
  M.Print(string.format("Imported shared prices: %d new items, %d day-rows merged.", newItems, rows))
  if M.frame and M.frame:IsShown() and M.RefreshUI then M.RefreshUI() end
end

-- One-shot cleanup: drop every daily value before a cutoff day. Used to purge an
-- old, sparse external import (a guildmate's Auctionator history) that polluted the
-- early archive. Stamp-guarded so it runs exactly once per distinct cutoff.
function M.TrimBefore(cutoffDay, stamp)
  if not M.db or type(cutoffDay) ~= "number" then return end
  M.db.config = M.db.config or {}
  if stamp and M.db.config.trimStamp == stamp then return end
  local rows, items = 0, 0
  for _, store in pairs(M.db.realms) do
    for key, it in pairs(store) do
      for day in pairs(it) do
        if type(day) == "number" and day < cutoffDay then it[day] = nil; rows = rows + 1 end
      end
      if next(it) == nil then store[key] = nil; items = items + 1 end
    end
  end
  if stamp then M.db.config.trimStamp = stamp end
  M.DirtyAnalysis()
  M.Print(string.format("Trimmed %d old daily values (%d items dropped) before %s.", rows, items, M.DayLabel(cutoffDay)))
  if M.frame and M.frame:IsShown() and M.RefreshUI then M.RefreshUI() end
end

-- One-shot cleanup: stored 0c unit prices (daily rows and intraday tails) become 1c,
-- the same floor unitPrice() applies to new data. Stamp-guarded.
function M.RepairZeroPrices()
  if not M.db then return 0 end
  M.db.config = M.db.config or {}
  if M.db.config.zeroPriceFix == "20261018" then return 0 end
  M.db.config.zeroPriceFix = "20261018"
  local n = 0
  for _, store in pairs(M.db.realms or {}) do
    for _, it in pairs(store) do
      for _, v in pairs(it) do
        if type(v) == "table" then
          if v.low and v.low < 1 then v.low = 1; n = n + 1 end
          if v.cur and v.cur < 1 then v.cur = 1; n = n + 1 end
        end
      end
    end
  end
  for _, istore in pairs(M.db.intra or {}) do
    for _, st in pairs(istore) do
      for i = 1, #st do
        if st[i].low and st[i].low < 1 then st[i].low = 1; n = n + 1 end
      end
    end
  end
  if n > 0 then M.DirtyAnalysis() end
  return n
end

-- Remove days older than the horizon
function M.Prune()
  local cutoff = M.GetScanDay() - M.C.PRUNE_DAYS
  local removed = 0
  for _, store in pairs(M.db.realms) do
    for key, it in pairs(store) do
      for day in pairs(it) do
        if day <= cutoff then it[day] = nil; removed = removed + 1 end
      end
      if next(it) == nil then store[key] = nil end
    end
  end
  M.DirtyAnalysis()
  M.Print(string.format("Prune: removed %d old daily values (horizon %d days).", removed, M.C.PRUNE_DAYS))
end

-- Access ---------------------------------------------------------------------
function M.GetSeries(key, realm)        -- {day = {low,qty}} or nil
  local store = M.db and M.db.realms[realm or M.RealmKey()]
  return store and store[key]
end

function M.IterItems(realm)             -- returns the store table
  return (M.db and M.db.realms[realm or M.RealmKey()]) or {}
end

-- highest day in the archive (cached). Quick-scan rows (M.CommitQuick) do not
-- count: a day only a quick scan reached is no scan day for the other items.
function M.LastScanDay(realm)
  realm = realm or M.RealmKey()
  M._lastDayCache = M._lastDayCache or {}
  local cached = M._lastDayCache[realm]
  if cached ~= nil then return cached end
  local last = -1
  for _, it in pairs(M.IterItems(realm)) do
    for day, rec in pairs(it) do
      if day > last and not (type(rec) == "table" and rec.quick) then last = day end
    end
  end
  M._lastDayCache[realm] = last        -- invalidated by M.DirtyAnalysis on any archive change
  return last
end

function M.PrintStatus()
  local realm = M.RealmKey()
  local items, rows = 0, 0
  for _, it in pairs(M.IterItems(realm)) do
    items = items + 1
    for _ in pairs(it) do rows = rows + 1 end
  end
  local last = M.LastScanDay(realm)
  M.Print(string.format("Realm %s: %d items, %d daily values. Last scan day: %s.",
    realm, items, rows, last >= 0 and M.DayLabel(last) or "-"))
  if M.db.config.lastIngest then
    M.Print("Last scan: " .. date("%Y-%m-%d %H:%M", M.db.config.lastIngest))
  end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
  self:UnregisterEvent("PLAYER_LOGIN")
  -- one frame later: M.db is created by Core's own PLAYER_LOGIN handler
  C_Timer.After(0, function()
    M.RepairZeroPrices()
    M.PruneLive()
    M.PruneNeutral()
  end)
end)
