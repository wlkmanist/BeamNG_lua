-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local maxDecalRoadNodes = 500 -- Absolute resampled-node cap for a single DecalRoad section (chunking is decided on the FINAL resampled node count, not the raw divPoint count). In practice the arc-length cap below bites first; this is just a hard ceiling.
local maxDecalRoadLenM = 250 -- Max arc length (m) per emitted DecalRoad section. The engine packs each DecalRoad into a 16-bit-indexed GPU buffer, so ONE object whose clipped vertex count passes 65535 drops its far end from the render -- wide overlays (asphalt variation / treadmarks / edge blends) on a long road hit this. Sectioning by length keeps every object well under the limit; consecutive sections join C1-continuous (start/endTangent handles) so there's no visible seam.

local decalResampleM = 8.0
local edgeLineResampleM = 4.0
local decalWeldMinLenM = 0.05 -- Min decal segment length (m). Safety weld after resampling: a ~0-length segment makes improvedSpline normalize a zero tangent and emit inf/overshoot verts, crashing the DecalRoad batcher.
local defaultDecalRoadDetail = 0.1
local decalDrapeHeight = 2.0 -- Raise decal nodes this many metres above the road so overObjects projects them DOWN onto the mesh (roadNetwork-style draping).
local markingFrayFadeM = 0.4 -- Short DecalRoad end-fade (m) at a cut made by a pothole: fakes the worn/frayed paint edge round the hole (NOT a long designed fade).
local defaultMaterial = "road_invisible"

local laneWidth = 5.0 -- Fallback lane width (m) if a group has no laneWidthM set.

local lightTreadMarksTexLen = 5
local lightTreadMaterial = 'm_tread_marks_clean'
local lightTreadStr = "Light Tread Marks"

local heavyTreadMarksTexLen = 5
local heavyTreadMaterial = 'road_rubber_double'
local heavyTreadStr = "Heavy Tread Marks"

local roadCrackTexLen = 15
local roadCrackMaterial = 'm_asphalt_cracks_02'
local roadCrackStr = "Road Crack"

local repair1TexLen = 25
local repair1Material = 'repair1'
local repair1Str = "Repair 1"

local repair2TexLen = 25
local repair2Material = 'repair2'
local repair2Str = "Repair 2"

local patchesTexLen = 45
local patchesMaterial = 'road_patches1'
local patchesStr = "Patches"

local damageAsphalt1TexLen = 10
local damageAsphalt1Material = 'm_asphalt_damaged_01'
local damageAsphalt1Str = "Damage Asphalt 1"

local damageAsphalt2TexLen = 25
local damageAsphalt2Material = 'm_asphalt_damaged_02'
local damageAsphalt2Str = "Damage Asphalt 2"

local roadCenterLineMaterial = 'm_line_yellow_double' -- USA-style opposing-traffic divider: solid double yellow.
local roadCenterLineStr = "Center Line"
local defaultCenterlineWidth = 0.2
local defaultCenterlineTexLen = 5.0

local roadEdgeLineMaterial = 'm_line_white'
local roadEdgeLineStr = "Edge Line"
local defaultEdgeLineWidth = 0.25

local roadLaneLineMaterial = 'm_line_white_discontinue'
local roadLaneLineStr = "Lane Line"
local defaultLaneLineWidth = 0.2

-- Only actual PAINTED lines get cut by potholes (the paint leaves with the pavement). Wear/tread/crack/patch/damage/blend
-- overlays are surface grime that reads as continuous, so they carry straight through the hole.
local paintLineMaterials = {
  [roadCenterLineMaterial] = true,
  [roadEdgeLineMaterial] = true,
  [roadLaneLineMaterial] = true,
}

local roadEdgeBlend1Material = 'm_road_asphalt_edge'
local roadEdgeBlend1Str = "Edge Blend 1"
local defaultEdgeBlend1Width = 1.0
local defaultEdgeBlend1TexLen = 10.0
local defaultEdgeBlend1LatPos = 1.1

local roadEdgeBlend2Material = 'm_road_edge_dirt'
local roadEdgeBlend2Str = "Edge Blend 2"
local defaultEdgeBlend2Width = 2.0
local defaultEdgeBlend2TexLen = 10.0
local defaultEdgeBlend2LatPos = 1.25

local roadEdgeBlend3Material = 'm_road_asphalt_edge_grass'
local roadEdgeBlend3Str = "Edge Blend 3"
local defaultEdgeBlend3Width = 3.0
local defaultEdgeBlend3TexLen = 10.0
local defaultEdgeBlend3LatPos = 1.35

-- The default values for the slider properties, so they can be reset to their default values.
local sliderDefaults = {
  defaultWidth = 10.0,
  defaultLateralPosition = 0.0,
  defaultRenderPriority = 10,
  defaultTexLength = 10.0,
  defaultFadeIn = 1.0,
  defaultFadeOut = 1.0,
  defaultPaintMargin = 0.0,
  defaultPaintMaterialIdx = 0,
}

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local buffer = require('string.buffer')
local geom = require('editor/toolUtilities/geom')
local repairMgr = require('editor/heroRoadEditor/repairMgr')
local regionStyles = require('editor/toolUtilities/regionStyles')

-- Module constants.
local min, max, floor, ceil, sqrt, huge, abs = math.min, math.max, math.floor, math.ceil, math.sqrt, math.huge, math.abs
local sin, asin = math.sin, math.asin

-- Module state.
local tmp1 = vec3()

-- Returns the default values for the slider properties, for use in the tool's front end.
local function getSliderDefaults() return sliderDefaults end

local function isEdgeLineLayer(layer)
  return layer and layer.name and string.find(layer.name, roadEdgeLineStr, 1, true) ~= nil
end

-- Edge-blend layers (the asphalt/dirt/grass fade strips outside the edge line).
local function isEdgeBlendLayer(layer)
  return layer ~= nil and layer.name ~= nil and (
    string.find(layer.name, roadEdgeBlend1Str, 1, true) ~= nil or
    string.find(layer.name, roadEdgeBlend2Str, 1, true) ~= nil or
    string.find(layer.name, roadEdgeBlend3Str, 1, true) ~= nil)
end

-- Layers that follow the road EDGE and so must bevel round a junction bell + break across its mouth: the edge line and the
-- edge-blend strips just outside it.
local function isEdgeFollowLayer(layer)
  return (layer ~= nil and layer.isEdge == true) or isEdgeLineLayer(layer) or isEdgeBlendLayer(layer)
end

-- Which side of the road the layer sits on: -1 = left, +1 = right. An Edge layer uses its chosen side, others their position.
local function layerSideSign(layer)
  if layer.isEdge == true then return layer.edgeSide == 'left' and -1.0 or 1.0 end
  return layer.position < 0 and -1.0 or 1.0
end

-- Is this a painted lane/edge/centre line (the only kind of layer a pothole cuts)?
local function isPaintLineLayer(layer)
  return layer ~= nil and layer.material ~= nil and paintLineMaterials[layer.material] == true
end

-- Uniform resample spacing for a decal layer: edge lines resample finer so the smooth line keeps hugging the mesh
-- edge on bends; other markings/overlays use the coarser spacing.
local function decalResampleSpacing(layer)
  return isEdgeLineLayer(layer) and edgeLineResampleM or decalResampleM
end

-- Max resampled nodes per emitted DecalRoad section: the smaller of the absolute node cap and the arc-length cap (converted to a
-- node count at this layer's resample spacing). Keeps each DecalRoad's clipped vertex count under the engine's 16-bit index limit.
local function sectionMaxNodes(layer)
  return max(2, min(maxDecalRoadNodes, floor(maxDecalRoadLenM / decalResampleSpacing(layer)) + 1))
end

-- Deep copies a layer. The runtime geometry buffers (pClipped/pFlip hold vec3 cdata that buffer.encode can't
-- serialise) are detached from the SOURCE before encoding and restored afterwards -- so copying never wipes the
-- source layer's live geometry (the old version cleared it in place, a destructive side effect). The copy starts
-- with fresh empty buffers; they are rebuilt on the next updateLayer.
local function deepCopyLayer(layer)
  local pC, wC, pF, wF = layer.pClipped, layer.wClipped, layer.pFlip, layer.wFlip
  layer.pClipped, layer.wClipped, layer.pFlip, layer.wFlip = nil, nil, nil, nil
  local copy = buffer.decode(buffer.encode(layer))
  layer.pClipped, layer.wClipped, layer.pFlip, layer.wFlip = pC, wC, pF, wF
  copy.pClipped, copy.wClipped, copy.pFlip, copy.wFlip = {}, {}, {}, {}
  return copy
end

-- Deep copies all layers.
local function deepCopyAllLayers(layers)
  local copy = {}
  for i = 1, #layers do
    copy[i] = deepCopyLayer(layers[i])
  end
  return copy
end

-- Removes all decal roads associated with a layer (for chunked layers).
local function removeAllDecalRoadsForLayer(layer)
  if layer.decalRoadIds then
    for i = 1, #layer.decalRoadIds do
      local decalRoad = scenetree.findObjectById(layer.decalRoadIds[i])
      if decalRoad then
        decalRoad:delete()
      end
    end
    layer.decalRoadIds = nil
  end
end

-- Initialise layer.decalRoadIds if it doesn't exist
local function ensureLayerDecalRoadIds(layer)
  if not layer.decalRoadIds then
    layer.decalRoadIds = {}
  end
end

-- Removes the decal road object associated with the given layer, if it exists.
local function removeDecalRoadInLayer(layer)
  if layer.decalRoadId then
    local decalRoad = scenetree.findObjectById(layer.decalRoadId)
    if decalRoad then
      decalRoad:delete()
    end
    layer.decalRoadId = nil
  end
  -- Also remove chunked DecalRoads if they exist
  removeAllDecalRoadsForLayer(layer)
end

local function setIdsCanSave(ids, persist)
  if not ids then return end
  for i = 1, #ids do
    local d = scenetree.findObjectById(ids[i])
    if d then d.canSave = persist end
  end
end

-- Flip canSave on every DecalRoad this group owns (layer singles + chunks, crossings, widening dividers, junction lines) so a
-- level save honours the Edit/Live split: Edit (persist=false) writes nothing; Live/baked (persist=true) writes them with the road.
-- Called on the enable/disable (Edit/Live) toggle and after a bake, since those transitions don't rebuild the decals.
local function setGroupDecalsCanSave(group, persist)
  if not group then return end
  if group.layers then
    for i = 1, #group.layers do
      local layer = group.layers[i]
      local d = layer.decalRoadId and scenetree.findObjectById(layer.decalRoadId)
      if d then d.canSave = persist end
      setIdsCanSave(layer.decalRoadIds, persist)
    end
  end
  setIdsCanSave(group.crossingDecalIds, persist)
  setIdsCanSave(group.wideningDecalIds, persist)
  setIdsCanSave(group.junctionDecalIds, persist)
end

-- Clears chunk data for a group.
local function clearGroupChunks(group)
  table.clear(group.chunkStartIndices)
  table.clear(group.chunkEndIndices)
  group.numChunks = 0
end

-- Adds a chunk to a group.
local function addGroupChunk(group, startIdx, endIdx)
  group.numChunks = group.numChunks + 1
  group.chunkStartIndices[group.numChunks] = startIdx
  group.chunkEndIndices[group.numChunks] = endIdx
end

-- Inserts a decal node, SKIPPING non-finite positions. A single inf/NaN node (from a degenerate binormal or divWidth
-- upstream) makes the engine's DecalRoad batcher push its leaf origin / AABB to +-inf and crash
-- SceneStaticDecalRoadManager on the render thread. Skip the bad node (a tiny gap in the marking) instead of crashing.
-- `ins` is the running 0-based insert index; it only advances on a successful insert so node indices stay contiguous.
local function insertDecalNode(decal, pos, width, ins)
  local x, y, z = pos.x, pos.y, pos.z
  if x ~= x or y ~= y or z ~= z
      or x == huge or x == -huge or y == huge or y == -huge or z == huge or z == -huge then
    return ins
  end
  decal:insertNodeNoRegen(pos, width, ins)
  return ins + 1
end

-- Plan-view (x,y) centreline length of the group.
local function planLength(div)
  local total = 0
  for i = 2, #div do total = total + sqrt((div[i].x - div[i - 1].x) ^ 2 + (div[i].y - div[i - 1].y) ^ 2) end
  return total
end

-- Interpolated centreline frame at normalized arc-length t01: point (px,py,pz) + unit binormal (bx,by,bz, +right of travel),
-- or nil. total is the precomputed plan-view length. Local (not groupMgr.crossingFrame) to keep this file require-cycle free.
local function crossingStationFrame(div, binormals, total, t01)
  local n = #div
  local target = min(max(t01, 0), 1) * total
  local acc = 0
  for i = 1, n - 1 do
    local a, b = div[i], div[i + 1]
    local segLen = sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    if acc + segLen >= target or i == n - 1 then
      local tt = segLen > 1e-9 and min(max((target - acc) / segLen, 0), 1) or 0
      local b0, b1 = binormals[i], binormals[i + 1]
      local bx = b0.x + (b1.x - b0.x) * tt
      local by = b0.y + (b1.y - b0.y) * tt
      local bz = b0.z + (b1.z - b0.z) * tt
      local bl = sqrt(bx * bx + by * by + bz * bz)
      if bl > 1e-9 then bx, by, bz = bx / bl, by / bl, bz / bl end
      return a.x + (b.x - a.x) * tt, a.y + (b.y - a.y) * tt, a.z + (b.z - a.z) * tt, bx, by, bz
    end
    acc = acc + segLen
  end
  return nil
end

-- Build the list of pothole "cut discs" {x,y,r} in plan view (only potholes flagged cutMarkings). A painted line node landing
-- inside any disc is dropped, so the line gaps over the hole -- the paint left with the pavement -- instead of draping into it.
-- The disc is the crater's rim radius (radiusM), so ONLY lines that actually cross the hole are cut and the cut sits right at
-- the rim (not the grown wobble/elongation footprint, which reached out over neighbouring lines). Returns nil = nothing to cut.
local function buildPotholeCutList(group)
  local pot = group and group.potholes
  if not pot or #pot == 0 then return nil end
  local div, binormals = group.divPoints, group.binormals
  if not div or #div < 2 or not binormals then return nil end
  local total = planLength(div)
  if total <= 1e-6 then return nil end
  local cuts, n = nil, 0
  for i = 1, #pot do
    local ph = pot[i]
    if ph.cutMarkings ~= false then
      local px, py, _, bx, by = crossingStationFrame(div, binormals, total, ph.t or 0.5)
      if px then
        local latM = ph.lateralM or 0.0
        n = n + 1
        cuts = cuts or {}
        -- Round cut disc sized to the crater's widest half-extent (length/width ellipse), falling back to the legacy radiusM.
        local halfSpan = max((ph.lengthM or 0) * 0.5, (ph.widthM or 0) * 0.5, ph.radiusM or 2.0)
        cuts[n] = { x = px + bx * latM, y = py + by * latM, r = max(0.1, halfSpan) }
      end
    end
  end
  return cuts
end

-- True if plan point (x,y) falls inside any cut disc.
local function pointInCuts(cuts, x, y)
  for i = 1, #cuts do
    local c = cuts[i]
    local dx, dy = x - c.x, y - c.y
    if dx * dx + dy * dy < c.r * c.r then return true end
  end
  return false
end

-- Linear-interpolated carriageway width at plan arc fraction t01 (used to place a layer's cut discs on its own line).
local function widthAtArc(div, divWidths, total, t01)
  local target = min(max(t01, 0), 1) * total
  local acc = 0
  for i = 1, #div - 1 do
    local a, b = div[i], div[i + 1]
    local segLen = sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    if acc + segLen >= target or i == #div - 1 then
      local tt = segLen > 1e-9 and min(max((target - acc) / segLen, 0), 1) or 0
      return (divWidths[i] or 0) * (1 - tt) + (divWidths[i + 1] or 0) * tt
    end
    acc = acc + segLen
  end
  return divWidths[1] or 0
end

-- Break an edge-following line (edge line OR edge blend) across a junction MOUTH. The line already bevels round the bell (the
-- widening bulge pushes it out over the whole flare); this only drops the nodes over the THROAT (the mouth opening) on the
-- junction side, so the line WRAPS round the two bevels and stops at the joining end -- it does NOT gap the bevels or run far
-- along the trunk. Discs are placed on the layer's OWN (bulged) lateral position so each edge/blend strip breaks in step.
-- Returns a list of {x,y,r} discs, or nil when nothing on this side breaks.
local function buildJunctionEdgeCuts(group, layer)
  local list = group.junctions
  if not list or #list == 0 then return nil end
  local div, binormals, divWidths = group.divPoints, group.binormals, group.divWidths
  if not div or #div < 2 or not binormals or not divWidths then return nil end
  local total = planLength(div)
  if total <= 1e-6 then return nil end
  local wantLeft = layerSideSign(layer) < 0
  local isEdge = layer.isEdge == true
  local posFrac = isEdge and 0.5 or abs(layer.position) * 0.5 -- this line's lateral fraction of the half-width (edge line ~0.5, blends a bit more).
  local edgeOff = isEdge and (layer.edgeOffsetM or 0.0) or 0.0
  local cuts, n = nil, 0
  for j = 1, #list do
    local jn = list[j]
    if jn.breakEdge and ((jn.side == 'left') == wantLeft) then
      local sgn = jn.side == 'left' and -1.0 or 1.0
      local flare = max(0.0, jn.flareM or 0.0)
      local half = max(0.0, jn.lengthM or 0.0) * 0.5 -- ONLY the throat (mouth); the bevel wraps keep the line.
      if half > 1e-6 then
        local centre01 = min(max(jn.t or 0.5, 0.0), 1.0)
        local centreArc = centre01 * total
        local lat = posFrac * widthAtArc(div, divWidths, total, centre01) + edgeOff + flare -- the bulged position of this line over the throat.
        local step = max(0.4, half / 6.0)
        local a = -half
        while a <= half + 1e-6 do
          local px, py, _, bx, by = crossingStationFrame(div, binormals, total, min(max((centreArc + a) / total, 0.0), 1.0))
          if px then
            n = n + 1; cuts = cuts or {}
            cuts[n] = { x = px + bx * sgn * lat, y = py + by * sgn * lat, r = max(step, 0.8) }
          end
          a = a + step
        end
      end
    end
  end
  return cuts
end

-- C1 smoothstep on [0,1] (0 at 0, 1 at 1, zero slope at both ends) for the widening taper ramps.
local function smoothstep01(x)
  if x <= 0 then return 0.0 elseif x >= 1 then return 1.0 else return x * x * (3.0 - 2.0 * x) end
end

-- Per-station OUTWARD bulge (m) for the edge line on `side` ('left'/'right'), summed from widenings with edgeBulge set: a
-- smoothstep taper-in -> full widthM held over the bay -> taper-out, keyed on plan-view arc length (decals drape, so plan
-- length is the right frame -- matches crossings/repairs). Overlaps on the same side max-combine. Added to the edge line's
-- lateral offset so the single continuous edge decal follows the widened mesh edge over the bay (no gap/second decal
-- needed). Returns a dense array over divPoints, or nil when nothing on that side bulges (the common case allocates nothing).
local function buildWideningEdgeBulge(group, side)
  local widenings, junctions = group.widenings, group.junctions
  local nW = (widenings and #widenings) or 0
  local nJ = (junctions and #junctions) or 0
  if nW + nJ == 0 then return nil end
  local div = group.divPoints
  local n = div and #div or 0
  if n < 2 then return nil end
  local wantLeft = side == 'left'
  local s = { [1] = 0.0 }
  for i = 2, n do s[i] = s[i - 1] + sqrt((div[i].x - div[i - 1].x) ^ 2 + (div[i].y - div[i - 1].y) ^ 2) end
  local total = s[n]
  if total <= 1e-6 then return nil end
  local arr = nil
  for k = 1, nW + nJ do
    local width, tin, bay, tout, t01
    if k <= nW then
      local it = widenings[k]
      if it.edgeBulge and ((it.side == 'left') == wantLeft) then -- widening: bulge only when the artist asked for it.
        width, tin, bay, tout, t01 = it.widthM, it.taperInM, it.bayLenM, it.taperOutM, it.t
      end
    else
      local it = junctions[k - nW]
      if (it.side == 'left') == wantLeft then -- junction: the edge line always follows the flare out (the bevel round the bell).
        width, tin, bay, tout, t01 = it.flareM, it.bevelM, it.lengthM, it.bevelM, it.t
      end
    end
    if width then
      width = max(0.0, width or 0.0); tin = max(0.0, tin or 0.0); bay = max(0.0, bay or 0.0); tout = max(0.0, tout or 0.0)
      local span = tin + bay + tout
      if width > 1e-6 and span > 1e-6 then
        local centre = min(max(t01 or 0.5, 0.0), 1.0) * total
        local a0 = centre - span * 0.5
        local a1 = a0 + tin
        local a2 = a1 + bay
        local a3 = a2 + tout
        arr = arr or {}
        for i = 1, n do
          local si, f = s[i], 0.0
          if si > a0 and si < a3 then
            if si < a1 then f = tin > 1e-6 and smoothstep01((si - a0) / tin) or 1.0
            elseif si <= a2 then f = 1.0
            else f = tout > 1e-6 and smoothstep01((a3 - si) / tout) or 1.0 end
          end
          local v = f * width
          local cur = arr[i]
          if not cur or v > cur then arr[i] = v end
        end
      end
    end
  end
  return arr
end

-- Creates + configures an empty DecalRoad for a marking layer (shared by the gapped emit path). Caller inserts nodes + regens.
local function newLayerDecalRoad(layer, group, folder, startFade, endFade)
  local dr = createObject("DecalRoad")
  dr:setField("improvedSpline", 0, "true")
  dr:setField("overObjects", 0, "true")
  dr:setField("detail", 0, defaultDecalRoadDetail)
  dr:setField("textureLength", 0, layer.texLen)
  dr:setField("renderPriority", 0, layer.renderPriority)
  dr:setField("drivability", 0, -1.0)
  dr:setField("material", 0, layer.material)
  dr:setField('startEndFade', 0, string.format("%f %f", startFade, endFade))
  dr:registerObject(Sim.getUniqueName(layer.name .. "_chunk"))
  folder:addObject(dr)
  dr.canSave = not group.isEnabled -- Edit = transient; Live/baked = persisted (matches the other decals).
  return dr
end

-- Build one chunk DecalRoad from a slice [a,b] of an already-built resampled polyline (pts/ws). At an internal join a
-- start/endTangent HANDLE node is added: improvedSpline treats the first/last node as a tangent control point (not drawn) and
-- takes the end tangent from the chord handle->end node, so the handle sits half the central difference (next - prev) away from
-- the join node. Both chunks then meet with the tangent the unsplit spline has there (C1, no crease, no double-draw); borrowing
-- the neighbour node instead gives each side a different one-sided chord, which shows as a wedge on tight bends.
-- The engine ignores the flags below 4 nodes (and draws the handle), so a chunk too short for its handles keeps natural ends.
local function createDecalRoadFromSlice(layer, group, folder, pts, ws, a, b, startFade, endFade, tanBefore, tanAfter)
  if (b - a + 1) + (tanBefore and 1 or 0) + (tanAfter and 1 or 0) < 4 then tanBefore, tanAfter = false, false end
  local dr = newLayerDecalRoad(layer, group, folder, startFade, endFade)
  dr:setField("startTangent", 0, tanBefore and "1" or "0")
  dr:setField("endTangent", 0, tanAfter and "1" or "0")
  local useTrack = layer.isTrackWidth
  local ins = 0
  if tanBefore then
    tmp1:setSub2(pts[a + 1], pts[a - 1])
    tmp1:setScaled(-0.5)
    tmp1:setAdd(pts[a])
    ins = insertDecalNode(dr, tmp1, useTrack and ws[a] or layer.width, ins)
  end
  for k = a, b do ins = insertDecalNode(dr, pts[k], useTrack and ws[k] or layer.width, ins) end
  if tanAfter then
    tmp1:setSub2(pts[b + 1], pts[b - 1])
    tmp1:setScaled(0.5)
    tmp1:setAdd(pts[b])
    ins = insertDecalNode(dr, tmp1, useTrack and ws[b] or layer.width, ins)
  end
  dr:regenerate()
  return dr
end

-- Build the layer's full-road decal polyline into its reused pClipped/wClipped buffers: offset each divPoint laterally by the
-- layer position, lift by decalDrapeHeight (overObjects drapes it back down), apply flip, then uniform-resample + weld (the
-- improvedSpline overshoots on uneven spacing; the weld kills degenerate segments that crash the batcher). Returns pts, ws.
-- bulgeArr (optional, edge lines only): per-station outward metres to push the edge line to the widened mesh edge over a
-- widening bay. Sign follows the layer's side (position < 0 = left, so the bulge pushes further left).
local function buildLayerPolyline(group, layer, bulgeArr)
  local divPoints, divWidths, binormals = group.divPoints, group.divWidths, group.binormals
  local layerPositionHalfWidth = layer.position * 0.5
  local sideSign = layerSideSign(layer)
  local isEdge = layer.isEdge == true -- Edge layer: sits at its side's road edge, offset outward by edgeOffsetM metres.
  local edgeOff = layer.edgeOffsetM or 0.0
  local pClipped, wClipped, ctr = layer.pClipped, layer.wClipped, 1
  for i = 1, #divPoints do
    local off = isEdge and sideSign * (0.5 * divWidths[i] + edgeOff) or layerPositionHalfWidth * divWidths[i]
    if bulgeArr and bulgeArr[i] then off = off + sideSign * bulgeArr[i] end
    tmp1:setScaled2(binormals[i], off)
    pClipped[ctr] = pClipped[ctr] or vec3()
    pClipped[ctr]:setAdd2(divPoints[i], tmp1)
    pClipped[ctr].z = pClipped[ctr].z + decalDrapeHeight
    wClipped[ctr] = divWidths[i]
    ctr = ctr + 1
  end
  for k = #pClipped, ctr, -1 do pClipped[k], wClipped[k] = nil, nil end
  if layer.isFlip then
    local pFlip, wFlip, c2 = layer.pFlip, layer.wFlip, 1
    for i = #pClipped, 1, -1 do
      pFlip[c2] = pFlip[c2] or vec3()
      pFlip[c2]:set(pClipped[i])
      wFlip[c2] = wClipped[i]
      c2 = c2 + 1
    end
    for k = #pFlip, c2, -1 do pFlip[k], wFlip[k] = nil, nil end
    pClipped, wClipped = pFlip, wFlip
  end
  geom.resampleUniformNodesWidths(pClipped, wClipped, decalResampleSpacing(layer))
  geom.weldShortSegments(pClipped, wClipped, decalWeldMinLenM)
  return pClipped, wClipped
end

-- Emit the layer's line as 1+ DecalRoads split around the pothole cut discs.
local function emitGappedPolyline(layer, group, folder, pts, ws, startFade, endFade, cuts)
  local n = #pts
  local secMax = sectionMaxNodes(layer)
  local i = 1
  while i <= n do
    while i <= n and pointInCuts(cuts, pts[i].x, pts[i].y) do i = i + 1 end -- skip nodes inside a hole.
    if i > n then break end
    local a = i
    while i <= n and not pointInCuts(cuts, pts[i].x, pts[i].y) do i = i + 1 end
    local b = i - 1 -- run [a,b] is entirely ungapped.
    local runStartFade = (a == 1) and startFade or markingFrayFadeM
    local runEndFade = (b == n) and endFade or markingFrayFadeM
    local s = a
    while s <= b do
      local e = min(s + secMax - 1, b)
      if e - s >= 1 then -- need >= 2 nodes for a DecalRoad.
        local sf = (s == a) and runStartFade or 0.0
        local ef = (e == b) and runEndFade or 0.0
        -- Internal sub-splits of a run join C1-continuous via a borrowed tangent handle; the run's own ends (a pothole/junction
        -- cut, or the road end) keep their fray/designed fade and a natural end (no handle across the gap).
        local dr = createDecalRoadFromSlice(layer, group, folder, pts, ws, s, e, sf, ef, s > a, e < b)
        layer.decalRoadIds[#layer.decalRoadIds + 1] = dr:getId()
      end
      if e == b then break end
      s = e -- share the boundary node with the next chunk.
    end
  end
end

-- Updates the decal road object associated with the given layer.
local function updateLayer(group, layerIdx, groupIdx)
  -- Check if the spline has enough nodes to create a valid decal road (minimum 2 nodes).
  if #group.nodes < 2 then
    -- Remove the decal road if there are insufficient nodes.
    local layer = group.layers[layerIdx]
    removeDecalRoadInLayer(layer)
    return
  end

  -- Get the Road Spline's scene tree folder.
  local folder = scenetree.findObjectById(group.sceneTreeFolderId)

  -- Create the decal road object, if it doesn't exist.
  local layer = group.layers[layerIdx]

  -- Ensure the layer has the decalRoadIds array (for backward compatibility)
  ensureLayerDecalRoadIds(layer)

  -- Edge bulge: over a widening bay flagged edgeBulge (and always round a junction bell), the edge line + edge-blend strips
  -- follow the widened mesh edge. Computed once here (edge-following layers only) and threaded through every build path so it
  -- applies to the single, chunked and gapped decals alike.
  local bulgeArr = isEdgeFollowLayer(layer) and buildWideningEdgeBulge(group, layerSideSign(layer) < 0 and 'left' or 'right') or nil

  -- Pothole gapping: only PAINTED lines are cut (the paint leaves with the pavement); wear/tread/damage/patch overlays run
  -- straight through. Build the whole line and split it around the holes (short fray fade at each cut end). This stays OFF the
  -- tested single/chunked paths below -- only the gapped paint-line case takes this branch.
  local cuts = isPaintLineLayer(layer) and buildPotholeCutList(group) or nil
  if isEdgeFollowLayer(layer) then -- break the edge line + edge-blend strips across any junction mouth on this side.
    local jCuts = buildJunctionEdgeCuts(group, layer)
    if jCuts then
      if cuts then for i = 1, #jCuts do cuts[#cuts + 1] = jCuts[i] end else cuts = jCuts end
    end
  end
  if cuts then
    removeDecalRoadInLayer(layer) -- drop any prior single + chunked roads for this layer.
    clearGroupChunks(group)
    ensureLayerDecalRoadIds(layer)
    local pts, ws = buildLayerPolyline(group, layer, bulgeArr)
    emitGappedPolyline(layer, group, folder, pts, ws, layer.fadeIn, layer.fadeOut, cuts)
    layer.isDirty = false
    return
  end

  -- Build the full-road offset polyline once (lateral offset + drape lift + flip + resample + weld). The chunk decision is made
  -- on the FINAL resampled node count (maxDecalRoadNodes), so typical hero roads stay a single seam-free DecalRoad.
  local pClipped, wClipped = buildLayerPolyline(group, layer, bulgeArr)
  local n = #pClipped
  local secMax = sectionMaxNodes(layer)

  if n > secMax then
    -- Long road: split the single resampled polyline into balanced chunks. Consecutive chunks share their boundary node and, at
    -- every internal join, borrow one neighbour node as a start/endTangent handle so they meet C1-continuous (see
    -- createDecalRoadFromSlice). The two true ends stay natural.
    removeDecalRoadInLayer(layer)
    clearGroupChunks(group)
    ensureLayerDecalRoadIds(layer)
    table.clear(layer.decalRoadIds)
    local numChunks = ceil((n - 1) / (secMax - 1))
    local step = ceil((n - 1) / numChunks)
    local idx, a = 0, 1
    while a < n do
      local b = min(a + step, n)
      idx = idx + 1
      local dr = createDecalRoadFromSlice(layer, group, folder, pClipped, wClipped, a, b,
        (a == 1) and layer.fadeIn or 0.0, (b == n) and layer.fadeOut or 0.0, a > 1, b < n)
      layer.decalRoadIds[idx] = dr:getId()
      addGroupChunk(group, a, b)
      a = b -- next chunk starts on this chunk's last drawn node (shared) -> no gap.
    end
    layer.isDirty = false
    return
  end

  -- Short/medium road: one continuous DecalRoad. Drop any chunks left from a previous longer build, then reuse the persistent
  -- single object.
  if group.numChunks > 0 then
    removeAllDecalRoadsForLayer(layer)
    clearGroupChunks(group)
  end
  if not layer.decalRoadId or not scenetree.findObjectById(layer.decalRoadId)
      or scenetree.findObjectById(layer.decalRoadId):getClassName() ~= "DecalRoad" then
    local newDecalRoad = createObject("DecalRoad")
    newDecalRoad:setField("improvedSpline", 0, "true")
    newDecalRoad:setField("overObjects", 0, "true")
    newDecalRoad:setField("detail", 0, defaultDecalRoadDetail)
    newDecalRoad:registerObject(Sim.getUniqueName(layer.name))
    layer.decalRoadId = newDecalRoad:getId()
    folder:addObject(newDecalRoad)
    editor.setDirty()
  end

  local dRoad = scenetree.findObjectById(layer.decalRoadId)
  dRoad:setField("textureLength", 0, layer.texLen)
  dRoad:setField("renderPriority", 0, layer.renderPriority)
  dRoad:setField("drivability", 0, -1.0)
  dRoad:setField("material", 0, layer.material)
  dRoad:setField("overObjects", 0, "true") -- Always drape onto the road mesh (this is a mesh road, not a terrain decal).
  dRoad:setField("startTangent", 0, "0") -- single road: natural ends, no tangent handles.
  dRoad:setField("endTangent", 0, "0")
  dRoad:setField('startEndFade', 0, string.format("%f %f", layer.fadeIn, layer.fadeOut))
  dRoad.canSave = not group.isEnabled -- Edit = transient, never written to the level; Live/baked = persisted.

  -- Clear all the nodes from the decal road object, but do not regenerate the geometry.
  for i = #editor.getNodes(dRoad) - 1, 0, -1 do
    dRoad:deleteNodeNoRegen(i)
  end

  -- Set the nodes in the decal road object (non-finite nodes are skipped to protect the batcher).
  local ins = 0
  if layer.isTrackWidth then
    for i = 1, n do
      ins = insertDecalNode(dRoad, pClipped[i], wClipped[i], ins)
    end
  else
    local layerWidth = layer.width
    for i = 1, n do
      ins = insertDecalNode(dRoad, pClipped[i], layerWidth, ins)
    end
  end

  dRoad:regenerate()
  layer.isDirty = false
end

-- Updates the properties of all layers.
-- ============================ Pedestrian crossing (zebra) decals ============================
-- A transverse zebra DecalRoad per placed crossing, spanning the carriageway (kerb-to-kerb when the crossing asks). The
-- dropped-kerb dip itself is built separately in sidewalkMgr; this is just the road-surface marking. A local station frame
-- (not groupMgr.crossingFrame) keeps this file free of a circular require on groupMgr.
local crossingMaterial = 'crossing_white' -- shipped ZEBRA_CROSSING material.
local crossingTexLenM = 5.0 -- metres per stripe-group repeat across the span (matches roadNetwork / Road Architect).
local crossingRenderPriority = 12 -- above the longitudinal markings so the zebra draws on top.
local crossingKerbSpanM = 1.65 -- extra span onto the walk each side for a kerb-to-kerb crossing (approx sidewalk band width).

-- Delete the decals in the group folder whose name starts with `prefix`. On a saved/baked road these decals persist (canSave)
-- but the transient id lists are wiped on load, so without this sweep the OLD ones survive a rebuild and stack under the new.
local function sweepFolderByPrefix(group, prefix)
  local folder = group.sceneTreeFolderId and scenetree.findObjectById(group.sceneTreeFolderId)
  if not folder then return end
  local stale = {}
  for j = 0, folder:size() - 1 do
    local obj = folder:at(j)
    local name = obj and obj.getName and obj:getName()
    if name and string.find(name, prefix, 1, true) == 1 then stale[#stale + 1] = obj end
  end
  for k = 1, #stale do if simObjectExists(stale[k]) then stale[k]:delete() end end
end

-- Delete a group's live zebra decals (and reset the id list). Called on every rebuild + on teardown.
local function clearCrossings(group)
  if not group then return end
  group.crossingDecalIds = group.crossingDecalIds or {}
  for i = 1, #group.crossingDecalIds do
    local obj = scenetree.findObjectById(group.crossingDecalIds[i])
    if obj and simObjectExists(obj) then obj:delete() end
  end
  table.clear(group.crossingDecalIds)
  sweepFolderByPrefix(group, 'HeroRoad_Crossing')
end

-- Places one zebra bar spanning p0..p1 (node width = depthM along traffic). Nodes are lifted by decalDrapeHeight so
-- overObjects projects the decal back down onto the road mesh.
local function placeCrossingBar(folder, group, p0, p1, depthM)
  if not folder or p0:squaredDistance(p1) < 0.25 then return end
  local decal = createObject('DecalRoad')
  decal:setField('improvedSpline', 0, 'true')
  decal:setField('overObjects', 0, 'true')
  decal:setField('detail', 0, defaultDecalRoadDetail)
  decal:setField('textureLength', 0, tostring(crossingTexLenM))
  decal:setField('renderPriority', 0, crossingRenderPriority)
  decal:setField('drivability', 0, -1.0)
  decal:setField('material', 0, crossingMaterial)
  decal:setField('startEndFade', 0, '0 0')
  decal:registerObject(Sim.getUniqueName('HeroRoad_Crossing'))
  folder:addObject(decal)
  decal.canSave = not group.isEnabled -- transient while editing; persisted on a Live/baked road (matches the layer decals).
  local ins = insertDecalNode(decal, vec3(p0.x, p0.y, p0.z + decalDrapeHeight), depthM, 0)
  insertDecalNode(decal, vec3(p1.x, p1.y, p1.z + decalDrapeHeight), depthM, ins)
  decal:regenerate()
  group.crossingDecalIds[#group.crossingDecalIds + 1] = decal:getId()
end

-- (Re)build every placed crossing's zebra bar. No-op (past the clear) when the road has none.
local function updateCrossings(group)
  clearCrossings(group)
  if not group then return end
  local crossings = group.crossings
  if not crossings or #crossings == 0 then return end
  local div, binormals = group.divPoints, group.binormals
  if not div or #div < 2 or not binormals then return end
  local folder = group.sceneTreeFolderId and scenetree.findObjectById(group.sceneTreeFolderId)
  if not folder then return end
  local leftExt = group.leftExtM or ((group.divWidths and group.divWidths[1] or 5) * 0.5)
  local rightExt = group.rightExtM or leftExt
  local total = 0
  for i = 2, #div do total = total + sqrt((div[i].x - div[i - 1].x) ^ 2 + (div[i].y - div[i - 1].y) ^ 2) end
  if total <= 1e-6 then return end
  for c = 1, #crossings do
    local cr = crossings[c]
    local px, py, pz, bx, by, bz = crossingStationFrame(div, binormals, total, cr.t or 0.5)
    if px then
      local lSpan, rSpan = leftExt, rightExt
      if cr.lateral == 'kerb' then -- extend onto the walk on each side that has a sidewalk.
        if group.sidewalkLeft then lSpan = lSpan + crossingKerbSpanM end
        if group.sidewalkRight then rSpan = rSpan + crossingKerbSpanM end
      end
      placeCrossingBar(folder, group,
        vec3(px - bx * lSpan, py - by * lSpan, pz - bz * lSpan),
        vec3(px + bx * rSpan, py + by * rSpan, pz + bz * rSpan),
        cr.depthM or 3.5)
    end
  end
end

-- ============================ Widening lane-divider decals ============================
-- A dashed lane line along the ORIGINAL carriageway edge over a widening's bay, for widenings flagged laneDivider (turns the
-- bay into a marked extra lane, e.g. an overtaking lane). Its partner -- the solid edge line following the widened outer edge
-- -- is handled by the edge-line bulge (buildWideningEdgeBulge), so nothing is gapped here; this just adds the inner divider.
local wideningDividerPriority = sliderDefaults.defaultRenderPriority + 1 -- above the edge line so the dashes read on top.

-- Delete a group's live widening-divider decals (and reset the id list). Called on every rebuild + on teardown.
local function clearWidenings(group)
  if not group then return end
  group.wideningDecalIds = group.wideningDecalIds or {}
  for i = 1, #group.wideningDecalIds do
    local obj = scenetree.findObjectById(group.wideningDecalIds[i])
    if obj and simObjectExists(obj) then obj:delete() end
  end
  table.clear(group.wideningDecalIds)
  sweepFolderByPrefix(group, 'HeroRoad_Widening')
end

-- (Re)build the dashed divider for every widening flagged laneDivider. No-op (past the clear) when the road has none.
local function updateWidenings(group)
  clearWidenings(group)
  if not group then return end
  local list = group.widenings
  if not list or #list == 0 then return end
  local div, binormals, divWidths = group.divPoints, group.binormals, group.divWidths
  local n = div and #div or 0
  if n < 2 or not binormals or not divWidths then return end
  local folder = group.sceneTreeFolderId and scenetree.findObjectById(group.sceneTreeFolderId)
  if not folder then return end
  local off = group.edgeLineOffset or 1.0 -- the divider sits at the ORIGINAL edge (same lateral position the edge line had).
  local material = group.laneLineMaterial or roadLaneLineMaterial
  local texLen = group.laneLineTexLen or sliderDefaults.defaultTexLength
  local s = { [1] = 0.0 }
  for i = 2, n do s[i] = s[i - 1] + sqrt((div[i].x - div[i - 1].x) ^ 2 + (div[i].y - div[i - 1].y) ^ 2) end
  local total = s[n]
  if total <= 1e-6 then return end
  for w = 1, #list do
    local it = list[w]
    local span = max(0.0, it.taperInM or 0.0) + max(0.0, it.bayLenM or 0.0) + max(0.0, it.taperOutM or 0.0)
    if it.laneDivider and span > 1e-6 then
      local centre = min(max(it.t or 0.5, 0.0), 1.0) * total
      local a0, a3 = centre - span * 0.5, centre + span * 0.5
      local sgn = it.side == 'left' and -1.0 or 1.0
      -- Gather the span's stations, then give them the SAME density treatment as the layer decals (uniform resample + weld).
      -- Raw divPoints are far denser than a marking needs -- and `detail` subdivides every segment again -- so emitting them
      -- 1:1 piled up thousands of nodes over one bay and lost the render. This line follows the carriageway edge, so it uses
      -- the finer edge-line spacing.
      local pts, ws = {}, {}
      for i = 1, n do
        if s[i] >= a0 and s[i] <= a3 then
          tmp1:setScaled2(binormals[i], sgn * divWidths[i] * 0.5 * off)
          local c = #pts + 1
          pts[c] = vec3(div[i].x + tmp1.x, div[i].y + tmp1.y, div[i].z + tmp1.z + decalDrapeHeight)
          ws[c] = defaultLaneLineWidth
        end
      end
      if #pts >= 2 then
        geom.resampleUniformNodesWidths(pts, ws, edgeLineResampleM)
        geom.weldShortSegments(pts, ws, decalWeldMinLenM)
      end
      if #pts >= 2 then -- a degenerate span (< 2 usable stations) emits nothing.
        local decal = createObject('DecalRoad')
        decal:setField('improvedSpline', 0, 'true')
        decal:setField('overObjects', 0, 'true')
        decal:setField('detail', 0, defaultDecalRoadDetail)
        decal:setField('textureLength', 0, tostring(texLen))
        decal:setField('renderPriority', 0, wideningDividerPriority)
        decal:setField('drivability', 0, -1.0)
        decal:setField('material', 0, material)
        decal:setField('startEndFade', 0, string.format("%f %f", markingFrayFadeM, markingFrayFadeM)) -- fade in/out at the taper ends.
        decal:registerObject(Sim.getUniqueName('HeroRoad_Widening'))
        folder:addObject(decal)
        decal.canSave = not group.isEnabled -- transient while editing; persisted on a Live/baked road (matches the layer decals).
        local ins = 0
        for i = 1, #pts do ins = insertDecalNode(decal, pts[i], ws[i], ins) end
        decal:regenerate()
        group.wideningDecalIds[#group.wideningDecalIds + 1] = decal:getId()
      end
    end
  end
end

-- ============================ Junction markings (give-way bar + incoming centreline) ============================
-- Two SEPARATE markings on the joining (stub) road, each with its own toggle:
--   * centreline (exitCenterline): runs ALONG the stub, down its middle, from the trunk centreline out to the end of the stub.
--   * give-way (giveWay):          a transverse bar ACROSS the stub (perpendicular to it / parallel to the trunk), sitting ON
--                                  the stub just past the trunk carriageway edge, spanning the stub width -- a real give-way
--                                  line, not on the trunk. Drawn on top so the centreline crossing it doesn't split it.
-- The flare (mesh) and the edge-line bevel/break round the bell are handled elsewhere; this is just the paint.
local junctionBarPriority = sliderDefaults.defaultRenderPriority + 2 -- centreline: on top of the edge line + widening divider.
local giveWayPriority = junctionBarPriority + 2 -- give-way bar draws above the centreline so the crossing stays one clean bar.
local giveWayLineWidthM = 0.3 -- line thickness of the give-way (m).

-- Delete a group's junction decals (and reset the id list). Called on every rebuild + on teardown.
local function clearJunctions(group)
  if not group then return end
  group.junctionDecalIds = group.junctionDecalIds or {}
  for i = 1, #group.junctionDecalIds do
    local obj = scenetree.findObjectById(group.junctionDecalIds[i])
    if obj and simObjectExists(obj) then obj:delete() end
  end
  table.clear(group.junctionDecalIds)
  sweepFolderByPrefix(group, 'HeroRoad_Junction')
end

-- Places one straight 2-node junction line pA->pB (nodes lifted by decalDrapeHeight so overObjects drapes it onto the mesh) and
-- records its id. widthM is the DecalRoad width (perpendicular to pA->pB).
local function placeJunctionLine(folder, group, pA, pB, widthM, material, texLen, priority)
  local decal = createObject('DecalRoad')
  decal:setField('improvedSpline', 0, 'true')
  decal:setField('overObjects', 0, 'true')
  decal:setField('detail', 0, defaultDecalRoadDetail)
  decal:setField('textureLength', 0, tostring(texLen))
  decal:setField('renderPriority', 0, priority)
  decal:setField('drivability', 0, -1.0)
  decal:setField('material', 0, material)
  decal:setField('startEndFade', 0, '0 0')
  decal:registerObject(Sim.getUniqueName('HeroRoad_Junction'))
  folder:addObject(decal)
  decal.canSave = not group.isEnabled -- transient while editing; persisted on a Live/baked road (matches the layer decals).
  local ins = insertDecalNode(decal, vec3(pA.x, pA.y, pA.z + decalDrapeHeight), widthM, 0)
  insertDecalNode(decal, vec3(pB.x, pB.y, pB.z + decalDrapeHeight), widthM, ins)
  decal:regenerate()
  group.junctionDecalIds[#group.junctionDecalIds + 1] = decal:getId()
end

-- (Re)build the joining-road centreline + give-way line for every junction. No-op (past the clear) when the road has none.
-- The hero road is the TRUNK (bidirectional). A junction is the mouth of a side road joining it on jn.side. Both markings are
-- RADIAL (perpendicular to the trunk tangent) at the junction station:
--   * give-way  : SOLID white, from the trunk centreline out to the junction-side carriageway edge. It covers ONLY the joining
--                 (incoming) half of the trunk -- NOT the far lane -- and stops at the edge.
--   * centreline: the joining road's own centreline, from that same edge on OUT to the end of the apron. It STARTS at the
--                 give-way line so it never enters the trunk.
local function updateJunctions(group)
  clearJunctions(group)
  if not group then return end
  local list = group.junctions
  if not list or #list == 0 then return end
  local div, binormals = group.divPoints, group.binormals
  if not div or #div < 2 or not binormals then return end
  local folder = group.sceneTreeFolderId and scenetree.findObjectById(group.sceneTreeFolderId)
  if not folder then return end
  local leftExt = group.leftExtM or ((group.divWidths and group.divWidths[1] or 5) * 0.5)
  local rightExt = group.rightExtM or leftExt
  local total = 0
  for i = 2, #div do total = total + sqrt((div[i].x - div[i - 1].x) ^ 2 + (div[i].y - div[i - 1].y) ^ 2) end
  if total <= 1e-6 then return end
  group.junctionDecalIds = group.junctionDecalIds or {}
  local ctrMat = group.centerLineMaterial or roadCenterLineMaterial
  local ctrTex = group.centerLineTexLen or defaultCenterlineTexLen
  local gwMat = group.edgeLineMaterial or roadEdgeLineMaterial -- SOLID white give-way (junction-side half only).
  for j = 1, #list do
    local jn = list[j]
    local edge = jn.side == 'left' and leftExt or rightExt -- carriageway edge on the junction side (start of the apron).
    local sgn = jn.side == 'left' and -1.0 or 1.0
    local flare = max(0.0, jn.flareM or 0.0)
    local length = max(0.0, jn.lengthM or 0.0)
    local centre01 = min(max(jn.t or 0.5, 0.0), 1.0)
    local px, py, pz, bx, by, bz = crossingStationFrame(div, binormals, total, centre01)
    if px then
      local setback = min(1.0, max(0.3, flare * 0.3)) -- give-way sits ~0.5-1 m onto the stub, clearly off the trunk carriageway.
      local gwLat = edge + setback
      -- How far along the stub (from its centreline) the paved edge sits AT this lateral: over the throat the stub is length/2
      -- wide, then the flare ramps in over the bevel (smoothstep), so invert it to follow the edge round the bevel.
      local halfPaved = length * 0.5
      if flare > 1e-6 and (jn.bevelM or 0) > 1e-6 then
        local v = min(1.0, setback / flare)
        local u = 0.5 - sin(asin(min(1.0, max(-1.0, 1.0 - 2.0 * v))) / 3.0) -- smoothstep^-1(v).
        halfPaved = halfPaved + (jn.bevelM or 0) * (1.0 - u)
      end
      -- Give-way: SOLID white bar ACROSS the joining road (parallel to the trunk tangent), ON the stub off the trunk edge. Runs
      -- from JUST INSIDE the stub centreline out to JUST BEFORE the edge line (the incoming half only). NOT on the trunk.
      if jn.giveWay and length > 1e-6 then
        local sA = centre01 * total + 0.25             -- just inside the centreline (not painted over it).
        local sB = centre01 * total + halfPaved - 0.3  -- just before the edge line at the bevel.
        if sB > sA then
          local ax, ay, az, abx, aby, abz = crossingStationFrame(div, binormals, total, min(max(sA / total, 0.0), 1.0))
          local ex, ey, ez, ebx, eby, ebz = crossingStationFrame(div, binormals, total, min(max(sB / total, 0.0), 1.0))
          if ax and ex then
            placeJunctionLine(folder, group,
              { x = ax + abx * sgn * gwLat, y = ay + aby * sgn * gwLat, z = az + abz * sgn * gwLat },
              { x = ex + ebx * sgn * gwLat, y = ey + eby * sgn * gwLat, z = ez + ebz * sgn * gwLat },
              giveWayLineWidthM, gwMat, ctrTex, giveWayPriority)
          end
        end
      end
      -- Joining-road centreline: radial, down the middle of the stub. STOPS before the give-way bar (starts just outside it) and
      -- runs OUT to the end of the apron -- so it never crosses the give-way and never enters the trunk.
      if jn.exitCenterline ~= false and flare > 1e-3 then
        local inner = gwLat + 0.4        -- stop just before the give-way bar.
        local outer = edge + flare       -- the connecting end of the stub.
        if outer > inner then
          placeJunctionLine(folder, group,
            { x = px + bx * sgn * inner, y = py + by * sgn * inner, z = pz + bz * sgn * inner },
            { x = px + bx * sgn * outer, y = py + by * sgn * outer, z = pz + bz * sgn * outer },
            defaultCenterlineWidth, ctrMat, ctrTex, junctionBarPriority)
        end
      end
    end
  end
end

local function updateAllLayers(group, groupIdx)
  local layers = group.layers
  for i = 1, #layers do
    local layer = layers[i]
    if layer.isEnabled then
      updateLayer(group, i, groupIdx)
    else
      removeDecalRoadInLayer(layer) -- Remove the decal road object associated with the given layer.
    end
  end
  updateCrossings(group) -- transverse zebra bars for any placed pedestrian crossings.
  updateWidenings(group) -- dashed lane dividers for any placed widenings (overtaking lanes).
  updateJunctions(group) -- give-way / stop bars for any placed junction bell-mouths.
  repairMgr.updateRepairs(group) -- seeded scatter of asphalt-patch decals for any placed repair clusters.
end

-- Updates the properties of only the dirty layers.
local function updateOnlyDirtyLayers(group, groupIdx)
  local layers = group.layers
  for i = 1, #layers do
    local layer = layers[i]
    if layer.isDirty then
      if layer.isEnabled then
        updateLayer(group, i, groupIdx)
      else
        removeDecalRoadInLayer(layer) -- Remove the decal road object associated with the given layer.
      end
      layer.isDirty = false
    end
  end
end

-- Removes a layer at the given index.
local function removeLayer(idx, group)
  local layers = group.layers
  local layer = layers[idx]
  removeDecalRoadInLayer(layer)
  table.remove(layers, idx) -- Remove the layer from the list.
end

-- Removes all layers.
local function removeAllLayers(group)
  for i = #group.layers, 1, -1 do
    removeLayer(i, group)
  end
  clearCrossings(group) -- also drop any zebra decals (disabled / too-few-nodes teardown).
  clearWidenings(group) -- and any widening lane-divider decals.
  clearJunctions(group) -- and any junction give-way / stop bar decals.
  repairMgr.clearRepairs(group) -- and any scattered repair-patch decals.
end

-- Drag-hide teardown: remove every layer's rendered DecalRoad(s) plus the crossing/widening/junction/repair decals, but KEEP the
-- layer definitions (and all authored placeable data) on the group -- the release rebuild recreates the decals. Unlike
-- removeAllLayers, this does NOT table.remove the layer entries, so a node drag no longer permanently drops the artist's layers.
local function clearAllLayerDecals(group)
  local layers = group.layers
  for i = 1, #layers do removeDecalRoadInLayer(layers[i]) end
  clearCrossings(group)
  clearWidenings(group)
  clearJunctions(group)
  repairMgr.clearRepairs(group)
end

-- Removes all hidden layers.
local function removeAllHiddenLayers(group)
  local layers = group.layers
  for i = #layers, 1, -1 do
    if layers[i].isHidden then
      removeLayer(i, group)
    end
  end
end

-- Adds a new layer.
local function addNewLayer(group)
  group.layers[#group.layers + 1] = {
    name = string.format("New Layer %d", #group.layers + 1),
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = false,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = defaultMaterial,
    isFlip = false,
    isTrackWidth = true,
    isOverObjects = false,
    width = sliderDefaults.defaultWidth,
    position = sliderDefaults.defaultLateralPosition,
    texLen = sliderDefaults.defaultTexLength,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,

    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},

    decalRoadIds = {},
  }
end

-- Duplicates a layer at the given index.
local function duplicateLayer(idx, group)
  local layer = group.layers[idx]
  local newLayer = deepCopyLayer(layer)
  newLayer.id = Engine.generateUUID()
  newLayer.name = layer.name .. " (Copy)"
  -- Drop the source's DecalRoad scene handles so the copy builds its OWN roads. Without this both layers point
  -- at the same DecalRoad(s) and drive them together, so the original appears to vanish (and deleting either
  -- deletes the shared object). Force a fresh build via isDirty.
  newLayer.decalRoadId = nil
  newLayer.decalRoadIds = {}
  newLayer.isDirty = true
  table.insert(group.layers, idx + 1, newLayer)
end

-- Switches off all auto layers.
local function switchOffAllAutoLayers(selGroup)
  selGroup.isLightTreadMarks = false
  selGroup.isHeavyTreadMarks = false
  selGroup.isDamageAsphalt1 = false
  selGroup.isDamageAsphalt2 = false
  selGroup.isRoadCrack = false
  selGroup.isRepair1 = false
  selGroup.isRepair2 = false
  selGroup.isPatches = false
  selGroup.isRoadCenterLine = false
  selGroup.isRoadEdgeLines = false
  selGroup.isRoadLaneLines = false
  selGroup.isEdgeBlend1 = false
  selGroup.isEdgeBlend2 = false
  selGroup.isEdgeBlend3 = false

  selGroup.isDirty = true
end

-- Adds new full-length detail layers (wear / tread / cracks / repairs / damage), one per LANE, centred in the lane.
-- Uses the REAL lane model (lanesLeft/lanesRight x laneWidthM), exactly like the lane-division lines -- not roadSpline's
-- old width/5 heuristic -- so a decal sits over each actual lane for any symmetric OR asymmetric config. The carriageway
-- is symmetric about the spline over N = nL+nR equal lanes, and 'position' is a fraction of the half-width, so lane j's
-- centre is at (2j-1-N)/N. Each decal is one lane wide (isTrackWidth off -> uses layer.width = laneWidthM).
local function addFullLengthLayers(group, searchString, material, texLen)
  local nL = max(0, floor(group.lanesLeft or 1))
  local nR = max(0, floor(group.lanesRight or 1))
  local N = nL + nR
  if N < 1 then N = 1 end
  local lw = max(0.1, group.laneWidthM or laneWidth)
  for j = 1, N do
    local pos = (2 * j - 1 - N) / N
    group.layers[#group.layers + 1] = {
      name = string.format("%s - %s %d", searchString, pos < 0 and "Left" or "Right", j),
      id = Engine.generateUUID(),
      isDirty = true,
      isHidden = true,
      decalRoadId = nil,
      renderPriority = sliderDefaults.defaultRenderPriority,
      isEnabled = true,
      material = material,
      isFlip = false,
      isTrackWidth = false,
      isOverObjects = false,
      width = lw,
      position = pos,
      texLen = texLen,
      fadeIn = sliderDefaults.defaultFadeIn,
      fadeOut = sliderDefaults.defaultFadeOut,
      pClipped = {},
      wClipped = {},
      pFlip = {},
      wFlip = {},
      decalRoadIds = {},
    }
  end
end

-- Removes all layers matching the given search string.
local function removeMatchingLayers(group, searchString)
  local layers = group.layers
  for i = #layers, 1, -1 do
    if string.find(layers[i].name, searchString) then
      removeLayer(i, group)
    end
  end
end

-- Add/remove functions for various detail layers. The texture tile length is per-road (group.<field>, set from the Materials
-- tab) and falls back to the module default when a road was authored before the field existed.
local function addLightTreadMarksLayers(group) addFullLengthLayers(group, lightTreadStr, lightTreadMaterial, group.lightTreadTexLen or lightTreadMarksTexLen) end
local function removeLightTreadMarksLayers(group) removeMatchingLayers(group, lightTreadStr) end
local function addHeavyTreadMarksLayers(group) addFullLengthLayers(group, heavyTreadStr, heavyTreadMaterial, group.heavyTreadTexLen or heavyTreadMarksTexLen) end
local function removeHeavyTreadMarksLayers(group) removeMatchingLayers(group, heavyTreadStr) end
local function addRoadCrackLayers(group) addFullLengthLayers(group, roadCrackStr, roadCrackMaterial, group.roadCrackTexLen or roadCrackTexLen) end
local function removeRoadCrackLayers(group) removeMatchingLayers(group, roadCrackStr) end
local function addRepair1Layers(group) addFullLengthLayers(group, repair1Str, repair1Material, group.repair1TexLen or repair1TexLen) end
local function removeRepair1Layers(group) removeMatchingLayers(group, repair1Str) end
local function addRepair2Layers(group) addFullLengthLayers(group, repair2Str, repair2Material, group.repair2TexLen or repair2TexLen) end
local function removeRepair2Layers(group) removeMatchingLayers(group, repair2Str) end
local function addPatchesLayers(group) addFullLengthLayers(group, patchesStr, patchesMaterial, group.patchesTexLen or patchesTexLen) end
local function removePatchesLayers(group) removeMatchingLayers(group, patchesStr) end
local function addRoadDamageAsphalt1Layers(group) addFullLengthLayers(group, damageAsphalt1Str, damageAsphalt1Material, group.damageAsphalt1TexLen or damageAsphalt1TexLen) end
local function removeRoadDamageAsphalt1Layers(group) removeMatchingLayers(group, damageAsphalt1Str) end
local function addRoadDamageAsphalt2Layers(group) addFullLengthLayers(group, damageAsphalt2Str, damageAsphalt2Material, group.damageAsphalt2TexLen or damageAsphalt2TexLen) end
local function removeRoadDamageAsphalt2Layers(group) removeMatchingLayers(group, damageAsphalt2Str) end

-- Adds new road center line layers.
local function addRoadCenterLineLayers(group)
  -- The centre line is the OPPOSING-TRAFFIC divider, so it belongs at the boundary between the left and right lane
  -- groups -- which is only at the spline when the road is symmetric. The carriageway is symmetric about the spline
  -- (N = nL+nR equal lanes centred on it), so that boundary is at normalised position (2*nL - N)/N. One-way roads
  -- (a side with 0 lanes) have no opposing traffic, so no centre line at all.
  local nL = max(0, floor(group.lanesLeft or 1))
  local nR = max(0, floor(group.lanesRight or 1))
  if nL < 1 or nR < 1 then return end
  local pos = (nL - nR) / (nL + nR)
  group.layers[#group.layers + 1] = {
    name = roadCenterLineStr,
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = group.centerLineMaterial or roadCenterLineMaterial,
    isFlip = false,
    isTrackWidth = false,
    isOverObjects = false,
    width = regionStyles.getRegion('usa').centerLineWidthM or defaultCenterlineWidth,
    position = pos,
    texLen = group.centerLineTexLen or defaultCenterlineTexLen,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }
end

-- Removes the road center line layers.
local function removeRoadCenterLineLayers(group) removeMatchingLayers(group, roadCenterLineStr) end

-- Adds new road edge lines layers.
local function addRoadEdgeLinesLayers(group)
  -- These are road-level (group) properties, not layer properties: the edge decals are auto-generated/hidden and
  -- get rebuilt from scratch on every dirty update, so the authorable values must live on the group. Fall back to
  -- the module defaults so older serialized roads (saved before these fields existed) still build correctly.
  local w = group.edgeLineWidth or defaultEdgeLineWidth
  local off = group.edgeLineOffset or 1.0
  group.layers[#group.layers + 1] = {
    name = roadEdgeLineStr .. " - Left",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = group.edgeLineMaterial or roadEdgeLineMaterial,
    isFlip = false,
    isTrackWidth = false,
    isOverObjects = false,
    width = w,
    position = -off,
    texLen = group.edgeLineTexLen or sliderDefaults.defaultTexLength,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }

  group.layers[#group.layers + 1] = {
    name = roadEdgeLineStr .. " - Right",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = group.edgeLineMaterial or roadEdgeLineMaterial,
    isFlip = false,
    isTrackWidth = false,
    isOverObjects = false,
    width = w,
    position = off,
    texLen = group.edgeLineTexLen or sliderDefaults.defaultTexLength,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }
end

-- Removes the road edge lines layers.
local function removeRoadEdgeLinesLayers(group) removeMatchingLayers(group, roadEdgeLineStr) end

-- Adds new road lane lines layers.
-- Lane-division lines from the ACTUAL lane model (roadNetwork-style), not roadSpline's width heuristic. The
-- carriageway is symmetric about the spline and spans N = lanesLeft + lanesRight equal lanes, so the interior lane
-- boundaries sit at normalised position (2k - N)/N for k = 1..N-1 (position is a fraction of the half-width, so it is
-- independent of lane width). We skip k == lanesLeft: that boundary is the opposing-traffic divider, which the
-- separate centre-line layer draws.
local function addRoadLaneLinesLayers(group)
  local nL = max(0, floor(group.lanesLeft or 1))
  local nR = max(0, floor(group.lanesRight or 1))
  local N = nL + nR
  if N < 2 then return end -- Fewer than two lanes: no interior lane dividers.
  local twoWay = nL > 0 and nR > 0 -- On a two-way road the nL boundary is the opposing-traffic divider (centre line), so skip it here.
  for k = 1, N - 1 do
    if not (twoWay and k == nL) then
      local pos = (2 * k - N) / N
      group.layers[#group.layers + 1] = {
        name = string.format("%s - %s %d", roadLaneLineStr, pos < 0 and "Left" or "Right", k),
        id = Engine.generateUUID(),
        isDirty = true,
        isHidden = true,
        decalRoadId = nil,
        renderPriority = sliderDefaults.defaultRenderPriority,
        isEnabled = true,
        material = group.laneLineMaterial or roadLaneLineMaterial,
        isFlip = false,
        isTrackWidth = false,
        isOverObjects = false,
        width = defaultLaneLineWidth,
        position = pos,
        texLen = group.laneLineTexLen or sliderDefaults.defaultTexLength,
        fadeIn = sliderDefaults.defaultFadeIn,
        fadeOut = sliderDefaults.defaultFadeOut,
        pClipped = {},
        wClipped = {},
        pFlip = {},
        wFlip = {},
        decalRoadIds = {},
      }
    end
  end
end

-- Removes the road lane lines layers.
local function removeRoadLaneLinesLayers(group) removeMatchingLayers(group, roadLaneLineStr) end

-- Adds new edge blend 1 layers.
local function addEdgeBlend1Layers(group)
  local w = group.edgeBlend1Width or defaultEdgeBlend1Width
  local off = group.edgeBlend1Offset or defaultEdgeBlend1LatPos
  group.layers[#group.layers + 1] = {
    name = roadEdgeBlend1Str .. " - Left",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority - 1,
    isEnabled = true,
    material = roadEdgeBlend1Material,
    isFlip = false,
    isTrackWidth = false,
    isOverObjects = false,
    width = w,
    position = -off,
    texLen = defaultEdgeBlend1TexLen,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }

  group.layers[#group.layers + 1] = {
    name = roadEdgeBlend1Str .. " - Right",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority - 1,
    isEnabled = true,
    material = roadEdgeBlend1Material,
    isFlip = true,
    isTrackWidth = false,
    isOverObjects = false,
    width = w,
    position = off,
    texLen = defaultEdgeBlend1TexLen,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }
end

-- Removes the edge blend 1 layers.
local function removeEdgeBlend1Layers(group) removeMatchingLayers(group, roadEdgeBlend1Str) end

-- Adds new edge blend 2 layers.
local function addEdgeBlend2Layers(group)
  local w = group.edgeBlend2Width or defaultEdgeBlend2Width
  local off = group.edgeBlend2Offset or defaultEdgeBlend2LatPos
  group.layers[#group.layers + 1] = {
    name = roadEdgeBlend2Str .. " - Left",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = roadEdgeBlend2Material,
    isFlip = false,
    isTrackWidth = false,
    isOverObjects = false,
    width = w,
    position = -off,
    texLen = defaultEdgeBlend2TexLen,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }

  group.layers[#group.layers + 1] = {
    name = roadEdgeBlend2Str .. " - Right",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = roadEdgeBlend2Material,
    isFlip = true,
    isTrackWidth = false,
    isOverObjects = false,
    width = w,
    position = off,
    texLen = defaultEdgeBlend2TexLen,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }
end

-- Removes the edge blend 2 layers.
local function removeEdgeBlend2Layers(group) removeMatchingLayers(group, roadEdgeBlend2Str) end

-- Adds new edge blend 3 layers.
local function addEdgeBlend3Layers(group)
  local w = group.edgeBlend3Width or defaultEdgeBlend3Width
  local off = group.edgeBlend3Offset or defaultEdgeBlend3LatPos
  group.layers[#group.layers + 1] = {
    name = roadEdgeBlend3Str .. " - Left_A",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = roadEdgeBlend3Material,
    isFlip = false,
    isTrackWidth = false,
    isOverObjects = false,
    width = w,
    position = -off,
    texLen = defaultEdgeBlend3TexLen,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }

  group.layers[#group.layers + 1] = {
    name = roadEdgeBlend3Str .. " - Right_A",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = roadEdgeBlend3Material,
    isFlip = true,
    isTrackWidth = false,
    isOverObjects = false,
    width = w,
    position = off,
    texLen = defaultEdgeBlend3TexLen,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }
end

-- Removes the edge blend 3 layers.
local function removeEdgeBlend3Layers(group) removeMatchingLayers(group, roadEdgeBlend3Str) end

-- Serialises a layer to a table.
local function serializeLayer(layer)
  return {
    name = layer.name,
    id = layer.id,
    isHidden = layer.isHidden,
    isEnabled = layer.isEnabled,
    material = layer.material,
    isFlip = layer.isFlip,
    isTrackWidth = layer.isTrackWidth,
    isEdge = layer.isEdge,
    edgeSide = layer.edgeSide,
    edgeOffsetM = layer.edgeOffsetM,
    isOverObjects = layer.isOverObjects,
    width = layer.width,
    position = layer.position,
    texLen = layer.texLen,
    fadeIn = layer.fadeIn,
    fadeOut = layer.fadeOut,
    renderPriority = layer.renderPriority,
  }
end

-- Deserialises a layer from a table.
local function deserializeLayer(data)
  return {
    name = data.name or "?",
    id = data.id or Engine.generateUUID(),
    isDirty = true, -- Set to dirty. The objects will be added in the next update.
    decalRoadId = nil,
    isHidden = data.isHidden == true,
    isEnabled = data.isEnabled ~= false,
    material = data.material,
    isFlip = data.isFlip == true,
    isTrackWidth = data.isTrackWidth == true,
    isEdge = data.isEdge == true,
    edgeSide = data.edgeSide == 'left' and 'left' or 'right',
    edgeOffsetM = data.edgeOffsetM or 0.0,
    isOverObjects = data.isOverObjects == true,
    width = data.width or sliderDefaults.defaultWidth,
    position = data.position or sliderDefaults.defaultLateralPosition,
    texLen = data.texLen or sliderDefaults.defaultTexLength,
    fadeIn = data.fadeIn or sliderDefaults.defaultFadeIn,
    fadeOut = data.fadeOut or sliderDefaults.defaultFadeOut,
    renderPriority = data.renderPriority or sliderDefaults.defaultRenderPriority,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }
end


-- Public interface.
M.getSliderDefaults =                                  getSliderDefaults

M.deepCopyLayer =                                      deepCopyLayer
M.deepCopyAllLayers =                                  deepCopyAllLayers

M.updateAllLayers =                                    updateAllLayers
M.updateOnlyDirtyLayers =                              updateOnlyDirtyLayers

M.removeDecalRoadInLayer =                             removeDecalRoadInLayer
M.setGroupDecalsCanSave =                             setGroupDecalsCanSave
M.removeLayer =                                        removeLayer
M.removeAllLayers =                                    removeAllLayers
M.clearAllLayerDecals =                                clearAllLayerDecals
M.removeAllHiddenLayers =                              removeAllHiddenLayers
M.addNewLayer =                                        addNewLayer
M.duplicateLayer =                                     duplicateLayer

M.switchOffAllAutoLayers =                             switchOffAllAutoLayers
M.addLightTreadMarksLayers =                           addLightTreadMarksLayers
M.removeLightTreadMarksLayers =                        removeLightTreadMarksLayers
M.addHeavyTreadMarksLayers =                           addHeavyTreadMarksLayers
M.removeHeavyTreadMarksLayers =                        removeHeavyTreadMarksLayers
M.addRoadCrackLayers =                                 addRoadCrackLayers
M.removeRoadCrackLayers =                              removeRoadCrackLayers
M.addRepair1Layers =                                   addRepair1Layers
M.removeRepair1Layers =                                removeRepair1Layers
M.addRepair2Layers =                                   addRepair2Layers
M.removeRepair2Layers =                                removeRepair2Layers
M.addPatchesLayers =                                   addPatchesLayers
M.removePatchesLayers =                                removePatchesLayers
M.addRoadDamageAsphalt1Layers =                        addRoadDamageAsphalt1Layers
M.removeRoadDamageAsphalt1Layers =                     removeRoadDamageAsphalt1Layers
M.addRoadDamageAsphalt2Layers =                        addRoadDamageAsphalt2Layers
M.removeRoadDamageAsphalt2Layers =                     removeRoadDamageAsphalt2Layers

M.addRoadCenterLineLayers =                            addRoadCenterLineLayers
M.removeRoadCenterLineLayers =                         removeRoadCenterLineLayers
M.addRoadEdgeLinesLayers =                             addRoadEdgeLinesLayers
M.removeRoadEdgeLinesLayers =                          removeRoadEdgeLinesLayers
M.addRoadLaneLinesLayers =                             addRoadLaneLinesLayers
M.removeRoadLaneLinesLayers =                          removeRoadLaneLinesLayers
M.addEdgeBlend1Layers =                                addEdgeBlend1Layers
M.removeEdgeBlend1Layers =                             removeEdgeBlend1Layers
M.addEdgeBlend2Layers =                                addEdgeBlend2Layers
M.removeEdgeBlend2Layers =                             removeEdgeBlend2Layers
M.addEdgeBlend3Layers =                                addEdgeBlend3Layers
M.removeEdgeBlend3Layers =                             removeEdgeBlend3Layers

M.serializeLayer =                                     serializeLayer
M.deserializeLayer =                                   deserializeLayer

return M