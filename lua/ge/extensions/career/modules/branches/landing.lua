-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function sortByStartable(m1, m2)
  if m1.tier ~= m2.tier then
    return m1.tier < m2.tier
  end
  return m1.startable and not m2.startable
end

local function sortByFacId(f1, f2)
  if f1.id ~= f2.id then
    return f1.id < f2.id
  end
  return f1.startable and not f2.startable
end

local function getRewardIcons(rewards)
  local ret = {}
  --Get the names of the rewards
  for _, tierData in pairs(rewards) do
    for _, reward in ipairs(tierData) do
      ret[reward.attributeKey] = reward.rewardAmount
    end
  end
  local keys = tableKeys(ret)
  career_branches.orderAttributeKeysByBranchOrder(keys)
  local newRet = {}
  for _, attKey in ipairs(keys) do
    table.insert(newRet, {attributeKey = attKey, rewardAmount = ret[attKey] })
  end
  return newRet
end

local function getSkillsProgressForUi(branchId)
  local ret = {}
  for _, skill in pairs(career_branches.getSortedBranches()) do
    if skill.isSkill and skill.parentBranch == branchId then
      local attKey = skill.attributeKey
      local value = career_modules_playerAttributes.getAttributeValue(attKey)
      local level, _, _, min, max = career_branches.calcBranchLevelFromValue(value, skill.id)
      local skData = {
        id = skill.attributeKey,
        name = skill.name,
        description = skill.description,
        level = level,
        levelLabel = {txt='ui.career.lvlLabel', context={lvl=level}},
        min = min,
        value = value,
        max = max,
        unlockInfo = {},
        order = skill.order,
        isInDevelopment = skill.isInDevelopment,
      }

      local unlocks = career_modules_delivery_progress.getSkillUnlockDescription()[skill.attributeKey]
      if unlocks then
        local prevTarget = 0
        for i = 1, #unlocks do
          local prevLvlInfo = skill.levels[i-1]
          local curLvlInfo = skill.levels[i]
          local nextLvlInfo = skill.levels[i+1]
          local requiredRelative = (curLvlInfo and curLvlInfo.requiredValue or -1) - prevTarget

          prevTarget = (curLvlInfo and curLvlInfo.requiredValue or -1)
          skData.unlockInfo[i] = {
            list = unlocks[i].unlocks or {
              {label = "Coming Soon!", type = "text"},
            },
            index = i,
            currentValue = prevLvlInfo and value - prevLvlInfo.requiredValue or -1,
            requiredValue = curLvlInfo and requiredRelative or -1,
            isInDevelopment = i > 0 and curLvlInfo == nil,
            isMaxLevel = curLvlInfo == nil,
            isBase = i == 1,
            unlocked = i >= level,
            description = unlocks[i].description,
          }
        end
      end
      --dumpz(skData.unlockInfo,2)

      skData.maxRequiredValue = 0
      for _, value in ipairs(skData.unlockInfo) do
        skData.maxRequiredValue = skData.maxRequiredValue + value.requiredValue
      end
      table.insert(ret, skData)
    end
  end
  return ret
end

local function getFacilityProgress(fac)
  local ret = {
    deliveredFromHere = {
      countByType = {},
      moneySum = {
        money = {
        attributeKey = 'money',
        rewardAmount = fac.progress.deliveredFromHere.moneySum
        }
      }
    },
    deliveredToHere = {
      countByType = {},
      moneySum = {
        money = {
        attributeKey = 'money',
        rewardAmount = fac.progress.deliveredToHere.moneySum
        }
      }
    }
  }
  for key, value in pairs(fac.providedSystemsLookup) do
    if value then
      table.insert(ret.deliveredFromHere.countByType, {
        attributeKey = key,
        rewardAmount = fac.progress.deliveredFromHere.countByType[key]
      })
    end
  end

  for key, value in pairs(fac.receivedSystemsLookup) do
    if value then
      table.insert(ret.deliveredToHere.countByType, {
        attributeKey = key,
        rewardAmount = fac.progress.deliveredToHere.countByType[key]
      })
    end
  end

  return ret
end

local deliverySystemToSkill = {
  vehicleDelivery = "vehicleDelivery",
  parcelDelivery = "delivery",
  trailerDelivery = "delivery",
}
local function getSkillsForFacility(facility)
  local ret = {}
  for key, value in pairs(facility.providedSystemsLookup) do
    if value then
      ret[deliverySystemToSkill[key]] = true
    end
  end
  for key, value in pairs(facility.receivedSystemsLookup) do
    if value then
      ret[deliverySystemToSkill[key]] = true
    end
  end
  return tableKeysSorted(ret)
end

local function changeDarknesssColor(color, addedValue)
  local number = tonumber(color:match("(%d+)"))
  if number then
      -- Adding 100 to the number
      local new_number = number + addedValue
      local oValue = color:gsub("(%d+)", tostring(new_number))
      return oValue
  end
    return color
end

local function getFacilitiesData(color)
  local ret = {}
  local facilities = career_modules_delivery_generator.getFacilities()

  for i, fac in ipairs(facilities) do
    table.insert(ret, {
      order = i,
      skill = getSkillsForFacility(fac),
      rewards = getFacilityProgress(fac),
      id = fac.id,
      icon = "garage01",
      label = fac.name,
      description = fac.description,
      locked = false, --need to know if it's unlocked or not
      startable = true, --need to know if it's startable or not
      thumbnailFile = fac.preview,
      tier = 0, --is there any tier?
      color = color,
      blockedColor = changeDarknesssColor(color, 100)
    })
  end
  return ret
end

local function getFiltersForSkills(skills)
  local ret = {}
  for _, s in ipairs(skills) do
    ret[s.id] = {
      value = s.id,
      label = s.name,
      order = s.order,
    }
  end
  return ret
end

local function getBranchPageData(branchId)
  local branch = {}
  local branchData = career_branches.getBranchById(branchId)
  --Setup branch
  if not branchData.isSkill then
    local attKey = branchData.attributeKey
    local value = career_modules_playerAttributes.getAttributeValue(attKey)
    local level, _, _, min, max = career_branches.calcBranchLevelFromValue(value, branchData.id)
    branch.skillInfo = {
      name = branchData.name,
      icon = branchData.icon,
      glyphIcon = branchData.glyphIcon,
      id = attKey,
      levelLabel = {txt='ui.career.lvlLabel', context={lvl=level}},
      min = min,
      value = value,
      max = max,
    }
    --branchData.milestones = career_modules_milestones_milestones.getMilestones({branchData.attributeKey})
    branchData.skills = getSkillsProgressForUi(branchId)
    branch.details = branchData
  end

  --get the missions by branch and type
  local missions = {}
  for i,m in ipairs(gameplay_missions_missions.get()) do
    if m.careerSetup.showInCareer and m.careerSetup.branch == branchId then
      table.insert(missions, m)
    end
  end

  --Sort the misison tables and add them to the main table that will be send to the UI
  branch.missions = {}
  for i, m in ipairs(missions) do
    table.insert(branch.missions, {
      order = i,
      skill = {m.careerSetup.skill},
      rewards = getRewardIcons(m.careerSetup.starRewards),
      id = m.id,
      icon = m.bigMapIcon.icon,
      label = m.name,
      description = m.description,
      formattedProgress =  gameplay_missions_progress.formatSaveDataForUi(m.id),
      startable = m.unlocks.startable,
      preview = m.previewFile,
      locked = not m.unlocks.visible,
      tier = m.unlocks.maxBranchlevel,
      thumbnailFile = m.thumbnailFile,
      difficulty = m.additionalAttributes.difficulty,
      color = branchData.color,
      blockedColor = changeDarknesssColor(branchData.color, 100)
    })
  end

  table.sort(branch.missions, sortByStartable)

  if branch.details.attributeKey == "labourer" then
    branch.facilities = getFacilitiesData(branchData.color)
    table.sort(branch.facilities, sortByFacId)
  end

  branch.filters = getFiltersForSkills(branch.details.skills)
  branch.isBranch = true
  return branch
end


local function getBranchSkillCardData(branchId)

-- first get all branches. then get all skills
  local br = career_branches.getBranchById(branchId)
  local attKey = br.attributeKey
  local value = career_modules_playerAttributes.getAttributeValue(attKey)
  local level, _, _, min, max = career_branches.calcBranchLevelFromValue(value, br.id)
  local branchInfo = {
    name = br.name,
    id = br.id,
    levelLabel = {txt='ui.career.lvlLabel', context={lvl=level}},
    cover = br.progressCover,
    icon = br.icon,
    glyphIcon = br.glyphIcon,
    color = br.color,
    min = min,
    value = value,
    max = max,
    skills = {}
  }

  for _, skill in pairs(career_branches.getSortedBranches()) do
    if skill.isSkill and skill.parentBranch == branchId then
      local attKey = skill.attributeKey
      local value = career_modules_playerAttributes.getAttributeValue(attKey)
      local level, _, _, min, max = career_branches.calcBranchLevelFromValue(value, skill.id)
      local skillInfo = {
        name = skill.name,
        levelLabel = {txt='ui.career.lvlLabel', context={lvl=level}},
        min = min,
        value = value,
        max = max,
        isInDevelopment = skill.isInDevelopment,
      }
      table.insert(branchInfo.skills, skillInfo)
    end
  end
  return branchInfo
end

local function openBigMapWithMissionSelected(missionId)
  freeroam_bigMapMode.enterBigMap({instant = true, missionId = missionId})
end

M.getBranchPageData = getBranchPageData
M.getBranchSkillCardData = getBranchSkillCardData
M.openBigMapWithMissionSelected = openBigMapWithMissionSelected

return M