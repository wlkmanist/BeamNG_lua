-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local SETTINGS_ROUTES = {
  ["pause.multiseatSettings"] = true,
  ["pause.multiseatSettings.vehicleSelector"] = true,
}

local function confirmMultiseatSettingsExit(route, params, context)
  local routeName = type(context) == "table" and context.routeName or route and route.name
  -- moving between the settings screen and the vehicle selector stays inside the flow
  if SETTINGS_ROUTES[routeName] then
    return true
  end

  if not ui_multiseat_multiseatSettings then
    return true
  end

  return ui_multiseat_multiseatSettings.confirmExit(route, params, context)
end

M.guards = {
  confirmMultiseatSettingsExit = confirmMultiseatSettingsExit,
}

return M
