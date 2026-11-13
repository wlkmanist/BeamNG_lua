-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function safePathPart(value)
  value = tostring(value or ""):gsub("[^%w_.-]", "_")
  return value ~= "" and value or "unknown"
end

local function getFinalOutputPath(item, captureMode)
  local outputFolder = string.format("vehicles/%s/", safePathPart(item.modelKey))
  local name = captureMode == "defaults" and item.isDefaultConfig and "default" or safePathPart(item.configName)
  return outputFolder .. name .. ".jpg", outputFolder
end

-- the game picks up either a .png or a .jpg thumbnail, from the game or the user folder
local function hasThumbnail(item)
  local path = getFinalOutputPath(item, "all")
  return FS:fileExists(path) or FS:fileExists((path:gsub("%.jpg$", ".png")))
end

local function makeOutputPaths(item, captureMode)
  local finalPath, outputFolder = getFinalOutputPath(item, captureMode)
  FS:directoryCreate(outputFolder, true)
  local paths = {
    outputFolder = outputFolder,
    final = finalPath
  }
  local defaultOutputPath = outputFolder .. "default.jpg"
  if captureMode == "all" and item.isDefaultConfig and finalPath ~= defaultOutputPath then
    paths.defaultFinal = defaultOutputPath
  end
  return paths
end

M.safePathPart = safePathPart
M.getFinalOutputPath = getFinalOutputPath
M.hasThumbnail = hasThumbnail
M.makeOutputPaths = makeOutputPaths

return M
