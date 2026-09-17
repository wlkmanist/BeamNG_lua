-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"gameplay_traffic", "gameplay_police", "gameplay_parking", "ui_fadeScreen"}
local missions = {}

local logTag = "missionManager"

-- CANbus is one-vehicle exclusive, so all vehicles need to be removed before...
local removeAllVehiclesBeforeMission = false
-- If enabled, mission stashing deletes vehicles and restores them from spawn data instead of toggling active state.
local despawnStashedVehiclesForMission = true
local debugVehicleStashingForMission = false

------------- helpers ----------------
local foregroundMissionId -- holds the one non-background-mission that is allowed to run at the same time
local delayedStartFromWithinMission
local fadedScreen = false

local taskData = {
  steps = {},
  data = {},
  active = false,
  currentStep = 0
}

local function vehicleStashDebugLog(message)
  if debugVehicleStashingForMission then
    log("I", logTag, message)
  end
end

local function resolveMissionEnvironmentTime(environment, state)
  if type(environment) ~= "table" then return nil end

  if environment.normalizedTime ~= nil then
    local time = core_environment.getTimeOfDayValueForNormalizedTime(environment.normalizedTime, state)
    log("I", logTag, "resolveMissionEnvironmentTime: normalizedTime="..environment.normalizedTime..", time="..time)
    if time ~= nil then return time end
  end

  local time = environment.time
  if type(time) ~= "string" then
    return time
  end
  return core_environment.getSolarTimeOfDayValue(time, state)
end

local function getVehicleSpawnData(obj)
  local metallicPaintData = obj:getMetallicPaintData() or {}
  return {
    model = obj.jbeam or obj.JBeam or obj:getField('JBeam', '0'),
    config = obj.partConfig,
    pos = obj:getPosition(),
    rot = quatFromDir(vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp())),
    paint = createVehiclePaint(obj.color, metallicPaintData[1]),
    paint2 = createVehiclePaint(obj.colorPalette0, metallicPaintData[2]),
    paint3 = createVehiclePaint(obj.colorPalette1, metallicPaintData[3]),
    licenseText = obj:getDynDataFieldbyName("licenseText", 0),
    vehicleName = obj:getField('name', '')
  }
end

local function spawnVehicleFromStashData(data)
  if not data or not data.model then return end
  local options = {
    config = data.config,
    pos = data.pos,
    rot = data.rot,
    paint = data.paint,
    paint2 = data.paint2,
    paint3 = data.paint3,
    licenseText = data.licenseText,
    vehicleName = data.vehicleName,
    autoEnterVehicle = false,
    canSpawnAnotherVehicleCheck = false,
    centeredPosition = true
  }
  return core_vehicles.spawnNewVehicle(data.model, options)
end

local function stashVehicles(step)
  local mission = taskData.data.mission
  local setupData = mission.setupData
  local playerVehId = mission._startingInfo and mission._startingInfo.vehId
  local currentInventoryId = career_modules_inventory and career_modules_inventory.getCurrentVehicle and career_modules_inventory.getCurrentVehicle()
  local totalVehiclesDeleted = 0
  setupData._hasStashedVehicles = true
  setupData.stashedVehicleSpawnData = setupData.stashedVehicleSpawnData or {}
  setupData.stashedCareerVehicleData = setupData.stashedCareerVehicleData or {}
  setupData._stashVehicleIds = setupData._stashVehicleIds or tableKeysSorted(setupData.stashedVehicles)
  vehicleStashDebugLog(string.format("Starting vehicle stash. despawnMode=%s playerVehId=%s", tostring(despawnStashedVehiclesForMission), tostring(playerVehId)))

  if step and step.careerPartConditionsVehicleId then
    if not step.careerPartConditionsUpdated then
      return false, 0
    end

    local id = step.careerPartConditionsVehicleId
    local inventoryId = step.careerPartConditionsInventoryId
    local data = step.careerPartConditionsStashData
    step.careerPartConditionsVehicleId = nil
    step.careerPartConditionsInventoryId = nil
    step.careerPartConditionsStashData = nil
    step.careerPartConditionsUpdated = nil

    local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
    local partConditions = vehInfo and vehInfo.partConditions or {}
    career_modules_inventory.setVehicleDirty(inventoryId)
    local brokenParts = career_modules_valueCalculator.getNumberOfBrokenParts(partConditions)
    if brokenParts >= career_modules_valueCalculator.getBrokenPartsThreshold() then
      vehicleStashDebugLog(string.format("Removing damaged career vehicle from world without mission respawn: vehId=%d inventoryId=%d brokenParts=%d", id, inventoryId, brokenParts))
      setupData._damagedCareerVehicleStored = true
      career_modules_inventory.removeVehicleObject(inventoryId)
      setupData.stashedVehicles[id] = nil
    else
      vehicleStashDebugLog(string.format("Removing career vehicle for mission respawn: vehId=%d inventoryId=%d brokenParts=%d", id, inventoryId, brokenParts))
      setupData.stashedCareerVehicleData[id] = data
      career_modules_inventory.removeVehicleObject(inventoryId)
      setupData.stashedVehicles[id] = true
    end
    totalVehiclesDeleted = totalVehiclesDeleted + 1
  end

  while setupData._stashVehicleIds[1] do
    local id = table.remove(setupData._stashVehicleIds, 1)
    local v = setupData.stashedVehicles[id]
    local obj = getObjectByID(id)
    if v == false and obj then
      log("D", logTag, "Stashing vehicle for mission setup: "..id)
      if despawnStashedVehiclesForMission and id ~= playerVehId then
        local inventoryId = career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId(id)
        if inventoryId then
          if inventoryId == currentInventoryId then
            vehicleStashDebugLog("Deactivating current career vehicle: "..id)
            obj:setActive(0)
            setupData.stashedVehicles[id] = true
          else
            vehicleStashDebugLog(string.format("Updating career part conditions before stashing: vehId=%d inventoryId=%d", id, inventoryId))
            step.careerPartConditionsVehicleId = id
            step.careerPartConditionsInventoryId = inventoryId
            step.careerPartConditionsStashData = {inventoryId = inventoryId, pos = obj:getPosition(), rot = quatFromDir(vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))}
            career_modules_inventory.updatePartConditions(id, inventoryId, function()
              step.careerPartConditionsUpdated = true
            end)
            return false, totalVehiclesDeleted
          end
        else
          vehicleStashDebugLog("Capturing and deleting stashed vehicle: "..id)
          setupData.stashedVehicleSpawnData[id] = getVehicleSpawnData(obj)
          obj:delete()
          setupData.stashedVehicles[id] = true
          totalVehiclesDeleted = totalVehiclesDeleted + 1
        end
      else
        vehicleStashDebugLog("Deactivating stashed vehicle: "..id)
        obj:setActive(0)
        setupData.stashedVehicles[id] = true
      end
    end
  end
  setupData._stashVehicleIds = nil
  return true, totalVehiclesDeleted
end

local function unstashVehicles()
  local mission = taskData.data.mission
  local setupData = mission.setupData
  setupData._unstashVehicleIds = setupData._unstashVehicleIds or tableKeysSorted(setupData.stashedVehicles)

  if setupData._careerRespawnPendingId then
    if not setupData._careerRespawnComplete then
      return false
    end
    local id = setupData._careerRespawnPendingId
    if setupData.stashedCareerVehicleData then
      setupData.stashedCareerVehicleData[id] = nil
    end
    setupData.stashedVehicles[id] = nil
    setupData._careerRespawnPendingId = nil
    setupData._careerRespawnComplete = nil
    return false
  end

  local id = table.remove(setupData._unstashVehicleIds, 1)
  if id then
    local spawnData = setupData.stashedVehicleSpawnData or {}
    local careerData = setupData.stashedCareerVehicleData and setupData.stashedCareerVehicleData[id]
    if setupData.stashedVehicles[id] == true and careerData then
      vehicleStashDebugLog(string.format("Respawning career vehicle from mission stash: oldVehId=%d inventoryId=%d", id, careerData.inventoryId))
      setupData._careerRespawnPendingId = id
      setupData._careerRespawnComplete = nil
      local veh = career_modules_inventory.spawnVehicle(careerData.inventoryId, nil, function()
        local newId = career_modules_inventory.getVehicleIdFromInventoryId(careerData.inventoryId)
        local obj = newId and getObjectByID(newId)
        if obj then
          spawn.safeTeleport(obj, careerData.pos, careerData.rot)
        end
        career_modules_inventory.setVehicleDirty(careerData.inventoryId)
        setupData._careerRespawnComplete = true
      end)
      if veh then
        -- wait for career inventory to finish applying part conditions before continuing
      else
        log("W", logTag, "Unable to respawn career vehicle from mission stash: "..id)
        setupData._careerRespawnPendingId = nil
        setupData.stashedCareerVehicleData[id] = nil
        setupData.stashedVehicles[id] = nil
      end
    elseif setupData.stashedVehicles[id] == true and spawnData[id] then
      log("D", logTag, "Respawning vehicle from mission stash: "..id)
      vehicleStashDebugLog("Respawning deleted stashed vehicle: "..id)
      local veh = spawnVehicleFromStashData(spawnData[id])
      if veh then
        local newId = veh:getID()
        vehicleStashDebugLog(string.format("Respawned stashed vehicle: oldId=%d newId=%d", id, newId))
        if mission._startingInfo and mission._startingInfo.vehId == id then
          mission._startingInfo.vehId = newId
        end
      else
        log("W", logTag, "Unable to respawn vehicle from mission stash: "..id)
      end
      spawnData[id] = nil
    elseif setupData.stashedVehicles[id] == true then
      local obj = getObjectByID(id)
      if obj then
        vehicleStashDebugLog("Reactivating setActive-stashed vehicle: "..id)
        obj:setActive(1)
        core_vehicleBridge.executeAction(obj, "setFreeze", false)
      end
    end
    setupData.stashedVehicles[id] = nil
    return false
  end

  setupData._hasStashedVehicles = nil
  setupData._unstashVehicleIds = nil
  if setupData.stashedVehicleSpawnData then
    table.clear(setupData.stashedVehicleSpawnData)
  end
  if setupData.stashedCareerVehicleData then
    table.clear(setupData.stashedCareerVehicleData)
  end
  table.clear(setupData.stashedVehicles)
  if setupData._damagedCareerVehicleStored then
    guihooks.trigger("toastrMsg", {type="warning", label = "vehStoredMission", title = _tr("ui.career.inventory.toast.vehicleStored.title"), msg = _tr("ui.career.inventory.toast.vehicleStoredMission.msg")})
    setupData._damagedCareerVehicleStored = nil
  end
  return true
end

local function taskLoadLevelStep(step)
  if not step.waitForClientStartMission then
    loadPresetExtensions()
    local foundLevel = false
    for i, v in ipairs(core_levels.getList()) do
      if v.levelName:lower() == step.level:lower() then
        local level = v.fullfilename
        if string.find(v.fullfilename, '.mis') then
          level = v.fullfilename
        else
          level = path.getPathLevelMain(v.levelName)
        end
        foundLevel = true
        core_levels.startLevel(level, nil, function()
          ui_router.navigate("play")
          profilerPushEvent("clientPostStartMission")

          clientPostStartMission(level)

          profilerPopEvent("clientPostStartMission")
          profilerPushEvent("clientStartMission")

          extensions.hookNotify("onClientStartMission", level)
          map.assureLoad() -- map data needs to be loaded so that systems such as traffic can initialize properly before gameplay starts

          profilerPopEvent("clientStartMission")
          step.complete = true
        end)
      end
    end
    if not foundLevel then
      log("E","","Could not find level: " .. step.level)
    end
    step.waitForClientStartMission = true
  end
  return step.levelLoaded or false
end


local function getFadeScreenData(mission)
  local preview = mission.previewFile
  if preview and string.find(preview, "noPreview") then preview = nil end
  local tips = mission.getMissionTips and mission:getMissionTips() or {}
  return {image = preview, title = mission.name, subtitle = "ui.mission.loading.loading", text = mission.description, tips = tips[math.random(#tips)]}
end

local function taskStartFadeStep(step)
  if fadedScreen then -- if screen is already black, complete this step
    step.complete = true
    fadedScreen = false
    --ui_fadeScreen.delayFrames = 1
    return
  end
  if not step.waitForFade then
    step.waitForFade = true
    --guihooks.trigger('ChangeState', 'play')
    if taskData.type == "start" then
      --ui_fadeScreen.delayFrames = 15 -- extra delay, to pad loading time and ensure fancy loading screen is shown
      ui_fadeScreen.start(M.fadeDuration, getFadeScreenData(taskData.data.mission))
    else
      ui_fadeScreen.start(M.fadeDuration)
    end
  end
  if step.fadeState1 then
    step.complete = true
    --ui_fadeScreen.delayFrames = 1
  end
end

local function taskStartRemoveVehicles(step)
  if not removeAllVehiclesBeforeMission then step.complete = true return end
  for _, name in ipairs(scenetree.findClassObjects("BeamNGVehicle")) do
    local obj = scenetree.findObject(name)
    if obj then
      log("I","","Deleting " .. obj:getId())
      obj:delete()
    end
  end
  gameplay_traffic.deleteVehicles()
  step.complete = true
  return
end

local function taskStartPreMissionHandling(step)
  local mission = taskData.data.mission
  local userSettings = taskData.data.userSettings

  if not step.processUserSettings then
    taskData.data.startLoadingTime = os.time()

    if not userSettings then
      local settings = mission:getUserSettingsData() or {}
      userSettings = {}
      for _, elem in ipairs(settings) do
        userSettings[elem.key] = elem.value
      end
    end
    if mission:processUserSettings(userSettings or {}) then
      log("E", logTag, "Couldn't start mission, 'processUserSettings' didn't return nil/false: "..dumps(mission.id))
      --return
    end
    step.processUserSettings = true
  end

  if career_career and career_career.isActive() then
    if not step.sentToCareer then
      career_modules_missionWrapper.preMissionHandling(step)
      step.sentToCareer = true
    end
    if step.handlingComplete then
      step.complete = true
    end
  else
    step.complete = true
  end

  -- save the player car, position, etc. from where they started the mission
  local startingInfo = {}
  local veh = getPlayerVehicle(0)
  if veh then
    startingInfo.vehPos = veh:getPosition()
    startingInfo.vehRot = quatFromDir(vec3(veh:getDirectionVector()), vec3(veh:getDirectionVectorUp()))
    startingInfo.vehId = veh:getID()
    startingInfo.startedFromVehicle = true
  else
    startingInfo.camPos = core_camera.getPosition()
    startingInfo.camRot = core_camera.getQuat()
    startingInfo.startedFromCamera = true
  end
  mission._startingInfo = startingInfo
  mission.restoreStartingInfoSetup = nil

  -- prepare vehicle stash
  if not step.ignoreStash then
    mission.setupData._hasStashedVehicles = nil
    table.clear(mission.setupData.stashedVehicles)
    mission.setupData.stashedVehicleSpawnData = mission.setupData.stashedVehicleSpawnData or {}
    table.clear(mission.setupData.stashedVehicleSpawnData)
    mission.setupData.stashedCareerVehicleData = mission.setupData.stashedCareerVehicleData or {}
    table.clear(mission.setupData.stashedCareerVehicleData)
    mission.setupData._stashVehicleIds = nil
    mission.setupData._unstashVehicleIds = nil
    mission.setupData._careerRespawnPendingId = nil
    mission.setupData._careerRespawnComplete = nil
    mission.setupData._damagedCareerVehicleStored = nil
    for _, name in ipairs(scenetree.findClassObjects("BeamNGVehicle")) do
      local obj = scenetree.findObject(name)
      if obj and obj:getActive() then
        mission.setupData.stashedVehicles[obj:getId()] = false
      end
    end

    local vehicleSetup = mission.setupModules.vehicles
    local usesPlayerVehicle = vehicleSetup.enabled and not vehicleSetup.useCustomConfig and (vehicleSetup.usePlayerVehicle or not vehicleSetup.vehicles or not vehicleSetup._selectionIdx)
    if usesPlayerVehicle and startingInfo.vehId then
      mission.setupData.stashedVehicles[startingInfo.vehId] = nil
    end

    local trafficSetup = mission.setupModules.traffic
    if trafficSetup.useTraffic and trafficSetup.usePrevTraffic and gameplay_traffic.getState() == 'on' then
      for _, id in ipairs(gameplay_traffic.getTrafficList()) do
        mission.setupData.stashedVehicles[id] = nil
      end
      for _, id in ipairs(gameplay_parking.getParkedCarsList()) do
        mission.setupData.stashedVehicles[id] = nil
      end
    end
  end

  -- pass startingOptions to mission
  mission.startingOptions = taskData.data.startingOptions or {}

  -- custom mission script
  local scriptPath = mission.missionFolder.."/script"
  if FS:fileExists(scriptPath..".lua") then
    local script
    local result = xpcall(function()
      script = require(scriptPath)
    end
    , debug.traceback)
    if result then
      mission.script = script({mission = mission}) -- actual init of the script
      log("I", logTag, "Initializing custom mission script")
    end
  end

end

local requiredGBReleasedPerVehicle = 0.100
local function taskStartStashVehiclesStep(step)
  if not step.handled then
    step.startTimeClock = os.clock()
    step.handled = true
    local mission = taskData.data.mission
    local startingInfo = mission._startingInfo or {}
    local totalVehiclesDeleted = 0

    -- freeze traffic and stash vehicles here, after start setup but before mission vehicles are spawned
    local m = Engine.Platform.getMemoryInfo()
    local availableGB = m.availableBytes / (1024 * 1024 * 1024)
    vehicleStashDebugLog(string.format("Available memory before freezing traffic state: %5.3f GB", availableGB))
    step.startingMemoryGB = availableGB
    local trafficSetup = mission.setupModules.traffic
    if not trafficSetup.usePrevTraffic then

      if gameplay_traffic.getState() == 'on' then
        vehicleStashDebugLog(string.format("Freezing traffic state. despawnMode=%s", tostring(despawnStashedVehiclesForMission)))
        trafficSetup._prevTraffic, trafficSetup._prevPolice, trafficSetup._prevParking = gameplay_traffic.freezeState({despawnVehicles = despawnStashedVehiclesForMission, debugVehicleStashing = debugVehicleStashingForMission, exceptVehicleId = startingInfo.vehId, vehicleStashDebugLog = vehicleStashDebugLog }) -- stash previous traffic

        if despawnStashedVehiclesForMission then
          totalVehiclesDeleted = totalVehiclesDeleted + #((trafficSetup._prevTraffic and trafficSetup._prevTraffic.vehicleSpawnOrder) or {})
          totalVehiclesDeleted = totalVehiclesDeleted + #((trafficSetup._prevPolice and trafficSetup._prevPolice.vehicleSpawnOrder) or {})
          totalVehiclesDeleted = totalVehiclesDeleted + #((trafficSetup._prevParking and trafficSetup._prevParking.vehicleSpawnOrder) or {})
        end

        log("I", logTag, "Now storing current traffic state")
      end

      gameplay_traffic.setTrafficVars() -- resets variables
      gameplay_police.setPursuitVars()
      gameplay_parking.setParkingVars()
    end
    local m = Engine.Platform.getMemoryInfo()
    local availableGB = m.availableBytes / (1024 * 1024 * 1024)
    vehicleStashDebugLog(string.format("Available memory after freezing traffic state: %5.3f GB", availableGB))

    step.totalVehiclesDeleted = totalVehiclesDeleted
  end

  if not step.stashingComplete then
    if not step.ignoreStash then
      local complete, deletedCount = stashVehicles(step)
      step.totalVehiclesDeleted = step.totalVehiclesDeleted + (deletedCount or 0)
      if not complete then return end
      local m = Engine.Platform.getMemoryInfo()
      local availableGB = m.availableBytes / (1024 * 1024 * 1024)
      vehicleStashDebugLog(string.format("Available memory after stashing: %5.3f GB", availableGB))
    end
    vehicleStashDebugLog(string.format("Total vehicles deleted: %d", step.totalVehiclesDeleted))
    step.stashingComplete = true
  end

  local m = Engine.Platform.getMemoryInfo()
  local availableGB = m.availableBytes / (1024 * 1024 * 1024)
  local elapsedTime = os.clock() - step.startTimeClock
  local requiredGB = requiredGBReleasedPerVehicle * (step.totalVehiclesDeleted - elapsedTime)
  local releasedGB = availableGB - step.startingMemoryGB
  --print(string.format("Waiting for memory to be released... released so far: %5.3f GB, required: %5.3f GB, elapsedTime: %0.2fs", releasedGB, requiredGB, elapsedTime))
  step.complete = releasedGB >= requiredGB or elapsedTime > 6
end

local function setDiffs(setup, veh)
  if not setup then return end
  log("I","Setting diffs for vehicle ".. veh:getID().."...")
  if setup.toggleDifferentials then
    veh:queueLuaCommand([[
      for _, v in ipairs(powertrain.getDevicesByType("differential")) do powertrain.toggleDeviceMode(v.name) end
    ]])
  end
  if setup.lockFrontDiffs then
    veh:queueLuaCommand([[
      controller.getControllerSafe("frontLockControl").setDriveMode('locked')
    ]])
  end
  if setup.lockRearDiffs then
    veh:queueLuaCommand([[
      controller.getControllerSafe("rearLockControl").setDriveMode('locked')
    ]])
  end
  if setup.setTransfercase then
    veh:queueLuaCommand([[
      controller.getControllerSafe("transfercaseControl").setDriveMode('4hi')
      controller.getControllerSafe("transfercaseControl").setDriveMode('high')
    ]])
  end
  if setup.setRangebox then
    veh:queueLuaCommand([[
      controller.getControllerSafe("rangeboxControl").setDriveMode('low')
    ]])
  end
end

local function taskStartVehicleStep(step)
  local vehicleSetup = taskData.data.mission.setupModules.vehicles
  local userSettings = taskData.data.userSettings or {}
  extensions.load("gameplay_vehiclePerformance")

  if not vehicleSetup.enabled then
    step.complete = true
  else
    local playerId = taskData.data.mission._startingInfo and taskData.data.mission._startingInfo.vehId
    local idx = vehicleSetup._selectionIdx

    if (vehicleSetup.usePlayerVehicle or not vehicleSetup.vehicles or not idx) and not vehicleSetup.useCustomConfig then
      -- uses existing player vehicle
      vehicleSetup.usePlayerVehicle = true
      if playerId then
        taskData.data.mission.setupData.stashedVehicles[playerId] = nil
        if taskData.data.mission.setupData.stashedVehicleSpawnData then
          taskData.data.mission.setupData.stashedVehicleSpawnData[playerId] = nil
        end
      end
      local vehId = taskData.data.mission._startingInfo.vehId
      local veh = getObjectByID(vehId)
      if veh then
        setDiffs(vehicleSetup.playerVehicleDiffs or {}, veh)
      end

      if career_career.isActive() then -- gets performance class data from career inventory
        local inventoryVehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
        if inventoryVehId then
          local classData = career_modules_vehiclePerformance.getVehicleClass(inventoryVehId)
          if classData then
            taskData.data.mission._startingInfo.vehicleClass = classData.class.name
            taskData.data.mission._startingInfo.vehiclePerformanceIndex = classData.performanceIndex
          end
        end
      else -- attempts to get performance class data from vehicle config
        local classData = gameplay_vehiclePerformance.getClassFromVehId(vehId)
        if classData then
          taskData.data.mission._startingInfo.vehicleClass = classData.class.name
          taskData.data.mission._startingInfo.vehiclePerformanceIndex = classData.performanceIndex
        end
      end

      step.complete = true
    else
      -- spawns and uses a new vehicle
      if not step.waitForPlayerVehicle then
        step.waitForPlayerVehicle = true
        local model, config, options = nil, nil, nil
        if vehicleSetup.useCustomConfig then
          model = vehicleSetup._customVehicle.model
          config = vehicleSetup._customVehicle.config
          options = {config = config}
        else
          local vehicleInstance = vehicleSetup.vehicles[idx]
          model, config = vehicleInstance.model, vehicleInstance.configPath
          if vehicleInstance.customConfigPath and FS:fileExists(vehicleInstance.customConfigPath) then
            config = vehicleInstance.customConfigPath
            log("I", logTag, "Custom part config found and accepted for vehicle setup")
          end

          local paintData = core_vehicles.getModel(model).model.paints
          local paint = vehicleInstance.paintName and paintData[vehicleInstance.paintName]
          local paint2 = vehicleInstance.paintName2 and paintData[vehicleInstance.paintName2]
          local paint3 = vehicleInstance.paintName3 and paintData[vehicleInstance.paintName3]

          options = {config = config, paint = paint, paint2 = paint2, paint3 = paint3}
        end
        local spawningOptions = sanitizeVehicleSpawnOptions(model, options)
        -- these spawning options are critical for the mission to load properly
        spawningOptions.autoEnterVehicle = true
        spawningOptions.canSpawnAnotherVehicleCheck = false
        spawningOptions.unlimitedSafeSpawnRange = true
        spawningOptions.removeWhenNoPositionFound = false
        step.veh = core_vehicles.spawnNewVehicle(model, spawningOptions)
      end
    end
  end

  if step.veh and step.veh:isReady() then
    vehicleSetup.vehId = step.veh:getID()
    local idx = vehicleSetup._selectionIdx
    local vehicleInstance = vehicleSetup.vehicles[idx]

    -- differentials setup
    setDiffs(vehicleInstance, step.veh)

    local classData = gameplay_vehiclePerformance.getClassFromVehId(vehicleSetup.vehId)
    if classData then
      taskData.data.mission._startingInfo.vehicleClass = classData.class.name
      taskData.data.mission._startingInfo.vehiclePerformanceIndex = classData.performanceIndex
    end

    step.complete = true
  end
end

local function taskStartStartingOptionRepairStep(step)
  -- skip this step if career is not loaded
  if not career_modules_inventory then step.complete = true return end

  if step.handled then return end

  local mission = taskData.data.mission

  if mission._startingInfo then

    --payment for entry fee
    if career_career.isActive() then
      local entryFee = mission:getEntryFee(taskData.data.userSettings) or {}
      if next(entryFee) then
        career_modules_playerAttributes.addAttributes(entryFee, {label = "ui.career.attributeLog.challengeEntryFee"})
      end
    end
    -- repair cost
    if taskData.data.startingOptions and taskData.data.startingOptions.repair
      and taskData.data.startingOptions.repair.type ~= "defaultStart"
      and taskData.data.startingOptions.repair.type ~= "noRepair" then
      local vehId = mission._startingInfo.startedFromVehicle and mission._startingInfo.vehId
      local inventoryVehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId or 0)
      if inventoryVehId then
        local repairType = taskData.data.startingOptions.repair.type

        --payment for repairs
        local price = gameplay_missions_missionScreen.getRepairCostForStartingRepairType(repairType)
        local payment = {}
        for att, amount in pairs(price) do
          payment[att] = -amount
        end
        career_modules_playerAttributes.addAttributes(payment, {label = "ui.career.attributeLog.challengePreRepair"})

        local vehInfo = career_modules_inventory.getVehicles()[inventoryVehId]
        career_modules_insurance_insurance.makeRepairClaim(inventoryVehId, {deductible = price}, vehInfo)

        -- actual repairing
        career_modules_inventory.updatePartConditions(nil, inventoryVehId,
          function()
            career_modules_insurance_insurance.startRepair(inventoryVehId, nil, function()
              step.complete = true
            end)
          end)
      else
        log("E","","No Inventory ID for repairing?")
        step.complete = true
      end
    else
      step.complete = true
    end
    step.handled = true
  else
    step.complete = true
  end
end

local function taskStartTakePartConditionSnapshot(step)
  -- skip this step if career is not loaded
  if not career_modules_inventory then step.complete = true return end
  -- skip this step if the player is not seated in a vehicle they own
  if not career_modules_inventory.getCurrentVehicle() then step.complete = true return end

  if not step.handled then
    local vehObj = getPlayerVehicle(0)
    -- take snapshot
    core_vehicleBridge.executeAction(vehObj, 'createPartConditionSnapshot', "beforeMission")
    core_vehicleBridge.executeAction(vehObj, 'setPartConditionResetSnapshotKey', "beforeMission")
    core_vehicleBridge.requestValue(vehObj, function()
      step.complete = true
      taskData.data.mission._partConditionSnapshotTaken = true
    end, 'ping')

    step.handled = true
  end
end


local function taskStartTrafficStep(step)
  local trafficSetup = taskData.data.mission.setupModules.traffic
  --local userSettings = taskData.data.userSettings or {}

  if trafficSetup.useTraffic and trafficSetup.usePrevTraffic and gameplay_traffic.getState() == 'on' then -- use existing traffic
    for _, id in ipairs(gameplay_traffic.getTrafficList()) do
      taskData.data.mission.setupData.stashedVehicles[id] = nil
      if taskData.data.mission.setupData.stashedVehicleSpawnData then
        taskData.data.mission.setupData.stashedVehicleSpawnData[id] = nil
      end
    end
    for _, id in ipairs(gameplay_parking.getParkedCarsList()) do
      taskData.data.mission.setupData.stashedVehicles[id] = nil
      if taskData.data.mission.setupData.stashedVehicleSpawnData then
        taskData.data.mission.setupData.stashedVehicleSpawnData[id] = nil
      end
    end

    step.activated = true
    gameplay_traffic.forceTeleportAll()
  end

  if not step.waitForTraffic then
    step.waitForTraffic = true

    if trafficSetup.enabled and trafficSetup.useTraffic and not step.activated then -- spawn new traffic
      local options = {keepCurrent = true}
      if not trafficSetup.useGameOptions then
        options.allMods = false
        options.allConfigs = true
        options.simpleVehs = trafficSetup.useSimpleVehs
      end

      if trafficSetup.customGroupFile then
        local json = jsonReadFile(trafficSetup.customGroupFile)
        if json and json.data then
          options.vehGroup = json.data
        end
      end

      step.validParking = gameplay_parking.setupVehicles(trafficSetup.parkedAmount)
      step.validTraffic = gameplay_traffic.setupTraffic(trafficSetup.amount, options)
      trafficSetup._hasSpawnedTraffic = true
      if not step.validParking and not step.validTraffic then -- no vehicles to spawn, just continue
        step.complete = true
      end
    else
      step.complete = true
    end
  end
  if step.activated then -- runs after the traffic step spawned traffic, or if previous traffic is used
    gameplay_traffic.setTrafficVars({spawnValue = trafficSetup.respawnRate, enableRandomEvents = false})
    if step.validTraffic then -- only if new traffic was created
      gameplay_traffic.setActiveAmount(trafficSetup.activeAmount)
    end
    step.complete = true
  end
end

local function taskStartMissionStep(step)
  if taskData.data.startLoadingTime and os.time() - taskData.data.startLoadingTime < 1 then return end -- minimum loading screen time while the user reads

  if step.handled then return end
  step.handled = true
  local mission = taskData.data.mission

  --[[
    -- load associated prefabs
    if mission.prefabs then
      mission._spawnedPrefabs = {}
      mission._vehicleTransforms = {}
      for i, p in ipairs(mission.prefabs) do
        local obj = spawnPrefab(mission.id.."_prefab_" .. i , p, "0 0 0", "0 0 0 1", "1 1 1")
        if obj == nil then
          log("E", "", "Couldn't start mission "..dumps(mission.id)..", could not load prefab: "..dumps(p))
          unloadMissionPrefabs(mission)
          return true
        else
          log("D", "", "Loaded prefab for mission"..dumps(mission.id) .. " - " .. dumps(p))
          table.insert(mission._spawnedPrefabs, obj)
          for i = 0, obj:size() - 1 do
            local sObj = obj:at(i)
            local name = sObj:getClassName()
            if sObj then
              if name == 'BeamNGVehicle' then
                sObj = Sim.upcast(sObj)
                mission._vehicleTransforms[sObj:getId()] = {
                  pos = vec3(sObj:getPosition()),
                  rot = quat(sObj:getRotation())
                }
              end
            end
          end
        end
      end
    end
  ]]

  simTimeAuthority.pause(false)
  simTimeAuthority.setInstant(1)
  be:resetTireMarks()

  -- setupModules
  if mission.setupModules.vehicles.enabled then
    mission.setupModules.vehicles._processed = true
  end

  if mission.setupModules.traffic.enabled then
    mission.setupModules.traffic._processed = true
  end

  mission.setupModules.environment._originalTimeOfDay = deepcopy(core_environment.getTimeOfDay() or {})

  mission.setupModules.environment._originalCloudCover = core_environment.getCloudCover() or 0
  mission.setupModules.environment._originalCloudWindSpeed = core_environment.getWindSpeed() or 0
  mission.setupModules.environment._originalFogDensity = core_environment.getFogDensity() or 0

  if mission.setupModules.environment.enabled then
    mission.setupModules.environment._processed = true
    if mission.setupModules.environment._originalTimeOfDay.time then
      mission.setupModules.environment._originalTimeOfDay.play = mission.setupModules.environment._originalTimeOfDay.play and true or false
      local tod = deepcopy(core_environment.getTimeOfDay())
      tod.time = resolveMissionEnvironmentTime(mission.setupModules.environment, tod)
      if tod.time == -1 then
        tod.time = mission.setupModules.environment._originalTimeOfDay.time
      end

      if mission.setupModules.environment.timeScale > 0 then
        tod.play = true
        tod.dayLength = (tod.dayLength or 1800) / mission.setupModules.environment.timeScale
      end
      core_environment.setTimeOfDay(tod)
    end

    core_environment.setCloudCover(mission.setupModules.environment.cloudCover)
    core_environment.setWindSpeed(mission.setupModules.environment.cloudWindSpeed)
    core_environment.setFogDensity(mission.setupModules.environment.fogDensity)

    if mission.setupModules.environment.windSpeed > 0 then
      mission.setupModules.environment._windVec = vec3(
        math.sin(mission.setupModules.environment.windDirAngle) * mission.setupModules.environment.windSpeed,
        math.cos(mission.setupModules.environment.windDirAngle) * mission.setupModules.environment.windSpeed,
        0
      )
    end
  end
  mission._isOngoing = true -- in case onStart guys ask about our own state - yes, we're kinda ongoing now...
  --dump("Mission now _isOngoing : " .. dumps(mission.id))
  if mission:onStart() then
    mission._isOngoing = false -- ...but we'll stop in case of problems
    log("E", logTag, "Couldn't start mission, 'onStart' didn't return nil/false: "..dumps(mission.id))
    --unloadMissionPrefabs(mission)
    --return true
  end
  --if mission._spawnedPrefabs and mission.prefabsRequireCollisionReload then
  --  be:reloadCollision()
  --end

  -- set exclusivity
  if not mission.background then
    foregroundMissionId = mission.id
  end

  extensions.hook("onAnyMissionChanged", "started", mission, taskData.data.userSettings)
  step.complete = true
end

local function taskStopMissionStep(step)
  local mission = step.mission or taskData.data.mission
  local data = taskData.data.data
  data = data or {}
  local abandoned = data.abandoned

  if step.handled then
    step.complete = true
    return
  end
  step.handled = true
  extensions.hook("onAnyMissionWillChange", "stopped", mission, abandoned)

  mission._isOngoing = false
  mission:onStop(data)

  if foregroundMissionId == mission.id then
    foregroundMissionId = nil
  end

  simTimeAuthority.pause(false)
  simTimeAuthority.setInstant(1)
  be:resetTireMarks()

  -- setupModules
  local prevId = mission._startingInfo and mission._startingInfo.vehId
  local prevVeh = prevId and getObjectByID(prevId) -- checks if it exists; the vehicle can get removed before this step
  if mission.setupModules.vehicles._processed and prevVeh and mission.setupModules.vehicles.vehId and prevId ~= mission.setupModules.vehicles.vehId then
    local vehObj = getObjectByID(mission.setupModules.vehicles.vehId)
    if vehObj then vehObj:delete() end
  end
  mission.setupModules.vehicles._processed = nil

  if mission.setupModules.traffic._processed and mission.setupModules.traffic._hasSpawnedTraffic then
    gameplay_traffic.deleteVehicles()
    gameplay_parking.deleteVehicles()
    log("I", logTag, "Deleting traffic spawned by mission.")
  end
  step.complete = true
end

local function taskStopRestoreStashedVehiclesStep(step)
  local mission = step.mission or taskData.data.mission
  if not step.ignoreStash then
    if not unstashVehicles() then
      return
    end
  end
  local trafficSetup = mission.setupModules.traffic
  if trafficSetup._prevTraffic and not trafficSetup.usePrevTraffic then
    vehicleStashDebugLog(string.format("Restoring traffic state. respawnMode=%s", tostring(despawnStashedVehiclesForMission)))
    gameplay_traffic.unfreezeState(trafficSetup._prevTraffic, trafficSetup._prevPolice, trafficSetup._prevParking, {respawnVehicles = despawnStashedVehiclesForMission, debugVehicleStashing = debugVehicleStashingForMission})
    log("I", logTag, "Now restoring previous traffic state")
  end
  trafficSetup._prevTraffic, trafficSetup._prevPolice, trafficSetup._prevParking, trafficSetup._processed = nil, nil, nil, nil
  step.complete = true
end

local function taskStopMissionPostStep(step)
  local mission = step.mission or taskData.data.mission
  if step.handled then
    if mission.mgr.runningState == 'stopped' then
      mission._startingInfo = nil
      step.complete = true
      extensions.hook("onAnyMissionChanged", "stopped", mission)
    end
    return
  end
  step.handled = true
  if mission.setupModules.environment._originalTimeOfDay then
    core_environment.setTimeOfDay(mission.setupModules.environment._originalTimeOfDay)
    mission.setupModules.environment._originalTimeOfDay = nil
  end
  if mission.setupModules.environment._originalCloudCover then
    core_environment.setCloudCover(mission.setupModules.environment._originalCloudCover)
    mission.setupModules.environment._originalCloudCover = nil
  end
  if mission.setupModules.environment._originalCloudWindSpeed then
    core_environment.setWindSpeed(mission.setupModules.environment._originalCloudWindSpeed)
    mission.setupModules.environment._originalCloudWindSpeed = nil
  end
  if mission.setupModules.environment._originalFogDensity then
    core_environment.setFogDensity(mission.setupModules.environment._originalFogDensity)
    mission.setupModules.environment._originalFogDensity = nil
  end

  if mission.setupModules.environment._windVec then -- resets wind; what if previous wind existed?
    for _, veh in ipairs(getAllVehicles()) do
      veh:queueLuaCommand("obj:setWind(0, 0, 0)")
    end
    mission.setupModules.environment._windVec = nil
  end
  mission.setupModules.environment._processed = nil

  -- starting info reset
  if mission.restoreStartingInfoSetup and mission._startingInfo then
    if mission._startingInfo.startedFromVehicle then
      local veh = getObjectByID(mission._startingInfo.vehId)
      if veh then
        if gameplay_walk and gameplay_walk.isWalking() then
          gameplay_walk.getInVehicle(veh)
        else
          be:enterVehicle(0, veh)
        end
        -- auto unfreeze player vehicle
        core_vehicleBridge.executeAction(veh, 'setFreeze', false)
        spawn.safeTeleport(veh, mission._startingInfo.vehPos, mission._startingInfo.vehRot, nil, nil, nil, nil, false)
      end
    end
    if mission._startingInfo.startedFromCamera then
      core_camera.setPosRot(0,
        mission._startingInfo.camPos.x, mission._startingInfo.camPos.y, mission._startingInfo.camPos.z,
        mission._startingInfo.camRot.x, mission._startingInfo.camRot.y, mission._startingInfo.camRot.z, mission._startingInfo.camRot.w)
    end
  end

  if mission._startingInfo and mission._startingInfo.startedFromVehicle then
    commands.setGameCamera()
  end

  mission.script = nil
  if mission.mgr.runningState == 'stopped' then
    mission._startingInfo = nil
    step.complete = true
    extensions.hook("onAnyMissionChanged", "stopped", mission)
  end
end

local function taskStopRespawnVehicleStep(step)
  if not removeAllVehiclesBeforeMission then step.complete = true return end

  if not step.veh then
    local pos = core_camera.getPosition()
    pos.z = core_terrain.getTerrainHeight(pos)+0.5
    local options = {config = "kc6x_360_A", pos = pos}
    local spawningOptions = sanitizeVehicleSpawnOptions("etkc", options)
    spawningOptions.autoEnterVehicle = true
    spawningOptions.canSpawnAnotherVehicleCheck = false
    step.veh = core_vehicles.spawnNewVehicle("etkc", spawningOptions)
  end
  if step.veh:isReady() then
    spawn.teleportToLastRoad()
    gameplay_walk.getInVehicle(step.veh)
    commands.setGameCamera()
    step.complete = true
    return
  end
end

local function taskStopRespawnTrafficStep(step)
  if not removeAllVehiclesBeforeMission then step.complete = true return end

  if not step.started then
    gameplay_traffic.setupTraffic()
    step.started = true
  end
  if gameplay_traffic.getState() == 'on' then
    gameplay_traffic.scatterTraffic()
    gameplay_traffic.scatterTraffic()
    step.complete = true
  end

  step.complete = true
end

local function taskStopFadeStep(step)
  if not step.waitForFade then
    gameplay_rawPois.clear()
    core_gamestate.setGameState("freeroam","freeroam")
    guihooks.trigger('ChangeState', 'play')
    step.waitForFade = true
    ui_fadeScreen.stop(M.fadeDuration)
  end
  if step.fadeState3 then
    step.complete = true
  end
end

local function trafficActivated()
  if not taskData.active or not taskData.steps[taskData.currentStep] or not taskData.steps[taskData.currentStep].waitForTraffic then
    return
  end
  taskData.steps[taskData.currentStep].activated = true
end

M.onTrafficStarted = trafficActivated
M.onParkingVehiclesActivated = trafficActivated -- triggers if parked cars spawn but no traffic spawns

M.fadeDuration = 0.75
M.onScreenFadeState = function(state)
  if delayedStartFromWithinMission then
    if delayedStartFromWithinMission.currMission then
      delayedStartFromWithinMission.currMission.restoreStartingInfoSetup = true
      M.stop(delayedStartFromWithinMission.currMission, {ignoreFade = true})
      delayedStartFromWithinMission.currMission = nil
      return
    end
  end

  if not taskData.active or not taskData.steps[taskData.currentStep] or not taskData.steps[taskData.currentStep].waitForFade then
    return
  end
  taskData.steps[taskData.currentStep]["fadeState"..state] = true
end


local function startWithFade(mission, userSettings, startingOptions)
  if not mission then
    log("E", logTag, "Couldn't start mission, mission id not found. " .. dumpsz(mission, 2))
    return true
  end
  if mission._isOngoing then
    log("E", logTag, "Couldn't start mission, it's already ongoing: "..dumpsz(mission, 2))
    return true
  end
  if taskData.active then
    log("W", logTag, "Attempting to start mission while there is an active task: " .. dumpsz(taskData, 3))
    return
  end
  userSettings = userSettings or {}
  startingOptions = startingOptions or {}

  taskData.data = {mission = mission, userSettings = userSettings, startingOptions = startingOptions}
  taskData.type = "start"
  taskData.steps = {
    {
      name = "taskStartFadeStep",
      processTask = taskStartFadeStep,
      timeout = 10
    }, {
      name = "taskStartRemoveVehicles",
      processTask = taskStartRemoveVehicles
    }, {
      name = "taskStartPreMissionHandling",
      processTask = taskStartPreMissionHandling
    }, {
      name = "taskStartStashVehiclesStep",
      processTask = taskStartStashVehiclesStep
    }, {
      name = "taskStartVehicleStep",
      processTask = taskStartVehicleStep
    }, {
      name = "taskStartStartingOptionRepairStep",
      processTask = taskStartStartingOptionRepairStep
    },
  }

  if not startingOptions.skipPartConditionSnapshot then
    table.insert(taskData.steps, {
      name = "taskStartTakePartConditionSnapshot",
      processTask = taskStartTakePartConditionSnapshot
    })
  end

  arrayConcat(taskData.steps, {
     {
      name = "taskStartTrafficStep",
      processTask = taskStartTrafficStep
    }, {
      name = "taskStartMissionStep",
      processTask = taskStartMissionStep
    }}
  )

  taskData.active = true
  taskData.currentStep = 1
  log("I", logTag, "Starting mission with fade.")
  extensions.hook("onMissionStartWithFade", mission, userSettings)
end

local function startAsScenario(mission, userSettings)
  if not mission then
    log("E", logTag, "Couldn't start mission, mission id not found. " .. dumpsz(mission, 2))
    return true
  end
  if mission._isOngoing then
    log("E", logTag, "Couldn't start mission, it's already ongoing: "..dumpsz(mission, 2))
    return true
  end
  if taskData.active then
    log("W", logTag, "Attempting to start mission while there is an active task: " .. dumpsz(taskData, 3))
    return
  end

  taskData.data = {mission = mission, userSettings = userSettings}
  taskData.type = "start"
  taskData.steps = {
    {
      name = "taskStartPreMissionHandling",
      processTask = taskStartPreMissionHandling
    }, {
      name = "taskStartStashVehiclesStep",
      processTask = taskStartStashVehiclesStep
    }, {
      name = "taskStartVehicleStep",
      processTask = taskStartVehicleStep
    }, {
      name = "taskStartTrafficStep",
      processTask = taskStartTrafficStep
    }, {
      name = "taskStartMissionStep",
      processTask = taskStartMissionStep
    }
  }
  taskData.active = true
  taskData.currentStep = 1
  log("I", logTag, "Starting mission startAsScenario.")
end

local function startFromWithinMission(mission, userSettings, instant)
  if not foregroundMissionId then
    log("W", logTag, "No foreground mission id, skipping startFromWithinMission.")
    return
  end

  delayedStartFromWithinMission = {
    currMission = gameplay_missions_missions.getMissionById(foregroundMissionId),
    mission = mission,
    userSettings = userSettings,
    skipPartConditionSnapshot = true,
    instant = instant
  }

  -- deducing that we are reconfiguring the mission
  if mission.id == foregroundMissionId then
    extensions.hook("onMissionReconfigured", {mission = mission, oldUserSettings = mission.lastUserSettings, newUserSettings = userSettings})
  end
  if not instant then
    log("I", logTag, "Delaying start of mission from within another mission for fade.")
    --ui_fadeScreen.delayFrames = 15
    ui_fadeScreen.start(M.fadeDuration, getFadeScreenData(mission))
  else
    delayedStartFromWithinMission.currMission.restoreStartingInfoSetup = false
    M.stop(delayedStartFromWithinMission.currMission, {ignoreFade = true})
    delayedStartFromWithinMission.currMission = nil
  end
end

local function startInstant(mission, userSettings, startingOptions)
  userSettings = userSettings or {}
  startingOptions = startingOptions or {}

  taskData.data = {mission = mission, userSettings = userSettings, startingOptions = startingOptions}
  taskData.type = "start"
  taskData.steps = {
    {
      name = "taskStartPreMissionHandling",
      processTask = taskStartPreMissionHandling,
      ignoreStash = true
    }, {
      name = "taskStartMissionStep",
      processTask = taskStartMissionStep,
      ignoreStash = true
    }
  }


  taskData.active = true
  taskData.currentStep = 1
  log("I", logTag, "Starting mission isntantly from within another mission.")
  extensions.hook("startFromWithinMissionInstant", mission, userSettings, startingOptions)
end

local function startWithLoadingLevel(mission, userSettings, level)
  if not mission then
    log("E", logTag, "Couldn't start mission, mission id not found. " .. dumpsz(mission, 2))
    return true
  end
  if taskData.active then
    log("W", logTag, "Attempting to start mission while there is an active task: " .. dumpsz(taskData, 3))
    return
  end

  local level = level or mission.startTrigger.level
  if not level then
    log("E", logTag, "Couldn't start mission, level not found. " .. dumpsz(mission, 2))
    return true
  end

  if foregroundMissionId then
    M.stopForegroundMissionInstantly()
  end


  taskData.data = {mission = mission, userSettings = userSettings, level = level}
  taskData.type = "start"
  taskData.steps = {
    {
      name = "taskLoadLevelStep",
      processTask = taskLoadLevelStep,
      level = level
    }, {
      name = "taskStartPreMissionHandling",
      processTask = taskStartPreMissionHandling
    }, {
      name = "taskStartStashVehiclesStep",
      processTask = taskStartStashVehiclesStep
    }, {
      name = "taskStartVehicleStep",
      processTask = taskStartVehicleStep
    }, {
      name = "taskStartTrafficStep",
      processTask = taskStartTrafficStep
    }, {
      name = "taskStartMissionStep",
      processTask = taskStartMissionStep
    }
  }
  taskData.active = true
  taskData.currentStep = 1



  log("I", logTag, "Starting mission with loading level.")
end

local function attemptAbandonMissionWithFade(mission, force, abandonButtonPressed)
  --dump("attemptAbandonMissionWithFade")
  --print(debug.tracesimple())
  if not mission then
    log("E", logTag, "Couldn't stop mission, mission id not found.")
    return true
  end
  if not mission._isOngoing then
    log("E", logTag, "Couldn't stop mission, it's not ongoing: "..dumps(mission.id))
    return true
  end
  if taskData.active then
    log("W", logTag, "Attempting to stop mission while there is an active task.")
    return
  end
  mission.restoreStartingInfoSetup = true

  -- this mission handles stopping themselves..
  if mission:attemptAbandonMission() then
    log("I", logTag, "Requesting faded abandon for mission, not force stopping. : "..dumps(mission.id))
    return true
  end

  taskData.data = {mission = mission, data = {}}

  if abandonButtonPressed then
    taskData.data.data.abandoned = true
  end

  taskData.type = "stop"
  taskData.active = true
  taskData.steps = {{
      name = "taskStartFadeStep",
      processTask = taskStartFadeStep,
      timeout = 10
    }, {
      name = "taskStopMissionStep",
      processTask = taskStopMissionStep,
    }, {
      name = "taskStopRestoreStashedVehiclesStep",
      processTask = taskStopRestoreStashedVehiclesStep,
    }, {
      name = "taskStopMissionPostStep",
      processTask = taskStopMissionPostStep,
    }, {
      name = "taskStartRemoveVehicles",
      processTask = taskStartRemoveVehicles,
    }, {
      name = "taskStopRespawnVehicleStep",
      processTask = taskStopRespawnVehicleStep,
    }, {
      name = "taskStopRespawnTrafficStep",
      processTask = taskStopRespawnTrafficStep,
    }, {
      name = "taskStopFadeStep",
      processTask = taskStopFadeStep,
      timeout = 5
    }
  }
  taskData.currentStep = 1

  extensions.hook("onMissionAbandoned", mission)
  log("I", logTag, "Delaying abandonment of mission for fade.")
end

local function stop(mission, data)
  --dump("stop")
  --print(debug.tracesimple())
  data = data or {}
  if not mission then
    log("E", logTag, "Couldn't stop mission, mission id not found.")
    return true
  end
  if not mission._isOngoing then
    log("E", logTag, "Couldn't stop mission, it's not ongoing: "..dumps(mission.id))
    return true
  end
  if taskData.active then
    log("W", logTag, "Attempting to stop mission while there is an active task.")
    return
  end
  taskData.data = {mission = mission, data = data or {}}
  taskData.type = "stop"
  taskData.active = true
  taskData.steps = {
    {
      name = "taskStopMissionStep",
      processTask = taskStopMissionStep,
    }, {
      name = "taskStopRestoreStashedVehiclesStep",
      processTask = taskStopRestoreStashedVehiclesStep,
    }, {
      name = "taskStopMissionPostStep",
      processTask = taskStopMissionPostStep,
    }, {
      name = "taskStartRemoveVehicles",
      processTask = taskStartRemoveVehicles,
    }, {
      name = "taskStopRespawnVehicleStep",
      processTask = taskStopRespawnVehicleStep,
    }, {
      name = "taskStopRespawnTrafficStep",
      processTask = taskStopRespawnTrafficStep,
    }
  }
  taskData.currentStep = 1
  if not data.ignoreFade then
    table.insert(taskData.steps,{
      name = "taskStopFadeStep",
      processTask = taskStopFadeStep,
      timeout = 5,
    })
  end

  extensions.hook("onMissionStopped", mission)
end

-- WIP for allowing or disallowing missions
M.allowMissionInteraction = function()
  if core_gamestate.state and core_gamestate.state.state ~= "freeroam" then
    return false
  end
  return true
end

local showDebugWindow = false
local debugApprove = false
local function onUpdate(dtReal, dtSim, dtRaw)
  if showDebugWindow then
    local im = ui_imgui
    im.Begin("Mission Manager Debug")
    im.Text("Steps")
    if not taskData.active then im.BeginDisabled() end
    for i, step in ipairs(taskData.steps) do
      im.TextWrapped(string.format("%s%d - %s",taskData.currentStep == i and "ACTIVE " or "", i, step.name or "Unnamed Step"))
      im.Text(dumps(step))
      if debugApprove and i==taskData.currentStep and step.complete then
        if im.Button("Approve##"..i) then
          step.approved = true
        end
      end
      im.Separator()
    end
    im.TextWrapped(dumpsz(taskData.data, 3))
    if not taskData.active  then im.EndDisabled() end
    im.End()
  end

  if taskData.active then
    local stepToHandle = taskData.steps[taskData.currentStep]
    while stepToHandle do
      stepToHandle.processTask(stepToHandle, taskData)
      if not stepToHandle._startingTime then stepToHandle._startingTime = os.time() end
      if os.time() - stepToHandle._startingTime > (stepToHandle.timeout or 120) then
        log("E","","This step timed out ("..(stepToHandle.timeout or 120).."s). Step will be set to complete.")
        --dump(stepToHandle)
        --dump(taskData)
        stepToHandle.complete = true
      end
      if stepToHandle.complete then
        log("I", logTag, string.format("Completed Step: %s", stepToHandle.name or "Unnamed Task"))
        taskData.currentStep = taskData.currentStep + 1
        stepToHandle = taskData.steps[taskData.currentStep]
        if not stepToHandle then
          taskData.active = false
        end
      else
        stepToHandle = nil
      end
    end
  else
    if delayedStartFromWithinMission then
      if not delayedStartFromWithinMission.currMission then
        local fun = delayedStartFromWithinMission.instant and M.startInstant or M.startWithFade
        local fail = fun(delayedStartFromWithinMission.mission, delayedStartFromWithinMission.userSettings,
          {
            skipPartConditionSnapshot = delayedStartFromWithinMission.skipPartConditionSnapshot
          }
        )
        if fail then
          log("W", logTag, "Delayed mission failed to load!")
          ui_fadeScreen.stop(0)
        else
          log("I", logTag, "Delayed mission now loading: " .. dumps(delayedStartFromWithinMission.mission.id))
          fadedScreen = true
        end
        delayedStartFromWithinMission = nil
      end
    end
  end

  --if not M.allowMissionInteraction() then return end

  -- run all ongoing activities
  if foregroundMissionId then
    for _, mission in ipairs(gameplay_missions_missions.getAllMissions()) do
      if mission._isOngoing then
        mission:onUpdate(dtReal, dtSim, dtRaw)
      end
    end
  end
end


-- when we change level, immediately stop mission, but don't clean up.
local function stopForegroundMissionInstantly()
  if M.getForegroundMissionId() then
    taskData.data = {mission = gameplay_missions_missions.getMissionById(M.getForegroundMissionId()), data = {stopInstant = true}}
    taskStopMissionStep({})
  end
end

M.start = startWithFade
M.startWithFade = startWithFade
M.startAsScenario = startAsScenario
M.startFromWithinMission = startFromWithinMission
M.startInstant = startInstant
M.startWithLoadingLevel = startWithLoadingLevel
M.stop = stop
M.attemptAbandonMissionWithFade = attemptAbandonMissionWithFade

M.getCurrentTaskdataTypeOrNil = function()
  if delayedStartFromWithinMission then return "start" end
  if not taskData or not taskData.active then return nil end
  return taskData.type
end

-- external callbacks
M.onUpdate = onUpdate
M.onClientEndMission = stopForegroundMissionInstantly -- this is related to level load, not to missions
M.onCareerActive = stopForegroundMissionInstantly
M.stopForegroundMissionInstantly = stopForegroundMissionInstantly
-- exclusivity
M.getForegroundMissionId = function() return foregroundMissionId end
M.isCurrentlyProcessingStep = function() return taskData and taskData.active end

return M