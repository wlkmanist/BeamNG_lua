-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "ui_photomode_camera",
  "ui_photomode_scene",
  "ui_photomode_effects",
}

local STORE_VERSION = 1
local PRESET_VERSION = 1
local PRESET_DIR = "settings/photomode/presets"
local DEFAULT_PRESET_ID = "__defaults"
local discoveredTemporaryPresets = {}
local hiddenTemporaryPresetIds = {}
local sessionDefaultPresetData = {}
local sessionDefaultsCaptured = false

local PRESET_TYPES = {
  camera = {
    filename = "camera.json",
    moduleName = "ui_photomode_camera",
  },
  scene = {
    filename = "scene.json",
    moduleName = "ui_photomode_scene",
  },
  effects = {
    filename = "effects.json",
    moduleName = "ui_photomode_effects",
  },
}

local function getPresetTypeData(presetType)
  return PRESET_TYPES[tostring(presetType or "")]
end

local function getPresetModule(presetType)
  local presetTypeData = getPresetTypeData(presetType)
  return presetTypeData and _G[presetTypeData.moduleName] or nil
end

local function getStorePath(presetType)
  local presetTypeData = getPresetTypeData(presetType)
  return presetTypeData and string.format("%s/%s", PRESET_DIR, presetTypeData.filename) or nil
end

local function buildEmptyStore()
  return {
    version = STORE_VERSION,
    presets = {},
  }
end

function M.resetTemporaryPresets()
  discoveredTemporaryPresets = {}
  hiddenTemporaryPresetIds = {}
  sessionDefaultPresetData = {}
  sessionDefaultsCaptured = false
end

local function readStore(presetType)
  local storePath = getStorePath(presetType)
  if not storePath then
    return nil, "preset_type_invalid"
  end

  local store = jsonReadFile(storePath)
  if type(store) ~= "table" then
    return buildEmptyStore()
  end

  if type(store.presets) ~= "table" then
    store.presets = {}
  end
  store.version = tonumber(store.version) or STORE_VERSION

  return store
end

local function writeStore(presetType, store)
  local storePath = getStorePath(presetType)
  if not storePath then
    return false, "preset_type_invalid"
  end

  if FS and type(FS.directoryCreate) == "function" and not FS:directoryExists(PRESET_DIR) then
    FS:directoryCreate(PRESET_DIR, true)
  end

  local ok = jsonWriteFile(storePath, store, true, nil, true) == true
  return ok, ok and nil or "preset_write_failed"
end

local function makePresetId()
  if Engine and type(Engine.generateUUID) == "function" then
    return Engine.generateUUID()
  end
  return string.format("%d_%d", os.time() or 0, math.random(1000000))
end

local function normalizePresetName(name)
  name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return name ~= "" and name or "Untitled preset"
end

local function findPreset(store, presetId)
  presetId = tostring(presetId or "")
  for index, preset in ipairs(store.presets) do
    if tostring(preset.id or "") == presetId then
      return preset, index
    end
  end
  return nil, nil
end

local function captureDefaultPresetData(presetType)
  local presetModule = getPresetModule(presetType)
  if not presetModule or type(presetModule.captureDefaultPresetState) ~= "function" then
    return nil
  end

  return presetModule.captureDefaultPresetState()
end

function M.captureSessionDefaultPresets()
  sessionDefaultPresetData = {}
  sessionDefaultsCaptured = true
  for presetType in pairs(PRESET_TYPES) do
    local data = captureDefaultPresetData(presetType)
    if type(data) == "table" then
      sessionDefaultPresetData[presetType] = data
    end
  end
end

local function buildDefaultPreset(presetType)
  local data = sessionDefaultsCaptured
    and sessionDefaultPresetData[presetType]
    or captureDefaultPresetData(presetType)
  if type(data) ~= "table" then
    return nil
  end

  return {
    id = DEFAULT_PRESET_ID,
    type = presetType,
    version = PRESET_VERSION,
    name = "Defaults",
    temporary = true,
    data = data,
  }
end

local function isPresetAvailable(presetType, preset)
  if presetType ~= "camera" then
    return true
  end

  local data = type(preset) == "table" and type(preset.data) == "table" and preset.data or {}
  if data.cameraPresetType ~= "scene" then
    return true
  end

  local levelId = tostring(data.levelId or "")
  local currentLevelId = type(getCurrentLevelIdentifier) == "function" and tostring(getCurrentLevelIdentifier() or "") or ""
  return levelId == "" or levelId == currentLevelId
end

local function buildPresetList(presetType, store)
  local presets = {}
  local defaultPreset = buildDefaultPreset(presetType)
  if defaultPreset and hiddenTemporaryPresetIds[defaultPreset.id] ~= true then
    presets[#presets + 1] = defaultPreset
  end

  if discoveredTemporaryPresets[presetType] == true then
    local presetModule = getPresetModule(presetType)
    if presetModule and type(presetModule.getTemporaryPresetList) == "function" then
      for _, preset in ipairs(presetModule.getTemporaryPresetList()) do
        if hiddenTemporaryPresetIds[tostring(preset.id or "")] ~= true then
          presets[#presets + 1] = preset
        end
      end
    end
  end

  for _, preset in ipairs(store.presets or {}) do
    if isPresetAvailable(presetType, preset) then
      presets[#presets + 1] = preset
    end
  end

  return presets
end

local function buildPreset(presetType, name, data, origin)
  return {
    id = makePresetId(),
    type = presetType,
    version = PRESET_VERSION,
    name = normalizePresetName(name),
    createdAt = os.time(),
    updatedAt = os.time(),
    origin = origin,
    data = type(data) == "table" and data or {},
  }
end

function M.listPresets(presetType)
  local store, reason = readStore(presetType)
  if not store then
    return {
      ok = false,
      reason = reason,
      presets = {},
    }
  end

  return {
    presets = buildPresetList(presetType, store),
  }
end

function M.discoverTemporaryPresets(presetType)
  local store, reason = readStore(presetType)
  if not store then
    return {
      ok = false,
      reason = reason,
      presets = {},
    }
  end

  discoveredTemporaryPresets[presetType] = true

  return {
    presets = buildPresetList(presetType, store),
  }
end

function M.saveCurrentPreset(presetType, name, options)
  local presetModule = getPresetModule(presetType)
  if not presetModule then
    return { ok = false, reason = "preset_type_invalid" }
  end

  local store, reason = readStore(presetType)
  if not store then
    return { ok = false, reason = reason }
  end

  local presetData = presetModule.capturePresetState(type(options) == "table" and options or {})
  if type(presetData) ~= "table" then
    return { ok = false, reason = "preset_capture_failed" }
  end

  local preset = buildPreset(presetType, name, presetData)
  table.insert(store.presets, 1, preset)

  local ok, writeReason = writeStore(presetType, store)
  if not ok then
    return { ok = false, reason = writeReason }
  end

  return {
    preset = preset,
    presets = buildPresetList(presetType, store),
  }
end

function M.applyPreset(presetType, presetId, options)
  local presetModule = getPresetModule(presetType)
  if not presetModule then
    return { ok = false, reason = "preset_type_invalid" }
  end

  local presetIdString = tostring(presetId or "")
  local preset = presetIdString == DEFAULT_PRESET_ID and buildDefaultPreset(presetType) or nil
  local store = nil
  if not preset then
    local presetModuleForTemporary = getPresetModule(presetType)
    if presetModuleForTemporary and type(presetModuleForTemporary.getTemporaryPresetList) == "function" then
      for _, temporaryPreset in ipairs(presetModuleForTemporary.getTemporaryPresetList()) do
        if tostring(temporaryPreset.id or "") == presetIdString then
          preset = temporaryPreset
          break
        end
      end
    end
  end

  if not preset then
    local reason
    store, reason = readStore(presetType)
    if not store then
      return { ok = false, reason = reason }
    end
    preset = findPreset(store, presetId)
  end

  if not preset or not isPresetAvailable(presetType, preset) then
    return { ok = false, reason = "preset_not_found" }
  end

  local applyResult = presetModule.applyPresetState(preset.data, type(options) == "table" and options or {})
  if applyResult and applyResult.ok == false then
    return applyResult
  end

  return {
    preset = preset,
    state = applyResult and applyResult.state or nil,
  }
end

function M.deletePreset(presetType, presetId)
  local presetIdString = tostring(presetId or "")
  if presetIdString == DEFAULT_PRESET_ID then
    local store, reason = readStore(presetType)
    if not store then
      return { ok = false, reason = reason }
    end

    hiddenTemporaryPresetIds[presetIdString] = true
    return {
      presets = buildPresetList(presetType, store),
    }
  end

  local presetModule = getPresetModule(presetType)
  if presetModule and type(presetModule.getTemporaryPresetList) == "function" then
    for _, temporaryPreset in ipairs(presetModule.getTemporaryPresetList()) do
      if tostring(temporaryPreset.id or "") == presetIdString then
        local store, reason = readStore(presetType)
        if not store then
          return { ok = false, reason = reason }
        end

        hiddenTemporaryPresetIds[presetIdString] = true
        return {
          presets = buildPresetList(presetType, store),
        }
      end
    end
  end

  local store, reason = readStore(presetType)
  if not store then
    return { ok = false, reason = reason }
  end

  local _, index = findPreset(store, presetId)
  if not index then
    return { ok = false, reason = "preset_not_found" }
  end

  table.remove(store.presets, index)

  local ok, writeReason = writeStore(presetType, store)
  if not ok then
    return { ok = false, reason = writeReason }
  end

  return {
    presets = buildPresetList(presetType, store),
  }
end

function M.renamePreset(presetType, presetId, name)
  local store, reason = readStore(presetType)
  if not store then
    return { ok = false, reason = reason }
  end

  local preset = findPreset(store, presetId)
  if not preset then
    return { ok = false, reason = "preset_not_found" }
  end

  preset.name = normalizePresetName(name)
  preset.updatedAt = os.time()

  local ok, writeReason = writeStore(presetType, store)
  if not ok then
    return { ok = false, reason = writeReason }
  end

  return {
    preset = preset,
    presets = buildPresetList(presetType, store),
  }
end

function M.applyPresetPayload(presetType, payload)
  local presetModule = getPresetModule(presetType)
  if not presetModule then
    return { ok = false, reason = "preset_type_invalid" }
  end

  local presetData = type(payload) == "table" and (payload.data or payload) or {}
  local applyResult = presetModule.applyPresetState(presetData)
  if applyResult and applyResult.ok == false then
    return applyResult
  end

  return {
    state = applyResult and applyResult.state or nil,
  }
end

function M.savePresetPayload(presetType, name, payload, origin)
  local store, reason = readStore(presetType)
  if not store then
    return { ok = false, reason = reason }
  end

  local presetData = type(payload) == "table" and (payload.data or payload) or {}
  local preset = buildPreset(presetType, name, presetData, origin)
  table.insert(store.presets, 1, preset)

  local ok, writeReason = writeStore(presetType, store)
  if not ok then
    return { ok = false, reason = writeReason }
  end

  return {
    preset = preset,
    presets = buildPresetList(presetType, store),
  }
end

function M.savePresetBundle(bundle, namePrefix, origin)
  if type(bundle) ~= "table" then
    return { ok = false, reason = "preset_bundle_invalid" }
  end

  local imported = {}
  local prefix = normalizePresetName(namePrefix)
  local saveOrder = { "camera", "scene", "effects" }

  for _, presetType in ipairs(saveOrder) do
    local payload = bundle[presetType]
    if type(payload) == "table" then
      local name = string.format("%s %s", prefix, presetType)
      local result = M.savePresetPayload(presetType, name, payload, origin)
      if result and result.ok == false then
        return result
      end
      imported[presetType] = result and result.preset or nil
    end
  end

  return {
    imported = imported,
  }
end

function M.getScreenshotPresetBundle()
  return {
    schemaVersion = 1,
    camera = {
      version = PRESET_VERSION,
      type = "camera",
      data = ui_photomode_camera.capturePresetState(),
    },
    scene = {
      version = PRESET_VERSION,
      type = "scene",
      data = ui_photomode_scene.capturePresetState(),
    },
    effects = {
      version = PRESET_VERSION,
      type = "effects",
      data = ui_photomode_effects.capturePresetState(),
    },
  }
end

return M
