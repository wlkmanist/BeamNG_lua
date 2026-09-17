-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local kitSearchPath = 'assets/meshes/props/assembly_kit/' -- The path at which to search for assembly kits.

local simplifyRdpTol = 9.0 -- The tolerance for the RDP simplification of the spline.

local defaultSplineWidth = 10.0 -- The default width for a spline when adding a new node, in meters.
local elevScale = 100.0 -- The scale factor for the elevation drop lines (used for blue->red colour transition).

local minSpacing, maxSpacing = 0.0, 100.0
local minVerticalOffset, maxVerticalOffset = -100.0, 100.0
local minSag, maxSag = 0.0, 100.0
local maxRandomSeed = 1000

local DOImin, DOImax = 0.0, 500.0
local terraMarginMin, terraMarginMax = 1.0, 20.0
local terraFalloffMin, terraFalloffMax = 1.0, 5.0

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- External modules.
local splineMgr = require('editor/assemblySpline/splineMgr')
local mol = require('editor/assemblySpline/molecule')
local pop = require('editor/assemblySpline/populate')
local import = require('editor/assemblySpline/import')
local input = require('editor/toolUtilities/splineInput')
local render = require('editor/toolUtilities/render')
local skeleton = require('editor/toolUtilities/skeleton')
local rdp = require('editor/toolUtilities/rdp')
local poly = require('editor/toolUtilities/polygon')
local maskExport = require('editor/toolUtilities/splineMaskExport')
local util = require('editor/toolUtilities/util')
local geom = require('editor/toolUtilities/geom')
local style = require('editor/toolUtilities/style')
local terra = require('editor/terraform/terraform')

-- Module constants.
local im = ui_imgui
local min, max = math.min, math.max
local toolWinName, toolWinSize = 'assemblySpline', im.ImVec2(300, 700)
local defaultParams = splineMgr.getDefaultSliderParams()
local cols = style.getImguiCols('crystal')
local iconsSmall, iconsBig = im.ImVec2(24, 24), im.ImVec2(36, 36)

-- Module state.
local isAssemblySplineActive = false
local isGizmoActive = false
local isLockShape = false
local isDrawPolygon = false
local selectedSplineIdx = 1
local selectedNodeIdx = 1
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
  splineMgr.getAssemblySplines,
  splineMgr.getEditModeKey,
  splineMgr.deepCopyAssemblySpline,
  splineMgr.deepCopyAssemblySplineState,
  'editor_assemblySpline'
)


-- Sets the selected spline index (for cross-tool selection).
local function setSelectedSplineIdx(idx) selectedSplineIdx = idx end

-- Sets the selected node index (for cross-tool selection).
local function setSelectedNodeIdx(idx) selectedNodeIdx = idx end

-- Serialise callback.
local function onSerialize()
  local assemblySplines = splineMgr.getAssemblySplines()
  local numSplines = #assemblySplines
  local assemblySplinesSer = {}
  for i = 1, numSplines do
    assemblySplinesSer[i] = splineMgr.serializeAssemblySpline(assemblySplines[i])
  end
  splineMgr.removeAllAssemblySplines()
  return assemblySplinesSer
end

-- Deserialise callback.
local function onDeserialized(data)
  if data and #data > 0 then
    local assemblySplines = splineMgr.getAssemblySplines()
    table.clear(assemblySplines)
    for i = 1, #data do
      local spline = splineMgr.deserializeAssemblySpline(data[i], true)
      assemblySplines[#assemblySplines + 1] = spline
    end
    selectedSplineIdx = max(1, min(#assemblySplines, selectedSplineIdx))

    -- Update the spline map.
    util.computeIdToIdxMap(assemblySplines, splineMgr.getSplineMap())

    -- Update the mesh kit and molecule structures for each spline.
    for i = 1, #assemblySplines do
      local spline = assemblySplines[i]
      -- Only regenerate if we don't already have the data (e.g., for new splines)
      if not spline.meshKit or #spline.meshKit == 0 then
        if spline.isImported and spline.importedKit and spline.importedKit.reconstructedKit then
          -- For imported splines, use the stored reconstructed kit.
          spline.meshKit = spline.importedKit.reconstructedKit
          spline.moleculeDescription = mol.buildMolecule(spline.meshKit, spline)
        else
          -- For folder-based splines, load from disk.
          spline.meshKit = mol.getAssemblyKit(spline.kitFolderPath)
          spline.moleculeDescription = mol.buildMolecule(spline.meshKit, spline)
        end
      end
    end
  end
end

-- Handles the main tool window.
local function handleMainToolWindowUI()
  if editor.beginWindow(toolWinName, "Assembly Spline###21344", im.WindowFlags_NoCollapse) then
    local icons = editor.icons
    local assemblySplines = splineMgr.getAssemblySplines()
    selectedSplineIdx = max(1, min(#assemblySplines, selectedSplineIdx)) -- Ensure the selected spline index is within bounds.

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

    -- 'Add New assembly spline' button.
    if editor.uiIconImageButton(icons.bSpline, iconsBig, cols.blueB, nil, nil, 'addNewAssemblySplineBtn') then
      local statePre = splineMgr.deepCopyAssemblySplineState()
      splineMgr.addNewAssemblySpline()
      selectedSplineIdx = #assemblySplines
      editor.history:commitAction("Add New assembly spline", { old = statePre, new = splineMgr.deepCopyAssemblySplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
    end
    im.tooltip('Add a new assembly spline.')
    im.SameLine()
    im.NextColumn()

    -- 'Draw A Selection Polygon' button.
    local btnCol = isDrawPolygon and cols.blueB or cols.blueD
    if editor.uiIconImageButton(icons.rounded_corner, iconsBig, btnCol, nil, nil, 'drawPolygonBtn') then
      isDrawPolygon = not isDrawPolygon
      poly.clearPolygon() -- Ensure there is no residual polygon left over from the previous usage.
    end
    im.tooltip(isDrawPolygon and 'Click to stop drawing a selection polygon.' or 'Click to draw a selection polygon, to convert scene objects to an Assembly Spline.')
    im.SameLine()
    im.NextColumn()

    -- 'Import From Bitmap Mask' button.
    if editor.uiIconImageButton(icons.floppyDiskPlus, iconsBig, cols.blueB, nil, nil, 'importFromBitmapMaskBtn') then
      extensions.editor_fileDialog.openFile(
        function(data)
          if data.filepath then
            local paths = skeleton.getPathsFromPng(data.filepath)
            if #paths > 0 then
              local preState = splineMgr.deepCopyAssemblySplineState()
              splineMgr.convertPathsToAssemblySplines(paths)
              editor.history:commitAction("Import Assembly Splines From Bitmap", { old = preState, new = splineMgr.deepCopyAssemblySplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
            end
          end
        end,
        {{"PNG",".png"}},
        false,
        "/")
    end
    im.tooltip('Import assembly splines from a bitmap mask.')
    im.SameLine()
    im.NextColumn()

    -- 'Remove All Assembly Splines' button.
    if #assemblySplines > 0 then
      if editor.uiIconImageButton(icons.trashBin2, iconsBig, cols.blueB, nil, nil, 'removeAllAssemblySplinesBtn') then
        local statePre = splineMgr.deepCopyAssemblySplineState()
        splineMgr.removeAllAssemblySplines(false)
        selectedSplineIdx = 1
        editor.history:commitAction("Remove All assembly splines", { old = statePre, new = splineMgr.deepCopyAssemblySplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
      end
      im.tooltip('Remove all (enabled and not linked) assembly splines from the session.')
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Lock Shape' toggle button.
    local selSpline = assemblySplines[selectedSplineIdx]
    if #assemblySplines > 0 and selSpline and selSpline.isEnabled and not selSpline.isLink then
      btnCol = isLockShape and cols.blueB or cols.blueD
      if editor.uiIconImageButton(icons.roadGuideArrowSolid, iconsBig, btnCol, nil, nil, 'lockShapeBtn') then
        isLockShape = not isLockShape
      end
      im.tooltip((isLockShape and 'Unlock the shape of the assembly spline to move nodes separately' or 'Lock the shape of the assembly spline to move nodes rigidly'))
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Export Spline Mask' button.
    if #assemblySplines > 0 then
      if editor.uiIconImageButton(icons.folder, iconsBig, cols.blueB, nil, nil, 'exportSplineMaskBtn') then
        local sources = util.getAllSources(assemblySplines)
        extensions.editor_fileDialog.saveFile(
          function(data)
            maskExport.export(data.filepath, sources, 1.0) -- TODO: Uses a 1m margin. Maybe make this a parameter later.
          end,
          {{"PNG",".png"}},
          false,
          "/",
          "File already exists.\nDo you want to overwrite the file?")
      end
      im.tooltip('Export the session as a .PNG mask file. Will not include any disabled Assembly Splines.')
    else
      im.Dummy(iconsBig)
    end
    im.NextColumn()

    im.PopStyleVar(2)
    im.Columns(1)
    im.Separator()

    -- Assembly splines list.
    if #assemblySplines > 0 then
      im.TextColored(cols.greenB, "Assembly Splines:")
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
        for i = 1, #assemblySplines do
          local spline = assemblySplines[i]
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
            im.tooltip('This assembly spline is linked to a Master Spline. To edit or remove it, first unlink it from within the Master Spline Editor.')
          elseif not spline.isEnabled then
            im.TextColored(cols.dullWhite, spline.name)
            im.tooltip('This assembly spline is disabled. To edit or remove it, first enable it.')
          else
            if im.InputText("###" .. tostring(wCtr), splineNamePtr, 32) then
              spline.name = ffi.string(splineNamePtr)
              if spline.sceneTreeFolderId then
                local folder = scenetree.findObjectById(spline.sceneTreeFolderId)
                if folder then
                  local preState = splineMgr.deepCopyAssemblySpline(spline)
                  folder:setName(spline.name)
                  editor.refreshSceneTreeWindow()
                  spline.isDirty = true -- Ensures the mesh names are updated in the scene tree.
                  local postState = splineMgr.deepCopyAssemblySpline(spline)
                  preState.isUpdateSceneTree = true
                  postState.isUpdateSceneTree = true
                  editor.history:commitAction("Edit assembly spline name", { old = preState, new = postState }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
              end
            end
            im.tooltip('Edit the assembly spline name.')
            if im.IsItemActive() then
              selectedSplineIdx = i
            end
          end
          im.PopItemWidth()
          wCtr = wCtr + 1
          im.SameLine()
          im.NextColumn()

          -- 'Remove Selected Assembly Spline' button.
          if spline.isEnabled and not spline.isLink then
            if editor.uiIconImageButton(icons.trashBin2, iconsSmall, cols.blueB, nil, nil, 'removeSpline' .. i) then
              local statePre = splineMgr.deepCopyAssemblySplineState()
              splineMgr.removeAssemblySpline(i)
              if selectedSplineIdx > i then
                selectedSplineIdx = selectedSplineIdx - 1
              end
              selectedSplineIdx = max(1, min(#assemblySplines, selectedSplineIdx))
              editor.history:commitAction("Remove assembly spline", { old = statePre, new = splineMgr.deepCopyAssemblySplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
              editor.endWindow()
              return
            end
            im.tooltip('Remove this assembly spline from the session.')
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()
          im.NextColumn()

          -- 'Enable/Disable Assembly Spline' button.
          if not spline.isLink then
            local btnCol = spline.isEnabled and cols.blueB or cols.blueD
            local btnIcon = spline.isEnabled and icons.lock or icons.lock_open
            if editor.uiIconImageButton(btnIcon, iconsSmall, btnCol, nil, nil, 'lockUnlockAssemblySplineToggleBtn' .. i) then
              local statePre = splineMgr.deepCopyAssemblySpline(spline)
              spline.isEnabled = not spline.isEnabled
              pop.tryRemove(spline) -- Remove the assembly spline from the population, before rebuilding the collision mesh.
              spline.isDirty = true
              selectedSplineIdx = i
              editor.history:commitAction("Toggle assembly spline Lock", { old = statePre, new = splineMgr.deepCopyAssemblySpline(spline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
            end
            im.tooltip((spline.isEnabled and 'Disable' or 'Enable') .. ' this assembly spline.')
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

      -- Buttons underneath the assembly splines list box.
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
        im.tooltip('Go to this assembly spline (move camera).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Conform To Surface Below' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink then
        btnCol = selSpline.isConformToTerrain and cols.blueB or cols.blueD
        if editor.uiIconImageButton(icons.lineToTerrain, iconsBig, btnCol, nil, nil, 'conformToTerrainBtn') then
          local statePre = splineMgr.deepCopyAssemblySpline(selSpline)
          selSpline.isConformToTerrain = not selSpline.isConformToTerrain
          selSpline.isDirty = true
          editor.history:commitAction("Conform To Surface Below", { old = statePre, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip((selSpline.isConformToTerrain and 'Unconform' or 'Conform') .. ' the selected assembly spline to the surface below.')
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
          local statePre = splineMgr.deepCopyAssemblySpline(selSpline)
          selSpline.normalMode = (selSpline.normalMode + 1) % 3 -- Cycle through 0, 1, 2
          selSpline.isDirty = true
          editor.history:commitAction("Toggle Normal Mode", { old = statePre, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        -- Dynamic tooltip showing current mode and what clicking will do next
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

      -- 'Split assembly spline' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink and selSpline.nodes[selectedNodeIdx] and #selSpline.nodes > 2 and (selSpline.isLoop or (selectedNodeIdx > 1 and selectedNodeIdx < #selSpline.nodes)) then
        if editor.uiIconImageButton(icons.content_cut, iconsBig, cols.blueB, nil, nil, 'splitAssemblySplineBtn') then
          local statePre = splineMgr.deepCopyAssemblySplineState()
          splineMgr.splitAssemblySpline(selectedSplineIdx, selectedNodeIdx)
          selectedSplineIdx = #assemblySplines
          editor.history:commitAction("Split New assembly spline", { old = statePre, new = splineMgr.deepCopyAssemblySplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
        end
        im.tooltip('Splits the selected assembly spline into two, at the selected node.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Flip Direction' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink and #selSpline.nodes > 1 then
        if editor.uiIconImageButton(icons.cached, iconsBig, cols.blueB, nil, nil, 'flipDirectionBtn') then
          local statePre = splineMgr.deepCopyAssemblySpline(selSpline)
          geom.flipSplineDirection(selSpline)
          selSpline.isDirty = true
          editor.history:commitAction("Flip Assembly Spline Direction", { old = statePre, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip('Flips the direction of the selected assembly spline (back to front).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Simplify Spline' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink and selSpline.nodes[selectedNodeIdx] and #selSpline.nodes > 2 then
        if editor.uiIconImageButton(icons.routeSimple, iconsBig, cols.blueB, nil, nil, 'simplifySplineBtn') then
          local statePre = splineMgr.deepCopyAssemblySpline(selSpline)
          rdp.simplifyNodesWidthsNormals(selSpline.nodes, selSpline.widths, selSpline.nmls, simplifyRdpTol)
          selectedNodeIdx = max(1, min(#selSpline.nodes, selectedNodeIdx))
          selSpline.isDirty = true
          editor.history:commitAction("Simplify Assembly Spline", { old = statePre, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip('Simplifies the selected assembly spline (reduces the number of nodes).')
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
              jsonWriteFile(data.filepath, splineMgr.copyAssemblySplineProfile(selSpline), true)
            end,
            {{"JSON",".json"}},
            false,
            "/",
            "File already exists.\nDo you want to overwrite the file?")
        end
        im.tooltip('Saves the template of the selected assembly spline to disk.')
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
              local preState = splineMgr.deepCopyAssemblySpline(selSpline)
              splineMgr.pasteAssemblySplineProfile(selSpline, jsonReadFile(data.filepath))
              editor.history:commitAction("Load Assembly Spline Template", { old = preState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.objectSelectUndo, splineMgr.objectSelectRedo, true)
            end,
            {{"JSON",".json"}},
            false,
            "/")
        end
        im.tooltip('Sets the selected assembly spline to a template loaded from disk.')
      else
        im.Dummy(iconsBig)
      end
      im.NextColumn()
      im.PopStyleVar(2)
      im.Separator()
      im.Columns(1)

      -- If the selected spline is disabled, don't show anything further.
      if not selSpline or not selSpline.isEnabled then
        editor.endWindow()
        return
      end

      -- Spline Properties section.
      im.TextColored(cols.greenB, "Spline Properties:")
      im.PushItemWidth(-1)
      im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
      im.Columns(2, 'splinePropertiesCols', false)
      im.SetColumnWidth(0, 30)

      -- Spacing slider.
      if selSpline.spacing ~= defaultParams.spacing then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetSpacingBtn') then
          local preEditState = splineMgr.deepCopyAssemblySpline(selSpline)
          selSpline.spacing = defaultParams.spacing
          selSpline.isDirty = true
          editor.history:commitAction("Reset Spacing", { old = preEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      local tmpPtr = im.FloatPtr(selSpline.spacing)
      if im.SliderFloat('###5756', tmpPtr, minSpacing, maxSpacing, "Molecule Spacing (m) = %.2f") then
        selSpline.spacing = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the longitudinal spacing between each component, in meters.')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyAssemblySpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Spacing", { old = sliderPreEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      -- Vertical Offset slider.
      if selSpline.verticalOffset ~= defaultParams.verticalOffset then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetVerticalOffsetBtn') then
          local preEditState = splineMgr.deepCopyAssemblySpline(selSpline)
          selSpline.verticalOffset = defaultParams.verticalOffset
          selSpline.isDirty = true
          editor.history:commitAction("Reset Vertical Offset", { old = preEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      tmpPtr = im.FloatPtr(selSpline.verticalOffset)
      if im.SliderFloat('###4456', tmpPtr, minVerticalOffset, maxVerticalOffset, "Vertical Offset (m) = %.2f") then
        selSpline.verticalOffset = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the vertical offset of the components, in meters.')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyAssemblySpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Vertical Offset", { old = sliderPreEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      -- Sag slider (only show if molecule has sag-enabled bridges).
      local molecule = selSpline.moleculeDescription
      if molecule and molecule.isSagEnabled then
        if selSpline.sag ~= defaultParams.sag then
          if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetSagBtn') then
            local preEditState = splineMgr.deepCopyAssemblySpline(selSpline)
            selSpline.sag = defaultParams.sag
            selSpline.isDirty = true
            editor.history:commitAction("Reset Sag", { old = preEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
          end
          im.tooltip("Reset to default")
        else
          im.Dummy(iconsSmall)
        end
        im.SameLine()
        im.NextColumn()
        im.PushItemWidth(-1)
        tmpPtr = im.FloatPtr(selSpline.sag)
        if im.SliderFloat('###5316', tmpPtr, minSag, maxSag, "Bridge Sag = %.2f") then
          selSpline.sag = tmpPtr[0]
          selSpline.isDirty = true
        end
        im.tooltip('Set the amount of sag of all bridge components which support sag.')
        if im.IsItemActivated() then
          sliderPreEditState = splineMgr.deepCopyAssemblySpline(selSpline)
        end
        if im.IsItemDeactivatedAfterEdit() then
          editor.history:commitAction("Adjust Sag", { old = sliderPreEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.PopItemWidth()
        im.NextColumn()
      end

      -- Component rotation controls.
      im.PopStyleVar() -- Pop GrabMinSize pushed for the property sliders.
      im.Columns(1)
      im.Separator()
      im.TextColored(cols.greenB, "Molecule Pre-Rotation:")
      im.Columns(4)
      local tmpPtr = im.IntPtr(selSpline.preRot)
      if im.RadioButton2("0°", tmpPtr, 0) then
        selSpline.preRot = 0
        selSpline.isDirty = true
      end
      im.tooltip('Set the rotation to 0°.')
      im.SameLine()
      im.NextColumn()
      if im.RadioButton2("90°", tmpPtr, 1) then
        selSpline.preRot = 1
        selSpline.isDirty = true
      end
      im.tooltip('Set the rotation to 90°.')
      im.SameLine()
      im.NextColumn()
      if im.RadioButton2("180°", tmpPtr, 2) then
        selSpline.preRot = 2
        selSpline.isDirty = true
      end
      im.tooltip('Set the rotation to 180°.')
      im.SameLine()
      im.NextColumn()
      if im.RadioButton2("270°", tmpPtr, 3) then
        selSpline.preRot = 3
        selSpline.isDirty = true
      end
      im.tooltip('Set the rotation to 270°.')
      im.NextColumn()
      im.PopItemWidth()
      im.Columns(1)

      -- Geometric variation controls.
      im.Separator()
      im.TextColored(cols.greenB, "Random Variation:")
      im.PushItemWidth(-1)
      im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
      im.Columns(2, 'jitterPropertiesCols', false)
      im.SetColumnWidth(0, 30)

      -- Jitter forward slider.
      if selSpline.jitterForward ~= defaultParams.jitterForward then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetJitterForwardBtn') then
          local preEditState = splineMgr.deepCopyAssemblySpline(selSpline)
          selSpline.jitterForward = defaultParams.jitterForward
          selSpline.isDirty = true
          editor.history:commitAction("Reset Pitch Jitter", { old = preEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
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
      im.tooltip('Set the amount of random jitter to apply to the components, around the local Y-axis (pitch) .')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyAssemblySpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Pitch Jitter", { old = sliderPreEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      -- Jitter right slider.
      if selSpline.jitterRight ~= defaultParams.jitterRight then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetJitterRightBtn') then
          local preEditState = splineMgr.deepCopyAssemblySpline(selSpline)
          selSpline.jitterRight = defaultParams.jitterRight
          selSpline.isDirty = true
          editor.history:commitAction("Reset Yaw Jitter", { old = preEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
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
      im.tooltip('Set the amount of random jitter to apply to the components, around the local X-axis (yaw).')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyAssemblySpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Yaw Jitter", { old = sliderPreEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      -- Jitter up slider.
      if selSpline.jitterUp ~= defaultParams.jitterUp then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetJitterUpBtn') then
          local preEditState = splineMgr.deepCopyAssemblySpline(selSpline)
          selSpline.jitterUp = defaultParams.jitterUp
          selSpline.isDirty = true
          editor.history:commitAction("Reset Roll Jitter", { old = preEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
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
      im.tooltip('Set the amount of random jitter to apply to the components, around the local Z-axis (roll).')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyAssemblySpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Roll Jitter", { old = sliderPreEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      -- Spline Random Seed slider.
      if selSpline.splineRandomSeed ~= defaultParams.splineRandomSeed then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetSplineRandomSeedBtn') then
          local preEditState = splineMgr.deepCopyAssemblySpline(selSpline)
          selSpline.splineRandomSeed = defaultParams.splineRandomSeed
          selSpline.isDirty = true
          editor.history:commitAction("Reset Random Seed", { old = preEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      tmpPtr = im.IntPtr(selSpline.splineRandomSeed)
      if im.SliderInt('###77360', tmpPtr, 0, maxRandomSeed, "Random Seed = %d") then
        selSpline.splineRandomSeed = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the random seed for the variation properties of the spline (spline jitter, component distribution, and join play).')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyAssemblySpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Spline Random Seed", { old = sliderPreEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()
      im.PopStyleVar() -- Pop GrabMinSize pushed for the jitter sliders.
      im.Columns(1)
      im.Separator()

      -- Preset buttons.
      im.TextColored(cols.greenB, "Presets:")
      im.Columns(3, "presetBtns", false)
      im.SetColumnWidth(0, 40)
      im.SetColumnWidth(1, 40)
      im.SetColumnWidth(2, 40)
      im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
      im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

      -- 'Wooden Fence' preset button.
      if editor.uiIconImageButton(icons.meshFence, iconsBig, cols.blueB, nil, nil, 'woodenFencePresetBtn') then
        local preEditState = splineMgr.deepCopyAssemblySpline(selSpline)
        splineMgr.setPreset(selSpline, 'wooden_fence')
        selSpline.isDirty = true
        editor.history:commitAction("Select Wooden Fence Preset", { old = preEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.tooltip('Select The Wooden Fence Preset.')
      im.SameLine()
      im.NextColumn()

      -- 'Telegraph Pole' preset button.
      if editor.uiIconImageButton(icons.call_end, iconsBig, cols.blueB, nil, nil, 'telegraphPolePresetBtn') then
        local preEditState = splineMgr.deepCopyAssemblySpline(selSpline)
        splineMgr.setPreset(selSpline, 'telegraph_pole')
        selSpline.isDirty = true
        editor.history:commitAction("Select Telegraph Pole Preset", { old = preEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.tooltip('Select The Telegraph Pole Preset.')
      im.SameLine()
      im.NextColumn()

      -- 'Metal Crash Barrier' preset button.
      if editor.uiIconImageButton(icons.concreteRoadBlock, iconsBig, cols.blueB, nil, nil, 'metalCrashBarrierPresetBtn') then
        local preEditState = splineMgr.deepCopyAssemblySpline(selSpline)
        splineMgr.setPreset(selSpline, 'metal_crash_barrier')
        selSpline.isDirty = true
        editor.history:commitAction("Select Metal Crash Barrier Preset", { old = preEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.tooltip('Select The Metal Crash Barrier Preset.')
      im.NextColumn()
      im.PopStyleVar(2)
      im.Separator()
      im.Columns(1)

      -- Tab bar for organising the interface.
      local selectedTab = 0 -- Default to first tab.
      if im.BeginTabBar("AssemblySplineTabs") then
        if im.BeginTabItem("Assembly Kit") then
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
        if selectedTab == 0 then
          -- Kit source selection (folder vs imported).
          if selSpline.isImported then -- Show imported kit information.
            im.Columns(3, "staticMeshSelectionColumnsA", false)
            im.SetColumnWidth(0, 60)
            im.SetColumnWidth(1, 40)
            im.TextColored(cols.blueB, 'Imported Kit:')
            im.SameLine()
            im.NextColumn()
            im.Dummy(iconsSmall)
            im.SameLine()
            im.NextColumn()
            im.SetCursorPosY(im.GetCursorPosY() + max(0, (iconsSmall.y - im.GetTextLineHeight()) * 0.5))
            local sourceCount = selSpline.importedKit and #selSpline.importedKit.sourceMeshPaths or 0
            im.TextColored(cols.blueB, string.format('[Imported from %d TSStatics]', sourceCount))
            im.tooltip('This assembly spline was imported from scene TSStatic objects.')
          else -- Show folder selection for non-imported kits.
            im.Columns(2, "staticMeshSelectionColumnsB", false)
            im.SetColumnWidth(0, 40)
            if editor.uiIconImageButton(icons.folder, iconsSmall, cols.blueB, nil, nil, 'selectMeshKitBtn') then
              extensions.editor_fileDialog.openFile(
              function(data)
                if data.path then
                  local preState = splineMgr.deepCopyAssemblySplineState()
                  pop.tryRemove(selSpline)
                  selSpline.kitFolderPath = data.path
                  selSpline.meshKit = mol.getAssemblyKit(data.path)
                  selSpline.moleculeDescription = mol.buildMolecule(selSpline.meshKit, selSpline)
                  selSpline.preRot = 0
                  selSpline.isDirty = true
                  editor.history:commitAction("Select Mesh Kit", { old = preState, new = splineMgr.deepCopyAssemblySplineState() }, splineMgr.objectSelectUndo, splineMgr.objectSelectRedo, true)
                end
              end,
              {{"All Folders","*"}},
              true,
              kitSearchPath)
            end
            im.tooltip('Select the Assembly Kit folder.')
            im.SameLine()
            im.NextColumn()
            im.SetCursorPosY(im.GetCursorPosY() + max(0, (iconsSmall.y - im.GetTextLineHeight()) * 0.5))
            if selSpline.kitFolderPath then
              im.Text('[' .. selSpline.kitFolderPath .. ']')
            else
              im.Text('[No assembly kit selected]')
            end
            im.tooltip('The currently-selected Assembly Kit folder.')
          end
          im.NextColumn()
          im.Dummy(im.ImVec2(0, 3))

          -- Molecule components (available for both imported and non-imported kits).
          im.Columns(1)
          im.Separator()
          molecule = selSpline.moleculeDescription
          if molecule and (molecule.rigids or molecule.bridges) then
            if molecule.rigids and #molecule.rigids > 0 then
              im.Dummy(im.ImVec2(0, 5))
              im.TextColored(cols.greenB, "Molecule Components:")
              im.Columns(4, "rigidComponentsColumns", true)
              im.SetColumnWidth(0, 40)
              im.SetColumnWidth(1, 145)
              im.SetColumnWidth(2, 60)
              im.SetColumnWidth(3, 160)

              -- Rigid column headers.
              im.Text("Use")
              im.SameLine()
              im.NextColumn()
              im.Text("Mesh")
              im.SameLine()
              im.NextColumn()
              im.Text("Role")
              im.SameLine()
              im.NextColumn()
              im.Text("Var")
              im.NextColumn()
              im.Separator()

              -- Rigid meshes - display in placement order (root first, then children in attachment order).
              local rigids = molecule.rigids
              local placingOrder = molecule.placingOrder
              for i = 1, #placingOrder do
                local rigidIdx = placingOrder[i]
                local rigid = rigids[rigidIdx]
                local mesh = rigid.mesh
                local isRoot = mesh.fileName and mesh.fileName:lower():find("root")

                if isRoot then
                  -- Root mesh - no checkbox, just blank column.
                  im.Text("")
                  im.SameLine()
                  im.NextColumn()
                else
                  -- Non-root mesh - show checkbox.
                  tmpPtr = im.BoolPtr(mol.getRigidEnabled(selSpline, mesh.id))
                  if im.Checkbox("###rigid" .. tostring(49925 + rigidIdx), tmpPtr) then
                    local preState = splineMgr.deepCopyAssemblySpline(selSpline)
                    mol.setRigidEnabled(selSpline, mesh.id, tmpPtr[0])
                    selSpline.isDirty = true
                    editor.history:commitAction("Toggle Rigid Component", { old = preState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                  end
                  im.tooltip(mol.getRigidEnabled(selSpline, mesh.id) and 'Do not include this component in the assembly.' or 'Include this component in the assembly.')
                  im.SameLine()
                  im.NextColumn()
                end

                -- Show the mesh file name.
                im.TextColored(cols.purpleB, mesh.fileName)
                im.tooltip(mesh.meshPath)
                im.SameLine()
                im.NextColumn()

                -- Check if this is the root mesh.
                isRoot = mesh.fileName and mesh.fileName:lower():find("root")
                local isEnabled = mol.getRigidEnabled(selSpline, mesh.id)

                if isRoot then
                  im.TextColored(cols.redB, "[root]")
                  im.tooltip("The root mesh of the molecule.")
                elseif isEnabled then
                  im.TextColored(cols.dullWhite, "[child]")
                  im.tooltip("A child mesh of the molecule.")
                end
                -- If disabled and not root, show nothing (blank column).
                im.SameLine()
                im.NextColumn()

                im.Text("")
                im.NextColumn()
                im.Separator()

                -- Variations for this rigid.
                local variations = rigid.variations
                for j, variation in ipairs(variations) do
                  -- All variations (including root variations) have enable/disable checkboxes.
                  local varTmpPtr = im.BoolPtr(mol.getRigidEnabled(selSpline, variation.id))
                  if im.Checkbox("###rigidVar" .. tostring(49925 + rigidIdx) .. "_" .. tostring(j), varTmpPtr) then
                    local preState = splineMgr.deepCopyAssemblySpline(selSpline)
                    mol.setRigidEnabled(selSpline, variation.id, varTmpPtr[0])
                    selSpline.isDirty = true
                    editor.history:commitAction("Toggle Rigid Variation", { old = preState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                  end
                  im.tooltip(mol.getRigidEnabled(selSpline, variation.id) and 'Do not include this variation in the assembly.' or 'Include this variation in the assembly.')
                  im.SameLine()
                  im.NextColumn()
                  im.TextColored(cols.dullWhite, " * " .. variation.fileName)
                  im.tooltip(variation.meshPath)
                  im.SameLine()
                  im.NextColumn()
                  im.Text("")
                  im.SameLine()
                  im.NextColumn()
                  im.TextColored(cols.dullWhite, "var" .. tostring(j))
                  im.tooltip("This is variation " .. tostring(j) .. " of the base component.")
                  im.NextColumn()
                  im.Separator()
                end
              end
              im.Columns(1)
            end

            -- Bridge components.
            if molecule.bridges and #molecule.bridges > 0 then
              im.Columns(1)
              im.Dummy(im.ImVec2(0, 5))
              im.TextColored(cols.greenB, "Bridge Components:")
              im.Columns(4, "bridgeComponentsColumns", true)
              im.SetColumnWidth(0, 40)
              im.SetColumnWidth(1, 145)
              im.SetColumnWidth(2, 60)
              im.SetColumnWidth(3, 160)

              -- Bridge column headers.
              im.Text("Use")
              im.SameLine()
              im.NextColumn()
              im.Text("Mesh")
              im.SameLine()
              im.NextColumn()
              im.Text("Alias")
              im.SameLine()
              im.NextColumn()
              im.Text("Var")
              im.NextColumn()
              im.Separator()

              -- Bridge meshes.
              local bridges = molecule.bridges
              for i = 1, #bridges do
                local bridge = bridges[i]
                local mesh = bridge.mesh
                tmpPtr = im.BoolPtr(mol.getBridgeEnabled(selSpline, mesh.id))
                if im.Checkbox("###bridge" .. tostring(49925 + i), tmpPtr) then
                  local preState = splineMgr.deepCopyAssemblySpline(selSpline)
                  mol.setBridgeEnabled(selSpline, mesh.id, tmpPtr[0])
                  selSpline.isDirty = true
                  editor.history:commitAction("Toggle Bridge Component", { old = preState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip(mol.getBridgeEnabled(selSpline, mesh.id) and 'Do not include this bridge in the assembly.' or 'Include this bridge in the assembly.')
                im.SameLine()
                im.NextColumn()

                -- Show the mesh file name.
                im.TextColored(cols.purpleB, mesh.fileName)
                im.tooltip(mesh.meshPath)
                im.SameLine()
                im.NextColumn()

                -- Show the alias name for this bridge instance.
                local aliasName = "main"
                if molecule.bridgeAttachments and molecule.bridgeAttachments[i] then
                  local bridgeAttachData = molecule.bridgeAttachments[i]
                  if bridgeAttachData.sourceMeshIdx and bridgeAttachData.sourceAttachmentIdx then
                    local sourceRigid = molecule.rigids[bridgeAttachData.sourceMeshIdx]
                    if sourceRigid and sourceRigid.attachments[bridgeAttachData.sourceAttachmentIdx] then
                      aliasName = sourceRigid.attachments[bridgeAttachData.sourceAttachmentIdx].aliasName or "main"
                    end
                  end
                end
                im.TextColored(cols.redB, string.format("[%s]", aliasName))
                im.tooltip("The alias name for this bridge instance.")
                im.SameLine()
                im.NextColumn()

                im.Text("")
                im.NextColumn()
                im.Separator()

                -- Variations for this bridge.
                local variations = bridge.variations
                for j, variation in ipairs(variations) do
                  local varTmpPtr = im.BoolPtr(mol.getBridgeEnabled(selSpline, variation.id))
                  if im.Checkbox("###bridgeVar" .. tostring(49925 + i) .. "_" .. tostring(j), varTmpPtr) then
                    local preState = splineMgr.deepCopyAssemblySpline(selSpline)
                    mol.setBridgeEnabled(selSpline, variation.id, varTmpPtr[0])
                    selSpline.isDirty = true
                    editor.history:commitAction("Toggle Bridge Variation", { old = preState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                  end
                  im.tooltip(mol.getBridgeEnabled(selSpline, variation.id) and 'Do not include this variation in the assembly.' or 'Include this variation in the assembly.')
                  im.SameLine()
                  im.NextColumn()
                  im.TextColored(cols.dullWhite, " * " .. variation.fileName)
                  im.tooltip(variation.meshPath)
                  im.SameLine()
                  im.NextColumn()
                  im.Text("")
                  im.SameLine()
                  im.NextColumn()
                  im.TextColored(cols.dullWhite, "var" .. tostring(j))
                  im.tooltip("This is variation " .. tostring(j) .. " of the base component.")
                  im.NextColumn()
                  im.Separator()
                end
              end
              im.Columns(1)
            end
          else
            im.TextColored(cols.redB, 'No assembly kit selected.')
            im.Text('Select a folder containing assembly meshes to continue.')
          end
        elseif selectedTab == 1 then -- Distribution tab.
          local isDistContent = false
          molecule = selSpline.moleculeDescription
          if molecule and molecule.rigids then
            local wCtr = 44428
            local placingOrder = molecule.placingOrder
            for i = 1, #placingOrder do -- Process rigid components in placement order.
              local rigidIdx = placingOrder[i]
              local rigid = molecule.rigids[rigidIdx]
              local baseMesh = rigid.mesh
              local variations = rigid.variations

              -- Check if there are at least 2 enabled meshes in this component set (base + variations).
              local enabledCount = 0
              if mol.getRigidEnabled(selSpline, baseMesh.id) then
                enabledCount = enabledCount + 1
              end
              for _, variation in ipairs(variations) do
                if mol.getRigidEnabled(selSpline, variation.id) then
                  enabledCount = enabledCount + 1
                end
              end

              if enabledCount >= 2 then
                im.TextColored(cols.greenB, baseMesh.fileName:gsub("%.dae$", ""))
                local isRoot = baseMesh.fileName and baseMesh.fileName:lower():find("root")
                if isRoot then
                  im.SameLine()
                  im.TextColored(cols.redB, "[root]") -- Add indicator for root mesh.
                end
                im.SameLine()
                im.TextColored(cols.greenB, ":")

                -- Distribution radio buttons.
                tmpPtr = im.IntPtr(rigid.isRandom and 1 or 0)
                im.Columns(2, "DistributionCols" .. rigidIdx, false)
                if im.RadioButton2("Round Robin###" .. tostring(wCtr), tmpPtr, 0) then
                  local statePre = splineMgr.deepCopyAssemblySpline(selSpline)
                  rigid.isRandom = false
                  tmpPtr[0] = 0
                  selSpline.isDirty = true
                  editor.history:commitAction("Set Round Robin", { old = statePre, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip('Use round robin pattern for this component set.')
                wCtr = wCtr + 1
                im.SameLine()
                im.NextColumn()
                if im.RadioButton2("Random###" .. tostring(wCtr), tmpPtr, 1) then
                  local statePre = splineMgr.deepCopyAssemblySpline(selSpline)
                  rigid.isRandom = true
                  tmpPtr[0] = 1
                  selSpline.isDirty = true
                  editor.history:commitAction("Set Random", { old = statePre, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip('Use random pattern for this component set.')
                wCtr = wCtr + 1
                im.NextColumn()
                im.Columns(1)

                -- Weight sliders (only if random is selected).
                if rigid.isRandom then
                  -- Base mesh weight slider.
                  if mol.getRigidEnabled(selSpline, baseMesh.id) then
                    im.PushItemWidth(-1)
                    im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
                    im.Columns(2, "WeightCols" .. rigidIdx, false)
                    im.SetColumnWidth(0, 30)

                    if rigid.randomWeight < 1.0 then
                      if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetBaseWeightBtn' .. rigidIdx) then
                        local statePre = splineMgr.deepCopyAssemblySpline(selSpline)
                        rigid.randomWeight = 1.0
                        selSpline.isDirty = true
                        editor.history:commitAction("Reset Base Weight", { old = statePre, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                      end
                      im.tooltip("Reset to default.")
                    else
                      im.Dummy(iconsSmall)
                    end
                    im.SameLine()
                    im.NextColumn()
                    im.PushItemWidth(-1)
                    tmpPtr = im.FloatPtr(rigid.randomWeight)
                    if im.SliderFloat('###baseWeight' .. rigidIdx, tmpPtr, 0.0, 1.0, "Base Weight = %.2f") then
                      rigid.randomWeight = tmpPtr[0]
                      selSpline.isDirty = true
                    end
                    im.tooltip("Set the weight for the base component.")
                    if im.IsItemActivated() then
                      sliderPreEditState = splineMgr.deepCopyAssemblySpline(selSpline)
                    end
                    if im.IsItemDeactivatedAfterEdit() then
                      editor.history:commitAction("Adjust Base Weight", { old = sliderPreEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                    end
                    im.PopItemWidth()
                    im.NextColumn()

                    im.Columns(1)
                    im.PopStyleVar()
                    im.PopItemWidth()
                  end

                  -- Variation weight sliders.
                  for j, variation in ipairs(variations) do
                    if mol.getRigidEnabled(selSpline, variation.id) then
                      im.PushItemWidth(-1)
                      im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
                      im.Columns(2, "WeightCols" .. rigidIdx .. "_" .. j, false)
                      im.SetColumnWidth(0, 30)

                      if variation.randomWeight < 1.0 then
                        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetVarWeightBtn' .. rigidIdx .. '_' .. j) then
                          local statePre = splineMgr.deepCopyAssemblySpline(selSpline)
                          variation.randomWeight = 1.0
                          selSpline.isDirty = true
                          editor.history:commitAction("Reset Variation Weight", { old = statePre, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                        end
                        im.tooltip("Reset to default.")
                      else
                        im.Dummy(iconsSmall)
                      end
                      im.SameLine()
                      im.NextColumn()
                      im.PushItemWidth(-1)
                      tmpPtr = im.FloatPtr(variation.randomWeight)
                      if im.SliderFloat('###varWeight' .. rigidIdx .. '_' .. j, tmpPtr, 0.0, 1.0, "Var" .. j .. " Weight = %.2f") then
                        variation.randomWeight = tmpPtr[0]
                        selSpline.isDirty = true
                      end
                      im.tooltip("Set the weight for variation " .. tostring(j) .. ".")
                      if im.IsItemActivated() then
                        sliderPreEditState = splineMgr.deepCopyAssemblySpline(selSpline)
                      end
                      if im.IsItemDeactivatedAfterEdit() then
                        editor.history:commitAction("Adjust Variation Weight", { old = sliderPreEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                      end
                      im.PopItemWidth()
                      im.NextColumn()

                      im.Columns(1)
                      im.PopStyleVar()
                      im.PopItemWidth()
                    end
                  end
                end
                im.Separator()
                isDistContent = true
              end
            end

            -- Process bridge components.
            for i, bridge in ipairs(molecule.bridges) do
              local baseMesh = bridge.mesh
              local variations = bridge.variations
              local aliasName = "main" -- Default alias name

              -- Check if there are at least 2 enabled meshes in this component set (base + variations).
              local enabledCount = 0
              if mol.getBridgeEnabled(selSpline, baseMesh.id) then
                enabledCount = enabledCount + 1
              end
              for _, variation in ipairs(variations) do
                if mol.getBridgeEnabled(selSpline, variation.id) then
                  enabledCount = enabledCount + 1
                end
              end

              if enabledCount >= 2 then
                -- Get the alias name for this bridge instance.
                if molecule.bridgeAttachments and molecule.bridgeAttachments[i] then
                  local bridgeAttachData = molecule.bridgeAttachments[i]
                  if bridgeAttachData.sourceMeshIdx and bridgeAttachData.sourceAttachmentIdx then
                    local sourceRigid = molecule.rigids[bridgeAttachData.sourceMeshIdx]
                    if sourceRigid and sourceRigid.attachments[bridgeAttachData.sourceAttachmentIdx] then
                      aliasName = sourceRigid.attachments[bridgeAttachData.sourceAttachmentIdx].aliasName or "main"
                    end
                  end
                end

                -- Show the mesh file name.
                local headerText = baseMesh.fileName:gsub("%.dae$", "")
                im.TextColored(cols.greenB, headerText)
                if aliasName ~= "main" then
                  im.SameLine()
                  im.TextColored(cols.redB, string.format("[%s]", aliasName)) -- Include the alias name, if this is an aliased entry.
                end
                im.SameLine()
                im.TextColored(cols.greenB, ':')

                -- Distribution radio buttons.
                tmpPtr = im.IntPtr(bridge.isRandom and 1 or 0)
                im.Columns(2, "BridgeDistributionCols" .. i, false)
                if im.RadioButton2("Round Robin###" .. tostring(wCtr), tmpPtr, 0) then
                  local statePre = splineMgr.deepCopyAssemblySpline(selSpline)
                  bridge.isRandom = false
                  tmpPtr[0] = 0
                  selSpline.isDirty = true
                  editor.history:commitAction("Set Bridge Round Robin", { old = statePre, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip('Use round robin pattern for this bridge component set.')
                wCtr = wCtr + 1
                im.SameLine()
                im.NextColumn()
                if im.RadioButton2("Random###" .. tostring(wCtr), tmpPtr, 1) then
                  local statePre = splineMgr.deepCopyAssemblySpline(selSpline)
                  bridge.isRandom = true
                  tmpPtr[0] = 1
                  selSpline.isDirty = true
                  editor.history:commitAction("Set Bridge Random", { old = statePre, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip('Use random pattern for this bridge component set.')
                wCtr = wCtr + 1
                im.NextColumn()
                im.Columns(1)

                -- Weight sliders (only if random is selected).
                if bridge.isRandom then
                  -- Base mesh weight slider.
                  if mol.getBridgeEnabled(selSpline, baseMesh.id) then
                    im.PushItemWidth(-1)
                    im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
                    im.Columns(2, "BridgeWeightCols" .. i, false)
                    im.SetColumnWidth(0, 30)

                    if bridge.randomWeight < 1.0 then
                      if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetBridgeBaseWeightBtn' .. i) then
                        local statePre = splineMgr.deepCopyAssemblySpline(selSpline)
                        bridge.randomWeight = 1.0
                        selSpline.isDirty = true
                        editor.history:commitAction("Reset Bridge Base Weight", { old = statePre, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                      end
                      im.tooltip("Reset to default.")
                    else
                      im.Dummy(iconsSmall)
                    end
                    im.SameLine()
                    im.NextColumn()
                    im.PushItemWidth(-1)
                    tmpPtr = im.FloatPtr(bridge.randomWeight)
                    if im.SliderFloat('###bridgeBaseWeight' .. i, tmpPtr, 0.0, 1.0, "Base Weight = %.2f") then
                      bridge.randomWeight = tmpPtr[0]
                      selSpline.isDirty = true
                    end
                    im.tooltip("Set the weight for the bridge base component.")
                    if im.IsItemActivated() then
                      sliderPreEditState = splineMgr.deepCopyAssemblySpline(selSpline)
                    end
                    if im.IsItemDeactivatedAfterEdit() then
                      editor.history:commitAction("Adjust Bridge Base Weight", { old = sliderPreEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                    end
                    im.PopItemWidth()
                    im.NextColumn()

                    im.Columns(1)
                    im.PopStyleVar()
                    im.PopItemWidth()
                  end

                  -- Variation weight sliders.
                  for j, variation in ipairs(variations) do
                    if mol.getBridgeEnabled(selSpline, variation.id) then
                      im.PushItemWidth(-1)
                      im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
                      im.Columns(2, "BridgeWeightCols" .. i .. "_" .. j, false)
                      im.SetColumnWidth(0, 30)

                      if variation.randomWeight < 1.0 then
                        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetBridgeVarWeightBtn' .. i .. '_' .. j) then
                          local statePre = splineMgr.deepCopyAssemblySpline(selSpline)
                          variation.randomWeight = 1.0
                          selSpline.isDirty = true
                          editor.history:commitAction("Reset Bridge Variation Weight", { old = statePre, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                        end
                        im.tooltip("Reset to default.")
                      else
                        im.Dummy(iconsSmall)
                      end
                      im.SameLine()
                      im.NextColumn()
                      im.PushItemWidth(-1)
                      tmpPtr = im.FloatPtr(variation.randomWeight)
                      if im.SliderFloat('###bridgeVarWeight' .. i .. '_' .. j, tmpPtr, 0.0, 1.0, "Var" .. j .. " Weight = %.2f") then
                        variation.randomWeight = tmpPtr[0]
                        selSpline.isDirty = true
                      end
                      im.tooltip("Set the weight for bridge variation " .. tostring(j) .. ".")
                      if im.IsItemActivated() then
                        sliderPreEditState = splineMgr.deepCopyAssemblySpline(selSpline)
                      end
                      if im.IsItemDeactivatedAfterEdit() then
                        editor.history:commitAction("Adjust Bridge Variation Weight", { old = sliderPreEditState, new = splineMgr.deepCopyAssemblySpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                      end
                      im.PopItemWidth()
                      im.NextColumn()

                      im.Columns(1)
                      im.PopStyleVar()
                      im.PopItemWidth()
                      isDistContent = true
                    end
                  end
                end
                im.Separator()
              end
            end
            if not isDistContent then
              im.Text('No variations available in this assembly kit.')
            end
          else
          im.Text('Select an assembly kit first.')
          end

        elseif selectedTab == 2 then -- Terrain tab.
          if selSpline.isConformToTerrain then
            im.TextColored(cols.greenB, "Spline Is Conformed To Surface")
            im.Text("Terraforming controls are disabled.")
          else
            im.TextColored(cols.greenB, "Terraforming:")
            im.Columns(2, "terrainSlidersRow_assembly", false)
            im.SetColumnWidth(0, 30)

          -- 'DOI' slider.
          if terraParams.terraDOI ~= 50.0 then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetDOI_assembly') then
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
          if im.SliderFloat('###assembly_doi', tmpPtr, DOImin, DOImax, "DOI = %.2f") then
            terraParams.terraDOI = tmpPtr[0]
          end
          im.tooltip('Set the Domain Of Influence, in meters.')
          im.PopItemWidth()
          im.NextColumn()

          -- 'Terraform Margin' slider.
          if terraParams.terraMargin ~= 5.0 then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetMargin_assembly') then
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
          if im.SliderFloat('###assembly_margin', tmpPtr, terraMarginMin, terraMarginMax, "Terraform Margin = %.2f") then
            terraParams.terraMargin = tmpPtr[0]
          end
          im.PopItemWidth()
          im.NextColumn()

          -- 'Terraform Falloff' slider.
          if terraParams.terraFalloff ~= 2.0 then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetFalloff_assembly') then
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
          if im.SliderFloat('###assembly_falloff', tmpPtr, terraFalloffMin, terraFalloffMax, "Terraform Falloff = %.2f") then
            terraParams.terraFalloff = tmpPtr[0]
          end
          im.PopItemWidth()
          im.NextColumn()

          -- 'Terraform Roughness' slider.
          if terraParams.terraRoughness ~= 0.0 then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetRough_assembly') then
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
          if im.SliderFloat('###assembly_rough', tmpPtr, 0.0, 1.0, "Noise Roughness = %.2f") then
            terraParams.terraRoughness = tmpPtr[0]
          end
          im.PopItemWidth()
          im.NextColumn()

          -- 'Terraform Scale' slider.
          if terraParams.terraScale ~= 0.0 then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetScale_assembly') then
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
          if im.SliderFloat('###assembly_scale', tmpPtr, 0.0, 1.0, "Noise Scale = %.2f") then
            terraParams.terraScale = tmpPtr[0]
          end
          im.PopItemWidth()
          im.NextColumn()

          im.Columns(1)

          -- 'Terraform To Assembly Spline' button.
          if selSpline and selSpline.isEnabled and not selSpline.isLink and #selSpline.nodes > 1 and not selSpline.isConformToTerrain then
            if editor.uiIconImageButton(icons.terrainToLine, iconsBig, cols.blueB, nil, nil, 'terraformToAssemblySplineBtn') then
              local sources = util.getSourcesSingle(selSpline)
              terra.terraformToSources(terraParams.terraDOI, terraParams.terraMargin, terraParams.terraFalloff, terraParams.terraRoughness, terraParams.terraScale, sources)
            end
            im.tooltip('Terraform the terrain to the selected Assembly Spline.')
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
      im.Text("No assembly splines.")
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

  -- Ensure all assembly splines are updated, even if this tool is not active.
  -- [This ensures any linked assembly splines are also updated.]
  splineMgr.updateDirtyAssemblySplines()

  -- If this tool is not active, render the shells of the splines but do nothing further.
  if not isAssemblySplineActive then
    render.renderShells(splineMgr.getAssemblySplines())
    return
  end

  -- Handle the main tool window UI.
  handleMainToolWindowUI()

  -- Handle the front end if the user is drawing a selection polygon.
  if isDrawPolygon then
    poly.handleUserPolygon(onSelectionPolygonComplete)
    return -- Don't do anything further if the user is drawing a selection polygon.
  end

  -- Handle the mouse and keyboard events.
  local splines = splineMgr.getAssemblySplines()
  local isConformToTerrain = selectedSplineIdx and splines[selectedSplineIdx] and splines[selectedSplineIdx].isConformToTerrain
  out.spline, out.node, out.isGizmoActive, out.isLockShape = selectedSplineIdx, selectedNodeIdx, isGizmoActive, isLockShape
  input.handleSplineEvents(
    splines,
    out,
    false, isConformToTerrain, false, false, false, true, true, isLockShape,
    defaultSplineWidth,
    splineMgr.deepCopyAssemblySpline, splineMgr.deepCopyAssemblySplineState,
    splineMgr.copyAssemblySplineProfile, splineMgr.pasteAssemblySplineProfile,
    nil,
    splineMgr.joinAssemblySplines,
    splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo,
    splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo)
  selectedSplineIdx, selectedNodeIdx, isGizmoActive, isLockShape = out.spline, out.node, out.isGizmoActive, out.isLockShape

  -- Render the assembly splines with debugDraw (only if not linked to master spline).
  local selSpline = splines[selectedSplineIdx]
  if selSpline then
    render.handleSplineRendering(splines, selectedSplineIdx, selectedNodeIdx, isGizmoActive, false, isLockShape, true, false, elevScale)

    -- Render polylines for assembly splines.
    render.renderSplinePolylines(splines, selectedSplineIdx)
  end
end

-- Called when the tool mode icon is pressed.
local function onActivate()
  isDrawPolygon = false
  poly.clearPolygon() -- Ensure there is no residual polygon left over from the previous usage.
  editor.clearObjectSelection()
  editor.showWindow(toolWinName)
  isAssemblySplineActive = true
end

-- Called when the tool is exited.
local function onDeactivate()
  isDrawPolygon = false
  poly.clearPolygon() -- Ensure there is no residual polygon left over from the previous usage.
  editor.hideWindow(toolWinName)
  isAssemblySplineActive = false
end

-- Validates the selection for the scenetree right click menu.
local function validateSceneTreeRightClickMenuSelection(node)
  if node then
    local validCtr = 0
    for _, objId in ipairs(editor.selection.object) do
      local obj = scenetree.findObjectById(objId)
      if obj and obj:getClassName() == "TSStatic" then
        if import.validateToolCompatibleTSStatic(obj) then
          validCtr = validCtr + 1
          if validCtr >= 2 then -- Need at least two tool-compatible static meshes to convert to an assembly spline.
            return true
          end
        end
      end
    end
  end
  return false
end

-- Called on scenetree right click menu, if validated.
local function processSceneTreeRightClickMenuSelection(node)
  if node then
    import.convertTSStatics2AssemblySpline(editor.selection.object)
  end
end

-- Called upon world editor initialization.
local function onEditorInitialized()
  editor.editModes.assemblySplineEditMode = {
    displayName = "Assembly Spline",
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    icon = editor.icons.gyroscope,
    iconTooltip = "AssemblySpline",
    auxShortcuts = {},
    hideObjectIcons = true }
  editor.registerWindow(toolWinName, toolWinSize)

  -- Set up the scenetree right click menu for importing.
  editor.addExtendedSceneTreeObjectMenuItem({
    title = "Convert to Assembly Spline",
    extendedSceneTreeObjectMenuItems = processSceneTreeRightClickMenuSelection,
    validator = validateSceneTreeRightClickMenuSelection })
end

-- Called when leaving the map.
local function onClientEndMission()
  splineMgr.removeAllAssemblySplines(true) -- We remove all assembly splines (even disabled), so we don't have to worry about bad TSStatic pointers post-load.
end


-- Public interface.
M.setSelectedSplineIdx =                                  setSelectedSplineIdx
M.setSelectedNodeIdx =                                    setSelectedNodeIdx

M.onSerialize =                                           onSerialize
M.onDeserialized =                                        onDeserialized

M.onEditorGui =                                           onEditorGui
M.onEditorInitialized =                                   onEditorInitialized
M.onClientEndMission =                                    onClientEndMission

return M
