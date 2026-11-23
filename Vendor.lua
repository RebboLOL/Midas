-- Midas – Vendor: learn vendor-sold items so they stay OUT of flip picks.
-- An item you can buy from an NPC for a fixed price (unlimited supply) is never a
-- real flip - nobody buys it on the AH. We learn these two ways:
--   1) self-contained: scan every merchant window we open (unlimited, gold-only items)
--   2) one-off bootstrap: import Auctionator's vendor cache if that addon is present.
-- Result lives in MidasDB.vendor = { [itemID] = vendorUnitPriceCopper } (account-wide).
local ADDON, M = ...

local function ensure()
  if not M.db then return nil end
  M.db.vendor = M.db.vendor or {}
  return M.db.vendor
end

function M.IsVendorItem(id)
  return (M.db and M.db.vendor and M.db.vendor[id]) ~= nil
end

function M.VendorPrice(id)
  return M.db and M.db.vendor and M.db.vendor[id] or nil
end

-- A merchant only sets an item's price while the AH asks more than he does
-- (thread, vials, throwing knives). Where the AH trades below him, the AH is
-- the market and he is just a ceiling: the WoW Forever Black Market sells
-- herbs, Black Lotus and Arcane Crystals for 50g without a limit, far above
-- their auction price. No AH data: the merchant price stands.
function M.VendorPins(id)
  id = tonumber(id)
  local v = id and M.VendorPrice(id)
  if not v or v <= 0 then return false end
  local s = M.GetSeries and M.GetSeries(tostring(id))
  local m = s and M.Metrics and M.Metrics(s, tostring(id))
  local fair = m and m.fair
  if not fair or fair <= 0 then return true end
  return fair > v
end

-- counted once and kept until this file writes to the table again (the craft
-- cache asks on every lookup)
local vendorN, vendorT
function M.VendorCount()
  local t = M.db and M.db.vendor
  if not t then return 0 end
  if vendorN and vendorT == t then return vendorN end
  local c = 0
  for _ in pairs(t) do c = c + 1 end
  vendorN, vendorT = c, t
  return c
end

-- Record unlimited, gold-only items from the currently open merchant.
local scanPending = false
local function scanMerchant()
  scanPending = false
  local v = ensure(); if not v then return end
  local n = GetMerchantNumItems() or 0
  local added = 0
  for i = 1, n do
    local name, _, price, quantity, numAvailable = M.GetMerchantItemInfo(i)
    local extended = (GetMerchantItemCostInfo and GetMerchantItemCostInfo(i) or 0) > 0
    -- numAvailable == -1 => unlimited stock; skip limited stock and token/honor costs
    if name and price and price > 0 and numAvailable == -1 and not extended then
      local link = GetMerchantItemLink(i)
      local id = link and tonumber(link:match("item:(%d+)"))
      if id then
        local unit = math.floor(price / (quantity or 1))
        -- only a new item or a lower price is a change: a merchant seen before
        -- must not refresh the whole analysis again
        if not v[id] or unit < v[id] then v[id] = unit; added = added + 1 end
      end
    end
  end
  if added > 0 then
    vendorN = nil
    M.DirtyAnalysis(true)   -- vendor prices never move the newest scan day
  end
end

-- Bootstrap from Auctionator's vendor price cache (keys are string item IDs).
function M.SeedVendor()
  local v = ensure(); if not v then return end
  local src = AUCTIONATOR_VENDOR_PRICE_CACHE
  if type(src) ~= "table" then return end
  local n = 0
  for k, price in pairs(src) do
    local id
    if type(k) == "number" then id = k
    elseif type(k) == "string" then id = tonumber(k) or tonumber(k:match("item:(%d+)")) end
    if id and type(price) == "number" and not v[id] then
      v[id] = price; n = n + 1
    end
  end
  if n > 0 then
    vendorN = nil
    M.DirtyAnalysis(true)
    if M.frame and M.frame:IsShown() and M.RefreshUI then M.RefreshUI() end
  end
end

local ev = CreateFrame("Frame")
M.SafeRegister(ev, "MERCHANT_SHOW")
M.SafeRegister(ev, "MERCHANT_UPDATE")
-- one scan per burst of merchant events (every purchase fires MERCHANT_UPDATE)
ev:SetScript("OnEvent", function()
  if scanPending then return end
  scanPending = true
  C_Timer.After(0.1, scanMerchant)
end)
