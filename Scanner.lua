-- Midas – Scanner: self-contained full auction-house scan (Classic "GetAll")
-- No Auctionator required: we query the whole AH ourselves and store the result.
local ADDON, M = ...
if M.MODERN_AH then return end   -- modern client: ScannerModern.lua

local CHUNK = 3000           -- auctions processed per frame (avoids freezing)
local scanPending = false
local driver, watchdog

local function stopDriver()
  if driver then driver:SetScript("OnUpdate", nil) end
end

local function abort(msg)
  stopDriver()
  if watchdog then watchdog:Cancel(); watchdog = nil end
  M.scanning = false
  scanPending = false
  if M.ScanUIState then M.ScanUIState(false) end
  if msg then M.Print(msg) end
end
M.AbortScan = abort

-- Read the delivered "list" results in chunks, then commit ---------------------
local function processList()
  local num = GetNumAuctionItems("list") or 0
  if num == 0 then abort("Scan: no auctions received - please try again."); return end
  local acc, i = {}, 0
  driver = driver or CreateFrame("Frame")
  driver:SetScript("OnUpdate", function(self)
    if not M.AHOpen then abort("Scan aborted (auction house closed)."); return end
    local stop = i + CHUNK; if stop > num then stop = num end
    while i < stop do
      i = i + 1
      local name, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = GetAuctionItemInfo("list", i)
      if not itemID then
        local link = GetAuctionItemLink("list", i)
        itemID = link and tonumber(link:match("item:(%d+)"))
      end
      count = count or 1
      if itemID and count > 0 then
        local a = acc[itemID]
        if not a then a = { qty = 0 }; acc[itemID] = a end
        a.name = a.name or (name ~= "" and name or nil)   -- remembered account-wide (Charts search; uncached items report "")
        a.qty = a.qty + count
        if buyout and buyout > 0 then
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
      M.CommitScan(acc)
    end
  end)
end

-- Trigger a full scan (GetAll). Needs the AH open and the mass query off cooldown.
function M.Scan(verbose)
  if M.scanning then if verbose then M.Print("Scan already running.") end return end
  if not M.AHOpen then if verbose then M.Print("Open the auction house first, then scan.") end return end
  local canQuery, canMass = CanSendAuctionQuery()
  if (not canQuery) or (canMass == false) then
    if verbose then M.Print("Full scan on cooldown - try again in a few minutes.") end
    return
  end
  M.scanning = true
  scanPending = true
  if M.ScanUIState then M.ScanUIState(true) end
  if M.SetScanProgress then M.SetScanProgress(0, "Querying AH...") end
  if verbose then M.Print("Starting full scan...") end
  QueryAuctionItems("", nil, nil, 0, nil, nil, true, false, nil)
  if watchdog then watchdog:Cancel() end
  watchdog = C_Timer.NewTimer(20, function()
    if scanPending then abort("Scan timed out - try again in a moment.") end
  end)
end
M.Ingest = M.Scan   -- backwards-compatible alias for older call sites

-- AH events ------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
ev:SetScript("OnEvent", function(_, event)
  if event == "AUCTION_HOUSE_SHOW" then
    M.AHOpen = true
    if M.ShowScanButton then M.ShowScanButton() end
    -- No auto-scan: start it with the "Midas Scan" button (or /midas scan).
    -- Re-enable automatic scanning with /midas auto.
    if M.db and M.db.config and M.db.config.autoScan == true then
      C_Timer.After(2, function() M.Scan(false) end)
    end
  elseif event == "AUCTION_HOUSE_CLOSED" then
    M.AHOpen = false
    if M.HideScanButton then M.HideScanButton() end
    if M.scanning or scanPending then abort("Scan aborted (auction house closed).") end
  elseif event == "AUCTION_ITEM_LIST_UPDATE" then
    if scanPending then
      -- a GetAll result delivers everything in one batch: numBatch == total.
      -- Ignore stray partial updates from the default AH browse.
      local numBatch, total = GetNumAuctionItems("list")
      if numBatch and total and total > 0 and numBatch == total then
        scanPending = false
        if watchdog then watchdog:Cancel(); watchdog = nil end
        processList()
      end
    end
  end
end)
