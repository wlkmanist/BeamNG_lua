local M = {}

M.dependencies = {
  "gameplay_discover",
}

local SYSTEM_KEY = "quickStartExperiences"
local EXPERIENCES_LABEL = "ui.menu.gameplaySelector.quickStart.experiences"
local CHALLENGES_LABEL = "ui.menu.gameplaySelector.propValue.system.challenges"

local function translate(value)
  return core_locales.translateWithOrWithoutContext(value or "")
end

local function getPageKey(page, index)
  return page.folder or page.title or tostring(index)
end

local function getCardCount(page)
  local count = 0
  for _, section in ipairs(page.sections or {}) do
    count = count + #(section.cards or {})
  end
  return count
end

local function getSourceIcons(data)
  local sourceIcons = {}
  if data.isOfficial then
    table.insert(sourceIcons, {icon = "beamNG"})
  end
  if data.isMod then
    table.insert(sourceIcons, {icon = "puzzleModule"})
  end
  return sourceIcons
end

local function getDiscoverPages()
  return gameplay_discover.getDiscoverPages() or {}
end

local function findPage(pageKey)
  for index, page in ipairs(getDiscoverPages()) do
    if getPageKey(page, index) == pageKey then
      return page
    end
  end
end

local function findCard(discoverId)
  for _, page in ipairs(getDiscoverPages()) do
    for _, section in ipairs(page.sections or {}) do
      for _, card in ipairs(section.cards or {}) do
        if card.discoverId == discoverId then
          return card
        end
      end
    end
  end
end

local function buildPageTile(page, index)
  local pageKey = getPageKey(page, index)
  return {
    key = "discoverPage_" .. pageKey,
    name = translate(page.title),
    preview = page.image,
    subElementCount = getCardCount(page),
    gotoPath = {"discoverPage", pageKey, translate(page.title)},
    favouriteIdx = 0,
    showFavouriteIconPercent = 0,
    system = SYSTEM_KEY,
    type = "discoverPage",
    sourceIcons = getSourceIcons(page),
    order = index,
    date = page.date,
    validBackends = {gameplaySelector = true},
  }
end

local function buildCardTile(card, order)
  local item = {
    name = translate(card.title or card.name),
    preview = card.image,
    sourceIcons = getSourceIcons(card),
    order = order,
  }

  if card.type == "mission" and card.missionId then
    item.key = "mission_" .. card.missionId
    item.showDetails = {
      missionId = card.missionId,
      key = item.key,
    }
  else
    item.key = "discover_" .. card.discoverId
    item.showDetails = {
      discoverId = card.discoverId,
      key = item.key,
    }
  end

  return item
end

function M.getPageGroups(pageKey)
  local page = findPage(pageKey)
  if not page then
    return {}
  end

  local experiences = {
    key = "discoverExperiences",
    label = _tr(EXPERIENCES_LABEL),
    tiles = {},
  }
  local challenges = {
    key = "discoverChallenges",
    label = _tr(CHALLENGES_LABEL),
    tiles = {},
  }
  local order = 0

  for _, section in ipairs(page.sections or {}) do
    for _, card in ipairs(section.cards or {}) do
      order = order + 1
      local group = card.type == "mission" and challenges or experiences
      table.insert(group.tiles, buildCardTile(card, order))
    end
  end

  local groups = {}
  if #experiences.tiles > 0 then
    table.insert(groups, experiences)
  end
  if #challenges.tiles > 0 then
    table.insert(groups, challenges)
  end
  return groups
end

local function onGameplaySelectorGetTiles(items, backend)
  if backend.backendName ~= "gameplaySelector" then
    return
  end

  for index, page in ipairs(getDiscoverPages()) do
    if not page.showMultiseatControllers and getCardCount(page) > 0 then
      table.insert(items, buildPageTile(page, index))
    end
  end
end

local function getTags(card)
  local tags = {}
  for _, tag in ipairs(card.tagList or {}) do
    local tagCopy = deepcopy(tag)
    tagCopy.label = translate(tagCopy.label)
    table.insert(tags, tagCopy)
  end
  return tags
end

local function onGameplaySelectorGetDetails(itemDetails, details, buttonInstance, backend)
  if not itemDetails.discoverId then
    return
  end

  local card = findCard(itemDetails.discoverId)
  if not card then
    return
  end

  local data = {
    headerTitle = translate(card.title or card.name),
    description = translate(card.description),
    preview = card.image,
    isFavourite = backend.isFavourite(itemDetails.key),
    specifications = {},
    tags = getTags(card),
    buttonInfo = {},
  }

  table.insert(data.buttonInfo, buttonInstance.addButton(function()
    backend.trackRecent(itemDetails.key)
    if card.preStartRoute then
      extensions.ui_router.navigate(card.preStartRoute)
    else
      gameplay_discover.startDiscover(itemDetails.discoverId)
    end
  end, {
    label = _tr("ui.playmodes.discover.play"),
    icon = "play",
    primary = true,
    isDoubleClickAction = true,
    waitForLoadingScreen = not card.preStartRoute,
  }))

  table.insert(details, data)
end

M.onGameplaySelectorGetTiles = onGameplaySelectorGetTiles
M.onGameplaySelectorGetDetails = onGameplaySelectorGetDetails

return M
