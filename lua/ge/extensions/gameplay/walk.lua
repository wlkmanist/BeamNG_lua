-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local occupantFaces = require("jbeam/sections/occupantFaces")

local logTag = "walk"

-- per-player state, keyed by the 0-based player index
local active = {}
local vehicleInFront = {}
local atParkingSpeed = {}
local showMessageLastFrame = {}
local unicycleIds = {}
local hiddenUnicycleIds = {}
local faceParts = {}
local paints = {}
local personaIds = {}
local personaPaints = {}

-- global state, shared by all players
local togglingEnabled = true
local vehicleBlacklist = {}

local lowerStoppingSpeed = 5.0/3.6
local higherStoppingSpeed = 6.0/3.6
local up = vec3(0,0,1)
local forward = vec3(0,1,0)
local placePlayerOffsetFromBody = 0.7
local defaultCharacterColor = {0.37, 0.37, 0.39, 1}

local players = {0}
local playersRevision = nil

-- in splitscreen, colors come from the persona; outside of it, the unicycle keeps its own paint
local function getPersonaPaint(player)
  return core_multiseat and core_multiseat.isMultiseatActive() and personaPaints[player]
end

local function configureUnicycle(player, unicycle)
  local paint = getPersonaPaint(player)
  if not unicycle or not paint then return end

  local color = paint.baseColor
  local linearColor = ColorF(color[1], color[2], color[3], 1):asLinear4F()
  unicycle.color = linearColor
  unicycle.colorPalette0 = linearColor
  unicycle.colorPalette1 = linearColor
  unicycle:setMetallicPaintData({paint, paint, paint})
end

local function configureUnicycles()
  for player, unicycleId in pairs(unicycleIds) do
    configureUnicycle(player, getObjectByID(unicycleId))
  end
end

local function removeUnicycle(player)
  local unicycleId = unicycleIds[player]
  if not unicycleId then return end
  local unicycle = getObjectByID(unicycleId)
  if not unicycle then return end
  -- leave the seat first, otherwise the deletion moves the player into somebody else's vehicle
  if be:getPlayerVehicleID(player) == unicycleId then be:exitVehicle(player) end
  unicycle:delete()
end

-- the local player roster, refreshed only when multiseat reports a change so onUpdate stays allocation free
local function getPlayers()
  local revision = core_multiseat and core_multiseat.getParticipantRevision()
  if revision == playersRevision then return players end
  playersRevision = revision

  players = (core_multiseat and core_multiseat.getPlayers()) or {0}
  if #players == 0 then players = {0} end

  local stillHere = {}
  table.clear(personaIds)
  table.clear(personaPaints)
  for _, player in ipairs(players) do
    stillHere[player] = true
    local participant = core_multiseat and core_multiseat.getParticipant(player)
    if participant then
      local persona = participant.persona
      personaIds[player] = persona.id
      personaPaints[player] = createVehiclePaint({x = persona.color[1], y = persona.color[2], z = persona.color[3], w = 1})
    end
  end
  configureUnicycles()
  for player in pairs(unicycleIds) do
    if not stillHere[player] then removeUnicycle(player) end
  end
  -- drop the state of players that left, so stale data can't leak into the getters
  for player in pairs(atParkingSpeed) do
    if not stillHere[player] then
      active[player] = nil
      vehicleInFront[player] = nil
      atParkingSpeed[player] = nil
      showMessageLastFrame[player] = nil
    end
  end
  for player in pairs(faceParts) do
    if not stillHere[player] then faceParts[player] = nil end
  end
  for player in pairs(paints) do
    if not stillHere[player] then paints[player] = nil end
  end
  return players
end

-- returns the unicycle a player is currently in, no matter if it's the one saved under unicycleIds or not
local function getCurrentUnicycle(player)
  local veh = getPlayerVehicle(player or 0)
  if veh and veh:getJBeamFilename() == "unicycle" then
    return veh
  end
end

local function getUnicycleData(player)
  local unicycle = getCurrentUnicycle(player) or (unicycleIds[player] and getObjectByID(unicycleIds[player]))
  return unicycle and core_vehicle_manager.getVehicleData(unicycle:getId())
end

local function getUnicycleFacePart(player)
  local vehicleData = getUnicycleData(player)
  if not vehicleData then return end
  for partName, part in pairs(vehicleData.vdata.activePartsData) do
    if part.slotType == "skin_character_face" then return partName end
  end
end

-- priority: the unicycle part (part selector), the splitscreen setting, the last known face, a random face
local function getFacePart(player)
  player = player or 0
  getPlayers()
  faceParts[player] = getUnicycleFacePart(player)
    or settings.getValue("playerCharacterFace", nil, personaIds[player])
    or faceParts[player]
    or occupantFaces.getRandomFacePart()
  return faceParts[player]
end

local function createPaintFromColor(color)
  return createVehiclePaint({x = color[1], y = color[2], z = color[3], w = color[4] or 1})
end

-- priority: the splitscreen persona paint, the unicycle paint (vehicle config menu), the last known paint, the saved color
local function getPaint(player)
  player = player or 0
  getPlayers()
  local personaPaint = getPersonaPaint(player)
  if personaPaint then return personaPaint end
  local vehicleData = getUnicycleData(player)
  paints[player] = vehicleData and vehicleData.config.paints[1]
    or paints[player]
    or createPaintFromColor(settings.getValue("playerCharacterColor", defaultCharacterColor))
  return paints[player]
end

-- a walking player gets their unicycle respawned with the new face, otherwise the stored unicycle is dropped and respawned later
local function setFacePart(player, facePart)
  player = player or 0
  if faceParts[player] == facePart then return end
  faceParts[player] = facePart
  local unicycle = getCurrentUnicycle(player)
  if unicycle then
    unicycle.autoEnterVehiclePlayer = tostring(player)
    core_vehicle_partmgmt.setConfigOfVehicle(unicycle, {parts = {skin_character_face = facePart}})
  else
    removeUnicycle(player)
    if gameplay_seatOccupants then gameplay_seatOccupants.onSettingsChanged() end
  end
end

local function isWalking(player)
  return getCurrentUnicycle(player) ~= nil
end

local function isAtParkingSpeed(player)
  return atParkingSpeed[player or 0] ~= false
end

local function getUnicyleAtPosition(player, pos, visibilityPoint)
  local unicycle = getCurrentUnicycle(player)

  if unicycleIds[player] and not unicycle then
    unicycle = getObjectByID(unicycleIds[player])
  end
  if unicycle then
    unicycle:setActive(1)
  else
    local config = {
      model = "unicycle",
      format = 2,
      parts = {
        unicycle_meshes = "unicycle_character",
        skin_character_face = getFacePart(player),
      },
    }
    dump(config)
    unicycle = extensions.core_vehicles.spawnNewVehicle("unicycle", {config = config, paint = getPaint(player), pos = pos, visibilityPoint = visibilityPoint, removeTraffic = false, canSpawnAnotherVehicleCheck = false, autoEnterVehiclePlayer = player})
  end
  if unicycle then
    if pos then spawn.safeTeleport(unicycle, pos, nil, nil, visibilityPoint, false) end
    unicycle.playerUsable = false
    configureUnicycle(player, unicycle)
  end
  unicycleIds[player] = unicycle and unicycle:getId() or nil
  return unicycle
end

-- returns a position near the driver's door
local function getDoorsidePosRot(veh)
  local refNodes = extensions.core_vehicle_manager.getVehicleData(veh:getId()).vdata.refNodes[0]
  local ref  = veh:getNodePosition(refNodes.ref)
  local left = veh:getNodePosition(refNodes.left)
  local carLeft = (left-ref):normalized()
  local driverNode, rightHandDrive, rightHandDoor = core_camera.getDriverData(veh)
  driverNode = driverNode or refNodes.ref
  local driverPos = veh:getPosition() + veh:getNodePosition(driverNode)

  local initCorner = rightHandDoor and veh.initialNodePosBB.minExtents or veh.initialNodePosBB.maxExtents
  local initDriverPos = veh:getInitialNodePosition(driverNode)

  local driverPosOffset = initCorner.x - initDriverPos.x
  driverPosOffset = driverPosOffset + (sign(driverPosOffset) * placePlayerOffsetFromBody)

  local pos = driverPos + driverPosOffset * carLeft
  local target = veh:getPosition() + ref
  local front = (target-pos):normalized() -- look from pos towards the center
  front.z = 0

  return pos, front, up
end

local function getDriverPos(veh)
  local driverNode = core_camera.getDriverData(veh)
  if not driverNode then
    local refNodes = extensions.core_vehicle_manager.getVehicleData(veh:getId()).vdata.refNodes[0]
    driverNode = refNodes.ref
  end
  return veh:getPosition() + veh:getNodePosition(driverNode)
end

local function setUnicycleInactive(unicycle)
  be.nodeGrabber:clearVehicleFixedNodes(unicycle:getId())
  unicycle:setActive(0)
end

local function getInVehicle(vehicle, player)
  player = player or 0
  local unicycle = getCurrentUnicycle(player)
  if unicycle then
    unicycleIds[player] = unicycle:getId()
  end
  be:enterVehicle(player, vehicle)
end

local function getOutOfVehicle(vehicle, pos, rot, player, visibilityPoint)
  if vehicle and not pos then
    local doorsidePos, front, up = getDoorsidePosRot(vehicle)
    pos = doorsidePos
    visibilityPoint = getDriverPos(vehicle)
  end
  local unicycle = getUnicyleAtPosition(player, pos, visibilityPoint)

  if unicycle then
    local camData = core_camera.getCameraDataById(unicycle:getId(), core_camera.getContextIdForPlayer(player))
    if camData and camData.unicycle then
      local unicyclePos = unicycle:getPosition()
      local finalDir
      if rot then
        finalDir = rot * forward
      elseif visibilityPoint then
        finalDir = (visibilityPoint - unicyclePos)
      else
        finalDir = forward
      end
      camData.unicycle:setCustomData({pos = unicyclePos, front = finalDir, up = up})
    end
    be:enterVehicle(player, unicycle)
  end
end

local function setRot(front, up, player)
  player = player or 0
  if not active[player] then return end
  local unicycle = getCurrentUnicycle(player)
  local camData = unicycle and core_camera.getCameraDataById(unicycle:getId(), core_camera.getContextIdForPlayer(player))
  if camData and camData.unicycle then
    camData.unicycle:setCustomData({front = front, up = up})
  end
end

-- pos and rot are optional
local function canToggleWalkingMode(force, player)
  player = player or 0
  local actionBlocked = core_input_actionFilter
    and core_input_actionFilter.isActionBlocked
    and core_input_actionFilter.isActionBlocked("toggleWalkingMode")
  return force or (isAtParkingSpeed(player) and togglingEnabled and not actionBlocked and core_replay.getState() ~= "playback")
end

local function canSetWalkingMode(enabled, force, player)
  player = player or 0
  return enabled ~= (active[player] == true) and canToggleWalkingMode(force, player)
end

local function setWalkingMode(enabled, pos, rot, force, player)
  player = player or 0
  local unicycle = getCurrentUnicycle(player)
  if not canSetWalkingMode(enabled, force, player) then
    return false, unicycle and unicycle:getId()
  end
  if enabled then
    -- clear camera message when entering walking mode
    guihooks.trigger('Message', {
      category = 'cameramode',
      clear = true
    })
    if not unicycle then
      extensions.hook("onBeforeWalkingModeToggled", enabled, nil, player)
      local vehicle = getPlayerVehicle(player)
      local visibilityPoint
      if vehicle and not pos and gameplay_seatOccupants and gameplay_seatOccupants.getSeatExitData then
        pos, visibilityPoint = gameplay_seatOccupants.getSeatExitData(player, vehicle:getId())
      end
      getOutOfVehicle(vehicle, pos, rot, player, visibilityPoint)
    end
  else
    local target = vehicleInFront[player]
    if target then
      extensions.hook("onBeforeWalkingModeToggled", enabled, target:getId(), player)
      local handled
      if gameplay_seatOccupants and gameplay_seatOccupants.requestEnterBestSeat then
        local walkingPos = unicycle and vec3(unicycle:getPosition()) or nil
        handled = gameplay_seatOccupants.requestEnterBestSeat(target:getId(), player, walkingPos)
      end
      if handled == nil then
        getInVehicle(target, player)
      end
    else
      extensions.hook("onBeforeWalkingModeToggled", enabled, nil, player)
      setUnicycleInactive(unicycle)
    end
  end
  local playerUnicycle = getCurrentUnicycle(player)
  if enabled then
    return playerUnicycle ~= nil, playerUnicycle and playerUnicycle:getId()
  else
    return not playerUnicycle, playerUnicycle and playerUnicycle:getId()
  end
end

local function getStoredUnicycleId(player)
  return unicycleIds[player or 0]
end

local function toggleWalkingMode(player)
  player = player or 0
  if player < 0 then return end
  local enabled
  if active[player] then
    if not vehicleInFront[player] then return end
    enabled = false
  else
    enabled = true
  end

  if multiplayer_vehicleSync then
    multiplayer_vehicleSync.requestWalkingMode(enabled, nil, nil, nil, player)
    return
  end

  setWalkingMode(enabled, nil, nil, nil, player)
end

-- TODO if we got rid of the moving threshold, we could get rid of the update function when walking mode is not active
local vehVelocity = vec3()
local function setAtParkingSpeed(player, veh)
  -- prevent flicker while hovering over threshold speed by using a different limit on each direction
  if veh then
    vehVelocity:set(veh:getVelocityXYZ())
    local vehicleSpeed = vehVelocity:len()
    if vehicleSpeed < lowerStoppingSpeed then atParkingSpeed[player] = true end
    if vehicleSpeed > higherStoppingSpeed then atParkingSpeed[player] = false end
  else
    atParkingSpeed[player] = true
  end
end

local p1, p2, p3, p4, p5, p6, p7, p8 = vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
local bbPoints = {}
local function getBBPoints(bbCenter, bbAxis0, bbAxis1, bbAxis2)
  p1:set(bbCenter) p1:setAdd(bbAxis0) p1:setAdd(bbAxis1) p1:setSub(bbAxis2)
  p2:set(bbCenter) p2:setAdd(bbAxis0) p2:setAdd(bbAxis1) p2:setAdd(bbAxis2)
  p3:set(bbCenter) p3:setSub(bbAxis0) p3:setAdd(bbAxis1) p3:setAdd(bbAxis2)
  p4:set(bbCenter) p4:setSub(bbAxis0) p4:setAdd(bbAxis1) p4:setSub(bbAxis2)
  p5:set(bbCenter) p5:setAdd(bbAxis0) p5:setSub(bbAxis1) p5:setSub(bbAxis2)
  p6:set(bbCenter) p6:setAdd(bbAxis0) p6:setSub(bbAxis1) p6:setAdd(bbAxis2)
  p7:set(bbCenter) p7:setSub(bbAxis0) p7:setSub(bbAxis1) p7:setAdd(bbAxis2)
  p8:set(bbCenter) p8:setSub(bbAxis0) p8:setSub(bbAxis1) p8:setSub(bbAxis2)
  bbPoints[1] = p1; bbPoints[2] = p2; bbPoints[3] = p3; bbPoints[4] = p4;
  bbPoints[5] = p5; bbPoints[6] = p6; bbPoints[7] = p7; bbPoints[8] = p8;
  return bbPoints
end


local function boundingBoxDistance(pos, otherBBCenter, otherBBAxis0, otherBBAxis1, otherBBAxis2)
  local bbPoints = getBBPoints(otherBBCenter, otherBBAxis0, otherBBAxis1, otherBBAxis2)

  -- 1,2,3,4 front
  -- 5,6,7,8 back
  local minDist = math.huge
  -- lower bbPoints
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[1], bbPoints[4]))
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[4], bbPoints[8]))
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[8], bbPoints[5]))
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[5], bbPoints[1]))

  -- upper bbPoints
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[2], bbPoints[3]))
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[3], bbPoints[7]))
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[7], bbPoints[6]))
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[6], bbPoints[2]))

  -- left
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[1], bbPoints[6]))
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[2], bbPoints[5]))
  -- front
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[1], bbPoints[3]))
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[2], bbPoints[4]))
  -- right
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[3], bbPoints[8]))
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[4], bbPoints[7]))
  -- back
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[5], bbPoints[7]))
  minDist = math.min(minDist, pos:distanceToLineSegment(bbPoints[6], bbPoints[8]))
  return minDist
end

local otherBBCenter, otherBBAxis0, otherBBAxis1, otherBBAxis2 = vec3(), vec3(), vec3(), vec3()
local vehPos = vec3()
local function updatePlayer(player, allVehicles)
  local showMessage = false

  vehicleInFront[player] = nil
  local unicycle = active[player] and getCurrentUnicycle(player)
  if unicycle then
    vehPos:set(unicycle:getPositionXYZ())
    local closestHit = 2
    for _, veh in ipairs(allVehicles) do
      local vehId = veh:getID()
      if not vehicleBlacklist[vehId] and veh.playerUsable ~= false and veh:getActive() and veh:getJBeamFilename() ~= "unicycle" then
        otherBBCenter:set(be:getObjectOOBBCenterXYZ(vehId))
        otherBBAxis0:set(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
        otherBBAxis1:set(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
        otherBBAxis2:set(be:getObjectOOBBHalfAxisXYZ(vehId, 2))

        if be:getObjectOOBBIsInitialized(vehId) then
          local dist = boundingBoxDistance(vehPos, otherBBCenter, otherBBAxis0, otherBBAxis1, otherBBAxis2)
          if dist < closestHit then
            vehicleInFront[player] = veh
            closestHit = dist
          end
        end
      end
    end

    if vehicleInFront[player] then
      setAtParkingSpeed(player, vehicleInFront[player])
      if isAtParkingSpeed(player) and togglingEnabled then
        showMessage = true
      end
    end
  else
    setAtParkingSpeed(player, getPlayerVehicle(player))
  end

  if showMessage ~= showMessageLastFrame[player] then
    if showMessage then
      guihooks.trigger("Message", {
        ttl = 60,
        category = "walkingmode",
        icon = "seatArrowInLeft",
        player = player,
        actionItems = fillActionLabelSimple{"toggleWalkingMode"}
      })
    else
      guihooks.trigger("Message", {
        category = "walkingmode",
        player = player,
        clear = true
      })
    end
  end
  showMessageLastFrame[player] = showMessage
end

local function onUpdate(dtReal, dtSim)
  local allVehicles
  for _, player in ipairs(getPlayers()) do
    if active[player] and not allVehicles then allVehicles = getAllVehicles() end
    updatePlayer(player, allVehicles)
  end
end

local function getVehicleInFront(player)
  return vehicleInFront[player or 0]
end

local function onSerialize()
  return {togglingEnabled = togglingEnabled, vehicleBlacklist = vehicleBlacklist, unicycleIds = unicycleIds, faceParts = faceParts, paints = paints}
end

local function onDeserialize(data)
  togglingEnabled = data.togglingEnabled
  vehicleBlacklist = data.vehicleBlacklist
  unicycleIds = data.unicycleIds or {}
  faceParts = data.faceParts or {}
  paints = data.paints or {}
  active = {}
  for _, player in ipairs(getPlayers()) do
    active[player] = getCurrentUnicycle(player) ~= nil
  end
end

local function getPosRot(player)
  player = player or 0
  local unicycle = active[player] and getCurrentUnicycle(player)
  if unicycle then
    return unicycle:getPosition(), core_camera.getQuat(core_camera.getContextIdForPlayer(player))
  end
end

local function getPosXYZ(player)
  player = player or 0
  local unicycle = active[player] and getCurrentUnicycle(player)
  if unicycle then
    return unicycle:getPositionXYZ()
  end
end

local function getRotXYZW(player)
  player = player or 0
  if active[player] and getCurrentUnicycle(player) then
    return core_camera.getQuatXYZW(core_camera.getContextIdForPlayer(player))
  end
end

local function enableToggling(enabled)
  togglingEnabled = enabled
end

local function isTogglingEnabled()
  return togglingEnabled
end

local function addVehicleToBlacklist(vehId)
  vehicleBlacklist[vehId] = true
end

local function removeVehicleFromBlacklist(vehId)
  vehicleBlacklist[vehId] = nil
end

local function isVehicleBlacklisted(vehId)
  return vehicleBlacklist[vehId]
end

local function clearBlacklist()
  vehicleBlacklist = {}
end

local function getBlacklist()
  return vehicleBlacklist
end

local function onClientStartMission(levelPath)
  clearBlacklist()
  togglingEnabled = true
end

local function onClientEndMission(levelPath)
  table.clear(unicycleIds)
  table.clear(hiddenUnicycleIds)
  table.clear(faceParts)
  table.clear(paints)
end

local function onSplitScreenChanged(enabled, playerCount, layout, mode)
  configureUnicycles()
end

-- hide the unicycle in that player's own render view while they use the unicycle camera, or while the big map transition flies away from them
local function onCameraChanged(player, camName, vid)
  local hiddenId = hiddenUnicycleIds[player]
  local veh = vid and getObjectByID(vid)
  local isUnicycle = veh ~= nil and veh:getJBeamFilename() == "unicycle"
  local bigMapActive = (freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive()) or camName == "bigMap" -- we check also for the cam mode "bigMap" because that will be active one frame before bigMapActive() returns true
  local hideId = isUnicycle and (camName == "unicycle" or bigMapActive) and vid or nil
  if hiddenId == hideId then return end

  if hiddenId then
    local unicycle = getObjectByID(hiddenId)
    if unicycle then unicycle:renderViewMaskClear() end
  end
  if hideId then
    local unicycle = getObjectByID(hideId)
    if unicycle then unicycle:hideInRenderView(player) end
  end
  hiddenUnicycleIds[player] = hideId
end

local function onVehicleSwitched(oldId, newId, player)
  player = player or 0

  local unicycle = scenetree.findObjectById(oldId)
  if unicycle and oldId == unicycleIds[player] then
    setUnicycleInactive(unicycle)
  end

  active[player] = getCurrentUnicycle(player) ~= nil
end

local function onVehicleColorChanged(vehId, index, paint)
  if index ~= 1 or not paint or not paint.baseColor or (core_multiseat and core_multiseat.isMultiseatActive()) then return end
  for player, unicycleId in pairs(unicycleIds) do
    if unicycleId == vehId then
      paints[player] = paint
      settings.setValue("playerCharacterColor", paint.baseColor)
      if gameplay_seatOccupants then gameplay_seatOccupants.onSettingsChanged() end
      return
    end
  end
end

local function forgetUnicycle(vehId)
  for player, unicycleId in pairs(unicycleIds) do
    if unicycleId == vehId then
      unicycleIds[player] = nil
      hiddenUnicycleIds[player] = nil
      break
    end
  end
end

local function onVehicleReplaced(vehId)
  forgetUnicycle(vehId)
end

local function onVehicleDestroyed(vehId)
  forgetUnicycle(vehId)
end

M.isWalking = isWalking
M.getPosRot = getPosRot
M.getVehicleInFront = getVehicleInFront
M.isAtParkingSpeed = isAtParkingSpeed
M.toggleWalkingMode = toggleWalkingMode
M.canToggleWalkingMode = canToggleWalkingMode
M.canSetWalkingMode = canSetWalkingMode
M.enableToggling = enableToggling
M.isTogglingEnabled = isTogglingEnabled
M.setWalkingMode = setWalkingMode
M.getStoredUnicycleId = getStoredUnicycleId
M.getFacePart = getFacePart
M.setFacePart = setFacePart
M.getPaint = getPaint
M.getInVehicle = getInVehicle
M.getDoorsidePosRot = getDoorsidePosRot
M.getCurrentUnicycle = getCurrentUnicycle
M.addVehicleToBlacklist = addVehicleToBlacklist
M.removeVehicleFromBlacklist = removeVehicleFromBlacklist
M.isVehicleBlacklisted = isVehicleBlacklisted
M.clearBlacklist = clearBlacklist
M.getBlacklist = getBlacklist
M.setRot = setRot
M.getPosXYZ = getPosXYZ
M.getRotXYZW = getRotXYZW

M.onUpdate = onUpdate
M.onSerialize = onSerialize
M.onDeserialize = onDeserialize
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onSplitScreenChanged = onSplitScreenChanged
M.onCameraChanged = onCameraChanged
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleColorChanged = onVehicleColorChanged
M.onVehicleReplaced = onVehicleReplaced
M.onVehicleDestroyed = onVehicleDestroyed

return M
