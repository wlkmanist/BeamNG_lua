-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local RallyLoopTime = require('/lua/ge/extensions/gameplay/rally/loop/rallyLoopTime')

local C = {}
local logTag = ''

C.name = 'Rally Loop Init'
C.description = 'Do necessary loading for Rally Loop.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'

C.pinSchema = {
  -- { dir = 'in', type = 'number', name = 'vehId', description = 'Vehicle id.'},
  { dir = 'out', type = 'flow', name = 'success', description = 'Outflow on successful initialization.' },
  { dir = 'out', type = 'flow', name = 'failed', description = 'Outflow on failed initialization.' },
}

-- gets called when the project of this node stops execution.
-- function C:_executionStopped()
  -- log('D', logTag, "stopped rallyStage execution")
  -- self:unloadExt()
  -- extensions.hook('onRallySessionEnd')
-- end

function C:_executionStopped()
  log('D', logTag, 'loopInit _executionStopped')
  if extensions.isExtensionLoaded(RallyUtil.extRallyLoop) then
    log('D', logTag, 'loopInit _executionStopped: unloading rally loop extension')
    extensions.unload(RallyUtil.extRallyLoop)
  end
end

function C:unloadExt()
  log('D', logTag, 'unloading ' .. RallyUtil.extRallyLoop)
  if extensions.isExtensionLoaded(RallyUtil.extRallyLoop) then
    extensions.unload(RallyUtil.extRallyLoop)
  end
end

function C:loadExt()
  log('D', logTag, 'loading ' .. RallyUtil.extRallyLoop)
  if not extensions.isExtensionLoaded(RallyUtil.extRallyLoop) then
    extensions.load(RallyUtil.extRallyLoop)
  end
end

function C:workOnce()
  -- clear existing extension
  self:unloadExt()
  -- load new extension
  self:loadExt()

  local missionId, missionDir, err = RallyUtil.detectMissionIdHelper()
  if err then
    log('E', logTag, '')
    log('E', logTag, '===============================================')
    log('E', logTag, '= RallyLoop flowgraph: failed to detect missionId')
    log('E', logTag, '= Did you select a Rally stage in the mission editor? And open the race file?')
    log('E', logTag, '===============================================')
    log('E', logTag, '')
    self.pinOut.failed.value = true
    return
  end

  -- Time-of-day is applied by missionManager via the environment setup module.
  -- For the static Default option we force play=false here so freeroam's running
  -- clock doesn't leak into the loop.
  local mission = gameplay_missions_missions and gameplay_missions_missions.getMissionById(missionId)
  local environment = mission and mission.setupModules and mission.setupModules.environment
  if environment and environment.enabled then
    -- Default/CSV picks: use today's real-world date so the sun matches the date.
    -- (The "Current" passthrough disables the env module, so it is left as-is.)
    RallyLoopTime.applyCurrentDate()
    if environment._rallyForceStatic then
      RallyLoopTime.setPlaying(false, environment.time)
    end
  end
  gameplay_rallyLoop.setDebugLogging(true)
  gameplay_rallyLoop.setup(missionId, missionDir)
  self.pinOut.success.value = true
end

return _flowgraph_createNode(C)
