-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local pfxDefaultEdgeAAStateBlock = scenetree.findObject("PFX_DefaultEdgeAAStateBlock")
if not pfxDefaultEdgeAAStateBlock then
  pfxDefaultEdgeAAStateBlock = createObject("GFXStateBlockData")
  pfxDefaultEdgeAAStateBlock.zDefined = true
  pfxDefaultEdgeAAStateBlock.zEnable = false
  pfxDefaultEdgeAAStateBlock.zWriteEnable = false
  pfxDefaultEdgeAAStateBlock.samplersDefined = true
  pfxDefaultEdgeAAStateBlock:setField("samplerStates", 0, "SamplerClampPoint")
  pfxDefaultEdgeAAStateBlock:setField("samplerStates", 1, "SamplerClampPoint")
  pfxDefaultEdgeAAStateBlock:registerObject("PFX_DefaultEdgeAAStateBlock")
end

local pfxEdgeAADetectShader = scenetree.findObject("PFX_EdgeAADetectShader")
if not pfxEdgeAADetectShader then
  pfxEdgeAADetectShader = createObject("ShaderData")
  pfxEdgeAADetectShader.DXComputShaderName    = "shaders/common/postFx/edgeaa/edgeDetect.cs.hlsl"
  pfxEdgeAADetectShader:setField("samplerNames", 0, "prepassBuffer")
  pfxEdgeAADetectShader.pixVersion = 5.0
  pfxEdgeAADetectShader:registerObject("PFX_EdgeAADetectShader")
end

local edgeDetectPostEffect = scenetree.findObject("EdgeDetectPostEffect")
if not edgeDetectPostEffect then
  edgeDetectPostEffect = createObject("PostEffect")
  edgeDetectPostEffect.isEnabled = true
  edgeDetectPostEffect:setField("renderTime", 0, "PFXBeforeBin")
  edgeDetectPostEffect:setField("renderBin", 0, "ObjTranslucentBin")
  -- edgeDetectPostEffect.renderPriority = 0.1
  edgeDetectPostEffect:setField("targetScale", 0, "0.5 0.5")
  edgeDetectPostEffect:setField("shader", 0, "PFX_EdgeAADetectShader")
  edgeDetectPostEffect:setField("stateBlock", 0, "PFX_DefaultEdgeAAStateBlock")
  edgeDetectPostEffect:setField("texture", 0, "#prepass[RT0]")
  edgeDetectPostEffect:setField("texture", 1, "#prepass[Depth]")
  edgeDetectPostEffect:setField("target", 0, "#edge")
  edgeDetectPostEffect:registerObject("EdgeDetectPostEffect")
end
