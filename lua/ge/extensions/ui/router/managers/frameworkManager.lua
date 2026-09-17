-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  FrameworkManager

  Outbound guihook bridge from the Lua router to the UI frameworks. It emits the
  route-change lifecycle events (start / complete / cancelled) and holds no state.

  Active transition state, progress, timeouts, and acknowledgement validation live
  in transitionManager.lua and router.lua; this module only forwards events.
]]

local Constants = require("ge/extensions/ui/router/constants")

local M = {}

--[[
  Emit a route-change event to the UI frameworks.

  @param data - Route-change payload (a NavigationEntry). Treated as immutable.
  @param transitionId - Optional active transition id to attach to the payload.

  When a transition id is supplied, a shallow copy of the payload is emitted with
  transitionId added, so the immutable NavigationEntry table is never mutated.
  Existing top-level fields (request, resolved, origin, toRoute, fromRoute, routeNode)
  are preserved so current UI handlers keep reading data.resolved / data.request.
]]
M.sendRouteChange = function(data, transitionId)
  local payload = data
  if transitionId ~= nil and type(data) == "table" then
    payload = {}
    for key, value in pairs(data) do
      payload[key] = value
    end
    payload.transitionId = transitionId
  end
  guihooks.trigger("ui_router_routeChange", payload)
end

M.sendRouteChangeComplete = function(data)
  guihooks.trigger("ui_router_" .. Constants.RouterHooks.AFTER_ROUTE_CHANGE, data)
end

M.sendRouteChangeCancelled = function(data)
  guihooks.trigger("ui_router_" .. Constants.RouterHooks.ROUTE_CHANGE_CANCELLED, data)
end

return M
