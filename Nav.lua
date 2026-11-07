-- Midas – Navigation: every item links to every page Midas has for it.
-- One table names the pages an item can open (chart, craft tree, offer book,
-- your trades, your stock) and M.Go reaches each of them from anywhere. A jump
-- to another tab leaves a Back pill in the window header that returns to the
-- exact place you came from. M.LinkBar draws an item's pages as chips on the
-- detail views, M.ItemMenu lists them on right-click wherever an item is shown.
local ADDON, M = ...
local T = M.Theme
local C = T.C
local floor, max, min = math.floor, math.max, math.min

local DOT = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
local SEP = "  \194\183  "

local function hexc(c) return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255) end
local MUTH, SUBH = hexc(C.muted), hexc(C.sub)

local function baseId(key)
  if key == nil then return nil end
  return (M.BaseID and M.BaseID(key)) or tonumber(key)
end

-- ===== The pages of an item =================================================
-- label = chip and menu text, short = narrow cards, color = theme token
local DEST = {
  chart   = { label = "Chart",       short = "Chart",  color = "accent",
              tip = "Price history with Current, Fair and the signal, your own trades as dots and the price alert limits." },
  tree    = { label = "Craft tree",  short = "Tree",   color = "mint",
              tip = "The Crafting tab: what it costs to make, every material down to the raw goods, bought or made, now and at Fair." },
  book    = { label = "Offer book",  short = "Book",   color = "blue",
              tip = "Every price it is listed at in your newest full scan, cheapest first, with the supply up to each price." },
  trades  = { label = "Your trades", short = "Trades", color = "green",
              tip = "The Trades tab, By Item, filtered to this item: every sale, return and purchase with its price." },
  holding = { label = "Your stock",  short = "Stock",  color = "purple",
              tip = "Net Worth: what your stock of this item was worth day by day, with what you paid for it." },
}
local ORDER = { "chart", "tree", "book", "trades", "holding" }
M.LINK_DEST, M.LINK_ORDER = DEST, ORDER

-- ===== What exists for an item ==============================================
-- Units held by your characters of this realm + faction: bags, bank, mail and
-- your own auctions (the same scope as Net Worth, fallen characters excluded).
function M.OwnedBy(id)
  id = tonumber(id)
  local list, total = {}, 0
  if not (id and M.db and M.db.chars) then return list, 0 end
  for ck, c in pairs(M.db.chars) do
    if not c.dead and (not M.CharInScope or M.CharInScope(c)) then
      local q = ((c.bags and c.bags[id]) or 0) + ((c.bank and c.bank[id]) or 0) + ((c.mail and c.mail[id]) or 0)
      local a = c.auctions and c.auctions[id]
      if a then q = q + (a.qty or 0) end
      if q > 0 then
        list[#list + 1] = { ck = ck, name = c.name or ck:match("^(.-)%-") or ck, qty = q }
        total = total + q
      end
    end
  end
  table.sort(list, function(a, b) return a.qty > b.qty end)
  return list, total
end

function M.OwnedQty(id)
  local _, total = M.OwnedBy(id)
  return total
end

-- the item's By-Item entry in the Trades tab (same window as that table)
local function tradeEntry(id)
  if not (id and M.TradeStats) then return nil end
  local stats = M.TradeStats()
  if not stats then return nil end
  local k = M.TradeKeyForID and M.TradeKeyForID(id)
  if k and stats[k] then return stats[k], k end
  for k2, s in pairs(stats) do
    if s.id and tonumber(s.id) == id then return s, k2 end
  end
  return nil
end
M.TradeEntryForID = tradeEntry

-- { chart = {}, tree = {...}, book = {...}, trades = {...}, holding = {...} }:
-- only the pages that have something to show for this item
function M.ItemLinkInfo(key)
  local info = {}
  if key == nil then return info end
  key = tostring(key)
  info.chart = {}
  local id = baseId(key)
  if not id then return info end
  local Rx = M.Recipes and (not M.CraftingOn or M.CraftingOn()) and M.Recipes()
  if Rx then
    if Rx.byItem[id] then
      info.tree = { make = true }
    elseif Rx.usedIn[id] then
      local seen, n = {}, 0
      for _, rec in ipairs(Rx.usedIn[id]) do
        if not seen[rec.item] then seen[rec.item] = true; n = n + 1 end
      end
      info.tree = { uses = n, extra = "used in " .. n }
    end
  end
  local d = M.GetDepth and M.GetDepth(id)
  if d and d.levels and d.levels[1] then
    info.book = { d = d, extra = tostring(d.listed or d.units or "") }
  end
  local s, sk = tradeEntry(id)
  if s and ((s.soldStacks or 0) + (s.retStacks or 0) + (s.boughtUnits or 0)) > 0 then
    local extra
    if (s.soldStacks or 0) > 0 then extra = s.soldStacks .. " sold"
    elseif (s.boughtUnits or 0) > 0 then extra = "bought" end
    info.trades = { s = s, key = sk, extra = extra }
  end
  local owners, q = M.OwnedBy(id)
  if q > 0 then info.holding = { qty = q, owners = owners, extra = "\195\151" .. q } end
  return info
end

-- ===== Where you are, and the way back ======================================
-- A place = the tab plus what it shows (item, sub-view, drill-down). M.Go
-- remembers the place it leaves; the Back pill in the header restores it.
local stack = {}
local MAX_STACK = 12

local function capture()
  local TAB, t = M.TAB, M.curTab
  if not (TAB and t) then return nil end
  local s = { tab = t }
  if t == TAB.Charts then
    s.key = M.chartKey
    if M.depthView and M.depthView:IsShown() then s.sub = "book"
    elseif M.whyView and M.whyView:IsShown() then s.sub = "why" end
  elseif t == TAB.Crafting then
    local id = M.craftUI and M.craftUI.id
    s.key = id and tostring(id) or nil
  elseif t == TAB.Trades then
    local ts = M.TradesState and M.TradesState()
    if ts then s.view, s.search, s.expanded = ts.view, ts.search, ts.expanded end
  elseif t == TAB["Net Worth"] then
    local w = M.wealth
    if w then
      if w.itemWorth and w.itemWorth:IsShown() then
        s.sub, s.key, s.qty, s.src = "holding", w.itemWorth.key, w.itemWorth.qty, w.itemWorth.srcLabel
      elseif w.itemView and w.itemView:IsShown() then
        s.sub, s.ck, s.cls = "char", w.itemView.charKey, w.itemView.clsFilter
      elseif w.classView and w.classView:IsShown() then
        s.sub, s.cls, s.day = "class", w.classView.cls, w.classView.day
      elseif w.dayView and w.dayView:IsShown() then
        s.sub, s.day = "day", w.dayView.day
      elseif w.moversView and w.moversView:IsShown() then
        s.sub, s.day = "movers", w.moversView.refDayOverride
      end
    end
  elseif t == TAB.Ledger then
    local lg = M.ledgerUI
    s.focus = lg and lg.focus or nil
  end
  return s
end
M.NavCapture = capture

local function same(a, b)
  if not (a and b) then return false end
  return a.tab == b.tab and a.key == b.key and a.sub == b.sub and a.ck == b.ck
    and a.cls == b.cls and a.view == b.view and a.search == b.search and a.focus == b.focus
end

local function charName(ck)
  local c = ck and M.db and M.db.chars and M.db.chars[ck]
  return (c and c.name) or (ck and (ck:match("^(.-)%-") or ck)) or "?"
end

-- "Trades", "Thorium Bar" -- what the Back pill names
local function placeName(s)
  local TAB = M.TAB or {}
  local name = (M.TABS and M.TABS[s.tab]) or "Midas"
  if s.tab == TAB.Charts and s.sub == "book" then name = "Offer book"
  elseif s.tab == TAB["Net Worth"] and s.sub == "holding" then name = "Your stock" end
  local what
  if s.key then what = M.ItemName(s.key)
  elseif s.ck then what = charName(s.ck)
  elseif s.cls then what = s.cls
  elseif s.focus and s.focus.label then what = s.focus.label
  elseif s.search and s.search ~= "" then what = "\"" .. s.search .. "\"" end
  return name, what
end
M.NavPlaceName = placeName

local function restore(s)
  local TAB = M.TAB
  if s.tab == TAB.Charts then
    if s.key then M.chartKey = s.key end     -- no re-sort of the recently-viewed list
    M.SelectTab(TAB.Charts)
    if s.sub == "book" and s.key and M.ShowDepth then M.ShowDepth(s.key)
    elseif s.sub == "why" and s.key and M.ShowWhy then M.ShowWhy(s.key) end
  elseif s.tab == TAB.Crafting then
    if M.CraftOpen then M.CraftOpen(s.key and tonumber(s.key), true) else M.SelectTab(TAB.Crafting) end
  elseif s.tab == TAB.Trades then
    if M.TradesRestore then M.TradesRestore(s.view, s.search, s.expanded) end
    M.SelectTab(TAB.Trades)
  elseif s.tab == TAB["Net Worth"] then
    M.SelectTab(s.tab)
    if s.sub == "holding" and s.key and M.ShowItemWorth then M.ShowItemWorth(s.key, s.qty or 0, s.src)
    elseif s.sub == "char" and s.ck and M.ShowCharItems then M.ShowCharItems(s.ck, s.cls)
    elseif s.sub == "class" and s.cls and M.ShowWorthClass then M.ShowWorthClass(s.cls, s.day)
    elseif s.sub == "day" and s.day and M.ShowWorthDay then M.ShowWorthDay(s.day)
    elseif s.sub == "movers" and M.ShowMovers then M.ShowMovers(s.day) end
  elseif s.tab == TAB.Ledger then
    if M.ledgerUI then M.ledgerUI.focus = s.focus end
    M.SelectTab(TAB.Ledger)
  else
    M.SelectTab(s.tab)
  end
end

function M.NavDepth() return #stack end

function M.NavClear()
  for i = #stack, 1, -1 do stack[i] = nil end
  if M.UpdateNavPill then M.UpdateNavPill() end
end

function M.NavBack()
  local s = table.remove(stack)
  if M.HideItemMenu then M.HideItemMenu() end
  if s then restore(s) end
  M.UpdateNavPill()
end

-- open one page of an item; false = nothing to open
local function openDest(dest, key, arg)
  local TAB = M.TAB
  local id = baseId(key)
  if dest == "chart" then
    if not key then return false end
    M.SetChartKey(key); M.SelectTab(TAB.Charts)
  elseif dest == "book" or dest == "why" then
    if not key then return false end
    M.SetChartKey(key); M.SelectTab(TAB.Charts)
    if dest == "book" and M.ShowDepth then M.ShowDepth(key)
    elseif dest == "why" and M.ShowWhy then M.ShowWhy(key) end
  elseif dest == "tree" then
    if not (id and M.ShowCraftTree) then return false end
    M.ShowCraftTree(id)
  elseif dest == "trades" then
    if not key then return false end
    if M.TradesFocus then M.TradesFocus(key) end
    M.SelectTab(TAB.Trades)
  elseif dest == "holding" then
    if not (key and M.ShowItemWorth) then return false end
    M.SelectTab(TAB["Net Worth"])
    M.ShowItemWorth(key, arg or (id and M.OwnedQty(id)) or 0)
  elseif dest == "char" then
    if not (key and M.ShowCharItems) then return false end
    M.SelectTab(TAB["Net Worth"])
    M.ShowCharItems(key, arg)
  elseif dest == "tab" then
    local i = tonumber(key)
    if not i then return false end
    M.SelectTab(i)
  elseif dest == "movers" then
    -- Net Worth "what moved", measured from the given snapshot day
    if not M.ShowMovers then return false end
    M.SelectTab(TAB["Net Worth"])
    M.ShowMovers(tonumber(key))
  elseif dest == "alerts" then
    if not M.OpenAlerts then return false end
    M.OpenAlerts()
  else
    return false
  end
  return true
end

-- The one way to jump: M.Go("tree", "12360"), M.Go("holding", key),
-- M.Go("char", charKey), M.Go("tab", M.TAB.Ledger). Leaving a place inside
-- the open window remembers it for the Back pill.
function M.Go(dest, key, arg)
  if not dest then return end
  if key ~= nil then key = tostring(key) end
  M.EnsureUI()
  local from = M.frame:IsShown() and capture() or nil
  if M.HideItemMenu then M.HideItemMenu() end
  if M.HideCraftPeek then M.HideCraftPeek() end
  GameTooltip:Hide()
  M.frame:Show()
  if openDest(dest, key, arg) == false then return end
  if from and not same(from, capture()) then
    stack[#stack + 1] = from
    while #stack > MAX_STACK do table.remove(stack, 1) end
  end
  M.UpdateNavPill()
end

-- ===== The Back pill (window header) ========================================
local pill

function M.BuildNavPill(parent, anchor)
  if pill then return pill end
  pill = CreateFrame("Button", nil, parent, "BackdropTemplate")
  pill:SetHeight(22)
  pill:SetBackdrop(T.FLAT)
  pill.fs = T.Text(pill, T.SIZE.small, "text", T.FONT_MED)
  pill.fs:SetPoint("LEFT", 10, 0); pill.fs:SetJustifyH("LEFT")
  local function paint(hot)
    local a = C.accent
    pill:SetBackdropColor(a[1], a[2], a[3], hot and 0.24 or 0.12)
    pill:SetBackdropBorderColor(a[1], a[2], a[3], hot and 1 or 0.7)
  end
  paint(false)
  if anchor then pill:SetPoint("LEFT", anchor, "RIGHT", 18, 0) end
  pill:SetScript("OnClick", function() M.NavBack() end)
  pill:SetScript("OnEnter", function(self)
    paint(true)
    local top = stack[#stack]
    if not top then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    local n, w = placeName(top)
    GameTooltip:AddLine("Back to " .. n .. (w and (" \194\183 " .. w) or ""), C.accent[1], C.accent[2], C.accent[3])
    GameTooltip:AddLine("Returns to the page you came from, as you left it.", C.sub[1], C.sub[2], C.sub[3], true)
    if #stack > 1 then
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("Further back", C.muted[1], C.muted[2], C.muted[3])
      for i = #stack - 1, max(1, #stack - 5), -1 do
        local n2, w2 = placeName(stack[i])
        GameTooltip:AddLine("   " .. n2 .. (w2 and (" \194\183 " .. w2) or ""), C.sub[1], C.sub[2], C.sub[3])
      end
    end
    GameTooltip:Show()
  end)
  pill:SetScript("OnLeave", function() paint(false); GameTooltip:Hide() end)
  pill:Hide()
  M.navPill = pill
  return pill
end

function M.UpdateNavPill()
  if not pill then return end
  local top = stack[#stack]
  if not top then pill:Hide(); return end
  local n, w = placeName(top)
  pill.fs:SetWidth(0)
  pill.fs:SetText("\226\128\185  Back to " .. n .. (w and (MUTH .. "  \194\183  " .. w .. "|r") or "")
    .. ((#stack > 1) and (MUTH .. "   (" .. #stack .. ")|r") or ""))
  local tw = min(360, (pill.fs:GetStringWidth() or 120))
  pill.fs:SetWidth(tw)
  pill:SetWidth(tw + 22)
  pill:Show()
end

-- ===== Chip hover: what the page holds for this item ========================
local function addKV(l, r, lc, rc)
  lc, rc = lc or C.sub, rc or C.text
  GameTooltip:AddDoubleLine(l, r, lc[1], lc[2], lc[3], rc[1], rc[2], rc[3])
end

local function linkTip(chip)
  local d, key, info = chip.dest, chip.key, chip.info or {}
  if not (d and key) then return end
  -- the craft tree previews itself
  if d == "tree" and info.make and M.CraftPeek then
    if M.CraftPeek(chip, baseId(key)) then return end
  end
  GameTooltip:SetOwner(chip, "ANCHOR_BOTTOM")
  GameTooltip:SetMinimumWidth(260)
  if d == "watch" then
    local on = M.IsWatched and M.IsWatched(key)
    GameTooltip:AddLine("Watchlist", C.accent[1], C.accent[2], C.accent[3])
    GameTooltip:AddLine(on and "On your watchlist - click to remove it."
      or "Click to watch it: the Start page and the Watchlist tab show its buy and sell signal.",
      C.sub[1], C.sub[2], C.sub[3], true)
  else
    local def = DEST[d]
    local col = C[def.color] or C.accent
    GameTooltip:AddLine(def.label, col[1], col[2], col[3])
    if d == "tree" and info.uses then
      GameTooltip:AddLine("Used in " .. info.uses .. ((info.uses == 1) and " recipe" or " recipes")
        .. " - the Crafting tab lists them with the profit of each.", C.sub[1], C.sub[2], C.sub[3], true)
    else
      GameTooltip:AddLine(def.tip, C.sub[1], C.sub[2], C.sub[3], true)
    end
    if d == "book" and info.d then
      local ago = max(0, time() - (info.d.ts or time()))
      local agoTxt = (ago < 3600) and string.format("%d min ago", floor(ago / 60))
        or (ago < 86400) and string.format("%.1f h ago", ago / 3600)
        or string.format("%d d ago", floor(ago / 86400))
      GameTooltip:AddLine(" ")
      addKV("Listed", tostring(info.d.listed or info.d.units or "?"))
      addKV("Scanned", agoTxt)
    elseif d == "trades" and info.s then
      local s = info.s
      GameTooltip:AddLine(" ")
      addKV("Sold", tostring(s.soldStacks or 0), C.sub, C.green)
      addKV("Returned", tostring(s.retStacks or 0))
      local net = s.net or 0
      addKV("Net", ((net >= 0) and "+" or "-") .. M.MoneyPlain(math.abs(net)), C.sub, (net >= 0) and C.green or C.red)
    elseif d == "holding" and info.owners then
      GameTooltip:AddLine(" ")
      for i = 1, min(6, #info.owners) do
        local o = info.owners[i]
        addKV(o.name, "x" .. o.qty)
      end
      local unit = M.ItemValue and M.ItemValue(baseId(key)) or 0
      if unit > 0 then addKV("Worth today", M.MoneyPlain(unit * (info.qty or 0)), C.sub, C.accent) end
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Right-click: every page of this item", C.muted[1], C.muted[2], C.muted[3])
  GameTooltip:Show()
end

-- ===== Link bar: an item's pages as chips ===================================
-- opts.except  = the page the bar sits on (left out)
-- opts.skip    = { dest = true } pages the host already offers another way
-- opts.short   = short labels (narrow cards)
-- opts.watch   = add the watchlist toggle
-- opts.maxW    = width budget; chips that do not fit are dropped (the
--                right-click menu still lists them) unless opts.wrap
-- opts.wrap    = wrap into further rows inside maxW (bar.h grows)
-- The caller anchors the bar; with a RIGHT anchor the chips grow leftwards.
local CHIP_H, GAP = 20, 6

function M.LinkBar(parent, opts)
  opts = opts or {}
  local bar = CreateFrame("Frame", nil, parent)
  bar:SetSize(1, CHIP_H)
  bar.chips, bar.opts, bar.h = {}, opts, CHIP_H

  local function chip(i)
    local c = bar.chips[i]
    if c then return c end
    c = T.Chip(bar, CHIP_H, opts.short)
    c:HookScript("OnEnter", linkTip)
    c:HookScript("OnLeave", function()
      GameTooltip:SetMinimumWidth(0)
      GameTooltip:Hide()
      if M.HideCraftPeek then M.HideCraftPeek() end
    end)
    c:SetScript("OnClick", function(self, button)
      if not self.key then return end
      if M.HideCraftPeek then M.HideCraftPeek() end
      if button == "RightButton" then M.ItemMenu(self.key); return end
      if self.dest == "watch" then
        local on = M.ToggleWatch(self.key)
        M.Print(M.ItemName(self.key) .. (on and " is on your watchlist now." or " left your watchlist."))
        bar:SetItem(self.key, bar.maxW)
        if M.RefreshUI then M.RefreshUI() end
        if self:IsMouseOver() then linkTip(self) end
        return
      end
      M.Go(self.dest, self.key)
    end)
    bar.chips[i] = c
    return c
  end

  -- re-label for `key`; maxW overrides opts.maxW (elastic hosts). Returns the
  -- width the chips take.
  function bar:SetItem(key, maxW)
    self.key = key and tostring(key) or nil
    self.maxW = maxW or opts.maxW
    for _, c in ipairs(self.chips) do c:Hide() end
    if not self.key then self:SetWidth(1); self.h = CHIP_H; self:SetHeight(CHIP_H); self:Hide(); return 0 end
    local info = M.ItemLinkInfo(self.key)
    local list = {}
    for _, d in ipairs(ORDER) do
      if d ~= opts.except and info[d] and not (opts.skip and opts.skip[d]) then list[#list + 1] = d end
    end
    if opts.watch then list[#list + 1] = "watch" end
    local x, y, rowW, n = 0, 0, 0, 0
    local limit = self.maxW
    for i, d in ipairs(list) do
      local c = chip(i)
      c.dest, c.key, c.info = d, self.key, info[d]
      local w
      if d == "watch" then
        local on = M.IsWatched and M.IsWatched(self.key)
        c.filled = on
        w = c:Set(on and "Watched" or "+ Watch", nil, "accent", true)
      else
        local def = DEST[d]
        c.filled = nil
        if opts.short then w = c:Set(def.short, nil, def.color)
        else w = c:Set(def.label, info[d].extra, def.color) end
      end
      if limit and ((x > 0) and (x + GAP + w) or w) > limit then
        if opts.wrap and x > 0 then
          y = y + CHIP_H + GAP     -- next row
          x = 0
        else
          break                    -- dropped: the item menu still lists it
        end
      end
      local cx = (x > 0) and (x + GAP) or 0
      c:ClearAllPoints()
      c:SetPoint("TOPLEFT", self, "TOPLEFT", cx, -y)
      c:Show()
      x = cx + w
      if x > rowW then rowW = x end
      n = n + 1
    end
    self.h = y + CHIP_H
    self:SetSize(max(1, rowW), self.h)
    self:SetShown(n > 0)
    return rowW
  end

  return bar
end

-- ===== Item menu (right-click) ==============================================
local menu
local MENU_W, ROW_H = 236, 22

local function buildMenu()
  if menu then return menu end
  menu = CreateFrame("Frame", "MidasItemMenu", UIParent, "BackdropTemplate")
  menu:SetFrameStrata("FULLSCREEN_DIALOG")
  menu:SetClampedToScreen(true)
  menu:EnableMouse(true)
  menu:SetBackdrop(T.FLAT)
  menu:SetBackdropColor(C.bg1[1], C.bg1[2], C.bg1[3], 0.98)
  menu:SetBackdropBorderColor(T.Unpack(C.borderlt))
  menu:SetWidth(MENU_W)
  menu.icon = menu:CreateTexture(nil, "ARTWORK")
  menu.icon:SetSize(18, 18); menu.icon:SetPoint("TOPLEFT", 9, -8)
  menu.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  menu.title = T.Text(menu, T.SIZE.body, "text", T.FONT_SEMI)
  menu.title:SetPoint("LEFT", menu.icon, "RIGHT", 7, 0)
  menu.title:SetWidth(MENU_W - 44); menu.title:SetJustifyH("LEFT")
  menu.rows, menu.seps = {}, {}
  -- not in UISpecialFrames: ESC closes every listed frame at once, so it
  -- would take the Midas window down with the menu. The window's OnHide,
  -- a tab switch, a click elsewhere or the cursor staying away close it.
  -- close when the cursor stays away, or on a click anywhere else
  menu:SetScript("OnUpdate", function(self, el)
    if self:IsMouseOver(12, -12, -12, 12) then self.away = 0
    else
      self.away = (self.away or 0) + (el or 0)
      if self.away > 2.5 then self:Hide() end
    end
  end)
  menu:SetScript("OnShow", function(self) self.away = 0 end)
  local ev = CreateFrame("Frame")
  if M.SafeRegister and M.SafeRegister(ev, "GLOBAL_MOUSE_DOWN") then
    ev:SetScript("OnEvent", function()
      if menu:IsShown() and not menu:IsMouseOver() then menu:Hide() end
    end)
  end
  menu:Hide()
  return menu
end

local function menuRow(i)
  local r = menu.rows[i]
  if r then return r end
  r = CreateFrame("Button", nil, menu)
  r:SetHeight(ROW_H)
  r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  r.hl = r:CreateTexture(nil, "BACKGROUND"); r.hl:SetAllPoints(); r.hl:SetColorTexture(1, 1, 1, 0.06); r.hl:Hide()
  r.dot = r:CreateTexture(nil, "OVERLAY"); r.dot:SetTexture(DOT); r.dot:SetSize(7, 7); r.dot:SetPoint("LEFT", 12, 0)
  r.l = T.Text(r, T.SIZE.small, "text", T.FONT_MED); r.l:SetPoint("LEFT", 26, 0); r.l:SetJustifyH("LEFT")
  r.x = T.Text(r, T.SIZE.tiny, "muted", T.FONT_MED); r.x:SetPoint("RIGHT", -24, 0); r.x:SetJustifyH("RIGHT")
  r.ar = T.Text(r, T.SIZE.body, nil, T.FONT_SEMI); r.ar:SetPoint("RIGHT", -10, 1); r.ar:SetText("\226\128\186")
  r:SetScript("OnEnter", function(self)
    self.hl:Show()
    local c = self.col or C.text
    self.l:SetTextColor(c[1], c[2], c[3])
  end)
  r:SetScript("OnLeave", function(self)
    self.hl:Hide()
    local c = self.base or C.text
    self.l:SetTextColor(c[1], c[2], c[3])
  end)
  r:SetScript("OnClick", function(self)
    local fn = self.fn
    menu:Hide()
    if fn then fn() end
  end)
  menu.rows[i] = r
  return r
end

local function menuSep(i)
  local s = menu.seps[i]
  if not s then
    s = menu:CreateTexture(nil, "ARTWORK")
    s:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.8)
    s:SetHeight(1)
    menu.seps[i] = s
  end
  s:Show()
  return s
end

function M.HideItemMenu()
  if menu then menu:Hide() end
end

-- the right-click answer for any item: its pages, then watch / post / search
function M.ItemMenu(key)
  if key == nil then return end
  key = tostring(key)
  local f = buildMenu()
  for _, r in ipairs(f.rows) do r:Hide() end
  for _, s in ipairs(f.seps) do s:Hide() end
  GameTooltip:Hide()
  if M.HideCraftPeek then M.HideCraftPeek() end
  local id = baseId(key)
  local qc = M.ItemQualityColor(key)
  f.title:SetText(M.ItemName(key)); f.title:SetTextColor(qc.r, qc.g, qc.b)
  f.icon:SetTexture((id and M.GetItemIcon and M.GetItemIcon(id)) or "Interface\\Icons\\INV_Misc_QuestionMark")
  f.key = key
  local info = M.ItemLinkInfo(key)
  local y, n, ns = 34, 0, 0
  local function sep()
    ns = ns + 1
    local s = menuSep(ns)
    s:ClearAllPoints()
    s:SetPoint("TOPLEFT", 8, -(y + 3)); s:SetPoint("TOPRIGHT", -8, -(y + 3))
    y = y + 7
  end
  local function row(label, extra, colorKey, fn, action)
    n = n + 1
    local r = menuRow(n)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 1, -y); r:SetPoint("TOPRIGHT", -1, -y)
    local col = C[colorKey or "accent"] or C.accent
    r.col = action and C.text or col
    r.base = action and C.sub or C.text
    r.l:SetText(label); r.l:SetTextColor(T.Unpack(r.base))
    r.x:SetText(extra or "")
    r.dot:SetVertexColor(col[1], col[2], col[3], action and 0 or 1)
    r.ar:SetShown(not action)
    r.ar:SetTextColor(col[1], col[2], col[3])
    r.fn = fn
    r:Show()
    y = y + ROW_H
  end
  sep()
  for _, d in ipairs(ORDER) do
    if info[d] then
      local def = DEST[d]
      local extra = info[d].extra
      if d == "tree" and info[d].make and M.CraftCost then
        local cc = M.CraftCost(id)
        if cc and cc.now then extra = "make " .. M.MoneyPlain(floor(cc.now + 0.5)) end
      end
      row(def.label, extra, def.color, function() M.Go(d, key) end)
    end
  end
  sep()
  local watched = M.IsWatched and M.IsWatched(key)
  row(watched and "Remove from watchlist" or "Add to watchlist", nil, "accent", function()
    local on = M.ToggleWatch(key)
    M.Print(M.ItemName(key) .. (on and " is on your watchlist now." or " left your watchlist."))
    if M.RefreshUI then M.RefreshUI() end
  end, true)
  if M.PostItemStats then
    row("Post price to chat", nil, nil, function() M.PostItemStats(key) end, true)
  end
  if M.AHOpen and M.ItemShiftAction then
    row("Search the auction house", nil, nil, function() M.ItemShiftAction(key) end, true)
  end
  f:SetHeight(y + 6)
  -- open under the cursor, the cursor resting on the title row
  local x, cy = GetCursorPosition()
  local sc = UIParent:GetEffectiveScale() or 1
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", (x or 0) / sc - 14, (cy or 0) / sc + 8)
  f:Show()
  return f
end
