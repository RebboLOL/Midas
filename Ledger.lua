-- Midas – Ledger: every gold and item flow per character and day.
-- Gold is booked only from PLAYER_MONEY deltas, items only from a diff of an
-- own bag/equipment/bank snapshot. Hooks, events and chat lines merely leave
-- "expectations" that the next delta claims (single match -> subset sum ->
-- open amount -> held for a late cause -> open-window context -> Other), so
-- the event order never matters and the booked gold always sums to the real
-- change. Sales and purchases get their value from the gold side only; the
-- item side adds quantities.
local ADDON, M = ...

local CT = C_Container
local floor, abs = math.floor, math.abs

local HOLD       = 2.0   -- s an unexplained delta waits for a late cause
local CTX_TAIL   = 3.0   -- s a closed window still explains deltas
local DEBOUNCE   = 0.4   -- s item diff debounce
local SEED_WAIT  = 5.0   -- s after login/zoning before item diffs count
local REBOOK     = 10    -- s a fallback booking can still be corrected by a late cause
local KEEP_DAYS  = 120   -- daily detail; older days fold into months
local TOP_ITEMS  = 12    -- items kept per category and day
local TOP_PARTNERS = 20
local RECENT_MAX = 300
local SUBSET_MAX = 8

-- ===== Categories ===========================================================
-- side: gin gold source, gout gold sink, sale stock->gold, buy gold->stock,
-- iin goods source, iout goods sink, altg/alti alt transfers (signed),
-- int internal (quantity only). g = gold direction, i = item direction.
local CATS = {
  lg = { label = "Looted gold",          side = "gin",  color = "accent", alt = "Looted gold (returned)" },
  qg = { label = "Quest rewards",        side = "gin",  color = "green",  alt = "Quest rewards (returned)" },
  pg = { label = "From players",         side = "gin",  color = "teal",   alt = "Returned to players" },
  oi = { label = "Other income",         side = "gin",  color = "muted",  alt = "Other income (reversed)" },
  ur = { label = "Unrecorded gain",      side = "gin",  color = "sub",    alt = "Unrecorded loss" },
  rp = { label = "Repairs",              side = "gout", color = "red",    alt = "Repair refunds" },
  fl = { label = "Flights",              side = "gout", color = "blue",   alt = "Flight refunds" },
  tr = { label = "Training",             side = "gout", color = "purple", alt = "Training refunds" },
  tw = { label = "Talent resets",        side = "gout", color = "purple", alt = "Talent reset refunds" },
  sv = { label = "Services",             side = "gout", color = "blue",   alt = "Service refunds" },
  qc = { label = "Quest costs",          side = "gout", color = "red",    alt = "Quest cost refunds" },
  po = { label = "Postage",              side = "gout", color = "muted",  alt = "Postage refunds" },
  ad = { label = "AH deposits",          side = "gout", color = "red",    alt = "Deposit refunds" },
  ac = { label = "AH cut",               side = "gout", color = "red",    alt = "AH cut refunds" },
  tp = { label = "To players",           side = "gout", color = "red",    alt = "Refunds from players" },
  os = { label = "Other spending",       side = "gout", color = "muted",  alt = "Other spending (reversed)" },
  sa = { label = "Sold on the AH",       side = "sale", color = "green",  alt = "AH sales reversed" },
  sh = { label = "AH sales (net)",       side = "sale", color = "green",  alt = "AH sales (net) reversed" },
  sn = { label = "Sold to vendors",      side = "sale", color = "green",  alt = "Bought back from vendors" },
  sp = { label = "Sold to players",      side = "sale", color = "green",  alt = "Refunded to players" },
  ba = { label = "Bought on the AH",     side = "buy",  color = "blue",   alt = "AH bid refunds" },
  bn = { label = "Bought from vendors",  side = "buy",  color = "blue",   alt = "Vendor refunds" },
  bp = { label = "Bought from players",  side = "buy",  color = "blue",   alt = "Refunds from players" },
  il = { label = "Looted",               side = "iin",  color = "accent", alt = "Loot given back" },
  ig = { label = "Gathered",             side = "iin",  color = "mint",   alt = "Gathered (returned)" },
  iq = { label = "Quest reward items",   side = "iin",  color = "green",  alt = "Quest reward items (returned)" },
  ic = { label = "Crafted",              side = "iin",  color = "mint",   alt = "Crafted (returned)" },
  ie = { label = "Disenchant & prospect yield", side = "iin", color = "purple", alt = "Yield (returned)" },
  io = { label = "From containers",      side = "iin",  color = "accent", alt = "From containers (returned)" },
  ir = { label = "Received",             side = "iin",  color = "teal",   alt = "Received (returned)" },
  ix = { label = "Other gained",         side = "iin",  color = "muted",  alt = "Other gained (reversed)" },
  xc = { label = "Consumed",             side = "iout", color = "red",    alt = "Consumed (returned)" },
  xa = { label = "Ammo",                 side = "iout", color = "red",    alt = "Ammo (returned)" },
  xr = { label = "Reagents",             side = "iout", color = "red",    alt = "Reagents (returned)" },
  xk = { label = "Used for crafting",    side = "iout", color = "mint",   alt = "Crafting (returned)" },
  xd = { label = "Disenchanted & prospected", side = "iout", color = "purple", alt = "Disenchanted (returned)" },
  xo = { label = "Containers opened",    side = "iout", color = "sub",    alt = "Containers (returned)" },
  xq = { label = "Quest items handed in", side = "iout", color = "sub",   alt = "Quest items (returned)" },
  xx = { label = "Destroyed",            side = "iout", color = "muted",  alt = "Destroyed (restored)" },
  xg = { label = "Given away",           side = "iout", color = "teal",   alt = "Given away (returned)" },
  xu = { label = "Used up",              side = "iout", color = "muted",  alt = "Used up (returned)" },
  ag = { label = "From alts",            side = "altg", color = "sub",    alt = "To alts" },
  at = { label = "Goods from alts",      side = "alti", color = "sub",    alt = "Goods to alts" },
  ah = { label = "Listed on the AH",     side = "int",  color = "sub",    alt = "Listed on the AH" },
  ar = { label = "AH returns",           side = "int",  color = "sub",    alt = "AH returns" },
}
local ORDER = { "lg", "qg", "pg", "oi", "ur", "rp", "fl", "tr", "tw", "sv", "qc", "po", "ad", "ac", "tp", "os",
                "sa", "sh", "sn", "sp", "ba", "bn", "bp", "il", "ig", "iq", "ic", "ie", "io", "ir", "ix",
                "xc", "xa", "xr", "xk", "xd", "xo", "xq", "xx", "xg", "xu", "ag", "at", "ah", "ar" }
do
  local G = { gin = 1, sale = 1, altg = 1, gout = -1, buy = -1 }
  local I = { iin = 1, buy = 1, alti = 1, iout = -1, sale = -1 }
  for k, c in pairs(CATS) do
    c.key, c.g, c.i = k, G[c.side], I[c.side]
  end
  CATS.ah.i, CATS.ar.i = -1, 1
end
M.LEDGER_CATS = CATS
M.LEDGER_ORDER = ORDER

-- ===== State ================================================================
local S = { flow = 0, skipped = 0, itemFlow = {}, debug = false }
local GQ, held, recentG = {}, {}, {}      -- gold expectations, held deltas, recent bookings
local IQ, heldI, recentI = {}, {}, {}     -- the same for items
local lastMoney

local function now() return GetTime() end
local function off() return M.db and M.db.config and M.db.config.ledgerOff == true end
local function secret(v) return issecretvalue ~= nil and issecretvalue(v) == true end
local function idOf(link)
  if type(link) ~= "string" or secret(link) then return nil end
  return tonumber(link:match("item:(%d+)"))
end
local function ckey() return (M.CharKey and M.CharKey()) or ((UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")) end
local function dbg(fmt, ...)
  if S.debug and M.Print then M.Print("ledger: " .. string.format(fmt, ...)) end
end
local function signed(c) return (c >= 0 and "+" or "-") .. M.MoneyPlain(abs(c)) end

-- ===== Storage ==============================================================
local function ldb()
  if not M.db then return nil end
  local L = M.db.ledger
  if type(L) ~= "table" then L = { v = 1 }; M.db.ledger = L end
  L.d = L.d or {}
  L.mo = L.mo or {}
  L.since = L.since or {}
  L.last = L.last or {}
  L.recent = L.recent or {}
  return L
end

local function dayRec(L, ck)
  local realm, day = M.RealmKey(), M.GetScanDay()
  local r = L.d[realm]; if not r then r = {}; L.d[realm] = r end
  local dd = r[day]; if not dd then dd = {}; r[day] = dd end
  local c = dd[ck]; if not c then c = { v = {} }; dd[ck] = c end
  c.v = c.v or {}
  return c
end

local valCache = {}
local function unitValue(id)
  local t = now()
  local c = valCache[id]
  if c and t - c.t < 60 then return c.v end
  local v = 0
  if M.ItemValue then
    local ok, r = pcall(M.ItemValue, id)
    if ok and type(r) == "number" and r > 0 then v = r end
  end
  valCache[id] = { v = v, t = t }
  return v
end

local function sub(t, k)
  local s = t[k]; if not s then s = {}; t[k] = s end
  return s
end

local function addKey(t, k, v)
  local nv = (t[k] or 0) + v
  if nv == 0 then t[k] = nil else t[k] = nv end
end

-- keep the TOP_ITEMS most valuable items of a category; the total stays in v
local function capItems(c, cat)
  local n, w = c.n and c.n[cat], c.w and c.w[cat]
  local ids, cnt = {}, 0
  for id in pairs(n or {}) do if not ids[id] then ids[id] = true; cnt = cnt + 1 end end
  for id in pairs(w or {}) do if not ids[id] then ids[id] = true; cnt = cnt + 1 end end
  while cnt > TOP_ITEMS do
    local minId, minV
    for id in pairs(ids) do
      local val = (w and w[id]) and abs(w[id]) or abs((n and n[id]) or 0) * unitValue(id)
      if not minV or val < minV then minId, minV = id, val end
    end
    ids[minId] = nil; cnt = cnt - 1
    if n then n[minId] = nil end
    if w then w[minId] = nil end
  end
  if n and next(n) == nil then c.n[cat] = nil end
  if w and next(w) == nil then c.w[cat] = nil end
  if c.n and next(c.n) == nil then c.n = nil end
  if c.w and next(c.w) == nil then c.w = nil end
end

local function capPartners(x)
  local cnt = 0
  for _ in pairs(x) do cnt = cnt + 1 end
  while cnt > TOP_PARTNERS do
    local minK, minV
    for k, v in pairs(x) do if not minV or abs(v) < minV then minK, minV = k, abs(v) end end
    x[minK] = nil; cnt = cnt - 1
  end
end

local function pushRecent(L, e)
  local i = (L.ri or 0) % RECENT_MAX + 1
  L.recent[i] = e
  L.ri = i
end

local function saveLast()
  if off() or not lastMoney then return end
  local L = ldb(); if not L then return end
  L.last[ckey()] = { m = lastMoney, t = time() }
end

local function touched()
  if M.RequestUIRefresh then M.RequestUIRefresh() end
end

-- one gold flow: d = signed money change; info may carry id, q (+ nq: the
-- quantity is booked from the gold side), partner
local function bookGold(cat, d, info, src)
  if d == 0 then return end
  local def = CATS[cat]
  if not def or not def.g then cat = (d > 0) and "oi" or "os"; def = CATS[cat] end
  if src ~= "gap" then
    if off() then S.skipped = S.skipped + d; return end
    S.flow = S.flow + d
  end
  local L = ldb(); if not L then return end
  local ck = ckey()
  local c = dayRec(L, ck)
  local nat = d * def.g
  addKey(c.v, cat, nat)
  local id = info and info.id
  if id then
    c.w = c.w or {}
    addKey(sub(c.w, cat), id, nat)
    if info.nq and info.q and info.q ~= 0 then
      c.n = c.n or {}
      addKey(sub(c.n, cat), id, (nat > 0) and abs(info.q) or -abs(info.q))
    end
    capItems(c, cat)
  end
  local p = info and info.partner
  if p and p ~= "" then
    c.x = c.x or {}
    addKey(c.x, p, d)
    capPartners(c.x)
  end
  L.since[ck] = L.since[ck] or time()
  pushRecent(L, { ts = time(), ck = ck, cat = cat, v = d, id = id, q = info and info.q, src = src })
  dbg("gold %s -> %s (%s)", signed(d), def.label, src or "?")
  touched()
end

-- one item flow: d = signed quantity change of the own snapshot
local function bookItem(cat, id, d, src)
  if d == 0 or not id then return end
  local def = CATS[cat]
  if not def or not def.i then cat = (d > 0) and "ix" or "xu"; def = CATS[cat] end
  S.itemFlow[id] = (S.itemFlow[id] or 0) + d
  if off() then return end
  local L = ldb(); if not L then return end
  local ck = ckey()
  local c = dayRec(L, ck)
  local nat = d * def.i
  c.n = c.n or {}
  addKey(sub(c.n, cat), id, nat)
  local val = 0
  if def.side == "iin" or def.side == "iout" or def.side == "alti" then
    val = floor(abs(d) * unitValue(id) + 0.5) * ((nat > 0) and 1 or -1)
    if val ~= 0 then
      addKey(c.v, cat, val)
      c.w = c.w or {}
      addKey(sub(c.w, cat), id, val)
    end
  end
  capItems(c, cat)
  L.since[ck] = L.since[ck] or time()
  pushRecent(L, { ts = time(), ck = ck, cat = cat, v = val, id = id, q = d, src = src })
  if S.debug then
    dbg("item %+d x %s -> %s (%s)", d, (M.ItemName and M.ItemName(tostring(id))) or tostring(id), def.label, src or "?")
  end
  touched()
end

-- ===== Open windows =========================================================
-- A delta that no cause claims is explained by the window that was open when
-- it happened (still valid CTX_TAIL seconds after closing).
local ctx = {}
local function setCtx(name, open)
  local c = ctx[name]; if not c then c = {}; ctx[name] = c end
  c.open = open and true or false
  c.at = now()
end
local function pulse(name, sec)   -- short-lived context after a spell cast
  local c = ctx[name]; if not c then c = {}; ctx[name] = c end
  c.open = false
  c.at = now() + sec - CTX_TAIL
end
local function active(name)
  local c = ctx[name]
  return c ~= nil and (c.open or now() - c.at <= CTX_TAIL)
end
local function isOpen(name)
  local c = ctx[name]
  return c ~= nil and c.open
end

-- ===== Gold engine ==========================================================
local function purgeGold(t)
  for i = #GQ, 1, -1 do if GQ[i].exp < t then table.remove(GQ, i) end end
  for i = #recentG, 1, -1 do if t - recentG[i].at > REBOOK then table.remove(recentG, i) end end
end

-- fb = booked by an open expectation or a fallback: a late exact cause may
-- still claim (and re-categorize) it
local function remember(cat, d, info, fb)
  recentG[#recentG + 1] = { cat = cat, d = d, info = info, at = now(), fb = fb }
  if #recentG > 30 then table.remove(recentG, 1) end
end

local function bookExp(e, d, src, fb)
  if e.parts then
    local big, rest, share = 1, d, {}
    for i, p in ipairs(e.parts) do
      if abs(p.amt) > abs(e.parts[big].amt) then big = i end
      share[i] = p.amt
      rest = rest - p.amt
    end
    share[big] = share[big] + rest
    for i, p in ipairs(e.parts) do bookGold(p.cat, share[i], p, src) end
    remember(e.parts[big].cat, d, nil, fb)
  else
    bookGold(e.cat, d, e, src)
    remember(e.cat, d, e, fb)
  end
end

local function claimGold(d)
  purgeGold(now())
  -- 1) the closest single expectation within its tolerance
  local best, bestErr
  for i, e in ipairs(GQ) do
    if e.amt then
      local err = abs(d - e.amt)
      if err <= e.tol and (not bestErr or err < bestErr) then best, bestErr = i, err end
    end
  end
  if best then
    local e = table.remove(GQ, best)
    bookExp(e, d, e.src, false)
    return true
  end
  -- 2) several answers in one money update: smallest matching subset
  local cand = {}
  for i, e in ipairs(GQ) do
    if e.amt then
      cand[#cand + 1] = i
      if #cand >= SUBSET_MAX then break end
    end
  end
  if #cand >= 2 then
    local bestMask, bestPop
    bestErr = nil
    for mask = 3, 2 ^ #cand - 1 do
      local s, tol, pop, mm = 0, 0, 0, mask
      for j = 1, #cand do
        if mm % 2 == 1 then
          local e = GQ[cand[j]]
          s = s + e.amt; tol = tol + e.tol; pop = pop + 1
        end
        mm = floor(mm / 2)
      end
      if pop >= 2 then
        local err = abs(d - s)
        if err <= tol and (not bestMask or pop < bestPop or (pop == bestPop and err < bestErr)) then
          bestMask, bestPop, bestErr = mask, pop, err
        end
      end
    end
    if bestMask then
      local members, s, mm = {}, 0, bestMask
      for j = 1, #cand do
        if mm % 2 == 1 then members[#members + 1] = cand[j]; s = s + GQ[cand[j]].amt end
        mm = floor(mm / 2)
      end
      local big = members[1]
      for _, gi in ipairs(members) do if abs(GQ[gi].amt) > abs(GQ[big].amt) then big = gi end end
      local list = {}
      for k = #members, 1, -1 do
        local gi = members[k]
        local e = GQ[gi]
        list[#list + 1] = { e = e, amt = e.amt + ((gi == big) and (d - s) or 0) }
        table.remove(GQ, gi)
      end
      for k = #list, 1, -1 do bookExp(list[k].e, list[k].amt, list[k].e.src, false) end
      return true
    end
  end
  -- 3) an expectation without a known amount
  for i, e in ipairs(GQ) do
    if not e.amt and (not e.sign or e.sign * d > 0) then
      if not e.multi then table.remove(GQ, i) end
      bookExp(e, d, e.src, true)
      return true
    end
  end
  return false
end

-- the window that explains an unclaimed delta, decided when it happened
local function fallbackGold(d)
  if active("trade") then return (d > 0) and "pg" or "tp", "trade" end
  if active("mail") then return (d > 0) and "pg" or "po", "mail" end
  if active("merchant") then
    if d < 0 and InRepairMode and InRepairMode() then return "rp", "repair" end
    return (d > 0) and "sn" or "bn", "merchant"
  end
  if active("ah") then
    if d < 0 and S.bidAt and now() - S.bidAt < 10 then return "ba", "ah" end
    return (d > 0) and "sh" or "ad", "ah"
  end
  if d < 0 and active("taxi") then return "fl", "taxi" end
  if d < 0 and active("trainer") then return "tr", "trainer" end
  if d < 0 and active("bank") then return "sv", "bank" end
  if active("quest") then return (d > 0) and "qg" or "qc", "quest" end
  if d > 0 and active("loot") then return "lg", "loot" end
  return nil
end

local function flushHeld(all)
  local t, i = now(), 1
  while held[i] do
    local h = held[i]
    if all or t - h.at >= HOLD - 0.01 then
      table.remove(held, i)
      local cat = h.fb or ((h.d > 0) and "oi" or "os")
      bookGold(cat, h.d, nil, h.fb and ("ctx:" .. h.ctx) or "other")
      remember(cat, h.d, nil, true)
    else
      i = i + 1
    end
  end
end

local function hold(d)
  local fb, cn = fallbackGold(d)
  held[#held + 1] = { d = d, at = now(), fb = fb, ctx = cn }
  C_Timer.After(HOLD + 0.05, function() flushHeld(false) end)
end

local function retryHeld()
  local i = 1
  while held[i] do
    if claimGold(held[i].d) then table.remove(held, i) else i = i + 1 end
  end
end

local function prepGold(e)
  e.exp = now() + (e.ttl or 10)
  e.tol = e.tol or 0
  if e.parts then
    local s = 0
    for i = #e.parts, 1, -1 do
      local p = e.parts[i]
      if not p.amt or p.amt == 0 then table.remove(e.parts, i) else s = s + p.amt end
    end
    if #e.parts == 0 then return nil end
    if #e.parts == 1 then
      local p = e.parts[1]
      e.parts, e.cat, e.id, e.q, e.nq, e.partner = nil, p.cat, p.id, p.q, p.nq, p.partner
    end
    e.amt = s
  end
  if e.amt == 0 then return nil end
  return e
end

-- Register causes. A late cause (it arrives after its money: chat lines,
-- mail confirmations, trade completion) first looks for its delta among the
-- held ones and the recent fallback bookings, which it then re-categorizes.
local function expectGold(list)
  local add, late, total, exact = {}, false, 0, true
  for _, e in ipairs(list) do
    e = prepGold(e)
    if e then
      add[#add + 1] = e
      if e.late then late = true end
      if e.amt then total = total + e.amt else exact = false end
    end
  end
  if #add == 0 then return end
  purgeGold(now())
  for _, h in ipairs(held) do
    if h.d == total then exact = false; break end   -- still waiting: the normal claim takes it
  end
  if late and exact then
    for i = #recentG, 1, -1 do
      local r = recentG[i]
      if r.fb and r.d == total then
        table.remove(recentG, i)
        local same = #add == 1 and add[1].cat == r.cat and not add[1].id and not add[1].parts and not add[1].partner
        if not same then
          bookGold(r.cat, -r.d, r.info, "fix")
          for _, e in ipairs(add) do bookExp(e, e.amt, "fix", false) end
        end
        return
      end
    end
  end
  for _, e in ipairs(add) do GQ[#GQ + 1] = e end
  if held[1] then retryHeld() end
end

local function onMoney(force)
  if not S.started then return end
  local m = GetMoney and GetMoney()
  if type(m) ~= "number" or secret(m) then return end
  if not lastMoney then lastMoney = m; return end
  -- GetMoney can read 0 for a moment while loading: confirm before booking it
  if m == 0 and lastMoney > 0 and not force then
    if not S.zeroWait then
      S.zeroWait = true
      C_Timer.After(1.5, function() S.zeroWait = nil; onMoney(true) end)
    end
    return
  end
  local d = m - lastMoney
  if d == 0 then return end
  lastMoney = m
  if off() then S.skipped = S.skipped + d; return end
  saveLast()
  if not claimGold(d) then hold(d) end
end

-- ===== Item engine ==========================================================
-- Own snapshot of bags, bag slots, equipment and (while it is open) the bank,
-- soulbound items included. Bank moves and equipping cancel out inside it.
local function numSlots(bag)
  if CT and CT.GetContainerNumSlots then return CT.GetContainerNumSlots(bag) or 0 end
  return (_G.GetContainerNumSlots and _G.GetContainerNumSlots(bag)) or 0
end

local function slotItem(bag, slot)
  if CT and CT.GetContainerItemInfo then
    local info = CT.GetContainerItemInfo(bag, slot)
    if type(info) == "table" and info.itemID then return info.itemID, info.stackCount or 1 end
    return nil
  end
  if _G.GetContainerItemInfo then
    local _, count, _, _, _, _, link, _, _, itemID = _G.GetContainerItemInfo(bag, slot)
    return itemID or idOf(link), count or 1
  end
  return nil
end

local function invSlotOf(bag)
  local fn = (CT and CT.ContainerIDToInventoryID) or _G.ContainerIDToInventoryID
  if not fn then return nil end
  local ok, s = pcall(fn, bag)
  return ok and s or nil
end

local function addInv(t, slot)
  local id = slot and GetInventoryItemID and GetInventoryItemID("player", slot)
  if type(id) == "number" and not secret(id) then t[id] = (t[id] or 0) + 1 end
end

local function addBag(t, bag)
  for slot = 1, numSlots(bag) do
    local id, q = slotItem(bag, slot)
    if type(id) == "number" and not secret(id) then t[id] = (t[id] or 0) + (q or 1) end
  end
end

local BANK = M.BankContainers()
local BAGS = {}
do
  for b = 0, NUM_BAG_SLOTS or 4 do BAGS[#BAGS + 1] = b end
  local rb = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
  local clash = false
  for _, b in ipairs(BANK) do if b == rb then clash = true end end
  if rb and rb > (NUM_BAG_SLOTS or 4) and not clash then BAGS[#BAGS + 1] = rb end
end

local function readBags()
  local t = {}
  for _, bag in ipairs(BAGS) do
    addBag(t, bag)
    if bag > 0 then addInv(t, invSlotOf(bag)) end
  end
  for slot = 1, 19 do addInv(t, slot) end
  return t
end

local function readBank()
  local t = {}
  for _, bag in ipairs(BANK) do
    addBag(t, bag)
    if bag > (NUM_BAG_SLOTS or 4) then addInv(t, invSlotOf(bag)) end
  end
  return t
end

local base, bankOpen, bankLast = nil, false, nil
local seedUntil = math.huge      -- no item booking before the first PLAYER_ENTERING_WORLD
local itemGen = 0

local function snapshot()
  local t = readBags()
  local b = bankLast
  if bankOpen then
    b = readBank()
    -- an empty read right after closing: keep the last real contents
    if next(b) == nil and bankLast and next(bankLast) then b = bankLast end
    bankLast = b
  end
  if b then for id, q in pairs(b) do t[id] = (t[id] or 0) + q end end
  return t
end

local function purgeItems(t)
  for i = #IQ, 1, -1 do if IQ[i].done or IQ[i].exp < t then table.remove(IQ, i) end end
  for i = #recentI, 1, -1 do if t - recentI[i].at > REBOOK then table.remove(recentI, i) end end
end

-- open = quantity a late chat line may still claim without booking again
local function rememberI(cat, id, d, fb, open)
  recentI[#recentI + 1] = { cat = cat, id = id, d = d, at = now(), fb = fb, open = open }
  if #recentI > 60 then table.remove(recentI, 1) end
end

local function wants(e, rest)
  if e.q then return e.q * rest > 0 end
  return (e.sign or 0) * rest > 0
end

-- causes with an item id from a hook beat chat causes; a hook match also
-- uses up the chat line describing the same event
local function takeFrom(id, d, hookPass)
  local rest = d
  for _, e in ipairs(IQ) do
    if rest == 0 then break end
    if not e.done and e.id == id and (e.hook == true) == hookPass and wants(e, rest) then
      local take = rest
      if e.q then
        if abs(e.q) < abs(rest) then take = e.q end
        e.q = e.q - take
        if e.q == 0 then e.done = true end
      else
        e.done = true
      end
      bookItem(e.cat, id, take, e.src)
      rest = rest - take
      local left = 0
      if hookPass then
        left = take
        for _, c in ipairs(IQ) do
          if left == 0 then break end
          if not c.done and not c.hook and c.id == id and c.q and c.q * left > 0 then
            local x = (abs(c.q) < abs(left)) and c.q or left
            c.q = c.q - x; left = left - x
            if c.q == 0 then c.done = true end
          end
        end
      end
      rememberI(e.cat, id, take, false, left)
    end
  end
  return rest
end

local function claimItem(id, d)
  local rest = takeFrom(id, d, true)
  if rest ~= 0 then rest = takeFrom(id, rest, false) end
  return rest
end

local function classOf(id)
  local fn = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
  local cls = fn and select(6, fn(id))
  if not cls then cls = select(12, M.GetItemInfo(id)) end
  return cls
end
local CLASS_OUT = { [0] = "xc", [6] = "xa", [5] = "xr", [12] = "xq" }

local function fallbackItem(id, d)
  local t = now()
  if active("de") then return (d < 0) and "xd" or "ie", "de" end
  if active("trade") then return (d > 0) and "ir" or "xg", "trade" end
  if active("mail") then
    if d > 0 then return (S.mailCat and t - S.mailCat.at < 5 and S.mailCat.cat) or "ir", "mail" end
    return "xg", "mail"
  end
  if active("merchant") then return (d > 0) and "bn" or "sn", "merchant" end
  if active("ah") then
    if d < 0 then return "ah", "ah" end
    return (S.bidAt and t - S.bidAt < 10) and "ba" or "ar", "ah"
  end
  if active("quest") then return (d > 0) and "iq" or "xq", "quest" end
  if active("craft") then return (d > 0) and "ic" or "xk", "craft" end
  if d > 0 then
    if active("loot") then return S.lootCat or "il", "loot" end
    return "ix", nil
  end
  local u = S.use
  if u and u.id == id and u.opened and t - u.at < 5 then return "xo", "open" end
  return CLASS_OUT[classOf(id) or -1] or "xu", "class"
end

local function flushHeldI(all)
  local t, i = now(), 1
  while heldI[i] do
    local h = heldI[i]
    if all or t - h.at >= HOLD - 0.01 then
      table.remove(heldI, i)
      bookItem(h.fb, h.id, h.d, h.ctx and ("ctx:" .. h.ctx) or "other")
      rememberI(h.fb, h.id, h.d, true, h.d)
    else
      i = i + 1
    end
  end
end

local function onItemDelta(id, d)
  purgeItems(now())
  local rest = claimItem(id, d)
  if rest ~= 0 then
    local fb, cn = fallbackItem(id, rest)
    heldI[#heldI + 1] = { id = id, d = rest, at = now(), fb = fb, ctx = cn }
    C_Timer.After(HOLD + 0.05, function() flushHeldI(false) end)
  end
end

local function expectItem(e)
  if not e.id or e.q == 0 then return end
  local t = now()
  e.exp = t + (e.ttl or 10)
  purgeItems(t)
  local waiting = false
  for _, h in ipairs(heldI) do
    if h.id == e.id and e.q and h.d * e.q > 0 then waiting = true; break end
  end
  if e.late and e.q and not waiting then
    for _, r in ipairs(recentI) do
      if r.id == e.id and r.open ~= 0 and r.open * e.q > 0 then
        local x = (abs(r.open) < abs(e.q)) and r.open or e.q
        r.open = r.open - x
        if r.fb and r.cat ~= e.cat then
          bookItem(r.cat, e.id, -x, "fix")
          bookItem(e.cat, e.id, x, "fix")
        end
        e.q = e.q - x
        if e.q == 0 then return end
      end
    end
  end
  IQ[#IQ + 1] = e
  local i = 1
  while heldI[i] do
    local h = heldI[i]
    if h.id == e.id then
      local rest = claimItem(h.id, h.d)
      if rest == 0 then table.remove(heldI, i) else h.d = rest; i = i + 1 end
    else
      i = i + 1
    end
  end
end

local scheduleItems
local function flushItems()
  if CursorHasItem and CursorHasItem() then scheduleItems(); return end
  local cur = snapshot()
  if not base or now() < seedUntil then base = cur; return end
  local old = base
  base = cur
  if off() then return end
  for id, q in pairs(cur) do
    local d = q - (old[id] or 0)
    if d ~= 0 then onItemDelta(id, d) end
  end
  for id, q in pairs(old) do
    if cur[id] == nil then onItemDelta(id, -q) end
  end
end

scheduleItems = function()
  itemGen = itemGen + 1
  local g = itemGen
  C_Timer.After(DEBOUNCE, function() if g == itemGen then flushItems() end end)
end

local function flushNow()
  itemGen = itemGen + 1
  flushItems()
end

local function seedItems()
  seedUntil = now() + SEED_WAIT
  base = nil
  C_Timer.After(SEED_WAIT + 0.1, flushNow)
end

-- the bank only becomes readable once it is open and may fill in over the
-- first moments: its contents are seeded, never booked
local function bankShow()
  if bankOpen then return end
  flushNow()
  bankOpen = true
  seedUntil = math.max(seedUntil, now() + 1.5)
  base = snapshot()
  C_Timer.After(1.6, scheduleItems)
end

local function bankHide()
  if not bankOpen then return end
  flushNow()
  bankOpen = false
end

-- ===== Causes ===============================================================
-- Post-hooks only (never replacing a Blizzard function); errors stay inside.
local function guard(name, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      S.errors = (S.errors or 0) + 1
      S.lastErr = name .. ": " .. tostring(err)
      dbg("error in %s", S.lastErr)
    end
  end
end
local function hookG(name, fn)
  if hooksecurefunc and type(_G[name]) == "function" then hooksecurefunc(name, guard(name, fn)) end
end
local function hookT(t, name, fn)
  if hooksecurefunc and type(t) == "table" and type(t[name]) == "function" then hooksecurefunc(t, name, guard(name, fn)) end
end
local function num(v) return (type(v) == "number" and not secret(v)) and v or nil end
local function ownName(n) return n ~= nil and n ~= "" and M.IsOwnChar ~= nil and M.IsOwnChar(n) end

-- GlobalStrings format -> anchored Lua pattern; positional "%1$s" tolerated,
-- the trailing period optional
local function escapeFmt(fmt)
  local p = fmt:gsub("%%%d%$", "%%")
  p = p:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
  return p
end
local function fmtPattern(fmt)
  if type(fmt) ~= "string" or fmt == "" then return nil end
  local p = escapeFmt(fmt):gsub("%%s", "(.+)")
  p = p:gsub("%%d", "(%%d+)")
  p = p:gsub("%%%.$", "%%.?")
  return "^" .. p .. "$"
end

local COIN
local function coins(s)
  if not COIN then
    COIN = {}
    for _, u in ipairs({ { GOLD_AMOUNT, 10000 }, { SILVER_AMOUNT, 100 }, { COPPER_AMOUNT, 1 } }) do
      if type(u[1]) == "string" then
        COIN[#COIN + 1] = { pat = (escapeFmt(u[1]):gsub("%%d", "(%%d+)")), mult = u[2] }
      end
    end
  end
  local total, any = 0, false
  for _, u in ipairs(COIN) do
    local n = tonumber(s:match(u.pat))
    if n then total = total + n * u.mult; any = true end
  end
  return any and total or nil
end

local MONEY_PATS
local function onMoneyChat(msg)
  if type(msg) ~= "string" or secret(msg) then return end
  if not MONEY_PATS then
    -- guild variants first: the plain "You loot %s" would also match them
    MONEY_PATS = {}
    local fmts = { YOU_LOOT_MONEY_GUILD, LOOT_MONEY_SPLIT_GUILD, YOU_LOOT_MONEY, LOOT_MONEY_SPLIT }
    for i = 1, 4 do
      local p = fmtPattern(fmts[i])
      if p then MONEY_PATS[#MONEY_PATS + 1] = p end
    end
  end
  for _, p in ipairs(MONEY_PATS) do
    local s = msg:match(p)
    if s then
      local c = coins(s)
      if c and c > 0 then expectGold({ { cat = "lg", amt = c, src = "chat", late = true, ttl = 5 } }) end
      return
    end
  end
end

local LOOT_PATS
local function lootPats()
  if LOOT_PATS then return LOOT_PATS end
  LOOT_PATS = {}
  local function add(fmt, kind)
    local p = fmtPattern(fmt)
    if p then LOOT_PATS[#LOOT_PATS + 1] = { pat = p, kind = kind } end
  end
  add(LOOT_ITEM_SELF_MULTIPLE, "loot"); add(LOOT_ITEM_PUSHED_SELF_MULTIPLE, "push")
  add(LOOT_ITEM_CREATED_SELF_MULTIPLE, "create")
  add(LOOT_ITEM_SELF, "loot"); add(LOOT_ITEM_PUSHED_SELF, "push"); add(LOOT_ITEM_CREATED_SELF, "create")
  return LOOT_PATS
end

-- "You receive item" carries no source: the open window decides
local function pushCat()
  local t = now()
  if active("de") then return "ie" end
  if active("merchant") then return "bn" end
  if active("mail") then return (S.mailCat and t - S.mailCat.at < 5 and S.mailCat.cat) or "ir" end
  if active("trade") then return "ir" end
  if active("quest") then return "iq" end
  if active("craft") then return "ic" end
  if active("loot") then return S.lootCat or "il" end
  return "il"
end

local function onLootChat(msg)
  if type(msg) ~= "string" or secret(msg) then return end
  for _, P in ipairs(lootPats()) do
    local a, b = msg:match(P.pat)
    if a then
      local link, n = a, tonumber(b)
      if not n and b and tonumber(a) then link, n = b, tonumber(a) end
      local id = idOf(link)
      if not id then return end
      local cat
      if P.kind == "create" then cat = "ic"
      elseif P.kind == "loot" then cat = (active("loot") and S.lootCat) or "il"
      else cat = pushCat() end
      expectItem({ cat = cat, id = id, q = n or 1, src = "chat", late = true, ttl = 5 })
      return
    end
  end
end

-- loot window: coin slots and items, the source decided by what opened it.
-- Only container-like items (clams, lockboxes, bags of loot) count as opened.
local OPENABLE = { [1] = true, [12] = true, [15] = true }
local function onLootOpened()
  setCtx("loot", true)
  local t = now()
  local cat = "il"
  if active("de") then
    cat = "ie"
  elseif (S.gatherAt and t - S.gatherAt < 5) or (IsFishingLoot and IsFishingLoot()) then
    cat = "ig"
  elseif S.use and t - S.use.at < 2 and OPENABLE[classOf(S.use.id) or -1] then
    cat = "io"
    if not S.use.opened then
      S.use.opened = true
      expectItem({ cat = "xo", id = S.use.id, q = -1, hook = true, src = "open" })
    end
  end
  S.lootCat = cat
  local coinType = LOOT_SLOT_MONEY or (Enum and Enum.LootSlotType and Enum.LootSlotType.Money) or 2
  local coin = false
  for i = 1, (GetNumLootItems and GetNumLootItems()) or 0 do
    local st = GetLootSlotType and GetLootSlotType(i)
    local isCoin
    if st ~= nil then isCoin = (st == coinType) else isCoin = LootSlotIsCoin and LootSlotIsCoin(i) end
    if isCoin then
      coin = true
    else
      local id = GetLootSlotLink and idOf(GetLootSlotLink(i))
      local q = GetLootSlotInfo and num(select(3, GetLootSlotInfo(i)))
      if id then expectItem({ cat = cat, id = id, q = (q and q > 0) and q or 1, hook = true, src = "loot", ttl = 60 }) end
    end
  end
  if coin then expectGold({ { cat = "lg", sign = 1, src = "loot", ttl = 60, lootWin = true } }) end
end

local function onLootClosed()
  setCtx("loot", false)
  local tail = now() + CTX_TAIL
  for _, e in ipairs(GQ) do if e.lootWin and e.exp > tail then e.exp = tail end end
  for _, e in ipairs(IQ) do if e.src == "loot" and e.exp > tail then e.exp = tail end end
end

-- spell casts: disenchant/prospect and gathering decide the loot source,
-- casts with the profession window open keep the craft context alive
local SPELLS
local function spellName(id)
  if C_Spell and C_Spell.GetSpellName then
    local ok, n = pcall(C_Spell.GetSpellName, id)
    if ok and n then return n end
  end
  if GetSpellInfo then
    local ok, n = pcall(GetSpellInfo, id)
    if ok then return n end
  end
  return nil
end
local function onCast(unit, _, spellID)
  if unit ~= "player" or not num(spellID) then return end
  if not SPELLS then
    SPELLS = { de = {}, gather = {} }
    for _, id in ipairs({ 13262, 31252 }) do
      SPELLS.de[id] = true
      local n = spellName(id); if n then SPELLS.de[n] = true end
    end
    for _, id in ipairs({ 2575, 2366, 8613, 7620 }) do
      SPELLS.gather[id] = true
      local n = spellName(id); if n then SPELLS.gather[n] = true end
    end
  end
  local nm = spellName(spellID)
  if SPELLS.de[spellID] or (nm and SPELLS.de[nm]) then
    pulse("de", 5)
  elseif SPELLS.gather[spellID] or (nm and SPELLS.gather[nm]) then
    S.gatherAt = now()
  elseif isOpen("craft") then
    setCtx("craft", true)
  end
end

-- quests
hookG("GetQuestReward", function(choice)
  local money = num(GetRewardMoney and GetRewardMoney()) or 0
  if money > 0 then
    S.questMoney, S.questAt = money, now()
    expectGold({ { cat = "qg", amt = money, src = "quest" } })
  end
  local need = num(GetQuestMoneyToGet and GetQuestMoneyToGet()) or 0
  if need > 0 then expectGold({ { cat = "qc", amt = -need, src = "quest" } }) end
  local function want(kind, i, cat, sign)
    local id = GetQuestItemLink and idOf(GetQuestItemLink(kind, i))
    local cnt = GetQuestItemInfo and num(select(3, GetQuestItemInfo(kind, i)))
    if id then expectItem({ cat = cat, id = id, q = sign * ((cnt and cnt > 0) and cnt or 1), hook = true, src = "quest" }) end
  end
  for i = 1, (GetNumQuestRewards and GetNumQuestRewards()) or 0 do want("reward", i, "iq", 1) end
  if num(choice) and choice > 0 then want("choice", choice, "iq", 1) end
  for i = 1, (GetNumQuestItems and GetNumQuestItems()) or 0 do want("required", i, "xq", -1) end
end)

local function onQuestTurnedIn(_, _, money)
  money = num(money)
  if money and money > 0 and not (S.questMoney == money and now() - (S.questAt or 0) < 5) then
    expectGold({ { cat = "qg", amt = money, src = "quest", late = true } })
  end
end

-- merchant: buys, buyback, sales (new buyback rows), repairs
local bbList = {}
local function bbKey(e) return tostring(e.id or e.name) .. "|" .. e.price .. "|" .. e.qty end
local function buybackRow(i)
  if not GetBuybackItemInfo then return nil end
  local name, _, price, qty = GetBuybackItemInfo(i)
  if not name or secret(name) then return nil end
  local id = GetBuybackItemLink and idOf(GetBuybackItemLink(i))
  return { id = id, name = name, price = num(price) or 0, qty = num(qty) or 1 }
end
local function readBuyback()
  local t = {}
  for i = 1, (GetNumBuybackItems and GetNumBuybackItems()) or 0 do
    local e = buybackRow(i)
    if e then t[#t + 1] = e end
  end
  return t
end
local function buybackDiff()
  local new = readBuyback()
  local have = {}
  for _, e in ipairs(bbList) do local k = bbKey(e); have[k] = (have[k] or 0) + 1 end
  for _, e in ipairs(new) do
    local k = bbKey(e)
    if (have[k] or 0) > 0 then
      have[k] = have[k] - 1
    elseif e.price > 0 then
      expectGold({ { cat = "sn", amt = e.price, id = e.id, src = "sale", late = true, ttl = 5 } })
    end
  end
  bbList = new
end

local function repairCost()
  if not GetRepairAllCost then return 0 end
  return num((GetRepairAllCost())) or 0
end
local function checkRepair()
  if not isOpen("merchant") then return end
  local c = repairCost()
  local old = S.repair or c
  if c < old and InRepairMode and InRepairMode() then
    expectGold({ { cat = "rp", amt = c - old, tol = 1, src = "repair", late = true, ttl = 5 } })
  end
  S.repair = c
end

hookG("BuyMerchantItem", function(index, qty)
  local name, _, price, batch = M.GetMerchantItemInfo(index)
  if not name then return end
  batch = (num(batch) and batch > 0) and batch or 1
  local amount = (num(qty) and qty > 0) and qty or batch
  local id = GetMerchantItemLink and idOf(GetMerchantItemLink(index))
  price = num(price)
  if price and price > 0 then
    local cost = floor(price * (amount / batch) + 0.5)
    expectGold({ { cat = "bn", amt = -cost, tol = math.max(1, floor(cost * 0.01)), id = id, src = "buy" } })
  end
  if id then expectItem({ cat = "bn", id = id, q = amount, hook = true, src = "buy" }) end
end)

hookG("BuybackItem", function(index)
  local e = buybackRow(index) or bbList[index]
  if not e or e.price <= 0 then return end
  local k = bbKey(e)
  for i, x in ipairs(bbList) do
    if bbKey(x) == k then table.remove(bbList, i); break end
  end
  expectGold({ { cat = "sn", amt = -e.price, id = e.id, src = "buyback" } })
  if e.id then expectItem({ cat = "sn", id = e.id, q = e.qty, hook = true, src = "buyback" }) end
end)

hookG("RepairAllItems", function(guild)
  local c = S.repair
  if not c or c <= 0 then c = repairCost() end
  S.repair = 0
  if guild or c <= 0 then return end   -- the guild bank pays
  expectGold({ { cat = "rp", amt = -c, tol = math.max(1, floor(c * 0.01)), src = "repair" } })
end)

-- travel, training, talents, bank slots
hookG("TakeTaxiNode", function(slot)
  local c = num(TaxiNodeCost and TaxiNodeCost(slot))
  if c and c > 0 then expectGold({ { cat = "fl", amt = -c, src = "taxi", ttl = 15 } }) end
end)

hookG("BuyTrainerService", function(index)
  local c = num(GetTrainerServiceCost and GetTrainerServiceCost(index))
  if c and c > 0 then expectGold({ { cat = "tr", amt = -c, src = "trainer" } }) end
end)

hookG("ConfirmTalentWipe", function()
  if S.wipe and S.wipe > 0 then expectGold({ { cat = "tw", amt = -S.wipe, src = "talent" } }) end
  S.wipe = nil
end)
local function onTalentWipe(cost)
  S.wipe = num(cost)
  if S.wipe and type(ConfirmTalentWipe) ~= "function" then
    expectGold({ { cat = "tw", amt = -S.wipe, src = "talent", ttl = 120 } })
  end
end

hookG("PurchaseSlot", function()
  local n = num(GetNumBankSlots and GetNumBankSlots())
  local c = n and GetBankSlotCost and num(GetBankSlotCost(n))
  if c and c > 0 then expectGold({ { cat = "sv", amt = -c, src = "bankslot" } }) end
end)

-- auction house (classic list API)
hookG("PostAuction", function(minBid, buyout, runTime, stackSize, numStacks)
  numStacks = (num(numStacks) and numStacks > 0) and numStacks or 1
  local dep
  if GetAuctionDeposit then
    local ok, v = pcall(GetAuctionDeposit, runTime, minBid, buyout, stackSize, 1)
    if ok then dep = num(v) end
  end
  if not dep and CalculateAuctionDeposit then
    local ok, v = pcall(CalculateAuctionDeposit, runTime, stackSize, 1)
    if ok then dep = num(v) end
  end
  S.postAt = now()
  if dep == 0 then return end
  local list = {}
  for i = 1, numStacks do
    list[i] = dep and { cat = "ad", amt = -dep, src = "post", ttl = 20 + 3 * i }
                  or { cat = "ad", sign = -1, src = "post", ttl = 20 + 3 * i }
  end
  expectGold(list)
end)

hookG("PlaceAuctionBid", function(listType, index, bid)
  bid = num(bid)
  if not bid or bid <= 0 then return end
  local id, count
  if M.AuctionRowPrice then
    local _, _, rid, rc = M.AuctionRowPrice(listType, index)
    id, count = num(rid), num(rc)
  end
  S.bidAt = now()
  expectGold({ { cat = "ba", amt = -bid, tol = bid - 1, id = id, q = count, src = "bid" } })
end)

-- auction house (modern C_AuctionHouse)
do
  local AH = C_AuctionHouse
  local function deposit(ok, dep)
    dep = ok and num(dep)
    S.postAt = now()
    if dep == 0 then return end
    expectGold({ dep and { cat = "ad", amt = -dep, src = "post", ttl = 20 }
                       or { cat = "ad", sign = -1, src = "post", ttl = 20 } })
  end
  hookT(AH, "PostItem", function(item, duration, quantity)
    if AH.CalculateItemDeposit then deposit(pcall(AH.CalculateItemDeposit, item, duration, quantity)) else deposit(false) end
  end)
  hookT(AH, "PostCommodity", function(item, duration, quantity)
    local id
    if C_Item and C_Item.GetItemID then
      local ok, v = pcall(C_Item.GetItemID, item)
      if ok then id = num(v) end
    end
    if id and AH.CalculateCommodityDeposit then deposit(pcall(AH.CalculateCommodityDeposit, id, duration, quantity)) else deposit(false) end
  end)
  hookT(AH, "PlaceBid", function(_, bid)
    bid = num(bid)
    if not bid or bid <= 0 then return end
    S.bidAt = now()
    expectGold({ { cat = "ba", amt = -bid, tol = bid - 1, src = "bid" } })
  end)
  hookT(AH, "StartCommoditiesPurchase", function(itemID, quantity)
    S.cp = { id = num(itemID), q = num(quantity) }
  end)
  hookT(AH, "ConfirmCommoditiesPurchase", function(itemID, quantity)
    local cp = S.cp
    S.cp, S.bidAt = nil, now()
    local total = cp and cp.id == itemID and cp.total
    if total and total > 0 then
      expectGold({ { cat = "ba", amt = -total, tol = math.max(1, floor(total * 0.05)), id = num(itemID), q = num(quantity), src = "buy" } })
    else
      expectGold({ { cat = "ba", sign = -1, id = num(itemID), q = num(quantity), src = "buy" } })
    end
  end)
end

-- mail: what is taken is read inside the hook; a cached copy of the inbox
-- covers a mail the client already emptied
local SUBJ
local function mailKind(subject)
  if type(subject) ~= "string" then return nil, nil end
  if not SUBJ then
    local function pre(fmt)
      if type(fmt) ~= "string" then return nil end
      local i = fmt:find("%s", 1, true)
      return i and fmt:sub(1, i - 1) or fmt
    end
    SUBJ = { { "sold", pre(AUCTION_SOLD_MAIL_SUBJECT) }, { "won", pre(AUCTION_WON_MAIL_SUBJECT) },
             { "expired", pre(AUCTION_EXPIRED_MAIL_SUBJECT) }, { "cancelled", pre(AUCTION_REMOVED_MAIL_SUBJECT) },
             { "outbid", pre(AUCTION_OUTBID_MAIL_SUBJECT) }, { "cod", pre(COD_PAYMENT) } }
  end
  for _, s in ipairs(SUBJ) do
    local p = s[2]
    if p and p ~= "" and subject:sub(1, #p) == p then return s[1], subject:sub(#p + 1) end
  end
  return nil, nil
end

-- "Iron Bar (20)" -> "Iron Bar", 20
local function splitName(s)
  if type(s) ~= "string" or s == "" then return nil, nil end
  local q = tonumber(s:match("%((%d+)%)%s*$"))
  return (s:gsub("%s*%(%d+%)%s*$", "")), q
end

local function nameToID(name)
  if not name or name == "" then return nil end
  local idx = M.db and M.db.trade and M.db.trade.nameIndex
  local id = idx and idx[name:lower()]
  if not id and M.NameToID then
    local ok, v = pcall(M.NameToID, name)
    if ok then id = v end
  end
  return num(id)
end

local function readMail(i)
  if not GetInboxHeaderInfo then return nil end
  local _, _, sender, subject, money, cod = GetInboxHeaderInfo(i)
  if subject == nil or secret(subject) or secret(sender) then return nil end
  local m = { sender = sender, subject = subject, money = num(money) or 0, cod = num(cod) or 0, items = {} }
  if GetInboxInvoiceInfo then
    local kind, name, player, bid, buyout, dep, cut = GetInboxInvoiceInfo(i)
    if kind and not secret(kind) then
      m.inv = { kind = kind, name = name, player = player, bid = num(bid), buyout = num(buyout), deposit = num(dep), cut = num(cut) }
    end
  end
  for a = 1, ATTACHMENTS_MAX_RECEIVE or 16 do
    local id = GetInboxItemLink and idOf(GetInboxItemLink(i, a))
    if id then
      local cnt = GetInboxItem and num(select(4, GetInboxItem(i, a)))
      m.items[#m.items + 1] = { id = id, q = (cnt and cnt > 0) and cnt or 1, a = a }
    end
  end
  return m
end

local inbox = {}
local function cacheInbox()
  inbox = {}
  for i = 1, (GetInboxNumItems and GetInboxNumItems()) or 0 do inbox[i] = readMail(i) end
end

local function getMail(i)
  local live, c = readMail(i), inbox[i]
  if not live then return c end
  if c and c.subject == live.subject and c.sender == live.sender then
    if live.money == 0 then live.money = c.money end
    if live.cod == 0 then live.cod = c.cod end
    live.inv = live.inv or c.inv
    if #live.items == 0 then live.items = c.items end
  end
  inbox[i] = live
  return live
end

local function mailItemCat(m, kind)
  if kind == "won" then return "ba" end
  if kind == "expired" or kind == "cancelled" then return "ar" end
  if (m.cod or 0) > 0 then return "bp" end
  if ownName(m.sender) then return "at" end
  return "ir"
end

local function takeMoney(m)
  local money = m.money or 0
  if money <= 0 then return end
  m.money = 0
  local kind, rest = mailKind(m.subject)
  local inv = m.inv
  if kind == "sold" or (inv and inv.kind == "seller") then
    local name, q = splitName(rest)
    if inv and type(inv.name) == "string" and inv.name ~= "" then name = name or inv.name end
    local id = nameToID(name)
    if inv and inv.kind == "seller" then
      -- the sale mail also refunds the listing deposit
      local dep = inv.deposit
      dep = (dep and dep > 0 and dep < money) and dep or 0
      local fee = (inv.cut and inv.cut > 0) and inv.cut or 0
      local gross = money - dep + fee
      q = q or (id and M.AuctionSize and M.AuctionSize(id, gross)) or 1
      expectGold({ { parts = { { cat = "sa", amt = gross, id = id, q = q, nq = true },
                               { cat = "ac", amt = -fee }, { cat = "ad", amt = dep } }, src = "mail" } })
    else
      expectGold({ { cat = "sh", amt = money, id = id, q = q or 1, nq = true, src = "mail" } })
    end
  elseif kind == "outbid" then
    expectGold({ { cat = "ba", amt = money, src = "mail" } })
  elseif kind == "cod" then
    local name = splitName(rest)
    expectGold({ { cat = "sp", amt = money, id = nameToID(name), partner = m.sender, src = "mail" } })
  elseif ownName(m.sender) then
    expectGold({ { cat = "ag", amt = money, partner = m.sender, src = "mail" } })
  else
    expectGold({ { cat = "pg", amt = money, partner = m.sender, src = "mail" } })
  end
end

local function takeItems(m, which)
  local kind = mailKind(m.subject)
  local cat = mailItemCat(m, kind)
  S.mailCat = { cat = cat, at = now() }
  local first
  for _, it in ipairs(m.items) do
    if not which or it.a == which then
      first = first or it.id
      expectItem({ cat = cat, id = it.id, q = it.q, hook = true, src = "mail" })
    end
  end
  if (m.cod or 0) > 0 then
    expectGold({ { cat = "bp", amt = -m.cod, id = first, partner = m.sender, src = "cod" } })
    m.cod = 0
  end
end

hookG("TakeInboxMoney", function(i)
  local m = getMail(i)
  if m then takeMoney(m) end
end)
hookG("TakeInboxItem", function(i, a)
  local m = getMail(i)
  if m then takeItems(m, a or 1) end
end)
hookG("AutoLootMailItem", function(i)
  local m = getMail(i)
  if m then takeMoney(m); takeItems(m, nil) end
end)

local pendingSend
hookG("SendMail", function(to)
  local items = {}
  for a = 1, ATTACHMENTS_MAX_SEND or 12 do
    local id = GetSendMailItemLink and idOf(GetSendMailItemLink(a))
    if id then
      local cnt = GetSendMailItem and num(select(4, GetSendMailItem(a)))
      items[#items + 1] = { id = id, q = (cnt and cnt > 0) and cnt or 1 }
    end
  end
  pendingSend = {
    to = to, at = now(), items = items,
    postage = num(GetSendMailPrice and GetSendMailPrice()) or 0,
    money = num(GetSendMailMoney and GetSendMailMoney()) or 0,
    cod = num(GetSendMailCOD and GetSendMailCOD()) or 0,
  }
end)

local function onSendSuccess()
  local p = pendingSend
  pendingSend = nil
  if not p or now() - p.at > 30 then return end
  local own = ownName(p.to)
  local list = {}
  if p.postage > 0 then list[#list + 1] = { cat = "po", amt = -p.postage, src = "mail", late = true } end
  if p.money > 0 then
    list[#list + 1] = { cat = own and "ag" or "tp", amt = -p.money, partner = p.to, src = "mail", late = true }
  end
  if #list > 0 then expectGold(list) end
  local icat = own and "at" or ((p.cod > 0) and "sp" or "xg")
  for _, it in ipairs(p.items) do
    expectItem({ cat = icat, id = it.id, q = -it.q, hook = true, late = true, src = "mail" })
  end
end

-- containers: a sale at an open merchant, else remembered for "opened"
local lastUseKey, lastUseAt
local function onUse(bag, slot)
  local t = now()
  local key = tostring(bag) .. ":" .. tostring(slot)
  if lastUseKey == key and t - (lastUseAt or 0) < 0.05 then return end
  lastUseKey, lastUseAt = key, t
  local id, q = slotItem(bag, slot)
  if not id then return end
  if isOpen("merchant") then
    if not (InRepairMode and InRepairMode()) then
      expectItem({ cat = "sn", id = id, q = -(q or 1), hook = true, src = "sell" })
    end
    return
  end
  if isOpen("mail") or isOpen("trade") or isOpen("bank") or isOpen("ah") then return end
  S.use = { id = id, at = t }
end
hookT(CT, "UseContainerItem", onUse)
hookG("UseContainerItem", onUse)

-- destroying: the item on the cursor (or the last one picked up)
local function cursorItem()
  if not GetCursorInfo then return nil end
  local kind, id = GetCursorInfo()
  if kind == "item" then return num(id) end
  return nil
end
local function onPickup()
  local id = cursorItem()
  if id then S.pick = { id = id, at = now() } end
end
hookT(CT, "PickupContainerItem", onPickup)
hookG("PickupContainerItem", onPickup)
hookG("PickupInventoryItem", onPickup)
hookG("DeleteCursorItem", function()
  local id = cursorItem() or S.delId
  if not id and S.pick and now() - S.pick.at < 60 then id = S.pick.id end
  S.delId, S.pick = nil, nil
  if id then expectItem({ cat = "xx", id = id, sign = -1, hook = true, src = "delete", ttl = 5 }) end
end)

-- trade window (Trades.lua calls this for every completed trade)
local function splitByValue(list, gold)
  local vals, sum, units = {}, 0, 0
  for i, it in ipairs(list) do
    local c = it.count or 1
    vals[i] = (it.id and unitValue(it.id) or 0) * c
    sum = sum + vals[i]; units = units + c
  end
  local out, left = {}, gold
  for i, it in ipairs(list) do
    local share = left
    if i < #list then
      local w = (sum > 0) and (vals[i] / sum) or ((it.count or 1) / math.max(1, units))
      share = floor(gold * w + 0.5)
      if abs(share) > abs(left) then share = left end
    end
    out[i] = share
    left = left - share
  end
  return out
end

function M.LedgerTrade(snap)
  if type(snap) ~= "table" or not S.started then return end
  local partner = snap.partner
  local own = ownName(partner)
  local mine, theirs = snap.mine or {}, snap.theirs or {}
  local goldIn = (num(snap.theirGold) or 0) - (num(snap.myGold) or 0)
  local gcat, outCat, inCat
  if own then
    gcat, outCat, inCat = "ag", "at", "at"
  elseif #theirs == 0 and #mine > 0 and goldIn > 0 then
    gcat, outCat, inCat = "sp", "sp", "ir"
  elseif #mine == 0 and #theirs > 0 and goldIn < 0 then
    gcat, outCat, inCat = "bp", "xg", "bp"
  else
    gcat, outCat, inCat = (goldIn > 0) and "pg" or "tp", "xg", "ir"
  end
  if goldIn ~= 0 then
    local goods = (gcat == "sp") and mine or ((gcat == "bp") and theirs or nil)
    if goods then
      local shares = splitByValue(goods, goldIn)
      local parts = {}
      for i, it in ipairs(goods) do parts[i] = { cat = gcat, amt = shares[i], id = it.id, partner = partner } end
      expectGold({ { parts = parts, src = "trade", late = true } })
    else
      expectGold({ { cat = gcat, amt = goldIn, partner = partner, src = "trade", late = true } })
    end
  end
  for _, it in ipairs(mine) do
    if it.id then expectItem({ cat = outCat, id = it.id, q = -(it.count or 1), hook = true, late = true, src = "trade" }) end
  end
  for _, it in ipairs(theirs) do
    if it.id then expectItem({ cat = inCat, id = it.id, q = it.count or 1, hook = true, late = true, src = "trade" }) end
  end
end

-- ===== Session start, events ================================================
local function startSession(m)
  local L = ldb(); if not L then return end
  local ck = ckey()
  local last = L.last[ck]
  -- money changed while the addon was not recording (other client, disabled)
  if not off() and last and num(last.m) and last.m ~= m then
    bookGold("ur", m - last.m, nil, "gap")
  end
  lastMoney, S.start, S.flow, S.skipped = m, m, 0, 0
  S.started = true
  if not off() then L.since[ck] = L.since[ck] or time() end
  saveLast()
end

local function onEnterWorld()
  if not M.db then return end
  if not S.begun then
    S.begun = true
    M.LedgerPrune()
    local function try(n)
      local m = num(GetMoney and GetMoney())
      if not m then return end
      local L = ldb()
      local last = L and L.last[ckey()]
      if m == 0 and last and (num(last.m) or 0) > 0 and n < 2 then
        C_Timer.After(2, function() try(n + 1) end)
        return
      end
      startSession(m)
    end
    try(0)
  else
    onMoney()
  end
  seedItems()
end

local OPEN = {
  MERCHANT_SHOW = "merchant", MAIL_SHOW = "mail", AUCTION_HOUSE_SHOW = "ah", TAXIMAP_OPENED = "taxi",
  TRAINER_SHOW = "trainer", BANKFRAME_OPENED = "bank", TRADE_SHOW = "trade",
  QUEST_DETAIL = "quest", QUEST_PROGRESS = "quest", QUEST_COMPLETE = "quest", QUEST_GREETING = "quest",
  TRADE_SKILL_SHOW = "craft", CRAFT_SHOW = "craft",
}
local CLOSE = {
  MERCHANT_CLOSED = "merchant", MAIL_CLOSED = "mail", AUCTION_HOUSE_CLOSED = "ah", TAXIMAP_CLOSED = "taxi",
  TRAINER_CLOSED = "trainer", BANKFRAME_CLOSED = "bank", TRADE_CLOSED = "trade", QUEST_FINISHED = "quest",
  TRADE_SKILL_CLOSE = "craft", CRAFT_CLOSE = "craft",
}
-- modern clients announce most windows through the interaction manager
local PIT = {}
do
  local E = Enum and Enum.PlayerInteractionType
  if E then
    for k, v in pairs({ Merchant = "merchant", MailInfo = "mail", Auctioneer = "ah", TaxiNode = "taxi",
                        Trainer = "trainer", Banker = "bank", TradePartner = "trade" }) do
      if E[k] then PIT[E[k]] = v end
    end
  end
end

local function openCtx(name)
  if name == "bank" then bankShow() end
  setCtx(name, true)
  if name == "merchant" then
    bbList = readBuyback()
    S.repair = repairCost()
  elseif name == "mail" then
    cacheInbox()
  end
end

local function closeCtx(name)
  if name == "bank" then bankHide() end
  setCtx(name, false)
end

local function onEvent(event, a1, a2, a3)
  if event == "PLAYER_MONEY" then
    onMoney()
  elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_EQUIPMENT_CHANGED" or event == "PLAYERBANKSLOTS_CHANGED" then
    scheduleItems()
  elseif event == "CHAT_MSG_LOOT" then
    onLootChat(a1)
  elseif event == "CHAT_MSG_MONEY" then
    onMoneyChat(a1)
  elseif event == "LOOT_OPENED" then
    onLootOpened()
  elseif event == "LOOT_CLOSED" then
    onLootClosed()
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    onCast(a1, a2, a3)
  elseif event == "MERCHANT_UPDATE" then
    buybackDiff()
    checkRepair()
  elseif event == "UPDATE_INVENTORY_DURABILITY" then
    checkRepair()
  elseif event == "MAIL_INBOX_UPDATE" then
    cacheInbox()
  elseif event == "MAIL_SEND_SUCCESS" then
    onSendSuccess()
  elseif event == "MAIL_FAILED" then
    pendingSend = nil
  elseif event == "QUEST_TURNED_IN" then
    onQuestTurnedIn(a1, a2, a3)
  elseif event == "CONFIRM_TALENT_WIPE" then
    onTalentWipe(a1)
  elseif event == "DELETE_ITEM_CONFIRM" then
    S.delId = cursorItem() or S.delId
  elseif event == "COMMODITY_PRICE_UPDATED" then
    if S.cp then S.cp.total = num(a2) end
  elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
    if PIT[a1] then openCtx(PIT[a1]) end
  elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
    if PIT[a1] then closeCtx(PIT[a1]) end
  elseif OPEN[event] then
    openCtx(OPEN[event])
  elseif CLOSE[event] then
    closeCtx(CLOSE[event])
  elseif event == "PLAYER_ENTERING_WORLD" then
    onEnterWorld()
  elseif event == "PLAYER_LOGOUT" then
    flushHeld(true)
    flushHeldI(true)
    saveLast()
  end
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "PLAYER_MONEY", "BAG_UPDATE_DELAYED",
                     "PLAYER_EQUIPMENT_CHANGED", "PLAYERBANKSLOTS_CHANGED", "CHAT_MSG_MONEY", "CHAT_MSG_LOOT",
                     "LOOT_OPENED", "LOOT_CLOSED", "MERCHANT_UPDATE", "UPDATE_INVENTORY_DURABILITY",
                     "MAIL_INBOX_UPDATE", "MAIL_SEND_SUCCESS", "MAIL_FAILED", "QUEST_TURNED_IN",
                     "CONFIRM_TALENT_WIPE", "DELETE_ITEM_CONFIRM", "UNIT_SPELLCAST_SUCCEEDED",
                     "COMMODITY_PRICE_UPDATED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
                     "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }) do
  M.SafeRegister(ev, e)
end
for e in pairs(OPEN) do M.SafeRegister(ev, e) end
for e in pairs(CLOSE) do M.SafeRegister(ev, e) end
ev:SetScript("OnEvent", guard("event", function(_, event, ...) onEvent(event, ...) end))

-- ===== Retention ============================================================
local function monthKey(day)
  local t = date("*t", day * 86400 + M.C.SCAN_DAY_0 + 43200)
  return t.year * 100 + t.month
end

local midCache = {}
local function monthMid(mk)
  local v = midCache[mk]
  if not v then
    v = floor((time({ year = floor(mk / 100), month = mk % 100, day = 15, hour = 12 }) - M.C.SCAN_DAY_0) / 86400)
    midCache[mk] = v
  end
  return v
end

-- once per login: days older than KEEP_DAYS fold into monthly totals (values
-- only), finished days keep their top items only
function M.LedgerPrune()
  local L = ldb(); if not L then return end
  local today = M.GetScanDay()
  local cut = today - KEEP_DAYS
  for realm, days in pairs(L.d) do
    for day, chars in pairs(days) do
      if type(day) ~= "number" or type(chars) ~= "table" then
        days[day] = nil
      elseif day < cut then
        local mm = sub(sub(L.mo, realm), monthKey(day))
        for ck, c in pairs(chars) do
          local t = mm[ck]
          if not t then t = { v = {}, d = 0 }; mm[ck] = t end
          for cat, v in pairs(c.v or {}) do addKey(t.v, cat, v) end
          t.d = t.d + 1
        end
        days[day] = nil
      elseif day < today then
        for _, c in pairs(chars) do
          for cat in pairs(c.n or {}) do capItems(c, cat) end
          for cat in pairs(c.w or {}) do capItems(c, cat) end
        end
      end
    end
    if next(days) == nil then L.d[realm] = nil end
  end
  local R = L.recent
  while #R > RECENT_MAX do table.remove(R) end
  if (L.ri or 0) > #R then L.ri = #R end
end

-- ===== Query ================================================================
function M.LedgerChars(realm)
  realm = realm or M.RealmKey()
  local out, seen = {}, {}
  local L = ldb()
  if not L then return out end
  local function add(ck)
    if seen[ck] then return end
    seen[ck] = true
    local c = M.db.chars and M.db.chars[ck]
    out[#out + 1] = { key = ck, name = (c and c.name) or ck:match("^(.-)%-") or ck }
  end
  for _, chars in pairs(L.d[realm] or {}) do for ck in pairs(chars) do add(ck) end end
  for _, chars in pairs(L.mo[realm] or {}) do for ck in pairs(chars) do add(ck) end end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

local function addAll(dst, src)
  for cat, t in pairs(src) do
    local o = dst[cat]; if not o then o = {}; dst[cat] = o end
    for id, v in pairs(t) do addKey(o, id, v) end
  end
end

function M.LedgerQuery(q)
  q = q or {}
  local out = { v = {}, n = {}, w = {}, x = {}, days = 0 }
  local L = ldb()
  if not L then return out end
  local realm = q.realm or M.RealmKey()
  local from, to = q.fromDay or -math.huge, q.toDay or math.huge
  local chars = {}
  for day, dd in pairs(L.d[realm] or {}) do
    if day >= from and day <= to then
      local any = false
      for ck, c in pairs(dd) do
        if not q.char or q.char == ck then
          any = true
          chars[ck] = true
          for cat, v in pairs(c.v or {}) do addKey(out.v, cat, v) end
          if c.n then addAll(out.n, c.n) end
          if c.w then addAll(out.w, c.w) end
          for p, v in pairs(c.x or {}) do addKey(out.x, p, v) end
        end
      end
      if any then out.days = out.days + 1 end
    end
  end
  for mk, mm in pairs(L.mo[realm] or {}) do
    local mid = monthMid(mk)
    if mid >= from and mid <= to then
      local dmax = 0
      for ck, t in pairs(mm) do
        if not q.char or q.char == ck then
          chars[ck] = true
          for cat, v in pairs(t.v or {}) do addKey(out.v, cat, v) end
          if (t.d or 0) > dmax then dmax = t.d end
        end
      end
      out.days = out.days + dmax
    end
  end
  for cat, t in pairs(out.n) do if next(t) == nil then out.n[cat] = nil end end
  for cat, t in pairs(out.w) do if next(t) == nil then out.w[cat] = nil end end
  if q.char then chars[q.char] = true end
  for ck in pairs(chars) do
    local s = L.since[ck]
    if s and (not out.since or s < out.since) then out.since = s end
  end
  return out
end

-- ===== Model for the Sankey and the flow table ==============================
local function itemList(r, cat)
  local n, w = r.n[cat], r.w[cat]
  if not n and not w then return nil, nil end
  local list, seen, count = {}, {}, 0
  local function add(id)
    if seen[id] then return end
    seen[id] = true
    local qty = abs((n and n[id]) or 0)
    local val = w and w[id]
    val = val and abs(val) or qty * unitValue(id)
    count = count + qty
    list[#list + 1] = { id = id, qty = qty, value = floor(val + 0.5) }
  end
  for id in pairs(n or {}) do add(id) end
  for id in pairs(w or {}) do add(id) end
  table.sort(list, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    if a.qty ~= b.qty then return a.qty > b.qty end
    return a.id < b.id
  end)
  for i = #list, 9, -1 do list[i] = nil end
  return (#list > 0) and list or nil, (count > 0) and count or nil
end

local function mergeItems(a, b)
  if not b then return a end
  local by, out = {}, {}
  for _, l in ipairs({ a or {}, b }) do
    for _, it in ipairs(l) do
      local o = by[it.id]
      if not o then o = { id = it.id, qty = 0, value = 0 }; by[it.id] = o; out[#out + 1] = o end
      o.qty, o.value = o.qty + it.qty, o.value + it.value
    end
  end
  table.sort(out, function(x, y)
    if x.value ~= y.value then return x.value > y.value end
    return x.id < y.id
  end)
  for i = #out, 9, -1 do out[i] = nil end
  return out
end

local function copyList(t)
  if not t then return nil end
  local o = {}
  for i, v in ipairs(t) do
    local c = {}
    for k, x in pairs(v) do c[k] = x end
    o[i] = c
  end
  return o
end

local BUY_SUB = { ba = "Auction house", bn = "Vendors", bp = "Players",
                  sa = "AH sales reversed", sh = "AH sales reversed", sn = "Vendor buybacks", sp = "Player refunds" }

function M.LedgerModel(q)
  q = q or {}
  local r = M.LedgerQuery(q)
  local allChars = q.char == nil
  local nodes, links, rows = {}, {}, {}
  local function addNode(t) nodes[#nodes + 1] = t; return t end
  local function link(from, to, value, label, color, items)
    if value > 0 then
      links[#links + 1] = { from = from, to = to, value = value, label = label, color = color, items = copyList(items) }
    end
  end
  local function catNode(cat, label, col, lane, color, items, value)
    local nd = addNode({ id = "C_" .. cat, label = label, col = col, lane = lane, color = color, cat = cat,
                         items = copyList(items) })
    nd._v = value
    local hub = (lane == "gold") and "GOLD" or "STOCK"
    if col == 0 then link(nd.id, hub, value, nil, color, items) else link(hub, nd.id, value, nil, color, items) end
  end
  local buyTotal, buySub, buyItems = 0, {}, nil
  local function addBuy(cat, value, items)
    buyTotal = buyTotal + value
    buySub[#buySub + 1] = { label = BUY_SUB[cat] or CATS[cat].label, value = value }
    buyItems = mergeItems(buyItems, items)
  end

  for _, cat in ipairs(ORDER) do
    local def = CATS[cat]
    local v = r.v[cat] or 0
    local items, count = itemList(r, cat)
    if def.side == "int" then
      if items then
        local val = 0
        for id, qn in pairs(r.n[cat] or {}) do val = val + abs(qn) * unitValue(id) end
        rows[#rows + 1] = { key = cat, label = def.label, side = def.side, value = floor(val + 0.5), items = items, count = count }
      end
    elseif v ~= 0 then
      local neg, a, side = v < 0, abs(v), def.side
      local label = neg and def.alt or def.label
      if allChars and side == "altg" then label = neg and "In the mail" or "Out of the mail" end
      if allChars and side == "alti" then label = neg and "Goods in the mail" or "Goods out of the mail" end
      rows[#rows + 1] = { key = cat, label = label, side = side, value = a, items = items, count = count }
      local c = def.color
      if side == "gin" or side == "altg" then
        catNode(cat, label, neg and 3 or 0, "gold", c, items, a)
      elseif side == "gout" then
        catNode(cat, label, neg and 0 or 3, "gold", c, items, a)
      elseif side == "iin" or side == "alti" then
        catNode(cat, label, neg and 3 or 0, "goods", c, items, a)
      elseif side == "iout" then
        catNode(cat, label, neg and 0 or 3, "goods", c, items, a)
      elseif side == "sale" then
        if neg then addBuy(cat, a, items) else link("STOCK", "GOLD", a, def.label, c, items) end
      elseif side == "buy" then
        if neg then catNode(cat, label, 0, "gold", c, items, a) else addBuy(cat, a, items) end
      end
    end
  end
  if buyTotal > 0 then
    table.sort(buySub, function(x, y) return x.value > y.value end)
    addNode({ id = "BUY_G", label = "Spent on goods", col = 3, lane = "gold", color = "blue", group = "buy",
              items = copyList(buyItems), sub = copyList(buySub) })
    addNode({ id = "BUY_I", label = "Bought goods", col = 0, lane = "goods", color = "blue", group = "buy",
              items = copyList(buyItems), sub = copyList(buySub) })
    link("GOLD", "BUY_G", buyTotal, "Spent on goods", "blue", buyItems)
    link("BUY_I", "STOCK", buyTotal, "Bought goods", "blue", buyItems)
  end

  local function sums()
    local gi, go, si, so = 0, 0, 0, 0
    for _, l in ipairs(links) do
      if l.to == "GOLD" then gi = gi + l.value end
      if l.from == "GOLD" then go = go + l.value end
      if l.to == "STOCK" then si = si + l.value end
      if l.from == "STOCK" then so = so + l.value end
    end
    return gi, go, si, so
  end

  -- fold categories under 1% of the largest hub throughput (two or more per
  -- column and lane) into one node; the table keeps them separate
  local gi, go, si, so = sums()
  local thr = math.max(gi, go, si, so) * 0.01
  local groups, gorder = {}, {}
  for _, nd in ipairs(nodes) do
    if nd.cat and nd._v and nd._v < thr then
      local k = nd.col .. nd.lane
      if not groups[k] then groups[k] = {}; gorder[#gorder + 1] = k end
      table.insert(groups[k], nd)
    end
  end
  for _, k in ipairs(gorder) do
    local g = groups[k]
    if #g >= 2 then
      local f = g[1]
      local fold = { id = "FOLD_" .. f.col .. "_" .. f.lane, label = (f.col == 0) and "Smaller sources" or "Smaller sinks",
                     col = f.col, lane = f.lane, color = "muted", sub = {} }
      local total, gone, items = 0, {}, nil
      for _, nd in ipairs(g) do
        total = total + nd._v
        gone[nd.id] = true
        fold.sub[#fold.sub + 1] = { label = nd.label, value = nd._v }
        items = mergeItems(items, nd.items)
      end
      fold.items = items
      local keepN, keepL = {}, {}
      for _, nd in ipairs(nodes) do if not gone[nd.id] then keepN[#keepN + 1] = nd end end
      for _, l in ipairs(links) do if not gone[l.from] and not gone[l.to] then keepL[#keepL + 1] = l end end
      nodes, links = keepN, keepL
      addNode(fold)
      local hub = (f.lane == "gold") and "GOLD" or "STOCK"
      if f.col == 0 then link(fold.id, hub, total, nil, "muted", items) else link(hub, fold.id, total, nil, "muted", items) end
    end
  end

  -- balance both hubs exactly
  gi, go, si, so = sums()
  if gi > go then
    addNode({ id = "SAVED", label = "Saved gold", col = 3, lane = "gold", color = "accent" })
    link("GOLD", "SAVED", gi - go, nil, "accent")
  elseif go > gi then
    addNode({ id = "SAVINGS", label = "From savings", col = 0, lane = "gold", color = "accent" })
    link("SAVINGS", "GOLD", go - gi, nil, "accent")
  end
  if si > so then
    addNode({ id = "BUILT", label = "Stock built", col = 3, lane = "goods", color = "mint",
              note = "flow-based - see Net Worth for market value" })
    link("STOCK", "BUILT", si - so, nil, "mint")
  elseif so > si then
    addNode({ id = "DRAWN", label = "Drawn from stock", col = 0, lane = "goods", color = "sub" })
    link("DRAWN", "STOCK", so - si, nil, "sub")
  end
  local usedGold, usedStock = false, false
  for _, l in ipairs(links) do
    if l.from == "GOLD" or l.to == "GOLD" then usedGold = true end
    if l.from == "STOCK" or l.to == "STOCK" then usedStock = true end
  end
  if usedGold then table.insert(nodes, 1, { id = "GOLD", label = "Gold", col = 2, lane = "gold", hub = true, color = "accent" }) end
  if usedStock then table.insert(nodes, 1, { id = "STOCK", label = "Stock", col = 1, lane = "goods", hub = true, color = "sub" }) end
  for _, nd in ipairs(nodes) do nd._v = nil end

  table.sort(rows, function(x, y)
    if x.value ~= y.value then return x.value > y.value end
    return x.key < y.key
  end)
  local un = abs(r.v.oi or 0) + abs(r.v.os or 0)
  local denom = gi + go
  return {
    nodes = nodes, links = links, rows = rows,
    summary = {
      goldIn = gi, goldOut = go, goldNet = gi - go, goodsIn = si, goodsOut = so,
      unattributed = un, unattributedShare = (denom > 0) and math.min(1, un / denom) or 0,
      since = r.since, days = r.days,
    },
  }
end

function M.LedgerRecent(n)
  local out = {}
  local L = ldb()
  if not L then return out end
  local R, total = L.recent, #L.recent
  if total == 0 then return out end
  local i = L.ri or total
  n = math.min(n or 20, total)
  for k = 0, n - 1 do out[#out + 1] = R[((i - 1 - k) % total) + 1] end
  return out
end

-- ===== Slash ================================================================
local function printSummary(title, q)
  local m = M.LedgerModel(q)
  local s = m.summary
  M.Print(string.format("%s: gold in %s, out %s, net %s   \194\183   goods in %s, out %s", title,
    M.MoneyPlain(s.goldIn), M.MoneyPlain(s.goldOut), signed(s.goldNet), M.MoneyPlain(s.goodsIn), M.MoneyPlain(s.goodsOut)))
  local top = {}
  for i = 1, math.min(4, #m.rows) do top[#top + 1] = m.rows[i].label .. " " .. M.MoneyPlain(m.rows[i].value) end
  if #top > 0 then print("   " .. table.concat(top, "  \194\183  ")) end
end

local function eventText(e)
  local def = CATS[e.cat]
  local what
  if def and def.g then
    what = signed(e.v or 0)
  else
    what = string.format("%+d x %s", e.q or 0, (e.id and M.ItemName and M.ItemName(tostring(e.id))) or tostring(e.id))
  end
  return string.format("%s  %s  %s  (%s)", date("%H:%M:%S", e.ts or 0), def and def.label or tostring(e.cat), what, e.src or "?")
end

function M.LedgerSlash(arg)
  arg = arg or ""
  if arg == "debug" then
    S.debug = not S.debug
    M.Print("Ledger debug: " .. (S.debug and "ON - every gold and item flow is printed with its cause" or "OFF"))
  elseif arg == "recent" then
    local list = M.LedgerRecent(15)
    if #list == 0 then M.Print("Ledger: nothing recorded yet.") end
    for i = #list, 1, -1 do print("   " .. eventText(list[i])) end
  elseif arg == "check" then
    if not S.started then M.Print("Ledger: not started yet.") return end
    local m = num(GetMoney()) or 0
    local hs = 0
    for _, h in ipairs(held) do hs = hs + h.d end
    local diff = (m - S.start) - S.flow - S.skipped - hs
    M.Print(string.format("Ledger check: session %s, booked %s, waiting %s%s  ->  difference %s",
      signed(m - S.start), signed(S.flow), signed(hs), (S.skipped ~= 0) and (", not recorded " .. signed(S.skipped)) or "",
      (diff == 0) and "0 (ok)" or signed(diff)))
  elseif arg == "" then
    if off() then M.Print("Ledger (beta) recording is OFF (Ledger tab or Settings > \"Record ledger\").") end
    local today, ck = M.GetScanDay(), ckey()
    printSummary("Ledger (beta) today", { char = ck, fromDay = today, toDay = today })
    printSummary("Last 7 days", { char = ck, fromDay = today - 6, toDay = today })
  else
    M.Print("/midas ledger (beta)  -  today and the last 7 days   \194\183   debug  -  live attribution   \194\183   recent  -  last 15 flows   \194\183   check  -  session balance")
  end
end

M._ledgerTest = {
  S = S, GQ = GQ, IQ = IQ, held = held, heldI = heldI,
  flushHeld = function() flushHeld(true); flushHeldI(true) end,
  flushItems = flushNow,
  snapshot = snapshot,
  base = function() return base end,
  lastMoney = function() return lastMoney end,
  active = active,
}
