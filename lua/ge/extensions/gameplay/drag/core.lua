-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "drag_core"

M.dependencies = {'gameplay_drag_saveSystem', 'gameplay_drag_dragBridge', 'gameplay_drag_rulesMenu', 'gameplay_drag_timeslip', 'gameplay_drag_poi'}

local dragData
local raceStateStore = {}

local gameplayContext = "freeroam"
local dragExtension
local needsMapReload = false
local needsCollisionRebuild = false

local careerRewards = 5
local rewardsGrantedForCurrentRace = false
local levelDragStrips = {}
local poiJoinRequestSent = {}

local RESET_STATE_IDLE = "idle"
local RESET_STATE_RESETTING = "resetting"
local RESET_STATE_READY = "ready"
local resetState = RESET_STATE_IDLE
local loadedDragExtensions = {}


local DRAG_MP_GAMEMODE_EXT = extensions.luaPathToExtName('multiplayer/gamemodes/drag/drag')
local function getDragGamemode()
  -- Restore the two lines below once multiplayer drag is ready to ship.
  -- local ext = _G[DRAG_MP_GAMEMODE_EXT]
  -- if type(ext) ~= "table" then return nil end
  -- return ext
  return nil
end

local function doSendTimeslipDataToUi()
  local slipData = gameplay_drag_timeslip.createTimeslipData()
  if not slipData or not next(slipData) then
    guihooks.trigger("onDragRaceTimeslipData", nil)
    return
  end
  M.saveDialTimes(slipData)
  guihooks.trigger("onDragRaceTimeslipData", slipData)
end

local function sendTimeslipDataToUi()
  local drag = getDragGamemode()
  if drag and drag.isMultiplayer and drag.isMultiplayer() then
    -- MP owns timer sync/timeout behavior and decides when to finalize.
    extensions.hook("onDragMpTimeslipRequested")
    return
  end
  doSendTimeslipDataToUi()
end

local function ensureExtensionLoaded(extName)
  if not extName then return false end
  if not extensions.isExtensionLoaded(extName) then
    extensions.load(extName)
    if not extensions.isExtensionLoaded(extName) then
      log('E', logTag, 'Failed to load required extension: ' .. extName)
      return false
    end
  end
  if extName and not loadedDragExtensions[extName] then
    loadedDragExtensions[extName] = true
  end
  return true
end

--- Ensures all required extensions are loaded from strip data (utils, drag type, times, display). Call before starting a race.
--- @param data optional strip/poi data; if nil, uses module dragData (single-player).
local function ensureAllExtensionsLoaded(data)
  local stripData = data or dragData
  if not stripData then
    log('E', logTag, 'ensureAllExtensionsLoaded called but dragData is nil')
    return false
  end

  if not ensureExtensionLoaded('gameplay_drag_phaseHandlers') then
    return false
  end

  if not stripData.dragType then
    log('E', logTag, 'dragData.dragType is nil, cannot determine which drag type extension to load')
    return false
  end

  local extNameByType = {
    headsUpRace = 'gameplay_drag_dragTypes_headsUpRace',
    bracketRace = 'gameplay_drag_dragTypes_bracketRace',
  }
  local dragTypeExtName = extNameByType[stripData.dragType]
  if not dragTypeExtName or not ensureExtensionLoaded(dragTypeExtName) then
    return false
  end

  if stripData.dragType == "headsUpRace" then
    dragExtension = gameplay_drag_dragTypes_headsUpRace
  elseif stripData.dragType == "bracketRace" then
    dragExtension = gameplay_drag_dragTypes_bracketRace
  else
    log('E', logTag, 'Unknown dragType: ' .. tostring(stripData.dragType))
    return false
  end

  if not dragExtension then
    log('E', logTag, 'dragExtension is nil after loading ' .. dragTypeExtName)
    return false
  end
  if not ensureExtensionLoaded('gameplay_drag_times') then
    log('E', logTag, 'Failed to load required extension gameplay_drag_times')
    return false
  end
  if not gameplay_drag_times then
    log('E', logTag, 'gameplay_drag_times is nil after loading')
    return false
  end
  if not ensureExtensionLoaded('gameplay_drag_display') then
    log('E', logTag, 'Failed to load required extension gameplay_drag_display')
    return false
  end
  if not gameplay_drag_display then
    log('E', logTag, 'gameplay_drag_display is nil after loading')
    return false
  end

  return true
end

-- Unload in dependency order (leaves first). pairs() order is undefined and unloading e.g. times before
-- phaseHandlers breaks resolution and spuriously cascades / triggers extension warnings.
local dragLazyExtensionUnloadOrder = {
  'gameplay_drag_dragTypes_headsUpRace',
  'gameplay_drag_dragTypes_bracketRace',
  'gameplay_drag_display',
  'gameplay_drag_phaseHandlers',
  'gameplay_drag_times',
}

local function unloadAllExtensions()
  extensions.hook("onBeforeDragUnloadAllExtensions")
  for _, extName in ipairs(dragLazyExtensionUnloadOrder) do
    if loadedDragExtensions[extName] and extensions.isExtensionLoaded(extName) then
      extensions.unload(extName)
      loadedDragExtensions[extName] = nil
    end
  end
  for extName, _ in pairs(loadedDragExtensions) do
    if extensions.isExtensionLoaded(extName) then
      extensions.unload(extName)
    end
  end
  table.clear(loadedDragExtensions)
end

local function loadDragStripData(filepath)
  dragData = gameplay_drag_saveSystem.loadDragStripData(filepath)
  if not dragData then
    log('E', logTag, 'Failed to load drag strip data from file: ' .. tostring(filepath))
    return
  end
  return dragData
end

local function loadPrefabs(data)
  if not data then return end

  gameplay_drag_saveSystem.loadPrefabs(data)

  if needsCollisionRebuild then
    be:reloadCollision()
  end
  if needsMapReload then
    map.reset()
  end
end

-- Single source of truth for drag data (strip, racers, timers, etc.). In MP and SP, core owns it.
local function getData()
  return dragData
end

local function getRacerIsDisqualified(racer)
  if not racer then return false end
  if racer.isDisqualified ~= nil then return racer.isDisqualified end
  return racer.isDesqualified or false
end

local function getRacerDisqualificationReason(racer)
  if not racer then return "None" end
  return racer.disqualifiedReason or racer.desqualifiedReason or "None"
end

local function setRacerDisqualificationState(racer, isDisqualified, reason)
  if not racer then return end
  local isDq = isDisqualified and true or false
  local dqReason = reason or "None"
  racer.isDisqualified = isDq
  racer.disqualifiedReason = dqReason
  -- Legacy aliases kept for compatibility during migration.
  racer.isDesqualified = isDq
  racer.desqualifiedReason = dqReason
end

local function normalizeRacerDisqualificationFields(racer)
  if not racer then return end
  setRacerDisqualificationState(racer, getRacerIsDisqualified(racer), getRacerDisqualificationReason(racer))
end

local function setupRacerMpStub(vehicleId, lane, currentDragData)
  local drag = getDragGamemode()
  if not drag or not drag.isMultiplayer() then return false end
  local phases = {}
  for _, p in ipairs(currentDragData.phases or {}) do
    table.insert(phases, { name = p.name, started = false, completed = false, dependency = p.dependency, timerOffset = 0, startedOffset = p.startedOffset or 0 })
  end
  local racerStub = {
    vehId = vehicleId,
    lane = lane,
    currentPhase = 1,
    isPlayable = true,
    vehicleRemoved = false,
    isFinished = false,
    phases = phases,
    beamState = {},
    timers = {},
    timersStarted = false,
    vehObj = nil,
    _stopPhaseStartDistance = nil, -- set once the stop phase begins; distance-from-stage-line reference point for the space-based stop cap
  }
  setRacerDisqualificationState(racerStub, false, "None")
  if not currentDragData.racers then currentDragData.racers = {} end
  currentDragData.racers[vehicleId] = racerStub
  local localRace = drag.getLocalClientActiveRace()
  if localRace and localRace.poiData then
    if not localRace.poiData.racers then localRace.poiData.racers = {} end
    localRace.poiData.racers[vehicleId] = racerStub
  end
  return true
end

local function getInitialDial(vehicleId, importantTimerId)
  local oldData = gameplay_drag_saveSystem.getDialTimes()
  local timesKey = gameplay_drag_saveSystem.generateHashFromFile(vehicleId)
  if oldData[timesKey] then
    return oldData[timesKey][importantTimerId] or oldData[timesKey].time_1_4 or 10
  end
  local details = core_vehicles.getVehicleDetails(vehicleId)
  if details and details.configs and details.configs["Drag Times"] then
    local dt = details.configs["Drag Times"]
    return dt[importantTimerId] or dt.time_1_4 or 10
  end
  return 10
end

local function buildRacerTimers(dial, timerConfig)
  local timers = {
    dial = { type = "dialTimer", value = dial, isSet = true },
    timer = { type = "timer", value = 0 },
  }
  for _, t in ipairs(timerConfig) do
    local id = t.id
    if not id or id == "" then
      local n = 0
      for _ in pairs(timers) do n = n + 1 end
      id = "timer_" .. n
    end
    if t.type == "distanceTimer" then
      local entry = { type = "distanceTimer", value = 0, distance = t.distance, isSet = false, label = t.label or id, important = t.important }
      if t.distance and t.distance < 0.5 then
        entry.frameHistory = {}
      end
      timers[id] = entry
    elseif t.type == "velocity" then
      timers[id] = { type = "velocity", value = 0, distance = t.distance, isSet = false, label = t.label or id, important = t.important }
    end
  end
  return timers
end

local function buildWheelGeometry(vehicle, vehicleId)
  local wheelsByFrontness = {}
  local maxFrontness = -math.huge
  local wheelCount = vehicle:getWheelCount() - 1

  if wheelCount > 0 then
    local vehiclePos = vehicle:getPosition()
    local forward = vehicle:getDirectionVector()
    local up = vehicle:getDirectionVectorUp()
    local vehicleRot = quatFromDir(forward, up)
    local x, y, z = vehicleRot * vec3(1, 0, 0), vehicleRot * vec3(0, 1, 0), vehicleRot * vec3(0, 0, 1)
    local center = vehicle:getSpawnWorldOOBB():getCenter()

    for i = 0, wheelCount do
      local axisNodes = vehicle:getWheelAxisNodes(i)
      local nodePos = vec3(vehicle:getNodePosition(axisNodes[1]))
      local wheelNodePos = vehiclePos + nodePos
      local frontness = forward:dot(wheelNodePos - center)

      for key, _ in pairs(wheelsByFrontness) do
        if math.abs(tonumber(key) - frontness) < 0.2 then
          frontness = key
        end
      end

      local pos = vec3(nodePos:dot(x), nodePos:dot(y), nodePos:dot(z))
      wheelsByFrontness[frontness] = wheelsByFrontness[frontness] or {}
      table.insert(wheelsByFrontness[frontness], pos)
      maxFrontness = math.max(frontness, maxFrontness)
    end
  end

  if not next(wheelsByFrontness) then
    log('E', logTag, 'Couldnt find front wheels for ' .. vehicleId .. '! will use OOBB as wheel offsets')
    local vehiclePos = vehicle:getPosition()
    local forward = vehicle:getDirectionVector()
    local up = vehicle:getDirectionVectorUp()
    local vehicleRot = quatFromDir(forward, up)
    local x, y, z = vehicleRot * vec3(1, 0, 0), vehicleRot * vec3(0, 1, 0), vehicleRot * vec3(0, 0, 1)
    local frontLeft, frontRight = vehicle:getSpawnWorldOOBB():getPoint(0) - vehiclePos, vehicle:getSpawnWorldOOBB():getPoint(3) - vehiclePos
    local posL = vec3(frontLeft:dot(x), frontLeft:dot(y), frontLeft:dot(z))
    local posR = vec3(frontRight:dot(x), frontRight:dot(y), frontRight:dot(z))
    maxFrontness = "oobb"
    wheelsByFrontness[maxFrontness] = { posL, posR }
  end

  return wheelsByFrontness, maxFrontness
end

local function buildRacerPhases(phasesConfig)
  local phases = {}
  for _, phase in ipairs(phasesConfig) do
    table.insert(phases, {
      name = phase.name,
      started = false,
      completed = false,
      dependency = phase.dependency,
      timerOffset = 0,
      startedOffset = phase.startedOffset,
    })
  end
  return phases
end

local function setupRacer(vehicleId, lane)
  local currentDragData = getData()
  if not currentDragData then return end

  if not vehicleId then
    log('E', logTag, 'No vehicle id')
    return
  end

  local vehicle = scenetree.findObjectById(vehicleId)
  if not vehicle or vehicle.className ~= "BeamNGVehicle" then
    if setupRacerMpStub(vehicleId, lane, currentDragData) then
      return
    end
    log('E', logTag, 'Object with ID: ' .. vehicleId .. ' is not a vehicle')
    return
  end

  local timerConfig = currentDragData.timers or gameplay_drag_saveSystem.DEFAULT_TIMERS
  local importantTimerId = currentDragData.importantTimerId or "time_1_4"
  local dial = getInitialDial(vehicleId, importantTimerId)

  local racer = {
    vehId = vehicleId,
    phases = {},
    currentPhase = 1,
    isPlayable = true,
    lane = lane,
    isFinished = false,
    wheelsOffsets = {},
    currentCorners = {},
    canBeTeleported = currentDragData.canBeTeleported,
    canBeReseted = currentDragData.canBeReseted,
    treeStarted = false,
    timersStarted = false,
    damage = 0,
    timers = buildRacerTimers(dial, timerConfig),
    vehPos = vec3(),
    vehDirectionVector = vec3(),
    vehDirectionVectorUp = vec3(),
    vehRot = quat(),
    vehVelocity = vec3(),
    prevSpeed = 0,
    vehSpeed = 0,
    vehObj = nil,
    _stopPhaseStartDistance = nil, -- set once the stop phase begins; distance-from-stage-line reference point for the space-based stop cap
  }
  setRacerDisqualificationState(racer, false, "None")

  local wheelsByFrontness, maxFrontness = buildWheelGeometry(vehicle, vehicleId)
  racer.allWheelsOffsets = wheelsByFrontness
  racer.wheelsCenter = {}
  racer.beamState = {}
  racer.frontWheelId = maxFrontness
  for k, v in pairs(racer.allWheelsOffsets) do
    racer.wheelsCenter[k] = { pos = vec3(), wheelCountInv = 1 / #racer.allWheelsOffsets[k] }
    racer.beamState[k] = { preStage = false, stage = false }
  end

  racer.phases = buildRacerPhases(currentDragData.phases)

  local details = core_vehicles.getVehicleDetails(vehicleId)
  if details then
    racer.niceName = (details.model.Brand or "") .. " " .. (details.configs.Name or "Unknown")
  end

  local _, ret = xpcall(function() return type(deserialize(vehicle.partConfig)) end, nop)
  racer.stock = not ret
  racer.licenseText = core_vehicles.getVehicleLicenseText(vehicle)

  if not currentDragData.racers then currentDragData.racers = {} end
  currentDragData.racers[vehicleId] = racer
end

local cachedZoneMetatable
local restoreZoneMetatable = function(zone)
  if not zone or zone.containsPoint2D then return end
  if not zone.vertices then return end
  if not cachedZoneMetatable then
    local ZoneClass = require('/lua/ge/extensions/gameplay/sites/zone')
    cachedZoneMetatable = getmetatable(ZoneClass(nil, ""))
  end
  if cachedZoneMetatable then setmetatable(zone, cachedZoneMetatable) end
end

local reconstructRuntimeObjects = function(data)
  if not data or not data.strip or not data.strip.lanes then return end
  for _, lane in ipairs(data.strip.lanes) do
    restoreZoneMetatable(lane.zone)
  end
  restoreZoneMetatable(data.strip.stripZone)
end

local function resolveRaceEndTimerId(data)
  if not data then return nil end
  local importantId = data.importantTimerId or "time_1_4"
  local timerConfig = data.timers or (gameplay_drag_saveSystem and gameplay_drag_saveSystem.DEFAULT_TIMERS) or {}
  local maxDistTimerId = nil
  local maxDist = -1
  for _, t in ipairs(timerConfig) do
    local id = t.id or ("timer_" .. #timerConfig)
    if t.distance and t.distance > maxDist then
      maxDist = t.distance
      maxDistTimerId = id
    end
  end
  return maxDistTimerId or importantId
end

local function setDragRaceData(data)
  if not data then
    return
  end

  dragData = data
  if not dragData.racers then dragData.racers = {} end
  for _, racer in pairs(dragData.racers) do
    normalizeRacerDisqualificationFields(racer)
  end
  dragData.raceEndTimerId = resolveRaceEndTimerId(dragData)

  reconstructRuntimeObjects(dragData)

  gameplay_drag_saveSystem.syncDragStripWaypointsWithSceneTree(dragData)
  gameplay_drag_saveSystem.resolveAutoStopWaypoints(dragData)

  if not ensureAllExtensionsLoaded(data) then
    log('E', logTag, 'Failed to ensure all extensions loaded in setDragRaceData')
    return
  end
  extensions.hook('onDragDataSet', data)
end

--- Mission-facing helper: load drag strip data, prefabs, context, and set runtime drag data.
--- Returns loaded data table on success, nil on failure.
local function loadDragDataForMission(filepath)
  local data = loadDragStripData(filepath)
  if not data then
    return nil
  end
  loadPrefabs(data)
  gameplayContext = data.context or gameplayContext
  setDragRaceData(data)
  return data
end

local function calculateStateChecksum(data)
  if not data then return 0 end
  local checksum = 0
  if data.isStarted then checksum = checksum + 1 end
  if data.isCompleted then checksum = checksum + 2 end
  if data.racers then
    for vehId, racer in pairs(data.racers) do
      checksum = checksum + (racer.currentPhase or 0) * 10
      checksum = checksum + (getRacerIsDisqualified(racer) and 1 or 0) * 100
      checksum = checksum + (racer.isFinished and 1 or 0) * 1000
      if racer.phases then
        for i, phase in ipairs(racer.phases) do
          checksum = checksum + (phase.started and 1 or 0) * (i * 2)
          checksum = checksum + (phase.completed and 1 or 0) * (i * 3)
        end
      end
    end
  end
  return checksum
end

local function validateResetState(data)
  if not data then return false, "No drag data" end
  if data.isStarted then return false, "Race still marked as started" end
  if data.isCompleted then return false, "Race still marked as completed" end
  if not data.racers then return true, "No racers to validate" end

  for vehId, racer in pairs(data.racers) do
    if racer.currentPhase ~= 1 then
      return false, string.format("Racer %d not in phase 1 (current: %d)", vehId, racer.currentPhase)
    end
    if getRacerIsDisqualified(racer) then
      return false, string.format("Racer %d still disqualified", vehId)
    end
    if racer.isFinished then
      return false, string.format("Racer %d still marked as finished", vehId)
    end
    if racer.treeStarted then
      return false, string.format("Racer %d tree still started", vehId)
    end
    if racer.timersStarted then
      return false, string.format("Racer %d timers still started", vehId)
    end
    if racer.phases then
      for i, phase in ipairs(racer.phases) do
        if phase.started then
          return false, string.format("Racer %d phase %d still started", vehId, i)
        end
        if phase.completed then
          return false, string.format("Racer %d phase %d still completed", vehId, i)
        end
      end
    end
  end
  return true, "Validation passed"
end

local function getResetState()
  return resetState
end

--- Marks a racer as disqualified and finished so they count as finished and do not affect data.
local function markRacerDisqualifiedAndFinished(racer, reason)
  if not racer then return end
  setRacerDisqualificationState(racer, true, reason or "None")
  racer.isFinished = true
  racer.currentPhase = #(getData() and getData().phases or {}) + 1
end

--- Marks a racer as removed (vehicle destroyed). Racer stays in data with lane/timers but no vehId/vehObj.
local function markRacerVehicleRemoved(racer, reason)
  if not racer then return end
  markRacerDisqualifiedAndFinished(racer, reason or "Vehicle removed")
  racer.vehicleRemoved = true
  racer.vehObj = nil
end

--- Resets a single racer's state (phases, DQ, finished, tree/timers). Used by reset().
local function resetRacerState(racer)
  if not racer then return end
  racer.currentPhase = 1
  setRacerDisqualificationState(racer, false, "None")
  racer.isFinished = false
  racer.vehicleRemoved = false
  racer.treeStarted = false
  racer.timersStarted = false
  racer.reactionTimeInvalid = false
  racer.damage = 0
  racer.raceStartBroadcasted = false
  if racer.phases then
    for _, phase in ipairs(racer.phases) do
      phase.started = false
      phase.completed = false
      phase.timerOffset = 0
      phase.creepPhase = nil
      phase.creepBrakeTimer = nil
    end
  end
end

--- # Reset race state. Accepts an options table with named fields (all default to false/nil):
-- raceState       : reset isStarted/isCompleted flags
-- racers          : reset each racer's phase/DQ/finished state
-- clearRacers     : remove all racers from data
-- timeslip        : clear timeslip UI
-- transitionLock  : clear phase transition locks and remote staging hold timers
-- treeLightStaging: trigger staging tree light UI
-- hooks           : fire extensions.hook("onDragReset")
-- raceId          : race identifier (passed to hook)
M.reset = function(opts)
  if type(opts) ~= "table" then opts = {} end
  rewardsGrantedForCurrentRace = false
  if gameplay_drag_phaseHandlers then
    gameplay_drag_phaseHandlers.clearDqRestageState()
  end
  local hookOpts = { raceId = opts.raceId }

  local data = getData()
  if not data then
    resetState = RESET_STATE_IDLE
    if opts.timeslip then guihooks.trigger("onDragRaceTimeslipData", nil) end
    if opts.hooks then extensions.hook("onDragReset", hookOpts) end
    return
  end

  resetState = RESET_STATE_RESETTING
  local preChecksum = calculateStateChecksum(data)

  if opts.raceState then
    data.isStarted = false
    data.isCompleted = false
  end

  if opts.clearRacers then
    data.racers = {}
  elseif opts.racers and data.racers then
    for _, racer in pairs(data.racers) do resetRacerState(racer) end
  end

  if opts.transitionLock and gameplay_drag_phaseHandlers then
    gameplay_drag_phaseHandlers.clearRacerTransitionLock()
    gameplay_drag_phaseHandlers.clearRemoteStagingHoldTimers()
  end

  if opts.treeLightStaging then guihooks.trigger('updateTreeLightStaging', true) end
  if opts.timeslip then guihooks.trigger("onDragRaceTimeslipData", nil) end
  if opts.hooks then extensions.hook("onDragReset", hookOpts) end

  resetState = RESET_STATE_READY
  local postChecksum = calculateStateChecksum(data)
  local isValid, validationMsg = validateResetState(data)
  if not isValid then
    log('W', logTag, string.format('Reset validation warning: %s (preChecksum=%d, postChecksum=%d)', validationMsg, preChecksum, postChecksum))
  end
end

-- # Clear drag state. Accepts an options table with named fields (all default to false):
-- hooks           : fire extensions.hook("onDragClear")
-- transitionLock  : clear phase transition locks
-- localRace       : clear MP local client active race
-- extensions      : unload lazy-loaded drag extensions
-- data            : unload prefabs and nil out dragData
-- context         : reset gameplayContext to "freeroam"
-- ui              : hide drag UI apps and clear messages
-- treeLightStaging: trigger staging tree light UI off
M.clear = function(opts)
  if type(opts) ~= "table" then opts = {} end
  rewardsGrantedForCurrentRace = false
  if gameplay_drag_phaseHandlers then
    gameplay_drag_phaseHandlers.clearDqRestageState()
  end
  if opts.hooks then extensions.hook("onDragClear", {}) end
  if opts.transitionLock and gameplay_drag_phaseHandlers then
    gameplay_drag_phaseHandlers.clearRacerTransitionLock()
  end
  if opts.localRace then
    local drag = getDragGamemode()
    if drag and drag.clearLocalClientActiveRace then drag.clearLocalClientActiveRace() end
  end
  if opts.extensions then unloadAllExtensions() end
  if opts.data and dragData then
    gameplay_drag_saveSystem.unloadPrefabs(dragData)
  end
  if opts.data then
    dragData = nil
    raceStateStore = {}
    needsMapReload = false
    needsCollisionRebuild = false
    dragExtension = nil
    poiJoinRequestSent = {}
  end
  resetState = RESET_STATE_IDLE
  if opts.context then gameplayContext = "freeroam" end
  if opts.ui and ui_appContainers then
    ui_appContainers.hideApp('topCenter', 'drag')
  end
  if opts.ui and ui_appContainers_topCenter then
    ui_appContainers_topCenter.clearMessagesFromSource('drag')
  end
  if opts.treeLightStaging then guihooks.trigger('updateTreeLightStaging', false) end
  if opts.hooks then extensions.hook("onDragClearComplete") end
end

local function setRacerDial(vehicleId, dialValue)
  local currentDragData = getData()
  if not currentDragData then
    log("W", logTag, "setRacerDial called but dragData is nil")
    return false
  end
  if not vehicleId or dialValue == nil then
    return false
  end
  local numVal = tonumber(dialValue)
  if not numVal or numVal < 0 then
    return false
  end
  if not currentDragData.racers or not currentDragData.racers[vehicleId] then
    return false
  end
  if not currentDragData.racers[vehicleId].timers then
    currentDragData.racers[vehicleId].timers = {}
  end
  if not currentDragData.racers[vehicleId].timers.dial then
    currentDragData.racers[vehicleId].timers.dial = { type = 'dialTimer', value = 0, isSet = true }
  end
  currentDragData.racers[vehicleId].timers.dial.value = numVal
  currentDragData.racers[vehicleId].timers.dial.isSet = true
  return true
end

local function setRacersDial(dials)
  local currentDragData = getData()
  if not currentDragData then
    log("W", logTag, "setRacersDial called but dragData is nil")
    return false
  end
  if not dials or type(dials) ~= 'table' or #dials == 0 then
    return false
  end

  local successCount = 0
  for _, d in ipairs(dials) do
    if d and d.racerId and d.value then
      if setRacerDial(d.racerId, d.value) then
        successCount = successCount + 1
      end
    end
  end
  return successCount > 0
end

local function setPlayableVehicle(vehicleId)
  if not vehicleId then return end
  local currentDragData = getData()
  if currentDragData and currentDragData.racers and currentDragData.racers[vehicleId] then
    currentDragData.racers[vehicleId].isPlayable = true
  end
end

local function getTimers(vehicleId)
  local currentDragData = getData()
  if not currentDragData then return end
  if currentDragData.racers and currentDragData.racers[vehicleId] then
    return currentDragData.racers[vehicleId].timers or {}
  end
  return {}
end

local function getRacerData(vehicleId)
  local currentDragData = getData()
  if not currentDragData or not currentDragData.racers or not currentDragData.racers[vehicleId] then return end
  return currentDragData.racers[vehicleId] or {}
end

local function trySetUIContainerContextToDrag()
  if ui_appContainers then
    ui_appContainers.showApp('topCenter', 'drag')
  end
end


local function startDragRaceActivity(lane)
  local currentDragData = getData()
  if not currentDragData then
    log('E', logTag, 'startDragRaceActivity called but dragData is nil')
    return false
  end

  if not currentDragData.racers then
    log('E', logTag, 'startDragRaceActivity called but dragData.racers is nil')
    return false
  end

  if not ensureAllExtensionsLoaded(currentDragData) then
    log('E', logTag, 'Failed to ensure all extensions loaded before starting drag race')
    return false
  end

  if not dragExtension then
    log('E', logTag, 'dragExtension is nil after ensureAllExtensionsLoaded')
    return false
  end

  if not gameplay_drag_phaseHandlers then
    log('E', logTag, 'gameplay_drag_phaseHandlers is nil after ensureAllExtensionsLoaded')
    return false
  end

  if not gameplay_drag_times then
    log('E', logTag, 'gameplay_drag_times is nil after ensureAllExtensionsLoaded')
    return false
  end

  if not gameplay_drag_display then
    log('E', logTag, 'gameplay_drag_display is nil after ensureAllExtensionsLoaded')
    return false
  end

  -- In MP, racers are already set up by onDragRaceStarted (local + remote stubs).
  -- Only clear and recreate in singleplayer freeroam where this is the initial racer setup.
  local isMP = getDragGamemode() and getDragGamemode().isMultiplayer and getDragGamemode().isMultiplayer()
  if not isMP and lane ~= nil and gameplayContext == "freeroam" then
    dragData.racers = {}
    if dragData.prefabs and dragData.prefabs.christmasTree and not dragData.prefabs.christmasTree.treeType then
      dragData.prefabs.christmasTree.treeType = ".500"
    end
    setupRacer(be:getPlayerVehicleID(0), lane)
    gameplayContext = dragData.context or 'freeroam'
  end

  poiJoinRequestSent = {}

  trySetUIContainerContextToDrag()
  -- In MP, don't force-show the staging app; checkStagingAppVisibility will show it when the player is near the stage line.
  local drag = getDragGamemode()
  if not drag or not drag.isMultiplayer or not drag.isMultiplayer() then
    guihooks.trigger('updateTreeLightStaging', true)
  end
  dragExtension.startActivity()
  extensions.hook('onDragRacersSetup', dragData)
  return true
end


--- Merge updates into stored race state for raceId. MP handlers and gamemode call this; they do not edit race state directly.
local function setRaceState(raceId, updates)
  if not raceId or not updates or type(updates) ~= "table" then return end
  raceStateStore[raceId] = raceStateStore[raceId] or {}
  local r = raceStateStore[raceId]
  for k, v in pairs(updates) do
    r[k] = v
  end
end

--- Removes a race from the state store entirely.
local function clearRaceState(raceId)
  if raceId then raceStateStore[raceId] = nil end
end

--- Returns race state. In MP: from raceStateStore (canonical); data = getData(). In SP: from dragData.
local function getRaceState(raceId)
  local drag = getDragGamemode()
  if drag and drag.isMultiplayer and drag.isMultiplayer() then
    -- Default to the local player's active race when no raceId is provided
    if not raceId then
      local lcar = drag.getLocalClientActiveRace and drag.getLocalClientActiveRace()
      raceId = lcar and lcar.id or nil
    end
    if not raceId then
      for storedId, _ in pairs(raceStateStore) do
        raceId = storedId
        break
      end
    end
    if raceId and raceStateStore[raceId] then
      local r = raceStateStore[raceId]
      return {
        id = raceId,
        data = getData(),
        isStarted = r.isStarted or false,
        players = r.players or {},
        queue = r.queue or {},
        currentPairIndex = r.currentPairIndex or 0,
        treeType = r.treeType or ".500",
        creatorId = r.creatorId,
        finishTimes = r.finishTimes or {},
        timerValues = r.timerValues or {},
        lobbyId = r.lobbyId,
        poiData = r.poiData,
        playersRacedThisCycle = r.playersRacedThisCycle or {},
      }
    end
    return nil
  end
  if not dragData then return nil end
  return {
    id = nil,
    data = dragData,
    isStarted = dragData.isStarted or false,
    isCompleted = dragData.isCompleted or false,
    finishTimes = {},
    timerValues = {},
    players = {},
    treeType = dragData.prefabs and dragData.prefabs.christmasTree and dragData.prefabs.christmasTree.treeType or ".500"
  }
end

local function getDragIsStarted()
  if not dragData then return false end
  return dragData.isStarted or false
end

local function getGameplayContext()
  return gameplayContext
end

local function onVehicleResetted(vehicleId)
  local currentDragData = getData()
  if gameplayContext == "freeroam" and currentDragData and getDragIsStarted() then
    if currentDragData.racers and currentDragData.racers[vehicleId] then
      local isMultiplayer = getDragGamemode() and getDragGamemode().isMultiplayer()
      if not isMultiplayer then
        markRacerDisqualifiedAndFinished(currentDragData.racers[vehicleId], "Vehicle reset")
      end
    end
  end
end

local function onVehicleSwitched(oldId, newId)
  local currentDragData = getData()
  if gameplayContext == "freeroam" and currentDragData and getDragIsStarted() then
    local racers = currentDragData.racers
    if racers then
      local isMultiplayer = getDragGamemode() and getDragGamemode().isMultiplayer()
      if not isMultiplayer then
        if racers[oldId] then markRacerDisqualifiedAndFinished(racers[oldId], "Vehicle switched") end
        if racers[newId] then markRacerDisqualifiedAndFinished(racers[newId], "Vehicle switched") end
      end
    end
  end
end

local function onVehicleDestroyed(vehicleId)
  local currentDragData = getData()
  if gameplayContext == "freeroam" and currentDragData and getDragIsStarted() then
    if currentDragData.racers and currentDragData.racers[vehicleId] then
      local isMultiplayer = getDragGamemode() and getDragGamemode().isMultiplayer()
      if not isMultiplayer then
        markRacerVehicleRemoved(currentDragData.racers[vehicleId], "Vehicle removed")
      end
    end
  end
end

local function onDragRaceCountdownStart(mappedTime, randValue)
  local currentDragData = getData()
  if not currentDragData or not gameplay_drag_phaseHandlers then return end

  local drag = getDragGamemode()
  local isMP = drag and drag.isMultiplayer and drag.isMultiplayer()
  local isHost = drag and drag.isServerHost and drag.isServerHost()

  -- In MP only the host advances via checkTimerDrift; clients advance here when they receive the broadcast.
  if isMP and not isHost then
    local anyInPhase1 = false
    for _, racer in pairs(currentDragData.racers) do
      if not racer.vehicleRemoved and racer.currentPhase == 1 then anyInPhase1 = true break end
    end
    if anyInPhase1 then
      for _, racer in pairs(currentDragData.racers) do
        if racer.vehicleRemoved then goto continue end
        if racer.phases and racer.phases[1] then racer.phases[1].completed = true end
        ::continue::
      end
      gameplay_drag_phaseHandlers.changeAllPhases()
    end
  elseif not isMP then
    local allStaged, stagedCount, totalCount = gameplay_drag_phaseHandlers.areAllRacersStaged(currentDragData)
    if allStaged and totalCount > 0 and stagedCount == totalCount then
      gameplay_drag_phaseHandlers.changeAllPhases()
    end
  end

  for _, racer in pairs(currentDragData.racers) do
    if racer.vehicleRemoved then goto continue end
    if racer.phases and racer.phases[2] and not racer.phases[2].started then
      racer.phases[2].timerOffset = racer.phases[2].startedOffset or 0
      extensions.hook("startDragCountdown", racer.vehId, 0)
      racer.phases[2].started = true
    end
    ::continue::
  end
end

--- When host applies a tree light update: mark racers in that lane as staged/unstaged so areAllRacersStaged is correct.
--- In MP, delegates to gameplay_drag_phaseHandlers for the 1-second staging hold (same threshold as singleplayer).
local function setRacersInLaneStaged(lane, staged)
  local data = getData()
  if not data or not data.racers then return end

  local drag = getDragGamemode()
  local isMP = drag and drag.isMultiplayer and drag.isMultiplayer()

  if isMP and gameplay_drag_phaseHandlers then
    gameplay_drag_phaseHandlers.setRemoteStagingState(data, lane, staged)
  else
    for _, racer in pairs(data.racers) do
      if racer.lane == lane and racer.phases and racer.phases[1] then
        racer.phases[1].completed = (staged == true)
      end
    end
  end
end

local function onDragRaceTreeLights(lane, lightState)
  if lightState and lightState.stageLights and lightState.stageLights.stageLight ~= nil then
    setRacersInLaneStaged(lane, lightState.stageLights.stageLight)
  end
  if gameplay_drag_display then
    gameplay_drag_display.updateTreeLightsFromNetwork(lane, lightState)
  end
end

local function onDragRaceWinningLights(lane)
  if gameplay_drag_display then
    gameplay_drag_display.onWinnerLightOn(lane)
  end
end

--- When host broadcasts race start, clients advance all racers to race phase (phase 3).
local function onDragRaceStart(raceStartTime)
  local currentDragData = getData()
  if not currentDragData or not gameplay_drag_phaseHandlers then return end
  local drag = getDragGamemode()
  local isMP = drag and drag.isMultiplayer and drag.isMultiplayer()
  local isHost = drag and drag.isServerHost and drag.isServerHost()
  if isMP and not isHost then
    local anyInPhase2 = false
    for _, racer in pairs(currentDragData.racers) do
      if not racer.vehicleRemoved and racer.currentPhase == 2 then anyInPhase2 = true break end
    end
    if anyInPhase2 then
      for _, racer in pairs(currentDragData.racers) do
        if racer.vehicleRemoved then goto continue end
        if racer.phases and racer.phases[2] then racer.phases[2].completed = true end
        ::continue::
      end
      gameplay_drag_phaseHandlers.changeAllPhases()
    end
  end
end

local function onDragRaceJoinAccepted(raceId, lane, poiData, treeType)
  if poiData and poiData.prefabs and poiData.prefabs.christmasTree then
    poiData.prefabs.christmasTree.treeType = treeType
  end
  setDragRaceData(poiData)
  local vehicleId = be:getPlayerVehicleID(0)
  if vehicleId and vehicleId ~= -1 then
    setupRacer(vehicleId, lane)
  end
  startDragRaceActivity(lane)
  local drag = getDragGamemode()
  if drag and drag.isMenuOpen and drag.openMenu then
    if not drag.isMenuOpen() then
      drag.openMenu(deepcopy(poiData), lane)
      if drag.setMenuState then drag.setMenuState("lobby") end
    end
  end
end



local lastStartedRaceId = nil
local function onDragRaceStarted(raceId)
  -- Guard against duplicate calls (host receives its own broadcast via lobby client list)
  if lastStartedRaceId == raceId then return end

  local raceState
  local drag = getDragGamemode()
  if drag and drag.isMultiplayer and drag.isMultiplayer() and drag.getRaceState then
    raceState = drag.getRaceState(raceId)
  else
    raceState = getRaceState(raceId)
  end
  if not raceState then
    log('E', logTag, string.format('onDragRaceStarted: raceState nil for raceId=%s', tostring(raceId)))
    return
  end

  -- Prefer poiData from raceStateStore (has updated rules from broadcastRulesUpdate) over getData()
  local poiData = raceState.poiData or raceState.data
  if not poiData then
    log('E', logTag, 'onDragRaceStarted: poiData is nil')
    return
  end

  local treeType = raceState.treeType or ".500"
  if poiData.prefabs and poiData.prefabs.christmasTree then
    poiData.prefabs.christmasTree.treeType = treeType
  end

  setDragRaceData(deepcopy(poiData))
  loadPrefabs(deepcopy(poiData))

  local dragData = getData()
  if not dragData then
    log('E', logTag, 'onDragRaceStarted: dragData is nil after setDragRaceData')
    return
  end

  -- Only add racers for the current heat so staging/countdown waits for all in-heat players
  local queue = raceState.queue or {}
  local heatIdx = (raceState.currentPairIndex and raceState.currentPairIndex > 0) and raceState.currentPairIndex or 1
  local slot = queue[heatIdx]
  local players = raceState.players or {}
  dragData.racers = {}
  -- Use slot index as lane so each racer gets the correct lane for this heat (staging lights per lane).
  if type(slot) == "table" then
    for lane = 1, (dragData.strip and dragData.strip.lanes and #dragData.strip.lanes) or 2 do
      local playerId = slot[lane]
      if playerId and players[playerId] then
        local pd = players[playerId]
        setupRacer(pd.vehicleId, lane)
      end
    end
  end
  if not next(dragData.racers) then
    for playerId, playerData in pairs(players) do
      setupRacer(playerData.vehicleId, playerData.lane or 1)
    end
  end

  -- In MP, the local player's entry in raceState.players has vehicleId=-1 (set at join time).
  -- Replace the stub with a proper racer using the real local vehicle so staging/DQ work locally.
  -- Mark it as isLocalRacer so the update loop only runs physics on this machine's vehicle.
  -- Remote racers (stubs or synced vehicles with wrong scenetree IDs) are network-driven only.
  if drag and drag.isMultiplayer and drag.isMultiplayer() then
    local localPlayerId = drag.getLocalPlayerId and drag.getLocalPlayerId()
    local localVehicleId = be:getPlayerVehicleID(0)
    if localPlayerId and localVehicleId and localVehicleId > 0 then
      local pd = players[localPlayerId]
      if pd and pd.lane then
        -- Remove the stub entry (vehicleId=-1 or whatever was stored at join time)
        if pd.vehicleId ~= localVehicleId and dragData.racers[pd.vehicleId] then
          dragData.racers[pd.vehicleId] = nil
        end
        -- Create a proper racer with the real vehicle
        if not dragData.racers[localVehicleId] then
          setupRacer(localVehicleId, pd.lane)
        end
      end
    end
    -- Tag each racer so the per-frame update loop knows which one is local
    for vehId, racer in pairs(dragData.racers) do
      racer.isLocalRacer = (vehId == localVehicleId)
    end
  end

  extensions.hook("onDragReset", { raceId = nil })

  startDragRaceActivity(raceState.lane or 1)

  if poiData.dragType == "bracketRace" and drag and drag.isMultiplayer and drag.isMultiplayer() then
    local localVehicleId = be:getPlayerVehicleID(0)
    if localVehicleId and localVehicleId > 0 then
      local racer = dragData.racers and dragData.racers[localVehicleId]
      local dialVal = racer and racer.timers and racer.timers.dial and racer.timers.dial.value
      if not dialVal or dialVal <= 0 then
        gameplay_drag_dragBridge.showDialControl()
      end
    end
  end

  lastStartedRaceId = raceId
end

local function onDragRaceListChanged()
  local drag = getDragGamemode()
  if drag and drag.isMultiplayer and drag.isMultiplayer() and drag.onDragRaceListChanged then
    drag.onDragRaceListChanged()
  end
end

local function onDragRaceReset(raceId)
  local data = getData()
  if data then
    data.isStarted = false
    data.isCompleted = false
  end
  -- Allow the same raceId to trigger onDragRaceStarted again (next heat)
  lastStartedRaceId = nil
end

local function onDragRaceCancelled(raceId)
  -- Reset/clear only from drag bridge (flowgraph) or vehicle hooks; will remake later.
end

--- Marks the racer belonging to a player as DQ+finished when they disconnect mid-race.
local function onDragRacePlayerLeft(player)
  if not player or not player.playerId then return end
  local drag = getDragGamemode()
  if not drag or not drag.isMultiplayer or not drag.isMultiplayer() then return end
  local raceState = getRaceState()
  if not raceState or not raceState.players then return end
  local pd = raceState.players[player.playerId]
  if not pd then return end
  local currentDragData = getData()
  if not currentDragData or not currentDragData.racers then return end
  local racer = nil

  -- Primary lookup by the player's known vehicle ID.
  if pd.vehicleId then
    racer = currentDragData.racers[pd.vehicleId]
    if not racer then
      for _, r in pairs(currentDragData.racers) do
        if r.vehId == pd.vehicleId then
          racer = r
          break
        end
      end
    end
  end

  -- Fallback for MP remap cases where active racer key no longer matches raceState.players[playerId].vehicleId.
  if not racer and pd.lane ~= nil then
    for _, r in pairs(currentDragData.racers) do
      if r.lane == pd.lane then
        racer = r
        break
      end
    end
  end

  if racer and not racer.isFinished then
    markRacerDisqualifiedAndFinished(racer, "Player left")
    log('W', logTag, string.format('Racer for player %s disconnected mid-race; marked DQ+finished', tostring(player.playerId)))
  end
end

--- Resolves the disconnecting client to a player and delegates to onDragRacePlayerLeft.
local function onDragRaceClientDisconnected(client)
  if not client or not client.id then return end
  local drag = getDragGamemode()
  if not drag then return end
  local playerId = drag.getPlayerIdByClientId and drag.getPlayerIdByClientId(client.id)
  if not playerId then return end
  onDragRacePlayerLeft({ playerId = playerId })
end

local function onExtensionLoaded()
  -- Reset/clear only from drag bridge (flowgraph) or vehicle hooks; will remake later.
end



local function allRacersFinished(data)
  if not data or not data.racers or not next(data.racers) then return false end
  for _, racer in pairs(data.racers) do
    if not racer.isFinished then return false end
  end
  return true
end

--- Called by MP host to check if all racers are staged; general only reads data. Returns (allStaged, currentDragData) or (false, nil).
local function getStagingCheckData()
  local drag = getDragGamemode()
  if not drag or not drag.isServerHost or not drag.isServerHost() then return false, nil end
  local raceState = drag.getRaceState and drag.getRaceState() or getRaceState()
  if not raceState or not raceState.isStarted then return false, nil end
  local currentDragData = getData()
  if not currentDragData or not gameplay_drag_phaseHandlers then return false, nil end
  local allStaged, stagedCount, totalCount = gameplay_drag_phaseHandlers.areAllRacersStaged(currentDragData)
  return (allStaged and totalCount > 0 and stagedCount == totalCount), currentDragData
end

--- Called when player leaves the drag strip zone (offline). Clears and unloads drag. Also called from onUpdate when zone check detects player outside.
local function onPlayerLeftDragArea()
  M.clear({ hooks = true, transitionLock = true, localRace = true, extensions = true, data = true, context = true, ui = true, treeLightStaging = true })
end

-- Matches dragStagePlane's showDistance: once the player passes this, the stage guide helper is cleared.
local STAGE_RUNAWAY_CLEAR_DISTANCE = 25

--- While still staging (race not started, not returning from a finished race), running far enough away to clear
--- the stage guide helper also tears down the whole drag system + UI. Offline freeroam only. Must run from
--- core.onUpdate (not display) so the teardown's extension unload doesn't happen mid display update.
local function checkStageRunaway()
  if gameplayContext ~= "freeroam" then return end
  local data = getData()
  if not data or not data.racers then return end
  if not gameplay_drag_phaseHandlers then return end
  if getDragGamemode() and getDragGamemode().isMultiplayer and getDragGamemode().isMultiplayer() then return end

  for _, racer in pairs(data.racers) do
    if racer.isPlayable then
      local phaseName = racer.phases and racer.phases[racer.currentPhase] and racer.phases[racer.currentPhase].name
      if phaseName ~= "stage" then return end
      if racer.currentDistanceFromOrigin == nil then return end
      gameplay_drag_phaseHandlers.calculateDistanceOfAllWheelsFromStagePos(racer)
      local distance = gameplay_drag_phaseHandlers.getFrontWheelDistanceFromStagePos(racer)
      if distance and math.abs(distance) > STAGE_RUNAWAY_CLEAR_DISTANCE then
        onPlayerLeftDragArea()
      end
      return
    end
  end
end

local function finalizeMpPostRace()
  local data = getData()
  if data and data.racers then
    for vehId, _ in pairs(data.racers) do
      if gameplay_drag_display then
        gameplay_drag_display.dragRaceEndLineReached(vehId)
      end
    end
  end

  if gameplay_drag_phaseHandlers then
    gameplay_drag_phaseHandlers.generateWinData()
  end

  doSendTimeslipDataToUi()
end

local function onUpdate(dtReal, dtSim, dtRaw)
  local data = getData()
  if gameplayContext == "freeroam" and data and data.strip and data.strip.stripZone and data.strip.stripZone.containsPoint2D then
    if not (getDragGamemode() and getDragGamemode().isMultiplayer and getDragGamemode().isMultiplayer()) then
      local playerVehId = be:getPlayerVehicleID(0)
      if playerVehId and playerVehId ~= 0 then
        local veh = scenetree.findObjectById(playerVehId)
        if veh and veh.getPosition then
          local pos = veh:getPosition()
          if not data.strip.stripZone:containsPoint2D(pos) then
            onPlayerLeftDragArea()
          end
        end
      end
    end
  end

  checkStageRunaway()

  if gameplay_drag_phaseHandlers then
    if gameplay_drag_phaseHandlers.checkFreeroamDqReStage(dtSim) == "leftArea" then
      onPlayerLeftDragArea()
      return
    end
    gameplay_drag_phaseHandlers.updateRemoteStagingHoldTimers()
  end

  -- Multiplayer and rules-menu updates are owned by their respective extensions.
end

local function onAnyMissionChanged(status, mission)
  if status == "started" or status == "stopped" then
    M.clear({ hooks = true, transitionLock = true, localRace = true, extensions = true, data = true, context = true, ui = true, treeLightStaging = true })
  end
end

local function getCurrentSavePath()
  return gameplay_drag_saveSystem.getCurrentSavePath()
end

local function saveDialTimes(timeslip)
  local currentDragData = getData()
  if currentDragData then
    gameplay_drag_saveSystem.saveDialTimes(currentDragData, timeslip)
  end
end

local function onSaveCurrentProfile(currentSavePath)
  if currentSavePath then
    gameplay_drag_saveSystem.saveDialFile(currentSavePath)
  end
end

local function onCareerActive()
  gameplay_drag_saveSystem.onCareerActive()
end

local function setCareerRewards()
  if rewardsGrantedForCurrentRace then return nil end
  local currentDragData = getData()
  if not career_career.isActive() or (currentDragData and currentDragData.context == "activity") then return nil end
  rewardsGrantedForCurrentRace = true
  local rewards = {bmra = math.ceil(careerRewards)}
  career_modules_playerAttributes.addAttributes(rewards, {label = "ui.career.attributeLog.dragRaceRewards", tags = {"gameplay"}})
  return rewards
end

local function getExtension()
  return dragExtension
end

local function setExtension(ext)
  dragExtension = ext
end


local function getDragDataForLevel(levelIdentifier)

  if not levelDragStrips[levelIdentifier] then
    levelDragStrips[levelIdentifier] = {}

    local levelDir = core_levels.getLevelByName(levelIdentifier).dir
    local settingsFiles = FS:findFiles(levelDir.."/dragstrips/", "*.dragSettings.json", -1, true, false)

    for i, file in ipairs(settingsFiles) do
      local dragData = gameplay_drag_saveSystem.loadDragStripData(file)
      if dragData then
        local _, fn, ext = path.split(file, true)
        dragData._originFile = file
        dragData._fnWithoutExt = string.sub(fn, 1, string.len(fn) - string.len(ext)-1)
        dragData._index = i
        table.insert(levelDragStrips[levelIdentifier], dragData)
      end
    end
  end
  return levelDragStrips[levelIdentifier]
end

--- Number of lanes for strip data (poiData or dragData). Returns at least 1.
local function getMaxLanes(data)
  if not data or not data.strip or not data.strip.lanes then return 2 end
  return math.max(1, #data.strip.lanes)
end

--- Stable key for a drag strip (level:name). Used for one lobby per strip in MP.
local function getPoiKey(poiData)
  if not poiData then return nil end
  local level = (poiData.level and tostring(poiData.level)) or ""
  local name = (poiData._fnWithoutExt and tostring(poiData._fnWithoutExt)) or (poiData.name and tostring(poiData.name)) or ""
  return level .. ":" .. name
end

local function isDragEnabled()
  return career_career.isActive() or settings.getValue("enableDragRaceInFreeroam")
end

-- Public API


M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.loadDragStripData = loadDragStripData
M.loadDragDataForMission = loadDragDataForMission
M.setDragRaceData = setDragRaceData
M.setupRacer = setupRacer

M.setPlayableVehicle = setPlayableVehicle
M.setRacerDial = setRacerDial
M.setRacersDial = setRacersDial
M.startDragRaceActivity = startDragRaceActivity
M.getDragIsStarted = getDragIsStarted
M.getGameplayContext = getGameplayContext
M.getResetState = getResetState
M.calculateStateChecksum = calculateStateChecksum
M.validateResetState = validateResetState

M.getData = getData
M.getRaceState = getRaceState
M.setRaceState = setRaceState
M.clearRaceState = clearRaceState
M.getRacerData = getRacerData
M.getTimers = getTimers

M.onVehicleResetted = onVehicleResetted
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleDestroyed = onVehicleDestroyed

M.onAnyMissionChanged = onAnyMissionChanged

M.getCurrentSavePath = getCurrentSavePath
M.saveDialTimes = saveDialTimes
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onCareerActive = onCareerActive

M.setCareerRewards = setCareerRewards

M.createTimeslipData = function()
  return gameplay_drag_timeslip.createTimeslipData()
end
M.createTimeslipPanelData = function()
  return gameplay_drag_timeslip.createTimeslipPanelData()
end
M.sendTimeslipDataToUi = sendTimeslipDataToUi

M.getExtension = getExtension
M.setExtension = setExtension

M.getMaxLanes = getMaxLanes
M.getPoiKey = getPoiKey
M.getDragDataForLevel = getDragDataForLevel
M.onGetRawPoiListForLevel = function(levelIdentifier, elements)
  gameplay_drag_poi.onGetRawPoiListForLevel(levelIdentifier, elements)
end
M.onGetRawPoiListForTutorial = function(elements) M.onGetRawPoiListForLevel("west_coast_usa", elements) end

M.getDragGamemode = getDragGamemode
M.getStagingCheckData = getStagingCheckData

M.allRacersFinished = allRacersFinished
M.isDragEnabled = isDragEnabled
M.isPoiJoinRequestSent = function(poiKey) return poiJoinRequestSent[poiKey] end
M.setPoiJoinRequestSent = function(poiKey, val)
  if val then poiJoinRequestSent[poiKey] = true else poiJoinRequestSent[poiKey] = nil end
end
M.clearPoiJoinRequest = function(poiKey)
  if poiKey then poiJoinRequestSent[poiKey] = nil end
end

M.onPlayerLeftDragArea = onPlayerLeftDragArea

M.onDragRaceCountdownStart = onDragRaceCountdownStart
M.onDragRaceStart = onDragRaceStart
M.onDragRaceTreeLights = onDragRaceTreeLights
M.onDragRaceWinningLights = onDragRaceWinningLights
M.onDragRaceJoinAccepted = onDragRaceJoinAccepted
M.onDragRaceReset = onDragRaceReset
M.onDragRaceCancelled = onDragRaceCancelled
M.onDragRaceStarted = onDragRaceStarted
M.onDragRaceListChanged = onDragRaceListChanged
M.onDragRacePlayerLeft = onDragRacePlayerLeft
M.onDragRaceClientDisconnected = onDragRaceClientDisconnected

-- In MP, when network timer values arrive, check if we now have values for ALL racers.
-- Once all synced: update display signs, generate win data + winning lights, create timeslip + save history.
M.onDragRaceTimerUpdated = function(raceId, playerId, timerName, timerValue)
  local drag = getDragGamemode()
  if not drag or not drag.isMultiplayer or not drag.isMultiplayer() then return end

  if timerName == "dial" then
    if drag and drag.getActiveDragRace then
      local race = drag.getActiveDragRace()
      if race and race.players and race.players[playerId] then
        local vid = race.players[playerId].vehicleId
        if vid and vid ~= -1 then
          setRacerDial(vid, timerValue)
        end
      end
    end
  end

  local data = getData()
  if data and data.racers and drag and drag.getActiveDragRace then
    local race = drag.getActiveDragRace()
    if race and race.players and race.players[playerId] then
      local pd = race.players[playerId]
      local newVid = pd.vehicleId
      if newVid and newVid ~= -1 and not data.racers[newVid] then
        for vehId, racer in pairs(data.racers) do
          if racer.lane == pd.lane and vehId ~= newVid then
            data.racers[newVid] = racer
            racer.vehId = newVid
            data.racers[vehId] = nil
            break
          end
        end
      end
    end
  end

end

M.finalizeMpPostRace = finalizeMpPostRace

M.onExtensionUnloaded = function()
  M.clear({ hooks = true, transitionLock = true, localRace = true, extensions = true, data = true, context = true, ui = true, treeLightStaging = true })
end

return M