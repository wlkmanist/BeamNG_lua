-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY UI TRACKER

  Tracks which screens the player enters and leaves. Screens are strictly sequential, so
  each one is reported as a uiScreen activity and the duration is the time spent on it.
  The from field gives the screen the player came from, which reconstructs the path
  taken through the menus.

  Route names only. Screen params are not reported, they can carry arbitrary payloads.

  How long the screen took to become usable rides along on the end of the activity rather
  than being an event of its own. uiScreen is already the most frequent thing we report, so
  a second event per navigation would have been the largest addition to the whole report.
]]

local M = {}
M.dependencies = {'telemetry_core'}

local currentScreen = nil

-- Timing of the navigation that opened currentScreen, waiting for the activity to close
local currentLoad = nil

-- A navigation quicker than this is not worth breaking down, so only the total goes out. The
-- slow ones also say how much of it was the screen waiting on itself
local loadDetailMs = 250

local function endScreen()
  if not currentScreen then return end

  local event = {screen = currentScreen}
  if currentLoad then
    event.loadMs = currentLoad.total
    -- a route that never acknowledged a mount finished earlier, at the commit, so its total
    -- covers less ground. Reported so the two are not averaged together by mistake
    event.loadToMount = currentLoad.mountAcked
    if (currentLoad.total or 0) >= loadDetailMs then
      -- what the route did before the transition started, and what the screen did after the
      -- route was committed. The rest of the total is the UI framework in between
      event.loadEnterMs = currentLoad.enter
      event.loadReadyMs = currentLoad.ready
    end
  end

  extensions.telemetry_core.endActivity("uiScreen", event)
  currentScreen = nil
  currentLoad = nil
end

-- The router fires this once a navigation completed, so this is the screen on display.
-- Using the modern hook here, not the legacy onUiChangedState compatibility hook.
local function onAfterRouteChange(entry)
  local screen = entry and entry.request and entry.request.name
  if not screen then return end

  endScreen()

  currentScreen = screen
  extensions.telemetry_core.startActivity("uiScreen", {
    screen = screen,
    from = entry.origin and entry.origin.route,
  })
end

-- The router finishes a navigation after it committed the route, so this arrives just after
-- the activity above opened. A navigation that was cancelled or timed out never gets here,
-- and that screen is reported without a time.
local function onRouteTiming(routeName, timings)
  if routeName ~= currentScreen then return end
  currentLoad = timings
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
end

-- close the open screen, otherwise the last one has no duration
local function onExit()
  endScreen()
end

M.onExtensionLoaded = onExtensionLoaded
M.onExit = onExit
-- a lua reload tears the trackers down without an onExit, so close the screen here too
M.onExtensionUnloaded = endScreen

M.onAfterRouteChange = onAfterRouteChange
M.onRouteTiming = onRouteTiming

return M
