local M = {}

local function getKeyFromDetails(details)
  return string.format("mission_%s", details.missionId)
end

local function onGameplaySelectorGetTiles(items, backend)
  if backend.backendName == "gameplaySelector" then
    for _, mission in ipairs(gameplay_missions_missions.getAllMissions()) do
      local isCareerOnly = mission.careerSetup and mission.careerSetup.showInCareer and not mission.careerSetup.showInFreeroam
      local forwardInfo = gameplay_missions_unlocks.getForwardMissionInfo(mission)

      local item =  {
        name = mission.name,
        preview = mission.previewFile,
        favouriteIdx = 0,
        showFavouriteIconPercent = 0,
        showDetails = {missionId = mission.id},

        system = "challenges",
        missionType = mission.missionType,
        missionTypeLabel = mission.missionTypeLabel,
        gameplaySelectorSubGroup = mission.gameplaySelectorSubGroup,
        type = _tr(mission.missionTypeLabel),
        sourceIcons = {},
        isAuxiliary = mission.devMission,
        isCareerOnly = isCareerOnly, -- Add flag for filtering
        order = isCareerOnly and forwardInfo.depth or -(mission.date or 0),
        validBackends = {gameplaySelector = true},
        date = mission.date,
      }
      item.key = getKeyFromDetails(item.showDetails)
      item.showDetails.key = item.key

      item.name = item.name or "ui.menu.gameplaySelector.missions.unnamedMission"
      item.name = core_locales.translateWithOrWithoutContext(item.name)
      if mission.startTrigger.type == "coordinates" then
        item.level = mission.startTrigger.level
      elseif mission.startTrigger.type == "level" then
        item.level = mission.startTrigger.level
      end
      if item.level then
        item.level = core_levels.getLevelTitle(item.level) or "ui.menu.gridSelector.other"
        item.level = _tr(item.level)
      end
      if mission.official then
        table.insert(item.sourceIcons, {icon = "beamNG"})
      end
      if mission.devMission then
        table.insert(item.sourceIcons, {icon = "bug"})
      end
      if isCareerOnly then
        table.insert(item.sourceIcons, {icon = "cup"})
      end
      table.insert(items, item)
    end
  end

  table.insert(items, {
    name = _tr("ui.menu.gameplaySelector.missions.moreMissions"),
    system = _tr("ui.menu.gameplaySelector.propValue.system.otherGameplay"),
    key = "moreMissions",
    order = 100,
    isLegacy = true,
    validBackends = {}
  })
end

local function generateMissionSpecifications(mission)
  local generalSpecs = {}
  local careerSpecs = {}

  -- Mission Type
  if mission.missionTypeLabel then
    table.insert(generalSpecs, {
      icon = "info",
      label = _tr("bigMap.missionLabels.missionType"),
      value = _tr(mission.missionTypeLabel)
    })
  end

  -- Difficulty
  if mission.additionalAttributes and mission.additionalAttributes.difficulty then
    local additionalAttributes, _ = gameplay_missions_missions.getAdditionalAttributes()
    local difficultyData = additionalAttributes.difficulty.valuesByKey[mission.additionalAttributes.difficulty]
    if difficultyData then
      table.insert(generalSpecs, {
        icon = "flag",
        label = _tr("ui.common.property.difficulty"),
        value = _tr(difficultyData.translationKey or difficultyData.label)
      })
    end
  end

  -- Vehicle Used
  if mission.additionalAttributes and mission.additionalAttributes.vehicle then
    local additionalAttributes, _ = gameplay_missions_missions.getAdditionalAttributes()
    local vehicleData = additionalAttributes.vehicle.valuesByKey[mission.additionalAttributes.vehicle]
    if vehicleData then
      table.insert(generalSpecs, {
        icon = "car",
        label = _tr("ui.common.property.vehicleUsed"),
        value = _tr(vehicleData.translationKey or vehicleData.label)
      })
    end
  end

  -- Author
  if mission.author then
    table.insert(generalSpecs, {
      icon = "personSolid",
      label = _tr("ui.common.property.authors"),
      value = mission.author
    })
  end

  -- Created date
  if mission.date then
    local dateValue = os.date("%d %B %Y", mission.date)
    table.insert(generalSpecs, {
      icon = "info",
      label = _tr("ui.common.property.createdAt"),
      value = dateValue
    })
  end

  -- Level/Map
  if mission.startTrigger and mission.startTrigger.level then
    local levelTitle = core_levels.getLevelTitle(mission.startTrigger.level)
    if levelTitle then
      table.insert(generalSpecs, {
        icon = "terrain",
        label = _tr("ui.common.property.map"),
        value = _tr(levelTitle)
      })
    end
  end

  -- Custom Additional Attributes
  if mission.customAdditionalAttributes and #mission.customAdditionalAttributes > 0 then
    for _, attr in ipairs(mission.customAdditionalAttributes) do
      table.insert(generalSpecs, {
        icon = attr.icon or "info",
        label = core_locales.translateWithOrWithoutContext(attr.labelKey or "ui.menu.gameplaySelector.additionalInfo"),
        value = core_locales.translateWithOrWithoutContext(attr.valueKey or "ui.common.unknown")
      })
    end
  end

  -- Career Setup (Skill/Branch)
  if mission.careerSetup then
    if mission.careerSetup.skill and mission.careerSetup.skill ~= "(none)" then
      table.insert(careerSpecs, {
        icon = "star",
        label = _tr("ui.common.property.skill"),
        value = _tr(mission.careerSetup.skill)
      })
    end

    -- Career Content Availability
    local isCareerOnly = mission.careerSetup.showInCareer and not mission.careerSetup.showInFreeroam
    if isCareerOnly then
      table.insert(careerSpecs, {
        icon = "cup",
        label = _tr("ui.common.property.availability"),
        value = _tr("ui.menu.gameplaySelector.missions.careerOnly")
      })
    end
  end

  -- Return specifications as separate lists
  local specifications = {}
  if #generalSpecs > 0 then
    table.insert(specifications, generalSpecs)
  end
  if #careerSpecs > 0 then
    table.insert(specifications, careerSpecs)
  end

  return specifications
end

local function onGameplaySelectorGetDetails(itemDetails, details, buttonInstance, backend)
  local missionId = itemDetails.missionId
  if not missionId then
    return
  end

  local mission = gameplay_missions_missions.getMissionById(missionId)
  if not mission then
    return
  end

  local data = {
    headerTitle = core_locales.translateWithOrWithoutContext(mission.name),
    description = core_locales.translateWithOrWithoutContext(mission.description or ""),
    preview = mission.previewFile,
    isFavourite = backend.isFavourite(getKeyFromDetails(itemDetails)),
    specifications = generateMissionSpecifications(mission),
    tags = {},
    buttonInfo = {}
  }
  if buttonInstance and backend then
    table.insert(data.buttonInfo,
      buttonInstance.addButton(function()
        -- Track recent usage
        backend.trackRecent(itemDetails.key)
        -- Start mission
        gameplay_missions_missionManager.startWithLoadingLevel(mission)
      end, {
        label = _tr("ui.menu.gameplaySelector.missions.startMission"),
        icon = "play",
        primary = true,
        isDoubleClickAction = true,
        waitForLoadingScreen = true,
      })
    )
  end

  -- Add tags for all sourceIcons
  if mission.official then
    table.insert(data.tags, {icon = "beamNG", label = _tr("ui.menu.gridSelector.tags.beamngOfficial")})
  end
  if mission.devMission then
    table.insert(data.tags, {icon = "bug", label = _tr("ui.menu.gridSelector.tags.auxiliary")})
  end
  local isCareerOnly = mission.careerSetup and mission.careerSetup.showInCareer and not mission.careerSetup.showInFreeroam
  if isCareerOnly then
    table.insert(data.tags, {icon = "cup", label = _tr("ui.menu.gameplaySelector.missions.careerOnly")})
  end

  -- Add mod information tags
  if mission.modID then
    local mod = core_modmanager.getModNameFromID(mission.modID)
    if mod then
      table.insert(data.tags, {icon = "puzzleModule", label = mission.modTitle or mission.modName, goToMod = mod.modID})
    end
  end

  -- Add mission type tag
  if mission.missionType and mission.missionType ~= "flowgraph" then
    table.insert(data.tags, {icon = "markerTriangleBack", label = _tr(mission.missionTypeLabel or mission.missionType)})
  end
  table.insert(details, data)
end

M.onGameplaySelectorGetTiles = onGameplaySelectorGetTiles
M.onGameplaySelectorGetDetails = onGameplaySelectorGetDetails
return M