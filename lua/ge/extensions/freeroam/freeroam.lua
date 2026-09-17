-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt


local M = {state={}}
M.dependencies = {"core_environment"}

local logTag = 'freeroam'

local inputActionFilter = extensions.core_input_actionFilter

M.spawningOptionsHelper = {
  -- traffic options
  trafficMode = "fromSetting", -- options: "fromSetting", "disabled", "enabled"
  trafficAmount = -1, -- options: -1 (auto), 0 (disabled), 1+ (amount)
  trafficPolice = "disabled", -- options: "disabled", "enabled"
  trafficParked = "disabled", -- options: "disabled", "enabled"
  trafficParkedAmount = -1, -- options: -1 (auto), 0 (disabled), 1+ (amount)

  -- environment options
  timeOfDay = "default", -- options: "default", "current", "currentUtc", any of the keys from level's time of day options, or a number between 0 and 1
  date = nil, -- unix epoch seconds, used to set the environment year/month/day
  timePlay = "disabled", -- options: "disabled", "slow", "normal", "fast" - time progression speed

  -- meta options
  resetOptionsAfterStartingFreeroam = true, -- options: true, false
}
local defaultSpawningOptions = deepcopy(M.spawningOptionsHelper)

M.resetSpawningOptions = function()
  M.spawningOptionsHelper = deepcopy(defaultSpawningOptions)
end


local function startFreeroamHelper (level, startPointName, spawnVehicle, customLoadingFunction)
  unloadAutoExtensions()
  loadPresetExtensions()
  M.state = {}
  M.state.freeroamActive = true

  local levelPath = level
  if type(level) == 'table' then
    setSpawnpoint.setDefaultSP(startPointName, level.levelName)
    levelPath = level.misFilePath
  end

  inputActionFilter.clear(0)

  if spawnVehicle == false then
    -- clear the previous vehicle data so we don't spawn a vehicle
    VariableRegistry.set('$beamngVehicle', '')
    VariableRegistry.set('$beamngVehicleConfig', '')
    VariableRegistry.set('$beamngVehicleColor', '')
    VariableRegistry.set('$beamngVehicleMetallicPaintData', '')
    VariableRegistry.set('$beamngVehicleLicenseName', '')
    VariableRegistry.set('$beamngVehicleArgs', '')
  end
  core_levels.startLevel(levelPath, nil, customLoadingFunction, spawnVehicle)
end

local function startAssociatedFlowgraph(levelName)
  local level = core_levels.getLevelByName(levelName)
  -- load flowgraphs associated with this level.
  if level and level.flowgraphs then
    for _, absolutePath in ipairs(level.flowgraphs or {}) do
      local relativePath = level.misFilePath..absolutePath
      local path = FS:fileExists(absolutePath) and absolutePath or (FS:fileExists(relativePath) and (relativePath) or nil)
      if path then
        local mgr = core_flowgraphManager.loadManager(path)
        --core_flowgraphManager.startOnLoadingScreenFadeout(mgr)
        mgr:setRunning(true)
        mgr.stopRunningOnClientEndMission = true -- make mgr self-destruct when level is ended.
        mgr.removeOnStopping = true -- make mgr self-destruct when level is ended.
        log("I", "Flowgraph loading", "Loaded level-associated flowgraph from file "..dumps(path))
      else
        log("E", "Flowgraph loading", "Could not find file in either '" .. absolutePath.."' or '" .. relativePath.."'!")
      end
    end
  end
end

local function startFreeroam(level, startPointName, wasDelayed, spawnVehicle, customLoadingFunction)
  core_gamestate.requestEnterLoadingScreen(logTag)
  -- if this was a delayed start, load the FGs now.
  --if wasDelayed then
  --  startAssociatedFlowgraph(level)
  --end

  -- this is to prevent bug where freeroam is started while a different level is still loaded.
  -- Loading the new freeroam causes the current loaded freeroam to unload which breaks the new freeroam
  --local delaying = false
  if scenetree.MissionGroup then
    log('D', logTag, 'Delaying start of freeroam until current level is unloaded...')
    local func = function()
      startFreeroam(level, startPointName, true, spawnVehicle, customLoadingFunction)
    end
    endActiveGameMode(triggerDelayedStartGenerator(logTag, 'freeroam', func, true))
    --delaying = true
  elseif not core_gamestate.getLoadingStatus(logTag .. '.startFreeroamHelper') then -- remove again at some point
    startFreeroamHelper(level, startPointName, spawnVehicle, customLoadingFunction)
    core_gamestate.requestExitLoadingScreen(logTag)
  end
  -- if there was no delaying and the function call itself didnt
  -- come from a delayed start, load the FGs (starting from main menu)

end

local function startFreeroamByName(levelName, startPointName, wasDelayed, spawnVehicle, customLoadingFunction)
  local level = core_levels.getLevelByName(levelName)
  if level then
    startFreeroam(level, startPointName, wasDelayed, spawnVehicle, customLoadingFunction)
    return true
  end
  return false
end

local function onPlayerCameraReady()
  -- set up traffic, parking, and maybe other systems
  -- figure out traffic loading and override if set in spawningOptionsHelper
  local loadTraffic = false
  if M.spawningOptionsHelper.trafficMode == "disabled" then
    loadTraffic = false
  elseif M.spawningOptionsHelper.trafficMode == "enabled" then
    loadTraffic = true
  end

  local loadParking = false
  if M.spawningOptionsHelper.trafficParked == "disabled" then
    loadParking = false
  elseif M.spawningOptionsHelper.trafficParked == "enabled" then
    loadParking = true
  end

  local trafficAmount, parkingAmount = -1, -1
  if M.spawningOptionsHelper.trafficAmount ~= -1 then
    trafficAmount = M.spawningOptionsHelper.trafficAmount
  end
  if M.spawningOptionsHelper.trafficParkedAmount ~= -1 then
    parkingAmount = M.spawningOptionsHelper.trafficParkedAmount
  end

  if not loadTraffic then
    trafficAmount = 0
  end
  if not loadParking then
    parkingAmount = 0
  end

  local levelName = getCurrentLevelIdentifier()
  local level = core_levels.getLevelByName(levelName)
  local supportsTraffic = true
  if level then
    supportsTraffic = level.supportsTraffic
  end

  if not supportsTraffic then
    loadTraffic = false
    loadParking = false
  end

  if loadTraffic and loadParking and not settings.getValue('trafficParkedVehicles') then -- use setting to disable parking in this case
    loadParking = false
    parkingAmount = 0
  end

  if not M.state.freeroamActive or (not loadTraffic and not loadParking) then -- return now, as nothing is needed for traffic systems
    return
  end

  core_gamestate.requestEnterLoadingScreen('traffic')

  local usePolice = M.spawningOptionsHelper.trafficPolice == "enabled"
  local trafficOptions = {police = usePolice}
  local parkingOptions = {}

  log('I', logTag, string.format('Now spawning traffic for freeroam mode (%s parked vehicles, %s police vehicles)', loadParking and 'with' or 'without', usePolice and 'with' or 'without'))
  gameplay_traffic.setupTrafficHelper(trafficAmount, trafficOptions, parkingAmount, parkingOptions)
end

local function onTrafficOrParkingReady()
  if M.state.freeroamActive and core_gamestate.getLoadingStatus('traffic') then
    core_gamestate.requestExitLoadingScreen('traffic')
  end
end

local function onClientPreStartMission(levelPath)
  local path, file, _ = path.splitWithoutExt(levelPath)
  file = path .. 'mainLevel'
  if not FS:fileExists(file..'.lua') then return end
  extensions.loadAtRoot(file,"")
  if mainLevel and mainLevel.onClientPreStartMission then
    mainLevel.onClientPreStartMission(levelPath)
  end
end

local function onClientStartMission(levelPath)
  --local path, file, ext = path.splitWithoutExt(levelPath)
  --file = path .. 'mainLevel'

  if M.state.freeroamActive then
    extensions.hook('onFreeroamLoaded', levelPath)

    local am = scenetree.findObject("ExplorationCheckpointsActionMap")
    if am then am:push() end
  end
end

local function dateFromEpoch(epoch)
  epoch = tonumber(epoch)
  if not epoch then return nil end

  local ok, date = pcall(os.date, "*t", epoch)
  if not ok or type(date) ~= "table" then return nil end

  local year = tonumber(date.year)
  local month = tonumber(date.month)
  local day = tonumber(date.day)
  if not year or not month or not day then return nil end

  return {year = year, month = month, day = day}
end

local function onClientPostStartMission(levelPath)
  -- set environment date if set in spawningOptionsHelper
  if M.spawningOptionsHelper.date then
    local date = dateFromEpoch(M.spawningOptionsHelper.date)
    if date then
      log('I', logTag, string.format('Setting environment date to: %04d-%02d-%02d', date.year, date.month, date.day))
      core_environment.setTimeOfDay(date)
    else
      log('W', logTag, 'Environment date is invalid: ' .. tostring(M.spawningOptionsHelper.date))
    end
  end

  -- set time of day if set in spawningOptionsHelper
  if M.spawningOptionsHelper.timeOfDay ~= "default" then
    log('I', logTag, 'Setting time of day to: ' .. tostring(M.spawningOptionsHelper.timeOfDay))
    local time = M.spawningOptionsHelper.timeOfDay
    if time == "current" then
      core_environment.syncTimeToRealClock()
      time = nil
    elseif time == "currentUtc" then
      core_environment.syncTimeToRealClockUtc()
      time = nil
    elseif type(time) == 'string' then
      -- Get time of day options for the current level
      local levelName = getCurrentLevelIdentifier()
      local timeOfDayOptions = core_environment.getTimeOfDayOptions(levelName)
      local timeValue = nil

      -- Find the time value for the given key
      for _, option in ipairs(timeOfDayOptions) do
        if option.key == time then
          timeValue = option.value
          break
        end
      end

      if timeValue then
        log('I', logTag, 'Time of day found: ' .. tostring(timeValue))
        time = timeValue
      else
        log('W', logTag, 'Time of day key not found: ' .. tostring(time))
        time = nil
      end
    end
    if type(time) == 'number' then
      log('I', logTag, 'Setting time of day to: ' .. tostring(time))
      core_environment.setTimeOfDay({time = time})
    end
  end

   -- set time play if set in spawningOptionsHelper
   if M.spawningOptionsHelper.timePlay and M.spawningOptionsHelper.timePlay ~= "disabled" then
     log('I', logTag, 'Setting time progression to: ' .. tostring(M.spawningOptionsHelper.timePlay))

     local dayLength = 1800 -- normal: a full day in 30 min
     if M.spawningOptionsHelper.timePlay == "slow" then
       dayLength = 7200
     elseif M.spawningOptionsHelper.timePlay == "fast" then
       dayLength = 900
     elseif M.spawningOptionsHelper.timePlay == "realtime" then
       dayLength = 24 * 60 * 60
     end
     local time = core_environment.getTimeOfDay()
     core_environment.setTimeOfDay({play = true, dayLength = dayLength, time = time.time})
   end

   -- reset environment options to default
   M.spawningOptionsHelper.timeOfDay = "default"
   M.spawningOptionsHelper.date = nil
   M.spawningOptionsHelper.timePlay = "disabled"

   -- start flowgraph (except for scenarios)
   if scenario_scenarios == nil or scenario_scenarios.getScenario() == nil then
     startAssociatedFlowgraph(getCurrentLevelIdentifier())
   end
end

local function onClientEndMission(levelPath)
  if M.state.freeroamActive then
    M.state.freeroamActive = false
    local am = scenetree.findObject("ExplorationCheckpointsActionMap")
    if am then am:pop() end
  end

  if not mainLevel then return end
  local path, _, _ = path.splitWithoutExt(levelPath)
  extensions.unload(path .. 'mainLevel')
end

-- Resets previous vehicle alpha when switching between different vehicles
-- Used to fix multipart highlighting when switching vehicles
local function onVehicleSwitched(oldId, newId, player)
  extensions.core_vehicle_partmgmt.showHighlightedParts(oldId)
end

local function onVehicleSpawned(vehID)
  extensions.core_vehicle_partmgmt.resetVehicleHighlights(true, vehID)
  extensions.core_vehicle_partmgmt.setNewParts(vehID)
  extensions.core_vehicle_partmgmt.showHighlightedParts(vehID)
end

local function onResetGameplay(playerID)
  if scenario_scenarios and scenario_scenarios.getScenario() then return end
  if campaign_campaigns and campaign_campaigns.getCampaign() then return end
  --if career_career and career_career.isActive() then return end
  if core_recoveryPrompt.isActive() then return end
  for _, mgr in ipairs(core_flowgraphManager.getAllManagers()) do
    if mgr:blocksOnResetGameplay() then return end
  end

  be:resetVehicle(playerID)
  -- if core_intapi then
  --   core_intapi.debug_resetVehicle(playerID)
  -- else
  --   be:resetVehicle(playerID)
  -- end
end

local function startTrackBuilder(levelName, forceLoad)
  extensions.load("trackbuilder_trackBuilder")

  if not trackbuilder_trackBuilder then
    log('E', logTag, 'Could not find trackbuilder extentions')
    return
  end

  if getCurrentLevelIdentifier() == nil or forceLoad then
    local level = core_levels.getLevelByName(levelName)
    if not level then
      log('E', logTag, 'Level not found: ' .. tostring(levelName))
      return
    end

    local callback = function ()
      log('I', logTag, 'startTrackBuilder callback triggered...')
      trackbuilder_trackBuilder.showTrackBuilder()
    end

    extensions.setCompletedCallback("onClientStartMission", callback);
    startFreeroam(level)
  else
    trackbuilder_trackBuilder.toggleTrackBuilder()
    guihooks.trigger("MenuHide")
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if worldReadyState == 0 then
    commands.initCamera()
    if not getPlayerVehicle(0) then
      commands.setFreeCamera()
    end
  end
end

local function isStateFreeroam()
  if core_gamestate.state and (core_gamestate.state.state == "freeroam") then
    return true
  end
  return false
end

local function onSpeedTrapTriggered(speedTrapData, playerSpeed, overSpeed)
  if not speedTrapData.speedLimit then return end
  if not isStateFreeroam() or speedTrapData.subjectID ~= be:getPlayerVehicleID(0) then
    return
  end
  local veh = getPlayerVehicle(0)
  local highscore, leaderboard = gameplay_speedTrapLeaderboards.addRecord(speedTrapData, playerSpeed, overSpeed, veh)
  ui_message({txt="ui.freeroam.speedTrap.speedingMessage", context={licensePlate = core_vehicles.getVehicleLicenseText(veh), recordedSpeed = playerSpeed, speedLimit = speedTrapData.speedLimit}}, 10, 'speedTrap')

  local message
  if highscore then
    if leaderboard[2] then
      message = {txt="ui.freeroam.speedTrap.newRecord", context={recordedSpeed = playerSpeed, previousSpeed = leaderboard[2].speed}}
    else
      message = {txt="ui.freeroam.speedTrap.newRecordNoOld", context={recordedSpeed = playerSpeed}}
    end
  else
    message = {txt="ui.freeroam.speedTrap.noNewRecord", context={recordedSpeed = playerSpeed, recordSpeed = leaderboard[1].speed}}
  end

  ui_message(message, 10, 'speedTrapRecord')
end

local function onRedLightCamTriggered(speedTrapData, playerSpeed)
  if not isStateFreeroam() or speedTrapData.subjectID ~= be:getPlayerVehicleID(0) then
    return
  end
  local veh = getPlayerVehicle(0)
  ui_message({txt="ui.freeroam.speedTrap.redLightMessage", context={licensePlate = core_vehicles.getVehicleLicenseText(veh)}}, 10, 'speedTrap')
end

-- public interface
M.startFreeroam = startFreeroam
M.startFreeroamByName = startFreeroamByName
M.onPlayerCameraReady = onPlayerCameraReady
M.onTrafficOrParkingReady = onTrafficOrParkingReady
M.onClientPreStartMission = onClientPreStartMission
M.onClientPostStartMission = onClientPostStartMission
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleSpawned = onVehicleSpawned
M.onResetGameplay = onResetGameplay
M.startTrackBuilder = startTrackBuilder
M.onUpdate = onUpdate
M.onSpeedTrapTriggered = onSpeedTrapTriggered
M.onRedLightCamTriggered = onRedLightCamTriggered

return M
