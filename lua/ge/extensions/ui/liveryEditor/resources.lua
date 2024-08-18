local M = {}

M.dependencies = {"editor_api_dynamicDecals_textures"}

local brushes = {}
local fonts = {}

-- Category properties
-- id
-- name
-- preview

-- Texture properties
-- filename
-- preview
-- type sdf or normal
-- category
M.textures = {}

local function parseTextures(taggedTextures)
  M.textures = {}
  for tag, taggedTextures in pairs(taggedTextures) do
    local categorizedTextures = {
      value = tag,
      label = tag,
      items = {}
    }

    for key, file in pairs(taggedTextures) do
      local _, filename, _ = path.split(file)
      table.insert(categorizedTextures.items, {
        name = filename,
        label = filename,
        value = filename,
        preview = file
      })
    end

    table.insert(M.textures, categorizedTextures)
  end
end

M.setup = function()
  extensions.editor_api_dynamicDecals_textures.setup()
  local taggedTextures = extensions.editor_api_dynamicDecals_textures.getTagsWithRefs()
  parseTextures(taggedTextures)
end

M.getTextureCategories = function()
  local tags = extensions.editor_api_dynamicDecals_textures.getTagsWithRefs()
  local categories = {}

  for key, value in pairs(tags) do
    table.insert(categories, {
      label = key,
      value = key,
      preview = value[1]
    })
  end

  table.sort(categories, function(a, b)
    return a.label:lower() < b.label:lower()
  end)

  return categories
end

M.getTexturesByCategory = function(category)
  for key, textureCategory in ipairs(M.textures) do
    if textureCategory.value == category then
      return textureCategory
    end
  end
end

M.getDecalTextures = function()
  return M.textures
end

M.dynamicDecals_onTextureFileAdded = function(textureFilePath)
end

M.dynamicDecals_onTextureFileDeleted = function(textureFilePath)
end

return M
