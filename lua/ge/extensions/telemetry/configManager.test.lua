-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("configManager")

local M = {}
local configManager = require("ge/extensions/telemetry/configManager")

function M.testMissingTrackerConfigIsDisabledAndAllocationFree(ctx)
  local first = configManager.getModuleConfig("__missing_tracker__")
  local second = configManager.getModuleConfig("__missing_tracker__")

  ctx:assert(first.enabled == false, "missing trackers must default off")
  ctx:assert(rawequal(first, second), "missing tracker config must reuse one table")
  ctx:assert(configManager.isModuleEnabled("__missing_tracker__") == false)
end

return M
