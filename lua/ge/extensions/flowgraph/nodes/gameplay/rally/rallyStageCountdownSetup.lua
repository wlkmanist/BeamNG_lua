-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local StagedCountdownUtils = require('/lua/ge/extensions/gameplay/rally/loop/stagedCountdownUtils')

local C = {}

local defaultDuration = 3
local defaultMaxAnnounced = 3

C.name = 'Rally Stage Countdown Setup'
C.description = 'Warms the rally countdown UI stream before the stage fade-in.'
C.color = rallyUtil.rally_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'

local function ensureRallyLoopBridgeLoaded()
  if extensions and extensions.isExtensionLoaded and extensions.load and not extensions.isExtensionLoaded(rallyUtil.extRallyLoop) then
    extensions.load(rallyUtil.extRallyLoop)
  end
end

local function clearStageTimingState()
  if not gameplay_rally or not gameplay_rally.getRallyManager then return end

  local rm = gameplay_rally.getRallyManager()
  if rm and rm.clearSplitTimes then
    rm:clearSplitTimes()
  end
end

function C:workOnce()
  ensureRallyLoopBridgeLoaded()
  clearStageTimingState()

  local countdownSettings = StagedCountdownUtils.getStageCountdownSettings(defaultDuration, defaultMaxAnnounced)

  extensions.hook('onRallyDataUpdated', {
    resetFallbackStreamData = true,
    activeState = rallyUtil.activeState_countdown,
    countdownData = {
      countdown = countdownSettings.duration,
      state = 'waiting'
    }
  })
end

return _flowgraph_createNode(C)
