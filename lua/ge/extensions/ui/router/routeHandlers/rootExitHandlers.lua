-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local NavigationState = require("ge/extensions/ui/router/navigationState")
local M = {}

M.garageExitHandler = function()
  local currentResolved = NavigationState.getCurrentResolved()
  if not currentResolved then
    ui_router.navigate("menu")
    return true
  end

  local currentRouteName = currentResolved.resolved.name
  if currentRouteName == "menu" then
    ui_router.navigate("garage")
    return true
  else
    ui_router.navigate("menu")
  end
end

return M