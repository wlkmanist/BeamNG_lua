-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local fuelUtils = require('/lua/ge/extensions/gameplay/rally/fuelUtils')

local C = {}
local logTag = 'rally-mode-flowgraph'

C.name = 'Rally Mode Recover To Route Departure'
C.description = 'Recovers the vehicle to the last tracked route-departure recovery point.'
C.color = rallyUtil.rally_flowgraph_color
C.tags = {'rally', 'recover', 'teleport'}
C.category = 'repeat_p_duration'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'vehId', description = 'Defines the id of the vehicle to move.' },
  { dir = 'in', type = 'number', name = 'backoffDistance', description = 'Distance before the tracked recovery point, along the static driveline.' },
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

  local rm = gameplay_rally and gameplay_rally.getRallyManager and gameplay_rally.getRallyManager()
  if not rm then
    log('E', logTag, 'recoverToRouteDeparture failed, rallyManager not found')
    return
  end

  local veh = scenetree.findObjectById(pendingRecovery.vehId)
  if not veh then
    log('W', logTag, 'recoverToRouteDeparture failed, vehicle not found')
    return
  end

  log('I', logTag, string.format('recoverToRouteDeparture vehId=%s repairVehicle=%s', tostring(veh:getID()), tostring(pendingRecovery.repairVehicle)))
  local ok, reason = rm:recoverVehicleToRouteDeparture(veh, {
    repairVehicle = pendingRecovery.repairVehicle,
    backoffDistance = pendingRecovery.backoffDistance,
  })
  if not ok then
    log('W', logTag, 'recoverToRouteDeparture failed: '..tostring(reason))
  end

  if ok and pendingRecovery.repairVehicle then
    fuelUtils.applyFuelSnapshot(veh, self.fuelSnapshot, logTag, 'recoverToRouteDeparture')
  end
end

function C:startRecovery()
  if self.pendingRecovery then
    return
  end

  self.fuelSnapshot = nil

  local rm = gameplay_rally and gameplay_rally.getRallyManager and gameplay_rally.getRallyManager()
  if not rm then
    log('E', logTag, 'recoverToRouteDeparture failed, rallyManager not found')
    return
  end

  local veh
  if self.pinIn.vehId.value then
    veh = scenetree.findObjectById(self.pinIn.vehId.value)
  else
    veh = getPlayerVehicle(0)
  end

  if not veh then
    log('W', logTag, 'recoverToRouteDeparture failed, vehicle not found')
    return
  end

  local repairVehicle = getRecoveryRepairVehicle()
  self.pendingRecovery = {
    vehId = veh:getID(),
    repairVehicle = repairVehicle,
    backoffDistance = self.pinIn.backoffDistance.value,
  }

  if repairVehicle then
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
