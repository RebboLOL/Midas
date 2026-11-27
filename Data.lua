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

-- ===== Compact stores (1.3.8) ================================================
-- The intraday tails and the offer book are written as one short string per
-- item (base-36 numbers) instead of a table per point: the SavedVariables
-- writer puts every table field on a line of its own, which made the tails the
-- biggest block of the file. New fields, so an older Midas finds nothing it
-- cannot read: MidasDB.intra2 (tails) and MidasDB.book (offer book). The old
-- MidasDB.intra / MidasDB.depth are still read and move over at login
-- (M.MigrateStores, a few hundred items per frame).
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function enc36(n)
  n = math.floor((tonumber(n) or 0) + 0.5)
  if n <= 0 then return "0" end
  local t = {}
  while n > 0 do
    local d = n % 36
    t[#t + 1] = B36:sub(d + 1, d + 1)
    n = (n - d) / 36
  end
  return string.reverse(table.concat(t))
end
local function dec36(s) return tonumber(s, 36) end
M.Enc36, M.Dec36 = enc36, dec36

-- One item's tail: "<base>|", then the points ascending by ts with ";"
-- between them, each
--   <ts - base>,<low>,<qty>[,w<w0>.<wm>]
-- base = a ts at or before the first point. A scan only appends or replaces
-- the last point and drops the oldest as plain string operations (pushIntra),
-- so a full scan of 15,000 items does not decode and re-encode every tail.
-- w = the 3-hour windows of a run at an unchanged price (heat map); other
-- fields (",b" price bands of the 1.3.8 test builds) are skipped, and they
-- leave a tail as its points are rewritten or age out. Strings without "|"
-- (the first 1.3.8 builds) count each ts from the point before.
local function segOf(e, base)
  local p = enc36((tonumber(e.ts) or base) - base) .. "," .. enc36(e.low or 1) .. "," .. enc36(e.qty or 0)
  if e.w0 and type(e.wm) == "string" and e.wm:find("^[01]+$") then p = p .. ",w" .. enc36(e.w0) .. "." .. e.wm end
  return p
end

-- one point; ts counts from `from` (the base, or the point before)
local function segParse(seg, from)
  local o, lo, q, rest = seg:match("^(%w+),(%w+),(%w+)(.*)$")
  if not o then return nil end
  local low = dec36(lo)
  if not low or low < 1 then low = 1 end     -- a price is at least 1c
  local e = { ts = from + (dec36(o) or 0), low = low, qty = dec36(q) or 0 }
  for v in rest:gmatch(",w([^,]*)") do
    local w0, wm = v:match("^(%w+)%.([01]+)$")
    if w0 then e.w0, e.wm = dec36(w0), wm end
  end
  return e
end

local function decodeIntra(s)
  local list = {}
  local b, body = s:match("^(%w+)|(.*)$")
  local base = b and dec36(b)
  if not base then body = s end
  local prev = 0
  for seg in body:gmatch("[^;]+") do
    local e = segParse(seg, base or prev)
    if e then list[#list + 1] = e; prev = e.ts end
  end
  return list
end

local function encodeIntra(list)
  local base = list[1] and math.floor(tonumber(list[1].ts) or 0) or 0
  local out, prev = {}, base
  for _, e in ipairs(list) do
    local ts = math.floor(tonumber(e.ts) or 0)
    if ts < prev then ts = prev end
    out[#out + 1] = segOf({ ts = ts, low = e.low, qty = e.qty, w0 = e.w0, wm = e.wm }, base)
    prev = ts
  end
  return enc36(base) .. "|" .. table.concat(out, ";")
end
M.DecodeIntra, M.EncodeIntra = decodeIntra, encodeIntra

-- the intraday tail of an item (ascending { ts, low, qty, w0?, wm? }),
-- read only; nil when there is none. Decoded lists are kept per string.
local tailCache, tailCacheN = {}, 0
function M.IntraList(key, rk)
  if key == nil or not M.db then return nil end
  key = tostring(key)
  rk = rk or M.RealmKey()
  local s2 = M.db.intra2 and M.db.intra2[rk]
  local s = s2 and s2[key]
  if type(s) == "string" then
    local ck = rk .. "\1" .. key
    local c = tailCache[ck]
    if c and c.s == s then return c.list end
    if tailCacheN > 6000 then tailCache, tailCacheN = {}, 0 end
    local list = decodeIntra(s)
    if not c then tailCacheN = tailCacheN + 1 end
    tailCache[ck] = { s = s, list = list }
    return list
  end
  local leg = M.db.intra and M.db.intra[rk]
  local t = leg and leg[key]
  return type(t) == "table" and t or nil
end

-- intraday tail (1W chart): last scans per item, own top-level store so the
-- daily rows (and the community sync built on them) stay byte-identical.
-- A repeat of the same low+qty only slides the newest point's ts forward and
-- marks its 3-hour window (heat map).
local INTRA_KEEP, INTRA_MAX = 8 * 86400, 16
local INTRA_REBASE = 20 * 86400        -- a base older than this is renewed

-- the 3-hour windows an unchanged run was scanned in, for the heat map
-- (Heatmap.lua): w0 = the run's first window, wm = "1" scanned / "0" not, one
-- character per window from w0, the newest 56 (7 days) kept
local function markWindow(e, now)
  local w = math.floor(now / 10800)
  if not e.w0 then e.w0, e.wm = math.floor(e.ts / 10800), "1" end
  local off, n = w - e.w0, #e.wm
  if off >= n then
    e.wm = e.wm .. string.rep("0", off - n) .. "1"
    if #e.wm > 56 then
      local cut = #e.wm - 56
      e.wm, e.w0 = e.wm:sub(cut + 1), e.w0 + cut
    end
  end
end

-- a repeat of point e's run at `now` (the chart reads ts only)
local function slide(e, now)
  markWindow(e, now)
  e.ts = now
  return true
end

local function repeats(e, low, qty)
  return e and e.low == low and e.qty == qty
end

-- a decoded tail + an old table tail (not moved yet, or written by an older
-- Midas after a downgrade): the table's points newer than the tail join it
local function joinOld(st, old)
  if type(old) ~= "table" then return st end
  local lastTs = st[#st] and st[#st].ts or -math.huge
  for _, oe in ipairs(old) do
    if type(oe) == "table" and tonumber(oe.ts) and tonumber(oe.low) and oe.ts > lastTs then
      st[#st + 1] = { ts = oe.ts, low = oe.low, qty = oe.qty, w0 = oe.w0, wm = oe.wm }
      lastTs = oe.ts
    end
  end
  return st
end

local function pushIntra(rk, key, low, qty, now)
  M.db.intra2 = M.db.intra2 or {}
  local dst = M.db.intra2[rk]
  if not dst then dst = {}; M.db.intra2[rk] = dst end
  local s = dst[key]
  local leg = M.db.intra and M.db.intra[rk]
  local old = leg and leg[key]
  local bs = type(s) == "string" and s:match("^(%w+)|")
  local base = bs and dec36(bs)
  local icut = now - INTRA_KEEP
  if base and old == nil and now - base <= INTRA_REBASE then
    -- the fast way: only the last point and the oldest ones are touched
    local hp = #bs + 1                          -- the "|"
    local sc = s:match(".*();")                 -- the last ";"
    local p = (sc and sc > hp) and (sc + 1) or (hp + 1)
    local e = segParse(s:sub(p), base)
    -- a clock set back: never before the newest point (the tail stays ascending)
    if e and now < e.ts then now = e.ts end
    if repeats(e, low, qty) and slide(e, now) then
      s = s:sub(1, p - 1) .. segOf(e, base)
    else
      s = s .. ((s:sub(-1) == "|") and "" or ";") .. segOf({ ts = now, low = low, qty = qty }, base)
    end
    -- the oldest points go: older than INTRA_KEEP or past the newest INTRA_MAX
    local n = select(2, s:gsub(";", ";")) + 1
    while s do
      local first = s:match("^%w+|(%w+)")
      local fts = first and (base + (dec36(first) or 0))
      if not fts or not (n > INTRA_MAX or fts < icut) then break end
      local cut = s:find(";", hp + 1, true)
      if cut then s = s:sub(1, hp) .. s:sub(cut + 1); n = n - 1 else s = nil end
    end
    dst[key] = s
    return
  end
  -- the full way: a first point, an old table tail, the older string format
  -- or a base that lies far back (renewed here)
  local st = joinOld((type(s) == "string") and decodeIntra(s) or {}, old)
  if old ~= nil and leg then leg[key] = nil end
  local lp = st[#st]
  if lp and now < lp.ts then now = lp.ts end     -- a clock set back (see above)
  if not (repeats(lp, low, qty) and slide(lp, now)) then
    st[#st + 1] = { ts = now, low = low, qty = qty }
  end
  while st[1] and (st[1].ts < icut or #st > INTRA_MAX) do table.remove(st, 1) end
  dst[key] = st[1] and encodeIntra(st) or nil
end
M._PushIntra = pushIntra   -- for the tests

-- the offer book of one item as stored in MidasDB.book:
--   <auctions>,<listed>,<p1>:<q1>:<n1>,<p2 - p1>:<q2>:<n2>,...
-- (unit prices ascending, each after the first as the step from the one
-- before). flat = { N, p1, q1, n1, ... } as the old table format had it.
local function encodeBook(flat, listed)
  local out, prev = { enc36(flat[1] or 0), enc36(listed or 0) }, 0
  for i = 2, #flat, 3 do
    local p = math.floor((tonumber(flat[i]) or 0) + 0.5)
    out[#out + 1] = enc36(p - prev) .. ":" .. enc36(flat[i + 1]) .. ":" .. enc36(flat[i + 2])
    prev = p
  end
  return table.concat(out, ",")
end

local function decodeBook(s)
  local flat, listed, p, k = {}, nil, 0, 0
  for part in s:gmatch("[^,]+") do
    k = k + 1
    if k == 1 then flat[1] = dec36(part) or 0
    elseif k == 2 then
      listed = dec36(part)
      if listed == 0 then listed = nil end   -- not known (an item on the AH has units)
    else
      local dp, q, n = part:match("^(%w+):(%w+):(%w+)$")
      if dp then
        p = p + (dec36(dp) or 0)
        flat[#flat + 1] = p; flat[#flat + 1] = dec36(q) or 0; flat[#flat + 1] = dec36(n) or 0
      end
    end
  end
  return flat, listed
end
M.EncodeBook, M.DecodeBook = encodeBook, decodeBook

-- the stored book of this realm (MidasDB.book, else until the next full scan
-- the old MidasDB.depth): { ts, market, items = { [id] = string or flat },
-- qty = { [id] = listed } }. A full scan writes tables (no encoding in the
-- frame that commits 15,000 items), the logout packs them into strings
-- (M.CompactBook); an item is read in either form.
local function bookOf(rk)
  rk = rk or M.RealmKey()
  local b = M.db and M.db.book and M.db.book[rk]
  if b and b.items then return b, true end
  local d = M.db and M.db.depth and M.db.depth[rk]
  if d and d.items then return d, false end
  return nil
end
M.BookOf = bookOf

-- flat { N, p1, q1, n1, ... } + listed of one item of the stored book
function M.BookFlat(itemID, rk)
  local b = bookOf(rk)
  local id = tonumber(itemID)
  local v = b and id and b.items[id]
  if type(v) == "string" then return decodeBook(v) end
  if type(v) ~= "table" then return nil end
  return v, b.qty and b.qty[id]
end

-- every book still in tables -> compact strings (PLAYER_LOGOUT, before the
-- client writes the SavedVariables; a /reload counts as a logout)
function M.CompactBook()
  local db = M.db
  if not (db and type(db.book) == "table") then return end
  for _, d in pairs(db.book) do
    if type(d) == "table" and type(d.items) == "table" then
      local q = type(d.qty) == "table" and d.qty or nil
      for id, v in pairs(d.items) do
        if type(v) == "table" then d.items[id] = encodeBook(v, q and q[id]) end
      end
      d.qty = nil
    end
  end
end
do
  local lf = CreateFrame("Frame")
  if M.SafeRegister then M.SafeRegister(lf, "PLAYER_LOGOUT") else lf:RegisterEvent("PLAYER_LOGOUT") end
  lf:SetScript("OnEvent", function() M.CompactBook() end)
end

-- Old tables -> compact strings, a few hundred items per frame (a 50 MB
-- SavedVariables file holds 150,000 tail points; one frame doing them all
-- could hit the client's script time limit). Readers use whichever store
-- holds an item meanwhile.
local MIGRATE_CHUNK = 300
function M.MigrateStores()
  local db = M.db
  if not db then return end
  db.intra2 = db.intra2 or {}
  db.book = db.book or {}
  local function step()
    -- the offer books: one realm per frame
    for rk, d in pairs(db.depth or {}) do
      if type(d) == "table" then
        local nb = db.book[rk]
        if type(d.items) == "table" and not (nb and (tonumber(nb.ts) or 0) >= (tonumber(d.ts) or 0)) then
          -- moved as it is; the logout packs it (M.CompactBook)
          db.book[rk] = { ts = d.ts, market = d.market, items = d.items, qty = d.qty }
        end
      end
      db.depth[rk] = nil
      C_Timer.After(0, step)
      return
    end
    -- the tails: MIGRATE_CHUNK items per frame
    for rk, leg in pairs(db.intra or {}) do
      if type(leg) ~= "table" then
        db.intra[rk] = nil
      else
        local dst = db.intra2[rk]
        if not dst then dst = {}; db.intra2[rk] = dst end
        local n = 0
        for key, list in pairs(leg) do
          if type(list) == "table" then
            -- a compact tail already there (written before a downgrade):
            -- the table's newer points join it
            local cur = dst[key]
            local st = joinOld((type(cur) == "string") and decodeIntra(cur) or {}, list)
            while st[INTRA_MAX + 1] do table.remove(st, 1) end
            if st[1] then dst[key] = encodeIntra(st) end
          end
          leg[key] = nil
          n = n + 1
          if n >= MIGRATE_CHUNK then break end
        end
        if next(leg) == nil then db.intra[rk] = nil end
      end
      C_Timer.After(0, step)
      return
    end
  end
  step()
end

-- A scan that does not look like this faction's auction house: far fewer items
-- than your own scans of today/yesterday hold AND many prices well away from
-- your newest ones. The thresholds match the server's quarantine (SPEC 4):
-- ordinary scans stay at >= 0.92 of the size with at most 40 % such prices,
-- neutral auction house scans came in at 0.57-0.65 with 53-54 %.
local FOREIGN_SIZE, FOREIGN_FACTOR, FOREIGN_SHARE = 0.80, 1.5, 0.45
local FOREIGN_MIN_REF, FOREIGN_MIN_COMMON = 500, 50

function M.LooksForeignScan(acc)
  local store = M.db and M.db.realms and M.db.realms[M.RealmKey()]
  if type(store) ~= "table" or type(acc) ~= "table" then return false end
  local today = M.GetScanDay()
  local size, ref = { [today] = 0, [today - 1] = 0 }, {}
  for key, it in pairs(store) do
    if type(it) == "table" and type(key) == "string" and key:match("^%d+$") then
      local newest
      for d = today - 1, today do
        local rec = it[d]
        -- scanned rows only (a scan time, not a quick scan): imports carry none
        if type(rec) == "table" and rec.ts and not rec.quick then
          size[d] = size[d] + 1
          if rec.cur then newest = rec.cur end
        end
      end
      if newest then ref[key] = newest end
    end
  end
  local refSize = math.max(size[today], size[today - 1])
  if refSize < FOREIGN_MIN_REF then return false end
  local n, common, off = 0, 0, 0
  for itemID, a in pairs(acc) do
    if type(a) == "table" and a.low then
      n = n + 1
      local cur = ref[tostring(itemID)]
      if cur and cur > 0 then
        common = common + 1
        local low = unitPrice(a.low)
        if low >= cur * FOREIGN_FACTOR or cur >= low * FOREIGN_FACTOR then off = off + 1 end
      end
    end
  end
  return n < refSize * FOREIGN_SIZE and common >= FOREIGN_MIN_COMMON and off > common * FOREIGN_SHARE
end

-- Commit a scan snapshot {itemID = {low=copper, qty=n}} into MidasDB.
-- One bucket per scan day; idempotent merge (low = MIN, qty = MAX). Each record
-- also carries cur (latest scan price, last-write-wins) and ts (scan timestamp,
-- the tie-breaker that keeps cur consistent across community sync). Rows the
-- scan actually changed are handed to Comm.lua for broadcasting.
-- A scan at a neutral AH is stored apart and touches nothing else.
-- opts.noDepth: a price scan (ScannerModern.lua) - every item's cheapest unit
-- price and units, but no single auctions. Rows, newest scan day and sync as
-- for a full scan; the offer book stays as the last snapshot left it.
-- opts.note: text appended to the chat line.
function M.CommitScan(acc, opts)
  if not M.db or type(acc) ~= "table" then return end
  local noDepth = opts and opts.noDepth and true or false
  local neutral = M.ScanFromNeutralAH()
  local foreign = not neutral and M.LooksForeignScan(acc)
  if foreign then
    -- the zone and the auctioneer said "faction AH", the scan says otherwise:
    -- keep it apart, and the rest of this visit with it
    neutral = true
    M._visitNeutral = true
    if M.AHOpen then M._ahNeutral = true end
  end
  if neutral then
    local day, now, items = M.GetScanDay(), time(), 0
    for itemID, a in pairs(acc) do
      if a.low then items = items + 1; noteNeutral(itemID, unitPrice(a.low), a.qty, day, now) end
    end
    if foreign then
      M.Print(string.format("This scan does not look like your %s auction house (%d items, many prices unlike your last scans) - stored apart like a neutral auction house scan. If this was your faction's auction house, please type /midas market here and post the lines in #bug-reports.",
        UnitFactionGroup("player") or "faction", items))
    else
      M.Print(string.format("Neutral auction house scan stored apart: %d items, day %s - your %s prices stay as they were.",
        items, M.DayLabel(day), UnitFactionGroup("player") or "faction"))
    end
    return
  end
  local day = M.GetScanDay()
  local now = time()
  local store = Store()
  local rk = M.RealmKey()
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
      pushIntra(rk, key, low, a.qty or 0, now)
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
  -- the rows of a price scan stay readable until the next full scan (API.lua
  -- GetLastScanRows, Datalink.lua); a full scan has its offer book for that
  M._lastScanRows = noDepth and { ts = now, market = M.MarketInfo(), acc = acc } or nil
  -- a full scan is newer than every price the AH showed before it
  if M.db.live then M.db.live[rk] = nil end
  if not noDepth then M.CommitDepth(acc, now) end
  -- today is a full-scan day now: raise the cached newest day instead of
  -- dropping it (the next reader would walk the whole archive for it)
  local ldc = M._lastDayCache
  if items > 0 and ldc and ldc[rk] and day > ldc[rk] then ldc[rk] = day end
  M.DirtyAnalysis(items == 0 or (ldc and ldc[rk]) ~= nil)
  M.Print(string.format("%s stored: %d items, day %s.%s", noDepth and "Price scan" or "Full scan",
    items, M.DayLabel(day), (opts and opts.note) or ""))
  if M.CheckAlerts then M.CheckAlerts() end
  -- the sell helper at the AH ranks bags by these prices: re-fill it in place
  if M.ShowSellDock then M.ShowSellDock() end
  if M.OnScanCommitted then M.OnScanCommitted(day, changed, now) end
  -- depth = false: a price scan, the offer book is still the last snapshot's
  if M.FireAPIEvent then M.FireAPIEvent("SCAN_COMPLETE", { day = day, items = items, ts = now, market = M.MarketInfo(), depth = not noDepth }) end
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
  if M.ScanFromNeutralAH() then
    for itemID, a in pairs(acc) do
      if a.low then items = items + 1; noteNeutral(itemID, unitPrice(a.low), a.qty, day, now) end
    end
    return items
  end
  local store = Store()
  local rk = M.RealmKey()
  for itemID, a in pairs(acc) do
    if type(a) == "table" and type(a.low) == "number" and a.low > 0 then
      items = items + 1
      local key = tostring(itemID)
      local low, qty = unitPrice(math.floor(a.low)), a.qty or 0
      local it = store[key]; if not it then it = {}; store[key] = it end
      pushIntra(rk, key, low, qty, now)
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
  M.DirtyAnalysis(true, true)   -- quick rows never move the newest scan day, only touch today
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
  M.DirtyAnalysis(true, true)   -- live prices stay out of the archive
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
  if M.ScanFromNeutralAH() then noteNeutral(id, unit, qty, M.GetScanDay(), time()); return end
  local rk = M.RealmKey()
  M.db.live = M.db.live or {}
  local ls = M.db.live[rk]; if not ls then ls = {}; M.db.live[rk] = ls end
  local key = tostring(id)
  local old = ls[key]
  if M._mCache and M._mCache.items then M._mCache.items[key] = nil end
  -- the same price again (an Auctionator scan writes thousands): only its
  -- time moves, no new table and no whole-archive refresh
  if old and old.p == unit and old.q == qty then old.ts = time(); return end
  ls[key] = { p = unit, q = qty, ts = time() }
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
-- MidasDB.book[realmKey] = { ts, market, items = { [itemID] = { N, p1, q1, n1,
-- p2, ... } }, qty = { [itemID] = listed } } while the session runs, packed
-- into one string per item at the logout (M.CompactBook, encodeBook above).
-- N = buyout auctions over ALL prices; p = unit buyout (copper, ascending),
-- q = units, n = auctions at that price (cheapest DEPTH_LEVELS prices only);
-- listed = ALL units on the AH. A new scan replaces the whole realm entry, so
-- sold-out items drop out (and an old MidasDB.depth entry of the realm with it).
local DEPTH_LEVELS = 20

function M.CommitDepth(acc, now)
  M.db.book = M.db.book or {}
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
  -- tables now, strings at the logout (M.CompactBook)
  local rk = M.RealmKey()
  M.db.book[rk] = { ts = now, market = M.MarketInfo(), items = items, qty = qty }
  if M.db.depth then M.db.depth[rk] = nil end
end

-- Depth of one item on the current realm: levels = { {price, qty, auctions, cum}, ... },
-- plus ts of the scan it comes from and the item's total auction count.
-- nil when the newest scan did not list it.
function M.GetDepth(itemID)
  local d = bookOf()
  local flat, listed = M.BookFlat(itemID)
  if not (d and flat) then return nil end
  local levels, cum = {}, 0
  for i = 2, #flat, 3 do
    cum = cum + flat[i + 1]
    levels[#levels + 1] = { price = flat[i], qty = flat[i + 1], auctions = flat[i + 2], cum = cum }
  end
  -- listed = every unit on the AH (scans before 1.2.3 final: the stored levels only)
  return { ts = d.ts, levels = levels, units = cum, auctions = flat[1], listed = listed or cum }
end

-- A buyout the player just made thins the stored ladder immediately - the
-- snapshot itself is only replaced by the next full scan. Returns true when
-- the bought price level was found and reduced (then the open books refresh).
function M.DepthBuyout(itemID, unit, units)
  if M.AtNeutralAH() then return false end   -- the stored ladder is your own market's
  local d = bookOf()
  local id = tonumber(itemID)
  local flat, listed = M.BookFlat(id)
  if not (d and flat) or not unit then return false end
  local packed = type(d.items[id]) == "string"
  unit = unitPrice(unit)
  for i = 2, #flat, 3 do
    if flat[i] == unit then
      flat[i + 1] = flat[i + 1] - (units or 1)
      flat[i + 2] = flat[i + 2] - 1
      flat[1] = math.max(0, (flat[1] or 1) - 1)
      if listed then listed = math.max(0, listed - (units or 1)) end
      if flat[i + 1] <= 0 or flat[i + 2] <= 0 then
        table.remove(flat, i); table.remove(flat, i); table.remove(flat, i)
      end
      if packed then
        d.items[id] = encodeBook(flat, listed)    -- a decoded copy: pack it back
      elseif d.qty and d.qty[id] then
        d.qty[id] = listed                         -- the table itself was thinned
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
  M.DirtyAnalysis(true)   -- MergeSharedRows raised the newest scan day itself
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

-- One-shot per market (1.3.4): up to 23.11.2026 the server filed RP-PvP realms
-- ("... RP PvP") under PvP, and so did Midas. Server prices loaded since then
-- were wrong in both directions, and the import keeps the lowest price of a
-- day, so a wrong low stays until it is removed:
-- * RP-PvP realms got the prices of the PvP auction house: the last 90 days
--   (what the server hands out) are cleaned - rows no scan wrote (no time) go,
--   and a day low below the day's last scanned price returns to that price;
-- * three PvP markets carried RP-PvP scans (exports before and after the move
--   compared: EU Horde, US Horde, EU Alliance, days 4.-22.11.): there only
--   those days are cleaned, and only lows more than 20% below the day's last
--   scanned price return to it (a normal day keeps its own low).
-- Only where server prices were loaded. The import marks are dropped, so the
-- clean server prices (Datalink.lua: never from a Prices.lua written before
-- the move) and Auctionator / aux rows come back. Returns the values changed.
local SERVER_DAYS = 90
local TAINTED_PVP = { ["EU Horde"] = true, ["US Horde"] = true, ["EU Alliance"] = true }
local function dayOf(y, m, d)
  return math.floor((time({ year = y, month = m, day = d, hour = 12 }) - M.C.SCAN_DAY_0) / 86400)
end
function M.RepairServerPrices()
  if not (M.db and M.RealmRuleset and M.RealmName and M.MODERN_AH) then return 0 end
  local rs = M.RealmRuleset(M.RealmName())
  local from, to, gap
  if rs == "RPPvP" then
    from, to, gap = M.GetScanDay() - SERVER_DAYS, math.huge, 1
  elseif rs == "PvP" then
    local mk = M.MarketInfo and M.MarketInfo()
    if not (mk and TAINTED_PVP[tostring(mk.region) .. " " .. tostring(mk.faction)]) then return 0 end
    from, to, gap = dayOf(2026, 11, 3), dayOf(2026, 11, 23), 1.25
  else
    return 0
  end
  M.db.config = M.db.config or {}
  local cfg, rk = M.db.config, M.RealmKey()
  cfg.srvFix = cfg.srvFix or {}
  if cfg.srvFix[rk] then return 0 end
  cfg.srvFix[rk] = 1
  local imp = cfg.impSrc
  local srv = type(imp) == "table" and type(imp["Midas Server"]) == "table" and imp["Midas Server"][rk]
  local store = M.db.realms and M.db.realms[rk]
  if not srv or type(store) ~= "table" then return 0 end
  local n = 0
  for key, it in pairs(store) do
    for day, rec in pairs(it) do
      if type(day) == "number" and day >= from and day <= to and type(rec) == "table" then
        if not rec.ts then
          it[day] = nil; n = n + 1
        elseif rec.cur and rec.low and rec.low * gap < rec.cur then
          rec.low = rec.cur; n = n + 1
        end
      end
    end
    if next(it) == nil then store[key] = nil end
  end
  for _, per in pairs(imp) do
    if type(per) == "table" then per[rk] = nil end
  end
  if n > 0 then
    if M.DirtyAnalysis then M.DirtyAnalysis() end
    M.Print(string.format("Server prices: midasmarket.app mixed RP-PvP and PvP auction houses until 23 November. Cleaned %d daily values of that time - your own scans stay, the corrected prices load again.", n))
  end
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
