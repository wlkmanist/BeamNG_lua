-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY FIRST DRIVE TRACKER

  Tracks the First Drive tutorial: the session, its lessons and the vehicle recoveries made
  during it. The only thing recorded outside a First Drive session is the firstDriveProgress
  snapshot, see surveyProgress.

  Vehicle switches (vehicleUsed) and resets (vehicleReset) come from the vehicle tracker and
  are not repeated here. A recovery also fires trackVehReset, so it shows up there as a
  vehicleReset as well.
]]

local M = {}
M.dependencies = {'telemetry_core'}

-- written by gameplay/discover/firstDrive/learningProgress.lua
local progressFile = "settings/firstDriveLearning.json"
local progressVersion = 1
local defaultSurveyIntervalHours = 24 * 7
local surveyFile = extensions.telemetry_core.getDataFolder() .. "surveys/firstDriveSurvey.json"

-- os.clockhp() of the session start, set while a First Drive session runs
local sessionStartedAt = nil
local lessonId = nil
local lessonStartedAt = nil

local function secondsSince(startedAt)
  return startedAt and os.clockhp() - startedAt or nil
end

-- sorted, so the same progress always encodes the same
local function getCompletedLessonIds(completedLessons)
  local ids = {}
  for id, done in pairs(completedLessons) do
    if done == true then table.insert(ids, id) end
  end
  table.sort(ids)
  return ids
end

local function completedLessonIds()
  local progress = gameplay_discover_firstDrive_learningProgress
  return progress and getCompletedLessonIds(progress.getCompletedLessons()) or nil
end

local function completedLessonCount()
  local ids = completedLessonIds()
  return ids and #ids
end

-- Saved progress has no completion times, so the first snapshot of a player is the baseline
-- of what was completed untracked, before this tracker existed or with telemetry off. It is
-- sent again on the next start after the lessons changed, otherwise once per
-- surveyIntervalHours. The progress file only exists once a lesson was completed, without
-- it nothing is sent.
local function surveyProgress()
  local data = jsonReadFile(progressFile)
  if type(data) ~= "table" or data.version ~= progressVersion or type(data.completedLessons) ~= "table" then return end
  local ids = getCompletedLessonIds(data.completedLessons)

  local hours = extensions.telemetry_configManager.getSurveyIntervalHours(
    'gameplay_firstDrive', defaultSurveyIntervalHours)
  local stat = FS:stat(surveyFile)
  local delivered = stat and stat.modtime
  if delivered and delivered > os.time() - hours * 60 * 60 then
    local sent = jsonReadFile(surveyFile)
    if sent and jsonEncode(sent.completedLessonIds or {}) == jsonEncode(ids) then return end
  end

  local survey = {
    name = "firstDriveProgress",
    completedLessonIds = ids,
    lessonsCompleted = #ids,
  }
  -- only kept once it is in the report, so a dropped snapshot is retried on the next start
  if extensions.telemetry_core.addEvent(survey) then
    jsonWriteFile(surveyFile, survey, true)
  end
end

local function endSession(reason)
  if not sessionStartedAt then return end

  if reason == "completed" then
    extensions.telemetry_core.addEvent({
      name = "firstDriveCompleted",
      duration = secondsSince(sessionStartedAt),
    })
  end
  extensions.telemetry_core.endActivity("firstDriveActive", {
    reason = reason,
    lessonsCompleted = completedLessonCount(),
  })
  sessionStartedAt = nil
  lessonId = nil
  lessonStartedAt = nil
end

-- Also fires for a restart from the pause menu, which closes the previous session
local function onFirstDriveStarted(startAtLookout)
  endSession("restarted")
  sessionStartedAt = os.clockhp()
  local ids = completedLessonIds()
  local progress = gameplay_discover_firstDrive_learningProgress
  local allLessonsCompleted
  if progress then allLessonsCompleted = progress.areAllLessonsCompleted() end
  extensions.telemetry_core.startActivity("firstDriveActive", {
    startAtLookout = startAtLookout == true,
    lessonsCompleted = ids and #ids,
    completedLessonIds = ids,
    allLessonsCompleted = allLessonsCompleted,
  })
end

-- reason: completed, skipToFreeroam, mainMenu, startFailed or clientEndMission
local function onFirstDriveEnded(reason)
  endSession(reason)
end

local function onFirstDriveLessonStarted(id)
  if not sessionStartedAt then return end
  lessonId = id
  lessonStartedAt = os.clockhp()
  extensions.telemetry_core.addEvent({
    name = "firstDriveLessonStarted",
    lessonId = id,
  })
end

-- The recovery lesson can also be completed from the crash popup without being started,
-- that completion carries no duration
local function endLesson(eventName, id, reason)
  if not sessionStartedAt then return end
  local event = {name = eventName, lessonId = id, reason = reason}
  if id == lessonId then
    event.duration = secondsSince(lessonStartedAt)
    lessonId = nil
    lessonStartedAt = nil
  end
  extensions.telemetry_core.addEvent(event)
end

-- reason: pauseMenu when the player stops it, otherwise leftArea, leftStartArea, sessionEnded,
-- completionFailed or a lesson specific one like vehicleChanged
local function onFirstDriveLessonStopped(id, reason)
  endLesson("firstDriveLessonStopped", id, reason)
end

local function onFirstDriveLessonCompleted(id)
  endLesson("firstDriveLessonCompleted", id)
end

local function onStopRecovering(timer)
  if not sessionStartedAt then return end
  local experience = gameplay_discover_firstDrive_experience
  -- the recovery tutorial lets the player try the button without recovering the vehicle
  if experience and experience._recoveryPreview then return end

  extensions.telemetry_core.addEvent({
    name = "firstDriveVehicleRecovered",
    heldSeconds = tonumber(timer),
    phase = experience and experience.getPhase(),
    lessonId = lessonId,
  })
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
  surveyProgress()
end

M.onExtensionLoaded = onExtensionLoaded
-- game exit, a lua reload and disabling the tracker all unload it, the core unloads the
-- trackers before their onExit would run
M.onExtensionUnloaded = function() endSession("trackerUnloaded") end

M.onFirstDriveStarted = onFirstDriveStarted
M.onFirstDriveEnded = onFirstDriveEnded
M.onFirstDriveLessonStarted = onFirstDriveLessonStarted
M.onFirstDriveLessonStopped = onFirstDriveLessonStopped
M.onFirstDriveLessonCompleted = onFirstDriveLessonCompleted
M.onStopRecovering = onStopRecovering

return M
