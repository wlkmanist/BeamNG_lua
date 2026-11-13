-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local bl_ShadowFilterShaderV = scenetree.findObject("BL_ShadowFilterShaderV")
if not bl_ShadowFilterShaderV then
  bl_ShadowFilterShaderV = createObject("ShaderData")
  bl_ShadowFilterShaderV.DXComputShaderName = "shaders/common/lighting/basic/shadowFilter.cs.hlsl"
  bl_ShadowFilterShaderV:setField("samplerNames", 0, "$diffuseMap")
  bl_ShadowFilterShaderV:setField("defines", 0, "BLUR_DIR=float2(1.0,0.0)")
  bl_ShadowFilterShaderV.pixVersion = 5.0;
  bl_ShadowFilterShaderV:registerObject("BL_ShadowFilterShaderV")
end

local bl_ShadowFilterShaderH = scenetree.findObject("BL_ShadowFilterShaderH")
if not bl_ShadowFilterShaderH then
  bl_ShadowFilterShaderH = createObject("ShaderData")
  bl_ShadowFilterShaderH:inheritParentFields(bl_ShadowFilterShaderV)
  bl_ShadowFilterShaderH:setField("defines", 0, "BLUR_DIR=float2(0.0,1.0)")
  bl_ShadowFilterShaderH:registerObject("BL_ShadowFilterShaderH")
end

-- NOTE: This is ONLY used in Basic Lighting, and
-- only directly by the ProjectedShadow.  It is not
-- meant to be manually enabled like other PostEffects.
-- Blur horizontal
local bl_ShadowFilterPostFx = scenetree.findObject("BL_ShadowFilterPostFx")
if not bl_ShadowFilterPostFx then
  local bl_ShadowFilterShaderH = createObject("PostEffect")
  bl_ShadowFilterShaderH:setField("shader", 0, "BL_ShadowFilterShaderH")
  bl_ShadowFilterShaderH:setField("stateBlock", 0, "PFX_DefaultStateBlock")
  bl_ShadowFilterShaderH:setField("texture", 0, "$inTex")
  bl_ShadowFilterShaderH:setField("target", 0, "$outTex")
  bl_ShadowFilterShaderH:registerObject()

  -- Blur vertically
  bl_ShadowFilterPostFx = createObject("PostEffect")
  bl_ShadowFilterPostFx:setField("shader", 0, "BL_ShadowFilterShaderV")
  bl_ShadowFilterPostFx:setField("stateBlock", 0, "PFX_DefaultStateBlock")
  bl_ShadowFilterPostFx:setField("texture", 0, "$inTex")
  bl_ShadowFilterPostFx:setField("target", 0, "$outTex")
  bl_ShadowFilterPostFx:add(bl_ShadowFilterShaderH)
  bl_ShadowFilterPostFx:registerObject("BL_ShadowFilterPostFx")
end