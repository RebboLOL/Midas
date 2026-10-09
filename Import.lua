-- Midas – Import: seed the price archive from OTHER addons' scan databases
-- (Auctionator, aux) at login, so a fresh install starts with real history and
-- Auctionator/aux-scanning users stay current without ever running /midas scan.
--
-- Design: pluggable sources normalize into { [itemKey] = { [day] = {low, qty} } },
-- a background coroutine merges them with the same MIN/MAX lattice as the
-- community sync (low = MIN, qty = MAX) -- idempotent, so it can run every login.
-- Imported rows carry NO cur/ts: the user's own scans stay authoritative, and
-- the sync layer never broadcasts a fabricated "current" price (Comm.lua only
-- attaches cur when ts exists). One DirtyAnalysis per productive batch.
local ADDON, M = ...

-- ===== source registry =======================================================
-- A source is { name, Available()->bool, Ready()->handle|nil,
--   Fingerprint(handle)->string, Keys(handle)->array (MUST run in one frame),
--   Rows(handle, key) -> itemKey, {[dayNumber]={low,qty}} | nil }.
-- Adding a future source (e.g. TSM once it has local data again) means
-- implementing exactly these five members -- driver, merge, fingerprint store,
-- chat line and Sync-tab status are shared.
local sources = {}
function M.RegisterImportSource(def) sources[#sources + 1] = def end

-- ===== Auctionator ===========================================================
-- AUCTIONATOR_PRICE_DATABASE[realm] -- on disk a CBOR string, but Auctionator
-- deserializes the CURRENT realm into a plain table at login (State.Loaded).
-- Per item: { l={[dayStr]=lowestLow}, h={[dayStr]=highestLow}, a={[dayStr]=qty},
-- m=lastMin }. Day index and realm key are IDENTICAL to ours (same 2020-01-01
-- epoch, same "<Realm> <Faction>" key). Daily minimum = l[day] or h[day].
-- m is NOT imported: it has no timestamp, so mapping it to cur would let the
-- LWW sync mesh propagate a fabricated "current" price.
M.RegisterImportSource({
  name = "Auctionator",
  Available = function()
    return type(Auctionator) == "table" and type(AUCTIONATOR_PRICE_DATABASE) == "table"
  end,
  Ready = function()
    local st = Auctionator.State
    if not (st and st.Loaded and st.CurrentRealm) then return nil end
    local rt = AUCTIONATOR_PRICE_DATABASE[st.CurrentRealm]
    if type(rt) ~= "table" then return nil end   -- still a CBOR string -> retry
    return rt
  end,
  Fingerprint = function(rt)
    -- catches: any GetAll scan (timestamp), any never-seen item (count), and a
    -- new calendar day (at most one full re-walk per day). Same-day browse
    -- increments are picked up next day at the latest -- the 21-day window and
    -- the MIN/MAX merge make a skipped increment harmless.
    local n = 0
    for _ in pairs(rt) do n = n + 1 end
    local sv = AUCTIONATOR_SAVEDVARS
    return n .. ":" .. ((sv and sv.TimeOfLastGetAllScan) or 0) .. ":" .. M.GetScanDay()
  end,
  Keys = function(rt)
    local keys, n = {}, 0
    for k in pairs(rt) do n = n + 1; keys[n] = k end
    return keys
  end,
  Rows = function(rt, key)
    if type(key) ~= "string" and type(key) ~= "number" then return nil end
    key = tostring(key)
    -- "version" = realm-table meta entry; "p:" = battle pets (no Era market)
    if key == "version" or key:sub(1, 2) == "p:" then return nil end
    local v = rt[key]   -- re-read: the entry may have changed since the snapshot
    -- structural defense against future __dbversion drift: only consume entries
    -- that look like the documented shape
    if type(v) ~= "table" or (type(v.h) ~= "table" and type(v.l) ~= "table") then return nil end
    local today = M.GetScanDay()
    local minDay = today - (M.C.PRUNE_DAYS or 730)
    local out, any = {}, false
    local function take(dayStr)
      local d = tonumber(dayStr)
      if not d or d <= minDay or d > today + 1 then return end
      local low = (type(v.l) == "table" and v.l[dayStr]) or (type(v.h) == "table" and v.h[dayStr])
      if type(low) ~= "number" or low <= 0 or low > 5e8 then return end
      local qty = (type(v.a) == "table" and tonumber(v.a[dayStr])) or 0
      if qty < 0 or qty > 1e5 then qty = 0 end
      local rec = out[d]
      if not rec then out[d] = { low, qty }; any = true
      else
        if low < rec[1] then rec[1] = low end
        if qty > rec[2] then rec[2] = qty end
      end
    end
    if type(v.h) == "table" then for dayStr in pairs(v.h) do take(dayStr) end end
    if type(v.l) == "table" then for dayStr in pairs(v.l) do take(dayStr) end end
    if not any then return nil end
    return key, out
  end,
})

-- ===== aux-addon =============================================================
-- aux.faction["<Realm>|<Faction>"].history[itemID..":"..suffixID] = a PLAIN
-- string "<next_push>#<daily_min_buyout>#<value>@<time>;<value>@<time>;...".
-- data_points[1] is newest (max 11); `time` is the unix stamp of the local
-- midnight that CLOSES the summarized day -> day = round((t-epoch)/86400) - 1.
-- The running day still sits in daily_min_buyout with next_push = the coming
-- midnight. We parse the raw strings ourselves -- aux's own read_record has a
-- write side effect (day roll-over) we must not trigger. Only suffix-":0" keys
-- are imported: numeric suffix ids don't map onto our "gr:<id>:<suffixString>"
-- keys, and folding suffixed gear into the base item would mix price levels.
M.RegisterImportSource({
  name = "aux",
  Available = function()
    return type(aux) == "table" and type(aux.faction) == "table"
  end,
  Ready = function()
    local fk = GetRealmName() .. "|" .. (UnitFactionGroup("player") or "")
    local fd = aux.faction[fk]
    if type(fd) ~= "table" or type(fd.history) ~= "table" then return nil end
    return fd.history
  end,
  Fingerprint = function(hist)
    local n = 0
    for _ in pairs(hist) do n = n + 1 end
    return n .. ":aux:" .. M.GetScanDay()
  end,
  Keys = function(hist)
    local keys, n = {}, 0
    for k in pairs(hist) do n = n + 1; keys[n] = k end
    return keys
  end,
  Rows = function(hist, key)
    if type(key) ~= "string" then return nil end
    local id = key:match("^(%d+):0$")
    if not id then return nil end
    local rec = hist[key]
    if type(rec) ~= "string" or rec == "" then return nil end
    local npRaw, dmbRaw, points = rec:match("^([^#]*)#([^#]*)#(.*)$")
    if not npRaw then return nil end
    local today = M.GetScanDay()
    local minDay = today - (M.C.PRUNE_DAYS or 730)
    local D0 = M.C.SCAN_DAY_0
    local out, any = {}, false
    local function put(d, low)
      if not d or d <= minDay or d > today + 1 then return end
      if type(low) ~= "number" or low <= 0 or low > 5e8 then return end
      local r = out[d]
      if not r then out[d] = { low, 0 }; any = true
      elseif low < r[1] then r[1] = low end
    end
    if points and points ~= "" then
      for val, ts in points:gmatch("([^;@]*)@([^;]*)") do
        local v2, t2 = tonumber(val), tonumber(ts)
        if v2 and t2 then
          -- round, not floor: DST can shift local midnight by an hour
          put(math.floor((t2 - D0) / 86400 + 0.5) - 1, v2)
        end
      end
    end
    local np, dmb = tonumber(npRaw), tonumber(dmbRaw)
    if np and dmb then
      -- the not-yet-pushed running minimum belongs to the day next_push closes
      put(math.floor((np - D0) / 86400 + 0.5) - 1, dmb)
    end
    if not any then return nil end
    return id, out
  end,
})

-- ===== merge + coroutine driver =============================================
-- Mirrors the analysis pipeline's frame pump (Logic.lua EnsureAnalysis): one
-- resume per frame, IMPORT_CHUNK items per resume. 8.8k items x <=22 day-rows
-- finish in ~22 invisible frames -- a synchronous loop would trip WoW's
-- "script ran too long" watchdog. While an import runs, EnsureAnalysis
-- early-outs (stale-while-revalidate keeps the UI served), so the two
-- whole-archive jobs never interleave a pairs() walk with writes.
local function runImport(src, handle, fp, force)
  local store = M.Store()
  local wasEmpty = (next(store) == nil)
  local keys = src.Keys(handle)   -- synchronous snapshot: the SOURCE table can
                                  -- gain keys mid-import (Auctionator scans at
                                  -- the AH) and pairs() across frames is UB
  local CHUNK = M.C.IMPORT_CHUNK or 400
  local items, rows = 0, 0
  for i = 1, #keys do
    local okRow, itemKey, days = pcall(src.Rows, handle, keys[i])
    if okRow and itemKey and days then
      local it = store[itemKey]
      if not it then it = {}; store[itemKey] = it end
      local touched = false
      for day, lq in pairs(days) do
        local rec = it[day]
        if not rec then
          it[day] = { low = lq[1], qty = lq[2] }
          rows = rows + 1; touched = true
        else
          local ch = false
          if lq[1] < rec.low then rec.low = lq[1]; ch = true end
          if lq[2] > (rec.qty or 0) then rec.qty = lq[2]; ch = true end
          if ch then rows = rows + 1; touched = true end
        end
      end
      if touched then items = items + 1 end
      if next(it) == nil then store[itemKey] = nil end
    end
    if i % CHUNK == 0 then coroutine.yield() end
  end
  -- finalize (frame-atomic): remember the fingerprint, refresh once
  M.db.config.impSrc = M.db.config.impSrc or {}
  local per = M.db.config.impSrc[src.name] or {}
  M.db.config.impSrc[src.name] = per
  local prev = per[M.RealmKey()]
  per[M.RealmKey()] = { fp = fp, at = time(), items = items, rows = rows,
                        totItems = ((prev and prev.totItems) or 0) + items }
  if rows > 0 then
    M.DirtyAnalysis()
    local msg = string.format("imported %d items / %d day-rows from %s.", items, rows, src.name)
    if wasEmpty then msg = msg .. "  Open /midas to explore." end
    M.Print(msg)
    if M.FireAPIEvent then M.FireAPIEvent("IMPORT_COMPLETE", { source = src.name, items = items, rows = rows }) end
  elseif force then
    M.Print("import: nothing new from " .. src.name .. ".")
  end
end

local function ensureFrame()
  if M._importFrame then return M._importFrame end
  local fr = CreateFrame("Frame")
  fr:Hide()
  fr:SetScript("OnUpdate", function()
    local job = M._importJob
    if not job then fr:Hide(); return end
    local ok, err = coroutine.resume(job)
    if not ok then
      M._importJob = nil; fr:Hide()
      M.Print("import error: " .. tostring(err))
      if M._importNext then local nx = M._importNext; M._importNext = nil; nx() end
    elseif coroutine.status(job) == "dead" then
      M._importJob = nil; fr:Hide()
      if M.EnsureAnalysis then M.EnsureAnalysis() end   -- suppressed during import
      if M.frame and M.frame:IsShown() and M.RefreshUI then M.RefreshUI() end
      if M._importNext then local nx = M._importNext; M._importNext = nil; nx() end
    end
  end)
  M._importFrame = fr
  return fr
end

-- Walk the queue of available sources SEQUENTIALLY (one coroutine at a time).
-- Each source: poll Ready() (12 x 5 s, then give up silently this session),
-- fingerprint early-out, and never start while an analysis build is running.
local function runNext(q, i, force, tries)
  if i > #q or not M.db then return end
  local src = q[i]
  local function nextSource() runNext(q, i + 1, force, 0) end
  local ok, handle = pcall(src.Ready)
  if not ok or not handle then
    if tries < 12 then
      C_Timer.After(5, function() runNext(q, i, force, tries + 1) end)
    else
      nextSource()
    end
    return
  end
  local okFp, fp = pcall(src.Fingerprint, handle)
  if not okFp then fp = "err:" .. M.GetScanDay() end
  local per = M.db.config.impSrc and M.db.config.impSrc[src.name]
  local last = per and per[M.RealmKey()]
  if not force and last and last.fp == fp then nextSource(); return end
  if M._analysisJob then
    C_Timer.After(2, function() runNext(q, i, force, tries) end)
    return
  end
  if M._importJob then return end   -- foreign job (shouldn't happen) -> bail
  M._importNext = nextSource
  M._importJob = coroutine.create(function() runImport(src, handle, fp, force) end)
  ensureFrame():Show()
end

-- Login entry point AND "/midas import" (force = re-check despite fingerprint).
function M.ImportExternal(force)
  if not M.db or M._importJob then return end
  local q = {}
  for i = 1, #sources do
    local ok, av = pcall(sources[i].Available)
    if ok and av then q[#q + 1] = sources[i] end
  end
  if #q == 0 then
    if force then M.Print("import: no other price-database addon found (Auctionator, aux).") end
    return
  end
  runNext(q, 1, force, 0)
end
