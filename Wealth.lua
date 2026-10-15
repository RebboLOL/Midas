-- Midas – Wealth: account-wide net worth (gold + item value + active auctions),
-- broken down by asset class, with a daily historical snapshot per market scope
-- (realm + faction) in MidasDB.nw.
--
-- Methodology: every character caches its bags + money (Inventory.lua) while you
-- play it (bank/mail/auctions when their window is open). NetWorth() sums those
-- caches across ALL characters, values each item at its market median (or the
-- vendor price), and adds the value still tied up in active auctions -- each
-- auction discounted by how likely it is to actually sell (high-volume mats keep
-- most of their value, expensive BoE gear is discounted hard). A snapshot is
-- written once per day so a net-worth history builds up and can be charted.
local ADDON, M = ...

-- Value of one unit, in copper: market Fair if we have AH data, otherwise the
-- item's vendor sell price (what a vendor pays you) so every item still counts.
-- If the client has not loaded the item yet, request it -- the value resolves on
-- the next refresh (Core hooks GET_ITEM_INFO_RECEIVED -> RefreshUI).
--
-- Vendor-purchasable items (learned in MidasDB.vendor) are the exception: anyone
-- can buy them from an NPC in unlimited supply, so their AH asks are almost always
-- fantasy prices that never sell -- a stack of vendor throwing knives "worth" 2g
-- apiece would fake hundreds of gold of net worth. Their market Fair only counts
-- when YOUR OWN sales prove it (limited-stock vendor items really do flip above
-- vendor price); otherwise they are worth what an NPC pays, like unpriced items.
function M.ItemValue(id)
  local series = M.GetSeries(tostring(id))
  if series then
    local vend = M.db and M.db.vendor and M.db.vendor[tonumber(id) or id]
    local trusted = (vend == nil)
    if not trusted and M.RealizedSell then
      local _, rn = M.RealizedSell(tostring(id))
      trusted = (rn or 0) >= (M.C.SELL_MIN_N or 3)
    end
    if trusted then
      local m = M.Metrics(series, tostring(id))
      if m and m.fair and m.fair > 0 then return m.fair end
    end
  end
  local base = (M.BaseID and M.BaseID(id)) or tonumber(id)
  if base then
    local name, _, _, _, _, _, _, _, _, _, sell = M.GetItemInfo(base)
    if sell and sell > 0 then return sell end
    if not name and C_Item and C_Item.RequestLoadItemDataByID then
      C_Item.RequestLoadItemDataByID(base)
    end
  end
  return 0
end

-- Asset-class bucket from the item's class id (GetItemInfo).
local ASSET = {
  [0]  = "Consumables", -- consumables
  [1]  = "Other",       -- containers / bags
  [2]  = "Gear",        -- weapons
  [4]  = "Gear",        -- armor
  [5]  = "Crafting",    -- reagents
  [6]  = "Consumables", -- projectiles / ammo
  [7]  = "Crafting",    -- trade goods
  [9]  = "Recipes",     -- recipes
  [11] = "Other",       -- quivers
}
function M.AssetClass(id)
  local base = (M.BaseID and M.BaseID(id)) or tonumber(id)
  if not base then return "Other" end
  local classID = select(12, M.GetItemInfo(base))
  if not classID then
    if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(base) end
    return "Other"
  end
  return ASSET[classID] or "Other"
end

M.ASSET_ORDER = { "Money", "Crafting", "Consumables", "Gear", "Recipes", "Auctions", "Other" }

-- Realized fraction of an auction's asking price (0..1): how likely the listing
-- actually sells. High-volume mats sell readily (small discount); expensive BoE
-- gear sells slowly (large discount). Base by class, steeper for pricey items.
local AUCTION_FACTOR = {
  Crafting = 0.90, Consumables = 0.86, Recipes = 0.62, Gear = 0.45, Other = 0.60,
}
function M.SellChance(id, unitAsk)
  local f = AUCTION_FACTOR[M.AssetClass(id)] or 0.60
  unitAsk = unitAsk or 0
  if unitAsk >= 1000000 then f = f * 0.55        -- >= 100g / unit: slow mover
  elseif unitAsk >= 200000 then f = f * 0.70     -- >= 20g
  elseif unitAsk >= 50000 then f = f * 0.85      -- >= 5g
  end
  return f
end

-- Fully valued assets for one character (reused by NetWorth and the hover tips).
-- ===== Market scope (realm + faction) =======================================
-- A PvE realm can host characters of BOTH factions on one account, and each
-- auction house only pays for its own faction. Net worth is therefore kept per
-- M.RealmKey() ("<Realm> <Faction>"): characters of the other faction are not
-- counted, and the daily history is stored per scope.
function M.CharScope()
  return (M.CharKey and M.CharKey())
    or (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

function M.CharInScope(c)
  local cs = c and c.scope
  if cs then return cs == M.RealmKey() end
  -- no scope yet (recorded before 1.2.1): such characters belong to the scope that
  -- owns the migrated history, so a new character of the OTHER faction never
  -- inherits them. They get their own stamp the next time they log in.
  local home = M.db and M.db.config and M.db.config.nwHome
  if home then return home == M.RealmKey() end
  return true
end

function M.NWHist()
  if not M.db then return {} end
  M.db.nw = M.db.nw or {}
  local s = M.RealmKey()
  M.db.nw[s] = M.db.nw[s] or {}
  return M.db.nw[s]
end

-- Intraday net-worth tail (1W chart): sorted array of { ts, t } points,
-- self-retaining (15-min buckets, 8-day window) — see RecordNetWorth.
function M.NWIntra()
  if not M.db then return {} end
  M.db.nwi = M.db.nwi or {}
  local s = M.RealmKey()
  M.db.nwi[s] = M.db.nwi[s] or {}
  return M.db.nwi[s]
end

-- one-shot: the old account-wide history belongs to the scope that wrote it. We
-- only claim it while logged in on a character that actually appears in it, so a
-- first login on the other faction cannot mislabel the whole history.
function M.NWMigrate()
  if not M.db or M.db.config.nwSplit == "20260920" then return end
  local old = M.db.networth
  if type(old) ~= "table" or next(old) == nil then
    M.db.config.nwSplit = "20260920"
    M.db.networth = nil
    return
  end
  local me, mine = M.CharScope(), false
  for _, snap in pairs(old) do
    if type(snap) == "table" and type(snap.chars) == "table" and snap.chars[me] then mine = true; break end
  end
  if not mine then return end          -- try again on a character that belongs to it
  M.db.config.nwSplit = "20260920"
  M.db.nw = M.db.nw or {}
  local key = M.RealmKey()
  local dst = M.db.nw[key] or {}
  for day, snap in pairs(old) do if dst[day] == nil then dst[day] = snap end end
  M.db.nw[key] = dst
  M.db.config.nwHome = key     -- characters without a scope belong here
  M.db.networth = nil
end

-- WoW Forever's beta client began reporting only the FIRST word of two-part
-- character names ("Deputy Willem" -> "Deputy"): such characters forked into
-- a second, history-less entry and were double-counted in the daily
-- snapshots. Fold every unambiguous short/full pair back into the full key.
-- A pair that coexists across MANY snapshot days is two real characters and
-- is left alone; the fork only ever overlaps for a few days.
function M.MergeForkedChars()
  local chars = M.db and M.db.chars
  if not chars then return end
  local moves = {}
  for sk in pairs(chars) do
    local sn, sr = sk:match("^(.-)%-(.*)$")
    if sn and sn ~= "" and not sn:find(" ", 1, true) then
      local hit, n = nil, 0
      for fk in pairs(chars) do
        if fk ~= sk then
          local fn, fr = fk:match("^(.-)%-(.*)$")
          if fn and fr == sr and fn:sub(1, #sn + 1) == sn .. " " then
            hit = fk; n = n + 1
          end
        end
      end
      if n == 1 then
        local both = 0
        for _, hist in pairs(M.db.nw or {}) do
          for _, s in pairs(hist) do
            if type(s) == "table" and type(s.chars) == "table"
               and s.chars[sk] ~= nil and s.chars[hit] ~= nil then both = both + 1 end
          end
        end
        if both <= 10 then moves[sk] = hit end
      end
    end
  end
  if next(moves) == nil then return end
  for sk, fk in pairs(moves) do
    local sc, fc = chars[sk], chars[fk]
    -- the short entry is the one the client writes NOW, so its balances are
    -- current; the full entry keeps its display name and everything the
    -- short one never recorded
    for _, f in ipairs({ "money", "bags", "bank", "mail", "auctions",
                         "bagsTs", "bankTs", "mailTs", "scope",
                         "dead", "deadTs", "deadWorth" }) do
      if sc[f] ~= nil then fc[f] = sc[f] end
    end
    chars[sk] = nil
    if M.Print then M.Print("merged duplicate character '" .. sk .. "' into '" .. fk .. "'.") end
  end
  if M.db.trade and M.db.trade.log then
    for _, e in ipairs(M.db.trade.log) do
      if e.char and moves[e.char] then e.char = moves[e.char] end
    end
  end
  -- daily snapshots: on days where BOTH keys were counted, the frozen full
  -- value was pure double counting -- remove it from the totals, then point
  -- the full key at the live (short) reading
  for _, hist in pairs(M.db.nw or {}) do
    for _, s in pairs(hist) do
      if type(s) == "table" and type(s.chars) == "table" then
        for sk, fk in pairs(moves) do
          local sv = s.chars[sk]
          if sv ~= nil then
            local fv = s.chars[fk]
            if fv ~= nil then
              s.t = math.max(0, (s.t or 0) - fv)
              if type(s.c) == "table" and type(s.cc) == "table" and type(s.cc[fk]) == "table" then
                for cls, v in pairs(s.cc[fk]) do
                  if s.c[cls] then s.c[cls] = math.max(0, s.c[cls] - v) end
                end
              end
            end
            s.chars[fk] = sv
            s.chars[sk] = nil
            if type(s.cc) == "table" then
              if fv ~= nil then s.cc[fk] = nil end
              if s.cc[sk] ~= nil then s.cc[fk] = s.cc[sk]; s.cc[sk] = nil end
            end
          end
        end
      end
    end
  end
end

function M.CharAssets(ck)
  local c = M.db and M.db.chars and M.db.chars[ck]
  if not c then return nil end
  local money = c.money or 0
  local hold = {}
  if c.bags then for id, q in pairs(c.bags) do hold[id] = (hold[id] or 0) + q end end
  if c.bank then for id, q in pairs(c.bank) do hold[id] = (hold[id] or 0) + q end end
  if c.mail then for id, q in pairs(c.mail) do hold[id] = (hold[id] or 0) + q end end
  local items, itemsTotal = {}, 0
  for id, q in pairs(hold) do
    local val = M.ItemValue(id) * q
    if val > 0 then
      items[#items + 1] = { id = id, qty = q, value = val, cls = M.AssetClass(id) }
      itemsTotal = itemsTotal + val
    end
  end
  local auctions, auctionsTotal = {}, 0
  if c.auctions then
    for id, a in pairs(c.auctions) do
      local qty, gold = a.qty or 0, a.gold or 0
      local unit = (qty > 0) and (gold / qty) or gold
      local val = math.floor(gold * M.SellChance(id, unit))
      if val > 0 then
        auctions[#auctions + 1] = { id = id, qty = qty, value = val, ask = gold }
        auctionsTotal = auctionsTotal + val
      end
    end
  end
  table.sort(items, function(a, b) return a.value > b.value end)
  table.sort(auctions, function(a, b) return a.value > b.value end)
  return {
    name = c.name or ck:match("^(.-)%-") or ck,
    money = money, items = items, auctions = auctions,
    itemsTotal = itemsTotal, auctionsTotal = auctionsTotal,
    total = money + itemsTotal + auctionsTotal,
    seen = (c.money ~= nil) or (c.bags ~= nil) or (c.auctions ~= nil),
  }
end

-- Account-wide net worth, with per-class item lists for the breakdown tooltips.
function M.NetWorth()
  if not M.db then return nil end
  local classes = {}
  for _, name in ipairs(M.ASSET_ORDER) do classes[name] = 0 end
  local clsItems, perChar = {}, {}
  local money, itemsTotal, auctionsTotal = 0, 0, 0
  local itemQty, itemVal = {}, {}   -- account-wide per-item totals (for iq snapshots)
  local function bucket(cls, id, qty, value)
    classes[cls] = (classes[cls] or 0) + value
    itemQty[id] = (itemQty[id] or 0) + qty
    itemVal[id] = (itemVal[id] or 0) + value
    local b = clsItems[cls]; if not b then b = {}; clsItems[cls] = b end
    local e = b[id]; if not e then e = { id = id, qty = 0, value = 0 }; b[id] = e end
    e.qty = e.qty + qty; e.value = e.value + value
  end
  local grave, graveTotal = {}, 0
  for ck, c in pairs(M.db.chars or {}) do
    local a = nil
    if M.CharInScope(c) then a = M.CharAssets(ck) end
    if a and c.dead then
      -- graveyard: fallen (HC) characters rest OUTSIDE the account total, in
      -- their own sum. Everything is kept, so their items stay browsable.
      grave[#grave + 1] = { key = ck, name = a.name, total = a.total,
                            deadTs = c.deadTs, deadWorth = c.deadWorth }
      graveTotal = graveTotal + a.total
    elseif a then
      -- per-character class split (for the character-level stacked worth chart)
      local ccls = { Money = a.money }
      for _, it in ipairs(a.items) do
        local cl = it.cls or "Other"
        ccls[cl] = (ccls[cl] or 0) + it.value
      end
      if a.auctionsTotal > 0 then ccls.Auctions = a.auctionsTotal end
      perChar[ck] = { key = ck, name = a.name, total = a.total, money = a.money,
                      items = a.itemsTotal, auctions = a.auctionsTotal, seen = a.seen,
                      cls = ccls }
      money = money + a.money
      itemsTotal = itemsTotal + a.itemsTotal
      auctionsTotal = auctionsTotal + a.auctionsTotal
      classes.Money = classes.Money + a.money
      for _, it in ipairs(a.items) do bucket(it.cls or "Other", it.id, it.qty, it.value) end
      for _, it in ipairs(a.auctions) do bucket("Auctions", it.id, it.qty, it.value) end
    end
  end
  local classItems = {}
  for cls, b in pairs(clsItems) do
    local arr = {}
    for _, e in pairs(b) do arr[#arr + 1] = e end
    table.sort(arr, function(x, y) return x.value > y.value end)
    for i = #arr, 25, -1 do arr[i] = nil end   -- keep the top 24 per class (tall windows show ~20 rows)
    classItems[cls] = arr
  end
  table.sort(grave, function(x, y) return x.total > y.total end)
  return {
    total = money + itemsTotal + auctionsTotal,
    money = money, itemsTotal = itemsTotal, auctionsTotal = auctionsTotal,
    classes = classes, classItems = classItems, chars = perChar,
    itemQty = itemQty, itemVal = itemVal,
    grave = grave, graveTotal = graveTotal, graveCount = #grave,
  }
end

-- Store today's snapshot (one bucket per day, latest computation wins).
-- Refresh the CURRENT character's bags + money first, so the live character is
-- always accurate (other characters are as fresh as you last played them).
function M.RecordNetWorth()
  if M.CacheBags then M.CacheBags() end
  if M.CacheMoney then M.CacheMoney() end
  local nw = M.NetWorth()
  if not nw then return nil end
  local hist = M.NWHist()
  local pc, pcc = {}, {}
  for ck, info in pairs(nw.chars or {}) do
    pc[ck] = info.total
    pcc[ck] = info.cls          -- per-char class split (character-level stacked chart)
  end
  -- per-item quantities of the most valuable holdings (top 200 worth >= 0.5g):
  -- powers TRUE per-day quantities in the item holding chart from now on, while
  -- keeping the snapshot size bounded
  local iq = {}
  do
    local ids = {}
    for id, val in pairs(nw.itemVal or {}) do
      if val >= 5000 then ids[#ids + 1] = id end
    end
    table.sort(ids, function(a, b) return (nw.itemVal[a] or 0) > (nw.itemVal[b] or 0) end)
    for i = 1, math.min(#ids, 200) do iq[ids[i]] = nw.itemQty[ids[i]] end
  end
  hist[M.GetScanDay()] = { t = nw.total, m = nw.money, c = nw.classes,
                                    chars = pc, cc = pcc, iq = iq,
                                    g = (nw.graveTotal or 0) > 0 and nw.graveTotal or nil }
  -- intraday tail (1W chart): 15-min bucket, latest wins inside the bucket.
  -- The bucket anchor is the FIRST write's ts — refreshes fire every minute,
  -- so moving ts on replace would keep one point sliding forever.
  local ni, nowT = M.NWIntra(), time()
  local lastP = ni[#ni]
  if lastP and (nowT - lastP.ts) < 900 then
    lastP.t, lastP.c = nw.total, nw.classes   -- class split powers intraday stack bars
  else
    ni[#ni + 1] = { ts = nowT, t = nw.total, c = nw.classes }
  end
  local icut = nowT - 8 * 86400
  while ni[1] and ni[1].ts < icut do table.remove(ni, 1) end
  return nw
end

-- Move a character to the graveyard (HC characters die...). Unlike the old
-- permanent delete, NOTHING is removed: the character just stops counting
-- toward the account total and rests in the graveyard sum instead. Logging in
-- on the character (Inventory.lua) or the Restore button brings it back.
function M.GraveyardChar(ck)
  local c = M.db and M.db.chars and ck and M.db.chars[ck]
  if not c or c.dead then return false end
  local a = M.CharAssets(ck)
  c.dead = true
  c.deadTs = time()
  c.deadWorth = (a and a.total) or 0    -- worth at the time of death, for the record
  M.Print(tostring((a and a.name) or ck) .. " rests in the graveyard now - its worth no longer counts toward the total.")
  if M.NWNavReset then M.NWNavReset() end   -- close the whole drill-down stack
  if M.frame and M.frame:IsShown() and M.RefreshWealth then M.RefreshWealth() end
  return true
end

function M.ReviveChar(ck)
  local c = M.db and M.db.chars and ck and M.db.chars[ck]
  if not c or not c.dead then return false end
  c.dead, c.deadTs, c.deadWorth = nil, nil, nil
  M.Print(tostring(c.name or ck) .. " returned from the graveyard - counting toward the total again.")
  if M.frame and M.frame:IsShown() and M.RefreshWealth then M.RefreshWealth() end
  return true
end

-- Change in a character's net worth vs a reference snapshot. With refDay the
-- comparison uses exactly that day (the tab's shared timeframe); without it,
-- the most recent PRIOR daily snapshot that recorded the character.
-- Returns (deltaCopper, refDay), or nil if there's no usable reference yet.
function M.CharDeltaSince(ck, currentTotal, refDay)
  local hist = M.NWHist()
  if not hist then return nil end
  if refDay then
    local s = hist[refDay]
    local v = s and s.chars and s.chars[ck]
    if v == nil then return nil end
    return (currentTotal or 0) - v, refDay
  end
  local today = M.GetScanDay()
  local bestDay, bestVal
  for day, s in pairs(hist) do
    if day < today and s.chars and s.chars[ck] ~= nil then
      if not bestDay or day > bestDay then bestDay, bestVal = day, s.chars[ck] end
    end
  end
  if not bestDay then return nil end
  return (currentTotal or 0) - bestVal, bestDay
end

-- ===== Net-worth attribution ("what moved it") ==============================
-- Decomposes the account total's change between a reference snapshot R (picked
-- from the shared chart timeframe, config.chartRange) and NOW into per-item
-- stock and market effects plus gold and an honest residual, and aggregates
-- realized trading per item over the same window. A pure read-model over
-- existing data (snapshots, price archive, trade log) -- nothing is persisted.

-- Reference day for the current chart range.
--   "t"  -> oldest snapshot inside the window (the chart's first visible
--           point, so the hero delta equals the chart's endpoints); fallback:
--           the newest snapshot BEFORE the window (labels name the real day)
--   "iq" -> same, but only snapshots carrying per-item quantities (recorded
--           since v1.0.9) -- the base for the item movers
function M.AttribRefDay(kind)
  local hist = M.NWHist()
  if not hist then return nil end
  local today = M.GetScanDay()
  local days = M.ChartRangeDays and M.ChartRangeDays() or nil
  local minDay = days and (today - days + 1) or nil
  local inWin, before
  for day, s in pairs(hist) do
    if type(s) == "table" and day < today
       and (kind ~= "iq" or (type(s.iq) == "table" and next(s.iq) ~= nil)) then
      if not minDay or day >= minDay then
        if not inWin or day < inWin then inWin = day end
      elseif not before or day > before then
        before = day
      end
    end
  end
  return inWin or before
end

-- One-day fair at a historic day: the same clamp maths as FairSeries
-- (Logic.lua), evaluated for a single day -- keeps the reconstruction in the
-- same valuation family as today's net worth without O(days^2) work.
local function fairAt(series, key, day)
  local m = M.Metrics(series, key)
  if not (m and m.rstar) then return nil end
  local b = M.DemandBase and M.DemandBase(series, day)
  local f7 = M.Floor7 and M.Floor7(series, day)
  if not (b and b > 0 and f7 and f7 > 0) then return nil end
  local liftMax = (M.C and M.C.FAIR_LIFT_MAX) or 1.10
  local adj = (f7 * m.rstar) / b
  if adj < 1 then adj = 1 elseif adj > liftMax then adj = liftMax end
  return b * adj
end

-- Value change of everything you HOLD (items only, gold excluded) over the
-- last `win` days: today's holdings value minus the snapshot's, both from the
-- frozen daily snapshots (no price reconstruction involved). Falls back to
-- the oldest snapshot when the history is younger. Returns delta, refDay.
function M.HoldingsDelta(nw, win)
  nw = nw or (M.NetWorth and M.NetWorth())
  local hist = nw and M.NWHist and M.NWHist()
  if not (nw and hist) then return nil end
  local want = M.GetScanDay() - (win or (M.C and M.C.SELL_WINDOW) or 60)
  local best, oldest
  for day, s in pairs(hist) do
    if type(s.t) == "number" and type(s.m) == "number" then
      if day <= want and (not best or day > best) then best = day end
      if not oldest or day < oldest then oldest = day end
    end
  end
  local refDay = best or oldest
  local snap = refDay and hist[refDay]
  if not snap then return nil end
  return ((nw.total or 0) - (nw.money or 0)) - ((snap.t or 0) - (snap.m or 0)), refDay
end

-- Bought for own use over the window: units bought that were neither resold
-- nor are still held (equips put on, mats used up), valued at their actual
-- buy price. qR comes from the reference snapshot's iq; items below its gate
-- read conservatively as zero consumption.
function M.ConsumedCost(nw, win)
  nw = nw or (M.NetWorth and M.NetWorth())
  local hist = nw and M.NWHist and M.NWHist()
  if not (nw and hist and M.db and M.db.trade) then return nil end
  local want = M.GetScanDay() - (win or (M.C and M.C.SELL_WINDOW) or 60)
  local best, oldest
  for day, s in pairs(hist) do
    if type(s.iq) == "table" and next(s.iq) then
      if day <= want and (not best or day > best) then best = day end
      if not oldest or day < oldest then oldest = day end
    end
  end
  local refDay = best or oldest
  local snap = refDay and hist[refDay]
  if not snap then return nil end
  local realm = M.RealmKey()
  local buyQ, buyC, sellQ = {}, {}, {}
  for _, e in ipairs(M.db.trade.log or {}) do
    if e.realm == realm and e.day and e.day > refDay and e.id then
      if e.kind == "bought" then
        buyQ[e.id] = (buyQ[e.id] or 0) + (e.count or 0)
        buyC[e.id] = (buyC[e.id] or 0) + (e.gross or 0)
      elseif e.kind == "sold" then
        sellQ[e.id] = (sellQ[e.id] or 0) + (e.count or 0)
      end
    end
  end
  local total = 0
  for id, bq in pairs(buyQ) do
    if bq > 0 then
      local qH = (nw.itemQty and nw.itemQty[id]) or 0
      local qR = (snap.iq and snap.iq[id]) or 0
      local gone = qR + bq - qH               -- units that left the stock
      local consumed = math.min(bq, math.max(0, gone - (sellQ[id] or 0)))
      if consumed > 0 then
        total = total + consumed * (buyC[id] / bq)
      end
    end
  end
  return total, refDay
end

-- "/midas band": dump the Trades-band HOLDINGS number and the attribution to
-- chat, so a wrong-looking value can be dissected in the state that made it.
function M.BandDebug()
  local nw = M.NetWorth and M.NetWorth()
  if not nw then M.Print("band: no net worth") return end
  local win = (M.C and M.C.SELL_WINDOW) or 60
  local function pm(v) return ((v or 0) >= 0 and "+" or "-") .. M.MoneyPlain(math.abs(v or 0)) end
  local hd, hrd = M.HoldingsDelta and M.HoldingsDelta(nw, win)
  if hd then
    M.Print(string.format("band: holdings %s since day %s (%s)  itemsNow %s",
      pm(hd), tostring(hrd), M.DayLabel(hrd),
      M.MoneyPlain((nw.total or 0) - (nw.money or 0))))
    -- the bridge to the net-worth change: dNW = holdings + gold flow, and the
    -- gold flow splits into realized trading and everything else (repairs,
    -- flights, lost deposits, quest gold)
    local snap = M.NWHist and M.NWHist()[hrd]
    local sm = M.TradeSummary and M.TradeSummary(M.RealmKey(), win)
    if snap and sm then
      local dNW = (nw.total or 0) - (snap.t or 0)
      local dGold = (nw.money or 0) - (snap.m or 0)
      M.Print(string.format("band: bridge  nw %s = holdings %s + gold %s;  gold = trades %s + non-trading %s",
        pm(dNW), pm(hd), pm(dGold), pm(sm.net), pm(dGold - (sm.net or 0))))
    end
    local cons = M.ConsumedCost and M.ConsumedCost(nw, win)
    if cons and cons > 0 then
      M.Print("band: consumed " .. M.MoneyPlain(cons) .. " (bought, neither resold nor in stock)")
    end
  end
  local at = M.WorthAttribution and M.WorthAttribution(nw, M.GetScanDay() - win)
  if not at then M.Print("band: no attribution (no item snapshots yet)") return end
  M.Print(string.format("band: refDay %s (%s)  market %s  stock %s  gold %s  residual %s  nwTotal %s",
    tostring(at.refDay), M.DayLabel(at.refDay), pm(at.market), pm(at.stock),
    pm(at.gold), pm(at.residual), M.MoneyPlain(nw.total or 0)))
  local items = {}
  for i = 1, #at.items do items[i] = at.items[i] end
  table.sort(items, function(a, b) return math.abs(a.dMarket or 0) > math.abs(b.dMarket or 0) end)
  for i = 1, math.min(6, #items) do
    local e = items[i]
    M.Print(string.format("  %s   q %d \194\187 %d   pR %s   pH %s   mkt %s",
      (M.ItemName and M.ItemName(tostring(e.id))) or tostring(e.id),
      e.qR or 0, e.qH or 0, M.MoneyPlain(e.pR or 0), M.MoneyPlain(e.pH or 0), pm(e.dMarket)))
  end
end

-- Full attribution result. nw = a fresh M.NetWorth()/RecordNetWorth() table
-- (the live side is never cached, so the latest-wins snapshot design can't
-- serve stale numbers). Per item, with R->H the reference and current state:
--   dStock  = (qH - qR) * pR   -- bought/sold/crafted/consumed
--   dMarket = qH * (pH - pR)   -- the market moved under what you hold
--   trade   = realized gold from AH/vendor trades of the item in the window
--   pnl     = dStock + dMarket + trade  -- true P&L since R (ranks the list)
--   buyQ/buyC, sellQ/sellN = the window's buys and sells per side
--   cons/consCost = own consumption: bought, neither resold nor still held
-- Reference prices are cached per (analysis generation, refDay) -- the only
-- expensive side (DemandBase/Floor7 per item).
function M.WorthAttribution(nw, refDayOverride)
  nw = nw or (M.NetWorth and M.NetWorth())
  if not nw then return nil end
  local hist = M.NWHist()
  -- refDayOverride: attribute against an explicitly picked snapshot day (the
  -- day-view's "what moved since that day?") instead of the chart timeframe.
  -- Falls back to the nearest EARLIER iq snapshot if the picked day has none.
  local refDay
  if refDayOverride and hist then
    local best, oldest
    for day, s in pairs(hist) do
      if type(s.iq) == "table" and next(s.iq) then
        if day <= refDayOverride and (not best or day > best) then best = day end
        if not oldest or day < oldest then oldest = day end
      end
    end
    -- no snapshot reaches back that far: measure from the oldest one instead
    -- of silently falling back to the chart timeframe
    refDay = best or oldest
  end
  refDay = refDay or M.AttribRefDay("iq")
  local snap = refDay and hist and hist[refDay]
  if not snap then return nil end
  local realm = M.RealmKey()

  local cache = M._nwAttrib
  if not (cache and cache.gen == (M._analysisGen or 0) and cache.refDay == refDay) then
    cache = { gen = M._analysisGen or 0, refDay = refDay, p = {} }
    M._nwAttrib = cache
  end
  local pcache = cache.p

  -- realized trading + quantity deltas over (refDay, today], one log pass.
  -- buy/sell quantities and gold are kept per side too: the hover itemizes the
  -- window (bought x avg, sold net, consumed) so the Total can be re-checked.
  local tradeBy, qDelta = {}, {}
  local buyQ, buyC, sellQ, sellN = {}, {}, {}, {}
  local soldSum, boughtSum = 0, 0
  for _, e in ipairs((M.db.trade and M.db.trade.log) or {}) do
    if e.realm == realm and e.day and e.day > refDay
       and (e.kind == "sold" or e.kind == "bought") then
      local id = e.id or (M.NameToID and e.name and M.NameToID(e.name)) or nil
      if e.kind == "sold" then
        soldSum = soldSum + (e.net or 0)
        if id then
          tradeBy[id] = (tradeBy[id] or 0) + (e.net or 0)
          qDelta[id] = (qDelta[id] or 0) - (e.count or 0)
          sellQ[id] = (sellQ[id] or 0) + (e.count or 0)
          sellN[id] = (sellN[id] or 0) + (e.net or 0)
        end
      else
        boughtSum = boughtSum + (e.gross or 0)
        if id then
          tradeBy[id] = (tradeBy[id] or 0) - (e.gross or 0)
          qDelta[id] = (qDelta[id] or 0) + (e.count or 0)
          buyQ[id] = (buyQ[id] or 0) + (e.count or 0)
          buyC[id] = (buyC[id] or 0) + (e.gross or 0)
        end
      end
    end
  end

  -- union of ids: reference holdings + today's holdings (sold-out items with
  -- qH = 0 must appear as losers)
  local ids = {}
  for id in pairs(snap.iq or {}) do ids[id] = true end
  for id in pairs(nw.itemQty or {}) do ids[id] = true end

  local items, market, stock = {}, 0, 0
  for id in pairs(ids) do
    local key = tostring(id)
    local qH = (nw.itemQty and nw.itemQty[id]) or 0
    local pH
    if qH > 0 and nw.itemVal and nw.itemVal[id] then
      pH = nw.itemVal[id] / qH                    -- exactly today's valuation
    else
      pH = (M.ItemValue and M.ItemValue(id)) or 0
    end
    local qR = snap.iq and snap.iq[id]
    if qR == nil then
      -- below the 0.5g snapshot gate at R: reconstruct from trades, else
      -- assume unchanged (farming/crafting stays in the residual, honestly)
      local d = qDelta[id]
      qR = d and math.max(0, qH - d) or qH
    end
    local pR = pcache[id]
    if pR == nil then
      local series = M.GetSeries and M.GetSeries(key)
      pR = (series and fairAt(series, key, refDay)) or false
      pcache[id] = pR
    end
    if not pR or pR <= 0 then pR = pH end         -- vendor/no data: quantity effect only
    -- reconstruction sanity: a junk scan history (vendor ammo listed at gold
    -- prices) can hand fairAt a reference price hundreds of times today's
    -- valuation and blow the split up by thousands of gold. With no valuation
    -- today the position cannot carry a market/quantity split at all (the
    -- difference stays in the residual, honestly unexplained); otherwise the
    -- reference may not leave a x10 band around today's price - real moves
    -- keep their direction and a big (capped) contribution, junk gets tamed.
    if not pH or pH <= 0 then pR, pH = 0, 0
    elseif pR > pH * 10 then pR = pH * 10
    elseif pR < pH / 10 then pR = pH / 10 end
    local dStock = (qH - qR) * pR
    local dMarket = qH * (pH - pR)
    stock = stock + dStock
    market = market + dMarket
    local dTot = dStock + dMarket
    local trade = tradeBy[id] or 0
    -- true P&L of the position: holdings change PLUS the realized cash of its
    -- trades. An at-market buy nets ~0 (stack value in, purchase cost out), a
    -- bargain buy is an immediate gain, consumption stays a loss.
    local pnl = dTot + trade
    -- own consumption (the ConsumedCost rule): bought units that neither sold
    -- on nor sit in the stock were used up - priced at the window's avg buy
    local bq, sq = buyQ[id] or 0, sellQ[id] or 0
    local cons = math.min(bq, math.max(0, qR + bq - sq - qH))
    local consCost = cons > 0 and math.floor(cons * (buyC[id] or 0) / bq) or 0
    if math.abs(pnl) >= 1000 or math.abs(trade) >= 1000 then
      items[#items + 1] = { id = id, qR = qR, qH = qH, pR = pR, pH = pH,
                            dStock = dStock, dMarket = dMarket,
                            trade = trade, dTotal = dTot, pnl = pnl,
                            buyQ = bq, buyC = buyC[id] or 0, sellQ = sq,
                            sellN = sellN[id] or 0, cons = cons, consCost = consCost }
    end
  end
  table.sort(items, function(a, b) return math.abs(a.pnl) > math.abs(b.pnl) end)

  local dTotal = (nw.total or 0) - (snap.t or 0)
  local gold = (nw.money or 0) - (snap.m or 0)
  return {
    refDay = refDay,
    tRefDay = M.AttribRefDay("t") or refDay,
    dTotal = dTotal, market = market, stock = stock, gold = gold,
    residual = dTotal - market - stock - gold,
    trading = { sold = soldSum, bought = boughtSum, net = soldSum - boughtSum },
    items = items,
  }
end

-- Chat diagnostic / manual refresh: /midas worth
function M.PrintWorth()
  local nw = M.RecordNetWorth()
  if not nw then return end
  M.Print("Net worth (" .. M.RealmKey() .. " characters): " .. M.MoneyPlain(nw.total))
  M.Print(string.format("   gold %s   \194\183   items %s   \194\183   auctions %s",
    M.MoneyPlain(nw.money), M.MoneyPlain(nw.itemsTotal), M.MoneyPlain(nw.auctionsTotal)))
  local chars = {}
  for _, info in pairs(nw.chars) do chars[#chars + 1] = info end
  table.sort(chars, function(a, b) return a.total > b.total end)
  for _, info in ipairs(chars) do
    if info.seen or info.total > 0 then
      print(string.format("   %s  %s", info.name, M.MoneyPlain(info.total)))
    else
      print(string.format("   %s  |cff808080not cached yet - log in on it once|r", info.name))
    end
  end
  if (nw.graveCount or 0) > 0 then
    M.Print(string.format("graveyard: %d fallen  \194\183  %s  (not in the total)",
      nw.graveCount, M.MoneyPlain(nw.graveTotal or 0)))
  end
end

-- Daily snapshot on login (after data has loaded) and on logout.
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_LOGOUT")
ev:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    C_Timer.After(5, function() if M.RecordNetWorth then M.RecordNetWorth() end end)
  elseif M.RecordNetWorth then
    M.RecordNetWorth()
  end
end)
