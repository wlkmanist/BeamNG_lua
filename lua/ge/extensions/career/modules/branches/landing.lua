-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function sortByStartable(m1, m2)
  if m1.unlocks.maxBranchlevel ~= m2.unlocks.maxBranchlevel then
    return m1.unlocks.maxBranchlevel < m2.unlocks.maxBranchlevel
  end
  return m1.unlocks.startable and not m2.unlocks.startable
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
    table.insert(newRet, {attributeKey = attKey, rewardAmount = ret[attKey], icon=career_branches.getBranchIcon(attKey) })
  end
  return newRet
end

local comingSoonCard = {heading="(Not Implemented)", type="unlockCard", icon="roadblockL"}
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
        unlocked = skill.unlocked,
        min = min,
        value = value,
        max = max,
        unlockInfo = {},
        order = skill.order,
        isInDevelopment = skill.isInDevelopment,
        hasLevels = skill.hasLevels,
      }

      if skill.showProgressAsStars then
        local total, unlocked = career_modules_branches_leagues.getStarsForSkill(skill.id)
        skData.levelLabel = nil
        skData.min, skData.value, skData.max = 0, unlocked, total
        skData.showProgressAsStars = true
      end

      local unlocks = skill.levels


      if unlocks then
        local prevTarget = 0
        for i = 1, #unlocks do
          local prevLvlInfo = skill.levels[i-1]
          local curLvlInfo = skill.levels[i]
          local nextLvlInfo = skill.levels[i+1]
          local requiredRelative = (curLvlInfo and curLvlInfo.requiredValue or -1) - prevTarget

          prevTarget = (curLvlInfo and curLvlInfo.requiredValue or -1)
          skData.unlockInfo[i] = {
            list = unlocks[i].unlocks ,
            index = i,
            currentValue = prevLvlInfo and value - prevLvlInfo.requiredValue or -1,
            requiredValue = curLvlInfo and requiredRelative or -1,
            isInDevelopment = unlocks[i].isInDevelopment,
            isMaxLevel = unlocks[i].isMaxLevel,
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

local deliverySystemIcon = {
  parcelDelivery = "boxPickUp03",
  trailerDelivery = "smallTrailer",
  vehicleDelivery = "keys1",
  smallFluidDelivery = "tankerTrailer",
  largeFluidDelivery = "tankerTrailer",
  smallDryBulkDelivery = "terrain",
  largeDryBulkDelivery = "terrain",
}

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
        rewardAmount = fac.progress.deliveredFromHere.countByType[key],
        icon = deliverySystemIcon[key]
      })
    end
  end

  for key, value in pairs(fac.receivedSystemsLookup) do
    if value then
      table.insert(ret.deliveredToHere.countByType, {
        attributeKey = key,
        rewardAmount = fac.progress.deliveredToHere.countByType[key],
        icon = deliverySystemIcon[key]
      })
    end
  end

  return ret
end

local deliverySystemToSkill = {
  vehicleDelivery = "vehicleDelivery",
  parcelDelivery = "delivery",
  trailerDelivery = "delivery",
  smallDryBulkDelivery = "delivery",
  largeDryBulkDelivery = "delivery",
  smallFluidDelivery = "delivery",
  largeFluidDelivery = "delivery",
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

local function getFacilityAvailableOrders(fac)
  local ret = {}
  -- parcels
  local amounts = {[1]=0, [2]=0, [3]=0, [4]=0, [5]=0, total = 0}
  for _, item in ipairs(career_modules_delivery_parcelManager.getAllCargoForFacilityUnexpiredUndelivered(fac.id)) do
    career_modules_delivery_generator.finalizeParcelItemDistanceAndRewards(item)
    local modifierKeys = {}
    for _, mod in ipairs(item.modifiers or {}) do
      modifierKeys[mod.type] = true
    end
    local lockedBecauseOfMods, minTier = career_modules_delivery_parcelMods.lockedBecauseOfMods(modifierKeys)
    amounts[minTier] = amounts[minTier] + 1
    amounts.total = amounts.total + 1
  end

  table.insert(ret, {
    icon = "cardboardBox",
    label = "Available Parcels",
    amounts = amounts,
    level = career_branches.getBranchLevel("delivery"),
  })

  -- trailers + vehicles
  for _, t in ipairs({
    {key="trailer", icon="smallTrailer", label="Available Trailers", skill="delivery"},
    {key="vehicle", icon="keys1",        label="Available Vehicles", skill="vehicleDelivery"}
  }) do
    local amounts = {[1]=0, [2]=0, [3]=0, [4]=0, [5]=0, total = 0}
    for _, item in ipairs(career_modules_delivery_vehicleOfferManager.getAllOfferAtFacilityUnexpired(fac.id)) do
      if item.data.type == t.key then
        local enabled, reason = career_modules_delivery_vehicleOfferManager.isVehicleTagUnlocked(item.vehicle.unlockTag)
        amounts[reason.level] = amounts[reason.level] + 1
        amounts.total = amounts.total + 1
      end
    end
    table.insert(ret, {
      icon = t.icon,
      label = t.label,
      amounts = amounts,
      level = career_branches.getBranchLevel(t.skill),
    })
  end


  return ret

end

local function getFacilitiesData(color)
  local ret = {}
  local facilities = career_modules_delivery_generator.getFacilities()

  for i, fac in ipairs(facilities) do
    local data = {
      order = i,
      skill = getSkillsForFacility(fac),
      rewards = getFacilityProgress(fac),
      availableOrders = getFacilityAvailableOrders(fac),
      id = fac.id,
      icon = "garage01",
      label = fac.name,
      description = fac.description,
      visible = fac.progress.interacted or fac.alwaysVisible,
      locked = false, --need to know if it's unlocked or not
      startable = true, --need to know if it's startable or not
      thumbnailFile = fac.preview,
      tier = 0, --is there any tier?
      color = color,
      blockedColor = changeDarknesssColor(color, 100)
    }
    data.hasOrders = false
    for _, orders in ipairs(data.availableOrders) do
      if orders.amounts.total > 0 then
        data.hasOrders = true
      end
    end
    if data.hasOrders then
      table.insert(ret,data)
    end
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
      glyphIcon = branchData.icon,
      color = branchData.color,
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

  branch.leagues = career_modules_branches_leagues.getLeaguesForProgressBranchPage(branchId)

  --get the missions by branch and type

  local i = 1
  for _, skill in ipairs(career_branches.getSortedBranches()) do
    if skill.isSkill and skill.parentBranch == branchId then
      local missions = {}
      for i,m in ipairs(gameplay_missions_missions.get()) do
        if m.careerSetup.showInCareer and m.careerSetup.skill == skill.id and not career_modules_branches_leagues.startConditionIncludesLeague(m.startCondition) and not m.devMission then
          table.insert(missions, m)
          --dump(m.id, m.unlocks.maxBranchlevel)
        end
      end
      -- local driftSpots = {}
      -- if skill.id == "drift" then
      --   for i,ds in pairs(gameplay_drift_saveLoad.getDriftSpotsById()) do
      --     if not ds._isInLeague then
      --       table.insert(driftSpots, ds)
      --     end
      --   end
      -- end

       if next(missions) then
         table.sort(missions, sortByStartable)
         local noLeague = career_modules_branches_leagues.getNoLeague(skill, missions, driftSpots)
         noLeague.skillId = skill.id
         table.insert(branch.leagues, i, noLeague)
         i = i+1
       end
    end
  end


  --Sort the misison tables and add them to the main table that will be send to the UI
  for _, league in ipairs(branch.leagues) do
    for i, mId in ipairs(league.missions) do
      local m = gameplay_missions_missions.getMissionById(mId)
      league.missions[i] = M.formatMission(m)
    end

    for i, dsId in ipairs(league.driftSpots or {}) do
      local spot = gameplay_drift_saveLoad.getDriftSpotById(dsId)
      league.driftSpots[i] = M.formatDriftSpot(spot)
    end

  end

--[[
  local driftLeague = {
    id = "driftSpotLeague",
    name = "Drift Spots",
    icon = "drift02",
    description = "Drift spots around the map.",
    skillId = "drift",
    missions = {},
    _unlocked = true,
    totalStarsAvailable = 0,
    totalStarsObtained = 0,
  }
  local driftSpots = {}
  for id, ds in pairs(gameplay_drift_saveLoad.getDriftSpotsById()) do
    table.insert(driftSpots, ds)
  end
  table.sort(driftSpots, function(a,b) return a.id<b.id end)
  local driftSpotsFormatted = {}
  for _, ds in ipairs(driftSpots) do
    driftLeague.totalStarsAvailable = driftLeague.totalStarsAvailable + #ds.info.objectives
    local formatted = M.formatDriftSpot(ds)
    if formatted.formattedProgress then
      driftLeague.totalStarsObtained = driftLeague.totalStarsObtained + formatted.formattedProgress.unlockedStars.defaultCount
    end
    table.insert(driftLeague.missions, formatted)
  end
  table.insert(branch.leagues, 1, driftLeague)
]]


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
    unlocked = br.unlocked,
    cover = br.progressCover,
    icon = br.icon,
    glyphIcon = br.icon,
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
        unlocked = skill.unlocked,
        min = min,
        value = value,
        max = max,
        isInDevelopment = skill.isInDevelopment,
        hasLevels = skill.hasLevels,
      }
      if skill.showProgressAsStars then
        local total, unlocked = career_modules_branches_leagues.getStarsForSkill(skill.id)
        skillInfo.levelLabel = nil
        skillInfo.min, skillInfo.value, skillInfo.max = 0, unlocked, total
        skillInfo.showProgressAsStars = true
      end
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

local formatMission = function(m)
  return {
    skill = {m.careerSetup.skill},
    id = m.id,
    icon = m.bigMapIcon.icon,
    label = m.name,
    formattedProgress =  gameplay_missions_progress.formatSaveDataForUi(m.id),
    startable = m.unlocks.startable,
    preview = m.previewFile,
    locked = not m.unlocks.visible,
  }
end
M.formatMission = formatMission


local formatDriftSpot = function(ds)
  local ret = {
    skill = {"drift"},
    id = ds.id,
    icon = "drift02",
    label = ds.info.name,
    startable = true,
    preview = ds.info.preview,
  }
  if ds.info.objectives then
    local defaults = {}
    local defaultCount = 0
    for _, obj in ipairs(ds.info.objectives) do
      table.insert(defaults, ds.saveData.objectivesCompleted[obj.id] or false)
      defaultCount = defaultCount + (ds.saveData.objectivesCompleted[obj.id] and 1 or 0)
    end
    local formattedProgress = {
      unlockedStars = {
        totalBonusStarCount = 0,
        defaults = defaults,
        defaultCount = defaultCount
      }
    }
    ret.formattedProgress = formattedProgress
  end
  return ret
end
M.formatDriftSpot = formatDriftSpot
return M