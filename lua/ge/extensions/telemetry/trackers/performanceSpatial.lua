-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"telemetry_core", "core_camera"}

local Detector = require("ge/extensions/telemetry/performanceSpatialDetector")
local performanceMetrics = require("ge/extensions/telemetry/performanceMetrics")
local performanceSpatialConfig = require("ge/extensions/telemetry/performanceSpatialConfig")
local gameplayExit = require("ge/extensions/telemetry/performanceSpatialGameplayExit")
local spatialSnapshot = require("ge/extensions/telemetry/performanceSpatialSnapshot")

local pollIntervalSeconds = 0.13
local nextPollAt = 0
local nextSpatialAt = 0
local spatialSampleIntervalSeconds = 0
local dipTrackingEnabled = false
local recoveryTrackingEnabled = false
local gameplayExitTrackingEnabled = false
local shaderGenerationTrackingEnabled = false
local lastShaderGenerationCount
local detector
local worstSnapshot
local lastLevel
local lastSpatialAt
local lastPollAt
local lastFpsInstant
local lastFrameMs
local dipObservedSeconds = 0
local trackedLevels
local activeGpu
local snapshotOptions
local lastGameplayExitKey
local lastGameplayExitAt = 0
local completedMissionId

local function resetDetector()
  if detector then detector:reset() end
  worstSnapshot = nil
end

local function emitDip(details)
  if not details or not worstSnapshot then return end
  worstSnapshot.name = "performanceDip"
  worstSnapshot.durationMs = math.floor(details.durationMs + 0.5)
  worstSnapshot.worstAgoMs = math.floor(details.worstAgoMs + 0.5)
  worstSnapshot.baselineFrameMs = math.floor(details.baselineFrameMs * 100 + 0.5) / 100
  worstSnapshot.trigger = details.trigger
  worstSnapshot.dipFpsThreshold = details.dipFpsThreshold
  worstSnapshot.dipFrameTimeRatio = details.dipFrameTimeRatio
  worstSnapshot.dipMinDurationMs = details.dipMinDurationMs
  extensions.telemetry_core.addEvent(worstSnapshot)
  worstSnapshot = nil
end

local function accumulateDipObservation(now)
  if lastPollAt and detector and detector:canReport(lastPollAt * 1000) then
    dipObservedSeconds = dipObservedSeconds + now - lastPollAt
  end
  lastPollAt = now
end

local function emitSpatial(now, finalExposure)
  if not lastLevel or not lastSpatialAt or not lastFpsInstant
      or now - lastSpatialAt < 1 then return end
  local event = spatialSnapshot.capture(
    lastLevel, lastFpsInstant, lastFrameMs, activeGpu,
    not finalExposure and snapshotOptions)
  event.name = "performanceSpatial"
  event.intervalSeconds = math.floor(
    clamp(now - lastSpatialAt, 1, 3600) * 100 + 0.5) / 100
  if detector then
    event.dipObservedSeconds = math.floor(
      clamp(dipObservedSeconds, 0, event.intervalSeconds) * 100 + 0.5) / 100
  end
  if finalExposure then
    event.finalExposure = true
    event.fpsInstant, event.fpsAvg, event.fpsMin, event.fpsP99 = nil, nil, nil, nil
    event.frameMs, event.cpuMs, event.gpuMs, event.gpuWaitMs = nil, nil, nil, nil
    event.limitedBy, event.simTimeScale = nil, nil
    event.framePhases, event.renderStats, event.textureStreaming = nil, nil, nil
  end
  extensions.telemetry_core.addEvent(event)
  lastSpatialAt = now
  dipObservedSeconds = 0
end

local function finishContext(now, includeExposure)
  accumulateDipObservation(now)
  if detector then emitDip(detector:finish(now * 1000)) end
  if includeExposure and spatialSampleIntervalSeconds > 0 then
    emitSpatial(now, true)
  end
  lastLevel, lastSpatialAt, lastPollAt = nil, nil, nil
  lastFpsInstant, lastFrameMs = nil, nil
  nextSpatialAt, dipObservedSeconds = 0, 0
  resetDetector()
end

local function trackVehReset()
  if not recoveryTrackingEnabled then return end

  local level = getCurrentLevelIdentifier()
  if not level or level == "" or (trackedLevels and not trackedLevels[level]) then return end

  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then return end
  local position = vehicle:getPosition()
  extensions.telemetry_core.addEvent({
    name = "vehicleRecovery",
    level = level,
    position = {x = position.x, y = position.y, z = position.z},
  })
end

local function emitGameplayExit(exitKind, activity)
  if not gameplayExitTrackingEnabled then return end
  local event = gameplayExit.capture(exitKind, activity, trackedLevels)
  if not event then return end
  if exitKind ~= "abort" and event.activityType == "mission"
      and event.activityId == completedMissionId then return end

  local now = os.clockhp()
  local key = event.activityType .. ":" .. (event.activityId or "")
  if key == lastGameplayExitKey and now - lastGameplayExitAt < 5 then return end
  lastGameplayExitKey = key
  lastGameplayExitAt = now
  extensions.telemetry_core.addEvent(event)
end

local function onAnyMissionChanged(change)
  if change == "started" then completedMissionId = nil end
end

local function onMissionAttemptAggregated(_, mission)
  completedMissionId = mission and mission.id or completedMissionId
end

local function onRecoveryPromptButtonPressed(id)
  if id == "restartMission" then completedMissionId = nil end
end

local function onGameplayActivityAborted()
  emitGameplayExit("abort")
end

local function onClientPreEndMission()
  emitGameplayExit("worldExit")
end

local function onPreExit()
  emitGameplayExit("gameExit")
end

local function configureGameplayExitHooks(enabled)
  M.onAnyMissionChanged = enabled and onAnyMissionChanged or nil
  M.onMissionAttemptAggregated = enabled and onMissionAttemptAggregated or nil
  M.onRecoveryPromptButtonPressed = enabled and onRecoveryPromptButtonPressed or nil
  M.onGameplayActivityAborted = enabled and onGameplayActivityAborted or nil
  M.onClientPreEndMission = enabled and onClientPreEndMission or nil
  M.onPreExit = enabled and onPreExit or nil
  extensions.hookUpdate("onAnyMissionChanged")
  extensions.hookUpdate("onMissionAttemptAggregated")
  extensions.hookUpdate("onRecoveryPromptButtonPressed")
  extensions.hookUpdate("onGameplayActivityAborted")
  extensions.hookUpdate("onClientPreEndMission")
  extensions.hookUpdate("onPreExit")
end

local function emitShaderGeneration(level, fpsInstant, frameMs, count)
  local event = spatialSnapshot.capture(level, fpsInstant, frameMs, activeGpu)
  event.name = "shaderGeneration"
  event.generatedShaderCount = count
  extensions.telemetry_core.addEvent(event)
end

local function onUpdate(dtReal, dtSim)
  if spatialSampleIntervalSeconds == 0
      and not dipTrackingEnabled and not shaderGenerationTrackingEnabled then return end

  local now = os.clockhp()
  if now < nextPollAt then return end
  nextPollAt = now + pollIntervalSeconds
  local shaderGenerationCount = shaderGenerationTrackingEnabled
    and Engine.Render.getShaderGenerationCount() or nil

  local level = getCurrentLevelIdentifier()
  if not level or level == "" or (trackedLevels and not trackedLevels[level])
      or worldReadyState ~= 2 or not performanceMetrics.isFocused()
      or not dtSim or dtSim <= 0 then
    lastShaderGenerationCount = shaderGenerationCount
    finishContext(now, true)
    return
  end
  if level ~= lastLevel then
    if lastLevel then finishContext(now, false) end
    lastLevel = level
    lastSpatialAt = now
    lastPollAt = now
    nextSpatialAt = spatialSampleIntervalSeconds > 0
      and now + spatialSampleIntervalSeconds or 0
    lastShaderGenerationCount = shaderGenerationCount
    resetDetector()
  end

  local fpsInstant = performanceMetrics.readAvailable("$fps::instantaneous")
  if not fpsInstant or fpsInstant <= 0 then
    lastShaderGenerationCount = shaderGenerationCount
    lastPollAt = now
    return
  end
  local frameMs = 1000 / fpsInstant
  accumulateDipObservation(now)
  lastFpsInstant, lastFrameMs = fpsInstant, frameMs

  if shaderGenerationCount then
    local generatedShaderCount = lastShaderGenerationCount
      and shaderGenerationCount - lastShaderGenerationCount or 0
    lastShaderGenerationCount = shaderGenerationCount
    if generatedShaderCount > 0 then
      emitShaderGeneration(level, fpsInstant, frameMs, generatedShaderCount)
    end
  end

  if detector then
    local limitedBy = performanceMetrics.getLimitedBy()
    local captureWorst, dip = detector:update(
      now * 1000, fpsInstant, frameMs, limitedBy == nil)
    if captureWorst then
      worstSnapshot = spatialSnapshot.capture(level, fpsInstant, frameMs, activeGpu)
    end
    if dip then
      emitDip(dip)
    elseif not detector.episodeStartMs then
      worstSnapshot = nil
    end
  end

  if spatialSampleIntervalSeconds > 0 and now >= nextSpatialAt then
    nextSpatialAt = now + spatialSampleIntervalSeconds
    emitSpatial(now, false)
  end
end

local function onExtensionLoaded(data)
  local options = performanceSpatialConfig.read(
    extensions.telemetry_configManager.getModuleConfig("performanceSpatial"))
  spatialSampleIntervalSeconds = options.sampleIntervalSeconds
  dipTrackingEnabled = options.dipTrackingEnabled
  recoveryTrackingEnabled = options.recoveryTrackingEnabled
  gameplayExitTrackingEnabled = options.gameplayExitTrackingEnabled
  configureGameplayExitHooks(gameplayExitTrackingEnabled)
  shaderGenerationTrackingEnabled = options.shaderGenerationTrackingEnabled
  trackedLevels = options.levels
  snapshotOptions = options
  lastGameplayExitKey = nil
  lastGameplayExitAt = 0
  completedMissionId = type(data) == "table"
    and type(data.completedMissionId) == "string"
    and data.completedMissionId or nil

  local pollingEnabled = spatialSampleIntervalSeconds > 0
    or dipTrackingEnabled or shaderGenerationTrackingEnabled
  if not pollingEnabled and not recoveryTrackingEnabled
      and not gameplayExitTrackingEnabled then
    return false
  end
  if not pollingEnabled then
    M.onUpdate = nil
    extensions.hookUpdate("onUpdate")
    setExtensionUnloadMode(M, "manual")
    return
  end

  lastShaderGenerationCount = shaderGenerationTrackingEnabled
    and Engine.Render.getShaderGenerationCount() or nil
  activeGpu = nil
  if Engine.Platform and Engine.Platform.getGPUInfo then
    local ok, gpu = pcall(Engine.Platform.getGPUInfo)
    if ok and type(gpu) == "table" then
      activeGpu = {
        name = type(gpu.name) == "string" and gpu.name or nil,
        vendor = type(gpu.vendor) == "string" and gpu.vendor or nil,
        memoryMB = type(gpu.memoryMB) == "number" and gpu.memoryMB or nil,
      }
      if not next(activeGpu) then activeGpu = nil end
    end
  end

  detector = nil
  if options.detector then
    detector = Detector.new(options.detector)
    if type(data) == "table" then
      detector.eventCount = clamp(
        tonumber(data.eventCount) or 0, 0, detector.maxDipEventsPerSession)
      detector.cooldownUntilMs = math.max(
        tonumber(data.cooldownUntilMs) or 0, 0)
    end
  end

  setExtensionUnloadMode(M, "manual")
end

local function onSerialize(reason)
  if reason ~= "reload" then return end
  finishContext(os.clockhp(), true)
  local data = {completedMissionId = completedMissionId}
  if detector then
    data.eventCount = detector.eventCount
    data.cooldownUntilMs = detector.cooldownUntilMs
  end
  if next(data) then return data end
end

local function finishCurrentContext()
  finishContext(os.clockhp(), true)
end

M.onExtensionLoaded = onExtensionLoaded
M.onSerialize = onSerialize
M.onUpdate = onUpdate
M.onClientEndMission = finishCurrentContext
M.onExit = finishCurrentContext
M.onExtensionUnloaded = finishCurrentContext
M.trackVehReset = trackVehReset

return M
