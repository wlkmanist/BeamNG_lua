-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {"gameplay_missions_missions", "gameplay_missions_progress"}
local missionIdToMilestonesList = {}
local milestoneConfigs = {}
local milestones

local function getUnlockedStarCounts(mission)
  local total, default, bonus = gameplay_missions_progress.getUnlockedStarCountsForMissionById(mission.id)
  return total or 0, default or 0, bonus or 0
end

local function getMissionStarCount(mission)
  return mission.careerSetup._activeStarCache.defaultStarCount + mission.careerSetup._activeStarCache.bonusStarCount
end

M.onGeneralMilestonesCollect = function(milestonesList)
  milestones = career_modules_milestones_milestones
  -- get all career missions.
  local careerMissions = {}
  local missionsByBranch = {}
  for i, mission in ipairs(gameplay_missions_missions.getAllMissions()) do
    if mission.careerSetup.showInCareer then
      table.insert(careerMissions, mission)
      local forwardInfo = gameplay_missions_unlocks.getForwardMissionInfo(mission)
      for branchKey, _ in pairs(forwardInfo.branchTags) do
        missionsByBranch[branchKey] = missionsByBranch[branchKey] or {}
        table.insert(missionsByBranch[branchKey], mission)
      end
    end
  end

  M.makeAllMissionStarMilestones(careerMissions, milestonesList)
  for _, branchKey in ipairs(tableKeysSorted(missionsByBranch)) do
    M.makeBranchMissionStarMilestones(missionsByBranch[branchKey], branchKey , milestonesList)
  end



  --M.makeUnlockMissionsMilestones(careerMissions, milestonesList)

end

local stepPercent = {0.10,0.18,0.3,0.54,0.74,1.0}
M.makeAllMissionStarMilestones = function(missions, milestonesList)
  local defaultStarCount, bonusStarCount = 0, 0
  local missionCount = 0
  for _, m in ipairs(missions) do
    defaultStarCount = defaultStarCount + m.careerSetup._activeStarCache.defaultStarCount
    bonusStarCount = bonusStarCount + m.careerSetup._activeStarCache.bonusStarCount
    missionCount = missionCount + 1
  end
  local totalStarCount = defaultStarCount + bonusStarCount


  -- all stars
  local allStarMilestone = {
      id = "mission_totalStarCount",
      filter = {mission=true, general=true},
      type = "mission",
      hooks = {onAnyMissionChanged = true},
      maxStep = #stepPercent,
      icon = "star",
      color=career_modules_milestones_milestones.colorMissionBlue,
      getValue = function()
        local count = 0
        for _, m in ipairs(missions) do
          local totalUnlockedStarCount = getUnlockedStarCounts(m)
          count = count + totalUnlockedStarCount
        end
        return count
      end,
      getLabel = function(step, displayValue, target) return "ui.career.milestones.missions.starCollector.label" end,
      getDescription = function(step, displayValue, target) return {txt="ui.career.milestones.missions.starCollector.description", context={count = target}} end,
      getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.missions.starsProgressLabel", context={current = current, target = target}} end,
      getTarget = function(step) return step == 0 and 0 or math.ceil(stepPercent[step]*totalStarCount) end,
      getRewards = milestones.majorLinear,
    }
  milestones.saveData.general[allStarMilestone.id] = milestones.saveData.general[allStarMilestone.id] or {claimedStep = 0, notificationStep = 0}

  for _, m in ipairs(missions) do
    missionIdToMilestonesList[m.id] = missionIdToMilestonesList[m.id] or {}
    table.insert(missionIdToMilestonesList[m.id], allStarMilestone)
  end
  table.insert(milestoneConfigs, allStarMilestone)
  table.insert(milestonesList, allStarMilestone)

  -- pass all missions
  local passAllMissionMilestone = {
      id = "mission_passMissions",
      filter = {mission=true},
      type = "mission",
      hooks = {onAnyMissionChanged = true},
      maxStep = #stepPercent,
      icon = "star",
      color=career_modules_milestones_milestones.colorMissionBlue,
      getValue = function()
        local count = 0
        for _, m in ipairs(missions) do
          local _, defaultUnlockedStarCount = getUnlockedStarCounts(m)
          count = count + (defaultUnlockedStarCount > 0 and 1 or 0)
        end
        return count
      end,
      getLabel = function(step, displayValue, target) return "ui.career.milestones.missions.challengePasser.label" end,
      getDescription = function(step, displayValue, target) return "ui.career.milestones.missions.challengePasser.description" end,
      getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.missions.challengesProgressLabel", context={current = current, target = target}} end,
      getTarget = function(step) return step == 0 and 0 or math.ceil(stepPercent[step]*missionCount) end,
      getRewards = milestones.minorLinear,
    }
  milestones.saveData.general[passAllMissionMilestone.id] = milestones.saveData.general[passAllMissionMilestone.id] or {claimedStep = 0, notificationStep = 0}

  for _, m in ipairs(missions) do
    missionIdToMilestonesList[m.id] = missionIdToMilestonesList[m.id] or {}
    table.insert(missionIdToMilestonesList[m.id], passAllMissionMilestone)
  end
  table.insert(milestoneConfigs, passAllMissionMilestone)
  table.insert(milestonesList, passAllMissionMilestone)

    -- completing all missions
  local completeAllMissionsMilestone = {
      id = "mission_completeMissions",
      filter = {mission=true},
      type = "mission",
      hooks = {onAnyMissionChanged = true},
      maxStep = #stepPercent,
      icon = "star",
      color=career_modules_milestones_milestones.colorMissionBlue,
      getValue = function()
        local count = 0
        for _, m in ipairs(missions) do
          local totalUnlockedStarCount = getUnlockedStarCounts(m)
          local totalStarCount = getMissionStarCount(m)
          count = count + (totalStarCount > 0 and totalUnlockedStarCount >= totalStarCount and 1 or 0)
        end
        return count
      end,
      getLabel = function(step, displayValue, target) return "ui.career.milestones.missions.challengeCompletionist.label" end,
      getDescription = function(step, displayValue, target) return "ui.career.milestones.missions.challengeCompletionist.description" end,
      getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.missions.challengesProgressLabel", context={current = current, target = target}} end,
      getTarget = function(step) return step == 0 and 0 or math.ceil(stepPercent[step]*missionCount) end,
      getRewards = milestones.minorLinear,
    }
  milestones.saveData.general[completeAllMissionsMilestone.id] = milestones.saveData.general[completeAllMissionsMilestone.id] or {claimedStep = 0, notificationStep = 0}

  for _, m in ipairs(missions) do
    missionIdToMilestonesList[m.id] = missionIdToMilestonesList[m.id] or {}
    table.insert(missionIdToMilestonesList[m.id], completeAllMissionsMilestone)
  end
  table.insert(milestoneConfigs, completeAllMissionsMilestone)
  table.insert(milestonesList, completeAllMissionsMilestone)
end

M.makeBranchMissionStarMilestones = function(missions, branchKey, milestonesList)
  local defaultStarCount, bonusStarCount = 0, 0
  local missionCount = 0
  for _, m in ipairs(missions) do
    defaultStarCount = defaultStarCount + m.careerSetup._activeStarCache.defaultStarCount
    bonusStarCount = bonusStarCount + m.careerSetup._activeStarCache.bonusStarCount
    missionCount = missionCount + 1
  end
  local totalStarCount = defaultStarCount + bonusStarCount
  local branchInfo = career_branches.getBranchById(branchKey)
  local branchName = branchInfo.name
  local branchType = branchInfo.isSkill and "ui.career.milestones.missions.branchType.skill" or "ui.career.milestones.missions.branchType.branch"
  -- all stars
  local milestoneConfig = {
      id = "mission_totalStar_branch_"..branchKey,
      filter = {mission=true, ['branch_'..branchKey] = true},
      type = "mission",
      hooks = {onAnyMissionChanged = true},
      maxStep = #stepPercent,
      icon="star",
      color=career_modules_milestones_milestones.colorMissionBlue,
      getValue = function()
        local count = 0
        for _, m in ipairs(missions) do
          local totalUnlockedStarCount = getUnlockedStarCounts(m)
          count = count + totalUnlockedStarCount
        end
        return count
      end,
      getLabel = function(step, displayValue, target) return {txt="ui.career.milestones.missions.branchStarCollector.label", context={branchName = branchName}} end,
      getDescription = function(step, displayValue, target) return {txt="ui.career.milestones.missions.branchStarCollector.description", context={count = target, branchName = branchName, branchType = branchType}} end,
      getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.missions.starsProgressLabel", context={current = current, target = target}} end,
      getTarget = function(step) return step == 0 and 0 or math.ceil(stepPercent[step]*totalStarCount) end,
      getRewards = milestones.minorLinear,
    }
  milestones.saveData.general[milestoneConfig.id] = milestones.saveData.general[milestoneConfig.id] or {claimedStep = 0, notificationStep = 0}

  for _, m in ipairs(missions) do
    missionIdToMilestonesList[m.id] = missionIdToMilestonesList[m.id] or {}
    table.insert(missionIdToMilestonesList[m.id], milestoneConfig)
  end
  table.insert(milestoneConfigs, milestoneConfig)
  table.insert(milestonesList, milestoneConfig)

  -- pass all missions
  local passAllMissionMilestone = {
      id = "mission_passMissions_"..branchKey,
      filter = {mission=true, ['branch_'..branchKey] = true},
      type = "mission",
      hooks = {onAnyMissionChanged = true},
      maxStep = #stepPercent,
      icon="star",
      color=career_modules_milestones_milestones.colorMissionBlue,
      getValue = function()
        local count = 0
        for _, m in ipairs(missions) do
          local _, defaultUnlockedStarCount = getUnlockedStarCounts(m)
          count = count + (defaultUnlockedStarCount > 0 and 1 or 0)
        end
        return count
      end,
      getLabel = function(step, displayValue, target) return {txt="ui.career.milestones.missions.branchChallengePasser.label", context={branchName = branchName}} end,
      getDescription = function(step, displayValue, target) return "ui.career.milestones.missions.challengePasser.description" end,
      getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.missions.challengesProgressLabel", context={current = current, target = target}} end,
      getTarget = function(step) return step == 0 and 0 or math.ceil(stepPercent[step]*missionCount) end,
      getRewards = milestones.minorLinear,
    }
  milestones.saveData.general[passAllMissionMilestone.id] = milestones.saveData.general[passAllMissionMilestone.id] or {claimedStep = 0, notificationStep = 0}

  for _, m in ipairs(missions) do
    missionIdToMilestonesList[m.id] = missionIdToMilestonesList[m.id] or {}
    table.insert(missionIdToMilestonesList[m.id], passAllMissionMilestone)
  end
  table.insert(milestoneConfigs, passAllMissionMilestone)
  table.insert(milestonesList, passAllMissionMilestone)

    -- completing all missions
  local completeAllMissionsMilestone = {
      id = "mission_completeMissions_"..branchKey,
      filter = {mission=true, ['branch_'..branchKey] = true},
      type = "mission",
      hooks = {onAnyMissionChanged = true},
      maxStep = #stepPercent,
      icon="star",
      color=career_modules_milestones_milestones.colorMissionBlue,
      getValue = function()
        local count = 0
        for _, m in ipairs(missions) do
          local totalUnlockedStarCount = getUnlockedStarCounts(m)
          local totalStarCount = getMissionStarCount(m)
          count = count + (totalStarCount > 0 and totalUnlockedStarCount >= totalStarCount and 1 or 0)
        end
        return count
      end,
      getLabel = function(step, displayValue, target) return {txt="ui.career.milestones.missions.branchChallengeCompletionist.label", context={branchName = branchName}} end,
      getDescription = function(step, displayValue, target) return "ui.career.milestones.missions.challengeCompletionist.description" end,
      getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.missions.challengesProgressLabel", context={current = current, target = target}} end,
      getTarget = function(step) return step == 0 and 0 or math.ceil(stepPercent[step]*missionCount) end,
      getRewards = milestones.minorLinear,
    }
  milestones.saveData.general[completeAllMissionsMilestone.id] = milestones.saveData.general[completeAllMissionsMilestone.id] or {claimedStep = 0, notificationStep = 0}

  for _, m in ipairs(missions) do
    missionIdToMilestonesList[m.id] = missionIdToMilestonesList[m.id] or {}
    table.insert(missionIdToMilestonesList[m.id], completeAllMissionsMilestone)
  end
  table.insert(milestoneConfigs, completeAllMissionsMilestone)
  table.insert(milestonesList, completeAllMissionsMilestone)
end

M.makeUnlockMissionsMilestones = function(missions, milestonesList)

  local milestoneConfig = {
      id = "mission_unlockMissions",
      filter = {mission=true},
      type = "mission",
      hooks = {onMissionUnlocked = true},
      getValue = function() return milestones.saveData.general['mission_unlockMissions'].unlockedCount end,
      getLabel = function(step, displayValue, target) return {txt="ui.career.milestones.missions.challengeUnlocker.label", context={step = step}} end,
      getDescription = function(step, displayValue, target) return "ui.career.milestones.missions.challengeUnlocker.description" end,
      getProgressLabel = function(step, current, target) return {txt="ui.career.milestones.missions.challengesProgressLabel", context={current = current, target = target}} end,
      getTarget = function(step) return (step+1)*1 end,
      getRewards = milestones.minorLinear,
    }
  milestones.saveData.general[milestoneConfig.id] = milestones.saveData.general[milestoneConfig.id] or {claimedStep = 0, notificationStep = 0, unlockedCount = 0}

  for _, m in ipairs(missions) do
    missionIdToMilestonesList[m.id] = missionIdToMilestonesList[m.id] or {}
    table.insert(missionIdToMilestonesList[m.id], milestoneConfig)
  end
  table.insert(milestoneConfigs, milestoneConfig)
  table.insert(milestonesList, milestoneConfig)
end



M.onGeneralMilestonesSetupCallbacks = function()
  for _, milestone in ipairs(milestoneConfigs) do
    M.setNotificationTarget(milestone)
  end
end


-- branch related updates
local function setNotificationTarget(milestone)
  local step = milestones.saveData.general[milestone.id].notificationStep +1
  if milestone.maxStep and step > milestone.maxStep then return end
  local target = milestone.getTarget(step)
  -- check if completed
  if target then
    milestone._target = target
  end
end

local function onAnyMissionChanged(state, mission)
  if state == "stopped" then
    for _, milestone in ipairs(missionIdToMilestonesList[mission.id] or {}) do
      if milestone.hooks.onAnyMissionChanged then
        local step = milestones.saveData.general[milestone.id].notificationStep +1
        if milestone._target and milestone.getValue() >= milestone._target then
          milestones.milestoneReached(milestone.getLabel(step))
          milestone._target = nil
          milestones.saveData.general[milestone.id].notificationStep = step
          M.setNotificationTarget(milestone)
        end
      end
    end
  end
end

local function onMissionUnlocked(id)
  for _, milestone in ipairs(milestoneConfigs) do
    if milestone.hooks.onMissionUnlocked then
      -- count the unlock manually
      milestones.saveData.general[milestone.id].unlockedCount = milestones.saveData.general[milestone.id].unlockedCount + 1
      local step = milestones.saveData.general[milestone.id].notificationStep +1
      if milestone._target and milestone.getValue() >= milestone._target then
        milestones.milestoneReached(milestone.getLabel(step))
        milestone._target = nil
        milestones.saveData.general[milestone.id].notificationStep = step
        M.setNotificationTarget(milestone)
      end
    end
  end

end

M.setNotificationTarget = setNotificationTarget
M.onAnyMissionChanged = onAnyMissionChanged

return M