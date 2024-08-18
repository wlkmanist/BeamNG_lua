-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"career_career"}

local inventoryId
local vehicleTransform

local originComputerId

local function getTuningData()
  local vehId = career_modules_inventory.getMapInventoryIdToVehId()[inventoryId]
  if not vehId then return end
  local vehData = core_vehicle_manager.getVehicleData(vehId)
  return vehData.vdata.variables
end

local function initVehicle(_inventoryId)

end

local function startActual(_originComputerId)
  originComputerId = _originComputerId
  if originComputerId then
    guihooks.trigger('ChangeState', {state = 'tuning', params = {}})
    extensions.hook("onCareerTuningStarted")
  end
end

local function start(_inventoryId, _originComputerId)
  inventoryId = _inventoryId or career_modules_inventory.getInventoryIdsInClosestGarage(true)
  if not inventoryId or not career_modules_inventory.getMapInventoryIdToVehId()[inventoryId] then return end

  local numberOfBrokenParts = career_modules_insurance.getNumberOfBrokenParts(career_modules_inventory.getVehicles()[inventoryId].partConditions)
  if numberOfBrokenParts > 0 and numberOfBrokenParts < career_modules_insurance.getBrokenPartsThreshold() then
    career_modules_insurance.startRepair(inventoryId, nil, function() startActual(_originComputerId) end)
  else
    startActual(_originComputerId)
  end
end

local function onVehicleReplaced(vehId)
  local veh = be:getObjectByID(vehId)
  spawn.safeTeleport(veh, vehicleTransform.pos, vehicleTransform.rot)
  M.onVehicleReplaced = nil
end

local function apply(tuningValues)
  local vehId = career_modules_inventory.getMapInventoryIdToVehId()[inventoryId]
  local oldVeh = be:getObjectByID(vehId)
  vehicleTransform = {pos = oldVeh:getPosition(), rot = quat(0,0,1,0) * quat(oldVeh:getRefNodeRotation())}
  M.onVehicleReplaced = onVehicleReplaced

  -- add the new tuning values to the existing vars and then reload the vehicle by entering again
  local vehicleVarsBefore = career_modules_inventory.getVehicles()[inventoryId].config.vars or {}
  career_modules_inventory.getVehicles()[inventoryId].config.vars = tableMerge(vehicleVarsBefore, tuningValues)
  career_modules_inventory.setVehicleDirty(inventoryId)
  career_modules_inventory.spawnVehicle(inventoryId, 2, career_career.isAutosaveEnabled() and career_saveSystem.saveCurrent)

  extensions.hook("onCareerTuningApplied")
end

local function close()
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
end

local function onMenuClosed()

end

local function onComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["tuning"] then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
    local inventoryId = vehicleData.inventoryId
    local permissionStatus, permissionLabel = career_modules_permissions.getStatusForTag("vehicleModification")

    local buttonDisabled =
      vehicleData.needsRepair or
      menuData.tutorialPartShoppingActive or
      permissionStatus == "forbidden"

    local label = "Tuning" ..(permissionLabel and ("\n"..permissionLabel) or "")

    local computerFunctionData = {
      id = "tuning",
      label = label,
      callback = function() start(nil, menuData.computerFacility.id) end,
      disabled = buttonDisabled
    }
    if vehicleData.needsRepair then
      computerFunctionData.disableReason = "fix vehicle body first"
    end

    computerFunctions.vehicleSpecific[inventoryId][computerFunctionData.id] = computerFunctionData
  end
end

M.start = start
M.initVehicle = initVehicle
M.apply = apply
M.getTuningData = getTuningData
M.close = close

M.onMenuClosed = onMenuClosed
M.onComputerAddFunctions = onComputerAddFunctions

return M