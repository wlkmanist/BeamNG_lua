-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local supportedFuelTypes = {
  gasoline = true,
  diesel = true,
}

local function isNumber(value)
  return type(value) == 'number' and value == value
end

local function isValidTankName(name)
  return type(name) == 'string' and name ~= ''
end

local function createFullTankEntry(tank)
  if not tank or not isValidTankName(tank.name) or not isNumber(tank.maxEnergy) then
    return nil
  end

  return {
    name = tank.name,
    maxEnergy = tank.maxEnergy,
  }
end

function M.createFuelSnapshot(energyStorageData)
  local snapshot = {
    mode = 'full',
    tanks = {},
    reason = nil,
  }

  if type(energyStorageData) ~= 'table' then
    snapshot.reason = 'missing energy storage data'
    return snapshot
  end

  local fuelTankCount = 0
  local rememberedTank = nil
  local unsupportedStorage = nil

  for _, tank in ipairs(energyStorageData) do
    local storageType = tank.storageType

    if storageType == 'fuelTank' then
      fuelTankCount = fuelTankCount + 1

      local fullTank = createFullTankEntry(tank)
      if fullTank then
        table.insert(snapshot.tanks, fullTank)
      else
        unsupportedStorage = unsupportedStorage or 'invalid fuel tank'
      end

      if supportedFuelTypes[tank.energyType] and isValidTankName(tank.name) and isNumber(tank.currentEnergy) then
        rememberedTank = {
          name = tank.name,
          currentEnergy = tank.currentEnergy,
        }
      else
        unsupportedStorage = unsupportedStorage or 'unsupported fuel tank'
      end
    elseif storageType == 'electricBattery' then
      unsupportedStorage = unsupportedStorage or 'electric battery'
    elseif storageType and storageType ~= 'n2oTank' then
      unsupportedStorage = unsupportedStorage or tostring(storageType)
    end
  end

  if fuelTankCount == 0 then
    snapshot.reason = unsupportedStorage or 'no fuel tanks'
    return snapshot
  end

  if fuelTankCount ~= 1 then
    snapshot.reason = 'multiple fuel tanks'
    return snapshot
  end

  if unsupportedStorage then
    snapshot.reason = unsupportedStorage
    return snapshot
  end

  if not rememberedTank then
    snapshot.reason = 'unsupported fuel tank'
    return snapshot
  end

  snapshot.mode = 'remembered'
  snapshot.reason = nil
  snapshot.tanks = { rememberedTank }
  return snapshot
end

function M.requestFuelSnapshot(veh, callback)
  if not veh then
    callback(M.createFuelSnapshot(nil))
    return
  end

  core_vehicleBridge.requestValue(veh, function(ret)
    callback(M.createFuelSnapshot(ret and ret[1]))
  end, 'energyStorage')
end

function M.applyFuelSnapshot(veh, snapshot, logTag, reason)
  if not veh or not snapshot then
    return
  end

  local tanks = snapshot.tanks or {}
  if #tanks == 0 then
    return
  end

  if snapshot.mode == 'remembered' then
    for _, tank in ipairs(tanks) do
      core_vehicleBridge.executeAction(veh, 'setEnergyStorageEnergy', tank.name, tank.currentEnergy)
    end
    return
  end

  if snapshot.reason then
    log('W', logTag or '', string.format('fuel restore fallback to full tank during %s: %s', tostring(reason or 'recovery'), tostring(snapshot.reason)))
  end

  for _, tank in ipairs(tanks) do
    core_vehicleBridge.executeAction(veh, 'setEnergyStorageEnergy', tank.name, tank.maxEnergy)
  end
end

return M
