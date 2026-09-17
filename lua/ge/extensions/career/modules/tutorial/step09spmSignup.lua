-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local tasklistLocale = require("/lua/ge/extensions/career/modules/tutorial/tasklistLocale")

local STARTING_BONUS_MONEY = 10000

local headers = {
  onboarding = { label = "ui.career.tutorial.task.step09.header.onboarding" },
  firstVehicle = { label = "ui.career.tutorial.task.step09.header.firstVehicle" },
}

local goals = {
  accessComputerGoal = {
    done = false,
    id = "step9_accessComputerGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step09.goal.accessComputer.label",
    subtext = "ui.career.tutorial.task.step09.goal.accessComputer.subtext",
    attention = true,
  },
  signUpGoal = {
    done = false,
    id = "step9_signUpGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step09.goal.signUp.label",
    subtext = "ui.career.tutorial.task.step09.goal.signUp.subtext",
  },
  openMarketplaceGoal = {
    done = false,
    id = "step9_openMarketplaceGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step09.goal.openMarketplace.label",
    subtext = "ui.career.tutorial.task.step09.goal.openMarketplace.subtext",
    attention = true,
  },
  selectSellerGoal = {
    done = false,
    id = "step9_selectSellerGoal",
    type = "message",
    label = "ui.career.tutorial.task.step09.goal.selectSeller.label",
    subtext = "ui.career.tutorial.task.step09.goal.selectSeller.subtext",
    attention = true,
  },
  openPurchaseGoal = {
    done = false,
    id = "step9_openPurchaseGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step09.goal.openPurchase.label",
    subtext = "ui.career.tutorial.task.step09.goal.openPurchase.subtext",
    subtextController = "ui.career.tutorial.task.step09.goal.openPurchase.subtext.controller",
    attention = true,
  },
  finalizePurchaseGoal = {
    done = false,
    id = "step9_finalizePurchaseGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step09.goal.finalizePurchase.label",
    subtext = "ui.career.tutorial.task.step09.goal.finalizePurchase.subtext",
  },
}

local phase = "waitComputer"
local tutorialVehicleDespawned = false
local garageInteriorWalkStartSpot = nil
local WALK_ROUTE_CLEAR_DISTANCE_M = 1
local GARAGE_ENTRANCE_MARKER_HIDE_DISTANCE_M = 3.0
local garageEntranceMarkerSpot = nil
local garageEntranceMarkerId = nil
local moneySoundId = nil
local startingBonusGranted = false

local function clearComputerRoute()
  core_groundMarkers.setPath(nil)
  garageInteriorWalkStartSpot = nil
end

local function clearGarageEntranceMarker()
  if garageEntranceMarkerId and gameplay_tutorial_markers then
    gameplay_tutorial_markers.removeMarker(garageEntranceMarkerId)
  end
  garageEntranceMarkerId = nil
end

local function setupGarageEntranceMarker()
  if garageEntranceMarkerId then return end
  if not garageEntranceMarkerSpot or not gameplay_tutorial_markers then return end
  local p = garageEntranceMarkerSpot.pos
  garageEntranceMarkerId = gameplay_tutorial_markers.createMarker(vec3(p.x, p.y, p.z + 2), nil, vec3(1.5, 1.5, 1.5))
end

local function resetToStep9Start()
  local sites = gameplay_tutorial_setup.tutorialSites
  local spot = sites and sites.parkingSpots and sites.parkingSpots.byName and sites.parkingSpots.byName["garageInteriorWalkStart"] or nil
  local veh = getPlayerVehicle(0)
  if not spot or not veh then return end
  spawn.safeTeleport(veh, spot.pos, spot.rot, nil, nil, nil, nil, false)
  if gameplay_walk and gameplay_walk.setWalkingMode then
    gameplay_walk.setWalkingMode(true)
  end
end

local function despawnTutorialVehicle()
  if tutorialVehicleDespawned then return end

  -- Keep garage onboarding visuals in sync with tutorial car lifetime.
  gameplay_tutorial_setup.setActivePrefabs({
    garageParkingPylons = false
  })

  local tutorialVehId = gameplay_tutorial_setup.tutorialVehicleId
  if tutorialVehId then
    local tutorialVeh = getObjectByID(tutorialVehId)
    if tutorialVeh then
      tutorialVeh:delete()
    end
    gameplay_tutorial_setup.tutorialVehicleId = nil
  end
  tutorialVehicleDespawned = true
end

local function markGoalDone(goal)
  if goal.done then return end
  goal.done = true
  tasklistLocale.setTasklistTask(goal)
end

local function grantStartingBonus()
  if startingBonusGranted then return end
  startingBonusGranted = true
  career_modules_playerAttributes.addAttributes({ money = STARTING_BONUS_MONEY }, { tags = { "tutorial", "startingBonus" }, label = "ui.career.tutorial.reward.startingBonus" })
  guihooks.trigger("careerStatusDataUpdated")
  if not moneySoundId or not scenetree.findObjectById(moneySoundId) then
    moneySoundId = Engine.Audio.createSource("AudioGui", "event:>UI>Career>Progress_Money")
  end
  if moneySoundId and moneySoundId ~= 0 then
    local sound = scenetree.findObjectById(moneySoundId)
    if sound then
      sound:play(-1)
    end
  end
end

function M.setup(stepData)
  for _, goal in pairs(goals) do
    goal.done = false
  end
  phase = "waitComputer"
  tutorialVehicleDespawned = false
  garageInteriorWalkStartSpot = nil
  garageEntranceMarkerSpot = nil
  garageEntranceMarkerId = nil
  startingBonusGranted = false

  gameplay_tutorial_bounds.setActiveZones({"garageBounds"})
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(resetToStep9Start)
  if gameplay_tutorial_setup.tutorialSites then
    garageInteriorWalkStartSpot = gameplay_tutorial_setup.tutorialSites.parkingSpots.byName["garageInteriorWalkStart"]
    garageEntranceMarkerSpot = gameplay_tutorial_setup.tutorialSites.parkingSpots.byName["garageEntranceMarker"]
  end

  guihooks.trigger("ClearTasklist")
  tasklistLocale.setTasklistHeader(headers.onboarding)
  tasklistLocale.setTasklistTask(goals.accessComputerGoal)
  setupGarageEntranceMarker()
  gameplay_rawPois.clear()
end

function M.onComputerMenuOpened()
  if career_modules_tutorial.getCurrentStep() ~= "09spmSignup" then return end
  if phase ~= "waitComputer" then return end

  clearGarageEntranceMarker()
  clearComputerRoute()
  markGoalDone(goals.accessComputerGoal)
  phase = "waitApmPopup"
  tasklistLocale.setTasklistTask(goals.signUpGoal)
  local saveSlot = career_saveSystem.getCurrentProfile()
  ui_popup.openContractSignPopup({ userName = saveSlot, money = STARTING_BONUS_MONEY, startingMoney = 0, endMoney = STARTING_BONUS_MONEY }, {
    "v2/apmOnboarding",
  })
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if career_modules_tutorial.getCurrentStep() ~= "09spmSignup" then return end
  if phase ~= "waitComputer" then return end
  if not garageInteriorWalkStartSpot then return end

  local veh = getPlayerVehicle(0)
  local pos = veh and veh:getPosition() or core_camera.getPosition()
  if not pos then return end
  if garageEntranceMarkerId and garageEntranceMarkerSpot and pos:distance(garageEntranceMarkerSpot.pos) <= GARAGE_ENTRANCE_MARKER_HIDE_DISTANCE_M then
    clearGarageEntranceMarker()
  end
  if pos:distance(garageInteriorWalkStartSpot.pos) <= WALK_ROUTE_CLEAR_DISTANCE_M then
    clearComputerRoute()
  end
end

function M.onCareerTutorialRedeemedContractVoucher()
  if career_modules_tutorial.getCurrentStep() ~= "09spmSignup" then return end
  grantStartingBonus()
end

function M.onIntroPopupCareerClosed(id)
  if career_modules_tutorial.getCurrentStep() ~= "09spmSignup" then return end

  if id == "contractSign" and phase == "waitApmPopup" then
    grantStartingBonus()
    gameplay_achievement.unlockAchievement("WELCOME_TO_APM")
    markGoalDone(goals.signUpGoal)
    return
  end

  if id == "v2/apmOnboarding" and phase == "waitApmPopup" then
    guihooks.trigger("ClearTasklist")
    tasklistLocale.setTasklistHeader(headers.firstVehicle)
    tasklistLocale.setTasklistTask(goals.openMarketplaceGoal)
    phase = "waitMarketplaceOpen"
    return
  end

  if id == "v2/careerUnlocked" and phase == "waitCareerUnlocked" then
    gameplay_achievement.unlockAchievement("FIRST_ROLLOUT")
    if career_modules_tutorial.playedAdvancedTimeTrial then
      gameplay_achievement.unlockAchievement("EXTRA_CREDIT")
    end
    career_modules_tutorial.endTutorial()
    return
  end
end

function M.onVehicleShoppingMenuOpened(data)
  if career_modules_tutorial.getCurrentStep() ~= "09spmSignup" then return end
  if phase ~= "waitMarketplaceOpen" then return end

  markGoalDone(goals.openMarketplaceGoal)
  tasklistLocale.setTasklistTask(goals.selectSellerGoal)
  phase = "waitSellerSelect"
end

function M.onVehicleShoppingSelectedSellerIdChanged(payload)
  if career_modules_tutorial.getCurrentStep() ~= "09spmSignup" then return end
  if phase ~= "waitSellerSelect" then return end

  markGoalDone(goals.selectSellerGoal)
  tasklistLocale.setTasklistTask(goals.openPurchaseGoal)
  phase = "waitPurchaseMenu"
end

function M.onVehicleShoppingPurchaseMenuOpened(data)
  if career_modules_tutorial.getCurrentStep() ~= "09spmSignup" then return end
  if phase ~= "waitPurchaseMenu" then return end

  -- Despawn tutorial car BEFORE purchase finalization so spawn safety checks see free space.
  despawnTutorialVehicle()

  markGoalDone(goals.openPurchaseGoal)
  tasklistLocale.setTasklistTask(goals.finalizePurchaseGoal)
  phase = "waitVehicleAdded"
  career_modules_tutorialPopups.introPopup("v2/vehiclePurchaseAndInsurance", true)
end

function M.onVehicleAddedToInventory(data)
  if career_modules_tutorial.getCurrentStep() ~= "09spmSignup" then return end
  if phase ~= "waitVehicleAdded" then return end

  -- Safety fallback in case the car was not removed earlier.
  despawnTutorialVehicle()

  -- Once the first vehicle is purchased, disable tutorial OOB checks for this step.
  gameplay_tutorial_bounds.setActiveZones({})
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(nil)

  markGoalDone(goals.finalizePurchaseGoal)
  guihooks.trigger("ClearTasklist")
  phase = "waitCareerUnlocked"
  career_modules_tutorialPopups.introPopup("v2/careerUnlocked", true)
end

function M.onGetRawPoiListForTutorial(elements)
  if career_modules_tutorial.getCurrentStep() ~= "09spmSignup" then return end
  local garage = freeroam_facilities.getFacility("computer", "servicestationGarageComputer")
  if garage then
    freeroam_facilities.formatFacilityToRawPoi(garage, elements)
  end
end

function M.cleanup()
  clearGarageEntranceMarker()
  if moneySoundId then
    local sound = scenetree.findObjectById(moneySoundId)
    if sound then
      sound:delete()
    end
    moneySoundId = nil
  end
  gameplay_tutorial_bounds.setActiveZones({})
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(nil)
  guihooks.trigger("ClearTasklist")
end

function M.onDebugMenu(im)
  im.Text("Step 9 - SPM Signup")
  im.Separator()
  im.Text(string.format("Phase: %s", tostring(phase)))
  if im.Button("Skip Step 9") then
    for _, goal in pairs(goals) do
      markGoalDone(goal)
    end
    guihooks.trigger("ClearTasklist")
    phase = "waitCareerUnlocked"
    career_modules_tutorialPopups.introPopup("v2/careerUnlocked", true)
  end
end

return M
