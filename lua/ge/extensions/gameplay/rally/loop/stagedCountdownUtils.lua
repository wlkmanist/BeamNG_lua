-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local M = {}

function M.getEnvironmentWallClockSecs()
  if not core_environment or not core_environment.getTimeOfDay then return 0 end
  local tod = core_environment.getTimeOfDay()
  if not tod or not tod.time then return 0 end

  return ((tod.time + 0.5) % 1) * 86400
end

function M.getStageCountdownSettings(defaultDuration, defaultMaxAnnounced)
  local settingVisualPacenotes = settings.getValue('rallyVisualPacenotes')
  local settingAudioPacenotes = settings.getValue('rallyAudioPacenotes')

  return {
    duration = defaultDuration,
    maxAnnounced = defaultDuration,
    showVisualCountdown = settingVisualPacenotes or nil,
    playSoundEffects = not settingAudioPacenotes,
    playVoiceCountdown = settingAudioPacenotes or false
  }
end

function M.calculateImmediateMinuteCountdown(duration)
  local launchWindowSecs = duration + 1
  local currentWallClockSecs = M.getEnvironmentWallClockSecs()
  local secondsIntoMinute = currentWallClockSecs % 60
  local secondsToNextMinute = 60 - secondsIntoMinute
  if secondsToNextMinute <= 1e-6 then
    secondsToNextMinute = 60
  end

  local targetWallClockSecs = currentWallClockSecs + secondsToNextMinute

  return {
    environmentStartTimeSecs = (targetWallClockSecs - launchWindowSecs) % 86400,
    epochTime = 0,
    scheduledEventTime = launchWindowSecs,
    targetStartTime = 1,
    timer = launchWindowSecs
  }
end

function M.getWallClockTime(environmentStartTimeSecs, epochTime)
  return ((environmentStartTimeSecs or 0) + (epochTime or 0)) % 86400
end

function M.buildRallyClockData(wallClockSecs)
  return {
    wallClockSecs = wallClockSecs,
    wallClockTime = rallyUtil.formatTime24Hour(wallClockSecs, true, false),
    canSkipTimeControls = false,
    isTimeControlSkipAvailable = false,
    canSkipCountdown = false
  }
end

function M.drawDebugPlane(pos, rot, normals)
  normals = normals or false
  local scale = 10
  local x, y, z = rot * vec3(scale/2,0,0), rot * vec3(0,scale/2,0), rot * vec3(0,0,scale/2)
  local col = color(128, 0, 255, 128)  -- purple
  if normals then
    local axisLength = 4
    -- Y axis (back - plane normal) - Green
    local yEnd = pos + rot * vec3(0, axisLength, 0)
    debugDrawer:drawLineInstance(pos, yEnd, 4, ColorF(0, 1, 0, 1), false)
    debugDrawer:drawTextAdvanced(yEnd, String("back"), ColorF(0, 1, 0, 1), true, false, ColorI(0, 0, 0, 255), false, false)

    -- -Y axis (front) - Red
    local yBackEnd = pos + rot * vec3(0, -axisLength, 0)
    debugDrawer:drawLineInstance(pos, yBackEnd, 4, ColorF(1, 0, 0, 1), false)
    debugDrawer:drawTextAdvanced(yBackEnd, String("front"), ColorF(1, 0, 0, 1), true, false, ColorI(0, 0, 0, 255), false, false)
  end

  debugDrawer:drawSphere(pos, 0.2, ColorF(0.5, 0.0, 1.0, 0.8), true, false)  -- purple
  debugDrawer:drawTriSolid(
    vec3(pos + x + z),
    vec3(pos + x    ),
    vec3(pos - x    ),
    col)
  debugDrawer:drawTriSolid(
    vec3(pos - x    ),
    vec3(pos - x + z),
    vec3(pos + x + z),
    col)
end

function M.drawVehicleToPlaneDebug(vehPos, planePos, rot, tmpPlaneNormal, tmpToVehicle, tmpClosestPoint, tmpMidPoint)
  -- Calculate the plane normal (y-axis since plane is drawn in x-z)
  tmpPlaneNormal:set(0, 1, 0)
  tmpPlaneNormal:set(rot * tmpPlaneNormal)
  tmpPlaneNormal:normalize()

  -- Calculate signed distance from vehicle to plane
  tmpToVehicle:setSub2(vehPos, planePos)
  local signedDistance = tmpToVehicle:dot(tmpPlaneNormal)

  -- Flip sign so back/past is negative, front/before is positive
  signedDistance = -signedDistance

  -- Calculate closest point on plane
  tmpClosestPoint:set(tmpPlaneNormal)
  tmpClosestPoint:setScaled(-signedDistance)
  tmpClosestPoint:setSub2(vehPos, tmpClosestPoint)

  -- Determine colors based on which side we're on
  local sideColor, lineColor, sideName
  if signedDistance < 0 then
    -- Back side (past line)
    sideColor = ColorF(1.0, 0.5, 0.0, 0.8)  -- orange
    lineColor = ColorF(1.0, 0.5, 0.0, 0.6)
    sideName = "past"
  else
    -- Front side (before line)
    sideColor = ColorF(0.0, 1.0, 0.0, 0.8)  -- green
    lineColor = ColorF(0.0, 1.0, 0.0, 0.6)
    sideName = "before"
  end

  -- Draw the closest point on the plane
  debugDrawer:drawSphere(tmpClosestPoint, 0.3, sideColor, true, false)

  -- Draw line from vehicle to closest point on plane
  debugDrawer:drawLineInstance(vehPos, tmpClosestPoint, 4, lineColor, false)

  -- Draw distance text at midpoint
  tmpMidPoint:setAdd2(vehPos, tmpClosestPoint)
  tmpMidPoint:setScaled(0.5)
  debugDrawer:drawTextAdvanced(
    tmpMidPoint,
    String(string.format("%.2fm (%s)", signedDistance, sideName)),
    ColorF(1, 1, 1, 1),
    true, false,
    ColorI(0, 0, 0, 255), false, false
  )
end

function M.drawDebugVehiclePoint(vehPos, inside)
  local color = inside and ColorF(0.0, 1.0, 0.0, 0.8) or ColorF(1.0, 0.0, 0.0, 0.8)
  debugDrawer:drawSphere(vehPos, 0.15, color, true, false)
end

function M.freezeVehicle(vehId, logTag)
  if not vehId then return false end

  local veh = scenetree.findObjectById(vehId)
  if veh then
    core_vehicleBridge.executeAction(veh, 'setFreeze', true)
    log('D', logTag, 'Vehicle frozen (staged)')
    return true
  end
  return false
end

function M.unfreezeVehicle(vehId, logTag)
  if not vehId then return false end

  local veh = scenetree.findObjectById(vehId)
  if veh then
    core_vehicleBridge.executeAction(veh, 'setFreeze', false)
    log('D', logTag, 'Vehicle unfrozen')
    return true
  end
  return false
end

function M.drawMiddleInfo(im, nodeData, formatTimeFromSeconds)
  if not nodeData.useImgui then return end

  -- Show test mode indicator
  if nodeData.test then
    im.TextColored(im.ImVec4(1, 1, 0, 1), "TEST MODE")
  end

  -- Display wall clock
  local wallClockSecs = nodeData.wallClockSecs
  if wallClockSecs then
    local wallClockStr = formatTimeFromSeconds(wallClockSecs)
    im.Text("Wall Clock: " .. wallClockStr)
  end

  -- Display epoch and scheduled time
  local currentEpochTime = nodeData.currentEpochTime
  local scheduledEventTime = nodeData.scheduledEventTime
  if currentEpochTime and scheduledEventTime then
    local timeUntilEvent = scheduledEventTime - currentEpochTime
    local stagingCheckTime = nodeData.stagingCheckTime or 10
    local stagingCheckAt = scheduledEventTime - stagingCheckTime
    local timeUntilStagingCheck = stagingCheckAt - currentEpochTime

    im.Text(string.format("Epoch: %.1fs", currentEpochTime))

    -- Display scheduled event time in wall clock format
    if nodeData.test and nodeData.testInstance and nodeData.testInstance.environmentStartTimeSecs then
      local scheduledWallClockSecs = (nodeData.testInstance.environmentStartTimeSecs + scheduledEventTime) % 86400
      local scheduledWallClockStr = formatTimeFromSeconds(scheduledWallClockSecs)
      im.Text("Event at: " .. scheduledWallClockStr)
    else
      im.Text(string.format("Event at: %.1fs", scheduledEventTime))
    end

    im.Text(string.format("Event in: %.1fs", timeUntilEvent))

    -- Show staging check time only if it's upcoming
    if timeUntilStagingCheck > 0 and timeUntilStagingCheck < stagingCheckTime then
      im.TextColored(im.ImVec4(1, 0.8, 0.2, 1), string.format("Staging check in: %.1fs", timeUntilStagingCheck))
    end
  end

  im.Text("State: " .. nodeData.state)
  im.Text(string.format("Reschedules: %d/%d", nodeData.rescheduleCount, nodeData.maxReschedules or 3))

  -- Display vehicle status
  if nodeData.inZone ~= nil then
    im.Text("In Zone: " .. tostring(nodeData.inZone))
    im.Text("Staged: " .. tostring(nodeData.staged))
  end
end

function M.drawMiddleProgress(im, state, duration, timer, STATE_COUNTDOWN_RUNNING, STATE_FINISHED)
  if state == STATE_COUNTDOWN_RUNNING then
    im.ProgressBar((duration - timer) / duration, im.ImVec2(100,0))
    im.Text("Running")
  elseif state == STATE_FINISHED then
    im.ProgressBar(1, im.ImVec2(100,0))
    im.Text("Done")
  else
    im.ProgressBar(0, im.ImVec2(100,0))
    im.Text("Waiting")
  end
end

return M