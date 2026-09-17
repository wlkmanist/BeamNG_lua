-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function mockVehicle(id)
  return {
    getID = function() return id or 0 end,
    queueLuaCommand = function() end,
  }
end

-- Default hooks
function M.generateMockData_onUpdate()
  extensions.hook("onUpdate", 0.016, 0.016, 0.016)
end

function M.generateMockData_updateGFX()
  extensions.hook("updateGFX", 0.016)
end

function M.generateMockData_onPhysicsStep()
  extensions.hook("onPhysicsStep", 0.001)
end

function M.generateMockData_onSerialize()
  extensions.hook("onSerialize", "extensionTest")
end

function M.generateMockData_onDeserialize()
  extensions.hook("onDeserialize", {})
end

function M.generateMockData_onDeserialized()
  extensions.hook("onDeserialized", {})
end

function M.generateMockData_onExtensionLoaded()
  extensions.hook("onExtensionLoaded")
end

function M.generateMockData_onExtensionUnloaded()
  extensions.hook("onExtensionUnloaded")
end

function M.generateMockData_default(hookName)
  extensions.hook(hookName)
end

-- Vehicle hooks
function M.generateMockData_onVehicleSwitched()
  extensions.hook("onVehicleSwitched", 0, 0)
  extensions.hook("onVehicleSwitched", 0, 1)
  extensions.hook("onVehicleSwitched", 1, 0)
end

function M.generateMockData_onVehicleResetted()
  extensions.hook("onVehicleResetted", 0)
  extensions.hook("onVehicleResetted", 1)
end

function M.generateMockData_onVehicleDestroyed()
  extensions.hook("onVehicleDestroyed", 0)
  extensions.hook("onVehicleDestroyed", 1)
end

function M.generateMockData_onVehicleSpawned()
  extensions.hook("onVehicleSpawned", 0, mockVehicle(0))
  extensions.hook("onVehicleSpawned", 1, mockVehicle(1))
end

function M.generateMockData_onVehicleActiveChanged()
  extensions.hook("onVehicleActiveChanged", 0, true)
  extensions.hook("onVehicleActiveChanged", 0, false)
end

function M.generateMockData_onVehicleMapmgrUpdate()
  extensions.hook("onVehicleMapmgrUpdate", 0)
end

function M.generateMockData_onVehicleGroupSpawned()
  extensions.hook("onVehicleGroupSpawned", {0, 1}, 1, "groupA")
end

function M.generateMockData_onVehicleParkingStatus()
  extensions.hook("onVehicleParkingStatus", 0, {state = "parked", score = 1})
end

function M.generateMockData_onVehicleEditorRenderJBeams()
  extensions.hook("onVehicleEditorRenderJBeams", 0.016, 0.016, 0.016)
end

function M.generateMockData_onVehicleLoaded()
  extensions.hook("onVehicleLoaded", false)
  extensions.hook("onVehicleLoaded", true)
end

function M.generateMockData_onVehicleReset()
  extensions.hook("onVehicleReset", false)
  extensions.hook("onVehicleReset", true)
end

function M.generateMockData_onVehicleTileClick()
  extensions.hook("onVehicleTileClick")
end

function M.generateMockData_onVehicleInfoReady()
  extensions.hook("onVehicleInfoReady", 0, {name = "vehicle", speed = 0})
end

function M.generateMockData_onVehicleConnectionReady()
  extensions.hook("onVehicleConnectionReady", 0, 64256)
end

function M.generateMockData_onVehicleSelectorSpawnNew()
  extensions.hook("onVehicleSelectorSpawnNew", "pickup", "base", "paint1", "paint2", "paint3")
end

function M.generateMockData_onVehicleSelectorReplaceCurrent()
  extensions.hook("onVehicleSelectorReplaceCurrent", "pickup", "base", "paint1", "paint2", "paint3")
end

function M.generateMockData_onVehicleSelectorSetAsDefault()
  extensions.hook("onVehicleSelectorSetAsDefault")
end

function M.generateMockData_onVehicleSelectorLoadDefault()
  extensions.hook("onVehicleSelectorLoadDefault")
end

function M.generateMockData_onVehicleSelectorCloneCurrent()
  extensions.hook("onVehicleSelectorCloneCurrent")
end

function M.generateMockData_onVehicleSelectorSelectRandom()
  extensions.hook("onVehicleSelectorSelectRandom")
end

function M.generateMockData_onVehicleSelectorResetAll()
  extensions.hook("onVehicleSelectorResetAll")
end

function M.generateMockData_onVehicleSelectorRemoveAll()
  extensions.hook("onVehicleSelectorRemoveAll")
end

function M.generateMockData_onVehicleSelectorRemoveCurrent()
  extensions.hook("onVehicleSelectorRemoveCurrent")
end

function M.generateMockData_onVehicleSelectorRemoveOthers()
  extensions.hook("onVehicleSelectorRemoveOthers")
end

function M.generateMockData_onVehicleReplaced()
  extensions.hook("onVehicleReplaced", 0)
end

function M.generateMockData_onVehiclePoolRemoved()
  extensions.hook("onVehiclePoolRemoved", 0)
end

function M.generateMockData_onVehiclePoolAdded()
  extensions.hook("onVehiclePoolAdded", 0)
end

function M.generateMockData_onVehicleColorChanged()
  extensions.hook("onVehicleColorChanged", 0, 0, {baseColor = {1, 1, 1, 1}})
end

function M.generateMockData_onVehicleFlippedUpright()
  extensions.hook("onVehicleFlippedUpright", 0)
end

function M.generateMockData_onVehicleSpawnFinished()
  extensions.hook("onVehicleSpawnFinished", 0)
end

function M.generateMockData_onVehicleShoppingMenuOpened()
  extensions.hook("onVehicleShoppingMenuOpened", {seller = "dealer"})
end

function M.generateMockData_onVehicleShoppingMenuClosed()
  extensions.hook("onVehicleShoppingMenuClosed", {})
end

function M.generateMockData_onVehicleAddedToInventory()
  extensions.hook("onVehicleAddedToInventory", {inventoryId = 1, vehicleInfo = {id = 1}})
end

function M.generateMockData_onVehicleShoppingVehicleShown()
  extensions.hook("onVehicleShoppingVehicleShown", {vehicleInfo = {id = 1}})
end

function M.generateMockData_onVehicleShoppingPurchaseMenuOpened()
  extensions.hook("onVehicleShoppingPurchaseMenuOpened", {purchaseType = "cash", shopId = "shopA"})
end

function M.generateMockData_onVehicleDamaged()
  extensions.hook("onVehicleDamaged", {damage = 0.1}, {damage = 0.01})
end

function M.generateMockData_onVehicleSaveFinished()
  extensions.hook("onVehicleSaveFinished", "/vehicles/car.pc", 0)
  extensions.hook("onVehicleSaveFinished")
end

function M.generateMockData_onVehicleAdded()
  extensions.hook("onVehicleAdded", 1)
end

function M.generateMockData_onVehicleRemoved()
  extensions.hook("onVehicleRemoved", 1)
end

function M.generateMockData_onVehiclePaintingUiOpened()
  extensions.hook("onVehiclePaintingUiOpened")
end

function M.generateMockData_onVehicleBought()
  extensions.hook("onVehicleBought")
end

function M.generateMockData_onVehicleRemovedFromInventory()
  extensions.hook("onVehicleRemovedFromInventory", 1)
end

function M.generateMockData_onVehicleCameraConfigChanged()
  extensions.hook("onVehicleCameraConfigChanged")
end

return M
