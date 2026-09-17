-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local guards = {}
local guardsDir = "/lua/ge/extensions/ui/router/guards/"
local guardsRequirePrefix = "ge/extensions/ui/router/guards/"

M.reloadGuards = function()
  guards = {}
  local luaFiles = FS:findFiles(guardsDir, "*.lua", 0, false, false)
  for _, file in ipairs(luaFiles) do
    local _, fn, _ = path.split(file)
    local name = string.sub(fn, 1, -5)
    local mod = require(guardsRequirePrefix .. name)
    if type(mod.guards) == "table" then
      for key, fn in pairs(mod.guards) do
        if type(fn) == "function" then
          guards[key] = fn
        end
      end
    end
  end
end

M.addGuard = function(key, fn)
  if guards[key] then
    log("W", "", "Guard " .. key .. " already exists")
    return
  end
  guards[key] = fn
end

M.updateGuard = function(key, fn)
  if not guards[key] then
    log("W", "", "Guard " .. key .. " not found")
    return
  end
  guards[key] = fn
end

M.removeGuard = function(key)
  guards[key] = nil
end

M.executeGuards = function(specifiedGuards, route, params, context)
  local result = { result = true }

  for _, specifiedGuard in ipairs(specifiedGuards) do
    local guard = guards[specifiedGuard]
    if guard then
      result.result = guard(route, params, context)
      if result.result == false then
        result.failedGuard = specifiedGuard
        return result
      end
    else
      log("W", "", "Guard " .. specifiedGuard .. " not found. Ignoring.")
    end
  end

  return result
end

return M
