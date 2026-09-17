-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = 'rallyLoopStars'

local starKeys = { 'bronzeTime', 'silverTime', 'goldTime' }

local function extractMissionId(value)
  if type(value) ~= 'string' or value == '' or value == '<none>' then return nil end
  return value:match('.*%(([^()]*)%)$') or value
end
M.extractMissionId = extractMissionId

local function getStageMissionData(stageId)
  local mission = gameplay_missions_missions
    and gameplay_missions_missions.getMissionById
    and gameplay_missions_missions.getMissionById(stageId)
    or nil
  if mission and mission.missionTypeData then return mission end

  local info = jsonReadFile('/gameplay/missions/' .. stageId .. '/info.json')
  return info
end

-- Sum the linked stages' existing authored thresholds. All configured stages must
-- provide all three values; partial loop targets would be misleading.
function M.deriveThresholds(loopMissionTypeData)
  if type(loopMissionTypeData) ~= 'table' then return nil end

  local totals = { bronzeTime = 0, silverTime = 0, goldTime = 0 }
  local stageCount = 0
  for i = 1, 4 do
    local stageId = extractMissionId(loopMissionTypeData['stage' .. i .. '_rallyStage'])
    if stageId then
      stageCount = stageCount + 1
      local stageMission = getStageMissionData(stageId)
      local stageData = stageMission and stageMission.missionTypeData
      if not stageData then
        log('W', logTag, string.format('Could not resolve rallyStage mission data for loop stage %d (%s).', i, stageId))
        return nil
      end
      local activeStars = stageMission.careerSetup and stageMission.careerSetup.starsActive or {}
      for _, key in ipairs(starKeys) do
        local value = tonumber(stageData[key])
        if activeStars[key] ~= true or not value or value <= 0 then
          log('W', logTag, string.format('Loop stage %d (%s) has no active, usable %s.', i, stageId, key))
          return nil
        end
        totals[key] = totals[key] + value
      end
      if stageData.goldTime > stageData.silverTime or stageData.silverTime > stageData.bronzeTime then
        log('W', logTag, string.format('Loop stage %d (%s) has invalid medal threshold ordering.', i, stageId))
        return nil
      end
    end
  end

  if stageCount == 0 then return nil end
  for _, key in ipairs(starKeys) do
    totals[key] = math.floor(totals[key] * 10 + 0.5) / 10
  end
  totals.stageCount = stageCount
  return totals
end

function M.applyThresholds(loopMissionTypeData)
  local totals = M.deriveThresholds(loopMissionTypeData)
  if not totals then
    loopMissionTypeData.bronzeTime = nil
    loopMissionTypeData.silverTime = nil
    loopMissionTypeData.goldTime = nil
    return nil
  end
  for _, key in ipairs(starKeys) do
    loopMissionTypeData[key] = totals[key]
  end
  return totals
end

function M.gradeAttempt(mission, attempt)
  attempt.unlockedStars = attempt.unlockedStars or {}
  local data = mission and mission.missionTypeData
  local time = attempt.data and attempt.data.totalTime
  if attempt.dnf or not data or type(time) ~= 'number' or time <= 0 then
    return attempt
  end
  local activeStars = mission.careerSetup and mission.careerSetup.starsActive or {}
  for _, key in ipairs(starKeys) do
    local threshold = tonumber(data[key])
    if activeStars[key] == true and threshold and threshold > 0 then
      attempt.unlockedStars[key] = time <= threshold
    end
  end
  return attempt
end

local function outroForKey(mission, key)
  local careerTexts = mission.careerSetup and mission.careerSetup.starOutroTexts or {}
  local text = careerTexts[key]
  if text == nil or text == '' then
    text = mission.defaultStarOutroTexts and mission.defaultStarOutroTexts[key] or nil
  end
  return text
end

function M.getOutroText(mission, attempt)
  if not (mission and mission.missionTypeData and mission.missionTypeData.goldTime) then
    return nil
  end
  local activeStars = mission.careerSetup and mission.careerSetup.starsActive or {}
  if activeStars.goldTime ~= true and activeStars.silverTime ~= true and activeStars.bronzeTime ~= true then
    return nil
  end

  local text = outroForKey(mission, 'noStarUnlocked')
  for _, key in ipairs(starKeys) do
    if attempt and attempt.unlockedStars and attempt.unlockedStars[key] then
      text = outroForKey(mission, key) or text
    end
  end
  return text
end

return M
