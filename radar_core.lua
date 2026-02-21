-- radar_core.lua  (scan/marks/filter core, reusable via require)
local M = {}

-- ===== Config =====
M.CFG = {
  scanRadius = 160,
  ignorePlayers = false,
  showOnlyMarked = false,
  ignoreFriendly = false,
  ignoreHostile  = false,

  minRadius = 5,
  maxRadius = 512,
}

local MARK_FILE = "marked_entities.txt"

-- ===== util =====
local function has(p, m) return type(p[m]) == "function" end
local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end
local function strLower(x) return tostring(x or ""):lower() end

-- ===== peripherals =====
local cam, camName

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

-- ===== marks =====
local marks = {}

local function loadMarks()
  local m = {}
  if fs.exists(MARK_FILE) then
    local f = fs.open(MARK_FILE,"r")
    while true do
      local line = f.readLine()
      if not line then break end
      line = line:gsub("%s+$","")
      if #line > 0 then m[line] = true end
    end
    f.close()
  end
  return m
end

local function saveMarks(m)
  local f = fs.open(MARK_FILE,"w")
  for id,val in pairs(m) do
    if val then f.writeLine(id) end
  end
  f.close()
end

function M.isMarked(id) return marks[tostring(id)] == true end

function M.toggleMarkById(id)
  if not id then return end
  id = tostring(id)
  marks[id] = not marks[id]
  saveMarks(marks)
end

function M.getMarksTable() return marks end

-- ===== type helpers (same idea as your script) =====
local function isFriendlyType(t)
  t = strLower(t)
  if t == "player" then return false end
  if t:find("cow") or t:find("sheep") or t:find("pig") or t:find("chicken")
     or t:find("horse") or t:find("donkey") or t:find("mule")
     or t:find("wolf") or t:find("cat") or t:find("fox") or t:find("rabbit")
     or t:find("goat") or t:find("bee") or t:find("parrot") or t:find("turtle")
     or t:find("squid") or t:find("glow_squid") or t:find("dolphin")
     or t:find("axolotl")
     or t:find("villager") or t:find("wandering_trader")
     or t:find("iron_golem") or t:find("snow_golem")
  then return true end
  return false
end

local function isHostileType(t)
  t = strLower(t)
  if t == "player" then return false end
  if t:find("zombie") or t:find("skeleton") or t:find("creeper")
     or t:find("spider") or t:find("cave_spider")
     or t:find("enderman") or t:find("witch")
     or t:find("slime") or t:find("magma_cube")
     or t:find("phantom")
     or t:find("pillager") or t:find("vindicator") or t:find("evoker") or t:find("ravager")
     or t:find("warden")
     or t:find("blaze") or t:find("ghast")
     or t:find("hoglin") or t:find("zoglin") or t:find("piglin_brute")
     or t:find("guardian") or t:find("elder_guardian")
     or t:find("wither") or t:find("wither_skeleton")
  then return true end
  return false
end

-- ===== heading / center (best effort, from your script) =====
local lastCamCenter = { x=0, y=0, z=0 }
local lastCamSrc = "init"

function M.getCenterPos()
  if cam and has(cam, "getCameraPosition") then
    local ok, p = pcall(function() return cam.getCameraPosition() end)
    if ok and type(p) == "table" then
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

  if cam and has(cam, "getPosition") then
    local ok, p = pcall(function() return cam.getPosition() end)
    if ok and type(p) == "table" then
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

  if cam and has(cam, "getX") and has(cam, "getY") and has(cam, "getZ") then
    local okX, x = pcall(function() return cam.getX() end)
    local okY, y = pcall(function() return cam.getY() end)
    local okZ, z = pcall(function() return cam.getZ() end)
    x,y,z = tonumber(x),tonumber(y),tonumber(z)
    if okX and okY and okZ and x and y and z then
      lastCamCenter = {x=x,y=y,z=z}
      lastCamSrc = "cam.getXYZ"
      return lastCamCenter, lastCamSrc
    end
  end

  return lastCamCenter, "last("..tostring(lastCamSrc)..")"
end

local function headingFromFacingString(f)
  f = strLower(f)
  if f == "north" then return math.pi end
  if f == "south" then return 0 end
  if f == "west"  then return math.pi/2 end
  if f == "east"  then return -math.pi/2 end
  return nil
end

function M.tryGetHeadingRad(currentList, rotateWithHeading)
  if rotateWithHeading == false then
    return 0, "rotate=off"
  end

  if cam and has(cam, "getYaw") then
    local ok, v = pcall(function() return cam.getYaw() end)
    if ok and type(v) == "number" then
      local rad = v
      if math.abs(v) > (2*math.pi + 0.1) then rad = math.rad(v) end
      return rad, "cam.getYaw"
    end
  end

  if cam and has(cam, "getRotation") then
    local ok, v = pcall(function() return cam.getRotation() end)
    if ok then
      if type(v) == "number" then
        local rad = v
        if math.abs(v) > (2*math.pi + 0.1) then rad = math.rad(v) end
        return rad, "cam.getRotation(num)"
      elseif type(v) == "table" then
        local y = v.yaw or v.y or v[1]
        if type(y) == "number" then
          local rad = y
          if math.abs(y) > (2*math.pi + 0.1) then rad = math.rad(y) end
          return rad, "cam.getRotation(tbl)"
        end
      end
    end
  end

  if cam and has(cam, "getFacing") then
    local ok, f = pcall(function() return cam.getFacing() end)
    if ok and f then
      local rad = headingFromFacingString(f)
      if rad then return rad, "cam.getFacing" end
    end
  end

  -- fallback: 0
  return 0, "heading=0(fallback)"
end

-- ===== init =====
function M.init(cfgOverride)

  -- 自动打开 modem
  local modem = peripheral.find("modem")
  if modem then
    local side = peripheral.getName(modem)
    if not rednet.isOpen(side) then
      rednet.open(side)
    end
  end

  if cfgOverride then
    for k,v in pairs(cfgOverride) do M.CFG[k] = v end
  end

  cam, camName = findCamera()
  if not cam then error("No camera found in network") end

  marks = loadMarks()

  M.applyScanRadius()
  return true
end

function M.getCameraName() return camName end

function M.applyScanRadius()
  M.CFG.scanRadius = clamp(tonumber(M.CFG.scanRadius) or 160, M.CFG.minRadius, M.CFG.maxRadius)
  if cam and cam.setClipRange then
    pcall(function() cam.setClipRange(M.CFG.scanRadius) end)
  end
end

-- ===== scan/refresh =====
-- FIX: robust world-coordinate extraction (VS ship armor stand safe)
local function posFrom(t)
  if type(t) ~= "table" then return nil end
  local x = tonumber(t.x or t[1])
  local y = tonumber(t.y or t[2])
  local z = tonumber(t.z or t[3])
  if x and y and z then return x,y,z end
  return nil
end

local function isSaneXYZ(x,y,z)
  -- reject absurd local/transform coords
  return math.abs(x) < 1000000 and math.abs(y) < 1000000 and math.abs(z) < 1000000
end

local function extractXYZ(e)
  if type(e) ~= "table" then return nil end

  local fallback = nil

  local function consider(v)
    local x,y,z = posFrom(v)
    if x and y and z then
      if isSaneXYZ(x,y,z) then return x,y,z,true end
      if not fallback then fallback = {x=x,y=y,z=z} end
    end
    return nil,nil,nil,false
  end

  -- 注意：不要用 candidates + ipairs（会被 nil 截断）
  do local x,y,z,ok = consider(e.worldPos);       if ok then return x,y,z end end
  do local x,y,z,ok = consider(e.worldpos);       if ok then return x,y,z end end
  do local x,y,z,ok = consider(e.worldPosition);  if ok then return x,y,z end end
  do local x,y,z,ok = consider(e.world_position); if ok then return x,y,z end end

  do local x,y,z,ok = consider(e.globalPos);      if ok then return x,y,z end end
  do local x,y,z,ok = consider(e.globalpos);      if ok then return x,y,z end end
  do local x,y,z,ok = consider(e.absolutePos);    if ok then return x,y,z end end
  do local x,y,z,ok = consider(e.absolutepos);    if ok then return x,y,z end end

  do local x,y,z,ok = consider(e.posWorld);       if ok then return x,y,z end end
  do local x,y,z,ok = consider(e.world);          if ok then return x,y,z end end
  do local x,y,z,ok = consider(e.abs);            if ok then return x,y,z end end

  do local x,y,z,ok = consider(e.pos);            if ok then return x,y,z end end
  do local x,y,z,ok = consider(e.position);       if ok then return x,y,z end end
  do local x,y,z,ok = consider(e.location);       if ok then return x,y,z end end

  do local x,y,z,ok = consider(e);                if ok then return x,y,z end end

  if fallback then return fallback.x, fallback.y, fallback.z end
  return nil
end


local function scan()
  local raw
  if cam.getEntities then raw = cam.getEntities(M.CFG.scanRadius)
  else raw = cam.getMobs(M.CFG.scanRadius) end

  local out = {}
  if type(raw) ~= "table" then return out end

  for _,e in pairs(raw) do
    local id = e.id or e.uuid or e.UUID or e.uniqueId or e.name
    local name = e.name or e.displayName or e.customName or tostring(id)
    local etype = e.type or e.entityType or e.mobType or e.id or "unknown"
    if type(etype) == "string" then etype = etype:gsub("^minecraft:","") end

    -- ===== FIXED COORDS HERE =====
    local x,y,z = extractXYZ(e)
    -- ===========================

    if id and x and y and z then
      local rt = strLower(e.type)
      local et = strLower(etype)
      local en = strLower(e.entityType)
      local un = strLower(e.username or e.user or e.playerName)

      local isPlayer =
        (e.isPlayer == true) or (e.isPlayer == "true") or
        (#un > 0) or
        (rt:find("player", 1, true) ~= nil) or
        (et:find("player", 1, true) ~= nil) or
        (en:find("player", 1, true) ~= nil)

      if not (M.CFG.ignorePlayers and isPlayer) then
        table.insert(out,{
          id=tostring(id),
          name=tostring(name),
          type=tostring(etype),
          x=tonumber(x), y=tonumber(y), z=tonumber(z),
          isPlayer=isPlayer,
          raw=e,
        })
      end
    end
  end

  table.sort(out,function(a,b)
    if a.type == b.type then return a.name < b.name end
    return a.type < b.type
  end)

  return out
end

local list = {}

function M.refresh()
  local raw = scan()
  local filtered = {}

  for _,e in ipairs(raw) do
    local t = e.type
    if M.CFG.ignoreFriendly and isFriendlyType(t) then
      -- skip
    elseif M.CFG.ignoreHostile and isHostileType(t) then
      -- skip
    else
      if (not M.CFG.showOnlyMarked) or marks[e.id] then
        table.insert(filtered, e)
      end
    end
  end

  list = filtered
  return list
end

function M.getList() return list end

function M.getMarkedList()
  local out = {}
  for _,e in ipairs(list) do
    if marks[e.id] then table.insert(out, e) end
  end
  return out
end

function M.pickNearestMarked()
  local center = select(1, M.getCenterPos())
  local best, bestD = nil, 1e18
  for _,e in ipairs(list) do
    if marks[e.id] then
      local dx,dy,dz = e.x-center.x, e.y-center.y, e.z-center.z
      local d2 = dx*dx + dy*dy + dz*dz
      if d2 < bestD then bestD = d2; best = e end
    end
  end
  return best
end

return M
