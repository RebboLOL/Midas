-- Midas – Crafting: what an item costs to make, what it disenchants into and
-- who of your characters knows the recipe. Recipes come from the game's own
-- client tables (Recipes.lua). Every price comes twice, side by side: "now"
-- (cheapest listing of the newest scan, Fair when the item is not listed) and
-- "fair". Each level of a recipe is bought or made, whichever is cheaper.
local ADDON, M = ...
local floor, min, max = math.floor, math.min, math.max

local AH_CUT    = 0.05
local MAX_DEPTH = 6
local NOW, FAIR = 1, 2

-- Crafting is in beta: one switch (Settings / Crafting tab, config.craftOff)
-- turns the tab, the Crafted price in Charts, the tooltip craft lines and the
-- craft-tree links off. Known recipes keep being recorded either way.
function M.CraftingOn()
  return not (M.db and M.db.config and M.db.config.craftOff == true)
end

-- the one setter behind both checkboxes; redraws what reads the switch
function M.SetCraftingOn(on)
  if not (M.db and M.db.config) then return end
  if on then M.db.config.craftOff = nil else M.db.config.craftOff = true end
  if M.HideCraftPeek then M.HideCraftPeek() end
  if M.HideCraftPopups then M.HideCraftPopups() end
  if M.RerenderCharts then M.RerenderCharts() end
  if M.RefreshUI then M.RefreshUI() end
end

-- Recipes on a cooldown (transmutes, Mooncloth ...) cannot be made at will: one
-- Arcanite Bar every two days does not supply a craft. Spell -> seconds per
-- recipe set, from the game's SpellCooldowns table of the builds the recipes
-- come from (the larger of own and category cooldown).
local RECIPE_CD = {
  era = {
    [25146] = 600, [22430] = 7200, [11479] = 86400, [17559] = 86400, [17560] = 86400, [17561] = 86400,
    [17562] = 86400, [17563] = 86400, [17564] = 86400, [17565] = 86400, [17566] = 86400, [11480] = 172800,
    [17187] = 172800, [18560] = 345600,
  },
  tbc = {
    [11479] = 72000, [11480] = 72000, [17559] = 72000, [17560] = 72000, [17561] = 72000, [17562] = 72000,
    [17563] = 72000, [17564] = 72000, [17565] = 72000, [17566] = 72000, [28566] = 72000, [28567] = 72000,
    [28568] = 72000, [28569] = 72000, [28580] = 72000, [28581] = 72000, [28582] = 72000, [28583] = 72000,
    [28584] = 72000, [28585] = 72000, [29688] = 72000, [32765] = 72000, [32766] = 72000, [47280] = 72000,
    [28027] = 172800, [28028] = 172800, [26751] = 331200, [31373] = 331200, [36686] = 331200,
  },
  forever = {
    [25146] = 600, [11479] = 3600, [11480] = 3600, [1302508] = 3600, [22430] = 7200, [17559] = 82800,
    [17560] = 82800, [17561] = 82800, [17562] = 82800, [17563] = 82800, [17564] = 82800, [17565] = 82800,
    [17566] = 82800, [17187] = 169200, [1317279] = 169200, [18560] = 342000,
  },
}

-- ===== Recipe index (decoded on first use) ==================================
local R
function M.Recipes()
  if R then return R end
  R = { byItem = {}, bySpell = {}, usedIn = {}, items = {}, prof = {}, vend = {}, n = 0,
        enchants = {}, enchBySpell = {}, enchIn = {}, teach = {}, taughtBy = {} }
  local D = M.RECIPE_DATA
  if type(D) ~= "table" then return R end
  R.prof, R.vend, R.build, R.flavor = D.prof or {}, D.vend or {}, D.build, D.flavor
  -- a `cd` table in the recipe data, once it carries one, replaces the list above
  local cds = (type(D.cd) == "table" and D.cd) or RECIPE_CD[D.flavor or M.CLIENT_FLAVOR or "era"] or {}
  for line in (D.rec or ""):gmatch("[^\n]+") do
    local item, lo, hi, prof, yel, grey, spell, mats =
      line:match("^(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)|(.+)$")
    if item then
      local rec = { item = tonumber(item), lo = tonumber(lo), hi = tonumber(hi), prof = tonumber(prof),
                    yellow = tonumber(yel), grey = tonumber(grey), spell = tonumber(spell), mats = {} }
      rec.yield = (rec.lo + rec.hi) / 2
      local cd = tonumber(cds[rec.spell])
      if cd and cd > 0 then rec.cd = cd end
      for m, c in mats:gmatch("(%d+)%*(%d+)") do
        local mid = tonumber(m)
        rec.mats[#rec.mats + 1] = { id = mid, n = tonumber(c) }
        local u = R.usedIn[mid]
        if not u then u = {}; R.usedIn[mid] = u end
        u[#u + 1] = rec
      end
      local b = R.byItem[rec.item]
      if not b then b = {}; R.byItem[rec.item] = b; R.items[#R.items + 1] = rec.item end
      b[#b + 1] = rec
      R.bySpell[rec.spell] = rec
      R.n = R.n + 1
    end
  end
  -- enchants: a profession spell that enchants an item instead of making one
  -- (Enchant Weapon - Crusader); no product, so only "what goes into it"
  for line in (D.ench or ""):gmatch("[^\n]+") do
    local spell, prof, yel, grey, mats = line:match("^(%d+):(%d+):(%d+):(%d+)|(.+)$")
    if spell then
      local rec = { spell = tonumber(spell), prof = tonumber(prof), yellow = tonumber(yel),
                    grey = tonumber(grey), mats = {}, enchant = true }
      for m, c in mats:gmatch("(%d+)%*(%d+)") do
        local mid = tonumber(m)
        rec.mats[#rec.mats + 1] = { id = mid, n = tonumber(c) }
        local u = R.enchIn[mid]
        if not u then u = {}; R.enchIn[mid] = u end
        u[#u + 1] = rec
      end
      R.enchants[#R.enchants + 1] = rec
      R.enchBySpell[rec.spell] = rec
    end
  end
  -- recipe items (Recipe:, Pattern:, Plans: ...): item -> the recipe it
  -- teaches, and per product the recipe items that teach one of its recipes
  for key, spell in pairs(type(D.teach) == "table" and D.teach or {}) do
    local rec, item = R.bySpell[tonumber(spell)], tonumber(key)
    if rec and item then
      R.teach[item] = rec
      local t = R.taughtBy[rec.item]
      if not t then t = {}; R.taughtBy[rec.item] = t end
      t[#t + 1] = item
    end
  end
  for _, t in pairs(R.taughtBy) do table.sort(t) end
  D.rec, D.ench, D.teach = nil, nil, nil   -- the index is all we need from here on
  return R
end

-- name and icon of an enchant spell (the client knows every spell, learned or not)
function M.EnchantName(spell)
  if C_Spell and C_Spell.GetSpellName then
    local ok, n = pcall(C_Spell.GetSpellName, spell)
    if ok and n then return n end
  end
  if GetSpellInfo then
    local ok, n = pcall(GetSpellInfo, spell)
    if ok and n then return n end
  end
  return "Enchant #" .. tostring(spell)
end

local ENCH_ICON = "Interface\\Icons\\Trade_Engraving"
function M.EnchantIcon(spell)
  if C_Spell and C_Spell.GetSpellTexture then
    local ok, t = pcall(C_Spell.GetSpellTexture, spell)
    if ok and t then return t end
  end
  if GetSpellTexture then
    local ok, t = pcall(GetSpellTexture, spell)
    if ok and t then return t end
  end
  return ENCH_ICON
end

-- "4 recipes, 2 enchants" / "1 recipe" / "3 enchants"
function M.UsedInText(nRec, nEnch)
  local t = {}
  if nRec > 0 then t[#t + 1] = nRec .. (nRec == 1 and " recipe" or " recipes") end
  if nEnch > 0 then t[#t + 1] = nEnch .. (nEnch == 1 and " enchant" or " enchants") end
  return table.concat(t, ", ")
end

-- how many distinct recipes and enchants use a material
function M.UsedInCount(id)
  local Rx = M.Recipes()
  local seen, n = {}, 0
  for _, rec in ipairs(Rx.usedIn[id] or {}) do
    if not seen[rec.item] then seen[rec.item] = true; n = n + 1 end
  end
  return n, #(Rx.enchIn[id] or {})
end

function M.ProfName(id)
  local p = M.Recipes().prof
  return (p and p[id]) or "Crafting"
end

-- ===== Prices ===============================================================
local function metrics(id)
  local key = tostring(id)
  local s = M.GetSeries and M.GetSeries(key)
  if not s then return nil end
  return M.Metrics(s, key)
end
M.CraftMetrics = metrics

-- one unit to BUY, both ways: now, fair, source ("vendor" / "ah" / "est").
-- A merchant price only wins where it is the cheaper way to buy: the WoW
-- Forever Black Market sells herbs and crystals at a 50g cap, far above the AH.
function M.UnitPrice(id)
  id = tonumber(id)
  if not id then return nil end
  local v = M.VendorPrice and M.VendorPrice(id)
  if not (v and v > 0) then v = nil end
  local m = metrics(id)
  if m and ((m.fair and m.fair > 0) or (m.cur and m.cur > 0)) then
    local fair = (m.fair and m.fair > 0) and m.fair or m.cur
    local now = m.cur
    if not now or now <= 0 or (M.NotListed and M.NotListed(m)) then now = fair end
    if v then
      local n = math.min(now, v)
      return n, math.min(fair, v), (n < v) and "ah" or "vendor"
    end
    return now, fair, "ah"
  end
  if v then return v, v, "vendor" end
  local est = M.Recipes().vend[id]
  if est then return est, est, "est" end
  return nil, nil, nil
end

-- one unit to SELL on the AH (before the cut), both ways
function M.SellPrice(id)
  local m = metrics(id)
  if not m then return nil end
  local fair = (m.fair and m.fair > 0) and m.fair or nil
  local now = m.cur
  if not now or now <= 0 or (M.NotListed and M.NotListed(m)) then now = fair end
  return now, fair or now
end

-- ===== Cost of making =======================================================
-- cost(id) = the cheaper of buying it and making it from its cheapest recipe;
-- `path` keeps a chain from feeding on itself (transmute circles), `memo`
-- remembers each decision of one calculation for the tree view.
-- A MATERIAL that has a price is never made by a recipe on a cooldown (1.3.4,
-- rec.cd): such a recipe only counts for a material without any price. The
-- item a calculation is about keeps all its recipes.
-- "Buy unknown" (config.craftBuyUnknown): a material that has a price is only
-- made when one of your characters knows its recipe. `kset` holds what they
-- can make for the current cache generation - nil while the switch is off or
-- no profession window was read yet.
-- Your own choice (Crafting tab, table view): `force` = { [itemID] = "make" |
-- "buy" } for the materials of the item a calculation is about. It wins over
-- Make or buy and Buy unknown; a choice the item cannot follow (no recipe, no
-- price) is left out. Set by M.CraftCost for its own calculation only.
local kset
local force
local cost

-- A past day instead of the newest prices (M.CraftCostOn sets it for its own
-- calculation only): a material's AH price is its daily low of that day, or of
-- its last scan day up to DAY_LOOKBACK days before - never a later day, so a
-- material that only reached the auction house later has no price yet. A
-- merchant price wins where it is cheaper, as in M.UnitPrice; without an AH
-- price the merchant price or the recipe data's estimate counts.
-- A moment instead (`priceTs`, M.CraftCostAt, the 1D chart): the material's
-- price is its newest scan at or before that moment - an own scan or a server
-- point (M.ServerIntra), else its daily row: today's when its last scan lay
-- before the moment, an earlier day's otherwise (up to DAY_LOOKBACK days).
local DAY_LOOKBACK = 7
local priceDay, priceTs

-- the newest point of an ascending intraday list at or before t, when it is
-- newer than `best` and has a price
local function intraBefore(list, t, best)
  for i = #(list or {}), 1, -1 do
    local e = list[i]
    if type(e) == "table" and tonumber(e.ts) and e.ts <= t then
      local p = tonumber(e.low)
      if p and p > 0 and (not best or e.ts > best.ts) then return { ts = e.ts, p = p } end
      if p and p > 0 then return best end
    end
  end
  return best
end

-- AH price of a material at the moment priceTs (nil: none known)
local function ahAt(id, s)
  local t, D0 = priceTs, M.C.SCAN_DAY_0
  local key = tostring(id)
  local tail
  if M.IntraList then tail = M.IntraList(key)
  else
    local ist = M.db and M.db.intra and M.RealmKey and M.db.intra[M.RealmKey()]
    tail = ist and ist[key]
  end
  local best = intraBefore(tail, t, nil)
  best = intraBefore(M.ServerIntra and M.ServerIntra(key), t, best)
  if best and best.ts < t - DAY_LOOKBACK * 86400 then best = nil end
  if s then
    local d0 = floor((t - D0) / 86400)
    for d = d0, d0 - DAY_LOOKBACK, -1 do
      local r = s[d]
      if type(r) == "table" then
        local rts, rp = tonumber(r.ts), nil
        if rts and rts <= t and tonumber(r.cur) and r.cur > 0 then
          rp = r.cur
        elseif d < d0 and tonumber(r.low) and r.low > 0 then
          rp, rts = r.low, (rts and rts <= t) and rts or (D0 + (d + 1) * 86400 - 1)
        end
        if rp then
          if not best or rts > best.ts then best = { ts = rts, p = rp } end
          break
        end
      end
    end
  end
  return best and best.p
end

local function unitOn(id)
  local v = M.VendorPrice and M.VendorPrice(id)
  if not (v and v > 0) then v = nil end
  local s = M.GetSeries and M.GetSeries(tostring(id))
  local p
  if priceTs then
    p = ahAt(id, s)
  elseif s then
    for d = priceDay, priceDay - DAY_LOOKBACK, -1 do
      local r = s[d]
      local q = type(r) == "table" and tonumber(r.low)
      if q and q > 0 then p = q; break end
    end
  end
  if p then
    if v and v <= p then return v, "vendor" end
    return p, "ah"
  end
  if v then return v, "vendor" end
  local est = M.Recipes().vend[id]
  if est then return est, "est" end
  return nil, nil
end

local function makeCost(id, k, depth, path, mob, memo, free)
  local recs = M.Recipes().byItem[id]
  if not recs then return nil end
  path[id] = true
  local bestC, bestR, bestOk
  for _, rec in ipairs(recs) do
    if not (free and rec.cd) then
      local sum, ok = 0, true
      for _, mt in ipairs(rec.mats) do
        local c, _, _, cok = cost(mt.id, k, depth + 1, path, mob, memo)
        if c then sum = sum + c * mt.n else ok = false end
        if not cok then ok = false end
      end
      local unit = sum / rec.yield
      if not bestC or (ok and not bestOk) or (ok == bestOk and unit < bestC) then
        bestC, bestR, bestOk = unit, rec, ok
      end
    end
  end
  path[id] = nil
  return bestC, bestR, bestOk
end

cost = function(id, k, depth, path, mob, memo)
  local hit = memo[id]
  if hit then return hit.cost, hit.how, hit.rec, hit.ok end
  local now, fair, src
  if priceDay or priceTs then
    now, src = unitOn(id)
    fair = now
  else
    now, fair, src = M.UnitPrice(id)
  end
  local buy = (k == NOW) and now or fair
  local e = { cost = buy, how = "buy", src = src, ok = buy ~= nil, buy = buy }
  local f = force and force[id]
  if (mob or f) and depth < MAX_DEPTH and not path[id] then
    -- your "make" may use a cooldown recipe too
    local mc, mrec, mok = makeCost(id, k, depth, path, mob, memo, buy ~= nil and f ~= "make")
    local barred = kset ~= nil and buy ~= nil and not kset[id]
    if f == "make" and mc then
      e.cost, e.how, e.rec, e.ok, e.make, e.forced = mc, "make", mrec, mok, mc, "make"
    elseif f == "buy" and buy then
      e.make, e.forced = mc, "buy"
    elseif mob and mc and not barred and ((mok and (not buy or mc < buy)) or not buy) then
      e.cost, e.how, e.rec, e.ok, e.make = mc, "make", mrec, mok, mc
    elseif mc then
      e.make = mc
      -- cheaper to make, but none of your characters knows the recipe
      if barred and mok and mc < buy then e.barred = true end
    end
  end
  memo[id] = e
  return e.cost, e.how, e.rec, e.ok
end

local cache, cacheGen = {}, nil
local knownGen = 0      -- counts up when a character learns a recipe
local function buyUnknown()
  local d = M.db
  return (d and d.config and d.config.craftBuyUnknown == true and d.crafts and next(d.crafts) ~= nil) or false
end
local function fresh()
  local bu = buyUnknown()
  local g = tostring(M._analysisGen or 0) .. ":" .. tostring(M.VendorCount and M.VendorCount() or 0)
    .. (bu and (":k" .. knownGen) or "")
  if cacheGen ~= g then
    cache, cacheGen = {}, g
    kset = bu and (M.CraftKnownItems() or {}) or nil
  end
end
local dayCache, dayGen = {}, nil   -- M.CraftCostOn's own cache (see there)
function M.CraftCacheReset() cacheGen = nil; dayGen = nil end

local function mobOn()
  return not (M.db and M.db.config and M.db.config.craftBuyOnly)
end

-- the cache key of a set of your choices ("" for none), the same for any order
local function forceKey(fc)
  if not fc or next(fc) == nil then return "" end
  local t = {}
  for mid, how in pairs(fc) do t[#t + 1] = tostring(mid) .. ((how == "make") and "m" or "b") end
  table.sort(t)
  return "|" .. table.concat(t, ",")
end

-- what it costs to MAKE one unit of id, now and fair:
-- { now, fair, rec, complete, nowOk, fairOk, memo = { [NOW] = {...}, [FAIR] = {...} } }
-- fc = your make / buy choices for its materials (see `force`), nil for none
function M.CraftCost(id, mob, fc)
  id = tonumber(id)
  if not id or not M.Recipes().byItem[id] then return nil end
  if mob == nil then mob = mobOn() end
  fresh()
  local key = id .. (mob and ":m" or ":b") .. forceKey(fc)
  if cache[key] then return cache[key] end
  local res = { memo = {} }
  force = (fc and next(fc) ~= nil) and fc or nil
  for k = NOW, FAIR do
    local mm = {}
    local c, rec, ok = makeCost(id, k, 0, {}, mob, mm)
    res.memo[k] = mm
    if k == NOW then res.now, res.rec, res.nowOk = c, rec, ok
    else res.fair, res.fairRec, res.fairOk = c, rec, ok end
  end
  force = nil
  res.complete = res.nowOk and res.fairOk
  cache[key] = res
  return res
end

-- what it cost to MAKE one unit of id on a past day (scan day number), along
-- the route of M.CraftCost without your own choices: each level bought or
-- made, whichever was cheaper with that day's prices (see `priceDay`).
-- Returns cost, complete - incomplete when some material had no price yet.
-- Its own cache outlives the newest-price cache: live prices and today's quick
-- rows (M.DirtyAnalysis pastSame) leave every past day's row alone, so only
-- M._pastGen, merchant prices and the known recipes (Buy unknown) renew it.
-- Today (or a synced row from a fast clock ahead of it) is never cached: its
-- rows still change with every quick scan.
function M.CraftCostOn(id, day, mob)
  id, day = tonumber(id), tonumber(day)
  if not id or not day or not M.Recipes().byItem[id] then return nil end
  if mob == nil then mob = mobOn() end
  fresh()
  local g = tostring(M._pastGen or 0) .. ":" .. tostring(M.VendorCount and M.VendorCount() or 0)
    .. (buyUnknown() and (":k" .. knownGen) or "")
  if dayGen ~= g then dayCache, dayGen = {}, g end
  local key = id .. ":" .. day .. (mob and ":m" or ":b")
  local hit = dayCache[key]
  if hit then return hit.c, hit.ok end
  force, priceDay, priceTs = nil, day, nil
  local fine, c, _, ok = pcall(makeCost, id, NOW, 0, {}, mob, {})
  priceDay = nil
  if not fine then return nil end
  hit = { c = c, ok = ok and c ~= nil and c > 0 }
  if not (M.GetScanDay and day >= M.GetScanDay()) then dayCache[key] = hit end
  return hit.c, hit.ok
end

-- the same at a moment of the last day (unix time; the 1D chart): each
-- material at its newest scan before it (see `priceTs`). Not cached - the
-- server's points come and go with the companion app's file, and a 1D chart
-- asks for a few dozen moments only. Returns cost, complete.
function M.CraftCostAt(id, ts, mob)
  id, ts = tonumber(id), tonumber(ts)
  if not id or not ts or not M.Recipes().byItem[id] then return nil end
  if mob == nil then mob = mobOn() end
  fresh()
  force, priceDay, priceTs = nil, nil, ts
  local fine, c, _, ok = pcall(makeCost, id, NOW, 0, {}, mob, {})
  priceTs = nil
  if not fine then return nil end
  return c, (ok and c ~= nil and c > 0) or false
end

-- what the materials of one enchant cost, now and fair (each bought or made,
-- whichever is cheaper): { now, fair, nowOk, fairOk, complete,
-- mat = { [now] = { cost of each material line }, [fair] = { ... } } }
function M.EnchantCost(spell, mob)
  local rec = M.Recipes().enchBySpell[tonumber(spell) or 0]
  if not rec then return nil end
  if mob == nil then mob = mobOn() end
  fresh()
  force = nil
  local key = "e" .. rec.spell .. (mob and ":m" or ":b")
  if cache[key] then return cache[key] end
  local res = { mat = { {}, {} } }
  for k = NOW, FAIR do
    local mm, sum, ok = {}, 0, true
    for i, mt in ipairs(rec.mats) do
      local c, _, _, cok = cost(mt.id, k, 1, {}, mob, mm)
      res.mat[k][i] = c and c * mt.n
      if c then sum = sum + c * mt.n else ok = false end
      if not cok then ok = false end
    end
    if k == NOW then res.now, res.nowOk = sum, ok else res.fair, res.fairOk = sum, ok end
  end
  res.complete = res.nowOk and res.fairOk
  cache[key] = res
  return res
end

-- AH price after the 5% cut minus the cost of making it, now and fair;
-- mob = true / false asks for one way of sourcing (nil: the Make or buy switch),
-- fc = your make / buy choices for its materials
function M.CraftProfit(id, mob, fc)
  local cc = M.CraftCost(id, mob, fc)
  if not cc then return nil end
  local sNow, sFair = M.SellPrice(id)
  local p = { cost = cc, sellNow = sNow, sellFair = sFair }
  if sNow and cc.now then
    p.now = sNow * (1 - AH_CUT) - cc.now
    p.nowPct = (cc.now > 0) and (p.now / cc.now) or nil
  end
  if sFair and cc.fair then
    p.fair = sFair * (1 - AH_CUT) - cc.fair
    p.fairPct = (cc.fair > 0) and (p.fair / cc.fair) or nil
  end
  return p
end

-- What `n` items of id need to BUY, along the same route as CraftCost (now
-- prices): every material bought there counts with its units, a material made
-- there is followed into its own recipe. { [itemID] = { units, src, price } }
-- fc = your make / buy choices for its materials
function M.CraftNeeds(id, n, mob, fc)
  local cc = M.CraftCost(id, mob, fc)
  if not (cc and cc.rec and n and n > 0) then return nil end
  local memo = cc.memo[NOW]
  local need, path = {}, { [tonumber(id)] = true }
  -- `path` ends every circle; a made material is followed however deep its
  -- memo entry sits, as CraftCost counted it
  local function walk(mid, units)
    local e = memo[mid]
    if e and e.how == "make" and e.rec and not path[mid] then
      path[mid] = true
      local runs = units / e.rec.yield
      for _, mt in ipairs(e.rec.mats) do walk(mt.id, mt.n * runs) end
      path[mid] = nil
    else
      local t = need[mid]
      if not t then
        t = { units = 0, src = e and e.src, price = e and e.buy }
        need[mid] = t
      end
      t.units = t.units + units
    end
  end
  local runs = n / cc.rec.yield
  for _, mt in ipairs(cc.rec.mats) do walk(mt.id, mt.n * runs) end
  return need
end

-- true when this realm has the price ladder of a full scan (the offer book)
function M.HasDepth()
  if M.BookOf then return M.BookOf() ~= nil end
  local d = M.db and M.db.depth and M.RealmKey and M.db.depth[M.RealmKey()]
  return d ~= nil and d.items ~= nil
end

-- What buying `units` of id costs at the listings of your newest full scan,
-- cheapest first: { want, got, listed, cost, climb, ts }, climb = what that
-- costs over buying them all at its cheapest listing. Units listed above the
-- stored price levels count at the dearest stored price. nil when that scan
-- did not list the item.
function M.DepthCost(id, units)
  local d = M.GetDepth and M.GetDepth(id)
  local lv1 = d and d.levels and d.levels[1]
  if not lv1 then return nil end
  local want = math.ceil((units or 0) - 1e-6)
  local got, sum, last = 0, 0, lv1.price
  for _, lv in ipairs(d.levels) do
    if got >= want then break end
    local take = min(lv.qty, want - got)
    got, sum, last = got + take, sum + take * lv.price, lv.price
  end
  local listed = max(d.listed or got, d.units or got)
  local rest = min(want, listed) - got
  if rest > 0 then
    got, sum = got + rest, sum + rest * last
  end
  return { want = want, got = got, listed = listed, cost = sum, climb = sum - got * lv1.price, ts = d.ts }
end

-- best crafts by profit (now) among items with market data: { {id, profit}, ... }
-- known = true: only items one of your characters can make
function M.TopCrafts(prof, n, known)
  fresh()
  local key = "top:" .. tostring(prof) .. ":" .. tostring(mobOn())
  local list = cache[key]
  if not list then
    list = {}
    local Rx = M.Recipes()
    for _, id in ipairs(Rx.items) do
      local rec = Rx.byItem[id][1]
      if not prof or rec.prof == prof then
        local p = M.CraftProfit(id)
        if p and p.now and p.cost.nowOk and p.sellNow then
          local m = metrics(id)
          list[#list + 1] = { id = id, profit = p, prof = rec.prof, speed = m and m.speed }
        end
      end
    end
    table.sort(list, function(a, b)
      if a.profit.now ~= b.profit.now then return a.profit.now > b.profit.now end
      return a.id < b.id
    end)
    cache[key] = list
  end
  -- filtered after the cache: recipes learned meanwhile count at once
  if known then
    local set, f = M.CraftKnownItems() or {}, {}
    for _, e in ipairs(list) do
      if set[e.id] then f[#f + 1] = e end
    end
    list = f
  end
  if not n or n >= #list then return list end
  local out = {}
  for i = 1, n do out[i] = list[i] end
  return out
end

-- ===== Recipe payoff ========================================================
-- A recipe item (Recipe:, Pattern:, Plans: ...) teaches one recipe. Its payoff
-- is how many crafts of that recipe it takes until their profit after the 5%
-- AH cut has paid for the recipe item: ceil(price / profit of one craft), now
-- and fair. Each material counts as CraftCost decided it (Make or buy, Buy
-- unknown, your choices), but always the materials of THIS recipe, even where
-- the item has a cheaper one.
-- { item, rec, product, price = { now, fair }, src, per = { now, fair },
--   crafts = { now, fair }, partial } - crafts false = the craft makes no
-- profit; nil when the recipe item, its price or the product's AH price is
-- unknown

-- one craft of rec (all its yield) along the route of a CraftCost result
local function recipeRun(rec, cc, k)
  local memo = cc.memo[k]
  local sum, ok = 0, true
  for _, mt in ipairs(rec.mats) do
    local e = memo and memo[mt.id]
    if not (e and e.cost) then return nil end
    sum = sum + e.cost * mt.n
    if not e.ok then ok = false end
  end
  return sum, ok
end

function M.RecipePayoff(item, mob, fc)
  item = tonumber(item)
  local rec = item and M.Recipes().teach[item]
  if not rec then return nil end
  local pNow, pFair, src = M.UnitPrice(item)
  if not (pNow and pNow > 0) then return nil end
  local cc = M.CraftCost(rec.item, mob, fc)
  local sNow, sFair = M.SellPrice(rec.item)
  if not (cc and sNow) then return nil end
  local res = { item = item, rec = rec, product = rec.item, price = { pNow, pFair or pNow }, src = src,
                per = {}, crafts = {} }
  local sells = { sNow, sFair }
  for k = NOW, FAIR do
    local run, ok = recipeRun(rec, cc, k)
    if run and sells[k] then
      local per = sells[k] * (1 - AH_CUT) * rec.yield - run
      res.per[k] = per
      -- under one copper a craft is no profit (it would take billions of crafts)
      res.crafts[k] = (per >= 1) and max(1, math.ceil(res.price[k] / per - 1e-9)) or false
      if not ok then res.partial = true end
    end
  end
  if res.crafts[NOW] == nil then return nil end
  return res
end

-- "17 crafts" / "1 craft" / "9999+ crafts" / "no profit" (false)
function M.CraftsText(c)
  if c == false then return "no profit" end
  if not c then return "-" end
  if c > 9999 then return "9999+ crafts" end
  return c .. ((c == 1) and " craft" or " crafts")
end

-- the payoff of the recipe item that pays off soonest among those teaching a
-- recipe for this product (nil: none with a price, trainer recipes)
function M.ProductPayoff(id, mob, fc)
  local list = M.Recipes().taughtBy[tonumber(id) or 0]
  if not list then return nil end
  local best
  for _, item in ipairs(list) do
    local p = M.RecipePayoff(item, mob, fc)
    if p then
      local a, b = p.crafts[NOW], best and best.crafts[NOW]
      if not best or (a and (not b or a < b or (a == b and p.price[NOW] < best.price[NOW])))
         or (not a and not b and p.price[NOW] < best.price[NOW]) then
        best = p
      end
    end
  end
  return best
end

-- ===== Disenchanting ========================================================
-- Results are server loot and not in the client tables: this is the known
-- table of the game mechanic, odds approximate (community-measured).
-- quality -> { minIlvl, maxIlvl, { { itemID, chance, min, max }, ... } }
-- Uncommon weapons swap the dust and essence odds.
local DE = {
  [2] = {
    { 5, 15,   { { 10940, .80, 1, 2 }, { 10938, .20, 1, 2 } } },
    { 16, 20,  { { 10940, .75, 2, 3 }, { 10939, .20, 1, 2 }, { 10978, .05, 1, 1 } } },
    { 21, 25,  { { 10940, .75, 4, 6 }, { 10998, .15, 1, 2 }, { 10978, .10, 1, 1 } } },
    { 26, 30,  { { 11083, .75, 1, 2 }, { 11082, .20, 1, 2 }, { 11084, .05, 1, 1 } } },
    { 31, 35,  { { 11083, .75, 2, 5 }, { 11134, .20, 1, 2 }, { 11138, .05, 1, 1 } } },
    { 36, 40,  { { 11137, .75, 1, 2 }, { 11135, .20, 1, 2 }, { 11139, .05, 1, 1 } } },
    { 41, 45,  { { 11137, .75, 2, 5 }, { 11174, .20, 1, 2 }, { 11177, .05, 1, 1 } } },
    { 46, 50,  { { 11176, .75, 1, 2 }, { 11175, .20, 1, 2 }, { 11178, .05, 1, 1 } } },
    { 51, 55,  { { 11176, .75, 2, 5 }, { 16202, .20, 1, 2 }, { 14343, .05, 1, 1 } } },
    { 56, 60,  { { 16204, .75, 1, 2 }, { 16203, .20, 1, 2 }, { 14344, .05, 1, 1 } } },
    { 61, 65,  { { 16204, .75, 2, 5 }, { 16203, .20, 2, 3 }, { 14344, .05, 1, 1 } } },
    { 66, 79,  { { 22445, .75, 1, 3 }, { 22447, .22, 1, 3 }, { 22448, .03, 1, 1 } } },
    { 80, 99,  { { 22445, .75, 2, 3 }, { 22447, .22, 2, 3 }, { 22448, .03, 1, 1 } } },
    { 100, 120, { { 22445, .75, 2, 5 }, { 22446, .22, 1, 2 }, { 22449, .03, 1, 1 } } },
  },
  [3] = {
    { 1, 25,   { { 10978, 1, 1, 1 } } },
    { 26, 30,  { { 11084, 1, 1, 1 } } },
    { 31, 35,  { { 11138, 1, 1, 1 } } },
    { 36, 40,  { { 11139, 1, 1, 1 } } },
    { 41, 45,  { { 11177, 1, 1, 1 } } },
    { 46, 50,  { { 11178, 1, 1, 1 } } },
    { 51, 55,  { { 14343, 1, 1, 1 } } },
    { 56, 65,  { { 14344, .995, 1, 1 }, { 20725, .005, 1, 1 } } },
    { 66, 99,  { { 22448, .995, 1, 1 }, { 22450, .005, 1, 1 } } },
    { 100, 164, { { 22449, .995, 1, 1 }, { 22450, .005, 1, 1 } } },
  },
  [4] = {
    { 40, 45,  { { 11177, 1, 2, 4 } } },
    { 46, 50,  { { 11178, 1, 2, 4 } } },
    { 51, 55,  { { 14343, 1, 2, 4 } } },
    { 56, 60,  { { 20725, 1, 1, 1 } } },
    { 61, 94,  { { 20725, 1, 1, 2 } } },
    { 95, 164, { { 22450, 1, 1, 2 } } },
  },
}
M.DE_TABLE = DE

local function deBand(quality, ilvl)
  for _, b in ipairs(DE[quality] or {}) do
    if ilvl >= b[1] and ilvl <= b[2] then return b end
  end
  return nil
end

-- expected disenchant value of one item: nil when it cannot be disenchanted
-- (or its item info is not loaded yet)
function M.DisenchantValue(id)
  id = tonumber(id)
  if not id then return nil end
  local _, _, quality, ilvl, _, _, _, _, _, _, vendorSell, classID = M.GetItemInfo(id)
  if not (quality and ilvl and classID) then return nil end
  if (classID ~= 2 and classID ~= 4) or quality < 2 or quality > 4 then return nil end
  local band = deBand(quality, ilvl)
  if not band then return nil end
  local res = { results = {}, now = 0, fair = 0, complete = true, vendor = vendorSell or 0, quality = quality, ilvl = ilvl }
  local swap = (classID == 2 and quality == 2 and #band[3] >= 2)
  for i, r in ipairs(band[3]) do
    local chance = r[2]
    if swap and i <= 2 then chance = band[3][3 - i][2] end
    local avg = (r[3] + r[4]) / 2
    local now, fair = M.UnitPrice(r[1])
    res.results[#res.results + 1] = { id = r[1], chance = chance, lo = r[3], hi = r[4], now = now, fair = fair }
    if now and fair then
      res.now = res.now + chance * avg * now
      res.fair = res.fair + chance * avg * fair
    else
      res.complete = false
    end
  end
  table.sort(res.results, function(a, b) return a.chance > b.chance end)
  local sNow, sFair = M.SellPrice(id)
  res.sellNow = sNow and sNow * (1 - AH_CUT)
  res.sellFair = sFair and sFair * (1 - AH_CUT)
  local best, bestV = "vendor", res.vendor
  if res.complete and res.now > bestV then best, bestV = "disenchant", res.now end
  if res.sellNow and res.sellNow > bestV then best, bestV = "sell", res.sellNow end
  res.best = best
  return res
end

-- which disenchant bands yield this material: { { quality, lo, hi, chance, weapon }, ... }
function M.DisenchantSources(id)
  id = tonumber(id)
  local out = {}
  for q, bands in pairs(DE) do
    for _, b in ipairs(bands) do
      for i, r in ipairs(b[3]) do
        if r[1] == id then
          out[#out + 1] = { quality = q, lo = b[1], hi = b[2], chance = r[2], min = r[3], max = r[4], slot = i }
        end
      end
    end
  end
  table.sort(out, function(a, b) if a.quality ~= b.quality then return a.quality < b.quality end return a.lo < b.lo end)
  return out
end

-- ===== Recipes your characters know =========================================
-- Read when a profession window opens: legacy clients list products, the
-- modern client lists recipe (= spell) ids.
local function idOf(link)
  if type(link) ~= "string" then return nil end
  if issecretvalue and issecretvalue(link) then return nil end
  return tonumber(link:match("item:(%d+)"))
end

local function charStore()
  if not (M.db and M.CharKey) then return nil end
  M.db.crafts = M.db.crafts or {}
  local ck = M.CharKey()
  local c = M.db.crafts[ck]
  if not c then c = { items = {}, prof = {} }; M.db.crafts[ck] = c end
  c.items, c.prof, c.ench = c.items or {}, c.prof or {}, c.ench or {}
  return c
end

-- an enchant shows as an "enchant:<spell>" link instead of an item
local function enchOf(c, link)
  if type(link) ~= "string" then return false end
  if issecretvalue and issecretvalue(link) then return false end
  local sp = tonumber(link:match("enchant:(%d+)"))
  if sp and M.Recipes().enchBySpell[sp] then c.ench[sp] = true; return true end
  return false
end

local function readLegacy(c)
  local n = GetNumTradeSkills and GetNumTradeSkills() or 0
  local name, rank = nil, nil
  if GetTradeSkillLine then name, rank = GetTradeSkillLine() end
  local got = 0
  for i = 1, n do
    local _, kind = GetTradeSkillInfo(i)
    if kind ~= "header" then
      local id = idOf(GetTradeSkillItemLink and GetTradeSkillItemLink(i))
      if id then c.items[id] = true; got = got + 1
      elseif GetTradeSkillRecipeLink and enchOf(c, GetTradeSkillRecipeLink(i)) then got = got + 1 end
    end
  end
  if name and type(rank) == "number" and name ~= "UNKNOWN" then c.prof[name] = rank end
  return got
end

local function readCraft(c)
  local n = GetNumCrafts and GetNumCrafts() or 0
  local got = 0
  for i = 1, n do
    local _, _, kind = GetCraftInfo(i)
    if kind ~= "header" then
      local link = GetCraftItemLink and GetCraftItemLink(i)
      local id = idOf(link)
      if id and M.Recipes().byItem[id] then c.items[id] = true; got = got + 1
      elseif enchOf(c, link) then got = got + 1 end
    end
  end
  if GetCraftDisplaySkillLine then
    local name, rank = GetCraftDisplaySkillLine()
    if name and type(rank) == "number" then c.prof[name] = rank end
  end
  return got
end

local function readModern(c)
  local T = C_TradeSkillUI
  if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo) then return 0 end
  local ok, ids = pcall(T.GetAllRecipeIDs)
  if not ok or type(ids) ~= "table" then return 0 end
  local got = 0
  for _, rid in ipairs(ids) do
    local info = T.GetRecipeInfo(rid)
    local rec = M.Recipes().bySpell[rid]
    if info and info.learned and rec then c.items[rec.item] = true; got = got + 1
    elseif info and info.learned and M.Recipes().enchBySpell[rid] then c.ench[rid] = true; got = got + 1 end
  end
  return got
end

function M.CraftLearn(kind)
  local first = not (M.db and M.db.crafts and next(M.db.crafts) ~= nil)   -- no profession window read yet
  local c = charStore()
  if not c then return 0 end
  local function size()
    local n = 0
    for _ in pairs(c.items) do n = n + 1 end
    for _ in pairs(c.ench) do n = n + 1 end
    return n
  end
  local before = size()
  local ok, got = pcall(function()
    if kind == "craft" then return readCraft(c) end
    if GetNumTradeSkills then return readLegacy(c) end
    return readModern(c)
  end)
  -- a new recipe, or the first record at all (red cards and "Buy unknown" start with it)
  local grew = size() ~= before or first
  if grew then knownGen = knownGen + 1 end   -- "Buy unknown" recalculates
  return ok and got or 0, grew
end

-- names of your characters who can make this item (enchant = true: who
-- knows this enchant spell)
function M.CraftKnownBy(id, enchant)
  id = tonumber(id)
  local out = {}
  for ck, c in pairs((M.db and M.db.crafts) or {}) do
    local set = enchant and c.ench or c.items
    if set and set[id] then
      local ch = M.db.chars and M.db.chars[ck]
      out[#out + 1] = (ch and ch.name) or ck:match("^(.*)%-[^%-]*$") or ck
    end
  end
  table.sort(out)
  return out
end

-- every item one of your characters can make: { [itemID] = true }, nil while
-- no profession window has been read yet
function M.CraftKnownItems()
  local set, any = {}, false
  for _, c in pairs((M.db and M.db.crafts) or {}) do
    for id in pairs(c.items or {}) do
      local n = tonumber(id)
      if n then set[n] = true; any = true end
    end
  end
  return any and set or nil
end

do
  local ev = CreateFrame("Frame")
  for _, e in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "CRAFT_SHOW", "CRAFT_UPDATE",
                       "TRADE_SKILL_LIST_UPDATE" }) do
    M.SafeRegister(ev, e)
  end
  local pending
  ev:SetScript("OnEvent", function(_, event)
    if pending then return end
    pending = true
    C_Timer.After(0.5, function()
      pending = nil
      local _, grew = M.CraftLearn((event == "CRAFT_SHOW" or event == "CRAFT_UPDATE") and "craft" or "trade")
      -- an open Crafting tab shows the new recipes at once (red cards, costs)
      if grew and M.RefreshCrafting then M.RefreshCrafting() end
    end)
  end)
end

-- ===== Tooltip lines ========================================================
-- Game-font safe characters only (no arrows, no math signs): "~" for approximate.
local GOLD, PURPLE = { 0.99, 0.80, 0.38 }, { 0.62, 0.55, 0.98 }
local function hex(c) return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255) end
local function money(c)
  if not c then return "?" end
  c = floor(c + 0.5)
  return ((c < 0) and "-" or "") .. M.MoneyTip(math.abs(c))
end
local function pct(p)
  if not p then return "" end
  local col = (p >= 0) and "|cff5cd178" or "|cfff0645a"
  return string.format("  %s%+.0f%%|r", col, p * 100)
end

-- adds the craft / disenchant / payoff / used-in lines; `header` puts the Midas title
-- first (items without market data); returns true when it added anything
function M.CraftTipLines(tip, id, mode, header)
  if not (M.db and M.db.config) or M.db.config.tooltipCraft == false then return false end
  if not M.CraftingOn() then return false end
  id = tonumber(id)
  if not id then return false end
  local Rx = M.Recipes()
  local p = Rx.byItem[id] and M.CraftProfit(id)
  local de = M.DisenchantValue(id)
  local pay = Rx.teach[id] and M.RecipePayoff(id)
  local nRec, nEnch = M.UsedInCount(id)
  local uses = (nRec + nEnch) > 0
  if not (p or de or pay or (uses and mode ~= "reduced")) then return false end
  if header then
    tip:AddLine(" ")
    tip:AddLine("|cffE8B44AMidas|r")
  end
  local G, P = hex(GOLD), hex(PURPLE)
  if p then
    local cc = p.cost
    local part = cc.nowOk and "" or "  |cff9a968c(partial)|r"
    tip:AddDoubleLine("Craft  " .. G .. money(cc.now) .. "|r" .. pct(p.nowPct) .. part,
      P .. "fair " .. money(cc.fair) .. "|r" .. pct(p.fairPct), 0.78, 0.76, 0.70, 0.78, 0.76, 0.70)
  end
  if de then
    local tag = de.complete and "" or "  |cff9a968c(partial)|r"
    tip:AddDoubleLine("Disenchant  " .. G .. "~" .. money(de.now) .. "|r" .. tag,
      P .. "fair ~" .. money(de.fair) .. "|r", 0.78, 0.76, 0.70, 0.78, 0.76, 0.70)
  end
  if pay then
    -- a recipe item: how many crafts until their profit pays for it
    local n = pay.crafts[1]
    local note = pay.partial and "  |cff9a968c(partial)|r" or ""
    -- a recipe on a cooldown (transmutes): the first craft at once, then one per cooldown
    if n and n > 1 and n <= 9999 and pay.rec.cd then
      local days = math.ceil((n - 1) * pay.rec.cd / 86400 - 1e-9)
      note = note .. string.format("  |cff9a968c(cooldown, ~%d %s)|r", days, (days == 1) and "day" or "days")
    end
    local right = (pay.crafts[2] ~= nil) and (P .. "fair " .. M.CraftsText(pay.crafts[2]) .. "|r") or ""
    tip:AddDoubleLine("Payoff  " .. ((n == false) and "|cfff0645a" or G) .. M.CraftsText(n) .. "|r" .. note,
      right, 0.78, 0.76, 0.70, 0.78, 0.76, 0.70)
  end
  if uses and mode ~= "reduced" then
    tip:AddLine("Used in  " .. M.UsedInText(nRec, nEnch), 0.55, 0.58, 0.64)
  end
  return true
end
