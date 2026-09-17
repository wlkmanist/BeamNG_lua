-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

local blockCounter = 0
local BLOCK_FORCE_THRESHOLD = 6
local pauseV2Enabled = true

local activeGameplayRoute = "play"

local function setGameplayRoute(route)
  activeGameplayRoute = route or "play"
end

local function getGameplayRoute()
  return activeGameplayRoute
end

local function isGameplayRoute(routeName)
  return routeName == "play" or routeName == activeGameplayRoute
end

local routeAliases = {
  vehicleselect = "menu.vehicles",
  vehicleconfig = "menu.vehicleconfig.parts",
  vehicledebug = "menu.vehicleconfig.debug",
  appedit = "pause.hudApps",
}

local function hookMenuToggled(showMenu, navigationResult)
  if not showMenu then
    if not navigationResult or navigationResult.result == false then
      return
    end
  elseif navigationResult and navigationResult.result == false then
    return
  end

  extensions.hook("onMenuToggled", showMenu)
end

local function navigateHandled(targetRoute, params, options)
  blockCounter = 0
  if options and options.hookMenuToggled == true then
    extensions.hook("onBeforeMenuOpened")
  end
  local navigationResult = ui_router.navigate(targetRoute, params)
  if options and options.hookMenuToggled ~= nil then
    hookMenuToggled(options.hookMenuToggled, navigationResult)
  end

  return {
    handled = true,
    targetRoute = targetRoute,
    navigation = navigationResult
  }
end

local function getFinishedScenarioRoute(sc)
  if not sc then
    return "scenario.end"
  end

  if sc.isQuickRace then
    return "scenario.quickrace.end"
  end

  if campaign_campaigns
    and campaign_campaigns.getCampaignActive and campaign_campaigns.getCampaignActive()
    and campaign_campaigns.isCampaignOver and campaign_campaigns.isCampaignOver(sc) then
    return "scenario.chapter.end"
  end

  return "scenario.end"
end

local function hasLoadedLevel()
  return type(getMissionFilename) == "function" and getMissionFilename() ~= ""
end

local function getMenuRoute()
  -- With no level loaded, the only valid "menu" destination is the main menu.
  -- pause/play are in-level routes and must never be chosen here.
  if not hasLoadedLevel() then
    return "menu"
  end

  if pauseV2Enabled then
    if core_replay and core_replay.getLoadedFile and core_replay.getLoadedFile() ~= "" then
      return "pause.replay:pause-replay-player"
    end
    return "pause"
  end
  if career_career.isActive() then return "menu.careerPause" end
  return "menu"
end

local function getOptionsRoute()
  if not hasLoadedLevel() then
    return "options"
  end
  if pauseV2Enabled then
    return "pause.options"
  end
  return "options"
end

local function isPauseRoute(routeName)
  return routeName == "pause" or string.find(routeName or "", "^pause%.") ~= nil
end

local function isOnMenu(routeName)
  return routeName == "menu" or routeName == "menu.careerPause" or isPauseRoute(routeName)
end

-- Picks a sensible destination when back navigation has no valid target
-- (e.g. exiting an abstract/standalone route such as a debug screen).
local function getContextualFallbackRoute()
  if not hasLoadedLevel() then
    return "menu"
  end
  if gameplay_garageMode.isActive() then
    return "garage"
  end
  return getGameplayRoute()
end

local function handleGarageMode(currentRoute)
  if currentRoute.resolved.name == "menu" then
    return navigateHandled("garage")
  elseif currentRoute.resolved.name == "garage" then
    return {
      handled = true
    }
  else
    ui_router.back()
    return {
      handled = true
    }
  end
end

local function handleMissionDetails(currentRoute)
  if extensions.gameplay_missions_missionScreen.isAnyMissionActive() then
    local isMissionStartOrEndScreen = extensions.gameplay_missions_missionScreen.isMissionStartOrEndScreenActive()
    if isMissionStartOrEndScreen then
      return navigateHandled("mission.control", {
        mode = isMissionStartOrEndScreen
      })
    end
  end

  return navigateHandled("play")
end

local function navigationBack()
  local currentRoute = ui_router.getCurrent()
  local currentRouteName = currentRoute and currentRoute.resolved and currentRoute.resolved.name or nil
  if not currentRouteName then
    return { handled = false, reason = "no_current_route" }
  end

  local backResult = ui_router.back()

  if backResult and backResult.result == false and backResult.reason == "guard_blocked_exit" then
    blockCounter = blockCounter + 1
    if blockCounter < BLOCK_FORCE_THRESHOLD then
      return { handled = true }
    end
    blockCounter = 0
    return navigateHandled(getMenuRoute(), nil, { hookMenuToggled = true })
  end

  blockCounter = 0

  if backResult and backResult.result ~= false then
    local targetIsMenu = backResult.data and isOnMenu(backResult.data.request.name)
    hookMenuToggled(targetIsMenu or false, backResult)
    return { handled = true, navigation = backResult }
  end

  if currentRouteName == "blank" or isGameplayRoute(currentRouteName) then
    return navigateHandled(getMenuRoute(), nil, { hookMenuToggled = true })
  end

  local fallbackRoute = getContextualFallbackRoute()
  return navigateHandled(fallbackRoute, nil, { hookMenuToggled = isOnMenu(fallbackRoute) })
end

M.toggleMenu = function()
  local currentRoute = ui_router.getCurrent()
  local currentRouteName = currentRoute and currentRoute.resolved and currentRoute.resolved.name or nil
  if not currentRouteName then
    return {
      handled = false,
      reason = "no_current_route"
    }
  end

  if not hasLoadedLevel() then
    if string.find(currentRouteName or "", "menu%.mods") then
      ui_router.navigate("menu")
      return {
        handled = true
      }
    end

    -- Already at the main menu: nothing to toggle to when no level is loaded.
    if currentRouteName == "menu" then
      return { handled = true }
    end

    -- pause/play are in-level routes; if we somehow ended up there without a
    -- loaded level, force back to the main menu instead of bouncing between them.
    if isGameplayRoute(currentRouteName) or isPauseRoute(currentRouteName) then
      return navigateHandled("menu", nil, { hookMenuToggled = true })
    end

    -- attempt back navigation, falling back contextually when it has no target
    return navigationBack()
  end

  if gameplay_garageMode.isActive() then
    return handleGarageMode(currentRoute)
  end

  --[[
  if currentRouteName == "mission.details" then
    if pauseV2Enabled then
      return navigationBack()
    end
    return handleMissionDetails(currentRoute)
  end

  if currentRouteName == "play"
    and extensions.gameplay_missions_missionScreen.isAnyMissionActive() then
    return navigateHandled("mission.details", nil, {
      hookMenuToggled = true
    })
  end
  ]]
  local missionScreenMode = gameplay_missions_missionScreen and gameplay_missions_missionScreen.isMissionStartOrEndScreenActive()
  if isPauseRoute(currentRouteName) and missionScreenMode then
    return navigateHandled("mission.control", {
      mode = missionScreenMode
    }, {
      hookMenuToggled = false
    })
  end

  if (currentRouteName == "pause" or currentRouteName == "play") and scenario_scenarios and scenario_scenarios.getScenario then
    local sc = scenario_scenarios.getScenario()
    local state = sc and sc.state
    if state == "physicsPaused" then
      state = scenario_scenarios.getScenarioStateAtPauseEvent()
    end
    if state == "pre-running" then
      --scenario_scenarios.setScenarioStateAtPauseEvent(nil)
      return navigateHandled("scenario.start", nil, {
        hookMenuToggled = true
      })
    elseif state == "finished" or state == "post" then
      --scenario_scenarios.setScenarioStateAtPauseEvent(nil)
      return navigateHandled(getFinishedScenarioRoute(sc), nil, {
        hookMenuToggled = true
      })
    end
  end

  if isGameplayRoute(currentRouteName) then
    return navigateHandled(getMenuRoute(), nil, {
      hookMenuToggled = true
    })
  end

  if isOnMenu(currentRouteName) then
    return navigateHandled(getGameplayRoute(), nil, {
      hookMenuToggled = false
    })
  end

  return navigationBack()
end

M.openMenu = function()
  local currentRoute = ui_router.getCurrent()
  local currentRouteName = currentRoute and currentRoute.resolved and currentRoute.resolved.name or nil
  if currentRouteName and isOnMenu(currentRouteName) then
    return { handled = true }
  end
  return navigateHandled(getMenuRoute(), nil, { hookMenuToggled = true })
end

M.closeToMenu = function()
  return navigateHandled("menu")
end

M.closeMenu = function()
  local currentRoute = ui_router.getCurrent()
  local currentRouteName = currentRoute and currentRoute.resolved and currentRoute.resolved.name or nil
  if not currentRouteName or isGameplayRoute(currentRouteName) or currentRouteName == "garage" then
    return { handled = true }
  end
  return navigateHandled(getGameplayRoute(), nil, { hookMenuToggled = false })
end

M.MenuOpenModule = function(data)
  if type(data) == "string" then
    local route = data == "options" and getOptionsRoute() or (routeAliases[data] or data)
    ui_router.navigate(route)
  else
    ui_router.navigate(data.state, data.params)
  end
end

M.menuHide = function(showMenu)
  if showMenu then
    return navigateHandled(getMenuRoute())
  else
    return navigateHandled(getGameplayRoute())
  end
end

M.setGameplayRoute = setGameplayRoute

M.isPauseV2Enabled = function()
  return pauseV2Enabled
end

return M
