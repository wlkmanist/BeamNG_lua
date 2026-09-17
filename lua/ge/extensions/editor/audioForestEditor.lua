-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local nodeVisViewRadiusDefault = 1000.0 -- meters
local nodeVisSphereRadiusDefault = 1.5 -- meters
local thinningOuterRadiusMul = 1.5 -- outer frontier radius = mul * density

local defaultGroupEventName = 'event:>Ambient>Ambiences>Forest_Static'
local defaultRoomtoneEventName = 'event:>Ambient>Ambiences>Roomtone'

-- Hard-coded knobs.
local worldGraphMinNodeSpacing = 20.0 -- density (m)
local nodeHeightBlend = 0.50 -- 0=ground, 1=tree top
local classT0 = 1 / 3 -- S/M threshold
local classT1 = 2 / 3 -- M/L threshold
local volumeClassPercentile = 0.95 -- bbox-volume normalization for default S/M/L classing

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- External modules.
local ffi = require('ffi')
local render = require('editor/toolUtilities/render')
local style = require('editor/toolUtilities/style')
local audioForest = require('core/audioForest')
local audioForestCommon = require('core/audioForest/audioForestCommon')

-- Module constants.
local min, max, floor = math.min, math.max, math.floor
local im = ui_imgui
local toolWinName, toolWinSize = 'audioForestEditor', im.ImVec2(520, 820)
local cols = style.getImguiCols('crystal')
local iconsSmall = im.ImVec2(24, 24)
local colorWhite = ColorF(1, 1, 1, 1)
local forestSelectableFlags = im.flags(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)
local debugCentroidRadius = 0.7
local debugCentroidCol = ColorF(0.95, 0.2, 0.95, 0.55)
local debugCentroidZ = 0.4

-- Module state.
local isAudioForestEditor = false
local worldGraph = nil
local showNodeVisPtr = im.BoolPtr(true)
local nodeVisDrawRadiusPtr = im.FloatPtr(nodeVisViewRadiusDefault)
local nodeVisSphereRadiusPtr = im.FloatPtr(nodeVisSphereRadiusDefault)
local forestTypeShapes = {}        -- [row] = shapeFile (string, may be '')
local forestTypeBaseName = {}      -- [row] = base file name for display
local forestTypeInstanceCount = {} -- [row] = number of instances in the level using that shape
local forestTypeInstanceCountStr = {} -- [row] = 'xN' preformatted
local forestTypeSelectableId = {}     -- [row] = selectable widget id (stable)
local forestTypeCheckboxId = {}       -- [row] = checkbox widget id (stable)
local forestTypeShapeDisplay = {}     -- [row] = shape or '<no shape>'
local forestTypeTooltipStr = {}       -- [row] = tooltip string (cached)
local forestShapeVolume = {}       -- shapeFile -> bbox volume estimate (cached per refresh)
local forestTypeVolume = {}        -- [row] = bbox volume estimate
local forestTypeVolumeStr = {}     -- [row] = preformatted volume string
local forestTypeClassDefault = {}  -- [row] = 1..3 (S/M/L) computed from bbox volume
local forestTypeClassSel = {}      -- [row] = 1..3 (S/M/L) current selection (default or overridden)
local forestTypeClassDefaultByShape = {} -- shapeFile -> 1..3
local forestTypeClassSelByShape = {}     -- shapeFile -> 1..3
local forestTypeClassOverrideByShape = {} -- shapeFile -> bool (true = user override)
local forestTypeRowCount = 0       -- number of unique types
local forestTotalInstanceCount = 0 -- total instances in level (all types)
local forestIncludePtrByShape = {} -- shapeFile (string) -> BoolPtr (true = included)
local forestShapeToRow = {}        -- shapeFile -> row
local forestShapeCounts = {}       -- shapeFile -> count (also used for hover markup)
local isForestListDirty = true
local selectedForestTypeRow = 1
local scrollToForestTypeRow = nil
local forestListForceUnclippedFrames = 0
local forestClipper = im.ImGuiListClipper()
local forestIncludedTypeCount = 0 -- Cached UI totals strings (avoid per-frame string.format/concat).
local forestIncludedInstanceCount = 0
local forestTotalsStr = "0 / 0"
local forestTypesHintStr = ""
local forestRayRange = 10000
local hoveredForestBBList = { nil } -- reused; avoids allocating {forestItem} each frame.
local hoveredForestPos = vec3()
local hoverLabelShape = nil
local hoverLabelExcluded = nil
local hoverLabelCount = nil
local hoverLabelStr = nil
local tmpH = vec3()
local centroidDebugPos = vec3()
local emitterNodeIds, emitterNodeIdCount = nil, 0
local mainEventEditPtr = im.ArrayChar(128, defaultGroupEventName)
local mainEventStr = defaultGroupEventName
local roomtoneEnabledPtr = im.BoolPtr(false)
local roomtoneEventEditPtr = im.ArrayChar(128, defaultRoomtoneEventName)
local roomtoneEventStr = defaultRoomtoneEventName
local roomtoneZPtr = im.FloatPtr(0.0)
local pendingDeserializedState = nil
local classCols = {
  color(255, 0, 0, 255),
  color(0, 255, 0, 255),
  color(0, 0, 255, 255) } -- S/M/L node colours.
local classColsU32 = {
  im.GetColorU322(im.ImVec4(1, 0, 0, 1)),
  im.GetColorU322(im.ImVec4(0, 1, 0, 1)),
  im.GetColorU322(im.ImVec4(0, 0, 1, 1)) }
local classColsU32Dim = {
  im.GetColorU322(im.ImVec4(1, 0, 0, 0.25)),
  im.GetColorU322(im.ImVec4(0, 1, 0, 0.25)),
  im.GetColorU322(im.ImVec4(0, 0, 1, 0.25)) }

-- Serializes editor state for runtime and level persistence.
local function onSerialize()
  local includeByShape = {}
  for shape, ptr in pairs(forestIncludePtrByShape) do
    includeByShape[shape] = (ptr and ptr[0]) and true or false
  end
  local classSelByShape = {}
  for shape, cls in pairs(forestTypeClassSelByShape) do
    classSelByShape[shape] = cls
  end
  local classOverrideByShape = {}
  for shape, v in pairs(forestTypeClassOverrideByShape) do
    classOverrideByShape[shape] = v and true or false
  end

  return {
    version = 1,
    nodeVisDrawRadius = nodeVisDrawRadiusPtr[0],
    nodeVisSphereRadius = nodeVisSphereRadiusPtr[0],
    showNodes = showNodeVisPtr[0],
    mainEvent = mainEventStr,
    roomtoneEnabled = roomtoneEnabledPtr[0],
    roomtoneEvent = roomtoneEventStr,
    roomtoneZ = roomtoneZPtr[0],
    selectedRow = selectedForestTypeRow,
    includeByShape = includeByShape,
    classSelByShape = classSelByShape,
    classOverrideByShape = classOverrideByShape,
  }
end

-- Pushes the current graph and main event into the runtime.
local function syncAudioForestRuntime(nodeCloud)
  audioForest.setEnabled(false)
  audioForest.clearMainAudio()
  audioForest.setNodeCloud(nil)
  emitterNodeIds, emitterNodeIdCount = nil, 0

  if not nodeCloud or not nodeCloud.nodeCount then
    return
  end

  if not audioForest.setNodeCloud(nodeCloud) then
    return
  end
  audioForest.setMainEvent(mainEventStr)
  audioForest.setEnabled(mainEventStr ~= '')

  if mainEventStr ~= '' then
    emitterNodeIds, emitterNodeIdCount = audioForest.getEmitterNodeIds()
  end
end

-- Stores the current editor state in the runtime module.
local function pushToolStateToRuntime()
  audioForest.setPersistedToolState(onSerialize())
end

-- Extracts a compact display name from a forest shape path.
local function getForestTypeBaseName(shape)
  local baseName = (shape ~= '' and shape:match("([^/]+)$")) or ''
  if baseName == '' then
    baseName = '<no shape>'
  end
  return baseName
end

local function getForestObject()
  local forestCore = rawget(_G, 'core_forest')
  return forestCore and forestCore.getForestObject and forestCore.getForestObject() or nil
end

-- Refreshes cached forest include summary strings.
local function refreshForestSummaryStrings()
  forestTotalsStr = tostring(forestIncludedInstanceCount) .. " / " .. tostring(forestTotalInstanceCount)
  forestTypesHintStr =
    "Types: " .. tostring(forestIncludedTypeCount) .. " / " .. tostring(forestTypeRowCount) ..
    ". Hover + click in viewport selects a type."
end

-- Recomputes included type and instance counters.
local function recomputeForestIncludeCounts()
  forestIncludedTypeCount = 0
  forestIncludedInstanceCount = 0
  for row = 1, forestTypeRowCount do
    local shape = forestTypeShapes[row]
    local ptr = forestIncludePtrByShape[shape]
    if (ptr == nil) or ptr[0] then
      forestIncludedTypeCount = forestIncludedTypeCount + 1
      forestIncludedInstanceCount = forestIncludedInstanceCount + (forestTypeInstanceCount[row] or 0)
    end
  end
  refreshForestSummaryStrings()
end

-- Rebuilds forest type rows and default class selections.
local function refreshForestTypeList()
  forestTypeRowCount = 0
  forestTotalInstanceCount = 0
  table.clear(forestTypeShapes)
  table.clear(forestTypeBaseName)
  table.clear(forestTypeInstanceCount)
  table.clear(forestTypeInstanceCountStr)
  table.clear(forestTypeSelectableId)
  table.clear(forestTypeCheckboxId)
  table.clear(forestTypeShapeDisplay)
  table.clear(forestTypeTooltipStr)
  table.clear(forestShapeVolume)
  table.clear(forestTypeVolume)
  table.clear(forestTypeVolumeStr)
  table.clear(forestTypeClassDefault)
  table.clear(forestTypeClassSel)
  table.clear(forestShapeToRow)
  table.clear(forestShapeCounts)

  local forestObj = getForestObject()
  local data = forestObj and forestObj.getData and forestObj:getData() or nil
  local all = data and data.getItems and data:getItems() or nil
  if not all then
    selectedForestTypeRow = 1
    recomputeForestIncludeCounts()
    isForestListDirty = false
    pendingDeserializedState = nil
    return
  end
  local count = #all

  local unique = {}
  local uniqueCount = 0

  -- Count instances by shape, and gather unique shape list.
  for i = 1, count do
    local item = all[i]
    local shape = item:getData():getShapeFile()
    forestTotalInstanceCount = forestTotalInstanceCount + 1
    forestShapeCounts[shape] = (forestShapeCounts[shape] or 0) + 1

    if forestShapeVolume[shape] == nil then
      forestShapeVolume[shape] = audioForestCommon.getItemVolume(item)
    end

    if not forestShapeToRow[shape] then
      uniqueCount = uniqueCount + 1
      unique[uniqueCount] = shape
      forestShapeToRow[shape] = -1 -- mark as seen; final row mapping filled after sort
    end
  end

  table.sort(unique, function(a, b)
    local an = getForestTypeBaseName(a)
    local bn = getForestTypeBaseName(b)
    if an == bn then
      return a < b
    end
    return an < bn
  end)

  -- Fill row arrays.
  for row = 1, uniqueCount do
    local shape = unique[row]
    forestTypeShapes[row] = shape
    forestTypeBaseName[row] = getForestTypeBaseName(shape)
    local instCount = forestShapeCounts[shape] or 0
    forestTypeInstanceCount[row] = instCount
    forestTypeInstanceCountStr[row] = "x" .. tostring(instCount)
    local vol = forestShapeVolume[shape] or 0.0
    forestTypeVolume[row] = vol
    forestTypeVolumeStr[row] = string.format('%.2f', vol)
    forestShapeToRow[shape] = row
    forestTypeRowCount = row
    local includeOverride = nil
    if pendingDeserializedState and pendingDeserializedState.includeByShape then
      includeOverride = pendingDeserializedState.includeByShape[shape]
    end
    local ptr = forestIncludePtrByShape[shape]
    if ptr == nil then
      -- Default to included (users typically want to start with "everything on").
      ptr = im.BoolPtr(true)
      forestIncludePtrByShape[shape] = ptr
    end
    if includeOverride ~= nil then
      ptr[0] = includeOverride and true or false
    end

    forestTypeSelectableId[row] = "###forestTypeRow_" .. tostring(row)
    forestTypeCheckboxId[row] = "##forestTypeInclude_" .. shape
    local disp = (shape ~= '' and shape or '<no shape>')
    forestTypeShapeDisplay[row] = disp
    forestTypeTooltipStr[row] =
      "Shape: " .. disp ..
      "\nInstances: " .. tostring(instCount) ..
      "\nBBox volume: " .. (forestTypeVolumeStr[row] or "")
  end

  -- Compute default S/M/L class from bbox volumes (1/3 and 2/3 cut points on normalized volume).
  local vols = {}
  for row = 1, forestTypeRowCount do
    vols[row] = forestTypeVolume[row] or 0.0
  end
  table.sort(vols)
  local p95 = 0.0
  if forestTypeRowCount > 0 then
    local idx = floor((forestTypeRowCount - 1) * volumeClassPercentile) + 1
    p95 = vols[idx] or 0.0
  end
  local inv = p95 > 0.0 and (1.0 / p95) or 0.0

  local t0 = classT0
  local t1 = classT1
  if t0 > t1 then t0, t1 = t1, t0 end

  for row = 1, forestTypeRowCount do
    local shape = forestTypeShapes[row]
    local n = (forestTypeVolume[row] or 0.0) * inv
    if n < 0.0 then n = 0.0 elseif n > 1.0 then n = 1.0 end
    local def = audioForestCommon.computeDefaultClassFromNormVol(n, t0, t1)
    forestTypeClassDefault[row] = def
    forestTypeClassDefaultByShape[shape] = def
    if pendingDeserializedState then
      local pSel = pendingDeserializedState.classSelByShape and pendingDeserializedState.classSelByShape[shape]
      local pOvr = pendingDeserializedState.classOverrideByShape and pendingDeserializedState.classOverrideByShape[shape]
      if pSel ~= nil then
        forestTypeClassSelByShape[shape] = pSel
      end
      if pOvr ~= nil then
        forestTypeClassOverrideByShape[shape] = pOvr and true or false
      end
    end
    local sel = forestTypeClassSelByShape[shape]
    local isOverride = forestTypeClassOverrideByShape[shape]
    if (not isOverride) or sel == nil then
      sel = def
      forestTypeClassSelByShape[shape] = def
      forestTypeClassOverrideByShape[shape] = false
    end
    forestTypeClassSel[row] = sel
  end

  selectedForestTypeRow = max(1, min(forestTypeRowCount, selectedForestTypeRow))
  recomputeForestIncludeCounts()
  isForestListDirty = false
  pendingDeserializedState = nil
end

-- Sets all forest type include toggles at once.
local function setAllForestTypeIncludes(v)
  for row = 1, forestTypeRowCount do
    local shape = forestTypeShapes[row]
    forestIncludePtrByShape[shape][0] = v
  end
  if v then
    forestIncludedTypeCount = forestTypeRowCount
    forestIncludedInstanceCount = forestTotalInstanceCount
  else
    forestIncludedTypeCount = 0
    forestIncludedInstanceCount = 0
  end
  refreshForestSummaryStrings()
end

local classIncSPtr = im.BoolPtr(true)
local classIncMPtr = im.BoolPtr(true)
local classIncLPtr = im.BoolPtr(true)

-- Refreshes bulk class include checkbox state.
local function refreshClassIncludeState()
  local totalS, totalM, totalL = 0, 0, 0
  local incS, incM, incL = 0, 0, 0
  for row = 1, forestTypeRowCount do
    local shape = forestTypeShapes[row]
    local def = forestTypeClassDefaultByShape[shape] or 2
    local cls = forestTypeClassSelByShape[shape] or def
    local ptr = forestIncludePtrByShape[shape]
    local on = ptr and ptr[0]
    if cls == 1 then
      totalS = totalS + 1
      if on then incS = incS + 1 end
    elseif cls == 2 then
      totalM = totalM + 1
      if on then incM = incM + 1 end
    else
      totalL = totalL + 1
      if on then incL = incL + 1 end
    end
  end
  classIncSPtr[0] = totalS > 0 and incS == totalS
  classIncMPtr[0] = totalM > 0 and incM == totalM
  classIncLPtr[0] = totalL > 0 and incL == totalL
end

-- Applies one include value to all rows in a class.
local function applyIncludeForClass(cls, v)
  for row = 1, forestTypeRowCount do
    local shape = forestTypeShapes[row]
    local def = forestTypeClassDefaultByShape[shape] or 2
    local c = forestTypeClassSelByShape[shape] or def
    if c == cls then
      local ptr = forestIncludePtrByShape[shape]
      if ptr then
        ptr[0] = v
      end
    end
  end
end

-- Builds the editor preview cloud through the shared graph module.
local function buildForestNodeCloud()
  local forestObj = getForestObject()
  local nodeCloud = audioForestCommon.buildNodeCloudFromForest(forestObj, onSerialize(), {
    minNodeSpacing = worldGraphMinNodeSpacing,
    thinningOuterRadiusMul = thinningOuterRadiusMul,
    nodeHeightBlend = nodeHeightBlend,
    classT0 = classT0,
    classT1 = classT1,
    volumeClassPercentile = volumeClassPercentile,
  }, {
    includeEditorFields = true,
    shapeToRow = forestShapeToRow,
  })
  nodeCloud.defaultNodeCol = color(255, 0, 0, 255)
  nodeCloud.sphereRadius = nodeVisSphereRadiusPtr[0]
  nodeCloud.nodeGroupId = nil
  nodeCloud.groupCols = nil
  return nodeCloud
end

-- Rebuilds the editor cloud and resyncs runtime state.
local function rebuildForestNodeCloud()
  if isForestListDirty then
    refreshForestTypeList()
  end
  worldGraph = buildForestNodeCloud()
  if worldGraph then
    worldGraph.sphereRadius = nodeVisSphereRadiusPtr[0]
    if worldGraph.nodeClassId then
      worldGraph.nodeGroupId = worldGraph.nodeClassId
      worldGraph.groupCols = classCols
    end
  end
  syncAudioForestRuntime(worldGraph)
  pushToolStateToRuntime()
end

-- Updates viewport hover selection for forest items.
local function updateForestHoverPicking()
  if im.GetIO().WantCaptureMouse then
    return
  end
  if not editor.isViewportHovered() or editor.isAxisGizmoHovered() then
    return
  end

  local forest = getForestObject()
  if not forest then
    return
  end
  local cam = getCameraMouseRay()
  if not cam then
    return
  end
  local hit = forest:castRayRendered(cam.pos, cam.pos + cam.dir * forestRayRange)
  local forestItem = hit and hit.forestItem or nil
  if not forestItem then
    return
  end

  hoveredForestBBList[1] = forestItem
  worldEditorCppApi.renderForestBBs(hoveredForestBBList, colorWhite)

  local shape = forestItem:getData():getShapeFile()
  local row = forestShapeToRow[shape]
  local baseName = (row and forestTypeBaseName[row]) or getForestTypeBaseName(shape)
  local hoveredForestTypeCount = forestShapeCounts[shape] or 0
  local incPtr = forestIncludePtrByShape[shape]
  local hoveredForestIsExcluded = incPtr and (not incPtr[0]) or false
  hoveredForestPos:set(forestItem:getPosition())

  if (shape ~= hoverLabelShape) or (hoveredForestIsExcluded ~= hoverLabelExcluded) or (hoveredForestTypeCount ~= hoverLabelCount) then
    hoverLabelShape = shape
    hoverLabelExcluded = hoveredForestIsExcluded
    hoverLabelCount = hoveredForestTypeCount
    hoverLabelStr = string.format('Forest: %s (%s)%s', baseName, "x" .. tostring(hoveredForestTypeCount), hoveredForestIsExcluded and ' [EXCLUDED]' or '')
  end

  tmpH:set(hoveredForestPos.x, hoveredForestPos.y, hoveredForestPos.z + 2.0)
  if render.markupSplineName then
    render.markupSplineName(tmpH, hoverLabelStr)
  end

  if im.IsMouseClicked(0) then
    if isForestListDirty then
      refreshForestTypeList()
    end
    row = forestShapeToRow[shape]
    if row then
      selectedForestTypeRow = row
      scrollToForestTypeRow = row
      forestListForceUnclippedFrames = 2 -- ensure row exists for SetScrollHereY centering
    end
  end
end

-- Renders graph visualization controls.
local function renderWorldGraphControls(icons)
  im.TextColored(cols.greenB, "World Forest Graph:")
  im.Separator()

  -- View radius.
  im.Columns(2, "viewRadiusRow", false)
  im.SetColumnWidth(0, 30)
  if nodeVisDrawRadiusPtr[0] ~= nodeVisViewRadiusDefault then
    if editor.uiIconImageButton(icons.star_border, iconsSmall, cols.blueB, nil, nil, 'resetViewRadiusBtn') then
      nodeVisDrawRadiusPtr[0] = nodeVisViewRadiusDefault
    end
    im.tooltip("Reset to default")
  else
    im.Dummy(iconsSmall)
  end
  im.NextColumn()
  im.PushItemWidth(-1)
  im.SliderFloat("###viewRadius", nodeVisDrawRadiusPtr, 10.0, 2000.0, "View Radius (m) = %.0f")
  im.tooltip("Only draws node spheres within this distance from the camera.")
  im.PopItemWidth()
  im.Columns(1)

  -- Sphere radius.
  im.Columns(2, "sphereRadiusRow", false)
  im.SetColumnWidth(0, 30)
  if nodeVisSphereRadiusPtr[0] ~= nodeVisSphereRadiusDefault then
    if editor.uiIconImageButton(icons.star_border, iconsSmall, cols.blueB, nil, nil, 'resetSphereRadiusBtn') then
      nodeVisSphereRadiusPtr[0] = nodeVisSphereRadiusDefault
      if worldGraph then worldGraph.sphereRadius = nodeVisSphereRadiusPtr[0] end
    end
    im.tooltip("Reset to default")
  else
    im.Dummy(iconsSmall)
  end
  im.NextColumn()
  im.PushItemWidth(-1)
  im.SliderFloat("###sphereRadius", nodeVisSphereRadiusPtr, 0.5, 4.0, "Sphere Radius (m) = %.2f")
  im.tooltip("Controls the size of the node spheres.")
  im.PopItemWidth()
  im.Columns(1)

  im.Checkbox("Show Nodes###showNodeVis", showNodeVisPtr)
  im.tooltip("Toggle drawing of the node spheres in the world.")

  im.TextColored(cols.dullWhite, "Emitters per class event = 1 (centroid)")
end

-- Draws one S/M/L color swatch.
local function drawClassSwatchU32(colU32)
  local dl = im.GetWindowDrawList()
  local p = im.GetCursorScreenPos()
  local s = im.GetFrameHeight()
  local pad = 3
  im.ImDrawList_AddRectFilled(dl, im.ImVec2(p.x + pad, p.y + pad), im.ImVec2(p.x + s - pad, p.y + s - pad), colU32)
  im.Dummy(im.ImVec2(s, s))
end

-- Draws one class override radio button.
local function drawClassRadioButton(label, cls, sel, def, shape, row)
  if cls == def then
    im.PushStyleColor2(im.Col_Text, cols.blueB)
  end
  local clicked = im.RadioButton1(label, sel == cls)
  if cls == 1 then
    im.tooltip("Override class: Small (S)\nThis affects the vegetation-size RTPC (color).\nDefault choice is tinted blue.")
  elseif cls == 2 then
    im.tooltip("Override class: Medium (M)\nThis affects the vegetation-size RTPC (color).\nDefault choice is tinted blue.")
  else
    im.tooltip("Override class: Large (L)\nThis affects the vegetation-size RTPC (color).\nDefault choice is tinted blue.")
  end
  if cls == def then
    im.PopStyleColor()
  end
  if clicked and sel ~= cls then
    sel = cls -- reflect immediately in same frame
    forestTypeClassSelByShape[shape] = cls
    forestTypeClassSel[row] = cls
    forestTypeClassOverrideByShape[shape] = (cls ~= def)
    refreshClassIncludeState()
    return sel, true
  end
  return sel, false
end

-- Draws one forest type include/class row.
local function drawForestExclusionRow(row)
  local changed = false
  local shape = forestTypeShapes[row] or ''
  local ptr = forestIncludePtrByShape[shape]
  local flag = row == selectedForestTypeRow

  local rowH = im.GetFrameHeightWithSpacing()
  if im.Selectable1(forestTypeSelectableId[row], flag, forestSelectableFlags, im.ImVec2(0, rowH)) then
    selectedForestTypeRow = row
  end
  do
    local dl = im.GetWindowDrawList()
    local pMin = im.GetItemRectMin()
    local pMax = im.GetItemRectMax()
    local h = pMax.y - pMin.y
    local s = min(14, h - 4)
    local x0 = pMin.x + 2
    local y0 = pMin.y + 2
    local def = forestTypeClassDefaultByShape[shape] or 2
    local sel = forestTypeClassSelByShape[shape] or def
    local colU32 = (ptr[0] and (classColsU32[sel] or classColsU32[2])) or (classColsU32Dim[sel] or classColsU32Dim[2])
    im.ImDrawList_AddRectFilled(dl, im.ImVec2(x0, y0), im.ImVec2(x0 + s, y0 + s), colU32)
  end
  if scrollToForestTypeRow and row == scrollToForestTypeRow then
    im.SetScrollHereY(0.5)
    scrollToForestTypeRow = nil
  end
  im.SameLine()
  im.NextColumn()

  if im.Checkbox(forestTypeCheckboxId[row], ptr) then
    selectedForestTypeRow = row
    changed = true
    local inst = forestTypeInstanceCount[row] or 0
    if ptr[0] then
      forestIncludedTypeCount = forestIncludedTypeCount + 1
      forestIncludedInstanceCount = forestIncludedInstanceCount + inst
    else
      forestIncludedTypeCount = forestIncludedTypeCount - 1
      forestIncludedInstanceCount = forestIncludedInstanceCount - inst
    end
    refreshForestSummaryStrings()
    refreshClassIncludeState()
  end
  im.NextColumn()

  im.TextUnformatted(forestTypeInstanceCountStr[row] or "")
  im.NextColumn()

  im.TextUnformatted(forestTypeVolumeStr[row] or "")
  im.NextColumn()

  if not ptr[0] then
    im.TextColored(cols.dullWhite, forestTypeBaseName[row] or "")
  else
    im.TextUnformatted(forestTypeBaseName[row] or "")
  end
  im.NextColumn()

  local def = forestTypeClassDefaultByShape[shape] or 2
  local sel = forestTypeClassSelByShape[shape] or def

  im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(2, 2))
  local radioChanged = false
  sel, radioChanged = drawClassRadioButton("S##clsS_" .. shape, 1, sel, def, shape, row); changed = changed or radioChanged
  im.SameLine()
  sel, radioChanged = drawClassRadioButton("M##clsM_" .. shape, 2, sel, def, shape, row); changed = changed or radioChanged
  im.SameLine()
  sel, radioChanged = drawClassRadioButton("L##clsL_" .. shape, 3, sel, def, shape, row); changed = changed or radioChanged
  im.PopStyleVar()
  if im.IsItemHovered() then
    im.tooltip((forestTypeTooltipStr[row] or "") .. "\nDefault class is blue.")
  end
  im.NextColumn()
  im.Separator()

  return changed
end

-- Renders forest include and class controls.
local function renderForestExclusionList()
  im.Separator()
  im.TextColored(cols.greenB, "Forest Exclusion List:")
  if isForestListDirty then
    refreshForestTypeList()
  end
  refreshClassIncludeState()

  im.Columns(2, "forestExclusionTotalsRow", false)
  im.SetColumnWidth(0, 140)
  im.TextUnformatted(forestTotalsStr)
  im.tooltip("Included / Total forest instances")
  im.NextColumn()
  im.TextColored(cols.dullWhite, forestTypesHintStr)
  im.Columns(1)

  im.PushItemWidth(-1)
  if im.BeginListBox('###forestExclusionListBox', im.ImVec2(-1, 260)) then
    im.Columns(6, "forestExclusionListBoxColumns", true)
    im.SetColumnWidth(0, 18)  -- selection gutter
    im.SetColumnWidth(1, 30)  -- include checkbox
    im.SetColumnWidth(2, 55)  -- type count
    im.SetColumnWidth(3, 70)  -- volume
    im.SetColumnWidth(4, 195) -- base name
    im.SetColumnWidth(5, 120) -- class selector
    im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(4, 2))
    im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

    local needsRebuild = false

    if forestListForceUnclippedFrames > 0 then
      for row = 1, forestTypeRowCount do
        needsRebuild = drawForestExclusionRow(row) or needsRebuild
      end
      forestListForceUnclippedFrames = forestListForceUnclippedFrames - 1
    else
      im.ImGuiListClipper_Begin(forestClipper, forestTypeRowCount)
      while im.ImGuiListClipper_Step(forestClipper) do
        for row = forestClipper.DisplayStart + 1, forestClipper.DisplayEnd do
          needsRebuild = drawForestExclusionRow(row) or needsRebuild
        end
      end
    end

    im.PopStyleVar(2)
    im.EndListBox()

    if needsRebuild then
      rebuildForestNodeCloud()
    end
  end
  im.PopItemWidth()

  im.Separator()

  im.Columns(4, "buttonsUnderForestExclusionListBox", false)
  im.SetColumnWidth(0, 80)
  im.SetColumnWidth(1, 60)
  im.SetColumnWidth(2, 60)
  im.SetColumnWidth(3, 60)
  im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
  im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

  local changed = false
  if im.Button("Refresh###refreshForestList") then
    isForestListDirty = true
    refreshForestTypeList()
    changed = true
  end
  im.NextColumn()
  if im.Button("All###forestIncAll") then
    setAllForestTypeIncludes(true)
    changed = true
  end
  im.NextColumn()
  if im.Button("None###forestIncNone") then
    setAllForestTypeIncludes(false)
    changed = true
  end
  im.NextColumn()
  if im.Button("Invert###forestIncInvert") then
    for row = 1, forestTypeRowCount do
      local shape = forestTypeShapes[row]
      local ptr = forestIncludePtrByShape[shape]
      ptr[0] = not ptr[0]
    end
    recomputeForestIncludeCounts()
    changed = true
  end
  im.Columns(1)
  im.PopStyleVar(2)

  if changed then
    rebuildForestNodeCloud()
  end

  im.Separator()
  im.TextColored(cols.greenB, "Include classes:")
  im.SameLine()
  local bulkChanged = false

  drawClassSwatchU32(classColsU32[1]); im.SameLine()
  if im.Checkbox("S###incClassS", classIncSPtr) then
    applyIncludeForClass(1, classIncSPtr[0])
    bulkChanged = true
  end
  im.tooltip("Include/exclude all Small (S) types at once.")
  im.SameLine()

  drawClassSwatchU32(classColsU32[2]); im.SameLine()
  if im.Checkbox("M###incClassM", classIncMPtr) then
    applyIncludeForClass(2, classIncMPtr[0])
    bulkChanged = true
  end
  im.tooltip("Include/exclude all Medium (M) types at once.")
  im.SameLine()

  drawClassSwatchU32(classColsU32[3]); im.SameLine()
  if im.Checkbox("L###incClassL", classIncLPtr) then
    applyIncludeForClass(3, classIncLPtr[0])
    bulkChanged = true
  end
  im.tooltip("Include/exclude all Large (L) types at once.")
  if bulkChanged then
    recomputeForestIncludeCounts()
    rebuildForestNodeCloud()
  end

  im.Separator()
  if im.Button("Reset class overrides###resetClassOverrides") then
    if isForestListDirty then
      refreshForestTypeList()
    end
    for row = 1, forestTypeRowCount do
      local shape = forestTypeShapes[row]
      local def = forestTypeClassDefaultByShape[shape] or 2
      forestTypeClassSelByShape[shape] = def
      forestTypeClassOverrideByShape[shape] = false
      forestTypeClassSel[row] = def
    end
    rebuildForestNodeCloud()
  end
  im.tooltip("Resets all S/M/L selections back to their bbox-based defaults.")
end

-- Renders the main forest event controls.
local function renderMainEvent()
  im.Separator()
  im.TextColored(cols.greenB, "Main Event:")

  im.PushItemWidth(-1)
  if im.InputText("###mainEvent", mainEventEditPtr, 128) then
    mainEventStr = ffi.string(mainEventEditPtr)
    audioForest.clearMainAudio()
    audioForest.setMainEvent(mainEventStr)
    audioForest.setEnabled(mainEventStr ~= '')
    emitterNodeIds = (mainEventStr ~= '') and audioForest.getEmitterNodeIds() or nil
    emitterNodeIdCount = (mainEventStr ~= '') and 1 or 0
    pushToolStateToRuntime()
  end
  im.PopItemWidth()
  im.tooltip("Single FMOD event for the forest emitter.\nRTPC 'color' will be vegetation-size proxy in [0..1].")

  im.Columns(2, "mainEventButtons", false)
  im.SetColumnWidth(0, 120)
  if im.Button("Use default###mainEvUseDefault") then
    mainEventEditPtr = im.ArrayChar(128, defaultGroupEventName)
    mainEventStr = defaultGroupEventName
    audioForest.clearMainAudio()
    audioForest.setMainEvent(mainEventStr)
    audioForest.setEnabled(true)
    emitterNodeIds, emitterNodeIdCount = audioForest.getEmitterNodeIds()
    pushToolStateToRuntime()
  end
  im.tooltip("Reset main event to default.")
  im.NextColumn()
  if im.Button("Clear###mainEvClear") then
    mainEventEditPtr = im.ArrayChar(128, "")
    mainEventStr = ''
    audioForest.clearMainAudio()
    audioForest.setMainEvent('')
    audioForest.setEnabled(false)
    emitterNodeIds, emitterNodeIdCount = nil, 0
    pushToolStateToRuntime()
  end
  im.tooltip("Clear main event (disables runtime forest audio).")
  im.Columns(1)
end

-- Renders the independent roomtone controls.
local function renderRoomtone()
  im.Separator()
  im.TextColored(cols.greenB, "Roomtone:")

  if im.Checkbox("Enabled###roomtoneEnabled", roomtoneEnabledPtr) then
    audioForest.setRoomtoneEnabled(roomtoneEnabledPtr[0])
    pushToolStateToRuntime()
  end
  im.tooltip("Plays a single fixed-position roomtone emitter (centered at x=0,y=0).\nThis is independent from the forest wind emitter and avoids direction/distance jumps.")

  if not roomtoneEnabledPtr[0] then
    return
  end

  im.PushItemWidth(-1)
  if im.InputText("###roomtoneEvent", roomtoneEventEditPtr, 128) then
    roomtoneEventStr = ffi.string(roomtoneEventEditPtr)
    audioForest.setRoomtoneEvent(roomtoneEventStr)
    pushToolStateToRuntime()
  end
  im.PopItemWidth()
  im.tooltip("FMOD event path for roomtone.")

  im.PushItemWidth(-1)
  if im.SliderFloat("###roomtoneZ", roomtoneZPtr, -200.0, 2000.0, "Z (m) = %.1f") then
    audioForest.setRoomtoneZ(roomtoneZPtr[0])
    pushToolStateToRuntime()
  end
  im.PopItemWidth()
  im.tooltip("Roomtone emitter Z position (x=0,y=0 are fixed).")
end

-- Renders the main Audio Forest editor window.
local function renderToolWindow()
  local icons = editor.icons
  if not editor.beginWindow(toolWinName, "Audio Forest Editor") then
    return
  end

  renderWorldGraphControls(icons)
  renderForestExclusionList()
  renderMainEvent()
  renderRoomtone()

  editor.endWindow()
end

-- Updates editor UI, picking, and node visualization.
local function onEditorGui()
  if not isAudioForestEditor then
    return
  end

  if isForestListDirty then
    refreshForestTypeList()
  end

  -- Render UI first (matches other tools, keeps ImGui state current).
  renderToolWindow()

  updateForestHoverPicking()

  if showNodeVisPtr[0] and worldGraph then
    worldGraph.sphereRadius = nodeVisSphereRadiusPtr[0]
    if emitterNodeIds and emitterNodeIdCount and emitterNodeIdCount > 0 then
      render.renderWorldGraphNodeBackdrops(
      worldGraph,
      nodeVisDrawRadiusPtr[0],
      emitterNodeIds,
      emitterNodeIdCount,
      1.7,
      color(60, 60, 60, 90))
    end
    render.renderWorldGraphNodes(worldGraph, nodeVisDrawRadiusPtr[0])

    local centroidActive, cx, cy, cz = audioForest.getMainEmitterDebugState()
    if centroidActive then
      centroidDebugPos:set(cx, cy, cz + debugCentroidZ)
      debugDrawer:drawSphere(centroidDebugPos, debugCentroidRadius, debugCentroidCol)
    end
  end
end

-- Activates the Audio Forest editor mode.
local function onActivate()
  editor.clearObjectSelection()
  editor.showWindow(toolWinName)
  isAudioForestEditor = true
  if not pendingDeserializedState then
    pendingDeserializedState = audioForest.getPersistedToolState()
    if pendingDeserializedState then
      isForestListDirty = true
    end
  end
  if pendingDeserializedState then
    selectedForestTypeRow = pendingDeserializedState.selectedRow or selectedForestTypeRow
    mainEventStr = pendingDeserializedState.mainEvent or mainEventStr
    mainEventEditPtr = im.ArrayChar(128, mainEventStr)
    roomtoneEnabledPtr[0] = pendingDeserializedState.roomtoneEnabled and true or false
    roomtoneEventStr = pendingDeserializedState.roomtoneEvent or roomtoneEventStr
    roomtoneEventEditPtr = im.ArrayChar(128, roomtoneEventStr)
    roomtoneZPtr[0] = pendingDeserializedState.roomtoneZ or roomtoneZPtr[0]
  else -- Start with everything included each activation.
    table.clear(forestIncludePtrByShape)
  end
  isForestListDirty = true
  rebuildForestNodeCloud()

  audioForest.setRoomtoneZ(roomtoneZPtr[0])
  audioForest.setRoomtoneEvent(roomtoneEventStr)
  audioForest.setRoomtoneEnabled(roomtoneEnabledPtr[0])
  pushToolStateToRuntime()
end

-- Deactivates the Audio Forest editor mode.
local function onDeactivate()
  editor.hideWindow(toolWinName)
  isAudioForestEditor = false
end

-- Registers the editor mode and tool window.
local function onEditorInitialized()
  editor.editModes.audioForestEditMode = {
    displayName = "Audio Forest Editor",
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    icon = editor.icons.create_forest,
    iconTooltip = "Audio Forest Editor",
    auxShortcuts = {},
    hideObjectIcons = true }
  editor.registerWindow(toolWinName, toolWinSize)
end

-- Receives persisted editor state after level load.
local function onDeserialized(data)
  if type(data) ~= 'table' then
    return
  end
  pendingDeserializedState = data
  isForestListDirty = true
  if isAudioForestEditor then
    rebuildForestNodeCloud()
  end
end

-- Public interface.
M.onEditorGui =                                           onEditorGui
M.onEditorInitialized =                                   onEditorInitialized
M.onSerialize =                                           onSerialize
M.onDeserialized =                                        onDeserialized

return M