-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {
  "editor_api_dynamicDecals",
  "editor_dynamicDecals_browser",
  "editor_dynamicDecals_layerTypes_decal",
  "editor_dynamicDecals_docs",
}
local logTag = "editor_api_dynamicDecals_textures"

local texturesDirectoryPath = "/art/dynamicDecals/textures"
local textureFiles = nil
local tags = nil
local tagsWithRefs = nil
local missingSidecarFiles = nil

local contextMenuTexturePath = ""

local sidecarExtension = ".dynDecalTexture.json"
local sidecarTemplate = {
  version = 1,
  path = "",
  type = 0, -- 0: greyscale; 1: color; 2: sdf; 3: fillTexture
  tags = {},
  vehicle = ""
}

local function dumpTags()
  -- print("tags")
  -- dump(tags)
  -- print("tagsWithRefs")
  -- dump(tagsWithRefs)

  -- for k, v in pairs(tagsWithRefs) do
  --   print(string.format("%s : %d", k, #v))
  -- end
end

local function removeTags(textureFilepath, tagsToRemove)
  for _, tag in ipairs(tagsToRemove) do
    if tagsWithRefs[tag] then
      for k, v in ipairs(tagsWithRefs[tag]) do
        if v == textureFilepath then
          table.remove(tagsWithRefs[tag], k)
          if #tagsWithRefs[tag] == 0 then
            tagsWithRefs[tag] = nil
            for kk, t in ipairs(tags) do
              if t == tag then
                table.remove(tags, kk)
              end
            end
          end
        end
      end
    end
  end
end

local function textureFilesSortFn(a, b)
  local _, fileNameA, _ = path.split(a)
  local _, fileNameB, _ = path.split(b)
  return string.lower(fileNameA) < string.lower(fileNameB)
end

local function sidecarFileExists(textureFilepath)
  return FS:fileExists(textureFilepath .. sidecarExtension)
end

local function readSidecarFile(textureFilepath)
  if sidecarFileExists(textureFilepath) then
    return jsonReadFile(textureFilepath .. sidecarExtension)
  else
    return nil
  end
end

local function updateSidecarFile(textureFilepath, data)
  local sidecarFilePath = textureFilepath .. sidecarExtension

  -- remove tags and refs
  if FS:fileExists(sidecarFilePath) then
    local oldData = jsonReadFile(sidecarFilePath)
    if oldData.tags then
      removeTags(textureFilepath, oldData.tags)
    end
  end

  jsonWriteFile(sidecarFilePath, data)

  -- add new tags
  if data.tags then
    for _, tag in ipairs(data.tags) do
      if not tagsWithRefs[tag] then
        tagsWithRefs[tag] = {}
        table.insert(tags, tag)
      end
      table.insert(tagsWithRefs[tag], textureFilepath)
    end
  end

  dumpTags()
end

local function reloadTextureFiles()
  textureFiles = FS:findFiles(texturesDirectoryPath, "*.jpg\t*.png", -1, true, false)
  tags = {}
  tagsWithRefs = {}
  missingSidecarFiles = {}

  for _, filepath in ipairs(textureFiles) do
    local dirName, fileName, extension = path.split(filepath)
    local textureFilePath = dirName .. fileName
    if sidecarFileExists(textureFilePath) then
      local data = readSidecarFile(textureFilePath)
      if data.tags then
        for _, tag in ipairs(data.tags) do
          if not tagsWithRefs[tag] then
            tagsWithRefs[tag] = {}
            table.insert(tags, tag)
          end
          table.insert(tagsWithRefs[tag], filepath)
        end
      end
    else
      table.insert(missingSidecarFiles, filepath)
      local data = shallowcopy(sidecarTemplate)
      data.path = dirName .. fileName
      updateSidecarFile(textureFilePath, data)
    end
  end

  table.sort(textureFiles, textureFilesSortFn)

  -- Sort by usage count
  table.sort(tags, function(a, b)
    return #tagsWithRefs[a] > #tagsWithRefs[b]
  end)

  dumpTags()
end

local function textureExists(filepath)
  for k, path in ipairs(textureFiles) do
    if path == filepath then
      return true, k
    end
  end
  return false
end

local function addTexture(filepath)
  table.insert(textureFiles, filepath)
  table.sort(textureFiles, textureFilesSortFn)

  local dirName, fileName, extension = path.split(filepath)
  local sidecarFilePath = dirName .. fileName .. sidecarExtension
  missingSidecarFiles = {}
  if not FS:fileExists(sidecarFilePath) then
    table.insert(missingSidecarFiles, filepath)
    local data = shallowcopy(sidecarTemplate)
    data.path = dirName .. fileName
    jsonWriteFile(sidecarFilePath, data)
  end

  extensions.hook("dynamicDecals_onTextureFileAdded", filepath)
end

local function setup()
  reloadTextureFiles()
  FS:directoryCreate(texturesDirectoryPath)
end

local function onFileChanged(filepath, type)
  local dir, filename, ext = path.split(filepath)
  if dir == (texturesDirectoryPath .. "/") and ext ~= "json" then
    if type == 'added' or type == 'modified' then
      if not textureExists(filepath) then
        addTexture(filepath)
      end
      return
    end
    if type == 'deleted' then
      local res, index = textureExists(filepath)
      if res then
        local sidecarFilePath = filepath .. sidecarExtension

        -- remove tags and refs
        if FS:fileExists(sidecarFilePath) then
          local oldData = jsonReadFile(sidecarFilePath)
          if oldData.tags then
            removeTags(filepath, oldData.tags)
          end
        end

        dumpTags()

        table.remove(textureFiles, index)
        extensions.hook("dynamicDecals_onTextureFileDeleted", filepath)
      end
    end
  end
end

-- public interface
M.setup = setup
M.reloadTextureFiles = reloadTextureFiles
M.getTextureFiles = function() return textureFiles end
M.getSidecarTemplate = function() return sidecarTemplate end
M.getAndFlushMissingSidecarFiles = function()
  local res = shallowcopy(missingSidecarFiles)
  missingSidecarFiles = nil
  return res
end
M.sidecarFileExists = sidecarFileExists
M.readSidecarFile = readSidecarFile
M.updateSidecarFile = updateSidecarFile
M.getTags = function() return tags end
M.getTagsWithRefs = function() return tagsWithRefs end
M.getTexturesDirectoryPath = function()
  return texturesDirectoryPath .. '/'
end

M.onFileChanged = onFileChanged

return M