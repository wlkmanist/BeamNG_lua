-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"career_career"}

local computerTetherRange = 4 --meter
local tether

local computerFunctions
local computerId
local menuData = {}

local function openMenu(computerFacility)
  computerFunctions = {general = {}, vehicleSpecific = {}}
  computerId = computerFacility.id

  menuData = {vehiclesInGarage = {}}
  local inventoryIds = career_modules_inventory.getInventoryIdsInClosestGarage()

  for _, inventoryId in ipairs(inventoryIds) do
    local vehicleData = {}
    vehicleData.inventoryId = inventoryId
    vehicleData.needsRepair = career_modules_insurance.inventoryVehNeedsRepair(inventoryId) or nil
    local vehicleInfo = career_modules_inventory.getVehicles()[inventoryId]
    vehicleData.vehicleName = vehicleInfo and vehicleInfo.niceName
    table.insert(menuData.vehiclesInGarage, vehicleData)

    computerFunctions.vehicleSpecific[inventoryId] = {}
  end

  menuData.computerFacility = computerFacility
  if not career_modules_linearTutorial.getTutorialFlag("partShoppingComplete") then
    menuData.tutorialPartShoppingActive = true
  elseif not career_modules_linearTutorial.getTutorialFlag("tuningComplete") then
    menuData.tutorialTuningActive = true
  end

  extensions.hook("onComputerAddFunctions", menuData, computerFunctions)

  local computerPos = freeroam_facilities.getAverageDoorPositionForFacility(computerFacility)
  tether = career_modules_tether.startSphereTether(computerPos, computerTetherRange, M.closeMenu)

  guihooks.trigger('ChangeState', {state = 'computer'})
  extensions.hook("onComputerMenuOpened")
end

local function computerButtonCallback(buttonId, inventoryId)
  local functionData
  if inventoryId then
    functionData = computerFunctions.vehicleSpecific[inventoryId][buttonId]
  else
    functionData = computerFunctions.general[buttonId]
  end

  functionData.callback(computerId)
end

local function getComputerUIData()
  local data = {}
  local computerFunctionsForUI = deepcopy(computerFunctions)
  computerFunctionsForUI.vehicleSpecific = {}

  -- convert keys of the table to string, because js doesnt support number keys
  for inventoryId, computerFunction in pairs(computerFunctions.vehicleSpecific) do
    computerFunctionsForUI.vehicleSpecific[tostring(inventoryId)] = computerFunction
  end

  local vehiclesForUI = deepcopy(menuData.vehiclesInGarage)
  for i, vehicleData in ipairs(menuData.vehiclesInGarage) do
    vehiclesForUI[i].inventoryId = tostring(vehicleData.inventoryId)
  end

  data.computerFunctions = computerFunctionsForUI
  data.vehicles = vehiclesForUI
  return data
end

local function onMenuClosed()
  if tether then tether.remove = true tether = nil end
end

local function closeMenu()
  career_career.closeAllMenus()
end

M.openMenu = openMenu
M.onMenuClosed = onMenuClosed
M.closeMenu = closeMenu

M.getComputerUIData = getComputerUIData
M.computerButtonCallback = computerButtonCallback

return M