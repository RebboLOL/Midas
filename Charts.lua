-- Midas – Charts: Scalable-style line charts. Thin anti-aliased teal line on a
-- clean dark ground, value bounds on the right, current value at the line end.
local ADDON, M = ...
local WHITE = "Interface\\Buttons\\WHITE8X8"
-- Smooth lines: the curves are drawn with a high-resolution line profile
-- (Media\AALine: 64 texels across the thickness, solid core, soft edges)
-- that the GPU scales down to the line's few screen pixels - the edge
-- smoothing a supersampled render would give, which the UI API cannot do.
-- The drawn quad is AA_PAD wider than the visible line so the soft edges
-- sit outside the core; pixel snapping is off so slopes do not stair-step.
-- Horizontal reference lines stay crisp (plain texture, snapped).
local AA_LINE = "Interface\\AddOns\\" .. (ADDON or "Midas") .. "\\Media\\AALine"
local AA_PAD = 1.5
local aaOK = true          -- false once the texture failed to load: plain lines

local function TC(key)
  local c = M.Theme and M.Theme.C[key]
  if c then return c[1], c[2], c[3] else return 0.8, 0.8, 0.8 end
end

-- Recency fade in the Midas gold: newest week strongest, older weeks fade
-- toward a muted grey. (Fade behaviour kept by request.)
local function fadeColor(k, n)
  local t = (n <= 1) and 1 or (0.25 + 0.75 * (k / (n - 1)))
  local b = (M.Theme and M.Theme.C.teal) or { 0.99, 0.80, 0.38 }
  local gx = 0.30
  return b[1] * t + gx * (1 - t), b[2] * t + gx * (1 - t), b[3] * t + gx * (1 - t)
end

-- ===== Pools on the canvas ==================================================
local function GetLine(canvas)
  canvas._ln = canvas._ln or {}; canvas._lnN = (canvas._lnN or 0) + 1
  local ln = canvas._ln[canvas._lnN]
  if not ln then ln = canvas:CreateLine(nil, "ARTWORK"); ln:SetTexture(WHITE); canvas._ln[canvas._lnN] = ln end
  ln:Show()
  return ln
end

local function GetTex(canvas, layer)
  canvas._tex = canvas._tex or {}; canvas._texN = (canvas._texN or 0) + 1
  local t = canvas._tex[canvas._texN]
  if not t then t = canvas:CreateTexture(nil, layer or "OVERLAY"); canvas._tex[canvas._texN] = t end
  t:SetDrawLayer(layer or "OVERLAY"); t:Show()
  return t
end

local function GetFS(canvas)
  canvas._fs = canvas._fs or {}; canvas._fsN = (canvas._fsN or 0) + 1
  local s = canvas._fs[canvas._fsN]
  if not s then
    s = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); canvas._fs[canvas._fsN] = s
    -- canvas._fontSize: a chart may ask for larger labels (the Start dashboard)
    if M.Theme and M.Theme.RegFont then M.Theme.RegFont(s, M.Theme.FONT, canvas._fontSize or 10) end
  end
  s:SetText(""); s:Show()
  return s
end

local function ResetPools(canvas)
  for i = 1, (canvas._lnN or 0) do canvas._ln[i]:Hide() end
  for i = 1, (canvas._texN or 0) do canvas._tex[i]:Hide() end
  for i = 1, (canvas._fsN or 0) do canvas._fs[i]:Hide() end
  canvas._lnN, canvas._texN, canvas._fsN = 0, 0, 0
  canvas._pts = nil
end

-- ===== Primitives (origin = BOTTOMLEFT of the canvas) =======================
-- smooth = soft-edged line (curves, slanted dashes); otherwise a crisp plain
-- line. "/midas lines" switches every chart to crisp lines (config.crispLines).
local function lineMode(ln, smooth)
  if smooth and aaOK and not (M.db and M.db.config and M.db.config.crispLines) then
    if ln._aa ~= true then
      if ln:SetTexture(AA_LINE) == false then
        aaOK = false
        ln:SetTexture(WHITE); ln._aa = false
      else
        ln._aa = true
        if ln.SetSnapToPixelGrid then ln:SetSnapToPixelGrid(false) end
        if ln.SetTexelSnappingBias then ln:SetTexelSnappingBias(0) end
      end
    end
  elseif ln._aa ~= false then
    ln:SetTexture(WHITE); ln._aa = false
    if ln.SetSnapToPixelGrid then ln:SetSnapToPixelGrid(true) end
  end
  return ln._aa
end

local function Seg(canvas, x1, y1, x2, y2, w, r, g, b, a, smooth)
  local ln = GetLine(canvas)
  w = w or 1.5
  if lineMode(ln, smooth) then
    ln:SetThickness(w + AA_PAD)
  else
    ln:SetThickness(w)
  end
  ln:SetVertexColor(r, g, b, a or 1)
  ln:SetStartPoint("BOTTOMLEFT", canvas, x1, y1)
  ln:SetEndPoint("BOTTOMLEFT", canvas, x2, y2)
end

local function Dot(canvas, x, y, s, r, g, b)
  local t = GetTex(canvas, "OVERLAY")
  t:SetTexture(WHITE); t:SetVertexColor(r, g, b, 1)
  t:SetSize(s, s); t:ClearAllPoints()
  t:SetPoint("CENTER", canvas, "BOTTOMLEFT", x, y)
end

-- Round dot: a circular alpha-mask texture tinted via vertex color (the square
-- WHITE8X8 pixel reads as a "blip"; trade markers want a proper round dot).
local CIRCLE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
local function RoundDot(canvas, x, y, s, r, g, b, a)
  local t = GetTex(canvas, "OVERLAY")
  t:SetTexture(CIRCLE)
  t:SetVertexColor(r, g, b, a or 1)
  t:SetSize(s, s); t:ClearAllPoints()
  t:SetPoint("CENTER", canvas, "BOTTOMLEFT", x, y)
end

local function Label(canvas, x, y, text, anchor, r, g, b)
  local s = GetFS(canvas)
  s:SetText(text); s:ClearAllPoints()
  s:SetPoint(anchor or "CENTER", canvas, "BOTTOMLEFT", x, y)
  if r then s:SetTextColor(r, g, b) else s:SetTextColor(TC("sub")) end
  return s
end

-- Smooth polyline through pts ({x=,y=}) via Catmull-Rom, clamped to [ylo,yhi].
local function Curve(canvas, pts, w, r, g, b, a, ylo, yhi)
  local n = #pts
  if n == 0 then return end
  if n == 1 then Dot(canvas, pts[1].x, pts[1].y, 3, r, g, b); return end
  if n == 2 then Seg(canvas, pts[1].x, pts[1].y, pts[2].x, pts[2].y, w, r, g, b, a, true); return end
  local STEPS = 14
  local function P(i) if i < 1 then i = 1 elseif i > n then i = n end return pts[i] end
  local px, py
  for i = 1, n - 1 do
    local p0, p1, p2, p3 = P(i - 1), P(i), P(i + 1), P(i + 2)
    for s = 0, STEPS do
      local t = s / STEPS
      local t2 = t * t; local t3 = t2 * t
      local x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
      local y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
      if y < ylo then y = ylo elseif y > yhi then y = yhi end
      if px then Seg(canvas, px, py, x, y, w, r, g, b, a, true) end
      px, py = x, y
    end
  end
end

-- Dashed straight segment (manual dashing: WoW lines can't be dashed natively).
-- Used to bridge missing scan days as an interpolated, visually distinct line.
local function DashSeg(canvas, x1, y1, x2, y2, w, r, g, b, a)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return end
  local ux, uy = dx / len, dy / len
  local dash, gap = 5, 4
  local d = 0
  -- level lines (Fair, alerts, Crafted) stay crisp; slanted bridges are smooth
  local smooth = math.abs(dx) > 0.01 and math.abs(dy) > 0.01
  while d < len do
    local e = math.min(d + dash, len)
    Seg(canvas, x1 + ux * d, y1 + uy * d, x1 + ux * e, y1 + uy * e, w, r, g, b, a, smooth)
    d = e + gap
  end
end

-- Monotone cubic Hermite interpolation (Fritsch-Carlson) -- the shape-preserving
-- smoothing finance/charting libs use (this is D3's `curveMonotoneX`): smooth, but
-- it never overshoots the data and stays single-valued in x (exactly one y per x,
-- no loops). Points must be sorted with strictly increasing x. Any point may flag
-- its incoming segment as dashed; dashing is even and pixel-based along the curve.
local function SmoothLine(canvas, pts, w, r, g, b, a, ylo, yhi, dashA)
  local n = #pts
  if n == 0 then return end
  if n == 1 then Dot(canvas, pts[1].x, pts[1].y, 3, r, g, b); return end

  -- secant slopes, then monotone tangents
  local d, m = {}, {}
  for i = 1, n - 1 do
    local dx = pts[i + 1].x - pts[i].x
    d[i] = (dx ~= 0) and (pts[i + 1].y - pts[i].y) / dx or 0
  end
  m[1] = d[1]; m[n] = d[n - 1]
  for i = 2, n - 1 do m[i] = (d[i - 1] + d[i]) / 2 end
  for i = 1, n - 1 do
    if d[i] == 0 then
      m[i] = 0; m[i + 1] = 0
    else
      local al = m[i] / d[i]
      local be = m[i + 1] / d[i]
      if al < 0 then m[i] = 0; al = 0 end
      if be < 0 then m[i + 1] = 0; be = 0 end
      local sq = al * al + be * be
      if sq > 9 then
        local tau = 3 / math.sqrt(sq)
        m[i] = tau * al * d[i]
        m[i + 1] = tau * be * d[i]
      end
    end
  end

  -- render each interval with cubic Hermite + even pixel dashing
  local DASH, GAP = 6, 4
  for i = 1, n - 1 do
    local x1, y1, x2, y2 = pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y
    local h, m1, m2 = x2 - x1, m[i], m[i + 1]
    local dashed = pts[i + 1].dash
    local col = dashed and (dashA or a * 0.5) or a
    local span = math.abs(x2 - x1) + math.abs(y2 - y1)
    local steps = dashed and math.max(12, math.min(48, math.floor(span / 4)))
                         or  math.max(4,  math.min(20, math.floor(span / 6)))
    local px, py, dist = nil, nil, 0
    for s = 0, steps do
      local t = s / steps
      local t2 = t * t; local t3 = t2 * t
      local x = x1 + h * t
      local y = (2 * t3 - 3 * t2 + 1) * y1 + (t3 - 2 * t2 + t) * h * m1
              + (-2 * t3 + 3 * t2) * y2 + (t3 - t2) * h * m2
      if y < ylo then y = ylo elseif y > yhi then y = yhi end
      if px then
        if dashed then
          if (dist % (DASH + GAP)) < DASH then Seg(canvas, px, py, x, y, w, r, g, b, col, true) end
          dist = dist + math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
        else
          Seg(canvas, px, py, x, y, w, r, g, b, col, true)
        end
      end
      px, py = x, y
    end
  end
end

-- Subtle volume bars: quantity per price point along the bottom of the plot.
-- Drawn on BACKGROUND so the price line always stays on top. Muted grey, very faint.
local function VolumeBars(canvas, bars, bottom, ph, bw, qmax)
  if not qmax then
    qmax = 0
    for i = 1, #bars do local q = bars[i].q or 0; if q > qmax then qmax = q end end
  end
  if qmax <= 0 then return end
  local volH = ph * 0.40                 -- tallest bar uses ~40% of the plot height
  local r, g, b = TC("sub")              -- dezentes grau-blau aus dem Theme
  for i = 1, #bars do
    local q = bars[i].q or 0
    if q > 0 then
      local t = GetTex(canvas, "BACKGROUND")
      t:SetTexture(WHITE); t:SetVertexColor(r, g, b, 0.22)
      t:SetSize(bw, math.max(1, volH * (q / qmax))); t:ClearAllPoints()
      t:SetPoint("BOTTOM", canvas, "BOTTOMLEFT", bars[i].x, bottom)
    end
  end
end

-- ===== Hover read-out: a dot + a small box per data series at the cursor =====
-- A chart point may carry several read-outs (price / fair / MA / quantity) in
-- point.reads = { { kind, y, l1, l2? }, ... }. Each gets its own marker on the
-- crosshair. "price" stays opaque (keeps the focus); the rest are more
-- transparent. Boxes are de-cluttered vertically so they never overlap.
local READ_STYLE = {
  price = { dot = "teal",   txt = "text",   bg = 0.97, big = true },
  fair  = { dot = "purple", txt = "purple", bg = 0.58 },
  ma    = { dot = "blue",   txt = "blue",   bg = 0.58 },
  qty   = { dot = "sub",    txt = "sub",    bg = 0.50 },
  tbuy  = { dot = "green",  txt = "green",  bg = 0.58 },   -- your buys ("My trades")
  tsell = { dot = "red",    txt = "red",    bg = 0.58 },   -- your sells
  hprice = { dot = "text",  txt = "text",   bg = 0.58 },   -- holding chart: market price
}

local function getReadout(canvas, i)
  canvas._ro = canvas._ro or {}
  local m = canvas._ro[i]
  if not m then
    m = {}
    m.dot = canvas:CreateTexture(nil, "OVERLAY"); m.dot:SetTexture(WHITE); m.dot:SetSize(7, 7)
    m.box = CreateFrame("Frame", nil, canvas, "BackdropTemplate")
    m.box:SetFrameLevel(canvas:GetFrameLevel() + 20)
    m.box:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, tile = false, edgeSize = 1,
      insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    m.t1 = m.box:CreateFontString(nil, "OVERLAY")
    if M.Theme and M.Theme.RegFont then M.Theme.RegFont(m.t1, M.Theme.FONT, 11) else m.t1:SetFont("Fonts\\ARIALN.TTF", 11, "") end
    m.t1:SetPoint("TOP", 0, -3)
    m.t2 = m.box:CreateFontString(nil, "OVERLAY")
    if M.Theme and M.Theme.RegFont then M.Theme.RegFont(m.t2, M.Theme.FONT, 10) else m.t2:SetFont("Fonts\\ARIALN.TTF", 10, "") end
    m.t2:SetPoint("TOP", m.t1, "BOTTOM", 0, -1)
    canvas._ro[i] = m
  end
  return m
end

local function hideHover(canvas)
  if canvas._hvline then canvas._hvline:Hide() end
  if canvas._ro then for _, m in ipairs(canvas._ro) do m.dot:Hide(); m.box:Hide() end end
end

-- Wire a chart canvas once: crosshair + one read-out per series of the nearest
-- point (canvas._pts = { {x, y, reads = {...}}, ... }).
function M.SetupHover(canvas)
  if canvas._hoverWired then return end
  canvas._hoverWired = true
  canvas:EnableMouse(true)
  canvas._hvline = canvas:CreateTexture(nil, "OVERLAY")
  canvas._hvline:SetColorTexture(0.84, 0.79, 0.66, 0.40); canvas._hvline:SetWidth(1); canvas._hvline:Hide()
  canvas:HookScript("OnHide", function(self) hideHover(self) end)
  canvas:SetScript("OnUpdate", function(self)
    local function leave()
      hideHover(self)
      if self._lastHoverDay ~= nil then self._lastHoverDay = nil; if self._onHoverEnd then self._onHoverEnd() end end
    end
    local pts = self._pts
    if not pts or #pts == 0 or not self:IsMouseOver() then leave(); return end
    local CC = M.Theme and M.Theme.C
    local lx = GetCursorPosition() / self:GetEffectiveScale() - self:GetLeft()
    local best, bestd
    for i = 1, #pts do
      local d = pts[i].x - lx; if d < 0 then d = -d end
      if not bestd or d < bestd then bestd = d; best = pts[i] end
    end
    if not best then leave(); return end
    if self._onHover and best.day and best.day ~= self._lastHoverDay then
      self._lastHoverDay = best.day; self._onHover(best)
    end
    local top, bot = self._plotTop or self:GetHeight(), self._plotBot or 0
    local W, H = self:GetWidth(), self:GetHeight()
    self._hvline:ClearAllPoints()
    self._hvline:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", best.x, bot)
    self._hvline:SetHeight(math.max(1, top - bot)); self._hvline:Show()
    local reads = best.reads or { { kind = "price", y = best.y, l1 = best.label, l2 = best.sub } }
    local OFFX, OFFY = 9, 9   -- push the box up-and-right so the data point stays visible

    local function fill(m, a)  -- fill per kind, NO border (by request)
      if CC then m.box:SetBackdropColor(CC.bg2[1], CC.bg2[2], CC.bg2[3], a); m.box:SetBackdropBorderColor(0, 0, 0, 0) end
    end
    if self._compact then
      -- small preview: ONE box = current price (main) + a small line of qty / MA / fair
      local price
      for _, r in ipairs(reads) do if r.kind == "price" then price = r; break end end
      price = price or reads[1]
      local ord = { qty = 1, ma = 2, fair = 3 }
      local extras = {}
      for _, r in ipairs(reads) do if r.kind ~= "price" and ord[r.kind] then extras[#extras + 1] = r end end
      table.sort(extras, function(a, b) return (ord[a.kind] or 9) < (ord[b.kind] or 9) end)
      local parts = {}
      for _, r in ipairs(extras) do parts[#parts + 1] = r.l1 end
      local sub = table.concat(parts, "  \194\183  ")
      local m = getReadout(self, 1)
      local dr, dg, db = TC("teal")
      m.dot:SetVertexColor(dr, dg, db, 1); m.dot:SetSize(7, 7)
      m.dot:ClearAllPoints(); m.dot:SetPoint("CENTER", self, "BOTTOMLEFT", best.x, price.y); m.dot:Show()
      fill(m, READ_STYLE.price.bg)
      m.t1:SetText(price.l1 or ""); m.t1:SetTextColor(TC("text"))
      m.t2:SetText(sub); m.t2:SetShown(sub ~= "")
      if sub ~= "" then m.t2:SetTextColor(TC("sub")) end
      local tw = math.max(m.t1:GetStringWidth(), (sub ~= "" and m.t2:GetStringWidth()) or 0)
      m.box:SetSize(tw + 14, (sub ~= "") and 34 or 20)
      -- sit the box ABOVE the top of the plot so it never covers the graph itself
      local hw = m.box:GetWidth() / 2
      local cx = best.x + OFFX + hw
      if cx + hw > W - 2 then cx = best.x - OFFX - hw end
      if cx - hw < 2 then cx = hw + 2 elseif cx + hw > W - 2 then cx = W - hw - 2 end
      m.box:ClearAllPoints(); m.box:SetPoint("BOTTOM", self, "BOTTOMLEFT", cx, top + 3)
      m.box:Show()
      if self._ro then for i = 2, #self._ro do self._ro[i].dot:Hide(); self._ro[i].box:Hide() end end
      return
    end

    -- big chart: one dot per series at its true value; the boxes form a SORTED,
    -- overlap-free stack beside the crosshair. Method:
    --   1) each box WANTS to sit at its own data height (clear association, same
    --      vertical order as the dots),
    --   2) a two-pass relaxation (top->bottom, then bottom->top) enforces a
    --      minimum gap between neighbours and the stack bounds -- overlap-free by
    --      construction; when space is tight the stack compresses instead,
    --   3) the whole stack moves to the side of the crosshair where the nearby
    --      curve occupies the stack's vertical span the LEAST (graph rising to
    --      the right -> boxes go left, and vice versa), with a hard flip at the
    --      plot edges so boxes never leave the canvas.
    local items = {}
    local maxW = 0
    for idx, r in ipairs(reads) do
      local st = READ_STYLE[r.kind] or READ_STYLE.qty
      local m = getReadout(self, idx)
      local dr, dg, db = TC(st.dot)
      m.dot:SetVertexColor(dr, dg, db, st.big and 1 or 0.9); m.dot:SetSize(st.big and 7 or 6, st.big and 7 or 6)
      m.dot:ClearAllPoints(); m.dot:SetPoint("CENTER", self, "BOTTOMLEFT", best.x, r.y); m.dot:Show()
      fill(m, st.bg)
      m.t1:SetText(r.l1 or ""); m.t1:SetTextColor(TC(st.txt))
      local has2 = r.l2 ~= nil and r.l2 ~= ""
      m.t2:SetText(has2 and r.l2 or ""); m.t2:SetShown(has2)
      if has2 then m.t2:SetTextColor(TC("sub")) end
      local tw = math.max(m.t1:GetStringWidth(), has2 and m.t2:GetStringWidth() or 0)
      local bw, bh = tw + 14, has2 and 34 or 20
      m.box:SetSize(bw, bh)
      if bw > maxW then maxW = bw end
      items[#items + 1] = { m = m, w = bw, h = bh, want = r.y, cy = r.y }
    end
    table.sort(items, function(a, b) return a.want > b.want end)   -- top box first
    local GAP = 3
    local hi, lo = H - 2, 16          -- stack bounds: below the canvas top, above the date row
    local needH = -GAP                -- total height the stack requires
    for _, it in ipairs(items) do needH = needH + it.h + GAP end
    local spanVals = (#items > 1) and (items[1].want - items[#items].want) or 0
    local packed = (#items > 1) and (needH > spanVals + 20)   -- "no room between the graphs"

    -- vertical layout A (cyVal): each box near its own value, two-pass relaxation
    if not packed then
      for i, it in ipairs(items) do   -- pass 1 (top->bottom): drop below the upper neighbour
        local cy = it.want
        if cy + it.h / 2 > hi then cy = hi - it.h / 2 end
        if i > 1 then
          local up = items[i - 1]
          local need = up.cyVal - up.h / 2 - GAP - it.h / 2
          if cy > need then cy = need end
        end
        it.cyVal = cy
      end
      for i = #items, 1, -1 do        -- pass 2 (bottom->top): push back up off the floor
        local it = items[i]
        if it.cyVal - it.h / 2 < lo then it.cyVal = lo + it.h / 2 end
        if i < #items then
          local dn = items[i + 1]
          local need = dn.cyVal + dn.h / 2 + GAP + it.h / 2
          if it.cyVal < need then it.cyVal = need end
        end
        if it.cyVal + it.h / 2 > hi then it.cyVal = hi - it.h / 2 end
      end
    end
    -- vertical layout B (cyAbove): the whole stack above the highest data point
    do
      local cy = items[1].want + OFFY
      for i = #items, 1, -1 do
        local it = items[i]
        it.cyAbove = cy + it.h / 2
        cy = cy + it.h + GAP
      end
      local over = (items[1].cyAbove + items[1].h / 2) - hi
      if over > 0 then for _, it in ipairs(items) do it.cyAbove = it.cyAbove - over end end
    end

    -- SAFEGUARD: candidate layouts (value-aligned / above-stack, left / right of
    -- the crosshair) are SCORED by how much of the surrounding chart they would
    -- cover -- every nearby series point (price, fair, MA, qty, trades) inside a
    -- box counts, and spilling into the right value-label margin is penalized.
    -- The least-covering layout wins; ties prefer value-aligned and the right side.
    local function boxAt(it, side)
      local hw = it.w / 2
      local cx = best.x + side * (OFFX + hw)
      if cx - hw < 2 then cx = hw + 2 elseif cx + hw > W - 2 then cx = W - hw - 2 end
      return cx, hw
    end
    local function scoreOf(mode, side)
      local s = 0
      for _, it in ipairs(items) do
        local cy = (mode == "val") and it.cyVal or it.cyAbove
        local cx, hw = boxAt(it, side)
        local x1, x2 = cx - hw - 2, cx + hw + 2
        local y1, y2 = cy - it.h / 2 - 2, cy + it.h / 2 + 2
        for p = 1, #pts do
          local px = pts[p].x
          if px >= x1 and px <= x2 then
            if pts[p].reads then
              for _, r in ipairs(pts[p].reads) do
                if r.y and r.y >= y1 and r.y <= y2 then s = s + 1 end
              end
            elseif pts[p].y and pts[p].y >= y1 and pts[p].y <= y2 then
              s = s + 1
            end
          end
        end
        if self._plotRight and (cx + hw) > self._plotRight + 4 then s = s + 3 end
      end
      return s
    end
    local cands = {}
    local function addCand(mode, side)
      if side == 1 and best.x + OFFX + maxW > W - 2 then return end
      if side == -1 and best.x - OFFX - maxW < 2 then return end
      cands[#cands + 1] = { mode = mode, side = side }
    end
    if not packed then addCand("val", 1); addCand("val", -1) end
    addCand("above", 1); addCand("above", -1)
    if #cands == 0 then
      cands[1] = { mode = packed and "above" or "val", side = (best.x < W / 2) and 1 or -1 }
    end
    local bestC, bestS
    for _, c in ipairs(cands) do
      local s = scoreOf(c.mode, c.side)
      if not bestS or s < bestS then bestS, bestC = s, c end
    end

    for _, it in ipairs(items) do
      local cy = (bestC.mode == "val") and it.cyVal or it.cyAbove
      local cx = boxAt(it, bestC.side)
      it.m.box:ClearAllPoints()
      it.m.box:SetPoint("CENTER", self, "BOTTOMLEFT", cx, cy)
      it.m.box:Show()
    end
    if self._ro then for i = #reads + 1, #self._ro do self._ro[i].dot:Hide(); self._ro[i].box:Hide() end end
  end)
end

-- ===== Chart timeframe (1W / 1M / 3M / All) =================================
-- config.chartRange ("7" / "30" / "90" / "all"; unset = all) trims every BIG
-- chart to the last N days before its newest data point. Preview cards
-- (canvas._compact) follow their own config.previewRange (set in Settings).
function M.ChartRangeDays()
  local v = M.db and M.db.config and M.db.config.chartRange
  return tonumber(v)   -- nil for "all" / unset
end

function M.PreviewRangeDays()
  local v = M.db and M.db.config and M.db.config.previewRange
  return tonumber(v)   -- nil for "all" / unset
end

local function applyRange(arr, days)
  local n = #arr
  if not days or n == 0 then return arr end
  local cutoff = arr[n].day - days + 1
  local out = {}
  for i = 1, n do if arr[i].day >= cutoff then out[#out + 1] = arr[i] end end
  return out
end

-- A young history (a handful of scan days) would stretch two lonely points to
-- the far edges of the plot, with the volume bars as thin sticks under them.
-- Cap the per-day step instead: the chart hugs the left edge with sensibly
-- sized, sensibly spaced bars and grows rightwards day by day.
-- Returns dayW (px per day), the effective plot width and whether it capped.
local function dayStep(pw, dSpan)
  if dSpan <= 5 and pw / dSpan > 52 then return 52, dSpan * 52, true end
  return pw / dSpan, pw, false
end

-- A flat or near-flat range still gets a readable scale: at least +-5% of the
-- price (one `unit` minimum), centred on the data. A fixed step would blow
-- copper noise up to full height on one item and dwarf a 7s price on another.
local function minSpan(lo, hi, unit)
  local need = math.max(hi * 0.10, unit)
  if hi - lo >= need then return lo, hi end
  local mid = (lo + hi) / 2
  return mid - need / 2, mid + need / 2
end

-- Floor MA shared by the market and the holding chart: a trailing simple MA of
-- the daily lows over `period` calendar days (capped at 20, shrinking on short
-- spans so it still shows). It starts once a full window of history exists.
-- Returns ma[i] (copper) for the indices of arr that have one.
local function FloorMA(arr, dSpan)
  local period = math.min(20, math.max(4, math.floor(dSpan / 3)))
  local ma, dMin = {}, arr[1] and arr[1].day
  for i = 1, #arr do
    if arr[i].day - dMin >= period - 1 then
      local s, c = 0, 0
      for j = i, 1, -1 do
        if arr[i].day - arr[j].day >= period then break end
        s = s + arr[j].low; c = c + 1
      end
      if c > 0 then ma[i] = s / c end
    end
  end
  return ma
end

-- ===== All-time line (Scalable style: thin teal line over the full history) ==
function M.RenderAllTime(canvas, key)
  ResetPools(canvas)
  if not key then return end
  local series = M.GetSeries(key)
  if not series then return end
  local arr = {}
  for day, v in pairs(series) do arr[#arr + 1] = { day = day, low = v.low, cur = v.cur, qty = v.qty or 0 } end
  table.sort(arr, function(a, b) return a.day < b.day end)
  -- big charts follow the global timeframe, preview cards their own setting;
  -- a canvas can pin its own range ("7"/"30"/"90"/"all" - the tooltip chart)
  local rangeDays
  if canvas._rangeOverride then rangeDays = tonumber(canvas._rangeOverride)
  elseif canvas._compact then rangeDays = M.PreviewRangeDays()
  else rangeDays = M.ChartRangeDays() end
  arr = applyRange(arr, rangeDays)
  local n = #arr
  if n == 0 then Label(canvas, canvas:GetWidth() / 2, canvas:GetHeight() / 2, "No data", "CENTER", TC("muted")); return end

  -- 1W intraday: per-scan points from the intraday tail (big chart only).
  -- Every intraday day also has a daily row (CommitScan writes both), so the
  -- day list in arr stays the backbone; lastOf marks each day's newest scan.
  local ipts, covered, lastOf
  if not canvas._compact and M.ChartRangeDays() == 7 and M.db and M.db.intra then
    local ist = M.db.intra[M.RealmKey()]
    local st = ist and ist[key]
    if st and st[1] then
      local cutoff = arr[n].day - 6
      for i = 1, #st do
        local t = (st[i].ts - M.C.SCAN_DAY_0) / 86400
        local d = math.floor(t)
        if d >= cutoff then
          ipts = ipts or {}
          ipts[#ipts + 1] = { day = d, t = t, ts = st[i].ts, low = st[i].low, qty = st[i].qty or 0 }
        end
      end
      if ipts and #ipts < 2 then ipts = nil end
      if ipts then
        covered, lastOf = {}, {}
        for _, e in ipairs(ipts) do covered[e.day] = true; lastOf[e.day] = e end
      end
    end
  end

  -- the newest day's point is the CURRENT price (that day's latest scan, the
  -- number the headers show); older days plot their daily low. A 1W intraday
  -- day already ends on its own last scan.
  for i = 1, n do arr[i].px = arr[i].low end
  if arr[n].cur and not (lastOf and lastOf[arr[n].day]) then arr[n].px = arr[n].cur end

  local vmin, vmax = math.huge, -math.huge
  for _, p in ipairs(arr) do
    local g = p.px / 10000
    if g < vmin then vmin = g end
    if g > vmax then vmax = g end
  end
  if ipts then
    for _, p in ipairs(ipts) do
      local g = p.low / 10000
      if g < vmin then vmin = g end
      if g > vmax then vmax = g end
    end
  end
  -- overlays NEAR the data (within 30% outside its range) are pulled into the
  -- scale so they draw at their true height; a far-off value stays out -- one
  -- bargain flip or a mistyped limit would squash the price line flat and pile
  -- the edge labels into each other
  local lo0, hi0 = vmin, vmax
  local function widen(g)
    if g >= lo0 * 0.7 and g <= hi0 * 1.3 then
      if g < vmin then vmin = g end
      if g > vmax then vmax = g end
    end
  end
  -- your trade dots draw at their realized UNIT price; sells usually clear
  -- ABOVE the daily low the line is built from. Big chart only (previews show
  -- no dots, tighter scale).
  if M.chartTrades ~= false and not canvas._compact and M.db and M.db.trade and M.db.trade.log then
    local id = (M.BaseID and M.BaseID(key)) or tonumber(key)
    if id then
      local realm = M.RealmKey()
      local d0, d1 = arr[1].day, arr[n].day
      for _, e in ipairs(M.db.trade.log) do
        if e.id == id and e.realm == realm and (e.kind == "sold" or e.kind == "bought")
           and (e.gross or 0) > 0 and e.day and e.day >= d0 and e.day <= d1 then
          local cnt = (e.count and e.count > 0) and e.count or 1
          widen((e.gross / cnt) / 10000)
        end
      end
    end
  end
  -- price-alert limits (Settings "Alert lines in charts"). Big chart only --
  -- previews and the tooltip chart stay clean.
  local alertRec
  if not canvas._compact and not canvas._rangeOverride
     and M.db and M.db.config and M.db.config.alertLines ~= false and M.db.alerts then
    local ar = M.db.alerts[M.RealmKey()]
    local a = ar and ar[tostring(key)]
    if a and (a.below or a.above) then
      alertRec = a
      if a.below then widen(a.below / 10000) end
      if a.above then widen(a.above / 10000) end
    end
  end
  -- Fair-price TRAILING series (sell-odds ratio applied to the trailing 7-day
  -- floor, so it drifts with the market level). The "Fair" toggle skips the
  -- series here, which drops the line, its read-outs and its label below.
  local fairByDay = {}
  if M.chartFair ~= false and M.FairSeries then
    for _, e in ipairs(M.FairSeries(series, key)) do fairByDay[e.day] = e.fair end
    for i = 1, n do
      local fv = fairByDay[arr[i].day]
      if fv then widen(fv / 10000) end
    end
  end
  -- what it costs to MAKE (Crafting tab, newest prices, make or buy per
  -- material): a dashed mint level line in the big chart. Settings "Craft
  -- lines" turns it off together with the tooltip lines, the Crafting (beta)
  -- switch together with everything crafting.
  local craftNow
  if not canvas._compact and not canvas._rangeOverride and M.CraftCost
     and not (M.db and M.db.config and M.db.config.tooltipCraft == false)
     and (not M.CraftingOn or M.CraftingOn()) then
    local cid = (M.BaseID and M.BaseID(key)) or tonumber(key)
    local cc = cid and M.CraftCost(cid)
    if cc and cc.now and cc.now > 0 then
      craftNow = cc.now
      widen(craftNow / 10000)
    end
  end
  vmin, vmax = minSpan(vmin, vmax, 0.0001)
  local pad = (vmax - vmin) * 0.15
  vmin, vmax = math.max(0, vmin - pad), vmax + pad

  local W, H = canvas:GetWidth(), canvas:GetHeight()
  local left, right, top, bottom = 10, 56, 14, 18
  local pw, ph = W - left - right, H - top - bottom
  -- TIME-based X axis: missing scan days now show as real horizontal gaps
  -- (the old index-based axis hid them and the downsample made duplicate points).
  local dMin, dMax = arr[1].day, arr[n].day
  -- float span: intraday points sit at their time of day between the day marks
  local tMin, tMax = dMin, dMax
  if ipts then
    if ipts[1].t < tMin then tMin = ipts[1].t end
    if ipts[#ipts].t > tMax then tMax = ipts[#ipts].t end
  end
  local dSpan = math.max(1, tMax - tMin)
  local dayW, capped
  dayW, pw, capped = dayStep(pw, dSpan)
  local function X(day) return left + (day - tMin) * dayW end
  local function Y(g) return bottom + (g - vmin) / (vmax - vmin) * ph end
  local function inScale(g) return g >= vmin and g <= vmax end
  local function clampY(g) local y = Y(g); if y < bottom then y = bottom elseif y > bottom + ph then y = bottom + ph end return y end

  -- one x and one quantity per day, shared by its bar, line point, Fair/MA
  -- vertices and read-outs: a 1W day covered by intraday scans sits at its
  -- LAST scan with that scan's quantity (the daily row would sit at midnight
  -- with the daily MIN and the day's peak supply)
  local dayX, dayQ = {}, {}
  for i = 1, n do
    local lp = lastOf and lastOf[arr[i].day]
    dayX[i] = lp and X(lp.t) or X(arr[i].day)
    dayQ[i] = lp and (lp.qty or 0) or (arr[i].qty or 0)
  end
  local qmax, volH = 0, ph * 0.40
  for i = 1, n do if dayQ[i] > qmax then qmax = dayQ[i] end end
  if ipts then for _, e in ipairs(ipts) do if (e.qty or 0) > qmax then qmax = e.qty end end end
  local function qtyY(q) return (qmax > 0) and (bottom + volH * (q / qmax)) or bottom end

  -- subtle volume bars (quantity per day) at each day's real time position
  local bars = {}
  for i = 1, n do bars[i] = { x = dayX[i], q = dayQ[i] } end
  VolumeBars(canvas, bars, bottom, ph, capped and 18 or math.max(1.5, math.min(10, dayW)), qmax)

  -- hover points = the real scan days, each carrying price + fair + qty read-outs
  local pts = {}
  for i = 1, n do
    local d = arr[i].day
    local lp = lastOf and lastOf[d]
    local price = lp and lp.low or arr[i].px
    local priceY = Y(price / 10000)
    local when = lp and ("  " .. date("%H:%M", lp.ts)) or ""
    local reads = { { kind = "price", y = priceY,
      l1 = M.DayLabel(d) .. when .. "  \194\183  " .. M.MoneyPlain(price) } }
    local fv = fairByDay[d]
    if fv then
      local fGold = fv / 10000
      reads[#reads + 1] = { kind = "fair", y = clampY(fGold),
        l1 = "Fair  " .. M.MoneyPlain(fv) .. (inScale(fGold) and "" or "  \194\183  off scale") }
    end
    reads[#reads + 1] = { kind = "qty", y = qtyY(dayQ[i]), l1 = "Qty  " .. math.floor(dayQ[i] + 0.5) }
    pts[i] = { x = dayX[i], y = priceY, reads = reads }
  end

  -- One smooth line through all points; segments that bridge missing days are
  -- dashed ALONG the same curve, so solid<->dashed transitions stay seamless.
  local lr, lg, lb = TC("teal")
  for i = 1, n do pts[i].dash = (i > 1) and ((arr[i].day - arr[i - 1].day) > 1) or false end
  if ipts then
    -- line through the day points (already at each covered day's last scan)
    -- plus every earlier scan of each day
    local linePts = {}
    for i = 1, n do linePts[#linePts + 1] = { x = pts[i].x, y = pts[i].y, day = arr[i].day } end
    for _, e in ipairs(ipts) do
      if lastOf[e.day] ~= e then
        linePts[#linePts + 1] = { x = X(e.t), y = Y(e.low / 10000), day = e.day }
      end
    end
    table.sort(linePts, function(a, b) return a.x < b.x end)
    for i = 1, #linePts do
      linePts[i].dash = (i > 1) and ((linePts[i].day - linePts[i - 1].day) > 1) or false
    end
    SmoothLine(canvas, linePts, 1.6, lr, lg, lb, 1, bottom, bottom + ph, 0.5)
  else
    SmoothLine(canvas, pts, 1.6, lr, lg, lb, 1, bottom, bottom + ph, 0.5)
  end

  -- fair-price line: the trailing recency-weighted value, so it moves over
  -- time. Off-scale days break the line instead of pinning it to an edge,
  -- where it would read as a price it never had.
  do
    local fr, fg, fb = TC("purple")
    local run = {}
    local function flush()
      if #run >= 2 then SmoothLine(canvas, run, 1.3, fr, fg, fb, 0.6, bottom, bottom + ph, 0.6) end
      run = {}
    end
    for i = 1, n do
      local fv = fairByDay[arr[i].day]
      if fv then
        if inScale(fv / 10000) then run[#run + 1] = { x = pts[i].x, y = Y(fv / 10000) } else flush() end
      end
    end
    flush()
  end

  -- YOUR trades as dots ("My trades" toggle): each buy (GREEN, your entry) and
  -- sale (RED, your exit) at its day and realized UNIT price -- see at a glance
  -- where in the price range you actually traded. Hovering a day adds one
  -- aggregated read-out per side (total qty + volume-weighted avg unit price; a
  -- Chronoboon session can be 19 single buys -- one line, not 19 boxes). A small
  -- legend appears while dots are shown. Big chart only; previews stay clean.
  -- The Y scale is stretched above to include trade prices; clampY stays as a
  -- safety net only.
  local legend = false
  if M.chartTrades ~= false and not canvas._compact and M.db and M.db.trade then
    local id = (M.BaseID and M.BaseID(key)) or tonumber(key)
    if id then
      local realm = M.RealmKey()
      local gr, gg, gb = TC("green")
      local rr, rg, rb = TC("red")
      local agg = {}          -- day -> { b|s = { qty, cost } }
      local marks = {}        -- individual events, drawn after max qty is known
      local drew, maxCnt = false, 0
      for _, e in ipairs(M.db.trade.log or {}) do
        if e.id == id and e.realm == realm and (e.kind == "sold" or e.kind == "bought")
           and (e.gross or 0) > 0 and e.day and e.day >= dMin and e.day <= dMax then
          local cnt = (e.count and e.count > 0) and e.count or 1
          -- with intraday points active, place the dot at the trade's actual time
          local tx = e.day
          if ipts and e.ts then
            tx = (e.ts - M.C.SCAN_DAY_0) / 86400
            if tx < tMin then tx = tMin elseif tx > tMax then tx = tMax end
          end
          -- a trade the scale block left out (too far off) draws no dot: pinned
          -- to the plot edge it would read as a price it never had -- the day's
          -- hover read-out below still carries the numbers
          local g = (e.gross / cnt) / 10000
          if inScale(g) then
            marks[#marks + 1] = { x = X(tx), y = clampY(g),
                                  cnt = cnt, buy = (e.kind == "bought") }
            if cnt > maxCnt then maxCnt = cnt end
          end
          drew = true
          local a = agg[e.day]; if not a then a = {}; agg[e.day] = a end
          local k = (e.kind == "bought") and "b" or "s"
          local t = a[k]; if not t then t = { qty = 0, cost = 0 }; a[k] = t end
          t.qty = t.qty + cnt
          t.cost = t.cost + e.gross
        end
      end
      -- dot size scales with the traded amount (6..11 px), so big lots stand out
      for _, mk in ipairs(marks) do
        local sz = (maxCnt > 0) and (6 + 5 * math.sqrt(mk.cnt / maxCnt)) or 8
        if mk.buy then
          RoundDot(canvas, mk.x, mk.y, sz, gr, gg, gb)
        else
          RoundDot(canvas, mk.x, mk.y, sz, rr, rg, rb)
        end
      end
      if drew then
        -- hover read-outs at the aggregated avg-price height of each traded day
        local ptsByDay = {}
        for i = 1, n do ptsByDay[arr[i].day] = pts[i] end
        for day, a in pairs(agg) do
          local p = ptsByDay[day]
          if not p then
            -- traded on a day with NO scan: give the dot its own hover point,
            -- otherwise the crosshair skips straight over it
            p = { x = X(day), y = bottom, day = day, reads = {} }
            pts[#pts + 1] = p
          end
          if p.reads then
            if a.b and a.b.qty > 0 then
              p.reads[#p.reads + 1] = { kind = "tbuy", y = clampY((a.b.cost / a.b.qty) / 10000),
                l1 = string.format("Bought x%d  \194\183  %s", a.b.qty, M.MoneyPlain(a.b.cost / a.b.qty)) }
            end
            if a.s and a.s.qty > 0 then
              p.reads[#p.reads + 1] = { kind = "tsell", y = clampY((a.s.cost / a.s.qty) / 10000),
                l1 = string.format("Sold x%d  \194\183  %s", a.s.qty, M.MoneyPlain(a.s.cost / a.s.qty)) }
            end
            if p.y == bottom and p.reads[1] then p.y = p.reads[1].y end
          end
        end
        -- compact legend along the top edge of the plot (only while dots show)
        if marks[1] then
          local ly = bottom + ph + 2
          RoundDot(canvas, left + 6, ly, 8, gr, gg, gb)
          local f1 = Label(canvas, left + 12, ly, "Buys", "LEFT", TC("sub"))
          local lx2 = left + 12 + (f1:GetStringWidth() or 26) + 14
          RoundDot(canvas, lx2, ly, 8, rr, rg, rb)
          Label(canvas, lx2 + 6, ly, "Sells", "LEFT", TC("sub"))
          legend = true
        end
      end
    end
  end

  -- optional moving-average overlay (broker style), drawn with the same
  -- monotone curve as the price line (no x-overshoot)
  local maLabelY
  if M.chartMA then
    local ma = FloorMA(arr, dSpan)
    local mapts = {}
    for i = 1, n do
      if ma[i] then
        local maY = Y(ma[i] / 10000)
        mapts[#mapts + 1] = { x = pts[i].x, y = maY }
        pts[i].reads[#pts[i].reads + 1] = { kind = "ma", y = maY, l1 = "Floor MA  " .. M.MoneyPlain(ma[i]) }
      end
    end
    if #mapts >= 2 then
      local ar, ag, ab = TC("blue")   -- cool blue: gold is reserved for the price line
      SmoothLine(canvas, mapts, 1.4, ar, ag, ab, 0.5, bottom, bottom + ph, 0.5)
      maLabelY = mapts[#mapts].y
    end
  end

  -- remaining intraday scans as extra hover points, appended AFTER the MA and
  -- trade blocks so pts[i] stays index-parallel to arr for those
  if ipts then
    for _, e in ipairs(ipts) do
      if lastOf[e.day] ~= e then
        local py = Y(e.low / 10000)
        local reads = { { kind = "price", y = py,
          l1 = M.DayLabel(e.day) .. "  " .. date("%H:%M", e.ts) .. "  \194\183  " .. M.MoneyPlain(e.low) } }
        reads[#reads + 1] = { kind = "qty", y = qtyY(e.qty or 0), l1 = "Qty  " .. math.floor((e.qty or 0) + 0.5) }
        pts[#pts + 1] = { x = X(e.t), y = py, day = e.day, reads = reads }
      end
    end
  end

  canvas._pts, canvas._plotBot, canvas._plotTop, canvas._plotRight = pts, bottom, bottom + ph, left + pw
  M.SetupHover(canvas)

  -- right edge: current value at the line end (Midas gold), the scale bounds
  -- and the Fair / Floor MA line labels, each at least 11px from the others; a
  -- line label may shift a few px off its line end to find room
  local yCur = pts[n].y
  local mr, mg, mb = TC("muted")
  Dot(canvas, pts[n].x, yCur, 4, lr, lg, lb)
  local curPx = (lastOf and lastOf[arr[n].day]) and lastOf[arr[n].day].low or arr[n].px
  Label(canvas, left + pw + 8, yCur, M.MoneyPlain(curPx), "LEFT", lr, lg, lb)
  local taken = { yCur }
  local function sideLabel(y, txt, r, g, b, shifts)
    for _, dy in ipairs(shifts or { 0 }) do
      local yy = y + dy
      local free = yy >= bottom - 2 and yy <= bottom + ph + 2
      for _, t in ipairs(taken) do if math.abs(t - yy) < 11 then free = false; break end end
      if free then
        taken[#taken + 1] = yy
        Label(canvas, left + pw + 8, yy, txt, "LEFT", r, g, b)
        return
      end
    end
  end
  local NUDGE = { 0, 6, -6, 11, -11, 16, -16 }
  sideLabel(bottom + ph, M.MoneyPlain(vmax * 10000), mr, mg, mb)
  sideLabel(bottom, M.MoneyPlain(vmin * 10000), mr, mg, mb)
  local fLast = fairByDay[arr[n].day]
  local fOff = fLast and not inScale(fLast / 10000)
  if fLast and not fOff then
    local fr, fg, fb = TC("purple")
    sideLabel(Y(fLast / 10000), "Fair", fr, fg, fb, NUDGE)
  end
  if maLabelY then
    local ar, ag, ab = TC("blue")
    sideLabel(maLabelY, "Floor MA", ar, ag, ab, NUDGE)
  end

  -- off-scale notes stack inward from the plot edges (the top stack starts
  -- under the Buys/Sells legend)
  local noteTop, noteBot = bottom + ph - (legend and 10 or 6), bottom + 7
  local function edgeNote(txt, above, r, g, b)
    local y
    if above then y = noteTop; noteTop = noteTop - 11 else y = noteBot; noteBot = noteBot + 11 end
    Label(canvas, left + 4, y, txt, "LEFT", r, g, b)
  end
  if fOff and not canvas._compact then
    local fr, fg, fb = TC("purple")
    edgeNote("Fair  " .. M.MoneyPlain(fLast) .. "  \194\183  off scale", fLast / 10000 > vmax, fr, fg, fb)
  end

  -- price-alert limit lines: dashed horizontals at the below (green, the buy
  -- side) and above (gold, the sell side) limits, labelled at the left end.
  if alertRec then
    local function alertLine(v, word, cr, cg, cb)
      local g = v / 10000
      if not inScale(g) then
        -- limit outside the scale (the widen rule above left it out): say so
        -- at the edge instead of silently drawing nothing - a mistyped 7g50
        -- limit on a 7s item looks exactly like a missing line otherwise
        edgeNote("ALERT " .. word .. "  " .. M.MoneyPlain(v) .. "  \194\183  off scale", g > vmax, cr, cg, cb)
        return
      end
      local ay = Y(g)
      DashSeg(canvas, left, ay, left + pw, ay, 1.2, cr, cg, cb, 0.55)
      -- the text sits above its line, below it right under the plot ceiling
      local ty = (ay + 14 > bottom + ph) and (ay - 7) or (ay + 7)
      Label(canvas, left + 4, ty, "ALERT " .. word .. "  " .. M.MoneyPlain(v), "LEFT", cr, cg, cb)
    end
    if alertRec.below then local r2, g2, b2 = TC("green"); alertLine(alertRec.below, "below", r2, g2, b2) end
    if alertRec.above then local r2, g2, b2 = TC("accent"); alertLine(alertRec.above, "above", r2, g2, b2) end
  end

  -- crafting cost level (see the scale block): labelled "Crafted" at the right
  if craftNow then
    local cr, cg, cb = TC("mint")
    local g = craftNow / 10000
    if inScale(g) then
      local cy = Y(g)
      DashSeg(canvas, left, cy, left + pw, cy, 1.2, cr, cg, cb, 0.6)
      sideLabel(cy, "Crafted", cr, cg, cb, NUDGE)
    else
      edgeNote("Crafted  " .. M.MoneyPlain(craftNow) .. "  \194\183  off scale", g > vmax, cr, cg, cb)
    end
  end

  -- date labels (bottom), evenly spaced by TIME; on a capped (left-hugging)
  -- chart only first + last, both LEFT-anchored so they cannot collide.
  -- Placement runs on the INT day span (labels name whole days even when the
  -- intraday tail stretches the plot span to a float).
  local ldSpan = dMax - dMin
  local labelN = (dMax == dMin) and 1 or (capped and 2 or math.max(2, math.min(4, ldSpan + 1)))
  for k = 0, labelN - 1 do
    local day = (labelN <= 1) and dMin or (dMin + math.floor(ldSpan * k / (labelN - 1) + 0.5))
    local anchor = (k == 0) and "LEFT" or ((k == labelN - 1) and (capped and "LEFT" or "RIGHT") or "CENTER")
    local lx = X(day)
    if lx < left then lx = left end
    Label(canvas, lx, bottom - 12, M.DayLabel(day), anchor, TC("muted"))
  end
end

-- Every item chart (big + mini detail) goes through this. The former Weekday
-- overlay mode was removed in 1.0.10 -- it never earned its place next to the
-- full time axis, so this is a plain alias now.
function M.RenderItemChart(canvas, key)
  M.RenderAllTime(canvas, key)
end

-- ===== Net worth history (Scalable-style total line) ========================
-- Asset class -> theme color token. Single source of truth (UI reuses it for the
-- BY ASSET CLASS bars, so list and chart always match).
M.CLASS_COLOR = {
  Money = "accent", Crafting = "mint", Consumables = "green",
  Gear = "blue", Recipes = "red", Auctions = "purple", Other = "muted",
}

-- Net-worth history on a TIME axis (missing snapshot days become dashed gaps,
-- exactly like the market chart). ck = nil -> the account (total line + class
-- split); ck = a character key -> that character's line (+ its class split,
-- recorded from 1.0.8 on); clsName set -> the history of ONE asset class
-- (single line in the class color, no stack). The class split is drawn as
-- CUMULATIVE stacked per-day bars under the line.
function M.RenderNetWorthChart(canvas, ck, clsName)
  ResetPools(canvas)
  local hist = M.NWHist()
  local arr = {}
  if hist then
    for day, snap in pairs(hist) do
      local v, cls
      if clsName then
        v = (type(snap.c) == "table") and snap.c[clsName] or nil
      elseif ck then
        v = snap.chars and snap.chars[ck]
        cls = snap.cc and snap.cc[ck]
      else
        v = snap.t or 0
        cls = (type(snap.c) == "table") and snap.c or nil
      end
      if v then arr[#arr + 1] = { day = day, v = v, cls = cls } end
    end
  end
  table.sort(arr, function(x, y) return x.day < y.day end)
  arr = applyRange(arr, M.ChartRangeDays())
  local n = #arr
  -- 1W intraday: splice the intraday tail (several points per day) into the
  -- account-wide total line. Days covered by intraday points drop their daily
  -- LINE point (it would sit at midnight with the end-of-day value); the class
  -- stack bars below stay daily. Intraday points carry t (float day) for the
  -- X axis and keep day (int) so hover drill-downs stay day-based.
  local ipts
  if not ck and not clsName and M.ChartRangeDays() == 7 and M.NWIntra then
    local ni = M.NWIntra()
    if ni[1] then
      local newest = (n > 0) and arr[n].day
        or math.floor((ni[#ni].ts - M.C.SCAN_DAY_0) / 86400)
      local cutoff = newest - 6
      for i = 1, #ni do
        local t = (ni[i].ts - M.C.SCAN_DAY_0) / 86400
        local d = math.floor(t)
        if d >= cutoff then
          ipts = ipts or {}
          ipts[#ipts + 1] = { day = d, t = t, ts = ni[i].ts, v = ni[i].t, cls = ni[i].c }
        end
      end
      if ipts and #ipts < 2 then ipts = nil end
    end
  end
  local plotArr = arr
  local iByDay
  if ipts then
    local covered = {}
    iByDay = {}
    for _, e in ipairs(ipts) do
      covered[e.day] = true
      local l = iByDay[e.day]
      if not l then l = {}; iByDay[e.day] = l end
      l[#l + 1] = e
    end
    plotArr = {}
    for _, e in ipairs(arr) do if not covered[e.day] then plotArr[#plotArr + 1] = e end end
    for _, e in ipairs(ipts) do plotArr[#plotArr + 1] = e end
    table.sort(plotArr, function(x, y) return (x.t or x.day) < (y.t or y.day) end)
  end
  local pn = #plotArr
  if pn == 0 then
    Label(canvas, canvas:GetWidth() / 2, canvas:GetHeight() / 2,
      (ck and "no history for this character yet") or "No history yet \226\128\147 a snapshot is saved each day",
      "CENTER", TC("muted"))
    return
  end
  if pn == 1 then
    Label(canvas, canvas:GetWidth() / 2, canvas:GetHeight() / 2 + 4, M.MoneyPlain(plotArr[1].v), "CENTER", TC("teal"))
    Label(canvas, canvas:GetWidth() / 2, canvas:GetHeight() / 2 - 14, "history builds up from here", "CENTER", TC("muted"))
    return
  end
  local vmin, vmax = math.huge, -math.huge
  for _, p2 in ipairs(plotArr) do
    local g = p2.v / 10000
    if g < vmin then vmin = g end
    if g > vmax then vmax = g end
  end
  if ipts then
    -- covered days lost their LINE point but still draw their class stack up
    -- to the daily snapshot value - keep that value inside the scale, or the
    -- whole stack of such a day gets clamped away below vmin
    for _, p2 in ipairs(arr) do
      local g = p2.v / 10000
      if g < vmin then vmin = g end
      if g > vmax then vmax = g end
    end
  end
  vmin, vmax = minSpan(vmin, vmax, 0.0001)
  local pad = (vmax - vmin) * 0.12
  vmin, vmax = math.max(0, vmin - pad), vmax + pad
  local W, H = canvas:GetWidth(), canvas:GetHeight()
  -- top pad 18: the class legend sits ABOVE the plot ceiling (it used to poke
  -- 4px into the plot, so the total line ran through the legend text)
  local left, right, top, bottom = 10, 70, 18, 20
  local pw, ph = W - left - right, H - top - bottom
  -- float span: intraday points sit at their time of day between the day marks
  local tMin = plotArr[1].t or plotArr[1].day
  local tMax = plotArr[pn].t or plotArr[pn].day
  local dSpan = math.max(1, tMax - tMin)
  local dayW, capped
  dayW, pw, capped = dayStep(pw, dSpan)
  local function X(day) return left + (day - tMin) * dayW end
  local function Y(g) return bottom + (g - vmin) / (vmax - vmin) * ph end
  -- cumulative class stack per day (bars under the line, clamped to the plot).
  -- Bars and legend use the SAME pre-blended shade (transparency would make them
  -- look like two different palettes).
  local order = M.ASSET_ORDER or { "Money" }
  local bw = math.max(2, math.min(16, dayW * 0.6))
  local BG = (M.Theme and M.Theme.C.bg0) or { 0.05, 0.06, 0.08 }
  local MIX = 0.45
  local function stackColor(name)
    local cr, cg, cb = TC(M.CLASS_COLOR[name] or "muted")
    return cr * MIX + BG[1] * (1 - MIX),
           cg * MIX + BG[2] * (1 - MIX),
           cb * MIX + BG[3] * (1 - MIX)
  end
  local hasCls = false
  local function stack(cx, bw3, cmap)
    if cx < left then cx = left end   -- a covered day can sit left of tMin
    local acc = 0
    for _, name in ipairs(order) do
      local v = cmap[name]
      if v and v > 0 then
        local y0 = Y(acc / 10000)
        local y1 = Y((acc + v) / 10000)
        if y0 < bottom then y0 = bottom end
        if y1 > bottom + ph then y1 = bottom + ph end
        if y1 > y0 + 0.5 then
          local tex = GetTex(canvas, "BACKGROUND")
          tex:SetTexture(WHITE)
          local cr, cg, cb = stackColor(name)
          tex:SetVertexColor(cr, cg, cb, 1)
          tex:ClearAllPoints()
          tex:SetSize(bw3, y1 - y0)
          tex:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", cx - bw3 / 2, y0)
        end
        acc = acc + v
      end
    end
  end
  for _, p2 in ipairs(arr) do
    if p2.cls then
      hasCls = true
      local ip = iByDay and iByDay[p2.day]
      if ip then
        -- covered day: one slim stack per intraday point (its own class split
        -- where recorded); points from before the split was stored fall back
        -- to ONE daily stack at the day's last intraday position
        local n2 = 0
        for _, e in ipairs(ip) do if e.cls then n2 = n2 + 1 end end
        if n2 > 0 then
          local ibw = math.max(2, math.min(16, dayW / math.max(1, n2) - 1))
          for _, e in ipairs(ip) do if e.cls then stack(X(e.t), ibw, e.cls) end end
        else
          stack(X(ip[#ip].t), bw, p2.cls)
        end
      else
        stack(X(p2.day), bw, p2.cls)
      end
    end
  end
  if hasCls then
    local lx = left + 4
    local newest
    for i = n, 1, -1 do if arr[i].cls then newest = arr[i].cls; break end end
    for _, name in ipairs(order) do
      if newest and (newest[name] or 0) > 0 then
        local cr, cg, cb = stackColor(name)
        Dot(canvas, lx, bottom + ph + 8, 5, cr, cg, cb)
        local fs = Label(canvas, lx + 6, bottom + ph + 8, name, "LEFT", TC("sub"))
        lx = lx + 14 + (fs:GetStringWidth() or 40)
      end
    end
  end
  local pts = {}
  for i, p2 in ipairs(plotArr) do
    local lab = M.DayLabel(p2.day)
      .. (p2.ts and ("  " .. date("%H:%M", p2.ts)) or "")
      .. "  \194\183  " .. M.MoneyPlain(p2.v)
    pts[#pts + 1] = { x = X(p2.t or p2.day), y = Y(p2.v / 10000), day = p2.day, label = lab }
    pts[#pts].dash = (i > 1) and ((p2.day - plotArr[i - 1].day) > 1) or false
  end
  local lr, lg, lb = TC(clsName and (M.CLASS_COLOR[clsName] or "teal") or "teal")
  SmoothLine(canvas, pts, 1.8, lr, lg, lb, 1, bottom, bottom + ph, 0.5)
  canvas._pts, canvas._plotBot, canvas._plotTop, canvas._plotRight = pts, bottom, bottom + ph, left + pw
  M.SetupHover(canvas)
  local yCur = pts[pn].y
  local mr, mg, mb = TC("muted")
  if math.abs(yCur - (bottom + ph)) > 11 then Label(canvas, left + pw + 8, bottom + ph, M.MoneyPlain(vmax * 10000), "LEFT", mr, mg, mb) end
  if math.abs(yCur - bottom) > 11 then Label(canvas, left + pw + 8, bottom, M.MoneyPlain(vmin * 10000), "LEFT", mr, mg, mb) end
  Dot(canvas, pts[pn].x, yCur, 4, lr, lg, lb)
  Label(canvas, left + pw + 8, yCur, M.MoneyPlain(plotArr[pn].v), "LEFT", lr, lg, lb)
  -- date labels evenly spaced by TIME on whole days, like the market chart
  local dMin, dMax = plotArr[1].day, plotArr[pn].day
  local ldSpan = dMax - dMin
  local labelN = (dMax == dMin) and 1 or (capped and 2 or math.max(2, math.min(4, ldSpan + 1)))
  for k = 0, labelN - 1 do
    local day = (labelN <= 1) and dMin or (dMin + math.floor(ldSpan * k / (labelN - 1) + 0.5))
    local anchor = (k == 0) and "LEFT" or ((k == labelN - 1) and (capped and "LEFT" or "RIGHT") or "CENTER")
    local lx = X(day)
    if lx < left then lx = left end
    Label(canvas, lx, bottom - 12, M.DayLabel(day), anchor, TC("muted"))
  end
end

-- ===== Holding history (one item you own): dual-scale combined chart ========
-- ONE plot, two y scales: the item's market PRICE on the LEFT scale (gold line)
-- and the VALUE of your holding (that day's quantity x Fair) on the RIGHT
-- scale (teal line), overlaid. Your per-day quantity shows as faint bars along
-- the bottom and your buys/sells as green/red dots at their realized prices
-- (size scales with the traded amount).
--
-- Quantities are carried across ALL calendar days -- trades that happened on
-- days without a scan still move the quantity. Across scan gaps the VALUE line
-- stays solid when the quantity is unchanged (only the price is interpolated);
-- it is dashed when the quantity changed inside the gap. The price line is
-- dashed across every scan gap (no market data there).
function M.RenderHoldingChart(canvas, key, qty)
  ResetPools(canvas)
  local series = key and M.GetSeries(key)
  -- qty 0 is fine when snapshots know the item (a sold-out mover): the
  -- backwards reconstruction re-anchors on iq and shows the former holding
  local hasIq = false
  if qty == 0 then
    local id = (M.BaseID and M.BaseID(key)) or tonumber(key)
    for _, s in pairs(M.NWHist()) do
      if type(s) == "table" and s.iq and id and s.iq[id] then hasIq = true; break end
    end
  end
  if not series or not qty or (qty <= 0 and not hasIq) then
    Label(canvas, canvas:GetWidth() / 2, canvas:GetHeight() / 2, "No market data", "CENTER", TC("muted"))
    return
  end
  local arr = {}
  for day, v in pairs(series) do
    if v.low then arr[#arr + 1] = { day = day, low = v.low } end
  end
  table.sort(arr, function(x, y) return x.day < y.day end)
  arr = applyRange(arr, M.ChartRangeDays())
  local n = #arr
  if n == 0 then
    Label(canvas, canvas:GetWidth() / 2, canvas:GetHeight() / 2, "No market data", "CENTER", TC("muted"))
    return
  end
  -- trades: per-day aggregates (dots + hover) and quantity deltas (reconstruction)
  local id = (M.BaseID and M.BaseID(key)) or tonumber(key)
  local hist = M.NWHist()
  local delta, tagg = {}, {}
  if id and M.db and M.db.trade and M.db.trade.log then
    local realm = M.RealmKey()
    for _, e in ipairs(M.db.trade.log) do
      if e.id == id and e.realm == realm and e.day and (e.count or 0) > 0 then
        if e.kind == "bought" or e.kind == "received" then delta[e.day] = (delta[e.day] or 0) + e.count
        elseif e.kind == "sold" or e.kind == "given" then delta[e.day] = (delta[e.day] or 0) - e.count end
        if (e.kind == "bought" or e.kind == "sold") and (e.gross or 0) > 0 then
          local a = tagg[e.day]; if not a then a = {}; tagg[e.day] = a end
          local k = (e.kind == "bought") and "b" or "s"
          local t = a[k]; if not t then t = { qty = 0, cost = 0 }; a[k] = t end
          t.qty = t.qty + e.count
          t.cost = t.cost + e.gross
        end
      end
    end
  end
  -- unit value per day, the way net worth values the item today: that day's
  -- Fair (the trailing series ends exactly on today's Fair), or the flat
  -- vendor value net worth falls back to for untrusted vendor items
  local fairSeries = M.FairSeries and M.FairSeries(series, key) or {}
  local unitOf = {}
  do
    local unitNow = M.ItemValue and M.ItemValue(key)
    local mNow = M.Metrics(series, key)
    if not unitNow or (mNow and mNow.fair and math.abs(unitNow - mNow.fair) < 0.5) then
      for _, e in ipairs(fairSeries) do unitOf[e.day] = e.fair end
    elseif unitNow > 0 then
      for i = 1, n do unitOf[arr[i].day] = unitNow end
    end
  end
  -- per-day quantity, carried backwards across EVERY calendar day: a recorded
  -- snapshot (iq) re-anchors, and trades inside scan gaps still count.
  do
    local q = qty
    for i = n, 1, -1 do
      local d = arr[i].day
      local snapQ = id and hist and hist[d] and hist[d].iq and hist[d].iq[id]
      if snapQ ~= nil then q = snapQ end
      if q < 0 then q = 0 end
      arr[i].q = q
      arr[i].unit = unitOf[d] or arr[i].low
      arr[i].v = arr[i].unit * q
      -- step back to the previous SCAN day, undoing trades on every calendar
      -- day in between (d down to prevDay+1)
      local stopDay = (i > 1) and (arr[i - 1].day + 1) or d
      for dd = d, stopDay, -1 do
        q = q - (delta[dd] or 0)
      end
      -- did the quantity change inside the gap BEFORE this point? -> dash flag
      if i > 1 then
        local changed = false
        for dd = arr[i - 1].day + 1, d do
          if delta[dd] then changed = true; break end
        end
        arr[i].qChangedInGap = changed
      end
    end
  end
  -- grey consumption dots: units that left the holding WITHOUT a logged sale
  -- (enchants, crafting, gifts). Between two snapshot-anchored days the stock
  -- should be prev + buys - sells; whatever the next anchor is short of was
  -- used up, marked on that anchor day.
  local consAt = {}
  do
    local prevQ, prevDay
    for i = 1, n do
      local d = arr[i].day
      local snapQ = id and hist and hist[d] and hist[d].iq and hist[d].iq[id]
      if snapQ ~= nil then
        if prevQ ~= nil then
          local expect = prevQ
          for dd = prevDay + 1, d do expect = expect + (delta[dd] or 0) end
          if snapQ < expect then consAt[d] = expect - snapQ end
        end
        prevQ, prevDay = snapQ, d
      end
    end
  end
  -- layout: one plot, price scale on the left, value scale on the right
  local W, H = canvas:GetWidth(), canvas:GetHeight()
  local left, right, top, bottom = 64, 70, 16, 20
  local pw, ph = W - left - right, H - top - bottom
  local dMin, dMax = arr[1].day, arr[n].day
  local dSpan = math.max(1, dMax - dMin)
  local dayW, capped
  dayW, pw, capped = dayStep(pw, dSpan)
  local function X(day) return left + (day - dMin) * dayW end
  local pMin, pMax = math.huge, -math.huge
  local vMin, vMax = math.huge, -math.huge
  local qMax = 0
  for _, p2 in ipairs(arr) do
    local pg = p2.low / 10000
    local vg = p2.v / 10000
    if pg < pMin then pMin = pg end
    if pg > pMax then pMax = pg end
    if vg < vMin then vMin = vg end
    if vg > vMax then vMax = vg end
    if (p2.q or 0) > qMax then qMax = p2.q end
  end
  local pLo, pHi = pMin, pMax      -- freeze the data range before widening
  -- same 30% rule as the market chart: a far-off trade or Fair must not squash the scale
  local function widen(ug)
    if ug >= pLo * 0.7 and ug <= pHi * 1.3 then
      if ug < pMin then pMin = ug end
      if ug > pMax then pMax = ug end
    end
  end
  for _, a in pairs(tagg) do     -- keep NEARBY trade prices inside the left scale
    for _, k in ipairs({ "b", "s" }) do
      local t = a[k]
      if t and t.qty > 0 then widen((t.cost / t.qty) / 10000) end
    end
  end
  local showFair = M.chartFair ~= false
  if showFair then
    for _, e in ipairs(fairSeries) do
      if e.day >= dMin and e.day <= dMax then widen(e.fair / 10000) end
    end
  end
  pMin, pMax = minSpan(pMin, pMax, 0.0001)
  vMin, vMax = minSpan(vMin, vMax, 0.0001)
  local pPad = (pMax - pMin) * 0.12
  local vPad = (vMax - vMin) * 0.12
  pMin, pMax = math.max(0, pMin - pPad), pMax + pPad
  vMin, vMax = math.max(0, vMin - vPad), vMax + vPad
  -- the two scales live in SEPARATE height zones so the multiplication reads
  -- visually: the VALUE line (right scale) always runs clearly ABOVE the PRICE
  -- line (left scale) -- value = price x quantity, bigger thing on top. A small
  -- overlap keeps it one continuous plot instead of two boxed bands.
  local pZ0, pZ1 = bottom, bottom + ph * 0.56              -- price zone (lower)
  local vZ0, vZ1 = bottom + ph * 0.44, bottom + ph         -- value zone (upper)
  -- edge case: when the value scale starts at ZERO (the holding was empty or
  -- near-worthless for a stretch), pinning zero to the zone floor makes a flat
  -- line float mid-plot -- run the zone down to the plot floor instead, so low
  -- values sit at the bottom and the climb reads top-to-bottom honestly
  if vMin <= 0 then vZ0 = bottom end
  local function YP(g) return pZ0 + (g - pMin) / (pMax - pMin) * (pZ1 - pZ0) end
  local function YV(g) return vZ0 + (g - vMin) / (vMax - vMin) * (vZ1 - vZ0) end
  -- quantity bars along the bottom (faint, up to 30% of the plot height)
  if qMax > 0 then
    local bw = capped and 18 or math.max(1.5, math.min(10, dayW))
    local qh = ph * 0.25
    local br, bgc, bb = TC("sub")
    for _, p2 in ipairs(arr) do
      local hgt = qh * ((p2.q or 0) / qMax)
      if hgt > 0.5 then
        local tex = GetTex(canvas, "BACKGROUND")
        tex:SetTexture(WHITE); tex:SetVertexColor(br, bgc, bb, 0.20)
        tex:ClearAllPoints(); tex:SetSize(bw, hgt)
        tex:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", X(p2.day) - bw / 2, bottom)
      end
    end
  end
  -- hover points + the two lines
  local pts, vpts, ppts = {}, {}, {}
  for i, p2 in ipairs(arr) do
    local xx = X(p2.day)
    local vy = YV(p2.v / 10000)
    local py = YP(p2.low / 10000)
    local gap = (i > 1) and ((p2.day - arr[i - 1].day) > 1) or false
    ppts[#ppts + 1] = { x = xx, y = py, dash = gap }
    -- value line: solid across gaps when the quantity did not change there
    vpts[#vpts + 1] = { x = xx, y = vy, dash = gap and p2.qChangedInGap or false }
    local reads = {
      { kind = "price", y = vy, l1 = M.DayLabel(p2.day) .. "  \194\183  " .. M.MoneyPlain(p2.v),
        l2 = "x" .. (p2.q or 0) .. "  @  " .. M.MoneyPlain(p2.unit) },
      { kind = "hprice", y = py, l1 = "Price  " .. M.MoneyPlain(p2.low) },
      { kind = "qty", y = bottom + ph * 0.25 * ((p2.q or 0) / math.max(qMax, 1)), l1 = "Qty  x" .. (p2.q or 0) },
    }
    local a = tagg[p2.day]
    if a then
      if a.b and a.b.qty > 0 then
        reads[#reads + 1] = { kind = "tbuy", y = YP((a.b.cost / a.b.qty) / 10000),
          l1 = string.format("Bought x%d  \194\183  %s", a.b.qty, M.MoneyPlain(a.b.cost / a.b.qty)) }
      end
      if a.s and a.s.qty > 0 then
        reads[#reads + 1] = { kind = "tsell", y = YP((a.s.cost / a.s.qty) / 10000),
          l1 = string.format("Sold x%d  \194\183  %s", a.s.qty, M.MoneyPlain(a.s.cost / a.s.qty)) }
      end
    end
    local cq = consAt[p2.day]
    if cq and cq > 0 then
      reads[#reads + 1] = { kind = "tcons", y = vy,
        l1 = string.format("Consumed x%d  \194\183  no sale logged", cq) }
    end
    pts[#pts + 1] = { x = xx, y = vy, day = p2.day, reads = reads }
  end
  -- trades on days WITHOUT a scan draw a dot too -- give them a hover point of
  -- their own so the crosshair reads them instead of skipping over
  do
    local have = {}
    for _, p2 in ipairs(arr) do have[p2.day] = true end
    for d, a in pairs(tagg) do
      if not have[d] and d >= dMin and d <= dMax then
        local reads = {}
        if a.b and a.b.qty > 0 then
          reads[#reads + 1] = { kind = "tbuy", y = YP((a.b.cost / a.b.qty) / 10000),
            l1 = string.format("Bought x%d  \194\183  %s", a.b.qty, M.MoneyPlain(a.b.cost / a.b.qty)) }
        end
        if a.s and a.s.qty > 0 then
          reads[#reads + 1] = { kind = "tsell", y = YP((a.s.cost / a.s.qty) / 10000),
            l1 = string.format("Sold x%d  \194\183  %s", a.s.qty, M.MoneyPlain(a.s.cost / a.s.qty)) }
        end
        if #reads > 0 then
          pts[#pts + 1] = { x = X(d), y = reads[1].y, day = d, reads = reads }
        end
      end
    end
  end
  local ar, ag, ab = TC("text")
  local lr, lg, lb = TC("teal")
  SmoothLine(canvas, ppts, 1.4, ar, ag, ab, 0.75, pZ0, pZ1, 0.4)
  SmoothLine(canvas, vpts, 1.7, lr, lg, lb, 1, vZ0, vZ1, 0.5)
  -- Floor MA / Fair overlays on the LEFT price scale -- the same three toggles
  -- work here exactly like in the market chart
  if M.chartMA then
    local ma = FloorMA(arr, dSpan)
    local mapts = {}
    for i = 1, n do
      if ma[i] then mapts[#mapts + 1] = { x = X(arr[i].day), y = YP(ma[i] / 10000) } end
    end
    if #mapts >= 2 then
      local r2, g2, b2 = TC("blue")   -- cool blue: gold is reserved for the price line
      SmoothLine(canvas, mapts, 1.3, r2, g2, b2, 0.5, pZ0, pZ1, 0.4)
    end
  end
  if showFair then
    -- FairSeries covers the item's WHOLE history: keep only the days this
    -- chart shows (the timeframe trims arr, X() would go negative before it
    -- and draw the line out of the canvas); off-scale days break the line
    -- instead of pinning it to the zone edge
    local r2, g2, b2 = TC("purple")
    local run = {}
    local function flush()
      if #run >= 2 then SmoothLine(canvas, run, 1.3, r2, g2, b2, 0.6, pZ0, pZ1, 0.6) end
      run = {}
    end
    for _, e in ipairs(fairSeries) do
      if e.day >= dMin and e.day <= dMax then
        local g = e.fair / 10000
        if g >= pMin and g <= pMax then run[#run + 1] = { x = X(e.day), y = YP(g) } else flush() end
      end
    end
    flush()
  end
  -- your trades as dots at their realized unit price (left scale), size by amount
  local maxTQ = 0
  for _, a in pairs(tagg) do
    if a.b and a.b.qty > maxTQ then maxTQ = a.b.qty end
    if a.s and a.s.qty > maxTQ then maxTQ = a.s.qty end
  end
  local function dotSize(q2)
    if maxTQ <= 0 then return 8 end
    return 6 + 5 * math.sqrt(q2 / maxTQ)
  end
  local drewTrades = false
  if M.chartTrades ~= false then
    local gr, gg, gb = TC("green")
    local rr2, rg2, rb2 = TC("red")
    for d, a in pairs(tagg) do
      if d >= dMin and d <= dMax then
        local xx = X(d)
        local both = a.b and a.b.qty > 0 and a.s and a.s.qty > 0
        -- off-scale trades (left out of the scale above) draw no dot here either
        if a.b and a.b.qty > 0 then
          local bg = (a.b.cost / a.b.qty) / 10000
          if bg >= pMin and bg <= pMax then
            RoundDot(canvas, xx - (both and 4 or 0), YP(bg), dotSize(a.b.qty), gr, gg, gb)
            drewTrades = true
          end
        end
        if a.s and a.s.qty > 0 then
          local sg = (a.s.cost / a.s.qty) / 10000
          if sg >= pMin and sg <= pMax then
            RoundDot(canvas, xx + (both and 4 or 0), YP(sg), dotSize(a.s.qty), rr2, rg2, rb2)
            drewTrades = true
          end
        end
      end
    end
  end
  -- consumption as grey dots ON the value line (that is where the drop shows),
  -- same "My trades" toggle as the buy/sell dots
  local drewCons = false
  if M.chartTrades ~= false then
    local cr, cg, cb = TC("muted")
    for _, p2 in ipairs(arr) do
      local cq = consAt[p2.day]
      if cq and cq > 0 then
        RoundDot(canvas, X(p2.day), YV(p2.v / 10000), dotSize(cq), cr, cg, cb)
        drewCons = true
      end
    end
  end
  canvas._pts, canvas._plotBot, canvas._plotTop, canvas._plotRight = pts, bottom, bottom + ph, left + pw
  M.SetupHover(canvas)
  -- axes: PRICE scale on the left (gold), VALUE scale on the right (teal-muted)
  local mr, mg, mb = TC("muted")
  Label(canvas, left - 6, pZ1, M.MoneyPlain(pMax * 10000), "RIGHT", ar, ag, ab)
  Label(canvas, left - 6, pZ0, M.MoneyPlain(pMin * 10000), "RIGHT", ar, ag, ab)
  local yV = vpts[#vpts].y
  if math.abs(yV - vZ1) > 11 then Label(canvas, left + pw + 8, vZ1, M.MoneyPlain(vMax * 10000), "LEFT", mr, mg, mb) end
  -- the value zone's floor sits mid-plot; a "0c" there reads like a data
  -- point, so the label only shows when the scale really starts above zero
  if vMin > 0 and math.abs(yV - vZ0) > 11 then Label(canvas, left + pw + 8, vZ0, M.MoneyPlain(vMin * 10000), "LEFT", mr, mg, mb) end
  Dot(canvas, vpts[#vpts].x, yV, 4, lr, lg, lb)
  Label(canvas, left + pw + 8, yV, M.MoneyPlain(arr[n].v), "LEFT", lr, lg, lb)
  Dot(canvas, ppts[#ppts].x, ppts[#ppts].y, 3, ar, ag, ab)
  -- legend along the top: line scales, holding quantity, trade colors
  local lx = left + 4
  Dot(canvas, lx, bottom + ph + 3, 5, ar, ag, ab)
  local f0 = Label(canvas, lx + 6, bottom + ph + 3, "Price (left)", "LEFT", TC("sub"))
  lx = lx + 14 + (f0:GetStringWidth() or 60)
  Dot(canvas, lx, bottom + ph + 3, 5, lr, lg, lb)
  local f1 = Label(canvas, lx + 6, bottom + ph + 3, "Value (right)", "LEFT", TC("sub"))
  lx = lx + 14 + (f1:GetStringWidth() or 64)
  local f2 = Label(canvas, lx + 6, bottom + ph + 3, "holding x" .. qty .. " today", "LEFT", TC("sub"))
  lx = lx + 14 + (f2:GetStringWidth() or 80)
  if drewTrades then
    local gr, gg, gb = TC("green")
    local rr2, rg2, rb2 = TC("red")
    RoundDot(canvas, lx + 4, bottom + ph + 3, 8, gr, gg, gb)
    local f3 = Label(canvas, lx + 10, bottom + ph + 3, "Buys", "LEFT", TC("sub"))
    local lx2 = lx + 10 + (f3:GetStringWidth() or 26) + 14
    RoundDot(canvas, lx2, bottom + ph + 3, 8, rr2, rg2, rb2)
    local f4 = Label(canvas, lx2 + 6, bottom + ph + 3, "Sells", "LEFT", TC("sub"))
    lx = lx2 + 6 + (f4:GetStringWidth() or 28) + 8
  end
  if drewCons then
    local cr, cg, cb = TC("muted")
    RoundDot(canvas, lx + 6, bottom + ph + 3, 8, cr, cg, cb)
    Label(canvas, lx + 12, bottom + ph + 3, "Consumed", "LEFT", TC("sub"))
  end
  local labelN = capped and math.min(2, n) or math.min(4, n)
  for k = 0, labelN - 1 do
    local i = 1 + math.floor((n - 1) * k / math.max(labelN - 1, 1) + 0.5)
    local anchor = (k == 0) and "LEFT" or ((k == labelN - 1) and (capped and "LEFT" or "RIGHT") or "CENTER")
    Label(canvas, X(arr[i].day), bottom - 12, M.DayLabel(arr[i].day), anchor, TC("muted"))
  end
end

-- ===== Help-tab example charts (static, illustrative data) ==================
-- Drawn with the same primitives as the real charts so they look native.
function M.RenderHelpFair(canvas)
  ResetPools(canvas)
  local W, H = canvas:GetWidth(), canvas:GetHeight()
  if W < 50 then return end
  local left, right, top, bottom = 30, 8, 14, 16
  local pw, ph = W - left - right, H - top - bottom
  -- 14 example daily lows in gold; day 5 is a 30g no-demand spike (trimmed)
  local lows = { 10, 11, 9.5, 10.5, 30, 10, 11, 12, 10.5, 11, 11.5, 10.5, 11, 11.5 }
  local nl = #lows
  -- base exactly as DemandBase builds it: days above median x FAIR_TRIM drop
  -- out, the rest weigh 0.5^(age / the Fair half-life set in Settings)
  local sorted = {}
  for i, g in ipairs(lows) do sorted[i] = g end
  table.sort(sorted)
  local med = (nl % 2 == 1) and sorted[(nl + 1) / 2] or (sorted[nl / 2] + sorted[nl / 2 + 1]) / 2
  local cap = med * (M.C.FAIR_TRIM or 1.5)
  local hl = M.FairHalflife and M.FairHalflife() or 7
  local wsum, vsum = 0, 0
  for i, g in ipairs(lows) do
    if g <= cap then
      local w = 0.5 ^ ((nl - i) / hl)
      wsum = wsum + w; vsum = vsum + w * g
    end
  end
  local base = vsum / wsum
  -- the example's sales lift Fair to 11g (the odds example below uses the same
  -- 11g); Fair never sits under the base
  local fair = math.max(11, base)
  local lo, hi = 9, 13.5                      -- y-scale ignores the spike
  local function X(i) return left + (i - 1) / (nl - 1) * pw end
  local function Y(g)
    local y = bottom + (g - lo) / (hi - lo) * ph
    if y > bottom + ph then y = bottom + ph end
    return y
  end
  local tr, tg, tb = TC("teal")
  local rr, rg, rb = TC("blue")
  local pts, gap = {}, false
  for i, g in ipairs(lows) do
    if g <= cap then
      pts[#pts + 1] = { x = X(i), y = Y(g), dash = gap }
      gap = false
    else
      -- a trimmed day: cool blue dot pinned to the top edge (gold = prices, red = sells)
      RoundDot(canvas, X(i), bottom + ph - 2, 7, rr, rg, rb, 0.9)
      Label(canvas, X(i) + 6, bottom + ph - 2, "trimmed (no demand)", "LEFT", rr, rg, rb)
      gap = true
    end
  end
  SmoothLine(canvas, pts, 1.6, tr, tg, tb, 1, bottom, bottom + ph, 0.5)
  -- base and Fair reference lines
  local mr, mg, mb = TC("muted")
  DashSeg(canvas, left, Y(base), left + pw, Y(base), 1, mr, mg, mb, 0.7)
  Label(canvas, left + 2, Y(base) - 7, "base " .. M.MoneyPlain(base * 10000) .. " (trimmed, recent days weigh more)", "LEFT", mr, mg, mb)
  local pr, pg, pb = TC("purple")
  DashSeg(canvas, left, Y(fair), left + pw, Y(fair), 1, pr, pg, pb, 0.9)
  Label(canvas, left + pw - 2, Y(fair) + 8, "Fair " .. M.MoneyPlain(fair * 10000)
    .. ((fair > base) and " (lifted, capped by your sales)" or " (no lift)"), "RIGHT", pr, pg, pb)
  for _, g in ipairs({ 10, 12 }) do Label(canvas, left - 4, Y(g), g .. "g", "RIGHT", mr, mg, mb) end
  Label(canvas, left, bottom - 9, "14 days of scans", "LEFT", TC("muted"))
end

-- Live Settings demo for the Fair recency slider: three weeks of lively daily
-- lows around 12g that drop to ~8g a week before the end. The purple line is
-- the market base COMPUTED PER DAY over its trailing 14-day window with the
-- chosen half-life - exactly like the Fair line in the real charts: a short
-- half-life hugs the price down right after the drop, a long one trails it.
-- Pure function of (canvas size, hl) - cheap to redraw per drag step.
function M.RenderFairBiasDemo(canvas, hl)
  ResetPools(canvas)
  local W, H = canvas:GetWidth(), canvas:GetHeight()
  if W < 50 or H < 40 then return end   -- at the minimum window the demo zone collapses
  hl = hl or 7
  local left, right, top, bottom = 34, 8, 12, 16
  local pw, ph = W - left - right, H - top - bottom
  local lows = { 11.6, 12.9, 10.9, 13.1, 11.4, 12.6, 10.8, 13.2, 11.5, 12.8,
                 11.0, 12.5, 11.3, 9.4, 7.8, 8.9, 7.3, 8.8, 7.5, 8.7, 7.9 }
  local n = #lows
  local lo, hi = 6.5, 13.8
  local function X(i) return left + (i - 1) / (n - 1) * pw end
  local function Y(g) return bottom + (g - lo) / (hi - lo) * ph end
  local tr, tg2, tb = TC("teal")
  local pts = {}
  for i, g in ipairs(lows) do pts[#pts + 1] = { x = X(i), y = Y(g) } end
  SmoothLine(canvas, pts, 1.6, tr, tg2, tb, 1, bottom, bottom + ph, 0.5)
  -- trailing base per day: the real DemandBase weighting (0.5^(age/hl)) over
  -- the last up-to-14 days known at that day (the trim cannot fire here)
  local bpts, lastBase = {}, 0
  for i = 1, n do
    local wsum, vsum = 0, 0
    for j = math.max(1, i - 13), i do
      local w = 0.5 ^ ((i - j) / hl)
      wsum = wsum + w
      vsum = vsum + w * lows[j]
    end
    lastBase = vsum / wsum
    bpts[#bpts + 1] = { x = X(i), y = Y(lastBase) }
  end
  local pr, pg, pb = TC("purple")
  SmoothLine(canvas, bpts, 1.4, pr, pg, pb, 0.9, bottom, bottom + ph, 0.5)
  Label(canvas, X(n) - 4, bpts[n].y + 9,
    "base " .. M.MoneyPlain(math.floor(lastBase * 10000)), "RIGHT", pr, pg, pb)
  local mr, mg2, mb = TC("muted")
  Label(canvas, left - 4, Y(8), "8g", "RIGHT", mr, mg2, mb)
  Label(canvas, left - 4, Y(12), "12g", "RIGHT", mr, mg2, mb)
  Label(canvas, left, bottom - 9, "old level ~12g", "LEFT", mr, mg2, mb)
  Label(canvas, left + pw, bottom - 9, "dropped to ~8g", "RIGHT", mr, mg2, mb)
end

function M.RenderHelpOdds(canvas)
  ResetPools(canvas)
  local W, H = canvas:GetWidth(), canvas:GetHeight()
  if W < 50 then return end
  local left, right, top, bottom = 34, 8, 10, 30
  local pw, ph = W - left - right, H - top - bottom
  -- NOT a price-over-time chart: x is YOUR ASKING PRICE for an item whose
  -- floor is 10g (same numbers as the Fair example above); y answers "how
  -- likely does ONE 48h auction sell at that ask?". The marker percentages
  -- are read off the drawn curve, so text and picture cannot disagree.
  local FLOOR = 10
  local function X(g) return left + (g - 9) / 11 * pw end        -- 9g .. 20g
  local function Y(o) return bottom + o * ph end
  local function odds(g) return 1 / (1 + math.exp((g / FLOOR - 1.1) * 8)) end
  local tr, tg, tb = TC("teal")
  local pts = {}
  for i = 0, 36 do
    local g = 9 + i * (11 / 36)
    pts[#pts + 1] = { x = X(g), y = Y(odds(g)) }
  end
  SmoothLine(canvas, pts, 1.6, tr, tg, tb, 1, bottom, bottom + ph, 0.5)
  local mr, mg, mb = TC("muted")
  DashSeg(canvas, left, Y(0.5), left + pw, Y(0.5), 1, mr, mg, mb, 0.6)
  Label(canvas, left - 4, Y(1), "100%", "RIGHT", mr, mg, mb)
  Label(canvas, left - 4, Y(0.5), "50%", "RIGHT", mr, mg, mb)
  Label(canvas, left - 4, Y(0), "0%", "RIGHT", mr, mg, mb)
  local gr, gg, gb = TC("green")
  local rr, rg, rb = TC("red")
  RoundDot(canvas, X(10), Y(odds(10)), 7, tr, tg, tb)
  Label(canvas, X(10) + 6, Y(odds(10)) + 4,
    string.format("ask 10g (floor) \194\183 ~%.0f%%", odds(10) * 100), "LEFT", TC("sub"))
  RoundDot(canvas, X(11), Y(odds(11)), 8, gr, gg, gb)
  Label(canvas, X(11) + 6, Y(odds(11)) - 9,
    string.format("ask 11g = Fair \194\183 ~%.0f%%", odds(11) * 100), "LEFT", gr, gg, gb)
  RoundDot(canvas, X(13), Y(odds(13)), 8, rr, rg, rb)
  Label(canvas, X(13) + 4, Y(odds(13)) + 10,
    string.format("ask 13g (+30%%) \194\183 ~%.0f%%", odds(13) * 100), "LEFT", rr, rg, rb)
  Label(canvas, X(10), bottom - 9, "10g", "CENTER", mr, mg, mb)
  Label(canvas, X(15), bottom - 9, "15g", "CENTER", mr, mg, mb)
  Label(canvas, X(20) - 4, bottom - 9, "20g", "CENTER", mr, mg, mb)
  Label(canvas, left + pw / 2, bottom - 20, "your asking price", "CENTER", mr, mg, mb)
end

-- ===== "Why these numbers?" charts: the Help examples with REAL item data ===
function M.RenderWhyFair(canvas, key)
  ResetPools(canvas)
  local W, H = canvas:GetWidth(), canvas:GetHeight()
  if W < 50 then return end
  local series = key and M.GetSeries(key)
  local m = series and M.Metrics(series, key)
  if not (series and m and m.base and m.base > 0) then
    Label(canvas, W / 2, H / 2, "no price data", "CENTER", TC("muted"))
    return
  end
  local left, right, top, bottom = 46, 10, 16, 20
  local pw, ph = W - left - right, H - top - bottom
  local arr = {}
  for day, v in pairs(series) do if v.low then arr[#arr + 1] = { day = day, low = v.low } end end
  table.sort(arr, function(x, y) return x.day < y.day end)
  local n = #arr
  local from = math.max(1, n - 20)
  -- the base window exactly as DemandBase trims it: a day above the window
  -- median x FAIR_TRIM carried no demand, a one-scan dip below median /
  -- FAIR_TRIM that the market already left again is dropped too
  local dw, hiCap, loCap = M.DemandWindow(series, m.lastDay or arr[n].day)
  local trimDay = {}
  if dw then for _, e in ipairs(dw) do if not e.keep then trimDay[e.day] = true end end end
  local lo, hi = math.huge, 0
  for i = from, n do
    local l = arr[i].low
    if not trimDay[arr[i].day] then
      if l < lo then lo = l end
      if l > hi then hi = l end
    end
  end
  if lo == math.huge then lo = m.base end
  lo = math.min(lo, m.base, m.fair) * 0.92
  hi = math.max(hi, m.base, m.fair) * 1.08
  if hi <= lo then hi = lo + 1 end
  local function X(i) return left + (i - from) / math.max(1, n - from) * pw end
  local function Y(v)
    local y = bottom + (v - lo) / (hi - lo) * ph
    if y > bottom + ph then y = bottom + ph elseif y < bottom then y = bottom end
    return y
  end
  local tr, tg, tb = TC("teal")
  local ar, ag, ab = TC("blue")   -- trimmed days: cool blue (gold = prices, red = sells)
  local rr, rg, rb = TC("red")
  -- your sells per day: they are what the lift/cap is measured against
  local sellAgg = {}
  do
    local id = (M.BaseID and M.BaseID(key)) or tonumber(key)
    if id and M.db and M.db.trade and M.db.trade.log then
      local realm = M.RealmKey()
      for _, e in ipairs(M.db.trade.log) do
        if e.id == id and e.realm == realm and e.kind == "sold"
           and (e.gross or 0) > 0 and e.day then
          local t2 = sellAgg[e.day]
          if not t2 then t2 = { qty = 0, cost = 0 }; sellAgg[e.day] = t2 end
          local cnt = (e.count and e.count > 0) and e.count or 1
          t2.qty = t2.qty + cnt
          t2.cost = t2.cost + e.gross
        end
      end
    end
  end
  local kept, trimmed = {}, 0
  local hpts = {}
  for i = from, n do
    local e = arr[i]
    local reads
    if trimDay[e.day] then
      trimmed = trimmed + 1
      -- spikes pin to the top edge, dips to the bottom edge
      local ty = (e.low > hiCap) and (bottom + ph - 2) or (bottom + 2)
      RoundDot(canvas, X(i), ty, 6, ar, ag, ab, 0.9)
      reads = { { kind = "ma", y = ty,
        l1 = M.DayLabel(e.day) .. "  trimmed  \194\183  " .. M.MoneyPlain(e.low) } }
    else
      kept[#kept + 1] = { x = X(i), y = Y(e.low) }
      reads = { { kind = "price", y = Y(e.low),
        l1 = M.DayLabel(e.day) .. "  \194\183  " .. M.MoneyPlain(e.low) } }
    end
    local sa = sellAgg[e.day]
    if sa and sa.qty > 0 then
      local u = sa.cost / sa.qty
      RoundDot(canvas, X(i), Y(u), 6, rr, rg, rb, 0.85)
      reads[#reads + 1] = { kind = "tsell", y = Y(u),
        l1 = string.format("Sold x%d  \194\183  %s", sa.qty, M.MoneyPlain(u)) }
    end
    hpts[#hpts + 1] = { x = X(i), y = reads[1].y, day = e.day, reads = reads }
  end
  if #kept >= 2 then SmoothLine(canvas, kept, 1.5, tr, tg, tb, 1, bottom, bottom + ph, 0.5) end
  -- the trim caps: a day outside them is a blue dot instead of the line
  if hiCap then
    for _, c in ipairs({ hiCap, loCap }) do
      if c > lo and c < hi then DashSeg(canvas, left, Y(c), left + pw, Y(c), 1, ar, ag, ab, 0.45) end
    end
  end
  if trimmed > 0 then
    Label(canvas, left + pw - 2, bottom + ph - 2,
      string.format("%d day(s) trimmed \226\128\148 outside %s \226\128\147 %s", trimmed,
        M.MoneyPlain(loCap), M.MoneyPlain(hiCap)), "RIGHT", ar, ag, ab)
  end
  local mr, mg, mb = TC("muted")
  DashSeg(canvas, left, Y(m.base), left + pw, Y(m.base), 1, mr, mg, mb, 0.7)
  Label(canvas, left + 2, Y(m.base) - 7, "base " .. M.MoneyPlain(m.base), "LEFT", mr, mg, mb)
  local pr, pg, pb = TC("purple")
  DashSeg(canvas, left, Y(m.fair), left + pw, Y(m.fair), 1, pr, pg, pb, 0.9)
  Label(canvas, left + 2, Y(m.fair) + 8, "Fair " .. M.MoneyPlain(m.fair), "LEFT", pr, pg, pb)
  Label(canvas, left - 4, Y(lo), M.MoneyPlain(lo), "RIGHT", mr, mg, mb)
  Label(canvas, left - 4, Y(hi), M.MoneyPlain(hi), "RIGHT", mr, mg, mb)
  Label(canvas, left, bottom - 10, "this item's daily lows \194\183 last " .. (n - from + 1) .. " scan days", "LEFT", mr, mg, mb)
  -- legend row along the top edge, holding-chart style
  local ly = bottom + ph + 5
  local lx = left + 2
  Dot(canvas, lx, ly, 5, tr, tg, tb)
  local f1 = Label(canvas, lx + 6, ly, "daily low", "LEFT", TC("sub"))
  lx = lx + 12 + (f1:GetStringWidth() or 44)
  RoundDot(canvas, lx, ly, 6, ar, ag, ab)
  local f2 = Label(canvas, lx + 6, ly, "trimmed", "LEFT", TC("sub"))
  lx = lx + 12 + (f2:GetStringWidth() or 40)
  DashSeg(canvas, lx - 4, ly, lx + 8, ly, 1.5, mr, mg, mb, 0.9)
  local f3 = Label(canvas, lx + 12, ly, "base", "LEFT", TC("sub"))
  lx = lx + 18 + (f3:GetStringWidth() or 26)
  DashSeg(canvas, lx - 4, ly, lx + 8, ly, 1.5, pr, pg, pb, 1)
  local f4 = Label(canvas, lx + 12, ly, "Fair", "LEFT", TC("sub"))
  lx = lx + 18 + (f4:GetStringWidth() or 24)
  RoundDot(canvas, lx, ly, 6, rr, rg, rb)
  Label(canvas, lx + 6, ly, "your sells", "LEFT", TC("sub"))
  -- full native hover: crosshair + per-day value read-outs
  canvas._pts, canvas._plotBot, canvas._plotTop, canvas._plotRight = hpts, bottom, bottom + ph, left + pw
  M.SetupHover(canvas)
end

function M.RenderWhyOdds(canvas, key)
  ResetPools(canvas)
  local W, H = canvas:GetWidth(), canvas:GetHeight()
  if W < 50 then return end
  local series = key and M.GetSeries(key)
  local m = series and M.Metrics(series, key)
  if not (m and m.fair and m.fair > 0 and m.oddsAtFair and m.oddsAtFair > 0 and m.oddsAtFair < 1) then
    Label(canvas, W / 2, H / 2 + 6, "not enough of your own sold/expired", "CENTER", TC("muted"))
    Label(canvas, W / 2, H / 2 - 6, "outcomes to estimate odds yet", "CENTER", TC("muted"))
    return
  end
  local left, right, top, bottom = 46, 10, 14, 32
  local pw, ph = W - left - right, H - top - bottom
  -- the EXACT model curve: logit(odds) is linear in ln(price) with slope
  -- -FAIR_SLOPE, anchored at (fair, oddsAtFair) -- identical to Metrics' oddsAt
  local slope = M.C.FAIR_SLOPE or 3
  local l0 = math.log(m.oddsAtFair / (1 - m.oddsAtFair))
  local function odds(p)
    local z = l0 + slope * math.log(m.fair / p)
    if z > 30 then return 1 elseif z < -30 then return 0 end
    return 1 / (1 + math.exp(-z))
  end
  local cur = (m.cur and m.cur > 0) and m.cur or m.fair
  local pLo = math.min(m.fair * 0.75, cur * 0.9)
  local pHi = math.max(m.fair * 2.2, cur * 1.25)
  local lnLo, lnHi = math.log(pLo), math.log(pHi)
  local function X(p) return left + (math.log(p) - lnLo) / (lnHi - lnLo) * pw end
  local function Y(o) return bottom + o * ph end
  local tr, tg, tb = TC("teal")
  local rr, rg, rb = TC("red")
  -- your sells, bucketed onto the nearest curve sample (dots + hover)
  local sellB = {}
  do
    local id = (M.BaseID and M.BaseID(key)) or tonumber(key)
    if id and M.db and M.db.trade and M.db.trade.log then
      local realm = M.RealmKey()
      for _, e in ipairs(M.db.trade.log) do
        if e.id == id and e.realm == realm and e.kind == "sold" and (e.gross or 0) > 0 then
          local cnt = (e.count and e.count > 0) and e.count or 1
          local u = e.gross / cnt
          if u >= pLo and u <= pHi then
            local bi = math.floor((math.log(u) - lnLo) / (lnHi - lnLo) * 40 + 0.5)
            local b2 = sellB[bi]
            if not b2 then b2 = { qty = 0, cost = 0 }; sellB[bi] = b2 end
            b2.qty = b2.qty + cnt
            b2.cost = b2.cost + e.gross
          end
        end
      end
    end
  end
  local curve, hpts = {}, {}
  for i = 0, 40 do
    local p = math.exp(lnLo + (lnHi - lnLo) * i / 40)
    local o = odds(p)
    curve[#curve + 1] = { x = X(p), y = Y(o) }
    local reads = { { kind = "price", y = Y(o), l1 = "ask " .. M.MoneyPlain(p),
      l2 = string.format("~%.0f%% \194\183 one 48h auction", o * 100) } }
    local b2 = sellB[i]
    if b2 and b2.qty > 0 then
      local u = b2.cost / b2.qty
      RoundDot(canvas, X(u), Y(odds(u)), 5, rr, rg, rb, 0.8)
      reads[#reads + 1] = { kind = "tsell", y = Y(odds(u)),
        l1 = string.format("your sales x%d  \194\183  %s", b2.qty, M.MoneyPlain(u)) }
    end
    hpts[#hpts + 1] = { x = X(p), y = Y(o), reads = reads }
  end
  SmoothLine(canvas, curve, 1.6, tr, tg, tb, 1, bottom, bottom + ph, 0.5)
  local mr, mg, mb = TC("muted")
  DashSeg(canvas, left, Y(0.5), left + pw, Y(0.5), 1, mr, mg, mb, 0.6)
  Label(canvas, left - 4, Y(1), "100%", "RIGHT", mr, mg, mb)
  Label(canvas, left - 4, Y(0.5), "50%", "RIGHT", mr, mg, mb)
  Label(canvas, left - 4, Y(0), "0%", "RIGHT", mr, mg, mb)
  local gr, gg, gb = TC("green")
  RoundDot(canvas, X(m.fair), Y(odds(m.fair)), 8, gr, gg, gb)
  Label(canvas, X(m.fair) + 6, Y(odds(m.fair)) + 9,
    string.format("Fair %s \194\183 ~%.0f%%", M.MoneyPlain(m.fair), odds(m.fair) * 100), "LEFT", gr, gg, gb)
  local cr, cg, cb = TC(M.DeltaColor(m.delta))
  local curOdds = m.odds or odds(cur)
  RoundDot(canvas, X(cur), Y(odds(cur)), 8, cr, cg, cb)
  local anch = (X(cur) > left + pw * 0.6) and "RIGHT" or "LEFT"
  Label(canvas, X(cur) + ((anch == "LEFT") and 6 or -6), Y(odds(cur)) - 9,
    string.format("current %s (%+.0f%%) \194\183 ~%.0f%%", M.MoneyPlain(cur), m.delta * 100, curOdds * 100), anch, cr, cg, cb)
  Label(canvas, left, bottom - 9, M.MoneyPlain(pLo), "LEFT", mr, mg, mb)
  Label(canvas, left + pw, bottom - 9, M.MoneyPlain(pHi), "RIGHT", mr, mg, mb)
  Label(canvas, left + pw / 2, bottom - 20, "your asking price (not time)", "CENTER", mr, mg, mb)
  -- legend row along the top edge
  local ly = bottom + ph + 4
  local lx = left + 2
  Dot(canvas, lx, ly, 5, tr, tg, tb)
  local f1 = Label(canvas, lx + 6, ly, "chance ONE 48h auction sells", "LEFT", TC("sub"))
  lx = lx + 12 + (f1:GetStringWidth() or 150)
  RoundDot(canvas, lx, ly, 6, rr, rg, rb)
  Label(canvas, lx + 6, ly, "your sells (unit price)", "LEFT", TC("sub"))
  -- full native hover along the curve
  canvas._pts, canvas._plotBot, canvas._plotTop, canvas._plotRight = hpts, bottom, bottom + ph, left + pw
  M.SetupHover(canvas)
end

-- ===== Start-page net-worth sparkline =======================================
-- Tiny, label-free trend of the daily net-worth snapshots (last ~45) in the
-- brand gold with a soft area fill. The dashboard sets canvas._compact, so the
-- hover shows one small "date - total" box above the plot.
function M.RenderWorthSpark(canvas)
  ResetPools(canvas)
  local hist = M.NWHist()
  local all = {}
  if hist then
    for day, s in pairs(hist) do
      if type(s) == "table" and s.t then all[#all + 1] = { day = day, v = s.t } end
    end
  end
  table.sort(all, function(a, b) return a.day < b.day end)
  -- the preview timeframe (Settings) trims by days; "All" keeps the classic
  -- last-45-snapshots cap so the sparkline stays a short readable trend
  local arr = all
  local days = M.PreviewRangeDays and M.PreviewRangeDays()
  if days and #all > 0 then
    arr = {}
    local cutoff = all[#all].day - days + 1
    for i = 1, #all do if all[i].day >= cutoff then arr[#arr + 1] = all[i] end end
  elseif #all > 45 then
    arr = {}
    for i = #all - 44, #all do arr[#arr + 1] = all[i] end
  end
  local n = #arr
  canvas._d0, canvas._d1 = nil, nil
  local W, H = canvas:GetWidth(), canvas:GetHeight()
  if W < 10 or H < 10 then return end
  if n == 0 then
    Label(canvas, W / 2, H / 2, "a snapshot is saved every day", "CENTER", TC("muted"))
    canvas._pts = nil
    return
  end
  if n == 1 then
    Label(canvas, W / 2, H / 2, M.DayLabel(arr[1].day) .. "  \194\183  " .. M.MoneyPlain(arr[1].v), "CENTER", TC("sub"))
    canvas._pts = nil
    return
  end
  local vmin, vmax = math.huge, -math.huge
  for i = 1, n do
    if arr[i].v < vmin then vmin = arr[i].v end
    if arr[i].v > vmax then vmax = arr[i].v end
  end
  vmin, vmax = minSpan(vmin, vmax, 1)
  local pad = (vmax - vmin) * 0.15
  vmin = math.max(0, vmin - pad); vmax = vmax + pad
  local left, right, top, bottom = 4, 4, 10, 6
  local pw, ph = W - left - right, H - top - bottom
  local d0, d1 = arr[1].day, arr[n].day
  canvas._d0, canvas._d1 = d0, d1       -- the Start hero labels the span
  local span = math.max(1, d1 - d0)
  local ar, ag, ab = TC("accent")
  local pts, hpts = {}, {}
  for i = 1, n do
    local x = left + (arr[i].day - d0) / span * pw
    local y = bottom + (arr[i].v - vmin) / (vmax - vmin) * ph
    pts[#pts + 1] = { x = x, y = y }
    hpts[#hpts + 1] = { x = x, y = y, day = arr[i].day,
      reads = { { kind = "price", y = y, l1 = M.DayLabel(arr[i].day) .. "  \194\183  " .. M.MoneyPlain(arr[i].v) } } }
    local t = GetTex(canvas, "BACKGROUND")
    t:SetTexture(WHITE); t:SetVertexColor(ar, ag, ab, 0.07)
    -- column width capped + clamped into the plot: with a young history the
    -- old pw/n columns grew card-wide and bled into the neighbour card
    local bw = math.max(1, math.min(18, pw / n - 1))
    local bx = x - bw / 2
    if bx < left then bx = left elseif bx + bw > left + pw then bx = left + pw - bw end
    t:SetSize(bw, math.max(1, y - bottom))
    t:ClearAllPoints(); t:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", bx, bottom)
  end
  SmoothLine(canvas, pts, 2, ar, ag, ab, 0.95, bottom, bottom + ph)
  RoundDot(canvas, pts[n].x, pts[n].y, 5, ar, ag, ab, 1)
  canvas._pts = hpts
  canvas._plotBot, canvas._plotTop, canvas._plotRight = bottom, bottom + ph, left + pw
  M.SetupHover(canvas)
end
