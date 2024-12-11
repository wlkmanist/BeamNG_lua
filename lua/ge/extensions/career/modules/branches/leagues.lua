-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local leaguesById = nil
M.getLeagueById = function(id) return leaguesById[id] end


-- career utility
local missionsBySkill = {}
local starsBySkillCache = {}
M.clearLeagueUnlockCache = function()
  for _, league in pairs(leaguesById) do league._unlocked = nil end
  starsBySkillCache = {}
end
M.getSimpleUnlockedStatus = function()
  M.clearLeagueUnlockCache()
  local ret = {}
  for id, _ in pairs(leaguesById) do
    ret[id] = M.isLeagueUnlocked(id)
  end
  return ret
end

local function isLeagueUnlocked(id)
  local league = M.getLeagueById(id)
  if not league then return false end
  if league._unlocked ~= nil then return league._unlocked end
  -- no condition = unlocked by default
  if not league.unlock or not next(league.unlock) then
    league._unlocked = true
    return true
  end

  local allConditionsMet = true
  for _, condition in ipairs(league.unlock) do
    if condition.type == "leagueStars" then
      local count = 0
      local otherLeague = M.getLeagueById(condition.leagueId)
      for _, mId in ipairs(otherLeague.missions) do
        local all, def, bon = gameplay_missions_progress.getUnlockedStarCountsForMissionById(mId)
        -- todo: decide if all or only default stars count
        count = count + all
      end

      for i, dsId in ipairs(otherLeague.driftSpots or {}) do
        local spot = gameplay_drift_saveLoad.getDriftSpotById(dsId)
        local defaultCount = 0
        for _, obj in ipairs(spot.info.objectives) do
          defaultCount = defaultCount + (spot.saveData.objectivesCompleted[obj.id] and 1 or 0)
        end
        count = count + defaultCount
      end

      condition.met = (count >= condition.stars)
      condition.progress = {
        min = 0,
        max = condition.stars,
        cur = count,
        label = string.format("%d Stars / %d Stars", count, condition.stars)

      }
      condition.label = string.format("Get %d stars from '%s'", condition.stars, translateLanguage(otherLeague.name, otherLeague.name, true))

    elseif condition.type == "branchLevel" then
      local level = career_branches.getBranchLevel(condition.skillId)
      local neededForLevel = career_branches.getXPNeededForLevel(condition.skillId, condition.level)
      local xp = career_branches.getBranchXP(condition.skillId)
      condition.met = level >= condition.level
      condition.progress = {
        min = 0,
        max = neededForLevel,
        cur = xp,
        label = string.format("%d XP / %d XP", xp, neededForLevel)
      }
      local branch = career_branches.getBranchById(condition.skillId)
      condition.label = string.format("Reach level %d of '%s'", condition.level,  translateLanguage(branch.name, branch.name, true))
    elseif condition.type == "skillStars" then
      if not starsBySkillCache[condition.skillId] then
        starsBySkillCache[condition.skillId] = {}
        starsBySkillCache[condition.skillId].total, starsBySkillCache[condition.skillId].unlocked = M.getStarsForSkill(condition.skillId)
      end
      condition.met = starsBySkillCache[condition.skillId].unlocked >= condition.stars
      condition.progress = {
        min = 0, max = condition.stars, cur = starsBySkillCache[condition.skillId].unlocked, label = string.format("%d / %d", starsBySkillCache[condition.skillId].unlocked, condition.stars)
      }
      local branch = career_branches.getBranchById(condition.skillId)
      condition.label = string.format("Get %d stars in '%s'", condition.stars,  translateLanguage(branch.name, branch.name, true))
    end
    allConditionsMet = allConditionsMet and condition.met
  end
  league._unlocked = allConditionsMet
  return allConditionsMet
end
M.isLeagueUnlocked = isLeagueUnlocked


local function formatLeague(l)
  isLeagueUnlocked(l.id)
  local league = deepcopy(l)
  league.totalStarsAvailable, league.totalStarsObtained = 0, 0
  for _, mId in ipairs(league.missions) do
    local mission = gameplay_missions_missions.getMissionById(mId)
    if mission then
      league.totalStarsAvailable = league.totalStarsAvailable + mission.careerSetup._activeStarCache.defaultStarCount
      local all, def, bon = gameplay_missions_progress.getUnlockedStarCountsForMissionById(mId)
      league.totalStarsObtained = league.totalStarsObtained + def
    end
  end

  for i, dsId in ipairs(league.driftSpots or {}) do
    local spot = gameplay_drift_saveLoad.getDriftSpotById(dsId)
    league.totalStarsAvailable = league.totalStarsAvailable + #spot.info.objectives
    local defaults = {}
    local defaultCount = 0
    for _, obj in ipairs(spot.info.objectives) do
      table.insert(defaults, spot.saveData.objectivesCompleted[obj.id] or false)
      defaultCount = defaultCount + (spot.saveData.objectivesCompleted[obj.id] and 1 or 0)
    end
    league.totalStarsObtained = league.totalStarsObtained + defaultCount
  end

  local skill = career_branches.getBranchById(league.skillId)
  if skill then
    league.icon = skill.icon
  end
  --league.milestones = career_modules_milestones_milestones.getMilestones({"branch_apexRacing"}).list
  return league
end

local function getLeaguesForProgressBranchPage(branchId)
  M.clearLeagueUnlockCache()
  local ret = {}
  for id, l in pairs(leaguesById) do
    local league = formatLeague(l)
    local skill = career_branches.getBranchById(league.skillId)
    if not branchId or branchId == skill.id or skill.parentBranch == branchId then
      table.insert(ret, league)
    end
  end
  table.sort(ret, function(a,b) return a._order < b._order end)
  return ret
end
M.getLeaguesForProgressBranchPage = getLeaguesForProgressBranchPage

local function getLeaguesForUnlockChange(before, after)
  local ret = {}
  for id, l in pairs(leaguesById) do
    if not before[id] and after[id] then
      local league = formatLeague(l)
      table.insert(ret, league)
    end
  end
  table.sort(ret, function(a,b) return a._order < b._order end)
  return ret
end
M.getLeaguesForUnlockChange = getLeaguesForUnlockChange

local noLeague = {
  id = "noLeague",
  name = "Other Missions",
  description = "",
  missions = {},
  driftSpots = {},
  _unlocked = true,
}
local function getNoLeague(skill, missions, driftSpots)
  local league = deepcopy(noLeague)
  local branch = career_branches.getBranchById(skill.id)
  league.name = string.format("%s Challenges", translateLanguage(branch.name, branch.name, true))
  league.skillId = skill.id
  for _, m in ipairs(missions or {}) do
    table.insert(league.missions, m.id)
  end
  for _, ds in ipairs(driftSpots or {}) do
    table.insert(league.driftSpots, ds.id)
  end
  return formatLeague(league)
end
M.getNoLeague = getNoLeague

local function getLeaguesForMission(missionId)
  M.clearLeagueUnlockCache()
  local ret = {}
  for id, l in pairs(leaguesById) do
    if tableContains(l.missions, missionId) then
      local league = formatLeague(l)
      table.insert(ret, league)
    end
  end
  table.sort(ret, function(a,b) return a._order < b._order end)
  return ret
end
M.getLeaguesForMission = getLeaguesForMission

-- save/load



local function loadLeagues()
  -- todo: load from file
  if not leaguesById then
    leaguesById = {}
    local files = FS:findFiles("/gameplay/", "*.leagues.json", -1, true, false)
    table.sort(files)
    local i = 1
    for _, file in ipairs(files) do
      local data = jsonReadFile(file)
      if data then
        for _, league in ipairs(data) do
          -- todo sanitize
          if leaguesById[league.id] then
            log("E","","League already exists: " .. league.id .. " (from file " .. dumps(file)..") Ignored.")
          else
            league._skillStars = 0
            league._orderByFile = i
            i = i+1
            for _, prog in ipairs(league.unlock or {}) do
              if prog.type == "skillStars" then
                league._skillStars = prog.stars
              end
            end
            league.missions = league.missions or {}
            league.driftSpots = league.driftSpots or {}

            local skill = career_branches.getBranchById(league.skillId)
            if skill then
              league.branchId = skill.parentBranch
            end

            leaguesById[league.id] = league
          end
        end
      end
    end

    local leagueIds = tableKeys(leaguesById)

    local function sortLeagues(a, b)
      local leagueA, leagueB = leaguesById[a], leaguesById[b]
      if leagueA.skillId ~= leagueB.skillId then
        return career_branches.getOrder(leagueA.skillId) < career_branches.getOrder(leagueB.skillId)
      end
      if leagueA._skillStars ~= leagueB._skillStars then
        return leagueA._skillStars < leagueB._skillStars
      end
      return leagueA._orderByFile < leagueB._orderByFile
    end
    table.sort(leagueIds, sortLeagues)
    for i, key in ipairs(leagueIds) do
      leaguesById[key]._order = i
    end
  end

end

local function onCareerModulesActivated()
  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()

  -- load leagues
  loadLeagues()
end
M.onCareerModulesActivated = onCareerModulesActivated

local function getStarsForSkill(skillId)
  local total, unlocked = 0, 0
  
  for _, m in ipairs(gameplay_missions_missions.get()) do
    if m.careerSetup and m.careerSetup.skill == skillId then
      total = total + m.careerSetup._activeStarCache.defaultStarCount
      local _, def, _ = gameplay_missions_progress.getUnlockedStarCountsForMissionById(m.id)
      unlocked = unlocked + def
    end
  end
  --[[
  if skillId == "drift" then
    for _, ds in pairs(gameplay_drift_saveLoad.getDriftSpotsById()) do
      for _, obj in ipairs(ds.info.objectives) do
        unlocked = unlocked + (ds.saveData.objectivesCompleted[obj.id] and 1 or 0)
        total = total + 1
      end
    end
  end
  ]]
  return total, unlocked
end
M.getStarsForSkill = getStarsForSkill

local function startConditionIncludesLeague(cond, leagueId)
  if cond.type == "league" and (cond.leagueId == leagueId or not leagueId) then
    return true
  else
    for _, n in ipairs(cond.nested or {}) do
      if M.startConditionIncludesLeague(n, leagueId) then
        return true
      end
    end
  end
end
M.startConditionIncludesLeague = startConditionIncludesLeague

local function getStartConditionLeagueId(cond, map)
  if cond.type == "league" then
    map[cond.leagueId] = true
  else
    for _, n in ipairs(cond.nested or {}) do
      M.getStartConditionLeagueId(n, map)
    end
  end
end
M.getStartConditionLeagueId = getStartConditionLeagueId

local function onMissionsLoadedFromFiles(missionsById)
  loadLeagues()
  missionsBySkill = {}
  local missionIdsBySkill = {}
  local dirty = 0

  for id, league in pairs(leaguesById) do
    local validMissionIds = {}
    for _, mId in ipairs(league.missions) do
      local m = gameplay_missions_missions.getMissionById(mId)
      if not m then
        log("E","","Mission does not exist: " .. dumps(mId) .. " in league " .. dumps(id)..". Removed from league.")
      end

      if m and m.careerSetup.showInCareer then
        table.insert(validMissionIds, mId)
        if not M.startConditionIncludesLeague(m.startCondition, id) then
          m.startCondition = {type = "league", leagueId = id}
          m._dirty = true
          dirty = dirty + 1
        end
      end
    end
    leaguesById[id].missions = validMissionIds
  end
  for mId, m in pairs(missionsById) do
    local lMap = {}
    M.getStartConditionLeagueId(m.startCondition, lMap)
    if table.getn(lMap) > 1 then
      log("W","","Mission has more than one league in starting condition... " .. mId)
    end
    local lId = next(lMap)
    if lId then
      local league = M.getLeagueById(lId)
      if not league then
        log("E","","League doesnt exist! " .. lId .. " in " .. mId)
      else
        if m.careerSetup.skill ~= league.skill then
          m._dirty = true
          dirty = dirty + 1
        end
        m.careerSetup.skill = league.skillId

        missionIdsBySkill[m.careerSetup.skill] = missionIdsBySkill[m.careerSetup.skill] or {}
        missionsBySkill[m.careerSetup.skill] = missionsBySkill[m.careerSetup.skill] or {}
        if not missionIdsBySkill[m.careerSetup.skill][mId] then
          table.insert(missionsBySkill[m.careerSetup.skill], m)
        end
        missionIdsBySkill[m.careerSetup.skill][mId] = true
      end
    end
  end

  if dirty > 0  then
    log("W","","Some ("..tostring(dirty)..") missions were not set up properly for leagues.")
  end
end
M.onMissionsLoadedFromFiles = onMissionsLoadedFromFiles

--[[
M.onAfterDriftSpotsLoaded = function(spotsById)
  loadLeagues()
  for _, spot in pairs(spotsById) do
    spot._isInLeague = nil
    spot.unlocked = true
  end
  for id, league in pairs(leaguesById) do
    for _, dsId in ipairs(league.driftSpots) do
      local spot = spotsById[dsId]
      if not spot then
        log("E","","Drift spot " .. dumps(dsId) .. " listed in league " .. dumps(id).. " does not exist.")
      else
        if spot._isInLeague then
          log("E","","Drift spot " .. dumps(dsId) .. " is listed in more than one league! " .. dumps(spot._isInLeague) ..  " and " .. dumps(id))
        end
        spot._isInLeague = id
        spot.unlocked = M.isLeagueUnlocked(id)
      end
    end
  end
end
]]
return M