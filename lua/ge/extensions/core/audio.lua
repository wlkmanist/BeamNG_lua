-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local registeredBanks = {}
local fmodBankFileSize = {}
local fmod_banks = {}
local fmodBanksLoadOrder = {}
local loadedBankCache = {} -- keeps track on what banks are already loaded for faster lua reloading
local levelProjectsCache = {}
local inited = false

local function registerBaseBank(path)
  local inLevelOrLoadingOrLoading = getMissionFilename() ~= "" or LoadingManager:isLoadingInProgress()
  if inLevelOrLoading then
    return
  end
  if string.sub(path, 1, 1) ~= '/' then
    path = "/"..path
  end
  path = string.lower(path)
  if inited then
    if not loadedBankCache[path] then
      loadedBankCache[path] = true
      if SFXFMODProject then SFXFMODProject.loadBaseBank(path)
      else log("E", "audio", "SFXFMODProject is nil") end
    end
  else
    table.insert(registeredBanks, path)
  end
end

local loadingBankFilenames = {}
local function loadBankSets()
  local rootGroup = scenetree.findObject("RootGroup")
  for _,key in ipairs(fmodBanksLoadOrder) do
    local v = fmod_banks[key]
    table.clear(loadingBankFilenames)
    for _,filepath in pairs(v) do
      table.insert(loadingBankFilenames, filepath)
    end
    -- log('E','','Loading banks '..tostring(key)..' : '..dumps(loadingBankFilenames))
    if SFXFMODProject then
      local project = SFXFMODProject()
      if project then
        project:registerObject(key)
        project:loadBankSet(loadingBankFilenames)
        rootGroup:addObject(project)
        table.insert(levelProjectsCache, key)
      end
    end
  end

  -- for i, v in ipairs(registeredBanks) do
  --   if not loadedBankCache[v] then
  --     loadedBankCache[v] = true
  --     if SFXFMODProject then SFXFMODProject.loadBaseBank(v)
  --     else log("E", "audio", "SFXFMODProject is nil") end
  --   end
  -- end
  -- registeredBanks = {}

  inited = true
end

local function populateBankSets()
  local process_bank = function(filepath)
    if string.sub(filepath, 1, 1) ~= '/' then
      filepath = "/"..filepath
    end
    filepath = string.lower(filepath)
    local stringParts = {}
    local filename = string.match(filepath, "^(.-)%.") --(.-) capture is non-greedy, capture as few characters as possible. '%.' means '.' has to exist in the string. Capture upto 1st '.' excluding the period.
    local key = string.match(filename, "([^/]*)$")
    local fileStats = FS:stat(filepath)
    local bankSet = fmod_banks[key] or {}
    local bankFileSize = fmodBankFileSize[key] or 0

    -- log("I", "", filepath ..': '..tostring(filename)..' key = '..tostring(key))

    bankFileSize = bankFileSize + fileStats.filesize
    if string.find(filepath, 'assets') then
      bankSet.assets = filepath
    elseif string.find(filepath, 'strings') then
      bankSet.strings = filepath
    elseif string.find(filepath, 'streams') then
      bankSet.streams = filepath
    else
      bankSet.meta = filepath
    end

    fmod_banks[key] = bankSet
    fmodBankFileSize[key] = bankFileSize
  end

  table.clear(fmod_banks)
  table.clear(fmodBankFileSize)

  local platformDir = PlatformSwitches.audioFolderName
  local asset_directory = '/art/sound/fmod/'..platformDir
  local bankFiles = FS:findFiles(asset_directory, '*.bank', 0, true, false)
  bankFiles = tableMerge(bankFiles, FS:findFiles(asset_directory..'/mods', '*.bank', 0, true, false))
  for _,filepath in ipairs(bankFiles) do
    process_bank(filepath)
  end

  local useHeadphones = VariableRegistry.get('$pref::SFX::enableHeadphonesMode')
  --dump("useHeadphones = "..tostring(useHeadphones))
  if useHeadphones then
    local headphoneBanks = FS:findFiles(asset_directory..'_headphones', '*.bank', 0, true, false)
    for _,filepath in ipairs(headphoneBanks) do
      process_bank(filepath)
    end
  end

  table.clear(fmodBanksLoadOrder)
  for k,_ in pairs(fmod_banks) do
    table.insert(fmodBanksLoadOrder, k)
  end

  local orderFunction = function(a, b)
    -- Very important! Load banks sets with 'string' banks firsts, then 'preload' banks, then the rest
    local aIsPreload = string.find(a, "preload") ~= nil
    local bIsPreload = string.find(b, "preload") ~= nil
    local aIsStrings = fmod_banks[a].strings ~= nil
    local bIsStrings = fmod_banks[b].strings ~= nil
    local aBankSize = fmodBankFileSize[a] or 0
    local bBankSize = fmodBankFileSize[b] or 0

    if aIsStrings ~= bIsStrings then
        return aIsStrings
    end
    if aIsPreload ~= bIsPreload then
        return aIsPreload
    end
    if aBankSize == bBankSize then
      return a < b
    end

    return aBankSize > bBankSize
  end
  table.sort(fmodBanksLoadOrder, orderFunction)

  -- log("I", "", 'fmod_banks = '..dumps(fmod_banks))
  -- log("I", "", 'fmodBankFileSize = '..dumps(fmodBankFileSize))
  -- log("I", "", 'load order = '..dumps(fmodBanksLoadOrder))
end

local function onFirstUpdate()
  --log("I", "onFirstUpdate", 'onFirstUpdate called....')
  profilerPushEvent('audioLoadBanksFirstFrame')
  if M.hotloadTriggered then
    log("I", "audio", 'Hotloading banks....')
    loadedBankCache = {}
    levelProjectsCache  = {}
    if SFXFMODProject then
      SFXFMODProject.hotloadingTriggered()
    else
     log("E", "audio", "SFXFMODProject is nil")
   end
  end

  populateBankSets()
  loadBankSets()

  if M.hotloadTriggered then
    -- We need to trigger what would have happened in onClientPreStartMission because we are
    -- already in the level and triggered hotloading
    -- loadLevelBanks()
    if SFXFMODProject then
      SFXFMODProject.hotloadingCompleted()
    else
     log("E", "audio", "SFXFMODProject is nil")
    end
  end

  M.hotloadTriggered = nil

  profilerPopEvent('audioLoadBanksFirstFrame')
end

local function onClientPreStartMission(levelPath)
  -- log("I", "loadLevelBank", "Loading default level banks")
  profilerPushEvent('loadAudioBanks')

  -- loadLevelBanks()
  profilerPopEvent('loadAudioBanks')
end

local function onClientEndMission()
  -- If we unload banks later when we exit a level, we need to clear the cache so that the banks get loaded again.
end

local function startProcessForHotloading()
  local rootGroup = scenetree.findObject("RootGroup")
  for i, projectName in ipairs(levelProjectsCache) do
    local project = scenetree.findObject(projectName)
    if project then
      rootGroup:removeObject(project)
      project:deleteObject()
    end
  end
end

local function triggerBankHotloading()
  log('I', 'audio', 'Banks hotloading started.....')
  startProcessForHotloading()
  loadedBankCache = {}
  levelProjectsCache  = {}
  if SFXFMODProject then
    SFXFMODProject.hotloadingTriggered()
  else
    log("E", "audio", "SFXFMODProject is nil")
  end

  populateBankSets()
  loadBankSets()

  if SFXFMODProject then
    SFXFMODProject.hotloadingCompleted()
  else
    log("E", "audio", "SFXFMODProject is nil")
  end
  log('I', 'audio', 'Banks hotloading finished.')
end

local function onFilesChanged(files)
  local reloadBanks = false
  for _,v in pairs(files) do
    local filename = v.filename
    -- file notification strips leading forward slash but the loadedBankCache keys start with a leading forward slash.
    -- make sure the key we use here matches that used previously in loadBaseBank
    if string.sub(filename, 1, 1) ~= '/' then
      filename = "/"..filename
    end

    if filename and filename:match('.*%.bank$') then
      filename = string.lower(filename)
      loadedBankCache[filename] = false

      -- We have to wait for all banks to complete building before we trigger hotloading
      for k,v1 in pairs(loadedBankCache) do
        if v1 == true then
          goto continue
        end
      end
      log("I", "onFileChanged", 'onFileChanged called....')
      reloadBanks = true
    end
    ::continue::
  end

  if reloadBanks then
    triggerBankHotloading()
  end
end

local function onSerialize()
    startProcessForHotloading()
    return { hotloadTriggered = true }
end

local function onDeserialized(data)
  M.hotloadTriggered = data.hotloadTriggered
end

local function onPhysicsPaused()
  SFXSystem.setGlobalParameter("g_GamePause", 1)
end

local function onPhysicsUnpaused()
  SFXSystem.setGlobalParameter("g_GamePause", 0)
end

M.onReplayStateChanged = function(newState)
  if M.prevReplayState == newState.state and M.prevReplayPaused == newState.paused then
    return
  end

  local paused = simTimeAuthority.getPause()
  if paused then
    SFXSystem.setGlobalParameter("g_GamePause", 1)
  else
    SFXSystem.setGlobalParameter("g_GamePause", 0)
  end

  M.prevReplayState = newState.state
  M.prevReplayPaused = newState.paused
end

M.onFirstUpdate = onFirstUpdate
M.registerBaseBank = registerBaseBank
M.triggerBankHotloading = triggerBankHotloading

M.onClientPreStartMission = onClientPreStartMission
M.onClientEndMission = onClientEndMission
M.onPhysicsPaused = onPhysicsPaused
M.onPhysicsUnpaused = onPhysicsUnpaused

M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onFilesChanged = onFilesChanged

return M
