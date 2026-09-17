-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local TransitionManager = require("ge/extensions/ui/router/managers/transitionManager")

local M = {}

M.logNavigationGuard = function(lifecycleName, context)
  log("D", "Guards", "Navigation: " .. context.to.name)
  return {
    result = true,
    context = context
  }
end

M.handleTimeoutGuard = function(lifecycleName, context)
  local isTimeoutReached = TransitionManager.isTimeoutReached()

  if isTimeoutReached then
    log("D", "Guards", "Transition timeout reached")
    context.reason = "timeout_reached"
    return {
      result = false,
      context = context
    }
  end

  return {
    result = true,
    context = context
  }
end

M.handleTransitionStateGuard = function(lifecycleName, context)
  if not TransitionManager.isTransitioning() then
    return {
      result = true,
      context = context
    }
  end

  if context.settings.force then
    log("D", "Guards", "Force navigation is enabled, allowing to continue with the current transition")
    return {
      result = true,
      context = context
    }
  end

  context.reason = "transition_in_progress"
  return { result = false, context = context }
end

return M
