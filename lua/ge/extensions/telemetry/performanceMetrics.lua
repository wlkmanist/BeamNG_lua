-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

function M.readNumber(name)
  local value = tonumber(VariableRegistry.get(name, -1)) or -1
  return (value ~= value or value == math.huge or value == -math.huge) and -1 or value
end

function M.readAvailable(name)
  local value = M.readNumber(name)
  return value >= 0 and value or nil
end

function M.isFocused()
  return not Engine.isProgramFocused or Engine.isProgramFocused()
end

-- A ceiling the player chose. Without it a reading held at 60 looks like a machine that
-- cannot reach it.
function M.getLimitedBy()
  if settings.getValue("fpsLimitBackgroundEnabled") and not M.isFocused() then
    return "background"
  end
  if render_openxr and render_openxr.isSessionRunning() then return "vr" end
  if settings.getValue("fpsLimitEnabled") then return "limiter" end
  if settings.getValue("vsync") then return "vsync" end
end

return M
