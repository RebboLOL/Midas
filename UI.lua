-- Midas – UI: window, tabs, Top Picks, opportunity ranking, watchlist, charts
local ADDON, M = ...
local T = M.Theme
local C = T.C
local TABS = { "Start", "Watchlist", "Net Worth", "Trades", "Ledger", "Charts", "Crafting", "Settings", "Help" }
local TAB = {}
for i, n in ipairs(TABS) do TAB[n] = i end
M.TAB = TAB
M.TABS = TABS
-- what the tab bar SHOWS; TABS stays the lookup key everywhere
local TAB_LABEL = { Ledger = "Ledger (beta)", Crafting = "Crafting (beta)" }

-- small helpers --------------------------------------------------------------
local function cell(parent, x, y, w, just, size, colorKey, variant)
  local fs = T.Text(parent, size or T.SIZE.body, colorKey, variant)
  fs:SetPoint("TOPLEFT", x, y); fs:SetWidth(w); fs:SetJustifyH(just or "LEFT")
  return fs
end

local function colorize(fs, rgb) fs:SetTextColor(rgb[1], rgb[2], rgb[3]) end

-- faint vertical separator (replaces hard internal borders)
-- Extra vertical room the content panel has gained over the 980x560 baseline
-- window (panel = 426px there). Tabs use it to grow their charts and show more
-- list rows when the window is resized taller, instead of leaving empty space.
local function extraH(panel)
  local h = panel and panel:GetHeight()
  return math.max(0, math.floor((h or 426) - 426))
end

-- How many rows of rowH fit into the panel below `used` px of fixed content.
-- Unlike baseline+extra math this also uses the base layout's built-in slack.
-- Falls back to the 426px baseline before the first layout pass.
local function availRows(panel, used, rowH, minRows)
  local h = panel and panel:GetHeight()
  if not h or h < 100 then h = 426 end
  local n = math.floor((h - used) / rowH)
  if n < minRows then n = minRows end
  return n
end

local function vline(parent, x)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.6)
  t:SetWidth(1); t:SetPoint("TOPLEFT", x, 0); t:SetPoint("BOTTOMLEFT", x, 0)
  return t
end

-- Show the real item tooltip just outside the window. Table rows and detail
-- cards already show the Midas numbers, so their tooltip stays plain; `full`
-- adds the Midas lines and the price chart (the start page's tiles and short
-- rows show no more than a percent). Tooltip.lua reads M.tipFull.
local function ShowItemTip(key, full)
  local id = M.BaseID and M.BaseID(key)
  if not id or not M.frame then GameTooltip:Hide(); return end
  GameTooltip:SetOwner(M.frame, "ANCHOR_NONE")
  M.tipFull = full and true or nil
  GameTooltip:ClearAllPoints()
  if (M.frame:GetRight() or 0) + 300 > GetScreenWidth() then
    GameTooltip:SetPoint("TOPRIGHT", M.frame, "TOPLEFT", -6, -2)
  else
    GameTooltip:SetPoint("TOPLEFT", M.frame, "TOPRIGHT", 6, -2)
  end
  GameTooltip:SetHyperlink("item:" .. id)
  GameTooltip:Show()
end
M.ShowItemTip = ShowItemTip
local function HideTip() M.tipFull = nil; GameTooltip:Hide() end
M.HideTip = HideTip

-- Right-click on an item row: the item menu with every page Midas has for it
-- (Nav.lua). Returns true when it handled the click.
local function ItemMenuClick(mouse, key)
  if mouse ~= "RightButton" or not key then return false end
  HideTip()
  if M.ItemMenu then M.ItemMenu(key) end
  return true
end

-- the one jump to another tab's page (Nav.lua M.Go leaves a Back pill)
local function GoChart(key)
  if not key then return end
  if M.Go then M.Go("chart", key) else M.SetChartKey(key); M.SelectTab(TAB.Charts) end
end

-- ===== Build ================================================================
function M.EnsureUI()
  if M.frame then return end
  local f = CreateFrame("Frame", "MidasFrame", UIParent, "BackdropTemplate")
  M.frame = f
  f:SetSize(980, 560); f:SetPoint("CENTER")
  f:SetBackdrop(T.FLAT)
  f:SetBackdropColor(C.bg0[1], C.bg0[2], C.bg0[3], 0.97)
  f:SetBackdropBorderColor(T.Unpack(C.borderlt))
  f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- remember where the window was dropped (top-left in UIParent space, like
    -- the resize grip); EnsureUI restores it, fresh installs keep CENTER
    if M.db and M.db.config and self:GetLeft() then
      M.db.config.uiX = math.floor(self:GetLeft() + 0.5)
      M.db.config.uiY = math.floor(self:GetTop() + 0.5)
    end
  end)
  f:SetClampedToScreen(true); f:SetFrameStrata("MEDIUM"); f:SetToplevel(true); f:Hide()
  tinsert(UISpecialFrames, "MidasFrame") -- ESC closes

  -- resize grip (bottom-right): drags WIDTH and HEIGHT independently (real
  -- resize, no scaling -- fonts stay their normal size). The top-left corner
  -- stays put; charts and panels are anchored elastically and use the room.
  -- Persisted (config.uiW/uiH, clamped 980x560 .. 1600x1000).
  if M.db and M.db.config then
    f:SetSize(math.max(980, math.min(1600, M.db.config.uiW or 980)),
              math.max(560, math.min(1000, M.db.config.uiH or 560)))
    -- restore the last dragged-to spot; SetClampedToScreen pulls a stale
    -- off-screen position (resolution change) back into view
    if M.db.config.uiX and M.db.config.uiY then
      f:ClearAllPoints()
      f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", M.db.config.uiX, M.db.config.uiY)
    end
  end
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -3, 3)
  grip:SetFrameLevel(f:GetFrameLevel() + 60)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function(self)
    local cx, cy = GetCursorPosition()
    local es = f:GetEffectiveScale()
    -- pin the top-left corner so the window grows right/down only
    local l, t = f:GetLeft(), f:GetTop()
    if l and t then
      f:ClearAllPoints()
      f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
    end
    f._resz = { w = f:GetWidth(), h = f:GetHeight(), cx = cx, cy = cy, es = es }
    self:SetScript("OnUpdate", function()
      local r = f._resz; if not r then return end
      local x, y = GetCursorPosition()
      local w = r.w + (x - r.cx) / r.es       -- width and height move independently
      local h = r.h - (y - r.cy) / r.es
      if w < 980 then w = 980 elseif w > 1600 then w = 1600 end
      if h < 560 then h = 560 elseif h > 1000 then h = 1000 end
      f:SetSize(w, h)
    end)
  end)
  grip:SetScript("OnMouseUp", function(self)
    self:SetScript("OnUpdate", nil)
    f._resz = nil
    if M.db and M.db.config then
      M.db.config.uiW = f:GetWidth()
      M.db.config.uiH = f:GetHeight()
      -- the grip re-anchored the frame to TOPLEFT: persist that spot too, so
      -- the next session restores exactly this placement
      if f:GetLeft() then
        M.db.config.uiX = math.floor(f:GetLeft() + 0.5)
        M.db.config.uiY = math.floor(f:GetTop() + 0.5)
      end
    end
    -- charts read their canvas size at render time: redraw everything once
    if M.RerenderCharts then M.RerenderCharts() end
    if M.RefreshUI then M.RefreshUI() end
  end)
  if T.HelpTip then
    T.HelpTip(grip, "Resize", {
      "Drag to resize the window - width and height move independently, the top-left corner stays put. Charts grow into the room; text keeps its normal size. The size is remembered." })
  end

  -- Header bar (borderless soft band; mouse passes through so it stays draggable)
  local header = T.Fill(f, "bg2")
  header:SetPoint("TOPLEFT", 1, -1); header:SetPoint("TOPRIGHT", -1, -1); header:SetHeight(46)
  local logo = header:CreateTexture(nil, "ARTWORK")
  logo:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
  logo:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  logo:SetSize(22, 22); logo:SetPoint("LEFT", 14, 0)
  local mark = T.Text(header, 22, "accent", T.FONT_SEMI)
  mark:SetPoint("LEFT", logo, "RIGHT", 9, 0); mark:SetText("Midas")
  local sub = T.Text(header, T.SIZE.small, "sub")
  sub:SetPoint("LEFT", mark, "RIGHT", 9, -1); sub:SetText("AH Market Analysis")
  M.headerStatus = T.Text(header, T.SIZE.small, "sub")
  M.headerStatus:SetPoint("RIGHT", -44, 0); M.headerStatus:SetJustifyH("RIGHT")
  -- Back pill: appears after a jump from one tab's item to another tab's page
  -- and returns to exactly where you came from (Nav.lua)
  if M.BuildNavPill then
    local pill = M.BuildNavPill(f, sub)
    pill:SetFrameLevel(f:GetFrameLevel() + 20)
  end
  -- a closed window starts fresh: no stale way back, no open item menu
  f:HookScript("OnHide", function()
    if M.NavClear then M.NavClear() end
    if M.HideItemMenu then M.HideItemMenu() end
  end)

  local close = T.Close(f)
  close:SetPoint("TOPRIGHT", -10, -12)
  close:SetScript("OnClick", function() f:Hide() end)

  -- Tabs + divider. Picking a tab yourself ends the jump trail (Back pill).
  local labels = {}
  for i, n in ipairs(TABS) do labels[i] = TAB_LABEL[n] or n end
  M.tabBar = T.TabBar(f, labels, function(i)
    if M.NavClear then M.NavClear() end
    M.SelectTab(i)
  end)
  M.tabBar.frame:SetPoint("TOPLEFT", 14, -52)

  -- floor-MA toggle (on/off), rightmost of the chart-toggle row. "Floor MA"
  -- because it averages the daily CHEAPEST buyouts (the floor) -- naming it plainly
  -- explains why Fair may sit above it when real sales prove a premium.
  M.chartMA = (M.db and M.db.config and M.db.config.chartMA) and true or false
  local maToggle = T.Checkbox(f, "Floor MA", function(on)
    M.chartMA = on
    if M.db and M.db.config then M.db.config.chartMA = on end
    M.RerenderCharts()
  end)
  maToggle:SetPoint("RIGHT", f, "TOPRIGHT", -14, -62)
  maToggle:SetChecked(M.chartMA)
  M.maToggle = maToggle
  if T.HelpTip then
    T.HelpTip(maToggle, T.HELP.ma[1], T.HELP.ma[2])
  end

  -- "My trades" toggle: show your own sells (green) / buys (red) as dots in the
  -- big chart, at their day and realized unit price. Default ON; persisted.
  M.chartTrades = not (M.db and M.db.config and M.db.config.chartTrades == false)
  local trToggle = T.Checkbox(f, "My trades", function(on)
    M.chartTrades = on
    if M.db and M.db.config then M.db.config.chartTrades = on end
    M.RerenderCharts()
  end)
  trToggle:SetPoint("RIGHT", maToggle, "LEFT", -14, 0)
  trToggle:SetChecked(M.chartTrades)
  M.trToggle = trToggle
  if T.HelpTip then
    T.HelpTip(trToggle, "My trades", {
      "Shows your own trades in the charts: green dots = buys, red dots = sells, at their day and realized unit price (market chart) or on your holding's value line (Net Worth item view).",
      "Hover a traded day for the total quantity and volume-weighted average price. Vendor buys are included." })
  end

  -- "Fair" toggle: show/hide the purple Fair line (and its hover read-outs/label)
  M.chartFair = not (M.db and M.db.config and M.db.config.chartFair == false)
  local fairToggle = T.Checkbox(f, "Fair", function(on)
    M.chartFair = on
    if M.db and M.db.config then M.db.config.chartFair = on end
    M.RerenderCharts()
  end)
  fairToggle:SetPoint("RIGHT", trToggle, "LEFT", -14, 0)
  fairToggle:SetChecked(M.chartFair)
  M.fairToggle = fairToggle
  if T.HelpTip then
    T.HelpTip(fairToggle, "Fair line", T.HELP.fair[2])
  end
  -- nine tabs share the row with the three toggles: at the minimum window width
  -- the tab padding shrinks until the bar ends before the first toggle
  if M.tabBar.Fit then
    local togW = maToggle:GetWidth() + trToggle:GetWidth() + fairToggle:GetWidth() + 28
    M.tabBar:Fit(980 - 28 - togW - 16)
  end

  local div = T.Divider(f)
  div:SetPoint("TOPLEFT", 12, -82); div:SetPoint("TOPRIGHT", -12, -82)

  -- Content panels
  M.panels = {}
  for i = 1, #TABS do
    local p = CreateFrame("Frame", nil, f)
    p:SetPoint("TOPLEFT", 14, -92)
    p:SetPoint("BOTTOMRIGHT", -14, 42)
    p:Hide()
    M.panels[i] = p
  end

  -- Footer
  local fdiv = T.Divider(f)
  fdiv:SetPoint("BOTTOMLEFT", 12, 36); fdiv:SetPoint("BOTTOMRIGHT", -12, 36)
  M.footer = T.Text(f, T.SIZE.small, "muted")
  M.footer:SetPoint("BOTTOMLEFT", 16, 14)
  local scanBtn = T.Button(f, "Scan AH", 110, 22)
  scanBtn:SetPoint("BOTTOMRIGHT", -14, 10)
  scanBtn:SetScript("OnClick", function() M.Scan(true); M.RefreshUI() end)
  if T.HelpTip then
    T.HelpTip(scanBtn, "Scan AH", {
      "Runs a full auction-house scan and stores today's lowest buyout and quantity per item in your permanent archive.",
      "Works only while the auction house is open; full (GetAll) scans are rate-limited by the server to roughly one per 15 minutes." })
  end
  -- quiet community link left of the scan button: muted, accent on hover,
  -- click opens the copy box; the tab hint stops short of it
  local dc = T.Text(f, T.SIZE.tiny, "muted", T.FONT_MED)
  dc:SetPoint("RIGHT", scanBtn, "LEFT", -14, 0)
  dc:SetText("Discord \194\183 " .. M.DISCORD_URL:gsub("^https://", ""))
  local dcBtn = CreateFrame("Button", nil, f)
  dcBtn:SetAllPoints(dc)
  dcBtn:SetScript("OnClick", function() M.ShowLinkCopy(M.DISCORD_URL, "Midas Discord") end)
  dcBtn:SetScript("OnEnter", function() dc:SetTextColor(C.accent[1], C.accent[2], C.accent[3]) end)
  dcBtn:SetScript("OnLeave", function() dc:SetTextColor(C.muted[1], C.muted[2], C.muted[3]) end)
  -- running version, far left before the status text - fed by M.version, so
  -- the release bump keeps it true without touching this line
  local ver = T.Text(f, T.SIZE.tiny, "muted", T.FONT_MED)
  ver:SetPoint("LEFT", f, "BOTTOMLEFT", 16, 21)
  ver:SetText("v" .. (M.version or ""))
  M.footer:ClearAllPoints()
  M.footer:SetPoint("LEFT", ver, "RIGHT", 10, 0)   -- same centre line as the scan button
  M.footer:SetPoint("RIGHT", dc, "LEFT", -16, 0)
  M.footer:SetJustifyH("LEFT")

  M.BuildHome(M.panels[TAB.Start])
  M.BuildWatch(M.panels[TAB.Watchlist])
  M.BuildWealth(M.panels[TAB["Net Worth"]])
  M.BuildTrades(M.panels[TAB.Trades])
  M.BuildLedger(M.panels[TAB.Ledger])
  M.BuildCharts(M.panels[TAB.Charts])
  if M.BuildCrafting then M.BuildCrafting(M.panels[TAB.Crafting]) end
  M.BuildSettings(M.panels[TAB.Settings])
  M.BuildHelp(M.panels[TAB.Help])
  -- start on tab 1 WITHOUT filling it: the window is still hidden here and
  -- every caller shows it and fills it right after (Toggle, SelectTab, Go).
  -- Filling the hidden window doubled the work of the first open.
  M.curTab = 1
  for j, p in ipairs(M.panels) do p:SetShown(j == 1) end
  M.tabBar:Select(1)
  M.UpdateChartToggles()
end

function M.SelectTab(i)
  M.curTab = i
  -- every tab opens in its base view: drop transient drill-down state so a
  -- "< back" chain never survives a tab switch invisibly
  if M.NWNavReset then M.NWNavReset() end
  if M.whyView then M.whyView:Hide() end
  if M.depthView then M.depthView:Hide() end
  if M.alertsView then M.alertsView:Hide() end
  if M.ledgerUI and M.ledgerUI.pop then M.ledgerUI.pop:Hide() end
  if M.HideCraftPopups then M.HideCraftPopups() end
  if M.HideItemMenu then M.HideItemMenu() end
  for j, p in ipairs(M.panels) do p:SetShown(j == i) end
  if M.tabBar then M.tabBar:Select(i) end
  M.RefreshUI()
end

-- The three chart-overlay toggles (Fair / My trades / Floor MA) live in the
-- window header but only where a chart actually reads them: item charts
-- (Watchlist previews, Trades By-Item preview, Charts tab) and the Net-Worth
-- HOLDING drill-down -- the account/class/character worth charts ignore them.
function M.UpdateChartToggles()
  local t = M.curTab
  local holding = M.wealth and M.wealth.itemWorth and M.wealth.itemWorth:IsShown()
  local showCtl = (t == TAB.Watchlist) or (t == TAB.Charts)
    or (t == TAB.Trades and M.tradeView ~= "log")
    or (t == TAB["Net Worth"] and holding == true)
  if M.maToggle then M.maToggle:SetShown(showCtl) end
  if M.trToggle then M.trToggle:SetShown(showCtl) end
  if M.fairToggle then M.fairToggle:SetShown(showCtl) end
end

function M.RefreshUI()
  if not M.frame then return end
  local realm = M.RealmKey()
  local last = M.LastScanDay(realm)
  local lastTxt = (last >= 0) and M.DayLabel(last) or "-"
  if M.headerStatus then
    local shared = ""
    if M.commStats and (M.commStats.rxRows or 0) > 0 then
      shared = "   \194\183   shared +" .. M.commStats.rxRows
    end
    M.headerStatus:SetText(realm .. "   \194\183   last scan " .. lastTxt .. shared)
  end
  local t = M.curTab
  if M.UpdateChartToggles then M.UpdateChartToggles() end
  local hint = "/midas scan to update   \194\183   /midas help lists every command"
  if t == TAB.Start and M.db and M.db.config and M.db.config.homeView == "classic" then
    hint = "click a card for its tab   \194\183   right-click an item to watch it   \194\183   alt: post stats to chat"
  elseif t == TAB.Start then
    hint = "click an item for its chart   \194\183   right-click: watch / unwatch   \194\183   hover a card title for how it is computed"
  elseif t == TAB.Watchlist then
    hint = "\"+ group\" creates a section   \194\183   drag a row onto a group   \194\183   right-click removes   \194\183   header: right-click renames, shift-click deletes"
  elseif t == TAB["Net Worth"] then
    hint = "account-wide assets (gold + item value)   \194\183   click a chart day or a character for details   \194\183   right-click an item: all its pages"
  elseif t == TAB.Trades then
    hint = "open your mailbox to log trades   \194\183   By Item: click a row for each sale's price   \194\183   right-click an item: all its pages"
  elseif t == TAB.Ledger then
    hint = "beta: every gold and item flow   \194\183   hover a band for details   \194\183   click lists its items   \194\183   right-click an item: all its pages"
  elseif t == TAB.Charts then
    hint = "chips next to the name: the item's other pages   \194\183   right-click any item: all its pages   \194\183   shift: AH search   \194\183   alt: chat"
  elseif t == TAB.Crafting then
    if M.CraftingOn and not M.CraftingOn() then
      hint = "beta: crafting is switched off   \194\183   tick \"Enable crafting\" above to turn it on"
    else
      hint = "beta   \194\183   click a card to open it   \194\183   + shows how a material is made   \194\183   right-click: all its pages   \194\183   bottom bar: sideways"
    end
  elseif t == TAB.Settings then
    hint = "general options + community sync   \194\183   sync is invisible to other players"
  elseif t == TAB.Help then
    hint = "how Midas prices things   \194\183   hover any column header in the other tabs for per-metric help"
  end
  M.footer:SetText(hint)
  if t == TAB.Start and M.RefreshHome then M.RefreshHome()
  elseif t == TAB.Watchlist and M.RefreshWatch then M.RefreshWatch()
  elseif t == TAB["Net Worth"] and M.RefreshWealth then M.RefreshWealth()
  elseif t == TAB.Trades and M.RefreshTrades then M.RefreshTrades()
  elseif t == TAB.Ledger and M.RefreshLedger then M.RefreshLedger()
  elseif t == TAB.Crafting and M.RefreshCrafting then M.RefreshCrafting()
  elseif t == TAB.Settings and M.RefreshSettings then M.RefreshSettings()
  elseif t == TAB.Help and M.RefreshHelp then M.RefreshHelp()
  elseif t == TAB.Charts and M.RefreshCharts then M.RefreshCharts() end
  -- floating drill-downs re-read their numbers too: the tab refreshers above
  -- only cover the base views (RefreshCharts already re-targets an open
  -- offer book), everything below keeps its own context and just re-fills
  if M.whyView and M.whyView:IsShown() and M.FillWhy then M.FillWhy() end
  local w = M.wealth
  if w then
    if w.itemView and w.itemView:IsShown() and M.FillCharItems then M.FillCharItems() end
    if w.dayView and w.dayView:IsShown() and M.FillWorthDay then M.FillWorthDay() end
    if w.classView and w.classView:IsShown() and M.FillWorthClass then M.FillWorthClass() end
    if w.itemWorth and w.itemWorth:IsShown() and M.FillItemWorth then M.FillItemWorth() end
    if w.moversView and w.moversView:IsShown() and M.FillMovers then M.FillMovers() end
  end
end

-- Coalesced refresh for background data writers (auction / mail / bank
-- caches): several updates inside half a second end in ONE visible refresh,
-- and nothing runs while the window is closed. The scan commit keeps its
-- direct RefreshUI call (one event, immediate feedback).
function M.RequestUIRefresh()
  if not (M.frame and M.frame:IsShown()) or M._uiRefreshPending then return end
  M._uiRefreshPending = true
  C_Timer.After(0.5, function()
    M._uiRefreshPending = nil
    if M.frame and M.frame:IsShown() and M.RefreshUI then M.RefreshUI() end
  end)
end

-- Re-draw every chart currently on screen (used when the view mode changes).
function M.RerenderCharts()
  if M.detailCards then
    for _, card in ipairs(M.detailCards) do
      if card.shownKey and M.RenderItemChart then M.RenderItemChart(card.canvas, card.shownKey) end
    end
  end
  if M.canvas and M.chartKey and M.RenderItemChart then M.RenderItemChart(M.canvas, M.chartKey) end
  if M.whyView and M.whyView:IsShown() and M.FillWhy then M.FillWhy() end
  if M.depthView and M.depthView:IsShown() and M.FillDepth then M.FillDepth() end
  -- open Net-Worth views carry charts too (holding view reacts to the toggles)
  local w = M.wealth
  if w then
    if w.chart and M.RenderNetWorthChart and M.frame and M.frame:IsShown() then M.RenderNetWorthChart(w.chart) end
    if w.itemView and w.itemView:IsShown() and M.FillCharItems then M.FillCharItems() end
    if w.classView and w.classView:IsShown() and M.FillWorthClass then M.FillWorthClass() end
    if w.itemWorth and w.itemWorth:IsShown() and M.FillItemWorth then M.FillItemWorth() end
  end
end

function M.Toggle()
  if M.frame and M.frame:IsShown() then M.frame:Hide(); return end
  local first = not M.frame
  M.EnsureUI()
  M.frame:Show()
  if first then
    -- the first open has just built all nine tabs: the window shows now and
    -- its content fills one frame later, as a script run of its own. Build
    -- and fill in ONE run could hit the client's script time limit, which
    -- aborts silently - the window then stayed shut until the second click.
    C_Timer.After(0, function()
      if M.frame:IsShown() then M.RefreshUI() end
    end)
  else
    M.RefreshUI()
  end
end

-- ===== Chart timeframe (1W / 1M / 3M / All) =================================
-- ONE global range for every big chart (config.chartRange, read by Charts.lua);
-- the segments on the Charts tab, the Net Worth tab and in Settings mirror it.
M.rangeSegs = {}
function M.SetChartRange(key)
  if M.db and M.db.config then M.db.config.chartRange = key end
  for _, seg in ipairs(M.rangeSegs) do seg:Select(key) end
  -- picking a range leaves a picked-day movers view: back to the timeframe
  if M.wealth and M.wealth.moversView then M.wealth.moversView.refDayOverride = nil end
  M.RerenderCharts()
  -- the Net-Worth hero decomposition, movers and class deltas read the same
  -- window: refresh the active tab's texts too
  if M.RefreshUI then M.RefreshUI() end
end

local function makeRangeSeg(parent)
  local seg = T.Segment(parent, {
    { key = "7",   label = "1W" },
    { key = "30",  label = "1M" },
    { key = "90",  label = "3M" },
    { key = "all", label = "All" },
  }, M.SetChartRange)
  seg:Select((M.db and M.db.config and M.db.config.chartRange) or "all")
  M.rangeSegs[#M.rangeSegs + 1] = seg
  if T.HelpTip then
    T.HelpTip(seg.frame, "Chart timeframe", {
      "How far back the big charts look: the last week, month, three months, or everything recorded. One setting for all big charts; the small preview cards have their own timeframe in Settings." })
  end
  return seg
end

-- Select a chart + remember it in the "recently viewed" list (cap 10, newest first)
function M.SetChartKey(key)
  key = key and tostring(key)   -- callers may pass a numeric itemID (AH book title)
  M.chartKey = key
  if not key or not (M.db and M.db.config) then return end
  local r = M.db.config.recentCharts or {}
  for i = #r, 1, -1 do
    r[i] = tostring(r[i])       -- heal numeric entries a pre-fix click wrote
    if r[i] == key then table.remove(r, i) end
  end
  table.insert(r, 1, key)
  while #r > 30 do table.remove(r) end
  M.db.config.recentCharts = r
  M.chartListOff = 0            -- a new pick starts the left list at the top
end

-- Open the window on the Charts tab showing a given item (from the AH, the
-- offer book dock, ...): through M.Go, so an open window keeps its way back
function M.ShowChartFor(key)
  if M.Go then M.Go("chart", key); return end
  M.EnsureUI(); M.frame:Show()
  M.SetChartKey(key)
  M.SelectTab(TAB.Charts)
  M.RefreshUI()
end

-- ===== Configurable click shortcuts =========================================
-- Two item shortcuts run through here: "post" (default ALT = post the price
-- card to chat) and "search" (default SHIFT = AH search / open the chart).
-- Each can be moved to ALT/CTRL/SHIFT or OFF via /midas keys; the Settings
-- checkbox (config.modClicks == false) is a master off switch for both.
-- ModKey returns the RAW configured key so /midas keys can still report the
-- binding while the master toggle is off; pass true for the effective key.
function M.ModKey(which, effective)
  local cfg = (M.db and M.db.config) or {}
  if effective and cfg.modClicks == false then return "OFF" end
  local v = (which == "post") and cfg.modPost or cfg.modSearch
  if v ~= "ALT" and v ~= "CTRL" and v ~= "SHIFT" and v ~= "OFF" then
    v = (which == "post") and "ALT" or "SHIFT"
  end
  return v
end

local MOD_CHECK = { ALT = IsAltKeyDown, CTRL = IsControlKeyDown, SHIFT = IsShiftKeyDown }

function M.ModPostDown()
  local f = MOD_CHECK[M.ModKey("post", true)]
  return (f and f()) or false
end

function M.ModSearchDown()
  local f = MOD_CHECK[M.ModKey("search", true)]
  return (f and f()) or false
end

-- /midas keys post|search alt|ctrl|shift|off. If the new key collides with the
-- other shortcut, that one moves to the freed key - two shortcuts can never sit
-- on the same modifier, so a click stays unambiguous.
function M.SetModKey(which, key)
  which = tostring(which or ""):lower()
  key = tostring(key or ""):upper()
  local okWhich = (which == "post" or which == "search")
  local okKey = (key == "ALT" or key == "CTRL" or key == "SHIFT" or key == "OFF")
  if not (okWhich and okKey) then
    M.Print("usage: /midas keys post|search alt|ctrl|shift|off")
    return
  end
  local cfg = M.db.config
  local other = (which == "post") and "search" or "post"
  local oldMine, otherKey = M.ModKey(which), M.ModKey(other)
  cfg[(which == "post") and "modPost" or "modSearch"] = key
  local moved
  if key ~= "OFF" and key == otherKey then
    moved = (oldMine ~= "OFF") and oldMine or ((key == "ALT") and "SHIFT" or "ALT")
    cfg[(other == "post") and "modPost" or "modSearch"] = moved
  end
  -- binding a real key is the clearest "I want this working" there is: lift
  -- the master off switch too, so the fresh key never sits dead behind it
  local reOn
  if key ~= "OFF" and cfg.modClicks == false then
    cfg.modClicks = nil
    reOn = true
    if M.RefreshSettings then M.RefreshSettings() end
  end
  M.Print("click shortcut: " .. ((which == "post") and "post to chat" or "AH search/chart")
    .. " = " .. key .. (moved and ("   (the other shortcut moved to " .. moved .. ")") or "")
    .. (reOn and "   (shortcuts were OFF in Settings - switched back on)" or "")
    .. (cfg.modClicks == false and '   (master toggle is OFF in Settings)' or ""))
end

-- Search-click an item in Midas (default SHIFT): at the auction house, type it
-- into the search box and search; otherwise drop its link into an open chat
-- edit box (standard).
function M.ItemShiftAction(key)
  local id = (M.BaseID and M.BaseID(key)) or tonumber(tostring(key):match("(%d+)"))
  if not id then return end
  local name, link = M.GetItemInfo(id)
  if M.AHOpen and name then
    -- Auctionator present: search it in Auctionator's Shopping tab (its API switches
    -- to that tab and runs an exact search) -- matches where the user is working.
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if api and api.MultiSearchExact then
      if pcall(api.MultiSearchExact, "Midas", { name }) then return end
    end
    -- Fallback (no Auctionator), modern client: the AuctionHouseFrame search bar
    local ahf = _G.AuctionHouseFrame
    local bar = ahf and ahf.SearchBar
    if bar and bar.SetSearchText and bar.StartSearch then
      if ahf.SetDisplayMode and _G.AuctionHouseFrameDisplayMode then
        pcall(ahf.SetDisplayMode, ahf, _G.AuctionHouseFrameDisplayMode.Buy)
      end
      if pcall(bar.SetSearchText, bar, name) and pcall(bar.StartSearch, bar) then return end
    end
    -- Fallback (no Auctionator), classic client: the default Browse tab search box
    local box = _G.BrowseName
    if box then
      box:SetText(name)
      if _G.BrowseSearchButton then _G.BrowseSearchButton:Click()
      elseif _G.AuctionFrameBrowse_Search then _G.AuctionFrameBrowse_Search() end
      return
    end
  end
  if link and HandleModifiedItemClick then HandleModifiedItemClick(link) end
end

-- Alt-click anywhere: post the item's price card into chat -- the one-click
-- answer to a guildmate's "price check?". One plain-text line (outgoing chat
-- rejects color escapes; item links are fine), sent to the channel of the
-- player's last-used chat input, capped at the 255-byte chat limit.
function M.PostItemStats(key)
  local id = (M.BaseID and M.BaseID(key)) or tonumber(tostring(key):match("(%d+)"))
  if not id then return end
  local series = M.GetSeries and M.GetSeries(tostring(id))
  local m = series and M.Metrics(series, tostring(id))
  local name, link = M.GetItemInfo(id)
  local shown = link or name or ("item " .. id)
  if not (m and m.fair and m.fair > 0) then
    M.Print("no price data for " .. shown .. " yet - scan the AH first.")
    return
  end
  local parts = {
    "now " .. M.MoneyPlain(m.cur),
    string.format("fair %s (%+.0f%%)", M.MoneyPlain(m.fair), (m.delta or 0) * 100),
  }
  if m.floor7 then parts[#parts + 1] = "floor " .. M.MoneyPlain(m.floor7) end
  -- the low covers Metrics' 60-day stats window; its day says how recent it is
  if m.min then
    parts[#parts + 1] = "60d low " .. M.MoneyPlain(m.min)
      .. (m.minDay and (" (" .. M.DayLabel(m.minDay) .. ")") or "")
  end
  local function build()
    return shown .. ":  " .. table.concat(parts, " \194\183 ") .. "  - by Midas Addon"
  end
  local msg = build()
  while #msg > 255 and #parts > 2 do   -- keep at least now + fair, never the tag
    table.remove(parts)
    msg = build()
  end
  if #msg > 255 and name then shown = name; msg = build() end   -- oversized link
  if #msg > 255 then return end
  local eb = (ChatEdit_ChooseBoxForSend and ChatEdit_ChooseBoxForSend())
    or (DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox)
  local ctype = (eb and eb.GetAttribute and eb:GetAttribute("chatType")) or "SAY"
  if ctype == "BN_WHISPER" then
    M.Print("Battle.net whispers can't carry item links - open a normal chat channel first.")
    return
  end
  if ctype == "WHISPER" then
    local to = eb and eb:GetAttribute("tellTarget")
    if to and to ~= "" then SendChatMessage(msg, "WHISPER", nil, to)
    else SendChatMessage(msg, "SAY") end
  elseif ctype == "CHANNEL" then
    local num = eb and eb:GetAttribute("channelTarget")
    num = num and GetChannelName(num) or 0
    if num and num > 0 then SendChatMessage(msg, "CHANNEL", nil, num)
    else SendChatMessage(msg, "SAY") end
  else
    SendChatMessage(msg, ctype)
  end
end

-- Reverse direction: shift-click an item AT the auction house -> show it in Midas.
-- We hook the standard link paths (HandleModifiedItemClick + the chat link-insert
-- functions), which is what the default AH *and* addons like Auctionator route
-- shift-clicks through (Auctionator itself hooks these same functions). Gated on:
-- AH open, no chat message being composed (so linking an item into chat isn't
-- hijacked), we have data for it, and a small de-dup so one click that trips
-- several hooks only opens once. Covers Auctionator's Selling/Shopping/Cancelling.
if not M._shiftHooks then
  M._shiftHooks = true
  local function shiftToMidas(link)
    if not link then return end
    -- the client only routes SHIFT-clicks through these link paths, so this
    -- reverse hook exists for the default binding only: it sleeps when the
    -- search shortcut is off or moved to another key
    if M.ModKey("search", true) ~= "SHIFT" then return end
    if not (IsShiftKeyDown() and M.AHOpen) then return end
    if ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then return end
    local id = tonumber(tostring(link):match("item:(%d+)"))
    if not (id and M.GetSeries and M.GetSeries(tostring(id))) then return end
    local now = GetTime()
    if M._shiftId == id and now - (M._shiftAt or 0) < 0.5 then return end
    M._shiftId, M._shiftAt = id, now
    M.ShowChartFor(tostring(id))
  end
  if type(HandleModifiedItemClick) == "function" then hooksecurefunc("HandleModifiedItemClick", shiftToMidas) end
  if type(ChatEdit_InsertLink) == "function" then hooksecurefunc("ChatEdit_InsertLink", shiftToMidas) end
  if ChatFrameUtil and type(ChatFrameUtil.InsertLink) == "function" then hooksecurefunc(ChatFrameUtil, "InsertLink", shiftToMidas) end
end

-- Alt-click an item link anywhere the client routes it as a modified click
-- (a chat link via SetItemRef, a bag item, the AH): post its price card.
-- Shift keeps all its meanings (insert link / Midas chart); modifier combos
-- are left alone. Same 0.5s de-dup pattern as the shift hook above.
if not M._altHooks then
  M._altHooks = true
  local function altToChat(link)
    if not link then return end
    -- same story as the shift hook: HandleModifiedItemClick is an ALT-click
    -- path, so this sleeps when the post shortcut is off or moved
    if M.ModKey("post", true) ~= "ALT" then return end
    if not IsAltKeyDown() then return end
    if IsShiftKeyDown() or IsControlKeyDown() then return end
    local id = tonumber(tostring(link):match("item:(%d+)"))
    if not id then return end
    local now = GetTime()
    if M._altId == id and now - (M._altAt or 0) < 0.5 then return end
    M._altId, M._altAt = id, now
    if M.PostItemStats then M.PostItemStats(tostring(id)) end
  end
  if type(HandleModifiedItemClick) == "function" then hooksecurefunc("HandleModifiedItemClick", altToChat) end
end

-- ===== "Midas Scan" button + progress bar on the Auction House frame ========
function M.EnsureScanUI()
  if M.scanUI then return M.scanUI end
  local AH = _G.AuctionFrame or _G.AuctionHouseFrame   -- classic / modern client
  if not AH then return nil end
  local f = CreateFrame("Frame", nil, AH)
  f:SetSize(140, 40)
  f:SetPoint("BOTTOMRIGHT", AH, "TOPRIGHT", -12, 2)
  f:SetFrameLevel(AH:GetFrameLevel() + 10)

  local btn = T.Button(f, "Midas Scan", 140, 22)
  btn:SetPoint("BOTTOMRIGHT", 0, 0)
  btn:SetScript("OnClick", function() M.Scan(true) end)

  -- coin button left of Scan: opens the market window right from the AH
  -- (CF request spudster90 - discoverable without the minimap or /midas)
  local open = CreateFrame("Button", nil, f, "BackdropTemplate")
  open:SetSize(22, 22)
  open:SetPoint("BOTTOMRIGHT", btn, "BOTTOMLEFT", -4, 0)
  open:SetBackdrop(T.FLAT)
  open:SetBackdropColor(C.bg1[1], C.bg1[2], C.bg1[3], 0.97)
  open:SetBackdropBorderColor(T.Unpack(C.border))
  local coin = open:CreateTexture(nil, "ARTWORK")
  coin:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
  coin:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  coin:SetPoint("TOPLEFT", 3, -3); coin:SetPoint("BOTTOMRIGHT", -3, 3)
  open:SetScript("OnClick", function() if M.Toggle then M.Toggle() end end)
  open:SetScript("OnEnter", function(self)
    self:SetBackdropBorderColor(T.Unpack(C.accent))
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Midas", 1, 1, 1)
    GameTooltip:AddLine("Open the market window", 0.82, 0.85, 0.92)
    GameTooltip:Show()
  end)
  open:SetScript("OnLeave", function(self)
    self:SetBackdropBorderColor(T.Unpack(C.border))
    GameTooltip:Hide()
  end)

  local bar = T.Surface(f, "bg0", "border")
  bar:SetSize(140, 12); bar:SetPoint("BOTTOMRIGHT", btn, "TOPRIGHT", 0, 5)
  bar:SetFrameLevel(f:GetFrameLevel() + 1)
  local fill = bar:CreateTexture(nil, "ARTWORK")
  fill:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.95)
  fill:SetPoint("TOPLEFT", 1, -1); fill:SetPoint("BOTTOMLEFT", 1, 1); fill:SetWidth(1)
  local txt = T.Text(bar, T.SIZE.tiny, "text", T.FONT_MED)
  txt:SetPoint("CENTER", 0, 0); txt:SetText("")
  bar:Hide()

  M.scanUI = { btn = btn, bar = bar, fill = fill, txt = txt, frame = f, barW = 138 }
  return M.scanUI
end

function M.ShowScanButton()
  local w = M.EnsureScanUI()
  if not w then
    -- modern client: the AH UI is load-on-demand and may appear a moment later
    if not M._scanBtnRetry then
      M._scanBtnRetry = true
      C_Timer.After(0.5, function() M._scanBtnRetry = nil; if M.AHOpen and M.EnsureScanUI() then M.ShowScanButton() end end)
    end
    return
  end
  w.frame:Show()
  M.ScanUIState(M.scanning == true)
  -- opt-in (Settings "Open with the auction house"): bring the market window
  -- up together with the AH; closing is left to the user. Same path as a
  -- click (M.Toggle): the first open shows the window now and fills it one
  -- frame later, as a script run of its own.
  if M.db and M.db.config and M.db.config.openWithAH
     and not (M.frame and M.frame:IsShown()) then
    M.Toggle()
  end
end

function M.HideScanButton()
  if M.scanUI then M.scanUI.frame:Hide() end
end

-- Toggle the scan widget between idle and scanning (shows/hides the bar).
function M.ScanUIState(scanning)
  local w = M.scanUI; if not w then return end
  if scanning then
    w.btn.text:SetText("Scanning\226\128\166")
    w.bar:Show()
  else
    w.btn.text:SetText("Midas Scan")
    w.bar:Hide()
  end
end

-- Update the progress bar (frac 0..1) with an optional label.
function M.SetScanProgress(frac, label)
  local w = M.scanUI; if not w then return end
  frac = math.max(0, math.min(1, frac or 0))
  w.fill:SetWidth(math.max(1, w.barW * frac))
  w.txt:SetText(label or string.format("%d%%", math.floor(frac * 100)))
end

-- ===== Offer book docked to the auction house ===============================
-- Dropping an item into the sell slot or picking a browse result docks that
-- item's supply ladder (from the newest full scan) to the right edge of the
-- AH window. Settings > "Offer book at the auction house" turns it off
-- (config.ahBook == false; unset = on).
local ahb                 -- the docked panel, built lazily
-- row pool = DEPTH_LEVELS (Data.lua): the snapshot never stores more price
-- levels, and the fill clamps to the panel height anyway (~18 rows fit)
local AHB_ROWS = 20

-- one-time note when a dock's X is clicked (both AH docks share it)
local function dockHint()
  if M.db and M.db.config and M.db.config.dockCloseHint ~= 1 then
    M.db.config.dockCloseHint = 1
    M.Print("Dock hidden until your next auction house visit. The Settings checkboxes (\"Offer book at the auction house\", \"Sell helper at the AH\") turn them off for good.")
  end
end

local function ahBookPanel()
  if ahb then return ahb end
  local AH = _G.AuctionFrame or _G.AuctionHouseFrame   -- classic / modern client
  if not AH then return nil end
  ahb = CreateFrame("Frame", "MidasAHBook", AH, "BackdropTemplate")
  ahb:SetBackdrop(T.FLAT)
  ahb:SetBackdropColor(C.bg0[1], C.bg0[2], C.bg0[3], 0.97)
  ahb:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1)
  ahb:SetWidth(320)
  ahb:SetPoint("TOPLEFT", AH, "TOPRIGHT", -2, -12)
  ahb:SetPoint("BOTTOMLEFT", AH, "BOTTOMRIGHT", -2, 12)
  ahb:SetFrameLevel(AH:GetFrameLevel() + 10)
  ahb.icon = ahb:CreateTexture(nil, "ARTWORK")
  ahb.icon:SetSize(20, 20); ahb.icon:SetPoint("TOPLEFT", 10, -10)
  ahb.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  ahb.title = T.Text(ahb, T.SIZE.body, "text", T.FONT_SEMI)
  ahb.title:SetPoint("TOPLEFT", 36, -11)
  ahb.sub = T.Text(ahb, T.SIZE.tiny, "muted")
  ahb.sub:SetPoint("TOPLEFT", 36, -27)
  ahb.head = T.Text(ahb, T.SIZE.tiny, "muted", T.FONT_MED)
  ahb.head:SetPoint("TOPLEFT", 10, -46)
  ahb.head:SetText("OFFER BOOK  \194\183  title: chart  \194\183  right-click: all pages")
  -- small X: hides the dock for this AH visit (Settings turns it off for good)
  if T.Close then
    local xb = T.Close(ahb)
    xb:SetPoint("TOPRIGHT", -4, -4)
    xb:SetFrameLevel(ahb:GetFrameLevel() + 5)
    xb:SetScript("OnClick", function()
      ahb._dismissed = true
      ahb:Hide()
      dockHint()
    end)
  end
  local hb = CreateFrame("Button", nil, ahb)   -- title block opens the Midas chart
  hb:SetPoint("TOPLEFT", 6, -6); hb:SetPoint("TOPRIGHT", -26, -6); hb:SetHeight(36)
  hb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  hb:SetScript("OnClick", function(_, mouse)
    if not ahb._id then return end
    if ItemMenuClick(mouse, tostring(ahb._id)) then return end
    if M.ShowChartFor then M.ShowChartFor(ahb._id) end
  end)
  hb:SetScript("OnEnter", function() if ahb._id and M.ShowItemTip then M.ShowItemTip(tostring(ahb._id)) end end)
  hb:SetScript("OnLeave", function() if M.HideTip then M.HideTip() end end)
  ahb.rows = {}
  for r = 1, AHB_ROWS do
    local row = CreateFrame("Frame", nil, ahb)
    row:SetPoint("TOPLEFT", 10, -60 - (r - 1) * 18)
    row:SetPoint("TOPRIGHT", -10, -60 - (r - 1) * 18)
    row:SetHeight(18)
    row.price = T.Text(row, T.SIZE.small, "text", T.FONT_MED)
    row.price:SetPoint("LEFT", 0, 0); row.price:SetWidth(64); row.price:SetJustifyH("RIGHT")
    row.ghost = row:CreateTexture(nil, "BORDER")
    row.ghost:SetColorTexture(C.sub[1], C.sub[2], C.sub[3], 0.14)
    row.bar = row:CreateTexture(nil, "ARTWORK")
    row.own = row:CreateTexture(nil, "ARTWORK")
    row.qty = T.Text(row, T.SIZE.small, "text", T.FONT_MED)
    row.cum = T.Text(row, T.SIZE.small, "sub")
    row.cum:SetPoint("RIGHT", 0, 0); row.cum:SetWidth(40); row.cum:SetJustifyH("RIGHT")
    ahb.rows[r] = row
  end
  local pu = C.purple or C.accent
  ahb.fairLine = ahb:CreateTexture(nil, "OVERLAY")
  ahb.fairLine:SetColorTexture(pu[1], pu[2], pu[3], 0.9)
  ahb.fairLine:SetHeight(1)
  ahb.foot1 = T.Text(ahb, T.SIZE.tiny, "sub");   ahb.foot1:SetPoint("BOTTOMLEFT", 10, 24)
  ahb.foot2 = T.Text(ahb, T.SIZE.tiny, "muted"); ahb.foot2:SetPoint("BOTTOMLEFT", 10, 10)
  ahb.note = T.Text(ahb, T.SIZE.small, "sub")
  ahb.note:SetPoint("TOPLEFT", 10, -64); ahb.note:SetPoint("TOPRIGHT", -10, -64)
  ahb.note:SetJustifyH("LEFT"); ahb.note:SetWordWrap(true)
  ahb:Hide()
  return ahb
end

-- The scanned level an own ask belongs to. Own unit prices are rounded
-- (Inventory.lua), the scan's are floored, so one auction can read 1c apart.
local function scanLevelAt(byPrice, p)
  return byPrice[p] or byPrice[p - 1]
end

local function ahBookFill(id)
  local f = ahb
  local key = tostring(id)
  local qc = M.ItemQualityColor(key)
  f.title:SetText(M.ItemName(key)); f.title:SetTextColor(qc.r, qc.g, qc.b)
  local icon = M.GetItemIcon and M.GetItemIcon(id)
  f.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
  for _, row in ipairs(f.rows) do
    row:Hide(); row.bar:Hide(); row.own:Hide(); row.ghost:Hide()
    row.price:SetText(""); row.qty:SetText(""); row.cum:SetText("")
  end
  f.fairLine:Hide(); f.note:SetText(""); f.foot1:SetText(""); f.foot2:SetText("")
  local d = M.GetDepth and M.GetDepth(id)
  if not d or not d.levels[1] then
    f.sub:SetText("no scan data")
    f.note:SetText("Not in your newest full scan. Run Midas Scan to fill the book.")
    return
  end
  local ago = math.max(0, time() - (d.ts or 0))
  local agoTxt = (ago < 3600) and string.format("%d min ago", math.floor(ago / 60))
    or (ago < 86400) and string.format("%.1f h ago", ago / 3600)
    or string.format("%d d ago", math.floor(ago / 86400))
  f.sub:SetText(string.format("%d listed  \194\183  scanned %s", d.listed or d.units, agoTxt))
  local m = M.Metrics(M.GetSeries(key) or {}, key)
  local fair = m and m.fair and m.fair > 0 and m.fair or nil
  -- same display-price grouping as the big book
  local gl = {}
  for _, l in ipairs(d.levels) do
    local lbl = M.MoneyPlain(l.price)
    local g = gl[#gl]
    if g and g.lbl == lbl then g.qty = g.qty + l.qty; g.cum = l.cum
    else gl[#gl + 1] = { lbl = lbl, price = l.price, qty = l.qty, cum = l.cum } end
  end
  -- your own asks per displayed price (every character of this realm+faction).
  -- They sit INSIDE a scanned level only at its exact copper price: a 1c
  -- undercut posted after the scan reads like the level (silver rounding)
  -- but is supply the scan never saw
  local lvByPrice = {}
  for _, l in ipairs(d.levels) do lvByPrice[l.price] = l end
  local myByLbl, myQty, myNew = {}, 0, 0
  if M.db and M.db.chars then
    for _, ch in pairs(M.db.chars) do
      local a = ch.auctions and ch.auctions[id]
      if a and (not M.CharInScope or M.CharInScope(ch)) then
        myQty = myQty + (a.qty or 0)
        if a.lv then for p, q in pairs(a.lv) do
          local l = scanLevelAt(lvByPrice, p)
          local inScan = l and math.min(q, l.qty) or 0
          if inScan > 0 then
            local lbl = M.MoneyPlain(l.price); myByLbl[lbl] = (myByLbl[lbl] or 0) + inScan
          end
          myNew = myNew + (q - inScan)
        end end
      end
    end
  end
  local availH = (f:GetHeight() or 400) - 60 - 40
  local n = math.min(#gl, AHB_ROWS, math.max(4, math.floor(availH / 18)))
  local maxCum = math.max(1, gl[n].cum)
  local W2 = math.max(60, (f:GetWidth() or 320) - 20 - 82 - 34 - 40)
  local mint = C.mint or C.accent
  local fairAbove
  for i = 1, n do
    local e, row = gl[i], f.rows[i]
    row:Show()
    local below = fair and e.price < fair
    local pc = below and C.green or C.text
    row.price:SetText(e.lbl); row.price:SetTextColor(pc[1], pc[2], pc[3])
    local prev = e.cum - e.qty
    local gw = W2 * prev / maxCum
    row.ghost:ClearAllPoints(); row.ghost:SetPoint("LEFT", 82, 0); row.ghost:SetHeight(10)
    if prev > 0 then row.ghost:SetWidth(math.max(1, gw)); row.ghost:Show() end
    local own = math.min(myByLbl[e.lbl] or 0, e.qty)
    local bw = math.max(3, W2 * e.qty / maxCum)
    local ownW = (own > 0) and math.min(bw, math.max(2, math.floor(bw * own / e.qty + 0.5))) or 0
    local otherW = bw - ownW
    local rgb = below and C.green or (C.teal or C.accent)
    row.bar:ClearAllPoints(); row.bar:SetPoint("LEFT", 82 + gw, 0); row.bar:SetHeight(10)
    row.bar:SetColorTexture(rgb[1], rgb[2], rgb[3], below and 0.8 or 0.7)
    if otherW > 0 then row.bar:SetWidth(otherW); row.bar:Show() end
    row.own:ClearAllPoints(); row.own:SetPoint("LEFT", 82 + gw + otherW, 0); row.own:SetHeight(10)
    row.own:SetColorTexture(mint[1], mint[2], mint[3], 0.85)
    if ownW > 0 then row.own:SetWidth(ownW); row.own:Show() end
    row.qty:ClearAllPoints()
    row.qty:SetPoint("LEFT", (ownW > 0) and row.own or row.bar, "RIGHT", 5, 0)
    row.qty:SetText(e.qty)
    row.cum:SetText(e.cum)
    if fair and not fairAbove and e.price >= fair then fairAbove = i end
  end
  -- one thin FAIR line on the edge between below- and above-fair rows
  if fairAbove then
    local ly = -60 - (fairAbove - 1) * 18
    f.fairLine:ClearAllPoints()
    f.fairLine:SetPoint("TOPLEFT", 10, ly); f.fairLine:SetPoint("TOPRIGHT", -10, ly)
    f.fairLine:Show()
  end
  local ft = {}
  if fair then ft[#ft + 1] = "Fair " .. M.MoneyPlain(fair) end
  if m and m.quick then ft[#ft + 1] = "quick-sell " .. M.MoneyPlain(m.quick) end
  f.foot1:SetText(table.concat(ft, "   \194\183   "))
  if myQty > 0 then
    local t = "your asks \195\151" .. myQty .. "  (mint share)"
    if myNew > 0 then t = t .. "  \194\183  \195\151" .. myNew .. " posted after the scan" end
    f.foot2:SetText(t)
    f.foot2:SetTextColor(mint[1], mint[2], mint[3])
  elseif #gl > n then
    f.foot2:SetText("+" .. (#gl - n) .. " higher prices not shown")
    f.foot2:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
  end
end

function M.ShowAHBook(id)
  if not id then if ahb then ahb:Hide() end return end
  if not M.db then return end
  if M.db.config and M.db.config.ahBook == false then if ahb then ahb:Hide() end return end
  if ahb and ahb._dismissed then return end   -- X-ed away for this AH visit
  if not M.AHOpen then return end
  -- the book is your own market's last scan: wrong at a neutral AH
  if M.AtNeutralAH() then if ahb then ahb:Hide() end return end
  local f = ahBookPanel()
  if not f then return end
  f._id = id
  ahBookFill(id)
  f:Show()
end

-- modern client: the sell frames receive their item via SetItem(itemLocation)
local function hookModernSell()
  if M._ahSellHooked then return end
  local ahf = _G.AuctionHouseFrame
  if not ahf then return end
  local function onSet(_, loc)
    local ok2, id = pcall(function() return loc and C_Item.GetItemID(loc) end)
    if ok2 and type(id) == "number" then M.ShowAHBook(id) end
  end
  local hooked = false
  if ahf.ItemSellFrame and ahf.ItemSellFrame.SetItem then
    pcall(hooksecurefunc, ahf.ItemSellFrame, "SetItem", onSet); hooked = true
  end
  if ahf.CommoditiesSellFrame and ahf.CommoditiesSellFrame.SetItem then
    pcall(hooksecurefunc, ahf.CommoditiesSellFrame, "SetItem", onSet); hooked = true
  end
  M._ahSellHooked = hooked or nil
end

-- feeders: classic sell slot + browse selection, modern buy views + sell frames
local ahbEv = CreateFrame("Frame")
M.SafeRegister(ahbEv, "AUCTION_HOUSE_SHOW")
M.SafeRegister(ahbEv, "AUCTION_HOUSE_CLOSED")
M.SafeRegister(ahbEv, "NEW_AUCTION_UPDATE")                 -- classic: sell slot
M.SafeRegister(ahbEv, "ITEM_SEARCH_RESULTS_UPDATED")        -- modern: item buy view
M.SafeRegister(ahbEv, "COMMODITY_SEARCH_RESULTS_UPDATED")   -- modern: commodity buy view
ahbEv:SetScript("OnEvent", function(_, ev, a1)
  if ev == "AUCTION_HOUSE_CLOSED" then
    if ahb then ahb:Hide(); ahb._dismissed = nil end
  elseif ev == "AUCTION_HOUSE_SHOW" then
    hookModernSell()
  elseif ev == "NEW_AUCTION_UPDATE" then
    local id
    if GetAuctionSellItemInfo then
      local name, _, _, _, _, _, _, _, _, sellID = GetAuctionSellItemInfo()
      id = sellID
      if not id and name then
        local link = select(2, M.GetItemInfo(name))
        id = link and tonumber(link:match("item:(%d+)"))
      end
    end
    M.ShowAHBook(id)   -- slot emptied -> id nil -> hide
  elseif ev == "ITEM_SEARCH_RESULTS_UPDATED" then
    local id = a1 and a1.itemID
    if id then M.ShowAHBook(id) end
  elseif ev == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    if type(a1) == "number" then M.ShowAHBook(a1) end
  end
end)
-- classic: clicking a browse row selects it. The whole block only runs where
-- SetSelectedAuctionItem exists; the _G lookups keep these classic-only calls
-- out of the static modern-client marker scan (they are unreachable there).
if _G.SetSelectedAuctionItem and hooksecurefunc then
  local GAII, GAIL = _G["GetAuctionItemInfo"], _G["GetAuctionItemLink"]
  hooksecurefunc("SetSelectedAuctionItem", function(listType, index)
    if listType ~= "list" or not index or not GAII then return end
    local id = select(17, GAII("list", index))
    if not id and GAIL then
      local link = GAIL("list", index)
      id = link and tonumber(link:match("item:(%d+)"))
    end
    if id then M.ShowAHBook(id) end
  end)
end

-- live offer book: a BUYOUT the player makes thins the ladder right away -
-- the aux/Blizzard buy paths both go through PlaceAuctionBid. The _G lookup
-- keeps the classic-only GetAuctionItemInfo out of the static marker scan.
if _G.PlaceAuctionBid and hooksecurefunc then
  local GAII3 = _G["GetAuctionItemInfo"]
  hooksecurefunc("PlaceAuctionBid", function(listType, index, bid)
    if listType ~= "list" or not index or not GAII3 then return end
    local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, id = GAII3("list", index)
    if not id or not buyout or buyout <= 0 or not bid or bid < buyout then return end
    local units = (count and count > 0) and count or 1
    if M.DepthBuyout and M.DepthBuyout(id, math.floor(buyout / units), units) then
      if ahb and ahb:IsShown() and ahb._id == id then ahBookFill(id) end
      if M.RequestUIRefresh then M.RequestUIRefresh() end
    end
  end)
end

-- ===== Sell helper docked under the auction house ===========================
-- The sell tab docks a bar of your bag items, best sale first (% over fair):
-- click one and it lands in the sell slot; listing it empties the bag slot and
-- the next candidates slide up (BAG_UPDATE_DELAYED refill). Settings >
-- "Sell helper at the AH" turns it off (config.sellDock == false; unset = on).
local sdk                 -- the docked bar, built lazily
local SDK_CW = 40         -- cell width (32px icon + gap)

local function sdNumSlots(bag)
  if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) or 0 end
  return (_G.GetContainerNumSlots and _G.GetContainerNumSlots(bag)) or 0
end

-- id, count, bound for one bag slot (C_Container with old-global fallback)
local function sdSlot(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if info then return info.itemID, info.stackCount or 1, info.isBound end
    return nil
  end
  if _G.GetContainerItemInfo then
    local _, count, _, _, _, _, _, _, _, itemID = _G.GetContainerItemInfo(bag, slot)
    return itemID, count or 1, nil
  end
end

local function sdPickup(bag, slot)
  if C_Container and C_Container.PickupContainerItem then C_Container.PickupContainerItem(bag, slot)
  elseif _G.PickupContainerItem then _G.PickupContainerItem(bag, slot) end
end

-- the window the dock anchors to: an AH-replacing addon's frame (aux) wins,
-- because the Blizzard frame is hidden underneath it
local function sdAnchor()
  local aux = _G.aux_frame
  if aux and aux:IsShown() then return aux end
  local AH = _G.AuctionFrame
  if AH and AH:IsShown() then return AH end
  local mAH = _G.AuctionHouseFrame
  if mAH and mAH:IsShown() then return mAH end
end

local function sellDockPanel(host)
  if sdk then return sdk end
  if not host then return nil end
  sdk = CreateFrame("Frame", "MidasSellDock", host, "BackdropTemplate")
  sdk:SetBackdrop(T.FLAT)
  sdk:SetBackdropColor(C.bg0[1], C.bg0[2], C.bg0[3], 0.97)
  sdk:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1)
  sdk:SetHeight(70)
  sdk.head = T.Text(sdk, T.SIZE.tiny, "muted", T.FONT_MED)
  sdk.head:SetPoint("TOPLEFT", 10, -7)
  -- small X: hides the dock for this AH visit (Settings turns it off for good)
  if T.Close then
    local xb = T.Close(sdk)
    xb:SetPoint("TOPRIGHT", -3, -3)
    xb:SetFrameLevel(sdk:GetFrameLevel() + 5)
    xb:SetScript("OnClick", function()
      sdk._dismissed = true
      sdk:Hide()
      dockHint()
    end)
  end
  sdk.empty = T.Text(sdk, T.SIZE.small, "sub")
  sdk.empty:SetPoint("TOPLEFT", 10, -32)
  sdk.more = T.Text(sdk, T.SIZE.tiny, "muted", T.FONT_MED)
  sdk.cells = {}
  sdk:RegisterEvent("BAG_UPDATE_DELAYED")     -- an item listed/looted -> slide up
  sdk:SetScript("OnEvent", function(f)
    if f:IsShown() and not f._tick then
      f._tick = true
      C_Timer.After(0.2, function() f._tick = nil; if f:IsShown() then M.ShowSellDock() end end)
    end
  end)
  sdk:Hide()
  return sdk
end

local function sdCell(i)
  local f = sdk
  local c = f.cells[i]
  if c then return c end
  c = CreateFrame("Button", nil, f)
  c:SetSize(32, 32)
  c:SetPoint("TOPLEFT", 10 + (i - 1) * SDK_CW, -20)
  c.icon = c:CreateTexture(nil, "ARTWORK")
  c.icon:SetAllPoints(); c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  local hl = c:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.12)
  c.count = c:CreateFontString(nil, "OVERLAY")
  T.RegFont(c.count, T.FONT_MED, T.SIZE.tiny)
  c.count:SetPoint("BOTTOMRIGHT", -1, 1); c.count:SetJustifyH("RIGHT")
  c.count:SetTextColor(T.Unpack(C.text))
  c.pct = T.Text(f, T.SIZE.tiny, "sub", T.FONT_MED)
  c.pct:SetPoint("TOP", c, "BOTTOM", 0, -2); c.pct:SetWidth(SDK_CW); c.pct:SetJustifyH("CENTER")
  -- the real in-game item tooltip (with the Midas lines), opening UPWARD from
  -- the cell: the dock sits at the bottom edge of the AH frame, and anchoring
  -- at the main Midas window (ShowItemTip) would point nowhere useful here
  c:SetScript("OnEnter", function()
    if not c.bag then return end
    GameTooltip:SetOwner(c, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    local fl, cl = sdk:GetLeft() or 0, c:GetLeft() or 0
    if (cl - fl) > (sdk:GetWidth() or 740) * 0.5 then
      GameTooltip:SetPoint("BOTTOMRIGHT", c, "TOPRIGHT", 0, 6)
    else
      GameTooltip:SetPoint("BOTTOMLEFT", c, "TOPLEFT", 0, 6)
    end
    GameTooltip:SetBagItem(c.bag, c.slot)
    GameTooltip:Show()
  end)
  c:SetScript("OnLeave", HideTip)
  c:SetScript("OnClick", function()
    if not c.bag then return end
    -- an item already on the cursor (e.g. just dragged off this dock and
    -- released over it) must never be swallowed here - leave it to the user
    if CursorHasItem and CursorHasItem() then return end
    sdPickup(c.bag, c.slot)
    local click = _G.ClickAuctionSellItemButton
    local au = _G.AuctionFrameAuctions
    if click and au and au:IsShown() then
      -- the real, VISIBLE Blizzard sell tab: straight into its slot
      click()
      ClearCursor()     -- a swapped-out previous item returns to its bag
    else
      -- replaced AH UI (aux/Auctionator/TSM) or modern client: the item stays
      -- on the CURSOR. Feeding the hidden native slot just swallows the item -
      -- those UIs never read it (and aux even clears it)
      if M.db and M.db.config and M.db.config.sellCursorNote ~= 1 then
        M.db.config.sellCursorNote = 1
        M.Print("The item is on your CURSOR - drop it into your AH addon's post slot. (Clicking fills the sell slot directly only on the standard Blizzard sell tab.)")
      end
    end
  end)
  -- drag the icon: the item follows the cursor - drop it on ANY post slot
  -- (aux and other UIs that refuse the native slot)
  c:RegisterForDrag("LeftButton")
  c:SetScript("OnDragStart", function()
    if not c.bag then return end
    if CursorHasItem and CursorHasItem() then return end
    sdPickup(c.bag, c.slot)
  end)
  f.cells[i] = c
  return c
end

local function sellDockFill()
  local f = sdk
  local items, list = {}, {}
  for bag = 0, 4 do
    for slot = 1, sdNumSlots(bag) do
      local id, count, bound = sdSlot(bag, slot)
      if id and not bound then
        local key = tostring(id)
        local e = items[key]
        if e == nil then
          local m = M.Metrics(M.GetSeries(key) or {}, key)
          if m and m.fair and m.fair > 0 and m.cur and m.cur > 0 then
            e = { key = key, id = id, bag = bag, slot = slot, n = 0,
                  delta = (m.cur - m.fair) / m.fair }
            list[#list + 1] = e
          else
            e = false     -- no price data: remember, so further stacks skip Metrics
          end
          items[key] = e
        end
        if e then e.n = e.n + (count or 1) end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.delta ~= b.delta then return a.delta > b.delta end
    return a.key < b.key
  end)
  local w = f:GetWidth() or 740
  local maxN = math.max(1, math.floor((w - 50) / SDK_CW))
  local shown = math.min(#list, maxN)
  for i = 1, shown do
    local e, c = list[i], sdCell(i)
    c.key, c.bag, c.slot = e.key, e.bag, e.slot
    c.icon:SetTexture((M.GetItemIcon and M.GetItemIcon(e.id)) or "Interface\\Icons\\INV_Misc_QuestionMark")
    c.count:SetText(e.n > 1 and e.n or "")
    c.pct:SetText(string.format("%+d%%", e.delta * 100))
    -- seller's view: well over fair = a good sale (green), under fair = hold (red)
    local col = (e.delta >= M.C.PICK_DELTA) and C.green
      or (e.delta <= -M.C.PICK_DELTA) and C.red or C.sub
    c.pct:SetTextColor(col[1], col[2], col[3])
    c:Show(); c.pct:Show()
  end
  for i = shown + 1, #f.cells do
    local c = f.cells[i]
    c:Hide(); c.pct:Hide(); c.key, c.bag = nil, nil
  end
  f.empty:SetShown(shown == 0)
  if shown == 0 then f.empty:SetText("Nothing in your bags has price data yet - run a scan.") end
  if #list > shown and shown > 0 then
    f.more:ClearAllPoints()
    f.more:SetPoint("LEFT", f.cells[shown], "RIGHT", 8, 0)
    f.more:SetText("+" .. (#list - shown)); f.more:Show()
  else
    f.more:Hide()
  end
  -- the bar may have re-sorted under the cursor (item listed / fresh scan):
  -- keep the hovered cell's tooltip honest
  for i = 1, #f.cells do
    local c = f.cells[i]
    if GameTooltip:IsShown() and GameTooltip:GetOwner() == c then
      if c:IsShown() and c.bag then
        GameTooltip:SetBagItem(c.bag, c.slot)
      else
        GameTooltip:Hide()
      end
    end
  end
end

function M.ShowSellDock()
  if not M.db then return end
  if M.db.config and M.db.config.sellDock == false then if sdk then sdk:Hide() end return end
  if sdk and sdk._dismissed then return end   -- X-ed away for this AH visit
  -- its ranking and prices are your own market's: wrong at a neutral AH
  if not M.AHOpen or M.AtNeutralAH() then if sdk then sdk:Hide() end return end
  local host = sdAnchor()
  if not host then if sdk then sdk:Hide() end return end
  -- Blizzard classic UI IN USE = one of its tab panels is on screen: dock only
  -- beside the Auctions (sell) tab. AH-replacing addons (aux/Auctionator) keep
  -- AuctionFrame shown but hide all its panels and draw their own window over
  -- it - then no panel is visible and the bar simply stays for the session.
  local au = _G.AuctionFrameAuctions
  local sellSlot = (au and au:IsShown()) and true or false
  if host == _G.AuctionFrame and not sellSlot then
    local br, bi = _G.AuctionFrameBrowse, _G.AuctionFrameBid
    local tabVisible = (br and br:IsShown()) or (bi and bi:IsShown())
    if tabVisible then if sdk then sdk:Hide() end return end
  end
  local f = sellDockPanel(host)
  if not f then return end
  -- the host can change between sessions/UIs: re-anchor every show
  if f._host ~= host then
    f._host = host
    f:SetParent(host)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", host, "BOTTOMLEFT", 12, -24)    -- below the tab row
    f:SetPoint("TOPRIGHT", host, "BOTTOMRIGHT", -2, -24)
    f:SetFrameLevel(host:GetFrameLevel() + 10)
  end
  f.head:SetText(sellSlot
    and "SELL NEXT  \194\183  your bags by % over fair  \194\183  click = into the sell slot"
    or "SELL NEXT  \194\183  your bags by % over fair  \194\183  click or drag = onto your cursor, drop it on the post slot")
  sellDockFill()
  f:Show()
end

-- classic: the dock follows the Auctions (sell) tab. The Blizzard panels exist
-- only after Blizzard_AuctionUI loads, so the hook runs from AUCTION_HOUSE_SHOW.
local function hookSellDock()
  if M._sellDockHooked then return end
  if not _G.AuctionFrameAuctions then return end
  -- re-evaluate on EVERY Blizzard panel change: tab switches show/hide the
  -- bar, and an AH-replacing addon hiding all panels (aux) brings it back
  for _, p in ipairs({ _G.AuctionFrameAuctions, _G.AuctionFrameBrowse, _G.AuctionFrameBid }) do
    if p then
      p:HookScript("OnShow", function() M.ShowSellDock() end)
      p:HookScript("OnHide", function() M.ShowSellDock() end)
    end
  end
  M._sellDockHooked = true
end

local sdkEv = CreateFrame("Frame")
M.SafeRegister(sdkEv, "AUCTION_HOUSE_SHOW")
M.SafeRegister(sdkEv, "AUCTION_HOUSE_CLOSED")
sdkEv:SetScript("OnEvent", function(_, ev)
  if ev == "AUCTION_HOUSE_CLOSED" then
    if sdk then sdk:Hide(); sdk._dismissed = nil end
  else
    -- next frame: the scanners' own handlers set M.AHOpen first
    C_Timer.After(0, function()
      hookSellDock()
      M.ShowSellDock()   -- classic stays hidden until the sell tab opens
    end)
  end
end)

-- ===== Reusable detail card (mini chart + stats), borderless ================
local function CreateChartCard(parent, x0, w, h)
  local card = CreateFrame("Frame", nil, parent)
  -- fully elastic: pinned between the table's right edge (x0) and the parent's
  -- bottom-right corner, so a wider/taller window all goes into the preview
  -- chart instead of a dead gap (w/h kept for call compatibility; at the
  -- 980x560 baseline the size works out to exactly the old w x h)
  card:SetPoint("TOPLEFT", x0, 0); card:SetPoint("BOTTOMRIGHT", 0, 0)
  local obj = { frame = card }

  local title = T.Text(card, T.SIZE.h2 + 1, "text", T.FONT_SEMI)
  title:SetPoint("TOPLEFT", 10, -12); title:SetPoint("TOPRIGHT", -26, -12)
  title:SetJustifyH("LEFT"); title:SetText("Hover an item for details")
  obj.title = title

  -- "?" methodology help so the price basis is transparent, on every detail card
  local help = CreateFrame("Button", nil, card)
  help:SetSize(16, 16); help:SetPoint("TOPRIGHT", -6, -11)
  local hq = help:CreateFontString(nil, "OVERLAY")
  T.RegFont(hq, T.FONT_MED, T.SIZE.body); hq:SetPoint("CENTER"); hq:SetText("?")
  hq:SetTextColor(T.Unpack(C.muted))
  help:SetScript("OnEnter", function() hq:SetTextColor(T.Unpack(C.accent)) end)
  help:SetScript("OnLeave", function() hq:SetTextColor(T.Unpack(C.muted)) end)
  if T.HelpTip then
    -- method text comes from the shared source (Theme.T.HELP) + one line about
    -- what the card-specific numbers mean
    local L = {}
    for _, ln in ipairs(T.HELP.fair[2]) do L[#L + 1] = ln end
    L[#L + 1] = ""
    L[#L + 1] = "The % next to Fair is its estimated sell chance; the odds after 'vs fair' are the chance at the CURRENT price. Quick-sell: at/just below the current floor - near-certain, less margin."
    T.HelpTip(help, "How Midas prices", L)
  end

  local cat = T.Text(card, T.SIZE.small, "sub")
  cat:SetPoint("TOPLEFT", 10, -30); cat:SetText("")
  obj.cat = cat

  local canvas = CreateFrame("Frame", nil, card) -- transparent plot (Scalable: line on dark bg)
  -- elastic height: the preview chart absorbs the card's extra room; 142px at
  -- the bottom stay reserved for the bottom-anchored stat block + hint
  canvas:SetPoint("TOPLEFT", 8, -48); canvas:SetPoint("BOTTOMRIGHT", -8, 142)
  canvas._compact = true   -- small preview: hover shows ONE compact read-out, not per-series boxes
  obj.canvas = canvas

  obj.stats = {}
  for i = 1, 5 do
    local y = 118 - (i - 1) * 22          -- bottom-anchored under the elastic chart
    local lbl = T.Text(card, T.SIZE.body, "sub")
    lbl:SetPoint("BOTTOMLEFT", 12, y)
    local val = T.Text(card, T.SIZE.body, "text", T.FONT_MED)
    val:SetPoint("BOTTOMRIGHT", -12, y); val:SetJustifyH("RIGHT")
    obj.stats[i] = { lbl = lbl, val = val }
  end

  local hint = T.Text(card, T.SIZE.small, "muted")
  hint:SetPoint("BOTTOMLEFT", 10, 8); hint:SetPoint("BOTTOMRIGHT", -8, 8)
  hint:SetJustifyH("LEFT"); hint:SetText("Hover: preview   \194\183   Click: full chart")
  obj.hint = hint
  -- the hovered item's pages as chips in place of the hint (Nav.lua); what
  -- does not fit the card stays in the right-click menu
  if M.LinkBar then
    obj.links = M.LinkBar(card, { short = true })
    obj.links:SetPoint("BOTTOMLEFT", 10, 5)
    obj.links:Hide()
  end
  M.detailCards = M.detailCards or {}
  M.detailCards[#M.detailCards + 1] = obj
  return obj
end

local function setStat(obj, i, label, value, rgb)
  obj.stats[i].lbl:SetText(label)
  obj.stats[i].val:SetText(value)
  if rgb then colorize(obj.stats[i].val, rgb) else colorize(obj.stats[i].val, C.text) end
end

-- Re-fills only when the item OR the data generation changed: a scan, sync,
-- trade mail or the Fair slider bumps M._analysisGen, so the card follows the
-- table rows next to it instead of keeping the numbers of its first fill.
local function cardLinks(obj, key)
  if not obj.links then return end
  if key then
    local w = obj.frame:GetWidth() or 0
    if w < 120 then w = 240 end
    obj.links:SetItem(key, w - 20)
  else
    obj.links:SetItem(nil)
  end
  if obj.hint then obj.hint:SetShown(not obj.links:IsShown()) end
end

function M.FillChartCard(obj, key)
  if not obj then return end
  local gen = M._analysisGen or 0
  if obj.shownKey == key and obj.shownGen == gen then return end
  obj.shownKey, obj.shownGen = key, gen
  cardLinks(obj, key)
  if not key then
    obj.title:SetText("No data"); colorize(obj.title, C.sub); obj.cat:SetText("")
    for i = 1, 5 do obj.stats[i].lbl:SetText(""); obj.stats[i].val:SetText("") end
    if M.RenderItemChart then M.RenderItemChart(obj.canvas, nil) end
    return
  end
  local qc = M.ItemQualityColor(key)
  obj.title:SetText(M.ItemName(key)); obj.title:SetTextColor(qc.r, qc.g, qc.b)
  obj.cat:SetText(M.ItemCategory(key)); colorize(obj.cat, C.sub)
  local series = M.GetSeries(key)
  local m = series and M.Metrics(series, key)
  if not m then
    for i = 1, 5 do obj.stats[i].lbl:SetText(""); obj.stats[i].val:SetText("") end
    obj.stats[1].lbl:SetText("No price data on this realm yet"); colorize(obj.stats[1].lbl, C.muted)
    if M.RenderItemChart then M.RenderItemChart(obj.canvas, nil) end
    return
  end
  local cur = m.cur
  local delta = m.delta
  obj.cat:SetText(M.ItemCategory(key) .. "   \194\183   " .. m.days .. " days"); colorize(obj.cat, C.sub)
  local sells = m.liqLabel or "?"
  if m.speed then sells = string.format("~%.1f/day \194\183 %s", m.speed, m.liqLabel or "?") end
  local gone = M.NotListed and M.NotListed(m)
  if gone then
    setStat(obj, 1, "Last seen", M.MoneyPlain(cur) .. "  \194\183  " .. M.DayLabel(M.SeenDay(m)), C.muted)
  else
    setStat(obj, 1, "Current", M.MoneyPlain(cur))
  end
  -- Fair carries its calibrated sell chance; oversupplied = even the trimmed
  -- market level stays below the target odds (post less, don't price lower)
  local fairLbl = "Fair"
  if m.oddsAtFair then fairLbl = string.format("Fair (~%.0f%% odds)", m.oddsAtFair * 100) end
  if m.fairCapped then fairLbl = fairLbl .. " \194\183 oversupplied" end
  setStat(obj, 2, fairLbl, M.MoneyPlain(m.fair))
  local drgb = C[M.DeltaColor and M.DeltaColor(delta) or "sub"] or C.sub
  local vsTxt = string.format("%+.0f%%", delta * 100)
  if m.odds then vsTxt = string.format("%+.0f%%  \194\183  ~%.0f%% odds", delta * 100, m.odds * 100) end
  if gone then vsTxt, drgb = "not listed in the newest scan", C.muted end
  setStat(obj, 3, "vs fair", vsTxt, drgb)
  setStat(obj, 4, "Sells", sells)
  setStat(obj, 5, "Quick-sell", M.MoneyPlain(m.quick))
  if M.RenderItemChart then M.RenderItemChart(obj.canvas, key) end
end

-- ===== Shared item-row helpers ==============================================
-- (the Start tab itself lives in Home.lua)
local function wireItemBtn(b)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnEnter", function() if b.key then ShowItemTip(b.key) end end)
  b:SetScript("OnLeave", HideTip)
  b:SetScript("OnClick", function(_, mouse)
    if not b.key then return end
    if M.ModPostDown() then M.PostItemStats(b.key); return end
    if M.ModSearchDown() then M.ItemShiftAction(b.key); return end
    if mouse == "RightButton" then
      M.ToggleWatch(b.key)
      if M.RefreshHome then M.RefreshHome() end
    else
      GoChart(b.key)
    end
  end)
end

local function setItemName(fs, key, fallbackText)
  if key then
    fs:SetText(M.ItemName(key))
    local qc = M.ItemQualityColor(key); fs:SetTextColor(qc.r, qc.g, qc.b)
  else
    fs:SetText(fallbackText or ""); colorize(fs, C.text)
  end
end


-- ===== Settings tab: general options + community sync =======================
-- The old Sync tab, rededicated: everything configurable lives HERE (plus the
-- three chart toggles in the window header, which stay next to the charts).
-- height of the scrolling left column of the Settings tab (general options,
-- sync status, live log); a taller window simply shows more of the log
local SET_LEFT_H = 700

function M.BuildSettings(panel)
  local s = {}
  M.setUI = s
  local function hx(c) return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255) end
  local GRN, RED, WHT, MUT, GOLD, MINT = hx(C.green), hx(C.red), hx(C.text), hx(C.muted), hx(C.accent), hx(C.mint)
  s.GRN, s.RED, s.WHT, s.MUT, s.GOLD, s.MINT = GRN, RED, WHT, MUT, GOLD, MINT

  vline(panel, 445)
  -- the left column scrolls: the general options, the sync status and the
  -- live log need about 700px; the panel has 426 at the smallest window
  local lscroll = CreateFrame("ScrollFrame", "MidasSettingsScroll", panel, "UIPanelScrollFrameTemplate")
  lscroll:SetPoint("TOPLEFT", 0, 0); lscroll:SetPoint("BOTTOMLEFT", 0, 0); lscroll:SetWidth(430)
  local left = CreateFrame("Frame", nil, lscroll)
  left:SetSize(430, SET_LEFT_H)
  lscroll:SetScrollChild(left)
  T.StyleScrollbar("MidasSettingsScroll")
  s.left, s.leftScroll = left, lscroll


  -- ----- GENERAL (left column) ---------------------------------------------
  local gh = T.Text(left, T.SIZE.small, "muted", T.FONT_MED)
  gh:SetPoint("TOPLEFT", 0, -2); gh:SetText("GENERAL")

  local tl = T.Text(left, T.SIZE.body, "sub")
  tl:SetPoint("TOPLEFT", 0, -26); tl:SetText("Item tooltip")
  local tipSeg = T.Segment(left, {
    { key = "full",    label = "Full" },
    { key = "reduced", label = "Reduced" },
    { key = "off",     label = "Off" },
  }, function(key)
    M.db.config.tooltipMode = key
    if s.setPreview then s.setPreview(key) end
  end)
  tipSeg.frame:SetPoint("TOPLEFT", 150, -22)
  s.tipSeg = tipSeg
  if T.HelpTip then
    T.HelpTip(tipSeg.frame, "Item tooltip", {
      "The Midas block shown on every item tooltip in the game (bags, bank, AH, chat links).",
      "Full: signal, Current/Fair, sell speed, quick-sell, AH supply, sell odds and what you paid. Reduced: just the signal and Current vs Fair. Off: no Midas lines at all.",
      "The preview below shows exactly what each setting produces." })
  end

  -- craft / disenchant lines in item tooltips (Crafting.lua), default on
  local tcCb = T.Checkbox(left, "Craft lines", function(on)
    if on then M.db.config.tooltipCraft = nil else M.db.config.tooltipCraft = false end
    if s.setPreview then s.setPreview(M.db.config.tooltipMode or "full") end
    if M.RerenderCharts then M.RerenderCharts() end
  end)
  tcCb:SetPoint("TOPLEFT", 318, -24)
  s.tcCb = tcCb
  if T.HelpTip then
    T.HelpTip(tcCb, "Craft lines", {
      "Adds what an item costs to make from its materials (now in gold, Fair in purple, with the profit after the AH cut), what gear disenchants into, and how many recipes use a material.",
      "Craftable items without market data get these lines too. The full tree is in the Crafting tab.",
      "Also draws the dashed mint \"Crafted\" line (what it costs to make now) in the item's big chart." })
  end

  -- live preview of the tooltip block (mirrors Tooltip.lua's example output)
  local pv = T.Surface(left, "bg0", "border")
  pv:SetPoint("TOPLEFT", 0, -52); pv:SetSize(430, 118)
  local pvL, pvR = {}, {}
  local PREVIEW = {
    { "|cffE8B44AMidas|r",                        "|cff5CD178+18% above fair|r" },
    { "|cff5CD178Current  12g 34s|r",             "Fair (~52%)  10g 50s" },
    { "Craft  |cffFDCC619g 40s|r  |cff5CD178+24%|r", "|cff9E8CFAfair 9g 10s|r  |cff5CD178+20%|r" },
    { "Sells  ~6.0/day \194\183 Steady",           "Quick-sell  9g 80s" },
    { "In AH now:  14",                           "Avg in AH:  11" },
    { "|cff5CD178Sell odds at current price  ~44%|r", "" },
    { "You paid  8g 20s avg  (12 bought)",        "" },
  }
  for i, ln in ipairs(PREVIEW) do
    local y = -7 - (i - 1) * 15
    pvL[i] = T.Text(pv, T.SIZE.small, "sub"); pvL[i]:SetPoint("TOPLEFT", 12, y); pvL[i]:SetText(ln[1])
    pvR[i] = T.Text(pv, T.SIZE.small, "sub"); pvR[i]:SetPoint("TOPRIGHT", -12, y); pvR[i]:SetJustifyH("RIGHT"); pvR[i]:SetText(ln[2])
  end
  local pvOff = T.Text(pv, T.SIZE.small, "muted")
  pvOff:SetPoint("CENTER", 0, 0); pvOff:SetText("no Midas lines on item tooltips"); pvOff:Hide()
  local pvCap = T.Text(left, T.SIZE.tiny, "muted", T.FONT_MED)
  pvCap:SetPoint("TOPLEFT", pv, "BOTTOMLEFT", 0, -4)
  pvCap:SetText("PREVIEW \194\183 what an item tooltip will show")
  function s.setPreview(mode)
    local nShow = (mode == "off") and 0 or (mode == "reduced") and 3 or #PREVIEW
    local craft = M.db.config.tooltipCraft ~= false and (not M.CraftingOn or M.CraftingOn())
    local y = -7
    for i = 1, #PREVIEW do
      local show = i <= nShow and (i ~= 3 or craft)
      pvL[i]:SetShown(show)
      pvR[i]:SetShown(show)
      if show then
        pvL[i]:SetPoint("TOPLEFT", 12, y); pvR[i]:SetPoint("TOPRIGHT", -12, y)
        y = y - 15
      end
    end
    pvOff:SetShown(mode == "off")
  end

  local mmCb = T.Checkbox(left, "Minimap button", function(on)
    if M.SetMinimapShown then M.SetMinimapShown(on) end
  end)
  mmCb:SetPoint("TOPLEFT", 0, -196)
  s.mmCb = mmCb

  -- second checkbox column (x 250): the left rows are full down to the log
  -- NOTE on these toggles: the and-nil-else-false shorthand is ALWAYS false in
  -- Lua (a nil result in the and branch falls through to the or) - re-enabling
  -- silently kept features off and the box unticked itself. Explicit if/else only.
  local alCb = T.Checkbox(left, "Alert lines in charts", function(on)
    if on then M.db.config.alertLines = nil else M.db.config.alertLines = false end
    M.RerenderCharts()
  end)
  alCb:SetPoint("TOPLEFT", 250, -196)
  s.alCb = alCb
  if T.HelpTip then
    T.HelpTip(alCb, "Alert lines", {
      "Draws this realm's below/above price alerts as dashed limit lines in the item's big chart (Charts tab): below in green (buy side), above in gold (sell side).",
      "A limit far outside the current price range stays off the chart, so a stray alert cannot crush the scale." })
  end

  local sdCb = T.Checkbox(left, "Sell helper at the AH", function(on)
    if on then M.db.config.sellDock = nil else M.db.config.sellDock = false end
    if on then
      if _G.MidasSellDock then _G.MidasSellDock._dismissed = nil end
      if M.ShowSellDock then M.ShowSellDock() end
    elseif _G.MidasSellDock then _G.MidasSellDock:Hide() end
  end)
  sdCb:SetPoint("TOPLEFT", 250, -218)
  s.sdCb = sdCb
  if T.HelpTip then
    T.HelpTip(sdCb, "Sell helper", {
      "Docks a bar under the auction house sell tab: everything in your bags with price data, best sale first (% over fair).",
      "Click an item and it lands in the sell slot - or DRAG it onto any post slot (for AH addons like aux that manage the slot themselves). Once listed, the next candidates slide up.",
      "Green = 15%+ over fair (sell it), red = under fair (hold)." })
  end

  local autoCb = T.Checkbox(left, "Auto-scan when the AH opens", function(on)
    M.db.config.autoScan = on and true or nil
  end)
  autoCb:SetPoint("TOPLEFT", 0, -218)
  s.autoCb = autoCb
  if T.HelpTip then
    T.HelpTip(autoCb, "Auto-scan", {
      "Starts a full scan automatically ~2 seconds after you open the auction house. Full (GetAll) scans are rate-limited by the server to roughly one per 15 minutes." })
  end

  local ahCb = T.Checkbox(left, "Offer book at the auction house", function(on)
    if on then M.db.config.ahBook = nil else M.db.config.ahBook = false end
    if not on and ahb then ahb:Hide() end
    if on and _G.MidasAHBook then _G.MidasAHBook._dismissed = nil end
  end)
  ahCb:SetPoint("TOPLEFT", 0, -240)
  s.ahCb = ahCb
  if T.HelpTip then
    T.HelpTip(ahCb, "Offer book at the AH", {
      "Docks the item's supply ladder to the auction house window whenever you pick a browse result or drop an item into the sell slot.",
      "The ladder comes from your newest full scan; clicking its title opens the full Midas chart." })
  end

  local mcCb = T.Checkbox(left, "Alt/Shift shortcuts", function(on)
    if on then M.db.config.modClicks = nil else M.db.config.modClicks = false end
  end)
  mcCb:SetPoint("TOPLEFT", 250, -240)
  s.mcCb = mcCb
  if T.HelpTip then
    T.HelpTip(mcCb, "Alt/Shift click shortcuts", {
      "ALT-click any item in Midas (or an item link in chat) to post its price card to chat. SHIFT-click an item in Midas to search it at the AH - and shift-click an item AT the AH to open its Midas chart.",
      "Off (the default on a new install) disables both shortcuts; plain clicks keep working.",
      "Rebind them per shortcut with  /midas keys post|search alt|ctrl|shift|off  -  \"/midas keys\" shows the current keys." })
  end

  -- the two onboarding helpers share a row: the starter set + the tour
  local swCb = T.Checkbox(left, "Starter watchlist", function(on)
    if on then M.db.config.starterWatch = nil else M.db.config.starterWatch = false end
    local n = M.ApplyStarterWatch and M.ApplyStarterWatch(on) or 0
    if on then
      M.Print("Starter watchlist: " .. n .. " item" .. (n == 1 and "" or "s") .. " added.")
    else
      M.Print("Starter watchlist: " .. n .. " starter item" .. (n == 1 and "" or "s") .. " removed - your own picks stay.")
    end
    if M.RequestUIRefresh then M.RequestUIRefresh() end
  end)
  swCb:SetPoint("TOPLEFT", 0, -262)
  s.swCb = swCb
  if T.HelpTip then
    T.HelpTip(swCb, "Starter watchlist", {
      "A curated base of ~80 items that trade well on most realms: consumables, trade goods and flip classics. New installs start with it.",
      "ON adds the missing ones to your watchlist; OFF removes exactly those again and keeps every item you picked yourself." })
  end

  local gsBtn = T.Button(left, "Get started guide", 150, 22)
  gsBtn:SetPoint("TOPLEFT", 250, -258)
  gsBtn:SetScript("OnClick", function() if M.ShowGuide then M.ShowGuide() end end)

  -- opt-in auto-open with the AH (CF request spudster90); default OFF
  local owCb = T.Checkbox(left, "Open with the auction house", function(on)
    M.db.config.openWithAH = on and true or nil
  end)
  owCb:SetPoint("TOPLEFT", 0, -284)
  s.owCb = owCb
  if T.HelpTip then
    T.HelpTip(owCb, "Open with the auction house", {
      "Opens the Midas window automatically whenever you open the auction house. The coin button next to \"Midas Scan\" opens it on demand either way." })
  end
  -- ledger recording (Ledger.lua); default ON, the switch only stops new bookings
  local lgCb = T.Checkbox(left, "Record ledger (beta)", function(on)
    M.db.config.ledgerOff = (not on) and true or nil
  end)
  lgCb:SetPoint("TOPLEFT", 250, -284)
  s.lgCb = lgCb
  if T.HelpTip then
    T.HelpTip(lgCb, "Record ledger (beta)", {
      "Books every gold and item flow - loot, quests, repairs, flights, sales, purchases, crafting, consumption - for the Ledger tab.",
      "Off stops new bookings; what is already recorded stays." })
  end
  -- crafting (Crafting.lua / CraftTree.lua); default ON, the same switch as
  -- "Enable crafting" in the Crafting tab
  local crCb = T.Checkbox(left, "Crafting (beta)", function(on)
    if M.SetCraftingOn then M.SetCraftingOn(on) end
    if s.setPreview then s.setPreview(M.db.config.tooltipMode or "full") end
  end)
  crCb:SetPoint("TOPLEFT", 250, -306)
  s.crCb = crCb
  if T.HelpTip then
    T.HelpTip(crCb, "Crafting (beta)", {
      "Prices every recipe of your game version from your scans: the Crafting tab's tech tree, the Crafted price and line in the Charts tab, the craft lines in item tooltips and the Craft tree links of an item.",
      "Off switches all of that off; the recipes your characters know keep being recorded. The same switch sits in the Crafting tab." })
  end
  if T.HelpTip then
    T.HelpTip(gsBtn, "Get started guide", {
      "A six-step tour of the Midas workflow: scan, watchlist, fair price, offer book, alerts and your own trades." })
  end

  -- (the rows below sit one row lower since the Crafting (beta) switch)
  local rl = T.Text(left, T.SIZE.body, "sub")
  rl:SetPoint("TOPLEFT", 0, -344); rl:SetText("Chart timeframe")
  local rangeSeg = makeRangeSeg(left)
  rangeSeg.frame:SetPoint("TOPLEFT", 150, -340)

  -- the small preview cards get their own window, independent of the big charts
  local pl = T.Text(left, T.SIZE.body, "sub")
  pl:SetPoint("TOPLEFT", 0, -372); pl:SetText("Preview timeframe")
  local prevSeg = T.Segment(left, {
    { key = "7",   label = "1W" },
    { key = "30",  label = "1M" },
    { key = "90",  label = "3M" },
    { key = "all", label = "All" },
  }, function(key)
    M.db.config.previewRange = key
    M.RerenderCharts()
  end)
  prevSeg.frame:SetPoint("TOPLEFT", 150, -368)
  s.prevSeg = prevSeg
  if T.HelpTip then
    T.HelpTip(prevSeg.frame, "Preview timeframe", {
      "How far back the small preview cards look: the hover charts on the Watchlist and Trades tabs and the net-worth chart on the Start page.",
      "All keeps the classic view - the full history (the sparkline shows its last 45 snapshots)." })
  end

  -- mini price chart docked to the item tooltip: own timeframe, or off
  local tcl = T.Text(left, T.SIZE.body, "sub")
  tcl:SetPoint("TOPLEFT", 0, -400); tcl:SetText("Tooltip chart")
  local ttSeg = T.Segment(left, {
    { key = "7",   label = "1W" },
    { key = "30",  label = "1M" },
    { key = "90",  label = "3M" },
    { key = "all", label = "All" },
    { key = "off", label = "Off" },
  }, function(key)
    M.db.config.tooltipRange = key
  end)
  ttSeg.frame:SetPoint("TOPLEFT", 150, -396)
  s.ttSeg = ttSeg
  if T.HelpTip then
    T.HelpTip(ttSeg.frame, "Tooltip chart", {
      "Docks a mini price chart to the item tooltip (bags, bank, mail, auction house) with this timeframe.",
      "Off hides the chart. The Midas text lines follow their own \"Item tooltip\" setting above." })
  end

  -- ----- SYNC STATUS + LIVE LOG (left column, below the timeframes) --------
  -- the FAIR PRICE block lives in the right column now, where its demo graph
  -- gets real height; the status read-out is monitoring and sits fine here
  local sdiv = T.Divider(left)
  sdiv:SetPoint("TOPLEFT", 0, -434); sdiv:SetPoint("TOPRIGHT", left, "TOPLEFT", 430, -434)

  -- ----- COMMUNITY SYNC (right column) -------------------------------------
  local X = 464
  local sh0 = T.Text(panel, T.SIZE.small, "muted", T.FONT_MED)
  sh0:SetPoint("TOPLEFT", X, -2); sh0:SetText("COMMUNITY SYNC")
  local sub = T.Text(panel, T.SIZE.small, "muted")
  sub:SetPoint("TOPLEFT", X, -22); sub:SetWidth(470); sub:SetJustifyH("LEFT"); sub:SetWordWrap(true)
  sub:SetText("Shares scans with your guild and with nearby Midas users (any guild) at the auction house. Invisible to other players.")

  local cb = T.Checkbox(panel, "Sync enabled", function(on)
    M.db.config.share = on and true or false
    if on and M.CommSync then C_Timer.After(0.3, function() M.CommSync() end) end
    M.RefreshSettings()
  end)
  cb:SetPoint("TOPLEFT", X, -60)
  s.cb = cb

  local tlabel = T.Text(panel, T.SIZE.small, "sub")
  tlabel:SetPoint("TOPLEFT", X, -92); tlabel:SetText("Accept data from")
  local seg = T.Segment(panel, {
    { key = "all", label = "Everyone" },
    { key = "guild", label = "Guild only" },
  }, function(key) M.db.config.shareTrust = key; M.RefreshSettings() end)
  seg.frame:SetPoint("TOPLEFT", X + 140, -88)
  s.trustSeg = seg
  if T.HelpTip then
    T.HelpTip(seg.frame, "Accept data from", {
      "Whose shared scan data Midas merges into your archive: everyone on the realm, or only your guild." })
  end

  local vlabel = T.Text(panel, T.SIZE.small, "sub")
  vlabel:SetPoint("TOPLEFT", X, -122); vlabel:SetText("Cross-guild (nearby)")
  local vseg = T.Segment(panel, {
    { key = "off", label = "Off" },
    { key = "say", label = "Say" },
    { key = "yell", label = "Yell" },
  }, function(key) M.db.config.vicinity = key; M.RefreshSettings() end)
  vseg.frame:SetPoint("TOPLEFT", X + 140, -118)
  s.vicinitySeg = vseg
  if T.HelpTip then
    T.HelpTip(vseg.frame, "Cross-guild (nearby)", {
      "At the auction house, Midas can also exchange its lightweight sync layer (data manifests and requests - never bulk scan data) with Midas users OUTSIDE your guild, over hidden SAY or YELL addon messages.",
      "Completely invisible to other players. Yell reaches the whole AH building, Say only players right next to you; Off disables it." })
  end

  local syncBtn = T.Button(panel, "Sync now", 100, 22)
  syncBtn:SetPoint("TOPLEFT", X, -152)
  syncBtn:SetScript("OnClick", function() if M.CommSync then M.CommSync() end M.RefreshSettings() end)

  local div = T.Divider(panel)
  div:SetPoint("TOPLEFT", X, -190); div:SetPoint("TOPRIGHT", 0, -190)

  -- status + live log in the LEFT column (monitoring, below the timeframes);
  -- the stats anchor keeps the log below however many import-source lines show
  local sh = T.Text(left, T.SIZE.small, "muted", T.FONT_MED)
  sh:SetPoint("TOPLEFT", 0, -446); sh:SetText("SYNC \194\183 STATUS")
  local stats = T.Text(left, T.SIZE.body, "sub")
  stats:SetPoint("TOPLEFT", 0, -466); stats:SetJustifyH("LEFT"); stats:SetJustifyV("TOP")
  stats:SetWidth(430); stats:SetSpacing(5); stats:SetWordWrap(true)
  s.stats = stats
  -- live log: every entry tagged PUSH (sent by you) / PULL (received or asked
  -- for) / WARN / INFO, oldest first, scrolls with the wheel and follows live
  local ah = T.Text(left, T.SIZE.small, "muted", T.FONT_MED)
  ah:SetPoint("TOPLEFT", stats, "BOTTOMLEFT", 0, -14); ah:SetText("SYNC \194\183 LIVE LOG")
  local lh = T.Text(left, T.SIZE.tiny, "muted", T.FONT_MED)
  lh:SetPoint("LEFT", ah, "RIGHT", 10, 0)
  lh:SetText("PUSH = sent by you  \194\183  PULL = received  \194\183  wheel scrolls")
  local box = T.Surface(left, "bg0", "border")
  box:SetPoint("TOPLEFT", stats, "BOTTOMLEFT", 0, -32)
  box:SetPoint("BOTTOMRIGHT", left, "BOTTOMLEFT", 430, 30)
  local log = CreateFrame("ScrollingMessageFrame", nil, box)
  log:SetPoint("TOPLEFT", 7, -6); log:SetPoint("BOTTOMRIGHT", -7, 6)
  log:SetFont(T.FONT, T.SIZE.tiny, "")
  log:SetJustifyH("LEFT")
  log:SetFading(false)
  log:SetMaxLines(300)
  log:EnableMouseWheel(true)
  log:SetScript("OnMouseWheel", function(self, d)
    if d > 0 then self:ScrollUp() else self:ScrollDown() end
  end)
  s.log = log
  local SYNC_TAG = { push = { "PUSH", C.accent }, pull = { "PULL", C.green }, warn = { "WARN", C.red },
                     info = { "INFO", C.sub } }
  local function syncLine(e)
    local tag = SYNC_TAG[e.dir] or SYNC_TAG.info
    return MUT .. date("%H:%M:%S", e.t) .. "|r  " .. hx(tag[2]) .. tag[1] .. "|r  " .. WHT .. e.text .. "|r"
  end
  function s.refillLog()
    log:Clear()
    local list = M.SyncLog and M.SyncLog() or {}
    for _, e in ipairs(list) do log:AddMessage(syncLine(e)) end
    if #list == 0 then log:AddMessage(MUT .. 'No sync traffic yet - open the AH or click "Sync now".|r') end
    log:ScrollToBottom()
  end
  M.onSyncLog = function(e)
    if panel:IsVisible() then log:AddMessage(syncLine(e)) end
  end
  panel:HookScript("OnShow", function() s.refillLog() end)
  local clearBtn = T.Button(left, "Clear view", 96, 20)
  clearBtn:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, -5)
  clearBtn:SetScript("OnClick", function() log:Clear() end)

  -- ----- FAIR PRICE (right column, under the sync controls) ----------------
  -- recency slider: how fast the market base behind Fair forgets old scan
  -- days. Drag = live demo only; the expensive re-price commits on release.
  -- The demo card grows to the panel bottom, so the graph gets real height.
  local fh = T.Text(panel, T.SIZE.small, "muted", T.FONT_MED)
  fh:SetPoint("TOPLEFT", X, -202); fh:SetText("FAIR PRICE")
  local fsub = T.Text(panel, T.SIZE.tiny, "muted", T.FONT_MED)
  fsub:SetPoint("LEFT", fh, "RIGHT", 10, 0)
  fsub:SetText("how fast Fair follows the market")
  local flabel = T.Text(panel, T.SIZE.small, "sub")
  flabel:SetPoint("TOPLEFT", X, -226); flabel:SetText("Recency bias")
  local fval = T.Text(panel, T.SIZE.small, "accent", T.FONT_SEMI)
  fval:SetPoint("TOPLEFT", X + 404, -226); fval:SetWidth(76); fval:SetJustifyH("RIGHT")
  local fbox = T.Surface(panel)
  fbox:SetPoint("TOPLEFT", X, -262)
  fbox:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 4)
  local fdemo = CreateFrame("Frame", nil, fbox)
  fdemo:SetPoint("TOPLEFT", 8, -8)
  fdemo:SetPoint("BOTTOMRIGHT", -8, 8)
  local fsl = T.Slider(panel, 260, 2, 14, function(v, done)
    fval:SetText("half-life " .. v .. "d")
    if M.RenderFairBiasDemo then M.RenderFairBiasDemo(fdemo, v) end
    if done then
      M.db.config.fairHalflife = (v ~= 7) and v or nil
      if M.DirtyAnalysis then M.DirtyAnalysis() end
      if M.RerenderCharts then M.RerenderCharts() end
      if M.RequestUIRefresh then M.RequestUIRefresh() end
    end
  end)
  fsl:SetPoint("TOPLEFT", X + 130, -224)
  local fr = T.Text(panel, T.SIZE.tiny, "muted")
  fr:SetPoint("TOPLEFT", X + 130, -244); fr:SetText("reactive \194\183 2d")
  local fs2 = T.Text(panel, T.SIZE.tiny, "muted")
  fs2:SetPoint("TOPLEFT", X + 330, -244); fs2:SetWidth(60); fs2:SetJustifyH("RIGHT")
  fs2:SetText("steady \194\183 14d")
  s.fairSl, s.fairVal, s.fairDemo = fsl, fval, fdemo
  if T.HelpTip then
    T.HelpTip(fsl, "Fair recency bias", {
      "How fast the Fair price forgets old scan days: the market base behind Fair weighs each scan day by 0.5^(age/half-life).",
      "SHORT half-life (2-4 days): Fair chases the latest days - reacts fast, jumpy on thin items. LONG (10-14 days): Fair smooths over the whole two-week window and shrugs off short dips.",
      "Default 7 days. The graph below shows a market that dropped from 12g to 8g a week before today - drag and watch the base line change character. Changing it re-prices everything (Fair, signals, net-worth valuation); scanned history stays untouched." })
  end

  -- keep it live while the tab is on screen (panels only OnUpdate while shown)
  panel:SetScript("OnUpdate", function(self, el)
    self._acc = (self._acc or 0) + el
    if self._acc >= 1 then self._acc = 0 if M.RefreshSettings then M.RefreshSettings() end end
  end)
end

function M.RefreshSettings()
  local s = M.setUI
  if not s then return end
  if s.left then
    -- the log box grows with the window; below SET_LEFT_H the column scrolls
    local vis = ((M.frame and M.frame:GetHeight()) or 560) - 134
    s.left:SetHeight(math.max(SET_LEFT_H, math.floor(vis)))
  end
  local cfg = M.db.config
  local mode = cfg.tooltipMode or "full"
  s.tipSeg:Select(mode)
  s.setPreview(mode)
  if s.tcCb then s.tcCb:SetChecked(cfg.tooltipCraft ~= false) end
  s.mmCb:SetChecked(not cfg.minimapHide)
  s.autoCb:SetChecked(cfg.autoScan == true)
  if s.ahCb then s.ahCb:SetChecked(cfg.ahBook ~= false) end
  if s.swCb then s.swCb:SetChecked(cfg.starterWatch ~= false) end
  if s.alCb then s.alCb:SetChecked(cfg.alertLines ~= false) end
  if s.sdCb then s.sdCb:SetChecked(cfg.sellDock ~= false) end
  if s.mcCb then s.mcCb:SetChecked(cfg.modClicks ~= false) end
  if s.owCb then s.owCb:SetChecked(cfg.openWithAH == true) end
  if s.lgCb then s.lgCb:SetChecked(cfg.ledgerOff ~= true) end
  if s.crCb then s.crCb:SetChecked(cfg.craftOff ~= true) end
  s.cb:SetChecked(cfg.share == true)
  s.trustSeg:Select(cfg.shareTrust == "guild" and "guild" or "all")
  if s.prevSeg then s.prevSeg:Select(cfg.previewRange or "all") end
  if s.ttSeg then s.ttSeg:Select(cfg.tooltipRange or "30") end
  if s.vicinitySeg then s.vicinitySeg:Select(cfg.vicinity or "off") end
  -- fair recency slider: never fight an active drag (this runs on a 1s ticker);
  -- redraw the demo when the value or the panel height changed
  if s.fairSl and not s.fairSl.dragging then
    local hl = (M.FairHalflife and M.FairHalflife()) or 7
    s.fairSl:Set(hl)
    s.fairVal:SetText("half-life " .. hl .. "d")
    local hh = math.floor((s.fairDemo and s.fairDemo:GetHeight()) or 0)
    if (s._fairHl ~= hl or s._fairH ~= hh) and M.RenderFairBiasDemo then
      s._fairHl, s._fairH = hl, hh
      M.RenderFairBiasDemo(s.fairDemo, hl)
    end
  end
  local info = M.CommInfo and M.CommInfo()
  if not info then s.stats:SetText("Comm module not loaded.") return end
  local GRN, RED, WHT, MUT, GOLD, MINT = s.GRN, s.RED, s.WHT, s.MUT, s.GOLD, s.MINT
  local statusCol = info.share and (GRN .. "ON|r") or (RED .. "OFF|r")
  local guildCol = info.guild and "" or ("   " .. RED .. "not in a guild|r - group and nearby only")
  local vic = info.vicinity or "off"
  local vicTxt = (vic == "off") and (MUT .. "off|r")
    or (WHT .. vic .. "|r  (AH " .. (info.ahOpen and (GRN .. "open|r") or (MUT .. "closed|r")) .. ")")
  -- who is online, newest contact first, with the Midas version they run
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
    "Received  " .. MINT .. info.rxRows .. "|r prices  (" .. info.rxMsgs .. " msgs)   \194\183   sent  "
      .. GOLD .. info.txRows .. "|r prices  (" .. info.txMsgs .. " msgs)",
    "Queue  " .. WHT .. math.max(0, info.queue) .. "|r" .. ((thr > 0) and ("   \194\183   throttled  " .. GOLD .. thr .. "|r") or ""),
  }
  if info.newer then
    sl[#sl + 1] = GOLD .. "Midas " .. info.newer .. " is out - players you sync with run it already.|r"
  end
  -- last import from other addons' price databases (Import.lua), per source
  local imp = cfg.impSrc
  if imp then
    local rk = M.RealmKey()
    for srcName, per in pairs(imp) do
      local rec = per and per[rk]
      if rec and rec.at then
        sl[#sl + 1] = " "
        sl[#sl + 1] = srcName .. " import:  " .. WHT .. (rec.items or 0) .. " items / "
          .. (rec.rows or 0) .. " rows|r   (" .. date("%b %d  %H:%M", rec.at) .. ")"
      end
    end
  end
  s.stats:SetText(table.concat(sl, "\n"))
end


-- ===== Ranked table (Watchlist) =============================================
local CH_COLS = {
  { name = "Item", w = 160, just = "LEFT", sort = "name" },
  { name = "Category", w = 110, just = "LEFT", sort = "category" },
  { name = "Today", w = 64, just = "CENTER", sort = "today" },
  { name = "Current", w = 64, just = "RIGHT", sort = "cur" },
  { name = "Fair", w = 60, just = "RIGHT", sort = "fair" },
  { name = "vs Fair", w = 54, just = "RIGHT", sort = "delta" },
  { name = "Qty", w = 40, just = "RIGHT", sort = "avgQty" },
  { name = "Days", w = 32, just = "RIGHT", sort = "days" },
  { name = "Score", w = 46, just = "RIGHT", sort = "score" },
}
local CH_ROWS, CH_ROWH = 20, 18

-- Column header explanations (shown on hover) -------------------------------
local COL_HELP = {
  delta  = { "% over / under Fair", "Current price relative to the Fair price. Same basis as the Today signal (threshold +/-15%).\n\n|cff5BD178Below (green)|r = cheaper than fair, a buy.\n|cffF0635AAbove (red)|r = pricier than fair, a sell." },
  cur    = { "Current price", "What the item costs right now.\n\n|cff5BD178Green|r = at/below your buy target (25th percentile), cheap.\n|cffF0635ARed|r = at/above your sell target (75th percentile), pricey.\nWhite = in between." },
  fair   = { "Fair price", T.HelpText("fair") },
  margin = { "Flip margin", "sell / buy - 1: what you'd make flipping it (capped at 150% inside the score)." },
  avgQty = { "Avg quantity", "Average number listed in the AH per day - a liquidity proxy. More supply usually means it sells faster (higher sell-through)." },
  days   = { "Days of data", "How many scan days are recorded. More days = more reliable numbers." },
  score  = { "Opportunity score", T.HelpText("score") },
  name     = { "Item", "Click to sort by name (A-Z, click again Z-A)." },
  category = { "Category", "Item class / subclass. Click to sort alphabetically." },
  today    = { "Today's call", "BUY / NEUTRAL / SELL from current price vs Fair (threshold +/-15%). Click to sort." },
}

-- Today's recommendation from the latest price vs Fair (Top-Picks logic).
local function todaySignal(m)
  if not m or not m.delta then return nil end
  if M.NotListed and M.NotListed(m) then return "NOT LISTED", C.muted end
  if m.delta <= -M.C.PICK_DELTA then return "BUY", C.green
  elseif m.delta >= M.C.PICK_DELTA then return "SELL", C.red end
  return "NEUTRAL", C.sub
end

-- Sort value for a ranked row: strings for name/category, numbers otherwise.
-- Strings are memoized on the entry: with the browse view the comparator runs
-- O(n log n) times over thousands of rows, and ItemName/ItemCategory + :lower()
-- per COMPARISON would hammer the GC.
local function rankSortVal(e, fld)
  if fld == "name" then
    e._nm = e._nm or M.ItemName(e.key):lower()
    return e._nm
  end
  if fld == "category" then
    e._ct = e._ct or (M.ItemCategory(e.key) or ""):lower()
    return e._ct
  end
  if fld == "today" then return e.m and e.m.delta end
  return e.m and e.m[fld]
end

-- name prompt for watchlist groups (create and rename share it)
StaticPopupDialogs["MIDAS_WATCH_GROUP"] = {
  text = "%s", button1 = OKAY, button2 = CANCEL,
  hasEditBox = true, maxLetters = 24,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  OnShow = function(self)
    local eb = self.editBox or self.EditBox
    if eb then eb:SetText((self.data and self.data.prefill) or ""); eb:HighlightText(); eb:SetFocus() end
  end,
  OnAccept = function(self)
    local eb = self.editBox or self.EditBox
    if self.data and self.data.cb then self.data.cb(eb and eb:GetText()) end
  end,
  EditBoxOnEnterPressed = function(self)
    local p = self:GetParent()
    if p.data and p.data.cb then p.data.cb(self:GetText()) end
    p:Hide()
  end,
  EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
}

-- small label that follows the cursor while a watchlist row is dragged
local dragGhost
local function dragGhostShow(txt)
  if not dragGhost then
    dragGhost = CreateFrame("Frame", nil, UIParent)
    dragGhost:SetFrameStrata("TOOLTIP")
    dragGhost:SetSize(10, 14)
    dragGhost.fs = T.Text(dragGhost, T.SIZE.small, "text", T.FONT_MED)
    dragGhost.fs:SetPoint("LEFT")
    dragGhost:SetScript("OnUpdate", function(self)
      local x, y = GetCursorPosition()
      local s = UIParent:GetEffectiveScale()
      self:ClearAllPoints()
      self:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / s + 14, y / s - 8)
    end)
  end
  dragGhost.fs:SetText(txt or "")
  dragGhost:Show()
end
local function dragGhostHide() if dragGhost then dragGhost:Hide() end end

-- Builds a search + sortable table + detail card on the panel; returns its state.
local function CreateRankTab(panel, opts)
  -- opts.persistKey: the chosen column sort survives reloads (config slot)
  local saved = opts.persistKey and M.db and M.db.config and M.db.config[opts.persistKey]
  local st = { search = "", sort = { field = saved and saved.f or "score",
                                     asc = saved and saved.asc or false } }
  -- with groups, a permanent chip row sits between the search and the headers
  local TOP_OFF = opts.groups and 20 or 0
  vline(panel, 696)

  local search = T.Input(panel, opts.groups and 240 or 300, 22, opts.placeholder, function(txt)
    st.search = (txt or ""):lower()
    -- debounce: in the browse view one keystroke re-filters thousands of rows
    if st._qTimer then st._qTimer:Cancel() end
    st._qTimer = C_Timer.NewTimer(0.12, function() st._qTimer = nil; st.Refresh() end)
  end)
  search:SetPoint("TOPLEFT", 0, -2)
  local grpBtn
  if opts.groups then
    grpBtn = T.Button(panel, "+ group", 64, 22)
    grpBtn:SetPoint("LEFT", search, "RIGHT", 8, 0)
    grpBtn:SetScript("OnClick", function()
      StaticPopup_Show("MIDAS_WATCH_GROUP", "New watchlist group:", nil, {
        cb = function(txt)
          if M.WatchGroupAdd and M.WatchGroupAdd(txt) then
            st.showAll, st.showRemoved = nil, nil
            st.Refresh()
          end
        end })
    end)
    if T.HelpTip then
      T.HelpTip(grpBtn, "Watchlist groups", {
        "Creates a named section in the watchlist. Drag a row onto a group chip (above the table), a group header or one of its items to file it there; drop it on UNGROUPED to file it out.",
        "Clicking a chip filters the list to that group (click again for all). Click a header to fold the group, right-click renames it, shift-click deletes it - the items always stay on the list." })
    end
  end
  local count = T.Text(panel, T.SIZE.small, "muted")
  count:SetPoint("LEFT", grpBtn or search, "RIGHT", 12, 0)

  -- Watchlist only: mini tab to view (and re-add) recently removed items
  if opts.recentTab then
    local tg = CreateFrame("Button", nil, panel)
    tg:SetSize(160, 16); tg:SetPoint("LEFT", count, "RIGHT", 16, 0)
    local tf = tg:CreateFontString(nil, "OVERLAY"); T.RegFont(tf, T.FONT_MED, T.SIZE.small)
    tf:SetPoint("LEFT", 0, 0); tf:SetJustifyH("LEFT"); tf:SetTextColor(T.Unpack(C.sub))
    tg.tf = tf
    tg:SetScript("OnClick", function()
      if M.alertsView then M.alertsView:Hide() end
      st.showRemoved = not st.showRemoved; st.Refresh()
    end)
    tg:SetScript("OnEnter", function() tf:SetTextColor(T.Unpack(C.text)) end)
    tg:SetScript("OnLeave", function()
      if st.showRemoved then tf:SetTextColor(T.Unpack(C.accent)) else tf:SetTextColor(T.Unpack(C.sub)) end
    end)
    st.toggle = tg
    if T.HelpTip then
      T.HelpTip(tg, "Recently removed", {
        "Switches to the watchlist items you removed most recently - click one there to re-add it, click the toggle again to return." })
    end
  end

  -- Watchlist only: browse the WHOLE archive in the same table ("all items")
  if opts.browseTab then
    local bg2 = CreateFrame("Button", nil, panel)
    bg2:SetSize(136, 16); bg2:SetPoint("TOPLEFT", 554, -5)
    local bf = bg2:CreateFontString(nil, "OVERLAY"); T.RegFont(bf, T.FONT_MED, T.SIZE.small)
    bf:SetPoint("RIGHT", 0, 0); bf:SetJustifyH("RIGHT"); bf:SetTextColor(T.Unpack(C.sub))
    bg2.tf = bf
    bg2:SetScript("OnClick", function()
      if M.alertsView then M.alertsView:Hide() end
      st.showAll = not st.showAll
      st.showRemoved = nil
      st.Refresh()
    end)
    bg2:SetScript("OnEnter", function() bf:SetTextColor(T.Unpack(C.text)) end)
    bg2:SetScript("OnLeave", function()
      if st.showAll then bf:SetTextColor(T.Unpack(C.accent)) else bf:SetTextColor(T.Unpack(C.sub)) end
    end)
    st.browseToggle = bg2
    if T.HelpTip then
      T.HelpTip(bg2, "All items", {
        "Switches the table to EVERY item your scans and syncs have touched on this realm - not just your watchlist.",
        "Sort by any column, search as usual; a gold edge marks items already on your watchlist, right-click adds or removes one. Items below the ranking gate (too few days or too little supply) show price and supply only." })
    end

    -- third sub-view: this realm's price alerts with their CURRENT prices.
    -- A plain overlay above the table (alerts are few - no scroll, no sort);
    -- every row is a live item button: click = the chart, where limits live.
    local av = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    av:SetPoint("TOPLEFT", 0, -24); av:SetPoint("BOTTOMRIGHT", 0, 0)
    av:SetBackdrop(T.FLAT)
    av:SetBackdropColor(C.bg1[1], C.bg1[2], C.bg1[3], 1)
    av:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1)
    av:SetFrameLevel(panel:GetFrameLevel() + 30)
    av:Hide()
    M.alertsView = av
    local avTitle = T.Text(av, T.SIZE.small, "muted", T.FONT_MED)
    avTitle:SetPoint("TOPLEFT", 12, -10)
    local avHint = T.Text(av, T.SIZE.tiny, "muted")
    avHint:SetPoint("TOPRIGHT", -12, -12); avHint:SetJustifyH("RIGHT")
    avHint:SetText("click a row for its chart \194\183 limits are set there (below / above)")
    local AV_COLS = {
      { x = 12,  w = 230, j = "LEFT",  t = "ITEM" },
      { x = 250, w = 90,  j = "RIGHT", t = "BELOW" },
      { x = 348, w = 90,  j = "RIGHT", t = "CURRENT" },
      { x = 446, w = 90,  j = "RIGHT", t = "ABOVE" },
      { x = 544, w = 70,  j = "RIGHT", t = "VS FAIR" },
    }
    for _, c2 in ipairs(AV_COLS) do
      local hc = T.Text(av, T.SIZE.tiny, "muted", T.FONT_MED)
      hc:SetPoint("TOPLEFT", c2.x, -32); hc:SetWidth(c2.w); hc:SetJustifyH(c2.j); hc:SetText(c2.t)
    end
    av.rows = {}
    for r2 = 1, 14 do
      local b = CreateFrame("Button", nil, av)
      b:SetPoint("TOPLEFT", 8, -46 - (r2 - 1) * 22); b:SetSize(630, 21)
      b:SetFrameLevel(av:GetFrameLevel() + 2)
      local zb = b:CreateTexture(nil, "BACKGROUND")
      zb:SetAllPoints(); zb:SetColorTexture(1, 1, 1, 0.03); zb:SetShown(r2 % 2 == 0)
      local hl3 = b:CreateTexture(nil, "HIGHLIGHT"); hl3:SetAllPoints(); hl3:SetColorTexture(1, 1, 1, 0.05)
      local c3 = {}
      for i2, d in ipairs(AV_COLS) do
        c3[i2] = cell(b, d.x - 8, -4, d.w, d.j, T.SIZE.body)
      end
      b.c = c3
      wireItemBtn(b)
      b:Hide()
      av.rows[r2] = b
    end
    av.more = T.Text(av, T.SIZE.tiny, "muted")
    av.more:SetPoint("BOTTOMLEFT", 12, 10)
    av.empty = T.Text(av, T.SIZE.body, "sub")
    av.empty:SetPoint("CENTER", 0, 20); av.empty:SetWidth(520)
    av.empty:SetJustifyH("CENTER"); av.empty:SetWordWrap(true); av.empty:SetSpacing(4)
    av.empty:SetText("No price alerts on this realm yet.\nOpen an item in the Charts tab and set a below and/or above limit - Midas rings when a scan or sync crosses it.")
    local function fillAlerts()
      local realm = M.RealmKey()
      local al = M.db and M.db.alerts and M.db.alerts[realm]
      local list = {}
      if al then
        for key, a in pairs(al) do
          if type(a) == "table" and (a.below or a.above) then
            local m2 = M.Metrics(M.GetSeries(key) or {}, key)
            local cur2 = (m2 and m2.cur and m2.cur > 0) and m2.cur or nil
            local hit = (cur2 and ((a.below and cur2 <= a.below) or (a.above and cur2 >= a.above))) and true or false
            list[#list + 1] = { key = key, below = a.below, above = a.above,
                                cur = cur2, fair = m2 and m2.fair, hit = hit }
          end
        end
      end
      table.sort(list, function(x, y)
        if x.hit ~= y.hit then return x.hit end
        return (M.ItemName(x.key) or tostring(x.key)) < (M.ItemName(y.key) or tostring(y.key))
      end)
      avTitle:SetText("PRICE ALERTS  \194\183  " .. realm .. "  \194\183  " .. #list .. " active")
      for r2 = 1, #av.rows do
        local e, b = list[r2], av.rows[r2]
        if e then
          setItemName(b.c[1], e.key)
          b.c[2]:SetText(e.below and M.MoneyPlain(e.below) or "\226\128\147")
          colorize(b.c[2], e.below and C.green or C.muted)
          b.c[3]:SetText(e.cur and M.MoneyPlain(e.cur) or "no data")
          if e.cur and e.below and e.cur <= e.below then colorize(b.c[3], C.green)
          elseif e.cur and e.above and e.cur >= e.above then colorize(b.c[3], C.accent)
          else colorize(b.c[3], e.cur and C.text or C.muted) end
          b.c[4]:SetText(e.above and M.MoneyPlain(e.above) or "\226\128\147")
          colorize(b.c[4], e.above and C.accent or C.muted)
          if e.cur and e.fair and e.fair > 0 then
            local d2 = e.cur / e.fair - 1
            b.c[5]:SetText(string.format("%+.0f%%", d2 * 100))
            colorize(b.c[5], d2 < 0 and C.green or C.red)
          else b.c[5]:SetText("") end
          b.key = e.key
          b:Show()
        else
          b.key = nil; b:Hide()
        end
      end
      av.more:SetText(#list > #av.rows and ("+" .. (#list - #av.rows) .. " more alerts") or "")
      av.empty:SetShown(#list == 0)
    end
    av:SetScript("OnShow", fillAlerts)
    local ag = CreateFrame("Button", nil, panel)
    ag:SetSize(110, 16); ag:SetPoint("TOPRIGHT", -8, -5)
    local af = ag:CreateFontString(nil, "OVERLAY"); T.RegFont(af, T.FONT_MED, T.SIZE.small)
    af:SetPoint("RIGHT", 0, 0); af:SetJustifyH("RIGHT")
    local function agLabel()
      if av:IsShown() then af:SetText("< back"); af:SetTextColor(T.Unpack(C.accent))
      else af:SetText("price alerts \194\187"); af:SetTextColor(T.Unpack(C.sub)) end
    end
    ag:SetScript("OnClick", function() av:SetShown(not av:IsShown()) end)
    ag:SetScript("OnEnter", function() af:SetTextColor(T.Unpack(C.text)) end)
    ag:SetScript("OnLeave", agLabel)
    av:HookScript("OnShow", agLabel)
    av:HookScript("OnHide", agLabel)
    agLabel()
    -- the Start page's "all alerts" link lands here
    M.OpenAlerts = function()
      M.SelectTab(TAB.Watchlist)
      av:Show()
    end
    if T.HelpTip then
      T.HelpTip(ag, "Price alerts", {
        "All below/above price alerts of this realm with their CURRENT prices - the price turns green once it is at or under your buy limit, gold once it reached your sell limit.",
        "Click a row to open the item's chart (alerts are set and cleared there)." })
    end
  end

  local headers = {}
  local hx = 0
  for _, d in ipairs(CH_COLS) do
    if d.sort then
      local b = CreateFrame("Button", nil, panel)
      b:SetSize(d.w, 16); b:SetPoint("TOPLEFT", hx, -32 - TOP_OFF)
      local tt = b:CreateFontString(nil, "OVERLAY")
      T.RegFont(tt, T.FONT_MED, T.SIZE.tiny); tt:SetAllPoints(); tt:SetJustifyH(d.just)
      tt:SetText(d.name:upper()); tt:SetTextColor(T.Unpack(C.muted))
      b.tt, b.field = tt, d.sort
      b:SetScript("OnClick", function()
        if st.sort.field == d.sort then st.sort.asc = not st.sort.asc
        else st.sort.field = d.sort; st.sort.asc = (d.sort == "name" or d.sort == "category") end
        if opts.persistKey and M.db and M.db.config then
          M.db.config[opts.persistKey] = { f = st.sort.field, asc = st.sort.asc }
        end
        st.Refresh()
      end)
      b:SetScript("OnEnter", function()
        if st.sort.field ~= d.sort then tt:SetTextColor(T.Unpack(C.sub)) end
        local h = COL_HELP[d.sort]
        if h then
          GameTooltip:SetOwner(b, "ANCHOR_TOP")   -- above the header, so it never covers the rows
          GameTooltip:SetMinimumWidth(300)        -- uniform wrap width; texts are whole paragraphs
          GameTooltip:SetText(h[1], 1, 1, 1)
          GameTooltip:AddLine(h[2], 0.82, 0.85, 0.92, true)
          GameTooltip:Show()
        end
      end)
      b:SetScript("OnLeave", function()
        if st.sort.field ~= d.sort then tt:SetTextColor(T.Unpack(C.muted)) end
        GameTooltip:SetMinimumWidth(0)
        GameTooltip:Hide()
      end)
      headers[#headers + 1] = b
    else
      local tt = cell(panel, hx, -32 - TOP_OFF, d.w, d.just, T.SIZE.tiny, "muted", T.FONT_MED)
      tt:SetText(d.name:upper())
    end
    hx = hx + d.w + 4
  end

  local scroll = CreateFrame("ScrollFrame", opts.scrollName, panel, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, -50 - TOP_OFF)
  scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMLEFT", 690, 0)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, CH_ROWH, st.Refresh)
  end)
  local function onWheel(_, delta)
    local sb = _G[opts.scrollName .. "ScrollBar"]
    if sb then sb:SetValue(sb:GetValue() - delta * CH_ROWH * 2) end
  end
  scroll:EnableMouseWheel(true); scroll:SetScript("OnMouseWheel", onWheel)
  T.StyleScrollbar(opts.scrollName)

  local card = CreateChartCard(panel, 702, 250, 420)

  -- permanent group-chip row between the search and the column headers
  -- (watchlist views only): click a chip to FILTER the list to that group
  -- (click again to clear), drag a row onto one to FILE it there. UNGROUPED
  -- filters/files the rest. Hidden in the browse and removed views.
  local chipBar, updateChips
  if opts.groups then
    chipBar = CreateFrame("Frame", nil, panel)
    chipBar:SetPoint("TOPLEFT", 0, -26)
    chipBar:SetPoint("TOPRIGHT", panel, "TOPLEFT", 690, -26)
    chipBar:SetHeight(20)
    chipBar.chips = {}
    chipBar.empty = T.Text(chipBar, T.SIZE.tiny, "muted")
    chipBar.empty:SetPoint("LEFT", 0, 0)
    chipBar.empty:SetText("no groups yet \226\128\148 \"+ group\" creates one")
    -- right edge of the chip row: fold or unfold every section at once
    chipBar.foldAll = CreateFrame("Button", nil, chipBar)
    chipBar.foldAll:SetSize(90, 20); chipBar.foldAll:SetPoint("TOPRIGHT", 0, 0)
    chipBar.foldAll.fs = T.Text(chipBar.foldAll, T.SIZE.small, "sub", T.FONT_MED)
    chipBar.foldAll.fs:SetPoint("RIGHT", 0, 0); chipBar.foldAll.fs:SetJustifyH("RIGHT")
    chipBar.foldAll:SetScript("OnEnter", function(fa) fa.fs:SetTextColor(T.Unpack(C.text)) end)
    chipBar.foldAll:SetScript("OnLeave", function(fa) fa.fs:SetTextColor(T.Unpack(C.sub)) end)
    chipBar.foldAll:SetScript("OnClick", function()
      local cfg = M.db.config
      cfg.watchGroupFold = cfg.watchGroupFold or {}
      local fold = cfg.watchGroupFold
      local groups = (M.WatchGroups and M.WatchGroups()) or {}
      local anyOpen = not fold["~rest"]
      if not anyOpen then
        for _, g in ipairs(groups) do if not fold[g] then anyOpen = true; break end end
      end
      if anyOpen then
        for _, g in ipairs(groups) do fold[g] = true end
        fold["~rest"] = true
      else
        for k in pairs(fold) do fold[k] = nil end
      end
      st.Refresh()
    end)
    updateChips = function(visible)
      if not visible then chipBar:Hide(); return end
      local groups = (M.WatchGroups and M.WatchGroups()) or {}
      local x = 0
      local function chip(i, label, group, fkey)
        local c = chipBar.chips[i]
        if not c then
          c = CreateFrame("Button", nil, chipBar)
          c:SetHeight(20)
          c.bg = c:CreateTexture(nil, "BORDER")
          c.bg:SetAllPoints()
          c.fs = T.Text(c, T.SIZE.small, "text", T.FONT_MED)
          c.fs:SetPoint("CENTER")
          c:SetScript("OnClick", function()
            st.groupFilter = (st.groupFilter ~= c.fkey) and c.fkey or nil
            st.Refresh()
          end)
          chipBar.chips[i] = c
        end
        c.group, c.fkey = group, fkey
        local active = (st.groupFilter == fkey)
        c.bg:SetColorTexture(C.sub[1], C.sub[2], C.sub[3], active and 0.38 or 0.16)
        c.fs:SetText(label)
        if active then c.fs:SetTextColor(T.Unpack(C.text))
        elseif group then c.fs:SetTextColor(T.Unpack(C.accent))
        else c.fs:SetTextColor(T.Unpack(C.sub)) end
        c:SetWidth((c.fs:GetStringWidth() or 40) + 18)
        c:ClearAllPoints(); c:SetPoint("TOPLEFT", x, 0)
        x = x + c:GetWidth() + 6
        c:Show()
      end
      local i = 0
      for _, g in ipairs(groups) do i = i + 1; chip(i, g, g, g) end
      if groups[1] then i = i + 1; chip(i, "UNGROUPED", nil, "~rest") end
      for j = i + 1, #chipBar.chips do chipBar.chips[j]:Hide() end
      chipBar.empty:SetShown(i == 0)
      local fold = (M.db.config and M.db.config.watchGroupFold) or {}
      local anyOpen = not fold["~rest"]
      if not anyOpen then
        for _, g in ipairs(groups) do if not fold[g] then anyOpen = true; break end end
      end
      chipBar.foldAll.fs:SetText(anyOpen and "collapse all" or "expand all")
      chipBar.foldAll:SetShown(groups[1] ~= nil)
      chipBar:Show()
    end
  end

  local rows = {}
  local function mkRow(r)
    local btn = CreateFrame("Button", nil, panel)
    btn:SetSize(672, CH_ROWH); btn:SetPoint("TOPLEFT", 0, -50 - TOP_OFF - (r - 1) * CH_ROWH)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local zb = btn:CreateTexture(nil, "BACKGROUND"); zb:SetAllPoints(); zb:SetColorTexture(1, 1, 1, 0.02); zb:Hide()
    btn.zb = zb
    -- browse view: a slim gold edge marks items already on the watchlist
    local wb = btn:CreateTexture(nil, "BORDER")
    wb:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.7)
    wb:SetPoint("TOPLEFT", -6, -2); wb:SetSize(2, CH_ROWH - 4); wb:Hide()
    btn.wb = wb
    local hl = btn:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.05)
    local fs, cx = {}, 0
    for i, d in ipairs(CH_COLS) do fs[i] = cell(btn, cx, -3, d.w, d.just, T.SIZE.body); cx = cx + d.w + 4 end
    btn.fs = fs
    btn:EnableMouseWheel(true); btn:SetScript("OnMouseWheel", onWheel)
    btn:SetScript("OnEnter", function() if btn.key then M.FillChartCard(card, btn.key); ShowItemTip(btn.key) end end)
    btn:SetScript("OnLeave", HideTip)
    btn:SetScript("OnClick", function(_, mouse)
      if btn.isAddGroup then
        StaticPopup_Show("MIDAS_WATCH_GROUP", "New watchlist group:", nil, {
          cb = function(txt)
            if M.WatchGroupAdd and M.WatchGroupAdd(txt) then st.Refresh() end
          end })
        return
      end
      if btn.isHeader then
        if mouse == "RightButton" and btn.group then
          local old = btn.group
          StaticPopup_Show("MIDAS_WATCH_GROUP", "Rename group:", nil, {
            prefill = old,
            cb = function(txt)
              if M.WatchGroupRename and M.WatchGroupRename(old, txt) then st.Refresh() end
            end })
        elseif IsShiftKeyDown() and btn.group then
          if M.WatchGroupDelete and M.WatchGroupDelete(btn.group) then
            M.Print("Watchlist group removed - its items stay on the list.")
            st.Refresh()
          end
        else
          local cfg2 = M.db.config
          cfg2.watchGroupFold = cfg2.watchGroupFold or {}
          cfg2.watchGroupFold[btn.foldKey] = not cfg2.watchGroupFold[btn.foldKey] or nil
          st.Refresh()
        end
        return
      end
      if not btn.key then return end
      if M.ModPostDown() then M.PostItemStats(btn.key); return end
      if M.ModSearchDown() then M.ItemShiftAction(btn.key); return end
      if mouse == "RightButton" then M.ToggleWatch(btn.key); st.Refresh()
      elseif btn.addable then M.ToggleWatch(btn.key); st.Refresh()
      else GoChart(btn.key) end
    end)
    -- drag a watchlist row onto a group header, one of its rows, or a drop
    -- chip (the chips appear while dragging - the search view has no headers).
    -- Dragging a "+ item" search result adds it to the list on the way in.
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function()
      if not opts.groups or not btn.key or st.showAll or st.showRemoved then return end
      st._dragKey, st._dragAdd = btn.key, btn.addable
      dragGhostShow(M.ItemName(btn.key))
    end)
    btn:SetScript("OnDragStop", function()
      dragGhostHide()
      local key, wasAdd = st._dragKey, st._dragAdd
      st._dragKey, st._dragAdd = nil, nil
      local hitChip, chipGroup = false, nil
      if chipBar and chipBar:IsShown() then
        for _, c in ipairs(chipBar.chips) do
          if c:IsShown() and c:IsMouseOver() then hitChip = true; chipGroup = c.group; break end
        end
      end
      if not key then return end
      local function file(target)
        if wasAdd and M.IsWatched and not M.IsWatched(key) then M.ToggleWatch(key) end
        if M.WatchGroupSet then M.WatchGroupSet(key, target) end
        st.Refresh()
      end
      if hitChip then file(chipGroup); return end
      for _, b in ipairs(rows) do
        if b:IsShown() and b:IsMouseOver() then
          if b.isAddGroup then return
          elseif b.isHeader then file(b.group)   -- nil on UNGROUPED = file out
          elseif b.key then
            file(M.db.config.watchGroupOf and M.db.config.watchGroupOf[b.key])
          end
          return
        end
      end
    end)
    rows[r] = btn
  end
  for r = 1, CH_ROWS do mkRow(r) end

  function st.Refresh()
    local q = (st.search ~= "" and st.search) or nil
    local removedView = opts.recentTab and st.showRemoved
    local browseView = opts.browseTab and st.showAll and not removedView
    local data
    if removedView then
      data = {}
      for _, key in ipairs(M.RecentlyRemoved and M.RecentlyRemoved() or {}) do
        local series = M.GetSeries(key)
        data[#data + 1] = { key = key, m = series and M.Metrics(series, key) or nil, addable = true }
      end
    elseif browseView then
      data = (M.BrowseAll and M.BrowseAll()) or {}
    else
      data = opts.dataFn()
    end
    -- group-chip filter (watchlist views only); clear it if its group is gone
    local gFilter
    if opts.groups and not removedView and not browseView and st.groupFilter then
      gFilter = st.groupFilter
      if gFilter ~= "~rest" then
        local found = false
        for _, g in ipairs((M.WatchGroups and M.WatchGroups()) or {}) do
          if g == gFilter then found = true; break end
        end
        if not found then st.groupFilter, gFilter = nil, nil end
      end
    end
    local fld, asc = st.sort.field, st.sort.asc
    -- browse view: filtering + sorting thousands of rows is the expensive part,
    -- and FauxScrollFrame re-runs Refresh on EVERY scroll tick - so the built
    -- view is cached and reused until the data table (a new analysis build),
    -- the query or the sort changes. The watchlist path stays uncached (its
    -- dataFn returns a fresh table each call, and 200 rows sort instantly).
    local sorted
    local bc = browseView and st._bCache
    if bc and bc.src == data and bc.q == q and bc.fld == fld and bc.asc == asc then
      sorted = bc.view
    else
      sorted = {}
      local gOf = gFilter and ((M.db.config and M.db.config.watchGroupOf) or {})
      for i = 1, #data do
        local e = data[i]
        local keep = not q or rankSortVal(e, "name"):find(q, 1, true) or rankSortVal(e, "category"):find(q, 1, true)
        if keep and gFilter then
          local g = gOf[e.key]
          keep = (gFilter == "~rest" and g == nil) or g == gFilter
        end
        if keep then sorted[#sorted + 1] = e end
      end
      table.sort(sorted, function(a, b)
        local av, bv = rankSortVal(a, fld), rankSortVal(b, fld)
        if type(av) == "string" or type(bv) == "string" then
          av = av or ""; bv = bv or ""
          if av ~= bv then if asc then return av < bv else return av > bv end end
        else
          -- rows WITHOUT a value in this column always sort last (asc or
          -- desc), so the browse view's unrated items stop flooding one end
          if (av == nil) ~= (bv == nil) then return bv == nil end
          if av ~= nil and av ~= bv then if asc then return av < bv else return av > bv end end
        end
        local as = (a.m and a.m.score) or -math.huge
        local bs = (b.m and b.m.score) or -math.huge
        if as ~= bs then return as > bs end
        -- final tiebreaker by name: table.sort is NOT stable, so equal rows
        -- would reshuffle on every refresh (each scan/sync) without this
        return rankSortVal(a, "name") < rankSortVal(b, "name")
      end)
      if browseView then
        st._bCache = { src = data, q = q, fld = fld, asc = asc, view = sorted }
      end
    end
    -- Watchlist: let the search also surface items not yet watched, to add them.
    -- Collect matches CHEAPLY first (name/category + one quick pass) -- running the
    -- full v3 Metrics for every match of a short query in one frame trips WoW's
    -- "script ran too long" watchdog on a large archive. Pre-rank by market supply,
    -- then price only the top few (memoized in Logic.lua).
    if opts.addSearch and not removedView and not browseView and q and #q >= 2 then
      local seen = {}
      for _, e in ipairs(sorted) do seen[e.key] = true end
      local cand = {}
      for key, series in pairs(M.IterItems()) do
        if not seen[key] and not M.IsWatched(key)
           and (M.ItemName(key):lower():find(q, 1, true) or M.ItemCategory(key):lower():find(q, 1, true)) then
          local _, _, avgQty = M.QuickScan(series)
          cand[#cand + 1] = { key = key, aq = avgQty }
        end
      end
      table.sort(cand, function(a, b) return a.aq > b.aq end)
      local extra = {}
      for i = 1, math.min(#cand, 40) do
        local key = cand[i].key
        extra[#extra + 1] = { key = key, m = M.Metrics(M.GetSeries(key), key), addable = true }
      end
      table.sort(extra, function(a, b) return ((a.m and a.m.score) or 0) > ((b.m and b.m.score) or 0) end)
      for i = 1, math.min(#extra, 15) do sorted[#sorted + 1] = extra[i] end
    end
    -- watchlist groups: the plain view folds into ordered sections (own groups
    -- first, the rest under UNGROUPED); searching shows the flat list. "+ new
    -- group" is the last row either way, so the entry point is always visible.
    local nItems = #sorted
    if opts.groups and not q and not removedView and not browseView then
      local groups = (M.WatchGroups and M.WatchGroups()) or {}
      if groups[1] then
        local isGroup = {}
        for _, g in ipairs(groups) do isGroup[g] = true end
        local of = (M.db.config and M.db.config.watchGroupOf) or {}
        local fold = (M.db.config and M.db.config.watchGroupFold) or {}
        local byG, rest = {}, {}
        for _, e in ipairs(sorted) do
          local g = of[e.key]
          if g and isGroup[g] then
            local t2 = byG[g]; if not t2 then t2 = {}; byG[g] = t2 end
            t2[#t2 + 1] = e
          else
            rest[#rest + 1] = e
          end
        end
        local out = {}
        for _, g in ipairs(groups) do
          if not gFilter or gFilter == g then
            local l2 = byG[g] or {}
            local folded = fold[g] and true or nil
            out[#out + 1] = { header = g, n = #l2, folded = folded }
            if not folded then for _, e in ipairs(l2) do out[#out + 1] = e end end
          end
        end
        if not gFilter or gFilter == "~rest" then
          local foldedR = fold["~rest"] and true or nil
          out[#out + 1] = { header = "UNGROUPED", ungrouped = true, n = #rest, folded = foldedR }
          if not foldedR then for _, e in ipairs(rest) do out[#out + 1] = e end end
        end
        sorted = out
      end
      sorted[#sorted + 1] = { addGroup = true }
    end
    for _, b in ipairs(headers) do
      if b.field == fld then b.tt:SetTextColor(T.Unpack(C.accent)) else b.tt:SetTextColor(T.Unpack(C.muted)) end
    end
    local total = browseView and #sorted or math.min(#sorted, opts.maxRows or M.C.RANK_TOP)
    if removedView then
      count:SetText(nItems .. (q and " matches" or " recently removed"))
    elseif browseView then
      count:SetText(nItems .. (q and " matches" or " items in the archive"))
    else
      count:SetText(nItems .. (q and " matches" or (opts.unit or " items")))
    end
    if st.toggle then
      st.toggle:SetShown(not browseView)   -- removed-view toggle makes no sense while browsing
      if st.showRemoved then
        st.toggle.tf:SetText("< back to watchlist"); st.toggle.tf:SetTextColor(T.Unpack(C.accent))
      else
        local nrem = (M.RecentlyRemoved and #M.RecentlyRemoved()) or 0
        st.toggle.tf:SetText("recently removed (" .. nrem .. ")"); st.toggle.tf:SetTextColor(T.Unpack(C.sub))
      end
    end
    if st.browseToggle then
      if browseView then
        st.browseToggle.tf:SetText("< back to watchlist"); st.browseToggle.tf:SetTextColor(T.Unpack(C.accent))
      else
        st.browseToggle.tf:SetText("browse all items \194\187"); st.browseToggle.tf:SetTextColor(T.Unpack(C.sub))
      end
    end
    if updateChips then updateChips(not removedView and not browseView) end
    -- taller window -> more visible rows (the scroll frame already tracks the panel)
    local vis = availRows(panel, 50 + TOP_OFF, CH_ROWH, 10)
    for r = #rows + 1, vis do mkRow(r) end
    FauxScrollFrame_Update(scroll, total, vis, CH_ROWH)
    local offset = math.min(FauxScrollFrame_GetOffset(scroll), math.max(0, total - vis))
    for r = 1, #rows do
      local idx = r + offset
      local btn = rows[r]
      if r <= vis and idx <= total then
        local e = sorted[idx]; local m = e.m
        btn.isHeader, btn.isAddGroup, btn.group, btn.foldKey = nil, nil, nil, nil
        if e.header or e.addGroup then
          -- group header / "+ new group" pseudo rows
          btn.key, btn.addable = nil, false
          btn.zb:SetShown(false); btn.wb:Hide()
          for i2 = 2, 9 do btn.fs[i2]:SetText("") end
          if e.addGroup then
            btn.isAddGroup = true
            btn.fs[1]:SetText("+ new group\226\128\166")
            colorize(btn.fs[1], C.muted)
          else
            btn.isHeader = true
            btn.group = (not e.ungrouped) and e.header or nil
            btn.foldKey = e.ungrouped and "~rest" or e.header
            btn.fs[1]:SetText((e.folded and "+  " or "\226\128\147  ")
              .. (e.ungrouped and "UNGROUPED" or e.header:upper()) .. "   (" .. e.n .. ")")
            colorize(btn.fs[1], e.ungrouped and C.sub or C.accent)
          end
          btn:Show()
        else
        btn.key = e.key
        btn.addable = e.addable and true or false
        btn.zb:SetShown((r % 2) == 0)
        btn.wb:SetShown(browseView and M.IsWatched(e.key) or false)
        local qc = M.ItemQualityColor(e.key)
        if e.addable then
          btn.fs[1]:SetText("+ " .. M.ItemName(e.key)); colorize(btn.fs[1], C.accent)
        else
          btn.fs[1]:SetText(M.ItemName(e.key)); btn.fs[1]:SetTextColor(qc.r, qc.g, qc.b)
        end
        btn.fs[2]:SetText(M.ItemCategory(e.key)); colorize(btn.fs[2], C.sub)
        local sig, srgb = todaySignal(m)
        btn.fs[3]:SetText(sig or "\226\128\147"); colorize(btn.fs[3], srgb or C.muted)
        if m and m.fair then
          btn.fs[4]:SetText(M.MoneyPlain(m.cur))
          if m.cur <= m.buy then colorize(btn.fs[4], C.green)
          elseif m.cur >= m.sell then colorize(btn.fs[4], C.red)
          else colorize(btn.fs[4], C.text) end
          btn.fs[5]:SetText(M.MoneyPlain(m.fair)); colorize(btn.fs[5], C.sub)
          btn.fs[6]:SetText(string.format("%+.0f%%", m.delta * 100))
          if M.NotListed and M.NotListed(m) then
            colorize(btn.fs[4], C.muted); colorize(btn.fs[6], C.muted)
          else
            colorize(btn.fs[6], C[M.DeltaColor and M.DeltaColor(m.delta) or "sub"] or C.sub)
          end
          btn.fs[7]:SetText(math.floor(m.avgQty + 0.5)); colorize(btn.fs[7], C.sub)
          btn.fs[8]:SetText(m.days)
          if m.days >= 8 then colorize(btn.fs[8], C.green) else btn.fs[8]:SetTextColor(0.90, 0.62, 0.40) end
          btn.fs[9]:SetText(string.format("%.2f", m.score)); colorize(btn.fs[9], C.accent)
        elseif m then
          -- browse shell (below the ranking gate): price + supply only
          btn.fs[4]:SetText(m.cur and M.MoneyPlain(m.cur) or "\226\128\147"); colorize(btn.fs[4], C.text)
          btn.fs[5]:SetText("\226\128\147"); colorize(btn.fs[5], C.muted)
          btn.fs[6]:SetText("\226\128\147"); colorize(btn.fs[6], C.muted)
          btn.fs[7]:SetText(math.floor((m.avgQty or 0) + 0.5)); colorize(btn.fs[7], C.sub)
          btn.fs[8]:SetText(m.days or 0)
          if (m.days or 0) >= 8 then colorize(btn.fs[8], C.green) else btn.fs[8]:SetTextColor(0.90, 0.62, 0.40) end
          btn.fs[9]:SetText("\226\128\147"); colorize(btn.fs[9], C.muted)
        else
          for i = 4, 9 do btn.fs[i]:SetText("\226\128\147"); colorize(btn.fs[i], C.muted) end
        end
        btn:Show()
        end
      else
        btn.key = nil; btn.addable = false; btn.wb:Hide(); btn:Hide()
      end
    end
    local emptyMsg = removedView and "Nothing removed recently"
      or (browseView and "Analyzing the archive - one moment (or run a scan at the AH first)")
      or opts.emptyText
    if total == 0 and emptyMsg then
      M.FillChartCard(card, nil)
      card.title:SetText(emptyMsg); colorize(card.title, C.sub)
    else
      M.FillChartCard(card, card.shownKey or (sorted[1] and sorted[1].key) or nil)
    end
  end

  return st
end

function M.BuildWatch(panel)
  local st = CreateRankTab(panel, {
    scrollName  = "MidasWatchScroll",
    placeholder = "Filter, or type to find & add items",
    dataFn      = function() return M.RankWatch() end,
    maxRows     = 200,
    unit        = " watched",
    addSearch   = true,
    recentTab   = true,
    browseTab   = true,
    groups      = true,
    persistKey  = "watchSort",
    emptyText   = "Watchlist is empty - type a name above to add items",
  })
  M.RefreshWatch = st.Refresh
  -- jump straight into the all-items browse (what's-new)
  M.OpenBrowse = function()
    st.showAll, st.showRemoved = true, nil
    M.SelectTab(TAB.Watchlist)   -- SelectTab refreshes the tab
  end
end

-- ===== Trades tab: history + per-item sellability ===========================
local LOG_COLS = {
  { name = "Date",   w = 92,  just = "LEFT",  sort = "ts" },
  { name = "Type",   w = 64,  just = "LEFT",  sort = "kind" },
  { name = "Item",   w = 176, just = "LEFT",  sort = "iname" },
  { name = "Qty",    w = 40,  just = "RIGHT", sort = "count" },
  { name = "Unit",   w = 88,  just = "RIGHT", sort = "unit" },
  { name = "Total",  w = 92,  just = "RIGHT", sort = "total" },
  { name = "Net",    w = 92,  just = "RIGHT", sort = "net" },
  { name = "vs Fair", w = 56,  just = "RIGHT", sort = "delta" },
  { name = "Char",   w = 120, just = "LEFT",  sort = "char" },
}
-- widths sum to 642 (+4 gap each) so ten columns fit the 686px rows
local ITEM_COLS = {
  { name = "Item",      w = 126, just = "LEFT",  sort = "iname" },
  { name = "Sold",      w = 38,  just = "RIGHT", sort = "sold" },
  { name = "Ret",       w = 36,  just = "RIGHT", sort = "ret" },
  { name = "Sell-thru", w = 58,  just = "RIGHT", sort = "rate" },
  { name = "Rating",    w = 70,  just = "LEFT",  sort = "rate" },
  { name = "Avg Sell",  w = 66,  just = "RIGHT", sort = "avgsell" },
  { name = "Avg Buy",   w = 62,  just = "RIGHT", sort = "avgbuy" },
  { name = "Margin",    w = 68,  just = "RIGHT", sort = "margin" },
  { name = "Net",       w = 70,  just = "RIGHT", sort = "net" },
  { name = "vs Fair",   w = 48,  just = "RIGHT", sort = "delta" },
}
local TRADE_ROWS, TRADE_ROWH = 17, 18

local TRADE_HELP = {
  sold  = { "Sold auctions", "How many of your auctions of this item SOLD over the last " .. (M.C.SELL_WINDOW or 60) .. " days." },
  ret   = { "Returned auctions", "How many EXPIRED and came back unsold over the last " .. (M.C.SELL_WINDOW or 60) .. " days." },
  rate  = { "Sell-through & rating", "sold / (sold + returned) over the last " .. (M.C.SELL_WINDOW or 60) .. " days.\n\n|cffE8B44AUnderpriced|r ~all sold -> you could ask more.\n|cff5BD178Well priced|r some sold, some returned.\n|cffF0635AOverpriced|r ~all returned -> lower the price." },
  avgsell = { "Average sale", "Average gold per sold UNIT (total proceeds / units sold) - directly comparable to Avg Buy, Current and Fair." },
  avgbuy = { "Average buy", "Average unit price YOU paid for this item over the last " .. (M.C.SELL_WINDOW or 60) .. " days - auction wins, vendor buys and trade-window buys. Compare with Avg Sell and Fair; Margin does the maths for the units you sold." },
  margin = { "Realized margin", "What you earned on the units you actually SOLD over the last " .. (M.C.SELL_WINDOW or 60) .. " days: sale proceeds after the AH cut minus your average buy price for those units.\n\nStock you bought but still hold does not count against it. \226\128\147 = no buys on record (crafted, farmed or looted), so there is no cost to compare." },
  net   = { "Net cash flow", "Gold in minus gold out over the last " .. (M.C.SELL_WINDOW or 60) .. " days: sale proceeds (after the AH cut) minus EVERYTHING you paid for it - including stock you still hold. A fresh restock pushes it below zero; Margin shows what the sales themselves earned." },
  delta = { "% over / under Fair", "Current market price vs its Fair price.\n\n|cff5BD178Below (green)|r cheaper than fair = good to BUY.\n|cffF0635AAbove (red)|r pricier than fair = good to SELL." },
  iname = { "Item", "Click to sort by name (A-Z)." },
  icat  = { "Category", "Click to sort by item class." },
}

-- History column explanations (the By-Item headers use TRADE_HELP above; the
-- History view had none at all)
local LOG_HELP = {
  ts    = { "Date", "When the mail was collected. Click to sort (newest first by default)." },
  kind  = { "Type", "Sold (green) - Bought / Vendor buy (red) - Own use (grey) = a vendor buy of something you never sell, not a trading cost - Returned = expired unsold - Cancelled - Outbid.",
            "Trade sell / Trade buy = the trade window, items one way and gold the other (the gold is split over several items by Fair). Traded away / Received = a swap or gift without a price. Trades with your own characters are transfers and not listed." },
  iname = { "Item", "Click to sort by name (A-Z)." },
  count = { "Quantity", "Units in this transaction." },
  unit  = { "Unit price", "Realized price per single unit." },
  total = { "Total", "Gross gold of the transaction, before the AH cut." },
  net   = { "Net", "After the AH cut: sale proceeds minus fees; buys count negative." },
  delta = { "vs Fair", "The transaction's unit price vs the item's Fair price on that day - how good the deal was." },
  char  = { "Character", "Which of your characters traded. Click to sort." },
}

local function tradeKindLabel(kind, src, id)
  if src == "trade" then
    if kind == "sold"     then return "Trade sell", C.green end
    if kind == "bought"   then return "Trade buy", C.red end
    if kind == "given"    then return "Traded away", C.muted end
    if kind == "received" then return "Received", C.muted end
  end
  if kind == "sold"      then return "Sold",      C.green end
  if kind == "bought"    then
    if src == "vendor" then
      -- never sold on: bought for your own use, not counted as trading cost
      if M.IsTradedID and not M.IsTradedID(id) then return "Own use", C.muted end
      return "Vendor buy", C.red
    end
    return "Bought", C.red
  end
  if kind == "returned"  then return "Returned",  C.sub end
  if kind == "cancelled" then return "Cancelled", C.muted end
  if kind == "outbid"    then return "Outbid",    C.blue end
  return kind or "?", C.muted
end

-- Fair on a trade's own day: an August sale measured against today's Fair
-- flips colour whenever the market moved since. Falls back to today's Fair
-- when the archive does not reach back to that day.
local fodCache = { gen = -1, v = {} }
local function fairOnDay(id, day)
  if not id then return nil end
  local gen = M._analysisGen or 0
  if fodCache.gen ~= gen then fodCache.gen, fodCache.v = gen, {} end
  local key = tostring(id)
  local ck = key .. ":" .. tostring(day)
  local v = fodCache.v[ck]
  if v == nil then
    local s = M.GetSeries(key)
    v = (s and day and M.FairAt and M.FairAt(s, key, day)) or false
    if not v then
      local m = s and M.Metrics(s, key)
      v = (m and m.fair) or false
    end
    fodCache.v[ck] = v
  end
  return v or nil
end

local function tradeSortVal(e, fld)
  if fld == "iname" then return (e.s.name or (e.s.id and M.ItemName(tostring(e.s.id))) or e.key):lower() end
  if fld == "icat"  then return (e.s.id and M.ItemCategory(tostring(e.s.id)) or ""):lower() end
  if fld == "sold"  then return e.s.soldStacks end
  if fld == "ret"   then return e.s.retStacks end
  if fld == "rate"  then return e.sell.rate or -1 end
  if fld == "net"   then return e.s.net or 0 end
  if fld == "avgsell" then
    local u = ((e.s.soldUnits or 0) > 0 and e.s.soldUnits) or e.s.soldStacks
    return (u > 0 and (e.s.gross or 0) > 0) and (e.s.gross / u) or -1
  end
  if fld == "avgbuy" then return e.ab or -1 end
  if fld == "margin" then return e.margin or -math.huge end
  if fld == "delta" then return (e.m and e.m.delta) or -math.huge end
  return e.s.net or 0
end

local function logSortVal(w, fld)
  local e = w.e
  if fld == "kind"  then return e.kind or "" end
  if fld == "iname" then return w.nml or (w.nm or ""):lower() end
  if fld == "count" then return w.cnt or 0 end
  if fld == "unit"  then return w.unit or -1 end
  if fld == "total" then return w.gross or 0 end
  if fld == "net"   then return e.net or 0 end
  if fld == "delta" then return w.vsmed or -math.huge end
  if fld == "char"  then return (e.char or ""):lower() end
  return e.ts or 0
end

function M.BuildTrades(panel)
  local st = { view = (M.db and M.db.config and M.db.config.tradeView) or "log",
               sort = { field = "net", asc = false },
               logSort = { field = "ts", asc = false },
               expanded = {} }   -- By-Item rows the user has clicked open
  M.tradeView = st.view

  -- view toggle (segmented), top-left of the panel
  local seg = T.Segment(panel, {
    { key = "log",  label = "History" },
    { key = "item", label = "By Item" },
  }, function(key)
    st.view = key; M.tradeView = key
    if M.db and M.db.config then M.db.config.tradeView = key end
    -- full RefreshUI, not just st.Refresh: the header chart toggles are shown
    -- only in By Item (History has no chart), and the footer hint follows too
    M.RefreshUI()
  end)
  if T.HelpTip then
    T.HelpTip(seg.frame, "Trades view", {
      "History: every logged event (sales, buys, returns) in order, from your AH mail and vendor purchases.",
      "By Item: aggregated per item with sell-through, rating, Avg Sell / Avg Buy and realized net - click a row to expand its individual transactions." })
  end
  seg.frame:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -1)
  st.seg = seg

  -- search box (same position as the other tabs, filters both History & By Item)
  st.search = ""
  local search = T.Input(panel, 300, 22, "Search item or category...", function(txt)
    st.search = (txt or ""):lower()
    st.Refresh()
  end)
  search:SetPoint("TOPLEFT", 0, -2)

  -- summary strip
  local function stat(x, w, label, tip)
    local lbl = T.Text(panel, T.SIZE.tiny, "muted", T.FONT_MED)
    lbl:SetPoint("TOPLEFT", x, -34); lbl:SetWidth(w); lbl:SetText(label)
    local val = T.Text(panel, T.SIZE.h2 + 2, "text", T.FONT_SEMI)
    val:SetPoint("TOPLEFT", x, -47); val:SetWidth(w)
    val.lbl = lbl
    if tip and T.HelpTip then
      local hb = CreateFrame("Button", nil, panel)
      hb:SetPoint("TOPLEFT", x, -34); hb:SetSize(w, 32)
      T.HelpTip(hb, label, tip)
    end
    return val
  end
  local win = M.C.SELL_WINDOW or 60
  st.sNet   = stat(0,   118, "NET P/L \194\183 " .. win .. "D",
    { "Realized trading only: sale proceeds after fees, minus what you paid, over the window." })
  st.sHold  = stat(124, 118, "HOLDINGS \194\183 " .. win .. "D",
    { "Value change of everything you still HOLD (items only, gold excluded): today's holdings value minus the daily snapshot ~" .. win .. " days back.",
      "NET P/L books every buy as a cost although the items are still there. Bought for 3k and the stock is worth 9k now? That +6k shows HERE.",
      "Younger net-worth history than the window: measured from the oldest snapshot instead." })
  st.sTotal = stat(248, 122, "TOTAL \194\183 " .. win .. "D",
    { "NET P/L (realized cash from trades) + HOLDINGS (value change of what you kept): your true trading result over the window.",
      "TOTAL can top the net-worth change: net worth = TOTAL + non-trading gold flow (repairs, flights, lost deposits, quest gold).",
      "\"/midas band\" prints that bridge with your numbers." })
  st.sGross = stat(376, 108, "GROSS SELLS")
  st.sFees  = stat(490, 84,  "AH FEES")
  st.sBuy   = stat(580, 104, "BOUGHT",
    { "AH and vendor buys over the window. Vendor buys of items you never sell (arrows, drinks) are own use and stay out.",
      "The consumed line under it prices the bought units that were neither resold nor are still in stock - equips you put on, mats you used up. They read as losses in NET P/L and TOTAL; this line says how much of that was own consumption." })
  st.sFlow  = stat(690, 136, "SOLD / RETURNED")
  st.sRate  = stat(832, 112, "SELL-THROUGH")
  -- own consumption, tucked under the BOUGHT stat
  st.sCons = T.Text(panel, T.SIZE.tiny, "muted", T.FONT_MED)
  st.sCons:SetPoint("TOPLEFT", 580, -64); st.sCons:SetWidth(160); st.sCons:SetJustifyH("LEFT")

  local div = T.Divider(panel)
  div:SetPoint("TOPLEFT", 0, -74); div:SetPoint("TOPRIGHT", 0, -74)

  -- ----- History view -------------------------------------------------------
  local logView = CreateFrame("Frame", nil, panel)
  logView:SetPoint("TOPLEFT", 0, -82); logView:SetPoint("BOTTOMRIGHT", 0, 0)
  local logHeaders = {}
  do
    local hx = 0
    for _, d in ipairs(LOG_COLS) do
      local b = CreateFrame("Button", nil, logView)
      b:SetSize(d.w, 16); b:SetPoint("TOPLEFT", hx, -2)
      local tt = b:CreateFontString(nil, "OVERLAY")
      T.RegFont(tt, T.FONT_MED, T.SIZE.tiny); tt:SetAllPoints(); tt:SetJustifyH(d.just)
      tt:SetText(d.name:upper()); tt:SetTextColor(T.Unpack(C.muted))
      b.tt, b.field = tt, d.sort
      b:SetScript("OnClick", function()
        if st.logSort.field == d.sort then st.logSort.asc = not st.logSort.asc
        else st.logSort.field = d.sort; st.logSort.asc = (d.sort == "iname" or d.sort == "kind" or d.sort == "char") end
        st.RefreshLog()
      end)
      b:SetScript("OnEnter", function()
        if st.logSort.field ~= d.sort then tt:SetTextColor(T.Unpack(C.sub)) end
        local h = LOG_HELP[d.sort]
        if h then
          GameTooltip:SetOwner(b, "ANCHOR_TOP")   -- above the header, clear of the rows
          GameTooltip:SetMinimumWidth(300)
          GameTooltip:SetText(h[1], 1, 1, 1)
          for i = 2, #h do GameTooltip:AddLine(h[i], 0.82, 0.85, 0.92, true) end
          GameTooltip:Show()
        end
      end)
      b:SetScript("OnLeave", function()
        if st.logSort.field ~= d.sort then tt:SetTextColor(T.Unpack(C.muted)) end
        GameTooltip:SetMinimumWidth(0)
        GameTooltip:Hide()
      end)
      logHeaders[#logHeaders + 1] = b
      hx = hx + d.w + 4
    end
  end
  local logScroll = CreateFrame("ScrollFrame", "MidasTradeLogScroll", logView, "FauxScrollFrameTemplate")
  logScroll:SetPoint("TOPLEFT", 0, -22); logScroll:SetPoint("BOTTOMRIGHT", logView, "BOTTOMLEFT", 864, 0)
  local function logWheel(_, delta)
    local sb = _G["MidasTradeLogScrollScrollBar"]
    if sb then sb:SetValue(sb:GetValue() - delta * TRADE_ROWH * 2) end
  end
  logScroll:EnableMouseWheel(true); logScroll:SetScript("OnMouseWheel", logWheel)
  logScroll:SetScript("OnVerticalScroll", function(self, offset)
    -- scroll only refills the visible rows from st.logData; the expensive
    -- rebuild (fetch + decorate + sort) runs in buildLog on data changes only
    FauxScrollFrame_OnVerticalScroll(self, offset, TRADE_ROWH, st.FillLog)
  end)
  T.StyleScrollbar("MidasTradeLogScroll")
  local logRows = {}
  local function mkLogRow(r)
    local btn = CreateFrame("Button", nil, logView)
    btn:SetSize(852, TRADE_ROWH); btn:SetPoint("TOPLEFT", 0, -22 - (r - 1) * TRADE_ROWH)
    local zb = btn:CreateTexture(nil, "BACKGROUND"); zb:SetAllPoints(); zb:SetColorTexture(1, 1, 1, 0.02); zb:Hide(); btn.zb = zb
    local hl = btn:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.05)
    local fs, cx = {}, 0
    for i, d in ipairs(LOG_COLS) do fs[i] = cell(btn, cx, -3, d.w, d.just, T.SIZE.body); cx = cx + d.w + 4 end
    btn.fs = fs
    btn:EnableMouseWheel(true); btn:SetScript("OnMouseWheel", logWheel)
    btn:SetScript("OnEnter", function() if btn.key then ShowItemTip(btn.key) end end)
    btn:SetScript("OnLeave", HideTip)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, mouse)
      if not btn.key then return end
      if ItemMenuClick(mouse, btn.key) then return end
      if M.ModPostDown() then M.PostItemStats(btn.key); return end
      if M.ModSearchDown() then M.ItemShiftAction(btn.key) else GoChart(btn.key) end
    end)
    logRows[r] = btn
  end
  for r = 1, TRADE_ROWS do mkLogRow(r) end

  -- ----- By-Item view -------------------------------------------------------
  local itemView = CreateFrame("Frame", nil, panel)
  itemView:SetPoint("TOPLEFT", 0, -82); itemView:SetPoint("BOTTOMRIGHT", 0, 0)
  vline(itemView, 696)
  local itemHeaders = {}
  do
    local hx = 0
    for _, d in ipairs(ITEM_COLS) do
      if d.sort then
        local b = CreateFrame("Button", nil, itemView)
        b:SetSize(d.w, 16); b:SetPoint("TOPLEFT", hx, -2)
        local tt = b:CreateFontString(nil, "OVERLAY")
        T.RegFont(tt, T.FONT_MED, T.SIZE.tiny); tt:SetAllPoints(); tt:SetJustifyH(d.just)
        tt:SetText(d.name:upper()); tt:SetTextColor(T.Unpack(C.muted))
        b.tt, b.field = tt, d.sort
        b:SetScript("OnClick", function()
          if st.sort.field == d.sort then st.sort.asc = not st.sort.asc
          else st.sort.field = d.sort; st.sort.asc = (d.sort == "iname" or d.sort == "icat") end
          st.RefreshItem()
        end)
        b:SetScript("OnEnter", function()
          if st.sort.field ~= d.sort then tt:SetTextColor(T.Unpack(C.sub)) end
          local h = TRADE_HELP[d.sort]
          if h then
            GameTooltip:SetOwner(b, "ANCHOR_TOP")   -- above the header, so it never covers the rows
            GameTooltip:SetMinimumWidth(300)        -- uniform wrap width; texts are whole paragraphs
            GameTooltip:SetText(h[1], 1, 1, 1)
            GameTooltip:AddLine(h[2], 0.82, 0.85, 0.92, true)
            GameTooltip:Show()
          end
        end)
        b:SetScript("OnLeave", function()
          if st.sort.field ~= d.sort then tt:SetTextColor(T.Unpack(C.muted)) end
          GameTooltip:SetMinimumWidth(0)
          GameTooltip:Hide()
        end)
        itemHeaders[#itemHeaders + 1] = b
      else
        local tt = cell(itemView, hx, -2, d.w, d.just, T.SIZE.tiny, "muted", T.FONT_MED)
        tt:SetText(d.name:upper())
      end
      hx = hx + d.w + 4
    end
  end
  local itemScroll = CreateFrame("ScrollFrame", "MidasTradeItemScroll", itemView, "FauxScrollFrameTemplate")
  itemScroll:SetPoint("TOPLEFT", 0, -22)
  itemScroll:SetPoint("BOTTOMRIGHT", itemView, "BOTTOMLEFT", 690, 0)
  local function itemWheel(_, delta)
    local sb = _G["MidasTradeItemScrollScrollBar"]
    if sb then sb:SetValue(sb:GetValue() - delta * TRADE_ROWH * 2) end
  end
  itemScroll:EnableMouseWheel(true); itemScroll:SetScript("OnMouseWheel", itemWheel)
  itemScroll:SetScript("OnVerticalScroll", function(self, offset)
    -- same split as the History list: scrolling refills from st.itemDisp only
    FauxScrollFrame_OnVerticalScroll(self, offset, TRADE_ROWH, st.FillItem)
  end)
  T.StyleScrollbar("MidasTradeItemScroll")
  local itemCard = CreateChartCard(itemView, 702, 250, 330)
  -- sticky group header: when you scroll into an expanded item's transactions this
  -- pins the item name + the transaction column labels over the normal header, so you
  -- always know which item you're inside and what the columns mean.
  local sticky = CreateFrame("Frame", nil, itemView)
  sticky:SetPoint("TOPLEFT", itemView, "TOPLEFT", 0, -2)
  sticky:SetSize(690, 17)
  sticky:SetFrameLevel(itemView:GetFrameLevel() + 12)
  local sbg = sticky:CreateTexture(nil, "BACKGROUND"); sbg:SetAllPoints(); sbg:SetColorTexture(C.bg0[1], C.bg0[2], C.bg0[3], 1)
  local sln = sticky:CreateTexture(nil, "ARTWORK"); sln:SetColorTexture(T.Unpack(C.border)); sln:SetHeight(1)
  sln:SetPoint("BOTTOMLEFT", 0, 0); sln:SetPoint("BOTTOMRIGHT", 0, 0)
  sticky.name = cell(sticky, 16, -1, 104, "LEFT", T.SIZE.tiny, "accent", T.FONT_MED)
  for _, c in ipairs({ { "Type", 124, 58, "LEFT" }, { "Qty", 186, 38, "RIGHT" }, { "Unit", 228, 92, "RIGHT" },
                       { "Total", 324, 92, "RIGHT" }, { "Net", 420, 88, "RIGHT" }, { "vs Fair", 512, 58, "RIGHT" } }) do
    cell(sticky, c[2], -1, c[3], c[4], T.SIZE.tiny, "muted", T.FONT_MED):SetText(c[1]:upper())
  end
  sticky:Hide()
  st.sticky = sticky
  local itemRows = {}
  local function mkItemRow(r)
    local btn = CreateFrame("Button", nil, itemView)
    btn:SetSize(686, TRADE_ROWH); btn:SetPoint("TOPLEFT", 0, -22 - (r - 1) * TRADE_ROWH)
    local zb = btn:CreateTexture(nil, "BACKGROUND"); zb:SetAllPoints(); zb:SetColorTexture(1, 1, 1, 0.02); zb:Hide(); btn.zb = zb
    local hl = btn:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.05)
    local fs, cx = {}, 0
    for i, d in ipairs(ITEM_COLS) do fs[i] = cell(btn, cx, -3, d.w, d.just, T.SIZE.body); cx = cx + d.w + 4 end
    btn.fs = fs
    -- disclosure indicator (+/- box; Inter has no right-pointing triangle glyph)
    fs[1]:ClearAllPoints(); fs[1]:SetPoint("TOPLEFT", 14, -3); fs[1]:SetWidth(ITEM_COLS[1].w - 14)
    btn.tri = btn:CreateTexture(nil, "OVERLAY"); btn.tri:SetSize(11, 11); btn.tri:SetPoint("TOPLEFT", 0, -4)
    -- per-transaction sub-row cells (shown when an item is expanded), indented
    btn.sub = {
      date  = cell(btn, 16,  -3, 104, "LEFT",  T.SIZE.small),
      kind  = cell(btn, 124, -3, 58,  "LEFT",  T.SIZE.small),
      qty   = cell(btn, 186, -3, 38,  "RIGHT", T.SIZE.small),
      unit  = cell(btn, 228, -3, 92,  "RIGHT", T.SIZE.small),
      total = cell(btn, 324, -3, 92,  "RIGHT", T.SIZE.small),
      net   = cell(btn, 420, -3, 88,  "RIGHT", T.SIZE.small),
      vsmed = cell(btn, 512, -3, 58,  "RIGHT", T.SIZE.small),
    }
    for _, f in pairs(btn.sub) do f:Hide() end
    btn:EnableMouseWheel(true); btn:SetScript("OnMouseWheel", itemWheel)
    btn:SetScript("OnEnter", function() if btn.key then M.FillChartCard(itemCard, btn.key); ShowItemTip(btn.key) end end)
    btn:SetScript("OnLeave", HideTip)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, mouse)
      -- Shift-click anywhere in By Item (group row OR an expanded transaction row)
      -- jumps to the full chart of that item; alt posts its price card;
      -- right-click opens the item menu; plain click expands/collapses.
      if ItemMenuClick(mouse, btn.key) then return end
      if mouse == "RightButton" then return end
      if M.ModPostDown() and btn.key then M.PostItemStats(btn.key); return end
      if M.ModSearchDown() and btn.key then
        GoChart(btn.key)
        return
      end
      if btn.expandKey then
        st.expanded[btn.expandKey] = (not st.expanded[btn.expandKey]) or nil
        st.RefreshItem()
      end
    end)
    itemRows[r] = btn
  end
  for r = 1, TRADE_ROWS do mkItemRow(r) end

  -- ----- refreshers ---------------------------------------------------------
  -- Build (fetch + decorate + sort the whole log) and fill (draw the visible
  -- rows) are split: OnVerticalScroll used to run the full rebuild on every
  -- scroll step, which got laggy once the 75-day trade log grew into the
  -- thousands of entries. Scrolling now only refills.
  local function buildLog()
    local data = M.TradeLog(M.RealmKey())
    local q = st.search or ""
    -- build display rows: clean name, resolve id, per-unit price + vs-median
    -- (same logic as the By-Item detail rows, just flat & chronological)
    local rows, catCache = {}, {}
    for _, e in ipairs(data) do
      local nm = (M.CleanItemName and M.CleanItemName(e.name)) or e.name or (e.id and M.ItemName(tostring(e.id))) or "?"
      local nml = nm:lower()
      local id = e.id or (nm ~= "?" and M.NameToID and M.NameToID(nm)) or nil
      local hit = (q == "") or nml:find(q, 1, true)
      if not hit and id then
        local cat = catCache[id]
        if not cat then cat = (M.ItemCategory(tostring(id)) or ""):lower(); catCache[id] = cat end
        hit = cat:find(q, 1, true)
      end
      if hit then
        local cnt = e.count
        if (not cnt or cnt == 0) and e.kind == "sold" and M.AuctionSize then cnt = M.AuctionSize(id, e.gross or 0) end
        local gross = e.gross or 0
        local unit = (cnt and cnt > 0 and gross > 0) and (gross / cnt) or nil
        local med = unit and fairOnDay(id, e.day) or nil
        local vsmed = (unit and med and med > 0) and (unit / med - 1) or nil
        rows[#rows + 1] = { e = e, nm = nm, nml = nml, id = id, cnt = cnt, gross = gross, unit = unit, vsmed = vsmed }
      end
    end
    local fld, asc = st.logSort.field, st.logSort.asc
    table.sort(rows, function(a, b)
      local av, bv = logSortVal(a, fld), logSortVal(b, fld)
      if type(av) == "string" or type(bv) == "string" then
        av = av or ""; bv = bv or ""
        if av ~= bv then if asc then return av < bv else return av > bv end end
      elseif av ~= bv then
        if asc then return av < bv else return av > bv end
      end
      return (a.e.ts or 0) > (b.e.ts or 0)
    end)
    for _, b in ipairs(logHeaders) do
      if b.field == fld then b.tt:SetTextColor(T.Unpack(C.accent)) else b.tt:SetTextColor(T.Unpack(C.muted)) end
    end
    st.logData = rows
  end

  function st.FillLog()
    local rows = st.logData or {}
    local total = #rows
    local vis = availRows(panel, 104, TRADE_ROWH, 10)
    for r = #logRows + 1, vis do mkLogRow(r) end
    FauxScrollFrame_Update(logScroll, total, vis, TRADE_ROWH)
    local offset = math.min(FauxScrollFrame_GetOffset(logScroll), math.max(0, total - vis))
    for r = 1, #logRows do
      local btn = logRows[r]
      local w = (r <= vis) and rows[r + offset] or nil
      if w then
        local e = w.e
        btn.zb:SetShown((r % 2) == 0)
        btn.key = w.id and tostring(w.id) or nil
        btn.fs[1]:SetText(date("%b %d  %H:%M", e.ts)); colorize(btn.fs[1], C.sub)
        local lab, lrgb = tradeKindLabel(e.kind, e.src, e.id or w.id)
        btn.fs[2]:SetText(lab); colorize(btn.fs[2], lrgb)
        btn.fs[3]:SetText(w.nm)
        if w.id then local qc = M.ItemQualityColor(tostring(w.id)); btn.fs[3]:SetTextColor(qc.r, qc.g, qc.b)
        else colorize(btn.fs[3], C.sub) end
        btn.fs[4]:SetText((w.cnt and w.cnt > 0) and tostring(w.cnt) or "\226\128\147"); colorize(btn.fs[4], C.sub)
        local isRet = (e.kind == "returned" or e.kind == "cancelled" or e.kind == "given" or e.kind == "received")
        if isRet then
          btn.fs[5]:SetText("\226\128\147"); colorize(btn.fs[5], C.muted)
          btn.fs[6]:SetText("\226\128\147"); colorize(btn.fs[6], C.muted)
          btn.fs[7]:SetText("\226\128\147"); colorize(btn.fs[7], C.muted)
          btn.fs[8]:SetText("\226\128\147"); colorize(btn.fs[8], C.muted)
        else
          btn.fs[5]:SetText(w.unit and M.MoneyPlain(w.unit) or "\226\128\147"); colorize(btn.fs[5], w.unit and C.text or C.muted)
          btn.fs[6]:SetText(M.MoneyPlain(w.gross)); colorize(btn.fs[6], C.sub)
          local amt = e.net or 0
          btn.fs[7]:SetText((amt >= 0 and "+" or "-") .. M.MoneyPlain(math.abs(amt))); colorize(btn.fs[7], amt >= 0 and C.green or C.red)
          if w.vsmed then
            btn.fs[8]:SetText(string.format("%+.0f%%", w.vsmed * 100))
            local good
            if w.vsmed >= M.C.PICK_DELTA then good = (e.kind == "sold")
            elseif w.vsmed <= -M.C.PICK_DELTA then good = (e.kind ~= "sold") end
            if good == true then colorize(btn.fs[8], C.green)
            elseif good == false then colorize(btn.fs[8], C.red)
            else colorize(btn.fs[8], C.sub) end
          else
            btn.fs[8]:SetText("\226\128\147"); colorize(btn.fs[8], C.muted)
          end
        end
        local who = (e.char or ""):gsub("%-.*$", "")
        if e.partner then who = who .. " \226\134\148 " .. e.partner end
        btn.fs[9]:SetText(who); colorize(btn.fs[9], C.muted)
        btn:Show()
      else
        btn.key = nil; btn:Hide()
      end
    end
    if total == 0 then
      local btn = logRows[1]
      btn.zb:Hide(); btn.key = nil
      for i = 1, #LOG_COLS do btn.fs[i]:SetText("") end
      btn.fs[3]:SetText("No trades yet \226\128\147 collect AH mail"); colorize(btn.fs[3], C.muted)
      btn:Show()
    end
  end

  function st.RefreshLog()
    buildLog(); st.FillLog()
  end

  local function buildItems()
    local realm = M.RealmKey()
    local stats = M.TradeStats(realm)
    -- every By-Item column covers the same window as TradeStats: Avg Buy from
    -- the window's buys too (one log pass), not the whole retained log
    local cutoff = M.GetScanDay() - (M.C.SELL_WINDOW or 60)
    local paidBy = {}
    for _, ev in ipairs(M.TradeLog(realm)) do
      if ev.kind == "bought" and ev.id and (ev.day or 0) >= cutoff and (ev.gross or 0) > 0 then
        local pb = paidBy[ev.id]
        if not pb then pb = { paid = 0, units = 0 }; paidBy[ev.id] = pb end
        pb.paid = pb.paid + ev.gross
        pb.units = pb.units + ((ev.count and ev.count > 0) and ev.count or 1)
      end
    end
    local list = {}
    for key, s in pairs(stats) do
      -- keyed -> per-item odds refinement + the metrics memo (this loop covers every
      -- traded item in one frame; without the memo it re-prices all of them each refresh)
      local sid = s.id and tostring(s.id)
      local m = sid and M.Metrics(M.GetSeries(sid) or {}, sid) or nil
      local pb = s.id and paidBy[tonumber(s.id) or s.id]
      local ab = (pb and pb.units > 0) and (pb.paid / pb.units) or nil
      -- realized margin on the SOLD units only: proceeds after the cut minus their
      -- buy cost. Units bought before the window fall back to the retained log's
      -- average; no buys at all (crafted / farmed) = no margin to show.
      local cost = ab or (sid and M.RealizedBuy and (M.RealizedBuy(sid))) or nil
      local su = ((s.soldUnits or 0) > 0 and s.soldUnits) or s.soldStacks or 0
      local margin = (cost and su > 0) and ((s.gross or 0) - (s.fees or 0) - cost * su) or nil
      list[#list + 1] = { key = key, s = s, m = m, ab = ab, margin = margin, sell = M.Sellability(key) }
    end
    local q = st.search
    if q and q ~= "" then
      local f = {}
      for _, e in ipairs(list) do
        local nm = (e.s.name or (e.s.id and M.ItemName(tostring(e.s.id))) or e.key):lower()
        local cat = (e.s.id and M.ItemCategory(tostring(e.s.id)) or ""):lower()
        if nm:find(q, 1, true) or cat:find(q, 1, true) then f[#f + 1] = e end
      end
      list = f
    end
    local fld, asc = st.sort.field, st.sort.asc
    table.sort(list, function(a, b)
      local av, bv = tradeSortVal(a, fld), tradeSortVal(b, fld)
      if type(av) == "string" or type(bv) == "string" then
        av = av or ""; bv = bv or ""
        if av ~= bv then if asc then return av < bv else return av > bv end end
      elseif av ~= bv then
        if asc then return av < bv else return av > bv end
      end
      return (a.s.net or 0) > (b.s.net or 0)
    end)
    for _, b in ipairs(itemHeaders) do
      if b.field == fld then b.tt:SetTextColor(T.Unpack(C.accent)) else b.tt:SetTextColor(T.Unpack(C.muted)) end
    end
    -- flatten: each aggregate item; when expanded, a label row + its transactions
    local disp = {}
    for _, e in ipairs(list) do
      disp[#disp + 1] = { t = "item", e = e }
      if st.expanded[e.key] then
        local med = e.m and e.m.fair
        disp[#disp + 1] = { t = "head", e = e }
        for _, ev in ipairs(M.ItemTradeLog(e.key)) do
          if (ev.day or 0) >= cutoff then
            disp[#disp + 1] = { t = "sub", ev = ev, id = e.s.id, med = med }
          end
        end
      end
    end
    st.itemList, st.itemDisp = list, disp
  end

  function st.FillItem()
    local disp, list = st.itemDisp or {}, st.itemList or {}
    local total = #disp
    local vis = availRows(panel, 104, TRADE_ROWH, 10)
    for r = #itemRows + 1, vis do mkItemRow(r) end
    FauxScrollFrame_Update(itemScroll, total, vis, TRADE_ROWH)
    local offset = math.min(FauxScrollFrame_GetOffset(itemScroll), math.max(0, total - vis))
    for r = 1, #itemRows do
      local btn = itemRows[r]
      local d = (r <= vis) and disp[r + offset] or nil
      if d and d.t == "item" then
        local e = d.e; local s = e.s
        for i = 1, #ITEM_COLS do btn.fs[i]:Show() end
        for _, f in pairs(btn.sub) do f:Hide() end
        btn.zb:SetShown((r % 2) == 0)
        btn.key = s.id and tostring(s.id) or nil
        btn.expandKey = e.key
        btn.tri:SetTexture(st.expanded[e.key] and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
        btn.tri:Show()
        local nm = s.name or (s.id and M.ItemName(tostring(s.id))) or e.key
        btn.fs[1]:SetText(nm)
        if s.id then local qc = M.ItemQualityColor(tostring(s.id)); btn.fs[1]:SetTextColor(qc.r, qc.g, qc.b)
        else colorize(btn.fs[1], C.sub) end
        btn.fs[2]:SetText(s.soldStacks); colorize(btn.fs[2], C.green)
        btn.fs[3]:SetText(s.retStacks); colorize(btn.fs[3], C.sub)
        btn.fs[4]:SetText(e.sell.rate and string.format("%.0f%%", e.sell.rate * 100) or "\226\128\147"); colorize(btn.fs[4], C.text)
        btn.fs[5]:SetText(e.sell.label); colorize(btn.fs[5], e.sell.color)
        local avgUnits = ((s.soldUnits or 0) > 0 and s.soldUnits) or s.soldStacks
        local avg = (avgUnits > 0 and (s.gross or 0) > 0) and (s.gross / avgUnits) or nil
        btn.fs[6]:SetText(avg and M.MoneyPlain(avg) or "\226\128\147"); colorize(btn.fs[6], avg and C.sub or C.muted)
        btn.fs[7]:SetText(e.ab and M.MoneyPlain(e.ab) or "\226\128\147"); colorize(btn.fs[7], e.ab and C.sub or C.muted)
        if e.margin then
          btn.fs[8]:SetText((e.margin >= 0 and "+" or "-") .. M.MoneyPlain(math.abs(e.margin)))
          colorize(btn.fs[8], e.margin >= 0 and C.green or C.red)
        else
          btn.fs[8]:SetText("\226\128\147"); colorize(btn.fs[8], C.muted)
        end
        local net = s.net or 0
        btn.fs[9]:SetText((net >= 0 and "+" or "-") .. M.MoneyPlain(math.abs(net))); colorize(btn.fs[9], net >= 0 and C.sub or C.red)
        if e.m then
          btn.fs[10]:SetText(string.format("%+.0f%%", e.m.delta * 100))
          colorize(btn.fs[10], C[M.DeltaColor and M.DeltaColor(e.m.delta) or "sub"] or C.sub)
        else
          btn.fs[10]:SetText("\226\128\147"); colorize(btn.fs[10], C.muted)
        end
        btn:Show()
      elseif d and (d.t == "sub" or d.t == "head") then
        for i = 1, #ITEM_COLS do btn.fs[i]:Hide() end
        for _, f in pairs(btn.sub) do f:Show() end
        btn.tri:Hide()
        btn.expandKey = nil
        if d.t == "head" then
          btn.zb:Hide(); btn.key = nil
          btn.sub.date:SetText("Date"); colorize(btn.sub.date, C.muted)
          btn.sub.kind:SetText("Type"); colorize(btn.sub.kind, C.muted)
          btn.sub.qty:SetText("Qty");  colorize(btn.sub.qty, C.muted)
          btn.sub.unit:SetText("Unit"); colorize(btn.sub.unit, C.muted)
          btn.sub.total:SetText("Total"); colorize(btn.sub.total, C.muted)
          btn.sub.net:SetText("Net"); colorize(btn.sub.net, C.muted)
          btn.sub.vsmed:SetText("vs Fair"); colorize(btn.sub.vsmed, C.muted)
        else
          local ev = d.ev
          btn.zb:SetShown((r % 2) == 0); btn.key = d.id and tostring(d.id) or nil
          btn.sub.date:SetText(date("%b %d  %H:%M", ev.ts)); colorize(btn.sub.date, C.muted)
          local lab, lrgb = tradeKindLabel(ev.kind, ev.src, ev.id or d.id)
          btn.sub.kind:SetText(lab); colorize(btn.sub.kind, lrgb)
          local gross = ev.gross or 0
          local cnt = ev.count
          if (not cnt or cnt == 0) and ev.kind == "sold" and M.AuctionSize then cnt = M.AuctionSize(d.id, gross) end
          btn.sub.qty:SetText((cnt and cnt > 0) and ("x" .. cnt) or "\226\128\147"); colorize(btn.sub.qty, C.sub)
          local isRet = (ev.kind == "returned" or ev.kind == "cancelled" or ev.kind == "given" or ev.kind == "received")
          local unit = (cnt and cnt > 0 and gross > 0) and (gross / cnt) or nil
          if isRet then
            btn.sub.unit:SetText("\226\128\147"); colorize(btn.sub.unit, C.muted)
            btn.sub.total:SetText("\226\128\147"); colorize(btn.sub.total, C.muted)
            btn.sub.net:SetText("\226\128\147"); colorize(btn.sub.net, C.muted)
            btn.sub.vsmed:SetText("\226\128\147"); colorize(btn.sub.vsmed, C.muted)
          else
            btn.sub.unit:SetText(unit and M.MoneyPlain(unit) or "\226\128\147"); colorize(btn.sub.unit, unit and C.text or C.muted)
            btn.sub.total:SetText(M.MoneyPlain(gross)); colorize(btn.sub.total, C.sub)
            local net = ev.net or 0
            btn.sub.net:SetText((net >= 0 and "+" or "-") .. M.MoneyPlain(math.abs(net))); colorize(btn.sub.net, net >= 0 and C.green or C.red)
            -- vs median per unit, coloured by what's GOOD for that trade: a sell
            -- above median is green (sold high) / below red; a buy is reversed
            -- (bought below median = green). Within the threshold band = grey.
            local fd = unit and (fairOnDay(d.id, ev.day) or d.med) or nil
            if unit and fd and fd > 0 then
              local dl = unit / fd - 1
              btn.sub.vsmed:SetText(string.format("%+.0f%%", dl * 100))
              local good
              if dl >= M.C.PICK_DELTA then good = (ev.kind == "sold")
              elseif dl <= -M.C.PICK_DELTA then good = (ev.kind ~= "sold") end
              if good == true then colorize(btn.sub.vsmed, C.green)
              elseif good == false then colorize(btn.sub.vsmed, C.red)
              else colorize(btn.sub.vsmed, C.sub) end
            else
              btn.sub.vsmed:SetText("\226\128\147"); colorize(btn.sub.vsmed, C.muted)
            end
          end
        end
        btn:Show()
      else
        btn.key = nil; btn.expandKey = nil; btn:Hide()
      end
    end
    -- sticky header: pin the owning item + transaction labels while scrolled into a group
    local topd = disp[offset + 1]
    if topd and topd.t ~= "item" then
      local owner
      for i = offset + 1, 1, -1 do if disp[i].t == "item" then owner = disp[i].e; break end end
      if owner then
        local nm = owner.s.name or (owner.s.id and M.ItemName(tostring(owner.s.id))) or owner.key
        st.sticky.name:SetText("\226\150\188 " .. nm)
        st.sticky:Show()
      else st.sticky:Hide() end
    else
      st.sticky:Hide()
    end
    if total == 0 then
      st.sticky:Hide()
      M.FillChartCard(itemCard, nil)
      itemCard.title:SetText("No item stats yet"); colorize(itemCard.title, C.sub)
      itemCard.cat:SetText("open your mailbox after selling or buying \226\128\148 AH mail is logged automatically")
    elseif itemCard.shownKey or (list[1] and list[1].s.id) then
      M.FillChartCard(itemCard, itemCard.shownKey or tostring(list[1].s.id))
    end
  end

  function st.RefreshItem()
    buildItems(); st.FillItem()
  end

  -- ----- jumps in from other pages (Nav.lua) ------------------------------
  -- one item: By Item, searched by its name, its transactions unfolded
  local function setSearch(txt)
    txt = txt or ""
    if search.edit:GetText() ~= txt then
      search.edit:SetText(txt)          -- OnTextChanged sets st.search + refreshes
    end
    st.search = txt:lower()
  end
  function M.TradesFocus(key)
    local id = (M.BaseID and M.BaseID(key)) or tonumber(key)
    local _, sk = nil, nil
    if id and M.TradeEntryForID then _, sk = M.TradeEntryForID(id) end
    st.view = "item"; M.tradeView = "item"
    if M.db and M.db.config then M.db.config.tradeView = "item" end
    st.expanded = {}
    if sk then st.expanded[sk] = true end
    setSearch(id and M.ItemName(tostring(id)) or "")
    FauxScrollFrame_SetOffset(itemScroll, 0)
    local sb = _G["MidasTradeItemScrollScrollBar"]
    if sb then sb:SetValue(0) end
    if id then M.FillChartCard(itemCard, tostring(id)) end
  end
  -- what the Back pill needs to come back here
  function M.TradesState()
    local ex = {}
    for k, v in pairs(st.expanded) do ex[k] = v end
    return { view = st.view, search = search.edit:GetText() or "", expanded = ex }
  end
  function M.TradesRestore(view, txt, expanded)
    st.view = view or st.view; M.tradeView = st.view
    if M.db and M.db.config then M.db.config.tradeView = st.view end
    st.expanded = {}
    for k, v in pairs(expanded or {}) do st.expanded[k] = v end
    setSearch(txt)
  end

  function st.Refresh()
    -- holdings: value change of the item stock over the window - today's
    -- holdings value vs the frozen snapshot ~60 days back. The pair NET P/L +
    -- HOLDINGS makes buys stop reading as pure losses (the bought items stand
    -- on the other side). One NetWorth serves holdings + consumed.
    local nw2 = M.NetWorth and M.NetWorth()
    local hold, hRef
    if nw2 and M.HoldingsDelta then hold, hRef = M.HoldingsDelta(nw2, M.C.SELL_WINDOW) end
    local cons = nw2 and M.ConsumedCost and M.ConsumedCost(nw2, M.C.SELL_WINDOW)
    -- the trade window opens right after the holdings snapshot: a trade on
    -- the snapshot day is already inside it, so TOTAL = NET + HOLDINGS adds
    -- the same span on both sides
    local sm = M.TradeSummary(M.RealmKey(), M.C.SELL_WINDOW, hRef)
    local span = " \194\183 " .. (sm.days or M.C.SELL_WINDOW) .. "D"
    st.sNet.lbl:SetText("NET P/L" .. span)
    st.sHold.lbl:SetText("HOLDINGS" .. span)
    st.sTotal.lbl:SetText("TOTAL" .. span)
    st.sNet:SetText((sm.net >= 0 and "+" or "-") .. M.MoneyPlain(math.abs(sm.net)))
    colorize(st.sNet, sm.net >= 0 and C.green or C.red)
    if st.sCons then
      if cons and cons >= 10000 then
        st.sCons:SetText("\194\187 consumed " .. M.MoneyPlain(cons))
      else
        st.sCons:SetText("")
      end
    end
    if hold then
      st.sHold:SetText((hold >= 0 and "+" or "-") .. M.MoneyPlain(math.abs(hold)))
      colorize(st.sHold, hold >= 0 and C.green or C.red)
      local tot = sm.net + hold
      st.sTotal:SetText((tot >= 0 and "+" or "-") .. M.MoneyPlain(math.abs(tot)))
      colorize(st.sTotal, tot >= 0 and C.green or C.red)
    else
      st.sHold:SetText("\226\128\147"); colorize(st.sHold, C.muted)
      st.sTotal:SetText("\226\128\147"); colorize(st.sTotal, C.muted)
    end
    st.sGross:SetText(M.MoneyPlain(sm.grossSells)); colorize(st.sGross, C.text)
    st.sFees:SetText(M.MoneyPlain(sm.fees)); colorize(st.sFees, C.sub)
    st.sBuy:SetText(M.MoneyPlain(sm.buyCost)); colorize(st.sBuy, C.text)
    st.sFlow:SetText(sm.sold .. " / " .. sm.ret); colorize(st.sFlow, C.text)
    st.sRate:SetText(sm.sellThrough and string.format("%.0f%%", sm.sellThrough * 100) or "\226\128\147")
    colorize(st.sRate, C.accent)

    seg:Select(st.view)
    logView:SetShown(st.view == "log")
    itemView:SetShown(st.view == "item")
    if st.view == "log" then st.RefreshLog() else st.RefreshItem() end
  end

  M.RefreshTrades = st.Refresh
end

-- ===== Net Worth tab ========================================================
-- single source of truth lives in Charts.lua (M.CLASS_COLOR), so the asset-class
-- list and the stacked worth chart always use the same colors
local CLASS_COLOR = M.CLASS_COLOR or {
  Money = "accent", Crafting = "mint", Consumables = "green",
  Gear = "blue", Recipes = "red", Auctions = "purple", Other = "muted",
}

-- Breakdown tooltip anchored just outside the window (like ShowItemTip).
local function OpenInfoTip()
  if not M.frame then return end
  GameTooltip:SetOwner(M.frame, "ANCHOR_NONE")
  GameTooltip:ClearAllPoints()
  if (M.frame:GetRight() or 0) + 320 > GetScreenWidth() then
    GameTooltip:SetPoint("TOPRIGHT", M.frame, "TOPLEFT", -6, -2)
  else
    GameTooltip:SetPoint("TOPLEFT", M.frame, "TOPRIGHT", 6, -2)
  end
end
local function addKV(label, value, lc, rc)
  lc = lc or C.sub; rc = rc or C.text
  GameTooltip:AddDoubleLine(label, value, lc[1], lc[2], lc[3], rc[1], rc[2], rc[3])
end
local function addItemLine(id, qty, value)
  local qc = M.ItemQualityColor(tostring(id))
  GameTooltip:AddDoubleLine(M.ItemName(tostring(id)) .. "  x" .. (qty or 0), M.MoneyPlain(value),
    qc.r, qc.g, qc.b, 0.91, 0.92, 0.95)
end

-- ===== Net-Worth drill-down navigation ======================================
-- The Net Worth tab drills down along one consistent chain:
--   day (chart click) -> class -> character -> items -> one item's value history,
-- and every entry point (main lists, day view, class view) uses the same hops.
-- Only ONE overlay is visible at a time; opening a deeper one pushes the current
-- view on a stack, "< back" pops it -- so the path back always retraces the path in.
-- Earliest snapshot day that carries the given per-character table ("chars" /
-- "cc"): the drill-down notes name the user's REAL first recording day instead
-- of a date hardcoded from the developer's own archive.
local function firstSnapDay(field)
  local hist = M.NWHist()
  local best
  if hist then
    for day, s in pairs(hist) do
      if type(s) == "table" and type(s[field]) == "table" and next(s[field]) and (not best or day < best) then
        best = day
      end
    end
  end
  return best
end

-- copper -> compact gold string for the tight change columns
local function shortGold(c)
  local g = c / 10000
  local a = math.abs(g)
  if a >= 1000 then return string.format("%.1fkg", g / 1000)
  elseif a >= 10 then return string.format("%.0fg", g)
  else return string.format("%.1fg", g) end
end

-- inline color code from a palette entry (mixed-color single FontStrings)
local function hexC(c) return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255) end

-- THE delta format of the Net Worth tab: one glyph for "nothing worth
-- mentioning" (under 0.1g -- shortGold would print a misleading "+0.0g"),
-- signed compact gold otherwise. deltaColor pairs it for colorize().
local function fmtDelta(v)
  if not v or math.abs(v) < 1000 then return "\226\128\147" end
  return ((v >= 0) and "+" or "-") .. shortGold(math.abs(v))
end
local function deltaColor(v)
  if not v or math.abs(v) < 1000 then return C.muted end
  return (v >= 0) and C.green or C.red
end
-- the attribution's sanity band (Wealth.WorthAttribution): a reconstructed
-- reference price may not leave x10 around today's valuation
local function bandRef(pR, pH)
  if pR > pH * 10 then return pH * 10 elseif pR < pH / 10 then return pH / 10 end
  return pR
end

function M.NWNavPush(fr)
  M._nwStack = M._nwStack or {}
  local w = M.wealth
  if w then
    for _, v in ipairs({ w.itemView, w.dayView, w.classView, w.itemWorth, w.moversView }) do
      if v and v ~= fr and v:IsShown() then
        M._nwStack[#M._nwStack + 1] = v
        v:Hide()
        break
      end
    end
  end
  fr:Show()
  if M.UpdateChartToggles then M.UpdateChartToggles() end
end

function M.NWNavBack(fr)
  fr:Hide()
  local st = M._nwStack
  local prev = st and table.remove(st)
  if prev then prev:Show() end
  if M.UpdateChartToggles then M.UpdateChartToggles() end
end

function M.NWNavReset()
  M._nwStack = {}
  local w = M.wealth
  if w then
    for _, v in ipairs({ w.itemView, w.dayView, w.classView, w.itemWorth, w.moversView }) do
      if v then v:Hide() end
    end
  end
  if M.UpdateChartToggles then M.UpdateChartToggles() end
end

-- Moving a character to the graveyard (HC deaths) is fully reversible, so a
-- simple yes/no confirms it -- unlike the old permanent delete with its typed
-- DELETE unlock.
StaticPopupDialogs["MIDAS_GRAVEYARD_CHAR"] = {
  text = "Move %s to the graveyard?\n\nA fallen character stops counting toward the account total and rests in the graveyard sum instead. Nothing is deleted: its items stay browsable, and Restore (or logging in alive) brings it back.",
  button1 = YES or "Yes",
  button2 = NO or "No",
  timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
  OnAccept = function(self)
    if M.GraveyardChar then M.GraveyardChar(self.data) end
  end,
}

-- Deleting net-worth days cannot be undone: the popup names the day and offers
-- both scopes -- this day only, or this day and every earlier one.
StaticPopupDialogs["MIDAS_FORGET_WORTH"] = {
  text = "Delete net worth history?\n\n%s only, or %s and every day before it - for example beta days that ended up in your live history. Characters, items and trades stay. This cannot be undone.",
  button1 = "This day",
  button3 = "And all before",
  button2 = CANCEL or "Cancel",
  timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
  OnAccept = function(self) if M.ForgetWorthDays then M.ForgetWorthDays(self.data, false) end end,
  OnAlt = function(self) if M.ForgetWorthDays then M.ForgetWorthDays(self.data, true) end end,
}

function M.BuildWealth(panel)
  local w = {}; M.wealth = w
  local lbl = T.Text(panel, T.SIZE.tiny, "muted", T.FONT_MED)
  lbl:SetPoint("TOPLEFT", 2, -2); lbl:SetText("NET WORTH \194\183 ALL CHARACTERS   \194\183   hover any value for its breakdown")
  w.total = T.Text(panel, 26, "text", T.FONT_SEMI); w.total:SetPoint("TOPLEFT", 0, -14)
  -- two fixed-width lines: the headline delta and, below it, the decomposition.
  -- Width-capped at 350 so they can never run under the movers columns again.
  w.delta = T.Text(panel, T.SIZE.body, "sub"); w.delta:SetPoint("TOPLEFT", 2, -48); w.delta:SetWidth(350); w.delta:SetJustifyH("LEFT")
  w.deltaSub = T.Text(panel, T.SIZE.tiny, "sub"); w.deltaSub:SetPoint("TOPLEFT", 2, -60); w.deltaSub:SetWidth(350); w.deltaSub:SetJustifyH("LEFT")

  -- hover the big total -> split by gold / items / auctions + per character
  w.totalBtn = CreateFrame("Button", nil, panel)
  w.totalBtn:SetPoint("TOPLEFT", 0, -10); w.totalBtn:SetSize(340, 38)
  w.totalBtn:SetScript("OnEnter", function()
    local nw = w.nw; if not nw then return end
    OpenInfoTip()
    GameTooltip:AddLine("Net worth \194\183 all characters", 1, 1, 1)
    addKV("Gold", M.MoneyPlain(nw.money), C.sub, C.accent)
    addKV("Items", M.MoneyPlain(nw.itemsTotal))
    addKV("On auctions", M.MoneyPlain(nw.auctionsTotal), C.sub, C.purple)
    if (nw.graveCount or 0) > 0 then
      GameTooltip:AddLine(" ")
      addKV("Graveyard (" .. nw.graveCount .. ")", M.MoneyPlain(nw.graveTotal or 0), C.muted, C.muted)
    end
    GameTooltip:Show()
  end)
  w.totalBtn:SetScript("OnLeave", HideTip)

  -- top gainers / losers over the shared timeframe, in the hero band's free
  -- room; click opens the item's holding history, the link the full breakdown
  local gh = T.Text(panel, T.SIZE.tiny, "muted", T.FONT_MED)
  gh:SetPoint("TOPLEFT", 360, -4); gh:SetText("TOP GAINERS")
  local lh = T.Text(panel, T.SIZE.tiny, "muted", T.FONT_MED)
  lh:SetPoint("TOPLEFT", 580, -4); lh:SetText("TOP LOSERS")
  w.mvHeads = { gh, lh }
  local function miniTip(self)
    local e = self.e; if not e then return end
    OpenInfoTip()
    local qc = M.ItemQualityColor(tostring(e.id))
    GameTooltip:AddLine(M.ItemName(tostring(e.id)), qc.r, qc.g, qc.b)
    -- \194\187 (Latin-1 raquo): the GameTooltip font has no U+2192 arrow glyph
    addKV("Quantity", string.format("%d \194\187 %d", e.qR, e.qH))
    -- itemized window: held today - start + sold - bought = Total, line by
    -- line re-checkable (the Consumed line is PART of Bought, not added again)
    if (e.qR or 0) > 0 then
      addKV("Start value", string.format("%d x %s  =  %s", e.qR,
        M.MoneyPlain(math.floor(e.pR or 0)), M.MoneyPlain(math.floor(e.qR * (e.pR or 0)))), C.sub, C.sub)
    end
    if (e.buyQ or 0) > 0 then
      addKV("Bought", string.format("%d x %s  =  -%s", e.buyQ,
        M.MoneyPlain(math.floor(e.buyC / e.buyQ)), M.MoneyPlain(e.buyC)), C.sub, C.red)
    end
    if (e.sellQ or 0) > 0 then
      addKV("Sold", string.format("%d  \194\183  +%s net", e.sellQ, M.MoneyPlain(e.sellN or 0)), C.sub, C.green)
    end
    if (e.cons or 0) > 0 then
      addKV("Consumed", string.format("%d x %s  (in Bought)", e.cons,
        M.MoneyPlain(math.floor(e.consCost / e.cons))), C.muted, C.muted)
    end
    if (e.qH or 0) > 0 then
      addKV("Held today", string.format("%d x %s  =  %s", e.qH,
        M.MoneyPlain(math.floor(e.pH or 0)), M.MoneyPlain(math.floor(e.qH * (e.pH or 0)))), C.sub, C.sub)
    end
    addKV("Market effect", (e.dMarket >= 0 and "+" or "-") .. M.MoneyPlain(math.abs(e.dMarket)),
      C.sub, e.dMarket >= 0 and C.green or C.red)
    addKV("Total P/L", (e.pnl >= 0 and "+" or "-") .. M.MoneyPlain(math.abs(e.pnl)),
      C.sub, e.pnl >= 0 and C.green or C.red)
    if (e.cons or 0) > 0 then
      local tp = e.pnl + e.consCost
      addKV("Trading P/L", (tp >= 0 and "+" or "-") .. M.MoneyPlain(math.abs(tp)) .. "  (consumption excluded)",
        C.sub, tp >= 0 and C.green or C.red)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: holding history \194\183 shift: market chart \194\183 right-click: all pages", C.muted[1], C.muted[2], C.muted[3])
    GameTooltip:Show()
  end
  local function wireMini(btn)
    btn:SetScript("OnEnter", miniTip)
    btn:SetScript("OnLeave", HideTip)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(self, mouse)
      local e = self.e; if not e then return end
      HideTip()
      if ItemMenuClick(mouse, tostring(e.id)) then return end
      if M.ModPostDown() then M.PostItemStats(tostring(e.id)); return end
      if M.ModSearchDown() then GoChart(tostring(e.id)); return end
      if M.ShowItemWorth then M.ShowItemWorth(tostring(e.id), e.qH or 0) end
    end)
  end
  -- the rich character hover, shared by the main list, the class drill-down
  -- and the day drill-down (self.key or self.ck names the character)
  local function charTip(self)
    local key = self.key or self.ck; if not key then return end
    local a = M.CharAssets(key); if not a then return end
    OpenInfoTip()
    GameTooltip:AddLine(a.name, 1, 1, 1)
    addKV("Total", M.MoneyPlain(a.total), C.sub, C.accent)
    local nwTotal = w.nw and w.nw.total
    if nwTotal and nwTotal > 0 then
      addKV("Share of total", string.format("%.1f%%", a.total / nwTotal * 100))
    end
    if M.CharDeltaSince then
      -- same reference day as every change column on this tab
      local rday = w.attrib and w.attrib.refDay or nil
      local dd, refDay = M.CharDeltaSince(key, a.total, rday)
      if dd == nil and rday then dd, refDay = M.CharDeltaSince(key, a.total) end
      if dd and refDay then
        addKV("Change since " .. M.DayLabel(refDay),
          (dd >= 0 and "+" or "-") .. M.MoneyPlain(math.abs(dd)), C.sub, dd >= 0 and C.green or C.red)
      else
        addKV("Change", "history starts now", C.sub, C.muted)
      end
    end
    GameTooltip:AddLine(" ")
    addKV("Gold", M.MoneyPlain(a.money))
    if a.itemsTotal > 0 then addKV("Items", M.MoneyPlain(a.itemsTotal)) end
    if a.auctionsTotal > 0 then addKV("On auctions", M.MoneyPlain(a.auctionsTotal), C.sub, C.purple) end
    if #a.items > 0 then
      GameTooltip:AddLine(" "); GameTooltip:AddLine("Top items", C.muted[1], C.muted[2], C.muted[3])
      for k = 1, math.min(#a.items, 8) do addItemLine(a.items[k].id, a.items[k].qty, a.items[k].value) end
    end
    if #a.auctions > 0 then
      GameTooltip:AddLine(" "); GameTooltip:AddLine("On auctions", C.muted[1], C.muted[2], C.muted[3])
      for k = 1, math.min(#a.auctions, 6) do addItemLine(a.auctions[k].id, a.auctions[k].qty, a.auctions[k].value) end
    end
    GameTooltip:Show()
  end
  w.charTip = charTip

  local function mkMiniRows(x)
    local rows = {}
    for i = 1, 3 do
      local y = -16 - (i - 1) * 15
      local r = {}
      r.name = T.Text(panel, T.SIZE.small); r.name:SetPoint("TOPLEFT", x, y); r.name:SetWidth(132)
      r.val = T.Text(panel, T.SIZE.small, "sub", T.FONT_MED)
      r.val:SetPoint("TOPLEFT", x + 136, y); r.val:SetWidth(70); r.val:SetJustifyH("RIGHT")
      r.btn = CreateFrame("Button", nil, panel)
      r.btn:SetPoint("TOPLEFT", x - 2, y + 2); r.btn:SetSize(212, 14)
      local hl = r.btn:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.04)
      wireMini(r.btn)
      rows[i] = r
    end
    return rows
  end
  w.gainRows = mkMiniRows(360)
  w.loseRows = mkMiniRows(580)
  local wm = CreateFrame("Button", nil, panel)
  local wmf = T.Text(wm, T.SIZE.small, "accent", T.FONT_MED)
  wmf:SetPoint("LEFT", 0, 0); wmf:SetText("what moved? \226\128\186")
  wm:SetSize(100, 16); wm:SetPoint("TOPLEFT", 800, -4)   -- header row, clear of the range segment
  wm:SetScript("OnEnter", function() wmf:SetTextColor(T.Unpack(C.text)) end)
  wm:SetScript("OnLeave", function() wmf:SetTextColor(T.Unpack(C.accent)) end)
  wm:SetScript("OnClick", function() if M.ShowMovers then M.ShowMovers() end end)
  if T.HelpTip then
    T.HelpTip(wm, "What moved it", {
      "The full account-wide breakdown of the change over the selected timeframe: every item's quantity and market effect, realized trading, gold - down to an honest rest." }, "ANCHOR_CURSOR")
  end
  w.whatMoved = wm
  -- the delta + decomposition lines open the breakdown too (350 wide: must
  -- never cover the movers rows next to them)
  local db = CreateFrame("Button", nil, panel)
  db:SetPoint("TOPLEFT", 0, -46); db:SetSize(350, 26)
  db:SetScript("OnClick", function() if M.ShowMovers then M.ShowMovers() end end)
  w.deltaBtn = db

  local chart = CreateFrame("Frame", nil, panel)
  chart:SetPoint("TOPLEFT", 0, -72); chart:SetPoint("TOPRIGHT", 0, -72); chart:SetHeight(170)
  w.chart = chart
  -- timeframe switch for the history chart (shared with the Charts tab)
  local rangeSeg = makeRangeSeg(panel)
  rangeSeg.frame:SetPoint("TOPRIGHT", 0, -44)
  -- scrubbing the history chart shows each character AS OF that day + the change to now
  chart._onHover = function(best) if M.FillCharRows then M.FillCharRows(best.day) end end
  chart._onHoverEnd = function() if M.FillCharRows then M.FillCharRows(nil) end end

  -- everything below the history chart hangs off this anchor: when the window
  -- is taller, RefreshWealth grows the chart and slides the anchor down
  local low = CreateFrame("Frame", nil, panel)
  low:SetPoint("TOPLEFT", 0, -252); low:SetSize(1, 1)
  w.lowerAnchor = low
  local clsHint = T.Text(panel, T.SIZE.tiny, "muted", T.FONT_MED)
  clsHint:SetPoint("TOPLEFT", low, "TOPLEFT", 2, 0); clsHint:SetText("BY ASSET CLASS")
  w.classHint = clsHint
  w.classRows = {}
  for i = 1, 7 do
    local y = -20 - (i - 1) * 21
    local r = {}
    r.name = T.Text(panel, T.SIZE.body, "text"); r.name:SetPoint("TOPLEFT", low, "TOPLEFT", 4, y); r.name:SetWidth(92)
    local bgt = panel:CreateTexture(nil, "ARTWORK"); bgt:SetColorTexture(1, 1, 1, 0.05)
    bgt:SetPoint("TOPLEFT", low, "TOPLEFT", 100, y - 1); bgt:SetSize(150, 11)
    r.bar = panel:CreateTexture(nil, "OVERLAY"); r.bar:SetPoint("TOPLEFT", low, "TOPLEFT", 100, y - 1); r.bar:SetSize(1, 11)
    r.val = T.Text(panel, T.SIZE.body, "text", T.FONT_MED); r.val:SetPoint("TOPLEFT", low, "TOPLEFT", 258, y); r.val:SetWidth(96); r.val:SetJustifyH("RIGHT")
    r.pct = T.Text(panel, T.SIZE.small, "muted"); r.pct:SetPoint("TOPLEFT", low, "TOPLEFT", 358, y); r.pct:SetWidth(36); r.pct:SetJustifyH("RIGHT")
    r.chg = T.Text(panel, T.SIZE.small, "muted", T.FONT_MED); r.chg:SetPoint("TOPLEFT", low, "TOPLEFT", 400, y); r.chg:SetWidth(104); r.chg:SetJustifyH("RIGHT")
    r.btn = CreateFrame("Button", nil, panel)
    r.btn:SetPoint("TOPLEFT", low, "TOPLEFT", 2, y + 2); r.btn:SetSize(504, 16)
    local hl = r.btn:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.04)
    r.btn:SetScript("OnEnter", function(self)
      local nw, cls = w.nw, self.cls
      if not nw or not cls then return end
      OpenInfoTip()
      GameTooltip:AddLine(cls .. " \194\183 asset class", 1, 1, 1)
      addKV("Subtotal", M.MoneyPlain(nw.classes[cls] or 0), C.sub, (C[CLASS_COLOR[cls]] or C.text))
      local items = nw.classItems and nw.classItems[cls]
      if items and #items > 0 then
        GameTooltip:AddLine(" ")
        for k = 1, #items do addItemLine(items[k].id, items[k].qty, items[k].value) end
      elseif cls == "Money" then
        GameTooltip:AddLine(" "); GameTooltip:AddLine("Liquid gold across all characters.", C.muted[1], C.muted[2], C.muted[3], true)
      else
        GameTooltip:AddLine(" "); GameTooltip:AddLine("no items", C.muted[1], C.muted[2], C.muted[3])
      end
      if cls == "Auctions" then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Value still listed on the AH, discounted by how likely each lot is to sell.", C.muted[1], C.muted[2], C.muted[3], true)
      end
      GameTooltip:Show()
    end)
    r.btn:SetScript("OnLeave", HideTip)
    r.btn:SetScript("OnClick", function(self)
      if self.cls and M.ShowWorthClass then HideTip(); M.ShowWorthClass(self.cls) end
    end)
    w.classRows[i] = r
  end

  -- separator only next to the lists (the old full-height line cut through
  -- the hero and the chart)
  local vl = vline(panel, 516)
  vl:ClearAllPoints()
  vl:SetPoint("TOPLEFT", low, "TOPLEFT", 516, 2)
  vl:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 516, 0)
  local ct = T.Text(panel, T.SIZE.tiny, "muted", T.FONT_MED)
  ct:SetPoint("TOPLEFT", low, "TOPLEFT", 532, 0); ct:SetWidth(362); ct:SetJustifyH("LEFT"); ct:SetText("BY CHARACTER  \194\183  change")
  w.charHint = ct
  w.charRows = {}
  local function mkCharRow(i)
    local y = -20 - (i - 1) * 17
    local r = {}
    r.name = T.Text(panel, T.SIZE.body, "text"); r.name:SetPoint("TOPLEFT", low, "TOPLEFT", 532, y); r.name:SetWidth(146)
    r.val = T.Text(panel, T.SIZE.body, "sub", T.FONT_MED); r.val:SetPoint("TOPLEFT", low, "TOPLEFT", 676, y); r.val:SetWidth(92); r.val:SetJustifyH("RIGHT")
    r.chg = T.Text(panel, T.SIZE.small, "muted", T.FONT_MED); r.chg:SetPoint("TOPLEFT", low, "TOPLEFT", 772, y); r.chg:SetWidth(122); r.chg:SetJustifyH("RIGHT")
    r.btn = CreateFrame("Button", nil, panel)
    r.btn:SetPoint("TOPLEFT", low, "TOPLEFT", 530, y + 2); r.btn:SetSize(364, 15)
    local hl = r.btn:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.04)
    r.btn:SetScript("OnEnter", charTip)
    r.btn:SetScript("OnLeave", HideTip)
    r.btn:SetScript("OnClick", function(self)
      if self.key and M.ShowCharItems then HideTip(); M.ShowCharItems(self.key) end
    end)
    w.charRows[i] = r
  end
  w.mkCharRow = mkCharRow
  for i = 1, 8 do mkCharRow(i) end

  -- graveyard sum: the fallen characters' collected worth, kept OUT of the
  -- account total. Click to flip the list above between living and fallen.
  -- Anchored under the LAST VISIBLE character row by RefreshWealth (the list
  -- is elastic now), so it can never overflow the panel again.
  local gy = CreateFrame("Button", nil, panel)
  gy:SetPoint("TOPLEFT", low, "TOPLEFT", 530, -158); gy:SetSize(364, 16)
  local ghl = gy:CreateTexture(nil, "HIGHLIGHT"); ghl:SetAllPoints(); ghl:SetColorTexture(1, 1, 1, 0.04)
  gy.lbl = T.Text(panel, T.SIZE.small, "muted", T.FONT_MED)
  gy.lbl:SetPoint("LEFT", gy, "LEFT", 2, 0)
  gy.val = T.Text(panel, T.SIZE.body, "sub", T.FONT_MED)
  gy.val:SetPoint("LEFT", gy, "LEFT", 146, 0); gy.val:SetWidth(92); gy.val:SetJustifyH("RIGHT")
  gy:SetScript("OnClick", function()
    w.graveView = not w.graveView
    if M.FillCharRows then M.FillCharRows(nil) end
  end)
  if T.HelpTip then
    T.HelpTip(gy, "Graveyard", {
      "The collected worth of your fallen (graveyard) characters - kept OUT of the account total on purpose.",
      "Click to flip the list above between living characters and the graveyard; click a fallen character to browse its items or restore it." })
  end
  gy:Hide(); gy.lbl:Hide(); gy.val:Hide()
  w.graveRow = gy

  -- ===== per-character item drill-down ======================================
  -- Clicking a character covers the tab with a full list of everything that
  -- character owns (bags+bank+mail merged; active auctions tagged "AH"), valued
  -- like Net Worth and sorted by value. Click a row for its chart, Back returns.
  local iv = CreateFrame("Frame", nil, panel)
  iv:SetAllPoints()
  iv:SetFrameLevel(panel:GetFrameLevel() + 30)
  local ivbg = iv:CreateTexture(nil, "BACKGROUND")
  ivbg:SetAllPoints(); ivbg:SetColorTexture(C.bg0[1], C.bg0[2], C.bg0[3], 1)
  iv:EnableMouse(true)                      -- swallow input meant for the view below
  iv.title = T.Text(iv, T.SIZE.h2 + 2, "text", T.FONT_SEMI)
  iv.title:SetPoint("TOPLEFT", 2, -4)
  iv.sub = T.Text(iv, T.SIZE.small, "sub")
  iv.sub:SetPoint("TOPLEFT", 2, -27)
  local ivBack = T.Button(iv, "< back", 88, 22)
  ivBack:SetPoint("TOPRIGHT", -2, -2)
  ivBack:SetScript("OnClick", function() M.NWNavBack(iv) end)
  if T.HelpTip then T.HelpTip(ivBack, "Back", { "One step back in the drill-down - it retraces exactly the path you came in on." }) end

  -- move this character to the graveyard (HC deaths) or bring it back; the
  -- label follows the character's state (set in FillCharItems)
  local ivGrave = T.Button(iv, "Move to graveyard\226\128\166", 160, 22)
  ivGrave:SetPoint("TOPRIGHT", ivBack, "TOPLEFT", -8, 0)
  ivGrave:SetScript("OnClick", function()
    if not iv.charKey then return end
    local c = M.db and M.db.chars and M.db.chars[iv.charKey]
    if c and c.dead then
      if M.ReviveChar then M.ReviveChar(iv.charKey); M.FillCharItems() end
    else
      local a = M.CharAssets and M.CharAssets(iv.charKey)
      StaticPopup_Show("MIDAS_GRAVEYARD_CHAR", (a and a.name) or iv.charKey, nil, iv.charKey)
    end
  end)
  iv.graveBtn = ivGrave
  if T.HelpTip then
    T.HelpTip(ivGrave, "Graveyard", {
      "Moves this character to the graveyard (for HC deaths): it stops counting toward the account total and rests in a separate graveyard sum. Nothing is deleted - its items stay browsable from the graveyard list.",
      "On a graveyard character this button restores it instead. Logging in ALIVE on the character also revives it automatically - a ghost login leaves it resting." })
  end

  -- asset-allocation chips: filter the item list by class ("All" + the classes).
  -- This is the "character -> asset allocation -> items" hop of the drill-down.
  iv.chips = {}
  do
    local cx = 2
    for _, name in ipairs({ "All", "Crafting", "Consumables", "Gear", "Recipes", "Auctions", "Other" }) do
      local b = CreateFrame("Button", nil, iv)
      local fs = b:CreateFontString(nil, "OVERLAY")
      T.RegFont(fs, T.FONT_MED, T.SIZE.small); fs:SetPoint("LEFT", 0, 0); fs:SetText(name)
      fs:SetTextColor(T.Unpack(C.sub))
      b:SetSize(fs:GetStringWidth() + 14, 16)
      b:SetPoint("TOPLEFT", cx, -44)
      b.fs, b.cls = fs, (name ~= "All") and name or nil
      b:SetScript("OnClick", function(self)
        iv.clsFilter = self.cls
        if M.FillCharItems then M.FillCharItems() end
      end)
      b:SetScript("OnEnter", function(self) self.fs:SetTextColor(T.Unpack(C.text)) end)
      b:SetScript("OnLeave", function(self)
        local active = (iv.clsFilter == self.cls)
        self.fs:SetTextColor(T.Unpack(active and C.accent or C.sub))
      end)
      if T.HelpTip then
        T.HelpTip(b, name, { b.cls and ("Filter this character's items to the " .. name .. " class.")
                                    or "Show all of this character's items." })
      end
      iv.chips[#iv.chips + 1] = b
      cx = cx + b:GetWidth() + 10
    end
  end

  -- the character's own worth history: total line + cumulative class stack
  -- (the class split records from now on and fills in day by day)
  local ivChart = CreateFrame("Frame", nil, iv)
  ivChart:SetPoint("TOPLEFT", 0, -64)
  ivChart:SetPoint("TOPRIGHT", -10, -64)   -- elastic width
  ivChart:SetHeight(114)
  iv.chart = ivChart

  local IV_COLS = {
    { name = "Item",  w = 300, just = "LEFT" },
    { name = "",      w = 40,  just = "LEFT" },   -- "AH" tag for active auctions
    { name = "Qty",   w = 56,  just = "RIGHT" },
    { name = "Unit",  w = 104, just = "RIGHT" },
    { name = "Value", w = 116, just = "RIGHT" },
    { name = "Share", w = 56,  just = "RIGHT" },
    { name = "Mkt \206\148", w = 96, just = "RIGHT",
      help = "How the market moved under this character's CURRENT holdings over the selected timeframe (quantity x price change). Per-character quantity history isn't recorded - the quantity effect lives in the account-wide 'what moved?' view." },
  }
  -- header + list hang off this anchor; FillCharItems grows the chart into
  -- the extra room, slides the anchor down and adds rows for what is left
  local ivLow = CreateFrame("Frame", nil, iv)
  ivLow:SetPoint("TOPLEFT", 0, -186); ivLow:SetSize(1, 1)
  iv.lower = ivLow
  do
    local hx = 0
    for _, d in ipairs(IV_COLS) do
      local h = cell(iv, hx, 0, d.w, d.just, T.SIZE.tiny, "muted", T.FONT_MED)
      h:ClearAllPoints(); h:SetPoint("TOPLEFT", ivLow, "TOPLEFT", hx, 0)
      h:SetText(d.name:upper())
      if d.help and T.HelpTip then
        local hb = CreateFrame("Button", nil, iv)
        hb:SetPoint("TOPLEFT", ivLow, "TOPLEFT", hx, 2); hb:SetSize(d.w, 14)
        T.HelpTip(hb, d.name, { d.help }, "ANCHOR_TOP")
      end
      hx = hx + d.w + 6
    end
  end
  local IV_ROWS, IV_ROWH = 12, 18
  local ivScroll = CreateFrame("ScrollFrame", "MidasCharItemsScroll", iv, "FauxScrollFrameTemplate")
  ivScroll:SetPoint("TOPLEFT", ivLow, "TOPLEFT", 0, -16)
  ivScroll:SetPoint("BOTTOMRIGHT", iv, "BOTTOMLEFT", 812, 4)
  local function ivWheel(_, delta)
    local sb = _G["MidasCharItemsScrollScrollBar"]
    if sb then sb:SetValue(sb:GetValue() - delta * IV_ROWH * 2) end
  end
  ivScroll:EnableMouseWheel(true); ivScroll:SetScript("OnMouseWheel", ivWheel)
  ivScroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, IV_ROWH, function()
      if M.FillCharItems then M.FillCharItems() end
    end)
  end)
  T.StyleScrollbar("MidasCharItemsScroll")
  local ivRows = {}
  local function mkIvRow(r)
    local btn = CreateFrame("Button", nil, iv)
    btn:SetSize(804, IV_ROWH)
    btn:SetPoint("TOPLEFT", ivLow, "TOPLEFT", 0, -16 - (r - 1) * IV_ROWH)
    local zb = btn:CreateTexture(nil, "BACKGROUND"); zb:SetAllPoints(); zb:SetColorTexture(1, 1, 1, 0.02); zb:Hide(); btn.zb = zb
    local hl = btn:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.05)
    local fs, cx = {}, 0
    for i, d in ipairs(IV_COLS) do fs[i] = cell(btn, cx, -3, d.w, d.just, T.SIZE.body); cx = cx + d.w + 6 end
    btn.fs = fs
    btn:EnableMouseWheel(true); btn:SetScript("OnMouseWheel", ivWheel)
    btn:SetScript("OnEnter", function() if btn.key then ShowItemTip(btn.key) end end)
    btn:SetScript("OnLeave", HideTip)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, mouse)
      if not btn.key then return end
      -- drill-down chain: click = this item's holding-value history;
      -- Shift-click = the full market chart; alt posts its price card;
      -- right-click = the item menu with every page
      if ItemMenuClick(mouse, btn.key) then return end
      if M.ModPostDown() then M.PostItemStats(btn.key); return end
      if M.ModSearchDown() then
        GoChart(btn.key)
      elseif M.ShowItemWorth then
        HideTip(); M.ShowItemWorth(btn.key, btn.qty or 0, "this character")
      end
    end)
    ivRows[r] = btn
  end
  for r = 1, IV_ROWS do mkIvRow(r) end
  w.itemView = iv
  iv:Hide()

  function M.FillCharItems()
    local ck = iv.charKey; if not ck then return end
    local a = M.CharAssets(ck); if not a then return end
    -- taller window: chart grows, the item list slides down and shows more rows
    local ex = extraH(M.panels and M.panels[TAB["Net Worth"]])
    local grow = math.min(math.floor(ex * 0.45), 240)
    ivChart:SetHeight(114 + grow)
    ivLow:SetPoint("TOPLEFT", 0, -(186 + grow))
    local vis = availRows(M.panels and M.panels[TAB["Net Worth"]], 186 + grow + 24, IV_ROWH, 6)
    for r = #ivRows + 1, vis do mkIvRow(r) end
    if iv.chart and M.RenderNetWorthChart then M.RenderNetWorthChart(iv.chart, ck) end
    local filter = iv.clsFilter
    local cdead = M.db and M.db.chars and M.db.chars[ck] and M.db.chars[ck].dead
    iv.title:SetText((a.name or "?") .. (filter and ("   \194\183   " .. filter) or "")
      .. (cdead and "   \194\183   graveyard" or ""))
    if iv.graveBtn and iv.graveBtn.text then
      iv.graveBtn.text:SetText(cdead and "Restore from graveyard" or "Move to graveyard\226\128\166")
      iv.graveBtn.text:SetTextColor(T.Unpack(cdead and C.green or C.sub))
    end
    -- make sure the attribution (and its cached reference prices) is current,
    -- then show this character's change over the shared timeframe
    local at2 = w.attrib or (M.WorthAttribution and M.WorthAttribution(w.nw))
    local pmap = (at2 and M._nwAttrib and M._nwAttrib.p) or nil
    iv._refDay = at2 and at2.refDay or nil
    local chg = ""
    if at2 and M.CharDeltaSince then
      local dd = M.CharDeltaSince(ck, a.total, at2.refDay)
      if dd then
        chg = string.format("   \194\183   since %s  %s", M.DayLabel(at2.refDay), fmtDelta(dd))
      end
    end
    iv.sub:SetText(string.format("Total %s   \194\183   Gold %s   \194\183   Items %s   \194\183   On auctions %s%s",
      M.MoneyPlain(a.total), M.MoneyPlain(a.money), M.MoneyPlain(a.itemsTotal), M.MoneyPlain(a.auctionsTotal), chg))
    for _, chip in ipairs(iv.chips or {}) do
      chip.fs:SetTextColor(T.Unpack((iv.clsFilter == chip.cls) and C.accent or C.sub))
    end
    local list = {}
    for _, e in ipairs(a.items) do
      if not filter or (filter ~= "Auctions" and (e.cls or "Other") == filter) then
        list[#list + 1] = { id = e.id, qty = e.qty, value = e.value }
      end
    end
    for _, e in ipairs(a.auctions) do
      if not filter or filter == "Auctions" then
        list[#list + 1] = { id = e.id, qty = e.qty, value = e.value, ah = true }
      end
    end
    table.sort(list, function(x, y) return x.value > y.value end)
    local total = #list
    FauxScrollFrame_Update(ivScroll, total, vis, IV_ROWH)
    local offset = math.min(FauxScrollFrame_GetOffset(ivScroll), math.max(0, total - vis))
    for r = 1, #ivRows do
      local btn = ivRows[r]
      local e = (r <= vis) and list[r + offset] or nil
      if e then
        local key = tostring(e.id)
        btn.key = key
        btn.qty = e.qty
        btn.zb:SetShown((r % 2) == 0)
        local q = M.ItemQualityColor(key)
        btn.fs[1]:SetText(M.ItemName(key)); btn.fs[1]:SetTextColor(q.r, q.g, q.b)
        btn.fs[2]:SetText(e.ah and "AH" or ""); colorize(btn.fs[2], C.purple)
        btn.fs[3]:SetText((e.qty and e.qty > 0) and ("x" .. e.qty) or "\226\128\147"); colorize(btn.fs[3], C.sub)
        btn.fs[4]:SetText((e.qty and e.qty > 0) and M.MoneyPlain(e.value / e.qty) or "\226\128\147"); colorize(btn.fs[4], C.sub)
        btn.fs[5]:SetText(M.MoneyPlain(e.value)); colorize(btn.fs[5], C.text)
        btn.fs[6]:SetText((a.total > 0) and string.format("%.0f%%", e.value / a.total * 100) or ""); colorize(btn.fs[6], C.muted)
        -- market effect on this character's CURRENT stack over the window.
        -- AH rows: e.value is SellChance-discounted, price the units directly.
        local dm
        local pR = pmap and pmap[e.id]
        if pR and e.qty and e.qty > 0 then
          local pH = e.ah and (M.ItemValue and M.ItemValue(e.id) or 0) or (e.value / e.qty)
          if pH > 0 then dm = e.qty * (pH - bandRef(pR, pH)) end
        end
        btn.fs[7]:SetText(fmtDelta(dm)); colorize(btn.fs[7], deltaColor(dm))
        btn:Show()
      else
        btn.key = nil; btn.qty = nil; btn:Hide()
      end
    end
    if total == 0 then
      local btn = ivRows[1]
      btn.zb:Hide(); btn.key = nil
      for i = 1, #IV_COLS do btn.fs[i]:SetText("") end
      btn.fs[1]:SetText("no items cached for this character yet \226\128\148 log in with it once")
      colorize(btn.fs[1], C.muted)
      btn:Show()
    end
  end

  function M.ShowCharItems(ck, clsFilter)
    iv.charKey = ck
    iv.clsFilter = clsFilter
    local sb = _G["MidasCharItemsScrollScrollBar"]
    if sb then sb:SetValue(0) end
    M.FillCharItems()
    M.NWNavPush(iv)
  end

  -- ===== day drill-down =====================================================
  -- Clicking a day in the history chart covers the tab with that day's snapshot:
  -- the asset-class split and the per-character split AS OF that day, each with
  -- its change to today -- "where did the gold sit back then, and what moved?".
  local dv = CreateFrame("Frame", nil, panel)
  dv:SetAllPoints()
  dv:SetFrameLevel(panel:GetFrameLevel() + 40)
  local dvbg = dv:CreateTexture(nil, "BACKGROUND")
  dvbg:SetAllPoints(); dvbg:SetColorTexture(C.bg0[1], C.bg0[2], C.bg0[3], 1)
  dv:EnableMouse(true)
  dv.title = T.Text(dv, T.SIZE.h2 + 2, "text", T.FONT_SEMI)
  dv.title:SetPoint("TOPLEFT", 2, -4)
  dv.sub = T.Text(dv, T.SIZE.small, "sub")
  dv.sub:SetPoint("TOPLEFT", 2, -27)
  local dvBack = T.Button(dv, "< back", 88, 22)
  dvBack:SetPoint("TOPRIGHT", -2, -2)
  dvBack:SetScript("OnClick", function() M.NWNavBack(dv) end)
  if T.HelpTip then T.HelpTip(dvBack, "Back", { "One step back in the drill-down - it retraces exactly the path you came in on." }) end
  -- the payoff of clicking a chart day: the full item attribution since then
  local dvMoved = T.Button(dv, "What moved since? \226\128\186", 160, 22)
  dvMoved:SetPoint("TOPRIGHT", dvBack, "TOPLEFT", -8, 0)
  dvMoved:SetScript("OnClick", function()
    if dv.day and M.ShowMovers then M.ShowMovers(dv.day) end
  end)
  if T.HelpTip then
    T.HelpTip(dvMoved, "What moved since this day?", {
      "Opens the account-wide item breakdown attributed against THIS day's snapshot: every item's quantity and market effect plus realized trading between then and now." })
  end
  -- drop a wrong day -- or this day and everything before it (beta leftovers)
  local dvDel = T.Button(dv, "Delete\226\128\166", 80, 22)
  dvDel:SetPoint("TOPRIGHT", dvMoved, "TOPLEFT", -8, 0)
  dvDel:SetScript("OnClick", function()
    if not dv.day then return end
    local lbl = M.DayLabel(dv.day)
    StaticPopup_Show("MIDAS_FORGET_WORTH", lbl, lbl, dv.day)
  end)
  if T.HelpTip then
    T.HelpTip(dvDel, "Delete history", {
      "Deletes this day's net worth snapshot - or this day and every earlier one, for example beta days that ended up in your live history. Characters, items and trades are not touched." })
  end
  local ca = T.Text(dv, T.SIZE.tiny, "muted", T.FONT_MED)
  ca:SetPoint("TOPLEFT", 2, -56); ca:SetText("BY ASSET CLASS \194\183 that day \194\183 change to now")
  dv.classRows = {}
  for i = 1, 7 do
    local y = -76 - (i - 1) * 21
    local r = {}
    r.name = T.Text(dv, T.SIZE.body, "text"); r.name:SetPoint("TOPLEFT", 4, y); r.name:SetWidth(92)
    local bgt = dv:CreateTexture(nil, "ARTWORK"); bgt:SetColorTexture(1, 1, 1, 0.05)
    bgt:SetPoint("TOPLEFT", 100, y - 1); bgt:SetSize(150, 11)
    r.bar = dv:CreateTexture(nil, "OVERLAY"); r.bar:SetPoint("TOPLEFT", 100, y - 1); r.bar:SetSize(1, 11)
    r.val = T.Text(dv, T.SIZE.body, "text", T.FONT_MED); r.val:SetPoint("TOPLEFT", 258, y); r.val:SetWidth(96); r.val:SetJustifyH("RIGHT")
    r.pct = T.Text(dv, T.SIZE.small, "muted"); r.pct:SetPoint("TOPLEFT", 358, y); r.pct:SetWidth(36); r.pct:SetJustifyH("RIGHT")
    r.chg = T.Text(dv, T.SIZE.small, "muted", T.FONT_MED); r.chg:SetPoint("TOPLEFT", 400, y); r.chg:SetWidth(104); r.chg:SetJustifyH("RIGHT")
    r.btn = CreateFrame("Button", nil, dv)
    r.btn:SetPoint("TOPLEFT", 2, y + 2); r.btn:SetSize(508, 16)
    local chl = r.btn:CreateTexture(nil, "HIGHLIGHT"); chl:SetAllPoints(); chl:SetColorTexture(1, 1, 1, 0.04)
    r.btn:SetScript("OnEnter", function(self)
      local s = dv.day and M.NWHist()[dv.day]
      local cls = self.cls
      if not (s and cls) then return end
      local thenV = (type(s.c) == "table") and (s.c[cls] or 0) or 0
      local nowV = w.nw and w.nw.classes and w.nw.classes[cls] or 0
      OpenInfoTip()
      GameTooltip:AddLine(cls .. " \194\183 " .. M.DayLabel(dv.day), 1, 1, 1)
      addKV("That day", M.MoneyPlain(thenV))
      addKV("Now", M.MoneyPlain(nowV))
      addKV("Change", fmtDelta(nowV - thenV), C.sub, deltaColor(nowV - thenV))
      GameTooltip:Show()
    end)
    r.btn:SetScript("OnLeave", HideTip)
    r.btn:SetScript("OnClick", function(self)
      if self.cls and M.ShowWorthClass then HideTip(); M.ShowWorthClass(self.cls) end
    end)
    dv.classRows[i] = r
  end
  vline(dv, 524)
  local cb = T.Text(dv, T.SIZE.tiny, "muted", T.FONT_MED)
  cb:SetPoint("TOPLEFT", 540, -56); cb:SetText("BY CHARACTER \194\183 that day \194\183 change to now")
  dv.charRows = {}
  dv.mkChar = function(i)
    local y = -76 - (i - 1) * 17
    local r = {}
    r.name = T.Text(dv, T.SIZE.body, "text"); r.name:SetPoint("TOPLEFT", 540, y); r.name:SetWidth(140)
    r.val = T.Text(dv, T.SIZE.body, "sub", T.FONT_MED); r.val:SetPoint("TOPLEFT", 682, y); r.val:SetWidth(90); r.val:SetJustifyH("RIGHT")
    r.pct = T.Text(dv, T.SIZE.small, "muted"); r.pct:SetPoint("TOPLEFT", 776, y); r.pct:SetWidth(36); r.pct:SetJustifyH("RIGHT")
    r.chg = T.Text(dv, T.SIZE.small, "muted", T.FONT_MED); r.chg:SetPoint("TOPLEFT", 816, y); r.chg:SetWidth(84); r.chg:SetJustifyH("RIGHT")
    r.btn = CreateFrame("Button", nil, dv)
    r.btn:SetPoint("TOPLEFT", 538, y + 2); r.btn:SetSize(364, 15)
    local dhl = r.btn:CreateTexture(nil, "HIGHLIGHT"); dhl:SetAllPoints(); dhl:SetColorTexture(1, 1, 1, 0.04)
    r.btn:SetScript("OnEnter", charTip)
    r.btn:SetScript("OnLeave", HideTip)
    r.btn:SetScript("OnClick", function(self)
      if self.ck and M.ShowCharItems then HideTip(); M.ShowCharItems(self.ck) end
    end)
    dv.charRows[i] = r
  end
  for i = 1, 10 do dv.mkChar(i) end
  dv.note = T.Text(dv, T.SIZE.small, "muted")
  dv.note:SetPoint("BOTTOMLEFT", 2, 6); dv.note:SetWidth(880); dv.note:SetJustifyH("LEFT")
  dv:Hide()
  w.dayView = dv

  -- click a day in the history chart to open it (hover already tracks the day)
  if w.chart then
    w.chart:SetScript("OnMouseUp", function(self)
      local day = self._lastHoverDay
      if day and M.ShowWorthDay then M.ShowWorthDay(day) end
    end)
  end

  -- ===== class drill-down (inside the day view) =============================
  -- Clicking an asset class in the day view: that class's value history as a
  -- chart (class color), its per-character split AS OF the picked day, and the
  -- class's top items TODAY (items are not stored per day, and it says so).
  local cv = CreateFrame("Frame", nil, panel)
  cv:SetAllPoints()
  cv:SetFrameLevel(panel:GetFrameLevel() + 50)
  local cvbg = cv:CreateTexture(nil, "BACKGROUND")
  cvbg:SetAllPoints(); cvbg:SetColorTexture(C.bg0[1], C.bg0[2], C.bg0[3], 1)
  cv:EnableMouse(true)
  cv.title = T.Text(cv, T.SIZE.h2 + 2, "text", T.FONT_SEMI)
  cv.title:SetPoint("TOPLEFT", 2, -4)
  cv.sub = T.Text(cv, T.SIZE.small, "sub")
  cv.sub:SetPoint("TOPLEFT", 2, -27)
  local cvBack = T.Button(cv, "< back", 88, 22)
  cvBack:SetPoint("TOPRIGHT", -2, -2)
  cvBack:SetScript("OnClick", function() M.NWNavBack(cv) end)
  if T.HelpTip then T.HelpTip(cvBack, "Back", { "One step back in the drill-down - it retraces exactly the path you came in on." }) end
  cv.chart = CreateFrame("Frame", nil, cv)
  cv.chart:SetPoint("TOPLEFT", 0, -46)
  cv.chart:SetPoint("TOPRIGHT", -10, -46)  -- elastic width
  cv.chart:SetHeight(132)
  -- the lists hang off this anchor; FillWorthClass grows the chart into the
  -- extra room, slides the anchor down and adds list rows for what is left
  local cvLow = CreateFrame("Frame", nil, cv)
  cvLow:SetPoint("TOPLEFT", 0, -190); cvLow:SetSize(1, 1)
  cv.lower = cvLow
  local cch = T.Text(cv, T.SIZE.tiny, "muted", T.FONT_MED)
  cch:SetPoint("TOPLEFT", cvLow, "TOPLEFT", 2, 0); cch:SetText("BY CHARACTER \194\183 that day \194\183 change to now")
  cv.charRows = {}
  cv.mkChar = function(i)
    local y = -18 - (i - 1) * 17
    local r = {}
    r.name = T.Text(cv, T.SIZE.body, "text"); r.name:SetPoint("TOPLEFT", cvLow, "TOPLEFT", 4, y); r.name:SetWidth(150)
    r.val = T.Text(cv, T.SIZE.body, "sub", T.FONT_MED); r.val:SetPoint("TOPLEFT", cvLow, "TOPLEFT", 158, y); r.val:SetWidth(96); r.val:SetJustifyH("RIGHT")
    r.pct = T.Text(cv, T.SIZE.small, "muted"); r.pct:SetPoint("TOPLEFT", cvLow, "TOPLEFT", 258, y); r.pct:SetWidth(40); r.pct:SetJustifyH("RIGHT")
    r.chg = T.Text(cv, T.SIZE.small, "muted", T.FONT_MED); r.chg:SetPoint("TOPLEFT", cvLow, "TOPLEFT", 302, y); r.chg:SetWidth(88); r.chg:SetJustifyH("RIGHT")
    r.btn = CreateFrame("Button", nil, cv)
    r.btn:SetPoint("TOPLEFT", cvLow, "TOPLEFT", 2, y + 2); r.btn:SetSize(392, 15)
    local khl = r.btn:CreateTexture(nil, "HIGHLIGHT"); khl:SetAllPoints(); khl:SetColorTexture(1, 1, 1, 0.04)
    r.btn:SetScript("OnEnter", charTip)
    r.btn:SetScript("OnLeave", HideTip)
    r.btn:SetScript("OnClick", function(self)
      if self.ck and M.ShowCharItems then HideTip(); M.ShowCharItems(self.ck, cv.cls) end
    end)
    cv.charRows[i] = r
  end
  for i = 1, 8 do cv.mkChar(i) end
  local cvl = vline(cv, 420)
  cvl:SetPoint("TOPLEFT", cvLow, "TOPLEFT", 420, 0)   -- divider only beside the lists, not the chart
  local cit = T.Text(cv, T.SIZE.tiny, "muted", T.FONT_MED)
  cit:SetPoint("TOPLEFT", cvLow, "TOPLEFT", 440, 0); cit:SetText("TOP ITEMS \194\183 today \194\183 change")
  cv.itHint = cit
  cv.itemRows = {}
  cv.mkItem = function(i)
    local y = -18 - (i - 1) * 17
    local r = {}
    r.name = T.Text(cv, T.SIZE.body, "text"); r.name:SetPoint("TOPLEFT", cvLow, "TOPLEFT", 440, y); r.name:SetWidth(220)
    r.qty = T.Text(cv, T.SIZE.small, "sub"); r.qty:SetPoint("TOPLEFT", cvLow, "TOPLEFT", 664, y); r.qty:SetWidth(56); r.qty:SetJustifyH("RIGHT")
    r.val = T.Text(cv, T.SIZE.body, "sub", T.FONT_MED); r.val:SetPoint("TOPLEFT", cvLow, "TOPLEFT", 724, y); r.val:SetWidth(100); r.val:SetJustifyH("RIGHT")
    r.chg = T.Text(cv, T.SIZE.small, "muted", T.FONT_MED); r.chg:SetPoint("TOPLEFT", cvLow, "TOPLEFT", 828, y); r.chg:SetWidth(84); r.chg:SetJustifyH("RIGHT")
    r.btn = CreateFrame("Button", nil, cv)
    r.btn:SetPoint("TOPLEFT", cvLow, "TOPLEFT", 438, y + 2); r.btn:SetSize(478, 15)
    local ihl = r.btn:CreateTexture(nil, "HIGHLIGHT"); ihl:SetAllPoints(); ihl:SetColorTexture(1, 1, 1, 0.04)
    r.btn:SetScript("OnEnter", function(self) if self.key then ShowItemTip(self.key) end end)
    r.btn:SetScript("OnLeave", HideTip)
    r.btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r.btn:SetScript("OnClick", function(self, mouse)
      if not self.key then return end
      if ItemMenuClick(mouse, self.key) then return end
      if M.ModPostDown() then M.PostItemStats(self.key); return end
      if M.ModSearchDown() then
        GoChart(self.key)
      elseif M.ShowItemWorth then
        HideTip(); M.ShowItemWorth(self.key, self.qty or 0)
      end
    end)
    cv.itemRows[i] = r
  end
  for i = 1, 8 do cv.mkItem(i) end
  cv.note = T.Text(cv, T.SIZE.small, "muted")
  cv.note:SetPoint("BOTTOMLEFT", 2, 6); cv.note:SetWidth(880); cv.note:SetJustifyH("LEFT")
  cv:Hide()
  w.classView = cv

  -- ===== single-item holding view ===========================================
  -- Deepest hop of the chain: one item you own -- what YOUR stack was worth on
  -- each day (today's quantity x that day's market price), plus your cost basis.
  local wv = CreateFrame("Frame", nil, panel)
  wv:SetAllPoints()
  wv:SetFrameLevel(panel:GetFrameLevel() + 60)
  local wvbg = wv:CreateTexture(nil, "BACKGROUND")
  wvbg:SetAllPoints(); wvbg:SetColorTexture(C.bg0[1], C.bg0[2], C.bg0[3], 1)
  wv:EnableMouse(true)
  wv.title = T.Text(wv, T.SIZE.h2 + 2, "text", T.FONT_SEMI)
  wv.title:SetPoint("TOPLEFT", 2, -4)
  wv.sub = T.Text(wv, T.SIZE.small, "sub")
  wv.sub:SetPoint("TOPLEFT", 2, -27)
  local wvBack = T.Button(wv, "< back", 88, 22)
  wvBack:SetPoint("TOPRIGHT", -2, -2)
  wvBack:SetScript("OnClick", function() M.NWNavBack(wv) end)
  if T.HelpTip then T.HelpTip(wvBack, "Back", { "One step back in the drill-down - it retraces exactly the path you came in on." }) end
  -- the item's other pages (market chart, craft tree, offer book, trades) as
  -- chips left of the back button; they grow leftwards (Nav.lua)
  if M.LinkBar then
    wv.links = M.LinkBar(wv, { except = "holding", watch = true })
    wv.links:SetPoint("TOPRIGHT", wvBack, "TOPLEFT", -10, -1)
  end
  wv.chart = CreateFrame("Frame", nil, wv)
  wv.chart:SetPoint("TOPLEFT", 0, -52)
  wv.chart:SetPoint("BOTTOMRIGHT", -6, 26) -- fully elastic (only the note below)
  wv.note = T.Text(wv, T.SIZE.small, "muted")
  wv.note:SetPoint("BOTTOMLEFT", 2, 6); wv.note:SetWidth(880); wv.note:SetJustifyH("LEFT")
  wv.note:SetText("Value = price x your quantity per day \226\128\148 quantities from the daily snapshots, gaps reconstructed from logged buys/sells (crafting or farming is invisible to the log).")
  wv:Hide()
  w.itemWorth = wv

  -- ===== movers drill-down: account-wide "what moved it" ====================
  -- The first account-wide item entry point: every item's contribution to the
  -- net-worth change over the shared timeframe, split into quantity and market
  -- effects plus realized trading, down to an honest "everything else" line.
  local mo = CreateFrame("Frame", nil, panel)
  mo:SetAllPoints()
  mo:SetFrameLevel(panel:GetFrameLevel() + 70)
  local mobg = mo:CreateTexture(nil, "BACKGROUND")
  mobg:SetAllPoints(); mobg:SetColorTexture(C.bg0[1], C.bg0[2], C.bg0[3], 1)
  mo:EnableMouse(true)
  mo.title = T.Text(mo, T.SIZE.h2 + 2, "text", T.FONT_SEMI)
  mo.title:SetPoint("TOPLEFT", 2, -4)
  mo.sub = T.Text(mo, T.SIZE.small, "sub")
  -- full width: the back button + range segment live a row higher
  mo.sub:SetPoint("TOPLEFT", 2, -27); mo.sub:SetPoint("TOPRIGHT", -12, -27); mo.sub:SetJustifyH("LEFT")
  local moBack = T.Button(mo, "< back", 88, 22)
  moBack:SetPoint("TOPRIGHT", -2, -2)
  moBack:SetScript("OnClick", function()
    mo.refDayOverride = nil            -- a picked-day view ends with the view
    M.NWNavBack(mo)
  end)
  local moSeg = makeRangeSeg(mo)
  moSeg.frame:SetPoint("TOPRIGHT", moBack, "TOPLEFT", -10, 0)

  local MO_COLS = {
    { name = "ITEM",   w = 250, just = "LEFT" },
    { name = "QTY",    w = 100, just = "RIGHT" },
    { name = "STOCK",  w = 92,  just = "RIGHT" },
    { name = "MARKET", w = 92,  just = "RIGHT" },
    { name = "TRADES", w = 92,  just = "RIGHT" },
    { name = "TOTAL",  w = 100, just = "RIGHT" },
  }
  local MO_HELP = {
    QTY    = "Units you held at the reference day vs now (bags + bank + mail + your own auctions).",
    STOCK  = "Quantity effect: units gained or lost since the reference day, valued at that day's price - buying, selling, crafting, consuming.",
    MARKET = "Market effect: the price moving under what you hold now - today's valuation vs the reference day's, per unit.",
    TRADES = "Realized gold from this item's AH and vendor trades in the window: sale proceeds after fees, minus what you paid.",
    TOTAL  = "Quantity effect + market effect + realized trades: this item's profit or loss since the reference day. An at-market purchase nets out to ~0; a bargain buy shows as a gain.",
  }
  mo.barX = 0
  do
    local hx2 = 0
    for _, d in ipairs(MO_COLS) do
      local fs = cell(mo, hx2, -56, d.w, d.just, T.SIZE.tiny, "muted", T.FONT_MED)
      fs:SetText(d.name)
      if MO_HELP[d.name] and T.HelpTip then
        local hb = CreateFrame("Button", nil, mo)
        hb:SetPoint("TOPLEFT", hx2, -54); hb:SetSize(d.w, 14)
        T.HelpTip(hb, d.name, { MO_HELP[d.name] }, "ANCHOR_TOP")
      end
      hx2 = hx2 + d.w + 6
    end
    mo.barX = hx2 + 4
  end
  mo.cols = MO_COLS

  local moScroll = CreateFrame("ScrollFrame", "MidasMoversScroll", mo, "FauxScrollFrameTemplate")
  moScroll:SetPoint("TOPLEFT", 0, -72)
  moScroll:SetPoint("BOTTOMRIGHT", -12, 44)
  local function moWheel(_, delta)
    local sb = _G["MidasMoversScrollScrollBar"]
    if sb then sb:SetValue(sb:GetValue() - delta * 18 * 2) end
  end
  moScroll:EnableMouseWheel(true); moScroll:SetScript("OnMouseWheel", moWheel)
  moScroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, 18, function() if M.FillMovers then M.FillMovers(true) end end)
  end)
  T.StyleScrollbar("MidasMoversScroll")
  mo.scroll = moScroll

  mo.rows = {}
  function mo.mkRow(r)
    local btn = CreateFrame("Button", nil, mo)
    btn:SetHeight(17)
    btn:SetPoint("TOPLEFT", 0, -72 - (r - 1) * 18)
    btn:SetPoint("RIGHT", mo, "RIGHT", -16, 0)
    local zb = btn:CreateTexture(nil, "BACKGROUND"); zb:SetAllPoints(); zb:SetColorTexture(1, 1, 1, 0.02); zb:Hide(); btn.zb = zb
    local hl = btn:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.05)
    local fs, cx = {}, 0
    for i, d in ipairs(MO_COLS) do fs[i] = cell(btn, cx, -2, d.w, d.just, T.SIZE.body); cx = cx + d.w + 6 end
    btn.fs = fs
    -- +/- contribution bar with a center anchor: green grows right, red left
    local track = btn:CreateTexture(nil, "ARTWORK")
    track:SetColorTexture(1, 1, 1, 0.05)
    track:SetPoint("LEFT", btn, "LEFT", mo.barX, 0)
    track:SetPoint("RIGHT", btn, "RIGHT", -2, 0)
    track:SetHeight(11)
    btn.track = track
    local tick = btn:CreateTexture(nil, "ARTWORK")
    tick:SetColorTexture(T.Unpack(C.borderlt))
    tick:SetSize(1, 11); tick:SetPoint("CENTER", track, "CENTER", 0, 0)
    btn.barPos = btn:CreateTexture(nil, "OVERLAY")
    btn.barPos:SetColorTexture(C.green[1], C.green[2], C.green[3], 0.85)
    btn.barPos:SetPoint("LEFT", track, "CENTER", 0, 0); btn.barPos:SetSize(1, 11)
    btn.barNeg = btn:CreateTexture(nil, "OVERLAY")
    btn.barNeg:SetColorTexture(C.red[1], C.red[2], C.red[3], 0.85)
    btn.barNeg:SetPoint("RIGHT", track, "CENTER", 0, 0); btn.barNeg:SetSize(1, 11)
    btn:EnableMouseWheel(true); btn:SetScript("OnMouseWheel", moWheel)
    -- the same rich split tooltip as the hero movers (qty, effects, trades)
    btn:SetScript("OnEnter", function(self)
      if self.e then miniTip(self)
      elseif self.key then ShowItemTip(self.key) end
    end)
    btn:SetScript("OnLeave", HideTip)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(self, mouse)
      local e = self.e; if not e then return end
      HideTip()
      if ItemMenuClick(mouse, tostring(e.id)) then return end
      if M.ModPostDown() then M.PostItemStats(tostring(e.id)); return end
      if M.ModSearchDown() then GoChart(tostring(e.id)); return end
      if M.ShowItemWorth then M.ShowItemWorth(tostring(e.id), e.qH or 0) end
    end)
    mo.rows[r] = btn
  end
  for r = 1, 12 do mo.mkRow(r) end

  -- pinned footer: binds the visible sum to the actual total change
  mo.other = T.Text(mo, T.SIZE.body, "muted")
  mo.other:SetPoint("BOTTOMLEFT", 2, 26)
  mo.otherVal = T.Text(mo, T.SIZE.body, "sub", T.FONT_MED)
  mo.otherVal:SetPoint("BOTTOMLEFT", 262, 26); mo.otherVal:SetWidth(190); mo.otherVal:SetJustifyH("RIGHT")
  mo.note = T.Text(mo, T.SIZE.small, "muted")
  mo.note:SetPoint("BOTTOMLEFT", 2, 6); mo.note:SetPoint("BOTTOMRIGHT", -12, 6); mo.note:SetJustifyH("LEFT")
  mo.note:SetText("Quantities from the daily snapshots \226\128\148 prices reconstructed with today's method at the reference day's market level.")
  mo:Hide()
  w.moversView = mo
end

-- (shortGold / hexC / fmtDelta / deltaColor live above NWNavPush now: the
-- drill-down fill functions inside BuildWealth need them in scope)

-- Fill the by-character rows. cmpDay = a net-worth-history day to compare against
-- (from scrubbing the chart): totals then show THAT day's value and the change to
-- now. cmpDay nil = live: current totals + change since the last daily snapshot,
-- falling back to the character's share of the current net worth when no history yet.
function M.FillCharRows(cmpDay)
  local w = M.wealth; if not w or not w.charRows then return end
  local nw = w.nw; if not nw then return end
  -- graveyard view: the same rows show the fallen (worth + death day) instead
  if w.graveView and not cmpDay then
    local g = nw.grave or {}
    if w.charHint then w.charHint:SetText("GRAVEYARD  \194\183  worth at market  \194\183  died") end
    for i = 1, #w.charRows do
      local r = w.charRows[i]
      if r then
        local e = (i <= (w._charVis or 8)) and g[i] or nil
        if r.btn then r.btn.key = e and e.key or nil end
        if e then
          r.name:SetText(e.name or e.key); colorize(r.name, C.muted)
          r.val:SetText(M.MoneyPlain(e.total)); colorize(r.val, C.sub)
          r.chg:SetText(e.deadTs and date("%b %d %Y", e.deadTs) or "\226\128\147"); colorize(r.chg, C.muted)
        elseif i == 1 then
          r.name:SetText("the graveyard is empty"); colorize(r.name, C.muted)
          r.val:SetText(""); r.chg:SetText("")
        else
          r.name:SetText(""); r.val:SetText(""); r.chg:SetText("")
        end
      end
    end
    return
  end
  local hist = M.NWHist()
  local snap = cmpDay and hist and hist[cmpDay] or nil
  -- live view compares against the tab's shared timeframe (share % lives in
  -- the hover tooltip now -- the column had carried two meanings before)
  local refDay = w.attrib and w.attrib.refDay or nil   -- ONE change reference for the whole tab
  if w.charHint then
    if cmpDay then w.charHint:SetText("as of " .. M.DayLabel(cmpDay) .. "  \194\183  change to now")
    else w.charHint:SetText("BY CHARACTER (" .. M.RealmKey() .. ")  \194\183  change since "
      .. (refDay and M.DayLabel(refDay) or "last snapshot")) end
  end
  local chars, hidden = {}, 0
  for _, info in pairs(nw.chars) do
    if info.seen or info.total > 0 then chars[#chars + 1] = info else hidden = hidden + 1 end
  end
  -- scrubbed: rank by the value the row shows (that day's), not today's
  local function shownOf(info)
    return (snap and snap.chars and snap.chars[info.key]) or info.total
  end
  table.sort(chars, function(a, b) return shownOf(a) > shownOf(b) end)
  local vis = w._charVis or 8
  for i = 1, #w.charRows do
    local r = w.charRows[i]
    if r then
      local info = (i <= vis) and chars[i] or nil
      if r.btn then r.btn.key = info and info.key or nil end
      if info then
        r.name:SetText(info.name); colorize(r.name, C.text)
        local base = snap and snap.chars and snap.chars[info.key]
        local shown = base or info.total
        r.val:SetText(M.MoneyPlain(shown)); colorize(r.val, C.sub)
        local dd, isNew
        if cmpDay then
          if base then dd = info.total - base end
        elseif M.CharDeltaSince then
          dd = M.CharDeltaSince(info.key, info.total, refDay)
          -- not in the reference snapshot: the character joined later, so a
          -- change "since <refDay>" does not exist for it
          isNew = (dd == nil and refDay ~= nil)
        end
        -- percent of the value AT the reference, not of today's value
        local ref = dd and (info.total - dd)
        if dd and ref and ref > 0 and math.abs(dd) >= 1000 then
          r.chg:SetText(string.format("%+.1f%%  %s", dd / ref * 100, fmtDelta(dd)))
          colorize(r.chg, deltaColor(dd))
        elseif dd and math.abs(dd) >= 1000 then
          r.chg:SetText(fmtDelta(dd)); colorize(r.chg, deltaColor(dd))
        elseif isNew then
          r.chg:SetText("new"); colorize(r.chg, C.muted)
        else
          r.chg:SetText("\226\128\147"); colorize(r.chg, C.muted)
        end
      elseif i <= vis and hidden > 0 and i == #chars + 1 then
        r.name:SetText(string.format("+%d not scanned yet", hidden)); colorize(r.name, C.muted)
        r.val:SetText(""); r.chg:SetText("")
      else
        r.name:SetText(""); r.val:SetText(""); r.chg:SetText("")
      end
    end
  end
end

-- Fill the movers drill-down from the current attribution. scrollOnly = true
-- keeps the cached attribution (called from the scroll handler). With
-- mo.refDayOverride set (day-view's "what moved since?"), the attribution is
-- computed against that picked day instead of the shared timeframe.
function M.FillMovers(scrollOnly)
  local w = M.wealth
  local mo = w and w.moversView
  if not mo then return end
  local at
  if scrollOnly and mo.at then
    at = mo.at
  elseif mo.refDayOverride then
    at = M.WorthAttribution and M.WorthAttribution(w.nw, mo.refDayOverride)
  else
    at = w.attrib or (M.WorthAttribution and M.WorthAttribution(w.nw))
  end
  mo.at = at
  local function pm(v) return ((v >= 0) and "+" or "-") .. shortGold(math.abs(v)) end
  if not at then
    mo.title:SetText("What moved it")
    mo.sub:SetText("No item snapshots yet \226\128\148 they build up daily from the first net-worth snapshot on.")
    for _, btn in ipairs(mo.rows) do
      btn.key, btn.e = nil, nil
      for i = 1, #btn.fs do btn.fs[i]:SetText("") end
      btn.zb:Hide(); btn.barPos:SetWidth(1); btn.barNeg:SetWidth(1)
      btn.barPos:Hide(); btn.barNeg:Hide(); btn.track:Hide(); btn:Hide()
    end
    mo.other:SetText(""); mo.otherVal:SetText("")
    return
  end
  local d = at.dTotal
  mo.title:SetText(string.format("What moved it   \194\183   since %s%s   \194\183   %s%s",
    M.DayLabel(at.refDay), mo.refDayOverride and "  (picked day)" or "",
    (d >= 0) and "+" or "-", M.MoneyPlain(math.abs(d))))
  local tradingTxt
  if (at.trading.sold or 0) == 0 and (at.trading.bought or 0) == 0 then
    tradingTxt = "no trades in this window"
  else
    tradingTxt = string.format("trading:  sold %s  -  bought %s  =  %s",
      shortGold(at.trading.sold), shortGold(at.trading.bought), fmtDelta(at.trading.net))
  end
  mo.sub:SetText(string.format(
    "market %s   \194\183   quantity %s   \194\183   gold %s   \194\183   other %s        %s",
    pm(at.market), pm(at.stock), pm(at.gold), pm(at.residual), tradingTxt))

  local list = at.items or {}
  local panel = M.panels and M.panels[TAB["Net Worth"]]
  local vis = availRows(panel, 118, 18, 12)
  for r = #mo.rows + 1, vis do mo.mkRow(r) end
  FauxScrollFrame_Update(mo.scroll, #list, vis, 18)
  local offset = math.min(FauxScrollFrame_GetOffset(mo.scroll), math.max(0, #list - vis))
  -- bar scale: the bar draws the TOTAL (pnl) column; the 0.1g floor keeps a
  -- page of churn rows (pnl ~ 0) from blowing noise bars to full width
  local maxAbs = 1000
  for _, e in ipairs(list) do
    local a = math.abs(e.pnl)
    if a > maxAbs then maxAbs = a end
  end
  local function money(fs, v)
    fs:SetText(fmtDelta(v)); colorize(fs, deltaColor(v))
  end
  for r = 1, #mo.rows do
    local btn = mo.rows[r]
    local e = (r <= vis) and list[r + offset] or nil
    btn.e = e
    if e then
      btn:Show(); btn.track:Show(); btn.barPos:Show(); btn.barNeg:Show()
      btn.zb:SetShown((r % 2) == 0)
      local key = tostring(e.id)
      btn.key = key
      setItemName(btn.fs[1], key)
      btn.fs[2]:SetText(string.format("%d \226\134\146 %d", e.qR or 0, e.qH or 0)); colorize(btn.fs[2], C.sub)
      money(btn.fs[3], e.dStock)
      money(btn.fs[4], e.dMarket)
      money(btn.fs[5], e.trade or 0)
      money(btn.fs[6], e.pnl)
      local tw = btn.track:GetWidth() or 0
      if tw < 20 then tw = 180 end   -- first fill before the layout pass
      local half = math.max(1, math.floor(tw / 2) - 1)
      local frac = math.min(1, math.abs(e.pnl) / maxAbs)
      if e.pnl >= 0 then
        btn.barPos:SetWidth(math.max(1, half * frac)); btn.barNeg:SetWidth(1)
      else
        btn.barNeg:SetWidth(math.max(1, half * frac)); btn.barPos:SetWidth(1)
      end
    else
      btn.key = nil
      for i = 1, #btn.fs do btn.fs[i]:SetText("") end
      btn.zb:Hide(); btn.track:Hide(); btn.barPos:Hide(); btn.barNeg:Hide()
      if r > vis then btn:Hide() else btn:Show() end
    end
  end
  if #list == 0 then
    mo.rows[1]:Show()
    mo.rows[1].fs[1]:SetText("no single item moved more than 0.1g in this window")
    colorize(mo.rows[1].fs[1], C.muted)
  end
  -- at.rest = total change minus every listed row: rows + this line add up
  -- to the headline exactly (it holds non-trading gold, the AH listing
  -- discount, rows under 0.1g and trades without an item id)
  mo.other:SetText("everything else  (non-trading gold, AH discount, small items)")
  local rest = at.rest or ((at.gold or 0) - (at.trading.net or 0) + (at.residual or 0))
  mo.otherVal:SetText(fmtDelta(rest)); colorize(mo.otherVal, deltaColor(rest))
end

-- refDay (optional): attribute against that picked snapshot day instead of
-- the shared timeframe (the day-view's "what moved since this day?").
function M.ShowMovers(refDay)
  local w = M.wealth
  if not (w and w.moversView) then return end
  w.moversView.refDayOverride = refDay
  if w.moversView.scroll then FauxScrollFrame_SetOffset(w.moversView.scroll, 0) end
  M.NWNavPush(w.moversView)   -- show first: the bar widths need a laid-out frame
  M.FillMovers()
end

-- Fill the day drill-down from the snapshot of w.dayView.day: class split with
-- bars + share + change-to-now, and the per-character split of that day.
function M.FillWorthDay()
  local w = M.wealth
  local dv = w and w.dayView
  if not dv or not dv.day then return end
  local hist = M.NWHist()
  local s = hist and hist[dv.day]
  if not s then dv:Hide(); return end
  local nw = w.nw
  dv.title:SetText("Net Worth on " .. M.DayLabel(dv.day) .. "   \194\183   " .. M.MoneyPlain(s.t or 0))
  -- context line: change vs the previous snapshot and to now
  local prevDay
  for d in pairs(hist) do
    if d < dv.day and (not prevDay or d > prevDay) then prevDay = d end
  end
  local parts = {}
  if prevDay and hist[prevDay] and (hist[prevDay].t or 0) > 0 then
    local dd = (s.t or 0) - hist[prevDay].t
    parts[#parts + 1] = string.format("vs %s:  %s%s", M.DayLabel(prevDay), dd >= 0 and "+" or "-", M.MoneyPlain(math.abs(dd)))
  end
  if nw and nw.total and (s.t or 0) > 0 then
    local dd = nw.total - s.t
    parts[#parts + 1] = string.format("to now:  %s%s  (%+.1f%%)", dd >= 0 and "+" or "-", M.MoneyPlain(math.abs(dd)), dd / s.t * 100)
  end
  dv.sub:SetText(table.concat(parts, "   \194\183   "))
  -- classes as of that day
  local cls = (type(s.c) == "table") and s.c or {}
  local total = (s.t and s.t > 0) and s.t or 1
  local maxv = 1
  for _, name in ipairs(M.ASSET_ORDER or {}) do
    local v = cls[name] or 0
    if v > maxv then maxv = v end
  end
  for i, name in ipairs(M.ASSET_ORDER or {}) do
    local r = dv.classRows[i]
    if r then
      local v = cls[name] or 0
      if r.btn then r.btn.cls = name end
      r.name:SetText(name)
      r.val:SetText(M.MoneyPlain(v))
      r.pct:SetText(string.format("%.0f%%", v / total * 100))
      local col = C[CLASS_COLOR[name] or "muted"]
      r.bar:SetColorTexture(col[1], col[2], col[3], 0.9)
      r.bar:SetWidth(math.max(1, 150 * (v / maxv)))
      local nowv = nw and nw.classes and nw.classes[name] or 0
      local dd = nowv - v
      r.chg:SetText(fmtDelta(dd)); colorize(r.chg, deltaColor(dd))
    end
  end
  -- characters as of that day (elastic: taller windows show them all)
  local arr = {}
  for ck, v in pairs(s.chars or {}) do arr[#arr + 1] = { ck = ck, v = v } end
  table.sort(arr, function(a, b) return a.v > b.v end)
  local vis = availRows(M.panels and M.panels[TAB["Net Worth"]], 100, 17, 10)
  if dv.mkChar then for i = #dv.charRows + 1, vis do dv.mkChar(i) end end
  for i = 1, #dv.charRows do
    local r = dv.charRows[i]
    local e = (i <= vis) and arr[i] or nil
    if e and i == vis and #arr > vis then
      -- collapse the cut-off rest into one line instead of dropping it silently
      if r.btn then r.btn.ck = nil end
      r.name:SetText(string.format("+%d more \226\128\148 taller window shows them", #arr - vis + 1))
      colorize(r.name, C.muted)
      r.val:SetText(""); r.pct:SetText(""); r.chg:SetText("")
    elseif e then
      if r.btn then r.btn.ck = e.ck end
      local dc = M.db and M.db.chars and M.db.chars[e.ck]
      r.name:SetText((dc and dc.name) or e.ck:match("^(.-)%-") or e.ck)
      colorize(r.name, C.text)
      r.val:SetText(M.MoneyPlain(e.v))
      r.pct:SetText(string.format("%.0f%%", e.v / total * 100))
      local nowc = nw and nw.chars and nw.chars[e.ck]
      if nowc then
        local dd = (nowc.total or 0) - e.v
        r.chg:SetText(fmtDelta(dd)); colorize(r.chg, deltaColor(dd))
      else
        local dc2 = M.db and M.db.chars and M.db.chars[e.ck]
        r.chg:SetText((dc2 and dc2.dead) and "graveyard" or "removed"); colorize(r.chg, C.muted)
      end
    else
      if r.btn then r.btn.ck = nil end
      r.name:SetText(""); r.val:SetText(""); r.pct:SetText(""); r.chg:SetText("")
    end
  end
  if not s.chars or not next(s.chars) then
    local d0 = firstSnapDay("chars")
    dv.note:SetText("No per-character data for this day \226\128\148 "
      .. (d0 and ("it records from " .. M.DayLabel(d0) .. " on") or "it starts with the next snapshot") .. ".")
  else
    dv.note:SetText("Snapshots store one value per day \226\128\148 click other days in the chart after going back.")
  end
end

function M.ShowWorthDay(day)
  local w = M.wealth
  if not (w and w.dayView) then return end
  w.dayView.day = day
  M.FillWorthDay()
  M.NWNavPush(w.dayView)
end

-- Fill the class drill-down: one asset class on the picked day -- its full value
-- history (chart in the class color), the per-character split of that day, and
-- the class's top items TODAY (item lists are not stored per day; the note says so).
function M.FillWorthClass()
  local w = M.wealth
  local cv = w and w.classView
  if not (cv and cv.cls and cv.day) then return end
  local day, cls = cv.day, cv.cls
  local hist = M.NWHist()
  local s = hist and hist[day]
  if not s then cv:Hide(); return end
  local nw = w.nw
  local v = (type(s.c) == "table") and (s.c[cls] or 0) or 0
  local total = (s.t and s.t > 0) and s.t or 1
  cv.title:SetText(cls .. " on " .. M.DayLabel(day) .. "   \194\183   " .. M.MoneyPlain(v)
    .. "   \194\183   " .. string.format("%.0f%%", v / total * 100) .. " of that day")
  local nowv = nw and nw.classes and nw.classes[cls] or 0
  local dd = nowv - v
  cv.sub:SetText(string.format("now:  %s   \194\183   change:  %s%s",
    M.MoneyPlain(nowv), dd >= 0 and "+" or "-", M.MoneyPlain(math.abs(dd))))
  -- taller window: most of the extra room goes into the chart, the rest into
  -- longer lists; the anchor slides everything below the chart down
  local ex = extraH(M.panels and M.panels[TAB["Net Worth"]])
  local grow = math.min(math.floor(ex * 0.62), 300)
  if cv.chart then cv.chart:SetHeight(132 + grow) end
  if cv.lower then cv.lower:SetPoint("TOPLEFT", 0, -(190 + grow)) end
  cv._vis = availRows(M.panels and M.panels[TAB["Net Worth"]], 190 + grow + 42, 17, 8)
  if cv.mkChar then for i = #cv.charRows + 1, cv._vis do cv.mkChar(i) end end
  if cv.mkItem then for i = #cv.itemRows + 1, cv._vis do cv.mkItem(i) end end
  if M.RenderNetWorthChart and cv.chart then M.RenderNetWorthChart(cv.chart, nil, cls) end
  -- per-character split of the class as of that day (snapshot.cc, recorded since 1.0.8)
  local arr = {}
  if s.cc then
    for ck, cmap in pairs(s.cc) do
      local cval = cmap and cmap[cls]
      if cval and cval > 0 then arr[#arr + 1] = { ck = ck, v = cval } end
    end
  end
  table.sort(arr, function(a, b) return a.v > b.v end)
  for i = 1, #cv.charRows do
    local r = cv.charRows[i]
    local e = (i <= (cv._vis or 8)) and arr[i] or nil
    if e then
      if r.btn then r.btn.ck = e.ck end
      r.name:SetText((e.ck:match("^(.-)%-") or e.ck)); colorize(r.name, C.text)
      r.val:SetText(M.MoneyPlain(e.v))
      r.pct:SetText((v > 0) and string.format("%.0f%%", e.v / v * 100) or "")
      local nowc = nw and nw.chars and nw.chars[e.ck]
      local nowcv = nowc and nowc.cls and nowc.cls[cls]
      if nowcv ~= nil then
        local d2 = nowcv - e.v
        r.chg:SetText(fmtDelta(d2)); colorize(r.chg, deltaColor(d2))
      else
        local dc = M.db and M.db.chars and M.db.chars[e.ck]
        r.chg:SetText(nowc and "\226\128\147" or ((dc and dc.dead) and "graveyard" or "removed")); colorize(r.chg, C.muted)
      end
    else
      if r.btn then r.btn.ck = nil end
      r.name:SetText(""); r.val:SetText(""); r.pct:SetText(""); r.chg:SetText("")
    end
  end
  if #arr == 0 then
    local d0 = firstSnapDay("cc")
    cv.charRows[1].name:SetText("no per-character split for this day \226\128\148 "
      .. (d0 and ("it records from " .. M.DayLabel(d0) .. " on") or "it starts with the next snapshot"))
    colorize(cv.charRows[1].name, C.muted)
  end
  -- top items of the class TODAY, each with its change over the shared window
  local at2 = w.attrib or (M.WorthAttribution and M.WorthAttribution(nw))
  local pmap = (at2 and M._nwAttrib and M._nwAttrib.p) or nil
  local iqR = at2 and hist and hist[at2.refDay] and hist[at2.refDay].iq or nil
  -- items over the movers keep-gate reuse the attribution's pnl, so this list
  -- always agrees with the what-moved TOTAL for the same item
  local byId = {}
  if at2 then for _, ae in ipairs(at2.items or {}) do byId[ae.id] = ae end end
  if cv.itHint then
    cv.itHint:SetText("TOP ITEMS \194\183 today \194\183 change"
      .. (at2 and (" since " .. M.DayLabel(at2.refDay)) or ""))
  end
  local items = nw and nw.classItems and nw.classItems[cls] or {}
  for i = 1, #cv.itemRows do
    local r = cv.itemRows[i]
    local e = (i <= (cv._vis or 8)) and items[i] or nil
    if e then
      local key = tostring(e.id)
      if r.btn then r.btn.key = key; r.btn.qty = e.qty end
      local qc = M.ItemQualityColor(key)
      r.name:SetText(M.ItemName(key)); r.name:SetTextColor(qc.r, qc.g, qc.b)
      r.qty:SetText("x" .. (e.qty or 0))
      r.val:SetText(M.MoneyPlain(e.value or 0))
      -- account-wide stock+market effect; the Auctions class is valued with
      -- the sell-chance discount, a price delta would be misleading there
      local dtot
      local ae = cls ~= "Auctions" and byId[e.id] or nil
      if ae then
        dtot = ae.pnl
      elseif cls ~= "Auctions" and pmap and e.qty and e.qty > 0 then
        local pR = pmap[e.id]
        local pH = (e.value or 0) / e.qty
        if pR and pH > 0 then
          pR = bandRef(pR, pH)
          local qR = (iqR and iqR[e.id]) or e.qty
          dtot = (e.qty - qR) * pR + e.qty * (pH - pR)
        end
      end
      r.chg:SetText(fmtDelta(dtot)); colorize(r.chg, deltaColor(dtot))
    else
      if r.btn then r.btn.key = nil; r.btn.qty = nil end
      r.name:SetText(""); r.qty:SetText(""); r.val:SetText(""); r.chg:SetText("")
    end
  end
  if #items == 0 and cls == "Money" then
    cv.itemRows[1].name:SetText("liquid gold \226\128\148 no items"); colorize(cv.itemRows[1].name, C.muted)
  end
  cv.note:SetText("Per-day data covers totals and characters; item lists always show TODAY's holdings.")
end

-- Deepest drill-down hop: one owned item's holding-value history. Quantity comes
-- from the caller (character stack or account-wide, depending on where you came
-- from); the chart multiplies it with each day's market price.
function M.FillItemWorth()
  local w = M.wealth
  local wv = w and w.itemWorth
  if not (wv and wv.key) then return end
  local key, qty = wv.key, wv.qty or 0
  local qc = M.ItemQualityColor(key)
  wv.title:SetText(M.ItemName(key))
  wv.title:SetTextColor(qc.r, qc.g, qc.b)
  if wv.links then wv.links:SetItem(key) end
  local unit = M.ItemValue and M.ItemValue(key) or 0
  -- the chart re-anchors on the account-wide daily snapshots (which INCLUDE
  -- your own auctions), so the header must count the same way -- a class-list
  -- entry hands over only that class's share and used to show too few
  local id = (M.BaseID and M.BaseID(key)) or tonumber(key)
  local accQ = w.nw and w.nw.itemQty and id and w.nw.itemQty[id] or nil
  if accQ then qty = accQ end
  local parts
  if qty > 0 then
    local qtxt = string.format("x%d \194\183 account-wide incl. your auctions", qty)
    if wv.srcLabel == "this character" and wv.qty and wv.qty ~= qty then
      qtxt = qtxt .. string.format("  (x%d this character)", wv.qty)
    end
    parts = { qtxt, "worth today  " .. M.MoneyPlain(unit * qty) }
  else
    parts = { "sold out \226\128\148 the chart shows the former holding" }
  end
  if M.RealizedBuy then
    local paid, units = M.RealizedBuy(key)
    if paid and units and units > 0 then
      parts[#parts + 1] = string.format("you paid  %s avg  (%d bought)", M.MoneyPlain(paid), units)
    end
  end
  -- this item's slice of the shared window: prefer the attribution entry (the
  -- EXACT numbers the movers rank by, incl. consumption and the total), so the
  -- header and the movers view can never disagree; small items below the
  -- movers keep-gate fall back to the old inline estimate
  local at2 = w.attrib or (M.WorthAttribution and M.WorthAttribution(w.nw))
  local ae
  if at2 and id then
    for _, x in ipairs(at2.items or {}) do if x.id == id then ae = x; break end end
  end
  local pR = at2 and M._nwAttrib and M._nwAttrib.p and id and M._nwAttrib.p[id]
  if ae then
    local line = string.format("since %s:  market %s  \194\183  trades %s",
      M.DayLabel(at2.refDay), fmtDelta(ae.dMarket), fmtDelta(ae.trade))
    if (ae.cons or 0) > 0 then
      line = line .. string.format("  \194\183  consumed %d", ae.cons)
    end
    parts[#parts + 1] = line .. "  \194\183  total " .. fmtDelta(ae.pnl)
  elseif at2 and pR and unit > 0 and qty > 0 then
    local dm = qty * (unit - pR)
    local trade = 0
    local realm = M.RealmKey()
    for _, e in ipairs((M.db.trade and M.db.trade.log) or {}) do
      if e.id == id and e.realm == realm and e.day and e.day > at2.refDay then
        if e.kind == "sold" then trade = trade + (e.net or 0)
        elseif e.kind == "bought" then trade = trade - (e.gross or 0) end
      end
    end
    parts[#parts + 1] = string.format("since %s:  market %s  \194\183  trades %s",
      M.DayLabel(at2.refDay), fmtDelta(dm), fmtDelta(trade))
  end
  wv.sub:SetText(table.concat(parts, "   \194\183   "))
  if M.RenderHoldingChart and wv.chart then M.RenderHoldingChart(wv.chart, key, qty) end
end

-- srcLabel names what the quantity means ("this character" from the character
-- drill-down, otherwise account-wide) -- the number changes meaning by entry.
function M.ShowItemWorth(key, qty, srcLabel)
  local w = M.wealth
  if not (w and w.itemWorth) then return end
  w.itemWorth.key = key
  w.itemWorth.qty = qty
  w.itemWorth.srcLabel = srcLabel
  M.FillItemWorth()
  M.NWNavPush(w.itemWorth)
end

function M.ShowWorthClass(cls, day)
  local w = M.wealth
  if not (w and w.classView) then return end
  if not day then
    if w.dayView and w.dayView:IsShown() and w.dayView.day then
      day = w.dayView.day
    else
      local hist = M.NWHist()
      if hist then for d in pairs(hist) do if not day or d > day then day = d end end end
    end
  end
  if not day then return end
  w.classView.cls = cls
  w.classView.day = day
  M.FillWorthClass()
  M.NWNavPush(w.classView)
end

function M.RefreshWealth()
  local w = M.wealth
  if not w then return end
  local nw = (M.RecordNetWorth and M.RecordNetWorth()) or (M.NetWorth and M.NetWorth())
  if not nw then return end
  w.nw = nw
  w.total:SetText(M.MoneyPlain(nw.total))

  local hist = M.NWHist()
  -- attribution over the shared chart timeframe: feeds the hero decomposition,
  -- the mini movers, the class deltas and the movers drill-down
  local at = M.WorthAttribution and M.WorthAttribution(nw) or nil
  w.attrib = at

  local GRN, RED, MUT = hexC(C.green), hexC(C.red), hexC(C.muted)
  local function pmC(v)
    local col = (math.abs(v) < 1000) and MUT or ((v >= 0) and GRN or RED)
    return col .. fmtDelta(v) .. "|r"
  end
  local tRef = at and at.tRefDay or nil
  local refVal = tRef and hist and hist[tRef] and hist[tRef].t or nil
  local refLbl = tRef and M.DayLabel(tRef)
  -- 1W draws the intraday tail: its line starts at the first point of the
  -- oldest covered day, not at that day's closing snapshot - the headline
  -- has to start there too to match the chart's endpoints
  local intraRef = false
  if refVal and M.ChartRangeDays and M.ChartRangeDays() == 7 and M.NWIntra then
    local ni = M.NWIntra()
    for i = 1, #ni do
      local d = math.floor((ni[i].ts - M.C.SCAN_DAY_0) / 86400)
      if d == tRef then
        refVal, intraRef = ni[i].t, true
        refLbl = refLbl .. " " .. date("%H:%M", ni[i].ts)
        break
      elseif d > tRef then
        break
      end
    end
  end
  if refVal and refVal > 0 then
    -- headline on its own 350px line; the decomposition below it (the movers
    -- headers carry the decomposition's reference day)
    local d = nw.total - refVal
    w.delta:SetText(string.format("since %s   %s%s%s  (%+.1f%%)|r", refLbl,
      (d >= 0) and GRN or RED, (d >= 0) and "+" or "-", M.MoneyPlain(math.abs(d)), d / refVal * 100))
    colorize(w.delta, C.sub)
    local sub = MUT .. "mkt|r " .. pmC(at.market)
      .. MUT .. "   qty|r " .. pmC(at.stock)
      .. MUT .. "   gold|r " .. pmC(at.gold)
    if math.abs(at.residual or 0) >= 1000 and math.abs(at.residual) >= math.abs(d) * 0.05 then
      sub = sub .. MUT .. "   other|r " .. pmC(at.residual)
    end
    -- per-item quantities exist only in younger snapshots: when the timeframe
    -- reaches further back, the split is measured from a later day - say so,
    -- or the parts don't add up to the headline above
    if at.refDay and (at.refDay ~= tRef or intraRef) then
      sub = MUT .. "since " .. M.DayLabel(at.refDay) .. ":|r  " .. sub
    end
    w.deltaSub:SetText(sub)
    colorize(w.deltaSub, C.sub)
  else
    w.delta:SetText("tracking starts now \194\183 the history fills up day by day")
    colorize(w.delta, C.muted)
    w.deltaSub:SetText("")
  end

  -- mini movers in the hero band (top 3 gainers / losers of the window)
  local gains, losses = {}, {}
  if at then
    for _, e in ipairs(at.items) do
      -- 0.1g floor: churn rows (kept for their |trade| alone) carry a pnl of a
      -- few copper, and fmtDelta would head TOP GAINERS with a dash
      if e.pnl >= 1000 and #gains < 3 then gains[#gains + 1] = e
      elseif e.pnl <= -1000 and #losses < 3 then losses[#losses + 1] = e end
      if #gains >= 3 and #losses >= 3 then break end
    end
  end
  local function fillMini(rows, list)
    for i = 1, 3 do
      local r = rows[i]
      local e = list[i]
      r.btn.e = e
      if e then
        setItemName(r.name, tostring(e.id))
        r.val:SetText(fmtDelta(e.pnl)); colorize(r.val, deltaColor(e.pnl))
      else
        r.name:SetText(""); r.val:SetText("")
      end
    end
  end
  if w.gainRows then fillMini(w.gainRows, gains); fillMini(w.loseRows, losses) end
  -- hidden entirely while there is nothing to show (no attribution yet, or a
  -- flat window) -- headers without rows just looked broken
  local showMini = (at ~= nil) and (#gains + #losses) > 0
  if w.mvHeads then
    local since = at and ("  \194\183  since " .. M.DayLabel(at.refDay)) or ""
    w.mvHeads[1]:SetText("TOP GAINERS" .. since)
    w.mvHeads[2]:SetText("TOP LOSERS" .. since)
    for _, fsx in ipairs(w.mvHeads) do fsx:SetShown(showMini) end
  end
  if w.whatMoved then w.whatMoved:SetShown(at ~= nil) end
  if w.deltaBtn then w.deltaBtn:EnableMouse(at ~= nil) end

  -- taller window: the chart takes ~45% of the extra room (capped), the
  -- character list grows with the rest instead of staying fixed at 8 rows
  local ex = extraH(M.panels and M.panels[TAB["Net Worth"]])
  local chartH = 170 + math.min(math.floor(ex * 0.45), 200)
  if w.chart then w.chart:SetHeight(chartH) end
  local anchorY = 82 + chartH
  if w.lowerAnchor then w.lowerAnchor:SetPoint("TOPLEFT", 0, -anchorY) end
  if w.chart and M.RenderNetWorthChart then
    C_Timer.After(0, function() M.RenderNetWorthChart(w.chart) end)
  end
  w._charVis = availRows(M.panels and M.panels[TAB["Net Worth"]], anchorY + 42, 17, 7)
  if w.mkCharRow then for i = #w.charRows + 1, w._charVis do w.mkCharRow(i) end end

  local order = M.ASSET_ORDER or { "Money" }
  local total = (nw.total > 0) and nw.total or 1
  local maxv = 1
  for _, name in ipairs(order) do local v = nw.classes[name] or 0; if v > maxv then maxv = v end end
  -- class change reads the SAME reference day as every other change column
  -- (the iq day the decomposition uses -- Money's change equals the gold part)
  local snapT = at and hist and hist[at.refDay] or nil
  if w.classHint then
    w.classHint:SetText("BY ASSET CLASS"
      .. (at and ("  \194\183  change since " .. M.DayLabel(at.refDay)) or ""))
  end
  for i, name in ipairs(order) do
    local r = w.classRows[i]
    if r then
      local v = nw.classes[name] or 0
      if r.btn then r.btn.cls = name end
      r.name:SetText(name)
      r.val:SetText(M.MoneyPlain(v))
      r.pct:SetText(string.format("%.0f%%", v / total * 100))
      local col = C[CLASS_COLOR[name] or "muted"]
      r.bar:SetColorTexture(col[1], col[2], col[3], 0.9)
      r.bar:SetWidth(math.max(1, 150 * (v / maxv)))
      if r.chg then
        local prev = snapT and snapT.c and snapT.c[name]
        if prev ~= nil then
          local dd = v - prev
          r.chg:SetText(fmtDelta(dd)); colorize(r.chg, deltaColor(dd))
        else
          r.chg:SetText("\226\128\147"); colorize(r.chg, C.muted)
        end
      end
    end
  end

  if M.FillCharRows then M.FillCharRows(nil) end
  -- graveyard summary row directly under the last visible character row
  if w.graveRow then
    local n = nw.graveCount or 0
    if n > 0 then
      w.graveRow:ClearAllPoints()
      w.graveRow:SetPoint("TOPLEFT", w.lowerAnchor, "TOPLEFT", 530, -(20 + (w._charVis or 8) * 17 + 4))
      w.graveRow.lbl:SetText(string.format("GRAVEYARD  \194\183  %d fallen", n))
      w.graveRow.val:SetText(M.MoneyPlain(nw.graveTotal or 0))
      w.graveRow:Show(); w.graveRow.lbl:Show(); w.graveRow.val:Show()
    else
      w.graveView = nil
      w.graveRow:Hide(); w.graveRow.lbl:Hide(); w.graveRow.val:Hide()
    end
  end
  -- keep open drill-downs current with the fresh data
  if w.itemView and w.itemView:IsShown() and M.FillCharItems then M.FillCharItems() end
  if w.dayView and w.dayView:IsShown() and M.FillWorthDay then M.FillWorthDay() end
  if w.classView and w.classView:IsShown() and M.FillWorthClass then M.FillWorthClass() end
  if w.itemWorth and w.itemWorth:IsShown() and M.FillItemWorth then M.FillItemWorth() end
  if w.moversView and w.moversView:IsShown() and M.FillMovers then M.FillMovers() end
end

-- ===== Tab 5: Charts ========================================================
function M.BuildCharts(panel)
  local list = CreateFrame("Frame", nil, panel)
  list:SetPoint("TOPLEFT", 0, 0); list:SetPoint("BOTTOMLEFT", 0, 0); list:SetWidth(190)
  vline(panel, 196)
  local csearch = T.Input(list, 186, 22, "Search item...", function(txt)
    M.chartSearch = (txt or ""):lower(); M.chartListOff = 0; M.RefreshCharts()
  end)
  csearch:SetPoint("TOPLEFT", 2, -2)
  M.chartSearch = ""
  local lt = T.Text(list, T.SIZE.tiny, "muted", T.FONT_MED)
  lt:SetPoint("TOPLEFT", 4, -32); lt:SetText("RECENTLY VIEWED")
  M.chartListLabel = lt
  M.chartBtns = {}
  M._mkChartBtn = function(r)
    local b = CreateFrame("Button", nil, list)
    b:SetSize(184, 22); b:SetPoint("TOPLEFT", 2, -50 - (r - 1) * 24)
    if r % 2 == 0 then
      local zb = b:CreateTexture(nil, "BACKGROUND"); zb:SetAllPoints(); zb:SetColorTexture(1, 1, 1, 0.02)
    end
    local sel = b:CreateTexture(nil, "BACKGROUND"); sel:SetAllPoints()
    sel:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.12); sel:Hide()
    b.sel = sel
    local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.05)
    b.fs = T.Text(b, T.SIZE.body)
    b.fs:SetPoint("LEFT", 6, 0); b.fs:SetWidth(172); b.fs:SetJustifyH("LEFT")
    b:SetScript("OnEnter", function() if b.key then ShowItemTip(b.key) end end)
    b:SetScript("OnLeave", HideTip)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(_, mouse)
      if not b.key then return end
      if ItemMenuClick(mouse, b.key) then return end
      if M.ModPostDown() then M.PostItemStats(b.key); return end
      if M.ModSearchDown() then M.ItemShiftAction(b.key); return end
      M.SetChartKey(b.key); M.RefreshCharts()
    end)
    M.chartBtns[r] = b
  end
  for r = 1, 10 do M._mkChartBtn(r) end
  -- the history keeps up to 30 entries: mouse wheel scrolls what the visible
  -- rows cannot hold
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    local n = #(M._chartListData or {})
    local vis = availRows(M.panels and M.panels[TAB.Charts], 58, 24, 10)
    local maxOff = math.max(0, n - vis)
    local off = math.max(0, math.min(maxOff, (M.chartListOff or 0) - delta * 3))
    if off ~= (M.chartListOff or 0) then
      M.chartListOff = off
      if M.FillChartList then M.FillChartList() end
    end
  end)

  -- the item NAME is the biggest line (above the signal in the hierarchy);
  -- category / qty / days sit small and right-aligned on the same line
  local titleIcon = panel:CreateTexture(nil, "ARTWORK")
  titleIcon:SetSize(22, 22); titleIcon:SetPoint("TOPLEFT", 206, -5)
  titleIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)   -- shave the stock icon border
  titleIcon:Hide()
  M.chartTitleIcon = titleIcon
  local title = T.Text(panel, T.SIZE.h1 + 2, "text", T.FONT_SEMI)
  title:SetPoint("TOPLEFT", 234, -8); title:SetPoint("TOPRIGHT", -12, -8); title:SetJustifyH("LEFT")
  M.chartTitle = title
  -- the header (icon + name) is a live item link: hover shows the in-game
  -- item tooltip, a click (or right-click) opens the item menu with every
  -- page, shift-click runs the AH search, alt-click posts the stats.
  -- Width follows the rendered name (set in RefreshCharts).
  local titleBtn = CreateFrame("Button", nil, panel)
  titleBtn:SetPoint("TOPLEFT", 206, -4); titleBtn:SetSize(150, 26)
  titleBtn:SetFrameLevel(panel:GetFrameLevel() + 10)
  titleBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  titleBtn:SetScript("OnEnter", function() if M.chartKey then ShowItemTip(M.chartKey) end end)
  titleBtn:SetScript("OnLeave", HideTip)
  titleBtn:SetScript("OnClick", function()
    if not M.chartKey then return end
    if M.ModPostDown() then M.PostItemStats(M.chartKey)
    elseif M.ModSearchDown() then M.ItemShiftAction(M.chartKey)
    else HideTip(); if M.ItemMenu then M.ItemMenu(M.chartKey) end end
  end)
  M.chartTitleBtn = titleBtn
  -- the item's other pages, right next to its name: craft tree, your trades,
  -- your stock and the watchlist toggle (the offer book has its own switch
  -- above the chart). Placed behind the measured name in RefreshCharts.
  if M.LinkBar then
    M.chartLinks = M.LinkBar(panel, { except = "chart", skip = { book = true }, watch = true })
    M.chartLinks:SetFrameLevel(panel:GetFrameLevel() + 12)
    M.chartLinks:Hide()
  end
  -- category / avg qty / days: quiet, right-aligned on the "your record" line
  M.chartMeta = T.Text(panel, T.SIZE.small, "muted")
  M.chartMeta:SetPoint("TOPRIGHT", -12, -85); M.chartMeta:SetJustifyH("RIGHT")
  -- Header data, in three lines with a clear hierarchy instead of a KPI grid:
  -- a big colored SIGNAL (the one thing to see), one calm market fact line,
  -- and one dimmed personal line that only exists when there is history.
  M.chartSignal = T.Text(panel, T.SIZE.h1, "text", T.FONT_SEMI)
  M.chartSignal:SetPoint("TOPLEFT", 206, -38); M.chartSignal:SetPoint("TOPRIGHT", -12, -38)
  M.chartSignal:SetJustifyH("LEFT")
  M.chartLine1 = T.Text(panel, T.SIZE.body, "text")
  M.chartLine1:SetPoint("TOPLEFT", 206, -64); M.chartLine1:SetPoint("TOPRIGHT", -12, -64)
  M.chartLine1:SetJustifyH("LEFT")
  M.chartLine2 = T.Text(panel, T.SIZE.small, "sub")
  -- ends where the category / qty / days read-out on its right begins
  -- (that read-out sizes to its text; RefreshCharts lets it yield)
  M.chartLine2:SetPoint("TOPLEFT", 206, -84); M.chartLine2:SetPoint("TOPRIGHT", M.chartMeta, "TOPLEFT", -16, 1)
  M.chartLine2:SetJustifyH("LEFT")
  -- invisible hover strips: FontStrings take no mouse, so each header line
  -- gets a thin button carrying its explanation (full math lives in Help)
  local function hoverStrip(y, h, tipTitle, tipLines, rightPad)
    local b = CreateFrame("Button", nil, panel)
    b:SetPoint("TOPLEFT", 206, y); b:SetPoint("TOPRIGHT", rightPad or -12, y); b:SetHeight(h)
    if T.HelpTip then T.HelpTip(b, tipTitle, tipLines, "ANCHOR_CURSOR") end
    return b
  end
  -- the signal strip stops short of the "why these numbers?" link, which
  -- otherwise sat underneath it and never received hover or click
  hoverStrip(-38, 22, "The signal", {
    "BUY / SELL / NEUTRAL compares the current price with the item's Fair price; the threshold is +/-15%. BUY = clearly cheaper than fair, SELL = clearly pricier, NEUTRAL = inside the band.",
    "The percentage is that distance; the odds are the chance that ONE 48-hour auction sells at the CURRENT price, measured from your own sold-vs-expired history.",
    "The full method with a worked example is in the Help tab." }, -150)
  hoverStrip(-64, 16, "The market numbers", {
    "Current - the cheapest buyout in the newest scan.",
    "Fair - the trimmed, recency-weighted market value (its %-number is the sell chance at that price). 'oversupplied' means even that level misses the target sell chance - post fewer, not cheaper.",
    "The maths:  B = sum(w\194\183low) / sum(w) over the last 14 daily lows, w = 0.5^(age/half-life) - the half-life is yours to set (Settings > FAIR PRICE, default 7d); days with low > 1.5\194\183median are trimmed as no-demand spikes, and one-scan dips under median/1.5 that were gone by the day's last scan.",
    "P(sell at r) = sigmoid(a - 3\194\183ln(r/r0)) with r = price/floor7, fitted from your sold/expired record; r* is the r where P = 50%.",
    "Fair = B \194\183 clamp(floor7\194\183r*/B, 1, 1.10) - at most +10% over the base, and never past the prices your sales really cleared at.",
    "Crafted - what it costs to make from its materials at the newest prices (each material bought or made, whichever is cheaper); the % is the distance to Current. Hover it for a peek at the tree, click to open the Crafting tab.",
    "Quick-sell - at/just under the current floor: sells near-certainly, with less margin.",
    "Sells - how fast it moves: your realized sales per day and the market's liquidity class.",
    "How these are computed, with examples: Help tab." })
  -- the record line opens this item's trades (By Item, unfolded); it stops
  -- short of the category/qty/days read-out on the right
  local recStrip = hoverStrip(-84, 14, "Your record", {
    "Built purely from the AH mail you collect: auctions sold vs returned (last 75 days), the sell-through rating, your average sale and purchase price per unit, and the realized net after the AH cut.",
    "Click: every transaction of this item in the Trades tab." }, -240)
  recStrip:SetScript("OnClick", function()
    if not (M.chartKey and M.Go and M.ItemLinkInfo) then return end
    if M.ItemLinkInfo(M.chartKey).trades then M.Go("trades", M.chartKey) end
  end)
  local recHl = recStrip:CreateTexture(nil, "HIGHLIGHT")
  recHl:SetAllPoints(); recHl:SetColorTexture(C.green[1], C.green[2], C.green[3], 0.06)
  -- "why these numbers?" opens the Help-tab story rebuilt from THIS item's
  -- real data (its scan days, its own odds curve)
  local whyBtn = CreateFrame("Button", nil, panel)
  local wbf = whyBtn:CreateFontString(nil, "OVERLAY")
  T.RegFont(wbf, T.FONT_MED, T.SIZE.small); wbf:SetPoint("RIGHT", 0, 0)
  wbf:SetText("why these numbers?"); wbf:SetTextColor(T.Unpack(C.accent))
  whyBtn:SetSize(130, 16); whyBtn:SetPoint("TOPRIGHT", -12, -40)
  whyBtn:SetFrameLevel(panel:GetFrameLevel() + 10)
  whyBtn:SetScript("OnEnter", function() wbf:SetTextColor(T.Unpack(C.text)) end)
  whyBtn:SetScript("OnLeave", function() wbf:SetTextColor(T.Unpack(C.accent)) end)
  whyBtn:SetScript("OnClick", function()
    if M.chartKey and M.ShowWhy then M.ShowWhy(M.chartKey) end
  end)
  if T.HelpTip then
    T.HelpTip(whyBtn, "Why these numbers?", {
      "Opens the Fair and odds explanation rebuilt from THIS item's own data: its real scan days with the trimmed ones marked, and its own sell-odds curve with Fair and the current price on it." }, "ANCHOR_CURSOR")
  end
  -- the craft tree is a chip next to the item name now (M.chartLinks). The
  -- "Crafted" value in the market line stays a live link too: an underline
  -- shows it, hover peeks at the tree, click opens it
  local chot = CreateFrame("Button", nil, panel)
  chot:SetHeight(18)
  chot:SetFrameLevel(panel:GetFrameLevel() + 12)
  local cul = chot:CreateTexture(nil, "OVERLAY")
  cul:SetColorTexture(C.mint[1], C.mint[2], C.mint[3], 0.55); cul:SetHeight(1)
  cul:SetPoint("BOTTOMLEFT", 4, 2); cul:SetPoint("BOTTOMRIGHT", -4, 2)
  chot:SetScript("OnEnter", function(self)
    cul:SetColorTexture(C.mint[1], C.mint[2], C.mint[3], 1)
    if M.chartKey and M.CraftPeek then M.CraftPeek(self, M.BaseID(M.chartKey)) end
  end)
  chot:SetScript("OnLeave", function()
    cul:SetColorTexture(C.mint[1], C.mint[2], C.mint[3], 0.55)
    if M.HideCraftPeek then M.HideCraftPeek() end
  end)
  chot:SetScript("OnClick", function()
    if M.HideCraftPeek then M.HideCraftPeek() end
    if M.chartKey and M.Go then M.Go("tree", M.chartKey) end
  end)
  chot:Hide()
  M.chartCraftHot = chot

  local wy = CreateFrame("Frame", nil, panel)
  wy:SetAllPoints()
  wy:SetFrameLevel(panel:GetFrameLevel() + 40)
  local wybg = wy:CreateTexture(nil, "BACKGROUND")
  wybg:SetAllPoints(); wybg:SetColorTexture(C.bg0[1], C.bg0[2], C.bg0[3], 1)
  wy:EnableMouse(true)
  wy.title = T.Text(wy, T.SIZE.h1, "text", T.FONT_SEMI)
  wy.title:SetPoint("TOPLEFT", 2, -4)
  wy.sub = T.Text(wy, T.SIZE.small, "sub")
  wy.sub:SetPoint("TOPLEFT", 2, -28); wy.sub:SetPoint("TOPRIGHT", -110, -28)
  wy.sub:SetJustifyH("LEFT"); wy.sub:SetSpacing(3); wy.sub:SetWordWrap(true)
  local wyBack = T.Button(wy, "< back", 88, 22)
  wyBack:SetPoint("TOPRIGHT", -2, -2)
  wyBack:SetScript("OnClick", function() wy:Hide() end)
  local capA = T.Text(wy, T.SIZE.tiny, "muted", T.FONT_MED)
  capA:SetPoint("TOPLEFT", 2, -70)
  capA:SetText("1 \194\183 FAIR \226\128\148 from this item's scan days")
  local capB = T.Text(wy, T.SIZE.tiny, "muted", T.FONT_MED)
  capB:SetPoint("TOPLEFT", wy, "TOP", 16, -70)
  capB:SetText("2 \194\183 SELL ODDS \226\128\148 from your sold/expired record")
  wy.fairC = CreateFrame("Frame", nil, wy)
  wy.fairC:SetPoint("TOPLEFT", 0, -86)
  wy.fairC:SetPoint("BOTTOMRIGHT", wy, "BOTTOM", -14, 30)
  wy.oddsC = CreateFrame("Frame", nil, wy)
  wy.oddsC:SetPoint("TOPLEFT", wy, "TOP", 16, -86)
  wy.oddsC:SetPoint("BOTTOMRIGHT", -4, 30)
  wy.note = T.Text(wy, T.SIZE.small, "muted")
  wy.note:SetPoint("BOTTOMLEFT", 2, 8)
  wy.note:SetText("General method with a worked example: the Help tab.")
  wy:Hide()
  M.whyView = wy

  function M.FillWhy()
    local key = wy.key
    if not key then return end
    local qc = M.ItemQualityColor(key)
    local m = M.Metrics(M.GetSeries(key) or {}, key)
    wy.title:SetText("Why " .. M.ItemName(key) .. " shows these numbers")
    wy.title:SetTextColor(qc.r, qc.g, qc.b)
    if m and m.base and m.base > 0 then
      local oddsTxt = m.odds and string.format("~%.0f%%", m.odds * 100) or "n/a"
      wy.sub:SetText(string.format(
        "Base = trimmed average of the last 14 daily lows: %s.   Lift from real sales: x%.2f%s  \226\134\146  Fair %s.       Current %s = %+.0f%% vs Fair  \226\134\146  %s odds that ONE 48h auction sells.",
        M.MoneyPlain(m.base), m.fair / m.base, m.fairCapped and " (oversupplied: even this level misses the target odds)" or "",
        M.MoneyPlain(m.fair), M.MoneyPlain(m.cur), m.delta * 100, oddsTxt))
    else
      wy.sub:SetText("Not enough price data yet.")
    end
    C_Timer.After(0, function()
      if not wy:IsShown() then return end
      if M.RenderWhyFair then M.RenderWhyFair(wy.fairC, key) end
      if M.RenderWhyOdds then M.RenderWhyOdds(wy.oddsC, key) end
    end)
  end

  function M.ShowWhy(key)
    if M.depthView then M.depthView:Hide() end
    wy.key = key
    M.FillWhy()
    wy:Show()
  end

  -- "offer book" = the supply ladder of the newest scan: every unit price on
  -- the AH (cheapest 20) with units, auctions and the cumulative supply --
  -- the AH has no buy orders, so this is the ask side only
  -- offer book / split: ONE two-function control in the classic segment
  -- style, sitting left of the timeframe switch. The big left half opens
  -- the full-screen book, the small right half the chart+ladder split.
  local depthSeg = T.Segment(panel, {
    { key = "book",  label = "offer book" },
    { key = "split", label = "split" },
  }, function(key)
    if not (M.chartKey and M.ShowDepth) then return end
    M.db.config.depthSplit = (key == "split") or nil
    M.ShowDepth(M.chartKey)
  end)
  depthSeg.frame:SetPoint("TOPRIGHT", -228, -108)
  depthSeg.frame:SetFrameLevel(panel:GetFrameLevel() + 10)
  do
    -- the big "offer book" half reads as the main action: a faint accent
    -- wash of its own (under the select highlight) and a 1px divider
    -- towards the split half. Both live on the buttons, not the frame --
    -- child-frame regions always draw above parent regions.
    local b1, b2 = depthSeg.buttons[1], depthSeg.buttons[2]
    local wash = b1:CreateTexture(nil, "BACKGROUND", nil, -1)
    wash:SetAllPoints()
    wash:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.10)
    local div = b2:CreateTexture(nil, "OVERLAY")
    div:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
    div:SetWidth(1)
    div:SetPoint("TOPLEFT", 0, 0); div:SetPoint("BOTTOMLEFT", 0, 0)
  end
  if T.HelpTip then
    T.HelpTip(depthSeg.frame, "Offer book", {
      "offer book - every price this item is listed at in your newest full scan, cheapest first: units, auctions and the supply you would have to buy through to reach each price (sell side only, the AH has no buy orders).",
      "split - the price chart on the left and the supply ladder on the right." })
  end

  -- price alerts for the current item: two thresholds, checked after every
  -- scan / sync merge (Data.lua CheckAlerts); "/midas alerts" lists them all
  local alertBar = CreateFrame("Frame", nil, panel)
  alertBar:SetSize(252, 22)
  alertBar:SetPoint("TOPRIGHT", depthSeg.frame, "TOPLEFT", -18, 0)
  local alLbl = T.Text(alertBar, T.SIZE.tiny, "muted", T.FONT_MED)
  alLbl:SetPoint("LEFT", 0, 0); alLbl:SetText("ALERT")
  local function alertField(ph, x)
    local box = T.Surface(alertBar, "bg0", "border")
    box:SetSize(86, 20); box:SetPoint("LEFT", x, 0)
    local edit = CreateFrame("EditBox", nil, box)
    edit:SetPoint("LEFT", 6, 0); edit:SetPoint("RIGHT", -6, 0); edit:SetHeight(18)
    T.RegFont(edit, T.FONT, T.SIZE.small)
    edit:SetTextColor(C.text[1], C.text[2], C.text[3])
    edit:SetAutoFocus(false)
    local phFS = box:CreateFontString(nil, "OVERLAY")
    T.RegFont(phFS, T.FONT, T.SIZE.small)
    phFS:SetPoint("LEFT", edit, "LEFT", 1, 0)
    phFS:SetTextColor(C.muted[1], C.muted[2], C.muted[3]); phFS:SetText(ph)
    edit:SetScript("OnTextChanged", function(self) phFS:SetShown((self:GetText() or "") == "") end)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box.edit = edit
    return box
  end
  local alertLo = alertField("below", 42)
  local alertHi = alertField("above", 134)
  local function saveAlerts()
    if not (M.chartKey and M.db) then return end
    M.db.alerts = M.db.alerts or {}
    local realm = M.RealmKey()
    M.db.alerts[realm] = M.db.alerts[realm] or {}
    local lo = M.ParseMoney and M.ParseMoney(alertLo.edit:GetText())
    local hi = M.ParseMoney and M.ParseMoney(alertHi.edit:GetText())
    if lo or hi then
      M.db.alerts[realm][M.chartKey] = { below = lo, above = hi }
    else
      M.db.alerts[realm][M.chartKey] = nil
    end
    M.RerenderCharts()   -- the big chart draws the limit lines right away
  end
  for _, b in ipairs({ alertLo, alertHi }) do
    b.edit:SetScript("OnEnterPressed", function(s) saveAlerts(); s:ClearFocus() end)
    b.edit:SetScript("OnEditFocusLost", saveAlerts)
  end
  M.alertUI = { bar = alertBar, below = alertLo, above = alertHi }
  if T.HelpTip then
    T.HelpTip(alertBar, "Price alert", {
      "Rings the raid-warning bell (plus a chat line) when this item's newest scanned or synced price reaches your limit: below = buy chance, above = sell moment.",
      "Prices read \"4g50s\", \"120s\" or a bare number as gold; empty both fields to drop the alert. Each side fires once and re-arms when the price leaves the limit.",
      "\"/midas alerts\" lists every alert on this realm." })
  end

  local dv = CreateFrame("Frame", nil, panel)
  dv:SetAllPoints()
  dv:SetFrameLevel(panel:GetFrameLevel() + 40)
  local dvbg = dv:CreateTexture(nil, "BACKGROUND")
  dvbg:SetAllPoints(); dvbg:SetColorTexture(C.bg0[1], C.bg0[2], C.bg0[3], 1)
  dv:EnableMouse(true)
  dv.icon = dv:CreateTexture(nil, "ARTWORK")
  dv.icon:SetSize(20, 20); dv.icon:SetPoint("TOPLEFT", 2, -3)
  dv.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  dv.title = T.Text(dv, T.SIZE.h1, "text", T.FONT_SEMI)
  dv.title:SetPoint("TOPLEFT", 28, -4)
  -- same live header as the chart: tooltip on hover, shift = AH search,
  -- alt = post stats (width follows the name, set in FillDepth)
  dv.titleBtn = CreateFrame("Button", nil, dv)
  dv.titleBtn:SetPoint("TOPLEFT", 0, -2); dv.titleBtn:SetSize(140, 24)
  dv.titleBtn:SetFrameLevel(dv:GetFrameLevel() + 5)
  dv.titleBtn:SetScript("OnEnter", function() if dv.key then ShowItemTip(dv.key) end end)
  dv.titleBtn:SetScript("OnLeave", HideTip)
  dv.titleBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  dv.titleBtn:SetScript("OnClick", function()
    if not dv.key then return end
    if M.ModPostDown() then M.PostItemStats(dv.key)
    elseif M.ModSearchDown() then M.ItemShiftAction(dv.key)
    else HideTip(); if M.ItemMenu then M.ItemMenu(dv.key) end end
  end)
  dv.sub = T.Text(dv, T.SIZE.small, "sub")
  dv.sub:SetPoint("TOPLEFT", 2, -28); dv.sub:SetPoint("TOPRIGHT", -110, -28)
  dv.sub:SetJustifyH("LEFT"); dv.sub:SetWordWrap(true)
  local dvBack = T.Button(dv, "< back", 88, 22)
  dvBack:SetPoint("TOPRIGHT", -2, -2)
  dvBack:SetScript("OnClick", function() dv:Hide() end)
  -- split view: the price chart keeps the upper half of the tab while the
  -- ladder + card fill the lower -- the trend and the live asks in one look
  local dvSplit = T.Button(dv, "split view", 88, 22)
  dvSplit:SetPoint("TOPRIGHT", dvBack, "TOPLEFT", -6, 0)
  local layoutDepth   -- defined next to the chart canvas (it re-anchors both)
  dvSplit:SetScript("OnClick", function()
    M.db.config.depthSplit = not M.db.config.depthSplit or nil
    if layoutDepth then layoutDepth() end
    if M.chartKey and M.RenderItemChart then M.RenderItemChart(M.canvas, M.chartKey) end
    M.FillDepth()
  end)
  if T.HelpTip then
    T.HelpTip(dvSplit, "Split view", {
      "Shows the price chart on the left and a reduced offer book (the supply ladder) on the right.",
      "Midas remembers the choice." }, "ANCHOR_CURSOR")
  end
  -- the item's other pages as chips, growing leftwards from the buttons
  -- (full view only: in split view the chart header above carries them)
  if M.LinkBar then
    dv.links = M.LinkBar(dv, { except = "book", watch = true })
    dv.links:SetPoint("TOPRIGHT", dvSplit, "TOPLEFT", -10, -1)
    dv.links:SetFrameLevel(dv:GetFrameLevel() + 6)
  end
  -- Offer book, designed for the eye: ONE question per area.
  -- Left, the ladder (elastic, fills the window): cheapest ask on top, one
  -- row per shown price. Bars mean supply and nothing else: grey = everything
  -- cheaper, colored = this price -> the cumulative "tree". Green only means
  -- "below Fair" (the buy zone). Price markers (Fair, quick-sell, 7-day floor,
  -- your buy/sell price) are slim rows sorted in by price: a hairline in their
  -- color runs to the supply you would have bought through by then, ending in
  -- a dot -- they read the tree, they never add to it.
  -- Right, the verdict card (fixed width): the floor, its distance to Fair,
  -- a plain-words read-out and the price markers with what they cost to reach.
  local CARD_W, GAP, TOP = 300, 28, -20
  local PU = C.purple or C.accent
  local DOT = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
  local card = T.Surface(dv, "bg1", "border")
  card:SetPoint("TOPRIGHT", -2, -56); card:SetPoint("BOTTOMRIGHT", -2, 8); card:SetWidth(CARD_W)
  local lad = CreateFrame("Frame", nil, dv)
  lad:SetPoint("TOPLEFT", 0, -56); lad:SetPoint("BOTTOMRIGHT", card, "BOTTOMLEFT", -GAP, 0)
  -- column geometry: price + marker on the left, three numbers pinned right
  local PW, MX, BX = 82, 90, 136           -- price width / marker x / bar start
  local RC = { { "AUCT.", 112, 40 }, { "TOTAL", 58, 48 }, { "VS FAIR", 0, 52 } }  -- right offset, width
  local function rcell(parent, off, w, y, size, colorKey, variant)
    local fs = T.Text(parent, size, colorKey, variant)
    fs:SetPoint("TOPRIGHT", -off, y); fs:SetWidth(w); fs:SetJustifyH("RIGHT")
    return fs
  end
  cell(lad, 0, 0, PW, "RIGHT", T.SIZE.tiny, "muted", T.FONT_MED):SetText("PRICE")
  dv.headSupply = cell(lad, BX, 0, 300, "LEFT", T.SIZE.tiny, "muted", T.FONT_MED)
  dv.headSupply:SetText("SUPPLY   grey = cheaper, bar = at this price")
  for _, c in ipairs(RC) do rcell(lad, c[2], c[3], 0, T.SIZE.tiny, "muted", T.FONT_MED):SetText(c[1]) end
  local hr = lad:CreateTexture(nil, "ARTWORK")                -- header hairline
  hr:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.8); hr:SetHeight(1)
  hr:SetPoint("TOPLEFT", 0, -14); hr:SetPoint("TOPRIGHT", 0, -14)
  dv.zone = lad:CreateTexture(nil, "BACKGROUND")              -- buy-zone wash
  dv.zone:SetColorTexture(C.green[1], C.green[2], C.green[3], 0.05)
  dv.zoneEdge = lad:CreateTexture(nil, "BORDER")
  dv.zoneEdge:SetColorTexture(C.green[1], C.green[2], C.green[3], 0.8); dv.zoneEdge:SetWidth(2)
  local NROW = 20
  dv.rows = {}
  for r = 1, NROW do
    local row = CreateFrame("Frame", nil, lad)
    row.price = T.Text(row, T.SIZE.body, "text", T.FONT_MED)
    row.price:SetPoint("LEFT", 0, 0); row.price:SetWidth(PW); row.price:SetJustifyH("RIGHT")
    row.mark = T.Text(row, T.SIZE.tiny, "muted", T.FONT_MED)
    row.mark:SetPoint("LEFT", MX, 0)
    row.ghost = row:CreateTexture(nil, "BORDER")
    row.ghost:SetColorTexture(C.sub[1], C.sub[2], C.sub[3], 0.14)
    row.bar = row:CreateTexture(nil, "ARTWORK")
    row.own = row:CreateTexture(nil, "ARTWORK")   -- your share of this price, marker color
    row.ownLine = row:CreateTexture(nil, "ARTWORK")   -- YOUR-ASK hairline, left of the bar
    row.ownLbl = T.Text(row, T.SIZE.tiny, "text", T.FONT_SEMI)
    row.qty = T.Text(row, T.SIZE.small, "text", T.FONT_MED)
    row.qty:SetPoint("LEFT", row.bar, "RIGHT", 6, 0)
    row.auc = T.Text(row, T.SIZE.small, "muted"); row.auc:SetPoint("RIGHT", -RC[1][2], 0)
    row.cum = T.Text(row, T.SIZE.small, "sub");   row.cum:SetPoint("RIGHT", -RC[2][2], 0)
    row.vs  = T.Text(row, T.SIZE.small, "sub");   row.vs:SetPoint("RIGHT", -RC[3][2], 0)
    -- hover: light the row, the card answers "what if I buy everything up to here"
    row.hl = row:CreateTexture(nil, "BACKGROUND", nil, 3); row.hl:SetAllPoints()
    row.hl:SetColorTexture(1, 1, 1, 0.06); row.hl:Hide()
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self) self.hl:Show(); if M.DepthHover then M.DepthHover(self.info) end end)
    row:SetScript("OnLeave", function(self) self.hl:Hide(); if M.DepthHover then M.DepthHover(nil) end end)
    dv.rows[r] = row
  end
  -- marker rows: tint, price + name in the marker color, hairline + dot
  -- (pool covers the 5 fixed markers plus up to 4 YOUR-ASK clusters)
  dv.mkRows = {}
  for r = 1, 10 do
    local row = CreateFrame("Frame", nil, lad)
    row.tint = row:CreateTexture(nil, "BACKGROUND"); row.tint:SetAllPoints()
    row.price = T.Text(row, T.SIZE.small, "text", T.FONT_SEMI)
    row.price:SetPoint("LEFT", 0, 0); row.price:SetWidth(PW); row.price:SetJustifyH("RIGHT")
    row.line = row:CreateTexture(nil, "ARTWORK")
    row.bar = row:CreateTexture(nil, "ARTWORK")   -- qty bar for YOUR-ASK markers off the ladder
    row.dot = row:CreateTexture(nil, "OVERLAY"); row.dot:SetTexture(DOT); row.dot:SetSize(7, 7)
    -- the name rides at the tip of its line (like a chart label at the line
    -- end), so line and text can never cross
    row.name = T.Text(row, T.SIZE.tiny, "text", T.FONT_SEMI); row.name:SetPoint("LEFT", row.dot, "RIGHT", 5, 0)
    row.cum = T.Text(row, T.SIZE.small, "text", T.FONT_MED); row.cum:SetPoint("RIGHT", -RC[2][2], 0)
    row.vs  = T.Text(row, T.SIZE.small, "sub"); row.vs:SetPoint("RIGHT", -RC[3][2], 0)
    -- hover: light the row, the card answers "what if I buy everything up to here"
    row.hl = row:CreateTexture(nil, "BACKGROUND", nil, 3); row.hl:SetAllPoints()
    row.hl:SetColorTexture(1, 1, 1, 0.06); row.hl:Hide()
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self) self.hl:Show(); if M.DepthHover then M.DepthHover(self.info) end end)
    row:SetScript("OnLeave", function(self) self.hl:Hide(); if M.DepthHover then M.DepthHover(nil) end end)
    dv.mkRows[r] = row
  end

  -- verdict card
  local PAD = 16
  local function lbl(y, txt)
    local f = T.Text(card, T.SIZE.tiny, "muted", T.FONT_MED); f:SetPoint("TOPLEFT", PAD, y); f:SetText(txt)
    return f
  end
  local function rule(y)
    local t = card:CreateTexture(nil, "ARTWORK"); t:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.8)
    t:SetHeight(1); t:SetPoint("TOPLEFT", PAD, y); t:SetPoint("TOPRIGHT", -PAD, y)
  end
  lbl(-14, "CHEAPEST NOW")
  dv.floor = T.Text(card, T.SIZE.h1 + 8, "text", T.FONT_SEMI)
  dv.floor:SetPoint("TOPLEFT", PAD, -28)
  dv.chip = T.Text(card, T.SIZE.body, "text", T.FONT_MED)
  dv.chip:SetPoint("TOPLEFT", PAD, -58)
  rule(-80)
  dv.say1 = T.Text(card, T.SIZE.body, "text")
  dv.say1:SetPoint("TOPLEFT", PAD, -90); dv.say1:SetPoint("TOPRIGHT", -PAD, -90)
  dv.say1:SetJustifyH("LEFT"); dv.say1:SetWordWrap(true); dv.say1:SetSpacing(3)
  dv.say2 = T.Text(card, T.SIZE.body, "sub")
  dv.say2:SetPoint("TOPLEFT", dv.say1, "BOTTOMLEFT", 0, -6); dv.say2:SetPoint("RIGHT", card, "RIGHT", -PAD, 0)
  dv.say2:SetJustifyH("LEFT"); dv.say2:SetWordWrap(true)
  rule(-152)
  lbl(-162, "PRICE MARKERS")
  -- the card list doubles as the legend (a color swatch per ladder line) and
  -- answers "what does it take to buy down to here": units + gold for every
  -- stack listed at or below the marker price
  local MC = { { "PRICE", 126, 58 }, { "UNITS", 86, 36 }, { "BUY ALL", PAD, 66 } }   -- right offset, width
  for _, c in ipairs(MC) do
    local h = T.Text(card, T.SIZE.tiny, "muted", T.FONT_MED)
    h:SetPoint("TOPRIGHT", -c[2], -162); h:SetWidth(c[3]); h:SetJustifyH("RIGHT"); h:SetText(c[1])
  end
  local MK = { { "Fair", PU }, { "Quick-sell", C.sub }, { "7-day floor", C.blue }, { "You paid", C.green },
               { "You sold", C.red }, { "Your ask", C.mint or C.accent }, { "25% units" }, { "Median ask" } }
  dv.mk = {}
  for i, e in ipairs(MK) do
    local y = -178 - (i - 1) * 14
    if e[2] then
      local sw = card:CreateTexture(nil, "ARTWORK"); sw:SetSize(8, 2)
      sw:SetPoint("TOPLEFT", PAD, y - 6); sw:SetColorTexture(e[2][1], e[2][2], e[2][3], 1)
    end
    local l = T.Text(card, T.SIZE.body, "sub"); l:SetPoint("TOPLEFT", PAD + 14, y); l:SetText(e[1])
    local cells = {}
    for ci, c in ipairs(MC) do
      local v = T.Text(card, ci == 1 and T.SIZE.body or T.SIZE.small, ci == 1 and "text" or "sub", ci == 1 and T.FONT_MED or nil)
      v:SetPoint("TOPRIGHT", -c[2], y); v:SetWidth(c[3]); v:SetJustifyH("RIGHT")
      cells[ci] = v
    end
    if e[2] then cells[1]:SetTextColor(e[2][1], e[2][2], e[2][3]) end
    dv.mk[i] = cells
  end
  rule(-296)
  dv.kpi = {}
  local KL = { "UNITS LISTED", "YOU LIST", "WITHIN +10%" }
  for i = 1, 3 do
    local cx = PAD + (i - 1) * 84
    local l = T.Text(card, T.SIZE.tiny, "muted", T.FONT_MED); l:SetPoint("TOPLEFT", cx, -304); l:SetText(KL[i])
    local v = T.Text(card, T.SIZE.h2, "text", T.FONT_MED); v:SetPoint("TOPLEFT", cx, -317)
    dv.kpi[i] = v
  end
  dv.note = T.Text(card, T.SIZE.small, "muted")
  dv.note:SetPoint("BOTTOMLEFT", PAD, 12); dv.note:SetPoint("BOTTOMRIGHT", -PAD, 12)
  dv.note:SetJustifyH("LEFT"); dv.note:SetWordWrap(true); dv.note:SetSpacing(2)
  -- hover read-out: covers the top of the card while a ladder row is hovered
  do
    local hv = CreateFrame("Frame", nil, card)
    hv:SetPoint("TOPLEFT", 1, -1); hv:SetPoint("TOPRIGHT", -1, -1); hv:SetHeight(150)
    hv:SetFrameLevel(card:GetFrameLevel() + 5)
    local bg = hv:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints()
    bg:SetColorTexture(C.bg1[1], C.bg1[2], C.bg1[3], 1)
    hv.kick = T.Text(hv, T.SIZE.tiny, "muted", T.FONT_MED); hv.kick:SetPoint("TOPLEFT", PAD - 1, -13)
    hv.price = T.Text(hv, T.SIZE.h1 + 8, "text", T.FONT_SEMI); hv.price:SetPoint("TOPLEFT", PAD - 1, -27)
    hv.sub = T.Text(hv, T.SIZE.body, "sub", T.FONT_MED); hv.sub:SetPoint("TOPLEFT", PAD - 1, -57)
    local rl = hv:CreateTexture(nil, "ARTWORK"); rl:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.8)
    rl:SetHeight(1); rl:SetPoint("TOPLEFT", PAD - 1, -79); rl:SetPoint("TOPRIGHT", -PAD + 1, -79)
    hv.k, hv.v = {}, {}
    for i = 1, 4 do
      local y = -87 - (i - 1) * 15
      hv.k[i] = T.Text(hv, T.SIZE.body, "sub"); hv.k[i]:SetPoint("TOPLEFT", PAD - 1, y)
      hv.v[i] = T.Text(hv, T.SIZE.body, "text", T.FONT_MED); hv.v[i]:SetPoint("TOPRIGHT", -PAD + 1, y)
      hv.v[i]:SetJustifyH("RIGHT")
    end
    hv:Hide()
    dv.hover = hv
  end

  -- fill the hover read-out for one ladder row (nil = back to the verdict)
  local function pct(a, b) return (a and b and b > 0) and string.format("%+.0f%%", (a / b - 1) * 100) or "-" end
  function M.DepthHover(info)
    local hv = dv.hover
    if not info then hv:Hide(); return end
    local x = dv.ctx or {}
    hv.kick:SetText("BUY EVERYTHING UP TO" .. (info.name and ("  \194\183  " .. info.name) or ""))
    hv.price:SetText(info.lbl)
    if info.rgb then hv.price:SetTextColor(info.rgb[1], info.rgb[2], info.rgb[3]) else colorize(hv.price, C.text) end
    hv.sub:SetText(string.format("%d units  \194\183  %d auctions", info.units or 0, info.auctions or 0))
    local avg = (info.units or 0) > 0 and info.cost / info.units or nil
    local rows = {
      { "Total cost", (info.cost or 0) > 0 and M.MoneyPlain(info.cost) or "-" },
      { "Average per unit", avg and (M.MoneyPlain(avg) .. "   " .. pct(avg, x.fair) .. " vs Fair") or "-" },
      { "This price vs Fair", pct(info.price, x.fair) },
      { "vs 7-day floor / quick-sell", pct(info.price, x.floor7) .. "  /  " .. pct(info.price, x.quick) },
    }
    if x.paid then rows[4] = { "vs 7-day floor / you paid", pct(info.price, x.floor7) .. "  /  " .. pct(info.price, x.paid) } end
    for i, r2 in ipairs(rows) do hv.k[i]:SetText(r2[1]); hv.v[i]:SetText(r2[2]) end
    hv:Show()
  end
  dv:Hide()
  M.depthView = dv

  function M.FillDepth()
    local key = dv.key
    if not key then return end
    local qc = M.ItemQualityColor(key)
    dv.title:SetText(M.ItemName(key))
    dv.title:SetTextColor(qc.r, qc.g, qc.b)
    local icon = M.GetItemIcon and M.GetItemIcon((M.BaseID and M.BaseID(key)) or key)
    dv.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    dv.titleBtn:SetWidth(32 + (dv.title:GetStringWidth() or 120))
    if dv.links then
      if M.db and M.db.config and M.db.config.depthSplit then
        dv.links:Hide()
      else
        -- the room between the name and the buttons on the right
        local room = (dv:GetWidth() or 0) - 2 - 88 - 6 - 88 - 10 - (28 + (dv.title:GetStringWidth() or 120) + 20)
        dv.links:SetItem(key, math.max(80, (room > 0) and room or 420))
      end
    end
    for _, row in ipairs(dv.rows) do
      row:Hide(); row.bar:Hide(); row.own:Hide(); row.ownLine:Hide(); row.ownLbl:Hide(); row.ghost:Hide()
      row.price:SetText(""); row.mark:SetText(""); row.qty:SetText("")
      row.auc:SetText(""); row.cum:SetText(""); row.vs:SetText("")
    end
    for _, r in ipairs(dv.mkRows) do r:Hide() end
    dv.hover:Hide()
    dv.zone:Hide(); dv.zoneEdge:Hide()
    for _, v in ipairs(dv.kpi) do v:SetText("") end
    for _, cells in ipairs(dv.mk) do for _, v in ipairs(cells) do v:SetText("") end end
    dv.floor:SetText(""); dv.chip:SetText(""); dv.say1:SetText(""); dv.say2:SetText(""); dv.note:SetText("")
    local id = M.BaseID and M.BaseID(key)
    local d = id and M.GetDepth and M.GetDepth(id)
    if not d or not d.levels[1] then
      dv.sub:SetText("OFFER BOOK   \194\183   " .. M.RealmKey())
      dv.say1:SetText("Not listed in your newest full scan. Scan the auction house to see who sells at which price.")
      return
    end
    local ago = math.max(0, time() - (d.ts or 0))
    local agoTxt = (ago < 3600) and string.format("%d min ago", math.floor(ago / 60))
      or (ago < 86400) and string.format("%.1f h ago", ago / 3600)
      or string.format("%d d ago", math.floor(ago / 86400))
    dv.sub:SetText("OFFER BOOK   \194\183   " .. M.RealmKey() .. "   \194\183   scanned " .. agoTxt)
    local m = M.Metrics(M.GetSeries(key) or {}, key)
    local fair = m and m.fair and m.fair > 0 and m.fair or nil
    local lv = d.levels
    -- price grouping: levels that only differ in copper read as the same
    -- price ("5g 19s" x8) -> merge them into one row per displayed price
    local gl = {}
    for _, l in ipairs(lv) do
      local lbl2 = M.MoneyPlain(l.price)
      local g = gl[#gl]
      if g and g.lbl == lbl2 then
        g.qty = g.qty + l.qty; g.auctions = g.auctions + l.auctions; g.cum = l.cum
        g.cost = g.cost + l.qty * l.price
      else
        gl[#gl + 1] = { lbl = lbl2, price = l.price, qty = l.qty, auctions = l.auctions, cum = l.cum,
                        cost = l.qty * l.price }
      end
    end
    local n = math.min(#gl, NROW)
    local LW, LH = lad:GetWidth() or 560, lad:GetHeight() or 360
    local W = math.max(80, LW - BX - (RC[1][2] + RC[1][3]) - 48)
    local maxCum = math.max(1, gl[n].cum)
    -- supply quantiles over ALL listed units (price where 25% / 50% are
    -- reached); the stored ladder holds only the cheapest levels, so a
    -- quantile beyond it stays unmarked instead of landing on its last row
    local allU = math.max(d.units or 0, d.listed or 0)
    local q25, q50
    for _, l in ipairs(lv) do
      if not q25 and l.cum >= allU * 0.25 then q25 = l.price end
      if not q50 and l.cum >= allU * 0.50 then q50 = l.price end
    end
    -- price markers, gated by the same header toggles as the charts
    -- (Fair / Floor MA / My trades); quick-sell always
    local paid = (M.chartTrades ~= false and M.RealizedBuy) and (M.RealizedBuy(key)) or nil
    -- your own active auctions of this item, over every character of this
    -- realm + faction (cached whenever you open the AH on that character)
    local myQty, myGold, myLv = 0, 0, {}
    if M.db and M.db.chars then
      for _, ch in pairs(M.db.chars) do
        local a = ch.auctions and ch.auctions[tonumber(id)]
        if a and (not M.CharInScope or M.CharInScope(ch)) then
          myQty = myQty + (a.qty or 0); myGold = myGold + (a.gold or 0)
          if a.lv then for p, q in pairs(a.lv) do myLv[p] = (myLv[p] or 0) + q end end
        end
      end
    end
    local myAsk = (myQty > 0) and (myGold / myQty) or nil
    -- own units INSIDE a scanned level (its exact copper price) vs units the
    -- scan never saw (posted after it - typically a 1c undercut that reads
    -- like the level after silver rounding): the latter extend the supply
    local lvByPrice = {}
    for _, l in ipairs(lv) do lvByPrice[l.price] = l end
    local myIn, myOut = {}, {}
    for p, q in pairs(myLv) do
      local l = scanLevelAt(lvByPrice, p)
      local inScan = l and math.min(q, l.qty) or 0
      if inScan > 0 then myIn[l.price] = (myIn[l.price] or 0) + inScan end
      if q > inScan then myOut[p] = (myOut[p] or 0) + (q - inScan) end
    end
    -- in-scan units per DISPLAYED price (same label grouping as the ladder),
    -- so a level's bar can split into the others' share and yours
    local myByLbl = {}
    if M.chartTrades ~= false then
      for p, q in pairs(myIn) do
        local l = M.MoneyPlain(p)
        myByLbl[l] = (myByLbl[l] or 0) + q
      end
    end
    local sold = (M.chartTrades ~= false and M.RealizedSell) and (M.RealizedSell(key)) or nil
    local marks = {
      { p = m and m.quick, lbl = "QUICK-SELL", rgb = C.sub },
      { p = M.chartMA and m and m.floor7, lbl = "7-DAY FLOOR", rgb = C.blue },
      { p = paid, lbl = "YOU PAID", rgb = C.green },
      { p = sold, lbl = "YOU SOLD", rgb = C.red },
      { p = (M.chartFair ~= false) and fair, lbl = "FAIR", rgb = PU, fair = true },
    }
    -- YOUR ASK: one marker per ask-price cluster (the four biggest by units),
    -- so two batches listed at different prices no longer melt into one
    -- volume-weighted average; caches from before 1.2.6 carry no cluster
    -- data yet -> fall back to that average until the AH is opened again
    if M.chartTrades ~= false then
      local cl = {}
      for p, q in pairs(myOut) do cl[#cl + 1] = { p = p, q = q, ext = true } end
      for p, q in pairs(myIn) do cl[#cl + 1] = { p = p, q = q } end
      table.sort(cl, function(x, y) return x.q > y.q end)
      while #cl > 4 do table.remove(cl) end
      if #cl > 0 then
        -- q = units that EXTEND the supply (not in the scan); own = already
        -- inside a scanned level (drawn in that row when it is on the ladder)
        for _, e in ipairs(cl) do
          marks[#marks + 1] = { p = e.p, lbl = "YOUR ASK \195\151" .. e.q, rgb = C.mint or C.accent,
                                q = e.ext and e.q or nil, own = not e.ext }
        end
      elseif myAsk then
        marks[#marks + 1] = { p = myAsk, lbl = "YOUR ASK", rgb = C.mint or C.accent }
      end
    end
    -- one top-down sequence: levels, with each marker slotted in before the
    -- first level that costs more than it (so "total" reads straight down)
    local mks = {}
    for _, mk in ipairs(marks) do if mk.p and mk.p > 0 then mks[#mks + 1] = mk end end
    table.sort(mks, function(a, b) return a.p < b.p end)
    -- elastic geometry: level rows 18..28 px, marker rows three quarters of
    -- that. The ladder must never run out of its frame: if even the minimum
    -- sizes do not fit, the most expensive levels go (markers always stay;
    -- the card's note counts what is not shown). Minima carry the 13px body
    -- font with air - the narrow split column otherwise stacks the texts.
    local avail = LH + TOP
    local RH = math.floor(avail / (math.max(n, 10) + 0.75 * #mks))
    RH = math.max(18, math.min(28, RH))
    local MRH = math.max(14, math.floor(RH * 0.75))
    local BH = math.max(8, math.floor(RH * 0.6))
    local fit = math.floor((avail - #mks * MRH) / RH)
    if n > fit then
      n = math.max(1, fit)
      maxCum = math.max(1, gl[n].cum)
    end
    -- YOUR-ASK clusters whose price row IS on the ladder render inside that
    -- row (split bar + in-row hairline) and skip their own marker row; only
    -- clusters whose price fell off the ladder keep the classic marker line
    local visLbl = {}
    for i = 1, n do visLbl[gl[i].lbl] = true end
    local function keepMk(mk) return not (mk.own and visLbl[M.MoneyPlain(mk.p)]) end
    -- a marker whose price reads like a grouped row ("4g 75s" spans 4g75s00c
    -- ..99c) goes ABOVE that row: its total counts only the copper levels up
    -- to its own price, so below the row it would read smaller than the row
    local seq, pi = {}, 1
    for i = 1, n do
      while mks[pi] and (mks[pi].p < gl[i].price or M.MoneyPlain(mks[pi].p) == gl[i].lbl) do
        if keepMk(mks[pi]) then seq[#seq + 1] = { mk = mks[pi] } end
        pi = pi + 1
      end
      seq[#seq + 1] = { lvl = i }
    end
    while mks[pi] do
      if keepMk(mks[pi]) then seq[#seq + 1] = { mk = mks[pi] } end
      pi = pi + 1
    end
    -- off-ladder YOUR-ASK clusters EXTEND the supply, so the TOTAL column
    -- reads straight down even right after posting: their units join the
    -- running total of every row beneath them ("extra" in the loop below),
    -- and the scale grows by the full sum so each bar fits at its shifted
    -- cumulative position
    local totalExtra = 0
    for _, s2 in ipairs(seq) do
      local mk2 = s2.mk
      if mk2 and mk2.q and mk2.q > 0 then totalExtra = totalExtra + mk2.q end
    end
    if totalExtra > 0 then maxCum = math.max(maxCum, gl[n].cum + totalExtra) end

    local nBelow, wall, fairMid, belowBot = 0, gl[1], nil, nil
    local mark25, mark50, r = false, false, 0
    local costCum, aucCum = 0, 0
    local extra, extraCost = 0, 0   -- your off-ladder units/cost passed so far (joins TOTAL + hover)
    dv.ctx = { fair = fair, quick = m and m.quick, floor7 = m and m.floor7, paid = M.RealizedBuy and (M.RealizedBuy(key)) }
    local yy = TOP
    for _, s in ipairs(seq) do
      if s.lvl then
        local i = s.lvl
        local e, row = gl[i], dv.rows[i]
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, yy); row:SetPoint("TOPRIGHT", 0, yy)
        row:SetHeight(RH); row:Show()
        yy = yy - RH
        if e.qty > wall.qty then wall = e end
        local below = fair and e.price < fair
        if below then nBelow = i; belowBot = yy end
        -- this level: green = under Fair, price-line gold above; the grey ghost
        -- (everything cheaper) never shares a color with the level itself
        local rgb = below and C.green or (C.teal or C.accent)
        row.price:SetText(e.lbl)
        colorize(row.price, below and C.green or C.text)
        local own = math.min(myByLbl[e.lbl] or 0, e.qty)
        -- the quantile tags skip rows that carry the YOUR-ASK decor (line and
        -- label live in the same gap); the next plain row still reads ">= 25%"
        if own == 0 then
          if not mark25 and e.cum >= allU * 0.25 then row.mark:SetText("25%"); mark25 = true end
          if not mark50 and e.cum >= allU * 0.50 then
            row.mark:SetText(row.mark:GetText() == "25%" and "25/50" or "50%"); mark50 = true
          end
        end
        local prev = e.cum - e.qty + extra
        local gw = W * prev / maxCum
        row.ghost:ClearAllPoints(); row.ghost:SetPoint("LEFT", BX, 0); row.ghost:SetHeight(BH)
        if prev > 0 then row.ghost:SetWidth(math.max(1, gw)); row.ghost:Show() end
        -- the level's bar splits when part of it is YOURS: the others' share
        -- first, your units docked right beside it in the YOUR-ASK color
        local bw2 = math.max(3, W * e.qty / maxCum)
        local ownW = (own > 0) and math.min(bw2, math.max(2, math.floor(bw2 * own / e.qty + 0.5))) or 0
        local otherW = bw2 - ownW
        row.bar:ClearAllPoints(); row.bar:SetPoint("LEFT", BX + gw, 0); row.bar:SetHeight(BH)
        row.bar:SetColorTexture(rgb[1], rgb[2], rgb[3], below and 0.80 or 0.70)
        if otherW > 0 then row.bar:SetWidth(otherW); row.bar:Show() else row.bar:Hide() end
        local mint = C.mint or C.accent
        row.own:ClearAllPoints(); row.own:SetPoint("LEFT", BX + gw + otherW, 0); row.own:SetHeight(BH)
        row.own:SetColorTexture(mint[1], mint[2], mint[3], 0.85)
        if ownW > 0 then row.own:SetWidth(ownW); row.own:Show() else row.own:Hide() end
        row.qty:ClearAllPoints()
        row.qty:SetPoint("LEFT", (ownW > 0) and row.own or row.bar, "RIGHT", 6, 0)
        row.qty:SetText(e.qty)
        -- the YOUR-ASK hairline + count live IN this row, left of the bar:
        -- the line runs through the ghost gap up to the bar, the label sits
        -- right-aligned at its end (dropped when the gap is too narrow)
        if own > 0 then
          -- the label goes where there is room, measured against its real
          -- width: left of the bar (the hairline stops short of it), else
          -- right after the qty number (its real width counted, so the label
          -- never runs into the AUCT./TOTAL columns of the narrow split book)
          row.ownLbl:SetText("YOUR ASK \195\151" .. own)
          row.ownLbl:SetTextColor(mint[1], mint[2], mint[3])
          local strW = row.ownLbl:GetStringWidth() or 60
          local qtyW = row.qty:GetStringWidth() or 24
          row.ownLbl:ClearAllPoints()
          local lblW = 0
          if gw - 5 - strW >= 6 then
            row.ownLbl:SetPoint("RIGHT", row, "LEFT", BX + gw - 5, 0)
            row.ownLbl:Show()
            lblW = strW + 10
          elseif gw + bw2 + 6 + qtyW + 8 + strW + 24 <= W then
            row.ownLbl:SetPoint("LEFT", row.qty, "RIGHT", 8, 0)
            row.ownLbl:Show()
          end
          local lw = gw - 1 - lblW
          if lw >= 2 then
            row.ownLine:ClearAllPoints(); row.ownLine:SetPoint("LEFT", BX, 0)
            row.ownLine:SetSize(lw, 1)
            row.ownLine:SetColorTexture(mint[1], mint[2], mint[3], 0.9)
            row.ownLine:Show()
          end
        end
        costCum = costCum + e.cost; aucCum = aucCum + e.auctions
        row.info = { lbl = e.lbl, price = e.price, units = e.cum + extra, cost = costCum + extraCost, auctions = aucCum }
        row.auc:SetText("\195\151" .. e.auctions)
        row.cum:SetText(e.cum + extra)
        if fair then row.vs:SetText(string.format("%+.0f%%", (e.price / fair - 1) * 100)) end
      else
        -- marker row: slim, tinted, a hairline in its color from the start of
        -- the tree to the supply you would have bought through at its price
        local mk = s.mk
        r = r + 1
        local row, c = dv.mkRows[r], mk.rgb
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, yy); row:SetPoint("TOPRIGHT", 0, yy)
        row:SetHeight(MRH); row:Show()
        if mk.fair then fairMid = yy - MRH / 2 end
        yy = yy - MRH
        local u = 0
        for _, l in ipairs(lv) do if l.price <= mk.p then u = u + l.qty end end
        local gx = W * math.min(u + extra, maxCum) / maxCum
        row.tint:SetColorTexture(c[1], c[2], c[3], mk.fair and 0.09 or 0.05)
        row.price:SetText(M.MoneyPlain(mk.p)); row.price:SetTextColor(c[1], c[2], c[3])
        row.name:SetText(mk.lbl); row.name:SetTextColor(c[1], c[2], c[3])
        -- a YOUR-ASK cluster whose price is not on the scanned ladder (posted
        -- after the scan, or the level fell off): its units EXTEND the supply,
        -- so the bar STARTS at the cumulative position and runs right (the
        -- scale was widened above to make room)
        local mbw = 0
        if mk.q and mk.q > 0 then
          mbw = math.min(W - gx, math.max(3, W * mk.q / maxCum))
          if mbw < 0 then mbw = 0 end
        end
        if mbw > 0 then
          row.bar:ClearAllPoints()
          row.bar:SetPoint("LEFT", BX + gx, 0)
          row.bar:SetSize(mbw, math.min(BH, MRH - 2))
          row.bar:SetColorTexture(c[1], c[2], c[3], 0.75)
          row.bar:Show()
        else
          row.bar:Hide()
        end
        -- the label rides at the line tip - but a quantity BAR starts there
        -- and runs right, which printed the text ACROSS the bar: put it
        -- beside the bar instead (right of its end, or left of its start
        -- when the right side is out of room)
        row.name:ClearAllPoints()
        if mbw > 0 then
          local strW = (row.name:GetStringWidth() or 60) + 5
          if gx + mbw + strW <= W then
            row.name:SetPoint("LEFT", row, "LEFT", BX + gx + mbw + 5, 0)
          elseif gx >= strW then
            row.name:SetPoint("RIGHT", row, "LEFT", BX + gx - 5, 0)
          else
            row.name:SetPoint("RIGHT", row, "LEFT", BX + W, 0)
          end
        else
          row.name:SetPoint("LEFT", row.dot, "RIGHT", 5, 0)
        end
        row.line:ClearAllPoints(); row.line:SetPoint("LEFT", BX, 0)
        row.line:SetSize(math.max(1, gx), mk.fair and 2 or 1)
        row.line:SetColorTexture(c[1], c[2], c[3], 0.9); row.line:SetShown(gx >= 1)
        row.dot:ClearAllPoints(); row.dot:SetPoint("CENTER", row, "LEFT", BX + gx, 0)
        row.dot:SetVertexColor(c[1], c[2], c[3], 1)
        row.dot:SetShown(mbw <= 0)
        local mq = (mk.q and mk.q > 0) and mk.q or 0
        row.cum:SetText(u + extra + mq); row.cum:SetTextColor(c[1], c[2], c[3])
        row.vs:SetText(fair and not mk.fair and string.format("%+.0f%%", (mk.p / fair - 1) * 100) or "")
        local mc, ma = 0, 0
        for _, l in ipairs(lv) do if l.price <= mk.p then mc = mc + l.qty * l.price; ma = ma + l.auctions end end
        row.info = { lbl = M.MoneyPlain(mk.p), name = mk.lbl, rgb = c, price = mk.p,
                     units = u + extra + mq, cost = mc + extraCost + mq * mk.p, auctions = ma }
        if mq > 0 then extra = extra + mq; extraCost = extraCost + mq * mk.p end
      end
    end
    -- buy zone: from the top down to the Fair row (or the last level under Fair)
    if fair and nBelow > 0 then
      local zBot = fairMid or belowBot or TOP
      dv.zone:ClearAllPoints()
      dv.zone:SetPoint("TOPLEFT", 0, TOP); dv.zone:SetSize(LW, TOP - zBot); dv.zone:Show()
      dv.zoneEdge:ClearAllPoints()
      dv.zoneEdge:SetPoint("TOPLEFT", 0, TOP); dv.zoneEdge:SetHeight(TOP - zBot); dv.zoneEdge:Show()
    end
    -- verdict
    local floor = lv[1].price
    dv.floor:SetText(M.MoneyPlain(floor))
    if fair then
      local dlt = floor / fair - 1
      dv.chip:SetText(string.format("%s%.0f%% %s Fair", dlt < 0 and "\226\136\146" or "+", math.abs(dlt) * 100,
        dlt < 0 and "under" or "over"))
      colorize(dv.chip, (dlt <= -0.10) and C.green or (dlt >= 0.10) and C.sub or C.text)
    else
      dv.chip:SetText("No Fair price yet - needs a few scan days"); colorize(dv.chip, C.muted)
    end
    local belowU, belowCost, near = 0, 0, 0
    for _, l in ipairs(lv) do
      if fair and l.price < fair then belowU = belowU + l.qty; belowCost = belowCost + l.qty * l.price end
      if l.price <= floor * 1.10 then near = near + l.qty end
    end
    if fair and belowU > 0 then
      dv.say1:SetText(string.format("%d units are listed under Fair. Buying all of them costs %s, %s each on average.",
        belowU, M.MoneyPlain(belowCost), M.MoneyPlain(belowCost / belowU)))
    elseif fair then
      dv.say1:SetText("Nothing is listed under Fair right now - every seller asks at least the fair price.")
    else
      dv.say1:SetText(string.format("%d units are listed at the %d cheapest prices.", d.units, #gl))
    end
    if #gl > 1 and wall.qty >= 2 * (d.units / #gl) then
      dv.say2:SetText(string.format("Largest wall: %d units at %s.", wall.qty, wall.lbl))
    end
    local function mv(v) return (v and v > 0) and M.MoneyPlain(v) or "-" end
    local mp = { fair, m and m.quick, m and m.floor7, M.RealizedBuy and (M.RealizedBuy(key)),
                 M.RealizedSell and (M.RealizedSell(key)), myAsk, q25, q50 }
    for i = 1, #dv.mk do
      local p, cells = mp[i], dv.mk[i]
      cells[1]:SetText(mv(p))
      local u, cost = 0, 0
      if p and p > 0 then
        for _, l in ipairs(lv) do
          if l.price <= p then u = u + l.qty; cost = cost + l.qty * l.price end
        end
      end
      cells[2]:SetText((p and p > 0) and tostring(u) or "")
      cells[3]:SetText(u > 0 and M.MoneyPlain(cost) or ((p and p > 0) and "-" or ""))
    end
    dv.kpi[1]:SetText(d.listed or d.units)
    dv.kpi[2]:SetText(myQty > 0 and (myQty .. " units") or "-")
    dv.kpi[3]:SetText(near .. " units")
    local shown = 0
    for i = 1, n do shown = shown + gl[i].auctions end
    local more = ((d.auctions or 0) > shown)
      and string.format("%d more auctions above %s not shown. ", d.auctions - shown, gl[n].lbl) or ""
    dv.note:SetText(more ~= "" and more or "Buyout prices, no seller names.")
  end

  function M.ShowDepth(key)
    wy:Hide()
    dv.key = key
    if layoutDepth then layoutDepth() end
    depthSeg.frame:Hide()
    dv:Show()
    M.FillDepth()
    -- redraw the chart at its new width right away -- the drawn line keeps
    -- its old span otherwise and pokes under the book until the next resize
    if M.chartKey and M.RenderItemChart and M.canvas then M.RenderItemChart(M.canvas, M.chartKey) end
  end

  local canvas = CreateFrame("Frame", nil, panel)
  canvas:SetPoint("TOPLEFT", 206, -106); canvas:SetPoint("BOTTOMRIGHT", 0, 0)
  M.canvas = canvas

  -- timeframe switch, top-right corner of the plot (under the value labels)
  local rangeSeg = makeRangeSeg(panel)
  rangeSeg.frame:SetPoint("TOPRIGHT", -64, -108)
  rangeSeg.frame:SetFrameLevel(panel:GetFrameLevel() + 10)

  -- one function owns the chart/offer-book geometry. Split view puts the
  -- chart on the LEFT half and a REDUCED book (the ladder alone, no verdict
  -- card) on the RIGHT half; 103 is half the 206px list column, so panel
  -- TOP/BOTTOM +103 marks the middle of the detail area. Both halves stay
  -- elastic -- the ladder already drops its priciest rows when it runs short.
  layoutDepth = function()
    local split = M.db and M.db.config and M.db.config.depthSplit
    canvas:ClearAllPoints()
    canvas:SetPoint("TOPLEFT", 206, -106)
    dv:ClearAllPoints()
    rangeSeg.frame:ClearAllPoints()
    if split then
      canvas:SetPoint("BOTTOMRIGHT", panel, "BOTTOM", 89, 0)          -- 103 - 14 gap
      dv:SetPoint("TOPLEFT", panel, "TOP", 117, -106)                 -- 103 + 14 gap
      dv:SetPoint("BOTTOMRIGHT", 0, 0)
      rangeSeg.frame:SetPoint("TOPRIGHT", panel, "TOP", 25, -108)     -- stays over the plot
    else
      canvas:SetPoint("BOTTOMRIGHT", 0, 0)
      dv:SetPoint("TOPLEFT", 0, 0)
      dv:SetPoint("BOTTOMRIGHT", 0, 0)
      rangeSeg.frame:SetPoint("TOPRIGHT", -64, -108)
    end
    -- the reduced book: the chart header above already names the item, the
    -- verdict card (with the hover read-out) folds away and the ladder
    -- takes the whole column under a short header
    dv.icon:SetShown(not split)
    dv.title:SetShown(not split)
    dv.titleBtn:SetShown(not split)
    dv.sub:SetShown(not split)
    card:SetShown(not split)
    dv.headSupply:SetText(split and "SUPPLY" or "SUPPLY   grey = cheaper, bar = at this price")
    lad:SetPoint("TOPLEFT", 0, split and -28 or -56)
    if split then lad:SetPoint("BOTTOMRIGHT", dv, "BOTTOMRIGHT", 0, 0)
    else lad:SetPoint("BOTTOMRIGHT", card, "BOTTOMLEFT", -GAP, 0) end
    card:SetPoint("TOPRIGHT", -2, split and -28 or -56)
    dvSplit.text:SetText(split and "full view" or "split view")
  end
  -- leaving the book (back, why-view, tab switch) restores the full chart
  dv:SetScript("OnHide", function()
    canvas:ClearAllPoints()
    canvas:SetPoint("TOPLEFT", 206, -106); canvas:SetPoint("BOTTOMRIGHT", 0, 0)
    rangeSeg.frame:ClearAllPoints()
    rangeSeg.frame:SetPoint("TOPRIGHT", -64, -108)
    depthSeg.frame:Show()
    if panel:IsShown() and M.chartKey and M.RenderItemChart then M.RenderItemChart(canvas, M.chartKey) end
  end)
  -- re-fill on real size changes (split toggle, window resize) so the row
  -- count always matches the ladder height
  dv:SetScript("OnSizeChanged", function()
    if dv:IsShown() then M.FillDepth() end
  end)
end

-- ===== Ledger tab: every gold and item flow as one Sankey ====================
-- Ledger.lua records the flows and builds the model, Sankey.lua draws it. The
-- diagram fills the left, the flows table the right; clicking a band, a node
-- or a row lists that flow's items (or its breakdown) in the table.
local LG_TABLE_W, LG_ROWH = 300, 18

local function ledgerQuery()
  local cfg = (M.db and M.db.config) or {}
  local days = M.ChartRangeDays and M.ChartRangeDays()
  local today = M.GetScanDay()
  return { realm = M.RealmKey(), char = cfg.ledgerChar,
           fromDay = days and (today - days + 1) or nil, toDay = today }
end

-- the side total a row's share is measured against
local SHARE_BASE = { gin = "goldIn", sale = "goldIn", gout = "goldOut", buy = "goldOut",
                     iin = "goodsIn", iout = "goodsOut" }

local function ledgerTitle(hit)
  if hit.node then return hit.node.label or "?" end
  local l = hit.link
  -- the title lands in GameTooltip, whose game font has no arrow glyphs: use a guillemet
  return (l and l.label) or (((hit.from and hit.from.label) or "?") .. "  \194\187  " .. ((hit.to and hit.to.label) or "?"))
end

function M.BuildLedger(panel)
  local lg = { rows = {}, popBtns = {}, panel = panel }
  M.ledgerUI = lg

  -- character filter: a button with a small pick list (account-wide by default)
  local charBtn = T.Button(panel, "All characters", 180, 22)
  charBtn:SetPoint("TOPLEFT", 0, -2)
  lg.charBtn = charBtn
  local pop = T.Surface(panel, "bg1", "borderlt")
  pop:SetFrameStrata("DIALOG")
  pop:SetPoint("TOPLEFT", charBtn, "BOTTOMLEFT", 0, -2)
  pop:SetSize(180, 24)
  pop:Hide()
  lg.pop = pop
  local function pick(ck)
    if M.db and M.db.config then M.db.config.ledgerChar = ck end
    pop:Hide()
    lg.focus = nil
    M.RefreshLedger()
  end
  charBtn:SetScript("OnClick", function()
    if pop:IsShown() then pop:Hide(); return end
    local list = { { key = nil, name = "All characters" } }
    for _, c in ipairs((M.LedgerChars and M.LedgerChars(M.RealmKey())) or {}) do list[#list + 1] = c end
    local cur = M.db and M.db.config and M.db.config.ledgerChar
    for i, e in ipairs(list) do
      local b = lg.popBtns[i]
      if not b then
        b = CreateFrame("Button", nil, pop)
        b:SetSize(176, 18); b:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 18)
        local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.06)
        b.fs = cell(b, 6, -3, 166, "LEFT", T.SIZE.body)
        lg.popBtns[i] = b
      end
      b.fs:SetText(e.name)
      colorize(b.fs, (cur == e.key) and C.accent or C.text)
      b:SetScript("OnClick", function() pick(e.key) end)
      b:Show()
    end
    for i = #list + 1, #lg.popBtns do lg.popBtns[i]:Hide() end
    pop:SetHeight(#list * 18 + 4)
    pop:Show()
  end)

  -- recording switch right where the numbers are (the same setting as
  -- Settings > "Record ledger"); off stops new bookings, the history stays
  local recCb = T.Checkbox(panel, "Record ledger", function(on)
    if M.db and M.db.config then M.db.config.ledgerOff = (not on) and true or nil end
    M.RefreshLedger()
  end)
  recCb:SetPoint("LEFT", charBtn, "RIGHT", 16, 0)
  lg.recCb = recCb
  if T.HelpTip then
    T.HelpTip(recCb, "Record ledger (beta)", {
      "On: every gold and item flow is booked for this tab. Off: nothing new is booked; what is already recorded stays.",
      "The same switch sits in Settings." })
  end
  local beta = T.Surface(panel, "bg0", "accent")
  beta:SetSize(44, 18)
  beta:SetPoint("LEFT", recCb, "RIGHT", 16, 0)
  local betaTx = T.Text(beta, T.SIZE.tiny, "accent", T.FONT_SEMI)
  betaTx:SetPoint("CENTER", 0, 0); betaTx:SetText("BETA")
  local betaNote = T.Text(panel, T.SIZE.small, "muted")
  betaNote:SetPoint("LEFT", beta, "RIGHT", 8, 0)
  betaNote:SetText("bookings are still being tuned \226\128\148 feedback welcome on the Discord")

  local rangeSeg = makeRangeSeg(panel)
  rangeSeg.frame:SetPoint("TOPRIGHT", 0, -1)

  -- summary strip
  local function stat(x, w, label, tip)
    local lbl = T.Text(panel, T.SIZE.tiny, "muted", T.FONT_MED)
    lbl:SetPoint("TOPLEFT", x, -34); lbl:SetWidth(w); lbl:SetText(label)
    local val = T.Text(panel, T.SIZE.h2 + 2, "text", T.FONT_SEMI)
    val:SetPoint("TOPLEFT", x, -47); val:SetWidth(w)
    if tip and T.HelpTip then
      local hb = CreateFrame("Button", nil, panel)
      hb:SetPoint("TOPLEFT", x, -34); hb:SetSize(w, 32)
      T.HelpTip(hb, label, tip)
    end
    return val
  end
  lg.sIn = stat(0, 120, "GOLD IN",
    { "Every copper that reached your bags in the timeframe: loot, quests, sales, mail and trades.",
      "Gold counts the moment it lands in your bags - a sale still waiting in the mailbox is not in yet." })
  lg.sOut = stat(128, 120, "GOLD OUT",
    { "Every copper that left: repairs, flights, training, AH deposits and cuts, postage, purchases." })
  lg.sNet = stat(256, 120, "NET GOLD", { "Gold in minus gold out - the change of the gold you carry." })
  lg.sGin = stat(384, 120, "GOODS IN",
    { "Items that joined your stock (looted, gathered, crafted, quest rewards, bought), valued at Fair when they arrived." })
  lg.sGout = stat(512, 120, "GOODS OUT",
    { "Items that left your stock (sold, consumed, used in crafting, destroyed, given away). Sales count at the gold they brought in." })
  lg.sUna = stat(640, 110, "UNMATCHED",
    { "Share of gold moves Midas could not tie to a cause (booked as Other income / Other spending).",
      "Low single digits are normal - quest NPCs and addons that bypass the usual calls leave a little behind." })
  lg.sSince = stat(760, 180, "RECORDING SINCE",
    { "The ledger starts with this version - loot, quests and repairs before it were never recorded anywhere." })

  -- the diagram
  local canvas = CreateFrame("Frame", nil, panel)
  canvas:SetPoint("TOPLEFT", 0, -80)
  canvas:SetPoint("BOTTOMRIGHT", -(LG_TABLE_W + 18), 0)
  lg.canvas = canvas

  -- the flows table
  local tbl = CreateFrame("Frame", nil, panel)
  tbl:SetPoint("TOPRIGHT", 0, -80); tbl:SetPoint("BOTTOMRIGHT", 0, 0); tbl:SetWidth(LG_TABLE_W)
  lg.tbl = tbl
  local sep = tbl:CreateTexture(nil, "ARTWORK")
  sep:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.6)
  sep:SetPoint("TOPLEFT", -9, 0); sep:SetPoint("BOTTOMLEFT", -9, 0); sep:SetWidth(1)
  lg.tHead = cell(tbl, 0, -2, 296, "LEFT", T.SIZE.small, "text", T.FONT_SEMI)
  local back = CreateFrame("Button", nil, tbl)
  back:SetAllPoints(lg.tHead)
  back:SetScript("OnClick", function() if lg.focus then lg.focus = nil; M.RefreshLedger() end end)
  lg.h1 = cell(tbl, 0, -22, 160, "LEFT", T.SIZE.tiny, "muted", T.FONT_MED)
  lg.h2 = cell(tbl, 164, -22, 84, "RIGHT", T.SIZE.tiny, "muted", T.FONT_MED)
  lg.h3 = cell(tbl, 252, -22, 44, "RIGHT", T.SIZE.tiny, "muted", T.FONT_MED)
  local scroll = CreateFrame("ScrollFrame", "MidasLedgerScroll", tbl, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, -38); scroll:SetPoint("BOTTOMRIGHT", -2, 0)
  local function wheel(_, delta)
    local sb = _G["MidasLedgerScrollScrollBar"]
    if sb then sb:SetValue(sb:GetValue() - delta * LG_ROWH * 2) end
  end
  scroll:EnableMouseWheel(true); scroll:SetScript("OnMouseWheel", wheel)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, LG_ROWH, lg.FillTable)
  end)
  T.StyleScrollbar("MidasLedgerScroll")
  lg.scroll = scroll

  local function mkRow(r)
    local btn = CreateFrame("Button", nil, tbl)
    btn:SetSize(282, LG_ROWH); btn:SetPoint("TOPLEFT", 0, -38 - (r - 1) * LG_ROWH)
    local zb = btn:CreateTexture(nil, "BACKGROUND"); zb:SetAllPoints(); zb:SetColorTexture(1, 1, 1, 0.02); zb:Hide(); btn.zb = zb
    local hl = btn:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.05)
    btn.c1 = cell(btn, 2, -3, 158, "LEFT", T.SIZE.body)
    btn.c2 = cell(btn, 164, -3, 84, "RIGHT", T.SIZE.body, "text", T.FONT_MED)
    btn.c3 = cell(btn, 238, -3, 44, "RIGHT", T.SIZE.small, "muted")
    btn:EnableMouseWheel(true); btn:SetScript("OnMouseWheel", wheel)
    btn:SetScript("OnEnter", function() if btn.itemKey then ShowItemTip(btn.itemKey) end end)
    btn:SetScript("OnLeave", HideTip)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, mouse)
      local d = btn.data
      if not d then return end
      if d.itemKey then
        if ItemMenuClick(mouse, d.itemKey) then return end
        if M.ModPostDown() then M.PostItemStats(d.itemKey); return end
        if M.ModSearchDown() then M.ItemShiftAction(d.itemKey); return end
        GoChart(d.itemKey)
      elseif mouse == "RightButton" then
        return
      elseif d.focus then
        lg.focus = d.focus; M.RefreshLedger()
      end
    end)
    lg.rows[r] = btn
  end

  function lg.FillTable()
    local data = lg.tableData or {}
    local vis = math.max(4, math.floor(((tbl:GetHeight() or 0) > 60 and (tbl:GetHeight() - 40) or 300) / LG_ROWH))
    for r = #lg.rows + 1, vis do mkRow(r) end
    FauxScrollFrame_Update(scroll, #data, vis, LG_ROWH)
    local off = math.min(FauxScrollFrame_GetOffset(scroll), math.max(0, #data - vis))
    for r = 1, #lg.rows do
      local btn = lg.rows[r]
      local d = (r <= vis) and data[r + off] or nil
      btn.data, btn.itemKey = d, d and d.itemKey or nil
      if d then
        btn.zb:SetShown((r % 2) == 0)
        btn.c1:SetText(d.label)
        if d.qc then btn.c1:SetTextColor(d.qc.r, d.qc.g, d.qc.b) else colorize(btn.c1, d.rgb or C.text) end
        btn.c2:SetText(d.amount or "")
        btn.c3:SetText(d.extra or "")
        btn:Show()
      else
        btn:Hide()
      end
    end
  end

  -- band / node hover: amount, breakdown, top items
  local function hitTip(hit)
    if not hit then GameTooltip:Hide(); return end
    local ref = hit.node or hit.link or {}
    GameTooltip:SetOwner(canvas, "ANCHOR_CURSOR")
    GameTooltip:SetText(ledgerTitle(hit), 1, 1, 1)
    GameTooltip:AddDoubleLine("Amount", M.MoneyPlain(hit.value or 0), 0.65, 0.65, 0.65, 1, 1, 1)
    for _, s in ipairs(ref.sub or {}) do
      GameTooltip:AddDoubleLine("   " .. (s.label or "?"), M.MoneyPlain(s.value or 0), 0.65, 0.65, 0.65, 0.85, 0.85, 0.85)
    end
    local items = ref.items
    if items and #items > 0 then
      GameTooltip:AddLine(" ")
      for i = 1, math.min(5, #items) do
        local it = items[i]
        local nm = (it.id and M.ItemName(tostring(it.id))) or "?"
        GameTooltip:AddDoubleLine(nm .. "  \195\151" .. (it.qty or 0), M.MoneyPlain(it.value or 0), 0.85, 0.85, 0.85, 0.85, 0.85, 0.85)
      end
    end
    if ref.note then GameTooltip:AddLine(ref.note, 0.55, 0.55, 0.55, true) end
    if (items and #items > 0) or ref.sub then GameTooltip:AddLine("click: list it in the table", 0.45, 0.45, 0.45) end
    GameTooltip:Show()
  end
  lg.onHover = hitTip
  lg.onClick = function(hit)
    if not hit then return end
    local ref = hit.node or hit.link or {}
    if (ref.items and #ref.items > 0) or ref.sub then
      lg.focus = { label = ledgerTitle(hit), items = ref.items, sub = ref.sub }
      M.RefreshLedger()
    end
  end
end

function M.RefreshLedger()
  local lg = M.ledgerUI
  if not (lg and lg.panel and lg.panel:IsShown()) then return end
  local cfg = (M.db and M.db.config) or {}
  local ck = cfg.ledgerChar
  lg.charBtn.text:SetText(ck and (ck:match("^(.-)%-") or ck) or "All characters")
  if lg.recCb then lg.recCb:SetChecked(cfg.ledgerOff ~= true) end
  -- the canvas has no size before the first layout pass: draw one frame later
  if (lg.canvas:GetWidth() or 0) < 50 and not lg.waited then
    lg.waited = true
    C_Timer.After(0, M.RefreshLedger)
    return
  end
  lg.waited = nil

  local model = M.LedgerModel and M.LedgerModel(ledgerQuery()) or nil
  local sum = (model and model.summary) or {}
  local function money(fs, v, rgb)
    fs:SetText(M.MoneyPlain(math.abs(v or 0))); colorize(fs, rgb)
  end
  money(lg.sIn, sum.goldIn, C.green)
  money(lg.sOut, sum.goldOut, C.red)
  local net = sum.goldNet or 0
  lg.sNet:SetText((net >= 0 and "+" or "-") .. M.MoneyPlain(math.abs(net)))
  colorize(lg.sNet, (net >= 0) and C.green or C.red)
  money(lg.sGin, sum.goodsIn, C.mint or C.text)
  money(lg.sGout, sum.goodsOut, C.sub)
  local share = sum.unattributedShare
  lg.sUna:SetText(share and string.format("%.0f%%", share * 100) or "\226\128\147")
  colorize(lg.sUna, (share and share > 0.10) and C.red or C.sub)
  lg.sSince:SetText(sum.since and date("%b %d, %Y", sum.since) or "\226\128\147")
  colorize(lg.sSince, C.sub)

  local empty = (cfg.ledgerOff == true)
    and "Recording is off  \194\183  tick \"Record ledger\" above to start booking"
    or "Nothing recorded in this timeframe yet \226\128\148 every gold and item flow is booked from now on."
  if M.RenderSankey then
    M.RenderSankey(lg.canvas, model or { nodes = {}, links = {} },
      { onHover = lg.onHover, onClick = lg.onClick, emptyText = empty })
  end

  -- table: all flows, or the items / breakdown of the clicked one
  local data = {}
  if lg.focus then
    lg.tHead:SetText("\226\128\185  all flows   \194\183   " .. (lg.focus.label or ""))
    colorize(lg.tHead, C.accent)
    lg.h1:SetText("ITEM"); lg.h2:SetText("VALUE"); lg.h3:SetText("QTY")
    for _, it in ipairs(lg.focus.items or {}) do
      local key = it.id and tostring(it.id)
      data[#data + 1] = { label = (key and M.ItemName(key)) or "?", itemKey = key,
                          qc = key and M.ItemQualityColor(key) or nil,
                          amount = M.MoneyPlain(it.value or 0), extra = tostring(it.qty or "") }
    end
    for _, s in ipairs(lg.focus.sub or {}) do
      data[#data + 1] = { label = s.label or "?", rgb = C.sub, amount = M.MoneyPlain(s.value or 0) }
    end
  else
    lg.tHead:SetText("FLOWS")
    colorize(lg.tHead, C.text)
    lg.h1:SetText("FLOW"); lg.h2:SetText("AMOUNT"); lg.h3:SetText("SHARE")
    for _, r in ipairs((model and model.rows) or {}) do
      local cat = M.LEDGER_CATS and M.LEDGER_CATS[r.key]
      local base = SHARE_BASE[r.side] and sum[SHARE_BASE[r.side]]
      data[#data + 1] = {
        label = r.label or r.key, rgb = (cat and C[cat.color]) or C.text,
        amount = M.MoneyPlain(r.value or 0),
        extra = (base and base > 0) and string.format("%.0f%%", (r.value or 0) / base * 100) or "",
        focus = ((r.items and #r.items > 0) and { label = r.label, items = r.items }) or nil,
      }
    end
  end
  lg.tableData = data
  -- back to the top only when WHAT is listed changed, not on every data refresh
  local viewKey = tostring(ck) .. "|" .. tostring(cfg.chartRange) .. "|" .. tostring(lg.focus and lg.focus.label)
  if lg.viewKey ~= viewKey then
    lg.viewKey = viewKey
    FauxScrollFrame_SetOffset(lg.scroll, 0)
  end
  lg.FillTable()
end

-- ===== Tab 8: Help -- how the numbers are made, for humans ==================
-- Layout is CHAINED: section 2 and 3 anchor to the measured bottom of what
-- sits above them (text or example chart, whichever is taller) -- fixed pixel
-- slots cropped the paragraphs on the first attempt.
function M.BuildHelp(panel)
  local h = {}
  M.helpUI = h
  -- scrollable: at the 980x560 minimum, section 3 used to fall below the panel
  local scroll = CreateFrame("ScrollFrame", "MidasHelpScroll", panel, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, 0); scroll:SetPoint("BOTTOMRIGHT", -24, 0)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(880, 800)   -- room for section 4 (Discord) under the glossary
  scroll:SetScrollChild(content)
  T.StyleScrollbar("MidasHelpScroll")

  local title = T.Text(content, T.SIZE.h1, "text", T.FONT_SEMI)
  title:SetPoint("TOPLEFT", 0, -2); title:SetText("How Midas prices things")

  local gsb = T.Button(content, "Get started tour", 140, 22)
  gsb:SetPoint("TOPLEFT", 420, 0)
  gsb:SetScript("OnClick", function() if M.ShowGuide then M.ShowGuide() end end)

  -- community: questions, bugs and ideas go to the Discord (copy box, WoW has no browser)
  local dcb = T.Button(content, "Join the Discord", 130, 22)
  dcb:SetPoint("LEFT", gsb, "RIGHT", 8, 0)
  dcb:SetScript("OnClick", function() M.ShowLinkCopy(M.DISCORD_URL, "Midas Discord") end)

  local function head(txt)
    local fs = T.Text(content, T.SIZE.h2 + 1, "accent", T.FONT_SEMI)
    fs:SetText(txt)
    return fs
  end
  local function para(anchor, txt)
    local fs = T.Text(content, T.SIZE.small, "sub")
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 2, -8)
    fs:SetWidth(500); fs:SetJustifyH("LEFT"); fs:SetSpacing(4)
    fs:SetWordWrap(true)   -- T.Text defaults to false (table cells ellipsize)
    fs:SetText(txt)
    return fs
  end

  h.head1 = head("1.  Fair \226\128\148 the price it actually clears at")
  h.head1:SetPoint("TOPLEFT", 0, -30)
  h.para1 = para(h.head1, "Every scan keeps each day's CHEAPEST price. Example:  10g \194\183 11g \194\183 9g \194\183 |cff70A3EB30g|r \194\183 10g \194\183 12g \194\183 11g.  The 30g day is trimmed \226\128\148 only overpriced stock was listed, nobody bought. Recent days weigh more (14-day window); the trimmed average is the BASE, here |cffE8E8E8~10g 60s|r. Your own sold-vs-expired record then lifts Fair toward what buyers really pay \226\128\148 at most +10%, never above your real sale prices: Fair |cffE8E8E8~11g|r.")
  h.fairCanvas = CreateFrame("Frame", nil, content)
  h.fairCanvas:SetPoint("TOPLEFT", h.para1, "TOPRIGHT", 22, 4)
  h.fairCanvas:SetSize(330, 128)
  h.cap1 = T.Text(content, T.SIZE.tiny, "muted", T.FONT_MED)
  h.cap1:SetPoint("TOP", h.fairCanvas, "BOTTOM", 0, -3)
  h.cap1:SetText("EXAMPLE \194\183 daily lows, one trimmed spike, base and Fair")

  h.head2 = head("2.  Sell odds \226\128\148 will ONE auction sell?")
  h.head2:SetPoint("TOPLEFT", 0, -190)   -- re-anchored dynamically in RefreshHelp
  h.para2 = para(h.head2, "Every auction ends SOLD or EXPIRED; Midas logs both, with how far above the market floor you asked. Hundreds of outcomes draw the curve on the right \226\128\148 its x-axis is YOUR ASKING PRICE, not time. For an item whose floor is 10g: ask right at 10g and it nearly always sells; ask 13g (+30%) and only about 1 in 6 sells. \226\128\158~11% odds at this price\226\128\156 simply reads that curve at today's price; Fair (11g here) aims for the ~50% point.")
  h.oddsCanvas = CreateFrame("Frame", nil, content)
  h.oddsCanvas:SetPoint("TOPLEFT", h.para2, "TOPRIGHT", 22, 4)
  h.oddsCanvas:SetSize(330, 128)
  h.cap2 = T.Text(content, T.SIZE.tiny, "muted", T.FONT_MED)
  h.cap2:SetPoint("TOP", h.oddsCanvas, "BOTTOM", 0, -3)
  h.cap2:SetText("EXAMPLE \194\183 x-axis = your ASKING price (not time) \194\183 floor 10g")

  h.head3 = head("3.  The rest, in one line each")
  h.head3:SetPoint("TOPLEFT", 0, -352)   -- re-anchored dynamically in RefreshHelp
  local GL = {
    { "Current", "the cheapest buyout in the newest scan." },
    { "Floor MA", "20-day average of the daily cheapest prices (blue line)." },
    { "Quick-sell", "at/just under the floor \226\128\148 near-certain, less margin." },
    { "Sells ~N/day", "your realized sales per day + the liquidity class." },
    { "Sell-through", "sold / (sold + returned) of your auctions." },
    { "Avg buy / sell", "your real average unit prices, from AH mail." },
    { "Net", "sale proceeds after the AH cut, minus your buys." },
    { "Fair \194\183 oversupplied", "even the trimmed market level misses the target sell chance \226\128\148 post fewer, not cheaper." },
    { "Score", "margin x liquidity x confidence \226\128\148 the opportunity ranking on the Start page." },
    { "vs Fair", "current price vs Fair; the BUY/SELL signal fires at +/-15%." },
    { "Ledger (beta)", "every gold + item flow since install; gold counts when it lands in your bags (Trades dates sales by their mail)." },
    { "Gold timer", "right-click the minimap coin: gold + loot value from that moment on, per hour; hover it for the sources." },
    { "Crafting (beta)", "what a recipe item costs from its materials, now (gold) and at Fair (purple), buy or make per level; also disenchant value." },
    { "Item pages", "right-click any item: chart, tree, offer book, trades, stock." },
    { "Back", "the header pill returns from a jump to another tab." },
  }
  for i, e in ipairs(GL) do
    local col = (i - 1) % 2
    local row = math.floor((i - 1) / 2)
    local y = -8 - row * 16
    local lbl = T.Text(content, T.SIZE.small, "text", T.FONT_MED)
    lbl:SetPoint("TOPLEFT", h.head3, "BOTTOMLEFT", 2 + col * 440, y)
    lbl:SetText(e[1])
    local txt = T.Text(content, T.SIZE.small, "muted")
    txt:SetPoint("TOPLEFT", h.head3, "BOTTOMLEFT", 100 + col * 440, y)
    txt:SetWidth(330); txt:SetJustifyH("LEFT")
    txt:SetText(e[2])
  end

  h.head4 = head("4.  Questions, bugs, ideas")
  h.head4:SetPoint("TOPLEFT", h.head3, "BOTTOMLEFT", 0, -8 - math.ceil(#GL / 2) * 16 - 18)
  h.para4 = para(h.head4, "Ask in #help, report bugs in #bug-reports (your Midas version and the "
    .. "error text from \"/console scriptErrors 1\" help a lot) and suggest features - all on "
    .. "the Midas Discord. Click the link to copy it, or type \"/midas discord\".")
  h.link4 = T.Text(content, T.SIZE.body, "accent", T.FONT_MED)
  h.link4:SetPoint("TOPLEFT", h.para4, "BOTTOMLEFT", 0, -8)
  h.link4:SetText(M.DISCORD_URL)
  local lb = CreateFrame("Button", nil, content)
  lb:SetAllPoints(h.link4)
  lb:SetScript("OnClick", function() M.ShowLinkCopy(M.DISCORD_URL, "Midas Discord") end)
  lb:SetScript("OnEnter", function() h.link4:SetTextColor(C.text[1], C.text[2], C.text[3]) end)
  lb:SetScript("OnLeave", function() h.link4:SetTextColor(C.accent[1], C.accent[2], C.accent[3]) end)
  h.panel = content
end

function M.RefreshHelp()
  local h = M.helpUI
  if not h then return end
  -- one frame later the font strings know their real heights: chain the
  -- sections under whichever is taller, text or example chart
  C_Timer.After(0, function()
    if not (h.panel and h.panel:IsShown()) then return end
    local top = h.panel:GetTop()
    if not top then return end
    local function bottomOf(...)
      local b
      for _, fs in ipairs({ ... }) do
        local v = fs and fs:GetBottom()
        if v and (not b or v < b) then b = v end
      end
      return b
    end
    local b1 = bottomOf(h.para1, h.cap1)
    if b1 then h.head2:ClearAllPoints(); h.head2:SetPoint("TOPLEFT", 0, -(top - b1) - 16) end
    local b2 = bottomOf(h.para2, h.cap2)
    if b2 then h.head3:ClearAllPoints(); h.head3:SetPoint("TOPLEFT", 0, -(top - b2) - 16) end
    if M.RenderHelpFair and h.fairCanvas then M.RenderHelpFair(h.fairCanvas) end
    if M.RenderHelpOdds and h.oddsCanvas then M.RenderHelpOdds(h.oddsCanvas) end
  end)
end

-- left-hand item list: renders M._chartListData at M.chartListOff (the mouse
-- wheel scrolls entries the visible rows cannot hold)
function M.FillChartList()
  local data = M._chartListData or {}
  local vis = availRows(M.panels and M.panels[TAB.Charts], 58, 24, 10)
  if M._mkChartBtn then for r = #M.chartBtns + 1, vis do M._mkChartBtn(r) end end
  local maxOff = math.max(0, #data - vis)
  local off = math.min(M.chartListOff or 0, maxOff)
  M.chartListOff = off
  for r = 1, #M.chartBtns do
    local b = M.chartBtns[r]; local e = (r <= vis) and data[r + off] or nil
    if e then
      b.key = e.key
      local qc = M.ItemQualityColor(e.key)
      b.fs:SetText(e.nm or M.ItemName(e.key)); b.fs:SetTextColor(qc.r, qc.g, qc.b)
      b:Show()
    else
      b.key = nil; b:Hide()
    end
  end
  if not M.chartKey and data[1] then M.chartKey = data[1].key end
  for r = 1, #M.chartBtns do
    local b = M.chartBtns[r]
    if b.sel then b.sel:SetShown(b.key ~= nil and b.key == M.chartKey) end
  end
end

function M.RefreshCharts()
  local q = M.chartSearch or ""
  local data = {}
  local function setLabel(s) if M.chartListLabel then M.chartListLabel:SetText(s) end end
  if #q >= 2 then
    setLabel("SEARCH RESULTS")
    -- a bare item id jumps straight to that item
    local idHit = q:match("^%d+$") and M.IterItems()[q] and q or nil
    if idHit then data[#data + 1] = { key = idHit, nm = M.ItemName(idHit) } end
    local n = #data
    for key in pairs(M.IterItems()) do
      if key ~= idHit then
        local nm = M.ItemName(key)
        if nm and nm:lower():find(q, 1, true) then
          data[#data + 1] = { key = key, nm = nm }
          n = n + 1; if n >= 60 then break end
        end
      end
    end
    table.sort(data, function(a, b) return a.nm:lower() < b.nm:lower() end)
  else
    setLabel("RECENTLY VIEWED")
    local r = (M.db and M.db.config and M.db.config.recentCharts) or {}
    for _, key in ipairs(r) do data[#data + 1] = { key = key, nm = M.ItemName(key) } end
    if #data == 0 then                            -- nothing viewed yet -> seed with top picks
      setLabel("TOP PICKS")
      for _, e in ipairs(M.RankAll()) do data[#data + 1] = { key = e.key }; if #data >= 10 then break end end
    end
  end
  -- taller window -> more entries; the wheel scrolls the rest (FillChartList)
  M._chartListData = data
  M.FillChartList()
  -- inline color codes from the theme palette
  local function hx(c) return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255) end
  local MUT, GRN, RED, SUBC = hx(C.muted), hx(C.green), hx(C.red), hx(C.sub)
  if M.chartKey then
    local key = M.chartKey
    local m = M.Metrics(M.GetSeries(key) or {}, key)
    M.chartTitle:SetText(M.ItemName(key))
    local qc = M.ItemQualityColor(key)
    M.chartTitle:SetTextColor(qc.r, qc.g, qc.b)
    local icon = M.GetItemIcon and M.GetItemIcon((M.BaseID and M.BaseID(key)) or key)
    M.chartTitleIcon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    M.chartTitleIcon:Show()
    -- name, then the link chips right behind it: the name keeps its full
    -- width unless name + chips overflow the row (then it ellipsizes)
    local cpanel = M.panels[TAB.Charts]
    local avail = ((cpanel and cpanel:GetWidth()) or 0) - 234 - 12
    if avail < 300 then avail = 952 - 234 - 12 end
    M.chartTitle:ClearAllPoints()
    M.chartTitle:SetPoint("TOPLEFT", 234, -8)
    M.chartTitle:SetWidth(0)
    local nameW = math.floor((M.chartTitle:GetStringWidth() or 120) + 0.5)
    local chipsW = 0
    if M.chartLinks then
      chipsW = M.chartLinks:SetItem(key, math.max(140, avail - math.min(nameW, 240) - 16))
    end
    local titleW = math.max(80, math.min(nameW, avail - ((chipsW > 0) and (chipsW + 16) or 0)))
    M.chartTitle:SetWidth(titleW)
    if M.chartLinks then
      M.chartLinks:ClearAllPoints()
      M.chartLinks:SetPoint("TOPLEFT", cpanel, "TOPLEFT", 234 + titleW + 16, -6)
    end
    if M.chartTitleBtn then
      M.chartTitleBtn:SetWidth(34 + titleW)
      M.chartTitleBtn:Show()
    end
    M.chartMeta:SetText(m and string.format("%s  \194\183  avg qty %d  \194\183  %d days",
      M.ItemCategory(key) or "", math.floor(m.avgQty + 0.5), m.days) or (M.ItemCategory(key) or ""))
    -- 1) the SIGNAL: what to do, how far from Fair, how likely it sells
    if m then
      local word, col
      local gone = M.NotListed and M.NotListed(m)
      if gone then word, col = "NOT LISTED", MUT
      elseif m.delta <= -M.C.PICK_DELTA then word, col = "BUY", GRN
      elseif m.delta >= M.C.PICK_DELTA then word, col = "SELL", RED
      else word, col = "NEUTRAL", SUBC end
      local sig = col .. word .. string.format("  %+.0f%%|r " .. MUT .. "vs Fair|r", m.delta * 100)
      if gone then
        sig = col .. word .. "|r" .. MUT .. "   in the newest scan  \194\183  last seen " .. M.DayLabel(M.SeenDay(m)) .. "|r"
      elseif m.odds then
        sig = sig .. MUT .. string.format("    \194\183    ~%.0f%% odds at this price", m.odds * 100) .. "|r"
      end
      M.chartSignal:SetText(sig)
      -- 2) the market in one calm line (labels muted, values plain)
      local fairTxt = M.MoneyPlain(m.fair)
      if m.oddsAtFair then fairTxt = fairTxt .. MUT .. string.format(" ~%.0f%%|r", m.oddsAtFair * 100) end
      if m.fairCapped then fairTxt = fairTxt .. MUT .. " oversupplied|r" end
      local sellsTxt = m.speed and string.format("~%.1f/day \194\183 %s", m.speed, m.liqLabel or "?") or (m.liqLabel or "?")
      local pre = MUT .. (gone and "Last seen|r  " or "Current|r  ") .. M.MoneyPlain(m.cur) ..
        MUT .. "      Fair|r  " .. fairTxt .. "      "
      -- what it costs to make, next to what it costs to buy (Crafting tab)
      local craftTxt = ""
      local cid = M.BaseID and M.BaseID(key)
      local cc = cid and M.CraftCost and (not M.CraftingOn or M.CraftingOn()) and M.CraftCost(cid)
      if cc and cc.now then
        local mint = string.format("|cff%02x%02x%02x", C.mint[1] * 255, C.mint[2] * 255, C.mint[3] * 255)
        craftTxt = mint .. "Crafted|r  " .. M.MoneyPlain(cc.now)
        local ref = (not gone and m.cur and m.cur > 0) and m.cur or m.fair
        if ref and ref > 0 then
          local d = cc.now / ref - 1
          craftTxt = craftTxt .. ((d <= 0) and GRN or RED) .. string.format(" %+.0f%%", d * 100) .. "|r"
        end
        if not cc.nowOk then craftTxt = craftTxt .. MUT .. " partial|r" end
        craftTxt = craftTxt .. "      "
      end
      local post = MUT .. "Quick-sell|r  " .. M.MoneyPlain(m.quick) .. MUT .. "      Sells|r  " .. sellsTxt
      -- measure where the Crafted value sits, so its hover zone covers just it
      M.chartLine1:SetText(pre)
      local w0 = M.chartLine1:GetStringWidth() or 0
      M.chartLine1:SetText(pre .. craftTxt)
      local w1 = M.chartLine1:GetStringWidth() or 0
      M.chartLine1:SetText(pre .. craftTxt .. post)
      if M.chartCraftHot then
        if craftTxt ~= "" then
          M.chartCraftHot:ClearAllPoints()
          M.chartCraftHot:SetPoint("TOPLEFT", M.panels[TAB.Charts], "TOPLEFT", 206 + w0 - 4, -63)
          M.chartCraftHot:SetWidth(math.max(40, w1 - w0 - 16))
          M.chartCraftHot:Show()
        else
          M.chartCraftHot:Hide()
        end
      end
    else
      M.chartSignal:SetText(MUT .. "no price data yet|r")
      M.chartLine1:SetText("")
      if M.chartCraftHot then M.chartCraftHot:Hide() end
    end
    -- 3) your own record, dimmed -- and simply absent when there is none
    local sid = (M.BaseID and M.BaseID(key) and tostring(M.BaseID(key))) or key
    local srec, skey
    for k2, s2 in pairs((M.TradeStats and M.TradeStats(M.RealmKey())) or {}) do
      if s2.id and tostring(s2.id) == sid then srec, skey = s2, k2; break end
    end
    local ab = M.RealizedBuy and M.RealizedBuy(sid) or nil
    if srec then
      local sell = skey and M.Sellability and M.Sellability(skey)
      local net = srec.net or 0
      local parts = {
        MUT .. "Your trades|r   " .. (srec.soldStacks or 0) .. " sold \194\183 " .. (srec.retStacks or 0) .. " returned",
      }
      if sell and sell.rate then
        parts[#parts + 1] = string.format("%.0f%% \194\183 %s", sell.rate * 100, sell.label or "")
      end
      if (srec.soldStacks or 0) > 0 then
        -- per UNIT (like avg buy, Current and Fair); ancient log rows without
        -- a count fall back to per-auction
        local units = (srec.soldUnits or 0) > 0 and srec.soldUnits or srec.soldStacks
        parts[#parts + 1] = MUT .. "avg sell|r " .. M.MoneyPlain((srec.gross or 0) / units)
      end
      if ab then parts[#parts + 1] = MUT .. "avg buy|r " .. M.MoneyPlain(ab) end
      parts[#parts + 1] = MUT .. "net|r " .. (net >= 0 and GRN .. "+" or RED .. "-") .. M.MoneyPlain(math.abs(net)) .. "|r"
      M.chartLine2:SetText(table.concat(parts, "      "))
    elseif ab then
      M.chartLine2:SetText(MUT .. "Your trades|r   " .. MUT .. "avg buy|r " .. M.MoneyPlain(ab) .. MUT .. "  \194\183  no sales logged yet|r")
    else
      M.chartLine2:SetText("")
    end
    -- the quiet category / qty / days read-out gives way when your own
    -- record needs the room (narrow windows): the record matters more
    do
      local pw = ((M.frame and M.frame:GetWidth()) or 980) - 28
      local need = M.chartLine2:GetStringWidth() or 0
      if need > 0 and need > pw - 206 - 12 - 16 - (M.chartMeta:GetStringWidth() or 0) then
        M.chartMeta:SetText("")
      end
    end
    -- alert fields follow the item (shown in the Charts-tab button row)
    if M.alertUI then
      M.alertUI.bar:Show()
      local a = M.db.alerts and M.db.alerts[M.RealmKey()] and M.db.alerts[M.RealmKey()][M.chartKey]
      M.alertUI.below.edit:SetText((a and a.below) and M.MoneyPlain(a.below) or "")
      M.alertUI.above.edit:SetText((a and a.above) and M.MoneyPlain(a.above) or "")
    end
    C_Timer.After(0, function()
      if not M.canvas then return end
      -- an open offer book follows the item switch and re-applies its split
      -- geometry (a tab return leaves the chart re-anchored to full width)
      if M.depthView and M.depthView:IsShown() and M.ShowDepth then
        M.ShowDepth(M.chartKey)
      else
        M.RenderItemChart(M.canvas, M.chartKey)
      end
    end)
  else
    if M.alertUI then M.alertUI.bar:Hide() end
    M.chartTitle:SetText("No data \226\128\148 scan the AH first.")
    M.chartTitle:SetTextColor(T.Unpack(C.sub))
    if M.chartTitleIcon then M.chartTitleIcon:Hide() end
    if M.chartTitleBtn then M.chartTitleBtn:Hide() end
    if M.chartLinks then M.chartLinks:SetItem(nil) end
    if M.chartCraftHot then M.chartCraftHot:Hide() end
    M.chartTitle:ClearAllPoints()
    M.chartTitle:SetPoint("TOPLEFT", 234, -8); M.chartTitle:SetPoint("TOPRIGHT", -12, -8)
    M.chartMeta:SetText("")
    M.chartSignal:SetText(""); M.chartLine1:SetText(""); M.chartLine2:SetText("")
  end
end

-- ===== What's new: a one-time spotlight for bigger features =================
-- Every bigger feature gets ONE entry in M.NEWS. Each entry is shown once per
-- account (config.newsSeen[id]) a few seconds after login: a small preview of
-- the feature, what it does, where to find it, and a "Show me" button that
-- takes the player straight there. Several unseen entries queue up.

-- the item to demo on: the chart that is open, else the scanned item with the
-- most listed units (so the preview is never empty after a scan)
local function demoItem()
  if M.chartKey then return M.chartKey end
  local d = M.db and M.db.depth and M.db.depth[M.RealmKey()]
  local best, bestU
  if d and d.items then
    for id, flat in pairs(d.items) do
      local u = 0
      for i = 3, #flat, 3 do u = u + flat[i] end
      if not bestU or u > bestU then best, bestU = id, u end
    end
  end
  return best and tostring(best) or nil
end

M.NEWS = {
  {
    id = "offerbook-1.2.3", version = "1.2.3", title = "Offer Book",
    text = "Every price an item is listed at, cheapest first. Each bar adds to a running total of supply "
      .. "- green under Fair, gold above. Fair, quick-sell, the 7-day floor and your own buy/sell price sit "
      .. "in between; the card on the right shows what buying up to each of them costs.",
    where = "Charts tab  \226\128\186  pick an item  \226\128\186  \"offer book\" (top right)",
    preview = "offerbook",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      M.SelectTab(TAB.Charts)
      local key = demoItem()
      if key then
        M.SetChartKey(key); M.RefreshCharts()
        if M.ShowDepth then M.ShowDepth(key) end
      end
    end,
  },
  {
    id = "split-1.2.4", version = "1.2.4", title = "Split View",
    text = "The offer book can now share the screen with the price chart: the split toggle puts "
      .. "the chart on the left and the supply ladder on the right - watch the trend and the "
      .. "live asks at once. The chart and offer-book headers also carry the item's icon now.",
    where = "Charts tab  \226\128\186  offer book | split (top right)",
    preview = "offerbook",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      M.SelectTab(TAB.Charts)
      local key = demoItem()
      if key then
        M.SetChartKey(key); M.RefreshCharts()
        if M.db and M.db.config then M.db.config.depthSplit = true end
        if M.ShowDepth then M.ShowDepth(key) end
      end
    end,
  },
  {
    id = "intraday-1.2.6", version = "1.2.6", title = "Intraday charts",
    text = "On the 1W timeframe the net-worth chart and the item price charts now keep every scan "
      .. "of the last 8 days as its own point - hover shows the time of day. Longer timeframes "
      .. "still show one point per day.",
    where = "any big chart  \226\128\186  timeframe \"1W\"",
    preview = "intraday",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      if M.SetChartRange then M.SetChartRange("7") end
      M.SelectTab(TAB["Net Worth"])
    end,
  },
  {
    id = "ttchart-1.2.6", version = "1.2.6", title = "Tooltip chart",
    text = "Hovering an item now docks a mini chart of its price history to the tooltip - in your "
      .. "bags, the bank, mail and the auction house. It has its own timeframe in Settings, "
      .. "independent of the big charts and the preview cards, and an Off switch.",
    where = "Settings  \226\128\186  \"Tooltip chart\"",
    preview = "ttchart",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      M.SelectTab(TAB.Settings)
    end,
  },
  {
    id = "ahbook-1.2.6", version = "1.2.6", title = "Offer book at the AH",
    text = "Picking a browse result or dropping an item into the sell slot docks that item's "
      .. "supply ladder to the auction house window - see the wall you are up against while "
      .. "you price. Click its title for the full chart; a Settings checkbox turns it off.",
    where = "auction house  \226\128\186  right edge",
    preview = "offerbook",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      M.SelectTab(TAB.Settings)
    end,
  },
  {
    id = "alerts-1.2.7", version = "1.2.7", title = "Price alerts",
    text = "Give any item a below and/or above limit in the Charts tab: when a scan or a synced "
      .. "price reaches it, Midas rings the raid-warning bell and posts a chat line. Each side "
      .. "fires once and re-arms when the price leaves the limit; \"/midas alerts\" lists them.",
    where = "Charts tab  \226\128\186  ALERT below / above",
    preview = "alert",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      M.SelectTab(TAB.Charts)
    end,
  },
  {
    id = "guide-1.2.7", version = "1.2.7", title = "Get started guide",
    text = "New to auction-house trading, or drowning in numbers? A six-step tour now walks "
      .. "the whole Midas workflow - scan, watchlist, Fair, offer book, alerts, your trades. "
      .. "A Settings checkbox can also seed an empty watchlist with ~80 proven starter items.",
    where = "Settings  \226\128\186  Get started guide",
    preview = "watchlist",
    open = function() if M.ShowGuide then M.ShowGuide() end end,
  },
  {
    id = "browse-1.2.8", version = "1.2.8", title = "Browse the whole archive",
    text = "The Watchlist tab's new \"all items\" view lists EVERY item your scans and "
      .. "syncs have touched - sortable by any column, searchable, right-click to watch "
      .. "(a gold edge marks watched ones), and your column sort now survives reloads.",
    where = "Watchlist tab  \226\128\186  browse all items",
    preview = "watchlist",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      if M.OpenBrowse then M.OpenBrowse() else M.SelectTab(TAB.Watchlist) end
    end,
  },
  {
    id = "selldock-1.2.8", version = "1.2.8", title = "Sell helper at the AH",
    text = "The auction house sell tab now docks a bar of everything in your bags that has "
      .. "price data, best sale first (% over fair). Click an item and it lands in the "
      .. "sell slot; list it and the next candidates slide up. A Settings checkbox turns "
      .. "it off.",
    where = "auction house  \226\128\186  Auctions (sell) tab  \226\128\186  bottom edge",
    preview = "selldock",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      M.SelectTab(TAB.Settings)
    end,
  },
  {
    id = "discord-1.2.11", version = "1.2.11", title = "Midas has a Discord",
    kicker = "MIDAS \194\183 COMMUNITY",
    text = "Questions, bug reports and feature ideas now have a home: the Midas Discord. "
      .. "Ask in #help, post bugs with your Midas version and the error text, and vote on "
      .. "what comes next. Release notes land there first.",
    where = M.DISCORD_URL, link = M.DISCORD_URL, showLabel = "Copy link",
    preview = "discord",
    open = function() M.ShowLinkCopy(M.DISCORD_URL, "Midas Discord") end,
  },
  {
    id = "groups-1.2.8", version = "1.2.8", title = "Watchlist groups",
    text = "Sort your watchlist into named sections: the \"+ group\" button next to the "
      .. "search creates one, dragging a row onto a group chip (always above the table - "
      .. "they work from a search too), a header or one of its items files it; UNGROUPED "
      .. "files it out. Clicking a chip filters the list to that group. Headers fold on "
      .. "click; right-click renames, shift-click deletes (the items stay on the list).",
    where = "Watchlist tab  \226\128\186  + group  \194\183  drag rows",
    preview = "watchlist",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      M.SelectTab(TAB.Watchlist)
    end,
  },
  {
    id = "tradewin-1.2.15", version = "1.2.15", title = "Trade window + realized margin",
    text = "Sales and buys through the player trade window now land in your trade ledger as Trade "
      .. "sell / Trade buy - several items share the gold by Fair, and trades with your own characters "
      .. "stay out. The By Item table gained a Margin column: what the units you sold really earned "
      .. "after the AH cut and your buy price, so a fresh restock no longer reads as a loss.",
    where = "Trades tab  \226\128\186  By Item  \226\128\186  Margin   \194\183   History  \226\128\186  Trade sell / buy",
    preview = "trades",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      M.SelectTab(TAB.Trades)
    end,
  },
  {
    id = "ledger-1.2.17", version = "1.2.17", title = "Ledger (beta): every gold and item flow",
    text = "A new tab books everything that moves your wealth - looted gold and items, quest rewards, "
      .. "sales and purchases, repairs, flights, training, AH deposits and cuts, crafting and the potions "
      .. "and food you used up - and draws it as one flow diagram. It is in beta: the bookings are still "
      .. "being tuned, and the \"Record ledger\" switch in the tab turns it off.",
    where = "Ledger (beta) tab   \194\183   hover a band, click to list its items",
    preview = "ledger",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      M.SelectTab(TAB.Ledger)
    end,
  },
  {
    id = "goldtimer-1.2.18", version = "1.2.18", title = "Gold timer",
    text = "A small stopwatch that counts what you earn from the moment it starts: looted, quest and "
      .. "sales gold plus the value of the items you loot or gather. Hover it for every source, your top "
      .. "items, costs like repairs and the net, each per hour. It keeps running through reloads and "
      .. "pauses while you are offline.",
    where = "minimap coin  \226\128\186  right-click   \194\183   /midas timer   \194\183   scan: shift + right-click",
    preview = "goldtimer", showLabel = "Open timer",
    open = function() if M.GoldTimerToggle then M.GoldTimerToggle(false) end end,
  },
  {
    id = "crafting-1.2.20", version = "1.2.20", title = "Crafting tree (beta)",
    text = "A new tab draws every recipe as a tech tree in its own scrollable field: the item on the right, its "
      .. "materials fanning out to the left down to the raw goods, every step priced now (gold) and at Fair "
      .. "(purple) with what making it saves over buying it. Charts and item tooltips show the craft cost too. "
      .. "It is in beta: the \"Enable crafting\" switch in the tab turns all of it off.",
    where = "Crafting (beta) tab   \194\183   Top crafts   \194\183   Charts  \226\128\186  Craft tree chip   \194\183   /midas tree <item>",
    preview = "crafting",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      M.SelectTab(TAB.Crafting)
    end,
  },
  {
    id = "links-1.2.20", version = "1.2.20", title = "Every item, every page",
    text = "Items now link to everything Midas knows about them. Right-click an item anywhere - in a list, "
      .. "on a card, in the tree - for its chart, craft tree, offer book, your trades and your stock, or to "
      .. "watch it. Chips next to an item's name jump there in one click, and after a jump the Back pill "
      .. "in the window header returns to where you came from.",
    where = "right-click any item   \194\183   chips next to a name   \194\183   \226\128\185 Back in the header",
    preview = "links",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      local key = demoItem()
      if key then M.SetChartKey(key) end
      M.SelectTab(TAB.Charts)
    end,
  },
  {
    id = "home-1.2.20", version = "1.2.20", title = "A new start page",
    text = "The Start tab now answers four questions at a glance: what your net worth did this week and why "
      .. "(market prices, stock, gold), what your trading earned, which watched items are cheap or ready to "
      .. "sell - your watchlist as a tinted grid of item tiles - and what to do next: fresh price alerts, "
      .. "listings a newer scan undercuts, and sell and buy ideas ranked by the gold they move. The switch "
      .. "next to the tabs brings back the classic start page.",
    where = "Start tab   \194\183   Dashboard | Classic next to the tabs",
    preview = "home",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      M.SelectTab(TAB.Start)
    end,
  },
}

-- ===== Get-started tour =====================================================
-- The same stacked window as M.NEWS, but a workflow walk for new (or
-- overwhelmed) users: Settings/Help open it on demand, and a genuinely fresh
-- install sees it at first login instead of the what's-new backlog (Core.lua).
M.GUIDE = {
  {
    kicker = "MIDAS \194\183 GET STARTED", title = "Scan, every visit",
    text = "Everything in Midas - prices, Fair, charts, scores - is built from YOUR auction "
      .. "house scans. Open the AH and hit Scan (or let Settings > auto-scan do it); the "
      .. "server allows a full scan roughly every 15 minutes. Scan daily: every day deepens "
      .. "the history and sharpens every number.",
    where = "auction house  \226\128\186  Scan   \194\183   Settings  \226\128\186  auto-scan",
    preview = "scan",
    open = function() M.EnsureUI(); M.frame:Show(); M.SelectTab(TAB.Settings) end,
  },
  {
    kicker = "MIDAS \194\183 GET STARTED", title = "The watchlist is home base",
    text = "Trading begins with a shortlist. Right-click any item anywhere in Midas to watch "
      .. "it; the Watchlist tab ranks your items by Score and shows Current vs Fair at a "
      .. "glance. New installs start with a proven base of ~80 good traders (Settings > "
      .. "Starter watchlist) - trim it to your market.",
    where = "Watchlist tab   \194\183   right-click any item",
    preview = "watchlist",
    open = function() M.EnsureUI(); M.frame:Show(); M.SelectTab(TAB.Watchlist) end,
  },
  {
    kicker = "MIDAS \194\183 GET STARTED", title = "Fair tells you cheap or dear",
    text = "Fair is what an item really clears at on your realm: weeks of scans, spikes "
      .. "trimmed, capped by real sales. Current is the cheapest buyout right now. Green = "
      .. "under Fair (consider buying), red = over Fair (consider selling); Score ranks "
      .. "today's best opportunities. The Help tab explains every number.",
    where = "hover any item   \194\183   Watchlist columns   \194\183   Help tab",
    preview = "ttchart",
    open = function() M.EnsureUI(); M.frame:Show(); M.SelectTab(TAB.Help) end,
  },
  {
    kicker = "MIDAS \194\183 GET STARTED", title = "Check the wall before you price",
    text = "Click any item for its full chart. The offer book lists every current ask, "
      .. "cheapest first, with a running supply total - see the wall you would sit behind "
      .. "before you buy or undercut. At the auction house it docks on automatically while "
      .. "you browse or sell.",
    where = "Charts tab  \226\128\186  offer book   \194\183   auction house right edge",
    preview = "offerbook",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      M.SelectTab(TAB.Charts)
      local key = demoItem()
      if key then
        M.SetChartKey(key); M.RefreshCharts()
        if M.ShowDepth then M.ShowDepth(key) end
      end
    end,
  },
  {
    kicker = "MIDAS \194\183 GET STARTED", title = "Let Midas ring the bell",
    text = "Give an item a below/above limit in the Charts tab and Midas rings the moment a "
      .. "scan or a synced price reaches it - no more staring at search results. The start "
      .. "page's movers list what jumped or crashed since yesterday; both are where flips "
      .. "are born.",
    where = "Charts tab  \226\128\186  ALERT   \194\183   Start  \226\128\186  movers",
    preview = "alert",
    open = function() M.EnsureUI(); M.frame:Show(); M.SelectTab(TAB.Charts) end,
  },
  {
    kicker = "MIDAS \194\183 GET STARTED", title = "Read your own ledger",
    text = "Every buy, sale, cancel and expiry books itself the moment you open the mailbox. "
      .. "The band on the Trades tab answers the only question that matters - are you "
      .. "actually up? - net P/L, the value change of what you still hold, fees paid. Check "
      .. "it weekly and double down on what works. Reopen this tour anytime: Settings > "
      .. "Get started guide.",
    where = "Trades tab",
    preview = "trades",
    open = function() M.EnsureUI(); M.frame:Show(); M.SelectTab(TAB.Trades) end,
  },
  {
    kicker = "MIDAS \194\183 GET STARTED", title = "Stuck? Ask the community",
    text = "The Midas Discord is the place for questions, bug reports and ideas - and the "
      .. "first to hear about new versions. Click the link to copy it; the Help tab and "
      .. "\"/midas discord\" have it too.",
    where = M.DISCORD_URL, link = M.DISCORD_URL, showLabel = "Copy link",
    preview = "discord",
    open = function() M.ShowLinkCopy(M.DISCORD_URL, "Midas Discord") end,
  },
}

-- WoW cannot open a browser: links go into a selected, read-only edit box the
-- player copies with Ctrl+C (the usual addon way to hand out a URL)
function M.ShowLinkCopy(url, title)
  if not url then return end
  if not (StaticPopupDialogs and StaticPopup_Show) then M.Print(url); return end
  StaticPopupDialogs["MIDAS_COPY_LINK"] = StaticPopupDialogs["MIDAS_COPY_LINK"] or {
    text = "%s\n\nPress Ctrl+C to copy the link, then paste it into your browser.",
    button1 = OKAY or "OK",
    hasEditBox = true, editBoxWidth = 260,
    OnShow = function(self, data)
      local eb = self.editBox or self.EditBox
      if eb then eb:SetText(data or ""); eb:SetFocus(); eb:HighlightText() end
    end,
    -- read-only: anything typed snaps back to the link, still selected
    EditBoxOnTextChanged = function(self, data)
      if data and self:GetText() ~= data then self:SetText(data); self:HighlightText() end
    end,
    EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
  StaticPopup_Show("MIDAS_COPY_LINK", "|cffE8B44A" .. (title or "Midas") .. "|r", nil, url)
end

-- tiny offer-book illustration: a cumulative tree with a Fair row in it
local function drawOfferbookPreview(f)
  local rows = { { 0.00, 0.10, true }, { 0.10, 0.18, true }, { 0.28, 0.12, true }, "fair",
                 { 0.40, 0.08 }, { 0.48, 0.32 }, { 0.80, 0.06 }, { 0.86, 0.14 } }
  local W, y = 150, -8
  local PU = C.purple or C.accent
  for _, r in ipairs(rows) do
    if r == "fair" then
      local t = f:CreateTexture(nil, "BACKGROUND"); t:SetColorTexture(PU[1], PU[2], PU[3], 0.10)
      t:SetPoint("TOPLEFT", 6, y); t:SetSize(W + 16, 10)
      local ln = f:CreateTexture(nil, "ARTWORK"); ln:SetColorTexture(PU[1], PU[2], PU[3], 0.9)
      ln:SetPoint("TOPLEFT", 14, y - 4); ln:SetSize(W * 0.40, 2)
      local dot = f:CreateTexture(nil, "OVERLAY"); dot:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
      dot:SetVertexColor(PU[1], PU[2], PU[3], 1); dot:SetSize(7, 7)
      dot:SetPoint("CENTER", f, "TOPLEFT", 14 + W * 0.40, y - 5)
      local fs = T.Text(f, T.SIZE.tiny, "text", T.FONT_SEMI); fs:SetTextColor(PU[1], PU[2], PU[3])
      fs:SetPoint("LEFT", dot, "RIGHT", 4, 0); fs:SetText("FAIR")
      y = y - 12
    else
      local g = f:CreateTexture(nil, "BORDER"); g:SetColorTexture(C.sub[1], C.sub[2], C.sub[3], 0.16)
      g:SetPoint("TOPLEFT", 14, y - 3); g:SetSize(math.max(1, W * r[1]), 10)
      if r[1] == 0 then g:Hide() end
      local c = r[3] and C.green or (C.teal or C.accent)
      local b = f:CreateTexture(nil, "ARTWORK"); b:SetColorTexture(c[1], c[2], c[3], r[3] and 0.8 or 0.7)
      b:SetPoint("TOPLEFT", 14 + W * r[1], y - 3); b:SetSize(W * r[2], 10)
      y = y - 16
    end
  end
  local edge = f:CreateTexture(nil, "BORDER"); edge:SetColorTexture(C.green[1], C.green[2], C.green[3], 0.8)
  edge:SetPoint("TOPLEFT", 6, -8); edge:SetSize(2, 3 * 16 + 5)
end

-- tiny intraday illustration: a rising dotted line, the last day crowded with
-- per-scan points. Hides whatever an earlier preview kind drew on the frame.
local function drawIntradayPreview(f)
  for _, r in ipairs({ f:GetRegions() }) do r:Hide() end
  local bg = f:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints()
  bg:SetColorTexture(C.bg0[1], C.bg0[2], C.bg0[3], 1)
  local TL = C.teal or C.accent
  for _, x in ipairs({ 14, 62, 110 }) do
    local g = f:CreateTexture(nil, "BORDER"); g:SetColorTexture(C.sub[1], C.sub[2], C.sub[3], 0.14)
    g:SetPoint("TOPLEFT", x, -14); g:SetSize(1, 100)
  end
  local nodes = { { 14, -100 }, { 62, -78 }, { 110, -70 }, { 121, -79 }, { 132, -58 },
                  { 143, -64 }, { 154, -44 }, { 164, -50 }, { 172, -38 } }
  for i = 2, #nodes do
    local x0, y0, x1, y1 = nodes[i - 1][1], nodes[i - 1][2], nodes[i][1], nodes[i][2]
    local segN = math.max(2, math.floor((x1 - x0) / 4))
    for s = 1, segN - 1 do
      local t = f:CreateTexture(nil, "ARTWORK"); t:SetColorTexture(TL[1], TL[2], TL[3], 0.55)
      t:SetSize(2, 2)
      t:SetPoint("CENTER", f, "TOPLEFT", x0 + (x1 - x0) * s / segN, y0 + (y1 - y0) * s / segN)
    end
  end
  for i, p in ipairs(nodes) do
    local dot = f:CreateTexture(nil, "OVERLAY"); dot:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    dot:SetVertexColor(TL[1], TL[2], TL[3], 1)
    local sz = (i <= 2) and 7 or 5
    dot:SetSize(sz, sz)
    dot:SetPoint("CENTER", f, "TOPLEFT", p[1], p[2])
  end
  local fs = T.Text(f, T.SIZE.tiny, "text", T.FONT_SEMI); fs:SetTextColor(TL[1], TL[2], TL[3])
  fs:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -122); fs:SetText("1W \194\183 every scan is a point")
end

-- tiny tooltip-chart illustration: a "tooltip" box with a mini chart docked
-- under it
local function drawTooltipChartPreview(f)
  local TL = C.teal or C.accent
  local function box(x, y, w, h)
    local b = f:CreateTexture(nil, "BORDER"); b:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.9)
    b:SetPoint("TOPLEFT", x, y); b:SetSize(w, h)
    local i2 = f:CreateTexture(nil, "ARTWORK"); i2:SetColorTexture(C.bg1 and C.bg1[1] or 0.09, C.bg1 and C.bg1[2] or 0.10, C.bg1 and C.bg1[3] or 0.13, 1)
    i2:SetPoint("TOPLEFT", x + 1, y - 1); i2:SetSize(w - 2, h - 2)
  end
  -- the tooltip: a bordered box with text bars (title gold, lines grey)
  box(16, -12, 148, 56)
  local tb = f:CreateTexture(nil, "OVERLAY"); tb:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.9)
  tb:SetPoint("TOPLEFT", 24, -20); tb:SetSize(64, 6)
  for i, w in ipairs({ 104, 84, 60 }) do
    local l = f:CreateTexture(nil, "OVERLAY"); l:SetColorTexture(C.sub[1], C.sub[2], C.sub[3], 0.5)
    l:SetPoint("TOPLEFT", 24, -20 - i * 10); l:SetSize(w, 4)
  end
  -- the docked chart panel below it
  box(16, -72, 148, 48)
  local nodes = { { 26, -108 }, { 50, -96 }, { 74, -102 }, { 98, -88 }, { 122, -94 }, { 152, -82 } }
  for i = 2, #nodes do
    local x0, y0, x1, y1 = nodes[i - 1][1], nodes[i - 1][2], nodes[i][1], nodes[i][2]
    local segN = math.max(2, math.floor((x1 - x0) / 4))
    for s2 = 1, segN - 1 do
      local t = f:CreateTexture(nil, "OVERLAY"); t:SetColorTexture(TL[1], TL[2], TL[3], 0.6)
      t:SetSize(2, 2)
      t:SetPoint("CENTER", f, "TOPLEFT", x0 + (x1 - x0) * s2 / segN, y0 + (y1 - y0) * s2 / segN)
    end
  end
  for _, p in ipairs(nodes) do
    local dot = f:CreateTexture(nil, "OVERLAY"); dot:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    dot:SetVertexColor(TL[1], TL[2], TL[3], 1); dot:SetSize(5, 5)
    dot:SetPoint("CENTER", f, "TOPLEFT", p[1], p[2])
  end
  local fs = T.Text(f, T.SIZE.tiny, "text", T.FONT_SEMI); fs:SetTextColor(TL[1], TL[2], TL[3])
  fs:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -126); fs:SetText("hover an item \194\183 chart docks on")
end

-- tiny price-alert illustration: a wobbly price line crossing a limit line
local function drawAlertPreview(f)
  local TL = C.teal or C.accent
  local AC = C.accent
  -- the limit line (dashed) with its label
  for x = 14, 158, 10 do
    local t = f:CreateTexture(nil, "BORDER"); t:SetColorTexture(AC[1], AC[2], AC[3], 0.8)
    t:SetSize(6, 2); t:SetPoint("TOPLEFT", x, -54)
  end
  local la = T.Text(f, T.SIZE.tiny, "text", T.FONT_SEMI); la:SetTextColor(AC[1], AC[2], AC[3])
  la:SetPoint("TOPLEFT", 14, -40); la:SetText("ALERT below 4g50s")
  -- the price line dipping through it
  local nodes = { { 14, -78 }, { 44, -70 }, { 74, -84 }, { 104, -66 }, { 134, -48 }, { 164, -58 } }
  for i = 2, #nodes do
    local x0, y0, x1, y1 = nodes[i - 1][1], nodes[i - 1][2], nodes[i][1], nodes[i][2]
    local segN = math.max(2, math.floor((x1 - x0) / 4))
    for s2 = 1, segN - 1 do
      local t = f:CreateTexture(nil, "ARTWORK"); t:SetColorTexture(TL[1], TL[2], TL[3], 0.6)
      t:SetSize(2, 2)
      t:SetPoint("CENTER", f, "TOPLEFT", x0 + (x1 - x0) * s2 / segN, y0 + (y1 - y0) * s2 / segN)
    end
  end
  for _, p in ipairs(nodes) do
    local dot = f:CreateTexture(nil, "OVERLAY"); dot:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    dot:SetVertexColor(TL[1], TL[2], TL[3], 1); dot:SetSize(5, 5)
    dot:SetPoint("CENTER", f, "TOPLEFT", p[1], p[2])
  end
  -- the crossing point gets the "bell" dot
  local bell = f:CreateTexture(nil, "OVERLAY"); bell:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
  bell:SetVertexColor(AC[1], AC[2], AC[3], 1); bell:SetSize(9, 9)
  bell:SetPoint("CENTER", f, "TOPLEFT", 134, -48)
  local fs = T.Text(f, T.SIZE.tiny, "text", T.FONT_SEMI); fs:SetTextColor(TL[1], TL[2], TL[3])
  fs:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -116); fs:SetText("scan hits the limit \194\183 bell rings")
end

-- tiny get-started illustration: a Scan button pouring rows into the archive
local function drawScanPreview(f)
  local AC = C.accent
  local b = f:CreateTexture(nil, "BORDER"); b:SetColorTexture(AC[1], AC[2], AC[3], 0.18)
  b:SetPoint("TOPLEFT", 40, -14); b:SetSize(100, 24)
  local e = f:CreateTexture(nil, "ARTWORK"); e:SetColorTexture(AC[1], AC[2], AC[3], 0.9)
  e:SetPoint("TOPLEFT", 40, -38); e:SetSize(100, 2)
  local fs = T.Text(f, T.SIZE.body, "text", T.FONT_SEMI); fs:SetTextColor(AC[1], AC[2], AC[3])
  fs:SetPoint("CENTER", f, "TOPLEFT", 90, -26); fs:SetText("SCAN")
  -- rows raining into the archive, fading as they settle
  local rows = { { 118, 0.9 }, { 96, 0.7 }, { 132, 0.5 }, { 84, 0.35 }, { 108, 0.22 } }
  for i, r in ipairs(rows) do
    local t = f:CreateTexture(nil, "ARTWORK"); t:SetColorTexture(C.sub[1], C.sub[2], C.sub[3], r[2] * 0.6)
    t:SetPoint("TOPLEFT", 30, -50 - i * 12); t:SetSize(r[1], 6)
  end
  local TL = C.teal or C.accent
  local cap = T.Text(f, T.SIZE.tiny, "text", T.FONT_SEMI); cap:SetTextColor(TL[1], TL[2], TL[3])
  cap:SetPoint("TOPLEFT", 14, -124); cap:SetText("every scan feeds every number")
end

-- tiny watchlist illustration: ranked rows, green cheap / red dear
local function drawWatchPreview(f)
  local rows = {
    { 64, "-31%", C.green }, { 84, "-18%", C.green }, { 52, "+4%", C.sub },
    { 92, "+22%", C.red },   { 70, "+35%", C.red },
  }
  for i, r in ipairs(rows) do
    local y = -14 - (i - 1) * 20
    local ic = f:CreateTexture(nil, "ARTWORK")
    ic:SetColorTexture(C.sub[1], C.sub[2], C.sub[3], 0.35)
    ic:SetPoint("TOPLEFT", 14, y); ic:SetSize(10, 10)
    local nm = f:CreateTexture(nil, "ARTWORK")
    nm:SetColorTexture(C.sub[1], C.sub[2], C.sub[3], 0.5)
    nm:SetPoint("TOPLEFT", 30, y - 2); nm:SetSize(r[1], 6)
    local d = T.Text(f, T.SIZE.tiny, "text", T.FONT_SEMI)
    d:SetTextColor(r[3][1], r[3][2], r[3][3])
    d:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, y); d:SetJustifyH("RIGHT")
    d:SetText(r[2])
  end
  local TL = C.teal or C.accent
  local fs = T.Text(f, T.SIZE.tiny, "text", T.FONT_SEMI); fs:SetTextColor(TL[1], TL[2], TL[3])
  fs:SetPoint("TOPLEFT", 14, -124); fs:SetText("right-click any item \194\183 watch")
end

-- tiny trades illustration: the band's verdict tiles
local function drawTradesPreview(f)
  local tiles = {
    { "NET P/L", "+812g", C.green }, { "HOLDINGS", "+803g", C.green },
    { "AH FEES", "78g", C.accent },
  }
  for i, t in ipairs(tiles) do
    local y = -14 - (i - 1) * 34
    local bg = f:CreateTexture(nil, "BORDER")
    bg:SetColorTexture(C.sub[1], C.sub[2], C.sub[3], 0.10)
    bg:SetPoint("TOPLEFT", 14, y); bg:SetSize(152, 28)
    local lb = T.Text(f, T.SIZE.tiny, "muted", T.FONT_MED)
    lb:SetPoint("TOPLEFT", 22, y - 5); lb:SetText(t[1])
    local v = T.Text(f, T.SIZE.body, "text", T.FONT_SEMI)
    v:SetTextColor(t[3][1], t[3][2], t[3][3])
    v:SetPoint("TOPRIGHT", f, "TOPLEFT", 158, y - 7); v:SetJustifyH("RIGHT")
    v:SetText(t[2])
  end
  local TL = C.teal or C.accent
  local fs = T.Text(f, T.SIZE.tiny, "text", T.FONT_SEMI); fs:SetTextColor(TL[1], TL[2], TL[3])
  fs:SetPoint("TOPLEFT", 14, -124); fs:SetText("the band: are you actually up?")
end

-- tiny sell-dock illustration: a row of item squares with % tags, best first
local function drawSellDockPreview(f)
  local AC = C.accent
  local sb = f:CreateTexture(nil, "BORDER"); sb:SetColorTexture(AC[1], AC[2], AC[3], 0.25)
  sb:SetPoint("TOPLEFT", 74, -10); sb:SetSize(30, 30)
  local lb = T.Text(f, T.SIZE.tiny, "muted"); lb:SetPoint("LEFT", sb, "RIGHT", 6, 0); lb:SetText("sell slot")
  local a1 = T.Text(f, T.SIZE.body, "text", T.FONT_SEMI); a1:SetTextColor(AC[1], AC[2], AC[3])
  a1:SetPoint("TOPLEFT", 38, -42); a1:SetText("\194\187")
  local tags = { { "+62%", C.green }, { "+31%", C.green }, { "+18%", C.green }, { "-4%", C.sub } }
  for i, t in ipairs(tags) do
    local x = 14 + (i - 1) * 40
    local q = f:CreateTexture(nil, "ARTWORK"); q:SetColorTexture(C.sub[1], C.sub[2], C.sub[3], 0.30)
    q:SetPoint("TOPLEFT", x, -64); q:SetSize(30, 30)
    local p = T.Text(f, T.SIZE.tiny, "text", T.FONT_SEMI); p:SetTextColor(t[2][1], t[2][2], t[2][3])
    p:SetPoint("TOP", q, "BOTTOM", 0, -3); p:SetText(t[1])
  end
  local TL = C.teal or C.accent
  local fs = T.Text(f, T.SIZE.tiny, "text", T.FONT_SEMI); fs:SetTextColor(TL[1], TL[2], TL[3])
  fs:SetPoint("TOPLEFT", 14, -118); fs:SetText("best sale first \194\183 click loads it")
end

-- tiny community illustration: a Discord-style channel list, #help lit up
local function drawDiscordPreview(f)
  local AC = C.accent
  local chans = { { "help", true }, { "bug-reports" }, { "feature-requests" }, { "announcements" } }
  for i, ch in ipairs(chans) do
    local y = -16 - (i - 1) * 24
    if ch[2] then
      local hl = f:CreateTexture(nil, "BORDER"); hl:SetColorTexture(AC[1], AC[2], AC[3], 0.14)
      hl:SetPoint("TOPLEFT", 10, y + 5); hl:SetSize(160, 20)
    end
    local hash = T.Text(f, T.SIZE.body, "text", T.FONT_SEMI)
    hash:SetPoint("TOPLEFT", 18, y); hash:SetText("#")
    if ch[2] then hash:SetTextColor(AC[1], AC[2], AC[3]) else hash:SetTextColor(C.sub[1], C.sub[2], C.sub[3]) end
    local nm = T.Text(f, T.SIZE.small, ch[2] and "text" or "sub", T.FONT_MED)
    nm:SetPoint("LEFT", hash, "RIGHT", 6, 0); nm:SetText(ch[1])
  end
  local TL = C.teal or C.accent
  local fs = T.Text(f, T.SIZE.tiny, "text", T.FONT_SEMI); fs:SetTextColor(TL[1], TL[2], TL[3])
  fs:SetPoint("TOPLEFT", 14, -124); fs:SetText("help \194\183 bugs \194\183 ideas \194\183 news")
end

-- tiny ledger illustration: the real Sankey renderer on a canned, balanced flow
local function drawLedgerPreview(f)
  if not M.RenderSankey then return end
  M.RenderSankey(f, {
    nodes = {
      { id = "lo", label = "Looted gold", col = 0, lane = "gold", color = "accent" },
      { id = "qu", label = "Quests", col = 0, lane = "gold", color = "accent" },
      { id = "il", label = "Looted items", col = 0, lane = "goods", color = "mint" },
      { id = "STOCK", label = "Stock", col = 1, lane = "goods", color = "mint", hub = true },
      { id = "GOLD", label = "Gold", col = 2, lane = "gold", color = "accent", hub = true },
      { id = "rp", label = "Repairs", col = 3, lane = "gold", color = "red" },
      { id = "sv", label = "Saved gold", col = 3, lane = "gold", color = "green" },
      { id = "xc", label = "Consumed", col = 3, lane = "goods", color = "purple" },
    },
    links = {
      { from = "lo", to = "GOLD", value = 40 }, { from = "qu", to = "GOLD", value = 25 },
      { from = "il", to = "STOCK", value = 60 },
      { from = "STOCK", to = "GOLD", value = 35, label = "Sold" },
      { from = "STOCK", to = "xc", value = 25 },
      { from = "GOLD", to = "rp", value = 30 }, { from = "GOLD", to = "sv", value = 70 },
    },
  }, { compact = true, noHover = true })
end

-- tiny gold timer illustration: the window itself over the start of its hover card
local function drawGoldTimerPreview(f)
  local AC, TL, B = C.accent, C.teal or C.accent, C.border
  -- regions only (the pager hides regions, not child frames)
  local win = f:CreateTexture(nil, "BORDER")
  win:SetColorTexture(B[1], B[2], B[3], 1)
  win:SetPoint("TOPLEFT", 10, -12); win:SetSize(160, 52)
  local fill = f:CreateTexture(nil, "ARTWORK")
  fill:SetColorTexture(C.bg1[1], C.bg1[2], C.bg1[3], 1)
  fill:SetPoint("TOPLEFT", win, "TOPLEFT", 1, -1); fill:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -1, 1)
  local kick = T.Text(f, T.SIZE.tiny, "muted", T.FONT_SEMI)
  kick:SetPoint("TOPLEFT", win, "TOPLEFT", 8, -6); kick:SetText("GOLD TIMER")
  local st = T.Text(f, T.SIZE.tiny, "green", T.FONT_MED)
  st:SetPoint("LEFT", kick, "RIGHT", 6, 0); st:SetText("running")
  local clk = T.Text(f, T.SIZE.body, "text", T.FONT_SEMI)
  clk:SetPoint("TOPLEFT", win, "TOPLEFT", 8, -20); clk:SetText("0:42:13")
  local earned = T.Text(f, T.SIZE.body, "text", T.FONT_SEMI)
  earned:SetPoint("TOPRIGHT", win, "TOPRIGHT", -8, -20); earned:SetText("38g 20s"); earned:SetTextColor(TL[1], TL[2], TL[3])
  local rate = T.Text(f, T.SIZE.tiny, "sub", T.FONT_MED)
  rate:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -8, 6); rate:SetText("54g 30s / h")
  local rows = { { "Looted gold", "11g 05s" }, { "Runecloth  x34", "20g 40s" }, { "Repairs", "-2g 10s" } }
  for i, r in ipairs(rows) do
    local y = -76 - (i - 1) * 16
    local l = T.Text(f, T.SIZE.tiny, "sub", T.FONT_MED); l:SetPoint("TOPLEFT", 14, y); l:SetText(r[1])
    local v = T.Text(f, T.SIZE.tiny, "text", T.FONT_MED); v:SetPoint("TOPRIGHT", -14, y); v:SetText(r[2])
    if i == 3 then v:SetTextColor(C.red[1], C.red[2], C.red[3]) else v:SetTextColor(AC[1], AC[2], AC[3]) end
  end
end

-- tiny crafting tree: three materials feed one product, each priced now (gold)
-- over Fair (purple); regions only, like every preview
local function drawCraftingPreview(f)
  local TL, PU, BL = C.teal or C.accent, C.purple, C.borderlt
  local function box(x, y, w, h, q, now, fair, border)
    local b = f:CreateTexture(nil, "BORDER")
    b:SetColorTexture(border[1], border[2], border[3], 1)
    b:SetPoint("TOPLEFT", x, y); b:SetSize(w, h)
    local fill = f:CreateTexture(nil, "ARTWORK")
    fill:SetColorTexture(C.bg1[1], C.bg1[2], C.bg1[3], 1)
    fill:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1); fill:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    local ic = f:CreateTexture(nil, "OVERLAY")
    ic:SetColorTexture(q[1], q[2], q[3], 1)
    ic:SetPoint("TOPLEFT", b, "TOPLEFT", 4, -4); ic:SetSize(h - 8, h - 8)
    local a = T.Text(f, T.SIZE.tiny, nil, T.FONT_MED); a:SetTextColor(TL[1], TL[2], TL[3])
    a:SetPoint("TOPLEFT", ic, "TOPRIGHT", 4, 1); a:SetText(now)
    local p = T.Text(f, T.SIZE.tiny, nil, T.FONT_MED); p:SetTextColor(PU[1], PU[2], PU[3])
    p:SetPoint("TOPLEFT", ic, "TOPRIGHT", 4, -10); p:SetText(fair)
  end
  local function seg(x, y, w, h)
    local t = f:CreateTexture(nil, "BORDER")
    t:SetColorTexture(BL[1], BL[2], BL[3], 1)
    t:SetPoint("TOPLEFT", x, y); t:SetSize(w, h)
  end
  local mats = { { -12, { 0.12, 1, 0 }, "1g 20s", "1g 10s" }, { -54, { 1, 1, 1 }, "4g 05s", "4g 30s" },
                 { -96, { 0.12, 1, 0 }, "60s", "55s" } }
  for _, m in ipairs(mats) do
    box(6, m[1], 70, 30, m[2], m[3], m[4], C.border)
    seg(76, m[1] - 15, 14, 2)
  end
  seg(90, -27, 2, 84)
  seg(90, -68, 18, 2)
  box(108, -50, 68, 38, { 0, 0.44, 0.87 }, "9g 40s", "9g 10s", C.accent)
  local tag = T.Text(f, T.SIZE.tiny, "green", T.FONT_SEMI)
  tag:SetPoint("TOPRIGHT", -6, -92); tag:SetText("+24%")
end

-- tiny item-links illustration: the Back pill, a name with its page chips and
-- the right-click menu under it; regions only, like every preview
-- tiny start-page illustration: the watchlist map's tinted tiles + a move
local function drawHomePreview(f)
  local G, R, N = C.green, C.red, C.bg2
  local tint = { G, G, N, N, R, R, G, N, N, N, R, N, N, G, N, N, N, R }
  for i, c in ipairs(tint) do
    local col, row = (i - 1) % 6, math.floor((i - 1) / 6)
    local t = f:CreateTexture(nil, "BORDER")
    t:SetColorTexture(c[1], c[2], c[3], (c == N) and 1 or 0.5)
    t:SetPoint("TOPLEFT", 14 + col * 26, -12 - row * 26); t:SetSize(22, 22)
    local ic = f:CreateTexture(nil, "ARTWORK")
    ic:SetColorTexture(C.sub[1], C.sub[2], C.sub[3], 0.35)
    ic:SetPoint("TOP", t, "TOP", 0, -3); ic:SetSize(12, 12)
  end
  local pill = f:CreateTexture(nil, "BORDER")
  pill:SetColorTexture(C.red[1], C.red[2], C.red[3], 0.18)
  pill:SetPoint("TOPLEFT", 14, -96); pill:SetSize(34, 14)
  local pv = T.Text(f, T.SIZE.tiny, "red", T.FONT_MED); pv:SetPoint("CENTER", pill, "CENTER", 0, 0); pv:SetText("SELL")
  local nm = f:CreateTexture(nil, "ARTWORK")
  nm:SetColorTexture(C.sub[1], C.sub[2], C.sub[3], 0.5)
  nm:SetPoint("LEFT", pill, "RIGHT", 8, 0); nm:SetSize(64, 6)
  local val = T.Text(f, T.SIZE.tiny, "accent", T.FONT_SEMI)
  val:SetPoint("TOPRIGHT", f, "TOPLEFT", 166, -98); val:SetJustifyH("RIGHT"); val:SetText("\226\137\164 31g")
  local TL = C.teal or C.accent
  local fs = T.Text(f, T.SIZE.tiny, "text", T.FONT_SEMI); fs:SetTextColor(TL[1], TL[2], TL[3])
  fs:SetPoint("TOPLEFT", 14, -124); fs:SetText("what to do next, at a glance")
end

local function drawLinksPreview(f)
  local function pill(x, y, w, col, label, fillA)
    local b = f:CreateTexture(nil, "BORDER")
    b:SetColorTexture(col[1], col[2], col[3], 0.75)
    b:SetPoint("TOPLEFT", x, y); b:SetSize(w, 16)
    local fill = f:CreateTexture(nil, "ARTWORK")
    fill:SetColorTexture(C.bg1[1], C.bg1[2], C.bg1[3], 1)
    fill:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1); fill:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    local tint = f:CreateTexture(nil, "OVERLAY")
    tint:SetColorTexture(col[1], col[2], col[3], fillA or 0.12)
    tint:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1); tint:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    local t = T.Text(f, T.SIZE.tiny, "text", T.FONT_MED)
    t:SetPoint("LEFT", b, "LEFT", 6, 0); t:SetText(label)
  end
  pill(4, -6, 88, C.accent, "\226\128\185 Back to Trades", 0.18)
  local nm = T.Text(f, T.SIZE.small, "text", T.FONT_SEMI)
  nm:SetPoint("TOPLEFT", 6, -32); nm:SetText("Arcanite Bar")
  nm:SetTextColor(0.64, 0.21, 0.93)
  pill(4, -50, 70, C.mint, "Craft tree \226\128\186")
  pill(78, -50, 64, C.green, "Trades \226\128\186")
  pill(146, -50, 32, C.accent, "+")
  -- the right-click menu
  local mb = f:CreateTexture(nil, "BORDER")
  mb:SetColorTexture(C.borderlt[1], C.borderlt[2], C.borderlt[3], 1)
  mb:SetPoint("TOPLEFT", 30, -74); mb:SetSize(130, 62)
  local mf = f:CreateTexture(nil, "ARTWORK")
  mf:SetColorTexture(C.bg1[1], C.bg1[2], C.bg1[3], 1)
  mf:SetPoint("TOPLEFT", mb, "TOPLEFT", 1, -1); mf:SetPoint("BOTTOMRIGHT", mb, "BOTTOMRIGHT", -1, 1)
  local rows = { { "Chart", C.accent }, { "Craft tree", C.mint }, { "Offer book", C.blue }, { "Your stock", C.purple } }
  for i, r in ipairs(rows) do
    local y = -79 - (i - 1) * 14
    local dot = f:CreateTexture(nil, "OVERLAY")
    dot:SetColorTexture(r[2][1], r[2][2], r[2][3], 1)
    dot:SetPoint("TOPLEFT", 38, y - 4); dot:SetSize(5, 5)
    local t = T.Text(f, T.SIZE.tiny, (i == 2) and "text" or "sub", T.FONT_MED)
    t:SetPoint("TOPLEFT", 48, y); t:SetText(r[1])
    if i == 2 then t:SetTextColor(r[2][1], r[2][2], r[2][3]) end
  end
end

local newsFrame
-- render the current entry of the stacked news window (f._list / f._idx)
local function renderNews(f)
  local n = f._list and #f._list or 0
  local item = f._list and f._list[f._idx]
  if not item then f:Hide(); return end
  f.kicker:SetText(item.kicker or ("NEW IN MIDAS " .. item.version))
  f.title:SetText(item.title)
  f.text:SetText(item.text)
  f.where:SetText(item.where)
  -- a link entry: the WHERE line is clickable (copy box) and the button says so
  f._link = item.link
  f.whereL:SetText(item.link and "LINK  \194\183  CLICK TO COPY" or "WHERE TO FIND IT")
  f.whereBtn:SetShown(item.link ~= nil)
  f.show.text:SetText(item.showLabel or "Show me")
  if f.previewKind ~= item.preview then
    -- switching kinds: clear what the previous drawer left and lay a fresh bg
    if f.previewKind ~= nil then
      for _, r in ipairs({ f.preview:GetRegions() }) do r:Hide() end
      local pbg2 = f.preview:CreateTexture(nil, "BACKGROUND")
      pbg2:SetAllPoints(); pbg2:SetColorTexture(C.bg0[1], C.bg0[2], C.bg0[3], 1)
    end
    f.previewKind = item.preview
    if item.preview == "offerbook" then drawOfferbookPreview(f.preview)
    elseif item.preview == "intraday" then drawIntradayPreview(f.preview)
    elseif item.preview == "ttchart" then drawTooltipChartPreview(f.preview)
    elseif item.preview == "alert" then drawAlertPreview(f.preview)
    elseif item.preview == "scan" then drawScanPreview(f.preview)
    elseif item.preview == "watchlist" then drawWatchPreview(f.preview)
    elseif item.preview == "trades" then drawTradesPreview(f.preview)
    elseif item.preview == "selldock" then drawSellDockPreview(f.preview)
    elseif item.preview == "discord" then drawDiscordPreview(f.preview)
    elseif item.preview == "ledger" then drawLedgerPreview(f.preview)
    elseif item.preview == "goldtimer" then drawGoldTimerPreview(f.preview)
    elseif item.preview == "crafting" then drawCraftingPreview(f.preview)
    elseif item.preview == "links" then drawLinksPreview(f.preview)
    elseif item.preview == "home" then drawHomePreview(f.preview) end
  end
  f.pager:SetText(f._idx .. " / " .. n)
  local multi = n > 1
  f.prev:SetShown(multi); f.next:SetShown(multi); f.pager:SetShown(multi)
end

local function buildNewsFrame()
  local f = T.Surface(UIParent, "bg1", "border")
  f:SetSize(520, 290); f:SetPoint("CENTER", 0, 90)
  f:SetFrameStrata("DIALOG"); f:EnableMouse(true); f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f.kicker = T.Text(f, T.SIZE.tiny, "accent", T.FONT_MED); f.kicker:SetPoint("TOPLEFT", 20, -18)
  f.title = T.Text(f, T.SIZE.h1 + 4, "text", T.FONT_SEMI); f.title:SetPoint("TOPLEFT", 20, -32)
  f.preview = CreateFrame("Frame", nil, f)
  f.preview:SetPoint("TOPLEFT", 14, -72); f.preview:SetSize(180, 140)
  local pbg = f.preview:CreateTexture(nil, "BACKGROUND"); pbg:SetAllPoints()
  pbg:SetColorTexture(C.bg0[1], C.bg0[2], C.bg0[3], 1)
  f.text = T.Text(f, T.SIZE.body, "text")
  f.text:SetPoint("TOPLEFT", 212, -74); f.text:SetPoint("TOPRIGHT", -20, -74)
  f.text:SetJustifyH("LEFT"); f.text:SetWordWrap(true); f.text:SetSpacing(3)
  f.whereL = T.Text(f, T.SIZE.tiny, "muted", T.FONT_MED); f.whereL:SetText("WHERE TO FIND IT")
  f.whereL:SetPoint("TOPLEFT", f.text, "BOTTOMLEFT", 0, -12)
  f.where = T.Text(f, T.SIZE.body, "accent", T.FONT_MED)
  f.where:SetPoint("TOPLEFT", f.whereL, "BOTTOMLEFT", 0, -4); f.where:SetPoint("RIGHT", f, "RIGHT", -20, 0)
  f.where:SetJustifyH("LEFT"); f.where:SetWordWrap(true)
  f.whereBtn = CreateFrame("Button", nil, f)
  f.whereBtn:SetAllPoints(f.where); f.whereBtn:Hide()
  f.whereBtn:SetScript("OnClick", function() if f._link then M.ShowLinkCopy(f._link, "Midas Discord") end end)
  f.whereBtn:SetScript("OnEnter", function() f.where:SetTextColor(C.text[1], C.text[2], C.text[3]) end)
  f.whereBtn:SetScript("OnLeave", function() f.where:SetTextColor(C.accent[1], C.accent[2], C.accent[3]) end)
  f.show = T.Button(f, "Show me", 110, 24); f.show:SetPoint("BOTTOMRIGHT", -20, 16)
  f.ok = T.Button(f, "Got it", 90, 24); f.ok:SetPoint("RIGHT", f.show, "LEFT", -8, 0)
  f.close = T.Close and T.Close(f)
  if f.close then f.close:SetPoint("TOPRIGHT", -8, -8) end
  -- pager: several unseen entries stack into ONE window ("2 / 3") instead of
  -- a chain of popups; \226\128\185/\226\128\186 page through, wrapping around
  f.prev = T.Button(f, "\226\128\185", 26, 24); f.prev:SetPoint("BOTTOMLEFT", 20, 16)
  f.pager = T.Text(f, T.SIZE.body, "muted", T.FONT_MED)
  f.pager:SetPoint("LEFT", f.prev, "RIGHT", 6, 0)
  f.pager:SetWidth(44); f.pager:SetJustifyH("CENTER")
  f.next = T.Button(f, "\226\128\186", 26, 24); f.next:SetPoint("LEFT", f.pager, "RIGHT", 6, 0)
  f.prev:SetScript("OnClick", function()
    if not (f._list and f._list[2]) then return end
    f._idx = (f._idx - 2) % #f._list + 1
    renderNews(f)
  end)
  f.next:SetScript("OnClick", function()
    if not (f._list and f._list[2]) then return end
    f._idx = f._idx % #f._list + 1
    renderNews(f)
  end)
  f.ok:SetScript("OnClick", function() f:Hide() end)
  if f.close then f.close:SetScript("OnClick", function() f:Hide() end) end
  f.show:SetScript("OnClick", function()
    local item = f._list and f._list[f._idx]
    f:Hide()
    if item and item.open then item.open() end
  end)
  return f
end

-- show every unseen entry in ONE stacked window, newest first (returns false
-- when there is none). "/midas news" (force) pages through the whole history.
function M.ShowWhatsNew(force)
  if not (M.db and M.db.config) then return false end
  if InCombatLockdown and InCombatLockdown() then
    C_Timer.After(10, function() M.ShowWhatsNew(force) end)
    return false
  end
  M.db.config.newsSeen = M.db.config.newsSeen or {}
  local seen = M.db.config.newsSeen
  local list = {}
  for i = #M.NEWS, 1, -1 do
    local e = M.NEWS[i]
    if force or not seen[e.id] then list[#list + 1] = e end
  end
  if not list[1] then return false end
  -- once means once, even if it is ignored: the pager says how many there are
  for _, e in ipairs(list) do seen[e.id] = true end
  newsFrame = newsFrame or buildNewsFrame()
  local f = newsFrame
  f._list, f._idx = list, 1
  renderNews(f)
  f:Show()
  return true
end

-- the get-started tour: pages through M.GUIDE in the same stacked window.
-- Settings/Help buttons open it on demand; Core.lua shows it once on a
-- genuinely fresh install (instead of the what's-new backlog).
function M.ShowGuide()
  if InCombatLockdown and InCombatLockdown() then
    C_Timer.After(10, M.ShowGuide)
    return
  end
  newsFrame = newsFrame or buildNewsFrame()
  local f = newsFrame
  f._list, f._idx = M.GUIDE, 1
  renderNews(f)
  f:Show()
end

-- ===== Onboarding milestones ================================================
-- Six one-shot cards keyed to the own-scan-DAY counter (Data.lua bumps
-- config.scanDays once per day with a stored scan; Core.lua initializes).
-- Same stacked window as M.NEWS / M.GUIDE, one card at a time, each shown
-- once: config.obStage = highest card index shown (0 = none, 99 = account
-- pre-dates the system). When a user blows past several thresholds, only the
-- HIGHEST due card shows - lower ones drop silently, never queue.
local OB_STAGES = {
  { threshold = 0, kicker = "MIDAS \194\183 WELCOME",
    title = "Welcome - one scan starts everything",
    text = "Good call installing Midas. Everything here - prices, Fair value, charts, "
      .. "signals - is built from your own auction house scans, so the first step is "
      .. "simple: visit the auction house and hit Scan. Milestone tips like this one "
      .. "appear as your archive grows; the full tour walks every tab in two minutes.",
    where = "auction house  \226\128\186  Midas Scan",
    preview = "scan", showLabel = "Full tour",
    open = function() if M.ShowGuide then M.ShowGuide() end end,
  },
  { threshold = 1, kicker = "MIDAS \194\183 MILESTONE \194\183 SCAN DAY 1",
    title = "Make the watchlist yours",
    text = "That first scan just priced your whole realm. The Watchlist tab is home "
      .. "base: it ranks a starter set of ~80 proven traders by Score and shows "
      .. "Current vs Fair at a glance. Trim it to your market - right-click any item "
      .. "anywhere in Midas to watch or unwatch it, and pin what you actually trade.",
    where = "Watchlist tab   \194\183   right-click any item",
    preview = "watchlist",
    open = function() M.EnsureUI(); M.frame:Show(); M.SelectTab(TAB.Watchlist) end,
  },
  { threshold = 3, kicker = "MIDAS \194\183 MILESTONE \194\183 SCAN DAY 3",
    title = "Make scanning a habit",
    text = "Three scan days in - this is where Midas starts earning its keep. Fair, "
      .. "Score and the movers sharpen with every day you scan: a few days of history "
      .. "is what separates real bargains from noise. Let Settings > auto-scan carry "
      .. "the habit - it runs a full scan moments after you open the AH, as often as "
      .. "the server allows (roughly every 15 minutes).",
    where = "Settings  \226\128\186  \"Auto-scan when the AH opens\"",
    preview = "scan",
    open = function() M.EnsureUI(); M.frame:Show(); M.SelectTab(TAB.Settings) end,
  },
  { threshold = 10, kicker = "MIDAS \194\183 MILESTONE \194\183 SCAN DAY 10",
    title = "You know the highs and lows now",
    text = "Ten scan days deep - you're doing great, and your charts now show real "
      .. "highs and lows. Use that feel: refine your watchlist, then give your best "
      .. "items a below and/or above limit in the Charts tab. Midas rings the "
      .. "raid-warning bell the moment a scan or synced price reaches your limit - "
      .. "buying the dip stops being luck.",
    where = "Charts tab  \226\128\186  ALERT below / above",
    preview = "alert",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      M.SelectTab(TAB.Charts)
      local key = demoItem()
      if key then M.SetChartKey(key); M.RefreshCharts() end
    end,
  },
  { threshold = 25, kicker = "MIDAS \194\183 MILESTONE \194\183 SCAN DAY 25",
    title = "Check the wall, then sell",
    text = "Twenty-five scan days - time the selling side paid off too. Before you "
      .. "price anything, read its offer book: every current ask, cheapest first, "
      .. "with the supply wall you would sit behind. At the auction house the book "
      .. "docks on automatically while you browse or sell, and the sell helper ranks "
      .. "everything in your bags by % over Fair - best sale first.",
    where = "Charts tab  \226\128\186  offer book   \194\183   AH sell tab  \226\128\186  bottom edge",
    preview = "offerbook",
    open = function()
      M.EnsureUI()
      M.frame:Show()
      M.SelectTab(TAB.Charts)
      local key = demoItem()
      if key then
        M.SetChartKey(key); M.RefreshCharts()
        if M.ShowDepth then M.ShowDepth(key) end
      end
    end,
  },
  { threshold = 50, kicker = "MIDAS \194\183 MILESTONE \194\183 SCAN DAY 50",
    title = "Fifty scan days - read your ledger",
    text = "A real trader checks the books. Collect your auction mail and the Trades "
      .. "tab writes the ledger itself: net P/L, holdings change, fees - the band "
      .. "answers the only question that matters: are you actually up? Check it weekly "
      .. "and double down on what works. Stuck, or curious what others flip? "
      .. "\"/midas discord\" opens the community.",
    where = "Trades tab   \194\183   /midas discord",
    preview = "trades",
    open = function() M.EnsureUI(); M.frame:Show(); M.SelectTab(TAB.Trades) end,
  },
}

-- show one onboarding card (shared frame with news/guide: last caller wins)
function M.ShowOnboard(idx)
  local e = OB_STAGES[idx]
  if not (e and M.db and M.db.config) then return end
  if InCombatLockdown and InCombatLockdown() then
    C_Timer.After(10, function() M.ShowOnboard(idx) end)
    return
  end
  -- one-shot: marked before it shows (like newsSeen), and never backwards -
  -- a combat retry must not undo a higher card shown in the meantime
  M.db.config.obStage = math.max(M.db.config.obStage or 0, idx)
  newsFrame = newsFrame or buildNewsFrame()
  local f = newsFrame
  f._list, f._idx = { e }, 1
  renderNews(f)
  f:Show()
end

-- Data.lua calls this on each NEW scan day: at most ONE card per call,
-- always the highest threshold the day counter has reached beyond obStage
function M.OnboardScan()
  if not (M.db and M.db.config) then return end
  local done = M.db.config.obStage or 99
  if done >= #OB_STAGES then return end
  local n = M.db.config.scanDays or 0
  for i = #OB_STAGES, done + 1, -1 do
    if n >= OB_STAGES[i].threshold then
      M.ShowOnboard(i)
      return
    end
  end
end
