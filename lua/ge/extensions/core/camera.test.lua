-- Run (GE Lua console, or MCP run_lua):
--   extensions.testFramework_TestManager:runTestFiles("camera")

local M = {}

local function cam()
  if not core_camera then extensions.load("core_camera") end
  return core_camera
end

function M.testCameraGroupRing(ctx)
  local nextGroup = cam().nextCameraGroup
  ctx:assertEqual(nextGroup({"world"}, nil), "world", "game cameras -> free cameras")
  ctx:assertEqual(nextGroup({"world"}, "world"), nil, "free cameras -> game cameras")
  ctx:assertEqual(nextGroup({"world"}, false), nil, "system camera -> game cameras")
end

function M.testFreeCameraModes(ctx)
  local cameras = cam().getGlobalCameras()
  ctx:assertEqual(cameras.free.group, "world", "free camera belongs to free ring")
  ctx:assertEqual(cameras.smoothFree.group, "world", "cinematic camera belongs to free ring")
  ctx:assertEqual(cameras.steadycam.group, "world", "steadycam belongs to free ring")
end

function M.testDroneIsRegularCamera(ctx)
  local drone = require("core/cameraModes/droneChase")()
  ctx:assert(drone.isGlobal ~= true, "Drone Chase is vehicle-bound")
  ctx:assert(drone.hidden ~= true, "Drone Chase is visible in Camera Options")
  ctx:assertEqual(drone.disabledByDefault, true, "Drone Chase is disabled by default")
end

function M.testFreeCameraConfigurationApi(ctx)
  local camera = cam()
  ctx:assert(type(camera.getFreeCameraConfigurationReadOnly) == "function", "free camera configuration is readable")
  ctx:assert(type(camera.changeFreeCameraOrder) == "function", "free camera order is configurable")
  ctx:assert(type(camera.toggleFreeCameraEnabledById) == "function", "free camera modes can be enabled")
  ctx:assert(type(camera.setCameraByNameFromOptions) == "function", "camera options use the dedicated selection path")
end

return M
