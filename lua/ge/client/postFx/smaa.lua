-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- log('I','postfx', 'Smaa.lua loaded.....')

local smaaStateBlock = scenetree.findObject("SMAA_StateBlock")
if not smaaStateBlock then
  local pfxDefaultStateBlock = scenetree.findObject("PFX_DefaultStateBlock")
  smaaStateBlock = createObject("GFXStateBlockData")
  smaaStateBlock:inheritParentFields(pfxDefaultStateBlock)
  smaaStateBlock.samplersDefined = true
  smaaStateBlock:setField("samplerStates", 0, "SamplerClampPoint")
  smaaStateBlock:setField("samplerStates", 1, "SamplerClampLinear")
  smaaStateBlock:registerObject("SMAA_StateBlock")
end

local smaaEdgeDetectionShaderData = scenetree.findObject("SMAA_EdgeDetectionShaderData")
if not smaaEdgeDetectionShaderData then
  smaaEdgeDetectionShaderData = createObject("ShaderData")
  smaaEdgeDetectionShaderData.DXComputShaderName    = "shaders/common/postFx/smaa/smaa_edgeDetection.cs.hlsl"
  smaaEdgeDetectionShaderData.pixVersion = 5.0
  smaaEdgeDetectionShaderData:setField("samplerNames", 0, "$colorTexGamma")
  smaaEdgeDetectionShaderData:registerObject("SMAA_EdgeDetectionShaderData")
end

local smaaBlendingWeightShaderData = scenetree.findObject("SMAA_BlendingWeightShaderData")
if not smaaBlendingWeightShaderData then
  smaaBlendingWeightShaderData = createObject("ShaderData")
  smaaBlendingWeightShaderData.DXComputShaderName    = "shaders/common/postFx/smaa/smaa_blendingWeight.cs.hlsl"
  smaaBlendingWeightShaderData.pixVersion = 5.0
  smaaBlendingWeightShaderData:setField("samplerNames", 0, "$edgesTex")
  smaaBlendingWeightShaderData:setField("samplerNames", 1, "$areaTex")
  smaaBlendingWeightShaderData:setField("samplerNames", 2, "$searchTex")
  smaaBlendingWeightShaderData:registerObject("SMAA_BlendingWeightShaderData")
end

local smaaNeighborhoodBlendingShaderData = scenetree.findObject("SMAA_NeighborhoodBlendingShaderData")
if not smaaNeighborhoodBlendingShaderData then
  smaaNeighborhoodBlendingShaderData = createObject("ShaderData")
  smaaNeighborhoodBlendingShaderData.DXComputShaderName    = "shaders/common/postFx/smaa/smaa_NeighborhoodBlending.cs.hlsl"
  smaaNeighborhoodBlendingShaderData.pixVersion = 5.0
  smaaNeighborhoodBlendingShaderData:setField("samplerNames", 0, "$colorTex")
  smaaNeighborhoodBlendingShaderData:setField("samplerNames", 1, "$blendTex")
  smaaNeighborhoodBlendingShaderData:registerObject("SMAA_NeighborhoodBlendingShaderData")
end

-- UpscaleMode::SMAAT2x, see engine/graphics/postFx/upscale/upscaler.h
local smaaT2xUpscaleMode = 7

-- Shared by every AA mode that takes over from T2x. The chain and the render view jitter have to go
-- together, a jittered scene without the resolve is just permanent shimmer.
local function disableSmaaT2x()
  local pfx = scenetree.findObject("SMAA_T2X_PostEffect")
  if pfx then
    pfx:disable()
  end
  local mgr = RenderViewManagerInstance
  if mgr then
    local function clearT2x(rv)
      if rv and rv.upscaleMode == smaaT2xUpscaleMode then
        rv.upscaleMode = 0
      end
    end
    clearT2x(mgr:getView("main"))
    for i = 0, 7 do
      clearT2x(mgr:getView("splitscreen" .. i))
    end
    clearT2x(mgr:getView("multiMonitorLeft"))
    clearT2x(mgr:getView("multiMonitorRight"))
  end
end
rawset(_G, "disableSmaaT2x", disableSmaaT2x)

local smaaPostEffectCallbacks = {}
smaaPostEffectCallbacks.onEnabled = function()
  -- log('I', 'smaaPostEffect', 'onEnabled called for smaaPostEffect')
  local fxaa_postfx = scenetree.findObject("FXAA_PostEffect")
  if fxaa_postfx then
    fxaa_postfx:disable()
  end
  disableSmaaT2x()
  return true
end

smaaPostEffectCallbacks.preProcess = function()
  local smaaPostEffect = scenetree.findObject("SMAA_PostEffect")
  if smaaPostEffect then
    local rtSize = smaaPostEffect:getRenderTargetSize()
    local rtResolution = string.format("%f %f %f %f", 1.0 / rtSize.x, 1.0 / rtSize.y, rtSize.x, rtSize.y)
    local currentRTResolution = smaaPostEffect:getField("rtResolution", 0)
    if rtResolution ~= currentRTResolution then
      smaaPostEffect:setField("rtResolution", 0, rtResolution)
      smaaPostEffect:setShaderConst("$smaaRtMetrics", rtResolution)
      local smaaPostEffect1 = scenetree.findObject("SMAA_PostEffect1")
      if smaaPostEffect1 then
        smaaPostEffect1:setShaderConst("$smaaRtMetrics", rtResolution)
      end
      local smaaPostEffect2 = scenetree.findObject("SMAA_PostEffect2")
      if smaaPostEffect2 then
        smaaPostEffect2:setShaderConst("$smaaRtMetrics", rtResolution)
      end
    end
  end
end

rawset(_G, "SMAA_PostEffectCallbacks", smaaPostEffectCallbacks)

local smaaPostEffect = scenetree.findObject("SMAA_PostEffect")
if not smaaPostEffect then
  smaaPostEffect = createObject("PostEffect")
  smaaPostEffect.isEnabled = false
  smaaPostEffect.allowReflectPass = false
  smaaPostEffect:setField("renderTime", 0, "PFXAfterDiffuse")
  smaaPostEffect:setField("texture", 0, "$backBuffer")
  smaaPostEffect:setField("target", 0, "$outTex")
  smaaPostEffect:setField("stateBlock", 0, "SMAA_StateBlock")
  smaaPostEffect:setField("shader", 0, "SMAA_EdgeDetectionShaderData")

  local smaaPostEffect1 = createObject("PostEffect")
  smaaPostEffect1:inheritParentFields(smaaPostEffect)
  smaaPostEffect1:setField("texture", 0, "$inTex")
  smaaPostEffect1:setField("texture", 1, "shaders/common/postFx/smaa/AreaTexDX9.dds")
  smaaPostEffect1:setField("texture", 2, "shaders/common/postFx/smaa/SearchTex.dds")
  smaaPostEffect1:setField("target", 0, "$outTex")
  smaaPostEffect1:setField("stateBlock", 0, "SMAA_StateBlock")
  smaaPostEffect1:setField("shader", 0, "SMAA_BlendingWeightShaderData")

  local smaaPostEffect2 = createObject("PostEffect")
  smaaPostEffect2:inheritParentFields(smaaPostEffect1)
  smaaPostEffect2:setField("texture", 0, "$backBuffer")
  smaaPostEffect2:setField("texture", 1, "$inTex")
  smaaPostEffect2:setField("target", 0, "$backBuffer")
  smaaPostEffect2:setField("stateBlock", 0, "SMAA_StateBlock")
  smaaPostEffect2:setField("shader", 0, "SMAA_NeighborhoodBlendingShaderData")
  smaaPostEffect2:registerObject("SMAA_PostEffect2")

  smaaPostEffect1:add(smaaPostEffect2)
  smaaPostEffect1:registerObject("SMAA_PostEffect1")

  smaaPostEffect:add(smaaPostEffect1)
  smaaPostEffect:registerObject("SMAA_PostEffect")
end

-- log('I','postfx', 'Smaa.lua calling preProcess()....')
smaaPostEffectCallbacks.preProcess()

-- SMAA T2x. The same three spatial passes, but applied to each of the two jitter phases the
-- UpscaleMode::SMAAT2x render view alternates between, and resolved against the previous phase by
-- the PostFxSMAAT2xResolve child. It runs on the AfterPostFX bin so it sees the tone mapped image
-- and the untouched VelocityBuffer, before the vehicle motion blur velocity repaint.

local smaaT2xEdgeDetectionShaderData = scenetree.findObject("SMAA_T2X_EdgeDetectionShaderData")
if not smaaT2xEdgeDetectionShaderData then
  smaaT2xEdgeDetectionShaderData = createObject("ShaderData")
  smaaT2xEdgeDetectionShaderData.DXComputShaderName    = "shaders/common/postFx/smaa/smaa_edgeDetection.cs.hlsl"
  smaaT2xEdgeDetectionShaderData.pixVersion = 5.0
  smaaT2xEdgeDetectionShaderData:setField("defines", 0, "SMAA_T2X=1")
  smaaT2xEdgeDetectionShaderData:setField("samplerNames", 0, "$colorTexGamma")
  smaaT2xEdgeDetectionShaderData:registerObject("SMAA_T2X_EdgeDetectionShaderData")
end

local smaaT2xBlendingWeightShaderData = scenetree.findObject("SMAA_T2X_BlendingWeightShaderData")
if not smaaT2xBlendingWeightShaderData then
  smaaT2xBlendingWeightShaderData = createObject("ShaderData")
  smaaT2xBlendingWeightShaderData.DXComputShaderName    = "shaders/common/postFx/smaa/smaa_blendingWeight.cs.hlsl"
  smaaT2xBlendingWeightShaderData.pixVersion = 5.0
  smaaT2xBlendingWeightShaderData:setField("defines", 0, "SMAA_T2X=1")
  smaaT2xBlendingWeightShaderData:setField("samplerNames", 0, "$edgesTex")
  smaaT2xBlendingWeightShaderData:setField("samplerNames", 1, "$areaTex")
  smaaT2xBlendingWeightShaderData:setField("samplerNames", 2, "$searchTex")
  smaaT2xBlendingWeightShaderData:registerObject("SMAA_T2X_BlendingWeightShaderData")
end

local smaaT2xNeighborhoodBlendingShaderData = scenetree.findObject("SMAA_T2X_NeighborhoodBlendingShaderData")
if not smaaT2xNeighborhoodBlendingShaderData then
  smaaT2xNeighborhoodBlendingShaderData = createObject("ShaderData")
  smaaT2xNeighborhoodBlendingShaderData.DXComputShaderName    = "shaders/common/postFx/smaa/smaa_NeighborhoodBlending.cs.hlsl"
  smaaT2xNeighborhoodBlendingShaderData.pixVersion = 5.0
  smaaT2xNeighborhoodBlendingShaderData:setField("defines", 0, "SMAA_REPROJECTION=1")
  smaaT2xNeighborhoodBlendingShaderData:setField("samplerNames", 0, "$colorTex")
  smaaT2xNeighborhoodBlendingShaderData:setField("samplerNames", 1, "$blendTex")
  smaaT2xNeighborhoodBlendingShaderData:setField("samplerNames", 2, "$velocityTex")
  smaaT2xNeighborhoodBlendingShaderData:registerObject("SMAA_T2X_NeighborhoodBlendingShaderData")
end

local smaaT2xPostEffectCallbacks = {}
smaaT2xPostEffectCallbacks.onEnabled = function()
  local fxaaPostFx = scenetree.findObject("FXAA_PostEffect")
  if fxaaPostFx then
    fxaaPostFx:disable()
  end
  local smaa1xPostFx = scenetree.findObject("SMAA_PostEffect")
  if smaa1xPostFx then
    smaa1xPostFx:disable()
  end
  return true
end

smaaT2xPostEffectCallbacks.preProcess = function()
  local pfx = scenetree.findObject("SMAA_T2X_PostEffect")
  if not pfx then return end
  local pfx1 = scenetree.findObject("SMAA_T2X_PostEffect1")
  local pfx2 = scenetree.findObject("SMAA_T2X_PostEffect2")

  local rtSize = pfx:getRenderTargetSize()
  local rtResolution = string.format("%f %f %f %f", 1.0 / rtSize.x, 1.0 / rtSize.y, rtSize.x, rtSize.y)
  pfx:setField("rtResolution", 0, rtResolution)
  pfx:setShaderConst("$smaaRtMetrics", rtResolution)
  if pfx1 then pfx1:setShaderConst("$smaaRtMetrics", rtResolution) end
  if pfx2 then pfx2:setShaderConst("$smaaRtMetrics", rtResolution) end

  -- the area texture indices have to match the phase the scene was rasterized with.
  -- all t2x views share the same frame-id jitter, so this does not depend on which view is main.
  if pfx1 then
    local even = (Engine.Render.getFrameId() % 2) == 0
    pfx1:setShaderConst("$smaaSubsampleIndices", even and "1 1 1 0" or "2 2 2 0")
  end
end

rawset(_G, "SMAA_T2X_PostEffectCallbacks", smaaT2xPostEffectCallbacks)

local smaaT2xPostEffect = scenetree.findObject("SMAA_T2X_PostEffect")
if not smaaT2xPostEffect then
  smaaT2xPostEffect = createObject("PostEffect")
  smaaT2xPostEffect.isEnabled = false
  smaaT2xPostEffect.allowReflectPass = false
  smaaT2xPostEffect:setField("renderTime", 0, "PFXAfterBin")
  smaaT2xPostEffect:setField("renderBin", 0, "AfterPostFX")
  smaaT2xPostEffect:setField("texture", 0, "$backBuffer")
  smaaT2xPostEffect:setField("target", 0, "$outTex")
  smaaT2xPostEffect:setField("stateBlock", 0, "SMAA_StateBlock")
  smaaT2xPostEffect:setField("shader", 0, "SMAA_T2X_EdgeDetectionShaderData")

  local smaaT2xPostEffect1 = createObject("PostEffect")
  smaaT2xPostEffect1:inheritParentFields(smaaT2xPostEffect)
  smaaT2xPostEffect1:setField("texture", 0, "$inTex")
  smaaT2xPostEffect1:setField("texture", 1, "shaders/common/postFx/smaa/AreaTexDX9.dds")
  smaaT2xPostEffect1:setField("texture", 2, "shaders/common/postFx/smaa/SearchTex.dds")
  smaaT2xPostEffect1:setField("target", 0, "$outTex")
  smaaT2xPostEffect1:setField("stateBlock", 0, "SMAA_StateBlock")
  smaaT2xPostEffect1:setField("shader", 0, "SMAA_T2X_BlendingWeightShaderData")

  -- unlike 1x this keeps its result in a texture instead of writing the back buffer, the resolve
  -- needs it as its current frame input and its alpha carries the packed velocity magnitude.
  -- The default 8 bit target would clip the tone mapped color and quantize that magnitude far too
  -- coarsely for the reprojection weight, which reads it through a 30x amplification.
  local smaaT2xPostEffect2 = createObject("PostEffect")
  smaaT2xPostEffect2:inheritParentFields(smaaT2xPostEffect1)
  smaaT2xPostEffect2:setField("texture", 0, "$backBuffer")
  smaaT2xPostEffect2:setField("texture", 1, "$inTex")
  smaaT2xPostEffect2:setField("texture", 2, "#VelocityBuffer")
  smaaT2xPostEffect2:setField("target", 0, "$outTex")
  smaaT2xPostEffect2:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  smaaT2xPostEffect2:setField("stateBlock", 0, "SMAA_StateBlock")
  smaaT2xPostEffect2:setField("shader", 0, "SMAA_T2X_NeighborhoodBlendingShaderData")

  local smaaT2xResolve = createObject("PostFxSMAAT2xResolve")
  smaaT2xResolve:registerObject("SMAA_T2X_Resolve")

  smaaT2xPostEffect2:add(smaaT2xResolve)
  smaaT2xPostEffect2:registerObject("SMAA_T2X_PostEffect2")

  smaaT2xPostEffect1:add(smaaT2xPostEffect2)
  smaaT2xPostEffect1:registerObject("SMAA_T2X_PostEffect1")

  smaaT2xPostEffect:add(smaaT2xPostEffect1)
  smaaT2xPostEffect:registerObject("SMAA_T2X_PostEffect")
end

smaaT2xPostEffectCallbacks.preProcess()

-- log('I','postfx', 'Smaa.lua load completed')
