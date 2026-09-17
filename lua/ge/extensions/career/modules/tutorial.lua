-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "gameplay_tutorial_runtime",
  "gameplay_tutorial_setup",
  "gameplay_tutorial_markers",
  "gameplay_tutorial_damageTracker",
  "gameplay_tutorial_bounds"
}

local logTag = "career_tutorial"
local moduleVersion = 1
local saveFile = "/career/tutorialState.json"
local GARAGE_POI_ID = "tutorial_apm_parking"

local stepOrder = {
  "01enterVehicle",
  "02moveOff",
  "03basicManeuvers",
  "04timeTrial",
  "05driveToDragStrip",
  "06dragStripBasics",
  "07bigmap",
  "08driveToGarage",
  "09spmSignup"
}

local initialPrefabs = {
  startingArea = true,
  tutorialTrackClosed = true,
  tutorialTrackOpen = false,
  garageParkingPylons = true,
  driveToDragStripGuidesClosed = false,
  driveToDragStripGuidesOpen = false
}

local saveData = {
  version = moduleVersion,
  currentStepId = nil,
  completedSteps = {},
  isCompleted = false,
}

M.sharedTutorialData = gameplay_tutorial_runtime and gameplay_tutorial_runtime.sharedTutorialData or {}

local function isValidStepId(stepId)
  for _, id in ipairs(stepOrder) do
    if id == stepId then
      return true
    end
  end
  return false
end

local function pullRuntimeProgress()
  local progress = gameplay_tutorial_runtime.getProgressData() or {}
  saveData.currentStepId = progress.currentStepId
  saveData.completedSteps = progress.completedSteps or {}
  saveData.isCompleted = progress.isCompleted and true or false
end

local function pushRuntimeProgress()
  gameplay_tutorial_runtime.setProgressData({
    currentStepId = saveData.currentStepId,
    completedSteps = saveData.completedSteps or {},
    isCompleted = saveData.isCompleted and true or false
  })
end

local function configureRuntime()
  gameplay_tutorial_runtime.configure({
    stepOrder = stepOrder,
    stepExtensionPrefix = "career_modules_tutorial_step",
    initialPrefabs = initialPrefabs,
    loadSitesOnStart = true,
    setupBlockedActionsOnStart = true,
    onEnded = function()
      career_career.setAutosaveEnabled(true)
      career_saveSystem.saveCurrent()
      core_recoveryPrompt.setDefaultsForCareer()
      career_modules_playerDriving.resetPlayerState()
      gameplay_rawPois.clear()
      if core_gamestate then
        core_gamestate.setGameState("career", "career", nil)
      end
    end
  })
end

local function onExtensionLoaded()
  configureRuntime()

  local _, savePath = career_saveSystem.getCurrentProfile()
  local loadedData = (savePath and jsonReadFile(savePath .. saveFile)) or {}

  saveData = {
    version = loadedData.version or moduleVersion,
    currentStepId = loadedData.currentStepId,
    completedSteps = loadedData.completedSteps or {},
    isCompleted = loadedData.isCompleted or false
  }

  if saveData.version < moduleVersion then
    saveData.version = moduleVersion
  end

  if saveData.currentStepId and not isValidStepId(saveData.currentStepId) then
    log("W", logTag, "Saved step is invalid, resetting to first step: " .. tostring(saveData.currentStepId))
    saveData.currentStepId = nil
  end

  pushRuntimeProgress()
  M.sharedTutorialData = gameplay_tutorial_runtime.sharedTutorialData
end

local function onSaveCurrentProfile(currentSavePath)
  pullRuntimeProgress()
  saveData.version = moduleVersion
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, saveData, true)
end

local function onCareerActive()
  if not career_career.tutorialEnabled then
    log("I", logTag, "Tutorial start skipped: tutorialEnabled is false")
    return false
  end
  M.start()
end

function M.isActive()
  return gameplay_tutorial_runtime.isActive()
end

function M.getCurrentStep()
  return gameplay_tutorial_runtime.getCurrentStep()
end

function M.getStepOrder()
  return stepOrder
end

function M.getStepIdByIndex(index)
  return stepOrder[index]
end

function M.start()
  local ok = gameplay_tutorial_runtime.start()
  if ok then
    pullRuntimeProgress()
  end
  return ok
end

function M.activateStep(stepId)
  local ok = gameplay_tutorial_runtime.activateStep(stepId)
  if ok then
    pullRuntimeProgress()
  end
  return ok
end

function M.completeStep(stepId)
  local ok = gameplay_tutorial_runtime.completeStep(stepId)
  if ok then
    pullRuntimeProgress()
  end
  return ok
end

function M.advanceToNextStep()
  local ok = gameplay_tutorial_runtime.advanceToNextStep()
  if ok then
    pullRuntimeProgress()
  end
  return ok
end

function M.endTutorial()
  local ok = gameplay_tutorial_runtime.endTutorial()
  if ok then
    pullRuntimeProgress()
  end
  return ok
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  gameplay_tutorial_runtime.onUpdate(dtReal, dtSim, dtRaw)
end

function M.onPreRender(dtReal, dtSim, dtRaw)
  gameplay_tutorial_runtime.onPreRender(dtReal, dtSim, dtRaw)
end

function M.getCompletedSteps()
  local progress = gameplay_tutorial_runtime.getProgressData()
  return progress.completedSteps or {}
end

function M.onGetRawPoiListForTutorial(elements)
  if not gameplay_tutorial_runtime.isActive() then return end
  if not gameplay_tutorial_setup.tutorialSites then return end
  local spot = gameplay_tutorial_setup.tutorialSites.parkingSpots.byName["garageExteriorPark"]
  if not spot then return end

  table.insert(elements, {
    id = GARAGE_POI_ID,
    data = {
      type = "other",
      id = GARAGE_POI_ID
    },
    markerInfo = {
      bigmapMarker = {
        pos = spot.pos,
        icon = "poi_parking_round",
        name = _tr("ui.career.tutorial.poi.garage.name"),
        description = _tr("ui.career.tutorial.poi.garage.description"),
        thumbnail = "/levels/west_coast_usa/spawns_servicestation.jpg",
        previews = {"/levels/west_coast_usa/spawns_servicestation.jpg"}
      }
    }
  })
end

M.onExtensionLoaded = onExtensionLoaded
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onCareerActive = onCareerActive

return M
