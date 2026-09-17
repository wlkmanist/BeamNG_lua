-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local AiCompetitors = require('/lua/ge/extensions/gameplay/rally/aiCompetitors')

local C = {}
local logTag = 'RallyLoopAiCompetitorsInputs'

C.name = 'Rally Loop AI Competitors Inputs'
C.description =
  'Builds raw SS playerTimes, configured medal reference times, and official loop total time. Penalties are not added into stage times.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = { 'rally' }
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = '', chainFlow = true },
  { dir = 'out', type = 'flow', name = 'flow', description = '', chainFlow = true },
  {
    dir = 'out',
    type = 'table',
    tableType = 'generic',
    name = 'playerTimes',
    description = 'Raw SS stage times in seconds (no penalties; nil after first missing time / DNF).',
  },
  {
    dir = 'out',
    type = 'table',
    tableType = 'generic',
    name = 'silverTimes',
    description = 'Legacy pin name: configured reference times from linked rallyStage missions (gold by default).',
  },
  {
    dir = 'out',
    type = 'table',
    tableType = 'generic',
    name = 'stageLabels',
    description = 'Display labels for the SS stages, aligned with player and reference times.',
  },
  {
    dir = 'out',
    type = 'number',
    name = 'playerTotalTimeSec',
    description = 'Official loop total time in seconds (event log: all stage times + all penalties). Use for end-screen player total.',
  },
}

local function getRallyLoopManager()
  if not extensions.isExtensionLoaded(RallyUtil.extRallyLoop) then
    log('E', logTag, RallyUtil.extRallyLoop .. ' extension not loaded')
    return nil
  end
  return gameplay_rallyLoop.getManager()
end

local function extractMissionId(value)
  if type(value) ~= 'string' or value == '' or value == '<none>' then
    return nil
  end
  return value:match('.*%(([^()]*)%)$') or value
end

local function getStageReferenceTimes(mission)
  local referenceTimes = {}
  if not mission or not mission.missionTypeData then
    return referenceTimes
  end

  local missingReferenceTime = false
  for i = 1, 4 do
    local stageId = extractMissionId(mission.missionTypeData['stage' .. i .. '_rallyStage'])
    if stageId then
      local stageMission = gameplay_missions_missions and gameplay_missions_missions.getMissionById(stageId) or nil
      local referenceTime = stageMission and AiCompetitors.getReferenceTime(stageMission.missionTypeData) or nil
      if referenceTime then
        referenceTimes[#referenceTimes + 1] = referenceTime
      else
        missingReferenceTime = true
        log('W', logTag, string.format(
          'RallyLoop stage %d (%s) is missing usable rallyStage %s.',
          i, stageId, AiCompetitors.referenceStarKey
        ))
      end
    end
  end

  if missingReferenceTime then
    return {}
  end
  return referenceTimes
end

function C:workOnce()
  self.pinOut.playerTimes.value = {}
  self.pinOut.silverTimes.value = {}
  self.pinOut.stageLabels.value = {}
  self.pinOut.playerTotalTimeSec.value = 0

  local rm = getRallyLoopManager()
  if not rm then
    return
  end

  -- Prefer registry mission so missionTypeData matches disk; mgr.mission can be a slim instance.
  local mission = rm:getRallyLoopMission()
  local missionId = rm:getRallyLoopMissionId()
  if missionId and gameplay_missions_missions then
    local byId = gameplay_missions_missions.getMissionById(missionId)
    if byId and byId.missionTypeData then
      mission = byId
    end
  end

  local referenceTimes = getStageReferenceTimes(mission)
  self.pinOut.silverTimes.value = referenceTimes
  local S = #referenceTimes
  if S == 0 then
    return
  end

  local stageLabels = rm.getStageLabels and rm:getStageLabels() or {}
  if type(stageLabels) == 'table' and #stageLabels == S then
    self.pinOut.stageLabels.value = stageLabels
  elseif type(stageLabels) == 'table' and #stageLabels > 0 then
    log('W', logTag, string.format('RallyLoop stage label count (%d) does not match reference time count (%d).', #stageLabels, S))
  end

  local eventLog = rm:getEventLog()
  if not eventLog then
    return
  end

  local officialTotal = eventLog:getTotalTime()
  if type(officialTotal) == 'number' and officialTotal > 0 then
    self.pinOut.playerTotalTimeSec.value = officialTotal
  end

  local stageItems = eventLog:getStageTimes()
  local playerTimes = {}
  for i = 1, S do
    local item = stageItems[i]
    if item and item.data and type(item.data.stageTimeSecs) == 'number' then
      playerTimes[i] = item.data.stageTimeSecs
    else
      playerTimes[i] = nil
    end
  end

  self.pinOut.playerTimes.value = playerTimes
end

return _flowgraph_createNode(C)
