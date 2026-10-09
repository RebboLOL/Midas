-- Midas – Core: namespace, constants, helpers, events, slash, init
local ADDON, M = ...
M.version = "1.2.11"
-- community server: Help tab, the get-started tour, what's new and /midas discord
M.DISCORD_URL = "https://discord.gg/CfZgeyxAn5"

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
  ANALYSIS_CHUNK = 300,   -- items processed per frame by the background analyzer (Logic.lua)
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
function M.DirtyAnalysis()
  M._analysisStale = true   -- keep M._analysis on screen until the rebuild lands
  M._rankCache    = nil
  M._lastDayCache = nil
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

-- Time / days ----------------------------------------------------------------
function M.GetScanDay()
  return math.floor((time() - M.C.SCAN_DAY_0) / 86400)
end

-- "4g50s" / "4.5" (bare number = gold) / "120s" / "45000c" -> copper, nil on junk
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
  local v = math.floor((g or 0) * 10000 + (s or 0) * 100 + (c or 0) + 0.5)
  return v > 0 and v or nil
end

function M.DayLabel(day) -- e.g. "Jun 05"
  return date("%b %d", day * 86400 + M.C.SCAN_DAY_0)
end

-- Current realm key. Self-contained: realm + faction (Classic AH is per faction).
-- Falls back to Auctionator's key if present, to stay compatible with old data.
function M.RealmKey()
  if Auctionator and Auctionator.State and Auctionator.State.CurrentRealm then
    return Auctionator.State.CurrentRealm
  end
  local realm = GetRealmName() or "Realm"
  local faction = UnitFactionGroup("player")
  if faction and faction ~= "Neutral" then
    return realm .. " " .. faction
  end
  return realm
end

-- One canonical "<Name>-<Realm>" key per character. WoW Forever allows
-- two-part names ("Deputy Willem"), and a beta client patch made UnitName
-- report only the first word -- which forked such characters into a second,
-- history-less entry. If the reported name and exactly ONE stored character
-- of this realm are the same name in short and long form, reuse the stored
-- key instead of minting a new one.
function M.CharKey()
  local name = UnitName("player") or "?"
  local realm = GetRealmName() or "?"
  local exact = name .. "-" .. realm
  local chars = M.db and M.db.chars
  if not chars or chars[exact] then return exact end
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
local REGIONS = { "US", "KR", "EU", "TW", "CN" }
function M.MarketInfo()
  local region = GetCurrentRegion and REGIONS[GetCurrentRegion()] or "?"
  local ruleset = "Normal"
  if C_GameRules and C_GameRules.IsHardcoreActive then
    local ok, hc = pcall(C_GameRules.IsHardcoreActive)
    if ok and hc then ruleset = "Hardcore" end
  end
  return {
    client = M.MODERN_AH and "forever" or "era",
    region = region,
    realm = GetRealmName() or "?",
    faction = UnitFactionGroup("player") or "Neutral",
    ruleset = ruleset,
  }
end

-- Events ---------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
f:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    M.OnLogin()
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    M.OnItemInfo(...)
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
  if MidasDB.config.share == nil then MidasDB.config.share = true end  -- community sync (opt-out)
  MidasDB.config.shareTrust = MidasDB.config.shareTrust or "all"
  -- cross-guild vicinity sync (SAY/YELL at the AH). Default on ("yell"); the hardened
  -- send pump keeps it under the client throttle. "/midas vicinity off" opts out.
  if MidasDB.config.vicinity == nil then MidasDB.config.vicinity = "yell" end
  M.db = MidasDB
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
  -- beta servers rename realms; every store keys by realm+faction, so history
  -- then LOOKS gone (it sits under the old key). Say it once per YOUNG key -
  -- empty, or scanned for less than two weeks (the user may have scanned on
  -- the renamed realm before noticing) - while other realms hold data.
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
        if k ~= rk and type(st) == "table" and next(st) then others = true; break end
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
  M.Print("loaded. Open the auction house to run a full scan.  /midas = window.  v" .. M.version .. (M.MODERN_AH and "  (modern AH)" or ""))
  -- one-time privacy note (v1.1): the sync defaults are opt-out and were never
  -- announced anywhere -- say it once, then never again
  if M.db.config.privacyNote ~= 1 then
    M.db.config.privacyNote = 1
    M.Print("Midas shares scan data with guildmates & nearby Midas users at the AH (addon messages - invisible to other players). Toggle it in the Settings tab, or /midas share off.")
  end
  -- WoW Forever beta: the client sometimes starts a session without the saved addon
  -- data (Blizzard bug, all addons). Explain it once. If the data fails to load, the
  -- flag is gone too, so the note comes back exactly when the user sees an empty archive.
  if M.MODERN_AH and M.db.config.foreverNote ~= 2 then
    M.db.config.foreverNote = 2
    C_Timer.After(4, M.ShowForeverNote)
  end
  -- one-time "what's new" spotlight for bigger features (UI.lua M.NEWS). A
  -- fresh install gets the get-started tour instead: the news would describe
  -- changes to a UI the player has never seen.
  if fresh and M.ShowGuide then
    MidasDB.config.newsSeen = MidasDB.config.newsSeen or {}
    for _, e in ipairs(M.NEWS or {}) do MidasDB.config.newsSeen[e.id] = true end
    C_Timer.After(9, function() M.ShowGuide() end)
  elseif M.ShowWhatsNew then C_Timer.After(9, function() M.ShowWhatsNew() end) end
end

function M.ShowForeverNote()
  if not (StaticPopupDialogs and StaticPopup_Show) then return end
  StaticPopupDialogs["MIDAS_FOREVER_NOTE"] = StaticPopupDialogs["MIDAS_FOREVER_NOTE"] or {
    text = "|cffE8B44AMidas|r - WoW Forever beta\n\n"
      .. "The Forever beta client sometimes fails to load saved addon data at login. "
      .. "When that happens, Midas - like every other addon - starts empty, and the price "
      .. "history, trades and net-worth records of this game version are lost.\n\n"
      .. "This is a known Blizzard beta bug, not a Midas bug, and only Blizzard can fix it. "
      .. "Your Classic Era data is not affected.\n\n"
      .. "If your archive is suddenly empty, just keep scanning - Midas rebuilds it.\n\n"
      .. "Community workaround until Blizzard fixes it: the free tool |cffE8B44AForeverSVFix|r "
      .. "(search it on GitHub, not made by Midas). Run it once with WoW closed - and again "
      .. "after every Midas update.",
    button1 = OKAY or "OK",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
  }
  StaticPopup_Show("MIDAS_FOREVER_NOTE")
end

-- /midas help: every user-facing command in one place (the README mirrors this)
function M.PrintHelp()
  M.Print("commands:")
  local lines = {
    "/midas  -  open / close the window",
    "/midas scan  -  full AH scan (auction house must be open)",
    "/midas auto  -  toggle auto-scan when the AH opens",
    "/midas status  -  archive status (items, days, last scan)",
    "/midas import  -  re-check the Auctionator / aux price databases",
    "/midas sells  -  top sell tips from your bags, bank & mail",
    "/midas worth  -  net worth per character (also stores today's snapshot)",
    "/midas trades  -  trade summary of the last 60 days",
    "/midas vendor  -  number of known vendor-sold items",
    "/midas prune  -  drop archive days older than 2 years",
    "/midas share on|off  -  community sync (guild)",
    "/midas trust  -  accept synced data from everyone / guild only",
    "/midas vicinity say|yell|off  -  cross-guild sync at the AH",
    "/midas sync  -  send a sync manifest now",
    "/midas syncstatus  -  sync status in the chat",
    "/midas api  -  public API info for other addons",
    "/midas news  -  show the latest what's-new note again",
    "/midas discord  -  invite link to the Midas Discord (help, bugs, ideas)",
    "diagnostics:  /midas commprobe  -  sync transport test",
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
  if not old or old == "" then return false, "same" end
  -- accept any case; resolve against the keys that actually exist
  local function resolve(tbl)
    if not tbl then return nil end
    if tbl[old] then return old end
    for k in pairs(tbl) do
      if type(k) == "string" and k:lower() == old:lower() then return k end
    end
  end
  local oldKey = resolve(db.realms) or resolve(db.nw) or resolve(db.depth) or resolve(db.alerts)
  if not oldKey then return false, "notfound" end
  if oldKey == new then return false, "same" end
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
  -- net worth: fill missing days (the new key's own snapshots win)
  if db.nw and db.nw[oldKey] then
    local dst = db.nw[new]; if not dst then dst = {}; db.nw[new] = dst end
    for day, v in pairs(db.nw[oldKey]) do
      if dst[day] == nil then dst[day] = v; moved.days = moved.days + 1 end
    end
    db.nw[oldKey] = nil
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
  for _, fld in ipairs({ "nwi", "intra", "depth" }) do
    local t = db[fld]
    if t and t[oldKey] then
      if t[new] == nil then t[new] = t[oldKey] end
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
        M.Print(string.format("%s%s   \194\183   %d items", k, (k == rk) and "  (current)" or "", n))
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
  elseif msg == "share" or msg == "share on" or msg == "share off" then
    if msg == "share on" then M.db.config.share = true
    elseif msg == "share off" then M.db.config.share = false
    else M.db.config.share = not (M.db.config.share == true) end
    M.Print("Community sync: " .. (M.db.config.share and "ON" or "OFF"))
    if M.CommStatus then M.CommStatus() end
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
