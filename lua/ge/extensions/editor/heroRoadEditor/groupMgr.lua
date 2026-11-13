-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local toolPrefixStr = "Hero Road" -- The global prefix for the hero road tool.
local editModeKey = "heroRoadEditor" -- The edit mode key for this tool.

local minSplineDivisions = 20 -- The minimum number of subdivisions to use for a Road Spline.

local minImportSize = 10.0 -- The minimum size of a Road Spline to import.

local defaultLaneWidthM = 3.65 -- Default lane width, in meters.
local minLaneWidthM = 1.5 -- Minimum allowed lane width, in meters.

local defaultCrossingDepthM = 3.5 -- Default zebra band length along traffic for a new pedestrian crossing.
local crossingClearM = 0.5 -- Keep-clear each side of the band when clamping a crossing inside the road ends.
local defaultRepairLengthM = 8.0 -- Default longitudinal band length for a new repair-patch cluster.
local defaultPotholeRadiusM = 2.0 -- Default rim radius for a new procedural pothole (a real dip carved into the deck mesh).

-- Profile presets: complete cross-section templates.
local profilePresets = {
  -- Fast multi-lane divided road: wide lanes, gentle drainage crown, broad shoulders, gentle high-speed banking, big sweeping corners.
  highway  = { lanesLeft = 2, lanesRight = 2, laneWidthM = 3.65, crownOn = true,  crossfallPct = 2.0,   shoulderWidthM = 3.0, shoulderFallPct = 4.0,  superElevMaxDeg = 6.0,  superMinRadiusM = 300, roadClass = 'highway',   engRadiusM = 150, engTransM = 50, engVertLenM = 60, curveWidenMaxM = 1.2, curveWidenRunoffM = 40, isRoadCenterLine = true,  isRoadEdgeLines = true,  isRoadLaneLines = true  },
  -- Urban street: one lane each way, drainage crown, tight kerb shoulder, minimal banking, moderate junction-scale corners.
  city     = { lanesLeft = 1, lanesRight = 1, laneWidthM = 3.25, crownOn = true,  crossfallPct = 2.5,   shoulderWidthM = 0.3, shoulderFallPct = 6.0,  superElevMaxDeg = 2.0,  superMinRadiusM = 70,  roadClass = 'urban',     engRadiusM = 25,  engTransM = 10, engVertLenM = 30, curveWidenMaxM = 2.0, curveWidenRunoffM = 15, isRoadCenterLine = true,  isRoadEdgeLines = true,  isRoadLaneLines = false },
  -- Rural road: narrower lanes, gravel verge, moderate banking, medium flowing bends.
  country  = { lanesLeft = 1, lanesRight = 1, laneWidthM = 3.0,  crownOn = true,  crossfallPct = 2.5,   shoulderWidthM = 0.6, shoulderFallPct = 12.0, superElevMaxDeg = 5.0,  superMinRadiusM = 120, roadClass = 'rural',     engRadiusM = 70,  engTransM = 25, engVertLenM = 40, curveWidenMaxM = 2.0, curveWidenRunoffM = 25, isRoadCenterLine = true,  isRoadEdgeLines = true,  isRoadLaneLines = false },
  -- Mountain ledge: narrow shelf road, tight hairpin bends, short easements, near-vertical embankment shoulder (steep shoulder fall).
  ledge    = { lanesLeft = 1, lanesRight = 1, laneWidthM = 3.0,  crownOn = true,  crossfallPct = 3.0,   shoulderWidthM = 1.0, shoulderFallPct = 90.0, superElevMaxDeg = 6.0,  superMinRadiusM = 45,  roadClass = 'mountain',  engRadiusM = 14,  engTransM = 6,  engVertLenM = 22, curveWidenMaxM = 3.0, curveWidenRunoffM = 12, isRoadCenterLine = true,  isRoadEdgeLines = true,  isRoadLaneLines = false },
  -- Rally / dirt stage: narrow, low crown, hard banking on tight corners, short snappy transitions, no markings.
  rally    = { lanesLeft = 1, lanesRight = 1, laneWidthM = 2.5,  crownOn = true,  crossfallPct = 1.5,   shoulderWidthM = 0.5, shoulderFallPct = 25.0, superElevMaxDeg = 5.0,  superMinRadiusM = 55,  roadClass = 'rally',     engRadiusM = 20,  engTransM = 8,  engVertLenM = 24, curveWidenMaxM = 2.5, curveWidenRunoffM = 12, isRoadCenterLine = false, isRoadEdgeLines = false, isRoadLaneLines = false },
  -- Race circuit: wide, flat (no crown), heavy banking on corners, big constant-radius sweepers, no markings.
  race     = { lanesLeft = 2, lanesRight = 2, laneWidthM = 4.0,  crownOn = false, crossfallPct = 0.0,   shoulderWidthM = 1.0, shoulderFallPct = 3.0,  superElevMaxDeg = 12.0, superMinRadiusM = 60,  roadClass = 'rural',     engRadiusM = 60,  engTransM = 20, engVertLenM = 40, curveWidenMaxM = 1.5, curveWidenRunoffM = 25, isRoadCenterLine = false, isRoadEdgeLines = false, isRoadLaneLines = false },
  -- Banked oval / speedway: very wide, flat cross-section, extreme banking on tight constant-radius turns, no markings.
  speedway = { lanesLeft = 3, lanesRight = 3, laneWidthM = 4.5,  crownOn = false, crossfallPct = 0.0,   shoulderWidthM = 1.5, shoulderFallPct = 2.0,  superElevMaxDeg = 30.0, superMinRadiusM = 35,  roadClass = 'urban',     engRadiusM = 40,  engTransM = 10, engVertLenM = 40, curveWidenMaxM = 1.5, curveWidenRunoffM = 20, isRoadCenterLine = false, isRoadEdgeLines = false, isRoadLaneLines = false },
  -- Valley / half-pipe: inverted 'smile' crown that falls toward the centre, wide flowing bends, no markings.
  valley   = { lanesLeft = 2, lanesRight = 2, laneWidthM = 4.0,  crownOn = true,  crossfallPct = -12.0, shoulderWidthM = 0.5, shoulderFallPct = 30.0, superElevMaxDeg = 4.0,  superMinRadiusM = 80,  roadClass = 'rural',     engRadiusM = 80,  engTransM = 30, engVertLenM = 45, curveWidenMaxM = 2.0, curveWidenRunoffM = 30, isRoadCenterLine = false, isRoadEdgeLines = false, isRoadLaneLines = false },
}

-- Placeable widening defaults.
local wideningDefaults = { widthM = 3.0, bayLenM = 30.0, taperInM = 40.0, taperOutM = 25.0 }

-- Placeable barrier defaults (a guardrail run dropped at a spot, e.g. through a corner). lengthM is the along-road extent;
-- zOffsetM is an EXTRA vertical tweak on top of the type's standard burial (barrierMgr.barrierSinkM), so 0 = the standard seat.
local barrierDefaults = { lengthM = 30.0, offsetM = 0.5, zOffsetM = 0.0, side = 'right', type = 'guardrail' }

-- Default flare/length/bevel for a new junction bell-mouth (also the slider reset-to values). A junction is a one-sided
-- widening whose corners are rounded (bevel) and whose outer edge line is gapped across the mouth so a side road can join.
local junctionDefaults = { flareM = 4.0, lengthM = 8.0, bevelM = 2.5 } -- bevelM = corner radius; small so the straight throat (neck) is the bulk of the flare, not one big curve.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}
local logTag = 'heroRoadEditor'

-- Module dependencies.
local buffer = require('string.buffer')
local layerMgr = require('editor/heroRoadEditor/layerMgr')
local meshMgr = require('editor/heroRoadEditor/mesh')
local profile = require('editor/heroRoadEditor/profile')
local sidewalkMgr = require('editor/heroRoadEditor/sidewalkMgr')
local barrierMgr = require('editor/heroRoadEditor/barrierMgr')
local exportMgr = require('editor/heroRoadEditor/exportMgr')
local geom = require('editor/toolUtilities/geom')
local engineeredGeom = require('editor/toolUtilities/engineeredGeom')
local curveWiden = require('editor/toolUtilities/curveWiden')
local util = require('editor/toolUtilities/util')
local kitPlacer = require('editor/toolUtilities/kitPlacer')
local paint = require('editor/toolUtilities/terrainPainter')
local terra = require('editor/terraform/terraform')
local regionStyles = require('editor/toolUtilities/regionStyles')
local session = require('editor/toolUtilities/session')

-- Module constants.
local abs, min, max, floor, sqrt = math.abs, math.min, math.max, math.floor, math.sqrt

-- Module state.
local groups = {}
local groupMap = {}
local tmpPoint2I = Point2I(0, 0)


-- Default width/bay/taper for a new widening (also the slider reset-to values in the UI).
local function wideningDefaultsGet() return wideningDefaults end

-- Total along-road extent (m) of a widening: entry taper + full-width bay + exit taper. Used for end-clearance clamping.
local function wideningExtent(w) return (w.taperInM or 0.0) + (w.bayLenM or 0.0) + (w.taperOutM or 0.0) end

-- Default flare/length/bevel for a new junction bell-mouth (also the slider reset-to values in the UI).
local function junctionDefaultsGet() return junctionDefaults end

-- Total along-road extent (m) of a junction mouth: near bevel + throat + far bevel. Used for end-clearance clamping and,
-- via the widening trapezoid mapping, for the mesh flare (widthM=flareM, taperIn=taperOut=bevelM, bayLen=lengthM).
local function junctionExtent(j) return 2.0 * (j.bevelM or 0.0) + (j.lengthM or 0.0) end

-- Gets the current road splines array.
local function getGroups() return groups end

-- Gets the group id -> index map.
local function getIdToIdxMap() return groupMap end

-- Gets the prefix string for the tool.
local function getToolPrefixStr() return toolPrefixStr end

-- Gets the edit mode key for the road spline tool.
local function getEditModeKey() return editModeKey end

-- Adds a group to the groups array.
local function addGroupToGroupArray(group)
  -- Ensure we have a unique group name.
  local baseName = group.name or string.format(toolPrefixStr .. " %d", #groups + 1)
  local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)

  -- Create a new folder for the group.
  if not group.sceneTreeFolderId or not scenetree.findObjectById(group.sceneTreeFolderId) then
    local newFolder = createObject("SimGroup")
    local folderNameId = Engine.generateUUID()
    newFolder:registerObject(string.format("%s - %s", uniqueName, folderNameId))
    scenetree.MissionGroup:addObject(newFolder)
    group.sceneTreeFolderId = newFolder:getId()
  end

  -- The folder's persistence tracks the road state.
  local folder = scenetree.findObjectById(group.sceneTreeFolderId)
  if folder then folder.canSave = group.isEnabled == false end

  -- Add the group to the groups collection.
  table.insert(groups, group)
end

-- Removes the group at the given index.
local function removeGroup(idx)
  local group = groups[idx]
  if group then
    paint.revert(group) -- Restore any terrain paint before the group goes away (no-op if none).
    terra.restoreBaseline(group) -- Undo this road's terraform carve too, so deleting it cleans up the terrain.
    layerMgr.removeAllLayers(group) -- Remove all layers associated with the group.
    meshMgr.removeMesh(group) -- Remove the drivable procedural surface mesh.
    sidewalkMgr.removeGroup(group) -- Remove the sidewalk/kerb mesh.
    barrierMgr.removeGroup(group) -- Remove the placed barrier / lamp-post instances.
    table.clear(group.chunkStartIndices)
    table.clear(group.chunkEndIndices)
    group.numChunks = 0
    if group.sceneTreeFolderId then
      local folder = scenetree.findObjectById(group.sceneTreeFolderId)
      if folder then
        folder:delete() -- Delete the folder associated with the group, if it exists.
      end
    end
    table.remove(groups, idx) -- Remove the group from the groups collection.
  end
  util.computeIdToIdxMap(groups, groupMap) -- Recompute the group id -> index map.
end

-- Removes a linked road spline by ID (called from master spline layer removal).
local function removeLinkedRoadSpline(splineId)
  local idx = groupMap[splineId]
  if idx then
    removeGroup(idx)
  end
end

-- Removes all groups from the session.
local function removeAllGroups(isIncludeDisabled)
  if isIncludeDisabled then
    for i = #groups, 1, -1 do
      local group = groups[i]
      if group then
        removeGroup(i)
      end
    end
    table.clear(groups)
  else
    for i = #groups, 1, -1 do
      local group = groups[i]
      if group.isEnabled then -- Only remove enabled groups.
        removeGroup(i)
      end
    end
  end
end

-- Keeps the sparse per-corner override array index-aligned with the nodes.
local function ensureCornerArray(group)
  local c = group.corners or {}
  group.corners = c
  local nN = #group.nodes
  for i = #c + 1, nN do c[i] = false end
  for i = #c, nN + 1, -1 do c[i] = nil end
  return c
end

-- True when the profile is one-way (a side has zero lanes).
local function isOneWayProfile(group)
  local nL = max(0, floor(group.lanesLeft or 1))
  local nR = max(0, floor(group.lanesRight or 1))
  return nL == 0 or nR == 0
end

-- Derives the carriageway width from the lane profile.
local function syncProfileWidth(group)
  local nL = max(0, floor(group.lanesLeft or 1))
  local nR = max(0, floor(group.lanesRight or 1))
  if nL + nR < 1 then nL, nR = 1, 1 end
  group.lanesLeft, group.lanesRight = nL, nR
  local lw = max(minLaneWidthM, group.laneWidthM or defaultLaneWidthM)
  group.laneWidthM = lw
  local total = (nL + nR) * lw
  group.leftExtM, group.rightExtM = total * 0.5, total * 0.5
  for i = 1, #group.widths do
    group.widths[i] = total
  end
end

-- Applies a profile preset (see profilePresets) to the group.
local function applyProfilePreset(group, key)
  local p = group and profilePresets[key]
  if not p then return end
  for k, v in pairs(p) do group[k] = v end
  syncProfileWidth(group)
  group.isDirty = true
end

-- One-shot 'Drape to Terrain'.
local function conformGroupToTerrain(group)
  if not group or not group.nodes then return end
  local nodes = group.nodes
  for i = 1, #nodes do
    local h = core_terrain.getTerrainHeight(nodes[i])
    if h then nodes[i].z = h end
  end
  group.isDirty = true
end

-- Removes all auto-generated (hidden) layers, then recreates them.
local function recreateAutoGeneratedLayers(group)
  -- Remove all auto-generated layers.
  layerMgr.removeAllHiddenLayers(group)

  -- Recreate the auto-generated decal road layers.
  if group.isLightTreadMarks then layerMgr.addLightTreadMarksLayers(group) end
  if group.isHeavyTreadMarks then layerMgr.addHeavyTreadMarksLayers(group) end
  if group.isRepair1 then layerMgr.addRepair1Layers(group) end
  if group.isRepair2 then layerMgr.addRepair2Layers(group) end
  if group.isDamageAsphalt1 then layerMgr.addRoadDamageAsphalt1Layers(group) end
  if group.isDamageAsphalt2 then layerMgr.addRoadDamageAsphalt2Layers(group) end
  if group.isRoadCrack then layerMgr.addRoadCrackLayers(group) end
  if group.isPatches then layerMgr.addPatchesLayers(group) end
  if group.isRoadCenterLine then layerMgr.addRoadCenterLineLayers(group) end
  if group.isRoadEdgeLines then layerMgr.addRoadEdgeLinesLayers(group) end
  if group.isRoadLaneLines then layerMgr.addRoadLaneLinesLayers(group) end
  if group.isEdgeBlend1 then layerMgr.addEdgeBlend1Layers(group) end
  if group.isEdgeBlend2 then layerMgr.addEdgeBlend2Layers(group) end
  if group.isEdgeBlend3 then layerMgr.addEdgeBlend3Layers(group) end

  -- Mark the group as dirty so the layers get properly updated and rendered
  group.isDirty = true
end

-- Drag hide: tear down a group's heavy rendered geometry.
local function clearGroupVisuals(group)
  local hadMesh = group.meshId ~= nil
  meshMgr.removeMesh(group)
  sidewalkMgr.removeGroup(group)
  barrierMgr.removeGroup(group)
  layerMgr.clearAllLayerDecals(group) -- hide the decals ONLY: keep the layer defs so the release rebuild restores them (removeAllLayers would delete the artist's manual layers).
  if hadMesh and be and be.reloadCollision then be:reloadCollision() end
end

-- A junction bevel is a short feature (default ~6 m) whose smoothstep flare needs several stations to read as a smooth symmetric curve.
local function densifyJunctionSpans(group)
  local list = group.junctions
  if not list or #list == 0 then return end
  local div = group.divPoints
  local n = div and #div or 0
  if n < 3 then return end
  local divWidths, normals = group.divWidths, group.normals
  local divCurv = group.divCurv
  local haveCurv = divCurv and #divCurv == n
  local s = curveWiden.arcLengths(div, n)
  local total = s[n]
  if not total or total <= 1e-6 then return end

  -- Each junction contributes its TWO bevel ranges (the throat between them is flat, left coarse). Same step + length each side
  -- so the resampled grids mirror about the mouth centre => symmetric edge.
  local spans = {}
  for k = 1, #list do
    local j = list[k]
    local bev = max(0.0, j.bevelM or 0.0)
    local halfL = max(0.0, j.lengthM or 0.0) * 0.5
    if bev > 1e-6 then
      local c = min(max(j.t or 0.5, 0.0), 1.0) * total
      local step = max(0.3, bev / 12.0) -- ~12 stations across a bevel; 0.3 m floor so a tiny bevel doesn't explode the count.
      spans[#spans + 1] = { a = max(0.0, c - halfL - bev), b = min(total, c - halfL), step = step } -- near bevel.
      spans[#spans + 1] = { a = max(0.0, c + halfL), b = min(total, c + halfL + bev), step = step } -- far bevel.
    end
    if halfL > 1e-6 then -- the throat (neck): a few stations across the straight flat run so it reads as a clear straight section (not swallowed by the bevels), and the edge line + terraform follow it flat.
      local c = min(max(j.t or 0.5, 0.0), 1.0) * total
      spans[#spans + 1] = { a = max(0.0, c - halfL), b = min(total, c + halfL), step = max(0.5, halfL * 0.5) }
    end
  end
  if #spans == 0 then return end
  table.sort(spans, function(p, q) return p.a < q.a end)
  local merged = {}
  for i = 1, #spans do
    local sp = spans[i]
    local last = merged[#merged]
    if last and sp.a <= last.b + 1e-6 then
      last.b = max(last.b, sp.b); last.step = min(last.step, sp.step)
    else
      merged[#merged + 1] = { a = sp.a, b = sp.b, step = sp.step }
    end
  end

  -- Target arc list: every original station OUTSIDE all bevel ranges (unchanged), plus a uniform grid inside each range.
  local targets = { 0.0, total }
  for i = 1, n do
    local arc, inside = s[i], false
    for m = 1, #merged do if arc > merged[m].a + 1e-6 and arc < merged[m].b - 1e-6 then inside = true; break end end
    if not inside then targets[#targets + 1] = arc end
  end
  for m = 1, #merged do
    local mm = merged[m]
    local len = mm.b - mm.a
    local cnt = max(1, floor(len / mm.step + 0.5))
    for g = 0, cnt do targets[#targets + 1] = mm.a + len * (g / cnt) end
  end
  table.sort(targets)
  local uniq = {}
  for i = 1, #targets do
    local a = min(max(targets[i], 0.0), total)
    if #uniq == 0 or a - uniq[#uniq] > 1e-4 then uniq[#uniq + 1] = a end
  end
  if #uniq <= n then return end -- grid landed on existing stations; nothing to add.

  -- Resample every per-station array at the target arcs by walking the ORIGINAL polyline (linear interp; sub-cm on a dense
  -- curve). Fresh output tables so we never overwrite a source station still needed by a later target.
  local m2 = #uniq
  local outDiv = {}
  local outW = {}
  local outNrm = {}
  local outCurv = haveCurv and {} or nil
  local seg = 1
  for i = 1, m2 do
    local a = uniq[i]
    while seg < n and s[seg + 1] < a do seg = seg + 1 end
    local i0 = seg
    local i1 = min(n, seg + 1)
    local s0, s1 = s[i0], s[i1]
    local t = (s1 > s0) and ((a - s0) / (s1 - s0)) or 0.0
    if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
    local p0, p1 = div[i0], div[i1]
    outDiv[i] = vec3(p0.x + (p1.x - p0.x) * t, p0.y + (p1.y - p0.y) * t, p0.z + (p1.z - p0.z) * t)
    local w0, w1 = divWidths[i0] or 0.0, divWidths[i1] or 0.0
    outW[i] = w0 + (w1 - w0) * t
    local a0v, a1v = normals[i0], normals[i1]
    local nx = vec3(a0v.x + (a1v.x - a0v.x) * t, a0v.y + (a1v.y - a0v.y) * t, a0v.z + (a1v.z - a0v.z) * t)
    if nx:squaredLength() < 1e-10 then nx:set(0, 0, 1) else nx:normalize() end
    outNrm[i] = nx
    if haveCurv then outCurv[i] = divCurv[i0] + (divCurv[i1] - divCurv[i0]) * t end
  end

  -- Remap discMap (node -> divPoint index) to the nearest new station at each node's original arc.
  local discMap = group.discMap
  if discMap then
    for jn = 1, #discMap do
      local oldIdx = discMap[jn]
      if oldIdx and oldIdx >= 1 and oldIdx <= n then
        local nodeArc, best, bestD = s[oldIdx], 1, 1e30
        for i = 1, m2 do local d = abs(uniq[i] - nodeArc); if d < bestD then bestD, best = d, i end end
        discMap[jn] = best
      end
    end
  end

  -- Write back into the EXISTING arrays (keep table identity for any held references), extending / trimming to the new count.
  for i = 1, m2 do div[i], divWidths[i], normals[i] = outDiv[i], outW[i], outNrm[i] end
  for i = m2 + 1, n do div[i], divWidths[i], normals[i] = nil, nil, nil end
  if haveCurv then
    for i = 1, m2 do divCurv[i] = outCurv[i] end
    for i = m2 + 1, n do divCurv[i] = nil end
  end
  geom.computeFrenetFrame(group) -- rebuild tangents/binormals/normals from the new (denser) station set.
end

-- Samples the group's centerline into its divPoints/divWidths/normals/discMap.
local function sampleCenterline(group, lonRes)
  if group.geometryMode == 'engineered' then
    engineeredGeom.buildCenterlineFree(group, { R = group.engRadiusM, Ls = group.engTransM, vertLen = group.engVertLenM, lonRes = lonRes, deckZ = true, minR = profile.minSafeRadius(group) })
  else
    group.divCurv = nil -- drop any exact-curvature array from a prior engineered pass so profile.lua uses its finite-diff estimate.
    geom.catmullRomFree(group, lonRes, true) -- deckZ=true: smooth centripetal CR Z (see the long note at the caller).
  end
  densifyJunctionSpans(group) -- insert dense, symmetric stations across each junction's bevels.
  curveWiden.applyDivWidthWiden(group)
end

-- Updates the dirty groups.
local function updateDirtyGroups(dragging)
  local rebuiltAny = false -- did any group/layer actually rebuild this pass? (-> the document has an unsaved edit).
  for i = 1, #groups do
    local group = groups[i]
    if group.isDirty then
      rebuiltAny = true
      -- Disabled groups never build the live procedural surface.
      if not group.isEnabled then
        -- A disabled/baked MESH road drops its live terrain paint (the deck/static is its surface). A TERRAIN road (isMesh=false)
        -- keeps its paint -- the paint IS the road surface and, like the terraform, lives in the level terrain when finalised.
        if group.isMesh ~= false then paint.revert(group) end
        local hadMesh = group.meshId ~= nil
        meshMgr.removeMesh(group)
        if exportMgr.hasBaked(group) and #group.nodes >= 2 then
          -- serialize cleared divPoints -- recompute the spline geometry the decals ride.
          sampleCenterline(group, group.lonRes or minSplineDivisions)
          geom.updateRibPointsFree(group)
          exportMgr.applyState(group)
          recreateAutoGeneratedLayers(group)
          layerMgr.updateAllLayers(group, i)
          groups[i].roadLength = group.geometryMode == 'engineered' and util.getPolyLength(group.divPoints) or util.getPolyLength(group.nodes)
        else
          layerMgr.removeAllLayers(group) -- plain-disabled (or too few nodes): no static, no markings.
          if hadMesh and be and be.reloadCollision then be:reloadCollision() end -- Tear down the removed procedural collision.
        end
      -- Check if group has enough nodes to be valid (minimum 2).
      elseif #group.nodes < 2 then
        paint.revert(group) -- too few nodes to define a footprint: drop any paint (no-op if none).
        -- Remove all layers and clear secondary geometry when insufficient nodes.
        layerMgr.removeAllLayers(group)
        meshMgr.removeMesh(group)
        sidewalkMgr.removeGroup(group)
        barrierMgr.removeGroup(group) -- Remove any placed barrier / lamp-post instances.
        -- Clear secondary geometry arrays
        table.clear(group.ribPoints)
        table.clear(group.divPoints)
        table.clear(group.divWidths)
        table.clear(group.tangents)
        table.clear(group.binormals)
        table.clear(group.normals)
        table.clear(group.discMap)
        table.clear(group.chunkStartIndices)
        table.clear(group.chunkEndIndices)
        group.numChunks = 0
        group.roadLength = 0.0
      else
        syncProfileWidth(group) -- Lane profile is authoritative: derive node widths from lanesLeft/lanesRight x laneWidthM.
        local lonRes = group.lonRes or minSplineDivisions
        -- Always free 3D: nodes keep their authored Z.
        sampleCenterline(group, lonRes)
        geom.updateRibPointsFree(group) -- Update the rib points.
        groups[i].roadLength = group.geometryMode == 'engineered' and util.getPolyLength(group.divPoints) or util.getPolyLength(group.nodes)

        -- While dragging a node/gizmo, stop here.
        -- switched back on. nil counts as on (default).
        local previewOff = group.previewMesh == false
        if not dragging and not previewOff and group.isMesh == false then
          -- TERRAIN ROAD (isMesh=false): no lofted deck.
          local hadMesh = group.meshId ~= nil
          meshMgr.removeMesh(group)
          meshMgr.buildTerrainEdges(group) -- flat, world-up carriageway edge frames for furniture / sidewalks / ribbon.
          sidewalkMgr.updateGroup(group)
          barrierMgr.updateGroup(group)
          if hadMesh and be and be.reloadCollision then be:reloadCollision() end -- clear the removed deck collision (terrain carries collision).
          recreateAutoGeneratedLayers(group)
          layerMgr.updateAllLayers(group, i)
          -- Paint is the surface here, so follow the footprint whenever it's on (auto-enabled when the road is switched to terrain).
          if group.isPainting then
            paint.revert(group)
            paint.paint(group)
          end
        elseif not dragging and not previewOff then
          -- Build the drivable mesh FIRST, then reload collision, THEN lay the decals: marking draping uses overObjects,
          -- which is a physics raycast onto the collision mesh -- so the mesh collision must exist before the decals
          -- regenerate or they fall through to the terrain instead of sitting on the road (same as roadNetwork).
          meshMgr.updateMesh(group) -- Rebuild the drivable procedural surface mesh (+ collision).
          sidewalkMgr.updateGroup(group) -- (Re)sweep the kerb + paving along the freshly-built banked mesh edge.
          barrierMgr.updateGroup(group) -- (Re)place barriers / lamp posts along the banked mesh edge.
          if be and be.reloadCollision then be:reloadCollision() end

          -- Regenerate auto-generated layers to ensure they cover the current road width.
          recreateAutoGeneratedLayers(group)

          layerMgr.updateAllLayers(group, i) -- Update all the layers (decals drape onto the now-collidable mesh).

          -- Terrain paint follows the road: repaint the freshly-built footprint (revert the old cells first so a moved/resized
          -- road doesn't leave stale paint behind). Toggle is the per-group isPainting; material/margin are on the group.
          if group.isPainting then
            paint.revert(group)
            paint.paint(group)
          end
        else
          -- Dragging OR preview pinned off: the full mesh (and its meshEdgeL/R) is torn down for perf.
          if previewOff then clearGroupVisuals(group) end -- also HIDES all decals (no mesh to drape onto => flicker); layer defs kept for the toggle-on rebuild.
          meshMgr.buildRibbonEdges(group)
          -- Preview pinned off is still a SETTLED state (not a live drag), so terrain paint must keep following the road here
          -- too -- otherwise toggling paint or editing a preview-off road does nothing. The ribbon edges include the widened
          -- footprint (laybys / curve widening), so paint from them exactly like the full-build path. Skipped mid-drag.
          if previewOff and not dragging and group.isPainting then
            paint.revert(group)
            paint.paint(group)
          end
        end
      end

      groups[i].isDirty = false
    else
      -- The group is not dirty, but it may contain dirty layers (a marking edit) -- that still counts as a document change.
      local layers = group.layers
      local anyDirty = false
      if layers then for li = 1, #layers do if layers[li].isDirty then anyDirty = true; break end end end
      if anyDirty then rebuiltAny = true end
      if group.previewMesh == false then
        -- Preview pinned off: there's no mesh to drape onto, so don't build decals (they'd flicker on the terrain). Hide any that a
        -- layer add/edit just created and consume the dirty flags; toggling preview back on marks the group dirty and rebuilds them all.
        if anyDirty then
          layerMgr.clearAllLayerDecals(group)
          for li = 1, #layers do layers[li].isDirty = false end
        end
      else
        layerMgr.updateOnlyDirtyLayers(group, i)
      end
    end
  end
  -- Fold this pass's edits into the Save/Save As dirty state (once per pass so a fresh load's forced rebuild is swallowed by the
  -- session load guard). Terrain-only changes don't set group/layer dirty, matching how they're excluded from the saved session.
  if rebuiltAny then session.markEdited('heroRoadEditor') end
end

-- Light rebuild for groundmodel painting.
local function rebuildSurfaceOnly(group)
  if not group or not group.isEnabled or group.isMesh == false or group.previewMesh == false or #group.nodes < 2 then return end
  meshMgr.updateMesh(group) -- re-sweeps the deck (routing painted quads to their material submesh) + rebuilds this road's collision.
  if be and be.reloadCollision then be:reloadCollision() end -- sync the physics world so the new groundmodels take effect.
end

-- Sets the width of the group to a fixed value at every node.
local function setFixedWidth(group, width)
  for i = 1, #group.widths do
    group.widths[i] = width
  end
  group.isDirty = true
end

-- Sets the lane profile (lane counts + optional lane width) and marks the group dirty so widths/markings rebuild.
local function setLaneProfile(group, lanesLeft, lanesRight, laneWidthM)
  if not group then return end
  group.lanesLeft = lanesLeft
  group.lanesRight = lanesRight
  if laneWidthM ~= nil then group.laneWidthM = laneWidthM end
  syncProfileWidth(group)
  group.isDirty = true
end

-- Adds a new group.
local function addNewGroup(name)
  -- Ensure we have a unique group name.
  local baseName = name or string.format(toolPrefixStr .. " %d", #groups + 1)
  local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)
  local id = Engine.generateUUID()

  -- Create a new folder for the group.
  local newFolder = createObject("SimGroup")
  newFolder:registerObject(string.format("%s - %s", uniqueName, id))
  scenetree.MissionGroup:addObject(newFolder)
  newFolder.canSave = false -- new roads start in Edit: the folder is transient, so a level save leaves no ghost (applyState flips it on bake).

  -- Create the new group.
  local regionStyle = regionStyles.getRegion('usa') -- Hero roads seed USA markings (double-yellow centre, white edges); edit per road in the Layers tab.
  local newGroup = {
    name = uniqueName,
    id = id,
    isLoop = false,
    isMesh = true, -- Generate the drivable procedural surface mesh (this tool's purpose).

    -- Cross-section profile (crown crossfall, shoulders, curvature-driven superelevation).
    crownOn = true,
    crossfallPct = 2.5,
    flatEnds = false, -- ramp the crown/bank/shoulder-fall out to a flat, horizontal cross-section over the last flatEndLenM at each open end (for clean joins to hand-shaped flat terrain).
    flatEndLenM = 6.0,
    shoulderWidthM = 0.5,
    shoulderFallPct = 6.0,
    superElevMaxDeg = 6.0,
    superMinRadiusM = 80.0,

    -- Centerline geometry mode. 'engineered'.
    geometryMode = 'engineered',
    engRadiusM = 40.0, -- Engineered: design (arc) radius at each rounded corner. Auto-shrinks on sharp/short corners. (Matches the slider default + backfill.)
    engTransM = 15.0,  -- Engineered: transition (clothoid) length -- how gradually curvature ramps 0 -> 1/R (steering onset).
    engVertLenM = 40.0, -- Engineered: vertical-curve length (m) at each grade break -- parabolic crest/sag smoothing of the height profile.
    curveWidenMaxM = 2.5,     -- Engineered: max carriageway widening (m, split both sides) reached on the tightest corners; 0 = never widen.
    curveWidenRunoffM = 20.0, -- Engineered: how gradually the widening eases in/out (m); decoupled from engTransM so a hairpin still tapers smoothly.

    -- Design standard the grade/corner-radius heatmap scores this road against (see heatmap.classes). Authored per road
    -- (persists + undo), preset-driven. The heatmap's on/off + metric is a session-global view mode (heroRoadEditor), not here.
    roadClass = 'rural',

    -- Mesh resolution.
    latRes = 16, -- Lateral subdivisions per side across the carriageway (higher = smoother crown). Dense base -- LOD0 refine sheds the excess.
    lonRes = 100, -- Minimum longitudinal subdivisions per spline segment (higher = smoother/denser along the road). Dense base -- LOD0 refine sheds the excess.
    chamferWidthM = 0.6, -- Perimeter chamfer flare-out width (m): a shallow asphalt valance overhanging the terrain seam to hide it.
    chamferDropM = 0.1, -- Perimeter chamfer vertical drop (m) from the deck outer edge down to the rim (shallow = overhangs, hides seam).
    chamferAngleDeg = 9.5, -- Chamfer downward tilt (deg); keeps the facet length (0 = flat lip, 70 max = a steep skirt).
    sideChamfers = true, -- Chamfer along both sides (off = the deck stops at the outer edge, e.g. to butt drains against it).
    endChamfers = true, -- Chamfer across the start and end (off = square, bare ends for butting against another road).
    -- Baked LOD ladder + collision (Export tab). Only used by the bake; the live editor mesh is always full detail (LOD0).
    lodSize0 = 400, -- LOD0 detail size (px): the NEAR level, seen close up. This is also the LIVE editable/drivable mesh.
    lodSize1 = 150, -- LOD1 detail size (px): first coarser level.
    lodSize2 = 40,  -- Far LOD size (px): a coarsest visible level, OR (when lodFarNull) the 'nulldetail' size the shape vanishes below.
    -- Per-LOD refine settings: each level has its OWN decimation Quality (cm surface deviation) + Max tri length (m). LOD0 is
    -- the live drivable near mesh -- you drive/test exactly what ships as LOD0. Progressively larger tolerances = coarser levels.
    lodQualityCm0 = 1.0, lodMaxSegM0 = 20, -- LOD0 (near / live): fine -- sheds dead-flat coplanar tris only.
    lodQualityCm1 = 3.0, lodMaxSegM1 = 30, -- LOD1 (mid).
    lodQualityCm2 = 8.0, lodMaxSegM2 = 45, -- LOD2 (far, when visible).
    lodFarNull = true, -- Far LOD = no mesh: the far slot (lodSize2) becomes a 'nulldetail' level -> below it the shape renders nothing (terrain + decals carry it) instead of clamping to a visible LOD.
    collisionTolCm = 1.0, -- Collision detail (cm): the deck-only collision mesh follows the visible surface to within this (0 = exact).
    chunkLenM = 120, -- Export chunk length (m): baked DAE is split into pieces this long. Tuned for per-object occlusion/frustum culling on terrain-hugging roads (well under the 2048 m local range).

    -- Procedural sidewalks / kerbs (shared footway sweeper). Ride the banked mesh edge; terraform seals to their outer rail.
    sidewalkLeft = false,
    sidewalkRight = false,
    sidewalkOffsetM = 0.0, -- Lateral gap (m) from the mesh outer (deck/shoulder) edge to the kerb inner edge.

    -- Roadside furniture (shared prop-line placer). Instanced stock art assets that ride the banked mesh edge.
    barrierLeftType = 'none', -- 'none' | 'jersey' | 'plastic' | 'guardrail'. Barriers lean with the road.
    barrierRightType = 'none',
    barrierOffsetM = 0.5, -- Lateral gap (m) from the mesh outer edge to the barrier line.
    fenceLeftType = 'none', -- 'none' | 'fence' (metal) | 'chainlink'. Separate slot so a side can have a barrier AND a fence.
    fenceRightType = 'none',
    fenceOffsetM = 0.7, -- Lateral gap (m) from the mesh outer edge to the fence line (usually just outboard of the barrier).
    lampLeftType = 'none', -- 'none' | 'lampMast' | 'lampVictorian' | 'lampStreet' | 'lampHighway' | 'lampSidewalk'. Lamp posts stand world-up.
    lampRightType = 'none',
    lampOffsetM = 1.0, -- Lateral gap (m) from the mesh outer edge to the lamp-post line.
    lampSpacingM = 25.0, -- Centre-to-centre spacing (m) between lamp posts.

    -- Drivable-surface materials (the mesh IS the asphalt; markings drape on top) + their UV tiling (m per texture repeat).
    carriagewayMaterial = 'm_asphalt_new_01',
    shoulderMaterial = 'm_asphalt_new_01',
    carriagewayTexLenM = 4.0, -- Tile length along the road.
    carriagewayTexWidth = 4.0, -- Tile width across the road.
    shoulderTexLenM = 4.0,
    shoulderTexWidth = 4.0,

    -- Marking materials for the auto-generated centre / edge / lane-division decals (overridable per road) + their tex length.
    -- Seeded from the USA style; the Materials tab can still override per road afterward.
    centerLineMaterial = regionStyle.centerLineMaterial,
    edgeLineMaterial = regionStyle.edgeLineMaterial,
    laneLineMaterial = regionStyle.laneLineMaterial,
    centerLineTexLen = regionStyle.centerLineTexLen or 5.0,
    edgeLineTexLen = 10.0,
    laneLineTexLen = 10.0,

    -- Per-road texture tile length (m per repeat) for the auto-generated detail overlays (toggled in the Layers tab, sized
    -- in the Materials tab). Defaults match the module fallbacks in layerMgr.
    lightTreadTexLen = 5.0,
    heavyTreadTexLen = 5.0,
    repair1TexLen = 25.0,
    repair2TexLen = 25.0,
    damageAsphalt1TexLen = 10.0,
    damageAsphalt2TexLen = 25.0,
    patchesTexLen = 45.0,
    roadCrackTexLen = 15.0,

    sceneTreeFolderId = newFolder:getId(),
    isEnabled = true,
    isDirty = false,
    roadLength = 0.0,

    -- Lane profile (roadNetwork-style): integer lanes per side x lane width drives the carriageway width.
    lanesLeft = 1,
    lanesRight = 1,
    laneWidthM = defaultLaneWidthM,
    leftExtM = defaultLaneWidthM,
    rightExtM = defaultLaneWidthM,

    -- Terrain painting (toggle, like roadSpline). isPainting drives the repaint in updateDirtyGroups. Not serialized: like the
    -- terraform result the paint lives in the level terrain, and the settings (margin/material) travel with the session globals.
    isPainting = false,
    paintMargin = 2.0,
    paintMaterialIdx = 0,
    paintedDataX = {},
    paintedDataY = {},
    paintedDataVals = {},
    paintedDataBoxXMin = 0,
    paintedDataBoxXMax = 0,
    paintedDataBoxYMin = 0,
    paintedDataBoxYMax = 0,

    -- Pedestrian crossings placed along the road (s-position only; span the carriageway). Each: { id, t, depthM, lateral }.
    -- Plain data, so it rides the buffer deep-copy / session serialize automatically (crossingDecalIds is runtime, stripped).
    crossings = {},

    -- Repair-patch clusters placed along the road (a seeded scatter of asphalt-patch decals; surface-only, no mesh impact).
    -- Each: { id, name, t, lengthM, coverage, offset, density, sizeMin, sizeMax, rotJitter, material, seed }. Plain data --
    -- the live decal handles live in repairMgr's module store (keyed by group.id), never on the group (can't serialize userdata).
    repairs = {},

    -- Procedural potholes carved directly into the deck mesh (real geometry + collision, not decals): a normal-aligned crater
    -- displacement with local quad subdivision under each footprint. Each: { id, name, t, lateralM, radiusM, depthM, rimSharp,
    -- irregular, seed }. Plain data (rides the buffer deep-copy / session serialize); the mesh reads it at assemble time.
    potholes = {},

    -- Placeable widenings (laybys / overtaking lanes / stopping areas): a local one-sided FLAT carriageway widening with
    -- smoothstep entry/exit tapers, reshaped into the swept deck by profile.lua. Each: { id, name, type, side, widthM,
    -- bayLenM, taperInM, taperOutM, t }. Plain data (rides the buffer deep-copy / session serialize); the cross-section
    -- builder reads it at build time, so terraform / collision / sidewalks / bake all follow the widened footprint.
    widenings = {},

    -- Junction bell-mouths (this road is the trunk): a one-sided mesh flare with rounded (beveled) corners where a side road
    -- joins; the trunk's outer edge line bevels around the mouth. Each: { id, name, t, side, flareM, lengthM, bevelM, giveWay,
    -- exitCenterline, breakEdge }. Plain data (rides the buffer deep-copy / session serialize); the flare is folded into the widening
    -- flatExt so the mesh/terraform/collision follow, and layerMgr reshapes the markings (edge bevel + give-way bar + exit centreline).
    junctions = {},

    -- Placeable barriers (Features tab): guardrail/jersey/plastic segments dropped at specific spots (like a widening), each
    -- riding the banked mesh edge over an arc-length window. Each: { id, name, t, side, lengthM, offsetM, type }. Plain data;
    -- barrierMgr places one prop-line per segment after the mesh rebuild (independent of the whole-road Furniture-tab barriers).
    barriers = {},

    -- Groundmodel paint: world-space stamps { x, y, r, m } (m = surfaceKit palette index; 1 = Dry/base) routed onto carriageway
    -- quads as physics groundmodels. World-space so it survives re-splining / resolution changes; rasterised each build. Plain data.
    surfaceStamps = {},

    -- Sparse per-corner engineering overrides, one slot per node (false = auto, table = { radiusM, extraWidenM, apron,
    -- superElevDeg, taperM }). Only interior corners read it; kept index-aligned with nodes by splineInput + ensureCornerArray.
    corners = {},

    nodes = {},
    widths = {},
    nmls = {},
    ribPoints = {},
    divPoints = {},
    divWidths = {},
    tangents = {},
    binormals = {},
    normals = {},
    discMap = {},
    layers = {},
    isOverObjects = false,
    isLightTreadMarks = true,
    isHeavyTreadMarks = false,
    isDamageAsphalt1 = false,
    isDamageAsphalt2 = false,
    isRoadCrack = false,
    isRepair1 = false,
    isRepair2 = false,
    isPatches = false,
    isRoadCenterLine = true,
    isRoadEdgeLines = true,
    isRoadLaneLines = true,
    isEdgeBlend1 = false,
    isEdgeBlend2 = false,
    isEdgeBlend3 = false,

    -- Placement/size of the auto-generated edge decals. Road-level (not layer) properties: offset is a lateral
    -- position multiplier where 1.0 == the road edge (scales with road width), width is the decal width in metres.
    edgeLineOffset = 1.0,
    edgeLineWidth = 0.25,
    edgeBlend1Offset = 1.1,
    edgeBlend1Width = 1.0,
    edgeBlend2Offset = 1.25,
    edgeBlend2Width = 2.0,
    edgeBlend3Offset = 1.35,
    edgeBlend3Width = 3.0,

    -- Chunk data for long splines.
    chunkStartIndices = {},
    chunkEndIndices = {},
    numChunks = 0,
  }

  -- Create the initial auto-generated (hidden) layers.
  recreateAutoGeneratedLayers(newGroup)

  -- Add the new group to the groups collection.
  table.insert(groups, newGroup)

  -- Recompute the group id -> index map.
  util.computeIdToIdxMap(groups, groupMap)
end

-- Copies the layer profile from the given group (only the layers).
local function copyGroupProfile(sourceGroup)
  local profile = {
    layers = {},
    isOverObjects = sourceGroup.isOverObjects,
    isLightTreadMarks = sourceGroup.isLightTreadMarks,
    isHeavyTreadMarks = sourceGroup.isHeavyTreadMarks,
    isRoadCrack = sourceGroup.isRoadCrack,
    isRepair1 = sourceGroup.isRepair1,
    isRepair2 = sourceGroup.isRepair2,
    isPatches = sourceGroup.isPatches,
    isDamageAsphalt1 = sourceGroup.isDamageAsphalt1,
    isDamageAsphalt2 = sourceGroup.isDamageAsphalt2,
    isRoadCenterLine = sourceGroup.isRoadCenterLine,
    isRoadEdgeLines = sourceGroup.isRoadEdgeLines,
    isRoadLaneLines = sourceGroup.isRoadLaneLines,
    isEdgeBlend1 = sourceGroup.isEdgeBlend1,
    isEdgeBlend2 = sourceGroup.isEdgeBlend2,
    isEdgeBlend3 = sourceGroup.isEdgeBlend3,

    -- Cross-section geometry: the profile IS the shape, so Ctrl+C/Ctrl+V (and a saved profile) carries it too.
    lanesLeft = sourceGroup.lanesLeft,
    lanesRight = sourceGroup.lanesRight,
    laneWidthM = sourceGroup.laneWidthM,
    crownOn = sourceGroup.crownOn,
    crossfallPct = sourceGroup.crossfallPct,
    flatEnds = sourceGroup.flatEnds,
    flatEndLenM = sourceGroup.flatEndLenM,
    shoulderWidthM = sourceGroup.shoulderWidthM,
    shoulderFallPct = sourceGroup.shoulderFallPct,
    superElevMaxDeg = sourceGroup.superElevMaxDeg,
    superMinRadiusM = sourceGroup.superMinRadiusM,
    geometryMode = sourceGroup.geometryMode,
    engRadiusM = sourceGroup.engRadiusM,
    engTransM = sourceGroup.engTransM,
    engVertLenM = sourceGroup.engVertLenM,
    curveWidenMaxM = sourceGroup.curveWidenMaxM,
    curveWidenRunoffM = sourceGroup.curveWidenRunoffM,
    latRes = sourceGroup.latRes,
    lonRes = sourceGroup.lonRes,
    chamferWidthM = sourceGroup.chamferWidthM,
    chamferDropM = sourceGroup.chamferDropM,
    chamferAngleDeg = sourceGroup.chamferAngleDeg,
    sideChamfers = sourceGroup.sideChamfers,
    endChamfers = sourceGroup.endChamfers,
    lodSize0 = sourceGroup.lodSize0,
    lodSize1 = sourceGroup.lodSize1,
    lodSize2 = sourceGroup.lodSize2,
    lodQualityCm0 = sourceGroup.lodQualityCm0, lodMaxSegM0 = sourceGroup.lodMaxSegM0,
    lodQualityCm1 = sourceGroup.lodQualityCm1, lodMaxSegM1 = sourceGroup.lodMaxSegM1,
    lodQualityCm2 = sourceGroup.lodQualityCm2, lodMaxSegM2 = sourceGroup.lodMaxSegM2,
    lodFarNull = sourceGroup.lodFarNull,
    collisionTolCm = sourceGroup.collisionTolCm,
    chunkLenM = sourceGroup.chunkLenM,
    sidewalkLeft = sourceGroup.sidewalkLeft,
    sidewalkRight = sourceGroup.sidewalkRight,
    sidewalkOffsetM = sourceGroup.sidewalkOffsetM,
    barrierLeftType = sourceGroup.barrierLeftType,
    barrierRightType = sourceGroup.barrierRightType,
    barrierOffsetM = sourceGroup.barrierOffsetM,
    fenceLeftType = sourceGroup.fenceLeftType,
    fenceRightType = sourceGroup.fenceRightType,
    fenceOffsetM = sourceGroup.fenceOffsetM,
    lampLeftType = sourceGroup.lampLeftType,
    lampRightType = sourceGroup.lampRightType,
    lampOffsetM = sourceGroup.lampOffsetM,
    lampSpacingM = sourceGroup.lampSpacingM,

    -- Surface + marking materials (+ surface UV tiling).
    carriagewayMaterial = sourceGroup.carriagewayMaterial,
    shoulderMaterial = sourceGroup.shoulderMaterial,
    carriagewayTexLenM = sourceGroup.carriagewayTexLenM,
    carriagewayTexWidth = sourceGroup.carriagewayTexWidth,
    shoulderTexLenM = sourceGroup.shoulderTexLenM,
    shoulderTexWidth = sourceGroup.shoulderTexWidth,
    centerLineMaterial = sourceGroup.centerLineMaterial,
    edgeLineMaterial = sourceGroup.edgeLineMaterial,
    laneLineMaterial = sourceGroup.laneLineMaterial,
    centerLineTexLen = sourceGroup.centerLineTexLen,
    edgeLineTexLen = sourceGroup.edgeLineTexLen,
    laneLineTexLen = sourceGroup.laneLineTexLen,

    -- Detail-overlay texture tile lengths.
    lightTreadTexLen = sourceGroup.lightTreadTexLen,
    heavyTreadTexLen = sourceGroup.heavyTreadTexLen,
    repair1TexLen = sourceGroup.repair1TexLen,
    repair2TexLen = sourceGroup.repair2TexLen,
    damageAsphalt1TexLen = sourceGroup.damageAsphalt1TexLen,
    damageAsphalt2TexLen = sourceGroup.damageAsphalt2TexLen,
    patchesTexLen = sourceGroup.patchesTexLen,
    roadCrackTexLen = sourceGroup.roadCrackTexLen,

    edgeLineOffset = sourceGroup.edgeLineOffset,
    edgeLineWidth = sourceGroup.edgeLineWidth,
    edgeBlend1Offset = sourceGroup.edgeBlend1Offset,
    edgeBlend1Width = sourceGroup.edgeBlend1Width,
    edgeBlend2Offset = sourceGroup.edgeBlend2Offset,
    edgeBlend2Width = sourceGroup.edgeBlend2Width,
    edgeBlend3Offset = sourceGroup.edgeBlend3Offset,
    edgeBlend3Width = sourceGroup.edgeBlend3Width,
  }

  local layers, ctr = sourceGroup.layers, 1
  for i = 1, #layers do
    local layer = layers[i]
    if not layer.isHidden then -- Do not copy any auto-generated layers.
      profile.layers[ctr] = layerMgr.serializeLayer(layer)
      ctr = ctr + 1
    end
  end

  return profile
end

-- Pastes a layer profile onto the given group.
local function pasteGroupProfile(targetGroup, profile)
  layerMgr.removeAllLayers(targetGroup)

  for i = 1, #profile.layers do
    targetGroup.layers[i] = layerMgr.deserializeLayer(profile.layers[i])
  end

  targetGroup.isOverObjects = profile.isOverObjects or false
  targetGroup.isLightTreadMarks = profile.isLightTreadMarks or false
  targetGroup.isHeavyTreadMarks = profile.isHeavyTreadMarks or false
  targetGroup.isRoadCrack = profile.isRoadCrack or false
  targetGroup.isRepair1 = profile.isRepair1 or false
  targetGroup.isRepair2 = profile.isRepair2 or false
  targetGroup.isPatches = profile.isPatches or false
  targetGroup.isDamageAsphalt1 = profile.isDamageAsphalt1 or false
  targetGroup.isDamageAsphalt2 = profile.isDamageAsphalt2 or false
  targetGroup.isRoadCenterLine = profile.isRoadCenterLine or false
  targetGroup.isRoadEdgeLines = profile.isRoadEdgeLines or false
  targetGroup.isRoadLaneLines = profile.isRoadLaneLines or false
  targetGroup.isEdgeBlend1 = profile.isEdgeBlend1 or false
  targetGroup.isEdgeBlend2 = profile.isEdgeBlend2 or false
  targetGroup.isEdgeBlend3 = profile.isEdgeBlend3 or false

  -- Cross-section geometry (fall back to the target's own value so older profiles without these fields are valid).
  targetGroup.lanesLeft = profile.lanesLeft or targetGroup.lanesLeft
  targetGroup.lanesRight = profile.lanesRight or targetGroup.lanesRight
  targetGroup.laneWidthM = profile.laneWidthM or targetGroup.laneWidthM
  if profile.crownOn ~= nil then targetGroup.crownOn = profile.crownOn end
  targetGroup.crossfallPct = profile.crossfallPct or targetGroup.crossfallPct
  if profile.flatEnds ~= nil then targetGroup.flatEnds = profile.flatEnds end
  targetGroup.flatEndLenM = profile.flatEndLenM or targetGroup.flatEndLenM
  targetGroup.shoulderWidthM = profile.shoulderWidthM or targetGroup.shoulderWidthM
  targetGroup.shoulderFallPct = profile.shoulderFallPct or targetGroup.shoulderFallPct
  targetGroup.superElevMaxDeg = profile.superElevMaxDeg or targetGroup.superElevMaxDeg
  targetGroup.superMinRadiusM = profile.superMinRadiusM or targetGroup.superMinRadiusM
  if profile.geometryMode ~= nil then targetGroup.geometryMode = profile.geometryMode end
  targetGroup.engRadiusM = profile.engRadiusM or targetGroup.engRadiusM
  targetGroup.engTransM = profile.engTransM or targetGroup.engTransM
  targetGroup.engVertLenM = profile.engVertLenM or targetGroup.engVertLenM
  targetGroup.curveWidenMaxM = profile.curveWidenMaxM or targetGroup.curveWidenMaxM
  targetGroup.curveWidenRunoffM = profile.curveWidenRunoffM or targetGroup.curveWidenRunoffM
  targetGroup.latRes = profile.latRes or targetGroup.latRes
  targetGroup.lonRes = profile.lonRes or targetGroup.lonRes
  targetGroup.chamferWidthM = profile.chamferWidthM or targetGroup.chamferWidthM
  targetGroup.chamferDropM = profile.chamferDropM or targetGroup.chamferDropM
  targetGroup.chamferAngleDeg = profile.chamferAngleDeg or targetGroup.chamferAngleDeg
  if profile.sideChamfers ~= nil then targetGroup.sideChamfers = profile.sideChamfers end
  if profile.endChamfers ~= nil then targetGroup.endChamfers = profile.endChamfers end
  targetGroup.lodSize0 = profile.lodSize0 or targetGroup.lodSize0
  targetGroup.lodSize1 = profile.lodSize1 or targetGroup.lodSize1
  targetGroup.lodSize2 = profile.lodSize2 or targetGroup.lodSize2
  targetGroup.lodQualityCm0 = profile.lodQualityCm0 or targetGroup.lodQualityCm0
  targetGroup.lodQualityCm1 = profile.lodQualityCm1 or targetGroup.lodQualityCm1
  targetGroup.lodQualityCm2 = profile.lodQualityCm2 or targetGroup.lodQualityCm2
  targetGroup.lodMaxSegM0 = profile.lodMaxSegM0 or targetGroup.lodMaxSegM0
  targetGroup.lodMaxSegM1 = profile.lodMaxSegM1 or targetGroup.lodMaxSegM1
  targetGroup.lodMaxSegM2 = profile.lodMaxSegM2 or targetGroup.lodMaxSegM2
  if profile.lodFarNull ~= nil then targetGroup.lodFarNull = profile.lodFarNull end
  targetGroup.collisionTolCm = profile.collisionTolCm or targetGroup.collisionTolCm
  targetGroup.chunkLenM = profile.chunkLenM or targetGroup.chunkLenM
  targetGroup.sidewalkLeft = profile.sidewalkLeft or false
  targetGroup.sidewalkRight = profile.sidewalkRight or false
  targetGroup.sidewalkOffsetM = profile.sidewalkOffsetM or targetGroup.sidewalkOffsetM
  targetGroup.barrierLeftType = profile.barrierLeftType or targetGroup.barrierLeftType
  targetGroup.barrierRightType = profile.barrierRightType or targetGroup.barrierRightType
  targetGroup.barrierOffsetM = profile.barrierOffsetM or targetGroup.barrierOffsetM
  targetGroup.fenceLeftType = profile.fenceLeftType or targetGroup.fenceLeftType
  targetGroup.fenceRightType = profile.fenceRightType or targetGroup.fenceRightType
  targetGroup.fenceOffsetM = profile.fenceOffsetM or targetGroup.fenceOffsetM
  targetGroup.lampLeftType = profile.lampLeftType or targetGroup.lampLeftType
  targetGroup.lampRightType = profile.lampRightType or targetGroup.lampRightType
  targetGroup.lampOffsetM = profile.lampOffsetM or targetGroup.lampOffsetM
  targetGroup.lampSpacingM = profile.lampSpacingM or targetGroup.lampSpacingM

  -- Surface + marking materials.
  targetGroup.carriagewayMaterial = profile.carriagewayMaterial or targetGroup.carriagewayMaterial
  targetGroup.shoulderMaterial = profile.shoulderMaterial or targetGroup.shoulderMaterial
  targetGroup.carriagewayTexLenM = profile.carriagewayTexLenM or targetGroup.carriagewayTexLenM
  targetGroup.carriagewayTexWidth = profile.carriagewayTexWidth or targetGroup.carriagewayTexWidth
  targetGroup.shoulderTexLenM = profile.shoulderTexLenM or targetGroup.shoulderTexLenM
  targetGroup.shoulderTexWidth = profile.shoulderTexWidth or targetGroup.shoulderTexWidth
  targetGroup.centerLineMaterial = profile.centerLineMaterial or targetGroup.centerLineMaterial
  targetGroup.edgeLineMaterial = profile.edgeLineMaterial or targetGroup.edgeLineMaterial
  targetGroup.laneLineMaterial = profile.laneLineMaterial or targetGroup.laneLineMaterial
  targetGroup.centerLineTexLen = profile.centerLineTexLen or targetGroup.centerLineTexLen
  targetGroup.edgeLineTexLen = profile.edgeLineTexLen or targetGroup.edgeLineTexLen
  targetGroup.laneLineTexLen = profile.laneLineTexLen or targetGroup.laneLineTexLen
  -- Detail-overlay texture tile lengths (fall back to the target's own value so older profiles stay valid).
  targetGroup.lightTreadTexLen = profile.lightTreadTexLen or targetGroup.lightTreadTexLen
  targetGroup.heavyTreadTexLen = profile.heavyTreadTexLen or targetGroup.heavyTreadTexLen
  targetGroup.repair1TexLen = profile.repair1TexLen or targetGroup.repair1TexLen
  targetGroup.repair2TexLen = profile.repair2TexLen or targetGroup.repair2TexLen
  targetGroup.damageAsphalt1TexLen = profile.damageAsphalt1TexLen or targetGroup.damageAsphalt1TexLen
  targetGroup.damageAsphalt2TexLen = profile.damageAsphalt2TexLen or targetGroup.damageAsphalt2TexLen
  targetGroup.patchesTexLen = profile.patchesTexLen or targetGroup.patchesTexLen
  targetGroup.roadCrackTexLen = profile.roadCrackTexLen or targetGroup.roadCrackTexLen
  -- Edge decal placement/size. Defaults keep older profiles (saved before these existed) valid, and guarantee the
  -- slider UI always reads a non-nil number.
  targetGroup.edgeLineOffset = profile.edgeLineOffset or 1.0
  targetGroup.edgeLineWidth = profile.edgeLineWidth or 0.25
  targetGroup.edgeBlend1Offset = profile.edgeBlend1Offset or 1.1
  targetGroup.edgeBlend1Width = profile.edgeBlend1Width or 1.0
  targetGroup.edgeBlend2Offset = profile.edgeBlend2Offset or 1.25
  targetGroup.edgeBlend2Width = profile.edgeBlend2Width or 2.0
  targetGroup.edgeBlend3Offset = profile.edgeBlend3Offset or 1.35
  targetGroup.edgeBlend3Width = profile.edgeBlend3Width or 3.0
  targetGroup.isOverObjects = profile.isOverObjects or false

  targetGroup.isDirty = true

  -- Recreate the auto-generated layers.
  recreateAutoGeneratedLayers(targetGroup)
end

-- 2D (plan-view) arc length of the group's centreline (divPoints).
local function divLength(group)
  local div = group and group.divPoints
  if not div or #div < 2 then return 0 end
  local total = 0
  for i = 2, #div do total = total + sqrt((div[i].x - div[i - 1].x) ^ 2 + (div[i].y - div[i - 1].y) ^ 2) end
  return total
end

-- Clamp a normalized crossing position so the band (+ a small clearance) stays clear of both road ends. With no room
-- (too-short road) the crossing still gets placed at mid-road.
local function clampCrossingT(group, t01, depthM)
  local total = divLength(group)
  if total <= 1e-6 then return min(max(t01, 0), 1) end
  local half = ((depthM or defaultCrossingDepthM) * 0.5 + crossingClearM) / total
  local lo, hi = half, 1 - half
  if lo >= hi then return 0.5 end
  return min(max(t01, lo), hi)
end

-- Perpendicular XY projection of p onto the centreline. Returns raw t01 (unclamped), or nil when the road has no ribbon.
local function projectDivT(group, p)
  local div = group and group.divPoints
  if not div or #div < 2 then return nil end
  local acc, bestSq, bestSeg, bestSegT, accBefore = 0, 1e30, nil, 0, 0
  for i = 1, #div - 1 do
    local a, b = div[i], div[i + 1]
    local ex, ey = b.x - a.x, b.y - a.y
    local lenSq = ex * ex + ey * ey
    local tt = 0
    if lenSq > 1e-10 then
      tt = ((p.x - a.x) * ex + (p.y - a.y) * ey) / lenSq
      if tt < 0 then tt = 0 elseif tt > 1 then tt = 1 end
    end
    local cx, cy = a.x + ex * tt, a.y + ey * tt
    local d = (p.x - cx) ^ 2 + (p.y - cy) ^ 2
    if d < bestSq then bestSq, bestSeg, bestSegT, accBefore = d, i, tt, acc end
    acc = acc + sqrt(lenSq)
  end
  if not bestSeg or acc <= 1e-6 then return nil end
  local a, b = div[bestSeg], div[bestSeg + 1]
  local segLen = sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
  return (accBefore + bestSegT * segLen) / acc
end

-- Normalized crossing position for a world point projected onto the road (clamped clear of the ends). Used while
-- dragging a crossing handle. nil if no ribbon.
local function tForPointOnGroup(group, p, depthM)
  local t01 = projectDivT(group, p)
  if not t01 then return nil end
  return clampCrossingT(group, t01, depthM)
end

-- World frame of a crossing at normalized t01: centre point + carriageway-edge endpoints (p0 = left, p1 = right of
-- travel). nil if the geometry isn't ready. Drives the placement ghost + drag handles + the zebra span.
local function crossingFrame(group, t01)
  local div, bnm = group and group.divPoints, group and group.binormals
  if not div or #div < 2 or not bnm then return nil end
  local n = #div
  local total = divLength(group)
  if total <= 1e-6 then return nil end
  local target = min(max(t01, 0), 1) * total
  local acc = 0
  local leftExt = group.leftExtM or ((group.divWidths and group.divWidths[1] or 5) * 0.5)
  local rightExt = group.rightExtM or leftExt
  for i = 1, n - 1 do
    local a, b = div[i], div[i + 1]
    local segLen = sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    if acc + segLen >= target or i == n - 1 then
      local tt = segLen > 1e-9 and min(max((target - acc) / segLen, 0), 1) or 0
      local px, py, pz = a.x + (b.x - a.x) * tt, a.y + (b.y - a.y) * tt, a.z + (b.z - a.z) * tt
      local b0, b1 = bnm[i], bnm[i + 1]
      local bx, by, bz = b0.x + (b1.x - b0.x) * tt, b0.y + (b1.y - b0.y) * tt, b0.z + (b1.z - b0.z) * tt
      local bl = sqrt(bx * bx + by * by + bz * bz)
      if bl > 1e-9 then bx, by, bz = bx / bl, by / bl, bz / bl end
      return vec3(px, py, pz),
        vec3(px - bx * leftExt, py - by * leftExt, pz - bz * leftExt),
        vec3(px + bx * rightExt, py + by * rightExt, pz + bz * rightExt)
    end
    acc = acc + segLen
  end
  return nil
end

-- Adds a pedestrian crossing at normalized position t01. Returns the new crossing.
local function addCrossing(group, t01)
  if not group then return nil end
  group.crossings = group.crossings or {}
  local cr = {
    id = Engine.generateUUID(),
    name = 'Crossing ' .. tostring(#group.crossings + 1),
    t = clampCrossingT(group, min(max(t01 or 0.5, 0), 1)),
    depthM = defaultCrossingDepthM,
    lateral = 'carriageway', -- 'carriageway' | 'kerb'
  }
  group.crossings[#group.crossings + 1] = cr
  group.isDirty = true
  return cr
end

-- Removes the crossing at index idx.
local function removeCrossing(group, idx)
  if group and group.crossings and group.crossings[idx] then
    table.remove(group.crossings, idx)
    group.isDirty = true
  end
end

-- Adds a repair-patch cluster at normalized position t01. Returns the new cluster. Shares the crossing frame/projection/
-- clamp (a cluster sits at a station like a crossing); lengthM is its along-road extent for the end-clearance clamp.
local function addRepair(group, t01)
  if not group then return nil end
  group.repairs = group.repairs or {}
  local rc = {
    id = Engine.generateUUID(),
    name = 'Repair ' .. tostring(#group.repairs + 1),
    t = clampCrossingT(group, min(max(t01 or 0.5, 0), 1), defaultRepairLengthM),
    lengthM = defaultRepairLengthM,
    coverage = 0.6,   -- lateral spread as a fraction of the carriageway width
    offset = 0.0,     -- lateral shift of the band centre (-1 left .. +1 right)
    density = 0.08,   -- patches per square metre of the footprint (kept low so a cluster is a handful of patches, not a swarm)
    sizeMin = 2.0,    -- ~3 m mean patch size (2..4)
    sizeMax = 4.0,
    rotJitter = 0.0,  -- 0 = aligned to road, 1 = fully random yaw; default aligned to the road
    material = 'asphalt_patches',
    seed = math.random(1, 1000000000),
  }
  group.repairs[#group.repairs + 1] = rc
  group.isDirty = true
  return rc
end

-- Removes the repair cluster at index idx.
local function removeRepair(group, idx)
  if group and group.repairs and group.repairs[idx] then
    table.remove(group.repairs, idx)
    group.isDirty = true
  end
end

-- Adds a procedural pothole at normalized position t01. Returns the new pothole. Shares the crossing frame/projection/clamp
-- (a pothole sits at a station like a crossing); its along-road extent for the end-clearance clamp is ~2*radius (the diameter).
local function addPothole(group, t01)
  if not group then return nil end
  group.potholes = group.potholes or {}
  local ph = {
    id = Engine.generateUUID(),
    name = 'Pothole ' .. tostring(#group.potholes + 1),
    t = clampCrossingT(group, min(max(t01 or 0.5, 0), 1), defaultPotholeRadiusM * 2),
    lateralM = 0.0,   -- lateral offset of the crater centre from the road centreline (m; + = right of travel)
    lengthM = defaultPotholeRadiusM * 2, -- crater extent ALONG the road (ellipse long axis is oriented to the road)
    widthM = defaultPotholeRadiusM * 2,  -- crater extent ACROSS the road
    depthM = 0.3,   -- max sink at the floor
    noise = 0.15,   -- single 'natural variation' knob: drives rim raggedness + surface roughness (0 = clean bowl, 0.25 max)
    cutMarkings = true, -- gap any painted lane/edge lines crossing this hole (paint leaves with the pavement) rather than draping into it
    seed = math.random(1, 1000000000),
  }
  group.potholes[#group.potholes + 1] = ph
  group.isDirty = true
  return ph
end

-- Removes the pothole at index idx.
local function removePothole(group, idx)
  if group and group.potholes and group.potholes[idx] then
    table.remove(group.potholes, idx)
    group.isDirty = true
  end
end

-- Adds a placeable widening at normalized position t01.
local function addWidening(group, t01)
  if not group then return nil end
  group.widenings = group.widenings or {}
  local p = wideningDefaults
  local w = {
    id = Engine.generateUUID(),
    name = 'Widening ' .. tostring(#group.widenings + 1),
    side = 'right',      -- 'left' | 'right' (the widening is added to this side; the spline stays the carriageway centre)
    widthM = p.widthM,   -- extra half-width added on that side (m)
    bayLenM = p.bayLenM, -- length of the constant full-width bay/lane (m)
    taperInM = p.taperInM,   -- entry (diverge) taper length (m)
    taperOutM = p.taperOutM, -- exit (merge) taper length (m)
    edgeBulge = true,    -- true: the solid edge line follows the widened edge over the bay (untick for a plain layby)
    laneDivider = true,  -- true: a dashed lane line along the ORIGINAL edge over the bay (untick for a plain layby)
    t = clampCrossingT(group, min(max(t01 or 0.5, 0), 1), p.taperInM + p.bayLenM + p.taperOutM),
  }
  group.widenings[#group.widenings + 1] = w
  group.isDirty = true
  return w
end

-- Removes the widening at index idx.
local function removeWidening(group, idx)
  if group and group.widenings and group.widenings[idx] then
    table.remove(group.widenings, idx)
    group.isDirty = true
  end
end

local function barrierDefaultsGet() return barrierDefaults end

-- The along-road extent of a barrier segment (its length), used to keep it clear of the road ends.
local function barrierExtent(b) return b.lengthM or barrierDefaults.lengthM end

-- Adds a placeable barrier segment at normalized position t01 (a guardrail run on one side over a length window).
local function addBarrier(group, t01)
  if not group then return nil end
  group.barriers = group.barriers or {}
  local p = barrierDefaults
  local b = {
    id = Engine.generateUUID(),
    name = 'Barrier ' .. tostring(#group.barriers + 1),
    side = p.side,        -- 'left' | 'right' (which edge the rail rides)
    lengthM = p.lengthM,  -- along-road extent of the run (m)
    offsetM = p.offsetM,  -- lateral gap from the mesh outer edge to the rail (m)
    zOffsetM = p.zOffsetM,-- extra vertical tweak (m) on top of the type's standard burial (0 = standard seat)
    type = p.type,        -- 'jersey' | 'plastic' | 'guardrail'
    t = clampCrossingT(group, min(max(t01 or 0.5, 0), 1), p.lengthM),
  }
  group.barriers[#group.barriers + 1] = b
  group.isDirty = true
  return b
end

-- Removes the barrier at index idx.
local function removeBarrier(group, idx)
  if group and group.barriers and group.barriers[idx] then
    table.remove(group.barriers, idx)
    group.isDirty = true
  end
end

-- Adds a junction bell-mouth at normalized position t01.
local function addJunction(group, t01)
  if not group then return nil end
  group.junctions = group.junctions or {}
  local p = junctionDefaults
  local j = {
    id = Engine.generateUUID(),
    name = 'Junction ' .. tostring(#group.junctions + 1),
    side = 'right',        -- 'left' | 'right' (the side road joins on this side; the spline stays the trunk centre)
    flareM = p.flareM,     -- lateral apron depth beyond the normal carriageway edge (m)
    lengthM = p.lengthM,   -- throat/opening length along the road (m)
    bevelM = p.bevelM,     -- rounded-corner taper length each side of the throat (m)
    giveWay = true,        -- draw a give-way bar ACROSS the incoming road at the mouth (transverse, on the stub)
    exitCenterline = true, -- draw the incoming road's centreline ALONG the stub (trunk centre -> end of the incoming road)
    breakEdge = true,      -- wrap the trunk edge line + edge-blend strips round the bevels and break them across the mouth
    t = clampCrossingT(group, min(max(t01 or 0.5, 0), 1), 2.0 * p.bevelM + p.lengthM),
  }
  group.junctions[#group.junctions + 1] = j
  group.isDirty = true
  return j
end

-- Removes the junction at index idx.
local function removeJunction(group, idx)
  if group and group.junctions and group.junctions[idx] then
    table.remove(group.junctions, idx)
    group.isDirty = true
  end
end

local function deepCopyGroup(group)
  local copy = buffer.decode(buffer.encode(group))
  table.clear(copy.divPoints)
  table.clear(copy.divWidths)
  table.clear(copy.tangents)
  table.clear(copy.binormals)
  table.clear(copy.normals)
  table.clear(copy.discMap)
  return copy
end

-- Deep copies the full group state.
local function deepCopyAllGroups()
  local copy = {}
  for i = 1, #groups do
    copy[i] = deepCopyGroup(groups[i])
  end
  return copy
end

-- Splits the given group at the selected node index.
local function splitGroup(group, groupIdx, selectedNodeIdx)
  if group.isLoop then
    -- Use the helper function for loop spline geometry splitting (carries the per-corner overrides through the reorder).
    local cornersNew
    group.nodes, group.widths, group.nmls, cornersNew = geom.splitLoopSplineGeometry(group.nodes, group.widths, group.nmls, selectedNodeIdx, group.corners)
    group.corners = cornersNew; ensureCornerArray(group) -- carry per-corner overrides (radius etc.); keep the array dense.
    group.isLoop = false
    group.isDirty = true
  else
    -- Carry the per-corner overrides (radius/widen/apron/super/taper) through the split so each half keeps its own settings.
    local nodes1, widths1, nmls1, nodes2, widths2, nmls2, corners1, corners2 =
      geom.splitSplineGeometry(group.nodes, group.widths, group.nmls, selectedNodeIdx, group.corners)

    -- Prepare copies.
    local group1 = deepCopyGroup(group)
    group1.name = group.name .. " (1)"
    group1.id = Engine.generateUUID()
    group1.nodes = nodes1
    group1.widths = widths1
    group1.nmls = nmls1
    group1.corners = corners1; ensureCornerArray(group1) -- keep this half's per-corner overrides; keep the array dense.
    group1.isDirty = true

    local group2 = deepCopyGroup(group)
    group2.name = group.name .. " (2)"
    group2.id = Engine.generateUUID()
    group2.nodes = nodes2
    group2.widths = widths2
    group2.nmls = nmls2
    group2.corners = corners2; ensureCornerArray(group2) -- keep this half's per-corner overrides; keep the array dense.
    group2.isDirty = true
    group1.terraBaseline, group2.terraBaseline = nil, nil -- the carve belonged to the whole road; the halves start from current terrain.

    -- Remove the old group and add the new ones.
    removeGroup(groupIdx)
    addGroupToGroupArray(group1)
    addGroupToGroupArray(group2)
  end

  -- Recompute the group id -> index map.
  util.computeIdToIdxMap(groups, groupMap)
end

-- Joins two unlooped road group splines into one, modifying group1 and deleting group2.
local function joinRoadSplines(groupIdx1, nodeIdx1, groupIdx2, nodeIdx2)
  local group1, group2 = groups[groupIdx1], groups[groupIdx2]
  if not group1 or not group2 then
    return
  end

  -- Join the two groups (carries both roads' per-corner overrides through the join, index-aligned to the joined node list).
  local nodesNew, widthsNew, nmlsNew, cornersNew =
    geom.joinSplineGeometry(group1.nodes, group1.widths, group1.nmls, nodeIdx1, group2.nodes, group2.widths, group2.nmls, nodeIdx2, group1.corners, group2.corners)
  if not nodesNew then
    return -- Early return if invalid node indices.
  end

  -- Apply joined geometry to group1.
  group1.nodes = nodesNew
  group1.widths = widthsNew
  group1.nmls = nmlsNew
  group1.corners = cornersNew; ensureCornerArray(group1) -- keep both roads' per-corner overrides; keep the array dense.
  group1.isLoop = false
  group1.isDirty = true
  group1.terraBaseline = nil -- neither road's carve matches the joined road; start from current terrain.

  -- Remove group2 directly to avoid index shift issues.
  removeGroup(groupIdx2)

  -- Recompute the ID-to-Index map for consistency.
  util.computeIdToIdxMap(groups, groupMap)
end

-- Converts the given paths (traced from a bitmap) to Road Splines.
local function convertPathsToRoadSplines(paths)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  for i = 1, #paths do
    local path = paths[i]

    -- Create a new Road Spline.
    addNewGroup()
    local group = groups[#groups]

    -- Convert the grid points to world space.
    local points = path.points
    local numPoints = #points
    local pointsWS = {}
    for j = 1, numPoints do
      local pointGrid = points[j]
      tmpPoint2I.x, tmpPoint2I.y = pointGrid.x, pointGrid.y
      pointsWS[j] = te:gridToWorldByPoint2I(tmpPoint2I, tb)
    end

    -- If the path is sufficiently large, then import it.
    local aabb = geom.getAABB(pointsWS)
    if min(abs(aabb.xMax - aabb.xMin), abs(aabb.yMax - aabb.yMin)) > minImportSize then
      group.nodes, group.widths = pointsWS, path.widths -- Set the nodes and widths directly.
      for j = 1, numPoints do
        group.nmls[j] = geom.getTerrainNormal(pointsWS[j]) -- Compute the normals for each node.
      end
      ensureCornerArray(group) -- new node set: no per-corner overrides, but keep the array dense for later edits.
    end
  end
  log('I', logTag, string.format("Converted %d traced paths to Hero Roads. %d paths were too small to import.", #paths, #paths - #groups))
end

-- Serialises a group.
local function serializeGroup(group)
  table.clear(group.divPoints)
  table.clear(group.divWidths)
  table.clear(group.tangents)
  table.clear(group.binormals)
  table.clear(group.normals)
  table.clear(group.discMap)
  table.clear(group.ribPoints)
  return buffer.encode(group)
end

-- Deserialises a group. `data` is either the editor's buffer-encoded blob (string) or a plain table straight from a JSON
-- session file -- so the same backfill + scene-reconcile path serves both the editor's own serialize and Load Session.
local function deserializeGroup(data, isCreateObject)
  local group = type(data) == 'table' and data or buffer.decode(data)
  group.isDirty = true

  -- Runtime scratch tables.
  group.nodes = group.nodes or {}
  group.widths = group.widths or {}
  group.nmls = group.nmls or {}
  group.ribPoints = group.ribPoints or {}
  group.divPoints = group.divPoints or {}
  group.divWidths = group.divWidths or {}
  group.tangents = group.tangents or {}
  group.binormals = group.binormals or {}
  group.normals = group.normals or {}
  group.discMap = group.discMap or {}
  group.layers = group.layers or {}
  -- Rehydrate every layer to a clean slate (fresh empty vec3 buffers, isDirty, empty decalRoadIds). Both load paths need this:
  -- a JSON session brings plain {x,y,z} buffers, and the buffer path loses the layer's runtime handles too. This also rescues
  -- older bloated session files (the stale per-layer buffers are discarded here rather than fed to buildLayerPolyline).
  for i = 1, #group.layers do group.layers[i] = layerMgr.deserializeLayer(group.layers[i]) end
  group.chunkStartIndices = group.chunkStartIndices or {}
  group.chunkEndIndices = group.chunkEndIndices or {}
  group.numChunks = group.numChunks or 0

  for i = 1, #group.nodes do
    local n = group.nodes[i]
    if type(n) == 'table' and not n.distance then group.nodes[i] = vec3(n.x, n.y, n.z) end
  end
  for i = 1, #group.nmls do
    local n = group.nmls[i]
    if type(n) == 'table' and not n.distance then group.nmls[i] = vec3(n.x, n.y, n.z) end
  end
  ensureCornerArray(group) -- per-corner overrides: create (empty for pre-feature roads) and pad dense to the node count.

  -- Backfill the lane profile for roads saved before it existed (guarantees the sliders read valid numbers).
  group.lanesLeft = group.lanesLeft or 1
  group.lanesRight = group.lanesRight or 1
  group.laneWidthM = group.laneWidthM or defaultLaneWidthM
  if group.isMesh == nil then group.isMesh = true end
  if group.crownOn == nil then group.crownOn = true end
  group.crossfallPct = group.crossfallPct or 2.5
  if group.flatEnds == nil then group.flatEnds = false end
  group.flatEndLenM = group.flatEndLenM or 6.0
  group.shoulderWidthM = group.shoulderWidthM or 0.5
  group.shoulderFallPct = group.shoulderFallPct or 6.0
  group.superElevMaxDeg = group.superElevMaxDeg or 6.0
  group.superMinRadiusM = group.superMinRadiusM or 80.0
  group.geometryMode = group.geometryMode or 'spline'
  group.engRadiusM = group.engRadiusM or 40.0
  group.engTransM = group.engTransM or 15.0
  group.engVertLenM = group.engVertLenM or 40.0
  group.curveWidenMaxM = group.curveWidenMaxM or 2.5
  group.curveWidenRunoffM = group.curveWidenRunoffM or 20.0
  group.roadClass = group.roadClass or 'rural' -- design-heatmap class (roads saved before the feature).
  group.latRes = group.latRes or 16
  group.lonRes = group.lonRes or 100
  group.chamferWidthM = group.chamferWidthM or 0.6
  group.chamferDropM = group.chamferDropM or 0.1
  group.chamferAngleDeg = group.chamferAngleDeg or 9.5
  if group.sideChamfers == nil then group.sideChamfers = true end
  if group.endChamfers == nil then group.endChamfers = true end
  group.lodSize0 = group.lodSize0 or 400
  group.lodSize1 = group.lodSize1 or 150
  group.lodSize2 = group.lodSize2 or 40
  group.lodQualityCm0 = group.lodQualityCm0 or 1.0
  group.lodQualityCm1 = group.lodQualityCm1 or 3.0
  group.lodQualityCm2 = group.lodQualityCm2 or 8.0
  group.lodMaxSegM0 = group.lodMaxSegM0 or 20
  group.lodMaxSegM1 = group.lodMaxSegM1 or 30
  group.lodMaxSegM2 = group.lodMaxSegM2 or 45
  if group.lodFarNull == nil then group.lodFarNull = true end
  group.collisionTolCm = group.collisionTolCm or 1.0
  group.chunkLenM = group.chunkLenM or 120
  if group.sidewalkLeft == nil then group.sidewalkLeft = false end
  if group.sidewalkRight == nil then group.sidewalkRight = false end
  group.sidewalkOffsetM = group.sidewalkOffsetM or 0.0
  group.crossings = group.crossings or {} -- placed pedestrian crossings (empty for roads saved before the feature).
  group.repairs = group.repairs or {} -- placed repair-patch clusters (empty for roads saved before the feature).
  group.potholes = group.potholes or {} -- procedural potholes (empty for roads saved before the feature).
  group.widenings = group.widenings or {} -- placeable widenings (empty for roads saved before the feature).
  group.surfaceStamps = group.surfaceStamps or {} -- groundmodel paint stamps (empty for roads saved before the feature).
  for i = 1, #group.widenings do -- backfill the marking flags; a road authored with the old 'overtaking' type gets both on.
    local w = group.widenings[i]
    if w.edgeBulge == nil then w.edgeBulge = w.type == 'overtaking' end
    if w.laneDivider == nil then w.laneDivider = w.type == 'overtaking' end
    w.type = nil -- the type/preset concept is gone (one widening kind; markings drive the look).
  end
  group.junctions = group.junctions or {} -- junction bell-mouths (empty for roads saved before the feature).
  for i = 1, #group.junctions do -- backfill the marking flags (give-way + exit centreline are independent, both on by default).
    local jn = group.junctions[i]
    if jn.giveWay == nil then jn.giveWay = true elseif type(jn.giveWay) == 'string' then jn.giveWay = jn.giveWay ~= 'none' end -- old 'none'/'giveWay'/'stop' -> boolean (stop option dropped).
    if jn.exitCenterline == nil then jn.exitCenterline = true end
    if jn.breakEdge == nil then jn.breakEdge = true end
  end
  group.barriers = group.barriers or {} -- placeable barrier segments (empty for roads saved before the feature).
  group.barrierLeftType = group.barrierLeftType or 'none'
  group.barrierRightType = group.barrierRightType or 'none'
  group.barrierOffsetM = group.barrierOffsetM or 0.5
  group.fenceLeftType = group.fenceLeftType or 'none'
  group.fenceRightType = group.fenceRightType or 'none'
  group.fenceOffsetM = group.fenceOffsetM or 0.7
  group.lampLeftType = group.lampLeftType or 'none'
  group.lampRightType = group.lampRightType or 'none'
  group.lampOffsetM = group.lampOffsetM or 1.0
  group.lampSpacingM = group.lampSpacingM or 25.0
  group.carriagewayMaterial = group.carriagewayMaterial or 'm_asphalt_new_01'
  group.shoulderMaterial = group.shoulderMaterial or 'm_asphalt_new_01'
  group.carriagewayTexLenM = group.carriagewayTexLenM or 4.0
  group.carriagewayTexWidth = group.carriagewayTexWidth or 4.0
  group.shoulderTexLenM = group.shoulderTexLenM or 4.0
  group.shoulderTexWidth = group.shoulderTexWidth or 4.0
  group.centerLineMaterial = group.centerLineMaterial or 'm_line_yellow_double'
  group.edgeLineMaterial = group.edgeLineMaterial or 'm_line_white'
  group.laneLineMaterial = group.laneLineMaterial or 'm_line_white_discontinue'
  group.centerLineTexLen = group.centerLineTexLen or 5.0
  group.edgeLineTexLen = group.edgeLineTexLen or 10.0
  group.laneLineTexLen = group.laneLineTexLen or 10.0
  -- Detail-overlay tile lengths for roads saved before these fields existed (defaults match layerMgr's fallbacks).
  group.lightTreadTexLen = group.lightTreadTexLen or 5.0
  group.heavyTreadTexLen = group.heavyTreadTexLen or 5.0
  group.repair1TexLen = group.repair1TexLen or 25.0
  group.repair2TexLen = group.repair2TexLen or 25.0
  group.damageAsphalt1TexLen = group.damageAsphalt1TexLen or 10.0
  group.damageAsphalt2TexLen = group.damageAsphalt2TexLen or 25.0
  group.patchesTexLen = group.patchesTexLen or 45.0
  group.roadCrackTexLen = group.roadCrackTexLen or 15.0

  -- Backfill edge-decal properties for roads saved before these fields existed, so the builders and the slider
  -- UI always see valid numbers (FloatPtr(nil) would crash the UI).
  group.edgeLineOffset = group.edgeLineOffset or 1.0
  group.edgeLineWidth = group.edgeLineWidth or 0.25
  group.edgeBlend1Offset = group.edgeBlend1Offset or 1.1
  group.edgeBlend1Width = group.edgeBlend1Width or 1.0
  group.edgeBlend2Offset = group.edgeBlend2Offset or 1.25
  group.edgeBlend2Width = group.edgeBlend2Width or 2.0
  group.edgeBlend3Offset = group.edgeBlend3Offset or 1.35
  group.edgeBlend3Width = group.edgeBlend3Width or 3.0

  -- Create a new scene tree folder for the road spline, if requested.
  if isCreateObject then
    local newFolder = createObject("SimGroup")
    newFolder:registerObject(string.format("%s - %s", group.name, group.id))
    newFolder.canSave = group.isEnabled == false -- transient while editing (no ghost on level save); persistent for a baked/Live road so its static + decals save.
    scenetree.MissionGroup:addObject(newFolder)
    group.sceneTreeFolderId = newFolder:getId()
  end

  return group
end

-- Keys dropped from a saved group (all rebuilt by updateDirtyGroups from the primary data, or recreated scene handles).
local sessionStripKeys = {
  'divPoints', 'divWidths', 'tangents', 'binormals', 'normals', 'discMap', 'ribPoints', 'divCurv',
  'meshGrid', 'meshVArc', 'meshStationCount', 'meshEdgeL', 'meshEdgeR',
  'meshEdgeDirL', 'meshEdgeDirR', 'meshEdgeUp', 'meshCutIdx', 'meshMaxEdgeM', 'lodMaxEdgeM',
  'triCount', 'triCountRaw', 'chunkStartIndices', 'chunkEndIndices', 'numChunks',
  'heatGrade', 'heatRadius', 'divBankR', -- derived heatmap arrays + per-divPoint banked axis; recomputed by heatmap.compute / mesh build.
  'sceneTreeFolderId', 'meshId', 'meshIds', 'roadLength',
  'crossingDecalIds', -- runtime zebra DecalRoad handles; recreated by the dirty pass from group.crossings.
  'junctionDecalIds', -- runtime give-way/stop-bar DecalRoad handles; recreated by the dirty pass from group.junctions.
  'wideningDecalIds', -- runtime lane-divider DecalRoad handles; recreated by the dirty pass from group.widenings.
  'previewMesh', -- transient per-session view/perf toggle (procedural mesh preview); resets to on (nil) each load.
  'terraBaseline', -- pre-carve terrain snapshot; only valid against the live terrain it was taken from, never across a reload.
}

-- One group as a clean, portable plain table (deep-copied through the buffer codec so the LIVE group is never mutated).
local function serializeGroupToTable(group)
  local t = buffer.decode(buffer.encode(group))
  for i = 1, #sessionStripKeys do t[sessionStripKeys[i]] = nil end
  if group.layers then
    -- Emit clean, authored-only layers (same as the profile copy path): drops the per-layer runtime geometry buffers
    -- (pClipped/wClipped/pFlip/wFlip) and DecalRoad handles. Keeping them bloats the file to megabytes AND reloads as stale
    -- plain {x,y,z} tables that crash buildLayerPolyline (vec3 methods on a plain table) on the load's dirty pass.
    t.layers = {}
    for i = 1, #group.layers do t.layers[i] = layerMgr.serializeLayer(group.layers[i]) end
  end
  return t
end

-- True only if every baked chunk file in the manifest is present on disk (used for the load-time editable fallback).
local function bakedArtifactsExist(manifest)
  if not manifest or #manifest == 0 then return false end
  for i = 1, #manifest do
    local p = manifest[i].path
    if not p or not (FS and FS:fileExists(p)) then return false end
  end
  return true
end

-- Session-load deserialize.
local function deserializeSessionGroup(gt)
  if gt.isEnabled == false and gt.bakedManifest and not bakedArtifactsExist(gt.bakedManifest) then
    gt.isEnabled = true; gt.bakedManifest = nil -- artifacts gone -> load editable, not as an empty static.
  end
  return deserializeGroup(gt, true)
end

-- Recompute the group id -> index map (called by the shared session helper after a load appends the loaded roads).
local function recomputeIdMap() util.computeIdToIdxMap(groups, groupMap) end

-- Undo/redo core for single group changes.
local function singleGroupUndoRedoCore(data)
  local idx = groupMap[data.id]
  if idx then
    local group = groups[idx]
    layerMgr.removeAllLayers(group) -- Remove all layers associated with the group.
    group.layers = layerMgr.deepCopyAllLayers(data.layers) -- Need to deep copy all layers from the undo/redo history.
    group.name = data.name
    group.id = data.id
    group.isLoop = data.isLoop
    group.isMesh = data.isMesh
    group.crownOn = data.crownOn
    group.crossfallPct = data.crossfallPct
    group.flatEnds = data.flatEnds
    group.flatEndLenM = data.flatEndLenM
    group.shoulderWidthM = data.shoulderWidthM
    group.shoulderFallPct = data.shoulderFallPct
    group.superElevMaxDeg = data.superElevMaxDeg
    group.superMinRadiusM = data.superMinRadiusM
    group.geometryMode = data.geometryMode
    group.engRadiusM = data.engRadiusM
    group.engTransM = data.engTransM
    group.engVertLenM = data.engVertLenM
    group.curveWidenMaxM = data.curveWidenMaxM
    group.curveWidenRunoffM = data.curveWidenRunoffM
    group.roadClass = data.roadClass -- design-heatmap class (authored per road; the metric/on-off is a global view mode, not restored).
    group.latRes = data.latRes
    group.lonRes = data.lonRes
    group.chamferWidthM = data.chamferWidthM
    group.chamferDropM = data.chamferDropM
    group.chamferAngleDeg = data.chamferAngleDeg
    group.sideChamfers = data.sideChamfers
    group.endChamfers = data.endChamfers
    group.lodSize0 = data.lodSize0
    group.lodSize1 = data.lodSize1
    group.lodSize2 = data.lodSize2
    group.lodQualityCm0 = data.lodQualityCm0
    group.lodQualityCm1 = data.lodQualityCm1
    group.lodQualityCm2 = data.lodQualityCm2
    group.lodMaxSegM0 = data.lodMaxSegM0
    group.lodMaxSegM1 = data.lodMaxSegM1
    group.lodMaxSegM2 = data.lodMaxSegM2
    group.lodFarNull = data.lodFarNull
    group.collisionTolCm = data.collisionTolCm
    group.chunkLenM = data.chunkLenM
    group.sidewalkLeft = data.sidewalkLeft
    group.sidewalkRight = data.sidewalkRight
    group.sidewalkOffsetM = data.sidewalkOffsetM
    group.crossings = data.crossings -- placed pedestrian crossings (plain data; the buffer snapshot carries them).
    group.repairs = data.repairs -- placed repair-patch clusters (plain data; the buffer snapshot carries them).
    group.potholes = data.potholes -- procedural potholes carved into the deck (plain data; the buffer snapshot carries them).
    group.widenings = data.widenings -- placeable widenings reshaped into the deck (plain data; the buffer snapshot carries them).
    group.junctions = data.junctions -- junction bell-mouths flared into the deck (plain data; the buffer snapshot carries them).
    group.surfaceStamps = data.surfaceStamps -- groundmodel paint stamps (plain data; the buffer snapshot carries them).
    group.barriers = data.barriers -- placeable barrier segments (plain data; the buffer snapshot carries them).
    group.barrierLeftType = data.barrierLeftType
    group.barrierRightType = data.barrierRightType
    group.barrierOffsetM = data.barrierOffsetM
    group.fenceLeftType = data.fenceLeftType
    group.fenceRightType = data.fenceRightType
    group.fenceOffsetM = data.fenceOffsetM
    group.lampLeftType = data.lampLeftType
    group.lampRightType = data.lampRightType
    group.lampOffsetM = data.lampOffsetM
    group.lampSpacingM = data.lampSpacingM
    group.carriagewayMaterial = data.carriagewayMaterial
    group.shoulderMaterial = data.shoulderMaterial
    group.carriagewayTexLenM = data.carriagewayTexLenM
    group.carriagewayTexWidth = data.carriagewayTexWidth
    group.shoulderTexLenM = data.shoulderTexLenM
    group.shoulderTexWidth = data.shoulderTexWidth
    group.centerLineMaterial = data.centerLineMaterial
    group.edgeLineMaterial = data.edgeLineMaterial
    group.laneLineMaterial = data.laneLineMaterial
    group.centerLineTexLen = data.centerLineTexLen
    group.edgeLineTexLen = data.edgeLineTexLen
    group.laneLineTexLen = data.laneLineTexLen
    group.lightTreadTexLen = data.lightTreadTexLen
    group.heavyTreadTexLen = data.heavyTreadTexLen
    group.repair1TexLen = data.repair1TexLen
    group.repair2TexLen = data.repair2TexLen
    group.damageAsphalt1TexLen = data.damageAsphalt1TexLen
    group.damageAsphalt2TexLen = data.damageAsphalt2TexLen
    group.patchesTexLen = data.patchesTexLen
    group.roadCrackTexLen = data.roadCrackTexLen
    group.isDirty = true -- Set the dirty flag to true.
    group.isEnabled = data.isEnabled
    group.bakedManifest = data.bakedManifest -- Restore the bake (so undo/redo of a Bake / enable-disable reconciles the static below).
    group.terrainFinalized = data.terrainFinalized -- terrain-road equivalent of the manifest (undo/redo of a terrain finalise).

    -- Reconcile the burned sidewalk/furniture.
    local burnChanged = false
    if group.swBurnedManifest and group.swBurnedManifest ~= data.swBurnedManifest then
      kitPlacer.removeBurned(group.swBurnedManifest); burnChanged = true
    end
    if group.propBurnedManifest and group.propBurnedManifest ~= data.propBurnedManifest then
      kitPlacer.removeBurned(group.propBurnedManifest); burnChanged = true
    end
    group.swBurnedManifest = data.swBurnedManifest
    group.propBurnedManifest = data.propBurnedManifest
    if burnChanged then kitPlacer.markDirty() end

    group.nodes = data.nodes
    group.widths = data.widths
    group.nmls = data.nmls
    group.corners = data.corners -- per-corner overrides (buffer snapshot carries them; may be nil for pre-feature history).
    ensureCornerArray(group) -- keep the override array dense and node-aligned after the restore.
    group.roadLength = data.roadLength
    group.lanesLeft = data.lanesLeft
    group.lanesRight = data.lanesRight
    group.laneWidthM = data.laneWidthM
    group.leftExtM = data.leftExtM
    group.rightExtM = data.rightExtM
    group.isOverObjects = data.isOverObjects
    group.isLightTreadMarks = data.isLightTreadMarks
    group.isHeavyTreadMarks = data.isHeavyTreadMarks
    group.isDamageAsphalt1 = data.isDamageAsphalt1
    group.isDamageAsphalt2 = data.isDamageAsphalt2
    group.isRoadCrack = data.isRoadCrack
    group.isRepair1 = data.isRepair1
    group.isRepair2 = data.isRepair2
    group.isPatches = data.isPatches
    group.isRoadCenterLine = data.isRoadCenterLine
    group.isRoadEdgeLines = data.isRoadEdgeLines
    group.isRoadLaneLines = data.isRoadLaneLines
    group.isEdgeBlend1 = data.isEdgeBlend1
    group.isEdgeBlend2 = data.isEdgeBlend2
    group.isEdgeBlend3 = data.isEdgeBlend3
    group.edgeLineOffset = data.edgeLineOffset
    group.edgeLineWidth = data.edgeLineWidth
    group.edgeBlend1Offset = data.edgeBlend1Offset
    group.edgeBlend1Width = data.edgeBlend1Width
    group.edgeBlend2Offset = data.edgeBlend2Offset
    group.edgeBlend2Width = data.edgeBlend2Width
    group.edgeBlend3Offset = data.edgeBlend3Offset
    group.edgeBlend3Width = data.edgeBlend3Width

    -- Reconcile the mesh to the restored enabled/baked state: enabled -> live procedural (rebuilt by the dirty flag above);
    -- disabled -> baked static if the restored group has a bake, else nothing. Keeps undo/redo of Bake + toggle coherent.
    exportMgr.applyState(group)

    -- Special case for when the group has been renamed.
    if data.isUpdateSceneTree then
      if group.sceneTreeFolderId then
        local folder = scenetree.findObjectById(group.sceneTreeFolderId)
        if folder then
          folder:setName(group.name)
        end
      end
      editor.refreshSceneTreeWindow()
    end
  end
end

-- Handles the undo/redo for single group edits.
local function singleGroupEditUndo(data) singleGroupUndoRedoCore(data.old) end

local function singleGroupEditRedo(data) singleGroupUndoRedoCore(data.new) end

-- Undo/redo core for trans-group edits.
local function transGroupUndoRedoCore(data)
  removeAllGroups(true) -- Remove all groups.
  for i = 1, #data do
    addGroupToGroupArray(deepCopyGroup(data[i])) -- Add the given groups.
  end
  util.computeIdToIdxMap(groups, groupMap) -- Recompute the group id -> index map.

  -- Set the isDirty flag for all restored groups to ensure proper updates.
  for i = 1, #groups do
    groups[i].isDirty = true
  end
end

-- Handles the undo/redo for trans-group edits.
local function transGroupEditUndo(groupsData) transGroupUndoRedoCore(groupsData.old) end

local function transGroupEditRedo(groupsData) transGroupUndoRedoCore(groupsData.new) end

-- Returns the current list of Road Splines.
local function getCurrentRoadSplineList()
  local list, ctr = {}, 1
  for i = 1, #groups do
    local group = groups[i]
    if group.isEnabled then
      list[ctr] = { name = group.name, id = group.id, type = toolPrefixStr }
      ctr = ctr + 1
    end
  end
  return list
end


-- Public interface.
M.defaultCrossingDepthM =                              defaultCrossingDepthM
M.defaultRepairLengthM =                               defaultRepairLengthM
M.defaultPotholeRadiusM =                              defaultPotholeRadiusM

M.getGroups =                                          getGroups
M.getIdToIdxMap =                                      getIdToIdxMap
M.getToolPrefixStr =                                   getToolPrefixStr
M.getEditModeKey =                                     getEditModeKey
M.addGroupToGroupArray =                               addGroupToGroupArray

M.removeGroup =                                        removeGroup
M.removeLinkedRoadSpline =                             removeLinkedRoadSpline
M.removeAllGroups =                                    removeAllGroups

M.updateDirtyGroups =                                  updateDirtyGroups
M.rebuildSurfaceOnly =                                 rebuildSurfaceOnly
M.clearGroupVisuals =                                  clearGroupVisuals
M.setFixedWidth =                                      setFixedWidth
M.setLaneProfile =                                     setLaneProfile
M.syncProfileWidth =                                   syncProfileWidth
M.applyProfilePreset =                                 applyProfilePreset
M.conformGroupToTerrain =                              conformGroupToTerrain
M.isOneWayProfile =                                    isOneWayProfile
M.recreateAutoGeneratedLayers =                        recreateAutoGeneratedLayers

M.addNewGroup =                                        addNewGroup
M.ensureCornerArray =                                  ensureCornerArray

M.copyGroupProfile =                                   copyGroupProfile
M.pasteGroupProfile =                                  pasteGroupProfile
M.deepCopyGroup =                                      deepCopyGroup
M.deepCopyAllGroups =                                  deepCopyAllGroups

M.splitGroup =                                         splitGroup
M.joinRoadSplines =                                    joinRoadSplines

M.convertPathsToRoadGroups =                           convertPathsToRoadSplines

M.serializeGroup =                                     serializeGroup
M.deserializeGroup =                                   deserializeGroup
M.serializeGroupToTable =                              serializeGroupToTable
M.deserializeSessionGroup =                            deserializeSessionGroup
M.recomputeIdMap =                                     recomputeIdMap

M.singleGroupEditUndo =                                singleGroupEditUndo
M.singleGroupEditRedo =                                singleGroupEditRedo
M.transGroupEditUndo =                                 transGroupEditUndo
M.transGroupEditRedo =                                 transGroupEditRedo

M.crossingFrame =                                      crossingFrame
M.tForPointOnGroup =                                   tForPointOnGroup
M.clampCrossingT =                                     clampCrossingT
M.addCrossing =                                        addCrossing
M.removeCrossing =                                     removeCrossing
M.addRepair =                                          addRepair
M.removeRepair =                                       removeRepair
M.addPothole =                                         addPothole
M.removePothole =                                      removePothole
M.addWidening =                                        addWidening
M.removeWidening =                                     removeWidening
M.wideningDefaults =                                   wideningDefaultsGet
M.wideningExtent =                                     wideningExtent
M.addJunction =                                        addJunction
M.removeJunction =                                     removeJunction
M.junctionDefaults =                                   junctionDefaultsGet
M.junctionExtent =                                     junctionExtent
M.addBarrier =                                         addBarrier
M.removeBarrier =                                      removeBarrier
M.barrierDefaults =                                    barrierDefaultsGet
M.barrierExtent =                                      barrierExtent

M.getCurrentRoadSplineList =                           getCurrentRoadSplineList

return M