-- radar_server.lua  (SERVER: scan + broadcast + accept commands)
local core = require("radar_core")

-------------------------
-- rednet init (OPEN ALL MODEMS)
-------------------------
local function openAllRednet()
  local opened = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      if not rednet.isOpen(name) then
        rednet.open(name)
      end
      table.insert(opened, name)
    end
  end
  assert(#opened > 0, "No modem found")
  return opened
end

local modems = openAllRednet()
print("[SERVER] Opened modems: " .. table.concat(modems, ", "))

-- host name
pcall(function() rednet.unhost("RADAR") end) -- avoid duplicate host if rebooted weirdly
rednet.host("RADAR", "radar_server")

-------------------------
-- init core (auto find camera)
-------------------------
core.init()
core.applyScanRadius()

local TICK = 0.10

local function packList(list)
  local payload = {}
  for i=1, #list do
    local e = list[i]
    payload[i] = {
      id=e.id, name=e.name, type=e.type,
      x=e.x, y=e.y, z=e.z,
      isPlayer=e.isPlayer,
      marked = core.isMarked(e.id),
    }
  end
  return payload
end

local function broadcastOnce()
  local list = core.refresh()
  local center, centerSrc = core.getCenterPos()
  local headingRad, headingSrc = core.tryGetHeadingRad(list, true)

  rednet.broadcast({
    kind="radar_state",
    cfg = {
      scanRadius = core.CFG.scanRadius,
      ignorePlayers = core.CFG.ignorePlayers,
      showOnlyMarked = core.CFG.showOnlyMarked,
      ignoreFriendly = core.CFG.ignoreFriendly,
      ignoreHostile = core.CFG.ignoreHostile,
    },
    center = center,
    centerSrc = centerSrc,
    headingRad = headingRad,
    headingSrc = headingSrc,
    cameraName = core.getCameraName(),
    list = packList(list),
  }, "RADAR_STATE")
end

local function handleCommand(senderId, msg)
  if type(msg) ~= "table" or msg.kind ~= "radar_cmd" then return end

  -- debug
  print(("[CMD] from %s: %s"):format(tostring(senderId), textutils.serialize(msg)))

  if msg.cmd == "toggle_mark" and msg.id then
    core.toggleMarkById(msg.id)
    broadcastOnce() -- 立刻回显
    return
  end

  if msg.cmd == "set_radius" and type(msg.value) == "number" then
    core.CFG.scanRadius = msg.value
    core.applyScanRadius()
    broadcastOnce()
    return
  end

  if msg.cmd == "set_filter" and type(msg.key) == "string" then
    if core.CFG[msg.key] ~= nil then
      core.CFG[msg.key] = not core.CFG[msg.key]
      broadcastOnce()
    end
    return
  end
end

print("[RADAR SERVER] running")
print("Camera:", core.getCameraName())
print("Protocol: RADAR_STATE / RADAR_CMD")
print("Tick:", TICK)

local running = true

local function broadcastThread()
  while running do
    broadcastOnce()
    sleep(TICK)
  end
end

local function commandThread()
  while running do
    local sid, msg, proto = rednet.receive() -- 不限协议，啥都收
    if sid then
      print("[RECV] proto="..tostring(proto).." from="..tostring(sid).." msg="..textutils.serialize(msg))

      -- 任何人发 hello，我就回一个 ack（用于确认连通）
      if type(msg)=="table" and msg.kind=="hello" then
        rednet.send(sid, {kind="ack", server=os.getComputerID()}, "RADAR_ACK")
      end

      -- 正常命令
      if proto == "RADAR_CMD" then
        handleCommand(sid, msg)
      end
    end
  end
end

local function helloThread()
  while running do
    local sid, msg, proto = rednet.receive("RADAR_HELLO")
    if sid and type(msg)=="table" and msg.kind=="hello" then
      rednet.send(sid, { kind="ack", server=os.getComputerID() }, "RADAR_ACK")
    end
  end
end


local function stopThread()
  os.pullEvent("terminate")
  running = false
end

parallel.waitForAny(broadcastThread, commandThread, helloThread, stopThread)