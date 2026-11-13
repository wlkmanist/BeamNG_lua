-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

function C:init()
  self.personalityModifiers = {
    aggression = {offset = 0.2}
  }
  self.actions = {
    watchPolice = function ()
      self.state = 'wanted'
      self.flags.flee = nil
    end,
    fleePolice = function ()
      if self.veh.isAi then
        self.veh:setAiMode('flee')
        local obj = getObjectByID(self.veh.id)
        obj:queueLuaCommand('controller.setFreeze(0)')
        obj:queueLuaCommand('ai.setAggressionMode("off")')
        obj:queueLuaCommand('ai.driveInLane("off")')
        obj:queueLuaCommand('ai.setSpeedMode("off")')
        self:setAggression(0.8)
      end
      self.veh:modifyRespawnValues(800, 40) -- this strongly keeps the vehicle from respawning
      self.state = 'flee'
      self.flags.flee = 1
      self.flags.busy = 1
    end,
    arrest = function ()
      getObjectByID(self.veh.id):queueLuaCommand('controller.setFreeze(1)')
      self.flags.freeze = 1
      self.state = 'stop'
    end,
    clear = function ()
      getObjectByID(self.veh.id):queueLuaCommand('controller.setFreeze(0)')
      self.flags.freeze = nil
      self.flags.flee = nil
      self.flags.busy = nil
      self.state = 'none'
    end
  }

  self.pursuitMode = 2 -- default pursuit mode
end

function C:onRoleEnded()
  if self.flags.flee then
    gameplay_police.evadeVehicle(self.veh.id, gameplay_traffic.showMessages)
    self.flags.flee = nil
  end
end

function C:onActiveDone()
  if self.flags.flee then
    gameplay_police.evadeVehicle(self.veh.id, gameplay_traffic.showMessages)
    self.flags.flee = nil
  end
end

function C:onTrafficTick(tickTime)
  local sightThreshold = self.veh.isAi and 0.25 or 1 -- minimum pursuit start sight value
  local speedThreshold = self.flags.driveCheck and 1 or 0 -- minimum pursuit start speed
  if self.state == 'wanted' and self.veh.pursuit.sightValue >= sightThreshold and self.veh.speed >= speedThreshold then
    local policeIds = {}
    for id, veh in pairs(self.veh.getPolice()) do
      if not veh.role.flags.pursuit and not veh.role.flags.reset then -- only available police vehicles
        table.insert(policeIds, id)
      end
    end

    if policeIds[1] then
      gameplay_police.setPursuitMode(self.pursuitMode, self.veh.id, policeIds) -- police start chasing the wanted suspect
      local bestId = gameplay_police.getNearestPoliceVehicle(self.veh.id, true, true)
      self:setTarget(bestId or policeIds[1])
    end
  end
end

function C:onUpdate(dt, dtSim)
end

return function(...) return require('/lua/ge/extensions/gameplay/traffic/baseRole')(C, ...) end