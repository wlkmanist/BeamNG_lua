-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--Purpose: Lets mechanical beam movement trigger electrics

local M = {}
M.type = "auxiliary"

local min = math.min
local max = math.max

local beamIds = {}
local beamCount
local inverseBeamCount

local threshold
local electricsName
local electricsTriggerValue

local getBeamLength
local isTriggered

local function getAverageBeamLength()
  local totalLength = 0
  for i = 1, beamCount do
    totalLength = totalLength + obj:getBeamLength(beamIds[i])
  end
  return totalLength * inverseBeamCount
end

local function getMinimumBeamLength()
  local minimumLength = obj:getBeamLength(beamIds[1])
  for i = 2, beamCount do
    minimumLength = min(minimumLength, obj:getBeamLength(beamIds[i]))
  end
  return minimumLength
end

local function getMaximumBeamLength()
  local maximumLength = obj:getBeamLength(beamIds[1])
  for i = 2, beamCount do
    maximumLength = max(maximumLength, obj:getBeamLength(beamIds[i]))
  end
  return maximumLength
end

local function getSingleBeamLength()
  return obj:getBeamLength(beamIds[1])
end

local function isShorter(beamLength)
  return beamLength < threshold
end

local function isLonger(beamLength)
  return beamLength > threshold
end

local function updateGFX(dt)
  -- Keep the electric triggered while the selected beam length passes the threshold.
  electrics.values[electricsName] = isTriggered(getBeamLength()) and electricsTriggerValue or 0
end

local function reset(jbeamData)
  if electricsName then
    electrics.values[electricsName] = 0
  end
end

local function init(jbeamData)
  local beamTag = jbeamData.triggerBeamTag
  beamIds = beamstate.tagBeamMap[beamTag] or {}
  beamCount = #beamIds
  if beamCount == 0 then
    log("E", "beamLengthTrigger.init", M.name .. ": beamTag '" .. tostring(beamTag) .. "' has no matching beams")
    return
  end

  threshold = jbeamData.triggerLengthThreshold
  if type(threshold) ~= "number" then
    log("E", "beamLengthTrigger.init", M.name .. ": threshold must be a number")
    return
  end

  electricsName = jbeamData.electricsName or (M.name .. "_trigger")
  electricsTriggerValue = jbeamData.electricsTriggerValue or 1

  local comparison = jbeamData.comparison
  if comparison == "shorter" then
    isTriggered = isShorter
  elseif comparison == "longer" then
    isTriggered = isLonger
  else
    log("E", "beamLengthTrigger.init", M.name .. ": comparison must be 'shorter' or 'longer'")
    return
  end

  if beamCount > 1 then
    -- Select aggregation once so the per-frame update stays small.
    local aggregation = jbeamData.aggregation or "average"
    if aggregation == "average" then
      inverseBeamCount = 1 / beamCount
      getBeamLength = getAverageBeamLength
    elseif aggregation == "minimum" then
      getBeamLength = getMinimumBeamLength
    elseif aggregation == "maximum" then
      getBeamLength = getMaximumBeamLength
    else
      log("E", "beamLengthTrigger.init", M.name .. ": aggregation must be 'average', 'minimum', or 'maximum'")
      return
    end
  else
    getBeamLength = getSingleBeamLength
  end

  electrics.values[electricsName] = 0
  M.updateGFX = updateGFX
end

M.init = init
M.reset = reset

M.updateGFX = nil

return M
