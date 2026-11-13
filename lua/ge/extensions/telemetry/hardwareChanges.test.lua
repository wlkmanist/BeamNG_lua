-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("hardwareChanges")

local M = {}
local hardwareChanges = require("ge/extensions/telemetry/hardwareChanges")

function M.testControllerSnapshotFiltersNonControllerDevices(ctx)
  local snapshot = hardwareChanges.controllerSnapshot({
    {name = "wheel0", type = "wheel", productName = "Wheel", vidpid = "11112222"},
    {name = "joystick0", type = "joystick", productName = "Joystick"},
    {name = "gamepad0", type = "gamepad", productName = "Pad"},
    {name = "xinput0", type = "xinput", productName = "XInput pad"},
    {name = "keyboard0", type = "keyboard"},
    {name = "mouse0", type = "mouse"},
    {name = "openxr0", type = "openxr"},
    {name = "vinput0", type = "vinput"},
  })

  ctx:assertEqual(tableSize(snapshot), 4)
  ctx:assert(snapshot.wheel0 ~= nil)
  ctx:assert(snapshot.joystick0 ~= nil)
  ctx:assert(snapshot.gamepad0 ~= nil)
  ctx:assert(snapshot.xinput0 ~= nil)
end

function M.testConnectionChangesContainAddedAndRemovedDevices(ctx)
  local previous = {
    joystick0 = {device = "joystick0", deviceType = "joystick", productName = "Old"},
  }
  local current = {
    gamepad0 = {device = "gamepad0", deviceType = "gamepad", productName = "New"},
  }

  local changes = hardwareChanges.connectionChanges(previous, current)

  ctx:assertEqual(#changes, 2)
  ctx:assertEqual(changes[1].device, "gamepad0")
  ctx:assertEqual(changes[1].connected, true)
  ctx:assertEqual(changes[2].device, "joystick0")
  ctx:assertEqual(changes[2].connected, false)
end

function M.testReplacedDeviceSlotReportsBothTransitions(ctx)
  local previous = {
    wheel0 = {device = "wheel0", productName = "Old wheel", vidpid = "11112222"},
  }
  local current = {
    wheel0 = {device = "wheel0", productName = "New wheel", vidpid = "33334444"},
  }

  local changes = hardwareChanges.connectionChanges(previous, current)

  ctx:assertEqual(#changes, 2)
  ctx:assertEqual(changes[1].productName, "New wheel")
  ctx:assertEqual(changes[1].connected, true)
  ctx:assertEqual(changes[2].productName, "Old wheel")
  ctx:assertEqual(changes[2].connected, false)
end

function M.testOnlyDirectWindowFullscreenTransitionsAreTracked(ctx)
  ctx:assert(hardwareChanges.isTrackedDisplayTransition("Window", "Fullscreen"))
  ctx:assert(hardwareChanges.isTrackedDisplayTransition("Fullscreen", "Window"))
  ctx:assert(not hardwareChanges.isTrackedDisplayTransition("Window", "Borderless"))
  ctx:assert(not hardwareChanges.isTrackedDisplayTransition("Borderless", "Fullscreen"))
  ctx:assert(not hardwareChanges.isTrackedDisplayTransition("Window", "Window"))
end

return M
