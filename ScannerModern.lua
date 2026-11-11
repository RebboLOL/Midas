-- Midas – ScannerModern: full auction-house scan on the modern client (WoW Forever)
-- C_AuctionHouse.ReplicateItems() delivers a snapshot of every auction (commodities
-- included) -> REPLICATE_ITEM_LIST_UPDATE -> rows 0..n-1 via GetReplicateItemInfo.
-- Same contract as Scanner.lua: acc[itemID] = { low = min unit buyout, qty = sum,
-- lv = { [unit] = { units, auctions } } }
-- -> M.CommitScan(acc). Only active when Compat detected the modern AH.
-- While the snapshot is slow (or on cooldown) a quick scan fetches current prices
-- for your own items (see "Quick scan" below).
local ADDON, M = ...
if not M.MODERN_AH then return end

local AH = C_AuctionHouse
local CHUNK = 3000           -- rows processed per frame (avoids freezing)
local REPLICATE_CD = 900     -- server allows one replicate snapshot per ~15 min
local TIMEOUT = 300          -- wait this long for a snapshot (slow at busy hours)
local scanPending = false
local driver, ticker

local function stopDriver()
  if driver then driver:SetScript("OnUpdate", nil) end
end

-- ===== Quick scan: current prices for YOUR items while the snapshot is slow ==
-- The full snapshot comes once per ~15 min per account and can take minutes in
-- the evening. Meanwhile Midas asks the AH directly for the items that matter to
-- you - own auctions, price alerts, watchlist, then stock that has been on this
-- AH before - with C_AuctionHouse.SearchForItemKeys, QUICK_BATCH items per
-- request. The answers are ordinary browse / item results, which Live.lua turns
-- into current prices (M.ObserveLive); at the end the items found get today's
-- daily row (Data.lua M.CommitQuick - the chart point), marked so that every
-- item the quick scan did not reach counts as "not scanned", not "not listed".
local QUICK_AFTER = 45      -- seconds without a snapshot before the quick scan starts
local QUICK_MAX = 200       -- items per quick scan
local QUICK_BATCH = 50      -- item keys per browse request
local QUICK_WAIT = 8        -- seconds to wait for one answer
local QUICK_FOLLOW = 30     -- item lists for stackable non-commodities
local quick                 -- the running quick scan (nil = none)

local function quickAvailable()
  return AH.SearchForItemKeys ~= nil and AH.GetBrowseResults ~= nil
    and not (M.db and M.db.config and M.db.config.quickScan == false)
end

local function isGear(id)
  local instant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
  local classID = instant and select(6, instant(id))
  return classID == 2 or classID == 4
end

local function sortedIds(t)
  local out = {}
  for k in pairs(t or {}) do local id = tonumber(k); if id then out[#out + 1] = id end end
  table.sort(out)
  return out
end

-- The items worth a quick look, most urgent first, at most QUICK_MAX.
-- Gear is left out (Live.lua never prices a single random suffix).
function M.QuickItemKeys()
  local out, seen = {}, {}
  local db = M.db
  if not db then return out end
  local function add(id)
    id = tonumber(id)
    if not id or id <= 0 or seen[id] or #out >= QUICK_MAX or isGear(id) then return end
    seen[id] = true
    out[#out + 1] = id
  end
  local chars = {}
  for ck, c in pairs(db.chars or {}) do
    if type(c) == "table" and not c.dead and ((not M.CharInScope) or M.CharInScope(c)) then
      chars[#chars + 1] = ck
    end
  end
  table.sort(chars)
  local now = time()
  -- 1) own auctions (UNDERCUT); a listing older than 48 h has ended anyway
  for _, ck in ipairs(chars) do
    local c = db.chars[ck]
    if type(c.auctions) == "table" and c.auctionsTs and (now - c.auctionsTs) <= 48 * 3600 then
      for _, id in ipairs(sortedIds(c.auctions)) do add(id) end
    end
  end
  -- 2) price alerts of this auction house
  local realm = M.RealmKey and M.RealmKey()
  for _, id in ipairs(sortedIds(realm and db.alerts and db.alerts[realm])) do add(id) end
  -- 3) watchlist
  local watch = {}
  for k, v in pairs(db.watch or {}) do if v == true then watch[k] = true end end
  for _, id in ipairs(sortedIds(watch)) do add(id) end
  -- 4) stock (bags, bank, mail) that this AH has listed before, most valuable first
  local stock = {}
  for _, ck in ipairs(chars) do
    local c = db.chars[ck]
    for _, part in ipairs({ "bags", "bank", "mail" }) do
      if type(c[part]) == "table" then
        for k, q in pairs(c[part]) do
          local id = tonumber(k)
          if id and type(q) == "number" then stock[id] = (stock[id] or 0) + q end
        end
      end
    end
  end
  local list = {}
  for id, q in pairs(stock) do
    if not seen[id] and M.GetSeries and M.GetSeries(tostring(id)) then
      local v = (M.ItemValue and M.ItemValue(id)) or 0
      list[#list + 1] = { id = id, v = v * q }
    end
  end
  table.sort(list, function(a, b) if a.v ~= b.v then return a.v > b.v end return a.id < b.id end)
  for _, e in ipairs(list) do add(e.id) end
  return out
end

local function itemKey(id)
  if AH.MakeItemKey then
    local ok, k = pcall(AH.MakeItemKey, id)
    if ok and type(k) == "table" then return k end
  end
  return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
end

local function priceSort()
  local E = Enum and Enum.AuctionHouseSortOrder
  return { { sortOrder = (E and E.Price) or 0, reverseSort = false } }
end

local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end return n end

-- progress 0..1 of the running quick scan (browse batches + follow-ups)
local function quickProgress(q)
  local total = q.total + q.followN
  if total <= 0 then return 1 end
  return math.min(1, (q.doneN) / total)
end

local function quickLabel(q)
  return string.format("Your items %d/%d", count(q.updated), #q.keys)
end

-- Store what the quick scan found as today's rows (Data.lua M.CommitQuick: the
-- chart gets the point, the other items count as "not scanned"). The prices are
-- the ones Live.lua took from the answers since the quick scan started.
local function quickCommit(q)
  if q.committed then return q.stored or 0 end
  q.committed = true
  local acc, n = {}, 0
  for id in pairs(q.updated) do
    local e = M.LivePrice and M.LivePrice(id)
    if e and e.p and e.ts and e.ts >= q.t0 then
      acc[id] = { low = e.p, qty = e.q or 0 }
      n = n + 1
    end
  end
  if n > 0 and M.CommitQuick then n = M.CommitQuick(acc) or n end
  q.stored = n
  M._quickLast = { updated = n, listed = count(q.listed), asked = #q.keys }
  return n
end

-- end the running quick scan; keep = store what it found so far
local function quickStop(keep)
  local q = quick
  quick = nil
  if q and keep then return quickCommit(q) end
  return 0
end

local quickNext

local function quickDone()
  local q = quick
  if not q then return end
  quick = nil
  local n = quickCommit(q)
  local gone = #q.keys - count(q.listed)
  local rest = gone > 0 and string.format(" (%d not listed right now)", gone) or ""
  local what = string.format("Quick scan: today's prices for %d of your items stored%s", n, rest)
  if q.standalone then
    M.scanning = false
    if M.ScanUIState then M.ScanUIState(false) end
    local left = M.ScanCooldown()
    M.Print(what .. "." .. (left > 0 and string.format(" Full scan possible again in %d min.", math.ceil(left / 60)) or ""))
  else
    M.Print(what .. " - still waiting for the full snapshot.")
  end
end

local function quickSend()
  local q = quick
  if not q or not q.job then return end
  if not M.AHOpen then quickStop(true); return end
  -- the AH queues its own queries; a request sent while it is busy is lost
  if AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady() and q.readyWait < 20 then
    q.readyWait = q.readyWait + 1
    C_Timer.After(0.5, function() if quick == q then quickSend() end end)
    return
  end
  q.readyWait = 0
  local job = q.job
  job.tries = (job.tries or 0) + 1
  job.more = 0
  local token = {}
  job.token = token
  q.own = true
  if job.kind == "browse" then
    local keys = {}
    for i, id in ipairs(job.ids) do keys[i] = itemKey(id) end
    pcall(AH.SearchForItemKeys, keys, priceSort())
  else
    pcall(AH.SendSearchQuery, itemKey(job.id), priceSort(), false)
  end
  q.own = false
  C_Timer.After(QUICK_WAIT, function()
    if quick ~= q or q.job ~= job or job.token ~= token then return end
    -- three unanswered requests in a row: the AH is not answering searches now
    q.fails = q.fails + 1
    if q.fails >= 3 then
      local n = quickStop(true)
      if q.standalone then
        M.scanning = false
        if M.ScanUIState then M.ScanUIState(false) end
      end
      M.Print("Quick scan: the auction house is not answering searches right now"
        .. (n > 0 and string.format(" (%d items stored).", n) or "."))
      return
    end
    if job.kind == "browse" and #job.ids > 10 and job.tries < 2 then
      -- no answer: maybe too many keys for one request - split and go on
      local half = math.floor(#job.ids / 2)
      local a, b = {}, {}
      for i, id in ipairs(job.ids) do if i <= half then a[#a + 1] = id else b[#b + 1] = id end end
      table.insert(q.jobs, 1, { kind = "browse", ids = b })
      table.insert(q.jobs, 1, { kind = "browse", ids = a })
      q.total = q.total + 1   -- one batch became two
    elseif job.tries < 2 then
      quickSend()
      return
    else
      q.doneN = q.doneN + 1
    end
    q.job = nil
    quickNext()
  end)
end

quickNext = function()
  local q = quick
  if not q then return end
  if not M.AHOpen then quickStop(true); return end
  local job = table.remove(q.jobs, 1)
  if not job then quickDone(); return end
  q.job = job
  quickSend()
end

-- a job's answer is in: book it and move on
local function quickAdvance(q)
  q.fails = 0
  q.doneN = q.doneN + 1
  q.job = nil
  C_Timer.After(0.1, function() if quick == q then quickNext() end end)
end

local function onQuickBrowse()
  local q = quick
  local job = q and q.job
  if not (job and job.kind == "browse") then return end
  if AH.HasFullBrowseResults and AH.RequestMoreBrowseResults and not AH.HasFullBrowseResults() and job.more < 5 then
    job.more = job.more + 1
    q.own = true; pcall(AH.RequestMoreBrowseResults); q.own = false
    return
  end
  local ok, res = pcall(AH.GetBrowseResults)
  if not ok or type(res) ~= "table" then return end
  local mine, back, foreign = {}, {}, false
  for _, id in ipairs(job.ids) do mine[id] = true end
  for _, r in ipairs(res) do
    local id = type(r) == "table" and r.itemKey and r.itemKey.itemID
    if id then
      if mine[id] then back[id] = true else foreign = true end
    end
  end
  -- results of an older request (a resend after a drop): keep waiting for ours
  if foreign and next(back) == nil then return end
  local unit = M.BrowseIsUnit
  for id in pairs(back) do
    q.listed[id] = true
    if not unit or unit(id) then
      q.updated[id] = true
    elseif q.followN < QUICK_FOLLOW then
      -- browse shows a stack price here: the item list has the unit price
      q.followN = q.followN + 1
      q.jobs[#q.jobs + 1] = { kind = "item", id = id }
    end
  end
  quickAdvance(q)
end

local function onQuickItem(event, arg1)
  local q = quick
  local job = q and q.job
  if not (job and job.kind == "item") then return end
  if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    if arg1 ~= job.id then return end
    q.updated[job.id] = true   -- Live.lua read the cheapest unit price
    quickAdvance(q)
    return
  end
  if type(arg1) ~= "table" or arg1.itemID ~= job.id then return end
  local okF, full = true, true
  if AH.HasFullItemSearchResults then okF, full = pcall(AH.HasFullItemSearchResults, arg1) end
  if okF and not full and AH.RequestMoreItemSearchResults and job.more < 3 then
    job.more = job.more + 1
    q.own = true; pcall(AH.RequestMoreItemSearchResults, arg1); q.own = false
    return
  end
  if okF and full then
    -- Live.lua only listens to UPDATED: a list completed by ADDED is read here
    if event == "ITEM_SEARCH_RESULTS_ADDED" and M._live and M._live.item then M._live.item(arg1) end
    q.updated[job.id] = true
  end
  quickAdvance(q)
end

-- Start a quick scan. standalone = on its own (full scan on cooldown), else it
-- runs beside a pending full snapshot. Returns true when it started.
function M.QuickItemScan(standalone)
  if quick or not M.AHOpen or not quickAvailable() then return false end
  local keys = M.QuickItemKeys()
  if #keys == 0 then return false end
  local q = { keys = keys, jobs = {}, updated = {}, listed = {}, readyWait = 0, fails = 0, t0 = time(),
              total = 0, doneN = 0, followN = 0, standalone = standalone and true or false }
  for i = 1, #keys, QUICK_BATCH do
    local ids = {}
    for j = i, math.min(i + QUICK_BATCH - 1, #keys) do ids[#ids + 1] = keys[j] end
    q.jobs[#q.jobs + 1] = { kind = "browse", ids = ids }
    q.total = q.total + 1
  end
  quick = q
  if standalone then
    M.scanning = true
    if M.ScanUIState then M.ScanUIState(true) end
    if M.SetScanProgress then M.SetScanProgress(0, quickLabel(q)) end
    -- standalone: the bar follows the quick scan itself
    local function step()
      if quick ~= q then return end
      if M.SetScanProgress then M.SetScanProgress(quickProgress(q), quickLabel(q)) end
      C_Timer.After(0.5, step)
    end
    C_Timer.After(0.5, step)
  end
  quickNext()
  return true
end

-- your own search in the AH window would mix with the quick scan's answers:
-- the quick scan steps aside (prices from your search count all the same)
local function onForeignQuery()
  local q = quick
  if not q or q.own then return end
  local n = quickStop(true)
  if q.standalone then
    M.scanning = false
    if M.ScanUIState then M.ScanUIState(false) end
  end
  M.Print("Quick scan stopped - you searched the auction house yourself"
    .. (n > 0 and string.format(" (%d items stored).", n) or "."))
end
if hooksecurefunc and AH then
  for _, fn in ipairs({ "SendBrowseQuery", "SearchForFavorites", "SendSearchQuery", "SearchForItemKeys" }) do
    if type(AH[fn]) == "function" then pcall(hooksecurefunc, AH, fn, onForeignQuery) end
  end
end

local function abort(msg)
  stopDriver()
  if ticker then ticker:Cancel(); ticker = nil end
  M.scanning = false
  scanPending = false
  quickStop(true)   -- keeps what a quick scan found so far
  if M.ScanUIState then M.ScanUIState(false) end
  if msg then M.Print(msg) end
end
M.AbortScan = abort

local function lastReplicate()
  return (M.db and M.db.config and M.db.config.lastReplicate) or 0
end

-- seconds until the next snapshot may be requested (0 = now)
function M.ScanCooldown()
  local left = REPLICATE_CD - (time() - lastReplicate())
  return left > 0 and left or 0
end

local function processSnapshot()
  local num = AH.GetNumReplicateItems() or 0
  if num == 0 then abort("Scan: the server sent an empty snapshot - please try again in a moment. The archive keeps your last good scan."); return end
  local acc, i = {}, 0
  driver = driver or CreateFrame("Frame")
  driver:SetScript("OnUpdate", function(self)
    if not M.AHOpen then abort("Scan aborted (auction house closed)."); return end
    local stop = i + CHUNK; if stop > num then stop = num end
    while i < stop do
      -- replicate rows are 0-based
      local name, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = AH.GetReplicateItemInfo(i)
      i = i + 1
      count = count or 1
      if itemID and count > 0 then
        local a = acc[itemID]
        if not a then a = { qty = 0 }; acc[itemID] = a end
        a.name = a.name or (name ~= "" and name or nil)   -- remembered account-wide (Charts search; uncached items report "")
        a.qty = a.qty + count
        if buyout and buyout > 0 then        -- buyout is the whole row (stack) price
          local unit = math.floor(buyout / count)
          if not a.low or unit < a.low then a.low = unit end
          -- supply ladder: units + auctions per unit price (Data.lua keeps the cheapest)
          local lv = a.lv; if not lv then lv = {}; a.lv = lv end
          local st = lv[unit]; if not st then st = { 0, 0 }; lv[unit] = st end
          st[1] = st[1] + count; st[2] = st[2] + 1
        end
      end
    end
    if M.SetScanProgress then M.SetScanProgress(i / num, string.format("Scanning %d%%", math.floor(i / num * 100))) end
    if i >= num then
      self:SetScript("OnUpdate", nil)
      M.scanning = false
      if M.ScanUIState then M.ScanUIState(false) end
      if next(acc) == nil then
        -- rows arrived but none were readable: never commit (an empty commit
        -- would wipe the offer-book depth) - say what happened instead
        M.Print(string.format("Scan: %d rows received but none were readable - please try again later. The archive keeps your last good scan.", num))
        return
      end
      M.CommitScan(acc)
    end
  end)
end

-- Asking for a snapshot. The server answers within seconds to minutes (it is
-- slowest in the evening) and now and then loses a request. So: wait until
-- the AH's throttled message system is ready, ask, ask again at RETRY_AT if
-- nothing came, keep waiting up to TIMEOUT - and a snapshot that still
-- arrives after that (within LATE, AH open) is stored all the same.
local RETRY_AT = { 45, 120 }   -- seconds after the click
local MAX_TRIES = #RETRY_AT + 1
local SLOW_NOTE = 90           -- one chat note when the server takes this long
local LATE = 600
local tries, readyWait, started, noted, waitingReady = 0, 0, 0, false, false
local lateUntil, quickTried, quickRan

local function send()
  if not (scanPending and M.AHOpen) or waitingReady or tries >= MAX_TRIES then return end
  -- the AH queues its own queries; a request sent while it is busy is lost
  if AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady() and readyWait < 20 then
    readyWait = readyWait + 1
    waitingReady = true
    C_Timer.After(0.5, function() waitingReady = false; send() end)
    return
  end
  tries = tries + 1
  AH.ReplicateItems()
end

local function tick()
  if not scanPending then
    if ticker then ticker:Cancel(); ticker = nil end
    return
  end
  local t = GetTime() - started
  if M.SetScanProgress then
    local clock = string.format("%d:%02d", math.floor(t / 60), math.floor(t % 60))
    if quick and not quick.standalone then
      M.SetScanProgress(quickProgress(quick), quickLabel(quick) .. "  \194\183  " .. clock)
    elseif quickRan then
      M.SetScanProgress(0, "Waiting for the full scan  " .. clock)
    else
      M.SetScanProgress(0, "Waiting for the server  " .. clock)
    end
  end
  if not noted and t >= SLOW_NOTE then
    noted = true
    M.Print("Scan: the server is slow to send its snapshot right now (busy hours) - Midas keeps waiting up to 5 minutes while the AH is open.")
  end
  local nextAt = RETRY_AT[tries]
  if nextAt and t >= nextAt then send() end
  -- no snapshot yet: fetch the items that matter to you in the meantime
  if not quickTried and t >= QUICK_AFTER then
    quickTried = true
    quickRan = M.QuickItemScan(false)
  end
  if t >= TIMEOUT then
    lateUntil = time() + LATE
    local last = M._quickLast
    if quickRan and last and last.updated > 0 then
      abort("Scan: no full snapshot after 5 minutes (busy hours). The quick scan updated " .. last.updated .. " of your items - if the snapshot still comes while the AH is open, Midas stores it.")
    else
      abort("Scan: no snapshot after 5 minutes (asked " .. tries .. " times). The server sends one full snapshot per ~15 minutes per account and is slow at busy hours - if it still comes while the AH is open, Midas stores it. The archive keeps your last good scan.")
    end
  end
end

-- Trigger a full snapshot. Needs the AH open and the replicate cooldown free.
function M.Scan(verbose)
  if M.scanning then if verbose then M.Print("Scan already running.") end return end
  if not M.AHOpen then if verbose then M.Print("Open the auction house first, then scan.") end return end
  local left = M.ScanCooldown()
  if left > 0 then
    if verbose then
      if M.QuickItemScan(true) then
        M.Print(string.format("Full scan on cooldown (%d min) - quick scan of your items instead.", math.ceil(left / 60)))
      else
        M.Print(string.format("Full scan on cooldown - try again in %d min.", math.ceil(left / 60)))
      end
    end
    return
  end
  M.scanning = true
  scanPending = true
  tries, readyWait, noted, waitingReady, lateUntil = 0, 0, false, false, nil
  quickTried, quickRan, M._quickLast = false, false, nil
  started = GetTime()
  -- the cooldown stamp is set when the server actually ANSWERS (REPLICATE
  -- event below): a failed request must not lock the button for 15 minutes
  if M.ScanUIState then M.ScanUIState(true) end
  if M.SetScanProgress then M.SetScanProgress(0, "Querying AH...") end
  if verbose then M.Print("Starting full scan...") end
  if ticker then ticker:Cancel() end
  ticker = C_Timer.NewTicker(1, tick)
  send()
end
M.Ingest = M.Scan   -- backwards-compatible alias for older call sites

-- AH events ------------------------------------------------------------------
local ev = CreateFrame("Frame")
M.SafeRegister(ev, "AUCTION_HOUSE_SHOW")
M.SafeRegister(ev, "AUCTION_HOUSE_CLOSED")
M.SafeRegister(ev, "REPLICATE_ITEM_LIST_UPDATE")
-- a request the AH could not send: ask again in a second (counts as a try)
M.SafeRegister(ev, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
-- answers to the quick scan
M.SafeRegister(ev, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
M.SafeRegister(ev, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
M.SafeRegister(ev, "ITEM_SEARCH_RESULTS_UPDATED")
M.SafeRegister(ev, "ITEM_SEARCH_RESULTS_ADDED")
M.SafeRegister(ev, "COMMODITY_SEARCH_RESULTS_UPDATED")
ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    if quick then onQuickBrowse() end
    return
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_ADDED"
      or event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    if quick then onQuickItem(event, arg1) end
    return
  end
  if event == "AUCTION_HOUSE_SHOW" then
    M.AHOpen = true
    if M.ShowScanButton then M.ShowScanButton() end
    if M.db and M.db.config and M.db.config.autoScan == true then
      C_Timer.After(2, function() M.Scan(false) end)
    end
  elseif event == "AUCTION_HOUSE_CLOSED" then
    M.AHOpen = false
    if M.HideScanButton then M.HideScanButton() end
    lateUntil = nil   -- the snapshot rows cannot be read once the AH is closed
    if M.scanning or scanPending then abort("Scan aborted (auction house closed).") end
    quickStop(true)
  elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    if scanPending then C_Timer.After(1, send) end
    -- the dropped one may have been the quick scan's: send it once more
    local q = quick
    local job = q and q.job
    if job and (job.tries or 0) < 3 then
      C_Timer.After(1, function() if quick == q and q.job == job then quickSend() end end)
    end
  elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
    -- ours (or a late answer to ours after Midas stopped waiting); snapshots
    -- other addons asked for are left alone
    local late = not scanPending and lateUntil and time() <= lateUntil and M.AHOpen and not M.scanning
    if scanPending or late then
      scanPending, lateUntil = false, nil
      if ticker then ticker:Cancel(); ticker = nil end
      quickStop()   -- the full snapshot covers every item
      if late then
        M.scanning = true
        if M.ScanUIState then M.ScanUIState(true) end
        M.Print("Scan: the server's snapshot arrived late - storing it now.")
      end
      -- the server answered: NOW the ~15-min replicate cooldown is real
      if M.db and M.db.config then M.db.config.lastReplicate = time() end
      processSnapshot()
    end
  end
end)
