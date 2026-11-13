-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local simplifyRdpTol = 9.0 -- The tolerance for the RDP simplification of the spline.

local defaultSplineWidth = 10.0 -- The default width for a spline when adding a new node, in meters.

local latMin, latMax = -5.0, 5.0 -- The minimum and maximum values for the lateral position slider.
local edgeOffsetMinM, edgeOffsetMaxM = -5.0, 5.0 -- Edge layer offset (m) from the road edge: negative = onto the road, positive = outward.
local fadeMin, fadeMax = 0.0, 100.0 -- The minimum and maximum values for the fade slider.

local elevScale = 100.0 -- The scale factor for the elevation drop lines (used for blue->red colour transition).

local terraParams = { doi = 20.0, margin = 1.0, falloff = 3.0, roughness = 0.0, scale = 0.0, smooth = 2.0 } -- Terraform knobs.
local terraClipEnds = false -- Cut the terraform at the road's start/end planes (no falloff in front of either end).
local paintMarginDefault = 2.0 -- Seed for a road's paint margin (the material/margin themselves are per-road: group.paintMargin / paintMaterialIdx).

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- External modules.
local groupMgr = require('editor/heroRoadEditor/groupMgr')
local placeablesUI = require('editor/heroRoadEditor/placeablesUI')
local layerMgr = require('editor/heroRoadEditor/layerMgr')
local import = require('editor/heroRoadEditor/import')
local profile = require('editor/heroRoadEditor/profile')
local meshMgr = require('editor/heroRoadEditor/mesh')
local exportMgr = require('editor/heroRoadEditor/exportMgr')
local sidewalkMgr = require('editor/heroRoadEditor/sidewalkMgr')
local barrierMgr = require('editor/heroRoadEditor/barrierMgr')
local roadPlaceables = require('editor/toolUtilities/roadPlaceables')
local input = require('editor/toolUtilities/splineInput')
local materialSelectionMgr = require('editor/toolUtilities/materialSelectionMgr')
local rSpline = require('editor/toolUtilities/render/spline')
local rTransport = require('editor/toolUtilities/render/transport')
local poly = require('editor/toolUtilities/polygon')
local panCamera = require('editor/toolUtilities/panCamera')
local skeleton = require('editor/toolUtilities/skeleton')
local rdp = require('editor/toolUtilities/rdp')
local maskExport = require('editor/toolUtilities/splineMaskExport')
local util = require('editor/toolUtilities/util')
local matCombo = require('editor/toolUtilities/matCombo')
local geom = require('editor/toolUtilities/geom')
local engineeredGeom = require('editor/toolUtilities/engineeredGeom')
local cornerHandles = require('editor/toolUtilities/cornerHandles')
local style = require('editor/toolUtilities/style')
local terra = require('editor/terraform/terraform')
local terrainPaint = require('editor/toolUtilities/terrainPainter')
local session = require('editor/toolUtilities/session')
local siteLights = require('editor/toolUtilities/siteLights')
local heatmap = require('editor/heroRoadEditor/heatmap')
local groundmodel = require('editor/heroRoadEditor/groundmodel')
local surfaceKit = require('editor/toolUtilities/surfaceKit')

-- Module constants.
local im = ui_imgui
local min, max, floor, sqrt, abs = math.min, math.max, math.floor, math.sqrt, math.abs
local toolWindowName, toolWindowSize = "heroRoadEditor", im.ImVec2(200, 400)
local sliderDefaults = layerMgr.getSliderDefaults()
local iconsSmall, iconsBig = im.ImVec2(24, 24), im.ImVec2(36, 36)
local cols = style.getImguiCols('crystal')
local escapeKeyIdx = im.GetKeyIndex(im.Key_Escape)
local ctrlKeyIdx = im.GetKeyIndex(im.Key_ModCtrl)
local heatMetric = 'off'
local crossingHost = { -- Placeable hosts for the shared roadPlaceables controller.
  kind = 'crossing',
  label = 'Crossing',
  getGroups = groupMgr.getGroups,
  isRoad = function(_) return true end,
  itemsOf = function(g) return g.crossings end,
  extentOf = function(cr) return cr.depthM end,
  frameAt = groupMgr.crossingFrame,
  tForPoint = groupMgr.tForPointOnGroup,
  clampT = groupMgr.clampCrossingT,
  addItem = groupMgr.addCrossing,
  removeItem = groupMgr.removeCrossing,
  deepCopy = groupMgr.deepCopyGroup,
  undo = groupMgr.singleGroupEditUndo,
  redo = groupMgr.singleGroupEditRedo,
  defaultDepthM = groupMgr.defaultCrossingDepthM,
}
local repairHost = {
  kind = 'repair',
  label = 'Repair Cluster',
  getGroups = groupMgr.getGroups,
  isRoad = function(_) return true end,
  itemsOf = function(g) return g.repairs end,
  extentOf = function(r) return r.lengthM end,
  frameAt = groupMgr.crossingFrame,
  tForPoint = groupMgr.tForPointOnGroup,
  clampT = groupMgr.clampCrossingT,
  addItem = groupMgr.addRepair,
  removeItem = groupMgr.removeRepair,
  deepCopy = groupMgr.deepCopyGroup,
  undo = groupMgr.singleGroupEditUndo,
  redo = groupMgr.singleGroupEditRedo,
  defaultDepthM = groupMgr.defaultRepairLengthM,
}
local potholeHost = {
  kind = 'pothole',
  label = 'Pothole',
  getGroups = groupMgr.getGroups,
  isRoad = function(_) return true end,
  itemsOf = function(g) return g.potholes end,
  extentOf = function(ph) return ph.lengthM or (ph.radiusM or groupMgr.defaultPotholeRadiusM) * 2 end, -- along-road extent = end clearance.
  frameAt = groupMgr.crossingFrame,
  tForPoint = groupMgr.tForPointOnGroup,
  clampT = groupMgr.clampCrossingT,
  addItem = groupMgr.addPothole,
  removeItem = groupMgr.removePothole,
  deepCopy = groupMgr.deepCopyGroup,
  undo = groupMgr.singleGroupEditUndo,
  redo = groupMgr.singleGroupEditRedo,
  defaultDepthM = groupMgr.defaultPotholeRadiusM * 2,
}
local wideningHost = {
  kind = 'widening',
  label = 'Widening',
  getGroups = groupMgr.getGroups,
  isRoad = function(_) return true end,
  itemsOf = function(g) return g.widenings end,
  extentOf = function(w) return groupMgr.wideningExtent(w) end, -- entry taper + bay + exit taper = along-road end clearance.
  frameAt = groupMgr.crossingFrame,
  tForPoint = groupMgr.tForPointOnGroup,
  clampT = groupMgr.clampCrossingT,
  addItem = groupMgr.addWidening, -- one widening kind, seeded from the defaults + named 'Widening N' by addWidening.
  removeItem = groupMgr.removeWidening,
  deepCopy = groupMgr.deepCopyGroup,
  undo = groupMgr.singleGroupEditUndo,
  redo = groupMgr.singleGroupEditRedo,
  defaultDepthM = groupMgr.wideningExtent(groupMgr.wideningDefaults()),
}
local junctionHost = {
  kind = 'junction',
  label = 'Junction',
  getGroups = groupMgr.getGroups,
  isRoad = function(_) return true end,
  itemsOf = function(g) return g.junctions end,
  extentOf = function(j) return groupMgr.junctionExtent(j) end, -- bevel + throat + bevel = along-road end clearance.
  frameAt = groupMgr.crossingFrame,
  tForPoint = groupMgr.tForPointOnGroup,
  clampT = groupMgr.clampCrossingT,
  addItem = groupMgr.addJunction, -- one junction kind, seeded from the defaults + named 'Junction N' by addJunction.
  removeItem = groupMgr.removeJunction,
  deepCopy = groupMgr.deepCopyGroup,
  undo = groupMgr.singleGroupEditUndo,
  redo = groupMgr.singleGroupEditRedo,
  defaultDepthM = groupMgr.junctionExtent(groupMgr.junctionDefaults()),
}
local barrierHost = {
  kind = 'barrier',
  label = 'Barrier',
  getGroups = groupMgr.getGroups,
  isRoad = function(_) return true end,
  itemsOf = function(g) return g.barriers end,
  extentOf = function(b) return groupMgr.barrierExtent(b) end, -- run length = along-road end clearance.
  frameAt = groupMgr.crossingFrame,
  tForPoint = groupMgr.tForPointOnGroup,
  clampT = groupMgr.clampCrossingT,
  addItem = groupMgr.addBarrier, -- one barrier kind (jersey/plastic/guardrail set per item), named 'Barrier N' by addBarrier.
  removeItem = groupMgr.removeBarrier,
  deepCopy = groupMgr.deepCopyGroup,
  undo = groupMgr.singleGroupEditUndo,
  redo = groupMgr.singleGroupEditRedo,
  defaultDepthM = groupMgr.barrierExtent(groupMgr.barrierDefaults()),
}

-- Module state.
local isRoadSplineActive = false
local isDrawPolygon = false
local dragHideGroup = nil -- group whose visuals were torn down for the current node/gizmo drag (nil = not drag-hiding).
local liveSliderDragging = false -- set by a 'live' slider (e.g. Transition) while held; drives the same drag-hide path as a node drag so the ribbon re-samples every frame (heavy mesh deferred to release). Read + reset at the top of onEditorGui (1-frame pipeline: the UI is drawn later).
local selectedGroupIdx, selectedNodeIdx, selectedLayerId = 1, 1, nil
local hiddenGripNodes = {}
local matSelectTarget = 'layer' -- What the material selector applies to: 'layer', 'carriageway', or 'shoulder'.
local matThumbCache = {} -- matName -> texObj|false, so each swatch texture loads ONCE (bypasses the shared 5/frame throttle).
local isGizmoActive = false
local isLockShape = false
local previousSelectedGroupIdx = -1
local sliderPreEditState = nil
local statList = {}
local out = {
  spline = selectedGroupIdx,
  node = selectedNodeIdx,
  layer = selectedLayerId,
  isGizmoActive = isGizmoActive,
}
local sessionSpec = { -- Save/Load Session spec.
  toolId = 'heroRoadEditor',
  displayName = 'Hero Road',
  itemNoun = 'roads',
  altItemsKey = 'groups',
  getItems = groupMgr.getGroups,
  serializeItem = groupMgr.serializeGroupToTable,
  deserializeItem = groupMgr.deserializeSessionGroup,
  clearAll = function() groupMgr.removeAllGroups(true) end,
  deepCopyAll = groupMgr.deepCopyAllGroups,
  transUndo = groupMgr.transGroupEditUndo,
  transRedo = groupMgr.transGroupEditRedo,
  refreshIdMap = groupMgr.recomputeIdMap,
  onLoaded = function() selectedGroupIdx = 1 end,
  getGlobals = function() -- tool-global terraform knobs travel with the session (paint material/margin are per-road now).
    return { doi = terraParams.doi, margin = terraParams.margin, falloff = terraParams.falloff, roughness = terraParams.roughness,
             scale = terraParams.scale, smooth = terraParams.smooth }
  end,
  applyGlobals = function(t)
    for k in pairs(terraParams) do if type(t[k]) == 'number' then terraParams[k] = t[k] end end
  end,
  iconColor = cols.blueB,
  iconSize = iconsBig,
}

-- Register this tool with the shared spline input utilities.
input.registerSplineTool(
  groupMgr.getToolPrefixStr(),
  groupMgr.getGroups,
  groupMgr.getEditModeKey,
  groupMgr.deepCopyGroup,
  groupMgr.deepCopyAllGroups,
  'editor_heroRoadEditor'
)


-- Sets the selected spline index (for cross-tool selection).
local function setSelectedSplineIdx(idx) selectedGroupIdx = idx end

-- Sets the selected node index (for cross-tool selection).
local function setSelectedNodeIdx(idx) selectedNodeIdx = idx end

-- Finds a layer by id in a group.
local function findLayerById(group, layerId)
  if not group or not group.layers or not layerId then
    return nil
  end
  local layers = group.layers
  for i = 1, #layers do
    if layers[i].id == layerId then
      return layers[i], i
    end
  end
  return nil
end

-- Gets the selected layer and its index.
local function getSelectedLayer(group)
  if not group or not selectedLayerId then
    return nil, nil
  end
  return findLayerById(group, selectedLayerId)
end

-- Serialise callback.
local function onSerialize()
  local groups = groupMgr.getGroups()
  local serializedGroups = {}
  for i = 1, #groups do
    local group = groups[i]
    serializedGroups[i] = groupMgr.serializeGroup(group)
  end
  groupMgr.removeAllGroups(true)
  return { groups = serializedGroups }
end

-- Deserialisation callback.
local function onDeserialized(data)
  local groupsData = data.groups or data -- back-compat: older sessions serialized a bare groups array.
  local groups = groupMgr.getGroups()
  table.clear(groups)
  for i = 1, #groupsData do
    local group = groupMgr.deserializeGroup(groupsData[i], true)
    groups[#groups + 1] = group
  end
  util.computeIdToIdxMap(groups, groupMgr.getIdToIdxMap()) -- Recompute the group id -> index map.
end

-- Cheap per-frame update for prop-only sliders (lamp/barrier/fence offset + lamp spacing): these DON'T touch the road mesh,
-- so we only re-place the roadside furniture along the existing (unchanged) mesh edges. reload syncs the static prop collision
-- once on release (the props are collidable), so the drag itself stays smooth.
local function updateFurnitureLive(group, reload)
  barrierMgr.updateGroup(group)
  if reload and be and be.reloadCollision then be:reloadCollision() end
end

-- Renders one row of a group-level slider with a left-hand reset button.
-- furnitureLive: this param only moves roadside props (no road-mesh rebuild), so it updates the furniture every frame while
-- dragging and never dirties the group (see updateFurnitureLive).
local function resetSlider(group, key, default, minV, maxV, fmt, tooltip, label, isInt, onChange, noDirty, live, furnitureLive)
  if group[key] ~= default then
    if editor.uiIconImageButton(editor.icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'reset_' .. key) then
      local pre = groupMgr.deepCopyGroup(group)
      group[key] = default
      if onChange then onChange(group) end
      if furnitureLive then updateFurnitureLive(group, true)
      elseif not noDirty then group.isDirty = true end
      editor.history:commitAction(label, { old = pre, new = groupMgr.deepCopyGroup(group) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
    end
    im.tooltip("Reset to default")
  else
    im.Dummy(iconsSmall)
  end
  im.SameLine()
  im.NextColumn()
  im.PushItemWidth(-1)
  local changed
  if isInt then
    local ptr = im.IntPtr(group[key])
    changed = im.SliderInt("###" .. key, ptr, minV, maxV, fmt)
    if changed then group[key] = ptr[0] end
  else
    local ptr = im.FloatPtr(group[key])
    changed = im.SliderFloat("###" .. key, ptr, minV, maxV, fmt)
    if changed then group[key] = ptr[0] end
  end
  -- Live value only while dragging (the 2D preview reads group[key] directly, so it still animates); the actual rebuild
  -- is deferred to release below, so we don't dirty the group + reload collision every frame the slider is held.
  if changed and onChange then onChange(group) end
  -- 'live' params reshape the ribbon (e.g. Transition -> centerline): dirty every frame + flag the drag so the drag-hide path
  -- re-samples the ribbon each frame while the heavy mesh still waits for release (identical to dragging a node).
  if live then
    if changed then group.isDirty = true end
    if im.IsItemActive() then liveSliderDragging = true end
  end
  -- furnitureLive params (offsets / spacing) only move props: re-place them each frame, no mesh rebuild, no per-frame collision reload.
  if furnitureLive and changed then updateFurnitureLive(group, false) end
  if tooltip then im.tooltip(tooltip) end
  if im.IsItemActivated() then sliderPreEditState = groupMgr.deepCopyGroup(group) end
  if im.IsItemDeactivatedAfterEdit() then
    if furnitureLive then updateFurnitureLive(group, true)
    elseif not noDirty then group.isDirty = true end
    editor.history:commitAction(label, { old = sliderPreEditState, new = groupMgr.deepCopyGroup(group) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
  im.PopItemWidth()
  im.NextColumn()
end

-- One Mesh-tab slider on its own row (reset button | slider). Wraps resetSlider in the 2-column layout it needs, so sections can
-- be interleaved with plain text/separators without column bookkeeping. By default it's a bake-only param (noDirty -- doesn't
-- touch the live mesh); pass dirty=true for params that change the LIVE geometry (e.g. tessellation) so they rebuild on release.
local function exportSliderRow(group, key, default, minV, maxV, fmt, tooltip, label, isInt, dirty, live)
  im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
  im.Columns(2, 'c_' .. key, false)
  im.SetColumnWidth(0, 30)
  resetSlider(group, key, default, minV, maxV, fmt, tooltip, label, isInt, nil, not dirty, live)
  im.Columns(1)
  im.PopStyleVar()
end

local function setGeometryMode(group, mode)
  local pre = groupMgr.deepCopyGroup(group)
  group.geometryMode = mode; group.isDirty = true
  editor.history:commitAction(mode == 'engineered' and "Set Engineered Geometry" or "Set Smooth Geometry",
    { old = pre, new = groupMgr.deepCopyGroup(group) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
end

local function engGeomSlider(group, meta) -- one road-wide alignment row; live=true so it updates the ribbon every frame while dragging.
  exportSliderRow(group, meta.key, meta.default, meta.min, meta.max, meta.fmt, meta.tooltip, meta.label, false, true, true)
end

-- "Geometry:" section: engineered clothoid corners that ROUND interior nodes vs a smooth spline THROUGH them, then the road-wide
-- alignment sliders (corner radius is per-corner: the viewport knob). Labels/tooltips come from engineeredGeom.CONTROLS so every road
-- tool reads identical text. Hill Smoothing + Width Taper both apply here (free Z, mesh widens).
local function geometrySection(group)
  local C = engineeredGeom.CONTROLS
  local isEng = group.geometryMode == 'engineered'
  im.TextColored(cols.greenB, "Geometry:")

  -- (Mesh vs Terrain road is toggled per road from the road-list row, beside Remove. Deck-only controls below grey out for a terrain road.)
  im.Text("Mode"); im.SameLine()
  if im.RadioButton1("Engineered###heroEng", isEng) and not isEng then setGeometryMode(group, 'engineered') end
  im.tooltip(C.modeEngTip)
  im.SameLine()
  if im.RadioButton1("Smooth###heroSmooth", not isEng) and isEng then setGeometryMode(group, 'spline') end
  im.tooltip(C.modeSmoothTip)
  if isEng then
    engGeomSlider(group, C.transition)
    engGeomSlider(group, C.vertical)
    engGeomSlider(group, C.widenAmount)
    engGeomSlider(group, C.widthTaper)
  end
end

-- One furniture-type icon button (barriers / fences / lamp posts). Highlights when group[key] == presetKey; clicking selects it, or
-- clicking the already-selected one clears back to 'none' (so one row both picks the type AND toggles the side off).
local function propTypeButton(group, key, presetKey, icon, tip, label)
  local selected = group[key] == presetKey
  if editor.uiIconImageButton(icon, iconsSmall, selected and cols.blueB or nil, nil, nil, 'ptb_' .. key .. '_' .. presetKey) then
    local pre = groupMgr.deepCopyGroup(group)
    group[key] = selected and 'none' or presetKey
    group.isDirty = true
    editor.history:commitAction(label, { old = pre, new = groupMgr.deepCopyGroup(group) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
  im.tooltip(tip)
end

-- One row of a terraform slider for a terraParams field, with a left-hand reset button. MUST be called inside a
-- 2-column block (like resetSlider) so consecutive rows pack tightly.
local function terraSlider(key, default, minV, maxV, fmt, tooltip)
  if terraParams[key] ~= default then
    if editor.uiIconImageButton(editor.icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'treset_' .. key) then terraParams[key] = default end
    im.tooltip("Reset to default")
  else
    im.Dummy(iconsSmall)
  end
  im.SameLine()
  im.NextColumn()
  im.PushItemWidth(-1)
  local ptr = im.FloatPtr(terraParams[key])
  if im.SliderFloat("###ts_" .. key, ptr, minV, maxV, fmt) then terraParams[key] = ptr[0] end
  if tooltip then im.tooltip(tooltip) end
  im.PopItemWidth()
  im.NextColumn()
end

-- Builds the terraform SOURCE for a group straight from the final deck grid, in the exact format masterSpline's
-- terraform uses ({ sData } where each entry is { pos, width, binormal }).
local function terraSources(group)
  local W = group.meshGrid
  local m = W and #W or 0
  if m >= 2 and W[1] and #W[1] >= 2 then
    local cols = #W[1]
    local sData = table.new(m, 0)
    for j = 1, m do
      local l, r = W[j][1], W[j][cols]
      local hx, hy, hz = (r.x - l.x) * 0.5, (r.y - l.y) * 0.5, (r.z - l.z) * 0.5 -- half-span edge->centre (3D, banked).
      local hw = sqrt(hx * hx + hy * hy + hz * hz)
      local bx, by, bz
      if hw > 1e-9 then bx, by, bz = hx / hw, hy / hw, hz / hw else bx, by, bz = 1, 0, 0 end
      sData[j] = {
        pos = vec3((l.x + r.x) * 0.5, (l.y + r.y) * 0.5, (l.z + r.z) * 0.5),
        width = hw * 2.0,
        binormal = vec3(bx, by, bz),
      }
    end
    return { sData }
  end
  -- Terrain road (isMesh=false): no deck grid, so build the same source spans from the FLAT carriageway edges instead. Same
  -- {pos,width,binormal} format -- terraformToSources grades the terrain flush to the road's alignment Z across the full width.
  local eL, eR = group.meshEdgeL, group.meshEdgeR
  local n = eL and #eL or 0
  if n < 2 or not eR then return nil end
  local sData = table.new(n, 0)
  for j = 1, n do
    local l, r = eL[j], eR[j]
    local hx, hy, hz = (r.x - l.x) * 0.5, (r.y - l.y) * 0.5, (r.z - l.z) * 0.5
    local hw = sqrt(hx * hx + hy * hy + hz * hz)
    local bx, by, bz
    if hw > 1e-9 then bx, by, bz = hx / hw, hy / hw, hz / hw else bx, by, bz = 1, 0, 0 end
    sData[j] = {
      pos = vec3((l.x + r.x) * 0.5, (l.y + r.y) * 0.5, (l.z + r.z) * 0.5),
      width = hw * 2.0,
      binormal = vec3(bx, by, bz),
    }
  end
  return { sData }
end

-- Refreshes the road's CURRENT footprint (never terraform a stale/nil source) and returns its terraform sources: a mesh road
-- rebuilds its deck grid; a terrain road rebuilds its flat edges (no deck).
local function freshTerraSources(group)
  if group.isMesh == false then meshMgr.buildTerrainEdges(group) else meshMgr.updateMesh(group) end
  return terraSources(group)
end

-- End clip at source row a (b = its inner neighbour): { x, y, dx, dy, hw } with dx, dy pointing out of the road (see terraformToSources).
local function endClip(a, b)
  local dx, dy = a.pos.x - b.pos.x, a.pos.y - b.pos.y
  local len = sqrt(dx * dx + dy * dy)
  if len < 1e-6 then return nil end
  return { x = a.pos.x, y = a.pos.y, dx = dx / len, dy = dy / len, hw = a.width * 0.5 }
end

-- Terraforms the selected road. With terraClipEnds, the start and end are cut planes: nothing in front of either end is graded.
local function terraformRoad(selGroup)
  local sources = freshTerraSources(selGroup)
  if not sources then return end
  local run = sources[1]
  local m = #run
  local clips = {}
  if terraClipEnds and not selGroup.isLoop and m >= 2 then
    clips[#clips + 1] = endClip(run[1], run[2])
    clips[#clips + 1] = endClip(run[m], run[m - 1])
  end
  terra.carveToSources(selGroup, terraParams.doi, terraParams.margin, terraParams.falloff, terraParams.roughness, terraParams.scale, sources, floor(terraParams.smooth), clips)
end

-- 2D profile-preview transform helpers: map profile data (lateral offset o metres, height dz metres) to screen px using the
-- box `t` built once per draw ({ x0,y0,pad,h,plotW,minO,oRange,midZ,vScale }). profileY clamps off-box values to the border.
local function profileX(o, t) return t.x0 + t.pad + (o - t.minO) / t.oRange * t.plotW end

local function profileY(dz, t)
  local y = t.y0 + t.h * 0.5 - (dz - t.midZ) * t.vScale
  if y < t.y0 + t.pad then return t.y0 + t.pad elseif y > t.y0 + t.h - t.pad then return t.y0 + t.h - t.pad end
  return y
end

-- Draws the read-only 2D cross-section preview.
local function drawProfilePreview(group)
  local pts, bandMat = profile.previewCrossSection(group)
  if not pts or #pts < 2 then return end

  local dl = im.GetWindowDrawList()
  local origin = im.GetCursorScreenPos()
  local w = max(80, im.GetContentRegionAvailWidth())
  local h = 64
  local x0, y0 = origin.x, origin.y
  local pad = 8

  local bgCol = im.GetColorU322(im.ImVec4(0.10, 0.10, 0.12, 1.0))
  local borderCol = im.GetColorU322(im.ImVec4(0.35, 0.35, 0.40, 1.0))
  local roadCol = im.GetColorU322(im.ImVec4(0.85, 0.85, 0.92, 1.0))
  local shoulderCol = im.GetColorU322(im.ImVec4(0.90, 0.68, 0.30, 1.0))
  local centreCol = im.GetColorU322(im.ImVec4(0.30, 0.60, 0.85, 0.7))

  im.ImDrawList_AddRectFilled(dl, im.ImVec2(x0, y0), im.ImVec2(x0 + w, y0 + h), bgCol)
  im.ImDrawList_AddRect(dl, im.ImVec2(x0, y0), im.ImVec2(x0 + w, y0 + h), borderCol)

  -- Data bounds.
  local minO, maxO, minZ, maxZ = pts[1].o, pts[1].o, pts[1].dz, pts[1].dz
  for j = 1, #pts do
    local o, dz = pts[j].o, pts[j].dz
    if o < minO then minO = o end
    if o > maxO then maxO = o end
    if dz < minZ then minZ = dz end
    if dz > maxZ then maxZ = dz end
  end
  local oRange = max(maxO - minO, 1e-3)
  local midZ = (minZ + maxZ) * 0.5

  -- Horizontal fits the full width; vertical uses the SAME metres-per-pixel as horizontal (true 1:1 aspect), so a slope
  -- drawn here is exactly the slope in the mesh -- no vertical exaggeration. Subtle drainage crossfall therefore looks
  -- subtle (as it is), and only genuinely steep crown/shoulders read as steep. Off-box values clamp to the border.
  local plotW = w - 2 * pad
  local vScale = plotW / oRange
  local t = { x0 = x0, y0 = y0, pad = pad, h = h, plotW = plotW, minO = minO, oRange = oRange, midZ = midZ, vScale = vScale }

  -- Cross-section bands (carriageway vs shoulder colour) drawn first, so the lane markings overlay on top.
  for b = 1, #bandMat do
    local a, c = pts[b], pts[b + 1]
    local col = bandMat[b] == profile.MAT_SHOULDER and shoulderCol or roadCol
    im.ImDrawList_AddLine(dl, im.ImVec2(profileX(a.o, t), profileY(a.dz, t)), im.ImVec2(profileX(c.o, t), profileY(c.dz, t)), col, 2.0)
  end

  -- Lane markings must be REPRESENTATIVE.
  local nL = max(0, floor(group.lanesLeft or 1))
  local nR = max(0, floor(group.lanesRight or 1))
  local lw = group.laneWidthM or 3.65
  local leftExt = group.leftExtM or ((nL + nR) * lw * 0.5)
  local rightExt = group.rightExtM or leftExt

  local laneCol = im.GetColorU322(im.ImVec4(0.55, 0.58, 0.65, 0.35))
  local edgeCol = im.GetColorU322(im.ImVec4(0.95, 0.95, 1.00, 0.85))
  local yT, yB = y0 + pad, y0 + h - pad

  for k = 1, nL + nR - 1 do
    local lx = profileX(-leftExt + k * lw, t)
    if k == nL and nL > 0 and nR > 0 then
      im.ImDrawList_AddLine(dl, im.ImVec2(lx, yT), im.ImVec2(lx, yB), centreCol, 1.5) -- opposing-traffic centre line.
    else
      im.ImDrawList_AddLine(dl, im.ImVec2(lx, yT), im.ImVec2(lx, yB), laneCol, 1.0)
    end
  end

  -- Carriageway edge lines (white) at the carriageway/shoulder boundary, so the shoulder band is clearly delimited.
  local le, re = profileX(-leftExt, t), profileX(rightExt, t)
  im.ImDrawList_AddLine(dl, im.ImVec2(le, yT), im.ImVec2(le, yB), edgeCol, 1.5)
  im.ImDrawList_AddLine(dl, im.ImVec2(re, yT), im.ImVec2(re, yB), edgeCol, 1.5)

  im.Dummy(im.ImVec2(w, h))
end

-- Renders the offset + width sliders for one auto-generated edge decal (edge line / edge blend), shown only
-- when that decal is enabled. Offset is a lateral multiplier (1.0 == the road edge), width is in metres.
local function edgeDecalControls(group, label, offsetKey, offsetDefault, widthKey, widthDefault)
  im.TextColored(cols.dullWhite or cols.greenB, label)
  im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
  im.Columns(2, offsetKey .. 'Cols', false)
  im.SetColumnWidth(0, 30)
  resetSlider(group, offsetKey, offsetDefault, 0.0, 3.0, "Offset = %.2f", "Lateral offset of the decal (1.0 = the road edge). Mirrored on both sides.", "Adjust " .. label .. " Offset", false)
  resetSlider(group, widthKey, widthDefault, 0.05, 10.0, "Width (m) = %.2f", "Width of the decal, in metres.", "Adjust " .. label .. " Width", false)
  im.Columns(1)
  im.PopStyleVar()
end

-- One profile-preset icon button (Profile tab): apply preset `key` to `selGroup` as an undoable action. isLast omits the
-- trailing SameLine so the columns row closes cleanly.
local function presetBtn(selGroup, icon, key, label, tip, isLast)
  if editor.uiIconImageButton(icon, iconsBig, cols.blueB, nil, nil, key .. 'PresetBtn') then
    local statePre = groupMgr.deepCopyGroup(selGroup)
    groupMgr.applyProfilePreset(selGroup, key)
    editor.history:commitAction("Apply " .. label .. " Profile", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
  im.tooltip(tip)
  if not isLast then im.SameLine() end
  im.NextColumn()
end

-- Small material swatch to the LEFT of the picker button (Materials tab).
local function matThumb(matName)
  if matName and matName ~= "" then
    local tex = matThumbCache[matName]
    if tex == nil then
      tex = false
      local mat = scenetree.findObject(matName)
      if mat then
        local p = mat:getField("diffuseMap", 0)
        if p == "" then p = mat:getField("colorMap", 0) end
        if p == "" then p = mat:getField("baseColorMap", 0) end
        if p and p ~= "" then
          local absPath = string.find(p, "/") and p or (mat:getPath() .. p)
          local t = editor.texObj(absPath)
          if t and not tableIsEmpty(t) and t.tex then tex = t end
        end
      end
      matThumbCache[matName] = tex
    end
    if tex and tex.tex then im.Image(tex.tex:getID(), iconsSmall); im.SameLine(); return end
  end
  im.Dummy(iconsSmall)
  im.SameLine()
end

-- One material row (Materials tab): [reset material] [swatch] [pick] label for `selGroup`. defaultMat drives the left reset
-- (shown only when the material differs). texLenKey/texWidthKey (surface materials only) add the UV tiling sliders (m per
-- repeat) below.
local function matRow(selGroup, target, matKey, defaultMat, label, btnId, tip, texLenKey, texWidthKey, texDefault)
  if selGroup[matKey] ~= defaultMat then
    if editor.uiIconImageButton(editor.icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'matreset_' .. matKey) then
      local pre = groupMgr.deepCopyGroup(selGroup)
      selGroup[matKey] = defaultMat
      selGroup.isDirty = true
      editor.history:commitAction("Reset Material", { old = pre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
    end
    im.tooltip("Reset to the default material.")
  else
    im.Dummy(iconsSmall)
  end
  im.SameLine()
  matThumb(selGroup[matKey])
  if editor.uiIconImageButton(editor.icons.youtube_searched_for, iconsSmall, cols.blueB, nil, nil, btnId) then
    matSelectTarget = target
    materialSelectionMgr.openWindow()
  end
  im.tooltip(tip)
  im.SameLine()
  im.SetCursorPosY(im.GetCursorPosY() + max(0, (iconsSmall.y - im.GetTextLineHeight()) * 0.5))
  im.Text(label .. ': [' .. (selGroup[matKey] or 'Not Selected') .. ']')
  -- Texture tiling. Surface (mesh) materials get length (along) + width (across) so the asphalt isn't stretched. Marking
  -- materials are decals -- their width IS the line width, so only length (repeat along the road) applies, and it maps to
  -- the auto-layer's textureLength.
  if texLenKey then
    local td = texDefault or 4.0
    im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
    im.Columns(2, 'tex_' .. matKey, false)
    im.SetColumnWidth(0, 30)
    resetSlider(selGroup, texLenKey, td, 0.5, 40.0, "Tex Length (m) = %.1f", label .. " texture tile length along the road (m per repeat). Larger = less tiling.", "Adjust " .. label .. " Tex Length", false)
    if texWidthKey then
      resetSlider(selGroup, texWidthKey, td, 0.5, 40.0, "Tex Width (m) = %.1f", label .. " texture tile width across the road (m per repeat). Adjust to remove sideways stretch.", "Adjust " .. label .. " Tex Width", false)
    end
    im.Columns(1)
    im.PopStyleVar()
  end
end

-- Returns the per-corner override record for a node, creating an empty one on first edit (the array slot is kept dense/false
-- by groupMgr + splineInput, so this only ever flips false -> {}). Keeps overrides sparse: unset corners stay false.
local function ensureCornerOverride(selGroup, idx)
  local ov = selGroup.corners[idx]
  if not ov then ov = {}; selGroup.corners[idx] = ov end
  return ov
end

-- Global design-compliance heatmap control: a session view-mode radio (Off / Grade / Corner Radius -- the radio IS the on/off,
-- no separate toggle) plus the per-road CLASS radio for the selected road.
local function groundmodelRow(selGroup)
  -- Row 1: palette swatches (active one gets a white border), then a gap, then Clear / Clean, a gap, and the Wire toggle.
  -- Grip variants are resolved by naming convention (<carriageway>_wet/_snow/_ice); a state whose material is absent is greyed.
  local baseMat = selGroup and (selGroup.carriagewayMaterial or 'm_asphalt_new_01')
  if selGroup and not surfaceKit.isAvailable(groundmodel.getMatIndex(), baseMat) then groundmodel.setMatIndex(1) end -- picked surface has no material on this road.
  local cur = groundmodel.getMatIndex()
  for i = 1, surfaceKit.count() do
    local c = surfaceKit.colOf(i)
    local avail = surfaceKit.isAvailable(i, baseMat)
    if i > 1 then im.SameLine(0, 3) end
    local sel = (i == cur)
    local a = avail and 1.0 or 0.28 -- dim the swatch when there's no material for this surface.
    im.PushStyleColor2(im.Col_Button, im.ImVec4(c[1] / 255, c[2] / 255, c[3] / 255, a))
    im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(c[1] / 255, c[2] / 255, c[3] / 255, avail and 0.85 or 0.28))
    im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(c[1] / 255, c[2] / 255, c[3] / 255, a))
    if sel then
      im.PushStyleColor2(im.Col_Border, im.ImVec4(1, 1, 1, 1))
      im.PushStyleVar1(im.StyleVar_FrameBorderSize, 2)
    end
    if im.Button('###gcMat' .. i, im.ImVec2(24, 22)) and avail then groundmodel.setMatIndex(i) end
    im.PopStyleColor(sel and 4 or 3)
    if sel then im.PopStyleVar(1) end
    if surfaceKit.isBase(i) then
      im.tooltip(surfaceKit.labelOf(i) .. ' - base surface (' .. tostring(baseMat) .. '); paint to erase')
    elseif avail then
      im.tooltip(surfaceKit.labelOf(i) .. ' - physics surface (' .. tostring(surfaceKit.variantMaterial(i, baseMat)) .. ')')
    else
      im.tooltip(surfaceKit.labelOf(i) .. ' - unavailable: no material "' .. tostring(baseMat) ..
        (i == 3 and '_snow' or (i == 4 and '_ice' or '_wet')) .. '" in this level')
    end
  end

  im.SameLine(0, 20)
  if im.Button('Apply###gcApply') then groundmodel.requestApply() end
  im.tooltip('Apply the paint to the road physics so you can drive-test grip.')
  im.SameLine(0, 6)
  if im.Button('Clear###gcClear') and selGroup then
    local pre = groupMgr.deepCopyGroup(selGroup)
    groundmodel.clearAll(selGroup)
    editor.history:commitAction('Clear Groundmodel', { old = pre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
  im.tooltip('Clear all paint (back to Dry).')
  im.SameLine(0, 20)
  local wp = im.BoolPtr(groundmodel.getShowWire())
  if im.Checkbox('Wire###gcWire', wp) then groundmodel.setShowWire(wp[0]) end
  im.tooltip('Show the deck triangle grid (near camera).')

  -- Row 2: full-width brush-radius slider with the standard left-hand reset-to-default button.
  local brushDef = groundmodel.getBrushDefault()
  if groundmodel.getBrushRadius() ~= brushDef then
    if editor.uiIconImageButton(editor.icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'gcBrushReset') then groundmodel.setBrushRadius(brushDef) end
    im.tooltip('Reset to default')
  else
    im.Dummy(iconsSmall)
  end
  im.SameLine()
  im.PushItemWidth(-1)
  local rp = im.FloatPtr(groundmodel.getBrushRadius())
  if im.SliderFloat('###gcBrush', rp, 0.5, 20.0, 'Brush (m) = %.1f') then groundmodel.setBrushRadius(rp[0]) end
  im.PopItemWidth()
  im.tooltip('Brush radius (m): small paints a lane, large the full width.')
end

-- Overlay control: a single view/edit-mode radio row (compliance heatmaps + the groundmodel paint mode).
local function overlayControl(selGroup)
  im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
  im.TextColored(cols.greenB, 'Overlay:')
  im.SameLine()
  if im.RadioButton1('Off###hmOff', heatMetric == 'off') then heatMetric = 'off'; groundmodel.setActive(false) end
  im.tooltip('Hide the overlay.')
  im.SameLine()
  if im.RadioButton1('Grade###hmGrade', heatMetric == 'grade') then heatMetric = 'grade'; groundmodel.setActive(false) end
  im.tooltip('Shade the road by steepness: blue within the class grade limit, red where it exceeds it.')
  im.SameLine()
  if im.RadioButton1('Corner Radius###hmRadius', heatMetric == 'radius') then heatMetric = 'radius'; groundmodel.setActive(false) end
  im.tooltip("Shade the road by corner tightness: blue where corners meet the class minimum radius, red where they're tighter.")
  im.SameLine()
  -- Groundmodel paints physics onto carriageway mesh triangles, so it's mesh-roads only. A terrain road has no deck: disable
  -- the option, and drop out of paint mode if the road was flipped to terrain while it was active.
  local meshOff = selGroup.isMesh == false
  if meshOff and heatMetric == 'groundmodel' then heatMetric = 'off'; groundmodel.setActive(false) end
  if meshOff then im.BeginDisabled(true) end
  if im.RadioButton1('Groundmodel###hmGC', heatMetric == 'groundmodel') then heatMetric = 'groundmodel'; groundmodel.setActive(true) end
  if meshOff then im.EndDisabled() end
  im.tooltip(meshOff and 'Mesh roads only: a terrain road has no deck to paint.'
    or 'Paint physics surfaces (dry / wet / snow / ice) onto the deck. No visual change in-game; add a decal layer for the look.')

  if heatMetric == 'grade' or heatMetric == 'radius' then
    im.Text('Class:')
    for _, id in ipairs(heatmap.classOrder) do
      local cls = heatmap.classes[id]
      im.SameLine()
      if im.RadioButton1(cls.label .. '###hmClass' .. id, selGroup.roadClass == id) and selGroup.roadClass ~= id then
        local pre = groupMgr.deepCopyGroup(selGroup)
        selGroup.roadClass = id
        editor.history:commitAction('Road Class', { old = pre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
      end
      im.tooltip(string.format('%s\nLimits: max %d%% grade, min %d m corner radius.', cls.desc, cls.maxGradePct, cls.minRadiusM))
    end
  elseif heatMetric == 'groundmodel' then
    groundmodelRow(selGroup)
  end
  im.PopStyleVar(1)
end

-- A dull vertical bar between inline stat items (shared road-tool footer style).
local function statSep() im.SameLine(0, 6); im.TextColored(cols.dullWhite, "|"); im.SameLine(0, 6) end

-- Always-on summary footer at the bottom of the window. All figures are for the SELECTED road (not session-wide), matching the
-- other road tools' per-object footers.
local function drawBottomStats(selGroup)
  im.Separator()

  local selNodes = (selGroup and selGroup.nodes) and #selGroup.nodes or 0
  local selLenM = 0
  if selGroup then
    selLenM = (selGroup.meshVArc and selGroup.meshStationCount and selGroup.meshVArc[selGroup.meshStationCount]) or selGroup.roadLength or 0
  end
  local selTris = (selGroup and selGroup.triCount) or 0
  local barriers, fences, lamps = barrierMgr.counts(selGroup)

  table.clear(statList)
  statList[#statList + 1] = { label = "Nodes",    val = tostring(selNodes),                 tip = "Nodes in this road." }
  statList[#statList + 1] = { label = "Length",   val = string.format("%.0f m", selLenM),   tip = "Centreline length." }
  statList[#statList + 1] = { label = "Tris",     val = tostring(selTris),                  tip = "Live deck triangles (0 for a terrain road)." }
  statList[#statList + 1] = { label = "Walk tris", val = tostring(sidewalkMgr.tris(selGroup)), tip = "Footway triangles, both sides (0 once baked)." }
  statList[#statList + 1] = { label = "Barriers", val = tostring(barriers),                 tip = "Barrier pieces, both sides (0 once baked)." }
  statList[#statList + 1] = { label = "Fences",   val = tostring(fences),                   tip = "Fence pieces, both sides (0 once baked)." }
  statList[#statList + 1] = { label = "Lamps",    val = tostring(lamps),                    tip = "Lamp posts, both sides (0 once baked)." }

  local avail = im.GetContentRegionAvailWidth()
  local sepW = im.CalcTextSize("|").x + 12 -- the " | " separator (6px each side).
  local x = 0
  for i = 1, #statList do
    local it = statList[i]
    local col = (i % 2 == 1) and cols.greenB or cols.blueB
    local w = im.CalcTextSize(it.label).x + 3 + im.CalcTextSize(it.val).x
    if i > 1 then
      if x + sepW + w <= avail then statSep(); x = x + sepW else x = 0 end -- fits: keep inline; else fall to a fresh line.
    end
    im.TextColored(cols.dullWhite, it.label); im.SameLine(0, 3); im.TextColored(col, it.val)
    if it.tip then im.tooltip(it.tip) end
    x = x + w
  end
end

-- Main tool window UI.
local function handleMainToolWindowUI()
  if editor.beginWindow(toolWindowName, session.windowTitle(sessionSpec.toolId, "Hero Road Editor", toolWindowName), im.WindowFlags_NoCollapse) then
    local icons = editor.icons
    local groups = groupMgr.getGroups()

    im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
    im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

    -- 'Add New Hero Road' button.
    if editor.uiIconImageButton(icons.roadStackPlus, iconsBig, cols.blueB, nil, nil, 'addNewRoadSplineBtn') then
      local oldState = groupMgr.deepCopyAllGroups()
      groupMgr.addNewGroup()
      local newState = groupMgr.deepCopyAllGroups()
      editor.history:commitAction("Add New Hero Road", { old = oldState, new = newState }, groupMgr.transGroupEditUndo, groupMgr.transGroupEditRedo, true)
      selectedGroupIdx = #groups
    end
    im.tooltip('Add a new hero road.')
    im.SameLine()

    -- 'Draw A Selection Polygon' button.
    local btnCol = isDrawPolygon and cols.blueB or cols.blueD
    if editor.uiIconImageButton(icons.rounded_corner, iconsBig, btnCol, nil, nil, 'drawPolygonBtn') then
      isDrawPolygon = not isDrawPolygon
      poly.clearPolygon() -- Ensure there is no residual polygon left over from the previous usage.
    end
    im.tooltip(isDrawPolygon and 'Click to stop drawing a selection polygon.' or 'Click to draw a selection polygon, to convert scene objects to a Hero Road.')
    im.SameLine()

    -- 'Remove All Splines' button.
    if #groups > 0 then
      if editor.uiIconImageButton(icons.trashBin2, iconsBig, cols.blueB, nil, nil, 'removeAllSplinesBtn') then
        local statePre = groupMgr.deepCopyAllGroups()
        groupMgr.removeAllGroups()
        editor.history:commitAction("Remove All Hero Roads", { old = statePre, new = groupMgr.deepCopyAllGroups() }, groupMgr.transGroupEditUndo, groupMgr.transGroupEditRedo, true)
        selectedGroupIdx = 1
      end
      im.tooltip('Remove all hero roads from the session.')
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()

    -- 'Lock Shape' toggle button.
    local selGroup = groups[selectedGroupIdx]
    if selGroup and selGroup.isEnabled then
      btnCol = isLockShape and cols.blueB or cols.blueD
      if editor.uiIconImageButton(icons.roadGuideArrowSolid, iconsBig, btnCol, nil, nil, 'lockShapeBtn') then
        isLockShape = not isLockShape
      end
      im.tooltip((isLockShape and 'Unlock the shape of the hero road to move nodes separately' or 'Lock the shape of the hero road to move nodes rigidly'))
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()

    -- Pan-camera toggle: swaps between a top-down pan/zoom camera (RMB-drag to move, wheel to zoom) and the editor's normal
    -- free camera. Useful for large roads. When switched on it frames the selected hero road (or drops top-down where you
    -- are). See toolUtilities/panCamera (shared with roadNetwork).
    if editor.uiIconImageButton(icons.videocam, iconsBig, panCamera.isOn() and cols.blueB or cols.blueD, nil, nil, 'heroPanCamBtn') then
      panCamera.toggle()
    end
    im.tooltip(panCamera.isOn() and 'Pan camera ON: top-down, RMB-drag to move, wheel to zoom. Click to hand back the free camera.'
      or 'Pan camera: top-down view with RMB-drag pan + wheel zoom. Click to enable (free camera otherwise).')
    im.SameLine()

    -- 'Import From Bitmap Mask' (session-scope; kept by Save/Load rather than in a tab, because you use it with ZERO roads to
    -- build roads from a painted PNG). The matching Export mask lives in the Mesh tab beside Bake.
    if editor.uiIconImageButton(icons.floppyDiskPlus, iconsBig, cols.blueB, nil, nil, 'importFromBitmapMaskBtn') then
      extensions.editor_fileDialog.openFile(
        function(data)
          if data.filepath then
            local paths = skeleton.getPathsFromPng(data.filepath)
            if #paths > 0 then
              local preState = groupMgr.deepCopyAllGroups()
              groupMgr.convertPathsToRoadSplines(paths)
              editor.history:commitAction("Import Hero Roads From Bitmap", { old = preState, new = groupMgr.deepCopyAllGroups() }, groupMgr.transGroupEditUndo, groupMgr.transGroupEditRedo, true)
            end
          end
        end,
        {{"PNG",".png"}},
        false,
        "/")
    end
    im.tooltip('Import hero roads from a bitmap mask.')
    im.SameLine()

    -- 'Save Session' / 'Load Session' (+ the Replace/Merge modal) via the shared helper -- last buttons of the row. Save hides itself when empty.
    session.renderButtons(sessionSpec)

    im.PopStyleVar(2)
    im.Columns(1)
    im.Separator()

    -- Road splines list.
    if #groups > 0 then
      im.TextColored(cols.greenB, "Hero Roads:")
      selectedGroupIdx = max(1, min(#groups, selectedGroupIdx)) -- Ensure the selected layer index is within bounds.
      local didGroupIdxChange = (previousSelectedGroupIdx ~= selectedGroupIdx)
      previousSelectedGroupIdx = selectedGroupIdx
      im.PushItemWidth(-1)
      if im.BeginListBox('###1363', im.ImVec2(-1, 180)) then
        im.Columns(3, "roadSplineListBoxColumns", true)
        im.SetColumnWidth(0, 30)
        im.SetColumnWidth(1, 180)
        im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(4, 2))
        im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
        local wCtr = 92333
        for i = 1, #groups do
          local group = groups[i]
          local flag = i == selectedGroupIdx
          if im.Selectable1("###" .. tostring(wCtr), flag, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
            selectedGroupIdx = i
            materialSelectionMgr.closeWindow() -- If using the groups section, ensure the material selection window is closed.
            group.isDirty = true
          end
          if didGroupIdxChange and i == selectedGroupIdx then
            im.SetScrollHereY(0.5) -- Scrolls so the selected group is centered vertically
            selectedLayerId = nil
          end
          wCtr = wCtr + 1
          im.SameLine()
          im.NextColumn()

          -- 'Hero Road Name' input field.
          im.PushItemWidth(180)
          local splineNamePtr = im.ArrayChar(32, group.name)
          if not group.isEnabled then
            im.TextColored(cols.dullWhite, group.name)
            im.tooltip('This hero road is disabled. To edit or remove it, first enable it.')
          else
            -- Per-keystroke: only update the live label.
            if im.InputText("###" .. tostring(wCtr), splineNamePtr, 32) then
              group.name = ffi.string(splineNamePtr)
            end
            im.tooltip('Edit the hero road name.')
            if im.IsItemActivated() then
              sliderPreEditState = groupMgr.deepCopyGroup(group) -- snapshot before the edit begins, for undo.
            end
            if im.IsItemDeactivatedAfterEdit() then
              group.name = ffi.string(splineNamePtr) -- final buffer value.
              if group.sceneTreeFolderId then
                local folder = scenetree.findObjectById(group.sceneTreeFolderId)
                if folder then
                  folder:setName(group.name)
                  editor.refreshSceneTreeWindow()
                  group.isDirty = true -- Ensures the mesh names are updated in the scene tree.
                  local postState = groupMgr.deepCopyGroup(group)
                  if sliderPreEditState then sliderPreEditState.isUpdateSceneTree = true end
                  postState.isUpdateSceneTree = true
                  editor.history:commitAction("Edit Hero Road Name", { old = sliderPreEditState, new = postState }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
                end
              end
            end
            if im.IsItemActive() then
              selectedGroupIdx = i
            end
          end
          im.PopItemWidth()
          wCtr = wCtr + 1
          im.SameLine()
          im.NextColumn()

          -- 'Remove Selected Hero Road' button.
          if selGroup and selGroup.isEnabled then
            if editor.uiIconImageButton(icons.trashBin2, iconsSmall, cols.blueB, nil, nil, 'removeRoadSpline' .. i) then
              materialSelectionMgr.closeWindow() -- If using the groups section, ensure the material selection window is closed.
              local statePre = groupMgr.deepCopyAllGroups()
              groupMgr.removeGroup(i)
              editor.history:commitAction("Remove Hero Road", { old = statePre, new = groupMgr.deepCopyAllGroups() }, groupMgr.transGroupEditUndo, groupMgr.transGroupEditRedo, true)
              editor.endWindow()
              return
            end
            im.tooltip("Remove this hero road from the session.")
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()

          -- Mesh vs Terrain road toggle (per road). Mesh = raised drivable deck; Terrain = graded into the ground with a
          -- painted surface (no deck). Editable roads only.
          if group.isEnabled then
            local isMeshOn = group.isMesh ~= false
            if editor.uiIconImageButton(isMeshOn and icons.road or icons.terrain, iconsSmall, isMeshOn and cols.blueB or cols.dullWhite, nil, nil, 'meshModeToggle' .. i) then
              local statePre = groupMgr.deepCopyGroup(group)
              group.isMesh = not isMeshOn
              if group.isMesh == false then group.isPainting = true end -- terrain roads paint the surface (it's the only surface).
              group.isDirty = true
              editor.history:commitAction("Toggle Mesh Road", { old = statePre, new = groupMgr.deepCopyGroup(group) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.tooltip(isMeshOn and 'Mesh road: raised drivable deck. Click for a terrain road.' or 'Terrain road: graded in, painted surface, no deck. Click for a mesh deck.')
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()

          -- Unlock button. A BAKE (Export tab) is the ONLY way to reach Live, so there is no go-Live toggle here: an Edit road
          -- shows nothing in this column. A Live road shows Unlock, which reverts the bake -- removes the baked static, un-burns
          -- the sidewalks/furniture -- and restores the editable procedural surface. Undoable (the .dae files are kept so undo can restore the static).
          if not group.isEnabled then
            if editor.uiIconImageButton(icons.lock, iconsSmall, cols.blueD, nil, nil, 'lockUnlockRoadSplineToggleBtn' .. i) then
              local statePre = groupMgr.deepCopyGroup(group)
              exportMgr.unbakeGroup(group)
              selectedGroupIdx = i
              editor.history:commitAction("Unlock Road (Edit)", { old = statePre, new = groupMgr.deepCopyGroup(group) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.tooltip('Live (baked). Click to unlock and edit again. Re-bake (Export tab) to ship.')
          else
            im.Dummy(iconsSmall)
          end
          im.NextColumn()
          im.Separator()
        end
        im.PopStyleVar(2)
        im.EndListBox()
      end
      im.Separator()

      -- Buttons underneath the hero road list box.
      im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
      im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

      -- 'Go To Hero Road' button.
      if selGroup and #selGroup.nodes > 0 then
        if editor.uiIconImageButton(icons.cameraFocusTopDown, iconsBig, cols.blueB, nil, nil, 'goToRoadSplineBtn') then
          materialSelectionMgr.closeWindow() -- If using the groups section, ensure the material selection window is closed.
          -- When the pan camera is driving, fly IT to the road; otherwise do the normal free-camera jump.
          if not panCamera.gotoPoints(selGroup.divPoints) then util.goToSpline(selGroup.divPoints) end
        end
        im.tooltip('Move the camera to the selected Hero Road.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()

      -- 'Split Hero Road' button.
      if selGroup and selGroup.isEnabled and #selGroup.nodes > 2 and (selGroup.isLoop or (selectedNodeIdx > 1 and selectedNodeIdx < #selGroup.nodes)) then
        if editor.uiIconImageButton(icons.content_cut, iconsBig, cols.blueB, nil, nil, 'splitBtn') then
          materialSelectionMgr.closeWindow() -- If using the groups section, ensure the material selection window is closed.
          local statePre = groupMgr.deepCopyAllGroups()
          groupMgr.splitGroup(selGroup, selectedGroupIdx, selectedNodeIdx)
          local statePost = groupMgr.deepCopyAllGroups()
          editor.history:commitAction("Split Hero Road", { old = statePre, new = statePost }, groupMgr.transGroupEditUndo, groupMgr.transGroupEditRedo, true)
        end
        im.tooltip('Splits the selected hero road into two, at the selected node.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()

      -- 'Flip Direction' button.
      if selGroup and selGroup.isEnabled and #selGroup.nodes > 1 then
        if editor.uiIconImageButton(icons.cached, iconsBig, cols.blueB, nil, nil, 'flipDirectionBtn') then
          local statePre = groupMgr.deepCopyGroup(selGroup)
          geom.flipSplineDirection(selGroup)
          selGroup.isDirty = true
          editor.history:commitAction("Flip Hero Road Direction", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
        end
        im.tooltip('Flips the direction of the selected hero road (back to front).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()

      -- 'Drape To Terrain' button: one-shot drop of the free nodes onto the surface below (roadNetwork-style). Seeds
      -- node heights from the ground; nodes stay free-3D afterwards (edit with the gizmo). Not a persistent conform mode.
      if selGroup and selGroup.isEnabled and #selGroup.nodes > 0 then
        if editor.uiIconImageButton(icons.lineToTerrain, iconsBig, cols.blueB, nil, nil, 'drapeToTerrainBtn') then
          local statePre = groupMgr.deepCopyGroup(selGroup)
          groupMgr.conformGroupToTerrain(selGroup)
          editor.history:commitAction("Drape Road To Terrain", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
        end
        im.tooltip('Drop the free control points onto the surface below (seed heights from the ground). Nodes stay editable with the gizmo afterwards.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()

      -- 'Simplify Spline' button.
      if selGroup and selGroup.isEnabled and selGroup.nodes[selectedNodeIdx] and #selGroup.nodes > 2 then
        if editor.uiIconImageButton(icons.routeSimple, iconsBig, cols.blueB, nil, nil, 'simplifySplineBtn') then
          local statePre = groupMgr.deepCopyGroup(selGroup)
          rdp.simplifyNodesWidthsNormals(selGroup.nodes, selGroup.widths, selGroup.nmls, simplifyRdpTol)
          selectedNodeIdx = max(1, min(#selGroup.nodes, selectedNodeIdx))
          selGroup.isDirty = true
          editor.history:commitAction("Simplify Hero Road", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
        end
        im.tooltip('Simplifies the selected hero road (reduces the number of nodes).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()

      -- Procedural mesh preview toggle (per road). On by default; an artist can pin it off on a big/laggy road so edits only
      -- move the flat ribbon and skip the heavy mesh/markings rebuild. Toggling re-dirties the road (rebuild on / tear down off).
      -- Hidden for terrain roads (isMesh=false): they have no deck to preview, so the button would be a no-op.
      if selGroup and selGroup.isEnabled and selGroup.isMesh ~= false then
        local previewOn = selGroup.previewMesh ~= false
        -- Palette colours (not the neon yellowB/redB): the tool's standard blue accent when ON, dimmed dullWhite when OFF.
        if editor.uiIconImageButton(previewOn and icons.grid_on or icons.grid_off, iconsBig, previewOn and cols.blueB or cols.dullWhite, nil, nil, 'previewMeshToggleBtn') then
          selGroup.previewMesh = not previewOn
          selGroup.isDirty = true
        end
        im.tooltip(previewOn and 'Mesh preview: on. Click to hide -- edits then move only the ribbon (faster on big roads).' or 'Mesh preview: off (ribbon only). Click to rebuild the full mesh.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()

      -- Save profile button.
      if selGroup and #selGroup.layers > 0 then
        if editor.uiIconImageButton(icons.floppyDisk, iconsBig, cols.fullWhite, nil, nil, 'saveProfileBtn') then
          materialSelectionMgr.closeWindow() -- If using the groups section, ensure the material selection window is closed.
          extensions.editor_fileDialog.saveFile(
            function(data)
              local profile = groupMgr.copyGroupProfile(selGroup)
              jsonWriteFile(data.filepath, profile, true)
            end,
            {{"JSON",".json"}},
            false,
            "/",
            "File already exists.\nDo you want to overwrite the file?")
        end
        im.tooltip('Saves the selected profile to disk.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()

      -- Load profile button.
      if selGroup then
        if editor.uiIconImageButton(icons.roadFolder, iconsBig, cols.dullWhite, nil, nil, 'loadProfileBtn') then
          materialSelectionMgr.closeWindow() -- If using the groups section, ensure the material selection window is closed.
          extensions.editor_fileDialog.openFile(
            function(data)
              local profile = jsonReadFile(data.filepath)
              groupMgr.pasteGroupProfile(selGroup, profile)
            end,
            {{"JSON",".json"}},
            false,
            "/")
        end
        im.tooltip('Loads a previously-saved profile from disk.')
      else
        im.Dummy(iconsBig)
      end
      im.PopStyleVar(2)
      im.Separator()
    else
      im.Text("No hero roads.")
      im.Text("Click the 'Add' button to add one.")
    end

    -- Hero Road-specific UI.
    if selGroup and selGroup.isEnabled then
      -- Tab bar for organising the interface.
      local selectedTab = 0 -- Default to first tab.
      if im.BeginTabBar("RoadSplineTabs") then
        if im.BeginTabItem("Shape") then
          selectedTab = 0
          im.EndTabItem()
        end
        if im.BeginTabItem("Materials") then
          selectedTab = 3
          im.EndTabItem()
        end
        if im.BeginTabItem("Layers") then
          selectedTab = 1
          im.EndTabItem()
        end
        if im.BeginTabItem("Features") then
          selectedTab = 7
          im.EndTabItem()
        end
        if im.BeginTabItem("Furniture") then
          selectedTab = 4
          im.EndTabItem()
        end
        if im.BeginTabItem("Terrain") then
          selectedTab = 2
          im.EndTabItem()
        end
        if im.BeginTabItem("Mesh") then
          selectedTab = 5
          im.EndTabItem()
        end
        im.EndTabBar()
      end

      -- Tab content. Reserve two text lines + padding at the bottom.
      im.PushStyleVar2(im.StyleVar_WindowPadding, im.ImVec2(4, 8))
      if im.BeginChild1("TabContentChild", im.ImVec2(0, -(im.GetTextLineHeightWithSpacing() * 2 + 18)), true) then
        if selectedTab == 0 then -- Profile tab.
          -- Geometry: how the node polyline becomes the driven road path -- engineered corners that ROUND the interior nodes, or a
          -- smooth spline THROUGH every node. First in the tab: it decides everything below it. Corner radius is per-corner (viewport knob).
          geometrySection(selGroup)
          im.Dummy(im.ImVec2(0, 3))
          im.Separator()

          -- Cross-section shape (superelevation banking + crown/shoulders) is deck-only: a terrain road (isMesh=false) is graded
          -- flat into the ground, so these grey out. The alignment, lane layout and everything below it still apply.
          local meshOff = selGroup.isMesh == false

          -- Superelevation: dynamic corner banking, driven by curvature (independent of the cross-section preview below). Applies
          -- in both geometry modes, so it's a road-wide section here rather than inside the engineered-only block above.
          if meshOff then im.BeginDisabled(true) end
          im.TextColored(cols.greenB, "Superelevation:")
          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.Columns(2, 'superCols', false)
          im.SetColumnWidth(0, 30)
          resetSlider(selGroup, "superElevMaxDeg", 6.0, 0.0, 30.0, "Max Banking = %.1f deg", "Maximum corner banking angle, in degrees. High values (banked ovals) need a smooth surface to stay drivable.", "Adjust Max Superelevation", false)
          resetSlider(selGroup, "superMinRadiusM", 80.0, 10.0, 300.0, "Full-Bank Radius (m) = %.0f", "Corner radius at which maximum banking is reached (tighter = full bank).", "Adjust Super Min Radius", false)
          im.Columns(1)
          im.PopStyleVar()
          if meshOff then im.EndDisabled() end
          im.Dummy(im.ImVec2(0, 3))
          im.Separator()

          -- Profile: the cross-section SHAPE shown in the preview (lanes, crown, shoulders).
          im.TextColored(cols.greenB, "Profile:")

          -- Read-only 2D cross-section preview (looking along the road).
          drawProfilePreview(selGroup)

          -- Preset row directly under the preview: one-click complete cross-section templates (icon buttons, one row).
          im.Columns(8, "profilePresetBtns", false)
          for i = 0, 7 do im.SetColumnWidth(i, 40) end
          im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
          im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
          presetBtn(selGroup, icons.road, "highway", "Highway", "Divided highway: 2+2 wide lanes, gentle drainage crown, broad shoulders, gentle high-speed banking.")
          presetBtn(selGroup, icons.location_city, "city", "City", "Urban street: 1+1 lanes, drainage crown, tight kerb shoulder, minimal banking.")
          presetBtn(selGroup, icons.home, "country", "Country", "Rural road: 1+1 narrower lanes, gravel verge, moderate banking, large rolling surface bumps.")
          presetBtn(selGroup, icons.roadProfile, "ledge", "Ledge", "Mountain shelf: narrow, tight bends, near-vertical embankment shoulder (steep shoulder fall).")
          presetBtn(selGroup, icons.terrain, "rally", "Rally", "Dirt stage: narrow, very rough sharp-chatter surface, low crown, hard banking, no markings.")
          presetBtn(selGroup, icons.flag, "race", "Race", "Race circuit: wide, flat (no crown), heavy corner banking, smooth, no markings.")
          presetBtn(selGroup, icons.roadRoundaboutJunction, "speedway", "Speedway", "Banked oval: very wide, flat cross-section, extreme corner banking.")
          presetBtn(selGroup, icons.roadFace, "valley", "Valley", "Half-pipe / inverted 'smile' crown that falls toward the centre, wide and smooth.", true)
          im.PopStyleVar(2)
          im.Columns(1)

          im.Dummy(im.ImVec2(0, 3))

          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)

          -- Lane layout: left/right lane counts + lane width drive the carriageway width (roadNetwork-style).
          im.Columns(2, 'profileLanes', false)
          im.SetColumnWidth(0, 30)
          resetSlider(selGroup, "lanesLeft", 1, 0, 6, "Lanes Left = %d", "Number of lanes on the left of the spline. Set a side to 0 for a one-way road.", "Adjust Left Lanes", true, groupMgr.syncProfileWidth)
          resetSlider(selGroup, "lanesRight", 1, 0, 6, "Lanes Right = %d", "Number of lanes on the right of the spline. Set a side to 0 for a one-way road.", "Adjust Right Lanes", true, groupMgr.syncProfileWidth)
          resetSlider(selGroup, "laneWidthM", 3.65, 1.5, 5.0, "Lane Width (m) = %.2f", "Width of a single lane, in metres. Total road width = (left + right lanes) x lane width.", "Adjust Lane Width", false, groupMgr.syncProfileWidth)
          im.Columns(1)

          -- Crown / crossfall / shoulders are the deck cross-section -- deck-only, so they grey out for a terrain road.
          if meshOff then im.BeginDisabled(true) end
          -- Crown toggle. Crossfall is a crown-only setting, so it's only shown while the crown is on.
          local crownPtr = im.BoolPtr(selGroup.crownOn ~= false)
          if im.Checkbox("Crown", crownPtr) then
            local statePre = groupMgr.deepCopyGroup(selGroup)
            selGroup.crownOn = crownPtr[0]
            selGroup.isDirty = true
            editor.history:commitAction("Toggle Crown", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
          end
          im.tooltip('Crowned crossfall on straights (apex at the centre). Auto-fades into superelevation through corners.')

          -- Flat ends: ramp the cross-section to level at each open end for clean joins to hand-shaped flat terrain.
          im.SameLine()
          local flatEndsPtr = im.BoolPtr(selGroup.flatEnds == true)
          if im.Checkbox("Flat Ends", flatEndsPtr) then
            local statePre = groupMgr.deepCopyGroup(selGroup)
            selGroup.flatEnds = flatEndsPtr[0]
            selGroup.isDirty = true
            editor.history:commitAction("Toggle Flat Ends", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
          end
          im.tooltip('Flatten the crown, banking and shoulders to a level cross-section over the last few metres at each open end, so the road drops cleanly into flat terrain (chamfers unchanged). Skipped on closed loops.')

          -- Crown crossfall (crown only) + shoulders.
          im.Columns(2, 'profileShape', false)
          im.SetColumnWidth(0, 30)
          if selGroup.crownOn ~= false then
            resetSlider(selGroup, "crossfallPct", 2.5, -25.0, 25.0, "Crossfall = %.1f%%", "Crown cross-slope: how far each side falls from the centre (%%). +ve = a normal crown (~2-3%% drains well); -ve = an inverted 'valley' crown that falls toward the centre.", "Adjust Crossfall", false)
          end
          resetSlider(selGroup, "shoulderWidthM", 0.5, 0.0, 4.0, "Shoulder Width (m) = %.2f", "Width of the shoulder band on each side (0 = no shoulder).", "Adjust Shoulder Width", false)
          resetSlider(selGroup, "shoulderFallPct", 6.0, 0.0, 100.0, "Shoulder Fall = %.1f%%", "Downward slope of the shoulders, in percent (100%% = 45 deg). Low = a gentle verge; high = a steep embankment/wall at the road edge.", "Adjust Shoulder Fall", false)
          if selGroup.flatEnds then
            resetSlider(selGroup, "flatEndLenM", 6.0, 1.0, 30.0, "Flat End Length (m) = %.1f", "Distance over which each open end ramps from the road's normal shape to a flat, level cross-section.", "Adjust Flat End Length", false)
          end
          im.Columns(1)

          -- Chamfers: the small skirt round the deck edge that hides the terrain seam. Sides and ends toggle separately.
          local sideChamPtr = im.BoolPtr(selGroup.sideChamfers ~= false)
          if im.Checkbox("Side Chamfers", sideChamPtr) then
            local statePre = groupMgr.deepCopyGroup(selGroup)
            selGroup.sideChamfers = sideChamPtr[0]
            selGroup.isDirty = true
            editor.history:commitAction("Toggle Side Chamfers", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
          end
          im.tooltip('Skirt along both sides of the deck. Off = the deck stops at its outer edge (e.g. to butt drains against the shoulder).')
          im.SameLine()
          local endChamPtr = im.BoolPtr(selGroup.endChamfers ~= false)
          if im.Checkbox("End Chamfers", endChamPtr) then
            local statePre = groupMgr.deepCopyGroup(selGroup)
            selGroup.endChamfers = endChamPtr[0]
            selGroup.isDirty = true
            editor.history:commitAction("Toggle End Chamfers", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
          end
          im.tooltip('Skirt across the start and end of the deck. Off = square, bare ends (e.g. to butt against another road).')
          if selGroup.sideChamfers ~= false or selGroup.endChamfers ~= false then
            im.Columns(2, 'chamferShape', false)
            im.SetColumnWidth(0, 30)
            resetSlider(selGroup, "chamferAngleDeg", 9.5, 0.0, 70.0, "Chamfer Angle = %.1f deg", "Downward tilt of the chamfer. Low = a shallow lip over the terrain seam; high = a steep skirt into the ground.", "Adjust Chamfer Angle", false)
            im.Columns(1)
          end
          im.PopStyleVar()
          if meshOff then im.EndDisabled() end
          if meshOff then
            im.Dummy(im.ImVec2(0, 3))
            im.TextColored(cols.dullWhite, 'Terrain road: no deck. Surface = Terrain Paint; grade it flush in the Terrain tab.')
          end
        elseif selectedTab == 3 then -- Materials tab.
          -- Road Surface = the deck's asphalt bands (carriageway/shoulder). Deck-only, so grey them out for a terrain road (its
          -- surface is Terrain Paint, set in the Terrain tab). The marking + detail decals below drape on either surface, so stay live.
          local matMeshOff = selGroup.isMesh == false
          if matMeshOff then im.BeginDisabled(true) end
          im.TextColored(cols.greenB, "Road Surface:")
          -- Rows use the module-level matRow / matThumb helpers (small icons keep each row compact).
          matRow(selGroup, 'carriageway', 'carriagewayMaterial', 'm_asphalt_new_01', 'Carriageway', 'selCarriagewayMatBtn', 'Select the carriageway (asphalt) material for the road mesh.', 'carriagewayTexLenM', 'carriagewayTexWidth', 4.0)
          matRow(selGroup, 'shoulder', 'shoulderMaterial', 'm_asphalt_new_01', 'Shoulder', 'selShoulderMatBtn', 'Select the shoulder material for the road mesh.', 'shoulderTexLenM', 'shoulderTexWidth', 4.0)
          if matMeshOff then im.EndDisabled() end
          matRow(selGroup, 'centerline', 'centerLineMaterial', 'm_line_yellow_double', 'Centre Line', 'selCenterLineMatBtn', 'Select the centre-line marking material (opposing-traffic divider).', 'centerLineTexLen', nil, 5.0)
          matRow(selGroup, 'edgeline', 'edgeLineMaterial', 'm_line_white', 'Edge Lines', 'selEdgeLineMatBtn', 'Select the edge-line marking material.', 'edgeLineTexLen', nil, 10.0)
          matRow(selGroup, 'laneline', 'laneLineMaterial', 'm_line_white_discontinue', 'Lane Lines', 'selLaneLineMatBtn', 'Select the lane-division marking material.', 'laneLineTexLen', nil, 10.0)

          -- Detail overlays (wear / repair / patch / crack / tread).
          local detailRows = {
            { flag = 'isLightTreadMarks',  key = 'lightTreadTexLen',     def = 5.0,  label = 'Light Tread' },
            { flag = 'isHeavyTreadMarks',  key = 'heavyTreadTexLen',     def = 5.0,  label = 'Heavy Tread' },
            { flag = 'isRepair1',          key = 'repair1TexLen',        def = 25.0, label = 'Fix 1' },
            { flag = 'isRepair2',          key = 'repair2TexLen',        def = 25.0, label = 'Fix 2' },
            { flag = 'isDamageAsphalt1',   key = 'damageAsphalt1TexLen', def = 10.0, label = 'Wear 1' },
            { flag = 'isDamageAsphalt2',   key = 'damageAsphalt2TexLen', def = 25.0, label = 'Wear 2' },
            { flag = 'isPatches',          key = 'patchesTexLen',        def = 45.0, label = 'Patches' },
            { flag = 'isRoadCrack',        key = 'roadCrackTexLen',      def = 15.0, label = 'Cracks' },
          }
          local anyDetail = false
          for i = 1, #detailRows do if selGroup[detailRows[i].flag] then anyDetail = true; break end end
          if anyDetail then
            im.Dummy(im.ImVec2(0, 3))
            im.Separator()
            im.TextColored(cols.greenB, "Detail Overlays:")
            im.tooltip("Texture tile length for the enabled wear / repair / patch / crack / tread overlays (toggle them in the Layers tab).")
            for i = 1, #detailRows do
              local d = detailRows[i]
              if selGroup[d.flag] then
                im.Text(d.label)
                im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
                im.Columns(2, 'detail_' .. d.key, false)
                im.SetColumnWidth(0, 30)
                resetSlider(selGroup, d.key, d.def, 0.5, 100.0, "Tex Length (m) = %.1f", d.label .. " texture tile length along the road (m per repeat). Larger = less tiling.", "Adjust " .. d.label .. " Tex Length", false)
                im.Columns(1)
                im.PopStyleVar()
              end
            end
          end
        elseif selectedTab == 1 then -- Layers tab.
          -- Road detailing controls.
          im.TextColored(cols.greenB, "Auto-Generated Layers:")
          im.Dummy(im.ImVec2(0, 3))
          im.Columns(1)
          im.Columns(4, "roadDetailingRows", false)

          -- 'Include Light Tread Marks' checkbox.
          local tmpPtr = im.BoolPtr(selGroup.isLightTreadMarks)
          if im.Checkbox("Light", tmpPtr) then
            materialSelectionMgr.closeWindow()
            local statePre = groupMgr.deepCopyGroup(selGroup)
            selGroup.isLightTreadMarks = tmpPtr[0]
            groupMgr.recreateAutoGeneratedLayers(selGroup)
            local statePost = groupMgr.deepCopyGroup(selGroup)
            editor.history:commitAction("Add Light Tread Marks", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            selGroup.isDirty = true
          end
          im.tooltip('Toggle whether to include light tread marks on the Hero Road.')
          im.SameLine()
          im.NextColumn()

          -- 'Include Heavy Tread Marks' checkbox.
          tmpPtr = im.BoolPtr(selGroup.isHeavyTreadMarks)
          if im.Checkbox("Heavy", tmpPtr) then
            materialSelectionMgr.closeWindow()
            local statePre = groupMgr.deepCopyGroup(selGroup)
            selGroup.isHeavyTreadMarks = tmpPtr[0]
            groupMgr.recreateAutoGeneratedLayers(selGroup)
            local statePost = groupMgr.deepCopyGroup(selGroup)
            editor.history:commitAction("Add Heavy Tread Marks", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            selGroup.isDirty = true
          end
          im.tooltip('Toggle whether to include heavy tread marks on the Hero Road.')
          im.SameLine()
          im.NextColumn()

          -- 'Include Repair 1' checkbox.
          tmpPtr = im.BoolPtr(selGroup.isRepair1)
          if im.Checkbox("Fix 1", tmpPtr) then
            materialSelectionMgr.closeWindow()
            local statePre = groupMgr.deepCopyGroup(selGroup)
            selGroup.isRepair1 = tmpPtr[0]
            groupMgr.recreateAutoGeneratedLayers(selGroup)
            local statePost = groupMgr.deepCopyGroup(selGroup)
            editor.history:commitAction("Add Repair 1", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            selGroup.isDirty = true
          end
          im.tooltip('Toggle whether to include repair 1 fixes on the Hero Road.')
          im.SameLine()
          im.NextColumn()

          -- 'Include Repair 2' checkbox.
          tmpPtr = im.BoolPtr(selGroup.isRepair2)
          if im.Checkbox("Fix 2", tmpPtr) then
            materialSelectionMgr.closeWindow()
            local statePre = groupMgr.deepCopyGroup(selGroup)
            selGroup.isRepair2 = tmpPtr[0]
            groupMgr.recreateAutoGeneratedLayers(selGroup)
            local statePost = groupMgr.deepCopyGroup(selGroup)
            editor.history:commitAction("Add Repair 2", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            selGroup.isDirty = true
          end
          im.tooltip('Toggle whether to include repair 2 fixes on the Hero Road.')
          im.NextColumn()

          -- 'Include Road Damage Asphalt 1' checkbox.
          tmpPtr = im.BoolPtr(selGroup.isDamageAsphalt1)
          if im.Checkbox("Wear 1", tmpPtr) then
            materialSelectionMgr.closeWindow()
            local statePre = groupMgr.deepCopyGroup(selGroup)
            selGroup.isDamageAsphalt1 = tmpPtr[0]
            groupMgr.recreateAutoGeneratedLayers(selGroup)
            local statePost = groupMgr.deepCopyGroup(selGroup)
            editor.history:commitAction("Add Road Damage Asphalt 1", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            selGroup.isDirty = true
          end
          im.tooltip('Toggle whether to include damaged asphalt wear 1 on the Hero Road.')
          im.SameLine()
          im.NextColumn()

          -- 'Include Road Damage Asphalt 2' checkbox.
          tmpPtr = im.BoolPtr(selGroup.isDamageAsphalt2)
          if im.Checkbox("Wear 2", tmpPtr) then
            materialSelectionMgr.closeWindow()
            local statePre = groupMgr.deepCopyGroup(selGroup)
            selGroup.isDamageAsphalt2 = tmpPtr[0]
            groupMgr.recreateAutoGeneratedLayers(selGroup)
            local statePost = groupMgr.deepCopyGroup(selGroup)
            editor.history:commitAction("Add Road Damage Asphalt 2", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            selGroup.isDirty = true
          end
          im.tooltip('Toggle whether to include damaged asphalt wear 2 on the Hero Road.')
          im.SameLine()
          im.NextColumn()

          -- 'Include Patches' checkbox.
          tmpPtr = im.BoolPtr(selGroup.isPatches)
          if im.Checkbox("Patches", tmpPtr) then
            materialSelectionMgr.closeWindow()
            local statePre = groupMgr.deepCopyGroup(selGroup)
            selGroup.isPatches = tmpPtr[0]
            groupMgr.recreateAutoGeneratedLayers(selGroup)
            local statePost = groupMgr.deepCopyGroup(selGroup)
            editor.history:commitAction("Add Patches", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            selGroup.isDirty = true
          end
          im.tooltip('Toggle whether to include patches on the Hero Road.')
          im.SameLine()
          im.NextColumn()

          -- 'Include Road Crack' checkbox.
          tmpPtr = im.BoolPtr(selGroup.isRoadCrack)
          if im.Checkbox("Cracks", tmpPtr) then
            materialSelectionMgr.closeWindow()
            local statePre = groupMgr.deepCopyGroup(selGroup)
            selGroup.isRoadCrack = tmpPtr[0]
            groupMgr.recreateAutoGeneratedLayers(selGroup)
            local statePost = groupMgr.deepCopyGroup(selGroup)
            editor.history:commitAction("Add Road Crack", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            selGroup.isDirty = true
          end
          im.tooltip('Toggle whether to include road cracks on the Hero Road.')
          im.NextColumn()

          im.Columns(1)

          -- Paint line controls.
          im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
          im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

          -- 'Road Center Line' toggle button.
          btnCol = selGroup.isRoadCenterLine and cols.blueB or cols.blueD
          if editor.uiIconImageButton(icons.roadRefPathDecal, iconsBig, btnCol, nil, nil, 'roadCenterLineBtn') then
            materialSelectionMgr.closeWindow()
            selGroup.isRoadCenterLine = not selGroup.isRoadCenterLine
            if selGroup.isRoadCenterLine then
              local statePre = groupMgr.deepCopyGroup(selGroup)
              layerMgr.addRoadCenterLineLayers(selGroup)
              local statePost = groupMgr.deepCopyGroup(selGroup)
              editor.history:commitAction("Add Road Center Line", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            else
              local statePre = groupMgr.deepCopyGroup(selGroup)
              layerMgr.removeRoadCenterLineLayers(selGroup)
              local statePost = groupMgr.deepCopyGroup(selGroup)
              editor.history:commitAction("Remove Road Center Line", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            selGroup.isDirty = true
          end
          im.tooltip(((selGroup.isRoadCenterLine and 'Disable') or 'Enable') .. ' the road center line.')
          im.SameLine()

          -- 'Road Edge Lines' toggle button.
          btnCol = selGroup.isRoadEdgeLines and cols.blueB or cols.blueD
          if editor.uiIconImageButton(icons.roadEdgeLineDecal, iconsBig, btnCol, nil, nil, 'roadEdgeLinesBtn') then
            materialSelectionMgr.closeWindow()
            selGroup.isRoadEdgeLines = not selGroup.isRoadEdgeLines
            if selGroup.isRoadEdgeLines then
              local statePre = groupMgr.deepCopyGroup(selGroup)
              layerMgr.addRoadEdgeLinesLayers(selGroup)
              local statePost = groupMgr.deepCopyGroup(selGroup)
              editor.history:commitAction("Add Road Edge Lines", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            else
              local statePre = groupMgr.deepCopyGroup(selGroup)
              layerMgr.removeRoadEdgeLinesLayers(selGroup)
              local statePost = groupMgr.deepCopyGroup(selGroup)
              editor.history:commitAction("Remove Road Edge Lines", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            selGroup.isDirty = true
          end
          im.tooltip(((selGroup.isRoadEdgeLines and 'Disable') or 'Enable') .. ' the road edge lines.')
          im.SameLine()

          -- 'Road Lane Lines' toggle button.
          btnCol = selGroup.isRoadLaneLines and cols.blueB or cols.blueD
          if editor.uiIconImageButton(icons.roadDividerLinesDecal, iconsBig, btnCol, nil, nil, 'roadLaneLinesBtn') then
            materialSelectionMgr.closeWindow()
            selGroup.isRoadLaneLines = not selGroup.isRoadLaneLines
            if selGroup.isRoadLaneLines then
              local statePre = groupMgr.deepCopyGroup(selGroup)
              layerMgr.addRoadLaneLinesLayers(selGroup)
              local statePost = groupMgr.deepCopyGroup(selGroup)
              editor.history:commitAction("Add Road Lane Lines", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            else
              local statePre = groupMgr.deepCopyGroup(selGroup)
              layerMgr.removeRoadLaneLinesLayers(selGroup)
              local statePost = groupMgr.deepCopyGroup(selGroup)
              editor.history:commitAction("Remove Road Lane Lines", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            selGroup.isDirty = true
          end
          im.tooltip(((selGroup.isRoadLaneLines and 'Disable') or 'Enable') .. ' the road lane lines.')
          im.SameLine()

          -- 'Edge Blend 1' toggle button.
          btnCol = selGroup.isEdgeBlend1 and cols.blueB or cols.blueD
          if editor.uiIconImageButton(icons.roadSidewalkTransition, iconsBig, btnCol, nil, nil, 'edgeBlend1Btn') then
            materialSelectionMgr.closeWindow()
            selGroup.isEdgeBlend1 = not selGroup.isEdgeBlend1
            if selGroup.isEdgeBlend1 then
              local statePre = groupMgr.deepCopyGroup(selGroup)
              layerMgr.addEdgeBlend1Layers(selGroup)
              local statePost = groupMgr.deepCopyGroup(selGroup)
              editor.history:commitAction("Add Edge Blend 1", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            else
              local statePre = groupMgr.deepCopyGroup(selGroup)
              layerMgr.removeEdgeBlend1Layers(selGroup)
              local statePost = groupMgr.deepCopyGroup(selGroup)
              editor.history:commitAction("Remove Edge Blend 1", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            selGroup.isDirty = true
          end
          im.tooltip(((selGroup.isEdgeBlend1 and 'Disable') or 'Enable') .. ' the edge blend 1.')
          im.SameLine()

          -- 'Edge Blend 2' toggle button.
          btnCol = selGroup.isEdgeBlend2 and cols.blueB or cols.blueD
          if editor.uiIconImageButton(icons.roadSidewalkTransition, iconsBig, btnCol, nil, nil, 'edgeBlend2Btn') then
            materialSelectionMgr.closeWindow()
            selGroup.isEdgeBlend2 = not selGroup.isEdgeBlend2
            if selGroup.isEdgeBlend2 then
              local statePre = groupMgr.deepCopyGroup(selGroup)
              layerMgr.addEdgeBlend2Layers(selGroup)
              local statePost = groupMgr.deepCopyGroup(selGroup)
              editor.history:commitAction("Add Edge Blend 2", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            else
              local statePre = groupMgr.deepCopyGroup(selGroup)
              layerMgr.removeEdgeBlend2Layers(selGroup)
              local statePost = groupMgr.deepCopyGroup(selGroup)
              editor.history:commitAction("Remove Edge Blend 2", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            selGroup.isDirty = true
          end
          im.tooltip(((selGroup.isEdgeBlend2 and 'Disable') or 'Enable') .. ' the edge blend 2.')
          im.SameLine()

          -- 'Edge Blend 3' toggle button.
          btnCol = selGroup.isEdgeBlend3 and cols.blueB or cols.blueD
          if editor.uiIconImageButton(icons.road, iconsBig, btnCol, nil, nil, 'edgeBlend3Btn') then
            materialSelectionMgr.closeWindow()
            selGroup.isEdgeBlend3 = not selGroup.isEdgeBlend3
            if selGroup.isEdgeBlend3 then
              local statePre = groupMgr.deepCopyGroup(selGroup)
              layerMgr.addEdgeBlend3Layers(selGroup)
              local statePost = groupMgr.deepCopyGroup(selGroup)
              editor.history:commitAction("Add Edge Blend 3", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            else
              local statePre = groupMgr.deepCopyGroup(selGroup)
              layerMgr.removeEdgeBlend3Layers(selGroup)
              local statePost = groupMgr.deepCopyGroup(selGroup)
              editor.history:commitAction("Remove Edge Blend 3", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            selGroup.isDirty = true
          end
          im.tooltip(((selGroup.isEdgeBlend3 and 'Disable') or 'Enable') .. ' the edge blend 3.')
          im.PopStyleVar(2)

          im.Columns(1)

          -- Road-level placement/size controls for the enabled edge decals (edge line + edge blends).
          if selGroup.isRoadEdgeLines or selGroup.isEdgeBlend1 or selGroup.isEdgeBlend2 or selGroup.isEdgeBlend3 then
            im.Separator()
            im.TextColored(cols.greenB, "Edge Decals:")
            if selGroup.isRoadEdgeLines then edgeDecalControls(selGroup, "Edge Line", "edgeLineOffset", 1.0, "edgeLineWidth", 0.25) end
            if selGroup.isEdgeBlend1 then edgeDecalControls(selGroup, "Edge Blend 1", "edgeBlend1Offset", 1.1, "edgeBlend1Width", 1.0) end
            if selGroup.isEdgeBlend2 then edgeDecalControls(selGroup, "Edge Blend 2", "edgeBlend2Offset", 1.25, "edgeBlend2Width", 2.0) end
            if selGroup.isEdgeBlend3 then edgeDecalControls(selGroup, "Edge Blend 3", "edgeBlend3Offset", 1.35, "edgeBlend3Width", 3.0) end
          end

          -- Layers list.
          if selGroup and selGroup.isEnabled then
            im.Separator()
            im.TextColored(cols.greenB, "Layers:")
            local layers = selGroup.layers

            -- Get the selected layer and its index.
            local selectedLayer, _ = getSelectedLayer(selGroup)

            -- If no layer is selected or the selected layer doesn't exist, select the first non-hidden layer.
            if not selectedLayer then
              for i = 1, #layers do
                if not layers[i].isHidden then
                  selectedLayerId = layers[i].id
                  selectedLayer = layers[i]
                  break
                end
              end
            end

            im.PushItemWidth(-1)
            if im.BeginListBox('###5363', im.ImVec2(-1, 150)) then
              im.Columns(3, "layerListBoxColumns", true)
              im.SetColumnWidth(0, 32)
              im.SetColumnWidth(1, 180)
              im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(4, 2))
              im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
              local wCtr = 51322
              for i = 1, #layers do
                local layer = layers[i]

                -- Skip hidden layers
                if not layer.isHidden then
                  -- Display the material texture as a thumbnail.
                  local mat = scenetree.findObject(layer.material or "")
                  if mat then
                    local imgPath = mat:getField("diffuseMap", 0)
                    local absPath = imgPath
                    if absPath ~= "" then
                      absPath = (string.find(absPath, "/") ~= nil and absPath or (mat:getPath() .. absPath))
                    end
                    local texObj = materialSelectionMgr.getTexObj(absPath)
                    if texObj and texObj.tex then
                      im.Image(texObj.tex:getID(), iconsSmall)
                    else
                      im.Dummy(iconsSmall)
                    end
                  else
                    im.Dummy(iconsSmall)
                  end
                  im.SameLine()

                  -- Selectable row.
                  local flag = (layer.id == selectedLayerId)
                  if im.Selectable1("###" .. tostring(wCtr), flag, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
                    selectedLayerId = layer.id
                    materialSelectionMgr.closeWindow()
                  end
                  wCtr = wCtr + 1
                  im.NextColumn()

                  -- Layer name input field.
                  im.PushItemWidth(-1)
                  local layerNamePtr = im.ArrayChar(32, layer.name)
                  if not layer.isEnabled then
                    im.TextColored(cols.dullWhite, layer.name)
                    im.tooltip('This layer is disabled.')
                  else
                    -- Per-keystroke: only update the live label. The decal rebuild + undo commit are deferred to
                    -- IsItemDeactivatedAfterEdit, so renaming a layer rebuilds its decal once (on finish), not on every letter.
                    if im.InputText("###" .. tostring(wCtr), layerNamePtr, 32) then
                      layer.name = ffi.string(layerNamePtr)
                    end
                    im.tooltip('Edit the layer name.')
                    if im.IsItemActivated() then
                      sliderPreEditState = groupMgr.deepCopyGroup(selGroup) -- snapshot before the edit begins, for undo.
                    end
                    if im.IsItemDeactivatedAfterEdit() then
                      layer.name = ffi.string(layerNamePtr) -- final buffer value.
                      layerMgr.removeDecalRoadInLayer(layer)
                      layer.isDirty = true
                      editor.history:commitAction("Rename Layer", { old = sliderPreEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
                    end
                    if im.IsItemActive() then
                      selectedLayerId = layer.id
                      materialSelectionMgr.closeWindow()
                    end
                  end
                  im.PopItemWidth()
                  wCtr = wCtr + 1
                  im.NextColumn()

                  -- 'Remove Selected Layer' button.
                  local selLayer = getSelectedLayer(selGroup)
                  if not selLayer then
                    im.Dummy(iconsSmall)
                  else
                    if editor.uiIconImageButton(icons.trashBin2, iconsSmall, cols.blueB, nil, nil, 'removeLayerBtn' .. i) then
                      local oldState = groupMgr.deepCopyAllGroups()
                      layerMgr.removeLayer(i, selGroup)
                      selectedLayerId = nil
                      local newState = groupMgr.deepCopyAllGroups()
                      editor.history:commitAction("Remove Layer", { old = oldState, new = newState }, groupMgr.transGroupEditUndo, groupMgr.transGroupEditRedo, true)
                      editor.endWindow()
                      return
                    end
                    im.tooltip('Remove this layer from the Hero Road.')
                  end
                  im.SameLine()

                  -- 'Enable/Disable Layer' toggle button.
                  local eyeIcon = layer.isEnabled and icons.lock_open or icons.lock_outline
                  local iconCol = layer.isEnabled and cols.fullWhite or cols.dullWhite
                  if editor.uiIconImageButton(eyeIcon, iconsSmall, iconCol, nil, nil, "toggleVisibleBtn" .. i) then
                    layer.isEnabled = not layer.isEnabled
                    selGroup.isDirty = true
                  end
                  im.tooltip(layer.isEnabled and "Disable this layer (content will be removed from the Hero Road)" or "Enable this layer (content will be included in the Hero Road)")
                  im.NextColumn()

                  im.Separator()
                 end
               end
              im.PopStyleVar(2)
              im.EndListBox()
            end
            im.Separator()
          end

          -- Buttons underneath the layers list box.
          im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
          im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

          -- 'Add New Layer' button.
          if selGroup and selGroup.isEnabled then
            if editor.uiIconImageButton(icons.roadStackPlus, iconsBig, cols.blueB, nil, nil, 'addNewLayerBtn') then
              local statePre = groupMgr.deepCopyGroup(selGroup)
              layerMgr.addNewLayer(selGroup)
              -- Set selection to the newly created layer (it's at the end of the array)
              selectedLayerId = selGroup.layers[#selGroup.layers].id
              selGroup.isDirty = true
              editor.history:commitAction("Add New Layer", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.tooltip('Add a new layer to the selected Hero Road.')
          else
            im.Dummy(iconsBig)
          end
          im.SameLine()

          -- 'Duplicate Layer' button.
          local selectedLayer, selectedIndex = getSelectedLayer(selGroup)
          if selGroup and selGroup.isEnabled and selectedLayer and selectedLayer.isEnabled and not selectedLayer.isHidden then
            if editor.uiIconImageButton(icons.control_point_duplicate, iconsBig, cols.blueB, nil, nil, "duplicateLayerBtn") then
              local statePre = groupMgr.deepCopyGroup(selGroup)
              layerMgr.duplicateLayer(selectedIndex, selGroup)
              local statePost = groupMgr.deepCopyGroup(selGroup)
              editor.history:commitAction("Duplicate Layer", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
              selGroup.isDirty = true
            end
            im.tooltip("Duplicate the selected layer.")
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()

          -- 'Remove All Layers' button.
          if selGroup and #selGroup.layers > 0 and selGroup.isEnabled then
            if editor.uiIconImageButton(icons.trashBin2, iconsBig, cols.blueB, nil, nil, 'removeAlLayersBtn') then
              local oldState = groupMgr.deepCopyAllGroups()
              -- Only remove non-hidden layers (user-created layers)
              local i = 1
              while i <= #selGroup.layers do
                if not selGroup.layers[i].isHidden then
                  layerMgr.removeLayer(i, selGroup)
                else
                  i = i + 1
                end
              end
              selectedLayerId = nil
              -- Recreate auto-generated layers to ensure they're properly set up
              groupMgr.recreateAutoGeneratedLayers(selGroup)
              local newState = groupMgr.deepCopyAllGroups()
              editor.history:commitAction("Remove All Layers", { old = oldState, new = newState }, groupMgr.transGroupEditUndo, groupMgr.transGroupEditRedo, true)
            end
            im.tooltip('Remove all user-created layers from the selected Hero Road. Auto-generated layers will be preserved.')
          else
            im.Dummy(iconsBig)
          end
          im.PopStyleVar(2)
          im.Columns(1)

          -- Layer-specific UI (for the selected layer).
          selGroup = groupMgr.getGroups()[selectedGroupIdx]
          local selectedLayer, selectedIndex = getSelectedLayer(selGroup)
          if selGroup and selGroup.isEnabled and selectedLayer and selectedLayer.isEnabled and not selectedLayer.isHidden then
            im.Separator() -- divider above the layer-properties section (only when it actually renders, else it doubles with the tab's bottom separator)

            -- 'Select Material' panel.
            im.TextColored(cols.greenB, "Layer Material:")
            if editor.uiIconImageButton(icons.youtube_searched_for, iconsBig, cols.blueB, nil, nil, 'selectLayerMaterialBtn') then
              matSelectTarget = 'layer'
              materialSelectionMgr.openWindow()
            end
            im.tooltip('Select a new material for the selected layer.')
            im.SameLine()
            im.SetCursorPosY(im.GetCursorPosY() + max(0, (iconsBig.y - im.GetTextLineHeight()) * 0.5))
            im.Text('Material: [' .. (selectedLayer.material or 'Not Selected') .. ']')
            im.tooltip('The currently-selected material for this layer.')
            im.Columns(1)
            im.Dummy(im.ImVec2(0, 3))

            -- Layer-specific controls.
            im.Separator()
            im.TextColored(cols.greenB, "Layer Properties:")
            im.Dummy(im.ImVec2(0, 3))
            im.PushItemWidth(-1)
            im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
            im.Columns(3, "flipTrackCheckboxRow", false)

            -- 'Flip Laterally' checkbox.
            local tmpPtr2 = im.BoolPtr(selectedLayer.isFlip)
            if im.Checkbox("Flip Lateral", tmpPtr2) then
              local preState = groupMgr.deepCopyGroup(selGroup)
              selectedLayer.isFlip = tmpPtr2[0]
              selectedLayer.isDirty = true
              editor.history:commitAction("Flip Layer", { old = preState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.tooltip('Toggle whether this layer should be flipped left <--> right.')
            im.NextColumn()

            -- 'Track Width' checkbox.
            tmpPtr2 = im.BoolPtr(selectedLayer.isTrackWidth)
            if im.Checkbox("Track Width", tmpPtr2) then
              local preState = groupMgr.deepCopyGroup(selGroup)
              selectedLayer.isTrackWidth = tmpPtr2[0]
              selectedLayer.isDirty = true
              editor.history:commitAction("Change Track Width", { old = preState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.tooltip('Toggle whether this layer should track the width of the group spline (checked), or use its own fixed width (unchecked).')
            im.NextColumn()

            -- 'Edge' checkbox.
            tmpPtr2 = im.BoolPtr(selectedLayer.isEdge == true)
            if im.Checkbox("Edge", tmpPtr2) then
              local preState = groupMgr.deepCopyGroup(selGroup)
              selectedLayer.isEdge = tmpPtr2[0]
              if selectedLayer.isEdge then -- start where the layer already sits, so it doesn't jump.
                local halfW = ((selGroup.leftExtM or 0.0) + (selGroup.rightExtM or 0.0)) * 0.5
                selectedLayer.edgeSide = selectedLayer.position < 0 and 'left' or 'right'
                selectedLayer.edgeOffsetM = min(max((abs(selectedLayer.position) - 1.0) * halfW, edgeOffsetMinM), edgeOffsetMaxM)
              end
              selectedLayer.isDirty = true
              editor.history:commitAction("Change Layer Edge", { old = preState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.tooltip('Snap the layer to the road edge on one side. It follows lay-bys and junction flares, and its offset is measured from the edge.')
            im.NextColumn()

            im.Columns(1)
            im.Separator()
            im.PopStyleVar()
            im.PopItemWidth()

            -- Slider columns.
            im.PushItemWidth(-1)
            im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
            im.Columns(2, "layerSliderCols", false)
            im.SetColumnWidth(0, 30)

            -- 'Width' slider.
            if selectedLayer.width ~= sliderDefaults.defaultWidth then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetWidthBtn') then
                local preEditState = groupMgr.deepCopyGroup(selGroup)
                selectedLayer.width = sliderDefaults.defaultWidth
                selectedLayer.isDirty = true
                selGroup.isDirty = true
                editor.history:commitAction("Reset Width", { old = preEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            if not selectedLayer.isTrackWidth then
              im.PushItemWidth(-1)
              tmpPtr2 = im.FloatPtr(selectedLayer.width)
              if im.SliderFloat("###8130", tmpPtr2, 0.1, 30.0, "Width (m) = %.1f") then
                selectedLayer.width = tmpPtr2[0]
                selectedLayer.isDirty = true -- rebuild this one decal live each frame (updateOnlyDirtyLayers); group stays clean so no heavy mesh rebuild. Undo/commit still fires on release.
              end
              im.tooltip('Set the width of the layer.')
              if im.IsItemActivated() then
                sliderPreEditState = groupMgr.deepCopyGroup(selGroup)
              end
              if im.IsItemDeactivatedAfterEdit() then
                selectedLayer.isDirty = true
                selGroup.isDirty = true
                editor.history:commitAction("Adjust Width", { old = sliderPreEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
              end
              im.PopItemWidth()
            end
            im.NextColumn()

            if selectedLayer.isEdge then
              -- 'Edge Side' radios.
              im.Dummy(iconsSmall)
              im.NextColumn()
              local onLeft = selectedLayer.edgeSide == 'left'
              if im.RadioButton1('Left Edge###layerEdgeL', onLeft) and not onLeft then
                local preEditState = groupMgr.deepCopyGroup(selGroup)
                selectedLayer.edgeSide = 'left'
                selectedLayer.isDirty = true
                editor.history:commitAction("Change Layer Edge Side", { old = preEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
              end
              im.SameLine()
              if im.RadioButton1('Right Edge###layerEdgeR', not onLeft) and onLeft then
                local preEditState = groupMgr.deepCopyGroup(selGroup)
                selectedLayer.edgeSide = 'right'
                selectedLayer.isDirty = true
                editor.history:commitAction("Change Layer Edge Side", { old = preEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
              end
              im.tooltip('Which road edge the layer follows.')
              im.NextColumn()

              -- 'Edge Offset' slider.
              if abs(selectedLayer.edgeOffsetM or 0.0) > 1e-6 then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetEdgeOffBtn') then
                  local preEditState = groupMgr.deepCopyGroup(selGroup)
                  selectedLayer.edgeOffsetM = 0.0
                  selectedLayer.isDirty = true
                  editor.history:commitAction("Reset Edge Offset", { old = preEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr2 = im.FloatPtr(selectedLayer.edgeOffsetM or 0.0)
              if im.SliderFloat("###layerEdgeOff", tmpPtr2, edgeOffsetMinM, edgeOffsetMaxM, "Edge Offset (m) = %.2f") then
                selectedLayer.edgeOffsetM = tmpPtr2[0]
                selectedLayer.isDirty = true
              end
              im.tooltip('Distance of the layer centre from the road edge (negative = onto the road, positive = outward).')
              if im.IsItemActivated() then
                sliderPreEditState = groupMgr.deepCopyGroup(selGroup)
              end
              if im.IsItemDeactivatedAfterEdit() then
                selectedLayer.isDirty = true
                editor.history:commitAction("Adjust Edge Offset", { old = sliderPreEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()
            else
              -- 'Position' slider.
              if selectedLayer.position ~= sliderDefaults.defaultLateralPosition then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetPosBtn') then
                  local preEditState = groupMgr.deepCopyGroup(selGroup)
                  selectedLayer.position = sliderDefaults.defaultLateralPosition
                  selectedLayer.isDirty = true
                  selGroup.isDirty = true
                  editor.history:commitAction("Reset Position", { old = preEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr2 = im.FloatPtr(selectedLayer.position)
              if im.SliderFloat("###8131", tmpPtr2, latMin, latMax, "Lateral Position = %.2f") then
                selectedLayer.position = tmpPtr2[0]
                selectedLayer.isDirty = true
              end
              im.tooltip('Set the lateral position of the layer (-1.0 = left edge, 0.0 = center, 1.0 = right edge).')
              if im.IsItemActivated() then
                sliderPreEditState = groupMgr.deepCopyGroup(selGroup)
              end
              if im.IsItemDeactivatedAfterEdit() then
                selectedLayer.isDirty = true
                selGroup.isDirty = true
                editor.history:commitAction("Adjust Position", { old = sliderPreEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()
            end

            -- 'Texture Length' slider.
            if selectedLayer.texLen ~= sliderDefaults.defaultTexLength then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetTexLenBtn') then
                local preEditState = groupMgr.deepCopyGroup(selGroup)
                selectedLayer.texLen = sliderDefaults.defaultTexLength
                selectedLayer.isDirty = true
                selGroup.isDirty = true
                editor.history:commitAction("Reset Texture Length", { old = preEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            tmpPtr2 = im.FloatPtr(selectedLayer.texLen)
            if im.SliderFloat("###8132", tmpPtr2, 1.0, 200.0, "Tex Length (m) = %.1f") then
              selectedLayer.texLen = tmpPtr2[0]
              selectedLayer.isDirty = true
            end
            im.tooltip('Set the texture length of the layer.')
            if im.IsItemActivated() then
              sliderPreEditState = groupMgr.deepCopyGroup(selGroup)
            end
            if im.IsItemDeactivatedAfterEdit() then
              selectedLayer.isDirty = true
              selGroup.isDirty = true
              editor.history:commitAction("Adjust Tex Length", { old = sliderPreEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()

            -- 'Render Priority' slider.
            if selectedLayer.renderPriority ~= sliderDefaults.defaultRenderPriority then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetRenderPriorityBtn') then
                local preEditState = groupMgr.deepCopyGroup(selGroup)
                selectedLayer.renderPriority = sliderDefaults.defaultRenderPriority
                selectedLayer.isDirty = true
                selGroup.isDirty = true
                editor.history:commitAction("Reset Render Priority", { old = preEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            tmpPtr2 = im.IntPtr(selectedLayer.renderPriority)
            if im.SliderInt("###8133", tmpPtr2, 0, 100, "Render Priority = %d") then
              selectedLayer.renderPriority = tmpPtr2[0]
              selectedLayer.isDirty = true
            end
            im.tooltip('Set the render priority of the layer.')
            if im.IsItemActivated() then
              sliderPreEditState = groupMgr.deepCopyGroup(selGroup)
            end
            if im.IsItemDeactivatedAfterEdit() then
              selectedLayer.isDirty = true
              selGroup.isDirty = true
              editor.history:commitAction("Adjust Render Priority", { old = sliderPreEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()

            -- 'Fade In' slider.
            if selectedLayer.fadeIn ~= sliderDefaults.defaultFadeIn then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetFadeInBtn') then
                local preEditState = groupMgr.deepCopyGroup(selGroup)
                selectedLayer.fadeIn = sliderDefaults.defaultFadeIn
                selectedLayer.isDirty = true
                selGroup.isDirty = true
                editor.history:commitAction("Reset Fade In", { old = preEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            tmpPtr2 = im.FloatPtr(selectedLayer.fadeIn)
            if im.SliderFloat("###8134", tmpPtr2, fadeMin, fadeMax, "Fade In (m) = %.1f") then
              selectedLayer.fadeIn = tmpPtr2[0]
              selectedLayer.isDirty = true
            end
            im.tooltip('Set the fade in of the layer.')
            if im.IsItemActivated() then
              sliderPreEditState = groupMgr.deepCopyGroup(selGroup)
            end
            if im.IsItemDeactivatedAfterEdit() then
              selectedLayer.isDirty = true
              selGroup.isDirty = true
              editor.history:commitAction("Adjust Fade In", { old = sliderPreEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()


            -- 'Fade Out' slider.
            if selectedLayer.fadeOut ~= sliderDefaults.defaultFadeOut then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetFadeOutBtn') then
                local preEditState = groupMgr.deepCopyGroup(selGroup)
                selectedLayer.fadeOut = sliderDefaults.defaultFadeOut
                selectedLayer.isDirty = true
                selGroup.isDirty = true
                editor.history:commitAction("Reset Fade Out", { old = preEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            tmpPtr2 = im.FloatPtr(selectedLayer.fadeOut)
            if im.SliderFloat("###8135", tmpPtr2, fadeMin, fadeMax, "Fade Out (m) = %.1f") then
              selectedLayer.fadeOut = tmpPtr2[0]
              selectedLayer.isDirty = true
            end
            im.tooltip('Set the fade out of the layer.')
            if im.IsItemActivated() then
              sliderPreEditState = groupMgr.deepCopyGroup(selGroup)
            end
            if im.IsItemDeactivatedAfterEdit() then
              selectedLayer.isDirty = true
              selGroup.isDirty = true
              editor.history:commitAction("Adjust Fade Out", { old = sliderPreEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()

            -- Restore local slider spacing.
            im.PopStyleVar(1)
            im.PopItemWidth()
            im.Columns(1)
          else
            materialSelectionMgr.closeWindow() -- If no layer is selected, ensure the material selection window is closed.
          end
        elseif selectedTab == 4 then -- Furniture tab.
          -- Sidewalks: procedural kerb + slab kit (shared toolUtilities builder) riding the banked mesh edge, so it follows
          -- the road exactly (never floating). Terrain seals to the sidewalk's outer edge and the deck-side chamfer is dropped
          -- on that side. Left/right independent; the offset gaps the kerb out from the edge (a verge).
          im.TextColored(cols.greenB, "Sidewalks:")
          local swLPtr = im.BoolPtr(selGroup.sidewalkLeft == true)
          if im.Checkbox("Sidewalk L", swLPtr) then
            local statePre = groupMgr.deepCopyGroup(selGroup)
            selGroup.sidewalkLeft = swLPtr[0]
            selGroup.isDirty = true
            editor.history:commitAction("Toggle Sidewalk Left", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
          end
          im.tooltip('Build a kerb + slab sidewalk down the LEFT road edge. Follows the banking; the terrain seals to its outer edge.')
          im.SameLine()
          local swRPtr = im.BoolPtr(selGroup.sidewalkRight == true)
          if im.Checkbox("Sidewalk R", swRPtr) then
            local statePre = groupMgr.deepCopyGroup(selGroup)
            selGroup.sidewalkRight = swRPtr[0]
            selGroup.isDirty = true
            editor.history:commitAction("Toggle Sidewalk Right", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
          end
          im.tooltip('Build a kerb + slab sidewalk down the RIGHT road edge. Follows the banking; the terrain seals to its outer edge.')
          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.Columns(2, 'sidewalkCols', false)
          im.SetColumnWidth(0, 30)
          resetSlider(selGroup, "sidewalkOffsetM", 0.0, 0.0, 3.0, "Lateral Offset (m) = %.2f", "Gap from the mesh outer (deck/shoulder) edge to the kerb inner edge. 0 = flush against the road; larger = a grass verge between the road and the sidewalk.", "Adjust Sidewalk Offset", false)
          im.Columns(1)
          im.PopStyleVar()
          im.Dummy(im.ImVec2(0, 3))
          im.Separator()

          -- Barriers: instanced stock barrier assets stamped along the banked mesh edge (lean with the road, collide with cars).
          -- Pick a type per side; clicking the selected type again turns that side off. Shared lateral offset from the road edge.
          im.TextColored(cols.greenB, "Barriers:")
          im.Text("Left  ")
          im.SameLine()
          propTypeButton(selGroup, 'barrierLeftType', 'jersey', icons.concreteRoadBlock, 'Concrete / Jersey barrier down the LEFT edge.', 'Set Left Barrier')
          im.SameLine()
          propTypeButton(selGroup, 'barrierLeftType', 'plastic', icons.roadblockL, 'Plastic (alternating red/white) barrier down the LEFT edge.', 'Set Left Barrier')
          im.SameLine()
          propTypeButton(selGroup, 'barrierLeftType', 'guardrail', icons.roadGuideArrowSolid, 'Guardrail / crash barrier down the LEFT edge.', 'Set Left Barrier')
          im.Text("Right ")
          im.SameLine()
          propTypeButton(selGroup, 'barrierRightType', 'jersey', icons.concreteRoadBlock, 'Concrete / Jersey barrier down the RIGHT edge.', 'Set Right Barrier')
          im.SameLine()
          propTypeButton(selGroup, 'barrierRightType', 'plastic', icons.roadblockL, 'Plastic (alternating red/white) barrier down the RIGHT edge.', 'Set Right Barrier')
          im.SameLine()
          propTypeButton(selGroup, 'barrierRightType', 'guardrail', icons.roadGuideArrowSolid, 'Guardrail / crash barrier down the RIGHT edge.', 'Set Right Barrier')
          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.Columns(2, 'barrierCols', false)
          im.SetColumnWidth(0, 30)
          resetSlider(selGroup, "barrierOffsetM", 0.5, 0.0, 5.0, "Lateral Offset (m) = %.2f", "Gap from the mesh outer edge to the barrier line.", "Adjust Barrier Offset", false, nil, nil, nil, true)
          im.Columns(1)
          im.PopStyleVar()
          im.TextColored(cols.dullWhite, 'For barriers only on turns / specific spots, use the Features tab.')

          im.Dummy(im.ImVec2(0, 3))
          im.Separator()

          -- Fences: separate slot from barriers (own offset) so a side can carry a barrier AND a fence, like a bridge deck.
          im.TextColored(cols.greenB, "Fences:")
          im.Text("Left  ")
          im.SameLine()
          propTypeButton(selGroup, 'fenceLeftType', 'fence', icons.meshFence, 'Metal fence down the LEFT edge.', 'Set Left Fence')
          im.SameLine()
          propTypeButton(selGroup, 'fenceLeftType', 'chainlink', icons.mesh9Cells, 'Chainlink fence down the LEFT edge.', 'Set Left Fence')
          im.Text("Right ")
          im.SameLine()
          propTypeButton(selGroup, 'fenceRightType', 'fence', icons.meshFence, 'Metal fence down the RIGHT edge.', 'Set Right Fence')
          im.SameLine()
          propTypeButton(selGroup, 'fenceRightType', 'chainlink', icons.mesh9Cells, 'Chainlink fence down the RIGHT edge.', 'Set Right Fence')
          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.Columns(2, 'fenceCols', false)
          im.SetColumnWidth(0, 30)
          resetSlider(selGroup, "fenceOffsetM", 0.7, 0.0, 5.0, "Lateral Offset (m) = %.2f", "Gap from the mesh outer edge to the fence line (usually just outboard of the barrier).", "Adjust Fence Offset", false, nil, nil, nil, true)
          im.Columns(1)
          im.PopStyleVar()
          im.Dummy(im.ImVec2(0, 3))
          im.Separator()

          -- Lamp posts: instanced lamp assets spaced along the edge, always world-up (they don't bank with the road).
          im.TextColored(cols.greenB, "Lamp Posts:")
          im.Text("Left  ")
          im.SameLine()
          propTypeButton(selGroup, 'lampLeftType', 'lampMast', icons.lampPost2, 'Mast-arm lamp posts down the LEFT edge.', 'Set Left Lamp')
          im.SameLine()
          propTypeButton(selGroup, 'lampLeftType', 'lampVictorian', icons.lampPost3, 'Victorian lamp posts down the LEFT edge.', 'Set Left Lamp')
          im.SameLine()
          propTypeButton(selGroup, 'lampLeftType', 'lampStreet', icons.wb_sunny or icons.lampPost1, 'Modern single street lamp posts down the LEFT edge.', 'Set Left Lamp')
          im.SameLine()
          propTypeButton(selGroup, 'lampLeftType', 'lampHighway', icons.highlight or icons.lampPost1, 'Tall highway lamp posts down the LEFT edge.', 'Set Left Lamp')
          im.SameLine()
          propTypeButton(selGroup, 'lampLeftType', 'lampSidewalk', icons.wb_twilight or icons.lampPost1, 'Pedestrian sidewalk lamp posts down the LEFT edge.', 'Set Left Lamp')
          im.Text("Right ")
          im.SameLine()
          propTypeButton(selGroup, 'lampRightType', 'lampMast', icons.lampPost2, 'Mast-arm lamp posts down the RIGHT edge.', 'Set Right Lamp')
          im.SameLine()
          propTypeButton(selGroup, 'lampRightType', 'lampVictorian', icons.lampPost3, 'Victorian lamp posts down the RIGHT edge.', 'Set Right Lamp')
          im.SameLine()
          propTypeButton(selGroup, 'lampRightType', 'lampStreet', icons.wb_sunny or icons.lampPost1, 'Modern single street lamp posts down the RIGHT edge.', 'Set Right Lamp')
          im.SameLine()
          propTypeButton(selGroup, 'lampRightType', 'lampHighway', icons.highlight or icons.lampPost1, 'Tall highway lamp posts down the RIGHT edge.', 'Set Right Lamp')
          im.SameLine()
          propTypeButton(selGroup, 'lampRightType', 'lampSidewalk', icons.wb_twilight or icons.lampPost1, 'Pedestrian sidewalk lamp posts down the RIGHT edge.', 'Set Right Lamp')
          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.Columns(2, 'lampCols', false)
          im.SetColumnWidth(0, 30)
          resetSlider(selGroup, "lampOffsetM", 1.0, 0.0, 6.0, "Lateral Offset (m) = %.2f", "Gap from the mesh outer edge to the lamp-post line.", "Adjust Lamp Offset", false, nil, nil, nil, true)
          resetSlider(selGroup, "lampSpacingM", 25.0, 5.0, 100.0, "Spacing (m) = %.1f", "Target centre-to-centre spacing. A lamp is pinned at both ends and the rest are even-fit as close to this as possible.", "Adjust Lamp Spacing", false, nil, nil, nil, true)
          im.Columns(1)
          im.PopStyleVar()
        elseif selectedTab == 2 then -- Terrain tab.
          if selGroup and selGroup.isEnabled and #selGroup.nodes > 1 then
            -- Overlay: design-compliance heatmaps (grade / corner radius) + groundmodel paint. Lives here under Terrain since
            -- it's analysis/surface work; moved off the main window to free top space.
            overlayControl(selGroup)
            im.Separator()

            im.TextColored(cols.greenB, "Terraform To Road:")
            im.Dummy(im.ImVec2(0, 3))
            im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
            im.Columns(2, 'terraSliders', false)
            im.SetColumnWidth(0, 30)

            terraSlider('doi', 20.0, 0.0, 500.0, "DOI = %.1f", 'Domain Of Influence: how far out (m) from the road the terrain blends back to natural. Small = a tight seal, large = a broad feathered blend.')
            terraSlider('margin', 1.0, 1.0, 20.0, "Terraform Margin (m) = %.2f", 'Flat flush apron (m) held at the deck-edge height just outside the road, before the falloff starts (leave room for sidewalks/barriers).')
            terraSlider('falloff', 3.0, 1.0, 5.0, "Falloff = %.2f", 'Slope falloff exponent (1 = soft/gradual, 5 = sharp).')
            terraSlider('smooth', 2.0, 0.0, 2.0, "Smoothing = %.0f", 'Relaxation passes on the transition apron OUTSIDE the road (the road grade stays exact). 0 = raw feathered falloff; 2 = a smooth, even embankment. Above 2 just widens the feather, so it caps here.')

            im.Columns(1)
            im.PopStyleVar()
            im.Dummy(im.ImVec2(0, 3))

            -- 'Terraform To Road' button. Shapes the terrain up/down to meet the full road width (undo with Ctrl+Z).
            if editor.uiIconImageButton(icons.terrainToLine, iconsBig, cols.blueB, nil, nil, 'terraformToHeroRoadBtn') then
              terraformRoad(selGroup)
              selGroup.isDirty = true
            end
            im.tooltip('Terraform the terrain to meet the full width of this road. Undo with Ctrl+Z.')

            -- 'Restore Terrain' button.
            im.SameLine()
            local hasCarve = selGroup.terraBaseline and (selGroup.terraBaseline.n or 0) > 0
            if editor.uiIconImageButton(icons.settings_backup_restore, iconsBig, hasCarve and cols.blueB or cols.blueD, nil, nil, 'restoreTerrainFromHeroRoadBtn') and hasCarve then
              terra.restoreBaseline(selGroup, true) -- Road mesh is untouched (only terrain moves); recordHistory=true so this is Ctrl+Z-able.
            end
            im.tooltip('Restore the terrain this road carved back to how it was before terraforming (leaves the road in place). Undo with Ctrl+Z.')

            im.SameLine()
            local clipPtr = im.BoolPtr(terraClipEnds)
            if im.Checkbox('Clip Ends###hrTerraClipEnds', clipPtr) then terraClipEnds = clipPtr[0] end
            im.tooltip('Stop the terraform at the start and end of the road: the terrain in front of either end is left untouched.')
            im.Separator()

            -- Terrain paint: the painted material lives in the level terrain (not re-stored on load). Material + margin are
            -- PER-ROAD (bound to the selected road, like roadSpline) -- not a shared global, so switching roads and toggling
            -- paint always uses that road's own material. Toggle: while on, the paint follows the road as it's edited.
            im.TextColored(cols.greenB, "Terrain Paint:")
            im.Dummy(im.ImVec2(0, 3))
            local paintCh = false -- a slider moved this frame: live-repaint below if paint is currently applied.

            local pickedMat = matCombo.draw(selGroup.paintMaterialIdx or 0, {
              id = 'hrPaintMat', label = 'Material', default = 0,
              tooltip = 'Terrain layer painted under the road (full deck width plus the margin below).',
            })
            if pickedMat then selGroup.paintMaterialIdx = pickedMat paintCh = true end

            im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
            im.Columns(2, 'paintSliders', false)
            im.SetColumnWidth(0, 30)

            -- Paint Margin (m past the road edge).
            if (selGroup.paintMargin or paintMarginDefault) ~= paintMarginDefault then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'presetPaintMargin') then selGroup.paintMargin = paintMarginDefault paintCh = true end
              im.tooltip('Reset to default')
            else
              im.Dummy(im.ImVec2(iconsSmall.x + 4, iconsSmall.y))
            end
            im.SameLine() im.NextColumn()
            im.PushItemWidth(-1)
            local paintMarginPtr = im.FloatPtr(selGroup.paintMargin or paintMarginDefault)
            if im.SliderFloat('###hrPaintMargin', paintMarginPtr, 0.0, 20.0, "Paint Margin (m) = %.2f") then selGroup.paintMargin = paintMarginPtr[0] paintCh = true end
            im.tooltip('How far past the road edge to paint, so it covers the sidewalks/kerb and blends into the verge.')
            im.PopItemWidth()
            im.NextColumn()

            im.Columns(1)
            im.PopStyleVar()

            -- Live update: while painting, moving a slider re-rasterises immediately so the new material / margin shows. This is
            -- paint-only (revert + repaint the terrain cells) -- it does NOT dirty the group, so dragging a slider never rebuilds
            -- the road mesh. Geometry edits repaint via the group's dirty pass in updateDirtyGroups, exactly like roadSpline.
            if paintCh and selGroup.isPainting then
              terrainPaint.revert(selGroup)
              terrainPaint.paint(selGroup)
            end
            im.Dummy(im.ImVec2(0, 3))

            -- Paint toggle (like roadSpline): on = paint + keep following edits, off = restore the materials that were there.
            local painting = selGroup.isPainting == true
            if editor.uiIconImageButton(icons.terrain_painting, iconsBig, painting and cols.blueB or cols.blueD, nil, nil, 'paintHeroRoadBtn') then
              selGroup.isPainting = not painting
              selGroup.paintedDataVals = selGroup.paintedDataVals or {}
              if not selGroup.isPainting then terrainPaint.revert(selGroup) end
              selGroup.isDirty = true -- the dirty pass rebuilds the footprint and paints it (single source of truth).
            end
            im.tooltip('Switch terrain painting ' .. (painting and 'off' or 'on') .. '.')
          else
            im.TextColored(cols.redB, 'Add some nodes before terraforming.')
            im.Text('Create at least 2 nodes to enable terraforming.')
          end
        elseif selectedTab == 5 then -- Mesh tab.
          if #selGroup.nodes >= 2 then
            if selGroup.isMesh == false then
              -- Terrain road: no deck, so the resolution / LOD ladder / chunking settings don't apply. Bake below still finalises
              -- the road (it just persists paint + terraform + decals + furniture -- no .dae is written).
              im.TextColored(cols.dullWhite, 'Terrain road: no deck mesh.')
              im.TextWrapped('Resolution, LODs and chunking are deck-only. Bake below still finalises this road (paint, terraform, markings and furniture).')
              im.Dummy(im.ImVec2(0, 3))
              im.Separator()
            else
            local prev = meshMgr.lodPreview(selGroup) -- { lods = {size,tris,kept}, nullSize } (cached; re-assembled only on change).
            local lods = prev.lods
            local farNull = selGroup.lodFarNull ~= false

            -- RESOLUTION: the mesh you actually work on and drive.
            im.TextColored(cols.greenB, "Resolution:")
            exportSliderRow(selGroup, "latRes", 16, 1, 24, "Lateral Res = %d / side", "Lateral subdivisions per side across the carriageway. Higher = a smoother crown / denser base grid. Refine collapses coplanar columns back down, so flat crowns barely change; it shows on tight crowns/camber.", "Adjust Lateral Resolution", true, true)
            exportSliderRow(selGroup, "lonRes", 100, 6, 150, "Longitudinal Res = %d / seg", "Minimum subdivisions per spline segment along the road. Higher = denser lengthwise; Refine sheds the excess on straights (shows most on curves/crests).", "Adjust Longitudinal Resolution", true, true)
            exportSliderRow(selGroup, "lodQualityCm0", 1.0, 0.0, 15.0, "Refine = %.1f cm", "Max surface deviation of the drivable mesh. 0 = exact full res; ~1 cm sheds only dead-flat triangles. LOD0 inherits this -- keep it the TIGHTEST of the ladder.", "Adjust Refine", false, true)
            exportSliderRow(selGroup, "lodMaxSegM0", 20, 10, 60, "Max tri = %d m", "Caps how long a triangle in this mesh may get along the road, so a flat straight can't collapse to huge long-thin tris (bad for culling/lighting/collision).", "Adjust Max Tri", true, true)
            im.TextColored(cols.dullWhite, 'Original:'); im.SameLine()
            im.TextColored(cols.fullWhite, string.format('%d tris', selGroup.triCountRaw or 0)); im.SameLine()
            im.Dummy(im.ImVec2(10, 0)); im.SameLine()
            im.TextColored(cols.dullWhite, 'After refine:'); im.SameLine()
            im.TextColored(cols.fullWhite, string.format('%d tris', lods[1] and lods[1].tris or 0))
            im.tooltip('Original = full-res grid from the Lateral/Longitudinal resolution (before decimation), plus any pothole subdivision. After refine = what survives at the Refine tolerance -- the surface you drive, and what LOD0 inherits (potholes included).')
            local meshLenM = selGroup.meshVArc and selGroup.meshStationCount and selGroup.meshVArc[selGroup.meshStationCount]
            im.TextColored(cols.dullWhite, 'Road length:'); im.SameLine()
            im.TextColored(cols.fullWhite, string.format('%.0f m', meshLenM or selGroup.roadLength or 0)); im.SameLine()
            im.Dummy(im.ImVec2(10, 0)); im.SameLine()
            im.TextColored(cols.dullWhite, 'Max edge:'); im.SameLine()
            im.TextColored(cols.fullWhite, string.format('%.1f m', selGroup.lodMaxEdgeM or 0))
            im.tooltip('Longest triangle edge in this mesh (measured). Each LOD caps its longitudinal edges at its own Max tri length.')
            im.Separator()

            -- LODs: the baked detail ladder. The engine picks one per frame from the object's on-screen pixel size -- this is how
            -- every BeamNG prop/building DAE does LOD. LOD0 is the near level and INHERITS the working mesh above (no own refine --
            -- only a display size). LOD1+ each have their OWN refine Quality + Max tri + size; use progressively LARGER tolerances
            -- the further out the level is shown. The tri count shown for each is what remains AFTER that level's decimation.
            im.TextColored(cols.greenB, "LODs:")

            -- LOD0 (near): inherits the working mesh from Resolution above -- only its on-screen size threshold is a LOD param.
            if lods[1] then
              im.TextColored(cols.dullWhite, 'LOD 0 (near):'); im.SameLine()
              im.TextColored(cols.fullWhite, string.format('%d px   %d tris', lods[1].size, lods[1].tris)); im.SameLine()
              im.TextColored(cols.dullWhite, '(inherited)')
              im.tooltip("LOD0 IS the working/near mesh from Resolution above -- it inherits that geometry (its refine = the Resolution 'Refine' setting). Only its on-screen size threshold is set here.")
            end
            exportSliderRow(selGroup, "lodSize0", 400, 100, 1000, "LOD0 size = %d px", "On-screen pixel size at/above which the near mesh (LOD0) is drawn. Bigger = near level only very close up.", "Adjust LOD0 Size", true)
            im.Separator()

            -- LOD1 (mid). '(merged)' = so close to LOD0 the bake drops it as a redundant level.
            if lods[2] then
              im.TextColored(cols.dullWhite, 'LOD 1:'); im.SameLine()
              if lods[2].kept then
                im.TextColored(cols.fullWhite, string.format('%d px   %d tris', lods[2].size, lods[2].tris))
              else
                im.TextColored(cols.dullWhite, string.format('%d px   %d tris (merged)', lods[2].size, lods[2].tris))
              end
              im.tooltip('First coarser level (baked only). (merged) = so close to LOD0 the bake drops it as redundant -- raise its quality/lower its size to differentiate.')
            end
            exportSliderRow(selGroup, "lodSize1", 150, 40, 800, "LOD1 size = %d px", "Pixel size for the first coarser level (smaller = shown further away).", "Adjust LOD1 Size", true)
            exportSliderRow(selGroup, "lodQualityCm1", 3.0, 0.0, 30.0, "LOD1 quality = %.1f cm", "Surface deviation LOD1 may reach. Larger than LOD0 (it's shown further away, so more error is invisible) = lighter mesh.", "Adjust LOD1 Quality", false)
            exportSliderRow(selGroup, "lodMaxSegM1", 30, 10, 80, "LOD1 max tri = %d m", "Caps LOD1's triangle length along the road.", "Adjust LOD1 Max Tri", true)
            im.Separator()

            -- LOD2 / FAR slot: EITHER a third coarsest visible mesh, OR (no mesh) a 'nulldetail' level -> the road vanishes below
            -- its size (terrain + decals carry the look). The checkbox flips between the two; the size slider relabels to match.
            im.TextColored(cols.dullWhite, 'LOD 2 (far):'); im.SameLine()
            if farNull then
              im.TextColored(cols.fullWhite, 'no mesh (vanishes)')
            elseif lods[3] then
              if lods[3].kept then
                im.TextColored(cols.fullWhite, string.format('%d px   %d tris', lods[3].size, lods[3].tris))
              else
                im.TextColored(cols.dullWhite, string.format('%d px   %d tris (merged)', lods[3].size, lods[3].tris))
              end
            end
            local farPtr = im.BoolPtr(farNull)
            if im.Checkbox("no mesh (vanish at distance)", farPtr) then
              local statePre = groupMgr.deepCopyGroup(selGroup)
              selGroup.lodFarNull = farPtr[0]
              editor.history:commitAction("Toggle Far LOD Null", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.tooltip('On: past the far size the road draws nothing -- terrain + draped decals carry the look (cheapest, standard nulldetail LOD). Off: the far size becomes a third, coarsest visible LOD that draws forever.')
            if farNull then
              exportSliderRow(selGroup, "lodSize2", 40, 10, 400, "Vanish below = %d px", "Below this on-screen size the baked road renders nothing (the far LOD slot used as a 'nulldetail' level).", "Adjust Far Size", true)
            else
              exportSliderRow(selGroup, "lodSize2", 40, 10, 400, "LOD2 size = %d px", "Pixel size for the coarsest visible level; below it the road keeps drawing this level forever.", "Adjust LOD2 Size", true)
              exportSliderRow(selGroup, "lodQualityCm2", 8.0, 0.0, 40.0, "LOD2 quality = %.1f cm", "Surface deviation the coarsest visible level may reach. Largest of the ladder -- it's far away, so heavy decimation is invisible.", "Adjust LOD2 Quality", false)
              exportSliderRow(selGroup, "lodMaxSegM2", 45, 10, 120, "LOD2 max tri = %d m", "Caps LOD2's triangle length along the road.", "Adjust LOD2 Max Tri", true)
            end
            im.Separator()

            -- CHUNKING (the road is split into DAE pieces; the LOD ladder above applies to EVERY piece). Each piece stays under the
            -- engine's 2048 m local range; the split lands on shared station rings so neighbours meet crack-free. Purely an export
            -- setting -- it doesn't touch the live mesh (noDirty).
            im.TextColored(cols.greenB, "Chunking:")
            exportSliderRow(selGroup, "chunkLenM", 120, 50, 500, "Chunk length = %d m", "Length of each baked DAE piece. Smaller = more but lighter objects (better culling); larger = fewer, heavier ones (fewer draw calls). Splits on station boundaries so chunks meet crack-free.", "Adjust Chunk Length", true)
            -- Predict the chunk count from the SAME arc length the bake uses (the mesh centreline incl. its end extensions,
            -- stashed as meshVArc, computed as meshLenM up in the Resolution section), via mesh.chunkCount -- matches the bake exactly.
            local nChunks = meshMgr.chunkCount(meshLenM or selGroup.roadLength or 0, selGroup.chunkLenM or 120)
            im.TextColored(cols.dullWhite, 'Road length:'); im.SameLine()
            im.TextColored(cols.fullWhite, string.format('%.0f m', meshLenM or selGroup.roadLength or 0)); im.SameLine()
            im.Dummy(im.ImVec2(10, 0)); im.SameLine()
            im.TextColored(cols.dullWhite, 'Chunks:'); im.SameLine()
            im.TextColored(cols.fullWhite, tostring(nChunks))
            im.tooltip('How many DAE pieces this road will bake into at the current chunk length.')
            im.Separator()
            end -- end deck-only (Resolution / LODs / Chunking)

            -- Bake: write the current mesh (deck + chamfers, all material bands) to a .dae under the level's art/heroRoad
            -- folder so it ships with the map, then finalise it as a static baked object. A terrain road writes no .dae -- it just
            -- finalises (paint + terraform live in the terrain, markings + furniture flip to persistent).
            im.TextColored(cols.greenB, "Bake:")
            if editor.uiIconImageButton(icons.local_fire_department or icons.whatshot, iconsBig, cols.redB, nil, nil, 'bakeDaeBtn') then
              local statePre = groupMgr.deepCopyGroup(selGroup)
              local ok, info = exportMgr.bakeGroup(selGroup)
              if ok then
                log('I', 'heroRoadEditor', 'Baked hero road DAE -> ' .. tostring(info))
                editor.history:commitAction("Bake Hero Road", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
              else
                log('E', 'heroRoadEditor', 'Hero road bake failed: ' .. tostring(info))
              end
            end
            im.tooltip("Finalise this road so it ships with the level. Mesh road: bakes the deck (+ chamfers, all bands) to a .dae under art/heroRoad, then swaps in a static object. Terrain road: no .dae -- the paint + terraform already live in the terrain; this just flips markings + furniture (sidewalks/barriers/fences/lamps) to persistent. Either way editing locks -- re-enable it in the road list to edit again.")

            -- Export Spline Mask shares the Bake row as the tab's other file-output action. Session-scope: it writes the WHOLE
            -- session's footprint (every enabled road) to a .PNG mask, not just this road.
            im.SameLine()
            if editor.uiIconImageButton(icons.folder, iconsBig, cols.blueB, nil, nil, 'exportSplineMaskBtn') then
              local sources = util.getAllSources(groups)
              extensions.editor_fileDialog.saveFile(
                function(data)
                  maskExport.export(data.filepath, sources, 1.0) -- TODO: Uses a 1m margin. Maybe make this a parameter later.
                end,
                {{"PNG",".png"}},
                false,
                "/",
                "File already exists.\nDo you want to overwrite the file?")
            end
            im.tooltip('Export the whole session as a .PNG mask file (every enabled hero road, not just this one). Disabled roads are skipped.')
          else
            im.TextColored(cols.redB, 'Add some nodes before baking.')
            im.Text('Create at least 2 nodes to enable LOD baking.')
          end
        elseif selectedTab == 7 then -- Features tab: road-surface placeables (crossings + repairs + potholes + widenings).
          if selGroup.isMesh == false then
            -- Every feature here reshapes or carves the deck (potholes/laybys/junction flares) or ghost-places onto the deck's
            -- collision (crossings/repairs) -- none of which exist on a terrain road. Hidden rather than shown broken.
            im.TextColored(cols.redB, 'Not available on a terrain road.')
            im.TextWrapped('Surface features (potholes, laybys, junctions, crossings, repairs) need a road deck. Switch Mesh back on in the Shape tab to use them.')
          else
            placeablesUI.draw(selGroup, selectedGroupIdx)
          end
        end

        -- One bottom separator for every tab (individual tabs no longer draw their own trailing one, so this never doubles).
        im.Separator()
      end
      im.EndChild()
      im.PopStyleVar()
    end

    -- Always-on summary footer (outside the tab child), matching the other road tools.
    drawBottomStats(selGroup)
  end
  editor.endWindow()
end

-- Callback for when the user has selected a material. Routes to the layer decal, or the road-surface (mesh)
-- carriageway/shoulder material, depending on which picker was opened (matSelectTarget).
local function onSelectMaterial(objId)
  local groups = groupMgr.getGroups()
  local selGroup = groups[selectedGroupIdx]
  if not selGroup then return end

  -- Road-surface (mesh) and marking (decal) material picks route by target. Setting isDirty rebuilds the mesh and
  -- recreates the auto-generated marking layers, so a new centre/edge/lane material is picked up immediately.
  local matField = ({ carriageway = 'carriagewayMaterial', shoulder = 'shoulderMaterial',
    centerline = 'centerLineMaterial', edgeline = 'edgeLineMaterial', laneline = 'laneLineMaterial' })[matSelectTarget]
  if matField then
    local statePre = groupMgr.deepCopyGroup(selGroup)
    selGroup[matField] = objId
    selGroup.isDirty = true
    editor.history:commitAction("Select Surface Material", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
    return
  end

  local selectedLayer = getSelectedLayer(selGroup)
  if selectedLayer then
    local statePre = groupMgr.deepCopyGroup(selGroup)
    layerMgr.removeDecalRoadInLayer(selectedLayer)
    selectedLayer.material = objId
    selGroup.isDirty = true
    editor.history:commitAction("Select Layer Material", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
end

-- Callback for when the user has finished drawing a selection polygon.
local function onSelectionPolygonComplete(polygon)
  import.importFromPolygon(polygon)
  isDrawPolygon = false
end

-- Engineered per-corner in-viewport handles (radius knob + on-curve move grip) live in the shared toolUtilities/cornerHandles
-- module; this tool just drives it through a ctx (undo hooks + the fold-guardrail radius) and mirrors its move-grip test below.
local function cornerHandleCtx()
  return {
    selGroupIdx = selectedGroupIdx,
    selNodeIdx = selectedNodeIdx,
    setSelNode = function(i) selectedNodeIdx = i end,
    minRadius = profile.minSafeRadius,
    deepCopy = groupMgr.deepCopyGroup,
    undo = groupMgr.singleGroupEditUndo,
    redo = groupMgr.singleGroupEditRedo,
    ensureOverride = ensureCornerOverride,
  }
end

-- Main editor callback.
local function onEditorGui()
  siteLights.flush()
  -- Drag hide.
  local crossingDragging = isRoadSplineActive and roadPlaceables.isDragging()
  local cornerDragging = isRoadSplineActive and cornerHandles.isDragging()
  -- A held 'live' slider (Transition / Hill Smoothing, or a widening shaping slider in the Features tab) behaves like a node
  -- drag: the ribbon re-samples every frame, the mesh settles on release.
  local placeableLiveDrag = placeablesUI.consumeLiveDrag() -- always consume (reset) so a stale flag can't stick.
  local sliderDragging = isRoadSplineActive and (liveSliderDragging or placeableLiveDrag)
  liveSliderDragging = false
  local dragging = isRoadSplineActive and (input.isDragging() or crossingDragging or cornerDragging or sliderDragging)
  if dragging and not dragHideGroup then
    local gi = selectedGroupIdx
    if crossingDragging then
      local _, cgi = roadPlaceables.getSelection()
      if cgi then gi = cgi end
    elseif cornerDragging then
      gi = cornerHandles.draggingGroupIdx() or gi
    end
    local g = groupMgr.getGroups()[gi]
    if g then
      groupMgr.clearGroupVisuals(g)
      g.isDirty = true -- Mark dirty so the updateDirtyGroups pass right below rebuilds the ribbon edges THIS frame.
      dragHideGroup = g
    end
  elseif not dragging and dragHideGroup then
    dragHideGroup.isDirty = true -- rebuild once now that the node / crossing has settled.
    dragHideGroup = nil
  end

  -- Ensure all Hero Roads are updated, even if this tool is not active (dragging skips the heavy per-road rebuild).
  groupMgr.updateDirtyGroups(dragging)

  -- Apply any queued groundmodel physics rebuild (deferred off the paint strokes; fires once the paint mode is switched off).
  groundmodel.flushPending()

  -- If this tool is not active, render the shells of the splines but do nothing further.
  if not isRoadSplineActive then
    rSpline.renderShells(groupMgr.getGroups())
    return
  end

  -- Handle the main tool window UI.
  handleMainToolWindowUI()

  -- Drive the pan camera (RMB-drag pan + wheel zoom) when it's switched on. Suppress movement during the tool's own modal
  -- interactions (polygon drawing, node/gizmo drag, crossing placement/drag) so those don't fight the camera.
  if panCamera.isOn() then
    -- NB: don't block on isGizmoActive or groundmodel.isActive() -- those are persistent modes, not drags (the gizmo is a toggle;
    -- groundmodel paints on LMB while the pan is RMB, so they never fight). Actual drags are already covered by `dragging`.
    panCamera.drive(isDrawPolygon or dragging or roadPlaceables.isPlaceMode() or roadPlaceables.isDragging())
  end

  -- Handle the front end if the user is drawing a selection polygon.
  if isDrawPolygon then
    poly.handleUserPolygon(onSelectionPolygonComplete)
    return -- Don't do anything further if the user is drawing a selection polygon.
  end

  -- Handle the material selection UI. Shown for a road-surface pick (carriageway/shoulder) or a selected layer.
  local groups = groupMgr.getGroups()
  local selGroup = groups[selectedGroupIdx]
  -- Derive the selected layer AND its index fresh from selectedLayerId.
  local selectedLayer, selectedIndex = getSelectedLayer(selGroup)
  local isSurfacePick = matSelectTarget ~= 'layer' -- Any surface/marking pick (not a per-layer pick).
  if selGroup and (isSurfacePick or (#selGroup.layers > 0 and selectedLayer)) then
    materialSelectionMgr.handleMaterialSelectionSubWindow(false, onSelectMaterial)
  else
    materialSelectionMgr.closeWindow() -- Close the material selection window if there is nothing to apply to.
  end

  -- Render the ribbon quad-strip wire frame for all splines (like masterSpline / roadNetwork).
  rTransport.renderRibbonWireFrame(groups, selectedGroupIdx, 2, true)

  -- Overlay: design-compliance heatmap, or the groundmodel paint overlay (coloured painted cells + optional deck wireframe).
  if selGroup then
    if heatMetric == 'grade' or heatMetric == 'radius' then
      heatmap.compute(selGroup)
      heatmap.draw(selGroup, heatMetric)
    elseif heatMetric == 'groundmodel' then
      groundmodel.drawOverlay(selGroup)
    end
  end

  -- Engineered mode: draw the shared PI control-polygon overlay (blue guide-line + corner/clothoid markers) so it's clear the nodes
  -- are corner points the road ROUNDS -- the built centerline cuts inside each interior node instead of passing through it.
  if selGroup then engineeredGeom.drawControlPolygon(selGroup) end

  -- Render the spline nodes and layer visualisations with debugDraw.
  if selGroup then
    -- Hide the stray far PI node of any engineered corner that's showing an on-apex grip, so a tight bend reads as one handle.
    for k in pairs(hiddenGripNodes) do hiddenGripNodes[k] = nil end
    if selGroup.geometryMode == 'engineered' then
      for i = 2, #selGroup.nodes - 1 do
        if cornerHandles.moveHandle(selGroup, i) then hiddenGripNodes[i] = true end
      end
    end
    rSpline.handleSplineRendering(groups, selectedGroupIdx, selectedNodeIdx, isGizmoActive, false, isLockShape, true, false, elevScale, hiddenGripNodes)
    rTransport.drawNodeGhosts(selGroup, hiddenGripNodes)
    -- Selected-layer ribbon overlay: hidden when the mesh preview is off (there's no deck to sit on, and the user wants a clean ribbon-only view).
    if selectedLayer and selectedLayer.isEnabled and not selectedLayer.isHidden and selGroup.previewMesh ~= false then
      rSpline.renderLayer(selectedLayer, selGroup, true, 2)
    end
  end

  -- Placeables (pedestrian crossings + repair clusters) own the mouse before node editing so a click on a handle (or a
  -- click while in placement mode) never also drags a node.
  local crossingConsumed = false
  if groundmodel.isActive() and selGroup and selGroup.isMesh == false then
    groundmodel.setActive(false) -- terrain roads have no deck to paint; drop out of paint mode (e.g. mesh toggled off mid-paint).
  end
  if groundmodel.isActive() then
    groundmodel.updateAndPaint(selGroup) -- brush owns the mouse; skip placeables, corner handles and node editing below.
    crossingConsumed = true
  elseif roadPlaceables.isPlaceMode() then
    if im.IsKeyReleased(escapeKeyIdx) or im.IsMouseClicked(1) then
      roadPlaceables.setPlaceMode(false)
    else
      -- "Place once": drop a single crossing, then return to normal mode (not a persistent toggle).
      if roadPlaceables.handlePlacement(groups) then roadPlaceables.setPlaceMode(false) end
      crossingConsumed = true
    end
  else
    local hg, hc, hk = nil, nil, nil
    if not roadPlaceables.isDragging() then hg, hc, hk = roadPlaceables.underMouse() end
    roadPlaceables.drawHandles(groups, selGroup, roadPlaceables.hasSelection())
    roadPlaceables.drawHover(groups, hg, hc, hk)
    local mouseClicked = im.IsMouseClicked(0) and not editor.isAxisGizmoHovered()
    if mouseClicked and hg then
      roadPlaceables.clickHandle(groups, hg, hc, im.IsKeyDown(ctrlKeyIdx), hk)
      crossingConsumed = true
    end
    if roadPlaceables.isDragging() then
      crossingConsumed = roadPlaceables.handleSelectDrag(groups) or crossingConsumed
    end
  end

  -- Engineered per-node radius knobs.
  local suppressAddNode = false
  if not crossingConsumed and not input.isDragging() and selGroup and selGroup.geometryMode == 'engineered' then
    local consumed, hovering = cornerHandles.update(selGroup, cornerHandleCtx())
    if consumed then crossingConsumed = true elseif hovering then suppressAddNode = true end
  end

  if not crossingConsumed then
    -- Handle the mouse and keyboard events.
    out.spline, out.node, out.layer, out.isGizmoActive, out.isLockShape = selectedGroupIdx, selectedNodeIdx, selectedIndex or 1, isGizmoActive, isLockShape
    -- Free 3D nodes with the full translate/rotate gizmo.
    input.handleSplineEvents(
      groups,
      out,
      false, false, false, false, false, true, true, isLockShape,
      defaultSplineWidth,
      groupMgr.deepCopyGroup, groupMgr.deepCopyAllGroups,
      groupMgr.copyGroupProfile, groupMgr.pasteGroupProfile,
      groupMgr.recreateAutoGeneratedLayers,
      groupMgr.joinRoadSplines,
      groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo,
      groupMgr.transGroupEditUndo, groupMgr.transGroupEditRedo,
      nil, nil, nil, -- midJoinFunct / canJoinFunct / canJoinAuxFunct: not used here
      { preserveNodeZ = true, -- mouse drags a node on XY and keeps its height (edit Z with the gizmo / Drape To Terrain)
        suppressAddNode = suppressAddNode, -- hovering a corner handle: mute add/insert-node under it, but keep running the pass (gizmo stays).
        -- Draw the translate gizmo ON the ghost grip (bend apex) for any engineered corner whose PI is flung far off the road, so
        -- it grabs the handle you see instead of a gizmo tens of metres away. nil (normal nodes) = gizmo sits on the node as usual.
        gizmoAnchorFn = function(gi, ni)
          local g = groupMgr.getGroups()[gi]
          if not g or g.geometryMode ~= 'engineered' or ni <= 1 or ni >= #g.nodes then return nil end
          return cornerHandles.moveHandle(g, ni)
        end })
    selectedGroupIdx, selectedNodeIdx, selectedIndex, isGizmoActive, isLockShape = out.spline, out.node, out.layer, out.isGizmoActive, out.isLockShape

    -- Update selectedLayerId based on the returned index
    if selectedIndex and selGroup and selGroup.layers[selectedIndex] then
      selectedLayerId = selGroup.layers[selectedIndex].id
    end
  end
end

-- Called when the tool mode icon is pressed.
local function onActivate()
  isDrawPolygon = false
  poly.clearPolygon() -- Ensure there is no residual polygon left over from the previous usage.
  editor.clearObjectSelection()
  editor.showWindow(toolWindowName)
  materialSelectionMgr.closeWindow()
  roadPlaceables.reset() -- clear the shared controller's host registry + state from any previous tool session.
  roadPlaceables.setHost(crossingHost) -- register the Hero Road placeable kinds (crossings + repair clusters + potholes + widenings + junctions).
  roadPlaceables.setHost(repairHost)
  roadPlaceables.setHost(potholeHost)
  roadPlaceables.setHost(wideningHost)
  roadPlaceables.setHost(junctionHost)
  roadPlaceables.setHost(barrierHost)
  isRoadSplineActive = true

  -- Tell the pan camera how to frame the current selection (the selected hero road's driven centerline). Used when the pan
  -- camera is switched on / the tool opens. Start in the editor's normal free camera; the pan camera is opt-in via the toolbar.
  panCamera.configure({ focusProvider = function()
    local g = groupMgr.getGroups()[selectedGroupIdx]
    return g and g.divPoints
  end })

  -- Recompute the group id -> index map.
  util.computeIdToIdxMap(groupMgr.getGroups(), groupMgr.getIdToIdxMap()) -- Probably not needed here, but just in case.
end

-- Called when the tool is exited.
local function onDeactivate()
  isDrawPolygon = false
  poly.clearPolygon() -- Ensure there is no residual polygon left over from the previous usage.
  editor.hideWindow(toolWindowName)
  materialSelectionMgr.closeWindow()
  roadPlaceables.reset()
  panCamera.close() -- hand the editor's free camera back (no-op if we weren't driving it)
  isRoadSplineActive = false
end

-- Validates the selection for the scenetree right click menu.
local function validateSceneTreeRightClickMenuSelection(node)
  if node then
    local object = scenetree.findObjectById(node.id)
    if object then
      return object:getClassName() == "DecalRoad"
    end
  end
end

-- Called on scenetree right click menu, if validated.
local function processSceneTreeRightClickMenuSelection(node)
  if node then
    local decalRoads = {}
    local selection = editor.selection and editor.selection.object
    if selection then
      for _, objName in ipairs(editor.selection.object) do
        local obj = scenetree.findObject(objName)
        if obj:getClassName() == "DecalRoad" then
          table.insert(decalRoads, obj)
        end
      end
    end
    import.importSelectedIntoNewGroup(decalRoads)
  end
end

-- Editor initialization.
local function onEditorInitialized()
  editor.editModes.heroRoadEditor = {
    -- MUST equal groupMgr.getToolPrefixStr() ("Hero Road"): splineInput identifies a node's owning tool by matching
    -- bestHit.toolName (the tool prefix) against editor.editMode.displayName. A mismatch makes it treat this tool's own
    -- nodes as foreign and re-select the edit mode on every click (tearing the tool down/up, dropping the pan camera).
    displayName = "Hero Road",
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    icon = editor.icons.roadStack,
    iconTooltip = "Hero Road Editor",
    auxShortcuts = {},
    hideObjectIcons = true
  }
  editor.registerWindow(toolWindowName, toolWindowSize)
  materialSelectionMgr.registerWindow()

  -- Set up the scenetree right click menu for importing.
  editor.addExtendedSceneTreeObjectMenuItem({
    title = "Convert to Hero Road",
    extendedSceneTreeObjectMenuItems = processSceneTreeRightClickMenuSelection,
    validator = validateSceneTreeRightClickMenuSelection
  })
end

-- Called when leaving the map. We need to remove all groups and templates.
local function onClientEndMission()
  groupMgr.removeAllGroups()
  util.computeIdToIdxMap(groupMgr.getGroups(), groupMgr.getIdToIdxMap()) -- Recompute the group id -> index map.
end


-- Public interface.
M.setSelectedSplineIdx =                                setSelectedSplineIdx
M.setSelectedNodeIdx =                                  setSelectedNodeIdx

M.onSerialize =                                         onSerialize
M.onDeserialized =                                      onDeserialized

M.onEditorGui =                                         onEditorGui
M.onEditorInitialized =                                 onEditorInitialized
M.onClientEndMission =                                  onClientEndMission

return M