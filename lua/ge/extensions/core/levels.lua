-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = { "freeroam_levelStats" }

local cache = nil
local titleCache = {}
local previewCache = {}
local timeOfDayOptionsCache = {}

-- finds all levels: this has a lot of backward compatibility code in there
-- warning: slow, lots of filesystem interaction
local function _findAvailableLevels()
  local res = {}
  local level_dirs = FS:findFiles('/levels/', '*', 0, false, true)
  if util_asyncBulkLoader and util_asyncBulkLoader.isLoading() then
    util_asyncBulkLoader.addTotal(#level_dirs)
  end
  table.sort(level_dirs, function(a,b) return string.lower(a) < string.lower(b) end )

  for _, d in pairs(level_dirs) do
    -- check if its a valid folder really
    if FS:fileExists(d) or not FS:directoryExists(d) or d == "/levels/mod_info" then
      goto continue
    end
    local l = {}
    -- valid level?
    l.dir = d
    l.infoPath = d .. '/info.json'
    if not FS:fileExists(l.infoPath) then
      log('W', '', 'info.json missing: ' .. l.infoPath)
    end

    -- figure out name
    l.levelName = d:match('levels/([^/]+)')

    -- figure out entry points (in order of priority)
    local newSceneTreeEntry = d .. '/main/'
    local oldMainFile = path.getPathLevelMain(l.levelName)
    if FS:directoryExists(newSceneTreeEntry) then
      l.fullfilename = newSceneTreeEntry
    elseif FS:fileExists(oldMainFile) then
      l.fullfilename = oldMainFile
    else
      -- look for any mission files in there and use the first
      local files = FS:findFiles(d, '*.mis', 1, true, false)
      if #files ~= 0 then
        l.fullfilename = files[1]
      else
        log('E', '', 'No entry point for level found: ' .. d .. '. Ignoring level.')
        goto continue
      end
    end

    -- figure out the entry point value. We use that to find some other files (decals, images, etc)
    local dirname, filename, ext = path.split(l.fullfilename)
    filename = string.gsub(filename, "%.mis$", "")
    l.entryPoint = string.gsub(filename, "%.level.json$", "")

    l.dirEntry = l.dir .. '/' .. l.entryPoint

    if util_asyncBulkLoader and util_asyncBulkLoader.isLoading() then
      util_asyncBulkLoader.addCount(1)
      util_asyncBulkLoader.yield("findAvailableLevels " .. d)
    end
    table.insert(res, l)
    ::continue::
  end
  return res
end

local function getList()
  if cache ~= nil then
    --dump{'cache valid: ', cache}
    return cache
  end

  local levels = {}
  if not FS:directoryExists('/levels/') then
    log('E', '', 'main levels folder not found: /levels/')
    return {}
  end

  -- find all levels
  local found_levels = _findAvailableLevels()
  --dump{'found_levels', found_levels}

  for _, l in pairs(found_levels) do
    -- so, enrich the data of the levels for the user interface below
    local info = jsonReadFile(l.infoPath) or {}

    -- figure out the mod this belongs to
    local mod = extensions.core_modmanager.getModFromPath(l.infoPath, true)
    if mod then
      info.modID = mod.modID
      info.modName = mod.modname
      if mod.modData and mod.modData.title then
        info.modTitle = mod.modData.title
      end
    else
      info.modID = nil
      info.modName = 'BeamNG'
      info.modTitle = 'BeamNG.drive'
    end

    info.misFilePath = l.dir ..'/'..l.entryPoint
    info.dir = l.dir
    info.levelName = l.levelName
    info.fullfilename = l.fullfilename

    if info.hidden ~= nil then
      log("W", "", "Found deprecated flag 'hidden' in level: "..dumps(l.levelName)..". The flag has been renamed to 'isAuxiliary'")
      if info.isAuxiliary == nil then
        info.isAuxiliary = info.hidden
      end
    end

    info["official"] = isOfficialContentVPath(l.dir)

    if type(info["previews"]) == 'table' and #info["previews"] > 0 then
      -- add prefix
      local newPreviews = {}
      for _, img in pairs(info["previews"]) do
        table.insert(newPreviews, l.dir..'/' .. img)
      end
      info["previews"] = newPreviews
    else
      info["title"] = l.levelName
      info["previews"] = {
        imageExistsDefault(l.dirEntry..'.png', imageExistsDefault(l.dirEntry..'_preview.png')),
      }
    end
    info["preview"] = nil

    local foundDefaultSpawn = false
    if type(info.spawnPoints) == 'table' then
      for _, point in pairs(info.spawnPoints) do
        if not point.previews then point.previews = {} end

        -- add path prefix
        local newPreviews = {}
        for _, img in pairs(point.previews) do
          table.insert(newPreviews, l.dir..'/' .. img)
        end
        table.insert(newPreviews, imageExistsDefault(l.dir..'/'.. (point.preview or ''), l.dirEntry..'_preview.png'))
        point.previews = newPreviews
        point.preview = nil
        if point.objectname == info.defaultSpawnPointName then
          foundDefaultSpawn = true
          --point.previews = info["previews"]
          point.levelPreviews = info["previews"]
          point.flag = 'default'
        end
      end
    else
      info.spawnPoints = {}
    end

    if not foundDefaultSpawn then
      -- insert default spawn point
      table.insert(info.spawnPoints, {
        previews = info["previews"],
        translationId = 'ui.common.default',
        flag = 'default'
      })
    end

    if type(info.minimap) == 'table' then
      for _, elem in ipairs(info.minimap) do
        elem.file = l.dir..'/' .. elem.file
      end
    end

    -- default to true if not set
    if info.supportsTraffic == nil then info.supportsTraffic = true end
    if info.supportsTimeOfDay == nil then info.supportsTimeOfDay = true end

    table.insert(levels, info)
    ::continue::
  end

  -- now filter out .mis levels if a json version of the same exists
  local jsonLevels = {}
  for _, level in pairs(levels) do
    if string.find(level.fullfilename, ".json") then
      jsonLevels[level.levelName] = true
    end
  end

  local newLevels = {}
  for _, level in pairs(levels) do
    -- check if there is a json version of this, thus hide the old .mis file format
    if string.find(level.fullfilename, ".mis") and jsonLevels[level.levelName] then
      --log('D', '', 'not adding .mis level as .json format is existing for the same level: ' .. dumps(level))
    else
      table.insert(newLevels, level)
    end
  end
  levels = newLevels

  -- sort by name, case insensitive
  table.sort(levels, function(a, b) return string.lower(a.levelName) < string.lower(b.levelName) end )

  cache = levels
  --dump{"generated levels cache: ", cache}

  return cache
end

local function isListLoaded()
  return cache ~= nil
end

-- Returns array of level names only
local function getLevelNames()
  local res = {}
  for _, level in ipairs(getList()) do
    table.insert(res, level.levelName)
  end
  return res
end

local function getLevelPaths()
  local res = {}
  for _, level in ipairs(getList()) do
    table.insert(res, level.dir.."/")
  end
  return res
end

local function notifyUI()
  local result = M.getListWithStats()
  guihooks.trigger('onLevelsChanged', result.levels, result.uiStats)
end

local function getLevelByName(levelName)
  levelName = string.lower(levelName)
  for _, l in ipairs(getList()) do
    if string.lower(l.levelName) == levelName then
      return l
    end
  end
  return nil
end

local function getLevelTitle(levelName)
  if not levelName then
    return nil
  end

  local lowerLevelName = string.lower(levelName)

  -- Check cache first
  if titleCache[lowerLevelName] then
    return titleCache[lowerLevelName]
  end

  -- Find the level and get its title
  local level = getLevelByName(levelName)
  if level then
    local title = level.title or level.levelName
    titleCache[lowerLevelName] = title
    return title
  end

  -- Level not found, cache nil to avoid repeated lookups
  titleCache[lowerLevelName] = nil
  return nil
end

local function getLevelPreview(levelName)
  if not levelName then
    return nil
  end

  local lowerLevelName = string.lower(levelName)

  -- Check cache first
  if previewCache[lowerLevelName] then
    return previewCache[lowerLevelName]
  end

  -- Find the level and get its default preview
  local level = getLevelByName(levelName)
  if level then
    local preview = nil
    if type(level.previews) == 'table' and #level.previews > 0 then
      preview = level.previews[1] -- Get the first preview
    end
    previewCache[lowerLevelName] = preview
    print(string.format("getLevelPreview: %s -> %s", levelName, preview or "nil"))
    return preview
  end

  -- Level not found, cache nil to avoid repeated lookups
  previewCache[lowerLevelName] = nil
  print(string.format("getLevelPreview: %s -> nil", levelName))
  return nil
end

local function getTimeOfDayOptions(levelName)
  if not levelName then
    return {}
  end

  local lowerLevelName = string.lower(levelName)

  -- Check cache first
  if timeOfDayOptionsCache[lowerLevelName] then
    return timeOfDayOptionsCache[lowerLevelName]
  end

  local level = getLevelByName(levelName)
  local timeOfDayOptions = {}

  if level and level.supportsTimeOfDay then
    local defaultOptions = core_environment.getDefaultTimeOfDayOptions()
    for _, option in ipairs(defaultOptions) do
      table.insert(timeOfDayOptions, {
        key = option.key,
        value = option.value,
        label = option.label
      })
    end
  end

  -- Sort options by time value (morning to night)
  -- Time values: 0.5-1.0 = morning/day, 0.0-0.5 = evening/night
  table.sort(timeOfDayOptions, function(a, b)
    -- If both values are >= 0.5, sort normally
    if a.value > 0.5 and b.value > 0.5 then
      return a.value < b.value
    end
    -- If both values are < 0.5, sort normally
    if a.value <= 0.5 and b.value <= 0.5 then
      return a.value < b.value
    end
    -- If one is >= 0.5 and other is < 0.5, the >= 0.5 comes first
    return a.value > 0.5
  end)

  -- Cache the result
  timeOfDayOptionsCache[lowerLevelName] = timeOfDayOptions
  return timeOfDayOptions
end



local function onFilesChanged(files)
  for _,v in pairs(files) do
    local filename = v.filename
    if string.startswith(filename, '/levels/') then
      -- dump{'onFileChanged: invalidating level cache', filename, type}
      cache = nil
      titleCache = {} -- Clear title cache when level files change
      previewCache = {} -- Clear preview cache when level files change
      timeOfDayOptionsCache = {} -- Clear time of day options cache when level files change
      notifyUI()
      return
    end
  end
end

local nextSpawnVehicle = nil
--[[
local function maybeLoadDefaultVehicle()
  local success = core_vehicles.loadMaybeVehicle(nextSpawnVehicle)
  if not success then
    log("E", "", "Wrong 'spawnVehicle' parameter used on level load request: "..dumps(nextSpawnVehicle))
  end
end]]
local function maybeSpawnDefaultVehicle()
  if nextSpawnVehicle == nil then
    -- spawn default vehicle
    nextSpawnVehicle = core_vehicles.getDefaultVehicleParams()
  end
  if nextSpawnVehicle == false then
    -- do nothing
  end
  if type(nextSpawnVehicle) == 'table' then
    local model, options = unpack(nextSpawnVehicle)
    local modelData = core_vehicles.getModel(model)
    if not modelData or not next(modelData) then
      log("E", "", "Model: "..dumps(model).." does not exist. using default vehicle instead.")
      nextSpawnVehicle = core_vehicles.getDefaultVehicleParams()
      model, options = unpack(nextSpawnVehicle)
    end
    if options.color == '' then
      options.color = nil
    end
    options.vehicleName = "thePlayer"

    local spawnPoint = spawn.pickSpawnPoint('player')
    --local spawnPoint = setSpawnpoint.loadDefaultSpawnpoint()
    --spawnPoint = scenetree.findObject(spawnPoint)
    if spawnPoint then
      options.pos = spawnPoint:getPosition()
      options.rot = quat(spawnPoint:getRotation()) * quat(0,0,1,0)
    end
    options.canSpawnAnotherVehicleCheck = false
    local vehicle = core_vehicles.spawnNewVehicle(model, options)
    if not vehicle then
      log("E", "", "Failed to spawn vehicle: "..dumps(nextSpawnVehicle))
    end
    local missionCleanup = scenetree.MissionCleanup
    if not missionCleanup then
      log('E', 'vehicles.loadMaybeVehicle', 'missionCleanup does not exist')
    elseif vehicle then
      missionCleanup:addObject(vehicle)
    end
    local missionGroup = scenetree.MissionGroup
    if not missionGroup then
      log('E', 'vehicles.loadMaybeVehicle', 'MissionGroup does not exist')
    elseif vehicle then
      missionGroup:addObject(vehicle)
    end
    if vehicle then
      vehicle.canSave = false
    end
  end
  nextSpawnVehicle = nil
end

local function onClientPostStartMission()
  for _, name in ipairs(scenetree.findClassObjects('DecalRoad')) do
    local road = scenetree.findObject(name)
    if road then
      road:regenerate()
    end
  end
end

local function expandMissionFileName(missionFileName)
  if FS:directoryExists(missionFileName) then
    return missionFileName
  end
  local mfn = String(missionFileName)
  local missionFile = FS:expandFilename(missionFileName)

  if  FS:fileExists(missionFile) then
    return missionFile
  end
  --If the mission file doesn't exist... try to fix up the string.
  local newMission = missionFile
  --Support for old .mis files
  if string.find(missionFile, ".mis$") then
    newMission = string.gsub(missionFile, ".mis$", ".level.json")

    if FS:fileExists(newMission) then
      return newMission
    end
  end

  --try the new filename
  if not string.find(missionFile, ".level.json$") then
    newMission = missionFile..".level.json"

    if FS:fileExists(newMission) then
      return newMission
    end
  end

  if FS:fileExists(missionFile..'.mis') then
    return missionFile..'.mis'
  end
end

local function startLevelActual(levelPath, delayedStart, customLoadingFunction)
  if scenetree.MissionCleanup then
    return
  end

  -- check if new format
  if levelPath:find('main.level.json') and not FS:fileExists(levelPath) then
    local newName = levelPath:sub(0, levelPath:find('main.level.json') - 1)
    if FS:directoryExists(newName) then
      log('D', '', 'converting level argument to new format: ' .. tostring(levelPath) .. ' > ' .. tostring(newName))
      levelPath = newName
    end
  end

  local loadLevel = function()
    local expandedLevelPath = expandMissionFileName(levelPath)
    if not expandedLevelPath or expandedLevelPath == "" then
      log('E', '', 'Expanded mission file is invalid: "'..dumps(expandedLevelPath)..'" from "'..tostring(levelPath)..'"')
      core_gamestate.requestExitLoadingScreen('levels')
      return false
    end

    server.createGame(expandedLevelPath, customLoadingFunction)
    core_gamestate.requestExitLoadingScreen('levels')
  end

  if delayedStart then
    log('D', '', 'Triggering a delayed start of loading level...')
    endActiveGameMode(loadLevel)
  else
    return loadLevel()
  end
end

local function getLevelName(path)
  return string.match(path, '^/*levels/(.-)/.*')
end

local function startLevel(levelPath, delayedStart, customLoadingFunction, spawnVehicle)
  nextSpawnVehicle = spawnVehicle
  -- restirct from calling again until done
  if core_gamestate.getLoadingStatus('levels') then return end
  core_gamestate.requestEnterLoadingScreen('levels')
  local function help ()
    return startLevelActual(levelPath, delayedStart, customLoadingFunction)
  end
  if scenetree.MissionCleanup then
    return serverConnection.disconnect(help)
  else
    return help()
  end
end


local function getSpawnPointPosRot(poi, veh)
  local spawnPoint = scenetree.findObject(poi.data.objectname)
  if spawnPoint then
    return spawnPoint:getPosition(), quat(0,0,1,0) * spawnPoint:getRotation()
  end
  return nil, nil
end
local function onGetRawPoiListForLevel(levelIdentifier, elements)
  local levelInfo = getLevelByName(levelIdentifier)

  for i, spawnPoint in ipairs(levelInfo.spawnPoints or {}) do
    if spawnPoint.objectname then
      if not career_career.isActive() or career_modules_spawnPoints.isSpawnPointDiscovered(levelInfo.levelName, spawnPoint.objectname) then
        local obj = scenetree.findObject(spawnPoint.objectname)
        if obj then
          local data = deepcopy(spawnPoint)
          data.type = "spawnPoint"
          data.id = data.objectname or ("spawnPoint-"..i)

          table.insert(elements,  {
            id = data.id,
            data = data,
            markerInfo = {
              bigmapMarker = {pos = obj:getPosition(), icon = "poi_fasttravel_round_orange",  quickTravelPosRotFunction = getSpawnPointPosRot, name = data.translationId, description = data.description, thumbnail = data.previews[1], previews = data.previews}
            }
          })
        else
          log("E","","Could not find spawnpoint object! " .. dumps(spawnPoint.objectname))
        end
      end
    end
  end
end
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel

local function getListWithStats()
  return { levels = getList(), uiStats = freeroam_levelStats.getUiStats() }
end

-- metatable for this module for backward compatibility
M.levelsDir = '/levels/' -- backward compatibility

-- public interface
M.onFilesChanged         = onFilesChanged
M.onClientPostStartMission = onClientPostStartMission
--M.maybeLoadDefaultVehicle = maybeLoadDefaultVehicle
M.maybeSpawnDefaultVehicle = maybeSpawnDefaultVehicle
M.requestData           = notifyUI
M.startLevel            = startLevel
M.expandMissionFileName = expandMissionFileName
M.getLevelName          = getLevelName
M.getLevelPaths         = getLevelPaths

-- main API
M.getList        = getList
M.isListLoaded  = isListLoaded
M.getListWithStats = getListWithStats
M.getLevelNames  = getLevelNames
M.getSimpleList  = getLevelNames -- for backward compatibility.
M.getLevelByName = getLevelByName
M.getLevelTitle  = getLevelTitle
M.getLevelPreview = getLevelPreview
M.getTimeOfDayOptions = getTimeOfDayOptions

return M
