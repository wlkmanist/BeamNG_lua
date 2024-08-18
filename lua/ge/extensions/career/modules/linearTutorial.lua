-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local im = ui_imgui

M.dependencies = {'career_career'}
M.tutorialEnabled = -1
M.bounceBigmapIcons = false

local debug_ignoreGlobalSaveData = false
local debug_alwaysShowAllPopups = false

local tutorialsFolder ='/gameplay/tutorials/'
local saveFile = "/career/tutorialData.json"
local saveData
local globalSaveFile = "/settings/careerIntroPopups.json"
local globalSaveData

M.clearGlobalSaveData = function() globalSaveData = {} jsonWriteFile(globalSaveFile, globalSaveData, false) end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end
  -- load from saveslot
  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  saveData = (savePath and jsonReadFile(savePath .. saveFile)) or {}

  if debug_alwaysShowAllPopups then saveData = {} end

  if not next(saveData) then
    saveData = {
      linearStep = career_career.tutorialEnabled and 1 or -1,
      buyVehicleFlowgraphStarted = false,
      flags = {
        towToRoadEnabled = false,
        towToGarageEnabled = false,
        customTowHookEnabled = false,
        completedTutorialMission = false,
        arrivedAtFuelstation = false,
        arrivedAtGarage = false,
        purchasedFirstCar = false,
        partShoppingComplete = false,
        tuningComplete = false,
        modifiedFirstCar = false,
        spawnPointDiscoveryEnabled = false,
        earnedFirstStar = false,
      }
    }
    if career_career.vehSelectEnabled then

    end
  end
  if saveData.linearStep == -1 then
    for key, _ in pairs(saveData.flags) do
      saveData.flags[key] = true
    end
  end
  globalSaveData = jsonReadFile(globalSaveFile) or {}

  if debug_ignoreGlobalSaveData or debug_alwaysShowAllPopups then globalSaveData = {} end

end



M.endTutorial = function()
  saveData.linearStep = -1
  career_career.setAutosaveEnabled(true)
  career_saveSystem.saveCurrent()
  gameplay_rawPois.clear()
  core_recoveryPrompt.setDefaultsForCareer()
  career_modules_playerDriving.resetPlayerState()
  --core_gamestate.setGameState('freeroam', 'freeroam', 'freeroam') --  going into freeroam for now, until we unify gamestate across career to be "career"
  core_gamestate.setGameState("career","career", nil)
end

M.getCustomTowHookLabel = function() return "Custom Tow WIP" end

M.onClientStartMission = function()
  M.beginLinearStep(saveData.linearStep)
end
M.onCareerModulesActivated = function(alreadyInLevel)
  if alreadyInLevel then
    M.beginLinearStep(saveData.linearStep)
  end
end



local function beginLinearStep(step)
  if step == -1 then
    if career_career.hasBoughtStarterVehicle() then return end
    if not saveData.buyVehicleFlowgraphStarted then
      log("I","","Loading Vehicle buying Intro...")
      core_flowgraphManager.loadManager("gameplay/tutorials/buyVehicle.flow.json"):setRunning(true)
      saveData.buyVehicleFlowgraphStarted = true
    end
  end
  log("I","","Loading Linear Step " .. step)
  if step == 1 then
    core_flowgraphManager.loadManager("gameplay/tutorials/01-movementBasics.flow.json"):setRunning(true)
  end
  saveData.linearStep = step
  -- if tutorialData[step] then
  --   local fgPath = tutorialsFolder .. tutorialData[step].fgPath
  --   local mgr = core_flowgraphManager.loadManager(fgPath)
  --   mgr.transient = true
  --   mgr.name = "Step " .. step .. " Linear Tutorial"
  --   tutorialData[step].mgr = mgr
  --   mgr:setRunning(true)
  -- end
end

local function onExtensionUnloaded()
  -- if career is being stopped
  for _, mgr in ipairs(core_flowgraphManager.getAllManagers()) do
    if mgr._isCareerFlowgraph then
      log("I","","Stopping " .. mgr.name .. ", as it is a career FG.")
      -- stop all career-related FGs instantly
      mgr:setRunning(false, true)
    end
  end

end
M.onExtensionUnloaded = onExtensionUnloaded

local function completeLinearStep(nextStep)
  if saveData.linearStep == -1 then return end
  nextStep = nextStep or (saveData.linearStep+1)
  saveData.linearStep = nextStep
  extensions.hook("onLinearTutorialStepCompleted", step)
  beginLinearStep(nextStep)
end
local function getLinearStep()
  return saveData.linearStep
end
local function isLinearTutorialActive()
  return saveData.linearStep > 0
end
local function getTutorialFlag(key)
  return saveData.flags[key]
end
local function setTutorialFlag(key, value)
  saveData.flags[key] = value
end

-- dump(career_modules_linearTutorial.getTutorialData())
M.getTutorialData = function() return saveData end

-- this should only be loaded when the career is active
local function onSaveCurrentSaveSlot(currentSavePath)
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, saveData, true)
end


-- TODO: make sure this doesnt break in the future :D
M.setTrafficForTutorial = function()
  gameplay_parking.scatterParkedCars()
  gameplay_parking.setActiveAmount(0)
  gameplay_traffic.scatterTraffic()
  gameplay_traffic.setActiveAmount(career_modules_playerDriving.getPlayerData().trafficActive)

  for k, v in pairs(gameplay_traffic.getTrafficData()) do
    if v.role.name == "police" then
      local veh = be:getObjectByID(k)
      if veh then
        veh:setActive(0)
      end
      v.activeProbability = 0
    end
  end
end

M.setTrafficAfterTutorial = function()
  gameplay_parking.scatterParkedCars()
  gameplay_traffic.scatterTraffic()

  for k, v in pairs(gameplay_traffic.getTrafficData()) do
    if v.role.name == "police" then
      v.activeProbability = 0.15
    end
  end
end



-- creates a new intro popup from the content of the folder in ui/modules/introPopup/tutorial/ID/content.html
M.introPopup = function(id, force)
  if not force then
    if M.isLinearTutorialActive() then
      if M.getTutorialFlag(id) then return end
    else
      if globalSaveData[id] then return end
    end
  end

  M.setTutorialFlag(id, true)

  if not globalSaveData[id] then
    -- save global data manually
    globalSaveData[id] = true
    jsonWriteFile(globalSaveFile, globalSaveData, false)
  end

  if not FS:fileExists("ui/modules/introPopup/tutorial/"..id.."/content.html") then return end

  local content = readFile("ui/modules/introPopup/tutorial/"..id.."/content.html"):gsub("\r\n","")
  local entry = {
    type = "info",
    content = content,
    flavour = "onlyOk",
    isPopup = true,
  }
  guihooks.trigger("introPopupTutorial", {entry})

end

local introPopupTable = {
  -- triggered from 01 tutorial, when starting the tutorial

  showWelcomeSplashscreen = {"welcome"},

  addWalkingModeLogbookEntry = {},  -- No parameter for this function

  addCamerasLogbookEntry = {},  -- No parameter for this function

  -- triggered from 02 tutorial, right before driving the first time
  showBeforeDrivingSplashscreen = {"driving"},

  -- shown from 02 tutorial when crashing into the wall
  showCrashRecoverSplashScreen = {"crashRecover"},

  -- shown when opening bigmap the first time (part of 03 tutorial)
  onActivateBigMapCallback = {"bigmap"},

  -- shown when opening the refueling UI the first time (part of 04 tutorial)
  onRefuelingStartTransaction = {"refueling"},

  -- showne when opening the mission UI the first time (part of 04 tutorial)
  onAvailableMissionsSentToUi = {"missions"},

  -- shown after completing the mission in the tutorial
  showPostMissionSplash = {"postMission"},

  showTraversalSplashScreen = {},  -- No parameter for this function

  showBasicTutorialComplete = {},  -- No parameter for this function

  -- shown when dealership is opened the first time, or directly after the post-mission intropopup during tutorial
  onVehicleShoppingMenuOpened = {"dealership"},

  onVehicleBought = {},  -- No parameter for this function

  -- shown when interacting with the computer the first time, or when parking in the garage during tutorial.
  onComputerMenuOpened = {"computer"},

  -- shown when opening partshopping the first time
  onPartShoppingStarted = {"partShopping"},

  -- shown when opening parts tuning the first time
  onCareerTuningStarted = {"tuning"},

  -- shown when opening the garage the first time
  garageModeStartStep = {"garage"},

  -- shown at the end of the tutorial
  showLogbookSplash = {"logbook"},
  showTutorialOverSplash = {"finishing", "logbook","milestones","progress"},

  -- shown when opening the cargo screen for the first time
  onEnterCargoOverviewScreen = {"cargoScreen"},

  onComputerInsurance = {"insurance"},

  onVehiclePaintingUiOpened = {"vehiclePainting"},

}

-- this function is custom, because it needs to clear flags to make sure it always shows
M.showNonTutorialWelcomeSplashscreen = function()
  M.introPopup("welcomeNoTutorial", true)
  M.introPopup("logbookNoTutorial", true)
  M.introPopup("milestones", true)
  M.introPopup("progress", true)
end

for key, values in pairs(introPopupTable) do
  M[key] = function()
    for _, v in ipairs(values) do
      M.introPopup(v)
    end
  end
end

M.showAllSplashscreensAndLogbookEntries = function()
  for _, key in ipairs(M.allTutorialFlags) do saveData.flags[key] = false end
  globalSaveData = {}

  M.showNonTutorialWelcomeSplashscreen()
  for key, values in pairs(introPopupTable) do
    M[key]()
  end
end


local introPopupFiles = {
 {"/ui/modules/introPopup/tutorial/welcome/content.html"                 ,"Tutorial Start"},
 {"/ui/modules/introPopup/tutorial/driving/content.html"                 ,"Tutorial Driving"},
 {"/ui/modules/introPopup/tutorial/crashRecover/content.html"            ,"Tutorial Crashing"},
 {"/ui/modules/introPopup/tutorial/bigmap/content.html"                  ,"Tutorial Bigmap, Or when opening Bigmap"},
 {"/ui/modules/introPopup/tutorial/refueling/content.html"               ,"Tutorial Refuel, Or when opening Refueling screen"},
 {"/ui/modules/introPopup/tutorial/missions/content.html"                ,"Tutorial Missions, Or when opening Mission screen"},
 {"/ui/modules/introPopup/tutorial/postMission/content.html"             ,"Tutorial after Mission"},
 {"/ui/modules/introPopup/tutorial/dealership/content.html"              ,"Tutorial Dealership, or when opening Dealership Screen"},
 {"/ui/modules/introPopup/tutorial/computer/content.html"                ,"Tutorial Computer, or when opening Computer"},
 {"/ui/modules/introPopup/tutorial/partShopping/content.html"            ,"Tutorial Shopping, or when opening Shopping"},
 {"/ui/modules/introPopup/tutorial/finishing/content.html"               ,"Tutorial End 1"},
 {"/ui/modules/introPopup/tutorial/logbook/content.html"                 ,"Tutorial End 2"},
 {"/ui/modules/introPopup/tutorial/milestones/content.html"              ,"Tutorial End 3, Non-tutorial Start 3"},
 {"/ui/modules/introPopup/tutorial/progress/content.html"                ,"Tutorial End 4, Non-tutorial Start 4"},
  {},
 {"/ui/modules/introPopup/tutorial/welcomeNoTutorial/content.html"       ,"No-Tutorial Start 1"},
 {"/ui/modules/introPopup/tutorial/logbooknoTutorial/content.html"       ,"No-Tutorial Start 2"},
  {},
 {"/ui/modules/introPopup/tutorial/cargoScreen/content.html"             ,"Opening Cargo Screen for the first time"},
 {"/ui/modules/introPopup/tutorial/cargoDelivered/content.html"          ,"Delivered cargo for the first time"},
 {"/ui/modules/introPopup/tutorial/vehicleDeliveryUnlocked/content.html" ,"Vehicle Delivery System unlocked"},
 {"/ui/modules/introPopup/tutorial/trailerDeliveryUnlocked/content.html" ,"Trailer Delivery System unlocked"},
 {"/ui/modules/introPopup/tutorial/cargoContainerHowTo/content.html"     ,"How-To button on cargo screen"},
  {},
 {"/ui/modules/introPopup/tutorial/vehiclePainting/content.html"         ,"Opening Painting for the first time"},
 {"/ui/modules/introPopup/tutorial/tuning/content.html"                  ,"Opening Tuning menu for the first time"},
 {"/ui/modules/introPopup/tutorial/insurance/content.html"               ,"Opening Insurance Menu for the first time"},
}

M.drawDebugFunctions = function()
  if im.BeginMenu("> Intro Popups...") then
    if im.Selectable1("View All In Order") then
      for _,  file in ipairs(introPopupFiles) do
        if next(file) then
          local folder = file[1]:match(".-([^/]+)/[^/]+$")
          M.introPopup(folder, true)
        end
      end
    end
    im.Dummy(im.ImVec2(1,3))
    im.Separator()
    im.Dummy(im.ImVec2(1,3))
    for _,  file in ipairs(introPopupFiles) do
      if not next(file) then
        im.Dummy(im.ImVec2(1,3))
        im.Separator()
        im.Dummy(im.ImVec2(1,3))
      else
        local folder = file[1]:match(".-([^/]+)/[^/]+$")
        if im.Button("Edit##"..folder) then
          Engine.Platform.exploreFolder(file[1])
        end
        im.SameLine()
        if im.Selectable1("View " .. folder) then
          M.introPopup(folder, true)
        end
        im.tooltip(file[2])
      end
    end
    im.EndMenu()
  end
end


M.allTutorialFlags = {insuranceFlag, bigmapFlag, refuelFlag, missionFlag, dealershipFlag, inventoryFlag, computerFlag, partShoppingFlag, tuningFlag, garageFlag}

M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onExtensionLoaded = onExtensionLoaded
M.beginLinearStep = beginLinearStep
M.completeLinearStep = completeLinearStep
M.getLinearStep = getLinearStep
M.isLinearTutorialActive = isLinearTutorialActive
M.getTutorialFlag = getTutorialFlag
M.setTutorialFlag = setTutorialFlag
return M