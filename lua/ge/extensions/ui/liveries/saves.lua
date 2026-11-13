-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

local SAVE_DIR = "settings/dynamicDecals/"
local SAVE_EXTENSION = ".dynDecals.json"
local FILENAME_PATTERN = "^[a-zA-Z0-9_-]+$"

-- name of the save currently loaded/last saved in this editing session; nil for an unsaved new livery
local currentSaveName = nil
-- skin name staged by a save with Apply Skin checked, consumed once when the editor exits
local stagedApplySkinName = nil

local function getFilePath(filename)
  return SAVE_DIR .. filename .. SAVE_EXTENSION
end

local function getFilename(file)
  local _, fn = path.split(file)
  return fn:sub(1, #fn - #SAVE_EXTENSION)
end

local function isValidFilename(filename)
  if type(filename) ~= "string" or not string.match(filename, FILENAME_PATTERN) then
    log("W", "", "Invalid livery save filename: " .. dumps(filename))
    return false
  end
  return true
end

M.exists = function(filename)
  return FS:fileExists(getFilePath(filename))
end

M.getAll = function()
  local saves = {}
  local files = FS:findFiles(SAVE_DIR, "*" .. SAVE_EXTENSION, -1, false, false)
  for i, file in ipairs(files) do
    local stat = FS:stat(file)
    saves[i] = {
      name = getFilename(file),
      location = file,
      created = stat.created,
      modified = stat.modtime,
      fileSize = stat.filesize,
    }
  end
  return saves
end

M.create = function(filename)
  if not isValidFilename(filename) then
    return false
  end

  local filePath = getFilePath(filename)
  extensions.editor_api_dynamicDecals.saveLayerStackToFile(filePath)
  return filePath
end

M.rename = function(filename, newFilename)
  if not isValidFilename(newFilename) then
    return false
  end

  local filePath = getFilePath(filename)
  if not FS:fileExists(filePath) then
    log("W", "", "Livery save file not found: " .. dumps(filename))
    return false
  end

  if newFilename ~= filename and M.exists(newFilename) then
    log("W", "", "Livery save name already in use: " .. dumps(newFilename))
    return false
  end

  if FS:renameFile(filePath, getFilePath(newFilename)) ~= 0 then
    log("W", "", "Unable to rename livery save file " .. filename .. " to " .. newFilename)
    return false
  end

  -- keep the session's current-save identity pointed at the renamed file
  if currentSaveName == filename then
    currentSaveName = newFilename
  end
  return true
end

M.delete = function(filename)
  local filePath = getFilePath(filename)
  if not FS:fileExists(filePath) then
    log("W", "", "Livery save file not found: " .. dumps(filename))
    return false
  end

  FS:removeFile(filePath)

  -- the deleted file can no longer be overwritten as "the current save", nor should a
  -- previously staged skin from it still be applied on exit
  if currentSaveName == filename then
    M.clearCurrentSave()
  end
  return true
end

M.getFilename = getFilename

-- current-save / session state --------------------------------------------------------------

M.getCurrentSaveName = function()
  return currentSaveName
end

M.clearCurrentSave = function()
  currentSaveName = nil
  stagedApplySkinName = nil
end

M.consumeStagedApplySkin = function()
  local skinName = stagedApplySkinName
  stagedApplySkinName = nil
  return skinName
end

-- orchestrated save / load --------------------------------------------------------------------

local function getCurrentVehicleName()
  local vehicleObj = getPlayerVehicle(0)
  return vehicleObj and vehicleObj.JBeam
end

local function isUnrelatedDuplicate(filename)
  return filename ~= currentSaveName and M.exists(filename)
end

M.save = function(filename, applySkin)
  if not isValidFilename(filename) then
    return false
  end

  if isUnrelatedDuplicate(filename) then
    log("W", "", "Livery save name already in use: " .. dumps(filename))
    return false
  end

  local vehicleName = getCurrentVehicleName()
  if not vehicleName then
    log("E", "", "Unable to save livery, no player vehicle found")
    return false
  end

  local filePath = getFilePath(filename)
  extensions.editor_api_dynamicDecals.saveLayerStackToFile(filePath)
  extensions.editor_api_dynamicDecals.exportSkin(vehicleName, filename)

  currentSaveName = filename
  stagedApplySkinName = applySkin and filename or nil

  return filePath
end

M.load = function(filename)
  if not isValidFilename(filename) then
    return false
  end

  local filePath = getFilePath(filename)
  if not FS:fileExists(filePath) then
    log("W", "", "Livery save file not found: " .. dumps(filename))
    return false
  end

  local ok, result = pcall(extensions.editor_api_dynamicDecals.loadLayerStackFromFile, filePath)
  if not ok or not result then
    log("E", "", "Unable to load livery save file " .. dumps(filename) .. ": " .. dumps(result))
    return false
  end

  currentSaveName = filename
  stagedApplySkinName = nil
  return true
end

return M
