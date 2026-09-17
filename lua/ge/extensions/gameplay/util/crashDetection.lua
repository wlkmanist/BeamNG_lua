-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
M.dependencies =  {"gameplay_util_damageAssessment"}

local pow = math.pow
local abs = math.abs
local sqrt = math.sqrt
local im = ui_imgui

local plotHelperUtil
local debugDamageAssessmentUIPtr = im.BoolPtr(false)

local debug = false

local trackedVehIds = {}

-- GC
local newFrameDamage = {}

local dtSim

-- General crash settings
local minFrameDamageThreshold = 40
local stopCrashDelay = 1.8
local maxImpactDuration = 0.3

-- Debug color constants
local GreenTransparent = ColorF(0, 1, 0, 0.5)
local RedTransparent = ColorF(1, 0, 0, 0.5)
local BlueTransparent = ColorF(0, 0, 1, 0.5)
local WhiteTransparent = ColorF(1, 1, 1, 0.5)
local White = ColorF(1, 1, 1, 1)
local Black = ColorF(0, 0, 0, 1)
local BlackBackground = ColorI(0, 0, 0, 255)

-- Debug
local maxAccelHistory = 50
local debugHistoryTimer = 0
local debugHistorySamplesPerSec = 10
local debugSelectedVehicleIndex = im.IntPtr(0)


local function resetCurrentCrashData(vehId)
  if not trackedVehIds[vehId] then return end

  trackedVehIds[vehId].totalCrashTime = 0
  trackedVehIds[vehId].isCrashing = false
  trackedVehIds[vehId].currentCrashImpacts = nil
  trackedVehIds[vehId].totalCurrentImpactDamage = 0
end

local function resetCurrentImpactData(vehId)
  if not trackedVehIds[vehId] then return end

  if trackedVehIds[vehId].currentImpactData then
    trackedVehIds[vehId].currentImpactData = nil
    trackedVehIds[vehId].totalCurrentImpactDamage = 0
  end
end

local function resetPreImpactData(vehId)
  if not trackedVehIds[vehId] then return end

  trackedVehIds[vehId].mightBeCrashing = false
  if trackedVehIds[vehId].preImpactData then
    trackedVehIds[vehId].preImpactData = nil
    trackedVehIds[vehId].totalPreImpactDamage = 0
  end
end

local function resetAllVehData(vehId)
  resetCurrentCrashData(vehId)
  resetCurrentImpactData(vehId)
  resetPreImpactData(vehId)
end

local function onCrashStarted(crashData)
  local sanitizedCrashData = {
    vehId = crashData.vehId,
    vehImpactPos = crashData.currentImpactData.frameDamages[1].vehPos,
    vehImpactSpeed = crashData.currentImpactData.frameDamages[1].speed,
  }

  crashData.debug.eventFlags.crashStarted = true

  extensions.hook("onVehicleCrashStarted", sanitizedCrashData)
end

local function onNewImpactStarted(crashData)
  crashData.debug.eventFlags.impactStarted = true

  if not crashData.currentCrashImpacts then
    onCrashStarted(crashData)
  else
    extensions.hook("onNewImpactStarted",
      {
        newImpactData = crashData.currentImpactData,
      }
    )
  end
end

local tempVeh = {}
local tempVehName = ""
local tempAveragePos = vec3()
local function onImpactEnded(crashData)
  crashData.debug.eventFlags.impactEnded = true

  -- calculate some stats about the impact / sanitize the data
  tempAveragePos:set(0, 0, 0)
  local totalDamage = 0
  for _, frameDamage in pairs(crashData.currentImpactData.frameDamages) do
    tempAveragePos:setAdd(frameDamage.vehPos)
    totalDamage = totalDamage + frameDamage.newDamage
    for vehId, _ in pairs(frameDamage.touchedVehIds) do
      tempVeh = be:getObjectByID(vehId)
      tempVehName = "Despawned"
      if tempVeh then
        tempVehName = tempVeh.jbeam
      end
      crashData.currentImpactData.touchedVehIds[vehId] = {
        name = tempVehName
      }
    end
  end
  tempAveragePos:set(tempAveragePos / #crashData.currentImpactData.frameDamages)
  crashData.currentImpactData.averagePos = tempAveragePos
  crashData.currentImpactData.totalDamage = totalDamage
  crashData.currentImpactData.impactSpeed = crashData.currentImpactData.frameDamages[1].speed
  if crashData.crashSettings.enableImpactLocationData then
    crashData.currentImpactData.damageStateDiff = gameplay_util_damageAssessment.getTextualCollisionDamageLocations({oldSectionsDamageRaw = crashData.currentImpactData.startingDamageState, vehId = crashData.vehId})
  end

  if not crashData.currentCrashImpacts then
    crashData.currentCrashImpacts = {}
  end
  table.insert(crashData.currentCrashImpacts, crashData.currentImpactData)
  resetCurrentImpactData(crashData.vehId)
  resetPreImpactData(crashData.vehId)
end


local function onCrashEnded(crashData)
  crashData.debug.eventFlags.crashEnded = true

  -- aggregate/sanitize every impacts data
  local sanitizedCrashData = {
    impacts = crashData.currentCrashImpacts,
    sanitizedData = {
      touchedVehIds = {},
      initialImpactPos = crashData.currentCrashImpacts[1].frameDamages[1].vehPos,
      initialImpactSpeed = crashData.currentCrashImpacts[1].frameDamages[1].speed,
    },
    totalDamage = 0,
    vehId = crashData.vehId,
  }

  for _, impact in pairs(crashData.currentCrashImpacts) do
    if impact.touchedVehIds then
      for vehId, vehData in pairs(impact.touchedVehIds) do
        sanitizedCrashData.sanitizedData.touchedVehIds[vehId] = vehData
      end
    end
    for _, frameDamage in pairs(impact.frameDamages) do
      sanitizedCrashData.totalDamage = sanitizedCrashData.totalDamage + frameDamage.newDamage
    end
  end

  extensions.hook("onVehicleCrashEnded", sanitizedCrashData)

  resetCurrentCrashData(crashData.vehId)
end


local function populateDebugHistory(vehData, crashDamageThreshold, totalImpactDamage, peakAccel, peakAccelVerticallyUnweighted, jerk)
  -- update debug histories when debug is enabled
  if debug then
    debugHistoryTimer = debugHistoryTimer + dtSim * debugHistorySamplesPerSec
    if debugHistoryTimer > 1 then
      local crashData = trackedVehIds[vehData.id]
      if crashData and crashData.debug then
        -- add new data points to each debug history
        table.insert(crashData.debug.histories.accel.data, 1, peakAccel or 0)
        table.insert(crashData.debug.histories.accelVerticallyUnweighted.data, 1, peakAccelVerticallyUnweighted or 0)
        table.insert(crashData.debug.histories.threshold.data, 1, crashDamageThreshold)
        table.insert(crashData.debug.histories.damage.data, 1, totalImpactDamage)
        table.insert(crashData.debug.histories.jerk.data, 1, jerk)

        -- add event flags (1 if event occurred this frame, 0 otherwise)
        table.insert(crashData.debug.histories.crashStarted.data, 1, crashData.debug.eventFlags.crashStarted and 1 or 0)
        table.insert(crashData.debug.histories.crashEnded.data, 1, crashData.debug.eventFlags.crashEnded and 1 or 0)
        table.insert(crashData.debug.histories.impactStarted.data, 1, crashData.debug.eventFlags.impactStarted and 1 or 0)
        table.insert(crashData.debug.histories.impactEnded.data, 1, crashData.debug.eventFlags.impactEnded and 1 or 0)

        -- remove oldest entries if we exceed max history
        for _, historyData in pairs(crashData.debug.histories) do
          if historyData.data and historyData.data[maxAccelHistory] then
            historyData.data[maxAccelHistory] = nil
          end
        end

        -- reset event flags after recording
        crashData.debug.eventFlags.crashStarted = false
        crashData.debug.eventFlags.crashEnded = false
        crashData.debug.eventFlags.impactStarted = false
        crashData.debug.eventFlags.impactEnded = false
      end

      debugHistoryTimer = debugHistoryTimer - 1
    end
  end
end

local function calculateAccels(crashData)
  local frontPoint = crashData.accelData.front
  local rearPoint = crashData.accelData.rear

  if not frontPoint.accel or not rearPoint.accel then return end

  local finalAccel
  local peakAccel = (frontPoint.peakAccel + rearPoint.peakAccel) / 2
  local peakAccelVerticallyUnweighted = (frontPoint.peakAccelVerticallyUnweighted + rearPoint.peakAccelVerticallyUnweighted) / 2

  if crashData.crashSettings.verticallyUnweighted then
    finalAccel = peakAccelVerticallyUnweighted
  else
    finalAccel = peakAccel
  end

  local jerk = 0
  if crashData.lastFrameAccel then
    jerk = math.abs((finalAccel - crashData.lastFrameAccel) / dtSim / 40)
  end
  crashData.lastFrameAccel = finalAccel

  return peakAccel, peakAccelVerticallyUnweighted, jerk
end

local function getNewImpactData()
  return {
    frameDamages = {},
    touchedVehIds = {},
  }
end

local function initiatePreImpactData(crashData)
  crashData.preImpactData = getNewImpactData()

  if crashData.crashSettings.enableImpactLocationData then
    crashData.preImpactData.startingDamageState = gameplay_util_damageAssessment.getSectionsDamageInfoRaw(crashData.vehId)
  end
end

local function initiateCurrentImpactData(crashData)
  crashData.currentImpactData = getNewImpactData()
end

-- transvase preImpactData to currentImpactData
local function populateImpactDataWithPreImpactData(crashData)
  for _, frameDamage in pairs(crashData.preImpactData.frameDamages) do
    table.insert(crashData.currentImpactData.frameDamages, frameDamage)
  end
  crashData.currentImpactData.startingDamageState = crashData.preImpactData.startingDamageState
  crashData.totalCurrentImpactDamage = crashData.totalCurrentImpactDamage + crashData.totalPreImpactDamage
  crashData.totalPreImpactDamage = 0
  crashData.preImpactData = nil
end

local function getTotalImpactDamage(crashData)
  return crashData.totalPreImpactDamage + crashData.totalCurrentImpactDamage
end

local function managedImpactAndDetectImpacts(vehData)
  local crashData = trackedVehIds[vehData.id]
  if not crashData or not vehData.damage then return end

  local damageSum = scenetree.findObjectById(crashData.vehId):getSectionDamageSum() or 0

  if damageSum > crashData.lastFrameDamageSum or vehData.damage >  crashData.lastFrameDamage then

    local newDamage = vehData.damage - crashData.lastFrameDamage -- old API is more consistent
    local newDamageSum = damageSum - crashData.lastFrameDamageSum -- new API is more sensitive/triggers a few frames earlier, detects "scraches"

    local totalImpactDamage = getTotalImpactDamage(crashData)
    local peakAccel, peakAccelVerticallyUnweighted, jerk = calculateAccels(crashData)
    local crashDamageThreshold = linearScale(jerk, crashData.crashSettings.minAccel, crashData.crashSettings.maxAccel, crashData.crashSettings.maxDamage, crashData.crashSettings.minDamage)

    populateDebugHistory(vehData, crashDamageThreshold, totalImpactDamage, peakAccel, peakAccelVerticallyUnweighted, jerk)
    table.clear(newFrameDamage)
    newFrameDamage.time = crashData.totalCrashTime
    newFrameDamage.newDamageSum = newDamageSum
    newFrameDamage.newDamage = newDamage
    newFrameDamage.vehPos = vec3(vehData.pos.x, vehData.pos.y, vehData.pos.z)
    newFrameDamage.vehId = vehData.id
    newFrameDamage.touchedVehIds = vehData.objectCollisions
    newFrameDamage.speed = math.floor(vehData.vel:length() * 3.6 + 0.5)
    newFrameDamage.isAboveDamageThreshold = newDamage > minFrameDamageThreshold or newDamageSum > minFrameDamageThreshold

    if totalImpactDamage < crashDamageThreshold then -- if the new damage is too small, we don't consider it an impact, but it might become one
      if not crashData.preImpactData then
        initiatePreImpactData(crashData)
      end

      table.insert(crashData.preImpactData.frameDamages, deepcopy(newFrameDamage))
      crashData.totalPreImpactDamage = crashData.totalPreImpactDamage + newFrameDamage.newDamage
      crashData.mightBeCrashing = true
    else
      if not crashData.currentImpactData then
        initiateCurrentImpactData(crashData)

        if crashData.preImpactData then
          populateImpactDataWithPreImpactData(crashData)
        end

        table.insert(crashData.currentImpactData.frameDamages, deepcopy(newFrameDamage))
        crashData.totalCurrentImpactDamage = crashData.totalCurrentImpactDamage + newFrameDamage.newDamage
        onNewImpactStarted(crashData)
      else
        table.insert(crashData.currentImpactData.frameDamages, deepcopy(newFrameDamage))
        crashData.totalCurrentImpactDamage = crashData.totalCurrentImpactDamage + newFrameDamage.newDamage
      end
    end
  end

  crashData.lastFrameDamage = vehData.damage
  crashData.lastFrameDamageSum = damageSum -- new API is more sensitive/triggers a few frames sooner
end


local function logicDuringCrash(vehData)
  local crashData = trackedVehIds[vehData.id]
  if not crashData then return end

  crashData.isCrashing = crashData.currentCrashImpacts ~= nil

  -- run a timer
  if crashData.mightBeCrashing or crashData.isCrashing then
    crashData.totalCrashTime = crashData.totalCrashTime + dtSim
  end
end


local function checkIfCrashEnded(vehData)
  local crashData = trackedVehIds[vehData.id]
  if not crashData then return end

  local latestImpactTime
  if crashData.currentCrashImpacts then --currentCrashImpacts are only added when the impact is finished
    local latestImpact = crashData.currentCrashImpacts[#crashData.currentCrashImpacts]
    latestImpactTime = latestImpact.frameDamages[#latestImpact.frameDamages].time
  end

  -- Check if crash should end
  if latestImpactTime then
    local timeSinceLastImpact = crashData.totalCrashTime - latestImpactTime
    if timeSinceLastImpact >= stopCrashDelay or vehData.vel:length() < crashData.crashSettings.minVelocity then
      onCrashEnded(crashData)
    end
  end
end

local function checkIfImpactEnded(vehData)
  local crashData = trackedVehIds[vehData.id]
  if crashData and crashData.currentImpactData then
    local latestFrameDamageTime = crashData.currentImpactData.frameDamages[#crashData.currentImpactData.frameDamages].time

    -- distance, velocity and time check between the vehicle and the last frame damage
    local dist = vehData.pos:distance(crashData.currentImpactData.frameDamages[#crashData.currentImpactData.frameDamages].vehPos)
    if dist > crashData.crashSettings.groupImpactsDist or
    (vehData.vel:length() < crashData.crashSettings.minVelocity and
    crashData.totalCrashTime - latestFrameDamageTime > maxImpactDuration) then
      onImpactEnded(crashData)
    end
  end
end

local function checkIfPreImpactEnded(vehData)
  local crashData = trackedVehIds[vehData.id]
  if not crashData then return end

  if crashData.preImpactData and not crashData.currentImpactData then
    local latestFrameDamageTime = crashData.preImpactData.frameDamages[#crashData.preImpactData.frameDamages].time

    -- distance, velocity and time check between the vehicle and the last frame damage
    local dist = vehData.pos:distance(crashData.preImpactData.frameDamages[#crashData.preImpactData.frameDamages].vehPos)
    if dist > crashData.crashSettings.groupImpactsDist or
    (vehData.vel:length() < crashData.crashSettings.minVelocity and
    crashData.totalCrashTime - latestFrameDamageTime > maxImpactDuration) then
      resetPreImpactData(crashData.vehId)
    end
  end
end
-- verticallyUnweighted : sometimes we want to make it so that the vertical acceleration is weighted less for crash calculations
local function getPeakAccel(accelVec, verticallyUnweighted)
  if verticallyUnweighted == nil then verticallyUnweighted = false end
  return abs(abs(accelVec.x) + abs(accelVec.y) + abs(accelVec.z) * (verticallyUnweighted and 0.3 or 1))
end

local tempVecCurrVel = vec3()
local tempVecCurrAccel = vec3()
local tempVecPos = vec3()
local function updateAccelData(vehData)
  local crashData = trackedVehIds[vehData.id]
  if not crashData then return end

  -- using two arbitrary points to get a more accurate acceleration reading
  for _, point in pairs(crashData.accelData) do
    tempVecPos:set(vehData.pos + point.offsetFromCenter * vehData.dirVec)
    tempVecCurrVel:set((point.lastFramePos and (tempVecPos - point.lastFramePos) or vec3()) / dtSim)
    tempVecCurrAccel:set((point.lastFrameVel and (tempVecCurrVel - point.lastFrameVel) or vec3()) / dtSim)

    if not point.smootherAcc then
      point.smootherAcc = newTemporalSmoothing(700, 700)
    end

    point.lastFrameVel:set(tempVecCurrVel)
    point.lastFramePos:set(tempVecPos)

    point.vel:set(tempVecCurrVel)

    local accel = abs(point.smootherAcc:getUncapped(sqrt(square(tempVecCurrAccel.x) + square(tempVecCurrAccel.y) + square(tempVecCurrAccel.z)), dtSim))

    point.accel = accel
    point.peakAccel = getPeakAccel(tempVecCurrAccel, false)
    point.peakAccelVerticallyUnweighted = getPeakAccel(tempVecCurrAccel, true)
  end
end

local function drawImGuiWindow()
  if im.Begin("Crash Detection Debug") then
    -- Graph setup
    plotHelperUtil = plotHelperUtil or require('/lua/ge/extensions/editor/util/plotHelperUtil')()

    -- Create vehicle selector combo box
    local vehicleList = {}
    local vehicleListStr = ""
    for vehId, crashData in pairs(trackedVehIds) do
      if crashData.debug then
        local veh = getObjectByID(vehId)
        if veh then
          local vehJbeam = veh.jbeam
          table.insert(vehicleList, vehId)
          vehicleListStr = vehicleListStr .. tostring(vehId) .. " (" .. vehJbeam .. ") | " .. crashData.owner .. "\0"
        end
      end
    end

    -- Static variable to store selected vehicle index
    if not debugSelectedVehicleIndex then
      debugSelectedVehicleIndex = im.IntPtr(0)
    end

    if #vehicleList > 0 then
      -- Add vehicle selector and exit debug button on same line
      im.PushItemWidth(im.GetContentRegionAvailWidth() - 200) -- Reserve space for button
      im.Combo2("Select Vehicle", debugSelectedVehicleIndex, vehicleListStr)
      im.PopItemWidth()

      im.SameLine()
      if im.Button("Exit Debug") then
        M.setDebug(false)
        gameplay_util_damageAssessment.setDebug(false)
      end

      im.Dummy(im.ImVec2(1, 10))

      local selectedVehId = vehicleList[debugSelectedVehicleIndex[0] + 1]
      if selectedVehId and trackedVehIds[selectedVehId] and trackedVehIds[selectedVehId].debug then

        if trackedVehIds[selectedVehId].crashSettings.enableImpactLocationData then
          if im.Checkbox("Toggle damage assessment UI", debugDamageAssessmentUIPtr) then
            gameplay_util_damageAssessment.setDebug(debugDamageAssessmentUIPtr[0])
          end
        end

        local crashData = trackedVehIds[selectedVehId]

        -- Graph enable checkboxes
        im.Dummy(im.ImVec2(1, 5))
        im.Text("Graph Visibility:")
        im.Checkbox("Graph 1: Acceleration", crashData.debug.graphEnabled[1])
        im.SameLine()
        im.Checkbox("Graph 2: Jerk", crashData.debug.graphEnabled[2])
        im.Checkbox("Graph 3: Threshold/Damage", crashData.debug.graphEnabled[3])
        im.SameLine()
        im.Checkbox("Graph 4: Events", crashData.debug.graphEnabled[4])
        im.Dummy(im.ImVec2(1, 5))

        -- Group debug histories by graphNumber
        local graphGroups = {}
        local maxGraphNumber = 0
        for historyName, historyData in pairs(crashData.debug.histories) do
          if historyData.graphNumber and historyData.data then
            local graphNum = historyData.graphNumber
            maxGraphNumber = math.max(maxGraphNumber, graphNum)

            if not graphGroups[graphNum] then
              graphGroups[graphNum] = {}
            end

            table.insert(graphGroups[graphNum], {
              name = historyName,
              data = historyData.data,
              color = historyData.color,
              displayName = historyData.name or historyName
            })
          end
        end

        -- Draw graphs dynamically based on graphNumber
        for graphNum = 1, maxGraphNumber do
          if graphGroups[graphNum] and crashData.debug.graphEnabled[graphNum][0] then
            im.BeginChild1("Graph " .. graphNum .. "##" .. selectedVehId, im.ImVec2(im.GetContentRegionAvailWidth(), 300), true)

            -- Show legend with colored text
            for _, series in ipairs(graphGroups[graphNum]) do
              if series.color then
                im.PushStyleColor2(im.Col_Text, im.ImVec4(series.color[1], series.color[2], series.color[3], series.color[4] or 1))
                im.TextWrapped(series.displayName)
                im.PopStyleColor()
              end
            end

            -- Prepare chart data
            local chartData = {}
            local chartColors = {}
            local maxDataLength = 0

            for seriesIndex, series in ipairs(graphGroups[graphNum]) do
              chartData[seriesIndex] = {}
              chartColors[seriesIndex] = series.color
              maxDataLength = math.max(maxDataLength, #series.data)

              for i = 1, #series.data do
                chartData[seriesIndex][i] = {i, series.data[i]}
              end
            end

            if maxDataLength > 0 then
              plotHelperUtil:setDataMulti(chartData)
              plotHelperUtil:setSeriesColors(chartColors)
              plotHelperUtil:scaleToFitData()
              plotHelperUtil:setScale(nil, nil, 0, nil)
              plotHelperUtil:draw(im.GetContentRegionAvailWidth(), im.GetContentRegionAvail().y, 400)
            end

            im.EndChild()
          end
        end
      end

      im.Dummy(im.ImVec2(1, 10))
      im.Text("Is crashing: " .. tostring(trackedVehIds[selectedVehId].isCrashing))
      im.Text("Is using vertically unweighted accel: " .. tostring(trackedVehIds[selectedVehId].crashSettings.verticallyUnweighted))
    else
      im.Text("No vehicles being tracked")
    end
  end
  im.End()
end

local function drawDebug(vehData)
  local crashData = trackedVehIds[vehData.id]
  if not crashData then return end

  if crashData.currentCrashImpacts then
    for impactIndex, impactData in pairs(crashData.currentCrashImpacts) do
      -- draw the start of impact

      debugDrawer:drawSphere(impactData.frameDamages[1].vehPos, 0.4, GreenTransparent)
      debugDrawer:drawTextAdvanced(impactData.frameDamages[1].vehPos, string.format("#%i Impact speed: %i kph", impactIndex, impactData.impactSpeed), White, true, false, BlackBackground, false, false)
      -- draw the end of impact
      debugDrawer:drawSphere(impactData.frameDamages[#impactData.frameDamages].vehPos, 0.4, RedTransparent)
      debugDrawer:drawTextAdvanced(impactData.frameDamages[#impactData.frameDamages].vehPos, string.format("#%i Damage: %i", impactIndex, impactData.totalDamage), White, true, false, BlackBackground, false, false)
      if impactData.damageStateDiff then
        debugDrawer:drawTextAdvanced(impactData.frameDamages[#impactData.frameDamages].vehPos, impactData.damageStateDiff.mostDamagedLocation, White, true, false, BlackBackground, false, false)
      end

      -- draw average position of the impact
      debugDrawer:drawSphere(impactData.averagePos, 0.25, BlueTransparent)
      debugDrawer:drawTextAdvanced(impactData.averagePos, string.format("#%i", impactIndex), White, true, false, BlackBackground, false, false)

      -- draw every frame damage
      for frameDamageIndex, frameDamageImpact in pairs(impactData.frameDamages) do
        if frameDamageImpact.isAboveDamageThreshold then
          debugDrawer:drawSphere(frameDamageImpact.vehPos, 0.1, WhiteTransparent)
        end
        debugDrawer:drawText(frameDamageImpact.vehPos, string.format("%i", frameDamageImpact.newDamage), Black, false, false)
        --debugDrawer:drawTextAdvanced(impact.vehPos, string.format("#%i | %i damage | %i kph | %0.2f s", impactIndex, impact.newDamage, impact.speed, impact.time), ColorF(1,1,1,1), true, false, ColorI(0, 0, 0, 255))
      end
    end
  end
end

local currVehData
local vehIdList = {}
local function onUpdate(dtReal, _dtSim)

  dtSim = _dtSim
  if not trackedVehIds then return end

  table.clear(vehIdList)
  for vehId, _ in pairs(trackedVehIds) do
    table.insert(vehIdList, vehId)
  end

  for i = #vehIdList, 1, -1 do
    local vehId = vehIdList[i]
    currVehData = map.objects[vehId]
    if not currVehData then
      trackedVehIds[vehId] = nil -- remove if the vehicle doesn't exist anymore
    else
      updateAccelData(currVehData)
      logicDuringCrash(currVehData)

      managedImpactAndDetectImpacts(currVehData)
      checkIfPreImpactEnded(currVehData)
      checkIfImpactEnded(currVehData)
      checkIfCrashEnded(currVehData)
      if debug then
        drawDebug(currVehData)
      end
    end
  end

  if debug then
    drawImGuiWindow()
  end
end

local function addTrackedVehicleById(vehId_, crashSettings, owner)
  if vehId_ == nil or vehId_ < 0 then
    --log('W', 'crashDetection', "Cannot add a vehicle with a nil or negative ID")
    return
  end

  local vehMapObject = map.objects[vehId_]
  if not vehMapObject then
    --log('W', 'crashDetection', "Didn't find vehicle with id " .. vehId_)
    return
  end
  -- can make the crash detection more sensitive by tweaking these values
  local crashSettings = crashSettings or {}
  crashSettings.minAccel = 0
  crashSettings.maxAccel = crashSettings.maxAccel or 100
  crashSettings.minDamage = 150
  crashSettings.maxDamage = crashSettings.maxDamage or 5000
  crashSettings.verticallyUnweighted = crashSettings.verticallyUnweighted or false
  crashSettings.minVelocity = crashSettings.minVelocity or 1
  crashSettings.groupImpactsDist = math.max(0.1, crashSettings.groupImpactsDist or 1)
  crashSettings.enableImpactLocationData = crashSettings.enableImpactLocationData or false

  trackedVehIds[vehId_] = {
    debug = {
      histories = {
        jerk = {graphNumber = 2, color = {0.1, 0.5, 1, 1}, name = "Accel Jerk", data = {}},
        accel = {graphNumber = 1,color = {0.2, 1, 0.1, 1}, name = "Accel", data = {}},
        accelVerticallyUnweighted = {graphNumber = 1, color = {1, 0.1, 0.1, 1}, name = "Accel Vertically Unweighted (Road bump removal)", data = {}},
        threshold = {graphNumber = 3, color = {0.2, 1, 0.1, 1}, name = "Damage Threshold to detect impact. Goes down with acceleration", data = {}},
        damage = {graphNumber = 3, color = {1, 0.1, 0.1, 1}, name = "Impact Damage. If exceeds threshold, impact is detected", data = {}},
        crashStarted = {graphNumber = 4, color = {0, 0, 1, 1}, name = "Crash Started", data = {}},
        crashEnded = {graphNumber = 4, color = {1, 1, 1, 1}, name = "Crash Ended", data = {}},
        impactStarted = {graphNumber = 4, color = {0, 1, 0, 1}, name = "Impact Started", data = {}},
        impactEnded = {graphNumber = 4, color = {1, 0, 0, 1}, name = "Impact Ended", data = {}},
      },
      eventFlags = {
        crashStarted = false,
        crashEnded = false,
        impactStarted = false,
        impactEnded = false,
      },
      graphEnabled = {
        [1] = im.BoolPtr(false),  -- Acceleration graphs
        [2] = im.BoolPtr(false),  -- Jerk graph
        [3] = im.BoolPtr(true),  -- Threshold/Damage graphs
        [4] = im.BoolPtr(false),  -- Event graphs
      }
    },

    --currentCrashImpacts = {
      --  (impacts) {},{},{},{},{},
    --},
    --preImpactData = {}, -- because there is a minimum damage threshold to what is considered an impact, and that we want accurate data about the starting conditions (position, speed..)

    totalCrashTime = 0,
    vehId = vehId_,
    owner = owner or "unknown",
    crashSettings = crashSettings,
    lastFrameDamage = vehMapObject.damage or 0,
    lastFrameDamageSum = scenetree.findObjectById(vehId_):getSectionDamageSum() or 0,
    totalPreImpactDamage = 0,
    totalCurrentImpactDamage = 0,
    mightBeCrashing = false,
    isCrashing = false,
    accelData  = {
      front = {
        offsetFromCenter = 4, -- arbitrary offset from the center of the vehicle
        lastFrameVel = vec3(),
        lastFramePos = vec3(),
        vel = vec3(),
      },
      rear = {
        offsetFromCenter = -4, -- arbitrary offset from the center of the vehicle
        lastFrameVel = vec3(),
        lastFramePos = vec3(),
        vel = vec3(),
      }
    }
  }

end

local function removeTrackedVehicleById(vehId)
  if trackedVehIds[vehId] then
    trackedVehIds[vehId] = nil
  end
end

local function setDebug(_debug)
  debug = _debug
end

local function isVehCrashing(vehId)
  if not trackedVehIds[vehId] then return false end
  return trackedVehIds[vehId].isCrashing
end

local function isVehTracked(vehId)
  return trackedVehIds[vehId] ~= nil
end

local function onSerialize()
  return {
    trackedVehIds = trackedVehIds,
    debug = debug,
    debugDamageAssessmentUIPtr = debugDamageAssessmentUIPtr[0],
  }
end

local function onDeserialized(data)
  trackedVehIds = data.trackedVehIds
  debug = data.debug
  debugDamageAssessmentUIPtr = im.BoolPtr(data.debugDamageAssessmentUIPtr)
end

local function onVehicleDestroyed(vehId)
  if trackedVehIds[vehId] then
    trackedVehIds[vehId] = nil
  end
end

M.onUpdate = onUpdate
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onVehicleDestroyed = onVehicleDestroyed

M.addTrackedVehicleById = addTrackedVehicleById
M.removeTrackedVehicleById = removeTrackedVehicleById

M.setDebug = setDebug
M.isVehCrashing = isVehCrashing
M.isVehTracked = isVehTracked
M.resetCrashData = resetAllVehData
return M
