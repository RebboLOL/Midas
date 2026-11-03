-- Midas – Compat: one code base for Classic Era (1.15) and WoW Forever (1.60,
-- modern Mainline client). Everything version-sensitive is decided HERE by
-- feature detection -- never by build numbers (Forever reports interface 16001,
-- which breaks the usual "interface >= 100000 means modern" tests).
local ADDON, M = ...

-- Modern auction house (C_AuctionHouse: ReplicateItems / OwnedAuctions) instead of
-- the Classic QueryAuctionItems(getAll) + GetAuctionItemInfo list API.
-- Some clients ship both namespaces; the legacy list API wins whenever it exists.
M.MODERN_AH = (C_AuctionHouse ~= nil and C_AuctionHouse.ReplicateItems ~= nil
  and _G.QueryAuctionItems == nil
  and not (IsUsingLegacyAuctionClient and IsUsingLegacyAuctionClient())) or false

-- Register an event only if this client knows it (unknown events throw on the
-- modern client instead of being ignored).
function M.SafeRegister(frame, event)
  return (pcall(frame.RegisterEvent, frame, event))
end

-- GetItemInfo: the global is gone on the modern client, C_Item.GetItemInfo returns
-- the identical multi-value list. Resolved per call, so load order doesn't matter.
function M.GetItemInfo(item)
  local fn = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
  if not fn or item == nil then return nil end
  return fn(item)
end

-- Item icon: the dedicated icon APIs answer even before the item is cached;
-- GetItemInfo's texture (slot 10) is the last resort.
function M.GetItemIcon(item)
  if item == nil then return nil end
  local fn = (C_Item and C_Item.GetItemIconByID) or _G.GetItemIcon
  if fn then
    local ok, tex = pcall(fn, item)
    if ok and tex then return tex end
  end
  return (select(10, M.GetItemInfo(item)))
end

-- Merchant row in the classic multi-return shape:
-- name, texture, price, stackCount, numAvailable, isPurchasable, isUsable, extendedCost
function M.GetMerchantItemInfo(index)
  if _G.GetMerchantItemInfo then return _G.GetMerchantItemInfo(index) end
  local info = C_MerchantFrame and C_MerchantFrame.GetItemInfo and C_MerchantFrame.GetItemInfo(index)
  if type(info) ~= "table" then return nil end
  return info.name, info.texture, info.price, info.stackCount, info.numAvailable,
         info.isPurchasable, info.isUsable, info.hasExtendedCost
end

-- Classic AH browse row (the list API only exists on the legacy client):
-- buyout, bid-to-place minimum, itemID, count. nil when the API is missing.
function M.AuctionRowPrice(listType, index)
  local fn = _G.GetAuctionItemInfo
  if not fn then return nil end
  local _, _, count, _, _, _, _, minBid, minInc, buyout, bidAmount, _, _, _, _, _, itemID = fn(listType, index)
  local nextBid = ((bidAmount or 0) > 0) and (bidAmount + (minInc or 0)) or (minBid or 0)
  return buyout, nextBid, itemID, count
end

-- Bank containers: classic = main bank (-1) + bank bags; modern = bank tabs from
-- Enum.BagIndex (CharacterBankTab_1..n), whatever this client defines.
function M.BankContainers()
  local list = {}
  local BI = Enum and Enum.BagIndex
  if BI and BI.CharacterBankTab_1 then
    for i = 1, 12 do
      local b = BI["CharacterBankTab_" .. i]
      if not b then break end
      list[#list + 1] = b
    end
    if BI.Bank then table.insert(list, 1, BI.Bank) end
    return list
  end
  list[1] = (BI and BI.Bank) or BANK_CONTAINER or -1
  local first = (NUM_BAG_SLOTS or 4) + 1
  local last  = (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 7)
  for b = first, last do list[#list + 1] = b end
  return list
end

-- Addon message results that will never succeed on retry for this channel type
-- (e.g. SAY/YELL addon messages are InvalidChatType on the modern client).
do
  local R = Enum and Enum.SendAddonMessageResult
  M.SEND_PERMANENT_FAIL = {}
  if R then
    for _, k in ipairs({ "InvalidPrefix", "InvalidMessage", "InvalidChatType", "NotInGroup",
                         "TargetRequired", "InvalidChannel", "NotInGuild", "TargetOffline" }) do
      if R[k] then M.SEND_PERMANENT_FAIL[R[k]] = k end
    end
  end
end

-- Addon compartment (modern client minimap drawer): same clicks as on the coin.
function Midas_OnCompartmentClick(_, button)
  if button == "RightButton" and M.GoldTimerToggle then M.GoldTimerToggle(true); return end
  if M.Toggle then M.Toggle() end
end
