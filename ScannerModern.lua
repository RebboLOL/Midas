-- Midas – ScannerModern: full auction-house scan on the modern client (WoW Forever)
-- C_AuctionHouse.ReplicateItems() delivers a snapshot of every auction (commodities
-- included) -> REPLICATE_ITEM_LIST_UPDATE -> rows 0..n-1 via GetReplicateItemInfo.
-- Same contract as Scanner.lua: acc[itemID] = { low = min unit buyout, qty = sum,
-- lv = { [unit] = { units, auctions } } }
-- -> M.CommitScan(acc). Only active when Compat detected the modern AH.
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

local function abort(msg)
  stopDriver()
  if ticker then ticker:Cancel(); ticker = nil end
  M.scanning = false
  scanPending = false
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
local lateUntil

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
    M.SetScanProgress(0, string.format("Waiting for the server  %d:%02d", math.floor(t / 60), math.floor(t % 60)))
  end
  if not noted and t >= SLOW_NOTE then
    noted = true
    M.Print("Scan: the server is slow to send its snapshot right now (busy hours) - Midas keeps waiting up to 5 minutes while the AH is open.")
  end
  local nextAt = RETRY_AT[tries]
  if nextAt and t >= nextAt then send() end
  if t >= TIMEOUT then
    lateUntil = time() + LATE
    abort("Scan: no snapshot after 5 minutes (asked " .. tries .. " times). The server sends one full snapshot per ~15 minutes per account and is slow at busy hours - if it still comes while the AH is open, Midas stores it. The archive keeps your last good scan.")
  end
end

-- Trigger a full snapshot. Needs the AH open and the replicate cooldown free.
function M.Scan(verbose)
  if M.scanning then if verbose then M.Print("Scan already running.") end return end
  if not M.AHOpen then if verbose then M.Print("Open the auction house first, then scan.") end return end
  local left = M.ScanCooldown()
  if left > 0 then
    if verbose then M.Print(string.format("Full scan on cooldown - try again in %d min.", math.ceil(left / 60))) end
    return
  end
  M.scanning = true
  scanPending = true
  tries, readyWait, noted, waitingReady, lateUntil = 0, 0, false, false, nil
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
ev:SetScript("OnEvent", function(_, event)
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
  elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    if scanPending then C_Timer.After(1, send) end
  elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
    -- ours (or a late answer to ours after Midas stopped waiting); snapshots
    -- other addons asked for are left alone
    local late = not scanPending and lateUntil and time() <= lateUntil and M.AHOpen and not M.scanning
    if scanPending or late then
      scanPending, lateUntil = false, nil
      if ticker then ticker:Cancel(); ticker = nil end
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
