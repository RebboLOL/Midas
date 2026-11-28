-- Midas – Settings tab (since 1.3.9). Every option sits in one of eight groups
-- (left), with its explanation right under it instead of behind a hover. The
-- search box finds an option by its title, its description, its slash command
-- and the words people use for it (tags: "font", "gold icons", "lag" ...), and
-- says why a row matched. "Changed" lists what differs from a fresh install;
-- each changed option has a Reset, each group a "Reset group". "Show in <group>"
-- and M.OpenSettings / "/midas set <word>" jump to an option and mark it.
-- Rows are built once and only placed again: a keystroke, a group switch, a
-- changed value or a new text size re-run s.layout().
-- Replaces the two-column tab of 1.0 - 1.3.8 (UI.lua M.BuildSettings).
local ADDON, M = ...
local T = M.Theme
local C = T.C
local u = T.Unpack

local NAV_W, GAP = 176, 18        -- group list on the left, gap to the rows
local TOP_H = 64                  -- search row + suggestion chips
local PAD, RPAD = 12, 9           -- row padding: sides, top / bottom
local RESET_W = 40                -- room for "Reset" right of every control
local SB_W = 18                   -- the scroll bar sits right of the rows

local function hx(c) return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255) end
local HI, MUT, RED, GRN, WHT, GOLD = "|cffffe2a3", hx(C.muted), hx(C.red), hx(C.green), hx(C.text), hx(C.accent)
local LQ, RQ = "\226\128\156", "\226\128\157"   -- typographic quotes
local DOT = "  \194\183  "

local function cfg() return (M.db and M.db.config) or {} end
local function redraw() if M.RerenderCharts then M.RerenderCharts() end end
local function refreshUI() if M.RequestUIRefresh then M.RequestUIRefresh() end end
local function dl() return (M.DatalinkInfo and M.DatalinkInfo()) or {} end
local function lineH(size) return math.ceil(T.Scaled(size) * 1.3) end

-- ===== the groups and options ===============================================
local GROUPS = {
  { id = "ui",    name = "Interface",     blurb = "Text size, window behaviour, click shortcuts and help." },
  { id = "tip",   name = "Tooltips",      blurb = "What Midas adds to item tooltips in bags, bank, mail, chat links and at the AH." },
  { id = "ah",    name = "Auction house", blurb = "Scanning, and the helpers docked to the auction house window." },
  { id = "chart", name = "Charts",        blurb = "Timeframes and lines of the big charts and the small preview cards." },
  { id = "fair",  name = "Fair price",    blurb = "How fast the Fair price follows the market." },
  { id = "feat",  name = "Features",      blurb = "Switch whole modules on or off. Beta modules are marked." },
  { id = "share", name = "Data sharing",  blurb = "What Midas sends and receives: midasmarket.app and the in-game sync." },
  { id = "adv",   name = "Advanced",      blurb = "Sync log, price imports, archive upkeep and troubleshooting." },
}
local GROUP = {}
for _, g in ipairs(GROUPS) do GROUP[g.id] = g end

local KEYS = { { key = "ALT", label = "Alt" }, { key = "CTRL", label = "Ctrl" }, { key = "SHIFT", label = "Shift" }, { key = "OFF", label = "Off" } }
local RANGE4 = { { key = "7", label = "1W" }, { key = "30", label = "1M" }, { key = "90", label = "3M" }, { key = "all", label = "All" } }
local SPECIAL = { preview = true, fair = true, privacy = true, log = true }

-- last import of another addon's price database (Import.lua), this realm
local function importLine()
  local imp, rk, best = cfg().impSrc, M.RealmKey and M.RealmKey(), nil
  if type(imp) ~= "table" then return nil end
  for srcName, per in pairs(imp) do
    local rec = type(per) == "table" and per[rk]
    if rec and rec.at and (not best or rec.at > best.at) then best = { name = srcName, at = rec.at, items = rec.items or 0 } end
  end
  if not best then return nil end
  return best.name .. "  " .. WHT .. best.items .. "|r items" .. DOT .. date("%b %d", best.at)
end

local OPTS = {
  -- Interface -----------------------------------------------------------------
  { id = "textSize", g = "ui", sec = "Display", title = "Text size", kind = "slider", min = 18, max = 26, def = 20,
    get = function() return math.floor(T.fontScale * 20 + 0.5) end,
    set = function(v) M.SetFontScale(v / 20) end,
    fmt = function(v) return (v * 5) .. "%" end, minL = "90%", maxL = "130%",
    desc = "Makes all Midas text larger or smaller. The windows keep their size; item tooltips keep the game font.",
    tags = { "font", "font size", "bigger text", "smaller text", "scale", "zoom", "readability", "hard to read", "ui scale", "large text" } },
  { id = "minimap", g = "ui", sec = "Display", title = "Minimap button", kind = "switch", def = true,
    get = function() return not cfg().minimapHide end,
    set = function(on) if M.SetMinimapShown then M.SetMinimapShown(on) end end,
    desc = "The coin button at the minimap. Off hides it; /midas still opens the window.",
    tags = { "minimap", "icon", "map button", "hide icon", "clutter", "launcher" } },
  { id = "openWithAH", g = "ui", sec = "Display", title = "Open Midas with the auction house", kind = "switch", def = false,
    get = function() return cfg().openWithAH == true end,
    set = function(on) cfg().openWithAH = on and true or nil end,
    desc = "Opens the Midas window whenever you open the AH. The coin button next to Midas Scan opens it either way.",
    tags = { "auto open", "popup", "opens automatically", "window opens", "open on ah", "launch", "annoying window" } },
  -- noReset: a fresh install starts with the shortcuts off, older installs kept them on -
  -- neither is "changed", and Reset all must not switch working shortcuts off
  { id = "shortcuts", g = "ui", sec = "Click shortcuts", title = "Click shortcuts", kind = "switch", def = false, noReset = true,
    get = function() return cfg().modClicks ~= false end,
    set = function(on) if on then cfg().modClicks = nil else cfg().modClicks = false end end,
    desc = "Modifier clicks on items in Midas and on chat links. Plain clicks always work.",
    tags = { "alt click", "shift click", "modifier", "keybind", "hotkey", "ctrl click", "shortcuts" }, cmd = "/midas keys" },
  { id = "keyPost", g = "ui", sec = "Click shortcuts", title = "Post price card to chat", kind = "seg", opts = KEYS, def = "ALT",
    sub = true, parent = "shortcuts", badge = "NEW",
    get = function() return M.ModKey and M.ModKey("post") or "ALT" end,
    set = function(k) if M.SetModKey then M.SetModKey("post", k) end end,
    -- back to Alt without SetModKey's side effects (master switch, chat line); the
    -- search shortcut leaves Alt for its own default when it sat there
    reset = function()
      cfg().modPost = nil
      if M.ModKey and M.ModKey("search") == "ALT" then cfg().modSearch = nil end
    end,
    desc = "Click an item with this key to post its price card to chat. The other shortcut gives way when both want the same key.",
    tags = { "alt click", "price check", "post to chat", "link price", "keybind" } },
  { id = "keySearch", g = "ui", sec = "Click shortcuts", title = "Search item at the AH", kind = "seg", opts = KEYS, def = "SHIFT",
    sub = true, parent = "shortcuts", badge = "NEW",
    get = function() return M.ModKey and M.ModKey("search") or "SHIFT" end,
    set = function(k) if M.SetModKey then M.SetModKey("search", k) end end,
    reset = function()
      cfg().modSearch = nil
      if M.ModKey and M.ModKey("post") == "SHIFT" then cfg().modPost = nil end
    end,
    desc = "Click an item with this key to search it at the AH, or to open its chart from the AH.",
    tags = { "shift click", "search", "auction search", "find item", "keybind" } },
  { id = "guide", g = "ui", sec = "Help", title = "Get started guide", kind = "button", btn = "Open tour",
    act = function() if M.ShowGuide then M.ShowGuide() end end,
    desc = "Six steps through the Midas workflow: scan, watchlist, Fair, offer book, alerts and your own trades.",
    tags = { "tutorial", "help", "how to", "beginner", "onboarding", "tour", "first steps" } },
  { id = "news", g = "ui", sec = "Help", title = "What's new", kind = "button", btn = "Show notes",
    act = function() if M.ShowWhatsNew then M.ShowWhatsNew(true) end end,
    desc = "The release notes of the installed version.",
    tags = { "changelog", "patch notes", "update", "version", "release notes" }, cmd = "/midas news" },
  { id = "discord", g = "ui", sec = "Help", title = "Discord community", kind = "button", btn = "Get invite",
    act = function() if M.ShowLinkCopy then M.ShowLinkCopy(M.DISCORD_URL, "Midas Discord") end end,
    desc = "Help, bug reports and ideas.",
    tags = { "support", "bug", "report", "feedback", "contact", "help" }, cmd = "/midas discord" },

  -- Tooltips ------------------------------------------------------------------
  { id = "tooltipMode", g = "tip", sec = "Item tooltip", title = "Tooltip lines", kind = "seg", def = "full",
    opts = { { key = "full", label = "Full" }, { key = "reduced", label = "Reduced" }, { key = "off", label = "Off" } },
    get = function() return cfg().tooltipMode or "full" end,
    set = function(k) cfg().tooltipMode = k end,
    desc = "Full: signal, Current and Fair, sell speed, AH supply, sell odds and what you paid. Reduced: signal and Current vs Fair.",
    tags = { "tooltip", "hover", "mouseover", "price on hover", "item info", "less info", "too much text", "hide prices", "compact tooltip", "disable tooltip" } },
  { id = "tooltipChart", g = "tip", sec = "Item tooltip", title = "Tooltip chart", kind = "seg", def = "30",
    opts = { RANGE4[1], RANGE4[2], RANGE4[3], RANGE4[4], { key = "off", label = "Off" } },
    get = function() return cfg().tooltipRange or "30" end,
    set = function(k) cfg().tooltipRange = k end,
    desc = "A mini price chart docked to the item tooltip, with its own timeframe.",
    tags = { "mini chart", "sparkline", "graph on hover", "price history", "tooltip graph" } },
  { id = "craftLines", g = "tip", sec = "Item tooltip", title = "Craft cost lines", kind = "switch", def = true,
    get = function() return cfg().tooltipCraft ~= false end,
    set = function(on)
      if on then cfg().tooltipCraft = nil else cfg().tooltipCraft = false end
      redraw()
      if M.UpdateChartToggles then M.UpdateChartToggles() end
    end,
    desc = "Cost to make from the materials, profit after the AH cut, disenchant value and recipe payoff. Also the Crafted line in the charts.",
    tags = { "craft", "crafting cost", "profit", "disenchant", "de", "materials", "mats", "recipe", "enchanting" } },
  { id = "coinIcons", g = "tip", sec = "Item tooltip", title = "Coin icons", kind = "switch", def = false,
    get = function() return cfg().coinIcons == true end,
    set = function(on) cfg().coinIcons = on and true or nil end,
    desc = "Prices with the gold, silver and copper coins instead of the letters g, s and c.",
    tags = { "gold icons", "coins", "money format", "g s c", "currency", "icons instead of letters" } },
  { id = "tipPreview", g = "tip", sec = "Item tooltip", kind = "preview", browseOnly = true },

  -- Auction house -------------------------------------------------------------
  { id = "autoScan", g = "ah", sec = "Scanning", title = "Auto-scan when the AH opens", kind = "switch", def = false,
    get = function() return cfg().autoScan == true end,
    set = function(on) cfg().autoScan = on and true or nil end,
    desc = "Starts a full scan about 2 seconds after you open the AH. The server allows a full scan roughly every 15 minutes.",
    tags = { "scan", "auto scan", "getall", "full scan", "cooldown", "15 minutes", "automatic" }, cmd = "/midas auto" },
  { id = "quickScan", g = "ah", sec = "Scanning", title = "Price scan during the cooldown", kind = "switch", def = true, badge = "NEW",
    hidden = function() return not M.MODERN_AH end,
    get = function() return cfg().quickScan ~= false end,
    set = function(on) if on then cfg().quickScan = nil else cfg().quickScan = false end end,
    desc = "Keeps prices fresh between full scans. Modern auction house only (WoW Forever).",
    tags = { "quick scan", "price scan", "fast scan", "cooldown", "slow scan", "forever" }, cmd = "/midas quick" },
  { id = "ahBook", g = "ah", sec = "Docked helpers", title = "Offer book", kind = "switch", def = true,
    get = function() return cfg().ahBook ~= false end,
    set = function(on)
      if on then
        cfg().ahBook = nil
        if _G.MidasAHBook then _G.MidasAHBook._dismissed = nil end
      else
        cfg().ahBook = false
        if _G.MidasAHBook then _G.MidasAHBook:Hide() end
      end
    end,
    desc = "Docks the supply ladder of the picked item to the AH window. Its title opens the full chart.",
    tags = { "offer book", "ladder", "supply", "depth", "listings", "undercut", "competition", "dock" } },
  { id = "sellDock", g = "ah", sec = "Docked helpers", title = "Sell helper", kind = "switch", def = true,
    get = function() return cfg().sellDock ~= false end,
    set = function(on)
      if on then
        cfg().sellDock = nil
        if _G.MidasSellDock then _G.MidasSellDock._dismissed = nil end
        if M.ShowSellDock then M.ShowSellDock() end
      else
        cfg().sellDock = false
        if _G.MidasSellDock then _G.MidasSellDock:Hide() end
      end
    end,
    desc = "Your bag items with price data under the sell tab, best sale first. Click one, or drag it into any post slot.",
    tags = { "sell", "what to sell", "bags", "posting", "aux", "dock", "sell tab" } },

  -- Charts --------------------------------------------------------------------
  { id = "chartRange", g = "chart", sec = "Timeframes", title = "Big charts", kind = "seg", def = "all",
    opts = { { key = "1", label = "1D" }, RANGE4[1], RANGE4[2], RANGE4[3], RANGE4[4] },
    get = function() return cfg().chartRange or "all" end,
    set = function(k) if M.SetChartRange then M.SetChartRange(k) else cfg().chartRange = k end end,
    desc = "How far back the large charts look. One setting for all of them; the Charts and Net Worth tabs show the same choice.",
    tags = { "timeframe", "range", "history", "period", "days", "zoom out" } },
  { id = "previewRange", g = "chart", sec = "Timeframes", title = "Preview cards", kind = "seg", def = "all", opts = RANGE4,
    get = function() return cfg().previewRange or "all" end,
    set = function(k) cfg().previewRange = k; redraw() end,
    desc = "The hover charts on the Watchlist and Trades tabs and the net-worth card on Start.",
    tags = { "sparkline", "small chart", "preview", "watchlist chart", "hover chart" } },
  { id = "alertLines", g = "chart", sec = "Lines", title = "Price alert lines", kind = "switch", def = true,
    get = function() return cfg().alertLines ~= false end,
    set = function(on) if on then cfg().alertLines = nil else cfg().alertLines = false end redraw() end,
    desc = "Your below and above alerts as dashed lines in the big chart: green buy side, gold sell side.",
    tags = { "alerts", "price alert", "limit", "dashed line", "threshold", "notify" } },
  { id = "chartNeutral", g = "chart", sec = "Lines", title = "Neutral AH line", kind = "switch", def = false,
    get = function() return cfg().chartNeutral == true end,
    set = function(on) cfg().chartNeutral = on and true or nil; redraw() end,
    desc = "Your own scans at the neutral auction houses (Booty Bay, Gadgetzan, Everlook) as a rose line in the big chart. Never shared.",
    tags = { "neutral", "neutral ah", "booty bay", "gadgetzan", "everlook", "goblin", "cross faction" } },
  { id = "lineStyle", g = "chart", sec = "Lines", title = "Line style", kind = "seg", def = "smooth", badge = "NEW",
    opts = { { key = "smooth", label = "Smooth" }, { key = "crisp", label = "Crisp" } },
    get = function() return cfg().crispLines and "crisp" or "smooth" end,
    set = function(k) cfg().crispLines = (k == "crisp") or nil; redraw() end,
    desc = "Soft anti-aliased chart lines, or crisp pixel lines.",
    tags = { "smooth", "crisp", "jagged", "anti-aliasing", "blurry lines", "sharp lines" }, cmd = "/midas lines" },

  -- Fair price ----------------------------------------------------------------
  { id = "fairHalflife", g = "fair", sec = "Recency", title = "Half-life", kind = "slider", min = 2, max = 14, def = 7,
    get = function() return (M.FairHalflife and M.FairHalflife()) or 7 end,
    set = function(v)
      cfg().fairHalflife = (v ~= 7) and v or nil
      if M.DirtyAnalysis then M.DirtyAnalysis() end
      redraw(); refreshUI()
    end,
    live = function(v, s) if s.renderFair then s.renderFair(v) end end,
    fmt = function(v) return v .. " days" end, minL = "reactive", maxL = "steady",
    desc = "Short: Fair chases the latest scan days and reacts fast. Long: Fair smooths over two weeks and shrugs off short dips.",
    help = { "The market base behind Fair weighs each scan day by 0.5^(age / half-life), over the last 14 days.",
      "Changing it re-prices everything that reads Fair: signals, scores and the net-worth valuation. The scanned history stays untouched." },
    tags = { "fair price", "average", "smoothing", "half-life", "reactive", "weighting", "market value", "median", "valuation", "net worth value", "how is fair calculated" } },
  { id = "fairDemo", g = "fair", sec = "Recency", kind = "fair", browseOnly = true },

  -- Features ------------------------------------------------------------------
  { id = "crafting", g = "feat", sec = "Modules", title = "Crafting", kind = "switch", def = true, badge = "BETA",
    get = function() return (not M.CraftingOn) or M.CraftingOn() end,
    set = function(on) if M.SetCraftingOn then M.SetCraftingOn(on) end end,
    desc = "Prices every recipe from your scans: the Crafting tab, the Crafted line in charts and the craft lines in tooltips.",
    tags = { "crafting", "professions", "recipes", "tech tree", "make or buy", "craft profit", "disable crafting", "performance" } },
  { id = "ledger", g = "feat", sec = "Modules", title = "Ledger recording", kind = "switch", def = true, badge = "BETA",
    get = function() return cfg().ledgerOff ~= true end,
    set = function(on) cfg().ledgerOff = (not on) and true or nil end,
    desc = "Books every gold and item flow for the Ledger tab. Off stops new bookings; the history stays.",
    tags = { "ledger", "gold log", "income", "expenses", "bookkeeping", "where did my gold go", "gold tracking", "transactions" }, cmd = "/midas ledger" },
  { id = "hardcore", g = "feat", sec = "Net worth", title = "Hardcore characters", kind = "switch", def = false,
    get = function() return cfg().hcMode == true end,
    view = function() return M.HCMode and M.HCMode() or false end,
    locked = function() return cfg().hcMode ~= true and M.HCMode and M.HCMode() or false end,
    set = function(on) cfg().hcMode = on and true or nil; refreshUI() end,
    desc = "Characters you take out of net worth rest in a graveyard as fallen; logging in alive on one counts it again.",
    extra = function(o) if o.locked() then return MUT .. "Always on here: this realm plays by the Hardcore rules.|r" end end,
    tags = { "hardcore", "hc", "dead", "death", "graveyard", "fallen", "self-found", "exclude character", "net worth" } },
  { id = "starterWatch", g = "feat", sec = "Watchlist", title = "Starter watchlist", kind = "switch", def = true,
    get = function() return cfg().starterWatch ~= false end,
    set = function(on)
      if on then cfg().starterWatch = nil else cfg().starterWatch = false end
      local n = M.ApplyStarterWatch and M.ApplyStarterWatch(on) or 0
      if on then
        M.Print("Starter watchlist: " .. n .. " item" .. (n == 1 and "" or "s") .. " added.")
      else
        M.Print("Starter watchlist: " .. n .. " starter item" .. (n == 1 and "" or "s") .. " removed - your own picks stay.")
      end
      refreshUI()
    end,
    desc = "About 80 proven items for a new install. Off removes exactly those; your own picks stay.",
    tags = { "watchlist", "starter", "default items", "reset watchlist", "clear watchlist", "beginner" } },

  -- Data sharing --------------------------------------------------------------
  { id = "privacy", g = "share", sec = "At a glance", kind = "privacy", browseOnly = true },
  { id = "companion", g = "share", sec = "midasmarket.app \194\183 Datalink", title = "Midas Companion app", kind = "button", btn = "Get the app",
    btnShown = function() local i = dl(); return not (i.app or i.found) end,
    act = function() if M.ShowLinkCopy then M.ShowLinkCopy(M.DATALINK_URL, "Midas Companion") end end,
    status = function()
      local i = dl()
      if i.app then
        local t = GRN .. "v" .. i.app .. " found|r"
        if type(i.checked) ~= "number" or i.checked <= 0 then return t .. MUT .. DOT .. "no server check yet|r" end
        local days = math.floor((time() - i.checked) / 86400)
        if days >= 2 then return t .. GOLD .. DOT .. "no server check for " .. days .. " days|r" end
        return t .. MUT .. DOT .. "last check " .. date("%d.%m. %H:%M", i.checked) .. "|r"
      elseif i.found then
        return GRN .. "found|r" .. MUT .. DOT .. "an update shows its version here|r"
      end
      return RED .. "not found|r"
    end,
    desc = "The free desktop app that uploads what you share and brings the server prices of your market into the game.",
    tags = { "companion", "uplink", "desktop app", "download", "website", "midasmarket", "app" } },
  { id = "dlShare", g = "share", sec = "midasmarket.app \194\183 Datalink", title = "Share my scans with midasmarket.app", kind = "switch", def = false,
    get = function() return dl().share == true end,
    set = function(on) if M.DatalinkSetShare then M.DatalinkSetShare(on) end end,
    desc = "Prices and amounts from your AH scans, and once your last 90 days. Never character, guild or gold data.",
    extra = function()
      local i = dl()
      if i.legacy then
        if i.appReady then
          return RED .. "The old Midas_Uplink addon is still installed.|r" .. WHT .. " It is part of Midas now: quit the game and delete the Midas_Uplink folder in Interface\\AddOns - your settings carry over.|r"
        end
        return RED .. "The old Midas_Uplink addon is still installed.|r" .. WHT .. " Update the Midas Companion app (midasmarket.app/download), then delete the Midas_Uplink folder in Interface\\AddOns.|r"
      elseif i.share then
        local q, pq = i.queue or 0, i.pqueue or 0
        return string.format("Kept for the app  %s%d|r full %s" .. DOT .. "%s%d|r price %s%s",
          WHT, q, q == 1 and "scan" or "scans", WHT, pq, pq == 1 and "scan" or "scans",
          i.newest and (MUT .. DOT .. "newest " .. date("%d.%m. %H:%M", i.newest) .. "|r") or "")
      end
      return ""
    end,
    help = { "After every full scan Midas hands the offer book (the 20 cheapest prices of each item and how much is listed) to the companion app, which uploads it to midasmarket.app. Between full scans each complete price scan follows with the cheapest price and amount of each item. Once per market it also sends the daily prices of your last 90 days.",
      "Realm, faction and game version come along, and for the scanned items their names and item data - nothing about your characters, guild, gold or bags. Off clears what is still waiting." },
    tags = { "privacy", "upload", "share", "website", "datalink", "contribute", "what is sent", "data" }, cmd = "/midas datalink" },
  { id = "dlPrices", g = "share", sec = "midasmarket.app \194\183 Datalink", title = "Load server prices", kind = "switch", def = true,
    get = function() return dl().prices ~= false end,
    set = function(on) if M.DatalinkSetPrices then M.DatalinkSetPrices(on) end end,
    desc = "Fills the gaps in your history with the daily prices of your market. Your own scans always win. Applies after /reload.",
    extra = function()
      local i = dl()
      if not i.prices then return MUT .. "Server prices off - Midas ignores them from the next login or /reload.|r" end
      if i.market then
        return string.format("Server prices  %s%s|r" .. DOT .. "%s" .. DOT .. "%s%d items|r", WHT, i.market,
          date("%d.%m. %H:%M", i.priceTs or 0), WHT, i.priceItems or 0)
      end
      if i.app or i.found then return MUT .. "Server prices  none for this market yet - they arrive after the next /reload.|r" end
      return MUT .. "Server prices  none - the companion app brings them.|r"
    end,
    tags = { "server prices", "download prices", "missing data", "no data", "empty chart", "new realm", "history", "fill gaps" }, cmd = "/midas prices" },
  { id = "sync", g = "share", sec = "In game \194\183 Community sync", title = "Sync with my guild", kind = "switch", def = true,
    get = function() return cfg().share == true end,
    set = function(on)
      cfg().share = on and true or false
      if on and M.CommSync and C_Timer then C_Timer.After(0.3, function() M.CommSync() end) end
    end,
    desc = "Shares scans with your guild over hidden addon messages, invisible to other players.",
    tags = { "guild", "sync", "share", "community", "addon messages", "privacy", "comm" }, cmd = "/midas share" },
  { id = "trust", g = "share", sec = "In game \194\183 Community sync", title = "Accept data from", kind = "seg", def = "all",
    opts = { { key = "all", label = "Everyone" }, { key = "guild", label = "Guild only" } },
    get = function() return cfg().shareTrust == "guild" and "guild" or "all" end,
    set = function(k) cfg().shareTrust = k end,
    desc = "Whose shared scans Midas merges into your archive: everyone on the realm, or only your guild.",
    tags = { "trust", "guild only", "filter", "bad data", "fake prices", "manipulation" }, cmd = "/midas trust" },
  { id = "vicinity", g = "share", sec = "In game \194\183 Community sync", title = "Nearby Midas users", kind = "seg", def = "yell",
    opts = { { key = "off", label = "Off" }, { key = "say", label = "Say" }, { key = "yell", label = "Yell" } },
    get = function() return cfg().vicinity or "off" end,
    set = function(k) cfg().vicinity = k end,
    desc = "Cross-guild sync at the AH: only data manifests and requests, never bulk scans. Say reaches players next to you, Yell the whole building.",
    tags = { "cross-guild", "say", "yell", "nearby", "vicinity", "range", "other guilds" }, cmd = "/midas vicinity" },

  -- Advanced ------------------------------------------------------------------
  { id = "syncNow", g = "adv", sec = "Sync", title = "Sync now", kind = "button", btn = "Sync now",
    act = function() if M.CommSync then M.CommSync() end end,
    status = function()
      local info = M.CommInfo and M.CommInfo()
      if not info then return nil end
      local n = #(info.online or {})
      return (info.share and (GRN .. "on|r") or (RED .. "off|r")) .. DOT .. n .. " Midas user" .. (n == 1 and "" or "s") .. " online"
    end,
    desc = "Sends a sync manifest to your guild and to nearby users right away.",
    tags = { "sync now", "force sync", "refresh", "peers", "log", "status" }, cmd = "/midas sync" },
  { id = "syncLog", g = "adv", sec = "Sync", kind = "log", browseOnly = true },
  { id = "imports", g = "adv", sec = "Archive", title = "Price imports", kind = "button", btn = "Re-check",
    act = function() if M.ImportExternal then M.ImportExternal(true) end end,
    status = importLine,
    desc = "Reads the price databases of Auctionator and aux into your history.",
    tags = { "auctionator", "aux", "import", "other addons", "price database" }, cmd = "/midas import" },
  { id = "prune", g = "adv", sec = "Archive", title = "Archive cleanup", kind = "button", btn = "Clean up", confirm = true,
    act = function() if M.Prune then M.Prune() end end,
    desc = "Removes archive days older than two years. Saves memory and login time; it cannot be undone.",
    tags = { "delete old data", "storage", "memory", "savedvariables", "file size", "slow login", "prune", "clean up" }, cmd = "/midas prune" },
  { id = "realms", g = "adv", sec = "Archive", title = "Stored realms", kind = "button", btn = "List in chat",
    act = function() if SlashCmdList and SlashCmdList["MIDAS"] then SlashCmdList["MIDAS"]("realms") end end,
    desc = "Lists every realm Midas keeps data for. A realm was renamed? /midas realmmerge <old name> moves its history here.",
    tags = { "realm", "rename", "merge", "transfer", "lost data", "history missing", "realms", "realmmerge" }, cmd = "/midas realms" },
  { id = "perf", g = "adv", sec = "Troubleshooting", title = "Performance check", kind = "button", btn = "Measure 15 s",
    act = function() if M.PerfReport then M.PerfReport() end end,
    desc = "Measures for 15 seconds what Midas does in the background and prints it to chat.",
    tags = { "lag", "fps", "stutter", "performance", "slow", "cpu", "freeze" }, cmd = "/midas perf" },
  { id = "market", g = "adv", sec = "Troubleshooting", title = "Detected market", kind = "button", btn = "Details",
    act = function() if M.PrintMarketProbe then M.PrintMarketProbe() end end,
    status = function() return M.RealmKey and (WHT .. M.RealmKey() .. "|r") or nil end,
    desc = "What Midas detects as the market of this character: realm, faction and ruleset.",
    tags = { "realm", "faction", "ruleset", "market", "wrong realm", "diagnostics" }, cmd = "/midas market" },
}
local OPT = {}
for _, o in ipairs(OPTS) do
  OPT[o.id] = o
  o._tags = {}
  for i, t in ipairs(o.tags or {}) do o._tags[i] = t:lower() end
end
M.SETTINGS_OPTS, M.SETTINGS_GROUPS = OPTS, GROUPS

local SUGGEST = { "font size", "gold icons", "minimap", "auto open", "privacy", "alt click", "hardcore", "missing data" }

-- words of a query that say what to DO ("turn off", "change", "show") rather than
-- what to find; dropped unless the query has nothing else
local STOP = {}
for w in ("a an the to my me i how do does can is it of for in on off show hide turn change changing switch toggle "
  .. "enable disable set setting settings option options make get want where what"):gmatch("%S+") do STOP[w] = true end

-- ===== search ================================================================
local function variants(t)
  if #t > 3 and t:sub(-1) == "s" then return { t, t:sub(1, -2) } end
  return { t }
end
local function wordStart(s, i) return i == 1 or not s:sub(i - 1, i - 1):match("%w") end

-- the query's words, lower case, a leading "/" dropped ("/midas lines")
local function tokens(q)
  local out = {}
  for word in (q or ""):lower():gmatch("%S+") do
    local w = word:gsub("^/+", "")
    if w ~= "" then out[#out + 1] = w end
  end
  return out
end
local function hiList(toks)
  local out = {}
  for _, t in ipairs(toks) do for _, v in ipairs(variants(t)) do out[#out + 1] = v end end
  return out
end

-- text with every hit of the words in the highlight colour
local function hiText(text, toks)
  if not toks or #toks == 0 or not text or text == "" then return text or "" end
  local low, mark = text:lower(), {}
  for _, tk in ipairs(toks) do
    local i = 1
    while true do
      local a, b = low:find(tk, i, true)
      if not a then break end
      for j = a, b do mark[j] = true end
      i = b + 1
    end
  end
  local out, buf, cur = {}, {}, nil
  local function flush()
    if #buf > 0 then
      local t = table.concat(buf)
      out[#out + 1] = cur and (HI .. t .. "|r") or t
      buf = {}
    end
  end
  for j = 1, #text do
    local m = mark[j] == true
    if m ~= cur then flush(); cur = m end
    buf[#buf + 1] = text:sub(j, j)
  end
  flush()
  return table.concat(out)
end

-- nil when a word finds nothing; else { score, chip = why it matched }
local function match(o, toks, full)
  local title, desc, cmd = (o.title or ""):lower(), (o.desc or ""):lower(), (o.cmd or ""):lower()
  local grp = (GROUP[o.g].name .. " " .. (o.sec or "")):lower()
  local tags = o._tags
  local score, via = 0, {}
  for _, tk in ipairs(toks) do
    local best, how = 0, nil
    for _, v in ipairs(variants(tk)) do
      local ti = title:find(v, 1, true)
      if ti then
        local s1 = wordStart(title, ti) and 100 or 80
        if s1 > best then best, how = s1, "title" end
      end
      for _, tg in ipairs(tags) do
        local i = tg:find(v, 1, true)
        if i then
          local s2 = (i == 1) and 72 or (wordStart(tg, i) and 64 or 48)
          if s2 > best then best, how = s2, "tag" end
        end
      end
      if cmd ~= "" and cmd:find(v, 1, true) and best < 44 then best, how = 44, "cmd" end
      if grp:find(v, 1, true) and best < 32 then best, how = 32, "grp" end
      local di = desc:find(v, 1, true)
      if di then
        local s3 = wordStart(desc, di) and 26 or 18
        if s3 > best then best, how = s3, "desc" end
      end
    end
    if best == 0 then return nil end
    score = score + best
    via[#via + 1] = how
  end
  local f = (full or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local exactTag = false
  for _, tg in ipairs(tags) do if tg == f then exactTag = true break end end
  if exactTag then score = score + 60 elseif title:find(f, 1, true) then score = score + 50 end
  local allTitle, has = true, {}
  for _, h in ipairs(via) do has[h] = true; if h ~= "title" then allTitle = false end end
  local chip
  if not allTitle then
    if has.tag then
      local bt, bn = nil, 0
      for i, l in ipairs(tags) do
        local n = (l == f) and 1 or 0
        for _, tk in ipairs(toks) do
          for _, v in ipairs(variants(tk)) do if l:find(v, 1, true) then n = n + 1 break end end
        end
        if n > bn then bn, bt = n, o.tags[i] end
      end
      if bt then chip = "matched " .. LQ .. hiText(bt, hiList(toks)) .. RQ end
    end
    if not chip and has.cmd then chip = "matched the command " .. o.cmd end
    if not chip and has.desc then chip = "matched in the description" end
    if not chip and has.grp then chip = "matched the group " .. GROUP[o.g].name end
  end
  return { score = score, chip = chip }
end
M.SettingsMatch = match

-- ===== small widgets =========================================================
-- On/off switch with T.Checkbox's interface (b.checked, b:SetChecked, OnClick
-- flips it and calls back). locked = shown, not clickable.
local function Switch(parent, onToggle)
  local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
  b:SetSize(34, 18)
  b:SetBackdrop(T.FLAT)
  local knob = b:CreateTexture(nil, "OVERLAY")
  knob:SetSize(12, 12)
  b.checked = false
  function b:Paint(hot)
    knob:ClearAllPoints()
    if self.checked then
      self:SetBackdropColor(u(C.accent)); self:SetBackdropBorderColor(u(C.accent))
      knob:SetColorTexture(u(C.bg0)); knob:SetPoint("RIGHT", -3, 0)
    else
      self:SetBackdropColor(u(C.bg0)); self:SetBackdropBorderColor(u(hot and C.accent or C.borderlt))
      knob:SetColorTexture(u(C.sub)); knob:SetPoint("LEFT", 3, 0)
    end
    self:SetAlpha(self.locked and 0.5 or 1)
  end
  function b:SetChecked(v) self.checked = v and true or false; self:Paint(false) end
  b:SetScript("OnClick", function(self)
    if self.locked then return end
    self:SetChecked(not self.checked)
    if onToggle then onToggle(self.checked) end
  end)
  b:SetScript("OnEnter", function(self) self:Paint(true) end)
  b:SetScript("OnLeave", function(self) self:Paint(false) end)
  b:Paint(false)
  return b
end

-- a plain text button ("Reset", "Show in Tooltips  >")
local function LinkButton(parent, size, colorKey)
  local b = CreateFrame("Button", nil, parent)
  local fs = T.Text(b, size, colorKey, T.FONT_MED)
  fs:SetPoint("LEFT", 0, 0)
  b.fs, b._size, b._col = fs, size, colorKey
  function b:SetLabel(t)
    if t ~= nil then self._label = t end
    fs:SetText(self._label or "")
    self:SetSize(math.ceil(fs:GetStringWidth() or 0) + 2, lineH(self._size) + 4)
  end
  b:SetScript("OnEnter", function() fs:SetTextColor(u(C.text)) end)
  b:SetScript("OnLeave", function() fs:SetTextColor(u(C[colorKey])) end)
  return b
end

local function fitButton(b)
  b:SetWidth(math.ceil((b.text and b.text:GetStringWidth()) or 60) + 26)
  b:SetHeight(math.max(22, lineH(T.SIZE.body) + 6))
end

-- ===== the tooltip preview (mirrors Tooltip.lua's example output) ===========
local PREVIEW = {
  { "|cffE8B44AMidas|r",                            "|cff5CD178+18% above fair|r" },
  { "|cff5CD178Current  12g 34s|r",                 "Fair (~52%)  10g 50s" },
  { "Craft  |cffFDCC619g 40s|r  |cff5CD178+24%|r",  "|cff9E8CFAfair 9g 10s|r  |cff5CD178+20%|r" },
  { "Sells  ~6.0/day \194\183 Steady",               "Quick-sell  9g 80s" },
  { "In AH now:  14",                               "Avg in AH:  11" },
  { "|cff5CD178Sell odds at current price  ~44%|r", "" },
  { "You paid  8g 20s avg  (12 bought)",            "" },
}

local function buildPreview(r)
  r.cap = T.Text(r, T.SIZE.tiny, "muted", T.FONT_SEMI); r.cap:SetText("LIVE PREVIEW")
  local pv = CreateFrame("Frame", nil, r, "BackdropTemplate")
  pv:SetBackdrop(T.FLAT); pv:SetBackdropColor(0.03, 0.03, 0.06, 0.96); pv:SetBackdropBorderColor(0.42, 0.42, 0.50, 1)
  pv:SetSize(300, 135)
  r.pv = pv
  r.pvName = T.Text(pv, 13, nil, nil, true); r.pvName:SetTextColor(1, 1, 1); r.pvName:SetText("Thorium Bar")
  r.pvL, r.pvR = {}, {}
  for i = 1, #PREVIEW do
    r.pvL[i] = T.Text(pv, T.SIZE.small, "sub", nil, true)
    r.pvR[i] = T.Text(pv, T.SIZE.small, "sub", nil, true); r.pvR[i]:SetJustifyH("RIGHT")
  end
  r.pvOff = T.Text(pv, T.SIZE.small, "muted", nil, true); r.pvOff:SetText("No Midas lines on item tooltips.")
  r.note = T.Text(r, T.SIZE.small, "sub"); r.note:SetWordWrap(true); r.note:SetJustifyH("LEFT"); r.note:SetJustifyV("TOP")
  function r:fill()
    local c = cfg()
    local mode = c.tooltipMode or "full"
    local nShow = (mode == "off") and 0 or (mode == "reduced") and 3 or #PREVIEW
    local craft = c.tooltipCraft ~= false and (not M.CraftingOn or M.CraftingOn())
    local coins = M.CoinIconsOn and M.CoinIconsOn()
    self.pvName:ClearAllPoints(); self.pvName:SetPoint("TOPLEFT", 12, -8)
    local y = -26
    for i = 1, #PREVIEW do
      local show = i <= nShow and (i ~= 3 or craft)
      self.pvL[i]:SetShown(show); self.pvR[i]:SetShown(show)
      if show then
        self.pvL[i]:SetText(coins and M.CoinIcons and M.CoinIcons(PREVIEW[i][1]) or PREVIEW[i][1])
        self.pvR[i]:SetText(coins and M.CoinIcons and M.CoinIcons(PREVIEW[i][2]) or PREVIEW[i][2])
        self.pvL[i]:ClearAllPoints(); self.pvL[i]:SetPoint("TOPLEFT", 12, y)
        self.pvR[i]:ClearAllPoints(); self.pvR[i]:SetPoint("TOPRIGHT", -12, y)
        y = y - 15
      end
    end
    self.pvOff:SetShown(mode == "off")
    self.pvOff:ClearAllPoints(); self.pvOff:SetPoint("TOPLEFT", 12, -26)
    self.pv:SetHeight(((mode == "off") and 15 or (-y - 26)) + 26 + 8)
    local rng = c.tooltipRange or "30"
    local rtxt = ({ ["7"] = "last week", ["30"] = "last month", ["90"] = "last 3 months", all = "all history" })[rng]
    self.note:SetText("Follows the options above as you change them." .. "\n\n"
      .. (rtxt and ("The tooltip chart docks beside the tooltip and shows the " .. rtxt .. ".") or "The tooltip chart is off.")
      .. "\n\n" .. "Item tooltips use the game's own font, so Text size leaves them alone.")
  end
  function r:placeRow(w)
    self:fill()
    self.cap:ClearAllPoints(); self.cap:SetPoint("TOPLEFT", PAD, -RPAD)
    self.pv:ClearAllPoints(); self.pv:SetPoint("TOPLEFT", PAD, -RPAD - lineH(T.SIZE.tiny) - 6)
    local nx = PAD + 300 + 24
    self.note:ClearAllPoints(); self.note:SetPoint("TOPLEFT", nx, -RPAD - lineH(T.SIZE.tiny) - 6)
    self.note:SetWidth(math.max(120, w - nx - PAD))
    local h = RPAD + lineH(T.SIZE.tiny) + 6 + 135 + RPAD
    local nh = RPAD + lineH(T.SIZE.tiny) + 6 + math.ceil(self.note:GetStringHeight() or 0) + RPAD
    return math.max(h, nh)
  end
end

-- ===== the Fair demo (Charts.lua M.RenderFairBiasDemo) =======================
local FAIR_H = 150
local function buildFair(s, r)
  r.cap = T.Text(r, T.SIZE.tiny, "muted", T.FONT_SEMI)
  r.cap:SetText("LIVE DEMO  \194\183  A MARKET THAT DROPPED FROM ABOUT 12G TO 8G A WEEK AGO")
  r.canvas = CreateFrame("Frame", nil, r)
  r.canvas:SetHeight(FAIR_H)
  r.foot = T.Text(r, T.SIZE.small, "muted"); r.foot:SetWordWrap(true); r.foot:SetJustifyH("LEFT")
  r.foot:SetText("Hover the chart for the read-outs. Drag the half-life above and watch Fair change character.")
  function s.renderFair(hl)
    if not (r:IsShown() and M.RenderFairBiasDemo) then return end
    hl = hl or (M.FairHalflife and M.FairHalflife()) or 7
    local w, h = math.floor(r.canvas:GetWidth() or 0), math.floor(r.canvas:GetHeight() or 0)
    if r.fHl == hl and r.fW == w and r.fH == h and r.fScale == T.fontScale then return end
    r.fHl, r.fW, r.fH, r.fScale = hl, w, h, T.fontScale
    M.RenderFairBiasDemo(r.canvas, hl)
  end
  function r:placeRow(w)
    self.cap:ClearAllPoints(); self.cap:SetPoint("TOPLEFT", PAD, -RPAD)
    local cy = RPAD + lineH(T.SIZE.tiny) + 6
    self.canvas:ClearAllPoints(); self.canvas:SetPoint("TOPLEFT", PAD, -cy); self.canvas:SetWidth(w - 2 * PAD)
    self.foot:ClearAllPoints(); self.foot:SetPoint("TOPLEFT", PAD, -(cy + FAIR_H + 6)); self.foot:SetWidth(w - 2 * PAD)
    return cy + FAIR_H + 6 + math.ceil(self.foot:GetStringHeight() or lineH(T.SIZE.small)) + RPAD
  end
end

-- ===== what leaves the PC, at a glance =======================================
local function buildPrivacy(r)
  r.tiles = {}
  for i = 1, 4 do
    local t = T.Surface(r, "bg0", "border")
    t.label = T.Text(t, T.SIZE.tiny, "muted"); t.label:SetPoint("TOPLEFT", 10, -8); t.label:SetJustifyH("LEFT")
    t.label:SetWordWrap(true); t.label:SetJustifyV("TOP")
    t.value = T.Text(t, T.SIZE.body, "sub", T.FONT_SEMI); t.value:SetJustifyH("LEFT")
    r.tiles[i] = t
  end
  r.note = T.Text(r, T.SIZE.small, "sub"); r.note:SetWordWrap(true); r.note:SetJustifyH("LEFT")
  r.note:SetText("Never shared: your characters, guild members, gold or bags.")
  function r:fill()
    local i, c = dl(), cfg()
    local vic = c.vicinity or "off"
    local rows = {
      { "Scans to midasmarket.app", i.share == true, (i.share == true) and "On" or "Off" },
      { "Server prices to your game", i.prices ~= false, (i.prices ~= false) and "On" or "Off" },
      { "Scans with your guild", c.share == true, (c.share == true) and ((c.shareTrust == "guild") and "On, guild only" or "On") or "Off" },
      { "Nearby Midas users", vic ~= "off", (vic == "say") and "Say range" or ((vic == "yell") and "Yell range" or "Off") },
    }
    for k, t in ipairs(self.tiles) do
      t.label:SetText(rows[k][1])
      t.value:SetText(rows[k][3])
      t.value:SetTextColor(u(rows[k][2] and C.green or C.muted))
    end
  end
  function r:placeRow(w)
    self:fill()
    local tw = math.floor((w - 2 * PAD - 3 * 8) / 4)
    local lh = lineH(T.SIZE.tiny)
    for _, t in ipairs(self.tiles) do
      t.label:SetWidth(tw - 20)
      lh = math.max(lh, math.ceil(t.label:GetStringHeight() or 0))
    end
    local th = 8 + lh + 4 + lineH(T.SIZE.body) + 8
    for k, t in ipairs(self.tiles) do
      t:ClearAllPoints(); t:SetPoint("TOPLEFT", PAD + (k - 1) * (tw + 8), -RPAD); t:SetSize(tw, th)
      t.value:ClearAllPoints(); t.value:SetPoint("TOPLEFT", 10, -(8 + lh + 4)); t.value:SetWidth(tw - 20)
    end
    self.note:ClearAllPoints(); self.note:SetPoint("TOPLEFT", PAD, -(RPAD + th + 8)); self.note:SetWidth(w - 2 * PAD)
    return RPAD + th + 8 + math.ceil(self.note:GetStringHeight() or lineH(T.SIZE.small)) + RPAD
  end
end

-- ===== sync status + live log ================================================
local LOG_H = 150
local SYNC_TAG = { push = { "PUSH", "accent" }, pull = { "PULL", "green" }, warn = { "WARN", "red" }, info = { "INFO", "sub" } }
local function syncLine(e)
  local tag = SYNC_TAG[e.dir] or SYNC_TAG.info
  return MUT .. date("%H:%M:%S", e.t) .. "|r  " .. hx(C[tag[2]]) .. tag[1] .. "|r  " .. WHT .. (e.text or "") .. "|r"
end

local function statsText()
  local info = M.CommInfo and M.CommInfo()
  if not info then return "Comm module not loaded." end
  local statusCol = info.share and (GRN .. "ON|r") or (RED .. "OFF|r")
  local guildCol = info.guild and "" or ("   " .. RED .. "not in a guild|r - group and nearby only")
  local vic = info.vicinity or "off"
  local vicTxt = (vic == "off") and (MUT .. "off|r")
    or (WHT .. vic .. "|r  (AH " .. (info.ahOpen and (GRN .. "open|r") or (MUT .. "closed|r")) .. ")")
  local who
  local online = info.online or {}
  if #online == 0 then
    who = MUT .. "No other Midas users seen in the last 10 minutes.|r"
  else
    local parts = {}
    for i = 1, math.min(6, #online) do
      local p = online[i]
      parts[i] = WHT .. p.name .. "|r" .. (p.ver and (MUT .. " " .. p.ver .. "|r") or "")
    end
    who = "Midas users online (10 min):  " .. WHT .. #online .. "|r   " .. table.concat(parts, ", ")
      .. ((#online > 6) and (MUT .. ", +" .. (#online - 6) .. "|r") or "")
  end
  local thr = info.txThrottled or 0
  local sl = {
    "Sync  " .. statusCol .. guildCol .. "      cross-guild:  " .. vicTxt,
    who,
    "Received  " .. hx(C.mint) .. (info.rxRows or 0) .. "|r prices  (" .. (info.rxMsgs or 0) .. " msgs)" .. DOT .. "sent  "
      .. GOLD .. (info.txRows or 0) .. "|r prices  (" .. (info.txMsgs or 0) .. " msgs)",
    "Queue  " .. WHT .. math.max(0, info.queue or 0) .. "|r" .. ((thr > 0) and (DOT .. "throttled  " .. GOLD .. thr .. "|r") or ""),
  }
  if info.newer then
    sl[#sl + 1] = GOLD .. "Midas " .. info.newer .. " is out - players you sync with run it already.|r"
  end
  return table.concat(sl, "\n")
end

local function buildLog(s, r)
  r.stats = T.Text(r, T.SIZE.small, "sub"); r.stats:SetWordWrap(true); r.stats:SetJustifyH("LEFT"); r.stats:SetJustifyV("TOP")
  r.stats:SetSpacing(4)
  s.stats = r.stats
  r.cap = T.Text(r, T.SIZE.tiny, "muted", T.FONT_SEMI); r.cap:SetText("LIVE LOG")
  r.capR = T.Text(r, T.SIZE.tiny, "muted"); r.capR:SetText("PUSH = sent by you" .. DOT .. "PULL = received" .. DOT .. "wheel scrolls")
  r.box = T.Surface(r, "bg0", "border")
  r.box:SetHeight(LOG_H)
  local log = CreateFrame("ScrollingMessageFrame", nil, r.box)
  log:SetPoint("TOPLEFT", 7, -6); log:SetPoint("BOTTOMRIGHT", -7, 6)
  T.RegFont(log, T.FONT, T.SIZE.tiny)
  log:SetJustifyH("LEFT"); log:SetFading(false); log:SetMaxLines(300)
  log:EnableMouseWheel(true)
  log:SetScript("OnMouseWheel", function(self, d) if d > 0 then self:ScrollUp() else self:ScrollDown() end end)
  r.log, s.log = log, log
  r.clear = T.Button(r, "Clear view", 96, 20)
  r.clear:SetScript("OnClick", function() log:Clear() end)
  function s.refillLog()
    log:Clear()
    local list = M.SyncLog and M.SyncLog() or {}
    for _, e in ipairs(list) do log:AddMessage(syncLine(e)) end
    if #list == 0 then log:AddMessage(MUT .. 'No sync traffic yet - open the AH or click "Sync now".|r') end
    log:ScrollToBottom()
  end
  M.onSyncLog = function(e)
    if s.panel:IsVisible() and r:IsShown() then log:AddMessage(syncLine(e)) end
  end
  function r:placeRow(w)
    self.statsCache = statsText()
    self.stats:SetText(self.statsCache)
    self.stats:ClearAllPoints(); self.stats:SetPoint("TOPLEFT", PAD, -RPAD); self.stats:SetWidth(w - 2 * PAD)
    local y = RPAD + math.ceil(self.stats:GetStringHeight() or 60) + 12
    self.cap:ClearAllPoints(); self.cap:SetPoint("TOPLEFT", PAD, -y)
    self.capR:ClearAllPoints(); self.capR:SetPoint("LEFT", self.cap, "RIGHT", 10, 0)
    y = y + lineH(T.SIZE.tiny) + 4
    self.box:ClearAllPoints(); self.box:SetPoint("TOPLEFT", PAD, -y); self.box:SetWidth(w - 2 * PAD)
    y = y + LOG_H + 6
    fitButton(self.clear)
    self.clear:ClearAllPoints(); self.clear:SetPoint("TOPRIGHT", self, "TOPRIGHT", -PAD, -y)
    return y + self.clear:GetHeight() + RPAD
  end
end

-- ===== the tab ===============================================================
function M.BuildSettings(panel)
  local s = { panel = panel, cat = "tip", q = "", changedOnly = false, rows = {}, cards = {}, heads = {} }
  M.setUI = s

  -- search row: the box, the "Changed" filter
  local search = T.Input(panel, 600, 26, "Search settings: try " .. LQ .. "font size" .. RQ .. ", " .. LQ .. "gold icons" .. RQ
    .. " or " .. LQ .. "auto open" .. RQ, function(txt)
      local nq = txt or ""
      local fresh = nq ~= s.q
      s.q = nq
      if s.q ~= "" then s.hl = nil end
      if s.built then
        s.layout()
        if fresh and s.scroll then s.scroll:SetVerticalScroll(0) end
      end
    end)
  search:SetPoint("TOPLEFT", 0, 0)
  s.search = search
  -- empty the search box (its OnTextChanged follows in game; s.q is set here
  -- already so the caller's layout never sees the old words)
  function s.clearSearch()
    s.q = ""
    search.edit:SetText("")
  end
  local chg = T.Button(panel, "Changed", 110, 26)
  chg:SetPoint("TOPRIGHT", 0, 0)
  chg.count = T.Text(chg, T.SIZE.small, "accent", T.FONT_SEMI)
  s.chgBtn = chg
  local function paintChg(hot)
    local on = s.changedOnly and s.q == ""
    chg:SetBackdropColor(u(on and { C.accent[1], C.accent[2], C.accent[3], 0.16 } or C.bg2))
    chg:SetBackdropBorderColor(u((on or hot) and C.accent or C.border))
    chg.text:SetTextColor(u((on or hot) and C.text or C.sub))
  end
  s.paintChg = paintChg
  chg:SetScript("OnEnter", function() paintChg(true) end)
  chg:SetScript("OnLeave", function() paintChg(false) end)
  chg:SetScript("OnClick", function()
    s.changedOnly = not (s.changedOnly and s.q == "")
    s.hl = nil
    if s.q ~= "" then s.clearSearch() end
    s.layout()
  end)
  if T.HelpTip then
    T.HelpTip(chg, "Changed", { "Lists every option that differs from a fresh install, across all groups, so you can find and undo your changes in one place." })
  end

  -- suggestion chips
  s.tryL = T.Text(panel, T.SIZE.small, "muted"); s.tryL:SetText("Try")
  s.chips = {}
  for i, word in ipairs(SUGGEST) do
    local ch = T.Chip(panel, 20, true)
    ch:Set(word, nil, "accent", true)
    ch.word = word
    ch:SetScript("OnClick", function()
      s.q, s.hl = word, nil
      search.edit:SetText(word)
      s.layout()
      if s.scroll then s.scroll:SetVerticalScroll(0) end
    end)
    s.chips[i] = ch
  end

  -- group list
  s.nav = {}
  for i, g in ipairs(GROUPS) do
    local b = CreateFrame("Button", nil, panel)
    b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints(); b.bg:SetColorTexture(u(C.bg2)); b.bg:Hide()
    b.fs = T.Text(b, T.SIZE.body, "sub", T.FONT_MED); b.fs:SetPoint("LEFT", 10, 0); b.fs:SetText(g.name)
    b.n = T.Text(b, T.SIZE.tiny, "accent", T.FONT_SEMI); b.n:SetPoint("RIGHT", -10, 0); b.n:SetJustifyH("RIGHT")
    b.g = g
    b:SetScript("OnClick", function()
      s.cat, s.hl, s.changedOnly = g.id, nil, false
      if s.q ~= "" then s.clearSearch() end
    s.layout()
      if s.scroll then s.scroll:SetVerticalScroll(0) end
    end)
    b:SetScript("OnEnter", function() if not b.active then b.fs:SetTextColor(u(C.text)) end end)
    b:SetScript("OnLeave", function() if not b.active then b.fs:SetTextColor(u(C.sub)) end end)
    s.nav[i] = b
  end
  s.navNote = T.Text(panel, T.SIZE.tiny, "muted"); s.navNote:SetWordWrap(true); s.navNote:SetJustifyH("LEFT")
  s.navNote:SetText("Every option lives in one group. Search finds it under any name people use for it."
    .. "\n\nFrom chat:  /midas set <word>")

  -- header of the row list
  s.hTitle = T.Text(panel, T.SIZE.h1, "text", T.FONT_SEMI); s.hTitle:SetJustifyH("LEFT")
  s.hSub = T.Text(panel, T.SIZE.small, "sub"); s.hSub:SetWordWrap(true); s.hSub:SetJustifyH("LEFT")
  -- a reset that touches several options asks for a second click within 5 s
  local function confirmButton(b, label, fn)
    b.label = label
    b:SetScript("OnClick", function()
      local now = GetTime and GetTime() or 0
      if b.armedAt and now - b.armedAt < 5 and b.armedFor == (s.mode or "") .. ":" .. s.cat then
        b.armedAt = nil
        b.text:SetText(label); b.text:SetTextColor(u(C.text))
        fn()
      else
        b.armedAt, b.armedFor = now, (s.mode or "") .. ":" .. s.cat
        b.text:SetText("Click again to reset"); b.text:SetTextColor(u(C.red))
        if C_Timer then
          C_Timer.After(5, function()
            if b.armedAt == now then
              b.armedAt = nil
              b.text:SetText(label); b.text:SetTextColor(u(C.text))
              if s.built then s.layout() end
            end
          end)
        end
      end
      s.layout()
    end)
  end
  s.hReset = T.Button(panel, "Reset group", 100, 22)
  confirmButton(s.hReset, "Reset group", function()
    local list = {}
    for _, o in ipairs(OPTS) do if o.g == s.cat and s.isChanged(o) then list[#list + 1] = o end end
    s.resetList(list)
  end)
  s.hClear = T.Button(panel, "Clear search", 100, 22)
  s.hClear:SetScript("OnClick", function() s.clearSearch(); s.layout() end)
  s.hAll = T.Button(panel, "Reset all", 100, 22)
  confirmButton(s.hAll, "Reset all", function()
    local list = {}
    for _, o in ipairs(OPTS) do if s.isChanged(o) then list[#list + 1] = o end end
    s.resetList(list)
  end)

  -- the scrolling rows
  local scroll = CreateFrame("ScrollFrame", "MidasSettingsScroll", panel, "UIPanelScrollFrameTemplate")
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(600, 400)
  scroll:SetScrollChild(content)
  T.StyleScrollbar("MidasSettingsScroll")
  s.scroll, s.content = scroll, content
  s.empty = T.Text(content, T.SIZE.body, "sub"); s.empty:SetWordWrap(true); s.empty:SetJustifyH("CENTER")

  -- ----- values -------------------------------------------------------------
  function s.isChanged(o)
    if not (o.get and o.def ~= nil) or o.noReset or (o.hidden and o.hidden()) then return false end
    local ok, v = pcall(o.get)
    return ok and v ~= o.def
  end
  function s.apply(o, v)
    if o.set then
      local ok, err = pcall(o.set, v)
      if not ok and geterrorhandler then geterrorhandler()(err) end
    end
  end
  function s.resetOne(o)
    if o.reset then
      local ok, err = pcall(o.reset)
      if not ok and geterrorhandler then geterrorhandler()(err) end
    else
      s.apply(o, o.def)
    end
  end
  -- children (the shortcut keys) before their parent switch
  function s.resetList(list)
    for _, o in ipairs(list) do if o.parent then s.resetOne(o) end end
    for _, o in ipairs(list) do if not o.parent then s.resetOne(o) end end
  end
  -- a control changed a value: store it, then everything that shows it
  function s.setValue(o, v)
    local cur = o.get and o.get()
    if cur == v then return end
    s.apply(o, v)
    s.layout()
  end
  function s.act(o, r)
    if o.confirm then
      local now = GetTime and GetTime() or 0
      if not (r._armed and now - r._armed < 5) then
        r._armed = now
        r.btn.text:SetText("Click again")
        r.btn.text:SetTextColor(u(C.red))
        if C_Timer then
          C_Timer.After(5, function()
            if r._armed == now then r._armed = nil; r.btn.text:SetText(o.btn); r.btn.text:SetTextColor(u(C.text)) end
          end)
        end
        return
      end
      r._armed = nil
      r.btn.text:SetText(o.btn); r.btn.text:SetTextColor(u(C.text))
    end
    if o.act then
      local ok, err = pcall(o.act)
      if not ok and geterrorhandler then geterrorhandler()(err) end
    end
    s.layout()
  end

  -- ----- rows ----------------------------------------------------------------
  local baseLevel = content:GetFrameLevel() or 1
  local function buildRow(o)
    local r = CreateFrame("Frame", nil, content, "BackdropTemplate")
    r:SetFrameLevel(baseLevel + 3)
    r:SetBackdrop(T.FLAT); r:SetBackdropColor(0, 0, 0, 0); r:SetBackdropBorderColor(0, 0, 0, 0)
    r.o = o
    r.sep = r:CreateTexture(nil, "BORDER")
    r.sep:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.45); r.sep:SetHeight(1)
    r.sep:SetPoint("TOPLEFT", 1, 0); r.sep:SetPoint("TOPRIGHT", -1, 0)
    if o.kind == "preview" then buildPreview(r) return r end
    if o.kind == "fair" then buildFair(s, r) return r end
    if o.kind == "privacy" then buildPrivacy(r) return r end
    if o.kind == "log" then buildLog(s, r) return r end
    r.title = T.Text(r, T.SIZE.body, "text", T.FONT_MED); r.title:SetJustifyH("LEFT")
    r.badge = T.Text(r, T.SIZE.tiny, (o.badge == "BETA") and "purple" or "mint", T.FONT_SEMI)
    r.badge:SetText(o.badge == "NEW" and "NEW HERE" or (o.badge or ""))
    r.chg = T.Text(r, T.SIZE.tiny, "accent", T.FONT_MED); r.chg:SetText("changed")
    r.found = T.Text(r, T.SIZE.tiny, "accent", T.FONT_SEMI); r.found:SetText("FOUND VIA SEARCH")
    r.desc = T.Text(r, T.SIZE.small, "sub"); r.desc:SetWordWrap(true); r.desc:SetJustifyH("LEFT"); r.desc:SetJustifyV("TOP")
    r.extra = T.Text(r, T.SIZE.small, "sub"); r.extra:SetWordWrap(true); r.extra:SetJustifyH("LEFT"); r.extra:SetJustifyV("TOP")
    r.meta = T.Text(r, T.SIZE.tiny, "muted"); r.meta:SetJustifyH("LEFT")
    r.jump = LinkButton(r, T.SIZE.small, "accent")
    r.jump:SetScript("OnClick", function() s.jumpTo(o.id) end)
    r.reset = LinkButton(r, T.SIZE.tiny, "accent"); r.reset:SetLabel("Reset")
    r.reset:SetScript("OnClick", function() s.resetOne(o); s.layout() end)
    if T.HelpTip then
      T.HelpTip(r.reset, "Reset", { "Back to the default of a fresh install." })
    end
    if o.kind == "switch" then
      r.ctl = Switch(r, function(on) s.setValue(o, on) end)
    elseif o.kind == "seg" then
      r.seg = T.Segment(r, o.opts, function(k) s.setValue(o, k) end)
      r.ctl = r.seg.frame
      if o.id == "chartRange" and M.rangeSegs then M.rangeSegs[#M.rangeSegs + 1] = r.seg end
    elseif o.kind == "slider" then
      r.ctl = CreateFrame("Frame", nil, r)
      r.minL = T.Text(r.ctl, T.SIZE.tiny, "muted"); r.minL:SetText(o.minL or "")
      r.maxL = T.Text(r.ctl, T.SIZE.tiny, "muted"); r.maxL:SetText(o.maxL or "")
      r.val = T.Text(r.ctl, T.SIZE.small, "accent", T.FONT_SEMI); r.val:SetJustifyH("RIGHT")
      r.sl = T.Slider(r.ctl, 140, o.min, o.max, function(v, done)
        r.val:SetText(o.fmt(v))
        if o.live then o.live(v, s) end
        if done then s.setValue(o, v) end
      end)
    elseif o.kind == "button" then
      r.ctl = CreateFrame("Frame", nil, r)
      r.st = T.Text(r.ctl, T.SIZE.small, "sub"); r.st:SetJustifyH("RIGHT")
      r.btn = T.Button(r.ctl, o.btn, 100, 22)
      r.btn:SetScript("OnClick", function() s.act(o, r) end)
    end
    if o.help and T.HelpTip then
      r.tip = CreateFrame("Frame", nil, r)
      r.tip:SetPoint("TOPLEFT", r.title, "TOPLEFT", 0, 2); r.tip:SetPoint("BOTTOMRIGHT", r.title, "BOTTOMRIGHT", 0, -2)
      T.HelpTip(r.tip, o.title, o.help)
    end
    return r
  end
  for _, o in ipairs(OPTS) do s.rows[o.id] = buildRow(o) end
  -- compatibility names (Datalink.lua refresh, tests)
  s.dlApp, s.dlBox = s.rows.companion.st, s.rows.companion.btn
  s.dlShare, s.dlPrices = s.rows.dlShare.ctl, s.rows.dlPrices.ctl
  s.dlPriceLine, s.dlLegacy = s.rows.dlPrices.extra, s.rows.dlShare.extra

  -- the control's size; slider and button controls lay out their parts here
  local function ctlSize(r, o, rowW)
    if o.kind == "switch" then return 34, 18 end
    if o.kind == "seg" then return r.ctl:GetWidth() or 120, r.ctl:GetHeight() or 24 end
    if o.kind == "slider" then
      local a = math.ceil(r.minL:GetStringWidth() or 0)
      local b = math.ceil(r.maxL:GetStringWidth() or 0)
      local vw = math.ceil(math.max(56, T.Scaled(T.SIZE.small) * 5))
      r.minL:ClearAllPoints(); r.minL:SetPoint("LEFT", r.ctl, "LEFT", 0, 0)
      r.sl:ClearAllPoints(); r.sl:SetPoint("LEFT", r.ctl, "LEFT", a + 8, 0)
      r.maxL:ClearAllPoints(); r.maxL:SetPoint("LEFT", r.ctl, "LEFT", a + 8 + 140 + 8, 0)
      r.val:ClearAllPoints(); r.val:SetPoint("RIGHT", r.ctl, "RIGHT", 0, 0); r.val:SetWidth(vw)
      local w = a + 8 + 140 + 8 + b + 8 + vw
      r.ctl:SetSize(w, 20)
      return w, 20
    end
    if o.kind == "button" then
      local showBtn = (not o.btnShown) or o.btnShown()
      r.btn:SetShown(showBtn)
      local bw = 0
      if showBtn then fitButton(r.btn); bw = r.btn:GetWidth() end
      local st = o.status and o.status() or nil
      r.st:SetText(st or "")
      r.st:SetShown(st ~= nil and st ~= "")
      r.st:SetWidth(0)
      local natS = (r.st.GetUnboundedStringWidth or r.st.GetStringWidth)(r.st) or 0
      local sw = math.min(math.max(220, math.floor((rowW or 700) * 0.45)), math.ceil(natS) + 2)
      r.st:SetWidth(sw)
      r.btn:ClearAllPoints(); r.btn:SetPoint("RIGHT", r.ctl, "RIGHT", 0, 0)
      r.st:ClearAllPoints()
      if showBtn then r.st:SetPoint("RIGHT", r.btn, "LEFT", -10, 0) else r.st:SetPoint("RIGHT", r.ctl, "RIGHT", 0, 0) end
      local w = bw + ((st and st ~= "") and (sw + (showBtn and 10 or 0)) or 0)
      local h = math.max(showBtn and r.btn:GetHeight() or 0, lineH(T.SIZE.small))
      r.ctl:SetSize(math.max(1, w), h)
      return w, h
    end
    return 0, 0
  end

  -- one standard row at y: title line, description, extra line, why-it-matched
  local function placeStd(r, w, m)
    local o = r.o
    local mode = s.mode
    -- control value (a slider being dragged keeps its own)
    if o.kind == "switch" then
      local v = o.view and o.view() or o.get()
      r.ctl:SetChecked(v)
      r.ctl.locked = o.locked and o.locked() or nil
      r.ctl:Paint(false)
    elseif o.kind == "seg" then
      r.seg:Select(o.get())
    elseif o.kind == "slider" and not r.sl.dragging then
      local v = o.get()
      r.sl:Set(v); r.val:SetText(o.fmt(v))
    end
    local cw, ch = ctlSize(r, o, w)
    local changed = s.isChanged(o)
    local hlOn = (mode == "browse") and s.hl == o.id
    local parentOff = o.parent and OPT[o.parent] and not OPT[o.parent].get()
    local indent = (o.sub and mode == "browse") and 22 or 0
    local x0 = PAD + indent
    r.reset:SetLabel()
    local resetRoom = math.max(RESET_W, r.reset:GetWidth() + 14)
    local textW = math.max(140, w - x0 - PAD - resetRoom - cw - 18)
    local toks = (mode == "search") and s.hiToks or nil
    -- title line: title, badge, "changed", "FOUND VIA SEARCH"; a title wider
    -- than its room (large text sizes) gets cut before the marks, never the marks
    r.title:SetText(hiText(o.title, toks))
    r.title:ClearAllPoints(); r.title:SetPoint("TOPLEFT", x0, -RPAD)
    local marks = 0
    for _, f in ipairs({ { r.badge, o.badge ~= nil }, { r.chg, changed }, { r.found, hlOn } }) do
      if f[2] then marks = marks + 8 + math.ceil(f[1]:GetStringWidth() or 0) end
    end
    r.title:SetWidth(0)
    local natW = math.ceil((r.title.GetUnboundedStringWidth or r.title.GetStringWidth)(r.title) or 0) + 1
    r.title:SetWidth(math.max(40, math.min(natW, textW - marks)))
    local prev = r.title
    for _, f in ipairs({ { r.badge, o.badge ~= nil }, { r.chg, changed }, { r.found, hlOn } }) do
      f[1]:SetShown(f[2])
      if f[2] then f[1]:ClearAllPoints(); f[1]:SetPoint("LEFT", prev, "RIGHT", 8, 0); prev = f[1] end
    end
    local y = RPAD + lineH(T.SIZE.body) + 3
    r.desc:SetWidth(textW)
    r.desc:SetText(hiText(o.desc, toks))
    r.desc:ClearAllPoints(); r.desc:SetPoint("TOPLEFT", x0, -y)
    y = y + math.ceil(r.desc:GetStringHeight() or lineH(T.SIZE.small))
    local ex = o.extra and o.extra(o) or nil
    r.extra:SetShown(ex ~= nil and ex ~= "")
    r.extra:SetText(ex or "")
    if ex and ex ~= "" then
      r.extra:SetWidth(textW)
      r.extra:ClearAllPoints(); r.extra:SetPoint("TOPLEFT", x0, -(y + 4))
      y = y + 4 + math.ceil(r.extra:GetStringHeight() or lineH(T.SIZE.small))
    end
    -- meta: why it matched + the slash command; "Show in <group>" after it
    local parts = {}
    if m and m.chip then parts[#parts + 1] = m.chip end
    if o.cmd then parts[#parts + 1] = o.cmd end
    local meta = table.concat(parts, DOT)
    r.meta:SetText(meta); r.meta:SetShown(meta ~= "")
    local jump = mode ~= "browse"
    r.jump:SetShown(jump)
    if meta ~= "" or jump then
      local my = y + 5
      r.meta:ClearAllPoints(); r.meta:SetPoint("TOPLEFT", x0, -my)
      local jw = 0
      if jump then
        r.jump:SetLabel("Show in " .. GROUP[o.g].name .. "  \226\128\186")
        jw = r.jump:GetWidth() + 12
      end
      r.meta:SetWidth(0)
      local mw = math.ceil((r.meta.GetUnboundedStringWidth or r.meta.GetStringWidth)(r.meta) or 0) + 1
      r.meta:SetWidth(math.max(40, math.min(mw, textW - jw)))
      if jump then
        r.jump:ClearAllPoints()
        if meta ~= "" then r.jump:SetPoint("LEFT", r.meta, "RIGHT", 12, 0) else r.jump:SetPoint("TOPLEFT", x0, -my + 2) end
      end
      y = my + math.max(lineH(T.SIZE.tiny), jump and lineH(T.SIZE.small) or 0)
    end
    local h = math.max(y + RPAD, ch + 2 * RPAD)
    r:SetHeight(h)
    r.ctl:ClearAllPoints(); r.ctl:SetPoint("RIGHT", r, "RIGHT", -(PAD + resetRoom), 0)
    r.reset:SetShown(changed)
    r.reset:ClearAllPoints(); r.reset:SetPoint("RIGHT", r, "RIGHT", -PAD, 0)
    r:SetAlpha(parentOff and 0.5 or 1)
    if hlOn then
      r:SetBackdropColor(C.accent[1], C.accent[2], C.accent[3], 0.09)
      r:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.9)
    else
      r:SetBackdropColor(0, 0, 0, 0); r:SetBackdropBorderColor(0, 0, 0, 0)
    end
    return h
  end

  local function card(i)
    local c = s.cards[i]
    if not c then
      c = T.Surface(content, "bg1", "border")
      c:SetFrameLevel(baseLevel + 1)
      s.cards[i] = c
    end
    c:Show()
    return c
  end
  local function head(i)
    local h = s.heads[i]
    if not h then
      h = T.Text(content, T.SIZE.tiny, "muted", T.FONT_SEMI)
      h.sub = T.Text(content, T.SIZE.tiny, "muted")
      s.heads[i] = h
    end
    h:Show()
    return h
  end

  -- ----- the whole tab --------------------------------------------------------
  function s.layout()
    if not s.built then return end
    local W = panel:GetWidth() or 0
    if W < 400 then W = 952 end
    local q = s.q or ""
    local toks = tokens(q)
    local kept = {}
    for _, tk in ipairs(toks) do if not STOP[tk] then kept[#kept + 1] = tk end end
    if #kept > 0 then toks = kept end
    -- a word no option knows at all would empty every search ("change font size"):
    -- drop it, unless no word is known
    if #toks > 1 then
      local known = {}
      for _, tk in ipairs(toks) do
        for _, o in ipairs(OPTS) do
          if not o.browseOnly and not (o.hidden and o.hidden()) and match(o, { tk }, tk) then known[#known + 1] = tk break end
        end
      end
      if #known > 0 then toks = known end
    end
    s.toks, s.hiToks = toks, hiList(toks)
    s.mode = (#toks > 0) and "search" or (s.changedOnly and "changed" or "browse")
    local mode = s.mode

    -- search row + chips
    local nChanged = 0
    for _, o in ipairs(OPTS) do if s.isChanged(o) then nChanged = nChanged + 1 end end
    fitButton(chg)
    chg.count:SetText(nChanged)
    local cntW = math.ceil(chg.count:GetStringWidth() or 8)
    chg:SetWidth(math.max(110, chg:GetWidth() + cntW + 10))
    chg:SetHeight(26)
    chg.text:ClearAllPoints(); chg.text:SetPoint("CENTER", -math.floor((cntW + 8) / 2), 0)
    chg.count:ClearAllPoints(); chg.count:SetPoint("LEFT", chg.text, "RIGHT", 8, 0)
    paintChg(false)
    search:SetWidth(W - chg:GetWidth() - 10)
    s.tryL:ClearAllPoints(); s.tryL:SetPoint("TOPLEFT", 0, -38)
    local cx = math.ceil(s.tryL:GetStringWidth() or 20) + 10
    local ql = q:lower():gsub("^%s+", ""):gsub("%s+$", "")
    for _, ch in ipairs(s.chips) do
      ch.filled = ch.word == ql
      local wch = ch:Set(ch.word, nil, ch.filled and "text" or "accent", true)
      ch:ClearAllPoints(); ch:SetPoint("TOPLEFT", cx, -34)
      ch:SetShown(cx + wch <= W)
      cx = cx + wch + 6
    end

    -- results
    local list = {}      -- { title, sub, items = { { o, m } } }
    local hits = {}
    if mode == "browse" then
      local secs, by = {}, {}
      for _, o in ipairs(OPTS) do
        if o.g == s.cat and not (o.hidden and o.hidden()) then
          if not by[o.sec] then by[o.sec] = { title = o.sec, items = {} }; secs[#secs + 1] = by[o.sec] end
          local it = by[o.sec].items
          it[#it + 1] = { o = o }
        end
      end
      list = secs
    elseif mode == "search" then
      local per = {}
      for _, o in ipairs(OPTS) do
        if not o.browseOnly and not (o.hidden and o.hidden()) then
          local m = match(o, toks, q)
          if m then
            hits[#hits + 1] = o
            per[o.g] = per[o.g] or {}
            per[o.g][#per[o.g] + 1] = { o = o, m = m }
          end
        end
      end
      for _, g in ipairs(GROUPS) do
        local it = per[g.id]
        if it then
          table.sort(it, function(a, b)
            if a.m.score ~= b.m.score then return a.m.score > b.m.score end
            return a.o.id < b.o.id
          end)
          list[#list + 1] = { title = g.name, sub = #it .. (#it == 1 and " match" or " matches"), items = it, top = it[1].m.score, gi = #list }
        end
      end
      table.sort(list, function(a, b) if a.top ~= b.top then return a.top > b.top end return a.gi < b.gi end)
    else
      for _, g in ipairs(GROUPS) do
        local it = {}
        for _, o in ipairs(OPTS) do if o.g == g.id and s.isChanged(o) then it[#it + 1] = { o = o } end end
        if #it > 0 then list[#list + 1] = { title = g.name, sub = #it .. (#it == 1 and " option" or " options"), items = it } end
      end
    end

    -- group list
    local ny = -TOP_H
    local nh = math.max(26, lineH(T.SIZE.body) + 10)
    for _, b in ipairs(s.nav) do
      local active = mode == "browse" and b.g.id == s.cat
      local n = 0
      if mode == "search" then
        for _, o in ipairs(hits) do if o.g == b.g.id then n = n + 1 end end
      else
        for _, o in ipairs(OPTS) do if o.g == b.g.id and s.isChanged(o) then n = n + 1 end end
      end
      b.active = active
      b.bg:SetShown(active)
      b.fs:SetTextColor(u(active and C.accent or C.sub))
      b.n:SetText(n > 0 and n or "")
      b.n:SetTextColor(u(mode == "search" and C.text or C.accent))
      b:SetAlpha((mode == "search" and n == 0) and 0.4 or 1)
      b:ClearAllPoints(); b:SetPoint("TOPLEFT", 0, ny); b:SetSize(NAV_W, nh)
      ny = ny - nh - 2
    end
    s.navNote:ClearAllPoints(); s.navNote:SetPoint("TOPLEFT", 10, ny - 14); s.navNote:SetWidth(NAV_W - 14)
    local PH = panel:GetHeight() or 0
    if PH < 100 then PH = 426 end
    s.navNote:SetShown(-ny + 14 + math.ceil(s.navNote:GetStringHeight() or 0) <= PH)

    -- header
    local X = NAV_W + GAP
    local LW = W - X
    local hdr, sub
    if mode == "browse" then
      hdr, sub = GROUP[s.cat].name, GROUP[s.cat].blurb
    elseif mode == "search" then
      hdr = #hits .. (#hits == 1 and " result" or " results") .. " for " .. LQ .. q:gsub("^%s+", ""):gsub("%s+$", "") .. RQ
      sub = "Matches titles, descriptions, tags and slash commands. Change an option right here, or open it in its group."
    else
      hdr = "Changed from default"
      sub = nChanged .. (nChanged == 1 and " option differs" or " options differ") .. " from a fresh install."
    end
    local groupChanged = 0
    for _, o in ipairs(OPTS) do if o.g == s.cat and s.isChanged(o) then groupChanged = groupChanged + 1 end end
    local btn = (mode == "browse" and groupChanged > 0) and s.hReset or (mode == "search" and s.hClear)
      or (mode == "changed" and nChanged > 0 and s.hAll) or nil
    for _, b in ipairs({ s.hReset, s.hClear, s.hAll }) do b:SetShown(b == btn) end
    -- another group or view: an armed reset falls back to its label
    for _, b in ipairs({ s.hReset, s.hAll }) do
      if b.armedAt and b.armedFor ~= mode .. ":" .. s.cat then
        b.armedAt, b.armedFor = nil, nil
        b.text:SetText(b.label); b.text:SetTextColor(u(C.text))
      end
    end
    local bw = 0
    if btn then
      fitButton(btn); bw = btn:GetWidth() + 12
      btn:ClearAllPoints(); btn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -SB_W, -TOP_H)
    end
    s.hTitle:SetText(hdr)
    s.hTitle:ClearAllPoints(); s.hTitle:SetPoint("TOPLEFT", X, -TOP_H)
    s.hTitle:SetWidth(LW - bw - SB_W)
    s.hSub:SetText(sub)
    s.hSub:ClearAllPoints(); s.hSub:SetPoint("TOPLEFT", X, -(TOP_H + lineH(T.SIZE.h1) + 3))
    s.hSub:SetWidth(LW - bw - SB_W)
    local hh = lineH(T.SIZE.h1) + 3 + math.ceil(s.hSub:GetStringHeight() or lineH(T.SIZE.small)) + 12
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", X, -(TOP_H + hh))
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -SB_W, 0)
    local RW = LW - SB_W
    content:SetWidth(RW)

    -- rows
    -- only rows that leave the list are hidden: a row that stays never sees an
    -- OnHide (an open tooltip or a half-done click on it survives the re-layout)
    local inList = {}
    for _, sec in ipairs(list) do for _, it in ipairs(sec.items) do inList[it.o.id] = true end end
    for id, r in pairs(s.rows) do
      if not inList[id] then r:Hide() end
      r.rowY = nil
    end
    for _, c in ipairs(s.cards) do c:Hide() end
    for _, h in ipairs(s.heads) do h:Hide(); h.sub:Hide() end
    local y, ci = 0, 0
    for _, sec in ipairs(list) do
      ci = ci + 1
      local h = head(ci)
      h:SetText(sec.title:upper())
      h:ClearAllPoints(); h:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -y)
      if sec.sub then
        h.sub:SetText(sec.sub); h.sub:Show()
        h.sub:ClearAllPoints(); h.sub:SetPoint("LEFT", h, "RIGHT", 10, 0)
      end
      y = y + lineH(T.SIZE.tiny) + 6
      local top = y
      for i, it in ipairs(sec.items) do
        local r = s.rows[it.o.id]
        r:Show()
        r:ClearAllPoints(); r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y); r:SetWidth(RW)
        r.sep:SetShown(i > 1)
        local rh
        if r.placeRow then
          rh = r:placeRow(RW)
          r:SetHeight(rh)
        else
          rh = placeStd(r, RW, it.m)
        end
        r.rowY = y
        y = y + rh
      end
      local c = card(ci)
      c:ClearAllPoints(); c:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -top); c:SetSize(RW, math.max(1, y - top))
      y = y + 16
    end
    local empty = (mode == "search" and #hits == 0) or (mode == "changed" and nChanged == 0)
    s.empty:SetShown(empty)
    if empty then
      s.empty:SetWidth(RW - 40)
      s.empty:ClearAllPoints(); s.empty:SetPoint("TOP", content, "TOP", 0, -30)
      if mode == "search" then
        s.empty:SetText(WHT .. "Nothing matches " .. LQ .. q .. RQ .. "|r\n\nTry a shorter word or one of the suggestions above. Missing an option? Tell us on Discord - the word you searched becomes a tag.")
      else
        s.empty:SetText(WHT .. "Everything is on its default.|r\n\nOptions you change show up here, so you can find and undo them in one place.")
      end
      y = 120
    end
    content:SetHeight(math.max(1, y))
    local hlRow = s.rows.fairHalflife
    if s.rows.fairDemo:IsShown() and s.renderFair and not (hlRow.sl and hlRow.sl.dragging) then s.renderFair() end
    if s.rows.syncLog:IsShown() and not s._logFilled then s._logFilled = true; s.refillLog() end
    if s.rows.syncLog:IsShown() == false then s._logFilled = nil end
    s.liveSig = s.signature()
  end

  -- what the 1 s ticker watches: live texts that may change a row's height
  -- (values changed by a slash command while the tab is open show at once too)
  function s.signature()
    local i = dl()
    local parts = { tostring(i.app), tostring(i.found), tostring(i.checked), tostring(i.share), tostring(i.prices),
      tostring(i.market), tostring(i.priceTs), tostring(i.priceItems), tostring(i.queue), tostring(i.pqueue),
      tostring(i.newest), tostring(i.legacy), tostring(i.appReady), importLine() or "",
      tostring(s.rows.syncNow:IsShown() and OPT.syncNow.status() or ""), tostring(T.fontScale) }
    for _, o in ipairs(OPTS) do
      if o.get then
        local ok, v = pcall(o.get)
        parts[#parts + 1] = ok and tostring(v) or "?"
      end
      if o.view then parts[#parts + 1] = tostring(o.view()) end
    end
    return table.concat(parts, "|")
  end
  function s.live()
    if s.signature() ~= s.liveSig then s.layout() return end
    -- the sync counters change with every message: new text in place, a new
    -- layout only when the block grows or shrinks
    local lr = s.rows.syncLog
    if lr:IsShown() then
      local t = statsText()
      if t ~= lr.statsCache then
        lr.statsCache = t
        local h0 = math.ceil(lr.stats:GetStringHeight() or 0)
        lr.stats:SetText(t)
        if math.ceil(lr.stats:GetStringHeight() or 0) ~= h0 then s.layout() end
      end
    end
  end

  function s.jumpTo(id)
    local o = OPT[id]
    if not o then return end
    s.cat, s.changedOnly = o.g, false
    if s.q ~= "" then s.clearSearch() end
    s.hl = id
    s.layout()
    s.scrollToHl()
  end
  function s.scrollToHl()
    local r = s.hl and s.rows[s.hl]
    if not (r and r.rowY) then return end
    local function go()
      local range = scroll:GetVerticalScrollRange() or 0
      scroll:SetVerticalScroll(math.max(0, math.min(range, r.rowY - 40)))
    end
    go()
    if C_Timer then C_Timer.After(0, go) end
  end

  s.built = true
  T.OnFontScale(function() if s.built then s.layout() end end)
  panel:HookScript("OnShow", function() s.layout() end)
  -- messages that came while the tab was hidden: the log refills on the next show
  panel:HookScript("OnHide", function() s._logFilled = nil end)
  panel:HookScript("OnSizeChanged", function() if panel:IsShown() then s.layout() end end)
  -- keep the live texts current while the tab is on screen
  panel:SetScript("OnUpdate", function(self, el)
    self._acc = (self._acc or 0) + el
    if self._acc >= 1 then self._acc = 0; s.live() end
  end)
end

function M.RefreshSettings()
  local s = M.setUI
  if s and s.built then s.layout() end
end

-- Datalink.lua refreshes the DATALINK rows when the app or the queue changes
function M.RefreshDatalink()
  local s = M.setUI
  if s and s.built and s.panel:IsVisible() then s.live() end
end

-- Open the Settings tab: on one option (marked, scrolled to) or with a search
function M.OpenSettings(id, query)
  if M.EnsureUI then M.EnsureUI() end
  if not M.frame then return end
  M.frame:Show()
  if M.SelectTab and M.TAB then M.SelectTab(M.TAB.Settings) end
  local s = M.setUI
  if not (s and s.built) then return end
  if id and OPT[id] then
    s.jumpTo(id)
  elseif query and query ~= "" then
    s.q, s.hl = query, nil
    s.search.edit:SetText(query)
    s.search.edit:SetFocus()
    s.layout()
    if s.scroll then s.scroll:SetVerticalScroll(0) end
  end
end

-- "/midas set <word>" and "/midas settings [word]": the Settings tab, searched
do
  local prev = SlashCmdList and SlashCmdList["MIDAS"]
  if prev then
    SlashCmdList["MIDAS"] = function(msg)
      local raw = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
      local verb, rest = raw:match("^(%S+)%s*(.-)$")
      verb = verb and verb:lower()
      if verb == "set" or verb == "settings" or verb == "options" or verb == "config" then
        M.OpenSettings(nil, rest)
        return
      end
      return prev(msg)
    end
  end
end
