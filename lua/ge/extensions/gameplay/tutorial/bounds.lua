-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local sites = nil
local activeZoneNames = {}
local zoneEnabled = {}

local debugDrawBounds = false
local outOfBoundsActive = false
local outOfBoundsElapsed = 0
local autoResetTriggered = false
local lastShownCountdown = nil

local runtimeIsActiveGetter = function() return false end
local currentStepGetter = function() return nil end

local callbacks = {
  onOutOfBoundsStarted = function()
    extensions.hook("onCareerTutorialOutOfBoundsStarted")
  end,
  onOutOfBoundsEnded = function()
    extensions.hook("onCareerTutorialOutOfBoundsEnded")
  end,
  onOutOfBoundsTimedOut = function(currentStepId)
    if currentStepId == "04timeTrial" then
      extensions.hook("onCareerTutorialOutOfBoundsTimedOut")
    else
      extensions.hook("onCareerTutorialLeftBounds")
    end
  end,
  onOutOfBoundsWhileNotAllowed = function()
    extensions.hook("onCareerTutorialLeftBounds")
  end
}

local OOB_WARNING_ID = "tutorial_oob_returnToEval"
local OOB_AUTO_RESET_SECONDS = 5
local OOB_RETURNING_MESSAGE_SECONDS = 1.0

local function getOutOfBoundsTitleLabel()
  return "You are out of bounds. Please return to the evaluation zone."
end

local function getOutOfBoundsCountdownLabel(secondsRemaining)
  return string.format("Auto return: %d", secondsRemaining)
end

local function getOutOfBoundsReturningLabel()
  return "Automatically returning to the evaluation zone..."
end

function M.setRuntimeActiveGetter(getter)
  if type(getter) == "function" then
    runtimeIsActiveGetter = getter
  else
    runtimeIsActiveGetter = function() return false end
  end
end

function M.setCurrentStepGetter(getter)
  if type(getter) == "function" then
    currentStepGetter = getter
  else
    currentStepGetter = function() return nil end
  end
end

function M.setCallbacks(newCallbacks)
  newCallbacks = type(newCallbacks) == "table" and newCallbacks or {}
  callbacks.onOutOfBoundsStarted = newCallbacks.onOutOfBoundsStarted or callbacks.onOutOfBoundsStarted
  callbacks.onOutOfBoundsEnded = newCallbacks.onOutOfBoundsEnded or callbacks.onOutOfBoundsEnded
  callbacks.onOutOfBoundsTimedOut = newCallbacks.onOutOfBoundsTimedOut or callbacks.onOutOfBoundsTimedOut
  callbacks.onOutOfBoundsWhileNotAllowed = newCallbacks.onOutOfBoundsWhileNotAllowed or callbacks.onOutOfBoundsWhileNotAllowed
end

local function showOutOfBoundsWarning(countdownLabel)
  guihooks.trigger("SetTasklistTask", {
    id = OOB_WARNING_ID,
    type = "message",
    label = getOutOfBoundsTitleLabel(),
    subtext = countdownLabel,
    clear = false
  })
end

local function hideOutOfBoundsWarning()
  guihooks.trigger("DiscardTasklistItem", OOB_WARNING_ID)
end

local function enterOutOfBounds()
  outOfBoundsActive = true
  outOfBoundsElapsed = 0
  autoResetTriggered = false
  lastShownCountdown = OOB_AUTO_RESET_SECONDS
  showOutOfBoundsWarning(getOutOfBoundsCountdownLabel(lastShownCountdown))
  if callbacks.onOutOfBoundsStarted then
    callbacks.onOutOfBoundsStarted()
  end
end

local function leaveOutOfBounds()
  if not outOfBoundsActive then return end
  outOfBoundsActive = false
  outOfBoundsElapsed = 0
  autoResetTriggered = false
  lastShownCountdown = nil
  hideOutOfBoundsWarning()
  if callbacks.onOutOfBoundsEnded then
    callbacks.onOutOfBoundsEnded()
  end
end

local function getPlayerPosition()
  local veh = getPlayerVehicle(0)
  if veh then
    return veh:getPosition()
  end
  return core_camera.getPosition()
end

local function isInBoundsInternal()
  if not sites or not next(activeZoneNames) then return true end

  local pos = getPlayerPosition()
  if not pos then return true end

  local zonesByName = sites.zones and sites.zones.byName
  if zonesByName then
    for name, isActive in pairs(activeZoneNames) do
      if isActive and zoneEnabled[name] ~= false then
        local zone = zonesByName[name]
        if zone and zone.containsPoint2D and zone:containsPoint2D(pos) then
          return true
        end
      end
    end
    return false
  end

  local zonesAtPos = sites:getZonesForPosition(pos)
  for _, zone in ipairs(zonesAtPos) do
    local name = zone.name
    if name and activeZoneNames[name] and zoneEnabled[name] ~= false then
      return true
    end
  end
  return false
end

local function drawActiveZones()
  if not sites or not sites.zones or not sites.zones.objects then return end
  local color = { 1, 1, 0, 0.5 }
  for _, zone in pairs(sites.zones.objects) do
    local name = zone.name
    if name and activeZoneNames[name] and zoneEnabled[name] ~= false then
      if zone.drawDebug then
        zone:drawDebug("normal", color)
      end
    end
  end
end

function M.setSites(newSites)
  sites = newSites
end

function M.setActiveZones(names)
  activeZoneNames = {}
  if names then
    for _, name in ipairs(names) do
      activeZoneNames[name] = true
    end
  end
end

function M.setZoneEnabled(zoneName, enabled)
  zoneEnabled[zoneName] = enabled
end

function M.getZoneEnabled(zoneName)
  if zoneEnabled[zoneName] == nil then return true end
  return zoneEnabled[zoneName]
end

function M.getActiveZoneNames()
  local list = {}
  for name, _ in pairs(activeZoneNames) do
    table.insert(list, name)
  end
  table.sort(list)
  return list
end

function M.getEnabledZones()
  return zoneEnabled
end

function M.setDebugDrawBounds(enabled)
  debugDrawBounds = enabled
end

function M.getDebugDrawBounds()
  return debugDrawBounds
end

function M.isInBounds()
  if not runtimeIsActiveGetter() then return true end
  return isInBoundsInternal()
end

function M.update(dtReal)
  if not runtimeIsActiveGetter() then
    leaveOutOfBounds()
    return
  end

  if not sites then
    sites = gameplay_tutorial_setup.tutorialSites
    if not sites then
      gameplay_tutorial_setup.loadTutorialSites()
      sites = gameplay_tutorial_setup.tutorialSites
    end
  end

  local inBounds = isInBoundsInternal()
  local oobAllowed = gameplay_tutorial_setup.isOutOfBoundsResetAllowed()

  if not oobAllowed then
    leaveOutOfBounds()
    if not inBounds and callbacks.onOutOfBoundsWhileNotAllowed then
      callbacks.onOutOfBoundsWhileNotAllowed()
    end
    return
  end

  if inBounds then
    leaveOutOfBounds()
    return
  end

  if not outOfBoundsActive then
    enterOutOfBounds()
  end

  if autoResetTriggered then return end

  outOfBoundsElapsed = outOfBoundsElapsed + dtReal
  local secondsRemaining = math.max(0, math.ceil(OOB_AUTO_RESET_SECONDS - outOfBoundsElapsed))
  if secondsRemaining ~= lastShownCountdown then
    lastShownCountdown = secondsRemaining
    showOutOfBoundsWarning(getOutOfBoundsCountdownLabel(secondsRemaining))
  end

  if outOfBoundsElapsed >= OOB_AUTO_RESET_SECONDS then
    autoResetTriggered = true
    showOutOfBoundsWarning(getOutOfBoundsReturningLabel())
    core_jobsystem.create(function(job)
      job.sleep(OOB_RETURNING_MESSAGE_SECONDS)
      if not outOfBoundsActive or not autoResetTriggered then return end
      hideOutOfBoundsWarning()
      if callbacks.onOutOfBoundsTimedOut then
        callbacks.onOutOfBoundsTimedOut(currentStepGetter())
      end
    end, 1)
  end
end

function M.onPreRender(dtReal, dtSim, dtRaw)
  if not runtimeIsActiveGetter() then return end
  if debugDrawBounds then
    drawActiveZones()
  end
end

function M.cleanup()
  leaveOutOfBounds()
  sites = nil
  activeZoneNames = {}
  zoneEnabled = {}
  debugDrawBounds = false
end

return M
