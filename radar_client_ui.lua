-- radar_client_ui.lua  (CLIENT UI; data from server; HOTPLUG SAFE + FIXED COMMANDS)
-- UPGRADE: multi-ship dispatch
--   - listens SHIP_HELLO from helm computers
--   - C: cycle selected ship
--   - X: dispatch nearest marked target to selected ship via SHIP_CMD
--   - Z: stop selected ship via SHIP_CMD

-------------------------
-- CONFIG
-------------------------
local CFG = {
  tick = 0.10,

  maxShow = 20,
  minShow = 6,
  maxShowLimit = 40,
  showStep = 2,

  monitorTextScale = 0.5,
  monitorScaleStep = 0.5,
  minMonitorScale = 0.5,
  maxMonitorScale = 5.0,

  radarPointChar = ".",
  radarBorder = true,

  rotateWithHeading = true,
  radarCursorStep = 1,
}

-- ✅ 只连接指定 hostname 的 radar server（改成你的服务端打印出来的 hostname）
local WANT_HOSTNAME = "radar_server_"

-------------------------
-- rednet init (OPEN ALL MODEMS + HANDSHAKE)
-------------------------
local function openAllRednet()
  local opened = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      if not rednet.isOpen(name) then rednet.open(name) end
      table.insert(opened, name)
    end
  end
  assert(#opened > 0, "No modem found")
  return opened
end

local modems = openAllRednet()
print("[CLIENT] Opened modems: " .. table.concat(modems, ", "))
print("[CLIENT] myID:", os.getComputerID())
print("[CLIENT] target hostname:", WANT_HOSTNAME)

local serverId = nil
local lastHello = 0

local function hello()
  rednet.broadcast({ kind="hello", from=os.getComputerID() }, "RADAR_HELLO")
  lastHello = os.clock()
end

hello()

-- ✅ 只接受指定 hostname 的 ACK
local function handleAck(sid, msg, proto)
  if proto ~= "RADAR_ACK" then return false end
  if type(msg) ~= "table" or msg.kind ~= "ack" then return false end

  -- 服务端必须在 ACK 里附带 hostname
  if msg.hostname ~= WANT_HOSTNAME then
    -- 吃掉 ACK，避免误连其他服务器
    return true
  end

  serverId = sid
  print(("✅ Connected to %s (id=%s)"):format(tostring(WANT_HOSTNAME), tostring(serverId)))
  return true
end

-- ✅ 未连接时不再广播命令，避免串台
local function sendCmd(cmdTable)
  cmdTable.kind = "radar_cmd"

  if not serverId then
    if (os.clock() - lastHello > 1) then
      hello()
    end
    print("⚠ Not connected yet, waiting for:", WANT_HOSTNAME)
    return false
  end

  rednet.send(serverId, cmdTable, "RADAR_CMD")
  return true
end

-------------------------
-- UTIL
-------------------------
local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end
local function round1(x) return math.floor((x or 0) * 10 + 0.5) / 10 end
local function strLower(x) return tostring(x or ""):lower() end

local nativeTerm = term.native()

local function resetColors()
  term.setTextColor(colors.white)
  term.setBackgroundColor(colors.black)
end

local function clearTerm(t)
  if not t then return end
  local ok = pcall(function()
    local old = term.redirect(t)
    term.clear()
    term.setCursorPos(1,1)
    resetColors()
    term.redirect(old)
  end)
  return ok
end

-------------------------
-- AUTO FIND MONITOR + HOTPLUG SAFE
-------------------------
local function findMonitor()
  local sides = {"top","bottom","left","right","front","back"}
  for _, side in ipairs(sides) do
    if peripheral.isPresent(side) and peripheral.getType(side) == "monitor" then
      local m = peripheral.wrap(side)
      if m then return m, side end
    end
  end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local m = peripheral.wrap(name)
      if m then return m, name end
    end
  end
  return nil, nil
end

local monitor, monitorName = findMonitor()

local function trySetupMonitor()
  if monitor and monitor.setTextScale then
    CFG.monitorTextScale = clamp(CFG.monitorTextScale, CFG.minMonitorScale, CFG.maxMonitorScale)
    pcall(function() monitor.setTextScale(CFG.monitorTextScale) end)
  end
end
trySetupMonitor()

-- redraw wakeup (forward declare; real function later)
local requestRedraw

-- radar cache reset (forward declare; real function later)
local resetRadarCache

-- output target
local outputTarget = "terminal" -- monitor/terminal

-- SAFE wrapper: any monitor IO may fail during hotplug
local function safeWithMonitor(fn)
  if not monitor then return false end
  local ok = pcall(fn)
  if not ok then
    -- monitor likely unplugged
    monitor = nil
    monitorName = nil
    outputTarget = "terminal"
    return false
  end
  return true
end

local function syncMonitor()
  local oldName = monitorName
  local m, mName = findMonitor()

  if mName ~= oldName then
    monitor, monitorName = m, mName

    if monitor then
      trySetupMonitor()
    else
      outputTarget = "terminal"
    end

    -- hotplug: clear + reset + redraw (critical)
    clearTerm(nativeTerm)
    if monitor then clearTerm(monitor) end
    if resetRadarCache then resetRadarCache() end
    if requestRedraw then requestRedraw() end
    return true
  end

  return false
end

local function changeMonitorScale(delta)
  if not monitor then return false end
  CFG.monitorTextScale = clamp((CFG.monitorTextScale or 1) + delta, CFG.minMonitorScale, CFG.maxMonitorScale)
  trySetupMonitor()
  return true
end

local function changeFontBigger()
  if monitor then changeMonitorScale(-CFG.monitorScaleStep)
  else
    CFG.maxShow = clamp((CFG.maxShow or 20) - CFG.showStep, CFG.minShow, CFG.maxShowLimit)
  end
end
local function changeFontSmaller()
  if monitor then changeMonitorScale(CFG.monitorScaleStep)
  else
    CFG.maxShow = clamp((CFG.maxShow or 20) + CFG.showStep, CFG.minShow, CFG.maxShowLimit)
  end
end

-------------------------
-- UI STATE (server data)
-------------------------
local list = {}
local selected = 1
local viewMode = "list" -- list/radar

-- radar cursor
local radarCursorX, radarCursorY = 0, 0

-- server state
local serverCenter = {x=0,y=0,z=0}
local serverCenterSrc = "n/a"
local serverHeadingRad = 0
local serverHeadingSrc = "n/a"
local serverCFG = {
  scanRadius = 160,
  ignorePlayers=false, showOnlyMarked=false, ignoreFriendly=false, ignoreHostile=false,
}

-- radar toast (临时提示，画在雷达画面里)
local toastText = nil
local toastTimerId = nil
local TOAST_SECONDS = 2.5

-- 记录上一次 toast 占用的格子，方便擦掉
local lastRadarToast = {}

local function showToast(s)
  toastText = tostring(s or "")
  toastTimerId = os.startTimer(TOAST_SECONDS)
  if requestRedraw then requestRedraw() end
end

-------------------------
-- NEW: MULTI SHIP REGISTRY (from SHIP_HELLO)
-------------------------
local ships = {}            -- ships[ship_id] = { name, control_id, lastSeen }
local selectedShipKey = nil
local SHIP_OFFLINE_SEC = 3.0

local function shipDisplayLine()
  if selectedShipKey and ships[selectedShipKey] then
    local sh = ships[selectedShipKey]
    return string.format("%s (id=%s ctrl=%s)",
      tostring(sh.name or selectedShipKey),
      tostring(selectedShipKey),
      tostring(sh.control_id or "?")
    )
  end
  return "(none)  (press C)"
end

local function pickNextShip()
  local keys = {}
  for k,_ in pairs(ships) do table.insert(keys, k) end
  table.sort(keys)

  if #keys == 0 then
    selectedShipKey = nil
    showToast("No ship online")
    return
  end

  if not selectedShipKey then
    selectedShipKey = keys[1]
    showToast("Ship -> " .. tostring(ships[selectedShipKey].name or selectedShipKey))
    return
  end

  local idx = 1
  for i,k in ipairs(keys) do
    if k == selectedShipKey then idx = i break end
  end
  idx = idx + 1
  if idx > #keys then idx = 1 end
  selectedShipKey = keys[idx]
  showToast("Ship -> " .. tostring(ships[selectedShipKey].name or selectedShipKey))
end

local function sendShipCmd(cmd)
  cmd.kind = "ship_cmd"

  if not selectedShipKey or not ships[selectedShipKey] then
    showToast("Select ship first (press C)")
    return false
  end

  cmd.ship_id = selectedShipKey
  cmd.ts = os.epoch("utc")

  local sh = ships[selectedShipKey]
  if sh.control_id then
    rednet.send(sh.control_id, cmd, "SHIP_CMD")
  else
    -- fallback: broadcast (ship filters by ship_id)
    rednet.broadcast(cmd, "SHIP_CMD")
  end

  return true
end

-------------------------
-- TYPE COLORS
-------------------------
local function colorByType(t)
  t = strLower(t)
  if t == "player" then return colors.cyan end
  if t:find("zombie") or t:find("skeleton") or t:find("creeper") or t:find("spider")
     or t:find("enderman") or t:find("witch") or t:find("slime") or t:find("phantom")
     or t:find("pillager") or t:find("vindicator") or t:find("ravager")
  then return colors.red end
  if t:find("cow") or t:find("sheep") or t:find("pig") or t:find("chicken")
     or t:find("horse") or t:find("wolf") or t:find("cat") or t:find("villager")
  then return colors.green end
  return colors.lightGray
end

-------------------------
-- RADAR CACHE
-------------------------
local lastRadarPoints = {}
local lastRadarCursor = nil
local lastRadarBorder = {}

resetRadarCache = function()
  lastRadarPoints = {}
  lastRadarCursor = nil
  lastRadarBorder = {}
  lastRadarToast = {}
end

local function rememberBorder(w, h)
  lastRadarBorder = {}
  if not CFG.radarBorder then return end
  for x=1,w do
    lastRadarBorder[x..","..1] = true
    lastRadarBorder[x..","..h] = true
  end
  for y=1,h do
    lastRadarBorder["1,"..y] = true
    lastRadarBorder[w..","..y] = true
  end
end

local function eraseLastRadar()
  for k,_ in pairs(lastRadarPoints) do
    if not lastRadarBorder[k] then
      local xs, ys = k:match("^(%-?%d+),(%-?%d+)$")
      local x = tonumber(xs); local y = tonumber(ys)
      if x and y then
        term.setCursorPos(x,y); write(" ")
      end
    end
  end
  lastRadarPoints = {}

  if lastRadarCursor then
    local k = lastRadarCursor.x..","..lastRadarCursor.y
    if not lastRadarBorder[k] then
      term.setCursorPos(lastRadarCursor.x, lastRadarCursor.y); write(" ")
    end
    lastRadarCursor = nil
  end
end

local function eraseLastToast()
  for k,_ in pairs(lastRadarToast) do
    if not lastRadarBorder[k] then
      local xs, ys = k:match("^(%-?%d+),(%-?%d+)$")
      local x = tonumber(xs); local y = tonumber(ys)
      if x and y then
        term.setCursorPos(x,y); write(" ")
      end
    end
  end
  lastRadarToast = {}
end

-------------------------
-- STATUS DRAW
-------------------------
local function drawStatusOnTerm(t, hasMon)
  local old = term.redirect(t)
  term.clear()
  term.setCursorPos(1,1)
  resetColors()

  print("=== AUTO CAMERA RADAR (CLIENT UI) ===")
  print("Target Hostname:", WANT_HOSTNAME)
  print("Server:", serverId or "(not connected)")
  print("Monitor:", hasMon and (monitorName or "(monitor)") or "(none)")
  print("Output:", outputTarget, " | View:", viewMode, "(S)")
  print(("Radius: %d  ([ / ])"):format(tonumber(serverCFG.scanRadius) or 0))

  if hasMon then
    print(("MonitorScale: %.1f   (-/+)"):format(CFG.monitorTextScale))
  else
    print(("TerminalMaxShow: %d   (-/+)"):format(CFG.maxShow))
  end

  print(("Rotate: %s  Heading: %.1fdeg (%s / %s)"):format(
    tostring(CFG.rotateWithHeading),
    round1(math.deg(serverHeadingRad)),
    serverHeadingSrc, serverCenterSrc
  ))

  print(("Filters: P=%s F=%s H=%s M=%s"):format(
    tostring(serverCFG.ignorePlayers),
    tostring(serverCFG.ignoreFriendly),
    tostring(serverCFG.ignoreHostile),
    tostring(serverCFG.showOnlyMarked)
  ))

  print(("Selected Ship: %s   (C) cycle  | (X) dispatch | (Z) stop"):format(shipDisplayLine()))

  print("")
  print("T output monitor<->terminal | S list/radar | Q quit")
  print("List: UP/DOWN select, SPACE mark")
  print("Radar: arrows move cursor, SPACE mark nearest")
  print("M onlyMarked | P ignorePlayers | F ignoreFriendly | H ignoreHostile")
  term.redirect(old)
end

-------------------------
-- LIST VIEW
-------------------------
local function setColors(fg, bg)
  if fg then term.setTextColor(fg) end
  if bg then term.setBackgroundColor(bg) end
end

local function drawListToCurrentTerm()
  local showCount = math.min(#list, CFG.maxShow)
  for i=1, showCount do
    local e = list[i]
    local t = e.type or "unknown"
    local n = e.name or "unknown"

    local isSelected = (i == selected)
    local isMk = e.marked == true

    if isSelected then setColors(colors.black, colors.white)
    else setColors(colorByType(t), colors.black) end

    write(isSelected and ">" or " ")

    if isMk then
      term.setTextColor(isSelected and colors.orange or colors.yellow)
      write("*")
    else
      term.setTextColor(isSelected and colors.black or colorByType(t))
      write(" ")
    end

    term.setTextColor(isSelected and colors.black or colorByType(t))
    write((" %s (%s) (%.0f,%.0f,%.0f)"):format(t, n, e.x or 0, e.y or 0, e.z or 0))

    resetColors()
    print("")
  end
  resetColors()
end

-------------------------
-- RADAR VIEW
-------------------------
local function nearestEntityToCursor(cursorX, cursorY, cx, cy, minX, minY, maxX, maxY, scale, headingRad, center)
  local best, bestD = nil, 1e18
  local cosA = math.cos(-headingRad)
  local sinA = math.sin(-headingRad)

  for _, e in ipairs(list) do
    local dx = (e.x - center.x)
    local dz = (e.z - center.z)

    local rdx = dx * cosA - dz * sinA
    local rdz = dx * sinA + dz * cosA

    local sx = cx + math.floor(rdx * scale)
    local sy = cy + math.floor(rdz * scale)

    if sx >= minX and sx <= maxX and sy >= minY and sy <= maxY then
      local dd = (sx - cursorX)*(sx - cursorX) + (sy - cursorY)*(sy - cursorY)
      if dd < bestD then bestD = dd; best = e end
    end
  end
  return best
end

local function drawRadarDotsToCurrentTerm()
  local w, h = term.getSize()
  if w < 5 or h < 5 then
    print("Screen too small"); return
  end

  local cx = math.floor(w/2)
  local cy = math.floor(h/2)

  local minX, minY = 1, 1
  local maxX, maxY = w, h
  if CFG.radarBorder then
    minX, minY = 2, 2
    maxX, maxY = w-1, h-1
  end

  local usableW = maxX - minX
  local usableH = maxY - minY

  eraseLastRadar()

  if CFG.radarBorder then
    rememberBorder(w, h)
    resetColors()
    term.setCursorPos(1,1); write(string.rep("-", w))
    term.setCursorPos(1,h); write(string.rep("-", w))
    for yy=2, h-1 do
      term.setCursorPos(1,yy); write("|")
      term.setCursorPos(w,yy); write("|")
    end
    term.setCursorPos(1,1); write("+")
    term.setCursorPos(w,1); write("+")
    term.setCursorPos(1,h); write("+")
    term.setCursorPos(w,h); write("+")
  else
    rememberBorder(w, h)
  end

  -- ===== RADAR TOAST =====
  eraseLastToast()
  if toastText and toastText ~= "" then
    local tx = minX
    local ty = minY
    local maxLen = (maxX - minX + 1)

    local s = toastText
    if #s > maxLen then s = s:sub(1, maxLen) end

    term.setCursorPos(tx, ty)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.yellow)
    write(s)
    resetColors()

    for i=0, #s-1 do
      lastRadarToast[(tx+i)..","..ty] = true
    end
  end
  -- ===== /RADAR TOAST =====

  local center = serverCenter
  local headingRad = CFG.rotateWithHeading and (serverHeadingRad or 0) or 0

  local scanRadius = tonumber(serverCFG.scanRadius) or 160
  local scaleX = (usableW / 2) / scanRadius
  local scaleY = (usableH / 2) / scanRadius
  local scale = math.min(scaleX, scaleY)

  local cosA = math.cos(-headingRad)
  local sinA = math.sin(-headingRad)

  local normalCells = {}
  local markedCells = {}

  for _, e in ipairs(list) do
    local dx = (e.x - center.x)
    local dz = (e.z - center.z)

    local rdx = dx * cosA - dz * sinA
    local rdz = dx * sinA + dz * cosA

    local sx = cx + math.floor(rdx * scale)
    local sy = cy + math.floor(rdz * scale)

    if sx >= minX and sx <= maxX and sy >= minY and sy <= maxY then
      local key = sx..","..sy
      if e.marked == true then
        markedCells[key] = true
      else
        if not (sx == cx and sy == cy) then
          normalCells[key] = colorByType(e.type)
        end
      end
    end
  end

  resetColors()
  term.setCursorPos(cx, cy)
  term.setTextColor(colors.white)
  write("+")
  lastRadarPoints[cx..","..cy] = true

  for key, col in pairs(normalCells) do
    if not markedCells[key] then
      local xs, ys = key:match("^(%-?%d+),(%-?%d+)$")
      local x = tonumber(xs); local y = tonumber(ys)
      if x and y then
        term.setCursorPos(x, y)
        term.setTextColor(col)
        write(CFG.radarPointChar)
        lastRadarPoints[key] = true
      end
    end
  end

  for key, _ in pairs(markedCells) do
    local xs, ys = key:match("^(%-?%d+),(%-?%d+)$")
    local x = tonumber(xs); local y = tonumber(ys)
    if x and y then
      term.setCursorPos(x, y)
      term.setTextColor(colors.yellow)
      write("*")
      lastRadarPoints[key] = true
    end
  end

  local curX = clamp(cx + radarCursorX, minX, maxX)
  local curY = clamp(cy + radarCursorY, minY, maxY)
  local curKey = curX..","..curY

  term.setCursorPos(curX, curY)
  if markedCells[curKey] then
    term.setBackgroundColor(colors.white)
    term.setTextColor(colors.black)
    write("*")
    resetColors()
  else
    term.setTextColor(colors.white)
    write("X")
    resetColors()
  end

  lastRadarCursor = {x=curX, y=curY}
end

-------------------------
-- DRAW ROUTER
-------------------------
local function entityTermAndStatusTerm()
  local hasMon = (monitor ~= nil)
  if not hasMon then return nativeTerm, nativeTerm end
  if outputTarget == "monitor" then return monitor, nativeTerm end
  return nativeTerm, monitor
end

local function drawEntitiesOn(t)
  local old = term.redirect(t)
  resetColors()

  if viewMode == "list" then
    term.clear()
    term.setCursorPos(1,1)
    drawListToCurrentTerm()
  else
    drawRadarDotsToCurrentTerm()
  end

  term.redirect(old)
end

local function draw()
  syncMonitor()
  local hasMon = (monitor ~= nil)
  if not hasMon then outputTarget = "terminal" end

  local eTerm, sTerm = entityTermAndStatusTerm()
  local showStatus = not (not hasMon and viewMode == "radar")

  if showStatus then
    if sTerm == monitor then
      safeWithMonitor(function()
        drawStatusOnTerm(monitor, hasMon)
      end)
    else
      drawStatusOnTerm(nativeTerm, hasMon)
    end
  end

  if eTerm == monitor then
    safeWithMonitor(function()
      drawEntitiesOn(monitor)
    end)
  else
    drawEntitiesOn(nativeTerm)
  end
end

-------------------------
-- actions (SEND COMMANDS)
-------------------------
local function toggleMarkSelected()
  local e = list[selected]
  if not e then return end
  sendCmd({ cmd="toggle_mark", id=e.id })
end

local function changeRadius(delta)
  local r = tonumber(serverCFG.scanRadius) or 160
  r = clamp(r + delta, 5, 512)
  sendCmd({ cmd="set_radius", value=r })
end

local function radarToggleNearest()
  local eTerm, _ = entityTermAndStatusTerm()
  local w, h

  if eTerm == monitor then
    local ok = safeWithMonitor(function()
      local old = term.redirect(monitor)
      w, h = term.getSize()
      term.redirect(old)
    end)
    if not ok or not w then return end
  else
    w, h = term.getSize()
  end

  local cx = math.floor(w/2)
  local cy = math.floor(h/2)

  local minX, minY = 1, 1
  local maxX, maxY = w, h
  if CFG.radarBorder then
    minX, minY = 2, 2
    maxX, maxY = w-1, h-1
  end

  local usableW = maxX - minX
  local usableH = maxY - minY
  local scanRadius = tonumber(serverCFG.scanRadius) or 160
  local scaleX = (usableW / 2) / scanRadius
  local scaleY = (usableH / 2) / scanRadius
  local scale = math.min(scaleX, scaleY)

  local curX = clamp(cx + radarCursorX, minX, maxX)
  local curY = clamp(cy + radarCursorY, minY, maxY)

  local headingRad = CFG.rotateWithHeading and (serverHeadingRad or 0) or 0
  local e = nearestEntityToCursor(curX, curY, cx, cy, minX, minY, maxX, maxY, scale, headingRad, serverCenter)
  if e then sendCmd({ cmd="toggle_mark", id=e.id }) end
end

-- 找最近标记目标
local function pickNearestMarked()
  local best = nil
  local bestD = 1e18

  local cx = serverCenter.x or 0
  local cy = serverCenter.y or 0
  local cz = serverCenter.z or 0

  for _, e in ipairs(list) do
    if e.marked == true and e.x and e.y and e.z then
      local dx = e.x - cx
      local dy = e.y - cy
      local dz = e.z - cz
      local d2 = dx*dx + dy*dy + dz*dz

      if d2 < bestD then
        bestD = d2
        best = e
      end
    end
  end

  return best
end

-- NEW: Dispatch to selected ship (via SHIP_CMD)
local function dispatchGotoEntity(e)
  if not e then return end
  local ok = sendShipCmd({
    type = "GOTO",
    target = { x=e.x, y=e.y, z=e.z },
    target_name = e.name,
  })
  if ok then
    showToast(string.format("DISPATCH -> %s (%.1f, %.1f, %.1f)", tostring(e.name), e.x or 0, e.y or 0, e.z or 0))
  end
end

local function dispatchStop()
  local ok = sendShipCmd({ type = "STOP" })
  if ok then showToast("STOP -> " .. shipDisplayLine()) end
end

-------------------------
-- main (redraw wakeup)
-------------------------
if monitor then outputTarget = "monitor" else outputTarget = "terminal" end

local running = true
local needsRedraw = false

requestRedraw = function()
  needsRedraw = true
  os.queueEvent("radar_redraw")
end

clearTerm(nativeTerm)
if monitor then clearTerm(monitor) end
resetRadarCache()
draw()

local function handleKey(key)
  syncMonitor()
  local acted = false

  if key == keys.t then
    if monitor then
      outputTarget = (outputTarget == "monitor") and "terminal" or "monitor"
      acted = true
      clearTerm(nativeTerm)
      safeWithMonitor(function() clearTerm(monitor) end)
      resetRadarCache()
    end

  elseif key == keys.s then
    local goingToRadar = (viewMode == "list")
    viewMode = goingToRadar and "radar" or "list"
    acted = true
    local eTerm, _ = entityTermAndStatusTerm()
    if eTerm == monitor then safeWithMonitor(function() clearTerm(monitor) end)
    else clearTerm(nativeTerm) end
    resetRadarCache()
    if goingToRadar then radarCursorX, radarCursorY = 0, 0 end

  elseif key == keys.up then
    if viewMode == "radar" then radarCursorY = radarCursorY - CFG.radarCursorStep
    else selected = math.max(1, selected - 1) end
    acted = true

  elseif key == keys.down then
    if viewMode == "radar" then radarCursorY = radarCursorY + CFG.radarCursorStep
    else
      selected = selected + 1
      local maxSel = math.min(#list, CFG.maxShow)
      if selected > maxSel then selected = maxSel end
      if selected < 1 then selected = 1 end
    end
    acted = true

  elseif key == keys.left then
    if viewMode == "radar" then radarCursorX = radarCursorX - CFG.radarCursorStep; acted = true end
  elseif key == keys.right then
    if viewMode == "radar" then radarCursorX = radarCursorX + CFG.radarCursorStep; acted = true end

  elseif key == keys.space then
    if viewMode == "radar" then radarToggleNearest()
    else toggleMarkSelected() end
    acted = true

  elseif key == keys.m then
    sendCmd({ cmd="set_filter", key="showOnlyMarked" }); acted = true
  elseif key == keys.p then
    sendCmd({ cmd="set_filter", key="ignorePlayers" }); acted = true
  elseif key == keys.f then
    sendCmd({ cmd="set_filter", key="ignoreFriendly" }); acted = true
  elseif key == keys.h then
    sendCmd({ cmd="set_filter", key="ignoreHostile" }); acted = true

  elseif key == keys.leftBracket then
    changeRadius(-10); acted = true
  elseif key == keys.rightBracket then
    changeRadius(10); acted = true

  elseif key == keys.minus then
    changeFontBigger(); acted = true
  elseif key == keys.equals then
    changeFontSmaller(); acted = true

  elseif key == keys.c then
    pickNextShip()
    acted = true

  elseif key == keys.x then
    local e = pickNearestMarked()
    if e then
      dispatchGotoEntity(e)
    else
      showToast("DISPATCH -> (no marked target)")
    end
    acted = true

  elseif key == keys.z then
    dispatchStop()
    acted = true

  elseif key == keys.q then
    running = false
    acted = true
  end

  if acted then requestRedraw() end
end

local function receiverThread()
  while running do
    syncMonitor()

    local sid, msg, proto = rednet.receive(nil, CFG.tick)
    if sid then
      if handleAck(sid, msg, proto) then
        -- ack eaten

      elseif proto == "RADAR_STATE" and type(msg)=="table" and msg.kind=="radar_state" then
        serverCFG = msg.cfg or serverCFG
        serverCenter = msg.center or serverCenter
        serverCenterSrc = msg.centerSrc or serverCenterSrc
        serverHeadingRad = msg.headingRad or serverHeadingRad
        serverHeadingSrc = msg.headingSrc or serverHeadingSrc
        list = msg.list or {}

        if selected > #list then selected = #list end
        if selected < 1 then selected = 1 end

        requestRedraw()

      elseif proto == "SHIP_HELLO" and type(msg)=="table" and msg.kind=="ship_hello" then
        local k = tostring(msg.ship_id or "")
        if k ~= "" then
          ships[k] = ships[k] or {}
          ships[k].name = msg.name or ships[k].name
          ships[k].control_id = msg.control_id or ships[k].control_id
          ships[k].lastSeen = os.clock()
          if not selectedShipKey then selectedShipKey = k end
          requestRedraw()
        end
      end
    end

    -- offline cleanup
    do
      local now = os.clock()
      local changed = false
      for k,sh in pairs(ships) do
        if sh.lastSeen and (now - sh.lastSeen) > SHIP_OFFLINE_SEC then
          ships[k] = nil
          if selectedShipKey == k then selectedShipKey = nil end
          changed = true
        end
      end
      if changed then requestRedraw() end
    end
  end
end

local function inputThread()
  while running do
    local ev, a1 = os.pullEventRaw()
    if ev == "terminate" then
      running = false
      requestRedraw()
    elseif ev == "key" or ev == "key_repeat" then
      handleKey(a1)
    elseif ev == "radar_redraw" then
      -- wakeup
    elseif ev == "timer" then
      if toastTimerId and a1 == toastTimerId then
        toastTimerId = nil
        toastText = nil
        requestRedraw()
      end
    end

    if needsRedraw then
      draw()
      needsRedraw = false
    end
  end
end

parallel.waitForAny(receiverThread, inputThread)

clearTerm(nativeTerm)
if monitor then safeWithMonitor(function() clearTerm(monitor) end) end
