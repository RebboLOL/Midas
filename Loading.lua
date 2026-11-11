-- Midas: start page placeholders while a dashboard card waits for its data
--
-- The four dashboard cards (Home.lua) fill one frame after the window is
-- built, and Next Moves needs the whole-archive analysis (Logic.lua), which
-- can still be running on a first open. Until a card has its data, an opaque
-- layer under its title row shows an animated stand-in in the card's own
-- shape, then crossfades into the real content:
--   NET WORTH   a gold price line climbs across the 30-day axis (glowing head,
--               filling area), the figures shimmer, the asset bar pulses
--   TRADING     shimmering figures and rows, a sweep through the sell-through bar
--   WATCHLIST   a warm wave runs diagonally through the tile grid
--   NEXT MOVES  a scan line sweeps the list, the action labels take turns,
--               the footer counts the analysis: "x / y items"
-- One OnUpdate driver animates every visible layer and sleeps (hidden) once
-- none is left, so a filled start page costs nothing.
local ADDON, M = ...
local T = M.Theme
local C = T.C
local floor, max, min = math.floor, math.max, math.min

local PAD, HEAD = 12, 30                 -- Home.lua card padding / title row
local TOP = HEAD - 2                     -- the layer starts just under the title row
local FADE_OUT, FADE_IN = 0.3, 0.15
local TILE_W, TILE_H, TGAP = 44, 50, 4   -- Home.lua watchlist grid
local MV_ROWH = 32                       -- Home.lua Next Moves row pitch
local WHITE = "Interface\\Buttons\\WHITE8X8"
local GLOW = "Interface\\AddOns\\" .. (ADDON or "Midas") .. "\\Media\\Glow"
local SK = { 0.133, 0.114, 0.082 }       -- skeleton fill
local TILE0 = { 0.118, 0.102, 0.075 }    -- watchlist tile at rest
local TILE1 = { 0.180, 0.149, 0.086 }    -- ...where the wave passes
local KEYS = { "hero", "trading", "map", "moves" }

-- the climbing price line, normalized (x right, y DOWN from the top), sampled
-- from a smooth rising curve; the area under it fills along with the line
local PATH = {
  { 0.000, 0.905 }, { 0.050, 0.872 }, { 0.100, 0.820 }, { 0.150, 0.773 }, { 0.196, 0.750 },
  { 0.250, 0.729 }, { 0.300, 0.686 }, { 0.350, 0.638 }, { 0.391, 0.607 }, { 0.440, 0.592 },
  { 0.490, 0.605 }, { 0.540, 0.611 }, { 0.587, 0.548 }, { 0.640, 0.468 }, { 0.690, 0.405 },
  { 0.740, 0.362 }, { 0.789, 0.321 }, { 0.840, 0.287 }, { 0.890, 0.240 }, { 0.940, 0.180 },
  { 1.000, 0.095 },
}
local NSEG = #PATH - 1
local CYCLE = 2.8                        -- one climb: draw 72%, hold, fade the last 12%

local function frac(x, p) return (x % p) / p end
local function smooth(x) return x * x * (3 - 2 * x) end
local function easeInOut(x) return (x < 0.5) and (2 * x * x) or (1 - (-2 * x + 2) ^ 2 / 2) end

-- vertical/horizontal alpha ramp in one colour; flat colour where the client
-- has no gradient API
local function grad(tex, orient, rgb, a1, a2)
  tex:SetColorTexture(1, 1, 1, 1)
  local ok = false
  if tex.SetGradient and CreateColor then
    ok = pcall(tex.SetGradient, tex, orient, CreateColor(rgb[1], rgb[2], rgb[3], a1), CreateColor(rgb[1], rgb[2], rgb[3], a2))
  end
  if not ok then tex:SetColorTexture(rgb[1], rgb[2], rgb[3], (a1 + a2) / 2) end
end

local function fmtInt(n)
  local s = tostring(floor((n or 0) + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

-- ===== building blocks ========================================================
-- skeleton bar: dark fill with a gold shimmer band sweeping across (the band
-- lives in a clipped child frame, so it never leaves the bar)
local function newSkel(c, d)
  local f = CreateFrame("Frame", nil, c.o)
  local bg = f:CreateTexture(nil, "ARTWORK")
  bg:SetAllPoints(); bg:SetColorTexture(SK[1], SK[2], SK[3], 1)
  if f.SetClipsChildren then
    f:SetClipsChildren(true)
    local band = CreateFrame("Frame", nil, f)
    local l = band:CreateTexture(nil, "OVERLAY")
    l:SetPoint("TOPLEFT", band, "TOPLEFT"); l:SetPoint("BOTTOMRIGHT", band, "BOTTOM")
    local r = band:CreateTexture(nil, "OVERLAY")
    r:SetPoint("TOPLEFT", band, "TOP"); r:SetPoint("BOTTOMRIGHT", band, "BOTTOMRIGHT")
    grad(l, "HORIZONTAL", C.accent, 0, 0.16)
    grad(r, "HORIZONTAL", C.accent, 0.16, 0)
    band:Hide()
    f.band = band
  end
  f.d, f._w, f._p = d or 0, 1, c.o
  c.sk[#c.sk + 1] = f
  return f
end

local function placeSkel(f, x, y, w, hgt)
  w, hgt = max(1, floor(w + 0.5)), max(1, floor(hgt + 0.5))
  f:ClearAllPoints(); f:SetPoint("TOPLEFT", f._p, "TOPLEFT", x, -y); f:SetSize(w, hgt)
  f._w = w
  if f.band then f.band:SetSize(w, hgt) end
end

local function tickSkel(f, t)
  local b = f.band
  if not b or not f:IsShown() then return end
  local p = frac(t - f.d, 1.8)
  if p < 0.6 then
    if not f._bs then b:Show(); f._bs = true end
    b:SetPoint("LEFT", f, "LEFT", -f._w + (p / 0.6) * 2 * f._w, 0)
  elseif f._bs then
    b:Hide(); f._bs = nil
  end
end

local function tex(c, layer, sub, parent)
  return (parent or c.o):CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
end

-- ===== NET WORTH ==============================================================
local function buildHero(c)
  c.num = newSkel(c, 0)
  c.p1, c.p2 = newSkel(c, 0.12), newSkel(c, 0.20)
  c.attr = newSkel(c, 0.28)
  c.seg = {}
  local cols = { C.accent, C.mint, C.green, C.red, C.purple, C.muted }
  for i, rgb in ipairs(cols) do
    local s = tex(c)
    s:SetColorTexture(rgb[1], rgb[2], rgb[3], 1); s:SetAlpha(0.18)
    s.d = (i - 1) * 0.22
    c.seg[i] = s
  end
  c.leg = { newSkel(c, 0.40), newSkel(c, 0.48), newSkel(c, 0.56) }
  local ch = CreateFrame("Frame", nil, c.o)
  c.chart = ch
  c.ghost = {}
  for i = 1, 30 do
    local b = tex(c, "BORDER", 0, ch)
    b:SetColorTexture(0.141, 0.118, 0.082, 1)
    c.ghost[i] = b
  end
  c.area, c.ln, c.gl = {}, {}, {}
  for k = 1, NSEG do
    local a = tex(c, "ARTWORK", 1, ch)
    grad(a, "VERTICAL", C.teal, 0, 0.30)
    a:Hide(); c.area[k] = a
    local g = ch:CreateLine(nil, "ARTWORK", nil, 3)
    g:SetTexture(WHITE); g:SetVertexColor(C.teal[1], C.teal[2], C.teal[3], 0.22); g:SetThickness(6)
    g:SetBlendMode("ADD"); g:Hide(); c.gl[k] = g
    local l = ch:CreateLine(nil, "ARTWORK", nil, 4)
    l:SetTexture(WHITE); l:SetVertexColor(C.teal[1], C.teal[2], C.teal[3], 1); l:SetThickness(2)
    l:Hide(); c.ln[k] = l
  end
  c.halo = tex(c, "OVERLAY", 1, ch); c.halo:SetTexture(GLOW); c.halo:SetBlendMode("ADD")
  c.halo:SetVertexColor(C.teal[1], C.teal[2], C.teal[3], 0.55); c.halo:SetSize(34, 34); c.halo:Hide()
  c.head = tex(c, "OVERLAY", 2, ch); c.head:SetTexture(GLOW)
  c.head:SetVertexColor(1, 0.91, 0.66, 1); c.head:SetSize(11, 11); c.head:Hide()
  c.drawn = 0
end

local function layoutHero(c, g)
  local lw = max(268, floor(g.heroW * 0.42))
  local compW = lw - PAD
  local x0 = PAD - 1
  placeSkel(c.num, x0, 5, 152, 24)
  placeSkel(c.p1, x0, 42, 88, 17)
  placeSkel(c.p2, x0 + 94, 42, 114, 17)
  placeSkel(c.attr, x0, 70, min(214, compW), 9)
  local fr = { 0.14, 0.37, 0.19, 0.01, 0.15, 0.14 }
  local x = x0
  for i, s in ipairs(c.seg) do
    local w = max(1, floor(compW * fr[i] + 0.5) - 1)
    s:ClearAllPoints(); s:SetPoint("TOPLEFT", c.o, "TOPLEFT", x, -90); s:SetSize(w, 6)
    x = x + w + 1
  end
  placeSkel(c.leg[1], x0, 105, 74, 8)
  placeSkel(c.leg[2], x0 + 88, 105, 58, 8)
  placeSkel(c.leg[3], x0 + 160, 105, 64, 8)
  -- the chart where the real net-worth chart sits (Home.lua h.spark)
  local cx = lw + PAD + 8
  local w = max(60, g.heroW - cx - PAD)
  local hgt = max(40, g.r1 - HEAD - 12)
  local ch = c.chart
  ch:ClearAllPoints(); ch:SetPoint("TOPLEFT", c.o, "TOPLEFT", cx - 1, -(HEAD - TOP)); ch:SetSize(w, hgt)
  local bw = max(2, floor((w - 29 * 4) / 30))
  for i, b in ipairs(c.ghost) do
    b:ClearAllPoints(); b:SetPoint("BOTTOMLEFT", ch, "BOTTOMLEFT", (i - 1) * (bw + 4), 0)
    b:SetSize(bw, 8 + ((i * 37) % 13))
  end
  c.px, c.py = {}, {}
  for k, p in ipairs(PATH) do
    c.px[k] = 2 + p[1] * (w - 4)
    c.py[k] = 4 + (1 - p[2]) * (hgt - 14)
  end
  for k = 1, NSEG do
    c.ln[k]:SetStartPoint("BOTTOMLEFT", ch, c.px[k], c.py[k]); c.ln[k]:SetEndPoint("BOTTOMLEFT", ch, c.px[k + 1], c.py[k + 1])
    c.gl[k]:SetStartPoint("BOTTOMLEFT", ch, c.px[k], c.py[k]); c.gl[k]:SetEndPoint("BOTTOMLEFT", ch, c.px[k + 1], c.py[k + 1])
    local a = c.area[k]
    a:ClearAllPoints(); a:SetPoint("BOTTOMLEFT", ch, "BOTTOMLEFT", c.px[k], 0)
    a:SetSize(max(1, c.px[k + 1] - c.px[k] + 0.5), max(1, (c.py[k] + c.py[k + 1]) / 2))
  end
  c.drawn = -1     -- the next tick rebuilds the line from scratch
end

local function segPulse(p)
  if p < 0.3 then return 0.18 + 0.57 * smooth(p / 0.3) end
  if p < 0.55 then return 0.75 - 0.57 * smooth((p - 0.3) / 0.25) end
  return 0.18
end

local function tickHero(c, t)
  for _, s in ipairs(c.seg) do s:SetAlpha(segPulse(frac(t - s.d, 2.4))) end
  local p = frac(t, CYCLE)
  local draw = min(1, p / 0.72)
  c.chart:SetAlpha((p < 0.88) and 1 or max(0, 1 - (p - 0.88) / 0.12))
  local s = draw * NSEG
  local full = min(NSEG, floor(s))
  local part = s - full
  if full < c.drawn or c.drawn < 0 then          -- a new climb: start empty
    for k = 1, NSEG do c.ln[k]:Hide(); c.gl[k]:Hide(); c.area[k]:Hide() end
    c.drawn = 0
  end
  while c.drawn < full do
    c.drawn = c.drawn + 1
    local k = c.drawn
    c.ln[k]:SetEndPoint("BOTTOMLEFT", c.chart, c.px[k + 1], c.py[k + 1])
    c.gl[k]:SetEndPoint("BOTTOMLEFT", c.chart, c.px[k + 1], c.py[k + 1])
    c.area[k]:SetWidth(max(1, c.px[k + 1] - c.px[k] + 0.5))
    c.ln[k]:Show(); c.gl[k]:Show(); c.area[k]:Show()
  end
  local hx, hy = c.px[full + 1], c.py[full + 1]
  local k = full + 1
  if k <= NSEG and part > 0 then
    hx = c.px[k] + (c.px[k + 1] - c.px[k]) * part
    hy = c.py[k] + (c.py[k + 1] - c.py[k]) * part
    c.ln[k]:SetEndPoint("BOTTOMLEFT", c.chart, hx, hy)
    c.gl[k]:SetEndPoint("BOTTOMLEFT", c.chart, hx, hy)
    c.area[k]:SetWidth(max(1, hx - c.px[k]))
    c.ln[k]:Show(); c.gl[k]:Show(); c.area[k]:Show()
  end
  c.head:ClearAllPoints(); c.head:SetPoint("CENTER", c.chart, "BOTTOMLEFT", hx, hy); c.head:Show()
  c.halo:ClearAllPoints(); c.halo:SetPoint("CENTER", c.chart, "BOTTOMLEFT", hx, hy); c.halo:Show()
end

-- ===== TRADING ================================================================
local function buildTrading(c)
  c.l1, c.v1, c.s1 = newSkel(c, 0), newSkel(c, 0.10), newSkel(c, 0.20)
  c.l2, c.v2, c.s2 = newSkel(c, 0.05), newSkel(c, 0.15), newSkel(c, 0.25)
  c.track = tex(c)
  c.track:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
  c.sweepBox = CreateFrame("Frame", nil, c.o)
  if c.sweepBox.SetClipsChildren then c.sweepBox:SetClipsChildren(true) end
  c.sweep = CreateFrame("Frame", nil, c.sweepBox)
  local l = c.sweep:CreateTexture(nil, "ARTWORK")
  l:SetPoint("TOPLEFT", c.sweep, "TOPLEFT"); l:SetPoint("BOTTOMRIGHT", c.sweep, "BOTTOM")
  local r = c.sweep:CreateTexture(nil, "ARTWORK")
  r:SetPoint("TOPLEFT", c.sweep, "TOP"); r:SetPoint("BOTTOMRIGHT", c.sweep, "BOTTOMRIGHT")
  grad(l, "HORIZONTAL", C.accent, 0, 1); grad(r, "HORIZONTAL", C.accent, 1, 0)
  c.rows = {}
end

local TR_NAME = { 140, 100, 92, 118, 84, 106 }
local function layoutTrading(c, g)
  local half = floor((g.trW - 2 * PAD) / 2)
  local x1, x2 = PAD - 1, PAD + half + 6 - 1
  placeSkel(c.l1, x1, 4, 62, 7); placeSkel(c.v1, x1, 17, 54, 16); placeSkel(c.s1, x1, 37, min(104, half - 10), 8)
  placeSkel(c.l2, x2, 4, 92, 7); placeSkel(c.v2, x2, 17, 40, 16); placeSkel(c.s2, x2, 37, min(118, half - 10), 8)
  local bw = max(10, half - 6 - 50)
  c.track:ClearAllPoints(); c.track:SetPoint("TOPLEFT", c.o, "TOPLEFT", x2 + 50, -24); c.track:SetSize(bw, 4)
  c.sweepBox:ClearAllPoints(); c.sweepBox:SetPoint("TOPLEFT", c.track, "TOPLEFT"); c.sweepBox:SetSize(bw, 4)
  c.sweep:SetSize(max(8, floor(bw * 0.34)), 4)
  c.bw = bw
  local rowW = g.trW - 2 * PAD
  local n = max(1, floor((g.r1 - 84 - 6) / 19))
  for i = 1, max(n, #c.rows) do
    local r = c.rows[i]
    if i <= n then
      if not r then
        local d = 0.3 + (i - 1) * 0.12
        r = { newSkel(c, d), newSkel(c, d), newSkel(c, d), newSkel(c, d) }
        c.rows[i] = r
      end
      local y = 56 + (i - 1) * 19
      placeSkel(r[1], x1, y, 46, 17)
      placeSkel(r[2], x1 + 52, y, 16, 16)
      placeSkel(r[3], x1 + 74, y + 4, min(TR_NAME[(i - 1) % #TR_NAME + 1], rowW - 74 - 46), 9)
      placeSkel(r[4], x1 + rowW - 34, y + 4, 34, 9)
      for _, s in ipairs(r) do s:Show() end
    elseif r then
      for _, s in ipairs(r) do s:Hide() end
    end
  end
end

local function tickTrading(c, t)
  local e = easeInOut(frac(t, 1.6))
  local sw = c.sweep:GetWidth()
  c.sweep:SetPoint("LEFT", c.sweepBox, "LEFT", -sw + e * (c.bw + sw), 0)
end

-- ===== WATCHLIST ==============================================================
local function buildMap(c)
  c.tiles = {}
end

local function layoutMap(c, g)
  local aw = g.mapW - 2 * PAD
  local ah = g.r2 - HEAD - 8
  local cols = max(1, floor((aw + TGAP) / (TILE_W + TGAP)))
  local rows = max(1, floor((ah + TGAP) / (TILE_H + TGAP)))
  local tw = floor((aw - (cols - 1) * TGAP) / cols)
  local n = min(cols * rows, 120)
  for i = 1, max(n, #c.tiles) do
    local tl = c.tiles[i]
    if i <= n then
      if not tl then
        tl = { rim = tex(c, "BORDER"), bg = tex(c, "ARTWORK", 1), icon = tex(c, "ARTWORK", 3), lab = tex(c, "ARTWORK", 3) }
        tl.rim:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1); tl.rim:SetAlpha(0)
        tl.bg:SetColorTexture(TILE0[1], TILE0[2], TILE0[3], 1)
        tl.icon:SetColorTexture(0.165, 0.141, 0.106, 1)
        tl.lab:SetColorTexture(0.165, 0.141, 0.106, 1)
        c.tiles[i] = tl
      end
      local col, row = (i - 1) % cols, floor((i - 1) / cols)
      local x, y = PAD - 1 + col * (tw + TGAP), (HEAD - TOP) + row * (TILE_H + TGAP)
      tl.d = (col + row * 1.5) * 0.07
      tl.rim:ClearAllPoints(); tl.rim:SetPoint("TOPLEFT", c.o, "TOPLEFT", x, -y); tl.rim:SetSize(tw, TILE_H)
      tl.bg:ClearAllPoints(); tl.bg:SetPoint("TOPLEFT", c.o, "TOPLEFT", x + 1, -(y + 1)); tl.bg:SetSize(tw - 2, TILE_H - 2)
      tl.icon:ClearAllPoints(); tl.icon:SetPoint("TOP", tl.rim, "TOP", 0, -6); tl.icon:SetSize(26, 26)
      tl.lab:ClearAllPoints(); tl.lab:SetPoint("BOTTOM", tl.rim, "BOTTOM", 0, 8); tl.lab:SetSize(24, 6)
      for _, r in pairs({ tl.rim, tl.bg, tl.icon, tl.lab }) do r:Show() end
    elseif tl then
      for _, r in pairs({ tl.rim, tl.bg, tl.icon, tl.lab }) do r:Hide() end
    end
  end
  c.n = n
end

local function wave(p)
  if p < 0.4 then return smooth(p / 0.4) end
  if p < 0.7 then return smooth(1 - (p - 0.4) / 0.3) end
  return 0
end

local function tickMap(c, t)
  for i = 1, c.n or 0 do
    local tl = c.tiles[i]
    local k = wave(frac(t - tl.d, 2.6))
    tl.bg:SetColorTexture(TILE0[1] + (TILE1[1] - TILE0[1]) * k, TILE0[2] + (TILE1[2] - TILE0[2]) * k,
      TILE0[3] + (TILE1[3] - TILE0[3]) * k, 1)
    tl.rim:SetAlpha(0.35 * k)
  end
end

-- ===== NEXT MOVES =============================================================
local VERBS = { { "BUY", "green" }, { "SELL", "red" }, { "UNDERCUT", "purple" }, { "ALERT", "accent" } }
local MV_NAME, MV_WHY = { 92, 70, 140, 150, 84, 104 }, { 120, 118, 110, 128, 64, 70 }

local function buildMoves(c)
  c.rows = {}
  c.scan = CreateFrame("Frame", nil, c.o)
  c.scan:SetFrameLevel(c.o:GetFrameLevel() + 5)   -- the sweep passes over the rows
  c.scanBody = c.scan:CreateTexture(nil, "OVERLAY", nil, 1)
  c.scanBody:SetPoint("TOPLEFT"); c.scanBody:SetPoint("BOTTOMRIGHT", c.scan, "BOTTOMRIGHT", 0, 1)
  grad(c.scanBody, "VERTICAL", C.accent, 0.10, 0)
  c.scanEdge = c.scan:CreateTexture(nil, "OVERLAY", nil, 2)
  c.scanEdge:SetPoint("BOTTOMLEFT"); c.scanEdge:SetPoint("BOTTOMRIGHT"); c.scanEdge:SetHeight(1)
  c.scanEdge:SetColorTexture(C.teal[1], C.teal[2], C.teal[3], 0.55)
  c.foot = T.Text(c.o, 11, "muted")
  c.cur = T.Text(c.o, 11, "accent"); c.cur:SetText("_")
  c.cur:SetPoint("LEFT", c.foot, "RIGHT", 1, 0)
  c.ptrack = tex(c); c.ptrack:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
  c.pfill = tex(c, "ARTWORK", 2); c.pfill:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
  c.pglow = tex(c, "ARTWORK", 3); c.pglow:SetTexture(GLOW); c.pglow:SetBlendMode("ADD")
  c.pglow:SetVertexColor(C.teal[1], C.teal[2], C.teal[3], 0.8); c.pglow:SetSize(14, 8)
end

local function layoutMoves(c, g)
  local rowW = g.mvW - 2 * PAD
  local n = max(1, floor((g.r2 - HEAD - 26) / MV_ROWH))
  local x0 = PAD - 1
  for i = 1, max(n, #c.rows) do
    local r = c.rows[i]
    if i <= n then
      if not r then
        local d = (i - 1) * 0.14
        local pill = CreateFrame("Frame", nil, c.o)
        pill.bg = pill:CreateTexture(nil, "ARTWORK"); pill.bg:SetAllPoints()
        pill.fs = T.Text(pill, 11, "text", T.FONT_MED); pill.fs:SetPoint("CENTER", 0, 0)
        r = { pill = pill, icon = newSkel(c, d), name = newSkel(c, d), val = newSkel(c, d), why = newSkel(c, d),
              off = (i - 1) * 0.55, verb = 0 }
        c.rows[i] = r
      end
      local y = (HEAD - TOP) + (i - 1) * MV_ROWH
      r.pill:ClearAllPoints(); r.pill:SetPoint("TOPLEFT", c.o, "TOPLEFT", x0, -(y + 1)); r.pill:SetSize(58, 18)
      placeSkel(r.icon, x0 + 64, y + 1, 16, 16)
      placeSkel(r.name, x0 + 86, y + 5, min(MV_NAME[(i - 1) % 6 + 1], rowW - 86 - 50), 9)
      placeSkel(r.val, x0 + rowW - 38, y + 5, 38, 9)
      placeSkel(r.why, x0 + 64, y + 20, min(MV_WHY[(i - 1) % 6 + 1], rowW - 64), 7)
      r.pill:Show(); r.icon:Show(); r.name:Show(); r.val:Show(); r.why:Show()
    elseif r then
      r.pill:Hide(); r.icon:Hide(); r.name:Hide(); r.val:Hide(); r.why:Hide()
    end
  end
  c.H = max(40, g.r2 - TOP - 1)
  c.scan:SetSize(g.mvW - 2, 46)
  c.foot:ClearAllPoints(); c.foot:SetPoint("BOTTOMLEFT", c.o, "BOTTOMLEFT", x0, 15)
  c.ptrack:ClearAllPoints(); c.ptrack:SetPoint("BOTTOMLEFT", c.o, "BOTTOMLEFT", x0, 8); c.ptrack:SetSize(rowW, 2)
  c.pfill:ClearAllPoints(); c.pfill:SetPoint("BOTTOMLEFT", c.ptrack, "BOTTOMLEFT", 0, 0); c.pfill:SetHeight(2)
  c.rowW = rowW
end

local function tickMoves(c, t)
  for _, r in ipairs(c.rows) do
    if r.pill:IsShown() then
      local u = (t + r.off) % 6.4
      local idx = floor(u / 1.6) + 1
      if idx ~= r.verb then
        r.verb = idx
        local v = VERBS[idx]
        local rgb = C[v[2]] or C.accent
        r.pill.fs:SetText(v[1]); r.pill.fs:SetTextColor(rgb[1], rgb[2], rgb[3], 1)
        r.pill.bg:SetColorTexture(rgb[1], rgb[2], rgb[3], 0.14)
      end
      local q = (u % 1.6) / 1.6
      local a = (q < 0.1) and (q / 0.1) or ((q > 0.85) and ((1 - q) / 0.15) or 1)
      r.pill:SetAlpha(0.7 * a)
    end
  end
  local y = -46 + easeInOut(frac(t, 2.4)) * (c.H + 46)
  c.scan:ClearAllPoints(); c.scan:SetPoint("TOPLEFT", c.o, "TOPLEFT", 0, -y)
  -- the analysis' own count where it runs; otherwise a sweep
  -- direct call: an `x and f()` chain would keep only the first value
  local done, total
  if M.AnalysisProgress then done, total = M.AnalysisProgress() end
  local f
  if done and total and total > 0 then
    f = min(1, done / total)
    if c._done ~= done then
      c._done = done
      c.foot:SetText("reading the market  \194\183  " .. fmtInt(done) .. " / " .. fmtInt(total) .. " items")
    end
  else
    f = frac(t, 2.0)
    if c._done ~= false then c._done = false; c.foot:SetText("reading the market") end
  end
  local w = max(1, c.rowW * f)
  c.pfill:SetWidth(w)
  c.pglow:ClearAllPoints(); c.pglow:SetPoint("CENTER", c.ptrack, "LEFT", w, 1)
  c.cur:SetShown(frac(t, 1.2) < 0.5)
end

-- ===== the layers =============================================================
local CARDS = {
  hero = { build = buildHero, layout = layoutHero, tick = tickHero },
  trading = { build = buildTrading, layout = layoutTrading, tick = tickTrading },
  map = { build = buildMap, layout = layoutMap, tick = tickMap },
  moves = { build = buildMoves, layout = layoutMoves, tick = tickMoves },
}

local function layoutAll(L, h)
  local g = h.geo
  if not g then return end
  L.geoKey = h._lw and (h._lw .. "x" .. h._lh) or "?"
  for _, key in ipairs(KEYS) do
    local c = L.c[key]
    if c then CARDS[key].layout(c, g) end
  end
end

local function alphaOf(c, now)
  if c.state == "on" then
    return min(1, c.from + (now - c.since) / FADE_IN)
  elseif c.state == "out" then
    return max(0, c.from - (now - c.since) / FADE_OUT)
  end
  return 0
end

local function tickAll(L, now)
  local t = now - L.t0
  local any = false
  for _, key in ipairs(KEYS) do
    local c = L.c[key]
    if c and c.state ~= "off" then
      local a = alphaOf(c, now)
      if c.state == "out" and a <= 0 then
        c.state = "off"; c.o:Hide()
      else
        any = true
        c.o:SetAlpha(a)
        for _, s in ipairs(c.sk) do tickSkel(s, t) end
        CARDS[key].tick(c, t)
      end
    end
  end
  if not any then L.driver:Hide() end
end

-- Called at the end of Home.lua BuildHome: every card waits for its first fill.
function M.HomeLoadingInit(h)
  if not (h and h.cards and h.root) then return end
  local L = { c = {}, t0 = GetTime() }
  h.load = L
  L.driver = CreateFrame("Frame", nil, h.root)
  L.driver:Hide()
  L.driver:SetScript("OnUpdate", function() tickAll(L, GetTime()) end)
  for _, key in ipairs(KEYS) do
    local card = h.cards[key]
    if card then
      local o = CreateFrame("Frame", nil, card)
      o:SetFrameLevel(card:GetFrameLevel() + 9)
      o:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -TOP)
      o:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -1, 1)
      local bg = o:CreateTexture(nil, "BACKGROUND")
      bg:SetAllPoints(); bg:SetColorTexture(C.bg1[1], C.bg1[2], C.bg1[3], 1)
      if o.SetClipsChildren then o:SetClipsChildren(true) end
      local c = { key = key, o = o, sk = {}, state = "off", from = 0, since = 0 }
      L.c[key] = c
      CARDS[key].build(c)
      -- on from the first frame: no blank card before the first fill
      c.state, c.from, c.since = "on", 1, GetTime()
      o:EnableMouse(true); o:SetAlpha(1); o:Show()
    end
  end
  layoutAll(L, h)
  L.driver:Show()
end

-- Called at the end of every dashboard fill: ready = { hero=, trading=, map=, moves= }.
-- A ready card fades its layer out; one that is not ready (again) fades it in.
function M.HomeLoadingSet(h, ready)
  local L = h and h.load
  if not L then return end
  local key0 = h._lw and (h._lw .. "x" .. h._lh) or "?"
  if L.geoKey ~= key0 then layoutAll(L, h) end
  local now = GetTime()
  local run = false
  for _, key in ipairs(KEYS) do
    local c = L.c[key]
    if c then
      if ready and ready[key] then
        if c.state == "on" then
          c.from, c.since, c.state = alphaOf(c, now), now, "out"
          c.o:EnableMouse(false)
          run = true
        end
      elseif c.state ~= "on" then
        c.from, c.since, c.state = alphaOf(c, now), now, "on"
        c.o:EnableMouse(true); c.o:SetAlpha(c.from); c.o:Show()
        run = true
      end
    end
  end
  if run then L.driver:Show() end
end

-- Every layer off at once (offline renders and tests, which have no frame loop).
function M.HomeLoadingSkip(h)
  local L = h and h.load
  if not L then return end
  for _, c in pairs(L.c) do c.state = "off"; c.o:Hide() end
  L.driver:Hide()
end

-- Keys whose layer still shows (tests).
function M.HomeLoadingActive(h)
  local out = {}
  local L = h and h.load
  if not L then return out end
  for _, key in ipairs(KEYS) do
    local c = L.c[key]
    if c and c.state ~= "off" then out[#out + 1] = key end
  end
  return out
end

-- one animation step at a given time (tests)
M._loadingTick = tickAll
