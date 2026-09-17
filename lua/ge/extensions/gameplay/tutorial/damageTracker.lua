-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = { "gameplay_util_crashDetection" }

local SLOW_SPEED_MS = 3 / 3.6
local MAX_WAIT_SECONDS = 5
local MAX_WAIT_SECONDS_TIME_TRIAL = 1.5
local OOB_DAMAGE_SUPPRESS_SECONDS = 8

local enabled = false
local trackedVehId = nil
local configuredVehId = nil
local hadCrash = false
local wasRepairedAfterCrash = false
local pendingDamagePopup = false
local damagePopupWaitElapsed = 0
local suppressDamageUntilTime = 0

local tutorialDamagePopupShown = false
local timeTrialDamagePopupShown = false
local careerDamagePopupShown = false

local function isInTimeTrial()
  local fgId = gameplay_missions_missionManager and gameplay_missions_missionManager.getForegroundMissionId()
  if not fgId then return false end
  local mission = gameplay_missions_missions and gameplay_missions_missions.getMissionById(fgId)
  if not mission or not mission.missionType then return false end
  return mission.missionType == "timeTrial" or mission.missionType == "generatedTimeTrial"
end

local function isDamageTrackingActive()
  return enabled
end

local function isDamageSuppressed()
  return os.clockhp() < suppressDamageUntilTime
end

local function clearPendingDamagePopupState()
  pendingDamagePopup = false
  damagePopupWaitElapsed = 0
end

local defaultRepairGoal = {
  done = false,
  id = "tutorial_repairVehicleGoal",
  type = "goal",
  label = "ui.career.tutorial.damage.repairGoal.label",
  subtext = "ui.career.tutorial.damage.repairGoal.subtext",
  actionItems = {
    { action = "toggleRadialMenuMulti" },
  },
}
local repairGoal = deepcopy(defaultRepairGoal)

local function isTranslationKey(value)
  return type(value) == "string" and value:sub(1, 3) == "ui."
end

local function resolveTasklistGoal(goal)
  local task = deepcopy(goal)
  if isTranslationKey(task.label) then
    task.label = _tr(task.label)
  end
  if isTranslationKey(task.subtext) then
    task.subtext = _tr(task.subtext)
  end
  if type(task.actionItems) == "table" then
    fillActionLabels(task.actionItems)
  end
  return task
end

local function triggerRepairGoalTask()
  guihooks.trigger("SetTasklistTask", resolveTasklistGoal(repairGoal))
end

M.setRepairGoal = function(goal) repairGoal = goal or deepcopy(defaultRepairGoal) end
M.setDefaultRepairGoal = function() repairGoal = deepcopy(defaultRepairGoal) end

local timeTrialDamagedMessageId = "tutorial_timeTrialDamagedMessage"
local timeTrialRestartGoal = {
  done = false,
  id = "tutorial_timeTrialRestartGoal",
  type = "goal",
  label = "ui.career.tutorial.damage.timeTrialRestartGoal.label",
  subtext = "ui.career.tutorial.damage.timeTrialRestartGoal.subtext",
  actionItems = {
    { action = "toggleMenues" },
  },
}

local function clearRepairTask()
  repairGoal.done = true
  triggerRepairGoalTask()
  guihooks.trigger("DiscardTasklistItem", repairGoal.id)
end

local function clearTimeTrialRestartTask()
  timeTrialRestartGoal.done = true
  guihooks.trigger("SetTasklistTask", resolveTasklistGoal(timeTrialRestartGoal))
  guihooks.trigger("DiscardTasklistItem", timeTrialRestartGoal.id)
  guihooks.trigger("DiscardTasklistItem", timeTrialDamagedMessageId)
end

local function clearCareerRepairTask()
  guihooks.trigger("DiscardTasklistItem", "career_repairVehicleGoal")
  guihooks.trigger("DiscardTasklistItem", "career_vehicleDamagedMessage")
end

local function setTrackedVehicle(vehId)
  if trackedVehId and gameplay_util_crashDetection.isVehTracked(trackedVehId) then
    gameplay_util_crashDetection.removeTrackedVehicleById(trackedVehId)
  end

  trackedVehId = vehId
  if trackedVehId then
    gameplay_util_crashDetection.addTrackedVehicleById(trackedVehId, nil, "gameplay_tutorial_damageTracker")
  end
end

local function ensureTrackedVehicle()
  if enabled then
    local playerVehId = be:getPlayerVehicleID(0)
    if isInTimeTrial() and playerVehId and playerVehId ~= trackedVehId then
      setTrackedVehicle(playerVehId)
      return
    end

    if configuredVehId and configuredVehId ~= trackedVehId then
      setTrackedVehicle(configuredVehId)
      return
    end

    if not configuredVehId and trackedVehId then
      setTrackedVehicle(nil)
    end
    return
  end

  if trackedVehId then
    setTrackedVehicle(nil)
    clearTimeTrialRestartTask()
    clearCareerRepairTask()
    wasRepairedAfterCrash = true
  end
end

function M.setTrackedVehicleId(vehicleId)
  configuredVehId = vehicleId
end

function M.showRepairTask()
  if not enabled then return end
  if not hadCrash or wasRepairedAfterCrash then return end
  if isInTimeTrial() then
    timeTrialRestartGoal.done = false
    guihooks.trigger("SetTasklistTask", resolveTasklistGoal(timeTrialRestartGoal))
  else
    repairGoal.done = false
    triggerRepairGoalTask()
  end
end

function M.setEnabled(value)
  enabled = value and true or false
  if not enabled then
    setTrackedVehicle(nil)
    clearRepairTask()
    clearTimeTrialRestartTask()
    clearCareerRepairTask()
    clearPendingDamagePopupState()
  else
    ensureTrackedVehicle()
    M.showRepairTask()
  end
end

function M.debugTriggerCrash()
  hadCrash = true
  wasRepairedAfterCrash = false
  pendingDamagePopup = true
  damagePopupWaitElapsed = 0
end

function M.cleanup()
  M.setEnabled(false)
  hadCrash = false
  wasRepairedAfterCrash = false
  suppressDamageUntilTime = 0
  tutorialDamagePopupShown = false
  timeTrialDamagePopupShown = false
  careerDamagePopupShown = false
  clearPendingDamagePopupState()
end

local function shouldShowDamagePopupNow(veh, elapsedSec)
  local maxWait = isInTimeTrial() and MAX_WAIT_SECONDS_TIME_TRIAL or MAX_WAIT_SECONDS
  if elapsedSec >= maxWait then return true end
  if veh and veh:getVelocity():length() <= SLOW_SPEED_MS then return true end
  return false
end

local function showDamagePopupAndRepairTask()
  clearPendingDamagePopupState()

  local inTimeTrial = isInTimeTrial()
  local popupId
  local shouldShowPopup = false

  if inTimeTrial then
    popupId = "v2/damagedVehicleTimeTrial"
    shouldShowPopup = not timeTrialDamagePopupShown
    if shouldShowPopup then
      timeTrialDamagePopupShown = true
    end
  elseif enabled then
    popupId = "v2/damagedVehicle"
    shouldShowPopup = not tutorialDamagePopupShown
    if shouldShowPopup then
      tutorialDamagePopupShown = true
    end
  else
    popupId = "v2/damagedVehicleCareer"
    shouldShowPopup = not careerDamagePopupShown
    if shouldShowPopup then
      careerDamagePopupShown = true
    end
  end

  if shouldShowPopup and career_modules_tutorialPopups then
    career_modules_tutorialPopups.introPopup(popupId, true)
  end

  if inTimeTrial then
    guihooks.trigger("SetTasklistTask", { id = timeTrialDamagedMessageId, type = "message", label = _tr("ui.career.tutorial.damage.timeTrialDamagedMessage"), clear = false })
    timeTrialRestartGoal.done = false
    guihooks.trigger("SetTasklistTask", resolveTasklistGoal(timeTrialRestartGoal))
  elseif enabled then
    repairGoal.done = false
    triggerRepairGoalTask()
  else
    clearCareerRepairTask()
  end
end

local function vehicleHasDamage(veh)
  if not veh or not veh.getSectionDamageSum then return false end
  return (veh:getSectionDamageSum() or 0) > 0
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  ensureTrackedVehicle()

  if not isDamageTrackingActive() or not pendingDamagePopup then return end
  if isDamageSuppressed() then
    clearPendingDamagePopupState()
    return
  end

  damagePopupWaitElapsed = damagePopupWaitElapsed + dtRaw
  local veh = trackedVehId and getObjectByID(trackedVehId) or nil
  if shouldShowDamagePopupNow(veh, damagePopupWaitElapsed) then
    showDamagePopupAndRepairTask()
  end
end

function M.onVehicleCrashEnded(crashData)
  ensureTrackedVehicle()

  if not isDamageTrackingActive() then return end
  if not crashData or crashData.vehId ~= trackedVehId then return end
  if isDamageSuppressed() then return end

  hadCrash = true
  wasRepairedAfterCrash = false
  pendingDamagePopup = true
  damagePopupWaitElapsed = 0
end

function M.onCareerTutorialOutOfBoundsStarted()
  suppressDamageUntilTime = math.max(suppressDamageUntilTime, os.clockhp() + OOB_DAMAGE_SUPPRESS_SECONDS)
  hadCrash = false
  wasRepairedAfterCrash = true
  clearPendingDamagePopupState()
  clearRepairTask()
end

function M.onCareerTutorialOutOfBoundsEnded()
  if not enabled then return end
  if isInTimeTrial() then
    return
  end
  local veh = trackedVehId and getObjectByID(trackedVehId) or nil
  if not vehicleHasDamage(veh) then return end
  hadCrash = true
  wasRepairedAfterCrash = false
  clearPendingDamagePopupState()
  M.showRepairTask()
end

function M.onVehicleResetted(vehicleId)
  if isInTimeTrial() and enabled then
    wasRepairedAfterCrash = true
    clearPendingDamagePopupState()
    clearRepairTask()
    clearCareerRepairTask()
    trackedVehId = nil
    ensureTrackedVehicle()
    return
  end

  if not enabled or not hadCrash then return end
  if vehicleId ~= trackedVehId then return end
  wasRepairedAfterCrash = true
  clearPendingDamagePopupState()
  clearRepairTask()
  clearCareerRepairTask()
end

function M.onClientStartMission(levelPath)
  if isDamageTrackingActive() then
    ensureTrackedVehicle()
  end
end

function M.onRecoveryPromptRepairHereUsed(invVehId)
  wasRepairedAfterCrash = true
  clearPendingDamagePopupState()
  clearRepairTask()
  clearCareerRepairTask()
end

function M.onVehicleRepaired(invVehId)
  if not enabled or not hadCrash then return end
  wasRepairedAfterCrash = true
  clearPendingDamagePopupState()
  clearRepairTask()
  clearCareerRepairTask()
end

function M.onRecoveryPromptButtonPressed(buttonId)
  if buttonId ~= "restartMission" then return end
  if not isInTimeTrial() then return end
  if not hadCrash then return end
  wasRepairedAfterCrash = true
  clearPendingDamagePopupState()
  clearTimeTrialRestartTask()
  clearRepairTask()
  clearCareerRepairTask()
end

function M.onVehicleResetted(vehicleId)
  if not enabled then return end
  if vehicleId ~= trackedVehId then return end
  wasRepairedAfterCrash = true
  clearPendingDamagePopupState()
  clearRepairTask()
  clearCareerRepairTask()
end

function M.getHadCrash()
  return hadCrash
end

return M
