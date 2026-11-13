-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("core")

local M = {}
local telemetry = require("ge/extensions/telemetry/core")

function M.testTelemetryPlatformSupport(ctx)
  ctx:assert(telemetry.isPlatformSupported("ps5") == false)
  ctx:assert(telemetry.isPlatformSupported("ps5pro") == false)
  ctx:assert(telemetry.isPlatformSupported("") == true)
end

return M
