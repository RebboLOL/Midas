-- Midas – Inventory: scan holdings (bags/bank/mail) & sell tips
-- Bags are read live; bank and mail only while their frame is open
-- (WoW API limitation) -> we cache them per character in MidasDB.chars.
local ADDON, M = ...

-- ===== Container API (C_Container with fallback to old globals) =============
local CT = C_Container

local function NumSlots(bag)
  if CT and CT.GetContainerNumSlots then return CT.GetContainerNumSlots(bag) or 0 end
  return (_G.GetContainerNumSlots and _G.GetContainerNumSlots(bag)) or 0
end

local function SlotItem(bag, slot)            -- -> itemID, stackCount, isBound
  if CT and CT.GetContainerItemInfo then
    local info = CT.GetContainerItemInfo(bag, slot)
    if info then return info.itemID, info.stackCount or 1, info.isBound end
    return nil
  end
  if _G.GetContainerItemInfo then
    local _, count, _, _, _, _, link, _, _, itemID = _G.GetContainerItemInfo(bag, slot)
    if not itemID and link then itemID = tonumber(link:match("item:(%d+)")) end
    return itemID, count or 1
  end
  return nil
end

-- ===== Container lists =======================================================
local BAGS = { 0, 1, 2, 3, 4 }                -- backpack + 4 bags (always readable)

local BANK = M.BankContainers()   -- Compat.lua: classic bank bags or modern bank tabs

-- Detect soulbound items so equipped/looted BoP & BoE gear stays OUT of net
-- worth: a BoE only carries market value while it is still unbound. Once it has
-- been equipped (and is now soulbound) it can no longer be sold on the AH.
-- Uses the container isBound flag when the client provides it, else the tooltip.
local scanTip
local function slotSoulbound(bag, slot, isBound)
  if isBound ~= nil then return isBound end
  if not ITEM_SOULBOUND then return false end
  if not scanTip then
    scanTip = CreateFrame("GameTooltip", "MidasScanTip", nil, "GameTooltipTemplate")
  end
  scanTip:SetOwner(UIParent, "ANCHOR_NONE")
  scanTip:ClearLines()
  if not pcall(scanTip.SetBagItem, scanTip, bag, slot) then return false end
  for i = 2, math.min(scanTip:NumLines() or 0, 6) do
    local fs = _G["MidasScanTipTextLeft" .. i]
    if fs and fs:GetText() == ITEM_SOULBOUND then return true end
  end
  return false
end

local function scanBags(list, into)
  for _, bag in ipairs(list) do
    for slot = 1, NumSlots(bag) do
      local id, qty, isBound = SlotItem(bag, slot)
      if id and not slotSoulbound(bag, slot, isBound) then
        into[id] = (into[id] or 0) + (qty or 1)
      end
    end
  end
  return into
end

local function scanMail(into)
  local n = (GetInboxNumItems and GetInboxNumItems()) or 0
  local maxAtt = ATTACHMENTS_MAX_RECEIVE or 16
  local gold = 0
  for i = 1, n do
    -- attached money (auction proceeds, COD payouts): it is real wealth
    -- sitting in the inbox and must count before it is looted
    local money = select(5, GetInboxHeaderInfo(i))
    gold = gold + (money or 0)
    for j = 1, maxAtt do
      local link = GetInboxItemLink and GetInboxItemLink(i, j)
      if link then
        local id = tonumber(link:match("item:(%d+)"))
        if id then
          local _, _, _, count = GetInboxItem(i, j)
          into[id] = (into[id] or 0) + (count or 1)
        end
      end
    end
  end
  return into, gold
end

-- ===== Per-character cache (bank/mail) ======================================
local function CharKey()
  return (M.CharKey and M.CharKey())
    or (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

local function CharCache()
  if not M.db then return nil end
  M.db.chars = M.db.chars or {}
  local k = CharKey()
  M.db.chars[k] = M.db.chars[k] or {}
  local c = M.db.chars[k]
  -- auto-revive ONLY on a LIVING login: an HC corpse can still log in as a
  -- ghost, and that must not pull it off the graveyard. A character playing
  -- alive, though, is demonstrably not dead (accidental move, or the name was
  -- reused for a new character) -- bring it back.
  if c.dead and UnitIsDeadOrGhost and not UnitIsDeadOrGhost("player") then
    c.dead, c.deadTs, c.deadWorth = nil, nil, nil
    if M.Print then M.Print((c.name or k) .. " returned from the graveyard - counting toward the total again.") end
  end
  -- which auction house this character trades on: its items are only worth what
  -- THIS realm+faction pays, so net worth counts it only in that scope
  c.scope = M.RealmKey()
  return c
end

function M.CacheBank()
  local c = CharCache(); if not c then return end
  c.bank = scanBags(BANK, {})
  c.bankTs = time()
  if M.RequestUIRefresh then M.RequestUIRefresh() end   -- net worth reads this
end

function M.CacheMail()
  local c = CharCache(); if not c then return end
  c.mail, c.mailGold = scanMail({})
  c.mailTs = time()
  -- the inbox is the ground truth now: whatever left the owner list is either
  -- in c.mail / c.mailGold or long gone - the pending bridge has done its job
  c.pending, c.pendingTs = nil, nil
  if M.RequestUIRefresh then M.RequestUIRefresh() end   -- net worth reads this
end

-- Bags + money for the CURRENT character (needed for cross-character net worth)
function M.CacheBags()
  local c = CharCache(); if not c then return end
  local scan = scanBags(BAGS, {})
  -- A scan during a loading screen / logout can come back empty. Never let that
  -- wipe a previously captured snapshot of this character's bags (that bug made
  -- every offline character read as 0c after their last clean logout).
  if next(scan) == nil and c.bags and next(c.bags) ~= nil then return end
  c.bags = scan
  c.bagsTs = time()
end

function M.CacheMoney()
  local c = CharCache(); if not c then return end
  -- keep the stored two-part name when the client reports only its first word
  local nm = UnitName("player")
  if nm and not (c.name and c.name ~= nm and c.name:sub(1, #nm + 1) == nm .. " ") then c.name = nm end
  local m = GetMoney() or 0
  -- GetMoney() can read 0 during logout/loading; keep the known balance instead
  -- of clobbering it with a transient zero.
  if m == 0 and (c.money or 0) > 0 then return end
  c.money = m
end

-- Active auctions for the CURRENT character. Readable only at the AH once the
-- owner list has loaded (we cache opportunistically, like bank/mail). Aggregated
-- per item: total quantity + total asking price (buyout, else min bid).
-- Modern client (C_AuctionHouse): same output shape from the owned-auction list.
-- buyoutAmount / bidAmount are the TOTAL price of a normal row (in-game check 18.09.:
-- 14 Linen Cloth listed for 3s50c read buyoutAmount = 350), like classic buyouts.
-- Merged commodity rows are the exception (user report 23.09.: 69 Chunk of Boar Meat
-- at 39c each read buyoutAmount = 39): there the amount is the UNIT price.
-- A row larger than one stack can only be such a commodity row -> unit price.
-- Otherwise pick the reading whose unit price is closer to the item's value.
local function rowTotal(id, amount, count)
  if count <= 1 then return amount end
  local maxStack = select(8, M.GetItemInfo(id))
  if maxStack and maxStack > 0 and count > maxStack then return amount * count end
  local ref = M.ItemValue and M.ItemValue(id) or 0
  if ref > 0 then
    local asTotal = math.abs(math.log((amount / count) / ref))
    local asUnit  = math.abs(math.log(amount / ref))
    if asUnit < asTotal then return amount * count end
  end
  return amount
end

-- Pending bridge: whatever just LEFT the owner list is now travelling by mail
-- (sold = gold, expired/cancelled = the item) but is invisible until the
-- mailbox is opened - without this, net worth dips by exactly that value the
-- moment the AH refreshes the owner list. Remember the lost quantity with its
-- proportional ask; CharAssets keeps valuing it like the auction it was, and
-- M.CacheMail dissolves it once the inbox is the ground truth.
local function notePending(c, au)
  local old = c.auctions
  if not old then return end
  for id, a in pairs(old) do
    local nq = (au[id] and au[id].qty) or 0
    local lost = (a.qty or 0) - nq
    if lost > 0 and (a.qty or 0) > 0 and (a.gold or 0) > 0 then
      c.pending = c.pending or {}
      local p = c.pending[id]
      if not p then p = { qty = 0, gold = 0 }; c.pending[id] = p end
      p.qty = p.qty + lost
      p.gold = p.gold + math.floor(a.gold * lost / a.qty + 0.5)
      c.pendingTs = time()
    end
  end
end

-- An auction mail just told us a listing ended (sold / returned / cancelled):
-- take it out of the still-cached owner list, so the mail content and the
-- stale auction row are never counted twice. The next real owner-list refresh
-- overwrites the whole cache anyway.
function M.AuctionSettled(id, count)
  local c = CharCache(); if not (c and c.auctions) then return end
  local a = c.auctions[id]; if not a then return end
  local q = math.min(count or 1, a.qty or 0)
  if q <= 0 then return end
  local unit = a.gold / a.qty
  a.qty = a.qty - q
  a.gold = math.max(0, a.gold - math.floor(unit * q + 0.5))
  if a.qty <= 0 then c.auctions[id] = nil end
end

local function cacheAuctionsModern(c)
  local AH = C_AuctionHouse
  local n = AH.GetNumOwnedAuctions() or 0
  local au = {}
  for i = 1, n do
    local info = AH.GetOwnedAuctionInfo(i)
    local id = info and info.itemKey and info.itemKey.itemID
    if id and info.status == 0 then                     -- 0 = active, 1 = sold (money pending)
      local count = info.quantity or 1
      local buyout = (info.buyoutAmount and info.buyoutAmount > 0) and rowTotal(id, info.buyoutAmount, count) or nil
      local price = buyout
                 or (info.bidAmount and info.bidAmount > 0 and rowTotal(id, info.bidAmount, count)) or 0
      if price <= 0 and M.ItemValue then price = M.ItemValue(id) * count end
      if price > 0 then
        local a = au[id]; if not a then a = { qty = 0, gold = 0, lv = {} }; au[id] = a end
        a.qty = a.qty + count
        a.gold = a.gold + price
        -- unit-price clusters (copper -> units), so the offer book can mark
        -- each ask level instead of one volume-weighted average
        local u = math.floor(price / count + 0.5)
        a.lv = a.lv or {}
        a.lv[u] = (a.lv[u] or 0) + count
      end
      if buyout then
        if M.RememberAuctionSize then M.RememberAuctionSize(id, buyout, count) end
        if M.RememberListing then M.RememberListing(id, buyout, count) end
      end
    end
  end
  notePending(c, au)
  c.auctions = au
  c.auctionsTs = time()
  if M.RequestUIRefresh then M.RequestUIRefresh() end   -- YOUR-ASK clusters + net worth read this
end

function M.CacheAuctions()
  local c = CharCache(); if not c then return end
  if M.MODERN_AH then return cacheAuctionsModern(c) end
  local n = (GetNumAuctionItems and GetNumAuctionItems("owner")) or 0
  local au = {}
  for i = 1, n do
    local _, _, count, _, _, _, _, minBid, _, buyout, _, _, _, _, _, saleStatus, itemID = GetAuctionItemInfo("owner", i)
    local link = GetAuctionItemLink and GetAuctionItemLink("owner", i)
    local id = (link and tonumber(link:match("item:(%d+)"))) or itemID
    if id and (saleStatus == nil or saleStatus == 0) then   -- 0 = still active
      count = count or 1
      local price = (buyout and buyout > 0 and buyout) or (minBid and minBid > 0 and minBid) or 0
      if price <= 0 and M.ItemValue then price = M.ItemValue(id) * count end
      if price > 0 then
        local a = au[id]; if not a then a = { qty = 0, gold = 0, lv = {} }; au[id] = a end
        a.qty = a.qty + count
        a.gold = a.gold + price
        local u = math.floor(price / count + 0.5)
        a.lv = a.lv or {}
        a.lv[u] = (a.lv[u] or 0) + count
      end
      -- remember this auction's stack size so a later "sold" mail can show unit price,
      -- and its buyout so a later expired mail can be attributed a listed price
      if buyout and buyout > 0 then
        if M.RememberAuctionSize then M.RememberAuctionSize(id, buyout, count) end
        if M.RememberListing then M.RememberListing(id, buyout, count) end
      end
    end
  end
  notePending(c, au)
  c.auctions = au
  c.auctionsTs = time()
  if M.RequestUIRefresh then M.RequestUIRefresh() end   -- YOUR-ASK clusters + net worth read this
end

-- Total holdings: bags (live) + bank/mail (cache) -> {itemID = qty}
function M.Holdings()
  local h = scanBags(BAGS, {})
  local c = M.db and M.db.chars and M.db.chars[CharKey()]
  if c then
    if c.bank then for id, q in pairs(c.bank) do h[id] = (h[id] or 0) + q end end
    if c.mail then for id, q in pairs(c.mail) do h[id] = (h[id] or 0) + q end end
  end
  return h
end

-- ===== Sell tips =============================================================
-- Items from your holdings whose current price is above the median, weighted
-- by liquidity and data confidence. Same scoring idea as elsewhere in the addon.
function M.BestSells(limit)
  limit = limit or 4
  local C = M.C
  if not M.db then return {} end
  local out = {}
  for id, qty in pairs(M.Holdings()) do
    local key = tostring(id)
    local series = M.GetSeries(key)
    -- same quality filter as Top Picks: no vendor items (e.g. Alterac Swiss),
    -- no grey junk / BoP / quest -- only real, sellable market items.
    if series and M.IsTradeable(key) == true then
      local m = M.Metrics(series, key)
      if m and m.fair > 0 and m.days >= C.MIN_DAYS then
        local premium = m.cur / m.fair - 1
        if premium > 0 then
          local liqW  = 0.25 + 0.75 * m.liq        -- never weight liquidity fully to 0
          local score = math.min(premium, C.MARGIN_CAP) * liqW * m.conf
          out[#out + 1] = {
            id = id, qty = qty, cur = m.cur, fair = m.fair, premium = premium,
            avgQty = m.avgQty, days = m.days, score = score,
            liqLabel = m.liqLabel, speed = m.speed, quick = m.quick,
          }
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.score > b.score end)
  for i = #out, limit + 1, -1 do out[i] = nil end
  return out
end

-- Chat output (quick test without the minimap hover)
function M.PrintSells()
  local picks = M.BestSells(6)
  if #picks == 0 then
    M.Print("No sell tips: nothing above fair or too few scan days (>=4 needed).")
    return
  end
  M.Print("Top sells from your holdings:")
  for _, p in ipairs(picks) do
    print(string.format("  %s x%d  Price %s  +%.0f%% above fair  \194\183  %s (avg %d in AH, %dd)",
      M.ItemName(tostring(p.id)), p.qty, M.MoneyPlain(p.cur),
      p.premium * 100, p.liqLabel or "?", math.floor(p.avgQty + 0.5), p.days))
  end
end

-- ===== Events: cache bank/mail when their frame opens (debounced) ===========
local pending = {}
local function debounce(key, fn, delay)
  if pending[key] then return end
  pending[key] = true
  C_Timer.After(delay or 0.3, function() pending[key] = nil; fn() end)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "BANKFRAME_OPENED", "PLAYERBANKSLOTS_CHANGED", "MAIL_SHOW", "MAIL_INBOX_UPDATE",
                     "BAG_UPDATE_DELAYED", "PLAYER_MONEY", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT" }) do
  M.SafeRegister(ev, e)
end
if M.MODERN_AH then
  M.SafeRegister(ev, "OWNED_AUCTIONS_UPDATED")
  M.SafeRegister(ev, "AUCTION_HOUSE_SHOW")
else
  M.SafeRegister(ev, "AUCTION_OWNED_LIST_UPDATE")
end
ev:SetScript("OnEvent", function(_, event)
  if event == "BANKFRAME_OPENED" or event == "PLAYERBANKSLOTS_CHANGED" then
    debounce("bank", M.CacheBank, 0.3)
  elseif event == "MAIL_SHOW" then
    if CheckInbox then CheckInbox() end
    debounce("mail", M.CacheMail, 0.5)
    if M.ScanTradeMail then debounce("trademail", M.ScanTradeMail, 0.7) end
  elseif event == "MAIL_INBOX_UPDATE" then
    debounce("mail", M.CacheMail, 0.3)
    if M.ScanTradeMail then debounce("trademail", M.ScanTradeMail, 0.5) end
  elseif event == "AUCTION_OWNED_LIST_UPDATE" or event == "OWNED_AUCTIONS_UPDATED" then
    debounce("auctions", M.CacheAuctions, 0.3)
  elseif event == "AUCTION_HOUSE_SHOW" then
    -- modern client: the owned list is only sent on request
    C_Timer.After(1, function()
      if M.AHOpen and C_AuctionHouse.QueryOwnedAuctions then pcall(C_AuctionHouse.QueryOwnedAuctions, {}) end
    end)
  elseif event == "BAG_UPDATE_DELAYED" then
    debounce("bags", M.CacheBags, 0.5)
  elseif event == "PLAYER_MONEY" then
    debounce("money", M.CacheMoney, 0.2)
  elseif event == "PLAYER_ENTERING_WORLD" then
    -- every login / reload / zone: make sure this character is captured
    debounce("bags", M.CacheBags, 1.0)
    debounce("money", M.CacheMoney, 1.0)
  elseif event == "PLAYER_LOGOUT" then
    M.CacheBags(); M.CacheMoney()
  end
end)
