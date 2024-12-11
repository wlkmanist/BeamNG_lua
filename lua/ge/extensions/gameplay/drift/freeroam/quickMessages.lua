local M = {}
local im = ui_imgui

local debugHistory = {}

local gc = 0
local profiler = LuaProfiler("drift quick message profiler")
local isBeingDebugged
local driftDebugInfo = {
  default = false,
  canBeChanged = true
}

local driftActiveDataCopy
local driftChainActiveDataCopy
local scoreCopy

local options = {
  displayTime = 1, -- sec
  noCrashTime = 1
}

local rewards = {
  cachedScore = function(scoreToAdd)
    gameplay_drift_scoring.addCachedScore(scoreToAdd)
  end
}

local primaryConditions = {
  minAngle = function(conditionData, driftData)
    return driftData.driftActiveData and driftData.driftActiveData.currDegAngle > conditionData
  end,
  minOneDriftScore = function(conditionData, driftData)
    return driftData.driftActiveData and driftData.driftActiveData.score > conditionData
  end,
  minSpeed = function(conditionData, driftData)
    return driftData.driftActiveData and driftData.driftActiveData.speeds[#driftData.driftActiveData.speeds] > conditionData
  end,
  minDist = function(conditionData, driftData)
    return driftData.driftActiveData and (driftData.driftActiveData.closestWallDistanceFront < conditionData or driftData.driftActiveData.closestWallDistanceRear < conditionData)
  end,
  minDriftChain = function(conditionData, driftData)
    return driftData.driftChainActiveData and driftData.driftChainActiveData.chainedDrifts >= conditionData
  end,
  minCachedScore = function(conditionData, driftData)
    return driftData.score.cachedScore and driftData.score.cachedScore >= conditionData
  end
}

local confirmConditions = {
  noCrash = function(conditionData, data)
    if not conditionData.timeToNoCrash then conditionData.timeToNoCrash = options.noCrashTime end
    conditionData.timeToNoCrash = conditionData.timeToNoCrash - data.dt
    if gameplay_drift_drift.getIsCrashing() then
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
  bigAngle = {
    msg = "Big angle!",
    primaryConditions = {
      minAngle = 80
    }
  },
  goodDrift = {
    msg = "Long drift!",
    primaryConditions = {
      minOneDriftScore = 300
    }
  },
  veryGoodDrift = {
    msg = "Very long drift!",
    primaryConditions = {
      minOneDriftScore = 550
    }
  },
  closeCall = {
    msg = "Close call!",
    primaryConditions = {
      minAngle = 30,
      minSpeed = 40, -- kph
      minDist = 1.3
    },
    confirmConditions = {
      "noCrash"
    },
  },
  niceChain = {
    msg = "Nice drift chain!",
    primaryConditions = {
      minDriftChain = 4,
      minCachedScore = 400
    },
  },
  proDrift = {
    msg = "Long drift chain!",
    primaryConditions = {
      minDriftChain = 10,
      minCachedScore = 1500,
    },
  },
}

local checkConfirmConditionsQueue = {}

local quickMessagesProcessed = {}

-- so messages are shown in a timely manner
local quickMessageQueue = {}

local function addQuickMessageToDisplayQueue(quickMessageId)
  table.insert(quickMessageQueue, {
    msg = quickMessages[quickMessageId].msg,
    initiated = false,
    displayTime = options.displayTime,
    rewards = quickMessages[quickMessageId].rewards
  })
end

local function checkPrimaryConditions()
  for messageId, data in pairs(quickMessages) do
    if not quickMessagesProcessed[messageId] then
      local conditionsMet = true
      for primaryCondition, conditionData in pairs(data.primaryConditions) do
        if not primaryConditions[primaryCondition](conditionData, {driftActiveData = driftActiveDataCopy, driftChainActiveData = driftChainActiveDataCopy, score = scoreCopy}) then -- every condition must be met. So is AND not OR
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
          addQuickMessageToDisplayQueue(messageId)
        end
        quickMessagesProcessed[messageId] = true
      end
    end
  end
end

local function checkConfirmConditions(dt)
  for quickMessageId, confirmConditions_ in pairs(checkConfirmConditionsQueue) do
    local conditionsMet = true
    for confirmConditionName, confirmConditionData in pairs(confirmConditions_) do
      local result = confirmConditions[confirmConditionName](confirmConditionData, {dt = dt})
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
      addQuickMessageToDisplayQueue(quickMessageId)
      checkConfirmConditionsQueue[quickMessageId] = nil
    end
  end
end

local function displayQuickMessage(msg_, rewards)
  local msg = msg_
  if rewards ~= nil  then
    for rewardName, rewardAmount in pairs(rewards) do
      if rewardName == "cachedScore" then
        msg = msg .. " (+" .. rewardAmount .. " score)"
      end
    end
  end
  table.insert(debugHistory, msg)
  extensions.hook("onDriftQuickMessage", {msg = msg, displayTime = options.displayTime})
end

local function processRewards(quickMessage)
  if quickMessage.rewards ~= nil  then
    for rewardName, rewardAmount in pairs(quickMessage.rewards) do
      rewards[rewardName](rewardAmount)
    end
  end
end

local function processQueue(dt)
  if quickMessageQueue[1] then
    if not quickMessageQueue[1].initiated then
      displayQuickMessage(quickMessageQueue[1].msg, quickMessageQueue[1].rewards)
      processRewards(quickMessageQueue[1])
      quickMessageQueue[1].initiated = true
    else
      quickMessageQueue[1].displayTime = quickMessageQueue[1].displayTime - dt
      if quickMessageQueue[1].displayTime <= 0 then
        table.remove(quickMessageQueue, 1)
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
      if im.BeginTable("Loaded extensions", 2, nil) then
        im.TableNextColumn()
        im.Text("Message")
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
  end
end

local function onUpdate(dt)
  if not gameplay_drift_general then return end

  isBeingDebugged = gameplay_drift_general.getExtensionDebug("gameplay_drift_freeroam_quickMessages")
  imguiDebug()
  if gameplay_drift_general.getGeneralDebug() then profiler:start() end

  driftActiveDataCopy = gameplay_drift_drift.getDriftActiveData()
  driftChainActiveDataCopy = gameplay_drift_drift.getDriftChainActiveData()
  scoreCopy = gameplay_drift_scoring.getScore()

  if not gameplay_drift_general.getFrozen() then
    checkPrimaryConditions()
    checkConfirmConditions(dt)
  end
  processQueue(dt)
  if gameplay_drift_general.getGeneralDebug() then
    profiler:add("Drift quick messages")
    gc = profiler.sections[1].garbage
    profiler:finish(false)
  end
end

local function reset()
  checkConfirmConditionsQueue = {}
  quickMessageQueue = {}
  quickMessagesProcessed = {}
end

local function onDriftPlVehReset()
  reset()
end

local function onDriftCompleted()
  reset()
end

local function getDriftDebugInfo()
  return driftDebugInfo
end

local function getGC()
  return gc
end

M.onDriftPlVehReset = onDriftPlVehReset
M.onDriftCompleted = onDriftCompleted

M.onUpdate = onUpdate

M.reset = reset

M.getDriftDebugInfo = getDriftDebugInfo
M.getGC = getGC

return M