-- nav_eureka_move_input.lua
-- SHIP_POS: ship world position (from camera-on-ship) tagged by ship_id
-- SHIP_CMD: target commands for a specific ship_id (from UI)
-- RADAR_NAV: legacy broadcast target (kept for compatibility)
-- Control with helm.move(x=turn, y=up/down, z=throttle) as INPUTS (NOT coords)

local PROTO_NAV   = "RADAR_NAV"  -- legacy
local PROTO_SHIP  = "SHIP_POS"

local PROTO_HELLO = "SHIP_HELLO"
local PROTO_CMD   = "SHIP_CMD"

-- Auto identity = helm computer ID
local SHIP_ID   = "ship-" .. tostring(os.getComputerID())
local SHIP_NAME = "ship@" .. tostring(os.getComputerID())

local CFG = {
  tick = 0.05,
  posTimeout = 1.0,

  arriveDist = 3.5,

  -- MODE
  isBoat = true,            -- 船模式：只用 x(turn) 和 z(throttle)，永远不动 y（按 B 切换）
  useCruiseAltitude = true, -- 飞艇才用；船模式会强制忽略
  cruiseY = nil,
  cruiseAboveTarget = 12.0,
  climbArriveDy = 1.5,
  descendDist = 22.0,

  -- NET MODE
  netOnline = true,         -- ONLINE=接收 SHIP_CMD；OFFLINE=手动输入坐标（仍接收 SHIP_POS）

  -- input tuning
  turnGain = 1.2,
  turnMax  = 0.7,
  upGain   = 0.2,
  upMax    = 1.0,

  throttleFar = 1.0,
  throttleNear = 0.12,
  slowDist = 60.0,
  minThrottleDist = 3.5,

  spamEvery = 1.0,

  stopOnNewCommand = true,
}

for _,n in ipairs(peripheral.getNames()) do
  if peripheral.getType(n)=="modem" then rednet.open(n) end
end

local helm = peripheral.find("eureka_ship_helm")
assert(helm, "No eureka_ship_helm found")

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end
local function fmt1(x) return string.format("%.1f", tonumber(x) or 0) end

local function dist3(a,b)
  local dx=a.x-b.x; local dy=a.y-b.y; local dz=a.z-b.z
  return math.sqrt(dx*dx+dy*dy+dz*dz)
end
local function dist2(a,b)
  local dx=a.x-b.x; local dz=a.z-b.z
  return math.sqrt(dx*dx+dz*dz)
end

local function pickCruiseY(targetY)
  if not CFG.useCruiseAltitude then return targetY end
  if type(CFG.cruiseY)=="number" then return CFG.cruiseY end
  return (targetY or 0) + (CFG.cruiseAboveTarget or 0)
end

local function safeMove(x,y,z)
  local ok, err = pcall(function()
    helm.move(x,y,z)
  end)
  if not ok then print("helm.move ERROR:", err) end
  return ok
end

local function angleWrap(a)
  while a >  math.pi do a = a - 2*math.pi end
  while a < -math.pi do a = a + 2*math.pi end
  return a
end

print("Eureka NAV(move-input) ready. ID="..os.getComputerID())
print("SHIP_ID:", SHIP_ID, " NAME:", SHIP_NAME)
print("Listening:", PROTO_CMD, PROTO_NAV, "and", PROTO_SHIP)
print("move inputs: x=turn, y=up/down, z=throttle")
print("MODE:", CFG.isBoat and "BOAT (x/z only)" or "AIRSHIP (x/y/z)")
print("NET:", CFG.netOnline and "ONLINE (accept SHIP_CMD)" or "OFFLINE (manual goto)")
print("Hotkey: press B to toggle BOAT/AIRSHIP mode")
print("Hotkey: press M to toggle OFFLINE/ONLINE (STOP+CLEAR)")
print("OFFLINE commands: goto x y z  |  stop")

local ship=nil
local lastShipAt=0
local prevShip=nil

local target=nil
local lastPrint=0
local mode="DONE"

local cmdSeq = 0
local brakeThisTick = false

-- 防止按键切换把字符残留到输入里（m/b）
local consoleJustToggled = false

-- STOP + CLEAR helper
local function stopAndClear(reason)
  target=nil
  mode="DONE"
  prevShip=nil
  brakeThisTick=false
  safeMove(0,0,0)
  if reason then print(reason) end
end

local function onNewTarget(t)
  cmdSeq = cmdSeq + 1
  target = t

  if CFG.isBoat then
    mode = "CRUISE"
  else
    mode = CFG.useCruiseAltitude and "CLIMB" or "DESCEND"
  end

  prevShip = nil

  brakeThisTick = CFG.stopOnNewCommand == true
  if brakeThisTick then
    safeMove(0,0,0)
  end

  print(("[CMD#%d] TARGET → %s (%s,%s,%s)"):format(
    cmdSeq,
    tostring(target.name),
    fmt1(target.x), fmt1(target.y), fmt1(target.z)
  ))
end

local function helloThread()
  while true do
    rednet.broadcast({
      kind = "ship_hello",
      ship_id = SHIP_ID,
      name = SHIP_NAME,
      control_id = os.getComputerID(),
      ts = os.epoch("utc"),
    }, PROTO_HELLO)
    sleep(1)
  end
end

-- Toggle helper
local function setModeAfterToggle()
  if not target then
    mode = "DONE"
    return
  end
  if CFG.isBoat then
    mode = "CRUISE"
  else
    mode = CFG.useCruiseAltitude and "CLIMB" or "DESCEND"
    prevShip = nil
  end
end

-- ✅ 安全读取一行：不吞 rednet_message（会把非输入事件放回队列）
local function readLineSafe(prompt)
  if prompt then write(prompt) end
  local buf = ""

  while true do
    local ev = {os.pullEventRaw()} -- 不会被 terminate 直接打断（可选）

    local name = ev[1]
    if name == "char" then
      local ch = ev[2]
      buf = buf .. ch
      write(ch)

    elseif name == "paste" then
      local txt = ev[2] or ""
      buf = buf .. txt
      write(txt)

    elseif name == "key" then
      local k = ev[2]
      if k == keys.enter then
        print()
        return buf
      elseif k == keys.backspace then
        if #buf > 0 then
          buf = buf:sub(1, -2)
          -- 光标回退擦除
          local x, y = term.getCursorPos()
          if x > 1 then
            term.setCursorPos(x - 1, y)
            write(" ")
            term.setCursorPos(x - 1, y)
          end
        end
      end

    else
      -- ✅ 关键：把非输入事件（比如 rednet_message）放回队列，别吃掉
      os.queueEvent(table.unpack(ev))
      sleep(0)
    end
  end
end

-- Key listener (press B/M)
local function inputThread()
  while true do
    local ev, key = os.pullEvent("key")
    if key == keys.b then
      CFG.isBoat = not CFG.isBoat
      safeMove(0,0,0)
      setModeAfterToggle()
      consoleJustToggled = true
      print("MODE TOGGLED -> " .. (CFG.isBoat and "BOAT (x/z only)" or "AIRSHIP (x/y/z)"))

    elseif key == keys.m then
      CFG.netOnline = not CFG.netOnline
      stopAndClear("[NET] TOGGLED -> " .. (CFG.netOnline and "ONLINE (accept SHIP_CMD)" or "OFFLINE (manual goto)") .. " | STOPPED+CLEARED")
      consoleJustToggled = true
      if not CFG.netOnline then
        print("OFFLINE commands: goto x y z  |  stop")
      end
    end
  end
end

-- OFFLINE console: manual goto/stop (new command overrides old)
local function offlineConsoleThread()
  while true do
    if CFG.netOnline then
      sleep(0.2)
    else
      -- 吞掉刚切换带来的残留 m/b，但不吞其它事件
      if consoleJustToggled then
        consoleJustToggled = false
        while true do
          local ev = {os.pullEvent()}
          if ev[1] == "char" or ev[1] == "key" then
            -- 丢弃一次输入残留即可（m/b 的 char，或者 key 释放等）
            -- 如果你想更严格只丢 char，可改成只丢 char
          else
            os.queueEvent(table.unpack(ev))
            break
          end
          -- 再丢一次就够了，避免无限循环
          break
        end
      end

      local line = readLineSafe("[OFFLINE] > ")
      if line then
        local parts = {}
        for w in string.gmatch(tostring(line), "%S+") do
          table.insert(parts, w)
        end

        local cmd = (parts[1] or ""):lower()
        if cmd == "goto" then
          local x = tonumber(parts[2])
          local y = tonumber(parts[3])
          local z = tonumber(parts[4])
          if x and y and z then
            onNewTarget({x=x, y=y, z=z, name="manual"})
          else
            print("Usage: goto x y z")
          end

        elseif cmd == "stop" then
          stopAndClear("[OFFLINE] STOP")

        elseif cmd == "" then
          -- ignore
        else
          print("Commands: goto x y z | stop")
        end
      end
    end
  end
end

local function controlThread()
  while true do
    brakeThisTick = false

    -- drain messages within tick (non-blocking)
    local t0=os.clock()
    local newestNav = nil

    while (os.clock()-t0) < CFG.tick do
      local sid,msg,proto = rednet.receive(nil, 0)
      if not sid then break end

      if proto==PROTO_SHIP and type(msg)=="table" and msg.kind=="ship_pos" then
        -- IMPORTANT: only accept my ship_id (始终接收)
        if msg.ship_id == SHIP_ID then
          prevShip = ship
          ship = {x=tonumber(msg.x), y=tonumber(msg.y), z=tonumber(msg.z)}
          lastShipAt=os.clock()
        end

      elseif proto==PROTO_CMD and type(msg)=="table" and msg.kind=="ship_cmd" then
        -- ONLINE 才接收来自客户端/服务器的指令；OFFLINE 忽略
        if CFG.netOnline then
          if msg.ship_id == SHIP_ID and msg.type == "GOTO" and type(msg.target)=="table" then
            newestNav = {
              x=tonumber(msg.target.x),
              y=tonumber(msg.target.y),
              z=tonumber(msg.target.z),
              name = msg.target_name or msg.name or "target"
            }
          elseif msg.ship_id == SHIP_ID and msg.type == "STOP" then
            stopAndClear("[CMD] STOP")
          end
        end

      elseif proto==PROTO_NAV and type(msg)=="table" and msg.kind=="nav_goto" then
        newestNav = {x=tonumber(msg.x), y=tonumber(msg.y), z=tonumber(msg.z), name=msg.name}
      end
    end

    if newestNav then
      onNewTarget(newestNav)
    end

    if brakeThisTick then
      sleep(0)
      goto continue
    end

    if target then
      if (not ship) or (os.clock()-lastShipAt > CFG.posTimeout) then
        if os.clock()-lastPrint > CFG.spamEvery then
          print("Waiting SHIP_POS ("..SHIP_ID..") ...")
          lastPrint=os.clock()
        end
      else
        local dAll = dist3(ship, target)
        local dXZ  = dist2(ship, target)
        local cruiseY = pickCruiseY(target.y)

        if dAll <= CFG.arriveDist then
          safeMove(0,0,0)
          print(("[CMD#%d] ARRIVED ✓ ship=(%s,%s,%s)"):format(cmdSeq, fmt1(ship.x),fmt1(ship.y),fmt1(ship.z)))
          target=nil
          mode="DONE"
        else
          -- MODE SWITCHING
          if CFG.isBoat then
            mode = "CRUISE"
          else
            if CFG.useCruiseAltitude then
              if mode=="CLIMB" and math.abs(ship.y - cruiseY) <= CFG.climbArriveDy then
                mode="CRUISE"
              elseif mode=="CRUISE" and dXZ <= CFG.descendDist then
                mode="DESCEND"
              end
            else
              mode="DESCEND"
            end
          end

          -- Desired point
          local desired
          if CFG.isBoat then
            desired = {x=target.x, y=ship.y, z=target.z}
          else
            if not CFG.useCruiseAltitude then
              desired = {x=target.x, y=target.y, z=target.z}
            else
              if mode=="CLIMB" then
                desired = {x=ship.x, y=cruiseY, z=ship.z}
              elseif mode=="CRUISE" then
                desired = {x=target.x, y=cruiseY, z=target.z}
              else
                desired = {x=target.x, y=target.y, z=target.z}
              end
            end
          end

          -- Heading control (based on desired x/z)
          local tx = desired.x - ship.x
          local tz = desired.z - ship.z
          local targetYaw = math.atan2(tx, tz)

          local curYaw = targetYaw
          local yawSrc = "fallback"
          if prevShip then
            local vx = ship.x - prevShip.x
            local vz = ship.z - prevShip.z
            if (vx*vx + vz*vz) > 1e-6 then
              curYaw = math.atan2(vx, vz)
              yawSrc = "vel"
            end
          end

          local yawErr = angleWrap(targetYaw - curYaw)
          local turn = clamp(yawErr * CFG.turnGain, -CFG.turnMax, CFG.turnMax)

          -- Throttle scheduling by distance
          local t = clamp(dXZ / CFG.slowDist, 0, 1)
          local throttle = CFG.throttleNear + (CFG.throttleFar - CFG.throttleNear) * t
          if dXZ < CFG.minThrottleDist then
            throttle = throttle * (dXZ / CFG.minThrottleDist)
          end
          throttle = clamp(throttle, -1.0, 1.0)

          -- Up/down axis
          local up
          if CFG.isBoat then
            up = 0
          else
            local yErr = desired.y - ship.y
            up = clamp(yErr * CFG.upGain, -CFG.upMax, CFG.upMax)
          end

          safeMove(turn, up, throttle)

          if os.clock()-lastPrint > CFG.spamEvery then
            print(("[CMD#%d][%s] ship=(%s,%s,%s) d=%.1f dXZ=%.1f turn=%s up=%s thr=%s yawErr=%s (%s)"):format(
              cmdSeq, mode,
              fmt1(ship.x),fmt1(ship.y),fmt1(ship.z),
              dAll, dXZ,
              fmt1(turn), fmt1(up), fmt1(throttle),
              fmt1(yawErr), yawSrc
            ))
            lastPrint=os.clock()
          end
        end
      end
    end

    ::continue::
    sleep(0)
  end
end

parallel.waitForAny(controlThread, helloThread, inputThread, offlineConsoleThread)
