-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local Utils = require("ge/extensions/ui/router/utils")

local function sanitizeError(err)
  if type(err) == "string" and err ~= "" then
    return err
  end
  return "unknown_error"
end

local function resolveHook(route, hookName)
  if not route then
    return nil, nil, nil
  end

  local hook = route[hookName]
  if hook == nil then
    return nil, nil, nil
  end

  local routeName = route.name and tostring(route.name) or "<unnamed>"
  local label = string.format("Lifecycle hook %s on route %s", tostring(hookName), routeName)
  return Utils.resolveFunctionReference(hook, label)
end

local function runLifecycleHook(route, hookName, context, toRoute, fromRoute, data)
  local hook, err, isHard = resolveHook(route, hookName)

  if err then
    log("E", "Router", err)
    return false, sanitizeError(err), isHard
  end

  if not hook then
    return true, nil, false
  end

  local ok, execErr = pcall(hook, context, toRoute, fromRoute, data)
  if not ok then
    log("E", "Router", string.format("Lifecycle hook %s failed for route %s: %s", hookName, tostring(route.name), tostring(execErr)))
    return false, sanitizeError(execErr), false
  end

  return true, nil, false
end

M.sanitizeError = sanitizeError
M.resolveHook = resolveHook
M.runLifecycleHook = runLifecycleHook

return M
