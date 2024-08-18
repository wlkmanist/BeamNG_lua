-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.type = "auxiliary"
M.defaultOrder = 80

local abs = math.abs

local actuator = nil
local controlGroups = {}
local actuationStartDistance = 0
local actuationEndDistance = 0

local function iterateGroups(groupNameOrNames)
  if type(groupNameOrNames) == "string" then
    groupNameOrNames = {groupNameOrNames}
  end

  local groups = {}

  for _, name in ipairs(groupNameOrNames) do
    local group = controlGroups[name]
    if group then
      table.insert(groups, group)
    else
      log("W", "autoLevelSuspension.iterateGroups", "Suspension control group not found: " .. name)
    end
  end

  return pairs(groups)
end

local function toggleDump(groupNames)
  for _, group in iterateGroups(groupNames) do
    group.dumpAir = not group.dumpAir
    group.maxHeight = false
  end
end

local function setDump(groupNames, dumpAir)
  for _, group in iterateGroups(groupNames) do
    group.dumpAir = dumpAir
    group.maxHeight = false
  end
end

local function toggleMaxHeight(groupNames)
  for _, group in iterateGroups(groupNames) do
    group.maxHeight = not group.maxHeight
    group.reachedMaxHeight = false
    group.didStartMoving = false
    group.dumpAir = false
  end
end

local function setMaxHeight(groupNames, maxHeight)
  for _, group in iterateGroups(groupNames) do
    group.maxHeight = maxHeight
    group.reachedMaxHeight = false
    group.didStartMoving = false
    group.dumpAir = false
  end
end

local function setMomentaryIncrease(groupNames, increase)
  for _, group in iterateGroups(groupNames) do
    group.momentaryIncrease = increase
    group.momentaryDecrease = false
  end
end

local function setMomentaryDecrease(groupNames, decrease)
  for _, group in iterateGroups(groupNames) do
    group.momentaryDecrease = decrease
    group.momentaryIncrease = false
  end
end

--- Returns four values: the target height, the "dump air" flag, and the "max height" flag
local function getGroupState(groupName)
  local group = controlGroups[groupName]
  if not group then
    log("E", "autoLevelSuspension.getGroupState", "Suspension control group not found: " .. groupName)
    return 0, false, false
  end
  return group.targetLength, group.dumpAir, group.maxHeight
end

local function updateFixedStep(dt)
  for _, controlGroup in pairs(controlGroups) do
    local controlBeamId = controlGroup.controlBeamId
    local curLength = obj:getBeamLength(controlBeamId)

    if controlGroup.momentaryDecrease or controlGroup.dumpAir then
      actuator.setBeamGroupsValveState(controlGroup.beamGroups, -1)
      controlGroup.isAdjusting = controlGroup.momentaryDecrease
    elseif controlGroup.maxHeight then
      if controlGroup.reachedMaxHeight then
        actuator.setBeamGroupsValveState(controlGroup.beamGroups, 0)
      else
        actuator.setBeamGroupsValveState(controlGroup.beamGroups, 1)
        if abs(actuator.getBeamGroupsAverageFlowRate(controlGroup.beamGroups)) > 1e-4 then
          controlGroup.didStartMoving = true
        elseif controlGroup.didStartMoving then
          controlGroup.reachedMaxHeight = true
        end
      end
    elseif controlGroup.momentaryIncrease then
      actuator.setBeamGroupsValveState(controlGroup.beamGroups, 1)
      controlGroup.isAdjusting = controlGroup.momentaryIncrease
    else
      if controlGroup.isAdjusting then
        controlGroup.targetLength = curLength
        controlGroup.isAdjusting = false
      end

      local targetLength = controlGroup.targetLength
      local lengthError = targetLength - curLength
      local actuationCoef = linearScale(abs(lengthError), actuationStartDistance, actuationEndDistance, 0, 1) * sign(lengthError)

      actuator.setBeamGroupsValveState(controlGroup.beamGroups, actuationCoef)
    end
  end
end

local function reset()
  for _, g in pairs(controlGroups) do
    g.dumpAir = false
    g.maxHeight = false
    g.reachedMaxHeight = false
    g.targetLength = g.defaultTargetLength
    g.momentaryIncrease = false
    g.momentaryDecrease = false
    g.isAdjusting = false
  end
end

local function init(jbeamData)
  local actuatorGroupsData = v.data[jbeamData.actuatorGroups] or {}
  local controlBeamNames = {}

  for _, v in pairs(actuatorGroupsData) do
    controlBeamNames[v.controlBeamName] = true
  end

  local relevantBeamIds = {}
  local beams = v.data.beams

  for _, v in pairs(beams) do
    if v.name and controlBeamNames[v.name] then
      relevantBeamIds[v.name] = v.cid
    end
  end

  controlGroups = {}
  for _, groupData in pairs(actuatorGroupsData) do
    local controlBeamName = groupData.controlBeamName
    local controlGroupName = groupData.controlGroupName or controlBeamName
    local controlBeamId = relevantBeamIds[controlBeamName]

    if not controlBeamId then
      log("W", "autoLevelSuspension.init", "Can't find beam with name: " .. controlBeamName)
    else
      local beamGroupName = groupData.beamGroup
      local defaultTargetLength = groupData.defaultTargetLength or obj:getBeamRestLength(controlBeamId)

      if not controlGroups[controlGroupName] then
        controlGroups[controlGroupName] = {
          name = controlGroupName,
          controlBeamId = controlBeamId,
          beamGroups = {},
          dumpAir = false,
          maxHeight = false,
          didStartMoving = false,
          reachedMaxHeight = false,
          defaultTargetLength = defaultTargetLength,
          targetLength = defaultTargetLength,
          momentaryIncrease = false,
          momentaryDecrease = false,
          isAdjusting = false,
        }
      end

      table.insert(controlGroups[controlGroupName].beamGroups, beamGroupName)
    end
  end

  actuationStartDistance = jbeamData.actuationStartDistance or 0.01 -- 1 cm
  actuationEndDistance = jbeamData.actuationEndDistance or 0.06 -- 6 cm
end

local function initSecondStage(jbeamData)
  local actuatorName = jbeamData.actuatorName or "airbags"

  actuator = controller.getController(actuatorName)

  if not actuator then
    log("E", "suspension.init", "Actuator controller not found: " .. actuatorName)
    M.updateFixedStep = nop
    return
  end
end

M.toggleDump = toggleDump
M.setDump = setDump
M.toggleMaxHeight = toggleMaxHeight
M.setMaxHeight = setMaxHeight
M.setMomentaryIncrease = setMomentaryIncrease
M.setMomentaryDecrease = setMomentaryDecrease
M.getGroupState = getGroupState

M.init = init
M.initSecondStage = initSecondStage
M.reset = reset
M.updateFixedStep = updateFixedStep

return M
