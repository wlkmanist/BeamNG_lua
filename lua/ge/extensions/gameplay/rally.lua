-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- extension name: gameplay_rally


--'flipMission', 'recoverMission', 'submitMission', 'restartMission'
-- extensions.hook("onRecoveryPromptButtonPressed", 'restartMission')
-- extensions.hook("onRecoveryPromptButtonPressed", 'flipMission')
-- extensions.hook("onMissionScreenButtonClicked", { mgrId = core_flowgraphManager.getAllManagers()[0].id, funId = 1 })
-- gameplay_rally.setDebugLogging(true)
-- gameplay_rally.toggleDebug()


local im  = ui_imgui

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local RallyManager = require('/lua/ge/extensions/gameplay/rally/rallyManager')
local RecceApp = require('/lua/ge/extensions/gameplay/rally/recceApp')
local RallyToolbox = require('/lua/ge/extensions/gameplay/rally/tools/rallyToolbox')
local ExtHelper = require('/lua/ge/extensions/gameplay/rally/extHelper')
local voicepack = require('/lua/ge/extensions/gameplay/rally/voicepack')
local CodriverTiming = require('/lua/ge/extensions/gameplay/rally/codriverTiming')
local UiColors = require('/lua/ge/extensions/gameplay/rally/loop/uiColors')

local logTag = ''

local M = {}

local rallyManager = nil
local rallyManagerOwner = nil
local errorMsgForUser = nil

------------------------------
-- debug variables

local debugLogging = false
local showRallyToolbox = im.BoolPtr(false)

-- end debug variables
------------------------------

local rallyToolbox = nil
local theRace = nil

local function isFreeroam()
  return core_gamestate.state and core_gamestate.state.state == "freeroam"
end

local function getMissionVoicepackPick(missionId)
  local mission = gameplay_missions_missions and gameplay_missions_missions.getMissionById(missionId) or nil
  local userSettings = mission and mission.lastUserSettings or nil
  local value = userSettings and userSettings.rallyVoicepackPick or nil

  return voicepack.pickFromSettingValue(value)
end

local function getMissionBoolSetting(missionId, key, defaultValue)
  local mission = missionId and gameplay_missions_missions and gameplay_missions_missions.getMissionById(missionId) or nil
  local userSettings = mission and mission.lastUserSettings or nil
  local value = userSettings and userSettings[key]
  if value ~= nil then
    return value
  end

  if settings and settings.getValue then
    value = settings.getValue(key)
    if value ~= nil then
      return value
    end
  end

  return defaultValue
end

local function canManageMission(owner)
  owner = owner or 'external'
  if owner == 'mission' then
    return true
  end

  if owner == 'recce' and not isFreeroam() then
    return false, 'recce rally manager is only available in freeroam'
  end

  local foregroundMissionId = gameplay_missions_missionManager
    and gameplay_missions_missionManager.getForegroundMissionId
    and gameplay_missions_missionManager.getForegroundMissionId()
    or nil
  if foregroundMissionId then
    return false, string.format('rally manager is owned by foreground mission %s', foregroundMissionId)
  end
  if rallyManagerOwner == 'mission' then
    return false, 'rally manager is mission-owned'
  end
  return true
end

local function loadMission(missionId, missionDir, drivelineMode, voicepackPick, options)
  options = options or {}
  local owner = options.owner or 'external'
  local allowed, reason = canManageMission(owner)
  if not allowed then
    log('W', logTag, string.format('rejected rally manager load owner=%s missionId=%s: %s', owner, tostring(missionId), reason))
    return false, reason
  end

  errorMsgForUser = nil
  local newRallyManager = RallyManager(missionDir, missionId)
  newRallyManager:setVoicepackPick(voicepackPick or getMissionVoicepackPick(missionId))
  -- if drivelineMode then
  --   newRallyManager:setDrivelineMode(drivelineMode)
  -- end
  if not newRallyManager:rebuildAssets() then
    log('E', logTag, 'failed to load RallyManager')
    errorMsgForUser = newRallyManager:getErrorMsgForUser()
    return false, errorMsgForUser
  end
  rallyManager = newRallyManager
  rallyManagerOwner = owner
  return true
end

local function unloadMission(options)
  options = options or {}
  local owner = options.owner or 'external'
  local reason
  if rallyManagerOwner and rallyManagerOwner ~= owner then
    reason = string.format('rally manager is owned by %s', rallyManagerOwner)
    log('W', logTag, string.format('rejected rally manager unload owner=%s: %s', owner, reason))
    return false, reason
  end
  rallyManager = nil
  rallyManagerOwner = nil
  errorMsgForUser = nil
  return true
end

local function isReady()
  if rallyManager then
    return true
  end

  return false
end

local function enableRecceApp(val)
  RecceApp.setEnabled(val)
end

local function onUpdate(dtReal, dtSim, dtRaw)
  profilerPushEvent("gameplay_rally - onUpdate")

  -- gcprobe()
  RecceApp.onUpdate(dtReal, dtSim, dtRaw)
  -- gcprobe()

  -- gcprobe()
  if rallyManager and not RecceApp.isRecording() then
    rallyManager:onUpdate(dtReal, dtSim, dtRaw)
  end
  -- gcprobe()

  -- gcprobe()
  if rallyToolbox and showRallyToolbox[0] then
    im.Begin("Rally Toolbox", showRallyToolbox)
      rallyToolbox:draw()
    im.End()
  end
  -- gcprobe()

  profilerPopEvent("gameplay_rally - onUpdate")
end

-- local function onGuiUpdate(dtReal, dtSim, dtRaw)
-- end

local function onVehicleResetted(vehicleID)
  if vehicleID ~= be:getPlayerVehicleID(0) then return end

  if debugLogging then log('D', logTag, '>>> gameplay_rally VEHICLE RESET ENTRYPOINT <<<') end
  if debugLogging then log('D', logTag, 'onVehicleResetted') end

  if rallyManager then
    rallyManager:onVehicleResetted()
  end
end

local function onVehicleSwitched(oid, nid, player)
  -- log('D', logTag, 'onVehicleSwitched')
end

local function onVehicleSpawned(vid, v)
  -- log('D', logTag, 'onVehicleSpawned')
end

local function onVehicleActiveChanged(vehicleID, active)
  -- log('D', logTag, 'onVehicleActiveChanged')
end

local function onExtensionLoaded()
  if debugLogging then log('D', logTag, 'onExtensionLoaded') end
  ExtHelper.load()
  if debugLogging then log('I', logTag, 'gameplay_rally extension loaded') end
  guihooks.trigger('rally.onExtensionLoaded', {})
end

local function onExtensionUnloaded()
  if debugLogging then log('D', logTag, 'onExtensionUnloaded') end
  ExtHelper.unload()
  if debugLogging then log('I', logTag, 'gameplay_rally extension unloaded') end
end

local function isRecceAppLoaded()
  if not RecceApp then return end
  return RecceApp.isEnabled()
end

M.actionToggleMouseLikeVehicle = function()
  if not isRecceAppLoaded() then return end
  RecceApp.toggleMouseLikeVehicle()
end

M.actionTranscribeRecordingCut = function()
  guihooks.trigger('rallyInputActionCutRecording')
end

M.actionRecceMoveVehicleForward = function()
  if not isRecceAppLoaded() then return end
  guihooks.trigger('rallyInputActionRecceMoveVehicleForward')
end

M.actionRecceMoveVehicleBackward = function()
  if not isRecceAppLoaded() then return end
  guihooks.trigger('rallyInputActionRecceMoveVehicleBackward')
end

-- M.actionCodriverVolumeUp = function()
--   guihooks.trigger('rallyInputActionCodriverVolumeUp')
-- end

-- M.actionCodriverVolumeDown = function()
--   guihooks.trigger('rallyInputActionCodriverVolumeDown')
-- end

local function changeCodriverTiming(higher)
  local tick = higher and 0.1 or -0.1
  -- shift both ends of the delay range together (min = setting, max persisted to json)
  local newMin, newMax = CodriverTiming.nudge(tick)
  local msg = _tr('ui.rally.codriverTiming', 'Co-driver timing')
  guihooks.trigger('Message', {
    ttl = 5,
    msg = string.format('%s: %.1fs', msg, newMin),
    category = 'rally',
  })
end

local function toggleDebug()
  showRallyToolbox[0] = not showRallyToolbox[0]

  if not rallyToolbox then
    rallyToolbox = RallyToolbox()
  end

  -- if showRallyToolbox[0] and rallyManager and rallyToolbox then
  --   rallyToolbox:setDrivelineMode(rallyManager:getDrivelineMode())
  -- end
end

local function getRallyToolbox()
  return rallyToolbox
end

M.actionCodriverCallsEarlier = function()
  changeCodriverTiming(false)
end

M.actionCodriverCallsLater = function()
  changeCodriverTiming(true)
end

-- race hooks
-- M.onRaceStarted = function(event)
--   log('W', logTag, 'onRaceStarted')
-- end

M.onRacePathnodeReached = function(event)
  -- log('I', logTag, 'onRacePathnodeReached')
  local pathnode = event.pathnode
  local time = event.time
  -- local race = event.race
  if pathnode and rallyManager then
    -- log('D', logTag, string.format('Rally.onRacePathnodeReached name=%s id=%d time=%0.1f', pathnode.name, pathnode.id, time))
    rallyManager:recordSplit(pathnode.id, time)


    -- local splitPathnode = rallyManager:getSplitPathnode(pathnode.name)
    -- if splitPathnode then
    --   local rp = splitPathnode:getRoutePoint()
    --   if rp then
    --     local md = rp.metadata
    --     if md then
    --       local source = md.source
    --       local racePathnodeType = md.racePathnodeType
    --       if source and racePathnodeType then
    --         local distance = rallyManager:getPointDistanceFromStartKm(rp)
    --         -- log('W', logTag, string.format('pathnode route point source=%s racePathnodeType=%s distance=%.1fkm', source, racePathnodeType, distance))
    --         if debugLogging then log('D', logTag, string.format('RallyMode: reached %s (%s %.1fkm)', pathnode.name, racePathnodeType, distance)) end
    --       else
    --         if debugLogging then log('W', logTag, 'no source or racePathnodeType in onRacePathnodeReached') end
    --       end
    --     else
    --       if debugLogging then log('W', logTag, 'no metadata in onRacePathnodeReached') end
    --     end
    --   else
    --     if debugLogging then log('W', logTag, 'no route point in onRacePathnodeReached') end
    --   end
    -- else
    --   if debugLogging then log('D', logTag, string.format('onRacePathnodeReached name=%s split=%s', pathnode.name, tostring(pathnode.useAsSplit))) end
    -- end
  else
    -- if debugLogging then
      log('W', logTag, 'no pathnode in onRacePathnodeReached')
    -- end
  end
end

-- M.onRaceComplete = function(event)
--   log('W', logTag, 'onRaceComplete')
--   dumpz(event, 2)
-- end

-- M.onRaceAborted = function(event)
--   log('W', logTag, 'onRaceAborted')
--   dumpz(event, 2)
-- end

-- -- rally hooks
-- M.onRallySessionStart = function()
--   log('W', logTag, 'onRallySessionStart')
-- end

-- M.onRallyStageStart = function()
--   log('W', logTag, 'onRallyStageStart')
-- end

M.onRallyRegisterRace = function(raceData)
  if debugLogging then log('D', logTag, 'onRallyRegisterRace raceData='..dumpsz(raceData,1)) end
  theRace = raceData
  if rallyManager then
    rallyManager:setRaceData(raceData)
  end
end

M.onRallyVehicleRecovery = function(recoveryType)
  if rallyManager and rallyManager.addRecoveryRaceTime then
    rallyManager:addRecoveryRaceTime(recoveryType)
  end
end

-- M.onRallyStageFlyingFinish = function()
--   log('W', logTag, 'onRallyStageFlyingFinish')
-- end

-- M.onRallyStageComplete = function()
--   log('W', logTag, 'onRallyStageComplete')
-- end

-- M.onRallySessionEnd = function()
--   log('W', logTag, 'onRallySessionEnd')
-- end

-- extension hooks
M.onUpdate = onUpdate
-- M.onGuiUpdate = onGuiUpdate
M.onVehicleResetted = onVehicleResetted
-- M.onVehicleSpawned = onVehicleSpawned
-- M.onVehicleSwitched = onVehicleSwitched
-- M.onVehicleActiveChanged = onVehicleActiveChanged
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onSettingsChanged = function()
  if rallyManager then
    rallyManager:onSettingsChanged()
  end
end

-- rally API
M.enableRecceApp = enableRecceApp
M.loadMission = loadMission
M.unloadMission = unloadMission
M.canManageMission = canManageMission

M.isReady = isReady
M.getRallyManager = function() return rallyManager end
M.getRallyManagerOwner = function() return rallyManagerOwner end
M.getErrorMsgForUser = function() return errorMsgForUser end
M.getRecoveryRepairVehicle = function()
  local loopManager = gameplay_rallyLoop and gameplay_rallyLoop.getManager and gameplay_rallyLoop.getManager()
  if loopManager and loopManager.getRecoveryRepairVehicle then
    return loopManager:getRecoveryRepairVehicle()
  end
  local missionId = rallyManager and rallyManager.missionId
  if not missionId and gameplay_missions_missionManager then
    missionId = gameplay_missions_missionManager.getForegroundMissionId()
  end
  return getMissionBoolSetting(missionId, 'rallyRepairVehicleOnRecovery', true)
end
M.setStageRuntimeAuthorityMode = function(mode)
  if rallyManager and rallyManager.setStageRuntimeAuthorityMode then
    rallyManager:setStageRuntimeAuthorityMode(mode)
  end
end
M.getStageRuntimeAuthorityMode = function()
  return rallyManager and rallyManager.getStageRuntimeAuthorityMode and rallyManager:getStageRuntimeAuthorityMode() or 'shadow'
end
M.getStageObserverState = function()
  return rallyManager and rallyManager.getStageObserverState and rallyManager:getStageObserverState() or nil
end

M.recceApp = RecceApp
M.getDebugLogging = function() return debugLogging end
M.setDebugLogging = function(val) debugLogging = val end

-- Override rallyLoop stream theme (Stage Timing / Progress). Clear with nil/"".
-- gameplay_rally.setUiColor("#ff0000")
-- gameplay_rally.setUiColor()
local function resolveStreamTheme()
  local override = UiColors.getThemeOverride()
  if override then return override end

  local manager = gameplay_rallyLoop and gameplay_rallyLoop.getManager and gameplay_rallyLoop.getManager() or nil
  if manager and manager.uiColors then
    UiColors.updateForLoop(manager.uiColors, manager.isNgrcMode == true)
    return manager.uiColors.theme
  end

  local ok, Standalone = pcall(require, '/lua/ge/extensions/gameplay/rally/loop/standaloneFallbackStream')
  if ok and Standalone and type(Standalone.getStreamData) == "function" then
    local okSd, sd = pcall(Standalone.getStreamData)
    if okSd and sd and sd.uiColors and sd.uiColors.theme then
      return sd.uiColors.theme
    end
  end

  return "#009a1a"
end

M.setUiColor = function(hex)
  UiColors.setThemeOverride(hex)
end
M.getUiColor = function()
  return resolveStreamTheme()
end
M.getUiColorOverride = function()
  return UiColors.getThemeOverride()
end

M.toggleDebug = toggleDebug
M.getRallyToolbox = getRallyToolbox
M.isRallyToolboxVisible = function() return showRallyToolbox[0] end

M.getRace = function() return theRace end

return M



-- lua/ge/main.lua|399 col 3| extensions.hook('onClientPreStartMission', levelPath)
-- lua/ge/main.lua|408 col 3| extensions.hook('onClientPostStartMission', levelPath)
-- lua/ge/main.lua|414 col 3| extensions.hookNotify('onClientStartMission', levelPath)
-- lua/ge/main.lua|425 col 3| extensions.hookNotify('onClientEndMission', levelPath)
-- lua/ge/main.lua|434 col 3| extensions.hook('onEditorEnabled', enabled)
-- lua/ge/main.lua|451 col 3| extensions.hook('onPreRender', dtReal, dtSim, dtRaw)
-- lua/ge/main.lua|454 col 3| extensions.hook('onDrawDebug', Lua.lastDebugFocusPos, dtReal, dtSim, dtRaw)
-- lua/ge/main.lua|475 col 7| extensions.hook('onWorldReadyState', worldReadyState)
-- lua/ge/main.lua|483 col 3| extensions.hook('onFirstUpdate')
-- lua/ge/main.lua|504 col 3| extensions.hook('onUpdate', dtReal, dtSim, dtRaw)
-- lua/ge/main.lua|507 col 5| extensions.hook('onGuiUpdate', dtReal, dtSim, dtRaw)
-- lua/ge/main.lua|523 col 3| extensions.hook('onUiReady')
-- lua/ge/main.lua|563 col 3| extensions.hook('onBeamNGWaypoint', args)
-- lua/ge/main.lua|568 col 3| extensions.hook('onBeamNGTrigger', data)
-- lua/ge/main.lua|575 col 3| extensions.hook('onFilesChanged', files)
-- lua/ge/main.lua|579 col 5| extensions.hook('onFileChanged', v.filename, v.type)
-- lua/ge/main.lua|581 col 3| extensions.hook('onFileChangedEnd')
-- lua/ge/main.lua|586 col 3| extensions.hook('onPhysicsEngineEvent', args)
-- lua/ge/main.lua|599 col 3| extensions.hook('onVehicleSpawned', vid, v)
-- lua/ge/main.lua|610 col 3| extensions.hook('onVehicleSwitched', oid, nid, player)
-- lua/ge/main.lua|615 col 3| extensions.hook('onVehicleResetted', vehicleID)
-- lua/ge/main.lua|621 col 3| extensions.hook('onVehicleActiveChanged', vehicleID, active)
-- lua/ge/main.lua|625 col 3| extensions.hook('onMouseLocked', locked)
-- lua/ge/main.lua|630 col 3| extensions.hook('onVehicleDestroyed', vid)
-- lua/ge/main.lua|641 col 3| extensions.hook('onCouplerAttached', objId1, objId2, nodeId, obj2nodeId)
-- lua/ge/main.lua|645 col 3| extensions.hook('onCouplerDetached', objId1, objId2, nodeId, obj2nodeId)
-- lua/ge/main.lua|653 col 3| extensions.hook('onCouplerDetach', objId, nodeId)
-- lua/ge/main.lua|657 col 3| extensions.hook('onAiModeChange', vehicleID, newAiMode)
-- lua/ge/main.lua|707 col 5| extensions.hook('onPhysicsUnpaused')
-- lua/ge/main.lua|709 col 5| extensions.hook('onPhysicsPaused')
-- lua/ge/main.lua|739 col 3| extensions.hook('onResetGameplay', playerID)
-- lua/ge/main.lua|804 col 3| extensions.hook('onPreWindowClose')
-- lua/ge/main.lua|808 col 3| extensions.hook('onPreExit')
-- lua/ge/main.lua|813 col 5| extensions.hook('onExit')
