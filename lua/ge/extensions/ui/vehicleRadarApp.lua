-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- this is the lua part of the vehicle vicinity app

local M = {}

local min, max, floor, atan2, huge = math.min, math.max, math.floor, math.atan2, math.huge

local couplerCache = {}
local objectCache = {}
local paintColorCache = {}
local jbeamLowerCache = {}
local settingsFilePath = "settings/ui_apps/appsSettings/vehicleRadarSettings.json"
local gamma = 1 / 2.2
local proximityThreshold = 2.5
local maxPossibleVehExtent = 15

local oobb_corners1 = {}
local oobb_corners2 = {}
for i = 1, 8 do
  oobb_corners1[i] = vec3()
  oobb_corners2[i] = vec3()
end
local oobb_edges = {
  {1, 2}, {2, 4}, {4, 3}, {3, 1},
  {5, 6}, {6, 8}, {8, 7}, {7, 5},
  {1, 5}, {2, 6}, {3, 7}, {4, 8}
}

local settings = {
  rangeMeters = 13,
  rangeSeconds = 0.8,
  foreAftOffsetPct = 0,
  rangeType = 'distance',
  minimalLook = false,
  coloredCars = true
}

local function loadSettings()
  local data = jsonReadFile(settingsFilePath)
  if data then
    for k, v in pairs(data) do
      settings[k] = v
    end
  end
end

local function saveSettings()
  local dir = "settings/ui_apps/appsSettings"
  if not FS:directoryExists(dir) then
    FS:directoryCreate(dir, true)
  end
  jsonWriteFile(settingsFilePath, settings, true)
end

local function onExtensionLoaded()
  loadSettings()
  guihooks.trigger('VehicleRadarSettingsLoaded', settings)
end

local function updateSetting(key, value)
  if settings[key] ~= nil then
    settings[key] = value
    saveSettings()
  end
end

-- Minimum distance between two oriented bounding boxes
local function oobbToOobbDistance(bb1, bb2)
  local corners1 = oobb_corners1
  local corners2 = oobb_corners2
  local edges = oobb_edges

  for i = 0, 7 do
    corners1[i + 1]:set(bb1:getPoint(i))
    corners2[i + 1]:set(bb2:getPoint(i))
  end

  local minDist = huge

  for ci = 1, 8 do
    local corner = corners1[ci]
    for ei = 1, 12 do
      local edge = edges[ei]
      local dist = corner:distanceToLineSegment(corners2[edge[1]], corners2[edge[2]])
      if dist < minDist then minDist = dist end
    end
  end

  for ci = 1, 8 do
    local corner = corners2[ci]
    for ei = 1, 12 do
      local edge = edges[ei]
      local dist = corner:distanceToLineSegment(corners1[edge[1]], corners1[edge[2]])
      if dist < minDist then minDist = dist end
    end
  end

  for ei1 = 1, 12 do
    local edge1 = edges[ei1]
    local e1p1 = corners1[edge1[1]]
    local e1p2 = corners1[edge1[2]]
    for ei2 = 1, 12 do
      local edge2 = edges[ei2]
      local e2p1 = corners2[edge2[1]]
      local e2p2 = corners2[edge2[2]]
      local dist = e1p1:distanceToLineSegment(e2p1, e2p2)
      if dist < minDist then minDist = dist end
      dist = e1p2:distanceToLineSegment(e2p1, e2p2)
      if dist < minDist then minDist = dist end
      dist = e2p1:distanceToLineSegment(e1p1, e1p2)
      if dist < minDist then minDist = dist end
      dist = e2p2:distanceToLineSegment(e1p1, e1p2)
      if dist < minDist then minDist = dist end
    end
  end

  return minDist
end

local function getCouplerPoints(veh, vehId)
  if not couplerCache[vehId] then
    local res = {}
    local vData = extensions.core_vehicle_manager.getVehicleData(vehId)
    if vData and vData.vdata and vData.vdata.nodes then
      for _, node in pairs(vData.vdata.nodes) do
        if (node.couplerTag and node.couplerTag:find('fifthwheel')) or (node.tag and node.tag:find('fifthwheel')) then
          res[#res + 1] = {cid = node.cid, livePos = {x = 0, y = 0, z = 0}}
        end
      end
      couplerCache[vehId] = res
    end
  end
  local cached = couplerCache[vehId]
  if not cached or cached[1] == nil then return cached end
  local vpx, vpy, vpz = veh:getPositionXYZ()
  for j = 1, #cached do
    local node = cached[j]
    local npx, npy, npz = veh:getNodePositionXYZ(node.cid)
    local lp = node.livePos
    lp.x, lp.y, lp.z = npx + vpx, npy + vpy, npz + vpz
  end
  return cached
end

local function gammaCorrect(v)
  if v < 0 then v = 0 elseif v > 1 then v = 1 end
  return floor(v ^ gamma * 255 + 0.5)
end

local function onGuiUpdate(dtReal, dtSim, dtRaw)
  local data = {objects = {}}
  local playerId = be:getPlayerVehicleID(0)
  data.playerVehicleId = playerId

  local playerVehicle = be:getObjectByID(playerId)
  local playerSpeed = 0
  if playerVehicle then
    local vx, vy, vz = playerVehicle:getVelocityXYZ()
    playerSpeed = (vx * vx + vy * vy + vz * vz) ^ 0.5
  end
  data.playerVehicleSpeed = playerSpeed

  -- Effective range mirrors Vue effectiveRangeMeters; cullBase covers fore/aft offset (up to 80%)
  local effectiveRange
  if settings.rangeType == 'time' then
    effectiveRange = max(5, min(30, playerSpeed * (settings.rangeSeconds or 0.5)))
  else
    effectiveRange = settings.rangeMeters or 13
  end
  local cullBase = effectiveRange * 2.5

  local ppx, ppy, playerExtent, playerBB
  if playerVehicle then
    ppx, ppy = playerVehicle:getSpawnWorldOOBBCenterXYZ()
    local phx, phy, phz = be:getObjectOOBBHalfExtentsXYZ(playerId)
    playerExtent = max(phx, max(phy, phz))
    playerBB = playerVehicle:getSpawnWorldOOBB()
  end

  local roughCullRange = cullBase + (playerExtent or 0) + maxPossibleVehExtent
  local roughCullRangeSq = roughCullRange * roughCullRange
  local coloredCars = settings.coloredCars

  for i = 0, be:getObjectCount() - 1 do
    local veh = be:getObject(i)
    if not veh then goto continue end
    if veh:isHidden() then goto continue end

    local vehId = veh:getId()
    local isPlayer = vehId == playerId

    -- Stage 1: rough cull with getPositionXYZ (zero alloc)
    if ppx and not isPlayer then
      local px, py = veh:getPositionXYZ()
      local dx = px - ppx
      local dy = py - ppy
      if dx * dx + dy * dy > roughCullRangeSq then goto continue end
    end

    -- Stage 2: precise cull with OOBB center + extent (zero alloc)
    local cx, cy, cz = veh:getSpawnWorldOOBBCenterXYZ()
    local hx, hy, hz = be:getObjectOOBBHalfExtentsXYZ(vehId)
    local vehExtent = max(hx, max(hy, hz))

    local dx, dy
    if ppx and not isPlayer then
      dx = cx - ppx
      dy = cy - ppy
      local cullRange = cullBase + playerExtent + vehExtent
      if dx * dx + dy * dy > cullRange * cullRange then goto continue end
    end

    -- BB needed for axis and oobbToOobbDistance (getAxis has no XYZ variant)
    local bb = isPlayer and playerBB or veh:getSpawnWorldOOBB()
    local dir = bb:getAxis(0)

    local vehType = 'vehicle'
    if veh.isTraffic == 'true' then
      vehType = 'traffic'
    end
    if veh.isParked == 'true' then
      vehType = 'parked'
    end
    local jbeamLower = jbeamLowerCache[vehId]
    if not jbeamLower then
      jbeamLower = veh.jbeam:lower()
      jbeamLowerCache[vehId] = jbeamLower
    end
    if jbeamLower:find('trailer') then
      vehType = 'trailer'
    end

    -- Proximity: skip expensive OOBB distance when centers are clearly too far apart
    local proximityDistance = nil
    if dx then
      local centerDist = (dx * dx + dy * dy) ^ 0.5
      if centerDist - playerExtent - vehExtent <= proximityThreshold then
        proximityDistance = oobbToOobbDistance(playerBB, bb)
      end
    end

    local paintColor = nil
    if coloredCars then
      local paint = getVehiclePaint(vehId)
      if paint and paint.baseColor then
        local bc = paint.baseColor
        local pc = paintColorCache[vehId]
        if not pc then
          pc = {r = 0, g = 0, b = 0}
          paintColorCache[vehId] = pc
        end
        pc.r = gammaCorrect(bc[1])
        pc.g = gammaCorrect(bc[2])
        pc.b = gammaCorrect(bc[3])
        paintColor = pc
      end
    end

    local obj = objectCache[vehId]
    if not obj then
      obj = {}
      objectCache[vehId] = obj
    end
    obj.centerX = cx
    obj.centerY = cy
    obj.centerZ = cz
    obj.sizeX = hx * 2
    obj.sizeY = hy * 2
    obj.sizeZ = hz * 2
    obj.rotX = atan2(dir.y, dir.x)
    obj.type = vehType
    obj.couplers = getCouplerPoints(veh, vehId)
    obj.proximityDistance = proximityDistance
    obj.paintColor = paintColor
    data.objects[vehId] = obj

    ::continue::
  end
  guihooks.queueStream('vehicleRadar', data)
end

local function clearCaches()
  couplerCache = {}
  objectCache = {}
  paintColorCache = {}
  jbeamLowerCache = {}
end

local function onVehicleSwitched()
  clearCaches()
end

local function onVehicleSpawned()
  clearCaches()
end

M.onVehicleSpawned = onVehicleSpawned
M.onVehicleSwitched = onVehicleSwitched
M.onGuiUpdate = onGuiUpdate
M.onExtensionLoaded = onExtensionLoaded
M.updateSetting = updateSetting
return M
