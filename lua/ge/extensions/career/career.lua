-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local imgui = ui_imgui

M.dependencies = {'career_saveSystem', 'core_recoveryPrompt', 'gameplay_traffic'}

M.tutorialEnabled = false
M.startingOptions = {}

local pendingStartingOptions = nil
local startingModesDirectory = "/lua/ge/extensions/career/startingModes/"

local debugMenuEnabled = not shipping_build

local careerModuleDirectory = '/lua/ge/extensions/career/modules/'
local saveFile = "general.json"
local levelName = "west_coast_usa"
local autosaveEnabled = true

local careerActive = false
local careerModules = {}
local boughtStarterVehicle = false
local organizationInteraction = {}
local pendingInitAfterLevelLoad = nil

local devActions = {"dropPlayerAtCameraNoReset"}
arrayConcat(devActions, core_input_actionFilter.createActionTemplate({"editor", "uiReloading"}))

local nodegrabberActions = {"nodegrabberGrab", "nodegrabberRender", "nodegrabberStrength"}


local actionWhitelist = deepcopy(devActions)
arrayConcat(actionWhitelist, nodegrabberActions)
local blockedActions = core_input_actionFilter.createActionTemplate({"vehicleTeleporting", "vehicleMenues", "physicsControls", "aiControls", "vehicleSwitching", "funStuff"}, actionWhitelist)

-- TODO maybe save whenever we go into the esc menu

local function updateNodegrabberBlocking()
  -- enable node grabber only in walking mode
  if careerActive and (core_camera.getActiveGlobalCameraName() or not gameplay_walk.isWalking()) then
    core_input_actionFilter.setGroup('careerNodeGrabberActions', nodegrabberActions)
    core_input_actionFilter.addAction(0, 'careerNodeGrabberActions', true)
    be.nodeGrabber:onMouseButton(false)
    return
  end
  core_input_actionFilter.setGroup('careerNodeGrabberActions', nodegrabberActions)
  core_input_actionFilter.addAction(0, 'careerNodeGrabberActions', false)
end

local function blockInputActions(block)
  if shipping_build then
    core_input_actionFilter.setGroup('careerBlockedDevActions', devActions)
    core_input_actionFilter.addAction(0, 'careerBlockedDevActions', block)
  end

  core_input_actionFilter.setGroup('careerBlockedActions', blockedActions)
  core_input_actionFilter.addAction(0, 'careerBlockedActions', block)

  updateNodegrabberBlocking()
end

local function onCameraModeChanged(modeName)
  if not careerActive then return end
  updateNodegrabberBlocking()
end

local function onGlobalCameraSet(modeName)
  if not careerActive then return end
  updateNodegrabberBlocking()
end

local debugModules = {}
local function debugMenu()
  if not careerActive then return end
  local endCareerMode = false

  local debugSettings = settings.getValue('careerDebugSettings')
  imgui.SetNextWindowSize(imgui.ImVec2(300, 300), imgui.Cond_FirstUseEver)
  imgui.Begin("Career Debug (Save File: " .. career_saveSystem.getCurrentProfile() .. ")###Career Debug", nil, imgui.WindowFlags_MenuBar)
  imgui.BeginMenuBar()
  if imgui.BeginMenu("File") then
    local _, currentSavePath = career_saveSystem.getCurrentProfile()
    imgui.Text((string.sub(currentSavePath, string.len(career_saveSystem.getSaveRootDirectory())+2, -1)))
    imgui.Separator()
    if imgui.Selectable1("Save Career") then
      career_saveSystem.saveCurrent()
    end
    if imgui.Selectable1("Exit Career Mode") then
      endCareerMode = true
    end
    if imgui.Selectable1("Open Save Folder") then
      Engine.Platform.exploreFolder(currentSavePath:lower())
    end
    imgui.EndMenu()
  end
  if imgui.BeginMenu("Modules") then
    for _, mod in ipairs(debugModules) do
      local active = debugSettings[mod.debugName] or false
      if mod.drawDebugMenu then
        if imgui.Checkbox(mod.debugName, imgui.BoolPtr(active)) then
          debugSettings[mod.debugName] = not active
          settings.setValue('careerDebugSettings', debugSettings)
        end
      end
    end
    imgui.EndMenu()
  end

  if imgui.BeginMenu("Functions") then
    for _, mod in ipairs(careerModules) do
      if extensions[mod].drawDebugFunctions then
        imgui.Text(extensions[mod].debugName or extensions[mod].__extensionName__)
        extensions[mod].drawDebugFunctions()
        imgui.Separator()
      end
    end
    imgui.EndMenu()
  end

  imgui.EndMenuBar()
  for _, mod in ipairs(debugModules) do
    local active = debugSettings[mod.debugName] or false
    if mod.drawDebugMenu and active then
      mod.drawDebugMenu(dt)
      imgui.Separator()
    end
  end
  imgui.End()

  if endCareerMode then
    M.deactivateCareer()
    return true
  end
end

local function setupCareerActionsAndUnpause()
  blockInputActions(true)
  simTimeAuthority.pause(false)
  simTimeAuthority.set(1)
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not careerActive then return end
  if debugMenuEnabled then
    if debugMenu() then
      return
    end
  end
end

local function onCareerActive(active)
  if not active then return end
  if M.tutorialEnabled then
    core_recoveryPrompt.setDefaultsForTutorial()
  else
    core_recoveryPrompt.setDefaultsForCareer()
  end
  guihooks.trigger('ClearTasklist')
  M.onUpdate = onUpdate
  gameplay_rawPois.clear()
  setupCareerActionsAndUnpause()
  core_gamestate.setGameState("career","career", nil)
end


local skipModuleFolders = {"/tutorial/step"}

local function toggleCareerModules(active)
  if active then
    table.clear(careerModules)
    local extensionFiles = {}
    local files = FS:findFiles(careerModuleDirectory, '*.lua', -1, true, false)
    for i = 1, tableSize(files) do
      extensions.luaPathToExtName(modulePath)
      local extensionFile = string.gsub(files[i], "/lua/ge/extensions/", "")
      extensionFile = string.gsub(extensionFile, ".lua", "")
      local skip = false
      for _, folder in ipairs(skipModuleFolders) do
        if string.find(extensionFile, folder) then
          skip = true
          break
        end
      end
      if skip then goto continue end
      table.insert(extensionFiles, extensionFile)
      table.insert(careerModules, extensions.luaPathToExtName(extensionFile))
      ::continue::
    end
    extensions.load(careerModules)
    extensions.disableSerialization(careerModules)

    -- prevent these extensions from being unloaded when switching level
    for _, extension in ipairs(extensionFiles) do
      setExtensionUnloadMode(extensions.luaPathToExtName(extension), "manual")
    end

    for _, moduleName in ipairs(careerModules) do
      if extensions[moduleName].onCareerActivated then
        extensions[moduleName].onCareerActivated()
      end
    end

    debugModules = {}
    for _, moduleName in ipairs(careerModules) do
      if extensions[moduleName].debugName then
        table.insert(debugModules,extensions[moduleName])
      end
    end
    table.sort(debugModules, function(a,b) return a.debugOrder < b.debugOrder end)
  else
    for _, name in ipairs(careerModules) do
      extensions.unload(name)
    end
    table.clear(careerModules)
  end
end

local function removeNonTrafficVehicles()
  local safeIds = gameplay_traffic.getTrafficList(true)
  safeIds = arrayConcat(safeIds, gameplay_parking.getParkedCarsList(true))
  for i = be:getObjectCount()-1, 0, -1 do
    local objId = be:getObject(i):getID()
    if not tableContains(safeIds, objId) then
      be:getObject(i):delete()
    end
  end
end

local function initAfterLevelLoad(newSave)
  extensions.hook("onCareerActive", true, newSave)
end

local function onClientPostStartMission()
  if not pendingInitAfterLevelLoad then return end
  local newSave = pendingInitAfterLevelLoad.newSave
  pendingInitAfterLevelLoad = nil
  initAfterLevelLoad(newSave)
end

local function activateCareer(removeVehicles)
  if careerActive then return end
  -- load career
  local profile, savePath = career_saveSystem.getCurrentProfile()
  if not profile then return end
  core_gamestate.requestEnterLoadingScreen('careerActivate')
  extensions.hook("onBeforeCareerActivate")
  if removeVehicles == nil then
    removeVehicles = true
  end
  if core_groundMarkers then core_groundMarkers.setPath(nil) end

  careerActive = true
  log("I", "Loading career from " .. savePath .. "/career/" .. saveFile)
  local careerData = (savePath and jsonReadFile(savePath .. "/career/" .. saveFile)) or {}
  local newSave = tableIsEmpty(careerData)
  local savedStartingOptions = (type(careerData.startingOptions) == "table") and careerData.startingOptions or {}
  if newSave and type(pendingStartingOptions) == "table" then
    M.startingOptions = deepcopy(pendingStartingOptions)
  else
    M.startingOptions = deepcopy(savedStartingOptions)
  end
  M.tutorialEnabled = M.startingOptions.startMode == "apmOnboarding" and not careerData.boughtStarterVehicle
  if M.tutorialEnabled then
    log("I","","Tutorial for career enabled.")
    M.setAutosaveEnabled(false)
  end
  pendingStartingOptions = nil
  local levelToLoad = careerData.level or levelName
  boughtStarterVehicle = careerData.boughtStarterVehicle
  organizationInteraction = careerData.organizationInteraction or {}
  pendingInitAfterLevelLoad = nil

  if not getCurrentLevelIdentifier() or (getCurrentLevelIdentifier() ~= levelToLoad) then
    spawn.preventPlayerSpawning = true
    freeroam_freeroam.resetSpawningOptions()
    freeroam_freeroam.spawningOptionsHelper.trafficMode = "disabled" -- career_playerDriving will manage traffic setup
    freeroam_freeroam.startFreeroam(path.getPathLevelMain(levelToLoad), nil, false, nil, function()
      toggleCareerModules(true)
      M.closeAllMenus()
      core_gamestate.requestExitLoadingScreen('careerActivate')
      pendingInitAfterLevelLoad = { newSave = newSave }
      server.fadeoutLoadingScreen()
    end)
  else
    if removeVehicles then
      core_vehicles.removeAll()
    else
      removeNonTrafficVehicles()
    end
    toggleCareerModules(true)
    M.closeAllMenus()
    initAfterLevelLoad(newSave)
    core_gamestate.requestExitLoadingScreen('careerActivate')
  end
end

local function deactivateCareer(saveCareer)
  if not careerActive then return end
  M.onUpdate = nil
  careerActive = false
  toggleCareerModules(false)
  blockInputActions(false)
  gameplay_rawPois.clear()
  core_recoveryPrompt.setDefaultsForFreeroam()
  extensions.hook("onCareerActive", false)
  guihooks.trigger("HideCareerTasklist")
end

local function deactivateCareerAndReloadLevel(saveCareer)
  if not careerActive then return end
  deactivateCareer(saveCareer)
  freeroam_freeroam.startFreeroam(path.getPathLevelMain(getCurrentLevelIdentifier()))
end

local function isActive()
  return careerActive
end

local function createOrLoadCareerAndStart(name, specificAutosave, startingOptions)
  log("I","",string.format("Create or Load Career: %s - %s", name, specificAutosave))
  if career_saveSystem.setProfile(name, specificAutosave) then
    local parsedOptions = {}
    if type(startingOptions) == "table" then
      parsedOptions = deepcopy(startingOptions)
    end

    pendingStartingOptions = parsedOptions
    M.startingOptions = deepcopy(parsedOptions)

    activateCareer()
    return true
  end
  return false
end

local function getStartingModeOptions()
  local function sanitizeStartingModeForUi(modeData)
    return {
      id = modeData.id,
      order = modeData.order,
      tier = modeData.tier,
      title = modeData.title,
      description = modeData.description,
      image = modeData.image,
      tag = modeData.tag,
    }
  end

  local options = {}
  local files = FS:findFiles(startingModesDirectory, "*.lua", -1, true, false)

  table.sort(files)

  for _, filePath in ipairs(files) do
    local loadedOk, modeData = pcall(dofile, filePath)
    if loadedOk and type(modeData) == "table" and modeData.id and not modeData.ignore then
      table.insert(options, sanitizeStartingModeForUi(modeData))
    else
      log("W", "career.startingModes", string.format("Unable to load starting mode from '%s'", tostring(filePath)))
    end
  end

  table.sort(options, function(a, b)
    local ao = tonumber(a.order) or math.huge
    local bo = tonumber(b.order) or math.huge
    if ao ~= bo then
      return ao < bo
    end
    return tostring(a.id) < tostring(b.id)
  end)

  return deepcopy(options)
end

local function getCurrentStartingModeData()
  local startModeId = M.startingOptions and M.startingOptions.startMode
  if type(startModeId) ~= "string" then
    return nil
  end

  local files = FS:findFiles(startingModesDirectory, "*.lua", -1, true, false)
  table.sort(files)

  for _, filePath in ipairs(files) do
    local loadedOk, modeData = pcall(dofile, filePath)
    if loadedOk and type(modeData) == "table" and modeData.id == startModeId and not modeData.ignore then
      return modeData
    end
  end

  return nil
end

local function onSaveCurrentProfile(currentSavePath)
  if not careerActive then return end

  local filePath = currentSavePath .. "/career/" .. saveFile
  -- read the info file
  local data = {}

  data.level = getCurrentLevelIdentifier()
  data.startingOptions = deepcopy(M.startingOptions or {})
  data.boughtStarterVehicle = boughtStarterVehicle
  data.debugModuleOpenStates = {}
  data.organizationInteraction = organizationInteraction or {}
  for _, module in ipairs(debugModules) do
    if module.getDebugMenuActive then
      data.debugModuleOpenStates[module.___extensionName___] = module.getDebugMenuActive()
    end
  end

  career_saveSystem.jsonWriteFileSafe(filePath, data, true)
end

local function onBeforeSetProfile(currentSavePath)
  if isActive() then
    deactivateCareer()
  end
end

local beamXPLevels ={
    {requiredValue = 0}, -- to reach lvl 1
    {requiredValue = 100},-- to reach lvl 2
    {requiredValue = 300},-- to reach lvl 3
    {requiredValue = 600},-- to reach lvl 4
    {requiredValue = 1000},-- to reach lvl 5
}
local function getBeamXPLevel(xp)
  local level = -1
  local neededForNext = -1
  local curLvlProgress = -1
  for i, lvl in ipairs(beamXPLevels) do
    if xp >= lvl.requiredValue then
      level = i
    end
  end
  if beamXPLevels[level+1] then
    neededForNext = beamXPLevels[level+1].requiredValue
    curLvlProgress = xp - beamXPLevels[level].requiredValue
  end
  return level, curLvlProgress, neededForNext
end

local function formatProfileForUi(profile)
  local data = {}
  data.id = profile

  local autosavePath = career_saveSystem.getNewestSave(career_saveSystem.getSaveRootDirectory() .. profile)
  local infoData = jsonReadFile(autosavePath .. "/info.json")
  local vehiclePath = autosavePath .. "/career/vehicles/"
  local generalData = jsonReadFile(autosavePath .. "/career/general.json")

  local currentProfile, _ = career_saveSystem.getCurrentProfile()
  if career_career.isActive() and currentProfile == profile then

    -- current save slot
    data.tutorialActive = career_modules_tutorial.isActive()
    data.money = career_modules_playerAttributes.getAttribute("money")
    data.beamXP = career_modules_playerAttributes.getAttribute("beamXP")
    data.vouchers = career_modules_playerAttributes.getAttribute("vouchers")
    data.insuranceScore = {value = career_modules_insurance_insurance.getDriverScore()}
    data.beamXP.level, data.beamXP.curLvlProgress, data.beamXP.neededForNext = getBeamXPLevel(data.beamXP.value)
    data.branches = {}

    for _, br in ipairs(career_branches.getSortedBranches()) do
      if br.isBranch and br.parentDomain == "apm" then
        local attKey = br.attributeKey
        local brData = deepcopy(career_modules_playerAttributes.getAttribute(attKey) or {value=br.defaultValue or 0})
        brData.level, brData.curLvlProgress, brData.neededForNext = career_branches.calcBranchLevelFromValue(brData.value, br.id)
        brData.id = attKey
        brData.icon = br.icon
        brData.color = br.color
        brData.label = br.name
        brData.levelLabel = {txt='ui.career.lvlLabel', context={lvl=brData.level}}
        table.insert(data.branches, brData)
        -- remove this assigment once UI side works with the new branch list
        data[attKey] = brData
      end
    end
    data.currentVehicle = career_modules_inventory.getCurrentVehicle() and deepcopy(career_modules_inventory.getVehicles()[career_modules_inventory.getCurrentVehicle()])
    if data.currentVehicle then
      data.currentVehicle.niceName = career_modules_inventory.getVehicleNiceNameTranslated(career_modules_inventory.getCurrentVehicle())
    end

    data.vehicleCount = #career_modules_inventory.getVehicles()
  else
    -- save slot from file
    local attData = jsonReadFile(autosavePath .. "/career/playerAttributes.json")
    local inventoryData = jsonReadFile(autosavePath .. "/career/inventory.json")
    local insuranceData = jsonReadFile(autosavePath .. "/career/insurance.json")

    if attData then
      data.money = deepcopy(attData.money) or {value=0}
      data.beamXP = deepcopy(attData.beamXP) or {value=0}
      data.vouchers = deepcopy(attData.vouchers) or {value=0}
      if insuranceData and insuranceData.plDriverScore then
        data.insuranceScore = {value = insuranceData.plDriverScore}
      else
        data.insuranceScore = {value = 0}
      end
      data.beamXP.level, data.beamXP.curLvlProgress, data.beamXP.neededForNext = getBeamXPLevel(data.beamXP.value)
      data.branches = {}
      for _, br in ipairs(career_branches.getSortedBranches()) do
        if br.isBranch and br.parentDomain == "apm" then
          local attKey = br.attributeKey
          local newAttKey = career_branches.newAttributeNamesToOldNames[attKey] or attKey
          local brData = deepcopy(attData[newAttKey] or attData[attKey] or {value=br.defaultValue or 0})
          brData.level, brData.curLvlProgress, brData.neededForNext = career_branches.calcBranchLevelFromValue(brData.value, br.id)
          brData.id = attKey
          brData.icon = br.icon
          brData.color = br.color
          brData.label = br.name
          brData.levelLabel = {txt='ui.career.lvlLabel', context={lvl=brData.level}}

          table.insert(data.branches, brData)
          -- remove this assigment once UI side works with the new branch list
          data[attKey] = brData
        end
      end
    end

    if inventoryData and inventoryData.currentVehicle then
      local vehicleData = jsonReadFile(autosavePath .. "/career/vehicles/" .. inventoryData.currentVehicle .. ".json")
      if vehicleData then
        data.currentVehicle = vehicleData.niceName
      end

    end
    local files = FS:findFiles(vehiclePath, '*.json', 0, false, false)
    data.vehicleCount = #files
  end
  if generalData then
    data.boughtStarterVehicle = generalData.boughtStarterVehicle
    data.startingOptions = generalData.startingOptions or {}
  end
  -- add the infoData raw
  if infoData and infoData.version then
    infoData.incompatibleVersion = career_saveSystem.getBackwardsCompVersion() > infoData.version
    infoData.outdatedVersion = career_saveSystem.getSaveSystemVersion() > infoData.version
    tableMerge(data, infoData)
  end

  return data
end

local function sendAllCareerProfilesData()
  local res = {}
  local allProfiles = career_saveSystem.getAllProfiles()
  if util_asyncBulkLoader and util_asyncBulkLoader.isLoading() then
    util_asyncBulkLoader.addTotal(#allProfiles)
  end
  for _, profile in ipairs(allProfiles) do
    local profileData = formatProfileForUi(profile)
    if util_asyncBulkLoader and util_asyncBulkLoader.isLoading() then
      util_asyncBulkLoader.addCount(1)
      util_asyncBulkLoader.yield("sendAllCareerProfilesData " .. profile)
    end
    if profileData then
      table.insert(res, profileData)
    end
  end

  table.sort(res, function(a,b) return (a.creationDate or "Z") < (b.creationDate or "Z") end)
  guihooks.trigger("allCareerProfiles", res)
  return res
end

local function sendCurrentProfileData()
  if not careerActive then return end
  local profile = career_saveSystem.getCurrentProfile()
  if profile then
    return formatProfileForUi(profile)
  end
end

local function getAutosavesForProfile(profile)
  local res = {}
  for _, saveData in ipairs(career_saveSystem.getAllSaveFolders(profile)) do
    local data = jsonReadFile(career_saveSystem.getSaveRootDirectory() .. profile .. "/" .. saveData.name .. "/career/playerAttributes.json")
    if data then
      data.id = profile
      data.autosaveName = saveData.name
      table.insert(res, data)
    end
  end
  return res
end

-- Returns the list of save folders (autosaves) for a profile with enough info
-- for the UI to display and let the player pick one to load.
local function getSaveFoldersForProfile(profile)
  local res = {}
  if not profile then return res end
  local saveRootDir = career_saveSystem.getSaveRootDirectory()
  local curProfile, curSavePath = career_saveSystem.getCurrentProfile()
  local curFolderName = curSavePath and string.match(curSavePath, "([^/\\]+)$") or nil
  for _, saveData in ipairs(career_saveSystem.getAllSaveFolders(profile)) do
    local folderPath = saveRootDir .. profile .. "/" .. saveData.name
    local entry = {
      id = profile,
      name = saveData.name,
      date = saveData.date,
      creationDate = saveData.creationDate,
      displayName = saveData.displayName or profile,
      corrupted = saveData.corrupted and true or false,
      version = saveData.version,
      isCurrent = (curProfile == profile and curFolderName == saveData.name) or false,
    }
    if saveData.version then
      entry.incompatibleVersion = career_saveSystem.getBackwardsCompVersion() > saveData.version
      entry.outdatedVersion = career_saveSystem.getSaveSystemVersion() > saveData.version
    end

    local attData = jsonReadFile(folderPath .. "/career/playerAttributes.json")
    if attData then
      entry.money = attData.money or {value = 0}
      entry.beamXP = attData.beamXP or {value = 0}
    end

    local vehicleFiles = FS:findFiles(folderPath .. "/career/vehicles/", '*.json', 0, false, false)
    entry.vehicleCount = #vehicleFiles

    table.insert(res, entry)
  end

  -- newest first
  table.sort(res, function(a, b) return (a.date or "0") > (b.date or "0") end)
  return res
end

local function onClientEndMission(levelPath)
  if not careerActive then return end
  local levelNameToLoad = path.levelFromPath(levelPath)
  if levelNameToLoad == levelName then
    deactivateCareer()
  end
end

local function onSerialize()
  local data = {}
  if careerActive then
    data.reactivate = true
    deactivateCareer()
  end
  return data
end

local function onDeserialized(v)
  if v.reactivate then
    activateCareer(false)
  end
end

local function onAnyMissionChanged(state, mission)
  if not careerActive then return end
  if mission then
    if state == "stopped" then
      blockInputActions(true)
    elseif state == "started" then
      blockInputActions(false)
    end
  end
end

local function hasBoughtStarterVehicle()
  return boughtStarterVehicle
end

local function hasInteractedWithOrganization(id)
  return organizationInteraction[id]
end

local function interactWithOrganization(id)
  --print("Interact with: " .. dumps(id))
  organizationInteraction[id] = true
end

local function onVehicleAddedToInventory(data)
  -- if data.vehicleInfo is present, then the vehicle was bought
  if data.purchaseData == nil then return end
  if not boughtStarterVehicle and data.vehicleInfo then
    boughtStarterVehicle = true
    gameplay_rawPois.clear()
    career_saveSystem.saveCurrent()
    --career_modules_vehicleShopping.updateVehicleList(true)
  end
  if data.purchaseData.purchaseType == "instant" and data.purchaseData.vehicleInfo.sellerId == "apmStarterVehicles" then
    gameplay_achievement.unlockAchievement("FIRST_SET_OF_KEYS")
  end
end

local function closeAllMenus()
  -- guihooks.trigger('ChangeState', {state = 'play', params = {}})
  extensions.ui_router.navigate("play")
end

local function isAutosaveEnabled()
  return autosaveEnabled
end

local function setAutosaveEnabled(enabled)
  autosaveEnabled = enabled
end

local function getAdditionalMenuButtons()
  local ret = {}
  --table.insert(ret, {label = "Test", luaFun = "print('Test!')"})
  if career_modules_delivery_general.isDeliveryModeActive() then
    table.insert(ret, {label = "Map (My Cargo)", luaFun = "career_modules_delivery_cargoScreen.enterMyCargo()"})
  else
    table.insert(ret, {label = "Map", luaFun = "freeroam_bigMapMode.enterBigMap({instant=true})"})
  end
  if not career_modules_tutorial.isActive() and M.hasBoughtStarterVehicle() then
    table.insert(ret, {label = "Progress", luaFun = "guihooks.trigger('ChangeState', {state = 'career.domainSelection'})", showIndicator = career_modules_milestones_milestones.unclaimedMilestonesCount() > 0})
  end
  if career_modules_vehiclePerformance.isTestInProgress() then
    table.insert(ret, {label = "Cancel Certification", luaFun = "career_modules_vehiclePerformance.cancelTest()", showIndicator = true})
  end

  if career_modules_testDrive.isActive() then
    table.insert(ret, {label = "Cancel Test Drive", luaFun = "career_modules_testDrive.stop()", showIndicator = true})
  end
  return ret
end

local function setDebugMenuEnabled(enabled)
  debugMenuEnabled = enabled
end

M.getAdditionalMenuButtons = getAdditionalMenuButtons

M.createOrLoadCareerAndStart = createOrLoadCareerAndStart
M.activateCareer = activateCareer
M.deactivateCareer = deactivateCareer
M.deactivateCareerAndReloadLevel = deactivateCareerAndReloadLevel
M.isActive = isActive
M.sendAllCareerProfilesData = sendAllCareerProfilesData
M.sendCurrentProfileData = sendCurrentProfileData
M.getAutosavesForProfile = getAutosavesForProfile
M.getSaveFoldersForProfile = getSaveFoldersForProfile
M.hasBoughtStarterVehicle = hasBoughtStarterVehicle
M.hasInteractedWithOrganization = hasInteractedWithOrganization
M.interactWithOrganization = interactWithOrganization
M.closeAllMenus = closeAllMenus
M.isAutosaveEnabled = isAutosaveEnabled
M.setAutosaveEnabled = setAutosaveEnabled
M.getBeamXPLevel = getBeamXPLevel
M.setDebugMenuEnabled = setDebugMenuEnabled

M.onSaveCurrentProfile = onSaveCurrentProfile
M.onBeforeSetProfile = onBeforeSetProfile
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onClientEndMission = onClientEndMission
M.onClientPostStartMission = onClientPostStartMission
M.onAnyMissionChanged = onAnyMissionChanged
M.onVehicleAddedToInventory = onVehicleAddedToInventory
M.onCameraModeChanged = onCameraModeChanged
M.onGlobalCameraSet = onGlobalCameraSet
M.onCareerActive = onCareerActive

M.getStartingModeOptions = getStartingModeOptions
M.getCurrentStartingModeData = getCurrentStartingModeData

return M
