-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY TRAFFIC TRACKER

  Answers how much traffic is actually used. The trafficActive activity carries the
  duration, so a session that switches traffic on and leaves it on is visible as such.

  Kept deliberately cheap: two lifecycle hooks plus a peak counter. The amount is not
  read when traffic starts or stops, because those hooks fire a frame after the first or
  the last vehicle appears, when the count is not settled yet.
]]

local M = {}
M.dependencies = {'telemetry_core'}

local trafficRunning = false
local peakAmount = 0

local function onTrafficStarted()
  trafficRunning = true
  peakAmount = 0

  extensions.telemetry_core.startActivity("trafficActive", {
    level = getCurrentLevelIdentifier() or "unknown",
  })
end

local function onTrafficStopped()
  if not trafficRunning then return end
  trafficRunning = false

  extensions.telemetry_core.endActivity("trafficActive", {peakAmount = peakAmount})
end

-- Fires whenever vehicles are pooled in or out. Only the peak is kept, no event.
local function onTrafficAmountChanged(activeAmount)
  if activeAmount > peakAmount then
    peakAmount = activeAmount
  end
end

-- traffic does not always stop cleanly on a level change, so close the activity here
local function onClientEndMission()
  onTrafficStopped()
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
end

M.onExtensionLoaded = onExtensionLoaded
M.onExit = onClientEndMission
-- a lua reload tears the trackers down without an onExit, so close the activity here too
M.onExtensionUnloaded = onClientEndMission

M.onTrafficStarted = onTrafficStarted
M.onTrafficStopped = onTrafficStopped
M.onTrafficAmountChanged = onTrafficAmountChanged
M.onClientEndMission = onClientEndMission

return M
