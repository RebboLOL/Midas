-- Midas – Core: namespace, constants, helpers, events, slash, init
local ADDON, M = ...
M.version = "1.3.5"
-- community server: Help tab, the get-started tour, what's new and /midas discord
M.DISCORD_URL = "https://discord.gg/CfZgeyxAn5"

-- "/midas perf": what Midas did in the background over 15 seconds. The modules
-- only count (tooltip rebuilds, chart draws, analysis builds, sync merges).
M.perf = { tip = 0, tipMs = 0, build = 0, chart = 0, runs = 0, runMs = 0, sync = 0 }
function M.PerfReport()
  if M._perfRun then M.Print("perf: already measuring.") return end
  M._perfRun = true
  local secs, P, was = 15, M.perf, {}
  for k, v in pairs(P) do was[k] = v end
  M.Print("perf: measuring for " .. secs .. " seconds - hover a few items now.")
  C_Timer.After(secs, function()
    M._perfRun = nil
    local function d(k) return P[k] - was[k] end
    M.Print(string.format("perf: item tooltips rebuilt %d times (%.1f per second), Midas lines built %d times, chart drawn %d times, %.1f ms in total",
      d("tip"), d("tip") / secs, d("build"), d("chart"), d("tipMs")))
    M.Print(string.format("perf: market analysis rebuilt %d times (%.0f ms), sync messages merged %d, frame rate now %.0f",
      d("runs"), d("runMs"), d("sync"), (GetFramerate and GetFramerate()) or 0))
  end)
end

-- Parameters (identical to the Excel analysis) -------------------------------
M.C = {
  SCAN_DAY_0 = time({ year = 2020, month = 1, day = 1, hour = 0 }), -- day-0 epoch
  QTY_REF    = 20,    -- average qty at which liquidity counts as "full"
  DAYS_REF   = 10,    -- days of data needed for full confidence
  MARGIN_CAP = 1.5,   -- cap the margin in the score (150%)
  MIN_DAYS   = 4,     -- minimum scans before an item gets rated
  -- Fair price v3: trimmed market base + bounded sell-odds lift.
  -- Base = recency-weighted average of the daily lowest buyouts over the last
  -- FAIR_BASE_DAYS, EXCLUDING up-outlier days (low > median x FAIR_TRIM): those are
  -- asks that sit in the AH without meeting demand and must not inflate Fair.
  -- The sell-odds curve (logistic in ln(ask / 7-day floor), anchored per liquidity
  -- class at MEASURED sell-through of real outcomes: shipped prior + own log) may
  -- then LIFT Fair up to FAIR_LIFT_MAX when sales prove buyers pay more -- but it
  -- never cuts Fair below the trimmed base (oversupply is fixed by posting less,
  -- not by fire-sale pricing; the displayed odds carry that truth instead).
  FAIR_TARGET    = 0.50,  -- target sell chance per listing for the odds lift
  FAIR_SLOPE     = 3.0,   -- logit slope per ln(price ratio); prior until enough own data
  FAIR_BASE_DAYS = 14,    -- window of the trimmed short-term average
  FAIR_TRIM      = 1.50,  -- drop days with low > median x this (no-demand ask spikes)
  FAIR_LIFT_MAX  = 1.10,  -- odds may lift Fair at most this far above the base: Fair
                          -- must hug the (spike-cleaned) market level, not ride a cap
  FAIR_OVER_REALIZED = 1.10, -- reality brake: MAX headroom above the MEASURED clearing
                          -- ratio (own sales, else class). Scaled by record strength in
                          -- Logic.lua -- a record at ~target odds pins Fair AT the
                          -- clearing level; only a much stronger one earns the full
                          -- headroom. The logistic curve must never extrapolate a
                          -- "50% odds" price far beyond anything that ever sold.
  FAIR_PRIOR_N   = 24,    -- weight (pseudo-listings) of the shipped prior per class
  FAIR_PRIOR = {          -- measured on real Soulseeker data, 2026-07: sell-through S
    Fast     = { S = 0.41, r = 1.31, rs = 1.31 }, -- at typical ask ratio r (ask/floor7);
    Steady   = { S = 0.50, r = 1.03, rs = 1.03 }, -- rs = median ratio of SOLD listings
    Slow     = { S = 0.24, r = 1.25, rs = 1.25 }, --      (where sales really cleared)
    Illiquid = { S = 0.10, r = 1.18, rs = 1.18 },
  },
  CURVE_DAYS     = 30,    -- outcome-counter bucket size (cur+prev spans ~30-60 days)
  QUICK_UNDERCUT = 0.02,  -- quick-sell price = min(cur, fair) undercut by this
  LIQ_FAST   = 300,       -- avg market qty -> Fast / Steady / Slow / Illiquid liquidity label
  LIQ_STEADY = 100,
  LIQ_SLOW   = 20,
  -- Top Picks today
  PICK_MIN_QTY   = 20,
  PICK_MIN_PRICE = 1000,  -- 0.10g in copper
  PICK_MIN_MOVE  = 500,   -- 0.05g in copper
  PICK_DELTA     = 0.15,  -- +/- 15%
  PICK_MAX       = 20,    -- max entries per side
  PICK_TRADEABLE_ONLY = true, -- only mats/consumables/recipes/ammo/bags/BoE gear (no junk)
  -- Ranking / filter (like opportunities.rank)
  RANK_MIN_QTY   = 5,
  RANK_MIN_PRICE = 100,   -- 0.01g
  RANK_TOP       = 100,
  PRUNE_DAYS     = 730,   -- history horizon
  -- Trades / sellability (mail-based)
  SELL_WINDOW    = 60,    -- rolling days used for the sellability rating
  SELL_MIN_N     = 3,     -- min sold+returned auctions before we rate an item
  SELL_HOT       = 0.85,  -- >= this sell-through -> "Underpriced" (probably too cheap)
  SELL_COLD      = 0.34,  -- <  this sell-through -> "Overpriced" (too expensive)
  TRADE_LOG_MAX  = 20000, -- hard cap on stored trade events (runaway backstop; the normal trim is TRADE_LOG_DAYS)
  -- Community sync (Comm.lua, invisible addon messages between Midas users)
  COMM_BPS       = 400,   -- outgoing byte budget per second (conservative; avoids the server throttle)
  COMM_MPS       = 2,     -- max outgoing messages per second
  COMM_PAYLOAD   = 240,   -- max payload bytes per message (255 hard limit)
  SYNC_DAYS      = 60,    -- manifest/backfill horizon in days
  SYNC_MIN_ROWS  = 200,   -- a day must look like a real scan to be pulled/served (orphan-day gate)
  SHARE_MIN_FRAC = 0.05,  -- drop non-guild lows below 5% of the known low (poison guard)
  ANALYSIS_CHUNK = 300,   -- items processed per frame by the background analyzer (Logic.lua) without a clock
  ANALYSIS_SLICE_MS = 6,  -- ...with debugprofilestop: milliseconds of analysis per frame
  IMPORT_CHUNK = 400,     -- items merged per frame by the foreign-addon import (Import.lua)
  TRADE_LOG_DAYS = 75,    -- trade-mail log retention: full SELL_WINDOW (60d) + slack
}

local WD = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
M.WD = WD

-- Output ---------------------------------------------------------------------
function M.Print(...)
  print("|cffFFD700Midas|r:", ...)
end

-- Invalidate all derived, whole-archive analysis (ranked table, Top Picks, cached
-- last-scan-day). Called wherever the price archive or trade log changes. The last
-- finished analysis is KEPT and only marked stale (stale-while-revalidate): at the
-- AH, community sync merges arrive continuously, and dropping the tables on every
-- batch left Top Picks / Opportunities empty and "refreshing" forever. The next
-- TopPicks/RankAll call rebuilds in the background and swaps the result in.
-- Defined here in Core so the early-loading data/comm/vendor modules can call it.
-- keepLastDay: the caller did not move the newest full-scan day (or raised the
-- cached one itself), so M.LastScanDay keeps its answer instead of walking the
-- whole archive again.
function M.DirtyAnalysis(keepLastDay)
  M._analysisStale = true   -- keep M._analysis on screen until the rebuild lands
  M._rankCache    = nil
  if not keepLastDay then M._lastDayCache = nil end
  M._curveAnchor  = nil   -- sell-odds class anchors (Logic.lua) depend on trade data
  M._mCache       = nil   -- per-item metrics memo (Logic.lua), generation-stamped
  M._analysisGen  = (M._analysisGen or 0) + 1
end

-- Money: copper -> short text ------------------------------------------------
function M.Money(copper)
  copper = math.floor((copper or 0) + 0.5)
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  if g > 0 then return string.format("|cffffd70a%d|rg %02ds", g, s) end
  if s > 0 then return string.format("%ds %02dc", s, c) end
  return string.format("%dc", c)
end

-- like Money, but WITHOUT embedded color codes (so the cell/text color wins)
function M.MoneyPlain(copper)
  copper = math.floor((copper or 0) + 0.5)
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  if g > 0 then return string.format("%dg %02ds", g, s) end
  if s > 0 then return string.format("%ds %02dc", s, c) end
  return string.format("%dc", c)
end

-- Settings > "Coin icons": item tooltips show the game's gold/silver/copper
-- icons instead of the g/s/c letters (opt-in, config.coinIcons). CoinIcons
-- turns every "12g 05s" in a text into "12[gold] 5[silver]".
local COIN_ICON = {
  g = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t",
  s = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t",
  c = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t",
}
function M.CoinIcons(txt)
  -- a color code's hex digits may run straight into the amount ("|cffFDCC619g"):
  -- mark the code's end so only the amount itself gets matched
  txt = txt:gsub("(|c%x%x%x%x%x%x%x%x)", "%1\001")
  txt = txt:gsub("%f[%w](%d+)([gsc])%f[%A]", function(n, u)
    return tonumber(n) .. COIN_ICON[u]
  end)
  return (txt:gsub("\001", ""))
end
function M.CoinIconsOn()
  return M.db and M.db.config and M.db.config.coinIcons == true
end
-- tooltip money: MoneyPlain, or the coin icons when switched on
function M.MoneyTip(copper)
  if M.CoinIconsOn() then return M.CoinIcons(M.MoneyPlain(copper)) end
  return M.MoneyPlain(copper)
end
-- tooltip money with gold-tinted gold (like Money); icons need no tint
function M.MoneyTipGold(copper)
  if M.CoinIconsOn() then return M.CoinIcons(M.MoneyPlain(copper)) end
  return M.Money(copper)
end

-- Time / days ----------------------------------------------------------------
function M.GetScanDay()
  return math.floor((time() - M.C.SCAN_DAY_0) / 86400)
end

-- "4g50s" / "4.5" (bare number = gold) / "120s" / "45000c" -> copper, nil on junk.
-- A trailing number after the last unit means the NEXT SMALLER unit:
-- "7g50" = 7g 50s, "7s50" = 7s 50c (it used to be swallowed silently).
function M.ParseMoney(txt)
  if type(txt) ~= "string" then return nil end
  txt = txt:lower():gsub("%s+", ""):gsub(",", ".")
  if txt == "" then return nil end
  local g = tonumber(txt:match("([%d%.]+)g"))
  local s = tonumber(txt:match("(%d+)s"))
  local c = tonumber(txt:match("(%d+)c"))
  if not (g or s or c) then
    local plain = tonumber(txt)
    if not plain or plain <= 0 then return nil end
    return math.floor(plain * 10000 + 0.5)
  end
  local tail = tonumber(txt:match("[gsc](%d+%.?%d*)$"))
  if tail then
    if c then                                   -- nothing smaller than copper
    elseif s then c = tail
    elseif g then s = tail end
  end
  local v = math.floor((g or 0) * 10000 + (s or 0) * 100 + (c or 0) + 0.5)
  return v > 0 and v or nil
end

function M.DayLabel(day) -- e.g. "Jun 05"
  return date("%b %d", day * 86400 + M.C.SCAN_DAY_0)
end

-- ===== Realm name ============================================================
-- WoW Forever hides the realm since its hotfix of 20.11.2026: GetRealmName()
-- and GetNormalizedRealmName() answer "" and GetRealmID() 0. Every store keys
-- by realm, so Midas names it itself: the client's answer while there is one
-- (kept per character in MidasDB.realmSeen, by player GUID), else the realm
-- this character is stored under, else the realm of its ruleset the account
-- played on last (one auction house per ruleset; a Forever beta realm may hold
-- more characters, but not the latest). Without any of these: "Forever
-- <region> <ruleset>", which ends in its ruleset like the client's own names
-- ("CAMWOW EU5 Realm 7 PvE"). The character's entry, stored under that realm
-- at login, keeps the answer the same from then on.
local function secret(v) return issecretvalue and issecretvalue(v) end

-- the realm the client names, or nil when it names none
function M.ClientRealm()
  local r = GetRealmName and GetRealmName()
  if type(r) ~= "string" or secret(r) or not r:find("%S") then return nil end
  return r
end

-- the ruleset a realm name ends in, any case ("... PvE", "... PVP"), or nil.
-- RP-PvP realms spell theirs in two words ("CAMWOW EU4 Realm 9 RP PvP"): up to
-- 1.3.3 only the last one was read, which made them PvP realms - their scans
-- went to the PvP market of midasmarket.app and its prices came back.
local RULESET_WORDS = { pve = "PvE", pvp = "PvP", rp = "RP", rppvp = "RPPvP", hardcore = "Hardcore" }
function M.RealmRuleset(realm)
  if type(realm) ~= "string" then return nil end
  local a, b = realm:match("(%a+)[%s%-]+(%a+)%s*$")
  if a and a:lower() == "rp" and b:lower() == "pvp" then return "RPPvP" end
  local tail = realm:match("(%a+)%s*$")
  return tail and RULESET_WORDS[tail:lower()] or nil
end

-- the ruleset from the game rules (WoW Forever), nil when the client cannot tell
local function rulesRuleset()
  local GR, E = C_GameRules, Enum and Enum.GameRule
  if not (GR and GR.IsGameRuleActive and E) then return nil end
  local function on(rule)
    if rule == nil then return nil end
    local ok, v = pcall(GR.IsGameRuleActive, rule)
    if ok and not secret(v) and type(v) == "boolean" then return v end
  end
  if on(E.HardcoreRuleset) then return "Hardcore" end
  local pvp, rp = on(E.PvPRuleset), on(E.RPRuleset)
  if pvp == nil or rp == nil then return nil end
  if rp then return pvp and "RPPvP" or "RP" end
  return pvp and "PvP" or "PvE"
end

local REGIONS = { "US", "KR", "EU", "TW", "CN" }
local function regionCode()
  return GetCurrentRegion and REGIONS[GetCurrentRegion()] or "?"
end

local function playerGUID()
  local g = UnitGUID and UnitGUID("player")
  if type(g) == "string" and not secret(g) and g ~= "" then return g end
end

-- realm part of a stored character key "<name>-<realm>" ("" in the keys
-- Midas 1.3.2 wrote while the realm was hidden), nil for anything else
local function keyRealm(ck)
  return type(ck) == "string" and ck:match("^[^%-]*%-(.*)$") or nil
end
M.KeyRealm = keyRealm

-- newest bag, bank, mail or auction reading of a stored character (0 = none)
local CHAR_TS = { "bagsTs", "bankTs", "mailTs", "auctionsTs", "pendingTs" }
local function charLast(c)
  local t = 0
  if type(c) == "table" then
    for _, f in ipairs(CHAR_TS) do t = math.max(t, tonumber(c[f]) or 0) end
  end
  return t
end

-- the realm a character is stored under ("<full name>-<realm>"); with several
-- (an old entry of the same name on a Forever beta realm), the one of its
-- ruleset, then the one it played on last
local function storedRealm(chars, full, ruleset)
  local pre, cands = full .. "-", {}
  for ck, c in pairs(chars) do
    if type(ck) == "string" and #ck > #pre and ck:sub(1, #pre) == pre then
      local r = ck:sub(#pre + 1)
      if r:find("%S") then cands[#cands + 1] = { r = r, t = charLast(c) } end
    end
  end
  if #cands <= 1 then return cands[1] and cands[1].r end
  if ruleset then
    local keep = {}
    for _, x in ipairs(cands) do if M.RealmRuleset(x.r) == ruleset then keep[#keep + 1] = x end end
    if #keep > 0 then cands = keep end
  end
  local best, bt
  for _, x in ipairs(cands) do
    if not best or x.t > bt or (x.t == bt and x.r < best) then best, bt = x.r, x.t end
  end
  return best
end
M.StoredRealm = storedRealm

-- the realm of this ruleset the account played on last: the newest reading of
-- its characters or offer-book scan there; ties go to the realm with more
-- characters. A Forever beta realm can hold the most characters, never the
-- latest activity.
local function realmOfRuleset(db, chars, ruleset)
  if not ruleset then return nil end
  local last, count = {}, {}
  for ck, c in pairs(chars) do
    local r = keyRealm(ck)
    if r and r:find("%S") and M.RealmRuleset(r) == ruleset then
      count[r] = (count[r] or 0) + 1
      last[r] = math.max(last[r] or 0, charLast(c))
    end
  end
  local depth = db and type(db.depth) == "table" and db.depth
  if depth then
    for key, d in pairs(depth) do
      local r = type(key) == "string" and key:match("^(.-) %a+$")   -- "<realm> <Faction>"
      if r and last[r] and type(d) == "table" then last[r] = math.max(last[r], tonumber(d.ts) or 0) end
    end
  end
  local best, bt, bn
  for r, t in pairs(last) do
    local n = count[r]
    if not best or t > bt or (t == bt and (n > bn or (n == bn and r < best))) then best, bt, bn = r, t, n end
  end
  return best
end

-- The realm every store keys by. Second value: where the name comes from -
-- "client", "kept" (the client's last answer), "char" (own entry),
-- "ruleset" or "new".
local realmCache, realmKept
function M.RealmName()
  local r = M.ClientRealm()
  local db = type(MidasDB) == "table" and MidasDB or nil
  if r then
    if db and r ~= realmKept then
      local g = playerGUID()
      if g then
        if type(db.realmSeen) ~= "table" then db.realmSeen = {} end
        db.realmSeen[g] = r
        realmKept = r
      end
    end
    return r, "client"
  end
  if realmCache then return realmCache[1], realmCache[2] end
  local g = playerGUID()
  local kept = db and g and type(db.realmSeen) == "table" and db.realmSeen[g]
  local name, src
  if type(kept) == "string" and kept:find("%S") then
    name, src = kept, "kept"
  else
    local chars = db and type(db.chars) == "table" and db.chars or {}
    local rs = rulesRuleset()
    name, src = storedRealm(chars, M.PlayerFullName(), rs), "char"
    if not name then name, src = realmOfRuleset(db, chars, rs), "ruleset" end
    if not name then
      name = (M.CLIENT_FLAVOR == "forever" and "Forever " or "Classic ") .. regionCode() .. (rs and (" " .. rs) or "")
      src = "new"
    end
  end
  -- answered once per session (the saved data is there from login on)
  if db then realmCache = { name, src } end
  return name, src
end

-- Current realm key: realm + faction (every faction has its own auction house).
-- Always built from Midas' own realm name (M.RealmName). Up to 1.2.25 a loaded Auctionator
-- supplied the key instead ("PvP" on WoW Forever), which split one account's
-- characters as soon as Auctionator was on for some and off for others -
-- M.AdoptBorrowedKeys moves data stored under such a key home.
function M.RealmKey()
  local realm = M.RealmName()
  local faction = UnitFactionGroup("player")
  if faction and faction ~= "Neutral" then
    return realm .. " " .. faction
  end
  return realm
end

-- Neutral auction houses (Booty Bay, Gadgetzan, Everlook) are a market of their
-- own: other prices and a 15% cut instead of 5%. Their scans and prices are kept
-- under a separate key that no list, chart or sync ever reads. Detected by the
-- zone the player stands in while the AH is open - no faction AH shares one.
local NEUTRAL_MAPS = {
  [1434] = true, [1446] = true, [1452] = true,               -- Era: Stranglethorn Vale, Tanaris, Winterspring
  [224] = true, [210] = true, [71] = true, [83] = true,      -- modern maps: Stranglethorn, Cape, Tanaris, Winterspring
}
function M.InNeutralZone()
  if not (C_Map and C_Map.GetBestMapForUnit) then return false end
  local ok, id = pcall(C_Map.GetBestMapForUnit, "player")
  local hops = 0
  while ok and type(id) == "number" and hops < 6 do
    if NEUTRAL_MAPS[id] then return true end
    local info = C_Map.GetMapInfo and C_Map.GetMapInfo(id)
    id = info and info.parentMapID
    hops = hops + 1
  end
  return false
end

-- Second sign: the auctioneer. Faction auction houses are run by Horde or
-- Alliance NPCs, the neutral ones by the Steamwheedle Cartel (no faction group).
-- nil = no auctioneer to ask (no "npc" unit). The zone check alone missed some
-- neutral visits on WoW Forever (their scans landed in the Horde market, 22./23.11.2026).
function M.NeutralAuctioneer()
  if not (UnitExists and UnitFactionGroup and UnitExists("npc")) then return nil end
  local fg = UnitFactionGroup("npc")
  return fg ~= "Horde" and fg ~= "Alliance"
end

-- true while a neutral auction house is open (looked up once per visit)
function M.AtNeutralAH()
  if not M.AHOpen then return false end
  if M._ahNeutral == nil then
    M._ahNeutral = M.InNeutralZone() or M.NeutralAuctioneer() == true
    M._visitNeutral = M._ahNeutral
  end
  return M._ahNeutral
end

-- Where a scan being stored comes from. With the AH open: this AH. With it
-- closed: the last one visited - a quick or price scan cut short by closing the
-- AH is stored right after AUCTION_HOUSE_CLOSED and belongs to that visit.
function M.ScanFromNeutralAH()
  if M.AtNeutralAH() then return true end
  if M.AHOpen then return false end
  return M._visitNeutral == true
end

function M.NeutralKey() return M.RealmName() .. " Neutral" end
function M.IsNeutralKey(k) return type(k) == "string" and k:sub(-8) == " Neutral" end

-- An auction sale that paid the neutral 15% cut (the faction AH keeps 5%).
-- Below 1s the 1c rounding of the cut blurs the two rates.
function M.NeutralSale(e)
  return e.kind == "sold" and (e.gross or 0) >= 100 and (e.fee or 0) > e.gross * 0.10
end

-- WoW Forever characters carry a surname, which UnitName hands back as its
-- SECOND value (Era: the realm, nil for yourself). UnitNameUnmodified ignores
-- the "show my surname" display setting. Returns the full name and, when a
-- surname was found, the first name alone.
function M.PlayerFullName()
  local name, sur = (UnitNameUnmodified or UnitName)("player")
  if type(name) ~= "string" or name == "" or secret(name) then
    return UnitName("player") or "?", nil
  end
  if type(sur) ~= "string" or sur == "" or secret(sur)
     or sur == GetRealmName() or (GetNormalizedRealmName and sur == GetNormalizedRealmName()) then
    return name, nil
  end
  local tail = " " .. sur
  if name:sub(-#tail) == tail then return name, name:sub(1, #name - #tail) end
  return name .. tail, name
end

-- The client speaks surnames (WoW Forever): first names alone are not unique.
function M.SurnameClient()
  return (C_PlayerInfo and C_PlayerInfo.ShouldDisplaySurname) and true
    or (Constants and Constants.CharacterNameSeparatorConsts) and true or false
end

-- One canonical "<Name>-<Realm>" key per character, with the full two-part
-- name on WoW Forever. Without a surname from the client, a reported first
-- name that matches exactly ONE stored two-part character of this realm
-- reuses that key (the 1.2.4 beta-client fork guard).
function M.CharKey()
  local name, first = M.PlayerFullName()
  local realm = M.RealmName()
  local exact = name .. "-" .. realm
  local chars = M.db and M.db.chars
  if not chars or chars[exact] or first then return exact end
  local suffix, hit, n = "-" .. realm, nil, 0
  for key in pairs(chars) do
    if key:sub(-#suffix) == suffix then
      local kn = key:sub(1, #key - #suffix)
      if kn:sub(1, #name + 1) == name .. " " or name:sub(1, #kn + 1) == kn .. " " then
        hit = key; n = n + 1
      end
    end
  end
  if n == 1 then return hit end
  return exact
end

-- Where the scanned market lives, for exports/uploads: Era markets are per
-- realm + faction; Forever mega-realms are grouped by region + ruleset later.
function M.MarketInfo()
  local realm, src = M.RealmName()
  -- Forever realm names end in their ruleset ("CAMWOW EU5 Realm 7 PvE"); while
  -- the client hides the realm (20.11.2026) the game rules can tell it too
  local ruleset = M.RealmRuleset(realm) or (src ~= "client" and rulesRuleset()) or "Normal"
  if C_GameRules and C_GameRules.IsHardcoreActive then
    local ok, hc = pcall(C_GameRules.IsHardcoreActive)
    if ok and hc then ruleset = "Hardcore" end
  end
  return {
    client = M.MODERN_AH and "forever" or "era",
    region = regionCode(),
    realm = realm,
    faction = UnitFactionGroup("player") or "Neutral",
    ruleset = ruleset,
  }
end

-- Hardcore wording for characters kept out of the total (graveyard, fallen,
-- died) and the revive on a living login: on by itself on Hardcore realms,
-- opt-in elsewhere (Settings) for players who play hardcore by their own
-- rules. Without it the same list reads neutral ("not counted").
function M.HCMode()
  if M.db and M.db.config and M.db.config.hcMode == true then return true end
  if C_GameRules and C_GameRules.IsHardcoreActive then
    local ok, hc = pcall(C_GameRules.IsHardcoreActive)
    if ok and hc then return true end
  end
  return M.RealmRuleset(M.RealmName()) == "Hardcore"
end

-- /midas market: what Midas detects as this character's market, plus the raw
-- client answers behind it (realm/region/game-rules APIs). Printed AND kept in
-- MidasDB.config.marketProbe[char] so the values can be read after a /reload.
function M.PrintMarketProbe()
  local mk = M.MarketInfo()
  local raw = {}
  local function put(k, v) raw[#raw + 1] = { k, tostring(v) } end
  put("GetRealmName", GetRealmName and GetRealmName())
  put("GetNormalizedRealmName", GetNormalizedRealmName and GetNormalizedRealmName())
  local rn, rsrc = M.RealmName()
  put("Midas realm", rn .. " (" .. rsrc .. ")")
  put("ruleset from game rules", rulesRuleset())
  put("GetCurrentRegion", GetCurrentRegion and GetCurrentRegion())
  put("GetCurrentRegionName", GetCurrentRegionName and GetCurrentRegionName())
  put("WOW_PROJECT_ID", WOW_PROJECT_ID)
  -- neutral auction house signs (only meaningful with the AH open)
  local okMap, mapID = false, nil
  if C_Map and C_Map.GetBestMapForUnit then okMap, mapID = pcall(C_Map.GetBestMapForUnit, "player") end
  put("map", okMap and mapID or "none")
  put("auctioneer faction", (UnitExists and UnitExists("npc")) and (UnitFactionGroup("npc") or "none") or "no auctioneer")
  put("neutral AH", M.AHOpen and tostring(M.AtNeutralAH()) .. " (zone " .. tostring(M.InNeutralZone())
    .. ", auctioneer " .. tostring(M.NeutralAuctioneer()) .. ")" or "AH closed")
  -- every zero-argument Is*/Get*/Has* getter the game-rules / seasons APIs offer
  for _, ns in ipairs({ "C_GameRules", "C_Seasons" }) do
    local t = _G[ns]
    if type(t) == "table" then
      local names = {}
      for name, fn in pairs(t) do
        if type(fn) == "function" and (name:match("^Is") or name:match("^Get") or name:match("^Has")) then
          names[#names + 1] = name
        end
      end
      table.sort(names)
      for _, name in ipairs(names) do
        local ok, a, b = pcall(t[name])
        put(ns .. "." .. name, ok and (tostring(a) .. (b ~= nil and (", " .. tostring(b)) or "")) or "error")
      end
    else
      put(ns, "missing")
    end
  end
  local d = M.db and M.db.depth and M.db.depth[M.RealmKey()]
  local n = 0
  if d and d.items then for _ in pairs(d.items) do n = n + 1 end end
  M.Print(string.format("market: %s / %s / %s / %s / %s   (realm key \"%s\")",
    mk.client, mk.region, mk.realm, mk.faction, mk.ruleset, M.RealmKey()))
  M.Print(string.format("last offer-book scan: %s, %d items",
    (d and d.ts) and date("%Y-%m-%d %H:%M", d.ts) or "none", n))
  for _, r in ipairs(raw) do print("   " .. r[1] .. " = " .. r[2]) end
  if M.db and M.db.config then
    M.db.config.marketProbe = M.db.config.marketProbe or {}
    M.db.config.marketProbe[M.RealmKey() .. " / " .. (UnitName("player") or "?")] =
      { ts = time(), market = mk, raw = raw, scanTs = d and d.ts, scanItems = n }
  end
  M.Print("saved - /reload or log out so the values reach the saved-variables file.")
end

-- Events ---------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
f:RegisterEvent("AUCTION_HOUSE_SHOW")
f:RegisterEvent("AUCTION_HOUSE_CLOSED")
f:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    M.OnLogin()
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    M.OnItemInfo(...)
  elseif event == "AUCTION_HOUSE_SHOW" or event == "AUCTION_HOUSE_CLOSED" then
    M._ahNeutral = nil
    if event == "AUCTION_HOUSE_SHOW" then
      -- decide right away, while the auctioneer is the "npc" unit; it holds for
      -- this visit and for what is stored once it closes (M.ScanFromNeutralAH)
      local zone, npc = M.InNeutralZone(), M.NeutralAuctioneer()
      M._visitNeutral = zone or npc == true
      M._ahNeutral = M._visitNeutral
      -- the zone said "faction AH", the auctioneer "neutral": keep the last few
      -- such visits for bug reports (why the zone check misses some)
      if not zone and npc == true and M.db and M.db.config then
        local okM, mapID = false, nil
        if C_Map and C_Map.GetBestMapForUnit then okM, mapID = pcall(C_Map.GetBestMapForUnit, "player") end
        local guid = UnitGUID and UnitGUID("npc")
        local log = M.db.config.neutralProbe or {}
        M.db.config.neutralProbe = log
        log[#log + 1] = { ts = time(), map = okM and mapID or nil,
          -- Creature-0-server-instance-zone-npcID-spawn
          npc = type(guid) == "string" and tonumber(guid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)")) or nil }
        while #log > 5 do table.remove(log, 1) end
      end
    end
    -- once per session: say why the Midas numbers don't follow this AH
    if event == "AUCTION_HOUSE_SHOW" and not M._neutralNoted then
      C_Timer.After(1, function()
        if M.AtNeutralAH() and not M._neutralNoted then
          M._neutralNoted = true
          M.Print("Neutral auction house: Midas keeps its prices apart - a scan here is stored separately and never changes your "
            .. (UnitFactionGroup("player") or "faction") .. " prices.")
        end
      end)
    end
  end
end)

function M.OnLogin()
  MidasDB = MidasDB or { version = 1, realms = {}, config = {} }
  MidasDB.realms = MidasDB.realms or {}
  MidasDB.config = MidasDB.config or {}
  MidasDB.chars = MidasDB.chars or {}
  MidasDB.vendor = MidasDB.vendor or {}
  MidasDB.watch = MidasDB.watch or {}
  MidasDB.nw = MidasDB.nw or {}
  MidasDB.nwi = MidasDB.nwi or {}      -- intraday net-worth tail per realm (1W chart)
  MidasDB.intra = MidasDB.intra or {}  -- intraday price tails per realm (1W chart)
  MidasDB.alerts = MidasDB.alerts or {}  -- price alerts per realm (Charts tab)
  -- item names remembered from scans, so the Charts search covers the whole
  -- archive instead of only items the game client happens to have cached
  MidasDB.names = MidasDB.names or {}
  do
    -- heal "" names older scans stored for uncached items (blank rows in the
    -- browse view); the bootstrap below refills them where the trade log knows.
    -- Weapons/armor are purged too: scanned gear names carry a random suffix
    -- ("of the Whale") that doubled up on gr:-keyed chart titles - the client
    -- cache serves gear names instead (CommitScan no longer stores them).
    for id, nm in pairs(MidasDB.names) do
      local classID = (nm ~= "") and GetItemInfoInstant and select(6, GetItemInfoInstant(id))
      if nm == "" or classID == 2 or classID == 4 then MidasDB.names[id] = nil end
    end
    local idx = MidasDB.trade and MidasDB.trade.nameIndex
    if idx then
      for nm, id in pairs(idx) do
        if type(id) == "number" and type(nm) == "string" and not MidasDB.names[id] then
          MidasDB.names[id] = nm
        end
      end
    end
  end
  MidasDB.depth = MidasDB.depth or {}
  MidasDB.trade = MidasDB.trade or { log = {}, seen = {}, nameIndex = {} }
  -- every gold + item flow per character and day (Ledger.lua owns the layout)
  MidasDB.ledger = MidasDB.ledger or { v = 1 }
  -- recipes each character knows (Crafting.lua reads the profession windows)
  MidasDB.crafts = MidasDB.crafts or {}
  if MidasDB.config.share == nil then MidasDB.config.share = true end  -- community sync (opt-out)
  MidasDB.config.shareTrust = MidasDB.config.shareTrust or "all"
  -- cross-guild vicinity sync (SAY/YELL at the AH). Default on ("yell"); the hardened
  -- send pump keeps it under the client throttle. "/midas vicinity off" opts out.
  if MidasDB.config.vicinity == nil then MidasDB.config.vicinity = "yell" end
  M.db = MidasDB
  -- text size (Settings): before anything builds its font strings
  if M.Theme and M.Theme.SetFontScale then M.Theme.SetFontScale(MidasDB.config.fontScale or 1) end
  -- WoW Forever hides the realm since 20.11.2026: what 1.3.2 filed under an
  -- empty realm moves to the realm Midas names now, before anything else writes
  if M.AdoptHiddenRealm then M.AdoptHiddenRealm() end
  MidasDB.realmOf = nil   -- the first 1.3.3 test build kept guessed realms here
  if M.NWMigrate then M.NWMigrate() end   -- net worth history per realm+faction (1.2.1)
  if M.MergeForkedChars then M.MergeForkedChars() end   -- Forever short-name fork (1.2.4)
  if M.MergeImport then M.MergeImport() end
  -- One-shot: drop the old, sparse external import (guildmate data) by deleting
  -- every daily value before 27 May 2026; keeps the dense self-scanned history.
  if M.TrimBefore then
    M.TrimBefore(math.floor((time({ year = 2026, month = 5, day = 27, hour = 12 }) - M.C.SCAN_DAY_0) / 86400),
                 "20260611-drop-before-0527")
  end
  -- one-shot: clean phantom/incomplete trade entries logged by older builds
  if M.RepairTrades and M.db.config.tradeFix ~= "20260617" then
    M.db.config.tradeFix = "20260617"
    local fixed = M.RepairTrades()
    if fixed > 0 then M.Print("Trades: cleaned up " .. fixed .. " incomplete entries from older versions.") end
  end
  -- one-shot (v1.0.6): seed the sell-odds calibration from already-logged outcomes
  if M.SeedCurve and M.db.config.curveSeed ~= "20260723" then
    M.db.config.curveSeed = "20260723"
    local n = M.SeedCurve()
    if n > 0 then M.Print("Fair price calibrated from " .. n .. " of your logged auctions.") end
  end
  -- starter watchlist (1.2.7): one-shot seed for an EMPTY watchlist, so a new
  -- user starts from a proven base instead of a blank page. The set lives in
  -- Logic.lua (M.STARTER_WATCH); the Settings checkbox adds/removes it anytime.
  -- "fresh" = a genuinely new install (no news history, no price data): it gets
  -- the get-started tour below instead of the whole what's-new backlog.
  local fresh = (MidasDB.config.newsSeen == nil) and (next(MidasDB.realms) == nil)
  -- the Alt/Shift item shortcuts (UI.lua M.ModKey) start OFF on a new install;
  -- existing setups keep theirs (nil = on). One-shot: "fresh" stays true until
  -- the first scan, and a later login must not undo a user who switched them on.
  if MidasDB.config.modClicksInit == nil then
    if fresh and MidasDB.config.modClicks == nil then MidasDB.config.modClicks = false end
    MidasDB.config.modClicksInit = 1
  end
  if not MidasDB.config.starterDone then
    MidasDB.config.starterDone = 1
    if MidasDB.config.starterWatch ~= false and next(MidasDB.watch) == nil
       and M.ApplyStarterWatch then
      local n = M.ApplyStarterWatch(true)
      if n > 0 then
        M.Print("Watchlist: started you off with " .. n .. " proven items. Settings > \"Starter watchlist\" removes them again.")
      end
    end
  end
  -- onboarding milestones (1.2.13): one-shot cards keyed to the own-scan-DAY
  -- counter (UI.lua OB_STAGES; Data.lua bumps scanDays once per day with a
  -- stored scan). obStage = highest card index shown (0 = none yet). Accounts
  -- that pre-date the system are marked done (99): the cards must never fire
  -- retroactively.
  MidasDB.config.scanDays = MidasDB.config.scanDays or 0
  if MidasDB.config.obStage == nil then
    MidasDB.config.obStage = fresh and 0 or 99
  end
  -- beta servers rename realms; every store keys by realm+faction, so history
  -- then LOOKS gone (it sits under the old key). Say it once per YOUNG key -
  -- empty, or scanned for less than two weeks (the user may have scanned on
  -- the renamed realm before noticing) - while other realms hold data.
  if M.AdoptBorrowedKeys then M.AdoptBorrowedKeys() end   -- before the note: it may fill this key
  -- RP-PvP realms were read as PvP realms up to 1.3.3 (Midas and server):
  -- clean the server prices of that time, before the import below runs again
  if M.RepairServerPrices then M.RepairServerPrices() end
  do
    local rk = M.RealmKey and M.RealmKey()
    local cur = rk and MidasDB.realms[rk]
    local young, cutoff = true, (M.GetScanDay and M.GetScanDay() or 0) - 14
    if cur then
      for _, ser in pairs(cur) do          -- early exit: one old day disproves it
        for day in pairs(ser) do
          if type(day) == "number" and day < cutoff then young = false; break end
        end
        if not young then break end
      end
    end
    if rk and young then
      local others = false
      for k, st in pairs(MidasDB.realms) do
        if k ~= rk and not M.IsNeutralKey(k) and type(st) == "table" and next(st) then others = true; break end
      end
      MidasDB.config.realmHint = MidasDB.config.realmHint or {}
      if others and not MidasDB.config.realmHint[rk] then
        MidasDB.config.realmHint[rk] = 1
        M.Print("Little market data for this realm yet, but other realms are stored. Realm RENAMED? \"/midas realms\" lists them, \"/midas realmmerge <old name>\" moves that history here (works even after new scans).")
      end
    end
  end
  if M.InitMinimap then M.InitMinimap() end
  if M.SeedVendor then C_Timer.After(5, M.SeedVendor) end
  -- seed/refresh the archive from other addons' scan databases (Auctionator,
  -- aux) -- fingerprint-gated, background-chunked, idempotent (Import.lua)
  if M.ImportExternal then C_Timer.After(6, M.ImportExternal) end
  -- build the whole-archive analysis (Top Picks, ranking) in the background
  -- soon after login: the first open - usually together with the AH - then
  -- shows it at once instead of "analyzing market data..." for a second or
  -- two. A running import defers it; the import's end starts it anyway.
  if M.EnsureAnalysis then C_Timer.After(10, function() M.EnsureAnalysis() end) end
  M.Print("loaded. Open the auction house to run a full scan.  /midas = window.  v" .. M.version .. (M.MODERN_AH and "  (modern AH)" or ""))
  -- one-time privacy note (v1.1): the sync defaults are opt-out and were never
  -- announced anywhere -- say it once, then never again
  if M.db.config.privacyNote ~= 1 then
    M.db.config.privacyNote = 1
    M.Print("Midas shares scan data with guildmates & nearby Midas users at the AH (addon messages - invisible to other players). Toggle it in the Settings tab, or /midas share off.")
  end
  -- WoW Forever is live (05.11.2026): the beta's lost-save-data popup is gone
  M.db.config.foreverNote = nil
  -- one-time "what's new" spotlight for bigger features (UI.lua M.NEWS). A
  -- fresh install gets the onboarding welcome card instead (UI.lua OB_STAGES):
  -- the news would describe changes to a UI the player has never seen, and
  -- the welcome card hands out the full tour (M.ShowGuide) on its button.
  if fresh and M.ShowOnboard then
    MidasDB.config.newsSeen = MidasDB.config.newsSeen or {}
    for _, e in ipairs(M.NEWS or {}) do MidasDB.config.newsSeen[e.id] = true end
    C_Timer.After(9, function()
      if MidasDB.config.obStage == 0 and M.ShowOnboard then M.ShowOnboard(1) end
    end)
  elseif M.ShowWhatsNew then
    C_Timer.After(9, function()
      -- obStage 0 here = a fresh install whose welcome never displayed (quit
      -- within 9s of first login): re-offer it once
      if not M.ShowWhatsNew() and MidasDB.config.obStage == 0 and M.ShowOnboard then
        M.ShowOnboard(1)
      end
    end)
  end
end

-- /midas help: every user-facing command in one place (the README mirrors this)
function M.PrintHelp()
  M.Print("commands:")
  local lines = {
    "/midas  -  open / close the window",
    "/midas scan  -  full AH scan (auction house must be open)",
    "/midas auto  -  toggle auto-scan when the AH opens",
    "/midas quick  -  toggle the price scan / quick scan while the full scan is slow or on cooldown (WoW Forever)",
    "/midas status  -  archive status (items, days, last scan)",
    "/midas import  -  re-check the Auctionator / aux price databases",
    "/midas sells  -  top sell tips from your bags, bank & mail",
    "/midas worth  -  net worth per character (also stores today's snapshot)",
    "/midas trades  -  trade summary of the last 60 days",
    "/midas ledger  -  (beta) gold in/out summary   (recent: last bookings, check: session balance, debug: live)",
    "/midas timer  -  gold timer: gold + loot value per hour   (start, pause, reset, report)",
    "/midas tree [item]  -  (beta) crafting tree: material cost now / Fair, used in, disenchant value",
    "/midas lines  -  chart lines smooth (default) or crisp",
    "/midas perf  -  measure for 15 seconds what Midas does in the background",
    "/midas vendor  -  number of known vendor-sold items",
    "/midas prune  -  drop archive days older than 2 years",
    "/midas share on|off  -  community sync (guild)",
    "/midas datalink on|off|status|now|clear  -  Datalink: share your scans with midasmarket.app (off by default)",
    "/midas prices on|off|status  -  Datalink: server prices from the companion app",
    "/midas history  -  Datalink: state of the one-time price history upload",
    "/midas trust  -  accept synced data from everyone / guild only",
    "/midas vicinity say|yell|off  -  cross-guild sync at the AH",
    "/midas sync  -  send a sync manifest now",
    "/midas syncstatus  -  sync status in the chat",
    "/midas api  -  public API info for other addons",
    "/midas news  -  show the latest what's-new note again",
    "/midas discord  -  invite link to the Midas Discord (help, bugs, ideas)",
    "diagnostics:  /midas commprobe  -  sync transport test   \194\183   /midas market  -  detected market (realm, faction, ruleset)",
  }
  for _, l in ipairs(lines) do print("   " .. l) end
end

-- Item info arrived later -> drop name cache, refresh UI if open. Debounced at 1s:
-- during a big name-resolution wave (first analysis after login) hundreds of these
-- fire, and refreshing every 0.3s made the open tab visibly re-render nonstop.
local refreshPending = false
function M.OnItemInfo(itemID)
  if M.NameCacheDrop then M.NameCacheDrop(itemID) end
  if M.frame and M.frame:IsShown() and not refreshPending then
    refreshPending = true
    C_Timer.After(1.0, function()
      refreshPending = false
      if M.RefreshUI then M.RefreshUI() end
    end)
  end
end

-- ===== Realm rename migration ================================================
-- Beta servers rename realms; every store keys by realm+faction, so history
-- "disappears" under the old key (the data is intact). Merges ONE old key into
-- the current realm: price archive, trade log, net worth, alerts, char scopes.
function M.MergeRealm(old)
  local db = MidasDB
  local new = M.RealmKey()
  if not old or not old:find("%S") then return false, "same" end
  -- accept any case and outer spaces (the empty-realm keys of 1.3.2 on WoW
  -- Forever, " Alliance", are typed as "Alliance"); resolve against the keys
  -- that actually exist
  local want = old:lower():match("^%s*(.-)%s*$")
  local function resolve(tbl)
    if type(tbl) ~= "table" then return nil end
    if tbl[old] then return old end
    for k in pairs(tbl) do
      if type(k) == "string" and k:lower():match("^%s*(.-)%s*$") == want then return k end
    end
  end
  local oldKey = resolve(db.realms) or resolve(db.nw) or resolve(db.depth) or resolve(db.alerts)
    or (type(db.ledger) == "table" and resolve(db.ledger.d))
  if not oldKey then return false, "notfound" end
  if oldKey == new then return false, "same" end
  if M.IsNeutralKey(oldKey) then return false, "neutral" end   -- kept apart on purpose
  local moved = { items = 0, trades = 0, days = 0 }
  -- price archive: fill gaps; on a day collision keep min low / max qty, newer cur
  if db.realms and db.realms[oldKey] then
    local dst = db.realms[new]; if not dst then dst = {}; db.realms[new] = dst end
    for key, ser in pairs(db.realms[oldKey]) do
      moved.items = moved.items + 1
      local d2 = dst[key]
      if not d2 then dst[key] = ser
      else
        for day, v in pairs(ser) do
          local r = d2[day]
          if not r then d2[day] = v
          else
            if v.low and (not r.low or v.low < r.low) then r.low = v.low end
            if (v.qty or 0) > (r.qty or 0) then r.qty = v.qty end
            if (v.ts or 0) > (r.ts or 0) then r.cur = v.cur or r.cur; r.ts = v.ts end
          end
        end
      end
    end
    db.realms[oldKey] = nil
  end
  -- trade log: retag (the Trades UI filters on e.realm)
  if db.trade and db.trade.log then
    for _, e in ipairs(db.trade.log) do
      if e.realm == oldKey then e.realm = new; moved.trades = moved.trades + 1 end
    end
  end
  -- net worth: fill missing days; where both keys hold a day, the snapshot
  -- with the larger total stays (it counted more of the account)
  if db.nw and db.nw[oldKey] then
    local dst = db.nw[new]; if not dst then dst = {}; db.nw[new] = dst end
    for day, v in pairs(db.nw[oldKey]) do
      local cur = dst[day]
      if cur == nil then dst[day] = v; moved.days = moved.days + 1
      elseif type(v) == "table" and type(cur) == "table" and (v.t or 0) > (cur.t or 0) then dst[day] = v end
    end
    db.nw[oldKey] = nil
  end
  if db.config and db.config.nwHome == oldKey then db.config.nwHome = new end
  -- ledger: days and months per character; a character booked under both
  -- keys in one span (the day a realm went hidden) gets both bookings summed
  local function addTo(dst, src)
    for k, v in pairs(src) do
      if type(v) == "table" then
        if type(dst[k]) ~= "table" then dst[k] = {} end
        addTo(dst[k], v)
      elseif type(v) == "number" then
        local nv = (tonumber(dst[k]) or 0) + v
        if nv == 0 then dst[k] = nil else dst[k] = nv end
      end
    end
  end
  local L = db.ledger
  if type(L) == "table" then
    for _, fld in ipairs({ "d", "mo" }) do
      local t = L[fld]
      if type(t) == "table" and t[oldKey] then
        local dst = t[new]; if not dst then dst = {}; t[new] = dst end
        for span, chars in pairs(t[oldKey]) do
          local d2 = dst[span]
          if d2 == nil then dst[span] = chars
          elseif type(chars) == "table" and type(d2) == "table" then
            for ck, rec in pairs(chars) do
              if d2[ck] == nil then d2[ck] = rec
              elseif type(rec) == "table" and type(d2[ck]) == "table" then addTo(d2[ck], rec) end
            end
          end
        end
        t[oldKey] = nil
      end
    end
  end
  -- sell-odds calibration: move where the new key has none; live prices: the
  -- newer reading of an item stays
  if db.trade and type(db.trade.curve) == "table" and db.trade.curve[oldKey] then
    if db.trade.curve[new] == nil then db.trade.curve[new] = db.trade.curve[oldKey] end
    db.trade.curve[oldKey] = nil
  end
  if type(db.live) == "table" and db.live[oldKey] then
    local o, n = db.live[oldKey], db.live[new]
    if n == nil then db.live[new] = o
    elseif type(o) == "table" and type(n) == "table" then
      for key, v in pairs(o) do
        local w = n[key]
        if w == nil or (type(v) == "table" and type(w) == "table" and (tonumber(v.ts) or 0) > (tonumber(w.ts) or 0)) then
          n[key] = v
        end
      end
    end
    db.live[oldKey] = nil
  end
  -- alerts: keep the new realm's own limits, adopt the rest
  if db.alerts and db.alerts[oldKey] then
    local dst = db.alerts[new]; if not dst then dst = {}; db.alerts[new] = dst end
    for key, a in pairs(db.alerts[oldKey]) do
      if dst[key] == nil then dst[key] = a end
    end
    db.alerts[oldKey] = nil
  end
  -- short-lived per-realm tails: move only where the new key has nothing yet
  -- (the offer book: the newer scan stays)
  for _, fld in ipairs({ "nwi", "intra", "depth" }) do
    local t = db[fld]
    if t and t[oldKey] then
      local o, n = t[oldKey], t[new]
      if n == nil or (fld == "depth" and type(o) == "table" and type(n) == "table"
                      and (tonumber(o.ts) or 0) > (tonumber(n.ts) or 0)) then
        t[new] = o
      end
      t[oldKey] = nil
    end
  end
  -- characters: their net-worth scope follows the rename
  if db.chars then
    for _, ch in pairs(db.chars) do
      if type(ch) == "table" and ch.scope == oldKey then ch.scope = new end
    end
  end
  if M.DirtyAnalysis then M.DirtyAnalysis() end
  if M.RequestUIRefresh then M.RequestUIRefresh() end
  return true, moved, oldKey
end

-- ===== Borrowed realm keys ===================================================
-- Up to 1.2.25 a loaded Auctionator named the realm key. A character of THIS
-- realm whose scope is neither this realm's own key nor the other faction's
-- still points at such a borrowed key: its history is merged into the own key,
-- once, with or without Auctionator installed today. Left alone (a chat note
-- names the manual merge) when the borrowed key also holds characters of
-- another realm or of the other faction - that data cannot be told apart.
function M.AdoptBorrowedKeys()
  local db = MidasDB
  if not (db and type(db.chars) == "table" and UnitFactionGroup) then return 0 end
  local realm, faction = M.RealmName(), UnitFactionGroup("player")
  if not realm or not faction or faction == "Neutral" then return 0 end
  local own = M.RealmKey()
  local suffix = "-" .. realm
  local function here(ck) return type(ck) == "string" and ck:sub(-#suffix) == suffix end
  -- "<realm> <Faction>" of a realm characters are stored under is Midas' own
  -- key of that realm, not a borrowed one: a character that carries it while
  -- stored here (the realm Midas names for it changed, WoW Forever 20.11.2026)
  -- gets its stamp at login - merging that market into this one would mix two
  -- auction houses
  local function ownKeyElsewhere(s)
    local r = s:match("^(.+) Alliance$") or s:match("^(.+) Horde$")
    if not r then return false end
    for ck in pairs(db.chars) do
      if keyRealm(ck) == r then return true end
    end
    return false
  end
  local cand = {}
  for ck, c in pairs(db.chars) do
    local s = type(c) == "table" and c.scope
    -- keys of an empty realm (" Alliance", 1.3.2 on WoW Forever): M.AdoptHiddenRealm
    if type(s) == "string" and here(ck) and s ~= own and s:find("^%S")
       and s ~= realm .. " Alliance" and s ~= realm .. " Horde" and not M.IsNeutralKey(s)
       and not ownKeyElsewhere(s) then
      cand[s] = true
    end
  end
  local n = 0
  for key in pairs(cand) do
    local safe = true
    for ck, c in pairs(db.chars) do
      if type(c) == "table" and c.scope == key
         and (not here(ck) or (c.faction and c.faction ~= faction)) then
        safe = false; break
      end
    end
    if safe then
      local ok, info = M.MergeRealm(key)
      -- a key without market data of its own still names characters
      for _, c in pairs(db.chars) do
        if type(c) == "table" and c.scope == key then c.scope = own end
      end
      n = n + 1
      if ok then
        M.Print(string.format('Moved your history from "%s" to "%s": %d items, %d trade entries, %d net-worth days. Midas no longer takes its realm name from Auctionator, so all your characters here count together with or without it.',
          key, own, info.items or 0, info.trades or 0, info.days or 0))
      end
    else
      db.config = db.config or {}
      db.config.borrowHint = db.config.borrowHint or {}
      if not db.config.borrowHint[key] then
        db.config.borrowHint[key] = 1
        M.Print(string.format('Earlier data is stored under "%s", shared with characters of another realm or faction. "/midas realmmerge %s" moves it to "%s" - run it on the realm and faction it belongs to.',
          key, key, own))
      end
    end
  end
  return n
end

-- ===== Hidden realm (WoW Forever, 20.11.2026) ================================
-- Up to 1.3.2 Midas filed everything after the hotfix under an empty realm:
-- markets " Alliance" / " Horde", characters "<name>-". At login, while the
-- client hides the realm: every such character entry moves to its realm (this
-- character's to M.RealmName, any other one to the realm its own stored entry
-- names, the latest played of several) and this faction's market to
-- M.RealmKey() - unless a character of another realm wrote into it too: a
-- chat note then names the manual merge.
function M.AdoptHiddenRealm()
  local db = MidasDB
  if M.ClientRealm() or not (db and type(db.chars) == "table" and M.FoldChars) then return end
  local realm = M.RealmName()
  local chars = db.chars
  local mine = M.PlayerFullName() .. "-"
  local moves, n = {}, 0
  for ck, c in pairs(chars) do
    if type(c) == "table" and keyRealm(ck) == "" then
      local r = (ck == mine) and realm or storedRealm(chars, ck:sub(1, -2), nil)
      if r then moves[ck] = ck .. r; n = n + 1 end
    end
  end
  -- the empty-realm entry is the live one: its balances win
  if n > 0 then
    M.FoldChars(moves, false, true)
    M.Print(string.format("WoW Forever no longer names the realm: %d character entr%s moved back to %s realm.",
      n, n == 1 and "y" or "ies", n == 1 and "its" or "their"))
  end
  local faction = UnitFactionGroup and UnitFactionGroup("player")
  if not faction or faction == "Neutral" then return end
  local old, own = " " .. faction, M.RealmKey()
  if old == own then return end
  -- characters of another realm counted under the empty key: its data cannot be told apart
  local other
  for ck, c in pairs(chars) do
    local r = keyRealm(ck)
    if type(c) == "table" and c.scope == old and r and r ~= "" and r ~= realm then other = r; break end
  end
  -- every character of a known realm counts under its own key again (the fold
  -- above handed the empty key on to it)
  for ck, c in pairs(chars) do
    local r = keyRealm(ck)
    if type(c) == "table" and c.scope == old and r and r ~= "" then c.scope = r .. " " .. faction end
  end
  if not other then
    local ok, info = M.MergeRealm(old)
    if ok then
      M.Print(string.format('WoW Forever no longer names the realm: what Midas stored since then moved back to "%s" - %d items, %d trade entries, %d net-worth days.',
        own, info.items or 0, info.trades or 0, info.days or 0))
    end
  else
    db.config = db.config or {}
    db.config.hiddenHint = db.config.hiddenHint or {}
    local any = false
    for _, fld in ipairs({ "realms", "nw", "depth", "alerts" }) do
      if type(db[fld]) == "table" and db[fld][old] ~= nil then any = true; break end
    end
    if any and not db.config.hiddenHint[old] then
      db.config.hiddenHint[old] = 1
      M.Print(string.format('Data from the days WoW Forever stopped naming the realm is stored under "%s" for characters of several realms ("%s" too). "/midas realmmerge %s" moves it to "%s" - run it on a character of the realm it belongs to.',
        faction, other, faction, own))
    end
  end
end

-- Slash ----------------------------------------------------------------------
SLASH_MIDAS1 = "/midas"
SLASH_MIDAS2 = "/mid"
SlashCmdList["MIDAS"] = function(msg)
  local raw = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  msg = raw:lower()
  if msg == "scan" or msg == "ingest" then
    M.Scan(true)
  elseif msg == "auto" then
    M.db.config.autoScan = not (M.db.config.autoScan == true)
    M.Print("Auto-scan on AH open: " .. (M.db.config.autoScan and "ON" or "OFF") .. " (default OFF - use the Midas Scan button)")
  elseif msg == "quick" then
    if M.db.config.quickScan == false then M.db.config.quickScan = nil else M.db.config.quickScan = false end
    M.Print("Price scan and quick scan while the full scan is slow or on cooldown (WoW Forever): "
      .. (M.db.config.quickScan == false and "OFF" or "ON") .. " (default ON)")
  elseif msg == "status" then
    M.PrintStatus()
  elseif msg == "import" then
    if M.ImportExternal then M.ImportExternal(true) end
  elseif msg == "api" then
    if M.PrintAPIInfo then M.PrintAPIInfo() end
  elseif msg == "news" then
    if M.ShowWhatsNew then M.ShowWhatsNew(true) end
  elseif msg == "discord" then
    M.Print("Midas Discord: " .. M.DISCORD_URL)
    if M.ShowLinkCopy then M.ShowLinkCopy(M.DISCORD_URL, "Midas Discord") end
  elseif msg == "perf" then
    M.PerfReport()
  elseif msg == "ttchart" then
    if M.TooltipChartTest then M.TooltipChartTest() end
  elseif msg == "band" then
    if M.BandDebug then M.BandDebug() end
  elseif msg == "realms" then
    local rk = M.RealmKey()
    local any = false
    for k, st in pairs(MidasDB.realms or {}) do
      if type(st) == "table" then
        local n = 0
        for _ in pairs(st) do n = n + 1 end
        any = true
        M.Print(string.format("%s%s   \194\183   %d items", k,
          (k == rk) and "  (current)" or (M.IsNeutralKey(k) and "  (neutral auction houses, kept apart)" or ""), n))
      end
    end
    if not any then M.Print("No stored realms yet.") end
    M.Print('"/midas realmmerge <old name>" moves a renamed realm\'s history into the current one.')
  elseif msg:match("^realmmerge") then
    local arg = raw:match("^%S+%s+(.+)$")
    if not arg or arg == "" then
      M.Print('Usage: /midas realmmerge <old realm name>   ("/midas realms" lists them)')
    else
      local ok2, info, oldKey = M.MergeRealm(arg)
      if ok2 then
        M.Print(string.format('Merged "%s" into "%s": %d items, %d trade entries, %d net-worth days.',
          oldKey, M.RealmKey(), info.items or 0, info.trades or 0, info.days or 0))
      elseif info == "same" then
        M.Print("That IS the current realm - nothing to merge.")
      elseif info == "neutral" then
        M.Print("Neutral auction house prices stay apart - they would distort your own market.")
      else
        M.Print('No stored realm called "' .. arg .. '" - "/midas realms" lists them.')
      end
    end
  elseif msg == "keys" or msg:match("^keys%s") then
    local which, key = msg:match("^keys%s+(%a+)%s+(%a+)%s*$")
    if which and key and M.SetModKey then
      M.SetModKey(which, key)
    elseif M.ModKey then
      M.Print("click shortcuts: post to chat = " .. M.ModKey("post")
        .. "   AH search/chart = " .. M.ModKey("search")
        .. (M.db.config.modClicks == false and '   (master toggle OFF in Settings)' or ""))
      M.Print("rebind with: /midas keys post|search alt|ctrl|shift|off")
    end
  elseif msg == "alerts" then
    local al = M.db and M.db.alerts and M.db.alerts[M.RealmKey()]
    local n = 0
    if al then
      for key, a in pairs(al) do
        n = n + 1
        M.Print(string.format("alert: %s   %s%s", (M.ItemName and M.ItemName(key)) or key,
          a.below and ("below " .. M.MoneyPlain(a.below)) or "",
          a.above and ((a.below and "   " or "") .. "above " .. M.MoneyPlain(a.above)) or ""))
      end
    end
    if n == 0 then M.Print("alerts: none - set them in the Charts tab (ALERT below / above)") end
  elseif msg == "prune" then
    M.Prune()
  elseif msg == "sells" then
    M.PrintSells()
  elseif msg == "vendor" then
    M.Print("Vendor items known: " .. (M.VendorCount and M.VendorCount() or 0))
  elseif msg == "worth" then
    if M.PrintWorth then M.PrintWorth() end
  elseif msg == "trades" then
    if M.PrintTrades then M.PrintTrades() end
  elseif msg == "ledger" or msg:match("^ledger%s") then
    if M.LedgerSlash then M.LedgerSlash(msg:match("^ledger%s+(.-)%s*$") or "") end
  elseif msg == "tree" or msg:match("^tree%s") then
    if M.CraftSlash then M.CraftSlash(raw:match("^%a+%s+(.-)$") or "") end
  elseif msg == "lines" then
    -- smooth (soft-edged) chart lines are the default; crisp = plain pixels
    M.db.config.crispLines = (not M.db.config.crispLines) and true or nil
    M.Print("Chart lines: " .. (M.db.config.crispLines and "crisp (plain pixel lines)" or "smooth (default)"))
    if M.RerenderCharts then M.RerenderCharts() end
  elseif msg == "timer" or msg:match("^timer%s") then
    if M.GoldTimerSlash then M.GoldTimerSlash(msg:match("^timer%s+(.-)%s*$") or "") end
  elseif msg == "share" or msg == "share on" or msg == "share off" then
    if msg == "share on" then M.db.config.share = true
    elseif msg == "share off" then M.db.config.share = false
    else M.db.config.share = not (M.db.config.share == true) end
    M.Print("Community sync: " .. (M.db.config.share and "ON" or "OFF"))
    if M.CommStatus then M.CommStatus() end
  elseif msg == "datalink" or msg:match("^datalink%s") or msg == "prices" or msg:match("^prices%s") or msg == "history" then
    -- Datalink (midasmarket.app companion app, Datalink.lua)
    if M.DatalinkSlash then M.DatalinkSlash(msg) end
    if M.RefreshSettings then M.RefreshSettings() end
  elseif msg == "syncstatus" or msg == "commstatus" then
    if M.CommStatus then M.CommStatus() end
  elseif msg == "trust" then
    M.db.config.shareTrust = (M.db.config.shareTrust == "guild") and "all" or "guild"
    M.Print("Sync trust: " .. (M.db.config.shareTrust == "guild" and "GUILD ONLY" or "everyone (with sanity guards)"))
  elseif msg == "vicinity" or msg == "vicinity say" or msg == "vicinity yell" or msg == "vicinity off" then
    if msg == "vicinity say" then M.db.config.vicinity = "say"
    elseif msg == "vicinity yell" then M.db.config.vicinity = "yell"
    elseif msg == "vicinity off" then M.db.config.vicinity = "off"
    else  -- bare "/midas vicinity" cycles off -> say -> yell -> off
      local v = M.db.config.vicinity
      M.db.config.vicinity = (v == "off" or v == nil) and "say" or (v == "say" and "yell" or "off")
    end
    M.Print("Cross-guild vicinity sync: " .. string.upper(M.db.config.vicinity)
      .. (M.db.config.vicinity ~= "off" and "  (nearby players at the auction house)" or ""))
    if M.RefreshSettings then M.RefreshSettings() end
  elseif msg == "sync" then
    if M.CommSync then M.CommSync() end
  elseif msg == "commprobe" then
    if M.CommProbe then M.CommProbe() end
  elseif msg == "market" then
    M.PrintMarketProbe()
  elseif msg == "help" then
    M.PrintHelp()
  elseif msg == "" then
    M.Toggle()
  else
    -- a typo used to silently toggle the window; print the command list instead
    M.Print("Unknown command \"" .. msg .. "\".")
    M.PrintHelp()
  end
end
