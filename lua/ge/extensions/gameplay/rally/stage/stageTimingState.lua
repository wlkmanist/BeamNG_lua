-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

function C:init()
  self:reset()
end

function C:reset()
  self.status = 'idle'
  self.active = false
  self.complete = false
  self.elapsedTime = 0
  self.finishTime = nil
  self.frameStartTime = 0
  self.frameDt = 0
  self.splitTimes = {}
  self.splitOrder = {}
end

function C:setActive(active)
  active = active == true
  if self.complete then
    self.active = false
    return
  end

  if active and not self.active then
    self.status = 'active'
  elseif not active and self.active then
    self.status = 'idle'
  end

  self.active = active
end

function C:advance(dt)
  if self.active and not self.complete then
    self.frameStartTime = self.elapsedTime
    self.frameDt = dt or 0
    self.elapsedTime = self.elapsedTime + self.frameDt
  else
    self.frameStartTime = self:getTime()
    self.frameDt = 0
  end
end

function C:addTime(seconds)
  seconds = seconds or 0
  if seconds <= 0 or not self:isActive() then
    return false
  end

  self.elapsedTime = self.elapsedTime + seconds
  return true
end

function C:completeAt(time)
  self.complete = true
  self.active = false
  self.status = 'complete'
  self.finishTime = time or self.elapsedTime
  self.elapsedTime = self.finishTime
end

function C:recordSplit(splitData, time, source)
  if not splitData or not splitData.isSplitTiming then return end

  local pathnodeId = splitData.pathnodeId
  if not pathnodeId then return end

  if not self.splitTimes[pathnodeId] then
    table.insert(self.splitOrder, pathnodeId)
  end

  local splitTime = time or self:getTime()
  local entry = {
    pathnodeId = pathnodeId,
    pathnodeName = splitData.pathnodeName,
    pathnodeType = splitData.pathnodeType,
    splitLabel = splitData.splitLabel,
    time = splitTime,
    source = source or 'tracker',
  }

  self.splitTimes[pathnodeId] = entry

  splitData.time = splitData.time or splitTime
  splitData.source = splitData.source or entry.source
  return entry
end

function C:markSplitMissing(splitData, reason)
  if not splitData or not splitData.isSplitTiming then return end

  local pathnodeId = splitData.pathnodeId
  if not pathnodeId then return end

  if not self.splitTimes[pathnodeId] then
    table.insert(self.splitOrder, pathnodeId)
  end

  local entry = {
    pathnodeId = pathnodeId,
    pathnodeName = splitData.pathnodeName,
    pathnodeType = splitData.pathnodeType,
    splitLabel = splitData.splitLabel,
    missingReason = reason or splitData.missingReason or 'missing',
    source = 'tracker',
  }

  self.splitTimes[pathnodeId] = entry
  splitData.missingReason = entry.missingReason
  return entry
end

function C:getSplitTimes()
  return self.splitTimes
end

function C:getSplitOrder()
  return self.splitOrder
end

function C:isActive()
  return self.active and not self.complete
end

function C:isComplete()
  return self.complete
end

function C:getTime()
  return self.finishTime or self.elapsedTime
end

function C:getFrameStartTime()
  return self.frameStartTime
end

function C:getFrameDt()
  return self.frameDt
end

function C:getState()
  return {
    status = self.status,
    active = self:isActive(),
    complete = self.complete,
    elapsedTime = self.elapsedTime,
    finishTime = self.finishTime,
    frameStartTime = self.frameStartTime,
    frameDt = self.frameDt,
    splitTimes = self.splitTimes,
    splitOrder = self.splitOrder,
  }
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
