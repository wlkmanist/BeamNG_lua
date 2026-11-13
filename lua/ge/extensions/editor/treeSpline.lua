-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Tree Spline.
-- Draw an editable polyline on the terrain and the tool plants an evenly-spaced ROW of tree/shrub species along
-- it (real Forest instances) - avenues, tree lines, hedges. As soon as the spline has 2+ nodes it plants, and it
-- re-plants live as you add/move/delete nodes or change the distribution. This is the line sibling of the
-- forestZoneEditor (polygon) tool; both share the scatter core in toolUtilities/foliageScatter and follow the
-- same tool structure as meshSpline / assemblySpline (editor/<tool>.lua + <tool>/splineMgr.lua + populate.lua).

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local minSpacing, maxSpacing = 0.5, 40.0
local minVariance, maxVariance = 0.0, 1.0
local minScaleVar, maxScaleVar = 0.0, 0.9
local minSlope, maxSlope = 0.0, 89.0
local maxRandomSeed = 100000

local defaultSplineWidth = 4.0 -- Nominal per-node width (unused by the row scatter; kept for spline geometry).
local elevScale = 100.0 -- Elevation drop-line scale factor (shared spline rendering).
local simplifyRdpTol = 4.0 -- Tolerance (m) for the RDP node-reduction ('simplify') operation.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- External modules.
local splineMgr = require('editor/treeSpline/splineMgr')
local pop = require('editor/treeSpline/populate')
local scatter = require('editor/toolUtilities/foliageScatter')
local fPicker = require('editor/toolUtilities/foliagePicker')
local input = require('editor/toolUtilities/splineInput')
local panCamera = require('editor/toolUtilities/panCamera')
local rSpline = require('editor/toolUtilities/render/spline')
local style = require('editor/toolUtilities/style')
local util = require('editor/toolUtilities/util')
local session = require('editor/toolUtilities/session')
local geom = require('editor/toolUtilities/geom')
local rdp = require('editor/toolUtilities/rdp')
local bake = require('editor/toolUtilities/bake')

-- Module constants.
local im = ui_imgui
local min, max = math.min, math.max
local toolWinName, toolWinSize = 'treeSpline', im.ImVec2(330, 760)
local cols = style.getImguiCols('crystal')
local iconsSmall, iconsBig = im.ImVec2(24, 24), im.ImVec2(36, 36)
local defaultFoliage = splineMgr.getFoliageParamDefaults()
local classPresetIcons = { -- Icon + tooltip per class preset (order follows scatter.getClassOrder()).
  forest  = { icon = 'forest_snap_terrain',   tip = 'Forest: standard woodland spacing.' },
  dense   = { icon = 'forest_select',         tip = 'Dense: tightly-packed row.' },
  sparse  = { icon = 'forest_paint',          tip = 'Sparse: widely-spaced trees.' },
  shrub   = { icon = 'forest_brushelement',   tip = 'Shrub / hedge: small, closely-spaced.' },
  orchard = { icon = 'forest_add_brushgroup', tip = 'Orchard: regular, uniform-scale row.' },
}

-- Module state.
local isActive = false
local selectedSplineIdx, selectedNodeIdx = 1, 1
local previousSelectedSplineIdx = -1 -- tracks selection changes so the list scrolls to the selected spline once
local isGizmoActive, isLockShape = false, false
local sliderPreState = nil -- undo snapshot captured at a slider grab
local lifted = nil -- the live splines' trees, out of the forest while a level save writes it
local out = { spline = selectedSplineIdx, node = selectedNodeIdx, isGizmoActive = isGizmoActive, isLockShape = isLockShape }

-- Save/Load Session spec handed to the shared helper (toolUtilities/session): only these tool-specific hooks stay here.
local sessionSpec = {
  toolId = 'treeSpline',
  displayName = 'Tree Spline',
  itemNoun = 'tree splines',
  getItems = splineMgr.getTreeSplines,
  serializeItem = splineMgr.serializeTreeSplineToTable,
  deserializeItem = function(t) return splineMgr.deserializeTreeSpline(t) end,
  clearAll = function() splineMgr.removeAllTreeSplines(true) end,
  deepCopyAll = splineMgr.deepCopyTreeSplineState,
  transUndo = splineMgr.transSplineEditUndo,
  transRedo = splineMgr.transSplineEditRedo,
  refreshIdMap = splineMgr.recomputeIdMap,
  onLoaded = function() selectedSplineIdx = 1 end,
  iconColor = cols.blueB,
  iconSize = iconsBig,
}

-- Register with the shared spline input utilities (enables cross-tool node selection / hot-reload callbacks).
input.registerSplineTool(
  splineMgr.getToolPrefixStr(),
  splineMgr.getTreeSplines,
  splineMgr.getEditModeKey,
  splineMgr.deepCopyTreeSpline,
  splineMgr.deepCopyTreeSplineState,
  'editor_treeSpline'
)

-- Cross-tool selection setters (invoked by splineInput when a jump into this tool occurs). Both must exist or
-- splineInput skips the selection entirely (it requires the pair).
local function setSelectedSplineIdx(idx) selectedSplineIdx = idx end
local function setSelectedNodeIdx(idx) selectedNodeIdx = idx end

-- Snapshot a single spline before an edit.
local function preEdit(s) return splineMgr.deepCopyTreeSpline(s) end

-- Commit a single-spline (param / species) edit.
local function commitEdit(label, pre, s)
  editor.history:commitAction(label, { old = pre, new = splineMgr.deepCopyTreeSpline(s) },
    splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
end

-- Commit a structural (add / remove / remove-all) edit over the whole list.
local function commitTrans(label, preState)
  editor.history:commitAction(label, { old = preState, new = splineMgr.deepCopyTreeSplineState() },
    splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
end

-- Locks/unlocks the tree spline with this id and re-plants it now (also used by the Master Spline for linked children). A
-- locked spline's trees are left in the forest when the level saves (see onEditorBeforeSaveLevel).
local function setLockedById(id, isLocked)
  local sp = splineMgr.getTreeSplines()[splineMgr.getSplineMap()[id]]
  if not sp then return end
  sp.isEnabled = not isLocked
  sp.isDirty = true
  splineMgr.updateDirtyTreeSplines()
  editor.forestDirty = true
end

local bakeSpec = { toolId = 'treeSpline', displayName = 'Tree Spline', setLockedById = setLockedById }

-- Applies a class preset's spacing/scale defaults to a spline (keeps species + seed).
local function applyClassPreset(s, className)
  local p = scatter.getClassPresets()[className]
  if not p then return end
  s.class = className
  s.spacingM = p.spacingM
  s.scaleVariance = p.scaleVariance
end

-- Draws the shared species picker for spline `s`, wired to this tool's per-spline undo + dirty machinery.
local function drawSpeciesPicker(s)
  fPicker.draw(s, {
    id = 'ts',
    height = 150,
    onBeginEdit = function() return preEdit(s) end,
    onCommit = function(label, pre) commitEdit(label, pre, s) end,
    onChange = function() s.isDirty = true end,
  })
end

-- One float distribution slider, styled like the other tools: [reset icon | slider] two-column row.
local function paramSlider(s, id, label, getv, setv, lo, hi, fmt, default)
  if getv(s) ~= default then
    if editor.uiIconImageButton(editor.icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'tsReset' .. id) then
      local pre = preEdit(s)
      setv(s, default)
      s.isDirty = true
      commitEdit("Reset " .. id, pre, s)
    end
    im.tooltip("Reset to default")
  else
    im.Dummy(iconsSmall)
  end
  im.SameLine()
  im.NextColumn()
  im.PushItemWidth(-1)
  local p = im.FloatPtr(getv(s))
  if im.SliderFloat('###ts' .. id, p, lo, hi, label .. fmt) then
    setv(s, p[0])
    s.isDirty = true
  end
  if im.IsItemActivated() then sliderPreState = preEdit(s) end
  if im.IsItemDeactivatedAfterEdit() then commitEdit("Adjust " .. id, sliderPreState or preEdit(s), s) end
  im.PopItemWidth()
  im.NextColumn()
end

-- Distribution parameter section for the selected spline.
local function drawDistribution(s)
  im.TextColored(cols.greenB, "Preset:")

  -- Class preset buttons (a row of icons; the active preset is highlighted).
  local order = scatter.getClassOrder()
  im.Columns(#order, "tsPresetCols", false)
  for i = 1, #order do im.SetColumnWidth(i - 1, 39) end
  im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
  im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
  for i = 1, #order do
    local cn = order[i]
    local info = classPresetIcons[cn] or { icon = 'forest_snap_terrain', tip = cn }
    local btnCol = (s.class == cn) and cols.blueB or cols.blueD
    if editor.uiIconImageButton(editor.icons[info.icon], iconsBig, btnCol, nil, nil, 'tsPreset' .. cn) then
      local pre = preEdit(s)
      applyClassPreset(s, cn)
      s.isDirty = true
      commitEdit("Tree Spline Preset", pre, s)
    end
    im.tooltip(info.tip)
    if i < #order then im.SameLine() end
    im.NextColumn()
  end
  im.PopStyleVar(2)
  im.Columns(1)

  im.TextColored(cols.greenB, "Distribution:")

  im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
  im.Columns(2, 'tsDistCols', false)
  im.SetColumnWidth(0, 30)
  paramSlider(s, "Spacing", "Spacing (m) = ", function(x) return x.spacingM end,
    function(x, v) x.spacingM = v end, minSpacing, maxSpacing, "%.2f", defaultFoliage.spacingM)
  paramSlider(s, "PosVariance", "Position variance +/- ", function(x) return x.posVariance end,
    function(x, v) x.posVariance = v end, minVariance, maxVariance, "%.2f", defaultFoliage.posVariance)
  paramSlider(s, "HeightVariance", "Height variance +/- ", function(x) return x.scaleVariance end,
    function(x, v) x.scaleVariance = v end, minScaleVar, maxScaleVar, "%.2f", defaultFoliage.scaleVariance)
  paramSlider(s, "MaxSlope", "Max slope (deg) = ", function(x) return x.slopeMaxDeg end,
    function(x, v) x.slopeMaxDeg = v end, minSlope, maxSlope, "%.0f", defaultFoliage.slopeMaxDeg)
  im.Columns(1)
  im.PopStyleVar()

  -- Align-to-normal.
  local alignPtr = im.BoolPtr(s.alignToNormal == true)
  if im.Checkbox("Align to terrain normal###tsAlign", alignPtr) then
    local pre = preEdit(s)
    s.alignToNormal = alignPtr[0]
    s.isDirty = true
    commitEdit("Tree Spline Align", pre, s)
  end

  -- Seed slider + reseed button (any change re-plants the row).
  im.PushItemWidth(-70)
  local seedPtr = im.IntPtr(s.seed or 0)
  if im.SliderInt('###tsSeed', seedPtr, 0, maxRandomSeed, "Seed = %d") then
    s.seed = seedPtr[0]
    s.isDirty = true
  end
  if im.IsItemActivated() then sliderPreState = preEdit(s) end
  if im.IsItemDeactivatedAfterEdit() then commitEdit("Tree Spline Seed", sliderPreState or preEdit(s), s) end
  im.PopItemWidth()
  im.SameLine()
  if im.Button("Reseed###tsReseed") then
    local pre = preEdit(s)
    s.seed = math.random(0, maxRandomSeed)
    s.isDirty = true
    commitEdit("Tree Spline Reseed", pre, s)
  end

  im.Separator()
  im.TextColored(cols.dullWhite, "Instances: " .. tostring(s.count or 0))
  if #s.nodes < 2 then
    im.TextColored(cols.dullWhite, "Click on the terrain to add spline nodes (need 2+).")
  end
end

local function handleMainToolWindowUI()
  if editor.beginWindow(toolWinName, session.windowTitle(sessionSpec.toolId, "Tree Spline", "ts1"), im.WindowFlags_NoCollapse) then
    local icons = editor.icons
    local splines = splineMgr.getTreeSplines()
    selectedSplineIdx = max(0, min(#splines, selectedSplineIdx))

    -- Top buttons row (inline: plain im.SameLine sequence, Dummy holds slots for unavailable buttons).
    im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
    im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

    -- 'Add New Tree Spline' button.
    if editor.uiIconImageButton(icons.bSpline, iconsBig, cols.blueB, nil, nil, 'tsAddBtn') then
      local pre = splineMgr.deepCopyTreeSplineState()
      local idx = splineMgr.addNewTreeSpline()
      selectedSplineIdx, selectedNodeIdx = idx, 1
      commitTrans("Add Tree Spline", pre)
    end
    im.tooltip('Add a new tree spline, then click on the terrain to place its nodes.')
    im.SameLine()

    -- 'Remove All Splines' button.
    if #splines > 0 then
      if editor.uiIconImageButton(icons.trashBin2, iconsBig, cols.blueB, nil, nil, 'tsRemoveAllBtn') then
        local pre = splineMgr.deepCopyTreeSplineState()
        splineMgr.removeAllTreeSplines(false)
        selectedSplineIdx = 0
        commitTrans("Remove All Tree Splines", pre)
      end
      im.tooltip('Remove all (enabled and not linked) tree splines from the session.')
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()

    -- Pan camera toggle (top-down RMB-drag pan + wheel zoom, shared across the spline tools).
    if editor.uiIconImageButton(icons.videocam, iconsBig, panCamera.isOn() and cols.blueB or cols.blueD, nil, nil, 'panCamBtn') then
      panCamera.toggle()
    end
    im.tooltip(panCamera.isOn() and 'Pan camera ON: top-down, RMB-drag to move, wheel to zoom. Click for the free camera.' or 'Pan camera: top-down view, RMB-drag pan + wheel zoom.')
    im.SameLine()

    -- 'Save Session' / 'Load Session' (+ Replace/Merge modal) via the shared helper -- end of the row.
    session.renderButtons(sessionSpec)

    im.PopStyleVar(2)
    im.Columns(1)
    im.Separator()

    -- Splines list.
    im.TextColored(cols.greenB, "Tree Splines:")
    local removeIdx = nil
    im.PushItemWidth(-1)
    if im.BeginListBox('###tsSplineList', im.ImVec2(-1, 150)) then
      im.Columns(5, "tsSplineListCols", true)
      im.SetColumnWidth(0, 30 * im.uiscale[0])
      im.SetColumnWidth(1, 155 * im.uiscale[0])
      im.SetColumnWidth(2, 35 * im.uiscale[0])
      im.SetColumnWidth(3, 35 * im.uiscale[0])
      im.SetColumnWidth(4, 35 * im.uiscale[0])
      im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(4, 2))
      im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
      local didSplineIdxChange = previousSelectedSplineIdx ~= selectedSplineIdx
      previousSelectedSplineIdx = selectedSplineIdx
      for i = 1, #splines do
        local sp = splines[i]
        local flag = (i == selectedSplineIdx)
        if im.Selectable1("###tsSplineSel" .. i, flag, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
          selectedSplineIdx, selectedNodeIdx = i, 1
        end
        if didSplineIdxChange and flag then im.SetScrollHereY(0.5) end -- scroll the list to the newly-selected spline
        im.SameLine()
        im.NextColumn()

        im.PushItemWidth(155 * im.uiscale[0])
        if sp.isLink then
          im.TextColored(cols.dullWhite, sp.name)
          im.tooltip('This tree spline is linked to a Master Spline. To edit or remove it, first unlink it from within the Master Spline Editor.')
        elseif not sp.isEnabled then
          im.TextColored(cols.dullWhite, sp.name)
          im.tooltip('This tree spline is locked. Unlock it to edit it.')
        else
          local namePtr = im.ArrayChar(48, sp.name)
          if im.InputText("###tsSplineName" .. i, namePtr, 48) then
            sp.name = ffi.string(namePtr)
          end
          if im.IsItemActive() then selectedSplineIdx = i end
        end
        im.PopItemWidth()
        im.SameLine()
        im.NextColumn()

        im.PushID1("tsSplineDel" .. i)
        if sp.isLink or not sp.isEnabled then
          im.Dummy(iconsSmall)
        elseif editor.uiIconImageButton(icons.trashBin2, iconsSmall, cols.blueB, nil, nil, 'tsDel' .. i) then
          removeIdx = i
        end
        im.tooltip('Remove this tree spline.')
        im.PopID()
        im.NextColumn()

        -- 'Lock/Unlock' button. Linked splines are locked from the Master Spline.
        if sp.isLink then
          im.Dummy(iconsSmall)
        else
          local btnIcon = sp.isEnabled and icons.lock or icons.lock_open
          if editor.uiIconImageButton(btnIcon, iconsSmall, sp.isEnabled and cols.blueB or cols.blueD, nil, nil, 'tsLock' .. i) then
            bake.setLocked(bakeSpec, sp, sp.isEnabled)
            selectedSplineIdx = i
          end
          im.tooltip(sp.isEnabled and 'Lock this tree spline: its trees save with the level.' or 'Unlock this tree spline: its trees become editable again (re-planted from the spline).')
        end
        im.NextColumn()

        -- 'Bake' button (per row): locks this tree spline.
        if sp.isLink or not sp.isEnabled or #sp.nodes < 2 then
          im.Dummy(iconsSmall)
        else
          if editor.uiIconImageButton(editor.icons.local_fire_department or editor.icons.whatshot, iconsSmall, cols.redB, nil, nil, 'tsBurn' .. i) then
            bake.setLocked(bakeSpec, sp, true)
            selectedSplineIdx = i
          end
          im.tooltip('Bake: lock this tree spline. Its trees save with the level; it stays in the tool and can be unlocked again. Undoable.')
        end
        im.NextColumn()
        im.Separator()
      end
      im.PopStyleVar(2)
      im.EndListBox()
    end
    im.PopItemWidth()

    if removeIdx then
      local pre = splineMgr.deepCopyTreeSplineState()
      splineMgr.removeTreeSpline(removeIdx)
      if selectedSplineIdx >= removeIdx then selectedSplineIdx = max(0, selectedSplineIdx - 1) end
      commitTrans("Remove Tree Spline", pre)
    end

    -- Operations row underneath the listbox (matches meshSpline / riverSpline layout).
    local selSpline = splines[selectedSplineIdx]
    if selSpline and selSpline.isEnabled and not selSpline.isLink then
      im.Separator()
      im.Columns(6, "tsUnderListButtons", false)
      for c = 0, 5 do im.SetColumnWidth(c, 40) end
      im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
      im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

      -- 'Go To Selected Spline'.
      if #selSpline.nodes > 1 then
        if editor.uiIconImageButton(icons.cameraFocusTopDown, iconsBig, cols.blueB, nil, nil, 'tsGoToBtn') then
          local pts = #selSpline.divPoints > 1 and selSpline.divPoints or selSpline.nodes
          if not panCamera.gotoPoints(pts) then util.goToSpline(pts) end
        end
        im.tooltip('Go to this tree spline (move camera).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Split Tree Spline' (scissors), at the selected node.
      if selSpline.nodes[selectedNodeIdx] and #selSpline.nodes > 2 and (selSpline.isLoop or (selectedNodeIdx > 1 and selectedNodeIdx < #selSpline.nodes)) then
        if editor.uiIconImageButton(icons.content_cut, iconsBig, cols.blueB, nil, nil, 'tsSplitBtn') then
          local pre = splineMgr.deepCopyTreeSplineState()
          selectedSplineIdx = splineMgr.splitTreeSpline(selectedSplineIdx, selectedNodeIdx)
          selectedNodeIdx = 1
          commitTrans("Split Tree Spline", pre)
        end
        im.tooltip('Splits the selected tree spline into two, at the selected node.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Flip Direction'.
      if #selSpline.nodes > 1 then
        if editor.uiIconImageButton(icons.cached, iconsBig, cols.blueB, nil, nil, 'tsFlipBtn') then
          local pre = preEdit(selSpline)
          geom.flipSplineDirection(selSpline)
          selSpline.isDirty = true
          commitEdit("Flip Tree Spline Direction", pre, selSpline)
        end
        im.tooltip('Flips the direction of the selected tree spline (back to front).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Simplify Spline' (RDP node reduction).
      if selSpline.nodes[selectedNodeIdx] and #selSpline.nodes > 2 then
        if editor.uiIconImageButton(icons.routeSimple, iconsBig, cols.blueB, nil, nil, 'tsSimplifyBtn') then
          local pre = preEdit(selSpline)
          rdp.simplifyNodesWidthsNormals(selSpline.nodes, selSpline.widths, selSpline.nmls, simplifyRdpTol)
          selectedNodeIdx = max(1, min(#selSpline.nodes, selectedNodeIdx))
          selSpline.isDirty = true
          commitEdit("Simplify Tree Spline", pre, selSpline)
        end
        im.tooltip('Simplifies the selected tree spline (reduces the number of nodes).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Save Template' (foliage species + distribution) to disk.
      if editor.uiIconImageButton(icons.floppyDisk, iconsBig, nil, nil, nil, 'tsSaveTemplateBtn') then
        extensions.editor_fileDialog.saveFile(
          function(data) jsonWriteFile(data.filepath, splineMgr.copyTreeSplineProfile(selSpline), true) end,
          {{"JSON", ".json"}}, false, "/", "File already exists.\nDo you want to overwrite the file?")
      end
      im.tooltip('Saves the species + distribution of the selected tree spline as a template on disk.')
      im.SameLine()
      im.NextColumn()

      -- 'Load Template' from disk onto the selected spline.
      if editor.uiIconImageButton(icons.roadFolder, iconsBig, cols.dullWhite, nil, nil, 'tsLoadTemplateBtn') then
        extensions.editor_fileDialog.openFile(
          function(data)
            local pre = preEdit(selSpline)
            splineMgr.pasteTreeSplineProfile(selSpline, jsonReadFile(data.filepath))
            commitEdit("Load Tree Spline Template", pre, selSpline)
          end,
          {{"JSON", ".json"}}, false, "/")
      end
      im.tooltip('Sets the selected tree spline to a template loaded from disk.')
      im.NextColumn()

      im.PopStyleVar(2)
      im.Columns(1)
    end

    im.Separator()

    -- Selected-spline editor section.
    local s = splines[selectedSplineIdx]
    if s and not s.isEnabled then
      im.TextColored(cols.dullWhite, "This tree spline is locked. Unlock it to edit it.")
    elseif s then
      drawSpeciesPicker(s)
      im.Separator()
      drawDistribution(s)
    else
      im.TextColored(cols.dullWhite, "Select or add a tree spline to edit it.")
    end
  end
  editor.endWindow()
end

local function onEditorGui()
  if lifted then scatter.relay(lifted); lifted = nil end
  -- Rebuild/replant any dirty splines every frame (also after deserialize / undo, even when inactive).
  splineMgr.updateDirtyTreeSplines()

  if not isActive then
    rSpline.renderShells(splineMgr.getTreeSplines()) -- show the spline centrelines + node spheres (matches the other spline tools)
    return
  end

  handleMainToolWindowUI()

  -- Drive the pan camera when it's on (blocked during node / gizmo drag so they don't fight).
  if panCamera.isOn() then panCamera.drive(input.isDragging()) end

  -- Handle node editing (add / drag / delete) via the shared spline input utilities.
  local splines = splineMgr.getTreeSplines()
  out.spline, out.node, out.isGizmoActive, out.isLockShape = selectedSplineIdx, selectedNodeIdx, isGizmoActive, isLockShape
  input.handleSplineEvents(
    splines,
    out,
    true, true, false, false, false, true, true, isLockShape, -- Tree rows always drape onto the surface (2D on terrain), so the node editor works in conform mode.
    defaultSplineWidth,
    splineMgr.deepCopyTreeSpline, splineMgr.deepCopyTreeSplineState,
    splineMgr.copyTreeSplineProfile, splineMgr.pasteTreeSplineProfile,
    nil,
    nil,
    splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo,
    splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo)
  selectedSplineIdx, selectedNodeIdx, isGizmoActive, isLockShape = out.spline, out.node, out.isGizmoActive, out.isLockShape

  -- Render the selected spline (nodes, polyline, gizmo).
  local selSpline = splines[out.spline]
  if selSpline then
    rSpline.handleSplineRendering(splines, out.spline, out.node, isGizmoActive, true, isLockShape, true, false, elevScale)
    rSpline.renderSplinePolylines(splines, out.spline)
  end
end

-- Serialise: snapshot the spline definitions, then remove the planted instances so no orphans survive the Lua
-- VM reload; onDeserialized re-plants them. A locked spline's trees (and any hand edits) stay in the forest instead: it carries
-- their keys across and takes them back.
local function onSerialize()
  local splines = splineMgr.getTreeSplines()
  for i = 1, #splines do
    if not splines[i].isEnabled then splines[i].keptObjects = pop.release(splines[i]) end
  end
  local s = splineMgr.getState()
  splineMgr.removeAllTreeSplines(true)
  return s
end

local function onDeserialized(data)
  if data then splineMgr.setState(data) end -- flags splines dirty -> re-plant on next onEditorGui tick
end

local function onActivate()
  isActive = true
  fPicker.refresh()
  scatter.ensureForest()
  editor.clearObjectSelection()
  editor.showWindow(toolWinName)
  if #splineMgr.getTreeSplines() > 0 and selectedSplineIdx < 1 then selectedSplineIdx = 1 end
  panCamera.configure({ focusProvider = function()
    local s = splineMgr.getTreeSplines()[selectedSplineIdx]
    return s and (#s.divPoints > 1 and s.divPoints or s.nodes)
  end })
end

local function onDeactivate()
  isActive = false
  editor.hideWindow(toolWinName)
  panCamera.close()
end

local function onEditorInitialized()
  editor.editModes.treeSplineEditMode = {
    displayName = splineMgr.getToolPrefixStr(),
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    icon = editor.icons.forest_snap_terrain,
    iconTooltip = "TreeSpline",
    auxShortcuts = {},
    hideObjectIcons = true }
  editor.registerWindow(toolWinName, toolWinSize)
end

local function onClientEndMission()
  lifted = nil
  splineMgr.removeAllTreeSplines(true)
end

-- Only locked splines' trees are the level's. The live ones go back on the next frame, after every save hook has run.
local function onEditorBeforeSaveLevel()
  if lifted then return end
  local lists, splines = {}, splineMgr.getTreeSplines()
  for i = 1, #splines do
    if splines[i].items and splines[i].isEnabled then lists[#lists + 1] = splines[i].items end
  end
  lifted = scatter.lift(lists)
end


-- Public interface.
M.setSelectedSplineIdx = setSelectedSplineIdx
M.setSelectedNodeIdx = setSelectedNodeIdx
M.setLockedById = setLockedById
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
M.onEditorBeforeSaveLevel = onEditorBeforeSaveLevel
M.onClientEndMission = onClientEndMission

return M