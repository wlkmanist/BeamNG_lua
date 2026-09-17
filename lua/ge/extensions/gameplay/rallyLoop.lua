-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- extension name: gameplay_rallyLoop
-- This extension also publishes the shared rallyLoop UI stream for standalone
-- rally stages. In that mode no RallyLoopManager exists; the fallback stream is
-- only a compatibility bridge for countdown, timing, and progress UI data.
--
-- quick jumps
-- be:getPlayerVehicle(0):setPositionRotation(-1147.013672, 1618.314819, 152.612701, 0.000868, -0.001071, 0.628138, 0.778101) -- TINY
-- be:getPlayerVehicle(0):setPositionRotation(-1143.101685, 1623.638062, 152.612350, 0.000000, 0.000000, 0.628651, 0.777687) -- LOOP 1
-- be:getPlayerVehicle(0):setPositionRotation(-1149.058838, 1657.048828, 152.612350, 0.000000, 0.000000, 0.633423, 0.773806) -- NGRC 25
-- be:getPlayerVehicle(0):setPositionRotation(-1133.770752, 1620.473999, 152.612640, -0.002488, 0.001877, 0.627965, 0.778236) -- ONE STAGE LOOP
-- create:
-- local veh = be:getPlayerVehicle(0); if veh then local pos = veh:getPosition(); local rot = veh:getRotation(); print(string.format("be:getPlayerVehicle(0):setPositionRotation(%f, %f, %f, %f, %f, %f, %f)", pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)) end

local im  = ui_imgui

-- local ExtHelper = require('/lua/ge/extensions/gameplay/rally/extHelper')
local LoopToolbox = require('/lua/ge/extensions/gameplay/rally/tools/loopToolbox')
local RallyLoopManager = require('/lua/ge/extensions/gameplay/rally/loop/rallyLoopManager')
local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local RallyAttempts = require('/lua/ge/extensions/gameplay/rally/loop/rallyAttempts')
local StandaloneFallbackStream = require('/lua/ge/extensions/gameplay/rally/loop/standaloneFallbackStream')

local logTag = ''

local M = {}

------------------------------
-- debug variables

-- local debugLogging = true
local debugLogging = false

-- local showLoopToolbox = im.BoolPtr(true)
local showLoopToolbox = im.BoolPtr(false)

-- end debug variables
------------------------------

local loopToolbox = nil

local rallyLoopManager = nil
local streamData = nil

local function setup(missionId, missionDir)
  rallyLoopManager = RallyLoopManager(missionId, missionDir)
  StandaloneFallbackStream.clear()
end

local function unload()
  -- Time-of-day is restored by missionManager when the mission stops.
  rallyLoopManager = nil
  StandaloneFallbackStream.clear()
end

local function isReady()
  if rallyLoopManager then
    return true
  end

  return false
end

local function getRuntimeMode()
  if rallyLoopManager then
    return 'rallyLoop'
  end
  if StandaloneFallbackStream.isActive() then
    return 'standaloneUiBridge'
  end
  return 'idle'
end

-- local function enableDebugWindow(val)
--   if val then
--     showDebugWindow[0] = true
--   else
--     showDebugWindow[0] = false
--   end
-- end

local function onUpdate(dtReal, dtSim, dtRaw)
  profilerPushEvent("gameplay_rallyLoop - onUpdate")

  if rallyLoopManager then
    rallyLoopManager:onUpdate(dtReal, dtSim, dtRaw)

    -- Send stream data to UI
    streamData = rallyLoopManager:getStreamData()
    if streamData then
      guihooks.queueStream("rallyLoop", streamData)
    end
  else
    StandaloneFallbackStream.updateClock(dtSim or 0)
    streamData = StandaloneFallbackStream.getStreamData()
    guihooks.queueStream("rallyLoop", streamData)
  end

  -- gcprobe()
  if showLoopToolbox[0] then
    if not loopToolbox then
      loopToolbox = LoopToolbox()
    end
    im.Begin("Loop Toolbox", showLoopToolbox)
      loopToolbox:draw(rallyLoopManager)
    im.End()
  else
    if loopToolbox then
      loopToolbox = nil
    end
  end
  -- gcprobe()

  profilerPopEvent("gameplay_rallyLoop - onUpdate")
end

local function onGuiUpdate(dtReal, dtSim, dtRaw)
  profilerPushEvent("gameplay_rallyLoop - onGuiUpdate")

  if rallyLoopManager then
    rallyLoopManager:onGuiUpdate(dtReal, dtSim, dtRaw)
  end

  profilerPopEvent("gameplay_rallyLoop - onGuiUpdate")
end

-- local function onVehicleResetted(vehicleID)
-- end

-- local function onVehicleSwitched(oid, nid, player)
  -- log('D', logTag, 'onVehicleSwitched')
-- end

-- local function onVehicleSpawned(vid, v)
  -- log('D', logTag, 'onVehicleSpawned')
-- end

-- local function onVehicleActiveChanged(vehicleID, active)
  -- log('D', logTag, 'onVehicleActiveChanged')
-- end

local function onExtensionLoaded()
  if debugLogging then log('D', logTag, 'onExtensionLoaded') end
  -- ExtHelper.load()

  if debugLogging then log('I', logTag, 'gameplay_rallyLoop extension loaded') end
  -- guihooks.trigger('rally.onExtensionLoaded', {})
end

local function onExtensionUnloaded()
  if debugLogging then log('D', logTag, 'onExtensionUnloaded') end
  -- ExtHelper.unload()
  -- Time-of-day is restored by missionManager when the mission stops.

  -- Send inactive state to UI before unloading
  streamData = {
    activeState = RallyUtil.activeState_inactive,
  }
  StandaloneFallbackStream.clear()

  guihooks.queueStream("rallyLoop", streamData)

  if debugLogging then log('I', logTag, 'gameplay_rallyLoop extension unloaded') end
end

local function onSettingsChanged()
  if rallyLoopManager and rallyLoopManager.onSettingsChanged then
    rallyLoopManager:onSettingsChanged()
  end

  StandaloneFallbackStream.onSettingsChanged()
end

local function toggleDebug()
  showLoopToolbox[0] = not showLoopToolbox[0]

  if not loopToolbox then
    loopToolbox = LoopToolbox()
  end
end

local function getLoopToolbox()
  return loopToolbox
end

local function drawDebug(zOnTop, drawRoute, drawLabels)
  if rallyLoopManager then
    rallyLoopManager:drawDebug(zOnTop, drawRoute, drawLabels)
  end
end

M.onRallyDataUpdated = function(data)
  if rallyLoopManager then
    rallyLoopManager:onRallyDataUpdated(data)
  else
    StandaloneFallbackStream.updateStreamData(data)
  end
end

M.onGameplayInteract = function()
  -- log('D', logTag, 'rallyLoop onGameplayInteract')
  -- guihooks.trigger('Message', {msg = 'you pressed [action=gameplay_interact]', ttl = 1})
  if rallyLoopManager then
    rallyLoopManager:onRallyModeInteract()
  end
end

M.onUIStartButtonClicked = function()
  if rallyLoopManager then
    rallyLoopManager:onUIStartButtonClicked()
  end
end

M.onRecalculatedRoute = function()
  if rallyLoopManager then
    rallyLoopManager:onRecalculatedRoute()
  end
end

M.onCreatedRallyGroundMarkerRoute = function()
  if rallyLoopManager then
    rallyLoopManager:onCreatedRallyGroundMarkerRoute()
  end
end

M.onRallyVehicleRecovery = function(recoveryType)
  if rallyLoopManager then
    rallyLoopManager:trackRecovery(recoveryType)
  end
end

M.onRallyRouteRecoveryComplete = function(data)
  if rallyLoopManager and rallyLoopManager.onRallyRouteRecoveryComplete then
    rallyLoopManager:onRallyRouteRecoveryComplete(data)
  end
end

--
-- extension hooks API
--
M.onUpdate = onUpdate
M.onGuiUpdate = onGuiUpdate
-- M.onVehicleResetted = onVehicleResetted
-- M.onVehicleSpawned = onVehicleSpawned
-- M.onVehicleSwitched = onVehicleSwitched
-- M.onVehicleActiveChanged = onVehicleActiveChanged
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onSettingsChanged = onSettingsChanged

--
-- gameplay_rallyLoop API
--
M.isReady = isReady
M.getRuntimeMode = getRuntimeMode
M.setup = setup
M.unload = unload

M.getDebugLogging = function() return debugLogging end
M.setDebugLogging = function(val) debugLogging = val end

M.toggleDebug = toggleDebug
M.getLoopToolbox = getLoopToolbox
M.isLoopToolboxVisible = function() return showLoopToolbox[0] end

M.setupForNewMission = function()
  if rallyLoopManager then
    rallyLoopManager:setupForNewMission()
  end
end

M.setMissionExecutionTransferFlag = function(val)
  if rallyLoopManager then
    rallyLoopManager:setMissionExecutionTransferFlag(val)
  end
end
M.getMissionExecutionTransferFlag = function()
  if rallyLoopManager then
    return rallyLoopManager:getMissionExecutionTransferFlag()
  end
  return false
end

M.getNextMissionId = function()
  if rallyLoopManager then
    return rallyLoopManager:getNextMissionId()
  end
  return nil
end

M.startNextMission = function()
  if rallyLoopManager then
    return rallyLoopManager:startNextMission()
  end
  return false
end

M.skipLiaisonForTesting = function(options)
  if rallyLoopManager then
    return rallyLoopManager:skipLiaisonForTesting(options)
  end
  return false, 'no rally loop manager'
end

M.addTestPenalty = function(amount)
  if rallyLoopManager and rallyLoopManager.recordTestPenalty then
    return rallyLoopManager:recordTestPenalty(amount)
  end
  return false, 'no rally loop manager'
end

M.handleGOTO = function(gotoRallyLoop)
  if rallyLoopManager and gotoRallyLoop == 'restart' then
    log('D', logTag, 'rallyLoop handleGOTO: restart')
    rallyLoopManager:restartRallyLoop()
  elseif rallyLoopManager and gotoRallyLoop == 'abandon' then
    log('D', logTag, 'rallyLoop handleGOTO: abandon')
    rallyLoopManager:gotoRallyLoopInstant()
  elseif rallyLoopManager and gotoRallyLoop == 'postServiceIn' then
    log('D', logTag, 'rallyLoop handleGOTO: postServiceIn')
    rallyLoopManager:startNextMission()
  else
    log('D', logTag, 'rallyLoop handleGOTO: default case, gotoRallyLoop='..tostring(gotoRallyLoop))
    rallyLoopManager:startNextMission()
  end
end

-- M.onRecoveryPromptButtonPressed = function(buttonId)
--   log('I', logTag, 'rallyLoop onRecoveryPromptButtonPressed: '..buttonId)
-- end

M.onAnyMissionWillChange = function(state, mission, abandoned)
  local mgr = rallyLoopManager
  log('D', logTag, string.format('rallyLoop onAnyMissionWillChange mgr=%s, state=%s, mission=%s, abandoned=%s', tostring(not not mgr), state, mission and mission.id or 'nil', tostring(abandoned)))
  if mgr then
    mgr:clearTrafficExclusion()
    if state == 'stopped' and abandoned then
      -- Do not count attempt as abandon if we are still in serviceOut
      local currentMissionId = mgr:getCurrentMissionId()
      if currentMissionId ~= 'serviceOut' then
        RallyAttempts.createRallyLoopAttemptForDnf(mgr, 'abandon')
      else
        log('D', logTag, 'Not counting abandon in serviceOut as a DNF attempt')
      end
    end
  end
end

M.getManager = function()
  return rallyLoopManager
end

M.drawDebug = drawDebug

M.getDrawFlag = function(flagName)
  if rallyLoopManager then
    return rallyLoopManager:getDrawFlag(flagName)
  end
  return false
end

M.setDrawFlag = function(flagName, value)
  if rallyLoopManager then
    rallyLoopManager:setDrawFlag(flagName, value)
  end
end

M.getSSRescheduleCount = function()
  if rallyLoopManager then
    return rallyLoopManager:getSSRescheduleCount()
  end
  return 0
end

return M