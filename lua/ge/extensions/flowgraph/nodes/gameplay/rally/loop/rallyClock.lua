-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = 'rallyClock'

C.name = 'Rally Clock'
C.description = 'Gets the current epoch time and scheduled event time for a specific event from the rally loop manager.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'string', name = 'eventName', description = 'Name of the event to get the time for (spName, e.g., "SS_start_line").'},

  { dir = 'out', type = 'number', name = 'currentEpochTime', description = 'Current rally epoch time in seconds.'},
  { dir = 'out', type = 'number', name = 'scheduledEventTime', description = 'Scheduled event time in rally epoch for the specified event.'},
}

function C:init(mgr, ...)
  -- Cache for scheduled event time lookup
  self.cachedEventName = nil
  self.cachedMissionId = nil
  self.cachedScheduledEventTime = nil
end

function C:_executionStarted()
  -- Reset cache when execution starts
  self.cachedEventName = nil
  self.cachedMissionId = nil
  self.cachedScheduledEventTime = nil
end

local function getRallyLoopManager()
  if not extensions.isExtensionLoaded(RallyUtil.extRallyLoop) then
    log('E', logTag, RallyUtil.extRallyLoop .. ' extension not loaded')
    return nil
  end
  return gameplay_rallyLoop.getManager()
end

function C:work()
  local rm = getRallyLoopManager()
  if not rm then
    log('E', logTag, 'No rally loop manager')
    return
  end

  -- Get current epoch time from manager (always updates every frame)
  local currentEpochTime = rm:getEpochTime()
  self.pinOut.currentEpochTime.value = currentEpochTime

  -- Get event name from input pin
  local eventName = self.pinIn.eventName.value
  local currentMissionId = rm:getCurrentMissionId()

  -- Check if cache is invalid (event name or mission changed)
  if self.cachedEventName ~= eventName or self.cachedMissionId ~= currentMissionId then
    -- Cache miss - look up the scheduled event time
    local scheduledEventTime = rm:getScheduledEventTime(eventName)

    -- Update cache
    self.cachedScheduledEventTime = scheduledEventTime
    self.cachedEventName = eventName
    self.cachedMissionId = currentMissionId

    log('D', logTag, string.format('Cache updated: event=%s, mission=%s, time=%s',
      eventName or 'nil', currentMissionId or 'nil',
      scheduledEventTime and string.format('%.2f', scheduledEventTime) or 'nil'))
  end

  -- Use cached value
  self.pinOut.scheduledEventTime.value = self.cachedScheduledEventTime
end

return _flowgraph_createNode(C)
