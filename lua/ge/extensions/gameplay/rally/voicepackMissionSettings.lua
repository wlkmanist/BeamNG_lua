-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local voicepack = require('/lua/ge/extensions/gameplay/rally/voicepack')

local M = {}

local voicepackPickKey = 'rallyVoicepackPick'

local function voicepackPickValue(userSettings)
  return userSettings and userSettings[voicepackPickKey] or nil
end

function M.buildStageSetting(missionDir, missionId)
  return voicepack.buildMissionUserSetting(missionDir, missionId)
end

function M.buildLoopSetting(missionTypeData)
  return voicepack.buildLoopMissionUserSetting(missionTypeData)
end

function M.rememberStagePick(userSettings, missionDir, missionId)
  local pick = voicepack.pickFromSettingValue(voicepackPickValue(userSettings))
  if not pick or pick.type == 'preferences' then return end
  voicepack.addToMRU(pick, missionDir, missionId)
end

function M.rememberLoopPick(missionTypeData, userSettings)
  voicepack.addLoopMissionSettingToMRU(missionTypeData, voicepackPickValue(userSettings))
end

return M
