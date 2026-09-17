-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function isCurrentPhotomodeRoute(routeName)
  if type(routeName) ~= "string" then
    return false
  end

  local profile = ui_photomode_shared
    and ui_photomode_shared.S
    and ui_photomode_shared.S.activeProfile
    or "pause"
  local photomodeRouteName = tostring(profile) .. ".photomode"
  return routeName == photomodeRouteName
    or string.sub(routeName, 1, #photomodeRouteName + 1) == photomodeRouteName .. "."
end

local function confirmPhotomodeExit(route, params, context)
  local routeName = type(context) == "table" and context.routeName or route and route.name
  if isCurrentPhotomodeRoute(routeName) then
    return true
  end

  if not ui_photomode_session or not ui_photomode_session.isPhotomodeSessionActive() then
    return true
  end

  if ui_photomode_session.isPersistentSessionEnabled() then
    return true
  end

  if ui_photomode_session.consumeExitConfirmationBypass() then
    return true
  end

  ui_photomode_session.requestExitConfirmation(route, params, context)
  return false
end

M.guards = {
  confirmPhotomodeExit = confirmPhotomodeExit,
}

return M
