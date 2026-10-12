-- Midas – Tooltip: median & price signal right on the item
local ADDON, M = ...

-- Is our line already in the current tooltip? Prevents duplicates but still
-- allows re-adding after other addons (Auctionator/Bagnon/vendor) rebuilt the
-- tooltip and stripped our lines in the process.
local function hasMidas(tooltip)
  local name = tooltip.GetName and tooltip:GetName()
  if not name then return false end
  for i = 1, tooltip:NumLines() do
    local fs = _G[name .. "TextLeft" .. i]
    local t = fs and fs:GetText()
    if t and t:find("Midas", 1, true) then return true end
  end
  return false
end

local function annotate(tooltip, itemID)
  if not itemID or not M.db then return end
  -- Settings > Item tooltip: "full" (default) / "reduced" / "off"
  local mode = (M.db.config and M.db.config.tooltipMode) or "full"
  if mode == "off" then return end
  -- inside the Midas window the table row and the detail card already show
  -- these numbers -- the in-window item tooltip stays vanilla (no third copy)
  local owner = tooltip.GetOwner and tooltip:GetOwner()
  if owner and M.frame and owner == M.frame then return end
  local series = M.GetSeries(tostring(itemID))
  if not series then return end
  local m = M.Metrics(series, tostring(itemID))
  if not m or not m.fair or m.fair <= 0 then return end
  if hasMidas(tooltip) then return end

  local cur = m.cur
  local curQty = (series[m.lastDay] and series[m.lastDay].qty) or 0
  local avgQty = math.floor(m.avgQty + 0.5)
  -- color by price level: >=10% ABOVE fair = green (good to sell), <=10% below = red
  local delta = m.delta
  local sig, r, g, b
  if delta >= 0.10 then sig = string.format("+%.0f%% above fair", delta * 100); r, g, b = 0.36, 0.82, 0.47
  elseif delta <= -0.10 then sig = string.format("%.0f%% below fair", delta * 100); r, g, b = 0.94, 0.39, 0.35
  else sig = string.format("%+.0f%% ~ fair", delta * 100); r, g, b = 0.78, 0.80, 0.85 end
  local liqTxt = m.liqLabel or ""
  if m.speed then liqTxt = string.format("~%.1f/day \194\183 %s", m.speed, m.liqLabel or "") end
  -- Fair carries its meaning: the sell chance it is calibrated to (lower if capped)
  local fairTxt = "Fair  " .. M.Money(m.fair)
  if m.oddsAtFair then fairTxt = string.format("Fair (~%.0f%%)  %s", m.oddsAtFair * 100, M.Money(m.fair)) end

  tooltip:AddLine(" ")
  tooltip:AddDoubleLine("|cffE8B44AMidas|r", sig, 0.91, 0.70, 0.29, r, g, b)
  tooltip:AddDoubleLine("Current  " .. M.MoneyPlain(cur), fairTxt, r, g, b, 0.78, 0.76, 0.70)
  if mode == "reduced" then tooltip:Show(); return end
  tooltip:AddDoubleLine("Sells  " .. liqTxt, "Quick-sell  " .. M.MoneyPlain(m.quick), 0.78, 0.76, 0.70, 0.78, 0.76, 0.70)
  tooltip:AddDoubleLine("In AH now:  " .. curQty, "Avg in AH:  " .. avgQty, 0.78, 0.76, 0.70, 0.78, 0.76, 0.70)
  -- supply ladder of the newest scan: how much sits within 10% of the floor
  local dp = M.GetDepth and M.GetDepth(itemID)
  if dp and dp.levels[1] and (time() - (dp.ts or 0)) < 86400 then
    local cap, near = dp.levels[1].price * 1.10, 0
    for _, l in ipairs(dp.levels) do
      if l.price <= cap then near = l.qty + near end
    end
    tooltip:AddDoubleLine("Up to +10%:  " .. near, "Listed:  " .. (dp.listed or dp.units), 0.78, 0.76, 0.70, 0.78, 0.76, 0.70)
  end
  -- sell chance of a 48h listing at the CURRENT price (the transparency line)
  if m.odds then
    local o = m.odds
    local or_, og, ob
    if o >= 0.60 then or_, og, ob = 0.36, 0.82, 0.47
    elseif o < 0.35 then or_, og, ob = 0.94, 0.39, 0.35
    else or_, og, ob = 0.78, 0.80, 0.85 end
    local capTxt = ""
    if m.fairCapped then
      capTxt = (m.liqLabel == "Illiquid") and "  \194\183  thin market: sells rarely"
                                          or  "  \194\183  oversupplied: post less"
    end
    tooltip:AddLine(string.format("Sell odds at current price  ~%.0f%%%s", o * 100, capTxt), or_, og, ob)
  end
  -- what YOU historically paid per unit for this item (from your buy mails)
  if M.RealizedBuy then
    local paid, units = M.RealizedBuy(tostring(itemID))
    if paid and units > 0 then
      tooltip:AddLine(string.format("You paid  %s avg  (%d bought)", M.MoneyPlain(paid), units), 0.78, 0.76, 0.70)
    end
  end
  tooltip:Show()
end

-- ===== Mini price chart docked to the item tooltip ==========================
-- Settings > "Tooltip chart" picks its timeframe ("7"/"30"/"90"/"all") or "off".
-- A tooltip cannot host textures, so the chart lives in its own small panel
-- glued to the tooltip's bottom edge (top edge near the screen bottom).
local tt   -- the docked panel, built lazily
local TT_RANGE_LBL = { ["7"] = "1W", ["30"] = "1M", ["90"] = "3M", all = "ALL" }

local function chartPanel()
  if tt then return tt end
  local T = M.Theme
  tt = CreateFrame("Frame", "MidasTooltipChart", UIParent, "BackdropTemplate")
  tt:SetBackdrop(T.FLAT)
  tt:SetBackdropColor(T.C.bg0[1], T.C.bg0[2], T.C.bg0[3], 0.97)
  tt:SetBackdropBorderColor(T.C.border[1], T.C.border[2], T.C.border[3], 1)
  tt:SetSize(250, 104)
  tt:SetFrameStrata("TOOLTIP")
  tt:EnableMouse(false)
  tt.head = T.Text(tt, T.SIZE.tiny, "muted", T.FONT_MED)
  tt.head:SetPoint("TOPLEFT", 10, -7)
  tt.canvas = CreateFrame("Frame", nil, tt)
  -- EXPLICIT size, no bottom-right anchor: anchor-derived child rects are laid
  -- out lazily, so the very first render saw width 0 and collapsed the chart
  -- into the corner (and the render cache then kept the broken picture)
  tt.canvas:SetPoint("TOPLEFT", 6, -20)
  tt.canvas:SetSize(238, 80)
  tt.canvas._compact = true
  tt.canvas:EnableMouse(false)
  GameTooltip:HookScript("OnHide", function() tt:Hide() end)
  return tt
end

local function showChart(tooltip, itemID)
  if tooltip ~= GameTooltip or not M.db then return end
  local rng = (M.db.config and M.db.config.tooltipRange) or "30"
  if rng == "off" or not itemID then if tt then tt:Hide() end return end
  -- inside the Midas window the big chart is one click away - keep it clean
  local owner = tooltip.GetOwner and tooltip:GetOwner()
  if owner and M.frame and owner == M.frame then if tt then tt:Hide() end return end
  local key = tostring(itemID)
  local series = M.GetSeries(key)
  local days = 0
  if series then for _ in pairs(series) do days = days + 1; if days >= 2 then break end end end
  if days < 2 then if tt then tt:Hide() end return end

  local f = chartPanel()
  -- match the tooltip's width (it has laid out by post-call time); a width
  -- change invalidates the render cache so the plot fills the new frame
  local w = tooltip.GetWidth and tooltip:GetWidth() or 0
  -- follow the tooltip's full width (some tooltips run wide); 600 is only a
  -- safety cap against freak addon tooltips
  w = (w and w >= 120) and math.min(600, math.max(220, math.floor(w + 0.5))) or 250
  if f._w2 ~= w then f._w2 = w; f:SetWidth(w); f.canvas:SetSize(w - 12, 80); f._key = nil end
  f:ClearAllPoints()
  local b = tooltip.GetBottom and tooltip:GetBottom()
  if b and b < 118 then
    f:SetPoint("BOTTOMLEFT", tooltip, "TOPLEFT", 0, 2)
  else
    f:SetPoint("TOPLEFT", tooltip, "BOTTOMLEFT", 0, -2)
  end
  -- re-render only when the item, the timeframe or the data generation changed
  local gen = (M.db.config and M.db.config.lastIngest) or 0
  if f._key ~= key or f._rng ~= rng or f._gen ~= gen then
    f._key, f._rng, f._gen = key, rng, gen
    f.head:SetText("MIDAS  \194\183  PRICE  \194\183  " .. (TT_RANGE_LBL[rng] or rng))
    f.canvas._rangeOverride = rng
    M.RenderAllTime(f.canvas, key)
    f.canvas:EnableMouse(false)   -- SetupHover re-arms the mouse each render
  end
  f:Show()
end

local ok = false
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if tooltip ~= GameTooltip or not data then return end
    if issecretvalue and issecretvalue(data.id) then return end   -- modern client: restricted in combat
    if data.id then annotate(tooltip, data.id) end
    showChart(tooltip, data and data.id)
  end)
  ok = true
end
if not ok and GameTooltip.HookScript then
  GameTooltip:HookScript("OnTooltipSetItem", function(self)
    if self.GetItem then
      local _, link = self:GetItem()
      local id = link and tonumber(link:match("item:(%d+)"))
      annotate(self, id)
      showChart(self, id)
    end
  end)
end

-- "/midas ttchart": self-test. Renders the panel mid-screen for the first
-- scanned item and prints why it would not show on hover - separates a
-- renderer problem from a hover-context one without scriptErrors.
function M.TooltipChartTest()
  if not M.db then M.Print("tooltip chart: no DB yet") return end
  local rng = (M.db.config and M.db.config.tooltipRange) or "30"
  M.Print("tooltip chart: timeframe = " .. tostring(rng))
  if rng == "off" then M.Print("tooltip chart: set to OFF in Settings - nothing will show on hover") return end
  local key
  local store = M.db.realms and M.db.realms[M.RealmKey()]
  if store then
    for k, it in pairs(store) do
      local days = 0
      for _ in pairs(it) do days = days + 1; if days >= 2 then break end end
      if days >= 2 then key = k; break end
    end
  end
  if not key then M.Print("tooltip chart: no item with 2+ scan days on this realm - scan first") return end
  local f = chartPanel()
  if not f then M.Print("tooltip chart: panel build FAILED") return end
  f._key = nil
  f:ClearAllPoints()
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  f._w2 = 300; f:SetWidth(300); f.canvas:SetSize(288, 80)
  f.head:SetText("MIDAS  \194\183  SELF-TEST  \194\183  " .. (TT_RANGE_LBL[rng] or rng))
  f.canvas._rangeOverride = rng
  local ok2, err2 = pcall(M.RenderAllTime, f.canvas, key)
  if not ok2 then M.Print("tooltip chart: render ERROR: " .. tostring(err2)) return end
  f.canvas:EnableMouse(false)
  f:Show()
  M.Print("tooltip chart: shown mid-screen for item " .. tostring(key) .. " (hides in 5 s). If you can see it, the renderer is fine and only the hover context matters.")
  C_Timer.After(5, function() f:Hide(); f._key = nil end)
end
