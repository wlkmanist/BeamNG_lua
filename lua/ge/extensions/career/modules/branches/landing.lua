-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local isStartable = gameplay_missions_unlocks.isMissionStartable
local isVisible = gameplay_missions_unlocks.isMissionVisible

local function sortByStartable(m1, m2)
  local f1 = gameplay_missions_unlocks.getForwardMissionInfo(m1)
  local f2 = gameplay_missions_unlocks.getForwardMissionInfo(m2)
  if f1.maxBranchLevel ~= f2.maxBranchLevel then
    return f1.maxBranchLevel < f2.maxBranchLevel
  end
  return isStartable(m1) and not isStartable(m2)
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
local function calculateUnlockInfo(skill, value, level)
  local unlockInfo = {}
  local unlocks = skill.levels
  local hasUnlocks = false

  if unlocks then
    local prevTarget = 0
    for i = 1, #unlocks do
      local prevLvlInfo = skill.levels[i-1]
      local curLvlInfo = skill.levels[i]
      local nextLvlInfo = skill.levels[i+1]
      local requiredRelative = (curLvlInfo and curLvlInfo.requiredValue or -1) - prevTarget



      prevTarget = (curLvlInfo and curLvlInfo.requiredValue or -1)
      unlockInfo[i] = {
        index = i,
        currentValue = prevLvlInfo and value - prevLvlInfo.requiredValue or -1,
        requiredValue = curLvlInfo and requiredRelative or -1,
        xpCurrent = value,
        xpRequired = curLvlInfo and curLvlInfo.requiredValue or -1,
        isInDevelopment = unlocks[i].isInDevelopment,
        isMaxLevel = unlocks[i].isMaxLevel,
        isBase = i == 1,
        unlocked = i >= level,
        description = unlocks[i].description,
      }
      if (unlocks[i].unlocks and #unlocks[i].unlocks > 0) or unlocks[i].description then
        hasUnlocks = true
      end
      local list = {}
      for _, unlock in ipairs(unlocks[i].unlocks or {}) do
        if unlock.type == "tasklist" then
          local tasklistData = {}
          extensions.hook("onCareerProgressPageGetTasklistData", tasklistData, unlock.tasklistId)
          if tasklistData and next(tasklistData) then
            unlock.tasklistData = tasklistData
          end
          table.insert(list, unlock)
          unlock.type = "tasklist"
        else
          table.insert(list, unlock)
          unlock.type = "unlockCard"
        end
      end
      unlockInfo[i].list = list

    end
  end

  local maxRequiredValue = 0
  for _, value in ipairs(unlockInfo) do
    maxRequiredValue = maxRequiredValue + value.requiredValue
  end

  return unlockInfo, maxRequiredValue, hasUnlocks
end

local function getSkillsProgressForUi(branchId)
  local ret = {}
  --dump("getting skills for " .. branchId)
  for _, skill in pairs(career_branches.getSortedBranches()) do
    --dump(branchId .. " is a skill of " .. skill.id.." / "..dumps( skill.parentId))
    if skill.parentId == branchId then
      local attKey = skill.attributeKey
      local value = career_modules_playerAttributes.getAttributeValue(attKey)
      local level, _, _, min, max = career_branches.calcBranchLevelFromValue(value, skill.id)
      local skData = {
        icon = skill.icon,
        isSkill = skill.isSkill,
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
        color = skill.color,
        accentColor = skill.accentColor,
      }

      if skill.showProgressAsStars then
        local total, unlocked = career_modules_branches_leagues.getStarsForSkill(skill.id)
        skData.levelLabel = nil
        skData.min, skData.value, skData.max = 0, unlocked, total
        skData.showProgressAsStars = true
      end

      if skill.levels then
        skData.unlockInfo, skData.maxRequiredValue, skData.hasUnlocks = calculateUnlockInfo(skill, value, level)
      end
      --dumpz(skData.unlockInfo,2)

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
  vehicleDelivery = "logistics-vehicleDelivery",
  parcelDelivery = "logistics-delivery",
  trailerDelivery = "logistics-delivery",
  smallDryBulkDelivery = "logistics-delivery",
  largeDryBulkDelivery = "logistics-delivery",
  smallFluidDelivery = "logistics-delivery",
  largeFluidDelivery = "logistics-delivery",
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
  local amounts = {available = 0, locked = 0}
  for _, item in ipairs(career_modules_delivery_parcelManager.getAllCargoForFacilityUnexpiredUndelivered(fac.id)) do
    career_modules_delivery_generator.finalizeParcelItemDistanceAndRewards(item)
    local modifierKeys = {}
    for _, mod in ipairs(item.modifiers or {}) do
      modifierKeys[mod.type] = true
    end
    local lockedBecauseOfMods, minTier = career_modules_delivery_parcelMods.lockedBecauseOfMods(modifierKeys)
    if lockedBecauseOfMods then
      amounts.locked = amounts.locked + 1
    else
      amounts.available = amounts.available + 1
    end
  end

  table.insert(ret, {
    icon = "cardboardBox",
    label = "Available Parcels",
    amounts = amounts,
    level = career_branches.getBranchLevel("logistics-delivery"),
  })

  -- trailers + vehicles
  for _, t in ipairs({
    {key="trailer", icon="smallTrailer", label="Available Trailers", skill="logistics-delivery"},
    {key="vehicle", icon="keys1",        label="Available Vehicles", skill="logistics-vehicleDelivery"}
  }) do
    local amounts = {available = 0, locked = 0}
    for _, item in ipairs(career_modules_delivery_vehicleOfferManager.getAllOfferAtFacilityUnexpired(fac.id)) do
      if item.data.type == t.key then
        local enabled, reason = career_modules_delivery_vehicleOfferManager.isVehicleTagUnlocked(item.vehicle.unlockTag)
        if enabled then
          amounts.available = amounts.available + 1
        else
          amounts.locked = amounts.locked + 1
        end
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
      if orders.amounts.available > 0 or orders.amounts.locked > 0 then
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


local function getBranchSkillCardData(branchId)
  -- first get all branches. then get all skills
  career_branches.checkUnlocks()
  local br = career_branches.getBranchById(branchId)
  local attKey = br.attributeKey
  local value = career_modules_playerAttributes.getAttributeValue(attKey)
  local level, _, _, min, max = career_branches.calcBranchLevelFromValue(value, br.id)
  local branchInfo = {
    name = br.name,
    description = br.description,
    shortDescription = br.shortDescription,
    id = br.id,
    levelLabel = career_branches.getLevelLabel(br.id, level),
    isMaxLevel = level >= #br.levels,
    unlocked = br.unlocked,
    cover = br.progressCover,
    icon = br.icon,
    glyphIcon = br.icon,
    color = br.color,
    accentColor = br.accentColor,
    min = min,
    value = value,
    max = max,
    skills = {},
    isDomain = br.isDomain,
    isSkill = br.isSkill,
    showProgressAsStars = br.showProgressAsStars,
    level = level,
    certifications = {},
    lockedReason = br.lockedReason,
    unlockInfos = br.unlockInfos,
    isInDevelopment = br.isInDevelopment,
  }

  if br.showProgressAsStars then
    local total, unlocked = career_modules_branches_leagues.getStarsForSkill(br.id)
    branchInfo.levelLabel = nil
    branchInfo.min, branchInfo.value, branchInfo.max = 0, unlocked, total
    branchInfo.showProgressAsStars = true
  end


  -- certifications
  for _, certification in ipairs(br.certifications or {}) do
    local unlocked = career_modules_unlockFlags.getFlag(certification.unlockFlag)
    local flagDefinition = career_modules_unlockFlags.getFlagDefinition(certification.unlockFlag)
    local status =  "locked"
    local certificationMission = gameplay_missions_missions.getMissionById(certification.requiredMissionsToPass)
    if certificationMission and isStartable(certificationMission) then
      status = "available"
    end
    if unlocked then
      status = "completed"
    end
    if br.name == "Commercial" then
      status = "available"
    end
    table.insert(branchInfo.certifications, {
      status = status,
      name = "ui.career.certification.name",
      statusLabel = 'ui.career.certification.status.' .. status,
      icon = "badgeRoundStar",
    })
  end

  for _, subBranch in pairs(career_branches.getSortedBranches()) do
    if subBranch.parentId == branchId then
      local attKey = subBranch.attributeKey
      local value = career_modules_playerAttributes.getAttributeValue(attKey)
      local level, _, _, min, max = career_branches.calcBranchLevelFromValue(value, subBranch.id)
      local skillInfo = {
        id = subBranch.id,
        name = subBranch.name,
        levelLabel = career_branches.getLevelLabel(subBranch.id, level),
        isMaxLevel = level >= #subBranch.levels,
        unlocked = subBranch.unlocked,
        min = min,
        value = value,
        max = max,
        isInDevelopment = subBranch.isInDevelopment,
        hasLevels = subBranch.hasLevels,
        icon = subBranch.icon,
        level = level,
        color = subBranch.color,
        accentColor = subBranch.accentColor,
        showProgressAsStars = subBranch.showProgressAsStars,
        isBranch = subBranch.isBranch,
        isSkill = subBranch.isSkill,
      }
      if subBranch.showProgressAsStars then
        local total, unlocked = career_modules_branches_leagues.getStarsForSkill(subBranch.id)
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
  freeroam_bigMapMode.enterBigMap({
    instant = true,
    missionId = missionId,
    routeTarget = "career.branchPage.bigmap",
    routeParams = {
      autoSelectPoiId = missionId,
    },
  })
end

M.getBranchSkillCardData = getBranchSkillCardData
M.openBigMapWithMissionSelected = openBigMapWithMissionSelected

local formatMission = function(m)
  local previewFile = m.previewFile
  if previewFile and previewFile:sub(1, 1) == "/" then
    previewFile = previewFile:sub(2)
  end
  return {
    skill = {m.careerSetup.skill},
    id = m.id,
    icon = m.iconFontIcon,
    label = m.name,
    description = m.description,
    missionTypeLabel = m.missionTypeLabel or m.missionType,
    devMission = m.devMission,
    formattedProgress =  gameplay_missions_progress.formatSaveDataForUi(m.id),
    startable = isStartable(m),
    preview = previewFile,
    previews = previewFile and {previewFile} or {},
    thumbnail = m.thumbnailFile,
    locked = not isVisible(m),
    canStartFromProgressScreen = m.startTrigger.level ~= nil and m.startTrigger.type == "league",
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

local function getMissionStarCounts(formattedProgress)
  local stars = formattedProgress and formattedProgress.unlockedStars or {}
  local defaultTotal = stars.totalDefaultStarCount or 0
  local bonusTotal = stars.totalBonusStarCount or 0
  local defaultCount = stars.defaultUnlockedStarCount or stars.defaultCount or 0
  local bonusCount = stars.bonusUnlockedStarCount or stars.bonusCount or 0
  if type(stars.defaults) == "table" then
    defaultCount = 0
    for _, unlocked in pairs(stars.defaults) do
      if unlocked then defaultCount = defaultCount + 1 end
    end
  end
  if type(stars.bonus) == "table" then
    bonusCount = 0
    for _, unlocked in pairs(stars.bonus) do
      if unlocked then bonusCount = bonusCount + 1 end
    end
  end
  return defaultCount + bonusCount, defaultTotal + bonusTotal
end

local function addSuggestedMission(candidates, missionId)
  local mission = gameplay_missions_missions.getMissionById(missionId)
  if not mission then return end

  local formattedMission = formatMission(mission)
  local achievedStars, totalStars = getMissionStarCounts(formattedMission.formattedProgress)
  if totalStars <= 0 then return end

  if achievedStars == 0 then
    table.insert(candidates.none, formattedMission)
  elseif achievedStars < totalStars then
    table.insert(candidates.partial, formattedMission)
  end
end

local function collectSuggestedMissions(branchId, candidates)
  local childBranches = {}
  local childSkills = {}
  for _, branch in ipairs(career_branches.getSortedBranches()) do
    if branch.parentId == branchId then
      if branch.isBranch then
        table.insert(childBranches, branch)
      elseif branch.isSkill then
        table.insert(childSkills, branch)
      end
    end
  end

  for _, branch in ipairs(childBranches) do
    if not branch.isInDevelopment then
      collectSuggestedMissions(branch.id, candidates)
    end
  end

  for _, skill in ipairs(childSkills) do
    if not skill.isInDevelopment then
      local leagues = career_modules_branches_leagues.getLeaguesForProgressBranchPage(skill.id, true)
      for _, league in ipairs(leagues) do
        for _, missionId in ipairs(league.missions or {}) do
          addSuggestedMission(candidates, missionId)
        end
      end
    end
  end
end

local function getSuggestedMissionsForDomain(domainId)
  local candidates = {none = {}, partial = {}}
  collectSuggestedMissions(domainId or "apm", candidates)

  local suggested = {}
  if candidates.none[1] then table.insert(suggested, candidates.none[1]) end
  if candidates.partial[1] then
    table.insert(suggested, candidates.partial[1])
  elseif candidates.none[2] then
    table.insert(suggested, candidates.none[2])
  end

  return suggested
end
M.getSuggestedMissionsForDomain = getSuggestedMissionsForDomain

local function resolveBranchTitle(pathId)
  local branch = pathId and career_branches.getBranchById(pathId) or nil
  if branch and not branch.missing then
    return core_locales.translateWithOrWithoutContext(branch.branchHeading or branch.name)
  end
  return _tr("ui.career.landingPage.name")
end
M.resolveBranchTitle = resolveBranchTitle

local function getLandingPageData(pathId)
  local data = {
    heading = "ui.career.landingPage.name",
    description = "ui.career.landingPage.description",
    branches = {},
    breadcrumbs = {{label = _tr("ui.environment.pause"), routeName = "pause"}}
  }
  table.insert(data.breadcrumbs, {label = _tr("ui.career.landingPage.name"), routeName = "career.domainSelection"})

  local branches = career_branches.getSortedBranches()

  if not pathId or pathId == "" or pathId == "undefined" then
    --data.showMilestones = true
    -- Find all domains and determine their target type
    for _, branch in ipairs(branches) do
      if branch.isDomain then
        local hasBranches = false
        -- Check children of this domain
        for _, childBranch in ipairs(branches) do
          if childBranch.parentId == branch.id and childBranch.isBranch then
            hasBranches = true
            break
          end
        end
        table.insert(data.branches, {
          id = branch.id,
          target = hasBranches and "landing" or "skillPage",
          isSkill = branch.isSkill,
          description = branch.description,
        })
      end
    end
  else
    -- Find branches for this domain
    for _, branch in ipairs(branches) do
      if branch.parentId == pathId then
        table.insert(data.branches, {
          id = branch.id,
          target = "skillPage",
          isSkill = branch.isSkill,
          description = branch.description,
        })
      end
    end

    -- Set heading/description based on domain
    local domainBranch = career_branches.getBranchById(pathId)
    if domainBranch then

      local rewardMultiplier = career_branches.getLevelRewardMultiplier(domainBranch.id)
      local rewardMultiplierSourceIcon = rewardMultiplier and domainBranch.icon

      local parentBreadcrumbs = {}
      local parentBranch = career_branches.getBranchById(domainBranch.parentId)
      table.insert(parentBreadcrumbs, {label = core_locales.translateWithOrWithoutContext(domainBranch.name), routeName = "career.branchPage", params = {pathId = domainBranch.id}})
      while parentBranch and not parentBranch.missing do
        rewardMultiplier = rewardMultiplier or career_branches.getLevelRewardMultiplier(parentBranch.id)
        rewardMultiplierSourceIcon = rewardMultiplierSourceIcon or (rewardMultiplier and parentBranch.icon)
        table.insert(parentBreadcrumbs, {label = core_locales.translateWithOrWithoutContext(parentBranch.name), routeName = "career.branchPage", params = {pathId = parentBranch.id}})
        parentBranch = career_branches.getBranchById(parentBranch.parentId)
      end
      arrayReverse(parentBreadcrumbs)
      for _, breadcrumb in ipairs(parentBreadcrumbs) do
        table.insert(data.breadcrumbs, breadcrumb)
      end

      data.heading = domainBranch.name
      data.description = domainBranch.description
      data.branchHeading = domainBranch.branchHeading
      local attKey = domainBranch.attributeKey
      local value = career_modules_playerAttributes.getAttributeValue(attKey)
      local level, _, _, min, max = career_branches.calcBranchLevelFromValue(value, domainBranch.id)
      data.skillInfo = {
        name = domainBranch.name,
        icon = domainBranch.icon,
        glyphIcon = domainBranch.icon,
        color = domainBranch.color,
        accentColor = domainBranch.accentColor,
        unlocked = domainBranch.unlocked,
        levelLabel = career_branches.getLevelLabel(domainBranch.id, level),
        isMaxLevel = level >= #domainBranch.levels,
        isInDevelopment = domainBranch.isInDevelopment,
        min = min,
        value = value,
        max = max,
        level = level,
        hasLevels = domainBranch.hasLevels,
        rewardMultiplier = rewardMultiplier,
        rewardMultiplierSourceIcon = rewardMultiplierSourceIcon,
      }

      if domainBranch.showProgressAsStars then
        local total, unlocked = career_modules_branches_leagues.getStarsForSkill(domainBranch.id)
        data.skillInfo.min, data.skillInfo.value, data.skillInfo.max = 0, unlocked, total
        data.skillInfo.showProgressAsStars = true
      end

      if domainBranch.isBranch or domainBranch.isSkill then
        if domainBranch.levels then
          data.skillInfo.unlockInfo, data.skillInfo.maxRequiredValue, data.skillInfo.hasUnlocks = calculateUnlockInfo(domainBranch, value, level)
        end
        data.skillInfo.hasUnlocks = data.skillInfo.hasUnlocks or false

        data.skills = getSkillsProgressForUi(domainBranch.id)

        data.leagues = career_modules_branches_leagues.getLeaguesForProgressBranchPage(domainBranch.id, true  )


        --Sort the misison tables and add them to the main table that will be send to the UI
        for _, league in ipairs(data.leagues) do
          for i, mId in ipairs(league.missions) do
            local m = gameplay_missions_missions.getMissionById(mId)
            league.missions[i] = M.formatMission(m)
            if league.isCertification then
              league.missions[i].icon = "badgeRoundStar"
            end
          end
        end

--[[
        if domainBranch.attributeKey == "logistics" then
          data.facilities = getFacilitiesData(data.color)
          table.sort(data.facilities, sortByFacId)
        end
]]
        data.isBranch = true
      end
    end

  end
  return data
end

M.getLandingPageData = getLandingPageData


M.onComputerAddFunctions = function(menuData, computerFunctions)
  if menuData.computerFacility.functions["apmLandingPage"] then
    local computerFunctionData = {
      id = "apmLandingPage",
      routeTarget = "career.branchPage",
      label = _tr("ui.career.APM.name") ..' ' .. _tr("ui.career.landingPage.name"),
      icon = "garage01",
      callback = function()
        guihooks.trigger('ChangeState', {state = 'career.branchPage', params = {pathId = "apm", returnRoute = "career.computer"}})
      end,
      disabled = not menuData.hasBoughtStarterVehicle,
      reason = (not menuData.hasBoughtStarterVehicle) and career_modules_computer.reasons.hasBoughtStarterVehicle or nil,
    }
    computerFunctions.general[computerFunctionData.id] = computerFunctionData
  end
end

return M