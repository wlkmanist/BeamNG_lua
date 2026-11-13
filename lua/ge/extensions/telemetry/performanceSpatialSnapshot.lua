-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local performanceMetrics = require("ge/extensions/telemetry/performanceMetrics")

local phaseMetrics = {}
local uiPhases = {
  "UImsgLoop",
  "UIpixelsToGPU",
  "UIframeJSmain",
  "UIframeJSvehicles",
  "UImenuCompositor",
  "UIimgui",
}
local renderPhases = {
  "PreRender",
  "Render",
  "RenderShadows",
  "RenderReflections",
  "RenderMisc",
  "FramePresent",
  "FrameSecondary",
  "PostRender",
  "OtherRender",
}
local physicsPhases = {
  "PhysicsOther",
  "PhysicsState",
  "PhysicsAndVLUA",
  "PhysicsNodes",
  "PhysicsBeams",
  "PhysicsLights",
}
local luaPhases = {"LuaPre", "Lua"}

local function round(value, scale)
  if type(value) ~= "number" or value ~= value
      or value == math.huge or value == -math.huge then
    return nil
  end
  return math.floor(value * scale + 0.5) / scale
end

local function readRounded(name, scale)
  local value = performanceMetrics.readAvailable(name)
  return value and round(value, scale) or nil
end

local function phase(name)
  local value = phaseMetrics[name]
  if type(value) ~= "number" or value < 0
      or value ~= value or value == math.huge or value == -math.huge then
    return nil
  end
  return round(value, 100)
end

local function summedPhase(names)
  local sum = 0
  local found = false
  for _, name in ipairs(names) do
    local value = phaseMetrics[name]
    if type(value) == "number" and value >= 0
        and value == value and value ~= math.huge then
      sum = sum + value
      found = true
    end
  end
  return found and round(sum, 100) or nil
end

local function addCamera(event)
  local x, y, z = core_camera.getPositionXYZ()
  x, y, z = round(x, 1), round(y, 1), round(z, 1)
  if x and y and z then
    event.position = {x = x, y = y, z = z}
  end

  local angles = core_camera.getYawPitchRoll()
  local forwardX, forwardY = core_camera.getForwardXYZ()
  local hasHeading = forwardX * forwardX + forwardY * forwardY > 0.000001
  local camera = {
    yawDeg = hasHeading and angles and round(angles.yawDeg, 10) or nil,
    pitchDownDeg = angles and round(angles.pitchDown, 10),
    fovDeg = round(core_camera.getFovDeg(), 10),
    mode = core_camera.getActiveCamName(0),
  }
  if next(camera) then event.camera = camera end
end

local function addFramePhases(event)
  if not (Engine.Debug and Engine.Debug.getLastPerformanceMetrics) then return end
  table.clear(phaseMetrics)
  local ok = pcall(Engine.Debug.getLastPerformanceMetrics, phaseMetrics)
  if not ok then return end

  local phases = {
    textureCookerMs = phase("TextureCooker"),
    assetSystemMs = phase("AssetSystem"),
    renderMs = summedPhase(renderPhases),
    physicsMs = summedPhase(physicsPhases),
    luaMs = summedPhase(luaPhases),
    luaGcMs = phase("LuaGC"),
    uiMs = summedPhase(uiPhases),
  }
  if event.gpuWaitMs == nil then event.gpuWaitMs = phase("FramePresent") end
  if next(phases) then event.framePhases = phases end
end

local function renderStat(name, fallback)
  local value = performanceMetrics.readAvailable(name)
  if (value == nil or value == 0) and fallback then
    local ok, fallbackValue = pcall(fallback)
    if ok and type(fallbackValue) == "number" and fallbackValue >= 0
        and fallbackValue == fallbackValue and fallbackValue ~= math.huge then
      value = fallbackValue
    end
  end
  return value
end

local function addRenderStats(event)
  local render = Engine.Render
  local stats = {
    drawCalls = renderStat("$GFXDeviceStatistics::drawCalls", render and render.getDrawCallCount),
    polyCount = renderStat("$GFXDeviceStatistics::polyCount", render and render.getTriangleCount),
    shadowDrawCalls = performanceMetrics.readAvailable("$ShadowStats::drawCalls"),
    shadowPolyCount = performanceMetrics.readAvailable("$ShadowStats::polyCount"),
    activeLights = performanceMetrics.readAvailable("$lightMetrics::activeLights"),
    visibleObjectCount = performanceMetrics.readAvailable("$Scene::visibleObjectCount"),
  }
  if next(stats) then event.renderStats = stats end
end

local function addTextureStreaming(event)
  local render = Engine.Render
  if not (render and render.getTextureStreamingStats) then return end
  local ok, stats = pcall(render.getTextureStreamingStats)
  if ok and type(stats) == "table" and next(stats) then
    event.textureStreaming = stats
  end
end

local function addWorldState(event)
  if type(worldReadyState) == "number" then event.worldReadyState = worldReadyState end
  if be and be.getSimulationTimeScale then
    event.simTimeScale = round(be:getSimulationTimeScale(), 100)
  end
  if be and be.getObjectCount then event.vehicleCount = be:getObjectCount() end

  event.splitScreenPlayers = 1
  if extensions.isExtensionLoaded("render_splitScreen")
      and render_splitScreen and render_splitScreen.getCurrentConfiguration then
    local enabled, playerCount = render_splitScreen.getCurrentConfiguration()
    if enabled and type(playerCount) == "number" then
      event.splitScreenPlayers = playerCount
    end
  end

  if extensions.isExtensionLoaded("gameplay_traffic")
      and gameplay_traffic and gameplay_traffic.getTrafficAmount then
    event.trafficCount = gameplay_traffic.getTrafficAmount(true)
  end
end

function M.capture(level, fpsInstant, frameMs, activeGpu, options)
  local event = {
    level = level,
    fpsInstant = round(fpsInstant, 10),
    fpsAvg = readRounded("$fps::avg", 10),
    fpsMin = readRounded("$fps::min", 10),
    fpsP99 = readRounded("$fps::p99", 10),
    frameMs = round(frameMs, 100),
    cpuMs = readRounded("$fps::cpuTime", 100),
    gpuMs = readRounded("$fps::gpuTime", 100),
    gpuWaitMs = readRounded("$fps::waitForGPU", 100),
    limitedBy = performanceMetrics.getLimitedBy(),
    activeGpu = activeGpu,
  }

  addCamera(event)
  if options and options.renderTimingTrackingEnabled then addFramePhases(event) end
  if options and options.sceneComplexityTrackingEnabled then addRenderStats(event) end
  addTextureStreaming(event)
  addWorldState(event)
  return event
end

return M
