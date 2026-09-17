-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local saveRoot = 'settings/cloud/saves/'
local saveSystemVersion = 64
local backwardsCompVersion = 36
local numberOfAutosaves = 2
local creationDateOfCurrentProfile

local currentProfile
local currentSavePath
local currentDisplayName

local function getAllSaveFolders(profile)
  local res = {}
  local folders = FS:directoryList(saveRoot .. profile, false, true)
  for i = 1, tableSize(folders) do
    local dir, filename, ext = path.split(folders[i])
    local data = jsonReadFile(dir .. filename .. "/info.json")
    if data then
      data.name = filename
      table.insert(res, data)
    end
  end

  table.sort(res, function(a,b) return a.date < b.date end)
  return res
end

-- Picks the oldest or newest save folder out of the given list, based on the date in info.json.
local function pickSaveByDate(folders, oldest)
  local resultDate = oldest and "A" or "0"
  local resultSave = ""
  for i = 1, tableSize(folders) do
    local folder = folders[i]
    local data = jsonReadFile(folder .. "/info.json")
    if oldest then
      if not data or not data.date or data.date < resultDate or data.corrupted then
        resultSave = folder
        resultDate = (data and not data.corrupted) and data.date or "0"
      end
    else
      if data and data.date and data.date > resultDate and not data.corrupted then
        resultSave = folder
        resultDate = data.date
      end
    end
  end
  return resultSave
end

local function getOldestAutosave(path)
  local folders = FS:directoryList(path, false, true)

  -- Get the autosave folders
  local existingAutosaves = {}
  for i = 1, tableSize(folders) do
    local name = string.match(folders[i], "([^/\\]+)$")
    if name and string.match(name, "^autosave%d+$") then
      existingAutosaves[name] = folders[i]
    end
  end

  -- Find an autosave slot name that isnt used yet to create a new autosave
  for i = 1, numberOfAutosaves do
    if not existingAutosaves["autosave" .. i] then
      return "/" .. path .. "/autosave" .. i
    end
  end

  -- All slots are used, so return the oldest existing autosave
  local autosaveFolders = {}
  for i = 1, numberOfAutosaves do
    if existingAutosaves["autosave" .. i] then
      table.insert(autosaveFolders, existingAutosaves["autosave" .. i])
    end
  end
  return pickSaveByDate(autosaveFolders, true)
end

-- Finds the newest save folder for a profile
local function getNewestSave(path)
  local folders = FS:directoryList(path, false, true)
  return pickSaveByDate(folders, false)
end

local function isLegalDirectoryName(name)
  return not string.match(name, '[<>:"/\\|?*]')
end

local function getUsedProfileNames()
  local usedNames = {}
  local folders = FS:directoryList(saveRoot, false, true)
  for i = 1, tableSize(folders) do
    local dir, filename, ext = path.split(folders[i])
    usedNames[string.lower(filename)] = true
  end
  return usedNames
end

local function getSanitizedProfileName(profileName)
  local usedNames = getUsedProfileNames()
  local sanitizedName = string.lower(profileName or '')
  sanitizedName = string.gsub(sanitizedName, '[^a-z0-9]', '')
  if sanitizedName == '' then
    sanitizedName = 'profile'
  end

  local candidate = sanitizedName
  local counter = 1
  while usedNames[string.lower(candidate)] do
    candidate = sanitizedName .. counter
    counter = counter + 1
  end
  return candidate
end

local function setProfile(profile, specificSaveFolder)
  extensions.hook("onBeforeSetProfile")
  if not profile then
    currentSavePath = nil
    currentProfile = nil
    currentDisplayName = nil
    creationDateOfCurrentProfile = nil
    extensions.hook("onSetProfile", nil, nil)
    return false
  end
  local savePath = specificSaveFolder and (saveRoot .. profile .. "/" .. specificSaveFolder) or getNewestSave(saveRoot .. profile) -- get newest save

  local data = jsonReadFile(savePath .. "/info.json")
  if data then
    if not data.version or M.getBackwardsCompVersion() > data.version then
      return false
    end
    creationDateOfCurrentProfile = data.creationDate
    currentDisplayName = data.displayName or profile
  else
    currentDisplayName = profile
    profile = getSanitizedProfileName(profile)
    savePath = specificSaveFolder and (saveRoot .. profile .. "/" .. specificSaveFolder) or getNewestSave(saveRoot .. profile)
    creationDateOfCurrentProfile = nil
  end

  currentSavePath = savePath
  currentProfile = profile

  extensions.hook("onSetProfile", currentSavePath, profile)
  return true
end

local function removeProfile(profile)
  if currentProfile == profile then
    if not career_career.isActive() then
      setProfile(nil)
      FS:directoryRemove(saveRoot .. profile)
    end
  else
    FS:directoryRemove(saveRoot .. profile)
  end
end

local function removeSaveFolder(profile, saveFolderName)
  if not profile or not saveFolderName or saveFolderName == "" then return false end
  if not isLegalDirectoryName(saveFolderName) then return false end

  local folderPath = saveRoot .. profile .. "/" .. saveFolderName
  if not FS:directoryExists(folderPath) then return false end

  if currentProfile == profile and currentSavePath then
    local currentFolderName = string.match(currentSavePath, "([^/\\]+)$")
    if currentFolderName == saveFolderName then return false end
  end

  FS:directoryRemove(folderPath)
  return true
end

local function renameFolderRec(oldName, newName, oldNameLength)
  local success = true
  local folders = FS:directoryList(oldName, true, true)
  for i = 1, tableSize(folders) do
    if FS:directoryExists(folders[i]) then
      if not renameFolderRec(folders[i], newName, oldNameLength) then
        success = false
      end
    else
      local newPath = string.sub(folders[i], oldNameLength + 2)
      newPath = newName .. newPath
      if FS:renameFile(folders[i], newPath) == -1 then
        success = false
      end
    end
  end
  return success
end

local function renameFolder(oldName, newName)
  local oldNameLength = string.len(oldName)
  if renameFolderRec(oldName, newName, oldNameLength) then
    -- If the renaming of all files was successful, remove the old folder
    FS:directoryRemove(oldName)
    return true
  end
end

local function renameProfile(profile, newName)
  if not isLegalDirectoryName(profile) or not FS:directoryExists(saveRoot .. profile)
  or FS:directoryExists(saveRoot .. newName) then
    return false
  end

  if currentProfile == profile then
    if not career_career.isActive() then
      setProfile(nil)
      return renameFolder(saveRoot .. profile, saveRoot .. newName)
    end
  else
    return renameFolder(saveRoot .. profile, saveRoot .. newName)
  end
end

local function getCurrentProfile()
  return currentProfile, currentSavePath
end

local function getCurrentDisplayName()
  return currentDisplayName
end

local syncSaveExtensionsDone
local asyncSaveExtensions = {}
local infoData
local saveDate
local oldestSave
local pendingSaveSuccessSound = false

local function saveFailed()
  infoData = nil
end

local function jsonWriteFileSafe(filename, obj, pretty, numberPrecision, tempFileName)
  tempFileName = tempFileName or filename..".tmp"
  if jsonWriteFile(tempFileName, obj, pretty, numberPrecision) then
    if FS:renameFile(tempFileName, filename) == 0 then
      return true
    else
      log("E", "save", "failed to copy temporary json!")
    end
  else
    log("E", "save", "failed to write json!")
  end
  saveFailed()
  return false
end

local function saveCompleted()
  local playSuccessSound = pendingSaveSuccessSound
  pendingSaveSuccessSound = false
  if infoData then
    infoData.corrupted = nil
    infoData.date = saveDate
    if jsonWriteFileSafe(oldestSave .. "/info.json", infoData, true) then
      guihooks.trigger("toastrMsg", {type="success", title=_tr("ui.career.save.toast.success.title"), msg=""})
      log("I", "Saved to " .. oldestSave)
      currentSavePath = oldestSave -- update the currentSavePath
      if playSuccessSound then
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Drift_Combo_5x')
      end
      extensions.hook("onSaveFinished")
      return
    end
  end

  guihooks.trigger("toastrMsg", {type="error", title=_tr("ui.career.save.toast.failed.title"), msg=_tr("ui.career.save.toast.failed.msg")})
  log("E", "Saving to " .. oldestSave ..  " failed!")
end

local function registerAsyncSaveExtension(extName)
  asyncSaveExtensions[extName] = true
end

local function asyncSaveExtensionFinished(extName)
  asyncSaveExtensions[extName] = nil
  if syncSaveExtensionsDone and tableIsEmpty(asyncSaveExtensions) then
    saveCompleted()
  end
end

local function saveCurrent(vehiclesThumbnailUpdate, playSuccessSound, saveName)
  if not currentProfile then return end
  pendingSaveSuccessSound = playSuccessSound and true or false
  if saveName then
    -- save into a specific named folder instead of rotating autosave folders
    oldestSave = saveRoot .. currentProfile .. "/" .. saveName
  else
    oldestSave = getOldestAutosave(saveRoot .. currentProfile) -- get oldest autosave to overwrite
  end
  saveDate = os.date("!%Y-%m-%dT%H:%M:%SZ") -- UTC time

  infoData = {}
  infoData.version = saveSystemVersion
  infoData.date = "0"
  creationDateOfCurrentProfile = creationDateOfCurrentProfile or saveDate
  infoData.creationDate = creationDateOfCurrentProfile
  infoData.displayName = currentDisplayName
  infoData.corrupted = true

  if not jsonWriteFileSafe(oldestSave .. "/info.json", infoData, true) then
    saveFailed()
    saveCompleted()
    return
  end

  syncSaveExtensionsDone = false
  extensions.hook("onSaveCurrentProfileAsyncStart")
  extensions.hook("onSaveCurrentProfile", oldestSave, vehiclesThumbnailUpdate)
  syncSaveExtensionsDone = true
  if tableIsEmpty(asyncSaveExtensions) then
    saveCompleted()
  end
end

local function getAllProfiles()
  local res = {}
  local folders = FS:directoryList(saveRoot, false, true)
  for i = 1, tableSize(folders) do
    local dir, filename, ext = path.split(folders[i])
    table.insert(res, filename)
  end
  return res
end

local function onExtensionLoaded()
end

local function getSaveRootDirectory()
  return saveRoot
end

local function onSerialize()
  local data = {}
  data.currentProfile = currentProfile
  data.currentSavePath = currentSavePath
  data.currentDisplayName = currentDisplayName
  data.creationDateOfCurrentProfile = creationDateOfCurrentProfile
  return data
end

local function onDeserialized(v)
  currentProfile = v.currentProfile
  currentSavePath = v.currentSavePath
  currentDisplayName = v.currentDisplayName
  creationDateOfCurrentProfile = v.creationDateOfCurrentProfile
end

local function getSaveSystemVersion()
  return saveSystemVersion
end

local function getBackwardsCompVersion()
  return backwardsCompVersion
end

M.setProfile = setProfile
M.removeProfile = removeProfile
M.removeSaveFolder = removeSaveFolder
M.renameProfile = renameProfile
M.getCurrentProfile = getCurrentProfile
M.getCurrentDisplayName = getCurrentDisplayName
M.saveCurrent = saveCurrent
M.getAllProfiles = getAllProfiles
M.getSaveRootDirectory = getSaveRootDirectory
M.getNewestSave = getNewestSave
M.getAllSaveFolders = getAllSaveFolders
M.getSaveSystemVersion = getSaveSystemVersion
M.getBackwardsCompVersion = getBackwardsCompVersion
M.saveFailed = saveFailed
M.registerAsyncSaveExtension = registerAsyncSaveExtension
M.asyncSaveExtensionFinished = asyncSaveExtensionFinished
M.jsonWriteFileSafe = jsonWriteFileSafe

M.onExtensionLoaded = onExtensionLoaded
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M