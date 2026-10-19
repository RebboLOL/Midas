-- Midas – Comm: community sync. Every Midas user on the same realm+faction shares
-- scan data via invisible addon messages (CHAT_MSG_ADDON). These are a separate
-- message class the chat UI never displays - players with or without the addon
-- see nothing. Data flows over the GUILD channel (plus party/raid when grouped);
-- an opt-in vicinity layer (SAY/YELL) additionally bridges to nearby Midas users in
-- OTHER guilds at the auction house, carrying only the light pull traffic (manifest
-- + request). A hardened send pump (return-checked, message-token bucket, backoff)
-- keeps every channel under the client's per-prefix limit, so the "messages limited"
-- error can't appear. Consistency: day records merge as a CRDT (low=MIN, qty=MAX)
-- plus last-write-wins for cur via the scan timestamp, so every client converges to
-- the same DB no matter the message order or duplicates.
-- No external libs: own tiny throttle, base36 codec, self-contained chunks.
local ADDON, M = ...

local PREFIX = "Midas1"   -- protocol version lives in the prefix (breaking -> Midas2)

M.commStats = { rxRows = 0, txRows = 0, rxMsgs = 0, txMsgs = 0, txThrottled = 0, peers = {} }

-- recent activity ring for the Sync tab (newest appended)
local commLog = {}
local function logEvent(dir, text)   -- dir: "tx" | "rx" | "info"
  commLog[#commLog + 1] = { t = time(), dir = dir, text = text }
  if #commLog > 40 then table.remove(commLog, 1) end
end

-- probe pongs are printed ONLY to the player who ran the probe (otherwise a guild
-- probe would print "pong from ..." on everyone's screen). Set when WE probe.
local probeUntil = 0

-- ===== base36 + realm hash ===================================================
local DIG = "0123456789abcdefghijklmnopqrstuvwxyz"
local function enc36(n, minLen)
  n = math.floor(tonumber(n) or 0)
  if n < 0 then n = 0 end
  local s = ""
  repeat
    local r = n % 36
    s = DIG:sub(r + 1, r + 1) .. s
    n = math.floor(n / 36)
  until n == 0
  while minLen and #s < minLen do s = "0" .. s end
  return s
end
local function dec36(s) return s and tonumber(s, 36) or nil end

-- Sharing scope = realm + faction, computed identically on EVERY client.
-- Deliberately NOT M.RealmKey(): that borrows Auctionator's realm key when present,
-- so a user with Auctionator and one without would hash different strings and
-- silently reject each other's messages. Normalised (lowercase, no spaces) so a
-- stray space or case difference can never split a realm.
local function commScope()
  local realm = GetRealmName() or "?"
  local fac = UnitFactionGroup("player") or "?"
  return (realm .. ":" .. fac):lower():gsub("%s+", "")
end

local realmHash
local function RealmHash()
  if not realmHash then
    local s, h = commScope(), 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 1679616 end -- 36^4
    realmHash = enc36(h, 4)
  end
  return realmHash
end

local function ValidDay(day)
  local today = M.GetScanDay()
  return day > today - M.C.PRUNE_DAYS and day <= today + 1
end

-- ===== send queue + throttle (byte + message token buckets + backoff) =======
-- Three independent guards; an item leaves the queue ONLY on confirmed success:
--  (1) byte budget (COMM_BPS),
--  (2) a message-token bucket mirroring Blizzard's per-prefix allowance (10 burst,
--      +1/s) but deliberately conservative, so we essentially never present more
--      than the client will accept,
--  (3) return-value check + exponential backoff: a throttled/failed send keeps the
--      item (no qHead advance, nothing spent) and widens the send spacing.
-- Because of (3) we obey the client's throttle signal instead of hammering past it,
-- and because of (2) our sustained public-channel rate stays well under the limit
-- even though a Success return only means "queued client-side" (server may still
-- throttle). Together these make the visible "messages limited" error impossible.
-- Eigener Ende-Zähler qTail: "#queue" ist undefiniert, sobald der Anfang auf nil
-- gesetzt ist - neue Nachrichten landeten sonst in schon abgearbeiteten Fächern
-- unter qHead und wurden nie gesendet.
local queue, qHead, qTail, budget, nextSend = {}, 1, 0, 0, 0
local msgTokens   = 0            -- locally mirrored per-prefix message allowance
local commBackoff = 0            -- current backoff seconds (0 = none)
local MSG_BURST, MSG_REGEN      = 8, 0.9   -- < Blizzard's 10 burst / +1/s (headroom)
local BACKOFF_BASE, BACKOFF_CAP = 1, 30

-- Success == 0 (Enum.SendAddonMessageResult.Success). Older/edge builds may return
-- nil or a boolean; treat those as success. Anything else (esp. AddonMessageThrottle)
-- means the client did NOT send -> keep the item and back off.
local SENDOK = (Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success) or 0
local function sendOK(r) return r == nil or r == true or r == SENDOK end

local pump = CreateFrame("Frame"); pump:Hide()
pump:SetScript("OnUpdate", function(self, elapsed)
  local C = M.C
  budget    = math.min(C.COMM_BPS * 2, budget + C.COMM_BPS * elapsed)
  msgTokens = math.min(MSG_BURST,     msgTokens + MSG_REGEN * elapsed)
  if M.scanning then return end                 -- keep the frame budget during scans
  local now = GetTime()
  if now < nextSend then return end             -- min spacing AND active backoff
  local item = queue[qHead]
  if not item then queue, qHead, qTail = {}, 1, 0; self:Hide(); return end
  local cost = #item.text + 16
  if budget < cost or msgTokens < 1 then return end
  if item.chan == "GUILD" and not IsInGuild() then queue[qHead] = nil; qHead = qHead + 1; return end

  local r = C_ChatInfo.SendAddonMessage(PREFIX, item.text, item.chan, item.target)
  if sendOK(r) then
    budget, msgTokens, commBackoff = budget - cost, msgTokens - 1, 0
    M.commStats.txMsgs = M.commStats.txMsgs + 1
    queue[qHead] = nil; qHead = qHead + 1
    nextSend = now + 1 / C.COMM_MPS
  elseif M.SEND_PERMANENT_FAIL and M.SEND_PERMANENT_FAIL[r] then
    -- never succeeds on retry (e.g. SAY/YELL addon messages on the modern client):
    -- drop the item instead of blocking the queue; switch that channel off for the session
    queue[qHead] = nil; qHead = qHead + 1
    if (item.chan == "SAY" or item.chan == "YELL") and not M.vicinityBlocked then
      M.vicinityBlocked = true
      logEvent("info", "vicinity sync unavailable on this client (" .. M.SEND_PERMANENT_FAIL[r] .. ") - guild/group only")
    end
  else                                          -- throttled/failed: keep item, spend nothing
    commBackoff = math.min(BACKOFF_CAP, (commBackoff > 0 and commBackoff * 2) or BACKOFF_BASE)
    nextSend = now + commBackoff
    M.commStats.txThrottled = (M.commStats.txThrottled or 0) + 1
  end
end)

local function Enqueue(chan, text, target)
  if not (M.db and M.db.config and M.db.config.share) then return end
  -- "VICINITY" is a logical channel: map it to the configured public chat type, or
  -- drop it when vicinity sync is off. Direct SAY/YELL are honoured now (previously
  -- force-rewritten to GUILD); the hardened pump keeps them under the throttle.
  if chan == "VICINITY" then
    local v = M.db.config.vicinity
    if v == "say" then chan = "SAY"
    elseif v == "yell" then chan = "YELL"
    else return end
  end
  qTail = qTail + 1
  queue[qTail] = { chan = chan, text = text, target = target }
  pump:Show()
end

-- guild is the reliable backbone; party/raid come for free when grouped.
local function Broadcast(text)
  Enqueue("GUILD", text)
  if IsInRaid() then Enqueue("RAID", text) elseif IsInGroup() then Enqueue("PARTY", text) end
end

-- Vicinity (SAY/YELL) reaches nearby players regardless of guild - the cross-guild
-- bridge. It only matters where Midas users cluster: at the auction house. Gated on
-- AH open + share on + a vicinity channel configured + not guild-trust + not in
-- combat. Used ONLY for the light pull layer (manifest M / request R) - never for
-- the heavy scan-delta S stream, which stays guild-only.
local function VicinityOn()
  return M.AHOpen and not M.vicinityBlocked and M.db and M.db.config and M.db.config.share
     and M.db.config.vicinity and M.db.config.vicinity ~= "off"
     and M.db.config.shareTrust ~= "guild" and not InCombatLockdown()
end
local function BroadcastVicinity(text)
  if VicinityOn() then Enqueue("VICINITY", text) end
end

-- ===== row codec =============================================================
-- Row string "dId.low.qty[.dCur[.ts]]", rows joined by ";". Numbers base36, item
-- ids delta-encoded; every chunk restarts at an absolute id, so each message is
-- self-contained (no reassembly - a lost message just loses those rows and the
-- manifest/backfill heals them later). S-chunks carry one ts in the header (one
-- scan = one timestamp) and use the short 4-field form; D-chunks attach cur+ts
-- per row (5 fields) where known.
local function rowStr(r, prev, withTs)
  local s = enc36(r.id - prev) .. "." .. enc36(r.low) .. "." .. enc36(r.qty or 0)
  local dCur = (r.cur and r.cur >= r.low) and (r.cur - r.low) or 0
  if withTs then
    if r.cur and r.ts then s = s .. "." .. enc36(dCur) .. "." .. enc36(r.ts) end
  elseif dCur > 0 then
    s = s .. "." .. enc36(dCur)
  end
  return s
end

local function EncodeChunks(head, rows, withTs)
  table.sort(rows, function(a, b) return a.id < b.id end)
  local out, buf, blen, prev = {}, {}, #head, 0
  local i = 1
  while i <= #rows do
    local s = rowStr(rows[i], prev, withTs)
    if blen + #s + 1 > M.C.COMM_PAYLOAD and #buf > 0 then
      out[#out + 1] = head .. table.concat(buf, ";")
      buf, blen, prev = {}, #head, 0
    else
      buf[#buf + 1] = s; blen = blen + #s + 1; prev = rows[i].id; i = i + 1
    end
  end
  if #buf > 0 then out[#out + 1] = head .. table.concat(buf, ";") end
  return out
end

-- sTs = header timestamp of an S-chunk (rows then imply cur); nil for D-chunks.
-- Strict: one malformed/out-of-bounds row rejects the whole chunk.
local function DecodeRows(str, sTs)
  local rows, prev = {}, 0
  for rs in str:gmatch("[^;]+") do
    local f = {}
    for x in rs:gmatch("[^.]+") do f[#f + 1] = x end
    local dId, low, qty = dec36(f[1]), dec36(f[2]), dec36(f[3])
    if not (dId and low and qty) then return nil end
    local id = prev + dId; prev = id
    -- 0c = a sub-copper unit price (ammo) from peers before the 1c floor
    if low == 0 then low = 1 end
    if id <= 0 or id > 16777215 or low <= 0 or low > 5e8 or qty > 1e5 then return nil end
    local r = { id = id, low = low, qty = qty }
    if sTs then
      r.cur = low + (dec36(f[4]) or 0); r.ts = sTs
    elseif f[5] then
      local dc, ts = dec36(f[4]), dec36(f[5])
      if dc and ts then r.cur = low + dc; r.ts = ts end
    end
    rows[#rows + 1] = r
  end
  return rows
end

-- ===== local per-day summary (count + order-independent checksum) ===========
local manCache, manCacheT
local function LocalManifest()
  if manCache and (GetTime() - (manCacheT or 0)) < 60 then return manCache end
  local today = M.GetScanDay()
  local horizon = today - M.C.SYNC_DAYS
  local per = {}
  for key, it in pairs(M.IterItems()) do
    local id = tonumber(key)
    if id then
      for day, rec in pairs(it) do
        if day >= horizon and day <= today then
          local e = per[day]
          if not e then e = { cnt = 0, ck = 0 }; per[day] = e end
          e.cnt = e.cnt + 1
          e.ck = (e.ck + id * 31 + (rec.low or 0) + (rec.qty or 0)) % 1679616
        end
      end
    end
  end
  manCache, manCacheT = per, GetTime()
  return per
end

local lastManifestTx, lastManifestVicinityTx = 0, 0
local function SendManifest(force)
  if not force and GetTime() - lastManifestTx < 60 then return end
  lastManifestTx = GetTime()
  local per = LocalManifest()
  local days = {}
  for d in pairs(per) do days[#days + 1] = d end
  if #days == 0 then return end
  table.sort(days, function(a, b) return a > b end)
  local head = "M" .. RealmHash() .. "|"
  local chunks, buf, blen = {}, {}, #head
  for _, d in ipairs(days) do
    local e = per[d]
    local s = enc36(d) .. ":" .. enc36(e.cnt) .. ":" .. enc36(e.ck, 1)
    if blen + #s + 1 > M.C.COMM_PAYLOAD and #buf > 0 then
      chunks[#chunks + 1] = head .. table.concat(buf, ",")
      buf, blen = {}, #head
    end
    buf[#buf + 1] = s; blen = blen + #s + 1
  end
  if #buf > 0 then chunks[#chunks + 1] = head .. table.concat(buf, ",") end
  logEvent("info", "sent manifest (" .. #days .. " days)")
  for _, c in ipairs(chunks) do Broadcast(c) end
  -- Cross-guild discovery beacon: only the FIRST chunk (newest days), on its own
  -- 120 s throttle so a crowd arriving together doesn't co-time public beacons.
  if VicinityOn() and #chunks > 0 and GetTime() - lastManifestVicinityTx > 120 then
    lastManifestVicinityTx = GetTime()
    BroadcastVicinity(chunks[1])
    logEvent("tx", "beacon to nearby (" .. (M.db.config.vicinity or "?") .. ")")
  end
end

-- ===== backfill: request days we lack, one at a time =========================
local wantDays, reqCooldown, lastDRx, pendingDay = {}, {}, {}, nil
local reqTicker
local function RequestNext()
  if pendingDay and GetTime() - (lastDRx[pendingDay] or 0) < 5 then return end
  pendingDay = nil
  local best
  for d in pairs(wantDays) do if not best or d > best then best = d end end
  if not best then
    if reqTicker then reqTicker:Cancel(); reqTicker = nil end
    return
  end
  wantDays[best] = nil
  reqCooldown[best] = GetTime()
  pendingDay = best
  local req = "R" .. RealmHash() .. "|" .. enc36(best)
  Broadcast(req)
  BroadcastVicinity(req)        -- also ask nearby cross-guild peers at the AH
  logEvent("info", "requested day " .. best)
end
local function QueueWant(day)
  if GetTime() - (reqCooldown[day] or -9e9) < 600 then return end
  wantDays[day] = true
  if not reqTicker then reqTicker = C_Timer.NewTicker(6, RequestNext) end
end

-- ===== day-data response (responder election avoids duplicate senders) ======
local lastDSeen, lastDayTx = {}, {}
local function SendDayData(day, chan)
  if GetTime() - (lastDayTx[day] or -9e9) < 60 then return end
  lastDayTx[day] = GetTime()
  local rows = {}
  for key, it in pairs(M.IterItems()) do
    local id = tonumber(key)
    local rec = id and it[day]
    if rec then
      rows[#rows + 1] = { id = id, low = rec.low, qty = rec.qty,
        cur = (rec.ts and rec.cur) or nil, ts = rec.ts }
    end
  end
  if #rows < (M.C.SYNC_MIN_ROWS or 1) then return end -- never serve thin "orphan" days
  -- answer only on the channel the request came from (halves the traffic)
  local chunks = EncodeChunks("D" .. RealmHash() .. "|" .. enc36(day) .. "|", rows, true)
  for _, c in ipairs(chunks) do Enqueue(chan, c) end
  M.commStats.txRows = M.commStats.txRows + #rows
  logEvent("tx", "served day " .. day .. " (" .. #rows .. " rows) to " .. chan)
end

local function OnRequest(day, chan)
  -- wait a moment; if someone else already answers this day, stand down. lastDSeen
  -- is bumped by inbound D on ANY channel, so this election spans guild boundaries
  -- (a nearby cross-guild responder counts too) - the first answer wins.
  C_Timer.After(0.3 + math.random() * 2.2, function()
    if GetTime() - (lastDSeen[day] or -9e9) < 4 then return end
    SendDayData(day, chan)
  end)
end

-- ===== inbound dispatch ======================================================
local function HandleMsg(text, chan, sender, isSelf)
  if isSelf then
    if text:sub(1, 1) == "P" and chan == "WHISPER" and GetTime() < probeUntil then
      M.Print("comm self-test: transport OK (whisper loopback).")
    end
    return "self"
  end
  local typ = text:sub(1, 1)
  if text:sub(2, 5) ~= RealmHash() then return "realm" end
  local rest = text:sub(7)
  local cfg = M.db.config
  local isGuild = (chan == "GUILD")
  if cfg.shareTrust == "guild" and not isGuild and typ ~= "P" and typ ~= "Q" then return "trust" end
  M.commStats.peers[sender] = time()

  if typ == "H" or typ == "Q" then
    if typ == "Q" and GetTime() < probeUntil then M.Print("comm probe: pong from " .. sender .. " via " .. chan .. " (v" .. rest .. ")") end
    -- a Hello means someone (re)logged in: advertise our state so they can pull
    -- whatever they missed while offline (SendManifest is cooldown-gated)
    if typ == "H" then C_Timer.After(2 + math.random() * 4, function() SendManifest(false) end) end
    return "ok"
  elseif typ == "P" then
    if chan == "WHISPER" then
      Enqueue("WHISPER", "Q" .. RealmHash() .. "|" .. M.version, sender)
    else
      Enqueue(chan, "Q" .. RealmHash() .. "|" .. M.version)
    end
    return "ok"
  elseif typ == "S" then
    local d36, t36, rows = rest:match("^([^|]+)|([^|]+)|(.+)$")
    local day, ts = dec36(d36), dec36(t36)
    if not (day and ts and rows and ValidDay(day)) then return "bad" end
    local rs = DecodeRows(rows, ts)
    if not rs then return "bad" end
    local imp = M.MergeSharedRows(day, rs, isGuild) or 0
    M.commStats.rxRows = M.commStats.rxRows + imp
    logEvent("rx", "scan from " .. sender .. ": +" .. imp .. " rows (day " .. day .. ")")
    return "ok"
  elseif typ == "D" then
    local d36, rows = rest:match("^([^|]+)|(.+)$")
    local day = dec36(d36)
    if not (day and rows and ValidDay(day)) then return "bad" end
    lastDSeen[day] = GetTime(); lastDRx[day] = GetTime()
    local rs = DecodeRows(rows, nil)
    if not rs then return "bad" end
    local imp = M.MergeSharedRows(day, rs, isGuild) or 0
    M.commStats.rxRows = M.commStats.rxRows + imp
    logEvent("rx", "backfill from " .. sender .. ": +" .. imp .. " rows (day " .. day .. ")")
    return "ok"
  elseif typ == "M" then
    logEvent("info", "manifest from " .. sender)
    local per = LocalManifest()
    local iHaveMore = false
    for d36, c36, k36 in rest:gmatch("(%w+):(%w+):(%w+)") do
      local day, cnt, ck = dec36(d36), dec36(c36), dec36(k36)
      if day and cnt and ck and ValidDay(day) then
        local e = per[day]
        local lc, lk = e and e.cnt or 0, e and e.ck or 0
        -- day-quality gate: only pull days that look like a real full scan;
        -- thin "orphan" days (a handful of rows) would re-import junk history
        if cnt >= M.C.SYNC_MIN_ROWS and (cnt > lc or (cnt == lc and ck ~= lk)) then QueueWant(day) end
        if lc > cnt then iHaveMore = true end
      end
    end
    -- they are behind somewhere: advertise our state so THEY can pull from us
    if iHaveMore then C_Timer.After(2 + math.random() * 3, function() SendManifest(false) end) end
    return "ok"
  elseif typ == "R" then
    local day = dec36(rest)
    if day and ValidDay(day) then OnRequest(day, chan) end
    return "ok"
  end
  return "unknown"
end

-- ===== events ================================================================
local ahTicker
local ef = CreateFrame("Frame")
ef:RegisterEvent("CHAT_MSG_ADDON")
ef:RegisterEvent("PLAYER_LOGIN")
ef:RegisterEvent("AUCTION_HOUSE_SHOW")
ef:RegisterEvent("AUCTION_HOUSE_CLOSED")
ef:SetScript("OnEvent", function(_, event, ...)
  if event == "CHAT_MSG_ADDON" then
    local prefix, text, chan, sender = ...
    if prefix ~= PREFIX or type(text) ~= "string" then return end
    if not (M.db and M.db.config and M.db.config.share) then return end
    M.commStats.rxMsgs = M.commStats.rxMsgs + 1
    local short = Ambiguate(sender or "", "short")
    pcall(HandleMsg, text, chan, short, short == UnitName("player"))
  elseif event == "PLAYER_LOGIN" then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    C_Timer.After(5, function() Broadcast("H" .. RealmHash() .. "|" .. M.version) end)
    C_Timer.After(15 + math.random() * 15, function() SendManifest(true) end)
  elseif event == "AUCTION_HOUSE_SHOW" then
    C_Timer.After(2 + math.random() * 3, function() SendManifest(false) end)
    if not ahTicker then ahTicker = C_Timer.NewTicker(300, function() SendManifest(false) end) end
  elseif event == "AUCTION_HOUSE_CLOSED" then
    if ahTicker then ahTicker:Cancel(); ahTicker = nil end
  end
end)

-- ===== hooks & commands ======================================================
-- After each own scan: broadcast exactly the rows the scan changed locally.
-- First scanner of the day ships ~the full day, everyone after only improvements.
function M.OnScanCommitted(day, changed, ts)
  if not changed or #changed == 0 then return end
  if not (M.db and M.db.config and M.db.config.share) then return end
  local chunks = EncodeChunks("S" .. RealmHash() .. "|" .. enc36(day) .. "|" .. enc36(ts) .. "|", changed, false)
  for _, c in ipairs(chunks) do Broadcast(c) end
  M.commStats.txRows = M.commStats.txRows + #changed
  logEvent("tx", "sent scan: " .. #changed .. " rows (day " .. day .. ")")
  C_Timer.After(5, function() SendManifest(false) end)
end

function M.CommSync()
  SendManifest(true)
  M.Print("sync: manifest sent (last " .. M.C.SYNC_DAYS .. " days), queue " .. (qTail - qHead + 1) .. " msgs.")
end

function M.CommStatus()
  local cfg = M.db.config
  local np, now = 0, time()
  for _, t in pairs(M.commStats.peers) do if now - t < 600 then np = np + 1 end end
  M.Print(string.format("share %s  trust %s  |  rx %d rows/%d msgs  tx %d rows/%d msgs  |  peers(10m) %d  queue %d",
    cfg.share and "ON" or "OFF", cfg.shareTrust or "all",
    M.commStats.rxRows, M.commStats.rxMsgs, M.commStats.txRows, M.commStats.txMsgs,
    np, qTail - qHead + 1))
  M.Print(string.format("  scope %s  hash %s  guild:%s  |  vicinity %s (AH %s)  throttled %d",
    commScope(), RealmHash(), tostring(IsInGuild()),
    string.upper(cfg.vicinity or "off"), M.AHOpen and "open" or "closed", M.commStats.txThrottled or 0))
end

-- Snapshot for the Sync tab (UI reads this instead of poking comm internals).
function M.CommInfo()
  local cfg = M.db.config
  local now, names, cnt = time(), {}, 0
  for name, t in pairs(M.commStats.peers) do
    if now - t < 600 then cnt = cnt + 1; if #names < 6 then names[#names + 1] = name end end
  end
  local log = {}
  for i = #commLog, 1, -1 do
    local e = commLog[i]
    log[#log + 1] = { dir = e.dir, text = e.text, clock = date("%H:%M:%S", e.t) }
    if #log >= 16 then break end
  end
  return {
    scope = commScope(), hash = RealmHash(), guild = IsInGuild(),
    share = cfg.share == true, trust = cfg.shareTrust or "all",
    rxRows = M.commStats.rxRows, rxMsgs = M.commStats.rxMsgs,
    txRows = M.commStats.txRows, txMsgs = M.commStats.txMsgs,
    txThrottled = M.commStats.txThrottled or 0,
    vicinity = cfg.vicinity or "off", ahOpen = M.AHOpen == true,
    peerCount = cnt, peers = names, queue = qTail - qHead + 1, log = log,
  }
end

function M.CommProbe()
  probeUntil = GetTime() + 12   -- only WE print the pongs that come back in this window
  M.Print("comm probe: pinging guild + group + nearby + self. Watching for pongs...")
  local p = "P" .. RealmHash() .. "|1"
  Broadcast(p)
  BroadcastVicinity(p)          -- reaches cross-guild peers at the AH (if vicinity on)
  Enqueue("WHISPER", p, UnitName("player"))
end
