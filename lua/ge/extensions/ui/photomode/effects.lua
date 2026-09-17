-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = { "ui_photomode_shared", "ui_photomode_postFxPersistence", "ui_photomode_flash" }



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
  reflectionSizeLog2Min = 7,
  reflectionSizeLog2Max = 11,
  reflectionDetailMin = 0,
  reflectionDetailMax = 2,
  reflectionDistanceMin = 1,
  reflectionDistanceMax = 2000,
  ssaoContrastMin = 1,
  ssaoContrastMax = 10,
  ssaoRadiusMin = 0.01,
  ssaoRadiusMax = 3,
}


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

local function normalizeEffectsReflectionSizeLog2(value)
  return ui_photomode_shared.clampNumber(
    value,
    EFFECTS_LIMITS.reflectionSizeLog2Min,
    EFFECTS_LIMITS.reflectionSizeLog2Max,
    9
  )
end

local function normalizeEffectsReflectionDetail(value)
  return ui_photomode_shared.clampNumber(
    value,
    EFFECTS_LIMITS.reflectionDetailMin,
    EFFECTS_LIMITS.reflectionDetailMax,
    0.8
  )
end

local function normalizeEffectsReflectionDistance(value)
  return ui_photomode_shared.clampNumber(
    value,
    EFFECTS_LIMITS.reflectionDistanceMin,
    EFFECTS_LIMITS.reflectionDistanceMax,
    300
  )
end

local function textureSizeToLog2(value)
  local numericValue = tonumber(value)
  if numericValue == nil or numericValue <= 0 then
    return 9
  end
  local log2Value = math.log(numericValue) / math.log(2)
  return normalizeEffectsReflectionSizeLog2(math.floor(log2Value + 0.5))
end

local function log2ToTextureSize(value)
  return math.floor(math.pow(2, normalizeEffectsReflectionSizeLog2(value)) + 0.5)
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

local function hasPostEffectMethod(effectName, methodName)
  local effectObject = readPostEffectObject(effectName)
  return effectObject ~= nil and type(effectObject[methodName]) == "function"
end

local function normalizeEffectsSsaoContrast(value)
  return ui_photomode_shared.clampNumber(
    value,
    EFFECTS_LIMITS.ssaoContrastMin,
    EFFECTS_LIMITS.ssaoContrastMax,
    2
  )
end

local function normalizeEffectsSsaoRadius(value)
  return ui_photomode_shared.clampNumber(
    value,
    EFFECTS_LIMITS.ssaoRadiusMin,
    EFFECTS_LIMITS.ssaoRadiusMax,
    1.5
  )
end

local function ssaoQualityModeFromSamples(samples)
  samples = tonumber(samples)
  if samples ~= nil and samples >= 64 then
    return "High"
  end
  return "Normal"
end

local function ssaoSamplesFromQualityMode(value)
  if value == "High" or tonumber(value) == 2 then
    return 64, "High"
  end

  if value == "Normal" or value == "Low" or tonumber(value) == 1 then
    return 16, "Normal"
  end

  return nil, nil
end

local function readSsaoContrast()
  local value = readPostEffectNumber("SSAOPostFx", "getContrast", {
    "contrast",
    "overallStrength",
  })

  if value ~= nil then
    return value
  end

  -- Many builds expose setContrast but no getter.
  if hasPostEffectMethod("SSAOPostFx", "setContrast") then
    return 2
  end

  return nil
end

local function readSsaoRadius()
  local value = readPostEffectNumber("SSAOPostFx", "getRadius", {
    "radius",
  })

  if value ~= nil then
    return value
  end

  -- Many builds expose setRadius but no getter.
  if hasPostEffectMethod("SSAOPostFx", "setRadius") then
    return 1.5
  end

  return nil
end

local function readSsaoSamples()
  local value = readPostEffectNumber("SSAOPostFx", "getSamples", {
    "samples",
  })

  if value ~= nil then
    return value
  end

  if not hasPostEffectMethod("SSAOPostFx", "setSamples") then
    return nil
  end

  local qualitySetting = ui_photomode_shared.readSettingValue("PostFXSSAOGeneralQuality")
  local samples = ssaoSamplesFromQualityMode(qualitySetting)

  return samples or 16
end

local function applySsaoContrast(value)
  local ssaoObject = readPostEffectObject("SSAOPostFx")
  if not ssaoObject or type(ssaoObject.setContrast) ~= "function" then
    return false, "ssao_contrast_unavailable"
  end

  local ok, err = pcall(ssaoObject.setContrast, ssaoObject, normalizeEffectsSsaoContrast(value))
  if not ok then
    log("E", logTag, "SSAOPostFx:setContrast failed: " .. tostring(err))
    return false, "ssao_contrast_set_failed"
  end

  return true
end

local function applySsaoRadius(value)
  local ssaoObject = readPostEffectObject("SSAOPostFx")
  if not ssaoObject or type(ssaoObject.setRadius) ~= "function" then
    return false, "ssao_radius_unavailable"
  end

  local ok, err = pcall(ssaoObject.setRadius, ssaoObject, normalizeEffectsSsaoRadius(value))
  if not ok then
    log("E", logTag, "SSAOPostFx:setRadius failed: " .. tostring(err))
    return false, "ssao_radius_set_failed"
  end

  return true
end

local function applySsaoQuality(value)
  local samples, qualityMode = ssaoSamplesFromQualityMode(value)
  if samples == nil then
    return false, "ssao_quality_invalid"
  end

  local ssaoObject = readPostEffectObject("SSAOPostFx")
  if not ssaoObject or type(ssaoObject.setSamples) ~= "function" then
    return false, "ssao_quality_unavailable"
  end

  local ok, err = pcall(ssaoObject.setSamples, ssaoObject, samples)
  if not ok then
    log("E", logTag, "SSAOPostFx:setSamples failed: " .. tostring(err))
    return false, "ssao_quality_set_failed"
  end

  -- Graphics settings historically use Low/High here.
  ui_photomode_shared.writeSettingValue("PostFXSSAOGeneralQuality", qualityMode == "High" and "High" or "Low")

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
  { key = "ssaoEnabled" },
  { key = "ssaoContrast", normalize = normalizeEffectsSsaoContrast },
  { key = "ssaoRadius", normalize = normalizeEffectsSsaoRadius },
  { key = "ssaoSamples", outputKey = "ssaoQualityMode", normalize = ssaoQualityModeFromSamples },
  { key = "screenSpaceShadowsEnabled" },
  { key = "motionBlurEnabled" },
  { key = "motionBlurStrength", normalize = normalizeEffectsMotionBlurStrength },
  { key = "reflectionsEnabled" },
  { key = "reflectionDetail", normalize = normalizeEffectsReflectionDetail },
  { key = "reflectionDistance", normalize = normalizeEffectsReflectionDistance },
  { key = "reflectionTextureSize", outputKey = "reflectionSizeLog2", normalize = textureSizeToLog2 },
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
  local reflectionsEnabledValue = ui_photomode_shared.readSettingValue("GraphicDynReflectionEnabled")
  if reflectionsEnabledValue == nil then
    reflectionsEnabledValue = ui_photomode_shared.readVariableRegistryValue("$pref::BeamNGVehicle::dynamicReflection::enabled")
  end

  return {
    dofEnabled = readPostEffectEnabled("DOFPostEffect"),
    dofAutofocus = ui_photomode_shared.normalizeBoolean(ui_photomode_shared.readVariableRegistryValue("$DOFPostFx::EnableAutoFocus"), false),
    dofMaxBlurNear = tonumber(ui_photomode_shared.readVariableRegistryValue("$DOFPostFx::BlurMin")),
    dofMaxBlurFar = tonumber(ui_photomode_shared.readVariableRegistryValue("$DOFPostFx::BlurMax")),
    dofFocusRange = tonumber(ui_photomode_shared.readVariableRegistryValue("$DOFPostFx::FocusRangeMax")),
    dofAperture = normalizeEffectsDofAperture(tonumber(ui_photomode_shared.readVariableRegistryValue("$DOFPostFx::BlurCurveFar"))),
    dofFalloffSharpness = normalizeEffectsDofFalloffSharpness(tonumber(ui_photomode_shared.readVariableRegistryValue("$DOFPostFx::FocusRangeMin"))),
    ssaoEnabled = readPostEffectEnabled("SSAOPostFx"),
    ssaoContrast = readSsaoContrast(),
    ssaoRadius = readSsaoRadius(),
    ssaoSamples = readSsaoSamples(),

    screenSpaceShadowsEnabled = readPostEffectEnabled("ScreenSpaceShadowsPostFx"),
    motionBlurEnabled = readPostEffectEnabled("PostFxMotionBlur"),
    motionBlurStrength = motionBlurObject and tonumber(motionBlurObject.strength) or nil,
    reflectionsEnabled = ui_photomode_shared.normalizeBoolean(reflectionsEnabledValue, true),
    reflectionDetail = tonumber(ui_photomode_shared.readVariableRegistryValue("$pref::BeamNGVehicle::dynamicReflection::detail")),
    reflectionDistance = tonumber(ui_photomode_shared.readVariableRegistryValue("$pref::BeamNGVehicle::dynamicReflection::distance")),
    reflectionTextureSize = tonumber(ui_photomode_shared.readVariableRegistryValue("$pref::BeamNGVehicle::dynamicReflection::textureSize")),
  }
end

local function hasEffectsStateFields(effectsState)
  return ui_photomode_shared.hasAnyDescribedField(effectsState, EFFECTS_DISPLAY_FIELDS)
end

local function buildEffectsAvailability(effectsState)
  return {
    dof = effectsState.dofEnabled ~= nil,
    ssao = effectsState.ssaoEnabled ~= nil,
    ssaoSettings = hasPostEffectMethod("SSAOPostFx", "setContrast")
      or hasPostEffectMethod("SSAOPostFx", "setRadius")
      or hasPostEffectMethod("SSAOPostFx", "setSamples"),
    screenSpaceShadows = effectsState.screenSpaceShadowsEnabled ~= nil,
    motionBlur = effectsState.motionBlurEnabled ~= nil,
    reflections = effectsState.reflectionsEnabled ~= nil,
    reflectionDetail = effectsState.reflectionDetail ~= nil,
    reflectionDistance = effectsState.reflectionDistance ~= nil,
    reflectionSize = effectsState.reflectionTextureSize ~= nil,
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

  if partialState.ssaoEnabled ~= nil then
    local ssaoEnabled = ui_photomode_shared.normalizeBoolean(partialState.ssaoEnabled, true)
    ui_photomode_shared.writeSettingValue("PostFXSSAOGeneralEnabled", ssaoEnabled)
    ui_photomode_shared.writeVariableRegistryValue("$SSAOPostFx::Enable", ssaoEnabled)

    local ok, reason = setPostEffectEnabled("SSAOPostFx", ssaoEnabled)
    if not ok then
      return false, reason or "effect_set_failed"
    end

    changed = true
  end

  if partialState.ssaoContrast ~= nil then
    local ok, reason = applySsaoContrast(partialState.ssaoContrast)
    if not ok then
      return false, reason or "ssao_contrast_set_failed"
    end
    changed = true
  end

  if partialState.ssaoRadius ~= nil then
    local ok, reason = applySsaoRadius(partialState.ssaoRadius)
    if not ok then
      return false, reason or "ssao_radius_set_failed"
    end
    changed = true
  end

  if partialState.ssaoQualityMode ~= nil
    or partialState.ssaoQuality ~= nil
    or partialState.ssaoSamples ~= nil
  then
    local qualityValue = partialState.ssaoQualityMode or partialState.ssaoQuality

    if qualityValue == nil and partialState.ssaoSamples ~= nil then
      qualityValue = ssaoQualityModeFromSamples(partialState.ssaoSamples)
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

  if partialState.reflectionsEnabled ~= nil then
    local reflectionsEnabled = ui_photomode_shared.normalizeBoolean(partialState.reflectionsEnabled, true)
    local settingsApplied = ui_photomode_shared.writeSettingsState({
      GraphicDynReflectionEnabled = reflectionsEnabled,
    })
    if not settingsApplied then
      ui_photomode_shared.writeVariableRegistryValue("$pref::BeamNGVehicle::dynamicReflection::enabled", reflectionsEnabled)
      ui_photomode_shared.writeSettingValue("GraphicDynReflectionEnabled", reflectionsEnabled)
    end
    changed = true
  end

  if partialState.reflectionSizeLog2 ~= nil or partialState.reflectionTextureSize ~= nil then
    local textureSize = partialState.reflectionTextureSize
    if textureSize == nil then
      textureSize = log2ToTextureSize(partialState.reflectionSizeLog2)
    else
      textureSize = log2ToTextureSize(textureSizeToLog2(textureSize))
    end
    ui_photomode_shared.writeVariableRegistryValue("$pref::BeamNGVehicle::dynamicReflection::textureSize", tonumber(textureSize))
    changed = true
  end

  if partialState.reflectionDetail ~= nil then
    ui_photomode_shared.writeVariableRegistryValue(
      "$pref::BeamNGVehicle::dynamicReflection::detail",
      normalizeEffectsReflectionDetail(partialState.reflectionDetail)
    )
    changed = true
  end

  if partialState.reflectionDistance ~= nil then
    ui_photomode_shared.writeVariableRegistryValue(
      "$pref::BeamNGVehicle::dynamicReflection::distance",
      normalizeEffectsReflectionDistance(partialState.reflectionDistance)
    )
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

local function restoreEffectsState()
  local restoreState = ui_photomode_shared.S.sessionEffectsRestoreStatePersisted and ui_photomode_postFxPersistence.loadRestoreState() or nil
  restoreState = restoreState or ui_photomode_shared.S.sessionEffectsRestoreState
  if not restoreState then
    ui_photomode_shared.S.sessionEffectsRestoreStatePersisted = false
    return
  end

  ui_photomode_shared.S.sessionEffectsRestoreState = nil
  ui_photomode_shared.S.sessionEffectsRestoreStatePersisted = false
  local nonDofRestoreState = {
    ssaoEnabled = restoreState.ssaoEnabled,
    ssaoContrast = restoreState.ssaoContrast,
    ssaoRadius = restoreState.ssaoRadius,
    ssaoQualityMode = restoreState.ssaoSamples ~= nil and ssaoQualityModeFromSamples(restoreState.ssaoSamples) or nil,
    screenSpaceShadowsEnabled = restoreState.screenSpaceShadowsEnabled,
    motionBlurEnabled = restoreState.motionBlurEnabled,
    motionBlurStrength = restoreState.motionBlurStrength,
    reflectionsEnabled = restoreState.reflectionsEnabled,
    reflectionDetail = restoreState.reflectionDetail,
    reflectionDistance = restoreState.reflectionDistance,
    reflectionTextureSize = restoreState.reflectionTextureSize,
  }

  local ok, reason = applyEffectsStatePatch(nonDofRestoreState)
  if not ok then
    ui_photomode_shared.logDebug("restoreEffectsState skipped: " .. tostring(reason))
  end

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
  ssao = { "ssaoEnabled", "ssaoContrast", "ssaoRadius", "ssaoQualityMode" },
  screenSpaceShadows = { "screenSpaceShadowsEnabled" },
  motionBlur = { "motionBlurEnabled", "motionBlurStrength" },
  reflections = { "reflectionsEnabled", "reflectionSizeLog2", "reflectionDetail", "reflectionDistance" },
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
    ssaoEnabled = effectsState.ssaoEnabled,
    ssaoContrast = effectsState.ssaoContrast,
    ssaoRadius = effectsState.ssaoRadius,
    ssaoQualityMode = effectsState.ssaoQualityMode,
    screenSpaceShadowsEnabled = effectsState.screenSpaceShadowsEnabled,
    motionBlurEnabled = effectsState.motionBlurEnabled,
    motionBlurStrength = effectsState.motionBlurStrength,
    reflectionsEnabled = effectsState.reflectionsEnabled,
    reflectionSizeLog2 = effectsState.reflectionSizeLog2,
    reflectionDetail = effectsState.reflectionDetail,
    reflectionDistance = effectsState.reflectionDistance,
    flash = effectsState.flash,
  }
end
M.captureSerializableState = captureEffectsSerializableState

return M
