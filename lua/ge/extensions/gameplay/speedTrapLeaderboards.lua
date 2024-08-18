-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = ""

local leaderboards = {}
local freeroamSaveFolder = 'settings/cloud/speedTrapLeaderboards/'
local leaderboardSize = 10
local dirtyLevels = {}

local function isStateFreeroam()
  if career_career and career_career.isActive() then return false end
  if core_gamestate.state and (core_gamestate.state.state == "freeroam") then
    return true
  end
  return false
end

local function loadLeaderboards(folderPath)
  folderPath = folderPath or freeroamSaveFolder
  log("I", logTag, "Loading leaderboards from " .. folderPath)
  table.clear(leaderboards)
  local files = FS:findFiles(folderPath, '*.json', 0, false, false)
  for _, filePath in pairs(files) do
    local leaderboardFileData = jsonReadFile(filePath)
    if leaderboardFileData then
      local _, levelName = path.splitWithoutExt(filePath)
      leaderboards[levelName] = leaderboardFileData
    end
  end
end

local function saveLeaderboards(folderPath, forceOverwrite)
  folderPath = folderPath or freeroamSaveFolder
  log("I", logTag, "Saving leaderboards to " .. folderPath)
  for levelName, levelLeaderboards in pairs(leaderboards) do
    if dirtyLevels[levelName] or forceOverwrite then
      local fileName = folderPath .. levelName .. ".json"
      log("D", logTag, "Saving leaderboard to " .. fileName)
      jsonWriteFile(fileName, levelLeaderboards)
      dirtyLevels[levelName] = nil
    end
  end
end

local function createEntry(playerSpeed, overSpeed, veh)
  local modelName = ""
  local jbeamName = veh:getField('JBeam','0')
  if jbeamName then
    modelName = jbeamName
  end

  return {speed = playerSpeed, modelName = modelName, date = os.date("!%Y-%m-%dT%XZ")}
end

local function addRecord(speedTrapData, playerSpeed, overSpeed, veh)
  local currentLevel = getCurrentLevelIdentifier()
  if not leaderboards[currentLevel] then
    leaderboards[currentLevel] = {}
  end
  if not leaderboards[currentLevel][speedTrapData.triggerName] then
    leaderboards[currentLevel][speedTrapData.triggerName] = {}
  end
  local speedTrapLeaderboard = leaderboards[currentLevel][speedTrapData.triggerName]

  -- if there is enough room still, add the current record
  if tableSizeC(speedTrapLeaderboard) < leaderboardSize then
    table.insert(speedTrapLeaderboard, createEntry(playerSpeed, overSpeed, veh))
    table.sort(speedTrapLeaderboard, function(a, b) return a.speed > b.speed end)
    dirtyLevels[currentLevel] = true

  -- if the list is already full, check if the current record is faster than the slowest one
  elseif playerSpeed > speedTrapLeaderboard[leaderboardSize].speed then
    speedTrapLeaderboard[leaderboardSize] = createEntry(playerSpeed, overSpeed, veh)
    table.sort(speedTrapLeaderboard, function(a, b) return a.speed > b.speed end)
    dirtyLevels[currentLevel] = true
  end

  if playerSpeed >= speedTrapLeaderboard[1].speed then
    return true, speedTrapLeaderboard
  end
  return false, speedTrapLeaderboard
end

-- TODO need some "onFreeroamStart" function
local function onClientPostStartMission(levelPath)
  if isStateFreeroam() then
    loadLeaderboards()
  end
end

local function onClientEndMission()
  if isStateFreeroam() then
    saveLeaderboards()
  end
end

local function onBeforeCareerActivate()
  if isStateFreeroam() then
    saveLeaderboards()
  end
end

local function getLeaderboards()
  return leaderboards
end

local function onSerialize()
  if not career_career.isActive() then
    return {leaderboards = leaderboards, dirtyLevels = dirtyLevels}
  end
end

local function onDeserialized(data)
  leaderboards = data.leaderboards
  dirtyLevels = data.dirtyLevels
end

M.onClientPostStartMission = onClientPostStartMission
M.onClientEndMission = onClientEndMission
M.onBeforeCareerActivate = onBeforeCareerActivate
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

M.saveLeaderboards = saveLeaderboards
M.getLeaderboards = getLeaderboards
M.loadLeaderboards = loadLeaderboards
M.addRecord = addRecord

return M