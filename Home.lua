-- Midas - Home: the Start tab as a command center, four cards on a 12-column
-- grid: NET WORTH (where it stands, why it moved) | TRADING (what trading
-- earned) over WATCHLIST MAP (the watchlist as an inventory grid tinted by
-- price vs Fair) | NEXT MOVES (concrete steps, most urgent first).
-- M.HomeModel() computes every number without touching the UI (tests use it);
-- the cards are laid out from the window size and draw from widget pools that
-- only grow.
local ADDON, M = ...
local T = M.Theme
local C = T.C
local floor, abs, max, min = math.floor, math.abs, math.max, math.min

local GUT, PAD = 8, 12                    -- grid gutter, card padding
local BASE_W, BASE_H = 952, 426           -- content panel at the 980x560 minimum
local HEAD = 30                           -- card header (title row)
local QMARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local CIRCLE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"   -- round dot (tinted)
local COIN = "Interface\\Icons\\INV_Misc_Coin_01"
local MINUS = "\226\136\146"              -- typographic minus (font strings only)
local LEQ = "\226\137\164"                -- "<=" (font strings only)
local DOT = "  \194\183  "
local ARROW = "  \226\128\186"
local CUT = 0.95                          -- the AH keeps 5% of a sale
local HIT_FRESH = 24 * 3600               -- a fired alert counts as news this long
local SZ_HERO, SZ_VALUE, SZ_ROW, SZ_LABEL = 28, 17, 12, 11

-- ===== small helpers ==========================================================
local function colorize(fs, rgb, a) fs:SetTextColor(rgb[1], rgb[2], rgb[3], a or 1) end
local function hex(rgb)
  return string.format("|cff%02x%02x%02x", floor(rgb[1] * 255 + 0.5), floor(rgb[2] * 255 + 0.5), floor(rgb[3] * 255 + 0.5))
end
local function mix(a, b, k)
  return { a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k, a[3] + (b[3] - a[3]) * k }
end
local function short(c) return M.MoneyShort and M.MoneyShort(c) or M.MoneyPlain(c) end
local function pickD() return (M.C and M.C.PICK_DELTA) or 0.15 end

-- "+12g" / "-3s"; zero reads "no change" (never "+0c"). plain = Latin-1 (tooltips)
local function signedMoney(c, compact, plain)
  c = floor((c or 0) + 0.5)
  if c == 0 then return "no change" end
  local body = compact and short(abs(c)) or M.MoneyPlain(abs(c))
  return ((c > 0) and "+" or (plain and "-" or MINUS)) .. body
end

-- "+38%" / "-43%"; under half a percent reads "0%" (never "-0%").
-- trunc: cut toward zero - next to a threshold the label never rounds past it
local function pct(d, plain, unsigned, trunc)
  local v = (d or 0) * 100
  if trunc then v = (v >= 0) and floor(v) or -floor(-v) end
  if abs(v) < 0.5 then return "0%" end
  local s = unsigned and string.format("%.0f%%", abs(v)) or string.format("%+.0f%%", v)
  if not plain then s = s:gsub("^%-", MINUS) end
  return s
end

local function itemIcon(key)
  local id = M.BaseID and M.BaseID(key)
  return (id and M.GetItemIcon and M.GetItemIcon(id)) or QMARK
end

local function setName(fs, key, fallback)
  if key then
    fs:SetText(M.ItemName(key) or fallback or "?")
    local qc = M.ItemQualityColor(key)
    fs:SetTextColor(qc.r, qc.g, qc.b)
  else
    fs:SetText(fallback or ""); colorize(fs, C.text)
  end
end

local function place(fr, x, y, w, hgt)
  fr:ClearAllPoints()
  fr:SetPoint("TOPLEFT", fr:GetParent(), "TOPLEFT", floor(x + 0.5), -floor(y + 0.5))
  fr:SetSize(max(1, floor(w + 0.5)), max(1, floor(hgt + 0.5)))
end

local function inScope(c)
  return c and not c.dead and ((not M.CharInScope) or M.CharInScope(c))
end

-- tooltip lines are game-font: Latin-1 only (no arrows, no math signs)
local function tipOpen(owner, title, rgb, anchor)
  local c = rgb or C.accent
  GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
  GameTooltip:SetMinimumWidth(240)
  GameTooltip:AddLine(title or "", c[1], c[2], c[3])
end
local function tipLine(text, rgb, wrap)
  local c = rgb or C.sub
  GameTooltip:AddLine(text, c[1], c[2], c[3], wrap and true or false)
end
local function tipKV(k, v, vrgb)
  local c = vrgb or C.text
  GameTooltip:AddDoubleLine(k, v, C.sub[1], C.sub[2], C.sub[3], c[1], c[2], c[3])
end
local function tipClose()
  GameTooltip:SetMinimumWidth(0)
  GameTooltip:Hide()
end
local function tipHelp(lines)
  for _, ln in ipairs(lines or {}) do
    if ln == "" then GameTooltip:AddLine(" ") else tipLine(ln, C.sub, true) end
  end
end

-- ===== model ==================================================================
-- items the living characters of this realm + faction hold (bags, bank, mail)
-- and the ids with an active or pending auction of their own
local function ownership()
  local hold, listed = {}, {}
  for ck, c in pairs((M.db and M.db.chars) or {}) do
    if inScope(c) then
      local name = c.name or ck:match("^(.-)%-") or ck
      -- by field name: an ipairs over a table built from the three caches ends
      -- at the first missing one (no bank visit = no mail either)
      for _, field in ipairs({ "bags", "bank", "mail" }) do
        local src = c[field]
        if type(src) == "table" then
          for id, q in pairs(src) do
            local nid = tonumber(id)
            if nid and type(q) == "number" and q > 0 then
              local e = hold[nid]
              if not e then e = { qty = 0, who = {} }; hold[nid] = e end
              e.qty = e.qty + q
              e.who[name] = (e.who[name] or 0) + q
            end
          end
        end
      end
      for _, field in ipairs({ "auctions", "pending" }) do
        local src = c[field]
        if type(src) == "table" then
          for id in pairs(src) do local nid = tonumber(id); if nid then listed[nid] = true end end
        end
      end
    end
  end
  return hold, listed
end

-- row of the newest scan day - or a newer quick-scan row of the item (those
-- never move the newest scan day, Data.lua M.CommitQuick) - and its day
local function newestRec(key, lastDay)
  local s = M.GetSeries(key)
  if not (s and lastDay) then return nil end
  local today = M.GetScanDay()
  for d = today, math.max(lastDay + 1, today - 14), -1 do
    if s[d] then return s[d], d end
  end
  return s[lastDay], lastDay
end

-- price + timestamp in the newest scan, or a newer live price the AH showed
-- since (Data.lua) while it is listed
local function newestCur(key, lastDay)
  local rec, day = newestRec(key, lastDay)
  local cur, ts = rec and (rec.cur or rec.low), rec and rec.ts
  local lv = M.FreshLive and M.FreshLive(key, rec, day or lastDay)
  if lv and M.LiveListed(lv) then cur, ts = lv.p, lv.ts end
  return cur, ts
end

-- SELL: held, not listed, >= PICK_DELTA over Fair, listed in the newest scan,
-- enough history, a real market item. Suggested ask X = min(cur - 1c, Fair x
-- (1 + PICK_DELTA)); margin = (X x 0.95 - Fair) x min(qty, avgQty)
local function sellIdeas(hold, listed)
  local pd = pickD()
  local minDays = (M.C and M.C.MIN_DAYS) or 4
  local out = {}
  for id, e in pairs(hold) do
    if not listed[id] then
      local key = tostring(id)
      local series = M.GetSeries(key)
      if series and (not M.IsTradeable or M.IsTradeable(key) == true) then
        local m = M.Metrics(series, key)
        if m and m.fair and m.fair > 0 and m.cur and (m.days or 0) >= minDays
           and not (M.NotListed and M.NotListed(m)) and (m.cur / m.fair - 1) >= pd then
          local x = min(m.cur - 1, floor(m.fair * (1 + pd)))
          if x > m.fair then
            local units = min(e.qty, max(1, floor((m.avgQty or e.qty) + 0.5)))
            out[#out + 1] = { kind = "sell", key = key, qty = e.qty, who = e.who, m = m, ask = x,
                              prem = m.cur / m.fair - 1, margin = (x * CUT - m.fair) * units }
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.margin ~= b.margin then return a.margin > b.margin end
    return a.key < b.key
  end)
  return out
end

-- BUY: watchlist items and the market's own picks clearly under Fair today.
-- Picks you do not watch must be liquid (Fast / Steady) and within 60% (a lone
-- lowball listing is not a market); beyond 60% only one unit counts. Every
-- margin is weighted by how fast the item moves, so a slow 700g gear piece
-- does not outrank a steady mat flip; what costs more than all your gold is out
local LIQ_W = { Fast = 1, Steady = 0.75, Slow = 0.4, Illiquid = 0.15 }
local function buyIdeas(wlist, lastDay, money)
  local pd = pickD()
  local out, seen = {}, {}
  local function add(key, m, watched)
    local id = (M.BaseID and M.BaseID(key)) or key
    if seen[id] or not (m and m.fair and m.fair > 0 and m.cur and m.delta) then return end
    if m.delta > -pd or (M.NotListed and M.NotListed(m)) then return end
    if not watched and (not (m.liqLabel == "Fast" or m.liqLabel == "Steady") or m.delta < -0.60) then return end
    if money and money > 0 and m.cur > money then return end
    local unit = m.fair * CUT - m.cur
    if unit <= 0 then return end
    seen[id] = true
    local units = (m.delta < -0.60) and 1 or min(20, max(1, floor((m.avgQty or 1) + 0.5)))
    out[#out + 1] = { kind = "buy", key = key, m = m, unit = unit, new = not watched,
                      margin = unit * units * (LIQ_W[m.liqLabel or ""] or 0.4) }
  end
  for _, e in ipairs(wlist) do add(e.key, e.m, true) end
  local buys, _, lastPick = M.TopPicks()
  for _, rec in ipairs(buys or {}) do
    local s = M.GetSeries(rec.key)
    add(rec.key, s and M.Metrics(s, rec.key), M.IsWatched and M.IsWatched(rec.key))
  end
  for i, e in ipairs((M.RankAll and M.RankAll()) or {}) do
    if #out >= 12 or i > 300 then break end
    if e.m and lastPick and e.m.lastDay == lastPick then add(e.key, e.m, M.IsWatched and M.IsWatched(e.key)) end
  end
  table.sort(out, function(a, b)
    if a.margin ~= b.margin then return a.margin > b.margin end
    return a.key < b.key
  end)
  return out
end

-- price alerts: fresh hits, stale hits ("past limit"), distance of the rest
local function alertState(realm, lastDay, now)
  local hits, rest, armed = {}, {}, 0
  local al = M.db and M.db.alerts and M.db.alerts[realm]
  for key, a in pairs(al or {}) do
    if type(a) == "table" and (a.below or a.above) then
      local cur = newestCur(key, lastDay)
      local e = { kind = "alert", key = key, below = a.below, above = a.above, cur = cur, listed = cur ~= nil }
      local fired = (a.bFired and "below") or (a.aFired and "above") or nil
      if fired then
        local ts = (fired == "below") and a.bTs or a.aTs
        e.side, e.limit = fired, (fired == "below") and a.below or a.above
        if ts and (now - ts) <= HIT_FRESH then
          e.hit, e.ts = true, ts
          hits[#hits + 1] = e
        else
          e.past = true
          rest[#rest + 1] = e
        end
      else
        armed = armed + 1
        if cur and cur > 0 then
          local db = a.below and (cur / a.below - 1) or math.huge
          local da = a.above and (1 - cur / a.above) or math.huge
          if db <= da then e.dist, e.side, e.limit = db, "below", a.below
          else e.dist, e.side, e.limit = da, "above", a.above end
          rest[#rest + 1] = e
        end
      end
    end
  end
  table.sort(hits, function(x, y)
    if (x.ts or 0) ~= (y.ts or 0) then return (x.ts or 0) > (y.ts or 0) end
    return x.key < y.key
  end)
  table.sort(rest, function(x, y)
    if (x.past and true or false) ~= (y.past and true or false) then return x.past and true or false end
    if (x.dist or 0) ~= (y.dist or 0) then return (x.dist or 0) < (y.dist or 0) end
    return x.key < y.key
  end)
  return hits, rest, armed
end

-- UNDERCUT: your live listing asks more than the cheapest in a NEWER scan.
-- Listings older than the longest auction run (24h; 48h on TBC Anniversary)
-- have sold or expired already
local function undercuts(lastDay, now)
  local maxAge = ((M.CLIENT_FLAVOR == "tbc") and 48 or 24) * 3600
  local out, byKey = {}, {}
  for ck, c in pairs((M.db and M.db.chars) or {}) do
    if inScope(c) and type(c.auctions) == "table" and c.auctionsTs and (now - c.auctionsTs) <= maxAge then
      for id, a in pairs(c.auctions) do
        local ask
        for u in pairs(a.lv or {}) do if not ask or u < ask then ask = u end end
        if not ask and (a.qty or 0) > 0 then ask = floor((a.gold or 0) / a.qty) end
        local key = tostring(id)
        local cur, curTs = newestCur(key, lastDay)
        local units = ask and ((a.lv and a.lv[ask]) or a.qty or 1) or 0
        -- a newer scan, a cheaper ask, and enough at stake to be worth a repost
        if ask and cur and curTs and curTs > c.auctionsTs and cur < ask and (ask - cur) * units >= 1000
           and ask * units >= 10000 then
          local e = byKey[key]
          if not e or (ask - cur) * units > e.margin then
            e = { kind = "undercut", key = key, ask = ask, cur = cur, units = units, seenH = (now - c.auctionsTs) / 3600,
                  who = c.name or ck:match("^(.-)%-") or ck, margin = (ask - cur) * units }
            if not byKey[key] then out[#out + 1] = e end
            byKey[key] = e
          end
        end
      end
    end
  end
  for i, e in ipairs(out) do out[i] = byKey[e.key] end
  table.sort(out, function(a, b)
    if a.margin ~= b.margin then return a.margin > b.margin end
    return a.key < b.key
  end)
  return out
end

-- the latest sales and buys, one line per (day, kind, item); auctions that
-- came back are counted in SELL-THROUGH already
local KIND = { sold = true, bought = true }
local function latestTrades(realm, n, perDay)
  local log = (M.TradeLog and M.TradeLog(realm, 2000)) or {}
  local out, byKey = {}, {}
  for i = 1, #log do
    local e = log[i]
    if KIND[e.kind] then
      local gk = e.kind .. "|" .. (perDay and (e.day or 0) or "") .. "|" .. tostring(e.id or e.name)
      local g = byKey[gk]
      local amt = (e.kind == "sold") and (e.net or e.gross or 0) or (e.gross or 0)
      if g then
        g.count = g.count + (e.count or 1); g.amt = g.amt + amt
      elseif #out < n then
        g = { kind = e.kind, day = e.day, id = e.id, name = e.name, count = e.count or 1, amt = amt }
        byKey[gk] = g
        out[#out + 1] = g
      end
    end
  end
  return out
end

function M.HomeModel(opts)
  opts = opts or {}
  local realm, today = M.RealmKey(), M.GetScanDay()
  local lastDay = M.LastScanDay and M.LastScanDay(realm) or -1
  local now = time()
  local nw = M.NetWorth and M.NetWorth()
  local hist = (M.NWHist and M.NWHist()) or {}
  local mo = { realm = realm, today = today, lastDay = lastDay, now = now, nw = nw }

  -- one reference day for the hero pill, the attribution and TRADING
  local at
  if nw and M.WorthAttribution then at = M.WorthAttribution(nw, today - 7) end
  local ref = at and at.refDay
  -- a reference of today (first day of a new install) compares nothing
  if ref and ref >= today then ref, at = nil, nil end
  if not ref then
    for day, s in pairs(hist) do
      if type(s) == "table" and s.t and day <= today - 7 and (not ref or day > ref) then ref = day end
    end
  end
  local prevDay
  for day, s in pairs(hist) do
    if type(s) == "table" and s.t and day < today and (not prevDay or day > prevDay) then prevDay = day end
  end
  local nChars, top = 0, nil
  for ck, info in pairs((nw and nw.chars) or {}) do
    nChars = nChars + 1
    if M.CharDeltaSince then
      local d, refDay = M.CharDeltaSince(ck, info.total)   -- direct call: keep both returns
      if d and refDay and d ~= 0 and (not top or abs(d) > abs(top.d)) then top = { name = info.name or ck, d = d } end
    end
  end
  mo.hero = { total = (nw and nw.total) or 0, prevDay = prevDay, prev = prevDay and hist[prevDay].t,
              ref = ref, refT = ref and hist[ref] and hist[ref].t, at = at, chars = nChars, top = top,
              grave = nw and nw.graveTotal or 0 }

  -- trading over the same window as the hero; without a reference snapshot
  -- (a young install) the last 7 calendar days. Sell-through as the Trades tab
  -- shows it - unless its snapshot is from today or yesterday, then the plain
  -- window (an afterDay of today would drop today's own sales)
  local sm, smDays
  if M.TradeSummary then
    if ref then sm, smDays = M.TradeSummary(realm, nil, ref), today - ref
    else sm, smDays = M.TradeSummary(realm, 6), 7 end
  end
  local win = (M.C and M.C.SELL_WINDOW) or 60
  local ref60
  if nw and M.HoldingsDelta then
    local _, r60 = M.HoldingsDelta(nw, win)
    ref60 = r60
  end
  if ref60 and ref60 >= today - 1 then ref60 = nil end
  local s60 = M.TradeSummary and M.TradeSummary(realm, win, ref60)
  local okN = s60 and (s60.sold + s60.ret) >= ((M.C and M.C.SELL_MIN_N) or 3)
  mo.trading = { sm = sm, days = smDays or 7, s60 = s60, s60days = ref60 and (today - ref60) or win,
                 rate = okN and s60.sellThrough or nil, trades = latestTrades(realm, opts.trades or 3, opts.tradeDays ~= false) }

  -- watchlist + ownership; "to sell" on the map = exactly the SELL filter
  local hold, listed = ownership()
  mo.hold, mo.listed = hold, listed
  local sells = sellIdeas(hold, listed)
  local sellKey = {}
  for _, e in ipairs(sells) do sellKey[e.key] = true end
  local wlist = (M.RankWatch and M.RankWatch()) or {}
  mo.wlist = wlist
  local pd = pickD()
  local items, cheap, toSell, notListed = {}, 0, 0, 0
  local seenKey = {}
  local function addItem(key, m, unwatched)
    local isL = m and m.delta and not (M.NotListed and M.NotListed(m))
    local d = isL and m.delta or nil
    local id = M.BaseID and M.BaseID(key)
    local owned = sellKey[tostring(id or key)] and true or false
    if d and d <= -pd then cheap = cheap + 1 elseif d and d >= pd and owned then toSell = toSell + 1 end
    if not d then notListed = notListed + 1 end
    items[#items + 1] = { key = key, d = d, owned = owned, m = m, unwatched = unwatched }
    seenKey[key] = true
  end
  for _, e in ipairs(wlist) do addItem(e.key, e.m) end
  for key in pairs(opts.unwatched or {}) do
    if not seenKey[key] then
      local s = M.GetSeries(key)
      addItem(key, s and M.Metrics(s, key), true)
    end
  end
  mo.map = { items = items, cheap = cheap, toSell = toSell, notListed = notListed }

  -- next moves
  local hits, rest, armed = alertState(realm, lastDay, now)
  local uc = undercuts(lastDay, now)
  local buys = buyIdeas(wlist, lastDay, nw and nw.money)
  local rows = opts.rows or 6
  -- tier sizes: the base 6 rows hold 2 + 2 + 3/3 + 2; a taller card lets
  -- the trade ideas and the alert tail grow with it
  local capT = max(3, floor(rows * 0.4))
  local capN = max(2, floor(rows * 0.2))
  local list = {}
  for i = 1, min(2, #hits) do list[#list + 1] = hits[i] end
  for i = 1, min(2, #uc) do if #list < rows then list[#list + 1] = uc[i] end end
  local trade, si, bi = {}, 1, 1
  while (si <= min(capT, #sells) or bi <= min(capT, #buys)) do
    local s, b = (si <= capT) and sells[si] or nil, (bi <= capT) and buys[bi] or nil
    if s and (not b or s.margin >= b.margin) then trade[#trade + 1] = s; si = si + 1
    elseif b then trade[#trade + 1] = b; bi = bi + 1 else break end
  end
  local tailN = min(capN, #rest)
  for _, e in ipairs(trade) do if #list < rows - tailN then list[#list + 1] = e end end
  for i = 1, tailN do if #list < rows then list[#list + 1] = rest[i] end end
  -- leftover room after a short alert list: more trade ideas
  for _, e in ipairs(trade) do
    if #list >= rows then break end
    local dup = false
    for _, x in ipairs(list) do if x == e then dup = true break end end
    if not dup then list[#list + 1] = e end
  end
  local collect, collectWho = 0, {}
  for ck, c in pairs((M.db and M.db.chars) or {}) do
    if inScope(c) and (c.mailGold or 0) >= 10000 then
      collect = collect + c.mailGold
      collectWho[#collectWho + 1] = { name = c.name or ck:match("^(.-)%-") or ck, g = c.mailGold }
    end
  end
  table.sort(collectWho, function(a, b)
    if a.g ~= b.g then return a.g > b.g end
    return a.name < b.name
  end)
  local stale = (lastDay and lastDay >= 0 and today - lastDay >= 2) and (today - lastDay) or nil
  mo.moves = { list = list, hits = hits, rest = rest, armed = armed, extraHits = max(0, #hits - 2),
               undercuts = uc, sells = sells, buys = buys, stale = stale, noScan = (not lastDay or lastDay < 0) }
  -- buy ideas wait for the whole-archive analysis: until its first result the
  -- card keeps its loading layer (Loading.lua) instead of a half list
  mo.moves.pending = (M.TopPicks and select(4, M.TopPicks())) and true or nil
  mo.hero.mail, mo.hero.mailWho = collect, collectWho
  return mo
end

-- ===== card ===================================================================
-- flat surface, a faint three-step sheen on top, a colour square + caps
-- title, optional context after the title, the "tab >" jump on the right.
-- The whole card opens its tab; hovering the title explains the numbers.
local function newCard(h, key, title, colorKey, opts)
  opts = opts or {}
  local c = T.Surface(h.panel, "bg1", "border")
  for i, a in ipairs({ 0.020, 0.013, 0.007 }) do
    local sh = c:CreateTexture(nil, "BACKGROUND", nil, 2)
    sh:SetColorTexture(1, 1, 1, a)
    sh:SetPoint("TOPLEFT", 1, -1 - (i - 1) * 8); sh:SetPoint("TOPRIGHT", -1, -1 - (i - 1) * 8); sh:SetHeight(8)
  end
  local rgb = C[colorKey] or C.accent
  local dot = c:CreateTexture(nil, "ARTWORK")
  dot:SetColorTexture(rgb[1], rgb[2], rgb[3], 1)
  dot:SetSize(6, 6); dot:SetPoint("TOPLEFT", PAD, -13)
  local t = T.Text(c, SZ_LABEL, "sub", T.FONT_MED)
  t:SetPoint("LEFT", dot, "RIGHT", 6, 0); t:SetText(title)
  c.title, c.dot = t, dot
  c.ctx = T.Text(c, SZ_LABEL, "muted")
  c.ctx:SetPoint("LEFT", t, "RIGHT", 10, 0)
  if opts.tab then
    local b = CreateFrame("Button", nil, c)
    b:SetAllPoints(); b:SetFrameLevel(c:GetFrameLevel() + 1)
    local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.012)
    b:SetScript("OnClick", function()
      if opts.click then opts.click() elseif M.TAB[opts.tab] then M.SelectTab(M.TAB[opts.tab]) end
    end)
    c.btn = b
    local go = T.Text(c, SZ_LABEL, "muted")
    go:SetPoint("TOPRIGHT", -PAD, -11); go:SetJustifyH("RIGHT")
    go:SetText((opts.go or opts.tab:lower()) .. ARROW)
    c.go = go
  end
  -- the explanation lives on the title row, above the card's click button
  local hz = CreateFrame("Frame", nil, c)
  hz:SetPoint("TOPLEFT", c, "TOPLEFT", 4, -4)
  hz:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", 6, -5)
  hz:SetFrameLevel(c:GetFrameLevel() + 6)
  hz:EnableMouse(true)
  hz:SetScript("OnEnter", function(self)
    tipOpen(self, opts.help and opts.help[1] or title, C.accent, "ANCHOR_CURSOR")
    tipHelp(opts.help and opts.help[2])
    if opts.helpFn then opts.helpFn() end
    GameTooltip:Show()
  end)
  hz:SetScript("OnLeave", tipClose)
  c.helpZone = hz
  h.cards[key] = c
  return c
end

-- small tinted label ("today +9g", "SELL"); returns its width
local function newPill(parent)
  local p = CreateFrame("Frame", nil, parent)
  p:SetHeight(18)
  p.bg = p:CreateTexture(nil, "BACKGROUND"); p.bg:SetAllPoints()
  p.fs = T.Text(p, SZ_LABEL, "text", T.FONT_MED); p.fs:SetPoint("CENTER", 0, 0)
  function p:Set(text, rgb, fixedW, alpha)
    self.fs:SetText(text or ""); colorize(self.fs, rgb)
    self.bg:SetColorTexture(rgb[1], rgb[2], rgb[3], alpha or 0.15)
    local w = fixedW or floor(self.fs:GetStringWidth() + 14.5)
    self:SetWidth(w)
    return w
  end
  return p
end

-- item buttons: hover = tooltip, click = chart, right-click = watch / unwatch,
-- the configurable Alt/Shift shortcuts first (as everywhere in Midas)
local function itemClick(self, mouse)
  local key = self.key
  if not key then return end
  if M.ModPostDown and M.ModPostDown() then M.PostItemStats(key); return end
  if M.ModSearchDown and M.ModSearchDown() then M.ItemShiftAction(key); return end
  if mouse == "RightButton" then
    M.ToggleWatch(key)
    if M.HideTip then M.HideTip() end
    tipClose()
    M.RefreshHome()
  elseif M.Go then
    M.Go("chart", key)
  end
end
local function wireItem(b, tipFn)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnEnter", function(self)
    if not self.key then return end
    if tipFn then tipFn(self) elseif M.ShowItemTip then M.ShowItemTip(self.key, true) end
  end)
  b:SetScript("OnLeave", function(self)
    if M.HideTip then M.HideTip() end
    tipClose()
    if self.onLeave then self.onLeave(self) end
  end)
  b:SetScript("OnClick", itemClick)
  local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.06)
end

-- a clickable text strip (attribution line, footer chips)
local function linkText(parent, size, colorKey)
  local fs = T.Text(parent, size or SZ_LABEL, colorKey or "sub")
  local b = CreateFrame("Button", nil, parent)
  b:SetFrameLevel(parent:GetFrameLevel() + 5)
  b:SetAllPoints(fs)
  b:SetScript("OnLeave", tipClose)
  fs.btn = b
  return fs
end

-- ===== build ==================================================================
local HELP = {
  hero = { "Net worth", {
    "Gold + item value (Fair) + active auctions (valued at their chance to sell) of your living characters on this realm and faction.",
    "today / 7 days: change against the newest daily snapshot before today and the snapshot a week back. The line under them splits the week into market moves, stock bought or sold, and gold - click it for the item list.",
    "The bar shows what the total is made of (colours as in the Net Worth tab)." } },
  trading = { "Trading", {
    "NET P/L: your logged trades over the same week as the net-worth change - sales after the AH cut minus AH buys, exactly as the Trades tab counts it.",
    "SELL-THROUGH: share of your auctions that sold rather than came back over the last " .. ((M.C and M.C.SELL_WINDOW) or 60) .. " days.",
    "Below: your latest trades, one line per item and day." } },
  map = { "Watchlist map", {
    "Every watched item as a tile, cheapest first: green = under Fair, red = over Fair, the stronger the further. A gold dot marks what you hold and could sell now (the SELL ideas of Next moves).",
    "Plain tiles sit within 15% of Fair; dimmed tiles have no listing in the newest scan.",
    "Hover for the item, click for its chart, right-click to unwatch (right-click again to undo)." } },
  moves = { "Next moves", {
    "Most urgent first: price alerts that fired in the last 24 hours, your listings that a newer scan undercuts, then SELL and BUY ideas by the gold they move, then alerts close to their limit.",
    "SELL: things you hold (bags, bank, mail - not listed yet) that trade at least 15% over Fair; list at or under the shown price. BUY: watched items, or liquid market picks marked new, at least 15% under Fair.",
    "Bound BoE items cannot be told apart in the bag cache - skip those." } },
}

-- ===== Classic start page ====================================================
-- The 1.2.19 start page, one switch away: the segment in the window header
-- (Start tab only) sets config.homeView = "classic". Its code is kept as it
-- was, on its own root frame next to the dashboard's.
local buildClassic, refreshClassic
do
  local TAB = M.TAB
  local function cell(parent, x, y, w, just, size, colorKey, variant)
    local fs = T.Text(parent, size or T.SIZE.body, colorKey, variant)
    fs:SetPoint("TOPLEFT", x, y); fs:SetWidth(w); fs:SetJustifyH(just or "LEFT")
    return fs
  end
  local function extraH(panel)
    local hh = panel and panel:GetHeight()
    return math.max(0, math.floor((hh or 426) - 426))
  end
  local function ShowItemTip(key) if M.ShowItemTip then M.ShowItemTip(key, true) end end
  local function HideTip() if M.HideTip then M.HideTip() end end
  local function GoChart(key)
    if not key then return end
    if M.Go then M.Go("chart", key) else M.SetChartKey(key); M.SelectTab(TAB.Charts) end
  end

  -- The account at a glance, in three rows: net-worth hero + MARKET TODAY (the
  -- best buy/sell signals - today's picks merged with the archive-wide
  -- opportunity ranking), the WATCHLIST across the full width (the focus), and
  -- the biggest character movers + your trading highlights. Item rows behave
  -- like everywhere else: hover = tooltip, left-click = chart, right-click = watch.
  local HOME_ROWH = 17

  local function homeCard(panel, titleText, rgb, tabName, clickFn, goText)
    local card = T.Surface(panel, "bg1", "border")
    local head = T.Text(card, T.SIZE.small, nil, T.FONT_MED)
    head:SetPoint("TOPLEFT", 12, -10); head:SetText(titleText); colorize(head, rgb or C.sub)
    local ur = rgb or C.sub
    local ul = card:CreateTexture(nil, "ARTWORK")
    ul:SetColorTexture(ur[1], ur[2], ur[3], 0.45)
    ul:SetHeight(2); ul:SetPoint("TOPLEFT", 12, -26); ul:SetWidth(head:GetStringWidth() + 2)
    card.head = head
    if tabName then
      local b = CreateFrame("Button", nil, card)
      b:SetAllPoints(); b:SetFrameLevel(card:GetFrameLevel() + 1)
      local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.02)
      b:SetScript("OnClick", function()
        if clickFn then clickFn() elseif TAB[tabName] then M.SelectTab(TAB[tabName]) end
      end)
      local go = T.Text(card, T.SIZE.tiny, "muted")
      go:SetPoint("TOPRIGHT", -12, -11); go:SetText((goText or tabName:lower()) .. " \226\134\146")
    end
    return card
  end

  local function wireItemBtn(b)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnEnter", function() if b.key then ShowItemTip(b.key) end end)
    b:SetScript("OnLeave", HideTip)
    b:SetScript("OnClick", function(_, mouse)
      if not b.key then return end
      if M.ModPostDown() then M.PostItemStats(b.key); return end
      if M.ModSearchDown() then M.ItemShiftAction(b.key); return end
      if mouse == "RightButton" then
        M.ToggleWatch(b.key)
        if M.RefreshHome then M.RefreshHome() end
      else
        GoChart(b.key)
      end
    end)
  end

  -- character rows (biggest movers): hover = the rich character card of the
  -- Net Worth tab, click = that character's items there
  local function wireCharBtn(b)
    b:SetScript("OnEnter", function(self)
      if self.ck and M.wealth and M.wealth.charTip then M.wealth.charTip(self) end
    end)
    b:SetScript("OnLeave", HideTip)
    b:SetScript("OnClick", function(self)
      if not self.ck then return end
      HideTip()
      if M.Go then M.Go("char", self.ck) end
    end)
  end

  -- rows of aligned cells inside a card region; row.btn covers the line (hover
  -- tooltip, click-to-chart, right-click-to-watch). rows.mk adds more on demand.
  -- inert = display-only rows: no mouse, no hover promise; inert = "char" makes
  -- character rows that open the character in Net Worth instead.
  local function homeRows(parent, x0, y0, cols, n, rowW, inert)
    local rows = {}
    local function mkRow(r)
      local y = y0 - (r - 1) * HOME_ROWH
      local row, cx = {}, x0
      for i, d in ipairs(cols) do
        row[i] = cell(parent, cx, y, d.w, d.just or "LEFT", T.SIZE.body)
        cx = cx + d.w + 6
      end
      local b = CreateFrame("Button", nil, parent)
      b:SetPoint("TOPLEFT", x0 - 2, y + 2); b:SetSize(rowW, HOME_ROWH - 1)
      b:SetFrameLevel(parent:GetFrameLevel() + 5)
      if inert == "char" then
        local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.05)
        wireCharBtn(b)
      elseif inert then
        b:EnableMouse(false)
      else
        local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.05)
        wireItemBtn(b)
      end
      row.btn = b
      rows[r] = row
    end
    for r = 1, n do mkRow(r) end
    rows.mk = mkRow
    return rows
  end

  local function setItemName(fs, key, fallbackText)
    if key then
      fs:SetText(M.ItemName(key))
      local qc = M.ItemQualityColor(key); fs:SetTextColor(qc.r, qc.g, qc.b)
    else
      fs:SetText(fallbackText or ""); colorize(fs, C.text)
    end
  end

  local function clearHomeRow(row)
    for i = 1, #row do row[i]:SetText("") end
    if row.btn then row.btn.key = nil; row.btn.ck = nil end
  end

  local W_COLS  = { { w = 170 }, { w = 70, just = "RIGHT" }, { w = 70, just = "RIGHT" }, { w = 50, just = "RIGHT" } }
  local MT_COLS = { { w = 190 }, { w = 48, just = "RIGHT" } }
  local MV_COLS = { { w = 150 }, { w = 100, just = "RIGHT" }, { w = 84, just = "RIGHT" } }
  local AL_COLS = { { w = 150 }, { w = 94, just = "RIGHT" }, { w = 90, just = "RIGHT" } }
  local LT_COLS = { { w = 44 }, { w = 46 }, { w = 150 }, { w = 84, just = "RIGHT" } }

  buildClassic = function(panel)
    local h = {}
    M.homeClassic = h
    h.panel = panel
    local R1H, R2H = 146, 136
    local R2Y, R3Y = -(146 + 8), -(146 + 8 + 136 + 8)

    -- NET WORTH hero + sparkline ----------------------------------------------
    local nwc = homeCard(panel, "NET WORTH", C.accent, "Net Worth")
    nwc:SetPoint("TOPLEFT", 0, 0); nwc:SetSize(380, R1H)
    h.nwTotal = T.Text(nwc, 25, "accent", T.FONT_SEMI)
    h.nwTotal:SetPoint("TOPLEFT", 12, -36)
    h.nwD1 = T.Text(nwc, T.SIZE.body, "sub"); h.nwD1:SetPoint("TOPLEFT", 12, -74)
    h.nwD7 = T.Text(nwc, T.SIZE.body, "sub"); h.nwD7:SetPoint("TOPLEFT", 12, -93)
    h.nwSub = T.Text(nwc, T.SIZE.tiny, "muted"); h.nwSub:SetPoint("BOTTOMLEFT", 12, 10)
    h.spark = CreateFrame("Frame", nil, nwc)
    h.spark:SetPoint("TOPLEFT", 196, -34); h.spark:SetPoint("BOTTOMRIGHT", -10, 8)
    h.spark:SetFrameLevel(nwc:GetFrameLevel() + 5)
    h.spark._compact = true
    if T.HelpTip then
      T.HelpTip(nwc, "Net worth", {
        "Gold + item value + active auctions across all your living characters. A snapshot is stored once a day; the line shows how it develops.",
        "Click for the full Net Worth tab with the per-character and per-item breakdown." }, "ANCHOR_CURSOR")
    end

    -- MARKET TODAY (today's picks + top opportunities, merged) ----------------
    local mt = homeCard(panel, "MARKET TODAY", C.sub, "Watchlist",
      function() if M.OpenBrowse then M.OpenBrowse() else M.SelectTab(TAB.Watchlist) end end,
      "all items")
    mt:SetPoint("TOPLEFT", 388, 0); mt:SetPoint("TOPRIGHT", 0, 0); mt:SetHeight(R1H)
    h.mtDay = T.Text(mt, T.SIZE.tiny, "muted")
    h.mtDay:SetPoint("TOPRIGHT", -84, -11); h.mtDay:SetJustifyH("RIGHT")   -- left of "all items >"
    local mbh = T.Text(mt, T.SIZE.tiny, "green", T.FONT_MED)
    mbh:SetPoint("TOPLEFT", 12, -32); mbh:SetText("BUY")
    local msh = T.Text(mt, T.SIZE.tiny, "red", T.FONT_MED)
    msh:SetPoint("TOPLEFT", mt, "TOP", 8, -32); msh:SetText("SELL")
    local ml = CreateFrame("Frame", nil, mt)
    ml:SetPoint("TOPLEFT", 12, -46); ml:SetPoint("BOTTOMRIGHT", mt, "BOTTOM", -8, 8)
    local mr = CreateFrame("Frame", nil, mt)
    mr:SetPoint("TOPLEFT", mt, "TOP", 8, -46); mr:SetPoint("BOTTOMRIGHT", -12, 8)
    h.mtBuy  = homeRows(ml, 0, 0, MT_COLS, 4, 250)
    h.mtSell = homeRows(mr, 0, 0, MT_COLS, 4, 250)
    if T.HelpTip then
      T.HelpTip(mt, "Market today", {
        "BUY: the best flip candidates right now - items trading clearly under Fair on the newest scan day, merged with the highest-scoring opportunities from your whole archive (score = margin x liquidity x confidence).",
        "SELL: highly liquid items trading clearly above Fair today. Vendor goods are excluded.",
        "Right-click an item to put it on your watchlist - the Watchlist is the working view." }, "ANCHOR_CURSOR")
    end

    -- WATCHLIST (the focus: a full-width row of its own) ----------------------
    local wc = homeCard(panel, "WATCHLIST", C.accent, "Watchlist")
    wc:SetPoint("TOPLEFT", 0, R2Y); wc:SetPoint("TOPRIGHT", 0, R2Y); wc:SetHeight(R2H)
    h.wCard = wc
    local wbh = T.Text(wc, T.SIZE.tiny, "green", T.FONT_MED)
    wbh:SetPoint("TOPLEFT", 12, -32); wbh:SetText("BUY LOW")
    local wsh = T.Text(wc, T.SIZE.tiny, "red", T.FONT_MED)
    wsh:SetPoint("TOPLEFT", wc, "TOP", 8, -32); wsh:SetText("SELL HIGH")
    h.wHeadL, h.wHeadR = wbh, wsh
    local wl = CreateFrame("Frame", nil, wc)
    wl:SetPoint("TOPLEFT", 12, -46); wl:SetPoint("BOTTOMRIGHT", wc, "BOTTOM", -8, 8)
    local wr = CreateFrame("Frame", nil, wc)
    wr:SetPoint("TOPLEFT", wc, "TOP", 8, -46); wr:SetPoint("BOTTOMRIGHT", -12, 8)
    h.wBuy  = homeRows(wl, 0, 0, W_COLS, 4, 440)
    h.wSell = homeRows(wr, 0, 0, W_COLS, 4, 440)
    h.wCount = T.Text(wc, T.SIZE.tiny, "muted")
    h.wCount:SetPoint("BOTTOMRIGHT", -12, 10); h.wCount:SetJustifyH("RIGHT")
    h.wEmpty = T.Text(wc, T.SIZE.body, "sub")
    h.wEmpty:SetPoint("LEFT", 24, 0); h.wEmpty:SetPoint("RIGHT", -24, 0)
    h.wEmpty:SetJustifyH("CENTER"); h.wEmpty:SetWordWrap(true); h.wEmpty:SetSpacing(4)
    h.wEmpty:SetText("Your watchlist is empty.\nOpen the Watchlist tab to search & add items \226\128\148 or right-click any item on this page to watch it.")
    h.wEmpty:Hide()

    -- BIGGEST MOVERS + PRICE ALERTS (one card, two compact sections) ----------
    local mv = homeCard(panel, "BIGGEST MOVERS", C.sub, "Net Worth")
    mv:SetPoint("TOPLEFT", 0, R3Y); mv:SetPoint("BOTTOMLEFT", 0, 0); mv:SetWidth(380)
    h.mvCard = mv
    -- character rows, not item rows: hover shows the character, click opens it
    -- in the Net Worth tab
    h.mvRows = homeRows(mv, 12, -32, MV_COLS, 2, 348, "char")
    -- the card's lower half: this realm's active price alerts, click = chart
    local alh = T.Text(mv, T.SIZE.tiny, "accent", T.FONT_MED)
    alh:SetPoint("TOPLEFT", 12, -74); alh:SetText("PRICE ALERTS")
    h.alMore = T.Text(mv, T.SIZE.tiny, "muted")
    h.alMore:SetPoint("LEFT", alh, "RIGHT", 8, 0)
    h.alRows = homeRows(mv, 12, -88, AL_COLS, 2, 348)
    if T.HelpTip then
      T.HelpTip(mv, "Movers & alerts", {
        "MOVERS: which characters gained or lost the most net worth since the previous daily snapshot - click one for its items in the Net Worth tab.",
        "PRICE ALERTS: this realm's active below/above limits. Click one to open its chart - the Charts tab sets and clears them." }, "ANCHOR_CURSOR")
    end

    -- YOUR TRADES -------------------------------------------------------------
    local tc = homeCard(panel, "YOUR TRADES", C.sub, "Trades")
    tc:SetPoint("TOPLEFT", 388, R3Y); tc:SetPoint("BOTTOMRIGHT", 0, 0)
    h.tcCard = tc
    local bs = T.Text(tc, T.SIZE.tiny, "muted", T.FONT_MED)
    bs:SetPoint("TOPLEFT", 12, -32); bs:SetText("BEST SALE \194\183 ALL TIME")
    h.tSale  = cell(tc, 12, -48, 182, "LEFT", T.SIZE.body)
    h.tSale2 = cell(tc, 12, -65, 182, "LEFT", T.SIZE.small)
    local bb = T.Text(tc, T.SIZE.tiny, "muted", T.FONT_MED)
    bb:SetPoint("TOPLEFT", 12, -84); bb:SetText("BEST BARGAIN \194\183 60 DAYS")
    h.tBuy  = cell(tc, 12, -99, 182, "LEFT", T.SIZE.body)
    h.tBuy2 = cell(tc, 12, -114, 182, "LEFT", T.SIZE.small)
    h.tSaleBtn = CreateFrame("Button", nil, tc)
    h.tSaleBtn:SetPoint("TOPLEFT", 10, -46); h.tSaleBtn:SetSize(188, 36)
    h.tSaleBtn:SetFrameLevel(tc:GetFrameLevel() + 5)
    local hl1 = h.tSaleBtn:CreateTexture(nil, "HIGHLIGHT"); hl1:SetAllPoints(); hl1:SetColorTexture(1, 1, 1, 0.05)
    wireItemBtn(h.tSaleBtn)
    h.tBuyBtn = CreateFrame("Button", nil, tc)
    h.tBuyBtn:SetPoint("TOPLEFT", 10, -97); h.tBuyBtn:SetSize(188, 36)
    h.tBuyBtn:SetFrameLevel(tc:GetFrameLevel() + 5)
    local hl2 = h.tBuyBtn:CreateTexture(nil, "HIGHLIGHT"); hl2:SetAllPoints(); hl2:SetColorTexture(1, 1, 1, 0.05)
    wireItemBtn(h.tBuyBtn)
    local lh = T.Text(tc, T.SIZE.tiny, "muted", T.FONT_MED)
    lh:SetPoint("TOPLEFT", 206, -32); lh:SetText("LATEST")
    h.ltRows = homeRows(tc, 206, -48, LT_COLS, 4, 336)
    if T.HelpTip then
      T.HelpTip(tc, "Your trades", {
        "Highlights from your mail-based trade log: the biggest sale you ever booked, the best bargain of the last 60 days (bought furthest under today's Fair) and your latest trades.",
        "Click for the full Trades tab with history, per-item sellability and P/L." }, "ANCHOR_CURSOR")
    end
  end

  refreshClassic = function()
    local h = M.homeClassic
    if not h then return end
    local realm = M.RealmKey()
    local today = M.GetScanDay()

    -- net worth hero ----------------------------------------------------------
    local nw = M.NetWorth and M.NetWorth()
    h.nwTotal:SetText(nw and M.MoneyPlain(nw.total) or "\226\128\148")
    local hist = M.NWHist()
    local dPrevDay, dPrev, d7Day, d7
    for day, s in pairs(hist) do
      if type(s) == "table" and s.t then
        if day < today and (not dPrevDay or day > dPrevDay) then dPrevDay, dPrev = day, s.t end
        if day <= today - 7 and (not d7Day or day > d7Day) then d7Day, d7 = day, s.t end
      end
    end
    local function deltaLine(fs, ref, suffix)
      if not (nw and ref) then fs:SetText(""); return end
      local d = nw.total - ref
      local rgb = (d > 0) and C.green or (d < 0) and C.red or C.sub
      fs:SetText((d >= 0 and "+" or "-") .. M.MoneyPlain(math.abs(d)) .. "  " .. suffix)
      colorize(fs, rgb)
    end
    if dPrev then
      local since = (dPrevDay == today - 1) and "since yesterday" or ("since " .. M.DayLabel(dPrevDay))
      deltaLine(h.nwD1, dPrev, since)
    else
      h.nwD1:SetText("snapshots build up daily"); colorize(h.nwD1, C.muted)
    end
    if d7 and d7Day ~= dPrevDay then deltaLine(h.nwD7, d7, "vs " .. M.DayLabel(d7Day)) else h.nwD7:SetText("") end
    local nChars = 0
    if nw then for _ in pairs(nw.chars or {}) do nChars = nChars + 1 end end
    local subT = nChars .. ((nChars == 1) and " character" or " characters")
    if nw and (nw.graveTotal or 0) > 0 then
      subT = subT .. "   \194\183   graveyard " .. M.MoneyPlain(nw.graveTotal)
    end
    h.nwSub:SetText(subT)
    if M.RenderWorthSpark then M.RenderWorthSpark(h.spark) end

    -- layout: the watchlist row (R2) soaks up ~half of any extra window height,
    -- the bottom row (R3) slides down and keeps the rest
    local r2h = 136 + math.floor(extraH(h.panel) * 0.45)
    h.wCard:SetHeight(r2h)
    local r3y = -(146 + 8 + r2h + 8)
    h.mvCard:ClearAllPoints()
    h.mvCard:SetPoint("TOPLEFT", 0, r3y); h.mvCard:SetPoint("BOTTOMLEFT", 0, 0); h.mvCard:SetWidth(380)
    h.tcCard:ClearAllPoints()
    h.tcCard:SetPoint("TOPLEFT", 388, r3y); h.tcCard:SetPoint("BOTTOMRIGHT", 0, 0)

    -- watchlist ---------------------------------------------------------------
    local wlist = (M.RankWatch and M.RankWatch()) or {}
    local wBuys, wSells = {}, {}
    for _, e in ipairs(wlist) do
      -- an item missing from the newest scan has no current price to signal on
      if e.m and e.m.delta and not (M.NotListed and M.NotListed(e.m)) then
        if e.m.delta < 0 then wBuys[#wBuys + 1] = e
        elseif e.m.delta > 0 then wSells[#wSells + 1] = e end
      end
    end
    table.sort(wBuys, function(a, b) return a.m.delta < b.m.delta end)
    table.sort(wSells, function(a, b) return a.m.delta > b.m.delta end)
    local wEmpty = (#wlist == 0)
    h.wEmpty:SetShown(wEmpty)
    h.wHeadL:SetShown(not wEmpty); h.wHeadR:SetShown(not wEmpty)
    local wN = math.max(4, math.floor((r2h - 56) / HOME_ROWH))
    for r = #h.wBuy + 1, wN do h.wBuy.mk(r) end
    for r = #h.wSell + 1, wN do h.wSell.mk(r) end
    local function fillWatchRow(row, e)
      setItemName(row[1], e.key)
      row[2]:SetText(M.MoneyPlain(e.m.cur)); colorize(row[2], C.text)
      row[3]:SetText(M.MoneyPlain(e.m.fair)); colorize(row[3], C.sub)
      row[4]:SetText(string.format("%+.0f%%", e.m.delta * 100))
      colorize(row[4], C[M.DeltaColor and M.DeltaColor(e.m.delta) or "sub"] or C.sub)
      row.btn.key = e.key
    end
    for r = 1, #h.wBuy do
      local okRow = (r <= wN) and not wEmpty
      if okRow and wBuys[r] then fillWatchRow(h.wBuy[r], wBuys[r]) else clearHomeRow(h.wBuy[r]) end
      if okRow and wSells[r] then fillWatchRow(h.wSell[r], wSells[r]) else clearHomeRow(h.wSell[r]) end
    end
    if not wEmpty then
      if #wBuys == 0 then h.wBuy[1][1]:SetText("nothing under Fair right now"); colorize(h.wBuy[1][1], C.muted) end
      if #wSells == 0 then h.wSell[1][1]:SetText("nothing over Fair right now"); colorize(h.wSell[1][1], C.muted) end
    end
    h.wCount:SetText(wEmpty and "" or (#wlist .. " watched"))

    -- market today: today's picks merged with the best archive-wide flips ------
    local buys, sells, lastPick, pending = M.TopPicks()
    h.mtDay:SetText((lastPick and lastPick >= 0) and ("scan day " .. M.DayLabel(lastPick)) or "")
    local mtBuys, seen = {}, {}
    for _, rec in ipairs(buys) do
      local id = (M.BaseID and M.BaseID(rec.key)) or rec.key
      if not seen[id] then seen[id] = true; mtBuys[#mtBuys + 1] = rec end
    end
    if #mtBuys < #h.mtBuy then
      -- top up with the highest-scoring opportunities that are ALSO a buy signal
      -- on the same scan day (same gate as the picks themselves)
      for _, e in ipairs((M.RankAll and M.RankAll()) or {}) do
        if e.m and (e.m.delta or 0) <= -M.C.PICK_DELTA and lastPick and e.m.lastDay == lastPick then
          local id = (M.BaseID and M.BaseID(e.key)) or e.key
          if not seen[id] then
            seen[id] = true
            mtBuys[#mtBuys + 1] = { key = e.key, delta = e.m.delta }
            if #mtBuys >= #h.mtBuy then break end
          end
        end
      end
    end
    local function fillMT(row, rec)
      setItemName(row[1], rec.key)
      row[2]:SetText(string.format("%+.0f%%", rec.delta * 100))
      colorize(row[2], C[M.DeltaColor and M.DeltaColor(rec.delta) or "sub"] or C.sub)
      row.btn.key = rec.key
    end
    for r = 1, #h.mtBuy do
      if mtBuys[r] then fillMT(h.mtBuy[r], mtBuys[r]) else clearHomeRow(h.mtBuy[r]) end
      if sells[r] then fillMT(h.mtSell[r], sells[r]) else clearHomeRow(h.mtSell[r]) end
    end
    local mtEmpty = pending and "analyzing market data\226\128\166" or "no signals today"
    if #mtBuys == 0 then h.mtBuy[1][1]:SetText(mtEmpty); colorize(h.mtBuy[1][1], C.muted) end
    if #sells == 0 then h.mtSell[1][1]:SetText(mtEmpty); colorize(h.mtSell[1][1], C.muted) end

    -- biggest movers ----------------------------------------------------------
    local movers = {}
    if nw and M.CharDeltaSince then
      for ck, info in pairs(nw.chars or {}) do
        -- direct call: an `x and f()` chain would truncate the (delta, refDay) pair
        local d, refDay = M.CharDeltaSince(ck, info.total)
        if d and d ~= 0 and refDay then movers[#movers + 1] = { ck = ck, name = info.name or ck, d = d, refDay = refDay } end
      end
    end
    table.sort(movers, function(a, b) return math.abs(a.d) > math.abs(b.d) end)
    -- fixed two rows: the card's lower half carries the price alerts
    local mvN = #h.mvRows
    for r = 1, #h.mvRows do
      local e = (r <= mvN) and movers[r] or nil
      local row = h.mvRows[r]
      if e then
        row[1]:SetText(e.name); colorize(row[1], C.text)
        row[2]:SetText((e.d >= 0 and "+" or "-") .. M.MoneyPlain(math.abs(e.d)))
        colorize(row[2], (e.d > 0) and C.green or C.red)
        row[3]:SetText(e.refDay and ("since " .. M.DayLabel(e.refDay)) or ""); colorize(row[3], C.muted)
        row.btn.key = nil
        row.btn.ck = e.ck
      else
        clearHomeRow(row)
      end
    end
    if #movers == 0 then
      h.mvRows[1][1]:SetText(dPrev and "no changes since the last snapshot" or "snapshots build up daily")
      colorize(h.mvRows[1][1], C.muted)
    end

    -- price alerts (lower half of the movers card) -----------------------------
    if h.alRows then
      local al = M.db.alerts and M.db.alerts[realm]
      local alist = {}
      if al then
        for key, a in pairs(al) do
          if type(a) == "table" and (a.below or a.above) then
            alist[#alist + 1] = { key = key, below = a.below, above = a.above }
          end
        end
      end
      table.sort(alist, function(a, b)
        return (M.ItemName(a.key) or tostring(a.key)) < (M.ItemName(b.key) or tostring(b.key))
      end)
      -- the card bottom is elastic (the window resizes for real): grow the
      -- alert rows into whatever height is actually there
      local alN = math.max(2, math.floor((((h.mvCard and h.mvCard:GetHeight()) or 128) - 90) / HOME_ROWH))
      for r = #h.alRows + 1, alN do h.alRows.mk(r) end
      for r = 1, #h.alRows do
        local e, row = (r <= alN) and alist[r] or nil, h.alRows[r]
        if e then
          setItemName(row[1], e.key)
          row[2]:SetText(e.below and ("\226\137\164 " .. M.MoneyPlain(e.below)) or "")
          colorize(row[2], C.green)
          row[3]:SetText(e.above and ("\226\137\165 " .. M.MoneyPlain(e.above)) or "")
          colorize(row[3], C.accent)
          row.btn.key = e.key
        else
          clearHomeRow(row)
        end
      end
      h.alMore:SetText(#alist > alN and ("+" .. (#alist - alN) .. " more") or "")
      if #alist == 0 then
        h.alRows[1][1]:SetText("none set - see Charts")
        colorize(h.alRows[1][1], C.muted)
      end
    end

    -- your trades -------------------------------------------------------------
    local ltN = math.max(4, math.floor((((h.tcCard and h.tcCard:GetHeight()) or 128) - 56) / HOME_ROWH))
    for r = #h.ltRows + 1, ltN do h.ltRows.mk(r) end
    local log = (M.TradeLog and M.TradeLog(realm)) or {}
    local latest, bestSale, bestBuy, bestBuySave = {}, nil, nil, nil
    local cutoff60 = today - 60
    for i = 1, #log do
      local e = log[i]
      if #latest < ltN and (e.kind == "sold" or e.kind == "bought" or e.kind == "returned") then
        latest[#latest + 1] = e
      end
      if e.kind == "sold" and (e.gross or 0) > ((bestSale and bestSale.gross) or 0) then bestSale = e end
      if e.kind == "bought" and e.src ~= "vendor" and e.id and (e.day or 0) >= cutoff60
         and (e.gross or 0) > 0 and (e.count or 0) > 0 then
        local key = tostring(e.id)
        local s = M.GetSeries(key)
        local m = s and M.Metrics(s, key)
        if m and m.fair and m.fair > 0 then
          local save = 1 - (e.gross / e.count) / m.fair
          if save > (bestBuySave or 0.05) then bestBuySave, bestBuy = save, e end
        end
      end
    end
    local function tradeName(e) return (e.id and M.ItemName(tostring(e.id))) or e.name or "?" end
    if bestSale then
      local key = bestSale.id and tostring(bestSale.id)
      setItemName(h.tSale, key, tradeName(bestSale))
      local cnt = (bestSale.count and bestSale.count > 1) and (" x" .. bestSale.count) or ""
      h.tSale2:SetText(M.MoneyPlain(bestSale.gross) .. cnt .. "   \194\183   " .. M.DayLabel(bestSale.day or today))
      colorize(h.tSale2, C.green)
      h.tSaleBtn.key = key
    else
      h.tSale:SetText("no sales logged yet"); colorize(h.tSale, C.muted)
      h.tSale2:SetText("open your mailbox after selling"); colorize(h.tSale2, C.muted)
      h.tSaleBtn.key = nil
    end
    if bestBuy then
      local key = tostring(bestBuy.id)
      setItemName(h.tBuy, key)
      h.tBuy2:SetText(string.format("paid %s \194\183 %.0f%% under Fair",
        M.MoneyPlain(bestBuy.gross / bestBuy.count), bestBuySave * 100))
      colorize(h.tBuy2, C.green)
      h.tBuyBtn.key = key
    else
      h.tBuy:SetText("no AH bargain in the window"); colorize(h.tBuy, C.muted)
      h.tBuy2:SetText(""); h.tBuyBtn.key = nil
    end
    for r = 1, #h.ltRows do
      local e = (r <= ltN) and latest[r] or nil
      local row = h.ltRows[r]
      if e then
        row[1]:SetText(M.DayLabel(e.day or today)); colorize(row[1], C.muted)
        local kind, krgb = "sold", C.green
        if e.kind == "bought" then kind, krgb = "bought", C.red
        elseif e.kind == "returned" then kind, krgb = "back", C.sub end
        row[2]:SetText(kind); colorize(row[2], krgb)
        local key = e.id and tostring(e.id)
        setItemName(row[3], key, tradeName(e))
        if e.kind == "returned" then
          row[4]:SetText("x" .. (e.count or 1)); colorize(row[4], C.sub)
        else
          row[4]:SetText(((e.kind == "sold") and "+" or "-") .. M.MoneyPlain(e.gross or 0))
          colorize(row[4], krgb)
        end
        row.btn.key = key
      else
        clearHomeRow(row)
      end
    end
    if #latest == 0 then
      h.ltRows[1][1]:SetText("\226\128\148"); colorize(h.ltRows[1][1], C.muted)
      h.ltRows[1][3]:SetText("no trades logged yet"); colorize(h.ltRows[1][3], C.muted)
    end
  end
end

local layout   -- card geometry (===== layout below); BuildHome places the cards up front

function M.BuildHome(panel)
  -- two views on the Start tab: the dashboard (cards on root) and the classic
  -- page (its own root); RefreshHome shows one of them
  local root = CreateFrame("Frame", nil, panel); root:SetAllPoints()
  local classicRoot = CreateFrame("Frame", nil, panel); classicRoot:SetAllPoints(); classicRoot:Hide()
  local h = { panel = root, startPanel = panel, root = root, classicRoot = classicRoot, cards = {}, unwatched = {} }
  M.home = h
  -- leaving the tab ends the undo window of the map
  panel:HookScript("OnHide", function() h.unwatched = {} end)
  buildClassic(classicRoot)
  -- the view switch sits in the header row (the chart toggles' place, which
  -- the Start tab does not use) and shows with the Start tab only
  if M.frame then
    local seg = T.Segment(M.frame, { { key = "new", label = "Dashboard" }, { key = "classic", label = "Classic" } },
      function(key)
        if M.db and M.db.config then M.db.config.homeView = (key == "classic") and "classic" or nil end
        -- the whole window: the footer hint belongs to the view
        if M.RefreshUI then M.RefreshUI() else M.RefreshHome() end
      end)
    seg.frame:SetPoint("RIGHT", M.frame, "TOPRIGHT", -14, -62)
    if T.HelpTip then
      for _, b in ipairs(seg.buttons) do
        T.HelpTip(b, "Start page", {
          "Dashboard: net worth and why it moved, your trading, the watchlist map and your next moves.",
          "Classic: the earlier start page - net worth, market today, the watchlist split into buy low / sell high, character movers with price alerts, and your trades.",
          "Midas remembers your choice." })
      end
    end
    seg.frame:SetShown(panel:IsShown())
    panel:HookScript("OnShow", function() seg.frame:Show() end)
    panel:HookScript("OnHide", function() seg.frame:Hide() end)
    h.viewSeg = seg
  end

  -- NET WORTH ---------------------------------------------------------------
  local hero
  hero = newCard(h, "hero", "NET WORTH", "accent", { tab = "Net Worth", go = "net worth", help = HELP.hero,
    helpFn = function()
      local hm = h.model and h.model.hero
      if not hm then return end
      GameTooltip:AddLine(" ")
      tipKV("Characters", tostring(hm.chars))
      if hm.top then tipKV("Biggest change today", hm.top.name .. " " .. signedMoney(hm.top.d, true, true),
        (hm.top.d > 0) and C.green or C.red) end
      if (hm.grave or 0) > 0 then tipKV("Graveyard (not counted)", M.MoneyPlain(hm.grave), C.muted) end
    end })
  h.nwTotal = T.Text(hero, SZ_HERO, "accent", T.FONT_SEMI)
  h.nwTotal:SetPoint("TOPLEFT", PAD, -33)
  h.nwPill1 = newPill(hero); h.nwPill1:SetPoint("TOPLEFT", PAD, -70)
  h.nwPill2 = newPill(hero); h.nwPill2:SetPoint("LEFT", h.nwPill1, "RIGHT", 6, 0)
  h.attr = linkText(hero, SZ_LABEL, "sub")
  h.attr:SetPoint("TOPLEFT", PAD, -96)
  h.attr.btn:SetScript("OnClick", function()
    local hm = h.model and h.model.hero
    if hm and hm.ref and M.Go then M.Go("movers", hm.ref) end
  end)
  h.attr.btn:SetScript("OnEnter", function(self)
    local at = h.model and h.model.hero and h.model.hero.at
    if not at then return end
    tipOpen(self, "What moved it", C.accent)
    tipKV("Market (prices of what you hold)", signedMoney(at.market, false, true), (at.market >= 0) and C.green or C.red)
    tipKV("Stock (bought, sold, used)", signedMoney(at.stock, false, true), (at.stock >= 0) and C.green or C.red)
    tipKV("Gold", signedMoney(at.gold, false, true), (at.gold >= 0) and C.green or C.red)
    if abs(at.residual or 0) >= 1000 then tipKV("Other", signedMoney(at.residual, false, true)) end
    if at.items and #at.items > 0 then
      GameTooltip:AddLine(" ")
      tipLine("Biggest items", C.muted)
      for i = 1, min(3, #at.items) do
        local it = at.items[i]
        local key = tostring(it.id)
        local qc = M.ItemQualityColor(key)
        GameTooltip:AddDoubleLine(M.ItemName(key) or key, signedMoney(it.pnl, true, true), qc.r, qc.g, qc.b,
          (it.pnl >= 0) and C.green[1] or C.red[1], (it.pnl >= 0) and C.green[2] or C.red[2], (it.pnl >= 0) and C.green[3] or C.red[3])
      end
    end
    tipLine("Click: every item that moved", C.muted)
    GameTooltip:Show()
  end)
  h.compBg = hero:CreateTexture(nil, "ARTWORK")
  h.compBg:SetColorTexture(C.bg0[1], C.bg0[2], C.bg0[3], 1)
  h.compSeg, h.compLeg = {}, {}
  h.spark = CreateFrame("Frame", nil, hero)
  h.spark:SetFrameLevel(hero:GetFrameLevel() + 5)
  h.spark._compact = true
  h.spark._fontSize = SZ_LABEL      -- the chart's own labels at the dashboard's floor
  h.spark:SetScript("OnMouseUp", function() M.SelectTab(M.TAB["Net Worth"]) end)

  -- TRADING -----------------------------------------------------------------
  local tr = newCard(h, "trading", "TRADING", "accent", { tab = "Trades", help = HELP.trading })
  h.tr = { rows = {} }
  local function block(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetFrameLevel(parent:GetFrameLevel() + 3)
    b.lbl = T.Text(b, SZ_LABEL, "muted", T.FONT_MED); b.lbl:SetPoint("TOPLEFT", 0, 0)
    b.val = T.Text(b, SZ_VALUE, "text", T.FONT_SEMI); b.val:SetPoint("TOPLEFT", 0, -13)
    b.sub = T.Text(b, SZ_LABEL, "sub"); b.sub:SetPoint("TOPLEFT", 0, -33)
    b:SetScript("OnLeave", tipClose)
    b:SetScript("OnClick", function() M.SelectTab(M.TAB.Trades) end)
    return b
  end
  h.tr.pnl = block(tr)
  h.tr.st = block(tr)
  h.tr.empty = T.Text(tr, SZ_ROW, "muted")
  h.tr.empty:SetWordWrap(true); h.tr.empty:SetJustifyH("LEFT"); h.tr.empty:SetSpacing(3)
  h.tr.empty:SetText("No trades yet - Midas logs them when you collect your auction mail.")
  h.tr.empty:Hide()
  h.tr.barBg = h.tr.st:CreateTexture(nil, "ARTWORK")
  h.tr.barBg:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
  h.tr.bar = h.tr.st:CreateTexture(nil, "OVERLAY")
  h.tr.pnl:SetScript("OnEnter", function(self)
    local mo = h.model
    if not (mo and mo.trading.sm) then return end
    local sm, hm = mo.trading.sm, mo.hero
    tipOpen(self, "Trading, last " .. mo.trading.days .. " days")
    local function amount(v) return (v and v > 0) and M.MoneyPlain(v) or "none" end
    tipKV("Sales after AH cut", amount(sm.grossSells - sm.fees), C.green)
    tipKV("AH buys", amount(sm.buyCost), C.red)
    tipKV("Net P/L", signedMoney(sm.net, false, true))
    if hm.at then
      -- the same window as the net-worth pill: every line adds up exactly
      local at = hm.at
      GameTooltip:AddLine(" ")
      tipLine("How it fits the net-worth change", C.muted)
      tipKV("Net worth", signedMoney(at.dTotal, false, true))
      tipKV("  items", signedMoney(at.dTotal - at.gold, false, true))
      tipKV("    market", signedMoney(at.market, false, true))
      tipKV("    stock", signedMoney(at.stock, false, true))
      tipKV("    other (AH discount, small items)", signedMoney(at.dTotal - at.gold - at.market - at.stock, false, true))
      tipKV("  gold", signedMoney(at.gold, false, true))
      tipKV("    trading", signedMoney(sm.net, false, true))
      tipKV("    outside trading", signedMoney(at.gold - sm.net, false, true))
    end
    if (sm.ownUse or 0) > 0 then tipLine("Vendor buys for own use (" .. M.MoneyPlain(sm.ownUse) .. ") are left out.", C.muted, true) end
    GameTooltip:Show()
  end)
  h.tr.st:SetScript("OnEnter", function(self)
    local s60 = h.model and h.model.trading.s60
    if not s60 then return end
    tipOpen(self, "Sell-through, last " .. h.model.trading.s60days .. " days")
    tipKV("Sold", tostring(s60.sold), C.green)
    tipKV("Came back", tostring(s60.ret), C.red)
    tipLine("Low sell-through is usually oversupply, not price: post fewer at a time.", C.muted, true)
    GameTooltip:Show()
  end)

  -- WATCHLIST MAP -------------------------------------------------------------
  local map = newCard(h, "map", "WATCHLIST", "accent", { tab = "Watchlist", help = HELP.map })
  h.map = { tiles = {}, leg = {} }
  for i = 1, 5 do
    local sw = map:CreateTexture(nil, "ARTWORK")
    sw:SetSize(12, 6)
    h.map.leg[i] = sw
  end
  h.map.legL = T.Text(map, SZ_LABEL, "muted"); h.map.legL:SetText("under Fair")
  h.map.legR = T.Text(map, SZ_LABEL, "muted"); h.map.legR:SetText("over")
  h.map.legDot = map:CreateTexture(nil, "ARTWORK"); h.map.legDot:SetTexture(CIRCLE)
  h.map.legDot:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 1); h.map.legDot:SetSize(7, 7)
  h.map.legSell = T.Text(map, SZ_LABEL, "muted"); h.map.legSell:SetText("to sell")
  h.map.empty = T.Text(map, SZ_ROW, "sub")
  h.map.empty:SetWordWrap(true); h.map.empty:SetJustifyH("CENTER"); h.map.empty:SetSpacing(4)
  h.map.empty:SetText("Your watchlist is empty. Right-click any item in Midas to watch it - this map then tints every watched item by its price against Fair.")
  h.map.empty:Hide()

  -- NEXT MOVES ----------------------------------------------------------------
  local moves = newCard(h, "moves", "NEXT MOVES", "accent", { help = HELP.moves })
  h.mv = { rows = {}, chips = {} }
  h.mv.empty = T.Text(moves, SZ_ROW, "sub")
  h.mv.empty:SetWordWrap(true); h.mv.empty:SetJustifyH("LEFT"); h.mv.empty:SetSpacing(3)

  -- the cards stand in place from the first frame - the fill follows one frame
  -- later - and their loading layers cover them until it lands (Loading.lua)
  local classic = (M.db and M.db.config and M.db.config.homeView == "classic") and true or false
  root:SetShown(not classic); classicRoot:SetShown(classic)
  layout(h)
  if M.HomeLoadingInit then M.HomeLoadingInit(h) end
end

-- ===== layout =================================================================
-- the content panel as the window defines it (14px insets, 92 top, 42 bottom)
local function dims()
  local f = M.frame
  local W = (f and f:GetWidth()) or 980
  local Hh = (f and f:GetHeight()) or 560
  return max(BASE_W, floor(W - 28 + 0.5)), max(BASE_H, floor(Hh - 134 + 0.5))
end

layout = function(h)
  local W, Hh = dims()
  if h._lw == W and h._lh == Hh then return end
  h._lw, h._lh = W, Hh
  local col = (W - 11 * GUT) / 12
  local function cx(i) return floor(i * (col + GUT) + 0.5) end
  local function cw(i, n) return floor((i + n) * (col + GUT) - GUT + 0.5) - cx(i) end
  local ex = Hh - BASE_H
  local r1 = 150 + floor(ex * 0.25)
  local r2 = Hh - r1 - GUT
  local c = h.cards
  place(c.hero, cx(0), 0, cw(0, 8), r1)
  place(c.trading, cx(8), 0, cw(8, 4), r1)
  place(c.map, cx(0), r1 + GUT, cw(0, 8), r2)
  place(c.moves, cx(8), r1 + GUT, cw(8, 4), r2)
  h.geo = { heroW = cw(0, 8), r1 = r1, trW = cw(8, 4), mapW = cw(0, 8), r2 = r2, mvW = cw(8, 4) }
  local g = h.geo

  -- hero: number, pills, why-line and composition on the left, chart right
  local lw = max(268, floor(g.heroW * 0.42))
  h.compW = lw - PAD
  h.compBg:ClearAllPoints(); h.compBg:SetPoint("TOPLEFT", PAD, -118); h.compBg:SetSize(h.compW, 6)
  h.attr:SetWidth(h.compW)
  h.attr:SetJustifyH("LEFT")
  local chartX = lw + PAD + 8
  place(h.spark, chartX, HEAD, g.heroW - chartX - PAD, g.r1 - HEAD - 12)

  -- trading: two figures side by side, trades below
  local half = floor((g.trW - 2 * PAD) / 2)
  place(h.tr.pnl, PAD, 32, half - 6, 46)
  place(h.tr.st, PAD + half + 6, 32, half - 6, 46)
  h.tr.barBg:ClearAllPoints(); h.tr.barBg:SetPoint("TOPLEFT", h.tr.st, "TOPLEFT", 50, -20); h.tr.barBg:SetSize(half - 6 - 50, 4)
end

-- ===== refresh: hero ==========================================================
local LEG_LABEL = { Money = "Gold", Auctions = "On AH" }

local function refreshHero(h, mo)
  local hm = mo.hero
  local total = hm.total
  if total > 0 then
    h.nwTotal:SetText(M.MoneyPlain(total)); colorize(h.nwTotal, C.accent)
  else
    h.nwTotal:SetText(MINUS); colorize(h.nwTotal, C.muted)
  end
  local function pill(p, ref, label)
    if not (ref and total > 0) then p:Hide(); return 0 end
    local d = total - ref
    local rgb = (d > 0) and C.green or (d < 0) and C.red or C.sub
    local txt = label .. "  " .. signedMoney(d, true)
    if ref > 0 and abs(d / ref) >= 0.005 then txt = txt .. "  " .. pct(d / ref) end
    p:Show()
    return p:Set(txt, rgb)
  end
  local today = mo.today
  local n1 = pill(h.nwPill1, hm.prev,
    (hm.prevDay == today - 1) and "today" or ("since " .. (hm.prevDay and M.DayLabel(hm.prevDay) or "")))
  local span = hm.ref and (today - hm.ref) or 7
  if hm.refT and hm.prevDay and hm.ref < hm.prevDay then pill(h.nwPill2, hm.refT, span .. " days") else h.nwPill2:Hide() end
  if n1 == 0 then
    h.nwPill2:Hide()
    if total > 0 then h.nwPill1:Show(); h.nwPill1:Set("first snapshot today", C.sub, nil, 0.08) end
  end

  -- why it moved
  local at = hm.at
  if at then
    local function part(label, v)
      local rgb = (v > 0) and C.green or (v < 0) and C.red or C.sub
      return label .. " " .. hex(rgb) .. signedMoney(v, true) .. "|r"
    end
    local parts = { part("market", at.market), part("stock", at.stock), part("gold", at.gold) }
    local tailTxt = ""
    if abs(at.residual or 0) >= 1000 and abs(at.residual) >= 0.05 * max(1, abs(at.dTotal)) then
      parts[#parts + 1] = part("other", at.residual)
    end
    h.attr:SetText(table.concat(parts, " \194\183 ") .. tailTxt)
    -- "other" is the first to go when the line runs out of room (the hover has it)
    if #parts == 4 and h.attr:GetStringWidth() > h.compW then
      parts[4] = nil
      h.attr:SetText(table.concat(parts, " \194\183 ") .. tailTxt)
    end
    h.attr:Show(); h.attr.btn:Show()
  else
    h.attr:SetText(""); h.attr.btn:Hide()
  end

  -- composition: always gold and the AH, plus the biggest other class
  local nw = mo.nw
  local cls = (nw and nw.classes) or {}
  local cc = M.CLASS_COLOR or {}
  local segs, x = {}, 0
  for _, name in ipairs(M.ASSET_ORDER or { "Money" }) do
    local v = cls[name] or 0
    if v > 0 and total > 0 then segs[#segs + 1] = { name = name, v = v } end
  end
  for i, s in ipairs(segs) do
    local t = h.compSeg[i]
    if not t then t = h.cards.hero:CreateTexture(nil, "OVERLAY"); h.compSeg[i] = t end
    local w = (i == #segs) and (h.compW - x) or floor(h.compW * s.v / total + 0.5)
    w = max(0, min(w, h.compW - x))
    local rgb = C[cc[s.name] or "muted"] or C.muted
    t:SetColorTexture(rgb[1], rgb[2], rgb[3], 0.95)
    t:ClearAllPoints(); t:SetPoint("TOPLEFT", h.compBg, "TOPLEFT", x, 0); t:SetSize(max(1, w), 6)
    t:SetShown(w >= 1)
    x = x + w
  end
  for i = #segs + 1, #h.compSeg do h.compSeg[i]:Hide() end
  h.compBg:SetShown(#segs > 0)
  -- the biggest other class first, then gold and the AH (what is left out
  -- for room is in the bar and the Net Worth tab)
  local leg = {}
  local best
  for _, s in ipairs(segs) do
    if s.name ~= "Money" and s.name ~= "Auctions" and (not best or s.v > best.v) then best = s end
  end
  if best then leg[#leg + 1] = best end
  if (cls.Money or 0) > 0 then leg[#leg + 1] = { name = "Money", v = cls.Money } end
  if (cls.Auctions or 0) > 0 then leg[#leg + 1] = { name = "Auctions", v = cls.Auctions } end
  local lx = 0
  for i = 1, 3 do
    local L = h.compLeg[i]
    if not L then
      L = { sw = h.cards.hero:CreateTexture(nil, "ARTWORK"), fs = T.Text(h.cards.hero, SZ_LABEL, "sub") }
      L.sw:SetSize(6, 6)
      h.compLeg[i] = L
    end
    local s = leg[i]
    local shown = false
    if s then
      local rgb = C[cc[s.name] or "muted"] or C.muted
      L.sw:SetColorTexture(rgb[1], rgb[2], rgb[3], 1)
      local extra = ""
      if s.name == "Money" and (hm.mail or 0) >= 10000 then
        extra = " " .. hex(C.muted) .. "(" .. short(hm.mail) .. " in mail)|r"
      end
      L.fs:SetText((LEG_LABEL[s.name] or s.name) .. " " .. hex(C.text) .. short(s.v) .. "|r" .. extra)
      local w = 10 + L.fs:GetStringWidth()
      if lx + w <= h.compW then
        L.sw:ClearAllPoints(); L.sw:SetPoint("TOPLEFT", h.compBg, "BOTTOMLEFT", lx, -9)
        L.fs:ClearAllPoints(); L.fs:SetPoint("LEFT", L.sw, "RIGHT", 4, 0)
        lx = lx + w + 12
        shown = true
      end
    end
    L.sw:SetShown(shown); L.fs:SetShown(shown)
  end
  if M.RenderWorthSpark then M.RenderWorthSpark(h.spark) end
  local d0, d1 = h.spark._d0, h.spark._d1
  h.cards.hero.ctx:SetText((d0 and d1 and d1 > d0) and ("chart " .. (d1 - d0 + 1) .. " days") or "")
end

-- ===== refresh: trading =======================================================
local KINDV = { sold = { "sold", "green" }, bought = { "bought", "red" }, returned = { "back", "sub" } }

local function trRow(h, i)
  local r = h.tr.rows[i]
  if r then return r end
  local card = h.cards.trading
  r = CreateFrame("Button", nil, card)
  r:SetFrameLevel(card:GetFrameLevel() + 4)
  r.date = T.Text(r, SZ_ROW, "muted"); r.date:SetPoint("LEFT", 0, 0)
  r.pill = newPill(r); r.pill:SetPoint("LEFT", 44, 0)
  r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(14, 14); r.icon:SetPoint("LEFT", 96, 0)
  r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  r.val = T.Text(r, SZ_ROW, "text", T.FONT_MED); r.val:SetPoint("RIGHT", 0, 0); r.val:SetJustifyH("RIGHT")
  r.val:SetWidth(56)
  -- the count has its own field: a long name gets cut, the count never
  r.cnt = T.Text(r, SZ_ROW, "muted"); r.cnt:SetPoint("RIGHT", r.val, "LEFT", -6, 0); r.cnt:SetJustifyH("RIGHT")
  r.name = T.Text(r, SZ_ROW, "text")
  r.name:SetPoint("LEFT", r.icon, "RIGHT", 5, 0); r.name:SetPoint("RIGHT", r.cnt, "LEFT", -4, 0)
  r.name:SetJustifyH("LEFT")
  wireItem(r)
  h.tr.rows[i] = r
  return r
end

local function refreshTrading(h, mo)
  local g = h.geo
  local td = mo.trading
  local sm = td.sm
  local p = h.tr.pnl
  p.lbl:SetText("NET P/L \194\183 " .. td.days .. "D")
  if sm and (sm.sold + sm.bought) > 0 then
    p.val:SetText(signedMoney(sm.net, true)); colorize(p.val, (sm.net > 0) and C.green or (sm.net < 0) and C.red or C.sub)
    p.sub:SetText(sm.sold .. " sold" .. DOT .. sm.bought .. " bought")
  else
    p.val:SetText(MINUS); colorize(p.val, C.muted)
    p.sub:SetText("no trades in the window")
  end
  local s = h.tr.st
  s.lbl:SetText("SELL-THROUGH \194\183 " .. td.s60days .. "D")
  if td.rate then
    local rgb = (td.rate >= 0.6) and C.green or (td.rate >= 0.35) and C.accent or C.red
    s.val:SetText(string.format("%.0f%%", td.rate * 100)); colorize(s.val, rgb)
    s.sub:SetText(td.s60.sold .. " sold" .. DOT .. td.s60.ret .. " back")
    local bw = h.tr.barBg:GetWidth()
    h.tr.barBg:Show(); h.tr.bar:Show()
    h.tr.bar:ClearAllPoints(); h.tr.bar:SetPoint("TOPLEFT", h.tr.barBg, "TOPLEFT", 0, 0)
    h.tr.bar:SetSize(max(1, floor(bw * min(1, td.rate) + 0.5)), 4)
    h.tr.bar:SetColorTexture(rgb[1], rgb[2], rgb[3], 1)
  else
    s.val:SetText(MINUS); colorize(s.val, C.muted)
    s.sub:SetText("too few auctions yet")
    h.tr.barBg:Hide(); h.tr.bar:Hide()
  end
  -- latest trades
  local nRows = max(1, floor((g.r1 - 84 - 6) / 19))
  local list = td.trades
  local rowW = g.trW - 2 * PAD
  for i = 1, max(nRows, #h.tr.rows) do
    local e = (i <= nRows) and list[i] or nil
    if i <= nRows then
      local r = trRow(h, i)
      place(r, PAD, 84 + (i - 1) * 19, rowW, 18)
      -- a narrow card gives the item name the room of the date column
      local showDate = rowW >= 330
      r.pill:ClearAllPoints(); r.pill:SetPoint("LEFT", showDate and 44 or 0, 0)
      r.icon:ClearAllPoints(); r.icon:SetPoint("LEFT", showDate and 96 or 52, 0)
      if e then
        local k = KINDV[e.kind]
        r.date:SetText(M.DayLabel(e.day or mo.today)); r.date:SetShown(showDate)
        r.pill:Set(k[1], C[k[2]], 46); r.pill:Show()
        local key = e.id and tostring(e.id) or nil
        r.icon:SetTexture(key and itemIcon(key) or QMARK); r.icon:Show()
        setName(r.name, key, e.name)
        r.cnt:SetText(((e.count or 1) > 1) and ("\195\151" .. e.count) or "")
        if e.kind == "returned" then r.val:SetText("")
        else
          r.val:SetText(((e.kind == "sold") and "+" or MINUS) .. short(e.amt)); colorize(r.val, C[k[2]])
        end
        r.key = key
        r:Show()
      else
        r:Hide(); r.key = nil
      end
    elseif h.tr.rows[i] then
      h.tr.rows[i]:Hide(); h.tr.rows[i].key = nil
    end
  end
  h.tr.empty:ClearAllPoints()
  h.tr.empty:SetPoint("TOPLEFT", h.cards.trading, "TOPLEFT", PAD, -86); h.tr.empty:SetWidth(rowW)
  h.tr.empty:SetShown(#list == 0)
end

-- ===== refresh: watchlist map =================================================
local TILE_W, TILE_H, TGAP = 44, 50, 4

-- fill colour + alpha and the label colour of one tile
local function tileLook(it)
  local pd = pickD()
  if it.unwatched then return C.bg2, 0.45, C.muted end
  if not it.d then return C.bg2, 0.55, C.muted end
  local a = abs(it.d)
  if a < pd then return mix(C.bg2, C.sub, 0.08), 1, C.sub end
  if it.d < 0 then return mix(C.bg2, C.green, 0.24 + 0.46 * min(1, (a - pd) / 0.40)), 1, C.text end
  -- over Fair: one tint per distance for every tile (the same +35% must look
  -- the same); what you own and could sell carries the gold dot instead
  return mix(C.bg2, C.red, 0.14 + 0.28 * min(1, (a - pd) / 0.60)), 1, C.text
end

local function mapTip(self)
  local it = self.item
  if not it then return end
  local h = M.home
  -- the full tooltip (Midas lines + price chart): a tile shows only a percent
  if M.ShowItemTip then M.ShowItemTip(it.key, true) end
  -- the card header reads the hovered item, names without the tooltip
  local card = h.cards.map
  local qc = M.ItemQualityColor(it.key)
  local nm = string.format("|cff%02x%02x%02x%s|r", floor(qc.r * 255), floor(qc.g * 255), floor(qc.b * 255), M.ItemName(it.key) or "?")
  -- numbers first: a long name is what gets cut
  local s
  if it.unwatched then s = "removed - click to undo" .. DOT .. nm
  elseif it.m and it.m.cur and it.m.fair and it.d then
    local rgb = (abs(it.d) < pickD()) and C.sub or ((it.d < 0) and C.green or C.red)
    s = hex(rgb) .. pct(it.d, false, false, true) .. "|r" .. DOT .. "now " .. short(it.m.cur) .. DOT .. "Fair "
      .. short(it.m.fair) .. DOT .. nm
  else s = "not in the newest scan" .. DOT .. nm end
  card.ctx:SetText(s)
  h.map.hovering = true
end
local function mapLeave()
  local h = M.home
  if h and h.map.hovering then
    h.map.hovering = nil
    h.cards.map.ctx:SetText(h.map.ctxText or "")
  end
end

local function mapTile(h, i)
  local tl = h.map.tiles[i]
  if tl then return tl end
  local card = h.cards.map
  tl = CreateFrame("Button", nil, card)
  tl:SetFrameLevel(card:GetFrameLevel() + 4)
  tl.bg = tl:CreateTexture(nil, "BACKGROUND"); tl.bg:SetAllPoints()
  tl.rim = tl:CreateTexture(nil, "BORDER")
  tl.icon = tl:CreateTexture(nil, "ARTWORK")
  tl.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  tl.fs = T.Text(tl, SZ_LABEL, "text", T.FONT_SEMI)
  tl.fs:SetPoint("BOTTOM", 0, 5); tl.fs:SetJustifyH("CENTER")
  tl.more = T.Text(tl, SZ_ROW, "sub", T.FONT_SEMI); tl.more:SetPoint("CENTER", 0, 5)
  tl.cap = T.Text(tl, SZ_LABEL, "muted"); tl.cap:SetPoint("BOTTOM", 0, 5)
  -- the gold dot: you hold this and it trades well over Fair (= SELL)
  tl.dotBg = tl:CreateTexture(nil, "OVERLAY", nil, 1); tl.dotBg:SetTexture(CIRCLE)
  tl.dotBg:SetVertexColor(C.bg0[1], C.bg0[2], C.bg0[3], 1); tl.dotBg:SetSize(10, 10); tl.dotBg:SetPoint("TOPRIGHT", -1, -1)
  tl.dot = tl:CreateTexture(nil, "OVERLAY", nil, 2); tl.dot:SetTexture(CIRCLE)
  tl.dot:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 1); tl.dot:SetSize(6, 6); tl.dot:SetPoint("CENTER", tl.dotBg, "CENTER", 0, 0)
  wireItem(tl, mapTip)
  tl.onLeave = mapLeave
  h.map.tiles[i] = tl
  return tl
end

local function tileClick(self, mouse)
  local it = self.item
  if it and it.unwatched then
    -- undo: the item goes back on the watchlist, in the same place
    M.ToggleWatch(it.key)
    M.home.unwatched[it.key] = nil
    M.RefreshHome()
    return
  end
  if it and mouse == "RightButton" and not (M.ModPostDown and M.ModPostDown()) and not (M.ModSearchDown and M.ModSearchDown()) then
    M.ToggleWatch(it.key)
    M.home.unwatched[it.key] = true
    if M.HideTip then M.HideTip() end
    M.RefreshHome()
    return
  end
  itemClick(self, mouse)
end

local function refreshMap(h, mo)
  local g = h.geo
  local card = h.cards.map
  local mp = mo.map
  local items = {}
  for i, it in ipairs(mp.items) do items[i] = it end
  local n = #items
  local ctx
  if n == 0 then ctx = ""
  elseif mo.moves.noScan then ctx = n .. " items" .. DOT .. "no prices yet - scan the AH"
  elseif mo.moves.stale then
    ctx = hex(C.red) .. "scan " .. mo.moves.stale .. " days old|r" .. DOT .. hex(C.green) .. mp.cheap .. " cheap|r"
      .. DOT .. hex(C.accent) .. mp.toSell .. " to sell|r"
  else
    ctx = n .. " items" .. DOT .. hex(C.green) .. mp.cheap .. " cheap|r" .. DOT .. hex(C.accent) .. mp.toSell .. " to sell|r"
    if mp.notListed > 0 then ctx = ctx .. DOT .. mp.notListed .. " not listed" end
  end
  -- legend: under Fair .. over Fair on something you own
  local stops = { -0.55, -0.30, 0, 0.30, 0.55 }
  h.map.legSell:ClearAllPoints(); h.map.legSell:SetPoint("RIGHT", card, "TOPRIGHT", -(PAD + 80), -16)
  h.map.legDot:ClearAllPoints(); h.map.legDot:SetPoint("RIGHT", h.map.legSell, "LEFT", -4, 0)
  h.map.legR:ClearAllPoints(); h.map.legR:SetPoint("RIGHT", h.map.legDot, "LEFT", -12, 0)
  h.map.legDot:SetShown(n > 0); h.map.legSell:SetShown(n > 0)
  for i = 5, 1, -1 do
    local sw = h.map.leg[i]
    local rgb = tileLook({ d = stops[i] })
    sw:SetColorTexture(rgb[1], rgb[2], rgb[3], 1)
    sw:ClearAllPoints()
    if i == 5 then sw:SetPoint("RIGHT", h.map.legR, "LEFT", -5, 0)
    else sw:SetPoint("RIGHT", h.map.leg[i + 1], "LEFT", -1, 0) end
    sw:SetShown(n > 0)
  end
  h.map.legL:ClearAllPoints(); h.map.legL:SetPoint("RIGHT", h.map.leg[1], "LEFT", -5, 0)
  h.map.legL:SetShown(n > 0); h.map.legR:SetShown(n > 0)
  -- the context stops short of the legend
  local legLeft = g.mapW - (PAD + 80) - h.map.legSell:GetStringWidth() - 4 - 7 - 12 - h.map.legR:GetStringWidth()
    - 5 - 5 * 13 - 5 - h.map.legL:GetStringWidth()
  local ctxMax = legLeft - (PAD + 12 + card.title:GetStringWidth() + 10) - 12
  card.ctx:SetText(ctx)
  if card.ctx:GetStringWidth() > ctxMax then
    ctx = hex(C.green) .. mp.cheap .. " cheap|r" .. DOT .. hex(C.accent) .. mp.toSell .. " to sell|r"
    if mo.moves.stale then ctx = hex(C.red) .. "scan " .. mo.moves.stale .. " days old|r" .. DOT .. ctx
    else ctx = n .. " items" .. DOT .. ctx end
    card.ctx:SetText(ctx)
  end
  card.ctx:SetWidth(max(40, ctxMax))
  card.ctx:SetJustifyH("LEFT")
  h.map.ctxText = ctx

  -- grid: tiles grow (up to 1.45x) while everything still fits
  local aw = g.mapW - 2 * PAD
  local ah = g.r2 - HEAD - 8
  local s, cols, rows = 1, 1, 1
  for _, sc in ipairs({ 1.45, 1.35, 1.25, 1.15, 1.05, 1 }) do
    cols = max(1, floor((aw + TGAP) / (TILE_W * sc + TGAP)))
    rows = max(1, floor((ah + TGAP) / (TILE_H * sc + TGAP)))
    s = sc
    if cols * rows >= n then break end
  end
  local tw = floor((aw - (cols - 1) * TGAP) / cols)
  local th = floor(TILE_H * s)
  local cap = cols * rows
  -- too many: keep the strongest signals of both ends (>= 3 a side when
  -- there are), collapse the rest into "+N more" and "+N not listed" tiles
  local tail = {}
  if n > cap then
    local listedI, unl = {}, {}
    for _, it in ipairs(items) do if it.d or it.unwatched then listedI[#listedI + 1] = it else unl[#unl + 1] = it end end
    -- a stable pick of the unlisted ones (the watchlist comes in pairs() order)
    table.sort(unl, function(a, b)
      local an, bn = tostring(M.ItemName(a.key)), tostring(M.ItemName(b.key))
      if an ~= bn then return an < bn end
      return a.key < b.key
    end)
    local slots = cap - ((#unl > 0) and 1 or 0) - 1
    local pd = pickD()
    local function strength(it) return it.unwatched and 9 or (it.d and abs(it.d) or 0) end
    local lo, hi = {}, {}
    for _, it in ipairs(listedI) do
      if it.d and it.d <= -pd then lo[#lo + 1] = it elseif it.d and it.d >= pd then hi[#hi + 1] = it end
    end
    table.sort(lo, function(a, b)
      if a.d ~= b.d then return a.d < b.d end
      return a.key < b.key
    end)
    table.sort(hi, function(a, b)
      if a.owned ~= b.owned then return a.owned and true or false end
      if a.d ~= b.d then return a.d > b.d end
      return a.key < b.key
    end)
    local keep, kept = {}, 0
    for i = 1, min(3, #lo) do keep[lo[i]] = true; kept = kept + 1 end
    for i = 1, min(3, #hi) do keep[hi[i]] = true; kept = kept + 1 end
    table.sort(listedI, function(a, b)
      if strength(a) ~= strength(b) then return strength(a) > strength(b) end
      return a.key < b.key
    end)
    for _, it in ipairs(listedI) do
      if kept >= slots then break end
      if not keep[it] then keep[it] = true; kept = kept + 1 end
    end
    local sel, more = {}, 0
    for _, it in ipairs(items) do
      if keep[it] then sel[#sel + 1] = it elseif it.d or it.unwatched then more = more + 1 end
    end
    -- room left (few priced items, e.g. before the first scan): show unlisted
    -- items as dimmed icons too, only the rest goes into the collector
    local free = cap - #sel - ((more > 0) and 1 or 0)
    local unlLeft = #unl
    if unlLeft > free then free = free - 1 end
    for i = 1, min(free, #unl) do sel[#sel + 1] = unl[i]; unlLeft = unlLeft - 1 end
    items = sel
    if more > 0 then tail[#tail + 1] = { more = more, cap = "more", tab = true } end
    if unlLeft > 0 then tail[#tail + 1] = { more = unlLeft, cap = "not listed", tab = true } end
  end
  table.sort(items, function(a, b)
    local ad, bd = a.d, b.d
    if (ad ~= nil) ~= (bd ~= nil) then return ad ~= nil end
    if ad and bd and ad ~= bd then return ad < bd end
    local an, bn = tostring(M.ItemName(a.key)), tostring(M.ItemName(b.key))
    if an ~= bn then return an < bn end
    return a.key < b.key
  end)
  for _, t in ipairs(tail) do items[#items + 1] = t end
  local iconS = floor(26 * s + 0.5)
  local shown = #items
  for i = 1, max(shown, #h.map.tiles) do
    local it = items[i]
    if it then
      local tl = mapTile(h, i)
      place(tl, PAD + ((i - 1) % cols) * (tw + TGAP), HEAD + floor((i - 1) / cols) * (th + TGAP), tw, th)
      if it.more then
        tl.bg:SetColorTexture(C.bg2[1], C.bg2[2], C.bg2[3], 0.8)
        tl.rim:Hide(); tl.icon:Hide(); tl.fs:Hide(); tl.dot:Hide(); tl.dotBg:Hide()
        tl.more:SetText("+" .. it.more); tl.more:Show()
        tl.cap:SetText(it.cap); tl.cap:Show()
        tl.key, tl.item = nil, nil
        tl:SetAlpha(1)
        tl:SetScript("OnClick", function() M.SelectTab(M.TAB.Watchlist) end)
      else
        local bg, ba, lc = tileLook(it)
        tl.bg:SetColorTexture(bg[1], bg[2], bg[3], ba)
        local qc = M.ItemQualityColor(it.key)
        tl.rim:SetColorTexture(qc.r, qc.g, qc.b, (it.d and not it.unwatched) and 0.85 or 0.30)
        tl.rim:ClearAllPoints(); tl.rim:SetPoint("TOP", 0, -4); tl.rim:SetSize(iconS + 2, iconS + 2)
        tl.icon:ClearAllPoints(); tl.icon:SetPoint("TOP", 0, -5); tl.icon:SetSize(iconS, iconS)
        tl.icon:SetTexture(itemIcon(it.key))
        tl.icon:SetVertexColor(1, 1, 1, (it.d and not it.unwatched) and 1 or 0.4)
        tl.icon:Show(); tl.rim:Show()
        if it.unwatched then tl.fs:SetText("undo")
        elseif it.d then tl.fs:SetText(pct(it.d, false, false, true))
        else tl.fs:SetText(MINUS) end
        local dot = it.owned and not it.unwatched and it.d ~= nil
        tl.dot:SetShown(dot); tl.dotBg:SetShown(dot)
        colorize(tl.fs, lc)
        tl.fs:Show(); tl.more:Hide(); tl.cap:Hide()
        tl.key, tl.item = it.key, it
        tl:SetAlpha(mo.moves.stale and 0.55 or 1)
        tl:SetScript("OnClick", tileClick)
      end
      tl:Show()
    elseif h.map.tiles[i] then
      h.map.tiles[i]:Hide(); h.map.tiles[i].key, h.map.tiles[i].item = nil, nil
    end
  end
  h.map.empty:ClearAllPoints()
  h.map.empty:SetPoint("TOPLEFT", card, "TOPLEFT", 40, -(HEAD + 24)); h.map.empty:SetWidth(g.mapW - 80)
  h.map.empty:SetShown(n == 0)
end

-- ===== refresh: next moves ====================================================
local VERB = { sell = { "SELL", "red" }, buy = { "BUY", "green" }, undercut = { "UNDERCUT", "purple" },
               alert = { "ALERT", "accent" } }
local MV_ROWH = 32

local function moveTip(self)
  local e = self.move
  if not e then return end
  local qc = M.ItemQualityColor(e.key)
  tipOpen(self, M.ItemName(e.key) or e.key, { qc.r, qc.g, qc.b })
  if e.kind == "sell" then
    tipKV("You hold", tostring(e.qty))
    local who = {}
    for name, q in pairs(e.who or {}) do who[#who + 1] = name .. " " .. q end
    table.sort(who)
    if #who > 0 then tipLine(table.concat(who, ", "), C.muted, true) end
    tipKV("Now / Fair", M.MoneyPlain(e.m.cur) .. " / " .. M.MoneyPlain(e.m.fair))
    tipKV("List at or under", M.MoneyPlain(e.ask), C.accent)
    if e.m.liqLabel then tipKV("Moves", e.m.liqLabel) end
    tipLine("Asks far above Fair rarely sell; at most 15% over Fair keeps the odds up. Post what the market takes per day.", C.muted, true)
  elseif e.kind == "buy" then
    tipKV("Now / Fair", M.MoneyPlain(e.m.cur) .. " / " .. M.MoneyPlain(e.m.fair))
    tipKV("Margin per unit (after cut)", M.MoneyPlain(e.unit), C.green)
    if e.m.liqLabel then tipKV("Moves", e.m.liqLabel) end
    if e.new then tipLine("Not on your watchlist yet - right-click to add it.", C.muted, true) end
  elseif e.kind == "undercut" then
    tipKV("Your ask", M.MoneyPlain(e.ask))
    tipKV("Cheapest now", M.MoneyPlain(e.cur), C.red)
    tipKV("Listing of", e.who .. string.format(" (as of %.0fh ago)", e.seenH))
    tipLine("Cancel and repost at or under the new price, or wait it out if it sells slowly anyway.", C.muted, true)
  else
    tipKV("Limit", ((e.side == "below") and "below " or "above ") .. M.MoneyPlain(e.limit or 0))
    tipKV("Now", e.cur and M.MoneyPlain(e.cur) or "not in the newest scan")
    if e.hit then tipLine("Fired " .. date("%b %d %H:%M", e.ts) .. ".", C.accent)
    elseif e.past then tipLine("Fired earlier and still past the limit.", C.sub)
    elseif e.dist then tipLine(string.format("%.0f%% away from the limit.", e.dist * 100), C.sub) end
  end
  tipLine("Click: chart    Right-click: watch / unwatch", C.muted)
  GameTooltip:Show()
end

local function moveRow(h, i)
  local r = h.mv.rows[i]
  if r then return r end
  local card = h.cards.moves
  r = CreateFrame("Button", nil, card)
  r:SetFrameLevel(card:GetFrameLevel() + 4)
  r.pill = newPill(r); r.pill:SetPoint("TOPLEFT", 0, -1)
  r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(16, 16); r.icon:SetPoint("TOPLEFT", 64, -1)
  r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  r.val = T.Text(r, SZ_ROW, "text", T.FONT_MED); r.val:SetPoint("TOPRIGHT", 0, -3); r.val:SetJustifyH("RIGHT")
  -- both anchors on the top edge: the height stays the text's own
  r.name = T.Text(r, SZ_ROW, "text")
  r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 6, -2); r.name:SetPoint("TOPRIGHT", r.val, "TOPLEFT", -8, 0)
  r.name:SetJustifyH("LEFT")
  r.why = T.Text(r, SZ_LABEL, "muted")
  r.why:SetPoint("TOPLEFT", 64, -19); r.why:SetPoint("TOPRIGHT", 0, -19); r.why:SetJustifyH("LEFT")
  wireItem(r, moveTip)
  h.mv.rows[i] = r
  return r
end

local function chip(h, i)
  local c = h.mv.chips[i]
  if c then return c end
  c = linkText(h.cards.moves, SZ_LABEL, "muted")
  h.mv.chips[i] = c
  return c
end

local function refreshMoves(h, mo)
  local g = h.geo
  local card = h.cards.moves
  local mv = mo.moves
  local rowW = g.mvW - 2 * PAD
  local stale = mv.stale
  for i = 1, max(#mv.list, #h.mv.rows) do
    local e = mv.list[i]
    if e then
      local r = moveRow(h, i)
      place(r, PAD, HEAD + (i - 1) * MV_ROWH, rowW, MV_ROWH - 2)
      local v = VERB[e.kind]
      r.pill:Set(v[1], C[v[2]], 58)
      r.icon:SetTexture(itemIcon(e.key))
      setName(r.name, e.key)
      local why, val, vrgb = "", "", C.text
      if e.kind == "sell" then
        val, vrgb = LEQ .. " " .. short(e.ask), C.accent
        why = e.qty .. " held" .. DOT .. pct(e.prem, false, true, true) .. " over Fair"
      elseif e.kind == "buy" then
        val, vrgb = "+" .. short(e.unit) .. " ea", C.green
        why = pct(e.m.delta, false, true, true) .. " under Fair"
        if e.m.liqLabel == "Slow" or e.m.liqLabel == "Illiquid" then why = why .. DOT .. e.m.liqLabel:lower() end
        if e.new then why = why .. DOT .. "new" end
      elseif e.kind == "undercut" then
        val, vrgb = "by " .. short(e.ask - e.cur), C.purple
        why = string.format("seen %.0fh ago", e.seenH) .. DOT .. "now " .. short(e.cur)
      else
        why = ((e.side == "below") and "below " or "above ") .. short(e.limit or 0)
        if e.hit then val, vrgb = "hit", C.accent
        elseif e.past then val, vrgb = "past limit", C.sub
        else val, vrgb = pct(e.dist, true, true) .. " away", C.sub end
      end
      r.val:SetText(val); colorize(r.val, vrgb)
      r.why:SetText(why)
      local dim = stale and (e.kind == "sell" or e.kind == "buy" or e.kind == "undercut")
      r:SetAlpha(dim and 0.5 or 1)
      r.key, r.move = e.key, e
      r:Show()
    elseif h.mv.rows[i] then
      h.mv.rows[i]:Hide(); h.mv.rows[i].key, h.mv.rows[i].move = nil, nil
    end
  end
  -- footer: at most two notes - scan age, more hits, the alert list
  local chips = {}
  if stale then chips[#chips + 1] = { "scan " .. stale .. " days old", C.red } end
  if mv.extraHits > 0 then chips[#chips + 1] = { "+" .. mv.extraHits .. " hits  \226\128\186", C.accent, nil, true } end
  local alertTxt
  if mv.armed > 0 then alertTxt = (mv.armed == 1) and "1 alert armed" or (mv.armed .. " alerts armed")
  elseif #mv.hits + #mv.rest > 0 then alertTxt = "all alerts"
  else alertTxt = "set a price alert" end
  chips[#chips + 1] = { alertTxt .. "  \226\128\186", C.muted, nil, true }
  for i = #chips, 3, -1 do chips[i] = nil end
  local x = PAD
  for i = 1, max(#chips, #h.mv.chips) do
    local d = chips[i]
    local c = (d or h.mv.chips[i]) and chip(h, i)
    if d then
      c:SetText(d[1]); colorize(c, d[2])
      c:ClearAllPoints(); c:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", x, 9)
      x = x + c:GetStringWidth() + 14
      c.btn:SetScript("OnEnter", d[3])
      c.btn:SetScript("OnClick", d[4] and function() if M.Go then M.Go("alerts") end end or nil)
      c:Show(); c.btn:Show()
    elseif c then
      c:Hide(); c.btn:Hide()
    end
  end
  -- empty states
  h.mv.empty:ClearAllPoints()
  h.mv.empty:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -(HEAD + 4)); h.mv.empty:SetWidth(rowW)
  if #mv.list == 0 then
    if mv.noScan then
      h.mv.empty:SetText("Scan the auction house once - sell ideas from your bags, bargains on your watchlist and your price alerts line up here.")
    else
      h.mv.empty:SetText("Nothing urgent - nothing you hold trades well over Fair, no watched item is a bargain and no alert is close.")
    end
    h.mv.empty:Show()
  else
    h.mv.empty:Hide()
  end
end

-- ===== refresh ================================================================
function M.RefreshHome()
  local h = M.home
  if not h then return end
  local classic = (M.db and M.db.config and M.db.config.homeView == "classic") and true or false
  if h.viewSeg then h.viewSeg:Select(classic and "classic" or "new") end
  h.root:SetShown(not classic)
  h.classicRoot:SetShown(classic)
  if classic then
    refreshClassic()
    return
  end
  layout(h)
  local g = h.geo
  local rows = max(1, floor((g.r2 - HEAD - 26) / MV_ROWH))
  local trades = max(1, floor((g.r1 - 84 - 6) / 19))
  local mo = M.HomeModel({ rows = rows, trades = trades, unwatched = h.unwatched,
                          tradeDays = (g.trW - 2 * PAD) >= 330 })
  h.model = mo
  refreshHero(h, mo)
  refreshTrading(h, mo)
  refreshMap(h, mo)
  refreshMoves(h, mo)
  if M.HomeLoadingSet then
    M.HomeLoadingSet(h, { hero = true, trading = true, map = true, moves = not mo.moves.pending })
  end
end
