-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--  Quickrace loader V 0.1
--  Supplies code-created scenario info for the quickrace selection screen.
--  The created scenarios contain the available tracks.
--  This code also loads the scenario, creating the vehicle, needed prefabs
--  and race checkpoints, and also sets the scenario data so that the scenario_race.lua
--  can be used to handle the race logic.

local logTag = 'quickraceLoader'

local M = {}
M.quickRaceModules  = {'scenario_scenarios', 'statistics_statistics', 'scenario_waypoints', 'scenario_quickRace','core_hotlapping'}

local function getLevelList()
  if not FS:directoryExists('levels/') then
    return {}
  end
  local files = FS:findFiles('/levels/', 'info.json', 1, true, false)
  -- filter paths to only return filename without extension
  for k,v in pairs(files) do
    files[k] = string.gsub(files[k], "(.*/)(.*)/(.*)", "%2")
  end
  return files
end

local function mimicProcTracks ()
  local res = {}
  local supportedList = jsonReadFile('/levels/driver_training/scenarios/quickRaceProcedural/tracks.json')
  local scenData = jsonReadFile('/levels/driver_training/scenarios/career_prototype_gymkhana.json')[1]

  for i=1, 10, 1 do
    local help = deepcopy(scenData)

    help.name = supportedList[i].name
    help.previews = supportedList[i].previews

    table.insert(res, help)
  end

  return res
end


-- this function returns a list containing all levels that contain quickraces.
-- each level has a 'tracks'-property, which contains a list of all quickrace tracks for this level.
local function getQuickraceList()
  local files = M.getLevelList()

  local proceduralLevel = {}
  local levels = {}
  local addingProcedural = true

  local trackBuilderTracks =  M.getTrackEditorTracks()
 --dump(files)
  for _, levelName in ipairs(files) do
    --print(levelName)
    local levelPath = '/levels/' .. levelName .. '/quickrace/'
    local quickraceFiles =  FS:findFiles(levelPath, '*.json', -1, true, false)
      local newLevel = {}
    if #quickraceFiles > 0 or trackBuilderTracks[levelName] ~= nil  then -- only add the level if it has quickraces inside!

      newLevel.radiusMultiplierAI = 2
      newLevel.levelObjects = {
        tod   = { time = 0.9, dayLength = 120, play = false }
        --sunsky  = { colorize = "0.427451 0.572549 0.737255 1" }
      }
      newLevel.prefabs = {}

      newLevel.playersCountRange = { min = 1, max = 1 }
      newLevel.uilayout = 'quickraceScenario'
      newLevel.levelName = levelName
      newLevel.levelInfo =  jsonReadFile('/levels/'..levelName..'/info.json') -- this contains the level info for the UI!

      newLevel.official = isOfficialContentVPath('levels/'..levelName..'/info.json')
      if not newLevel.levelInfo then
        log('W', 'quickrace', 'could not load info-file for level ' .. levelName)
      else
        newLevel.name = newLevel.levelInfo.title
      end

      if newLevel.levelName == "driver_training" then
        newLevel.levelInfo.title = 'Procedural Tracks'
        newLevel.name = newLevel.levelInfo.title
        newLevel.uilayout = 'proceduralScenario'
      end

      if newLevel.levelName == "smallgrid" then
        newLevel.levelInfo.title = "Track Editor Tracks"
        newLevel.name = newLevel.levelInfo.title
      end

      newLevel.scenarioName = newLevel.name

      newLevel.previews = M.customPreviewLoader(newLevel, levelName)
      if levelName == "smallgrid" then
        newLevel.previews = {"/ui/images/trackEdit.png"}
      end
      newLevel.mission = path.getPathLevelMain(levelName)

      --if newLevel.levelName == "smallgrid" then
      --  newLevel.tracks = M.getTrackEditorTracks(quickraceFiles, levelName)
      --  if newLevel.tracks and #(newLevel.tracks) > 0 then
      --    newLevel.previews = newLevel.tracks[1].previews
      --  end
      --else
        newLevel.tracks = M.getTracks(quickraceFiles, levelName, newLevel.levelName)
      --end
      local tbt = trackBuilderTracks[levelName] or trackBuilderTracks[levelName:lower()]
      if tbt ~= nil then

        for _,t in ipairs(tbt) do
          newLevel.tracks[#newLevel.tracks+1] = t
        end
      end

      newLevel.trackCount = #newLevel.tracks

      newLevel.vehicles = {
        scenario_player0 = {
          driver = { player = true, startFocus = true, required = true }
        }
      }
      newLevel.vehicles['*'] = {}

      if #newLevel.tracks > 0 then
        if newLevel.previews and #newLevel.previews > 0 then
          newLevel.preview = newLevel.previews[1]
          newLevel.preImgIndex = 0
        end

        newLevel.maxPlayers = 0

        if newLevel.playersCountRange and newLevel.playersCountRange.max then
          newLevel.maxPlayers = newLevel.playersCountRange.max
        else
          for _,v in pairs(newLevel.vehicles) do
            if (v.playerUsable == true or v.playerUsable == '1') or (v.driver and v.driver.player == true) then
              newLevel.maxPlayers = newLevel.maxPlayers + 1
            end
          end
        end

        if newLevel.playersCountRange and newLevel.playersCountRange.min then
          newLevel.minPlayers = newLevel.playersCountRange.min
        else
          newLevel.minPlayers = newLevel.maxPlayers;
        end

        table.insert(levels, newLevel)
      end
    --  if addingProcedural then
   --     addingProcedural = false
    --  end
     end
    end
  return levels
end

local function getLevel(levelName)
  local raceList = getQuickraceList()
  if raceList then
    for _,raceLevel in ipairs(raceList) do
      if raceLevel.levelInfo.title == levelName or raceLevel.name == levelName then
        return raceLevel
      end
    end
  end

  return nil
end

local function getLevelTrack(levelName, trackName)
  local level = getLevel(levelName)
  if level and level.tracks and level.trackCount > 0 then
    for _,track in ipairs(level.tracks) do
      if track.name == trackName then
        return track
      end
    end
  end

  return nil
end

-- loads the previews for the levels. This code is copied and slightly modified from the scenario_scenarios.lua ...
local function  customPreviewLoader( levelInfo, levelName)
  -- figure out the previews automatically and check for errors

  levelInfo.directory = '/levels/'..levelName
  levelInfo.previews = {}

  if type(levelInfo.levelInfo.previews) == 'table' and #levelInfo.levelInfo.previews > 0 then
    -- add prefix
    local newPreviews = {}
    for _, img in pairs(levelInfo.levelInfo.previews) do
      table.insert(newPreviews, levelInfo.directory..'/' .. img)
    end
    levelInfo.previews = newPreviews
  else
    local tmp = FS:findFiles("/levels/"..levelName.."/",levelName..'_preview*.png', 0, true, false)
    for _, p in pairs(tmp) do
      table.insert(levelInfo.previews, p)
    end
    tmp = FS:findFiles("/levels/"..levelName.."/",levelName..'_preview*.jpg', 0, true, false)
    for _, p in pairs(tmp) do
      table.insert(levelInfo.previews, p)
    end
  end
  if #levelInfo.previews == 0 then
    log('W', 'scenarios', 'scenario has no previews: ' .. tostring(levelInfo.scenarioName))
  end
  return levelInfo.previews
end


--reloads the list of all available tracks, sends those to the app
local function getCustomTracks()
  local tracks = {}
  -- local previews = {}
  -- for i, file in ipairs(FS:findFiles('trackEditor/','*.json',-1,true,false)) do
  --   local _, fn, e = path.split(file)
  --   local name = fn:sub(1,#fn - #e - 1)
  --   local read = jsonReadFile(name)
  -- end

  return tracks
end

-- this function gets all the track builder tracks, and creates a quickrace track for each of them, returning them as a list.
local function getTrackEditorTracks()
  local tracks = {}

  --get names of all the track builder tracks
  local editorTracks = {}
  for i, file in ipairs(FS:findFiles('trackEditor/','*.json',-1,true,false)) do
      local _, fn, e = path.split(file)
      editorTracks[i] = fn:sub(1,#fn - #e - 1)
  end
  for _, name in ipairs(editorTracks) do
    local trackData = M.loadTrackBuilderJSON(name)

    if trackData then
      if trackData.version == nil then
        log('I',logTag,"The file 'trackEditor/"..name..".json' uses an old format that is no longer supported.")
      else

        local file = {
          name = name,
          authors = trackData.author or "",
          difficulty = trackData.difficulty or 37, -- 37 = medium
          date = trackData.date or 1521828000,
          lapCount = 1,
          reversible = trackData.reversible or false,
          closed = trackData.connected or false,
          allowRollingStart= false,
          length = trackData.length or nil,
          lapConfig = {},
          description = trackData.description and string.gsub(trackData.description or "", "\\n", "\n") or nil,
          customData = {
            name = name
          },
          ignoreAsMission = true,
        }

        if trackData.connected then
          file.lapCount = trackData.defaultLaps or 2
        end
        file.sourceFile = "quickraceLoader.getTrackEditorTracks()"
        file.trackName = "TrackEditorTrack_"..name
        file.directory = "generatedFile"

        file.official = false
        file.prefabs = {}
        file.reversePrefabs = {}
        file.forwardPrefabs = {}

        file.luaFile = "/lua/ge/extensions/util/trackBuilder/quickraceSetup"

        if FS:fileExists('trackEditor/'..name..'.jpg') then
          file.previews = {'/trackEditor/'..name..'.jpg'}
        elseif FS:fileExists('trackEditor/'..name..'.png') then
          file.previews = {'/trackEditor/'..name..'.png'}
        elseif trackData.level == 'glow_city' then
          file.previews = {"/ui/images/trackEditGlow.png"}
        else
          file.previews = {"/ui/images/trackEdit.png"}
        end
        file.preview = file.previews[1]

        file.spawnSpheres = {}


        file.spawnSpheres.standing = "_standing_spawn"
        file.spawnSpheres.standingReverse = "_standingReverse_spawn"
        file.spawnSpheres.rolling = "_rolling_spawn"
        file.spawnSpheres.rollingReverse = "_rollingReverse_spawn"

        file.tod = file.tod or 3


        file.introType = 'none'

        file.isTrackEditorTrack = true
        local level = trackData.level or 'smallgrid'
        if tracks[level] == nil then tracks[level] = {} end
        tracks[level][#tracks[level]+1] = file
        --print("added " .. name .." to level " .. level)
      end
    end
  end

  return tracks

end

-- This function loads the JSON of a track builder track.
local function loadTrackBuilderJSON(originalFilename)
  local filename = 'trackEditor/'..originalFilename..'.json'

  if FS:fileExists(filename) then
    local read = jsonReadFile(filename)
    if not read then
        log('I',logTag,'No track found in file Documents/BeamNG/'..filename)
        return nil
    end
    return read

  else
      log('I',logTag,'Could not find file Documents/BeamNG/'..filename)
      return nil
  end
end


-- this function parses the quickrace files, and returns a list of all tracks for one level.
local function getTracks(quickraceFiles, levelName, lvlName)
  local tracks = {}
  local procedurals = lvlName == "driver_training"
  for _, trackFile in ipairs(quickraceFiles) do
    local dir, filename, ext = path.split(trackFile, true)
    if ext == 'json' or ext == 'race.json' then
      local file = jsonReadFile(trackFile)
      if not file then
        log('E', 'failed to load this track ' , tostring(trackFile).. ' Check Json file')
      elseif procedurals ~= not file.procedural then -- no this cannot be changed to procedurals == file.procedural, becaus then false == nil -> false
        file.originalInfo = deepcopy(file)
        file.sourceFile = trackFile
        --file.ignoreAsMission = true
        local dir, filename, ext = path.splitWithoutExt(trackFile, true)
        file.trackName = filename
        file.directory = dir
        --file.raceFile = "/levels/"..levelName.."/quickrace/"..file.trackName..'.json'
        file.difficulty = file.difficulty and tonumber(file.difficulty) or nil
        file.prefabs = file.prefabs or {}
        file.reversePrefabs = file.reversePrefabs or {}
        file.forwardPrefabs = file.forwardPrefabs or {}
        file.customMarker = 'default'
        file.raceFile = ext == 'race.json' and trackFile or nil--FS:findFilesByRootPattern(file.directory, file.trackName..'.race.json', 0, true, false)
        local officialPath = trackFile
        file.official = FS:fileExists(officialPath) and isOfficialContentVPath(officialPath)

        if file.luaFile then
          file.luaFile = "/levels/"..levelName.."/quickrace/"..file.luaFile
        else
          file.luaFile = nil
        end

        if file.procedural then
          file.customData.seed = math.random(500*500*500*500)
          file.ignoreAsMission = true
        end

        -- find preview for forward and reverse
        local tmp = FS:findFiles(file.directory, file.trackName..'.jpg', 0, true, false)
        file.previews = {}
        for _, p in pairs(tmp) do
          table.insert(file.previews, p)
        end

        local tmp = FS:findFiles(file.directory, file.trackName..'_reverse.jpg', 0, true, false)
        file.reversePreviews = {}
        for _, p in pairs(tmp) do
          table.insert(file.reversePreviews, p)
        end


        -- set spawnSpheres.
        if not file.spawnSpheres then
          file.spawnSpheres = {}
        end

        if not file.closed then
          file.lapCount = 1
        end

        file.lapCount = file.lapCount or 1

        file.spawnSpheres.standing = file.spawnSpheres.standing or file.trackName.."_standing_spawn"
        file.spawnSpheres.standingReverse = file.spawnSpheres.standingReverse or file.trackName.."_standingReverse_spawn"
        file.spawnSpheres.rolling = file.spawnSpheres.rolling or file.trackName.."_rolling_spawn"
        file.spawnSpheres.rollingReverse = file.spawnSpheres.rollingReverse or file.trackName.."_rollingReverse_spawn"

        file.tod = file.tod or 3

        -- figure out if a html start file is existing
        local htmldiscovered = false
        if not file.startHTML then
          file.startHTML = "quickrace/"..file.trackName .. '.html'
          htmldiscovered = true
        end
        if not FS:fileExists("/levels/"..levelName..'/'..file.startHTML) then
          if not htmldiscovered then
            log('W', 'scenarios', 'start html not found, disabled: ' .. file.startHTML)
          end
          file.startHTML = nil
          file.introType = 'none'
        end

        if not file.introType then
          file.introType = 'htmlOnly'
        end

        if file.raceFile  then
          if file.classification then
            file.lapCount = file.defaultLaps
            file.closed = file.classification.closed
            file.allowRollingStart = file.classification.allowRollingStart
            file.reversible = file.classification.reversible
          end
          file.lapConfig = {}
          file.startLineCheckpoint = ''
        end
        table.insert(tracks, file)
      end
    end
  end
  table.sort(tracks, function(a,b) return a.name < b.name end)
  return tracks
end

local autoPrefabs = {
  prefabs = '',
  reversePrefabs = '_reverse',
  forwardPrefabs = '_forward'
}
local prefabExt = {'.prefab', '.prefab.json'}

local function loadQuickrace(scenarioKey, scenarioFile, trackFile, vehicleFile, raceType)
  scenarioFile.track = trackFile
  scenarioFile.vehicle = vehicleFile
  scenarioFile.name = trackFile.name
  if trackFile.trackEditorFile then
    scenarioFile.name = "trackEditor_"..scenarioFile.name
  end
  scenarioFile.scenarioName = trackFile.trackName
  scenarioFile.lapCount = trackFile.lapCount
  scenarioFile.lapConfig = trackFile.lapConfig
  if trackFile.lapConfigBranches then
    scenarioFile.lapConfigBranches = trackFile.lapConfigBranches
  end

  -- add automatic prefabs only if they exist
  for list, suf in pairs(autoPrefabs) do
    for _, ext in ipairs(prefabExt) do
      local file = "levels/"..scenarioFile.levelName.."/quickrace/"..trackFile.trackName..suf..ext
      if FS:fileExists(file) then
        table.insert(trackFile[list], file)
      end
    end
  end

  if trackFile.reverse then
    for _,p in ipairs(trackFile.reversePrefabs) do
      trackFile.prefabs[#trackFile.prefabs+1] = p
    end
  else
    for _,p in ipairs(trackFile.forwardPrefabs) do
      trackFile.prefabs[#trackFile.prefabs+1] = p
    end
  end

  scenarioFile.prefabs = trackFile.prefabs

  scenarioFile.startHTML = trackFile.startHTML
  scenarioFile.introType = trackFile.introType

  scenarioFile.isReverse = false
  scenarioFile.isReverse = false
  if trackFile.reverse then
    local rev = {}
    for i,c in ipairs(scenarioFile.lapConfig) do
      rev[#scenarioFile.lapConfig +1 - i] = c
    end
    scenarioFile.isReverse = true
    scenarioFile.lapConfig = rev

    if not trackFile.closed then
      local tmp = trackFile.finishLineCheckpoint
      trackFile.finishLineCheckpoint = trackFile.startLineCheckpoint
      trackFile.startLineCheckpoint = tmp
    end

  end

  scenarioFile.lapConfig[#scenarioFile.lapConfig+1] = trackFile.finishLineCheckpoint

  if trackFile.rollingStart then
    if trackFile.closed then
      scenarioFile.startTimerCheckpoint = trackFile.finishLineCheckpoint
    else
      scenarioFile.startTimerCheckpoint = trackFile.startLineCheckpoint
    end
    scenarioFile.rollingStart = true
  end
  --dump(scenarioFile.lapConfig)

  --  dump("End = " .. trackFile.startLineCheckpoint)
  local disableToD = false
  if scenarioFile.levelInfo.disableQuickraceTimeOfDay then disableToD = true end
  --dump(scenarioFile.levelInfo)
  if not disableToD then
    local tod = {0.5, 0.775, 0.85, 0.9, 0, 0.1, 0.175, 0.23, 0.245, 0.5}

    scenarioFile.levelObjects= {
          tod = {
              time = tod[trackFile.tod+1],
              play = false,
          }
      }
   --dump(trackFile.tod)
  else
   --scenarioFile.levelObjects = nil
  end

  scenarioFile.isQuickRace = true
  scenarioFile.quickraceType = raceType
  scenarioFile.tracks = {}

  local processedScenario = scenario_scenariosLoader.processScenarioData(scenarioKey, scenarioFile)

  return processedScenario
end

local function starQuickRaceFromUI(scenarioFile, trackFile, vehicleFile, raceType)
  if scenetree.MissionGroup then
    log('D', logTag, 'Delaying start of quickrace until current level is unloaded...')

    M.triggerDelayedStart = function()
      log('D', logTag, 'Triggering a delayed start of quickrace...')
      M.triggerDelayedStart = nil
      M.startQuickrace(scenarioFile, trackFile, vehicleFile,raceType)
    end

    endActiveGameMode(M.triggerDelayedStart)
  else
    -- log('I', logTag, 'Start of quickrace: ' .. dumps(trackFile))
    local modules = {}
    for _,m in ipairs(M.quickRaceModules) do
      modules[#modules+1] = m
    end
    modules[#modules+1] = trackFile.luaFile
    if trackFile.isTrackEditorTrack then
      modules[#modules+1] = 'util/trackBuilder/splineTrack'
    end
    -- log("I",logTag,"Make Modules.." .. dumps(modules))
    unloadAutoExtensions()
    loadPresetExtensions()
    extensions.load(modules)

    local quickraceScenario = loadQuickrace(nil, scenarioFile, trackFile, vehicleFile, raceType)
    -- dump(quickraceScenario)
    scenario_scenarios.executeScenario(quickraceScenario)
  end
end

-- This function will merge the track and vehicle data into the scenario and start the scenario.
local function startQuickrace(scenarioFile, trackFile, vehicleFile, type)

  if campaign_exploration and campaign_exploration.getExplorationActive() then
    campaign_exploration.startTimeTrail(scenarioFile, trackFile, vehicleFile)
  else
    starQuickRaceFromUI(scenarioFile, trackFile, vehicleFile, type)
  end
end

-- These two functions manage the loading and unloading of the hotlapping module when used in freeroam,
-- so that it doesnt have to be a core module but only loaded on demand.
local function uiEventStartHotlapping()
  --log("I",logTag,"uiEventStartHotlapping called.....")
  if not scenario_scenarios or not (scenario_scenarios and scenario_scenarios.getScenario()) then
    if not core_hotlapping then
      extensions.load({'core_hotlapping'});
    end
  end
  if core_hotlapping then
    core_hotlapping.startHotlapping()
  end
end

local function uiHotlappingAppDestroyed()
  --log("I",logTag,"uiHotlappingAppDestroyed called.....")
  if not scenario_scenarios or not (scenario_scenarios and scenario_scenarios.getScenario()) then
    extensions.unload('core_hotlapping');
  end
end

M.loadQuickrace             = loadQuickrace
M.getQuickraceList          = getQuickraceList
M.customPreviewLoader       = customPreviewLoader
M.getTracks                 = getTracks
M.startQuickrace            = startQuickrace
M.getLevelList              = getLevelList
M.getLevel                  = getLevel
M.getLevelTrack             = getLevelTrack
M.getTrackEditorTracks      = getTrackEditorTracks
M.loadTrackBuilderJSON      = loadTrackBuilderJSON
M.uiEventStartHotlapping    = uiEventStartHotlapping
M.uiHotlappingAppDestroyed  = uiHotlappingAppDestroyed
return M

