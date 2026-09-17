-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

local logTag = 'rallyEventLog'

function C:init()
  -- Array of all logged items, ordered by timestamp
  self.items = {}

  -- Map from eventGroup to array of items for that event group
  self.itemsByEventGroup = {}

  self.aggregatedItems = {}
end

function C:addItem(event, timestamp, type, data)
  local eventId = event.eventId or 'unknown'
  local eventGroup = event.eventGroup or 'unknown'

  local item = {
    timestamp = timestamp,
    eventId = eventId,
    eventGroup = eventGroup,
    type = type,
    data = data
  }

  -- Add to main items array
  table.insert(self.items, item)

  -- Add to eventGroup map
  if not self.itemsByEventGroup[eventGroup] then
    self.itemsByEventGroup[eventGroup] = {}
  end
  table.insert(self.itemsByEventGroup[eventGroup], item)

  self:recalculateAggregatedItems()
end

function C:recalculateAggregatedItems()
  self.aggregatedItems = {}
  self.aggregatedItems.totalPenalty = self:_calcTotalPenalty()
  self.aggregatedItems.totalStageTime = self:_calcTotalStageTime()
  self.aggregatedItems.totalTime = self.aggregatedItems.totalStageTime + self.aggregatedItems.totalPenalty
  self.aggregatedItems.penaltySummary = self:_calcPenaltySummary()
end

function C:getItemsByEventGroup(eventGroup)
  return self.itemsByEventGroup[eventGroup] or {}
end

function C:getAllItems()
  return self.items
end

function C:getItemsByType(type)
  local result = {}
  for _, item in ipairs(self.items) do
    if item.type == type then
      table.insert(result, item)
    end
  end
  return result
end

function C:getStageTimes()
  local result = {}
  for _, item in ipairs(self.items) do
    if item.data.stageTimeSecs then
      table.insert(result, item)
    end
  end
  return result
end

function C:getTotalPenalty()
  return self.aggregatedItems.totalPenalty or 0
end

function C:getTotalStageTime()
  return self.aggregatedItems.totalStageTime or 0
end

function C:getTotalTime()
  return self.aggregatedItems.totalTime or 0
end

function C:getPenaltySummary()
  return self.aggregatedItems.penaltySummary or { totalPenalty = 0, groups = {} }
end

function C:_calcTotalPenalty()
  local total = 0
  for _, item in ipairs(self.items) do
    if item.type == 'penalty' and item.data.amount then
      total = total + item.data.amount
    end
  end
  return total
end

function C:_calcTotalStageTime()
  local total = 0
  for _, item in ipairs(self.items) do
    if item.data.stageTimeSecs then
      total = total + item.data.stageTimeSecs
    end
  end
  return total
end

function C:_calcPenaltySummary()
  -- Group penalties by eventGroup, then by penaltyType
  -- Maintains natural order of groups (by first occurrence)
  -- Includes all groups (even empty ones with 0 penalties)
  local groupOrder = {}  -- Array to maintain order of groups
  local groupMap = {}    -- Map from eventGroup to penalty data
  local grandTotal = 0   -- Total penalty across all groups

  -- First pass: collect all groups in order
  for _, item in ipairs(self.items) do
    local eventGroup = item.eventGroup
    if not groupMap[eventGroup] then
      table.insert(groupOrder, eventGroup)
      groupMap[eventGroup] = {
        eventGroup = eventGroup,
        totalPenalty = 0,
        penaltyTypes = {}  -- Map from penaltyType to {count, amount}
      }
    end

    -- Process penalties
    if item.type == 'penalty' and item.data.penaltyType and item.data.amount then
      local penaltyType = item.data.penaltyType
      local amount = item.data.amount

      if not groupMap[eventGroup].penaltyTypes[penaltyType] then
        groupMap[eventGroup].penaltyTypes[penaltyType] = {count = 0, amount = 0}
      end

      groupMap[eventGroup].penaltyTypes[penaltyType].count = groupMap[eventGroup].penaltyTypes[penaltyType].count + 1
      groupMap[eventGroup].penaltyTypes[penaltyType].amount = groupMap[eventGroup].penaltyTypes[penaltyType].amount + amount
      groupMap[eventGroup].totalPenalty = groupMap[eventGroup].totalPenalty + amount
      grandTotal = grandTotal + amount
    end

  end

  -- Build groups array with groups in natural order
  local groups = {}
  for _, eventGroup in ipairs(groupOrder) do
    local groupData = groupMap[eventGroup]

    -- Convert penaltyTypes map to sorted array
    local penalties = {}
    for penaltyType, data in pairs(groupData.penaltyTypes) do
      table.insert(penalties, {
        type = penaltyType,
        count = data.count,
        amount = data.amount
      })
    end

    -- Sort penalties alphabetically by type
    table.sort(penalties, function(a, b)
      return a.type < b.type
    end)

    table.insert(groups, {
      eventGroup = groupData.eventGroup,
      totalPenalty = groupData.totalPenalty,
      penalties = penalties
    })
  end

  return {
    totalPenalty = grandTotal,
    groups = groups
  }
end

function C:clear()
  self.items = {}
  self.itemsByEventGroup = {}
  log('D', logTag, 'Cleared all log items')
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end

