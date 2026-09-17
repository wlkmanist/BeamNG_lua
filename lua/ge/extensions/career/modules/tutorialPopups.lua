-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local im = ui_imgui
local logTag = "tutorial_popups"

M.dependencies = {'ui_popup', 'gameplay_tutorial_damageTracker'}

local popupFlags = {}

local saveFile = "/career/tutorialData.json"

--==================================================
--MARK: Flags
-- Popup seen-flag state
--==================================================

local function setFlagsTable(flagsTable)
  popupFlags = flagsTable or {}
end

local function getTutorialFlag(key)
  return popupFlags[key]
end

local function setTutorialFlag(key, value)
  popupFlags[key] = value
end

M.wasIntroPopupsSeen = function(pages)
  for _, page in ipairs(pages or {}) do
    if not getTutorialFlag(page) then
      return false
    end
  end
  return true
end

local function onExtensionLoaded()
  local _, savePath = career_saveSystem.getCurrentProfile()
  local saveData = (savePath and jsonReadFile(savePath .. saveFile)) or {}
  popupFlags = saveData.flags or {}
end

local function onSaveCurrentProfile(currentSavePath)
  local saveData = {}
  saveData.flags = popupFlags
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, saveData, true)
end

--==================================================
--MARK: Damage
-- Damage popup queueing
--==================================================

local DAMAGED_VEHICLE_POPUP_ID = "v2/damagedVehicle"
local DAMAGED_VEHICLE_TIME_TRIAL_POPUP_ID = "v2/damagedVehicleTimeTrial"
local DAMAGED_VEHICLE_CAREER_POPUP_ID = "v2/damagedVehicleCareer"
local damagePopupClosed = true
local pendingPopupsAfterDamage = {}

local function showNextPendingAfterDamage()
  if #pendingPopupsAfterDamage == 0 then return end
  local nextPopup = table.remove(pendingPopupsAfterDamage, 1)
  M.introPopup(nextPopup.id, nextPopup.force)
end

-- Called when any tutorial popup is closed (from UI). Show damage popup first; once closed, show next queued popup.
function M.onIntroPopupCareerClosed(id)
  if id == DAMAGED_VEHICLE_POPUP_ID or id == DAMAGED_VEHICLE_TIME_TRIAL_POPUP_ID or id == DAMAGED_VEHICLE_CAREER_POPUP_ID then
    damagePopupClosed = true
  end
  showNextPendingAfterDamage()
end

--==================================================
--MARK: Opening
-- Popup opening helpers
--==================================================

M.introPopup = function(id, force)
  if not force and M.getTutorialFlag(id) then return end

  -- If this is a damage popup, mark it as open so other popups get queued until it's closed.
  if id == DAMAGED_VEHICLE_POPUP_ID or id == DAMAGED_VEHICLE_TIME_TRIAL_POPUP_ID or id == DAMAGED_VEHICLE_CAREER_POPUP_ID then
    damagePopupClosed = false
  elseif career_modules_tutorial.isActive()
      and gameplay_tutorial_damageTracker.getHadCrash()
      and not damagePopupClosed then
    -- Player has crashed and damage popup is not closed yet; queue this popup and show it after damage popup.
    table.insert(pendingPopupsAfterDamage, { id = id, force = force })
    return
  end

  M.setTutorialFlag(id, true)

  log("D", logTag, "Intro Popup: " .. id)
  extensions.ui_popup.openPopupById(id, {
    root = "/gameplay/tutorials/pages/",
  })
end

M.introPopupSequence = function(ids, force)
  if type(ids) ~= "table" or #ids == 0 then return end
  for _, id in ipairs(ids) do
    if force or not M.getTutorialFlag(id) then
      M.setTutorialFlag(id, true)
    end
  end
  log("D", logTag, "Intro Popup Sequence: " .. table.concat(ids, ", "))
  extensions.ui_popup.openPopupsByIds(ids, {
    root = "/gameplay/tutorials/pages/",
  })
end

--==================================================
--MARK: Legacy
-- Legacy popup hook mapping
--==================================================

local introPopupTable = {
  -- triggered from 01 tutorial, when starting the tutorial
  showWelcomeSplashscreen = {"welcome"},
  addWalkingModeLogbookEntry = {},
  addCamerasLogbookEntry = {},

  -- triggered from 02 tutorial, right before driving the first time
  showBeforeDrivingSplashscreen = {"driving"},

  -- shown from 02 tutorial when crashing into the wall
  showCrashRecoverSplashScreen = {"crashRecover"},

  -- shown when opening the refueling UI the first time (part of 04 tutorial)
  onRefuelingStartTransaction = {"refueling"},

  -- shown when opening the mission UI the first time (part of 04 tutorial)
  onAvailableMissionsSentToUi = {"missions"},

  -- shown after completing the mission in the tutorial
  showPostMissionSplash = {"postMission"},
  showTraversalSplashScreen = {},
  showBasicTutorialComplete = {},

  -- shown when dealership is opened the first time, or directly after the post-mission intro popup during tutorial
  --onVehicleShoppingMenuOpened = {"dealership"},
  onVehicleBought = {},

  -- shown when opening parts tuning the first time
  onCareerTuningStarted = {"tuning"},

  -- shown when opening the garage the first time
  garageModeStartStep = {"garage"},

  -- shown at the end of the tutorial
  showLogbookSplash = {"logbook"},
  showTutorialOverSplash = {"finishing", "logbook", "leagues", "performanceIndex"},

  -- shown when opening the cargo screen for the first time
  onEnterCargoOverviewScreen = {"delivery/cargoScreen"},
  onComputerInsurance = {"insurance"},
  onVehiclePaintingUiOpened = {"vehiclePainting"},
}

--==================================================
--MARK: Helpers
-- Legacy popup helper exports
--==================================================

M.showNonTutorialWelcomeSplashscreen = function()
  M.introPopup("welcomeNoTutorial", true)
  M.introPopup("leagues", true)
  M.introPopup("performanceIndex", true)
  M.introPopup("logbook", true)
end

for key, values in pairs(introPopupTable) do
  M[key] = function()
    for _, v in ipairs(values) do
      M.introPopup(v)
    end
  end
end

M.showAllSplashscreensAndLogbookEntries = function()
  for _, key in ipairs(M.allTutorialFlags) do
    popupFlags[key] = false
  end

  M.showNonTutorialWelcomeSplashscreen()
  for key, _ in pairs(introPopupTable) do
    M[key]()
  end
end

--==================================================
--MARK: Browser
-- Debug popup browser
--==================================================

local introPopupFiles = {
  {"welcome", "Tutorial Start"},
  {"driving", "Tutorial Driving"},
  {"crashRecover", "Tutorial Crashing"},
  {"bigmap", "Tutorial Bigmap, Or when opening Bigmap"},
  {"refueling", "Tutorial Refuel, Or when opening Refueling screen"},
  {"missions", "Tutorial Missions, Or when opening Mission screen"},
  {"postMission", "Tutorial after Mission"},
  {"dealership", "Tutorial Dealership, or when opening Dealership Screen"},
  {"computer", "Tutorial Computer, or when opening Computer"},
  {"partShopping", "Tutorial Shopping, or when opening Shopping"},
  {"finishing", "Tutorial End 1"},
  {"delivery/intro", "Tutorial End 2, No-Tutorial Start 2"},
  {"logbook", "Tutorial End 3, No-Tutorial Start 3"},
  {},
  {"welcomeNoTutorial", "No-Tutorial Start 1"},
  {"performanceIndex", "No-Tutorial Start 3"},
  {},
  {"delivery/cargoScreen", "Opening Cargo Screen for the first time"},
  {"delivery/parcelDeliveryHelp", "Parcel delivery help"},
  {"delivery/vehicleDeliveryHelp", "Vehicle delivery help"},
  {"delivery/trailerDeliveryHelp", "trailer delivery help"},
  {"delivery/materialsDeliveryHelp", "materials delivery help"},
  {"delivery/loanerHelp", "loaner help"},
  {},
  {"vehiclePainting", "Opening Painting for the first time"},
  {"tuning", "Opening Tuning menu for the first time"},
  {"insurance", "Opening Insurance Menu for the first time"},
  {"driverScore", "Driver Score Help"},
  {},
  {"milestones", "(NO LONGER USED)"},
  {"progress", "(NO LONGER USED)"},
}

M.drawDebugFunctions = function()
  if im.BeginMenu("> Intro Popups...") then
    if im.Selectable1("View All In Order") then
      for _, file in ipairs(introPopupFiles) do
        if next(file) then
          M.introPopup(file[1], true)
        end
      end
    end

    if im.Selectable1("Un-view all") then
      for _, file in ipairs(introPopupFiles) do
        if next(file) then
          M.setTutorialFlag(file[1], false)
        end
      end
    end

    im.Dummy(im.ImVec2(1, 3))
    im.Separator()
    im.Dummy(im.ImVec2(1, 3))
    for _, file in ipairs(introPopupFiles) do
      if not next(file) then
        im.Dummy(im.ImVec2(1, 3))
        im.Separator()
        im.Dummy(im.ImVec2(1, 3))
      else
        local folder = file[1]
        if im.Checkbox("##Seen " .. folder, im.BoolPtr(M.getTutorialFlag(folder) or false)) then
          M.setTutorialFlag(folder, not M.getTutorialFlag(folder))
        end
        im.SameLine()
        if im.Button("Edit##" .. folder) then
          Engine.Platform.exploreFolder("/gameplay/tutorials/pages/" .. folder .. "/content.html")
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

--==================================================
--MARK: Exports
-- Exported flag list and helpers
--==================================================

M.allTutorialFlags = {
  "welcome", "driving", "crashRecover", "bigmap", "refueling", "missions", "postMission",
  "dealership", "computer", "partShopping", "finishing", "delivery/intro", "logbook",
  "welcomeNoTutorial", "performanceIndex", "delivery/cargoScreen", "delivery/parcelDeliveryHelp",
  "delivery/vehicleDeliveryHelp", "delivery/trailerDeliveryHelp", "delivery/materialsDeliveryHelp",
  "delivery/loanerHelp", "vehiclePainting", "tuning", "insurance", "driverScore",
  "milestones", "progress", "leagues"
}

M.setFlagsTable = setFlagsTable
M.getTutorialFlag = getTutorialFlag
M.setTutorialFlag = setTutorialFlag

M.onExtensionLoaded = onExtensionLoaded
M.onSaveCurrentProfile = onSaveCurrentProfile

return M
