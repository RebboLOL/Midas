-- Midas – Sankey: where gold and goods come from and where they go. Four
-- columns (sources -> stock -> gold -> sinks) in two lanes, gold on top and
-- goods below; only sales cross from the goods lane into the gold lane.
-- SankeyLayout is pure; RenderSankey keeps its own region pools on canvas._sk.
local ADDON, M = ...
local WHITE = "Interface\\Buttons\\WHITE8X8"
local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs

local COLX       = { 0, 0.36, 0.64, 1 }  -- column x as fractions of the plot width
local MAX_VIS    = 7                     -- visible nodes per lane and column (incl. "Other")
local FOLD_SHARE = 0.01                  -- below this share of the column total a node may fold
local MIN_H      = 2                     -- minimum bar height
local TEX_BUDGET = 1300
local A_BASE, A_HOT, A_DIM, A_BAR_DIM = 0.45, 0.75, 0.15, 0.45
local LANES = { "gold", "goods" }
local LANE_RANK = { gold = 0, goods = 1 }

local GEO = {
  full    = { gutter = 120, padT = 30, padB = 30, nodeGap = 6, laneGap = 18, barW = 10 },
  compact = { gutter = 4,   padT = 4,  padB = 4,  nodeGap = 2, laneGap = 6,  barW = 6 },
}

local V_UL = UPPER_LEFT_VERTEX or 1
local V_LL = LOWER_LEFT_VERTEX or 2
local V_UR = UPPER_RIGHT_VERTEX or 3
local V_LR = LOWER_RIGHT_VERTEX or 4

local function ease(s) return s * s * (3 - 2 * s) end

local function rgb(key)
  local C = M.Theme and M.Theme.C
  local c = C and (C[key or "muted"] or C.muted)
  if c then return c[1], c[2], c[3] end
  return 0.6, 0.6, 0.6
end

local function trim1(v)
  local s = string.format("%.1f", v)
  return (s:gsub("%.0$", ""))
end

-- compact gold for diagram labels: 1.2M g / 1.2k g / 345g / 4.5g / 12s / 7c
function M.MoneyShort(copper)
  copper = tonumber(copper) or 0
  local c = floor(abs(copper) + 0.5)
  local g = c / 10000
  local s
  if g >= 1e6 then s = trim1(g / 1e6) .. "M g"
  elseif g >= 1e5 then s = string.format("%dk g", floor(g / 1000))
  elseif g >= 1000 then s = trim1(floor(g / 100) / 10) .. "k g"
  elseif g >= 10 then s = string.format("%dg", floor(g))
  elseif g >= 1 then s = trim1(floor(g * 10) / 10) .. "g"
  elseif c >= 100 then s = string.format("%ds", floor(c / 100))
  else s = string.format("%dc", c) end
  return ((copper < 0) and "-" or "") .. s
end

-- ===== Layout ===============================================================
local function nodeLess(a, b)
  if a.other ~= b.other then return not a.other end
  if a.hub ~= b.hub then return a.hub end
  if a.value ~= b.value then return a.value > b.value end
  local la, lb = tostring(a.node.label or a.id), tostring(b.node.label or b.id)
  if la ~= lb then return la < lb end
  return tostring(a.id) < tostring(b.id)
end

local function mergeItems(acc, items)
  if type(items) ~= "table" then return end
  for _, it in ipairs(items) do
    if it.id ~= nil then
      local a = acc.map[it.id]
      if not a then
        a = { id = it.id, qty = 0, value = 0 }
        acc.map[it.id] = a; acc.list[#acc.list + 1] = a
      end
      a.qty = a.qty + (tonumber(it.qty) or 0)
      a.value = a.value + (tonumber(it.value) or 0)
    end
  end
end

local function itemList(acc)
  table.sort(acc.list, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return tostring(a.id) < tostring(b.id)
  end)
  return acc.list
end

local function isFlat(s) return abs(s[3] - s[5]) < 0.01 and abs(s[4] - s[6]) < 0.01 end

-- model -> { nodes = {[id] = rect}, list = {rects in draw order}, links = {...}, scale, W, H }
-- Rects use the canvas BOTTOMLEFT origin (y up). Pass-through rects (pass = true)
-- carry a ribbon across a column it skips and are never drawn or hit.
function M.SankeyLayout(model, W, H, opts)
  opts = opts or {}
  W, H = tonumber(W) or 0, tonumber(H) or 0
  local geo = opts.compact and GEO.compact or GEO.full
  local out = { nodes = {}, list = {}, links = {}, scale = 0, W = W, H = H, total = 0,
                compact = opts.compact and true or false }
  if type(model) ~= "table" then out.empty = true; return out end

  local byId, ents = {}, {}
  for _, n in ipairs(model.nodes or {}) do
    local c = tonumber(n.col)
    if n.id ~= nil and c and c >= 0 and c <= 3 and byId[n.id] == nil then
      local e = { id = n.id, node = n, col = floor(c), lane = (n.lane == "goods") and "goods" or "gold",
                  hub = n.hub and true or false, other = false, group = n.group, color = n.color,
                  vin = 0, vout = 0, value = 0 }
      byId[n.id] = e; ents[#ents + 1] = e
    end
  end
  local raw = {}
  for i, l in ipairs(model.links or {}) do
    local a, b, v = byId[l.from], byId[l.to], tonumber(l.value)
    if a and b and v and v > 0 and a.col < b.col then
      raw[#raw + 1] = { link = l, from = a, to = b, value = v, idx = i }
    end
  end
  local function tally(list)
    for _, e in ipairs(ents) do e.vin, e.vout = 0, 0 end
    for _, L in ipairs(list) do
      L.from.vout = L.from.vout + L.value; L.to.vin = L.to.vin + L.value
    end
    for _, e in ipairs(ents) do e.value = max(e.vin, e.vout) end
  end
  tally(raw)
  local colTot = { [0] = 0, 0, 0, 0 }
  for _, e in ipairs(ents) do colTot[e.col] = colTot[e.col] + e.value end
  local total = max(colTot[0], colTot[1], colTot[2], colTot[3])
  if total <= 0 or W < 20 or H < 20 then out.empty = true; return out end
  out.total = total

  -- fold the small source/sink nodes of a lane into one "Other (n)"; grouped
  -- nodes never fold (their partner in the other lane must stay visible too)
  local foldTo = {}
  for _, c in ipairs({ 0, 3 }) do
    for _, lane in ipairs(LANES) do
      local list, grouped = {}, 0
      for _, e in ipairs(ents) do
        if e.col == c and e.lane == lane and not e.hub and e.value > 0 then
          list[#list + 1] = e
          if e.group ~= nil then grouped = grouped + 1 end
        end
      end
      table.sort(list, nodeLess)
      local cap = ((#list > MAX_VIS) and (MAX_VIS - 1) or MAX_VIS) - grouped
      local kept, cand = 0, {}
      for _, e in ipairs(list) do
        if e.group == nil then
          if kept < cap and e.value >= FOLD_SHARE * colTot[c] then kept = kept + 1
          else cand[#cand + 1] = e end
        end
      end
      if #cand >= 2 then
        local id = "__other:" .. c .. ":" .. lane
        local acc, sub, kids, v = { map = {}, list = {} }, {}, {}, 0
        for _, e in ipairs(cand) do
          v = v + e.value
          kids[#kids + 1] = e.node
          sub[#sub + 1] = { label = e.node.label or tostring(e.id), value = e.value }
          mergeItems(acc, e.node.items)
        end
        local o = { id = id, col = c, lane = lane, hub = false, other = true, color = "muted",
                    vin = 0, vout = 0, value = v,
                    node = { id = id, label = "Other (" .. #cand .. ")", col = c, lane = lane, color = "muted",
                             items = itemList(acc), sub = sub, folded = kids } }
        byId[id] = o; ents[#ents + 1] = o
        for _, e in ipairs(cand) do foldTo[e] = o; e.folded = true end
      end
    end
  end

  -- links of folded nodes merge per (from, to) into one synthetic link
  local eff, merged, mlist = {}, {}, {}
  for _, L in ipairs(raw) do
    local a, b = foldTo[L.from] or L.from, foldTo[L.to] or L.to
    if a == L.from and b == L.to then
      eff[#eff + 1] = L
    else
      local key = tostring(a.id) .. ">" .. tostring(b.id)
      local m = merged[key]
      if not m then
        m = { from = a, to = b, value = 0, idx = L.idx, acc = { map = {}, list = {} }, sub = {}, parts = {} }
        merged[key] = m; eff[#eff + 1] = m; mlist[#mlist + 1] = m
      end
      m.value = m.value + L.value
      m.parts[#m.parts + 1] = L.link
      local far = (a ~= L.from) and L.from or L.to
      mergeItems(m.acc, L.link.items or far.node.items)
      m.sub[#m.sub + 1] = { label = far.node.label or tostring(far.id), value = L.value }
    end
  end
  for _, m in ipairs(mlist) do
    m.link = { from = m.from.id, to = m.to.id, value = m.value, items = itemList(m.acc),
               sub = m.sub, folded = m.parts }
    m.acc = nil
  end
  tally(eff)

  local cols, used, vis = {}, {}, {}
  for c = 0, 3 do cols[c] = { gold = {}, goods = {}, pass = { gold = 0, goods = 0 } } end
  for _, e in ipairs(ents) do
    if not e.folded and e.value > 0 then
      vis[#vis + 1] = e
      local C = cols[e.col][e.lane]; C[#C + 1] = e
      used[e.lane] = true
    end
  end
  for c = 0, 3 do table.sort(cols[c].gold, nodeLess); table.sort(cols[c].goods, nodeLess) end

  local passes = {}
  for _, L in ipairs(eff) do
    if L.to.col - L.from.col >= 2 then
      L.pass = {}
      for c = L.from.col + 1, L.to.col - 1 do
        local p = { id = "__pass:" .. (#passes + 1), pass = true, col = c, lane = L.from.lane,
                    value = L.value, lk = L }
        L.pass[#L.pass + 1] = p; passes[#passes + 1] = p
        cols[c].pass[p.lane] = cols[c].pass[p.lane] + L.value
      end
    end
  end

  -- geometry
  local gutter = opts.compact and geo.gutter or max(70, min(geo.gutter, floor(W * 0.16)))
  local plotL, plotR = gutter, W - gutter
  local plotTop, plotBot = H - geo.padT, geo.padB
  local plotH = plotTop - plotBot
  local barW = geo.barW
  if plotR - plotL < 4 * barW + 20 or plotH < 10 then out.empty = true; return out end
  local function colX(c) return plotL + COLX[c + 1] * (plotR - plotL - barW) end

  local ng, lg = geo.nodeGap, geo.laneGap
  local function gapsOf(c, gN, gL)
    local C, g = cols[c], 0
    for _, lane in ipairs(LANES) do
      if #C[lane] > 1 then g = g + (#C[lane] - 1) * gN end
    end
    if (#C.gold > 0 or C.pass.gold > 0) and (#C.goods > 0 or C.pass.goods > 0) then g = g + gL end
    return g
  end
  local maxG = 0
  for c = 0, 3 do maxG = max(maxG, gapsOf(c, ng, lg)) end
  if maxG > 0.45 * plotH then
    local f = 0.45 * plotH / maxG
    ng, lg = ng * f, lg * f
  end
  local gaps = {}
  for c = 0, 3 do gaps[c] = gapsOf(c, ng, lg) end

  -- one scale for every column; min-height bars shrink it until all columns fit
  local k = math.huge
  for c = 0, 3 do
    local T = cols[c].pass.gold + cols[c].pass.goods
    for _, lane in ipairs(LANES) do
      for _, e in ipairs(cols[c][lane]) do T = T + e.value end
    end
    if T > 0 then k = min(k, (plotH - gaps[c]) / T) end
  end
  for _ = 1, 8 do
    local nk = math.huge
    for c = 0, 3 do
      local fixed, flex = 0, cols[c].pass.gold + cols[c].pass.goods
      for _, lane in ipairs(LANES) do
        for _, e in ipairs(cols[c][lane]) do
          if e.value * k < MIN_H then fixed = fixed + MIN_H else flex = flex + e.value end
        end
      end
      if flex > 0 then nk = min(nk, (plotH - gaps[c] - fixed) / flex) end
    end
    if nk >= k then break end
    k = nk
  end
  if not (k > 0) or k == math.huge then k = 1e-9 end
  out.scale = k

  for _, e in ipairs(vis) do
    e.x, e.w = colX(e.col), barW
    e.inflated = e.value * k < MIN_H
    e.h = max(MIN_H, e.value * k)
  end

  -- gold lane hangs from the top, goods lane stands on the bottom; a single
  -- lane is centred
  local both = used.gold and used.goods
  for c = 0, 3 do
    for _, lane in ipairs(LANES) do
      local list = cols[c][lane]
      if #list > 0 then
        local S = (#list - 1) * ng
        for _, e in ipairs(list) do S = S + e.h end
        local y
        if not both then y = (plotTop + plotBot + S) / 2
        elseif lane == "gold" then y = plotTop
        else y = plotBot + S end
        for _, e in ipairs(list) do e.y = y - e.h; y = e.y - ng end
      end
    end
  end

  -- ports: ordered by the far end (gold lane first, then top to bottom), so
  -- sources enter GOLD above the sales and sales leave STOCK above the sinks
  for _, e in ipairs(vis) do e.ins, e.outs = {}, {} end
  for _, L in ipairs(eff) do
    L.t = L.value * k
    local o, i = L.from.outs, L.to.ins
    o[#o + 1] = L; i[#i + 1] = L
  end
  local function sorter(outgoing)
    return function(a, b)
      local fa, fb
      if outgoing then fa, fb = a.to, b.to else fa, fb = a.from, b.from end
      if fa.lane ~= fb.lane then return LANE_RANK[fa.lane] < LANE_RANK[fb.lane] end
      local ya, yb = fa.y + fa.h / 2, fb.y + fb.h / 2
      if ya ~= yb then return ya > yb end
      if a.value ~= b.value then return a.value > b.value end
      return a.idx < b.idx
    end
  end
  local outSort, inSort = sorter(true), sorter(false)
  local function ports(e, list, key)
    local block = 0
    for _, L in ipairs(list) do block = block + L.t end
    local top
    if e.inflated then top = e.y + (e.h + block) / 2
    elseif e.lane == "goods" then top = e.y + block
    else top = e.y + e.h end
    for _, L in ipairs(list) do
      L[key] = { top, top - L.t }
      top = top - L.t
    end
  end
  for _, e in ipairs(vis) do
    table.sort(e.outs, outSort); table.sort(e.ins, inSort)
    ports(e, e.outs, "p0"); ports(e, e.ins, "p1")
  end

  -- a pass-through sits level with the hub end of its ribbon, so the skipped
  -- column is crossed flat and the ribbon curves only once
  for _, L in ipairs(eff) do
    if L.pass then
      local span = (L.from.hub and not L.to.hub) and L.p0 or L.p1
      for _, p in ipairs(L.pass) do
        p.x, p.w, p.y, p.h = colX(p.col), barW, span[2], span[1] - span[2]
      end
    end
  end

  for _, L in ipairs(eff) do
    local pts = { { L.from.x + L.from.w, L.p0[1], L.p0[2] } }
    for _, p in ipairs(L.pass or {}) do
      pts[#pts + 1] = { p.x, p.y + p.h, p.y }
      pts[#pts + 1] = { p.x + p.w, p.y + p.h, p.y }
    end
    pts[#pts + 1] = { L.to.x, L.p1[1], L.p1[2] }
    local segs = {}
    for i = 1, #pts - 1 do
      local a, b = pts[i], pts[i + 1]
      if b[1] - a[1] > 0.01 then
        local s = { a[1], b[1], a[2], a[3], b[2], b[3] }
        local prev = segs[#segs]
        if prev and isFlat(prev) and isFlat(s) and abs(prev[5] - s[3]) < 0.01 and abs(prev[6] - s[4]) < 0.01 then
          prev[2] = s[2]
        else
          segs[#segs + 1] = s
        end
      end
    end
    local key = L.link.color
    if not key then
      local nf, nt = L.from, L.to
      key = ((nf.hub and nt.hub) or nf.hub) and nt.color or nf.color
    end
    out.links[#out.links + 1] = {
      link = L.link, segs = segs, color = key or "muted", value = L.value, t = L.t,
      from = L.from.id, to = L.to.id, fromNode = L.from.node, toNode = L.to.node,
      cross = L.from.lane ~= L.to.lane,
    }
  end

  local function side(e)
    if e.col == 0 then return "left" elseif e.col == 3 then return "right" end
    return (e.lane == "gold") and "top" or "bottom"
  end
  for c = 0, 3 do
    for _, lane in ipairs(LANES) do
      for _, e in ipairs(cols[c][lane]) do
        local n = { id = e.id, x = e.x, y = e.y, w = e.w, h = e.h, node = e.node, lane = e.lane,
                    col = e.col, value = e.value, labelSide = side(e), hub = e.hub, other = e.other }
        out.nodes[e.id] = n; out.list[#out.list + 1] = n
      end
    end
  end
  for _, p in ipairs(passes) do
    local n = { id = p.id, x = p.x, y = p.y, w = p.w, h = p.h, lane = p.lane, col = p.col,
                value = p.value, pass = true, link = p.lk.link }
    out.nodes[p.id] = n; out.list[#out.list + 1] = n
  end
  out.plot = { l = plotL, r = plotR, top = plotTop, bot = plotBot, gutter = gutter, barW = barW }
  return out
end

-- ===== Hit test (canvas coordinates) ========================================
function M.SankeyHit(layout, x, y)
  if type(layout) ~= "table" or layout.empty or not x or not y then return nil end
  for _, n in ipairs(layout.list or {}) do
    if not n.pass then
      local cy, half = n.y + n.h / 2, max(n.h, 4) / 2
      if x >= n.x - 2 and x <= n.x + n.w + 2 and abs(y - cy) <= half + 1 then
        return { kind = "node", node = n.node, value = n.value, id = n.id }
      end
    end
  end
  local best, bestD
  for i, l in ipairs(layout.links or {}) do
    for _, s in ipairs(l.segs) do
      if x >= s[1] and x <= s[2] then
        local e = ease((x - s[1]) / (s[2] - s[1]))
        local yt = s[3] + (s[5] - s[3]) * e
        local yb = s[4] + (s[6] - s[4]) * e
        local d = abs(y - (yt + yb) / 2)
        if d <= max(yt - yb, 1) / 2 + 1 and (not bestD or d < bestD) then best, bestD = i, d end
        break
      end
    end
  end
  if not best then return nil end
  local l = layout.links[best]
  return { kind = "link", link = l.link, value = l.value, from = l.fromNode, to = l.toNode, index = best }
end

-- ===== Pools on the canvas ==================================================
local function initTex(t)
  t:SetTexture(WHITE)
  if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
  if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
end

local function getTex(canvas, sk, sub)
  sk.texN = sk.texN + 1
  local t = sk.tex[sk.texN]
  if not t then
    t = canvas:CreateTexture(nil, "ARTWORK"); initTex(t)
    sk.tex[sk.texN] = t
  end
  t:SetDrawLayer("ARTWORK", sub)
  t:ClearAllPoints(); t:Show()
  return t
end

local function getFS(canvas, sk, font, size)
  sk.fsN = sk.fsN + 1
  local s = sk.fs[sk.fsN]
  if not s then
    s = canvas:CreateFontString(nil, "OVERLAY")
    sk.fs[sk.fsN] = s
  end
  if M.Theme and M.Theme.RegFont then M.Theme.RegFont(s, font, size) else s:SetFont(font, size, "") end
  s:ClearAllPoints(); s:SetWidth(0); s:SetWordWrap(false); s:SetJustifyH("CENTER")
  s:SetText(""); s:Show()
  return s
end

local function rect(canvas, sk, x, y, w, h, r, g, b, a, sub)
  local t = getTex(canvas, sk, sub)
  if t._skVO then
    t:SetVertexOffset(V_UL, 0, 0); t:SetVertexOffset(V_LL, 0, 0)
    t:SetVertexOffset(V_UR, 0, 0); t:SetVertexOffset(V_LR, 0, 0)
    t._skVO = nil
  end
  t:SetVertexColor(r, g, b, 1); t:SetAlpha(a)
  t:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", x, y)
  t:SetSize(max(w, 0.1), max(h, 0.1))
  return t
end

-- vertical-sided trapezoid: left edge ta..ba at xa, right edge tb..bb at xb
local function trap(canvas, sk, xa, xb, ta, ba, tb, bb, r, g, b, a)
  local top, bot = max(ta, tb), min(ba, bb)
  local t = getTex(canvas, sk, 0)
  t:SetVertexColor(r, g, b, 1); t:SetAlpha(a)
  t:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", xa, bot)
  t:SetSize(xb - xa, top - bot)
  t:SetVertexOffset(V_UL, 0, ta - top)
  t:SetVertexOffset(V_LL, 0, ba - bot)
  t:SetVertexOffset(V_UR, 0, tb - top)
  t:SetVertexOffset(V_LR, 0, bb - bot)
  t._skVO = true
end

-- ribbons thinner than a pixel still draw one pixel
local function fat(t, b)
  if t - b < 1 then
    local c = (t + b) / 2
    return c + 0.5, c - 0.5
  end
  return t, b
end

local function wantSlices(w, vo)
  if vo then return max(10, min(32, floor(w / 8 + 0.5))) end
  return max(10, ceil(w / 3))
end

local function drawSeg(canvas, sk, s, n, r, g, b, a)
  local x0, x1 = s[1], s[2]
  if n <= 1 then
    local t0, b0 = fat(s[3], s[4])
    local t1, b1 = fat(s[5], s[6])
    rect(canvas, sk, x0, min(b0, b1), x1 - x0, max(t0, t1) - min(b0, b1), r, g, b, a, 0)
    return
  end
  local dx = (x1 - x0) / n
  local pt, pb = fat(s[3], s[4])
  for i = 1, n do
    local e = ease(i / n)
    local qt, qb = fat(s[3] + (s[5] - s[3]) * e, s[4] + (s[6] - s[4]) * e)
    local xa = x0 + (i - 1) * dx
    if sk.vo then
      trap(canvas, sk, xa, xa + dx, pt, pb, qt, qb, r, g, b, a)
    else
      local lo = min(pb, qb)
      rect(canvas, sk, xa, lo, dx, max(pt, qt) - lo, r, g, b, a, 0)
    end
    pt, pb = qt, qb
  end
end

-- ===== Labels ===============================================================
-- Greedy by value: each block sits at its bar centre or the nearest free spot
-- within reach; the amount line goes first when space runs out, then the label.
local function placeLabels(list, H)
  table.sort(list, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return a.yc > b.yc
  end)
  local placed = {}
  local function free(c, half)
    if c - half < 1 or c + half > H - 1 then return false end
    for _, p in ipairs(placed) do
      if c - half < p.hi - 0.01 and c + half > p.lo + 0.01 then return false end
    end
    return true
  end
  for _, e in ipairs(list) do
    local reach = max(12, e.h / 2)
    for _, hb in ipairs(e.wantAmount and { 23, 12 } or { 12 }) do
      local half = hb / 2
      local cands = { e.yc }
      for _, p in ipairs(placed) do
        cands[#cands + 1] = p.hi + half + 1
        cands[#cands + 1] = p.lo - half - 1
      end
      local best, bd
      for _, c in ipairs(cands) do
        local d = abs(c - e.yc)
        if d <= reach and (not bd or d < bd) and free(c, half) then best, bd = c, d end
      end
      if best then
        e.cy, e.amount = best, hb > 12
        placed[#placed + 1] = { lo = best - half, hi = best + half }
        break
      end
    end
  end
end

local function drawLabels(canvas, sk, L)
  local T = M.Theme
  local FONT_L = (T and T.FONT_MED) or "Fonts\\ARIALN.TTF"
  local FONT_A = (T and T.FONT) or FONT_L
  local tr, tg, tb = rgb("text")
  local sr, sg, sb = rgb("sub")
  local gw = L.plot.gutter - 10
  local left, right = {}, {}
  for _, n in ipairs(L.list) do
    if not n.pass then
      local text = (n.node and n.node.label) or tostring(n.id)
      if n.labelSide == "left" or n.labelSide == "right" then
        local e = { n = n, text = text, yc = n.y + n.h / 2, h = n.h, value = n.value, wantAmount = n.h >= 10 }
        if n.labelSide == "left" then left[#left + 1] = e else right[#right + 1] = e end
      else
        -- hubs: name and amount above (gold lane) or below (goods lane) the bar
        local cx, up = n.x + n.w / 2, n.labelSide == "top"
        local amt = n.h >= 10
        local s = getFS(canvas, sk, FONT_L, 11)
        s:SetText(text); s:SetTextColor(tr, tg, tb)
        local a2
        if amt then
          a2 = getFS(canvas, sk, FONT_A, 10)
          a2:SetText(M.MoneyShort(n.value)); a2:SetTextColor(sr, sg, sb)
        end
        if up then
          if a2 then a2:SetPoint("BOTTOM", canvas, "BOTTOMLEFT", cx, n.y + n.h + 3) end
          s:SetPoint("BOTTOM", canvas, "BOTTOMLEFT", cx, n.y + n.h + (a2 and 15 or 3))
        else
          s:SetPoint("TOP", canvas, "BOTTOMLEFT", cx, n.y - 3)
          if a2 then a2:SetPoint("TOP", canvas, "BOTTOMLEFT", cx, n.y - 16) end
        end
      end
    end
  end
  placeLabels(left, L.H); placeLabels(right, L.H)
  for pass = 1, 2 do
    local list = (pass == 1) and left or right
    for _, e in ipairs(list) do
      if e.cy then
        local n = e.n
        local anchor = (pass == 1) and "RIGHT" or "LEFT"
        local x = (pass == 1) and (n.x - 6) or (n.x + n.w + 6)
        local s = getFS(canvas, sk, FONT_L, 11)
        s:SetWidth(gw); s:SetJustifyH(anchor)
        s:SetText(e.text)
        if n.other then s:SetTextColor(sr, sg, sb) else s:SetTextColor(tr, tg, tb) end
        s:SetPoint(anchor, canvas, "BOTTOMLEFT", x, e.cy + (e.amount and 5.5 or 0))
        if e.amount then
          local a = getFS(canvas, sk, FONT_A, 10)
          a:SetWidth(gw); a:SetJustifyH(anchor)
          a:SetText(M.MoneyShort(n.value)); a:SetTextColor(sr, sg, sb)
          a:SetPoint(anchor, canvas, "BOTTOMLEFT", x, e.cy - 6)
        end
      end
    end
  end
  -- sales carry their own label inside the ribbon when it is thick enough
  for _, l in ipairs(L.links) do
    local s1 = l.segs[1]
    if l.cross and l.link.label and l.t >= 11 and s1 then
      local mx = (s1[1] + s1[2]) / 2
      local my = (s1[3] + s1[4] + s1[5] + s1[6]) / 4
      local s = getFS(canvas, sk, FONT_A, 10)
      s:SetText(l.link.label); s:SetTextColor(tr, tg, tb)
      s:SetPoint("CENTER", canvas, "BOTTOMLEFT", mx, my)
      if (s:GetStringWidth() or 0) > (s1[2] - s1[1]) - 8 then s:Hide() end
    end
  end
end

-- ===== Hover / click ========================================================
local function hitKey(hit)
  if not hit then return nil end
  if hit.kind == "node" then return "n:" .. tostring(hit.id) end
  return "l:" .. tostring(hit.index) .. ":" .. tostring(hit.link and hit.link.from) .. ">" .. tostring(hit.link and hit.link.to)
end

local function groupOf(n)
  if n and not n.hub and not n.pass and n.node then return n.node.group end
  return nil
end

local function hotSets(L, hit)
  local hotN, hotL = {}, {}
  if hit.kind == "node" then
    hotN[hit.id] = true
    local g = groupOf(L.nodes[hit.id])
    if g ~= nil then
      for _, n in ipairs(L.list) do if groupOf(n) == g then hotN[n.id] = true end end
    end
    for i, l in ipairs(L.links) do
      if hotN[l.from] or hotN[l.to] then hotL[i] = true end
    end
  else
    hotL[hit.index] = true
    local l = L.links[hit.index]
    for _, id in ipairs({ l.from, l.to }) do
      local g = groupOf(L.nodes[id])
      if g ~= nil then
        for i, m in ipairs(L.links) do
          if groupOf(L.nodes[m.from]) == g or groupOf(L.nodes[m.to]) == g then hotL[i] = true end
        end
      end
    end
  end
  for i in pairs(hotL) do
    hotN[L.links[i].from] = true; hotN[L.links[i].to] = true
  end
  return hotL, hotN
end

local function restyle(sk, hit)
  local L = sk.layout
  if not L or L.empty then return end
  local hotL, hotN
  if hit then hotL, hotN = hotSets(L, hit) end
  for i, l in ipairs(L.links) do
    local a = (not hit and A_BASE) or (hotL[i] and A_HOT) or A_DIM
    for t = l._t0 or 1, l._t1 or 0 do sk.tex[t]:SetAlpha(a) end
  end
  for _, n in ipairs(L.list) do
    if n._ti then sk.tex[n._ti]:SetAlpha((not hit or hotN[n.id]) and 1 or A_BAR_DIM) end
  end
end

local function cursorXY(canvas)
  local s = canvas:GetEffectiveScale() or 1
  local cx, cy = GetCursorPosition()
  return cx / s - (canvas:GetLeft() or 0), cy / s - (canvas:GetBottom() or 0)
end

local function setHover(sk, hit)
  local key = hitKey(hit)
  if key == sk.hoverKey then return end
  sk.hoverKey = key
  restyle(sk, hit)
  local cb = sk.opts and sk.opts.onHover
  if cb then cb(hit) end
end

-- installed on enter, removes itself once the cursor has left the canvas
local function onUpdate(self, elapsed)
  local sk = self._sk
  if not sk then self:SetScript("OnUpdate", nil); return end
  sk.acc = (sk.acc or 0) + (elapsed or 0)
  if sk.acc < 0.03 then return end
  sk.acc = 0
  if sk.noHover or not self:IsMouseOver() then
    self:SetScript("OnUpdate", nil)
    setHover(sk, nil)
    return
  end
  local x, y = cursorXY(self)
  sk.lastX, sk.lastY = x, y
  setHover(sk, M.SankeyHit(sk.layout, x, y))
end

local function wire(canvas, sk)
  if sk.wired then return end
  sk.wired = true
  canvas:EnableMouse(true)
  canvas:HookScript("OnEnter", function(self)
    local s = self._sk
    if s and not s.noHover then s.acc = 1; self:SetScript("OnUpdate", onUpdate) end
  end)
  canvas:HookScript("OnHide", function(self)
    local s = self._sk
    if s then self:SetScript("OnUpdate", nil); setHover(s, nil) end
  end)
  canvas:HookScript("OnMouseUp", function(self, button)
    local s = self._sk
    if not s or s.noHover or not s.layout then return end
    local hit = M.SankeyHit(s.layout, cursorXY(self))
    local cb = s.opts and s.opts.onClick
    if hit and cb then cb(hit, button) end
  end)
end

-- ===== Render ===============================================================
function M.RenderSankey(canvas, model, opts)
  opts = opts or {}
  local sk = canvas._sk
  if not sk then
    sk = { tex = {}, fs = {}, texN = 0, fsN = 0 }
    canvas._sk = sk
  end
  sk.texN, sk.fsN = 0, 0
  if sk.vo == nil then
    local t = canvas:CreateTexture(nil, "ARTWORK"); initTex(t); t:Hide()
    sk.tex[#sk.tex + 1] = t
    sk.vo = t.SetVertexOffset ~= nil
  end

  local L = M.SankeyLayout(model, canvas:GetWidth() or 0, canvas:GetHeight() or 0, opts)
  sk.layout, sk.opts, sk.noHover = L, opts, opts.noHover and true or false

  if L.empty then
    local text = opts.emptyText or "No flows to show"
    if text ~= "" then
      local s = getFS(canvas, sk, (M.Theme and M.Theme.FONT) or "Fonts\\ARIALN.TTF", 11)
      s:SetWidth(max(0, L.W - 40)); s:SetWordWrap(true)
      s:SetText(text); s:SetTextColor(rgb("muted"))
      s:SetPoint("CENTER", canvas, "BOTTOMLEFT", L.W / 2, L.H / 2)
    end
  else
    -- slice budget: flat sections take one texture, curves share what is left
    local bars = 0
    for _, n in ipairs(L.list) do if not n.pass then bars = bars + 1 end end
    local flatN, want = 0, 0
    for _, l in ipairs(L.links) do
      for _, s in ipairs(l.segs) do
        if isFlat(s) then flatN = flatN + 1 else want = want + wantSlices(s[2] - s[1], sk.vo) end
      end
    end
    local f = 1
    local avail = TEX_BUDGET - bars - 2
    if want > 0 and flatN + want > avail then f = max(0, avail - flatN) / want end

    for _, l in ipairs(L.links) do
      local r, g, b = rgb(l.color)
      l._t0 = sk.texN + 1
      for _, s in ipairs(l.segs) do
        local n = 1
        if not isFlat(s) then
          n = wantSlices(s[2] - s[1], sk.vo)
          if f < 1 then n = max(4, floor(n * f)) end
        end
        drawSeg(canvas, sk, s, n, r, g, b, A_BASE)
      end
      l._t1 = sk.texN
    end
    for _, n in ipairs(L.list) do
      if not n.pass then
        local r, g, b = rgb(n.node and n.node.color)
        rect(canvas, sk, n.x, n.y, n.w, n.h, r, g, b, 1, 2)
        n._ti = sk.texN
      end
    end
    if not L.compact then drawLabels(canvas, sk, L) end
  end

  for i = sk.texN + 1, #sk.tex do sk.tex[i]:Hide() end
  for i = sk.fsN + 1, #sk.fs do sk.fs[i]:Hide() end

  if not sk.noHover then
    wire(canvas, sk)
    -- keep the highlight through a re-render (a click that refilters the table)
    if sk.hoverKey then
      local hit = sk.lastX and M.SankeyHit(L, sk.lastX, sk.lastY)
      if hit and hitKey(hit) == sk.hoverKey then restyle(sk, hit) end
    end
    if canvas:IsMouseOver() then canvas:SetScript("OnUpdate", onUpdate) end
  end
  return L
end
