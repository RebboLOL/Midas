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
local floor, ceil, min, max, abs = math.floor, math.ceil, math.min, math.max, math.abs

local CARD_W, CARD_H = 204, 70
local COL_GAP, ROW_GAP = 46, 8
local SIDE_W, FOOT_H, TOP_H = 236, 78, 34
local BAR_ROW = 24        -- the second row of the bar, when the switches need one
-- the item at the root, named on its own tile floating in the field's top
-- left corner; the tree keeps the whole field and starts below the tile
local TILE_X, TILE_Y, TILE_H = 10, 10, 50
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
local ACCH = hexc(C.accent)

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
    -- "Buy unknown" bought it: making would save this, but nobody knows the recipe
    if e.barred then
      return MUTH .. "would save|r " .. GOLDH .. money(sN) .. "|r" .. (sF and ("  " .. PURH .. money(sF) .. "|r") or "")
    end
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

-- Your make / buy choices (table view): they belong to the item at the root,
-- config.craftForce[rootID] = { [materialID] = "make" | "buy" }, and count for
-- its tree, table and footer; Top crafts and the tooltips keep the cheapest way.
local function forceOf(id)
  local all = M.db and M.db.config and M.db.config.craftForce
  local fc = all and id and all[id]
  return (fc and next(fc) ~= nil) and fc or nil
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
  ct.tblOff = 0               -- and its table from the top
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
-- The tree is drawn at full size into the child of a scroll frame. Dragging
-- the field moves the tree with the pointer; the bars on the right and at the
-- bottom move it by dragging the thumb, clicking the track or the wheel over
-- them. The tree zooms: the scroll child is scaled, so everything here counts
-- in tree units and the field covers more of them the further you zoom out
-- (mouse wheel over the field, - / + / Fit in its corner).
local ZOOM_MIN, ZOOM_MAX, ZOOM_FIT_MIN = 0.2, 1.5, 0.1
local zoomBy                -- set below the tree drawing

local function viewSize()
  local z = ct.zoom or 1
  return (ct.canvas:GetWidth() or 0) / z, (ct.canvas:GetHeight() or 0) / z
end

local function maxScroll()
  local W, H = viewSize()
  local mh, mv = (ct.contentW or W) - W, (ct.contentH or H) - H
  return (mh > 0.5) and mh or 0, (mv > 0.5) and mv or 0
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

-- How far the tree may leave the field: dragging (and zooming) moves it past
-- its own edges as long as one card keeps KEEP_X by KEEP_Y pixels in view, so
-- it can sit anywhere in the field but never gets lost. The scroll child
-- carries that room as a margin around the layout (ct.free and ct.rects, set
-- by drawTree); ct.hs / ct.vs keep counting from the layout's own top left
-- corner and may go below 0 or above the bar range.
local KEEP_X, KEEP_Y = 80, 40

local function keepSize()
  local z = ct.zoom or 1
  return min(KEEP_X / z, CARD_W), min(KEEP_Y / z, CARD_H)
end

local function freeRange()
  local f = ct.free
  local mh, mv = maxScroll()
  if not f then return 0, mh, 0, mv end
  return min(0, f.hlo), max(mh, f.hhi), min(0, f.vlo), max(mv, f.vhi)
end

-- a position that shows no card (the corner of a tree is often empty) moves
-- the shortest way to the next card
local function keepCard(hs, vs)
  local rects = ct.rects
  if not rects or #rects == 0 then return hs, vs end
  local W, H = viewSize()
  local kx, ky = keepSize()
  local best, bx, by
  for _, r in ipairs(rects) do
    local lo, hi = r.x + kx - W, r.x + CARD_W - kx
    local dx = (hs < lo) and (lo - hs) or ((hs > hi) and (hi - hs) or 0)
    lo, hi = r.y + ky - H, r.y + CARD_H - ky
    local dy = (vs < lo) and (lo - vs) or ((vs > hi) and (hi - vs) or 0)
    local d = abs(dx) + abs(dy)
    if d == 0 then return hs, vs end
    if not best or d < best then best, bx, by = d, dx, dy end
  end
  return hs + bx, vs + by
end

-- one axis of a scroll: a given value stays inside the bar range unless the
-- move is free (a drag, a zoom); a kept axis (new = nil) stays where a drag
-- left it (ct[key] remembers that it sits past the bar range) and otherwise
-- follows the bar range, so a tree that got smaller comes back into view
local function scrollAxis(new, cur, m, lo, hi, free, key)
  if new ~= nil and not free then ct[key] = nil; return max(0, min(new, m)) end
  local val = new or cur or 0
  if new == nil and not ct[key] then return max(0, min(val, m)) end
  return max(lo, min(val, hi))
end

-- scroll to h / v (nil keeps that axis) and move both bars along. free = the
-- whole range of a drag; without it a given value stays inside the bar range.
local function setScroll(h, v, free)
  if not ct.canvas then return end
  local mh, mv = maxScroll()
  local hlo, hhi, vlo, vhi = freeRange()
  ct.hs = scrollAxis(h, ct.hs, mh, hlo, hhi, free, "looseH")
  ct.vs = scrollAxis(v, ct.vs, mv, vlo, vhi, free, "looseV")
  -- past the bar range (dragged there): one card stays in view; inside it an
  -- empty part of the tree may stay, a quiet click on the field moves nothing
  if ct.hs < 0 or ct.hs > mh or ct.vs < 0 or ct.vs > mv then
    ct.hs, ct.vs = keepCard(ct.hs, ct.vs)
  end
  ct.looseH = (ct.hs < 0 or ct.hs > mh) or nil
  ct.looseV = (ct.vs < 0 or ct.vs > mv) or nil
  ct.canvas:SetHorizontalScroll(ct.hs - hlo)
  ct.canvas:SetVerticalScroll(ct.vs - vlo)
  local W, H = viewSize()
  placeBar(ct.hbar, max(0, min(ct.hs, mh)), mh, W, ct.contentW)
  placeBar(ct.vbar, max(0, min(ct.vs, mv)), mv, H, ct.contentH)
end

-- the item (the right end of the tree) in view, its card in the middle
local function scrollHome()
  local _, H = viewSize()
  local mh = maxScroll()
  setScroll(mh, (ct.rootY or 0) + CARD_H / 2 - H / 2)
end

-- the wheel over the field zooms around the mouse pointer
local function fieldWheel(d)
  -- table view (the heading floats over it too): the wheel scrolls the rows
  if ct.view == "table" then
    if ct.tblWheel then ct.tblWheel(d) end
    return
  end
  zoomBy(d, true)
end

-- dragging with the left button moves the tree with the pointer - from the
-- empty field or from a card
local function panStop()
  if ct.pan then ct.panAt = GetTime and GetTime() end
  ct.pan = nil
  if ct.canvas then ct.canvas:SetScript("OnUpdate", nil) end
end

local function panUpdate()
  local p = ct.pan
  if not p then return end
  if not IsMouseButtonDown("LeftButton") then panStop(); return end
  local x, y = GetCursorPosition()
  local k = (ct.canvas:GetEffectiveScale() or 1) * (ct.zoom or 1)
  setScroll(p.hs - ((x or 0) - p.x) / k, p.vs + ((y or 0) - p.y) / k, true)
end

local function panStart()
  if not ct.canvas then return end
  local x, y = GetCursorPosition()
  ct.pan = { x = x or 0, y = y or 0, hs = ct.hs or 0, vs = ct.vs or 0 }
  GameTooltip:Hide()
  ct.canvas:SetScript("OnUpdate", panUpdate)
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
  if bar.set then bar.set(frac); return end
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

-- A bar moves the tree field unless it brings its own get / set / wheel (the
-- side column's bar): get() = position and range, set(frac) = scroll to that
-- share of the range, wheel(d) = one wheel step.
local function newBar(parent, horiz)
  local bar = CreateFrame("Frame", nil, parent)
  bar.horiz = horiz
  bar:EnableMouse(true)
  bar:EnableMouseWheel(true)
  local bg = bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(); bg:SetColorTexture(C.bg2[1], C.bg2[2], C.bg2[3], 1)
  bar.bg = bg
  bar.thumb = bar:CreateTexture(nil, "ARTWORK")
  bar.thumb:SetColorTexture(T.Unpack(C.borderlt))
  bar.thumb:Hide()
  bar:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" or not self.thumb:IsShown() then return end
    local c = barCursor(self)
    local pos, maxPos
    if self.get then
      pos, maxPos = self.get()
    else
      local mh, mv = maxScroll()
      pos, maxPos = self.horiz and ct.hs or ct.vs, self.horiz and mh or mv
      pos = max(0, min(pos or 0, maxPos))     -- a tree dragged past its edge: the thumb sits at its end
    end
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
    if self.wheel then self.wheel(d); return end
    local z = ct.zoom or 1
    if self.horiz then setScroll((ct.hs or 0) - d * 60 / z, nil) else setScroll(nil, (ct.vs or 0) - d * 40 / z) end
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
    if e.forced then
      tip:AddLine("Your choice in the table: " .. ((e.forced == "make") and "make it" or "buy it"),
        C.accent[1], C.accent[2], C.accent[3])
    end
  end
  if n.unknown then
    tip:AddLine((n.e and n.e.barred) and "Bought: none of your characters knows this recipe"
      or "None of your characters knows this recipe", C.red[1], C.red[2], C.red[3])
  end
  tip:AddLine("Click: focus \194\183  right-click: all pages of the item", 0.52, 0.48, 0.39)
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
  b.tag:SetPoint("BOTTOMLEFT", 7, 6); b.tag:SetJustifyH("LEFT"); b.tag:SetWordWrap(false)
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
    if ct.pan then return end
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
    -- the release that ends a drag is no click
    if ct.pan then return end
    local at = ct.panAt
    if at and GetTime and GetTime() - at < 0.1 then return end
    if self.node then itemClick(self.node.id, button) end
  end)
  -- a drag that starts on a card moves the tree like one on the empty field
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnDragStart", panStart)
  b:SetScript("OnDragStop", panStop)
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
-- material stays folded (+) until you open it. fc = your make / buy choices.
local function buildTree(rootId, expanded, maxNodes, fc)
  expanded, maxNodes = expanded or ct.expanded, maxNodes or MAX_NODES
  local cc = M.CraftCost(rootId, nil, fc)
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

-- ===== Recipes nobody knows =================================================
-- A step of the chain that none of your characters can craft shows as a red
-- card: the item itself, a material counted as made, and a material opened to
-- see how it is made. Nothing is marked before the first profession window
-- was read - until then Midas cannot tell.
local UNKNOWN_BG = { 0.27, 0.06, 0.05 }

local function knownSet()
  if not (M.db and M.db.crafts and next(M.db.crafts)) then return nil end
  return M.CraftKnownItems() or {}
end

local function recipeUnknown(n, kset)
  if not kset then return false end
  local crafted
  if n.root then crafted = n.rec ~= nil
  else crafted = (n.e and (n.e.how == "make" or n.e.barred)) or n.open end   -- barred: "Buy unknown" bought it
  return (crafted and not kset[n.id]) and true or false
end
M.CraftRecipeUnknown = recipeUnknown

-- ===== Tree drawing =========================================================
local function setCard(b, n)
  b.node = n
  local id = n.id
  b.ic:SetTexture(iconOf(id))
  local r, g, bl = qcolor(id)
  b.qb:SetVertexColor(r, g, bl, 1)
  b.name:SetText(known(id) and nameOf(id) or "?")
  local kn = n.root and #(M.CraftKnownBy(id)) > 0
  n.unknown = recipeUnknown(n, ct.kset)
  b.border = (n.unknown and C.red) or (kn and C.green) or (n.root and C.accent)
    or ((n.e and n.e.how == "make") and C.mint) or C.border
  b:SetBackdropColor(T.Unpack(n.unknown and UNKNOWN_BG or (n.dim and C.bg0 or C.bg1)))
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
    -- gold: your own choice in the table view
    b.tag:SetTextColor(T.Unpack((n.e.forced and C.accent) or ((n.e.how == "make") and C.mint)
      or (n.e.src and C.muted) or C.red))
    b.save:SetText(saveTxt(n.e, n.ef, n.need))
  end
  -- the name shares its row with the quantity badge
  b.name:SetWidth(max(40, CARD_W - 57 - (b.qty:GetStringWidth() or 30) - 6))
  -- bottom line: the saving keeps its room, the tag is cut to what is left
  -- (a long profession name next to both savings would run into them)
  local sw = ((b.save:GetText() or "") ~= "") and ((b.save:GetStringWidth() or 0) + 8) or 0
  local room = CARD_W - 14 - sw
  if room < 24 then b.tag:SetText(""); room = 24 end
  b.tag:SetWidth(room)
  if not n.root and n.craftable then
    b.ex.t:SetText(n.open and "\226\136\146" or "+")
    b.ex:Show()
  else
    b.ex:Hide()
  end
  b:ClearAllPoints()
  b:SetPoint("TOPLEFT", ct.content, "TOPLEFT", n.x + (ct.ox or 0), -n.y - (ct.oy or 0))
end

-- orthogonal connectors from a layout, drawn into `content` from `pool`;
-- `thick` = line width in tree units (2 by default, more when zoomed far out
-- so a line stays a full pixel), `ox` / `oy` = where the layout starts in it
local function drawSegs(content, pool, segs, thick, ox, oy)
  local th = thick or 2
  ox, oy = ox or 0, oy or 0
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
      t:SetPoint("TOPLEFT", content, "TOPLEFT", min(s[1], s[3]) + ox, -s[2] + th / 2 - oy)
      t:SetSize(max(1, abs(s[3] - s[1])), th)
    else
      t:SetPoint("TOPLEFT", content, "TOPLEFT", s[1] - th / 2 + ox, -min(s[2], s[4]) - oy)
      t:SetSize(th, max(1, abs(s[4] - s[2])))
    end
  end
end

-- the main view's geometry at the current zoom: the title tile is not zoomed,
-- so the room it needs on top grows in tree units as the tree shrinks
local ZGEO = setmetatable({}, { __index = GEO })

-- the zoom at which the whole tree fits a field of Wp x Hp pixels below the
-- title tile; never above 100%
local function fitZoom(root, Wp, Hp)
  ZGEO.padTop = 0
  local L = M.CraftTreeLayout(root, 0, 0, ZGEO)
  local z = min(1, Wp / L.w, max(1, Hp - GEO.padTop) / L.h)
  return max(ZOOM_FIT_MIN, floor(z * 1000) / 1000)
end

local function zoomLook()
  if not ct.zoomPct then return end
  ct.zoomPct:SetText(floor((ct.zoom or 1) * 100 + 0.5) .. "%")
  local b = ct.zoomFit
  b:SetBackdropBorderColor(T.Unpack(ct.fit and C.accent or C.border))
  b.text:SetTextColor(T.Unpack(ct.fit and C.accent or C.text))
end

local function drawTree()
  local Wp, Hp = ct.canvas:GetWidth(), ct.canvas:GetHeight()
  if not Wp or Wp < 50 then return false end
  for _, b in ipairs(ct.cards) do b:Hide() end
  for _, t in ipairs(ct.lines) do t:Hide() end
  local root, cc = buildTree(ct.id, nil, nil, ct.force)
  ct.cc = cc
  ct.kset = knownSet()
  if ct.fit then ct.zoom = fitZoom(root, Wp, Hp) end
  local z = ct.zoom or 1
  ct.content:SetScale(z)
  ZGEO.padTop = GEO.padTop / z
  local L = M.CraftTreeLayout(root, Wp / z, Hp / z, ZGEO)
  ct.contentW, ct.contentH, ct.rootX, ct.rootY = L.w, L.h, root.x, root.y
  -- room to drag the tree past its edges: the scroll range that leaves a
  -- strip of the cards' bounding box in view, kept as a margin around the
  -- layout (setScroll then holds on to one card inside it)
  local bx0, bx1, by0, by1 = math.huge, -math.huge, math.huge, -math.huge
  ct.rects = {}
  for i, n in ipairs(L.cards) do
    ct.rects[i] = { x = n.x, y = n.y }
    bx0, bx1 = min(bx0, n.x), max(bx1, n.x + CARD_W)
    by0, by1 = min(by0, n.y), max(by1, n.y + CARD_H)
  end
  local vw, vh = Wp / z, Hp / z
  local kx, ky = keepSize()
  ct.free = { hlo = bx0 + kx - vw, hhi = bx1 - kx, vlo = by0 + ky - vh, vhi = by1 - ky }
  local hlo, hhi, vlo, vhi = freeRange()
  local mh, mv = maxScroll()
  ct.ox, ct.oy = -hlo, -vlo
  ct.content:SetSize(L.w + ct.ox + (hhi - mh), L.h + ct.oy + (vhi - mv))
  for i, n in ipairs(L.cards) do setCard(card(i), n) end
  drawSegs(ct.content, ct.lines, L.segs, max(2, 1 / z), ct.ox, ct.oy)
  if ct.home then
    ct.home = nil
    scrollHome()
  else
    setScroll()
  end
  zoomLook()
  return true, root, cc
end

-- ===== Zoom =================================================================
-- The zoom stays as you set it (config.craftZoom); Fit is a mode of its own
-- (config.craftFit): every tree is shown whole until - / + take over again.
local function saveZoom()
  local cfg = M.db and M.db.config
  if not cfg then return end
  cfg.craftFit = ct.fit and true or nil
  cfg.craftZoom = (not ct.fit and abs((ct.zoom or 1) - 1) > 0.001) and ct.zoom or nil
end

-- zoom to z; the tree point under (ax, ay) stays where it is - field pixels
-- from the canvas' top left corner, the middle of the field by default
local function setZoom(z, ax, ay)
  if not (ct.canvas and ct.id) then return end
  local old = ct.zoom or 1
  ax = ax or (ct.canvas:GetWidth() or 0) / 2
  ay = ay or (ct.canvas:GetHeight() or 0) / 2
  local relX = (ct.hs or 0) + ax / old - (ct.rootX or 0)
  local relY = (ct.vs or 0) + ay / old - (ct.rootY or 0)
  ct.zoom, ct.fit = max(ZOOM_MIN, min(ZOOM_MAX, z)), nil
  saveZoom()
  if not drawTree() then return end
  setScroll((ct.rootX or 0) + relX - ax / ct.zoom, (ct.rootY or 0) + relY - ay / ct.zoom, true)
  if ct.pan then panStart() end   -- zoomed while dragging: the drag goes on from here
end

-- one step of 10% in (dir > 0) or out; atCursor = around the mouse pointer
zoomBy = function(dir, atCursor)
  if not (ct.canvas and ct.id) then return end
  local old = ct.zoom or 1
  local z
  if dir > 0 then z = (floor(old * 10 + 1e-6) + 1) / 10 else z = (ceil(old * 10 - 1e-6) - 1) / 10 end
  z = max(ZOOM_MIN, min(ZOOM_MAX, z))
  -- at the end of the range (a fitted tree may sit below the smallest step)
  if (dir > 0 and z <= old) or (dir <= 0 and z >= old) then return end
  local ax, ay
  if atCursor then
    local x, y = GetCursorPosition()
    local sc = ct.canvas:GetEffectiveScale() or 1
    ax = (x or 0) / sc - (ct.canvas:GetLeft() or 0)
    ay = (ct.canvas:GetTop() or 0) - (y or 0) / sc
  end
  setZoom(z, ax, ay)
end

-- Fit on: the whole tree in the field; Fit off: back to 100%, item in view
local function toggleFit()
  if not (ct.canvas and ct.id) then return end
  if ct.fit then ct.fit, ct.zoom = nil, 1 else ct.fit = true end
  saveZoom()
  ct.home = true
  drawTree()
end

-- ===== Side column: used in / disenchants into / from disenchanting =========
local QUAL = { [2] = "Uncommon", [3] = "Rare", [4] = "Epic" }

-- an enchant (no product): the game's spell tooltip, then what its
-- materials cost - each line now (gold) and fair (purple)
local function enchTip(rec)
  local tip = GameTooltip
  if not M.frame then tip:Hide(); return end
  tip:SetOwner(M.frame, "ANCHOR_NONE")
  tip:ClearAllPoints()
  if (M.frame:GetRight() or 0) + 300 > GetScreenWidth() then
    tip:SetPoint("TOPRIGHT", M.frame, "TOPLEFT", -6, -2)
  else
    tip:SetPoint("TOPLEFT", M.frame, "TOPRIGHT", 6, -2)
  end
  local ok = tip.SetSpellByID and pcall(tip.SetSpellByID, tip, rec.spell)
  if not ok or (tip:NumLines() or 0) == 0 then tip:SetText(M.EnchantName(rec.spell), 1, 1, 1) end
  tip:AddLine(" ")
  tip:AddLine("|cffE8B44AMidas|r  " .. M.ProfName(rec.prof) .. "  -  materials, now  fair")
  local ec = M.EnchantCost(rec.spell)
  for i, mt in ipairs(rec.mats) do
    local n = (ec and ec.mat[1][i]) and money(ec.mat[1][i]) or "?"
    local f = (ec and ec.mat[2][i]) and money(ec.mat[2][i]) or "?"
    tip:AddDoubleLine(mt.n .. "x " .. nameOf(mt.id), GOLDH .. n .. "|r  " .. PURH .. f .. "|r",
      0.78, 0.76, 0.70, 1, 1, 1)
  end
  if ec then
    local part = ec.complete and "" or "  " .. MUTH .. "(partial)|r"
    tip:AddDoubleLine("Total" .. part, tipMoney(ec.now, ec.fair), 1, 1, 1, 1, 1, 1)
  end
  local who = M.CraftKnownBy(rec.spell, true)
  if #who > 0 then
    tip:AddLine("known by " .. table.concat(who, ", "), 0.36, 0.82, 0.47)
  end
  tip:Show()
end

-- the side column scrolls as one piece: mouse wheel, or the bar on its right
-- edge once it is longer than the column - a slim thumb in a wider strip
-- that takes the mouse (drag the thumb, click the strip to jump there)
local SIDE_BAR = 10
local function sideMax()
  return max(0, (ct.sideH or 0) - (ct.side:GetHeight() or 0))
end

local function sideScroll(v)
  if not ct.sideScroll then return end
  local H = ct.side:GetHeight() or 0
  local maxV = sideMax()
  ct.sideOff = max(0, min(v or 0, maxV))
  ct.sideScroll:SetVerticalScroll(ct.sideOff)
  local bar = ct.sideBar
  if not bar then return end
  local th = bar.thumb
  if maxV <= 0 or H <= 0 then
    bar.len, bar.track = 0, H
    th:Hide(); bar:Hide()
    return
  end
  local len = max(24, H * H / ct.sideH)
  th:ClearAllPoints()
  th:SetSize(4, len)
  th:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, -(H - len) * ct.sideOff / maxV)
  th:Show()
  bar.len, bar.track = len, H
  bar:Show()
end
M.CraftSideScroll = sideScroll

local function sideRow(i)
  local r = ct.sideRows[i]
  if not r then
    r = CreateFrame("Button", nil, ct.sideBody)
    r:SetHeight(22)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r.ic = r:CreateTexture(nil, "ARTWORK"); r.ic:SetSize(18, 18); r.ic:SetPoint("LEFT", 0, 0)
    r.ic:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.l = T.Text(r, T.SIZE.small, "text", T.FONT_MED); r.l:SetPoint("LEFT", r.ic, "RIGHT", 6, 0)
    r.l:SetJustifyH("LEFT")
    r.r = T.Text(r, T.SIZE.tiny, "sub", T.FONT_MED); r.r:SetPoint("RIGHT", 0, 0); r.r:SetJustifyH("RIGHT")
    local hl = r:CreateTexture(nil, "BACKGROUND"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.05); hl:Hide()
    r:SetScript("OnEnter", function(self)
      hl:Show()
      if self.ench then enchTip(self.ench)
      elseif self.id and M.ShowItemTip then M.ShowItemTip(tostring(self.id)) end
    end)
    r:SetScript("OnLeave", function() hl:Hide(); GameTooltip:Hide() end)
    r:SetScript("OnClick", function(self, button) if self.id and not self.ench then itemClick(self.id, button) end end)
    ct.sideRows[i] = r
  end
  r:ClearAllPoints(); r:Show()
  return r
end

local function sideHead(i)
  local h = ct.sideHeads[i]
  if not h then
    h = T.Text(ct.sideBody, T.SIZE.tiny, "muted", T.FONT_SEMI)
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
  if ct.sideFor ~= id then ct.sideFor, ct.sideOff = id, 0 end
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
    ct.links:SetPoint("TOPLEFT", ct.sideBody, "TOPLEFT", 0, -y)
    ct.links:SetItem(tostring(id), SIDE_W - SIDE_BAR)
    if ct.links:IsShown() then y = y + (ct.links.h or 20) + 12 end
  end
  local function row(rid, left, right, rc)
    if nr >= 400 then return false end
    nr = nr + 1
    local r = sideRow(nr)
    r:SetPoint("TOPLEFT", 0, -y); r:SetPoint("RIGHT", ct.sideBody, "RIGHT", 0, 0)
    r.id, r.ench = rid, nil
    r.ic:SetTexture(rid and iconOf(rid) or QMARK); r.ic:SetShown(rid ~= nil)
    r.l:SetWidth(SIDE_W - SIDE_BAR - 24 - 70); r.l:SetText(left)
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
  -- enchants: no product, so no profit - what the materials cost, A-Z
  local ench = Rx.enchIn[id]
  if ench then
    local list = {}
    for _, rec in ipairs(ench) do
      local ec = M.EnchantCost(rec.spell)
      list[#list + 1] = { rec = rec, nm = M.EnchantName(rec.spell), c = ec and ec.now, ok = ec and ec.nowOk }
    end
    table.sort(list, function(a, b) if a.nm ~= b.nm then return a.nm < b.nm end return a.rec.spell < b.rec.spell end)
    head("ENCHANTS  \194\183  " .. #list .. "  \194\183  MATS NOW")
    for _, e in ipairs(list) do
      if not row(nil, e.nm, e.c and ((e.ok and "" or "~") .. money(e.c)) or "-", e.c and C.teal or C.muted) then
        break
      end
      local r = ct.sideRows[nr]
      r.ench, r.id = e.rec, e.rec.spell
      r.ic:SetTexture(M.EnchantIcon(e.rec.spell)); r.ic:Show()
      r.l:SetTextColor(T.Unpack(C.text))
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
  -- as long as its content: the scroll range; room for the thumb when it scrolls
  ct.sideH = y
  local H = ct.side:GetHeight() or 0
  ct.sideBody:SetSize((y > H) and (SIDE_W - SIDE_BAR) or SIDE_W, max(1, y))
  sideScroll(ct.sideOff)
end

-- ===== Footer ===============================================================
-- The answer first, in words: make it or buy it, and what crafting to sell
-- earns. Next to it the numbers behind that as a small table - for as many
-- items as set in its corner (1 = one item), now (gold) over Fair (purple) -
-- every column and row explained on hover. For more than one item the bottom
-- line checks your newest full scan: is enough of each material you buy
-- listed, and how far do the prices climb when you buy them all.
local GRID_X = 300
local QTY_MAX = 9999
local FOOT_COLS = {
  { key = "make", x = 44,  w = 86,  head = "MAKE", tip = { "Make",
    "What the materials cost for the items set on the left (1 = one item) - each material bought or made from its own materials, whichever is cheaper (Make or buy). A craft that makes several items is divided by its yield." } },
  { key = "buy",  x = 134, w = 86,  head = "BUY", tip = { "Buy",
    "What buying the items costs: the cheaper of a merchant's price and the cheapest listing of your newest scan (FAIR row: its Fair price)." } },
  { key = "save", x = 224, w = 128, head = "MAKING SAVES", tip = { "Making saves",
    "Buy minus make: what crafting them yourself saves over buying them, then that as a share of the buy price. Red = buying is the cheaper way." } },
  { key = "sell", x = 356, w = 118, head = "SELL AFTER CUT", tip = { "Sell after the cut",
    "What the items bring on the auction house after the 5% AH cut (FAIR row: sold at its Fair price)." } },
  { key = "prof", x = 478, w = 128, head = "PROFIT EACH", tip = { "Profit",
    "Sell after the cut minus make: what crafting the items to sell earns, then that as a share of the material cost." } },
}
local FOOT_ROWS = {
  { key = "now",  label = "NOW",  y = -21, color = "teal", tip = { "Now",
    "At the prices of your newest scan - what you pay and get today (Fair where an item is not listed)." } },
  { key = "fair", label = "FAIR", y = -38, color = "purple", tip = { "Fair",
    "At Fair prices - what each item is really worth, the purple line everywhere in Midas. Steadier than today's listings." } },
}
local fillFoot            -- the quantity box redraws the footer (defined below)

-- how many items the footer counts for (the box in the table's corner; it
-- stays when another item opens and starts at 1 after a reload)
local function qtyN() return ct.qty or 1 end

local function setQty(v, typing)
  v = floor(tonumber(v) or 0)
  if v < 1 then v = 1 elseif v > QTY_MAX then v = QTY_MAX end
  local changed = (v ~= qtyN())
  ct.qty = v
  if not typing and ct.qtyEdit then ct.qtyEdit:SetText(tostring(v)) end
  if changed and ct.view == "table" and ct.redrawTable then ct.redrawTable() end   -- the rows count for it too
  if changed and ct.footCC and fillFoot then fillFoot(ct.footRoot, ct.footCC) end
end

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
      "The line below says what crafting to sell earns after the 5% AH cut. The table on the right shows every number behind it, now and at Fair, for as many items as set in its corner." }, "ANCHOR_TOP")
  end
  local vs = g:CreateTexture(nil, "ARTWORK")
  vs:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.6)
  vs:SetWidth(1); vs:SetPoint("TOPLEFT", GRID_X - 12, -2); vs:SetHeight(52)
  -- how many items: type a number or turn the mouse wheel
  local qb = T.Surface(g, "bg0", "border")
  qb:SetSize(36, 17); qb:SetPoint("TOPLEFT", GRID_X - 3, -2)
  local qe = CreateFrame("EditBox", nil, qb)
  qe:SetPoint("TOPLEFT", 3, 0); qe:SetPoint("BOTTOMRIGHT", -3, 0)
  T.RegFont(qe, T.FONT_MED, T.SIZE.small); qe:SetTextColor(T.Unpack(C.text))
  qe:SetJustifyH("CENTER"); qe:SetAutoFocus(false)
  qe:SetNumeric(true); qe:SetMaxLetters(4)
  qe:SetText("1")
  qe:EnableMouseWheel(true)
  qe:SetScript("OnTextChanged", function(self, user)
    local t = self:GetText() or ""
    if user and t ~= "" then setQty(t, true) end
  end)
  qe:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  qe:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  qe:SetScript("OnEditFocusGained", function(self)
    qb:SetBackdropBorderColor(T.Unpack(C.accent)); self:HighlightText()
  end)
  qe:SetScript("OnEditFocusLost", function(self)
    qb:SetBackdropBorderColor(T.Unpack(C.border)); self:HighlightText(0, 0)
    setQty(self:GetText())                       -- an empty or 0 box goes back to 1
  end)
  qe:SetScript("OnMouseWheel", function(_, d) setQty(qtyN() + d) end)
  ct.qtyBox, ct.qtyEdit = qb, qe
  ct.qtyLab = T.Text(g, T.SIZE.tiny, "muted", T.FONT_SEMI)
  ct.qtyLab:SetPoint("LEFT", qb, "RIGHT", 5, 0); ct.qtyLab:SetText("ITEM")
  if T.HelpTip then
    T.HelpTip(qe, "How many", {
      "How many items to make. The table and the lines next to it show the totals for this many, at the same prices as for one: now (gold) and Fair (purple).",
      "For more than one, the line at the bottom checks your newest full scan: whether enough of each material you buy is listed, and how far its price climbs when you buy them all.",
      "Type a number or turn the mouse wheel over the box." }, "ANCHOR_TOP")
  end
  ct.footHeads = {}
  for _, c in ipairs(FOOT_COLS) do
    local h = T.Text(g, T.SIZE.tiny, "muted", T.FONT_SEMI)
    h:SetPoint("TOPLEFT", GRID_X + c.x, -6); h:SetWidth(c.w); h:SetJustifyH("RIGHT"); h:SetText(c.head)
    ct.footHeads[c.key] = h
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
  ct.known:SetPoint("BOTTOMRIGHT", 0, 2); ct.known:SetWordWrap(false)   -- one line, cut at the window edge
end

local function cellMoney(fs, v, col)
  if v then fs:SetText(col .. money(v) .. "|r") else fs:SetText(MUTH .. "-|r") end
end

-- buying the materials for n items at the listings of your newest full scan:
-- how far the prices climb over each material's cheapest listing, and which
-- materials are not listed in that number. nil for one item, { noScan = true }
-- without a full scan on this realm.
local function listingCheck(id, n)
  if n <= 1 or not (M.CraftNeeds and M.DepthCost) then return nil end
  local needs = M.CraftNeeds(id, n, nil, ct.force)
  if not needs then return nil end
  local ah = 0
  for _, t in pairs(needs) do
    if t.src == "ah" and t.units > 0 then ah = ah + 1 end
  end
  if ah == 0 then return nil end                      -- nothing bought on the AH: nothing to check
  if not M.HasDepth() then return { noScan = true } end
  local res = { climb = 0, short = {}, checked = 0 }     -- checked: materials bought on the AH
  for mid, t in pairs(needs) do
    if t.src == "ah" and t.units > 0 then
      res.checked = res.checked + 1
      local dc = M.DepthCost(mid, t.units)
      if not dc then
        res.short[#res.short + 1] = { id = mid, got = 0, want = ceil(t.units - 1e-6) }
      else
        res.climb = res.climb + dc.climb
        if dc.listed < dc.want then res.short[#res.short + 1] = { id = mid, got = dc.listed, want = dc.want } end
      end
    end
  end
  table.sort(res.short, function(a, b)
    local ma, mb = a.want - a.got, b.want - b.got
    if ma ~= mb then return ma > mb end
    return a.id < b.id
  end)
  return res
end

-- how many of your make / buy choices work on the way the calculation takes
-- (not those under a material that is bought); 0 without choices
local function choicesOnRoute(cc)
  local memo = ct.force and cc and cc.memo and cc.memo[1]
  if not (memo and cc.rec) then return 0 end
  local seen, nF = {}, 0
  local function walk(mid)
    if seen[mid] then return end
    seen[mid] = true
    local e = memo[mid]
    if not e then return end
    if e.forced then nF = nF + 1 end
    if e.how == "make" and e.rec then
      for _, mt in ipairs(e.rec.mats) do walk(mt.id) end
    end
  end
  for _, mt in ipairs(cc.rec.mats) do walk(mt.id) end
  return nF
end

function fillFoot(root, cc)
  local id = ct.id
  ct.footRoot, ct.footCC = root, cc
  local p = M.CraftProfit(id, nil, ct.force)
  if not (p and cc) then
    ct.footGrid:Hide()
    ct.noRecipe:Show()
    ct.known:SetText("")
    return
  end
  ct.footGrid:Show()
  ct.noRecipe:Hide()
  local n = qtyN()
  if ct.qtyEdit and not ct.qtyEdit:HasFocus() then ct.qtyEdit:SetText(tostring(n)) end
  ct.qtyLab:SetText((n == 1) and "ITEM" or "ITEMS")
  ct.footHeads.prof:SetText((n == 1) and "PROFIT EACH" or "PROFIT")
  local function times(v) return v and v * n end
  local rs = rootSave(id, cc)
  -- the table: n items, now over Fair
  local rows = {
    now  = { make = times(cc.now),  buy = times(rs.buyNow),  sell = times(p.sellNow),  prof = times(p.now),  pct = p.nowPct,  col = GOLDH },
    fair = { make = times(cc.fair), buy = times(rs.buyFair), sell = times(p.sellFair), prof = times(p.fair), pct = p.fairPct, col = PURH },
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
  local many = (n > 1) and (" " .. n) or ""
  local note = ""
  if d == "make" then
    ct.verdict:SetText(GRNH .. "MAKE IT|r")
    -- for more than one the share stays in the table (the line would not fit)
    ct.why1:SetText(GRNH .. money((by - mk) * n) .. "|r cheaper than buying" .. many
      .. ((by > 0 and n == 1) and string.format("%s  (%.0f%% less)|r", MUTH, (by - mk) / by * 100) or ""))
  elseif d == "buy" then
    ct.verdict:SetText(REDH .. "BUY IT|r")
    ct.why1:SetText("buying" .. many .. " is " .. REDH .. money((mk - by) * n) .. "|r cheaper"
      .. ((mk > 0 and n == 1) and string.format("%s  (%.0f%% less)|r", MUTH, (mk - by) / mk * 100) or ""))
  else
    local mc = cc.now or cc.fair
    ct.verdict:SetText(MUTH .. "NOTHING TO COMPARE|r")
    ct.why1:SetText("making " .. ((n > 1) and tostring(n) or "one") .. " costs " .. GOLDH .. money(mc and mc * n) .. "|r"
      .. MUTH .. "  - no buy price yet|r")
  end
  if atFair and d then note = "at Fair prices - nothing listed today"
  elseif dNow and dFair and dNow ~= dFair then
    note = (dFair == "make") and "at Fair prices: make it" or "at Fair prices: buy it"
  end
  ct.verdictNote:SetText(note)
  local pr, pfair = p.now, false
  if not pr then pr, pfair = p.fair, true end
  if pr and n > 1 then
    ct.why2:SetText(n .. " crafted to sell: " .. ((pr >= 0) and GRNH or REDH) .. signed(pr * n) .. "|r"
      .. MUTH .. (pfair and " at Fair" or "") .. " after the AH cut|r")
  elseif pr then
    ct.why2:SetText("crafted to sell: " .. ((pr >= 0) and GRNH or REDH) .. signed(pr) .. "|r each"
      .. MUTH .. (pfair and " at Fair" or "") .. " after the 5% AH cut|r")
  else
    ct.why2:SetText(MUTH .. "no AH price to sell it at yet|r")
  end
  local parts = {}
  -- missing prices first: the line is cut at the window edge
  if not cc.nowOk then parts[#parts + 1] = REDH .. "some material prices are missing - the totals are partial|r" end
  -- your own make / buy choices count here (set in the table view)
  local nF = choicesOnRoute(cc)
  if nF > 0 then
    parts[#parts + 1] = ACCH .. nF .. ((nF == 1) and " material" or " materials") .. " made or bought by your choice (Table)|r"
  end
  -- more than one: does the newest full scan list enough of what you buy?
  local lc = listingCheck(id, n)
  if lc and lc.noScan then
    parts[#parts + 1] = MUTH .. "a full scan shows whether enough is listed for " .. n .. "|r"
  elseif lc and lc.checked > 0 then
    local s = lc.short[1]
    if s then
      parts[#parts + 1] = REDH .. ((s.got > 0) and ("only " .. s.got .. " of " .. s.want .. " " .. nameOf(s.id) .. " listed")
        or (nameOf(s.id) .. " not listed")) .. ((#lc.short > 1) and (" (+" .. (#lc.short - 1) .. " more)") or "") .. "|r"
    end
    if lc.climb >= 1 then
      parts[#parts + 1] = "buying them all climbs the listings by " .. GOLDH .. money(lc.climb) .. "|r"
    elseif not s then
      parts[#parts + 1] = GRNH .. "enough listed at the cheapest prices|r"
    end
  end
  -- how much of the saving comes from making materials instead of buying them
  local direct = (not (M.db.config and M.db.config.craftBuyOnly)) and M.CraftCost(id, false)
  local extra = direct and direct.now and cc.now and (direct.now - cc.now)
  if extra and extra >= 1 then
    local ef = direct.fair and cc.fair and (direct.fair - cc.fair)
    -- with choices of yours some CRAFT tags are gold, not green
    parts[#parts + 1] = ((nF > 0) and "materials you make yourself (CRAFT cards) cut the cost by "
      or "materials you make yourself (green CRAFT cards) cut the cost by ") .. GOLDH .. money(extra * n) .. "|r"
      .. (ef and ("  " .. PURH .. money(ef * n) .. "|r") or "")
  end
  local who = M.CraftKnownBy(id)
  if #who > 0 then
    parts[#parts + 1] = GRNH .. "recipe known by " .. table.concat(who, ", ") .. "|r"
  else
    parts[#parts + 1] = MUTH .. "no character of yours knows the recipe yet (open the profession window once)|r"
  end
  -- red cards among the materials: steps of the chain nobody can craft yet
  local missing = 0
  local function count(nd)
    for _, c in ipairs(nd.children or {}) do
      if c.unknown then missing = missing + 1 end
      count(c)
    end
  end
  if root then count(root) end
  if missing > 0 then
    parts[#parts + 1] = REDH .. "red cards: " .. missing .. ((missing == 1) and " material recipe" or " material recipes")
      .. " not known|r"
  end
  ct.known:SetText(table.concat(parts, SEP))
end

-- ===== Title tile of the field ==============================================
-- icon + name of the item at the root (quality color), below it what it is:
-- profession and yield for a recipe item, the number of uses for a material
local function fillHead(id)
  if not (ct.head and id) then return end
  ct.headIcon:SetTexture(iconOf(id))
  local qr, qg, qb = qcolor(id)
  ct.headQb:SetVertexColor(qr, qg, qb, 1)
  ct.headName:SetText(known(id) and nameOf(id) or ("Item #" .. id))
  ct.headName:SetTextColor(qr, qg, qb)
  local Rx = M.Recipes()
  local recs = Rx.byItem[id]
  local meta
  if recs then
    local rec = recs[1]
    local y = (rec.lo == rec.hi) and tostring(rec.lo) or (rec.lo .. "-" .. rec.hi)
    meta = M.ProfName(rec.prof) .. "  \194\183  makes " .. y
    if #recs > 1 then meta = meta .. "  \194\183  " .. #recs .. " recipes" end
  else
    local n, ne = M.UsedInCount(id)
    meta = "material" .. ((n + ne > 0) and ("  \194\183  used in " .. M.UsedInText(n, ne)) or "")
  end
  ct.headMeta:SetText(meta)
  local tw = max(ct.headName:GetStringWidth() or 120, ct.headMeta:GetStringWidth() or 80)
  local full = (ct.headName.GetUnboundedStringWidth or ct.headName.GetStringWidth)
  local fullM = (ct.headMeta.GetUnboundedStringWidth or ct.headMeta.GetStringWidth)
  tw = max(tw, full(ct.headName) or 0, fullM(ct.headMeta) or 0)   -- a name cut before keeps its full width here
  -- the switches in the field's top right corner keep their room: a long name is cut
  local room = ct.headRoom and ct.headRoom()
  if room and 6 + 38 + 10 + tw + 12 > room then tw = max(40, room - (6 + 38 + 10 + 12)) end
  ct.headName:SetWidth(ceil(tw) + 2); ct.headMeta:SetWidth(ceil(tw) + 2)   -- + 2: no "..." from pixel rounding
  ct.head:SetWidth(floor(6 + 38 + 10 + tw + 12 + 0.5))
end

-- ===== Top crafts (start view) ==============================================
-- ITEM always, every other column chosen under "Columns" (config.craftCols
-- keeps only what differs from the defaults). A click on a column header
-- sorts the list by it, highest first (config.craftSort, nil = by profit).
-- A column that does not fit next to a readable item name stays out, and the
-- Columns list marks it.
local TOP_ROWH = 34
local TOP_ITEM_W, TOP_ITEM_MIN = 250, 170
local TOP_COLS = {
  { key = "prof", head = "PROFESSION", w = 120, align = "LEFT", on = true,
    tip = { "Profession", "The profession that makes the item." } },
  { key = "mats", head = "MATS", w = 110, on = true, sort = true, by = "material cost",
    tip = { "Materials", "What the materials for one item cost with your Make or buy setting, now (gold) over Fair (purple)." } },
  { key = "ah", head = "AH", w = 110, on = true, sort = true, by = "AH price",
    tip = { "Auction house", "What one item sells for on the AH before the 5% cut, now over Fair." } },
  { key = "profit", head = "PROFIT", w = 150, on = true, sort = true, by = "profit",
    tip = { "Profit", "What crafting one to sell earns after the 5% AH cut, with your Make or buy setting, then that as a share of the material cost." } },
  { key = "pbuy", head = "PROFIT \194\183 BUY MATS", w = 150, sort = true, by = "profit with bought materials",
    tip = { "Profit, materials bought", "Like Profit, but every material is bought - what the craft earns without making anything on the way." } },
  { key = "pmake", head = "PROFIT \194\183 MAKE OR BUY", w = 150, sort = true, by = "profit with make or buy",
    tip = { "Profit, make or buy", "Like Profit, but each material is bought or made from its own materials, whichever is cheaper - whatever the Make or buy switch says. Buy unknown still narrows it to the recipes your characters know." } },
  { key = "margin", head = "MARGIN", w = 80, sort = true, by = "margin",
    tip = { "Margin", "The profit as a share of the material cost, with your Make or buy setting: materials for 1g that bring 2g after the cut make +100%." } },
  { key = "saves", head = "MAKING SAVES", w = 120, sort = true, by = "making saves",
    tip = { "Making saves", "Buying one minus making one: what crafting it yourself saves over buying the item. Red = buying is the cheaper way." } },
  { key = "sells", head = "SELLS", w = 80, on = true, sort = true, by = "sales per day",
    tip = { "Sells", "Your own sales of the item per day, once you have sold it a few times." } },
}

-- "Known recipes": Top crafts and the profession list show only what one of
-- your characters can make (config.craftKnownOnly)
local function knownOnly()
  return (M.db and M.db.config and M.db.config.craftKnownOnly) == true
end

local function colOn(c)
  local cfg = M.db and M.db.config and M.db.config.craftCols
  local v = cfg and cfg[c.key]
  if v == nil then return c.on == true end
  return v == true
end

local function setColOn(c, on)
  local cfg = M.db.config
  on = on and true or false
  cfg.craftCols = cfg.craftCols or {}
  if on == (c.on == true) then cfg.craftCols[c.key] = nil else cfg.craftCols[c.key] = on end
  if next(cfg.craftCols) == nil then cfg.craftCols = nil end
  -- a list sorted by a column you hide goes back to the profit order
  if not on and cfg.craftSort == c.key then cfg.craftSort = nil end
end

local function sortKey()
  local k = M.db and M.db.config and M.db.config.craftSort
  for _, c in ipairs(TOP_COLS) do
    if c.key == k and c.sort then return k, c end
  end
  return "profit"
end

-- where the shown columns sit for a list W pixels wide: what does not fit
-- goes from the right, never the column the list is sorted by
-- { itemW, cols = { def, ... }, x = { [key] = x }, dropped = { [key] = true }, sig }
local function topLayout(W)
  if not W or W <= 0 then W = 2000 end           -- not laid out yet: everything fits
  local cols, sum = {}, 0
  for _, c in ipairs(TOP_COLS) do
    if colOn(c) then cols[#cols + 1] = c; sum = sum + c.w end
  end
  local dropped, sk = {}, sortKey()
  for i = #cols, 1, -1 do
    if W - sum >= TOP_ITEM_MIN then break end
    local c = cols[i]
    if c.key ~= sk then
      table.remove(cols, i)
      sum = sum - c.w
      dropped[c.key] = true
    end
  end
  local L = { itemW = max(TOP_ITEM_MIN, min(TOP_ITEM_W, W - sum)), cols = cols, x = {}, dropped = dropped }
  local x, sig = L.itemW, { tostring(L.itemW) }
  for _, c in ipairs(cols) do
    L.x[c.key] = x
    x = x + c.w
    sig[#sig + 1] = c.key
  end
  L.sig = table.concat(sig, ",")
  return L
end

-- a row's extra numbers, worked out once per entry (TopCrafts builds new
-- entries whenever prices or the switches change)
local function routeProfit(e, mob)
  local k = mob and "_pmake" or "_pbuy"
  if e[k] == nil then
    local q = M.CraftProfit(e.id, mob)
    e[k] = (q and q.now and { q.now, q.fair, q.nowPct, q.fairPct, q.cost.nowOk }) or false
  end
  return e[k] or nil
end

local function makeSaves(e)
  if e._saves == nil then
    local cc = e.profit.cost
    local bN, bF = M.UnitPrice(e.id)
    e._saves = { bN and cc.now and (bN - cc.now), bF and cc.fair and (bF - cc.fair) }
  end
  return e._saves
end

local function sortVal(e, key)
  local p = e.profit
  if key == "mats" then return p.cost.now
  elseif key == "ah" then return p.sellNow
  elseif key == "margin" then return p.nowPct
  elseif key == "sells" then return e.speed
  elseif key == "saves" then return makeSaves(e)[1]
  elseif key == "pbuy" or key == "pmake" then
    local q = routeProfit(e, key == "pmake")
    return q and q[1]
  end
  return p.now
end

-- the list in the chosen order, highest first, items without a value last
local function sortedTop(list, key)
  if key == "profit" then return list end        -- TopCrafts ranks by profit already
  local s = ct.topSort
  if s and s.src == list and s.key == key then return s.out end
  local out = {}
  for i, e in ipairs(list) do
    out[i] = e
    e._sv = sortVal(e, key)
  end
  table.sort(out, function(a, b)
    local va, vb = a._sv, b._sv
    if va == nil or vb == nil then
      if (va == nil) ~= (vb == nil) then return vb == nil end
      return a.id < b.id
    end
    if va ~= vb then return va > vb end
    return a.id < b.id
  end)
  ct.topSort = { src = list, key = key, out = out }
  return out
end

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
    r.name = T.Text(r, T.SIZE.body, "text", T.FONT_MED)
    r.name:SetPoint("LEFT", r, "LEFT", 30, 0); r.name:SetJustifyH("LEFT")
    r.cells = {}
    for _, def in ipairs(TOP_COLS) do
      local a = T.Text(r, T.SIZE.small, "text", T.FONT_MED)
      local b = T.Text(r, T.SIZE.tiny, nil, T.FONT_MED)
      a:SetWidth(def.w); a:SetJustifyH(def.align or "RIGHT")
      b:SetWidth(def.w); b:SetJustifyH(def.align or "RIGHT")
      b:SetTextColor(T.Unpack(C.purple))
      r.cells[def.key] = { a = a, b = b }
    end
    r:SetScript("OnEnter", function(self) self.hl:Show(); if self.id and M.ShowItemTip then M.ShowItemTip(tostring(self.id)) end end)
    r:SetScript("OnLeave", function(self) self.hl:Hide(); GameTooltip:Hide() end)
    r:SetScript("OnClick", function(self, button) if self.id then itemClick(self.id, button) end end)
    ct.topRows[i] = r
  end
  r:Show()
  return r
end

-- a row's cells where the layout wants them (only when the layout changed)
local function placeRow(r, L)
  if r.sig == L.sig then return end
  r.sig = L.sig
  r.name:SetWidth(L.itemW - 30)
  for _, def in ipairs(TOP_COLS) do
    local cell, x = r.cells[def.key], L.x[def.key]
    if x then
      cell.a:ClearAllPoints(); cell.a:SetPoint("TOPLEFT", r, "TOPLEFT", x, -3)
      cell.b:ClearAllPoints(); cell.b:SetPoint("TOPLEFT", r, "TOPLEFT", x, -17)
      cell.a:Show(); cell.b:Show()
    else
      cell.a:Hide(); cell.b:Hide()
    end
  end
end

local function profitCell(cell, now, fair, pn, pf, partial)
  cell.a:SetText(signed(now) .. pctTxt(pn))
  cell.a:SetTextColor(T.Unpack(partial and C.muted or (((now or 0) >= 0) and C.green or C.red)))
  cell.b:SetText(signed(fair) .. (pf and string.format(" (%+.0f%%)", pf * 100) or ""))
end

local function fillTopCell(cell, key, e)
  local p, cc = e.profit, e.profit.cost
  local a, b = cell.a, cell.b
  if key == "prof" then
    a:SetText(M.ProfName(e.prof)); a:SetTextColor(T.Unpack(C.sub)); b:SetText("")
  elseif key == "mats" then
    a:SetText(money(cc.now)); a:SetTextColor(T.Unpack(C.teal)); b:SetText(money(cc.fair))
  elseif key == "ah" then
    a:SetText(money(p.sellNow)); a:SetTextColor(T.Unpack(C.teal)); b:SetText(money(p.sellFair))
  elseif key == "profit" then
    profitCell(cell, p.now, p.fair, p.nowPct, p.fairPct)
  elseif key == "pbuy" or key == "pmake" then
    local q = routeProfit(e, key == "pmake")
    if q then
      profitCell(cell, q[1], q[2], q[3], q[4], not q[5])   -- grey: some material has no price
    else
      a:SetText("-"); a:SetTextColor(T.Unpack(C.muted)); b:SetText("")
    end
  elseif key == "margin" then
    local pn, pf = p.nowPct, p.fairPct
    a:SetText(pn and string.format("%+.0f%%", pn * 100) or "-")
    a:SetTextColor(T.Unpack(pn and ((pn >= 0) and C.green or C.red) or C.muted))
    b:SetText(pf and string.format("%+.0f%%", pf * 100) or "")
  elseif key == "saves" then
    local s = makeSaves(e)
    a:SetText(s[1] and signed(s[1]) or "-")
    a:SetTextColor(T.Unpack(s[1] and ((s[1] >= 0) and C.green or C.red) or C.muted))
    b:SetText(s[2] and signed(s[2]) or "")
  elseif key == "sells" then
    a:SetText(e.speed and string.format("~%.1f/day", e.speed) or "-"); a:SetTextColor(T.Unpack(C.sub))
    b:SetText("")
  end
end

-- the headers over the shown columns; the sorted one in the accent color
local function placeHeads(L, sk)
  local hd = ct.topHeads
  if not hd then return end
  hd.item:SetWidth(L.itemW - 30)
  for _, def in ipairs(TOP_COLS) do
    local h, x = hd[def.key], L.x[def.key]
    if x then
      h:ClearAllPoints(); h:SetPoint("TOPLEFT", ct.top, "TOPLEFT", x, -3)
      h.fs:SetTextColor(T.Unpack((def.key == sk) and C.accent or C.muted))
      h:Show()
    else
      h:Hide()
    end
  end
end

-- the Columns list: ticked = shown, "no room" = ticked but left out
local function fillColPop()
  local pop = ct.colPop
  if not pop then return end
  local L = ct.topLay or topLayout(ct.top and ct.top:GetWidth())
  local any = false
  for _, def in ipairs(TOP_COLS) do
    local cb = pop.boxes[def.key]
    cb:SetChecked(colOn(def))
    cb.note:SetText(L.dropped[def.key] and "no room" or "")
    if L.dropped[def.key] then any = true end
  end
  pop.hint:SetText("Click a column header to sort the list by it."
    .. (any and " Columns marked \"no room\" need a wider window." or ""))
  -- the hint wraps to more lines at a larger text size: the list grows with it
  local hh = pop.hint:GetStringHeight() or 0
  pop:SetHeight(22 + #TOP_COLS * 20 + 6 + max(28, ceil(hh)) + 8)
end

-- the list in the chosen order; "Known recipes" filters the sorted list (the
-- full list keeps its order cached, the filter is a quick pass)
local function topList(known, sk)
  local list = sortedTop(M.TopCrafts(ct.prof, nil, false), sk)
  if not known then return list end
  local set, f = M.CraftKnownItems() or {}, {}
  for _, e in ipairs(list) do
    if set[e.id] then f[#f + 1] = e end
  end
  return f
end

local function drawTop()
  local H = ct.top:GetHeight() or 380
  local known = knownOnly()
  local sk, sdef = sortKey()
  local list = topList(known, sk)
  local L = topLayout(ct.top:GetWidth())
  ct.topLay = L
  placeHeads(L, sk)
  local n = max(1, floor((H - 26 - 24) / TOP_ROWH))
  ct.topOff = max(0, min(ct.topOff, #list - n))
  for _, r in ipairs(ct.topRows) do r:Hide() end
  for i = 1, n do
    local e = list[i + ct.topOff]
    if not e then break end
    local r = topRow(i)
    r:SetPoint("TOPLEFT", ct.top, "TOPLEFT", 0, -26 - (i - 1) * TOP_ROWH)
    r:SetPoint("RIGHT", ct.top, "RIGHT", 0, 0)
    placeRow(r, L)
    r.id = e.id
    r.ic:SetTexture(iconOf(e.id))
    r.name:SetText(nameOf(e.id)); r.name:SetTextColor(qcolor(e.id))
    for _, def in ipairs(L.cols) do fillTopCell(r.cells[def.key], def.key, e) end
  end
  if #list == 0 then
    if not known then
      ct.topEmpty:SetText("No craft with market data yet - scan the AH to price materials and products.")
    elseif M.db.crafts and next(M.db.crafts) then   -- a profession window was read (enchants count too)
      ct.topEmpty:SetText("None of the recipes your characters know has market data here yet.")
    else
      ct.topEmpty:SetText("No known recipes yet - open each profession window once on every character.")
    end
  end
  ct.topEmpty:SetShown(#list == 0)
  ct.topCount:SetText(string.format("%d crafts with market data  \194\183  %s%s%s", #list,
    ct.prof and M.ProfName(ct.prof) or "all professions", known and "  \194\183  known recipes" or "",
    sdef and ("  \194\183  by " .. sdef.by) or ""))
  if ct.colPop and ct.colPop:IsShown() then fillColPop() end
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
  for id in pairs(Rx.enchIn) do
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
  local kset = knownOnly() and (M.CraftKnownItems() or {}) or nil
  for _, id in ipairs(Rx.items) do
    if not kset or kset[id] then
      local p = Rx.byItem[id][1].prof
      count[p] = (count[p] or 0) + 1
    end
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

-- ===== Table view ===========================================================
-- The same chain as the tree, one row per step, indented by level, for the
-- items set in the footer box: what making and what buying the step costs
-- (now over Fair; the way the calculation takes is bright, the other dim),
-- what making saves over buying, what making it to sell would earn, and on
-- the right your own choice for the material: Make or Buy. "Tree | Table" in
-- the field's top right corner switches the view (config.craftView).
local TBL_ROWH, TBL_HEAD, TBL_GAP = 30, 22, 8
local TBL_COLS = {
  { key = "make", head = "MAKE", w = 88, tip = { "Make",
    "What making the step costs for the items set in the footer box: its materials, each bought or made the way the calculation takes it. Bright = the way it is counted." } },
  { key = "buy", head = "BUY", w = 88, tip = { "Buy",
    "What buying the step costs: the cheaper of a merchant's price and the cheapest listing of your newest scan (lower line: at Fair). Bright = the way it is counted." } },
  { key = "save", head = "SAVES", w = 92, tip = { "Making saves",
    "Buy minus make for the step. Red = buying is the cheaper way." } },
  { key = "profit", head = "PROFIT", w = 96, tip = { "Profit",
    "What making the step to sell on the AH would earn after the 5% cut. On the item's own row: the profit of the craft." } },
  { key = "choice", head = "YOUR CHOICE", w = 108, tip = { "Your choice",
    "Make or Buy for this material. Your choice wins over Make or buy and Buy unknown and counts for this item's tree, table and footer; Top crafts and the tooltips keep the cheapest way.",
    "Click the way the calculation takes anyway to drop your choice." } },
}

-- the scroll range: every step plus the TOTAL row under the last one
local function tblMax()
  return max(0, #(ct.tblRows or {}) + 1 - (ct.tblFit or 1))
end

-- your choice for one material of the item at the root; the way the
-- calculation would take anyway is no choice and is not stored
local function setChoice(mid, want)
  local rootId = ct.id
  if not (rootId and mid and want) then return end
  local rest = {}
  for k, v in pairs(forceOf(rootId) or {}) do
    if k ~= mid then rest[k] = v end
  end
  local cc = M.CraftCost(rootId, nil, rest)
  local e = cc and cc.memo[1][mid]
  if not (e and e.how == want) then rest[mid] = want end
  local cfg = M.db.config
  cfg.craftForce = cfg.craftForce or {}
  cfg.craftForce[rootId] = (next(rest) ~= nil) and rest or nil
  if next(cfg.craftForce) == nil then cfg.craftForce = nil end
  M.RefreshCrafting()
end

local function tblRow(i)
  local r = ct.tblRowsF[i]
  if r then r:Show(); return r end
  r = CreateFrame("Button", nil, ct.tbl)
  r:SetHeight(TBL_ROWH - 2)
  r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints()
  r.hl = r:CreateTexture(nil, "BORDER"); r.hl:SetAllPoints(); r.hl:SetColorTexture(1, 1, 1, 0.05); r.hl:Hide()
  r.ic = r:CreateTexture(nil, "ARTWORK"); r.ic:SetSize(18, 18); r.ic:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  r.name = T.Text(r, T.SIZE.small, "text", T.FONT_MED); r.name:SetJustifyH("LEFT")
  r.qty = T.Text(r, T.SIZE.tiny, "muted", T.FONT_MED); r.qty:SetJustifyH("LEFT")
  r.cells = {}
  for _, c in ipairs(TBL_COLS) do
    if c.key ~= "choice" then
      local a = T.Text(r, T.SIZE.small, nil, T.FONT_MED)
      local b = T.Text(r, T.SIZE.tiny, nil, T.FONT_MED)
      a:SetWidth(c.w); a:SetJustifyH("RIGHT"); b:SetWidth(c.w); b:SetJustifyH("RIGHT")
      r.cells[c.key] = { a = a, b = b }
    end
  end
  r.none = T.Text(r, T.SIZE.tiny, "muted", T.FONT_MED); r.none:SetJustifyH("CENTER")
  r.seg = T.Segment(r, { { key = "make", label = "Make" }, { key = "buy", label = "Buy" } }, function(key)
    local nd = r.node
    if not nd or nd.root then return end
    if (key == "make" and not r.canMake) or (key == "buy" and not r.canBuy) then
      r.seg:Select(r.how)                       -- not possible for this material
      return
    end
    setChoice(nd.id, key)
  end)
  r.seg.frame:SetFrameLevel(r:GetFrameLevel() + 2)
  r:SetScript("OnEnter", function(self)
    self.hl:Show()
    if self.node and M.ShowItemTip then
      M.ShowItemTip(tostring(self.node.id))
      stepTip(self.node)
      local q = qtyN()
      if q > 1 and GameTooltip:IsShown() then
        GameTooltip:AddLine("The row counts for " .. q .. " items, the numbers above for one.", 0.52, 0.48, 0.39)
        GameTooltip:Show()
      end
    end
  end)
  r:SetScript("OnLeave", function(self) self.hl:Hide(); GameTooltip:Hide() end)
  r:SetScript("OnClick", function(self, button) if self.node then itemClick(self.node.id, button) end end)
  ct.tblRowsF[i] = r
  return r
end

local function moneyPair(cell, n, f, units, colN, colF)
  local a, b = cell.a, cell.b
  if n then
    a:SetText(money(n * units)); a:SetTextColor(T.Unpack(colN or C.teal))
    b:SetText(f and money(f * units) or ""); b:SetTextColor(T.Unpack(colF or C.purple))
  else
    a:SetText("-"); a:SetTextColor(T.Unpack(C.muted)); b:SetText("")
  end
end

local function signedPair(cell, n, f, units)
  local a, b = cell.a, cell.b
  if n then
    a:SetText(signed(n * units)); a:SetTextColor(T.Unpack((n >= 0) and C.green or C.red))
    b:SetText(f and signed(f * units) or ""); b:SetTextColor(T.Unpack(C.purple))
  else
    a:SetText("-"); a:SetTextColor(T.Unpack(C.muted)); b:SetText("")
  end
end

-- one row: a step of the chain for `q` items of the root
local function fillTblRow(r, nd, q, x, itemW)
  r.node = nd
  local units = (nd.need or 1) * q
  local indent = 4 + min(nd.depth or 0, 6) * 10
  r.ic:ClearAllPoints(); r.ic:SetPoint("LEFT", r, "LEFT", indent, 0)
  r.ic:SetTexture(iconOf(nd.id))
  -- the name on top, the amount on a small line of its own below it: a long
  -- name never hides the amount, and the name keeps the whole step column
  local nw = max(30, itemW - indent - 24 - 4)
  r.name:ClearAllPoints(); r.name:SetPoint("TOPLEFT", r, "TOPLEFT", indent + 24, -2)
  r.name:SetWidth(nw)
  r.name:SetText(known(nd.id) and nameOf(nd.id) or ("Item #" .. nd.id))
  r.name:SetTextColor(qcolor(nd.id))
  r.qty:ClearAllPoints(); r.qty:SetPoint("TOPLEFT", r, "TOPLEFT", indent + 24, -16)
  r.qty:SetWidth(nw)
  r.qty:SetText("\195\151" .. qtyTxt(units))
  nd.unknown = recipeUnknown(nd, ct.kset)
  if nd.unknown then r.bg:SetColorTexture(UNKNOWN_BG[1], UNKNOWN_BG[2], UNKNOWN_BG[3], 0.55)
  else r.bg:SetColorTexture(0, 0, 0, 0) end
  -- make and buy for one unit, now and fair; how = the way it is counted
  local mk, mkF, by, byF, how
  if nd.root then
    local cc = ct.cc
    local rs = rootSave(nd.id, cc)
    mk, mkF, by, byF, how = cc and cc.now, cc and cc.fair, rs.buyNow, rs.buyFair, "make"
  else
    local e, ef = nd.e or {}, nd.ef or {}
    mk, mkF, by, byF, how = e.make, ef.make, e.buy, ef.buy, e.how
    if not mk and nd.craftable then              -- not worked out on this route: its own cost
      local own = M.CraftCost(nd.id)
      if own then mk, mkF = own.now, own.fair end
    end
  end
  local dimC, dimF = { C.teal[1], C.teal[2], C.teal[3], 0.45 }, { C.purple[1], C.purple[2], C.purple[3], 0.45 }
  local mkOn, byOn = (how == "make"), (how ~= "make")
  moneyPair(r.cells.make, mk, mkF, units, (not mkOn) and dimC, (not mkOn) and dimF)
  moneyPair(r.cells.buy, by, byF, units, (not byOn) and dimC, (not byOn) and dimF)
  signedPair(r.cells.save, mk and by and (by - mk), mkF and byF and (byF - mkF), units)
  local sN, sF = M.SellPrice(nd.id)
  signedPair(r.cells.profit, mk and sN and (sN * 0.95 - mk), mkF and sF and (sF * 0.95 - mkF), units)
  -- the cells where the columns are
  for _, c in ipairs(TBL_COLS) do
    local cell, cx = r.cells[c.key], x[c.key]
    if cell then
      cell.a:ClearAllPoints(); cell.a:SetPoint("TOPLEFT", r, "TOPLEFT", cx, -2)
      cell.b:ClearAllPoints(); cell.b:SetPoint("TOPLEFT", r, "TOPLEFT", cx, -16)
    end
  end
  -- your choice: Make | Buy, gold frame when it is yours
  r.canMake = nd.craftable and true or false
  r.canBuy = by ~= nil
  r.how = how
  r.seg.frame:ClearAllPoints(); r.seg.frame:SetPoint("LEFT", r, "LEFT", x.choice + 2, 0)
  r.none:ClearAllPoints(); r.none:SetPoint("LEFT", r, "LEFT", x.choice, 0); r.none:SetWidth(TBL_COLS[5].w)
  if nd.root or not (r.canMake and r.canBuy) then
    r.seg.frame:Hide()
    r.none:SetText(nd.root and "" or (r.canMake and "make only" or "buy only"))
  else
    r.none:SetText("")
    r.seg.frame:Show()
    r.seg:Select(how)
    local mine = nd.e and nd.e.forced
    r.seg.frame:SetBackdropBorderColor(T.Unpack(mine and C.accent or C.border))
  end
end

-- the total at the bottom: the whole craft for the items set in the footer box.
-- The rows nest (a made material holds its own materials), so a plain column
-- sum would count twice: MAKE is everything you buy for it, BUY the items
-- themselves instead, then the saving and the profit.
local function sumTip(self)
  local i = self.info
  if not i then return end
  local tip = GameTooltip
  local L = { 0.78, 0.76, 0.70 }
  tip:SetOwner(self, "ANCHOR_TOP")
  tip:AddLine("Total for " .. i.q .. ((i.q == 1) and " item" or " items"), C.accent[1], C.accent[2], C.accent[3])
  tip:AddLine("Make: everything you buy for it - the same as the item's own row at the top. Buy: the items themselves instead.",
    C.sub[1], C.sub[2], C.sub[3], true)
  tip:AddLine(" ")
  tip:AddDoubleLine("Materials to buy", tostring(i.n), L[1], L[2], L[3], 1, 1, 1)
  if i.ah > 0 then tip:AddDoubleLine("Bought on the AH", GOLDH .. money(i.ah) .. "|r", L[1], L[2], L[3], 1, 1, 1) end
  if i.vendor > 0 then tip:AddDoubleLine("Bought from vendors", GOLDH .. money(i.vendor) .. "|r", L[1], L[2], L[3], 1, 1, 1) end
  if i.none > 0 then tip:AddDoubleLine("Without a price", REDH .. i.none .. "|r", L[1], L[2], L[3], 1, 1, 1) end
  tip:Show()
end

local function fillTblSum(x, itemW)
  local s, cc, id = ct.tblSum, ct.cc, ct.id
  if not (s and cc and id) then if s then s:Hide() end return end
  s:Show()
  local q = qtyN()
  local rs = rootSave(id, cc)
  local p = M.CraftProfit(id, nil, ct.force)
  s.name:SetWidth(max(40, itemW - 12)); s.sub:SetWidth(max(40, itemW - 12))
  s.name:SetText("TOTAL" .. ((q > 1) and ("  \195\151" .. q) or ""))
  -- the shopping list behind MAKE: how many materials, where they come from
  local needs = (M.CraftNeeds and M.CraftNeeds(id, q, nil, ct.force)) or {}
  local i = { q = q, n = 0, ah = 0, vendor = 0, none = 0 }
  for _, t in pairs(needs) do
    i.n = i.n + 1
    if not t.price then i.none = i.none + 1
    elseif t.src == "vendor" or t.src == "est" then i.vendor = i.vendor + t.price * t.units
    else i.ah = i.ah + t.price * t.units end
  end
  s.info = i
  s.sub:SetText(i.n .. ((i.n == 1) and " material to buy" or " materials to buy"))
  local dimC, dimF = { C.teal[1], C.teal[2], C.teal[3], 0.45 }, { C.purple[1], C.purple[2], C.purple[3], 0.45 }
  moneyPair(s.cells.make, cc.now, cc.fair, q)
  moneyPair(s.cells.buy, rs.buyNow, rs.buyFair, q, dimC, dimF)
  signedPair(s.cells.save, cc.now and rs.buyNow and (rs.buyNow - cc.now), cc.fair and rs.buyFair and (rs.buyFair - cc.fair), q)
  signedPair(s.cells.profit, p and p.now, p and p.fair, q)
  for _, c in ipairs(TBL_COLS) do
    local cell, cx = s.cells[c.key], x[c.key]
    if cell then
      cell.a:ClearAllPoints(); cell.a:SetPoint("TOPLEFT", s, "TOPLEFT", cx, -3)
      cell.b:ClearAllPoints(); cell.b:SetPoint("TOPLEFT", s, "TOPLEFT", cx, -17)
    end
  end
  local nF = choicesOnRoute(cc)
  s.choice:ClearAllPoints(); s.choice:SetPoint("LEFT", s, "LEFT", x.choice, 0); s.choice:SetWidth(TBL_COLS[5].w)
  s.choice:SetText((nF > 0) and (ACCH .. nF .. " set by you|r") or "cheapest way")
end

local function placeTblHeads(x, itemW)
  local hd = ct.tblHeads
  hd.item:SetWidth(itemW - 8)
  for _, c in ipairs(TBL_COLS) do
    local h = hd[c.key]
    h:ClearAllPoints(); h:SetPoint("TOPLEFT", ct.tbl, "TOPLEFT", x[c.key], -4)
  end
end

-- the table of ct.id; false while the field has no size yet (first frame)
local function drawTable()
  local W, H = ct.tbl:GetWidth() or 0, ct.tbl:GetHeight() or 0
  if W < 50 then return false end
  local root, cc = buildTree(ct.id, {}, MAX_NODES, ct.force)
  ct.cc = cc
  ct.kset = knownSet()
  local rows = {}
  local function walk(nd)
    rows[#rows + 1] = nd
    for _, c in ipairs(nd.children or {}) do walk(c) end
  end
  walk(root)
  ct.tblRows = rows
  -- columns from the right edge, the item takes what is left
  local inner = W - BAR - 6
  local x, right = {}, inner
  for i = #TBL_COLS, 1, -1 do
    local c = TBL_COLS[i]
    right = right - c.w
    x[c.key] = right
    right = right - TBL_GAP
  end
  local itemW = max(120, right)
  placeTblHeads(x, itemW)
  local fit = max(1, floor((H - TBL_HEAD - 4) / TBL_ROWH))
  ct.tblFit = fit
  ct.tblOff = max(0, min(ct.tblOff or 0, tblMax()))
  for _, r in ipairs(ct.tblRowsF) do r:Hide() end
  local q = qtyN()
  -- the TOTAL row hangs right under the last step and scrolls with the rows
  local sumSlot
  for i = 1, fit do
    local k = i + ct.tblOff
    local nd = rows[k]
    if not nd then
      if k == #rows + 1 then sumSlot = i end
      break
    end
    local r = tblRow(i)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", ct.tbl, "TOPLEFT", 0, -TBL_HEAD - (i - 1) * TBL_ROWH)
    r:SetPoint("RIGHT", ct.tbl, "RIGHT", -(BAR + 4), 0)
    fillTblRow(r, nd, q, x, itemW)
  end
  -- the steps out of view count for the footer's red-card line too
  for i, nd in ipairs(rows) do
    if i <= ct.tblOff or i > ct.tblOff + fit then nd.unknown = recipeUnknown(nd, ct.kset) end
  end
  placeBar(ct.tblBar, ct.tblOff, tblMax(), fit, #rows + 1)
  fillTblSum(x, itemW)
  local s = ct.tblSum
  s:ClearAllPoints()
  if sumSlot and cc then
    s:SetPoint("TOPLEFT", ct.tbl, "TOPLEFT", 0, -TBL_HEAD - (sumSlot - 1) * TBL_ROWH - 2)
    s:SetPoint("RIGHT", ct.tbl, "RIGHT", -(BAR + 4), 0)
    s:Show()
  else
    s:Hide()                                       -- scrolled away, below the rows in view
  end
  return true, root, cc
end

local function tblScroll(off)
  ct.tblOff = max(0, min(floor((off or 0) + 0.5), tblMax()))
  if ct.id and ct.view == "table" then drawTable() end
end

-- the table's frames, inside the field below its heading (built once)
local function buildTable(field)
  local t = CreateFrame("Frame", nil, field)
  t:SetPoint("TOPLEFT", 1, -(TILE_Y + TILE_H + 6)); t:SetPoint("BOTTOMRIGHT", -1, 1)
  t:SetFrameLevel(ct.canvas:GetFrameLevel() + 4)
  t:EnableMouseWheel(true)
  t:SetScript("OnMouseWheel", function(_, d) tblScroll((ct.tblOff or 0) - d * 3) end)
  t:Hide()
  ct.tbl, ct.tblRowsF = t, {}
  local hd = {}
  hd.item = T.Text(t, T.SIZE.tiny, "muted", T.FONT_SEMI)
  hd.item:SetPoint("TOPLEFT", 8, -8); hd.item:SetJustifyH("LEFT"); hd.item:SetText("STEP  \194\183  NEEDED")
  for _, c in ipairs(TBL_COLS) do
    local h = CreateFrame("Button", nil, t)
    h:SetSize(c.w, 16)
    h.fs = T.Text(h, T.SIZE.tiny, "muted", T.FONT_SEMI)
    h.fs:SetPoint("TOPLEFT", 0, -4); h.fs:SetWidth(c.w)
    h.fs:SetJustifyH((c.key == "choice") and "CENTER" or "RIGHT"); h.fs:SetText(c.head)
    if T.FitLabel then T.FitLabel(h.fs, c.w) end
    if T.HelpTip then
      local lines = { c.tip[2] }
      if c.tip[3] then lines[2] = c.tip[3] end
      T.HelpTip(h, c.tip[1], lines, "ANCHOR_TOP")
    end
    hd[c.key] = h
  end
  ct.tblHeads = hd
  local rule = t:CreateTexture(nil, "ARTWORK")
  rule:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.8)
  rule:SetHeight(1); rule:SetPoint("TOPLEFT", 4, -TBL_HEAD + 2); rule:SetPoint("TOPRIGHT", -(BAR + 4), -TBL_HEAD + 2)
  -- the total, right under the last step (drawTable places it)
  local s = CreateFrame("Button", nil, t)
  s:SetHeight(TBL_ROWH)
  local sbg = s:CreateTexture(nil, "BACKGROUND"); sbg:SetAllPoints()
  sbg:SetColorTexture(C.bg1[1], C.bg1[2], C.bg1[3], 0.9)
  local srule = s:CreateTexture(nil, "ARTWORK"); srule:SetColorTexture(T.Unpack(C.accent)); srule:SetHeight(1)
  srule:SetPoint("TOPLEFT", 4, 0); srule:SetPoint("TOPRIGHT", 0, 0)
  s.name = T.Text(s, T.SIZE.small, "accent", T.FONT_SEMI); s.name:SetPoint("TOPLEFT", 8, -3); s.name:SetJustifyH("LEFT")
  s.sub = T.Text(s, T.SIZE.tiny, "muted", T.FONT_MED); s.sub:SetPoint("TOPLEFT", 8, -17); s.sub:SetJustifyH("LEFT")
  s.cells = {}
  for _, c in ipairs(TBL_COLS) do
    if c.key ~= "choice" then
      local a = T.Text(s, T.SIZE.small, nil, T.FONT_SEMI)
      local b = T.Text(s, T.SIZE.tiny, nil, T.FONT_MED)
      a:SetWidth(c.w); a:SetJustifyH("RIGHT"); b:SetWidth(c.w); b:SetJustifyH("RIGHT")
      s.cells[c.key] = { a = a, b = b }
    end
  end
  s.choice = T.Text(s, T.SIZE.tiny, "muted", T.FONT_MED); s.choice:SetJustifyH("CENTER")
  s:SetScript("OnEnter", sumTip)
  s:SetScript("OnLeave", function() GameTooltip:Hide() end)
  s:Hide()
  ct.tblSum = s
  local bar = newBar(t, false)
  bar:SetPoint("TOPRIGHT", -1, -TBL_HEAD); bar:SetPoint("BOTTOMRIGHT", -1, 1); bar:SetWidth(BAR)
  bar.get = function() return ct.tblOff or 0, tblMax() end
  bar.set = function(frac) tblScroll(frac * tblMax()) end
  bar.wheel = function(d) tblScroll((ct.tblOff or 0) - d * 3) end
  ct.tblBar = bar
  ct.redrawTable = function()
    if not (ct.id and ct.view == "table") then return end
    drawTable()
  end
  ct.tblWheel = function(d) tblScroll((ct.tblOff or 0) - d * 3) end
end

-- what the heading may take of the field's width: the switches in its top
-- right corner keep their room (nil before the first layout)
ct.headRoom = function()
  local FW = ct.field and ct.field:GetWidth() or 0
  if FW <= 0 or not ct.viewSeg then return nil end
  local right = BAR + 10 + (ct.viewSeg.frame:GetWidth() or 0) + 8
  if ct.view == "table" then
    if ct.resetBtn and ct.resetBtn:IsShown() then right = right + (ct.resetBtn:GetWidth() or 0) + 8 end
  else
    right = right + 130 + 8                         -- the zoom box
  end
  return FW - TILE_X - right
end

-- Tree or Table: what the field shows; the switch sits in its top right corner
local function applyView()
  if not ct.tbl then return end
  local tbl = (ct.view == "table")
  ct.canvas:SetShown(not tbl)
  ct.vbar:SetShown(not tbl)
  ct.hbar:SetShown(not tbl)
  ct.zoomBox:SetShown(not tbl)
  ct.tbl:SetShown(tbl)
  ct.viewSeg:Select(ct.view)
  ct.viewSeg.frame:ClearAllPoints()
  ct.viewSeg.frame:SetPoint("TOPRIGHT", ct.field, "TOPRIGHT", -(BAR + 10) - (tbl and 0 or (130 + 8)), -TILE_Y - 2)
  ct.resetBtn:SetShown(tbl and forceOf(ct.id) ~= nil)
end

local function setView(key)
  ct.view = (key == "table") and "table" or "tree"
  M.db.config.craftView = (ct.view == "table") and "table" or nil
  ct.tblOff = 0
  M.RefreshCrafting()
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
  local prof = T.Button(panel, "All professions", 130, 22)
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
  -- "Buy unknown" narrows Make or buy to the recipes your characters know
  local buyUnk = T.Checkbox(panel, "Buy unknown", function(on)
    M.db.config.craftBuyUnknown = on and true or nil
    M.CraftCacheReset()
    ct.topOff = 0
    M.RefreshCrafting()
  end)
  buyUnk:SetPoint("RIGHT", mob, "LEFT", -14, 0)
  ct.buyUnk = buyUnk
  -- "Known recipes" sits in the bar next to them, so it is there in both views
  local knownCb = T.Checkbox(panel, "Known recipes", function(on)
    M.db.config.craftKnownOnly = on and true or nil
    ct.topOff = 0
    if ct.pop then ct.pop:Hide() end
    M.RefreshCrafting()
  end)
  knownCb:SetPoint("RIGHT", buyUnk, "LEFT", -16, 0)
  ct.knownCb = knownCb
  if T.HelpTip then
    T.HelpTip(buyUnk, "Buy unknown", {
      "On: a material is only counted as made when one of your characters knows its recipe. Every other material is bought, as long as it has a price.",
      "Off: Make or buy counts every recipe, known or not.",
      "Either way a red card in the tree marks a recipe none of your characters knows. Needs Make or buy." })
    T.HelpTip(knownCb, "Known recipes", {
      "On: Top crafts and the profession list show only what one of your characters can make.",
      "In the tree a red card marks a recipe none of your characters knows, whether this is on or off.",
      "Midas reads a character's recipes when you open its profession window, so open each one once." })
  end

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
  ct.ctrl = { ct.search, back, fwd, top, prof, mob, buyUnk, knownCb }
  -- three switches on the right: where the window is too narrow for one row
  -- (the default width, or a larger text size) they take a second row below
  -- it and the views start lower
  ct.fitBar = function()
    local W = panel:GetWidth() or 0
    if W <= 0 or not (ct.top and ct.tree and ct.off) then return end
    local left = 240 + 8 + 26 + 4 + 26 + 10 + 96 + 6 + 130 + 14 + 44 + 10 + (onCb:GetWidth() or 0)
    local right = 16 + (knownCb:GetWidth() or 0) + 16 + (buyUnk:GetWidth() or 0) + 14 + (mob:GetWidth() or 0) + 4
    local rows = (W >= left + right) and 1 or 2
    if rows == ct.barRows then return end
    ct.barRows = rows
    local drop = (rows - 1) * BAR_ROW
    mob:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -4 - drop)
    for _, v in ipairs({ ct.top, ct.tree, ct.off }) do v:SetPoint("TOPLEFT", 0, -(TOP_H + drop)) end
  end
  panel:HookScript("OnSizeChanged", ct.fitBar)
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
  -- column headers: a click sorts by the column, the tooltip explains it
  ct.topHeads = {}
  local ih = T.Text(ct.top, T.SIZE.tiny, "muted", T.FONT_SEMI)
  ih:SetPoint("TOPLEFT", 30, -6); ih:SetWidth(TOP_ITEM_W - 30); ih:SetJustifyH("LEFT"); ih:SetText("ITEM")
  ct.topHeads.item = ih
  for _, def in ipairs(TOP_COLS) do
    local h = CreateFrame("Button", nil, ct.top)
    h:SetSize(def.w, 14)
    h.fs = T.Text(h, T.SIZE.tiny, "muted", T.FONT_SEMI)
    h.fs:SetPoint("TOPLEFT", 0, -3); h.fs:SetWidth(def.w); h.fs:SetJustifyH(def.align or "RIGHT")
    h.fs:SetText(def.head)
    if T.FitLabel then T.FitLabel(h.fs, def.w) end
    if def.sort then
      h:SetScript("OnClick", function()
        M.db.config.craftSort = (def.key ~= "profit") and def.key or nil
        ct.topOff = 0
        drawTop()
      end)
    end
    if T.HelpTip then
      local lines = { def.tip[2] }
      if def.sort then lines[#lines + 1] = "Click to sort the list by this column, highest first." end
      T.HelpTip(h, def.tip[1], lines, "ANCHOR_TOP")
    end
    ct.topHeads[def.key] = h
  end
  -- Columns: which columns the list shows, in a small list above the button
  local colBtn = T.Button(ct.top, "Columns", 84, 18)
  colBtn:SetPoint("BOTTOMLEFT", 0, 0)
  ct.colBtn = colBtn
  local cpop = T.Surface(ct.top, "bg1", "borderlt")
  cpop:SetFrameStrata("DIALOG")
  cpop:SetPoint("BOTTOMLEFT", colBtn, "TOPLEFT", 0, 4)
  cpop:SetWidth(250)
  -- the list takes the mouse itself: no tooltip, click or wheel reaches the rows below
  cpop:EnableMouse(true)
  cpop:EnableMouseWheel(true)
  cpop:SetScript("OnMouseWheel", function() end)
  local cpt = T.Text(cpop, T.SIZE.tiny, "muted", T.FONT_SEMI)
  cpt:SetPoint("TOPLEFT", 10, -8); cpt:SetText("COLUMNS")
  cpop.boxes = {}
  for i, def in ipairs(TOP_COLS) do
    local cb = T.Checkbox(cpop, def.tip[1], function(on)
      setColOn(def, on)
      drawTop()
      fillColPop()
    end)
    cb:SetPoint("TOPLEFT", 10, -22 - (i - 1) * 20)
    cb.note = T.Text(cpop, T.SIZE.tiny, "red", T.FONT_MED)
    cb.note:SetPoint("RIGHT", cpop, "TOPRIGHT", -10, -31 - (i - 1) * 20)
    cpop.boxes[def.key] = cb
  end
  cpop.hint = T.Text(cpop, T.SIZE.tiny, "muted", T.FONT_MED)
  cpop.hint:SetPoint("TOPLEFT", 10, -22 - #TOP_COLS * 20 - 6)
  cpop.hint:SetWidth(230); cpop.hint:SetJustifyH("LEFT"); cpop.hint:SetWordWrap(true)
  cpop:SetHeight(22 + #TOP_COLS * 20 + 6 + 28 + 8)
  cpop:Hide()
  ct.colPop = cpop
  colBtn:SetScript("OnClick", function()
    if cpop:IsShown() then cpop:Hide() else fillColPop(); cpop:Show() end
  end)
  -- a click anywhere else closes the list
  local cev = CreateFrame("Frame")
  if M.SafeRegister and M.SafeRegister(cev, "GLOBAL_MOUSE_DOWN") then
    cev:SetScript("OnEvent", function()
      if cpop:IsShown() and not cpop:IsMouseOver() and not colBtn:IsMouseOver() then cpop:Hide() end
    end)
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
  -- a wider or narrower window fits the columns anew
  ct.top:SetScript("OnSizeChanged", function(self)
    if self:IsVisible() and M.CraftingOn() and not ct.id then drawTop() end
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
  ct.canvas:EnableMouse(true)
  ct.canvas:SetScript("OnMouseDown", function(_, button) if button == "LeftButton" then panStart() end end)
  ct.canvas:SetScript("OnMouseUp", panStop)
  ct.canvas:SetScript("OnHide", panStop)
  ct.vbar = newBar(ct.field, false)
  ct.vbar:SetPoint("TOPRIGHT", -1, -1); ct.vbar:SetPoint("BOTTOMRIGHT", -1, BAR + 2); ct.vbar:SetWidth(BAR)
  ct.hbar = newBar(ct.field, true)
  ct.hbar:SetPoint("BOTTOMLEFT", 1, 1); ct.hbar:SetPoint("BOTTOMRIGHT", -(BAR + 2), 1); ct.hbar:SetHeight(BAR)
  -- the item at the root as the heading of the field, floating in its top
  -- left corner above the tree (the layout starts the tree below it). It is
  -- set apart from the cards: no frame, the name large in its quality color,
  -- a gold rule below. The heading is a live item link - hover = tooltip,
  -- click = the item menu with every page, shift = AH search, alt = price to
  -- chat. Its width follows the text.
  local tile = CreateFrame("Button", nil, ct.field, "BackdropTemplate")
  tile:SetPoint("TOPLEFT", TILE_X, -TILE_Y); tile:SetHeight(TILE_H)
  tile:SetFrameLevel(ct.canvas:GetFrameLevel() + 20)
  tile:SetBackdrop(T.FLAT)
  -- the field's own color, so a tree dragged below it does not show through
  tile:SetBackdropColor(C.bg0[1] * 0.7, C.bg0[2] * 0.7, C.bg0[3] * 0.7, 0.94)
  tile:SetBackdropBorderColor(0, 0, 0, 0)
  tile:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  ct.headQb = tile:CreateTexture(nil, "ARTWORK")
  ct.headQb:SetTexture(WHITE); ct.headQb:SetSize(38, 38); ct.headQb:SetPoint("TOPLEFT", 6, -3)
  ct.headIcon = tile:CreateTexture(nil, "OVERLAY")
  ct.headIcon:SetSize(36, 36); ct.headIcon:SetPoint("CENTER", ct.headQb, "CENTER")
  ct.headIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  ct.headName = T.Text(tile, T.SIZE.h1 + 4, "text", T.FONT_SEMI)
  ct.headName:SetPoint("TOPLEFT", ct.headQb, "TOPRIGHT", 10, 0); ct.headName:SetJustifyH("LEFT")
  ct.headMeta = T.Text(tile, T.SIZE.small, "sub", T.FONT_MED)
  ct.headMeta:SetPoint("BOTTOMLEFT", ct.headQb, "BOTTOMRIGHT", 10, 1); ct.headMeta:SetJustifyH("LEFT")
  ct.headRule = tile:CreateTexture(nil, "ARTWORK")
  ct.headRule:SetColorTexture(T.Unpack(C.accent))
  ct.headRule:SetHeight(2); ct.headRule:SetPoint("BOTTOMLEFT", 6, 3); ct.headRule:SetPoint("BOTTOMRIGHT", -6, 3)
  tile:SetScript("OnEnter", function(self)
    ct.headRule:SetColorTexture(T.Unpack(C.teal))
    if ct.id and M.ShowItemTip then
      M.ShowItemTip(tostring(ct.id))
      if GameTooltip:IsShown() then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Click: every page of this item", 0.52, 0.48, 0.39)
        GameTooltip:Show()
      end
    end
  end)
  tile:SetScript("OnLeave", function()
    ct.headRule:SetColorTexture(T.Unpack(C.accent))
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
  -- zoom, floating in the field's top right corner: - / + step by 10%, the
  -- number between them is the zoom, Fit shows the whole tree
  local cfg = M.db and M.db.config
  local cz = cfg and tonumber(cfg.craftZoom)
  ct.zoom = cz and max(ZOOM_MIN, min(ZOOM_MAX, cz)) or 1
  ct.fit = (cfg and cfg.craftFit == true) or nil
  local zb = CreateFrame("Frame", nil, ct.field, "BackdropTemplate")
  zb:SetSize(130, 28); zb:SetPoint("TOPRIGHT", -(BAR + 10), -TILE_Y)
  zb:SetFrameLevel(ct.canvas:GetFrameLevel() + 20)
  zb:SetBackdrop(T.FLAT)
  zb:SetBackdropColor(C.bg1[1], C.bg1[2], C.bg1[3], 0.97)
  zb:SetBackdropBorderColor(T.Unpack(C.borderlt))
  zb:EnableMouse(true)
  zb:EnableMouseWheel(true)
  zb:SetScript("OnMouseWheel", function(_, d) fieldWheel(d) end)
  local zOut = T.Button(zb, "\226\136\146", 20, 20)
  zOut:SetPoint("LEFT", 4, 0)
  zOut:SetScript("OnClick", function() zoomBy(-1) end)
  ct.zoomPct = T.Text(zb, T.SIZE.small, "sub", T.FONT_MED)
  ct.zoomPct:SetPoint("LEFT", zOut, "RIGHT", 0, 0); ct.zoomPct:SetWidth(42); ct.zoomPct:SetJustifyH("CENTER")
  local zIn = T.Button(zb, "+", 20, 20)
  zIn:SetPoint("LEFT", zOut, "RIGHT", 42, 0)
  zIn:SetScript("OnClick", function() zoomBy(1) end)
  ct.zoomFit = T.Button(zb, "Fit", 36, 20)
  ct.zoomFit:SetPoint("LEFT", zIn, "RIGHT", 4, 0)
  ct.zoomFit:SetScript("OnClick", toggleFit)
  ct.zoomFit:HookScript("OnLeave", zoomLook)
  ct.zoomOut, ct.zoomIn, ct.zoomBox = zOut, zIn, zb
  if T.HelpTip then
    local steps = { "Zooms the tree out and in, in steps of 10%.",
      "The mouse wheel over the field does the same around the mouse pointer." }
    T.HelpTip(zOut, "Zoom out", steps, "ANCHOR_BOTTOMRIGHT")
    T.HelpTip(zIn, "Zoom in", steps, "ANCHOR_BOTTOMRIGHT")
    T.HelpTip(ct.zoomFit, "Fit", {
      "Shows the whole tree in the field, also when you open another item or unfold a material.",
      "Click again for 100%." }, "ANCHOR_BOTTOMRIGHT")
  end
  zoomLook()
  -- Tree | Table in the field's top right corner, Reset choices next to it
  ct.view = (cfg and cfg.craftView == "table") and "table" or "tree"
  ct.viewSeg = T.Segment(ct.field, { { key = "tree", label = "Tree" }, { key = "table", label = "Table" } }, setView)
  ct.viewSeg.frame:SetFrameLevel(ct.canvas:GetFrameLevel() + 22)       -- above the heading
  local reset = T.Button(ct.field, "Reset choices", 104, 20)
  reset:SetPoint("RIGHT", ct.viewSeg.frame, "LEFT", -8, 0)
  reset:SetFrameLevel(ct.canvas:GetFrameLevel() + 22)
  reset:SetScript("OnClick", function()
    local all = M.db.config.craftForce
    if all and ct.id then all[ct.id] = nil end
    if all and next(all) == nil then M.db.config.craftForce = nil end
    M.RefreshCrafting()
  end)
  ct.resetBtn = reset
  if T.HelpTip then
    for _, b in ipairs(ct.viewSeg.buttons) do
      T.HelpTip(b, "Tree or table", {
        "Tree: the chain as cards. Table: one row per step with make and buy side by side, the saving, the profit of making it to sell and your own choice - make or buy - for each material.",
        "Both count for the items set in the footer box." }, "ANCHOR_BOTTOMRIGHT")
    end
    T.HelpTip(reset, "Reset choices", { "Drops your make / buy choices for this item: every material goes back to the cheapest way." }, "ANCHOR_BOTTOMRIGHT")
  end
  buildTable(ct.field)
  local sep = ct.tree:CreateTexture(nil, "ARTWORK")
  sep:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.6)
  sep:SetWidth(1); sep:SetPoint("TOPRIGHT", -(SIDE_W + 8), 0); sep:SetPoint("BOTTOMRIGHT", -(SIDE_W + 8), FOOT_H)
  ct.side = CreateFrame("Frame", nil, ct.tree)
  ct.side:SetPoint("TOPRIGHT", 0, 0); ct.side:SetPoint("BOTTOMRIGHT", 0, FOOT_H)
  ct.side:SetWidth(SIDE_W)
  ct.sideScroll = CreateFrame("ScrollFrame", nil, ct.side)
  ct.sideScroll:SetAllPoints()
  ct.sideBody = CreateFrame("Frame", nil, ct.sideScroll)
  ct.sideBody:SetSize(SIDE_W, 10)
  ct.sideScroll:SetScrollChild(ct.sideBody)
  ct.sideScroll:EnableMouseWheel(true)
  ct.sideScroll:SetScript("OnMouseWheel", function(_, d) sideScroll((ct.sideOff or 0) - d * 44) end)
  ct.sideBar = newBar(ct.side, false)
  ct.sideBar.bg:Hide()
  ct.sideBar:SetPoint("TOPRIGHT", 0, 0); ct.sideBar:SetPoint("BOTTOMRIGHT", 0, 0)
  ct.sideBar:SetWidth(SIDE_BAR)
  ct.sideBar:SetFrameLevel(ct.sideScroll:GetFrameLevel() + 10)
  ct.sideBar.get = function() return ct.sideOff or 0, sideMax() end
  ct.sideBar.set = function(frac) sideScroll(frac * sideMax()) end
  ct.sideBar.wheel = function(d) sideScroll((ct.sideOff or 0) - d * 44) end
  ct.sideBar:Hide()
  ct.sideThumb = ct.sideBar.thumb
  ct.sideScroll:SetScript("OnSizeChanged", function() sideScroll(ct.sideOff) end)
  if M.LinkBar then
    ct.links = M.LinkBar(ct.sideBody, { except = "tree", watch = true, short = true, wrap = true })
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
  if ct.colPop then ct.colPop:Hide() end
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
  local mobOn = not (M.db.config and M.db.config.craftBuyOnly)
  ct.mob:SetChecked(mobOn)
  ct.buyUnk:SetChecked(M.db.config and M.db.config.craftBuyUnknown == true)
  ct.buyUnk:SetAlpha(mobOn and 1 or 0.4)      -- nothing to narrow while every material is bought
  ct.knownCb:SetChecked(knownOnly())
  ct.fitBar()
  ct.profBtn.text:SetText(ct.prof and M.ProfName(ct.prof) or "All professions")
  ct.back:SetAlpha((#ct.hist > 0 or ct.id) and 1 or 0.4)
  ct.fwdBtn:SetAlpha((#ct.fwd > 0) and 1 or 0.4)
  if not ct.id then
    ct.tree:Hide(); ct.top:Show()
    drawTop()
    return
  end
  ct.top:Hide(); ct.tree:Show()
  ct.force = forceOf(ct.id)
  applyView()
  fillHead(ct.id)
  local ok, root, cc
  if ct.view == "table" then ok, root, cc = drawTable() else ok, root, cc = drawTree() end
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
  local kset = knownSet()
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
    local kn = n.root and #(M.CraftKnownBy(n.id)) > 0
    local unk = recipeUnknown(n, kset)
    b:SetBackdropColor(T.Unpack(unk and UNKNOWN_BG or (n.dim and C.bg0 or C.bg1)))
    b:SetBackdropBorderColor(T.Unpack((unk and C.red) or (kn and C.green) or (n.root and C.accent)
      or (made and C.mint) or C.border))
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
