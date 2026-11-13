-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("clientFacts")

local M = {}
local clientFacts = require("ge/extensions/telemetry/clientFacts")

local function getEnvironment(values)
  return function(name)
    return values[name]
  end
end

function M.testCiProviderDetection(ctx)
  local cases = {
    {"JENKINS_URL", "jenkins"},
    {"GITLAB_CI", "gitlab"},
    {"GITHUB_ACTIONS", "github-actions"},
    {"TF_BUILD", "azure-pipelines"},
    {"TEAMCITY_VERSION", "teamcity"},
    {"BUILDKITE", "buildkite"},
    {"CIRCLECI", "circleci"},
    {"TRAVIS", "travis"},
    {"APPVEYOR", "appveyor"},
    {"CI", "generic"},
  }

  for _, case in ipairs(cases) do
    local isCiRunner, provider = clientFacts.detectCiProvider(
      getEnvironment({[case[1]] = "true"}))
    ctx:assert(isCiRunner == true, case[2] .. " must be detected")
    ctx:assertEqual(provider, case[2])
  end
end

function M.testCiProviderPriority(ctx)
  local isCiRunner, provider = clientFacts.detectCiProvider(getEnvironment({
    JENKINS_URL = "1",
    GITLAB_CI = "1",
    GITHUB_ACTIONS = "1",
    CI = "1",
  }))

  ctx:assert(isCiRunner == true, "a provider flag must identify a CI runner")
  ctx:assertEqual(provider, "jenkins")
end

function M.testFalseCiFlags(ctx)
  local isCiRunner, provider = clientFacts.detectCiProvider(getEnvironment({
    GITLAB_CI = "0",
    GITHUB_ACTIONS = "false",
    TF_BUILD = "FALSE",
    BUILDKITE = "",
    CI = "0",
  }))

  ctx:assert(isCiRunner == false, "false CI flags must not identify a runner")
  ctx:assert(provider == nil, "false CI flags must not select a provider")
end

function M.testCollectedContextContract(ctx)
  local previous = {
    Engine = Engine,
    getenv = os.getenv,
    OnlineServiceProvider = OnlineServiceProvider,
    ResearchVerifier = ResearchVerifier,
    render_openxr = render_openxr,
    beamng_appname = beamng_appname,
    beamng_version = beamng_version,
    beamng_buildtype = beamng_buildtype,
    beamng_buildnumber = beamng_buildnumber,
    beamng_arch = beamng_arch,
    headless_mode = headless_mode,
  }
  Engine = {
    Platform = {
      getPlatform = function() return "" end,
      getOSInfo = function()
        return {type = "windows", versionMajor = 10, versionMinor = 0,
          buildNumber = 22631, bits = 64}
      end,
      getCPUInfo = function()
        return {vendor = "GenuineIntel", name = "Test CPU", arch = "x64",
          coresPhysical = 8, coresLogical = 16}
      end,
      getMemoryInfo = function() return {osPhysAvailable = 16 * 1024 ^ 3} end,
      getPowerInfo = function() return {batteryPresent = false} end,
      getGPUAdaptersInfo = function()
        return {{name = "Intel GPU", vendor = "Intel", type = "integrated",
          dedicatedVideoMemoryBytes = 0, api = "Vulkan", vendorId = 32902, deviceId = 1}}
      end,
    },
    Render = {getAdapterType = function() return "Vulkan" end},
  }
  os.getenv = function(name) return name == "GITLAB_CI" and "true" or nil end
  OnlineServiceProvider = {branch = "internal"}
  ResearchVerifier = {isTechLicenseVerified = function() return false end}
  render_openxr = {state = {systemName = "Test headset"}}
  beamng_appname = "BeamNG.drive"
  beamng_version = "0.40.0.0.DEV1"
  beamng_buildtype = "INTERNAL"
  beamng_buildnumber = "123"
  beamng_arch = "x64"
  headless_mode = false

  local ok, facts = pcall(clientFacts.collect, "30")

  Engine = previous.Engine
  os.getenv = previous.getenv
  OnlineServiceProvider = previous.OnlineServiceProvider
  ResearchVerifier = previous.ResearchVerifier
  render_openxr = previous.render_openxr
  beamng_appname = previous.beamng_appname
  beamng_version = previous.beamng_version
  beamng_buildtype = previous.beamng_buildtype
  beamng_buildnumber = previous.beamng_buildnumber
  beamng_arch = previous.beamng_arch
  headless_mode = previous.headless_mode

  ctx:assert(ok, "collect must accept the engine context")
  ctx:assertEqual(facts.version, "30")
  ctx:assertEqual(facts.platform, "pc")
  ctx:assertEqual(facts.ciProvider, "gitlab")
  ctx:assertEqual(facts.osVersion, "10.0.22631")
  ctx:assertEqual(facts.deviceType, "desktop")
  ctx:assertEqual(facts.systemMemoryBytes, 16 * 1024 ^ 3)
  ctx:assertEqual(facts.gpuName, "Intel GPU")
  ctx:assertEqual(facts.gpuMemoryBytes, 0)
  ctx:assert(facts.headless == false, "false headless state must be retained")
  ctx:assert(facts.techLicense == false, "false tech licence state must be retained")
  ctx:assert(facts.vrAvailable == true, "a named headset must be available")
end

function M.testDesktopPlatformNormalization(ctx)
  ctx:assertEqual(clientFacts.normalizePlatform(""), "pc")
  ctx:assertEqual(clientFacts.normalizePlatform("steamdeck"), "steamdeck")
  ctx:assertEqual(clientFacts.normalizePlatform(nil), nil)
end

function M.testPreferredGpuSelection(ctx)
  local integrated = {name = "integrated", type = "integrated"}
  local dedicated = {name = "dedicated", type = "dedicated"}
  local laterDedicated = {name = "later", type = "dedicated"}

  ctx:assert(clientFacts.selectPreferredGPU({
    integrated,
    dedicated,
    laterDedicated,
  }) == dedicated, "the first dedicated adapter must be preferred")
  ctx:assert(clientFacts.selectPreferredGPU({integrated}) == integrated,
    "the first adapter must be the fallback")
  ctx:assert(clientFacts.selectPreferredGPU({}) == nil,
    "an empty adapter list must not invent a GPU")
end

return M
