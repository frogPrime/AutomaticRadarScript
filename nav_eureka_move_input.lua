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
  isBoat = true,            -- ✅ 船模式：只用 x(turn) 和 z(throttle)，永远不动 y（按 B 切换）
  useCruiseAltitude = true, -- 飞艇才用；船模式会强制忽略
  cruiseY = nil,
  cruiseAboveTarget = 12.0,
  climbArriveDy = 1.5,
  descendDist = 22.0,

  -- input tuning
  turnGain = 1.2, -- 船更稳一点（可按需调回 2.0）
  turnMax  = 0.7, -- 船更稳一点（可按需调回 1.0）
  upGain   = 0.2,
  upMax    = 1.0,

  throttleFar = 1.0,
  throttleNear = 0.12, -- 船靠近更慢（可按需调回 0.20）
  slowDist = 60.0,     -- 船减速圈更小（可按需调回 90.0）
  minThrottleDist = 3.5,

  spamEvery = 1.0,

  stopOnNewCommand = true,

  -- ✅ 单机模式：按 / 切换
  singleMode = false,
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
print("Hotkey: press B to toggle BOAT/AIRSHIP mode")
print("Hotkey: press / to toggle SINGLE mode (toggle will STOP immediately)")

local ship=nil
local lastShipAt=0
local prevShip=nil

local target=nil
local lastPrint=0
local mode="DONE"

local cmdSeq = 0
local brakeThisTick = false

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

local function stopNow(reason)
  target=nil
  mode="DONE"
  safeMove(0,0,0)
  if reason then print(reason) end
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

-- ✅ Toggle helper
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

-- ✅ 解析坐标输入：支持 "x y z" 或 "x, y, z"
local function parseCoords(line)
  if type(line) ~= "string" then return nil end
  local s = line:gsub(",", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return nil end
  local a,b,c = s:match("^(-?%d+%.?%d*)%s+(-?%d+%.?%d*)%s+(-?%d+%.?%d*)$")
  if not a then return nil end
  return tonumber(a), tonumber(b), tonumber(c)
end

-- ✅ 事件式输入：按 / 可立即切换(并停船)；支持退格/回车
local function readLineInterruptible(prompt)
  if prompt then io.write(prompt) end
  local buf = ""

  while true do
    local ev, a1 = os.pullEvent()

    if ev == "char" then
      buf = buf .. a1
      io.write(a1)

    elseif ev == "key" then
      if a1 == keys.enter then
        print()
        return buf

      elseif a1 == keys.backspace then
        if #buf > 0 then
          buf = buf:sub(1, -2)
          io.write("\b \b")
        end

      elseif a1 == keys.slash then
        -- ✅ 直接按 / 切换单机模式，并立刻停船
        CFG.singleMode = not CFG.singleMode
        stopNow("SINGLE TOGGLED -> " .. (CFG.singleMode and "ON" or "OFF") .. " (STOPPED)")
        os.queueEvent("single_toggle")
        print() -- 换行，避免光标残留
        return nil
      end
    end
  end
end

-- ✅ 单机输入线程：单机 ON 时输入坐标，新坐标覆盖旧目标
local function singleInputThread()
  while true do
    os.pullEvent("single_toggle")
    if CFG.singleMode then
      print("[SINGLE] ON  输入坐标: x y z 或 x,y,z （按 / 退出，切换会立刻停船）")
      while CFG.singleMode do
        local line = readLineInterruptible("[SINGLE] > ")
        if not CFG.singleMode then break end
        if not line then
          -- 被 / 打断切换了
          break
        end

        local x,y,z = parseCoords(line)
        if x and y and z then
          onNewTarget({x=x, y=y, z=z, name="single"})
        else
          print("[SINGLE] 输入无效。例子: 123 64 -80   或   123,64,-80")
        end
      end
    else
      print("[SINGLE] OFF")
    end
  end
end

-- ✅ Key listener (press B or /)
local function inputThread()
  while true do
    local ev, key = os.pullEvent("key")

    if key == keys.b then
      CFG.isBoat = not CFG.isBoat

      -- brake on toggle to avoid sudden output jumps
      safeMove(0,0,0)

      setModeAfterToggle()

      print("MODE TOGGLED -> " .. (CFG.isBoat and "BOAT (x/z only)" or "AIRSHIP (x/y/z)"))

    elseif key == keys.slash then
      -- ✅ / 切换单机模式：切换就停船（清目标 + 刹车）
      CFG.singleMode = not CFG.singleMode
      stopNow("SINGLE TOGGLED -> " .. (CFG.singleMode and "ON" or "OFF") .. " (STOPPED)")
      os.queueEvent("single_toggle")
    end
  end
end

local function controlThread()
  while true do
    brakeThisTick = false

    -- Step 1: drain messages within tick (non-blocking)
    local t0=os.clock()
    local newestNav = nil

    while (os.clock()-t0) < CFG.tick do
      local sid,msg,proto = rednet.receive(nil, 0)
      if not sid then break end

      if proto==PROTO_SHIP and type(msg)=="table" and msg.kind=="ship_pos" then
        -- IMPORTANT: only accept my ship_id
        if msg.ship_id == SHIP_ID then
          prevShip = ship
          ship = {x=tonumber(msg.x), y=tonumber(msg.y), z=tonumber(msg.z)}
          lastShipAt=os.clock()
        end

      elseif CFG.singleMode and (proto==PROTO_CMD or proto==PROTO_NAV) then
        -- ✅ 单机模式：忽略网络导航/停船指令（只听本地输入）
        -- do nothing

      elseif proto==PROTO_CMD and type(msg)=="table" and msg.kind=="ship_cmd" then
        if msg.ship_id == SHIP_ID and msg.type == "GOTO" and type(msg.target)=="table" then
          newestNav = {
            x=tonumber(msg.target.x),
            y=tonumber(msg.target.y),
            z=tonumber(msg.target.z),
            name = msg.target_name or msg.name or "target"
          }
        elseif msg.ship_id == SHIP_ID and msg.type == "STOP" then
          target=nil
          mode="DONE"
          safeMove(0,0,0)
          print("[CMD] STOP")
        end

      elseif proto==PROTO_NAV and type(msg)=="table" and msg.kind=="nav_goto" then
        -- legacy: broadcast nav (no ship select)
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
            mode = "CRUISE" -- 船永远平面跑
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
            -- 船：只追 x/z，y 保持当前高度（不做升降控制）
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

-- ✅ add inputThread + singleInputThread here
parallel.waitForAny(controlThread, helloThread, inputThread, singleInputThread)
