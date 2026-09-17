-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local im = ui_imgui
local ffi = require('ffi')

local logTag = "mission_port_tool"

local function convertBoundsToBoundary(boundsData, missionName)
  if not boundsData or not boundsData.zones or #boundsData.zones == 0 then
    log('W', logTag, "No zones found in bounds data for mission: " .. (missionName or "unknown"))
    return nil
  end

  local zone = boundsData.zones[1]
  if not zone or not zone.vertices or #zone.vertices < 3 then
    log('W', logTag,"Invalid zone data for mission: " .. (missionName or "unknown"))
    return nil
  end

  local boundary = require('/lua/ge/extensions/gameplay/sites/zone')(nil, missionName .. "_boundary")

  for i, vertexPos in ipairs(zone.vertices) do
    local pos = vec3(vertexPos[1], vertexPos[2], vertexPos[3])
    boundary:addVertex(pos)
  end

  if zone.top then
    boundary.top = {
      active = zone.top.active or false,
      pos = vec3(zone.top.pos[1], zone.top.pos[2], zone.top.pos[3]),
      normal = vec3(zone.top.normal[1], zone.top.normal[2], zone.top.normal[3])
    }
  else
    boundary.top = {
      active = false,
      pos = vec3(0, 0, 10),
      normal = vec3(0, 0, 1)
    }
  end

  if zone.bot then
    boundary.bot = {
      active = zone.bot.active or false,
      pos = vec3(zone.bot.pos[1], zone.bot.pos[2], zone.bot.pos[3]),
      normal = vec3(zone.bot.normal[1], zone.bot.normal[2], zone.bot.normal[3])
    }
  else
    boundary.bot = {
      active = false,
      pos = vec3(0, 0, -10),
      normal = vec3(0, 0, -1)
    }
  end

  boundary:processVertices()

  return boundary
end

local function convertRaceToPath(raceData, missionName)
  if not raceData or not raceData.pathnodes or #raceData.pathnodes == 0 then
    log('W', logTag,"No pathnodes found in race data for mission: " .. (missionName or "unknown"))
    return nil
  end

  local path = {
    name = missionName .. "_path",
    description = "Converted from race.race.json",
    nodes = {}
  }

  -- Build a map of startPosition oldIds to check which are recovery checkpoints
  -- The defaultStartPosition entry is the actual starting position, others referenced by recovery are checkpoints
  local recoveryStartPositionOldIds = {}
  if raceData.startPositions then
    for i, pathnode in ipairs(raceData.pathnodes) do
      if pathnode.recovery and pathnode.recovery ~= -1 then
        -- recovery points to oldId in startPositions array, not pathnode index
        recoveryStartPositionOldIds[pathnode.recovery] = true
      end
      if pathnode.reverseRecovery and pathnode.reverseRecovery ~= -1 then
        recoveryStartPositionOldIds[pathnode.reverseRecovery] = true
      end
    end
  end

  -- Convert pathnodes and mark recovery checkpoints
  -- A pathnode is a recovery checkpoint if it has a recovery field pointing to a startPosition
  for i, pathnode in ipairs(raceData.pathnodes) do
    local node = {
      name = pathnode.name or ("Node " .. i),
      pos = vec3(pathnode.pos[1], pathnode.pos[2], pathnode.pos[3]),
      radius = pathnode.radius or 6.0,
      flags = {}
    }

    if pathnode.normal then
      node.flags.normal = {pathnode.normal[1], pathnode.normal[2], pathnode.normal[3]}
    end
    if pathnode.recovery and pathnode.recovery ~= -1 then
      node.flags.recovery = pathnode.recovery
    end
    if pathnode.reverseRecovery and pathnode.reverseRecovery ~= -1 then
      node.flags.reverseRecovery = pathnode.reverseRecovery
    end
    if pathnode.sidePadding then
      node.flags.sidePadding = {pathnode.sidePadding[1], pathnode.sidePadding[2]}
    end

    -- Mark as recovery checkpoint if this pathnode has a recovery field
    -- (meaning it can trigger recovery to a startPosition)
    if (pathnode.recovery and pathnode.recovery ~= -1) or (pathnode.reverseRecovery and pathnode.reverseRecovery ~= -1) then
      node.flags.isRecoveryCheckpoint = true
      log('D', logTag, string.format("Marked pathnode %d (%s) as recovery checkpoint", i, node.name))
    end

    table.insert(path.nodes, node)
  end

  return path
end

local function extractMissionName(missionDir)
  local folderName = string.match(missionDir, "([^/]+)/?$")

  return folderName or "unknown_mission"
end

local function portMission(missionDir, targetLevel)
  if not missionDir or not FS:directoryExists(missionDir) then
    log('E', logTag,"Mission directory does not exist: " .. tostring(missionDir))
    return false
  end
  local missionName = extractMissionName(missionDir)
  local boundsFile = missionDir .. "/bounds.sites.json"
  local raceFile = missionDir .. "/race.race.json"
  local infoFile = missionDir .. "/info.json"

  if not FS:fileExists(boundsFile) then
    log('E', logTag,"bounds.sites.json not found in: " .. missionDir)
    return false
  end

  if not FS:fileExists(raceFile) then
    log('E', logTag,"race.race.json not found in: " .. missionDir)
    return false
  end

  if not FS:fileExists(infoFile) then
    log('W', logTag,"info.json not found in: " .. missionDir .. " (start position will not be available)")
  end

  local boundsData = jsonReadFile(boundsFile)
  local raceData = jsonReadFile(raceFile)

  if not boundsData then
    log('E', logTag,"Failed to load bounds.sites.json from: " .. boundsFile)
    return false
  end

  if not raceData then
    log('E', logTag,"Failed to load race.race.json from: " .. raceFile)
    return false
  end

  local boundary = convertBoundsToBoundary(boundsData, missionName)
  local path = convertRaceToPath(raceData, missionName)

  if not boundary then
    log('E', logTag,"Failed to convert boundary for mission: " .. missionName)
    return false
  end

  if not path then
    log('E', logTag,"Failed to convert path for mission: " .. missionName)
    return false
  end

  local levelToUse = targetLevel or getCurrentLevelIdentifier()
  if not levelToUse then
    log('E', logTag,"No level specified and no level currently loaded")
    return false
  end

  local levelCrawlDir = "/levels/" .. levelToUse .. "/crawls/"
  local missionDir = missionDir .. "/"

  local boundaryFile = levelCrawlDir .. missionName .. ".boundary.json"
  local pathFile = levelCrawlDir .. missionName .. ".path.json"

  local gameplay_crawl_saveSystem = require('/lua/ge/extensions/gameplay/crawl/saveSystem')

  local boundarySuccess = gameplay_crawl_saveSystem.saveBoundary(boundary, boundaryFile)
  local pathSuccess = gameplay_crawl_saveSystem.savePath(path, pathFile)

  if not boundarySuccess then
    log('E', logTag,"Failed to save boundary to: " .. boundaryFile)
    return false
  end

  if not pathSuccess then
    log('E', logTag,"Failed to save path to: " .. pathFile)
    return false
  end

  -- Convert starting position from race file
  local startingPositionId = nil
  if raceData.startPositions and #raceData.startPositions > 0 then
    -- defaultStartPosition is an oldId, not an index - find the matching startPosition entry
    local startPosData = nil
    local defaultStartOldId = raceData.defaultStartPosition

    if defaultStartOldId and defaultStartOldId ~= -1 then
      -- Find startPosition with matching oldId
      for _, sp in ipairs(raceData.startPositions) do
        if sp.oldId == defaultStartOldId then
          startPosData = sp
          break
        end
      end
    end

    -- Fallback to first entry if not found
    if not startPosData and #raceData.startPositions > 0 then
      log('W', logTag, string.format("Could not find startPosition with oldId %d, using first entry", defaultStartOldId or -1))
      startPosData = raceData.startPositions[1]
    end

    if startPosData and startPosData.pos then
      local startPos = vec3(startPosData.pos[1], startPosData.pos[2], startPosData.pos[3])

      -- Calculate rotation pointing to first checkpoint
      local rotation = quat(0, 0, 0, 1) -- Default identity rotation
      if path and path.nodes and #path.nodes > 0 then
        local firstCheckpoint = path.nodes[1]
        if firstCheckpoint and firstCheckpoint.pos then
          local direction = firstCheckpoint.pos - startPos
          -- Only set rotation if direction is valid (not zero length)
          if direction:length() > 0.001 then
            rotation = quatFromDir(direction, vec3(0, 0, 1))
            log('D', logTag, string.format("Calculated start rotation pointing to first checkpoint (distance: %.2f)", direction:length()))
          else
            log('W', logTag, "Start position and first checkpoint are too close, using default rotation")
          end
        end
      else
        log('W', logTag, "No path nodes available, using default rotation")
      end

      local startingPosition = {
        name = startPosData.name or (missionName .. "_start"),
        description = "Converted from race.race.json starting position",
        transform = {
          position = startPos,
          rotation = rotation,
          radius = 10.0
        },
        iconPosition = vec3(startPosData.pos[1], startPosData.pos[2], startPosData.pos[3] + 2),
        metadata = {
          created = os.date(),
          modified = os.date()
        }
      }

      local startingPositionFile = levelCrawlDir .. missionName .. ".startingPosition.json"
      local startingPositionSuccess = gameplay_crawl_saveSystem.saveStartingPosition(startingPosition, startingPositionFile)

      if startingPositionSuccess then
        startingPositionId = startingPositionFile
        log('D', logTag, "Starting position saved to: " .. startingPositionFile)
      else
        log('W', logTag, "Failed to save starting position, trail will be created without it")
      end
    else
      log('W', logTag, "Invalid starting position data in race file")
    end
  else
    log('W', logTag, "No starting positions found in race file")
  end

  local trail = {
    name = missionName,
    description = "Converted from mission: " .. missionName,
    pathId = pathFile,
    boundaryId = boundaryFile,
    startingPositionId = startingPositionId or "",
    pathReversed = false,
    thumbnail = "",
    preview = "",
    rules = {
      isPointsBased = false,
      isTimed = false
    },
    prefabs = {},
    metadata = {
      created = os.date(),
      modified = os.date()
    },
    isFromMission = true
  }

  local trailFile = missionDir .. missionName .. ".trail.json"
  local trailSuccess = gameplay_crawl_saveSystem.saveTrail(trail, trailFile)

  if not trailSuccess then
    log('E', logTag,"Failed to save trail to: " .. trailFile)
    return false
  end

  log('I', logTag, string.format("Successfully ported mission %s (starting position: %s)", missionName, startingPositionId and "yes" or "no"))
  return true
end

local showDialog = im.BoolPtr(false)
local missionsList = {}
local portedMissions = {}

local function scanMissions()
  missionsList = {}
  portedMissions = {}

  local currentLevel = getCurrentLevelIdentifier()
  if not currentLevel then
    log('W', logTag, "No level currently loaded")
    return
  end

  local missionsPath = "/gameplay/missions/" .. currentLevel .. "/crawl/"

  if not FS:directoryExists(missionsPath) then
    log('W', logTag, "Missions directory does not exist: " .. missionsPath)
    return
  end

  -- Find all mission directories
  local missionDirs = FS:findFiles(missionsPath, "*", 0, false, true)

  for _, missionDir in ipairs(missionDirs) do
    local stat = FS:stat(missionDir)
    if stat.filetype == "dir" then
      local missionName = string.match(missionDir, "([^/]+)/?$")
      if missionName then
        local boundsFile = missionDir .. "/bounds.sites.json"
        local raceFile = missionDir .. "/race.race.json"

        if FS:fileExists(boundsFile) and FS:fileExists(raceFile) then
          table.insert(missionsList, {
            name = missionName,
            path = missionDir,
            boundsFile = boundsFile,
            raceFile = raceFile
          })

          local trailFile = missionDir .. "/" .. missionName .. ".trail.json"
          if FS:fileExists(trailFile) then
            portedMissions[missionName] = true
          end
        end
      end
    end
  end

end

local function portAllMissions()
  local allLevels = getAllLevelIdentifiers()
  local totalConverted = 0
  local totalFailed = 0

  for _, levelName in ipairs(allLevels) do
    local missionsPath = "/gameplay/missions/" .. levelName .. "/crawl/"

    if FS:directoryExists(missionsPath) then
      local missionDirs = FS:findFiles(missionsPath, "*", 0, false, true)

      for _, missionDir in ipairs(missionDirs) do
        local stat = FS:stat(missionDir)
        if stat.filetype == "dir" then
          local missionName = string.match(missionDir, "([^/]+)/?$")
          if missionName then
            local boundsFile = missionDir .. "/bounds.sites.json"
            local raceFile = missionDir .. "/race.race.json"

            if FS:fileExists(boundsFile) and FS:fileExists(raceFile) then
              -- Port all missions without checking if already ported
              local success = portMission(missionDir, levelName)
              if success then
                totalConverted = totalConverted + 1
              else
                totalFailed = totalFailed + 1
              end
            end
          end
        end
      end
    end
  end

  log('I', logTag, "Port All Complete: " .. totalConverted .. " converted, " .. totalFailed .. " failed")

  editor_crawlEditor.loadAllObjects()

  scanMissions()
end

local function showPortingDialog()
  if showDialog[0] then
    if im.Begin("Mission Port Tool", showDialog) then
      im.Text("Convert Old Crawl Mission to New Crawl System")
      im.Separator()

      if im.Button("Port All Missions") then
        portAllMissions()
      end

      im.Separator()

      local currentLevel = getCurrentLevelIdentifier()
      if not currentLevel then
        im.TextColored(im.ImVec4(1, 0.5, 0, 1), "No level currently loaded!")
        im.Separator()
        if im.Button("Close") then
          showDialog[0] = false
        end
        im.End()
        return
      end

      im.Text("Current Level: " .. currentLevel)
      im.Text("Scanning: /gameplay/missions/" .. currentLevel .. "/crawl/")

      im.SameLine()
      if im.Button("Refresh") then
        scanMissions()
      end

      im.Separator()

      if #missionsList == 0 then
        im.TextWrapped("No convertible missions found in the current level's crawl directory.")
        im.TextWrapped("Missions must contain both bounds.sites.json and race.race.json files.")
      else
        im.Text("Found " .. #missionsList .. " convertible missions:")
        im.Separator()

        for i, mission in ipairs(missionsList) do
          im.PushID1(tostring(i))

          local buttonText = mission.name

          if im.Button(buttonText) then
            local success = portMission(mission.path)
            if success then
              log('I', logTag, "Mission port completed successfully!")
              portedMissions[mission.name] = true
              editor_crawlEditor.loadAllObjects()
            else
              log('E', logTag, "Mission port failed!")
            end
          end

          if portedMissions[mission.name] then
            im.SameLine()
            im.TextColored(im.ImVec4(0, 1, 0, 1), "Successfully ported")
          end

          im.PopID()
        end
      end

      im.Separator()
      im.TextWrapped("This tool will convert:")
      im.BulletText("bounds.sites.json → boundary file")
      im.BulletText("race.race.json → path file (with recovery checkpoints)")
      im.BulletText("race.race.json startPositions → starting position file")
      im.BulletText("Create a trail linking all components")

      im.Separator()

      if im.Button("Close") then
        showDialog[0] = false
      end

    end
    im.End()
  end
end

local function openPortingDialog()
  scanMissions()
  showDialog[0] = true
end

M.portMission = portMission
M.showPortingDialog = showPortingDialog
M.openPortingDialog = openPortingDialog

return M
