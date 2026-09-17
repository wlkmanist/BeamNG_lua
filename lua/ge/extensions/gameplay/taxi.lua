-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
M.dependencies = {"gameplay_util_vehicleSighting"}

-- taxi management
local taxis = {} -- vehId -> state key (string key into taxiStates)
local hailingEnabled = true -- false during active missions
local availableTaxiRatio = 1 -- fraction of taxis that start available (rest are unavailable)

local playerSightParams = {
  maxDistDirectSight = 25,
  minDistPeriphSight = 5,
  periphSightAngle = 90,
  needDirectVisualContact = true,
}

local taxiSightParams = {
  maxDistDirectSight = 25,
  minDistPeriphSight = 20,
  periphSightAngle = 90,
  needDirectVisualContact = false,
}

-- a faster taxi needs to spot the player from further away to react in time
local taxiSightMaxDist = 70
local taxiSightFullRangeSpeed = 100 / 3.6 -- m/s (100 km/h): speed at which direct sight reaches taxiSightMaxDist

local taxiSightParamsDynamic = {
  maxDistDirectSight = taxiSightParams.maxDistDirectSight,
  minDistPeriphSight = taxiSightParams.minDistPeriphSight,
  periphSightAngle = taxiSightParams.periphSightAngle,
  needDirectVisualContact = taxiSightParams.needDirectVisualContact,
}

local function getTaxiSightParams(vehId)
  local veh = getObjectByID(vehId)
  local speed = veh and veh:getVelocity():len() or 0
  local t = clamp(speed / taxiSightFullRangeSpeed, 0, 1)
  taxiSightParamsDynamic.maxDistDirectSight = lerp(taxiSightParams.maxDistDirectSight, taxiSightMaxDist, t)
  return taxiSightParamsDynamic
end

-- to manage walking away from the taxi
local wiggleRoom = 6

-- to manage pulling over at the destination
local pullOverDistToDestination = 35

local delayToOpenBigMap = 0.4

-- reaction time when hailing the taxi (seconds)
local minReactionTime = 0.3
local maxReactionTime = 0.6
local maxPullOverSpeed = 2 --km/h
local blinkersDuration = 6

local hailMessage = {
  ttl = 0.5,
  msg = "ui.taxi.hail",
  category = "taxiNearby",
  clear = false,
}

-- camera system
local taxiCameraMode = "orbit"

-- idle camera system
local idleCameraDelay = 15 -- seconds
local fadeToBlackDuration = 0.5
local rotationResetThreshold = 0.25 -- camera is considered actively moved if rotated within this many seconds

local distanceToTarget = 150
local accelerationTime = 1 -- seconds

local hurryUpLevels = {
  { apply = function(veh) local tv = gameplay_traffic.getTrafficData()[veh:getID()] if tv then tv:setAiParameters() end end },
  { apply = function(veh) veh:queueLuaCommand('ai.setAggression(0.6)') veh:queueLuaCommand('ai.setSpeedMode("off")') end },
  { apply = function(veh) veh:queueLuaCommand('ai.setAggression(0.9)') veh:queueLuaCommand('ai.setSpeedMode("off")') end },
  { apply = function(veh) veh:queueLuaCommand('ai.setAggression(1.0)') veh:queueLuaCommand('ai.setSpeedMode("off")') end },
}

-- player ride phases: tracks the player's current interaction with a taxi
local playerRidePhases = {
  none = "none",
  awaitingPickup = "awaitingPickup", -- one or more taxis are coming to / waiting at the pickup (called or hailed)
  choosingDestination = "choosingDestination",
  driving = "driving",
  arriving = "arriving",
}

local taxiRideFilterName = "taxiRide"
local taxiRideBlockedActions = {
  -- driving
  "accelerate", "brake", "accelerate_brake", "steer_left", "steer_right", "steering",
  "clutch", "parkingbrake", "parkingbrake_temporary", "parkingbrake_toggle",
  -- shifting
  "shiftUp", "shiftDown", "toggleShifterMode",
  "gearR", "gear1", "gear2", "gear3", "gear4", "gear5", "gear6", "gear7", "gear8", "gearN",
  -- ignition
  "activateStarterMotor",
  "setIgnitionLevel0", "setIgnitionLevel1", "setIgnitionLevel2", "setIgnitionLevel3",
  "setIgnitionLevel1Momentary", "setIgnitionLevel2Momentary", "setIgnitionLevel3Momentary",
  -- electrics
  "toggle_headlights", "highbeam", "toggle_foglights",
  "toggle_left_signal", "toggle_right_signal", "toggle_hazard_signal", "toggle_lightbar_signal",
  "toggle_underglow", "horn",
  -- drivetrain
  "toggleESCMode", "nextESCMode", "previousESCMode",
  "toggleDiffMode", "toggle4WDStatus", "toggleRangeStatus",
  "toggleTransbrake", "toggleLineLock",
  "overrideNitrousOxide", "toggleNitrousOxide",
  "toggleTwoStep", "increaseTwoStepRPM", "decreaseTwoStepRPM",
  "toggleLightbarMode",
  -- cruise control
  "set_cc_speed", "reset_cc_speed", "increase_cc_speed", "decrease_cc_speed",
  "increase_cc_speed_large", "decrease_cc_speed_large", "disable_cc",
  -- couplers
  "couplersLock", "couplersToggle", "couplersUnlock",
  -- misc
  "reset_physics",
}

local slowSpeedThreshold = 3 -- below this we just stop instead of pulling over while moving (m/s)
local dropoffKickDelay = 10 -- seconds before the driver boots the player out after arriving

local taxiStates = {
  available             = { displayInfo = { label = "Available",       color = ColorF(0, 1, 0, 1) }, lightState = "available" },
  enRoute               = { displayInfo = { label = "En route",        color = ColorF(0, 0.6, 1, 1) }, lightState = "reserved" },
  pullingOverForPickup  = { displayInfo = { label = "Pulling Over",    color = ColorF(1, 0.65, 0, 1) }, blinkers = "pullOver", lightState = "reserved" },
  waitingForPickup      = { displayInfo = { label = "Waiting for you", color = ColorF(0, 0.6, 1, 1) }, blinkers = "hazard", lightState = "reserved" },
  occupied              = { lightState = "occupied" },
  pullingOverForDropoff = { blinkers = "pullOver", lightState = "occupied" },
  waitingForDropoff     = { blinkers = "hazard", lightState = "occupied" },
  unavailable           = { displayInfo = { label = "Unavailable",     color = ColorF(1, 0, 0, 1) }, lightState = "offDuty" },
}

local uiUpdateInterval = 0.1

local player = {
  nearestTaxiId = nil,
  currentTaxiId = nil, -- the active ride taxi (only set once the player has climbed in)
  currentPhase = playerRidePhases.none,
  destinationPos = nil,
  cameraBeforeTaxi = nil,
  idleCameraActive = false,
  disableIdleCamera = false,
  idleCameraUserEnabled = true,
  idleCameraTimer = 0,
  idleCameraJobToken = 0, -- used to cancel a pending fade-in when the idle camera is turned off mid-fade
  skipPosition = nil,
  skipRotation = nil,
  totalRouteDistance = 0,
  hurryUpLevel = 1,
  -- if the big map is closed during choosingDestination without picking a destination,
  -- this decides what to do: "drive" resumes the existing route, nil does nothing
  chooseResumeMode = nil,
  taxiViewActive = false,
  uiUpdateTimer = 0,
  persistentMessage = nil,
  disabledSwitchVehicles = nil, -- vehicles we temporarily made non-usable while riding, restored on exit
  dropoffKickTimer = 0,
  routePlanner = require('/lua/ge/extensions/gameplay/route/route')(),
  -- taxis coming to / waiting at the pickup, keyed by vehId. Each entry:
  --   { called = bool, targetPos = vec3|nil, waitTimer = 0, maxDist = math.huge }
  pickupTaxis = {},
  -- fare system (career only)
  fare = 0,
  fareCalculator = nil,
  fareData = nil,
}

local callTaxiSpawnMinDist = 120
local callTaxiSpawnMaxDist = 250
local callTaxiMaxRoadDist = 50 -- player must be within this distance of a road to call
local pickupWaitTime = 30 -- seconds a called taxi waits at the pickup before giving up
local pickupAbandonRadius = 12 -- after the wait, the taxi leaves if the player isn't within this many meters
local stuckTimeThreshold = 10
local stuckDistThreshold = 3


local function defaultCalculateFare(data)
  local fare = data.fareConfig.fare
  local km = data.distanceTraveled / 1000
  local total = fare.initial + (fare.perKm * km)
  if data.isNight then
    total = total + fare.nightSurcharge
  end
  return total
end

local taxiConfigs = {
  {model = 'fullsize', config = 'taxi', fare = {initial = 1.5, perKm = 1.0, nightSurcharge = 0.5}},
  {model = 'bastion',  config = 'taxi', fare = {initial = 2.0, perKm = 1.5, nightSurcharge = 0.5}},
  {model = 'bluebuck', config = 'taxi', fare = {initial = 2.5, perKm = 1.8, nightSurcharge = 0.7},
    calculateFare = function(data)
      local miles = data.distanceTraveled / 1609.344
      local sixths = miles * 6
      local total = 0
      if sixths < 1 then
        total = 0.45 * sixths
      else
        total = 0.45 + (sixths - 1) * 0.10
      end
      total = total + data.stationaryTime / 120 * 0.10
      return total
    end,
  },
  {model = 'midsize',  config = 'taxi', fare = {initial = 1.5, perKm = 1.0, nightSurcharge = 0.5}},
  {model = 'legran',   config = 'taxi', fare = {initial = 1.8, perKm = 1.2, nightSurcharge = 0.5}},
}

local function getShouldSystemBeEnabled()
  if gameplay_discover_freeroamTutorial_tutorial then return false end
  if multiplayer_sessionManager and multiplayer_sessionManager.getCurrentSession() then return false end
  if gameplay_missions_missionManager and gameplay_missions_missionManager.getForegroundMissionId() then return false end
  if career_career and career_career.isActive() then return true end
  if not settings.getValue("enableTaxiInFreeroam") then return false end
  return true
end

local function onTrafficSpecialVehiclesProviders()
  if not getShouldSystemBeEnabled() then return end
  gameplay_traffic.registerSpecialVehicleProvider({
    name = 'taxi',
    priority = 5,
    guaranteed = 1,
    reserved = 1,
    buildGroup = function(count, options)
      local group = {}
      for i = 1, count do
        table.insert(group, taxiConfigs[math.random(#taxiConfigs)])
      end
      return group
    end,
  })
end

local function resetPlayerData()
  player.nearestTaxiId = nil
  player.currentTaxiId = nil
  player.currentPhase = playerRidePhases.none
  player.destinationPos = nil
  player.cameraBeforeTaxi = nil
  player.idleCameraTimer = 0
  player.disableIdleCamera = false
  player.chooseResumeMode = nil
  player.dropoffKickTimer = 0
  player.skipPosition = nil
  player.skipRotation = nil
  player.hasSkipped = false
  player.totalRouteDistance = 0
  player.hurryUpLevel = 1
  player.taxiViewActive = false
  player.uiUpdateTimer = 0
  player.persistentMessage = nil
  player.routePlanner:clear()
  table.clear(player.pickupTaxis)
  player.fare = 0
  player.fareCalculator = nil
  player.fareData = nil
end

-- remaining route distance from vehPos: straight-line to the first path node plus that node's
-- distance to the target. Returns nil if the planner has no path or vehPos is missing.
local function routeDistanceLeft(planner, vehPos)
  local p = planner and planner.path
  if not (p and p[1] and vehPos) then return nil end
  return vehPos:distance(p[1].pos) + p[1].distToTarget
end

local function getDistanceLeft()
  local veh = player.currentTaxiId and getObjectByID(player.currentTaxiId)
  if not veh then return 0 end
  return routeDistanceLeft(player.routePlanner, veh:getPosition()) or 0
end

local function isTaxiCrashed(vehId)
  local trafficVeh = gameplay_traffic.getTrafficData()[vehId]
  return trafficVeh and trafficVeh.activeData and trafficVeh.activeData.tCrash ~= nil or false
end

local function getTaxiViewData()
  local distLeft = getDistanceLeft()
  local isDriving = player.currentPhase == playerRidePhases.driving
  local isChoosing = player.currentPhase == playerRidePhases.choosingDestination
  local isArriving = player.currentPhase == playerRidePhases.arriving
  return {
    playerCurrentPhase = player.currentPhase,
    hasDestination = isDriving,
    canHurryUp = isDriving and player.hurryUpLevel < #hurryUpLevels,
    canSlowDown = isDriving and player.hurryUpLevel > 1,
    hurryUpLevel = player.hurryUpLevel - 1,
    hurryUpMax = #hurryUpLevels - 1,
    canSkip = isDriving and player.skipPosition ~= nil and not player.hasSkipped and not isTaxiCrashed(player.currentTaxiId),
    canChangeDestination = isDriving or isChoosing or isArriving,
    canStop = isDriving,
    distanceLeft = distLeft,
    totalDistance = player.totalRouteDistance,
    message = player.persistentMessage,
    idleCameraEnabled = player.idleCameraUserEnabled,
    currentFare = player.fareData and player.fare or nil,
  }
end

local function pushTaxiUIUpdate(message)
  if not player.taxiViewActive then return end
  if message then player.persistentMessage = message end
  local data = getTaxiViewData()
  guihooks.queueStream("taxi", data)
end

local function showMessage(message, clear, ttl)
  if clear == nil then clear = true end
  local helper = {
    ttl = ttl or 2,
    msg = message,
    category = "taxiNearby",
    clear = clear
  }
  guihooks.trigger('Message',helper)
end

local function activateSignal(veh, rightForRightHand)
  local isRightHand = map.getRoadRules().rightHandDrive
  local useRight = (isRightHand and rightForRightHand) or (not isRightHand and not rightForRightHand)
  -- autoCancel = false so the AI's steering during the maneuver doesn't self-cancel the signal
  veh:queueLuaCommand('electrics.set_' .. (useRight and 'left' or 'right') .. '_signal(true, false)')
end

local function activatePullOverBlinkers(veh)
  activateSignal(veh, true)
end

local function activateMergeBlinkers(vehId)
  core_jobsystem.create(function(job)
    -- wait a frame so any signal-off commands from a preceding state change run first
    job.yield()
    local v = getObjectByID(vehId)
    if not v then return end
    activateSignal(v, false)
    job.sleep(blinkersDuration)
    v = getObjectByID(vehId)
    if v then v:queueLuaCommand('electrics.stop_turn_signal()') end
  end, 1)
end


local function setIdleCamera(value)
  if not core_camera then return end
  if value == player.idleCameraActive then return end
  player.idleCameraActive = value
  player.idleCameraJobToken = player.idleCameraJobToken + 1
  local myToken = player.idleCameraJobToken
  if value then
    core_jobsystem.create(function(job)
      ui_fadeScreen.start(fadeToBlackDuration)
      job.sleep(fadeToBlackDuration+0.1)
      if myToken ~= player.idleCameraJobToken then
        ui_fadeScreen.stop(fadeToBlackDuration)
        return
      end
      core_camera.setByName(0, "external")
      ui_fadeScreen.stop(fadeToBlackDuration)
    end, 1)
  else
    core_camera.setByName(0, taxiCameraMode)
  end
end

local function setTaxiState(vehId, stateKey)
  if not vehId then return end
  local prev = taxis[vehId]
  if prev == stateKey then return end
  --log("I", "taxi", "setTaxiState: " .. tostring(vehId) .. " " .. tostring(prev) .. " -> " .. tostring(stateKey))
  taxis[vehId] = stateKey

  if stateKey == "unavailable" then
    local trafficData = gameplay_traffic.getTrafficData()
    local td = trafficData[vehId]
    if td then td.ignoreForceTeleport = nil end
    if td and td.reserved then
      gameplay_traffic.returnReservedVehicle(vehId)
    else
      gameplay_traffic.unprotectNonReservedVehicle(vehId)
    end
  end

  local veh = getObjectByID(vehId)
  if not veh then return end

  -- AI commands
  if stateKey == "pullingOverForPickup" or stateKey == "pullingOverForDropoff" then
    if veh:getVelocity():len() * 3.6 < maxPullOverSpeed then
      local stopped = stateKey == "pullingOverForPickup" and "waitingForPickup" or "waitingForDropoff"
      setTaxiState(vehId, stopped)
      return
    end
    veh:queueLuaCommand('ai.setPullOver(true)')
  elseif stateKey == "waitingForPickup" or stateKey == "waitingForDropoff" then
    veh:queueLuaCommand('ai.setMode("stop")')
  end

  -- Blinkers
  local meta = taxiStates[stateKey]
  if meta and meta.blinkers == "hazard" then
    core_jobsystem.create(function(job)
      job.sleep(0.2)
      veh:queueLuaCommand('electrics.set_warn_signal(1)')
    end, 1)
  elseif meta and meta.blinkers == "pullOver" then
    veh:queueLuaCommand('electrics.set_warn_signal(false)')
    activatePullOverBlinkers(veh)
  elseif prev and taxiStates[prev] and taxiStates[prev].blinkers then
    veh:queueLuaCommand('electrics.set_warn_signal(false)')
    veh:queueLuaCommand('electrics.stop_turn_signal()')
  end

  -- Taxi sign lights
  if meta and meta.lightState then
    veh:queueLuaCommand(string.format('local c = controller.getController("taxiLights") if c then c.setTaxiState("%s") end', meta.lightState))
  end
end

local function getTaxiState(vehId)
  return taxis[vehId] or "available"
end

-- registers a taxi that is coming to / waiting at the pickup. called = summoned via phone (vs hailed). target pos can be nil for hailed taxis that pull over in place.
local function addPickupTaxi(vehId, called, targetPos)
  player.pickupTaxis[vehId] = { called = called, targetPos = targetPos, waitTimer = 0, maxDist = math.huge }
  if player.currentPhase == playerRidePhases.none then
    player.currentPhase = playerRidePhases.awaitingPickup
  end
end

-- a pickup taxi is no longer serving the player (boarded another, crashed, walked away, waited too long, call cancelled): mark it unavailable
local function dismissPickupTaxi(vehId, message)
  player.pickupTaxis[vehId] = nil

  setTaxiState(vehId, "unavailable")
  local veh = getObjectByID(vehId)
  if veh then
    veh:queueLuaCommand('ai.setPullOver(false)')
    veh:queueLuaCommand('ai.setState({mode = "traffic"})')
    veh.playerUsable = false
  end
  gameplay_walk.addVehicleToBlacklist(vehId)
  activateMergeBlinkers(vehId)

  if message then showMessage(message, false, 3) end

  if player.currentPhase == playerRidePhases.awaitingPickup and not next(player.pickupTaxis) then
    player.currentPhase = playerRidePhases.none
  end
end

local function dismissAllPickupTaxis(exceptId)
  local ids = {}
  for vehId in pairs(player.pickupTaxis) do
    if vehId ~= exceptId then ids[#ids + 1] = vehId end
  end
  for _, vehId in ipairs(ids) do
    dismissPickupTaxi(vehId)
  end
end

-- drops a taxi from the pickup set WITHOUT marking it unavailable, so it stays a normal hailable taxi
-- (used when a hailed driver never noticed the player, or the vehicle vanished before engaging).
local function forgetPickupTaxi(vehId)
  player.pickupTaxis[vehId] = nil
  if player.currentPhase == playerRidePhases.awaitingPickup and not next(player.pickupTaxis) then
    player.currentPhase = playerRidePhases.none
  end
end

-- true if any pickup taxi was summoned via phone (so the radial menu offers "cancel call")
local function hasCalledATaxi()
  for _, entry in pairs(player.pickupTaxis) do
    if entry.called then return true end
  end
  return false
end

local function rollAvailability(vehId)
  if vehId and isTaxiCrashed(vehId) then return "unavailable" end
  return math.random() < availableTaxiRatio and "available" or "unavailable"
end

local drawTaxiLabels -- assigned by the Skia billboard add-on at the bottom of this file
local clearTaxiBillboards -- assigned by the Skia billboard add-on; tears down all billboards
local useBillboards = true

local function setPlayerPhase(phase, message)
  player.currentPhase = phase

  -- sync the active ride taxi's state to match the ride phase
  if player.currentTaxiId then
    if phase == playerRidePhases.choosingDestination or phase == playerRidePhases.driving then
      setTaxiState(player.currentTaxiId, "occupied")
    elseif phase == playerRidePhases.arriving then
      setTaxiState(player.currentTaxiId, "pullingOverForDropoff")
    end
  end

  if player.currentPhase == playerRidePhases.driving then
    -- start the idle timer fresh so it doesn't trigger from time spent in the big map
    player.idleCameraTimer = 0
    player.persistentMessage = nil
    -- navigate to the taxi view when entering the driving phase
    -- (done here rather than on vehicle-enter so the BigMap can close normally first)
    player.taxiViewActive = true
    extensions.ui_menuManager.setGameplayRoute("taxi")
    local current = extensions.ui_router.getCurrent()
    if not current or not current.request or current.request.name ~= "taxi" then
      extensions.ui_router.navigate("taxi")
    end
  end
  if player.currentPhase == playerRidePhases.arriving then
    setIdleCamera(false)
    player.disableIdleCamera = true
  end
  pushTaxiUIUpdate(message)
end


local function updateTaxiPullOver()
  -- pickup taxis: once stopped, switch from pulling over to waiting
  for vehId in pairs(player.pickupTaxis) do
    if taxis[vehId] == "pullingOverForPickup" then
      local veh = getObjectByID(vehId)
      if veh and veh:getVelocity():len() * 3.6 < maxPullOverSpeed then
        setTaxiState(vehId, "waitingForPickup")
      end
    end
  end

  -- active ride taxi: dropoff pull over
  if player.currentTaxiId and taxis[player.currentTaxiId] == "pullingOverForDropoff" then
    local veh = getObjectByID(player.currentTaxiId)
    if veh and veh:getVelocity():len() * 3.6 < maxPullOverSpeed then
      setTaxiState(player.currentTaxiId, "waitingForDropoff")
      pushTaxiUIUpdate(_tr("ui.taxi.canClimbOut"))
    end
  end
end

local function resetIdleCameraTimer()
  player.idleCameraTimer = 0
end

local function checkIdleCamera(dt)
  if not core_camera then return end

  -- treat the quick access menu like camera activity and hold the timer.
  if core_quickAccess and core_quickAccess.isEnabled() then
    player.idleCameraTimer = 0
    return
  end

  local timeSinceRotation = core_camera.timeSinceLastRotation() / 1000

  -- player is actively moving the camera: reset our timer and leave idle mode
  if timeSinceRotation < rotationResetThreshold then
    player.idleCameraTimer = 0
    if player.idleCameraActive then
      setIdleCamera(false)
    end
    return
  end

  if player.idleCameraActive or player.disableIdleCamera or not player.idleCameraUserEnabled then return end

  player.idleCameraTimer = player.idleCameraTimer + dt
  if player.idleCameraTimer > idleCameraDelay then
    setIdleCamera(true)
  end
end

local function getAiPath(path, veh)
  local aiPath = {}
  if not veh then return nil end
  local firstWpAdded = false
  local vehPos = veh:getPosition()
  local vehFwd = veh:getDirectionVector()
  local bestDist = math.huge
  local prevDot = nil
  local prevWp = nil
  local startDist = path[1].distToTarget
  -- find the first valid waypoint
  for i, marker in ipairs(path) do
    if marker.wp then
      if (marker.distToTarget < distanceToTarget) and not player.skipPosition then
        player.skipPosition = marker.pos
        if path[i+1] and path[i+1].pos then
          local direction = (path[i+1].pos - marker.pos):normalized()
          player.skipRotation = quatFromDir(direction, vec3(0, 0, 1))
        end
      end
      if not firstWpAdded then
        local toWp = (marker.pos - vehPos):normalized()
        local dot = toWp:dot(vehFwd)
        if prevDot and dot < prevDot and prevDot > 0 then
          table.insert(aiPath, prevWp)
          firstWpAdded = true
        end
        prevDot = dot
        prevWp = marker.wp
      else
        table.insert(aiPath, marker.wp)
      end
    end
  end
  -- If we haven't found a local maximum but have a positive dot product, use the last one
  if not firstWpAdded and prevDot and prevDot > 0 then
    table.insert(aiPath, prevWp)
    firstWpAdded = true
  end
  -- fallback: if no waypoint is in front of vehicle, use the first waypoint that's 25m away and all other waypoints
  if not firstWpAdded then
    for _, marker in ipairs(path) do
      if marker.wp and startDist - marker.distToTarget > 25 then
        table.insert(aiPath, marker.wp)
      end
    end
  end
  return aiPath
end

-- Ensures a drive path ends by passing through targetPos's road segment. Appends the approach node then the node just past the target, ordered by the route's final travel direction.
local function appendTargetApproach(aiPath, routePlanner, veh, targetPos)
  if not aiPath or not targetPos then return aiPath end
  local n1, n2 = map.findClosestRoad(targetPos)
  local nodes = map.getMap().nodes
  if not (n1 and n2 and nodes[n1] and nodes[n2]) then return aiPath end

  -- travel direction near the target: from the route's last named node (robust on curves),
  -- falling back to the vehicle position if the route has no usable named node
  local approachFrom
  for i = #routePlanner.path, 1, -1 do
    local m = routePlanner.path[i]
    if m.wp and nodes[m.wp] then approachFrom = nodes[m.wp].pos break end
  end
  approachFrom = approachFrom or (veh and veh:getPosition())
  if not approachFrom then return aiPath end
  local travelDir = targetPos - approachFrom
  if travelDir:length() < 1e-3 and veh then travelDir = targetPos - veh:getPosition() end
  travelDir = travelDir:normalized()

  -- approach node is on the near side of the target, overshoot node on the far side
  local approachWp, overshootWp = n1, n2
  if (nodes[n1].pos - targetPos):dot(travelDir) > (nodes[n2].pos - targetPos):dot(travelDir) then
    approachWp, overshootWp = n2, n1
  end

  if aiPath[#aiPath] ~= approachWp then table.insert(aiPath, approachWp) end
  if aiPath[#aiPath] ~= overshootWp then table.insert(aiPath, overshootWp) end
  return aiPath
end

local function getCurrentRoute(veh)
  local rp = player.routePlanner
  if not rp or not rp.path or not rp.path[1] then
    return
  end

  -- reset so getAiPath recomputes a fresh skip target for this route (otherwise the
  -- "not skipPosition" guard keeps a stale point from a previous ride/route forever)
  player.skipPosition = nil
  player.skipRotation = nil
  local aiPath = getAiPath(rp.path, veh)
  -- always anchor on the destination's road segment so the list is non-empty on short routes
  -- and the AI drives through the stop point (the actual stop is handled by proximity pull-over)
  appendTargetApproach(aiPath, rp, veh, player.destinationPos)

  local str = '{wpTargetList = '..serialize(aiPath)
  str = str..', noOfLaps = 1, aggression = 0.3, avoidCars = "on", driveInLane = "on", speedMode = "limit"}'
  return str
end


local function startTaxiWithCurrentRoute(skipWait)
  if skipWait == nil then skipWait = false end
  core_jobsystem.create(function(job)
    freeroam_bigMapMode.exitBigMap(false, true, true)
    local plVeh = be:getPlayerVehicle(0)
    if not plVeh then
      return
    end

    if not player.destinationPos then
      return
    end

    local vehPos = plVeh:getPosition()
    player.routePlanner:setupPathMulti({vehPos, player.destinationPos})
    if not (player.routePlanner.path and player.routePlanner.path[1]) then
      return
    end

    local routeStr = getCurrentRoute(plVeh)
    if not routeStr then
      return
    end

    player.routePlanner:trackVehicle(plVeh)
    player.totalRouteDistance = routeDistanceLeft(player.routePlanner, vehPos) or 0

    if not skipWait then
      job.sleep(2)
    end

    plVeh:queueLuaCommand('ai.setPullOver(false)') -- in case we're resuming from a pulled-over dropoff
    plVeh:queueLuaCommand('ai.driveUsingPath('..routeStr..')')

    setPlayerPhase(playerRidePhases.driving)
    -- signal merging back into traffic as the taxi pulls away from the curb
    activateMergeBlinkers(player.currentTaxiId)
    -- clear ground markers after phase change so the hook doesn't clear destinationPos
    freeroam_bigMapMode.setNavFocus(nil)
  end, 1)
end


local function refreshHailingEnabled()
  local wasEnabled = hailingEnabled
  hailingEnabled = getShouldSystemBeEnabled()

  if hailingEnabled == wasEnabled then return end

  if hailingEnabled then
    for id, veh in pairs(gameplay_traffic.getTrafficData()) do
      if veh.isTaxi and not veh.reserved and veh.isAi and not taxis[id] then
        setTaxiState(id, rollAvailability(id))
      end
    end
  else
    table.clear(taxis)
    clearTaxiBillboards()
  end
end

local function taxiSettingChanged()
  refreshHailingEnabled()
end

local function onTrafficStarted()
  refreshHailingEnabled()
end

local function onAnyMissionChanged()
  refreshHailingEnabled()
end

local function onTrafficVehicleAdded(id)
  if not hailingEnabled then return end
  local trafficData = gameplay_traffic.getTrafficData()
  local vehData = trafficData[id]
  if vehData and vehData.isTaxi and not vehData.reserved and vehData.isAi then
    setTaxiState(id, rollAvailability(id))
  end
end

local function onTrafficVehicleRemoved(id)
  if taxis[id] then
    taxis[id] = nil
  end
  if player.pickupTaxis[id] then
    player.pickupTaxis[id] = nil
    if player.currentPhase == playerRidePhases.awaitingPickup and not next(player.pickupTaxis) then
      player.currentPhase = playerRidePhases.none
    end
  end
end

local function onTrafficStopped()
  table.clear(taxis)
  clearTaxiBillboards()
  if player.idleCameraActive then setIdleCamera(false) end
  if player.taxiViewActive then
    extensions.ui_menuManager.setGameplayRoute(nil)
    local current = extensions.ui_router.getCurrent()
    if current and current.request and current.request.name == "taxi" then
      extensions.ui_router.navigate("play")
    end
  end
  resetPlayerData()
end

local function checkAndFindNearestTaxi()
  local phase = player.currentPhase
  if phase ~= playerRidePhases.none and phase ~= playerRidePhases.awaitingPickup then return end
  if not gameplay_walk.isWalking() then return end

  local playerVehId = be:getPlayerVehicleID(0)
  local playerObj = map.objects[playerVehId]
  if not playerObj then return end
  local playerPos = playerObj.pos
  local camPos = core_camera and core_camera.getPosition()
  local camFwd = camPos and core_camera.getForward()
  local nearestDist = math.huge
  local found = false
  for vehId, state in pairs(taxis) do
    if state == "available" and vehId ~= playerVehId and not player.pickupTaxis[vehId] and vehId ~= player.currentTaxiId then
      local veh = map.objects[vehId]
      if veh and camFwd then
        if gameplay_util_vehicleSighting.checkSighting(camPos, camFwd, veh.pos, playerSightParams) then
          local dist = playerPos:distance(veh.pos)
          if dist < nearestDist then
            nearestDist = dist
            player.nearestTaxiId = vehId
            found = true
          end
        end
      end
    end
  end

  if not found then
    player.nearestTaxiId = nil
  end
end


local function applyTaxiRideFilter()
  core_input_actionFilter.setGroup(taxiRideFilterName, taxiRideBlockedActions)
  core_input_actionFilter.addAction(0, taxiRideFilterName, true)
end

local function clearTaxiRideFilter()
  core_input_actionFilter.addAction(0, taxiRideFilterName, false)
end

local function blockVehicleSwitching() -- while riding the taxi, stop the player from switching into any other car
  player.disabledSwitchVehicles = {}
  for i = 0, be:getObjectCount() - 1 do
    local veh = be:getObject(i)
    if veh then
      local vid = veh:getId()
      if vid ~= player.currentTaxiId and veh.playerUsable ~= false and veh:getJBeamFilename() ~= "unicycle" then
        veh.playerUsable = false
        table.insert(player.disabledSwitchVehicles, vid)
      end
    end
  end
  applyTaxiRideFilter()
end

local function restoreVehicleSwitching() -- re-enable the cars we disabled when entering the taxi
  clearTaxiRideFilter()
  if not player.disabledSwitchVehicles then return end
  for _, vid in ipairs(player.disabledSwitchVehicles) do
    local veh = getObjectByID(vid)
    if veh then
      veh.playerUsable = true
    end
  end
  player.disabledSwitchVehicles = nil
end

local function callAndStopTaxi()
  if not player.nearestTaxiId then return end
  local taxiId = player.nearestTaxiId
  if player.pickupTaxis[taxiId] then return end -- already engaged with the player

  -- reserve it right away (hailed: no drive-to target) so it isn't offered again while the driver reacts
  addPickupTaxi(taxiId, false, nil)

  core_jobsystem.create(function(job)
    local reactionTime = lerp(minReactionTime, maxReactionTime, math.random())
    job.sleep(reactionTime)

    if not player.pickupTaxis[taxiId] then return end -- dismissed/cancelled while the driver reacted

    local veh = getObjectByID(taxiId)
    if not veh then
      forgetPickupTaxi(taxiId)
      return
    end

    local playerVehId = be:getPlayerVehicleID(0)
    if not gameplay_util_vehicleSighting.canVehicleSeeVehicle(taxiId, playerVehId, getTaxiSightParams(taxiId)) then
      forgetPickupTaxi(taxiId) -- stays available so the player can try again
      showMessage(_tr("ui.taxi.didntNotice"), false, 3)
      return
    end

    gameplay_walk.removeVehicleFromBlacklist(taxiId)
    veh.playerUsable = true
    setTaxiState(taxiId, "pullingOverForPickup")
    showMessage(_tr("ui.taxi.pullingOver"), false)
  end, 1)
end


local function getPlayerRoadPos()
  local playerVehId = be:getPlayerVehicleID(0)
  local playerObj = map.objects[playerVehId]
  if not playerObj then return nil end
  local playerPos = playerObj.pos
  local n1, n2 = map.findClosestRoad(playerPos)
  if not n1 or not n2 then return nil end
  local nodes = map.getMap().nodes
  local p1, p2 = nodes[n1].pos, nodes[n2].pos
  local roadPos = linePointFromXnorm(p1, p2, clamp(playerPos:xnormOnLine(p1, p2), 0, 1))
  if playerPos:distance(roadPos) > callTaxiMaxRoadDist then return nil end
  return roadPos, n1, n2
end

local callTaxiRoutePlanner = require('/lua/ge/extensions/gameplay/route/route')()

local function driveTaxiToPlayerRoad(vehId)
  local roadPos = getPlayerRoadPos()
  if not roadPos then
    log("W", "taxi", "driveTaxiToPlayerRoad: getPlayerRoadPos returned nil (player too far from road?)")
    return nil
  end

  local veh = getObjectByID(vehId)
  if not veh then
    log("W", "taxi", "driveTaxiToPlayerRoad: vehicle " .. tostring(vehId) .. " not found")
    return nil
  end

  local vehPos = veh:getPosition()
  log("I", "taxi", string.format("driveTaxiToPlayerRoad: veh %d at (%.1f, %.1f, %.1f) -> roadPos (%.1f, %.1f, %.1f), straight dist %.1f",
    vehId, vehPos.x, vehPos.y, vehPos.z, roadPos.x, roadPos.y, roadPos.z, vehPos:distance(roadPos)))

  callTaxiRoutePlanner:setupPathMulti({vehPos, roadPos})
  if not (callTaxiRoutePlanner.path and callTaxiRoutePlanner.path[1]) then
    log("W", "taxi", "driveTaxiToPlayerRoad: route planner produced no path between veh and player road")
    return nil
  end
  log("I", "taxi", string.format("driveTaxiToPlayerRoad: route planner path has %d nodes", #callTaxiRoutePlanner.path))

  -- getAiPath has a side effect on player.skipPosition/skipRotation; preserve them
  local savedSkipPos, savedSkipRot = player.skipPosition, player.skipRotation
  local aiPath = getAiPath(callTaxiRoutePlanner.path, veh)
  player.skipPosition, player.skipRotation = savedSkipPos, savedSkipRot

  -- always anchor on the pickup road segment so short routes don't collapse to an empty list
  appendTargetApproach(aiPath, callTaxiRoutePlanner, veh, roadPos)

  if not aiPath or #aiPath == 0 then
    log("W", "taxi", string.format("driveTaxiToPlayerRoad: getAiPath returned empty (path nodes %d) - veh likely has no nav waypoint near it",
      #callTaxiRoutePlanner.path))
    return nil
  end
  log("I", "taxi", string.format("driveTaxiToPlayerRoad: issuing ai.driveUsingPath with %d waypoints to veh %d", #aiPath, vehId))

  local routeStr = '{wpTargetList = ' .. serialize(aiPath)
    .. ', noOfLaps = 1, aggression = 0.3, avoidCars = "on", driveInLane = "on", speedMode = "limit"}'
  veh:queueLuaCommand('ai.driveUsingPath(' .. routeStr .. ')')
  return roadPos
end

local function findCallTaxiSpawnPoint(playerPos)
  local camPos = core_camera and core_camera.getPosition()
  local camFwd = camPos and core_camera.getForward()
  if not camFwd then return nil end

  -- search behind the camera for an out-of-sight position
  local behindDir = -camFwd
  local spawnData = gameplay_traffic_trafficUtils.findSafeSpawnPoint(
    playerPos, behindDir, callTaxiSpawnMinDist, callTaxiSpawnMaxDist,
    callTaxiSpawnMinDist, {minDrivability = 0.5}
  )
  if not spawnData then return nil end

  -- pick the lane whose legal travel direction heads back toward the player, so the taxi spawns facing
  -- the pickup instead of having to U-turn. finalizeSpawnPoint offsets to the matching lane from roadDir.
  local nodes = map.getMap().nodes
  local roadDir = 1
  if spawnData.n1 and spawnData.n2 and nodes[spawnData.n1] and nodes[spawnData.n2] then
    local segDir = nodes[spawnData.n2].pos - nodes[spawnData.n1].pos
    roadDir = segDir:dot(playerPos - spawnData.pos) >= 0 and 1 or -1
  end

  local pos, dir = gameplay_traffic_trafficUtils.finalizeSpawnPoint(spawnData.pos, spawnData.dir, spawnData.n1, spawnData.n2, {legalDirection = true, roadDir = roadDir})
  local normal = map.surfaceNormal(pos, 1)
  local rot = quatFromDir(vec3(0, 1, 0):rotated(quatFromDir(dir, normal)), normal)
  return pos, rot
end

-- all hailable taxis sorted nearest-first, so the caller can try each in turn before falling back
local function findNearbyAvailableTaxis(playerPos)
  local playerVehId = be:getPlayerVehicleID(0)
  local candidates = {}
  for vehId, state in pairs(taxis) do
    if state == "available" and vehId ~= playerVehId and not player.pickupTaxis[vehId] and vehId ~= player.currentTaxiId then
      local veh = getObjectByID(vehId)
      if veh then
        candidates[#candidates + 1] = { id = vehId, dist = playerPos:distance(veh:getPosition()) }
      end
    end
  end
  table.sort(candidates, function(a, b) return a.dist < b.dist end)
  return candidates
end

local function cancelTaxiCall()
  if not hasCalledATaxi() then return end
  for vehId in pairs(player.pickupTaxis) do
    if player.pickupTaxis[vehId].called then
      dismissPickupTaxi(vehId)
    end
  end
  showMessage(_tr("ui.taxi.callCancelled"), false, 3)
end

local function canCallTaxi()
  if not getShouldSystemBeEnabled() then return false end
  if gameplay_traffic.getState() ~= 'on' then return false end
  if not next(taxis) then return false end
  local phase = player.currentPhase
  return phase == playerRidePhases.none or phase == playerRidePhases.awaitingPickup
end

-- Claims a reserved taxi from the traffic pool and dispatches it to the player. Returns true if
-- dispatch started, false on a synchronous failure (no reserved taxi / no spawn point);
local function dispatchReservedTaxi(playerPos)
  local claimed = gameplay_traffic.useReservedVehicle('taxi', 1)
  if not claimed[1] then
    return false
  end

  local taxiId = claimed[1]
  local spawnPos, spawnRot = findCallTaxiSpawnPoint(playerPos)
  if not spawnPos then
    gameplay_traffic.returnReservedVehicle(taxiId)
    return false
  end

  -- mark it as ours (en route) BEFORE respawning, so the reset triggered by the teleport
  -- doesn't roll its state back to available/unavailable. targetPos is filled in once routed (below)
  addPickupTaxi(taxiId, true, nil)
  setTaxiState(taxiId, "enRoute")

  gameplay_traffic.respawnVehicle(taxiId, spawnPos, spawnRot)

  -- wait for the traffic refresh cycle (reset -> onRefresh -> active) to finish,
  -- then issue our path command so it isn't overridden by traffic AI reset
  core_jobsystem.create(function(job)
    local trafficData = gameplay_traffic.getTrafficData()
    local trafficVeh = trafficData[taxiId]

    -- wait until the vehicle reaches 'active' state (onRefresh completed)
    for _ = 1, 10 do
      job.yield()
      if trafficVeh and trafficVeh.state == 'active' then break end
    end

    if not player.pickupTaxis[taxiId] then return end -- cancelled / dismissed while spawning

    local targetPos = driveTaxiToPlayerRoad(taxiId)
    if not targetPos then
      dismissPickupTaxi(taxiId, _tr("ui.taxi.noTaxiAvailable"))
      return
    end
    if player.pickupTaxis[taxiId] then
      player.pickupTaxis[taxiId].targetPos = targetPos
    end
  end, 1)

  showMessage(_tr("ui.taxi.onTheWay"), false, 4)
  return true
end

local function callForTaxi()
  if not canCallTaxi() then return end

  local playerVehId = be:getPlayerVehicleID(0)
  local playerObj = map.objects[playerVehId]
  if not playerObj then return end
  local playerPos = playerObj.pos

  local roadPos = getPlayerRoadPos()
  if not roadPos then
    showMessage(_tr("ui.taxi.tooFarFromRoad"), false, 4)
    return
  end

  -- prefer an already-active available taxi; try them nearest-first before claiming a reserved one
  local candidates = findNearbyAvailableTaxis(playerPos)
  for _, candidate in ipairs(candidates) do
    local nearbyId = candidate.id
    setTaxiState(nearbyId, "enRoute")
    gameplay_traffic.protectNonReservedVehicle(nearbyId, 'taxi') -- in-service: don't let traffic pool/swap it while en route
    local targetPos = driveTaxiToPlayerRoad(nearbyId)
    if targetPos then
      addPickupTaxi(nearbyId, true, targetPos)
      showMessage(_tr("ui.taxi.onTheWay"), false, 4)
      return
    end
    -- this taxi couldn't be routed; release it and try the next nearest
    gameplay_traffic.unprotectNonReservedVehicle(nearbyId)
    setTaxiState(nearbyId, "available")
  end

  -- no active taxi could reach the player; fall back to a reserved one
  if not dispatchReservedTaxi(playerPos) then
    showMessage(_tr("ui.taxi.noTaxiAvailable"), false, 4)
  end
end

local function leaveTaxi(message)
  -- charge the fare (career only)
  if player.fare and player.fare > 0 and career_career and career_career.isActive() and career_modules_payment then
    local label = _tr("ui.taxi.fareLabel")
    career_modules_payment.pay({money = {amount = player.fare, canBeNegative = true}}, {label = label})
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
  end

  restoreVehicleSwitching() -- always restore, even if the taxi vehicle is already gone, so the player isn't locked out of their car
  local veh = getObjectByID(player.currentTaxiId)
  if not veh then return end
  veh:queueLuaCommand('ai.setPullOver(false)')
  hurryUpLevels[1].apply(veh)
  veh:queueLuaCommand('ai.setState({mode = "traffic"})')
  setTaxiState(player.currentTaxiId, "unavailable")
  activateMergeBlinkers(player.currentTaxiId)
  gameplay_walk.addVehicleToBlacklist(player.currentTaxiId)
  getObjectByID(player.currentTaxiId).playerUsable = false

  if message then
    showMessage(message, false)
  end

  setPlayerPhase(playerRidePhases.none)
  player.disableIdleCamera = false
  player.currentTaxiId = nil
  player.chooseResumeMode = nil
  player.routePlanner:clear()

  if player.taxiViewActive then
    player.taxiViewActive = false
    extensions.ui_menuManager.setGameplayRoute(nil)
    local current = extensions.ui_router.getCurrent()
    if current and current.request and current.request.name == "taxi" then
      extensions.ui_router.navigate("play")
    end
  end
end

-- a taxi waiting at the pickup leaves if the player walks up to it then walks away (ratchet) OR the
-- wait timer elapses while the player is out of range. Each waiting pickup taxi is tracked independently.
local function updatePickupWait(dtReal)
  if not next(player.pickupTaxis) then return end
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then return end
  local playerPos = playerVeh:getPosition()
  local walking = gameplay_walk.isWalking()

  local toDismiss = nil
  for vehId, entry in pairs(player.pickupTaxis) do
    if taxis[vehId] == "waitingForPickup" then -- only once stopped and waiting
      local taxiVeh = getObjectByID(vehId)
      if taxiVeh then
        local dist = playerPos:distance(taxiVeh:getPosition())

        -- walked-away: track the closest approach, then bail if the player backs off past it
        if walking then
          entry.maxDist = math.min(entry.maxDist, dist + wiggleRoom)
        end

        if walking and dist > entry.maxDist then
          toDismiss = toDismiss or {}
          toDismiss[vehId] = _tr("ui.taxi.walkedAway")
        else
          -- waited-too-long: bail once the timer elapses and the player still isn't within pickup range
          entry.waitTimer = entry.waitTimer + dtReal
          if entry.waitTimer >= pickupWaitTime and dist > pickupAbandonRadius then
            toDismiss = toDismiss or {}
            toDismiss[vehId] = _tr("ui.taxi.waitedTooLong")
          end
        end
      end
    end
  end

  if toDismiss then
    for vehId, message in pairs(toDismiss) do
      dismissPickupTaxi(vehId, message)
    end
  end
end

local function makeTaxiPullOverWhileDriving(message)
  if not player.currentTaxiId then return end
  local veh = getObjectByID(player.currentTaxiId)
  if not veh then return end
  local trafficVeh = gameplay_traffic.getTrafficData()[player.currentTaxiId]
  if trafficVeh and trafficVeh.role then
    veh:queueLuaCommand('ai.setPullOver(false)')
    veh:queueLuaCommand('ai.setState({mode = "traffic"})')
    setPlayerPhase(playerRidePhases.arriving)

    if message then
      showMessage(message, false)
    end
  end
end

local function isTaxiAvailable()
  local phase = player.currentPhase
  return hailingEnabled
    and (phase == playerRidePhases.none or phase == playerRidePhases.awaitingPickup)
    and gameplay_walk.isWalking() and player.nearestTaxiId
end

-- detects called pickup taxis reaching their drive-to point (or ceased to exist en route). On arrival the taxi
-- starts pulling over and becomes enterable; the player boards it like any other waiting taxi.
local function updatePickupArrivals()
  if not next(player.pickupTaxis) then return end

  local arrived, lost = nil, nil
  for vehId, entry in pairs(player.pickupTaxis) do
    local taxiVeh = getObjectByID(vehId)
    if not taxiVeh then
      lost = lost or {}
      lost[#lost + 1] = vehId
    elseif entry.targetPos then -- en route to the pickup
      -- mimic a real cab: if the driver spots the player along the way, pull over early; otherwise
      -- carry on to the agreed road spot and wait there
      local playerVehId = be:getPlayerVehicleID(0)
      local sawPlayer = playerVehId and gameplay_util_vehicleSighting.canVehicleSeeVehicle(vehId, playerVehId, getTaxiSightParams(vehId))
      if sawPlayer or taxiVeh:getPosition():distance(entry.targetPos) < pullOverDistToDestination then
        arrived = arrived or {}
        arrived[#arrived + 1] = vehId
      end
    end
  end

  if lost then
    for _, vehId in ipairs(lost) do
      player.pickupTaxis[vehId] = nil
    end
    if player.currentPhase == playerRidePhases.awaitingPickup and not next(player.pickupTaxis) then
      player.currentPhase = playerRidePhases.none
      showMessage(_tr("ui.taxi.noTaxiAvailable"), false, 4)
    end
  end

  if arrived then
    for _, vehId in ipairs(arrived) do
      local entry = player.pickupTaxis[vehId]
      if entry then
        entry.targetPos = nil
        gameplay_walk.removeVehicleFromBlacklist(vehId)
        local veh = getObjectByID(vehId)
        if veh then veh.playerUsable = true end
        setTaxiState(vehId, "pullingOverForPickup")
        showMessage(_tr("ui.taxi.taxiArrived"), false, 4)
      end
    end
  end
end

local function updatePickupStuck(dtReal)
  if not next(player.pickupTaxis) then return end

  local toDismiss = nil
  for vehId, entry in pairs(player.pickupTaxis) do
    if entry.called and entry.targetPos and taxis[vehId] == "enRoute" then
      local veh = getObjectByID(vehId)
      if veh then
        local pos = veh:getPosition()
        if not entry.stuckCheckPos then
          entry.stuckCheckPos = vec3(pos)
          entry.stuckTimer = 0
        elseif pos:distance(entry.stuckCheckPos) >= stuckDistThreshold then
          entry.stuckCheckPos = vec3(pos)
          entry.stuckTimer = 0
        else
          entry.stuckTimer = entry.stuckTimer + dtReal
          if entry.stuckTimer >= stuckTimeThreshold then
            toDismiss = toDismiss or {}
            toDismiss[vehId] = true
          end
        end
      end
    end
  end

  if toDismiss then
    for vehId in pairs(toDismiss) do
      dismissPickupTaxi(vehId, _tr("ui.taxi.stuck"))
    end
  end
end

local function updateFare(veh, dtReal)
  if not (veh and player.fareData and player.fareCalculator) then return end
  local speed = veh:getVelocity():len()
  player.fareData.distanceTraveled = player.fareData.distanceTraveled + speed * dtReal
  player.fareData.elapsedTime = player.fareData.elapsedTime + dtReal
  if speed < 0.5 then
    player.fareData.stationaryTime = player.fareData.stationaryTime + dtReal
  end
  player.fare = player.fareCalculator(player.fareData)
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not be:getPlayerVehicle(0) then return end
  if not next(taxis) and not next(player.pickupTaxis) then return end

  checkAndFindNearestTaxi()
  updateTaxiPullOver()
  if useBillboards then drawTaxiLabels() end

  if isTaxiAvailable() then
    guihooks.trigger('Message', hailMessage)
  end

  updatePickupArrivals()
  updatePickupStuck(dtReal)
  updatePickupWait(dtReal)

  if player.currentTaxiId and (player.currentPhase == playerRidePhases.driving or player.currentPhase == playerRidePhases.arriving) then
    local veh = getObjectByID(player.currentTaxiId)
    if veh then
      player.routePlanner:trackVehicle(veh)
    end

    if player.currentPhase == playerRidePhases.driving then
      checkIdleCamera(dtSim)
      if veh and player.destinationPos and veh:getPosition():distance(player.destinationPos) < pullOverDistToDestination then
        makeTaxiPullOverWhileDriving(_tr("ui.taxi.arrived"))
      end
    end

    if player.currentPhase == playerRidePhases.arriving or player.currentPhase == playerRidePhases.choosingDestination or player.currentPhase == playerRidePhases.driving then
      updateFare(veh, dtReal)
    end

    if player.currentPhase == playerRidePhases.arriving and taxis[player.currentTaxiId] == "waitingForDropoff" then
      player.dropoffKickTimer = player.dropoffKickTimer + dtReal
      if player.dropoffKickTimer >= dropoffKickDelay then
        player.dropoffKickTimer = 0
        showMessage(_tr("ui.taxi.kickedOut"), false, 4)
        gameplay_walk.setWalkingMode(true, nil, nil, true)
      end
    else
      player.dropoffKickTimer = 0
    end

    player.uiUpdateTimer = player.uiUpdateTimer + dtReal
    if player.uiUpdateTimer >= uiUpdateInterval then
      player.uiUpdateTimer = 0
      pushTaxiUIUpdate()
    end
  end
end

local function onVehicleSwitched(oldId, newId)
  -- player entered one of the pickup taxis: it becomes the active ride; dismiss all the others
  if player.pickupTaxis[newId] then
    player.pickupTaxis[newId] = nil
    dismissAllPickupTaxis(newId)
    player.currentTaxiId = newId
    gameplay_traffic.protectNonReservedVehicle(newId, 'taxi')
    local trafficVeh = gameplay_traffic.getTrafficData()[newId]
    if trafficVeh then trafficVeh.ignoreForceTeleport = true end

    player.hurryUpLevel = 1
    player.hasSkipped = false

    -- resolve fare calculator for this taxi (career only)
    if career_career and career_career.isActive() then
      local veh = getObjectByID(newId)
      local model = veh and veh:getJBeamFilename()
      local matchedConfig = nil
      if model then
        for _, cfg in ipairs(taxiConfigs) do
          if cfg.model == model then matchedConfig = cfg break end
        end
      end
      matchedConfig = matchedConfig or taxiConfigs[1]
      player.fareCalculator = matchedConfig.calculateFare or defaultCalculateFare
      player.fareData = {
        distanceTraveled = 0,
        stationaryTime = 0,
        elapsedTime = 0,
        isNight = core_environment and core_environment.getLightState().isNight or false,
        fareConfig = matchedConfig,
      }
      player.fare = 0
    end

    blockVehicleSwitching()
    if core_camera then
      player.cameraBeforeTaxi = core_camera.getActiveCamName()
      core_camera.setByName(0, taxiCameraMode)
    end
    -- initial destination choice: nothing to resume if the map is closed without picking
    player.chooseResumeMode = nil
    core_jobsystem.create(function(job)
      job.sleep(delayToOpenBigMap)
      setPlayerPhase(playerRidePhases.choosingDestination)
      freeroam_bigMapMode.enterBigMap({mode = "taxi"})
    end, 1)
  end

  -- player exited the taxi
  if oldId == player.currentTaxiId then
    if core_camera and player.cameraBeforeTaxi then
      core_camera.setByName(0, player.cameraBeforeTaxi)
      player.cameraBeforeTaxi = nil
    end
    leaveTaxi()
  end
end

local function onChangeDestinationCalled()
  resetIdleCameraTimer()
  if player.currentPhase == playerRidePhases.driving then
    setIdleCamera(false)
    setPlayerPhase(playerRidePhases.choosingDestination)
    -- if no new destination, keep driving
    player.chooseResumeMode = "drive"
  elseif player.currentPhase == playerRidePhases.arriving then -- waiting for drop off
    setIdleCamera(false)
    local veh = getObjectByID(player.currentTaxiId)
    if veh then veh:queueLuaCommand('ai.setPullOver(false)') end
    setPlayerPhase(playerRidePhases.choosingDestination)
    -- if the map is closed without picking, go back to waiting for dropoff (don't strand the player)
    player.chooseResumeMode = "arrive"
  elseif player.currentPhase ~= playerRidePhases.choosingDestination then
    return
  end
  -- defer opening so the radial menu fully closes first
  core_jobsystem.create(function(job)
    job.sleep(delayToOpenBigMap)
    freeroam_bigMapMode.enterBigMap({mode = "taxi"})
  end, 1)
end

local function setHurryUpLevel(delta)
  resetIdleCameraTimer()
  if player.currentPhase ~= playerRidePhases.driving then return end
  local newLevel = player.hurryUpLevel + delta
  if newLevel < 1 or newLevel > #hurryUpLevels then return end
  local veh = getObjectByID(player.currentTaxiId)
  if not veh then return end
  player.hurryUpLevel = newLevel
  hurryUpLevels[newLevel].apply(veh)
  pushTaxiUIUpdate()
end

local function onHurryUpCalled() setHurryUpLevel(1) end
local function onSlowDownCalled() setHurryUpLevel(-1) end

local function onSkipCalled()
  resetIdleCameraTimer()
  if player.currentPhase ~= playerRidePhases.driving or player.hasSkipped then return end

  player.hasSkipped = true

  -- snapshot the targets so a route change can't turn them nil while the job runs
  local targetPos = player.skipPosition
  local targetRot = player.skipRotation

  core_jobsystem.create(function(job)
    -- guarantee physics returns to normal even if the job dies between the 2x and 0 calls
    job.setExitCallback(function() be:setPhysicsSpeedFactor(0) end)

    ui_fadeScreen.start(fadeToBlackDuration)
    job.sleep(fadeToBlackDuration + 0.1)

    setIdleCamera(false)
    job.sleep(0.1)

    player.disableIdleCamera = true
    -- destinationPos persists from the original pick, so the private planner rebuilds
    -- the route from the teleport spot without needing the shared ground-marker planner
    startTaxiWithCurrentRoute(true)

    local veh = getObjectByID(player.currentTaxiId)
    if veh then
      spawn.safeTeleport(veh, targetPos, targetRot, true, nil, false)
      be:setPhysicsSpeedFactor(2) --so that the taxi gets up to speed faster
      job.sleep(accelerationTime)
      be:setPhysicsSpeedFactor(0)
    end

    player.disableIdleCamera = false
    ui_fadeScreen.stop(fadeToBlackDuration)
  end, 1)
end

local function setIdleCameraEnabled(enabled)
  player.idleCameraUserEnabled = enabled
  if not enabled then
    if player.idleCameraActive then
      setIdleCamera(false)
    end
    ui_fadeScreen.stop(fadeToBlackDuration)
  end
  resetIdleCameraTimer()
  pushTaxiUIUpdate()
end

local function onStopTaxiCalled()
  resetIdleCameraTimer()
  if player.currentPhase ~= playerRidePhases.driving then return end
  if not player.currentTaxiId then return end
  local veh = getObjectByID(player.currentTaxiId)
  if not veh then return end

  local speed = veh:getVelocity():len()
  if speed > slowSpeedThreshold then
    makeTaxiPullOverWhileDriving(_tr("ui.taxi.stoppingHere"))
  else
    setPlayerPhase(playerRidePhases.arriving, _tr("ui.taxi.canClimbOut"))
  end
end

local function onAiRouteDone(vehId)
  if vehId ~= player.currentTaxiId then return end
  if player.currentPhase ~= playerRidePhases.driving then return end
  if not getObjectByID(player.currentTaxiId) then return end
  setPlayerPhase(playerRidePhases.arriving)
end

local function onGameplayInteract()
  if player.currentPhase == playerRidePhases.driving then
    onStopTaxiCalled()
  elseif isTaxiAvailable() then
    callAndStopTaxi()
  end
end

local previewPlanner = require('/lua/ge/extensions/gameplay/route/route')()

local function getPreviewRouteLength(vehPos, destPos)
  previewPlanner:setupPathMulti({vehPos, destPos})
  local dist = routeDistanceLeft(previewPlanner, vehPos)
  if not dist or dist <= 0 then return nil end
  local val, unit = translateDistance(dist, "auto")
  return string.format("%.1f %s", val, unit)
end

local function onSetBigmapNavFocus(pos)
  if player.currentPhase ~= playerRidePhases.choosingDestination then return end
  if not pos then
    player.destinationPos = nil
    guihooks.trigger("TaxiDestinationPreviewed", { set = false })
    return
  end
  player.destinationPos = vec3(pos)
  local veh = player.currentTaxiId and getObjectByID(player.currentTaxiId)
  local routeLength = veh and getPreviewRouteLength(veh:getPosition(), player.destinationPos) or nil
  guihooks.trigger("TaxiDestinationPreviewed", { set = true, routeLength = routeLength })
end

local function confirmTaxiDestination()
  if player.currentPhase ~= playerRidePhases.choosingDestination or not player.destinationPos then return end
  player.chooseResumeMode = nil
  startTaxiWithCurrentRoute()
end

local function onDeactivateBigMapCallback()
  -- only react if the map closed while still choosing a destination (no pick happened)
  if player.currentPhase ~= playerRidePhases.choosingDestination then return end
  freeroam_bigMapMode.setNavFocus(nil)
  if player.chooseResumeMode == "drive" then
    -- player cancelled a "change destination"; the old route is still active, resume it
    setPlayerPhase(playerRidePhases.driving)
  elseif player.chooseResumeMode == "arrive" then
    -- player cancelled picking a new destination at the dropoff; go back to waiting for dropoff
    setPlayerPhase(playerRidePhases.arriving, _tr("ui.taxi.canClimbOut"))
  else
    -- initial pick cancelled; show the taxi view so the player can re-open the map
    player.taxiViewActive = true
    extensions.ui_menuManager.setGameplayRoute("taxi")
    extensions.ui_router.navigate("taxi")
    pushTaxiUIUpdate()
  end
  player.chooseResumeMode = nil
end

local function onVehicleResetted(id)
  -- never re-roll the active ride taxi or a taxi that's coming to / waiting for the player
  if taxis[id] and id ~= player.currentTaxiId and not player.pickupTaxis[id] then
    taxis[id] = nil -- clear so setTaxiState re-sends the lightState after vlua rebuild
    setTaxiState(id, rollAvailability(id))
  end
end

local function onTaxiViewEnter(context, toRoute, fromRoute, data)
  data.taxi = getTaxiViewData()
end


local function onTrafficVehicleCrashed(vehId)
  if not taxis[vehId] then return end

  if player.pickupTaxis[vehId] then
    -- a taxi coming to / waiting for the player crashed: drop it from the pickup set
    dismissPickupTaxi(vehId, _tr("ui.taxi.crashed"))
  elseif vehId == player.currentTaxiId then
    setIdleCamera(false)
    player.disableIdleCamera = true
  else
    -- any other traffic taxi: just mark it unavailable so it won't be hailed
    setTaxiState(vehId, "unavailable")
  end

  local veh = getObjectByID(vehId)
  if veh then
    veh:queueLuaCommand('local c = controller.getController("taxiLights") if c then c.setTaxiState("driverDistress") end')
  end
end

local function onRegisterQuickAccessMenus()
  if not core_quickAccess then return end
  -- register actions inside the Taxi category
  core_quickAccess.addEntry({
    level = '/root/sandbox/other/',
    uniqueID = 'callTaxiActions',
    generator = function(entries)
      if not canCallTaxi() then return end
      if hasCalledATaxi() then
        table.insert(entries, {
          title = 'ui.taxi.cancelCall', icon = 'xmark', uniqueID = 'callTaxi',
          onSelect = function() cancelTaxiCall() return {'hide'} end,
        })
      else
        table.insert(entries, {
          title = 'ui.taxi.callTaxi', icon = 'taxiCheckerLamp', uniqueID = 'callTaxi',
          onSelect = function() callForTaxi() return {'hide'} end,
        })
      end
    end,
  })

  if career_career and career_career.isActive() then
    core_quickAccess.addEntry({ level = '/root/sandbox/career/', title = 'Taxi', icon = 'taxiCheckerLamp', ["goto"] = '/root/sandbox/career/taxi/', uniqueID = 'taxiCategoryCareer' })
    core_quickAccess.addEntry({
      level = '/root/sandbox/career/taxi/',
      uniqueID = 'callTaxiActionsCareer',
      generator = function(entries)
        if not canCallTaxi() then return end
        if hasCalledATaxi() then
          table.insert(entries, {
            title = 'ui.taxi.cancelCall', icon = 'xmark', uniqueID = 'callTaxiCareer',
            onSelect = function() cancelTaxiCall() return {'hide'} end,
          })
        else
          table.insert(entries, {
            title = 'ui.taxi.callTaxi', icon = 'smartphone1', uniqueID = 'callTaxiCareer',
            onSelect = function() callForTaxi() return {'hide'} end,
          })
        end
      end,
    })
  end
end

local function isTaxiRideActive() return player.currentPhase == playerRidePhases.driving or player.currentPhase == playerRidePhases.arriving end
local function isTaxiActive() return player.taxiViewActive end

M.startTaxiWithCurrentRoute = startTaxiWithCurrentRoute

M.getTaxiState = getTaxiState
M.isTaxiViewActive = isTaxiActive
M.isTaxiRideActive = isTaxiRideActive
M.getTaxiViewData = getTaxiViewData
M.onTaxiViewEnter = onTaxiViewEnter
M.onStopTaxiCalled = onStopTaxiCalled
M.onAiRouteDone = onAiRouteDone

M.onChangeDestinationCalled = onChangeDestinationCalled
M.onHurryUpCalled = onHurryUpCalled
M.onSlowDownCalled = onSlowDownCalled
M.onSkipCalled = onSkipCalled
M.setIdleCameraEnabled = setIdleCameraEnabled

M.onSetBigmapNavFocus = onSetBigmapNavFocus
M.confirmTaxiDestination = confirmTaxiDestination
M.onDeactivateBigMapCallback = onDeactivateBigMapCallback
M.onTrafficSpecialVehiclesProviders = onTrafficSpecialVehiclesProviders
M.onTrafficStarted = onTrafficStarted
M.onTrafficVehicleAdded = onTrafficVehicleAdded
M.onTrafficVehicleRemoved = onTrafficVehicleRemoved
M.onTrafficStopped = onTrafficStopped
M.onAnyMissionChanged = onAnyMissionChanged
M.taxiSettingChanged = taxiSettingChanged
M.onTrafficVehicleCrashed = onTrafficVehicleCrashed
M.onVehicleResetted = onVehicleResetted
M.onVehicleSwitched = onVehicleSwitched
M.onGameplayInteract = onGameplayInteract
M.onUpdate = onUpdate
M.onRegisterQuickAccessMenus = onRegisterQuickAccessMenus
M.callForTaxi = callForTaxi
M.cancelTaxiCall = cancelTaxiCall
M.setUseBillboards = function(enabled)
  useBillboards = enabled
  if not enabled then clearTaxiBillboards() end
  log("I", "taxi", "useBillboards = " .. tostring(enabled))
end

local bbRenderer
local taxiBillboards = {} -- vehId -> { bbId, stateKey, topZ }
local bbUpdatePos = vec3()
local bbHidePos = vec3(0, 0, 0)

local stateAccents = {
  available            = "#00ff2aff",
  enRoute              = "#00ccffff",
  pullingOverForPickup = "#ffbb00ff",
  waitingForPickup     = "#00ccffff",
  unavailable          = "#ff2222ff",
}

local function ensureBBRenderer()
  if bbRenderer and bbRenderer.create then return bbRenderer end
  if scenetree and scenetree.taxiStateTags then bbRenderer = scenetree.taxiStateTags; return bbRenderer end
  if not (WorldBillboardRenderer and scenetree and scenetree.MissionGroup) then return nil end
  local r = WorldBillboardRenderer()
  if not r then return nil end
  r:registerObject("taxiStateTags")
  scenetree.MissionGroup:addObject(r)
  bbRenderer = r
  return r
end

local DOME_W, DOME_H = 512, 240
local domePath = string.format("M 0 %d A %d %d 0 0 1 %d %d Z", DOME_H, DOME_W / 2, DOME_H, DOME_W, DOME_H)

local function buildLabelTemplate(label, accent)
  return {
    size = {DOME_W, DOME_H},
    root = {
      type = "group",
      style = {justifyContent = "center", alignItems = "center", paddingTop = 50, paddingBottom = 16},
      children = {
        {type = "path", path = domePath,
         color = "#000000aa", stroke = "#ffffffee", strokeWidth = 4,
         style = {position = "absolute", left = 0, top = 0, width = DOME_W, height = DOME_H}},
        {type = "text", text = "TAXI", fontSize = 48, color = "#ffffffff",
         letterSpacing = 10, style = {height = 56}},
        {type = "text", text = label, fontSize = 72, color = accent, fit = "shrink",
          style = {width = "75%", height = 84}},
      },
    },
  }
end

local function destroyBillboard(vehId)
  local data = taxiBillboards[vehId]
  if data and bbRenderer then pcall(function() bbRenderer:destroy(data.bbId) end) end
  taxiBillboards[vehId] = nil
end

local function refreshBillboard(vehId, stateKey)
  local r = ensureBBRenderer()
  if not r then return end
  destroyBillboard(vehId)

  local stateDef = taxiStates[stateKey]
  local accent = stateAccents[stateKey]
  if not (stateDef and stateDef.displayInfo and accent) then return end

  local tmpl = buildLabelTemplate(stateDef.displayInfo.label, accent)
  local id = r:create(jsonEncode(tmpl), false)
  if id and id ~= 0 then
    r:render(id, "{}")
    local veh = getObjectByID(vehId)
    local topZOffset = 0
    if veh then
      local oobb = veh:getSpawnWorldOOBB()
      local he = oobb:getHalfExtents()
      topZOffset = math.abs(oobb:getAxis(0).z) * he.x
        + math.abs(oobb:getAxis(1).z) * he.y
        + math.abs(oobb:getAxis(2).z) * he.z
    end
    taxiBillboards[vehId] = {bbId = id, stateKey = stateKey, topZOffset = topZOffset}
  end
end

local bbBaseScale = 0.8
local bbRefDist   = 15
local bbFadeNear  = 40
local bbFadeFar   = 45
local bbAspect    = DOME_H / DOME_W

local function updateTaxiBillboards()
  if not gameplay_walk.isWalking() then
    for vehId in pairs(taxiBillboards) do destroyBillboard(vehId) end
    return
  end

  local r = ensureBBRenderer()
  if not r then return end

  local camPos = core_camera and core_camera.getPosition() or nil

  for vehId, stateKey in pairs(taxis) do
    local veh = getObjectByID(vehId)
    if not veh or not be:getObjectActive(vehId) then
      destroyBillboard(vehId)
    else
      local data = taxiBillboards[vehId]
      if not data or data.stateKey ~= stateKey then
        refreshBillboard(vehId, stateKey)
        data = taxiBillboards[vehId]
      end
      if data and camPos then
        local center = veh:getSpawnWorldOOBB():getCenter()
        local topZ = center.z + data.topZOffset

        local dist = camPos:distance(center)

        if dist > bbFadeFar then
          r:update(data.bbId, bbHidePos, 0, false)
        else
          local fade = dist < bbFadeNear and 1 or (1 - (dist - bbFadeNear) / (bbFadeFar - bbFadeNear))
          local scale = bbBaseScale * (dist / bbRefDist) * fade
          bbUpdatePos.x = center.x
          bbUpdatePos.y = center.y
          bbUpdatePos.z = topZ + scale * 0.5
          r:update(data.bbId, bbUpdatePos, scale, true)
        end
      elseif data then
        r:update(data.bbId, bbHidePos, 0, false)
      end
    end
  end

  for vehId in pairs(taxiBillboards) do
    if not taxis[vehId] then destroyBillboard(vehId) end
  end
end

drawTaxiLabels = updateTaxiBillboards

local function nukeBillboards()
  local r = scenetree and scenetree.taxiStateTags
  if r then r:deleteObject() end
  bbRenderer = nil
  table.clear(taxiBillboards)
end

clearTaxiBillboards = nukeBillboards

M.onClientEndMission = onTrafficStopped
M.onExtensionUnloaded = nukeBillboards

return M
