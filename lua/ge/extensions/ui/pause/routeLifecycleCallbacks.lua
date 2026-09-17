-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "ui_pause_actions",
  "ui_pause_providers_routeData_system",
  "ui_pause_providers_routeData_home",
  "ui_pause_providers_routeData_career",
  "ui_pause_providers_routeData_vehicle",
  "ui_pause_providers_routeData_environment",
  "ui_pause_providers_routeData_multiplayer",
  "ui_pause_providers_routeData_photomode",
  "ui_pause_providers_trafficControls",
  "ui_pause_providers_vehicleTabInteractions",
  "ui_pause_photomode",
}

local PAUSE_HOME_PAUSE_REQUEST_ID = "ui_pause_home_tab"

-- Route label translation keys (untranslated). Breadcrumbs use these keys directly so
-- they can be localized on the Vue side and react to language changes without
-- re-navigating; headings/tabs translate them via _tr(...) at the point of use.
local PauseRouteLabels = {
  ["pause.system"] = "ui.pause.system",
  ["pause"] = "ui.pause.tab.home",
  ["pause.hudApps"] = "ui.dashboard.appedit",
  ["pause.hudApps.editlayout"] = "ui.hudApps.editLayout",
  ["pause.hudApps.layoutactions"] = "ui.hudApps.layoutActions",
  ["pause.hudApps.selector"] = "ui.appselect.apps",
  ["pause.photomode"] = "ui.dashboard.photomode",
  ["pause.career"] = "ui.career.landingPage.name",
  ["pause.career.history"] = "ui.pause.career.history",
  ["pause.career.history.financial"] = "ui.pause.career.financialHistory",
  ["pause.career.history.gameplay"] = "ui.pause.career.gameplayHistory",
  ["pause.career.history.logbook"] = "ui.career.logbook.subHeading",
  ["pause.career.branch"] = "ui.career.landingPage.name",
  ["pause.career.branch.missionDetails"] = "ui.missions.details.startChallenge",
  ["pause.career.branch.bigmap"] = "Map",
  ["pause.career.missionDetails"] = "ui.missions.details.startChallenge",
  ["pause.career.milestones"] = "ui.career.milestones.title",
  ["pause.career.logbook"] = "ui.career.logbook.subHeading",
  ["pause.vehicle"] = "ui.pause.vehicle",
  ["pause.environment"] = "ui.dashboard.environment",
  ["pause.environment.weather"] = "ui.pause.environment.timeWeather",
  ["pause.environment.simulation"] = "ui.pause.environment.simulation",
  ["pause.environment.traffic"] = "ui.radialmenu2.traffic",
  ["pause.multiplayer"] = "ui.dashboard.multiplayer",
  ["pause.vehicle.parts"] = "ui.pause.route.partsManagement",
  ["pause.vehicle.configurationcombined"] = "ui.dashboard.vehicleconfig",
  ["pause.vehicle.configurationcombined.save"] = "ui.pause.route.saveConfig",
  ["pause.vehicle.configurationcombined.configlistmanage"] = "ui.pause.route.manageConfigs",
  ["pause.vehicle.configurationcombined.mirrors"] = "ui.mirrors.name",
  ["pause.vehicle.packs"] = "ui.pause.route.partsPacks",
  ["pause.vehicle.packs.path"] = "ui.pause.route.partsPacks",
  ["pause.vehicle.tuning"] = "ui.vehicleconfig.tuning",
  ["pause.vehicle.paint"] = "ui.pause.route.appearance",
  ["pause.vehicle.save"] = "ui.pause.route.saveConfig",
  ["pause.vehicle.vehicleDetails"] = "ui.pause.route.vehicleDetails",
  ["pause.vehicle.debug"] = "ui.debug.vehicle",
  ["pause.manageVehicles"] = "ui.pause.vehicle.manageVehicles",
  ["pause.manageVehicles.vehicleDetails"] = "ui.pause.route.vehicleDetails",
  ["pause.vehicleDetails"] = "ui.pause.route.vehicleDetails",
  ["pause.multiplayer.settings"] = "ui.multiplayer.sessionSettingsTitle",
  ["pause.multiplayer.gamemode"] = "ui.multiplayer.gamemode",
  ["pause.multiplayer.playerList"] = "ui.pause.route.playerList",
  ["pause.replay"] = "ui.apps.replay.name",
  ["pause.replay.all"] = "ui.pause.route.allReplays",
  ["pause.options"] = "ui.dashboard.options",
  ["pause.options.category"] = "ui.dashboard.options",
}

local function getReplayData(routeName)
  local isCatalogMode = routeName == "pause.replay.all"
  return {
    heading = _tr(PauseRouteLabels[routeName] or "ui.apps.replay.name"),
    mainCardClass = "menu-content-card-1--wide",
    mainPanelContent = {
      {
        id = "replayHostComponent",
        type = "component",
        componentName = "PauseReplayHost",
        props = {
          mode = isCatalogMode and "catalog" or "player",
        },
      },
    },
  }
end

local function getPauseRouteData(context, routeName)
  if routeName == "pause.system" then
    return ui_pause_providers_routeData_system.getSystemData(context)
  end
  if routeName == "pause" then
    if context.mode == "multiplayer" then
      return ui_pause_providers_routeData_multiplayer.getMultiplayerData(context)
    end
    return ui_pause_providers_routeData_home.getHomeData(context)
  end
  if routeName == "pause.vehicleDetails" then
    return ui_pause_providers_routeData_home.getHomeVehicleDetailsData(context)
  end
  if routeName == "pause.career" then
    return ui_pause_providers_routeData_career.getCareerProgressData(context)
  end
  if routeName == "pause.career.history" then
    return ui_pause_providers_routeData_career.getCareerHistoryData(context)
  end
  if routeName == "pause.career.history.financial" then
    return ui_pause_providers_routeData_career.getCareerHistoryDetailData(context, "financial")
  end
  if routeName == "pause.career.history.gameplay" then
    return ui_pause_providers_routeData_career.getCareerHistoryDetailData(context, "gameplay")
  end
  if routeName == "pause.manageVehicles" then
    return ui_pause_providers_routeData_vehicle.getVehicleSpawnedData(context)
  end
  if routeName == "pause.manageVehicles.vehicleDetails" then
    return ui_pause_providers_routeData_home.getHomeVehicleDetailsData(context)
  end

  if routeName == "pause.vehicle" then
    return ui_pause_providers_routeData_vehicle.getVehicleData(context)
  end
  if routeName == "pause.vehicle.parts" then
    return ui_pause_providers_routeData_vehicle.getVehiclePartsData()
  end
  if routeName == "pause.vehicle.configurationcombined" then
    return ui_pause_providers_routeData_vehicle.getVehicleConfigurationCombinedData()
  end
  if routeName == "pause.vehicle.packs" or routeName == "pause.vehicle.packs.path" then
    return ui_pause_providers_routeData_vehicle.getVehiclePacksData()
  end
  if routeName == "pause.vehicle.tuning" then
    return ui_pause_providers_routeData_vehicle.getVehicleTuningData()
  end
  if routeName == "pause.vehicle.paint" then
    return ui_pause_providers_routeData_vehicle.getVehiclePaintData()
  end
  if routeName == "pause.vehicle.save" then
    return ui_pause_providers_routeData_vehicle.getVehicleSaveData()
  end
  if routeName == "pause.vehicle.configurationcombined.save" then
    return ui_pause_providers_routeData_vehicle.getVehicleSaveData()
  end
  if routeName == "pause.vehicle.configurationcombined.configlistmanage" then
    return ui_pause_providers_routeData_vehicle.getVehicleConfigListManageData()
  end
  if routeName == "pause.vehicle.vehicleDetails" then
    return ui_pause_providers_routeData_home.getHomeVehicleDetailsData(context)
  end
  if routeName == "pause.vehicle.debug" then
    return ui_pause_providers_routeData_vehicle.getVehicleDebugData()
  end

  if routeName == "pause.environment" then
    return ui_pause_providers_routeData_environment.getEnvironmentData(context)
  end
  if routeName == "pause.environment.weather" then
    return ui_pause_providers_routeData_environment.getEnvironmentWeatherData(context)
  end
  if routeName == "pause.environment.simulation" then
    return ui_pause_providers_routeData_environment.getEnvironmentSimulationData(context)
  end
  if routeName == "pause.environment.traffic" then
    return ui_pause_providers_routeData_environment.getEnvironmentTrafficData(context)
  end

  if routeName == "pause.multiplayer" then
    return ui_pause_providers_routeData_multiplayer.getMultiplayerData(context)
  end
  if routeName == "pause.multiplayer.settings" then
    return ui_pause_providers_routeData_multiplayer.getMultiplayerSettingsData(context)
  end
  if routeName == "pause.multiplayer.gamemode" then
    return ui_pause_providers_routeData_multiplayer.getMultiplayerGamemodeData()
  end
  if routeName == "pause.multiplayer.playerList" then
    return ui_pause_providers_routeData_multiplayer.getMultiplayerPlayerListData()
  end

  if routeName == "pause.photomode" or routeName:find("^pause%.photomode%.") == 1 then
    return ui_pause_providers_routeData_photomode.getPhotomodeData()
  end

  if routeName == "pause.replay" or routeName == "pause.replay.all" then
    return getReplayData(routeName)
  end

  return {}
end

local function getPauseRootRouteName(routeName)
  local name = routeName or ""
  if name == "pause.photomode" or name:find("^pause%.photomode%.") == 1 then return "pause.photomode" end
  if name == "pause.system" then return "pause.system" end
  if name == "pause.career.milestones" then return "pause.career.history" end
  if name == "pause.career.history" or name:find("^pause%.career%.history%.") == 1 then return "pause.career.history" end
  if name == "pause.career" or name:find("^pause%.career%.") == 1 then return "pause.career" end
  if name == "pause.manageVehicles" or name:find("^pause%.manageVehicles%.") == 1 then return "pause" end
  if name == "pause.vehicleDetails" then return "pause" end
  if name:find("^pause%.vehicle") == 1 then return "pause.vehicle" end
  if name:find("^pause%.environment") == 1 then return "pause.environment" end
  if name:find("^pause%.multiplayer") == 1 then return "pause.multiplayer" end
  return "pause"
end

local function getPauseSelectedTabIndex(routeName, tabs)
  local rootRoute = getPauseRootRouteName(routeName)
  for i, tab in ipairs(tabs or {}) do
    if tab.routeName == rootRoute then
      return i - 1
    end
  end
  return 0
end

local function buildPauseBreadcrumbs(routeName)
  if routeName == "pause.system" or routeName == "pause" or routeName == "pause.career" or routeName == "pause.career.history" or routeName == "pause.vehicle" or routeName == "pause.environment" or routeName == "pause.multiplayer" then
    return {}
  end

  local breadcrumbs = {
    {label = "ui.environment.pause", routeName = "pause"},
  }

  local rootRoute = getPauseRootRouteName(routeName)
  if rootRoute ~= "pause" then
    table.insert(breadcrumbs, {
      label = PauseRouteLabels[rootRoute] or rootRoute,
      routeName = rootRoute,
    })
  end

  if routeName == "pause.manageVehicles.vehicleDetails" then
    table.insert(breadcrumbs, {
      label = PauseRouteLabels["pause.manageVehicles"] or "ui.pause.vehicle.manageVehicles",
      routeName = "pause.manageVehicles",
    })
  end

  if routeName == "pause.replay.all" then
    table.insert(breadcrumbs, {
      label = PauseRouteLabels["pause.replay"] or "ui.apps.replay.name",
      routeName = "pause.replay",
    })
  end

  if routeName == "pause.hudApps.editlayout" or routeName == "pause.hudApps.layoutactions" or routeName == "pause.hudApps.selector" then
    table.insert(breadcrumbs, {
      label = PauseRouteLabels["pause.hudApps"] or "ui.dashboard.appedit",
      routeName = "pause.hudApps",
    })
  end

  if routeName == "pause.hudApps.layoutactions" or routeName == "pause.hudApps.selector" then
    table.insert(breadcrumbs, {
      label = PauseRouteLabels["pause.hudApps.editlayout"] or "ui.dashboard.appedit",
      routeName = "pause.hudApps.editlayout",
    })
  end

  table.insert(breadcrumbs, {
    label = (routeName == "pause.vehicle.save" or routeName == "pause.vehicle.configurationcombined.save")
      and ui_pause_providers_routeData_vehicle.getVehicleSaveRouteTitle()
      or (PauseRouteLabels[routeName] or routeName),
    routeName = routeName,
  })

  return breadcrumbs
end

local function buildPauseTabs(context)
  local homeTabLabel = _tr("ui.pause.tab.home")
  local homeTabIcon = "road"
  if context.mode == "freeroam" then
    homeTabLabel = _tr("ui.playmodes.freeroam")
  elseif context.mode == "mission" then
    homeTabLabel = _tr("ui.playmodes.mission")
    homeTabIcon = "flag"
  end
  local tabs = {
    {
      tabId = "system",
      routeName = "pause.system",
      label = _tr("ui.pause.system"),
      icon = "adjust",
      digestHeading = _tr("ui.pause.system"),
      visible = true,
      enabled = true,
      disabledReason = nil,
    },
    {
      tabId = "home",
      routeName = "pause",
      label = homeTabLabel,
      icon = homeTabIcon,
      digestHeading = _tr("ui.pause.tab.activities"),
      visible = true,
      enabled = true,
      disabledReason = nil,
    },
  }

  if context.mode == "career" then
    table.insert(tabs, {
      tabId = "progress",
      routeName = "pause.career",
      label = _tr("ui.career.landingPage.name"),
      icon = "cup",
      digestHeading = _tr("ui.career.landingPage.name"),
      visible = true,
      enabled = true,
      disabledReason = nil,
    })
    table.insert(tabs, {
      tabId = "history",
      routeName = "pause.career.history",
      label = _tr("ui.pause.career.history"),
      icon = "listBig",
      digestHeading = _tr("ui.pause.career.history"),
      visible = true,
      enabled = true,
      disabledReason = nil,
    })
  else
    table.insert(tabs, {
      tabId = "vehicle",
      routeName = "pause.vehicle",
      label = _tr("ui.pause.vehicle"),
      icon = "car",
      digestHeading = _tr("ui.pause.vehicle"),
      visible = true,
      enabled = true,
      disabledReason = nil,
    })
    table.insert(tabs, {
      tabId = "environment",
      routeName = "pause.environment",
      label = _tr("ui.dashboard.environment"),
      icon = "weather",
      digestHeading = _tr("ui.dashboard.environment"),
      visible = true,
      enabled = true,
      disabledReason = nil,
    })
  end

  if MP ~= nil and not context.isFreeroamTutorialActive and context.mode == 'freeroam' then
    table.insert(tabs, {
      tabId = "multiplayer",
      routeName = "pause.multiplayer",
      label = _tr("ui.dashboard.multiplayer"),
      icon = "helmets",
      digestHeading = _tr("ui.dashboard.multiplayer"),
      visible = true,
      enabled = true,
      disabledReason = nil,
    })
  end

  -- mod-contributed tabs
  for _, modTab in ipairs(ui_pause_actions.getVisibleModTabs()) do
    table.insert(tabs, modTab)
  end

  return tabs
end

local function isPauseRouteName(routeName)
  if type(routeName) ~= "string" then return false end
  return routeName == "pause"
    or routeName:find("^pause%.") == 1
    or routeName:find("^menu%.pause") == 1
end

local function shouldPauseSimulationForRoute(routeName)
  if type(routeName) ~= "string" then return false end
  if routeName == "pause.options" or routeName:find("^pause%.options%.") == 1 then
    return true
  end
  if routeName == "pause.vehicle.parts" or routeName == "pause.vehicle.configurationcombined" or routeName == "pause.vehicle.configurationcombined.mirrors" or routeName == "pause.vehicle.tuning" or routeName == "pause.vehicle.debug" or routeName == "pause.vehicle.paint" then
    return false
  end
  if routeName == "pause.environment.weather" or routeName == "pause.environment.simulation" then
    return false
  end
  if routeName == "pause.replay" or routeName:find("^pause%.replay%.") == 1 then
    return false
  end
  if routeName == "pause.manageVehicles" or routeName:find("^pause%.manageVehicles%.") == 1 then
    return true
  end
  if routeName == "pause.photomode" or routeName:find("^pause%.photomode%.") == 1 then
    return false
  end
  return routeName == "pause" or routeName:find("^pause%.") == 1
end

local function setPauseSimulationRequest(enabled)
  if enabled then
    if simTimeAuthority and simTimeAuthority.pushPauseRequest then
      simTimeAuthority.pushPauseRequest(PAUSE_HOME_PAUSE_REQUEST_ID)
    end
    return
  end

  if simTimeAuthority and simTimeAuthority.popPauseRequest then
    simTimeAuthority.popPauseRequest(PAUSE_HOME_PAUSE_REQUEST_ID)
  end
end

local function getPauseRouteHeading(routeName, routeHeading)
  if routeHeading then return routeHeading end
  if routeName == "pause.vehicle.save" or routeName == "pause.vehicle.configurationcombined.save" then
    return ui_pause_providers_routeData_vehicle.getVehicleSaveRouteTitle()
  end
  return _tr(PauseRouteLabels[routeName] or "ui.environment.pause")
end

local function buildPauseLayoutData(routeName, navigationContext, includeRouteContent)
  local runtimeContext = type(navigationContext) == "table" and navigationContext or {}
  local tabs = buildPauseTabs(runtimeContext)

  ui_pause_actions.clearActions()
  local routeData = includeRouteContent == false and {} or (getPauseRouteData(runtimeContext, routeName) or {})

  local mainContent = routeData.mainPanelContent or {}
  routeData.mainPanelContent = nil
  local sideContent = routeData.sidePanelContents or {}
  routeData.sidePanelContents = nil
  local panelsContent = routeData.panels or {}
  routeData.panels = nil
  local routeHeading = routeData.heading
  routeData.heading = nil

  local railContent = routeData.rail or {}
  routeData.rail = nil

  return {
    topbar = {
      show = true,
      tabs = tabs,
      selectedTab = getPauseSelectedTabIndex(routeName, tabs),
      hints = {
        tabLeft = _tr("ui.pause.hints.previousTab"),
        tabRight = _tr("ui.pause.hints.nextTab"),
      },
      rightWidget = "pauseSystemInfo",
    },
    header = {
      heading = getPauseRouteHeading(routeName, routeHeading),
      subheading = nil,
      breadcrumbs = buildPauseBreadcrumbs(routeName),
    },
    content = {
      main = mainContent,
      side = sideContent,
      panels = panelsContent,
      rail = railContent,
      data = routeData,
    },
    nav = {
      scopeId = "pause-root",
      autoFocus = true,
    },
  }
end

local function fillPauseRouteData(context, toRoute, fromRoute, data, includeRouteContent)
  local routeName = toRoute and toRoute.name
  if not isPauseRouteName(routeName) then
    return
  end

  data.layoutMenu = buildPauseLayoutData(routeName, context, includeRouteContent)
  data.pause = {
    routeName = routeName,
    context = context or {},
  }
end

local function attachPhotomodeRouteData(context, toRoute, fromRoute, data)
  local routeName = toRoute and toRoute.name
  if routeName ~= "pause.photomode" then
    return
  end

  -- TODO: replace this enter-time payload workaround with an explicit lifecycle contract.
  -- Photomode needs fresh data after beginPhotomodeSession(); relying only on onMount can leave Show UI empty on late/stale mount acks.
  local routeData = getPauseRouteData(type(context) == "table" and context or {}, routeName) or {}
  if data.layoutMenu and data.layoutMenu.content then
    data.layoutMenu.content.data = routeData
  end
  if routeData.photomode then
    data.photomode = routeData.photomode
  end
end

function M.onPauseEnter(context, toRoute, fromRoute, data)
  -- dump("onPauseEnter", toRoute and toRoute.name)
  if not isPauseRouteName(toRoute and toRoute.name) then
    dump("not a pause route")
    return
  end

  if ui_pause_providers_vehicleTabInteractions and ui_pause_providers_vehicleTabInteractions.onPauseRouteLifecycle then
    ui_pause_providers_vehicleTabInteractions.onPauseRouteLifecycle(toRoute and toRoute.name)
  end

  fillPauseRouteData(context, toRoute, fromRoute, data, false)

  setPauseSimulationRequest(shouldPauseSimulationForRoute(toRoute and toRoute.name))

  if (toRoute and toRoute.name) == "pause" then
    if ui_pause_camera and ui_pause_camera.start then
      ui_pause_camera.start()
    end
  end
end

function M.onPauseMount(context, toRoute, fromRoute, data)
  -- dump("onPauseMount", toRoute and toRoute.name)
  fillPauseRouteData(context, toRoute, fromRoute, data, true)

  setPauseSimulationRequest(shouldPauseSimulationForRoute(toRoute and toRoute.name))

  if ui_pause_camera and ui_pause_camera.beginPauseSession then
    ui_pause_camera.beginPauseSession()
  end
end

function M.onPauseLeave(context, toRoute, fromRoute, data)
  -- dump("onPauseLeave", fromRoute and fromRoute.name)
  local fromName = fromRoute and fromRoute.name or ""
  if ui_pause_providers_vehicleTabInteractions and ui_pause_providers_vehicleTabInteractions.onPauseRouteLifecycle then
    ui_pause_providers_vehicleTabInteractions.onPauseRouteLifecycle(toRoute and toRoute.name)
  end
  setPauseSimulationRequest(shouldPauseSimulationForRoute(toRoute and toRoute.name))
  if fromName == "pause" then
    if ui_pause_camera and ui_pause_camera.stop then
      ui_pause_camera.stop()
    end
  end

  if isPauseRouteName(fromName) and not isPauseRouteName(toRoute and toRoute.name) then
    if ui_pause_camera and ui_pause_camera.endPauseSession then
      ui_pause_camera.endPauseSession()
    end
  end
end

function M.onPauseBigmapLeave(context, toRoute, fromRoute, data)
  if freeroam_vueBigMap and freeroam_vueBigMap.exitBigMap then
    freeroam_vueBigMap.exitBigMap()
  elseif freeroam_bigMapMode and freeroam_bigMapMode.exitBigMap then
    freeroam_bigMapMode.exitBigMap(true)
  end

  M.onPauseLeave(context, toRoute, fromRoute, data)
end

function M.onPhotomodeEnter(context, toRoute, fromRoute, data)
  M.onPauseEnter(context, toRoute, fromRoute, data)
  local toName = toRoute and toRoute.name or ""
  if ui_pause_photomode and ui_pause_photomode.beginPhotomodeSession then
    ui_pause_photomode.beginPhotomodeSession()
  end
  attachPhotomodeRouteData(context, toRoute, fromRoute, data)
  if ui_pause_photomode and ui_pause_photomode.onPhotomodeRouteEnter then
    ui_pause_photomode.onPhotomodeRouteEnter(toName)
  end
  local rawRouteData = data.layoutMenu and data.layoutMenu.content and data.layoutMenu.content.data or {}
  if rawRouteData.photomode then
    data.photomode = rawRouteData.photomode
  end
end

function M.onPhotomodeMount(context, toRoute, fromRoute, data)
  M.onPauseMount(context, toRoute, fromRoute, data)
  local rawRouteData = data.layoutMenu and data.layoutMenu.content and data.layoutMenu.content.data or {}
  if rawRouteData.photomode then
    data.photomode = rawRouteData.photomode
  end
end

function M.onPhotomodeLeave(context, toRoute, fromRoute, data)
  local toName = toRoute and toRoute.name or ""
  if toName == "pause.photomode" or toName:find("^pause%.photomode%.") == 1 then
    M.onPauseLeave(context, toRoute, fromRoute, data)
    return
  end
  if ui_pause_photomode and ui_pause_photomode.onPhotomodeRouteLeave then
    ui_pause_photomode.onPhotomodeRouteLeave(toName)
  end
  if ui_pause_photomode and ui_pause_photomode.endPhotomodeSession then
    ui_pause_photomode.endPhotomodeSession()
  end
  M.onPauseLeave(context, toRoute, fromRoute, data)
end

return M
