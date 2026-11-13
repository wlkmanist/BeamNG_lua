-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = { "editor_api_dynamicDecals_textures" }

local api = extensions.editor_api_dynamicDecals_textures

-- maps dynamic decal texture sidecar tag ids to vue translation keys under ui.liveries.edit.decalCategories.*
local tagLabels = {
  digit = "ui.liveries.edit.decalCategories.digit",
  gradient = "ui.liveries.edit.decalCategories.gradient",
  letter = "ui.liveries.edit.decalCategories.letter",
  logo = "ui.liveries.edit.decalCategories.logo",
  noise = "ui.liveries.edit.decalCategories.noise",
  pattern = "ui.liveries.edit.decalCategories.pattern",
  shape = "ui.liveries.edit.decalCategories.shape",
  textureFill = "ui.liveries.edit.decalCategories.textureFill",
  ["Team Offroad"] = "ui.liveries.edit.decalCategories.teamOffroad",
}

local ALL_CATEGORY = "all"
local ALL_CATEGORY_LABEL = "ui.common.all"
local OTHERS_CATEGORY = "others"
local OTHERS_CATEGORY_LABEL = "ui.liveries.edit.decalCategories.others"

local CATEGORY_DATA_EVENT = "liveries_textureCategoryData"
local DATA_LOADED_EVENT = "liveries_textureSelectorDataLoaded"
local PROGRESS_STREAM = "liveries_textureLoadProgress"

-- catalog item picked in the selector, kept alive while navigating to the transform screen
local selectedCatalogItem = nil

-- the texture scan runs in its own job, see loadTextures()
local loadJob = nil
local loadProgress = { count = 0, total = 0, percent = -1, inProgress = false }

local function makeTextureItem(filePath)
  local _, fileName, _ = path.split(filePath)
  return {
    name = fileName,
    label = fileName,
    value = fileName,
    preview = filePath,
  }
end

local function sortByLabel(a, b)
  return string.lower(a.label) < string.lower(b.label)
end

local function sortByValue(a, b)
  return string.lower(a.value) < string.lower(b.value)
end

-- textures without a sidecar tag end up in the "others" category
local function collectTaggedPaths()
  local taggedPaths = {}
  for _, filePaths in pairs(api.getTagsWithRefs() or {}) do
    for _, filePath in ipairs(filePaths) do
      taggedPaths[filePath] = true
    end
  end
  return taggedPaths
end

local function makeGroup(value, label, items)
  table.sort(items, sortByLabel)
  return { value = value, label = label, items = items }
end

local function buildTagGroup(tag, filePaths)
  local items = {}
  for _, filePath in ipairs(filePaths) do
    table.insert(items, makeTextureItem(filePath))
  end
  return makeGroup(tag, M.getTagLabel(tag), items)
end

local function buildUntaggedGroup()
  local taggedPaths = collectTaggedPaths()
  local items = {}
  for _, filePath in ipairs(api.getTextureFiles() or {}) do
    if not taggedPaths[filePath] then
      table.insert(items, makeTextureItem(filePath))
    end
  end
  return makeGroup(OTHERS_CATEGORY, OTHERS_CATEGORY_LABEL, items)
end

local function appendGroup(groups, group)
  if #group.items > 0 then
    table.insert(groups, group)
  end
end

M.getTagLabel = function(tag)
  return tagLabels[tag]
end

local function reportProgress()
  guihooks.triggerStream(PROGRESS_STREAM, loadProgress)
end

-- percent stays at -1 until the file count is known, which marks it as indeterminate
local function startProgress()
  loadProgress.count = 0
  loadProgress.total = 0
  loadProgress.percent = -1
  loadProgress.inProgress = true
  reportProgress()
end

local function stopProgress()
  loadProgress.inProgress = false
  reportProgress()
end

local function setProgressTotal(total)
  loadProgress.total = total
  loadProgress.percent = total > 0 and 0 or -1
  reportProgress()
end

local function addProgressCount(count)
  loadProgress.count = loadProgress.count + count
  if loadProgress.total <= 0 then return end

  -- a stream update per texture file would be thousands of json encodes, so only push
  -- one once the displayed percent actually moves
  local percent = math.floor(loadProgress.count / loadProgress.total * 100)
  if percent == loadProgress.percent then return end

  loadProgress.percent = percent
  reportProgress()
end

M.loadTextures = function()
  if loadJob and loadJob.running then
    reportProgress()
    return "alreadyLoading"
  end

  if not api then
    log("E", "liveries", "dynamic decals textures api not available")
    stopProgress()
    return "unavailable"
  end

  startProgress()

  loadJob = core_jobsystem.create(function(job)
    if not api.getTextureFiles() then
      api.setupAsync({ yield = job.yield, onTotal = setProgressTotal, onProgress = addProgressCount })
    end

    stopProgress()
    guihooks.trigger(DATA_LOADED_EVENT, M.getSelectorMetadata())
  end, 1/30)

  return "startLoading"
end

M.getSelectorMetadata = function()
  local metadata = { defaultCategory = ALL_CATEGORY, categories = {} }

  if not api then return metadata end

  local categories = {}
  for tag in pairs(api.getTagsWithRefs() or {}) do
    table.insert(categories, { value = tag, label = M.getTagLabel(tag) })
  end

  local taggedPaths = collectTaggedPaths()
  for _, filePath in ipairs(api.getTextureFiles() or {}) do
    if not taggedPaths[filePath] then
      table.insert(categories, { value = OTHERS_CATEGORY, label = OTHERS_CATEGORY_LABEL })
      break
    end
  end

  table.sort(categories, sortByValue)
  table.insert(categories, 1, { value = ALL_CATEGORY, label = ALL_CATEGORY_LABEL })

  metadata.categories = categories
  return metadata
end

M.requestSelectorCategory = function(category, requestId)
  category = type(category) == "string" and category or ALL_CATEGORY
  requestId = tonumber(requestId) or 0

  local groups = {}

  if api then
    if category == ALL_CATEGORY then
      -- a texture carrying several tags shows up in each of their groups, on purpose
      for tag, filePaths in pairs(api.getTagsWithRefs() or {}) do
        appendGroup(groups, buildTagGroup(tag, filePaths))
      end
      appendGroup(groups, buildUntaggedGroup())
      table.sort(groups, sortByValue)
    elseif category == OTHERS_CATEGORY then
      appendGroup(groups, buildUntaggedGroup())
    else
      local filePaths = (api.getTagsWithRefs() or {})[category]
      if filePaths then
        appendGroup(groups, buildTagGroup(category, filePaths))
      else
        log("W", "liveries", "ui_liveries_textures.requestSelectorCategory: unknown category " .. tostring(category))
      end
    end
  end

  guihooks.trigger(CATEGORY_DATA_EVENT, { requestId = requestId, category = category, groups = groups })
end

M.setSelectorItem = function(item)
  selectedCatalogItem = item
end

M.getSelectedItem = function()
  return selectedCatalogItem
end

M.clearSelectedItem = function()
  selectedCatalogItem = nil
end

return M
