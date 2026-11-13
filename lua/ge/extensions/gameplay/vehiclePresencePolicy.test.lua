-- Run with:
-- require("testFramework/TestManager"):runTestFiles("vehiclePresencePolicy")

local M = {}
local policy = require("gameplay/vehiclePresencePolicy")

function M.testModeValidationAndNormalization(ctx)
  ctx:assert(policy.isValidMode("driver"))
  ctx:assert(policy.isValidMode("passenger"))
  ctx:assert(policy.isValidMode("unrestricted"))
  ctx:assert(not policy.isValidMode("observer"))
  ctx:assertEqual(policy.normalizeMode("driver"), "driver")
  ctx:assertEqual(policy.normalizeMode("invalid", "unrestricted"), "unrestricted")
  ctx:assertEqual(policy.normalizeMode(nil), "passenger")
end

function M.testDefaultUnseatedMode(ctx)
  ctx:assertEqual(policy.defaultUnseatedMode({mode = "freeroam", isMultiseatActive = false}), "unrestricted")
  ctx:assertEqual(policy.defaultUnseatedMode({mode = "freeroam", isMultiseatActive = true}), "passenger")
  ctx:assertEqual(policy.defaultUnseatedMode({mode = "multiplayer"}), "passenger")
  ctx:assertEqual(policy.defaultUnseatedMode({mode = "career"}), "passenger")
  ctx:assertEqual(policy.defaultUnseatedMode(nil), "passenger")
end

function M.testActionMapPermissions(ctx)
  ctx:assert(policy.allowsActionMap("driver", "driving"))
  ctx:assert(not policy.allowsActionMap("driver", "slot"))
  ctx:assert(not policy.allowsActionMap("passenger", "driving"))
  ctx:assert(not policy.allowsActionMap("passenger", "slot"))
  ctx:assert(policy.allowsActionMap("unrestricted", "driving"))
  ctx:assert(policy.allowsActionMap("unrestricted", "slot"))
end

return M
