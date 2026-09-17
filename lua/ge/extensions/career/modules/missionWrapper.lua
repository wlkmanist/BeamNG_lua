-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career'}

local allMissionData = {}

local function init() end

local function setCurrentSaveSlot()
  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not savePath then return end
  gameplay_missions_progress.setSavePath(savePath .. "/career/missions/")
  gameplay_missions_missions.reloadCompleteMissionSystem()
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end

  -- load from saveslot
  setCurrentSaveSlot()
end

local function onExtensionUnloaded()
  gameplay_missions_progress.setSavePath(nil)
  gameplay_missions_missions.reloadCompleteMissionSystem()
end

-- this should only be loaded when the career is active
local function onSaveCurrentProfile(currentSavePath)
  gameplay_missions_progress.setSavePath(currentSavePath .. "/career/missions/")
  for id, dirtyDate in pairs(allMissionData) do
    if gameplay_missions_progress.saveMissionSaveData(id, dirtyDate) == false then
      career_saveSystem.saveFailed()
    end
  end
end

local function setMissionInfo(id, dirtyDate)
  allMissionData[id] = dirtyDate
end

local function cacheMissionData(id, dirtyDate)
  setMissionInfo(id, dirtyDate and dirtyDate or os.date("!%Y-%m-%dT%H:%M:%SZ"))
end

local function onMissionLoaded(id, dirtyDate)
  cacheMissionData(id, dirtyDate)
end

local function saveMission(id)
  cacheMissionData(id)
  career_saveSystem.saveCurrent()
end

local function onAnyMissionChanged(state, mission)
  if mission and state == "stopped" then
    career_modules_playerDriving.resetPlayerState()
    if career_career.isAutosaveEnabled() then
      saveMission(mission.id)
    end
  end
end

local missionStartStep
local function onVehicleSaveFinished()
  if missionStartStep then
    missionStartStep.handlingComplete = true
    missionStartStep = nil
  end
end

local function preMissionHandling(step, task)
  missionStartStep = step

  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  else
    missionStartStep.handlingComplete = true
    missionStartStep = nil
  end
end

M.cacheMissionData = cacheMissionData
M.onMissionLoaded = onMissionLoaded
M.saveMission = saveMission
M.preMissionHandling = preMissionHandling

M.onSaveCurrentProfile = onSaveCurrentProfile
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onAnyMissionChanged = onAnyMissionChanged
M.onVehicleSaveFinished = onVehicleSaveFinished

return M