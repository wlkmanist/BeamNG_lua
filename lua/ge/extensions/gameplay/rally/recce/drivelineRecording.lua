-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Driveline recording loader - handles loading recorded driveline files
-- A driveline is a series of timestamped position/orientation points recorded during a recce run

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local jsonlUtils = require('/lua/ge/extensions/gameplay/rally/util/jsonlUtils')
local PointList = require('/lua/ge/extensions/gameplay/rally/driveline/pointList')

local M = {}
local logTag = 'drivelineRecording'

-- Load a recorded driveline file and return a PointList
-- Returns: PointList on success, nil on failure
function M.load(missionDir)
  local t_start = rallyUtil.getTime()

  local fname = rallyUtil.drivelineFile(missionDir)

  if not FS:fileExists(fname) then
    log('W', logTag, 'driveline file not found: ' .. fname)
    return nil
  end

  -- Parse each line as a driveline point
  local rawPoints, err = jsonlUtils.parseJsonlFile(fname, function(obj)
    return PointList():createPoint(
      vec3(obj.pos),
      quat(obj.quat),
      obj.ts
    )
  end, rallyUtil)

  if not rawPoints then
    log("E", logTag, "failed to read driveline file: " .. err)
    return nil
  end

  if #rawPoints < 3 then
    log('E', logTag, 'failed to load driveline, not enough points (points='..tostring(#rawPoints)..')')
    return nil
  end

  -- Create PointList and setup relationships/normals
  local pointList = PointList(rawPoints)
  pointList:setupPointRelationships()
  pointList:setupPointNormals()

  local t_load = rallyUtil.getTime() - t_start

  log('I', logTag, 'loaded driveline in '.. string.format("%.3f", t_load)..'s with '..tostring(#rawPoints)..' points')

  return pointList
end

return M

