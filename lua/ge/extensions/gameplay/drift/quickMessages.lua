-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
M.dependencies = {
  "gameplay_drift_general",
  "gameplay_drift_drift",
  "gameplay_drift_scoring"
}

local im = ui_imgui

local debugHistory = {}

local gc = 0
local profiler = LuaProfiler("drift quick message profiler")
local isBeingDebugged
local driftDebugInfo = {
  default = false,
  canBeChanged = true
}

local closeCallsInCurrentDriftChain = 0
local currentVehId
local primaryDriftData = {
  driftActiveData = nil,
  driftChainActiveData = nil,
  currentSpeed = nil,
  score = nil,
  currentDriftDuration = 0
}
local confirmArgsTable = {dt = 0}

local firstOnUpdate = true

local driftChainStoppedThisFrame = false
local individualDriftStoppedThisFrame = false

local options = {
  displayTime = 1, -- sec
  noCrashTime = 1,
  idleDelay = 2 -- sec after not drifting before skipping checks
}

local isIdle = false
local notDriftingTimer = 0

local tempData = {}

local primaryConditions = {
  notDrifting = function(conditionData, driftData)
    return not driftData.driftActiveData
  end,
  minAngle = function(conditionData, driftData)
    return driftData.driftActiveData and driftData.driftActiveData.currDegAngle > conditionData
  end,
  minOneDriftScore = function(conditionData, driftData)
    return driftData.driftActiveData and driftData.driftActiveData.score > conditionData
  end,
  minSpeed = function(conditionData, driftData)
    return driftData.currentSpeed and driftData.currentSpeed > conditionData
  end,
  minDist = function(conditionData, driftData)
    return driftData.driftActiveData and (driftData.driftActiveData.closestWallDistanceFront < conditionData or driftData.driftActiveData.closestWallDistanceRear < conditionData)
  end,
  minDriftChain = function(conditionData, driftData)
    return driftData.driftChainActiveData and driftData.driftChainActiveData.chainedDrifts >= conditionData
  end,
  closeCallsInOneChain = function(conditionData, driftData)
    return closeCallsInCurrentDriftChain >= conditionData
  end,
  minCachedScore = function(conditionData, driftData)
    return driftData.score.cachedScore and driftData.score.cachedScore >= conditionData
  end,
  minDriftTime = function(conditionData, driftData)
    return driftData.currentDriftDuration > conditionData
  end
}

local resetConditions = {
  onDriftEnd = function()
    return individualDriftStoppedThisFrame
  end,
  onChainEnd = function()
    return driftChainStoppedThisFrame
  end,
  afterTime = function(conditionData, data)
    if not data.tempData.timer then data.tempData.timer = conditionData.time end
    data.tempData.timer = data.tempData.timer - data.dt
    return data.tempData.timer <= 0
  end
}


local confirmConditions = {
  noCrash = function(conditionData, data)
    if not conditionData.timeToNoCrash then conditionData.timeToNoCrash = options.noCrashTime end
    conditionData.timeToNoCrash = conditionData.timeToNoCrash - data.dt
    if gameplay_drift_drift.getIsCrashing(currentVehId) then
      return "failed"
    end
    return conditionData.timeToNoCrash <= 0
  end
}


--[[
"primaryConditions" must all be met at the same time.
"confirmConditions" are basically the "when" do we confirm the primaryConditions. Such as for a "close call" the vehicle must not crash afterwards
]]
local quickMessages = {
  precisionDrifting = {
    primaryConditions = {
      closeCallsInOneChain = 3,
      notDrifting = true
    },
    reset = {
      conditions = {
        onChainEnd = true
      },
      funcWhenReset = function()
        closeCallsInCurrentDriftChain = 0
      end
    },
    reward = 150
  },
  bigAngle = {
    primaryConditions = {
      minAngle = 80
    },
    reset = {
      conditions = {
        onDriftEnd = true  -- Reset after each drift
      }
    },
    reward = 15
  },
  reverseDrift = {
    primaryConditions = {
      minAngle = 105
    },
    reset = {
      conditions = {
        onDriftEnd = true  -- Reset after each drift
      }
    },
    reward = 30
  },
  longDrift = {
    primaryConditions = {
      minDriftTime = 4, -- sec
      minSpeed = 30
    },
    reset = {
      conditions = {
        onDriftEnd = true  -- Reset after each drift
      }
    },
    reward = 20
  },
  closeCall = {
    primaryConditions = {
      minAngle = 25,
      minSpeed = 30, -- kph
      minDist = 1.5
    },
    confirmConditions = {
      "noCrash"
    },
    reset = {
      conditions = {
        afterTime = { time = 4 }
      }
    },
    funcWhenReached = function()
      closeCallsInCurrentDriftChain = closeCallsInCurrentDriftChain + 1
    end,
    reward = 80
  },
  longDriftChain = {
    primaryConditions = {
      minDriftChain = 10,
    },
    reset = {
      conditions = {
        onChainEnd = true
      }
    },
    reward = 160
  },
}

local checkConfirmConditionsQueue = {}

local quickMessagesProcessed = {}

-- Simplify the display function to show messages immediately
local function displayQuickMessage(msg, reward)
  local msg = msg .. " +" .. reward
  table.insert(debugHistory, msg)
  extensions.hook("onDriftQuickMessageDisplay", {msg = msg, displayTime = options.displayTime})
end

-- Replace addQuickMessageToDisplayQueue with direct display
local function showQuickMessage(quickMessageId)
  displayQuickMessage(quickMessages[quickMessageId].msg, quickMessages[quickMessageId].reward)

  -- Call the funcWhenReached if it exists
  if quickMessages[quickMessageId].funcWhenReached then
    quickMessages[quickMessageId].funcWhenReached()
  end

  extensions.hook("onDriftQuickMessageReached", {quickMessageId = quickMessageId, reward = quickMessages[quickMessageId].reward})
  gameplay_drift_scoring.addCachedScore(quickMessages[quickMessageId].reward)
end

-- Update checkPrimaryConditions to use showQuickMessage instead
local function checkPrimaryConditions()
  for messageId, data in pairs(quickMessages) do
    if not quickMessagesProcessed[messageId] then
      local conditionsMet = true
      for primaryCondition, conditionData in pairs(data.primaryConditions) do
        if not primaryConditions[primaryCondition](conditionData, primaryDriftData) then
          conditionsMet = false
          break
        end
      end
      if conditionsMet then
        if data.confirmConditions then
          local table = {}
          for _, confirmConditionName in ipairs(data.confirmConditions) do
            table[confirmConditionName] = {}
          end
          checkConfirmConditionsQueue[messageId] = table
        else
          showQuickMessage(messageId)
        end
        quickMessagesProcessed[messageId] = true
      end
    end
  end

end

-- Update checkConfirmConditions to use showQuickMessage
local function checkConfirmConditions(dt)
  if not next(checkConfirmConditionsQueue) then return end
  confirmArgsTable.dt = dt
  for quickMessageId, confirmConditions_ in pairs(checkConfirmConditionsQueue) do
    local conditionsMet = true
    for confirmConditionName, confirmConditionData in pairs(confirmConditions_) do
      local result = confirmConditions[confirmConditionName](confirmConditionData, confirmArgsTable)
      if result == "failed" then
        checkConfirmConditionsQueue[quickMessageId] = nil
        conditionsMet = false
        break
      elseif not result then
        conditionsMet = false
        break
      end
    end
    if conditionsMet then
      showQuickMessage(quickMessageId)
      checkConfirmConditionsQueue[quickMessageId] = nil
    end
  end
end

local tempArgsTable = {dt = 0, tempData = {}}

local function checkResetConditions(dt)
  if not next(quickMessagesProcessed) then return end
  for messageId, messageData in pairs(quickMessages) do
    if quickMessagesProcessed[messageId] and messageData.reset.conditions then
      if not tempData[messageId] then tempData[messageId] = {} end
      tempArgsTable.dt = dt
      tempArgsTable.tempData = tempData[messageId]
      for conditionName, conditionData in pairs(messageData.reset.conditions) do
        if resetConditions[conditionName](conditionData, tempArgsTable) then
          quickMessagesProcessed[messageId] = nil
          tempData[messageId] = nil
          if messageData.reset.funcWhenReset then
            messageData.reset.funcWhenReset()
          end
          break
        end
      end
    end
  end
end

local function imguiDebug()
  if isBeingDebugged then
    if im.Begin("Quick messages") then
      im.Text("Available quick messages : ")
      if im.BeginChild1("Available quick messages", im.ImVec2(im.GetContentRegionAvailWidth(), 130), true) then
        for messageId, data in pairs(quickMessages) do
          im.Text('-' .. data.msg)
          if im.IsItemHovered() then
            im.tooltip(im.ArrayChar(4096, dumps(data)))
          end
        end
        im.EndChild()
      end

      im.Dummy(im.ImVec2(1, 10))
      im.Text("Quick message history : ")
      im.SameLine()
      if im.Button("Clear") then debugHistory = {} end
      if im.BeginTable("Loaded extensions", 2, nil) then
        im.TableNextColumn()
        im.Text("Messages")
        im.TableNextColumn()
        im.Text("Status")
        im.TableNextColumn()

        for i = #debugHistory, 1, -1 do
          im.Text(debugHistory[i])
          im.TableNextColumn()
          im.TableNextColumn()
        end
        im.EndTable()
      end
    end
    im.End()
  end
end

local function translateQuickMessages()
  for id, _ in pairs(quickMessages) do
    quickMessages[id].msg = _tr("missions.drift.quickMessage."..id)
  end
end

local function finishUpdate()
  if gameplay_drift_general.getGeneralDebug() then
    profiler:add("Drift quick messages")
    gc = profiler.sections[1].garbage
    profiler:finish(false)
  end
  individualDriftStoppedThisFrame = false
  driftChainStoppedThisFrame = false
end

local function onUpdate(dt)
  if firstOnUpdate then
    translateQuickMessages()
    firstOnUpdate = false
  end

  isBeingDebugged = gameplay_drift_general.getExtensionDebug("gameplay_drift_quickMessages")
  imguiDebug()
  if gameplay_drift_general.getGeneralDebug() then profiler:start() end

  currentVehId = gameplay_drift_drift.getVehId()
  local driftActiveData = gameplay_drift_drift.getDriftActiveData(currentVehId)

  if isIdle then
    if not driftActiveData then
      finishUpdate()
      return
    end
    isIdle = false
    notDriftingTimer = 0
  end

  primaryDriftData.driftActiveData = driftActiveData
  primaryDriftData.driftChainActiveData = gameplay_drift_drift.getDriftChainActiveData(currentVehId)
  primaryDriftData.currentSpeed = gameplay_drift_drift.getAirSpeed(currentVehId)
  primaryDriftData.score = gameplay_drift_scoring.getScore(currentVehId)
  primaryDriftData.currentDriftDuration = gameplay_drift_drift.getCurrentDriftDuration(currentVehId)

  if not gameplay_drift_general.getFrozen() then
    checkPrimaryConditions()
    checkConfirmConditions(dt)
    checkResetConditions(dt)
  end

  if driftActiveData then
    notDriftingTimer = 0
  else
    notDriftingTimer = notDriftingTimer + dt
    if notDriftingTimer >= options.idleDelay
        and not primaryDriftData.driftChainActiveData
        and not next(checkConfirmConditionsQueue) then
      isIdle = true
    end
  end

  finishUpdate()
end

local function reset()
  checkConfirmConditionsQueue = {}
  quickMessagesProcessed = {}
  closeCallsInCurrentDriftChain = 0
  tempData = {}
  isIdle = false
  notDriftingTimer = 0
end

local function onDriftActiveDataFinished()
  individualDriftStoppedThisFrame = true
end

-- this is called when the drift vehicle is reset
local function onDriftPlVehReset()
  reset()
end

-- this is called when a drift chain is completed
local function onDriftCompleted()
  driftChainStoppedThisFrame = true
end

local function getQuickMessages()
  translateQuickMessages()

  return quickMessages
end

local function getDriftDebugInfo()
  return driftDebugInfo
end

local function getGC()
  return gc
end

local function driftFailed()
  reset()
end

local function onDriftCrash()
  driftFailed()
end

local function onDriftSpinout()
  driftFailed()
end

M.onDriftPlVehReset = onDriftPlVehReset
M.onDriftCompleted = onDriftCompleted
M.onDriftActiveDataFinished = onDriftActiveDataFinished
M.onDriftCrash = onDriftCrash
M.onDriftSpinout = onDriftSpinout

M.onUpdate = onUpdate

M.reset = reset

M.getQuickMessages = getQuickMessages
M.getDriftDebugInfo = getDriftDebugInfo
M.getGC = getGC

return M