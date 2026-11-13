-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY HARDWARE TRACKER

  Collects system, graphics, display, audio, storage and input device information, to
  support minimum spec and optimization decisions.

  The survey is large and changes rarely, so it is only sent every 30 days. Controller,
  audio output and display mode transitions are separate point events.

  The survey we last sent is kept, and its modification time is when it went out. Lowering
  surveyIntervalHours in the server config makes every client survey again.

  Bindings load on onFirstUpdate, which main.lua fires before settings.finalizeInit loads
  telemetry, so the devices are already enumerated when this tracker starts.
]]

local M = {}
M.dependencies = {'telemetry_core'}

local hardwareAudio = require('ge/extensions/telemetry/hardwareAudio')
local hardwareChanges = require('ge/extensions/telemetry/hardwareChanges')
local hardwareInput = require('ge/extensions/telemetry/hardwareInput')
local defaultSurveyIntervalHours = 24 * 30
local surveyFile = extensions.telemetry_core.getDataFolder() .. "surveys/hardwareSurvey.json"
local surveyVersion = 3
local connectedControllers = {}

local function getControllerInfo()
  if not Input or not Input.getControllersInfo then return nil end
  return Input.getControllersInfo() or {}
end

local function collectInputDevices(controllerInfo)
  return hardwareInput.collect(controllerInfo or getControllerInfo())
end

-- The stable adapter data goes into the survey, the memory usage into separate snapshots.
local function collectGPUs()
  local gpus = {}
  local snapshots = {}

  for _, gpu in ipairs(Engine.Platform.getGPUAdaptersInfo() or {}) do
    table.insert(gpus, {
      adapterIndex = gpu.adapterIndex,
      name = gpu.name,
      type = gpu.type,
      vendor = gpu.vendor,
      driverName = gpu.driverName,
      driverVersion = gpu.driverVersion,
      api = gpu.api,
      apiVersion = gpu.apiVersion,
      vendorId = gpu.vendorId,
      deviceId = gpu.deviceId,
      subsystemId = gpu.subsystemId,
      revision = gpu.revision,
      dedicatedVideoMemoryBytes = gpu.dedicatedVideoMemoryBytes,
      dedicatedSystemMemoryBytes = gpu.dedicatedSystemMemoryBytes,
      sharedSystemMemoryBytes = gpu.sharedSystemMemoryBytes,
    })

    if gpu.localUsageBytes ~= nil or gpu.nonLocalUsageBytes ~= nil then
      table.insert(snapshots, {
        adapterIndex = gpu.adapterIndex,
        gpuName = gpu.name,
        localUsageBytes = gpu.localUsageBytes,
        localBudgetBytes = gpu.localBudgetBytes,
        nonLocalUsageBytes = gpu.nonLocalUsageBytes,
        nonLocalBudgetBytes = gpu.nonLocalBudgetBytes,
      })
    end
  end

  return gpus, snapshots
end

local function getDeviceType(power)
  local platform = Engine.Platform.getPlatform()
  if platform == "steamdeck" then return platform end
  if platform ~= "" or not power or power.batteryPresent == nil then return "unknown" end
  return power.batteryPresent and "laptop" or "desktop"
end

-- The headset and the resolution it asks for. The session tracker reports whether VR is
-- running as a flag; the model and its resolution are hardware and belong here. Nil when
-- no headset answered, so a machine without one adds nothing to the survey.
local function collectVR()
  local state = render_openxr and render_openxr.state
  if not state or not state.systemName or state.systemName == "?" then return nil end
  return {
    systemName = state.systemName,
    sessionRunning = state.sessionRunning,
    headsetActive = state.headsetActive,
    targetRefreshRate = state.targetRefreshRate,
    recommendedWidth = state.recommendedWidth,
    recommendedHeight = state.recommendedHeight,
    renderedWidth = state.renderedWidth,
    renderedHeight = state.renderedHeight,
  }
end

-- What the screen can do, not what the player asked for. The HDR settings are already in
-- the settings tracker, and a player can leave HDR off on a screen that supports it, so
-- only these three say how much of the population could use it at all.
local function collectHdr()
  if not GFXHdr or not GFXHdr.getSupported then return nil end
  return {
    supported = GFXHdr.getSupported(),
    outputMode = GFXHdr.getOutputModeName and GFXHdr.getOutputModeName() or nil,
    bestOutputMode = GFXHdr.getBestOutputModeName and GFXHdr.getBestOutputModeName() or nil,
  }
end

local function collectDisplayInfo()
  local info = core_settings_graphic
    and core_settings_graphic.getDisplayInformation
    and core_settings_graphic.getDisplayInformation()
    or {}
  local screens = {}

  -- getDisplayInformation knows the graphics outputs, getMonitorInfo knows the physical
  -- monitors and is the only source of dpi. Matched on desktop position, which is unique
  -- per monitor because they cannot overlap.
  local monitorInfo = Engine.Platform.getMonitorInfo and Engine.Platform.getMonitorInfo() or {}
  local byPosition = {}
  -- Formatted rather than concatenated, so the two sources cannot miss each other over
  -- one of them rendering the same coordinate as 0 and the other as 0.0
  local function positionKey(x, y)
    return string.format("%d,%d", x or 0, y or 0)
  end
  for _, monitor in ipairs(monitorInfo) do
    if monitor.pos then
      byPosition[positionKey(monitor.pos.x, monitor.pos.y)] = monitor
    end
  end

  for _, output in ipairs(info.outputs or {}) do
    local region = output.region or {}
    local monitor = byPosition[positionKey(region.left, region.top)]
    table.insert(screens, {
      name = output.monitorName,
      output = output.output,
      left = region.left,
      top = region.top,
      width = region.width,
      height = region.height,
      refreshRate = output.refreshRate,
      dpi = monitor and monitor.dpi,
      aspectRatio = monitor and monitor.aspectRatio,
    })
  end

  local region = info.mainWindowRegion or {}
  local videoMode = GFXDevice and GFXDevice.getVideoMode and GFXDevice.getVideoMode() or {}
  return {
    count = #screens,
    screens = screens,
    desktopBitDepth = monitorInfo.desktopBitDepth,
    desktopCompositionEnabled = monitorInfo.desktopCompositionEnabled,
    hdr = collectHdr(),
    window = {
      left = region.left,
      top = region.top,
      width = region.width,
      height = region.height,
      videoMode = {
        width = videoMode.width,
        height = videoMode.height,
        refreshRate = videoMode.refreshRate,
        displayMode = videoMode.displayMode,
      }
    }
  }
end

local function collectAudio()
  if not Engine.Audio or not Engine.Audio.getSelectedDeviceInfo then return nil end
  local output = hardwareAudio.fromDeviceInfo(Engine.Audio.getSelectedDeviceInfo())
  return output and {output = output} or nil
end

local function onDeviceChanged()
  local controllerInfo = getControllerInfo()
  if not controllerInfo then return end

  local current = hardwareChanges.controllerSnapshot(controllerInfo)
  for _, event in ipairs(hardwareChanges.connectionChanges(connectedControllers, current)) do
    event.name = "inputDeviceConnection"
    extensions.telemetry_core.addEvent(event)
  end
  connectedControllers = current
end

local function onAudioOutputDeviceChanged()
  local audio = collectAudio()
  local output = audio and audio.output or {}
  extensions.telemetry_core.addEvent({
    name = "audioOutputChanged",
    sampleRateHz = output.sampleRateHz,
    speakerMode = output.speakerMode,
    channels = output.channels,
  })
end

local function onDisplayModeChanged(from, to)
  if not hardwareChanges.isTrackedDisplayTransition(from, to) then return end
  extensions.telemetry_core.addEvent({
    name = "displayModeChanged",
    from = from,
    to = to,
  })
end

local function collectHardwareInfo(inputDevices, gpus)
  local power = Engine.Platform.getPowerInfo()
  local data = {
    name = "hardwareSurvey",
    deviceType = getDeviceType(power),
    input = inputDevices,
    os = Engine.Platform.getOSInfo(),
    cpu = Engine.Platform.getCPUInfo(),
    gpus = gpus,
    memory = Engine.Platform.getMemoryInfo(),
    display = collectDisplayInfo(),
    audio = collectAudio(),
    vr = collectVR(),

    steam = {
      language = OnlineServiceProvider.language,
      branch = OnlineServiceProvider.branch,
      working = OnlineServiceProvider.isWorking,
      loggedin = OnlineServiceProvider.accountLoggedIn
    }
  }

  -- Add detailed language info to OS
  data.os.languageOS = Lua:getOSLanguage()
  data.os.languageProvider = Lua:getSteamLanguage()
  data.os.appliedLanguage = Lua:getSelectedLanguage()

  -- Add Linux window system info
  if data.os.type == 'linux' then
    data.os.windowsystem = Engine.Platform.getVideoDriver()
  end

  -- Add disk info. getDiskFreeSpace carries the drive sizes beside the free bytes, so
  -- how full the drive is can be worked out rather than only how much is left.
  local space = Engine.Platform.getDiskFreeSpace() or {}
  data.disk = {
    freeSpace = { root = space.root, user = space.user },
    totalSpace = { root = space.rootTotal, user = space.userTotal },
  }
  if data.os.type == 'linux' then
    data.disk.caseSensiGame = FS:isGamePathCaseSensitive()
    data.disk.caseSensiUser = FS:isUserPathCaseSensitive()
  end

  -- Check for OneDrive path
  if string.find(FS:getUserPath(), ".:\\Users\\.-\\OneDrive") then
    data.disk.oneDrivePath = true
  end

  -- Count cache files
  local cache = FS:findFiles("/", "cache.*", 1, false, true)
  data.disk.cacheFileCount = #cache

  -- Add piracy detection
  if sailingTheHighSeas then
    data.piracy = {detected = true}
  end

  return data
end

local function onExtensionLoaded()
  connectedControllers = hardwareChanges.controllerSnapshot(getControllerInfo())

  -- The snapshots are the memory in use right now, so they go out once per session
  local gpus, snapshots = collectGPUs()
  for _, snapshot in ipairs(snapshots) do
    snapshot.name = "gpuMemorySnapshot"
    extensions.telemetry_core.addEvent(snapshot)
  end

  local hours = extensions.telemetry_configManager.getSurveyIntervalHours(
    'hardware', defaultSurveyIntervalHours)
  local stat = FS:stat(surveyFile)
  local delivered = stat and stat.modtime
  local previous = delivered and jsonReadFile(surveyFile)
  if not delivered
      or not previous
      or previous.surveyVersion ~= surveyVersion
      or delivered <= os.time() - hours * 60 * 60 then
    local survey = collectHardwareInfo(collectInputDevices(), gpus)
    survey.surveyVersion = surveyVersion
    -- only kept once it is in the report. Keeping a dropped survey would silence this
    -- machine for a whole interval over data that was never sent.
    if extensions.telemetry_core.addEvent(survey) then
      jsonWriteFile(surveyFile, survey, true)
    end
  end

  -- Prevent automatic unloading
  setExtensionUnloadMode(M, "manual")
end

M.onExtensionLoaded = onExtensionLoaded
M.onDeviceChanged = onDeviceChanged
M.onAudioOutputDeviceChanged = onAudioOutputDeviceChanged
M.onDisplayModeChanged = onDisplayModeChanged

return M