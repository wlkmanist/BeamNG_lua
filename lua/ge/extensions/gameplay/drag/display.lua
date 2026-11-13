-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'gameplay_drag_core', 'gameplay_drag_phaseHandlers'}
local logTag = ""

local rand
local stagedAmount = 0
local flashTime = 1.5
local pendingTreeLightAppUpdates = {}
local stageGuideMarkers = {} -- key: vehId, value: race_marker instance (one per staging racer, so multiseat players each get their own)

M.alwaysShowStageApp = true

local driverLightBlinkState = {
  lane = nil,
  isBlinking = false,
  timer = 0,
  frequency = 1/6, -- 6Hz = 1/6 seconds per cycle
  isOn = false,
  blinkCount = 0,
  maxBlinks = 6
}

local clearFlashStripCache = nil
local clearFlashUpdateActive = false
local playerIndexByVehId = {}
local multiseatEventNameCache = {}
local lightStages = {
  {1.0, 1.5, "amberLight1", false},
  {1.5, 2.0, "amberLight1", true, "amberLight2", false},
  {2.0, 2.5, "amberLight2", true, "amberLight3", false},
  {2.5, math.huge, "amberLight3", true, "greenLight", false}
}

local function getDrag()
  return gameplay_drag_core.getDragGamemode()
end

local function shouldSync()
  local drag = getDrag()
  return drag and drag.shouldSyncState and drag.shouldSyncState()
end

local function flashMessage(msg, duration)
  duration = duration or flashTime

  ui_appContainers.showApp('topCenter', 'flashMessage')
  guihooks.trigger('TopCenterAppsFlashMessage', { msg = msg, ttl = duration, big = false })
  guihooks.trigger('ScenarioFlashMessage', { msg = msg, ttl = duration, big = false })
end

local function isMultiseatHudActive()
  return core_multiseat
    and core_multiseat.isMultiseatActive
    and core_multiseat.isMultiseatActive()
    or false
end

local function vehicleIdsMatch(a, b)
  if a == nil or b == nil then return false end
  if a == b then return true end
  local na, nb = tonumber(a), tonumber(b)
  return na ~= nil and nb ~= nil and na == nb
end

local function getPlayerIndexForVehicle(vehId)
  if vehId == nil then return nil end
  local cached = playerIndexByVehId[vehId]
  if cached ~= nil then return cached end

  if ui_multiseat_multiseatVehicles and ui_multiseat_multiseatVehicles.getOwnedVehicles then
    for _, entry in ipairs(ui_multiseat_multiseatVehicles.getOwnedVehicles() or {}) do
      local ownedId = entry.vehId
      if ownedId == nil and entry.veh and entry.veh.getId then
        ownedId = entry.veh:getId()
      end
      if vehicleIdsMatch(ownedId, vehId) then
        playerIndexByVehId[vehId] = entry.player
        return entry.player
      end
    end
  end

  if not core_multiseat or not core_multiseat.getJoinedPlayers then return nil end
  for _, player in ipairs(core_multiseat.getJoinedPlayers() or {}) do
    local playerVehId = be:getPlayerVehicleID(player)
    if playerVehId and playerVehId ~= -1 and vehicleIdsMatch(playerVehId, vehId) then
      playerIndexByVehId[vehId] = player
      return player
    end
  end
  return nil
end

local function multiseatEventName(playerIndex, eventName)
  local byPlayer = multiseatEventNameCache[playerIndex]
  if not byPlayer then
    byPlayer = {}
    multiseatEventNameCache[playerIndex] = byPlayer
  end
  local name = byPlayer[eventName]
  if not name then
    name = string.format("multiseatDrag.%s.%s", tostring(playerIndex), eventName)
    byPlayer[eventName] = name
  end
  return name
end

local function triggerMultiseatTreeEvent(playerIndex, eventName, ...)
  if playerIndex == nil then return end
  guihooks.trigger(multiseatEventName(playerIndex, eventName), ...)
end

local function broadcastTreeLightStaging(visible)
  local isVisible = visible and true or false
  guihooks.trigger("updateTreeLightStaging", isVisible)
  if not isMultiseatHudActive() or not core_multiseat or not core_multiseat.getJoinedPlayers then return end
  for _, playerIndex in ipairs(core_multiseat.getJoinedPlayers() or {}) do
    triggerMultiseatTreeEvent(playerIndex, "updateTreeLightStaging", isVisible)
  end
end

local function triggerMultiseatTreeEventForLane(lane, eventName, ...)
  if lane == nil then return end
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.racers then return end

  for vehId, racer in pairs(dragData.racers) do
    if racer and not racer.vehicleRemoved and racer.lane == lane then
      local playerIndex = getPlayerIndexForVehicle(vehId)
      if playerIndex ~= nil then
        triggerMultiseatTreeEvent(playerIndex, eventName, ...)
      end
    end
  end
end

local function clearMultiseatTreeUi()
  if not core_multiseat or not core_multiseat.getJoinedPlayers then return end
  local clearedLights = {
    stageLights = { prestageLight = false, stageLight = false },
    countDownLights = {
      amberLight1 = false,
      amberLight2 = false,
      amberLight3 = false,
      greenLight = false,
      redLight = false,
    },
    globalLights = { blueLight = false },
  }
  for _, playerIndex in ipairs(core_multiseat.getJoinedPlayers() or {}) do
    triggerMultiseatTreeEvent(playerIndex, "updateTreeLightStaging", false)
    triggerMultiseatTreeEvent(playerIndex, "updateTreeLightDistance", 0, false)
    triggerMultiseatTreeEvent(playerIndex, "updateTreeLightApp", deepcopy(clearedLights))
  end
end

local function createStageGuideMarker(vehId)
  local marker = stageGuideMarkers[vehId]
  if marker then return marker end
  marker = require("scenario/race_marker").createRaceMarker(true, "dragStagePlane")
  if marker then
    marker:setMode("default")
    stageGuideMarkers[vehId] = marker
  end
  return marker
end

--- Clears one racer's marker (vehId given) or every marker (vehId omitted).
local function clearStageGuideMarker(vehId)
  if vehId ~= nil then
    local marker = stageGuideMarkers[vehId]
    if marker then
      marker:clearMarkers()
      stageGuideMarkers[vehId] = nil
    end
    return
  end
  for id, marker in pairs(stageGuideMarkers) do
    marker:clearMarkers()
    stageGuideMarkers[id] = nil
  end
end

local function resolveSceneObject(stripId, lightId, laneIndex, optional)
  local name = laneIndex and (stripId .. "_" .. lightId .. "_" .. laneIndex) or (stripId .. "_" .. lightId)
  local obj = scenetree.findObject(name)
  if not obj then
    if optional then
      log("D", logTag, "Optional scene object not found: " .. name)
    else
      log("E", logTag, "Scene object not found: " .. name .. " — must be named <stripId>_<lightId>_<laneIndex>")
    end
  end
  return obj
end

-- Optional SpotLight/PointLight companions on the mesh object name:
--   <meshName>_light                         staging, blue, winners, scoreboard
--   <meshName>_topBar_light                  winTimeboard top bar (with _light for the digits)
--   <meshName>_light_forward / _backward     tree amber, green, red only
local function isDirectionalTreeLightId(lightId)
  return lightId == "amber1" or lightId == "amber2" or lightId == "amber3" or lightId == "green" or lightId == "red"
end

local function resolveLightSources(stripId, lightId, laneIndex)
  local srcObjs = {}
  local baseName = laneIndex and (stripId .. "_" .. lightId .. "_" .. laneIndex) or (stripId .. "_" .. lightId)
  if isDirectionalTreeLightId(lightId) then
    local forward = scenetree.findObject(baseName .. "_light_forward")
    if forward then srcObjs[#srcObjs + 1] = forward end
    local backward = scenetree.findObject(baseName .. "_light_backward")
    if backward then srcObjs[#srcObjs + 1] = backward end
  else
    local obj = scenetree.findObject(baseName .. "_light")
    if obj then srcObjs[#srcObjs + 1] = obj end
    if lightId == "winTimeboard" then
      local topBar = scenetree.findObject(baseName .. "_topBar_light")
      if topBar then srcObjs[#srcObjs + 1] = topBar end
    end
  end
  return srcObjs
end

local function setLightSourceEnabled(lightObj, enabled)
  if not lightObj or not simObjectExists(lightObj) then return end
  if lightObj.setLightEnabled then
    lightObj:setLightEnabled(enabled)
  end
end

local function setLightSourcesEnabled(srcObjs, enabled)
  if not srcObjs then return end
  for i = 1, #srcObjs do
    setLightSourceEnabled(srcObjs[i], enabled)
  end
end

local function setTreeLightObjectHidden(light, hidden)
  if not light then return end
  if light.obj and simObjectExists(light.obj) then
    light.obj:setHidden(hidden)
  end
  setLightSourcesEnabled(light.srcObjs, not hidden)
end

local function createDragLightEntry(stripId, lightId, laneIndex, optional, anim)
  return {
    obj = resolveSceneObject(stripId, lightId, laneIndex, optional),
    srcObjs = resolveLightSources(stripId, lightId, laneIndex),
    anim = anim,
    isOn = false,
  }
end

local function createTreeLightsForLane(stripId, laneIndex)
  return {
    stageLights = {
      prestageLight = createDragLightEntry(stripId, "prestage",     laneIndex, false, "prestage"),
      stageLight    = createDragLightEntry(stripId, "stage",        laneIndex, false, "prestage"),
      winnerLight   = createDragLightEntry(stripId, "winTimeboard", laneIndex, true,  "prestage"),
      driverLight   = createDragLightEntry(stripId, "winDriver",    laneIndex, true,  "prestage"),
    },
    countDownLights = {
      amberLight1 = createDragLightEntry(stripId, "amber1", laneIndex, false, "tree"),
      amberLight2 = createDragLightEntry(stripId, "amber2", laneIndex, false, "tree"),
      amberLight3 = createDragLightEntry(stripId, "amber3", laneIndex, false, "tree"),
      greenLight  = createDragLightEntry(stripId, "green",  laneIndex, false, "tree"),
      redLight    = createDragLightEntry(stripId, "red",    laneIndex, false, "tree"),
    },
    globalLights = {},
    timers = {
      dialOffset = 0,
      laneTimer = 0,
      laneTimerFlag = false
    }
  }
end

local function initTree(dragData)
  if not dragData then
    log("W", logTag, "initTree called but dragData is nil")
    return {}
  end
  if not dragData.strip then
    log("W", logTag, "initTree called but dragData.strip is nil")
    return {}
  end
  if not dragData.strip.lanes or #dragData.strip.lanes == 0 then
    log("W", logTag, "initTree called but dragData.strip.lanes is empty or nil")
    return {}
  end

  local stripId = dragData.strip.id or dragData.id or "drag"
  local treeLights = {}
  for laneIndex = 1, #dragData.strip.lanes do
    treeLights[laneIndex] = createTreeLightsForLane(stripId, laneIndex)
  end
  if treeLights[1] then
    treeLights[1].globalLights = { blueLight = createDragLightEntry(stripId, "blueLight", nil, true, "prestage") }
  end
  return treeLights
end

-- Check if display digits are available (not nil)
local function hasDisplayDigits()
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.strip or not dragData.strip.displayDigits then
    return false
  end
  local digits = dragData.strip.displayDigits
  if not digits.timeDigits or not digits.speedDigits then
    return false
  end
  -- Check if at least one digit exists
  for _, laneDigits in ipairs(digits.timeDigits) do
    if laneDigits and #laneDigits > 0 and laneDigits[1] then
      return true
    end
  end
  return false
end

-- Check if tree lights are available (at least one light object exists)
local function hasTreeLights()
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.strip or not dragData.strip.treeLights then
    return false
  end
  for _, laneTree in ipairs(dragData.strip.treeLights) do
    if laneTree and laneTree.stageLights then
      -- Check if at least one light object exists
      for _, light in pairs(laneTree.stageLights) do
        if light and light.obj then
          return true
        end
      end
      for _, light in pairs(laneTree.countDownLights) do
        if light and light.obj then
          return true
        end
      end
    end
  end
  return false
end

-- In MP, get the network-broadcast timer values for a given vehicle.
-- Each machine timed its own vehicle locally, sent results to the host, and the host broadcast to all.
-- Returns a table keyed by timerId, or nil if not in MP / no values available.
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

-- Get the value of a specific timer for a racer, preferring network values in MP.
local function getTimerValue(racer, vehId, timerId, netTimers)
  if netTimers and netTimers[timerId] then
    return netTimers[timerId]
  end
  local timerObj = racer.timers and racer.timers[timerId]
  return timerObj and timerObj.value or 0
end

--- Local player's lane in current drag (for UI app: show only this racer's staging/countdown).
local function getLocalPlayerLane()
  if isMultiseatHudActive() then return nil end
  local drag = gameplay_drag_core.getDragGamemode()
  if drag and drag.getRaceState then
    local state = drag.getRaceState()
    if state and state.lane then return state.lane end
  end
  local dragData = gameplay_drag_core.getData()
  if dragData and dragData.racers then
    local playerVehId = be:getPlayerVehicleID(0)
    if playerVehId and dragData.racers[playerVehId] then
      return dragData.racers[playerVehId].lane
    end
  end
  return nil
end

local function updateTreeLightsUI(vehId, changes)
  if not changes then return end

  local dragData = gameplay_drag_core.getData()
  local lane = nil
  if vehId and dragData and dragData.racers and dragData.racers[vehId] then
    lane = dragData.racers[vehId].lane
    changes.lane = lane
  end

  -- MP network sync: host sends tree light changes to clients for all lanes (physical tree + remote clients' UI).
  local drag = gameplay_drag_core.getDragGamemode()
  if drag and drag.shouldSyncState and drag.shouldSyncState() and lane then
    local state = drag.getRaceState and drag.getRaceState()
    local raceId = state and state.id or nil
    if changes.countDownLights and drag.syncTreeLightState then
      drag.syncTreeLightState(raceId, lane, { countDownLights = changes.countDownLights })
    end
    if changes.stageLights and drag.syncTreeLightState then
      drag.syncTreeLightState(raceId, lane, { stageLights = changes.stageLights })
    end
  end

  if isMultiseatHudActive() then
    local targetLane = changes.lane ~= nil and changes.lane or lane
    if targetLane ~= nil then
      triggerMultiseatTreeEventForLane(targetLane, "updateTreeLightApp", changes)
    elseif vehId ~= nil then
      local playerIndex = getPlayerIndexForVehicle(vehId)
      if playerIndex ~= nil then
        triggerMultiseatTreeEvent(playerIndex, "updateTreeLightApp", changes)
      end
    elseif core_multiseat and core_multiseat.getJoinedPlayers then
      for _, playerIndex in ipairs(core_multiseat.getJoinedPlayers() or {}) do
        triggerMultiseatTreeEvent(playerIndex, "updateTreeLightApp", changes)
      end
    end
    return
  end

  -- UI app: only show the local player's lane staging/countdown state.
  -- In MP, skip UI updates for remote racers entirely (their state comes via network to their own client).
  local localLane = getLocalPlayerLane()
  if localLane == nil then return end
  if changes.lane ~= nil and changes.lane ~= localLane then return end
  if changes.lane == nil then changes.lane = localLane end

  -- Extra guard: in MP, only allow UI updates for the local racer's vehicle or global (nil vehId) updates
  if vehId and drag and drag.shouldSyncState and drag.shouldSyncState() then
    local localVehId = be:getPlayerVehicleID(0)
    if localVehId and vehId ~= localVehId then return end
  end

  if shouldSync() then
    table.insert(pendingTreeLightAppUpdates, changes)
  else
    guihooks.trigger("updateTreeLightApp", changes)
  end
end

M.updateTreeLightsFromNetwork = function(lane, lightState)
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.strip then return end

  -- Lazy-init tree lights if not yet built (can happen on clients when network messages arrive before onDragDataSet)
  if not dragData.strip.treeLights or not dragData.strip.treeLights[lane] then
    dragData.strip.treeLights = initTree(dragData) or {}
    if not dragData.strip.treeLights[lane] then return end
  end

  local treeLights = dragData.strip.treeLights[lane]
  local countDownLights = treeLights.countDownLights
  local hasTree = hasTreeLights()

  if lightState.countDownLights then
    local lights = lightState.countDownLights
    if lights.amberLight1 ~= nil then
      countDownLights.amberLight1.isOn = lights.amberLight1
      if hasTree then
        setTreeLightObjectHidden(countDownLights.amberLight1, not lights.amberLight1)
      end
    end
    if lights.amberLight2 ~= nil then
      countDownLights.amberLight2.isOn = lights.amberLight2
      if hasTree then
        setTreeLightObjectHidden(countDownLights.amberLight2, not lights.amberLight2)
      end
    end
    if lights.amberLight3 ~= nil then
      countDownLights.amberLight3.isOn = lights.amberLight3
      if hasTree then
        setTreeLightObjectHidden(countDownLights.amberLight3, not lights.amberLight3)
      end
    end
    if lights.greenLight ~= nil then
      countDownLights.greenLight.isOn = lights.greenLight
      if hasTree then
        setTreeLightObjectHidden(countDownLights.greenLight, not lights.greenLight)
      end
    end
    if lights.redLight ~= nil then
      local countdownDrag = getDrag()
      local countdownStart = countdownDrag and countdownDrag.getCountdownStartTime and countdownDrag.getCountdownStartTime()
      local redOn = lights.redLight and (countdownStart ~= nil)
      countDownLights.redLight.isOn = redOn
      if hasTree then
        setTreeLightObjectHidden(countDownLights.redLight, not redOn)
      end
    end

    if lane == getLocalPlayerLane() then
      guihooks.trigger("updateTreeLightApp", {
        lane = lane,
        countDownLights = lightState.countDownLights
      })
    end
    if isMultiseatHudActive() then
      triggerMultiseatTreeEventForLane(lane, "updateTreeLightApp", {
        lane = lane,
        countDownLights = lightState.countDownLights,
      })
    end
  end

  if lightState.stageLights then
    local lights = lightState.stageLights
    if lights.prestageLight ~= nil then
      treeLights.stageLights.prestageLight.isOn = lights.prestageLight
      if hasTree then
        setTreeLightObjectHidden(treeLights.stageLights.prestageLight, not lights.prestageLight)
      end
    end
    if lights.stageLight ~= nil then
      treeLights.stageLights.stageLight.isOn = lights.stageLight
      if hasTree then
        setTreeLightObjectHidden(treeLights.stageLights.stageLight, not lights.stageLight)
      end
    end

    if lane == getLocalPlayerLane() then
      guihooks.trigger("updateTreeLightApp", {
        lane = lane,
        stageLights = lightState.stageLights
      })
    end
    if isMultiseatHudActive() then
      triggerMultiseatTreeEventForLane(lane, "updateTreeLightApp", {
        lane = lane,
        stageLights = lightState.stageLights,
      })
    end
  end
end

local function initDisplay(dragData)
  local stripId = (dragData and dragData.strip and dragData.strip.id) or (dragData and dragData.id) or "drag"
  local lanes = dragData and dragData.strip and dragData.strip.lanes or {}
  local displayDigits = { timeDigits = {}, speedDigits = {} }
  local displayLights = {}

  for laneIndex = 1, #lanes do
    local time, speed = {}, {}
    for i = 1, 5 do
      time[i] = resolveSceneObject(stripId, "displayTime" .. i, laneIndex, true)
      speed[i] = resolveSceneObject(stripId, "displaySpeed" .. i, laneIndex, true)
    end
    displayDigits.timeDigits[laneIndex] = time
    displayDigits.speedDigits[laneIndex] = speed
    displayLights[laneIndex] = { srcObjs = resolveLightSources(stripId, "displayLight", laneIndex) }
  end

  return displayDigits, displayLights
end

local function setDisplayBoardLightEnabled(strip, lane, enabled)
  if not strip or not strip.displayLights then return end
  local entry = strip.displayLights[lane]
  if entry then
    setLightSourcesEnabled(entry.srcObjs, enabled)
  end
end

local function setAllDisplayBoardLightsEnabled(strip, enabled)
  if not strip or not strip.displayLights then return end
  for laneIndex = 1, #strip.displayLights do
    setDisplayBoardLightEnabled(strip, laneIndex, enabled)
  end
end

local function init(triggerStaging)
  local dragData = gameplay_drag_core.getData()
  if dragData then
    dragData.strip.treeLights = initTree(dragData) or {}
    local displayDigits, displayLights = initDisplay(dragData)
    dragData.strip.displayDigits = displayDigits or {}
    dragData.strip.displayLights = displayLights or {}
    if triggerStaging ~= false then
      broadcastTreeLightStaging(true)
    elseif isMultiseatHudActive() then
      broadcastTreeLightStaging(false)
    end
  end
end

local function clearLights()
  rand = math.random() + 2
  stagedAmount = 0
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.strip or not dragData.strip.treeLights then return end
  if dragData.racers then
    for _, racer in pairs(dragData.racers) do
      racer.raceStartBroadcasted = false
    end
  end
  for _, laneTree in ipairs(dragData.strip.treeLights) do
    for _,group in pairs(laneTree) do
      if type(group) == "table" then
        for _,light in pairs(group) do
          if type(light) == "table" and (light.obj or light.srcObjs) then
            setTreeLightObjectHidden(light, true)
            light.isOn = false
          end
        end
      end
    end
    laneTree.timers.laneTimer = 0
    laneTree.timers.laneTimerFlag = false
    laneTree.timers.dialOffset = 0
  end
  updateTreeLightsUI(nil, {
    stageLights = {
      prestageLight = false,
      stageLight = false,
    },
    countDownLights = {
      amberLight1 = false,
      amberLight2 = false,
      amberLight3 = false,
      greenLight = false,
      redLight = false
    },
    globalLights = {
      blueLight = false
    }
  })

  driverLightBlinkState = {
    lane = nil,
    isBlinking = false,
    timer = 0,
    frequency = 1/6, -- 6Hz = 1/6 seconds per cycle
    isOn = false,
    blinkCount = 0,
    maxBlinks = 6
  }
  -- guihooks.trigger("updateStageApp", -100)
  if isMultiseatHudActive() then
    clearMultiseatTreeUi()
  end
end


-- Changing shapeName reloads the digit mesh. Doing every digit on the finish frame freezes the sim before the timeslip can show.
local pendingDigitShapes = {}
local pendingDigitHead = 1
local pendingDigitTail = 0

local function clearPendingDigitShapes()
  pendingDigitShapes = {}
  pendingDigitHead = 1
  pendingDigitTail = 0
end

local function clearDisplay()
  clearPendingDigitShapes()
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.strip or not dragData.strip.displayDigits then return end
  for _, digitTypeData in pairs(dragData.strip.displayDigits) do
    for _,laneTypeData in ipairs(digitTypeData) do
      for _,digit in ipairs(laneTypeData) do
        if digit and simObjectExists(digit) then
          digit:setHidden(true)
        end
      end
    end
  end
  setAllDisplayBoardLightsEnabled(dragData.strip, false)
end

local function clearAll()
  local dragData = gameplay_drag_core.getData()
  if dragData and dragData.flashUpdate then
    dragData.flashUpdate = nil
  end
  clearLights()
  clearDisplay()
  clearStageGuideMarker()
  math.randomseed(os.time())
end

local function onExtensionLoaded()
  init()
  clearAll()
end

local function getDisplayTimeAndSpeed(racer, data, vehId)
  local importantId = (data and data.importantTimerId) or "time_1_4"
  local timerConfig = (data and data.timers) or {}
  local netTimers = vehId and getNetworkTimersForVehicle(vehId) or nil

  -- Find the important timer config entry
  local importantConfig = nil
  for _, t in ipairs(timerConfig) do
    local id = t.id or ("timer_" .. #timerConfig)
    if id == importantId then
      importantConfig = t
      break
    end
  end

  -- Get the important timer value; if not yet available, show nothing
  local importantVal = getTimerValue(racer, vehId, importantId, netTimers)
  if importantVal == 0 then return 0, 0 end

  local timeVal = 0
  local velVal = 0

  if importantConfig then
    if importantConfig.type == "distanceTimer" then
      timeVal = importantVal
      -- Find velocity at the same distance
      for _, t in ipairs(timerConfig) do
        local id = t.id or ("timer_" .. #timerConfig)
        if t.type == "velocity" and t.distance == importantConfig.distance then
          velVal = getTimerValue(racer, vehId, id, netTimers)
          break
        end
      end
    elseif importantConfig.type == "velocity" then
      velVal = importantVal
      -- Find distanceTimer at the same distance
      for _, t in ipairs(timerConfig) do
        local id = t.id or ("timer_" .. #timerConfig)
        if t.type == "distanceTimer" and t.distance == importantConfig.distance then
          timeVal = getTimerValue(racer, vehId, id, netTimers)
          break
        end
      end
    end
  else
    -- Fallback for default time_1_4 / velAt_1_4 when no config entry found
    timeVal = getTimerValue(racer, vehId, "time_1_4", netTimers)
    velVal = getTimerValue(racer, vehId, "velAt_1_4", netTimers)
    if timeVal == 0 and velVal == 0 then return 0, 0 end
  end

  return timeVal, velVal
end

local function shapeFileName(path)
  if type(path) ~= "string" then return nil end
  return string.match(path, "([^/\\]+)$")
end

local function queueDigitShape(digit, digitChar, hidden)
  if not digit or not simObjectExists(digit) then return end
  local shape = "art/shapes/quarter_mile_display/display_" .. digitChar .. ".dae"
  if shapeFileName(digit:getField("shapeName", 0)) == shapeFileName(shape) then
    digit:setHidden(hidden)
    return
  end
  for i = pendingDigitHead, pendingDigitTail do
    if pendingDigitShapes[i].digit == digit then
      pendingDigitShapes[i].shape = shape
      pendingDigitShapes[i].hidden = hidden
      return
    end
  end
  pendingDigitTail = pendingDigitTail + 1
  pendingDigitShapes[pendingDigitTail] = { digit = digit, shape = shape, hidden = hidden }
end

local function applyPendingDigitShapes()
  local item = pendingDigitShapes[pendingDigitHead]
  if not item then return end
  pendingDigitShapes[pendingDigitHead] = nil
  pendingDigitHead = pendingDigitHead + 1
  if pendingDigitHead > pendingDigitTail then
    clearPendingDigitShapes()
  end
  if not item.digit or not simObjectExists(item.digit) then return end
  item.digit:preApply()
  item.digit:setField("shapeName", 0, item.shape)
  item.digit:setHidden(item.hidden)
  item.digit:postApply()
end

local function updateDisplay(vehId)
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.racers or not dragData.racers[vehId] then return end
  local racer = dragData.racers[vehId]
  local lane = racer.lane
  local timeVal, velVal = getDisplayTimeAndSpeed(racer, dragData, vehId)

  -- Important timer not yet available; nothing to show
  if timeVal == 0 and velVal == 0 then return end

  if not hasDisplayDigits() then
    return
  end

  local timeDisplayValue = {}
  local speedDisplayValue = {}
  local timeDigits = {}
  local speedDigits = {}

  timeDigits = dragData.strip.displayDigits.timeDigits[lane]
  speedDigits = dragData.strip.displayDigits.speedDigits[lane]

  -- Speed timers are stored in m/s; the drag boards display trap speed in mph.
  local speedMph = velVal * 2.23694

  local timeHasLeadingPad = timeVal < 10
  local speedHasLeadingPad = speedMph < 100

  if timeHasLeadingPad then
    table.insert(timeDisplayValue, "0")
  end

  if speedHasLeadingPad then
    table.insert(speedDisplayValue, "0")
  end

  -- Three decimal points for time
  for num in string.gmatch(string.format("%.3f", timeVal), "%d") do
    table.insert(timeDisplayValue, num)
  end

  -- Two decimal points for speed
  for num in string.gmatch(string.format("%.2f", speedMph), "%d") do
    table.insert(speedDisplayValue, num)
  end

  if #timeDisplayValue > 0 and #timeDisplayValue < 6 then
    for i, v in ipairs(timeDisplayValue) do
      if timeDigits[i] then
        queueDigitShape(timeDigits[i], v, timeHasLeadingPad and i == 1)
      end
    end
  end

  for i, v in ipairs(speedDisplayValue) do
    if speedDigits and speedDigits[i] then
      queueDigitShape(speedDigits[i], v, speedHasLeadingPad and i == 1)
    end
  end

  setDisplayBoardLightEnabled(dragData.strip, lane, true)
end

local function updateTreeLightState(lightName, isOn, countDownLights, hasTree, racer, vehId)
  local light = countDownLights[lightName]
  if not light then return end

  if light.isOn == isOn then return end

  if hasTree then
    setTreeLightObjectHidden(light, not isOn)
  end
  light.isOn = isOn

  if racer.isPlayable or shouldSync() then
    updateTreeLightsUI(vehId, {
      countDownLights = {
        [lightName] = isOn
      }
    })
  end

  if shouldSync() and hasTree then
    setTreeLightObjectHidden(light, not isOn)
  end
end

local function updateMultipleTreeLights(lightStates, countDownLights, hasTree, racer, vehId, showGoMessage)
  for lightName, isOn in pairs(lightStates) do
    local light = countDownLights[lightName]
    if light then
      if hasTree then
        setTreeLightObjectHidden(light, not isOn)
      end
      light.isOn = isOn
    end
  end

  if racer.isPlayable or shouldSync() then
    if showGoMessage and racer.isPlayable then
      flashMessage("ui.scenarios.go", 5)
    end
    updateTreeLightsUI(vehId, {
      countDownLights = lightStates
    })
  end

  if shouldSync() and hasTree then
    for lightName, isOn in pairs(lightStates) do
      local light = countDownLights[lightName]
      if light then
        setTreeLightObjectHidden(light, not isOn)
      end
    end
  end
end

local function notifyRaceStartIfNeeded(racer)
  local drag = getDrag()
  if drag and racer.treeStarted and not racer.raceStartBroadcasted then
    local raceState = (drag and drag.getRaceState and drag.getRaceState()) or gameplay_drag_core.getRaceState()
    if raceState and raceState.id then
      if drag and drag.notifyRaceStart then drag.notifyRaceStart(raceState.id) end
    end
    racer.raceStartBroadcasted = true
  end
end

local function handle400TreeLogic(timers, countDownLights, racer, vehId)
  local hasTree = hasTreeLights()

  local currentRand = rand
  local drag = getDrag()
  if drag then
    local syncRand = drag.getSynchronizedRandValue()
    if syncRand then
      currentRand = syncRand
    end
  end

  if timers.laneTimer > currentRand and not timers.laneTimerFlag then
    timers.laneTimerFlag = true

    updateMultipleTreeLights({
      amberLight1 = true,
      amberLight2 = true,
      amberLight3 = true
    }, countDownLights, hasTree, racer, vehId, false)
  end

  if timers.laneTimerFlag and timers.laneTimer >= currentRand + 0.4 then
    notifyRaceStartIfNeeded(racer)
    clearDisplay()
    local isDisqualified = (racer.isDisqualified ~= nil and racer.isDisqualified) or racer.isDesqualified

    updateMultipleTreeLights({
      amberLight1 = false,
      amberLight2 = false,
      amberLight3 = false,
      greenLight = not isDisqualified,
      redLight = isDisqualified
    }, countDownLights, hasTree, racer, vehId, true)

    extensions.hook("startRaceFromTree", vehId)
    racer.treeStarted = false
    timers.laneTimerFlag = false
  end
end

local function handle500TreeLogic(timers, countDownLights, racer, vehId)
  local t = timers.laneTimer
  local hasTree = hasTreeLights()
  local isDisqualified = (racer.isDisqualified ~= nil and racer.isDisqualified) or racer.isDesqualified

  lightStages[4][6] = isDisqualified

  for _, stage in ipairs(lightStages) do
    if t > stage[1] and t < stage[2] then
      if countDownLights[stage[3]].isOn == stage[4] then
        updateTreeLightState(stage[3], not stage[4], countDownLights, hasTree, racer, vehId)
      end
      if stage[5] and countDownLights[stage[5]].isOn == stage[6] then
        updateTreeLightState(stage[5], not stage[6], countDownLights, hasTree, racer, vehId)
      end
    end
  end

  if t > 2.5 then
    notifyRaceStartIfNeeded(racer)
    clearDisplay()

    extensions.hook("startRaceFromTree", vehId)
    racer.treeStarted = false

    if countDownLights.greenLight.isOn == isDisqualified then
      updateMultipleTreeLights({
        greenLight = not isDisqualified,
        redLight = isDisqualified
      }, countDownLights, hasTree, racer, vehId, true)
    end
  end
end

-- Show/hide the staging tree UI based on proximity to the stage line.
-- Hides when the playable racer is far from stage. Re-shows when they return near stage AND in the staging phase.
local stageAppHiddenByDistance = false
local function checkStagingAppVisibility()
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.racers then return end

  if isMultiseatHudActive() then
    for vehId, racer in pairs(dragData.racers) do
      if racer.isPlayable then
        local playerIndex = getPlayerIndexForVehicle(vehId)
        if playerIndex ~= nil then
          local currentPhaseName = racer.phases and racer.phases[racer.currentPhase] and racer.phases[racer.currentPhase].name
          local isStaging = currentPhaseName == "stage"
          -- Keep the HUD tree up through countdown; Treelights hides itself after green/red.
          local showTree = isStaging or currentPhaseName == "countdown"
          local distance = racer.currentDistanceFromOrigin
          if distance ~= nil then
            local showDistance = isStaging and settings.getValue("dragAssistDistanceInTreeLights")
            if math.abs(distance - (racer._treeDistance or math.huge)) > 0.001 or racer._treeShowDistance ~= showDistance then
              racer._treeDistance = distance
              racer._treeShowDistance = showDistance
              triggerMultiseatTreeEvent(playerIndex, "updateTreeLightDistance", distance, showDistance)
            end
            if showTree then
              triggerMultiseatTreeEvent(playerIndex, "updateTreeLightStaging", math.abs(distance) <= 10 or M.alwaysShowStageApp)
            end
          end
        end
      end
    end
    return
  end

  for vehId, racer in pairs(dragData.racers) do
    if racer.isPlayable then
      if racer.currentDistanceFromOrigin == nil then return end

      local currentPhaseName = racer.phases and racer.phases[racer.currentPhase] and racer.phases[racer.currentPhase].name
      local isStaging = currentPhaseName == "stage"

      local distance = racer.currentDistanceFromOrigin
      if not distance then return end
      local showDistance = isStaging and settings.getValue("dragAssistDistanceInTreeLights")
      if math.abs(distance - (racer._treeDistance or math.huge)) > 0.001 or racer._treeShowDistance ~= showDistance then
        racer._treeDistance = distance
        racer._treeShowDistance = showDistance
        guihooks.trigger('updateTreeLightDistance', distance, showDistance)
      end

      if gameplay_drag_core.getGameplayContext() == "freeroam" then
        local isVisible = ui_appContainers.getAppVisibility('topCenter', 'drag')
        if math.abs(distance) > 10 and not M.alwaysShowStageApp then
          -- Far from stage: hide the app
          if isVisible then
            ui_appContainers.hideApp('topCenter', 'drag')
            flashMessage("")
            stageAppHiddenByDistance = true
          end
        else
          -- Near stage: re-show if we previously hid it and racer is in staging phase
          if stageAppHiddenByDistance and not isVisible and isStaging then
            ui_appContainers.showApp('topCenter', 'drag')
            guihooks.trigger('updateTreeLightStaging', true)
            stageAppHiddenByDistance = false
          end
        end
      end
      return
    end
  end
end


local function updateStageGuideMarker(dtReal, dtSim, dragData)
  if not settings.getValue("dragAssistStageGuideVisualizer") then
    clearStageGuideMarker()
    return
  end

  if not dragData or dragData.tutorial == false or not dragData.racers then
    clearStageGuideMarker()
    return
  end

  -- Drop markers for vehicles that are no longer staging (finished, past staging, or gone).
  for vehId in pairs(stageGuideMarkers) do
    local r = dragData.racers[vehId]
    if not r or r.isFinished or r.currentPhase ~= 1 then
      clearStageGuideMarker(vehId)
    end
  end

  for vehId, racer in pairs(dragData.racers) do
    if racer.isPlayable and not racer.isFinished and racer.currentPhase == 1 then
      local laneData = dragData.strip and dragData.strip.lanes and dragData.strip.lanes[racer.lane]
      if not laneData or not laneData.waypoints or not laneData.waypoints.stage or not laneData.waypoints.stage.transform then
        clearStageGuideMarker(vehId)
        goto continue
      end

      local distance = racer.currentDistanceFromOrigin
      if not distance then
        clearStageGuideMarker(vehId)
        goto continue
      end

      local frontWheelState = racer.beamState and racer.frontWheelId and racer.beamState[racer.frontWheelId] or nil
      local inLane = gameplay_drag_phaseHandlers.isRacerInsideBoundary(racer)
      local stageTransform = laneData.waypoints.stage.transform
      local isParallel = false
      if racer.vehDirectionVector and stageTransform.y then
        isParallel = math.abs(racer.vehDirectionVector:dot(stageTransform.y)) >= 0.70
      end
      local isValidStage = inLane and isParallel and frontWheelState and frontWheelState.stage

      local marker = createStageGuideMarker(vehId)
      if not marker then goto continue end

      if math.abs(distance) > (marker.getShowDistance and marker:getShowDistance() or 25) then
        clearStageGuideMarker(vehId)
        goto continue
      end

      if marker.updateFromStaging then
        marker:updateFromStaging(stageTransform, distance, isValidStage)
      end
      marker:update(dtReal, dtSim)
    end
    ::continue::
  end
end

local function updateCountdownTimer(timers, dtSim)
  local drag = getDrag()
  local countdownStartTime = drag and drag.getCountdownStartTime and drag.getCountdownStartTime() or nil

  if countdownStartTime then
    local currentTime = os.clockhp()
    local elapsed = currentTime - countdownStartTime
    if elapsed >= timers.dialOffset then
      timers.laneTimer = elapsed - timers.dialOffset
    else
      timers.laneTimer = 0
    end
  else
    timers.dialOffset = timers.dialOffset - dtSim
    if timers.dialOffset <= 0 then
      timers.laneTimer = timers.laneTimer + dtSim
    end
  end
end

local function updateRacerCountdown(vehId, racer, dragData, dtSim)
  local isDisqualified = (racer.isDisqualified ~= nil and racer.isDisqualified) or racer.isDesqualified
  if not racer.treeStarted or isDisqualified then
    return
  end

  if racer.currentPhase ~= 2 or not racer.phases or not racer.phases[2] or racer.phases[2].name ~= "countdown" then
    return
  end

  local treeLights = dragData.strip.treeLights[racer.lane]
  if not treeLights then
    return
  end

  local timers = treeLights.timers
  local countDownLights = treeLights.countDownLights

  updateCountdownTimer(timers, dtSim)

  -- In MP only the host drives countdown lights; clients apply from network.
  local drag = getDrag()
  local inMP = drag and drag.isMultiplayer and drag.isMultiplayer()
  local isHost = drag and drag.isServerHost and drag.isServerHost()
  if inMP and not isHost then
    return
  end
  if timers.dialOffset <= 0 or (drag and drag.getCountdownStartTime and drag.getCountdownStartTime()) then
    local treeType = dragData.prefabs and dragData.prefabs.christmasTree and dragData.prefabs.christmasTree.treeType or ".500"
    if treeType == ".400" then
      handle400TreeLogic(timers, countDownLights, racer, vehId)
    else
      handle500TreeLogic(timers, countDownLights, racer, vehId)
    end
  end
end

local function updateDriverLight(dtSim, dragData)
  if not driverLightBlinkState.isBlinking then
    return
  end

  if not dragData.strip.treeLights[driverLightBlinkState.lane] then
    driverLightBlinkState.isBlinking = false
    driverLightBlinkState.isOn = false
    return
  end

  local driverLight = dragData.strip.treeLights[driverLightBlinkState.lane].stageLights.driverLight
  if driverLight then
    local newTimer = driverLightBlinkState.timer + dtSim
    if newTimer >= driverLightBlinkState.frequency then
      driverLightBlinkState.timer = newTimer % driverLightBlinkState.frequency
      driverLightBlinkState.isOn = not driverLightBlinkState.isOn
      setTreeLightObjectHidden(driverLight, not driverLightBlinkState.isOn)
      if not driverLightBlinkState.isOn then
        driverLightBlinkState.blinkCount = driverLightBlinkState.blinkCount + 1
        if driverLightBlinkState.blinkCount >= driverLightBlinkState.maxBlinks then
          driverLightBlinkState.isBlinking = false
          driverLightBlinkState.isOn = false
          setTreeLightObjectHidden(driverLight, true)
          driverLight.isOn = false
        end
      end
    else
      driverLightBlinkState.timer = newTimer
    end
  else
    driverLightBlinkState.isBlinking = false
    driverLightBlinkState.isOn = false
  end
end

local function setAllLightsHidden(hidden, strip)
  local treeLights = strip and strip.treeLights or (gameplay_drag_core.getData() and gameplay_drag_core.getData().strip and gameplay_drag_core.getData().strip.treeLights)
  if not treeLights then return end
  for _, laneTree in ipairs(treeLights) do
    for _, group in pairs(laneTree) do
      if type(group) == "table" then
        for _, light in pairs(group) do
          if type(light) == "table" and (light.obj or light.srcObjs) then
            setTreeLightObjectHidden(light, hidden)
          end
        end
      end
    end
  end
end

local function setAllDisplayDigitsHidden(hidden, setZero, strip)
  local displayDigits = strip and strip.displayDigits or (gameplay_drag_core.getData() and gameplay_drag_core.getData().strip and gameplay_drag_core.getData().strip.displayDigits)
  if not displayDigits then return end
  for _, digitTypeData in pairs(displayDigits) do
    for _, laneTypeData in ipairs(digitTypeData) do
      for _, digit in ipairs(laneTypeData) do
        if digit and simObjectExists(digit) then
          if setZero and not hidden then
            digit:preApply()
            digit:setField('shapeName', 0, "art/shapes/quarter_mile_display/display_0.dae")
            digit:postApply()
          end
          digit:setHidden(hidden)
        end
      end
    end
  end
  setAllDisplayBoardLightsEnabled(strip or (gameplay_drag_core.getData() and gameplay_drag_core.getData().strip), not hidden)
end

local flashTimer = 0
local flashState = 0

local function updateFlash(dtSim, strip)
  if not strip then
    local dragData = gameplay_drag_core.getData()
    if not dragData then return false end
  end

  local flashDuration = 1/6
  flashTimer = flashTimer + dtSim

  if flashState == 0 and flashTimer >= flashDuration then
    setAllLightsHidden(false, strip)
    setAllDisplayDigitsHidden(false, true, strip)
    flashState = 1
    flashTimer = 0
  elseif flashState == 1 and flashTimer >= flashDuration then
    setAllLightsHidden(true, strip)
    setAllDisplayDigitsHidden(true, false, strip)
    flashState = 2
    flashTimer = 0
  elseif flashState == 2 and flashTimer >= flashDuration then
    setAllLightsHidden(false, strip)
    setAllDisplayDigitsHidden(false, false, strip)
    flashState = 3
    flashTimer = 0
  elseif flashState == 3 and flashTimer >= flashDuration then
    setAllLightsHidden(true, strip)
    setAllDisplayDigitsHidden(true, false, strip)
    flashState = 4
    flashTimer = 0
  elseif flashState == 4 and flashTimer >= flashDuration then
    -- Clear mode: end with lights off. Reset mode no longer uses flash.
    if strip then
      setAllLightsHidden(true, strip)
      setAllDisplayDigitsHidden(true, false, strip)
    end
    flashTimer = 0
    flashState = 0
    return false
  end

  return true
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not gameplay_drag_core then return end

  local dragData = gameplay_drag_core.getData()

  -- Clear flash runs after general has set dragData = nil; use cached strip
  if not dragData and clearFlashUpdateActive and clearFlashStripCache then
    local shouldContinue = updateFlash(dtSim, clearFlashStripCache)
    if not shouldContinue then
      clearFlashStripCache = nil
      clearFlashUpdateActive = false
      driverLightBlinkState = { lane = nil, isBlinking = false, timer = 0, frequency = 1/6, isOn = false, blinkCount = 0, maxBlinks = 6 }
    end
    return
  end

  if not dragData then return end

  applyPendingDigitShapes()

  if not dragData.strip or not dragData.strip.treeLights then
    return
  end

  -- Flush tree light UI updates deferred from previous frame (multiplayer: after sync)
  for _, changes in ipairs(pendingTreeLightAppUpdates) do
    guihooks.trigger("updateTreeLightApp", changes)
  end
  table.clear(pendingTreeLightAppUpdates)

  if dragData.flashUpdate then
    local shouldContinue = dragData.flashUpdate(dtSim)
    if not shouldContinue then
      dragData.flashUpdate = nil
    end
    return
  end

  checkStagingAppVisibility()

  for vehId, racer in pairs(dragData.racers) do
    updateRacerCountdown(vehId, racer, dragData, dtSim)
  end

  updateDriverLight(dtSim, dragData)
end

local function onPreRender(dtReal, dtSim, dtRaw)
  if not gameplay_drag_core then return end
  local dragData = gameplay_drag_core.getData()
  if not settings.getValue("dragAssistStageGuideVisualizer") then
    clearStageGuideMarker()
    return
  end
  if not dragData or not dragData.strip or not dragData.strip.treeLights then
    clearStageGuideMarker()
    return
  end
  updateStageGuideMarker(dtReal or 0, dtSim or 0, dragData)
end


local function onWinnerLightOn(lane)
  local dragData = gameplay_drag_core.getData()
  if not dragData then return end
  if lane and dragData.strip.treeLights and dragData.strip.treeLights[lane] then
    local winnerLight = dragData.strip.treeLights[lane].stageLights.winnerLight
    if winnerLight then
      winnerLight.isOn = true
      setTreeLightObjectHidden(winnerLight, false)
    end
    local driverLight = dragData.strip.treeLights[lane].stageLights.driverLight
    if driverLight and not driverLightBlinkState.isBlinking then
      driverLight.isOn = true
      driverLightBlinkState.lane = lane
      driverLightBlinkState.isBlinking = true
      driverLightBlinkState.timer = 0
      driverLightBlinkState.blinkCount = 0
      driverLightBlinkState.isOn = true
      setTreeLightObjectHidden(driverLight, false)
    end
    -- In MP, winning lights are triggered on each machine independently via generateWinData()
    -- after all network timers arrive. No separate broadcast needed.
  end
end

local function blueLightOn()
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.strip.treeLights or not dragData.strip.treeLights[1] then
    return
  end

  local hasTree = hasTreeLights()
  local blueLight = dragData.strip.treeLights[1].globalLights.blueLight
  if not blueLight then return end

  -- Update global blue light object if it exists
  if hasTree then
    setTreeLightObjectHidden(blueLight, false)
  end
  blueLight.isOn = true

  -- Always send to UI, even if tree objects don't exist
  updateTreeLightsUI(nil, {
    globalLights = {
      blueLight = true
    }
  })
end

local function blueLightOff()
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.strip.treeLights or not dragData.strip.treeLights[1] then
    return
  end

  local hasTree = hasTreeLights()
  local blueLight = dragData.strip.treeLights[1].globalLights.blueLight
  if not blueLight then return end

  -- Update global blue light object if it exists
  if hasTree then
    setTreeLightObjectHidden(blueLight, true)
  end
  blueLight.isOn = false

  -- Always send to UI, even if tree objects don't exist
  updateTreeLightsUI(nil, {
    globalLights = {
      blueLight = false
    }
  })
end

local function preStageLightOn(vehId)
  local dragData = gameplay_drag_core.getData()
  if not vehId or not dragData then return end
  local laneTree = dragData.strip.treeLights[dragData.racers[vehId].lane]
  if not laneTree or not laneTree.stageLights then return end

  if not laneTree.stageLights.prestageLight.isOn then
    local hasTree = hasTreeLights()
    if hasTree then
      setTreeLightObjectHidden(laneTree.stageLights.prestageLight, false)
    end
    laneTree.stageLights.prestageLight.isOn = true

    -- Always send to UI, even if tree objects don't exist
    updateTreeLightsUI(vehId, {
      stageLights = {
        prestageLight = true
      }
    })
    if not dragData.strip.treeLights[dragData.racers[vehId].lane].countDownLights.greenLight.isOn and not dragData.strip.treeLights[dragData.racers[vehId].lane].countDownLights.redLight.isOn then
      if dragData.racers[vehId].isPlayable then
        if ui_appContainers_topCenter then
          ui_appContainers_topCenter.clearMessagesFromSource('drag')
        end
        flashMessage("ui.drag.flash.preStage")
      end
    end
  end


end

M.preStageLightOn = preStageLightOn


local function preStageLightOff(vehId)
  local dragData = gameplay_drag_core.getData()
  if not vehId or not dragData then return end
  local laneTree = dragData.strip.treeLights[dragData.racers[vehId].lane]
  if not laneTree or not laneTree.stageLights then return end

  if laneTree.stageLights.prestageLight.isOn then
    local hasTree = hasTreeLights()
    if hasTree then
      setTreeLightObjectHidden(laneTree.stageLights.prestageLight, true)
    end
    laneTree.stageLights.prestageLight.isOn = false

    -- Send to UI and sync to host (MP) so tree lights stay in sync for all players
    local shouldSyncNow = dragData.racers[vehId].isPlayable or shouldSync()
    if shouldSyncNow then
      updateTreeLightsUI(vehId, {
        stageLights = {
          prestageLight = false,
          stageLight = laneTree.stageLights.stageLight and laneTree.stageLights.stageLight.isOn or false
        }
      })
    end
  end
end
M.preStageLightOff = preStageLightOff


local function stageLightOn(vehId)
  local dragData = gameplay_drag_core.getData()
  if not vehId or not dragData then return end
  local laneTree = dragData.strip.treeLights[dragData.racers[vehId].lane]
  if not laneTree or not laneTree.stageLights or not laneTree.stageLights.stageLight then return end

  if not laneTree.stageLights.stageLight.isOn then
    setTreeLightObjectHidden(laneTree.stageLights.stageLight, false)
    stagedAmount = stagedAmount + 1
    laneTree.stageLights.stageLight.isOn = true
    if stagedAmount >= #dragData.strip.treeLights then
      blueLightOn()
      stagedAmount = #dragData.strip.treeLights
    end
    if dragData.racers[vehId].isPlayable or shouldSync() then
      updateTreeLightsUI(vehId, {
        stageLights = {
          prestageLight = laneTree.stageLights.prestageLight and laneTree.stageLights.prestageLight.isOn or false,
          stageLight = true
        }
      })
      local drag = getDrag()
      local raceState = (drag and drag.getRaceState and drag.getRaceState()) or gameplay_drag_core.getRaceState()
      if raceState and raceState.id and drag and drag.syncStageLightState then
        drag.syncStageLightState(raceState.id, dragData.racers[vehId].lane, true)
      end
    end
    if not laneTree.countDownLights.greenLight.isOn and not laneTree.countDownLights.redLight.isOn then
      if dragData.racers[vehId].isPlayable then
        flashMessage("ui.drag.flash.stage")
      end
    end
  end
end

M.stageLightOn = stageLightOn

local function stageLightOff(vehId)
  local dragData = gameplay_drag_core.getData()
  if not vehId or not dragData then return end
  local laneTree = dragData.strip.treeLights[dragData.racers[vehId].lane]
  if not laneTree or not laneTree.stageLights or not laneTree.stageLights.stageLight then return end

  if laneTree.stageLights.stageLight.isOn then
    setTreeLightObjectHidden(laneTree.stageLights.stageLight, true)
    laneTree.stageLights.stageLight.isOn = false
    blueLightOff()
    if stagedAmount > 0 then
      stagedAmount = stagedAmount - 1
    end
    if dragData.racers[vehId].isPlayable or shouldSync() then
      updateTreeLightsUI(vehId, {
        stageLights = {
          prestageLight = laneTree and laneTree.stageLights and laneTree.stageLights.prestageLight.isOn or false,
          stageLight = false
        }
      })
      local drag = getDrag()
      local raceState = (drag and drag.getRaceState and drag.getRaceState()) or gameplay_drag_core.getRaceState()
      if raceState and raceState.id and drag and drag.syncStageLightState then
        drag.syncStageLightState(raceState.id, dragData.racers[vehId].lane, false)
      end
    end
  end
end
M.stageLightOff = stageLightOff


local function startDragCountdown(vehId, dial)
  local dragData = gameplay_drag_core.getData()
  if not dragData then return end
  local racer = dragData.racers[vehId]
  if not racer then return end

  if racer.currentPhase ~= 2 or not racer.phases or not racer.phases[2] or racer.phases[2].name ~= "countdown" then
    return
  end

  extensions.hook("onDragCountdownStarted", vehId, dial)
  racer.treeStarted = true

  local dialOffset = dial
  local drag = getDrag()
  if drag then
    local countdownStartTime = drag.getCountdownStartTime and drag.getCountdownStartTime()
    if countdownStartTime then
      local currentTime = os.clockhp()
      local elapsed = currentTime - countdownStartTime
      dialOffset = math.max(0, dial - elapsed)
    end
  end

  local laneTree = dragData.strip.treeLights and dragData.strip.treeLights[racer.lane]
  if not laneTree or not laneTree.timers then return end
  laneTree.timers.dialOffset = dialOffset
end

local function setDisqualifiedLights(vehId)
  local dragData = gameplay_drag_core.getData()
  if not dragData or not vehId then return end

  local racer = dragData.racers[vehId]
  if not racer then return end

  local treeLights = dragData.strip.treeLights[racer.lane]
  if not treeLights or not treeLights.countDownLights then return end
  local countDownLights = treeLights.countDownLights

  setTreeLightObjectHidden(countDownLights.amberLight1, true)
  setTreeLightObjectHidden(countDownLights.amberLight2, true)
  setTreeLightObjectHidden(countDownLights.amberLight3, true)
  countDownLights.amberLight1.isOn = false
  countDownLights.amberLight2.isOn = false
  countDownLights.amberLight3.isOn = false

  local isRedLight = racer.disqualifiedReason == gameplay_drag_phaseHandlers.redLightReason
  if isRedLight then
    setTreeLightObjectHidden(countDownLights.greenLight, true)
    setTreeLightObjectHidden(countDownLights.redLight, false)
    countDownLights.greenLight.isOn = false
    countDownLights.redLight.isOn = true
  end

  clearDisplay()
  extensions.hook("startRaceFromTree", vehId)
  if racer.isPlayable then
    local uiLights = {
      amberLight1 = false,
      amberLight2 = false,
      amberLight3 = false,
    }
    if isRedLight then
      uiLights.greenLight = false
      uiLights.redLight = true
    end
    updateTreeLightsUI(vehId, {
      countDownLights = uiLights
    })
    flashMessage(racer.disqualifiedReason, 5)
  end
end



local function stoppingVehicleDrag(vehId)
  local dragData = gameplay_drag_core.getData()
  if dragData and dragData.racers[vehId] and dragData.racers[vehId].isPlayable then
    flashMessage("missions.dragRace.gameplay.inLine", 5)
  end
end

local function dragRaceEndLineReached(vehId)
  updateDisplay(vehId)
end

local function dragRaceVehicleStopped()
  guihooks.trigger('updateTreeLightPhase', false)
  -- Do not clear displays/tree here; keep result visible until reset at POI or clear from bridge
end

local function flashAllLightsAndDisplay(forClear)
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.strip then return end

  -- Flash sequence: OFF → 1/6s → ON → 1/6s → OFF → 1/6s → ON → 1/6s → OFF (stay off)
  local totalFlashTime = 4/6 -- 4 intervals total

  ui_appContainers.showApp('topCenter', 'flashMessage')
  guihooks.trigger('ScenarioFlashMessage', { msg = "ui.drag.flash.systemReset", ttl = totalFlashTime, big = false })

  flashTimer = 0
  flashState = 0

  if forClear then
    clearFlashStripCache = { treeLights = dragData.strip.treeLights, displayDigits = dragData.strip.displayDigits }
    clearFlashUpdateActive = true
  else
    dragData.flashUpdate = function(dt) return updateFlash(dt, nil) end
  end
end

local function resetDragRaceValues()
  local dragData = gameplay_drag_core.getData()
  if not dragData then return end
  if dragData.strip and dragData.strip.treeLights then
    for _, laneTree in ipairs(dragData.strip.treeLights) do
      if laneTree.timers then
        laneTree.timers.laneTimer = 0
        laneTree.timers.laneTimerFlag = false
        laneTree.timers.dialOffset = 0
      end
    end
  end
  if dragData.racers then
    for _, racer in pairs(dragData.racers) do
      racer.treeStarted = false
      racer.raceStartBroadcasted = false
    end
  end
end

M.clearAll = clearAll
M.onBeforeDragUnloadAllExtensions = clearAll
M.onUpdate = onUpdate
M.onPreRender = onPreRender
M.onExtensionLoaded = onExtensionLoaded
M.startDragCountdown = startDragCountdown
M.setDisqualifiedLights = setDisqualifiedLights
M.dragRaceEndLineReached = dragRaceEndLineReached
M.dragRaceVehicleStopped = dragRaceVehicleStopped
M.resetDragRaceValues = resetDragRaceValues
M.onDragReset = function(options)
  -- Clear tree lights but NOT the display digits; results persist until clear or race start
  local dragData = gameplay_drag_core.getData()
  if dragData and dragData.flashUpdate then
    dragData.flashUpdate = nil
  end
  clearLights()
  clearStageGuideMarker()
  math.randomseed(os.time())
  resetDragRaceValues()
  stageAppHiddenByDistance = false
  clearMultiseatTreeUi()
end
M.onDragClear = function(options)
  -- Hide all tree lights and display digits immediately, then run light flick (flash uses cached strip after data is cleared)
  table.clear(playerIndexByVehId)
  clearAll()
  flashAllLightsAndDisplay(true)
  clearMultiseatTreeUi()
end
--- Called when general sets drag data (setDragRaceData). Inits tree lights and display digits for current strip.
--- In MP, display digits are preserved (cleared only at race start or gamemode stop).
M.onDragDataSet = function(data)
  profilerPushEvent("onDragDataSet")
  local drag = getDrag()
  local isMP = drag and drag.isMultiplayer and drag.isMultiplayer()
  profilerPushEvent("onDragDataSet init")
  init(not isMP) -- MP: skip staging trigger; checkStagingAppVisibility handles it by distance
  profilerPopEvent("onDragDataSet init")
  if isMP then
    -- MP: only reset tree lights, keep display digits from previous heat
    local dd = gameplay_drag_core.getData()
    if dd and dd.flashUpdate then dd.flashUpdate = nil end
    clearLights()
  else
    clearAll()
  end
  profilerPushEvent("onDragDataSet clearStageGuideMarker")
  clearStageGuideMarker()
  profilerPopEvent("onDragDataSet clearStageGuideMarker")
  profilerPopEvent("onDragDataSet")
end
M.onWinnerLightOn = onWinnerLightOn
M.stoppingVehicleDrag = stoppingVehicleDrag
M.broadcastTreeLightStaging = broadcastTreeLightStaging

-- When a remote racer's timer values arrive via network, update their display signs and UI.
M.onDragRaceTimerUpdated = function(raceId, mpPlayerId, timerName, timerValue)
  local drag = gameplay_drag_core.getDragGamemode()
  if not drag or not drag.isMultiplayer or not drag.isMultiplayer() then return end
  local race = drag.getActiveDragRace and drag.getActiveDragRace()
  if not race or not race.players then return end
  local pd = race.players[mpPlayerId]
  if pd and pd.vehicleId then
    updateDisplay(pd.vehicleId)
  end
end

return M
