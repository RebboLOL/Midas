-- Midas – Theme: design tokens + flat UI component factory (2026 reskin)
-- One source of truth for colors, fonts and reusable widgets. Everything visual
-- (window, tabs, cards, rows, inputs, tooltip, minimap) is built from here.
local ADDON, M = ...
local T = {}
M.Theme = T

local WHITE = "Interface\\Buttons\\WHITE8X8"

-- ---- Fonts (bundled Inter, graceful fallback to a built-in font) -----------
local FONT_DIR = "Interface\\AddOns\\Midas\\Fonts\\"
local probe = UIParent:CreateFontString(nil, "BACKGROUND")
local function norm(s) return s and s:lower():gsub("/", "\\") or "" end
local function loadable(path)
  probe:SetFont(path, 12, "")
  return norm(probe:GetFont()) == norm(path)
end
local function fontOr(file, fallback)
  local p = FONT_DIR .. file
  if loadable(p) then return p end
  return fallback
end
T.FONT      = fontOr("Inter-Regular.ttf",  "Fonts\\ARIALN.TTF")
T.FONT_MED  = fontOr("Inter-Medium.ttf",   T.FONT)
T.FONT_SEMI = fontOr("Inter-SemiBold.ttf", T.FONT_MED)

-- ---- Color tokens (r, g, b [, a], range 0..1) ------------------------------
-- The Midas gold theme: everything the addon touches turns to gold. Warm, dark
-- treasury backgrounds, gold hairlines, and the price/value lines themselves in
-- gold ("teal" keeps its token name for compatibility but IS the Midas gold).
-- Cool blue is the counterweight for secondary statistics (floor MA, trimmed
-- days); green/red/purple keep their buy/sell/Fair semantics untouched.
T.C = {
  bg0      = { 0.070, 0.061, 0.045 }, -- app background (dark treasury)
  bg1      = { 0.096, 0.084, 0.061 }, -- card / panel
  bg2      = { 0.126, 0.110, 0.078 }, -- header / hover / button
  border   = { 0.27,  0.22,  0.13  }, -- gold hairline
  borderlt = { 0.45,  0.37,  0.20  }, -- brighter gold edge / scrollthumb
  accent   = { 0.91,  0.70,  0.29  }, -- gold brand / active / score
  green    = { 0.36,  0.82,  0.47  }, -- buy / cheap
  red      = { 0.94,  0.39,  0.35  }, -- sell / expensive
  blue     = { 0.44,  0.64,  0.92  }, -- cool contrast: floor MA, trimmed days, Gear class
  teal     = { 0.99,  0.80,  0.38  }, -- the Midas touch: price & value lines in gold
  mint     = { 0.20,  0.88,  0.74  }, -- Crafting asset class (the old teal)
  purple   = { 0.62,  0.55,  0.98  }, -- gold tied up in active auctions
  text     = { 0.93,  0.90,  0.84  }, -- primary text (warm ivory)
  sub      = { 0.63,  0.59,  0.50  }, -- secondary text / labels
  muted    = { 0.40,  0.37,  0.30  }, -- tertiary / hints
}
T.SIZE = { h1 = 16, h2 = 12, body = 12, small = 11, tiny = 10 }

-- flat backdrop: solid fill + 1px solid border (set colors via SetBackdrop*)
T.FLAT = {
  bgFile = WHITE, edgeFile = WHITE, tile = false, edgeSize = 1,
  insets = { left = 1, right = 1, top = 1, bottom = 1 },
}

local function u(c) return c[1], c[2], c[3], c[4] or 1 end
T.Unpack = u

-- ---- Fonts on font strings --------------------------------------------------
-- (The window resizes for real instead of scaling, so text simply keeps its
-- requested size - the old scale-compensating font registry is gone.)
function T.RegFont(fs, font, size)
  fs:SetFont(font, size, "")
end

-- ---- Text ------------------------------------------------------------------
function T.Text(parent, size, colorKey, variant)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  T.RegFont(fs, variant or T.FONT, size or T.SIZE.body)
  fs:SetWordWrap(false)
  if colorKey then fs:SetTextColor(u(T.C[colorKey])) end
  return fs
end

-- ---- Flat surface / card ---------------------------------------------------
function T.Surface(parent, fillKey, borderKey)
  local fr = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  fr:SetBackdrop(T.FLAT)
  fr:SetBackdropColor(u(T.C[fillKey or "bg1"]))
  fr:SetBackdropBorderColor(u(T.C[borderKey or "border"]))
  return fr
end

-- ---- Borderless filled frame (soft panel, no hard outline) -----------------
function T.Fill(parent, fillKey)
  local fr = CreateFrame("Frame", nil, parent)
  local bg = fr:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(); bg:SetColorTexture(u(T.C[fillKey or "bg1"]))
  fr.bg = bg
  return fr
end

-- ---- Flat button -----------------------------------------------------------
function T.Button(parent, text, w, h)
  local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
  b:SetSize(w or 100, h or 22)
  b:SetBackdrop(T.FLAT)
  b:SetBackdropColor(u(T.C.bg2))
  b:SetBackdropBorderColor(u(T.C.border))
  local fs = b:CreateFontString(nil, "OVERLAY")
  T.RegFont(fs, T.FONT_MED, T.SIZE.body); fs:SetPoint("CENTER", 0, 0)
  fs:SetTextColor(u(T.C.text)); fs:SetText(text or "")
  b.text = fs
  b:SetScript("OnEnter", function(self)
    self:SetBackdropColor(0.19, 0.165, 0.115, 1)
    self:SetBackdropBorderColor(u(T.C.accent))
    fs:SetTextColor(u(T.C.accent))
  end)
  b:SetScript("OnLeave", function(self)
    self:SetBackdropColor(u(T.C.bg2))
    self:SetBackdropBorderColor(u(T.C.border))
    fs:SetTextColor(u(T.C.text))
  end)
  return b
end

-- ---- Flat checkbox ---------------------------------------------------------
function T.Checkbox(parent, label, onToggle)
  local b = CreateFrame("Button", nil, parent)
  local box = CreateFrame("Frame", nil, b, "BackdropTemplate")
  box:SetSize(15, 15); box:SetPoint("LEFT", 0, 0)
  box:SetBackdrop(T.FLAT); box:SetBackdropColor(u(T.C.bg0)); box:SetBackdropBorderColor(u(T.C.borderlt))
  local check = box:CreateTexture(nil, "OVERLAY")
  check:SetColorTexture(u(T.C.accent)); check:SetSize(7, 7); check:SetPoint("CENTER"); check:Hide()
  local fs = b:CreateFontString(nil, "OVERLAY")
  T.RegFont(fs, T.FONT, T.SIZE.body); fs:SetPoint("LEFT", box, "RIGHT", 6, 0)
  fs:SetText(label or ""); fs:SetTextColor(u(T.C.sub))
  b:SetSize(23 + math.floor(fs:GetStringWidth() + 0.5), 18)
  b.checked = false
  function b:SetChecked(v)
    self.checked = v and true or false
    check:SetShown(self.checked)
    if self.checked then fs:SetTextColor(u(T.C.text)) else fs:SetTextColor(u(T.C.sub)) end
  end
  b:SetScript("OnClick", function(self)
    self:SetChecked(not self.checked)
    if onToggle then onToggle(self.checked) end
  end)
  b:SetScript("OnEnter", function() box:SetBackdropBorderColor(u(T.C.accent)) end)
  b:SetScript("OnLeave", function() box:SetBackdropBorderColor(u(T.C.borderlt)) end)
  return b
end

-- ---- Segmented toggle (the active option is highlighted) -------------------
function T.Segment(parent, options, onSelect)
  local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  frame:SetBackdrop(T.FLAT); frame:SetBackdropColor(u(T.C.bg0)); frame:SetBackdropBorderColor(u(T.C.border))
  local seg = { frame = frame, buttons = {}, current = nil }
  local x, h = 2, 20
  for i, opt in ipairs(options) do
    local b = CreateFrame("Button", nil, frame)
    local fs = b:CreateFontString(nil, "OVERLAY")
    T.RegFont(fs, T.FONT_MED, T.SIZE.small); fs:SetPoint("CENTER", 0, 0); fs:SetText(opt.label)
    local w = math.floor(fs:GetStringWidth() + 0.5) + 18
    b:SetSize(w, h); b:SetPoint("LEFT", x, 0)
    local bg = b:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints()
    bg:SetColorTexture(T.C.accent[1], T.C.accent[2], T.C.accent[3], 0.22); bg:Hide()
    b.fs, b.bg, b.key = fs, bg, opt.key
    b:SetScript("OnClick", function() seg:Select(opt.key); if onSelect then onSelect(opt.key) end end)
    b:SetScript("OnEnter", function() if seg.current ~= opt.key then fs:SetTextColor(u(T.C.text)) end end)
    b:SetScript("OnLeave", function() if seg.current ~= opt.key then fs:SetTextColor(u(T.C.sub)) end end)
    seg.buttons[i] = b
    x = x + w
  end
  frame:SetSize(x + 2, h + 4)
  function seg:Select(key)
    self.current = key
    for _, b in ipairs(self.buttons) do
      if b.key == key then b.bg:Show(); b.fs:SetTextColor(u(T.C.accent))
      else b.bg:Hide(); b.fs:SetTextColor(u(T.C.sub)) end
    end
  end
  return seg
end

-- ---- Close (x) glyph -------------------------------------------------------
function T.Close(parent)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(24, 24)
  local fs = b:CreateFontString(nil, "OVERLAY")
  T.RegFont(fs, T.FONT_MED, 17); fs:SetPoint("CENTER", 0, 0)
  fs:SetText("\195\151") -- multiplication sign as a clean close glyph
  fs:SetTextColor(u(T.C.sub))
  b.text = fs
  b:SetScript("OnEnter", function() fs:SetTextColor(u(T.C.red)) end)
  b:SetScript("OnLeave", function() fs:SetTextColor(u(T.C.sub)) end)
  return b
end

-- ---- Divider (1px line); caller sets the two end points --------------------
function T.Divider(parent, colorKey)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetColorTexture(u(T.C[colorKey or "border"]))
  t:SetHeight(1)
  return t
end

-- ---- Tab bar (underline marks the active tab) ------------------------------
function T.TabBar(parent, labels, onSelect)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetHeight(28)
  local bar = { frame = frame, buttons = {}, current = 1 }
  local x = 0
  for i, label in ipairs(labels) do
    local b = CreateFrame("Button", nil, frame)
    local fs = b:CreateFontString(nil, "OVERLAY")
    T.RegFont(fs, T.FONT_MED, 13); fs:SetPoint("CENTER", 0, 1); fs:SetText(label)
    local tw = math.floor(fs:GetStringWidth() + 0.5) + 22
    b:SetSize(tw, 28); b:SetPoint("LEFT", x, 0)
    local ul = b:CreateTexture(nil, "OVERLAY")
    ul:SetColorTexture(u(T.C.accent)); ul:SetHeight(2)
    ul:SetPoint("BOTTOMLEFT", 5, 2); ul:SetPoint("BOTTOMRIGHT", -5, 2); ul:Hide()
    b.fs, b.ul = fs, ul
    b:SetScript("OnClick", function() onSelect(i) end)
    b:SetScript("OnEnter", function() if not b.active then fs:SetTextColor(u(T.C.text)) end end)
    b:SetScript("OnLeave", function() if not b.active then fs:SetTextColor(u(T.C.sub)) end end)
    bar.buttons[i] = b
    x = x + tw + 8
  end
  frame:SetWidth(math.max(x - 8, 1))
  function bar:Select(i)
    self.current = i
    for j, b in ipairs(self.buttons) do
      b.active = (j == i)
      if b.active then b.fs:SetTextColor(u(T.C.text)); b.ul:Show()
      else b.fs:SetTextColor(u(T.C.sub)); b.ul:Hide() end
    end
  end
  bar:Select(1)
  return bar
end

-- ---- Search input (icon + placeholder, flat) -------------------------------
function T.Input(parent, w, h, placeholder, onChanged)
  local box = T.Surface(parent, "bg0", "border")
  box:SetSize(w or 220, h or 22)
  local icon = box:CreateTexture(nil, "OVERLAY")
  icon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
  icon:SetSize(14, 14); icon:SetPoint("LEFT", 7, -1)
  icon:SetVertexColor(0.60, 0.63, 0.70)
  local edit = CreateFrame("EditBox", nil, box)
  edit:SetPoint("LEFT", icon, "RIGHT", 6, 1); edit:SetPoint("RIGHT", -22, 0)
  edit:SetHeight((h or 22) - 2)
  T.RegFont(edit, T.FONT, T.SIZE.body); edit:SetTextColor(u(T.C.text))
  edit:SetAutoFocus(false)
  local ph = box:CreateFontString(nil, "OVERLAY")
  T.RegFont(ph, T.FONT, T.SIZE.body); ph:SetPoint("LEFT", edit, "LEFT", 1, 0)
  ph:SetTextColor(u(T.C.muted)); ph:SetText(placeholder or "")
  -- clear (x) button, shown only while there is text
  local clear = CreateFrame("Button", nil, box)
  clear:SetSize(16, (h or 22) - 4); clear:SetPoint("RIGHT", -4, 0)
  local cx = clear:CreateFontString(nil, "OVERLAY")
  T.RegFont(cx, T.FONT_MED, 13); cx:SetPoint("CENTER", 0, 0)
  cx:SetText("\195\151"); cx:SetTextColor(u(T.C.muted))
  clear:Hide()
  clear:SetScript("OnEnter", function() cx:SetTextColor(u(T.C.red)) end)
  clear:SetScript("OnLeave", function() cx:SetTextColor(u(T.C.muted)) end)
  clear:SetScript("OnClick", function() edit:SetText("") end)
  box.clear = clear
  edit:SetScript("OnTextChanged", function(self)
    local txt = self:GetText() or ""
    ph:SetShown(txt == "")
    clear:SetShown(txt ~= "")
    if onChanged then onChanged(txt) end
  end)
  edit:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
  edit:SetScript("OnEditFocusGained", function() box:SetBackdropBorderColor(u(T.C.accent)) end)
  edit:SetScript("OnEditFocusLost", function() box:SetBackdropBorderColor(u(T.C.border)) end)
  box.edit = edit
  return box
end

-- ---- Slim down a FauxScrollFrame scrollbar ---------------------------------
function T.StyleScrollbar(scrollName)
  local sb = _G[scrollName .. "ScrollBar"]
  if not sb then return end
  local up   = _G[scrollName .. "ScrollBarScrollUpButton"]
  local down = _G[scrollName .. "ScrollBarScrollDownButton"]
  if up   then up:SetAlpha(0);   up:EnableMouse(false)   end
  if down then down:SetAlpha(0); down:EnableMouse(false) end
  local thumb = sb.GetThumbTexture and sb:GetThumbTexture()
  if thumb then thumb:SetColorTexture(u(T.C.borderlt)); thumb:SetWidth(6) end
  sb:SetWidth(8)
end

-- ---- Methodology help tooltip ----------------------------------------------
-- Wire an explanatory GameTooltip onto any frame/button so users can see HOW a
-- number is derived: T.HelpTip(frame, "Title", { "line one", "line two" }).
-- Each entry in `lines` is a whole PARAGRAPH (no hand-placed breaks): the tooltip
-- wraps it at a fixed minimum width, so the text reads as clean flowing blocks.
-- An empty string renders as a paragraph spacer.
function T.HelpTip(owner, title, lines, anchor)
  if not (owner and owner.HookScript) then return owner end
  if owner.EnableMouse then owner:EnableMouse(true) end
  owner:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
    GameTooltip:SetMinimumWidth(300)
    GameTooltip:AddLine(title or "", u(T.C.accent))
    for _, ln in ipairs(lines or {}) do
      if ln == "" then
        GameTooltip:AddLine(" ")                     -- explicit paragraph spacer
      else
        GameTooltip:AddLine(ln, T.C.sub[1], T.C.sub[2], T.C.sub[3], true) -- wrap
      end
    end
    GameTooltip:Show()
  end)
  owner:HookScript("OnLeave", function()
    GameTooltip:SetMinimumWidth(0)
    GameTooltip:Hide()
  end)
  return owner
end

-- Shared copy for the price-method tooltips (one source of truth, reused by UI).
T.HELP = {
  fair = { "Fair price", {
    "What the item is really worth right now: the average of the cheapest daily prices over the last 14 days, where recent days count more. Days on which only overpriced stock was listed are ignored - such asks sit in the AH without demand and must not inflate the value.",
    "",
    "When your own sales prove that buyers pay more, Fair is lifted by up to 10%, based on your real sold-vs-expired history (aiming for ~50% odds that one 48h auction sells) - but never beyond what your sales actually cleared at. It is never pushed below the market level: if the odds stay low even at Fair, the item is oversupplied - post fewer, don't price lower." } },
  vsfair = { "vs Fair", {
    "Current lowest price vs the Fair price. Green = cheap (below Fair), red = expensive (above), grey = within +/-10%." } },
  liq = { "Liquidity / sell speed", {
    "How fast the item moves, from market supply and your own sell rate. Rule of thumb: don't post more than ~N/day or auctions expire - low sell-through is usually oversupply, not price." } },
  quick = { "Quick-sell", {
    "At or just below the current floor: sells fast (near-certain odds) at the cost of margin. For when you want gold now." } },
  rating = { "Sell rating", {
    "Share of your auctions that sold vs. expired (last 60 days)." } },
  odds = { "Sell odds", {
    "Estimated chance that one 48-hour listing sells at that price, learned from your real sold-vs-expired history plus market-wide calibration.",
    "",
    "Fair aims for ~50% odds where the market supports it; for oversupplied items Fair stays at the market level and these odds tell you the honest chance." } },
  current = { "Current price", {
    "The cheapest buyout in the newest scan - what the item costs right now." } },
  ma = { "Floor MA", {
    "The moving average of the daily CHEAPEST buyouts (the floor) over a trailing 20-day window.",
    "It is a floor statistic: sales clear at and above it, so Fair may legitimately sit slightly higher when your sales prove buyers pay more." } },
  score = { "Opportunity score", {
    "score = margin x liquidity x confidence.",
    "margin: the 25th-to-75th-percentile flip spread, capped at 150%. liquidity: average market quantity / 20, capped at 1. confidence: grows with days of data, full at 10.",
    "Higher = a bigger, more dependable flip." } },
  sellthrough = { "Sell-through", {
    "sold / (sold + returned) of your own auctions over the last 60 days - the measured share of posted auctions that actually sold." } },
}

-- One entry as flowing text (paragraphs joined by blank lines) for tooltips
-- that take a single string instead of a line table.
function T.HelpText(key)
  local e = T.HELP[key]
  if not e then return "" end
  local out = {}
  for _, l in ipairs(e[2]) do if l ~= "" then out[#out + 1] = l end end
  return table.concat(out, "\n\n")
end
