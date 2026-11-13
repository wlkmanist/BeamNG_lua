-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {
  'core_camera',
  'core_vehicle_manager',
  'core_input_actionFilter',
  'core_gamestate',
  'core_multiseat',
  'ui_vehicleSelector_vehicleSpecifications',
}
M.enableSeatEjection = false
M.enablePresenceDebugMessages = false
M.debugDisableOccupantWeight = false
M.debugDisableOccupantSystem = false
local presencePolicy = require("gameplay/vehiclePresencePolicy")
local occupantFaces = require("jbeam/sections/occupantFaces")

local defaultWeight = 89
--actuawl minimum weight is defined by jbeam of the occupant
local minWeight = 0
local maxOccupantViewBits = 8
local seatExitMargin = 0.7
local drivingActionMapMaskOwner = "seatOccupants"
local presenceMaskedActionMaps = {}
local blockedSeatTriggerColor = {1, 0.1, 0.1, 0.8}
local serializationVersion = 2
-- occupancy[vehId][seatId] = physical seat claim { player|dummy, weight }
local occupancy = {}
-- playerPresence[player] = { vehicleId, seatId?, permissionMode, permissionOverride? }
local playerPresence = {}
local lastVolumes = {}
local seatTransitions = {}
local drivingBlocked = {}
local drivingPlayerByVehicle = {}
local knownSeatsByVehicle = {}
local vehicleConfigurationChanged = {}
local visibleOccupantCameraByPlayer = {}
local vehicleOccupantsEnabledOverride = {}
local seatlessVehicleBeforeReplacement = {}

local function randomDummyColor()
  return {
    r = math.random(64, 240),
    g = math.random(64, 240),
    b = math.random(64, 240),
  }
end

local function isUnicycle(veh)
  return veh and veh:getJBeamFilename() == "unicycle"
end

local function isPassengerOnly(cargoTypes)
  if not cargoTypes then return false end
  local hasPassenger = false
  for _, cargoType in ipairs(cargoTypes) do
    if cargoType == "passenger" then
      hasPassenger = true
    else
      return false
    end
  end
  return hasPassenger
end

local function seatIdFromGroupId(groupId)
  if type(groupId) ~= "string" then return nil end
  return groupId:match("^(.*)Occupant$")
end

local function getOccupantSystemConfig(vehId)
  local vehData = core_vehicle_manager.getVehicleData(vehId)
  local vdata = vehData and vehData.vdata
  return vdata and vdata.occupantSystem
end

local function getOccupantSystemVersion(vehId)
  local occupantSystem = getOccupantSystemConfig(vehId)
  return occupantSystem and occupantSystem.version
end

local function usesSeatSystem(vehId)
  if M.debugDisableOccupantSystem then return false end
  local occupantSystem = getOccupantSystemConfig(vehId)
  if occupantSystem and occupantSystem.enabled ~= nil then
    return occupantSystem.enabled == true
  end
  local vehData = core_vehicle_manager.getVehicleData(vehId)
  local vdata = vehData and vehData.vdata
  return vdata and vdata.occupantSlotsById and next(vdata.occupantSlotsById) ~= nil or false
end

local function getDriverSeatId(vehId)
  local vehData = core_vehicle_manager.getVehicleData(vehId)
  local slots = vehData and vehData.vdata and vehData.vdata.occupantSlotsById
  for seatId, slot in pairs(slots or {}) do
    if slot.defaultPermissionMode == "driver" then return seatId end
  end
  local _, rightHandDrive = core_camera.getDriverDataById(vehId)
  return rightHandDrive and "FR" or "FL"
end

local function isFirstPersonCam(player)
  local camName = core_camera.getActiveCamName(player)
  if not camName then return false end
  return camName == "driver" or camName == "onboard.driver" or camName == "onboard.rider"
    or camName:find("^occupant%.", 1) ~= nil
end

local function getPlayerSeat(player, vehId)
  local presence = playerPresence[player]
  if presence and presence.vehicleId == vehId then return presence.seatId end
  local seats = occupancy[vehId]
  if not seats then return nil end
  for seatId, occ in pairs(seats) do
    if occ.player == player then return seatId end
  end
end

local function seatTakenByOther(vehId, seatId, player)
  local occ = occupancy[vehId] and occupancy[vehId][seatId]
  return occ ~= nil and occ.player ~= player
end

local function seatReservedByOther(vehId, seatId, player)
  for otherPlayer, transition in pairs(seatTransitions) do
    if otherPlayer ~= player and transition.vehId == vehId and transition.seatId == seatId then
      return true
    end
  end
  return false
end

local function seatUnavailable(vehId, seatId, player)
  return seatTakenByOther(vehId, seatId, player) or seatReservedByOther(vehId, seatId, player)
end

local function getTriggerWorldPosition(veh, vdata, trigger, triggerObj)
  local nodeId = tonumber(trigger.idRef)
  if not nodeId then
    for currentNodeId, node in pairs(vdata.nodes or {}) do
      if node.name == trigger.idRef then
        nodeId = node.cid or currentNodeId
        break
      end
    end
  end
  if nodeId then
    return veh:getPosition() + veh:getNodePosition(nodeId)
  end
  return triggerObj and vec3(triggerObj:getCenter()) or nil
end

local function getSeatEntries(vehId)
  if M.debugDisableOccupantSystem then return {} end
  local veh = scenetree.findObjectById(vehId)
  local vehData = core_vehicle_manager.getVehicleData(vehId)
  local vdata = vehData and vehData.vdata
  local triggers = vdata and vdata.triggers or {}
  local entries = {}
  if not veh or not vdata then return entries end

  local slots = vdata.occupantSlotsById
  if slots and next(slots) then
    for seatId, slot in pairs(slots) do
      local trigger
      local triggerId
      for currentTriggerId, currentTrigger in pairs(triggers) do
        local name = currentTrigger.id or currentTrigger.name
        if name == slot.entryTrigger then
          trigger = currentTrigger
          triggerId = currentTriggerId
          break
        end
      end
      local triggerObj = trigger and veh:getTrigger(trigger.cid or triggerId)
      entries[#entries + 1] = {
        seatId = seatId,
        slot = slot,
        trigger = trigger,
        position = trigger and getTriggerWorldPosition(veh, vdata, trigger, triggerObj) or nil,
      }
    end
    table.sort(entries, function(a, b) return a.seatId < b.seatId end)
    return entries
  end

  return entries
end

local function getSeatEntry(vehId, seatId)
  for _, entry in ipairs(getSeatEntries(vehId)) do
    if entry.seatId == seatId then return entry end
  end
end

local function normalizePermissionMode(mode, fallback)
  return presencePolicy.normalizeMode(mode, fallback)
end

local function getDefaultUnseatedPermissionMode(player, vehId, explicitMode)
  if presencePolicy.isValidMode(explicitMode) then return explicitMode end
  if not usesSeatSystem(vehId) then return "unrestricted" end

  local query = {player = player or 0, vehicleId = vehId, mode = nil}
  extensions.hook("onResolveVehiclePresenceMode", query)
  if presencePolicy.isValidMode(query.mode) then return query.mode end

  local multiplayerActive = multiplayer_sessionManager
    and multiplayer_sessionManager.getCurrentSession
    and multiplayer_sessionManager.getCurrentSession() ~= nil
  local players = core_multiseat and core_multiseat.getPlayers and core_multiseat.getPlayers() or {}
  local multiseatActive = (core_multiseat and core_multiseat.isMultiseatActive
      and core_multiseat.isMultiseatActive())
    or #players > 1
  local gameState = core_gamestate and core_gamestate.state and core_gamestate.state.state
  local context = {
    mode = multiplayerActive and "multiplayer" or (multiseatActive and "multiseat" or gameState),
    isMultiseatActive = multiseatActive,
  }
  return presencePolicy.defaultUnseatedMode(context)
end

local function getSeatPermissionMode(vehId, seatId, explicitMode)
  if presencePolicy.isValidMode(explicitMode) then return explicitMode end
  local entry = getSeatEntry(vehId, seatId)
  return normalizePermissionMode(entry and entry.slot and entry.slot.defaultPermissionMode, "passenger")
end

local function presenceEqual(a, b)
  if a == b then return true end
  if not a or not b then return false end
  return a.vehicleId == b.vehicleId
    and a.seatId == b.seatId
    and a.permissionMode == b.permissionMode
    and a.permissionOverride == b.permissionOverride
end

local function showPresenceDebugMessage(player, presence)
  if not M.enablePresenceDebugMessages then return end
  local vehicleId = presence and presence.vehicleId or "none"
  local permissionMode = presence and presence.permissionMode or "none"
  local seat = presence and presence.seatId and ("Seat: " .. tostring(presence.seatId)) or "Unseated"
  guihooks.trigger("Message", {
    msg = string.format(
      "Player #%s | Vehicle: %s | Permission: %s | %s",
      tostring(player),
      tostring(vehicleId),
      tostring(permissionMode),
      seat
    ),
    ttl = 4,
    category = "vehiclePresenceDebug" .. tostring(player),
    icon = "info",
    player = player,
  })
end

local function setPlayerPresence(player, vehId, seatId, permissionMode, permissionOverride)
  player = player or 0
  if M.debugDisableOccupantSystem and vehId and vehId ~= -1 then
    seatId = nil
    permissionMode = "unrestricted"
    permissionOverride = nil
  end
  local old = playerPresence[player]
  local nextPresence
  if vehId and vehId ~= -1 then
    nextPresence = {
      vehicleId = vehId,
      seatId = seatId,
      permissionMode = normalizePermissionMode(permissionMode, "passenger"),
      permissionOverride = presencePolicy.isValidMode(permissionOverride) and permissionOverride or nil,
    }
  end
  playerPresence[player] = nextPresence
  if not presenceEqual(old, nextPresence) then
    showPresenceDebugMessage(player, nextPresence)
    extensions.hook("onPlayerVehiclePresenceChanged", player, old, nextPresence)
  end
  return nextPresence
end

local function getPlayerPresence(player)
  local presence = playerPresence[player or 0]
  return presence and deepcopy(presence) or nil
end

local function releasePlayerSeat(player, vehId)
  local presence = playerPresence[player]
  if not presence or (vehId and presence.vehicleId ~= vehId) then return end
  if be and be:getPlayerVehicleID(player) == presence.vehicleId then
    setPlayerPresence(player, presence.vehicleId, nil, presence.permissionMode, presence.permissionOverride)
  else
    setPlayerPresence(player, nil)
  end
end

local function isValidSeatId(vehId, seatId, caller)
  if getSeatEntry(vehId, seatId) then return true end
  log("W", "seatOccupants", string.format(
    "%s rejected unknown seat %q for vehicle %s",
    caller or "Seat operation",
    tostring(seatId),
    tostring(vehId)
  ))
  return false
end

local function selectAvailableSeat(vehId, player, position)
  local entries = getSeatEntries(vehId)
  if #entries == 0 then return nil, false end

  local driverSeatId = getDriverSeatId(vehId)
  for _, entry in ipairs(entries) do
    if entry.seatId == driverSeatId and not seatUnavailable(vehId, entry.seatId, player) then
      return entry.seatId, true
    end
  end

  local bestEntry
  local bestDistance = math.huge
  local firstFreeEntry
  for _, entry in ipairs(entries) do
    if not seatUnavailable(vehId, entry.seatId, player) then
      firstFreeEntry = firstFreeEntry or entry
      if position and entry.position then
        local distance = position:squaredDistance(entry.position)
        if distance < bestDistance then
          bestEntry = entry
          bestDistance = distance
        end
      end
    end
  end
  bestEntry = bestEntry or firstFreeEntry
  return bestEntry and bestEntry.seatId or nil, true
end

local function isVehicleEnterable(vehId, player)
  local veh = scenetree.findObjectById(vehId)
  if not veh or isUnicycle(veh) or not veh:getActive() then return false end
  if be and be:getPlayerVehicleID(player or 0) == vehId then return true end
  if veh.playerUsable == false then return false end

  local switchingAllowed = true
  if core_input_actionFilter and core_input_actionFilter.isActionBlocked then
    local nextBlocked = core_input_actionFilter.isActionBlocked("switch_next_vehicle")
    local previousBlocked = core_input_actionFilter.isActionBlocked("switch_previous_vehicle")
    switchingAllowed = not nextBlocked or not previousBlocked
  end

  local walkingAllowed = gameplay_walk and gameplay_walk.canToggleWalkingMode
    and gameplay_walk.canToggleWalkingMode(false, player or 0)
  if walkingAllowed and gameplay_walk.isVehicleBlacklisted and gameplay_walk.isVehicleBlacklisted(vehId) then
    walkingAllowed = false
  end

  return switchingAllowed or walkingAllowed
end

local function canEnterVehicle(vehId, player)
  return isVehicleEnterable(vehId, player)
end

local function showSeatMessage(player, translationId)
  guihooks.trigger("Message", {
    msg = _tr(translationId),
    ttl = 3,
    category = "seatOccupants",
    icon = "warning",
    player = player or 0,
  })
end

local function showVehicleFullMessage(player)
  showSeatMessage(player, "ui.gameplay.seatOccupants.vehicleFull")
end

local function syncDrivingForPlayer(player)
  local vehId = be and be:getPlayerVehicleID(player)
  local veh = vehId and vehId ~= -1 and scenetree.findObjectById(vehId)
  local presence = playerPresence[player]
  local mode = presence and presence.vehicleId == vehId and presence.permissionMode or nil
  local block = veh ~= nil and not isUnicycle(veh) and mode == "passenger"
  if drivingBlocked[player] == block then return end
  drivingBlocked[player] = block
end

local function syncDrivingForVehicle(vehId, force)
  local veh = scenetree.findObjectById(vehId)
  if not veh or isUnicycle(veh) then return end

  local controllers = {}
  for player, presence in pairs(playerPresence) do
    if presence.vehicleId == vehId
        and (presence.permissionMode == "driver" or presence.permissionMode == "unrestricted") then
      controllers[#controllers + 1] = player
    end
  end
  table.sort(controllers)
  local controllerKey = table.concat(controllers, ",")
  local previousKey = drivingPlayerByVehicle[vehId]
  if not force and previousKey == controllerKey then return end
  drivingPlayerByVehicle[vehId] = controllerKey
  local resetForSeatChange = previousKey ~= controllerKey
    and not settings.getValue("stickyVehicleControlsOnSeatChange", false)
  if previousKey ~= nil and (force or resetForSeatChange) then
    veh:queueLuaCommand("if input and input.neutralizeControls then input.neutralizeControls() end")
  end
end

local function applyDrivingActionMapMask()
  local actionMaps = {VehicleCommon = "driving", VehicleSpecific = "driving"}
  for _, veh in ipairs(getAllVehicles()) do
    local vehData = core_vehicle_manager.getVehicleData(veh:getId())
    local slots = vehData and vehData.vdata and vehData.vdata.occupantSlotsById
    for _, slot in pairs(slots or {}) do
      for _, actionMapName in ipairs(slot.actionMaps or {}) do
        actionMaps[actionMapName] = "slot"
      end
    end
  end

  for actionMapName, mapKind in pairs(actionMaps) do
    local playerMask = -1
    for player, presence in pairs(playerPresence) do
      local allowed = drivingBlocked[player] == false
        or presencePolicy.allowsActionMap(presence.permissionMode, mapKind)
      if not allowed then
        playerMask = bit.band(playerMask, bit.bnot(bit.lshift(1, player)))
      end
    end
    core_input_actionFilter.setActionMapPlayerMask(drivingActionMapMaskOwner, actionMapName, playerMask)
    presenceMaskedActionMaps[actionMapName] = true
  end

  for actionMapName in pairs(presenceMaskedActionMaps) do
    if not actionMaps[actionMapName] then
      core_input_actionFilter.clearActionMapPlayerMask(drivingActionMapMaskOwner, actionMapName)
      presenceMaskedActionMaps[actionMapName] = nil
    end
  end
end

local function syncDriving()
  local players = {}
  local vehicles = {}
  for vehId, seats in pairs(occupancy) do
    vehicles[vehId] = true
    for _, occ in pairs(seats) do
      if occ.player then players[occ.player] = true end
    end
  end
  for player, presence in pairs(playerPresence) do
    players[player] = true
    vehicles[presence.vehicleId] = true
  end
  for vehId in pairs(drivingPlayerByVehicle) do
    vehicles[vehId] = true
  end
  for player in pairs(drivingBlocked) do
    players[player] = true
  end
  for vehId in pairs(vehicles) do
    syncDrivingForVehicle(vehId)
  end
  for player in pairs(players) do
    syncDrivingForPlayer(player)
  end

  applyDrivingActionMapMask()
end

local function setPlayerPermissionMode(player, permissionMode)
  player = player or 0
  if not presencePolicy.isValidMode(permissionMode) then return false, "invalidPermissionMode" end
  local presence = playerPresence[player]
  if not presence then return false, "noPresence" end
  setPlayerPresence(player, presence.vehicleId, presence.seatId, permissionMode, permissionMode)
  syncDriving()
  return true
end

local function clearOccupantCameraVisibility(player)
  local previous = visibleOccupantCameraByPlayer[player]
  if not previous or not core_camera then return end
  local cameras = core_camera.getCameraDataById(previous.vehId, previous.ctxId)
  for _, override in ipairs(previous.overrides or {}) do
    local camera = cameras and cameras[override.camName]
    if camera then camera.hidden = override.hidden end
  end
  visibleOccupantCameraByPlayer[player] = nil
end

local function syncOccupantCamera(player, vehId, seatId)
  if not core_camera then return end
  clearOccupantCameraVisibility(player)

  local ctxId = core_camera.getContextIdForPlayer(player)
  local cameras = core_camera.getCameraDataById(vehId, ctxId)
  local entry = getSeatEntry(vehId, seatId)
  local configuredCamName = entry and entry.slot and entry.slot.cameraName
  local camName = configuredCamName or ("occupant." .. seatId)

  local overrides = {}
  for currentCamName, camera in pairs(cameras or {}) do
    local occupantCamera = currentCamName == "driver"
      or currentCamName:find("^occupant%.", 1) ~= nil
    if occupantCamera then
      local hidden = currentCamName ~= camName
      if camera.hidden ~= hidden then
        overrides[#overrides + 1] = {camName = currentCamName, hidden = camera.hidden}
        camera.hidden = hidden
      end
    end
  end
  if #overrides > 0 then
    visibleOccupantCameraByPlayer[player] = {vehId = vehId, ctxId = ctxId, overrides = overrides}
  end

  if core_camera.getActiveGlobalCameraName and core_camera.getActiveGlobalCameraName(player) then return end
  local activeCamName = core_camera.getActiveCamName(player)
  local occupantCameraActive = activeCamName == "driver"
    or activeCamName == "onboard.driver"
    or (activeCamName and activeCamName:find("^occupant%.", 1) ~= nil)
  if occupantCameraActive and activeCamName ~= camName then
    core_camera.setByName(player, camName)
  end
end

local function syncUnseatedCameras(player, vehId)
  if not core_camera then return end
  clearOccupantCameraVisibility(player)

  local ctxId = core_camera.getContextIdForPlayer(player)
  local cameras = core_camera.getCameraDataById(vehId, ctxId)
  local overrides = {}
  for camName, camera in pairs(cameras or {}) do
    local occupantCamera = camName == "driver"
      or camName:find("^occupant%.", 1) ~= nil
    if occupantCamera and camera.hidden then
      overrides[#overrides + 1] = {camName = camName, hidden = true}
      camera.hidden = false
    end
  end
  if #overrides > 0 then
    visibleOccupantCameraByPlayer[player] = {vehId = vehId, ctxId = ctxId, overrides = overrides}
  end
end

local function syncPresenceCameras(player)
  local presence = playerPresence[player]
  if not presence then
    clearOccupantCameraVisibility(player)
  elseif presence.seatId then
    syncOccupantCamera(player, presence.vehicleId, presence.seatId)
  else
    syncUnseatedCameras(player, presence.vehicleId)
  end
end

local function syncVehiclePresenceCameras(vehId)
  for player, presence in pairs(playerPresence) do
    if presence.vehicleId == vehId then syncPresenceCameras(player) end
  end
end

local function isOccupantBoxPart(container)
  local partPath = container.partPath
  return type(partPath) == "string" and partPath:find("occupant_generic", 1, true) ~= nil
end

local function getOccupantColorI(occupant)
  if not occupant then return nil end
  if occupant.color then
    return ColorI(occupant.color.r, occupant.color.g, occupant.color.b, 255)
  end
  if occupant.player == nil or not gameplay_walk then return nil end
  local color = gameplay_walk.getPaint(occupant.player).baseColor
  if not color then return nil end
  return ColorI(
    math.floor((color[1] or 0) * 255 + 0.5),
    math.floor((color[2] or 0) * 255 + 0.5),
    math.floor((color[3] or 0) * 255 + 0.5),
    255
  )
end

local function setOccupantMeshes(veh, partPath, visible, hideHeadPlayer, occupant)
  local vehData = core_vehicle_manager.getVehicleData(veh:getId())
  local vdata = vehData and vehData.vdata
  if not vdata then return end
  local color = visible and getOccupantColorI(occupant)
  local faceMaterial = occupantFaces.getFaceMaterial(visible and occupant and occupant.player and gameplay_walk and gameplay_walk.getFacePart(occupant.player))
  local function applyToMesh(meshData)
    if meshData.partPath == partPath and meshData.mesh then
      local meshKind = meshData.originalMesh or meshData.mesh
      if meshKind == "character_torso" or meshKind == "character_head" then
        local isHead = meshKind == "character_head"
        for bit = 0, maxOccupantViewBits - 1 do
          local hidden = visible and isHead and hideHeadPlayer ~= nil and bit == hideHeadPlayer
          veh:setMeshHiddenInRenderView(meshData.mesh, bit, hidden)
        end
        veh:setMeshAlpha(visible and 1 or 0, meshData.mesh)
        if color then
          veh:setMeshColor(meshData.mesh, color, color, color)
        end
        if isHead and meshData.faceMaterialSwitch then
          veh:switchMaterial(meshData.faceMaterialSwitch, faceMaterial)
        end
      end
    end
  end
  for _, flexbody in pairs(vdata.flexbodies or {}) do applyToMesh(flexbody) end
  for _, prop in pairs(vdata.props or {}) do applyToMesh(prop) end
end

local function syncOccupantMeshes(veh)
  local vehId = veh:getId()
  local vehData = core_vehicle_manager.getVehicleData(vehId)
  local vdata = vehData and vehData.vdata
  if not vdata then return end
  local seats = occupancy[vehId] or {}
  local occupantMeshesEnabled = vehicleOccupantsEnabledOverride[vehId]
  if occupantMeshesEnabled == nil then
    occupantMeshesEnabled = settings.getValue("enableSeatOccupants", true)
  end
  for _, container in pairs(vdata.cargoStorage or {}) do
    if isPassengerOnly(container.cargoTypes) and isOccupantBoxPart(container) then
      local seatId = seatIdFromGroupId(container.groupId)
      local occ = seatId and seats[seatId]
      local hideHeadPlayer
      if occupantMeshesEnabled and occ and occ.player and be:getPlayerVehicleID(occ.player) == vehId and isFirstPersonCam(occ.player) then
        hideHeadPlayer = occ.player
      end
      setOccupantMeshes(veh, container.partPath, occupantMeshesEnabled and occ ~= nil, hideHeadPlayer, occ)
    end
  end
end

-- Re-assert occupant mesh visibility after a path modified it without using the sync hooks
local function refreshOccupantMeshes(vehId)
  local veh = vehId and scenetree.findObjectById(vehId)
  if veh then syncOccupantMeshes(veh) end
end

local function volumesEqual(a, b)
  if a == b then return true end
  if not a or not b then return false end
  for id, volume in pairs(a) do
    if b[id] ~= volume then return false end
  end
  for id, _ in pairs(b) do
    if a[id] == nil then return false end
  end
  return true
end

local function playerOccupies(player, vehId)
  local seats = occupancy[vehId]
  if not seats then return false end
  for _, occ in pairs(seats) do
    if occ.player == player then return true end
  end
  return false
end

local function applyVehicle(vehId, visualsOnly, force)
  local veh = scenetree.findObjectById(vehId)
  if not veh or isUnicycle(veh) or not core_vehicleBridge then return end
  syncOccupantMeshes(veh)

  core_vehicleBridge.requestValue(veh, function(vehCargoContainerData)
    if not vehCargoContainerData or not vehCargoContainerData[1] then return end
    local vehNow = scenetree.findObjectById(vehId)
    if not vehNow then return end

    local seats = occupancy[vehId] or {}
    local knownSeats = {}
    local knownSeatIds = {}
    local newDriverSeatId
    for _, entry in ipairs(getSeatEntries(vehId)) do
      local permissionMode = entry.slot and entry.slot.defaultPermissionMode or "passenger"
      knownSeats[entry.seatId] = permissionMode
      knownSeatIds[#knownSeatIds + 1] = entry.seatId
      if permissionMode == "driver" then newDriverSeatId = entry.seatId end
    end

    local previousKnownSeats = knownSeatsByVehicle[vehId]
    local configurationChanged = vehicleConfigurationChanged[vehId] == true
      or (previousKnownSeats ~= nil and not volumesEqual(previousKnownSeats, knownSeats))
    knownSeatsByVehicle[vehId] = knownSeats
    vehicleConfigurationChanged[vehId] = nil

    local reconciledSeats = {}
    local removedPlayers = {}
    local seatsChanged = false
    local playerClaims = {}
    for oldSeatId, occ in pairs(seats) do
      if configurationChanged and occ.dummy then
        seatsChanged = true
      elseif occ.player ~= nil then
        playerClaims[#playerClaims + 1] = {oldSeatId = oldSeatId, occupant = occ}
      elseif knownSeats[oldSeatId] then
        reconciledSeats[oldSeatId] = occ
      else
        seatsChanged = true
      end
    end
    local dummiesRemoved = seatsChanged
    table.sort(playerClaims, function(a, b) return a.oldSeatId < b.oldSeatId end)
    table.sort(knownSeatIds)

    if configurationChanged and previousKnownSeats and newDriverSeatId then
      for _, claim in ipairs(playerClaims) do
        if previousKnownSeats[claim.oldSeatId] == "driver" and not reconciledSeats[newDriverSeatId] then
          reconciledSeats[newDriverSeatId] = claim.occupant
          claim.assigned = true
          if claim.oldSeatId ~= newDriverSeatId then seatsChanged = true end
          break
        end
      end
    end

    for _, claim in ipairs(playerClaims) do
      if not claim.assigned and knownSeats[claim.oldSeatId] and not reconciledSeats[claim.oldSeatId] then
        reconciledSeats[claim.oldSeatId] = claim.occupant
        claim.assigned = true
      end
    end

    for _, claim in ipairs(playerClaims) do
      if not claim.assigned and configurationChanged then
        for _, seatId in ipairs(knownSeatIds) do
          if not reconciledSeats[seatId] then
            reconciledSeats[seatId] = claim.occupant
            claim.assigned = true
            seatsChanged = true
            break
          end
        end
      end
      if not claim.assigned then
        removedPlayers[#removedPlayers + 1] = claim.occupant.player
        seatsChanged = true
      end
    end

    if seatsChanged then
      seats = reconciledSeats
      occupancy[vehId] = next(seats) and seats or nil
    end
    if configurationChanged then
      for seatId, occ in pairs(reconciledSeats) do
        if occ.player ~= nil then
          local presence = playerPresence[occ.player]
          local permissionOverride = presence and presence.permissionOverride
          setPlayerPresence(
            occ.player,
            vehId,
            seatId,
            getSeatPermissionMode(vehId, seatId, permissionOverride),
            permissionOverride
          )
          syncOccupantCamera(occ.player, vehId, seatId)
        end
      end
    end
    if seatsChanged then
      for _, player in ipairs(removedPlayers) do
        clearOccupantCameraVisibility(player)
        releasePlayerSeat(player, vehId)
        if playerPresence[player] then syncUnseatedCameras(player, vehId) end
        extensions.hook("onSeatOccupantExit", player, vehId)
      end
      if dummiesRemoved then extensions.hook("onSeatOccupantExit", nil, vehId) end -- nil player: dummy non-player occupants, such as the AI rally codriver
    end
    if seatsChanged or configurationChanged then
      syncDriving()
    end
    syncOccupantMeshes(vehNow)

    local weights = {}
    local volumes = {}
    local hasPassenger = false
    for _, container in ipairs(vehCargoContainerData[1]) do
      if isPassengerOnly(container.cargoTypes) then
        hasPassenger = true
        local seatId = seatIdFromGroupId(container.groupId)
        local occ = seatId and seats[seatId]
        local occupantsEnabled = vehicleOccupantsEnabledOverride[vehId] ~= false
        local volume = occupantsEnabled and not M.debugDisableOccupantWeight and occ and occ.weight or minWeight
        weights[container.id] = {
          containerId = container.id,
          volume = volume,
          density = 1
        }
        volumes[container.id] = volume
      end
    end

    if not hasPassenger then return end
    if not visualsOnly and (force or not volumesEqual(lastVolumes[vehId], volumes)) then
      lastVolumes[vehId] = volumes
      core_vehicleBridge.executeAction(vehNow, "setCargoContainers", weights, "updateExplicit")
    end
  end, "getCargoContainers")
end

local function clearPlayerFromVehicles(player, skipVehId)
  for vehId, seats in pairs(occupancy) do
    if vehId ~= skipVehId then
      local changed = false
      for seatId, occ in pairs(seats) do
        if occ.player == player then
          seats[seatId] = nil
          changed = true
        end
      end
      if changed then
        clearOccupantCameraVisibility(player)
        if not next(seats) then
          occupancy[vehId] = nil
        end
        applyVehicle(vehId)
        syncDriving()
      end
    end
  end
  local presence = playerPresence[player]
  if presence and presence.vehicleId ~= skipVehId then
    local presenceVehId = presence.vehicleId
    releasePlayerSeat(player, presenceVehId)
    if playerPresence[player] then syncUnseatedCameras(player, presenceVehId) end
  end
end

local function setOccupied(vehId, seatId, player, weight, permissionOverride)
  if not vehId then return false end
  local veh = scenetree.findObjectById(vehId)
  if not veh or isUnicycle(veh) then return false end

  player = player or 0
  weight = weight or defaultWeight

  if not seatId then
    seatId = getDriverSeatId(vehId)
  end
  if not isValidSeatId(vehId, seatId, "setOccupied") then return false end
  if seatUnavailable(vehId, seatId, player) then return false end

  clearPlayerFromVehicles(player, vehId)

  occupancy[vehId] = occupancy[vehId] or {}

  for otherSeat, occ in pairs(occupancy[vehId]) do
    if occ.player == player and otherSeat ~= seatId then
      occupancy[vehId][otherSeat] = nil
    end
  end

  occupancy[vehId][seatId] = {kind = "player", player = player, playerId = player, weight = weight}
  local permissionMode = getSeatPermissionMode(vehId, seatId, permissionOverride)
  setPlayerPresence(player, vehId, seatId, permissionMode, permissionOverride)
  applyVehicle(vehId)
  syncDriving()
  syncOccupantCamera(player, vehId, seatId)
  return true
end

local function clearOccupied(vehId, seatIdOrPlayer)
  if seatIdOrPlayer == nil then
    if vehId then
      for player, transition in pairs(seatTransitions) do
        if transition.vehId == vehId then
          seatTransitions[player] = nil
        end
      end
      for _, occ in pairs(occupancy[vehId] or {}) do
        if occ.player ~= nil then
          clearOccupantCameraVisibility(occ.player)
          releasePlayerSeat(occ.player, vehId)
        end
      end
      occupancy[vehId] = nil
      applyVehicle(vehId)
      syncDriving()
    end
    return
  end

  if type(seatIdOrPlayer) == "number" then
    seatTransitions[seatIdOrPlayer] = nil
    clearPlayerFromVehicles(seatIdOrPlayer)
    return
  end

  for player, transition in pairs(seatTransitions) do
    if transition.vehId == vehId and transition.seatId == seatIdOrPlayer then
      seatTransitions[player] = nil
    end
  end
  if vehId and occupancy[vehId] then
    local occ = occupancy[vehId][seatIdOrPlayer]
    if occ and occ.player ~= nil then
      clearOccupantCameraVisibility(occ.player)
      releasePlayerSeat(occ.player, vehId)
    end
    occupancy[vehId][seatIdOrPlayer] = nil
    if not next(occupancy[vehId]) then
      occupancy[vehId] = nil
    end
    applyVehicle(vehId)
    syncDriving()
  end
end

local function completeSeatTransition(player, vehId, oldVehId)
  local transition = seatTransitions[player]
  if not transition or transition.vehId ~= vehId then return false end
  seatTransitions[player] = nil
  local wasSeatedInTarget = getPlayerSeat(player, vehId) ~= nil

  local exitedVehId
  if oldVehId and oldVehId ~= -1 and oldVehId ~= vehId and playerOccupies(player, oldVehId) then
    exitedVehId = oldVehId
  end

  if not setOccupied(vehId, transition.seatId, player, transition.weight, transition.permissionOverride) then
    if exitedVehId then
      clearPlayerFromVehicles(player)
      extensions.hook("onSeatOccupantExit", player, exitedVehId)
    end
    return false
  end

  if exitedVehId then
    extensions.hook("onSeatOccupantExit", player, exitedVehId)
  end
  if oldVehId ~= vehId or not wasSeatedInTarget then
    extensions.hook("onSeatOccupantEnter", player, vehId)
  end
  syncOccupantCamera(player, vehId, transition.seatId)
  return true
end

local function completeUnseatedTransition(player, vehId)
  local transition = seatTransitions[player]
  if not transition or transition.vehId ~= vehId or transition.seatId ~= nil then return false end
  seatTransitions[player] = nil
  local oldPresence = playerPresence[player]
  local oldSeatId = oldPresence and oldPresence.vehicleId == vehId and oldPresence.seatId or nil
  clearPlayerFromVehicles(player)
  setPlayerPresence(
    player,
    vehId,
    nil,
    getDefaultUnseatedPermissionMode(player, vehId, transition.permissionOverride),
    transition.permissionOverride
  )
  syncUnseatedCameras(player, vehId)
  syncDriving()
  if oldSeatId then extensions.hook("onSeatOccupantExit", player, vehId) end
  return true
end

local function occupyPlayerVehicle(player, vehId, oldVehId)
  player = player or 0
  local transition = seatTransitions[player]
  if transition then
    if transition.vehId == vehId then
      if transition.seatId then
        completeSeatTransition(player, vehId, oldVehId)
      else
        completeUnseatedTransition(player, vehId)
      end
      return
    end
    seatTransitions[player] = nil
  end

  if oldVehId == vehId then return end
  local oldVeh = oldVehId and oldVehId ~= -1 and scenetree.findObjectById(oldVehId)
  if not oldVeh or isUnicycle(oldVeh) then oldVehId = nil end
  local veh = vehId and vehId ~= -1 and scenetree.findObjectById(vehId)
  local entering = veh and not isUnicycle(veh)

  if not entering then
    if oldVehId and playerOccupies(player, oldVehId) then
      clearPlayerFromVehicles(player)
      extensions.hook("onSeatOccupantExit", player, oldVehId)
    end
    setPlayerPresence(player, nil)
    clearOccupantCameraVisibility(player)
    syncDriving()
    return
  end

  local existingPresence = playerPresence[player]
  if existingPresence and existingPresence.vehicleId == vehId
      and (not oldVehId or oldVehId == vehId) then
    return
  end

  local exitedVehId
  if oldVehId and oldVehId ~= vehId and playerOccupies(player, oldVehId) then
    exitedVehId = oldVehId
  end

  local seatId, hasSeats = selectAvailableSeat(vehId, player)
  local entered
  if hasSeats and seatId then
    entered = setOccupied(vehId, seatId, player, defaultWeight)
  else
    clearPlayerFromVehicles(player)
    setPlayerPresence(player, vehId, nil, getDefaultUnseatedPermissionMode(player, vehId))
    syncUnseatedCameras(player, vehId)
    syncDriving()
    entered = true
  end
  if not entered then
    clearPlayerFromVehicles(player)
    syncDrivingForPlayer(player)
    syncDriving()
  end
  if exitedVehId then
    extensions.hook("onSeatOccupantExit", player, exitedVehId)
  end
  if entered and seatId and oldVehId ~= vehId then
    extensions.hook("onSeatOccupantEnter", player, vehId)
  end
  if entered and seatId then
    syncOccupantCamera(player, vehId, seatId)
  end
end

local function findTrigger(vdata, triggerId)
  if not vdata or not vdata.triggers or triggerId == nil then return nil end
  local row = vdata.triggers[triggerId] or vdata.triggers[tonumber(triggerId)]
  if row then return row end
  local triggerIdStr = tostring(triggerId)
  for _, ab in pairs(vdata.triggers) do
    if ab.id == triggerId or ab.name == triggerId or tostring(ab.cid) == triggerIdStr then
      return ab
    end
  end
end

local function seatIdFromTrigger(vehId, triggerId)
  local vehData = core_vehicle_manager.getVehicleData(vehId)
  local trigger = findTrigger(vehData and vehData.vdata, triggerId)
  if not trigger then return nil end
  local name = trigger.id or trigger.name
  if type(name) ~= "string" then return nil end
  return name:match("^enterSeat_(.+)$")
end

local function canPlayerLeaveSeat(player)
  return not gameplay_walk or not gameplay_walk.canSetWalkingMode
    or gameplay_walk.canSetWalkingMode(true, false, player)
end

local function onVehicleTriggerActionLabel(data)
  if data.actionName ~= "enterSeat" then return end
  if M.debugDisableOccupantSystem then
    if isVehicleEnterable(data.vehicleId, data.player or 0) then
      data.title = _tr("ui.radialmenu2.enterVehicle")
      data.icon = "seatArrowInLeft"
    else
      data.title = _tr("ui.gameplay.seatOccupants.cannotSitHere")
      data.icon = "circleSlashed"
      data.color = blockedSeatTriggerColor
    end
    return
  end
  local trigger = data.trigger
  local name = trigger and (trigger.id or trigger.name)
  local seatId = type(name) == "string" and name:match("^enterSeat_(.+)$")
  if not seatId then return end

  local player = data.player or 0
  local presence = playerPresence[player]
  data.permissionMode = presence and presence.vehicleId == data.vehicleId and presence.permissionMode or nil
  data.unseated = presence and presence.vehicleId == data.vehicleId and presence.seatId == nil or false
  local occ = occupancy[data.vehicleId] and occupancy[data.vehicleId][seatId]
  if occ and occ.player == player then
    if canPlayerLeaveSeat(player) then
      data.title = _tr("ui.gameplay.seatOccupants.exitVehicle")
      data.icon = "seatArrowOutLeft"
    else
      data.title = _tr("ui.gameplay.seatOccupants.cannotExitVehicle")
      data.icon = "circleSlashed"
      data.color = blockedSeatTriggerColor
    end
    return
  end
  if M.enableSeatEjection and occ and occ.player ~= nil then
    data.title = _tr("ui.gameplay.seatOccupants.ejectPlayer")
    data.icon = "danger"
    data.color = blockedSeatTriggerColor
    return
  end
  if occ or seatReservedByOther(data.vehicleId, seatId, player) then
    data.title = _tr("ui.gameplay.seatOccupants.seatOccupied")
    data.icon = "circleSlashed"
    data.color = blockedSeatTriggerColor
    return
  end
  local currentSeatId = getPlayerSeat(player, data.vehicleId)
  if currentSeatId and currentSeatId ~= seatId and not canPlayerLeaveSeat(player) then
    data.title = _tr("ui.gameplay.seatOccupants.cannotSwitchSeats")
    data.icon = "circleSlashed"
    data.color = blockedSeatTriggerColor
    return
  end
  if not isVehicleEnterable(data.vehicleId, player) then
    data.title = _tr("ui.gameplay.seatOccupants.cannotSitHere")
    data.icon = "circleSlashed"
    data.color = blockedSeatTriggerColor
    return
  end

  local entry = getSeatEntry(data.vehicleId, seatId)
  local slotName = entry and entry.slot and entry.slot.displayName
  local customSeatName = type(slotName) == "string" and slotName ~= "" and slotName or nil
  local seatName = customSeatName and _tr(customSeatName)
    or _tr(seatId == getDriverSeatId(data.vehicleId)
      and "ui.gameplay.seatOccupants.driverSeat"
      or "ui.gameplay.seatOccupants.passengerSeat")
  data.title = core_locales.contextTranslate("ui.gameplay.seatOccupants.sitHere", {seatName = seatName})
  data.icon = "seatArrowInLeft"
end

local function requestEnterSeat(vehId, seatId, player, permissionOverride)
  player = player or 0
  if not vehId or not seatId then return end
  local veh = scenetree.findObjectById(vehId)
  if not veh or isUnicycle(veh) then return false end
  if not isValidSeatId(vehId, seatId, "requestEnterSeat") then return false end
  if getPlayerSeat(player, vehId) == seatId then
    if not canPlayerLeaveSeat(player) then
      showSeatMessage(player, "ui.gameplay.seatOccupants.cannotExitVehicle")
      return false
    end
    if gameplay_walk and gameplay_walk.toggleWalkingMode then
      gameplay_walk.toggleWalkingMode(player)
    end
    return true
  end
  if getPlayerSeat(player, vehId) and not canPlayerLeaveSeat(player) then
    showSeatMessage(player, "ui.gameplay.seatOccupants.cannotSwitchSeats")
    return false
  end
  if seatUnavailable(vehId, seatId, player) then
    showSeatMessage(player, "ui.gameplay.seatOccupants.seatOccupied")
    return false
  end
  if not isVehicleEnterable(vehId, player) then
    showSeatMessage(player, "ui.gameplay.seatOccupants.cannotSitHere")
    return false
  end

  local currentVid = be:getPlayerVehicleID(player)
  local walking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking(player)
  if currentVid ~= vehId and walking and gameplay_walk.isAtParkingSpeed and not gameplay_walk.isAtParkingSpeed(player) then
    return false
  end

  seatTransitions[player] = {
    vehId = vehId,
    seatId = seatId,
    weight = defaultWeight,
    permissionOverride = presencePolicy.isValidMode(permissionOverride) and permissionOverride or nil,
  }
  if currentVid == vehId then
    return completeSeatTransition(player, vehId, currentVid)
  end

  if walking then
    gameplay_walk.getInVehicle(veh, player)
  else
    be:enterVehicle(player, veh)
  end

  local transition = seatTransitions[player]
  if transition then
    if be:getPlayerVehicleID(player) == vehId then
      completeSeatTransition(player, vehId, currentVid)
    else
      seatTransitions[player] = nil
    end
  end
  return getPlayerSeat(player, vehId) == seatId
end

local requestUnseatedPresence

local function requestEnterBestSeat(vehId, player, walkingPos)
  player = player or 0
  if not usesSeatSystem(vehId) then return nil end
  local seatId, hasSeats = selectAvailableSeat(vehId, player, walkingPos)
  if not hasSeats or not seatId then
    local permissionMode = getDefaultUnseatedPermissionMode(player, vehId)
    if permissionMode == "unrestricted" then
      return requestUnseatedPresence(player, vehId, permissionMode)
    end
    showVehicleFullMessage(player)
    return false
  end
  return requestEnterSeat(vehId, seatId, player)
end

requestUnseatedPresence = function(player, vehId, permissionMode)
  player = player or 0
  local veh = vehId and scenetree.findObjectById(vehId)
  if not veh or isUnicycle(veh) then return false, "invalidVehicle" end
  if permissionMode ~= nil and not presencePolicy.isValidMode(permissionMode) then
    return false, "invalidPermissionMode"
  end

  seatTransitions[player] = {
    vehId = vehId,
    seatId = nil,
    permissionOverride = permissionMode,
  }
  if be:getPlayerVehicleID(player) == vehId then
    return completeUnseatedTransition(player, vehId)
  end

  local walking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking(player)
  if walking and gameplay_walk.getInVehicle then
    gameplay_walk.getInVehicle(veh, player)
  else
    be:enterVehicle(player, veh)
  end
  if seatTransitions[player] and be:getPlayerVehicleID(player) == vehId then
    return completeUnseatedTransition(player, vehId)
  end
  return playerPresence[player] ~= nil
    and playerPresence[player].vehicleId == vehId
    and playerPresence[player].seatId == nil
end

local function getCurrentVehicleId(player)
  local vehId = be and be:getPlayerVehicleID(player or 0)
  local veh = vehId and vehId ~= -1 and scenetree.findObjectById(vehId)
  return veh and not isUnicycle(veh) and vehId or nil
end

local function switchSeat(player, direction)
  player = player or 0
  local vehId = getCurrentVehicleId(player)
  if not vehId then return false end

  local entries = getSeatEntries(vehId)
  if #entries == 0 then
    showVehicleFullMessage(player)
    return false
  end

  local driverSeatId = getDriverSeatId(vehId)
  table.sort(entries, function(a, b)
    local aIsDriver = a.seatId == driverSeatId
    local bIsDriver = b.seatId == driverSeatId
    if aIsDriver ~= bIsDriver then return aIsDriver end
    return a.seatId < b.seatId
  end)

  local currentSeatId = getPlayerSeat(player, vehId)
  if currentSeatId and not canPlayerLeaveSeat(player) then
    showSeatMessage(player, "ui.gameplay.seatOccupants.cannotSwitchSeats")
    return false
  end

  direction = direction and direction < 0 and -1 or 1
  local currentIndex = direction > 0 and 0 or (#entries + 1)
  for index, entry in ipairs(entries) do
    if entry.seatId == currentSeatId then
      currentIndex = index
      break
    end
  end

  for step = 1, #entries do
    local index = ((currentIndex - 1 + direction * step) % #entries) + 1
    local seatId = entries[index].seatId
    if seatId ~= currentSeatId and not seatUnavailable(vehId, seatId, player) then
      return requestEnterSeat(vehId, seatId, player)
    end
  end

  showVehicleFullMessage(player)
  return false
end

local function toggleUnseated(player)
  player = player or 0
  local vehId = getCurrentVehicleId(player)
  if not vehId then return false end

  local currentSeatId = getPlayerSeat(player, vehId)
  if currentSeatId then
    if not canPlayerLeaveSeat(player) then
      showSeatMessage(player, "ui.gameplay.seatOccupants.cannotSwitchSeats")
      return false
    end
    return requestUnseatedPresence(player, vehId)
  end

  local seatId, hasSeats = selectAvailableSeat(vehId, player)
  if not hasSeats or not seatId then
    showVehicleFullMessage(player)
    return false
  end
  return requestEnterSeat(vehId, seatId, player)
end

local function getSeats(vehId)
  local seats = {}
  local driverSeatId = getDriverSeatId(vehId)
  local occupiedSeats = occupancy[vehId] or {}
  local occupantPartPaths = {}
  local vehData = core_vehicle_manager.getVehicleData(vehId)
  local vdata = vehData and vehData.vdata
  local cargoStorage = vdata and vdata.cargoStorage or {}
  for _, container in pairs(cargoStorage) do
    if isPassengerOnly(container.cargoTypes) and isOccupantBoxPart(container) then
      local seatId = seatIdFromGroupId(container.groupId)
      if seatId then occupantPartPaths[seatId] = container.partPath end
    end
  end
  local parentPartPaths = {}
  local function collectParentPartPaths(node, parentPartPath)
    if not node then return end
    local partPath = node.partPath
    if partPath then parentPartPaths[partPath] = parentPartPath end
    for _, child in pairs(node.children or {}) do
      collectParentPartPaths(child, partPath or parentPartPath)
    end
  end
  collectParentPartPaths(vehData and vehData.config and vehData.config.partsTree)
  for _, entry in ipairs(getSeatEntries(vehId)) do
    local occ = occupiedSeats[entry.seatId]
    local presence = occ and occ.player ~= nil and playerPresence[occ.player] or nil
    seats[#seats + 1] = {
      seatId = entry.seatId,
      isDriver = entry.seatId == driverSeatId,
      occupied = occ ~= nil,
      occupantType = occ and (occ.dummy and "dummy" or "player") or nil,
      player = occ and occ.player or nil,
      weight = occ and occ.weight or nil,
      color = occ and occ.color and string.format("#%02X%02X%02X", occ.color.r, occ.color.g, occ.color.b) or nil,
      permissionMode = presence and presence.permissionMode or nil,
      displayName = entry.slot and entry.slot.displayName or nil,
      defaultPermissionMode = entry.slot and entry.slot.defaultPermissionMode or nil,
      cameraName = entry.slot and entry.slot.cameraName or nil,
      actionMaps = entry.slot and deepcopy(entry.slot.actionMaps or {}) or {},
      seatExitNode = entry.slot and entry.slot.exitNode or nil,
      seatExitSide = entry.slot and entry.slot.exitSide or nil,
      partPath = occupantPartPaths[entry.seatId],
      seatPartPath = parentPartPaths[occupantPartPaths[entry.seatId]],
    }
  end
  return seats
end

local function getVehiclePresences(vehId)
  local presences = {}
  for player, presence in pairs(playerPresence) do
    if presence.vehicleId == vehId then
      presences[#presences + 1] = {
        player = player,
        seatId = presence.seatId,
        permissionMode = presence.permissionMode,
        unseated = presence.seatId == nil,
      }
    end
  end
  table.sort(presences, function(a, b) return a.player < b.player end)
  return presences
end

-- lowest player index allowed to drive the vehicle, or nil if only passengers are present
local function getDriverPlayer(vehId)
  local driver
  for player, presence in pairs(playerPresence) do
    if presence.vehicleId == vehId
        and (presence.permissionMode == "driver" or presence.permissionMode == "unrestricted")
        and (not driver or player < driver) then
      driver = player
    end
  end
  return driver
end

local function setDummyOccupant(vehId, seatId, weight)
  local veh = scenetree.findObjectById(vehId)
  if not veh or isUnicycle(veh) then return false, "invalidVehicle" end
  if not getSeatEntry(vehId, seatId) then return false, "invalidSeat" end

  local occ = occupancy[vehId] and occupancy[vehId][seatId]
  if occ and not occ.dummy then return false, "occupied" end
  if seatReservedByOther(vehId, seatId, nil) then return false, "reserved" end

  occupancy[vehId] = occupancy[vehId] or {}
  local color = occ and occ.color or randomDummyColor()
  occupancy[vehId][seatId] = {
    kind = "dummy",
    dummy = true,
    weight = math.max(minWeight, tonumber(weight) or defaultWeight),
    color = color,
  }
  applyVehicle(vehId)
  syncDriving()
  return true
end

local function clearDummyOccupant(vehId, seatId)
  local seats = occupancy[vehId]
  local occ = seats and seats[seatId]
  if not occ or not occ.dummy then return false, "notDummy" end

  seats[seatId] = nil
  if not next(seats) then occupancy[vehId] = nil end
  applyVehicle(vehId)
  syncDriving()
  return true
end

local function clearDummyOccupants(vehId)
  local changedVehicles = {}
  local vehicleIds = {}
  if vehId ~= nil then
    vehicleIds[1] = vehId
  else
    for currentVehId in pairs(occupancy) do
      vehicleIds[#vehicleIds + 1] = currentVehId
    end
  end

  local clearedCount = 0
  for _, currentVehId in ipairs(vehicleIds) do
    local seats = occupancy[currentVehId]
    if seats then
      for seatId, occ in pairs(seats) do
        if occ.dummy then
          seats[seatId] = nil
          changedVehicles[currentVehId] = true
          clearedCount = clearedCount + 1
        end
      end
      if not next(seats) then occupancy[currentVehId] = nil end
    end
  end
  for currentVehId in pairs(changedVehicles) do
    applyVehicle(currentVehId)
  end
  if next(changedVehicles) then syncDriving() end
  return clearedCount
end

local function adjustOccupantWeights(vehId, delta, foodTranslationId)
  vehId = tonumber(vehId) or (be and be:getPlayerVehicleID(0))
  if not vehId or vehId == -1 then return nil end

  local seats = occupancy[vehId]
  if not seats then return nil end

  local displayedWeight
  for _, occupant in pairs(seats) do
    occupant.weight = clamp(
      (tonumber(occupant.weight) or defaultWeight) + delta,
      defaultWeight - 40,
      defaultWeight + 30
    )
    displayedWeight = displayedWeight or occupant.weight
  end
  if not displayedWeight then return nil end

  applyVehicle(vehId)
  guihooks.trigger("Message", {
    msg = core_locales.contextTranslate("ui.gameplay.seatOccupants.weightChanged", {
      food = foodTranslationId,
      weight = ui_vehicleSelector_vehicleSpecifications.valueToUnit.weight(displayedWeight),
    }),
    ttl = 3,
    category = "seatOccupantWeight",
    icon = "info",
  })
  return displayedWeight
end

local function cheeseburger(vehId)
  return adjustOccupantWeights(vehId, 10, "ui.gameplay.seatOccupants.cheeseburger")
end

local function salad(vehId)
  return adjustOccupantWeights(vehId, -10, "ui.gameplay.seatOccupants.salad")
end

local function getNodeWorldPosition(vehId, nodeRef)
  if nodeRef == nil then return nil end
  local veh = scenetree.findObjectById(vehId)
  local vehData = core_vehicle_manager.getVehicleData(vehId)
  local nodes = vehData and vehData.vdata and vehData.vdata.nodes
  if not veh or not nodes then return nil end

  local nodeRefNumber = tonumber(nodeRef)
  for nodeId, node in pairs(nodes) do
    if node.name == nodeRef or node.cid == nodeRefNumber or nodeId == nodeRef then
      return veh:getPosition() + veh:getNodePosition(node.cid or nodeId)
    end
  end
end

local function getSeatExitData(player, vehId)
  player = player or 0
  vehId = vehId or (be and be:getPlayerVehicleID(player))
  if not vehId or vehId == -1 or not be:getObjectOOBBIsInitialized(vehId) then return nil end

  local seatId = getPlayerSeat(player, vehId)
  local entry = seatId and getSeatEntry(vehId, seatId)
  if not entry or not entry.position then return nil end

  local exitNode = entry.slot and entry.slot.exitNode
  local exitNodePosition = getNodeWorldPosition(vehId, exitNode)
  local exitAnchor = exitNodePosition or entry.position
  local center = vec3(be:getObjectOOBBCenterXYZ(vehId))
  local lateralHalfAxis = vec3(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
  local halfWidth = lateralHalfAxis:length()
  if halfWidth < 1e-6 then return nil end
  local lateralAxis = lateralHalfAxis / halfWidth
  local lateralOffset = (exitAnchor - center):dot(lateralAxis)

  local exitSideValue = entry.slot and entry.slot.exitSide
  local exitSide = type(exitSideValue) == "string" and exitSideValue:lower() or nil
  local sideSign
  if exitNodePosition and math.abs(lateralOffset) > 1e-4 then
    sideSign = lateralOffset > 0 and 1 or -1
  elseif exitSide == "left" or exitSide == "l" then
    sideSign = 1
  elseif exitSide == "right" or exitSide == "r" then
    sideSign = -1
  elseif math.abs(lateralOffset) > 1e-4 then
    sideSign = lateralOffset > 0 and 1 or -1
  else
    sideSign = seatId:match("R$") and -1 or 1
  end

  local outwardDistance = sideSign * lateralOffset
  local exitOffset = math.max(0, halfWidth + seatExitMargin - outwardDistance)
  local exitPos = exitAnchor + lateralAxis * sideSign * exitOffset
  return exitPos, entry.position
end

local function ejectSeatOccupant(vehId, seatId, player)
  local sourceVeh = scenetree.findObjectById(vehId)
  if not sourceVeh or be:getPlayerVehicleID(player) ~= vehId
      or not gameplay_walk or not gameplay_walk.setWalkingMode then
    log("W", "seatOccupants", string.format(
      "Could not eject player %s from seat %q in vehicle %s",
      tostring(player),
      tostring(seatId),
      tostring(vehId)
    ))
    return false
  end

  if gameplay_walk.setWalkingMode(true, nil, nil, true, player) ~= true then
    log("W", "seatOccupants", string.format(
      "Walking mode rejected ejection of player %s from vehicle %s",
      tostring(player),
      tostring(vehId)
    ))
    return false
  end

  local walkingVeh = be:getPlayerVehicle(player)
  if not walkingVeh or not isUnicycle(walkingVeh) then return false end

  local direction = walkingVeh:getPosition() - sourceVeh:getPosition()
  direction.z = 0
  if direction:squaredLength() < 1e-6 then
    direction:set(sourceVeh:getDirectionVector())
  end
  direction:normalize()
  direction = direction * 8
  direction.z = 4
  walkingVeh:applyClusterVelocityScaleAdd(walkingVeh:getRefNodeId(), 1, direction.x, direction.y, direction.z)
  return true
end

local function enterSeat(vehId, triggerId, player)
  --log('I', 'seatOccupants', 'Entering seat: ' .. dumps(triggerId) .. ' for player: ' .. dumps(player) .. ' for vehicle: ' .. dumps(vehId))
  player = player or 0
  if M.debugDisableOccupantSystem then
    if not isVehicleEnterable(vehId, player) then return false end
    return requestUnseatedPresence(player, vehId, "unrestricted")
  end
  local seatId = seatIdFromTrigger(vehId, triggerId)
  local occ = seatId and occupancy[vehId] and occupancy[vehId][seatId]
  if M.enableSeatEjection and occ and occ.player ~= nil and occ.player ~= player then
    return ejectSeatOccupant(vehId, seatId, occ.player)
  end
  return requestEnterSeat(vehId, seatId, player)
end

local function onVehicleSwitched(oldId, newId, player)
  player = player or 0
  occupyPlayerVehicle(player, newId, oldId)
end

local function reconcilePlayerVehicles()
  if not be then return end

  local removals = {}
  local seatedPlayers = {}
  for vehId, seats in pairs(occupancy) do
    for seatId, occ in pairs(seats) do
      if occ.player ~= nil then
        local currentVehId = be:getPlayerVehicleID(occ.player)
        local presence = playerPresence[occ.player]
        if currentVehId ~= vehId
            or not presence
            or presence.vehicleId ~= vehId
            or presence.seatId ~= seatId
            or seatedPlayers[occ.player] then
          removals[#removals + 1] = {vehId = vehId, seatId = seatId, player = occ.player}
        else
          seatedPlayers[occ.player] = true
        end
      end
    end
  end

  local changedVehicles = {}
  for _, removal in ipairs(removals) do
    local seats = occupancy[removal.vehId]
    if seats then
      local presence = playerPresence[removal.player]
      if presence and presence.vehicleId == removal.vehId and presence.seatId == removal.seatId then
        clearOccupantCameraVisibility(removal.player)
        releasePlayerSeat(removal.player, removal.vehId)
      end
      seats[removal.seatId] = nil
      if not next(seats) then occupancy[removal.vehId] = nil end
      changedVehicles[removal.vehId] = true
    end
  end

  local players = core_multiseat and core_multiseat.getPlayers and core_multiseat.getPlayers() or {0}
  if #players == 0 then players = {0} end
  for _, player in ipairs(players) do
    local vehId = be:getPlayerVehicleID(player)
    local veh = vehId and vehId ~= -1 and scenetree.findObjectById(vehId)
    if veh and not isUnicycle(veh) then
      local presence = playerPresence[player]
      if not presence or presence.vehicleId ~= vehId then
        clearOccupantCameraVisibility(player)
        presence = setPlayerPresence(player, vehId, nil, getDefaultUnseatedPermissionMode(player, vehId))
      end
      if presence.seatId then
        local claim = occupancy[vehId] and occupancy[vehId][presence.seatId]
        local claimValid = false
        if claim then
          claimValid = claim.player == player and getSeatEntry(vehId, presence.seatId) ~= nil
        end
        if not claimValid then
          if claim and claim.player == player then
            occupancy[vehId][presence.seatId] = nil
            if not next(occupancy[vehId]) then occupancy[vehId] = nil end
            changedVehicles[vehId] = true
          end
          presence = setPlayerPresence(
            player,
            vehId,
            nil,
            presence.permissionMode,
            presence.permissionOverride
          )
        end
      end
      if presence.seatId then
        syncOccupantCamera(player, vehId, presence.seatId)
      else
        syncUnseatedCameras(player, vehId)
      end
    else
      local presence = playerPresence[player]
      if presence then
        releasePlayerSeat(player, presence.vehicleId)
        setPlayerPresence(player, nil)
      end
      clearOccupantCameraVisibility(player)
    end
  end

  for vehId in pairs(changedVehicles) do
    applyVehicle(vehId)
  end
  if next(changedVehicles) then syncDriving() end
end

local function applyAllVehicles(visualsOnly, force)
  for _, veh in ipairs(getAllVehicles()) do
    local vehId = veh:getId()
    if force then
      lastVolumes[vehId] = nil
    end
    applyVehicle(vehId, visualsOnly, force)
  end
end

local function setVehicleOccupantsEnabledOverride(vehId, enabled)
  vehId = tonumber(vehId)
  if not vehId or not scenetree.findObjectById(vehId) then return false end
  if enabled ~= nil then enabled = enabled == true end
  if vehicleOccupantsEnabledOverride[vehId] == enabled then return true end

  vehicleOccupantsEnabledOverride[vehId] = enabled
  lastVolumes[vehId] = nil
  applyVehicle(vehId, false, true)
  return true
end

local function applyDebugLegacyState()
  if not M.debugDisableOccupantSystem then return false end
  seatTransitions = {}
  occupancy = {}
  knownSeatsByVehicle = {}
  vehicleConfigurationChanged = {}
  for player, presence in pairs(playerPresence) do
    clearOccupantCameraVisibility(player)
    setPlayerPresence(player, presence.vehicleId, nil, "unrestricted")
  end
  reconcilePlayerVehicles()
  applyAllVehicles(false, true)
  syncDriving()
  return true
end

local function onSettingsChanged()
  applyAllVehicles(true)
end

local function onSplitScreenChanged()
  reconcilePlayerVehicles()
  applyAllVehicles(true)
  syncDriving()
end

local function onCameraChanged(player, camName, vid)
  player = player or 0
  local camVeh = vid and scenetree.findObjectById(vid)
  if camVeh and isUnicycle(camVeh) then return end
  local currentVid = be:getPlayerVehicleID(player)
  if currentVid and currentVid ~= -1 then
    if occupancy[currentVid] then applyVehicle(currentVid, true) end
    local presence = playerPresence[player]
    if presence and presence.vehicleId == currentVid then syncPresenceCameras(player) end
  end
end

local function trySeatUnseatedPlayers(vehId)
  if not usesSeatSystem(vehId) then return false end

  local players = {}
  for player, presence in pairs(playerPresence) do
    if presence.vehicleId == vehId and not presence.seatId
        and be:getPlayerVehicleID(player) == vehId then
      players[#players + 1] = player
    end
  end
  table.sort(players)
  for _, player in ipairs(players) do
    requestEnterBestSeat(vehId, player)
  end

  local hasPresence = false
  for _, presence in pairs(playerPresence) do
    if presence.vehicleId == vehId then
      hasPresence = true
      if not presence.seatId then return false end
    end
  end
  return hasPresence
end

local function onVehicleSpawned(vehId)
  lastVolumes[vehId] = nil
  if occupancy[vehId] then
    vehicleConfigurationChanged[vehId] = true
  else
    knownSeatsByVehicle[vehId] = nil
    vehicleConfigurationChanged[vehId] = nil
  end
  if seatlessVehicleBeforeReplacement[vehId] and trySeatUnseatedPlayers(vehId) then
    seatlessVehicleBeforeReplacement[vehId] = nil
  end
  applyVehicle(vehId, false, true)
  syncVehiclePresenceCameras(vehId)
  syncDrivingForVehicle(vehId, true)
end

local function onBeforeVehicleReplaced(vehId)
  seatlessVehicleBeforeReplacement[vehId] = not usesSeatSystem(vehId)
end

local function onVehicleReplaced(vehId)
  lastVolumes[vehId] = nil
  vehicleConfigurationChanged[vehId] = true

  if seatlessVehicleBeforeReplacement[vehId] and trySeatUnseatedPlayers(vehId) then
    seatlessVehicleBeforeReplacement[vehId] = nil
  end

  applyVehicle(vehId, false, true)
  syncVehiclePresenceCameras(vehId)
  syncDrivingForVehicle(vehId, true)
end

local function onVehicleResetted(vehId)
  lastVolumes[vehId] = nil
  applyVehicle(vehId, false, true)
  syncVehiclePresenceCameras(vehId)
  syncDrivingForVehicle(vehId)
end

local function onVehicleDestroyed(vehId)
  for player, transition in pairs(seatTransitions) do
    if transition.vehId == vehId then
      seatTransitions[player] = nil
    end
  end
  for _, occ in pairs(occupancy[vehId] or {}) do
    if occ.player ~= nil then clearOccupantCameraVisibility(occ.player) end
  end
  local presencePlayers = {}
  for player, presence in pairs(playerPresence) do
    if presence.vehicleId == vehId then presencePlayers[#presencePlayers + 1] = player end
  end
  for _, player in ipairs(presencePlayers) do
    clearOccupantCameraVisibility(player)
    setPlayerPresence(player, nil)
  end
  occupancy[vehId] = nil
  lastVolumes[vehId] = nil
  drivingPlayerByVehicle[vehId] = nil
  knownSeatsByVehicle[vehId] = nil
  vehicleConfigurationChanged[vehId] = nil
  vehicleOccupantsEnabledOverride[vehId] = nil
  seatlessVehicleBeforeReplacement[vehId] = nil
  syncDriving()
end

local function occupyExistingPlayers()
  if not be then return end
  occupyPlayerVehicle(0, be:getPlayerVehicleID(0))
end

local function onClientStartMission()
  vehicleOccupantsEnabledOverride = {}
  occupyExistingPlayers()
end

local function onLocalParticipantsChanged()
  reconcilePlayerVehicles()
  for vehId in pairs(occupancy) do
    applyVehicle(vehId, true)
  end
  syncDriving()
end

local function onBeforeWalkingModeToggled(enabled, _, player)
  if not enabled then return end
  drivingBlocked[player or 0] = false
  applyDrivingActionMapMask()
end

local function restoreSerializedState(data)
  occupancy = {}
  playerPresence = {}
  if type(data) ~= "table" then return false end

  if data.version == serializationVersion and type(data.seatClaims) == "table" then
    occupancy = data.seatClaims
    local serializedPresence = type(data.playerPresence) == "table" and data.playerPresence or {}
    playerPresence = {}
    for _, seats in pairs(occupancy) do
      for _, claim in pairs(seats) do
        if claim.kind == "player" then
          claim.player = claim.player ~= nil and claim.player or claim.playerId
          claim.playerId = claim.player
        elseif claim.kind == "dummy" then
          claim.dummy = true
          claim.color = claim.color or randomDummyColor()
        end
      end
    end
    for player, presence in pairs(serializedPresence) do
      local playerId = tonumber(player) or player
      presence.permissionMode = normalizePermissionMode(
        presence.permissionOverride or presence.permissionMode,
        getDefaultUnseatedPermissionMode(playerId, presence.vehicleId)
      )
      playerPresence[playerId] = presence
    end
    return true
  end

  if type(data.occupancy) == "table" then
    occupancy = data.occupancy
    for vehId, seats in pairs(occupancy) do
      for seatId, claim in pairs(seats) do
        if claim.dummy then
          claim.kind = "dummy"
          claim.color = claim.color or randomDummyColor()
        elseif claim.player ~= nil then
          claim.kind = "player"
          claim.playerId = claim.player
          local mode = getSeatPermissionMode(vehId, seatId)
          playerPresence[claim.player] = {
            vehicleId = vehId,
            seatId = seatId,
            permissionMode = mode,
          }
        end
      end
    end
    return true
  end
  return false
end

local function onExtensionLoaded(data)
  seatTransitions = {}
  drivingPlayerByVehicle = {}
  knownSeatsByVehicle = {}
  vehicleConfigurationChanged = {}
  vehicleOccupantsEnabledOverride = {}
  if restoreSerializedState(data) then return end
  occupyExistingPlayers()
  if applyDebugLegacyState() then return end
  reconcilePlayerVehicles()
  syncDriving()
end

local function onExtensionUnloaded()
  for vehId in pairs(vehicleOccupantsEnabledOverride) do
    setVehicleOccupantsEnabledOverride(vehId, nil)
  end
  local players = {}
  for player in pairs(visibleOccupantCameraByPlayer) do players[#players + 1] = player end
  for _, player in ipairs(players) do clearOccupantCameraVisibility(player) end
  core_input_actionFilter.clearActionMapPlayerMasks(drivingActionMapMaskOwner)
end

local function onSerialize()
  return {
    version = serializationVersion,
    playerPresence = playerPresence,
    seatClaims = occupancy,
    occupancy = occupancy,
  }
end

local function onDeserialized(data)
  seatTransitions = {}
  drivingPlayerByVehicle = {}
  knownSeatsByVehicle = {}
  vehicleConfigurationChanged = {}
  vehicleOccupantsEnabledOverride = {}
  restoreSerializedState(data)
  if applyDebugLegacyState() then return end
  reconcilePlayerVehicles()
  syncDriving()
  for vehId in pairs(occupancy) do
    applyVehicle(vehId)
  end
end

M.setOccupied = setOccupied
M.clearOccupied = clearOccupied
M.enterSeat = enterSeat
M.requestEnterSeat = requestEnterSeat
M.requestEnterBestSeat = requestEnterBestSeat
M.requestUnseatedPresence = requestUnseatedPresence
M.switchSeat = switchSeat
M.toggleUnseated = toggleUnseated
M.getPlayerPresence = getPlayerPresence
M.setPlayerPermissionMode = setPlayerPermissionMode
M.getSeats = getSeats
M.getVehiclePresences = getVehiclePresences
M.getDriverPlayer = getDriverPlayer
M.usesSeatSystem = usesSeatSystem
M.getOccupantSystemVersion = getOccupantSystemVersion
M.setDummyOccupant = setDummyOccupant
M.clearDummyOccupant = clearDummyOccupant
M.clearDummyOccupants = clearDummyOccupants
M.cheeseburger = cheeseburger
M.salad = salad
M.setVehicleOccupantsEnabledOverride = setVehicleOccupantsEnabledOverride
M.refreshOccupantMeshes = refreshOccupantMeshes
M.canEnterVehicle = canEnterVehicle
M.showVehicleFullMessage = showVehicleFullMessage
M.getSeatExitData = getSeatExitData
M.onVehicleSwitched = onVehicleSwitched
M.onCameraChanged = onCameraChanged
M.onSettingsChanged = onSettingsChanged
M.onSplitScreenChanged = onSplitScreenChanged
M.onVehicleSpawned = onVehicleSpawned
M.onBeforeVehicleReplaced = onBeforeVehicleReplaced
M.onVehicleReplaced = onVehicleReplaced
M.onVehicleResetted = onVehicleResetted
M.onVehicleDestroyed = onVehicleDestroyed
M.onClientStartMission = onClientStartMission
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onLocalParticipantsChanged = onLocalParticipantsChanged
M.onBeforeWalkingModeToggled = onBeforeWalkingModeToggled
M.onVehicleTriggerActionLabel = onVehicleTriggerActionLabel
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M
