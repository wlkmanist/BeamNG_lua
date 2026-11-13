-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY PERFORMANCE TRACKER

  Reports the framerate players get, as readings of what the engine already measures for the
  overlay ctrl+F cycles through. See engine/util/fpsTracker.cpp, and core/metrics.lua for the
  same values read for display.

  One event per reading. Nothing is averaged or judged here, so which framerate counts as too
  low stays a question for the server. sampleIntervalSeconds comes from the server config and
  is the volume dial.

  Readings are taken everywhere, menus included, because a slow menu is worth knowing about
  too. Each one says where it came from instead: level is nil in the menus, and paused is set
  when the simulation was stopped.
]]

local M = {}
M.dependencies = {'telemetry_core'}
local performanceMetrics = require("ge/extensions/telemetry/performanceMetrics")

local defaultSampleIntervalSeconds = 300

local sampleIntervalSeconds = defaultSampleIntervalSeconds
local nextReadingAt = 0

local function takeReading(paused)
  -- the registry answers -1 for anything the engine could not produce, gpuTime on a driver
  -- that does not report it for one
  local fpsAvg = performanceMetrics.readNumber("$fps::avg")

  if not fpsAvg or fpsAvg <= 0 then return end

  extensions.telemetry_core.addEvent({
    name = "performance",
    -- nil in the menus, where no level is loaded
    level = getCurrentLevelIdentifier(),
    -- a reading taken while the simulation is stopped is not one from playing. Left out when
    -- false so the payload stays small
    paused = paused or nil,
    intervalSeconds = sampleIntervalSeconds,
    fpsAvg = fpsAvg,
    fpsMin = performanceMetrics.readNumber("$fps::min"),
    fpsP99 = performanceMetrics.readNumber("$fps::p99"),
    cpuMs = performanceMetrics.readNumber("$fps::cpuTime"),
    gpuMs = performanceMetrics.readNumber("$fps::gpuTime"),
    limitedBy = performanceMetrics.getLimitedBy(),
  })
end

-- Runs every frame, so it does one clock call and one comparison and nothing else. Readings
-- are taken wherever the game is, menus included; where it was is on the event.
local function onUpdate(dtReal, dtSim, dtRaw)
  local now = os.clockhp()
  if now < nextReadingAt then return end

  nextReadingAt = now + sampleIntervalSeconds
  takeReading(dtSim <= 0)
end

local function onExtensionLoaded()
  local configured = extensions.telemetry_configManager.getModuleConfig('performance').sampleIntervalSeconds
  if type(configured) == "number" then
    sampleIntervalSeconds = clamp(configured, 5, 3600)
  end
  setExtensionUnloadMode(M, "manual")
end

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate

return M
