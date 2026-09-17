-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = "ui_photomode_postfx"
local RESTORE_STATE_FILE = "settings/photomodePostFxRestoreState.json"
local DEFAULT_POSTFX_PRESET_FILE = "lua/ge/client/postFx/presets/defaultpostfxpreset.postfx"
local RESTORE_STATE_VERSION = 1
local PHOTOMODE_AUTOFOCUS_FOCUS_RANGE = 0

local BOOLEAN_FIELDS = {
  "dofEnabled",
  "dofAutofocus",
  "ssaoEnabled",
  "motionBlurEnabled",
  "reflectionsEnabled",
}

local NUMBER_FIELDS = {
  "dofMaxBlurNear",
  "dofMaxBlurFar",
  "dofFocusRange",
  "motionBlurStrength",
  "reflectionDetail",
  "reflectionDistance",
  "reflectionTextureSize",
}

local function normalizeBoolean(value, fallback)
  if value == nil then
    return fallback
  end
  if value == true or value == 1 or value == "1" or value == "true" then
    return true
  end
  if value == false or value == 0 or value == "0" or value == "false" then
    return false
  end
  return fallback
end

local function normalizeNumber(value)
  local number = tonumber(value)
  if number == nil then
    return nil
  end
  return number
end

local function getPackagedDofDefaults()
  local preset = jsonReadFile(DEFAULT_POSTFX_PRESET_FILE) or {}
  local dof = type(preset.DOF) == "table" and preset.DOF or {}
  return {
    dofAutofocus = normalizeBoolean(dof.EnableAutoFocus, false),
    dofFocusRange = normalizeNumber(dof.FocusDistance) or 250,
  }
end

local function hasAnyEffectsField(effectsState)
  if type(effectsState) ~= "table" then
    return false
  end
  for _, fieldName in ipairs(BOOLEAN_FIELDS) do
    if effectsState[fieldName] ~= nil then
      return true
    end
  end
  for _, fieldName in ipairs(NUMBER_FIELDS) do
    if effectsState[fieldName] ~= nil then
      return true
    end
  end
  return false
end

local function normalizeEffectsState(effectsState)
  if type(effectsState) ~= "table" then
    return nil
  end

  local normalizedState = {}
  for _, fieldName in ipairs(BOOLEAN_FIELDS) do
    if effectsState[fieldName] ~= nil then
      normalizedState[fieldName] = normalizeBoolean(effectsState[fieldName], false)
    end
  end
  for _, fieldName in ipairs(NUMBER_FIELDS) do
    local normalizedNumber = normalizeNumber(effectsState[fieldName])
    if normalizedNumber ~= nil then
      normalizedState[fieldName] = normalizedNumber
    end
  end

  if normalizedState.dofAutofocus == nil and (
    normalizedState.dofEnabled ~= nil
      or normalizedState.dofMaxBlurNear ~= nil
      or normalizedState.dofMaxBlurFar ~= nil
      or normalizedState.dofFocusRange ~= nil
  ) then
    normalizedState.dofAutofocus = false
  end

  if normalizedState.dofAutofocus ~= true
    and normalizedState.dofFocusRange == PHOTOMODE_AUTOFOCUS_FOCUS_RANGE
  then
    normalizedState.dofFocusRange = getPackagedDofDefaults().dofFocusRange
  end

  return hasAnyEffectsField(normalizedState) and normalizedState or nil
end

local function readPersistedPayload()
  local payload = jsonReadFile(RESTORE_STATE_FILE)
  if type(payload) ~= "table" then
    return nil
  end
  if payload.version == RESTORE_STATE_VERSION and type(payload.effects) == "table" then
    return payload.effects
  end
  return payload
end

local function writePersistedPayload(effectsState)
  local payload = {
    version = RESTORE_STATE_VERSION,
    effects = effectsState,
  }
  local ok = jsonWriteFile(RESTORE_STATE_FILE, payload, true, nil, true) == true
  if not ok then
    log("E", logTag, "failed to write " .. RESTORE_STATE_FILE)
  end
  return ok
end

local function saveRestoreState(effectsState)
  local normalizedState = normalizeEffectsState(effectsState)
  if not normalizedState then
    return nil, false
  end
  return normalizedState, writePersistedPayload(normalizedState)
end

local function loadRestoreState()
  return normalizeEffectsState(readPersistedPayload())
end

M.RESTORE_STATE_FILE = RESTORE_STATE_FILE
M.saveRestoreState = saveRestoreState
M.loadRestoreState = loadRestoreState

return M
