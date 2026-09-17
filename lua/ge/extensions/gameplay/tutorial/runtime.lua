-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "gameplay_tutorial_setup",
  "gameplay_tutorial_markers",
  "gameplay_tutorial_damageTracker",
  "gameplay_tutorial_bounds"
}

M.sharedTutorialData = {}

local logTag = "gameplay_tutorial_runtime"

local isActive = false
local currentStepId = nil
local currentStepIndex = nil
local currentStepExtensionName = nil

local config = {
  stepOrder = {},
  stepExtensionPrefix = "career_modules_tutorial_step",
  initialPrefabs = nil,
  loadSitesOnStart = true,
  setupBlockedActionsOnStart = true,
  onStarted = nil,
  onEnded = nil
}

local progressData = {
  currentStepId = nil,
  completedSteps = {},
  isCompleted = false
}

local function isValidStepId(stepId)
  for _, id in ipairs(config.stepOrder) do
    if id == stepId then
      return true
    end
  end
  return false
end

local function findStepIndex(stepId)
  for i, id in ipairs(config.stepOrder) do
    if id == stepId then
      return i
    end
  end
  return nil
end

function M.configure(opts)
  opts = type(opts) == "table" and opts or {}
  config.stepOrder = opts.stepOrder or config.stepOrder
  config.stepExtensionPrefix = opts.stepExtensionPrefix or config.stepExtensionPrefix
  config.initialPrefabs = opts.initialPrefabs or config.initialPrefabs
  if opts.loadSitesOnStart ~= nil then
    config.loadSitesOnStart = opts.loadSitesOnStart and true or false
  end
  if opts.setupBlockedActionsOnStart ~= nil then
    config.setupBlockedActionsOnStart = opts.setupBlockedActionsOnStart and true or false
  end
  if opts.onStarted ~= nil then
    config.onStarted = opts.onStarted
  end
  if opts.onEnded ~= nil then
    config.onEnded = opts.onEnded
  end

  gameplay_tutorial_bounds.setRuntimeActiveGetter(function()
    return M.isActive()
      and gameplay_tutorial_setup.vehicleSetupComplete
      and gameplay_tutorial_setup.loadingScreenFadeoutComplete
      and gameplay_tutorial_setup.outOfBoundsSystemActive
  end)
  gameplay_tutorial_bounds.setCurrentStepGetter(M.getCurrentStep)
  gameplay_tutorial_markers.setDefaultParkingSpotVehicleGetter(function()
    local vehId = gameplay_tutorial_setup.tutorialVehicleId
    return vehId and getObjectByID(vehId) or nil
  end)
end

function M.setProgressData(data)
  data = type(data) == "table" and data or {}
  progressData.currentStepId = data.currentStepId
  progressData.completedSteps = data.completedSteps or {}
  progressData.isCompleted = data.isCompleted and true or false
end

function M.getProgressData()
  return progressData
end

function M.isActive()
  return isActive
end

function M.getCurrentStep()
  return currentStepId
end

function M.getStepOrder()
  return config.stepOrder
end

function M.getStepIdByIndex(index)
  return config.stepOrder[index]
end

function M.start()
  if isActive then
    log("W", logTag, "Tutorial runtime already active.")
    return false
  end

  if #config.stepOrder == 0 then
    log("E", logTag, "Cannot start tutorial runtime - step order is empty")
    return false
  end

  if config.initialPrefabs then
    gameplay_tutorial_setup.setActivePrefabs(config.initialPrefabs)
  end
  if config.loadSitesOnStart then
    gameplay_tutorial_setup.loadTutorialSites()
  end
  if config.setupBlockedActionsOnStart then
    gameplay_tutorial_setup.setupBlockedActions()
  end

  isActive = true
  local startStepId = progressData.currentStepId
  if not startStepId or not isValidStepId(startStepId) then
    startStepId = config.stepOrder[1]
  end
  local ok = M.activateStep(startStepId)

  if ok and config.onStarted then
    config.onStarted()
  end

  return ok
end

function M.activateStep(stepId)
  if not isActive then
    log("W", logTag, "Cannot activate step - tutorial runtime not active")
    return false
  end

  local normalizedStepId = tostring(stepId)
  if not isValidStepId(normalizedStepId) then
    log("E", logTag, "Cannot activate invalid step: " .. normalizedStepId)
    return false
  end

  if currentStepExtensionName then
    local prevStep = extensions[currentStepExtensionName]
    if prevStep and prevStep.cleanup then
      prevStep.cleanup()
    end
    extensions.unload(currentStepExtensionName)
    currentStepExtensionName = nil
  end

  currentStepExtensionName = config.stepExtensionPrefix .. normalizedStepId
  extensions.load(currentStepExtensionName)

  local stepExt = extensions[currentStepExtensionName]
  if not stepExt then
    log("E", logTag, "Failed to load step module: " .. currentStepExtensionName)
    return false
  end

  currentStepId = normalizedStepId
  currentStepIndex = findStepIndex(currentStepId)
  progressData.currentStepId = currentStepId
  progressData.isCompleted = false

  if stepExt.setup then
    stepExt.setup({})
  end

  return true
end

function M.completeStep(stepId)
  if not isActive then
    return false
  end
  progressData.completedSteps[stepId] = true
  return true
end

function M.advanceToNextStep()
  if not isActive then
    log("W", logTag, "Cannot advance - tutorial runtime not active")
    return false
  end

  if not currentStepIndex then
    currentStepIndex = findStepIndex(currentStepId)
  end

  if not currentStepIndex then
    log("E", logTag, "Cannot advance - current step is not part of step order: " .. tostring(currentStepId))
    return false
  end

  local nextStepId = config.stepOrder[currentStepIndex + 1]
  if nextStepId then
    M.completeStep(currentStepId)
    M.activateStep(nextStepId)
  else
    M.completeStep(currentStepId)
    M.endTutorial()
  end

  return true
end

function M.endTutorial()
  if not isActive then
    return false
  end

  if currentStepExtensionName then
    local stepModule = extensions[currentStepExtensionName]
    if stepModule and stepModule.cleanup then
      stepModule.cleanup()
    end
    extensions.unload(currentStepExtensionName)
    currentStepExtensionName = nil
  end

  gameplay_tutorial_markers.cleanup()
  gameplay_tutorial_damageTracker.cleanup()
  gameplay_tutorial_bounds.cleanup()
  gameplay_tutorial_setup.cleanup()

  isActive = false
  currentStepId = nil
  currentStepIndex = nil
  progressData.currentStepId = nil
  progressData.isCompleted = true

  guihooks.trigger("ClearTasklist")

  if config.onEnded then
    config.onEnded()
  end

  return true
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  gameplay_tutorial_damageTracker.setTrackedVehicleId(gameplay_tutorial_setup.tutorialVehicleId)
  if isActive and currentStepExtensionName then
    local stepModule = extensions[currentStepExtensionName]
    if stepModule and stepModule.onUpdate then
      stepModule.onUpdate(dtReal, dtSim, dtRaw)
    end
  end
  gameplay_tutorial_damageTracker.onUpdate(dtReal, dtSim, dtRaw)
  gameplay_tutorial_damageTracker.showRepairTask()
  if isActive then
    gameplay_tutorial_markers.update(dtReal, dtSim)
    gameplay_tutorial_bounds.update(dtReal)
  end
end

function M.onPreRender(dtReal, dtSim, dtRaw)
  if isActive and currentStepExtensionName then
    local stepModule = extensions[currentStepExtensionName]
    if stepModule and stepModule.onPreRender then
      stepModule.onPreRender(dtReal, dtSim)
    end
  end
  if isActive then
    gameplay_tutorial_bounds.onPreRender(dtReal, dtSim, dtRaw)
  end
end

return M
