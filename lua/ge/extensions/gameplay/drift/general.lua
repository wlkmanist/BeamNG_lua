local M = {}

M.dependencies = {"gameplay_drift_drift", "gameplay_drift_scoring", "gameplay_drift_statistics"}

local debug = false
local context -- contexts are : "stopped" "inChallenge" "inFreeroam"
local frozen = false -- used during drift missions when the vehicle goes out of bounds

local function clear()
  gameplay_drift_scoring.resetScore()
  gameplay_drift_drift.reset()
  if gameplay_drift_stuntZones then gameplay_drift_stuntZones.clearStuntZones() end
  frozen = false
end

local function reset()
  gameplay_drift_scoring.resetScore()
  gameplay_drift_drift.reset()
  if gameplay_drift_stuntZones then gameplay_drift_stuntZones.resetStuntZones() end
  frozen = false
end

local function setContext(newContext)
  if newContext == context then return end

  context = newContext
  if context == "stopped" then
    clear()
    extensions.unload("gameplay_drift_stuntZones")
    extensions.unload("gameplay_drift_display")
  elseif context == "inFreeroam" then
    extensions.unload("gameplay_drift_stuntZones")
    extensions.unload("gameplay_drift_display")
  elseif context == "inChallenge" then
    extensions.load("gameplay_drift_stuntZones")
    extensions.load("gameplay_drift_display")
  end
  extensions.hook("onDriftGeneralContextChanged", newContext)
end

local function setDebug(value)
  debug = value
end

local function setFrozen(value)
  frozen = value
end

local function getDebug()
  return debug
end

local function getContext()
  return context
end

local function getFrozen()
  return frozen
end

local function onExtensionLoaded()
  reset()
  setContext("inFreeroam")
end

local function onAnyMissionChanged(status, id)
  clear()
  if status == "stopped" then setContext("inFreeroam") end
end

local function onVehicleResetted(vid)
  if vid == be:getPlayerVehicleID(0) then
    extensions.hook("onDriftPlVehReset")
  end
end

M.reset = reset

M.getDebug = getDebug
M.getContext = getContext
M.getFrozen = getFrozen

M.setDebug = setDebug
M.setContext = setContext
M.setFrozen = setFrozen

M.onVehicleResetted = onVehicleResetted
M.onAnyMissionChanged = onAnyMissionChanged
M.onExtensionLoaded = onExtensionLoaded
return M