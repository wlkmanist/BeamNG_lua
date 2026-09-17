-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local RallyLoopStars = require('/lua/ge/extensions/gameplay/rally/loop/rallyLoopStars')

local function createAttempt()
  return gameplay_missions_progress.newAttempt('attempted', {})
end

local function addDnfData(mgr, attempt, dnfType)
  attempt.dnf = true
  attempt.data.dnfType = dnfType
  attempt.data.dnfMissionId = mgr:getCurrentMissionId()
end

local function addTimingData(mgr, attempt)
  attempt.data.penalty = mgr:getTotalPenalty() or 0
  attempt.data.totalTime = mgr:getTotalTime() or 0

  -- Get all individual SS stage times from eventLog
  local eventLog = mgr:getEventLog()
  if eventLog then
    local stageTimes = eventLog:getStageTimes()
    for i, item in ipairs(stageTimes) do
      -- Store individual stage times as timeSS1, timeSS2, etc.
      attempt.data["timeSS" .. i] = item.data.stageTimeSecs
    end
  end
end

local function addVehicleData(attempt)
  local veh = getPlayerVehicle(0)
  if veh then
    local vData = {
      model = veh.jbeam,
      config = veh.partConfig,
      isConfigFile = string.endswith(veh.partConfig, '.pc')
    }
    dump(vData)
    attempt["vehicle"] = vData
  end
end

local function aggregate(attempt, missionId)
  local totalChange = gameplay_missions_progress.aggregateAttempt(missionId, attempt)
  return totalChange
end

local function getMission(mgr, missionId)
  local mission = gameplay_missions_missions
    and gameplay_missions_missions.getMissionById
    and gameplay_missions_missions.getMissionById(missionId)
    or nil
  return mission or (mgr.getRallyLoopMission and mgr:getRallyLoopMission())
end

local function save(missionId)
  gameplay_missions_progress.saveMissionSaveData(missionId)
end

-- Public API: Create and save a normal attempt
-- @return totalChange: The aggregate change result from the attempt
-- @return attempt: The created attempt object
local function createRallyLoopAttemptForFinish(mgr)
  local missionId = mgr:getRallyLoopMissionId()
  if not missionId then
    log('E', '', 'createRallyLoopAttemptForFinish: could not get mission ID')
    return
  end

  local attempt = createAttempt()
  addTimingData(mgr, attempt)
  addVehicleData(attempt)
  RallyLoopStars.gradeAttempt(getMission(mgr, missionId), attempt)
  local totalChange = aggregate(attempt, missionId)
  save(missionId)
  return attempt, totalChange
end

-- Public API: Create and save an abandon attempt
-- @param dnfType: Type of DNF - "restart" or "abandon"
-- @return totalChange: The aggregate change result from the attempt
local function createRallyLoopAttemptForDnf(mgr, dnfType)
  local missionId = mgr:getRallyLoopMissionId()
  if not missionId then
    log('E', '', 'createRallyLoopAttemptForDnf: could not get mission ID')
    return
  end

  local attempt = createAttempt()
  addDnfData(mgr, attempt, dnfType)
  addVehicleData(attempt)
  local totalChange = aggregate(attempt, missionId)
  save(missionId)
  return attempt, totalChange
end

-- Public API
M.createRallyLoopAttemptForFinish = createRallyLoopAttemptForFinish
M.createRallyLoopAttemptForDnf = createRallyLoopAttemptForDnf

return M

