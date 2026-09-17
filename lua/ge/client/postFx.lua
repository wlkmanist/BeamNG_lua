-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local dofModule = nil

local pfxDefaultStateBlock = scenetree.findObject("PFX_DefaultStateBlock")
if not pfxDefaultStateBlock then
  pfxDefaultStateBlock = createObject("GFXStateBlockData")
  pfxDefaultStateBlock.zDefined = true
  pfxDefaultStateBlock.zEnable = false
  pfxDefaultStateBlock.zWriteEnable = false
  pfxDefaultStateBlock.samplersDefined = true
  pfxDefaultStateBlock:setField("samplerStates", 0, "SamplerClampLinear")
  pfxDefaultStateBlock:registerObject("PFX_DefaultStateBlock")
end

local pfxDefaultBlendStateBlock = scenetree.findObject("PFX_DefaultBlitStateBlock")
if not pfxDefaultBlendStateBlock then
  pfxDefaultBlendStateBlock = createObject("GFXStateBlockData")
  pfxDefaultBlendStateBlock.zDefined = true
  pfxDefaultBlendStateBlock.zEnable = false
  pfxDefaultBlendStateBlock.zWriteEnable = false
  pfxDefaultBlendStateBlock.samplersDefined = true
  pfxDefaultBlendStateBlock.blendDefined = true;
  pfxDefaultBlendStateBlock.blendEnable = true;
  pfxDefaultBlendStateBlock:setField("blendSrc", 0, "GFXBlendSrcAlpha")
  pfxDefaultBlendStateBlock:setField("blendDest", 0, "GFXBlendInvSrcAlpha")
  pfxDefaultBlendStateBlock:setField("blendOp", 0, "GFXBlendOpAdd")
  pfxDefaultBlendStateBlock:setField("samplerStates", 0, "SamplerClampLinear")
  pfxDefaultBlendStateBlock:registerObject("PFX_DefaultBlitStateBlock")
end

local pfxPassthruShader = scenetree.findObject("PFX_PassthruShader")
if not pfxPassthruShader then
  pfxPassthruShader = createObject("ShaderData")
  pfxPassthruShader.DXVertexShaderFile = "shaders/common/postFx/passthruP.hlsl"
  pfxPassthruShader.DXPixelShaderFile  = "shaders/common/postFx/passthruP.hlsl"
  pfxPassthruShader:setField("samplerNames", 0, "$inputTex")
  pfxPassthruShader.pixVersion = 5.0
  pfxPassthruShader:registerObject("PFX_PassthruShader")
end

local alFormatBlend = scenetree.findObject("AL_FormatBlit")
if not alFormatBlend then
  alFormatBlend = createObject("PostEffect")
  alFormatBlend.isEnabled = false
  alFormatBlend.allowReflectPass = true
  alFormatBlend.shader = "PFX_PassthruShader"
  alFormatBlend.stateBlock = scenetree.findObject("PFX_DefaultBlitStateBlock")
  alFormatBlend.texture = "$inTex"
  alFormatBlend.target = "$backbuffer"
  alFormatBlend:registerObject("AL_FormatBlit")
end

M.initPostEffects = function()
  -- First exec the scripts for the different light managers
  -- in the lighting folder.
  -- log('I', 'postFx', "initPostEffects start...");

  require("client/postFx/caustics")
  require("client/postFx/chromaticLens")
  M.loadPresetFile("lua/ge/client/postFx/presets/defaultpostfxpreset.postfx")
  dofModule = require("client/postFx/dof")
  require("client/postFx/edgeAA")
  require("client/postFx/flash")
  require('client/postFx/fog')
  require('client/postFx/fxaa')
  require('client/postFx/glow')
  require('client/postFx/maskedScreenBlur')
  require('client/postFx/MotionBlurFx')
  require('client/postFx/smaa');
  require('client/postFx/ssao');
  require('client/postFx/screenSpaceShadows');
  require('client/postFx/turbulence');

  -- log('I', 'postFx', "... initPostEffects done");
end

M.reloadPostEffects = function()
  -- First exec the scripts for the different light managers
  -- in the lighting folder.
  -- log('I', 'postFx', "reloadPostEffects start...");

  require("client/postFx/caustics")
  require("client/postFx/chromaticLens")
  dofModule = require("client/postFx/dof")
  require("client/postFx/edgeAA")
  require("client/postFx/flash")
  require('client/postFx/fog')
  require('client/postFx/fxaa')
  require('client/postFx/glow')
  require('client/postFx/maskedScreenBlur')
  require('client/postFx/MotionBlurFx')
  require('client/postFx/smaa');
  require('client/postFx/ssao');
  require('client/postFx/screenSpaceShadows');
  require('client/postFx/turbulence');

  -- log('I', 'postFx', "... reloadPostEffects done");
end

-- Return true if we really want the effect enabled.
-- By default this is the case.
local postEffectCallbacks = {}
postEffectCallbacks.onEnabled = function()
  -- log('I','postFx','PostEffect callback onEnable called....')
  return true
end
rawset(_G, "postEffectCallbacks", postEffectCallbacks)

local function shouldSaveCurrentValues()
  return M.backupSettings == nil
end

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

M.savePresetFile = function(filename)
  local adapterCount = GFXInit.getAdapterCount()
  if adapterCount == 1 and GFXInit.getAdapterName(0) == "GFX Null Device" then
    log('I', 'postFx', "% - PostFX Manager - Null graphics device detected, skipping saving preset file.")
    return
  end

  -- log('I','postfx','savePresetFile called: '..tostring(filename))
  filename = makeRelativePath(filename,"")

  if shouldSaveCurrentValues() then
    -- Apply the current settings to the preset
    M.settingsApplyAll()
  end

  local exports = VariableRegistry.exportToTable("$PostFXManager::Settings::*")
  -- log('I','','exported $PostFXManager::Settings::* = '..dumps(exports))
  exports.header = {version = 1.2}

  jsonWriteFile(filename, exports, true)

  log('I','postFx', "% - PostFX Manager - Save complete. Preset saved at : " ..filename)
end

local function loadPresetDataVersion1(data)
  for key, value in pairs(data) do
    local flag =  string.format("$PostFXManager::Settings::%s", key)
    if type(value) ~= "table" then
      VariableRegistry.set(flag, value)
    else
      for fieldName, fieldValue in pairs(value) do
        local fullFlag =  string.format("%s::%s", flag, fieldName)
        VariableRegistry.set(fullFlag, fieldValue)
      end
    end
  end
end

local function convertV1FormatToV1_2(data)
  local object = {}
  for key, value in pairs(data) do
    if type(value) ~= "table" then
      local convertedValue = tonumber(value) or tostring(value)
      if key:find("^Enable") or key:find("^enable") then
        convertedValue = convertedValue == 1 and true or false
      end
      object[key] = convertedValue
    else
      local objTable = {}
      for fieldName, fieldValue in pairs(value) do
        local convertedValue = tonumber(fieldValue) or tostring(fieldValue)
        if fieldName:find("^Enable") or fieldName:find("^enable") then
          convertedValue = convertedValue == 1 and true or false
        end
        objTable[fieldName] = convertedValue
      end
      object[key] = objTable
    end
  end
  return object
end

M.loadPresetFile = function(filename)
  local presetFilename = FS:expandFilename(filename)
  if FS:fileExists(presetFilename) then
    presetFilename = makeRelativePath( presetFilename, "")
    -- log('I', 'postFx', "loadPresetFile loading: "..presetFilename)
    local preset = jsonReadFile(presetFilename)
    local version = preset.header and preset.header.version
    preset.header = nil -- remove header first before parsing to create flags
    if version == 1 then
      preset = convertV1FormatToV1_2(preset)
    end

    for key, obj in pairs(preset) do
      local flag =  string.format("$PostFXManager::Settings::%s", key)
      if type(obj) ~= "table" then
        VariableRegistry.set(flag, obj)
      else
        for field, value in pairs(obj) do
          local fullFlag =  string.format("%s::%s", flag, field)
          VariableRegistry.set(fullFlag, value)
        end
    end
  end
    return true
  end
  return false
end

local function migrateDefaultPresetCSFile()
  local presetFilename = "settings/default.postfxpreset.cs"
  if FS:fileExists(FS:expandFilename(presetFilename)) then
    log('I', 'postfx', "PostFX Manager - migrating cs version of default preset")
    presetFilename = makeRelativePath(presetFilename, "")
    TorqueScriptLua.exec(presetFilename)
    M.settingsApplyFromPreset()
    FS:remove(presetFilename)
    return true
  end
  return false
end

M.applyDefaultPreset = function()
  -- log('I', 'postfx', "PostFX Manager - applyDefaultPreset called.....")
  VariableRegistry.set("$PostFXManager::highPreset",   "lua/ge/client/postFx/presets/defaultPostfxPreset.postfx")
  VariableRegistry.set("$PostFXManager::normalPreset", "lua/ge/client/postFx/presets/lowestPostfxPreset.postfx")
  VariableRegistry.set("$PostFXManager::lowPreset",    "lua/ge/client/postFx/presets/lowestPostfxPreset.postfx")
  VariableRegistry.set("$PostFXManager::lowestPreset", "lua/ge/client/postFx/presets/lowestPostfxPreset.postfx")

  -- Preset Migration for 1st time a user start after switch to LUA startup
  migrateDefaultPresetCSFile()

  local loaded = M.loadPresetFile("settings/postfxSettings.postfx")
  if not loaded then
    loaded = M.loadPresetFile("lua/ge/client/postFx/presets/defaultPostfxPreset.postfx")
  end
  if loaded then
    M.settingsApplyFromPreset()
  end
end

M.applySSAOPreset = function()
  VariableRegistry.set("$SSAOPostFx::Enable",  VariableRegistry.get("$PostFXManager::Settings::SSAO::Enable"))
  VariableRegistry.set("$SSAOPostFx::blurDepthTol",  VariableRegistry.get("$PostFXManager::Settings::SSAO::blurDepthTol"))
  VariableRegistry.set("$SSAOPostFx::blurNormalTol",  VariableRegistry.get("$PostFXManager::Settings::SSAO::blurNormalTol"))
  VariableRegistry.set("$SSAOPostFx::lDepthMax",  VariableRegistry.get("$PostFXManager::Settings::SSAO::lDepthMax"))
  VariableRegistry.set("$SSAOPostFx::lDepthMin",  VariableRegistry.get("$PostFXManager::Settings::SSAO::lDepthMin"))
  VariableRegistry.set("$SSAOPostFx::lDepthPow",  VariableRegistry.get("$PostFXManager::Settings::SSAO::lDepthPow"))
  VariableRegistry.set("$SSAOPostFx::lNormalPow",  VariableRegistry.get("$PostFXManager::Settings::SSAO::lNormalPow"))
  VariableRegistry.set("$SSAOPostFx::lNormalTol",  VariableRegistry.get("$PostFXManager::Settings::SSAO::lNormalTol"))
  VariableRegistry.set("$SSAOPostFx::lRadius",  VariableRegistry.get("$PostFXManager::Settings::SSAO::lRadius"))
  VariableRegistry.set("$SSAOPostFx::lStrength",  VariableRegistry.get("$PostFXManager::Settings::SSAO::lStrength"))
  VariableRegistry.set("$SSAOPostFx::overallStrength",  VariableRegistry.get("$PostFXManager::Settings::SSAO::overallStrength"))
  VariableRegistry.set("$SSAOPostFx::quality",  VariableRegistry.get("$PostFXManager::Settings::SSAO::quality"))
  VariableRegistry.set("$SSAOPostFx::sDepthMax",  VariableRegistry.get("$PostFXManager::Settings::SSAO::sDepthMax"))
  VariableRegistry.set("$SSAOPostFx::sDepthMin",  VariableRegistry.get("$PostFXManager::Settings::SSAO::sDepthMin"))
  VariableRegistry.set("$SSAOPostFx::sDepthPow",  VariableRegistry.get("$PostFXManager::Settings::SSAO::sDepthPow"))
  VariableRegistry.set("$SSAOPostFx::sNormalPow",  VariableRegistry.get("$PostFXManager::Settings::SSAO::sNormalPow"))
  VariableRegistry.set("$SSAOPostFx::sNormalTol",  VariableRegistry.get("$PostFXManager::Settings::SSAO::sNormalTol"))
  VariableRegistry.set("$SSAOPostFx::sRadius",  VariableRegistry.get("$PostFXManager::Settings::SSAO::sRadius"))
  VariableRegistry.set("$SSAOPostFx::sStrength",  VariableRegistry.get("$PostFXManager::Settings::SSAO::sStrength"))
end

M.applyHDRPreset = function()
  VariableRegistry.set("$HDRPostFX::Enable",  VariableRegistry.get("$PostFXManager::Settings::HDR1::Enable"))
  VariableRegistry.set("$HDRPostFX::adaptRate", VariableRegistry.get("$PostFXManager::Settings::HDR1::adaptRate"))
  VariableRegistry.set("$HDRPostFX::blueShiftColor", VariableRegistry.get("$PostFXManager::Settings::HDR1::blueShiftColor"))
  VariableRegistry.set("$HDRPostFX::brightPassThreshold", VariableRegistry.get("$PostFXManager::Settings::HDR1::brightPassThreshold"))
  VariableRegistry.set("$HDRPostFX::enableBloom", VariableRegistry.get("$PostFXManager::Settings::HDR1::enableBloom"))
  VariableRegistry.set("$HDRPostFX::enableBlueShift", VariableRegistry.get("$PostFXManager::Settings::HDR1::enableBlueShift"))
  VariableRegistry.set("$HDRPostFX::enableToneMapping", VariableRegistry.get("$PostFXManager::Settings::HDR1::enableToneMapping"))
  VariableRegistry.set("$HDRPostFX::gaussMean", VariableRegistry.get("$PostFXManager::Settings::HDR1::gaussMean"))
  VariableRegistry.set("$HDRPostFX::gaussMultiplier", VariableRegistry.get("$PostFXManager::Settings::HDR1::gaussMultiplier"))
  VariableRegistry.set("$HDRPostFX::gaussStdDev", VariableRegistry.get("$PostFXManager::Settings::HDR1::gaussStdDev"))
  VariableRegistry.set("$HDRPostFX::keyValue", VariableRegistry.get("$PostFXManager::Settings::HDR1::keyValue"))
  VariableRegistry.set("$HDRPostFX::minLuminace", VariableRegistry.get("$PostFXManager::Settings::HDR1::minLuminace"))
  VariableRegistry.set("$HDRPostFX::whiteCutoff", VariableRegistry.get("$PostFXManager::Settings::HDR1::whiteCutoff"))
  VariableRegistry.set("$HDRPostFX::colorCorrectionStrength", VariableRegistry.get("PostFXManager::Settings::HDR1::colorCorrectionStrength"))
  VariableRegistry.set("$HDRPostFX::colorCorrectionRamp", VariableRegistry.get("$PostFXManager::Settings::HDR1::ColorCorrectionRamp2", ""))
end

M.applyDOFPreset = function()
  VariableRegistry.set("$DOFPostFx::Enable",  VariableRegistry.get("$PostFXManager::Settings::DOF::Enable"))
  VariableRegistry.set("$DOFPostFx::EnableDebugMode", VariableRegistry.get("$PostFXManager::Settings::DOF::EnableDebugMode"))
  VariableRegistry.set("$DOFPostFx::EnableAutoFocus", normalizeBoolean(VariableRegistry.get("$PostFXManager::Settings::DOF::EnableAutoFocus"), false))
  VariableRegistry.set("$DOFPostFx::BlurMin", VariableRegistry.get("$PostFXManager::Settings::DOF::BlurNear"))
  VariableRegistry.set("$DOFPostFx::BlurMax", VariableRegistry.get("$PostFXManager::Settings::DOF::BlurFar"))
  VariableRegistry.set("$DOFPostFx::FocusRangeMin", VariableRegistry.get("$PostFXManager::Settings::DOF::FocusAperture"))
  VariableRegistry.set("$DOFPostFx::FocusRangeMax", VariableRegistry.get("$PostFXManager::Settings::DOF::FocusDistance"))
  VariableRegistry.set("$DOFPostFx::BlurCurveNear", VariableRegistry.get("$PostFXManager::Settings::DOF::BlurCurveNear"))
  VariableRegistry.set("$DOFPostFx::BlurCurveFar", VariableRegistry.get("$PostFXManager::Settings::DOF::BlurCurve"))

  -- make sure we apply the correct settings to the DOF
  dofModule.updateDOFSettings()
end

M.settingsApplyFromPreset = function()
  -- log('I', 'postfx', "PostFX Manager - Applying from preset")

  -- SSAO Settings
  M.applySSAOPreset()

  -- HDR settings
  M.applyHDRPreset()

  -- DOF settings
  M.applyDOFPreset()

  local enablePostFX = VariableRegistry.get("$PostFXManager::Settings::EnablePostFX")
  M.settingsSetEnabled(enablePostFX)
end

M.settingsSetEnabled = function(enablePostFX)
  VariableRegistry.set("$PostFX::Enabled", enablePostFX)
  local dof = scenetree.findObject("DOFPostEffect")
  local ssao = scenetree.findObject("SSAOPostFx")
  local hdrPostFx = scenetree.findObject("HDRPostFx")

  -- if to enable the postFX, apply the ones that are enabled
  if enablePostFX then
    -- SSAO, HDR, DOF
    if ssao then
      if VariableRegistry.get("$SSAOPostFx::Enable") then
        ssao:enable()
      else
        ssao:disable()
      end
    end

    if dof then
      if VariableRegistry.get("$DOFPostFx::Enable") then
        dof:enable()
      else
        dof:disable()
      end
    end

    -- log('I','postfx',"PostFX Manager - PostFX enabled")
  else
    -- Disable all postFX
    if ssao then ssao:disable() end
    if hdrPostFx then hdrPostFx:disable() end
    if dof then dof:disable() end

    -- log('I','postfx',"PostFX Manager - PostFX disabled")
  end
end

M.backupCurrentSettings = function()
  if not M.backupSettings then
    log('I','','Creating backup of Postfx settings')
    M.backupSettings = {}

    local DOF = {}
    DOF.Enable          = VariableRegistry.get('$DOFPostFx::Enable')
    DOF.EnableDebugMode = VariableRegistry.get('$DOFPostFx::EnableDebugMode')
    DOF.EnableAutoFocus = normalizeBoolean(VariableRegistry.get('$DOFPostFx::EnableAutoFocus'), false)
    DOF.BlurMin         = VariableRegistry.get('$DOFPostFx::BlurMin')
    DOF.BlurMax         = VariableRegistry.get('$DOFPostFx::BlurMax')
    DOF.FocusRangeMin   = VariableRegistry.get('$DOFPostFx::FocusRangeMin')
    DOF.FocusRangeMax   = VariableRegistry.get('$DOFPostFx::FocusRangeMax')
    DOF.BlurCurveNear   = VariableRegistry.get('$DOFPostFx::BlurCurveNear')
    DOF.BlurCurveFar    = VariableRegistry.get('$DOFPostFx::BlurCurveFar')
    M.backupSettings.DOF = DOF

    local HDR = {}
    HDR.Enable              = VariableRegistry.get('$HDRPostFX::Enable')
    HDR.adaptRate           = VariableRegistry.get('$HDRPostFX::adaptRate')
    HDR.blueShiftColor      = VariableRegistry.get('$HDRPostFX::blueShiftColor')
    HDR.brightPassThreshold = VariableRegistry.get('$HDRPostFX::brightPassThreshold')
    HDR.enableBloom         = VariableRegistry.get('$HDRPostFX::enableBloom')
    HDR.enableBlueShift     = VariableRegistry.get('$HDRPostFX::enableBlueShift')
    HDR.enableToneMapping   = VariableRegistry.get('$HDRPostFX::enableToneMapping')
    HDR.gaussMean           = VariableRegistry.get('$HDRPostFX::gaussMean')
    HDR.gaussMultiplier     = VariableRegistry.get('$HDRPostFX::gaussMultiplier')
    HDR.gaussStdDev         = VariableRegistry.get('$HDRPostFX::gaussStdDev')
    HDR.keyValue            = VariableRegistry.get('$HDRPostFX::keyValue')
    HDR.minLuminace             = VariableRegistry.get('$HDRPostFX::minLuminace')
    HDR.whiteCutoff             = VariableRegistry.get('$HDRPostFX::whiteCutoff')
    HDR.colorCorrectionStrength = VariableRegistry.get('$HDRPostFX::colorCorrectionStrength')
    HDR.colorCorrectionRamp     = VariableRegistry.get('$HDRPostFX::colorCorrectionRamp', "")
    M.backupSettings.HDR = HDR

    local SSAO = {}
    SSAO.Enable           = VariableRegistry.get("$SSAOPostFx::Enable")
    SSAO.blurDepthTol     = VariableRegistry.get('$SSAOPostFx::blurDepthTol')
    SSAO.blurNormalTol    = VariableRegistry.get('$SSAOPostFx::blurNormalTol')
    SSAO.lDepthMax        = VariableRegistry.get('$SSAOPostFx::lDepthMax')
    SSAO.lDepthMin        = VariableRegistry.get('$SSAOPostFx::lDepthMin')
    SSAO.lDepthPow        = VariableRegistry.get('$SSAOPostFx::lDepthPow')
    SSAO.lNormalPow       = VariableRegistry.get('$SSAOPostFx::lNormalPow')
    SSAO.lNormalTol       = VariableRegistry.get('$SSAOPostFx::lNormalTol')
    SSAO.lRadius          = VariableRegistry.get('$SSAOPostFx::lRadius')
    SSAO.lStrength        = VariableRegistry.get('$SSAOPostFx::lStrength')
    SSAO.overallStrength  = VariableRegistry.get('$SSAOPostFx::overallStrength')
    SSAO.quality          = VariableRegistry.get('$SSAOPostFx::quality')
    SSAO.sDepthMax        = VariableRegistry.get('$SSAOPostFx::sDepthMax')
    SSAO.sDepthMin        = VariableRegistry.get('$SSAOPostFx::sDepthMin')
    SSAO.sDepthPow        = VariableRegistry.get('$SSAOPostFx::sDepthPow')
    SSAO.sNormalPow       = VariableRegistry.get('$SSAOPostFx::sNormalPow')
    SSAO.sNormalTol       = VariableRegistry.get('$SSAOPostFx::sNormalTol')
    SSAO.sRadius          = VariableRegistry.get('$SSAOPostFx::sRadius')
    SSAO.sStrength        = VariableRegistry.get('$SSAOPostFx::sStrength')
    M.backupSettings.SSAO = SSAO
  end
end

M.clearBackup = function()
  M.backupSettings = nil
end


local function settingsApplySSAO()
  VariableRegistry.set("$PostFXManager::Settings::SSAO::Enable",          VariableRegistry.get("$SSAOPostFx::Enable"))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::blurDepthTol',    VariableRegistry.get('$SSAOPostFx::blurDepthTol'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::blurNormalTol',   VariableRegistry.get('$SSAOPostFx::blurNormalTol'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::lDepthMax',       VariableRegistry.get('$SSAOPostFx::lDepthMax'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::lDepthMin',       VariableRegistry.get('$SSAOPostFx::lDepthMin'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::lDepthPow',       VariableRegistry.get('$SSAOPostFx::lDepthPow'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::lNormalPow',      VariableRegistry.get('$SSAOPostFx::lNormalPow'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::lNormalTol',      VariableRegistry.get('$SSAOPostFx::lNormalTol'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::lRadius',         VariableRegistry.get('$SSAOPostFx::lRadius'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::lStrength',       VariableRegistry.get('$SSAOPostFx::lStrength'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::overallStrength', VariableRegistry.get('$SSAOPostFx::overallStrength'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::quality',         VariableRegistry.get('$SSAOPostFx::quality'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::sDepthMax',       VariableRegistry.get('$SSAOPostFx::sDepthMax'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::sDepthMin',       VariableRegistry.get('$SSAOPostFx::sDepthMin'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::sDepthPow',       VariableRegistry.get('$SSAOPostFx::sDepthPow'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::sNormalPow',      VariableRegistry.get('$SSAOPostFx::sNormalPow'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::sNormalTol',      VariableRegistry.get('$SSAOPostFx::sNormalTol'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::sRadius',         VariableRegistry.get('$SSAOPostFx::sRadius'))
  VariableRegistry.set('$PostFXManager::Settings::SSAO::sStrength',       VariableRegistry.get('$SSAOPostFx::sStrength'))
end

local function settingsApplyHDR()
  VariableRegistry.set('$PostFXManager::Settings::HDR1::Enable',                  VariableRegistry.get('$HDRPostFX::Enable'))
  VariableRegistry.set('$PostFXManager::Settings::HDR1::adaptRate',               VariableRegistry.get('$HDRPostFX::adaptRate'))
  VariableRegistry.set('$PostFXManager::Settings::HDR1::blueShiftColor',          VariableRegistry.get('$HDRPostFX::blueShiftColor'))
  VariableRegistry.set('$PostFXManager::Settings::HDR1::brightPassThreshold',     VariableRegistry.get('$HDRPostFX::brightPassThreshold'))
  VariableRegistry.set('$PostFXManager::Settings::HDR1::enableBloom',             VariableRegistry.get('$HDRPostFX::enableBloom'))
  VariableRegistry.set('$PostFXManager::Settings::HDR1::enableBlueShift',         VariableRegistry.get('$HDRPostFX::enableBlueShift'))
  VariableRegistry.set('$PostFXManager::Settings::HDR1::enableToneMapping',       VariableRegistry.get('$HDRPostFX::enableToneMapping'))
  VariableRegistry.set('$PostFXManager::Settings::HDR1::gaussMean',               VariableRegistry.get('$HDRPostFX::gaussMean'))
  VariableRegistry.set('$PostFXManager::Settings::HDR1::gaussMultiplier',         VariableRegistry.get('$HDRPostFX::gaussMultiplier'))
  VariableRegistry.set('$PostFXManager::Settings::HDR1::gaussStdDev',             VariableRegistry.get('$HDRPostFX::gaussStdDev'))
  VariableRegistry.set('$PostFXManager::Settings::HDR1::keyValue',                VariableRegistry.get('$HDRPostFX::keyValue'))
  VariableRegistry.set('$PostFXManager::Settings::HDR1::minLuminace',             VariableRegistry.get('$HDRPostFX::minLuminace'))
  VariableRegistry.set('$PostFXManager::Settings::HDR1::whiteCutoff',             VariableRegistry.get('$HDRPostFX::whiteCutoff'))
  VariableRegistry.set('$PostFXManager::Settings::HDR1::colorCorrectionStrength', VariableRegistry.get('$HDRPostFX::colorCorrectionStrength'))
  VariableRegistry.set('$PostFXManager::Settings::HDR1::ColorCorrectionRamp2',    VariableRegistry.get('$HDRPostFX::colorCorrectionRamp', ""))
end

local function settingsApplyDOF()
  VariableRegistry.set('$PostFXManager::Settings::DOF::Enable',           VariableRegistry.get('$DOFPostFx::Enable'))
  VariableRegistry.set('$PostFXManager::Settings::DOF::EnableDebugMode',  VariableRegistry.get('$DOFPostFx::EnableDebugMode'))
  VariableRegistry.set('$PostFXManager::Settings::DOF::EnableAutoFocus',  normalizeBoolean(VariableRegistry.get('$DOFPostFx::EnableAutoFocus'), false))
  VariableRegistry.set('$PostFXManager::Settings::DOF::BlurNear',         VariableRegistry.get('$DOFPostFx::BlurMin'))
  VariableRegistry.set('$PostFXManager::Settings::DOF::BlurFar',          VariableRegistry.get('$DOFPostFx::BlurMax'))
  VariableRegistry.set('$PostFXManager::Settings::DOF::FocusAperture',    VariableRegistry.get('$DOFPostFx::FocusRangeMin'))
  VariableRegistry.set('$PostFXManager::Settings::DOF::FocusDistance',    VariableRegistry.get('$DOFPostFx::FocusRangeMax'))
  VariableRegistry.set('$PostFXManager::Settings::DOF::BlurCurveNear',    VariableRegistry.get('$DOFPostFx::BlurCurveNear'))
  VariableRegistry.set('$PostFXManager::Settings::DOF::BlurCurve',        VariableRegistry.get('$DOFPostFx::BlurCurveFar'))
end

M.settingsApplyAll = function()
  -- Apply settings which control if effects are on/off altogether.
  VariableRegistry.set("$PostFXManager::Settings::EnablePostFX", VariableRegistry.get("$PostFX::Enabled"))

  -- Apply settings should save the values in the system to the
  -- the preset structure ($PostFXManager::Settings::*)

  -- SSAO Settings
  settingsApplySSAO()
  -- HDR settings
  settingsApplyHDR()
  -- DOF
  settingsApplyDOF()

  -- log('I','postfx', '% - PostFX Manager - All Settings applied to $PostFXManager::Settings')
end

M.restore_cs_preset_from_json = function()
  -- log('W','postFX','restore_cs_preset_from_json callled....remember to delete this function when no longer needed')
  if M.loadPresetFile("settings/postfxSettings.postfx") then
    FS:remove("settings/postfxSettings.postfx")
  end
end
return M
