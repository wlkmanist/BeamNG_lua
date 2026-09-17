-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local aiCompetitors = require('/lua/ge/extensions/gameplay/rally/aiCompetitors')

local C = {}
local logTag = 'RallyAICompetitorsLeaderboard'

C.name = 'Rally AI Competitors Leaderboard'
C.description = 'Simulates competitor stage times from aiCompetitorsConfig and outputs leaderboard data for the end screen.'
C.color = rallyUtil.rally_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = 'Inflow for this node.' },
  { dir = 'in', type = 'number', name = 'playerTime', description = 'Player stage time (seconds). Used when playerTimes is not set.' },
  { dir = 'in', type = 'number', name = 'silverTime', description = 'Legacy fallback reference time. Standalone rally uses aiCompetitors.referenceStarKey from missionTypeData.' },
  { dir = 'in', type = 'table', tableType = 'generic', name = 'playerTimes', description = 'Optional: one player time per stage (seconds). Same length as the configured reference-time table.' },
  { dir = 'in', type = 'table', tableType = 'generic', name = 'silverTimes', description = 'Legacy pin name: configured per-stage reference times (gold by default).' },
  { dir = 'in', type = 'table', tableType = 'generic', name = 'stageLabels', description = 'Optional: one display label per stage, aligned with player and reference times.' },
  {
    dir = 'in',
    type = 'number',
    name = 'playerTotalTimeSec',
    description = 'Optional: official rally loop total seconds (event log). Ranks the player vs AI by this total and uses it for the player final time.',
  },
  { dir = 'out', type = 'flow', name = 'flow', description = 'Outflow for this node.' },
  { dir = 'out', type = 'table', tableType = 'generic', name = 'leaderboard', description = '{ rows, playerRowIndex } for end screen UI; multiStage + stageCount when using stage tables.' },
}

local function copyStageLabels(stageLabels, stageCount)
  if type(stageLabels) ~= 'table' or type(stageCount) ~= 'number' then
    return nil
  end

  local labels = {}
  for i = 1, stageCount do
    local label = stageLabels[i]
    if type(label) ~= 'string' or label == '' then
      return nil
    end
    labels[i] = label
  end
  return labels
end

local function getRallyLoopStageLabels(stageCount)
  if type(stageCount) ~= 'number' or stageCount < 1 then
    return nil
  end
  if not extensions.isExtensionLoaded(rallyUtil.extRallyLoop) then
    return nil
  end
  local rm = gameplay_rallyLoop and gameplay_rallyLoop.getManager and gameplay_rallyLoop.getManager() or nil
  if not rm or not rm.getStageLabels then
    return nil
  end
  return copyStageLabels(rm:getStageLabels(), stageCount)
end

function C:workOnce()
  local ptTable = self.pinIn.playerTimes.value
  local stTable = self.pinIn.silverTimes.value
  local labelTable = self.pinIn.stageLabels and self.pinIn.stageLabels.value or nil
  local officialTotal = self.pinIn.playerTotalTimeSec.value
  local sortSecs = type(officialTotal) == 'number' and officialTotal > 0 and officialTotal or nil

  if type(ptTable) == 'table' and type(stTable) == 'table' and #ptTable > 0 and #ptTable == #stTable then
    self.pinOut.leaderboard.value = aiCompetitors.computeLeaderboard(ptTable, stTable, nil, sortSecs)
    local leaderboard = self.pinOut.leaderboard.value
    local stageCount = leaderboard and leaderboard.stageCount or nil
    local stageLabels = copyStageLabels(labelTable, stageCount) or getRallyLoopStageLabels(stageCount)
    if not stageLabels then
      log('E', logTag, string.format('Missing or invalid stageLabels for multi-stage leaderboard. stageCount=%s', tostring(stageCount)))
      self.pinOut.leaderboard.value = { rows = {} }
      return
    end
    leaderboard.stageLabels = stageLabels
  else
    local playerSeconds = self.pinIn.playerTime.value
    local referenceSeconds = aiCompetitors.getReferenceTime(
      self.mgr.activity and self.mgr.activity.missionTypeData
    ) or self.pinIn.silverTime.value
    self.pinOut.leaderboard.value = aiCompetitors.computeLeaderboard(playerSeconds, referenceSeconds, nil, sortSecs)
  end
end

return _flowgraph_createNode(C)
