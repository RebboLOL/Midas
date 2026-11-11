-- Midas – Live: current prices from what the auction house shows right now
-- A full scan is a snapshot; between two scans (one per ~15 min at best) the
-- market moves. Every price the AH itself shows after that becomes the item's
-- current price (Data.lua M.ObserveLive), so a search right after a scan and
-- the Midas numbers agree:
--   * Auctionator: every price it records (its searches, Shopping lists, full
--     scans, the Selling tab) - hooked on Auctionator.Database:SetPrice
--   * Classic AH: a browse search whose results fit on one page holds EVERY
--     auction of each item in it (all filters are item properties)
--   * modern AH (WoW Forever): browse results (cheapest unit price per item)
--     and the commodity / item lists opened from them
-- Weapons and armor are left out: a search for "X of the Bear" sees one random
-- suffix only, while Midas prices the base item over all of them.
local ADDON, M = ...

local function isGear(id)
  local instant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
  local classID = instant and select(6, instant(id))
  return classID == 2 or classID == 4
end

local function observe(id, unit, qty)
  if id and not isGear(id) then M.ObserveLive(id, unit, qty) end
end

-- ===== Auctionator ===========================================================
-- Auctionator.Database is created once its saved prices are loaded; the hook
-- sits on that instance (every write goes through its SetPrice). Keys other
-- than a plain item ID ("g:" gear, "p:" pets) are not ours.
local hookedDb
local function hookAuctionator()
  local db = type(Auctionator) == "table" and Auctionator.Database
  if type(db) ~= "table" or type(db.SetPrice) ~= "function" then return false end
  if db == hookedDb then return true end
  hooksecurefunc(db, "SetPrice", function(_, dbKey, price, available)
    if type(dbKey) ~= "string" and type(dbKey) ~= "number" then return end
    local id = tonumber(dbKey)
    if id and type(price) == "number" and price > 0 then
      observe(id, price, type(available) == "number" and available or nil)
    end
  end)
  hookedDb = db
  return true
end

local function tryHook(tries)
  if hookAuctionator() or tries >= 12 then return end
  C_Timer.After(5, function() tryHook(tries + 1) end)
end

-- ===== Classic AH: one-page browse results =====================================
local PAGE = NUM_AUCTION_ITEMS_PER_PAGE or 50

local function onClassicList()
  if M.scanning or not GetNumAuctionItems then return end
  local numBatch, total = GetNumAuctionItems("list")
  if not (numBatch and total and total > 0 and numBatch == total and total <= PAGE) then return end
  local acc = {}
  for i = 1, numBatch do
    local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = GetAuctionItemInfo("list", i)
    if not itemID then
      local link = GetAuctionItemLink and GetAuctionItemLink("list", i)
      itemID = link and tonumber(link:match("item:(%d+)"))
    end
    count = count or 1
    if itemID and count > 0 then
      local a = acc[itemID]
      if not a then a = { q = 0 }; acc[itemID] = a end
      a.q = a.q + count
      if buyout and buyout > 0 then
        local unit = math.floor(buyout / count)
        if not a.p or unit < a.p then a.p = unit end
      end
    end
  end
  for id, a in pairs(acc) do
    if a.p then observe(id, a.p, a.q) end
  end
end

-- ===== modern AH ===============================================================
local AH = C_AuctionHouse

-- browse minPrice is per unit for commodities and for items that never stack
local function browseIsUnit(id)
  if not (AH and AH.GetItemCommodityStatus) then return false end
  local ok, st = pcall(AH.GetItemCommodityStatus, id)
  if not ok or not st then return false end
  local E = Enum and Enum.ItemCommodityStatus
  if st == ((E and E.Commodity) or 2) then return true end
  if st == ((E and E.Item) or 1) then
    local stack = M.GetItemInfo and select(8, M.GetItemInfo(id))
    return stack == 1
  end
  return false
end
M.BrowseIsUnit = browseIsUnit   -- the quick scan (ScannerModern) asks for item lists otherwise

local function onBrowse()
  if not (AH and AH.GetBrowseResults) then return end
  local ok, res = pcall(AH.GetBrowseResults)
  if not ok or type(res) ~= "table" then return end
  local agg = {}
  for _, r in ipairs(res) do
    local k = type(r) == "table" and r.itemKey
    local id = k and k.itemID
    if id and (k.battlePetSpeciesID or 0) == 0 and type(r.minPrice) == "number" and r.minPrice > 0 then
      local a = agg[id]
      if not a then a = { p = r.minPrice, q = 0 }; agg[id] = a end
      if r.minPrice < a.p then a.p = r.minPrice end
      a.q = a.q + (tonumber(r.totalQuantity) or 0)
    end
  end
  for id, a in pairs(agg) do
    if browseIsUnit(id) then observe(id, a.p, a.q > 0 and a.q or nil) end
  end
end

-- commodity lists come cheapest first
local function onCommodity(id)
  if type(id) ~= "number" or not (AH and AH.GetCommoditySearchResultInfo) then return end
  local ok, r = pcall(AH.GetCommoditySearchResultInfo, id, 1)
  if not ok or type(r) ~= "table" or type(r.unitPrice) ~= "number" or r.unitPrice <= 0 then return end
  local qty
  if AH.HasFullCommoditySearchResults and AH.GetCommoditySearchResultsQuantity then
    local okF, full = pcall(AH.HasFullCommoditySearchResults, id)
    if okF and full then
      local okQ, q = pcall(AH.GetCommoditySearchResultsQuantity, id)
      if okQ and type(q) == "number" then qty = q end
    end
  end
  observe(id, r.unitPrice, qty)
end

-- item lists: only complete ones, only the plain item (no random suffix)
local function onItemSearch(key)
  if type(key) ~= "table" or type(key.itemID) ~= "number" then return end
  if (key.itemSuffix or 0) ~= 0 or (key.battlePetSpeciesID or 0) ~= 0 then return end
  if not (AH and AH.HasFullItemSearchResults and AH.GetNumItemSearchResults and AH.GetItemSearchResultInfo) then return end
  local okF, full = pcall(AH.HasFullItemSearchResults, key)
  if not (okF and full) then return end
  local okN, n = pcall(AH.GetNumItemSearchResults, key)
  if not (okN and type(n) == "number") then return end
  local best, qty = nil, 0
  for i = 1, n do
    local ok, r = pcall(AH.GetItemSearchResultInfo, key, i)
    if ok and type(r) == "table" and type(r.buyoutAmount) == "number" and r.buyoutAmount > 0 then
      local cnt = (type(r.quantity) == "number" and r.quantity > 0) and r.quantity or 1
      local unit = math.floor(r.buyoutAmount / cnt)
      if not best or unit < best then best = unit end
      qty = qty + cnt
    end
  end
  if best then observe(key.itemID, best, qty) end
end

-- ===== events ==================================================================
local ev = CreateFrame("Frame")
M.SafeRegister(ev, "PLAYER_LOGIN")
M.SafeRegister(ev, "AUCTION_HOUSE_SHOW")
if M.MODERN_AH then
  M.SafeRegister(ev, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  M.SafeRegister(ev, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
  M.SafeRegister(ev, "COMMODITY_SEARCH_RESULTS_UPDATED")
  M.SafeRegister(ev, "ITEM_SEARCH_RESULTS_UPDATED")
else
  M.SafeRegister(ev, "AUCTION_ITEM_LIST_UPDATE")
end
ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "PLAYER_LOGIN" then
    tryHook(0)
  elseif event == "AUCTION_HOUSE_SHOW" then
    hookAuctionator()   -- late-loaded Auctionator / a recreated database
  elseif not M.db then
    return
  elseif event == "AUCTION_ITEM_LIST_UPDATE" then
    onClassicList()
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    onBrowse()
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    onCommodity(arg1)
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
    onItemSearch(arg1)
  end
end)

-- entry points for offline tests
M._live = { hook = hookAuctionator, classic = onClassicList, browse = onBrowse,
            commodity = onCommodity, item = onItemSearch }
