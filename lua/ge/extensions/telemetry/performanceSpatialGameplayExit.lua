-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local activityTypes = {
  mission = true,
  scenario = true,
  careerDelivery = true,
  testDrive = true,
  vehicleCertification = true,
  freeformDelivery = true,
  freeroamDrag = true,
  freeroamDrift = true,
  freeroamCrawl = true,
}
local exitKinds = {abort = true, worldExit = true, gameExit = true}

local function call(module, name, ...)
  local fn = module and module[name]
  if type(fn) ~= "function" then return nil end
  local ok, result = pcall(fn, ...)
  return ok and result or nil
end

local function text(value, maximum)
  if type(value) == "number" and value == value
      and value ~= math.huge and value ~= -math.huge then
    value = tostring(value)
  end
  if type(value) ~= "string" or #value == 0 or #value > maximum
      or value:find("%c") then return nil end
  return value
end

local function validActivityId(value)
  value = text(value, 256)
  if not value or value:sub(1, 1) == " " or value:sub(-1) == " "
      or not value:match("^[%w_./:+%- ]+$") then return nil end
  return value
end

local function activity(activityType, activityId)
  if not activityTypes[activityType] then return nil end
  return {
    activityType = activityType,
    activityId = validActivityId(activityId),
  }
end

function M.resolveActivity(source)
  source = source or _G

  local missionId = call(
    source.gameplay_missions_missionManager, "getForegroundMissionId")
  if missionId then return activity("mission", missionId) end

  local scenario = call(source.scenario_scenarios, "getScenario")
  if type(scenario) == "table"
      and scenario.state ~= "finished" and scenario.state ~= "post" then
    return activity(
      "scenario", scenario.sourceFile or scenario.scenarioName or scenario.name)
  end

  local freeform = source.gameplay_freeformDelivery_freeformDelivery
  if call(freeform, "isActive") then
    local delivery = call(freeform, "getCurrentDelivery")
    return activity(
      "freeformDelivery",
      delivery and (delivery._basePath or delivery._loadedPath))
  end

  if call(source.career_modules_testDrive, "isActive") then
    return activity("testDrive")
  end
  local vehiclePerformance = source.career_modules_vehiclePerformance
  if call(vehiclePerformance, "isTestInProgress") then
    return activity("vehicleCertification")
  end

  local drag = source.gameplay_drag_core
  if call(drag, "getDragIsStarted") and call(drag, "getGameplayContext") == "freeroam" then
    local data = call(drag, "getData")
    if data and not data.isCompleted then
      local id = call(drag, "getPoiKey", data)
      if id and id:sub(1, 1) == ":" then
        id = tostring(call(source, "getCurrentLevelIdentifier") or "") .. id
      end
      return activity("freeroamDrag", id)
    end
  end

  local drift = source.gameplay_drift_freeroam_driftSpots
  if call(drift, "getIsInFreeroamChallenge")
      and not call(drift, "getIsInTheConcludingPhase") then
    return activity("freeroamDrift")
  end

  local trail = source.gameplay_crawl_general
    and source.gameplay_crawl_general.activeTrail
  local crawlerId = call(source.gameplay_crawl_utils, "getActiveCrawlerId")
  local crawlState = crawlerId
    and call(source.gameplay_crawl_utils, "getCrawlState", crawlerId)
  if type(trail) == "table" and not trail.isFromMission
      and crawlerId
      and not (crawlState and (crawlState.isCompleted or crawlState.isDisqualified)) then
    trail = trail.trail
    return activity(
      "freeroamCrawl", trail and (trail._filePath or trail.id))
  end

  if call(source.career_modules_delivery_general, "isDeliveryModeActive") then
    return activity("careerDelivery")
  end
end

local function round(value)
  if type(value) ~= "number" or value ~= value
      or value == math.huge or value == -math.huge then return nil end
  return math.floor(value * 10 + 0.5) / 10
end

local function position(x, y, z)
  x, y, z = round(x), round(y), round(z)
  return x and y and z and {x = x, y = y, z = z} or nil
end

local function capturePosition(source)
  local vehicle = call(source.be, "getPlayerVehicle", source.be, 0)
  local vehiclePosition = call(vehicle, "getPosition", vehicle)
  if vehiclePosition then
    local result = position(vehiclePosition.x, vehiclePosition.y, vehiclePosition.z)
    if result then return result, "vehicle" end
  end

  local camera = source.core_camera
  local fn = camera and camera.getPositionXYZ
  if type(fn) ~= "function" then return nil end
  local ok, x, y, z = pcall(fn)
  if not ok then return nil end
  local result = position(x, y, z)
  if result then return result, "camera" end
end

function M.capture(exitKind, currentActivity, trackedLevels, source)
  if not exitKinds[exitKind] then return nil end
  source = source or _G
  local level = call(source, "getCurrentLevelIdentifier")
  level = text(level, 128)
  if not level or not level:match("^[%w_.-]+$")
      or (trackedLevels and not trackedLevels[level]) then return nil end

  currentActivity = currentActivity or M.resolveActivity(source)
  if type(currentActivity) ~= "table" then return nil end
  currentActivity = activity(
    currentActivity.activityType,
    currentActivity.activityId)
  if not currentActivity then return nil end

  local eventPosition, positionSource = capturePosition(source)
  if not eventPosition then return nil end
  currentActivity.name = "gameplayActivityExit"
  currentActivity.exitKind = exitKind
  currentActivity.level = level
  currentActivity.position = eventPosition
  currentActivity.positionSource = positionSource
  return currentActivity
end

return M
