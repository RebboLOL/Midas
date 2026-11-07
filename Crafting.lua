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

-- ===== Recipe index (decoded on first use) ==================================
local R
function M.Recipes()
  if R then return R end
  R = { byItem = {}, bySpell = {}, usedIn = {}, items = {}, prof = {}, vend = {}, n = 0 }
  local D = M.RECIPE_DATA
  if type(D) ~= "table" then return R end
  R.prof, R.vend, R.build, R.flavor = D.prof or {}, D.vend or {}, D.build, D.flavor
  for line in (D.rec or ""):gmatch("[^\n]+") do
    local item, lo, hi, prof, yel, grey, spell, mats =
      line:match("^(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)|(.+)$")
    if item then
      local rec = { item = tonumber(item), lo = tonumber(lo), hi = tonumber(hi), prof = tonumber(prof),
                    yellow = tonumber(yel), grey = tonumber(grey), spell = tonumber(spell), mats = {} }
      rec.yield = (rec.lo + rec.hi) / 2
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
  D.rec = nil   -- the index is all we need from here on
  return R
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

-- one unit to BUY, both ways: now, fair, source ("vendor" / "ah" / "est")
function M.UnitPrice(id)
  id = tonumber(id)
  if not id then return nil end
  local v = M.VendorPrice and M.VendorPrice(id)
  if v and v > 0 then return v, v, "vendor" end
  local m = metrics(id)
  if m and ((m.fair and m.fair > 0) or (m.cur and m.cur > 0)) then
    local fair = (m.fair and m.fair > 0) and m.fair or m.cur
    local now = m.cur
    if not now or now <= 0 or (M.NotListed and M.NotListed(m)) then now = fair end
    return now, fair, "ah"
  end
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
local cost
local function makeCost(id, k, depth, path, mob, memo)
  local recs = M.Recipes().byItem[id]
  if not recs then return nil end
  path[id] = true
  local bestC, bestR, bestOk
  for _, rec in ipairs(recs) do
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
  path[id] = nil
  return bestC, bestR, bestOk
end

cost = function(id, k, depth, path, mob, memo)
  local hit = memo[id]
  if hit then return hit.cost, hit.how, hit.rec, hit.ok end
  local now, fair, src = M.UnitPrice(id)
  local buy = (k == NOW) and now or fair
  local e = { cost = buy, how = "buy", src = src, ok = buy ~= nil, buy = buy }
  if mob and depth < MAX_DEPTH and not path[id] then
    local mc, mrec, mok = makeCost(id, k, depth, path, mob, memo)
    if mc and ((mok and (not buy or mc < buy)) or not buy) then
      e.cost, e.how, e.rec, e.ok, e.make = mc, "make", mrec, mok, mc
    elseif mc then
      e.make = mc
    end
  end
  memo[id] = e
  return e.cost, e.how, e.rec, e.ok
end

local cache, cacheGen = {}, nil
local function fresh()
  local g = tostring(M._analysisGen or 0) .. ":" .. tostring(M.VendorCount and M.VendorCount() or 0)
  if cacheGen ~= g then cache, cacheGen = {}, g end
end
function M.CraftCacheReset() cacheGen = nil end

local function mobOn()
  return not (M.db and M.db.config and M.db.config.craftBuyOnly)
end

-- what it costs to MAKE one unit of id, now and fair:
-- { now, fair, rec, complete, nowOk, fairOk, memo = { [NOW] = {...}, [FAIR] = {...} } }
function M.CraftCost(id, mob)
  id = tonumber(id)
  if not id or not M.Recipes().byItem[id] then return nil end
  if mob == nil then mob = mobOn() end
  fresh()
  local key = id .. (mob and ":m" or ":b")
  if cache[key] then return cache[key] end
  local res = { memo = {} }
  for k = NOW, FAIR do
    local mm = {}
    local c, rec, ok = makeCost(id, k, 0, {}, mob, mm)
    res.memo[k] = mm
    if k == NOW then res.now, res.rec, res.nowOk = c, rec, ok
    else res.fair, res.fairRec, res.fairOk = c, rec, ok end
  end
  res.complete = res.nowOk and res.fairOk
  cache[key] = res
  return res
end

-- AH price after the 5% cut minus the cost of making it, now and fair
function M.CraftProfit(id)
  local cc = M.CraftCost(id)
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

-- best crafts by profit (now) among items with market data: { {id, profit}, ... }
function M.TopCrafts(prof, n)
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
  if not n or n >= #list then return list end
  local out = {}
  for i = 1, n do out[i] = list[i] end
  return out
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
  c.items, c.prof = c.items or {}, c.prof or {}
  return c
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
      if id then c.items[id] = true; got = got + 1 end
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
      local id = idOf(GetCraftItemLink and GetCraftItemLink(i))
      if id and M.Recipes().byItem[id] then c.items[id] = true; got = got + 1 end
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
    if info and info.learned and rec then c.items[rec.item] = true; got = got + 1 end
  end
  return got
end

function M.CraftLearn(kind)
  local c = charStore()
  if not c then return 0 end
  local ok, got = pcall(function()
    if kind == "craft" then return readCraft(c) end
    if GetNumTradeSkills then return readLegacy(c) end
    return readModern(c)
  end)
  return ok and got or 0
end

-- names of your characters who can make this item
function M.CraftKnownBy(id)
  id = tonumber(id)
  local out = {}
  for ck, c in pairs((M.db and M.db.crafts) or {}) do
    if c.items and c.items[id] then
      local ch = M.db.chars and M.db.chars[ck]
      out[#out + 1] = (ch and ch.name) or ck:match("^(.*)%-[^%-]*$") or ck
    end
  end
  table.sort(out)
  return out
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
      M.CraftLearn((event == "CRAFT_SHOW" or event == "CRAFT_UPDATE") and "craft" or "trade")
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
  return ((c < 0) and "-" or "") .. M.MoneyPlain(math.abs(c))
end
local function pct(p)
  if not p then return "" end
  local col = (p >= 0) and "|cff5cd178" or "|cfff0645a"
  return string.format("  %s%+.0f%%|r", col, p * 100)
end

-- adds the craft / disenchant / used-in lines; `header` puts the Midas title
-- first (items without market data); returns true when it added anything
function M.CraftTipLines(tip, id, mode, header)
  if not (M.db and M.db.config) or M.db.config.tooltipCraft == false then return false end
  if not M.CraftingOn() then return false end
  id = tonumber(id)
  if not id then return false end
  local Rx = M.Recipes()
  local p = Rx.byItem[id] and M.CraftProfit(id)
  local de = M.DisenchantValue(id)
  local uses = Rx.usedIn[id]
  if not (p or de or (uses and mode ~= "reduced")) then return false end
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
  if uses and mode ~= "reduced" then
    local seen, n = {}, 0
    for _, rec in ipairs(uses) do
      if not seen[rec.item] then seen[rec.item] = true; n = n + 1 end
    end
    tip:AddLine(string.format("Used in  %d recipe%s", n, n == 1 and "" or "s"), 0.55, 0.58, 0.64)
  end
  return true
end
