-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local defaultContrast = 2
local defaultRadius = 1.5

-- PostEffectSSAO only binds setters to lua, so the last applied values are kept here for
-- tools that need to read them back
local currentContrast = defaultContrast
local currentRadius = defaultRadius

local function setContrast(value)
  value = tonumber(value)
  if not value then return end
  currentContrast = value
  local ssaoPostFx = scenetree.findObject("SSAOPostFx")
  if ssaoPostFx then
    ssaoPostFx:setContrast(value)
  end
end

local function setRadius(value)
  value = tonumber(value)
  if not value then return end
  currentRadius = value
  local ssaoPostFx = scenetree.findObject("SSAOPostFx")
  if ssaoPostFx then
    ssaoPostFx:setRadius(value)
  end
end

local function applyDefaults()
  VariableRegistry.set("$SSAOPostFx::Enable", true)
  setContrast(defaultContrast)
  setRadius(defaultRadius)
end

M.applyDefaults = applyDefaults
M.setContrast = setContrast
M.setRadius = setRadius
M.getContrast = function() return currentContrast end
M.getRadius = function() return currentRadius end

-- Inspect the generated world-space bent-normal map without changing materials.
-- This debug effect is created on demand and has no cost while disabled.
M.setBentNormalDebugEnabled = function(enabled)
  local effect = scenetree.findObject("GTAOBentNormalsVizPostFx")
  if enabled and not effect then
    local shader = createObject("ShaderData")
    shader.DXComputShaderName = "shaders/common/postFx/gtao/visualizeBentNormals.cs.hlsl"
    shader.pixVersion = 5.0
    shader:setField("samplerNames", 0, "$inputTex")
    shader:registerObject("GTAOBentNormalsVizShader")
    effect = createObject("PostEffect")
    effect.allowReflectPass = false
    effect.renderPriority = 9999
    effect:setField("renderTime", 0, "PFXAfterDiffuse")
    effect:setField("shader", 0, "GTAOBentNormalsVizShader")
    effect:setField("stateBlock", 0, "PFX_DefaultStateBlock")
    effect:setField("texture", 0, "#gtaoOutput")
    effect:setField("target", 0, "$backBuffer")
    effect:registerObject("GTAOBentNormalsVizPostFx")
  end
  if effect then
    if enabled then effect:enable() else effect:disable() end
  end
end

local ssaoPostFx = scenetree.findObject("SSAOPostFx")
if not ssaoPostFx then
  ssaoPostFx = createObject("PostEffectSSAO")
  ssaoPostFx:registerObject("SSAOPostFx")
  applyDefaults()
end
ssaoPostFx.bentNormals = settings.getValue("PostFXSpecularOcclusionEnabled") == true

local ssaoVizPostFx = scenetree.findObject("SSAOVizPostFx")
if not ssaoVizPostFx then
  ssaoVizPostFx = createObject("PostEffectSSAO")
  ssaoVizPostFx.allowReflectPass = false
  ssaoVizPostFx:setField("shader", 0, "PFX_PassthruShader")
  ssaoVizPostFx:setField("stateBlock", 0, "PFX_DefaultStateBlock")
  ssaoVizPostFx:setField("texture", 0, "#ssaoMask")
  ssaoVizPostFx:setField("target", 0, "$backBuffer")
  ssaoVizPostFx:registerObject("SSAOVizPostFx")
end

return M