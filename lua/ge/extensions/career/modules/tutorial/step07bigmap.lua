-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local tasklistLocale = require("/lua/ge/extensions/career/modules/tutorial/tasklistLocale")
local GARAGE_POI_ID = "tutorial_apm_parking"
local GARAGE_ROUTE_POS_TOLERANCE_M = 10

local headers = {
  bigMap = { label = "ui.career.tutorial.task.step07.header.bigMap" },
}

local goals = {
  selectPoiGoal = {
    done = false,
    id = "step7_selectPoiGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step07.goal.selectPoi.label",
    subtext = "ui.career.tutorial.task.step07.goal.selectPoi.subtext",
    subtextController = "ui.career.tutorial.task.step07.goal.selectPoi.subtext.controller",
    attention = true,
  },
  setRouteGoal = {
    done = false,
    id = "step7_setRouteGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step07.goal.setRoute.label",
    subtext = "ui.career.tutorial.task.step07.goal.setRoute.subtext",
    attention = true,
  },
  closeBigmapGoal = {
    done = false,
    id = "step7_closeBigmapGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step07.goal.closeBigmap.label",
    subtext = "ui.career.tutorial.task.step07.goal.closeBigmap.subtext",
    actionItems = {
      { action = "toggleBigMap" },
    },
    attention = true,
  },
}

local messages = {
  openBigmapMessage = {
    id = "step7_openBigmapMessage",
    type = "message",
    label = "ui.career.tutorial.task.step07.message.openBigmap",
    actionItems = {
      { action = "toggleBigMap" },
    },
    clear = false,
  },
  timeslipHintMessage = {
    id = "step7_timeslipHintMessage",
    type = "message",
    label = "ui.career.tutorial.task.step07.message.timeslipHint",
    clear = false,
  },
}

local bigMapOpened = false
local bigMapActive = false
local tutorialPopupClosed = false
local routeSet = false
local timeslipHintMessageVisible = false
local garagePoiSelected = false
local garagePoiSpot = nil

local function resetToStep7Start()
  local sites = gameplay_tutorial_setup.tutorialSites
  local spot = sites and sites.parkingSpots and sites.parkingSpots.byName and sites.parkingSpots.byName["beforeDragStrip"] or nil
  local veh = gameplay_tutorial_setup.tutorialVehicleId and getObjectByID(gameplay_tutorial_setup.tutorialVehicleId) or getPlayerVehicle(0)
  if not spot or not veh then return end
  spawn.safeTeleport(veh, spot.pos, spot.rot, nil, nil, nil, nil, false)
  if gameplay_walk and gameplay_walk.isWalking() then
    gameplay_walk.getInVehicle(veh)
  end
end

local function completeGoal(goal)
  if goal.done then return end
  goal.done = true
  tasklistLocale.setTasklistTask(goal)
end

local function isRouteSetToGarage(pos)
  if not pos or not garagePoiSpot then return false end
  local routePos = vec3(pos.x or 0, pos.y or 0, pos.z or 0)
  return routePos:distance(garagePoiSpot.pos) <= GARAGE_ROUTE_POS_TOLERANCE_M
end

local function setTimeslipHintMessageVisible(visible)
  if visible == timeslipHintMessageVisible then return end
  timeslipHintMessageVisible = visible
  if visible then
    tasklistLocale.setTasklistTask(messages.timeslipHintMessage)
    return
  end
  guihooks.trigger("DiscardTasklistItem", messages.timeslipHintMessage.id)
end

local function isPlayerInTimeslipHintZone()
  local sites = gameplay_tutorial_setup.tutorialSites
  if not sites then return false end
  local zonesByName = sites.zones and sites.zones.byName
  if not zonesByName then return false end
  local zone = zonesByName["timeslipHint"]
  if not zone or not zone.containsPoint2D then return false end

  local veh = getPlayerVehicle(0)
  local pos = veh and veh:getPosition() or core_camera.getPosition()
  if not pos then return false end
  return zone:containsPoint2D(pos)
end

function M.setup(stepData)
  goals.selectPoiGoal.done = false
  goals.setRouteGoal.done = false
  goals.closeBigmapGoal.done = false
  bigMapOpened = false
  bigMapActive = false
  tutorialPopupClosed = false
  routeSet = false
  garagePoiSelected = false
  garagePoiSpot = nil
  timeslipHintMessageVisible = false

  -- Big map must be usable for this step.
  gameplay_tutorial_setup.blockedActionsTemplates.bigMap = false
  gameplay_tutorial_setup.setupBlockedActions()
  if gameplay_tutorial_setup.tutorialSites then
    garagePoiSpot = gameplay_tutorial_setup.tutorialSites.parkingSpots.byName["garageExteriorPark"]
  end
  gameplay_tutorial_bounds.setActiveZones({"drivingToDragBounds", "dragStripBounds"})
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(resetToStep7Start)

  guihooks.trigger("ClearTasklist")
  tasklistLocale.setTasklistHeader(headers.bigMap)
  tasklistLocale.setTasklistTask(messages.openBigmapMessage)

  gameplay_rawPois.clear()
end

function M.onCareerTutorialLeftBounds()
  gameplay_tutorial_setup.runCurrentStepOutOfBoundsReset()
end

-- Wait for map activation first, then show popup.
function M.onActivateBigMapCallback()
  if career_modules_tutorial.getCurrentStep() ~= "07bigmap" then return end
  bigMapActive = true
  -- Keep map UI focused: hide in-world hint task while big map is active.
  setTimeslipHintMessageVisible(false)
  -- Rebuild tutorial raw POIs each time map opens so tutorial entries remain available.
  gameplay_rawPois.clear()
  if bigMapOpened then return end
  bigMapOpened = true
  guihooks.trigger("DiscardTasklistItem", messages.openBigmapMessage.id)
  core_jobsystem.create(function(job)
    job.sleep(0.5)
    career_modules_tutorialPopups.introPopup("v2/bigmapTutorial", true)
  end, 1)
end

function M.onIntroPopupCareerClosed(id)
  if id ~= "v2/bigmapTutorial" then return end
  if career_modules_tutorial.getCurrentStep() ~= "07bigmap" then return end
  if tutorialPopupClosed then return end
  tutorialPopupClosed = true
  tasklistLocale.setTasklistTask(goals.selectPoiGoal)
end

function M.onPoiSelectedFromBigmap(poiId)
  if career_modules_tutorial.getCurrentStep() ~= "07bigmap" then return end
  if not tutorialPopupClosed then return end
  if goals.selectPoiGoal.done then return end
  if not poiId then return end
  if poiId ~= GARAGE_POI_ID then return end

  garagePoiSelected = true
  completeGoal(goals.selectPoiGoal)
  tasklistLocale.setTasklistTask(goals.setRouteGoal)
end

function M.onSetBigmapNavFocus(pos)
  if career_modules_tutorial.getCurrentStep() ~= "07bigmap" then return end
  if not tutorialPopupClosed then return end

  routeSet = garagePoiSelected and isRouteSetToGarage(pos)
  if not goals.selectPoiGoal.done or goals.setRouteGoal.done or not routeSet then
    return
  end

  completeGoal(goals.setRouteGoal)
  tasklistLocale.setTasklistTask(goals.closeBigmapGoal)
end

function M.onDeactivateBigMapCallback()
  if career_modules_tutorial.getCurrentStep() ~= "07bigmap" then return end
  bigMapActive = false
  if not tutorialPopupClosed then return end
  if not goals.setRouteGoal.done or not routeSet then return end

  completeGoal(goals.closeBigmapGoal)
  core_jobsystem.create(function(job)
    job.sleep(1.0)
    career_modules_tutorial.advanceToNextStep()
  end, 1)
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if career_modules_tutorial.getCurrentStep() ~= "07bigmap" then return end
  if bigMapActive then
    setTimeslipHintMessageVisible(false)
    return
  end
  if not gameplay_tutorial_bounds.isInBounds() then
    setTimeslipHintMessageVisible(false)
    return
  end
  setTimeslipHintMessageVisible(isPlayerInTimeslipHintZone())
end

function M.cleanup()
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(nil)
  bigMapActive = false
  guihooks.trigger("DiscardTasklistItem", messages.timeslipHintMessage.id)
  timeslipHintMessageVisible = false
  guihooks.trigger("ClearTasklist")
end

function M.onDebugMenu(im)
  im.Text("Step 7 - Big Map")
  im.Separator()
  im.Text(string.format("Big map opened: %s", bigMapOpened and "Yes" or "No"))
  im.Text(string.format("Popup closed: %s", tutorialPopupClosed and "Yes" or "No"))
  im.Text(string.format("Route set: %s", routeSet and "Yes" or "No"))
  if im.Button("Skip Step 7") then
    completeGoal(goals.selectPoiGoal)
    completeGoal(goals.setRouteGoal)
    completeGoal(goals.closeBigmapGoal)
    career_modules_tutorial.advanceToNextStep()
  end
end

return M
