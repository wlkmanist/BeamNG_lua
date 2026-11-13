-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "ui_multiseat_multiseatConfiguration",
}

local lastDiscover = nil
local pendingExperienceLoadId = nil -- discover id whose next loadExt should bind onUnloaded
local navigateToPlayOnFadeout = false
local postLoadRoute = "play"
local discoversById = nil
local pageInfosById = {}
local PAGE_PLACEHOLDER_IMAGE = "/gameplay/discover/images/freeroamTBD.jpg"

local function luaPathToExtName(filepath)
  if string.sub(filepath, 1, 1) == "/" then
    filepath = string.sub(filepath, 2)
  end
  return (filepath:gsub("_", "__"):gsub("/", "_"))
end

local function getLoadedExtensionModule(extensionName)
  local extPath = extensionName
  if string.sub(extPath, 1, 1) == "/" then
    extPath = string.sub(extPath, 2)
  end
  local extName = luaPathToExtName(extPath)
  return rawget(_G, extName) or package.loaded[extPath] or package.loaded[extensionName]
end

local function enrichPageInfoMetadata(pageInfo)
  local folder = pageInfo and pageInfo.folder
  local isOfficial = folder and isOfficialContentVPath(folder) or false
  local mod = nil

  if folder and extensions.core_modmanager and extensions.core_modmanager.getModFromPath then
    mod = extensions.core_modmanager.getModFromPath(folder .. "/info.json", true)
  end

  pageInfo.isOfficial = isOfficial
  pageInfo.isMod = mod ~= nil

  if mod then
    pageInfo.modID = mod.modID
    pageInfo.modName = mod.modName or mod.modname
    pageInfo.modTitle = mod.modTitle or mod.modName or mod.modname
  else
    pageInfo.modID = nil
    pageInfo.modName = nil
    pageInfo.modTitle = isOfficial and "BeamNG.drive" or nil
  end
end

local function buildTagList(data)
  local tagList = {}

  if data and data.playerCount then
    table.insert(tagList, {
      icon = "helmets",
      label = string.format("From %d to %d players", data.playerCount.min or -1, data.playerCount.max or -1),
      playerCount = deepcopy(data.playerCount),
    })
  end

  if data and data.version then
    table.insert(tagList, {
      icon = "listSmall",
      label = core_locales.contextTranslate("ui.experiences.general.version", {version = tostring(data.version)})
    })
  end

  if data and data.duration then
    table.insert(tagList, {
      icon = "stopwatchSectionOutlinedStart",
      label = core_locales.contextTranslate("ui.experiences.general.timeTag", {time = tostring(data.duration)})
    })
  end

  if data.typeTag then
    local typeTag = deepcopy(data.typeTag)
    typeTag.label = core_locales.translateWithOrWithoutContext(typeTag.label)
    table.insert(tagList, typeTag)
  elseif data.type == "mission" then
    table.insert(tagList, {
      icon = "flag",
      label = _tr("ui.playmodes.mission")
    })
  elseif data.type == "freeroam" and not data.hideFreeroamTag then
    table.insert(tagList, {
      icon = "road",
      label = _tr("ui.playmodes.freeroam")
    })
  end

  if data and data.progressTag then
    table.insert(tagList, {
      icon = "bookOpened",
      label = data.progressTag.label,
    })
  end

  if data and data.isOfficial then
    table.insert(tagList, {icon = "beamNG", label = _tr("ui.menu.gridSelector.tags.beamngOfficial")})
  end

  if data and data.isMod and data.modTitle then
    local tag = {icon = "puzzleModule", label = data.modTitle}
    if data.modID then
      tag.goToMod = data.modID
    end
    table.insert(tagList, tag)
  end

  return tagList
end

--[[
-- use this to get the position, rotation and partConfig of all vehicles
for id in activeVehiclesIterator() do local veh = scenetree.findObjectById(id) print(veh) dump({veh:getPosition(), quatFromDir(veh:getDirectionVector(), veh:getDirectionVectorUp()), veh.jbeam, veh.partConfig}) end
]]
M.loadDiscovers = function()
  if discoversById then return end
  discoversById = {}
  local discoverFiles = FS:findFiles("/gameplay/discover/", "*.lua", -1, true, false)
  for _, file in ipairs(discoverFiles) do
    local dir, fn = path.splitWithoutExt(file)
    local discover = require(dir..fn)
    if discover then
      if discover.pageInfo then
        pageInfosById[fn] = discover.pageInfo
        pageInfosById[fn].folder = dir
        enrichPageInfoMetadata(pageInfosById[fn])
      end
      if discover.experiences then
        for _, experience in ipairs(discover.experiences) do
          discoversById[experience.id] = experience
        end
      end
      if discover.getProgressTag then
        local progressTag = discover.getProgressTag()
        if progressTag then
          pageInfosById[fn].progressTag = progressTag
        end
      end
    end
  end
end
M.onLanguageChanged = function() discoversById = nil end

local function formatDiscover(discover, pageInfo)
  if not discover then
    return nil
  end
  local discoverCopy = deepcopy(discover)
  discoverCopy.discoverId = discover.id
  discoverCopy.icon = discoverCopy.icon or "road"
  if not discoverCopy.title and discoverCopy.name then
    discoverCopy.title = discoverCopy.name
  end
  if discover.type == "mission" and not discoverCopy.title then
    local mission = gameplay_missions_missions.getMissionById(discoverCopy.missionId)
    if mission then
      discoverCopy.title = mission.name
      discoverCopy.description = mission.description
      discoverCopy.image = mission.previewFile
      discoverCopy.icon = mission.iconFontIcon
    else
      log("W", "discover", "Mission not found for discover '" .. tostring(discover.id) .. "' (missionId: " .. tostring(discoverCopy.missionId) .. ")")
    end
  end

  if discoverCopy.type == "mission" then
    -- todo: get this data without loading mission
    --local mission = gameplay_missions_missions.getMissionById(discoverCopy.missionId)
    if mission then
      discoverCopy.isOfficial = mission.official or (mission.missionFolder and isOfficialContentVPath(mission.missionFolder)) or false
      discoverCopy.modID = mission.modID
      discoverCopy.modName = mission.modName
      discoverCopy.modTitle = mission.modTitle or mission.modName
      discoverCopy.isMod = discoverCopy.modID ~= nil
    else
      discoverCopy.isOfficial = isOfficialContentVPath("/gameplay/missions/"..discoverCopy.missionId) or false
      discoverCopy.isMod = false
      discoverCopy.modID = nil
      discoverCopy.modName = nil
      discoverCopy.modTitle = nil
    end
  else
    discoverCopy.isOfficial = pageInfo.isOfficial or false
    discoverCopy.isMod = pageInfo.isMod or false
    discoverCopy.modID = pageInfo.modID
    discoverCopy.modName = pageInfo.modName
    discoverCopy.modTitle = pageInfo.modTitle
  end
  if not discoverCopy.image then
    discoverCopy.image = discover.type == "mission" and ("/gameplay/missions/"..discoverCopy.missionId.."/preview.jpg")
  end

  if discoverCopy.type == "freeroam" and discoverCopy.image and not string.startswith(discoverCopy.image, "/") then
    discoverCopy.image = pageInfo.folder.."/"..discoverCopy.image
  end
  if not discoverCopy.image or not FS:fileExists(discoverCopy.image) then
    discoverCopy.image = "/gameplay/discover/images/freeroamTBD.jpg"
  end
  discoverCopy.tagList = buildTagList(discoverCopy)
  return discoverCopy
end

local function getDiscoverPages()
  M.loadDiscovers()
  local pages = {}
  for pageId, pageInfo in pairs(pageInfosById) do
    local page = deepcopy(pageInfo)
    if type(page.description) == "table" then
      page.title = page.title or page.description.title
      page.image = page.image or page.description.image
      page.description = page.description.description
    end
    page.sections = {}
    page.pageKind = pageInfo.pageKind or "minor"
    page.date = pageInfo.date or 0
    page.version = pageInfo.version
    page.duration = pageInfo.duration
    page.isOfficial = pageInfo.isOfficial or false
    page.isMod = pageInfo.isMod or false
    page.modID = pageInfo.modID
    page.modName = pageInfo.modName
    page.modTitle = pageInfo.modTitle
    page.tagList = deepcopy(pageInfo.tagList or {})
    page.showMultiseatControllers = pageInfo.showMultiseatControllers or false
    local autoTagList = buildTagList(page)
    for _, tag in ipairs(autoTagList) do
      table.insert(page.tagList, tag)
    end
    local firstMajorImage = nil
    local firstMinorImage = nil
    for _, section in ipairs(pageInfo.sections) do
      local sectionCopy = deepcopy(section)
      sectionCopy.sectionKind = sectionCopy.sectionKind or "minor"
      sectionCopy.cards = {}
      for _, discoverId in ipairs(section.discoverIds) do
        local discover = discoversById[discoverId]
        local card = formatDiscover(discover, pageInfo)
        if card then
          table.insert(sectionCopy.cards, card)
          if not firstMajorImage and sectionCopy.sectionKind == "major" and card.image then
            firstMajorImage = card.image
          end
          if not firstMinorImage and sectionCopy.sectionKind == "minor" and card.image then
            firstMinorImage = card.image
          end
        else
          log("W", "discover", "Unknown discoverId '" .. tostring(discoverId) .. "' in page '" .. tostring(pageId) .. "'")
        end
      end
      table.insert(page.sections, sectionCopy)
    end
    if not page.image then
      page.image = firstMajorImage or firstMinorImage
    end
    if page.image and not string.startswith(page.image, "/") then
      page.image = pageInfo.folder.."/"..page.image
    end
    if page.image and not FS:fileExists(page.image) then
      page.image = PAGE_PLACEHOLDER_IMAGE
    end
    if not page.image then
      page.image = PAGE_PLACEHOLDER_IMAGE
    end
    table.insert(pages, page)
  end
  table.sort(pages, function(a, b)
    local dateA = a.date or 0
    local dateB = b.date or 0
    if dateA ~= dateB then return dateA > dateB end
    return (a.sortBias or 0) > (b.sortBias or 0)
  end)
  return pages
end

local function startDiscover(discoverId)
  M.loadDiscovers()
  if lastDiscover then
    log("W", "discover", "Already loading discover: " .. lastDiscover..", ignoring: " .. discoverId)
    return
  end
  local discover = discoversById[discoverId]
  if not discover then
    log("W", "discover", "Unknown discover id: " .. tostring(discoverId))
    return
  end
  local splitscreenSetup
  if discover.playerCount then
    splitscreenSetup = require("gameplay/discover/multiseat/splitscreen")
    if not splitscreenSetup.canStartWithOptIns(discover.playerCount.min, discover.playerCount.max, discover.playerCount.softMax) then
      log("W", "discover", "Invalid splitscreen player configuration for: " .. tostring(discoverId))
      return false
    end
    local committed, reason = splitscreenSetup.commitMenuSetup()
    if not committed then
      log("W", "discover", "Could not apply splitscreen player configuration: " .. tostring(reason))
      return false
    end
  end
  lastDiscover = discoverId
  postLoadRoute = discover.playRoute or "play"
  if discover.missionId then
    local mission = gameplay_missions_missions.getMissionById(discover.missionId)
    if not mission then
      log("E", "discover", "Mission not found for discover '" .. tostring(discoverId) .. "' (missionId: " .. tostring(discover.missionId) .. ")")
      lastDiscover = nil
      postLoadRoute = "play"
      return
    end
    log('I', 'discover', 'Starting discover mission: ' .. discoverId)
    navigateToPlayOnFadeout = true
    local started = gameplay_missions_missionManager.startWithLoadingLevel(mission, nil, nil, "discover")
    if started then
      navigateToPlayOnFadeout = false
      postLoadRoute = "play"
      lastDiscover = nil
    end
  elseif type(discover.trigger) == "function" then
    log('I', 'discover', 'Starting discover: ' .. discoverId)
    navigateToPlayOnFadeout = true
    pendingExperienceLoadId = discoverId
    local started = discover.trigger(M)
    pendingExperienceLoadId = nil
    if started == false then
      if splitscreenSetup then splitscreenSetup.rollbackMenuSetup() end
      navigateToPlayOnFadeout = false
      postLoadRoute = "play"
      lastDiscover = nil
    else
      if splitscreenSetup then splitscreenSetup.completeMenuSetup() end
      if type(discover.onLoaded) == "function" then discover.onLoaded(M) end
    end
  else
    if splitscreenSetup then splitscreenSetup.rollbackMenuSetup() end
    log("E", "discover", "Discover '" .. tostring(discoverId) .. "' has no trigger function")
    lastDiscover = nil
    postLoadRoute = "play"
  end
end

local function navigateToPostLoadRoute()
  lastDiscover = nil
  if not navigateToPlayOnFadeout then
    return false
  end
  navigateToPlayOnFadeout = false
  local targetRoute = postLoadRoute
  postLoadRoute = "play"
  if gameplay_missions_missionScreen and gameplay_missions_missionScreen.isMissionStartOrEndScreenActive() then
    return false
  end
  extensions.ui_router.navigate(targetRoute)
  return true
end

M.navigateToPostLoadRoute = navigateToPostLoadRoute
M.onLoadingScreenFadeout = navigateToPostLoadRoute

local clearTasksOnClientEndMission = false
M.clearTasksOnClientEndMission = function()
  clearTasksOnClientEndMission = true
end

local loadedExtensions = {}

M.onClientEndMission = function()
  if lastDiscover == nil then
    navigateToPlayOnFadeout = false
    postLoadRoute = "play"
  end
  if clearTasksOnClientEndMission then
    guihooks.trigger('ClearTasklist')
    clearTasksOnClientEndMission = false
  end
end

M.loadExt = function(extensionName)
  if loadedExtensions[extensionName] then
    return
  end
  extensions.load(extensionName)
  loadedExtensions[extensionName] = true

  local discoverId = pendingExperienceLoadId
  local discover = discoverId and discoversById[discoverId]
  if not discover or type(discover.onUnloaded) ~= "function" then
    return
  end

  local extModule = getLoadedExtensionModule(extensionName)
  if not extModule then
    log("W", "discover", "Could not bind onUnloaded for '" .. tostring(extensionName) .. "'")
    return
  end

  local prevUnload = extModule.onExtensionUnloaded
  extModule.onExtensionUnloaded = function(...)
    if type(prevUnload) == "function" then
      prevUnload(...)
    end
    loadedExtensions[extensionName] = nil
    if type(discover.onUnloaded) == "function" then
      discover.onUnloaded(M)
    end
  end
end


-- can be started with -discover <discoverName>
-- -discover firstStart replays the first-launch onboarding popup in the main menu instead
local function onInit()
  setExtensionUnloadMode(M, "manual")
  local cmdArgs = Engine.getStartingArgs()
  for i, v in ipairs(cmdArgs) do
    if v == "-discover" then
      local discoverId = cmdArgs[i+1]
      if discoverId == "firstStart" then
        settings.setState({ onboardingPopupShown = false })
      else
        M.startDiscover(discoverId)
      end
    end
  end
end


local doneIntroPopups = {}
M.basicControlsIntroPopup = function()
  local deviceOrder = {"wheel","joystick","xinput","gamepad","mouse","keyboard"}
  local devices = {}
  for k, v in pairs(core_input_bindings.bindings) do
    if v.contents.devicetype and v.contents.imagePack then
      table.insert(devices, {device = v.contents.devicetype, imagePack = v.contents.imagePack})
    end
  end
  local function findIndex(arr, val)
    for i, v in ipairs(arr) do
      if v == val then return i end
    end
    return -1
  end
  table.sort(devices, function(a, b) return findIndex(deviceOrder, a.device) < findIndex(deviceOrder, b.device) end)
  table.insert(devices, {device = "fallback", imagePack = "fallback"})
  for i, v in ipairs(devices) do
    local popup = "basicDriving_"..v.imagePack
    if FS:fileExists("/gameplay/discover/popups/"..popup.."/content.json") then
      if not doneIntroPopups[popup] then
        M.introPopup(popup)
      end
      return
    else
      log("I","","Basic Driving Popup not found: "..popup)
    end
  end
end

M.introPopup = function(id)
  if doneIntroPopups[id] then
    return
  end
  local file = "/gameplay/discover/popups/"..id.."/content.json"
  if not FS:fileExists(file) then
    return
  end
  doneIntroPopups[id] = true
  M.loadExt("ui_popup")
  if not extensions.ui_popup then
    return
  end
  log("I","","Intro Popup: " .. id)
  extensions.ui_popup.openPopupById(id, {
    root = "/gameplay/discover/popups/",
  })
end


local SPLITSCREEN_PAGE_MODULE = "/gameplay/discover/multiseat/splitscreen"

local function getSplitscreenPageModule()
  M.loadDiscovers()
  local mod = package.loaded[SPLITSCREEN_PAGE_MODULE]
    or package.loaded["gameplay/discover/multiseat/splitscreen"]
  if mod then return mod end
  return require(SPLITSCREEN_PAGE_MODULE)
end

M.getSplitscreenPlayerOptIns = function()
  return getSplitscreenPageModule().getPlayerOptInState()
end

M.cycleSplitscreenDevicePlayer = function(deviceId, operation, direction)
  local splitscreen = getSplitscreenPageModule()
  if operation == "toggle" then return splitscreen.toggleDevicePlayer(deviceId) end
  if operation == "move" then return splitscreen.moveDevicePlayer(deviceId, direction) end
  return splitscreen.cycleDevicePlayer(deviceId)
end

M.setSplitscreenDevicePlayer = function(deviceId, personaNumber)
  return getSplitscreenPageModule().setDevicePlayer(deviceId, personaNumber)
end

M.joinSplitscreenDeviceGroup = function(groupId)
  return getSplitscreenPageModule().joinDeviceGroup(groupId)
end

M.setSplitscreenPlayerOptIn = function(player, optedIn)
  return getSplitscreenPageModule().setPlayerOptIn(player, optedIn)
end

M.getSplitscreenOptedInPlayers = function()
  return getSplitscreenPageModule().getOptedInPlayers()
end

M.canStartSplitscreenDiscover = function(minPlayers, maxPlayers)
  return getSplitscreenPageModule().canStartWithOptIns(minPlayers, maxPlayers)
end

M.leaveSplitscreenMenuSetup = function()
  return getSplitscreenPageModule().leaveMenuSetup()
end

M.getDiscoverPages = getDiscoverPages
M.onInit = onInit
M.startDiscover = startDiscover


return M
