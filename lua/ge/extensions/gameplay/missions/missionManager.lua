-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"gameplay_traffic", "gameplay_police", "gameplay_parking"}
local missions = {}

local logTag = "missionManager"

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

local function stashVehicles()
  local setupData = taskData.data.mission.setupData
  setupData._hasStashedVehicles = true

  for id, v in pairs(setupData.stashedVehicles) do
    if v == false and be:getObjectByID(id) then
      log("D", logTag, "Stashing vehicle for mission setup: "..id)
      be:getObjectByID(id):setActive(0)
      setupData.stashedVehicles[id] = true
    end
  end
end

local function unstashVehicles()
  local setupData = taskData.data.mission.setupData
  setupData._hasStashedVehicles = nil

  for id, v in pairs(setupData.stashedVehicles) do
    if v == true and be:getObjectByID(id) then
      log("D", logTag, "Unstashing vehicle for mission setup: "..id)
      be:getObjectByID(id):setActive(1)
      core_vehicleBridge.executeAction(be:getObjectByID(id), "setFreeze", false)
    end
  end
  table.clear(setupData.stashedVehicles)
end

local function getFadeScreenData(mission)
  local preview = mission.previewFile
  if preview and string.find(preview, "noPreview") then preview = nil end
  local tips = mission:getMissionTips() or {}
  return {image = preview, title = mission.name, subtitle = "ui.mission.loading.loading", text = mission.description, tips = tips[math.random(#tips)]}
end

local function taskStartFadeStep(step)
  if fadedScreen then -- if screen is already black, complete this step
    step.complete = true
    fadedScreen = false
    ui_fadeScreen.delayFrames = 1
    return
  end
  if not step.waitForFade then
    if taskData.type == "start" then
      ui_fadeScreen.delayFrames = 15 -- extra delay, to pad loading time and ensure fancy loading screen is shown
      ui_fadeScreen.start(M.fadeDuration, getFadeScreenData(taskData.data.mission))
    else
      ui_fadeScreen.start(M.fadeDuration)
    end

    step.waitForFade = true
  end
  if step.fadeState1 then
    step.complete = true
    ui_fadeScreen.delayFrames = 1
  end
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

  -- freeze traffic state here (before new vehicles get created)
  local trafficSetup = mission.setupModules.traffic
  if not trafficSetup.usePrevTraffic then

    if gameplay_traffic.getState() == 'on' then
      trafficSetup._prevTraffic, trafficSetup._prevPolice, trafficSetup._prevParking = gameplay_traffic.freezeState() -- stash previous traffic
      log("I", logTag, "Now storing current traffic state")
    end

    gameplay_traffic.setTrafficVars() -- resets variables
    gameplay_police.setPursuitVars()
    gameplay_parking.setParkingVars()
  end

  -- prepare vehicle stash
  mission.setupData._hasStashedVehicles = nil
  table.clear(mission.setupData.stashedVehicles)
  for _, name in ipairs(scenetree.findClassObjects("BeamNGVehicle")) do
    local obj = scenetree.findObject(name)
    if obj and obj:getActive() then
      mission.setupData.stashedVehicles[obj:getId()] = false
    end
  end

  -- custom mission script
  local scriptPath = mission.missionFolder.."/script"
  if FS:fileExists(scriptPath..".lua") then
    mission.script = require(scriptPath)({mission = mission})
    log("I", logTag, "Initializing custom mission script")
  end
end

local function taskStartVehicleStep(step)
  local vehicleSetup = taskData.data.mission.setupModules.vehicles
  local userSettings = taskData.data.userSettings or {}

  if not vehicleSetup.enabled then
    step.complete = true
  else
    local playerId = taskData.data.mission._startingInfo and taskData.data.mission._startingInfo.vehId
    local idx = vehicleSetup._selectionIdx

    if vehicleSetup.usePlayerVehicle or not vehicleSetup.vehicles or not idx then -- if selection does not exist, use player vehicle
      vehicleSetup.usePlayerVehicle = true
      if playerId then
        taskData.data.mission.setupData.stashedVehicles[playerId] = nil
      end
      step.complete = true
    else
      if not step.waitForPlayerVehicle then
        step.waitForPlayerVehicle = true

        local vehicleInstance = vehicleSetup.vehicles[idx]
        local model, config = vehicleInstance.model, vehicleInstance.configPath
        if vehicleInstance.customConfigPath and FS:fileExists(vehicleInstance.customConfigPath) then
          config = vehicleInstance.customConfigPath
          log("I", logTag, "Custom part config found and accepted for vehicle setup")
        end

        local paintData = core_vehicles.getModel(model).model.paints
        local paint = vehicleInstance.paintName and paintData[vehicleInstance.paintName]
        local paint2 = vehicleInstance.paintName2 and paintData[vehicleInstance.paintName2]
        local paint3 = vehicleInstance.paintName3 and paintData[vehicleInstance.paintName3]

        local options = {config = config, paint = paint, paint2 = paint2, paint3 = paint3}
        local spawningOptions = sanitizeVehicleSpawnOptions(model, options)
        spawningOptions.autoEnterVehicle = true
        step.veh = core_vehicles.spawnNewVehicle(model, spawningOptions)
      end
    end
  end

  if step.veh and step.veh:isReady() then
    vehicleSetup.vehId = step.veh:getID()
    step.complete = true
  end
end

local function taskStartStartingOptionRepairStep(step)
  -- skip this step if career is not loaded
  if not career_modules_inventory then step.complete = true return end

  if step.handled then return end

  local mission = taskData.data.mission

  if mission._startingInfo
    and taskData.data.startingOptions and taskData.data.startingOptions.repair
    and taskData.data.startingOptions.repair.type ~= "defaultStart"
    and taskData.data.startingOptions.repair.type ~= "noRepair" then
    local vehId = mission._startingInfo.startedFromVehicle and mission._startingInfo.vehId
    local inventoryVehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId or 0)
    if inventoryVehId then
      local repairType = taskData.data.startingOptions.repair.type

      --payment
      local price = gameplay_missions_missionScreen.getRepairCostForStartingRepairType(repairType)
      career_modules_playerAttributes.addAttributes(price, {label = "Repairing Vehicle before Challenge"})
      local claimPrice = {}
      for att, amount in pairs(price) do
        claimPrice[att] = {amount = amount}
      end
      career_modules_insurance.makeRepairClaim(inventoryVehId, claimPrice)

      -- actual repairing
      career_modules_inventory.updatePartConditions(nil, inventoryVehId,
        function()
          career_modules_insurance.startRepair(inventoryVehId, nil, function()
            step.complete = true
          end)
        end)
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
    end
    for _, id in ipairs(gameplay_parking.getParkedCarsList()) do
      taskData.data.mission.setupData.stashedVehicles[id] = nil
    end

    step.activated = true
    gameplay_traffic.forceTeleportAll()
  end

  if not step.waitForTraffic then
    step.waitForTraffic = true

    if trafficSetup.enabled and trafficSetup.useTraffic and not step.activated then -- spawn new traffic
      local options = {ignoreDelete = true, ignoreAutoAmount = true}
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
      step.validTraffic = gameplay_traffic.setupTraffic(trafficSetup.amount, 0, options)
      if not step.validParking and not step.validTraffic then -- no vehicles to spawn, just continue
        step.complete = true
      end
      gameplay_traffic.queueTeleport = step.validTraffic -- forces vehicles to teleport after spawning
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
  if taskData.data.startLoadingTime and os.time() - taskData.data.startLoadingTime < 5 then return end -- minimum loading screen time while the user reads

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

  mission.setupModules.timeOfDay._originalTimeOfDay = deepcopy(core_environment.getTimeOfDay())
  if mission.setupModules.timeOfDay.enabled then
    mission.setupModules.timeOfDay._processed = true
    local tod = deepcopy(core_environment.getTimeOfDay())
    tod.time = mission.setupModules.timeOfDay.time
    core_environment.setTimeOfDay(tod)
  end

  stashVehicles()

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
  local mission = taskData.data.mission
  if step.handled then
    if mission.mgr.runningState == 'stopped' then
      mission._startingInfo = nil
      step.complete = true
      extensions.hook("onAnyMissionChanged", "stopped", mission)
    end
    return
  end
  step.handled = true

  local data = taskData.data.data
  data = data or {}
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
  local prevVeh = prevId and be:getObjectByID(prevId) -- checks if it exists; the vehicle can get removed before this step
  if mission.setupModules.vehicles._processed and prevVeh and mission.setupModules.vehicles.vehId and prevId ~= mission.setupModules.vehicles.vehId then
    local vehObj = be:getObjectByID(mission.setupModules.vehicles.vehId)
    if vehObj then vehObj:delete() end
  end
  mission.setupModules.vehicles._processed = nil

  if mission.setupModules.traffic._processed and not mission.setupModules.traffic.usePrevTraffic then
    gameplay_traffic.deleteVehicles()
    gameplay_parking.deleteVehicles()
  end
  unstashVehicles()

  local trafficSetup = mission.setupModules.traffic
  if trafficSetup._prevTraffic and not trafficSetup.usePrevTraffic then
    gameplay_traffic.unfreezeState(trafficSetup._prevTraffic, trafficSetup._prevPolice, trafficSetup._prevParking)
    log("I", logTag, "Now restoring previous traffic state")
  end
  trafficSetup._prevTraffic, trafficSetup._prevPolice, trafficSetup._prevParking, trafficSetup._processed = nil, nil, nil, nil

  if mission.setupModules.timeOfDay._originalTimeOfDay then
    core_environment.setTimeOfDay(mission.setupModules.timeOfDay._originalTimeOfDay)
    mission.setupModules.timeOfDay._originalTimeOfDay = nil
    mission.setupModules.timeOfDay._processed = nil
  end

  -- starting info reset
  if mission.restoreStartingInfoSetup and mission._startingInfo then
    if mission._startingInfo.startedFromVehicle then
      local veh = be:getObjectByID(mission._startingInfo.vehId)
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
end

local function taskStopFadeStep(step)
  if not step.waitForFade then
    ui_fadeScreen.stop(M.fadeDuration)
    step.waitForFade = true
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

  taskData.data = {mission = mission, userSettings = userSettings, startingOptions = startingOptions or {}}
  taskData.type = "start"
  taskData.steps = {
    {
      name = "taskStartFadeStep",
      processTask = taskStartFadeStep,
      timeout = 10
    }, {
      name = "taskStartPreMissionHandling",
      processTask = taskStartPreMissionHandling
    }, {
      name = "taskStartVehicleStep",
      processTask = taskStartVehicleStep
    }, {
      name = "taskStartStartingOptionRepairStep",
      processTask = taskStartStartingOptionRepairStep
    }, {
      name = "taskStartTakePartConditionSnapshot",
      processTask = taskStartTakePartConditionSnapshot
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

local function startFromWithinMission(mission, userSettings)
  if not foregroundMissionId then return end
  delayedStartFromWithinMission = {
    currMission = gameplay_missions_missions.getMissionById(foregroundMissionId),
    mission = mission,
    userSettings = userSettings
  }
  log("I", logTag, "Delaying start of mission from within another mission for fade.")
  ui_fadeScreen.delayFrames = 15
  ui_fadeScreen.start(M.fadeDuration, getFadeScreenData(mission))
end

local function attemptAbandonMissionWithFade(mission)
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
  taskData.type = "stop"
  taskData.active = true
  taskData.steps = {
    {
      name = "taskStartFadeStep",
      processTask = taskStartFadeStep,
      timeout = 10
    }, {
      name = "taskStopMissionStep",
      processTask = taskStopMissionStep,
    }, {
      name = "taskStopFadeStep",
      processTask = taskStopFadeStep,
      timeout = 5
    }
  }
  taskData.currentStep = 1

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
        local fail = M.startWithFade(delayedStartFromWithinMission.mission, delayedStartFromWithinMission.userSettings)
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
  for _, mission in ipairs(gameplay_missions_missions.get()) do
    if mission._isOngoing then
      mission:onUpdate(dtReal, dtSim, dtRaw)
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
M.stop = stop
M.attemptAbandonMissionWithFade = attemptAbandonMissionWithFade

-- external callbacks
M.onUpdate = onUpdate
M.onClientEndMission = stopForegroundMissionInstantly -- this is related to level load, not to missions
M.onCareerActive = stopForegroundMissionInstantly
M.stopForegroundMissionInstantly = stopForegroundMissionInstantly
-- exclusivity
M.getForegroundMissionId = function() return foregroundMissionId end

return M
