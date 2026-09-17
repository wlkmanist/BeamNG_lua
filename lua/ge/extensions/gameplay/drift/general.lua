-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local im = ui_imgui
local imVec4Red = im.ImVec4(1,0.1,0,1)
local driftAppMounted = false

M.dependencies = {"gameplay_drift_drift", "gameplay_drift_scoring", "gameplay_drift_statistics", "gameplay_drift_saveLoad", "gameplay_util_groundContact"}

local loadedExtensions = {}

local driftDebugInfo = {
  default = true,
  canBeChanged = false
}

-- decides when an extension is loaded/unloaded
local variableExtensions = {
  gameplay_drift_stallingSystem = {
    challengeModes = {"Gymkhana"}
  },
  gameplay_drift_destination = {
    challengeModes = {"A to B", "A to B with stunt zones"},
    contexts = {"inFreeroamChallenge"}
  },
  gameplay_drift_stuntZones = {
    contexts = {"inChallenge"}
  },
  gameplay_drift_display = {
    contexts = {"inChallenge", "inFreeroamChallenge", "inFreeroam", "inFreeroamCruising"}
  },
  gameplay_drift_quickMessages = {
    contexts = {"inFreeroam", "inChallenge", "inFreeroamChallenge", "inFreeroamCruising"}
  },
  gameplay_drift_bounds = {
    contexts = {"inChallenge", "inFreeroamChallenge"}
  },
  gameplay_drift_freeroam_driftSpots = {
    contexts = {"inFreeroam", "inFreeroamChallenge", "inFreeroamCruising"},
  },
  gameplay_drift_scoreboard = {
    contexts = {"inChallenge"},
  },
  -- gameplay_drift_driftCompetition_clipZones = {
    --   challengeModes = {"Competition"}
    -- },
  gameplay_drift_freeroam_cruising = {manualLoad = true},
  gameplay_drift_sounds = {manualLoad = true}, -- it actually depends on the UI app being loaded
  gameplay_drift_multiplayer = {manualLoad = true}
}

local debugFlag = false
local context
local multiplayerEnabled = true
local frozen = false -- used to freeze the scoring, drift detection. For exemple when the player goes out of bounds or wrong way
local challengeMode
local paused = false -- used to "pause" the drift systems, used during the end screen of formal mission challenges

local contextList = {"inFreeroam", "inChallenge", "inFreeroamChallenge", "inAnotherMissionType", "inFreeroamCruising"}
local challengeModeList = {"None", "A to B", "A to B with stunt zones", "Gymkhana", "Competition"}

local driftExtensions = {}

local function commonReset()
  for extensionName, _ in pairs(loadedExtensions) do
    if extensionName ~= "gameplay_drift_general" and extensions.isExtensionLoaded(extensionName) and _G[extensionName].reset then
      _G[extensionName].reset()
    end
  end
  frozen = false
end

local function clear()
  commonReset()
  if gameplay_drift_stuntZones then gameplay_drift_stuntZones.clear() end
end

local function reset()
  commonReset()
  if gameplay_drift_stuntZones then gameplay_drift_stuntZones.reset() end
end

-- make a list of which extensions are loaded or unloaded
local function checkLoadedExtensions()
  for _, filePath in ipairs(driftExtensions) do
    local extensionName = string.match(extensions.luaPathToExtName(filePath), "extensions_([%w_]+)%.lua")
    local ext = require(string.match(filePath, "(.+)%.lua$"))
    local driftDebugInfo = {
      canBeChanged = false,
      default = false
    }
    if type(ext) == "table" then
      if ext.getDriftDebugInfo then
        driftDebugInfo = ext:getDriftDebugInfo()
      end
      loadedExtensions[extensionName] = {
        loaded = extensions.isExtensionLoaded(extensionName),
        driftDebugInfo = driftDebugInfo
      }
    end
  end
end

local function updateExtensions()
  for extensionName, data in pairs(variableExtensions) do
    if not data.manualLoad then
      local foundMatch = false
      if data.challengeModes then
        for _, challengeMode_ in ipairs(data.challengeModes) do
          if challengeMode_ == challengeMode then
            extensions.load(extensionName)
            foundMatch = true
            break
          end
        end
      end
      if data.contexts then
        for _, context_ in ipairs(data.contexts) do
          if context_ == context then
            extensions.load(extensionName)
            foundMatch = true
            break
          end
        end
      end

      if not foundMatch then
        extensions.unload(extensionName)
      end

      checkLoadedExtensions()
    end
  end
end

local function setChallengeMode(newChallengeMode)
  if newChallengeMode == challengeMode then return end
  challengeMode = newChallengeMode

  updateExtensions()
end

local function setPaused(newPaused)
  paused = newPaused
end

local function setContext(newContext)
  local oldContext = context

  context = newContext
  extensions.hook("onDriftContextChanged", context, oldContext)

  if oldContext ~= context then
    if context == "inFreeroam" then
      setChallengeMode("None")
    end

    updateExtensions()
  end
end

local function setDebug(value)
  debugFlag = value
  if debugFlag then
    checkLoadedExtensions()
  end
  extensions.hook("onDriftDebugChanged", value)
end

local function getGeneralDebug()
  return debugFlag
end

local function getPaused()
  return paused
end

local function getContext()
  return context
end

local function getDriftDebugInfo()
  return driftDebugInfo
end

local function getExtensionDebug(extName)
  if not debugFlag or not loadedExtensions[extName] then return false end
  return loadedExtensions[extName].driftDebugInfo.default
end

local function getFrozen()
  return frozen
end

local function getChallengeMode()
  return challengeMode
end

local function getMultiplayerEnabled()
  return multiplayer_sessionManager and multiplayer_sessionManager.getCurrentSession() and multiplayerEnabled
end

local function getIsThereAnyDriftUIAppDisplayed()
  local gameplayContextDriftLoaded = ui_appContainers.getAppVisibility('topCenter', 'drift')
  return driftAppMounted and gameplayContextDriftLoaded
end

local function onAnyMissionChanged(status, mission)
  clear()
  if status == "started" then
    if mission.missionType ~= "drift" then
      setContext("inAnotherMissionType")
    end
  elseif status == "stopped" then
    paused = false
    frozen = false
    setContext("inFreeroam")
  end
end

local function onVehicleResetted(vid)
  if vid == be:getPlayerVehicleID(0) then
    extensions.hook("onDriftPlVehReset")
  end
end

local function imguiDebug()
  if gameplay_drift_general.getGeneralDebug() then

    if im.Begin("Drift general") then
      im.PushStyleColor2(im.Col_Text, imVec4Red)
      if im.Button("Exit debug") then setDebug(false) end
      im.PopStyleColor()
      im.SameLine()
      if im.Button("Reset drift") then reset() end

      im.Dummy(im.ImVec2(1, 7))

      im.Text("Drift context : ")

      local s = ""
      for _, n in ipairs(contextList) do
        s = s .. tostring(n) .. "\0"
      end

      local contextIndex = tableFindKey(contextList, context)
      if contextIndex then
        local presetPtr = im.IntPtr(contextIndex - 1)
        if im.Combo2("", presetPtr, s) then
          setContext(contextList[presetPtr[0]+1])
        end

        im.Dummy(im.ImVec2(1, 10))

        if context == "inChallenge" then
          im.Text("Challenge mode : ")

          s = ""
          for _, n in ipairs(challengeModeList) do
            s = s .. tostring(n) .. "\0"
          end

          local challengeModeIndex = tableFindKey(challengeModeList, challengeMode)
          if challengeModeIndex then
            presetPtr = im.IntPtr(challengeModeIndex - 1)
            if im.Combo2("##"..'t', presetPtr, s) then
              setChallengeMode(challengeModeList[presetPtr[0]+1])
            end
            im.Dummy(im.ImVec2(1, 10))
          end
        end
      end

      im.Separator()

      im.Text("Loaded drift extensions : ")
      if im.BeginTable("Loaded extensions", 3, nil) then
        im.TableSetupColumn("Extension name", im.TableColumnFlags_WidthStretch, 10)
        im.TableSetupColumn("Debug", im.TableColumnFlags_WidthStretch, 4)
        im.TableSetupColumn("GC", im.TableColumnFlags_WidthStretch, 4)
        im.TableNextColumn()
        im.Text("Extension name")
        im.TableNextColumn()
        im.Text("Debug")
        im.TableNextColumn()
        im.Text("GC")
        im.TableNextColumn()

        for extensionName, extensionData in pairs(loadedExtensions) do
          if extensionData.loaded then
            im.Text(string.gsub(extensionName, "^gameplay_drift_", ""))
            im.TableNextColumn()
            if not extensionData.driftDebugInfo.canBeChanged then
              im.BeginDisabled()
            end
            local boolPtr = im.BoolPtr(extensionData.driftDebugInfo.default)
            if im.Checkbox("##"..extensionName, boolPtr) then
              extensionData.driftDebugInfo.default = boolPtr[0]
            end
            if not extensionData.driftDebugInfo.canBeChanged then
              im.EndDisabled()
            end

            im.TableNextColumn()

            if _G[extensionName] and _G[extensionName].getGC then
              im.Text(tostring(_G[extensionName].getGC()))
            else
              im.Text("nan")
            end
            im.TableNextColumn()

          end
        end
        im.EndTable()
      end

      im.Separator()

      im.Text("Paused : " .. tostring(paused))
      im.Text("Frozen : " .. tostring(frozen))
    end
    im.End()
  end
end

local function checkFrozen()
  local outOfBounds = false
  local goingWrongWay = false
  local isInTheConculdingPhase = false

  if gameplay_drift_destination then
    goingWrongWay = gameplay_drift_destination.getGoingWrongWay()
  end
  if gameplay_drift_bounds then
    outOfBounds = gameplay_drift_bounds.getIsOutOfBounds()
  end

  if gameplay_drift_freeroam_driftSpots then
    isInTheConculdingPhase = gameplay_drift_freeroam_driftSpots.getIsInTheConcludingPhase()
  end
  frozen = outOfBounds or goingWrongWay or isInTheConculdingPhase
end

local function loadSoundExtension(value)
  if value then
    extensions.load("gameplay_drift_sounds")
  else
    extensions.unload("gameplay_drift_sounds")
  end
  checkLoadedExtensions()
end

local function checkIfSoundShouldPlay()
  if getIsThereAnyDriftUIAppDisplayed() then
    if not gameplay_drift_sounds then
      loadSoundExtension(true)
    end
  else
    if gameplay_drift_sounds then
      loadSoundExtension(false)
    end
  end
end

local function checkCruisingExtension()
  local shouldBeLoaded = (context == "inFreeroam" or context == "inFreeroamCruising")
    and not (career_career and career_career.isActive and career_career.isActive())
    and settings.getValue("enableDriftFreeroamCruising")
    and gameplay_discover_freeroamTutorial_tutorial == nil

  if shouldBeLoaded and not gameplay_drift_freeroam_cruising then
    extensions.load("gameplay_drift_freeroam_cruising")
    checkLoadedExtensions()
  elseif not shouldBeLoaded and gameplay_drift_freeroam_cruising then
    if context == "inFreeroamCruising" then
      context = "inFreeroam"
    end
    extensions.unload("gameplay_drift_freeroam_cruising")
    checkLoadedExtensions()
  end
end

local function onUpdate()
  imguiDebug()
  checkIfSoundShouldPlay()
  checkCruisingExtension()
  checkFrozen()
end

-- hook fired when level is loaded (cough)
local function onClientPostStartMission()
  local missionId = gameplay_missions_missionManager.getForegroundMissionId()
  if not missionId then
    setContext("inFreeroam") -- don't set context if a mission is running
    reset()
  end
end

local function onSerialize()
  return {
    debugFlag = debugFlag,
    context = context,
    challengeMode = challengeMode,
  }
end

local function onDeserialized(data)
  debugFlag = data.debugFlag
  context = data.context
  challengeMode = data.challengeMode
end

local function onExtensionLoaded()
  driftExtensions = FS:findFiles("/lua/ge/extensions/gameplay/drift", '*.lua', -1, false, false)
  -- the UI app can persist across a GE lua reload (it doesn't remount), so it won't re-announce on its own.
  -- ask it to (re)report whether it's mounted. harmless if no app is listening.
  guihooks.trigger("onDriftRequestAppMountedState")
end

local function onDriftAppMounted()
  driftAppMounted = true
end

local function onDriftAppUnmounted()
  driftAppMounted = false
end

local function onMPSessionChanged(old, new)
  if not old and new then
    extensions.load("gameplay_drift_multiplayer")
  elseif old and not new then
    extensions.unload("gameplay_drift_multiplayer")
  end
end

local function onClientEndMission()
  setContext("inFreeroam")
end

M.reset = reset
M.clear = clear

M.setChallengeMode = setChallengeMode
M.getChallengeMode = getChallengeMode
M.getMultiplayerEnabled = getMultiplayerEnabled

M.getExtensionDebug = getExtensionDebug
M.getGeneralDebug = getGeneralDebug
M.getContext = getContext
M.getFrozen = getFrozen
M.getPaused = getPaused
M.getDriftDebugInfo = getDriftDebugInfo
M.getIsThereAnyDriftUIAppDisplayed = getIsThereAnyDriftUIAppDisplayed
M.setDebug = setDebug
M.setContext = setContext
M.setPaused = setPaused

M.onVehicleResetted = onVehicleResetted
M.onAnyMissionChanged = onAnyMissionChanged
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded

M.onClientEndMission = onClientEndMission
M.onClientPostStartMission = onClientPostStartMission
M.onDriftAppMounted = onDriftAppMounted
M.onDriftAppUnmounted = onDriftAppUnmounted
M.onMPSessionChanged = onMPSessionChanged
return M