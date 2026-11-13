-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local hardwareInput = require("ge/extensions/telemetry/hardwareInput")

local controllerTypes = {
  gamepad = true,
  joystick = true,
  wheel = true,
  xinput = true,
}

local function controllerSnapshot(controllerInfo)
  local snapshot = {}
  for _, info in ipairs(controllerInfo or {}) do
    if controllerTypes[info.type] and type(info.name) == "string" then
      local pidVid = type(info.vidpid) == "string" and string.upper(info.vidpid) or nil
      local englishName = info.type == "wheel" and hardwareInput.officialEnglishName(pidVid) or nil
      local mapped = hardwareInput.fromControllerInfo(info, englishName)
      snapshot[info.name] = {
        device = info.name,
        deviceType = info.type,
        productName = mapped.productName,
        vidpid = mapped.vidpid,
        forceFeedback = mapped.forceFeedback,
      }
    end
  end
  return snapshot
end

local function appendChanges(result, names, devices, connected)
  table.sort(names)
  for _, name in ipairs(names) do
    local event = {}
    for key, value in pairs(devices[name]) do
      event[key] = value
    end
    event.connected = connected
    table.insert(result, event)
  end
end

local function connectionChanges(previous, current)
  local connected = {}
  local disconnected = {}

  for name, device in pairs(current) do
    local old = previous[name]
    if not old then
      table.insert(connected, name)
    elseif old.vidpid ~= device.vidpid or old.productName ~= device.productName then
      table.insert(connected, name)
      table.insert(disconnected, name)
    end
  end
  for name in pairs(previous) do
    if not current[name] then table.insert(disconnected, name) end
  end

  local result = {}
  appendChanges(result, connected, current, true)
  appendChanges(result, disconnected, previous, false)
  return result
end

local function isTrackedDisplayTransition(from, to)
  return from == "Window" and to == "Fullscreen"
    or from == "Fullscreen" and to == "Window"
end

M.controllerSnapshot = controllerSnapshot
M.connectionChanges = connectionChanges
M.isTrackedDisplayTransition = isTrackedDisplayTransition

return M
