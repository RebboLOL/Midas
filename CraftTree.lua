-- Midas – Crafting tab: a tech tree in the style of old strategy games. The
-- item you want sits on the right, its materials fan out to the left, level by
-- level down to the raw goods; every card shows its price now (gold) and Fair
-- (purple) one below the other, the step total first, and what making it saves
-- over buying it. The tree sits in its own framed field with two scroll bars.
-- The side column lists what the item is used in, what it disenchants into and
-- which disenchants yield it. M.CraftPeek shows the same tree as a small card
-- (Charts tab).
local ADDON, M = ...
local T = M.Theme
local C = T.C
local floor, min, max, abs = math.floor, math.min, math.max, math.abs

local CARD_W, CARD_H = 204, 70
local COL_GAP, ROW_GAP = 46, 8
local SIDE_W, FOOT_H, TOP_H = 236, 78, 34
-- the item at the root, named on its own tile floating in the field's top
-- left corner; the tree keeps the whole field and starts below the tile
local TILE_X, TILE_Y, TILE_H = 10, 10, 46
local MAX_NODES = 140
local BAR = 10            -- scroll bar thickness
local WHITE = "Interface\\Buttons\\WHITE8X8"
local QMARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local GEO = { w = CARD_W, h = CARD_H, col = COL_GAP, row = ROW_GAP, pad = 24, padTop = TILE_Y + TILE_H + 14 }
local PEEK = { w = 150, h = 34, col = 22, row = 4 }
local PEEK_W, PEEK_H = 470, 300
M.CRAFT_GEO, M.CRAFT_PEEK_GEO = GEO, PEEK

local ct = { hist = {}, fwd = {}, expanded = {}, hs = 0, vs = 0, topOff = 0 }
M.craftUI = ct

local function hexc(c) return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255) end
local GOLDH, PURH, MUTH = hexc(C.teal), hexc(C.purple), hexc(C.muted)
local GRNH, REDH = hexc(C.green), hexc(C.red)

local function money(c)
  if not c then return "?" end
  c = floor(c + 0.5)
  return ((c < 0) and "-" or "") .. M.MoneyPlain(abs(c))
end
local function signed(c)
  if not c then return "?" end
  return ((c >= 0) and "+" or "") .. money(c)
end
local function pctTxt(p)
  if not p then return "" end
  return string.format(" (%s%+.0f%%|r)", (p >= 0) and GRNH or REDH, p * 100)
end
local function qtyTxt(q)
  if abs(q - floor(q + 0.5)) < 0.01 then return tostring(floor(q + 0.5)) end
  return (string.format("%.2f", q):gsub("0+$", ""))
end
local function nameOf(id) return M.ItemName and M.ItemName(tostring(id)) or ("Item #" .. id) end
local function qcolor(id)
  local q = M.ItemQualityColor and M.ItemQualityColor(tostring(id))
  if q and q.r then return q.r, q.g, q.b end
  return 1, 1, 1
end
local function iconOf(id) return (M.GetItemIcon and M.GetItemIcon(id)) or QMARK end
local function known(id) return M.GetItemInfo(id) ~= nil end
local SEP = "   \194\183   "

-- what making a node saves over buying it, now (gold) and fair (purple);
-- red "make +x" when buying is the cheaper way. Values for `need` units.
local function saveTxt(e, ef, need)
  local sN = e.buy and e.make and (e.buy - e.make) * need
  if not sN then
    return (e.how == "make") and (MUTH .. "no buy price|r") or ""
  end
  local sF = ef and ef.buy and ef.make and (ef.buy - ef.make) * need
  if sN >= 0 then
    return GRNH .. "saves|r " .. GOLDH .. money(sN) .. "|r" .. (sF and ("  " .. PURH .. money(sF) .. "|r") or "")
  end
  return REDH .. "make|r " .. GOLDH .. "+" .. money(-sN) .. "|r" ..
    (sF and ("  " .. PURH .. ((sF <= 0) and "+" or "") .. money(-sF) .. "|r") or "")
end

-- the root's own make or buy: { buyNow, buyFair, saveNow, saveFair }
local function rootSave(id, cc)
  local bN, bF = M.UnitPrice(id)
  return { buyNow = bN, buyFair = bF,
           saveNow = bN and cc and cc.now and (bN - cc.now),
           saveFair = bF and cc and cc.fair and (bF - cc.fair) }
end

-- ===== Navigation ===========================================================
local function setItem(id, noHist)
  id = tonumber(id)
  if not id then return end
  if ct.id and ct.id ~= id and not noHist then
    ct.hist[#ct.hist + 1] = ct.id
    ct.fwd = {}
  end
  ct.id = id
  ct.home = true              -- a new item opens with the item in view
  if M.RefreshCrafting then M.RefreshCrafting() end
end

-- open the tree for an item (from anywhere: tooltip, Charts, slash);
-- noHist = the Back pill returning here, the ‹ › history stays as it is
function M.CraftOpen(id, noHist)
  M.EnsureUI()
  M.frame:Show()
  if id then setItem(id, noHist) else ct.id = nil end
  M.SelectTab(M.TAB.Crafting)
end

function M.ShowCraftTree(id)
  M.CraftOpen(id)
end

-- left-click focuses the item in the tree, right-click opens the item menu
-- with every page Midas has for it (chart, offer book, trades, stock, watch)
local function itemClick(id, button)
  if button == "RightButton" then
    GameTooltip:Hide()
    if M.ItemMenu then M.ItemMenu(tostring(id))
    elseif M.Go then M.Go("chart", tostring(id)) end
  else
    setItem(id)
  end
end

-- ===== The tree field: a framed view with two scroll bars ==================
-- The tree is drawn at full size into the child of a scroll frame. The mouse
-- wheel scrolls up and down (sideways when the tree is not taller than the
-- field); the bars on the right and at the bottom move it by dragging the
-- thumb or clicking the track.
local function viewSize()
  return ct.canvas:GetWidth() or 0, ct.canvas:GetHeight() or 0
end

local function maxScroll()
  local W, H = viewSize()
  return max(0, (ct.contentW or W) - W), max(0, (ct.contentH or H) - H)
end

local function barLen(bar)
  if bar.horiz then return bar:GetWidth() or 0 end
  return bar:GetHeight() or 0
end

local function placeBar(bar, pos, maxPos, viewLen, contentLen)
  local track = barLen(bar)
  if maxPos <= 0 or track <= 0 or not contentLen or contentLen <= 0 then
    bar.thumb:Hide()
    bar.len, bar.track = 0, track
    return
  end
  local len = max(24, track * viewLen / contentLen)
  local off = (track - len) * (pos / maxPos)
  bar.thumb:ClearAllPoints()
  if bar.horiz then
    bar.thumb:SetSize(len, BAR - 4)
    bar.thumb:SetPoint("LEFT", bar, "LEFT", off, 0)
  else
    bar.thumb:SetSize(BAR - 4, len)
    bar.thumb:SetPoint("TOP", bar, "TOP", 0, -off)
  end
  bar.thumb:Show()
  bar.len, bar.track = len, track
end

-- scroll to h / v (nil keeps that axis) and move both bars along
local function setScroll(h, v)
  if not ct.canvas then return end
  local mh, mv = maxScroll()
  ct.hs = max(0, min(h or ct.hs or 0, mh))
  ct.vs = max(0, min(v or ct.vs or 0, mv))
  ct.canvas:SetHorizontalScroll(ct.hs)
  ct.canvas:SetVerticalScroll(ct.vs)
  local W, H = viewSize()
  placeBar(ct.hbar, ct.hs, mh, W, ct.contentW)
  placeBar(ct.vbar, ct.vs, mv, H, ct.contentH)
end

-- the item (the right end of the tree) in view, its card in the middle
local function scrollHome()
  local _, H = viewSize()
  local mh = maxScroll()
  setScroll(mh, (ct.rootY or 0) + CARD_H / 2 - H / 2)
end

local function fieldWheel(d)
  local _, mv = maxScroll()
  if mv > 0 then setScroll(nil, (ct.vs or 0) - d * 40) else setScroll((ct.hs or 0) - d * 60, nil) end
end

local function barCursor(bar)
  local x, y = GetCursorPosition()
  local sc = bar:GetEffectiveScale() or 1
  if bar.horiz then return (x or 0) / sc - (bar:GetLeft() or 0) end
  return (bar:GetTop() or 0) - (y or 0) / sc
end

local function barScrollTo(bar, thumbStart)
  local travel = (bar.track or 0) - (bar.len or 0)
  if travel <= 0 then return end
  local frac = max(0, min(1, thumbStart / travel))
  local mh, mv = maxScroll()
  if bar.horiz then setScroll(frac * mh, nil) else setScroll(nil, frac * mv) end
end

local function barStop(bar)
  bar.grab = nil
  bar:SetScript("OnUpdate", nil)
  bar.thumb:SetColorTexture(T.Unpack(bar.hot and C.accent or C.borderlt))
end

local function barUpdate(bar)
  if not bar.grab then return end
  if not IsMouseButtonDown("LeftButton") then barStop(bar); return end
  barScrollTo(bar, barCursor(bar) - bar.grab)
end

local function newBar(parent, horiz)
  local bar = CreateFrame("Frame", nil, parent)
  bar.horiz = horiz
  bar:EnableMouse(true)
  bar:EnableMouseWheel(true)
  local bg = bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(); bg:SetColorTexture(C.bg2[1], C.bg2[2], C.bg2[3], 1)
  bar.thumb = bar:CreateTexture(nil, "ARTWORK")
  bar.thumb:SetColorTexture(T.Unpack(C.borderlt))
  bar.thumb:Hide()
  bar:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" or not self.thumb:IsShown() then return end
    local c = barCursor(self)
    local mh, mv = maxScroll()
    local pos, maxPos = self.horiz and ct.hs or ct.vs, self.horiz and mh or mv
    local start = ((self.track or 0) - (self.len or 0)) * ((maxPos > 0) and (pos / maxPos) or 0)
    if c < start or c > start + (self.len or 0) then
      -- a click on the track: the thumb jumps there, centered on the cursor
      start = c - (self.len or 0) / 2
      barScrollTo(self, start)
      start = max(0, min(start, (self.track or 0) - (self.len or 0)))
    end
    self.grab = c - start
    self.thumb:SetColorTexture(T.Unpack(C.accent))
    self:SetScript("OnUpdate", barUpdate)
  end)
  bar:SetScript("OnMouseUp", barStop)
  bar:SetScript("OnHide", barStop)
  bar:SetScript("OnMouseWheel", function(self, d)
    if self.horiz then setScroll((ct.hs or 0) - d * 60, nil) else setScroll(nil, (ct.vs or 0) - d * 40) end
  end)
  bar:SetScript("OnEnter", function(self) self.hot = true; self.thumb:SetColorTexture(T.Unpack(C.accent)) end)
  bar:SetScript("OnLeave", function(self)
    self.hot = nil
    if not self.grab then self.thumb:SetColorTexture(T.Unpack(C.borderlt)) end
  end)
  return bar
end

-- ===== Card tooltip: this step in numbers ===================================
-- GameTooltip draws in the game font: plain characters only ("x", "-", "·").
local function tipMoney(n, f)
  return GOLDH .. money(n) .. "|r  " .. PURH .. money(f) .. "|r"
end

local function stepTip(n)
  local tip = GameTooltip
  if not (tip and tip:IsShown()) then return end
  local L, R = { 0.78, 0.76, 0.70 }, { 1, 1, 1 }
  local function dl(a, b) tip:AddDoubleLine(a, b, L[1], L[2], L[3], R[1], R[2], R[3]) end
  tip:AddLine(" ")
  tip:AddDoubleLine("|cffE8B44AThis step|r", MUTH .. "now  " .. PURH .. "fair|r", 1, 1, 1, 1, 1, 1)
  if n.root then
    local cc = ct.cc
    local rs = rootSave(n.id, cc)
    local rec = n.rec
    if cc then dl("Make 1", tipMoney(cc.now, cc.fair)) end
    if rec and rec.yield ~= 1 then
      dl("One craft makes " .. ((rec.lo == rec.hi) and rec.lo or (rec.lo .. "-" .. rec.hi)),
        MUTH .. "mats " .. tipMoney(cc and cc.now and cc.now * rec.yield, cc and cc.fair and cc.fair * rec.yield))
    end
    if rs.buyNow then dl("Buy 1", tipMoney(rs.buyNow, rs.buyFair)) end
    if rs.saveNow then
      if rs.saveNow >= 0 then
        dl(GRNH .. "Crafting saves|r", tipMoney(rs.saveNow, rs.saveFair))
      else
        dl(REDH .. "Buying saves|r", tipMoney(-rs.saveNow, rs.saveFair and -rs.saveFair))
      end
    end
  else
    local e, ef, need = n.e or {}, n.ef or {}, n.need or 1
    local rec = n.rec or (e.how == "make" and e.rec)
    local needTxt = qtyTxt(need)
    if rec and e.how == "make" then
      needTxt = needTxt .. MUTH .. "  (" .. qtyTxt(need / rec.yield) .. " crafts)|r"
    end
    dl("Needed", needTxt)
    if e.buy then dl("Buy " .. qtyTxt(need) .. " x " .. money(e.buy), tipMoney(e.buy * need, ef.buy and ef.buy * need)) end
    if e.make then dl("Make " .. qtyTxt(need) .. " x " .. money(e.make), tipMoney(e.make * need, ef.make and ef.make * need)) end
    if e.buy and e.make then
      local sN, sF = (e.buy - e.make) * need, ef.buy and ef.make and (ef.buy - ef.make) * need
      if sN >= 0 then
        dl(GRNH .. "Making saves|r", tipMoney(sN, sF))
      else
        dl(REDH .. "Buying saves|r", tipMoney(-sN, sF and -sF))
      end
    end
    local route = (e.how == "make") and "made from its materials" or
      ((e.src == "vendor" and "bought from a vendor") or (e.src == "est" and "bought from a vendor (estimate)")
       or (e.src == "ah" and "bought on the AH") or "no price yet")
    tip:AddLine("Counted as: " .. route, 0.55, 0.58, 0.64)
  end
  tip:AddLine("Click: focus  \194\183  right-click: all pages of the item", 0.52, 0.48, 0.39)
  tip:Show()
end

-- ===== Pools ================================================================
local function newCard(parent)
  local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
  b:SetSize(CARD_W, CARD_H)
  b:SetBackdrop(T.FLAT)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  local qb = b:CreateTexture(nil, "ARTWORK")
  qb:SetTexture(WHITE); qb:SetSize(36, 36); qb:SetPoint("TOPLEFT", 7, -7)
  local ic = b:CreateTexture(nil, "OVERLAY")
  ic:SetSize(34, 34); ic:SetPoint("CENTER", qb, "CENTER"); ic:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  b.qb, b.ic = qb, ic
  b.qty = T.Text(b, T.SIZE.small, "accent", T.FONT_SEMI)
  b.qty:SetPoint("TOPRIGHT", -7, -6); b.qty:SetJustifyH("RIGHT")
  b.name = T.Text(b, T.SIZE.small, "text", T.FONT_MED)
  b.name:SetPoint("TOPLEFT", qb, "TOPRIGHT", 7, 1); b.name:SetJustifyH("LEFT")
  -- two price rows: the step total on the left, the unit price on the right
  local tc, pc = C.teal, C.purple
  b.now = T.Text(b, T.SIZE.small, nil, T.FONT_SEMI)
  b.now:SetPoint("TOPLEFT", qb, "TOPRIGHT", 7, -14); b.now:SetTextColor(tc[1], tc[2], tc[3])
  b.nowU = T.Text(b, T.SIZE.tiny, nil, T.FONT_MED)
  b.nowU:SetPoint("TOPRIGHT", -7, -22); b.nowU:SetJustifyH("RIGHT"); b.nowU:SetTextColor(tc[1], tc[2], tc[3], 0.7)
  b.fair = T.Text(b, T.SIZE.small, nil, T.FONT_SEMI)
  b.fair:SetPoint("TOPLEFT", qb, "TOPRIGHT", 7, -27); b.fair:SetTextColor(pc[1], pc[2], pc[3])
  b.fairU = T.Text(b, T.SIZE.tiny, nil, T.FONT_MED)
  b.fairU:SetPoint("TOPRIGHT", -7, -35); b.fairU:SetJustifyH("RIGHT"); b.fairU:SetTextColor(pc[1], pc[2], pc[3], 0.7)
  -- bottom strip: where it comes from, and the make-or-buy saving
  local sep = b:CreateTexture(nil, "ARTWORK")
  sep:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.7)
  sep:SetHeight(1); sep:SetPoint("BOTTOMLEFT", 7, 21); sep:SetPoint("BOTTOMRIGHT", -7, 21)
  b.tag = T.Text(b, T.SIZE.tiny, "muted", T.FONT_SEMI)
  b.tag:SetPoint("BOTTOMLEFT", 7, 6); b.tag:SetJustifyH("LEFT")
  b.save = T.Text(b, T.SIZE.tiny, "sub", T.FONT_MED)
  b.save:SetPoint("BOTTOMRIGHT", -7, 6); b.save:SetJustifyH("RIGHT")
  -- expander on the connector side: show / hide how this material is made
  local ex = CreateFrame("Button", nil, b, "BackdropTemplate")
  ex:SetSize(14, 14); ex:SetPoint("CENTER", b, "LEFT", 0, 0)
  ex:SetBackdrop(T.FLAT); ex:SetBackdropColor(T.Unpack(C.bg2)); ex:SetBackdropBorderColor(T.Unpack(C.borderlt))
  ex.t = T.Text(ex, T.SIZE.small, "accent", T.FONT_SEMI); ex.t:SetPoint("CENTER", 0, 1)
  ex:SetFrameLevel(b:GetFrameLevel() + 2)
  ex:SetScript("OnClick", function(self)
    local node = self:GetParent().node
    if not node then return end
    ct.expanded[node.path] = not node.open
    M.RefreshCrafting()
  end)
  b.ex = ex
  b:SetScript("OnEnter", function(self)
    self:SetBackdropBorderColor(T.Unpack(C.accent))
    if self.node and M.ShowItemTip then
      M.ShowItemTip(tostring(self.node.id))
      stepTip(self.node)
    end
  end)
  b:SetScript("OnLeave", function(self)
    self:SetBackdropBorderColor(T.Unpack(self.border or C.border))
    GameTooltip:Hide()
  end)
  b:SetScript("OnClick", function(self, button)
    if self.node then itemClick(self.node.id, button) end
  end)
  return b
end

local function card(i)
  local b = ct.cards[i]
  if not b then b = newCard(ct.content); ct.cards[i] = b end
  b:Show()
  return b
end

-- ===== Tree model ===========================================================
local function firstRecipe(id)
  local recs = M.Recipes().byItem[id]
  return recs and recs[1]
end

-- nodes follow the "now" route of the cost calculation; a cheaper-to-buy
-- material stays folded (+) until you open it
local function buildTree(rootId, expanded, maxNodes)
  expanded, maxNodes = expanded or ct.expanded, maxNodes or MAX_NODES
  local cc = M.CraftCost(rootId)
  local memo = (cc and cc.memo[1]) or {}
  local memoF = (cc and cc.memo[2]) or {}
  local root = { id = rootId, need = 1, depth = 0, path = tostring(rootId), root = true,
                 rec = cc and cc.rec or firstRecipe(rootId) }
  local count = 1
  local function expand(node, guard)
    local rec = node.rec
    if not rec then return end
    node.children = {}
    local crafts = node.root and 1 or (node.need / rec.yield)
    for _, mt in ipairs(rec.mats) do
      local e, ef = memo[mt.id] or {}, memoF[mt.id] or {}
      local child = { id = mt.id, need = crafts * mt.n, depth = node.depth + 1,
                      path = node.path .. ">" .. mt.id, e = e, ef = ef, made = (e.how == "make"),
                      dim = node.dim }
      count = count + 1
      child.craftable = (M.Recipes().byItem[mt.id] ~= nil) and not guard[mt.id]
      local open = expanded[child.path]
      if open == nil then open = child.made end
      if child.craftable and open and child.depth < 6 and count < maxNodes then
        child.open = true
        child.rec = (e.how == "make" and e.rec) or firstRecipe(mt.id)
        if not child.made then child.dim = true end   -- shown for reference, buying is cheaper
        guard[mt.id] = true
        expand(child, guard)
        guard[mt.id] = nil
      end
      node.children[#node.children + 1] = child
    end
  end
  expand(root, { [rootId] = true })
  return root, cc
end

local function place(root)
  local rows, maxD = 0, 0
  local function walk(n)
    if n.depth > maxD then maxD = n.depth end
    if n.children and #n.children > 0 then
      for _, c in ipairs(n.children) do walk(c) end
      n.row = (n.children[1].row + n.children[#n.children].row) / 2
    else
      n.row = rows; rows = rows + 1
    end
  end
  walk(root)
  return rows, maxD
end

-- pure layout (tested offline): card rects and connector segments. `g` is the
-- card geometry (main view by default); g.pad keeps a margin all around
-- (g.padTop on top: room for the title tile), and a tree smaller than W x H
-- sits in the middle of what is left.
function M.CraftTreeLayout(root, W, H, g)
  g = g or GEO
  local cw, chh = g.w, g.h
  local rows, maxD = place(root)
  local rowH = chh + g.row
  local contentH = rows * rowH - g.row
  local step = cw + g.col
  local contentW = (maxD + 1) * cw + maxD * g.col
  local pad = g.pad or 0
  local padT = g.padTop or pad
  local offX = pad + max(0, (W - 2 * pad - contentW) / 2)
  local offY = padT + max(0, (H - padT - pad - contentH) / 2)
  local rootX = offX + contentW - cw
  local out = { cards = {}, segs = {}, w = max(contentW + 2 * pad, W), h = max(contentH + padT + pad, H) }
  local function walk(n)
    n.x = rootX - n.depth * step
    n.y = offY + n.row * rowH
    out.cards[#out.cards + 1] = n
    if n.children and #n.children > 0 then
      local px, py = n.x, n.y + chh / 2
      local mid = px - (step - cw) / 2
      local top, bot = py, py
      for _, c in ipairs(n.children) do
        walk(c)
        local cy = c.y + chh / 2
        out.segs[#out.segs + 1] = { c.x + cw, cy, mid, cy, dim = c.dim }
        if cy < top then top = cy end
        if cy > bot then bot = cy end
      end
      out.segs[#out.segs + 1] = { mid, top, mid, bot, dim = n.dim }
      out.segs[#out.segs + 1] = { mid, py, px, py, dim = n.dim }
    end
  end
  walk(root)
  return out
end

-- ===== Tree drawing =========================================================
local function setCard(b, n)
  b.node = n
  local id = n.id
  b.ic:SetTexture(iconOf(id))
  local r, g, bl = qcolor(id)
  b.qb:SetVertexColor(r, g, bl, 1)
  b.name:SetText(known(id) and nameOf(id) or "?")
  local kn = n.root and #(M.CraftKnownBy(id)) > 0
  b.border = (n.root and C.accent) or (kn and C.green) or ((n.e and n.e.how == "make") and C.mint) or C.border
  b:SetBackdropColor(T.Unpack(n.dim and C.bg0 or C.bg1))
  b:SetBackdropBorderColor(T.Unpack(b.border))
  b:SetAlpha(n.dim and 0.6 or 1)
  if n.root then
    local rec, cc = n.rec, ct.cc
    local y = rec and ((rec.lo == rec.hi) and tostring(rec.lo) or (rec.lo .. "-" .. rec.hi)) or "1"
    b.qty:SetText(rec and ("makes " .. y) or "")
    local rs = rootSave(id, cc)
    b.now:SetText("make " .. money(cc and cc.now))
    b.fair:SetText("make " .. money(cc and cc.fair))
    b.nowU:SetText("buy " .. money(rs.buyNow))
    b.fairU:SetText("buy " .. money(rs.buyFair))
    b.tag:SetText(rec and string.upper(M.ProfName(rec.prof)) or "NO RECIPE")
    b.tag:SetTextColor(T.Unpack(C.muted))
    b.save:SetText(saveTxt({ buy = rs.buyNow, make = cc and cc.now, how = "make" },
      { buy = rs.buyFair, make = cc and cc.fair }, 1))
  else
    b.qty:SetText("\195\151" .. qtyTxt(n.need))
    local u, uf = n.e.cost, n.ef.cost
    b.now:SetText(money(u and u * n.need))
    b.fair:SetText(money(uf and uf * n.need))
    b.nowU:SetText(money(u) .. " each")
    b.fairU:SetText(money(uf) .. " each")
    local tag = (n.e.how == "make") and "CRAFT" or (n.e.src == "vendor" and "VENDOR")
      or (n.e.src == "est" and "VENDOR EST.") or (n.e.src == "ah" and "AH") or "NO PRICE"
    b.tag:SetText(tag)
    b.tag:SetTextColor(T.Unpack((n.e.how == "make") and C.mint or (n.e.src and C.muted) or C.red))
    b.save:SetText(saveTxt(n.e, n.ef, n.need))
  end
  -- the name shares its row with the quantity badge
  b.name:SetWidth(max(40, CARD_W - 57 - (b.qty:GetStringWidth() or 30) - 6))
  if not n.root and n.craftable then
    b.ex.t:SetText(n.open and "\226\136\146" or "+")
    b.ex:Show()
  else
    b.ex:Hide()
  end
  b:ClearAllPoints()
  b:SetPoint("TOPLEFT", ct.content, "TOPLEFT", n.x, -n.y)
end

-- orthogonal connectors from a layout, drawn into `content` from `pool`
local function drawSegs(content, pool, segs)
  for i, s in ipairs(segs) do
    local t = pool[i]
    if not t then
      t = content:CreateTexture(nil, "BORDER")
      t:SetTexture(WHITE)
      pool[i] = t
    end
    t:ClearAllPoints(); t:Show()
    local c = s.dim and C.border or C.borderlt
    t:SetVertexColor(c[1], c[2], c[3], 1)
    if s[2] == s[4] then
      t:SetPoint("TOPLEFT", content, "TOPLEFT", min(s[1], s[3]), -s[2] + 1)
      t:SetSize(max(1, abs(s[3] - s[1])), 2)
    else
      t:SetPoint("TOPLEFT", content, "TOPLEFT", s[1] - 1, -min(s[2], s[4]))
      t:SetSize(2, max(1, abs(s[4] - s[2])))
    end
  end
end

local function drawTree()
  local W, H = ct.canvas:GetWidth(), ct.canvas:GetHeight()
  if not W or W < 50 then return false end
  for _, b in ipairs(ct.cards) do b:Hide() end
  for _, t in ipairs(ct.lines) do t:Hide() end
  local root, cc = buildTree(ct.id)
  ct.cc = cc
  local L = M.CraftTreeLayout(root, W, H)
  ct.contentW, ct.contentH, ct.rootY = L.w, L.h, root.y
  ct.content:SetSize(L.w, L.h)
  for i, n in ipairs(L.cards) do setCard(card(i), n) end
  drawSegs(ct.content, ct.lines, L.segs)
  if ct.home then
    ct.home = nil
    scrollHome()
  else
    setScroll()
  end
  return true, root, cc
end

-- ===== Side column: used in / disenchants into / from disenchanting =========
local QUAL = { [2] = "Uncommon", [3] = "Rare", [4] = "Epic" }

local function sideRow(i)
  local r = ct.sideRows[i]
  if not r then
    r = CreateFrame("Button", nil, ct.side)
    r:SetHeight(22)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r.ic = r:CreateTexture(nil, "ARTWORK"); r.ic:SetSize(18, 18); r.ic:SetPoint("LEFT", 0, 0)
    r.ic:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.l = T.Text(r, T.SIZE.small, "text", T.FONT_MED); r.l:SetPoint("LEFT", r.ic, "RIGHT", 6, 0)
    r.l:SetJustifyH("LEFT")
    r.r = T.Text(r, T.SIZE.tiny, "sub", T.FONT_MED); r.r:SetPoint("RIGHT", 0, 0); r.r:SetJustifyH("RIGHT")
    local hl = r:CreateTexture(nil, "BACKGROUND"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.05); hl:Hide()
    r:SetScript("OnEnter", function(self) hl:Show(); if self.id and M.ShowItemTip then M.ShowItemTip(tostring(self.id)) end end)
    r:SetScript("OnLeave", function() hl:Hide(); GameTooltip:Hide() end)
    r:SetScript("OnClick", function(self, button) if self.id then itemClick(self.id, button) end end)
    ct.sideRows[i] = r
  end
  r:ClearAllPoints(); r:Show()
  return r
end

local function sideHead(i)
  local h = ct.sideHeads[i]
  if not h then
    h = T.Text(ct.side, T.SIZE.tiny, "muted", T.FONT_SEMI)
    ct.sideHeads[i] = h
  end
  h:ClearAllPoints(); h:Show()
  return h
end

local function fillSide(id)
  for _, r in ipairs(ct.sideRows) do r:Hide() end
  for _, h in ipairs(ct.sideHeads) do h:Hide() end
  local Rx = M.Recipes()
  local y, nr, nh = 0, 0, 0
  local H = ct.side:GetHeight() or 300
  local function head(txt)
    nh = nh + 1
    local h = sideHead(nh)
    h:SetPoint("TOPLEFT", 0, -y); h:SetText(txt)
    y = y + 18
  end
  -- the item's other pages first: chart, offer book, your trades, your
  -- stock and the watchlist toggle, as chips (Nav.lua)
  if ct.links then
    head("THIS ITEM")
    ct.links:ClearAllPoints()
    ct.links:SetPoint("TOPLEFT", ct.side, "TOPLEFT", 0, -y)
    ct.links:SetItem(tostring(id), SIDE_W)
    if ct.links:IsShown() then y = y + (ct.links.h or 20) + 12 end
  end
  local function row(rid, left, right, rc)
    if y + 22 > H then return false end
    nr = nr + 1
    local r = sideRow(nr)
    r:SetPoint("TOPLEFT", 0, -y); r:SetPoint("RIGHT", ct.side, "RIGHT", 0, 0)
    r.id = rid
    r.ic:SetTexture(rid and iconOf(rid) or QMARK); r.ic:SetShown(rid ~= nil)
    r.l:SetWidth(SIDE_W - 24 - 70); r.l:SetText(left)
    if rid then r.l:SetTextColor(qcolor(rid)) else r.l:SetTextColor(T.Unpack(C.sub)) end
    r.r:SetText(right or "")
    if rc then r.r:SetTextColor(T.Unpack(rc)) else r.r:SetTextColor(T.Unpack(C.sub)) end
    y = y + 22
    return true
  end
  -- used in: one row per product, best profit first
  local uses = Rx.usedIn[id]
  if uses then
    local seen, list = {}, {}
    for _, rec in ipairs(uses) do
      if not seen[rec.item] then
        seen[rec.item] = true
        local p = M.CraftProfit(rec.item)
        list[#list + 1] = { id = rec.item, p = p and p.now, pct = p and p.nowPct }
      end
    end
    table.sort(list, function(a, b)
      if (a.p ~= nil) ~= (b.p ~= nil) then return a.p ~= nil end
      if a.p and b.p and a.p ~= b.p then return a.p > b.p end
      return a.id < b.id
    end)
    head("USED IN  \194\183  " .. #list)
    for i, e in ipairs(list) do
      local right = e.pct and string.format("%+.0f%%", e.pct * 100) or "-"
      local col = e.pct and ((e.pct >= 0) and C.green or C.red) or C.muted
      if not row(e.id, known(e.id) and nameOf(e.id) or "?", right, col) then
        break
      end
      if i == #list then break end
    end
    y = y + 8
  end
  -- disenchants into (gear)
  local de = M.DisenchantValue(id)
  if de then
    head("DISENCHANTS INTO  \194\183  ~ODDS")
    for _, r in ipairs(de.results) do
      local qty = (r.lo == r.hi) and tostring(r.lo) or (r.lo .. "-" .. r.hi)
      row(r.id, nameOf(r.id), string.format("%.0f%%  %sx", r.chance * 100, qty))
    end
    local best = (de.best == "disenchant" and "disenchant") or (de.best == "sell" and "sell on the AH") or "vendor it"
    row(nil, GOLDH .. "~" .. money(de.now) .. "|r  " .. PURH .. "~" .. money(de.fair) .. "|r", "best: " .. best,
      C.accent)
    y = y + 8
  end
  -- yielded by disenchanting (dust / essence / shards)
  local src = M.DisenchantSources(id)
  if #src > 0 then
    head("FROM DISENCHANTING  \194\183  ARMOR ODDS")
    for _, s in ipairs(src) do
      local qty = (s.min == s.max) and tostring(s.min) or (s.min .. "-" .. s.max)
      if not row(nil, string.format("%s  ilvl %d-%d", QUAL[s.quality] or "?", s.lo, s.hi),
        string.format("%.0f%%  %sx", s.chance * 100, qty)) then break end
    end
  end
  if nr == 0 and nh == 0 then
    head("USED IN")
    row(nil, "no recipe uses this item")
  end
end

-- ===== Footer ===============================================================
-- The answer first, in words: make it or buy it, and what crafting one to
-- sell earns. Next to it the numbers behind that as a small table - one item,
-- now (gold) over Fair (purple) - every column and row explained on hover.
local GRID_X = 300
local FOOT_COLS = {
  { key = "make", x = 44,  w = 86,  head = "MAKE", tip = { "Make",
    "What the materials for ONE item cost - each material bought or made from its own materials, whichever is cheaper (Make or buy). A craft that makes several items is divided by its yield." } },
  { key = "buy",  x = 134, w = 86,  head = "BUY", tip = { "Buy",
    "What one item costs to buy: a merchant's price if a vendor sells it, else the cheapest listing of your newest scan (FAIR row: its Fair price)." } },
  { key = "save", x = 224, w = 128, head = "MAKING SAVES", tip = { "Making saves",
    "Buy minus make: what crafting one yourself saves over buying it, then that as a share of the buy price. Red = buying is the cheaper way." } },
  { key = "sell", x = 356, w = 118, head = "SELL AFTER CUT", tip = { "Sell after the cut",
    "What one item brings on the auction house after the 5% AH cut (FAIR row: sold at its Fair price)." } },
  { key = "prof", x = 478, w = 128, head = "PROFIT EACH", tip = { "Profit each",
    "Sell after the cut minus make: what crafting one to sell earns, then that as a share of the material cost." } },
}
local FOOT_ROWS = {
  { key = "now",  label = "NOW",  y = -21, color = "teal", tip = { "Now",
    "At the prices of your newest scan - what you pay and get today (Fair where an item is not listed)." } },
  { key = "fair", label = "FAIR", y = -38, color = "purple", tip = { "Fair",
    "At Fair prices - what each item is really worth, the purple line everywhere in Midas. Steadier than today's listings." } },
}

-- the footer's frames (built once from BuildCrafting)
local function buildFoot(parent)
  local foot = CreateFrame("Frame", nil, parent)
  foot:SetPoint("BOTTOMLEFT", 0, 0); foot:SetPoint("BOTTOMRIGHT", 0, 0); foot:SetHeight(FOOT_H - 6)
  ct.foot = foot
  local g = CreateFrame("Frame", nil, foot)      -- verdict + table, hidden without a recipe
  g:SetAllPoints()
  ct.footGrid = g
  ct.verdict = T.Text(g, T.SIZE.h1, "text", T.FONT_SEMI)
  ct.verdict:SetPoint("TOPLEFT", 0, -4)
  ct.verdictNote = T.Text(g, T.SIZE.tiny, "muted", T.FONT_MED)
  ct.verdictNote:SetPoint("LEFT", ct.verdict, "RIGHT", 10, -1)
  ct.why1 = T.Text(g, T.SIZE.body, "text", T.FONT_MED)
  ct.why1:SetPoint("TOPLEFT", 0, -25); ct.why1:SetWidth(GRID_X - 18); ct.why1:SetJustifyH("LEFT")
  ct.why2 = T.Text(g, T.SIZE.small, "sub", T.FONT_MED)
  ct.why2:SetPoint("TOPLEFT", 0, -42); ct.why2:SetWidth(GRID_X - 18); ct.why2:SetJustifyH("LEFT")
  if T.HelpTip then
    local vb = CreateFrame("Button", nil, g)
    vb:SetPoint("TOPLEFT", 0, 0); vb:SetSize(GRID_X - 18, 54)
    T.HelpTip(vb, "Make it or buy it?", {
      "MAKE IT when the materials for one item cost less than buying one, BUY IT when buying is cheaper - judged at today's prices (at Fair when nothing is listed today).",
      "The line below says what crafting one to sell earns after the 5% AH cut. The table on the right shows every number behind it, now and at Fair." }, "ANCHOR_TOP")
  end
  local vs = g:CreateTexture(nil, "ARTWORK")
  vs:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.6)
  vs:SetWidth(1); vs:SetPoint("TOPLEFT", GRID_X - 12, -2); vs:SetHeight(52)
  local ph = T.Text(g, T.SIZE.tiny, "muted", T.FONT_SEMI)
  ph:SetPoint("TOPLEFT", GRID_X, -6); ph:SetText("PER ITEM")
  for _, c in ipairs(FOOT_COLS) do
    local h = T.Text(g, T.SIZE.tiny, "muted", T.FONT_SEMI)
    h:SetPoint("TOPLEFT", GRID_X + c.x, -6); h:SetWidth(c.w); h:SetJustifyH("RIGHT"); h:SetText(c.head)
    if T.HelpTip then
      local hb = CreateFrame("Button", nil, g)
      hb:SetPoint("TOPLEFT", GRID_X + c.x, -3); hb:SetSize(c.w, 14)
      T.HelpTip(hb, c.tip[1], { c.tip[2] }, "ANCHOR_TOP")
    end
  end
  ct.cells = {}
  for _, r in ipairs(FOOT_ROWS) do
    local lab = T.Text(g, T.SIZE.small, nil, T.FONT_SEMI)
    lab:SetPoint("TOPLEFT", GRID_X, r.y); lab:SetText(r.label); lab:SetTextColor(T.Unpack(C[r.color]))
    if T.HelpTip then
      local lb = CreateFrame("Button", nil, g)
      lb:SetPoint("TOPLEFT", GRID_X, r.y + 2); lb:SetSize(40, 15)
      T.HelpTip(lb, r.tip[1], { r.tip[2] }, "ANCHOR_TOP")
    end
    local cells = {}
    for _, c in ipairs(FOOT_COLS) do
      local v = T.Text(g, T.SIZE.small, "text", T.FONT_MED)
      v:SetPoint("TOPLEFT", GRID_X + c.x, r.y); v:SetWidth(c.w); v:SetJustifyH("RIGHT")
      cells[c.key] = v
    end
    ct.cells[r.key] = cells
  end
  ct.noRecipe = T.Text(foot, T.SIZE.body, "muted", T.FONT_MED)
  ct.noRecipe:SetPoint("TOPLEFT", 0, -8)
  ct.noRecipe:SetText("No recipe makes this item - it is gathered, looted or bought.")
  ct.noRecipe:Hide()
  ct.known = T.Text(foot, T.SIZE.tiny, "muted", T.FONT_MED)
  ct.known:SetPoint("BOTTOMLEFT", 0, 2); ct.known:SetJustifyH("LEFT")
end

local function cellMoney(fs, v, col)
  if v then fs:SetText(col .. money(v) .. "|r") else fs:SetText(MUTH .. "-|r") end
end

local function fillFoot(root, cc)
  local id = ct.id
  local p = M.CraftProfit(id)
  if not (p and cc) then
    ct.footGrid:Hide()
    ct.noRecipe:Show()
    ct.known:SetText("")
    return
  end
  ct.footGrid:Show()
  ct.noRecipe:Hide()
  local rs = rootSave(id, cc)
  -- the table: one item, now over Fair
  local rows = {
    now  = { make = cc.now,  buy = rs.buyNow,  sell = p.sellNow,  prof = p.now,  pct = p.nowPct,  col = GOLDH },
    fair = { make = cc.fair, buy = rs.buyFair, sell = p.sellFair, prof = p.fair, pct = p.fairPct, col = PURH },
  }
  for k, r in pairs(rows) do
    local cells = ct.cells[k]
    cellMoney(cells.make, r.make, r.col)
    cellMoney(cells.buy, r.buy, r.col)
    if r.buy and r.make then
      local sv = r.buy - r.make
      local share = (r.buy > 0) and string.format("  %s%.0f%%|r", MUTH, abs(sv) / r.buy * 100) or ""
      cells.save:SetText(((sv >= 0) and GRNH or (REDH .. "-")) .. money(abs(sv)) .. "|r" .. share)
    else
      cells.save:SetText(MUTH .. "-|r")
    end
    cellMoney(cells.sell, r.sell and r.sell * 0.95, r.col)
    if r.prof then
      cells.prof:SetText(((r.prof >= 0) and GRNH or REDH) .. signed(r.prof) .. "|r"
        .. (r.pct and string.format("  %s%+.0f%%|r", MUTH, r.pct * 100) or ""))
    else
      cells.prof:SetText(MUTH .. "-|r")
    end
  end
  -- the verdict, in words: today's prices decide, Fair when nothing is listed
  local function decide(make, buy)
    if not (make and buy) then return nil end
    return (buy >= make) and "make" or "buy"
  end
  local dNow, dFair = decide(cc.now, rs.buyNow), decide(cc.fair, rs.buyFair)
  local d, mk, by, atFair = dNow, cc.now, rs.buyNow, false
  if not d then d, mk, by, atFair = dFair, cc.fair, rs.buyFair, true end
  local note = ""
  if d == "make" then
    ct.verdict:SetText(GRNH .. "MAKE IT|r")
    ct.why1:SetText(GRNH .. money(by - mk) .. "|r cheaper than buying"
      .. ((by > 0) and string.format("%s  (%.0f%% less)|r", MUTH, (by - mk) / by * 100) or ""))
  elseif d == "buy" then
    ct.verdict:SetText(REDH .. "BUY IT|r")
    ct.why1:SetText("buying is " .. REDH .. money(mk - by) .. "|r cheaper"
      .. ((mk > 0) and string.format("%s  (%.0f%% less)|r", MUTH, (mk - by) / mk * 100) or ""))
  else
    ct.verdict:SetText(MUTH .. "NOTHING TO COMPARE|r")
    ct.why1:SetText("making one costs " .. GOLDH .. money(cc.now or cc.fair) .. "|r" .. MUTH .. "  - no buy price yet|r")
  end
  if atFair and d then note = "at Fair prices - nothing listed today"
  elseif dNow and dFair and dNow ~= dFair then
    note = (dFair == "make") and "at Fair prices: make it" or "at Fair prices: buy it"
  end
  ct.verdictNote:SetText(note)
  local pr, pfair = p.now, false
  if not pr then pr, pfair = p.fair, true end
  if pr then
    ct.why2:SetText("crafted to sell: " .. ((pr >= 0) and GRNH or REDH) .. signed(pr) .. "|r each"
      .. MUTH .. (pfair and " at Fair" or "") .. " after the 5% AH cut|r")
  else
    ct.why2:SetText(MUTH .. "no AH price to sell it at yet|r")
  end
  -- how much of the saving comes from making materials instead of buying them
  local parts = {}
  if not cc.nowOk then parts[#parts + 1] = REDH .. "some material prices are missing - the totals are partial|r" end
  local direct = (not (M.db.config and M.db.config.craftBuyOnly)) and M.CraftCost(id, false)
  local extra = direct and direct.now and cc.now and (direct.now - cc.now)
  if extra and extra >= 1 then
    local ef = direct.fair and cc.fair and (direct.fair - cc.fair)
    parts[#parts + 1] = "materials you make yourself (green CRAFT cards) cut the cost by " .. GOLDH .. money(extra) .. "|r"
      .. (ef and ("  " .. PURH .. money(ef) .. "|r") or "")
  end
  local who = M.CraftKnownBy(id)
  if #who > 0 then
    parts[#parts + 1] = GRNH .. "recipe known by " .. table.concat(who, ", ") .. "|r"
  else
    parts[#parts + 1] = MUTH .. "no character of yours knows the recipe yet (open the profession window once)|r"
  end
  ct.known:SetText(table.concat(parts, SEP))
end

-- ===== Title tile of the field ==============================================
-- icon + name of the item at the root (quality color), below it what it is:
-- profession and yield for a recipe item, the number of uses for a material
local function fillHead(id)
  if not (ct.head and id) then return end
  ct.headIcon:SetTexture(iconOf(id))
  ct.headName:SetText(known(id) and nameOf(id) or ("Item #" .. id))
  ct.headName:SetTextColor(qcolor(id))
  local Rx = M.Recipes()
  local recs = Rx.byItem[id]
  local meta
  if recs then
    local rec = recs[1]
    local y = (rec.lo == rec.hi) and tostring(rec.lo) or (rec.lo .. "-" .. rec.hi)
    meta = M.ProfName(rec.prof) .. "  \194\183  makes " .. y
    if #recs > 1 then meta = meta .. "  \194\183  " .. #recs .. " recipes" end
  else
    local seen, n = {}, 0
    for _, rec in ipairs(Rx.usedIn[id] or {}) do
      if not seen[rec.item] then seen[rec.item] = true; n = n + 1 end
    end
    meta = "material" .. ((n > 0) and ("  \194\183  used in " .. n .. ((n == 1) and " recipe" or " recipes")) or "")
  end
  ct.headMeta:SetText(meta)
  local tw = max(ct.headName:GetStringWidth() or 120, ct.headMeta:GetStringWidth() or 80)
  ct.head:SetWidth(floor(8 + 30 + 9 + tw + 14 + 0.5))
end

-- ===== Top crafts (start view) ==============================================
local TOP_COLS = {
  { "ITEM", 250, "LEFT" }, { "PROFESSION", 120, "LEFT" }, { "MATS", 110, "RIGHT" },
  { "AH", 110, "RIGHT" }, { "PROFIT", 150, "RIGHT" }, { "SELLS", 80, "RIGHT" },
}
local TOP_ROWH = 34

local function topRow(i)
  local r = ct.topRows[i]
  if not r then
    r = CreateFrame("Button", nil, ct.top)
    r:SetHeight(TOP_ROWH - 2)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local hl = r:CreateTexture(nil, "BACKGROUND"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.04)
    r.hl = hl; hl:Hide()
    r.ic = r:CreateTexture(nil, "ARTWORK"); r.ic:SetSize(22, 22); r.ic:SetPoint("LEFT", 2, 0)
    r.ic:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.cols = {}
    local x = 0
    for c, def in ipairs(TOP_COLS) do
      local a = T.Text(r, (c == 1) and T.SIZE.body or T.SIZE.small, "text", T.FONT_MED)
      local b = T.Text(r, T.SIZE.tiny, nil, T.FONT_MED)
      local cx = (c == 1) and 30 or x
      local w = (c == 1) and (def[2] - 30) or def[2]
      a:SetWidth(w); a:SetJustifyH(def[3]); b:SetWidth(w); b:SetJustifyH(def[3])
      if c == 1 then
        a:SetPoint("LEFT", r, "LEFT", cx, 0)
      else
        a:SetPoint("TOPLEFT", r, "TOPLEFT", cx, -3)
        b:SetPoint("TOPLEFT", r, "TOPLEFT", cx, -17)
        b:SetTextColor(T.Unpack(C.purple))
      end
      r.cols[c] = { a = a, b = b }
      x = x + def[2]
    end
    r:SetScript("OnEnter", function(self) self.hl:Show(); if self.id and M.ShowItemTip then M.ShowItemTip(tostring(self.id)) end end)
    r:SetScript("OnLeave", function(self) self.hl:Hide(); GameTooltip:Hide() end)
    r:SetScript("OnClick", function(self, button) if self.id then itemClick(self.id, button) end end)
    ct.topRows[i] = r
  end
  r:Show()
  return r
end

local function drawTop()
  local H = ct.top:GetHeight() or 380
  local list = M.TopCrafts(ct.prof)
  local n = max(1, floor((H - 26 - 16) / TOP_ROWH))
  ct.topOff = max(0, min(ct.topOff, #list - n))
  for _, r in ipairs(ct.topRows) do r:Hide() end
  for i = 1, n do
    local e = list[i + ct.topOff]
    if not e then break end
    local r = topRow(i)
    r:SetPoint("TOPLEFT", ct.top, "TOPLEFT", 0, -26 - (i - 1) * TOP_ROWH)
    r:SetPoint("RIGHT", ct.top, "RIGHT", 0, 0)
    r.id = e.id
    r.ic:SetTexture(iconOf(e.id))
    local p, cc = e.profit, e.profit.cost
    local c = r.cols
    c[1].a:SetText(nameOf(e.id)); c[1].a:SetTextColor(qcolor(e.id))
    c[2].a:SetText(M.ProfName(e.prof)); c[2].a:SetTextColor(T.Unpack(C.sub)); c[2].b:SetText("")
    c[3].a:SetText(money(cc.now)); c[3].a:SetTextColor(T.Unpack(C.teal)); c[3].b:SetText(money(cc.fair))
    c[4].a:SetText(money(p.sellNow)); c[4].a:SetTextColor(T.Unpack(C.teal)); c[4].b:SetText(money(p.sellFair))
    c[5].a:SetText(signed(p.now) .. pctTxt(p.nowPct))
    c[5].a:SetTextColor(T.Unpack((p.now or 0) >= 0 and C.green or C.red))
    c[5].b:SetText(signed(p.fair) .. (p.fairPct and string.format(" (%+.0f%%)", p.fairPct * 100) or ""))
    c[6].a:SetText(e.speed and string.format("~%.1f/day", e.speed) or "-"); c[6].a:SetTextColor(T.Unpack(C.sub))
    c[6].b:SetText("")
  end
  ct.topEmpty:SetShown(#list == 0)
  ct.topCount:SetText(string.format("%d crafts with market data  \194\183  %s", #list,
    ct.prof and M.ProfName(ct.prof) or "all professions"))
end

-- ===== Search ===============================================================
local function candidates()
  if ct.cand then return ct.cand end
  local Rx, seen, out = M.Recipes(), {}, {}
  for _, id in ipairs(Rx.items) do
    if not seen[id] then seen[id] = true; out[#out + 1] = id end
  end
  for id in pairs(Rx.usedIn) do
    if not seen[id] then seen[id] = true; out[#out + 1] = id end
  end
  ct.cand = out
  return out
end

-- warm the client item cache in small chunks, so names are searchable
local function warm()
  if ct.warmed then return end
  ct.warmed = true
  local list, i = candidates(), 1
  local function step()
    local stop = min(#list, i + 59)
    for k = i, stop do
      if not M.GetItemInfo(list[k]) and C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(list[k])
      end
    end
    i = stop + 1
    if i <= #list then C_Timer.After(0.2, step) end
  end
  step()
end

local function fillResults()
  local q = (ct.query or ""):lower()
  for _, r in ipairs(ct.resRows) do r:Hide() end
  if #q < 2 or not M.CraftingOn() then ct.results:Hide(); return end
  local Rx, hits = M.Recipes(), {}
  for _, id in ipairs(candidates()) do
    local nm = nameOf(id)
    if nm:lower():find(q, 1, true) then hits[#hits + 1] = { id = id, nm = nm, craft = Rx.byItem[id] ~= nil } end
  end
  table.sort(hits, function(a, b)
    if a.craft ~= b.craft then return a.craft end
    return a.nm < b.nm
  end)
  ct.firstHit = hits[1] and hits[1].id
  local n = min(#hits, 12)
  for i = 1, n do
    local r = ct.resRows[i]
    if not r then
      r = CreateFrame("Button", nil, ct.results)
      r:SetHeight(20)
      r.ic = r:CreateTexture(nil, "ARTWORK"); r.ic:SetSize(16, 16); r.ic:SetPoint("LEFT", 4, 0)
      r.l = T.Text(r, T.SIZE.small, "text", T.FONT_MED); r.l:SetPoint("LEFT", r.ic, "RIGHT", 6, 0)
      r.l:SetWidth(190); r.l:SetJustifyH("LEFT")
      r.t = T.Text(r, T.SIZE.tiny, "muted", T.FONT_SEMI); r.t:SetPoint("RIGHT", -6, 0)
      local hl = r:CreateTexture(nil, "BACKGROUND"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.06); hl:Hide()
      r:SetScript("OnEnter", function() hl:Show() end)
      r:SetScript("OnLeave", function() hl:Hide() end)
      r:SetScript("OnClick", function(self)
        ct.results:Hide()
        ct.search.edit:ClearFocus()
        setItem(self.id)
      end)
      ct.resRows[i] = r
    end
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", ct.results, "TOPLEFT", 2, -2 - (i - 1) * 20)
    r:SetPoint("RIGHT", ct.results, "RIGHT", -2, 0)
    r.id = hits[i].id
    r.ic:SetTexture(iconOf(r.id))
    r.l:SetText(hits[i].nm); r.l:SetTextColor(qcolor(r.id))
    r.t:SetText(hits[i].craft and "CRAFT" or "MAT")
    r:Show()
  end
  ct.results:SetHeight(4 + max(1, n) * 20)
  ct.noHit:SetShown(n == 0)
  ct.results:Show()
end

-- ===== Profession filter popup ==============================================
local function profPop()
  if ct.pop:IsShown() then ct.pop:Hide(); return end
  local Rx = M.Recipes()
  local count = {}
  for _, id in ipairs(Rx.items) do
    local p = Rx.byItem[id][1].prof
    count[p] = (count[p] or 0) + 1
  end
  local list = { { id = nil, name = "All professions" } }
  for p in pairs(count) do list[#list + 1] = { id = p, name = M.ProfName(p), n = count[p] } end
  table.sort(list, function(a, b)
    if (a.id == nil) ~= (b.id == nil) then return a.id == nil end
    return a.name < b.name
  end)
  for _, b in ipairs(ct.popRows) do b:Hide() end
  for i, e in ipairs(list) do
    local b = ct.popRows[i]
    if not b then
      b = CreateFrame("Button", nil, ct.pop)
      b:SetHeight(20)
      b.l = T.Text(b, T.SIZE.small, "text", T.FONT_MED); b.l:SetPoint("LEFT", 8, 0)
      b.r = T.Text(b, T.SIZE.tiny, "muted", T.FONT_MED); b.r:SetPoint("RIGHT", -8, 0)
      local hl = b:CreateTexture(nil, "BACKGROUND"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.06); hl:Hide()
      b:SetScript("OnEnter", function() hl:Show() end)
      b:SetScript("OnLeave", function() hl:Hide() end)
      b:SetScript("OnClick", function(self)
        ct.prof = self.prof
        ct.topOff = 0
        ct.pop:Hide()
        ct.id = nil
        M.RefreshCrafting()
      end)
      ct.popRows[i] = b
    end
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", ct.pop, "TOPLEFT", 2, -2 - (i - 1) * 20)
    b:SetPoint("RIGHT", ct.pop, "RIGHT", -2, 0)
    b.prof = e.id
    b.l:SetText(e.name)
    b.l:SetTextColor(T.Unpack((ct.prof == e.id) and C.accent or C.text))
    b.r:SetText(e.n and tostring(e.n) or "")
    b:Show()
  end
  ct.pop:SetHeight(4 + #list * 20)
  ct.pop:Show()
end

-- ===== Build / refresh ======================================================
function M.BuildCrafting(panel)
  ct.panel = panel
  ct.cards, ct.lines, ct.sideRows, ct.sideHeads, ct.topRows, ct.resRows, ct.popRows = {}, {}, {}, {}, {}, {}, {}

  ct.search = T.Input(panel, 240, 22, "Search item or material...", function(txt)
    ct.query = txt
    fillResults()
  end)
  ct.search:SetPoint("TOPLEFT", 0, -2)
  ct.search.edit:HookScript("OnEnterPressed", function(self)
    if ct.firstHit then ct.results:Hide(); self:ClearFocus(); setItem(ct.firstHit) end
  end)
  ct.search.edit:HookScript("OnEditFocusGained", function() warm(); fillResults() end)
  ct.search.edit:HookScript("OnEditFocusLost", function()
    C_Timer.After(0.2, function() if ct.results then ct.results:Hide() end end)
  end)

  local back = T.Button(panel, "\226\128\185", 26, 22)
  back:SetPoint("LEFT", ct.search, "RIGHT", 8, 0)
  back:SetScript("OnClick", function()
    local prev = table.remove(ct.hist)
    if prev then
      if ct.id then ct.fwd[#ct.fwd + 1] = ct.id end
      setItem(prev, true)
    elseif ct.id then
      ct.fwd[#ct.fwd + 1] = ct.id
      ct.id = nil
      M.RefreshCrafting()
    end
  end)
  local fwd = T.Button(panel, "\226\128\186", 26, 22)
  fwd:SetPoint("LEFT", back, "RIGHT", 4, 0)
  fwd:SetScript("OnClick", function()
    local nxt = table.remove(ct.fwd)
    if nxt then
      if ct.id then ct.hist[#ct.hist + 1] = ct.id end
      setItem(nxt, true)
    end
  end)
  ct.back, ct.fwdBtn = back, fwd

  local top = T.Button(panel, "Top crafts", 96, 22)
  top:SetPoint("LEFT", fwd, "RIGHT", 10, 0)
  top:SetScript("OnClick", function()
    if ct.id then ct.hist[#ct.hist + 1] = ct.id end
    ct.id = nil
    M.RefreshCrafting()
  end)
  local prof = T.Button(panel, "All professions", 150, 22)
  prof:SetPoint("LEFT", top, "RIGHT", 6, 0)
  prof:SetScript("OnClick", profPop)
  ct.profBtn = prof

  local mob = T.Checkbox(panel, "Make or buy", function(on)
    M.db.config.craftBuyOnly = (not on) and true or nil
    M.CraftCacheReset()
    M.RefreshCrafting()
  end)
  mob:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -4)
  ct.mob = mob

  -- beta: a plaque and the switch for everything crafting (the same setting
  -- as Settings > "Crafting (beta)"); the controls before it hide when off
  local beta = T.Surface(panel, "bg0", "accent")
  beta:SetSize(44, 18)
  beta:SetPoint("LEFT", prof, "RIGHT", 14, 0)
  local betaTx = T.Text(beta, T.SIZE.tiny, "accent", T.FONT_SEMI)
  betaTx:SetPoint("CENTER", 0, 0); betaTx:SetText("BETA")
  if T.HelpTip then
    T.HelpTip(beta, "Crafting (beta)", {
      "Recipes come from the game's own data tables, prices from your scans. Some recipes may still price oddly - feedback welcome on the Discord.",
      "\"Enable crafting\" next to it (or Settings > Crafting (beta)) turns the tab, the Crafted price in Charts, the tooltip craft lines and the craft-tree links off." })
  end
  local onCb = T.Checkbox(panel, "Enable crafting", function(on)
    if M.SetCraftingOn then M.SetCraftingOn(on) end
  end)
  onCb:SetPoint("LEFT", beta, "RIGHT", 10, 0)
  ct.onCb = onCb
  ct.ctrl = { ct.search, back, fwd, top, prof, mob }
  -- switched off: one calm note instead of the views
  ct.off = CreateFrame("Frame", nil, panel)
  ct.off:SetPoint("TOPLEFT", 0, -TOP_H); ct.off:SetPoint("BOTTOMRIGHT", 0, 0)
  local offT = T.Text(ct.off, T.SIZE.h1, "sub", T.FONT_SEMI)
  offT:SetPoint("TOP", 0, -90); offT:SetText("Crafting (beta) is switched off")
  local offS = T.Text(ct.off, T.SIZE.body, "muted")
  offS:SetPoint("TOP", offT, "BOTTOM", 0, -12); offS:SetWidth(520)
  offS:SetJustifyH("CENTER"); offS:SetWordWrap(true); offS:SetSpacing(4)
  offS:SetText("Tick \"Enable crafting\" above (or Settings > Crafting (beta)) to price every recipe from your scans: "
    .. "the tech tree here, the Crafted price and line in the Charts tab, the craft lines in item tooltips and the "
    .. "Craft tree links of an item. The recipes your characters know keep being recorded meanwhile.")
  ct.off:Hide()
  if T.HelpTip then
    T.HelpTip(mob, "Make or buy", {
      "On: every material is bought or made from its own materials, whichever is cheaper at the moment (a green CRAFT tag marks made ones).",
      "Off: materials are always bought, so the cost is what the direct ingredients cost on the AH or at a vendor." })
  end

  -- search results + profession list float above the views
  ct.results = T.Surface(panel, "bg1", "borderlt")
  ct.results:SetPoint("TOPLEFT", ct.search, "BOTTOMLEFT", 0, -2)
  ct.results:SetWidth(300); ct.results:SetFrameStrata("DIALOG"); ct.results:Hide()
  ct.noHit = T.Text(ct.results, T.SIZE.small, "muted"); ct.noHit:SetPoint("LEFT", 8, 0)
  ct.noHit:SetText("no recipe item or material matches")
  ct.pop = T.Surface(panel, "bg1", "borderlt")
  ct.pop:SetPoint("TOPLEFT", prof, "BOTTOMLEFT", 0, -2)
  ct.pop:SetWidth(200); ct.pop:SetFrameStrata("DIALOG"); ct.pop:Hide()

  -- start view: the best crafts at current prices
  ct.top = CreateFrame("Frame", nil, panel)
  ct.top:SetPoint("TOPLEFT", 0, -TOP_H); ct.top:SetPoint("BOTTOMRIGHT", 0, 0)
  local x = 0
  for c, def in ipairs(TOP_COLS) do
    local h = T.Text(ct.top, T.SIZE.tiny, "muted", T.FONT_SEMI)
    h:SetWidth((c == 1) and (def[2] - 30) or def[2]); h:SetJustifyH(def[3])
    h:SetPoint("TOPLEFT", (c == 1) and 30 or x, -6)
    h:SetText(def[1])
    x = x + def[2]
  end
  ct.topCount = T.Text(ct.top, T.SIZE.tiny, "muted", T.FONT_MED)
  ct.topCount:SetPoint("BOTTOMRIGHT", 0, 2); ct.topCount:SetJustifyH("RIGHT")
  ct.topEmpty = T.Text(ct.top, T.SIZE.body, "muted")
  ct.topEmpty:SetPoint("TOP", 0, -80)
  ct.topEmpty:SetText("No craft with market data yet - scan the AH to price materials and products.")
  ct.top:EnableMouseWheel(true)
  ct.top:SetScript("OnMouseWheel", function(_, d)
    ct.topOff = max(0, ct.topOff - d * 3)
    drawTop()
  end)

  -- tree view
  ct.tree = CreateFrame("Frame", nil, panel)
  ct.tree:SetPoint("TOPLEFT", 0, -TOP_H); ct.tree:SetPoint("BOTTOMRIGHT", 0, 0)
  -- the field: a darker framed area, the tree scrolls inside it
  ct.field = CreateFrame("Frame", nil, ct.tree, "BackdropTemplate")
  ct.field:SetPoint("TOPLEFT", 0, 0); ct.field:SetPoint("BOTTOMRIGHT", -(SIDE_W + 16), FOOT_H)
  ct.field:SetBackdrop(T.FLAT)
  ct.field:SetBackdropColor(C.bg0[1] * 0.7, C.bg0[2] * 0.7, C.bg0[3] * 0.7, 1)
  ct.field:SetBackdropBorderColor(T.Unpack(C.border))
  ct.canvas = CreateFrame("ScrollFrame", nil, ct.field)
  ct.canvas:SetPoint("TOPLEFT", 1, -1); ct.canvas:SetPoint("BOTTOMRIGHT", -(BAR + 2), BAR + 2)
  ct.content = CreateFrame("Frame", nil, ct.canvas)
  ct.content:SetSize(10, 10)
  ct.canvas:SetScrollChild(ct.content)
  ct.canvas:EnableMouseWheel(true)
  ct.canvas:SetScript("OnMouseWheel", function(_, d) fieldWheel(d) end)
  ct.vbar = newBar(ct.field, false)
  ct.vbar:SetPoint("TOPRIGHT", -1, -1); ct.vbar:SetPoint("BOTTOMRIGHT", -1, BAR + 2); ct.vbar:SetWidth(BAR)
  ct.hbar = newBar(ct.field, true)
  ct.hbar:SetPoint("BOTTOMLEFT", 1, 1); ct.hbar:SetPoint("BOTTOMRIGHT", -(BAR + 2), 1); ct.hbar:SetHeight(BAR)
  -- the item at the root on its own tile, floating in the field's top-left
  -- corner above the tree (the layout starts the tree below it): icon, name
  -- in its quality color and what it is. The tile is a live item link -
  -- hover = tooltip, click = the item menu with every page, shift = AH
  -- search, alt = price to chat. Its width follows the text.
  local tile = CreateFrame("Button", nil, ct.field, "BackdropTemplate")
  tile:SetPoint("TOPLEFT", TILE_X, -TILE_Y); tile:SetHeight(TILE_H)
  tile:SetFrameLevel(ct.canvas:GetFrameLevel() + 20)
  tile:SetBackdrop(T.FLAT)
  tile:SetBackdropColor(C.bg1[1], C.bg1[2], C.bg1[3], 0.97)
  tile:SetBackdropBorderColor(T.Unpack(C.borderlt))
  tile:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  ct.headIcon = tile:CreateTexture(nil, "ARTWORK")
  ct.headIcon:SetSize(30, 30); ct.headIcon:SetPoint("LEFT", 8, 0)
  ct.headIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  ct.headName = T.Text(tile, T.SIZE.h1 + 1, "text", T.FONT_SEMI)
  ct.headName:SetPoint("TOPLEFT", ct.headIcon, "TOPRIGHT", 9, 1); ct.headName:SetJustifyH("LEFT")
  ct.headMeta = T.Text(tile, T.SIZE.small, "muted", T.FONT_MED)
  ct.headMeta:SetPoint("BOTTOMLEFT", ct.headIcon, "BOTTOMRIGHT", 9, 0); ct.headMeta:SetJustifyH("LEFT")
  tile:SetScript("OnEnter", function(self)
    self:SetBackdropBorderColor(T.Unpack(C.accent))
    if ct.id and M.ShowItemTip then
      M.ShowItemTip(tostring(ct.id))
      if GameTooltip:IsShown() then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Click: every page of this item", 0.52, 0.48, 0.39)
        GameTooltip:Show()
      end
    end
  end)
  tile:SetScript("OnLeave", function(self)
    self:SetBackdropBorderColor(T.Unpack(C.borderlt))
    GameTooltip:Hide()
  end)
  tile:SetScript("OnClick", function()
    if not ct.id then return end
    local key = tostring(ct.id)
    if M.ModPostDown and M.ModPostDown() then M.PostItemStats(key)
    elseif M.ModSearchDown and M.ModSearchDown() then M.ItemShiftAction(key)
    else GameTooltip:Hide(); if M.ItemMenu then M.ItemMenu(key) end end
  end)
  tile:EnableMouseWheel(true)
  tile:SetScript("OnMouseWheel", function(_, d) fieldWheel(d) end)
  ct.head, ct.headBtn = tile, tile
  local sep = ct.tree:CreateTexture(nil, "ARTWORK")
  sep:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.6)
  sep:SetWidth(1); sep:SetPoint("TOPRIGHT", -(SIDE_W + 8), 0); sep:SetPoint("BOTTOMRIGHT", -(SIDE_W + 8), FOOT_H)
  ct.side = CreateFrame("Frame", nil, ct.tree)
  ct.side:SetPoint("TOPRIGHT", 0, 0); ct.side:SetPoint("BOTTOMRIGHT", 0, FOOT_H)
  ct.side:SetWidth(SIDE_W)
  if M.LinkBar then
    ct.links = M.LinkBar(ct.side, { except = "tree", watch = true, short = true, wrap = true })
  end
  local fdiv = ct.tree:CreateTexture(nil, "ARTWORK")
  fdiv:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.6)
  fdiv:SetHeight(1); fdiv:SetPoint("BOTTOMLEFT", 0, FOOT_H - 4); fdiv:SetPoint("BOTTOMRIGHT", 0, FOOT_H - 4)
  buildFoot(ct.tree)

  -- item info arrives late: one redraw per burst
  local ev = CreateFrame("Frame")
  M.SafeRegister(ev, "GET_ITEM_INFO_RECEIVED")
  local pending
  ev:SetScript("OnEvent", function()
    if pending or not (ct.panel and ct.panel:IsVisible()) then return end
    pending = true
    C_Timer.After(0.4, function()
      pending = nil
      if ct.results and ct.results:IsShown() then fillResults() end
      M.RefreshCrafting()
    end)
  end)
end

function M.HideCraftPopups()
  if ct.results then ct.results:Hide() end
  if ct.pop then ct.pop:Hide() end
  if ct.peek then ct.peek:Hide() end
end

function M.RefreshCrafting()
  if not (ct.panel and ct.panel:IsVisible()) then return end
  local on = M.CraftingOn()
  if ct.onCb then ct.onCb:SetChecked(on) end
  for _, c in ipairs(ct.ctrl or {}) do c:SetShown(on) end
  if ct.off then ct.off:SetShown(not on) end
  if not on then
    ct.tree:Hide(); ct.top:Hide()
    M.HideCraftPopups()
    return
  end
  ct.mob:SetChecked(not (M.db.config and M.db.config.craftBuyOnly))
  ct.profBtn.text:SetText(ct.prof and M.ProfName(ct.prof) or "All professions")
  ct.back:SetAlpha((#ct.hist > 0 or ct.id) and 1 or 0.4)
  ct.fwdBtn:SetAlpha((#ct.fwd > 0) and 1 or 0.4)
  if not ct.id then
    ct.tree:Hide(); ct.top:Show()
    drawTop()
    return
  end
  ct.top:Hide(); ct.tree:Show()
  fillHead(ct.id)
  local ok, root, cc = drawTree()
  if not ok then
    -- first layout pass not done yet: retry once on the next frame
    if not ct.waited then
      ct.waited = true
      C_Timer.After(0, function() M.RefreshCrafting() end)
    end
    return
  end
  ct.waited = nil
  fillSide(ct.id)
  fillFoot(root, cc)
end

-- ===== Sneak peek: the tree as a small card (Charts tab) ====================
local function peekFrame()
  if ct.peek then return ct.peek end
  local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  f:SetFrameStrata("TOOLTIP")
  f:SetBackdrop(T.FLAT)
  f:SetBackdropColor(C.bg0[1], C.bg0[2], C.bg0[3], 0.97)
  f:SetBackdropBorderColor(T.Unpack(C.borderlt))
  if f.SetClampedToScreen then f:SetClampedToScreen(true) end
  f.title = T.Text(f, T.SIZE.small, "text", T.FONT_SEMI)
  f.title:SetPoint("TOPLEFT", 10, -8); f.title:SetJustifyH("LEFT")
  f.cap = T.Text(f, T.SIZE.tiny, "muted", T.FONT_SEMI)
  f.cap:SetPoint("TOPRIGHT", -10, -9); f.cap:SetJustifyH("RIGHT")
  f.box = CreateFrame("Frame", nil, f)
  f.box:SetPoint("TOPLEFT", 10, -28)
  if f.box.SetClipsChildren then f.box:SetClipsChildren(true) end
  f.content = CreateFrame("Frame", nil, f.box)
  f.l1 = T.Text(f, T.SIZE.small, "sub", T.FONT_MED); f.l1:SetJustifyH("LEFT")
  f.l2 = T.Text(f, T.SIZE.small, "sub", T.FONT_MED); f.l2:SetJustifyH("LEFT")
  f.l3 = T.Text(f, T.SIZE.tiny, "muted", T.FONT_MED); f.l3:SetJustifyH("LEFT")
  f.l1:SetPoint("TOPLEFT", f.box, "BOTTOMLEFT", 0, -8)
  f.l2:SetPoint("TOPLEFT", f.l1, "BOTTOMLEFT", 0, -3)
  f.l3:SetPoint("TOPLEFT", f.l2, "BOTTOMLEFT", 0, -6)
  f.cards, f.lines = {}, {}
  f:Hide()
  ct.peek = f
  return f
end

local function peekCard(f, i)
  local b = f.cards[i]
  if not b then
    b = CreateFrame("Frame", nil, f.content, "BackdropTemplate")
    b:SetSize(PEEK.w, PEEK.h)
    b:SetBackdrop(T.FLAT)
    b.qb = b:CreateTexture(nil, "ARTWORK"); b.qb:SetTexture(WHITE); b.qb:SetSize(26, 26); b.qb:SetPoint("LEFT", 4, 0)
    b.ic = b:CreateTexture(nil, "OVERLAY"); b.ic:SetSize(24, 24); b.ic:SetPoint("CENTER", b.qb, "CENTER")
    b.ic:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.name = T.Text(b, T.SIZE.tiny, "text", T.FONT_MED)
    b.name:SetPoint("TOPLEFT", b.qb, "TOPRIGHT", 5, 0); b.name:SetWidth(PEEK.w - 40); b.name:SetJustifyH("LEFT")
    b.now = T.Text(b, T.SIZE.tiny, nil, T.FONT_SEMI)
    b.now:SetPoint("BOTTOMLEFT", b.qb, "BOTTOMRIGHT", 5, 0); b.now:SetTextColor(T.Unpack(C.teal))
    b.fair = T.Text(b, T.SIZE.tiny, nil, T.FONT_MED)
    b.fair:SetPoint("BOTTOMRIGHT", -5, 4); b.fair:SetJustifyH("RIGHT"); b.fair:SetTextColor(T.Unpack(C.purple))
    f.cards[i] = b
  end
  b:Show()
  return b
end

-- the tree of `id` as a small card under `owner`; nil when no recipe makes it
function M.CraftPeek(owner, id)
  id = tonumber(id)
  if not (owner and id and M.CraftingOn() and M.Recipes().byItem[id]) then
    if ct.peek then ct.peek:Hide() end
    return nil
  end
  local f = peekFrame()
  for _, c in ipairs(f.cards) do c:Hide() end
  for _, t in ipairs(f.lines) do t:Hide() end
  local root, cc = buildTree(id, {}, 40)
  local L = M.CraftTreeLayout(root, 0, 0, PEEK)
  -- shrink a big tree down to 70%, then show its item end (the right side)
  local z = max(0.7, min(1, PEEK_W / L.w, PEEK_H / L.h))
  local bw, bh = min(L.w * z, PEEK_W), min(L.h * z, PEEK_H)
  local cut = (L.w * z > PEEK_W + 1) or (L.h * z > PEEK_H + 1)
  f.box:SetSize(bw, bh)
  f.content:SetScale(z)
  f.content:SetSize(L.w, L.h)
  local oy = max(0, min(L.h * z - bh, (root.y + PEEK.h / 2) * z - bh / 2))
  f.content:ClearAllPoints()
  f.content:SetPoint("TOPRIGHT", f.box, "TOPRIGHT", 0, oy / z)
  for i, n in ipairs(L.cards) do
    local b = peekCard(f, i)
    b.ic:SetTexture(iconOf(n.id))
    local r, g, bl = qcolor(n.id)
    b.qb:SetVertexColor(r, g, bl, 1)
    local nm = known(n.id) and nameOf(n.id) or "?"
    local made = n.e and n.e.how == "make"
    b:SetBackdropColor(T.Unpack(n.dim and C.bg0 or C.bg1))
    b:SetBackdropBorderColor(T.Unpack((n.root and C.accent) or (made and C.mint) or C.border))
    b:SetAlpha(n.dim and 0.6 or 1)
    if n.root then
      b.name:SetText(nm)
      b.now:SetText(money(cc and cc.now))
      b.fair:SetText(money(cc and cc.fair))
    else
      b.name:SetText("\195\151" .. qtyTxt(n.need) .. "  " .. nm)
      b.now:SetText(money(n.e.cost and n.e.cost * n.need))
      b.fair:SetText(money(n.ef.cost and n.ef.cost * n.need))
    end
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", f.content, "TOPLEFT", n.x, -n.y)
  end
  drawSegs(f.content, f.lines, L.segs)
  -- the verdict under the tree, now and fair
  local rs = rootSave(id, cc)
  local function verdict(col, make, buy)
    local s = col .. "make " .. money(make) .. "|r"
    if buy and make then
      s = s .. SEP .. col .. "buy " .. money(buy) .. "|r" .. SEP
      if buy >= make then s = s .. GRNH .. "crafting saves " .. money(buy - make) .. "|r"
      else s = s .. REDH .. "buying saves " .. money(make - buy) .. "|r" end
    end
    return s
  end
  f.title:SetText(known(id) and nameOf(id) or "?")
  f.title:SetTextColor(qcolor(id))
  f.cap:SetText("CRAFT TREE  \194\183  " .. MUTH .. "now|r  " .. PURH .. "fair|r")
  f.l1:SetText(verdict(GOLDH, cc and cc.now, rs.buyNow))
  f.l2:SetText(verdict(PURH, cc and cc.fair, rs.buyFair))
  f.l3:SetText((cut and "part of the tree  \194\183  " or "") .. "click to open the full tree in the Crafting tab")
  local w = max(bw, 330)
  f:SetSize(w + 20, 28 + bh + 8 + 14 + 3 + 14 + 6 + 12 + 10)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -4)
  f:Show()
  return f
end

function M.HideCraftPeek()
  if ct.peek then ct.peek:Hide() end
end

-- /midas tree [item name | link | id]
function M.CraftSlash(arg)
  arg = arg or ""
  if not M.CraftingOn() then
    M.Print("Crafting (beta) is switched off - tick \"Enable crafting\" in the Crafting tab or Settings > Crafting (beta).")
    M.EnsureUI(); M.frame:Show(); M.SelectTab(M.TAB.Crafting)
    return
  end
  local id = tonumber(arg) or tonumber(arg:match("item:(%d+)"))
  if not id and arg ~= "" then
    local q = arg:lower()
    for _, cid in ipairs(candidates()) do
      if nameOf(cid):lower() == q then id = cid; break end
    end
    if not id then
      for _, cid in ipairs(candidates()) do
        if nameOf(cid):lower():find(q, 1, true) then id = cid; break end
      end
    end
    if not id then M.Print("No recipe item or material called \"" .. arg .. "\".") return end
  end
  M.ShowCraftTree(id)
end
