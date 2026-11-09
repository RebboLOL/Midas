-- Midas – Trades: trading history (buys / sells / returns) and a "sellability"
-- rating per item. Auction trades come from the auction-house mail you receive
-- (the mailbox is the only reliable source of *realized* auctions); vendor buys
-- and the player trade window are booked once they completed. Persisted in
-- SavedVariables.
--
--   sold mail      -> your auction sold     (money in mail, no attachment)
--   expired mail   -> auction came back     (item attached, no money)
--   won mail       -> you bought an item    (item attached)
--   outbid mail    -> your bid refunded     (money back)
--
-- Sell-through (sold / (sold + returned)) tells us how well the price was set:
--   ~all sold      -> probably too cheap
--   some / some    -> price well chosen
--   ~all returned  -> too expensive
local ADDON, M = ...

-- ===== Storage ==============================================================
local function tradeDB()
  if not M.db then return nil end
  M.db.trade = M.db.trade or {}
  local t = M.db.trade
  t.log = t.log or {}
  t.seen = t.seen or {}
  t.mail = t.mail or {}
  t.nameIndex = t.nameIndex or {}
  return t
end

local function charKey()
  return (M.CharKey and M.CharKey())
    or (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

-- Everything derived from the log. The windowed aggregates also go stale when
-- the scan day rolls over, not only when the log changes.
local function dropCaches()
  M._tradeStats, M._realizedCache, M._outcomeById, M._boughtCache = nil, nil, nil, nil
  M._tradeIdx = nil
end

local function syncDay()
  local d = M.GetScanDay()
  if M._tradeDay == d then return end
  local rolled = M._tradeDay ~= nil
  M._tradeDay = d
  dropCaches()
  -- deferred: this runs inside Metrics via RealizedSell/OutcomeCounts
  if rolled and M.DirtyAnalysis then C_Timer.After(0, M.DirtyAnalysis) end
end

-- Strip the trailing "(N)" stack size the AH puts in mail subjects, so a name is
-- the same regardless of how big the stack was ("Iron Bar (20)" -> "Iron Bar").
local function cleanItemName(nm)
  if not nm or nm == "" then return nm end
  return (nm:gsub("%s*%(%d+%)%s*$", ""))
end
M.CleanItemName = cleanItemName

-- Grouping key for the By-Item view: the cleaned item name, so the same item is
-- always ONE group regardless of stack size or whether its id has resolved yet
-- (item info is cold right after login, so an id-based key would fragment). Done
-- live here too, so grouping is correct even before the one-time data migration.
local function tradeKey(e)
  local nm = e.name
  if (not nm or nm == "") and e.id then nm = M.ItemName(tostring(e.id)) end
  if nm and nm ~= "" and not nm:find("^Item #") then return cleanItemName(nm):lower() end
  return e.id and ("id:" .. e.id) or "?"
end

-- ===== Locale-safe subject classification ===================================
-- WoW ships the AH mail subjects as global format strings ("Auction successful:
-- %s"). We match on the literal text *before* the %s, so this works in every
-- client language without hard-coding strings.
local SUBJ
local function prefixOf(fmt)
  if type(fmt) ~= "string" then return nil end
  local i = fmt:find("%%s")        -- position of the "%s" token
  if i then return fmt:sub(1, i - 1) end
  return fmt
end

local function ensureSubjects()
  if SUBJ then return SUBJ end
  SUBJ = {
    sold      = prefixOf(AUCTION_SOLD_MAIL_SUBJECT),     -- "Auction successful: %s"
    expired   = prefixOf(AUCTION_EXPIRED_MAIL_SUBJECT),  -- "Auction expired: %s"
    removed   = prefixOf(AUCTION_REMOVED_MAIL_SUBJECT),  -- "Auction cancelled: %s"
    won       = prefixOf(AUCTION_WON_MAIL_SUBJECT),      -- "Auction won: %s"
    outbid    = prefixOf(AUCTION_OUTBID_MAIL_SUBJECT),   -- "Outbid on: %s"
  }
  return SUBJ
end

local function startsWith(s, p)
  return p and p ~= "" and s:sub(1, #p) == p
end

-- subject -> kind, itemName (name captured from the part after the prefix)
local function classify(subject)
  if not subject then return nil end
  local S = ensureSubjects()
  if startsWith(subject, S.sold)    then return "sold",      subject:sub(#S.sold + 1) end
  if startsWith(subject, S.won)     then return "bought",    subject:sub(#S.won + 1) end
  if startsWith(subject, S.expired) then return "returned",  subject:sub(#S.expired + 1) end
  if startsWith(subject, S.removed) then return "cancelled", subject:sub(#S.removed + 1) end
  if startsWith(subject, S.outbid)  then return "outbid",    subject:sub(#S.outbid + 1) end
  return nil
end

-- Best guess at the buyout a now-expired auction was listed at, from the active
-- listings we cached while the AH Auctions tab was open (the expired mail itself
-- carries no price). Prefer entries with the same stack size; median of recent buyouts.
local function estListPrice(t, id, count)
  local arr = t and t.listings and t.listings[id]
  if not arr or #arr == 0 then return nil end
  local units = {}
  for _, l in ipairs(arr) do
    if (not count) or count == 0 or l.count == count then units[#units + 1] = l.buyout end
  end
  if #units == 0 then for _, l in ipairs(arr) do units[#units + 1] = l.buyout end end
  table.sort(units)
  return units[math.floor((#units + 1) / 2)]
end

-- ===== Mail identity ========================================================
-- A mail carries no id we can read. Per character it is identified by kind,
-- item, money (bought: the invoice price) and its expiry; identical mails are
-- matched one-to-one. AH mails live 30 days, so the expiry also dates the trade.
local MAIL_LIFE  = 30 * 86400
local MAIL_TOL   = 30    -- s: the same mail's expiry estimate wobbles by a few seconds between passes
local LEGACY_TOL = 300   -- s: t.seen expiries were taken from a stale daysLeft, so they run late

-- daysLeft only moves when the server resends the inbox, so "now + daysLeft"
-- creeps forward with the clock in between. Each daysLeft value is anchored to
-- the moment it was first read, which keeps one expiry per mail across passes.
local dlAnchor = {}

local function mailKey(kind, name, id, money, gross)
  local who = (name and name ~= "" and name:lower()) or id or "?"
  return kind .. "|" .. who .. "|" .. money .. "|" .. ((kind == "bought") and gross or 0)
end

-- nearest unclaimed stored expiry within MAIL_TOL
local function takeSlot(slots, claimed, expiry)
  local best, bestD
  for j = 1, #slots do
    if not claimed[j] then
      local d = math.abs(slots[j] - expiry)
      if d <= MAIL_TOL and (not bestD or d < bestD) then best, bestD = j, d end
    end
  end
  return best
end

-- t.seen holds "kind|id-or-name|money|hour#n" -> expiry, without the character.
-- Mails logged under that scheme must not be logged again; each entry is used
-- up by at most one mail and then dropped.
local function legacyIndex(t)
  if not next(t.seen) then return nil end
  local idx = {}
  for h, exp in pairs(t.seen) do
    local base = h:match("^(.*)|%-?%d+#%d+$")
    if base then
      local arr = idx[base]; if not arr then arr = {}; idx[base] = arr end
      arr[#arr + 1] = { h = h, exp = exp }
    end
  end
  return idx
end

local function takeLegacy(t, idx, base, expiry)
  local arr = idx[base]
  if not arr then return false end
  local best, bestD
  for j, o in ipairs(arr) do
    local d = o.exp - expiry
    if d >= -MAIL_TOL and d <= LEGACY_TOL and (not bestD or math.abs(d) < bestD) then
      best, bestD = j, math.abs(d)
    end
  end
  if not best then return false end
  t.seen[arr[best].h] = nil
  table.remove(arr, best)
  return true
end

-- ===== Scan the inbox and append new trade events ===========================
function M.ScanTradeMail()
  local t = tradeDB(); if not t then return end
  local n, onServer = 0, nil
  if GetInboxNumItems then n, onServer = GetInboxNumItems() end
  n = n or 0
  -- an empty list is also what the client reports before the inbox has loaded,
  -- so it proves nothing about collected mail
  if n == 0 then return end
  local now, day = time(), M.GetScanDay()
  local realm, char = M.RealmKey(), charKey()
  local added = 0
  local store = t.mail[char]
  if not store then store = {}; t.mail[char] = store end
  local claimed = {}        -- key -> { [slot] = true }: stored mails present in this pass
  local complete = (onServer == nil) or n >= onServer   -- the inbox shows at most 50 mails
  local legacy = legacyIndex(t)
  t.mailSince = t.mailSince or now
  local anchors = {}

  for i = 1, n do
    local _, _, _, subject, money, _, daysLeft = GetInboxHeaderInfo(i)
    local at = now
    if daysLeft then
      at = dlAnchor[daysLeft] or now
      anchors[daysLeft] = at
    end
    local kind, capName = classify(subject)
    if kind then
      money = money or 0
      -- the subject carries the stack size as a trailing "(N)" (e.g. "Iron Bar (20)");
      -- pull it out and strip it so the name stays clean -- otherwise the same item
      -- splits into one group per stack size.
      local subjCount
      if capName then
        subjCount = tonumber(capName:match("%((%d+)%)%s*$"))
        capName = (capName:gsub("%s*%(%d+%)%s*$", ""))
      end
      -- resolve item id / name / count
      local id, name, count
      if kind == "returned" or kind == "cancelled" or kind == "bought" then
        local link = GetInboxItemLink and GetInboxItemLink(i, 1)
        if link then id = tonumber(link:match("item:(%d+)")) end
        local nm, _, _, cnt = GetInboxItem(i, 1)
        name = capName or nm
        -- a multi-stack buy/return arrives as ONE mail with one attachment per
        -- stack (43 scraps = 20 + 20 + 3): sum every slot, not just the first
        local total = cnt or 0
        for a = 2, (ATTACHMENTS_MAX_RECEIVE or 16) do
          local _, _, _, c = GetInboxItem(i, a)
          if c then total = total + c end
        end
        count = math.max(total, subjCount or 0)
        if count == 0 then count = 1 end
        id = id or (name and (t.nameIndex[name:lower()] or M.NameToID(name)))
        if id and name then t.nameIndex[name:lower()] = id end
      else
        name = capName
        count = subjCount or 0   -- stack size now comes from the subject "(N)"
        id = name and (t.nameIndex[name:lower()] or M.NameToID(name)) or nil
      end

      -- money breakdown via invoice (may be nil); mail money = net ground truth
      local gross, fee, net = 0, 0, 0
      local _, _, _, bid, buyout, deposit, consignment
      if GetInboxInvoiceInfo then
        _, _, _, bid, buyout, deposit, consignment = GetInboxInvoiceInfo(i)
      end
      if kind == "sold" then
        -- the sale mail also refunds the listing deposit: that is our own money
        -- coming back, not sale proceeds (verified 18.09.: 14 Linen sold for 350c
        -- -> mail 433c = 350 - 17 cut + 100 deposit)
        deposit = (deposit and deposit > 0 and deposit < money) and deposit or 0
        net   = money - deposit
        fee   = consignment or 0
        gross = net + fee     -- sale price = proceeds + AH cut; robust (invoice buyout is unreliable, gross >= net)
        if not count or count == 0 then count = (id and gross > 0 and M.AuctionSize(id, gross)) or 1 end
      elseif kind == "bought" then
        local paid = bid or buyout or money or 0
        gross, net = paid, -paid
      elseif kind == "outbid" then
        net = money     -- refund coming back to you
      end

      -- estimate the listed price of a failed auction (the expired mail has no price);
      -- kept for future price-vs-outcome calibration, not used for pricing yet
      local listPrice
      if kind == "returned" and id then listPrice = estListPrice(t, id, count) end
      -- don't log a money-bearing mail until its gold/invoice has loaded, else we'd
      -- store a phantom 0c entry (a later inbox update catches the complete one)
      local incomplete = ((kind == "sold" or kind == "outbid") and money <= 0)
                      or (kind == "bought" and (gross or 0) <= 0)
      if incomplete then complete = false end   -- unmatched stored mails may be this one
      if incomplete and not M._mailRescan then
        -- a won mail's price lives only in its invoice, which the server loads
        -- lazily -- if the player loots the mail before another inbox pass runs,
        -- the buy would be lost forever. One debounced re-scan shortly after
        -- gives the invoice time to arrive while the mail is still there.
        M._mailRescan = true
        C_Timer.After(2, function() M._mailRescan = nil; M.ScanTradeMail() end)
      end
      if not incomplete then
        -- a mail stays in the inbox until collected: log it the first time only
        local expiry = math.floor(at + (daysLeft or 0) * 86400)
        local key = mailKey(kind, name, id, money, gross)
        local slots = store[key]; if not slots then slots = {}; store[key] = slots end
        local cl = claimed[key]; if not cl then cl = {}; claimed[key] = cl end
        local slot = takeSlot(slots, cl, expiry)
        local fresh = not slot
        if fresh then
          slots[#slots + 1] = expiry
          cl[#slots] = true
          if legacy and expiry - MAIL_LIFE <= t.mailSince + MAIL_TOL then
            local tail = "|" .. money
            fresh = not ((id and takeLegacy(t, legacy, kind .. "|" .. id .. tail, expiry))
                      or (name and takeLegacy(t, legacy, kind .. "|" .. name .. tail, expiry))
                      or ((not id and not name) and takeLegacy(t, legacy, kind .. "|?" .. tail, expiry)))
          end
        else
          cl[slot] = true
        end
        if fresh then
          -- the trade happened when the mail arrived, not when it was collected
          local tday = day
          if daysLeft and daysLeft > 0 and daysLeft <= 30 then
            tday = math.floor((expiry - MAIL_LIFE - M.C.SCAN_DAY_0) / 86400)
          end
          t.log[#t.log + 1] = {
            ts = now, day = tday, kind = kind,
            id = id, name = name, count = count,
            gross = gross, fee = fee, net = net,
            listPrice = listPrice,
            char = char, realm = realm,
          }
          added = added + 1
          -- this mail proves the listing ended: drop it from the still-cached
          -- owner list, or the inbox content and the stale auction row would
          -- both count toward net worth (Inventory.lua owns the cache)
          if M.AuctionSettled and id
             and (kind == "sold" or kind == "returned" or kind == "cancelled") then
            M.AuctionSettled(id, (count and count > 0) and count or 1)
          end
          -- feed the sell-odds calibration (Fair price v2). A sold outcome only
          -- counts while the listings cache could also have priced an expiry of
          -- this item -- same observability for both outcomes keeps the measured
          -- sell-through honest (else sales would be over-counted).
          -- (a sale at a neutral AH says nothing about your own market)
          local calPrice
          if kind == "sold" then
            if t.listings and id and t.listings[id] and #t.listings[id] > 0
               and not M.NeutralSale({ kind = kind, gross = gross, fee = fee }) then calPrice = gross end
          elseif kind == "returned" then
            calPrice = listPrice
          end
          if M.CurveNote and id and calPrice and calPrice > 0 then
            local cnt = (count and count > 0) and count or 1
            local s = M.GetSeries(tostring(id))
            local f7 = s and M.Floor7 and M.Floor7(s, tday)
            if f7 and f7 > 0 then
              M.CurveNote(M.LiqClass(s), (calPrice / cnt) / f7, kind == "sold")
            end
          end
        end
      end
    end
  end
  dlAnchor = anchors

  -- a complete pass saw every mail of this character: stored mails it did not
  -- see were collected, and an identical mail arriving later is a new one
  if complete then
    for key, slots in pairs(store) do
      local cl = claimed[key]
      local keep = {}
      if cl then
        for j = 1, #slots do if cl[j] then keep[#keep + 1] = slots[j] end end
      end
      store[key] = (#keep > 0) and keep or nil
    end
  end
  for ck, st in pairs(t.mail) do
    for key, slots in pairs(st) do
      for j = #slots, 1, -1 do if slots[j] < now then table.remove(slots, j) end end
      if #slots == 0 then st[key] = nil end
    end
    if next(st) == nil then t.mail[ck] = nil end
  end

  -- prune dedup memory + trim the log by AGE, not by a fixed entry count: the
  -- old 3000-entry FIFO rolled a busy trader's buys out after ~2 weeks, silently
  -- starving the chart dots, Avg Buy, sell-through and the Fair anchor of the
  -- 60-day window they are supposed to see. Keep SELL_WINDOW plus slack.
  for h, exp in pairs(t.seen) do if exp < now then t.seen[h] = nil end end
  local cutoff = now - (M.C.TRADE_LOG_DAYS or 75) * 86400
  local drop = 0
  for i = 1, #t.log do
    if (t.log[i].ts or 0) < cutoff then drop = drop + 1 else break end
  end
  if drop > 0 then
    local keep, n = {}, 0
    for i = drop + 1, #t.log do n = n + 1; keep[n] = t.log[i] end
    t.log = keep
  end
  local max = M.C.TRADE_LOG_MAX or 20000   -- hard cap: runaway backstop only
  while #t.log > max do table.remove(t.log, 1) end

  if added > 0 then
    dropCaches()
    if M.DirtyAnalysis then M.DirtyAnalysis() end   -- fair depends on trade outcomes now
    if M.frame and M.frame:IsShown() and M.RefreshUI then M.RefreshUI() end
  end
end

-- ===== History slice (newest first) for the log view ========================
function M.TradeLog(realm, limit)
  local out = {}
  local t = tradeDB(); if not t then return out end
  for i = #t.log, 1, -1 do
    local e = t.log[i]
    if not realm or e.realm == realm then
      out[#out + 1] = e
      if limit and #out >= limit then break end
    end
  end
  return out
end

-- ===== Individual transactions for one item (newest first) ==================
-- Used by the By-Item expand row: returns every sell/buy/return for an item key
-- so the UI can show the per-transaction price, not just the aggregate net.
function M.ItemTradeLog(key, realm)
  realm = realm or M.RealmKey()
  local out = {}
  local t = tradeDB(); if not t then return out end
  for i = #t.log, 1, -1 do
    local e = t.log[i]
    if e.realm == realm and tradeKey(e) == key then out[#out + 1] = e end
  end
  return out
end

-- Reverse item-name -> id from the market archive. "Sold" mails carry no
-- attachment (so no id); without this they'd never link to market data, leaving
-- the vs-median column and the price chart empty. Built lazily, cached per session.
local nameToId, bySuffix
local noSuffix = {}

-- Random-suffix gear ("Revenant Boots of the Bear") is archived as
-- "gr:<id>:of the Bear", never under its full name: split at each " of " and
-- accept the base id only when exactly that archive key exists.
local function suffixedID(name)
  local unsure = false
  local from = 1
  while true do
    local s = name:find(" of ", from, true)
    if not s then break end
    local base = name:sub(1, s - 1):lower()
    for _, id in ipairs(bySuffix[name:sub(s + 1)] or {}) do
      local nm = M.GetItemInfo(id)
      if nm then
        if nm:lower() == base then return id end
      else
        unsure = true
      end
    end
    from = s + 1
  end
  if not unsure then noSuffix[name] = true end
  return nil
end

function M.NameToID(name)
  if not name or name == "" then return nil end
  if not nameToId then
    nameToId, bySuffix = {}, {}
    for key in pairs(M.IterItems()) do
      local id = tonumber(key)
      if id then
        local nm = M.ItemName(key)
        if nm and not nm:find("^Item #") and not nm:find("^#") and not nm:find("^Pet ") then
          nameToId[nm:lower()] = id
        end
      elseif type(key) == "string" then
        local gid, suffix = key:match("^gr:(%d+):(.+)$")
        if gid and not suffix:find("^%d+$") then
          local arr = bySuffix[suffix]; if not arr then arr = {}; bySuffix[suffix] = arr end
          arr[#arr + 1] = tonumber(gid)
        end
      end
    end
  end
  local lname = name:lower()
  local id = nameToId[lname]
  if id or noSuffix[name] or not name:find(" of ", 1, true) then return id end
  id = suffixedID(name)
  if id then nameToId[lname] = id end
  return id
end

-- ===== Own-auction stack sizes (to recover sell unit prices) =================
-- "Sold" mails don't carry the stack size. We cache it from your own active
-- auctions (id|buyout -> count) whenever the AH Auctions tab is open, then match a
-- sold mail's buyout back to its stack size to get the per-unit sale price.
function M.RememberAuctionSize(id, buyout, count)
  local t = tradeDB(); if not t then return end
  if not (id and buyout and buyout > 0 and count and count > 0) then return end
  t.sizes = t.sizes or {}
  local key = id .. "|" .. buyout
  if t.sizes[key] == nil then
    t.sizesN = (t.sizesN or 0) + 1
    if t.sizesN > 4000 then t.sizes = {}; t.sizesN = 1 end  -- soft cap; sizes re-learn
  end
  t.sizes[key] = count
end

function M.AuctionSize(id, buyout)
  local t = tradeDB()
  if not t or not t.sizes or not id or not buyout or buyout <= 0 then return nil end
  return t.sizes[id .. "|" .. buyout]
end

-- Remember an active listing's buyout (from the AH Auctions tab) so a later
-- expired mail can be attributed a listed price (see estListPrice above).
function M.RememberListing(id, buyout, count)
  local t = tradeDB(); if not t then return end
  if not (id and buyout and buyout > 0) then return end
  t.listings = t.listings or {}
  local arr = t.listings[id]; if not arr then arr = {}; t.listings[id] = arr end
  arr[#arr + 1] = { buyout = buyout, count = count or 1, ts = time() }
  while #arr > 20 do table.remove(arr, 1) end   -- keep the most recent per item
end

-- ===== Sell-odds outcome counters (Fair price v2 calibration) ================
-- Rolling per-class counters of the user's auction outcomes by price ratio
-- (ask / 7-day floor at the time). Two ~CURVE_DAYS buckets rotate so the curve
-- follows the market and survives the raw log cap. Read by classAnchor (Logic.lua).
local function curveDB()
  local t = tradeDB(); if not t then return nil end
  t.curve = t.curve or {}
  local realm = M.RealmKey()
  local c = t.curve[realm]
  local day = M.GetScanDay()
  if not c then c = { epoch = day, cur = {}, prev = {} }; t.curve[realm] = c end
  if day - (c.epoch or 0) >= (M.C.CURVE_DAYS or 30) then
    c.prev, c.cur, c.epoch = c.cur, {}, day
  end
  return c
end

-- note one outcome: liquidity class, ask ratio r (unit ask / floor7), sold yes/no
function M.CurveNote(class, r, wasSold)
  if not class or not r or r <= 0.2 or r >= 8 then return end
  local c = curveDB(); if not c then return end
  local b = c.cur[class]
  if not b then b = { s = 0, n = 0, sr = 0, ssr = 0 }; c.cur[class] = b end
  b.n = b.n + 1
  b.sr = b.sr + r
  if wasSold then
    b.s = b.s + 1
    -- ratio stats of SOLD listings only (reality brake); sn tracks how many solds
    -- carry a ratio here, since buckets written by older builds lack the field
    b.ssr = (b.ssr or 0) + r
    b.sn  = (b.sn or 0) + 1
  end
  M._curveAnchor = nil
end

-- merged counters for a class (cur + prev bucket): sold, total, sum-of-ratios,
-- plus ratio sum & count of the SOLD listings only
function M.CurveCounts(class)
  local t = tradeDB()
  local c = t and t.curve and t.curve[M.RealmKey()]
  local s, n, sr, ssr, sn = 0, 0, 0, 0, 0
  if c then
    local b = c.cur and c.cur[class]
    if b then s, n, sr, ssr, sn = s + b.s, n + b.n, sr + b.sr, ssr + (b.ssr or 0), sn + (b.sn or 0) end
    b = c.prev and c.prev[class]
    if b then s, n, sr, ssr, sn = s + b.s, n + b.n, sr + b.sr, ssr + (b.ssr or 0), sn + (b.sn or 0) end
  end
  return s, n, sr, ssr, sn
end

-- One-shot seed from the already-logged history (called stamp-gated from OnLogin).
-- Only the period where BOTH outcomes are observable is used: expired mails carry a
-- price only since listPrice stamping exists, so counting all-time sales against
-- few priced expiries would fake a high sell-through (survivor bias).
function M.SeedCurve()
  local t = tradeDB(); if not t then return 0 end
  local realm = M.RealmKey()
  local t0 = nil
  for _, e in ipairs(t.log) do
    if e.kind == "returned" and e.realm == realm and (e.listPrice or 0) > 0 then
      if not t0 or e.day < t0 then t0 = e.day end
    end
  end
  if not t0 then return 0 end
  local n = 0
  for _, e in ipairs(t.log) do
    if e.realm == realm and e.id and (e.day or 0) >= t0 and e.src ~= "trade" and not M.NeutralSale(e)
       and (e.kind == "sold" or (e.kind == "returned" and (e.listPrice or 0) > 0)) then
      local cnt = (e.count and e.count > 0) and e.count or 1
      local unit = ((e.kind == "sold") and (e.gross or 0) or e.listPrice) / cnt
      local s = M.GetSeries(tostring(math.floor(e.id)))
      local f7 = s and M.Floor7 and M.Floor7(s, e.day)
      if unit > 0 and f7 and f7 > 0 then
        M.CurveNote(M.LiqClass(s), unit / f7, e.kind == "sold")
        n = n + 1
      end
    end
  end
  return n
end

-- sold / returned auction counts per item id within SELL_WINDOW (per-item
-- refinement of the sell-odds curve). Cached per realm.
function M.OutcomeCounts(key, realm)
  realm = realm or M.RealmKey()
  local id = (M.BaseID and M.BaseID(key)) or tonumber(key)
  if not id then return 0, 0 end
  syncDay()
  M._outcomeById = M._outcomeById or {}
  local cache = M._outcomeById[realm]
  if not cache then
    cache = {}
    local t = tradeDB()
    if t then
      local cutoff = M.GetScanDay() - (M.C.SELL_WINDOW or 60)
      for _, e in ipairs(t.log) do
        -- auction outcomes only: a trade-window sale says nothing about how
        -- an ask fares at the AH, nor does a sale at a neutral AH
        if e.realm == realm and e.id and (e.day or 0) >= cutoff and e.src ~= "trade" and not M.NeutralSale(e) then
          if e.kind == "sold" or e.kind == "returned" then
            local r = cache[e.id]
            if not r then r = { s = 0, n = 0 }; cache[e.id] = r end
            r.n = r.n + 1
            if e.kind == "sold" then r.s = r.s + 1 end
          end
        end
      end
    end
    M._outcomeById[realm] = cache
  end
  local c = cache[id]
  if not c then return 0, 0 end
  return c.s, c.n - c.s
end

-- Your own average BUY price per unit (from "bought" mails): volume-weighted
-- (total paid / total units) over the whole log. For the item tooltip.
function M.RealizedBuy(key, realm)
  realm = realm or M.RealmKey()
  local id = (M.BaseID and M.BaseID(key)) or tonumber(key)
  if not id then return nil, 0 end
  syncDay()
  M._boughtCache = M._boughtCache or {}
  local cache = M._boughtCache[realm]
  if not cache then
    cache = {}
    local t = tradeDB()
    if t then
      for _, e in ipairs(t.log) do
        if e.kind == "bought" and e.realm == realm and e.id and (e.gross or 0) > 0 then
          local cnt = (e.count and e.count > 0) and e.count or 1
          local r = cache[e.id]
          if not r then r = { paid = 0, units = 0 }; cache[e.id] = r end
          r.paid = r.paid + e.gross
          r.units = r.units + cnt
        end
      end
    end
    M._boughtCache[realm] = cache
  end
  local c = cache[id]
  if not c or c.units <= 0 then return nil, 0 end
  return c.paid / c.units, c.units
end

-- ===== Realized sale price per item (the Fair-price anchor) ==================
-- Median of your realized sale UNIT prices (gross/count) within SELL_WINDOW for an
-- item id, plus sale count, your sales (auctions) per day over the part of the
-- window the log actually covers, and the median RATIO of each sale vs the 7-day
-- floor on its sale day (what this item really clears at, price-level-free -- the
-- reality brake for the Fair lift). Cached per realm; invalidated with
-- _tradeStats whenever the log changes.
local function medianOf(arr)
  local n = #arr; if n == 0 then return nil end
  table.sort(arr)
  if n % 2 == 1 then return arr[(n + 1) / 2] end
  return (arr[n / 2] + arr[n / 2 + 1]) / 2
end

function M.RealizedSell(key, realm)
  realm = realm or M.RealmKey()
  local id = (M.BaseID and M.BaseID(key)) or tonumber(key)
  if not id then return nil, 0, 0 end
  syncDay()
  M._realizedCache = M._realizedCache or {}
  local cache = M._realizedCache[realm]
  if not cache then
    cache = {}
    local t = tradeDB()
    if t then
      local today = M.GetScanDay()
      local cutoff = today - (M.C.SELL_WINDOW or 60)
      local tmp, oldest = {}, nil
      for _, e in ipairs(t.log) do
        if e.realm == realm and e.day and (not oldest or e.day < oldest) then oldest = e.day end
        if e.kind == "sold" and e.src ~= "trade" and e.realm == realm and e.id and (e.day or 0) >= cutoff
           and not M.NeutralSale(e) then
          local cnt = (e.count and e.count > 0) and e.count or 1
          local unit = (e.gross or 0) / cnt
          if unit > 0 then
            local r = tmp[e.id]
            if not r then r = { units = {}, ratios = {} }; tmp[e.id] = r end
            r.units[#r.units + 1] = unit
            local s = M.GetSeries and M.GetSeries(tostring(e.id), realm)
            local f7 = s and M.Floor7 and M.Floor7(s, e.day)
            if f7 and f7 > 0 then r.ratios[#r.ratios + 1] = unit / f7 end
          end
        end
      end
      local observed = math.max(1, today - math.max(cutoff, oldest or cutoff) + 1)
      for iid, r in pairs(tmp) do
        cache[iid] = { med = medianOf(r.units), n = #r.units, perDay = #r.units / observed,
                       rmed = medianOf(r.ratios) }
      end
    end
    M._realizedCache[realm] = cache
  end
  local c = cache[id]
  if not c then return nil, 0, 0 end
  return c.med, c.n, c.perDay, c.rmed
end

-- One-shot cleanup of entries logged by older builds: drop phantom money-mails
-- (a "sold" with no proceeds, a "bought" with no cost) and recompute each sale's
-- gross as proceeds + AH cut so it is always >= net. Returns how many it touched.
function M.RepairTrades()
  local t = tradeDB(); if not t then return 0 end
  local kept, touched = {}, 0
  for _, e in ipairs(t.log) do
    -- strip a trailing "(N)" stack size older builds kept in the name (it split one
    -- item into several groups); recover the count and resolve the id from the name
    if e.name then
      local c = tonumber(e.name:match("%((%d+)%)%s*$"))
      if c then
        e.name = (e.name:gsub("%s*%(%d+%)%s*$", ""))
        if not e.count or e.count == 0 then e.count = c end
        e.id = e.id or M.NameToID(e.name)
        touched = touched + 1
      end
    end
    local drop = false
    if e.kind == "sold" then
      if not e.net or e.net <= 0 then drop = true
      else
        local g = e.net + (e.fee or 0)
        if e.gross ~= g then e.gross = g; touched = touched + 1 end
      end
    elseif e.kind == "bought" then
      if not e.gross or e.gross <= 0 then drop = true end
    elseif e.kind == "outbid" then
      if not e.net or e.net <= 0 then drop = true end
    end
    if drop then touched = touched + 1 else kept[#kept + 1] = e end
  end
  if touched > 0 then
    t.log = kept
    dropCaches()
    if M.DirtyAnalysis then M.DirtyAnalysis() end
  end
  return touched
end

-- ===== Traded items =========================================================
-- Per realm: which ids you ever SOLD (anything you only buy at a vendor is own
-- use, not trading stock) and the By-Item key of each id.
local function tradeIndex(realm)
  syncDay()
  M._tradeIdx = M._tradeIdx or {}
  local x = M._tradeIdx[realm]
  if x then return x end
  x = { sold = {}, key = {} }
  local t = tradeDB()
  if t then
    for i = #t.log, 1, -1 do
      local e = t.log[i]
      if e.realm == realm and (e.id or e.name) then
        local id = e.id or (e.name and (t.nameIndex[e.name:lower()] or M.NameToID(e.name)))
        if id then
          if e.kind == "sold" then x.sold[id] = true end
          if x.key[id] == nil then x.key[id] = tradeKey(e) end
        end
      end
    end
  end
  M._tradeIdx[realm] = x
  return x
end

local function asID(id)
  if id == nil then return nil end
  return (M.BaseID and M.BaseID(id)) or tonumber(id)
end

function M.IsTradedID(id, realm)
  local n = asID(id)
  return n ~= nil and tradeIndex(realm or M.RealmKey()).sold[n] == true
end

function M.TradeKeyForID(id, realm)
  local n = asID(id)
  return n and tradeIndex(realm or M.RealmKey()).key[n] or nil
end

-- a vendor purchase of something you never sell: consumption, not a trade
local function ownUse(e, realm)
  return e.kind == "bought" and e.src == "vendor"
     and not (e.id and tradeIndex(realm).sold[e.id])
end

-- ===== Per-item aggregate (cached, rebuilt from the log) ====================
-- Everything over SELL_WINDOW, so every column of an item row covers the same
-- days as its sellability rating. Own-use vendor buys are not trades and an
-- outbid mail only returns your own bid, so neither touches net.
function M.TradeStats(realm)
  realm = realm or M.RealmKey()
  syncDay()
  M._tradeStats = M._tradeStats or {}
  if M._tradeStats[realm] then return M._tradeStats[realm] end

  local stats = {}
  local t = tradeDB()
  if t then
    local cutoff = M.GetScanDay() - (M.C.SELL_WINDOW or 60)
    for _, e in ipairs(t.log) do
      if e.realm == realm and (e.id or e.name) and (e.day or 0) >= cutoff and not ownUse(e, realm)
         and e.kind ~= "given" and e.kind ~= "received" then
        local key = tradeKey(e)
        -- resolve an id for market data (chart / vs-median); grouping itself is by name
        local id = e.id or (e.name and (t.nameIndex[e.name:lower()] or M.NameToID(e.name)))
        local s = stats[key]
        if not s then
          s = { soldStacks = 0, retStacks = 0, soldUnits = 0, retUnits = 0,
                boughtUnits = 0, gross = 0, fees = 0, net = 0, lastTs = 0,
                soldW = 0, retW = 0, id = id, name = cleanItemName(e.name) }
          stats[key] = s
        end
        if e.kind == "sold" then
          -- a trade-window sale is money and units, but no AUCTION: it stays
          -- out of the sold/returned counts and the sell-through rating
          if e.src ~= "trade" then
            s.soldStacks = s.soldStacks + 1
            s.soldW = s.soldW + 1
          end
          s.soldUnits  = s.soldUnits + (e.count or 0)
          s.gross = s.gross + (e.gross or 0)
          s.fees  = s.fees + (e.fee or 0)
          s.net   = s.net + (e.net or 0)
        elseif e.kind == "returned" then
          s.retStacks = s.retStacks + 1
          s.retUnits  = s.retUnits + (e.count or 0)
          s.retW = s.retW + 1
        elseif e.kind == "bought" then
          s.boughtUnits = s.boughtUnits + (e.count or 0)
          s.net = s.net + (e.net or 0)
        end
        if not s.id and id then s.id = id end
        if not s.name and e.name then s.name = cleanItemName(e.name) end
        if (e.ts or 0) > s.lastTs then s.lastTs = e.ts end
      end
    end
  end
  M._tradeStats = M._tradeStats or {}   -- a day rollover inside the loop drops the caches
  M._tradeStats[realm] = stats
  return stats
end

-- ===== Sellability rating (over the rolling window) =========================
function M.Sellability(itemKey, realm)
  local C, CC = M.C, M.Theme.C
  local stats = M.TradeStats(realm)
  local s = stats[itemKey]
  local sold = (s and s.soldW) or 0
  local ret  = (s and s.retW) or 0
  local n = sold + ret
  if n < (C.SELL_MIN_N or 3) then
    return { n = n, rate = nil, label = "Too few", color = CC.muted, sold = sold, ret = ret }
  end
  local rate = sold / n
  if rate >= (C.SELL_HOT or 0.85) then
    return { n = n, rate = rate, label = "Underpriced", color = CC.accent, sold = sold, ret = ret }
  elseif rate < (C.SELL_COLD or 0.34) then
    return { n = n, rate = rate, label = "Overpriced", color = CC.red, sold = sold, ret = ret }
  end
  return { n = n, rate = rate, label = "Well priced", color = CC.green, sold = sold, ret = ret }
end

-- ===== Window summary for the header strip ==================================
-- afterDay: only trades AFTER that day (pairs with a net-worth snapshot taken at
-- the end of afterDay). days = calendar days the window spans, today included.
-- Outbid refunds and own-use vendor buys (ownUse = their cost) stay out of net.
function M.TradeSummary(realm, windowDays, afterDay)
  realm = realm or M.RealmKey()
  local today = M.GetScanDay()
  local cutoff, days = -math.huge, nil
  if afterDay then
    cutoff, days = afterDay + 1, today - afterDay
  elseif windowDays then
    cutoff, days = today - windowDays, windowDays + 1
  end
  local s = { grossSells = 0, fees = 0, buyCost = 0, net = 0, sold = 0, ret = 0, bought = 0,
              ownUse = 0, days = days }
  local t = tradeDB()
  if t then
    for _, e in ipairs(t.log) do
      if e.realm == realm and (e.day or 0) >= cutoff then
        if e.kind == "sold" then
          s.grossSells = s.grossSells + (e.gross or 0)
          s.fees = s.fees + (e.fee or 0)
          s.net  = s.net + (e.net or 0)
          if e.src ~= "trade" then s.sold = s.sold + 1 end   -- sold/returned count AUCTIONS
        elseif e.kind == "returned" then
          s.ret = s.ret + 1
        elseif e.kind == "bought" then
          if ownUse(e, realm) then
            s.ownUse = s.ownUse + (e.gross or 0)
          else
            s.buyCost = s.buyCost + (e.gross or 0)
            s.net = s.net + (e.net or 0)
            s.bought = s.bought + 1
          end
        end
      end
    end
  end
  local denom = s.sold + s.ret
  s.sellThrough = denom > 0 and (s.sold / denom) or nil
  return s
end

-- ===== Chat diagnostic (/midas trades) ======================================
function M.PrintTrades()
  local win = M.C.SELL_WINDOW or 60
  local s = M.TradeSummary(M.RealmKey(), win)
  M.Print(string.format("Trades (last %dd): net %s%s   \194\183   sold %d, returned %d, bought %d",
    win, s.net >= 0 and "+" or "-", M.MoneyPlain(math.abs(s.net)), s.sold, s.ret, s.bought))
  if s.sellThrough then
    M.Print(string.format("sell-through %.0f%%   \194\183   gross sells %s, AH fees %s",
      s.sellThrough * 100, M.MoneyPlain(s.grossSells), M.MoneyPlain(s.fees)))
  else
    M.Print("No completed sales/returns recorded yet - collect your AH mail.")
  end
end

-- ===== Vendor purchases =====================================================
-- Flips like the Chronoboon Displacer are BOUGHT at a vendor (1g) and sold at the
-- AH. Only auction-won mails used to be logged, so those buys were missing and the
-- Avg-Buy / net-P&L statistics looked too rosy. Hook the merchant buy call and log
-- a "bought" event with src="vendor" -- same shape as an AH buy, so Avg Buy,
-- realized net and the History view all account for the real cost basis.
-- The hook fires before the server answers and a buy can still fail (bags
-- full, not enough gold), so it is only booked once its gold has left.
local BUY_WAIT = 10        -- s an unconfirmed buy waits for its money change
local pendingBuys, lastMoney = {}, nil

local function bookVendorBuy(p, cost)
  local t = tradeDB(); if not t then return end
  if p.id and p.name then t.nameIndex[p.name:lower()] = p.id end
  t.log[#t.log + 1] = {
    ts = time(), day = M.GetScanDay(), kind = "bought", src = "vendor",
    id = p.id, name = p.name, count = p.count,
    gross = cost, fee = 0, net = -cost,
    char = charKey(), realm = M.RealmKey(),
  }
  local max = M.C.TRADE_LOG_MAX or 20000
  while #t.log > max do table.remove(t.log, 1) end
  -- vendor buys change cost stats, not the sell-odds curve -> no DirtyAnalysis
  dropCaches()
  if M.RequestUIRefresh then M.RequestUIRefresh()
  elseif M.frame and M.frame:IsShown() and M.RefreshUI then M.RefreshUI() end
end

local function costMatches(cost, spent)
  return math.abs(cost - spent) <= math.max(1, cost * 0.01)
end

local function onMoney()
  local money = GetMoney()
  local spent = (lastMoney or money) - money
  lastMoney = money
  local now = GetTime()
  while pendingBuys[1] and now - pendingBuys[1].at > BUY_WAIT do table.remove(pendingBuys, 1) end
  if spent <= 0 or not pendingBuys[1] then return end
  for i, p in ipairs(pendingBuys) do
    if costMatches(p.cost, spent) then
      table.remove(pendingBuys, i)
      bookVendorBuy(p, spent)
      return
    end
  end
  -- several answers can land in one money update
  local sum, k = 0, 0
  for i, p in ipairs(pendingBuys) do
    sum = sum + p.cost
    if costMatches(sum, spent) then k = i; break end
    if sum > spent then break end
  end
  for _ = 1, k do
    local p = table.remove(pendingBuys, 1)
    bookVendorBuy(p, p.cost)
  end
end

local function noteVendorBuy(index, amount)
  if not tradeDB() or not index then return end
  local name, _, price, batch = M.GetMerchantItemInfo(index)
  if not name or not price or price <= 0 then return end   -- extended-cost items etc.
  batch = (batch and batch > 0) and batch or 1
  amount = (amount and amount > 0) and amount or batch     -- right-click buys one batch
  local cost = math.floor(price * (amount / batch) + 0.5)
  if cost <= 0 then return end
  local link = GetMerchantItemLink and GetMerchantItemLink(index)
  local id = link and tonumber(link:match("item:(%d+)"))
  if not pendingBuys[1] then lastMoney = GetMoney() end
  pendingBuys[#pendingBuys + 1] = { at = GetTime(), cost = cost, id = id, name = name, count = amount }
end
if type(BuyMerchantItem) == "function" then
  hooksecurefunc("BuyMerchantItem", noteVendorBuy)
  local moneyEv = CreateFrame("Frame")
  M.SafeRegister(moneyEv, "PLAYER_MONEY")
  moneyEv:SetScript("OnEvent", onMoney)
end

-- ===== Player-to-player trades ==============================================
-- The trade window moves items and gold both ways. It is booked when the
-- server says "Trade complete", from the last state both sides accepted:
--   items one way, gold the other -> "sold"/"bought" with src = "trade" (the
--     gold is split over several item types by their Fair value)
--   items both ways, or no gold   -> "given"/"received" without a price (a swap
--     or a gift must not move Avg Buy or the P/L)
--   gold only                     -> nothing to book (a gift or a loan)
-- Trades with your own characters are transfers, not trades: never logged.
local TRADE_SLOTS = 6   -- slot 7 is "will not be traded" (enchanting)
local tradeSnap, tradeSnapAt

local function isOwnChar(name)
  local chars = M.db and M.db.chars
  if not (name and name ~= "" and chars) then return false end
  local short, realm = name:match("^(.-)%-(.+)$")
  return chars[(short or name) .. "-" .. (realm or GetRealmName() or "?")] ~= nil
end
M.IsOwnChar = isOwnChar

local function readTradeSide(infoFn, linkFn)
  local byKey, list = {}, {}
  for slot = 1, TRADE_SLOTS do
    local name, _, qty = infoFn(slot)
    if name and name ~= "" then
      local link = linkFn and linkFn(slot)
      local id = link and tonumber(link:match("item:(%d+)"))
      local k = id or name
      local it = byKey[k]
      if not it then
        it = { id = id, name = name, count = 0 }
        byKey[k] = it; list[#list + 1] = it
      end
      it.count = it.count + ((qty and qty > 0) and qty or 1)
    end
  end
  return list
end

local function snapTrade()
  tradeSnap = {
    partner = UnitName and UnitName("NPC") or nil,
    mine = readTradeSide(GetTradePlayerItemInfo, GetTradePlayerItemLink),
    theirs = readTradeSide(GetTradeTargetItemInfo, GetTradeTargetItemLink),
    myGold = (GetPlayerTradeMoney and GetPlayerTradeMoney()) or 0,
    theirGold = (GetTargetTradeMoney and GetTargetTradeMoney()) or 0,
  }
  tradeSnapAt = GetTime()
end

local function unitValue(id)
  if not id then return 0 end
  local key = tostring(id)
  local s = M.GetSeries and M.GetSeries(key)
  local m = s and M.Metrics(s, key)
  if m and m.fair and m.fair > 0 then return m.fair end
  return (M.ItemValue and M.ItemValue(id)) or 0
end

-- gold over several item types, by Fair value (by units when none is priced)
local function splitTradeGold(list, gold)
  local vals, sum, units = {}, 0, 0
  for i, it in ipairs(list) do
    vals[i] = unitValue(it.id) * it.count
    sum = sum + vals[i]; units = units + it.count
  end
  local out, left = {}, gold
  for i, it in ipairs(list) do
    local share = left
    if i < #list then
      local w = (sum > 0) and (vals[i] / sum) or (it.count / units)
      share = math.min(left, math.floor(gold * w + 0.5))
    end
    out[i] = share
    left = left - share
  end
  return out
end

local function bookTrade(snap)
  local t = tradeDB(); if not t then return end
  -- the ledger books every completed trade, own characters included (transfers)
  if M.LedgerTrade then M.LedgerTrade(snap) end
  if isOwnChar(snap.partner) then return end
  local mine, theirs = snap.mine or {}, snap.theirs or {}
  if #mine == 0 and #theirs == 0 then return end
  local goldIn = (snap.theirGold or 0) - (snap.myGold or 0)
  local now, day, char, realm = time(), M.GetScanDay(), charKey(), M.RealmKey()
  local function add(kind, it, gross)
    if it.id and it.name then t.nameIndex[it.name:lower()] = it.id end
    t.log[#t.log + 1] = {
      ts = now, day = day, kind = kind, src = "trade", partner = snap.partner,
      id = it.id, name = it.name, count = it.count,
      gross = gross, fee = 0,
      net = (kind == "sold" and gross) or (kind == "bought" and -gross) or 0,
      char = char, realm = realm,
    }
  end
  if #theirs == 0 and goldIn > 0 then
    local g = splitTradeGold(mine, goldIn)
    for i, it in ipairs(mine) do add("sold", it, g[i]) end
  elseif #mine == 0 and goldIn < 0 then
    local g = splitTradeGold(theirs, -goldIn)
    for i, it in ipairs(theirs) do add("bought", it, g[i]) end
  else
    for _, it in ipairs(mine) do add("given", it, 0) end
    for _, it in ipairs(theirs) do add("received", it, 0) end
  end
  local max = M.C.TRADE_LOG_MAX or 20000
  while #t.log > max do table.remove(t.log, 1) end
  dropCaches()
  if M.RequestUIRefresh then M.RequestUIRefresh()
  elseif M.frame and M.frame:IsShown() and M.RefreshUI then M.RefreshUI() end
end
M.BookTrade = bookTrade

if type(GetTradePlayerItemInfo) == "function" and type(GetTradeTargetItemInfo) == "function" then
  local tradeEv = CreateFrame("Frame")
  for _, ev in ipairs({ "TRADE_SHOW", "TRADE_ACCEPT_UPDATE", "TRADE_PLAYER_ITEM_CHANGED",
                        "TRADE_TARGET_ITEM_CHANGED", "TRADE_MONEY_CHANGED", "PLAYER_TRADE_MONEY",
                        "UI_INFO_MESSAGE" }) do
    M.SafeRegister(tradeEv, ev)
  end
  tradeEv:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "TRADE_SHOW" then
      tradeSnap = nil
    elseif event == "UI_INFO_MESSAGE" then
      -- (messageType, message) on current clients, (message) on older ones;
      -- the window may already be closed here, so the snapshot carries it
      local msg = (type(a1) == "string") and a1 or a2
      if msg and msg == ERR_TRADE_COMPLETE and tradeSnap and GetTime() - (tradeSnapAt or 0) < 60 then
        local snap = tradeSnap
        tradeSnap = nil
        bookTrade(snap)
      end
    elseif tradeDB() then
      snapTrade()
    end
  end)
end
