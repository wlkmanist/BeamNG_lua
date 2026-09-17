local M = {}

local logTag = 'trafficExclusion'
local defaultRadius = 10

local function loadRacePath(mission)
  if not mission or not mission.missionFolder then return nil end
  local racePathFile = mission.missionFolder .. "/race.race.json"

  if not FS:fileExists(racePathFile) then
    log('D', logTag, "Race path file not found: " .. tostring(racePathFile))
    return nil
  end

  local path = require('/lua/ge/extensions/gameplay/race/path')("Temp Path")
  local content = jsonReadFile(racePathFile)
  if content then
    path:onDeserialized(content)
    return path
  else
    log('E', logTag, "Failed to read/parse race path: " .. tostring(racePathFile))
  end
  return nil
end

-- local function createZonesForRallyStage(mission)
--   local zones = {}
--   local path = loadRacePath(mission)
--   if not path then return zones end

--   -- Get all start positions
--   if path.startPositions and path.startPositions.objects then
--     for _, sp in pairs(path.startPositions.objects) do
--       if sp.pos then
--         table.insert(zones, {pos = vec3(sp.pos), radius = defaultRadius})
--       end
--     end
--   end

--   -- Get all pathnodes
--   if path.pathnodes and path.pathnodes.objects then
--     for _, pn in pairs(path.pathnodes.objects) do
--       if pn.pos then
--         table.insert(zones, {pos = vec3(pn.pos), radius = defaultRadius})
--       end
--     end
--   end

--   return zones
-- end

local function createZonesForRallyStage2(mission, radius)
  local zones = {}
  if not mission or not mission.missionFolder then return zones end

  radius = radius or defaultRadius
  local sampleDistance = (1.5 * radius) -- controls overlap of sampled points

  local DrivelineV3 = require('/lua/ge/extensions/gameplay/rally/driveline/drivelineV3')
  local driveline = DrivelineV3(mission.missionFolder)

  if not driveline:loadDrivelineFromFile() then
    log('D', logTag, "Failed to load driveline for mission: " .. tostring(mission.missionFolder))
    return zones
  end

  local pointList = driveline:getFinalPointList()
  if not pointList then return zones end

  local points = pointList:getAll()
  local lastPos = nil

  for _, point in ipairs(points) do
    local pos = vec3(point.pos)
    if not lastPos or pos:distance(lastPos) >= sampleDistance then
      table.insert(zones, {pos = pos, radius = radius})
      lastPos = pos
    end
  end

  return zones
end

-- local function createZonesForRallyRoadSection(mission)
--   local zones = {}
--   local path = loadRacePath(mission)
--   if not path then return zones end

--   -- Get all start positions
--   if path.startPositions and path.startPositions.objects then
--     for _, sp in pairs(path.startPositions.objects) do
--       if sp.pos then
--         table.insert(zones, {pos = vec3(sp.pos), radius = defaultRadius})
--       end
--     end
--   end

--   return zones
-- end

local function createZones(missions, radius)
  missions = missions or {}
  local zones = {}

  -- If missions aren't provided, try to get the current active one from the editor
  if not next(missions) and editor_rallyEditor then
    local missionId = editor_rallyEditor.getMissionId()
    if missionId then
      local mission = gameplay_missions_missions.getMissionById(missionId)
      if mission then
        table.insert(missions, mission)
      else
        log('E', logTag, "Mission not found: " .. tostring(missionId))
      end
    end
  end

  if not next(missions) then
    log('W', logTag, "No missions available for traffic exclusion")
    return {}
  end

  for _, mission in ipairs(missions) do
    if mission.missionType == "rallyStage" then
      -- local zones1 = createZonesForRallyStage(mission)
      local zones1 = createZonesForRallyStage2(mission, radius)
      for _, z in ipairs(zones1) do table.insert(zones, z) end
    -- elseif mission.missionType == "rallyRoadSection" then
      -- local zones1 = createZonesForRallyRoadSection(mission)
      -- for _, z in ipairs(zones1) do table.insert(zones, z) end
    else
      log('W', logTag, "Unsupported mission type for traffic exclusion: " .. tostring(mission.missionType))
    end
  end

  log('I', logTag, string.format("Created %d traffic exclusion zones for %d missions", #zones, #missions))
  return zones
end

local stageNumbers = {1, 2, 3, 4}

local function extractMissionId(value)
  -- Extract mission ID from "Mission Name (mission-id)" format
  if not value or value == "<none>" then
    return nil
  end
  local missionId = value:match("%((.+)%)$")
  return missionId
end

local function extractMissionIdsFromRallyLoop(mission)
  if not mission or not mission.fgVariables then
    log('W', logTag, "No fgVariables found for mission")
    return {}
  end

  local fgVariables = mission.fgVariables
  local missionIds = {}

  -- Add stages in order
  for _, stageNum in ipairs(stageNumbers) do
    local roadSection = extractMissionId(fgVariables["stage"..stageNum.."_rallyRoadSection"])
    local stage = extractMissionId(fgVariables["stage"..stageNum.."_rallyStage"])

    if roadSection then
      table.insert(missionIds, roadSection)
    end
    if stage then
      table.insert(missionIds, stage)
    end
  end

  -- Add return road section
  local returnRoadSection = extractMissionId(fgVariables.return_rallyRoadSection)
  if returnRoadSection then
    table.insert(missionIds, returnRoadSection)
  end

  log('I', logTag, string.format("Extracted %d mission IDs from rallyLoop", #missionIds))
  return missionIds
end

-- local function applyForMissionIds(missionIds, radius, sampleDistance)
--   if not missionIds or #missionIds == 0 then
--     log('W', logTag, "No mission IDs provided for traffic exclusion")
--     return 0
--   end

--   -- Build list of mission objects
--   local missions = {}
--   for _, missionId in ipairs(missionIds) do
--     local mission = gameplay_missions_missions.getMissionById(missionId)
--     if mission then
--       table.insert(missions, mission)
--     else
--       log('W', logTag, 'Mission not found: ' .. tostring(missionId))
--     end
--   end

--   -- Create zones for all missions
--   local zones = createZones(missions, radius, sampleDistance)

--   -- Apply zones to map
--   map.setTrafficExclusionZones(zones)
--   map.reset() -- Reload navgraph with zones applied

--   log('I', logTag, string.format('Applied %d traffic exclusion zones for %d missions', #zones, #missions))
--   return #zones
-- end

local function applyForRallyLoop(loopMission, radius)
  if not loopMission then
    log('W', logTag, 'applyForRallyLoop: no loop mission provided')
    return {}
  end

  local missionIds = extractMissionIdsFromRallyLoop(loopMission)
  local missions = {}
  for _, missionId in ipairs(missionIds) do
    local mission = gameplay_missions_missions.getMissionById(missionId)
    if mission then
      table.insert(missions, mission)
    else
      log('W', logTag, 'applyForRallyLoop: stage mission not found: ' .. tostring(missionId))
    end
  end

  local zones = createZones(missions, radius)

  if loopMission.missionFolder then
    local grzonesFile = loopMission.missionFolder .. '/trafficGatedRoads.grzones.json'
    log('I', logTag, 'applyForRallyLoop: checking for grzones: ' .. tostring(grzonesFile))
    if FS:fileExists(grzonesFile) then
      local grzones = jsonReadFile(grzonesFile)
      if grzones and grzones.spheres then
        log('I', logTag, 'applyForRallyLoop: adding ' .. #grzones.spheres .. ' grzones spheres')
        for _, s in ipairs(grzones.spheres) do
          if s.pos and s.radius then
            table.insert(zones, {pos = vec3(s.pos[1], s.pos[2], s.pos[3]), radius = s.radius})
          else
            log('W', logTag, 'applyForRallyLoop: skipping sphere missing pos/radius, id=' .. tostring(s.id))
          end
        end
      else
        log('W', logTag, 'applyForRallyLoop: grzones file has no spheres array')
      end
    else
      log('D', logTag, 'applyForRallyLoop: no grzones file found (optional)')
    end
  end

  map.setTrafficExclusionZones(zones)
  map.reset()
  log('I', logTag, string.format('applyForRallyLoop: applied %d total zones', #zones))
  return zones
end

local function clearTrafficExclusion()
  map.clearTrafficExclusionZones()
  map.reset() -- Reload navgraph with zones cleared
  log('I', logTag, 'Cleared traffic exclusion zones')
end

M.createZones = createZones
M.extractMissionIdsFromRallyLoop = extractMissionIdsFromRallyLoop
M.applyForRallyLoop = applyForRallyLoop
M.clearTrafficExclusion = clearTrafficExclusion
M.getDefaultRadius = function() return defaultRadius end

return M
