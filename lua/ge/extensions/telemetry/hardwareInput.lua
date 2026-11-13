-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function canonicalPidVid(value)
  if type(value) ~= "string" or value == "" then return nil end
  return string.match(value, "^%x%x%x%x%x%x%x%x$") and string.upper(value) or value
end

local function officialEnglishName(pidVid)
  if not pidVid or not string.match(pidVid, "^%x%x%x%x%x%x%x%x$") then return nil end
  local path = "/settings/inputmaps/" .. string.lower(pidVid) .. ".json"
  if not isOfficialContentVPath or not isOfficialContentVPath(path) then return nil end

  local metadata = jsonReadFile(path)
  if type(metadata) ~= "table" then return nil end
  local name = metadata.displayName or metadata.name
  return type(name) == "string" and name ~= "" and name or nil
end

local function mapControls(source)
  if type(source) ~= "table" then return nil, nil end

  local controls = {}
  local counts = {}
  for name, details in pairs(source) do
    local controlType = type(details) == "table" and details.control_type or nil
    if type(name) == "string" and type(controlType) == "string" then
      controls[name] = controlType
      counts[controlType] = (counts[controlType] or 0) + 1
    end
  end
  return next(controls) and controls or nil, next(counts) and counts or nil
end

local function fromControllerInfo(info, englishName)
  local pidVid = canonicalPidVid(info.vidpid)
  local ffbAxes = type(info.ffbAxes) == "table" and next(info.ffbAxes)
    and shallowcopy(info.ffbAxes) or nil
  local result = {
    type = info.type,
    productName = info.type == "wheel" and englishName or info.productName,
    vidpid = pidVid,
    forceFeedback = ffbAxes ~= nil,
  }

  if info.type ~= "wheel" then return result end

  result.productName = englishName or info.productName
  result.reportedName = info.productName
  result.deviceName = info.name
  result.guid = info.guid
  result.hidSupported = info.hidSupported
  result.ffbAxes = ffbAxes
  result.ffbSamplePeriodMicroseconds = info.ff_sample_period
  result.ffbMinTimeResolutionMicroseconds = info.ff_min_time_res
  result.ffbDriverVersion = info.ff_driver_version
  result.hardwareRevision = info.hardware_revision
  result.firmwareRevision = info.firmware_revision
  result.controls, result.controlCounts = mapControls(info.controls)

  if pidVid and string.match(pidVid, "^%x%x%x%x%x%x%x%x$") then
    result.productId = string.sub(pidVid, 1, 4)
    result.vendorId = string.sub(pidVid, 5, 8)
  end
  if type(info.ff_sample_period) == "number" and info.ff_sample_period > 0 then
    result.maxRawFfbUpdateRateHz = 1000000 / info.ff_sample_period
  else
    result.ffbSamplePeriodMicroseconds = nil
  end

  return result
end

local function collect(controllerInfo)
  local devices = {}
  for _, info in ipairs(controllerInfo or {}) do
    local englishName = info.type == "wheel" and officialEnglishName(
      canonicalPidVid(info.vidpid)) or nil
    table.insert(devices, fromControllerInfo(info, englishName))
  end
  return devices
end

M.fromControllerInfo = fromControllerInfo
M.collect = collect
M.officialEnglishName = officialEnglishName

return M
