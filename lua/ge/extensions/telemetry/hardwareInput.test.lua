-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("hardwareInput")

local M = {}
local hardwareInput = require("ge/extensions/telemetry/hardwareInput")

local function wheel(samplePeriod)
  return {
    name = "wheel0",
    productName = "Volant de course G923",
    vidpid = "c266046d",
    guid = "{C266046D-0000-0000-0000-504944564944}",
    type = "wheel",
    ff_sample_period = samplePeriod,
    ff_min_time_res = 500,
    ff_driver_version = 65538,
    hardware_revision = 3,
    firmware_revision = 4,
    hidSupported = true,
    ffbAxes = {xaxis = 0},
    controls = {
      xaxis = {control_type = "axis"},
      yaxis = {control_type = "axis"},
      button0 = {control_type = "button"},
      pov0 = {control_type = "pov"},
    },
  }
end

function M.testMapsEveryAvailableWheelField(ctx)
  local result = hardwareInput.fromControllerInfo(
    wheel(1000), "Logitech G923 Racing Wheel")

  ctx:assertEqual(result.type, "wheel")
  ctx:assertEqual(result.productName, "Logitech G923 Racing Wheel")
  ctx:assertEqual(result.reportedName, "Volant de course G923")
  ctx:assertEqual(result.deviceName, "wheel0")
  ctx:assertEqual(result.vidpid, "C266046D")
  ctx:assertEqual(result.productId, "C266")
  ctx:assertEqual(result.vendorId, "046D")
  ctx:assertEqual(result.guid, "{C266046D-0000-0000-0000-504944564944}")
  ctx:assertEqual(result.forceFeedback, true)
  ctx:assertEqual(result.ffbSamplePeriodMicroseconds, 1000)
  ctx:assertEqual(result.maxRawFfbUpdateRateHz, 1000)
  ctx:assertEqual(result.ffbMinTimeResolutionMicroseconds, 500)
  ctx:assertEqual(result.ffbDriverVersion, 65538)
  ctx:assertEqual(result.hardwareRevision, 3)
  ctx:assertEqual(result.firmwareRevision, 4)
  ctx:assertEqual(result.hidSupported, true)
  ctx:assertEqual(result.ffbAxes.xaxis, 0)
  ctx:assertEqual(result.controls.xaxis, "axis")
  ctx:assertEqual(result.controlCounts.axis, 2)
  ctx:assertEqual(result.controlCounts.button, 1)
  ctx:assertEqual(result.controlCounts.pov, 1)
end

function M.testUnknownDefaultUpdateRateStaysAbsent(ctx)
  local result = hardwareInput.fromControllerInfo(wheel(0))

  ctx:assert(result.ffbSamplePeriodMicroseconds == nil)
  ctx:assert(result.maxRawFfbUpdateRateHz == nil)
  ctx:assertEqual(result.productName, "Volant de course G923")
end

function M.testEnglishNameComesOnlyFromOfficialInputMap(ctx)
  local previousOfficial = isOfficialContentVPath
  local previousRead = jsonReadFile
  local readPath
  isOfficialContentVPath = function() return true end
  jsonReadFile = function(path)
    readPath = path
    return {name = "Logitech G923 Racing Wheel"}
  end

  local name = hardwareInput.officialEnglishName("C266046D")

  isOfficialContentVPath = previousOfficial
  jsonReadFile = previousRead
  ctx:assertEqual(readPath, "/settings/inputmaps/c266046d.json")
  ctx:assertEqual(name, "Logitech G923 Racing Wheel")
end

function M.testUnofficialInputMapCannotSupplyTelemetryName(ctx)
  local previousOfficial = isOfficialContentVPath
  local previousRead = jsonReadFile
  isOfficialContentVPath = function() return false end
  jsonReadFile = function() error("must not read unofficial input map") end

  local name = hardwareInput.officialEnglishName("C266046D")

  isOfficialContentVPath = previousOfficial
  jsonReadFile = previousRead
  ctx:assert(name == nil)
end

function M.testNonWheelsKeepOnlyCommonIdentity(ctx)
  local info = wheel(1000)
  info.name = "xinput0"
  info.productName = "Controller"
  info.type = "xinput"

  local result = hardwareInput.fromControllerInfo(info, "Ignored English name")

  ctx:assertEqual(result.productName, "Controller")
  ctx:assertEqual(result.vidpid, "C266046D")
  ctx:assertEqual(result.forceFeedback, true)
  ctx:assert(result.reportedName == nil)
  ctx:assert(result.deviceName == nil)
  ctx:assert(result.controls == nil)
  ctx:assert(result.ffbDriverVersion == nil)
end

function M.testSymbolicDeviceIdentityKeepsItsCase(ctx)
  local result = hardwareInput.fromControllerInfo({
    type = "xinput",
    productName = "Controller",
    vidpid = "XIDevice",
  })

  ctx:assertEqual(result.vidpid, "XIDevice")
end

return M
