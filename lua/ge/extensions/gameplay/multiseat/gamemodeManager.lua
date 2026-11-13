local M = {}
M.ModuleName = "gamemodeManager"

local log = log or function() end
local logTag = "multiseat.gamemodeManager"

local GAMEMODE_PROVIDER_DIRS = {
  { path = "gameplay/discover/multiseat/", pattern = "*Rules.lua" },
}
local FALLBACK_THUMBNAIL = "/gameplay/discover/multiseat/header.jpg"
local FADE_DURATION = 0.35
local VEHICLE_READY_TIMEOUT = 5
local SCREEN_MGR_ID = "multiseatGamemode"
local BLOCKED_ACTIONS_GROUP = "multiseatBlockedActions"
local DEFAULT_BLOCKED_ACTIONS = {
  "vehicleTeleporting",
  "vehicleMenues",
  "physicsControls",
  "aiControls",
  "vehicleSwitching",
  "freeCam",
  "funStuff",
  "walkingMode",
  "radialMenuActivate",
}
-- switching vehicles or seats restarts the gamemode, so these stay blocked even without restrictScenarios
local ALWAYS_BLOCKED_ACTIONS = {
  "vehicleSwitching",
  "walkingMode",
}

local gamemodesInfo = nil
local currentGamemodeExt = nil
local currentGamemodeSettings = nil
local currentGamemodeName = nil
local gamemodePhase = nil -- nil | "starting" | "waiting" | "running"
local pendingReadyCallback = nil
local fadeActive = false
local pendingLaunch = false
local pendingVehicles = nil
local vehicleReadyDeadline = nil
local activeScreen = nil
local buttonFunctions = {}
local startScreenPendingOnPauseExit = false
local assignVehiclePool = false

local function loadGamemodeProviders()
  for _, entry in ipairs(GAMEMODE_PROVIDER_DIRS) do
    local files = FS:findFiles(entry.path, entry.pattern, 1, false, true)
    for _, file in ipairs(files) do
      -- the leading slash would turn into a leading underscore, loading a second copy of the
      -- provider under a name that is not the global the gamemodes call it by
      local extName = extensions.luaPathToExtName(file:gsub("^/", ""):gsub("%.lua$", ""))
      if extName then
        extensions.load(extName)
      end
    end
  end
end

local function collectGamemodesInfo()
  local collected = {}
  extensions.hook("onGetMultiseatGamemodeInfos", collected)

  local result = {}
  for _, info in ipairs(collected) do
    if info.name then
      result[info.name] = info
    else
      log('W', logTag, 'A gamemodeRegister returned info without a name, skipping')
    end
  end
  return result
end

local function ensureRegistryLoaded()
  if not gamemodesInfo then
    loadGamemodeProviders()
    gamemodesInfo = collectGamemodesInfo()
  end
end

local function buildDefaultSettings(info)
  local settings = {}
  for key, declaration in pairs(info.settings or {}) do
    settings[key] = declaration.default
  end
  return settings
end

local function resolveThumbnail(path)
  if path and FS:fileExists(path) then return path end
  return FALLBACK_THUMBNAIL
end

local function buildLocalPlayerList()
  if not core_multiseat then return {} end
  local players = {}
  local joined = core_multiseat.getJoinedPlayers and core_multiseat.getJoinedPlayers() or {}
  for i, playerIndex in ipairs(joined) do
    local name = "Player " .. (playerIndex + 1)
    local participants = core_multiseat.getJoinedParticipants and core_multiseat.getJoinedParticipants() or {}
    for _, participant in ipairs(participants) do
      if participant.assignment and participant.assignment.playerIndex == playerIndex and participant.persona then
        name = participant.persona.displayName or name
        break
      end
    end
    table.insert(players, {
      id = tostring(playerIndex),
      name = name,
      isLocalPlayer = (i == 1),
    })
  end
  return players
end

local function getJoinedPersona(playerIndex)
  if not core_multiseat or not core_multiseat.getJoinedParticipants then return nil end
  for _, participant in ipairs(core_multiseat.getJoinedParticipants()) do
    if participant.assignment and participant.assignment.playerIndex == playerIndex and participant.persona then
      return participant.persona
    end
  end
  return nil
end

local function getPlayerName(playerIndex)
  local persona = getJoinedPersona(playerIndex)
  return persona and persona.displayName or nil
end

local function getPlayerColorHex(playerIndex)
  local persona = getJoinedPersona(playerIndex)
  return persona and persona.colorHex or nil
end

local function exceedsMaxPlayers(info)
  local maxPlayers = info.playerCount and info.playerCount.max
  local joined = core_multiseat and core_multiseat.getJoinedPlayers() or {}
  return maxPlayers ~= nil and #joined > maxPlayers
end

local function requestGamemodeData()
  ensureRegistryLoaded()

  local gamemodesForUI = {}
  local unsupportedOnMapCount = 0
  local unsupportedPlayerCount = 0
  for name, info in pairs(gamemodesInfo) do
    if info.mapUnsupported then
      unsupportedOnMapCount = unsupportedOnMapCount + 1
    elseif exceedsMaxPlayers(info) then
      unsupportedPlayerCount = unsupportedPlayerCount + 1
    else
      gamemodesForUI[name] = {
        name = info.name,
        displayName = info.displayName,
        description = info.description,
        thumbnail = resolveThumbnail(info.thumbnail),
        settings = info.settings,
        tags = info.tags,
      }
    end
  end

  guihooks.trigger("OnGamemodeData", {
    context = "multiseat",
    gamemodes = gamemodesForUI,
    unsupportedOnMapCount = unsupportedOnMapCount,
    unsupportedPlayerCount = unsupportedPlayerCount,
    currentGamemodeDisplayName = currentGamemodeName and gamemodesInfo[currentGamemodeName] and gamemodesInfo[currentGamemodeName].displayName or nil,
    currentSettings = currentGamemodeSettings,
    isLobbyOwner = true,
    localPlayerLobbyRole = "active",
    players = buildLocalPlayerList(),
    readyUpGamemodeInfo = nil,
    preReadyStatuses = nil,
  })
end

local function resolveRulesExtension(info)
  if not info or not info.extensionPath then return nil end
  local rulesGlobalName = extensions.luaPathToExtName(info.extensionPath .. "Rules")
  return rulesGlobalName and _G[rulesGlobalName] or nil
end

local function applyGamemodeSettings(ext, settings)
  local rulesExt = resolveRulesExtension(ext.info)
  if rulesExt and rulesExt.setSettings then
    rulesExt.setSettings(settings)
  end

  if ext.setActivePlayerIds then
    local playerIds = {}
    for _, p in ipairs(buildLocalPlayerList()) do
      table.insert(playerIds, p.id)
    end
    ext.setActivePlayerIds(playerIds)
  end
end

local function setActionBlocking(enabled)
  if enabled then
    local info = currentGamemodeExt and currentGamemodeExt.info
    local templates = {}
    for _, action in ipairs(DEFAULT_BLOCKED_ACTIONS) do
      templates[#templates + 1] = action
    end
    for _, action in ipairs(info and info.extraBlockedActions or {}) do
      templates[#templates + 1] = action
    end
    local list = core_input_actionFilter.createActionTemplate(templates, info and info.allowedActions)
    if not settings.getValue("restrictScenarios", true) then
      list = core_input_actionFilter.createActionTemplate(ALWAYS_BLOCKED_ACTIONS, info and info.allowedActions)
    end
    core_input_actionFilter.setGroup(BLOCKED_ACTIONS_GROUP, list)
  end
  core_input_actionFilter.addAction(0, BLOCKED_ACTIONS_GROUP, enabled)
end

local function closeActiveScreen()
  if not activeScreen then return end
  activeScreen = nil
  buttonFunctions = {}
  extensions.ui_router.navigate("multiseat")
end

local function prepareAndShowScreen(screenData)
  if not screenData then return end
  buttonFunctions = {}
  activeScreen = screenData
  for _, button in ipairs(activeScreen.buttons or {}) do
    if button.callback then
      local funId = #buttonFunctions + 1
      buttonFunctions[funId] = button.callback
      button.callback = nil
      button.mgrId = SCREEN_MGR_ID
      button.funId = funId
    end
  end
  extensions.ui_router.navigate("mission.control", { mode = activeScreen.mode })
end

local function showStartScreen()
  if not currentGamemodeExt or not currentGamemodeExt.buildStartScreen then return end
  local screen = currentGamemodeExt.buildStartScreen()
  extensions.hook("onStartScreenFinishedBuilding")
  prepareAndShowScreen(screen)
end

local function showEndScreen(resultData)
  if not currentGamemodeExt then return end
  extensions.hook("onMultiseatGamemodeFinished", currentGamemodeName, resultData)
  simTimeAuthority.pause(true)

  -- Let the gamemode override individual sections or provide a complete paged layout.
  local overrides = {}
  if currentGamemodeExt.buildEndScreen then
    overrides = currentGamemodeExt.buildEndScreen(resultData) or {}
  end

  -- header
  local title
  local headerColor = overrides.headerColor
  if overrides.header then
    title = overrides.header
  elseif resultData and resultData.title then
    title = resultData.title
  elseif resultData and resultData.tied then
    title = "ui.gamemodes.endScreen.tie"
  elseif resultData and resultData.winnerPlayer ~= nil then
    local name = getPlayerName(resultData.winnerPlayer)
    title = name
      and { txt = "ui.gamemodes.endScreen.winner", context = { name = name } }
      or "ui.gamemodes.endScreen.title"
    headerColor = headerColor or getPlayerColorHex(resultData.winnerPlayer)
  else
    title = "ui.gamemodes.endScreen.title"
  end

  -- body
  local bodyText = overrides.body or (resultData and resultData.text) or ""
  local layout = overrides.layout or {
    {
      type = "textPanel",
      text = type(bodyText) == "table" and bodyText or { bodyText },
      pages = { main = true },
    },
  }
  local pages = overrides.pages or {
    main = { order = 1, icon = "medal", mandatory = false },
  }
  local simpleStartScreen = overrides.simpleStartScreen
  if simpleStartScreen == nil then simpleStartScreen = true end

  -- buttons
  local buttons = overrides.buttons or {
    { callback = function() M.restart() end, label = "missions.missions.general.panel.restart", focus = true, main = true },
    { callback = function()
        M.stop()
        extensions.ui_router.navigate("multiseat")
      end, label = "ui.playmodes.freeroam" },
    { callback = function() M.goToMainMenu() end, label = "ui.dashboard.menu" },
  }

  local screen = {
    mode = "endScreen",
    header = { header = title, color = headerColor },
    layout = layout,
    buttons = buttons,
    pages = pages,
    simpleStartScreen = simpleStartScreen,
  }

  prepareAndShowScreen(screen)
end

local function goToMainMenu()
  returnToMainMenu()
end

local function teardownCurrentGamemode(activateFreeroam)
  setActionBlocking(false)
  simTimeAuthority.pause(false)
  local ext = currentGamemodeExt
  currentGamemodeExt = nil
  currentGamemodeSettings = nil
  currentGamemodeName = nil
  gamemodePhase = nil

  if not ext then return end

  if ext.stop then
    ext.stop()
  end

  if activateFreeroam then
    extensions.load("ui_multiseat_freeroam")
    ui_multiseat_freeroam.activate()
  end
end

local function stopGamemode(activateFreeroam)
  if not currentGamemodeName then return end

  log('I', logTag, 'Stopping gamemode: ' .. tostring(currentGamemodeName))
  extensions.hook("onMultiseatGamemodeStopped", currentGamemodeName)
  pendingReadyCallback = nil
  pendingLaunch = false
  pendingVehicles = nil
  vehicleReadyDeadline = nil
  activeScreen = nil
  buttonFunctions = {}
  startScreenPendingOnPauseExit = false
  assignVehiclePool = false
  if fadeActive then
    fadeActive = false
    ui_fadeScreen.stop(0)
  end
  teardownCurrentGamemode(activateFreeroam)
end

local function stop()
  stopGamemode(true)
end

local function setReadyCallback(callback)
  pendingReadyCallback = callback
end

local function deferReady()
  if gamemodePhase == "starting" then
    gamemodePhase = "waiting"
  end
end

local function notifyReady()
  if gamemodePhase ~= "waiting" and gamemodePhase ~= "starting" then
    return
  end
  gamemodePhase = "running"
  if fadeActive then
    fadeActive = false
    ui_fadeScreen.stop(FADE_DURATION)
  end
  if pendingReadyCallback then
    local cb = pendingReadyCallback
    pendingReadyCallback = nil
    cb()
  end
end

local function getVehiclePool()
  local info = currentGamemodeExt and currentGamemodeExt.info
  return info and info.vehiclePool or nil
end

local function shouldAssignVehiclePool()
  return assignVehiclePool
end

local function startFadeAndDeferLaunch()
  fadeActive = true
  pendingLaunch = true
  ui_fadeScreen.start(FADE_DURATION)
end

local function launchCurrentGamemode()
  local ext = currentGamemodeExt
  local settings = currentGamemodeSettings

  gamemodePhase = "starting"

  log('I', logTag, 'launch: starting ' .. tostring(currentGamemodeName) .. ' in place')
  simTimeAuthority.pause(false)
  core_gamestate.setGameState("freeroam", "discover", nil)
  setActionBlocking(true)
  applyGamemodeSettings(ext, settings)
  extensions.hook("onMultiseatGamemodeLaunched", currentGamemodeName)
  local vehicles = ext.start(settings)
  if vehicles then
    pendingVehicles = vehicles
    vehicleReadyDeadline = os.clockhp() + VEHICLE_READY_TIMEOUT
    gamemodePhase = "waiting"
  elseif gamemodePhase == "starting" and not fadeActive and not pendingReadyCallback then
    notifyReady()
  end
  return true
end

local function start(name, settings, options)
  ensureRegistryLoaded()
  options = options or {}

  local info = gamemodesInfo[name]
  if not info then
    log('E', logTag, 'Failed to start gamemode ' .. tostring(name) .. ': not found in registry')
    return false
  end

  if not info.extensionPath then
    log('E', logTag, 'Failed to start gamemode ' .. name .. ': registry entry has no extensionPath')
    return false
  end

  if exceedsMaxPlayers(info) then
    log('W', logTag, 'Failed to start gamemode ' .. name .. ': more players joined than its maximum of ' .. tostring(info.playerCount.max))
    return false
  end

  log('I', logTag, 'Starting gamemode: ' .. name)

  extensions.load("ui_multiseat_freeroam")
  teardownCurrentGamemode(false)

  extensions.load(info.extensionPath)
  local ext = _G[extensions.luaPathToExtName(info.extensionPath)]
  if not ext then
    log('E', logTag, 'Failed to load gamemode extension: ' .. info.extensionPath)
    return false
  end
  ext.info = info

  currentGamemodeExt = ext
  currentGamemodeName = name
  currentGamemodeSettings = settings or buildDefaultSettings(info)
  assignVehiclePool = options.assignVehiclePool == true

  if ui_multiseat_freeroam then
    ui_multiseat_freeroam.deactivate()
  end

  if options.withFade == false then
    return launchCurrentGamemode()
  end
  startFadeAndDeferLaunch()
  return true
end

local function restart(name, settings)
  local targetName = name or currentGamemodeName
  if not targetName then return false end

  if currentGamemodeName ~= targetName or not currentGamemodeExt then
    return start(targetName, settings)
  end

  log('D', logTag, 'Restarting gamemode: ' .. tostring(targetName))

  if ui_multiseat_multiseatSettings then
    ui_multiseat_multiseatSettings.discardStagedSettings()
  end
  currentGamemodeSettings = settings or currentGamemodeSettings
  startFadeAndDeferLaunch()
  return true
end

local function isActive()
  return currentGamemodeName ~= nil
end

local function getGamemodeId()
  return currentGamemodeName
end

local function getMaxPlayers()
  local info = currentGamemodeExt and currentGamemodeExt.info
  return info and info.playerCount and info.playerCount.max or nil
end

local function getPhase()
  return gamemodePhase
end

local function isStartScreenPending()
  return startScreenPendingOnPauseExit
end

local function playPendingRound()
  if not startScreenPendingOnPauseExit then return false end
  startScreenPendingOnPauseExit = false
  showStartScreen()
  return true
end

local function onScreenFadeState(state)
  if state ~= 1 or not pendingLaunch then return end
  pendingLaunch = false
  launchCurrentGamemode()
end

local function onPreRender(dtReal, dtSim)
  if gamemodePhase ~= "waiting" or not pendingVehicles then return end
  if not ui_multiseat_multiseatVehicles.areVehiclesReady(pendingVehicles)
    and os.clockhp() < vehicleReadyDeadline then
    return
  end
  local vehicles = pendingVehicles
  pendingVehicles = nil
  vehicleReadyDeadline = nil
  notifyReady()
  if currentGamemodeExt and currentGamemodeExt.onReady then
    currentGamemodeExt.onReady(vehicles)
  end
  ui_multiseat_multiseatVehicles.setFrozen(vehicles, true)
  showStartScreen()
end

local function onRequestMissionScreenData(mode)
  if activeScreen and not string.find(mode, "test") then
    guihooks.trigger("onRequestMissionScreenDataReady", activeScreen)
    extensions.hook("onMissionScreenReady", mode, activeScreen)
  end
end

local function onMissionScreenButtonClicked(button)
  if not button or button.mgrId ~= SCREEN_MGR_ID then return end
  local buttonFunction = buttonFunctions[button.funId]
  local isEndScreen = activeScreen and activeScreen.mode == "endScreen"

  -- clear screen state
  activeScreen = nil
  buttonFunctions = {}

  if isEndScreen then
    -- end screen: callback owns its full flow (cleanup + navigation), run immediately
    if buttonFunction then buttonFunction() end
  else
    -- start screen: navigate to multiseat, run callback after short delay
    extensions.ui_router.navigate("multiseat")
    extensions.hook("onUIStartButtonClicked")
    if not buttonFunction then return end
    core_jobsystem.create(function(job)
      job.sleep(0.1)
      buttonFunction()
    end, 1)
  end
end

local function onGetIsMissionStartOrEndScreenActive(screensActive)
  if activeScreen then
    table.insert(screensActive, activeScreen.mode)
  end
end

local function onLoadingScreenFadeout()
  -- Vehicle-ready flow in onPreRender handles the start screen transition.
end

local function onAfterRouteChange(context)
  if not startScreenPendingOnPauseExit then return end
  local toRoute = context and context.toRoute
  local toRouteName = toRoute and toRoute.name
  if toRouteName ~= "play" and toRouteName ~= "multiseat" then return end
  playPendingRound()
end

local function onExtensionUnloaded()
  log('I', logTag, 'manager unloaded, gamemode was: ' .. tostring(currentGamemodeName))
  setActionBlocking(false)
  if currentGamemodeExt and currentGamemodeExt.stop then
    currentGamemodeExt.stop()
  end
  currentGamemodeExt = nil
  currentGamemodeSettings = nil
  currentGamemodeName = nil
  gamemodePhase = nil
  pendingReadyCallback = nil
  pendingLaunch = false
  pendingVehicles = nil
  vehicleReadyDeadline = nil
  activeScreen = nil
  buttonFunctions = {}
  startScreenPendingOnPauseExit = false
  assignVehiclePool = false
  if fadeActive then
    fadeActive = false
    ui_fadeScreen.stop(0)
  end
  gamemodesInfo = nil
end

local function onPauseHomeRailBuildMultiseatActions(actions, context, registerButton)
  local _tr = function(key) return key end
  if core_locales and core_locales.translate then
    _tr = core_locales.translate
  end

  if not currentGamemodeName then
    table.insert(actions, registerButton({
      id = "home.gamemodes",
      label = _tr("ui.gamemodes.gamemode"),
      icon = "gamepad",
      visible = true,
      enabled = true,
    }, function()
      return extensions.ui_router.navigate("pause.gamemodes")
    end))
  else
    table.insert(actions, registerButton({
      id = "home.gamemodeSettings",
      label = _tr("ui.gamemodes.settings"),
      icon = "adjust",
      visible = true,
      enabled = true,
    }, function()
      return extensions.ui_router.navigate("pause.gamemodeSettings")
    end))

    table.insert(actions, registerButton({
      id = "home.exitGamemode",
      label = _tr("ui.pause.exitGamemode"),
      icon = "abandon",
      visible = true,
      enabled = true,
    }, function()
      stop()
      return extensions.ui_router.navigate(ui_menuManager.getGameplayRoute())
    end))

    table.insert(actions, registerButton({
      id = "home.restartGamemode",
      label = _tr("ui.gamemodes.restart"),
      icon = "restart",
      visible = true,
      enabled = true,
    }, function()
      restart()
      return true
    end))
  end
end

local function onVehicleSwitched(oldId, newId, player)
  if not currentGamemodeExt or gamemodePhase ~= "running" then return end
  if ui_multiseat_multiseatVehicles and ui_multiseat_multiseatVehicles.isSynchronizing() then return end
  restart()
end

local function onMultiseatSettingsApplied(changeSet, result)
  if not currentGamemodeExt or result.success == false or result.exitAfterApply == true then return end
  if changeSet.requiresRestart then restart() end
end

local function onClientEndMission()
  stopGamemode(false)
end

M.onScreenFadeState = onScreenFadeState
M.onPreRender = onPreRender
M.onRequestMissionScreenData = onRequestMissionScreenData
M.onMissionScreenButtonClicked = onMissionScreenButtonClicked
M.onGetIsMissionStartOrEndScreenActive = onGetIsMissionStartOrEndScreenActive
M.onLoadingScreenFadeout = onLoadingScreenFadeout
M.onAfterRouteChange = onAfterRouteChange
M.onExtensionUnloaded = onExtensionUnloaded
M.onVehicleSwitched = onVehicleSwitched
M.onMultiseatSettingsApplied = onMultiseatSettingsApplied
M.onClientEndMission = onClientEndMission
M.onPauseHomeRailBuildMultiseatActions = onPauseHomeRailBuildMultiseatActions
M.requestGamemodeData = requestGamemodeData
M.start = start
M.stop = stop
M.restart = restart
M.isActive = isActive
M.getGamemodeId = getGamemodeId
M.getMaxPlayers = getMaxPlayers
M.getVehiclePool = getVehiclePool
M.shouldAssignVehiclePool = shouldAssignVehiclePool
M.getPhase = getPhase
M.setReadyCallback = setReadyCallback
M.deferReady = deferReady
M.notifyReady = notifyReady
M.goToMainMenu = goToMainMenu
M.isStartScreenPending = isStartScreenPending
M.playPendingRound = playPendingRound
M.showEndScreen = showEndScreen
M.getPlayerName = getPlayerName

return M
