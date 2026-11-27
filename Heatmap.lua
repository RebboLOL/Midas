-- Midas – Heat map (Charts tab): the last seven days of an item as a grid of
-- day x time of day in 3-hour windows (the Midas Server's intraday buckets),
-- each cell coloured by its lowest price against Fair, or by the units listed
-- against the item's usual supply.
-- A cell takes the item's scans inside its window: your own scans (exact),
-- else the Midas Server's median of all scanners (companion app, since
-- 1.3.7), merged and cleaned exactly like the 1W chart (M.IntraTrim); several
-- scans in one window give their median.
-- Few markets are scanned around the clock, so gaps stay visible on purpose:
--   hatched   no scan in this window, but the same time was scanned on other days
--   outlined  this time of day had no scan all week
-- Best times and the day-trade pattern only count times of day seen on
-- MIN_SEEN days or more. Own scans alone cannot fill an hourly grid (Data.lua
-- keeps the newest 16 per item), hence the 3-hour windows.
local ADDON, M = ...
local T = M.Theme
local C = T.C
local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local WHITE = "Interface\\Buttons\\WHITE8X8"
local HATCH = "Interface\\AddOns\\" .. (ADDON or "Midas") .. "\\Media\\Hatch"
local DOT = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
local DASH = "\226\128\147"       -- en dash
local SEP = "  \194\183  "

local STEP       = 10800  -- 3 h windows, aligned like the server's buckets
local NCOL       = 8
local NROW       = 7
local MIN_SEEN   = 3      -- a time of day counts for Best times once seen on 3 days
local AH_CUT     = 0.05   -- the auction house keeps 5 % of a sale
local SPAN_PRICE = 0.08   -- full colour at 8 % below / above Fair
local SPAN_QTY   = 0.40   -- full colour at 40 % more / fewer units than usual
local CALM       = 0.12   -- |score| below this stays neutral
M.HEAT = { STEP = STEP, NCOL = NCOL, NROW = NROW, MIN_SEEN = MIN_SEEN, AH_CUT = AH_CUT }

local function median(list)
  local n = #list
  if n == 0 then return nil end
  table.sort(list)
  if n % 2 == 1 then return list[(n + 1) / 2] end
  return (list[n / 2] + list[n / 2 + 1]) / 2
end

-- ===== Data =================================================================
-- "06" for a window starting on the full hour, else "05:30" (half-hour zones)
local function hm(t)
  return (date("%M", t) == "00") and date("%H", t) or date("%H:%M", t)
end

-- local midnight that starts the oldest day of the grid
local function gridStart(now)
  local tn = date("*t", now)
  return time({ year = tn.year, month = tn.month, day = tn.day - (NROW - 1), hour = 0, min = 0, sec = 0 })
end

-- Is there anything for a heat map of this item? (Link chips and the item
-- menu ask for every item they show: cheap checks only. M.ServerIntra keeps
-- its parsed items, misses included.)
function M.HeatAvailable(key)
  if key == nil then return false end
  key = tostring(key)
  -- the first window of the grid (a scan before it, e.g. 00:30 when the
  -- windows start at 01:00, belongs to the day before)
  local tFirst = math.ceil(gridStart(time()) / STEP) * STEP
  local st = M.IntraList and M.IntraList(key)
  local lp = st and st[#st]
  if lp and (lp.ts or 0) >= tFirst then return true end
  -- a point that kept an older time (tails of the 1.3.8 test builds): its
  -- newest marked window counts too
  if lp and tonumber(lp.w0) and type(lp.wm) == "string" and (lp.w0 + #lp.wm) * STEP > tFirst then return true end
  local srv = M.ServerIntra and M.ServerIntra(key)
  local last = srv and srv[#srv]
  return (last and (last.b1 or last.ts or 0) > tFirst) and true or false
end

-- The grid of one item.
-- rows[r] (r = 1 oldest .. 7 today) = { ts (noon), date, label, cells[c] }
-- cell = { r, c, b0, b1, future, has, low, qty, own, srv, lastOwn }
--   future = the window has not started yet, or it is running without a scan
-- cols[c] = { c, b0, short ("06–09"), range ("06:00–09:00"), past, n, low, qty }
--   (labels from the newest day: after a clock change the older days' windows
--   sit an hour off, the cells keep their own times)
-- plus fair (copper; fairOwn = from Midas' Fair, else the week's median),
-- medQ (usual units), nPast / nData (windows so far / with a scan), cheap and
-- dear (Best times), nElig (times of day seen on MIN_SEEN days), trade
-- (day-trade pattern), blind and few (column lists), srvOn (server windows
-- reach into the grid).
function M.HeatModel(key, now)
  if key == nil then return nil end
  key = tostring(key)
  now = now or time()
  -- the seven local days, oldest first, keyed by their date; stepping back
  -- from today's noon never skips or repeats a date over a clock change
  local tn = date("*t", now)
  local noon = time({ year = tn.year, month = tn.month, day = tn.day, hour = 12, min = 0, sec = 0 })
  local t0 = gridStart(now)
  local rows, rowOf = {}, {}
  for r = 1, NROW do
    local t = noon - (NROW - r) * 86400
    local ds = date("%Y%m%d", t)
    rows[r] = { ts = t, date = ds, label = date("%a %d", t), cells = {} }
    rowOf[ds] = r
  end
  -- every window starting on one of these days; column = local start hour / 3
  -- (the windows sit on the server's UTC-aligned buckets, so in a time zone a
  -- few hours off UTC they start at 01:00 / 02:00 - the labels say so)
  local cellOf, colB0 = {}, {}
  local first = floor((t0 - STEP) / STEP) * STEP
  for b0 = first, noon + 12 * 3600, STEP do
    local r = rowOf[date("%Y%m%d", b0)]
    if r then
      local c = floor(tonumber(date("%H", b0)) / 3) + 1
      -- a clock change can map two windows on one cell: the first one stays
      if c >= 1 and c <= NCOL and not rows[r].cells[c] then
        local cell = { r = r, c = c, b0 = b0, b1 = b0 + STEP, future = b0 > now,
                       running = b0 <= now and now < b0 + STEP,
                       ownL = {}, ownQ = {}, srvL = {}, srvQ = {}, own = 0, srv = 0 }
        rows[r].cells[c] = cell
        cellOf[b0] = cell
        colB0[c] = b0            -- the newest day's window names the column
      end
    end
  end

  -- the item's scans: own scans + server windows without an own scan, sorted,
  -- single outliers out (the 1W chart's rules, Charts.lua). A run of scans at
  -- an unchanged price is one stored point (Data.lua slides its ts); its w0 /
  -- wm list the 3-hour windows the run was scanned in, each one an own scan
  -- of that price (synthetic = no exact time).
  local own = M.IntraList and M.IntraList(key)
  local srv = M.ServerIntra and M.ServerIntra(key)
  local all = {}
  for i = 1, (own and #own or 0) do
    local e = own[i]
    if e.ts and e.low then
      all[#all + 1] = { ts = e.ts, low = e.low, qty = e.qty or 0 }
      local w0, wm = tonumber(e.w0), e.wm
      if w0 and type(wm) == "string" then
        local wLast = floor(e.ts / STEP)
        for k = 1, #wm do
          local w = w0 + k - 1
          if w ~= wLast and wm:sub(k, k) == "1" then
            -- the window middle; the run's first window shares the previous
            -- stored point's window, so there it stays after that point (the
            -- run began after it) - else the outlier rule would see a zigzag
            local ts = w * STEP + STEP / 2
            local prev = own[i - 1]
            if w == w0 and prev and prev.ts and ts <= prev.ts then ts = prev.ts + 1 end
            -- a window marked after the point (a point that kept an older
            -- time, tails of the 1.3.8 test builds) lies before the next stored
            -- point: the next one began only after the run's last repeat
            local nxt = own[i + 1]
            if w > wLast and nxt and nxt.ts and ts >= nxt.ts then ts = math.max(e.ts + 1, nxt.ts - 1) end
            all[#all + 1] = { ts = ts, low = e.low, qty = e.qty or 0, synth = true }
          end
        end
      end
    end
  end
  local nOwn = #all
  local srvOn = false
  if srv then
    local last = srv[#srv]
    srvOn = (last and (last.b1 or last.ts or 0) > math.ceil(t0 / STEP) * STEP) and true or false
    for _, p in ipairs(srv) do
      -- a server window inside one cell steps back for an own scan in it (as
      -- in the chart); one across cells stays, the cell rule below decides
      local mine = false
      if floor(p.b0 / STEP) == floor((p.b1 - 1) / STEP) then
        for j = 1, nOwn do
          local o = all[j].ts
          if o >= p.b0 and o < p.b1 then mine = true; break end
        end
      end
      if not mine then
        all[#all + 1] = { ts = p.ts, low = p.low, qty = p.qty or 0, srv = true, b0 = p.b0, b1 = p.b1 }
      end
    end
  end
  table.sort(all, function(a, b)
    if a.ts ~= b.ts then return a.ts < b.ts end
    return not a.srv and b.srv or false
  end)
  if M.IntraTrim then all = M.IntraTrim(all) end
  for _, e in ipairs(all) do
    if e.srv then
      -- a server window counts for every cell it overlaps; one still running
      -- only up to its point (its scans so far lie before e.ts)
      local done = e.b1 <= now
      local b = floor(e.b0 / STEP) * STEP
      while b < e.b1 do
        local cell = cellOf[b]
        if cell and not cell.future and (done or b < e.ts or b == floor(e.b0 / STEP) * STEP) then
          cell.srvL[#cell.srvL + 1] = e.low; cell.srvQ[#cell.srvQ + 1] = e.qty or 0
          cell.srv = cell.srv + 1
        end
        b = b + STEP
      end
    else
      local cell = cellOf[floor(e.ts / STEP) * STEP]
      if cell and not cell.future then
        cell.ownL[#cell.ownL + 1] = e.low; cell.ownQ[#cell.ownQ + 1] = e.qty or 0
        cell.own = cell.own + 1
        if not e.synth and (not cell.lastOwn or e.ts > cell.lastOwn) then cell.lastOwn = e.ts end
      end
    end
  end

  local nPast, nData, lows, qtys = 0, 0, {}, {}
  for r = 1, NROW do
    for c = 1, NCOL do
      local cell = rows[r].cells[c]
      if cell then
        -- own scans are exact: they win the cell
        local L, Q = cell.ownL, cell.ownQ
        if not L[1] then L, Q = cell.srvL, cell.srvQ; cell.own = 0 else cell.srv = 0 end
        -- the running window only counts once it has a scan
        if cell.running and not L[1] then cell.future = true end
        if not cell.future then
          nPast = nPast + 1
          if L[1] then
            cell.has = true
            cell.low = floor(median(L) + 0.5)
            cell.qty = median(Q) or 0
            nData = nData + 1
            lows[#lows + 1] = cell.low
            qtys[#qtys + 1] = cell.qty
          end
        end
        cell.ownL, cell.ownQ, cell.srvL, cell.srvQ = nil, nil, nil, nil
      end
    end
  end

  local m = M.Metrics and M.GetSeries and M.Metrics(M.GetSeries(key) or {}, key)
  local fair = m and m.fair and m.fair > 0 and m.fair or nil
  local fairOwn = fair ~= nil
  if not fair then fair = median(lows) end
  local medQ = median(qtys)
  if not medQ or medQ <= 0 then medQ = 1 end

  local cols = {}
  for c = 1, NCOL do
    local b = colB0[c]
    local col = { c = c, b0 = b, past = 0, n = 0, short = "", range = "" }
    if b then
      col.short = hm(b) .. DASH .. hm(b + STEP)
      col.range = date("%H:%M", b) .. DASH .. date("%H:%M", b + STEP)
    end
    local sl, sq = 0, 0
    for r = 1, NROW do
      local cell = rows[r].cells[c]
      if cell and not cell.future then
        col.past = col.past + 1
        if cell.has then col.n = col.n + 1; sl = sl + cell.low; sq = sq + cell.qty end
      end
    end
    if col.n > 0 then col.low, col.qty = sl / col.n, sq / col.n end
    cols[c] = col
  end

  -- Best times: the cheapest and the dearest times of day seen on enough days
  local elig = {}
  for c = 1, NCOL do if cols[c].n >= MIN_SEEN then elig[#elig + 1] = cols[c] end end
  table.sort(elig, function(a, b)
    if a.low ~= b.low then return a.low < b.low end
    return a.c < b.c
  end)
  local take = min(3, floor(#elig / 2))
  local cheap, dear = {}, {}
  for i = 1, take do cheap[i] = elig[i]; dear[i] = elig[#elig + 1 - i] end
  local trade
  local buy, sell = cheap[1], dear[1]
  if buy and sell and buy.c ~= sell.c then
    -- a dear time earlier in the day than the cheap one sells the next day
    local nextDay = sell.c < buy.c
    local both, won = 0, 0
    for r = 1, NROW do
      local a = rows[r].cells[buy.c]
      local b = rows[nextDay and r + 1 or r]
      b = b and b.cells[sell.c]
      if a and b and a.has and b.has then
        both = both + 1
        if b.low * (1 - AH_CUT) > a.low then won = won + 1 end
      end
    end
    trade = { buy = buy, sell = sell, margin = sell.low * (1 - AH_CUT) - buy.low, both = both, won = won,
              nextDay = nextDay }
  end
  local blind, few = {}, {}
  for c = 1, NCOL do
    if cols[c].past > 0 then
      if cols[c].n == 0 then blind[#blind + 1] = c
      elseif cols[c].n < MIN_SEEN then few[#few + 1] = c end
    end
  end
  return { key = key, now = now, rows = rows, cols = cols, fair = fair, fairOwn = fairOwn, medQ = medQ,
           nPast = nPast, nData = nData, cheap = cheap, dear = dear, nElig = #elig, trade = trade,
           blind = blind, few = few, srvOn = srvOn, nOwn = nOwn }
end

-- "02:00–05:00, 11:00–14:00" for a list of column numbers (neighbours merged,
-- at most three ranges; every column = "all times of day")
function M.HeatRanges(model, list)
  if #list >= NCOL then return "all times of day" end
  local out, s, p = {}, nil, nil
  local function push()
    local a, b = model.cols[s].b0, model.cols[p].b0
    if a and b then out[#out + 1] = date("%H:%M", a) .. DASH .. date("%H:%M", b + STEP) end
  end
  for _, c in ipairs(list) do
    if not s then s, p = c, c
    elseif c == p + 1 then p = c
    else push(); s, p = c, c end
  end
  if s then push() end
  if #out > 3 then return table.concat(out, ", ", 1, 3) .. " \226\128\166" end
  return table.concat(out, ", ")
end

-- ===== Colours ==============================================================
-- signed score: below zero = good to buy (green), above zero = dear or thin (red)
local function scoreOf(model, metric, low, qty)
  if metric == "qty" then return -((qty or 0) / model.medQ - 1) / SPAN_QTY end
  return (low / model.fair - 1) / SPAN_PRICE
end

local function mix(a, b, t)
  return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t
end

local NEU, GRN, RED
local function fillOf(s)
  if not NEU then
    NEU = { mix(C.bg1, C.accent, 0.10) }
    GRN = { mix(C.bg1, C.green, 0.42) }
    RED = { mix(C.bg1, C.red, 0.42) }
  end
  local t = min(1, abs(s))
  if t < CALM then return NEU[1], NEU[2], NEU[3] end
  return mix(NEU, (s < 0) and GRN or RED, 0.25 + 0.75 * t)
end
M.HeatFill = fillOf

local function textOf(s)
  if abs(s) < CALM then return C.accent end
  return (s < 0) and C.green or C.red
end

local function valText(metric, low, qty)
  if metric == "qty" then return tostring(floor((qty or 0) + 0.5)) end
  return M.MoneyPlain(low)
end

local function pct(v)
  local r = floor(v * 100 + 0.5)
  if r > 0 then return "+" .. r .. " %" end
  if r < 0 then return "\226\136\146" .. (-r) .. " %" end
  return "\194\177" .. "0 %"
end

-- ===== View =================================================================
local LBL_W, AVG_W, GAP = 82, 72, 2
local HEAD_H, FOOT_H, SEEN_H = 14, 22, 12

-- four 1px edges around a box (outlines without a backdrop frame)
local function Edges(parent, layer, sub)
  local e = { parent = parent }
  for i = 1, 4 do
    local t = parent:CreateTexture(nil, layer or "OVERLAY", nil, sub or 0)
    t:SetTexture(WHITE); t:Hide()
    e[i] = t
  end
  function e:Place(x, y, w, h, col, a)
    local p = self.parent
    self[1]:ClearAllPoints(); self[1]:SetPoint("TOPLEFT", p, "TOPLEFT", x, y); self[1]:SetSize(w, 1)
    self[2]:ClearAllPoints(); self[2]:SetPoint("TOPLEFT", p, "TOPLEFT", x, y - h + 1); self[2]:SetSize(w, 1)
    self[3]:ClearAllPoints(); self[3]:SetPoint("TOPLEFT", p, "TOPLEFT", x, y); self[3]:SetSize(1, h)
    self[4]:ClearAllPoints(); self[4]:SetPoint("TOPLEFT", p, "TOPLEFT", x + w - 1, y); self[4]:SetSize(1, h)
    for i = 1, 4 do self[i]:SetVertexColor(col[1], col[2], col[3], a or 1); self[i]:Show() end
  end
  function e:Off() for i = 1, 4 do self[i]:Hide() end end
  return e
end

local function hatchTex(parent, sub)
  local t = parent:CreateTexture(nil, "ARTWORK", nil, sub or 1)
  t:SetTexture(HATCH, "REPEAT", "REPEAT")
  if t.SetHorizTile then t:SetHorizTile(true) end
  if t.SetVertTile then t:SetVertTile(true) end
  t:SetVertexColor(C.borderlt[1], C.borderlt[2], C.borderlt[3], 0.55)
  t:Hide()
  return t
end

local function box(parent, tex, x, y, w, h)
  tex:ClearAllPoints()
  tex:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  tex:SetSize(max(1, w), max(1, h))
end

function M.BuildHeat(panel)
  if M.heatView then return M.heatView end
  local hv = CreateFrame("Frame", nil, panel)
  hv:SetAllPoints()
  hv:SetFrameLevel(panel:GetFrameLevel() + 40)
  local hvbg = hv:CreateTexture(nil, "BACKGROUND")
  hvbg:SetAllPoints(); hvbg:SetColorTexture(C.bg0[1], C.bg0[2], C.bg0[3], 1)
  hv:EnableMouse(true)

  -- header: icon + name as a live item link, the item's other pages, back
  hv.icon = hv:CreateTexture(nil, "ARTWORK")
  hv.icon:SetSize(20, 20); hv.icon:SetPoint("TOPLEFT", 2, -3)
  hv.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  hv.title = T.Text(hv, T.SIZE.h1, "text", T.FONT_SEMI)
  hv.title:SetPoint("TOPLEFT", 28, -4); hv.title:SetJustifyH("LEFT")
  hv.titleBtn = CreateFrame("Button", nil, hv)
  hv.titleBtn:SetPoint("TOPLEFT", 0, -2); hv.titleBtn:SetSize(140, 24)
  hv.titleBtn:SetFrameLevel(hv:GetFrameLevel() + 5)
  hv.titleBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  hv.titleBtn:SetScript("OnEnter", function(self)
    if not hv.key then return end
    local id = M.BaseID and M.BaseID(hv.key) or tonumber(hv.key)
    if id then
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
      GameTooltip:SetHyperlink("item:" .. id)
      GameTooltip:Show()
    end
  end)
  hv.titleBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  hv.titleBtn:SetScript("OnClick", function()
    if not hv.key then return end
    if M.ModPostDown and M.ModPostDown() then M.PostItemStats(hv.key)
    elseif M.ModSearchDown and M.ModSearchDown() then M.ItemShiftAction(hv.key)
    else GameTooltip:Hide(); if M.ItemMenu then M.ItemMenu(hv.key) end end
  end)
  local back = T.Button(hv, "< back", 88, 22)
  back:SetPoint("TOPRIGHT", -2, -2)
  back:SetScript("OnClick", function() hv:Hide() end)
  hv.back = back
  if M.LinkBar then
    hv.links = M.LinkBar(hv, { except = "heat", watch = true })
    hv.links:SetPoint("TOPRIGHT", back, "TOPLEFT", -10, -1)
    hv.links:SetFrameLevel(hv:GetFrameLevel() + 6)
  end

  -- tool row: what the colour shows, and how much of the week has a scan
  local showLbl = T.Text(hv, T.SIZE.tiny, "sub", T.FONT_MED)
  showLbl:SetPoint("TOPLEFT", 2, -37); showLbl:SetText("SHOW")
  local seg = T.Segment(hv, {
    { key = "price", label = "Lowest price vs Fair" },
    { key = "qty",   label = "Units listed" },
  }, function(k)
    if M.db and M.db.config then M.db.config.heatMetric = (k == "qty") and "qty" or nil end
    M.FillHeat()
  end)
  seg.frame:SetPoint("LEFT", showLbl, "RIGHT", 8, 0)
  hv.seg = seg
  if T.HelpTip then
    T.HelpTip(seg.frame, "Heat map colours", {
      "Lowest price vs Fair - green when the window's lowest buyout sat under the item's Fair price, red when above; full colour at 8 % off Fair.",
      "Units listed - green when more units than usual were on the auction house, red when fewer; full colour at 40 % off the item's usual supply." })
  end
  hv.covText = T.Text(hv, T.SIZE.small, "sub")
  hv.covText:SetPoint("TOPRIGHT", -2, -36); hv.covText:SetJustifyH("RIGHT")
  hv.covBg = hv:CreateTexture(nil, "ARTWORK")
  hv.covBg:SetColorTexture(C.bg2[1], C.bg2[2], C.bg2[3], 1); hv.covBg:SetSize(90, 6)
  hv.covBg:SetPoint("RIGHT", hv.covText, "LEFT", -8, 0)
  hv.covFill = hv:CreateTexture(nil, "OVERLAY")
  hv.covFill:SetTexture(WHITE); hv.covFill:SetHeight(6)
  hv.covFill:SetPoint("LEFT", hv.covBg, "LEFT", 0, 0)
  local covHot = CreateFrame("Button", nil, hv)
  covHot:SetPoint("LEFT", hv.covBg, "LEFT", 0, 0); covHot:SetPoint("RIGHT", hv.covText, "RIGHT", 0, 0)
  covHot:SetHeight(16)
  if T.HelpTip then
    T.HelpTip(covHot, "Scanned windows", {
      "How many of the 3-hour windows of the last seven days have a scan of this item, up to now.",
      "Your own scans count, and with the Midas Companion app also what all scanners on your auction house saw (Midas Server)." })
  end

  -- one quiet line about the gaps (shown when there are any)
  hv.banner = CreateFrame("Button", nil, hv)
  hv.banner:SetPoint("TOPLEFT", 0, -60); hv.banner:SetPoint("TOPRIGHT", 0, -60); hv.banner:SetHeight(16)
  local bdot = hv.banner:CreateTexture(nil, "ARTWORK")
  bdot:SetTexture(DOT); bdot:SetSize(7, 7); bdot:SetPoint("LEFT", 4, 0)
  bdot:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 1)
  hv.bannerDot = bdot
  hv.bannerText = T.Text(hv.banner, T.SIZE.small, "sub")
  hv.bannerText:SetPoint("LEFT", 16, 0); hv.bannerText:SetPoint("RIGHT", -2, 0); hv.bannerText:SetJustifyH("LEFT")
  if T.HelpTip then
    T.HelpTip(hv.banner, "Gaps in the scan history", {
      "Hatched cell - no scan in this window, but this time of day was scanned on other days.",
      "Outlined cell - this time of day had no scan all week.",
      "Best times and the day-trade pattern only use times of day seen on 3 or more days. Scans at other times - yours, or other players' through the Midas Companion app - fill the gaps." })
  end

  -- the grid
  local grid = CreateFrame("Frame", nil, hv)
  grid:SetPoint("BOTTOMRIGHT", 0, 0)
  grid:EnableMouse(true)
  hv.grid = grid
  hv.headL = T.Text(grid, T.SIZE.tiny, "sub", T.FONT_MED); hv.headL:SetJustifyH("LEFT")
  hv.headR = T.Text(grid, T.SIZE.tiny, "sub", T.FONT_MED); hv.headR:SetJustifyH("RIGHT")
  hv.headL:SetText("your time"); hv.headR:SetText("Day avg")
  hv.colLbl, hv.rowLbl, hv.rowCnt, hv.rowAvg, hv.cells = {}, {}, {}, {}, {}
  hv.foot, hv.seen = {}, {}
  for c = 1, NCOL do
    local fs = T.Text(grid, T.SIZE.tiny, "sub", T.FONT_MED); fs:SetJustifyH("CENTER")
    hv.colLbl[c] = fs
  end
  for r = 1, NROW do
    hv.rowLbl[r] = T.Text(grid, T.SIZE.small, "text", T.FONT_SEMI); hv.rowLbl[r]:SetJustifyH("LEFT")
    hv.rowCnt[r] = T.Text(grid, T.SIZE.tiny, "sub"); hv.rowCnt[r]:SetJustifyH("RIGHT")
    hv.rowAvg[r] = T.Text(grid, T.SIZE.small, "text", T.FONT_SEMI); hv.rowAvg[r]:SetJustifyH("RIGHT")
    hv.cells[r] = {}
    for c = 1, NCOL do
      local o = {}
      o.fill = grid:CreateTexture(nil, "ARTWORK", nil, 0); o.fill:SetTexture(WHITE)
      o.hatch = hatchTex(grid, 1)
      o.fs = T.Text(grid, T.SIZE.small, "text", T.FONT_MED); o.fs:SetJustifyH("CENTER")
      o.edge = Edges(grid, "ARTWORK", 2)
      hv.cells[r][c] = o
    end
  end
  hv.sep = grid:CreateTexture(nil, "ARTWORK"); hv.sep:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
  hv.footLbl = T.Text(grid, T.SIZE.small, "sub", T.FONT_SEMI); hv.footLbl:SetJustifyH("LEFT"); hv.footLbl:SetText("7-day avg")
  hv.seenLbl = T.Text(grid, T.SIZE.tiny, "sub"); hv.seenLbl:SetJustifyH("LEFT"); hv.seenLbl:SetText("Days seen")
  for c = 1, NCOL do
    local o = {}
    o.fill = grid:CreateTexture(nil, "ARTWORK", nil, 0); o.fill:SetTexture(WHITE)
    o.fs = T.Text(grid, T.SIZE.small, "text", T.FONT_SEMI); o.fs:SetJustifyH("CENTER")
    o.edge = Edges(grid, "ARTWORK", 2)
    hv.foot[c] = o
    local s = T.Text(grid, T.SIZE.tiny, "sub"); s:SetJustifyH("CENTER")
    hv.seen[c] = s
  end
  hv.selEdge = Edges(grid, "OVERLAY", 7)

  -- nothing to show yet
  hv.empty = CreateFrame("Frame", nil, hv)
  hv.empty:SetAllPoints(grid)
  hv.emptyT = T.Text(hv.empty, T.SIZE.h2, "text", T.FONT_SEMI)
  hv.emptyT:SetPoint("BOTTOM", hv.empty, "CENTER", 0, 4)
  hv.emptyS = T.Text(hv.empty, T.SIZE.small, "sub")
  hv.emptyS:SetPoint("TOP", hv.empty, "CENTER", 0, -4)
  hv.emptyS:SetWidth(520); hv.emptyS:SetWordWrap(true); hv.emptyS:SetJustifyH("CENTER")
  hv.emptyT:SetText("No scans through the day for this item yet")
  hv.emptyS:SetText("Every scan fills its 3-hour window. With the Midas Companion app the Midas Server adds what all scanners on your auction house saw.")
  hv.empty:Hide()

  -- the three cards under the grid
  local function card()
    local s = T.Surface(hv, "bg1", "border")
    s.title = T.Text(s, T.SIZE.tiny, "sub", T.FONT_MED)
    s.title:SetPoint("TOPLEFT", 10, -8); s.title:SetJustifyH("LEFT")
    return s
  end
  local A = card()
  A.when = T.Text(A, T.SIZE.body, "text", T.FONT_SEMI); A.when:SetJustifyH("LEFT")
  A.src = T.Text(A, T.SIZE.small, "sub"); A.src:SetJustifyH("LEFT")
  A.k, A.v = {}, {}
  for i = 1, 3 do
    A.k[i] = T.Text(A, T.SIZE.tiny, "sub", T.FONT_MED); A.k[i]:SetJustifyH("LEFT")
    A.v[i] = T.Text(A, T.SIZE.body, "text", T.FONT_SEMI); A.v[i]:SetJustifyH("LEFT")
  end
  A.k[1]:SetText("LOWEST"); A.k[2]:SetText("VS FAIR"); A.k[3]:SetText("UNITS LISTED")
  A.note = T.Text(A, T.SIZE.small, "sub"); A.note:SetJustifyH("LEFT"); A.note:SetJustifyV("TOP")
  A.note:SetWordWrap(true)
  hv.cardA = A
  local B = card()
  B.title:SetText("BEST TIMES  \194\183  7-DAY AVERAGE")
  B.hint = T.Text(B, T.SIZE.tiny, "sub"); B.hint:SetPoint("TOPRIGHT", -10, -8); B.hint:SetJustifyH("RIGHT")
  B.hint:SetText("times seen on 3+ days")
  B.h1 = T.Text(B, T.SIZE.small, "green", T.FONT_SEMI); B.h1:SetJustifyH("LEFT"); B.h1:SetText("Cheapest to buy")
  B.h2 = T.Text(B, T.SIZE.small, "red", T.FONT_SEMI); B.h2:SetJustifyH("LEFT"); B.h2:SetText("Dearest to sell")
  B.r1, B.p1, B.r2, B.p2 = {}, {}, {}, {}
  for i = 1, 3 do
    B.r1[i] = T.Text(B, T.SIZE.small, "text", T.FONT_MED); B.r1[i]:SetJustifyH("LEFT")
    B.p1[i] = T.Text(B, T.SIZE.small, "teal"); B.p1[i]:SetJustifyH("RIGHT")
    B.r2[i] = T.Text(B, T.SIZE.small, "text", T.FONT_MED); B.r2[i]:SetJustifyH("LEFT")
    B.p2[i] = T.Text(B, T.SIZE.small, "teal"); B.p2[i]:SetJustifyH("RIGHT")
  end
  B.note = T.Text(B, T.SIZE.tiny, "sub"); B.note:SetJustifyH("LEFT")
  B.empty = T.Text(B, T.SIZE.small, "sub"); B.empty:SetJustifyH("LEFT"); B.empty:SetJustifyV("TOP")
  B.empty:SetWordWrap(true)
  B.empty:SetText("Not enough history yet: no time of day has a scan on 3 or more days. It fills in as you and other scanners scan at different times.")
  hv.cardB = B
  if T.HelpTip then
    T.HelpTip(B, "Best times", {
      "The times of day with the lowest and the highest average lowest buyout over the last seven days.",
      "Only times of day scanned on 3 or more days count - a time with fewer scans could be a lucky one." })
  end
  local Cc = card()
  Cc.title:SetText("DAY-TRADE PATTERN")
  Cc.l, Cc.v = {}, {}
  for i = 1, 4 do
    Cc.l[i] = T.Text(Cc, T.SIZE.small, "sub"); Cc.l[i]:SetJustifyH("LEFT")
    Cc.v[i] = T.Text(Cc, T.SIZE.small, "text", T.FONT_SEMI); Cc.v[i]:SetJustifyH("RIGHT")
  end
  Cc.l[1]:SetText("Buy"); Cc.l[2]:SetText("Sell"); Cc.l[3]:SetText("Per unit after the 5 % AH cut"); Cc.l[4]:SetText("Profitable on")
  Cc.div = Cc:CreateTexture(nil, "ARTWORK"); Cc.div:SetColorTexture(C.border[1], C.border[2], C.border[3], 1); Cc.div:SetHeight(1)
  Cc.foot = T.Text(Cc, T.SIZE.tiny, "sub"); Cc.foot:SetJustifyH("LEFT")
  Cc.foot:SetText("7-day average, not a forecast. Deposit not included.")
  Cc.empty = T.Text(Cc, T.SIZE.small, "sub"); Cc.empty:SetJustifyH("LEFT"); Cc.empty:SetJustifyV("TOP")
  Cc.empty:SetWordWrap(true)
  Cc.empty:SetText("No pattern to show yet: it needs a cheap and a dear time of day, each scanned on 3 or more days.")
  hv.cardC = Cc
  if T.HelpTip then
    T.HelpTip(Cc, "Day-trade pattern", {
      "Buy at the cheapest time of day, list at the dearest: what that left per unit on average after the auction house's 5 % cut, and on how many of the days with both times scanned it would have paid off.",
      "An average of the last seven days, not a forecast; the deposit and undercuts are not included." })
  end

  -- legend
  hv.lg = {}
  local lg = hv.lg
  lg.left = T.Text(hv, T.SIZE.small, "sub")
  lg.sw = {}
  for i = 1, 7 do lg.sw[i] = hv:CreateTexture(nil, "ARTWORK"); lg.sw[i]:SetTexture(WHITE) end
  lg.right = T.Text(hv, T.SIZE.small, "sub")
  lg.mid = T.Text(hv, T.SIZE.small, "sub")
  lg.hFill = hv:CreateTexture(nil, "ARTWORK", nil, 0); lg.hFill:SetColorTexture(C.bg1[1], C.bg1[2], C.bg1[3], 1)
  lg.hatch = hatchTex(hv, 1)
  lg.hTxt = T.Text(hv, T.SIZE.small, "sub"); lg.hTxt:SetText("No scan, time seen on other days")
  lg.oEdge = Edges(hv, "ARTWORK", 2)
  lg.oTxt = T.Text(hv, T.SIZE.small, "sub"); lg.oTxt:SetText("Time never scanned this week")
  lg.bEdge = Edges(hv, "ARTWORK", 2)
  lg.sEdge = Edges(hv, "ARTWORK", 2)
  lg.bTxt = T.Text(hv, T.SIZE.small, "sub"); lg.bTxt:SetText("Best buy / sell time")

  -- hover: the cell under the cursor becomes the selected one
  grid:SetScript("OnUpdate", function(self)
    local g, model = hv.geo, hv.model
    if not (g and model and model.nData > 0 and self:IsMouseOver()) then return end
    local s = self:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    local left, top = self:GetLeft(), self:GetTop()
    if not (cx and left and top and s and s > 0) then return end
    local x, y = cx / s - left, top - cy / s
    local c = floor((x - g.x0) / (g.colW + GAP)) + 1
    local r = floor((y - g.y0) / (g.rowH + GAP)) + 1
    if c < 1 or c > NCOL or r < 1 or r > NROW then return end
    local cell = model.rows[r].cells[c]
    if cell and not cell.future and (hv.selR ~= r or hv.selC ~= c) then
      hv.selR, hv.selC = r, c
      M.HeatPaintSel()
    end
  end)

  hv:SetScript("OnHide", function()
    GameTooltip:Hide()
    if panel:IsShown() and M.chartKey and M.RenderItemChart and M.canvas then M.RenderItemChart(M.canvas, M.chartKey) end
  end)
  -- dragging the window edge fires this every frame: one refill per 0.1 s
  hv:SetScript("OnSizeChanged", function()
    if not hv:IsShown() or hv._sizePending then return end
    hv._sizePending = true
    C_Timer.After(0.1, function()
      hv._sizePending = nil
      if hv:IsShown() then M.FillHeat() end
    end)
  end)
  T.OnFontScale(function() if hv:IsShown() then M.FillHeat() end end)
  hv:Hide()
  M.heatView = hv
  return hv
end

local function metricNow()
  return (M.db and M.db.config and M.db.config.heatMetric == "qty") and "qty" or "price"
end

-- the selected cell: outline, row and column labels, the left card
function M.HeatPaintSel()
  local hv, model, g = M.heatView, M.heatView and M.heatView.model, M.heatView and M.heatView.geo
  if not (hv and model and g) then return end
  local r, c = hv.selR, hv.selC
  for i = 1, NROW do
    local on = (i == r)
    hv.rowLbl[i]:SetTextColor(T.Unpack(on and C.accent or C.text))
  end
  for j = 1, NCOL do
    hv.colLbl[j]:SetTextColor(T.Unpack((j == c) and C.accent or C.sub))
  end
  local A = hv.cardA
  local cell = r and c and model.rows[r] and model.rows[r].cells[c]
  if not cell then
    hv.selEdge:Off()
    A.when:SetText(""); A.src:SetText("")
    for i = 1, 3 do A.k[i]:Hide(); A.v[i]:Hide() end
    A.note:SetText(""); A.note:Show()
    return
  end
  hv.selEdge:Place(g.x0 + (c - 1) * (g.colW + GAP), -(g.y0 + (r - 1) * (g.rowH + GAP)), g.colW, g.rowH, C.text, 1)
  local row = model.rows[r]
  A.when:SetText(date("%a %d %b", row.ts) .. SEP .. date("%H:%M", cell.b0) .. DASH .. date("%H:%M", cell.b1))
  local metric = metricNow()
  if cell.has then
    local srcTxt
    if cell.own == 1 and cell.lastOwn then srcTxt = "Your scan at " .. date("%H:%M", cell.lastOwn)
    elseif cell.own == 1 then srcTxt = "Your scan, price unchanged until the next one"
    elseif cell.own > 1 then srcTxt = cell.own .. " scans of yours, their median counts"
    else srcTxt = "Midas Server  \194\183  all scanners" end
    A.src:SetText(srcTxt); A.src:SetTextColor(T.Unpack(C.sub))
    local s = scoreOf(model, "price", cell.low, cell.qty)
    A.v[1]:SetText(M.MoneyPlain(cell.low)); A.v[1]:SetTextColor(T.Unpack(C.teal))
    A.v[2]:SetText(pct(cell.low / model.fair - 1)); A.v[2]:SetTextColor(T.Unpack(textOf(s)))
    local sq = scoreOf(model, "qty", cell.low, cell.qty)
    A.v[3]:SetText(tostring(floor(cell.qty + 0.5)))
    A.v[3]:SetTextColor(T.Unpack(metric == "qty" and textOf(sq) or C.text))
    A.k[2]:SetText(model.fairOwn and "VS FAIR" or "VS MEDIAN")
    for i = 1, 3 do A.k[i]:Show(); A.v[i]:Show() end
    A.note:Hide()
  else
    A.src:SetText("No scan in this window"); A.src:SetTextColor(T.Unpack(C.red))
    for i = 1, 3 do A.k[i]:Hide(); A.v[i]:Hide() end
    local colm = model.cols[c]
    if colm.n > 0 then
      A.note:SetText(string.format("This time of day averaged %s (%s vs %s) on %d other %s.",
        M.MoneyPlain(colm.low), pct(colm.low / model.fair - 1), model.fairOwn and "Fair" or "the week's median",
        colm.n, colm.n == 1 and "day" or "days"))
    else
      A.note:SetText("Never scanned at this time of day in the last 7 days.")
    end
    A.note:Show()
  end
end

-- re-fill for the item in hv.key (layout follows the frame size)
function M.FillHeat()
  local hv = M.heatView
  if not (hv and hv:IsShown() and hv.key) then return end
  local key = hv.key
  local W, H = hv:GetWidth(), hv:GetHeight()
  if not (W and W > 100 and H and H > 100) then
    -- not laid out yet (first open): one frame later
    if not hv._fillPending then
      hv._fillPending = true
      C_Timer.After(0, function() hv._fillPending = nil; M.FillHeat() end)
    end
    return
  end
  local k = max(1, T.fontScale or 1)
  local function S(v) return floor(v * k + 0.5) end

  -- header
  local qc = M.ItemQualityColor(key)
  hv.title:SetText(M.ItemName(key))
  hv.title:SetTextColor(qc.r, qc.g, qc.b)
  local id = M.BaseID and M.BaseID(key) or tonumber(key)
  hv.icon:SetTexture((id and M.GetItemIcon and M.GetItemIcon(id)) or "Interface\\Icons\\INV_Misc_QuestionMark")
  hv.title:SetWidth(0)
  local nameW = floor((hv.title:GetStringWidth() or 120) + 0.5)
  local chipsW = 0
  if hv.links then
    chipsW = hv.links:SetItem(key, max(120, W - 28 - 100 - min(nameW, 240) - 16))
  end
  local titleW = max(80, min(nameW, W - 28 - 100 - ((chipsW > 0) and (chipsW + 16) or 0)))
  hv.title:SetWidth(titleW)
  hv.titleBtn:SetWidth(34 + titleW)

  local metric = metricNow()
  hv.seg:Select(metric)
  local model = M.HeatModel(key)
  hv.model = model

  -- coverage
  local ratio = (model.nPast > 0) and (model.nData / model.nPast) or 0
  local cc = (ratio < 0.25) and C.red or ((ratio < 0.75) and C.accent or C.green)
  hv.covFill:SetVertexColor(cc[1], cc[2], cc[3], 1)
  hv.covFill:SetWidth(max(1, floor(90 * ratio + 0.5)))
  hv.covFill:SetShown(ratio > 0)
  hv.covText:SetText(model.nData .. " / " .. model.nPast .. " windows scanned" .. SEP ..
    (model.srvOn and "your scans + Midas Server" or "your scans"))

  -- banner
  local banner
  if model.nData > 0 and ratio < 0.25 then
    banner = "Not enough scans for a heat map yet: " .. model.nData .. " of " .. model.nPast ..
      " windows have a scan. It fills in as you and other scanners scan at different times of day."
  elseif model.nData > 0 and (model.blind[1] or model.few[1]) then
    local parts = {}
    if model.blind[1] then parts[#parts + 1] = "no scans at " .. M.HeatRanges(model, model.blind) end
    if model.few[1] then parts[#parts + 1] = "fewer than 3 days at " .. M.HeatRanges(model, model.few) end
    banner = "Gaps in the scan history" .. SEP .. table.concat(parts, SEP)
  end
  hv.banner:SetShown(banner ~= nil)
  if banner then
    hv.bannerText:SetText(banner)
    local bc = (ratio < 0.25) and C.red or C.accent
    hv.bannerDot:SetVertexColor(bc[1], bc[2], bc[3], 1)
  end

  -- vertical budget: header 26, tool row to 54, banner to 78, cards and legend
  -- below. A tight fit (small window, large text) gives up, in this order, the
  -- tall average row, the "Days seen" row and the legend before rows shrink
  -- under their text.
  local legendH = S(16)
  local panelH = S(98)
  local top = banner and S(78) or S(58)
  hv.banner:ClearAllPoints()
  hv.banner:SetPoint("TOPLEFT", 0, -S(58)); hv.banner:SetPoint("TOPRIGHT", 0, -S(58))
  hv.banner:SetHeight(S(16))
  local headH, footH, seenH = S(HEAD_H), S(FOOT_H), S(SEEN_H)
  local lblW, avgW = S(LBL_W), S(AVG_W)
  local minRow = max(16, math.ceil(T.Scaled and T.Scaled(T.SIZE.small) or T.SIZE.small) + 3)
  local showSeen, showLegend = true, true
  local gh, rowH
  local function budget()
    gh = H - top - ((showLegend and (legendH + 8) or 4) + panelH + 8)
    local fixed = headH + 3 + 6 * GAP + 7 + footH + (showSeen and (2 + seenH) or 0)
    rowH = floor((gh - fixed) / NROW)
  end
  budget()
  if rowH < minRow then footH = minRow; budget() end
  if rowH < minRow then showSeen = false; budget() end
  if rowH < minRow then showLegend = false; budget() end
  if rowH > 44 then rowH = 44 elseif rowH < minRow then rowH = minRow end
  -- a tall window: the rows stop growing, the cards and the legend move up
  -- under the grid instead of leaving a gap above them
  local lift = max(0, gh - (headH + 3 + 6 * GAP + 7 + footH + (showSeen and (2 + seenH) or 0)) - NROW * rowH)
  local cardsY = (showLegend and (legendH + 8) or 4) + lift
  hv.grid:ClearAllPoints()
  hv.grid:SetPoint("TOPLEFT", 0, -top)
  hv.grid:SetPoint("BOTTOMRIGHT", 0, cardsY + panelH + 8)
  local gw = W
  local colW = (gw - lblW - avgW - GAP * (NCOL + 1)) / NCOL
  local x0, y0 = lblW + GAP, headH + 3
  hv.geo = { x0 = x0, y0 = y0, colW = colW, rowH = rowH }

  local empty = model.nData == 0
  hv.empty:SetShown(empty)
  local showGrid = not empty
  -- hide-everything helper for the empty state
  local function vis(region, on) if on then region:Show() else region:Hide() end end

  -- header row
  vis(hv.headL, showGrid); vis(hv.headR, showGrid)
  hv.headL:ClearAllPoints(); hv.headL:SetPoint("TOPLEFT", hv.grid, "TOPLEFT", 2, -1)
  hv.headR:ClearAllPoints(); hv.headR:SetPoint("TOPRIGHT", hv.grid, "TOPRIGHT", -4, -1)
  for c = 1, NCOL do
    local fs = hv.colLbl[c]
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", hv.grid, "TOPLEFT", x0 + (c - 1) * (colW + GAP), -1)
    fs:SetWidth(colW)
    fs:SetText(model.cols[c].short)
    vis(fs, showGrid)
  end

  -- cells
  local fs1 = (colW >= 80) and T.SIZE.body or T.SIZE.small
  for r = 1, NROW do
    local row = model.rows[r]
    local yy = -(y0 + (r - 1) * (rowH + GAP))
    local lbl, cnt, avg = hv.rowLbl[r], hv.rowCnt[r], hv.rowAvg[r]
    lbl:ClearAllPoints(); lbl:SetPoint("LEFT", hv.grid, "TOPLEFT", 2, yy - rowH / 2)
    lbl:SetText(row.label)
    cnt:ClearAllPoints(); cnt:SetPoint("RIGHT", hv.grid, "TOPLEFT", lblW - 4, yy - rowH / 2)
    local past, got, sum = 0, 0, 0
    for c = 1, NCOL do
      local cell = row.cells[c]
      if cell and not cell.future then
        past = past + 1
        if cell.has then got = got + 1; sum = sum + ((metric == "qty") and cell.qty or cell.low) end
      end
    end
    cnt:SetText(got .. "/" .. past)
    avg:ClearAllPoints(); avg:SetPoint("RIGHT", hv.grid, "TOPRIGHT", -4, yy - rowH / 2)
    if got > 0 then
      local a = sum / got
      avg:SetText(valText(metric, a, a))
      avg:SetTextColor(T.Unpack(textOf(scoreOf(model, metric, a, a))))
    else
      avg:SetText("\226\128\147"); avg:SetTextColor(T.Unpack(C.sub))
    end
    vis(lbl, showGrid); vis(cnt, showGrid); vis(avg, showGrid)
    for c = 1, NCOL do
      local o, cell = hv.cells[r][c], row.cells[c]
      local xx = x0 + (c - 1) * (colW + GAP)
      box(hv.grid, o.fill, xx, yy, colW, rowH)
      box(hv.grid, o.hatch, xx, yy, colW, rowH)
      o.fs:ClearAllPoints(); o.fs:SetPoint("CENTER", hv.grid, "TOPLEFT", xx + colW / 2, yy - rowH / 2)
      o.fs:SetWidth(colW - 4)
      T.RegFont(o.fs, T.FONT_MED, fs1)
      o.edge:Off(); o.hatch:Hide(); o.fs:SetText("")
      if not showGrid or not cell or cell.future then
        o.fill:Hide()
      elseif cell.has then
        o.fill:SetVertexColor(fillOf(scoreOf(model, metric, cell.low, cell.qty)))
        o.fill:Show()
        o.fs:SetText(valText(metric, cell.low, cell.qty))
        o.fs:SetTextColor(T.Unpack(C.text))
      elseif model.cols[c].n > 0 then
        o.fill:SetVertexColor(C.bg1[1], C.bg1[2], C.bg1[3], 1); o.fill:Show()
        o.hatch:Show()
      else
        o.fill:Hide()
        o.edge:Place(xx, yy, colW, rowH, C.border, 1)
      end
      vis(o.fs, showGrid)
    end
  end

  -- 7-day averages and days seen
  local yRows = y0 + NROW * rowH + (NROW - 1) * GAP
  box(hv.grid, hv.sep, 0, -(yRows + 3), gw, 1)
  vis(hv.sep, showGrid)
  local yF = -(yRows + 7)
  hv.footLbl:ClearAllPoints(); hv.footLbl:SetPoint("LEFT", hv.grid, "TOPLEFT", 2, yF - footH / 2)
  hv.seenLbl:ClearAllPoints(); hv.seenLbl:SetPoint("LEFT", hv.grid, "TOPLEFT", 2, yF - footH - 2 - seenH / 2)
  vis(hv.footLbl, showGrid); vis(hv.seenLbl, showGrid and showSeen)
  local buyC = model.trade and model.trade.buy.c
  local sellC = model.trade and model.trade.sell.c
  for c = 1, NCOL do
    local o, col = hv.foot[c], model.cols[c]
    local xx = x0 + (c - 1) * (colW + GAP)
    box(hv.grid, o.fill, xx, yF, colW, footH)
    o.fs:ClearAllPoints(); o.fs:SetPoint("CENTER", hv.grid, "TOPLEFT", xx + colW / 2, yF - footH / 2)
    o.fs:SetWidth(colW - 4)
    T.RegFont(o.fs, T.FONT_SEMI, fs1)
    o.edge:Off()
    if not showGrid then
      o.fill:Hide(); o.fs:Hide()
    elseif col.n == 0 then
      o.fill:Hide(); o.fs:SetText("\226\128\147"); o.fs:SetTextColor(T.Unpack(C.sub)); o.fs:Show()
      if col.past > 0 then o.edge:Place(xx, yF, colW, footH, C.border, 1) end
    elseif col.n < MIN_SEEN then
      -- seen on too few days: the value in its colour, no fill - it reads weaker
      local s = scoreOf(model, metric, col.low, col.qty)
      o.fill:Hide()
      o.fs:SetText(valText(metric, col.low, col.qty)); o.fs:SetTextColor(T.Unpack(textOf(s))); o.fs:Show()
      o.edge:Place(xx, yF, colW, footH, C.border, 1)
    else
      o.fill:SetVertexColor(fillOf(scoreOf(model, metric, col.low, col.qty))); o.fill:Show()
      o.fs:SetText(valText(metric, col.low, col.qty)); o.fs:SetTextColor(T.Unpack(C.text)); o.fs:Show()
      if c == buyC then o.edge:Place(xx, yF, colW, footH, C.green, 1)
      elseif c == sellC then o.edge:Place(xx, yF, colW, footH, C.red, 1) end
    end
    local s = hv.seen[c]
    s:ClearAllPoints(); s:SetPoint("CENTER", hv.grid, "TOPLEFT", xx + colW / 2, yF - footH - 2 - seenH / 2)
    s:SetText(col.n .. "/" .. col.past)
    s:SetTextColor(T.Unpack((col.past > 0 and col.n == 0) and C.red or ((col.n >= MIN_SEEN) and C.text or C.sub)))
    vis(s, showGrid and showSeen and col.past > 0)
  end

  -- selection: keep the hovered cell while it still has a window, else the newest scan
  local sr, sc = hv.selR, hv.selC
  local keep = hv.selKey == key and sr and sc and model.rows[sr].cells[sc] and not model.rows[sr].cells[sc].future
  if not keep then
    sr, sc = nil, nil
    for r = NROW, 1, -1 do
      for c = NCOL, 1, -1 do
        local cell = model.rows[r].cells[c]
        if not sr and cell and cell.has then sr, sc = r, c end
      end
    end
    if not sr then
      for r = NROW, 1, -1 do
        for c = NCOL, 1, -1 do
          local cell = model.rows[r].cells[c]
          if not sr and cell and not cell.future then sr, sc = r, c end
        end
      end
    end
  end
  hv.selR, hv.selC, hv.selKey = sr, sc, key
  if showGrid then M.HeatPaintSel() else hv.selEdge:Off() end

  -- cards
  local cw = floor((W - 24) / 3)
  local cards = { hv.cardA, hv.cardB, hv.cardC }
  for i, cd in ipairs(cards) do
    cd:ClearAllPoints()
    cd:SetPoint("BOTTOMLEFT", hv, "BOTTOMLEFT", (i - 1) * (cw + 12), cardsY)
    cd:SetSize((i == 3) and (W - 2 * (cw + 12)) or cw, panelH)
    cd:SetShown(showGrid)
  end
  local A, B, Cc = hv.cardA, hv.cardB, hv.cardC
  A.title:SetText("SELECTED 3 H WINDOW")
  -- the "3+ days" hint gives way to the title on a narrow card (large text)
  B.hint:SetShown((B.title:GetStringWidth() or 0) + (B.hint:GetStringWidth() or 0) + 34 <= cw)
  A.when:ClearAllPoints(); A.when:SetPoint("TOPLEFT", 10, -S(22)); A.when:SetWidth(cw - 20)
  A.src:ClearAllPoints(); A.src:SetPoint("TOPLEFT", 10, -S(38)); A.src:SetWidth(cw - 20)
  local kw = floor((cw - 20) / 3)
  for i = 1, 3 do
    A.k[i]:ClearAllPoints(); A.k[i]:SetPoint("TOPLEFT", 10 + (i - 1) * kw, -S(58)); A.k[i]:SetWidth(kw - 6)
    A.v[i]:ClearAllPoints(); A.v[i]:SetPoint("TOPLEFT", 10 + (i - 1) * kw, -S(72)); A.v[i]:SetWidth(kw - 6)
  end
  A.note:ClearAllPoints(); A.note:SetPoint("TOPLEFT", 10, -S(56)); A.note:SetWidth(cw - 20); A.note:SetHeight(S(34))

  local bw = (cw - 20 - 16) / 2
  B.h1:ClearAllPoints(); B.h1:SetPoint("TOPLEFT", 10, -S(24))
  B.h2:ClearAllPoints(); B.h2:SetPoint("TOPLEFT", 10 + bw + 16, -S(24))
  local hasBest = model.cheap[1] ~= nil
  B.h1:SetShown(hasBest); B.h2:SetShown(hasBest)
  for i = 1, 3 do
    local yy = -S(39 + (i - 1) * 13)
    local a, d = model.cheap[i], model.dear[i]
    B.r1[i]:ClearAllPoints(); B.r1[i]:SetPoint("TOPLEFT", 10, yy)
    B.p1[i]:ClearAllPoints(); B.p1[i]:SetPoint("TOPRIGHT", B, "TOPLEFT", 10 + bw, yy)
    B.r2[i]:ClearAllPoints(); B.r2[i]:SetPoint("TOPLEFT", 10 + bw + 16, yy)
    B.p2[i]:ClearAllPoints(); B.p2[i]:SetPoint("TOPRIGHT", B, "TOPLEFT", 10 + 2 * bw + 16, yy)
    -- "07:00–10:00", or "07–10" when time and price would touch (large text)
    local function put(rf, pf, col)
      rf:SetText(col and col.range or ""); pf:SetText(col and M.MoneyPlain(col.low) or "")
      if col and (rf:GetStringWidth() or 0) + (pf:GetStringWidth() or 0) + 8 > bw then rf:SetText(col.short) end
      -- still too wide (half-hour time zones, where short = range): the start alone
      if col and col.b0 and (rf:GetStringWidth() or 0) + (pf:GetStringWidth() or 0) + 8 > bw then
        rf:SetText(hm(col.b0))
      end
    end
    put(B.r1[i], B.p1[i], a)
    put(B.r2[i], B.p2[i], d)
    B.r1[i]:SetShown(a ~= nil); B.p1[i]:SetShown(a ~= nil); B.r2[i]:SetShown(d ~= nil); B.p2[i]:SetShown(d ~= nil)
  end
  local bnote = ""
  if model.blind[1] then bnote = "The cheapest time may be in a gap: no scans at " .. M.HeatRanges(model, model.blind) .. "."
  elseif model.few[1] then bnote = "Left out, seen on fewer than 3 days: " .. M.HeatRanges(model, model.few) .. "." end
  B.note:ClearAllPoints(); B.note:SetPoint("BOTTOMLEFT", 10, 8); B.note:SetWidth(cw - 20)
  B.note:SetText(bnote); B.note:SetShown(hasBest and bnote ~= "")
  B.empty:ClearAllPoints(); B.empty:SetPoint("TOPLEFT", 10, -S(26)); B.empty:SetWidth(cw - 20); B.empty:SetHeight(S(62))
  if (model.nElig or 0) == 1 then
    B.empty:SetText("Only one time of day has scans on 3 or more days so far; Best times need two to compare. It fills in as you and other scanners scan at different times.")
  else
    B.empty:SetText("Not enough history yet: no time of day has a scan on 3 or more days. It fills in as you and other scanners scan at different times.")
  end
  B.empty:SetShown(not hasBest)

  local ccw = W - 2 * (cw + 12)
  local tr = model.trade
  local rowsY = { 22, 35, 52, 65 }
  for i = 1, 4 do
    Cc.l[i]:ClearAllPoints(); Cc.l[i]:SetPoint("TOPLEFT", 10, -S(rowsY[i]))
    Cc.v[i]:ClearAllPoints(); Cc.v[i]:SetPoint("TOPRIGHT", -10, -S(rowsY[i]))
    Cc.l[i]:SetShown(tr ~= nil); Cc.v[i]:SetShown(tr ~= nil)
  end
  Cc.div:ClearAllPoints(); Cc.div:SetPoint("TOPLEFT", 10, -S(48)); Cc.div:SetPoint("TOPRIGHT", -10, -S(48))
  Cc.div:SetShown(tr ~= nil)
  Cc.foot:ClearAllPoints(); Cc.foot:SetPoint("BOTTOMLEFT", 10, 8); Cc.foot:SetWidth(ccw - 20)
  Cc.foot:SetShown(tr ~= nil)
  Cc.empty:ClearAllPoints(); Cc.empty:SetPoint("TOPLEFT", 10, -S(26)); Cc.empty:SetWidth(ccw - 20); Cc.empty:SetHeight(S(48))
  Cc.empty:SetShown(tr == nil)
  if tr then
    Cc.v[1]:SetText(tr.buy.range .. SEP .. "avg " .. M.MoneyPlain(tr.buy.low))
    Cc.v[2]:SetText(tr.sell.range .. SEP .. "avg " .. M.MoneyPlain(tr.sell.low))
    Cc.l[2]:SetText(tr.nextDay and "Sell next day" or "Sell")
    local mg = tr.margin
    local mtxt = ((mg < 0) and "\226\136\146" or "+") .. M.MoneyPlain(abs(mg))
    Cc.v[3]:SetText(mtxt .. "  (" .. pct(mg / tr.buy.low) .. ")")
    -- a long gold value at a large text size: the percentage gives way
    if (Cc.l[3]:GetStringWidth() or 0) + (Cc.v[3]:GetStringWidth() or 0) + 12 > ccw - 20 then Cc.v[3]:SetText(mtxt) end
    Cc.v[3]:SetTextColor(T.Unpack((mg >= 0) and C.green or C.red))
    for i = 1, 2 do
      -- buy / sell value: the shorter "07–10" when the full range would run into the label
      local col = (i == 1) and tr.buy or tr.sell
      if (Cc.l[i]:GetStringWidth() or 0) + (Cc.v[i]:GetStringWidth() or 0) + 12 > ccw - 20 then
        Cc.v[i]:SetText(col.short .. SEP .. "avg " .. M.MoneyPlain(col.low))
      end
    end
    if tr.both > 0 then
      Cc.v[4]:SetText(tr.won .. " of " .. tr.both .. ((tr.both == 1) and " day" or " days"))
    else
      Cc.v[4]:SetText(tr.nextDay and "never on two days in a row" or "never both on one day")
    end
    Cc.v[4]:SetTextColor(T.Unpack((tr.both >= MIN_SEEN) and C.text or C.sub))
  end

  -- legend, left to right; what does not fit the width stays out
  local lg = hv.lg
  local ly = legendH / 2 + 2 + lift
  local x = 2
  local function place(fs, txt)
    fs:SetText(txt); fs:ClearAllPoints(); fs:SetPoint("LEFT", hv, "BOTTOMLEFT", x, ly)
    x = x + floor((fs:GetStringWidth() or 0) + 0.5)
  end
  local function fits(w) return x + w <= W - 2 end
  local items = {}
  if metric == "qty" then
    place(lg.left, "More units than usual")
  else
    place(lg.left, "8 % below " .. (model.fairOwn and "Fair" or "median"))
  end
  local showLg = showGrid and showLegend
  lg.left:SetShown(showLg)
  x = x + 6
  for i = 1, 7 do
    local s = -1 + (i - 1) / 3
    lg.sw[i]:SetVertexColor(fillOf(s))
    lg.sw[i]:ClearAllPoints(); lg.sw[i]:SetPoint("LEFT", hv, "BOTTOMLEFT", x, ly); lg.sw[i]:SetSize(16, 10)
    lg.sw[i]:SetShown(showLg)
    x = x + 18
  end
  x = x + 4
  place(lg.right, (metric == "qty") and "Fewer units" or ("8 % above " .. (model.fairOwn and "Fair" or "median")))
  lg.right:SetShown(showLg)
  x = x + 16
  local midTxt = (metric == "qty") and ("Usual: " .. floor(model.medQ + 0.5) .. " units")
    or ((model.fairOwn and "Fair " or "Week median ") .. M.MoneyPlain(model.fair))
  lg.mid:SetText(midTxt)
  local wMid = floor((lg.mid:GetStringWidth() or 0) + 0.5)
  items[1] = { w = wMid, draw = function()
    lg.mid:ClearAllPoints(); lg.mid:SetPoint("LEFT", hv, "BOTTOMLEFT", x, ly); x = x + wMid
  end, hide = function() lg.mid:Hide() end, show = function() lg.mid:Show() end }
  local wH = 18 + 6 + floor((lg.hTxt:GetStringWidth() or 0) + 0.5)
  items[2] = { w = wH, draw = function()
    lg.hFill:ClearAllPoints(); lg.hFill:SetPoint("LEFT", hv, "BOTTOMLEFT", x, ly); lg.hFill:SetSize(18, 10)
    lg.hatch:ClearAllPoints(); lg.hatch:SetPoint("LEFT", hv, "BOTTOMLEFT", x, ly); lg.hatch:SetSize(18, 10)
    lg.hTxt:ClearAllPoints(); lg.hTxt:SetPoint("LEFT", hv, "BOTTOMLEFT", x + 24, ly)
    x = x + wH
  end, hide = function() lg.hFill:Hide(); lg.hatch:Hide(); lg.hTxt:Hide() end,
    show = function() lg.hFill:Show(); lg.hatch:Show(); lg.hTxt:Show() end }
  local wO = 18 + 6 + floor((lg.oTxt:GetStringWidth() or 0) + 0.5)
  items[3] = { w = wO, draw = function()
    local by = ly + 5
    lg.oEdge:Place(x, -(H - by), 18, 10, C.border, 1)
    lg.oTxt:ClearAllPoints(); lg.oTxt:SetPoint("LEFT", hv, "BOTTOMLEFT", x + 24, ly)
    x = x + wO
  end, hide = function() lg.oEdge:Off(); lg.oTxt:Hide() end, show = function() lg.oTxt:Show() end }
  local wB = 18 + 4 + 18 + 6 + floor((lg.bTxt:GetStringWidth() or 0) + 0.5)
  items[4] = { w = wB, draw = function()
    local by = ly + 5
    lg.bEdge:Place(x, -(H - by), 18, 10, C.green, 1)
    lg.sEdge:Place(x + 22, -(H - by), 18, 10, C.red, 1)
    lg.bTxt:ClearAllPoints(); lg.bTxt:SetPoint("LEFT", hv, "BOTTOMLEFT", x + 46, ly)
    x = x + wB
  end, hide = function() lg.bEdge:Off(); lg.sEdge:Off(); lg.bTxt:Hide() end, show = function() lg.bTxt:Show() end }
  for i, it in ipairs(items) do
    -- the best-time marks only exist with a day-trade pattern
    if showLg and fits(it.w) and (i ~= 4 or model.trade) then it.show(); it.draw(); x = x + 16 else it.hide() end
  end
end

function M.ShowHeat(key)
  local hv = M.heatView
  if not (hv and key) then return end
  if M.whyView then M.whyView:Hide() end
  if M.depthView then M.depthView:Hide() end
  hv.key = tostring(key)
  hv:Show()
  M.FillHeat()
end
