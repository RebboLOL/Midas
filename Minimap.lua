-- Midas – Minimap: clean circular coin button with mouseover sell tips
local ADDON, M = ...
local T = M.Theme
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local btn

local function angleNow()
  local cfg = M.db and M.db.config
  return (cfg and cfg.minimapAngle) or 198
end

local function updatePos()
  if not (btn and Minimap) then return end
  local a = math.rad(angleNow())
  local r = (Minimap:GetWidth() * 0.5) + 6     -- just outside the minimap ring
  btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

-- ===== Tooltip content =======================================================
function M.FillSellTooltip(tip)
  tip:AddLine("|cffE8B44AMidas|r  \194\183  Top sells from your holdings")
  tip:AddLine("Bags \194\183 Bank \194\183 Mail", 0.78, 0.76, 0.70)
  tip:AddLine(" ")

  if not M.db then
    tip:AddLine("Not loaded yet ...", 0.94, 0.39, 0.35)
    return
  end

  local picks = M.BestSells(4)
  if #picks == 0 then
    tip:AddLine("Nothing above fair right now \194\183 better hold.", 0.91, 0.70, 0.29)
    tip:AddLine("(needs >=4 scan days per item)", 0.45, 0.48, 0.54)
  else
    for _, p in ipairs(picks) do
      local key = tostring(p.id)
      local qc  = M.ItemQualityColor(key)
      local right = string.format("+%.0f%%  %s", p.premium * 100, M.MoneyPlain(p.cur))
      tip:AddDoubleLine(M.ItemName(key) .. "  x" .. p.qty, right,
        qc.r, qc.g, qc.b, 0.36, 0.82, 0.47)
      local liq = p.liqLabel or "?"
      if p.speed then liq = string.format("~%.1f/day \194\183 %s", p.speed, p.liqLabel or "?") end
      tip:AddLine(string.format("   Fair %s \194\183 %s \194\183 %dd",
        M.MoneyPlain(p.fair), liq, p.days), 0.55, 0.58, 0.64)
    end
  end

  tip:AddLine(" ")
  if M.GoldTimerTipLine then M.GoldTimerTipLine(tip) end
  tip:AddDoubleLine("Left-click", "Open window", 0.50, 0.53, 0.60, 0.78, 0.80, 0.85)
  tip:AddDoubleLine("Right-click", "Gold timer", 0.50, 0.53, 0.60, 0.78, 0.80, 0.85)
  tip:AddDoubleLine("Shift + right-click", "Scan now", 0.50, 0.53, 0.60, 0.78, 0.80, 0.85)
end

-- ===== Button setup ==========================================================
local CIRCLE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
local WHITE  = "Interface\\Buttons\\WHITE8X8"

function M.InitMinimap()
  if btn or not Minimap then return end
  M.db.config = M.db.config or {}
  if M.db.config.minimapAngle == nil then M.db.config.minimapAngle = 198 end
  if M.db.config.minimapHide then return end

  btn = CreateFrame("Button", "MidasMinimapButton", Minimap)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:SetSize(30, 30)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton")

  -- outer rim (turns accent on hover)
  local ring = btn:CreateTexture(nil, "BACKGROUND")
  ring:SetTexture(WHITE); ring:SetVertexColor(T.Unpack(T.C.border))
  ring:SetSize(28, 28); ring:SetPoint("CENTER")
  local ringMask = btn:CreateMaskTexture()
  ringMask:SetAllPoints(ring); ringMask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  ring:AddMaskTexture(ringMask)

  -- dark disc inside the rim
  local disc = btn:CreateTexture(nil, "BORDER")
  disc:SetTexture(WHITE); disc:SetVertexColor(T.C.bg1[1], T.C.bg1[2], T.C.bg1[3], 0.95)
  disc:SetSize(26, 26); disc:SetPoint("CENTER")
  local discMask = btn:CreateMaskTexture()
  discMask:SetAllPoints(disc); discMask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  disc:AddMaskTexture(discMask)

  -- coin icon (clipped to a circle, no chunky default ring)
  local icon = btn:CreateTexture(nil, "ARTWORK")
  icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  icon:SetSize(22, 22); icon:SetPoint("CENTER")
  local iconMask = btn:CreateMaskTexture()
  iconMask:SetAllPoints(icon); iconMask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  icon:AddMaskTexture(iconMask)

  btn:SetScript("OnEnter", function(self)
    ring:SetVertexColor(T.Unpack(T.C.accent))
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    M.FillSellTooltip(GameTooltip)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function()
    ring:SetVertexColor(T.Unpack(T.C.border))
    GameTooltip:Hide()
  end)

  btn:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
      if IsShiftKeyDown() or not M.GoldTimerToggle then M.Scan(true) else M.GoldTimerToggle(true) end
    else
      M.Toggle()
    end
  end)

  -- drag around the minimap
  local function onUpdate()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    if not (mx and cx) then return end
    cx, cy = cx / scale, cy / scale
    M.db.config.minimapAngle = math.deg(atan2(cy - my, cx - mx))
    updatePos()
  end
  btn:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", onUpdate) end)
  btn:SetScript("OnDragStop",  function(self) self:SetScript("OnUpdate", nil) end)

  updatePos()
  M.minimap = btn
end

-- Settings toggle: show/hide the button live, no /reload needed. Writes the
-- (previously orphaned) config.minimapHide flag that InitMinimap honors.
function M.SetMinimapShown(show)
  M.db.config.minimapHide = (not show) and true or nil
  if show then
    if btn then btn:Show() else M.InitMinimap() end
  elseif btn then
    btn:Hide()
  end
end
