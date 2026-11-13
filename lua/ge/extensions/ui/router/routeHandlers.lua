-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local NavigationState = require("ge/extensions/ui/router/navigationState")

local routeHandlers = {
  firstDriveLockedHandler = function()
    return { result = false, success = false, reason = "first_drive_locked" }
  end,
  previousRouteBackHandler = function()
    local previousEntry = NavigationState.getPreviousEntry()
    if previousEntry and previousEntry.request and previousEntry.request.name then
      return extensions.ui_router.navigate(previousEntry.request.name, previousEntry.request.params or {}, {restoreLastScope = true})
    end
    return extensions.ui_router.navigate("menu")
  end,
  garageExitHandler = extensions.ui_router_routeHandlers_rootExitHandlers.garageExitHandler,
  mainmenuExitHandler = extensions.ui_router_routeHandlers_mainMenuExitHandlers.mainmenuExitHandler,
  missionDetailsExitHandler = extensions.ui_router_routeHandlers_missionExitHandlers.missionDetailsExitHandler,
  pauseExitHandler = extensions.ui_router_routeHandlers_missionExitHandlers.pauseExitHandler,
  vehicleConfigurationBackHandler = function(...) return extensions.ui_pause_vehicleConfigurationGuard.navigateBack(...) end,
  missionVehicleSelectorBackHandler = extensions.ui_router_routeHandlers_missionExitHandlers.missionVehicleSelectorBackHandler,
  careerProfilesExitHandler = extensions.ui_router_routeHandlers_careerExitHandlers.careerProfilesExitHandler,
  careerBranchPageBackHandler = extensions.ui_router_routeHandlers_careerExitHandlers.careerBranchPageBackHandler,
  radialBackHandler = extensions.ui_router_routeHandlers_radialExitHandlers.radialBackHandler,
  partShoppingExitHandler = function(...) return extensions.career_modules_partShopping.requestExit(...) end,
  partInventoryExitHandler = function(...) return extensions.career_modules_partInventory.requestExit(...) end,
  vehicleShoppingExitHandler = function(...) return extensions.career_modules_vehicleShopping.requestExit(...) end,
  vehicleShoppingVehicleListExitHandler = function(...) return extensions.career_modules_vehicleShopping.requestVehicleListExit(...) end,
  vehiclePurchaseExitHandler = function(...) return extensions.career_modules_vehicleShopping.requestPurchaseExit(...) end,
  negotiationExitHandler = extensions.ui_router_routeHandlers_careerExitHandlers.negotiationExitHandler,
  vehicleInventoryExitHandler = function(...) return extensions.career_modules_inventory.requestPickerExit(...) end,
}

M.getHandler = function(handlerName)
  return routeHandlers[handlerName]
end

return M