-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = ''

C.name = 'Rally Mode Session Start'
C.description = 'Do necessary loading for Rally Mode.'
C.color = rallyUtil.rally_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'

C.pinSchema = {
  -- { dir = 'in', type = 'number', name = 'vehId', description = 'Vehicle id.'},
  { dir = 'in', type = 'bool', name = 'fireEvents', description = 'Fire events.', default = true},
  { dir = 'in', type = 'bool', name = 'disableOnStart', default = false, description = 'Disable pacenotes playback initially (dont forget to re-enable after countdown).'},

  { dir = 'out', type = 'string', name = 'loopPrefab', default = false, description = 'Loop prefab to load.'},
}

-- gets called when the project of this node stops execution.
function C:_executionStopped()
  -- log('D', logTag, "stopped rallyStage execution")
  self:unloadExt()
  if self.pinIn.fireEvents.value then
    extensions.hook('onRallySessionEnd')
  end
end

function C:unloadExt()
  -- log('D', logTag, 'unloading gameplay_rally')
  if extensions.isExtensionLoaded('gameplay_rally') then
    extensions.unload('gameplay_rally')
  end

  if self.loadedRallyLoopBridge and extensions.isExtensionLoaded(rallyUtil.extRallyLoop) then
    local loopManager = gameplay_rallyLoop and gameplay_rallyLoop.getManager()
    if not loopManager then
      extensions.unload(rallyUtil.extRallyLoop)
    end
  end
  self.loadedRallyLoopBridge = false
end

function C:loadExt()
  -- log('D', logTag, 'loading gameplay_rally')
  if not extensions.isExtensionLoaded('gameplay_rally') then
    extensions.load('gameplay_rally')
  end
end

function C:loadRallyLoopBridge()
  if not extensions.isExtensionLoaded(rallyUtil.extRallyLoop) then
    extensions.load(rallyUtil.extRallyLoop)
    self.loadedRallyLoopBridge = true
  else
    self.loadedRallyLoopBridge = false
  end
end

function C:workOnce()
  -- log('D', logTag, 'loading rally mode')
  -- self:unloadExt()
  self:loadExt()
  self:loadRallyLoopBridge()

  local missionId, missionDir, voicepackPick

  -- Get mission from rally loop if available
  if extensions.isExtensionLoaded('gameplay_rallyLoop') then
    local loopManager = gameplay_rallyLoop.getManager()
    if loopManager then
      missionId = loopManager:getCurrentMissionId()
      local schedule = loopManager:getSchedule()
      local currentIndex = loopManager.currentMissionIndex
      local scheduleEntry = schedule and schedule[currentIndex]
      missionDir = scheduleEntry and scheduleEntry.missionDir
      voicepackPick = loopManager:getVoicepackPickForMission(missionId, missionDir)
      log('D', logTag, 'Got mission from rally loop: ' .. tostring(missionId) .. ', dir: ' .. tostring(missionDir))
    end
  end

  -- Fall back to detection if loop didn't provide mission
  if not missionId or not missionDir then
    local err
    missionId, missionDir, err = rallyUtil.detectMissionIdHelper()
    if err then
      log('E', logTag, '')
      log('E', logTag, '===============================================')
      log('E', logTag, '= RallyStage flowgraph: failed to detect missionId')
      log('E', logTag, '= Did you select a Rally stage in the mission editor? And open the race file?')
      log('E', logTag, '===============================================')
      log('E', logTag, '')
      return
    end
    log('D', logTag, 'Detected mission: ' .. tostring(missionId) .. ', dir: ' .. tostring(missionDir))
  end

  local loaded, loadError = gameplay_rally.loadMission(missionId, missionDir, nil, voicepackPick, {owner = 'mission'})
  if not loaded then
    log('E', logTag, 'failed to load mission-owned rally manager: '..tostring(loadError))
    return
  end

  if self.pinIn.disableOnStart.value then
    local rm = gameplay_rally.getRallyManager()
    if rm then
      rm:setPacenoteProcessingEnabled(false)
    end
  end

  local loopManager = gameplay_rallyLoop and gameplay_rallyLoop.getManager()
  if loopManager then
    gameplay_rallyLoop.setupForNewMission()
    local rm = gameplay_rally.getRallyManager()
    self.pinOut.loopPrefab.value = rm:getLoopPrefabPath()
  end


  if self.pinIn.fireEvents.value then
    extensions.hook('onRallySessionStart')
  end
end

return _flowgraph_createNode(C)
