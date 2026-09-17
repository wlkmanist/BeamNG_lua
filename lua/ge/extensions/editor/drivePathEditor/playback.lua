-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local rdpTol = 1.0 -- The tolerance used when simplifying the nodes of a spline.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local splineMgr = require('editor/drivePathEditor/splineMgr')
local geom = require('editor/toolUtilities/geom')
local rdp = require('editor/toolUtilities/rdp')

-- Module state.
local playing = {}
local timer, time, totalTime = hptimer(), 0.0, 0.0


-- Gets the current playback time.
local function getPlaybackTime() return totalTime end

-- Starts playback of all linked drive path splines/vehicles.
-- [Adds all vehicles to the playing table if they have a valid link to a spline.]
-- [Note: Execution wont start until the update function is called, where delayTime is used to start the playback.]
local function startPlayback(splines, vehicles)
  table.clear(playing)
  for i = 1, #vehicles do
    local vehicle = vehicles[i]
    if vehicle then
      local spline = nil
      for j = 1, #splines do
        if splines[j].isVehicleLink and splines[j].id == vehicle.linkSplineId and splines[j].linkVehId == vehicle.vid then -- Validity check per spline <-> vehicle.
          spline = splines[j]
          break
        end
      end

      -- Add the vehicle/spline pair to the playing table. Only enabled splines are added.
      if spline and spline.isEnabled then
        local vid = vehicle.vid
        playing[vid] = { spline = spline, vehicle = vehicle, isStarted = false }
        splineMgr.resetVehiclePose(spline, vehicle) -- Move the vehicle to the starting position.
      end
    end
  end
  -- Reset the timers.
  time = 0.0
  totalTime = 0.0
  timer:stopAndReset()
end

-- Stops playback of all linked drive path splines/vehicles, and resets the vehicles to their starting positions.
local function stopPlayback()
  -- Disable the AI for all vehicles in the playing table.
  for _, v in pairs(playing) do
    v.vehicle.veh:queueLuaCommand('ai.setState({mode = "stop"})')
  end

  -- Reset the vehicles to their starting positions.
  for _, d in pairs(playing) do
    splineMgr.resetVehiclePose(d.spline, d.vehicle)
  end

  -- Tidy up for next time.
  table.clear(playing)
  time = 0.0
  totalTime = 0.0
  timer:stopAndReset()
end

-- Handles playback of all the active drive path splines/vehicles.
local function handlePlayback()
  for _, d in pairs(playing) do
    local isStarted = d.isStarted
    if not isStarted then
      local spline, vehicle = d.spline, d.vehicle
      if time >= spline.delayTime then
        local aggression = spline.aggression -- Ensure all properties are in the correct format.
        local routeSpeed = spline.routeSpeed
        local routeSpeedMode = spline.routeSpeedMode or 'off'
        local driveInLane = spline.isDriveInLane and 'on' or 'off'
        local avoidCars = spline.isAvoidCars and 'on' or 'off'
        local noOfLaps = spline.isLoop and spline.numLaps or nil
        local speedProfileMode = spline.speedProfileMode or 0

        -- The execution for this vehicle can now begin, so set it up based on mode.
        if spline.isFreeMode then -- CASE: FREE MODE.
          local nodes, widths, vels, velLimits
          if speedProfileMode == 0 then
            nodes, widths = geom.catmullRomNodesWidthsOnly(spline.nodes, spline.widths, 10, spline.isLoop)
          else
            nodes, widths, vels, velLimits = geom.catmullRomNodesWidthsVelVelLimits(spline, 10)
          end
          for i = 1, #widths do
            widths[i] = widths[i] * 0.5 -- Use half widths.
          end
          if speedProfileMode == 0 then
            rdp.simplifyNodesWidths(nodes, widths, rdpTol)
          else
            rdp.simplifyNodesWidthsVelVelLimits(nodes, widths, vels, velLimits, rdpTol)
          end
          local startIdx = spline.startingNode or 1
          if startIdx < 1 then
            startIdx = 1
          elseif startIdx > #nodes then
            startIdx = #nodes
          end

          if spline.isLoop then
            -- Ensure the emitted script is closed for laps even when startIdx ~= 1.
            nodes[#nodes + 1] = nodes[startIdx]
            widths[#widths + 1] = widths[startIdx]
            if speedProfileMode ~= 0 then
              vels[#vels + 1] = vels[startIdx]
              velLimits[#velLimits + 1] = velLimits[startIdx]
            end
          end

          local scriptParts = {}
          for i = startIdx, #nodes do
            local n = nodes[i]
            if speedProfileMode == 1 then
              table.insert(scriptParts, string.format("{ x = %f, y = %f, z = %f, r = %f, v = %f }", n.x, n.y, n.z, widths[i], vels[i]))
            elseif speedProfileMode == 2 then
              table.insert(scriptParts, string.format("{ x = %f, y = %f, z = %f, r = %f, vl = %f }", n.x, n.y, n.z, widths[i], velLimits[i]))
            else
              table.insert(scriptParts, string.format("{ x = %f, y = %f, z = %f, r = %f }", n.x, n.y, n.z, widths[i]))
            end
          end
          local scriptStr = "{ " .. table.concat(scriptParts, ", ") .. " }"

          -- Create the command for vLua, then execute it.
          local command = string.format([[ai.driveUsingPath{ script = %s%s%s%s%s%s%s }]],
            scriptStr,
            routeSpeedMode ~= 'off' and string.format(', routeSpeedMode = %q', routeSpeedMode) or '',
            routeSpeedMode ~= 'off' and string.format(', routeSpeed = %f', routeSpeed) or '',
            spline.isAvoidCars and string.format(', avoidCars = %q', avoidCars) or '',
            -- driveInLane is only meaningful for wpTargetList pathfinding.
            '',
            string.format(', aggression = %f', aggression),
            noOfLaps and string.format(', noOfLaps = %d', noOfLaps) or ''
          )
          vehicle.veh:queueLuaCommand(command)
        else -- CASE: NAV GRAPH MODE.
          local wpTargetListRaw, velsRaw = spline.graphNodes, spline.vels
          local startIdx = spline.startingNode or 1
          if startIdx < 1 then
            startIdx = 1
          elseif startIdx > #wpTargetListRaw then
            startIdx = #wpTargetListRaw
          end

          local wpTargetList = {}
          local ctr = 1
          for i = startIdx, #wpTargetListRaw do
            wpTargetList[ctr] = wpTargetListRaw[i]
            ctr = ctr + 1
          end

          local wpSpeeds = nil
          if speedProfileMode == 1 then
            wpSpeeds = {}
            for i = 1, #wpTargetList do
              wpSpeeds[wpTargetList[i]] = velsRaw[startIdx + i - 1]
            end
          end

          -- Create the command for vlua, then execute it.
          local luaCmd = string.format([[ai.driveUsingPath{ wpTargetList = %s%s%s%s%s%s%s%s }]],
            serialize(wpTargetList),
            wpSpeeds and string.format(', wpSpeeds = %s', serialize(wpSpeeds)) or '',
            routeSpeedMode ~= 'off' and string.format(', routeSpeedMode = %q', routeSpeedMode) or '',
            routeSpeedMode ~= 'off' and string.format(', routeSpeed = %f', routeSpeed) or '',
            spline.isAvoidCars and string.format(', avoidCars = %q', avoidCars) or '',
            spline.isDriveInLane and string.format(', driveInLane = %q', driveInLane) or '',
            string.format(', aggression = %f', aggression),
            noOfLaps and string.format(', noOfLaps = %d', noOfLaps) or ''
          )
          vehicle.veh:queueLuaCommand(luaCmd)
        end
        d.isStarted = true
      end
    end
  end

  -- Update the timers.
  local dt = timer:stopAndReset() * 0.001
  time = time + dt
  totalTime = totalTime + dt
end


-- Public interface.
M.getPlaybackTime =                                     getPlaybackTime

M.startPlayback =                                       startPlayback
M.stopPlayback =                                        stopPlayback
M.handlePlayback =                                      handlePlayback

return M