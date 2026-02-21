-- radar_server.lua  (SERVER: scan + broadcast + accept commands)
local core = require("radar_core")

-------------------------
-- CONFIG
-------------------------
local PROTO_HOST = "RADAR"

-- 1) hostname 选择：
--    A. 固定名字（可能冲突）
-- local HOSTNAME = "radar_server"

--    B. 永不冲突（推荐）：带上 computerId
local HOSTNAME = "radar_server_" .. os.getComputerID()

-- 2) 管理口令（想远程关机就用它；不想要就留空字符串）
local ADMIN_KEY = "change_me"  -- TODO: 改成你自己的；不想启用就设为 ""

-- 3) 管理协议名
local ADMIN_PROTO = "RADAR_ADMIN"

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

-------------------------
-- Host (fix: unhost needs hostname)
-------------------------
pcall(function() rednet.unhost(PROTO_HOST, HOSTNAME) end)
local ok, err = pcall(function() rednet.host(PROTO_HOST, HOSTNAME) end)
if not ok then
  print("[HOST] failed:", err)

  -- 如果你用了固定 hostname，且被占用，这里给一个自动 fallback
  -- （如果你已经用 radar_server_<id>，一般永远不会进到这里）
  if tostring(err):find("Hostname in use") then
    local fallback = HOSTNAME .. "_alt"
    print("[HOST] Hostname in use, fallback to:", fallback)
    HOSTNAME = fallback
    pcall(function() rednet.unhost(PROTO_HOST, HOSTNAME) end)
    assert(pcall(function() rednet.host(PROTO_HOST, HOSTNAME) end))
  else
    error(err)
  end
end
print("[HOST] protocol=" .. PROTO_HOST .. " hostname=" .. HOSTNAME)

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

    -- 附带服务器标识，方便客户端过滤不串台
    serverId = os.getComputerID(),
    hostname = HOSTNAME,
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

-- 管理命令：远程停机/重启/停广播
local running = true
local broadcastEnabled = true

local function handleAdmin(senderId, msg, proto)
  if proto ~= ADMIN_PROTO then return false end
  if type(msg) ~= "table" then return true end

  -- 未启用管理口令：直接忽略
  if ADMIN_KEY == "" then
    print("[ADMIN] disabled, ignoring from", senderId)
    return true
  end

  if msg.key ~= ADMIN_KEY then
    print("[ADMIN] bad key from", senderId)
    return true
  end

  local cmd = msg.cmd
  print(("[ADMIN] cmd=%s from=%s"):format(tostring(cmd), tostring(senderId)))

  if cmd == "shutdown" then
    rednet.send(senderId, {ok=true, msg="shutting down"}, ADMIN_PROTO)
    os.shutdown()
    return true
  end

  if cmd == "reboot" then
    rednet.send(senderId, {ok=true, msg="rebooting"}, ADMIN_PROTO)
    os.reboot()
    return true
  end

  if cmd == "stop" then
    running = false
    rednet.send(senderId, {ok=true, msg="stopping server loop"}, ADMIN_PROTO)
    return true
  end

  if cmd == "broadcast_off" then
    broadcastEnabled = false
    rednet.send(senderId, {ok=true, msg="broadcast disabled"}, ADMIN_PROTO)
    return true
  end

  if cmd == "broadcast_on" then
    broadcastEnabled = true
    rednet.send(senderId, {ok=true, msg="broadcast enabled"}, ADMIN_PROTO)
    return true
  end

  if cmd == "status" then
    rednet.send(senderId, {
      ok=true,
      running=running,
      broadcastEnabled=broadcastEnabled,
      serverId=os.getComputerID(),
      hostname=HOSTNAME
    }, ADMIN_PROTO)
    return true
  end

  rednet.send(senderId, {ok=false, msg="unknown admin cmd"}, ADMIN_PROTO)
  return true
end

print("[RADAR SERVER] running")
print("Camera:", core.getCameraName())
print("Protocol: RADAR_STATE / RADAR_CMD / RADAR_HELLO / RADAR_ACK / " .. ADMIN_PROTO)
print("Tick:", TICK)

local function broadcastThread()
  while running do
    if broadcastEnabled then
      broadcastOnce()
    end
    sleep(TICK)
  end
end

local function commandThread()
  while running do
    local sid, msg, proto = rednet.receive() -- 不限协议，啥都收
    if sid then
      -- 管理命令优先处理
      if handleAdmin(sid, msg, proto) then
        -- handled
      else
        print("[RECV] proto="..tostring(proto).." from="..tostring(sid).." msg="..textutils.serialize(msg))

        -- 任何人发 hello，我就回一个 ack（用于确认连通）
        if type(msg)=="table" and msg.kind=="hello" then
          rednet.send(sid, {
            kind="ack",
            server=os.getComputerID(),
            hostname=HOSTNAME,
          }, "RADAR_ACK")
        end

        -- 正常命令
        if proto == "RADAR_CMD" then
          handleCommand(sid, msg)
        end
      end
    end
  end
end

local function helloThread()
  while running do
    local sid, msg, proto = rednet.receive("RADAR_HELLO")
    if sid and type(msg)=="table" and msg.kind=="hello" then
      rednet.send(sid, {
        kind="ack",
        server=os.getComputerID(),
        hostname=HOSTNAME,
      }, "RADAR_ACK")
    end
  end
end

local function stopThread()
  os.pullEvent("terminate")
  running = false
end

parallel.waitForAny(broadcastThread, commandThread, helloThread, stopThread)
