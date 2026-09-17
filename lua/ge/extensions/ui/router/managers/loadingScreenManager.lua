-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
--[[
  LoadingScreenManager

  Wraps core_gamestate loading screen functions for router transitions.
  Uses the tag-based system where loading screen stays visible until
  all requesting modules call exit.
]] local Config = require("ge/extensions/ui/router/config")

local M = {}

-- Tag used for router loading screen requests
local ROUTER_TAG = "router_transition"

local state = {
  active = false,
  autoHide = true,
  autoHideTime = nil,
  autoHideTimer = 0
}

--[[
  Determine if loading screen should show for this navigation.
  Priority: callOptions > routeConfig > globalConfig

  @param route - The resolved route
  @param callOptions - Options passed to push/replace/etc
  @return boolean
]]
M.shouldShow = function(route, callOptions)
  local options = callOptions and callOptions.loadingScreen or {}
  local routeConfig = route and route.loadingScreen or {}

  -- Call options take highest priority
  if options.show ~= nil then
    return options.show
  end

  -- Route config takes next priority
  if routeConfig.show ~= nil then
    return routeConfig.show
  end

  -- Fall back to global config
  return Config.LoadingScreen.show
end

--[[
  Show the loading screen.

  @param transitionContext - The transition context { toRoute, fromRoute, kind }
  @param options - Display options { autoHide, onReady }
]]
M.show = function(transitionContext, options)
  options = options or {}
  state.autoHide = options.autoHide or Config.LoadingScreen.autoHideOnComplete
  state.autoHideTime = options.autoHideTime or nil
  state.active = true

  -- Debug: check gamestate before calling
  guihooks.trigger("LoadingScreen", {
    active = true
  })
end

--[[
  Hide the loading screen.
]]
M.hide = function()
  if not state.active then
    return
  end

  state.active = false
  state.autoHideTimer = 0
  state.autoHideTime = nil

  guihooks.trigger("LoadingScreen", {
    active = false
  })
end

--[[
  Check if loading screen should auto-hide on route complete.

  @return boolean
]]
M.shouldAutoHide = function()
  return state.active and state.autoHide
end

M.getAutoHideTime = function()
  return state.autoHideTime
end

--[[
  Check if router loading screen is currently active.

  @return boolean
]]
M.isActive = function()
  return state.active
end

--[[
  Get the router tag used for loading screen requests.

  @return string
]]
M.getTag = function()
  return ROUTER_TAG
end

M.canUpdate = function()
  return state.active and state.autoHide
end

M.update = function(dtReal)
  if state.active and state.autoHide and state.autoHideTime ~= nil then
    state.autoHideTimer = state.autoHideTimer + dtReal
    if state.autoHideTimer >= (state.autoHideTime or 0) then
      M.hide()
    end
  end
end

return M
