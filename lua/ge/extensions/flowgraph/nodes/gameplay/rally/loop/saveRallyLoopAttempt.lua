-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local RallyAttempts = require('/lua/ge/extensions/gameplay/rally/loop/rallyAttempts')
local RallyLoopStars = require('/lua/ge/extensions/gameplay/rally/loop/rallyLoopStars')

local C = {}
local logTag = ''

C.name = 'Rally Loop Save Attempt'
C.description = 'Saves the current rally loop attempt.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'in', type = 'string', name = 'dnfType', description = 'Type of DNF - "restart" or "abandon".'},
  { dir = 'out', type = 'table', name = "change", description = "Change Object", fixed=true },
  { dir = 'out', type = 'table', name = "outroTranslation", description = "Translation object with the attempt data as context.", tableType = 'translationObject', fixed=true },
}

-- gets called when the project of this node stops execution.
-- function C:_executionStopped()
  -- log('D', logTag, "stopped rallyStage execution")
  -- self:unloadExt()
  -- extensions.hook('onRallySessionEnd')
-- end

local function getRallyLoopManager()
  if not extensions.isExtensionLoaded(RallyUtil.extRallyLoop) then
    log('E', logTag, RallyUtil.extRallyLoop .. ' extension not loaded')
    return nil
  end
  return gameplay_rallyLoop.getManager()
end

function C:workOnce()
  local rm = getRallyLoopManager()
  if rm then
    local dnfType = self.pinIn.dnfType.value
    if dnfType then
      -- Do not count attempt as abandon if we are still in serviceOut
      local currentMissionId = rm:getCurrentMissionId()
      if currentMissionId ~= 'serviceOut' then
        RallyAttempts.createRallyLoopAttemptForDnf(rm, dnfType)
      else
        log('D', logTag, 'Not counting DNF in serviceOut as an attempt')
      end
    else
      local mission = rm:getRallyLoopMission()
      local missionId = rm:getRallyLoopMissionId()
      if missionId and gameplay_missions_missions and gameplay_missions_missions.getMissionById then
        mission = gameplay_missions_missions.getMissionById(missionId) or mission
      end
      local attempt, totalChange = RallyAttempts.createRallyLoopAttemptForFinish(rm)
      local outroText = RallyLoopStars.getOutroText(mission, attempt)
        or mission.missionTypeData.endScreenText
      self.pinOut.change.value = totalChange
      self.pinOut.outroTranslation.value =  { txt = outroText, context = deepcopy(attempt.data) }
    end
  else
    log('E', logTag, 'no rally loop manager')
  end
end

return _flowgraph_createNode(C)
