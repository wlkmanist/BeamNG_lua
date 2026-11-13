-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local dofModule = nil
local ssaoModule = nil

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

-- The raster passthru above stays for AL_FormatCopy, AL_FormatBlit and AL_UpscaleBilinear, which
-- are what copyToBackBuffer() resolves through and so cannot be a dispatch themselves.
local pfxPassthruComputeShader = scenetree.findObject("PFX_PassthruComputeShader")
if not pfxPassthruComputeShader then
  pfxPassthruComputeShader = createObject("ShaderData")
  pfxPassthruComputeShader.DXComputShaderName = "shaders/common/postFx/passthru.cs.hlsl"
  pfxPassthruComputeShader:setField("samplerNames", 0, "$inputTex")
  pfxPassthruComputeShader.pixVersion = 5.0
  pfxPassthruComputeShader:registerObject("PFX_PassthruComputeShader")
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

-- Invoked directly by PostEffectManager::stretchToBackBuffer, never added to the manager, so it must
-- not be enabled. It resolves a reduced-resolution render to the display for UpscaleMode::Bilinear
-- and SMAA T2x, which is why it samples linear and does not blend.
local alUpscaleBilinear = scenetree.findObject("AL_UpscaleBilinear")
if not alUpscaleBilinear then
  alUpscaleBilinear = createObject("PostEffect")
  alUpscaleBilinear.isEnabled = false
  alUpscaleBilinear.allowReflectPass = false
  alUpscaleBilinear.shader = "PFX_PassthruShader"
  alUpscaleBilinear.stateBlock = scenetree.findObject("PFX_DefaultStateBlock")
  alUpscaleBilinear.texture = "$inTex"
  alUpscaleBilinear.target = "$backbuffer"
  alUpscaleBilinear:registerObject("AL_UpscaleBilinear")
end

M.initPostEffects = function()
  -- First exec the scripts for the different light managers
  -- in the lighting folder.
  -- log('I', 'postFx', "initPostEffects start...");

  require("client/postFx/caustics")
  dofModule = require("client/postFx/dof")
  require("client/postFx/edgeAA")
  require('client/postFx/fog')
  require('client/postFx/fxaa')
  require('client/postFx/glow')
  require('client/postFx/maskedScreenBlur')
  require('client/postFx/smaa');
  ssaoModule = require('client/postFx/ssao');
  require('client/postFx/screenSpaceShadows');

  -- log('I', 'postFx', "... initPostEffects done");
end

M.reloadPostEffects = function()
  -- First exec the scripts for the different light managers
  -- in the lighting folder.
  -- log('I', 'postFx', "reloadPostEffects start...");

  require("client/postFx/caustics")
  dofModule = require("client/postFx/dof")
  require("client/postFx/edgeAA")
  require('client/postFx/fog')
  require('client/postFx/fxaa')
  require('client/postFx/glow')
  require('client/postFx/maskedScreenBlur')
  require('client/postFx/smaa');
  ssaoModule = require('client/postFx/ssao');
  require('client/postFx/screenSpaceShadows');

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

-- Restores the shipped default values for every effect that exposes them, then re-applies
-- the resulting state to the scene objects.
M.applyDefaults = function()
  ssaoModule = ssaoModule or require('client/postFx/ssao')
  dofModule = dofModule or require('client/postFx/dof')

  ssaoModule.applyDefaults()
  dofModule.applyDefaults()

  local ssao = scenetree.findObject("SSAOPostFx")
  if ssao then
    if VariableRegistry.get("$SSAOPostFx::Enable") then
      ssao:enable()
    else
      ssao:disable()
    end
  end

  -- also applies the enabled state to DOFPostEffect
  dofModule.updateDOFSettings()
end

return M
