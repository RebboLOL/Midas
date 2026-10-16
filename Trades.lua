-- Midas – Trades: mail-based trading history (buys / sells / returns) and a
-- "sellability" rating per item, derived purely from the auction-house mail you
-- receive. No network or posting hooks: the mailbox is the only reliable source
-- of *realized* trades, and it is persisted in SavedVariables.
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
  t.nameIndex = t.nameIndex or {}
  return t
end

local function charKey()
  return (M.CharKey and M.CharKey())
    or (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
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

-- ===== Scan the inbox and append new trade events ===========================
function M.ScanTradeMail()
  local t = tradeDB(); if not t then return end
  local n = (GetInboxNumItems and GetInboxNumItems()) or 0
  if n == 0 then return end
  local now, day = time(), M.GetScanDay()
  local realm, char = M.RealmKey(), charKey()
  local added = 0
  local occ = {}   -- counts identical mails within one pass so each gets its own key

  for i = 1, n do
    local _, _, _, subject, money, _, daysLeft = GetInboxHeaderInfo(i)
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
      if incomplete and not M._mailRescan then
        -- a won mail's price lives only in its invoice, which the server loads
        -- lazily -- if the player loots the mail before another inbox pass runs,
        -- the buy would be lost forever. One debounced re-scan shortly after
        -- gives the invoice time to arrive while the mail is still there.
        M._mailRescan = true
        C_Timer.After(2, function() M._mailRescan = nil; M.ScanTradeMail() end)
      end
      if not incomplete then
        -- dedup: a mail stays in the inbox until collected, so key on a stable
        -- expiry hour bucket (absolute expiry time does not drift across refreshes).
        -- Several identical mails (e.g. 5 stacks of the same item expiring together)
        -- share that bucket, so append a per-pass occurrence index -> each distinct,
        -- yet stable across re-opens. This was dropping returns as false "duplicates".
        local expiry = math.floor(now + (daysLeft or 0) * 86400)
        local base = kind .. "|" .. (id or name or "?") .. "|" .. money .. "|" .. math.floor(expiry / 3600)
        occ[base] = (occ[base] or 0) + 1
        local hash = base .. "#" .. occ[base]
        if not t.seen[hash] then
          t.seen[hash] = expiry
          t.log[#t.log + 1] = {
            ts = now, day = day, kind = kind,
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
          local calPrice
          if kind == "sold" then
            if t.listings and id and t.listings[id] and #t.listings[id] > 0 then calPrice = gross end
          elseif kind == "returned" then
            calPrice = listPrice
          end
          if M.CurveNote and id and calPrice and calPrice > 0 then
            local cnt = (count and count > 0) and count or 1
            local s = M.GetSeries(tostring(id))
            local f7 = s and M.Floor7 and M.Floor7(s, day)
            if f7 and f7 > 0 then
              M.CurveNote(M.LiqClass(s), (calPrice / cnt) / f7, kind == "sold")
            end
          end
        end
      end
    end
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
    M._tradeStats = nil
    M._realizedCache = nil
    M._outcomeById = nil
    M._boughtCache = nil
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
local nameToId
function M.NameToID(name)
  if not name or name == "" then return nil end
  if not nameToId then
    nameToId = {}
    for key in pairs(M.IterItems()) do
      local id = tonumber(key)
      if id then
        local nm = M.ItemName(key)
        if nm and not nm:find("^Item #") and not nm:find("^#") and not nm:find("^Pet ") then
          nameToId[nm:lower()] = id
        end
      end
    end
  end
  return nameToId[name:lower()]
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
    if e.realm == realm and e.id and (e.day or 0) >= t0
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
  M._outcomeById = M._outcomeById or {}
  local cache = M._outcomeById[realm]
  if not cache then
    cache = {}
    local t = tradeDB()
    if t then
      local cutoff = M.GetScanDay() - (M.C.SELL_WINDOW or 60)
      for _, e in ipairs(t.log) do
        if e.realm == realm and e.id and (e.day or 0) >= cutoff then
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
-- item id, plus sale count, your sales/day and the median RATIO of each sale vs the
-- 7-day floor on its sale day (what this item really clears at, price-level-free --
-- the reality brake for the Fair lift). Cached per realm; invalidated with
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
  M._realizedCache = M._realizedCache or {}
  local cache = M._realizedCache[realm]
  if not cache then
    cache = {}
    local t = tradeDB()
    if t then
      local cutoff = M.GetScanDay() - (M.C.SELL_WINDOW or 60)
      local tmp = {}
      for _, e in ipairs(t.log) do
        if e.kind == "sold" and e.realm == realm and e.id and (e.day or 0) >= cutoff then
          local cnt = (e.count and e.count > 0) and e.count or 1
          local unit = (e.gross or 0) / cnt
          if unit > 0 then
            local r = tmp[e.id]
            if not r then r = { units = {}, ratios = {}, minD = e.day, maxD = e.day }; tmp[e.id] = r end
            r.units[#r.units + 1] = unit
            local s = M.GetSeries and M.GetSeries(tostring(e.id), realm)
            local f7 = s and M.Floor7 and M.Floor7(s, e.day)
            if f7 and f7 > 0 then r.ratios[#r.ratios + 1] = unit / f7 end
            if e.day < r.minD then r.minD = e.day end
            if e.day > r.maxD then r.maxD = e.day end
          end
        end
      end
      for iid, r in pairs(tmp) do
        local span = math.max(1, (r.maxD - r.minD) + 1)
        cache[iid] = { med = medianOf(r.units), n = #r.units, perDay = #r.units / span,
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
    M._tradeStats = nil; M._realizedCache = nil; M._outcomeById = nil; M._boughtCache = nil
    if M.DirtyAnalysis then M.DirtyAnalysis() end
  end
  return touched
end

-- ===== Per-item aggregate (cached, rebuilt from the log) ====================
-- Lifetime counts for display + a windowed count used for the sellability rating.
function M.TradeStats(realm)
  realm = realm or M.RealmKey()
  M._tradeStats = M._tradeStats or {}
  if M._tradeStats[realm] then return M._tradeStats[realm] end

  local stats = {}
  local t = tradeDB()
  if t then
    local cutoff = M.GetScanDay() - (M.C.SELL_WINDOW or 60)
    for _, e in ipairs(t.log) do
      if e.realm == realm and (e.id or e.name) then
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
          s.soldStacks = s.soldStacks + 1
          s.soldUnits  = s.soldUnits + (e.count or 0)
          s.gross = s.gross + (e.gross or 0)
          s.fees  = s.fees + (e.fee or 0)
          s.net   = s.net + (e.net or 0)
          if e.day >= cutoff then s.soldW = s.soldW + 1 end
        elseif e.kind == "returned" then
          s.retStacks = s.retStacks + 1
          s.retUnits  = s.retUnits + (e.count or 0)
          if e.day >= cutoff then s.retW = s.retW + 1 end
        elseif e.kind == "bought" then
          s.boughtUnits = s.boughtUnits + (e.count or 0)
          s.net = s.net + (e.net or 0)
        elseif e.kind == "outbid" then
          s.net = s.net + (e.net or 0)
        end
        if not s.id and id then s.id = id end
        if not s.name and e.name then s.name = cleanItemName(e.name) end
        if (e.ts or 0) > s.lastTs then s.lastTs = e.ts end
      end
    end
  end
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
function M.TradeSummary(realm, windowDays)
  realm = realm or M.RealmKey()
  local cutoff = windowDays and (M.GetScanDay() - windowDays) or -math.huge
  local s = { grossSells = 0, fees = 0, buyCost = 0, net = 0, sold = 0, ret = 0, bought = 0 }
  local t = tradeDB()
  if t then
    for _, e in ipairs(t.log) do
      if e.realm == realm and (e.day or 0) >= cutoff then
        if e.kind == "sold" then
          s.grossSells = s.grossSells + (e.gross or 0)
          s.fees = s.fees + (e.fee or 0)
          s.net  = s.net + (e.net or 0)
          s.sold = s.sold + 1
        elseif e.kind == "returned" then
          s.ret = s.ret + 1
        elseif e.kind == "bought" then
          s.buyCost = s.buyCost + (e.gross or 0)
          s.net = s.net + (e.net or 0)
          s.bought = s.bought + 1
        elseif e.kind == "outbid" then
          s.net = s.net + (e.net or 0)
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
local function noteVendorBuy(index, amount)
  local t = tradeDB(); if not t then return end
  if not index then return end
  local name, _, price, batch = M.GetMerchantItemInfo(index)
  if not name or not price or price <= 0 then return end   -- extended-cost items etc.
  batch = (batch and batch > 0) and batch or 1
  amount = (amount and amount > 0) and amount or batch     -- right-click buys one batch
  local cost = math.floor(price * (amount / batch) + 0.5)
  if cost <= 0 then return end
  local link = GetMerchantItemLink and GetMerchantItemLink(index)
  local id = link and tonumber(link:match("item:(%d+)"))
  if id and name then t.nameIndex[name:lower()] = id end
  t.log[#t.log + 1] = {
    ts = time(), day = M.GetScanDay(), kind = "bought", src = "vendor",
    id = id, name = name, count = amount,
    gross = cost, fee = 0, net = -cost,
    char = charKey(), realm = M.RealmKey(),
  }
  local max = M.C.TRADE_LOG_MAX or 3000
  while #t.log > max do table.remove(t.log, 1) end
  -- vendor buys change cost stats, not the sell-odds curve -> no DirtyAnalysis
  M._tradeStats = nil
  M._boughtCache = nil
  if M.frame and M.frame:IsShown() and M.RefreshUI then M.RefreshUI() end
end
if type(BuyMerchantItem) == "function" then
  hooksecurefunc("BuyMerchantItem", noteVendorBuy)
end
