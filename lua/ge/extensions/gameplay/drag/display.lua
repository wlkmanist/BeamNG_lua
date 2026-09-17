-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = ""

local rand
local stagedAmount = 0
local flashTime = 1.5
local pendingTreeLightAppUpdates = {}
local stageGuideMarker = nil

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

local function createStageGuideMarker()
  if stageGuideMarker then return stageGuideMarker end
  stageGuideMarker = require("scenario/race_marker").createRaceMarker(true, "dragStagePlane")
  if stageGuideMarker then
    stageGuideMarker:setMode("default")
  end
  return stageGuideMarker
end

local function clearStageGuideMarker()
  if stageGuideMarker then
    stageGuideMarker:clearMarkers()
    stageGuideMarker = nil
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

local function createTreeLightsForLane(stripId, laneIndex)
  return {
    stageLights = {
      prestageLight = {obj = resolveSceneObject(stripId, "prestage",     laneIndex),       anim = "prestage", isOn = false},
      stageLight    = {obj = resolveSceneObject(stripId, "stage",        laneIndex),       anim = "prestage", isOn = false},
      winnerLight   = {obj = resolveSceneObject(stripId, "winTimeboard", laneIndex, true), anim = "prestage", isOn = false},
      driverLight   = {obj = resolveSceneObject(stripId, "winDriver",    laneIndex, true), anim = "prestage", isOn = false},
    },
    countDownLights = {
      amberLight1 = {obj = resolveSceneObject(stripId, "amber1", laneIndex), anim = "tree", isOn = false},
      amberLight2 = {obj = resolveSceneObject(stripId, "amber2", laneIndex), anim = "tree", isOn = false},
      amberLight3 = {obj = resolveSceneObject(stripId, "amber3", laneIndex), anim = "tree", isOn = false},
      greenLight  = {obj = resolveSceneObject(stripId, "green",  laneIndex), anim = "tree", isOn = false},
      redLight    = {obj = resolveSceneObject(stripId, "red",    laneIndex), anim = "tree", isOn = false},
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
  local blueObj = resolveSceneObject(stripId, "blueLight", nil, true)
  if treeLights[1] then
    treeLights[1].globalLights = {blueLight = {obj = blueObj, anim = "prestage", isOn = false}}
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

-- Send times data to UI app when display signs are not available. Uses configured timers and important flag.
local function sendTimesToUI(vehId)
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.racers or not dragData.racers[vehId] then
    return
  end

  local racer = dragData.racers[vehId]
  if not racer.isPlayable then
    return
  end

  local timerConfig = dragData.timers or {}
  local importantId = dragData.importantTimerId or "time_1_4"
  local timesData = { lane = racer.lane, timerConfig = timerConfig, importantTimerId = importantId }
  local netTimers = getNetworkTimersForVehicle(vehId)
  for _, t in ipairs(timerConfig) do
    local id = t.id or ("timer_" .. #timerConfig)
    timesData[id] = getTimerValue(racer, vehId, id, netTimers)
  end

  guihooks.trigger("updateDragRaceTimes", timesData)
end

--- Local player's lane in current drag (for UI app: show only this racer's staging/countdown).
local function getLocalPlayerLane()
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
      if hasTree and countDownLights.amberLight1.obj and simObjectExists(countDownLights.amberLight1.obj) then
        countDownLights.amberLight1.obj:setHidden(not lights.amberLight1)
      end
    end
    if lights.amberLight2 ~= nil then
      countDownLights.amberLight2.isOn = lights.amberLight2
      if hasTree and countDownLights.amberLight2.obj and simObjectExists(countDownLights.amberLight2.obj) then
        countDownLights.amberLight2.obj:setHidden(not lights.amberLight2)
      end
    end
    if lights.amberLight3 ~= nil then
      countDownLights.amberLight3.isOn = lights.amberLight3
      if hasTree and countDownLights.amberLight3.obj and simObjectExists(countDownLights.amberLight3.obj) then
        countDownLights.amberLight3.obj:setHidden(not lights.amberLight3)
      end
    end
    if lights.greenLight ~= nil then
      countDownLights.greenLight.isOn = lights.greenLight
      if hasTree and countDownLights.greenLight.obj and simObjectExists(countDownLights.greenLight.obj) then
        countDownLights.greenLight.obj:setHidden(not lights.greenLight)
      end
    end
    if lights.redLight ~= nil then
      local countdownDrag = getDrag()
      local countdownStart = countdownDrag and countdownDrag.getCountdownStartTime and countdownDrag.getCountdownStartTime()
      local redOn = lights.redLight and (countdownStart ~= nil)
      countDownLights.redLight.isOn = redOn
      if hasTree and countDownLights.redLight.obj and simObjectExists(countDownLights.redLight.obj) then
        countDownLights.redLight.obj:setHidden(not redOn)
      end
    end

    if lane == getLocalPlayerLane() then
      guihooks.trigger("updateTreeLightApp", {
        lane = lane,
        countDownLights = lightState.countDownLights
      })
    end
  end

  if lightState.stageLights then
    local lights = lightState.stageLights
    if lights.prestageLight ~= nil then
      treeLights.stageLights.prestageLight.isOn = lights.prestageLight
      if hasTree and treeLights.stageLights.prestageLight.obj and simObjectExists(treeLights.stageLights.prestageLight.obj) then
        treeLights.stageLights.prestageLight.obj:setHidden(not lights.prestageLight)
      end
    end
    if lights.stageLight ~= nil then
      treeLights.stageLights.stageLight.isOn = lights.stageLight
      if hasTree and treeLights.stageLights.stageLight.obj and simObjectExists(treeLights.stageLights.stageLight.obj) then
        treeLights.stageLights.stageLight.obj:setHidden(not lights.stageLight)
      end
    end

    if lane == getLocalPlayerLane() then
      guihooks.trigger("updateTreeLightApp", {
        lane = lane,
        stageLights = lightState.stageLights
      })
    end
  end
end

local function initDisplay(dragData)
  local stripId = (dragData and dragData.strip and dragData.strip.id) or (dragData and dragData.id) or "drag"
  local lanes = dragData and dragData.strip and dragData.strip.lanes or {}
  local displayDigits = { timeDigits = {}, speedDigits = {} }

  for laneIndex = 1, #lanes do
    local time, speed = {}, {}
    for i = 1, 5 do
      time[i] = resolveSceneObject(stripId, "displayTime" .. i, laneIndex, true)
      speed[i] = resolveSceneObject(stripId, "displaySpeed" .. i, laneIndex, true)
    end
    displayDigits.timeDigits[laneIndex] = time
    displayDigits.speedDigits[laneIndex] = speed
  end

  return displayDigits
end

local function init(triggerStaging)
  local dragData = gameplay_drag_core.getData()
  if dragData then
    dragData.strip.treeLights = initTree(dragData) or {}
    dragData.strip.displayDigits = initDisplay(dragData) or {}
    if triggerStaging ~= false then
      guihooks.trigger('updateTreeLightStaging', true)
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
          if type(light) == "table" and light.obj and simObjectExists(light.obj) then
            light.obj:setHidden(true)
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
end


local function clearDisplay()
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

local function updateDisplay(vehId)
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.racers or not dragData.racers[vehId] then return end
  local racer = dragData.racers[vehId]
  local lane = racer.lane
  local timeVal, velVal = getDisplayTimeAndSpeed(racer, dragData, vehId)

  -- Important timer not yet available; nothing to show
  if timeVal == 0 and velVal == 0 then return end

  -- If display signs are not available, send times to UI app instead
  if not hasDisplayDigits() then
    sendTimesToUI(vehId)
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
    for i,v in ipairs(timeDisplayValue) do
      if timeDigits[i] and simObjectExists(timeDigits[i]) then
        timeDigits[i]:preApply()
        timeDigits[i]:setField('shapeName', 0, "art/shapes/quarter_mile_display/display_".. v ..".dae")
        timeDigits[i]:setHidden(timeHasLeadingPad and i == 1)
        timeDigits[i]:postApply()
      end
    end
  end

  for i,v in ipairs(speedDisplayValue) do
    if speedDigits and speedDigits[i] and simObjectExists(speedDigits[i]) then
      speedDigits[i]:preApply()
      speedDigits[i]:setField('shapeName', 0, "art/shapes/quarter_mile_display/display_".. v ..".dae")
      speedDigits[i]:setHidden(speedHasLeadingPad and i == 1)
      speedDigits[i]:postApply()
    end
  end
end

local function setTreeLightObjectHidden(light, hidden)
  if light.obj and simObjectExists(light.obj) then
    light.obj:setHidden(hidden)
  end
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
      flashMessage("Go!", 5)
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

  local lightStages = {
    {1.0, 1.5, "amberLight1", false},
    {1.5, 2.0, "amberLight1", true, "amberLight2", false},
    {2.0, 2.5, "amberLight2", true, "amberLight3", false},
    {2.5, math.huge, "amberLight3", true, "greenLight", isDisqualified}
  }

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

  for vehId, racer in pairs(dragData.racers) do
    if racer.isPlayable then
      if racer.currentDistanceFromOrigin == nil then return end

      local currentPhaseName = racer.phases and racer.phases[racer.currentPhase] and racer.phases[racer.currentPhase].name
      local isStaging = currentPhaseName == "stage"

      gameplay_drag_phaseHandlers.calculateDistanceOfAllWheelsFromStagePos(racer)
      local distance = gameplay_drag_phaseHandlers.getFrontWheelDistanceFromStagePos(racer)
      if not distance then return end
      local showDistance = isStaging and settings.getValue("dragAssistDistanceInTreeLights")
      guihooks.trigger('updateTreeLightDistance', distance, showDistance)

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

local function getPlayableRacer(dragData)
  if not dragData or not dragData.racers then return nil end
  local playerVehId = be:getPlayerVehicleID(0)
  if playerVehId and dragData.racers[playerVehId] then
    return dragData.racers[playerVehId]
  end
  for _, racer in pairs(dragData.racers) do
    if racer.isPlayable then
      return racer
    end
  end
  return nil
end

local function updateStageGuideMarker(dtReal, dtSim, dragData)
  if not settings.getValue("dragAssistStageGuideVisualizer") then
    clearStageGuideMarker()
    return
  end

  if not dragData or dragData.tutorial == false then
    clearStageGuideMarker()
    return
  end

  local racer = getPlayableRacer(dragData)
  if not racer or racer.isFinished or racer.currentPhase ~= 1 then
    clearStageGuideMarker()
    return
  end

  if not dragData.strip or not dragData.strip.lanes or not dragData.strip.lanes[racer.lane] then
    clearStageGuideMarker()
    return
  end

  local laneData = dragData.strip.lanes[racer.lane]
  if not laneData.waypoints or not laneData.waypoints.stage or not laneData.waypoints.stage.transform then
    clearStageGuideMarker()
    return
  end

  gameplay_drag_phaseHandlers.calculateDistanceOfAllWheelsFromStagePos(racer)
  local distance = gameplay_drag_phaseHandlers.getFrontWheelDistanceFromStagePos(racer)
  if not distance then
    clearStageGuideMarker()
    return
  end

  local frontWheelState = racer.beamState and racer.frontWheelId and racer.beamState[racer.frontWheelId] or nil
  local inLane = gameplay_drag_phaseHandlers.isRacerInsideBoundary(racer)
  local stageTransform = laneData.waypoints.stage.transform
  local isParallel = false
  if racer.vehDirectionVector and stageTransform.y then
    isParallel = math.abs(racer.vehDirectionVector:dot(stageTransform.y)) >= 0.70
  end
  local isValidStage = inLane and isParallel and frontWheelState and frontWheelState.stage

  local marker = createStageGuideMarker()
  if not marker then
    return
  end

  if math.abs(distance) > (marker.getShowDistance and marker:getShowDistance() or 25) then
    clearStageGuideMarker()
    return
  end

  if marker.updateFromStaging then
    marker:updateFromStaging(stageTransform, distance, isValidStage)
  end
  marker:update(dtReal, dtSim)
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

local function updateRacerTimers(vehId, racer)
  if racer.timersStarted and not hasDisplayDigits() and racer.isPlayable then
    sendTimesToUI(vehId)
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
  if driverLight and driverLight.obj and simObjectExists(driverLight.obj) then
    local newTimer = driverLightBlinkState.timer + dtSim
    if newTimer >= driverLightBlinkState.frequency then
      driverLightBlinkState.timer = newTimer % driverLightBlinkState.frequency
      driverLightBlinkState.isOn = not driverLightBlinkState.isOn
      driverLight.obj:setHidden(not driverLightBlinkState.isOn)
      if not driverLightBlinkState.isOn then
        driverLightBlinkState.blinkCount = driverLightBlinkState.blinkCount + 1
        if driverLightBlinkState.blinkCount >= driverLightBlinkState.maxBlinks then
          driverLightBlinkState.isBlinking = false
          driverLightBlinkState.isOn = false
          driverLight.obj:setHidden(true)
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
          if type(light) == "table" and light.obj and simObjectExists(light.obj) then
            light.obj:setHidden(hidden)
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
    updateRacerTimers(vehId, racer)
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
  if lane then
    if dragData.strip.treeLights[lane].stageLights.winnerLight and dragData.strip.treeLights[lane].stageLights.winnerLight.obj and simObjectExists(dragData.strip.treeLights[lane].stageLights.winnerLight.obj) then
      dragData.strip.treeLights[lane].stageLights.winnerLight.isOn = true
      dragData.strip.treeLights[lane].stageLights.winnerLight.obj:setHidden(false)
    end
    if dragData.strip.treeLights[lane].stageLights.driverLight and dragData.strip.treeLights[lane].stageLights.driverLight.obj and simObjectExists(dragData.strip.treeLights[lane].stageLights.driverLight.obj) and not driverLightBlinkState.isBlinking then
      dragData.strip.treeLights[lane].stageLights.driverLight.isOn = true
      driverLightBlinkState.lane = lane
      driverLightBlinkState.isBlinking = true
      driverLightBlinkState.timer = 0
      driverLightBlinkState.blinkCount = 0
      driverLightBlinkState.isOn = true
      dragData.strip.treeLights[lane].stageLights.driverLight.obj:setHidden(false)
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

  -- Update global blue light object if it exists
  if hasTree and blueLight.obj and simObjectExists(blueLight.obj) then
    blueLight.obj:setHidden(false)
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

  -- Update global blue light object if it exists
  if hasTree and blueLight.obj and simObjectExists(blueLight.obj) then
    blueLight.obj:setHidden(true)
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
    if hasTree and laneTree.stageLights.prestageLight.obj and simObjectExists(laneTree.stageLights.prestageLight.obj) then
      laneTree.stageLights.prestageLight.obj:setHidden(false)
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
        flashMessage("Pre-stage")
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
    if hasTree and laneTree.stageLights.prestageLight.obj and simObjectExists(laneTree.stageLights.prestageLight.obj) then
      laneTree.stageLights.prestageLight.obj:setHidden(true)
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
  if not laneTree or not laneTree.stageLights.stageLight.isOn then
    if laneTree.stageLights.stageLight.obj and simObjectExists(laneTree.stageLights.stageLight.obj) then
      laneTree.stageLights.stageLight.obj:setHidden(false)
    end
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
        flashMessage("Stage")
      end
    end
  end
end

M.stageLightOn = stageLightOn

local function stageLightOff(vehId)
  local dragData = gameplay_drag_core.getData()
  if not vehId or not dragData then return end
  if dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.stageLight.isOn then
    if dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.stageLight.obj and simObjectExists(dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.stageLight.obj) then
      dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.stageLight.obj:setHidden(true)
    end
    dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.stageLight.isOn = false
    blueLightOff()
    if stagedAmount > 0 then
      stagedAmount = stagedAmount - 1
    end
    if dragData.racers[vehId].isPlayable or shouldSync() then
      local laneTree = dragData.strip.treeLights[dragData.racers[vehId].lane]
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

  dragData.strip.treeLights[racer.lane].timers.dialOffset = dialOffset
end

local function setDisqualifiedLights(vehId)
  local dragData = gameplay_drag_core.getData()
  if not dragData or not vehId then return end

  local racer = dragData.racers[vehId]
  if not racer then return end

  local treeLights = dragData.strip.treeLights[racer.lane]
  local countDownLights = treeLights.countDownLights

  if countDownLights.amberLight1.obj and simObjectExists(countDownLights.amberLight1.obj) then countDownLights.amberLight1.obj:setHidden(true) end
  if countDownLights.amberLight2.obj and simObjectExists(countDownLights.amberLight2.obj) then countDownLights.amberLight2.obj:setHidden(true) end
  if countDownLights.amberLight3.obj and simObjectExists(countDownLights.amberLight3.obj) then countDownLights.amberLight3.obj:setHidden(true) end
  if countDownLights.greenLight.obj and simObjectExists(countDownLights.greenLight.obj) then countDownLights.greenLight.obj:setHidden(true) end
  if countDownLights.redLight.obj and simObjectExists(countDownLights.redLight.obj) then countDownLights.redLight.obj:setHidden(false) end

  countDownLights.amberLight1.isOn = false
  countDownLights.amberLight2.isOn = false
  countDownLights.amberLight3.isOn = false
  countDownLights.greenLight.isOn = false
  countDownLights.redLight.isOn = true
  clearDisplay()
  extensions.hook("startRaceFromTree", vehId)
  if racer.isPlayable then
    updateTreeLightsUI(vehId, {
      countDownLights = {
        amberLight1 = false,
        amberLight2 = false,
        amberLight3 = false,
        greenLight = false,
        redLight = true
      }
    })
    flashMessage("False start", 5)
  end
end



local function stoppingVehicleDrag(vehId)
  local dragData = gameplay_drag_core.getData()
  if dragData and dragData.racers[vehId] and dragData.racers[vehId].isPlayable then
    flashMessage("Stop the vehicle!", 5)
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
  guihooks.trigger('ScenarioFlashMessage', { msg = "SYSTEM RESET", ttl = totalFlashTime, big = false })

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
end
M.onDragClear = function(options)
  -- Hide all tree lights and display digits immediately, then run light flick (flash uses cached strip after data is cleared)
  clearAll()
  flashAllLightsAndDisplay(true)
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

-- When a remote racer's timer values arrive via network, update their display signs and UI.
M.onDragRaceTimerUpdated = function(raceId, playerId, timerName, timerValue)
  local drag = gameplay_drag_core.getDragGamemode()
  if not drag or not drag.isMultiplayer or not drag.isMultiplayer() then return end
  local race = drag.getActiveDragRace and drag.getActiveDragRace()
  if not race or not race.players then return end
  local pd = race.players[playerId]
  if pd and pd.vehicleId then
    updateDisplay(pd.vehicleId)
  end
end

return M
