-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = { "ui_photomode_shared", "ui_photomode_postFxPersistence", "ui_photomode_flash", "core_settings_graphic" }

local logTag = "ui_photomode_effects"

local EFFECTS_LIMITS = {
  dofBlurNearMin = 0,
  dofBlurNearMax = 1,
  dofBlurFarMin = 0,
  dofBlurFarMax = 1,
  dofFocusRangeMin = -100,
  dofFocusRangeMax = 250,
  dofApertureMin = 0.1,
  dofApertureMax = 100,
  dofFalloffSharpnessMin = 0.1,
  dofFalloffSharpnessMax = 100,
  motionBlurStrengthMin = 0,
  motionBlurStrengthMax = 2,
}

local DYN_QUALITY_MODES = { "Disabled", "Lowest", "Low", "Normal", "High", "Ultra" }
local SSR_QUALITY_MODES = { "Off", "Low", "Medium", "High" }


local function normalizeEffectsDofBlurNear(value)
  return ui_photomode_shared.clampNumber(
    value,
    EFFECTS_LIMITS.dofBlurNearMin,
    EFFECTS_LIMITS.dofBlurNearMax,
    EFFECTS_LIMITS.dofBlurNearMin
  )
end

local function normalizeEffectsDofBlurFar(value)
  return ui_photomode_shared.clampNumber(
    value,
    EFFECTS_LIMITS.dofBlurFarMin,
    EFFECTS_LIMITS.dofBlurFarMax,
    0.15
  )
end

local function normalizeEffectsDofFocusRange(value)
  return ui_photomode_shared.clampNumber(
    value,
    EFFECTS_LIMITS.dofFocusRangeMin,
    EFFECTS_LIMITS.dofFocusRangeMax,
    50
  )
end

local function normalizeEffectsMotionBlurStrength(value)
  return ui_photomode_shared.clampNumber(
    value,
    EFFECTS_LIMITS.motionBlurStrengthMin,
    EFFECTS_LIMITS.motionBlurStrengthMax,
    0.5
  )
end

local function normalizeDynQuality(value, fallback)
  if type(value) == "string" then
    for _, mode in ipairs(DYN_QUALITY_MODES) do
      if mode == value then
        return mode
      end
    end
  end
  return fallback
end

local function getGraphicQualityOption(settingName)
  if not core_settings_graphic or type(core_settings_graphic.getOptions) ~= "function" then
    return nil
  end
  return core_settings_graphic.getOptions(settingName)
end

local function readDynQualityMode(settingName, fallback)
  local option = getGraphicQualityOption(settingName)
  if option and type(option.get) == "function" then
    return normalizeDynQuality(option.get(), fallback)
  end
  return normalizeDynQuality(ui_photomode_shared.readSettingValue(settingName), fallback)
end

local function applyDynQualityMode(settingName, value)
  ui_photomode_shared.writeSettingValue(settingName, value)
  local option = getGraphicQualityOption(settingName)
  if option and type(option.set) == "function" then
    option.set(value)
  end
end

local function normalizeEffectsDofAperture(value)
  return ui_photomode_shared.clampNumber(
    value,
        EFFECTS_LIMITS.dofApertureMin,
    EFFECTS_LIMITS.dofApertureMax,
    8
  )
end

local function normalizeEffectsDofFalloffSharpness(value)
  return ui_photomode_shared.clampNumber(
    value,
    EFFECTS_LIMITS.dofFalloffSharpnessMin,
    EFFECTS_LIMITS.dofFalloffSharpnessMax,
    1
  )
end


local function readPostEffectEnabled(effectName)
  local effectObject = scenetree and scenetree.findObject and scenetree.findObject(effectName)
  if not effectObject or type(effectObject.isEnabled) ~= "function" then
    return nil
  end
  local ok, value = pcall(effectObject.isEnabled, effectObject)
  if not ok then
    ui_photomode_shared.logDebug("readPostEffectEnabled failed for " .. tostring(effectName) .. ": " .. tostring(value))
    return nil
  end
  return value ~= false
end

local function setPostEffectEnabled(effectName, enabled)
  local effectObject = scenetree and scenetree.findObject and scenetree.findObject(effectName)
  if not effectObject then
    return false, "effect_unavailable"
  end

  local methodName = enabled and "enable" or "disable"
  local method = effectObject[methodName]
  if type(method) ~= "function" then
    return false, "effect_unavailable"
  end

  local ok, err = pcall(method, effectObject)
  if not ok then
    log("E", logTag, string.format("%s %s failed: %s", methodName, tostring(effectName), tostring(err)))
    return false, "effect_set_failed"
  end
  return true
end

local function readPostEffectObject(effectName)
  if not scenetree then
    return nil
  end

  if scenetree[effectName] then
    return scenetree[effectName]
  end

  if type(scenetree.findObject) == "function" then
    return scenetree.findObject(effectName)
  end

  return nil
end

local function readPostEffectNumber(effectName, getterName, propertyNames)
  local effectObject = readPostEffectObject(effectName)
  if not effectObject then
    return nil
  end

  if getterName and type(effectObject[getterName]) == "function" then
    local ok, value = pcall(effectObject[getterName], effectObject)
    if ok and tonumber(value) ~= nil then
      return tonumber(value)
    end
  end

  if type(propertyNames) == "table" then
    for _, propertyName in ipairs(propertyNames) do
      local value = tonumber(effectObject[propertyName])
      if value ~= nil then
        return value
      end
    end
  end

  return nil
end

local function ssaoQualityModeFromSamples(samples)
  samples = tonumber(samples)
  if samples ~= nil and samples >= 64 then
    return "High"
  end
  return "Normal"
end

local function normalizeSsaoQuality(value, fallback)
  if value == "Off" or value == "off" or value == false then
    return "Off"
  end
  if value == "High" or tonumber(value) == 2 then
    return "High"
  end
  if value == "Normal" or value == "Low" or tonumber(value) == 1 then
    return "Normal"
  end
  return fallback
end

local function readSsaoQualityMode()
  local option = getGraphicQualityOption("PostFXSSAOGeneralQuality")
  if option and type(option.get) == "function" then
    local qualityMode = normalizeSsaoQuality(option.get(), nil)
    if qualityMode then
      return qualityMode
    end
  end

  local enabled = readPostEffectEnabled("SSAOPostFx")
  if enabled == false then
    return "Off"
  end
  if enabled == true then
    return ssaoQualityModeFromSamples(readPostEffectNumber("SSAOPostFx", "getSamples", { "samples" }))
  end
  return normalizeSsaoQuality(ui_photomode_shared.readSettingValue("PostFXSSAOGeneralQuality"), nil)
end

local function applySsaoQuality(value)
  local qualityMode = normalizeSsaoQuality(value, nil)
  if not qualityMode then
    return false, "ssao_quality_invalid"
  end
  applyDynQualityMode("PostFXSSAOGeneralQuality", qualityMode)
  return true
end

local function normalizeSsrQuality(value, fallback)
  if type(value) == "string" then
    for _, mode in ipairs(SSR_QUALITY_MODES) do
      if mode == value then
        return mode
      end
    end
  end
  return fallback
end

local function readSsrQualityMode()
  local option = getGraphicQualityOption("PostFXSSRQuality")
  if option and type(option.get) == "function" then
    return normalizeSsrQuality(option.get(), nil)
  end
  return normalizeSsrQuality(ui_photomode_shared.readSettingValue("PostFXSSRQuality"), nil)
end

local function applySsrQuality(value)
  local qualityMode = normalizeSsrQuality(value, nil)
  if not qualityMode then
    return false, "ssr_quality_invalid"
  end
  local option = getGraphicQualityOption("PostFXSSRQuality")
  if option and type(option.set) == "function" then
    option.set(qualityMode)
    return true
  end
  ui_photomode_shared.writeSettingValue("PostFXSSRQuality", qualityMode)
  ui_photomode_shared.writeSettingValue("PostFXSSREnabled", qualityMode ~= "Off")
  local ok, reason = setPostEffectEnabled("PostFxSSSRObject", qualityMode ~= "Off")
  if not ok then
    return false, reason or "ssr_quality_set_failed"
  end
  return true
end

local function readSpecularOcclusionEnabled()
  local option = getGraphicQualityOption("PostFXSpecularOcclusionEnabled")
  if option and type(option.get) == "function" then
    return ui_photomode_shared.normalizeBoolean(option.get(), false)
  end
  return ui_photomode_shared.normalizeBoolean(ui_photomode_shared.readSettingValue("PostFXSpecularOcclusionEnabled"), nil)
end

local function applySpecularOcclusionEnabled(value)
  local enabled = ui_photomode_shared.normalizeBoolean(value, false)
  ui_photomode_shared.writeSettingValue("PostFXSpecularOcclusionEnabled", enabled)
  local option = getGraphicQualityOption("PostFXSpecularOcclusionEnabled")
  if option and type(option.set) == "function" then
    option.set(enabled)
  end
  return true
end

local function applyOccupantsVisible(value)
  local visible = ui_photomode_shared.normalizeBoolean(value, true)
  ui_photomode_shared.writeSettingValue("enableSeatOccupants", visible)
  if gameplay_seatOccupants and type(gameplay_seatOccupants.onSettingsChanged) == "function" then
    gameplay_seatOccupants.onSettingsChanged()
  end
  if gameplay_traffic and type(gameplay_traffic.onSettingsChanged) == "function" then
    gameplay_traffic.onSettingsChanged()
  end
  return true
end

local EFFECTS_DISPLAY_FIELDS = {
  { key = "dofEnabled" },
  { key = "dofAutofocus" },
  { key = "dofMaxBlurNear", normalize = normalizeEffectsDofBlurNear },
  { key = "dofMaxBlurFar", normalize = normalizeEffectsDofBlurFar },
  { key = "dofFocusRange", normalize = normalizeEffectsDofFocusRange },
  { key = "dofAperture", normalize = normalizeEffectsDofAperture },
  { key = "dofFalloffSharpness", normalize = normalizeEffectsDofFalloffSharpness },
  { key = "ssaoQualityMode" },
  { key = "specularOcclusionEnabled" },
  { key = "screenSpaceShadowsEnabled" },
  { key = "ssrQualityMode" },
  { key = "motionBlurEnabled" },
  { key = "motionBlurStrength", normalize = normalizeEffectsMotionBlurStrength },
  { key = "reflectionQualityMode" },
  { key = "mirrorsQualityMode" },
  { key = "occupantsVisible" },
}

local function buildEffectsDisplayState(effectsState)
  return ui_photomode_shared.buildDescribedState(effectsState, EFFECTS_DISPLAY_FIELDS)
end

local function captureDefaultFlashPresetState()
  if ui_photomode_flash and type(ui_photomode_flash.captureDefaultPresetState) == "function" then
    return ui_photomode_flash.captureDefaultPresetState()
  end
  return nil
end

local function updateDofRuntimeSettings()
  local loaded, moduleOrError = pcall(require, "client/postFx/dof")
  if not loaded or type(moduleOrError) ~= "table" then
    return false
  end
  if type(moduleOrError.updateDOFSettings) ~= "function" then
    return false
  end
  local ok, err = pcall(moduleOrError.updateDOFSettings)
  if not ok then
    log("E", logTag, "updateDOFSettings failed: " .. tostring(err))
    return false
  end
  return true
end

local function captureEffectsSerializableState()
  local motionBlurObject = scenetree and scenetree.PostFxMotionBlur or nil

  return {
    dofEnabled = readPostEffectEnabled("DOFPostEffect"),
    dofAutofocus = ui_photomode_shared.normalizeBoolean(ui_photomode_shared.readVariableRegistryValue("$DOFPostFx::EnableAutoFocus"), false),
    dofMaxBlurNear = tonumber(ui_photomode_shared.readVariableRegistryValue("$DOFPostFx::BlurMin")),
    dofMaxBlurFar = tonumber(ui_photomode_shared.readVariableRegistryValue("$DOFPostFx::BlurMax")),
    dofFocusRange = tonumber(ui_photomode_shared.readVariableRegistryValue("$DOFPostFx::FocusRangeMax")),
    dofAperture = normalizeEffectsDofAperture(tonumber(ui_photomode_shared.readVariableRegistryValue("$DOFPostFx::BlurCurveFar"))),
    dofFalloffSharpness = normalizeEffectsDofFalloffSharpness(tonumber(ui_photomode_shared.readVariableRegistryValue("$DOFPostFx::FocusRangeMin"))),
    ssaoQualityMode = readSsaoQualityMode(),
    specularOcclusionEnabled = readSpecularOcclusionEnabled(),
    screenSpaceShadowsEnabled = readPostEffectEnabled("ScreenSpaceShadowsPostFx"),
    ssrQualityMode = readSsrQualityMode(),
    motionBlurEnabled = readPostEffectEnabled("PostFxMotionBlur"),
    motionBlurStrength = motionBlurObject and tonumber(motionBlurObject.strength) or nil,
    reflectionQualityMode = readDynQualityMode("GraphicDynReflectionQuality", nil),
    mirrorsQualityMode = readDynQualityMode("GraphicDynMirrorsQuality", nil),
    occupantsVisible = ui_photomode_shared.normalizeBoolean(ui_photomode_shared.readSettingValue("enableSeatOccupants"), nil),
  }
end

local function hasEffectsStateFields(effectsState)
  return ui_photomode_shared.hasAnyDescribedField(effectsState, EFFECTS_DISPLAY_FIELDS)
end

local function buildEffectsAvailability(effectsState)
  return {
    dof = effectsState.dofEnabled ~= nil,
    ssao = effectsState.ssaoQualityMode ~= nil,
    specularOcclusion = effectsState.specularOcclusionEnabled ~= nil,
    screenSpaceShadows = effectsState.screenSpaceShadowsEnabled ~= nil,
    ssr = effectsState.ssrQualityMode ~= nil,
    motionBlur = effectsState.motionBlurEnabled ~= nil,
    reflections = effectsState.reflectionQualityMode ~= nil,
    mirrors = effectsState.mirrorsQualityMode ~= nil,
    occupants = effectsState.occupantsVisible ~= nil,
  }
end

local function buildEffectsDefaults()
  if not ui_photomode_shared.S.sessionEffectsRestoreState then
    return nil
  end

  local defaults = buildEffectsDisplayState(ui_photomode_shared.S.sessionEffectsRestoreState)
  defaults.flash = captureDefaultFlashPresetState()
  return defaults
end

local function buildEffectsState()
  local effectsState = captureEffectsSerializableState()
  local defaults = buildEffectsDefaults()
  local state = buildEffectsDisplayState(effectsState)
  state.sessionActive = ui_photomode_shared.S.sessionActive == true
  state.availability = buildEffectsAvailability(effectsState)
  state.defaultsAvailable = defaults ~= nil
  state.defaults = defaults
  if ui_photomode_flash and type(ui_photomode_flash.capturePresetState) == "function" then
    state.flash = ui_photomode_flash.capturePresetState()
  end
  return state
end

local function captureEffectsRestoreState()
  local effectsState = captureEffectsSerializableState()
  local persistedEffectsState, persistedOk = ui_photomode_postFxPersistence.saveRestoreState(effectsState)
  local restoreState = effectsState

  if type(persistedEffectsState) == "table" then
    restoreState = {}
    for k, v in pairs(effectsState) do
      restoreState[k] = v
    end
    for k, v in pairs(persistedEffectsState) do
      restoreState[k] = v
    end
  end
  ui_photomode_shared.S.sessionEffectsRestoreState = hasEffectsStateFields(restoreState) and restoreState or nil
  ui_photomode_shared.S.sessionEffectsRestoreStatePersisted = persistedOk == true
  ui_photomode_shared.S.sessionDofManualFocusRange = ui_photomode_shared.S.sessionEffectsRestoreState and tonumber(ui_photomode_shared.S.sessionEffectsRestoreState.dofFocusRange) or nil
end

local function applyEffectsStatePatch(partialState)
  if type(partialState) ~= "table" then
    return false, "effects_state_invalid"
  end

  local changed = false

  local dofSettingChanged = false
  local currentDofFocusRange = tonumber(ui_photomode_shared.readVariableRegistryValue("$DOFPostFx::FocusRangeMax"))
  local pendingDofFocusRange = nil
  if partialState.dofEnabled ~= nil then
    local dofEnabled = ui_photomode_shared.normalizeBoolean(partialState.dofEnabled, true)
    ui_photomode_shared.writeVariableRegistryValue("$DOFPostFx::Enable", dofEnabled)
    local ok, reason = setPostEffectEnabled("DOFPostEffect", dofEnabled)
    if not ok then
      return false, reason or "effect_set_failed"
    end
    dofSettingChanged = true
    changed = true
  end

  if partialState.dofAutofocus ~= nil then
    local dofAutofocus = ui_photomode_shared.normalizeBoolean(partialState.dofAutofocus, false)
    ui_photomode_shared.writeVariableRegistryValue("$DOFPostFx::EnableAutoFocus", dofAutofocus)
    if dofAutofocus then
      if partialState.dofFocusRange == nil then
        ui_photomode_shared.S.sessionDofManualFocusRange = currentDofFocusRange
        pendingDofFocusRange = 0
      end
    elseif partialState.dofFocusRange == nil and ui_photomode_shared.S.sessionDofManualFocusRange ~= nil then
      pendingDofFocusRange = ui_photomode_shared.S.sessionDofManualFocusRange
    end
    dofSettingChanged = true
    changed = true
  end

  if partialState.dofMaxBlurNear ~= nil then
    ui_photomode_shared.writeVariableRegistryValue("$DOFPostFx::BlurMin", normalizeEffectsDofBlurNear(partialState.dofMaxBlurNear))
    dofSettingChanged = true
    changed = true
  end

  if partialState.dofMaxBlurFar ~= nil then
    ui_photomode_shared.writeVariableRegistryValue("$DOFPostFx::BlurMax", normalizeEffectsDofBlurFar(partialState.dofMaxBlurFar))
    dofSettingChanged = true
    changed = true
  end

  if partialState.dofFocusRange ~= nil then
    local normalizedDofFocusRange = normalizeEffectsDofFocusRange(partialState.dofFocusRange)
    ui_photomode_shared.writeVariableRegistryValue("$DOFPostFx::FocusRangeMax", normalizedDofFocusRange)
    ui_photomode_shared.S.sessionDofManualFocusRange = normalizedDofFocusRange
    dofSettingChanged = true
    changed = true
  elseif pendingDofFocusRange ~= nil then
    ui_photomode_shared.writeVariableRegistryValue("$DOFPostFx::FocusRangeMax", normalizeEffectsDofFocusRange(pendingDofFocusRange))
    dofSettingChanged = true
    changed = true
  end

  if partialState.dofAperture ~= nil then
    ui_photomode_shared.writeVariableRegistryValue(
      "$DOFPostFx::BlurCurveFar",
      normalizeEffectsDofAperture(partialState.dofAperture)
    )
    dofSettingChanged = true
    changed = true
  end

  if partialState.dofFalloffSharpness ~= nil then
    ui_photomode_shared.writeVariableRegistryValue(
      "$DOFPostFx::FocusRangeMin",
      normalizeEffectsDofFalloffSharpness(partialState.dofFalloffSharpness)
    )
    dofSettingChanged = true
    changed = true
  end

  if dofSettingChanged then
    updateDofRuntimeSettings()
  end

  if partialState.ssaoQualityMode ~= nil
    or partialState.ssaoQuality ~= nil
    or partialState.ssaoSamples ~= nil
    or partialState.ssaoEnabled ~= nil
  then
    local qualityValue = partialState.ssaoQualityMode or partialState.ssaoQuality
    if qualityValue == nil and partialState.ssaoSamples ~= nil then
      qualityValue = ssaoQualityModeFromSamples(partialState.ssaoSamples)
    end
    if qualityValue == nil and partialState.ssaoEnabled ~= nil then
      qualityValue = ui_photomode_shared.normalizeBoolean(partialState.ssaoEnabled, true) and "Normal" or "Off"
    end

    local ok, reason = applySsaoQuality(qualityValue)
    if not ok then
      return false, reason or "ssao_quality_set_failed"
    end
    changed = true
  end

  if partialState.screenSpaceShadowsEnabled ~= nil then
    local enabled = ui_photomode_shared.normalizeBoolean(partialState.screenSpaceShadowsEnabled, true)
    ui_photomode_shared.writeSettingValue("PostFXScreenSpaceShadowsEnabled", enabled)

    local ok, reason = setPostEffectEnabled("ScreenSpaceShadowsPostFx", enabled)
    if not ok then
      return false, reason or "screen_space_shadows_set_failed"
    end

    changed = true
  end

  if partialState.specularOcclusionEnabled ~= nil then
    applySpecularOcclusionEnabled(partialState.specularOcclusionEnabled)
    changed = true
  end

  if partialState.ssrQualityMode ~= nil then
    local ok, reason = applySsrQuality(partialState.ssrQualityMode)
    if not ok then
      return false, reason or "ssr_quality_set_failed"
    end
    changed = true
  end

  if partialState.motionBlurEnabled ~= nil then
    local motionBlurEnabled = ui_photomode_shared.normalizeBoolean(partialState.motionBlurEnabled, true)
    ui_photomode_shared.writeSettingValue("PostFXMotionBlurEnabled", motionBlurEnabled)
    local ok, reason = setPostEffectEnabled("PostFxMotionBlur", motionBlurEnabled)
    if not ok then
      return false, reason or "effect_set_failed"
    end
    changed = true
  end

  if partialState.motionBlurStrength ~= nil then
    local motionBlurObject = scenetree and scenetree.PostFxMotionBlur or nil
    if not motionBlurObject then
      return false, "effect_unavailable"
    end
    local motionBlurStrength = normalizeEffectsMotionBlurStrength(partialState.motionBlurStrength)
    ui_photomode_shared.writeSettingValue("PostFXMotionBlurStrength", motionBlurStrength)
    motionBlurObject.strength = motionBlurStrength
    changed = true
  end

  if partialState.reflectionQualityMode ~= nil then
    local qualityMode = normalizeDynQuality(partialState.reflectionQualityMode, nil)
    if not qualityMode then
      return false, "reflection_quality_invalid"
    end
    applyDynQualityMode("GraphicDynReflectionQuality", qualityMode)
    changed = true
  end

  if partialState.mirrorsQualityMode ~= nil then
    local qualityMode = normalizeDynQuality(partialState.mirrorsQualityMode, nil)
    if not qualityMode then
      return false, "mirrors_quality_invalid"
    end
    applyDynQualityMode("GraphicDynMirrorsQuality", qualityMode)
    changed = true
  end

  if partialState.occupantsVisible ~= nil then
    applyOccupantsVisible(partialState.occupantsVisible)
    changed = true
  end

  if not changed then
    return false, "effects_patch_empty"
  end

  return true
end

local function restoreDofEffectsState(restoreState)
  if type(restoreState) ~= "table" then
    return true
  end

  local dofChanged = false

  if restoreState.dofEnabled ~= nil then
    ui_photomode_shared.writeVariableRegistryValue("$DOFPostFx::Enable", restoreState.dofEnabled == true)
    local ok, reason = setPostEffectEnabled("DOFPostEffect", restoreState.dofEnabled == true)
    if not ok then
      return false, reason or "effect_set_failed"
    end
    dofChanged = true
  end

  if restoreState.dofAutofocus ~= nil then
    ui_photomode_shared.writeVariableRegistryValue("$DOFPostFx::EnableAutoFocus", restoreState.dofAutofocus == true)
    dofChanged = true
  end

  if restoreState.dofMaxBlurNear ~= nil then
    ui_photomode_shared.writeVariableRegistryValue("$DOFPostFx::BlurMin", normalizeEffectsDofBlurNear(restoreState.dofMaxBlurNear))
    dofChanged = true
  end

  if restoreState.dofMaxBlurFar ~= nil then
    ui_photomode_shared.writeVariableRegistryValue("$DOFPostFx::BlurMax", normalizeEffectsDofBlurFar(restoreState.dofMaxBlurFar))
    dofChanged = true
  end

  if restoreState.dofFocusRange ~= nil then
    local normalizedDofFocusRange = normalizeEffectsDofFocusRange(restoreState.dofFocusRange)
    ui_photomode_shared.writeVariableRegistryValue("$DOFPostFx::FocusRangeMax", normalizedDofFocusRange)
    ui_photomode_shared.S.sessionDofManualFocusRange = normalizedDofFocusRange
    dofChanged = true
  else
    ui_photomode_shared.S.sessionDofManualFocusRange = nil
  end

  if restoreState.dofAperture ~= nil then
    ui_photomode_shared.writeVariableRegistryValue(
      "$DOFPostFx::BlurCurveFar",
      normalizeEffectsDofAperture(restoreState.dofAperture)
    )
    dofChanged = true
  end

  if restoreState.dofFalloffSharpness ~= nil then
    ui_photomode_shared.writeVariableRegistryValue(
      "$DOFPostFx::FocusRangeMin",
      normalizeEffectsDofFalloffSharpness(restoreState.dofFalloffSharpness)
    )
    dofChanged = true
  end

  if dofChanged then
    updateDofRuntimeSettings()
  end

  return true
end

local NON_DOF_RESTORE_FIELDS = {
  "ssaoQualityMode",
  "specularOcclusionEnabled",
  "screenSpaceShadowsEnabled",
  "ssrQualityMode",
  "motionBlurEnabled",
  "motionBlurStrength",
  "reflectionQualityMode",
  "mirrorsQualityMode",
  "occupantsVisible",
}

local function restoreNonDofEffectsState(restoreState)
  for _, fieldName in ipairs(NON_DOF_RESTORE_FIELDS) do
    if restoreState[fieldName] ~= nil then
      local ok, reason = applyEffectsStatePatch({
        [fieldName] = restoreState[fieldName],
      })
      if not ok then
        ui_photomode_shared.logDebug(
          "restoreEffectsState " .. fieldName .. " restore skipped: " .. tostring(reason)
        )
      end
    end
  end
end

local function restoreEffectsState()
  local restoreState = ui_photomode_shared.S.sessionEffectsRestoreStatePersisted and ui_photomode_postFxPersistence.loadRestoreState() or nil
  restoreState = restoreState or ui_photomode_shared.S.sessionEffectsRestoreState
  if not restoreState then
    ui_photomode_shared.S.sessionEffectsRestoreStatePersisted = false
    return
  end

  ui_photomode_shared.S.sessionEffectsRestoreState = nil
  ui_photomode_shared.S.sessionEffectsRestoreStatePersisted = false
  restoreNonDofEffectsState(restoreState)

  local dofOk, dofReason = restoreDofEffectsState(restoreState)
  if not dofOk then
    ui_photomode_shared.logDebug("restoreDofEffectsState skipped: " .. tostring(dofReason))
  end
end


function M.setEffectsState(partialState)
  if not ui_photomode_shared.S.sessionActive then
    return {
      ok = false,
      reason = "session_inactive",
    }
  end
  if type(partialState) ~= "table" then
    return {
      ok = false,
      reason = "effects_state_invalid",
    }
  end

  local ok, reason = applyEffectsStatePatch(partialState)
  if not ok then
    return {
      ok = false,
      reason = reason or "effects_set_failed",
      state = buildEffectsState(),
    }
  end

  return {
    ok = true,
    state = buildEffectsState(),
  }
end

function M.resetEffectsToDefaults()
  if not ui_photomode_shared.S.sessionActive then
    return {
      ok = false,
      reason = "session_inactive",
    }
  end

  if not ui_photomode_shared.S.sessionEffectsRestoreState then
    return {
      ok = false,
      reason = "effects_defaults_unavailable",
      state = buildEffectsState(),
    }
  end

  local restoreState = ui_photomode_shared.S.sessionEffectsRestoreState

  applyEffectsStatePatch(restoreState)
  restoreDofEffectsState(restoreState)
  if ui_photomode_flash and type(ui_photomode_flash.applyPresetState) == "function" then
    ui_photomode_flash.applyPresetState(restoreState.flash or captureDefaultFlashPresetState())
  end

  return {
    ok = true,
    state = buildEffectsState(),
  }
end

function M.getEffectsState()
  local effectsState = buildEffectsState()
  effectsState.ok = ui_photomode_shared.S.sessionActive == true
  if not effectsState.ok then
    effectsState.reason = "session_inactive"
  end
  return effectsState
end

function M.capturePresetState()
  return M.buildMetadataState()
end

function M.captureDefaultPresetState()
  if type(ui_photomode_shared.S.sessionEffectsRestoreState) ~= "table" then
    return nil
  end

  return buildEffectsDefaults()
end

local EFFECTS_PRESET_PART_FIELDS = {
  dof = {
    "dofEnabled",
    "dofAutofocus",
    "dofMaxBlurNear",
    "dofMaxBlurFar",
    "dofFocusRange",
    "dofAperture",
    "dofFalloffSharpness",
  },
  ssao = { "ssaoQualityMode" },
  specularOcclusion = { "specularOcclusionEnabled" },
  screenSpaceShadows = { "screenSpaceShadowsEnabled" },
  ssr = { "ssrQualityMode" },
  motionBlur = { "motionBlurEnabled", "motionBlurStrength" },
  reflections = { "reflectionQualityMode", "mirrorsQualityMode" },
  occupants = { "occupantsVisible" },
}

local function pickPresetFields(source, fields)
  local result = {}
  for _, key in ipairs(fields) do
    if source[key] ~= nil then
      result[key] = source[key]
    end
  end
  return result
end

local function buildPresetStateForPart(presetState, part)
  if part == nil or part == "" or part == "all" then
    return presetState
  end

  if part == "flash" then
    return {
      flash = presetState.flash,
    }
  end

  local fields = EFFECTS_PRESET_PART_FIELDS[part]
  if not fields then
    return nil, "preset_part_invalid"
  end

  return pickPresetFields(presetState, fields)
end

function M.applyPresetState(state, options)
  local presetState = type(state) == "table" and state or {}
  options = type(options) == "table" and options or {}
  local filteredState, filterReason = buildPresetStateForPart(presetState, options.part)
  if not filteredState then
    return { ok = false, reason = filterReason or "preset_part_invalid" }
  end
  presetState = filteredState

  local hasFlashState = type(presetState.flash) == "table"
  local ok, reason = applyEffectsStatePatch(presetState)
  if not ok and not (hasFlashState and reason == "effects_patch_empty") then
    return { ok = false, reason = reason or "effects_set_failed" }
  end
  if hasFlashState and ui_photomode_flash and type(ui_photomode_flash.applyPresetState) == "function" then
    local flashOk, flashReason = ui_photomode_flash.applyPresetState(presetState.flash)
    if not flashOk then
      return { ok = false, reason = flashReason or "flash_set_failed" }
    end
  end

  return { state = buildEffectsState() }
end


M.captureRestoreState = captureEffectsRestoreState
M.restoreState = restoreEffectsState
M.buildState = buildEffectsState
function M.buildMetadataState()
  local effectsState = buildEffectsState()
  return {
    dofEnabled = effectsState.dofEnabled,
    dofAutofocus = effectsState.dofAutofocus,
    dofMaxBlurNear = effectsState.dofMaxBlurNear,
    dofMaxBlurFar = effectsState.dofMaxBlurFar,
    dofFocusRange = effectsState.dofFocusRange,
    dofAperture = effectsState.dofAperture,
    dofFalloffSharpness = effectsState.dofFalloffSharpness,
    ssaoQualityMode = effectsState.ssaoQualityMode,
    specularOcclusionEnabled = effectsState.specularOcclusionEnabled,
    screenSpaceShadowsEnabled = effectsState.screenSpaceShadowsEnabled,
    ssrQualityMode = effectsState.ssrQualityMode,
    motionBlurEnabled = effectsState.motionBlurEnabled,
    motionBlurStrength = effectsState.motionBlurStrength,
    reflectionQualityMode = effectsState.reflectionQualityMode,
    mirrorsQualityMode = effectsState.mirrorsQualityMode,
    occupantsVisible = effectsState.occupantsVisible,
    flash = effectsState.flash,
  }
end
M.captureSerializableState = captureEffectsSerializableState

return M
