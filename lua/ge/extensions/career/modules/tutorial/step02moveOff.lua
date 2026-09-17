-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local tasklistLocale = require("/lua/ge/extensions/career/modules/tutorial/tasklistLocale")

local MOVE_DISTANCE_THRESHOLD = 3
local THROTTLE_THRESHOLD = 0.2
local GEAR_FIRST = 1

local mode = nil
local startPos = nil
local gearboxModeReceived = false
local advanceScheduled = false
local engineStallMode = false
local lastIgnitionLevel = 2

local headers = {
  waiting = { label = "ui.career.tutorial.task.step02.header.waiting" },
  arcade = { label = "ui.career.tutorial.task.step02.header.arcade" },
  realisticClutch = { label = "ui.career.tutorial.task.step02.header.realisticClutch" },
  realisticNoClutch = { label = "ui.career.tutorial.task.step02.header.realisticNoClutch" },
}

local messages = {
  waitingMessage = { id = "moveOff_wait", type = "message", label = "ui.career.tutorial.task.step02.message.waiting", clear = false },
}

local goals = {
  arcadeMoveGoal = { done = false, id = "moveOff_arcadeMove", type = "goal", label = "ui.career.tutorial.task.step02.goal.arcadeMove.label", actionItems = { { action = "accelerate" } }, attention = true },
  shiftGoal = { done = false, id = "moveOff_shiftGoal", type = "goal", label = "ui.career.tutorial.task.step02.goal.shift.label", actionItems = { { action = "shiftUp" } }, attention = true },
  throttleGoal = { done = false, id = "moveOff_throttleGoal", type = "goal", label = "ui.career.tutorial.task.step02.goal.throttle.label", actionItems = { { action = "accelerate" } }, attention = true },
  noClutchShiftGoal = { done = false, id = "moveOff_noClutchShift", type = "goal", label = "ui.career.tutorial.task.step02.goal.noClutchShift.label", actionItems = { { action = "clutch" }, { action = "shiftUp" } }, attention = true },
  noClutchMoveGoal = { done = false, id = "moveOff_noClutchMove", type = "goal", label = "ui.career.tutorial.task.step02.goal.noClutchMove.label", actionItems = { { action = "accelerate" }, { action = "clutch" } }, attention = true },
  engineStallRecoveryGoal = { done = false, id = "moveOff_stallRecovery", type = "goal", label = "ui.career.tutorial.task.step02.goal.engineStallRecovery.label", actionItems = { { action = "shiftDown" }, { action = "activateStarterMotor" } }, attention = true },
}

local function getVehiclePosition()
  local vehId = gameplay_tutorial_setup.tutorialVehicleId
  if not vehId then return nil end
  local obj = map.objects[vehId]
  if not obj or not obj.pos then return nil end
  return obj.pos
end

local function getDistanceMoved()
  if not startPos then return 0 end
  local pos = getVehiclePosition()
  if not pos then return 0 end
  return pos:distance(startPos)
end

local function applyInitialTasklist()
  guihooks.trigger("ClearTasklist")
  local header = headers.arcade
  if mode == 'realistic_clutch' then
    header = headers.realisticClutch
  elseif mode == 'realistic_no_clutch' then
    header = headers.realisticNoClutch
  end
  tasklistLocale.setTasklistHeader(header)

  if mode == 'arcade' then
    tasklistLocale.setTasklistTask(goals.arcadeMoveGoal)
  elseif mode == 'realistic_clutch' then
    tasklistLocale.setTasklistTask(goals.shiftGoal)
    tasklistLocale.setTasklistTask(goals.throttleGoal)
  else
    tasklistLocale.setTasklistTask(goals.noClutchShiftGoal)
    tasklistLocale.setTasklistTask(goals.noClutchMoveGoal)
  end
end

local function applyStallRecoveryTasklist()
  guihooks.trigger("ClearTasklist")
  tasklistLocale.setTasklistHeader(headers.waiting)
  tasklistLocale.setTasklistTask(goals.engineStallRecoveryGoal)
end

local function completeAndAdvance(completedGoal)
  if advanceScheduled then return end
  advanceScheduled = true
  if completedGoal then
    tasklistLocale.setTasklistTask(completedGoal)
  end
  core_jobsystem.create(function(job)
    job.sleep(1)
    career_modules_tutorial.activateStep("03basicManeuvers")
  end, 1)
end

function M.setup(stepData)
  goals.arcadeMoveGoal.done = false
  goals.shiftGoal.done = false
  goals.throttleGoal.done = false
  goals.noClutchShiftGoal.done = false
  goals.noClutchMoveGoal.done = false
  goals.engineStallRecoveryGoal.done = false
  gearboxModeReceived = false
  advanceScheduled = false
  engineStallMode = false
  lastIgnitionLevel = 2
  mode = nil
  startPos = nil

  gameplay_tutorial_bounds.setActiveZones({"evalZone"})
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(function()
    gameplay_tutorial_setup.placePlayerBackToParkingStart()
  end)

  guihooks.trigger("ClearTasklist")
  tasklistLocale.setTasklistHeader(headers.waiting)
  tasklistLocale.setTasklistTask(messages.waitingMessage)

  local veh = gameplay_tutorial_setup.tutorialVehicleId and getObjectByID(gameplay_tutorial_setup.tutorialVehicleId) or nil
  if not veh then return end

  core_vehicleBridge.registerValueChangeNotification(veh, 'throttle_input')
  core_vehicleBridge.registerValueChangeNotification(veh, 'clutch')
  core_vehicleBridge.registerValueChangeNotification(veh, 'gearIndex')
  core_vehicleBridge.registerValueChangeNotification(veh, 'ignitionLevel')

  core_vehicleBridge.requestValue(veh, function(val)
    if val.failReason then
      mode = 'arcade'
    else
      local gearboxBehavior = val.result
      local autoClutch = settings.getValue("autoClutch", true)
      if gearboxBehavior == "arcade" then
        mode = 'arcade'
      elseif autoClutch then
        mode = 'realistic_clutch'
      else
        mode = 'realistic_no_clutch'
      end
    end
    gearboxModeReceived = true
    startPos = vec3(getVehiclePosition())
    gameplay_tutorial_setup.blockedActions.shiftUp = false
    gameplay_tutorial_setup.blockedActions.shiftDown = false
    gameplay_tutorial_setup.blockedActions.setShifterMode = false
    gameplay_tutorial_setup.setupBlockedActions()
    core_vehicleBridge.executeAction(veh, 'setFreeze', false)
    applyInitialTasklist()
  end, "mainController", "gearboxMode")
end

function M.onCareerTutorialLeftBounds()
  gameplay_tutorial_setup.runCurrentStepOutOfBoundsReset()
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if not gearboxModeReceived or not gameplay_tutorial_setup.tutorialVehicleId then return end

  local vehId = gameplay_tutorial_setup.tutorialVehicleId
  local throttle = core_vehicleBridge.getCachedVehicleData(vehId, 'throttle_input') or 0
  local clutch = core_vehicleBridge.getCachedVehicleData(vehId, 'clutch') or 0
  local gearIndex = core_vehicleBridge.getCachedVehicleData(vehId, 'gearIndex')
  if gearIndex == nil then gearIndex = 0 end
  local ignitionLevel = core_vehicleBridge.getCachedVehicleData(vehId, 'ignitionLevel')
  if ignitionLevel == nil then ignitionLevel = 2 end

  if mode == 'realistic_no_clutch' then
    if lastIgnitionLevel == 2 and (ignitionLevel == 1 or ignitionLevel == 0) then
      engineStallMode = true
      goals.noClutchMoveGoal.done = false
      goals.engineStallRecoveryGoal.done = false
      applyStallRecoveryTasklist()
    elseif engineStallMode and ignitionLevel == 2 then
      goals.engineStallRecoveryGoal.done = true
      tasklistLocale.setTasklistTask(goals.engineStallRecoveryGoal)
      engineStallMode = false
      applyInitialTasklist()
    end
    lastIgnitionLevel = ignitionLevel
  end

  if engineStallMode then
    return
  end

  if not startPos then
    startPos = getVehiclePosition()
  end

  local distanceMoved = getDistanceMoved()
  if distanceMoved >= MOVE_DISTANCE_THRESHOLD then
    if mode == 'arcade' and not goals.arcadeMoveGoal.done then
      goals.arcadeMoveGoal.done = true
      completeAndAdvance(goals.arcadeMoveGoal)
      return
    end
    if mode == 'realistic_clutch' and goals.shiftGoal.done and not goals.throttleGoal.done then
      goals.throttleGoal.done = true
      completeAndAdvance(goals.throttleGoal)
      return
    end
    if mode == 'realistic_no_clutch' and goals.noClutchShiftGoal.done and not goals.noClutchMoveGoal.done then
      goals.noClutchMoveGoal.done = true
      completeAndAdvance(goals.noClutchMoveGoal)
      return
    end
  end

  if mode == 'arcade' then
    if not goals.arcadeMoveGoal.done and throttle > THROTTLE_THRESHOLD then
      tasklistLocale.setTasklistTask(goals.arcadeMoveGoal)
    end
  elseif mode == 'realistic_clutch' then
    if not goals.shiftGoal.done and gearIndex == GEAR_FIRST then
      goals.shiftGoal.done = true
      tasklistLocale.setTasklistTask(goals.shiftGoal)
    end
    if goals.shiftGoal.done and not goals.throttleGoal.done and throttle > THROTTLE_THRESHOLD then
      tasklistLocale.setTasklistTask(goals.throttleGoal)
    end
  else
    if not goals.noClutchShiftGoal.done and gearIndex == GEAR_FIRST then
      goals.noClutchShiftGoal.done = true
      tasklistLocale.setTasklistTask(goals.noClutchShiftGoal)
    end
    if goals.noClutchShiftGoal.done and not goals.noClutchMoveGoal.done and throttle > THROTTLE_THRESHOLD and clutch > 0.2 then
      tasklistLocale.setTasklistTask(goals.noClutchMoveGoal)
    end
  end
end

function M.cleanup()
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(nil)
  local veh = gameplay_tutorial_setup.tutorialVehicleId and getObjectByID(gameplay_tutorial_setup.tutorialVehicleId) or nil
  if veh then
    core_vehicleBridge.unregisterValueChangeNotification(veh, 'throttle_input')
    core_vehicleBridge.unregisterValueChangeNotification(veh, 'clutch')
    core_vehicleBridge.unregisterValueChangeNotification(veh, 'gearIndex')
    core_vehicleBridge.unregisterValueChangeNotification(veh, 'ignitionLevel')
  end
  guihooks.trigger("ClearTasklist")
end

local function skipStep()
  goals.arcadeMoveGoal.done = true
  goals.shiftGoal.done = true
  goals.throttleGoal.done = true
  goals.noClutchShiftGoal.done = true
  goals.noClutchMoveGoal.done = true
  goals.engineStallRecoveryGoal.done = true
  guihooks.trigger("ClearTasklist")
  career_modules_tutorial.activateStep("03basicManeuvers")
end

function M.onDebugMenu(im)
  im.Separator()
  im.Text("Step 2 - Move off")
  im.Text(string.format("Mode: %s", tostring(mode)))
  if im.Button("Skip step02moveOff") then
    skipStep()
  end
end

return M
