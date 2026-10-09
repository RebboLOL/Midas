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

function M.VendorCount()
  local c = 0
  if M.db and M.db.vendor then for _ in pairs(M.db.vendor) do c = c + 1 end end
  return c
end

-- Record unlimited, gold-only items from the currently open merchant.
local function scanMerchant()
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
        if not v[id] or unit < v[id] then v[id] = unit end
        added = added + 1
      end
    end
  end
  if added > 0 then M.DirtyAnalysis() end
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
    M.DirtyAnalysis()
    if M.frame and M.frame:IsShown() and M.RefreshUI then M.RefreshUI() end
  end
end

local ev = CreateFrame("Frame")
M.SafeRegister(ev, "MERCHANT_SHOW")
M.SafeRegister(ev, "MERCHANT_UPDATE")
ev:SetScript("OnEvent", function() C_Timer.After(0.1, scanMerchant) end)
