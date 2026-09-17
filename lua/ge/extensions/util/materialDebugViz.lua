-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local vec2 = im.ImVec2

local materialDebugVisualizationType = im.IntPtr(0)
local materialDebugVisualizationTypes = nil
local materialDebugEnabled = false
local lastLegendFrameId = nil


local renderDebugFlags = {
  FlagsDebugNone = 0,
  FlagsDebugBaseColor = bit.lshift(1,0),
  FlagsDebugOpacity = bit.lshift(1,1),
  FlagsDebugMetallic = bit.lshift(1,2),
  FlagsDebugRoughness = bit.lshift(1,3),
  FlagsDebugAmbientOcclusion = bit.lshift(1,4),
  FlagsDebugClearCoat = bit.lshift(1,5),
  FlagsDebugClearCoatRoughness = bit.lshift(1,6),
  FlagsDebugUV0 = bit.lshift(1,7),
  FlagsDebugUV0Checkerboard = bit.lshift(1,8),
  FlagsDebugUV0ColorGrid = bit.lshift(1,9),
  FlagsDebugUV1 = bit.lshift(1,10),
  FlagsDebugUV1Checkerboard = bit.lshift(1,11),
  FlagsDebugUV1ColorGrid = bit.lshift(1,12),
  FlagsDebugMaterialDeprecated = bit.lshift(1,13),
  FlagsDebugLayerCount = bit.lshift(1,14),
  FlagsDebugNormalsWS = bit.lshift(1,15),
  FlagsDebugEmissive = bit.lshift(1,16),
  FlagsDebugTriangleSize = bit.lshift(1,17),
  FlagsDebugMipBaseColor = bit.lshift(1,18),
  FlagsDebugMaterialWireframe = bit.lshift(1,19)
}


local tdGrad, gradTexSize = nil, Point2I(0,0)

local function _ensureGradTD(w, h)
  w = math.max(1, math.floor(w))
  h = math.max(1, math.floor(h))
  if not tdGrad or gradTexSize.x ~= w or gradTexSize.y ~= h then
    gradTexSize = Point2I(w, h)
    tdGrad = TextureDrawPrimitiveRegistry:getOrCreate("legendGradient", gradTexSize.x, gradTexSize.y)
    tdGrad:setWidthHeight(w, h)
  end
  return tdGrad
end

local function _colf(r, g, b, a)
  return color(
    math.floor((r or 0) * 255 + 0.5),
    math.floor((g or 0) * 255 + 0.5),
    math.floor((b or 0) * 255 + 0.5),
    math.floor((a or 1) * 255 + 0.5)
  )
end

local function _uiScale(v) return v * im.uiscale[0] end

local function _packColor(r, g, b, a)
  local function to8(x) return math.floor((x or 0) * 255 + 0.5) end
  return bit.bor(bit.lshift(to8(a or 1), 24), bit.lshift(to8(b), 16), bit.lshift(to8(g), 8), to8(r))
end

local function _bullet(text)
  im.Bullet()
  im.SameLine()
  im.TextUnformatted(text)
end

local function _jetRGB(t)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local r = math.max(0, math.min(1, 4 * t - 2))
  local g = math.max(0, math.min(1, 2 - math.abs(4 * t - 2)))
  local b = math.max(0, math.min(1, 2 - 4 * t))
  return r,g,b
end

local function _drawGradient(w, h, colorAtT, segments)
  segments = segments or 64
  w = math.max(1, math.floor(w))
  h = math.max(1, math.floor(h))
  local td = _ensureGradTD(w, h)
  local segW = w / segments
  local y0, y1 = 0, h

  for i = 0, segments - 1 do
    local t0 = i / segments
    local t1 = (i + 1) / segments
    local x0 = i * segW
    local x1 = x0 + segW

    local r0,g0,b0 = colorAtT(t0)
    local r1,g1,b1 = colorAtT(t1)

    local c0 = _colf(r0, g0, b0, 1)
    local c1 = _colf(r1, g1, b1, 1)

    td:triangle(x0, y0, x1, y0, x1, y1, 0, 0, c0, c1, c1, 0, 0, 0)
    td:triangle(x0, y0, x1, y1, x0, y1, 0, 0, c0, c1, c0, 0, 0, 0)
  end

  local bc = _colf(1,1,1,0.35)
  local s = 1
  td:line(0,0,w,0,s,s,0,0,bc,bc,bc,bc,0,0)
  td:line(0,h,w,h,s,s,0,0,bc,bc,bc,bc,0,0)
  td:line(0,0,0,h,s,s,0,0,bc,bc,bc,bc,0,0)
  td:line(w,0,w,h,s,s,0,0,bc,bc,bc,bc,0,0)

  td:ImGui_Image(w, h)
end

local function _colorChip(label, rgb)
  im.ColorButton("##"..label, im.ImVec4(rgb[1], rgb[2], rgb[3], 1),
    im.flags(im.ColorEditFlags_NoTooltip),
    vec2(_uiScale(18), _uiScale(18)))
  im.SameLine()
  im.TextUnformatted(label)
end

local function _makeMipChips(count)
  local chips = {}
  for i = 0, count - 1 do
    local t = (count > 1) and (i / (count - 1)) or 0
    local r, g, b = _jetRGB(t)
    local label = (i == 0) and "Mipmap LOD 0 (full resolution)" or ("Mipmap LOD " .. i)
    table.insert(chips, { label, { r, g, b } })
  end
  if count > 1 then
    chips[#chips][1] = ("Mipmap LOD %d (minimum resolution)"):format(count - 1)
  end
  table.insert(chips, { "No Base Color Texture", { 0.1, 0.1, 0.1 } })
  return chips
end

local uvEncodeBullets = {
  "R = U, G = V (wrapped into [0..1])",
  "Negative UVs are wrapped into [0..1]"
}

local uvCheckerBullets = {
  "Tile size = 0.25",
  "Shows parity of floor(U/size) + floor(V/size)"
}

local uvColorGridBullets = {
  "Hue stripes horizontally, grid lines every 32 px",
  "Overlaid checkers at sizes 2, 8, 64, 256"
}


local legendDefs = {
  Material_TriSize = {
    title = "Quad Overdraw",
    gradient = "jet",
    labels = {"Large\n(100% of GPU power utilized)", "Small\n(75% of GPU power wasted)"},
    bullets = {"Works only in Vulkan API or Direct3D12","Shows how much GPU power is being wasted in scene","Small or skinny triangles increase GPU overdraw and reduce performance,\nbecause the GPU still processes them even when they're too small to affect the final image","Overdraw levels will depend on your screen/render resolution,\nthe lower screen resolution the higher chances of more severe overdraw"}
  },
  Material_Wireframe = { title = "Opaque Wireframe", bullets = {"Shows wireframe on top of baseColor"} },
  Material_Mip = {
    title = "Base Color Mip Level",
    chips = _makeMipChips(12),
    bullets = {"Works only in Vulkan API or Direct3D12","Shows how much of texture initial resolution is used to render base color texture in material","Each mipmap LOD level is half size of previous level","Mipmap LOD levels will depent on your screen/render resolution,\nthe lower screen resolution the lower mipmap LOD levels are being used"}
  },
  Material_BaseColor = { title = "Base Color (Albedo)", bullets = {"Shows the final baseColor of the material"} },
  Material_Opacity   = { title = "Opacity (grayscale)", gradient = "bw", labels = {"0 (transparent)", "1 (opaque)"} },
  Material_Metallic  = { title = "Metallic (grayscale)", gradient = "bw", labels = {"0 (dielectric)", "1 (metal)"} },
  Material_Roughness = { title = "Roughness (grayscale)", gradient = "bw", labels = {"0 (smooth)", "1 (rough)"} },
  Material_AmbientOcclusion = { title = "Ambient Occlusion (grayscale)", gradient = "bw", labels = {"0 (occluded)", "1 (unoccluded)"} },
  Material_ClearCoat = { title = "Clear Coat (grayscale)", gradient = "bw", labels = {"0 (none)", "1 (full)"} },
  Material_ClearCoatRoughness = { title = "Clear Coat Roughness (grayscale)", gradient = "bw", labels = {"0 (smooth)", "1 (rough)"} },
  Material_UV0 = { title = "UV0 color encode", bullets = uvEncodeBullets },
  Material_UV1 = { title = "UV1 color encode", bullets = uvEncodeBullets },
  Material_UV0Checkerboard = { title = "UV0 Checkerboard", bullets = uvCheckerBullets },
  Material_UV1Checkerboard = { title = "UV1 Checkerboard", bullets = uvCheckerBullets },
  Material_UV0ColorGrid = { title = "UV0 Color Grid", bullets = uvColorGridBullets },
  Material_UV1ColorGrid = { title = "UV1 Color Grid", bullets = uvColorGridBullets },
  Material_NormalsWS = {
    title = "Normals (World Space)",
    bullets = { "R = X, G = Y, B = Z", "Components mapped from [-1..1] to [0..1]" }
  },
  Material_Emissive = { title = "Emissive", bullets = {"Shows emissive color"} },
  Material_MaterialDeprecated = {
    title = "Material Deprecated",
    chips = { {"Deprecated", {1,0,0}}, {"New", {0,1,0}} },
    bullets = {"Brightness is modulated by Ambient Occlusion"}
  },
  Material_LayerCount = {
    title = "Layer Count (deprecated pipeline)",
    chips = {
      {"New material", {0,0,1}},
      {"1 Layer",      {0,1,0}},
      {"2 Layer",      {1/3, 2/3, 0}},
      {"3 Layer",      {2/3, 1/3, 0}},
      {"4 Layer",      {1,0,0}}
    }
  }
}

local function _drawLegendForMaterialName(name)
  local def = legendDefs[name]
  if not def then return false end

  im.TextUnformatted(def.title or name)

  local w, h = _uiScale(640), _uiScale(24)

  if def.gradient then
    local palettes = {
      jet = function(t) local r,g,b = _jetRGB(t) return r,g,b end,
      bw  = function(t) return t, t, t end
    }
    local colorAtT = palettes[def.gradient] or palettes.bw
    _drawGradient(w, h, colorAtT, def.gradient == "jet" and 96 or 64)
  end

  if def.chips then
    for _, chip in ipairs(def.chips) do _colorChip(chip[1], chip[2]) end
    im.NewLine()
  end

  if def.bullets then
    for _, b in ipairs(def.bullets) do _bullet(b) end
  end

  return true
end

local function materialDebugSetter(flag)
  materialDebugSetFlag(flag)
  local enabled = flag ~= renderDebugFlags.FlagsDebugNone
  if materialDebugEnabled == enabled then return end

  materialDebugEnabled = enabled
  enableMaterialDebug(enabled)
end

function M.onExtensionLoaded()
  materialDebugVisualizationTypes = {
    {type="Custom", name="Material_None", displayName="None",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugNone) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugNone end},

    {type="Custom", name="Material_TriSize", displayName="Quad Overdraw",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugTriangleSize) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugTriangleSize end},

    {type="Custom", name="Material_Wireframe", displayName="Wireframe",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugMaterialWireframe) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugMaterialWireframe end},

    {type="Custom", name="Material_Mip", displayName="Base Color Mip Level",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugMipBaseColor) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugMipBaseColor end},

    {type="Custom", name="Material_BaseColor", displayName="Base Color",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugBaseColor) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugBaseColor end},

    {type="Custom", name="Material_Opacity", displayName="Opacity",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugOpacity) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugOpacity end},

    {type="Custom", name="Material_Metallic", displayName="Metallic",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugMetallic) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugMetallic end},

    {type="Custom", name="Material_Roughness", displayName="Roughness",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugRoughness) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugRoughness end},

    {type="Custom", name="Material_NormalsWS", displayName="Normals World Space",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugNormalsWS) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugNormalsWS end},

    {type="Custom", name="Material_AmbientOcclusion", displayName="Ambient Occlusion",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugAmbientOcclusion) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugAmbientOcclusion end},

    {type="Custom", name="Material_Emissive", displayName="Emissive",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugEmissive) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugEmissive end},

    {type="Custom", name="Material_ClearCoat", displayName="Clear Coat",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugClearCoat) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugClearCoat end},

    {type="Custom", name="Material_ClearCoatRoughness", displayName="Clear Coat Roughness",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugClearCoatRoughness) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugClearCoatRoughness end},

    {type="Custom", name="Material_UV0", displayName="UV0",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugUV0) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugUV0 end},

    {type="Custom", name="Material_UV0Checkerboard", displayName="UV0 Checkerboard",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugUV0Checkerboard) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugUV0Checkerboard end},

    {type="Custom", name="Material_UV0ColorGrid", displayName="UV0 Color Grid",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugUV0ColorGrid) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugUV0ColorGrid end},

    {type="Custom", name="Material_UV1", displayName="UV1",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugUV1) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugUV1 end},

    {type="Custom", name="Material_UV1Checkerboard", displayName="UV1 Checkerboard",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugUV1Checkerboard) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugUV1Checkerboard end},

    {type="Custom", name="Material_UV1ColorGrid", displayName="UV1 Color Grid",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugUV1ColorGrid) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugUV1ColorGrid end},

    {type="Custom", name="Material_MaterialDeprecated", displayName="Deprecated Material",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugMaterialDeprecated) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugMaterialDeprecated end},

    {type="Custom", name="Material_LayerCount", displayName="Layer Count",
      setter=function() materialDebugSetter(renderDebugFlags.FlagsDebugLayerCount) end,
      getter=function() return materialDebugGetFlag()==renderDebugFlags.FlagsDebugLayerCount end}
  }

  materialDebugEnabled = materialDebugGetFlag() ~= renderDebugFlags.FlagsDebugNone

  for k,v in ipairs(materialDebugVisualizationTypes) do
    if v.getter() then
      materialDebugVisualizationType[0] = (k-1)
      return
    end
  end
end

function M.getTypes() return materialDebugVisualizationTypes end
function M.getIndexPtr() return materialDebugVisualizationType end

function M.drawLegendWindow()
  local showLegend = editor and editor.getPreference and editor.getPreference("gizmos.visualization.showMaterialDebugLegend") or true
  if showLegend == false then return end

  if not materialDebugVisualizationTypes then return end

  local idx = materialDebugVisualizationType[0] or 0
  local activeType = materialDebugVisualizationTypes[idx + 1]
  if not activeType or activeType.name == "Material_None" or not legendDefs[activeType.name] then return end

  local frameId = Engine and Engine.Render and Engine.Render.getFrameId and Engine.Render.getFrameId()
  if frameId and lastLegendFrameId == frameId then return end
  lastLegendFrameId = frameId

  local vp = im.GetMainViewport and im.GetMainViewport()
  local pos
  if vp then
    pos = vec2(vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y * 0.8)
  end

  im.SetNextWindowPos(pos, im.Cond_Always, vec2(0.5, 0.5))
  im.SetNextWindowBgAlpha(0.85)

  local flags = im.flags(
    im.WindowFlags_AlwaysAutoResize,
    im.WindowFlags_NoTitleBar,
    im.WindowFlags_NoMove,
    im.WindowFlags_NoSavedSettings,
    im.WindowFlags_NoDocking,
    im.WindowFlags_NoFocusOnAppearing,
    im.WindowFlags_NoNav
  )

  if im.Begin("Material Debug Legend##overlay", nil, flags) then
    _drawLegendForMaterialName(activeType.name)
  end
  im.End()
end

local function _findTypeIndexByName(name)
  if not materialDebugVisualizationTypes then return nil end
  for i, v in ipairs(materialDebugVisualizationTypes) do
    if v.name == name then
      return i - 1
    end
  end
  return nil
end

function M.set(mode)
  if not materialDebugVisualizationTypes then M.onExtensionLoaded() end

  if not mode or mode == "Material_None" then
    materialDebugVisualizationType[0] = 0
    materialDebugSetter(renderDebugFlags.FlagsDebugNone)
    return
  end

  local idx = _findTypeIndexByName(mode)
  if not idx then
    log("E", "materialDebugViz", "Unknown mode: " .. tostring(mode))
    return
  end

  materialDebugVisualizationType[0] = idx
  materialDebugVisualizationTypes[idx + 1].setter()
end

M.onUpdate = M.drawLegendWindow

return M
