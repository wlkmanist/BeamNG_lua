-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY CONTROLS TRACKER

  Reports how the player drives: which input method steers the car, and how often each
  bound action is used. Which devices are connected belongs to the hardware survey.

  controlsUsed is a point event, not a duration. The vehicle side only reports a change,
  and the method almost never changes within a session, so the span it would measure is
  the session itself. It reports per vehicle, so switching vehicles reports again.
]]

local M = {}
M.dependencies = {'telemetry_core'}

local actionUseReported = false
local reloading = false

local function onSteeringFilterChanged(method)
  extensions.telemetry_core.addEvent({
    name = "controlsUsed",
    method = method,
  })
end

-- Counts are cumulative since the process started, so they are reported once at the end.
-- Analog actions such as steering count every value change and sit orders of magnitude
-- above a button, which counts presses. Only the fact that an action is used is
-- comparable across the two, not the size of the number.
local function reportActionUse()
  if not ActionMap or not ActionMap.getActionUseCounts then return end

  local counts = ActionMap.getActionUseCounts()
  if not counts or not next(counts) then return end

  extensions.telemetry_core.addEvent({
    name = "inputActionUse",
    counts = counts,
  })
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
end

-- core unloads the trackers before it flushes the buffer, so this still reaches the file
local function onExtensionUnloaded()
  if reloading or actionUseReported then return end
  actionUseReported = true
  reportActionUse()
end

local function onSerialize(reason)
  reloading = reason == "reload"
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onSerialize = onSerialize

M.onSteeringFilterChanged = onSteeringFilterChanged

return M
