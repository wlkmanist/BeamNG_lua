-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- this tiny module helps setting the steam rich presence

local M = {}

-- How to use: print(extensions.util_richPresence.set('yolo'))
M.state = { levelName = "", vehicleName = "" ,levelIdentifier=""}
M.richPresenceEnabled = true

local internal = not shipping_build or not string.match(beamng_windowtitle, "RELEASE")

--discord assets
local vehAssets = {"pickup"}
local lvlAssets = {
  "automation_test_track",
  "cliff",
  "derby",
  "driver_training",
  "east_coast_usa",
  "glow_city",
  "gridmap",
  "hirochi_raceway",
  "industrial",
  "italy",
  "jungle_rock_island",
  "small_island",
  "smallgrid",
  "utah",
  "west_coast_usa",
}

local steamTimelineClipPriorityStd=2
local steamTimelineClipPriorityFeat=2

local timelineEvents = {}
timelineEvents["vehicle/crash"] = {icon="steam_death", title="Crash"}
timelineEvents["vehicle/airtime.time"] = {icon="steam_effect", title="Air", type="range"}
timelineEvents["vehicle/rollover"] = {icon="steam_starburst", title="Rollover"}
timelineEvents["vehicle/jturn"] = {icon="steam_triangle", title="jturn"}
timelineEvents["drift/crashes"] = {icon="steam_bolt", title="drift crash"}
-- timelineEvents["drift/leftDrifts"] = {icon="steam_explosion", title="drift left"}
-- timelineEvents["drift/rightDrifts"] = {icon="steam_explosion", title="drift right"}

local activities = {
  replay = 'replay' ,

  photo_mode = 'photo_mode' ,

  career_tutorial = 'career_tutorial' ,
  career_challenge = 'career_challenge' ,
  career_cargo = 'career_cargo' ,
  career_partShopping = 'career_partShopping' ,
  career = 'career' ,

  garage = 'garage' ,

  freeroam_tutorial = 'freeroam_tutorial' ,

  challenge_type_airace = 'challenge_type_airace' ,
  challenge_type_arrive = 'challenge_type_arrive' ,
  challenge_type_busmode = 'challenge_type_busmode' ,
  challenge_type_cannon = 'challenge_type_cannon' ,
  challenge_type_chase = 'challenge_type_chase' ,
  challenge_type_collection = 'challenge_type_collection' ,
  challenge_type_crawl = 'challenge_type_crawl' ,
  challenge_type_delivery = 'challenge_type_delivery' ,
  challenge_type_dragstripapm = 'challenge_type_dragstriprace' ,
  challenge_type_dragstriprace = 'challenge_type_dragstriprace' ,
  challenge_type_drift = 'challenge_type_drift' ,
  challenge_type_evade = 'challenge_type_evade' ,
  challenge_type_flowgraph = 'challenge_generic' ,
  challenge_type_freeformdelivery = 'challenge_type_freeformdelivery' ,
  challenge_type_garagetogarage = 'challenge_type_garagetogarage' ,
  challenge_type_generatedtimetrial = 'challenge_type_gentimetrial' ,
  challenge_type_hypermiling = 'challenge_type_hypermiling' ,
  challenge_type_knockaway = 'challenge_type_knockaway' ,
  challenge_type_longjump = 'challenge_type_longjump' ,
  challenge_type_precisionparking = 'challenge_type_precisionparking' ,
  challenge_type_rallyloop = 'challenge_type_rallyloop' ,
  challenge_type_rallyroadsection = 'challenge_type_rallyloop' ,
  challenge_type_rallystage = 'challenge_type_rallystage' ,
  challenge_type_scatterpickup = 'challenge_type_scatterpickup' ,
  challenge_type_simplelapconfigscenario = 'challenge_generic' ,
  challenge_type_targetjump = 'challenge_type_targetjump' ,
  challenge_type_timetrial = 'challenge_type_timetrial' ,
  challenge_generic = 'challenge_generic' ,

  campaign = 'campaign' ,
  scenario_generic = 'scenario_generic' ,

  freeroam_drifting = 'freeroam_drifting' ,
  freeroam_drag = 'freeroam_drag' ,
  freeroam_crawl = 'freeroam_crawl' ,

  level_automation_test_track = 'level_automation_test_track' ,
  level_cliff = 'level_cliff' ,
  level_derby = 'level_derby' ,
  level_driver_training = 'level_driver_training' ,
  level_east_coast_usa = 'level_east_coast_usa' ,
  level_gridmap_v2 = 'level_gridmap_v2' ,
  level_hirochi_raceway = 'level_hirochi_raceway' ,
  level_industrial = 'level_industrial' ,
  level_italy = 'level_italy' ,
  level_johnson_valley = 'level_johnson_valley' ,
  level_jungle_rock_island = 'level_jungle_rock_island' ,
  level_small_island = 'level_small_island' ,
  level_smallgrid = 'level_smallgrid' ,
  level_utah = 'level_utah' ,
  level_west_coast_usa = 'level_west_coast_usa' ,
  level_generic = 'level_generic' ,

  main_menu = 'main_menu' ,
}

--local activity_debug = true
local lastActivity, lastActivityTime, lastEnabled = nil, 0, false
if activity_debug then
  local im = ui_imgui
  M.onUpdate = function()
    im.SetNextWindowSize(im.ImVec2(300, 300), im.Cond_FirstUseEver)
    im.Begin("Rich Presence Debug", nil, im.WindowFlags_MenuBar)
    im.Text("Last Activity: "..dumps(lastActivity))
    im.Text("Last Activity Time: "..(lastActivityTime or 0) - os.clock())
    im.Text("Last Enabled: "..(lastEnabled and "true" or "false"))
    im.End()
  end
end

local function getCurrentActivity()

  if core_replay and core_replay.getState() ~= 'inactive'  then
    return activities.replay
  end

  if ui_pause_photomode and ui_pause_photomode.isPhotomodeSessionActive() then
    return activities.photo_mode
  end

  if career_career and career_career.isActive() then
    if career_modules_tutorial and career_modules_tutorial.isActive() then
      return activities.career_tutorial
    end
    if gameplay_missions_missionManager.getForegroundMissionId() then
      return activities.career_challenge
    end
    if career_modules_delivery_general and career_modules_delivery_general.isDeliveryModeActive() then
      return activities.career_cargo
    end
    if career_modules_partShopping and career_modules_partShopping.isShoppingSessionActive() then
      return activities.career_partShopping
    end
    return activities.career
  end

  if gameplay_garageMode and gameplay_garageMode.isActive() then
    return activities.garage
  end

  if gameplay_discover_freeroamTutorial_tutorial ~= nil then
    return activities.freeroam_tutorial
  end

  if gameplay_missions_missionManager and gameplay_missions_missionManager.getForegroundMissionId() then
    local missionType = gameplay_missions_missions.getMissionTypeFromMissionId(gameplay_missions_missionManager.getForegroundMissionId()) or ""
    local activityId = "challenge_type_"..string.lower(missionType)
    if activities[activityId] then
      return activityId
    else
      return activities.challenge_generic
    end
  end

  if scenario_scenarios and scenario_scenarios.getScenario() then
    if scenario_scenarios.getScenario().restrictToCampaign then
      return activities.campaign
    else
      return activities.scenario_generic
    end
  end

  if gameplay_drag_core and gameplay_drag_core.getData() ~= nil then
    return activities.freeroam_drag
  end
  if gameplay_crawl_general and gameplay_crawl_general.activeTrail ~= nil then
    return activities.freeroam_crawl
  end
  if gameplay_drift_general and gameplay_drift_general.getContext() == "inFreeroamChallenge" then
    return activities.freeroam_drifting
  end

  if getCurrentLevelIdentifier() then
    if core_gamestate and core_gamestate.getLoadingStatus("levels") then
      return activities.level_generic
    end
    local activityId = "level_"..string.lower(getCurrentLevelIdentifier())
    if activities[activityId] then
      return activityId
    else
      return activities.level_generic
    end
  end

  return activities.main_menu
end

local function setActivity(activityId)
  if lastActivity == activityId then
    --log("I","Rich Presence", "setActivity already set "..activityId)
    return
  end
  log("I","Rich Presence", "Setting activity to "..activityId)
  if UDS then
    UDS.startActivityByID(activityId)
  end
  lastActivity = activityId
end

M.setActivity = nop
local function updateCurrentActivity()
  --log("I","Rich Presence", "updateCurrentActivity ")
  local activityId = getCurrentActivity() or ""
  lastActivityTime = os.clock()
  lastEnabled = M.setActivity ~= nop
  M.setActivity(activityId)
end

M.onCareerActive = function() updateCurrentActivity() end
M.onDeliveryModeStarted = function() updateCurrentActivity() end
M.onDeliveryModeStopped = function() updateCurrentActivity() end
M.onPartShoppingStarted = function() updateCurrentActivity() end
M.onPartShoppingTransactionComplete = function() updateCurrentActivity() end
M.onScenarioChange = function() updateCurrentActivity() end
M.onPartShoppingCancelled = function() updateCurrentActivity() end
M.onDragReset = function() updateCurrentActivity() end
M.onDragDataSet = function() updateCurrentActivity() end
M.onDragClear = function() updateCurrentActivity() end
M.onDragClearComplete = function() updateCurrentActivity() end
M.onCrawlStarted = function() updateCurrentActivity() end
M.onCrawlCleared = function() updateCurrentActivity() end
M.onDriftContextChanged = function() updateCurrentActivity() end
M.onWorldReadyState = function(levelpath) updateCurrentActivity() end

local function msgFormat()
  local fgActivityId = gameplay_missions_missionManager.getForegroundMissionId()
  local mission = nil
  if fgActivityId then
    mission = gameplay_missions_missions.getMissionById(fgActivityId)
  end

  local msg = ""
  local appendLevel, appendVehicle
  if editor and editor.isEditorActive() then
    msg = "Using World Editor"
    appendLevel, appendVehicle = true, false
  elseif fgActivityId and mission then
    msg = "Playing " .. core_locales.translate(mission.name, mission.name)
    appendLevel, appendVehicle = true, true
  elseif scenario_scenarios and scenario_scenarios.getScenario() then
    local scenario = scenario_scenarios.getScenario()
    if scenario.name then
      msg = "Playing " .. core_locales.translate(scenario.name, scenario.name)
    elseif scenario.isQuickRace then
      msg = "Playing Time Trials"
    else
      msg = "Playing Scenario"
    end
    appendLevel, appendVehicle = true, true
  elseif gameplay_walk and gameplay_walk.isWalking() then
    msg = "Walking around"
    appendLevel, appendVehicle = true, false
  else
    msg = "Playing"
    if extensions.core_gamestate.state.state then
      msg = msg.. " " ..tostring((core_gamestate.state.state:gsub("^%l", string.upper)) )
    end
    appendLevel, appendVehicle = true, true
  end

  if msg ~= "" then
    -- append level and vehicle if possible
    if appendLevel and M.state.levelName ~= "" then
      msg = msg .. " on " .. core_locales.translate(M.state.levelName)
    end

    if appendVehicle and M.state.vehicleName ~= "" and M.state.vehicleName ~= "Unicycle" then
      msg = msg .. " with " .. M.state.vehicleName
    end

    if Steam then
      Steam.timelineSetStateDescription(msg,0)
    end

    M.set(msg)

    -- only set discord state is there is a msg for steam
    if Discord and Discord.isWorking() then
      local dActivity = {state="Playing ",details="",asset_largeimg="",asset_largetxt="",asset_smallimg="",asset_smalltxt=""}
      -- discord will use the same message as steam
      dActivity.state = msg

      if M.state.levelName ~= "" then
        dActivity.details = M.state.levelName
        dActivity.asset_largetxt = M.state.levelName
      end
      if M.state.vehicleName ~= "" then
        dActivity.asset_smalltxt = M.state.vehicleName
        dActivity.details = M.state.vehicleName
      end
      if M.state.levelIdentifier and M.state.levelIdentifier ~= "" and tableContains(lvlAssets,M.state.levelIdentifier)then
        dActivity.asset_largeimg= "lvl_"..M.state.levelIdentifier
      else
        dActivity.asset_largeimg="missingnormaltexture"
      end
      -- if M.state.vehicleJbeam and M.state.vehicleJbeam ~= "" and tableContains(vehAssets,M.state.vehicleJbeam) then
      --   dActivity.asset_smallimg= M.state.vehicleJbeam
      -- else
      --   dActivity.asset_smallimg= "warnmat"
      -- end
      --log("E","msgFormat", dumps(dActivity))
      Discord.setActivity(dActivity)
    end
  end
end

local function getCurrentVehicleDetails()
  local plv = getPlayerVehicle(0)
  if not plv then
    return {current={key=""}, model={Name="", Brand=""}}
  end
  local jbeamName = plv:getJBeamFilename()
  local data =  {current={key=jbeamName}}
  data.model = jsonReadFile("/vehicles/".. jbeamName .."/info.json")
  return data
end

local function onVehicleSwitched(oldId, newId, player)
  -- local currentVehicle = core_vehicles.getCurrentVehicleDetails() --bad perf after lua reload because no cache
  local currentVehicle = getCurrentVehicleDetails()
  if currentVehicle.model and currentVehicle.model.Name then
    if currentVehicle.model.Brand then
      M.state.vehicleName = core_locales.translateWithPrefixFallback(currentVehicle.model.Brand,"ui.vehicleconfig.brand.") .. " " .. _tr(currentVehicle.model.Name)
    else
      M.state.vehicleName = _tr(currentVehicle.model.Name)
    end
    if M.state.vehicleName == " " then M.state.vehicleName = "" end
  else
    M.state.vehicleName = ""
  end
  M.state.vehicleJbeam = currentVehicle.current.key
  msgFormat()

end

local function onClientPostStartMission(levelPath)
  local currentLevel = getCurrentLevelIdentifier() or ''
  M.state.levelIdentifier = string.lower(currentLevel)
  if currentLevel ~= "" then
    M.state.levelName = currentLevel:gsub("^%l", string.upper)
    M.state.levelName = M.state.levelName:gsub("_", " ")
    M.state.levelName = string.gsub(" "..M.state.levelName, "%W%l", string.upper):sub(2)
    msgFormat()
  end
  updateCurrentActivity()
end
--[[
-- this was the old editor
local function onEditorEnabled(enabled)
  if enabled then
    M.set('Level editing')
  else
    msgFormat()
  end
end
]]

local function onEditorActivated()
  msgFormat()
  if Steam then
    Steam.timelineSetGameMode(2)
  end
end

local function onEditorDeactivated()
  msgFormat()
  if Steam then
    Steam.timelineSetGameMode(1)
  end
end

local function onGameStateUpdate(state)
  msgFormat()
  updateCurrentActivity()
end

local function onAnyMissionChanged()
  msgFormat()
  updateCurrentActivity()
end

local function statCbTimeline(name, oldentry, newentry)
  if Steam then
    if not timelineEvents[name].type or timelineEvents[name].type == "instant" then
      Steam.timelineAddEvent(
        timelineEvents[name].icon,
        timelineEvents[name].title,
        "",
        timelineEvents[name].priority or 0,
        0,
        0,
        steamTimelineClipPriorityStd
      )
    elseif timelineEvents[name].type == "range" then
      Steam.timelineAddEvent(
        timelineEvents[name].icon,
        timelineEvents[name].title,
        "",
        timelineEvents[name].priority or 0,
        -newentry.last,
        newentry.last,
        steamTimelineClipPriorityFeat
      )
    else
      Steam.timelineAddEvent(
        timelineEvents[name].icon,
        timelineEvents[name].title,
        "",
        timelineEvents[name].priority or 0,
        -0.05,
        0.1,
        steamTimelineClipPriorityStd
      )
    end
  end
  -- print(name)
end

local function onExtensionLoaded()
  if UDS then internal=false end
  if not internal and settings.getValue('richPresence') then
    log("D","Rich Presence", "Rich Presence is enabled. internal="..dumps(internal).." settings="..dumps(settings.getValue('richPresence')))
    if OnlineServiceProvider then
      OnlineServiceProvider.setRichPresence('steam_display', '#BNGGSW') -- BNGGSW = BeamNG Generic Status Wrapper
      OnlineServiceProvider.setRichPresence('status', beamng_windowtitle) -- will show up in the 'view game info' dialog in the Steam friends list.
      OnlineServiceProvider.setRichPresence('b', "   ")
    end
    if Discord then
      Discord.setEnabled(settings.getValue('richPresenceDiscord'))
    end
  else
    log("D","Rich Presence", "Rich Presence is disabled. internal="..dumps(internal).." settings="..dumps(settings.getValue('richPresence')))
  end
  if Steam then
    Steam.timelineSetGameMode(0)
  end
  for k,v in pairs(timelineEvents) do
    gameplay_statistic.callbackRegister(k, false, statCbTimeline)
  end
end

local function onExtensionUnloaded()
  if OnlineServiceProvider then
    OnlineServiceProvider.setRichPresence('b', "   ")
    -- OnlineServiceProvider.clearRichPresence() --not working
  end
  if Discord then
    Discord.clearActivity()
  end
  for k,v in pairs(timelineEvents) do
    gameplay_statistic.callbackRemove(k, false, statCbTimeline)
  end
end

-- returns true on success
local function set(v)
  log("D","Rich Presence", tostring(v))
  if OnlineServiceProvider then
    return OnlineServiceProvider.setRichPresence('b', tostring(v))
  end
end

local toggleableFunctions = {
  set = set,
  setActivity = setActivity
}

local function enableToggleableFunctions(enabled)
  M.richPresenceEnabled = enabled
  for k, v in pairs(toggleableFunctions) do
    M[k] = enabled and v or nop
  end
end

local function onSettingsChanged()
  if UDS then internal=false end
  if internal or not settings.getValue('richPresence') then
    --log("D","Rich Presence", "Rich Presence is disabled. internal="..dumps(internal).." settings="..dumps(settings.getValue('richPresence')))
    if OnlineServiceProvider then
      if Steam then
        OnlineServiceProvider.setRichPresence('b', "   ")
      end
      -- OnlineServiceProvider.clearRichPresence() --not working
    end
    if Discord then
      Discord.setEnabled(false)
    end
    lastActivity, lastActivityTime = nil, 0
    enableToggleableFunctions(false)
  elseif M.set == nop and settings.getValue('richPresence') then --re-enabled
    if OnlineServiceProvider then
      log("D","Rich Presence", "Rich Presence is enabled.")
      if Steam then
        OnlineServiceProvider.setRichPresence('steam_display', '#BNGGSW')
        OnlineServiceProvider.setRichPresence('status', beamng_windowtitle)
        OnlineServiceProvider.setRichPresence('b', "   ")
      end
      enableToggleableFunctions(true)
    end
    if Discord then
      Discord.setEnabled(settings.getValue('richPresenceDiscord'))
    end
    msgFormat()
    updateCurrentActivity()
  end
end

local function timelineStartLoadingScreen(levelpath)
  -- log("I","AAA","timelineStartLoadingScreen")
  if Steam then
    Steam.timelineSetGameMode(4)
  end
end

local function onUiReady()
  --log("I","onUiReady","") --usually used when reloading
  local state = 0 --invalid
  if extensions.core_gamestate.state.state then
    local s = extensions.core_gamestate.state.state
    --log("E","onUiReady",dumps(s))
    if string.startswith(s,"menu.") then
      state = 3 --menu
      if Steam then
        Steam.timelineSetStateDescription("Menu",0)
      end
    elseif s == "loading" then
      state = 4 --loadingscreen
      if Steam then
        Steam.timelineSetStateDescription("Loading screen",0)
      end
    elseif string.startswith(s,"scenario-") then
      state = 2 --stagging
    else
      state = 1 --playing
    end
  end
  if Steam then
    Steam.timelineSetGameMode(state)
  end
  updateCurrentActivity()
end


local function onUiChangedState(toState, fromState)
  -- log("I","onUiChangedState", "from="..dumps(fromState))
  -- log("I","onUiChangedState", "to="..dumps(toState))
  local state = 0 --invalid
  if string.startswith(toState,"menu.") then
    state = 3 --menu
    if Steam then
      Steam.timelineSetStateDescription("Menu",0)
    end
  elseif toState == "loading" then
    state = 4 --loadingscreen
    if Steam then
      Steam.timelineSetStateDescription("Loading screen",0)
    end
  elseif string.startswith(toState,"scenario-") then
    state = 2 --stagging
  else
    state = 1 --playing
  end
  if Steam then
    Steam.timelineSetGameMode(state)
  end
end

local function onResetGameplay()
  if Steam then
    Steam.timelineAddEvent(
      "steam_circle",
      "reset",
      "",
      0,0,0,steamTimelineClipPriorityStd)
  end
end

local function onNewAttempt(attemptData)
  if Steam then
    Steam.timelineAddEvent(
      "steam_circle",
      "New attempt",
      "",
      0,0,0,steamTimelineClipPriorityStd)
  end
end

local function onAttemptFailed(attemptData)
  if Steam then
    Steam.timelineAddEvent(
      "steam_invalid",
      "Failed",
      "",
      0,0,0,steamTimelineClipPriorityStd)
  end
end

local function onAttemptCompleted(attemptData)
  if Steam then
    Steam.timelineAddEvent(
      "steam_checkmark",
      "Completed",
      "",
      0,0,0,steamTimelineClipPriorityStd)
  end
end

local function onRaceWaypointReached(data)
  if Steam then
    Steam.timelineAddEvent(
      "steam_marker",
      "Race waypoint",
      "",
      0,0,0,steamTimelineClipPriorityStd)
  end
end

local function onRaceLap(data)
  local timeStr = string.format("%.2d:%.2d.%.3d", (data.time)/60, (data.time)%60, (data.time%1)*1000)
  if Steam then
    Steam.timelineAddEvent(
      "steam_flag",
      "Race lap "..dumps(data.lap),
      timeStr,
      10,0,0,steamTimelineClipPriorityStd)
  end
end

local function onRaceBranchChosen(data)
  -- log("E","onRaceBranchChosen", "  data="..dumps(data))
  if Steam then
    Steam.timelineAddEvent(
      "steam_transfer",
      "Race branch",
      "",
      0,0,0,steamTimelineClipPriorityStd)
  end
end

local function onRaceResult(data)
  local timeStr = string.format("%.2d:%.2d.%.3d", (data.finalTime)/60, (data.finalTime)%60, data.finalTime%1*1000)
  if Steam then
    Steam.timelineAddEvent(
      "steam_flag",
      "Race Result",
      timeStr,
      10,0,0,steamTimelineClipPriorityStd)
  end
end

local function onMissionAttemptAggregated(attempt, mission)
  -- log("E","onMissionAttemptAggregated", "  !!!!!!!!!!!!!!")
  if Steam then
    Steam.timelineAddEvent(
      "steam_flag",
      "Mission "..dumps(attempt.type),
      mission.name,
      0,0,0,steamTimelineClipPriorityStd)
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onSettingsChanged = onSettingsChanged
M.onAnyMissionChanged = onAnyMissionChanged
M.onDeserialized    = nop -- do not remove

M.onVehicleSwitched = onVehicleSwitched
M.onClientPostStartMission = onClientPostStartMission
M.onGameStateUpdate = onGameStateUpdate
M.onAnyMissionChanged = onAnyMissionChanged
M.onEditorActivated = onEditorActivated
M.onEditorDeactivated = onEditorDeactivated
M.clientEndMission = timelineStartLoadingScreen
M.clientPreStartMission = timelineStartLoadingScreen
M.onUiReady = onUiReady
M.onUiChangedState = onUiChangedState
-- M.onScenarioFinished = onScenarioFinished
-- M.onScenarioChange = onScenarioChange
-- M.onScenarioRestarted = onScenarioRestarted
M.onResetGameplay = onResetGameplay
M.onAnyMissionChanged = onAnyMissionChanged
-- M.onPursuitOffense = onPursuitOffense
M.onNewAttempt = onNewAttempt
M.onAttemptFailed = onAttemptFailed
M.onAttemptCompleted = onAttemptCompleted
M.onRaceWaypointReached = onRaceWaypointReached
M.onRaceLap = onRaceLap
M.onRaceBranchChosen = onRaceBranchChosen
M.onRaceResult = onRaceResult
M.onMissionAttemptAggregated = onMissionAttemptAggregated
-- M.onScenarioUIReady = onScenarioUIReady

if not internal then
  enableToggleableFunctions(true)
else
  enableToggleableFunctions(false)

  if OnlineServiceProvider then
    OnlineServiceProvider.setRichPresence('b', "   ")
    --OnlineServiceProvider.clearRichPresence()
  end
  if Discord then
    Discord.clearActivity()
    Discord.setEnabled(false)
  end
end

return M

