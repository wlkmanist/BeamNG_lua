-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"util_screenshotCreator_thumbnailConfig"}

local defaultSettleDelay = 2
local groundProbeAbove = 0.5
local groundProbeBelow = 2
local groundHeightAboveTolerance = 0.1
local groundClearance = 0.01
local appliedThumbnailRotations = {}
-- props too big for rear-right alignment, their box is centred on the spawn instead
local centeredModels = {inflated_mat = true, large_bridge = true}

local function yieldSeconds(seconds)
  local start = os.clock()
  while os.clock() - start < seconds do
    coroutine.yield()
  end
end

local function safeTeleportToExactRotation(vehicle, position, rotation)
  spawn.safeTeleport(vehicle, position, quat(0, 0, 1, 0) * rotation)
end

local function getGroundHeight(position)
  local rayStart = vec3(position.x, position.y, position.z + groundProbeAbove)
  local rayLength = groundProbeAbove + groundProbeBelow
  local distance = tonumber(castRayStatic(rayStart, vec3(0, 0, -1), rayLength)) or rayLength
  if distance >= 0 and distance < rayLength then
    local groundHeight = rayStart.z - distance
    if groundHeight <= position.z + groundHeightAboveTolerance
      and groundHeight >= position.z - groundProbeBelow
    then
      return groundHeight
    end
  end
  return position.z
end

-- probed from above the box: props with buried nodes (bollards, posts) put the box bottom under the floor,
-- where the short probe of getGroundHeight misses the floor and reports the buried bottom instead
local function getFloorHeight(bb)
  local bottom, top = math.huge, -math.huge
  for index = 0, 7 do
    local z = bb:getPoint(index).z
    bottom, top = math.min(bottom, z), math.max(top, z)
  end
  local center = bb:getCenter()
  local rayStart = vec3(center.x, center.y, top + groundProbeAbove)
  local rayLength = top - bottom + groundProbeAbove + groundProbeBelow
  local distance = tonumber(castRayStatic(rayStart, vec3(0, 0, -1), rayLength))
  if distance and distance >= 0 and distance < rayLength then
    return rayStart.z - distance
  end
  return bottom
end

-- local spawn box + the pose just set: the world OOBB only follows a teleport after physics steps,
-- and a stale box shifts the vehicle by the previous vehicle's offset
local function alignBottomToSpawn(vehicle, spawnPosition, rotation, centered)
  local box = vehicle.initialNodePosBB
  local refNode = vehicle:getInitialNodePosition(vehicle:getRefNodeId())
  local position, worldRotation = vehicle:getPosition(), quat(vehicle:getRotation())
  local function toWorld(point) return position + worldRotation * (point - refNode) end
  local anchor = toWorld(centered and vec3((box.minExtents.x + box.maxExtents.x) * 0.5, (box.minExtents.y + box.maxExtents.y) * 0.5, 0)
    or vec3(box.minExtents.x, box.maxExtents.y, 0))
  local minWorldZ = math.huge
  for index = 0, 7 do
    minWorldZ = math.min(minWorldZ, toWorld(vec3(
      index % 2 == 0 and box.minExtents.x or box.maxExtents.x,
      index % 4 < 2 and box.minExtents.y or box.maxExtents.y,
      index < 4 and box.minExtents.z or box.maxExtents.z
    )).z)
  end

  local groundHeight = getGroundHeight(spawnPosition)
  local offset = vec3(
    spawnPosition.x - anchor.x,
    spawnPosition.y - anchor.y,
    groundHeight + groundClearance - minWorldZ
  )
  safeTeleportToExactRotation(vehicle, vehicle:getPosition() + offset, rotation)
end

function M.getThumbnailSpawnTransform()
  local spawnSpheres = scenetree.findClassObjects("SpawnSphere")
  local spawnSphere = spawnSpheres and spawnSpheres[1] and scenetree.findObject(spawnSpheres[1])
  if not spawnSphere then return nil, nil end
  return vec3(spawnSphere:getPosition()), quat(spawnSphere:getRotation())
end

function M.getResetTransform(vehicle)
  local appliedRotation = appliedThumbnailRotations[vehicle:getId()]
  return appliedRotation and vec3(appliedRotation.originalPosition) or vec3(vehicle:getPosition()),
    appliedRotation and quat(appliedRotation.originalRotation) or quat(vehicle:getRotation())
end

function M.placeVehicleForThumbnail(vehicle, configName, fallbackPosition, fallbackRotation)
  local vehicleId = vehicle:getId()
  local appliedRotation = appliedThumbnailRotations[vehicleId]
  local position, rotation = M.getThumbnailSpawnTransform()
  position = position or fallbackPosition or (appliedRotation and appliedRotation.originalPosition)
    or vec3(vehicle:getPosition())
  rotation = rotation or fallbackRotation or (appliedRotation and appliedRotation.originalRotation)
    or quat(vehicle:getRotation())

  local modelName = vehicle.jbeam or vehicle.JBeam
  local thumbnailRotation = util_screenshotCreator_thumbnailConfig.getRotation(modelName, configName)

  vehicle:reset()
  appliedThumbnailRotations[vehicleId] = nil

  local finalRotation = quat(rotation)
  if thumbnailRotation ~= 0 then
    finalRotation = quatFromEuler(0, 0, math.rad(thumbnailRotation)) * finalRotation
  end
  safeTeleportToExactRotation(vehicle, position, finalRotation)
  coroutine.yield()
  alignBottomToSpawn(vehicle, position, finalRotation, centeredModels[modelName])
  coroutine.yield()

  if thumbnailRotation ~= 0 then
    appliedThumbnailRotations[vehicleId] = {
      key = modelName .. "/" .. tostring(configName) .. "/" .. tostring(thumbnailRotation),
      originalPosition = vec3(position),
      originalRotation = quat(rotation)
    }
  end
end

function M.waitForVehicleToSettle(modelName, configName, options)
  options = options or {}
  local pauseDelay = util_screenshotCreator_thumbnailConfig.getPauseDelay(modelName, configName)
  local settleDelay = pauseDelay > 0 and pauseDelay
    or math.max(tonumber(options.settleDelay) or defaultSettleDelay, 0)
  yieldSeconds(settleDelay)
end

function M.setLowBeams(vehicle, enabled)
  if vehicle and enabled then
    vehicle:queueLuaCommand("electrics.setLightsState(1)")
  end
end

function M.onVehicleSpawned(vehicleId)
  appliedThumbnailRotations[vehicleId] = nil
end

M.getGroundHeight = getGroundHeight
M.getFloorHeight = getFloorHeight

return M
