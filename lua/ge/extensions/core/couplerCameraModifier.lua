-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"core_trailerRespawn"}

local objId1
local objId2

local detached = true

local function getConfiguredOrbitDistance(vehId)
  local camData = vehId and core_camera and core_camera.getCameraDataById(vehId)
  return camData and camData.orbit and camData.orbit.distance or 5
end

local function checkForTrailer(objId1_, objId2_)
  if objId1_ == objId2_ then return false end
  if core_trailerRespawn.getConfigType(objId1_) ~= "Trailer" and core_trailerRespawn.getConfigType(objId2_) ~= "Trailer" then return false end

  local obj1 = scenetree.findObjectById(objId1_)
  local obj2 = scenetree.findObjectById(objId2_)

  local pos1 = obj1:getPosition()
  local pos2 = obj2:getPosition()

  if obj1 ~= nil and obj2 ~= nil then
    local dist = (pos1 - pos2):len()
    if dist < 1 or dist > 15 then return false end
  end
  return true
end

local function initCameraModifier()
  local dist1 = getConfiguredOrbitDistance(objId1)
  local dist2 = getConfiguredOrbitDistance(objId2)

  if core_camera ~= nil then
    core_camera.getCameraDataById(objId1).orbit.lockCamera = true
    core_camera.setDefaultDistance({vehId = objId1, camName = "orbit"}, (dist1+dist2)/1.5+1)
    core_camera.setDistance({vehId = objId1, camName = "orbit"}, (dist1+dist2)/1.5+1)
    core_camera.getCameraDataById(objId2).orbit.lockCamera = true
    core_camera.setDefaultDistance({vehId = objId2, camName = "orbit"}, (dist1+dist2)/1.5+1)
    core_camera.setDistance({vehId = objId2, camName = "orbit"}, (dist1+dist2)/1.5+1)
  end

  detached = false
end

local function restoreOriginalCamera()
  if core_camera then
    local obj1, obj2
    if objId1 then obj1 = scenetree.findObjectById(objId1) end
    if objId2 then obj2 = scenetree.findObjectById(objId2) end

    if obj1 then
      local dist1 = getConfiguredOrbitDistance(objId1)
      core_camera.setTargetMode({vehId = objId1, camName = "orbit"}, 'ref', nil)
      core_camera.setRef({vehId = objId1, camName = "orbit"}, nil, nil, nil)
      core_camera.setDefaultDistance({vehId = objId1, camName = "orbit"}, dist1)
      core_camera.setDistance({vehId = objId1, camName = "orbit"}, dist1)
    end

    if obj2 then
      local dist2 = getConfiguredOrbitDistance(objId2)
      core_camera.setTargetMode({vehId = objId2, camName = "orbit"}, 'ref', nil)
      core_camera.setRef({vehId = objId2, camName = "orbit"}, nil, nil, nil)
      core_camera.setDefaultDistance({vehId = objId2, camName = "orbit"}, dist2)
      core_camera.setDistance({vehId = objId2, camName = "orbit"}, dist2)
    end
  end
  detached = true
end

local function stopTracking()
  restoreOriginalCamera()
  objId1 = nil
  objId2 = nil
end

-- picks up a coupling the player vehicle is already part of
local function trackVehicleIfCoupled(vehId)
  if vehId == nil or vehId == -1 then return end
  if vehId == objId1 or vehId == objId2 then return end -- already tracking this pair

  local couplings = core_vehicles and core_vehicles.vehsCouplings[vehId]
  if not couplings then return end

  for otherId in pairs(couplings) do
    if checkForTrailer(vehId, otherId) then
      restoreOriginalCamera()
      objId1 = vehId
      objId2 = otherId
      initCameraModifier()
      return
    end
  end
end

local function onExtensionLoaded()
  if not settings.getValue("couplerCameraModifier", false) then return false end
  trackVehicleIfCoupled(be:getPlayerVehicleID(0))
end

local function onCouplerAttached(objId1_, objId2_)
  local playerVehId = be:getPlayerVehicleID(0)
  if playerVehId ~= objId1_ and playerVehId ~= objId2_ then return end
  if checkForTrailer(objId1_, objId2_) then
    restoreOriginalCamera()
    objId1 = objId1_
    objId2 = objId2_
    initCameraModifier()
  end
end

local function onCouplerDetached(objId1_, objId2_)
  if objId1 == nil then return end
  -- fires for every coupling in the world, so only react to the pair we are tracking
  if objId1_ ~= objId1 and objId1_ ~= objId2 and objId2_ ~= objId1 and objId2_ ~= objId2 then return end
  stopTracking()
end

local function onUpdate()
  if objId1 == nil or objId2 == nil then return end
  local vehicleId = be:getPlayerVehicleID(0)
  if vehicleId ~= objId1 and vehicleId ~= objId2 then return end

  local obj1 = scenetree.findObjectById(objId1)
  local obj2 = scenetree.findObjectById(objId2)

  if obj2 == nil or obj1 == nil then stopTracking() return end

  local vehicle = getPlayerVehicle(0)
  local playerVehiclePos = vehicle:getPosition()

  local obj1refNodePos = obj1:getNodePosition(core_camera.getCameraDataById(objId1).orbit.refNodes.ref)
  local obj2refNodePos = obj2:getNodePosition(core_camera.getCameraDataById(objId2).orbit.refNodes.ref)

  local obj1leftNodePos = obj1:getNodePosition(core_camera.getCameraDataById(objId1).orbit.refNodes.left)
  local obj2leftNodePos = obj2:getNodePosition(core_camera.getCameraDataById(objId2).orbit.refNodes.left)

  local obj1backNodePos = obj1:getNodePosition(core_camera.getCameraDataById(objId1).orbit.refNodes.back)
  local obj2backNodePos = obj2:getNodePosition(core_camera.getCameraDataById(objId2).orbit.refNodes.back)

  local ref = vec3(obj1refNodePos)
  local left = vec3(obj1leftNodePos)
  local back = vec3(obj1backNodePos)

  local nx = left - ref
  local ny = back - ref
  local nz = nx:cross(ny):normalized()
  ny = nx:cross(-nz):normalized() * ny:length()

  local offset = core_camera.getCameraDataById(objId1).orbit.offset
  local camBase = vec3(offset.x / nx:length(), offset.y / ny:length(), offset.z / nz:length())
  local camOffset2 = nx * camBase.x + ny * camBase.y + nz * camBase.z

  local obj1Pos = ref + obj1:getPosition() + camOffset2

  ref =   vec3(obj2refNodePos)
  left =  vec3(obj2leftNodePos)
  back =  vec3(obj2backNodePos)

  nx = left - ref
  ny = back - ref
  nz = nx:cross(ny):normalized()
  ny = nx:cross(-nz):normalized() * ny:length()

  offset = core_camera.getCameraDataById(objId2).orbit.offset
  camBase = vec3(offset.x / nx:length(), offset.y / ny:length(), offset.z / nz:length())
  camOffset2 = nx * camBase.x + ny * camBase.y + nz * camBase.z

  local obj2Pos = ref + obj2:getPosition() + camOffset2

  if (obj1Pos - obj2Pos):length() > (getConfiguredOrbitDistance(objId1) + getConfiguredOrbitDistance(objId2)) then
    restoreOriginalCamera()
  elseif detached then
    detached = false
    initCameraModifier()
  end

  if detached then return end

  local meanLocation = (obj1Pos + obj2Pos)/2 - playerVehiclePos
  local meanLeft = (obj1leftNodePos + obj1Pos + obj2leftNodePos + obj2Pos) / 2 - playerVehiclePos
  local meanBack = (obj1backNodePos + obj1Pos + obj2backNodePos + obj2Pos) / 2 - playerVehiclePos

  if core_camera then
    local vid = be:getPlayerVehicleID(0)
    core_camera.setTargetMode(vid, 'notCenter', nil)
    core_camera.setRef(vid, meanLocation, meanLeft, meanBack)
  end
end

local function onVehicleSwitched(oldId, newId, player)
  trackVehicleIfCoupled(newId)
end

local function onVehicleSpawned(vehId)
  if vehId == objId1 or vehId == objId2 then -- This means that one of the coupled vehicles got replaced
    stopTracking()
  end
end

local function onSerialize()
  return {
    objId1 = objId1,
    objId2 = objId2,
    detached = detached
  }
end

local function onDeserialized(data)
  if data then
    objId1 = data.objId1
    objId2 = data.objId2
    detached = data.detached
  end
end

M.checkForTrailer = checkForTrailer
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = restoreOriginalCamera
M.onCouplerAttached = onCouplerAttached
M.onCouplerDetached = onCouplerDetached
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleSpawned = onVehicleSpawned
M.onUpdate = onUpdate
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M