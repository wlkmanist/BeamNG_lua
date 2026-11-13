-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("hardwareAudio")

local M = {}
local hardwareAudio = require("ge/extensions/telemetry/hardwareAudio")

local function output(name)
  return hardwareAudio.fromDeviceInfo({
    name = name,
    provider = "FMOD",
    driverIndex = 0,
    useHardware = false,
    maxBuffers = 16,
    caps = 31,
    sampleRateHz = 48000,
    speakerMode = "Stereo",
    channels = 2,
  })
end

function M.testClassifiesKnownOutputTypes(ctx)
  ctx:assertEqual(output("Headphones (WH-1000XM5)").category, "headphones")
  ctx:assertEqual(output("LG TV (NVIDIA High Definition Audio)").category, "display")
  ctx:assertEqual(output("Speakers (Realtek Audio)").category, "speakers")
  ctx:assertEqual(output("VoiceMeeter Input").category, "virtual")
end

function M.testUnknownNamesStayUnknown(ctx)
  ctx:assertEqual(output("WH-1000XM5").category, "unknown")
end

function M.testRawDeviceNameIsRemoved(ctx)
  local data = output("Thomas Headphones")

  ctx:assert(data.name == nil, "raw device name must not enter telemetry")
  ctx:assert(data.provider == nil, "diagnostic fields must not enter telemetry")
  ctx:assert(data.driverIndex == nil, "diagnostic fields must not enter telemetry")
  ctx:assert(data.useHardware == nil, "diagnostic fields must not enter telemetry")
  ctx:assert(data.maxBuffers == nil, "diagnostic fields must not enter telemetry")
  ctx:assert(data.caps == nil, "diagnostic fields must not enter telemetry")
  ctx:assertEqual(data.sampleRateHz, 48000)
  ctx:assertEqual(data.speakerMode, "Stereo")
  ctx:assertEqual(data.channels, 2)
end

function M.testMissingDeviceIsNotReported(ctx)
  ctx:assert(hardwareAudio.fromDeviceInfo(nil) == nil)
end

return M
