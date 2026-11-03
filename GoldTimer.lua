-- Midas – Gold Timer: a stopwatch-sized window that adds up what comes in from
-- the moment it starts - gold from loot, quests and sales plus the value of the
-- items you loot or gather - and turns it into hourly rates. It reads the
-- Ledger's bookings (Ledger.lua calls M.GoldTimerTap), so the cause of every
-- copper is already known; the timer only sorts it into gold, loot and costs.
-- Selling or using loot swaps its counted value for the gold (no double count).
-- One timer per character; the clock pauses while you are offline.
local ADDON, M = ...
local T = M.Theme
local floor, abs, min, max = math.floor, math.abs, math.min, math.max

local SAMPLE_EVERY = 30    -- s of active time between rate samples
local SAMPLE_KEEP  = 40    -- samples kept (20 min)
local RECENT_WIN   = 600   -- s behind the "last 10 min" rate
local MIN_RATE_T   = 60    -- s before per-hour figures show
local TOP_ITEMS    = 6
local RESET_ARM    = 3     -- s the "Sure?" reset stays armed
local RESET_ASK    = 300   -- s of session before Reset asks first

-- what the timer makes of each Ledger category
local GOLD_IN = { lg = true, qg = true, pg = true, oi = true, sa = true, sh = true, sn = true, sp = true }
local COST    = { rp = true, fl = true, tr = true, tw = true, sv = true, qc = true, po = true,
                  ad = true, ac = true, tp = true, os = true }
local BUY     = { ba = true, bn = true, bp = true }
local GAIN    = { il = true, ig = true, iq = true, io = true, ie = true, ic = true, ir = true, ix = true }
-- items leaving: loot of this session loses its counted value (sold, listed, used ...)
local LEAVE   = { sa = true, sh = true, sn = true, sp = true, ah = true,
                  xc = true, xa = true, xr = true, xq = true, xx = true, xg = true, xu = true }
-- conversion inputs always give up their value: the yield was counted as a gain
local CONV    = { xk = true, xd = true, xo = true }
-- consumables from older stock are a running cost of the session
local USE     = { xc = true, xa = true, xr = true }
local SOLD    = { sa = true, sh = true, sn = true, sp = true }

local ORDER_G = { "lg", "qg", "sn", "sa", "sh", "sp", "pg", "oi" }
local ORDER_C = { "rp", "fl", "tr", "tw", "sv", "qc", "po", "ad", "ac", "tp", "os", "xc", "xa", "xr" }
local ORDER_X = { "ah", "xk", "xd", "xo", "xc", "xa", "xr", "xq", "xx", "xg", "xu" }

-- ===== State ================================================================
-- MidasDB.gtimer[charKey] = {
--   run (clock running), el (active seconds, folded), t0 (first start, epoch),
--   g[cat] gold income, c[cat] costs, l[cat] loot value gained, x[cat] loot value
--   given up, buy (spent on goods), gain[id] / pool[id] = { q, v } items gained /
--   still held, rm[cat][id] = { q, v, cq, cv } what a leave took (for reversals),
--   smp = { { el, earned } ... }, shown (window open) }
local seg            -- GetTime() the running segment started (this session only)
local ticker, frame, ui, tipOn, refresh

local function ckey() return (M.CharKey and M.CharKey()) or ((UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")) end

local function store()
  if not M.db then return nil end
  M.db.gtimer = M.db.gtimer or {}
  return M.db.gtimer
end

local function fresh(shown)
  return { run = false, el = 0, g = {}, c = {}, l = {}, x = {}, buy = 0,
           gain = {}, pool = {}, rm = {}, smp = {}, shown = shown }
end

local function cur(create)
  local s = store(); if not s then return nil end
  local k = ckey()
  if not s[k] and create then s[k] = fresh() end
  return s[k]
end

local function elapsed(st)
  if not st then return 0 end
  local e = st.el or 0
  if st.run and seg then e = e + max(0, GetTime() - seg) end
  return e
end

local function fold(st)
  if st and st.run and seg then
    local t = GetTime()
    st.el = (st.el or 0) + max(0, t - seg)
    seg = t
  end
end

local function sum(t)
  local s = 0
  for _, v in pairs(t or {}) do s = s + v end
  return s
end

local function earnedOf(st) return sum(st.g) + sum(st.l) - sum(st.x) end

local function sample(st)
  local el = elapsed(st)
  local last = st.smp[#st.smp]
  if last and el - last[1] < SAMPLE_EVERY then return end
  st.smp[#st.smp + 1] = { floor(el), earnedOf(st) }
  while #st.smp > SAMPLE_KEEP do table.remove(st.smp, 1) end
end

function M.GoldTimerRunning()
  local st = cur()
  return st ~= nil and st.run == true
end

function M.GoldTimerStats(st)
  st = st or cur()
  if not st then return nil end
  local el = elapsed(st)
  local gold, loot, gone, cost = sum(st.g), sum(st.l), sum(st.x), sum(st.c)
  local r = { el = el, run = st.run, gold = gold, loot = loot, gone = gone, lootNet = loot - gone,
              cost = cost, bought = st.buy or 0 }
  r.earned = gold + r.lootNet
  r.net = r.earned - cost
  local function rate(v) return (el >= MIN_RATE_T) and (v * 3600 / el) or nil end
  r.perHour, r.goldHour, r.lootHour, r.netHour = rate(r.earned), rate(gold), rate(r.lootNet), rate(r.net)
  if el >= RECENT_WIN then
    for i = #st.smp, 1, -1 do
      local s = st.smp[i]
      if el - s[1] >= RECENT_WIN then
        if el > s[1] then r.recentHour = (r.earned - s[2]) * 3600 / (el - s[1]) end
        break
      end
    end
  end
  return r
end

-- ===== Bookings from the Ledger =============================================
local function slot(t, k)
  local s = t[k]
  if not s then s = { q = 0, v = 0 }; t[k] = s end
  return s
end

local function add(t, k, v)
  local nv = (t[k] or 0) + v
  if nv == 0 then t[k] = nil else t[k] = nv end
end

-- q items of id leave through cat: loot of this session gives up its value
-- first; older stock only counts for conversions (x) and consumables (c)
local function takeOut(st, cat, id, q, unit)
  local r = st.rm[cat]
  if not r then r = {}; st.rm[cat] = r end
  local e = slot(r, id)
  local p = st.pool[id]
  local take = p and min(q, p.q) or 0
  if take > 0 then
    local v = floor(p.v * take / p.q + 0.5)
    p.q, p.v = p.q - take, p.v - v
    if p.q <= 0 then st.pool[id] = nil end
    add(st.x, cat, v)
    e.q, e.v = e.q + take, e.v + v
  end
  local rest = q - take
  if rest > 0 and unit > 0 and (CONV[cat] or USE[cat]) then
    local v = floor(rest * unit + 0.5)
    if CONV[cat] then add(st.x, cat, v) else add(st.c, cat, v) end
    e.cq, e.cv = (e.cq or 0) + rest, (e.cv or 0) + v
  end
  if e.q == 0 and (e.cq or 0) == 0 then r[id] = nil end
end

-- the reverse: a re-booking or a buyback brings q items of id back through cat
local function putBack(st, cat, id, q)
  local r = st.rm[cat]
  local e = r and r[id]
  if not e then return end
  local cq = e.cq or 0
  if cq > 0 then
    local k = min(q, cq)
    local v = floor(e.cv * k / cq + 0.5)
    e.cq, e.cv = cq - k, e.cv - v
    if CONV[cat] then add(st.x, cat, -v) else add(st.c, cat, -v) end
    q = q - k
  end
  if q > 0 and e.q > 0 then
    local k = min(q, e.q)
    local v = floor(e.v * k / e.q + 0.5)
    e.q, e.v = e.q - k, e.v - v
    add(st.x, cat, -v)
    local p = slot(st.pool, id)
    p.q, p.v = p.q + k, p.v + v
  end
  if e.q <= 0 and (e.cq or 0) <= 0 then r[id] = nil end
end

local function gainItem(st, cat, id, d, unit)
  local v = floor(abs(d) * unit + 0.5) * ((d > 0) and 1 or -1)
  add(st.l, cat, v)
  local g = slot(st.gain, id)
  g.q, g.v = g.q + d, g.v + v
  if g.q <= 0 then st.gain[id] = nil end
  local p = slot(st.pool, id)
  if d > 0 then
    p.q, p.v = p.q + d, p.v + v
  elseif p.q > 0 then   -- a gain booked back: it leaves the pool at its own value
    local k = min(-d, p.q)
    local pv = floor(p.v * k / p.q + 0.5)
    p.q, p.v = p.q - k, p.v - pv
  end
  if p.q <= 0 then st.pool[id] = nil end
end

-- kind "g": d = signed money change; kind "i": d = signed quantity of id
local function tap(kind, cat, d, id, unit)
  local st = cur()
  if not (st and st.run) or type(d) ~= "number" or d == 0 then return end
  if kind == "g" then
    if GOLD_IN[cat] then add(st.g, cat, d)
    elseif COST[cat] then add(st.c, cat, -d)
    elseif BUY[cat] then st.buy = (st.buy or 0) - d end
  elseif id then
    unit = (type(unit) == "number" and unit > 0) and unit or 0
    if GAIN[cat] then
      gainItem(st, cat, id, d, unit)
    elseif cat == "ar" then    -- an AH listing came back
      if d > 0 then putBack(st, "ah", id, d) else takeOut(st, "ah", id, -d, unit) end
    elseif LEAVE[cat] or CONV[cat] then
      if d < 0 then takeOut(st, cat, id, -d, unit) else putBack(st, cat, id, d) end
    end
  end
  sample(st)
  if refresh then refresh() end
end

function M.GoldTimerTap(...)
  local ok, err = pcall(tap, ...)
  if not ok then M.goldTimerErr = err end
end

-- ===== Formatting ===========================================================
local function money(c)
  c = floor((c or 0) + 0.5)
  return ((c < 0) and "-" or "") .. M.MoneyPlain(abs(c))
end

local function clock(s)
  s = floor(s or 0)
  return string.format("%d:%02d:%02d", floor(s / 3600), floor(s / 60) % 60, s % 60)
end

local function label(cat)
  local def = M.LEDGER_CATS and M.LEDGER_CATS[cat]
  return (def and def.label) or cat
end

local function stateText(st)
  if st and st.run then return "running", T.C.green end
  if st and elapsed(st) > 0 then return "paused", T.C.accent end
  return "ready", T.C.sub
end

-- ===== Tooltip ==============================================================
local SUB, VAL, MUT = { 0.78, 0.76, 0.70 }, { 0.97, 0.95, 0.90 }, { 0.55, 0.58, 0.64 }
local GOLDC, GREEN, RED = { 0.99, 0.80, 0.38 }, { 0.36, 0.82, 0.47 }, { 0.94, 0.39, 0.35 }

local function line(tip, l, r, lc, rc)
  lc, rc = lc or SUB, rc or VAL
  tip:AddDoubleLine(l, r, lc[1], lc[2], lc[3], rc[1], rc[2], rc[3])
end

local function perHour(v) return v and (money(v) .. " / h") or "-" end

function M.FillGoldTimerTip(tip)
  local st = cur()
  local r = st and M.GoldTimerStats(st)
  local stext, scol = stateText(st)
  tip:AddDoubleLine("|cffE8B44AMidas|r  \194\183  Gold Timer", stext .. "  " .. clock(r and r.el or 0),
    1, 1, 1, scol[1], scol[2], scol[3])
  if not r or (r.el == 0 and not r.run) then
    tip:AddLine("Counts gold and loot value from the moment you start it.", MUT[1], MUT[2], MUT[3], true)
    return
  end
  tip:AddLine(" ")
  line(tip, "Earned", money(r.earned), VAL, GOLDC)
  line(tip, "   per hour", perHour(r.perHour), SUB, GOLDC)
  if r.recentHour then line(tip, "   last 10 min", perHour(r.recentHour), SUB, GOLDC) end

  tip:AddLine(" ")
  line(tip, "Gold", money(r.gold) .. ((r.goldHour and ("   " .. perHour(r.goldHour))) or ""), VAL, VAL)
  local any = false
  for _, cat in ipairs(ORDER_G) do
    local v = st.g[cat]
    if v and v ~= 0 then line(tip, "   " .. label(cat), money(v)); any = true end
  end
  if not any then tip:AddLine("   none yet", MUT[1], MUT[2], MUT[3]) end

  line(tip, "Loot value", money(r.lootNet) .. ((r.lootHour and ("   " .. perHour(r.lootHour))) or ""), VAL, VAL)
  local items = {}
  for id, g in pairs(st.gain) do
    if g.q > 0 then items[#items + 1] = { id = id, q = g.q, v = g.v } end
  end
  table.sort(items, function(a, b) if a.v ~= b.v then return a.v > b.v end return a.id < b.id end)
  for i = 1, min(TOP_ITEMS, #items) do
    local it = items[i]
    local key = tostring(it.id)
    local qc = (M.ItemQualityColor and M.ItemQualityColor(key)) or { r = 1, g = 1, b = 1 }
    tip:AddDoubleLine("   " .. ((M.ItemName and M.ItemName(key)) or key) .. "  x" .. it.q, money(it.v),
      qc.r, qc.g, qc.b, VAL[1], VAL[2], VAL[3])
  end
  if #items > TOP_ITEMS then
    local rest, n = 0, 0
    for i = TOP_ITEMS + 1, #items do rest = rest + items[i].v; n = n + 1 end
    line(tip, "   " .. n .. " more items", money(rest), MUT, SUB)
  end
  if #items == 0 then tip:AddLine("   none yet", MUT[1], MUT[2], MUT[3]) end
  local sold = 0
  for cat in pairs(SOLD) do sold = sold + (st.x[cat] or 0) end
  if sold ~= 0 then line(tip, "   sold (now counted as gold)", money(-sold), SUB, RED) end
  for _, cat in ipairs(ORDER_X) do
    local v = st.x[cat]
    if v and v ~= 0 then line(tip, "   " .. label(cat), money(-v), SUB, RED) end
  end

  if r.cost ~= 0 then
    tip:AddLine(" ")
    line(tip, "Costs", money(-r.cost), VAL, RED)
    for _, cat in ipairs(ORDER_C) do
      local v = st.c[cat]
      if v and v ~= 0 then line(tip, "   " .. label(cat), money(-v), SUB, RED) end
    end
  end
  tip:AddLine(" ")
  line(tip, "Net", money(r.net), VAL, (r.net >= 0) and GREEN or RED)
  line(tip, "   per hour", perHour(r.netHour), SUB, (r.net >= 0) and GREEN or RED)
  if (r.bought or 0) > 0 then line(tip, "Spent on goods (not a cost)", money(r.bought), MUT, SUB) end
  tip:AddLine(" ")
  tip:AddLine("Loot counts at Fair (vendor price without scan data). Selling or using it swaps that value for the result.",
    MUT[1], MUT[2], MUT[3], true)
end

-- one status line for the minimap coin's tooltip
function M.GoldTimerTipLine(tip)
  local st = cur()
  if not st or (not st.run and elapsed(st) == 0) then return end
  local r = M.GoldTimerStats(st)
  local stext = stateText(st)
  tip:AddDoubleLine("Gold timer  " .. stext .. "  " .. clock(r.el),
    money(r.earned) .. ((r.perHour and ("  \194\183  " .. perHour(r.perHour))) or ""),
    0.78, 0.76, 0.70, 0.99, 0.80, 0.38)
end

-- ===== Window ===============================================================
local function redraw()
  if not (frame and ui) then return end
  local st = cur()
  local r = st and M.GoldTimerStats(st)
  local stext, scol = stateText(st)
  ui.state:SetText(stext); ui.state:SetTextColor(scol[1], scol[2], scol[3])
  ui.clock:SetText(clock(r and r.el or 0))
  ui.earned:SetText(money(r and r.earned or 0))
  ui.rate:SetText(perHour(r and r.perHour))
  ui.startB.text:SetText((st and st.run) and "Pause" or ((st and elapsed(st) > 0) and "Resume" or "Start"))
  if not ui.armed then ui.resetB.text:SetText("Reset") end
  if tipOn and GameTooltip.GetOwner and GameTooltip:GetOwner() == frame then
    GameTooltip:ClearLines()
    M.FillGoldTimerTip(GameTooltip)
    GameTooltip:Show()
  end
end
refresh = function() if frame and frame:IsShown() then redraw() end end

local function tick()
  local st = cur()
  if not (st and st.run) then return end
  fold(st)
  sample(st)
  refresh()
end

local function startTicker()
  if not ticker then ticker = C_Timer.NewTicker(1, tick) end
end

local function stopTicker()
  if ticker then ticker:Cancel(); ticker = nil end
end

function M.GoldTimerStart()
  local st = cur(true); if not st then return end
  if st.run then return end
  st.run = true
  st.t0 = st.t0 or time()
  seg = GetTime()
  sample(st)
  startTicker()
  refresh()
end

function M.GoldTimerPause()
  local st = cur()
  if not (st and st.run) then return end
  fold(st)
  sample(st)
  st.run, seg = false, nil
  stopTicker()
  refresh()
end

-- start over: totals and clock back to zero, running or paused as before
function M.GoldTimerReset()
  local s = store(); if not s then return end
  local k = ckey()
  local old = s[k]
  local st = fresh(old and old.shown)
  s[k] = st
  if old and old.run then
    st.run, st.t0 = true, time()
    seg = GetTime()
    startTicker()
  else
    seg = nil
    stopTicker()
  end
  refresh()
end

local function showTip(self)
  GameTooltip:SetOwner(self, "ANCHOR_NONE")
  GameTooltip:ClearAllPoints()
  local x = self:GetCenter()
  if x and x > (UIParent:GetWidth() or 0) / 2 then
    GameTooltip:SetPoint("TOPRIGHT", self, "TOPLEFT", -4, 0)
  else
    GameTooltip:SetPoint("TOPLEFT", self, "TOPRIGHT", 4, 0)
  end
  M.FillGoldTimerTip(GameTooltip)
  GameTooltip:Show()
  tipOn = true
end

local function hideTip()
  tipOn = false
  GameTooltip:Hide()
end

local function smallButton(parent, text, w)
  local b = T.Button(parent, text, w, 18)
  b.text:SetFont(T.FONT_MED, T.SIZE.small, "")
  return b
end

local function ensureFrame()
  if frame then return frame end
  local f = T.Surface(UIParent, "bg1", "border")
  frame = f
  f:SetSize(236, 70)
  f:SetFrameStrata("MEDIUM")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) hideTip(); self:StartMoving() end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local x, y = self:GetCenter()
    local cfg = M.db and M.db.config
    if cfg and x and y then cfg.gtX, cfg.gtY = floor(x + 0.5), floor(y + 0.5) end
  end)
  f:SetScript("OnEnter", showTip)
  f:SetScript("OnLeave", hideTip)
  f:SetScript("OnHide", hideTip)
  local cfg = M.db and M.db.config
  if cfg and cfg.gtX and cfg.gtY then
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cfg.gtX, cfg.gtY)
  else
    f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -24, -250)
  end
  f:Hide()

  ui = {}
  local kick = T.Text(f, T.SIZE.tiny, "muted", T.FONT_SEMI)
  kick:SetPoint("TOPLEFT", 10, -8); kick:SetText("GOLD TIMER")
  ui.state = T.Text(f, T.SIZE.tiny, "sub", T.FONT_MED)
  ui.state:SetPoint("LEFT", kick, "RIGHT", 8, 0)
  local close = T.Close(f)
  close:SetSize(22, 22); close:SetPoint("TOPRIGHT", -1, -1)
  close:SetScript("OnClick", function() M.GoldTimerToggle(false) end)
  ui.clock = T.Text(f, T.SIZE.h1, "text", T.FONT_SEMI)
  ui.clock:SetPoint("TOPLEFT", 10, -23)
  ui.earned = T.Text(f, T.SIZE.h1, "teal", T.FONT_SEMI)
  ui.earned:SetPoint("TOPRIGHT", -10, -23); ui.earned:SetJustifyH("RIGHT")
  ui.startB = smallButton(f, "Start", 58)
  ui.startB:SetPoint("BOTTOMLEFT", 8, 8)
  ui.startB:SetScript("OnClick", function()
    if M.GoldTimerRunning() then M.GoldTimerPause() else M.GoldTimerStart() end
  end)
  ui.resetB = smallButton(f, "Reset", 52)
  ui.resetB:SetPoint("LEFT", ui.startB, "RIGHT", 4, 0)
  ui.resetB:SetScript("OnClick", function(self)
    local st = cur()
    if st and elapsed(st) >= RESET_ASK and not (ui.armed and GetTime() - ui.armed < RESET_ARM) then
      ui.armed = GetTime()
      self.text:SetText("Sure?")
      C_Timer.After(RESET_ARM, function() ui.armed = nil; refresh() end)
      return
    end
    ui.armed = nil
    M.GoldTimerReset()
  end)
  ui.rate = T.Text(f, T.SIZE.small, "sub", T.FONT_MED)
  ui.rate:SetPoint("BOTTOMRIGHT", -10, 12); ui.rate:SetJustifyH("RIGHT")
  return f
end

-- right-click on the minimap coin / "/midas timer": open (a fresh timer starts
-- right away), or close - closing only hides the window, the clock keeps going
function M.GoldTimerToggle(autostart)
  if not M.db then return end
  local f = ensureFrame()
  local st = cur(true)
  if f:IsShown() then
    f:Hide()
    if st then st.shown = nil end
    return
  end
  if autostart and not st.run and elapsed(st) == 0 then M.GoldTimerStart() end
  st.shown = true
  f:Show()
  redraw()
end

-- ===== Slash ================================================================
function M.GoldTimerSlash(arg)
  arg = (arg or ""):lower()
  if arg == "" then
    M.GoldTimerToggle(true)
  elseif arg == "start" or arg == "resume" then
    M.GoldTimerStart()
    if not (frame and frame:IsShown()) then M.GoldTimerToggle(false) end
  elseif arg == "pause" or arg == "stop" then
    M.GoldTimerPause()
  elseif arg == "reset" then
    M.GoldTimerReset()
    M.Print("Gold timer reset.")
  elseif arg == "report" then
    local st = cur()
    local r = st and M.GoldTimerStats(st)
    if not r or (r.el == 0 and not r.run) then M.Print("Gold timer: not started.") return end
    M.Print(string.format("Gold timer %s %s: earned %s (%s), gold %s, loot %s, costs %s, net %s.",
      stateText(st), clock(r.el), money(r.earned), perHour(r.perHour), money(r.gold), money(r.lootNet),
      money(-r.cost), money(r.net)))
  else
    M.Print("/midas timer  -  open / close the gold timer   (start | pause | reset | report)")
  end
end

-- ===== Events ===============================================================
local inited = false
local ev = CreateFrame("Frame")
M.SafeRegister(ev, "PLAYER_ENTERING_WORLD")
M.SafeRegister(ev, "PLAYER_LOGOUT")
ev:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_ENTERING_WORLD" then
    if inited or not M.db then return end
    inited = true
    local st = cur()
    if st and st.run then
      seg = GetTime()      -- the offline time between sessions never counts
      startTicker()
    end
    if st and st.shown then
      ensureFrame():Show()
      redraw()
    end
  elseif event == "PLAYER_LOGOUT" then
    fold(cur())
  end
end)

M._gtTest = { tick = tick, cur = cur, elapsed = elapsed }
