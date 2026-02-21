-- ship_pos_broadcast.lua
-- broadcast CAMERA center position (tagged by ship_id = ship-<helm_id>)

local PROTO = "SHIP_POS"
local TICK  = 0.05

-- IMPORTANT: set this to the helm computer ID on the SAME ship
local HELM_ID = 6  -- <<< 改成你那台 helm 电脑的 ID

local SHIP_ID = "ship-" .. tostring(HELM_ID)

-- open modems
for _, n in ipairs(peripheral.getNames()) do
  if peripheral.getType(n) == "modem" then
    rednet.open(n)
  end
end

local function has(p, m) return type(p[m]) == "function" end

-- same camera detection as radar_core.lua
local function findCamera()
  local sides = {"top","bottom","left","right","front","back"}
  for _, side in ipairs(sides) do
    if peripheral.isPresent(side) then
      local p = peripheral.wrap(side)
      if p and (has(p,"getEntities") or has(p,"getMobs")) then
        return p, side
      end
    end
  end
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if p and (has(p,"getEntities") or has(p,"getMobs")) then
      return p, name
    end
  end
  return nil, nil
end

local cam, camName = findCamera()
assert(cam, "No camera found")

local lastCamCenter = { x=0, y=0, z=0 }
local lastCamSrc = "init"

local function getCenterPos()
  if has(cam, "getCameraPosition") then
    local ok, p = pcall(function() return cam.getCameraPosition() end)
    if ok and type(p)=="table" then
      local x = tonumber(p.x or p[1])
      local y = tonumber(p.y or p[2])
      local z = tonumber(p.z or p[3])
      if x and y and z then
        lastCamCenter = {x=x,y=y,z=z}
        lastCamSrc = "cam.getCameraPosition"
        return lastCamCenter, lastCamSrc
      end
    end
  end

  if has(cam, "getPosition") then
    local ok, p = pcall(function() return cam.getPosition() end)
    if ok and type(p)=="table" then
      local x = tonumber(p.x or p[1])
      local y = tonumber(p.y or p[2])
      local z = tonumber(p.z or p[3])
      if x and y and z then
        lastCamCenter = {x=x,y=y,z=z}
        lastCamSrc = "cam.getPosition"
        return lastCamCenter, lastCamSrc
      end
    end
  end

  if has(cam,"getX") and has(cam,"getY") and has(cam,"getZ") then
    local okX,x = pcall(function() return cam.getX() end)
    local okY,y = pcall(function() return cam.getY() end)
    local okZ,z = pcall(function() return cam.getZ() end)
    x,y,z = tonumber(x),tonumber(y),tonumber(z)
    if okX and okY and okZ and x and y and z then
      lastCamCenter = {x=x,y=y,z=z}
      lastCamSrc = "cam.getXYZ"
      return lastCamCenter, lastCamSrc
    end
  end

  return lastCamCenter, "last("..lastCamSrc..")"
end

print("[SHIP_POS] Camera:", camName)
print("[SHIP_POS] CameraPC ID:", os.getComputerID())
print("[SHIP_POS] HELM_ID:", HELM_ID, "-> ship_id:", SHIP_ID)
print("[SHIP_POS] Started")

local lastPrint = ""

while true do
  local pos, src = getCenterPos()
  if pos then
    local x,y,z = pos.x,pos.y,pos.z

    rednet.broadcast({
      kind="ship_pos",
      ship_id = SHIP_ID,
      helm_id = HELM_ID,
      x=x,y=y,z=z,
      src=src,
      camName=camName
    }, PROTO)

    local key = ("%d,%d,%d"):format(x,y,z)
    if key ~= lastPrint then
      lastPrint = key
      print(string.format("[CAM] X:%d  Y:%d  Z:%d  (%s) ship_id=%s", x,y,z,src,SHIP_ID))
    end
  end
  sleep(TICK)
end
