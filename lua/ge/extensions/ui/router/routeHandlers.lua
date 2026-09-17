-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

local routeHandlers = {
  garageExitHandler = extensions.ui_router_routeHandlers_rootExitHandlers.garageExitHandler,
  mainmenuExitHandler = extensions.ui_router_routeHandlers_mainMenuExitHandlers.mainmenuExitHandler,
  missionDetailsExitHandler = extensions.ui_router_routeHandlers_missionExitHandlers.missionDetailsExitHandler,
  pauseExitHandler = extensions.ui_router_routeHandlers_missionExitHandlers.pauseExitHandler,
  missionVehicleSelectorBackHandler = extensions.ui_router_routeHandlers_missionExitHandlers.missionVehicleSelectorBackHandler,
  careerProfilesExitHandler = extensions.ui_router_routeHandlers_careerExitHandlers.careerProfilesExitHandler,
  careerBranchPageBackHandler = extensions.ui_router_routeHandlers_careerExitHandlers.careerBranchPageBackHandler,
  radialBackHandler = extensions.ui_router_routeHandlers_radialExitHandlers.radialBackHandler,
  partShoppingExitHandler = function(...) return extensions.career_modules_partShopping.requestExit(...) end,
  partInventoryExitHandler = function(...) return extensions.career_modules_partInventory.requestExit(...) end,
  vehicleShoppingExitHandler = function(...) return extensions.career_modules_vehicleShopping.requestExit(...) end,
  vehicleShoppingVehicleListExitHandler = function(...) return extensions.career_modules_vehicleShopping.requestVehicleListExit(...) end,
  vehiclePurchaseExitHandler = function(...) return extensions.career_modules_vehicleShopping.requestPurchaseExit(...) end,
  vehicleInventoryExitHandler = function(...) return extensions.career_modules_inventory.requestPickerExit(...) end,
}

M.getHandler = function(handlerName)
  return routeHandlers[handlerName]
end

return M