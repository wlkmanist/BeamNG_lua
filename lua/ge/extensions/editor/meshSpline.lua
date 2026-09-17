-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local simplifyRdpTol = 9.0 -- The tolerance for the RDP simplification of the spline.

local minSpacing, maxSpacing = -0.2, 40.0 -- The minimum and maximum allowed spacing of the mesh components.
local minVerticalOffset, maxVerticalOffset = -100.0, 100.0 -- The minimum and maximum allowed vertical offset of the mesh components.
local DOImin, DOImax = 0.0, 500.0
local terraMarginMin, terraMarginMax = 1.0, 20.0
local terraFalloffMin, terraFalloffMax = 1.0, 5.0

local maxRandomSeed = 1000 -- The maximum allowed random seed value, in [0, maxRandomSeed].

local defaultSplineWidth = 10.0 -- The default width for a spline when adding a new node, in meters.

local elevScale = 100.0 -- The scale factor for the elevation drop lines (used for blue->red colour transition).

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- External modules.
local splineMgr = require('editor/meshSpline/splineMgr')
local pop = require('editor/meshSpline/populate')
local import = require('editor/meshSpline/import')
local input = require('editor/toolUtilities/splineInput')
local render = require('editor/toolUtilities/render')
local poly = require('editor/toolUtilities/polygon')
local skeleton = require('editor/toolUtilities/skeleton')
local rdp = require('editor/toolUtilities/rdp')
local maskExport = require('editor/toolUtilities/splineMaskExport')
local util = require('editor/toolUtilities/util')
local geom = require('editor/toolUtilities/geom')
local style = require('editor/toolUtilities/style')
local meshAuditionMgr = require('editor/toolUtilities/meshAuditionMgr')
local terra = require('editor/terraform/terraform')

-- Module constants.
local im = ui_imgui
local abs, min, max = math.abs, math.min, math.max
local toolWinName, toolWinSize = 'meshSpline', im.ImVec2(300, 700)
local defaultParams = splineMgr.getDefaultSliderParams()
local cols = style.getImguiCols('crystal')
local iconsSmall, iconsBig = im.ImVec2(24, 24), im.ImVec2(36, 36)

-- Module state.
local isMeshSplineActive = false
local isDrawPolygon = false
local isGizmoActive = false
local isLockShape = false
local selectedSplineIdx, selectedNodeIdx, selectedMeshIdx = 1, 1, 1
local meshTarget = 'main'
local sliderPreEditState = nil
local terraParams = {
  terraDOI = 50.0,
  terraMargin = 5.0,
  terraFalloff = 2.0,
  terraRoughness = 0.0,
  terraScale = 0.0,
}
local out = {
  spline = selectedSplineIdx,
  node = selectedNodeIdx,
  isGizmoActive = isGizmoActive,
  isLockShape = isLockShape,
}

-- Register this tool with the shared spline input utilities.
input.registerSplineTool(
  splineMgr.getToolPrefixStr(),
  splineMgr.getMeshSplines,
  splineMgr.getEditModeKey,
  splineMgr.deepCopyMeshSpline,
  splineMgr.deepCopyMeshSplineState,
  'editor_meshSpline'
)


-- Sets the selected spline index (for cross-tool selection).
local function setSelectedSplineIdx(idx) selectedSplineIdx = idx end

-- Sets the selected node index (for cross-tool selection).
local function setSelectedNodeIdx(idx) selectedNodeIdx = idx end

-- Serialise callback.
local function onSerialize()
  local meshSplines = splineMgr.getMeshSplines()
  if #meshSplines < 1 then
    return {} -- Return an empty table if there are no mesh splines.
  end
  meshAuditionMgr.leaveAuditionView()
  local meshSplinesSer = {}
  for i = 1, #meshSplines do
    local spline = meshSplines[i]
    local data = splineMgr.serializeMeshSpline(spline)
    meshSplinesSer[#meshSplinesSer + 1] = data
  end
  splineMgr.removeAllMeshSplines()
  return meshSplinesSer
end

-- Deserialise callback.
local function onDeserialized(data)
  if data and #data > 0 then
    local meshSplines = splineMgr.getMeshSplines()
    table.clear(meshSplines)
    for i = 1, #data do
      local spline = splineMgr.deserializeMeshSpline(data[i], true)
      meshSplines[#meshSplines + 1] = spline
    end
    selectedSplineIdx = max(1, min(#meshSplines, selectedSplineIdx))

    -- Update the spline map.
    util.computeIdToIdxMap(meshSplines, splineMgr.getSplineMap())
  end
end

-- Callback for when a static mesh is selected in the mesh audition manager.
local function onMeshSelected(auditionMesh, path)
  local box = auditionMesh:getObjBox()
  local worldBox = auditionMesh:getWorldBox()
  local center = auditionMesh:getPosition()
  local minExtents, maxExtents = worldBox.minExtents, worldBox.maxExtents
  local extents = box:getExtents()

  local splines = splineMgr.getMeshSplines()
  local selSpline = splines[selectedSplineIdx]
  local statePre = splineMgr.deepCopyMeshSpline(selSpline)

  if meshTarget == 'main' then
    selSpline.centerMeshPath = path
    selSpline.centerMeshName = path:match("([^/]+)$")
    selSpline.mainComponentPath = string.format('main_%s', path)
    selSpline.boxXLeft_Center, selSpline.boxXRight_Center = center.x - minExtents.x, maxExtents.x - center.x
    selSpline.boxYLeft_Center, selSpline.boxYRight_Center = center.y - minExtents.y, maxExtents.y - center.y
    selSpline.boxZLeft_Center, selSpline.boxZRight_Center = center.z - minExtents.z, maxExtents.z - center.z
    selSpline.extentsL_Center, selSpline.extentsW_Center, selSpline.extentsZ_Center = extents.x, extents.y, extents.z

    -- Determine the main axis (longest dimension)
    local isLongX = extents.x >= extents.y
    local boxCenter = worldBox:getCenter()

    -- Check if the mesh origin is near the center of the bounding box.
    local originToCenterDistance = isLongX and abs(center.x - boxCenter.x) or abs(center.y - boxCenter.y)
    selSpline.isCenteredLeft = originToCenterDistance > 0.01

    -- Pick the rotation from the two valid candidates.
    if not selSpline.isCenteredLeft then
      selSpline.rot = isLongX and 2 or 3
    else
      selSpline.rot = isLongX and 0 or 1
    end
  elseif meshTarget == 'alias1' then
    selSpline.alias1MeshPath = path
    selSpline.alias1MeshName = path:match("([^/]+)$")
    selSpline.alias1ComponentPath = string.format('alias1_%s', path)
  elseif meshTarget == 'alias2' then
    selSpline.alias2MeshPath = path
    selSpline.alias2MeshName = path:match("([^/]+)$")
    selSpline.alias2ComponentPath = string.format('alias2_%s', path)
  elseif meshTarget == 'alias3' then
    selSpline.alias3MeshPath = path
    selSpline.alias3MeshName = path:match("([^/]+)$")
    selSpline.alias3ComponentPath = string.format('alias3_%s', path)
  elseif meshTarget == 'start' then
    selSpline.startCapMeshPath = path
    selSpline.startCapMeshName = path:match("([^/]+)$")
    selSpline.startCapComponentPath = string.format('startCap_%s', path)
  elseif meshTarget == 'end' then
    selSpline.endCapMeshPath = path
    selSpline.endCapMeshName = path:match("([^/]+)$")
    selSpline.endCapComponentPath = string.format('endCap_%s', path)
  end

  pop.tryRemove(selSpline)
  selSpline.isDirty = true
  editor.history:commitAction("Select Static Mesh", { old = statePre, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.objectSelectUndo, splineMgr.objectSelectRedo, true)
end

-- Handles the main tool window.
local function handleMainToolWindowUI()
  if editor.beginWindow(toolWinName, "Mesh Spline###1144", im.WindowFlags_NoCollapse) then
    local icons = editor.icons
    local meshSplines = splineMgr.getMeshSplines()
    selectedSplineIdx = max(1, min(#meshSplines, selectedSplineIdx)) -- Ensure the selected spline index is within bounds.

    -- Top buttons row.
    im.Columns(6, "topMasterButtonsRow", false)
    im.SetColumnWidth(0, 39)
    im.SetColumnWidth(1, 39)
    im.SetColumnWidth(2, 39)
    im.SetColumnWidth(3, 39)
    im.SetColumnWidth(4, 39)
    im.SetColumnWidth(5, 39)
    im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
    im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

    -- 'Add New Mesh Spline' button.
    if editor.uiIconImageButton(icons.bSpline, iconsBig, cols.blueB, nil, nil, 'addNewMeshSplineBtn') then
      local statePre = splineMgr.deepCopyMeshSplineState()
      splineMgr.addNewMeshSpline()
      selectedSplineIdx = #meshSplines
      editor.history:commitAction("Add New Mesh Spline", { old = statePre, new = splineMgr.deepCopyMeshSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
    end
    im.tooltip('Add a new mesh spline.')
    im.SameLine()
    im.NextColumn()

    -- 'Import From Bitmap Mask' button.
    if editor.uiIconImageButton(icons.floppyDiskPlus, iconsBig, cols.blueB, nil, nil, 'importFromBitmapMaskBtn') then
      extensions.editor_fileDialog.openFile(
        function(data)
          if data.filepath then
            local paths = skeleton.getPathsFromPng(data.filepath)
            if #paths > 0 then
              local preState = splineMgr.deepCopyMeshSplineState()
              splineMgr.convertPathsToMeshSplines(paths)
              editor.history:commitAction("Import Mesh Splines From Bitmap", { old = preState, new = splineMgr.deepCopyMeshSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
            end
          end
        end,
        {{"PNG",".png"}},
        false,
        "/")
    end
    im.tooltip('Import mesh splines from a bitmap mask.')
    im.SameLine()
    im.NextColumn()

    -- 'Draw A Selection Polygon' button.
    local btnCol = isDrawPolygon and cols.blueB or cols.blueD
    if editor.uiIconImageButton(icons.rounded_corner, iconsBig, btnCol, nil, nil, 'drawPolygonBtn') then
      isDrawPolygon = not isDrawPolygon
      poly.clearPolygon() -- Ensure there is no residual polygon left over from the previous usage.
    end
    im.tooltip(isDrawPolygon and 'Click to stop drawing a selection polygon.' or 'Click to draw a selection polygon, to convert scene objects to a Mesh Spline.')
    im.SameLine()
    im.NextColumn()

    -- 'Remove All Mesh Splines' button.
    if #meshSplines > 0 then
      if editor.uiIconImageButton(icons.trashBin2, iconsBig, cols.blueB, nil, nil, 'removeAllMeshSplinesBtn') then
        local statePre = splineMgr.deepCopyMeshSplineState()
        splineMgr.removeAllMeshSplines(false)
        selectedSplineIdx = 1
        editor.history:commitAction("Remove All Mesh Splines", { old = statePre, new = splineMgr.deepCopyMeshSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
      end
      im.tooltip('Remove all (enabled and not linked) mesh splines from the session.')
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Lock Shape' toggle button.
    local selSpline = meshSplines[selectedSplineIdx]
    if #meshSplines > 0 and selSpline and selSpline.isEnabled and not selSpline.isLink then
      btnCol = isLockShape and cols.blueB or cols.blueD
      if editor.uiIconImageButton(icons.roadGuideArrowSolid, iconsBig, btnCol, nil, nil, 'lockShapeBtn') then
        isLockShape = not isLockShape
      end
      im.tooltip((isLockShape and 'Unlock the shape of the mesh spline to move nodes separately' or 'Lock the shape of the mesh spline to move nodes rigidly'))
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Export Spline Mask' button.
    if #meshSplines > 0 then
      if editor.uiIconImageButton(icons.folder, iconsBig, cols.blueB, nil, nil, 'exportSplineMaskBtn') then
        local sources = util.getAllSources(meshSplines)
        extensions.editor_fileDialog.saveFile(
          function(data)
            maskExport.export(data.filepath, sources, 1.0) -- TODO: Uses a 1m margin. Maybe make this a parameter later.
          end,
          {{"PNG",".png"}},
          false,
          "/",
          "File already exists.\nDo you want to overwrite the file?")
      end
      im.tooltip('Export the session as a .PNG mask file. Will not include any disabled Mesh Splines.')
    else
      im.Dummy(iconsBig)
    end
    im.NextColumn()

    im.PopStyleVar(2)
    im.Columns(1)
    im.Separator()

    -- Mesh splines list.
    if #meshSplines > 0 then
      im.TextColored(cols.greenB, "Mesh Splines:")
      im.PushItemWidth(-1)
      if im.BeginListBox('', im.ImVec2(-1, 180)) then
        im.Columns(4, "splineListBoxColumns", true)
        im.SetColumnWidth(0, 30)
        im.SetColumnWidth(1, 180)
        im.SetColumnWidth(2, 35)
        im.SetColumnWidth(3, 35)
        im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(4, 2))
        im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
        local wCtr = 41225
        for i = 1, #meshSplines do
          local spline = meshSplines[i]
          local flag = i == selectedSplineIdx
          if im.Selectable1("###" .. tostring(wCtr), flag, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
            selectedSplineIdx = i
            spline.isDirty = true
          end
          wCtr = wCtr + 1
          im.SameLine()
          im.NextColumn()

          im.PushItemWidth(180)
          local splineNamePtr = im.ArrayChar(32, spline.name)
          if spline.isLink then
            im.TextColored(cols.dullWhite, spline.name)
            im.tooltip('This mesh spline is linked to a Master Spline. To edit or remove it, first unlink it from within the Master Spline Editor.')
          elseif not spline.isEnabled then
            im.TextColored(cols.dullWhite, spline.name)
            im.tooltip('This mesh spline is disabled. To edit or remove it, first enable it.')
          else
            if im.InputText("###" .. tostring(wCtr), splineNamePtr, 32) then
              spline.name = ffi.string(splineNamePtr)
              if spline.sceneTreeFolderId then
                local folder = scenetree.findObjectById(spline.sceneTreeFolderId)
                if folder then
                  local preState = splineMgr.deepCopyMeshSpline(spline)
                  folder:setName(spline.name)
                  editor.refreshSceneTreeWindow()
                  spline.isDirty = true -- Ensures the mesh names are updated in the scene tree.
                  local postState = splineMgr.deepCopyMeshSpline(spline)
                  preState.isUpdateSceneTree = true
                  postState.isUpdateSceneTree = true
                  editor.history:commitAction("Edit Mesh Spline Name", { old = preState, new = postState }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
              end
            end
            im.tooltip('Edit the mesh spline name.')
            if im.IsItemActive() then
              selectedSplineIdx = i
            end
          end
          im.PopItemWidth()
          wCtr = wCtr + 1
          im.SameLine()
          im.NextColumn()

          -- 'Remove Selected Spline' button.
          if spline.isEnabled and not spline.isLink then
            if editor.uiIconImageButton(icons.trashBin2, iconsSmall, cols.blueB, nil, nil, 'removeSpline' .. i) then
              local statePre = splineMgr.deepCopyMeshSplineState()
              splineMgr.removeMeshSpline(i)
              if selectedSplineIdx > i then
                selectedSplineIdx = selectedSplineIdx - 1
              end
              selectedSplineIdx = max(1, min(#meshSplines, selectedSplineIdx))
              editor.history:commitAction("Remove Mesh Spline", { old = statePre, new = splineMgr.deepCopyMeshSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
              editor.endWindow()
              return
            end
            im.tooltip('Remove this mesh spline from the session.')
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()
          im.NextColumn()

          -- 'Enable/Disable' button.
          if not spline.isLink then
            btnCol = spline.isEnabled and cols.blueB or cols.blueD
            local btnIcon = spline.isEnabled and icons.lock or icons.lock_open
            if editor.uiIconImageButton(btnIcon, iconsSmall, btnCol, nil, nil, 'lockUnlockMeshSplineToggleBtn' .. i) then
              local statePre = splineMgr.deepCopyMeshSpline(spline)
              spline.isEnabled = not spline.isEnabled
              pop.tryRemove(spline) -- Remove the mesh spline from the population, before rebuilding the collision mesh.
              spline.isDirty = true
              selectedSplineIdx = i
              editor.history:commitAction("Toggle Mesh Spline Lock", { old = statePre, new = splineMgr.deepCopyMeshSpline(spline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
            end
            im.tooltip((spline.isEnabled and 'Disable' or 'Enable') .. ' this mesh spline.')
          else
            im.Dummy(iconsSmall)
          end
          im.NextColumn()
          im.Separator()
        end
        im.PopStyleVar(2)
        im.EndListBox()
      end
      im.PopItemWidth() -- Pop the item width pushed for the mesh splines list box.
      im.Separator()

      -- Buttons underneath the mesh splines list box.
      im.Columns(8, "buttonsUnderneathListBox", false)
      im.SetColumnWidth(0, 40)
      im.SetColumnWidth(1, 40)
      im.SetColumnWidth(2, 40)
      im.SetColumnWidth(3, 40)
      im.SetColumnWidth(4, 40)
      im.SetColumnWidth(5, 40)
      im.SetColumnWidth(6, 40)
      im.SetColumnWidth(7, 40)
      im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
      im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

      -- 'Go To Selected Spline' button.
      if selSpline.nodes and #selSpline.nodes > 1 then
        if editor.uiIconImageButton(icons.cameraFocusTopDown, iconsBig, cols.blueB, nil, nil, 'goToSelectedSplineBtn') then
          util.goToSpline(selSpline.divPoints)
        end
        im.tooltip('Go to this mesh spline (move camera).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Conform To Surface Below' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink then
        btnCol = selSpline.isConformToTerrain and cols.blueB or cols.blueD
        if editor.uiIconImageButton(icons.lineToTerrain, iconsBig, btnCol, nil, nil, 'conformToTerrainBtn') then
          local statePre = splineMgr.deepCopyMeshSpline(selSpline)
          selSpline.isConformToTerrain = not selSpline.isConformToTerrain
          selSpline.isDirty = true
          editor.history:commitAction("Conform To Surface Below", { old = statePre, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip((selSpline.isConformToTerrain and 'Unconform' or 'Conform') .. ' the selected mesh spline to the surface below.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Normal Mode' three-state toggle button.
      if selSpline and selSpline.isEnabled then
        local btnIcon
        if selSpline.normalMode == 0 then
          btnIcon = icons.align_local -- Local up (spline normals).
        elseif selSpline.normalMode == 1 then
          btnIcon = icons.align_world -- Global up (world Z-axis).
        else
          btnIcon = icons.forest_snap_terrain -- Terrain up.
        end
        if editor.uiIconImageButton(btnIcon, iconsBig, cols.blueB, nil, nil, 'normalModeBtn') then
          local statePre = splineMgr.deepCopyMeshSpline(selSpline)
          selSpline.normalMode = (selSpline.normalMode + 1) % 3 -- Cycle through 0, 1, 2.
          selSpline.isDirty = true
          editor.history:commitAction("Toggle Normal Mode", { old = statePre, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        -- Dynamic tooltip showing current mode and what clicking will do next.
        local tooltipText
        if selSpline.normalMode == 0 then
          tooltipText = "Local Up (Click for Global Up)"
        elseif selSpline.normalMode == 1 then
          tooltipText = "Global Up (Click for Terrain Up)"
        else
          tooltipText = "Terrain Up (Click for Local Up)"
        end
        im.tooltip(tooltipText)
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Split Mesh Spline' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink and selSpline.nodes[selectedNodeIdx] and #selSpline.nodes > 2 and (selSpline.isLoop or (selectedNodeIdx > 1 and selectedNodeIdx < #selSpline.nodes)) then
        if editor.uiIconImageButton(icons.content_cut, iconsBig, cols.blueB, nil, nil, 'splitMeshSplineBtn') then
          local statePre = splineMgr.deepCopyMeshSplineState()
          splineMgr.splitMeshSpline(selectedSplineIdx, selectedNodeIdx)
          selectedSplineIdx = #meshSplines
          editor.history:commitAction("Split New Mesh Spline", { old = statePre, new = splineMgr.deepCopyMeshSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
        end
        im.tooltip('Splits the selected mesh spline into two, at the selected node.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Flip Direction' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink and #selSpline.nodes > 1 then
        if editor.uiIconImageButton(icons.cached, iconsBig, cols.blueB, nil, nil, 'flipDirectionBtn') then
          local statePre = splineMgr.deepCopyMeshSpline(selSpline)
          geom.flipSplineDirection(selSpline)
          selSpline.isDirty = true
          editor.history:commitAction("Flip Mesh Spline Direction", { old = statePre, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip('Flips the direction of the selected mesh spline (back to front).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Simplify Spline' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink and selSpline.nodes[selectedNodeIdx] and #selSpline.nodes > 2 then
        if editor.uiIconImageButton(icons.routeSimple, iconsBig, cols.blueB, nil, nil, 'simplifySplineBtn') then
          local statePre = splineMgr.deepCopyMeshSpline(selSpline)
          rdp.simplifyNodesWidthsNormals(selSpline.nodes, selSpline.widths, selSpline.nmls, simplifyRdpTol)
          selectedNodeIdx = max(1, min(#selSpline.nodes, selectedNodeIdx))
          selSpline.isDirty = true
          editor.history:commitAction("Simplify Mesh Spline", { old = statePre, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip('Simplifies the selected mesh spline (reduces the number of nodes).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- Save template button.
      if selSpline.isEnabled then
        if editor.uiIconImageButton(icons.floppyDisk, iconsBig, nil, nil, nil, 'saveTemplateBtn') then
          extensions.editor_fileDialog.saveFile(
            function(data)
              jsonWriteFile(data.filepath, splineMgr.copyMeshSplineProfile(selSpline), true)
            end,
            {{"JSON",".json"}},
            false,
            "/",
            "File already exists.\nDo you want to overwrite the file?")
        end
        im.tooltip('Saves the template of the selected mesh spline to disk.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- Load template button.
      if selSpline.isEnabled then
        if editor.uiIconImageButton(icons.roadFolder, iconsBig, cols.dullWhite, nil, nil, 'loadTemplateBtn') then
          extensions.editor_fileDialog.openFile(
            function(data)
              local preState = splineMgr.deepCopyMeshSpline(selSpline)
              splineMgr.pasteMeshSplineProfile(selSpline, jsonReadFile(data.filepath))
              editor.history:commitAction("Load Mesh Spline Template", { old = preState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
            end,
            {{"JSON",".json"}},
            false,
            "/")
        end
        im.tooltip('Sets the selected mesh spline to a template loaded from disk.')
      else
        im.Dummy(iconsBig)
      end
      im.NextColumn()
      im.PopStyleVar(2)
      im.Separator()
      im.Columns(1)

      -- If the selected spline is disabled, don't show the tabs.
      if not selSpline or not selSpline.isEnabled then
        editor.endWindow()
        return
      end

      -- Mesh Spline Properties (always visible).
      im.TextColored(cols.greenB, "Properties:")

      im.PushItemWidth(-1)
      im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
      im.Columns(2, 'spacingAndJitterCols', false)
      im.SetColumnWidth(0, 30)

      -- Spacing slider.
      if selSpline.spacing ~= defaultParams.spacing then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetSpacingBtn') then
          local preEditState = splineMgr.deepCopyMeshSpline(selSpline)
          selSpline.spacing = defaultParams.spacing
          selSpline.isDirty = true
          editor.history:commitAction("Reset Spacing", { old = preEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      local tmpPtr = im.FloatPtr(selSpline.spacing)
      if im.SliderFloat('###5756', tmpPtr, minSpacing, maxSpacing, "Spacing (m) = %.2f") then
        selSpline.spacing = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the longitudinal spacing between each mesh component.')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyMeshSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Spacing", { old = sliderPreEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      -- Vertical Offset slider.
      if selSpline.verticalOffset ~= defaultParams.verticalOffset then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetVerticalOffsetBtn') then
          local preEditState = splineMgr.deepCopyMeshSpline(selSpline)
          selSpline.verticalOffset = defaultParams.verticalOffset
          selSpline.isDirty = true
          editor.history:commitAction("Reset Vertical Offset", { old = preEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      tmpPtr = im.FloatPtr(selSpline.verticalOffset)
      if im.SliderFloat('###27456', tmpPtr, minVerticalOffset, maxVerticalOffset, "Vertical Offset (m) = %.2f") then
        selSpline.verticalOffset = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the vertical offset of the mesh components, in meters.')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyMeshSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Vertical Offset", { old = sliderPreEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      -- Jitter forward slider.
      if selSpline.jitterForward ~= defaultParams.jitterForward then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetJitterForwardBtn') then
          local preEditState = splineMgr.deepCopyMeshSpline(selSpline)
          selSpline.jitterForward = defaultParams.jitterForward
          selSpline.isDirty = true
          editor.history:commitAction("Reset Pitch Jitter", { old = preEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      tmpPtr = im.FloatPtr(selSpline.jitterForward)
      if im.SliderFloat('###5757', tmpPtr, 0.0, 0.2, "Pitch Jitter = %.3f") then
        selSpline.jitterForward = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the amount of random jitter to apply to the mesh components, around the local Y-axis (pitch) .')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyMeshSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Pitch Jitter", { old = sliderPreEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      -- Jitter right slider.
      if selSpline.jitterRight ~= defaultParams.jitterRight then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetJitterRightBtn') then
          local preEditState = splineMgr.deepCopyMeshSpline(selSpline)
          selSpline.jitterRight = defaultParams.jitterRight
          selSpline.isDirty = true
          editor.history:commitAction("Reset Yaw Jitter", { old = preEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      tmpPtr = im.FloatPtr(selSpline.jitterRight)
      if im.SliderFloat('###5758', tmpPtr, 0.0, 0.2, "Yaw Jitter = %.3f") then
        selSpline.jitterRight = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the amount of random jitter to apply to the mesh components, around the local X-axis (yaw).')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyMeshSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Yaw Jitter", { old = sliderPreEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      -- Jitter up slider.
      if selSpline.jitterUp ~= defaultParams.jitterUp then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetJitterUpBtn') then
          local preEditState = splineMgr.deepCopyMeshSpline(selSpline)
          selSpline.jitterUp = defaultParams.jitterUp
          selSpline.isDirty = true
          editor.history:commitAction("Reset Roll Jitter", { old = preEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      tmpPtr = im.FloatPtr(selSpline.jitterUp)
      if im.SliderFloat('###5759', tmpPtr, 0.0, 0.2, "Roll Jitter = %.3f") then
        selSpline.jitterUp = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the amount of random jitter to apply to the mesh components, around the local Z-axis (roll).')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyMeshSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Roll Jitter", { old = sliderPreEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      -- Spline Random Seed slider.
      if selSpline.splineRandomSeed ~= defaultParams.splineRandomSeed then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetSplineRandomSeedBtn') then
          local preEditState = splineMgr.deepCopyMeshSpline(selSpline)
          selSpline.splineRandomSeed = defaultParams.splineRandomSeed
          selSpline.isDirty = true
          editor.history:commitAction("Reset Random Seed", { old = preEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      tmpPtr = im.IntPtr(selSpline.splineRandomSeed)
      if im.SliderInt('###5760', tmpPtr, 0, maxRandomSeed, "Random Seed = %d") then
        selSpline.splineRandomSeed = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the random seed for the spline jitter and placement.')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyMeshSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Spline Random Seed", { old = sliderPreEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()
      im.PopStyleVar()
      im.PopItemWidth() -- Pop the item width pushed for the properties section.
      im.Columns(1)
      im.Separator()

      -- Preset buttons.
      im.TextColored(cols.greenB, "Presets:")
      im.Columns(7, "presetBtns", false)
      im.SetColumnWidth(0, 40)
      im.SetColumnWidth(1, 40)
      im.SetColumnWidth(2, 40)
      im.SetColumnWidth(3, 40)
      im.SetColumnWidth(4, 40)
      im.SetColumnWidth(5, 40)
      im.SetColumnWidth(6, 40)
      im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
      im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

      -- 'Concrete Barrier' preset button.
      if editor.uiIconImageButton(icons.concreteRoadBlock, iconsBig, cols.blueB, nil, nil, 'concreteBarrierPresetBtn') then
        local preEditState = splineMgr.deepCopyMeshSpline(selSpline)
        splineMgr.setPreset(selSpline, 'concrete_barrier')
        selSpline.isDirty = true
        editor.history:commitAction("Select Concrete Barrier Preset", { old = preEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.presetSelectionUndo, splineMgr.presetSelectionRedo, true)
      end
      im.tooltip('Select The Concrete Barrier Preset.')
      im.SameLine()
      im.NextColumn()

      -- 'Plastic Barrier' preset button.
      if editor.uiIconImageButton(icons.roadblockL, iconsBig, cols.blueB, nil, nil, 'plasticBarrierPresetBtn') then
        local preEditState = splineMgr.deepCopyMeshSpline(selSpline)
        splineMgr.setPreset(selSpline, 'plastic_barrier')
        selSpline.isDirty = true
        editor.history:commitAction("Select Plastic Barrier Preset", { old = preEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.presetSelectionUndo, splineMgr.presetSelectionRedo, true)
      end
      im.tooltip('Select The Plastic Barrier Preset.')
      im.SameLine()
      im.NextColumn()

      -- 'Metal Fence' preset button.
      if editor.uiIconImageButton(icons.meshFence, iconsBig, cols.blueB, nil, nil, 'metalFencePresetBtn') then
        local preEditState = splineMgr.deepCopyMeshSpline(selSpline)
        splineMgr.setPreset(selSpline, 'metal_fence')
        selSpline.isDirty = true
        editor.history:commitAction("Select Metal Fence Preset", { old = preEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.presetSelectionUndo, splineMgr.presetSelectionRedo, true)
      end
      im.tooltip('Select The Metal Fence Preset.')
      im.SameLine()
      im.NextColumn()

      -- 'Mast Arm Lamp Post' preset button.
      if editor.uiIconImageButton(icons.lampPost2, iconsBig, cols.blueB, nil, nil, 'mastArmLampPostPresetBtn') then
        local preEditState = splineMgr.deepCopyMeshSpline(selSpline)
        splineMgr.setPreset(selSpline, 'mast_arm_lamp_post')
        selSpline.isDirty = true
        editor.history:commitAction("Select Mast Arm Lamp Post Preset", { old = preEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.presetSelectionUndo, splineMgr.presetSelectionRedo, true)
      end
      im.tooltip('Select The Mast Arm Lamp Post Preset.')
      im.SameLine()
      im.NextColumn()

      -- 'Victorian Lamp Post' preset button.
      if editor.uiIconImageButton(icons.lampPost3, iconsBig, cols.blueB, nil, nil, 'victorianLampPostPresetBtn') then
        local preEditState = splineMgr.deepCopyMeshSpline(selSpline)
        splineMgr.setPreset(selSpline, 'victorian_lamp_post')
        selSpline.isDirty = true
        editor.history:commitAction("Select Victorian Lamp Post Preset", { old = preEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.presetSelectionUndo, splineMgr.presetSelectionRedo, true)
      end
      im.tooltip('Select The Victorian Lamp Post Preset.')
      im.SameLine()
      im.NextColumn()

      -- 'Bollard' preset button.
      if editor.uiIconImageButton(icons.bollard, iconsBig, cols.blueB, nil, nil, 'bollardPresetBtn') then
        local preEditState = splineMgr.deepCopyMeshSpline(selSpline)
        splineMgr.setPreset(selSpline, 'bollard')
        selSpline.isDirty = true
        editor.history:commitAction("Select Bollard Preset", { old = preEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.presetSelectionUndo, splineMgr.presetSelectionRedo, true)
      end
      im.tooltip('Select The Bollard Preset.')
      im.SameLine()
      im.NextColumn()

      -- 'Oil Drum' preset button.
      if editor.uiIconImageButton(icons.fg_barrel, iconsBig, cols.blueB, nil, nil, 'oilDrumPresetBtn') then
        local preEditState = splineMgr.deepCopyMeshSpline(selSpline)
        splineMgr.setPreset(selSpline, 'oil_drum')
        selSpline.isDirty = true
        editor.history:commitAction("Select Oil Drum Preset", { old = preEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.presetSelectionUndo, splineMgr.presetSelectionRedo, true)
      end
      im.tooltip('Select The Oil Drum Preset.')
      im.NextColumn()
      im.PopStyleVar(2)
      im.Separator()
      im.Columns(1)

      -- Tab bar.
      local selectedTab = 0 -- Default to first tab.
      if im.BeginTabBar("MeshSplineTabs") then
        if im.BeginTabItem("Components") then
          selectedTab = 0
          im.EndTabItem()
        end
        if im.BeginTabItem("Distribution") then
          selectedTab = 1
          im.EndTabItem()
        end
        if im.BeginTabItem("Terrain") then
          selectedTab = 2
          im.EndTabItem()
        end
        im.EndTabBar()
      end

      -- Tab content.
      im.PushStyleVar2(im.StyleVar_WindowPadding, im.ImVec2(4, 8))
      if im.BeginChild1("TabContentChild", im.ImVec2(0, 0), true) then
        if selectedTab == 0 then -- Components tab.
          -- Static mesh selection panel.
          im.TextColored(cols.greenB, "Components:")
          im.Columns(4, "staticMeshSelectionColumns", false)
          im.SetColumnWidth(0, 40)
          im.SetColumnWidth(2, 40)
          im.Dummy(iconsBig)
          im.SameLine()
          im.NextColumn()
          im.Text('Main:')
          im.SameLine()
          im.NextColumn()
          if editor.uiIconImageButton(icons.youtube_searched_for, iconsSmall, cols.blueB, nil, nil, 'selectMainComponentMatBtn') then
            meshTarget = 'main'
            meshAuditionMgr.addMeshToAudition(selectedMeshIdx, nil)
          end
          im.tooltip('Select a new static mesh for the main component.')
          im.SameLine()
          im.NextColumn()
          im.SetCursorPosY(im.GetCursorPosY() + max(0, (iconsSmall.y - im.GetTextLineHeight()) * 0.5))
          im.Text(('[' ..selSpline.centerMeshName .. ']') or '[Not Set]')
          im.tooltip('The currently-selected static mesh for the main component.')
          im.NextColumn()

          local tmpPtr = im.BoolPtr(selSpline.isAlias1)
          if im.Checkbox("###87651", tmpPtr) then
            selSpline.isAlias1 = tmpPtr[0]
            selSpline.isDirty = true
            pop.tryRemove(selSpline)
          end
          im.tooltip('Select whether to include an variation 1 component (a variation of the main component).')
          im.SameLine()
          im.NextColumn()
          im.Text('Variation 1:')
          im.SameLine()
          im.NextColumn()
          if editor.uiIconImageButton(icons.youtube_searched_for, iconsSmall, cols.blueB, nil, nil, 'selectAlias1ComponentMatBtn') then
            meshTarget = 'alias1'
            meshAuditionMgr.addMeshToAudition(selectedMeshIdx, nil)
          end
          im.tooltip('Select a new static mesh for the variation 1 component.')
          im.SameLine()
          im.NextColumn()
          im.SetCursorPosY(im.GetCursorPosY() + max(0, (iconsSmall.y - im.GetTextLineHeight()) * 0.5))
          im.Text(('[' ..selSpline.alias1MeshName .. ']') or '[Not Set]')
          im.tooltip('The currently-selected static mesh for the variation 1 component.')
          im.NextColumn()

          tmpPtr = im.BoolPtr(selSpline.isAlias2)
          if im.Checkbox("###87652", tmpPtr) then
            selSpline.isAlias2 = tmpPtr[0]
            selSpline.isDirty = true
            pop.tryRemove(selSpline)
          end
          im.tooltip('Select whether to include an variation 2 component (a variation of the main component).')
          im.SameLine()
          im.NextColumn()
          im.Text('Variation 2:')
          im.SameLine()
          im.NextColumn()
          if editor.uiIconImageButton(icons.youtube_searched_for, iconsSmall, cols.blueB, nil, nil, 'selectAlias2ComponentMatBtn') then
            meshTarget = 'alias2'
            meshAuditionMgr.addMeshToAudition(selectedMeshIdx, nil)
          end
          im.tooltip('Select a new static mesh for the variation 2 component.')
          im.SameLine()
          im.NextColumn()
          im.SetCursorPosY(im.GetCursorPosY() + max(0, (iconsSmall.y - im.GetTextLineHeight()) * 0.5))
          im.Text(('[' ..selSpline.alias2MeshName .. ']') or '[Not Set]')
          im.tooltip('The currently-selected static mesh for the variation 2 component.')
          im.NextColumn()

          tmpPtr = im.BoolPtr(selSpline.isAlias3)
          if im.Checkbox("###87653", tmpPtr) then
            selSpline.isAlias3 = tmpPtr[0]
            selSpline.isDirty = true
            pop.tryRemove(selSpline)
          end
          im.tooltip('Select whether to include an variation 3 component (a variation of the main component).')
          im.SameLine()
          im.NextColumn()
          im.Text('Variation 3:')
          im.SameLine()
          im.NextColumn()
          if editor.uiIconImageButton(icons.youtube_searched_for, iconsSmall, cols.blueB, nil, nil, 'selectAlias3ComponentMatBtn') then
            meshTarget = 'alias3'
            meshAuditionMgr.addMeshToAudition(selectedMeshIdx, nil)
          end
          im.tooltip('Select a new static mesh for the variation 3 component.')
          im.SameLine()
          im.NextColumn()
          im.SetCursorPosY(im.GetCursorPosY() + max(0, (iconsSmall.y - im.GetTextLineHeight()) * 0.5))
          im.Text(('[' ..selSpline.alias3MeshName .. ']') or '[Not Set]')
          im.tooltip('The currently-selected static mesh for the variation 3 component.')
          im.NextColumn()

          tmpPtr = im.BoolPtr(selSpline.isStartCap)
          if im.Checkbox("###8765", tmpPtr) then
            selSpline.isStartCap = tmpPtr[0]
            selSpline.isDirty = true
            pop.tryRemove(selSpline)
          end
          im.tooltip('Use a separate start cap mesh for the first section.')
          im.SameLine()
          im.NextColumn()
          im.Text('Start Cap:')
          im.SameLine()
          im.NextColumn()
          if editor.uiIconImageButton(icons.youtube_searched_for, iconsSmall, cols.blueB, nil, nil, 'selectStartCapMatBtn') then
            meshTarget = 'start'
            meshAuditionMgr.addMeshToAudition(selectedMeshIdx, nil)
          end
          im.tooltip('Select a new static mesh for the start cap section.')
          im.SameLine()
          im.NextColumn()
          im.SetCursorPosY(im.GetCursorPosY() + max(0, (iconsSmall.y - im.GetTextLineHeight()) * 0.5))
          im.Text(('[' ..selSpline.startCapMeshName .. ']') or '[Not Set]')
          im.tooltip('The currently-selected static mesh for the start cap section.')
          im.NextColumn()

          tmpPtr = im.BoolPtr(selSpline.isEndCap)
          if im.Checkbox("###8766", tmpPtr) then
            selSpline.isEndCap = tmpPtr[0]
            selSpline.isDirty = true
            pop.tryRemove(selSpline)
          end
          im.tooltip('Use a separate end cap mesh for the last section.')
          im.SameLine()
          im.NextColumn()
          im.Text('End Cap:')
          im.SameLine()
          im.NextColumn()
          if editor.uiIconImageButton(icons.youtube_searched_for, iconsSmall, cols.blueB, nil, nil, 'selectEndCapMatBtn') then
            meshTarget = 'end'
            meshAuditionMgr.addMeshToAudition(selectedMeshIdx, nil)
          end
          im.tooltip('Select a new static mesh for the end cap section.')
          im.SameLine()
          im.NextColumn()
          im.SetCursorPosY(im.GetCursorPosY() + max(0, (iconsSmall.y - im.GetTextLineHeight()) * 0.5))
          im.Text(('[' ..selSpline.endCapMeshName .. ']') or '[Not Set]')
          im.tooltip('The currently-selected static mesh for the end cap section.')
          im.NextColumn()
          im.Columns(1)
          im.Dummy(im.ImVec2(0, 3))

          -- Component rotation controls.
          im.Separator()
          im.TextColored(cols.greenB, "Pre-Rotations:")
          im.Columns(5)
          im.Text("Main:")
          im.tooltip('Set the rotation around the Z-axis for the main component.')
          im.SameLine()
          im.NextColumn()
          tmpPtr = im.IntPtr(selSpline.rot)
          if im.RadioButton2("0°", tmpPtr, 0) then
            selSpline.rot = 0
            selSpline.isDirty = true
          end
          im.tooltip('Set the rotation to 0°.')
          im.SameLine()
          im.NextColumn()
          if im.RadioButton2("90°", tmpPtr, 1) then
            selSpline.rot = 1
            selSpline.isDirty = true
          end
          im.tooltip('Set the rotation to 90°.')
          im.SameLine()
          im.NextColumn()
          if im.RadioButton2("180°", tmpPtr, 2) then
            selSpline.rot = 2
            selSpline.isDirty = true
          end
          im.tooltip('Set the rotation to 180°.')
          im.SameLine()
          im.NextColumn()
          if im.RadioButton2("270°", tmpPtr, 3) then
            selSpline.rot = 3
            selSpline.isDirty = true
          end
          im.tooltip('Set the rotation to 270°.')
          im.NextColumn()
          im.Columns(1)

          -- Alias 1 Controls.
          if selSpline.isAlias1 then
            im.Separator()
            im.Columns(1)
            im.PushItemWidth(-1)
            im.Columns(5)
            im.Text("Var 1:")
            im.tooltip('Set the rotation around the Z-axis for the variation 1 mesh.')
            im.SameLine()
            im.NextColumn()
            tmpPtr = im.IntPtr(selSpline.alias1Rot)
            if im.RadioButton2("0°###7751", tmpPtr, 0) then
              selSpline.alias1Rot = 0
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 0°.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("90°###7761", tmpPtr, 1) then
              selSpline.alias1Rot = 1
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 90°.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("180°###7771", tmpPtr, 2) then
              selSpline.alias1Rot = 2
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 180°.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("270°###7781", tmpPtr, 3) then
              selSpline.alias1Rot = 3
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 270°.')
            im.NextColumn()
            im.PopItemWidth()
          end
          im.Columns(1)

          -- Alias 2 Controls.
          if selSpline.isAlias2 then
            im.Separator()
            im.Columns(1)
            im.PushItemWidth(-1)
            im.Columns(5)
            im.Text("Var 2:")
            im.tooltip('Set the rotation around the Z-axis for the variation 2 mesh.')
            im.SameLine()
            im.NextColumn()
            tmpPtr = im.IntPtr(selSpline.alias2Rot)
            if im.RadioButton2("0°###7752", tmpPtr, 0) then
              selSpline.alias2Rot = 0
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 0°.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("90°###7762", tmpPtr, 1) then
              selSpline.alias2Rot = 1
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 90°.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("180°###7772", tmpPtr, 2) then
              selSpline.alias2Rot = 2
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 180°.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("270°###7782", tmpPtr, 3) then
              selSpline.alias2Rot = 3
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 270°.')
            im.NextColumn()
            im.PopItemWidth()
          end
          im.Columns(1)

          -- Alias 3 Controls.
          if selSpline.isAlias3 then
            im.Separator()
            im.Columns(1)
            im.PushItemWidth(-1)
            im.Columns(5)
            im.Text("Var 3:")
            im.tooltip('Set the rotation around the Z-axis for the variation 3 mesh.')
            im.SameLine()
            im.NextColumn()
            tmpPtr = im.IntPtr(selSpline.alias3Rot)
            if im.RadioButton2("0°###7753", tmpPtr, 0) then
              selSpline.alias3Rot = 0
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 0°.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("90°###7763", tmpPtr, 1) then
              selSpline.alias3Rot = 1
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 90°.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("180°###7773", tmpPtr, 2) then
              selSpline.alias3Rot = 2
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 180°.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("270°###7783", tmpPtr, 3) then
              selSpline.alias3Rot = 3
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 270°.')
            im.NextColumn()
            im.PopItemWidth()
          end
          im.Columns(1)

          -- Start Cap Controls.
          if selSpline.isStartCap then
            im.Separator()
            im.Columns(1)
            im.PushItemWidth(-1)
            im.Columns(5)
            im.Text("Start Cap:")
            im.tooltip('Set the rotation around the Z-axis for the start cap mesh.')
            im.SameLine()
            im.NextColumn()
            tmpPtr = im.IntPtr(selSpline.startCapRot)
            if im.RadioButton2("0°###775", tmpPtr, 0) then
              selSpline.startCapRot = 0
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 0°.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("90°###776", tmpPtr, 1) then
              selSpline.startCapRot = 1
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 90°.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("180°###777", tmpPtr, 2) then
              selSpline.startCapRot = 2
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 180°.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("270°###778", tmpPtr, 3) then
              selSpline.startCapRot = 3
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 270°.')
            im.NextColumn()
            im.PopItemWidth()
          end
          im.Columns(1)

          -- End Cap Controls.
          if selSpline.isEndCap then
            im.Separator()
            im.Columns(1)
            im.PushItemWidth(-1)
            im.Columns(5)
            im.Text("End Cap:")
            im.tooltip('Set the rotation around the Z-axis for the end cap mesh.')
            im.SameLine()
            im.NextColumn()
            tmpPtr = im.IntPtr(selSpline.endCapRot)
            if im.RadioButton2("0°###782", tmpPtr, 0) then
              selSpline.endCapRot = 0
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 0°.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("90°###783", tmpPtr, 1) then
              selSpline.endCapRot = 1
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 90°.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("180°###784", tmpPtr, 2) then
              selSpline.endCapRot = 2
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 180°.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("270°###785", tmpPtr, 3) then
              selSpline.endCapRot = 3
              selSpline.isDirty = true
            end
            im.tooltip('Set the rotation to 270°.')
            im.NextColumn()
            im.PopItemWidth()
          end
          im.Columns(1)
          im.Separator()
        elseif selectedTab == 1 then -- Distribution tab.
          -- If aliases are being used, allow selection of mode (round robin or random)
          if selSpline.isAlias1 or selSpline.isAlias2 or selSpline.isAlias3 then
            im.TextColored(cols.greenB, "Distribution:")

            -- Distribution style: round robin or randomly distributed.
            tmpPtr = selSpline.isAliasRoundRobin and im.IntPtr(0) or im.IntPtr(1)
            im.Columns(2, "RoundRobinOrRandomCols", false)
            if im.RadioButton2("Round Robin", tmpPtr, 0) then
              local statePre = splineMgr.deepCopyMeshSpline(selSpline)
              selSpline.isAliasRoundRobin = true
              selSpline.isDirty = true
              editor.history:commitAction("Toggle Round Robin", { old = statePre, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
            end
            im.tooltip('Use a round robin distribution for the alias meshes.')
            im.SameLine()
            im.NextColumn()
            if im.RadioButton2("Random", tmpPtr, 1) then
              local statePre = splineMgr.deepCopyMeshSpline(selSpline)
              selSpline.isAliasRoundRobin = false
              selSpline.isDirty = true
              editor.history:commitAction("Toggle Random", { old = statePre, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
            end
            im.tooltip('Use a random distribution for the alias meshes.')
            im.NextColumn()
            im.Columns(1)

            -- Randomisation properties.
            if not selSpline.isAliasRoundRobin then
              im.PushItemWidth(-1)
              im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
              im.Columns(2, "randStyleWithResetCols", false)
              im.SetColumnWidth(0, 30)

              -- Main random weight slider row.
              if selSpline.mainRandomWeight ~= defaultParams.mainRandomWeight then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetMainRandomWeightBtn') then
                  selSpline.mainRandomWeight = defaultParams.mainRandomWeight
                  selSpline.isDirty = true
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.FloatPtr(selSpline.mainRandomWeight)
              if im.SliderFloat('###5752', tmpPtr, 0.0, 1.0, "Main Weight = %.2f") then
                selSpline.mainRandomWeight = tmpPtr[0]
                selSpline.isDirty = true
              end
              im.tooltip("Set the weight (similar to probability) of the main mesh.")
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyMeshSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Main Weight", { old = sliderPreEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()

              -- Alias 1 random weight slider row.
              if selSpline.isAlias1 then
                if selSpline.alias1RandomWeight ~= defaultParams.alias1RandomWeight then
                  if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetAlias1RandomWeightBtn') then
                    selSpline.alias1RandomWeight = defaultParams.alias1RandomWeight
                    selSpline.isDirty = true
                  end
                  im.tooltip("Reset to default")
                else
                  im.Dummy(iconsSmall)
                end
                im.SameLine()
                im.NextColumn()
                im.PushItemWidth(-1)
                tmpPtr = im.FloatPtr(selSpline.alias1RandomWeight)
                if im.SliderFloat('###5753', tmpPtr, 0.0, 1.0, "Variation 1 Weight = %.2f") then
                  selSpline.alias1RandomWeight = tmpPtr[0]
                  selSpline.isDirty = true
                end
                im.tooltip("Set the weight (similar to probability) of the variation 1 mesh.")
                if im.IsItemActivated() then
                  sliderPreEditState = splineMgr.deepCopyMeshSpline(selSpline)
                end
                if im.IsItemDeactivatedAfterEdit() then
                  editor.history:commitAction("Adjust Alias 1 Weight", { old = sliderPreEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.PopItemWidth()
                im.NextColumn()
              end

              -- Alias 2 random weight slider row.
              if selSpline.isAlias2 then
                if selSpline.alias2RandomWeight ~= defaultParams.alias2RandomWeight then
                  if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetAlias2RandomWeightBtn') then
                    selSpline.alias2RandomWeight = defaultParams.alias2RandomWeight
                    selSpline.isDirty = true
                  end
                  im.tooltip("Reset to default")
                else
                  im.Dummy(iconsSmall)
                end
                im.SameLine()
                im.NextColumn()
                im.PushItemWidth(-1)
                tmpPtr = im.FloatPtr(selSpline.alias2RandomWeight)
                if im.SliderFloat('###5754', tmpPtr, 0.0, 1.0, "Variation 2 Weight = %.2f") then
                  selSpline.alias2RandomWeight = tmpPtr[0]
                  selSpline.isDirty = true
                end
                im.tooltip("Set the weight (similar to probability) of the variation 2 mesh.")
                if im.IsItemActivated() then
                  sliderPreEditState = splineMgr.deepCopyMeshSpline(selSpline)
                end
                if im.IsItemDeactivatedAfterEdit() then
                  editor.history:commitAction("Adjust Alias 2 Weight", { old = sliderPreEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.PopItemWidth()
                im.NextColumn()
              end

              -- Alias 3 random weight slider row.
              if selSpline.isAlias3 then
                if selSpline.alias3RandomWeight ~= defaultParams.alias3RandomWeight then
                  if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetAlias3RandomWeightBtn') then
                    selSpline.alias3RandomWeight = defaultParams.alias3RandomWeight
                    selSpline.isDirty = true
                  end
                  im.tooltip("Reset to default")
                else
                  im.Dummy(iconsSmall)
                end
                im.SameLine()
                im.NextColumn()
                im.PushItemWidth(-1)
                tmpPtr = im.FloatPtr(selSpline.alias3RandomWeight)
                if im.SliderFloat('###5755', tmpPtr, 0.0, 1.0, "Variation 3 Weight = %.2f") then
                  selSpline.alias3RandomWeight = tmpPtr[0]
                  selSpline.isDirty = true
                end
                im.tooltip("Set the weight (similar to probability) of the variation 3 mesh.")
                if im.IsItemActivated() then
                  sliderPreEditState = splineMgr.deepCopyMeshSpline(selSpline)
                end
                if im.IsItemDeactivatedAfterEdit() then
                  editor.history:commitAction("Adjust Alias 3 Weight", { old = sliderPreEditState, new = splineMgr.deepCopyMeshSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.PopItemWidth()
                im.NextColumn()
              end
              im.PopStyleVar()
              im.PopItemWidth()
            end
            im.Separator()
          else
            im.TextColored(cols.greenB, "No variations selected") -- Show message when no variations are selected.
            im.Text("Variations are enabled in the Components tab.")
          end
          im.Columns(1)
        elseif selectedTab == 2 then -- Terrain tab.
          if selSpline.isConformToTerrain then
            im.TextColored(cols.greenB, "Spline Is Conformed To Surface")
            im.Text("Terraforming controls are disabled.")
          else
            im.TextColored(cols.greenB, "Terraforming:")
            im.Columns(2, "terrainSlidersRow_mesh", false)
            im.SetColumnWidth(0, 30)

          -- 'DOI' slider.
          if terraParams.terraDOI ~= 50.0 then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetDOI_mesh') then
              terraParams.terraDOI = 50.0
            end
            im.tooltip("Reset to default")
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()
          im.NextColumn()
          im.PushItemWidth(-1)
          tmpPtr = im.FloatPtr(terraParams.terraDOI)
          if im.SliderFloat('###mesh_doi', tmpPtr, DOImin, DOImax, "DOI = %.2f") then
            terraParams.terraDOI = tmpPtr[0]
          end
          im.tooltip('Set the Domain Of Influence, in meters.')
          im.PopItemWidth()
          im.NextColumn()

          -- 'Terraform Margin' slider.
          if terraParams.terraMargin ~= 5.0 then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetMargin_mesh') then
              terraParams.terraMargin = 5.0
            end
            im.tooltip("Reset to default")
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()
          im.NextColumn()
          im.PushItemWidth(-1)
          tmpPtr = im.FloatPtr(terraParams.terraMargin)
          if im.SliderFloat('###mesh_margin', tmpPtr, terraMarginMin, terraMarginMax, "Terraform Margin = %.2f") then
            terraParams.terraMargin = tmpPtr[0]
          end
          im.PopItemWidth()
          im.NextColumn()

          -- 'Terraform Falloff' slider.
          if terraParams.terraFalloff ~= 2.0 then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetFalloff_mesh') then
              terraParams.terraFalloff = 2.0
            end
            im.tooltip("Reset to default")
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()
          im.NextColumn()
          im.PushItemWidth(-1)
          tmpPtr = im.FloatPtr(terraParams.terraFalloff)
          if im.SliderFloat('###mesh_falloff', tmpPtr, terraFalloffMin, terraFalloffMax, "Terraform Falloff = %.2f") then
            terraParams.terraFalloff = tmpPtr[0]
          end
          im.PopItemWidth()
          im.NextColumn()

          -- 'Terraform Roughness' slider.
          if terraParams.terraRoughness ~= 0.0 then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetRough_mesh') then
              terraParams.terraRoughness = 0.0
            end
            im.tooltip("Reset to default")
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()
          im.NextColumn()
          im.PushItemWidth(-1)
          tmpPtr = im.FloatPtr(terraParams.terraRoughness)
          if im.SliderFloat('###mesh_rough', tmpPtr, 0.0, 1.0, "Noise Roughness = %.2f") then
            terraParams.terraRoughness = tmpPtr[0]
          end
          im.PopItemWidth()
          im.NextColumn()

          -- 'Terraform Scale' slider.
          if terraParams.terraScale ~= 0.0 then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetScale_mesh') then
              terraParams.terraScale = 0.0
            end
            im.tooltip("Reset to default")
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()
          im.NextColumn()
          im.PushItemWidth(-1)
          tmpPtr = im.FloatPtr(terraParams.terraScale)
          if im.SliderFloat('###mesh_scale', tmpPtr, 0.0, 1.0, "Noise Scale = %.2f") then
            terraParams.terraScale = tmpPtr[0]
          end
          im.PopItemWidth()
          im.NextColumn()

          im.Columns(1)

          -- 'Terraform To Mesh Spline' button.
          if selSpline and selSpline.isEnabled and not selSpline.isLink and #selSpline.nodes > 1 and not selSpline.isConformToTerrain then
            if editor.uiIconImageButton(icons.terrainToLine, iconsBig, cols.blueB, nil, nil, 'terraformToMeshSplineBtn') then
              local sources = util.getSourcesSingle(selSpline)
              terra.terraformToSources(terraParams.terraDOI, terraParams.terraMargin, terraParams.terraFalloff, terraParams.terraRoughness, terraParams.terraScale, sources)
            end
            im.tooltip('Terraform the terrain to the selected Mesh Spline.')
          else
            im.Dummy(iconsBig)
          end
          im.NextColumn()

          im.Columns(1)
          im.Separator()
          end -- End of if selSpline.isConformToTerrain else block.
        end -- End of tab content.
      end -- End of TabContentChild.
      im.EndChild() -- Must always be called for BeginChild1, regardless of return value.
      im.PopStyleVar() -- Restore original padding.
    else
      im.Text("No mesh splines.")
      im.Text("Click the 'Add' button to add one.")
    end
  end
  editor.endWindow()
end

-- Callback for when the user has finished drawing a selection polygon.
local function onSelectionPolygonComplete(polygon)
  import.importFromPolygon(polygon)
  isDrawPolygon = false
end

-- World editor main callback.
local function onEditorGui()
  -- Handle import delay update.
  import.handleDelayedSplineUpdates()

  -- Ensure all mesh splines are updated, even if this tool is not active.
  -- [This ensures any linked mesh splines are also updated.]
  splineMgr.updateDirtyMeshSplines()

  -- If this tool is not active, render the shells of the splines but do nothing further.
  if not isMeshSplineActive then
    render.renderShells(splineMgr.getMeshSplines())
    return
  end

  -- Handle the main tool window UI.
  handleMainToolWindowUI()

  -- Handle the mesh audition and selection.
  meshAuditionMgr.handleMeshAuditionAndSelection(meshTarget, onMeshSelected)

  -- Handle the front end if the user is drawing a selection polygon.
  if isDrawPolygon then
    poly.handleUserPolygon(onSelectionPolygonComplete)
    return -- Don't do anything further if the user is drawing a selection polygon.
  end

  -- Handle the mouse and keyboard events.
  local splines = splineMgr.getMeshSplines()
  local isConformToTerrain = selectedSplineIdx and splines[selectedSplineIdx] and splines[selectedSplineIdx].isConformToTerrain
  out.spline, out.node, out.isGizmoActive, out.isLockShape = selectedSplineIdx, selectedNodeIdx, isGizmoActive, isLockShape
  input.handleSplineEvents(
    splines,
    out,
    true, isConformToTerrain, false, false, false, true, true, isLockShape,
    defaultSplineWidth,
    splineMgr.deepCopyMeshSpline, splineMgr.deepCopyMeshSplineState,
    splineMgr.copyMeshSplineProfile, splineMgr.pasteMeshSplineProfile,
    nil,
    splineMgr.joinMeshSplines,
    splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo,
    splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo)
  selectedSplineIdx, selectedNodeIdx, isGizmoActive, isLockShape = out.spline, out.node, out.isGizmoActive, out.isLockShape

  -- Render the mesh splines with debugDraw (only if not linked to master spline).
  local selSpline = splines[out.spline]
  if selSpline then
    render.handleSplineRendering(splines, out.spline, out.node, isGizmoActive, true, isLockShape, true, false, elevScale)

    -- Render polylines for mesh splines.
    render.renderSplinePolylines(splines, out.spline)
  end
end

-- Called when the tool mode icon is pressed.
local function onActivate()
  isDrawPolygon = false
  poly.clearPolygon() -- Ensure there is no residual polygon left over from the previous usage.
  editor.clearObjectSelection()
  editor.showWindow(toolWinName)
  isMeshSplineActive = true
end

-- Called when the tool is exited.
local function onDeactivate()
  isDrawPolygon = false
  poly.clearPolygon() -- Ensure there is no residual polygon left over from the previous usage.
  meshAuditionMgr.leaveAuditionView()
  editor.hideWindow(toolWinName)
  isMeshSplineActive = false
end

-- Validates the selection for the scenetree right click menu.
local function validateSceneTreeRightClickMenuSelection(node)
  if node then
    local validCtr = 0
    for _, objId in ipairs(editor.selection.object) do
      local obj = scenetree.findObjectById(objId)
      if obj and obj:getClassName() == "TSStatic" then
        validCtr = validCtr + 1
        if validCtr >= 2 then -- Need at least two static meshes to convert to a mesh spline.
          return true
        end
      end
    end
  end
  return false
end

-- Called on scenetree right click menu, if validated.
local function processSceneTreeRightClickMenuSelection(node)
  if node then
    import.convertTSStatics2MeshSpline(editor.selection.object)
  end
end

-- Called upon world editor initialization.
local function onEditorInitialized()
  editor.editModes.meshSplineEditMode = {
    displayName = "Mesh Spline",
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    icon = editor.icons.bSpline,
    iconTooltip = "MeshSpline",
    auxShortcuts = {},
    hideObjectIcons = true }
  editor.registerWindow(toolWinName, toolWinSize)
  meshAuditionMgr.registerWindow()

  -- Set up the scenetree right click menu for importing.
  editor.addExtendedSceneTreeObjectMenuItem({
    title = "Convert to Mesh Spline",
    extendedSceneTreeObjectMenuItems = processSceneTreeRightClickMenuSelection,
    validator = validateSceneTreeRightClickMenuSelection })
end

-- Called when leaving the map. Removes all mesh splines.
local function onClientEndMission() splineMgr.removeAllMeshSplines(true) end


-- Public interface.
M.setSelectedSplineIdx =                                  setSelectedSplineIdx
M.setSelectedNodeIdx =                                    setSelectedNodeIdx

M.onSerialize =                                           onSerialize
M.onDeserialized =                                        onDeserialized

M.onEditorGui =                                           onEditorGui
M.onEditorInitialized =                                   onEditorInitialized
M.onClientEndMission =                                    onClientEndMission

return M
