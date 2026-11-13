-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY OTHER GAMEPLAY TRACKER

  Smaller gameplay features that do not need a tracker of their own: the track builder and
  the taxi. Both are activities, so the duration of a session or a ride is in the data.
]]

local M = {}
M.dependencies = {'telemetry_core'}

local trackBuilderOpen = false
local taxiRideOpen = false

-- The window funnels every open and close through one call, which also repeats the
-- current state, so the activity is paired off our own state instead.
local function onTrackBuilderWindowToggled(open)
  if open == trackBuilderOpen then return end
  trackBuilderOpen = open

  if open then
    extensions.telemetry_core.startActivity("trackBuilder", {
      level = getCurrentLevelIdentifier() or "unknown",
    })
  else
    extensions.telemetry_core.endActivity("trackBuilder")
  end
end

-- result: dispatched, noTaxiAvailable or tooFarFromRoad
local function onTaxiCalled(result)
  extensions.telemetry_core.addEvent({
    name = "taxiCalled",
    result = result,
  })
end

-- called is false for a taxi hailed at the roadside
local function onTaxiRideStarted(called)
  taxiRideOpen = true
  extensions.telemetry_core.startActivity("taxiRide", {
    called = called,
    career = career_career and career_career.isActive() or false,
    level = getCurrentLevelIdentifier() or "unknown",
  })
end

-- reason is exited or trafficStopped. phase is where the ride was when it ended, arriving
-- means the taxi had stopped for the player. Distances are in meters.
local function onTaxiRideEnded(data)
  if not taxiRideOpen then return end
  taxiRideOpen = false
  extensions.telemetry_core.endActivity("taxiRide", data)
end

local function closeActivities()
  onTrackBuilderWindowToggled(false)
  onTaxiRideEnded({reason = "gameExit"})
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
end

M.onExtensionLoaded = onExtensionLoaded
M.onExit = closeActivities
-- a lua reload tears the trackers down without an onExit, so close the activities here too
M.onExtensionUnloaded = closeActivities

M.onTrackBuilderWindowToggled = onTrackBuilderWindowToggled
M.onTaxiCalled = onTaxiCalled
M.onTaxiRideStarted = onTaxiRideStarted
M.onTaxiRideEnded = onTaxiRideEnded

return M
