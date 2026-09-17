local M = {}

local function getKeyFromDetails(details)
  return string.format("campaign_%s", details.campaignSourceFile)
end

local function onGameplaySelectorGetTiles(items, backend)
  if backend.backendName == "gameplaySelector" then
    for _, campaign in ipairs(campaign_campaignsLoader.getList()) do
      local item = {
        name = campaign.title,
        preview = campaign.previews and campaign.previews[1] or nil,
        favouriteIdx = 0,
        showFavouriteIconPercent = 0,
        showDetails = {campaignSourceFile = campaign.sourceFile},

        system = "campaigns",
        type = "campaign",
        level = campaign.level,
        sourceIcons = {},
        order = -tonumber(campaign.date) or 0,
        isLegacy = true,
        validBackends = {gameplaySelector = true},
        date = campaign.date,
      }
      item.key = getKeyFromDetails(item.showDetails)
      item.showDetails.key = item.key
      item.level = core_levels.getLevelTitle(item.level) or "Other..."
      item.level = _tr(item.level)

      item.name = core_locales.translateWithOrWithoutContext(item.name)
      if campaign.official then
        table.insert(item.sourceIcons, {icon = "beamNG"})
      end
      if campaign.isAuxiliary then
        table.insert(item.sourceIcons, {icon = "bug"})
      end
      table.insert(items, item)
    end
  end

  table.insert(items, {
    name = "More Campaigns...",
    system = "Other Gameplay",
    key = "moreCampaigns",
    order = 100,
    isLegacy = true,
    validBackends = {}
  })
end

local function generateCampaignSpecifications(campaign)
  local specifications = {}

  -- Difficulty
  if campaign.difficulty then
    table.insert(specifications, {
      icon = "flag",
      label = _tr("ui.common.property.difficulty"),
      value = tostring(campaign.difficulty)
    })
  end

  -- Authors
  if campaign.authors then
    table.insert(specifications, {
      icon = "personSolid",
      label = _tr("ui.common.property.authors"),
      value = campaign.authors
    })
  end

  -- Created date
  if campaign.date then
    local dateValue = os.date("%d %B %Y", campaign.date)
    table.insert(specifications, {
      icon = "info",
      label = _tr("ui.common.property.createdAt"),
      value = dateValue
    })
  end

  -- Players count (if multi-player)
  if campaign.maxPlayers and campaign.maxPlayers > 1 then
    local playersValue = string.format("From %d up to %d local players", campaign.minPlayers or 1, campaign.maxPlayers)
    table.insert(specifications, {
      icon = "people",
      label = _tr("ui.common.property.multiseatPlayers"),
      value = playersValue
    })
  end

  -- Count scenarios/missions in campaign
  local scenarioCount = 0
  if campaign.meta and campaign.meta.subsections then
    for _, subsection in pairs(campaign.meta.subsections) do
      if subsection.locations then
        for _ in pairs(subsection.locations) do
          scenarioCount = scenarioCount + 1
        end
      end
    end
  end

  if scenarioCount > 0 then
    table.insert(specifications, {
      icon = "list",
      label = _tr("ui.common.property.scenarios"),
      value = string.format("%d scenarios", scenarioCount)
    })
  end

  table.insert(specifications, {
    icon = "gamepadOld",
    label = _tr("Legacy System"),
    value = "Campaign system is outdated."
  })

  return { specifications }
end

local function onGameplaySelectorGetDetails(itemDetails, details, buttonInstance, backend)
  local campaignSourceFile = itemDetails.campaignSourceFile
  if not campaignSourceFile then
    return
  end
  local campaign = campaign_campaignsLoader.loadCampaign(campaignSourceFile)
  if not campaign then
    return
  end

  local data = {
    headerTitle = core_locales.translateWithOrWithoutContext(campaign.title),
    description = core_locales.translateWithOrWithoutContext(campaign.description),
    preview = campaign.previews and campaign.previews[1] or nil,
    isFavourite = backend.isFavourite(getKeyFromDetails(itemDetails)),
    specifications = generateCampaignSpecifications(campaign),
    tags = {},
    buttonInfo = {
      buttonInstance.addButton(function()
        -- Track recent usage
        backend.trackRecent(itemDetails.key)
        extensions.ui_router.navigate("play")
        -- Start campaign
        campaign_campaignsLoader.start(campaign)
      end, {
        label = "Start Campaign",
        icon = "clapperboard",
        primary = true,
        isDoubleClickAction = true,
        waitForLoadingScreen = true,
      })
    }
  }

  -- Add tags for all sourceIcons
  if campaign.official then
    table.insert(data.tags, {icon = "beamNG", label = _tr("ui.menu.gridSelector.tags.beamngOfficial")})
  end
  if campaign.isAuxiliary then
    table.insert(data.tags, {icon = "bug", label = _tr("ui.menu.gridSelector.tags.auxiliary")})
  end

  -- Add mod information tags
  if campaign.modID then
    local mod = core_modmanager.getModNameFromID(campaign.modID)
    if mod then
      table.insert(data.tags, {icon = "puzzleModule", label = campaign.modTitle or campaign.modName, goToMod = mod.modID})
    end
  end
  table.insert(details, data)
end

M.onGameplaySelectorGetTiles = onGameplaySelectorGetTiles
M.onGameplaySelectorGetDetails = onGameplaySelectorGetDetails
return M
