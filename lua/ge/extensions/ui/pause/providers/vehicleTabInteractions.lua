-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'core_vehicleBridge', 'core_locales'}

local buttonModule = require("ge/extensions/ui/gridSelectorUtils/buttonModule")
local buttonInstance = buttonModule.create()
local actionButtonsByVehicleId = {}
local vehicleDisplayNumberById = {}
local getSelectedSpawnedActionGroups
local getSelectedSpawnedActionGroupShell
local makeActionEntry
local buildVehicleControllerUiElements
local isWalkingCharacterVehicle
local hoveredVehicleId = nil
local selectedSpawnedVehicleId = nil
local pauseVehicleInteractionsActive = false
local vehicleStateById = {}
local spawnedVehicleOrder = {}
local spawnedVehicleOrderById = {}
local nextVehicleDisplayNumber = 1
local vehicleStateStreamName = "ui_pause_vehicleTabInteractions_vehicle_state"
local spawnedPayloadStreamName = "ui_pause_vehicleTabInteractions_spawned_payload"
local spawnedSelectedPayloadStreamName = "ui_pause_vehicleTabInteractions_spawned_selected_payload"
local aiModePollIntervalSec = 8
local aiModePollTimer = 0
local aiModeBatchId = 0
local aiModeBatchPending = 0
local inactiveVehicleCount = 0
local unusableVehicleCount = 0
-- Debug-only artificial delay for PoC async hydration state review.
local asyncHydrationDebugDelaySec = 0
local delayedAsyncHydrationRequests = {}

local function normalizeAiMode(aiMode)
  if type(aiMode) ~= "string" or aiMode == "" or aiMode == "disabled" then return "none" end
  return aiMode
end

local aiModeTranslationKeyByMode = {
  mixed = "ui.pause.vehicle.aiMode.mixed",
  none = "ui.pause.vehicle.aiMode.none",
  traffic = "ui.pause.vehicle.aiMode.traffic",
  chase = "ui.pause.vehicle.aiMode.chase",
  flee = "ui.pause.vehicle.aiMode.flee",
  follow = "ui.pause.vehicle.aiMode.follow",
  random = "ui.pause.vehicle.aiMode.random",
}

local function getAiModeTranslationKey(aiMode)
  return aiModeTranslationKeyByMode[normalizeAiMode(aiMode)]
end

local function getAiModeLabel(aiMode)
  local translationKey = getAiModeTranslationKey(aiMode)
  return translationKey and _tr(translationKey) or normalizeAiMode(aiMode)
end

local function contextTranslate(key, vars)
  return core_locales.contextTranslate(key, vars or {})
end

local function getAiModeSetterLabel(aiMode)
  return contextTranslate("ui.pause.vehicle.aiModeSetter", {
    mode = getAiModeTranslationKey(aiMode) or normalizeAiMode(aiMode),
  })
end

local function getVehicleFallbackName(vehicleId)
  return contextTranslate("ui.pause.vehicle.fallbackName", {id = tostring(vehicleId)})
end

local spawnedAiModeOptions = {
  { value = "mixed", label = getAiModeLabel("mixed") },
  { value = "none", label = getAiModeLabel("none") },
  { value = "traffic", label = getAiModeLabel("traffic") },
  { value = "chase", label = getAiModeLabel("chase") },
  { value = "flee", label = getAiModeLabel("flee") },
  { value = "follow", label = getAiModeLabel("follow") },
  { value = "random", label = getAiModeLabel("random") },
}

local function getCurrentRouteName()
  local currentRoute = ui_router and ui_router.getCurrent and ui_router.getCurrent() or nil
  local request = currentRoute and currentRoute.request or nil
  return request and request.name or nil
end

local function isVehiclePauseRoute(routeName)
  if type(routeName) ~= "string" then return false end
  return routeName:find("^pause%.vehicle") == 1 or routeName:find("^pause%.manageVehicles") == 1
end

local function isSpawnedVehiclePauseRoute(routeName)
  if type(routeName) ~= "string" then return false end
  return routeName == "pause.vehicle" or routeName:find("^pause%.manageVehicles") == 1
end

local function isVehicleAiPollingRoute(routeName)
  if isSpawnedVehiclePauseRoute(routeName) then return true end
  return routeName == "pause" or routeName == "pause.vehicleDetails"
end

local function isPauseFamilyRoute(routeName)
  return type(routeName) == "string" and (routeName == "pause" or routeName:find("^pause%.") == 1)
end

local function isVehicleHighlightRoute(routeName)
  return routeName == "pause" or isVehiclePauseRoute(routeName)
end

local function resetVehicleDisplayNumbers()
  table.clear(vehicleDisplayNumberById)
  nextVehicleDisplayNumber = 1
end

local function resetSpawnedVehicleOrder()
  table.clear(spawnedVehicleOrder)
  table.clear(spawnedVehicleOrderById)
end

local function rebuildSpawnedVehicleOrderIndex()
  table.clear(spawnedVehicleOrderById)
  for index, vehicleId in ipairs(spawnedVehicleOrder) do
    spawnedVehicleOrderById[vehicleId] = index
  end
end

local function getCameraPosition()
  if core_camera and core_camera.getPosition then
    return core_camera.getPosition()
  end
  return nil
end

local function getDistanceToCameraSq(cameraPos, veh)
  if not cameraPos or not veh or not veh.getPosition then return math.huge end
  local vehiclePos = veh:getPosition()
  if not vehiclePos then return math.huge end
  local delta = vehiclePos - cameraPos
  if not delta or not delta.length then return math.huge end
  local distance = delta:length()
  return distance * distance
end

local function getOrderedSpawnedVehicleIds(activeVehiclesById, activeVehicleIds, currentVehicleId)
  if #spawnedVehicleOrder == 0 then
    local cameraPos = getCameraPosition()
    table.sort(activeVehicleIds, function(a, b)
      if a == currentVehicleId then return true end
      if b == currentVehicleId then return false end
      local vehA = activeVehiclesById[a]
      local vehB = activeVehiclesById[b]
      local distA = getDistanceToCameraSq(cameraPos, vehA)
      local distB = getDistanceToCameraSq(cameraPos, vehB)
      if distA ~= distB then return distA < distB end
      return a < b
    end)
    for _, vehicleId in ipairs(activeVehicleIds) do
      table.insert(spawnedVehicleOrder, vehicleId)
    end
    rebuildSpawnedVehicleOrderIndex()
    return spawnedVehicleOrder
  end

  local activeById = {}
  for _, vehicleId in ipairs(activeVehicleIds) do
    activeById[vehicleId] = true
  end

  for index = #spawnedVehicleOrder, 1, -1 do
    local vehicleId = spawnedVehicleOrder[index]
    if not activeById[vehicleId] then
      table.remove(spawnedVehicleOrder, index)
    end
  end
  rebuildSpawnedVehicleOrderIndex()

  for _, vehicleId in ipairs(activeVehicleIds) do
    if not spawnedVehicleOrderById[vehicleId] then
      table.insert(spawnedVehicleOrder, vehicleId)
      spawnedVehicleOrderById[vehicleId] = #spawnedVehicleOrder
    end
  end

  return spawnedVehicleOrder
end

local function getVehicleDisplayNumber(vehicleId)
  if type(vehicleId) ~= "number" then return nil end
  local displayNumber = vehicleDisplayNumberById[vehicleId]
  if displayNumber then return displayNumber end

  displayNumber = nextVehicleDisplayNumber
  vehicleDisplayNumberById[vehicleId] = displayNumber
  nextVehicleDisplayNumber = nextVehicleDisplayNumber + 1
  return displayNumber
end

local function getVehicleDisplayLabelParts(vehicleId, rawName)
  local displayNumber = getVehicleDisplayNumber(vehicleId)
  local displayNumberLabel = displayNumber and (tostring(displayNumber) .. ".") or nil
  local labelName = tostring(rawName or "")
  local label = displayNumberLabel and (displayNumberLabel .. " " .. labelName) or labelName
  return displayNumber, displayNumberLabel, label
end

local function resetHiddenVehicleCounts()
  inactiveVehicleCount = 0
  unusableVehicleCount = 0
end

local function getVehicleTabExclusionReason(veh)
  if not veh or isWalkingCharacterVehicle(veh) then return "ignored" end
  if not veh.getActive or veh:getActive() ~= true then return "inactive" end
  if veh.playerUsable ~= true then return "unusable" end
  return nil
end

local function isVehicleTabVehicle(veh)
  return getVehicleTabExclusionReason(veh) == nil
end

local function collectVehicleTabVehicles()
  resetHiddenVehicleCounts()
  local vehicles = {}
  if not be or be:getObjectCount() == 0 then return vehicles end

  for i = 0, be:getObjectCount() - 1 do
    local veh = be:getObject(i)
    local exclusionReason = getVehicleTabExclusionReason(veh)
    if exclusionReason == "inactive" then
      inactiveVehicleCount = inactiveVehicleCount + 1
    elseif exclusionReason == "unusable" then
      unusableVehicleCount = unusableVehicleCount + 1
    elseif not exclusionReason then
      table.insert(vehicles, veh)
    end
  end

  return vehicles
end

local function ensureVehicleDisplayNumbersForCurrentList()
  if not be then return end
  for _, veh in ipairs(collectVehicleTabVehicles()) do
    getVehicleDisplayNumber(veh:getId())
  end
end

local function setPauseVehicleInteractionsActive(routeName)
  if not isPauseFamilyRoute(routeName) then
    resetVehicleDisplayNumbers()
    resetSpawnedVehicleOrder()
  end
  pauseVehicleInteractionsActive = isVehicleHighlightRoute(routeName)
  if pauseVehicleInteractionsActive then return end
  hoveredVehicleId = nil
  aiModePollTimer = 0
end

local function isAiControlled(aiMode)
  if type(aiMode) ~= "string" or aiMode == "" then return false end
  return aiMode ~= "disabled" and aiMode ~= "none"
end

local function getLocalPlayerIds()
  local out = {}
  local seen = {}
  local assignedPlayers = core_input_bindings and core_input_bindings.getAssignedPlayers and core_input_bindings.getAssignedPlayers() or {}
  for _, playerNumId in pairs(assignedPlayers) do
    if type(playerNumId) == "number" and not seen[playerNumId] then
      seen[playerNumId] = true
      table.insert(out, playerNumId)
    end
  end
  if #out == 0 then
    table.insert(out, 0)
  end
  table.sort(out)
  return out
end

local function isMultiSeatLocalPlayers()
  return #getLocalPlayerIds() > 1
end

local function getVehicleControllersByVehicleId()
  local byVehicleId = {}
  for _, playerNumId in ipairs(getLocalPlayerIds()) do
    local vehicleId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(playerNumId) or nil
    if vehicleId and vehicleId >= 0 then
      byVehicleId[vehicleId] = byVehicleId[vehicleId] or {}
      table.insert(byVehicleId[vehicleId], playerNumId)
    end
  end
  for _, playerNums in pairs(byVehicleId) do
    table.sort(playerNums)
  end
  return byVehicleId
end

local function getOnlineControlledVehicleIds()
  local byVehicleId = {}
  if not multiplayer_sessionManager or not multiplayer_vehicleSync or not multiplayer_multiplayer then return byVehicleId end
  if not multiplayer_sessionManager.getSessionPlayers or not multiplayer_vehicleSync.mIdToVId or not multiplayer_multiplayer.getLocalClientId then return byVehicleId end

  local localClientId = multiplayer_multiplayer.getLocalClientId()
  local sessionPlayers = multiplayer_sessionManager.getSessionPlayers() or {}
  for _, sessionPlayer in pairs(sessionPlayers) do
    if sessionPlayer and sessionPlayer.activeVehicleMId and sessionPlayer.clientId ~= localClientId then
      local vehicleId = multiplayer_vehicleSync.mIdToVId(sessionPlayer.activeVehicleMId)
      if vehicleId and vehicleId >= 0 then
        byVehicleId[vehicleId] = true
      end
    end
  end
  return byVehicleId
end

local function getVehicleControllerType(vehicleId)
  local controllersByVehicleId = getVehicleControllersByVehicleId()
  return (controllersByVehicleId[vehicleId] and #controllersByVehicleId[vehicleId] > 0) and "player" or "none"
end

local function collectVehicleControllerTypes()
  local activeVehicleIds = {}
  local controllersByVehicleId = getVehicleControllersByVehicleId()
  local onlineControlledVehicleIds = getOnlineControlledVehicleIds()
  local multiSeatLocal = isMultiSeatLocalPlayers()
  if be then
    for _, veh in ipairs(collectVehicleTabVehicles()) do
      local vehicleId = veh:getId()
      activeVehicleIds[vehicleId] = true
      local state = vehicleStateById[vehicleId] or {}
      state.controllingPlayerNums = controllersByVehicleId[vehicleId] or {}
      state.controllerType = (#state.controllingPlayerNums > 0) and "player" or "none"
      state.multiSeatLocal = multiSeatLocal
      state.onlineControlled = onlineControlledVehicleIds[vehicleId] == true
      state.aiControlled = isAiControlled(state.aiMode)
      vehicleStateById[vehicleId] = state
    end
  end

  for vehicleId, _ in pairs(vehicleStateById) do
    if not activeVehicleIds[vehicleId] then
      vehicleStateById[vehicleId] = nil
    end
  end
end

local function emitVehicleStateStream()
  local streamData = {}
  local currentVehicleId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or nil
  for vehicleId, state in pairs(vehicleStateById) do
    local isCurrent = vehicleId == currentVehicleId
    table.insert(streamData, {
      vehicleId = vehicleId,
      controllerType = state.controllerType or "none",
      controllingPlayerNums = state.controllingPlayerNums or {},
      multiSeatLocal = state.multiSeatLocal == true,
      onlineControlled = state.onlineControlled == true,
      aiMode = state.aiMode,
      aiControlled = state.aiControlled == true,
      controllerUiElements = buildVehicleControllerUiElements(state, isCurrent),
    })
  end
  guihooks.triggerStream(vehicleStateStreamName, streamData)
end

local function finishAiModeBatch(batchId)
  if batchId ~= aiModeBatchId then return end
  aiModeBatchPending = math.max(0, aiModeBatchPending - 1)
  if aiModeBatchPending > 0 then return end
  if pauseVehicleInteractionsActive and isVehicleHighlightRoute(getCurrentRouteName()) then
    emitVehicleStateStream()
  end
end

local function resetVehicleState()
  table.clear(vehicleStateById)
end

local function requestAiModeForVehicle(veh, batchId)
  if not veh or not core_vehicleBridge or not core_vehicleBridge.requestValue then return end
  local vehicleId = veh:getId()
  core_vehicleBridge.requestValue(veh, function(data)
    local state = vehicleStateById[vehicleId] or {}
    local controllersByVehicleId = getVehicleControllersByVehicleId()
    local onlineControlledVehicleIds = getOnlineControlledVehicleIds()
    state.controllingPlayerNums = controllersByVehicleId[vehicleId] or {}
    state.controllerType = (#state.controllingPlayerNums > 0) and "player" or "none"
    state.multiSeatLocal = isMultiSeatLocalPlayers()
    state.onlineControlled = onlineControlledVehicleIds[vehicleId] == true
    if type(data) == "table" then
      state.aiMode = data.aiMode
    else
      state.aiMode = nil
    end
    state.aiControlled = isAiControlled(state.aiMode)
    vehicleStateById[vehicleId] = state
    if batchId then
      finishAiModeBatch(batchId)
    elseif pauseVehicleInteractionsActive and isVehicleHighlightRoute(getCurrentRouteName()) then
      emitVehicleStateStream()
    end
  end, "aiMode")
  return true
end

local function requestAiModesForAllVehicles()
  if not pauseVehicleInteractionsActive then return end
  if not be then return end
  local vehicles = collectVehicleTabVehicles()
  aiModeBatchId = aiModeBatchId + 1
  aiModeBatchPending = #vehicles
  if aiModeBatchPending == 0 then
    emitVehicleStateStream()
    return
  end
  local batchId = aiModeBatchId
  for _, veh in ipairs(vehicles) do
    if not requestAiModeForVehicle(veh, batchId) then
      finishAiModeBatch(batchId)
    end
  end
end

local function emitVehicleStateForCurrentList()
  collectVehicleControllerTypes()
  emitVehicleStateStream()
end

local function emitVehiclePauseRouteData()
  local routeName = getCurrentRouteName()
  if not pauseVehicleInteractionsActive then return false end
  if not isVehicleHighlightRoute(routeName) then return false end
  resetVehicleState()
  emitVehicleStateForCurrentList()
  aiModePollTimer = 0
  if isSpawnedVehiclePauseRoute(routeName) then
    requestAiModesForAllVehicles()
  end
  return true
end

local function setHoveredVehicleId(vehicleId)
  hoveredVehicleId = tonumber(vehicleId)
end

local function clearHoveredVehicleId(vehicleId)
  local id = tonumber(vehicleId)
  if not hoveredVehicleId then return end
  if id == nil or hoveredVehicleId == id then
    hoveredVehicleId = nil
  end
end

local function getHighlightVehicleId()
  if hoveredVehicleId then return hoveredVehicleId end
  local routeName = getCurrentRouteName()
  if routeName == "pause.vehicleDetails" or routeName == "pause.vehicle.vehicleDetails" or routeName == "pause.manageVehicles.vehicleDetails" then
    local selectedId = tonumber(selectedSpawnedVehicleId)
    if selectedId and selectedId >= 0 then return selectedId end
  end
  return nil
end

local function clearTrackedVehicleId(vehicleId)
  if hoveredVehicleId == vehicleId then hoveredVehicleId = nil end
end

local function canModifyVehicles()
  if not be or be:getObjectCount() == 0 then return false end
  if not getPlayerVehicle or not getPlayerVehicle(0) then return false end
  if core_input_actionFilter.isActionBlocked("switch_next_vehicle") or core_input_actionFilter.isActionBlocked("switch_previous_vehicle") then return false end
  return true
end

local function canSwitchVehicles()
  if not canModifyVehicles() then return false end
  if core_input_actionFilter and core_input_actionFilter.isActionBlocked then
    local canSwitch = not core_input_actionFilter.isActionBlocked("switch_next_vehicle") and not core_input_actionFilter.isActionBlocked("switch_previous_vehicle")
    if not canSwitch then return false end
  end
  return true
end

local function canExitVehicle()
  if not gameplay_walk or not gameplay_walk.isTogglingEnabled then return false end
  if not gameplay_walk.isTogglingEnabled() then return false end
  if gameplay_walk.isWalking and gameplay_walk.isWalking() then return false end
  if core_input_actionFilter and core_input_actionFilter.isActionBlocked and core_input_actionFilter.isActionBlocked("toggleWalkingMode") then
    return false
  end
  if gameplay_walk.isAtParkingSpeed and not gameplay_walk.isAtParkingSpeed() then
    return false
  end
  return true
end

local function canUseVehicleAiModes()
  if not getPlayerVehicle or not getPlayerVehicle(0) then return false end
  if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then
    return false
  end
  if core_input_actionFilter and core_input_actionFilter.isActionBlocked and core_input_actionFilter.isActionBlocked("toggleAITraffic") then
    return false
  end
  return true
end

local function isSpawningTutorialActive()
  return gameplay_discover_freeroamTutorial_tutorial and gameplay_discover_freeroamTutorial_tutorial.getActivePhase and gameplay_discover_freeroamTutorial_tutorial.getActivePhase() == "vehicleManagementSpawn"
end

local function getVehicleObjectById(vehicleId)
  if not vehicleId then return nil end
  if scenetree and scenetree.findObjectById then
    return scenetree.findObjectById(vehicleId)
  end
  return getObjectByID(vehicleId)
end

local function getVehicleTabObjectById(vehicleId)
  local vehicle = getVehicleObjectById(vehicleId)
  if not isVehicleTabVehicle(vehicle) then return nil end
  return vehicle
end

local function getVehicleActionDisplayName(vehicleId)
  local vehicle = getVehicleTabObjectById(vehicleId)
  if not vehicle then return _tr("ui.pause.vehicle") end
  if core_quickAccess and core_quickAccess.getVehicleName then
    local vehicleName = core_quickAccess.getVehicleName(vehicle)
    if type(vehicleName) == "string" and vehicleName ~= "" then
      return vehicleName
    end
  end
  return getVehicleFallbackName(vehicleId)
end

local function setSelectedSpawnedVehicleId(vehicleId)
  if type(vehicleId) ~= "number" or vehicleId < 0 then return end
  selectedSpawnedVehicleId = vehicleId
end

local function getCurrentRouteParams()
  local currentRoute = ui_router and ui_router.getCurrent and ui_router.getCurrent() or nil
  local request = currentRoute and currentRoute.request or nil
  local resolved = currentRoute and currentRoute.resolved or nil
  if type(request and request.params) == "table" then return request.params end
  if type(resolved and resolved.params) == "table" then return resolved.params end
  return {}
end

local function getSelectedSpawnedVehicleId()
  local params = getCurrentRouteParams()
  local routeVehicleId = tonumber(params.vehicleId)
  if routeVehicleId and getVehicleTabObjectById(routeVehicleId) then
    selectedSpawnedVehicleId = routeVehicleId
    return routeVehicleId
  end
  if type(selectedSpawnedVehicleId) == "number" and getVehicleTabObjectById(selectedSpawnedVehicleId) then
    return selectedSpawnedVehicleId
  end
  local currentVehicleId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or nil
  if type(currentVehicleId) == "number" and currentVehicleId >= 0 and getVehicleTabObjectById(currentVehicleId) then
    selectedSpawnedVehicleId = currentVehicleId
    return currentVehicleId
  end
  selectedSpawnedVehicleId = nil
  return nil
end

isWalkingCharacterVehicle = function(veh)
  if not veh then return false end
  if veh.getJBeamFilename and veh:getJBeamFilename() == "unicycle" then return true end
  return veh.JBeam == "unicycle"
end

local function trySwitchToVehicle(vehicleId, playerNumId)
  if not canSwitchVehicles() then return false end
  local vehicle = getVehicleObjectById(vehicleId)
  if not vehicle or not be then return false end
  be:enterVehicle(playerNumId or 0, vehicle)
  extensions.hook("trackNewVeh")
  extensions.hook("onVehicleSwitchPerformendByUser")
  return true
end

local function tryDeleteVehicle(vehicleId)
  local vehicle = getVehicleObjectById(vehicleId)
  if not vehicle then return false end
  vehicle:delete()
  extensions.hook("onVehicleTabInteractionRemoveVehicle", vehicleId)
  extensions.hook("trackNewVeh")
  return true
end

local function tryRepairVehicleHere(vehicleId)
  local vehicle = getVehicleObjectById(vehicleId)
  if not vehicle or not spawn or not spawn.safeTeleport then return false end
  local pos = vehicle:getPosition()
  local dir = vehicle:getDirectionVector()
  local rot = quatFromDir(dir)
  spawn.safeTeleport(vehicle, pos, rot, nil, nil, nil, nil, true)
  return true
end

local function tryResetVehicle(vehicleId)
  local vehicle = getVehicleObjectById(vehicleId)
  if not vehicle then return false end
  vehicle:requestReset(RESET_PHYSICS)
  vehicle:resetBrokenFlexMesh()
  return true
end

local function trySetAiMode(vehicleId, mode)
  local vehicle = getVehicleObjectById(vehicleId)
  if not vehicle then return false end
  if not canUseVehicleAiModes() then return false end

  local targetId = be and be:getPlayerVehicleID(0) or nil
  if mode == "flee" or mode == "chase" or mode == "follow" then
    if not targetId then return false end
    vehicle:queueLuaCommand('ai.setMode("' .. mode .. '")')
    vehicle:queueLuaCommand("ai.setTargetObjectID(" .. tostring(targetId) .. ")")
    return true
  end

  if mode == "random" then
    vehicle:queueLuaCommand('ai.setState({mode = "random"})')
    return true
  end

  if mode == "traffic" then
    vehicle:queueLuaCommand('ai.setMode("traffic")')
    return true
  end

  return false
end

local function tryDisableAiDriving(vehicleId)
  local vehicle = getVehicleObjectById(vehicleId)
  if not vehicle then return false end
  if not canUseVehicleAiModes() then return false end
  vehicle:queueLuaCommand('ai.setMode("disabled")')
  return true
end

local function tryRemoveAllOtherVehicles(vehicleId)
  if not be then return false end
  local selectedVehicle = getVehicleObjectById(vehicleId)
  if not selectedVehicle then return false end

  local selectedId = selectedVehicle:getId()
  for i = be:getObjectCount() - 1, 0, -1 do
    local veh = be:getObject(i)
    if veh and veh:getId() ~= selectedId and not isWalkingCharacterVehicle(veh) then
      veh:delete()
    end
  end

  extensions.hook("onVehicleTabInteractionRemoveAll", selectedId)
  extensions.hook("trackNewVeh")
  return true
end

local function trySetOtherVehiclesAiMode(mode)
  if not be then return false end
  local currentVehicleId = be:getPlayerVehicleID(0)
  if type(currentVehicleId) ~= "number" or currentVehicleId < 0 then return false end

  local appliedCount = 0
  for _, veh in ipairs(collectVehicleTabVehicles()) do
    local vehicleId = veh:getId()
    if vehicleId ~= currentVehicleId then
      local ok = mode == "none" and tryDisableAiDriving(vehicleId) or trySetAiMode(vehicleId, mode)
      if ok then appliedCount = appliedCount + 1 end
    end
  end

  return appliedCount > 0
end

local function navigateToSpawnedSelectedHome(vehicleId)
  if not ui_router or not ui_router.navigate then return false end
  setSelectedSpawnedVehicleId(vehicleId)
  local ok, result = pcall(ui_router.navigate, "pause.vehicleDetails", { vehicleId = vehicleId }, { preferredScope = "menu-content-card-1" })
  return ok and result and result.result ~= false
end

local function navigateToVehicleTabVehicleDetails(vehicleId)
  if not ui_router or not ui_router.navigate then return false end
  setSelectedSpawnedVehicleId(vehicleId)
  local ok, result = pcall(ui_router.navigate, "pause.vehicle.vehicleDetails", { vehicleId = vehicleId }, { preferredScope = "menu-content-card-1" })
  return ok and result and result.result ~= false
end

local function navigateToManageVehicleDetails(vehicleId)
  if not ui_router or not ui_router.navigate then return false end
  setSelectedSpawnedVehicleId(vehicleId)
  local ok, result = pcall(ui_router.navigate, "pause.manageVehicles.vehicleDetails", { vehicleId = vehicleId }, { preferredScope = "menu-content-card-1" })
  return ok and result and result.result ~= false
end

local function navigateToManageVehiclesList()
  if not ui_router or not ui_router.navigate then return false end
  local ok, result = pcall(ui_router.navigate, "pause.manageVehicles", nil, { preferredScope = "menu-content-card-1" })
  return ok and result and result.result ~= false
end

local function navigateToVehicleTab()
  if not ui_router or not ui_router.navigate then return false end
  local ok, result = pcall(ui_router.navigate, "pause.vehicle", nil, { preferredScope = "menu-content-card-1" })
  return ok and result and result.result ~= false
end

local function tryExitVehicle()
  if not gameplay_walk or not gameplay_walk.toggleWalkingMode then return false end
  gameplay_walk.toggleWalkingMode()
  return true
end

local function getVehicleDetailsActionNameForRoute(routeName)
  if type(routeName) == "string" and routeName:find("^pause%.manageVehicles") == 1 then
    return "openVehicleDetailsManage"
  end
  if routeName == "pause" or routeName == "pause.vehicleDetails" then
    return "openVehicleDetailsHome"
  end
  return "openVehicleDetails"
end

local function navigateToVehicleDetails(vehicleId)
  local routeName = getCurrentRouteName()
  local detailActionName = getVehicleDetailsActionNameForRoute(routeName)
  if detailActionName == "openVehicleDetailsManage" then
    return navigateToManageVehicleDetails(vehicleId)
  end
  if detailActionName == "openVehicleDetailsHome" then
    return navigateToSpawnedSelectedHome(vehicleId)
  end
  return navigateToVehicleTabVehicleDetails(vehicleId)
end

local function shouldNavigateAfterDelete(routeName)
  return routeName == "pause.vehicleDetails" or routeName == "pause.vehicle.vehicleDetails" or routeName == "pause.manageVehicles.vehicleDetails"
end

local function tryCloneVehicle(vehicleId)
  if not be or not core_vehicles or not core_vehicles.cloneCurrent then return false end
  local sourceVehicle = getVehicleObjectById(vehicleId)
  if not sourceVehicle then return false end

  local originalVehicleId = be:getPlayerVehicleID(0)
  local sourceVehicleId = sourceVehicle:getId()
  local switchedToSource = false

  if originalVehicleId ~= sourceVehicleId then
    be:enterVehicle(0, sourceVehicle)
    switchedToSource = true
  end

  local clonedVehicle = core_vehicles.cloneCurrent()

  if switchedToSource then
    local originalVehicle = getVehicleObjectById(originalVehicleId)
    if originalVehicle then
      be:enterVehicle(0, originalVehicle)
    end
  end

  if clonedVehicle and clonedVehicle.getId then
    local clonedVehicleId = clonedVehicle:getId()
    setSelectedSpawnedVehicleId(clonedVehicleId)
    -- when cloning from a selected-vehicle details view, select the freshly cloned vehicle
    if shouldNavigateAfterDelete(getCurrentRouteName()) then
      navigateToVehicleDetails(clonedVehicleId)
    end
    return true
  end
  return false
end

local function refreshVehicleUiAfterAction(actionName)
  if actionName == "deleteVehicle" or actionName == "cloneVehicle" or actionName == "removeAllOtherVehicles" then
    return emitVehiclePauseRouteData()
  end
  emitVehicleStateForCurrentList()
  if actionName == "switchToVehicle" or (type(actionName) == "string" and actionName:find("^switchToVehicle_p%d+$")) or actionName == "aiModeFlee" or actionName == "aiModeChase" or actionName == "aiModeFollow" or actionName == "aiModeRandom" or actionName == "aiModeTraffic" or actionName == "aiModeDisable" or (type(actionName) == "string" and actionName:find("^setOtherVehiclesAiMode_")) then
    requestAiModesForAllVehicles()
    aiModePollTimer = 0
  end
  return true
end

local function getOrCreateActionButton(vehicleId, actionName)
  actionButtonsByVehicleId[vehicleId] = actionButtonsByVehicleId[vehicleId] or {}
  local cached = actionButtonsByVehicleId[vehicleId][actionName]
  if cached then return cached end

  local callback
  if actionName == "switchToVehicle" then
    callback = function()
      local ok = trySwitchToVehicle(vehicleId, 0)
      refreshVehicleUiAfterAction(actionName)
      return ok
    end
  elseif type(actionName) == "string" and actionName:find("^switchToVehicle_p%d+$") then
    local playerNumId = tonumber(actionName:match("^switchToVehicle_p(%d+)$")) or 0
    callback = function()
      local ok = trySwitchToVehicle(vehicleId, playerNumId)
      refreshVehicleUiAfterAction(actionName)
      return ok
    end
  elseif actionName == "deleteVehicle" then
    callback = function()
      local ok = tryDeleteVehicle(vehicleId)
      refreshVehicleUiAfterAction(actionName)
      local routeName = getCurrentRouteName()
      if ok and shouldNavigateAfterDelete(routeName) then
        selectedSpawnedVehicleId = nil
        if type(routeName) == "string" and routeName:find("^pause%.manageVehicles") == 1 then
          navigateToManageVehiclesList()
        else
          navigateToVehicleTab()
        end
      end
      return ok
    end
  elseif actionName == "repairVehicleHere" then
    callback = function()
      local ok = tryRepairVehicleHere(vehicleId)
      refreshVehicleUiAfterAction(actionName)
      return ok
    end
  elseif actionName == "resetVehicle" then
    callback = function()
      local ok = tryResetVehicle(vehicleId)
      refreshVehicleUiAfterAction(actionName)
      return ok
    end
  elseif actionName == "cloneVehicle" then
    callback = function()
      local ok = tryCloneVehicle(vehicleId)
      refreshVehicleUiAfterAction(actionName)
      return ok
    end
  elseif actionName == "aiModeFlee" then
    callback = function()
      local ok = trySetAiMode(vehicleId, "flee")
      refreshVehicleUiAfterAction(actionName)
      return ok
    end
  elseif actionName == "aiModeChase" then
    callback = function()
      local ok = trySetAiMode(vehicleId, "chase")
      refreshVehicleUiAfterAction(actionName)
      return ok
    end
  elseif actionName == "aiModeFollow" then
    callback = function()
      local ok = trySetAiMode(vehicleId, "follow")
      refreshVehicleUiAfterAction(actionName)
      return ok
    end
  elseif actionName == "aiModeRandom" then
    callback = function()
      local ok = trySetAiMode(vehicleId, "random")
      refreshVehicleUiAfterAction(actionName)
      return ok
    end
  elseif actionName == "aiModeTraffic" then
    callback = function()
      local ok = trySetAiMode(vehicleId, "traffic")
      refreshVehicleUiAfterAction(actionName)
      return ok
    end
  elseif actionName == "aiModeDisable" then
    callback = function()
      local ok = tryDisableAiDriving(vehicleId)
      refreshVehicleUiAfterAction(actionName)
      return ok
    end
  elseif actionName == "removeAllOtherVehicles" then
    callback = function()
      local ok = tryRemoveAllOtherVehicles(vehicleId)
      refreshVehicleUiAfterAction(actionName)
      return ok
    end
  elseif actionName == "exitVehicle" then
    callback = function()
      local ok = tryExitVehicle()
      refreshVehicleUiAfterAction(actionName)
      return ok
    end
  elseif actionName == "openVehicleDetails" or actionName == "openVehicleDetailsHome" or actionName == "openVehicleDetailsManage" then
    callback = function()
      setSelectedSpawnedVehicleId(vehicleId)
      return navigateToVehicleDetails(vehicleId)
    end
  elseif type(actionName) == "string" and actionName:find("^setOtherVehiclesAiMode_") then
    local mode = actionName:match("^setOtherVehiclesAiMode_(.+)$")
    callback = function()
      local ok = trySetOtherVehiclesAiMode(mode)
      refreshVehicleUiAfterAction(actionName)
      return ok
    end
  else
    callback = function() return false end
  end

  local meta = buttonInstance.addButton(callback, {
    action = actionName,
    vehicleId = vehicleId,
  })
  actionButtonsByVehicleId[vehicleId][actionName] = meta
  return meta
end

local vehicleAiActionSpecs = {
  { actionName = "aiModeFlee", mode = "flee" },
  { actionName = "aiModeChase", mode = "chase" },
  { actionName = "aiModeFollow", mode = "follow" },
  { actionName = "aiModeRandom", mode = "random" },
  { actionName = "aiModeTraffic", mode = "traffic" },
  { actionName = "aiModeDisable", mode = "none" },
}

local function buildActionEntry(vehicleId, actionName, label, disabled, extra, options)
  local entryExtra = {}
  if type(extra) == "table" then
    for key, value in pairs(extra) do
      entryExtra[key] = value
    end
  end
  entryExtra.action = actionName

  local loading = type(options) == "table" and options.loading == true
  local button = nil
  if not loading then
    button = getOrCreateActionButton(vehicleId or -1, actionName)
  end
  return makeActionEntry(button, label, loading or disabled, entryExtra)
end

local function buildVehicleActionContext(vehicleId, options)
  local currentVehicleId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or nil
  return {
    vehicleId = vehicleId,
    routeName = type(options) == "table" and options.routeName or getCurrentRouteName(),
    currentVehicleId = currentVehicleId,
    hasVehicle = type(vehicleId) == "number" and getVehicleTabObjectById(vehicleId) ~= nil or false,
    isCurrent = type(vehicleId) == "number" and vehicleId == currentVehicleId,
    canModify = canModifyVehicles(),
    canSwitch = canSwitchVehicles(),
    canExit = canExitVehicle(),
    canUseAi = canUseVehicleAiModes(),
    spawningTutorialActive = isSpawningTutorialActive(),
  }
end

local function buildVehicleOpenDetailsAction(context, options)
  local actionName = getVehicleDetailsActionNameForRoute(context.routeName)
  return buildActionEntry(context.vehicleId, actionName, _tr("ui.pause.vehicle.action.openDetails"), not context.hasVehicle, {
    id = "openMore",
  }, options)
end

local function buildVehicleCardSwitchAction(context, options)
  return buildActionEntry(context.vehicleId, "switchToVehicle", _tr("ui.pause.vehicle.action.switchToVehicle"), not (context.canSwitch and context.hasVehicle), {
    id = "switchToVehicle",
  }, options)
end

local function buildVehicleSwitchActions(context, options)
  local actions = {}
  local disabled = context.isCurrent or not (context.canSwitch and context.hasVehicle)
  if isMultiSeatLocalPlayers() then
    for _, playerNumId in ipairs(getLocalPlayerIds()) do
      table.insert(actions, buildActionEntry(context.vehicleId, "switchToVehicle_p" .. tostring(playerNumId), contextTranslate("ui.pause.vehicle.action.switchPlayer", {player = tostring(playerNumId + 1)}), disabled, nil, options))
    end
  else
    table.insert(actions, buildActionEntry(context.vehicleId, "switchToVehicle", _tr("ui.pause.vehicle.action.switchToVehicle"), disabled, nil, options))
  end
  return actions
end

local function buildVehicleExitAction(context, options)
  if not context.isCurrent then return nil end
  return buildActionEntry(context.vehicleId, "exitVehicle", _tr("ui.radialmenu2.exitVehicle"), not (context.canExit and context.hasVehicle), nil, options)
end

local function buildVehicleAiActions(context, options)
  if context.spawningTutorialActive then return {} end
  local actions = {}
  for _, spec in ipairs(vehicleAiActionSpecs) do
    table.insert(actions, buildActionEntry(context.vehicleId, spec.actionName, getAiModeLabel(spec.mode), not (context.canUseAi and context.hasVehicle), { value = spec.mode }, options))
  end
  return actions
end

local function buildVehicleRepairAction(context, options)
  return buildActionEntry(context.vehicleId, "repairVehicleHere", _tr("ui.radialmenu2.categories.repair"), not (context.canModify and context.hasVehicle), nil, options)
end

local function buildVehicleResetAction(context, options)
  return buildActionEntry(context.vehicleId, "resetVehicle", _tr("ui.common.reset"), not (context.canModify and context.hasVehicle), nil, options)
end

local function buildVehicleCloneAction(context, options)
  return buildActionEntry(context.vehicleId, "cloneVehicle", _tr("ui.pause.vehicle.action.cloneVehicle"), not (context.canModify and context.hasVehicle), nil, options)
end

local function buildVehicleDeleteAction(context, options)
  return buildActionEntry(context.vehicleId, "deleteVehicle", _tr("ui.pause.vehicle.action.removeThisVehicle"), not (context.canModify and context.hasVehicle), {
    danger = true,
    confirmText = contextTranslate("ui.pause.vehicle.action.confirmDeleteVehicle", {vehicle = getVehicleActionDisplayName(context.vehicleId)}),
  }, options)
end

local function buildDeleteOtherVehiclesAction(anchorVehicleId, disabled, options)
  return buildActionEntry(anchorVehicleId, "removeAllOtherVehicles", _tr("ui.pause.vehicle.action.deleteOtherVehicles"), disabled, {
    danger = true,
    confirmText = _tr("ui.pause.vehicle.action.confirmDeleteOtherVehicles"),
  }, options)
end

local function buildPerVehicleActionCatalog(vehicleId, options)
  local context = buildVehicleActionContext(vehicleId, options)
  return {
    context = context,
    openDetails = buildVehicleOpenDetailsAction(context, options),
    cardSwitch = buildVehicleCardSwitchAction(context, options),
    switchActions = buildVehicleSwitchActions(context, options),
    exitVehicle = buildVehicleExitAction(context, options),
    aiActions = buildVehicleAiActions(context, options),
    repair = buildVehicleRepairAction(context, options),
    reset = buildVehicleResetAction(context, options),
    clone = buildVehicleCloneAction(context, options),
    delete = buildVehicleDeleteAction(context, options),
    deleteOtherVehicles = buildDeleteOtherVehiclesAction(vehicleId, not (context.canModify and context.hasVehicle), options),
  }
end

local function buildCardActionMap(vehicleId, options)
  local catalog = buildPerVehicleActionCatalog(vehicleId, options)
  return {
    openMore = catalog.openDetails,
    switchToVehicle = catalog.cardSwitch,
    deleteVehicle = catalog.delete,
  }
end

local function buildSelectedSpawnedGroupsFromCatalog(catalog)
  local groups = {}
  local switchActions = {}
  for _, action in ipairs(catalog.switchActions or {}) do
    table.insert(switchActions, action)
  end
  if catalog.exitVehicle then
    table.insert(switchActions, catalog.exitVehicle)
  end

  if #switchActions > 0 then
    table.insert(groups, {
      id = "switch",
      label = _tr("ui.pause.vehicle.group.switch"),
      actions = switchActions,
    })
  end

  if #(catalog.aiActions or {}) > 0 then
    local state = type(catalog.context.vehicleId) == "number" and vehicleStateById[catalog.context.vehicleId] or {}
    local currentMode = normalizeAiMode(state and state.aiMode or "none")
    table.insert(groups, {
      id = "ai",
      -- TODO: temporary static label; the current mode is already shown in the BngSmartSelect. Change this asap to add
      -- a dedicated key like ui.pause.vehicle.aiMode.
      label = _tr("ui.apps.aicontrol.AiMode"),
      currentMode = currentMode,
      actions = catalog.aiActions,
    })
  end

  table.insert(groups, {
    id = "repairReset",
    label = _tr("ui.pause.vehicle.group.repairReset"),
    actions = {
      catalog.repair,
      catalog.reset,
    },
  })
  table.insert(groups, {
    id = "cloneRemove",
    label = _tr("ui.pause.vehicle.group.cloneRemove"),
    actions = {
      catalog.clone,
      catalog.delete,
    },
  })
  table.insert(groups, {
    id = "otherVehicles",
    label = _tr("ui.pause.vehicle.group.otherVehicles"),
    actions = {
      catalog.deleteOtherVehicles,
    },
  })

  return groups
end

local function buildFleetActionCatalog(currentVehicleId, vehicles, options)
  local canModify = canModifyVehicles()
  local canUseAi = canUseVehicleAiModes()
  local hasCurrentVehicle = type(currentVehicleId) == "number" and getVehicleTabObjectById(currentVehicleId) ~= nil
  local hasOtherVehicle = false
  for _, vehicle in ipairs(vehicles or {}) do
    if not vehicle.isCurrent then
      hasOtherVehicle = true
      break
    end
  end

  local aiModeButtons = {}
  for _, option in ipairs(spawnedAiModeOptions) do
    if option.value ~= "mixed" then
      aiModeButtons[option.value] = buildActionEntry(currentVehicleId, "setOtherVehiclesAiMode_" .. option.value, getAiModeSetterLabel(option.value), not (canUseAi and hasOtherVehicle), nil, options)
    end
  end

  return {
    cloneCurrent = buildActionEntry(currentVehicleId, "cloneVehicle", _tr("ui.radialmenu2.Manage.Clone"), not (canModify and hasCurrentVehicle), nil, options),
    deleteOtherVehicles = buildDeleteOtherVehiclesAction(currentVehicleId, not (canModify and hasCurrentVehicle and hasOtherVehicle), options),
    aiModeButtons = aiModeButtons,
    aiModeDisabled = (type(options) == "table" and options.loading == true) or not (canUseAi and hasOtherVehicle),
  }
end

local function buildSpawnedRouteActionPayload(currentVehicleId, vehicles, options)
  local catalog = buildFleetActionCatalog(currentVehicleId, vehicles, options)
  local aiModeButtons = {}
  for value, action in pairs(catalog.aiModeButtons or {}) do
    if action.buttonId ~= nil then
      aiModeButtons[value] = action.buttonId
    end
  end
  return {
    cloneCurrent = catalog.cloneCurrent,
    deleteOtherVehicles = catalog.deleteOtherVehicles,
    aiModeButtons = aiModeButtons,
    aiModeDisabled = catalog.aiModeDisabled,
  }
end

local aiModeIconByMode = {
  random = "arrowsShuffle",
  flee = "carFast",
  chase = "carsChase",
  traffic = "trafficLight",
  follow = "carsFollow",
}

buildVehicleControllerUiElements = function(vehicleState, isCurrent)
  local elements = {}
  local function addElement(iconId, number, color)
    if #elements >= 3 or type(iconId) ~= "string" or iconId == "" then return end
    local element = { iconId = iconId }
    if number ~= nil then element.number = number end
    if type(color) == "string" and color ~= "" then element.color = color end
    table.insert(elements, element)
  end

  local state = type(vehicleState) == "table" and vehicleState or {}
  local controllingPlayerNums = type(state.controllingPlayerNums) == "table" and state.controllingPlayerNums or {}
  local hasLocalControllers = #controllingPlayerNums > 0
  local hasPlayerControl = hasLocalControllers or isCurrent == true
  local isMultiSeatLocal = state.multiSeatLocal == true and #controllingPlayerNums > 0

  if hasPlayerControl then
    if isMultiSeatLocal then
      for _, playerNumId in ipairs(controllingPlayerNums) do
        local playerNumber = (tonumber(playerNumId) or 0) + 1
        addElement("steeringWheelSporty", playerNumber)
      end
    else
      addElement("steeringWheelSporty")
    end
  end

  if state.onlineControlled == true then
    addElement("helmets")
  end

  local aiMode = normalizeAiMode(state.aiMode)
  if aiMode ~= "none" then
    addElement("AIMicrochip")
    addElement(aiModeIconByMode[aiMode])
  end

  if #elements == 0 then
    addElement("night", nil, "rgba(var(--bng-cool-gray-300-rgb), 0.85)")
  end

  return elements
end

local actionIconByName = {
  switchToVehicle = "steeringWheelSporty",
  exitVehicle = "seatArrowOut",
  openVehicleDetails = "listIndented",
  openVehicleDetailsHome = "listIndented",
  openVehicleDetailsManage = "listIndented",
  deleteVehicle = "trashBin1",
  repairVehicleHere = "wrench",
  resetVehicle = "restart",
  cloneVehicle = "copy",
  aiModeFlee = "carFast",
  aiModeChase = "carsChase",
  aiModeFollow = "carsFollow",
  aiModeRandom = "arrowsShuffle",
  aiModeTraffic = "trafficLight",
  aiModeDisable = "circleSlashed",
  removeAllOtherVehicles = "removeListItem",
}

local function getActionIcon(actionName)
  if type(actionName) ~= "string" then return nil end
  if actionIconByName[actionName] then return actionIconByName[actionName] end
  if actionName:find("^switchToVehicle_p%d+$") then return "steeringWheelSporty" end
  if actionName:find("^setOtherVehiclesAiMode_") then return "AIMicrochip" end
  return nil
end

makeActionEntry = function(button, label, disabled, extra)
  local actionName = button and button.action or (type(extra) == "table" and extra.action or nil)
  local entry = {
    buttonId = button and button.buttonId or nil,
    label = label,
    action = actionName,
    disabled = disabled == true,
  }
  local icon = getActionIcon(actionName)
  if icon then
    entry.icon = icon
  end
  if type(extra) == "table" then
    for key, value in pairs(extra) do
      entry[key] = value
    end
  end
  return entry
end

local function getSpawnedVehicleItems()
  if not be or be:getObjectCount() == 0 then return {} end

  collectVehicleControllerTypes()
  local currentVehicleId = be:getPlayerVehicleID(0)
  local activeVehiclesById = {}
  local activeVehicleIds = {}
  for _, veh in ipairs(collectVehicleTabVehicles()) do
    local vehicleId = veh:getId()
    activeVehiclesById[vehicleId] = veh
    table.insert(activeVehicleIds, vehicleId)
  end

  local orderedVehicleIds = getOrderedSpawnedVehicleIds(activeVehiclesById, activeVehicleIds, currentVehicleId)
  local out = {}
  local index = 0
  for _, vehicleId in ipairs(orderedVehicleIds) do
    local veh = activeVehiclesById[vehicleId]
    if veh then
      index = index + 1
      local rawName = core_quickAccess and core_quickAccess.getVehicleName and core_quickAccess.getVehicleName(veh) or getVehicleFallbackName(vehicleId)
      local displayNumber, displayNumberLabel, label = getVehicleDisplayLabelParts(vehicleId, rawName)
      local state = vehicleStateById[vehicleId] or {}
      local aiMode = normalizeAiMode(state.aiMode)
      local isCurrent = vehicleId == currentVehicleId
      local cardActions = buildCardActionMap(vehicleId)
      table.insert(out, {
        id = tostring(vehicleId),
        vehicleId = vehicleId,
        index = index,
        displayNumber = displayNumber,
        displayNumberLabel = displayNumberLabel,
        label = label,
        rawName = rawName,
        icon = "car",
        isCurrent = isCurrent,
        controllerType = state.controllerType or (isCurrent and "player" or "none"),
        controllingPlayerNums = state.controllingPlayerNums or {},
        multiSeatLocal = state.multiSeatLocal == true,
        onlineControlled = state.onlineControlled == true,
        aiMode = aiMode,
        aiModeLabel = getAiModeLabel(aiMode),
        aiControlled = state.aiControlled == true,
        controllerUiElements = buildVehicleControllerUiElements(state, isCurrent),
        selectButtonId = cardActions.openMore and cardActions.openMore.buttonId or nil,
        quickDeleteButtonId = cardActions.deleteVehicle and cardActions.deleteVehicle.buttonId or nil,
        cardActions = cardActions,
      })
    end
  end

  return out
end

local function getSpawnedSummary(vehicles)
  local currentVehicleId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or nil
  local currentVehicleName = _tr("ui.pause.vehicle.none")
  local aiControlledCount = 0
  for _, vehicle in ipairs(vehicles or {}) do
    if vehicle.isCurrent then
      currentVehicleName = vehicle.label
    end
    if vehicle.aiControlled then
      aiControlledCount = aiControlledCount + 1
    end
  end
  if currentVehicleName == _tr("ui.pause.vehicle.none") and type(currentVehicleId) == "number" and currentVehicleId >= 0 then
    local currentVehicle = getVehicleTabObjectById(currentVehicleId)
    if currentVehicle then
      currentVehicleName = core_quickAccess and core_quickAccess.getVehicleName and core_quickAccess.getVehicleName(currentVehicle) or getVehicleFallbackName(currentVehicleId)
    end
  end
  return {
    currentVehicleName = currentVehicleName,
    totalCount = #(vehicles or {}),
    aiControlledCount = aiControlledCount,
  }
end

local function getOtherVehiclesAiMode(vehicles)
  local mode = nil
  local hasOtherVehicle = false
  for _, vehicle in ipairs(vehicles or {}) do
    if not vehicle.isCurrent then
      hasOtherVehicle = true
      if not mode then
        mode = vehicle.aiMode or "none"
      elseif mode ~= vehicle.aiMode then
        return "mixed"
      end
    end
  end
  return hasOtherVehicle and (mode or "none") or "none"
end

local function getSpawnedRouteActions(currentVehicleId, vehicles)
  return buildSpawnedRouteActionPayload(currentVehicleId, vehicles)
end

local function getSpawnedVehiclesPayload(context)
  local mode = context and context.mode or "freeroam"
  resetVehicleState()
  local vehicles = getSpawnedVehicleItems()
  emitVehicleStateForCurrentList()
  if pauseVehicleInteractionsActive then
    requestAiModesForAllVehicles()
  end
  aiModePollTimer = 0

  local currentVehicleId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or nil
  local selectedVehicleId = type(selectedSpawnedVehicleId) == "number" and getVehicleTabObjectById(selectedSpawnedVehicleId) and selectedSpawnedVehicleId or nil
  return {
    mode = mode,
    summary = getSpawnedSummary(vehicles),
    selectedVehicleId = selectedVehicleId,
    aiOtherVehiclesMode = getOtherVehiclesAiMode(vehicles),
    aiModeOptions = spawnedAiModeOptions,
    vehicles = vehicles,
    actions = getSpawnedRouteActions(currentVehicleId, vehicles),
  }
end

local function getSpawnedVehiclesShellPayload(context)
  local currentVehicleId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or nil
  return {
    mode = context and context.mode or "freeroam",
    asyncHydration = true,
    loading = true,
    selectedVehicleId = type(selectedSpawnedVehicleId) == "number" and getVehicleTabObjectById(selectedSpawnedVehicleId) and selectedSpawnedVehicleId or nil,
    summary = {
      currentVehicleName = _tr("ui.common.loading"),
      totalCount = 0,
      aiControlledCount = 0,
    },
    aiOtherVehiclesMode = "none",
    aiModeOptions = spawnedAiModeOptions,
    vehicles = {},
    actions = buildSpawnedRouteActionPayload(currentVehicleId, nil, { loading = true }),
  }
end

local function emitSpawnedVehiclesPayload(context, requestId)
  local payload = getSpawnedVehiclesPayload(context)
  payload.asyncHydration = true
  payload.loading = false
  payload.requestId = requestId
  guihooks.triggerStream(spawnedPayloadStreamName, payload)
  return payload
end

local function makeSelectedSpawnedVehicleFallback(vehicleId)
  local vehicle = getVehicleObjectById(vehicleId)
  if not vehicle then return nil end
  if not isVehicleTabVehicle(vehicle) then return nil end
  ensureVehicleDisplayNumbersForCurrentList()
  local rawName = core_quickAccess and core_quickAccess.getVehicleName and core_quickAccess.getVehicleName(vehicle) or getVehicleFallbackName(vehicleId)
  local displayNumber, displayNumberLabel, label = getVehicleDisplayLabelParts(vehicleId, rawName)
  local state = vehicleStateById[vehicleId] or {}
  local aiMode = normalizeAiMode(state.aiMode)
  local currentVehicleId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or nil
  return {
    id = tostring(vehicleId),
    vehicleId = vehicleId,
    displayNumber = displayNumber,
    displayNumberLabel = displayNumberLabel,
    label = label,
    rawName = rawName,
    isCurrent = vehicleId == currentVehicleId,
    controllerType = (vehicleId == currentVehicleId) and "player" or (state.controllerType or "none"),
    controllingPlayerNums = state.controllingPlayerNums or {},
    multiSeatLocal = state.multiSeatLocal == true,
    onlineControlled = state.onlineControlled == true,
    aiMode = aiMode,
    aiModeLabel = getAiModeLabel(aiMode),
    aiControlled = state.aiControlled == true,
  }
end

local function getSpawnedSelectedVehiclePayload(context)
  local vehicleId = getSelectedSpawnedVehicleId()
  local payload = getSpawnedVehiclesPayload(context)
  local selectedVehicle = nil
  if type(vehicleId) == "number" then
    for _, vehicle in ipairs(payload.vehicles or {}) do
      if vehicle.vehicleId == vehicleId then
        selectedVehicle = vehicle
        break
      end
    end
  end

  if not selectedVehicle and payload.vehicles and payload.vehicles[1] then
    selectedVehicle = payload.vehicles[1]
    vehicleId = selectedVehicle.vehicleId
    setSelectedSpawnedVehicleId(vehicleId)
  end

  return {
    vehicleId = vehicleId,
    label = selectedVehicle and selectedVehicle.label or _tr("ui.pause.vehicle.selectedSpawnedVehicle"),
    rawName = selectedVehicle and selectedVehicle.rawName or "",
    vehicle = selectedVehicle,
    groups = type(vehicleId) == "number" and getSelectedSpawnedActionGroups(vehicleId) or {},
  }
end

local function getSpawnedSelectedVehicleShellPayload(context)
  local vehicleId = getSelectedSpawnedVehicleId()
  local selectedVehicle = type(vehicleId) == "number" and makeSelectedSpawnedVehicleFallback(vehicleId) or nil
  return {
    asyncHydration = true,
    loading = true,
    vehicleId = vehicleId,
    label = selectedVehicle and selectedVehicle.label or _tr("ui.pause.vehicle.selectedSpawnedVehicle"),
    rawName = selectedVehicle and selectedVehicle.rawName or "",
    vehicle = selectedVehicle,
    groups = getSelectedSpawnedActionGroupShell(),
  }
end

local function emitSpawnedSelectedVehiclePayload(context, requestId)
  local payload = getSpawnedSelectedVehiclePayload(context)
  payload.asyncHydration = true
  payload.loading = false
  payload.requestId = requestId
  guihooks.triggerStream(spawnedSelectedPayloadStreamName, payload)
  return payload
end

local function makeAsyncHydrationLoadingAck(requestId)
  return {
    asyncHydration = true,
    loading = true,
    requestId = requestId,
    debugDelayed = true,
  }
end

local function queueAsyncHydrationRequest(kind, context, requestId)
  table.insert(delayedAsyncHydrationRequests, {
    kind = kind,
    context = context,
    requestId = requestId,
    remaining = asyncHydrationDebugDelaySec,
  })
  return makeAsyncHydrationLoadingAck(requestId)
end

local function updateDelayedAsyncHydrationRequests(dtReal)
  if #delayedAsyncHydrationRequests == 0 then return end
  local dt = dtReal or 0
  for index = #delayedAsyncHydrationRequests, 1, -1 do
    local request = delayedAsyncHydrationRequests[index]
    request.remaining = request.remaining - dt
    if request.remaining <= 0 then
      table.remove(delayedAsyncHydrationRequests, index)
      if request.kind == "spawned" then
        emitSpawnedVehiclesPayload(request.context, request.requestId)
      elseif request.kind == "selected" then
        emitSpawnedSelectedVehiclePayload(request.context, request.requestId)
      end
    end
  end
end

getSelectedSpawnedActionGroups = function(vehicleId)
  return buildSelectedSpawnedGroupsFromCatalog(buildPerVehicleActionCatalog(vehicleId))
end

getSelectedSpawnedActionGroupShell = function()
  return buildSelectedSpawnedGroupsFromCatalog(buildPerVehicleActionCatalog(nil, { loading = true }))
end

function M.executeVehicleTabInteractionAction(buttonId, payload)
  if not buttonId then return false end
  return buttonInstance.executeButton(buttonId, payload)
end

function M.getSpawnedVehiclesData(context)
  return getSpawnedVehiclesPayload(context)
end

function M.getSpawnedVehiclesShellData(context)
  return getSpawnedVehiclesShellPayload(context)
end

function M.requestSpawnedVehiclesPayload(payload)
  local requestId = type(payload) == "table" and payload.requestId or nil
  local context = type(payload) == "table" and payload.context or nil
  if asyncHydrationDebugDelaySec > 0 then
    return queueAsyncHydrationRequest("spawned", context, requestId)
  end
  return emitSpawnedVehiclesPayload(context, requestId)
end

function M.getSpawnedSelectedVehicleShellData(context)
  return getSpawnedSelectedVehicleShellPayload(context)
end

function M.requestSpawnedSelectedVehiclePayload(payload)
  local requestId = type(payload) == "table" and payload.requestId or nil
  local context = type(payload) == "table" and payload.context or nil
  if asyncHydrationDebugDelaySec > 0 then
    return queueAsyncHydrationRequest("selected", context, requestId)
  end
  return emitSpawnedSelectedVehiclePayload(context, requestId)
end

function M.setAsyncHydrationDebugDelay(delaySec)
  asyncHydrationDebugDelaySec = math.max(0, tonumber(delaySec) or 0)
  if asyncHydrationDebugDelaySec == 0 then
    table.clear(delayedAsyncHydrationRequests)
  end
  return asyncHydrationDebugDelaySec
end

function M.getAsyncHydrationDebugDelay()
  return asyncHydrationDebugDelaySec
end

function M.getSpawnedVehiclesSummaryData(context)
  local payload = getSpawnedVehiclesPayload(context)
  return {
    summary = payload.summary,
    vehicles = payload.vehicles,
  }
end

function M.getSpawnedSelectedVehicleData(context)
  return getSpawnedSelectedVehiclePayload(context)
end

function M.onPauseRouteLifecycle(routeName)
  setPauseVehicleInteractionsActive(routeName)
end

function M.onVehicleSwitched()
  emitVehicleStateForCurrentList()
  aiModePollTimer = 0
end

function M.onVehicleSwitchPerformendByUser()
  emitVehicleStateForCurrentList()
  aiModePollTimer = 0
end

function M.onVehicleSpawned()
  emitVehiclePauseRouteData()
  guihooks.trigger("VehicleTabSpawnFinished")
end

function M.onVehicleDestroyed()
  emitVehiclePauseRouteData()
end

function M.onVehicleHoverStart(vehicleId)
  setHoveredVehicleId(vehicleId)
end

function M.onVehicleHoverEnd(vehicleId)
  clearHoveredVehicleId(vehicleId)
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  local routeName = getCurrentRouteName()
  if not pauseVehicleInteractionsActive then
    hoveredVehicleId = nil
    aiModePollTimer = 0
    table.clear(delayedAsyncHydrationRequests)
    return
  end
  if not isVehicleHighlightRoute(routeName) then
    hoveredVehicleId = nil
    aiModePollTimer = 0
    table.clear(delayedAsyncHydrationRequests)
    return
  end

  updateDelayedAsyncHydrationRequests(dtReal)

  if isVehicleAiPollingRoute(routeName) then
    aiModePollTimer = aiModePollTimer + (dtSim or 0)
    if aiModePollTimer >= aiModePollIntervalSec then
      aiModePollTimer = aiModePollTimer - aiModePollIntervalSec
      requestAiModesForAllVehicles()
    end
  else
    aiModePollTimer = 0
  end

  local highlightVehicleId = getHighlightVehicleId()
  if not highlightVehicleId then return end

  local vehicle = getVehicleTabObjectById(highlightVehicleId)
  if not vehicle then
    clearTrackedVehicleId(highlightVehicleId)
    return
  end

  local oobb = vehicle.getSpawnWorldOOBB and vehicle:getSpawnWorldOOBB() or nil
  local t = os.clock() or 0
  local pulse = (math.sin(t * 4.0) + 1.0) * 0.5
  -- Orange comes from UI palette preset: --bng-gradient-orange (#ff6600).
  local orange = {1.0, 0.4, 0.0}
  local white = {1.0, 1.0, 1.0}
  local lineColor = ColorF(
    white[1] + (orange[1] - white[1]) * pulse,
    white[2] + (orange[2] - white[2]) * pulse,
    white[3] + (orange[3] - white[3]) * pulse,
    0.95
  )
  local thickness = 3
  if oobb and oobb.getPoint then
    local p = {}
    for i = 0, 7 do
      p[i] = vec3(oobb:getPoint(i))
    end

    debugDrawer:drawLineInstance(p[0], p[1], thickness, lineColor)
    debugDrawer:drawLineInstance(p[1], p[2], thickness, lineColor)
    debugDrawer:drawLineInstance(p[2], p[3], thickness, lineColor)
    debugDrawer:drawLineInstance(p[3], p[0], thickness, lineColor)

    debugDrawer:drawLineInstance(p[4], p[5], thickness, lineColor)
    debugDrawer:drawLineInstance(p[5], p[6], thickness, lineColor)
    debugDrawer:drawLineInstance(p[6], p[7], thickness, lineColor)
    debugDrawer:drawLineInstance(p[7], p[4], thickness, lineColor)

    debugDrawer:drawLineInstance(p[0], p[4], thickness, lineColor)
    debugDrawer:drawLineInstance(p[1], p[5], thickness, lineColor)
    debugDrawer:drawLineInstance(p[2], p[6], thickness, lineColor)
    debugDrawer:drawLineInstance(p[3], p[7], thickness, lineColor)
    return
  end

  local pos = vehicle:getPosition()
  local up = vehicle.getDirectionVectorUp and vehicle:getDirectionVectorUp() or vec3(0, 0, 1)
  debugDrawer:drawLineInstance(pos, pos + up * 2, thickness, lineColor)
end

return M
