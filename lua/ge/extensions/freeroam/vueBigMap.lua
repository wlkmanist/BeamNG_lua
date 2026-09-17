-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'gameplay_missions_missions','freeroam_bigMapMode', 'gameplay_rawPois', 'gameplay_missions_missionScreen'}

--[[
    enterBigMap: () => {}, -- initializes lua backend, creates caches etc
    exitBigMap: () => {}, -- clears caches

    getPoiData: () => {}, -- gives the full poi data by id: name, preview, aggregates, available actions
    getFilters: () => {}, -- filter icons, sorted first by type, then by group id
    {
      {
        key = 'careerPois',
        icon = 'flag',
        label = 'Career POIs',
        groups = {
          { key = 'type_garage', label = 'Garages', icon = 'garage01', elementCount = 5, visible = true },
          { key = 'type_gasStation', label = 'Gas Stations', icon = 'fuelPump', elementCount = 3, visible = false }
        }
      },
      {
        ...
      }
    }


    getGroups: () => {}, -- groups for the poiList, sorted again by type
    {
      {
        key = 'careerPois',
        icon = 'flag',
        label = 'Career POIs',
        groups = {
          { key = 'type_garage', label = 'Garages', icon = 'garage01', elements = [...], visible = true }, -- elements is poi ids
          -- not including type_gasStation because its not visible
        }
      },
      {
        ...
      }
    }


    toggleFiltersByIds: (groupKey) => String, -- toggles a group by group key
    getGameStateInfo: () => {}, -- game state info for the poiList

    selectPoiFromList: (poiId) => String, -- selects a poi from the list, highlighting the poi bigmapmarker and triggering showPoiDetails
    hoverPoiFromList: (poiId, active) => [String, Boolean], -- hovers a poi from the list, highlighting the poi bigmapmarker
    executePoiAction: (poiId, action) => [String, String], -- executes an action on a poi
    getAndClearPendingAutoSelectPoiId: () => String|nil, -- consumes the poiId requested via enterBigMap({autoSelectPoiId = ...}), for the UI to select once ready

    -- calls from lua to vue:
    showPoiDetails: (poiIds) => List of PoiIds, (can also be empty or a single poi) (guihooks.trigger('showPoiDetails', {poiIds}))
--]]

-- Cache variables
local poiDataCache = {}
local groupStructureCache = {}
local filterStructureCache = {}
local gameStateInfoCache = {}
local cacheValid = false

-- Group visibility state storage
local filterVisibilityState = {}

-- Action management system (like detailsInteraction.lua)
M.actionIdCounter = 0
M.actionFunctions = {}


-- Function to invalidate cache
local function invalidateCache()
  poiDataCache = {}
  groupStructureCache = {}
  gameStateInfoCache = {}
  filterStructureCache = {}
  cacheValid = false
end


-- Function to toggle group visibility
local function toggleFiltersByIds(filterIds)
  for filterId, state in pairs(filterVisibilityState) do
    filterVisibilityState[filterId] = false
  end
  for _, filterId in ipairs(filterIds) do
    filterVisibilityState[filterId] = true
  end
  M.setVisibleIds()
end

local function toggleFilterSectionById(sectionId)
  if sectionId == "everything" then
    -- Make everything visible
    for _, filterSection in ipairs(groupStructureCache) do
      for _, group in ipairs(filterSection.groups) do
        filterVisibilityState[group.key] = true
      end
    end
  else
    -- Hide all groups first
    for _, filterSection in ipairs(groupStructureCache) do
      for _, group in ipairs(filterSection.groups) do
        filterVisibilityState[group.key] = false
      end
    end
    -- Then make only the groups in the selected filter section visible
    for _, filterSection in ipairs(groupStructureCache) do
      if filterSection.key == sectionId then
        for _, group in ipairs(filterSection.groups) do
          filterVisibilityState[group.key] = true
        end
      end
    end
  end
  M.setVisibleIds()
end

-- Get a free action ID
local function getFreeActionId()
  M.actionIdCounter = M.actionIdCounter + 1
  return M.actionIdCounter
end

-- Clear all action functions
local function clearActionFunctions()
  M.actionFunctions = {}
end

-- Add an action with callback function
local function addAction(callback, meta)
  local actionId = getFreeActionId()
  M.actionFunctions[actionId] = callback

  meta = meta or {}
  meta.actionId = actionId
  return meta
end

-- Execute action callback by ID
local function executeAction(actionId)
  if M.actionFunctions[actionId] then
    M.actionFunctions[actionId]()
    return "success"
  else
    log("E", "", "Action function not found for ID: " .. tostring(actionId))
    return "error"
  end
end

-- POI type icons mapping
local poiTypeIcons = {
  spawnPoint = 'fastTravel',
  garage = 'garage01',
  gasStation = 'fuelPump',
  dealership = 'carDealer',
  logisticsParking = 'boxTruckFast',
  logisticsOffice = 'boxTruckFast',
  computer = 'screen',
  driftSpot = 'drift01',
  dragstrip = 'drag02',
  crawl = 'rockCrawling02',
  playerVehicle = 'carStarred',
  other = 'info',
}

-- Format POI for bigmap
local function formatPoiForBigmap(poi)
  local bmi = poi.markerInfo.bigmapMarker
  local qtEnabled = ((not career_career.isActive()) or (career_career.isActive() and career_modules_tutorial.isActive())) and bmi.quickTravelPosRotFunction
  local icon = bmi.cardIcon or poiTypeIcons[poi.data.type]
  local actions = {}
  table.insert(actions, addAction(
    function()
      freeroam_bigMapMode.navigateToMission(poi.id)
    end,
    {
      id = "setRoute",
      label = "bigMap.action.setRoute",
      icon = "mapPoint",
      soundClass = 'bng_click_set_route'
    }
  ))

  if qtEnabled then
    table.insert(actions, addAction(
      function()
        freeroam_bigMapMode.teleportToPoi(poi.id)
      end,
      {
        id = "quickTravel",
        label = "bigMap.action.quickTravel",
        icon = "fastTravel",
      }
    ))
  end

  return {
    id = poi.id,
    icon = icon,
    name = bmi.name,
    description = bmi.description,
    thumbnailFile = bmi.thumbnail,
    previewFiles = bmi.previews,
    type = poi.data.type,
    label = '',
    aggregatePrimary = bmi.aggregatePrimary,
    aggregateSecondary = bmi.aggregateSecondary,
    actions = actions,
    order = poi.data.order,
  }
end

-- Format mission for bigmap
local function formatMissionForBigmap(elemData)
  local mission = gameplay_missions_missions.getMissionById(elemData.missionId)
  local qtEnabled = (not career_career.isActive()) or (career_career.isActive() and career_modules_tutorial.isActive())
  if mission then
    local ret = {
      id = elemData.missionId,
      icon = mission.iconFontIcon,
      idInCluster = elemData.idInCluster,
      name = mission.name,
      label = mission.missionTypeLabel or mission.missionType,
      description = mission.description,
      thumbnailFile = mission.thumbnailFile,
      previewFiles = {mission.previewFile},
      type = "mission",
      devMission = mission.devMission or false,
    }
    ret.formattedProgress = gameplay_missions_progress.formatSaveDataForUi(elemData.missionId)
    ret.requiredVehicleClass = gameplay_missions_missionScreen and gameplay_missions_missionScreen.resolveMissionVehicleClassRequirement(mission) or nil
    ret.defaultVehicleClass = gameplay_missions_missionScreen and gameplay_missions_missionScreen.resolveDefaultMissionVehicleClass(mission) or nil
    ret.requirementState = gameplay_missions_missionScreen and gameplay_missions_missionScreen.resolveRequirementState(ret.defaultVehicleClass, ret.requiredVehicleClass) or "unknown"

    for key, val in pairs(gameplay_missions_progress.formatSaveDataForBigmap(mission.id) or {}) do
      ret[key] = val
    end

    local actions = {}

    table.insert(actions, addAction(
      function()
        freeroam_bigMapMode.navigateToMission(ret.id)
      end,
      {
        id = "setRoute",
        label = "bigMap.action.setRoute",
        icon = "mapPoint",
        soundClass = 'bng_click_set_route'
      }
    ))

    if qtEnabled then
      table.insert(actions, addAction(
        function()
          freeroam_bigMapMode.teleportToPoi(ret.id)
        end,
        {
          id = "quickTravel",
          label = "bigMap.action.quickTravel",
          icon = "fastTravel",
        }
      ))
    end
    ret.actions = actions

    return ret
  end
  return nil
end


local noBranch = "branch_noBranch"
-- Helper function to build group data structure
local function buildGroupData()

  local groupData = {
    type_mission = {label = "bigMap.group.type.mission"},
    type_driftSpots = {label = "bigMap.group.type.driftSpots", icon = "drift01"},
    type_dragstrip = {label = "bigMap.group.type.dragstrip", icon = "drag02"},
    type_crawl = {label = "bigMap.group.type.crawl", icon = "rockCrawling02"},
    type_spawnPoint = {label = "bigMap.group.type.spawnPoint", icon = "fastTravel"},
    type_garage = {label = "bigMap.group.type.garage", icon = "garage01"},
    type_gasStation = {label = "bigMap.group.type.gasStation", icon = "fuelPump"},
    type_dealership = {label = "bigMap.group.type.dealership", icon = "carDealer"},
    type_playerVehicle = {label = "bigMap.group.type.playerVehicle", icon = "carStarred"},
    type_computer = {label = "bigMap.group.type.computer", icon = "screen"},
    type_apm_computer = {label = "bigMap.group.type.computer", icon = "screen"},
    type_other = {label = "bigMap.group.type.other"},
  }

  if career_career.isActive() then
    groupData.delivery_facility = {label = "bigMap.group.deliveryFacility"}
    groupData.delivery_dropoff = {label = "bigMap.group.deliveryDropoff"}

    for _, branch in ipairs(career_branches.getSortedBranches()) do
      if branch and not branch.isDomain then
        local domain = career_branches.getBranchById(branch.parentDomain)
        groupData["branch_"..branch.id] = {label = {txt = "ui.career.domainSlashBranch", context={domain=domain.name, branch=branch.name}}}
      end
    end
    groupData[noBranch] = {label = "bigMap.group.branchlessMissions"}
  end

  extensions.hook("onBigmapBuildGroupData", groupData)

  for groupKey, gr in pairs(groupData) do
    gr.elements = {}
  end

  return groupData
end

-- Helper function to process mission POI data
local function processMissionPoi(poi, groupData)
  local formatted = formatMissionForBigmap(poi.data)
  local filterData = {
    groupTags = {},
    sortingValues = {}
  }

  filterData.sortingValues['id'] = poi.id
  filterData.groupTags['type_mission'] = true

  local mission = gameplay_missions_missions.getMissionById(poi.data.missionId)
  --local forwardInfo = gameplay_missions_unlocks.getForwardMissionInfo(mission)
  -- general data
  filterData.groupTags['missionType_'..mission.missionTypeLabel] = true
  if not groupData['missionType_'..mission.missionTypeLabel] then
    groupData['missionType_'..mission.missionTypeLabel] = {label = mission.missionTypeLabel, elements = {}, icon = mission.iconFontIcon}
  end
  --filterData.sortingValues['depth'] = forwardInfo.depth
  --formatted.depth = forwardInfo.depth

  if career_career.isActive() and mission.careerSetup.skill then
    local skill = career_branches.getBranchById(mission.careerSetup.skill)
    if skill then
      filterData.groupTags['branch_'..skill.id] = true
    end
  end

  --filterData.sortingValues['maxBranchTier'] = forwardInfo.maxBranchLevel
  --filterData.groupTags['maxBranchTier_'..forwardInfo.maxBranchLevel] = true
  --groupData['maxBranchTier_'..forwardInfo.maxBranchLevel] = {label = 'Tier ' .. forwardInfo.maxBranchLevel, elements = {}}

  -- custom groups/tags
  if mission.grouping.id ~= "" then
    local gId = 'missionGroup_'..mission.grouping.id
    if not groupData[gId] then
      groupData[gId] = {elements = {}, icon = mission.iconFontIcon}
    end
    if mission.grouping.label ~= "" and groupData[gId].label == nil then
      groupData[gId].label = mission.grouping.label
    end
    filterData.groupTags[gId] = true
  end

  filterData.sortingValues['starCount'] = formatted.rating.totalStars
  filterData.sortingValues['defaultUnlockedStarCount'] = formatted.rating.defaultUnlockedStarCount
  filterData.sortingValues['totalUnlockedStarCount'] = formatted.rating.totalUnlockedStarCount

  return formatted, filterData
end

-- Helper function to process non-mission POI data
local function processNonMissionPoi(poi, groupData)
  local formatted = formatPoiForBigmap(poi)
  local filterData = {
    groupTags = {},
    sortingValues = {}
  }

  filterData.sortingValues['id'] = poi.id

  if poi.data.type == 'spawnPoint' then
    filterData.groupTags['type_spawnPoint'] = true
  elseif poi.data.type == 'garage' then
    filterData.groupTags['type_garage'] = true
  elseif poi.data.type == 'gasStation' then
    filterData.groupTags['type_gasStation'] = true
  elseif poi.data.type == 'dealership' then
    filterData.groupTags['type_dealership'] = true
  elseif poi.data.type == "logisticsParking" then
    filterData.groupTags['delivery_dropoff'] = true
  elseif poi.data.type == 'logisticsOffice' then
    filterData.groupTags['delivery_facility'] = true
  elseif poi.data.type == "driftSpot" then
    filterData.groupTags['type_driftSpots'] = true
  elseif poi.data.type == "dragstrip" then
    filterData.groupTags['type_dragstrip'] = true
  elseif poi.data.type == "crawl" then
    filterData.groupTags['type_crawl'] = true
  elseif poi.data.type == "playerVehicle" then
    filterData.groupTags['type_playerVehicle'] = true
  elseif poi.data.type == "computer" then
    filterData.groupTags['type_computer'] = true
    if poi.data.facility.functions and poi.data.facility.functions.apmLandingPage then
      filterData.groupTags['type_apm_computer'] = true
    end
  elseif poi.data.type == "tutorialLesson" then
    local sectionId = poi.data.tutorialSectionId or "tutorial"
    local groupKey = "tutorialSection_" .. tostring(sectionId)
    local sectionIndex = poi.data.tutorialSectionIndex or math.huge
    local isTimeTrialsSection = sectionId == "timeTrials"
    if not groupData[groupKey] then
      groupData[groupKey] = {
        label = poi.data.tutorialSectionLabel or "bigMap.group.tutorial",
        elements = {},
        tutorialSectionIndex = sectionIndex,
        tutorialIsTimeTrials = isTimeTrialsSection,
      }
    end
    groupData[groupKey].tutorialSectionIndex = sectionIndex
    groupData[groupKey].tutorialIsTimeTrials = isTimeTrialsSection
    filterData.groupTags[groupKey] = true
  else -- other
    filterData.groupTags['type_other'] = true
  end

  if poi.data.customGroupTags then
    for _, tag in ipairs(poi.data.customGroupTags) do
      filterData.groupTags[tag] = true
    end
  end

  return formatted, filterData
end

local function formattedMissionSortFunction(a, b)
  local aDepth = a.depth or 0
  local bDepth = b.depth or 0
  if aDepth == bDepth then
    return a.id < b.id
  else
    return aDepth < bDepth
  end
end

local function getTutorialGroupsSorted(groupsById)
  local tutorialGroups = {}
  for _, groupId in ipairs(tableKeysSorted(groupsById)) do
    local group = groupsById[groupId]
    if group and group.tutorialSectionIndex then
      table.insert(tutorialGroups, group)
    end
  end

  table.sort(tutorialGroups, function(a, b)
    local aIsTimeTrials = a.tutorialIsTimeTrials == true
    local bIsTimeTrials = b.tutorialIsTimeTrials == true
    if aIsTimeTrials ~= bIsTimeTrials then
      return not aIsTimeTrials
    end

    local aSectionIndex = a.tutorialSectionIndex or math.huge
    local bSectionIndex = b.tutorialSectionIndex or math.huge
    if aSectionIndex == bSectionIndex then
      return tostring(a.key) < tostring(b.key)
    end
    return aSectionIndex > bSectionIndex
  end)

  return tutorialGroups
end

local function getIncompleteTutorialGroupsSorted(groupsById, poisById)
  local tutorialGroups = getTutorialGroupsSorted(groupsById)
  local incompleteTutorialGroups = {}

  for _, group in ipairs(tutorialGroups) do
    local incompleteElements = {}
    for _, poiId in ipairs(group.elements or {}) do
      local poi = poisById[poiId]
      local isIncompleteLesson = false
      if gameplay_discover_freeroamTutorial_tutorialBigMapUtils
        and gameplay_discover_freeroamTutorial_tutorialBigMapUtils.isPoiIncompleteTutorialLessonForBigMapGroup then
        isIncompleteLesson = gameplay_discover_freeroamTutorial_tutorialBigMapUtils.isPoiIncompleteTutorialLessonForBigMapGroup({
          data = poi,
        })
      elseif poi and poi.type == "tutorialLesson" and poi.lessonId and poi.lessonId ~= "" then
        isIncompleteLesson = not gameplay_discover_freeroamTutorial_tutorial.isLessonCompleted(poi.lessonId)
      end

      if isIncompleteLesson then
        table.insert(incompleteElements, poiId)
      end
    end

    if #incompleteElements > 0 then
      table.insert(incompleteTutorialGroups, {
        key = group.key,
        label = group.label,
        icon = group.icon,
        elements = incompleteElements,
        tutorialSectionIndex = group.tutorialSectionIndex,
        tutorialIsTimeTrials = group.tutorialIsTimeTrials,
      })
    end
  end

  return incompleteTutorialGroups
end

local function getAllTutorialGroupsForEverything(groupsById)
  local tutorialGroups = getTutorialGroupsSorted(groupsById)
  local allTutorialGroups = {}
  for _, group in ipairs(tutorialGroups) do
    table.insert(allTutorialGroups, {
      key = tostring(group.key) .. "_everything",
      label = group.label,
      icon = group.icon,
      elements = group.elements,
      tutorialSectionIndex = group.tutorialSectionIndex,
      tutorialIsTimeTrials = group.tutorialIsTimeTrials,
    })
  end
  return allTutorialGroups
end

-- Helper function to build POI data cache
local function buildPoiDataCache(level)
  gameplay_rawPois.clear()
  local poiData = {}
  local groupData = buildGroupData()
  for _, poi in ipairs(gameplay_rawPois.getRawPoiListByLevel(level)) do
    if poi.data and poi.data.type == "tutorialLesson"
      and gameplay_discover_freeroamTutorial_tutorialBigMapUtils
      and gameplay_discover_freeroamTutorial_tutorialBigMapUtils.addBigmapMarkerDataToPoi then
      gameplay_discover_freeroamTutorial_tutorialBigMapUtils.addBigmapMarkerDataToPoi(poi)
    end

    if poi.markerInfo.bigmapMarker then
      local formatted, filterData

      if poi.data.type == 'mission' then
        formatted, filterData = processMissionPoi(poi, groupData)
      else
        formatted, filterData = processNonMissionPoi(poi, groupData)
      end

      formatted.spriteIcon = poi.markerInfo.bigmapMarker.icon

      poiData[poi.id] = formatted
      poiData[poi.id].filterData = filterData

      for tag, include in pairs(filterData.groupTags) do
        if include then
          if not groupData[tag] then
            log("W","","Unknown group tag: " .. dumps(tag) .. " for poi " .. dumps(poi.id))
            groupData[tag] = {label = tag, elements = {}}
          end
          table.insert(groupData[tag].elements, poi.id)
        end
      end
    end
  end

  -- Sort elements in each group
  for key, gr in pairs(groupData) do
    local elementsAsPois = {}
    for i, id in ipairs(gr.elements) do elementsAsPois[i] = poiData[id] end
    if gr.sortFunction then
      table.sort(elementsAsPois, gr.sortFunction)
    else
      table.sort(elementsAsPois, formattedMissionSortFunction)
    end
    for i, poi in ipairs(elementsAsPois) do gr.elements[i] = elementsAsPois[i].id end
    gr.key = key
  end


  return poiData, groupData
end

-- helper function to build group structure
local function buildGroupStructure(poisById, groupsById)
  local groupStructure = {}
  local tutorialGroups = getIncompleteTutorialGroupsSorted(groupsById, poisById)
  local allTutorialGroups = getAllTutorialGroupsForEverything(groupsById)
  if #tutorialGroups > 0 then
    table.insert(groupStructure, {
      key = 'tutorialLessonsBySection',
      icon = 'bookOpened',
      title = 'bigMap.section.tutorialLessons',
      groups = tutorialGroups,
    })
  end

  if not career_career.isActive() then
    table.insert(groupStructure, {
      key = 'everything',
      icon = 'infinity',
      title = 'bigMap.sideMenu.pois',
      groups = allTutorialGroups,
    })
    table.insert(groupStructure, {
      key = 'freeroamPois',
      icon = 'mapPoint',
      title = 'bigMap.section.otherPois',
      groups = {
        groupsById['type_spawnPoint'],
        groupsById['type_gasStation'],
        groupsById['type_driftSpots'],
        groupsById['type_dragstrip'],
        groupsById['type_crawl'],
        groupsById['type_other'],
      }
    })
    local missionGroups = {}
    local sortedGroupIds = tableKeysSorted(groupsById)
    for _, groupId in ipairs(sortedGroupIds) do
      if string.startswith(groupId, 'missionType_') then
        table.insert(missionGroups, groupsById[groupId])
      end
    end
    table.insert(groupStructure, {
      key = 'missionsByType',
      icon = 'flag',
      title = 'bigMap.section.challenges',
      groups = missionGroups,
    })
    local customGroupStructures = {}
    extensions.hook("onBigmapBuildCustomGroupStructures", customGroupStructures)
    for _, customGroupStructure in ipairs(customGroupStructures) do
      local customGroups = {
        key = customGroupStructure.key,
        icon = customGroupStructure.icon,
        title = customGroupStructure.title,
        groups = {},
      }
      for _, group in ipairs(customGroupStructure.groupIds) do
        table.insert(customGroups.groups, groupsById[group])
      end
      table.insert(groupStructure, customGroups)
    end
  else
    table.insert(groupStructure, {
      key = 'freeroamPois',
      icon = 'mapPoint',
      title = 'bigMap.sideMenu.pois',
      groups = {
        groupsById['type_playerVehicle'],
        groupsById['type_dealership'],
        groupsById['type_garage'],
        groupsById['type_gasStation'],
        groupsById['type_dragstrip'],
        groupsById['type_crawl'],
        groupsById['type_computer'],
        groupsById['type_other'],
      }
    })
    local branchOrdered = career_branches.orderBranchNamesKeysByBranchOrder()
    for _, domainId in ipairs(branchOrdered) do
      local domain = career_branches.getBranchById(domainId)
      if domain.isDomain then
        local hasContent = false
        local filter = {
          key = 'domain_'..domainId,
          icon = domain.icon,
          title = core_locales.translateWithOrWithoutContext(domain.name),
          groups = {}
        }
        if domain.id == "logistics" then
          table.insert(filter.groups, groupsById['delivery_dropoff'])
          table.insert(filter.groups, groupsById['delivery_facility'])
          hasContent = true
        end

        if domain.id == "apm" then
          poiDataCache["apmChallengeInfo"] = {
            id = "apmChallengeInfo",
            type = "apmChallengeInfo",
            name = "bigMap.apmChallenges.name",
            description = "bigMap.apmChallenges.description",
            thumbnailFile = domain.thumbnail,
            previewFiles = {domain.progressCover},
          }
          --[[able.insert(filter.groups, {
            label = "APM Challenges",
            key = "apmChallenges",
            elements = { "apmChallengeInfo" }
          })]]
          table.insert(filter.groups, groupsById['type_apm_computer'])
          hasContent = true
        end

        for _, branchId in ipairs(branchOrdered) do
          local branch = career_branches.getBranchById(branchId)
          if branch.parentDomain == domainId then
            if groupsById['branch_'..branchId] and next(groupsById['branch_'..branchId].elements) then
              table.insert(filter.groups, groupsById['branch_'..branchId])
              hasContent = true
            end
            if branch.id == "bmra-drift" then
              table.insert(filter.groups, groupsById['type_driftSpots'])
              hasContent = true
            end
            if branch.id == "bmra-crawl" then
              table.insert(filter.groups, groupsById['type_crawl'])
              hasContent = true
            end
          end
        end
        if hasContent then
          table.insert(groupStructure, filter)
        end
      end
    end
    if next(groupsById['delivery_dropoff'].elements) then
    table.insert(groupStructure, {
      key = 'delivery',
      icon = 'boxTruckFast',
      title = 'bigMap.section.deliveryTasks',
      groups = {
          groupsById['delivery_dropoff']
        }
      })
    end
  end
  local nonEmptyGroupStructure = {}
  for _, structure in ipairs(groupStructure) do
    local hasContent = structure.key == 'everything'
    for _, group in ipairs(structure.groups) do
      if next(group.elements) then
        hasContent = true
        break
      end
    end
    if hasContent then
      table.insert(nonEmptyGroupStructure, structure)
    end
  end

  return nonEmptyGroupStructure
end

local function buildFilters(groupStructure)
  local filters = {}
  for _, section in ipairs(groupStructure) do
    local filterSection = {
      key = section.key,
      icon = section.icon,
      title = section.title,
      groups = {}
    }
    for _, group in ipairs(section.groups) do
      if filterVisibilityState[group.key] == nil then
        filterVisibilityState[group.key] = true
      end
      local visible = filterVisibilityState[group.key]
      table.insert(filterSection.groups, {
        key = group.key,
        label = core_locales.translateWithOrWithoutContext(group.label),
        icon = group.icon,
        elementCount = #group.elements,
        visible = visible,
      })
    end
    table.insert(filters, filterSection)
  end
  return filters
end
-- Function to generate cache data
local function generateCacheData()
  log("I", "", "Generating cache data for bigmap...")
  local level = getCurrentLevelIdentifier()

  M.clearActionFunctions()

  -- Build POI data cache
  local poisById, groupsById = buildPoiDataCache(level)
  local groupStructure = buildGroupStructure(poisById, groupsById)
  local filters = buildFilters(groupStructure)

  poiDataCache = poisById
  groupStructureCache = groupStructure
  filterStructureCache = filters

  gameStateInfoCache = {
    rules = {
      canSetRoute = true
    }
  }
  for _, lvl in ipairs(core_levels.getList()) do
    if string.lower(lvl.levelName) == getCurrentLevelIdentifier() then
      gameStateInfoCache.levelData = deepcopy(lvl)
      gameStateInfoCache.levelData.titleMap = core_locales.contextTranslate('bigmap.titleMap', {level = _tr(lvl.title)})
    end
    systemYield()
  end
  gameStateInfoCache.gameMode = "freeroam"
  if career_career and career_career.isActive() then
    gameStateInfoCache.gameMode = "career"
    gameStateInfoCache.rules.canSetRoute = not career_modules_testDrive.isActive()
  end
  if gameplay_missions_missionManager.getForegroundMissionId() then
    gameStateInfoCache.gameMode = "mission"
  end


  cacheValid = true
end

-- Main functions
local function enterBigMap(options)
  options = options or {}
  -- Delegate to existing bigmap mode
  if freeroam_bigMapMode  then
    local ignoreActionMaps = options.controllerUsed and options.isMenuBigmap
    local ignoreUiStateChange = options.ignoreUiStateChange
    if ignoreUiStateChange == nil then
      ignoreUiStateChange = options.isMenuBigmap
    end
    freeroam_bigMapMode.enterBigMap({instant = true, ignoreUiStateChange = ignoreUiStateChange, ignoreActionMaps = ignoreActionMaps})
  end

  --guihooks.trigger('MenuOpenModule', {state = "bigmap", params = {instant = true}})
  -- Generate cache data
  generateCacheData()


  M.setVisibleIds()

end

local function exitBigMap()
  -- Delegate to existing bigmap mode
  if freeroam_bigMapMode then
    freeroam_bigMapMode.exitBigMap(true)
  end

  -- Clear caches
  invalidateCache()

  -- Clear action functions
  clearActionFunctions()
end

local function getPoiData()
  if not cacheValid then
    generateCacheData()
  end
  return poiDataCache
end

local function getFilters()
  if not cacheValid then
    generateCacheData()
  end
  for _, section in ipairs(filterStructureCache) do
    for _, group in ipairs(section.groups) do
      group.visible = filterVisibilityState[group.key]
    end
  end
  return filterStructureCache
end

local function getGroups()
  if not cacheValid then
    generateCacheData()
  end
  local validIds = nil

  local groups = {}
  for _, section in ipairs(groupStructureCache) do
    local validSection = false
    local groupSection = {
      key = section.key,
      icon = section.icon,
      title = section.title,
      groups = {}
    }
    for _, group in ipairs(section.groups) do
      local visible = filterVisibilityState[group.key]
      if visible and group.elements and #group.elements > 0 then
        local validPoiIds = {}
        for _, poiId in ipairs(group.elements) do
          if validIds == nil or validIds[poiId] then
            table.insert(validPoiIds, poiId)
          end
        end
        if #validPoiIds > 0 then
          table.insert(groupSection.groups, {
            key = group.key,
            label = core_locales.translateWithOrWithoutContext(group.label),
            icon = group.icon,
            elementIds = validPoiIds,
            visible = true,
            openByDefault = group.openByDefault,
          })
          validSection = true
        end
      end
    end
    if validSection then
      table.insert(groups, groupSection)
    end
  end

  return groups
end

local function getGameStateInfo()
  if not cacheValid then
    generateCacheData()
  end

   -- Get poiListDisplayMode from settings
  gameStateInfoCache.poiListDisplayMode = settings.getValue("poiListDisplayMode") or "tree"

  return gameStateInfoCache
end

local function setVisibleIds()
  local visibleIds = {}
  for _, groupSection in ipairs(groupStructureCache) do
    for _, group in ipairs(groupSection.groups) do
      if filterVisibilityState[group.key] then
        for _, poiId in ipairs(group.elements) do
          visibleIds[poiId] = true
        end
      end
    end
  end
  if freeroam_bigMapMode then
    freeroam_bigMapMode.setOnlyIdsVisible(tableKeys(visibleIds))
  end
end

local ignoreNextReductionFlag = false
local function selectPoiFromList(poiId, isCollapsedMode)
  if poiId == "undefined" or poiId == "null" then poiId = nil end
  if freeroam_bigMapMode then
    if poiId then
      -- Only set ignoreNextReductionFlag if not in collapsed mode
      if not isCollapsedMode then
        ignoreNextReductionFlag = true
      end
      freeroam_bigMapMode.selectPoi(poiId)
    else
      freeroam_bigMapMode.deselect()
    end
  end
  return "success"
end

local function navigateToPoi(poiId)
  if poiId == "undefined" or poiId == "null" then poiId = nil end
  if poiId and freeroam_bigMapMode then
    freeroam_bigMapMode.navigateToMission(poiId)
  end
  return "success"
end

local function panToPoi(poiId)
  if poiId == "undefined" or poiId == "null" then poiId = nil end
  if poiId and freeroam_bigMapMode then
    freeroam_bigMapMode.panToPoi(poiId)
  end
  return "success"
end

local function onPoiSelectedFromBigmap(poiId)
  if poiId and poiId ~= "undefined" and poiId ~= "null" then
    local poiIds = freeroam_bigMapMarkers.getIdsFromHoveredPoiId(poiId)
    if ignoreNextReductionFlag then
      poiIds = {poiId}
      ignoreNextReductionFlag = false
    end
    if not tableIsEmpty(poiIds) then
      guihooks.trigger("showPoiDetails", {poiIds = poiIds, ignoreReduction = ignoreNextReductionFlag})
    else
      guihooks.trigger("showPoiDetails", {})
    end
  else
    guihooks.trigger("showPoiDetails", {})
  end
end
M.onPoiSelectedFromBigmap = onPoiSelectedFromBigmap

local function hoverPoiFromList(poiId, active)
  if freeroam_bigMapMode then
    freeroam_bigMapMode.poiHovered(poiId, active)
  end
  return "success", active
end

local function executePoiAction(actionId)
  executeAction(actionId)
end

local function getAndClearPendingAutoSelectPoiId()
  if freeroam_bigMapMode and freeroam_bigMapMode.getAndClearPendingAutoSelectPoiId then
    return freeroam_bigMapMode.getAndClearPendingAutoSelectPoiId()
  end
end

local function setPoiListDisplayMode(mode)
  if mode == "hidden" or mode == "tree" or mode == "simple" then
    settings.setValue("poiListDisplayMode", mode)
    -- Update cache if it exists
    if gameStateInfoCache then
      gameStateInfoCache.poiListDisplayMode = mode
    end
    return "success"
  end
  return "invalid_mode"
end

-- Return module functions
M.enterBigMap = enterBigMap
M.exitBigMap = exitBigMap
M.getPoiData = getPoiData
M.getFilters = getFilters
M.getGroups = getGroups
M.toggleFiltersByIds = toggleFiltersByIds
M.toggleFilterSectionById = toggleFilterSectionById
M.getGameStateInfo = getGameStateInfo
M.selectPoiFromList = selectPoiFromList
M.getAndClearPendingAutoSelectPoiId = getAndClearPendingAutoSelectPoiId
M.navigateToPoi = navigateToPoi
M.panToPoi = panToPoi
M.hoverPoiFromList = hoverPoiFromList
M.executePoiAction = executePoiAction
M.setPoiListDisplayMode = setPoiListDisplayMode
M.setVisibleIds = setVisibleIds

-- Action management functions
M.getFreeActionId = getFreeActionId
M.clearActionFunctions = clearActionFunctions
M.addAction = addAction
M.executeAction = executeAction
return M