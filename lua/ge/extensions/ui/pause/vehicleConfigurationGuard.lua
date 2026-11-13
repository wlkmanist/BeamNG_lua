-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local hasPendingChanges = false
local pendingExitNavigation = nil
local exitConfirmationBypass = false

local SUB_ROUTES = {
  ["pause.vehicle.configurationcombined.save"] = true,
  ["pause.vehicle.configurationcombined.configlistmanage"] = true,
  ["pause.vehicle.configurationcombined.mirrors"] = true,
}

function M.setHasPendingChanges(value)
  hasPendingChanges = value == true
end

function M.navigateBack()
  local returnRoute = "pause.vehicle"
  if extensions.core_vehicle_configTarget then
    returnRoute = extensions.core_vehicle_configTarget.getReturnRoute()
  end
  return extensions.ui_router.navigate(returnRoute, nil, {restoreLastScope = true})
end

local function resumePendingExit()
  local pending = pendingExitNavigation
  pendingExitNavigation = nil
  if type(pending) ~= "table" then return false end
  exitConfirmationBypass = true
  local result = extensions.ui_router.navigate(pending.routeName, pending.params, pending.options)
  exitConfirmationBypass = false
  return result
end

function M.confirmExit(route, params, context)
  if exitConfirmationBypass then
    exitConfirmationBypass = false
    return true
  end
  if not hasPendingChanges then return true end

  context = type(context) == "table" and context or {}
  local routeName = context.routeName or (type(route) == "table" and route.name)
  if type(routeName) ~= "string" or routeName == "" then return true end
  if SUB_ROUTES[routeName] then return true end

  -- always refresh the target and re-request: if the previous dialog was dismissed without a
  -- callback, a stale pending target would otherwise block navigation forever. The UI dedupes
  -- identical dialogs, so no second popup can stack up.
  pendingExitNavigation = {
    routeName = routeName,
    params = params,
    options = context.options,
  }

  guihooks.trigger("showConfirmationDialog", {
    title = "ui.vehicleconfig.unsavedChanges.title",
    text = "ui.vehicleconfig.unsavedChanges.message",
    buttons = {
      {
        label = "ui.common.cancel",
        luaCallback = "ui_pause_vehicleConfigurationGuard.cancelExit()",
        isCancel = true,
      },
      {
        label = "ui.hudApps.saveChanges.discard",
        luaCallback = "ui_pause_vehicleConfigurationGuard.confirmExitDiscarding()",
      },
      {
        label = "ui.common.apply",
        luaCallback = "ui_pause_vehicleConfigurationGuard.confirmExitApplying()",
        default = true,
      },
    },
  })
  return false
end

function M.cancelExit()
  pendingExitNavigation = nil
end

-- Unapplied changes only ever existed in the UI, so leaving the screen is the discard
function M.confirmExitDiscarding()
  return resumePendingExit()
end

-- The pending parts tree and tuning values live in the UI, so it applies them and
-- then calls back into resumePendingExit()
function M.confirmExitApplying()
  guihooks.trigger("VehicleConfigurationCombinedApplyAndExit")
end

function M.resumePendingExit()
  return resumePendingExit()
end

return M
