-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local recordingFreq = 1.0 -- The frequency at which to record the vehicle data, in seconds.
local rdpTol = 3.0 -- The tolerance used when simplifying the nodes of a spline.
local defaultWidth = 10.0 -- The default width for a spline.
local defaultVelLimit = 100.0 -- The default velocity limit for a spline.
local minVelocity = 3.0 -- The minimum velocity for a spline.

local closeTolSq = 4.1 -- The sq. distance tolerance used when testing if two nodes are close to each other, in meters squared.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local splineMgr = require('editor/drivePathEditor/splineMgr')
local rdp = require('editor/toolUtilities/rdp')

-- Module constants.
local max = math.max

-- Module state.
local recordingVehicle = nil
local recordingVehicleName = nil
local recordingPos = {}
local recordingVel = {}
local timer, time, totalTime = hptimer(), 0.0, 0.0


-- Gets the current playback time.
local function getRecordingTime() return totalTime end

-- Handles recording of the current vehicle.
local function handleRecord()
  if not recordingVehicle then
    return -- No vehicle to record.
  end

  -- Update the timer.
  local dt = timer:stopAndReset() * 0.001
  time = time + dt
  totalTime = totalTime + dt

  if time < recordingFreq then
    return -- Not enough time has passed to record a new point.
  end
  time = 0.0 -- Reset the timer, now that we have waited long enough.

  -- Get the current position and velocity of the recording vehicle.
  local pos = vec3(recordingVehicle:getPosition())
  local vel = max(minVelocity, recordingVehicle:getVelocity():length())

  -- Add the current position and velocity to the recording data.
  local idx = #recordingPos + 1
  recordingPos[idx], recordingVel[idx] = pos, vel
end

-- Starts recording with the given vehicle.
local function startRecord(vehicle)
  if vehicle then
    recordingVehicle = vehicle.veh -- Store reference to the recording vehicle.
    recordingVehicleName = vehicle.name -- Store the recording vehicle's name.

    -- Ensure the player is driving the recording vehicle.
    be:enterVehicle(0, vehicle.veh)

    -- Start recording the vehicle.
    table.clear(recordingPos)
    table.clear(recordingVel)
    recordingPos[1] = vec3(recordingVehicle:getPosition())
    recordingVel[1] = max(minVelocity, recordingVehicle:getVelocity():length())

    -- Reset the timers.
    time = 0.0
    totalTime = 0.0
    timer:stopAndReset()
  end
end

-- Stops recording with the given vehicle.
local function stopRecord(sceneVehicles)
  -- Add a new drive path spline to the splines array.
  splineMgr.addNewDrivePathSpline()
  local splines = splineMgr.getDrivePathSplines()
  local spline = splines[#splines]
  spline.name = string.format("Recorded_%s", recordingVehicleName)
  spline.routeSpeedMode = 'off'
  spline.speedProfileMode = 1

  -- Ensure the new spline is linked to the recording vehicle.
  spline.isVehicleLink = true
  spline.linkVehId = recordingVehicle:getId()
  for i = 1, #sceneVehicles do
    local v = sceneVehicles[i]
    if v.vid == spline.linkVehId then
      v.isLink, v.linkSplineId = true, spline.id
      break
    end
  end

  -- Copy the spline nodes and velocities to those of the recorded path.
  table.clear(spline.nodes)
  for i = 1, #recordingPos do
    spline.nodes[i] = vec3(recordingPos[i])
    spline.vels[i] = recordingVel[i]
  end

  -- Remove any duplicate nodes (before RDP simplification).
  local nodes, velocities, ctr = { spline.nodes[1] }, { spline.vels[1] }, 2
  for i = 2, #spline.nodes do
    local p1, p2 = spline.nodes[i - 1], spline.nodes[i]
    if p1:squaredDistance(p2) > closeTolSq then
      nodes[ctr], velocities[ctr] = spline.nodes[i], spline.vels[i]
      ctr = ctr + 1
    end
  end
  spline.nodes, spline.vels = nodes, velocities

  -- Simplify the recorded path.
  rdp.simplifyNodesVels(spline.nodes, spline.vels, rdpTol)

  -- Set the corresponding widths, nmls and velocity limits to default values.
  local pathLength = #spline.nodes
  spline.widths, spline.nmls, spline.velLimits = table.new(pathLength, 0), table.new(pathLength, 0), table.new(pathLength, 0)
  for i = 1, pathLength do
    spline.widths[i], spline.nmls[i], spline.velLimits[i] = defaultWidth, vec3(0, 0, 1), defaultVelLimit
  end

  -- Reset the recording data, ready for next time.
  table.clear(recordingPos)
  table.clear(recordingVel)
  recordingVehicle = nil
  time = 0.0
  totalTime = 0.0
end


-- Public interface.
M.getRecordingTime =                                    getRecordingTime

M.handleRecord =                                        handleRecord

M.startRecord =                                         startRecord
M.stopRecord =                                          stopRecord

return M