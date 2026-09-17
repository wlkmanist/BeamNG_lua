local M = {}

local function getKeyFromDetails(details)
  return string.format("scenario_%s", details.scenarioSourceFile)
end

local function onGameplaySelectorGetTiles(items, backend)
  if backend.backendName == "gameplaySelector" then
    for _, scenario in ipairs(scenario_scenariosLoader.getList(nil, false, true)) do
      local item = {
        name = scenario.name,
        preview = scenario.previews and scenario.previews[1] or nil,
        favouriteIdx = 0,
        showFavouriteIconPercent = 0,
        showDetails = {scenarioSourceFile = scenario.sourceFile},

        system = "scenarios",
        type = "scenario",
        level = scenario.levelName,
        sourceIcons = {},
        order = -tonumber(scenario.date or 0) or 0,
        isLegacy = true,
        validBackends = {gameplaySelector = true},
        date = tonumber(scenario.date),
      }
      item.key = getKeyFromDetails(item.showDetails)
      item.showDetails.key = item.key
      if item.level then
        item.level = core_levels.getLevelTitle(item.level) or "Other..."
        item.level = _tr(item.level)
      end

      if item.name then
        item.name = core_locales.translateWithOrWithoutContext(item.name)
      end
      if scenario.playersCountRange and scenario.playersCountRange.max > 1 then
        table.insert(item.sourceIcons, {icon = "helmets"})
        item.system = "scenariosMultiplayer"
        item.type = "scenarioMultiplayer"
      end
      if scenario.official then
        table.insert(item.sourceIcons, {icon = "beamNG"})
      end
      if scenario.isAuxiliary then
        table.insert(item.sourceIcons, {icon = "bug"})
      end
      table.insert(items, item)
    end
  end
  --[[
  table.insert(items, {
    name = "More Scenarios...",
    system = "Other Gameplay",
    key = "moreScenarios",
    order = 100,
    isLegacy = true,
    validBackends = {freeroamSelector = true}
  })
    ]]
end
M.onGameplaySelectorGetTiles = onGameplaySelectorGetTiles

local function generateScenarioSpecifications(scenario)
  local specifications = {}

  -- Difficulty
  if scenario.difficulty or scenario.difficultyLabel then
    local difficultyValue = scenario.difficultyLabel or tostring(scenario.difficulty)
    table.insert(specifications, {
      icon = "flag",
      label = _tr("ui.common.property.difficulty"),
      value = _tr(difficultyValue)
    })
  end

  -- Authors
  if scenario.authors then
    table.insert(specifications, {
      icon = "personSolid",
      label = _tr("ui.common.property.authors"),
      value = scenario.authors
    })
  end

  -- Created date
  if scenario.date then
    local dateValue = os.date("%d %B %Y", scenario.date)
    table.insert(specifications, {
      icon = "info",
      label = _tr("ui.common.property.createdAt"),
      value = dateValue
    })
  end

  -- Map/Level
  if scenario.map then
    table.insert(specifications, {
      icon = "terrain",
      label = _tr("ui.common.property.map"),
      value = _tr(scenario.map)
    })
  end

  -- Players count (if multi-player)
  if scenario.playersCountRange and scenario.playersCountRange.max > 1 then
    local playersValue = string.format("From %d up to %d local players", scenario.playersCountRange.min or 1, scenario.playersCountRange.max)
    table.insert(specifications, {
      icon = "helmets",
      label = _tr("ui.common.property.multiseatPlayers"),
      value = playersValue
    })
  end

  -- Goals (if available)
  if scenario.goals and #scenario.goals > 0 then
    local goalsValue = ""
    for i, goal in ipairs(scenario.goals) do
      if i > 1 then goalsValue = goalsValue .. ", " end
      goalsValue = goalsValue .. core_locales.translateWithOrWithoutContext(goal.tooltip or goal.text or "Unknown Goal")
    end
    table.insert(specifications, {
      icon = "check",
      label = _tr("ui.common.property.goals"),
      value = goalsValue
    })
  end

  -- Additional attributes (if available)
  if scenario.additionalAttributes and #scenario.additionalAttributes > 0 then
    for _, attr in ipairs(scenario.additionalAttributes) do
      table.insert(specifications, {
        icon = attr.icon or "info",
        label = core_locales.translateWithOrWithoutContext(attr.labelKey or "Additional Info"),
        value = core_locales.translateWithOrWithoutContext(attr.valueKey or "Unknown")
      })
    end
  end

  table.insert(specifications, {
    icon = "gamepadOld",
    label = _tr("Legacy System"),
    value = "Scenario system is outdated."
  })

  return { specifications }
end

local function onGameplaySelectorGetDetails(itemDetails, details, buttonInstance, backend)
  local scenarioSourceFile = itemDetails.scenarioSourceFile
  if not scenarioSourceFile then
    return
  end
  local scenario = scenario_scenariosLoader.loadScenario(scenarioSourceFile)
  if not scenario then
    return
  end

  local data = {
    headerTitle = core_locales.translateWithOrWithoutContext(scenario.name),
    description = core_locales.translateWithOrWithoutContext(scenario.description),
    preview = scenario.previews and scenario.previews[1] or nil,
    isFavourite = backend.isFavourite(getKeyFromDetails(itemDetails)),
    specifications = generateScenarioSpecifications(scenario),
    tags = {},
    buttonInfo = {
      buttonInstance.addButton(function()
        -- Track recent usage
        backend.trackRecent(itemDetails.key)
        -- Start scenario
        scenario_scenariosLoader.start(scenario)
      end, {
        label = "Start Scenario",
        icon = "clapperboard",
        primary = true,
        isDoubleClickAction = true,
        waitForLoadingScreen = true,
      })
    }
  }

  -- Add tags for all sourceIcons
  if scenario.official then
    table.insert(data.tags, {icon = "beamNG", label = _tr("ui.menu.gridSelector.tags.beamngOfficial")})
  end
  if scenario.isAuxiliary then
    table.insert(data.tags, {icon = "bug", label = _tr("ui.menu.gridSelector.tags.auxiliary")})
  end
  if scenario.playersCountRange and scenario.playersCountRange.max > 1 then
    table.insert(data.tags, {icon = "helmets", label = _tr("ui.menu.gameplaySelector.propValue.type.scenarioMultiplayer")})
  end

  -- Add mod information tags
  if scenario.modID then
    local mod = core_modmanager.getModNameFromID(scenario.modID)
    if mod then
      table.insert(data.tags, {icon = "puzzleModule", label = scenario.modTitle or scenario.modName, goToMod = mod.modID})
    end
  end
  table.insert(details, data)
end
M.onGameplaySelectorGetDetails = onGameplaySelectorGetDetails

return M
