-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local fuelUtils = require('/lua/ge/extensions/gameplay/rally/fuelUtils')

local C = {}
local logTag = 'rally-mode-flowgraph'

C.name = 'Rally Mode Recover In Place'
C.description = 'Recovers the vehicle in place without using pacenotes, route history, or driveline data.'
C.color = rallyUtil.rally_flowgraph_color
C.tags = {'rally', 'recover', 'teleport'}
C.category = 'repeat_p_duration'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'vehId', description = 'Defines the id of the vehicle to move.' },
}

local function getRecoveryRepairVehicle()
  local loopManager = gameplay_rallyLoop and gameplay_rallyLoop.getManager and gameplay_rallyLoop.getManager()
  if loopManager and loopManager.getRecoveryRepairVehicle then
    return loopManager:getRecoveryRepairVehicle()
  end

  if gameplay_rally and gameplay_rally.getRecoveryRepairVehicle then
    return gameplay_rally.getRecoveryRepairVehicle()
  end

  local value = settings and settings.getValue and settings.getValue('rallyRepairVehicleOnRecovery')
  if value ~= nil then
    return value
  end

  return true
end

function C:init()
  self:onNodeReset()
end

function C:_executionStarted()
  self:onNodeReset()
end

function C:_executionStopped()
  self:onNodeReset()
end

function C:onNodeReset()
  self.pendingRecovery = nil
  self.fuelSnapshot = nil
end

function C:runRecovery()
  local pendingRecovery = self.pendingRecovery
  self.pendingRecovery = nil

  if not pendingRecovery then
    return
  end

  local veh = scenetree.findObjectById(pendingRecovery.vehId)
  if not veh then
    log('W', logTag, 'recoverInPlace failed, vehicle not found')
    return
  end

  log('I', logTag, string.format('recoverInPlace vehId=%s resetVehicle=%s', tostring(veh:getID()), tostring(pendingRecovery.resetVehicle)))
  spawn.safeTeleport(veh, pendingRecovery.pos, pendingRecovery.rot, nil, nil, nil, true, pendingRecovery.resetVehicle)

  if pendingRecovery.resetVehicle then
    fuelUtils.applyFuelSnapshot(veh, self.fuelSnapshot, logTag, 'recoverInPlace')
  end

  extensions.hook('onVehicleTeleportedToLastRoad', veh:getID())
  extensions.hook('onRallyRouteRecoveryComplete', {
    vehId = veh:getID(),
    repairVehicle = pendingRecovery.resetVehicle,
    inPlace = true,
  })
end

function C:startRecovery()
  if self.pendingRecovery then
    return
  end

  self.fuelSnapshot = nil

  local veh
  if self.pinIn.vehId.value then
    veh = scenetree.findObjectById(self.pinIn.vehId.value)
  else
    veh = getPlayerVehicle(0)
  end

  if not veh then
    log('W', logTag, 'recoverInPlace failed, vehicle not found')
    return
  end

  local resetVehicle = getRecoveryRepairVehicle()
  self.pendingRecovery = {
    vehId = veh:getID(),
    pos = vec3(veh:getPosition()),
    rot = quatFromDir(veh:getDirectionVector(), veh:getDirectionVectorUp()),
    resetVehicle = resetVehicle,
  }

  if resetVehicle then
    fuelUtils.requestFuelSnapshot(veh, function(snapshot)
      self.fuelSnapshot = snapshot
      if self.pendingRecovery then
        self:runRecovery()
      end
    end)
    return
  end

  self:runRecovery()
end

function C:work()
  if self.pinIn.flow.value then
    self:startRecovery()
  end
end

return _flowgraph_createNode(C)
