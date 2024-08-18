-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
C.moduleOrder = 0 -- low first, high later
C.hooks = {'onDriftSpinout', 'onDriftCrash', 'onDonutDriftScore', 'onTightDriftScored', 'onDriftCompletedScored'}
C.dependencies = {'gameplay_drift_general'}

function C:resetModule()
  self.callbacks = {
    tight = {ttl = 0},
    donut = {ttl = 0},
    spinout = {ttl = 0},
    crash = {ttl = 0},
    tap = {ttl = 0},
    scored = {ttl = 0},
  }
end

function C:resetExtension()
  gameplay_drift_general.reset()
end

function C:init()
  self:resetModule()
end

function C:onUpdate()
  for _, callbackData in pairs(self.callbacks) do
    if callbackData.ttl > 0 then
      callbackData.ttl = callbackData.ttl - 1
    end
  end
end


function C:getCallBacks()
  return self.callbacks
end

function C:addCallback(name, data)
  self.callbacks[name] = {
    ttl = 2,
    data = data
  }
end


function C:onDriftSpinout()
  self:addCallback("spinout")
end

function C:onDriftCrash()
  self:addCallback("crash")
end

function C:onTightDriftScored(score)
  self:addCallback("tight", {score = score})
end

function C:onDonutDriftScore(score)
  self:addCallback("donut", {score = score})
end

function C:onDriftCompletedScored(addedScore, cachedScore, combo)
  self:addCallback("scored", {addedScore = addedScore, cachedScore = cachedScore, combo = combo})
end


function C:getScore()
  return gameplay_drift_scoring.getScore()
end

function C:getDriftActiveData()
  return gameplay_drift_drift.getDriftActiveData()
end

function C:getVehId()
  return gameplay_drift_drift.getVehId()
end

function C:setVehId(vehId)
  gameplay_drift_drift.setVehId(vehId)
end

function C:setAllowDonut(value)
  gameplay_drift_drift.setAllowDonut(value)
end

function C:setAllowTightDrift(value)
  gameplay_drift_drift.setAllowTightDrift(value)
end

function C:onDonutZoneReactivated()
  gameplay_drift_drift.onDonutZoneReactivated()
end

return _flowgraph_createModule(C)