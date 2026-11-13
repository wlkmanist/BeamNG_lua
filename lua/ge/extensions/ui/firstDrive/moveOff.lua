-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"ui_appContainers"}

local CONTAINER_ID = "topCenter"
local APP_ID = "moveOff"
local STATE_EVENT = "FirstDriveMoveOffState"
local SECTION_DELAY = 2
-- Vehicle values need a few frames to refresh after (re)registering or a gearbox mode change.
local SETTLE_DELAY = 0.3
local MOVING_SPEED_THRESHOLD = 0.5
local REVERSING_SPEED_THRESHOLD = 1.5
local RELEASE_CLUTCH_RPM_THRESHOLD = 1500
local BRAKE_THRESHOLD = 0.2
local CLUTCH_HELD_THRESHOLD = 0.8
local CLUTCH_RELEASED_THRESHOLD = 0.15
local FIRST_GEAR = 1
local NEUTRAL_GEAR = 0

local trackedKeys = {
  "throttle_input",
  "brake_input",
  "clutch_input",
  "gearIndex",
  "engineRunning",
  "rpm",
  "wheelspeed",
}

local actions = {
  throttle = {action = "accelerate", label = "ui.inputActions.vehicle.accelerate.title"},
  throttleArcade = {action = "accelerate", label = "ui.experiences.firstDrive.drivingAssists.forward"},
  brake = {action = "brake", label = "ui.inputActions.vehicle.brake.title"},
  brakeArcade = {action = "brake", label = "ui.experiences.firstDrive.drivingAssists.backward"},
  clutch = {action = "clutch", label = "ui.inputActions.vehicle.clutch.title"},
  shiftUp = {action = "shiftUp", label = "ui.inputActions.vehicle.shiftUp.title"},
  shiftDown = {action = "shiftDown", label = "ui.inputActions.vehicle.shiftDown.title"},
  starter = {action = "activateStarterMotor", label = "ui.inputActions.vehicle.toggleIgnitonLevel.title"},
}

local enabled = false
local trackedVehicleId
local mode
local phase = "engineOn"
local nextPhase
local sectionDelayRemaining = 0
local sectionDelayState
local settleRemaining = 0
local reverseDone = false
local currentState
local currentStateSignature
local requestToken = 0
local completedSection

local function setVisible(visible)
  ui_appContainers.setAppVisibility(CONTAINER_ID, APP_ID, visible)
end

local function unregisterVehicle()
  local vehicle = trackedVehicleId and getObjectByID(trackedVehicleId) or nil
  if vehicle then
    for _, key in ipairs(trackedKeys) do
      core_vehicleBridge.unregisterValueChangeNotification(vehicle, key)
    end
  end
  trackedVehicleId = nil
end

local function applySectionProgress(state, currentPhase)
  currentPhase = currentPhase or phase
  if currentPhase == "stopping" and reverseDone then currentPhase = "reverse" end
  if mode == "realisticManual" then
    local indexes = {
      engineNeutral = 1,
      engineOn = 2,
      startEngine = 2,
      moveOff = 3,
      stopping = 4,
      reverse = 5,
      engineOff = 6,
    }
    state.sectionIndex = indexes[currentPhase] or 1
    state.sectionCount = 6
    return
  end

  local indexes = {
    engineOn = 1,
    startEngine = 1,
    moveOff = 2,
    stopping = 3,
    reverse = 4,
    engineOff = 5,
  }
  state.sectionIndex = indexes[currentPhase] or 1
  state.sectionCount = 5
end

local function stateSignature(state)
  local signature = state.label .. "|" .. state.sectionIndex .. ":" .. state.sectionCount
  for _, step in ipairs(state.steps) do
    signature = signature .. "|" .. step.action .. ":" .. step.actionLabel .. ":" .. step.inputType .. ":" .. step.status .. ":" .. (step.separator or "")
  end
  return signature
end

local function publishState(state)
  if not state.sectionIndex then applySectionProgress(state) end
  local signature = stateSignature(state)
  if signature == currentStateSignature then return end
  currentState = state
  currentState.active = true
  currentStateSignature = signature
  setVisible(true)
  guihooks.trigger(STATE_EVENT, currentState)
end

local function step(action, inputType)
  return {
    action = action.action,
    actionLabel = action.label,
    inputType = inputType,
  }
end

local function instruction(label, steps, currentStep)
  for index, instructionStep in ipairs(steps) do
    if not currentStep or index < currentStep then
      instructionStep.status = "complete"
    elseif index == currentStep then
      instructionStep.status = "current"
    else
      instructionStep.status = "upcoming"
    end
  end
  return {
    label = label,
    steps = steps,
  }
end

local function arcadeSteps()
  return {
    step(actions.throttleArcade, "press"),
  }
end

local function arcadeEngineStartSteps()
  local starterStep = step(actions.starter, "hold")
  starterStep.separator = "or"
  return {
    starterStep,
    step(actions.throttleArcade, "press"),
  }
end

local function autoClutchSteps(shiftAction)
  return {
    step(shiftAction or actions.shiftUp, "press"),
    step(actions.throttle, "press"),
  }
end

local function manualClutchSteps(shiftAction)
  return {
    step(actions.clutch, "hold"),
    step(shiftAction or actions.shiftUp, "press"),
    step(actions.throttle, "press"),
    step(actions.clutch, "release"),
  }
end

local function stoppingSteps(shiftAction, gearIndex)
  if mode == "arcade" then
    -- Arcade reverses on the brake, so the throttle is what stops a reversing car.
    return {
      step(gearIndex < NEUTRAL_GEAR and actions.throttleArcade or actions.brakeArcade, "hold"),
    }
  end
  if mode == "realisticAutoClutch" then
    return {
      step(actions.brake, "hold"),
      step(shiftAction or actions.shiftDown, "press"),
    }
  end
  return {
    step(actions.clutch, "hold"),
    step(actions.brake, "hold"),
    step(shiftAction or actions.shiftDown, "press"),
    step(actions.clutch, "release"),
  }
end

local function shiftTowardNeutral(gearIndex)
  return gearIndex < NEUTRAL_GEAR and actions.shiftUp or actions.shiftDown
end

local function beginSectionDelay(targetPhase, state)
  applySectionProgress(state, phase)
  phase = "delay"
  nextPhase = targetPhase
  sectionDelayRemaining = SECTION_DELAY
  sectionDelayState = state
  return state
end

local engineOnInstruction

local function engineNeutralInstruction(engineRunning, gearIndex, clutchInput)
  if engineRunning ~= nil and engineRunning > 0 then
    completedSection = "engineOn"
    return beginSectionDelay(
      "moveOff",
      instruction(
        "ui.experiences.firstDrive.moveOff.engineOn",
        {step(actions.starter, "hold")}
      )
    )
  end

  if gearIndex == NEUTRAL_GEAR and clutchInput <= CLUTCH_RELEASED_THRESHOLD then
    phase = "startEngine"
    return engineOnInstruction(engineRunning, gearIndex, clutchInput)
  end

  local steps = {
    step(actions.clutch, "hold"),
    step(shiftTowardNeutral(gearIndex), "press"),
    step(actions.clutch, "release"),
  }
  if gearIndex ~= NEUTRAL_GEAR then
    return instruction(
      "ui.experiences.firstDrive.moveOff.shiftNeutral",
      steps,
      clutchInput >= CLUTCH_HELD_THRESHOLD and 2 or 1
    )
  end
  if clutchInput > CLUTCH_RELEASED_THRESHOLD then
    return instruction(
      "ui.experiences.firstDrive.moveOff.releaseClutchNeutral",
      steps,
      3
    )
  end
  return beginSectionDelay(
    "startEngine",
    instruction("ui.experiences.firstDrive.moveOff.neutralReady", steps)
  )
end

engineOnInstruction = function(engineRunning, gearIndex, clutchInput)
  if engineRunning ~= nil and engineRunning > 0 then
    completedSection = "engineOn"
    local steps = mode == "arcade"
      and arcadeEngineStartSteps()
      or {step(actions.starter, "hold")}
    return beginSectionDelay(
      "moveOff",
      instruction(
        "ui.experiences.firstDrive.moveOff.engineOn",
        steps
      )
    )
  end

  if mode == "arcade" then
    local state = instruction(
      "ui.experiences.firstDrive.moveOff.turnEngineOnArcade",
      arcadeEngineStartSteps(),
      1
    )
    state.steps[2].status = "current"
    return state
  end

  local shiftToNeutral = shiftTowardNeutral(gearIndex)
  if mode == "realisticAutoClutch" then
    local steps = {
      step(shiftToNeutral, "press"),
      step(actions.starter, "hold"),
    }
    return instruction(
      gearIndex ~= NEUTRAL_GEAR
          and "ui.experiences.firstDrive.moveOff.shiftNeutralAuto"
        or "ui.experiences.firstDrive.moveOff.turnEngineOn",
      steps,
      gearIndex ~= NEUTRAL_GEAR and 1 or 2
    )
  end

  return instruction(
    "ui.experiences.firstDrive.moveOff.turnEngineOn",
    {step(actions.starter, "hold")},
    1
  )
end

local function moveOffInstruction(clutchInput, gearIndex, rpm, moving)
  if moving then
    completedSection = "moveOff"
    local steps = mode == "arcade" and arcadeSteps()
      or mode == "realisticAutoClutch" and autoClutchSteps()
      or manualClutchSteps()
    return beginSectionDelay(
      "stopping",
      instruction("ui.experiences.firstDrive.moveOff.moving", steps)
    )
  end

  if mode == "arcade" then
    return instruction(
      "ui.experiences.firstDrive.moveOff.pressThrottle",
      arcadeSteps(),
      1
    )
  end

  if gearIndex ~= FIRST_GEAR then
    local shiftToFirst = gearIndex > FIRST_GEAR and actions.shiftDown or actions.shiftUp
    if mode == "realisticAutoClutch" then
      return instruction(
        "ui.experiences.firstDrive.moveOff.shiftFirst",
        autoClutchSteps(shiftToFirst),
        1
      )
    end
    return instruction(
      clutchInput < CLUTCH_HELD_THRESHOLD
        and "ui.experiences.firstDrive.moveOff.holdClutch"
        or "ui.experiences.firstDrive.moveOff.shiftFirst",
      manualClutchSteps(shiftToFirst),
      clutchInput < CLUTCH_HELD_THRESHOLD and 1 or 2
    )
  end

  if mode == "realisticAutoClutch" then
    return instruction(
      "ui.experiences.firstDrive.moveOff.pressThrottle",
      autoClutchSteps(),
      2
    )
  end

  if rpm <= RELEASE_CLUTCH_RPM_THRESHOLD then
    return instruction(
      "ui.experiences.firstDrive.moveOff.pressThrottleWithClutch",
      manualClutchSteps(),
      3
    )
  end

  if clutchInput > CLUTCH_RELEASED_THRESHOLD then
    return instruction(
      "ui.experiences.firstDrive.moveOff.releaseClutch",
      manualClutchSteps(),
      4
    )
  end

  return instruction(
    "ui.experiences.firstDrive.moveOff.keepThrottle",
    manualClutchSteps()
  )
end

local function stoppingInstruction(brake, clutchInput, gearIndex, moving)
  local steps = stoppingSteps(shiftTowardNeutral(gearIndex), gearIndex)
  if moving then
    if mode == "realisticManual" and clutchInput < CLUTCH_HELD_THRESHOLD then
      return instruction(
        "ui.experiences.firstDrive.moveOff.stopHoldClutch",
        steps,
        1
      )
    end
    if mode == "arcade" and gearIndex < NEUTRAL_GEAR then
      return instruction("ui.experiences.firstDrive.moveOff.stopReversingArcade", steps, 1)
    end
    return instruction(
      brake < BRAKE_THRESHOLD
        and "ui.experiences.firstDrive.moveOff.brakeToStop"
        or "ui.experiences.firstDrive.moveOff.keepBraking",
      steps,
      mode == "realisticManual" and 2 or 1
    )
  end

  if mode ~= "arcade" and gearIndex ~= NEUTRAL_GEAR then
    return instruction(
      mode == "realisticManual"
        and "ui.experiences.firstDrive.moveOff.shiftNeutral"
        or "ui.experiences.firstDrive.moveOff.shiftNeutralAuto",
      steps,
      mode == "realisticManual" and 3 or 2
    )
  end

  if mode == "realisticManual" and clutchInput > CLUTCH_RELEASED_THRESHOLD then
    return instruction(
      "ui.experiences.firstDrive.moveOff.releaseClutchNeutral",
      steps,
      4
    )
  end

  completedSection = "stopping"
  return beginSectionDelay(
    reverseDone and "engineOff" or "reverse",
    instruction("ui.experiences.firstDrive.moveOff.stopped", steps)
  )
end

local function reverseInstruction(clutchInput, gearIndex, rpm, wheelSpeed)
  local inReverse = gearIndex < NEUTRAL_GEAR
  local steps
  if mode == "arcade" then
    steps = {step(actions.brakeArcade, "hold")}
  elseif mode == "realisticAutoClutch" then
    steps = autoClutchSteps(actions.shiftDown)
  else
    steps = manualClutchSteps(actions.shiftDown)
  end

  if inReverse and wheelSpeed >= REVERSING_SPEED_THRESHOLD then
    completedSection = "reverse"
    reverseDone = true
    return beginSectionDelay("stopping", instruction("ui.experiences.firstDrive.moveOff.reversing", steps))
  end

  if mode == "arcade" then
    return instruction("ui.experiences.firstDrive.moveOff.reverseArcade", steps, 1)
  end

  if mode == "realisticAutoClutch" then
    if not inReverse then
      return instruction("ui.experiences.firstDrive.moveOff.shiftReverse", steps, 1)
    end
    return instruction("ui.experiences.firstDrive.moveOff.pressThrottleReverse", steps, 2)
  end

  if not inReverse then
    return instruction(
      clutchInput < CLUTCH_HELD_THRESHOLD
        and "ui.experiences.firstDrive.moveOff.holdClutch"
        or "ui.experiences.firstDrive.moveOff.shiftReverse",
      steps,
      clutchInput < CLUTCH_HELD_THRESHOLD and 1 or 2
    )
  end
  if rpm <= RELEASE_CLUTCH_RPM_THRESHOLD then
    return instruction("ui.experiences.firstDrive.moveOff.pressThrottleWithClutch", steps, 3)
  end
  if clutchInput > CLUTCH_RELEASED_THRESHOLD then
    return instruction("ui.experiences.firstDrive.moveOff.releaseClutch", steps, 4)
  end
  return instruction("ui.experiences.firstDrive.moveOff.pressThrottleReverse", steps)
end

local function engineOffInstruction(engineRunning, gearIndex, clutchInput, moving)
  if moving or mode ~= "arcade" and gearIndex ~= NEUTRAL_GEAR
    or mode == "realisticManual" and clutchInput > CLUTCH_RELEASED_THRESHOLD then
    phase = "stopping"
    return stoppingInstruction(0, clutchInput, gearIndex, moving)
  end

  local steps = {step(actions.starter, "press")}
  if engineRunning ~= nil and engineRunning <= 0 then
    completedSection = "engineOff"
    reverseDone = false
    return beginSectionDelay(
      mode == "realisticManual" and "engineNeutral" or "engineOn",
      instruction("ui.experiences.firstDrive.moveOff.engineOff", steps)
    )
  end
  return instruction(
    "ui.experiences.firstDrive.moveOff.turnEngineOff",
    steps,
    1
  )
end

local function getInstruction()
  if phase == "delay" then return sectionDelayState end

  local brake = core_vehicleBridge.getCachedVehicleData(trackedVehicleId, "brake_input") or 0
  local clutchInput = core_vehicleBridge.getCachedVehicleData(trackedVehicleId, "clutch_input") or 0
  local gearIndex = core_vehicleBridge.getCachedVehicleData(trackedVehicleId, "gearIndex") or NEUTRAL_GEAR
  local engineRunning = core_vehicleBridge.getCachedVehicleData(trackedVehicleId, "engineRunning")
  local rpm = core_vehicleBridge.getCachedVehicleData(trackedVehicleId, "rpm") or 0
  local wheelSpeed = math.abs(core_vehicleBridge.getCachedVehicleData(trackedVehicleId, "wheelspeed") or 0)
  local moving = wheelSpeed >= MOVING_SPEED_THRESHOLD

  if mode == "realisticManual" and (phase == "engineOn" or phase == "startEngine")
    and engineRunning ~= nil and engineRunning <= 0 and gearIndex ~= NEUTRAL_GEAR then
    phase = "engineNeutral"
  end

  if phase ~= "engineNeutral" and phase ~= "startEngine" and phase ~= "engineOff"
    and engineRunning ~= nil and engineRunning <= 0 then
    phase = mode == "realisticManual" and "engineNeutral" or "engineOn"
    reverseDone = false
  end

  if phase == "engineNeutral" then
    return engineNeutralInstruction(engineRunning, gearIndex, clutchInput)
  elseif phase == "engineOn" or phase == "startEngine" then
    return engineOnInstruction(engineRunning, gearIndex, clutchInput)
  elseif phase == "moveOff" then
    return moveOffInstruction(clutchInput, gearIndex, rpm, moving)
  elseif phase == "stopping" then
    return stoppingInstruction(brake, clutchInput, gearIndex, moving)
  elseif phase == "reverse" then
    return reverseInstruction(clutchInput, gearIndex, rpm, wheelSpeed)
  end
  return engineOffInstruction(engineRunning, gearIndex, clutchInput, moving)
end

local function disable()
  requestToken = requestToken + 1
  enabled = false
  unregisterVehicle()
  mode = nil
  phase = "engineOn"
  nextPhase = nil
  sectionDelayRemaining = 0
  sectionDelayState = nil
  currentState = nil
  currentStateSignature = nil
  reverseDone = false
  completedSection = nil
  setVisible(false)
  guihooks.trigger(STATE_EVENT, {active = false})
end

local function getMode(gearboxMode)
  if gearboxMode == "arcade" then return "arcade" end
  if settings.getValue("autoClutch", true) then return "realisticAutoClutch" end
  return "realisticManual"
end

local function setupVehicle(vehicle)
  requestToken = requestToken + 1
  unregisterVehicle()
  mode = nil
  phase = "engineOn"
  nextPhase = nil
  sectionDelayRemaining = 0
  sectionDelayState = nil
  currentState = nil
  currentStateSignature = nil
  settleRemaining = SETTLE_DELAY
  reverseDone = false
  completedSection = nil
  setVisible(false)
  if not vehicle then return end

  trackedVehicleId = vehicle:getID()
  for _, key in ipairs(trackedKeys) do
    core_vehicleBridge.registerValueChangeNotification(vehicle, key)
  end

  local token = requestToken
  local vehicleId = trackedVehicleId
  core_vehicleBridge.requestValue(vehicle, function(value)
    if not enabled or token ~= requestToken or trackedVehicleId ~= vehicleId then return end
    local gearboxMode = value and not value.failReason and value.result
      or settings.getValue("defaultGearboxBehavior", "arcade")
    mode = getMode(gearboxMode)
  end, "mainController", "gearboxMode")
end

local function setEnabled(value)
  value = value == true
  if enabled == value then return end
  if not value then
    disable()
    return
  end

  enabled = true
  setupVehicle(be:getPlayerVehicle(0))
end

local function getState()
  return currentState
end

local function onUpdate(dtReal)
  if not enabled then return end
  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then
    if trackedVehicleId then setupVehicle(nil) end
    return
  end
  if vehicle:getID() ~= trackedVehicleId then
    setupVehicle(vehicle)
    return
  end
  if not mode then return end
  if settleRemaining > 0 then
    settleRemaining = settleRemaining - (dtReal or 0)
    return
  end

  if phase == "delay" then
    sectionDelayRemaining = sectionDelayRemaining - (dtReal or 0)
    if sectionDelayRemaining <= 0 then
      phase = nextPhase
      nextPhase = nil
      sectionDelayState = nil
      currentStateSignature = nil
    end
  end

  publishState(getInstruction())
  if completedSection then
    local section = completedSection
    completedSection = nil
    extensions.hook("onFirstDriveMoveOffSectionCompleted", section)
  end
end

local function onVehicleSwitched(_, newVehicleId, player)
  if not enabled or (player and player ~= 0) then return end
  setupVehicle(newVehicleId and getObjectByID(newVehicleId) or be:getPlayerVehicle(0))
end

local function onVehicleDestroyed(vehicleId)
  if enabled and vehicleId == trackedVehicleId then setupVehicle(nil) end
end

local function onSettingsChanged()
  if not enabled then return end
  local token = requestToken
  core_jobsystem.create(function(job)
    job.sleep(0.1)
    if enabled and token == requestToken then setupVehicle(be:getPlayerVehicle(0)) end
  end, 1)
end

local function onExtensionUnloaded()
  disable()
end

local function onClientEndMission()
  disable()
end

M.setEnabled = setEnabled
M.getEnabled = function() return enabled end
M.getState = getState
M.onUpdate = onUpdate
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleReplaced = onVehicleDestroyed
M.onSettingsChanged = onSettingsChanged
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientEndMission = onClientEndMission

return M
