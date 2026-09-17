-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = "drag_flowgraph_bridge"
local liveTimerSentByLane = {}

local function clearLiveTimerCache()
  liveTimerSentByLane = {}
end

local function getNetworkTimersForVehicle(vehId)
  local drag = gameplay_drag_core.getDragGamemode()
  if not drag or not drag.isMultiplayer or not drag.isMultiplayer() then return nil end
  local race = drag.getActiveDragRace and drag.getActiveDragRace()
  if not race or not race.timerValues or not race.players then return nil end
  for pid, tvs in pairs(race.timerValues) do
    local pd = race.players[pid]
    if pd and pd.vehicleId == vehId then
      return tvs
    end
  end
  return nil
end

local function buildLiveTimerEntry(timerDef, timerId, value)
  local val = tonumber(value)
  if not val or val <= 0 then return nil, nil end
  local entry = {
    id = timerId,
    label = timerDef.label or timerId,
    shortLabel = timerDef.shortLabel,
    value = val,
    important = (timerDef.important == true),
  }
  if timerDef.type == "velocity" then
    entry.value_kmh = string.format("%0.3f", val * 3.6)
    entry.value_mph = string.format("%0.3f", val * 2.23694)
  else
    entry.valueStr = string.format("%0.3f", val)
  end
  return entry, val
end

local function pushLiveTimerUpdatesToUi()
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.racers then return end

  local timerConfig = dragData.timers or {}
  if #timerConfig == 0 then return end

  local racerInfos = {}
  for vehId, racer in pairs(dragData.racers) do
    if racer and racer.lane and racer.timers then
      local lane = racer.lane
      if not liveTimerSentByLane[lane] then liveTimerSentByLane[lane] = {} end
      local laneCache = liveTimerSentByLane[lane]
      local netTimers = getNetworkTimersForVehicle(vehId)
      local timerEntries = {}

      for idx, timerDef in ipairs(timerConfig) do
        local timerId = timerDef.id or ("timer_" .. idx)
        local localTimer = racer.timers[timerId]
        local rawValue = nil
        if netTimers and netTimers[timerId] ~= nil then
          rawValue = netTimers[timerId]
        elseif localTimer and localTimer.isSet then
          rawValue = localTimer.value
        end

        local entry, numericValue = buildLiveTimerEntry(timerDef, timerId, rawValue)
        if entry then
          local prevValue = laneCache[timerId]
          if prevValue == nil or math.abs(prevValue - numericValue) > 0.0005 then
            laneCache[timerId] = numericValue
            table.insert(timerEntries, entry)
          end
        end
      end

      if #timerEntries > 0 then
        table.insert(racerInfos, {
          laneNum = lane,
          timerEntries = timerEntries,
        })
      end
    end
  end

  if #racerInfos > 0 then
    guihooks.trigger("onDragRaceLiveTimesData", { racerInfos = racerInfos })
  end
end

--- Loads drag strip by ID: tries loadCompleteDragRaceData then loadDragStripData. Returns strip data or nil.
M.loadDragStrip = function(dragStripId)
  if not dragStripId then
    log('E', logTag, 'No drag strip ID provided for loading')
    return nil
  end
  local dragStrip = gameplay_drag_saveSystem.loadCompleteDragRaceData(dragStripId)
  if dragStrip then return dragStrip end
  dragStrip = gameplay_drag_saveSystem.loadDragStripData(dragStripId)
  if dragStrip then
    return dragStrip
  end

  log('E', logTag, 'Failed to load drag strip: ' .. tostring(dragStripId))
  return nil
end

--- Compatibility: returns true if dragStrip is non-nil. Config is applied via setDragRaceData in general.
M.configureDragStrip = function(dragStrip)
  return dragStrip ~= nil
end

--- Starts a drag race; delegates to general.startDragRaceActivity(lane or 1).
M.startDragRace = function(vehicleId, lane)
  local veh = vehicleId and scenetree.findObjectById(vehicleId) or be:getPlayerVehicle(0)
  if not veh then
    log('E', logTag, 'No valid vehicle found')
    return false
  end
  return gameplay_drag_core.startDragRaceActivity(lane or 1) or true
end

--- Clears current drag data (stops race). Uses general.clear().
M.stopDragRace = function()
  gameplay_drag_core.clear({ hooks = true, transitionLock = true, localRace = true, extensions = true, data = true, context = true, ui = true, treeLightStaging = true })
  return true
end

--- Resets race state. No args = full reset. Otherwise forwards the options table to core.reset(opts).
M.reset = function(opts)
  local data = gameplay_drag_core.getData()
  if not data then return false end
  if not opts then
    gameplay_drag_core.reset({ raceState = true, racers = true, timeslip = true, transitionLock = true, treeLightStaging = true, hooks = true })
  else
    gameplay_drag_core.reset(opts)
  end
  return true
end

--- Returns playable racer data (vehicleId, lane, timers, phases, isFinished, etc.) or nil.
M.getDragRaceData = function()
  local dragData = gameplay_drag_core.getData()
  if not dragData then return nil end
  local activeId
  for vehId, racer in pairs(dragData.racers or {}) do
    if racer.isPlayable then activeId = vehId break end
  end
  if not activeId then return nil end
  local racerData = gameplay_drag_core.getRacerData(activeId)
  if not racerData then return nil end
  return {
    vehicleId = activeId,
    lane = racerData.lane,
    timers = racerData.timers,
    isFinished = racerData.isFinished,
    isDisqualified = (racerData.isDisqualified ~= nil and racerData.isDisqualified) or racerData.isDesqualified,
    disqualificationReason = racerData.disqualifiedReason or racerData.desqualifiedReason,
    currentPhase = racerData.currentPhase,
    damage = racerData.damage,
    phases = racerData.phases
  }
end

--- Returns runtime data for playable racer (phase, position, speed, timers, etc.) or nil.
M.getDragRaceRuntimeData = function()
  local dragData = gameplay_drag_core.getData()
  if not dragData then return nil end
  local activeId
  for vehId, racer in pairs(dragData.racers or {}) do
    if racer.isPlayable then activeId = vehId break end
  end
  if not activeId then return nil end
  local racerData = gameplay_drag_core.getRacerData(activeId)
  if not racerData then return nil end
  return {
    vehicleId = activeId,
    lane = racerData.lane,
    currentPhase = racerData.currentPhase,
    isStarted = dragData.isStarted,
    isCompleted = dragData.isCompleted,
    timers = racerData.timers,
    phases = racerData.phases,
    isDisqualified = (racerData.isDisqualified ~= nil and racerData.isDisqualified) or racerData.isDesqualified,
    disqualificationReason = racerData.disqualifiedReason or racerData.desqualifiedReason,
    damage = racerData.damage,
    vehiclePosition = racerData.vehPos,
    vehicleSpeed = racerData.vehSpeed
  }
end

--- Returns strip info (stripName, dragType, context, lanes, phases, prefabs) for dragStripId or current data.
M.getDragStripInfo = function(dragStripId)
  local dragStrip = nil
  if dragStripId then
    dragStrip = gameplay_drag_saveSystem.loadCompleteDragRaceData(dragStripId)
  else
    local data = gameplay_drag_core.getData()
    dragStrip = data and { strip = data.strip, dragType = data.dragType, context = data.context, phases = data.phases, prefabs = data.prefabs, canBeTeleported = data.canBeTeleported, canBeReseted = data.canBeReseted } or nil
  end
  if not dragStrip then return nil end
  if dragStrip.strip then
    return {
      stripName = dragStrip.strip.name or (dragStrip.stripInfo and dragStrip.stripInfo.stripName) or "Drag Strip",
      dragType = dragStrip.dragType or "drag",
      context = dragStrip.context or "freeroam",
      lanes = dragStrip.strip.lanes,
      phases = dragStrip.phases or {},
      prefabs = dragStrip.prefabs or {},
      canBeTeleported = dragStrip.canBeTeleported ~= false,
      canBeReseted = dragStrip.canBeReseted ~= false,
    }
  end
  return nil
end

--- Returns true if a drag race is started (countdown or running).
M.isDragRaceActive = function()
  return gameplay_drag_core.getDragIsStarted()
end

--- Returns vehicle ID of the playable racer, or nil.
M.getActiveRacerId = function()
  local data = gameplay_drag_core.getData()
  if not data then return nil end
  for vehId, racer in pairs(data.racers or {}) do
    if racer.isPlayable then return vehId end
  end
  return nil
end

local function getPropertyValue(obj, path)
  local current = obj
  for _, key in ipairs(path) do
    if current == nil then
      log("E", logTag, "Property path not found: " .. dump(path))
      return
    end
    current = current[key]
  end
  return current
end

local function checkVehiclePermission(model, rules)
  for _, rule in ipairs(rules) do
    local propertyValue = getPropertyValue(model, rule.path)

    if rule.allowedValues then
      local found = false
      for _, allowedValue in ipairs(rule.allowedValues) do
        if propertyValue == allowedValue then
          found = true
          break
        end
      end
      if not found then
        log("E", logTag, "Vehicle " .. model.model .. " does not match rule: " .. dump(rule.path))
        return false
      end
    elseif rule.value ~= nil then
      if propertyValue ~= rule.value then
        log("E", logTag, "Vehicle " .. model.model .. " does not match rule: " .. dump(rule.path))
        return false
      end
    end
  end
  return true
end

--- Builds a list of opponent configs (model, config, paint) matching dial time and vehicle permission rules.
M.generateOpponentsGroup = function(vehId, dial, vehiclePermissionRules, amount, offset)
  if not vehId then
    log("E", logTag, "Invalid input parameters")
    return
  end

  amount = amount or 1
  offset = offset or 0.5

  local configs = core_vehicles.getConfigList()
  local vehicleDetails = core_vehicles.getVehicleDetails(vehId)
  if not vehicleDetails then
    log("E", logTag, "Could not find vehicle details for ID: " .. tostring(vehId))
    return
  end

  if not vehicleDetails.configs["Drag Times"] then
    log("E", logTag, "Vehicle has no drag times data")
    return
  end

  local quarterMileScore = dial or vehicleDetails.configs["Drag Times"].time_1_4 or 10
  local minTime = quarterMileScore - offset
  local maxTime = quarterMileScore + 0.1

  local eligibleVehicles = {}
  local eligibleCount = 0

  for _, config in pairs(configs.configs) do
    if config["Drag Times"] and config["Drag Times"].time_1_4 and config["Drag Times"].time_1_4 >= minTime and config["Drag Times"].time_1_4 < maxTime then
      local model = core_vehicles.getModel(config.model_key).model
      if checkVehiclePermission(model, vehiclePermissionRules) and not string.match(config.key, 'simple_traffic') then
        eligibleCount = eligibleCount + 1
        eligibleVehicles[eligibleCount] = config
      end
    end
  end

  if eligibleCount == 0 then
    eligibleVehicles[1] = vehicleDetails
    eligibleCount = 1
  end

  local opponentsGroup = {}
  for i = 1, amount do
    local selectedConfig = eligibleVehicles[math.random(eligibleCount)]
    local paints = tableKeys(tableValuesAsLookupDict(core_vehicles.getModel(selectedConfig.model_key).model.paints or {}))
    local paintCount = #paints

    table.insert(opponentsGroup, {
      model = selectedConfig.model_key,
      config = selectedConfig.key,
      paint = paintCount > 0 and paints[math.random(paintCount)] or nil,
    })
  end
  return opponentsGroup
end

M.setupRacer = function(vehicleId, lane)
  return gameplay_drag_core.setupRacer(vehicleId, lane)
end

--- Sets multiple racers from vehicleIds (array of { id, lane, isPlayable, dial }).
M.setVehicles = function(vehicleIds)
  local dragData = M.getData()
  if not dragData then
    log("E", logTag, "No drag data available for setting vehicles")
    return
  end

  for _, data in ipairs(vehicleIds) do
    M.setupRacer(data.id, data.lane)
    if not dragData.racers[data.id] then
      log("E", logTag, "There is a problem with the vehicle setting, vehicle has not been set correctly.")
      return
    end
    dragData.racers[data.id].isPlayable = data.isPlayable
    if data.dial and data.dial > 0 then
      dragData.racers[data.id].timers.dial.value = data.dial
    end
  end
end

--- Returns timers table for vehicleId, or {}.
M.getTimers = function(vehicleId)
  local dragData = gameplay_drag_core.getData()
  if not dragData then return {} end
  if not dragData.racers[vehicleId] then return {} end
  return dragData.racers[vehicleId].timers or {}
end

M.getData = function()
  return gameplay_drag_core.getData()
end

--- Returns full racer table for vehicleId, or {}.
M.getRacerData = function(vehicleId)
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.racers[vehicleId] then return {} end
  return dragData.racers[vehicleId] or {}
end

--- Loads drag data from file, loads prefabs, sets context and drag type extension.
M.loadDragDataForMission = function(filepath)
  local data = gameplay_drag_core.loadDragDataForMission(filepath)
  if not data then
    log("E", logTag, "Failed to load drag data from file: " .. tostring(filepath))
    return
  end
  return data
end

M.startDragRaceActivity = function(lane)
  return gameplay_drag_core.startDragRaceActivity(lane)
end

--- Removes all racers from current drag data. Uses general.reset(..., clearRacers=true).
M.clearRacers = function()
  gameplay_drag_core.reset({ clearRacers = true })
end

M.setRacerDial = function(vehicleId, dialValue)
  return gameplay_drag_core.setRacerDial(vehicleId, dialValue)
end

M.setRacersDial = function(dials)
  return gameplay_drag_core.setRacersDial(dials)
end

--- Clears drag data and unloads extensions. Uses general.clear().
M.unloadRace = function()
  gameplay_drag_core.clear({ hooks = true, transitionLock = true, localRace = true, extensions = true, data = true, context = true, ui = true, treeLightStaging = true })
end

M.getDialTimes = function()
  return gameplay_drag_saveSystem.getDialTimes()
end

M.generateHashFromFile = function(vehicleId)
  if vehicleId then
    return gameplay_drag_saveSystem.generateHashFromFile(vehicleId)
  else
    return gameplay_drag_saveSystem.generateHashFromFile(be:getPlayerVehicleID(0))
  end
end

M.getDragIsStarted = function()
  local dragData = gameplay_drag_core.getData()
  if not dragData then return false end
  return dragData.isStarted or false
end

M.getWinnersData = function()
  return gameplay_drag_phaseHandlers.generateWinData()
end

M.getPlayerRaceResult = function()
  local winners = M.getWinnersData() or {}
  local playerPos = nil
  for i, entry in ipairs(winners) do
    if entry and entry.isPlayable then
      playerPos = i
      break
    end
  end
  return {
    playerWin = playerPos == 1,
    playerPos = playerPos,
    winners = winners,
  }
end

M.createTimeslipData = function()
  return gameplay_drag_core.createTimeslipData()
end

M.sendTimeslipDataToUi = function()
  return gameplay_drag_core.sendTimeslipDataToUi()
end

M.screenshotTimeslip = function()
  return gameplay_drag_timeslip.screenshotTimeslip()
end

M.clearTimeslip = function()
  gameplay_drag_core.reset({ timeslip = true })
end

M.getHistory = function(id)
  return gameplay_drag_saveSystem.getHistory(id)
end

local dragTetherRange = 4
local tether

--- Opens drag history UI for facility; starts tether if career active.
M.openHistoryScreen = function(facility)
  local dragPos = freeroam_facilities.getClosestDoorPositionForFacility(facility)
  if career_career.isActive() and dragPos then
    tether = career_modules_tether.startSphereTether(dragPos, dragTetherRange, M.closeMenu)
  end
  extensions.ui_router.navigate("mission.dragHistory", {id = facility.id, name = facility.name, level = facility.level})
end

--- Opens Vue drag rules & setup screen for facility; starts tether if career active.
--- For testing: also opens IMGUI rules menu with only the Multiplayer tab.
M.openRulesScreen = function(facility)
  local dragPos = freeroam_facilities.getClosestDoorPositionForFacility(facility)
  if career_career.isActive() and dragPos then
    tether = career_modules_tether.startSphereTether(dragPos, dragTetherRange, M.closeMenu)
  end
  local levelId = getCurrentLevelIdentifier()
  extensions.ui_router.navigate("mission.dragRules", { id = facility.id, level = levelId or facility.level })
end

--- Opens Vue drag rules screen by strip id (e.g. from MP gamemode UI). Same backend as POI rules; host can change rules at any time.
M.openRulesScreenForStrip = function(levelId, stripId)
  if not levelId or not stripId then return end
  extensions.ui_router.navigate("mission.dragRules", { id = stripId, level = levelId })
end

--- Returns data for Vue rules screen. Uses same method as IMGUI (loadDragDataForFacility). Forward to rulesMenu.
M.getRulesScreenData = function(facilityIdOrStripId)
  if not gameplay_drag_rulesMenu then return nil end
  return gameplay_drag_rulesMenu.getRulesScreenData(facilityIdOrStripId)
end

--- Persists rules for strip. Forward to rulesMenu. In MP, also broadcast to all clients and update live dragData.
M.applyRulesSave = function(levelId, stripId, rules)
  gameplay_drag_rulesMenu.applyRulesSave(levelId, stripId, rules)
  -- In MP as host, broadcast rules to all clients so they take effect without restarting the session
  local drag = gameplay_drag_core.getDragGamemode()
  if drag and drag.isMultiplayer and drag.isMultiplayer() and drag.broadcastRulesUpdate then
    drag.broadcastRulesUpdate(rules)
  end
  -- Also update current live dragData so rules take effect immediately for timeslip/display
  local data = gameplay_drag_core.getData()
  if data then
    if rules.importantTimerId then data.importantTimerId = rules.importantTimerId end
    if rules.dragType then data.dragType = rules.dragType end
    if rules.treeType then
      if not data.prefabs then data.prefabs = {} end
      if not data.prefabs.christmasTree then data.prefabs.christmasTree = {} end
      data.prefabs.christmasTree.treeType = rules.treeType
    end
  end
end

--- Returns saved rules for strip. Forward to rulesMenu.
M.applyRulesRestore = function(levelId, stripId)
  if not gameplay_drag_rulesMenu then return nil end
  return gameplay_drag_rulesMenu.applyRulesRestore(levelId, stripId)
end

--- Clears tether when menu is closed.
M.onMenuClosed = function()
  if tether then tether.remove = true tether = nil end
end

M.closeMenu = function()
  career_career.closeAllMenus()
end

--- Stops drag race if one is active.
M.cleanup = function()
  if gameplay_drag_core.getDragIsStarted() then
    M.stopDragRace()
  end
end

-- UI helpers (called from Vue via lua bridge)

--- Returns all display data for the drag info HUD widget, or nil when no race is loaded.
M.getDragInfoData = function()
  local data = gameplay_drag_core.getData()
  if not data then return nil end

  local activeId = M.getActiveRacerId()
  local phaseName = nil
  local dialValue = nil
  if activeId then
    local racer = gameplay_drag_core.getRacerData(activeId)
    if racer then
      if racer.currentPhase and racer.phases and racer.phases[racer.currentPhase] then
        phaseName = racer.phases[racer.currentPhase].name
      end
      if data.dragType == "bracketRace" and racer.timers and racer.timers.dial then
        dialValue = racer.timers.dial.value
      end
    end
  end

  local treeType = data.prefabs and data.prefabs.christmasTree and data.prefabs.christmasTree.treeType or ".500"
  local treeNames = {[".400"] = "Pro Tree ( .400 )", [".500"] = "Sportsman Tree ( .500 )"}
  local phaseNames = {stage = "Staging", countdown = "On Tree", race = "Racing", stop = "Stopping"}

  local importantTimerId = data.importantTimerId or "time_1_4"
  local importantTimerLabel = importantTimerId
  if data.timers then
    for _, t in ipairs(data.timers) do
      if t.id == importantTimerId then
        importantTimerLabel = t.label or importantTimerId
        break
      end
    end
  end

  local drag = gameplay_drag_core.getDragGamemode()
  local isMP = drag and drag.isMultiplayer and drag.isMultiplayer()
  local raceState = isMP and gameplay_drag_core.getRaceState() or nil
  local mpPlayers = raceState and raceState.players or nil
  local localPlayerId = isMP and drag.getLocalPlayerId and drag.getLocalPlayerId() or nil

  -- Build a lane-to-player lookup from the current heat slot for MP name resolution
  local laneToPlayer = {}
  if isMP and raceState then
    local queue = raceState.queue or {}
    local heatIdx = (raceState.currentPairIndex or 0) > 0 and raceState.currentPairIndex or 1
    local slot = queue[heatIdx]
    if type(slot) == "table" then
      for lane, pid in pairs(slot) do
        if pid and mpPlayers and mpPlayers[pid] then
          laneToPlayer[lane] = { playerId = pid, persona = mpPlayers[pid].persona or mpPlayers[pid].configName or "Player" }
        end
      end
    end
  end

  local racersList = {}
  if data.racers then
    for vehId, racer in pairs(data.racers) do
      local rPhaseName = nil
      if racer.currentPhase and racer.phases and racer.phases[racer.currentPhase] then
        rPhaseName = racer.phases[racer.currentPhase].name
      end
      local rDialValue = nil
      if data.dragType == "bracketRace" and racer.timers and racer.timers.dial then
        rDialValue = racer.timers.dial.value
      end
      local racerName = vehId == activeId and "You" or "Bot"
      if isMP then
        local lp = laneToPlayer[racer.lane]
        if lp then
          racerName = (lp.playerId == localPlayerId) and "You" or lp.persona
        end
      end
      table.insert(racersList, {
        isLocal        = vehId == activeId,
        name           = racerName,
        lane           = racer.lane or 0,
        phase          = rPhaseName,
        phaseLabel     = phaseNames[rPhaseName] or "Ready",
        dialValue      = rDialValue,
        dialValueStr   = rDialValue and string.format("%0.2f", rDialValue) or nil,
        isFinished     = racer.isFinished     or false,
        isDisqualified = ((racer.isDisqualified ~= nil and racer.isDisqualified) or racer.isDesqualified) or false,
      })
    end
    table.sort(racersList, function(a, b) return (a.lane or 0) < (b.lane or 0) end)
  end

  -- MP heat queue and waiting list
  local currentHeat = nil
  local totalHeats = nil
  local waitingList = {}
  if isMP and raceState then
    local queue = raceState.queue or {}
    totalHeats = #queue
    currentHeat = (raceState.currentPairIndex or 0) > 0 and raceState.currentPairIndex or 1

    local currentHeatPlayerIds = {}
    if queue[currentHeat] and type(queue[currentHeat]) == "table" then
      for _, pid in pairs(queue[currentHeat]) do
        if pid then currentHeatPlayerIds[pid] = true end
      end
    end

    if mpPlayers then
      for heatIdx = 1, #queue do
        if heatIdx ~= currentHeat then
          local slot = queue[heatIdx]
          if type(slot) == "table" then
            for laneIdx, pid in pairs(slot) do
              if pid and mpPlayers[pid] then
                local pd = mpPlayers[pid]
                local pName = (pid == localPlayerId) and "You" or (pd.persona or "Player")
                table.insert(waitingList, { name = pName, heat = heatIdx, lane = laneIdx, playerId = pid })
              end
            end
          end
        end
      end
      table.sort(waitingList, function(a, b)
        if a.heat ~= b.heat then return a.heat < b.heat end
        return a.lane < b.lane
      end)
    end
  end

  return {
    dragType             = data.dragType,
    isBracketRace        = data.dragType == "bracketRace",
    stripName            = data.strip and data.strip.name or "",
    treeType             = treeType,
    treeTypeLabel        = treeNames[treeType] or treeType,
    importantTimerId     = importantTimerId,
    importantTimerLabel  = importantTimerLabel,
    dialValue            = dialValue,
    isStarted            = data.isStarted   or false,
    isCompleted          = data.isCompleted or false,
    currentPhase         = phaseName,
    racers               = racersList,
    isMultiplayer        = isMP or false,
    currentHeat          = currentHeat,
    totalHeats           = totalHeats,
    waitingList          = waitingList,
  }
end

M.getTreeLightUIState = function()
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.racers or not dragData.strip or not dragData.strip.treeLights then return nil end

  local lane, isStaging = nil, false
  for _, racer in pairs(dragData.racers) do
    if racer.isPlayable then
      lane = racer.lane
      local phaseName = racer.currentPhase and racer.phases and racer.phases[racer.currentPhase] and racer.phases[racer.currentPhase].name
      isStaging = phaseName == "stage"
      break
    end
  end
  if not lane then return nil end

  local laneTree = dragData.strip.treeLights[lane]
  if not laneTree then return nil end

  local function isOn(light)
    return (light and light.isOn) or false
  end

  local globalBlueLight = dragData.strip.treeLights[1] and dragData.strip.treeLights[1].globalLights and dragData.strip.treeLights[1].globalLights.blueLight

  return {
    isStaging = isStaging,
    stageLights = {
      prestageLight = isOn(laneTree.stageLights and laneTree.stageLights.prestageLight),
      stageLight = isOn(laneTree.stageLights and laneTree.stageLights.stageLight),
    },
    countDownLights = {
      amberLight1 = isOn(laneTree.countDownLights and laneTree.countDownLights.amberLight1),
      amberLight2 = isOn(laneTree.countDownLights and laneTree.countDownLights.amberLight2),
      amberLight3 = isOn(laneTree.countDownLights and laneTree.countDownLights.amberLight3),
      greenLight = isOn(laneTree.countDownLights and laneTree.countDownLights.greenLight),
      redLight = isOn(laneTree.countDownLights and laneTree.countDownLights.redLight),
    },
    globalLights = {
      blueLight = isOn(globalBlueLight),
    },
  }
end

--- Returns dial data for the local playable racer, or nil when unavailable.
M.getDragDialData = function()
  local data = gameplay_drag_core.getData()
  if not data then return nil end
  local activeId = M.getActiveRacerId()
  if not activeId then return nil end
  local racer = gameplay_drag_core.getRacerData(activeId)
  if not racer then return nil end
  local dialTimer = racer.timers and racer.timers.dial
  local importantTimerId    = data.importantTimerId or "time_1_4"
  local importantTimerLabel = importantTimerId
  if data.timers then
    for _, t in ipairs(data.timers) do
      if t.id == importantTimerId then
        importantTimerLabel = t.label or importantTimerId
        break
      end
    end
  end
  return {
    vehicleId           = activeId,
    dialValue           = dialTimer and dialTimer.value or 10,
    isSet               = dialTimer and dialTimer.isSet  or false,
    importantTimerId    = importantTimerId,
    importantTimerLabel = importantTimerLabel,
    isBracketRace       = data.dragType == "bracketRace",
  }
end

--- Sets the dial for the local playable racer. Convenience wrapper so Vue doesn't need to resolve vehicleId.
M.setLocalPlayerDial = function(value)
  local activeId = M.getActiveRacerId()
  if not activeId then return false end
  local result = gameplay_drag_core.setRacerDial(activeId, value) or false
  guihooks.trigger("dragRaceInfoChanged", M.getDragInfoData())
  return result
end

--- Shows the dial control panel in the topLeft utility apps container.
M.showDialControl = function()
  ui_appContainers.showApp("topLeft", "dragDialControl")
end

--- Returns lane info for the first strip on the current level.
M.getStripLaneInfo = function()
  local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier()
  if not levelId then return nil end
  local core = gameplay_drag_core
  if not core or not core.getDragDataForLevel then return nil end
  local list = core.getDragDataForLevel(levelId)
  if not list then return nil end
  for _, data in pairs(list) do
    if data.strip and data.strip.lanes then
      local lanes = {}
      for i, lane in ipairs(data.strip.lanes) do
        lanes[i] = {
          index = i,
          longName = lane.longName or ("Lane " .. i),
          shortName = lane.shortName or tostring(i),
          color = lane.color or nil,
        }
      end
      local timers = data.timers or gameplay_drag_saveSystem.DEFAULT_TIMERS
      return { lanes = lanes, timers = timers, importantTimerId = data.importantTimerId or "time_1_4" }
    end
  end
  return nil
end

-- Extension hooks: push UI updates when drag state changes

M.onDragRacersSetup = function(data)
  clearLiveTimerCache()
  guihooks.trigger("dragRaceInfoChanged", M.getDragInfoData())
  guihooks.trigger("dragDialDataChanged",  M.getDragDialData())
end

M.onDragDataSet = function(data)
  clearLiveTimerCache()
  guihooks.trigger("dragRaceInfoChanged", M.getDragInfoData())
  guihooks.trigger("dragDialDataChanged",  M.getDragDialData())
  ui_appContainers.showApp("topLeft", "dragInfo")
end

M.onDragReset = function(opts)
  clearLiveTimerCache()
  guihooks.trigger("dragRaceInfoChanged", M.getDragInfoData())
  guihooks.trigger("dragDialDataChanged",  M.getDragDialData())
  guihooks.trigger("onDragReset")
end

M.onDragClear = function()
  clearLiveTimerCache()
  guihooks.trigger("dragRaceInfoChanged", nil)
  guihooks.trigger("dragDialDataChanged",  nil)
  ui_appContainers.hideApp("topLeft", "dragInfo")
  ui_appContainers.hideApp("topLeft", "dragDialControl")
end

M.onRacerPhaseTransition = function(vehId, oldPhase, newPhase, newPhaseName)
  guihooks.trigger("dragRaceInfoChanged", M.getDragInfoData())
end

M.onDragRacePlayersUpdated = function()
  guihooks.trigger("dragRaceInfoChanged", M.getDragInfoData())
end

M.onDragRaceStateChanged = function()
  guihooks.trigger("dragRaceInfoChanged", M.getDragInfoData())
end

M.onDragRaceListChanged = function()
  guihooks.trigger("dragRaceInfoChanged", M.getDragInfoData())
end

M.onDragRaceStarted = function()
  clearLiveTimerCache()
  guihooks.trigger("dragRaceInfoChanged", M.getDragInfoData())
end

M.onUpdate = function()
  pushLiveTimerUpdatesToUi()
end

return M
