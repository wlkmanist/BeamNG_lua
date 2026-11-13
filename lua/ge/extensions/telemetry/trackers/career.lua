-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY CAREER TRACKER

  Tracks career mode engagement: how long a career is played, the state of the save
  when it is opened, and the vehicles bought and sold.
]]

local M = {}
M.dependencies = {'telemetry_core'}

-- Set while a career runs, so the activity is only closed when one is actually open
local careerRunning = false

local function endCareer()
  if not careerRunning then return end
  careerRunning = false
  extensions.telemetry_core.endActivity("careerActive")
end

local function onCareerActive(active, newSave)
  if not active then
    endCareer()
    return
  end
  if careerRunning then return end
  careerRunning = true

  extensions.telemetry_core.startActivity("careerActive", {
    money = career_modules_playerAttributes.getAttribute("money"),
    beamXP = career_modules_playerAttributes.getAttribute("beamXP"),
    vouchers = career_modules_playerAttributes.getAttribute("vouchers"),
    numberOfVehicles = tableSize(career_modules_inventory.getVehicles()),
    newSave = newSave,
    withTutorial = career_career.tutorialEnabled,
  })
end

local function onVehicleAddedToInventory(data)
  local vehicleData = {}
  if data.vehicleInfo then
    vehicleData.model = data.vehicleInfo.model_key
    vehicleData.name = data.vehicleInfo.Name
  end

  extensions.telemetry_core.addEvent({
    name = "vehicleAddedToInventory",
    vehicleData = vehicleData,
    price = data.purchaseData and data.purchaseData.prices,
  })
end

local function onBeforeVehicleSell(data)
  local vehicle = career_modules_inventory.getVehicles()[data.inventoryId]
  if not vehicle then return end

  extensions.telemetry_core.addEvent({
    name = "vehicleSold",
    vehicleData = {
      model = vehicle.model,
      name = vehicle.niceName,
    },
    price = data.price,
  })
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
end

M.onExtensionLoaded = onExtensionLoaded
-- a lua reload tears the trackers down without an onExit, so close the activity here too
M.onExtensionUnloaded = endCareer

M.onCareerActive = onCareerActive
M.onVehicleAddedToInventory = onVehicleAddedToInventory
M.onBeforeVehicleSell = onBeforeVehicleSell

return M
