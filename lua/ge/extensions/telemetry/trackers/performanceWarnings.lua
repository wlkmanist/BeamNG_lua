-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Reports each performance hardware warning once per session.

local M = {}
M.dependencies = {'telemetry_core'}

local reportedWarnings = {}

local function onPerformanceHardwareWarning(category, warning)
  local key = category .. "\0" .. tostring(warning.msg)
  if reportedWarnings[key] then return end
  reportedWarnings[key] = true

  extensions.telemetry_core.addEvent({
    name = "performanceHardwareWarning",
    category = category,
    warning = warning.msg,
    severity = warning.type,
    context = warning.context,
    acknowledged = warning.ack == true,
  })
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
end

M.onExtensionLoaded = onExtensionLoaded
M.onPerformanceHardwareWarning = onPerformanceHardwareWarning

return M
