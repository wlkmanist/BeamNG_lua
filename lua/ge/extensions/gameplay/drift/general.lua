local M = {}
local im = ui_imgui

M.dependencies = {"gameplay_drift_drift", "gameplay_drift_scoring", "gameplay_drift_statistics", "gameplay_drift_saveLoad"}

local debug = false
local context -- contexts are : "stopped" "inChallenge" "inFreeroam"
local frozen = false -- used during drift missions when the vehicle goes out of bounds
local challengeMode -- challengeModes are : "A to B" "A to B with stunt zones" "Gymkhana" "None"

local firstFlag = false

local function commonReset()
  if gameplay_drift_stallingSystem then
    gameplay_drift_stallingSystem.reset()
  end
  gameplay_drift_scoring.resetScore()
  gameplay_drift_drift.reset()
end

local function clear()
  commonReset()
  if gameplay_drift_stuntZones then gameplay_drift_stuntZones.clearStuntZones() end
  frozen = false
end

local function reset()
  commonReset()
  if gameplay_drift_stuntZones then gameplay_drift_stuntZones.resetStuntZones() end
  frozen = false
end

local function setChallengeMode(newChallengeMode)
  challengeMode = newChallengeMode

  if challengeMode == "None" or challengeMode == "A to B" or challengeMode == "A to B with stunt zones" then
    extensions.unload("gameplay_drift_stallingSystem")
  else
    extensions.load("gameplay_drift_stallingSystem")
  end
end

local function setContext(newContext)
  if newContext == context then return end

  context = newContext
  if context == "stopped" or context == "inFreeroam" then
    if context == "stopped" then
      clear()
    end
    setChallengeMode("None")
    extensions.unload("gameplay_drift_stuntZones")
    extensions.unload("gameplay_drift_display")
    extensions.unload("gameplay_drift_stallingSystem")
  elseif context == "inChallenge" then
    extensions.load("gameplay_drift_stuntZones")
    extensions.load("gameplay_drift_display")
  end
  extensions.hook("onDriftGeneralContextChanged", newContext)
end

local function setDebug(value)
  debug = value
  extensions.hook("onDriftDebugChanged", value)
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

local function getChallengeMode()
  return challengeMode
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

local function imguiDebug()
  if gameplay_drift_general.getDebug() then
    if im.Begin("Drift general") then
      im.Text("Drift context : " .. context)
      if im.Button("Set context freeroam") then setContext("inFreeroam") end
      if im.Button("Set context challenge") then setContext("inChallenge") end
      if im.Button("Set context stopped") then setContext("stopped") end
      if context == "inChallenge" then
        im.Text("Challege mode : " .. challengeMode)
        if im.Button("Set challenge mode 'A to B'") then setChallengeMode("A to B") end
        if im.Button("Set challenge mode 'A to B with stunt zones'") then setChallengeMode("A to B with stunt zones") end
        if im.Button("Set challenge mode 'Gymkhana'") then setChallengeMode("Gymkhana") end
      end
    end
    if im.Button("Exit debug") then setDebug(false) end
  end
end

local function init()
  reset()
  setContext("inFreeroam")
end

local function onUpdate()
  imguiDebug()

  if not firstFlag then
    init()
    firstFlag = true
  end
end

local function onSerialize()
  return {
    debug = debug
  }
end

local function onDeserialized(data)
  debug = data.debug
end

M.reset = reset

M.setChallengeMode = setChallengeMode
M.getChallengeMode = getChallengeMode

M.getDebug = getDebug
M.getContext = getContext
M.getFrozen = getFrozen

M.setDebug = setDebug
M.setContext = setContext
M.setFrozen = setFrozen

M.onVehicleResetted = onVehicleResetted
M.onAnyMissionChanged = onAnyMissionChanged
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onUpdate = onUpdate
return M