-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = 'compositorCalibration'
local calibrationBasename = 'compositorCalibration.json'

local function blankData()
  return {
    version = 1,
    styles = {},
  }
end

local function calibrationFile(missionDir)
  if not missionDir then return nil end
  return missionDir .. '/rally/' .. calibrationBasename
end
M.calibrationFile = calibrationFile

local function rangeBounds(value)
  if type(value) ~= 'table' then return nil, nil end
  return tonumber(value.min), value.max ~= nil and tonumber(value.max) or nil
end

local function copyNumericArray(values)
  if type(values) ~= 'table' then return nil end
  local out = {}
  for i, value in ipairs(values) do
    local n = tonumber(value)
    if not n then return nil end
    out[i] = n
  end
  return out
end

function M.boundariesFromList(list, key)
  if not list or #list == 0 then return nil end

  local boundaries = {}
  for i, entry in ipairs(list) do
    local value = entry[key]
    local min, max = rangeBounds(value)
    if not min then return nil end
    if i == 1 and min ~= 0 then return nil end
    if i > 1 then
      local _, prevMax = rangeBounds(list[i - 1][key])
      if prevMax ~= min then return nil end
    end
    if i < #list and not max then return nil end
    boundaries[i] = min
  end

  return boundaries
end

function M.validateBoundaries(boundaries, expectedCount)
  boundaries = copyNumericArray(boundaries)
  if not boundaries then return false end
  if expectedCount and #boundaries ~= expectedCount then return false end
  if #boundaries < 1 then return false end
  if boundaries[1] ~= 0 then return false end

  for i = 2, #boundaries do
    if boundaries[i] <= boundaries[i - 1] then
      return false
    end
  end

  return true
end

function M.applyBoundariesToList(list, key, boundaries)
  if not (list and key and boundaries) then return false end
  boundaries = copyNumericArray(boundaries)
  if not M.validateBoundaries(boundaries, #list) then return false end

  for i, entry in ipairs(list) do
    local nextBoundary = boundaries[i + 1]
    entry[key] = nextBoundary and { min = boundaries[i], max = nextBoundary } or { min = boundaries[i] }
  end
  return true
end

function M.load(missionDir)
  local fname = calibrationFile(missionDir)
  if not (fname and FS:fileExists(fname)) then return blankData() end

  local data = jsonReadFile(fname)
  if type(data) ~= 'table' then
    log('E', logTag, 'Failed to read compositor calibration file: ' .. tostring(fname))
    return blankData()
  end
  data.version = data.version or 1
  data.styles = data.styles or {}
  return data
end

function M.save(missionDir, data)
  local fname = calibrationFile(missionDir)
  if not fname then return false end

  data = data or blankData()
  data.version = data.version or 1
  data.styles = data.styles or {}

  local dir = fname:match("(.*/)")
  if dir then
    FS:directoryCreate(dir, true)
  end

  return jsonWriteFile(fname, data, true)
end

local function styleData(data, compositorName, create)
  if not (data and compositorName) then return nil end
  data.styles = data.styles or {}
  if create and not data.styles[compositorName] then
    data.styles[compositorName] = {}
  end
  return data.styles[compositorName]
end

function M.setBoundaries(missionDir, compositorName, groupName, key, boundaries)
  local data = M.load(missionDir)
  local style = styleData(data, compositorName, true)
  style[groupName] = style[groupName] or {}
  style[groupName][key] = copyNumericArray(boundaries)
  return M.save(missionDir, data)
end

function M.setLengthBoundaries(missionDir, compositorName, intensityName, boundaries)
  local data = M.load(missionDir)
  local style = styleData(data, compositorName, true)
  style.lengthsByIntensity = style.lengthsByIntensity or {}
  style.lengthsByIntensity[intensityName] = style.lengthsByIntensity[intensityName] or {}
  style.lengthsByIntensity[intensityName].arcMeters = copyNumericArray(boundaries)
  return M.save(missionDir, data)
end

function M.applyToConfig(config, compositorName, missionDir)
  if not (config and compositorName and missionDir) then return false end

  local data = M.load(missionDir)
  local style = styleData(data, compositorName, false)
  if not style then return false end

  local corner = config.componentTypes and config.componentTypes.corner
  if not corner then return false end
  local numbering = corner.numbering or corner

  local applied = false
  if numbering.intensity and style.intensity and style.intensity.diameter then
    applied = M.applyBoundariesToList(numbering.intensity, 'diameter', style.intensity.diameter) or applied
  end

  if numbering.lengthsByIntensity and style.lengthsByIntensity then
    for intensityName, saved in pairs(style.lengthsByIntensity) do
      local list = numbering.lengthsByIntensity[intensityName]
      if type(list) == 'table' and type(saved) == 'table' and saved.arcMeters then
        local boundaries = copyNumericArray(saved.arcMeters)
        applied = M.applyBoundariesToList(list, 'arcMeters', boundaries) or applied
      end
    end
  end

  return applied
end

return M
