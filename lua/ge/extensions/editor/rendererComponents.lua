-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- this is a little helper for the level people, so they can mark things :)

local M = {}

local im = ui_imgui
local postfxUtils = require('client/postFx/utils')
local okGraphicSettings, graphicSettingsModule = pcall(require, 'core/settings/graphic')
local graphicSettings = okGraphicSettings and graphicSettingsModule or nil
local toolWindowName = "rendererComponents"
local logTag = "editor_renderer_components"
local defaultPostFxPreset = "lua/ge/client/postFx/presets/defaultpostfxpreset.postfx"
local cloudWeatherSeedMax = 2147483647

local graphicOptionDefaults = {
  GraphicAntialias = "1",
  GraphicAntialiasType = "fxaa",
  GraphicCloudsQuality = "Normal",
  PostFXMotionBlurEnabled = true,
  PostFXMotionBlurStrength = 0.3,
  PostFXMotionBlurPlayerVehicle = true,
  PostFXSSAOGeneralQuality = "Normal",
  PostFXScreenSpaceShadowsEnabled = true
}

local cloudLayerDefaults = {
  vrtDownsampleFactor = 4,
  shadowLutUpdateGroupSize = 2,
  stepCount = 128,
  sunShadowStepCount = 8
}
local screenSpaceShadowsDefaults = nil

local types = {
  float = 1,
  texture = 2
}

local HDRsettings = {
  objectName = "PostEffectCombinePassObject",
  fields = {
    {
      identifier = "enabled",
      name = "Enabled",
      description = "Enabled",
      type = types.float,
      clampMin = 0,
      clampMax = 1,
      format = "%.0f"
    },
    {
      identifier = "colorCorrectionRampPath",
      name = "Color Correction Ramp Path",
      description = "Color Correction Ramp Path",
      type = types.texture
    },
    {
      identifier = "colorCorrectionStrength",
      name = "Color Correction Strength",
      description = "Color Correction Strength",
      type = types.float,
      clampMin = 0,
      clampMax = 1,
      format = "%.2f"
    },
  }
}

local tempBoolPtr = im.BoolPtr(true)
local tempFloatPtr = im.FloatPtr(0)
local tempIntPtr = im.IntPtr(0)
local tempFloatArr3 = im.ArrayFloat(3)
local tempCharPtr = im.ArrayChar(256, "")
local cloudWeatherSeedPtr = im.IntPtr(0)
local cloudWeatherStatus = nil

-- in string; out string
local function getTempFloat(value)
  if value then
    local res = tonumber(value)
    if res then
      tempFloatPtr[0] = res
    else
      editor.logError(logTag .. "Cannot parse float value '" .. value .. "'! Fallback to 0.")
      tempFloatPtr[0] = 0
    end
    return tempFloatPtr
  else
    return string.format('%f', tempFloatPtr[0])
  end
end

-- in string; out string
local function getTempCharPtr(value)
  if value then
    ffi.copy(tempCharPtr, value)
    return tempCharPtr
  else
    return ffi.string(tempCharPtr)
  end
end

local function widgetFloat(obj, field)
  local value = obj:getField(field.identifier, 0)
  if value then

    if field.readonly then
      if field.format then
        im.TextUnformatted(string.format(field.format, value))
      else
        im.TextUnformatted(value)
      end
    else
      im.PushItemWidth(im.GetContentRegionAvailWidth())
      if im.SliderFloat("##" .. field.identifier, getTempFloat(value), field.clampMin or 0, field.clampMax or 100, field.format or "%.3f") then
        obj:setField(field.identifier, 0, getTempFloat())
      end
      im.PopItemWidth()
    end
  end
  im.NextColumn()
end

local function widgetTexture(obj, field)
  local value = obj:getField(field.identifier, 0)
  if value then

    local function openFileDialog(dir)
      editor_fileDialog.openFile(
        function(data)
          obj:setField(field.identifier, 0, data.filepath)
        end,
        {{"Any files", "*"},{"Images",{".png", ".dds", ".jpg"}},{"PNG",".png"},{"JPG",{".jpg", ".jpeg"}},{"DDS",".dds"}},
        false,
        dir,
        true
      )
    end

    if editor.uiIconImageButton(
      editor.icons.folder,
      im.ImVec2(24, 24)
    ) then
      local dir = path.splitWithoutExt(value)
      openFileDialog(dir)
    end
    im.tooltip("Open file dialog")
    im.SameLine()

    tempBoolPtr[0] = false
    im.PushItemWidth(im.GetContentRegionAvailWidth())
    editor.uiInputText(
      "##" .. field.identifier,
      getTempCharPtr(value),
      nil,
      im.InputTextFlags_AutoSelectAll,
      nil,
      nil,
      tempBoolPtr
    )
    im.PopItemWidth()

    if tempBoolPtr[0] == true then
      obj:setField(field.identifier, 0, getTempCharPtr())
    end

  end
  im.NextColumn()
end

local function getGraphicOption(optionName)
  local module = core_settings_graphic or graphicSettings
  if module and type(module.getOptions) == "function" then
    local ok, option = pcall(module.getOptions, optionName)
    if ok then return option end
  end
end

local function getOptionValue(option)
  if option and type(option.get) == "function" then
    local ok, value = pcall(option.get)
    if ok then return value end
  end
end

local function setOptionValue(option, value)
  if option and type(option.set) == "function" then
    local ok, err = pcall(option.set, value)
    if not ok then
      log("E", logTag, "Unable to set graphics option: " .. tostring(err))
    end
    return ok
  end
  return false
end

local function drawOptionCheckbox(label, optionName, onValue, offValue)
  local option = getGraphicOption(optionName)
  if not option then
    im.TextUnformatted(label .. ": option not found.")
    return false
  end

  local value = getOptionValue(option)
  local numericValue = tonumber(value)
  tempBoolPtr[0] = value == true or (numericValue ~= nil and numericValue ~= 0)
  if im.Checkbox(label, tempBoolPtr) then
    setOptionValue(option, tempBoolPtr[0] and onValue or offValue)
    return true
  end
  return false
end

local function optionDisplayName(key, label)
  label = label or key
  if type(label) == "string" and string.sub(label, 1, 3) == "ui." then
    return tostring(key)
  end
  return tostring(label)
end

local function drawOptionCombo(label, optionName)
  local option = getGraphicOption(optionName)
  if not option or type(option.getModes) ~= "function" then
    im.TextUnformatted(label .. ": option not found.")
    return false
  end

  local okModes, modes = pcall(option.getModes)
  if not okModes then
    im.TextUnformatted(label .. ": modes unavailable.")
    return false
  end

  local keys = modes and modes.keys or {}
  local labels = modes and modes.values or {}
  local currentValue = getOptionValue(option)
  local currentLabel = tostring(currentValue)
  for i, key in ipairs(keys) do
    if key == currentValue or tostring(key) == tostring(currentValue) then
      currentLabel = optionDisplayName(key, labels[i])
      break
    end
  end

  local changed = false
  if im.BeginCombo(label, currentLabel) then
    for i, key in ipairs(keys) do
      local selected = key == currentValue or tostring(key) == tostring(currentValue)
      if im.Selectable1(optionDisplayName(key, labels[i]), selected) then
        setOptionValue(option, key)
        changed = true
      end
    end
    im.EndCombo()
  end
  return changed
end

local function resetGraphicOption(optionName)
  local fallback = graphicOptionDefaults[optionName]
  if settings and type(settings.resetSettingToDefault) == "function" then
    settings.resetSettingToDefault(optionName)
  end

  local value = settings and settings.getValue and settings.getValue(optionName, fallback) or fallback
  if value == nil then value = fallback end
  setOptionValue(getGraphicOption(optionName), value)
end

local function loadDefaultPostFxPreset()
  if not postFxModule or type(postFxModule.loadPresetFile) ~= "function" then
    return false
  end

  local ok = postFxModule.loadPresetFile(defaultPostFxPreset)
  if not ok then
    log("E", logTag, "Unable to load default postfx preset: " .. defaultPostFxPreset)
  end
  return ok
end

local function applyDefaultPostFxPreset(applyFunctionName)
  if not loadDefaultPostFxPreset() then return false end

  if applyFunctionName and type(postFxModule[applyFunctionName]) == "function" then
    postFxModule[applyFunctionName]()
  elseif type(postFxModule.settingsApplyFromPreset) == "function" then
    postFxModule.settingsApplyFromPreset()
  end
  return true
end

local function drawTabResetButton(id, resetFn)
  im.Dummy(im.ImVec2(0, 8))
  if im.Button("Reset Tab##" .. id) then
    resetFn()
  end
end

local function findPostFx(objectName)
  return scenetree and scenetree.findObject and scenetree.findObject(objectName) or nil
end

local DOFSettings = {
  ['enable'] = {
    default=false
  },
  ['enableDebugMode'] = {
    default=false
  },
  ['focusSettings'] = {
    blurMin = {
      range = {0, 1},
      default = 0.1,
    },
    blurMax = {
      range= {0, 1},
      default= 0.15,
    },
    blurCurveNear = {
      range= {1, 100},
      default= 10,
    },
    blurCurveFar = {
      range= {1, 100},
      default= 10,
    },
    focusRangeMin = {
      range= {0.1, 100},
      default= 1,
    },
    focusRangeMax = {
      range= {0, 250},
      default= 100,
    }
  }
}


local function initialiseSettings()
  DOFSettings['enable'].default = VariableRegistry.get("$DOFPostFx::Enable")
  DOFSettings['enable'].value = DOFSettings['enable'].default

  DOFSettings['enableDebugMode'].default = VariableRegistry.get("$DOFPostFx::EnableDebugMode")
  DOFSettings['enableDebugMode'].value = DOFSettings['enableDebugMode'].default

  DOFSettings['focusSettings'].blurMin.default = VariableRegistry.get("$DOFPostFx::BlurMin")
  DOFSettings['focusSettings'].blurMin.value = DOFSettings['focusSettings'].blurMin.default

  DOFSettings['focusSettings'].blurMax.default = VariableRegistry.get("$DOFPostFx::BlurMax")
  DOFSettings['focusSettings'].blurMax.value = DOFSettings['focusSettings'].blurMax.default

  DOFSettings['focusSettings'].blurCurveNear.default = VariableRegistry.get("$DOFPostFx::BlurCurveNear")
  DOFSettings['focusSettings'].blurCurveNear.value = DOFSettings['focusSettings'].blurCurveNear.default

  DOFSettings['focusSettings'].blurCurveFar.default = VariableRegistry.get("$DOFPostFx::BlurCurveFar")
  DOFSettings['focusSettings'].blurCurveFar.value = DOFSettings['focusSettings'].blurCurveFar.default

  DOFSettings['focusSettings'].focusRangeMin.default = VariableRegistry.get("$DOFPostFx::FocusRangeMin")
  DOFSettings['focusSettings'].focusRangeMin.value = DOFSettings['focusSettings'].focusRangeMin.default

  DOFSettings['focusSettings'].focusRangeMax.default = VariableRegistry.get("$DOFPostFx::FocusRangeMax")
  DOFSettings['focusSettings'].focusRangeMax.value = DOFSettings['focusSettings'].focusRangeMax.default
end

local function resetDepthOfFieldTab()
  if applyDefaultPostFxPreset("applyDOFPreset") then
    initialiseSettings()
  end
end

local function resetHDRCombinePassObject()
  local obj = findPostFx(HDRsettings.objectName)
  if obj and type(obj.setField) == "function" then
    pcall(obj.setField, obj, "enabled", 0, "1")
    pcall(obj.setField, obj, "colorCorrectionRampPath", 0, "lua/ge/client/postFx/default_color_ramp.png")
    pcall(obj.setField, obj, "colorCorrectionStrength", 0, "1")
  end
end

local function resetHDRLightingTab()
  applyDefaultPostFxPreset("applyHDRPreset")
  resetHDRCombinePassObject()
end

local function resetSSAOTab()
  applyDefaultPostFxPreset("applySSAOPreset")
  resetGraphicOption("PostFXSSAOGeneralQuality")
end

local function resetAntiAliasingTab()
  resetGraphicOption("GraphicAntialias")
  resetGraphicOption("GraphicAntialiasType")
end

local function resetMotionBlurTab()
  resetGraphicOption("PostFXMotionBlurEnabled")
  resetGraphicOption("PostFXMotionBlurStrength")
  resetGraphicOption("PostFXMotionBlurPlayerVehicle")
  if BeamNGVehicle then
    BeamNGVehicle.motionBlurAllVehiclesEnabled = true
  end
end

local function resetBloomTab()
  local bloom = scenetree.PostEffectBloomObject
  if not bloom then return end

  if type(bloom.enable) == "function" then
    bloom:enable()
  end
  bloom.threshHold = 8
end

local function captureScreenSpaceShadowsDefaults()
  if screenSpaceShadowsDefaults then return end

  local sss = findPostFx("ScreenSpaceShadowsPostFx")
  if not sss then return end

  local quality
  if type(sss.getQuality) == "function" then
    local ok, value = pcall(function() return tonumber(sss:getQuality()) end)
    if ok then quality = value end
  end

  local enabled = true
  if type(sss.isEnabled) == "function" then
    local ok, value = pcall(sss.isEnabled, sss)
    if ok then enabled = value ~= false end
  end

  screenSpaceShadowsDefaults = {
    enabled = enabled,
    quality = quality,
    surface_thickness = sss.surface_thickness,
    bilinear_threshold = sss.bilinear_threshold,
    shadow_contrast = sss.shadow_contrast,
    ignore_edge_pixels = sss.ignore_edge_pixels,
    use_precision_offset = sss.use_precision_offset,
    bilinear_sampling_offset_mode = sss.bilinear_sampling_offset_mode,
    use_early_out = sss.use_early_out
  }
end

local function resetScreenSpaceShadowsTab()
  captureScreenSpaceShadowsDefaults()

  local sss = findPostFx("ScreenSpaceShadowsPostFx")
  local defaults = screenSpaceShadowsDefaults
  if defaults then
    setOptionValue(getGraphicOption("PostFXScreenSpaceShadowsEnabled"), defaults.enabled)
  else
    resetGraphicOption("PostFXScreenSpaceShadowsEnabled")
  end

  if not sss then return end
  if defaults and type(sss.setQuality) == "function" and defaults.quality ~= nil then
    pcall(sss.setQuality, sss, defaults.quality)
  end
  if defaults then
    sss.surface_thickness = defaults.surface_thickness
    sss.bilinear_threshold = defaults.bilinear_threshold
    sss.shadow_contrast = defaults.shadow_contrast
    sss.ignore_edge_pixels = defaults.ignore_edge_pixels
    sss.use_precision_offset = defaults.use_precision_offset
    sss.bilinear_sampling_offset_mode = defaults.bilinear_sampling_offset_mode
    sss.use_early_out = defaults.use_early_out
    if defaults.enabled and type(sss.enable) == "function" then
      sss:enable()
    elseif type(sss.disable) == "function" then
      sss:disable()
    end
  end
end

local function renderDepthOfFieldTab()
  local DOFPostEffect = scenetree.findObject("DOFPostEffect")
  DOFPostEffect = Sim.upcast(DOFPostEffect)

  im.Dummy(im.ImVec2(0, 5))
  tempBoolPtr[0] = DOFSettings['enable'].value
  if im.Checkbox('Enable##DepthOfField', tempBoolPtr) then
    DOFSettings['enable'].value = tempBoolPtr[0]
    VariableRegistry.set("$DOFPostFx::Enable", DOFSettings['enable'].value)
    if tempBoolPtr[0] then
      DOFPostEffect.obj:enable()
    else
      DOFPostEffect.obj:disable()
    end
  end
  im.SameLine()
  tempBoolPtr[0] = DOFSettings['enableDebugMode'].value
  if im.Checkbox('Debug Viz##DepthOfField', tempBoolPtr) then
    DOFSettings['enableDebugMode'].value = tempBoolPtr[0]
    -- VariableRegistry.set("$PostFXManager::Settings::DOF::EnableDebugMode", DOFSettings['enableDebugMode'].value)
    VariableRegistry.set("$DOFPostFx::EnableDebugMode", DOFSettings['enableDebugMode'].value)
    DOFPostEffect.debugModeEnabled = DOFSettings['enableDebugMode'].value
  end
  im.Dummy(im.ImVec2(0, 5))
  im.Separator()
  im.TextUnformatted("Focus Settings")
  im.Dummy(im.ImVec2(0, 5))
  im.TextUnformatted("Focus Blur (Near)")
  im.SameLine()
  local blurMin = DOFSettings['focusSettings'].blurMin
  tempFloatPtr[0] = blurMin.value or blurMin.default
  if im.SliderFloat("##dofFocusNearBlur", tempFloatPtr, blurMin.range[1], blurMin.range[2], "%.3f") then
    blurMin.value = tempFloatPtr[0]
    DOFPostEffect.nearBlurMax = blurMin.value
    VariableRegistry.set("$DOFPostFx::BlurMin", blurMin.value)
  end
  im.TextUnformatted("Focus Blur (Far)")
  im.SameLine()
  local blurMax = DOFSettings['focusSettings'].blurMax
  tempFloatPtr[0] = blurMax.value or blurMax.default
  if im.SliderFloat("##dofFocusFarBlur", tempFloatPtr, blurMax.range[1], blurMax.range[2], "%.3f") then
    blurMax.value = tempFloatPtr[0]
    DOFPostEffect.farBlurMax = blurMax.value
    VariableRegistry.set("$DOFPostFx::BlurMax", blurMax.value)
  end
  im.TextUnformatted("Aperture (Focus Width)")
  im.SameLine()
  local blurCurveFar = DOFSettings['focusSettings'].blurCurveFar
  tempFloatPtr[0] = blurCurveFar.value or blurCurveFar.default
  if im.SliderFloat("##dofFocusAperture", tempFloatPtr, blurCurveFar.range[1], blurCurveFar.range[2], "%.3f") then
     blurCurveFar.value = tempFloatPtr[0]
     DOFPostEffect.farSlope = blurCurveFar.value
     VariableRegistry.set("$DOFPostFx::BlurCurveFar", blurCurveFar.value)
  end
  im.TextUnformatted("Falloff Sharpness")
  im.SameLine()
  local focusRangeMin = DOFSettings['focusSettings'].focusRangeMin
  tempFloatPtr[0] = focusRangeMin.value or focusRangeMin.default
  if im.SliderFloat("##dofFocusApertureFine", tempFloatPtr, focusRangeMin.range[1], focusRangeMin.range[2], "%.3f") then
    focusRangeMin.value = tempFloatPtr[0]
    DOFPostEffect.minRange = focusRangeMin.value
    VariableRegistry.set("$DOFPostFx::FocusRangeMin", focusRangeMin.value)
  end
  im.TextUnformatted("Focus Distance (meters)")
  im.SameLine()
  local focusRangeMax = DOFSettings['focusSettings'].focusRangeMax
  tempFloatPtr[0] = focusRangeMax.value or focusRangeMax.default
  if im.SliderFloat("##dofFocusFocusDistance", tempFloatPtr, focusRangeMax.range[1], focusRangeMax.range[2], "%.3f") then
    focusRangeMax.value = tempFloatPtr[0]
    DOFPostEffect.maxRange = focusRangeMax.value
    VariableRegistry.set("$DOFPostFx::FocusRangeMax", focusRangeMax.value)
  end
  im.Dummy(im.ImVec2(0, 15))
  im.Separator()
  im.TextUnformatted("Debug Stats")
  im.Dummy(im.ImVec2(0, 5))
  -- Estimate in-focus width (approximate, for user feedback)
  local aperture = blurCurveFar.value or blurCurveFar.default
  local steepness = focusRangeMin.value or focusRangeMin.default
  local inFocusWidth = (aperture / math.max(steepness, 0.01))
  im.TextUnformatted(string.format("Estimated In-Focus Width: %.2f units", inFocusWidth))
  drawTabResetButton("DepthOfField", resetDepthOfFieldTab)
end

local function renderHDRLightingTab()
  local obj = scenetree.findObject(HDRsettings.objectName)
  im.Columns(2)
  for _, field in ipairs(HDRsettings.fields) do
    if field.name then im.TextUnformatted(field.name) end
    if field.description then
      im.tooltip(field.description)
    end
    im.NextColumn()
    if field.type == types.float then
      widgetFloat(obj, field)
    elseif field.type == types.texture then
      widgetTexture(obj, field)
    else
      im.TextUnformatted('-type not implemented-')
      im.NextColumn()
    end
  end
  im.Columns(1)

  im.TextColored(editor.color.warning.Value, "Changes won't be saved. This is only for testing purposes.")
  drawTabResetButton("HDR", resetHDRLightingTab)
end

local function readPostFxNumber(obj, getterName, fieldNames, fallback)
  if obj and getterName and type(obj[getterName]) == "function" then
    local ok, value = pcall(obj[getterName], obj)
    if ok and tonumber(value) then return tonumber(value) end
  end

  for _, fieldName in ipairs(fieldNames or {}) do
    local value = obj and obj[fieldName]
    if tonumber(value) then return tonumber(value) end
  end

  return fallback
end

local function renderSSAOTab()
  drawOptionCheckbox("Enable##SSAO", "PostFXSSAOGeneralEnabled", true, false)
  drawOptionCombo("Quality##SSAO", "PostFXSSAOGeneralQuality")

  local ssao = findPostFx("SSAOPostFx")

  if type(ssao.setContrast) == "function" then
    tempFloatPtr[0] = readPostFxNumber(ssao, "getContrast", {"contrast", "overallStrength"}, 2)
    if im.SliderFloat("Contrast##SSAO", tempFloatPtr, 0, 10, "%.2f") then
      local ok, err = pcall(ssao.setContrast, ssao, tempFloatPtr[0])
      if not ok then log("E", logTag, "SSAOPostFx:setContrast failed: " .. tostring(err)) end
    end
  end

  if type(ssao.setRadius) == "function" then
    tempFloatPtr[0] = readPostFxNumber(ssao, "getRadius", {"radius"}, 1.5)
    if im.SliderFloat("Radius##SSAO", tempFloatPtr, 0, 5, "%.2f") then
      local ok, err = pcall(ssao.setRadius, ssao, tempFloatPtr[0])
      if not ok then log("E", logTag, "SSAOPostFx:setRadius failed: " .. tostring(err)) end
    end
  end

  im.TextColored(editor.color.warning.Value, "Changes won't be saved. This is only for testing purposes.")
  drawTabResetButton("SSAO", resetSSAOTab)
end

local function renderAntiAliasingTab()
  drawOptionCheckbox("Enable##AA", "GraphicAntialias", "1", "0")
  drawOptionCombo("Type##AA", "GraphicAntialiasType")

  local smaa = findPostFx("SMAA_PostEffect")
  local fxaa = findPostFx("FXAA_PostEffect")
  if smaa and type(smaa.isEnabled) == "function" then
    im.TextUnformatted("SMAA: " .. (smaa:isEnabled() ~= false and "Enabled" or "Disabled"))
  else
    im.TextUnformatted("SMAA_PostEffect object not found.")
  end
  if fxaa and type(fxaa.isEnabled) == "function" then
    im.TextUnformatted("FXAA: " .. (fxaa:isEnabled() ~= false and "Enabled" or "Disabled"))
  else
    im.TextUnformatted("FXAA_PostEffect object not found.")
  end
  drawTabResetButton("AntiAliasing", resetAntiAliasingTab)
end

local function renderMotionBlurTab()
  local mb = scenetree.PostFxMotionBlur

  tempBoolPtr[0] = mb:isEnabled()
  if im.Checkbox('Enable##MotionBlur', tempBoolPtr) then
    mb:toggle()
  end

  tempFloatPtr[0] = mb.strength
  if im.SliderFloat("##MB", tempFloatPtr, 0.001, 3, "%.3f") then
    mb.strength = tempFloatPtr[0]
  end

  tempBoolPtr[0] = BeamNGVehicle.motionBlurAllVehiclesEnabled
  if im.Checkbox('Enable for vehicles##MotionBlur', tempBoolPtr) then
    BeamNGVehicle.motionBlurAllVehiclesEnabled = tempBoolPtr[0]
  end

  tempBoolPtr[0] = BeamNGVehicle.motionBlurPlayerVehiclesEnabled
  if im.Checkbox('Enable for player vehicles##MotionBlur', tempBoolPtr) then
    BeamNGVehicle.motionBlurPlayerVehiclesEnabled = tempBoolPtr[0]
  end
  drawTabResetButton("MotionBlur", resetMotionBlurTab)
end

local function renderBloomTab()
  local bloom = scenetree.PostEffectBloomObject

  tempBoolPtr[0] = bloom:isEnabled()
  if im.Checkbox('Enable##Bloom', tempBoolPtr) then
    bloom:toggle()
  end

  tempFloatPtr[0] = bloom.threshHold
  if im.SliderFloat("ThreshHold##Bloom", tempFloatPtr, 0.001, 5, "%.3f") then
    bloom.threshHold = tempFloatPtr[0]
  end

  tempFloatPtr[0] = bloom.knee
  if im.SliderFloat("Knee##Bloom", tempFloatPtr, 0.001, 5, "%.3f") then
    bloom.knee = tempFloatPtr[0]
  end
  drawTabResetButton("Bloom", resetBloomTab)
end

local function renderScreenSpaceShadowsTab()
  local sss = scenetree.findObject("ScreenSpaceShadowsPostFx")
  captureScreenSpaceShadowsDefaults()

  tempBoolPtr[0] = sss:isEnabled()
  if im.Checkbox('Enable##SSS', tempBoolPtr) then
    if tempBoolPtr[0] then
      sss:enable()
    else
      sss:disable()
    end
  end

  if type(sss.getQuality) == "function" and type(sss.setQuality) == "function" then
    local qualityNames = {"Low", "Normal", "High"}
    local ok, curQuality = pcall(function() return tonumber(sss:getQuality()) end)
    if ok and curQuality then
      if im.BeginCombo("Quality##SSS", qualityNames[curQuality + 1] or tostring(curQuality)) then
        for i = 0, 2 do
          if im.Selectable1(qualityNames[i + 1], i == curQuality) then
            sss:setQuality(i)
          end
        end
        im.EndCombo()
      end
    end
  end

  im.Dummy(im.ImVec2(0, 5))
  im.Separator()
  im.TextUnformatted("Parameters")
  im.Dummy(im.ImVec2(0, 5))

  tempFloatPtr[0] = sss.surface_thickness
  if im.SliderFloat("Surface Thickness##SSS", tempFloatPtr, 0.0001, 0.1, "%.4f") then
    sss.surface_thickness = tempFloatPtr[0]
  end
  im.tooltip("Thickness of the surface used for occlusion testing.")

  tempFloatPtr[0] = sss.bilinear_threshold
  if im.SliderFloat("Bilinear Threshold##SSS", tempFloatPtr, 0.001, 0.2, "%.3f") then
    sss.bilinear_threshold = tempFloatPtr[0]
  end
  im.tooltip("Depth difference threshold for bilinear sample rejection. Quality preset overrides this on change.")

  tempFloatPtr[0] = sss.shadow_contrast
  if im.SliderFloat("Shadow Contrast##SSS", tempFloatPtr, 1.0, 16.0, "%.2f") then
    sss.shadow_contrast = tempFloatPtr[0]
  end
  im.tooltip("Contrast applied to the shadow result.")

  im.Dummy(im.ImVec2(0, 5))
  im.Separator()
  im.TextUnformatted("Options")
  im.Dummy(im.ImVec2(0, 5))

  tempBoolPtr[0] = sss.ignore_edge_pixels ~= 0 and sss.ignore_edge_pixels ~= false
  if im.Checkbox('Ignore Edge Pixels##SSS', tempBoolPtr) then
    sss.ignore_edge_pixels = tempBoolPtr[0]
  end

  tempBoolPtr[0] = sss.use_precision_offset ~= 0 and sss.use_precision_offset ~= false
  if im.Checkbox('Use Precision Offset##SSS', tempBoolPtr) then
    sss.use_precision_offset = tempBoolPtr[0]
  end

  tempBoolPtr[0] = sss.bilinear_sampling_offset_mode ~= 0 and sss.bilinear_sampling_offset_mode ~= false
  if im.Checkbox('Bilinear Sampling Offset Mode##SSS', tempBoolPtr) then
    sss.bilinear_sampling_offset_mode = tempBoolPtr[0]
  end

  tempBoolPtr[0] = sss.use_early_out ~= 0 and sss.use_early_out ~= false
  if im.Checkbox('Use Early Out##SSS', tempBoolPtr) then
    sss.use_early_out = tempBoolPtr[0]
  end
  drawTabResetButton("ScreenSpaceShadows", resetScreenSpaceShadowsTab)
end

local function renderCoconutTab()
  if im.Button("Open Coconut") then
    local ok, err = pcall(Engine.Render.setCoconutWindowOpen, true)
    if not ok then log("E", logTag, "Unable to open Coconut: " .. tostring(err)) end
  end
end

local function renderClusteredShadingTab()
  if im.Button("Open Clustered Shading") then
    local ok, err = pcall(ClusterShading)
    if not ok then log("E", logTag, "ClusterShading() failed: " .. tostring(err)) end
  end
end

local function renderShadowsTab()
  if im.Button("Open Shadows") then
    local ok, err = pcall(Shadows)
    if not ok then log("E", logTag, "Shadows() failed: " .. tostring(err)) end
  end
end

local function getCloudLayerInt(fieldName)
  if not CloudLayer then return end
  local ok, value = pcall(function() return tonumber(CloudLayer[fieldName]) end)
  if ok then return value end
end

local function setCloudLayerInt(fieldName, value)
  if not CloudLayer then return end
  local ok, err = pcall(function() CloudLayer[fieldName] = math.max(1, math.floor(value)) end)
  if not ok then log("E", logTag, "Unable to set CloudLayer." .. tostring(fieldName) .. ": " .. tostring(err)) end
end

local function drawCloudLayerInt(label, fieldName, minValue, maxValue)
  local value = getCloudLayerInt(fieldName)
  if not value then
    im.TextUnformatted(label .. ": unavailable.")
    return
  end

  tempIntPtr[0] = value
  if im.SliderInt(label, tempIntPtr, minValue, maxValue) then
    setCloudLayerInt(fieldName, tempIntPtr[0])
  end
end

local function regenerateCloudLayerWeather(seed)
  if not CloudLayer or type(CloudLayer.regenerateWeatherMap) ~= "function" then
    cloudWeatherStatus = "CloudLayer.regenerateWeatherMap is not available."
    return false
  end

  local normalizedSeed = math.floor(tonumber(seed) or 0)
  normalizedSeed = math.max(0, math.min(cloudWeatherSeedMax, normalizedSeed))
  cloudWeatherSeedPtr[0] = normalizedSeed

  local ok, err = pcall(CloudLayer.regenerateWeatherMap, normalizedSeed)
  if not ok then
    cloudWeatherStatus = "Regenerate failed: " .. tostring(err)
    log("E", logTag, "Unable to regenerate CloudLayer weather map: " .. tostring(err))
    return false
  end

  cloudWeatherStatus = "Regenerated weather map with seed " .. tostring(normalizedSeed) .. "."
  return true
end

local function resetCloudLayerTab()
  resetGraphicOption("GraphicCloudsQuality")

  for fieldName, value in pairs(cloudLayerDefaults) do
    setCloudLayerInt(fieldName, value)
  end

  if CloudLayer and type(CloudLayer.setWeatherOffsetKm) == "function" and type(Point3F) == "function" then
    local ok, err = pcall(CloudLayer.setWeatherOffsetKm, Point3F(0, 0, 0))
    if not ok then log("E", logTag, "Unable to reset CloudLayer weather offset: " .. tostring(err)) end
  end
  cloudWeatherSeedPtr[0] = 0
  cloudWeatherStatus = nil
end

local function resetAllTabs()
  if applyDefaultPostFxPreset() then
    initialiseSettings()
  end

  resetHDRCombinePassObject()
  resetGraphicOption("PostFXSSAOGeneralQuality")
  resetAntiAliasingTab()
  resetMotionBlurTab()
  resetBloomTab()
  resetScreenSpaceShadowsTab()
  resetCloudLayerTab()
end

local function renderCloudLayerTab()
  drawOptionCombo("Quality##CloudLayer", "GraphicCloudsQuality")

  im.Dummy(im.ImVec2(0, 5))
  im.Separator()
  im.TextUnformatted("Volumetric Cloud Settings")
  im.Dummy(im.ImVec2(0, 5))

  drawCloudLayerInt("VRT Downsample Factor##CloudLayer", "vrtDownsampleFactor", 1, 16)
  drawCloudLayerInt("Shadow LUT Update Group Size##CloudLayer", "shadowLutUpdateGroupSize", 1, 32)
  drawCloudLayerInt("Step Count##CloudLayer", "stepCount", 1, 512)
  drawCloudLayerInt("Sun Shadow Step Count##CloudLayer", "sunShadowStepCount", 1, 128)

  im.Dummy(im.ImVec2(0, 5))
  im.Separator()
  im.TextUnformatted("Weather")
  im.Dummy(im.ImVec2(0, 5))

  if type(CloudLayer.getWeatherOffsetKm) == "function" and type(CloudLayer.setWeatherOffsetKm) == "function" and type(Point3F) == "function" then
    local ok, offset = pcall(CloudLayer.getWeatherOffsetKm)
    if ok and offset then
      tempFloatArr3[0] = tonumber(offset.x) or 0
      tempFloatArr3[1] = tonumber(offset.y) or 0
      tempFloatArr3[2] = tonumber(offset.z) or 0
      if im.InputFloat3("Weather Offset (km)##CloudLayer", tempFloatArr3, "%.3f", im.InputTextFlags_EnterReturnsTrue) then
        local setOk, err = pcall(CloudLayer.setWeatherOffsetKm, Point3F(tempFloatArr3[0], tempFloatArr3[1], tempFloatArr3[2]))
        if not setOk then log("E", logTag, "Unable to set CloudLayer weather offset: " .. tostring(err)) end
      end
    else
      im.TextUnformatted("Weather offset is not available.")
    end
  else
    im.TextUnformatted("Weather offset controls are not available.")
  end

  if type(CloudLayer.regenerateWeatherMap) == "function" then
    tempIntPtr[0] = math.max(0, math.min(cloudWeatherSeedMax, tonumber(cloudWeatherSeedPtr[0]) or 0))
    if im.InputInt("Weather Seed##CloudLayer", tempIntPtr, 1) then
      cloudWeatherSeedPtr[0] = math.max(0, math.min(cloudWeatherSeedMax, tonumber(tempIntPtr[0]) or 0))
    end
    if im.Button("Regenerate Current Seed##CloudLayer") then
      regenerateCloudLayerWeather(cloudWeatherSeedPtr[0])
    end
    im.SameLine()
    if im.Button("Randomize Weather Map##CloudLayer") then
      regenerateCloudLayerWeather(math.random(0, cloudWeatherSeedMax))
    end
    if cloudWeatherStatus then
      im.TextUnformatted(cloudWeatherStatus)
    end
  else
    im.TextUnformatted("Weather map regeneration is not available.")
  end
  drawTabResetButton("CloudLayer", resetCloudLayerTab)
end

local function onEditorGui()
  if editor.beginWindow(toolWindowName, "Renderer Components", im.WindowFlags_MenuBar) then
    if im.BeginMenuBar() then
      if im.BeginMenu("File", imgui_true) then
        if im.MenuItem1("Load Preset...",nil,imgui_false,imgui_true) then
           postfxUtils.loadPresets()
        end
        if im.MenuItem1("Save Preset...",nil,imgui_false,imgui_true) then
          postfxUtils.savePresets()
        end
        im.EndMenu()
      end
      if im.MenuItem1("Reset All", nil, imgui_true) then
        resetAllTabs()
      end
      im.EndMenuBar()
    end
    im.Dummy(im.ImVec2(0, 10))

    if im.BeginTabBar("settings") then
      if findPostFx("DOFPostEffect") and im.BeginTabItem("Depth of Field", nil, im.TabItemFlags_None) then
        renderDepthOfFieldTab()
        im.EndTabItem()
      end

      if findPostFx(HDRsettings.objectName) and im.BeginTabItem("HDR", nil, im.TabItemFlags_None) then
        renderHDRLightingTab()
        im.EndTabItem()
      end

      if findPostFx("SSAOPostFx") and im.BeginTabItem("SSAO", nil, im.TabItemFlags_None) then
        renderSSAOTab()
        im.EndTabItem()
      end

      if (getGraphicOption("GraphicAntialias") or getGraphicOption("GraphicAntialiasType")) and im.BeginTabItem("Anti-Aliasing", nil, im.TabItemFlags_None) then
        renderAntiAliasingTab()
        im.EndTabItem()
      end

      if scenetree.PostFxMotionBlur and BeamNGVehicle and im.BeginTabItem("Motion Blur", nil, im.TabItemFlags_None) then
        renderMotionBlurTab()
        im.EndTabItem()
      end

      if scenetree.PostEffectBloomObject and im.BeginTabItem("Bloom", nil, im.TabItemFlags_None) then
        renderBloomTab()
        im.EndTabItem()
      end

      if findPostFx("ScreenSpaceShadowsPostFx") and im.BeginTabItem("Screen Space Shadows", nil, im.TabItemFlags_None) then
        renderScreenSpaceShadowsTab()
        im.EndTabItem()
      end

      if CloudLayer and im.BeginTabItem("CloudLayer", nil, im.TabItemFlags_None) then
        renderCloudLayerTab()
        im.EndTabItem()
      end

      local render = Engine and Engine.Render or nil
      if not shipping_build and render and type(render.setCoconutWindowOpen) == "function" and im.BeginTabItem("Coconut", nil, im.TabItemFlags_None) then
        renderCoconutTab()
        im.EndTabItem()
      end

      if not shipping_build and type(ClusterShading) == "function" and im.BeginTabItem("Clustered Shading", nil, im.TabItemFlags_None) then
        renderClusteredShadingTab()
        im.EndTabItem()
      end

      if not shipping_build and type(Shadows) == "function" and im.BeginTabItem("Shadows", nil, im.TabItemFlags_None) then
        renderShadowsTab()
        im.EndTabItem()
      end

      im.EndTabBar()
    end

  end
  editor.endWindow()
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  editor.addWindowMenuItem("Renderer Components", onWindowMenuItem)

  editor.registerWindow(toolWindowName, im.ImVec2(300, 500))
  if postFxModule then
    postFxModule.backupCurrentSettings()
  end
  initialiseSettings()
  captureScreenSpaceShadowsDefaults()
end

M.onEditorActivated = function()
  if DOFSettings['enable'].value == nil then
    initialiseSettings()
  end

  local DOFPostEffect = scenetree.findObject("DOFPostEffect")
  if DOFPostEffect then
    DOFPostEffect = Sim.upcast(DOFPostEffect)
    DOFPostEffect.debugModeEnabled = DOFSettings['enableDebugMode'].value
    if DOFSettings['enable'].value then
      DOFPostEffect.obj:enable()
    else
      DOFPostEffect.obj:disable()
    end
  end
end

-- public interface
M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized

return M
