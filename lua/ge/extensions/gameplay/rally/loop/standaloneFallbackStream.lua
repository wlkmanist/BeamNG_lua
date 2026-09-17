-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local UiColors = require('/lua/ge/extensions/gameplay/rally/loop/uiColors')

local M = {}

local fallbackStreamData = nil
local fallbackLastUpdateTime = nil
local fallbackCountdownHoldUntil = 0
local fallbackFreshTime = 0.75
local fallbackGoDisplayTime = 0.1
local fallbackGoHoldUntil = nil
local fallbackClockFromNode = false
local fallbackClockSecs = nil
local fallbackStageResetActive = false
local showStageApps = nil

local standaloneUiColors = {}

local function shallowCopy(tbl)
  if not tbl then return nil end
  local res = {}
  for k, v in pairs(tbl) do
    res[k] = v
  end
  return res
end

local function getNow()
  return RallyUtil.getTime and RallyUtil.getTime() or os.clockhp()
end

local function resolveShowStageApps()
  if settings and settings.getValue then
    local value = settings.getValue('rallyShowStageApps')
    if value ~= nil then
      return value
    end
  end

  return true
end

local function getShowStageApps()
  if showStageApps == nil then
    showStageApps = resolveShowStageApps()
  end
  return showStageApps ~= false
end

local function onSettingsChanged()
  showStageApps = resolveShowStageApps()
end

local function getStandaloneIsNgrcMode()
  if gameplay_rally and gameplay_rally.getRecoveryRepairVehicle then
    return not gameplay_rally.getRecoveryRepairVehicle()
  end
  return false
end

local function getStandaloneWallClockTime()
  if not core_environment or not core_environment.getTimeOfDay then return nil end
  local tod = core_environment.getTimeOfDay()
  if not tod or not tod.time then return nil end

  local wallClockSecs = ((tod.time + 0.5) % 1) * 86400
  return RallyUtil.formatTime24Hour(wallClockSecs, true, false)
end

local function getStandaloneStageData()
  if not gameplay_rally or not gameplay_rally.getRallyManager then return nil end

  local rm = gameplay_rally.getRallyManager()
  if rm and rm.getActiveStageData then
    return rm:getActiveStageData()
  end

  return nil
end

local function getStandaloneMissionName()
  if not gameplay_rally or not gameplay_rally.getRallyManager then return nil end

  local rm = gameplay_rally.getRallyManager()
  if rm and rm.getMissionName then
    return rm:getMissionName()
  end

  return nil
end

local function getStandaloneResetSplits(stageData)
  local splits = stageData and stageData.splits
  local resetSplits = {}

  if splits then
    for _, split in ipairs(splits) do
      local resetSplit = {}
      for k, v in pairs(split) do
        if k ~= 'time' then
          resetSplit[k] = v
        end
      end
      table.insert(resetSplits, resetSplit)
    end
  end

  if #resetSplits == 0 then
    table.insert(resetSplits, {pathnodeType = 'reset'})
  end

  return resetSplits
end

local function getStandaloneResetStageData(stageData)
  local completion = stageData and stageData.completion or {}
  local stageHeader = getStandaloneMissionName()
  return {
    currentSSTime = 0,
    isActive = false,
    isComplete = false,
    splits = getStandaloneResetSplits(stageData),
    label = stageData and stageData.label or stageHeader,
    stageHeader = stageHeader,
    completion = {
      distM = 0,
      totalDistM = completion.totalDistM or completion.distM or 0,
      distPct = 0
    },
    unit = stageData and stageData.unit or 'km'
  }
end

local function getStandaloneStageStreamData(stageData)
  if not stageData then return nil end

  local streamStageData = shallowCopy(stageData)
  streamStageData.stageHeader = getStandaloneMissionName()
  return streamStageData
end

local function getStandaloneScheduleData(stageData, activeState, vehicleProximity)
  local isPostFinishProximity = stageData and stageData.isComplete and activeState == RallyUtil.activeState_vehicleProximity and vehicleProximity ~= nil

  local scheduleData = {
    label = nil,
    eventType = nil,
    ssLabel = nil,
    eventWallClockStart = nil,
    eventWallClockEnd = nil,
    timeDiff = nil,
    timeDiffWithEnd = nil,
    lateness = nil,
    penalty = 0,
    hasPenalty = false,
    canIncurLatePenalty = false,
    speedLimit = nil,
    speedLimitDisplay = nil,
    speedUnit = 'km/h',
    isSpeeding = false
  }

  if isPostFinishProximity then
    scheduleData.label = 'Stop Control'
    scheduleData.eventType = 'ss_stop'
  end

  return scheduleData
end

local function getStandaloneResetStreamData()
  local stageData = getStandaloneStageData()
  local isNgrcMode = getStandaloneIsNgrcMode()
  UiColors.updateForStage(standaloneUiColors, isNgrcMode)
  return {
    activeState = RallyUtil.activeState_countdown,
    rallyClock = nil,
    stageData = getStandaloneResetStageData(stageData),
    scheduleData = getStandaloneScheduleData(),
    vehicleProximity = nil,
    countdownData = nil,
    showStageApps = getShowStageApps(),
    uiColors = standaloneUiColors,
  }
end

local function clear()
  fallbackStreamData = nil
  fallbackLastUpdateTime = nil
  fallbackCountdownHoldUntil = 0
  fallbackGoHoldUntil = nil
  fallbackClockFromNode = false
  fallbackClockSecs = nil
  fallbackStageResetActive = false
end

local function isActive()
  return fallbackStreamData ~= nil or getStandaloneStageData() ~= nil
end

local function updateClock(dtSim)
  if fallbackClockSecs then
    fallbackClockSecs = (fallbackClockSecs + dtSim) % 86400
  end
end

local function getStreamData(now)
  now = now or getNow()

  local stageData = getStandaloneStageData()
  local stageActive = stageData and stageData.isActive
  local stagePresent = stageData and not stageData.isComplete
  local stageComplete = stageData and stageData.isComplete
  local streamFresh = fallbackStreamData and fallbackLastUpdateTime and now - fallbackLastUpdateTime <= fallbackFreshTime
  local isNgrcMode = getStandaloneIsNgrcMode()
  UiColors.updateForStage(standaloneUiColors, isNgrcMode)

  if fallbackStreamData and (streamFresh or stageActive or stagePresent or (stageComplete and not fallbackStageResetActive)) then
    fallbackStreamData.rallyClock = fallbackStreamData.rallyClock or {}
    if fallbackClockSecs then
      fallbackStreamData.rallyClock.wallClockSecs = fallbackClockSecs
      fallbackStreamData.rallyClock.wallClockTime = RallyUtil.formatTime24Hour(fallbackClockSecs, true, false)
    elseif not fallbackClockFromNode then
      fallbackStreamData.rallyClock.wallClockTime = getStandaloneWallClockTime()
    end
    fallbackStreamData.rallyClock.canSkipTimeControls = false
    fallbackStreamData.rallyClock.isTimeControlSkipAvailable = false
    fallbackStreamData.rallyClock.canSkipCountdown = false
    fallbackStreamData.rallyClock.isNgrcMode = isNgrcMode

    if stageActive and now >= fallbackCountdownHoldUntil then
      fallbackStageResetActive = false
      fallbackStreamData.activeState = RallyUtil.activeState_stageActive
      fallbackStreamData.countdownData = nil
      fallbackStreamData.vehicleProximity = nil
    elseif stagePresent and fallbackStreamData.activeState ~= RallyUtil.activeState_countdown then
      fallbackStageResetActive = false
      fallbackStreamData.activeState = RallyUtil.activeState_stageActive
      fallbackStreamData.countdownData = nil
      fallbackStreamData.vehicleProximity = nil
    end
    fallbackStreamData.stageData = (stageData and not fallbackStageResetActive) and getStandaloneStageStreamData(stageData) or getStandaloneResetStageData(stageData)
    fallbackStreamData.scheduleData = getStandaloneScheduleData(stageData, fallbackStreamData.activeState, fallbackStreamData.vehicleProximity)
    fallbackStreamData.showStageApps = getShowStageApps()
    fallbackStreamData.uiColors = standaloneUiColors
    return fallbackStreamData
  end

  if stagePresent then
    return {
      activeState = RallyUtil.activeState_stageActive,
      rallyClock = {
        wallClockTime = getStandaloneWallClockTime(),
        canSkipTimeControls = false,
        isTimeControlSkipAvailable = false,
        canSkipCountdown = false,
        isNgrcMode = isNgrcMode
      },
      stageData = getStandaloneStageStreamData(stageData),
      scheduleData = getStandaloneScheduleData(),
      showStageApps = getShowStageApps(),
      uiColors = standaloneUiColors
    }
  end

  return {
    activeState = RallyUtil.activeState_inactive,
    stageData = getStandaloneResetStageData(stageData),
    scheduleData = getStandaloneScheduleData(),
    showStageApps = getShowStageApps(),
    uiColors = standaloneUiColors
  }
end

local function updateStreamData(data)
  if not data then return end

  if data.resetFallbackStreamData then
    clear()
    fallbackStageResetActive = true
    fallbackStreamData = getStandaloneResetStreamData()
  end

  local now = getNow()
  fallbackStreamData = fallbackStreamData or {
    activeState = RallyUtil.activeState_inactive,
  }
  fallbackLastUpdateTime = now

  local incomingCountdown = data.activeState == RallyUtil.activeState_countdown or data.countdownData ~= nil
  local incomingNonCountdownOnly = data.activeState ~= nil and data.activeState ~= RallyUtil.activeState_countdown and data.countdownData == nil
  local countdownProtected = fallbackStreamData.activeState == RallyUtil.activeState_countdown and now < fallbackCountdownHoldUntil
  local previousCountdownData = fallbackStreamData.countdownData
  local incomingGoCountdown = data.countdownData and data.countdownData.countdown == 0

  if data.activeState and not (incomingNonCountdownOnly and countdownProtected) then
    fallbackStreamData.activeState = data.activeState
  end

  if data.vehicleProximity then
    fallbackStreamData.vehicleProximity = shallowCopy(data.vehicleProximity)
    fallbackStreamData.vehicleProximity.isStartLine = data.vehicleProximity.isStartLine or false
    fallbackStreamData.vehicleProximity.isOverLineAllowed = data.vehicleProximity.isOverLineAllowed or false
  end

  if data.countdownData then
    fallbackStreamData.countdownData = shallowCopy(data.countdownData)
  elseif data.activeState and data.activeState ~= RallyUtil.activeState_countdown and not countdownProtected then
    fallbackStreamData.countdownData = nil
    fallbackGoHoldUntil = nil
  end

  if data.rallyClock then
    fallbackStreamData.rallyClock = shallowCopy(data.rallyClock)
    fallbackClockFromNode = true
    fallbackClockSecs = data.rallyClock.wallClockSecs or fallbackClockSecs
  end

  if incomingCountdown then
    if incomingGoCountdown then
      if not fallbackGoHoldUntil or not previousCountdownData or previousCountdownData.countdown ~= 0 then
        fallbackGoHoldUntil = now + fallbackGoDisplayTime
      end
      fallbackCountdownHoldUntil = fallbackGoHoldUntil
    else
      fallbackGoHoldUntil = nil
      fallbackCountdownHoldUntil = now + fallbackFreshTime
    end
  end
end

M.clear = clear
M.isActive = isActive
M.updateClock = updateClock
M.getStreamData = getStreamData
M.updateStreamData = updateStreamData
M.onSettingsChanged = onSettingsChanged

return M
