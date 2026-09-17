-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

local logTag = 'roadSectionPenaltyKeeper'

-- Penalty configuration (based on real rally liaison route violations)
local RECALC_TIME_WINDOW = 10  -- seconds - window to check for frequent recalculations
local RECALC_THRESHOLD = 5    -- number of recalcs allowed in time window before penalty
local MAX_VIOLATIONS = 1
local PENALTIES = {
  30,   -- 1st violation: 30 seconds
  60,   -- 2nd violation: 1 minute
  120,  -- 3rd violation: 2 minutes
  180   -- 4th+ violation: 3 minutes
}

function C:init(manager)
  self.manager = manager
  -- Track all recalculation timestamps
  self.recalcCount = 0
  -- Track total violations (for escalating penalties)
  self.violationCount = 0
end

function C:reset()
  self.recalcCount = 0
  self.violationCount = 0
end

function C:registerRecalc()
  self.recalcCount = self.recalcCount + 1
end

function C:createPenaltyData()
  -- Create penalty data for the current violation
  -- Called when attaching penalty to TC event

  self.violationCount = self.violationCount + 1
  local penaltyIndex = math.min(self.violationCount, #PENALTIES)
  local penaltyAmount = PENALTIES[penaltyIndex]

  -- Create structured penalty data
  local penaltyData = {
    type = "liaison_deviation",
    amount = penaltyAmount,
    data = {
      violationNumber = self.violationCount,
      recalcCount = self.recalcCount,
    }
  }

  return penaltyData
end

function C:onUpdate()
  local currentTime = self.manager.clock
  if not self.lastCheckTime then
    self.lastCheckTime = currentTime
  end

  local diffTime = currentTime - self.lastCheckTime
  if diffTime < RECALC_TIME_WINDOW then
    return false
  end

  self.lastCheckTime = currentTime

  if self.recalcCount > RECALC_THRESHOLD and self.violationCount < MAX_VIOLATIONS then
    self.manager:recordRouteRecalcPenalty(self:createPenaltyData())
    self.recalcCount = 0
  end
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end


