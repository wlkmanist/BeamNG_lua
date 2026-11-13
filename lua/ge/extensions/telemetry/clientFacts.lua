-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local ciProviders = {
  {"jenkins", "JENKINS_URL", "JENKINS_HOME"},
  {"gitlab", "GITLAB_CI"},
  {"github-actions", "GITHUB_ACTIONS"},
  {"azure-pipelines", "TF_BUILD"},
  {"teamcity", "TEAMCITY_VERSION"},
  {"buildkite", "BUILDKITE"},
  {"circleci", "CIRCLECI"},
  {"travis", "TRAVIS"},
  {"appveyor", "APPVEYOR"},
}

local function knownText(value)
  if type(value) ~= "string" or value == "" then return nil end
  if string.lower(value) == "unknown" then return nil end
  return value
end

local function positiveNumber(value)
  value = tonumber(value)
  return value and value > 0 and value or nil
end

local function nonNegativeNumber(value)
  value = tonumber(value)
  return value and value >= 0 and value or nil
end

local function knownBoolean(value)
  if type(value) == "boolean" then return value end
  return nil
end

local function isEnvironmentFlagSet(value)
  if value == nil or value == false or value == 0 then return false end
  if type(value) ~= "string" then return true end
  value = string.lower(value)
  return value ~= "" and value ~= "false" and value ~= "0"
end

function M.detectCiProvider(getEnvironment)
  getEnvironment = getEnvironment or os.getenv
  for _, provider in ipairs(ciProviders) do
    for i = 2, #provider do
      if isEnvironmentFlagSet(getEnvironment(provider[i])) then
        return true, provider[1]
      end
    end
  end
  if isEnvironmentFlagSet(getEnvironment("CI")) then
    return true, "generic"
  end
  return false, nil
end

function M.normalizePlatform(platform)
  if platform == "" then return "pc" end
  return knownText(platform)
end

function M.selectPreferredGPU(adapters)
  if not adapters then return nil end
  for _, adapter in ipairs(adapters) do
    if adapter.type == "dedicated" then return adapter end
  end
  return adapters[1]
end

local function getDeviceType(platform, power)
  if platform == "steamdeck" then return "steamdeck" end
  if platform ~= "" or not power or power.batteryPresent == nil then
    return "unknown"
  end
  return power.batteryPresent and "laptop" or "desktop"
end

local function addOSVersion(facts, osInfo)
  local major = positiveNumber(osInfo.versionMajor)
  local minor = nonNegativeNumber(osInfo.versionMinor)
  local build = nonNegativeNumber(osInfo.buildNumber)
  if not major or not minor or not build then return end

  facts.osVersion = string.format("%d.%d.%d", major, minor, build)
  facts.osVersionMajor = major
  facts.osVersionMinor = minor
  facts.osBuildNumber = build
end

local function isVRAvailable()
  local state = render_openxr and render_openxr.state
  if not state or state.systemName == nil then return nil end
  return state.systemName ~= "" and state.systemName ~= "?"
end

function M.collect(version)
  local platformApi = Engine and Engine.Platform
  local renderApi = Engine and Engine.Render
  local rawPlatform = platformApi and platformApi.getPlatform
    and platformApi.getPlatform() or nil
  local osInfo = platformApi and platformApi.getOSInfo
    and platformApi.getOSInfo() or {}
  local cpuInfo = platformApi and platformApi.getCPUInfo
    and platformApi.getCPUInfo() or {}
  local memoryInfo = platformApi and platformApi.getMemoryInfo
    and platformApi.getMemoryInfo() or {}
  local power = platformApi and platformApi.getPowerInfo
    and platformApi.getPowerInfo() or nil
  local adapters = platformApi and platformApi.getGPUAdaptersInfo
    and platformApi.getGPUAdaptersInfo() or nil
  local gpu = M.selectPreferredGPU(adapters) or {}
  local isCiRunner, ciProvider = M.detectCiProvider(os.getenv)
  local techLicense
  if ResearchVerifier then
    techLicense = knownBoolean(ResearchVerifier.isTechLicenseVerified())
  end

  local facts = {
    version = knownText(version),
    product = knownText(beamng_appname),
    productVersion = knownText(beamng_version),
    platform = M.normalizePlatform(rawPlatform),
    buildType = knownText(beamng_buildtype),
    buildNumber = positiveNumber(beamng_buildnumber),
    arch = knownText(beamng_arch),
    isCiRunner = isCiRunner,
    ciProvider = ciProvider,
    osType = knownText(osInfo.type),
    osBits = positiveNumber(osInfo.bits),
    deviceType = getDeviceType(rawPlatform, power),
    systemMemoryBytes = positiveNumber(memoryInfo.osPhysAvailable),
    cpuVendor = knownText(cpuInfo.vendor),
    cpuName = knownText(cpuInfo.name),
    cpuArch = knownText(cpuInfo.arch),
    cpuPhysicalCores = positiveNumber(cpuInfo.coresPhysical),
    cpuLogicalCores = positiveNumber(cpuInfo.coresLogical),
    gpuVendor = knownText(gpu.vendor),
    gpuName = knownText(gpu.name),
    gpuType = knownText(gpu.type),
    gpuMemoryBytes = nonNegativeNumber(gpu.dedicatedVideoMemoryBytes),
    gpuApi = knownText(gpu.api),
    gpuVendorId = positiveNumber(gpu.vendorId),
    gpuDeviceId = positiveNumber(gpu.deviceId),
    gfxAdapterType = knownText(renderApi and renderApi.getAdapterType
      and renderApi.getAdapterType() or nil),
    headless = knownBoolean(headless_mode),
    distributionBranch = knownText(
      OnlineServiceProvider and OnlineServiceProvider.branch),
    techLicense = techLicense,
    batteryPresent = knownBoolean(power and power.batteryPresent),
    vrAvailable = isVRAvailable(),
  }
  addOSVersion(facts, osInfo)
  return facts
end

return M
