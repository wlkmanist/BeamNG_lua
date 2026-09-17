-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {}

local maxDistanceFromVeh = 10
local vehicleId
local active

local startPosRot
local id

local testDriveInfo

local function rtMessageJob(job)
  local message = job.args[1] or ""
  local delay = job.args[2] or 0

  job.sleep(delay)
  guihooks.trigger('ScenarioRealtimeDisplay', {msg = message})
  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  job.sleep(3.5)
  guihooks.trigger('ScenarioRealtimeDisplay', {msg = ""})
end

local helper = {}
local function showMessage(message, clear)
  if clear == nil then clear = true end

  helper = {
    ttl = 5,
    msg = message,
    category = "t",
    clear = clear
  }
  guihooks.trigger('Message',helper)
end

local function rtMessage(message, delay)
  delay = delay or 0
  core_jobsystem.create(rtMessageJob, 1, message, delay)
end

local function setActive(value)
  active = value
  gameplay_rawPois.clear()
end

local function resetData()
  setActive(false)
end

local function displayTimeLeft(time)
  helper.clear = false
  helper.ttl = 5
  helper.msg = "Test drive time left: " .. time
  helper.category = "testDriveTimeLeft"
  helper.icon = nil
  guihooks.trigger('Message',helper)

  --showMessage("(WIP temporary) Time left: " .. time, true)
end

local function checkTimeLeft(dtSim)
  if testDriveInfo.timeLimit then
    local timeBefore = round(testDriveInfo.timeLimit)
    testDriveInfo.timeLimit = testDriveInfo.timeLimit - dtSim
    if testDriveInfo.timeLimit < 0 then
      return false
    else
      local timeAfter = round(testDriveInfo.timeLimit)
      if timeBefore ~= timeAfter then
        displayTimeLeft(timeAfter)
      end
      return true
    end
  end
  return true
end

local function checkPlayerNotTooFarFromVeh()
  local veh = getObjectByID(vehicleId)
  if not veh then return end
  local vehPos = veh:getPosition()
  local playerPos = getObjectByID(be:getPlayerVehicleID(0)):getPosition()
  if playerPos:distance(vehPos) > maxDistanceFromVeh then
    return false
  end
  return true
end

local function setTestDriveInfo(_testDriveInfo)
  testDriveInfo = deepcopy(_testDriveInfo)
end

local function start(_vehicleId, testDriveInfo)
  setTestDriveInfo(testDriveInfo)
  vehicleId = _vehicleId
  local vehObj = getObjectByID(vehicleId)
  gameplay_walk.getInVehicle(vehObj)
  startPosRot = {pos = vehObj:getPosition(), rot = quat(0,0,1,0) * quat(vehObj:getRefNodeRotation())}

  -- create part condition snapshot
  core_vehicleBridge.executeAction(vehObj, 'createPartConditionSnapshot', "beforeTestDrive")
  core_vehicleBridge.executeAction(vehObj, 'setPartConditionResetSnapshotKey', "beforeTestDrive")

  setActive(true)
  core_vehicleBridge.executeAction(vehObj, 'setFreeze', false)
  extensions.hook('onTestDriveStarted')
  gameplay_rawPois.clear()
  career_career.setAutosaveEnabled(false)
end

local function resetDataAfterTestDriveDone()
  testDriveInfo = nil
  --gameplay_markerInteraction.clearCache()
  id = -1
  vehicleId = nil
end

local function endTestDriveJob(job)
  -- if tp is set, the vehicle should be teleported back to the dealership.
  -- if not set, it should be despawned
  local tp = job.args[1]
  if job.args[1] == nil then tp = true end

  simTimeAuthority.set(0.5)
  setActive(false)

  if tp then
    ui_fadeScreen.start(1)
  end
  job.sleep(1.5)

  local vehicle = getObjectByID(vehicleId)
  if vehicle and tp then
    spawn.safeTeleport(vehicle, startPosRot.pos, startPosRot.rot, nil, nil, nil, nil, false)

    job.sleep(0.1)-- setWalkingMode needs to wait a little bit after the vehicle is tp, or the player is set to walking mode where the veh was before the tp

    if gameplay_walk.isWalking() then
      gameplay_walk.getInVehicle(vehicle) -- hack
    end

    core_vehicleBridge.executeAction(vehicle,'setIgnitionLevel', 0)
    core_vehicleBridge.executeAction(vehicle, 'setFreeze', true)

    local vehicleData = map.objects[vehicleId]
    if vehicleData then
      local veh = scenetree.findObjectById(vehicleId)
      local oobb = veh:getSpawnWorldOOBB()

      local vehPos = vehicleData.pos - vec3(0,0,1.8)
      local dir = (oobb:getPoint(0) - vehPos)
      dir:normalize()

      job.sleep(0.1)

      local finalPos = oobb:getPoint(0) + (dir * 1.3)
      gameplay_walk.setWalkingMode(true, finalPos, quatFromDir(-dir, vec3(0,0,1)))
    else
      log("W", "testDrive", "world-map data for test drive vehicle not ready right after teleport; using default walking-mode placement")
      gameplay_walk.setWalkingMode(true)
    end
  end

  resetDataAfterTestDriveDone()

  simTimeAuthority.set(1)
  if tp then
    guihooks.trigger('ChangeState', {state = 'play'})
    ui_fadeScreen.stop(1)
    -- fade screen changes the ui state, so we need to change it back here
    extensions.hook('onTestDriveEndedAfterFade')
  end
  job.sleep(1.5)

end

local function onVehicleRepairedByInsurance(amount)
  rtMessage("Repaired test drive vehicle: -" .. amount, 1.8)
end

local function stop()
  if not active then return end

  core_jobsystem.create(endTestDriveJob, 1)
  career_career.setAutosaveEnabled(true)
end

local function abandonTestDrive()
  if not active then return end

  core_jobsystem.create(function(job)
    setActive(false)
    job.sleep(0.2) -- job is needed to display the ui message
    if testDriveInfo.abandonFees > 0 then --private sales don't have abandon fees
      local logBookLabel = "Didn't return the test drive vehicle."
      local label = string.format("Fee for not returning the test drive vehicle : -%i$", testDriveInfo.abandonFees)
      ui_message(label, 5, 'test1')
      career_modules_payment.pay({money = { amount = testDriveInfo.abandonFees, canBeNegative = true}}, {label = logBookLabel})
    end
    resetDataAfterTestDriveDone()
    career_modules_inspectVehicle.onTestDriveAbandoned()
  end, 1)

end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not vehicleId then return end

  if active then
    if not checkTimeLeft(dtSim) then
      stop()
    end
    if not checkPlayerNotTooFarFromVeh() then
      abandonTestDrive()
    end
  end
end

local function getTimeLeft()
  return testDriveInfo == nil and nil or testDriveInfo.timeLimit
end

local function isActive()
  return active
end


local function formatTestDriveToRawPoi(elements)
  if testDriveInfo == nil or not active or not testDriveInfo.endParkingSpot or not testDriveInfo.endParkingSpotCreated then return end
  id = string.format("testDrive-%s-%s-parkingEnd",testDriveInfo.dealershipName, testDriveInfo.route)
  local eps = testDriveInfo.endParkingSpot
  table.insert(elements,  {
    id = id,
    data = { type = "testDriveEnd", id = id},
    markerInfo = {
      parkingMarker = {path = testDriveInfo.endParkingSpot:getPath(), pos = eps.pos, rot = eps.rot, scl = eps.scl },
      bigmapMarker = {pos = eps.pos, name = "ui.career.testDrive.endTestDrive", description = "ui.career.testDrive.endTestDriveDesc", thumbnail = testDriveInfo.dealershipPreview, previews = {testDriveInfo.dealershipPreview}}
    }
  })
end

-- poi list stuff
local function onGetRawPoiListForLevel(levelIdentifier, elements)
  formatTestDriveToRawPoi(elements)
end

local function onPoiDetailPromptOpening(elemData, promptData)
  if testDriveInfo == nil or not active then return end

  local isTestDrivePoi = false
  for _, elem in ipairs(elemData) do
    if elem.type == "testDriveEnd" then
      isTestDrivePoi = true
    end
  end
  if isTestDrivePoi then
    local ret = {}
    ret.label = "ui.career.testDrive.endTestDrive"
    ret.buttonText = "ui.career.testDrive.stopTestDrive"
    ret.buttonFun = function() M.stop(false) end
    table.insert(promptData, ret)
  end
end

local function onCareerActive(active)
  if not active then return end
  resetData()
end

local quickAccessInitialized
local function onBeforeRadialOpened()
  if quickAccessInitialized then return end
  quickAccessInitialized = true
  core_quickAccess.addEntry(
    {
      level = "/root/sandbox/career/",
      generator = function(entries)
        if not isActive() then return end
        table.insert(entries, {
          title = "Stop Test Drive",
          icon = "abandon",
          priority = 90,
          enabled = true,
          uniqueID = "stopTestDrive",
          ignoreAsRecentActionForCategory = "sandbox",
          onSelect = function()
            career_modules_testDrive.stop()
            return {"hide"}
          end
        })
      end
    }
  )
end
M.onBeforeRadialOpened = onBeforeRadialOpened

M.abandonTestDrive = abandonTestDrive
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onPoiDetailPromptOpening = onPoiDetailPromptOpening
M.getTimeLeft = getTimeLeft
M.stop = stop
M.start = start
M.isActive = isActive
M.formatTestDriveToRawPoi = formatTestDriveToRawPoi
M.resetData = resetData

M.onUpdate = onUpdate
M.onCareerActive = onCareerActive
M.onVehicleRepairedByInsurance = onVehicleRepairedByInsurance

return M
