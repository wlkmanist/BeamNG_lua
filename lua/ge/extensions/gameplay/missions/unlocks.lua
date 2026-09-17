-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local conditionTypes = {}
local _overrideStartable = {}
local _overrideVisible = {}

local _unlockStatusCache = {}
local _backwardCache = {}
local _forwardCache = nil

-- This function recursively processes a condition, generating label, if the condition is met etc.
local function conditionMet(condition)
  local conditionType = conditionTypes[condition.type]
  if not conditionType then
    conditionType = conditionTypes['missing']
  end

  local met, nested = conditionType.conditionMet(condition)
  local label = conditionType.getLabel(condition)
  return {met = met, condition = condition, nested = nested, label = label, hidden = conditionType.hidden}
end


-----------------------------------------------------------------
----------------------- Comparing Unlocks -----------------------
-----------------------------------------------------------------

--  this function generates a flat/simple list of all unlock data for all missions, used for comparisons.
local function getSimpleUnlockedStatus()
  local cache = {}
  for _, mission in ipairs(gameplay_missions_missions.getAllMissions()) do
    cache[mission.id] = deepcopy(M.constructUnlocksField(mission))
  end
  return cache
end

-- compares two unlock data, to see what changed between them
local keysToCheck = {'startable','visible'}
local function compareUnlock(a,b)
  local ret = {}
  for _, key in ipairs(keysToCheck) do
    if a[key] ~= b[key] then
      table.insert(ret, {
        key = key,
        old = a[key],
        new = b[key]
      })
    end
  end
  return ret
end

-- compares two simpleUnlockedStatus lists to see what changed between them
local function getUnlockDiff(before, after)
  local diff = {list = {}, byId = {}, missionsList={}}
  for _, mission in ipairs(gameplay_missions_missions.getAllMissions()) do
    local id = mission.id
    local comp = compareUnlock(before[id], after[id])
    if next(comp) then
      table.insert(diff.list,{
        missionId = id,
        change = comp
      })
      diff.byId[id] = comp
      -- check if a mission is now startable
      if after[id].startable and (not before[id].startable) then
        table.insert(diff.missionsList, {
          name = mission.name,
          id = id
        })
      end
    end
  end
  return diff
end

-- for a specific mission, gets all missions that are directly unlocked by it.
local function getMissionBasedUnlockDiff(mission, diff)
  local fwd = {list = {}}
  local forwardIds = M.getForwardMissionInfo(mission).forwardIds
  for _, id in ipairs(forwardIds) do
    local otherMission = gameplay_missions_missions.getMissionById(id)
    local startable = M.isMissionStartable(otherMission)
    table.insert(fwd.list, {missionId = id, changed = diff.byId[id] ~= nil, startable = startable})
  end
  return fwd
end

--------------------------------------------------------------------
----------------------- Ordering and Tagging -----------------------
--------------------------------------------------------------------

-- recursively collects all missions referenced in conditions (missionPassed, missionCompleted)
local function getMissionsForCondition(cond, list)
  if cond.nested then
    for _, n in ipairs(cond.nested) do
      getMissionsForCondition(n, list)
    end
  else
    if cond.type == 'missionPassed' or cond.type == 'missionCompleted' then
      table.insert(list, cond.missionId)
    end
  end
end
M.getMissionsForCondition = getMissionsForCondition

-- recursively gets all branch level requirements in conditions (branchLevel)
local function getBranchLevelForCondition(cond, list)
  if cond.nested then
    for _, n in ipairs(cond.nested) do
      M.getBranchLevelForCondition(n, list)
    end
  else
    if cond.type == "branchLevel" then
      list[cond.branchId] = cond.level
    end
    if cond.type == "league" and career_modules_branches_leagues then
      local league = career_modules_branches_leagues.getLeagueById(cond.leagueId)
      if league then
        if league.branchId then
          list[league.branchId] = 1
        else
          log("W", "gameplay_missions_unlocks", "League " .. cond.leagueId .. " has no branchId")
          dump(cond)
          dumpz(league, 2)
        end
      end
    end
  end
end
M.getBranchLevelForCondition = getBranchLevelForCondition

-- for one specific mission, sets the branchTags and level data for all missions following it (missionPassed etc).
local function propagateBranchLevel(startId)
  local front, nxt, open = {}, {}, {}
  local startLevel = _forwardCache[startId].maxBranchLevel
  local startTypes = _forwardCache[startId].branchTags
  table.insert(front, startId)
  local c = 0
  while c < 10000 and next(front) do
    nxt = {}
    for _, mId in ipairs(front) do
      _forwardCache[mId].maxBranchLevel = math.max(_forwardCache[mId].maxBranchLevel, startLevel)
      for _, nId in ipairs(_forwardCache[mId].forwardIds) do
        nxt[nId] = true
      end
      for key, _ in pairs(startTypes) do
        _forwardCache[mId].branchTags[key] = true
      end
    end
    front = tableKeysSorted(nxt)
    c = c+1
  end
end

-- builds the forward cache (this needs all missions to be loaded)
local function buildForwardCache()
  -- get all missions, initialize the forward cache
  local missions = gameplay_missions_missions.getAllMissions()
  _forwardCache = {}
  for _, m in ipairs(missions) do
    _forwardCache[m.id] = {}
  end

  -- get the base data for all missions: associated missions, branch levels.
  local highestLevelForMission = {}
  local branchTagForMission = {}
  for _, m in ipairs(missions) do
    local levelForBranch = {}
    getBranchLevelForCondition(m.startCondition, levelForBranch)
    highestLevelForMission[m.id] = nil
    branchTagForMission[m.id] = nil
    for bId, lvl in pairs(levelForBranch) do
      branchTagForMission[m.id] = branchTagForMission[m.id] or {}
      branchTagForMission[m.id][bId] = true
      if not highestLevelForMission[m.id] then
        highestLevelForMission[m.id] = lvl
      else
        highestLevelForMission[m.id] = math.max(highestLevelForMission[m.id], lvl)
      end
    end

    local c = _forwardCache[m.id]
    c.forwardIds = {}
    c.maxBranchLevel = highestLevelForMission[m.id] or 0
    c.branchTags = branchTagForMission[m.id] or {}
  end

  -- double-link the missions, so that missions know which ones come after that (conditions are looking "backward")
  for _, bMission in ipairs(missions) do
    local bId = bMission.id
    local backwardIds = M.getBackwardMissionIds(bMission)
    for _, fId in ipairs(backwardIds) do
      if _forwardCache[fId] then
        table.insert(_forwardCache[fId].forwardIds, bId)
      end
    end
  end

  -- print backward and forward ids for all missions
  local printDebug = false
  if printDebug then
    for _, m in ipairs(missions) do
      local backwardIds = M.getBackwardMissionIds(m)
      local forwardIds = _forwardCache[m.id].forwardIds
      if #backwardIds > 0 then
        log("I","",m.id .. " Backwards: " .. dumps(backwardIds))
      end
      if #forwardIds > 0 then
        log("I","",m.id .. " Forwards: " .. dumps(forwardIds))
      end
    end
  end

  -- propagate the max lvl of a mission forward, so each mission knows the minimum branch level needed through predecessors
  local missionIdsWithBranchCondition = tableKeysSorted(highestLevelForMission)
  for _, mId in ipairs(missionIdsWithBranchCondition) do
    propagateBranchLevel(mId)
  end

  --propagate missions go get initial "depth"
  local front, nxt, open = {}, {}, {}
  local depth = 0
  for _, m in ipairs(missions) do
    _forwardCache[m.id].depth = -1
    local backwardIds = M.getBackwardMissionIds(m)
    if #backwardIds == 0 then
      table.insert(front, m.id)
    end
  end
  while depth < 1000 and next(front) do
    nxt = {}
    for _, mId in ipairs(front) do
      _forwardCache[mId].depth = math.max(_forwardCache[mId].depth, depth)
      for _, nId in ipairs(_forwardCache[mId].forwardIds) do
        nxt[nId] = true
      end
    end
    front = tableKeysSorted(nxt)
    depth = depth+1
  end

  -- get max depth for each level. then sum up to get depth offset
  local maxDepthPerBranchLevel = {}
  local maxLevel = 0
  for _, m in ipairs(missions) do
    local c = _forwardCache[m.id]
    maxDepthPerBranchLevel[c.maxBranchLevel] = math.max(c.depth, maxDepthPerBranchLevel[c.maxBranchLevel] or 0)
    maxLevel = math.max(maxLevel, c.maxBranchLevel)
  end
  local prev = 0
  for i = 0, maxLevel do
    maxDepthPerBranchLevel[i] = prev + maxDepthPerBranchLevel[i]
    prev = maxDepthPerBranchLevel[i]
  end

  -- shift the depth of a mission based on the amount of branches, branch depth, branch level
  for _, m in ipairs(missions) do
    local c = _forwardCache[m.id]
    c.depth = c.depth + maxDepthPerBranchLevel[c.maxBranchLevel] + (c.maxBranchLevel)*1
  end
end

local function computeStartableDetails(mission)
  local careerActive = career_career and career_career.isActive()
  if mission.careerSetup.showInCareer and mission.careerSetup.showInFreeroam and not careerActive then
    return nil
  else
    return conditionMet(mission.startCondition or deepcopy(conditionTypes['always']))
  end
end

local function getStartableDetails(mission)
  local c = _unlockStatusCache[mission.id]
  if not c then
    c = {}
    c.startableDetails = computeStartableDetails(mission)
    _unlockStatusCache[mission.id] = c
  end
  return c.startableDetails
end

local function isMissionStartableRaw(mission)
  -- compute startable (without any overrides)
  local startableDetails = getStartableDetails(mission)
  if startableDetails == nil then
    return true
  end
  return startableDetails.met
end

local function isMissionStartable(mission)
  -- returns true if the mission is startable, false otherwise
  local override = _overrideStartable[mission.id]
  if override ~= nil then
    return override
  end
  return isMissionStartableRaw(mission)
end

local function isAnyBackwardMissionStartable(mission)
  local backwardIds = M.getBackwardMissionIds(mission)
  if #backwardIds == 0 then
    return true
  end
  for _, bId in ipairs(backwardIds) do
    local back = gameplay_missions_missions.getMissionById(bId)
    if back then
      local startable = isMissionStartableRaw(back)
      if startable then
        return true
      end
    end
  end
  return false
end

local function computeVisible(mission)
  local careerActive = career_career and career_career.isActive()
  local isPotentiallyVisible = true
  if careerActive then
    isPotentiallyVisible = mission.careerSetup.showInCareer
  else
    isPotentiallyVisible = mission.careerSetup.showInFreeroam
  end
  local visible = false
  if isPotentiallyVisible then
    if mission.visibleCondition.type == 'automatic' then
      if mission.careerSetup.showInCareer and mission.careerSetup.showInFreeroam and not careerActive then
        visible = true
      else
        visible = isAnyBackwardMissionStartable(mission)
      end
    else
      local visibleInfo = conditionMet(mission.visibleCondition or deepcopy(conditionTypes['always']))
      visible = visibleInfo.met
    end
  end
  return visible
end

local function isMissionVisible(mission)
  -- returns true if the mission is visible, false otherwise
  local override = _overrideVisible[mission.id]
  if override ~= nil then
    return override
  end
  local c = _unlockStatusCache[mission.id]
  if not c then
    getStartableDetails(mission) -- fills _unlockStatusCache[mission.id]
    c = _unlockStatusCache[mission.id]
  end
  if c.visible == nil then
    c.visible = computeVisible(mission)
  end
  return c.visible
end

local function getBackwardMissionIds(mission)
  -- returns a list of mission IDs that are required to unlock the given mission
  local backwardIds = _backwardCache[mission.id]
  if not backwardIds then
    backwardIds = {}
    getMissionsForCondition(mission.startCondition, backwardIds)
    _backwardCache[mission.id] = backwardIds
  end
  return backwardIds
end

local function getForwardMissionInfo(mission)
  -- returns a table with the following keys:
  -- forwardIds: list of mission IDs that are unlocked by the given mission
  -- maxBranchLevel: the maximum branch level of the given mission (among itself and all forward missions)
  -- branchTags: a list of branch tags that are set for the given mission
  -- depth: the depth of the given mission (int), i.e. the number of mission levels in forward direction of the tree

  -- to compute forward information, we need to load all missions to be able to traverse the whole mission tree
  if not _forwardCache or not _forwardCache[mission.id] then
    if _forwardCache then
      log("W", "gameplay_missions_unlocks", "Forward cache missing mission " .. tostring(mission.id) .. ", rebuilding.")
    end
    buildForwardCache()
  end
  return _forwardCache[mission.id]
end

local function overrideStartable(mission, value)
  _overrideStartable[mission.id] = value
end

local function overrideVisible(mission, value)
  _overrideVisible[mission.id] = value
end

local function constructUnlocksField(mission)
  local u = {}
  local startable = isMissionStartable(mission)
  local visible = isMissionVisible(mission)
  local backwardIds = getBackwardMissionIds(mission)
  local forwardInfo = getForwardMissionInfo(mission)
  local startableDetails = getStartableDetails(mission)
  u.startable = startable
  u.visible = visible
  u.startableDetails = startableDetails
  u.backward = backwardIds
  u.forward = forwardInfo.forwardIds
  u.maxBranchLevel = forwardInfo.maxBranchLevel
  u.branchTags = forwardInfo.branchTags
  u.depth = forwardInfo.depth
  return u
end

-- Unlocks API
M.isMissionStartable = isMissionStartable
M.getStartableDetails = getStartableDetails
M.isMissionVisible = isMissionVisible
M.getBackwardMissionIds = getBackwardMissionIds
M.getForwardMissionInfo = getForwardMissionInfo
M.overrideStartable = overrideStartable
M.overrideVisible = overrideVisible
M.constructUnlocksField = constructUnlocksField

M.startConditionMet = startConditionMet

M.conditionMet = conditionMet
M.getSimpleUnlockedStatus = getSimpleUnlockedStatus
M.getUnlockDiff = getUnlockDiff
M.getMissionBasedUnlockDiff = getMissionBasedUnlockDiff

-- load all condition types.
local function onExtensionLoaded()
  local files = FS:findFiles('/lua/ge/extensions/gameplay/missions/unlocks/conditions','*.lua',-1)
  local count = 0
  for _, file in ipairs(files) do
    local aConds = require(file:sub(0,-5))

    for key, value in pairs(aConds) do
      count = count+1
      conditionTypes[key] = value
    end
  end
  log("D","","Loaded " .. count .. " condition types from " .. #files .. " files.")
end
M.onExtensionLoaded = onExtensionLoaded

M.depthIdSort = function(a,b)
  local aDepth = getForwardMissionInfo(a).depth
  local bDepth = getForwardMissionInfo(b).depth
  if aDepth == bDepth then
    return a.id < b.id
  else
    return aDepth < bDepth
  end
end
M.depthIdSortUsingIds = function(aId,bId)
  local a, b = gameplay_missions_missions.getMissionById(aId), gameplay_missions_missions.getMissionById(bId)
  if not a or not b then return false end
  local aDepth = getForwardMissionInfo(a).depth
  local bDepth = getForwardMissionInfo(b).depth
  if aDepth == bDepth then
    return a.id < b.id
  else
    return aDepth < bDepth
  end
end

M.clearUnlockStatusCache = function()
  if career_modules_branches_leagues then
    career_modules_branches_leagues.clearLeagueUnlockCache()
  end
  _unlockStatusCache = {}
end

M.clearCache = function()
  M.clearUnlockStatusCache()
  _backwardCache = {}
  _forwardCache = nil
end

return M
