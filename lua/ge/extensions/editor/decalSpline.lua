-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local simplifyRdpTol = 9.0 -- The tolerance for the RDP simplification of the spline.

local minSpacing, maxSpacing = 0.0, 100.0 -- The minimum and maximum allowed spacing of the decal components.

local defaultSplineWidth = 10.0 -- The default width for a spline when adding a new node, in meters.

local elevScale = 100.0 -- The scale factor for the elevation drop lines (used for blue->red colour transition).

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- External modules.
local splineMgr = require('editor/decalSpline/splineMgr')
local pop = require('editor/decalSpline/populate')
local materialSelectionMgr = require('editor/toolUtilities/materialSelectionMgr')
local input = require('editor/toolUtilities/splineInput')
local render = require('editor/toolUtilities/render')
local skeleton = require('editor/toolUtilities/skeleton')
local rdp = require('editor/toolUtilities/rdp')
local maskExport = require('editor/toolUtilities/splineMaskExport')
local util = require('editor/toolUtilities/util')
local geom = require('editor/toolUtilities/geom')
local style = require('editor/toolUtilities/style')

-- Register this tool with the shared spline input utilities.
input.registerSplineTool(
  splineMgr.getToolPrefixStr(),
  splineMgr.getDecalSplines,
  splineMgr.getEditModeKey,
  splineMgr.deepCopyDecalSpline,
  splineMgr.deepCopyDecalSplineState,
  'editor_decalSpline'
)

-- Module constants.
local im = ui_imgui
local min, max = math.min, math.max
local toolWinName, toolWinSize = 'decalSpline', im.ImVec2(300, 700)
local defaultParams = splineMgr.getDefaultSliderParams()
local cols = style.getImguiCols('crystal')
local iconsSmall, iconsBig = im.ImVec2(24, 24), im.ImVec2(36, 36)

-- Module state.
local isDecalSplineActive = false
local isLockShape = false
local materialTarget = 'Component 1'
local selectedComponentTab = 1
local isGizmoActive = false
local selectedSplineIdx, selectedNodeIdx = 1, 1
local sliderPreEditState = nil
local out = {
  spline = selectedSplineIdx,
  node = selectedNodeIdx,
  isGizmoActive = isGizmoActive,
  isLockShape = isLockShape,
}


-- Sets the selected spline index (for cross-tool selection).
local function setSelectedSplineIdx(idx) selectedSplineIdx = idx end

-- Sets the selected node index (for cross-tool selection).
local function setSelectedNodeIdx(idx) selectedNodeIdx = idx end

-- Serialise callback.
local function onSerialize()
  local decalSplines = splineMgr.getDecalSplines()
  if #decalSplines < 1 then
    return {} -- Return an empty table if there are no decal splines.
  end
  local decalSplinesSer = {}
  for i = 1, #decalSplines do
    local spline = decalSplines[i]
    local data = splineMgr.serializeDecalSpline(spline)
    decalSplinesSer[#decalSplinesSer + 1] = data
  end
  splineMgr.removeAllDecalSplines()
  return decalSplinesSer
end

-- Deserialise callback.
local function onDeserialized(data)
  if data and #data > 0 then
    local decalSplines = splineMgr.getDecalSplines()
    table.clear(decalSplines)
    for i = 1, #data do
      local spline = splineMgr.deserializeDecalSpline(data[i], true)
      decalSplines[#decalSplines + 1] = spline
    end
    selectedSplineIdx = max(1, min(#decalSplines, selectedSplineIdx))

    -- Update the spline map.
    util.computeIdToIdxMap(decalSplines, splineMgr.getSplineMap())
  end
end

-- Handles the main tool window.
local function handleMainToolWindowUI()
  if editor.beginWindow(toolWinName, "Decal Spline###1144", im.WindowFlags_NoCollapse) then
    local icons = editor.icons
    local decalSplines = splineMgr.getDecalSplines()
    selectedSplineIdx = max(1, min(#decalSplines, selectedSplineIdx)) -- Ensure the selected spline index is within bounds.

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

    -- 'Add New Decal Spline' button.
    if editor.uiIconImageButton(icons.bSpline, iconsBig, cols.blueB, nil, nil, 'addNewDecalSplineBtn') then
      local statePre = splineMgr.deepCopyDecalSplineState()
      splineMgr.addNewDecalSpline()
      selectedSplineIdx = #decalSplines
      editor.history:commitAction("Add New Decal Spline", { old = statePre, new = splineMgr.deepCopyDecalSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
    end
    im.tooltip('Add a new decal spline.')
    im.SameLine()
    im.NextColumn()

    -- 'Import From Bitmap Mask' button.
    if editor.uiIconImageButton(icons.floppyDiskPlus, iconsBig, cols.blueB, nil, nil, 'importFromBitmapMaskBtn') then
      extensions.editor_fileDialog.openFile(
        function(data)
          if data.filepath then
            local paths = skeleton.getPathsFromPng(data.filepath)
            if #paths > 0 then
              local preState = splineMgr.deepCopyDecalSplineState()
              splineMgr.convertPathsToDecalSplines(paths)
              editor.history:commitAction("Import Decal Splines From Bitmap", { old = preState, new = splineMgr.deepCopyDecalSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
            end
          end
        end,
        {{"PNG",".png"}},
        false,
        "/")
    end
    im.tooltip('Import decal splines from a bitmap mask.')
    im.SameLine()
    im.NextColumn()

    -- 'Remove All Decal Splines' button.
    if #decalSplines > 0 then
      if editor.uiIconImageButton(icons.trashBin2, iconsBig, cols.blueB, nil, nil, 'removeAllDecalSplinesBtn') then
        local statePre = splineMgr.deepCopyDecalSplineState()
        splineMgr.removeAllDecalSplines(false)
        selectedSplineIdx = 1
        editor.history:commitAction("Remove All Decal Splines", { old = statePre, new = splineMgr.deepCopyDecalSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
      end
      im.tooltip('Remove all (enabled and not linked) decal splines from the session.')
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Lock Shape' toggle button.
    local selSpline = decalSplines[selectedSplineIdx]
    if #decalSplines > 0 and selSpline and selSpline.isEnabled and not selSpline.isLink then
      local btnCol = isLockShape and cols.blueB or cols.blueD
      if editor.uiIconImageButton(icons.roadGuideArrowSolid, iconsBig, btnCol, nil, nil, 'lockShapeBtn') then
        isLockShape = not isLockShape
      end
      im.tooltip((isLockShape and 'Unlock the shape of the decal spline to move nodes separately' or 'Lock the shape of the decal spline to move nodes rigidly'))
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Export Spline Mask' button.
    if #decalSplines > 0 then
      if editor.uiIconImageButton(icons.folder, iconsBig, cols.blueB, nil, nil, 'exportSplineMaskBtn') then
        local sources = util.getAllSources(decalSplines)
        extensions.editor_fileDialog.saveFile(
          function(data)
            maskExport.export(data.filepath, sources, 1.0) -- TODO: Uses a 1m margin. Maybe make this a parameter later.
          end,
          {{"PNG",".png"}},
          false,
          "/",
          "File already exists.\nDo you want to overwrite the file?")
      end
      im.tooltip('Export the session as a .PNG mask file. Will not include any disabled Decal Splines.')
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- Save Decal State button.
    if #decalSplines > 0 then
      if editor.uiIconImageButton(icons.floppyDisk, iconsBig, nil, nil, nil, 'saveDecalStateBtn') then
        editor.saveDecals()
      end
      im.tooltip('Saves Decal State to disk.')
    else
      im.Dummy(iconsBig)
    end
    im.NextColumn()

    im.PopStyleVar(2)
    im.Columns(1)
    im.Separator()

    -- Decal splines list.
    if #decalSplines > 0 then
      im.TextColored(cols.greenB, "Decal Splines:")
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
        for i = 1, #decalSplines do
          local spline = decalSplines[i]
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
            im.tooltip('This decal spline is linked to a Master Spline. To edit or remove it, first unlink it from within the Master Spline Editor.')
          elseif not spline.isEnabled then
            im.TextColored(cols.dullWhite, spline.name)
            im.tooltip('This decal spline is disabled. To edit or remove it, first enable it.')
          else
            if im.InputText("###" .. tostring(wCtr), splineNamePtr, 32) then
              local preState = splineMgr.deepCopyDecalSpline(spline)
              spline.name = ffi.string(splineNamePtr)
              local postState = splineMgr.deepCopyDecalSpline(spline)
              editor.history:commitAction("Edit Decal Spline Name", { old = preState, new = postState }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
            end
            im.tooltip('Edit the decal spline name.')
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
              local statePre = splineMgr.deepCopyDecalSplineState()
              splineMgr.removeDecalSpline(i)
              if selectedSplineIdx > i then
                selectedSplineIdx = selectedSplineIdx - 1
              end
              selectedSplineIdx = max(1, min(#decalSplines, selectedSplineIdx))
              editor.history:commitAction("Remove Decal Spline", { old = statePre, new = splineMgr.deepCopyDecalSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
              editor.endWindow()
              return
            end
            im.tooltip('Remove this decal spline from the session.')
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()
          im.NextColumn()

          -- 'Enable/Disable' button.
          if not spline.isLink then
            local btnCol = spline.isEnabled and cols.blueB or cols.blueD
            local btnIcon = spline.isEnabled and icons.lock or icons.lock_open
            if editor.uiIconImageButton(btnIcon, iconsSmall, btnCol, nil, nil, 'lockUnlockDecalSplineToggleBtn' .. i) then
              local statePre = splineMgr.deepCopyDecalSpline(spline)
              spline.isEnabled = not spline.isEnabled
              spline.isDirty = true
              selectedSplineIdx = i
              editor.history:commitAction("Toggle Decal Spline Lock", { old = statePre, new = splineMgr.deepCopyDecalSpline(spline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
            end
            im.tooltip((spline.isEnabled and 'Disable' or 'Enable') .. ' this decal spline.')
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

      -- Buttons underneath the decal splines list box.
      im.Columns(6, "buttonsUnderneathListBox", false)
      im.SetColumnWidth(0, 39)
      im.SetColumnWidth(1, 39)
      im.SetColumnWidth(2, 39)
      im.SetColumnWidth(3, 39)
      im.SetColumnWidth(4, 39)
      im.SetColumnWidth(5, 39)
      im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
      im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

      -- 'Go To Selected Spline' button.
      if selSpline.nodes and #selSpline.nodes > 1 then
        if editor.uiIconImageButton(icons.cameraFocusTopDown, iconsBig, cols.blueB, nil, nil, 'goToSelectedSplineBtn') then
          util.goToSpline(selSpline.divPoints)
        end
        im.tooltip('Go to this decal spline (move camera).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Split Decal Spline' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink and selSpline.nodes[selectedNodeIdx] and #selSpline.nodes > 2 and (selSpline.isLoop or (selectedNodeIdx > 1 and selectedNodeIdx < #selSpline.nodes)) then
        if editor.uiIconImageButton(icons.content_cut, iconsBig, cols.blueB, nil, nil, 'splitDecalSplineBtn') then
          local statePre = splineMgr.deepCopyDecalSplineState()
          splineMgr.splitDecalSpline(selectedSplineIdx, selectedNodeIdx)
          selectedSplineIdx = #decalSplines
          editor.history:commitAction("Split New Decal Spline", { old = statePre, new = splineMgr.deepCopyDecalSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
        end
        im.tooltip('Splits the selected decal spline into two, at the selected node.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Flip Direction' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink and #selSpline.nodes > 1 then
        if editor.uiIconImageButton(icons.cached, iconsBig, cols.blueB, nil, nil, 'flipDirectionBtn') then
          local statePre = splineMgr.deepCopyDecalSpline(selSpline)
          geom.flipSplineDirection(selSpline)
          selSpline.isDirty = true
          editor.history:commitAction("Flip Decal Spline Direction", { old = statePre, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip('Flips the direction of the selected decal spline (back to front).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Simplify Spline' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink and selSpline.nodes[selectedNodeIdx] and #selSpline.nodes > 2 then
        if editor.uiIconImageButton(icons.routeSimple, iconsBig, cols.blueB, nil, nil, 'simplifySplineBtn') then
          local statePre = splineMgr.deepCopyDecalSpline(selSpline)
          rdp.simplifyNodesWidthsNormals(selSpline.nodes, selSpline.widths, selSpline.nmls, simplifyRdpTol)
          selectedNodeIdx = max(1, min(#selSpline.nodes, selectedNodeIdx))
          selSpline.isDirty = true
          editor.history:commitAction("Simplify Decal Spline", { old = statePre, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip('Simplifies the selected decal spline (reduces the number of nodes).')
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
              jsonWriteFile(data.filepath, splineMgr.copyDecalSplineProfile(selSpline), true)
            end,
            {{"JSON",".json"}},
            false,
            "/",
            "File already exists.\nDo you want to overwrite the file?")
        end
        im.tooltip('Saves the template of the selected decal spline to disk.')
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
              local preState = splineMgr.deepCopyDecalSpline(selSpline)
              splineMgr.pasteDecalSplineProfile(selSpline, jsonReadFile(data.filepath))
              editor.history:commitAction("Load Decal Spline Template", { old = preState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
            end,
            {{"JSON",".json"}},
            false,
            "/")
        end
        im.tooltip('Sets the selected decal spline to a template loaded from disk.')
      else
        im.Dummy(iconsBig)
      end
      im.NextColumn()
      im.PopStyleVar(2)
      im.Separator()
      im.Columns(1)

      -- Check if there are any splines.
      if #decalSplines == 0 then
        im.Text("No decal splines.")
        im.Text("Click the 'Add' button to add one.")
        editor.endWindow()
        return
      end

      -- If the selected spline is disabled, don't show the decal component selection panel.
      if not selSpline or not selSpline.isEnabled then
        editor.endWindow()
        return
      end

      -- Spline Properties.
      im.TextColored(cols.greenB, "Spline Properties:")
      im.PushItemWidth(-1)
      im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
      im.Columns(2, 'spacingAndJitterCols', false)
      im.SetColumnWidth(0, 30)

      -- Spacing slider.
      if selSpline.spacing ~= defaultParams.spacing then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetSpacingBtn') then
          local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
          selSpline.spacing = defaultParams.spacing
          selSpline.isDirty = true
          editor.history:commitAction("Reset Spacing", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
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
      im.tooltip('Set the longitudinal spacing between each decal component.')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Spacing", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      -- Jitter slider.
      if selSpline.jitter ~= defaultParams.jitter then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetJitterBtn') then
          local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
          selSpline.jitter = defaultParams.jitter
          selSpline.isDirty = true
          editor.history:commitAction("Reset Jitter", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      tmpPtr = im.FloatPtr(selSpline.jitter)
      if im.SliderFloat('###5757', tmpPtr, 0.0, 0.2, "Jitter = %.3f") then
        selSpline.jitter = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the amount of random jitter to apply to the decal components.')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Pitch Jitter", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()
      im.PopStyleVar()
      im.Columns(1)
      im.Dummy(im.ImVec2(0, 3))
      im.Separator()

      -- Decal Component selection panel.
      im.TextColored(cols.greenB, "Components:")
      im.Columns(5, "decalComponentSelectionColumns", true)
      im.SetColumnWidth(0, 35)
      im.SetColumnWidth(1, 40)
      im.SetColumnWidth(3, 40)
      im.Separator()

      -- Component 1 material thumbnail, selection button and name.
      im.Dummy(iconsSmall)
      im.SameLine()
      im.NextColumn()
      local mat = scenetree.findObject(selSpline.component1Material or "")
      if mat then
        local imgPath = mat:getField("diffuseMap", 0)
        local absPath = imgPath
        if absPath ~= "" then
          absPath = (string.find(absPath, "/") ~= nil and absPath or (mat:getPath() .. absPath))
        end
        local texObj = materialSelectionMgr.getTexObj(absPath)
        if texObj and texObj.texId then
          im.Image(texObj.texId, iconsSmall)
        else
          im.Dummy(iconsSmall)
        end
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.Text('Comp 1:')
      im.SameLine()
      im.NextColumn()
      if editor.uiIconImageButton(icons.youtube_searched_for, iconsSmall, cols.blueB, nil, nil, 'selectLayerMaterialBtn1') then
        materialTarget = 'Component 1'
        materialSelectionMgr.openWindow()
      end
      im.tooltip('Select a new material for Component 1.')
      im.SameLine()
      im.NextColumn()
      im.SetCursorPosY(im.GetCursorPosY() + max(0, (iconsSmall.y - im.GetTextLineHeight()) * 0.5))
      im.TextColored(cols.redB, ('[' ..selSpline.component1Material .. ']') or '[Not Set]')
      im.tooltip('The currently-selected material for Component 1.')
      im.NextColumn()
      im.Separator()

      -- Component 2 checkbox, material thumbnail, selection button and name.
      local tmpPtr = im.BoolPtr(selSpline.isComponent2)
      if im.Checkbox('###777', tmpPtr) then
        local statePre = splineMgr.deepCopyDecalSpline(selSpline)
        selSpline.isComponent2 = not selSpline.isComponent2
        selSpline.isDirty = true
        editor.history:commitAction("Toggle Component 2", { old = statePre, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        if selSpline.isComponent2 then
          selectedComponentTab = 2
        else
          selectedComponentTab = 1
        end
      end
      im.tooltip('Enable/Disable Component 2.')
      im.SameLine()
      im.NextColumn()
      mat = scenetree.findObject(selSpline.component2Material or "")
      if mat then
        local imgPath = mat:getField("diffuseMap", 0)
        local absPath = imgPath
        if absPath ~= "" then
          absPath = (string.find(absPath, "/") ~= nil and absPath or (mat:getPath() .. absPath))
        end
        local texObj = materialSelectionMgr.getTexObj(absPath)
        if texObj and texObj.texId then
          im.Image(texObj.texId, iconsSmall)
        else
          im.Dummy(iconsSmall)
        end
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.Text('Comp 2:')
      im.SameLine()
      im.NextColumn()
      if editor.uiIconImageButton(icons.youtube_searched_for, iconsSmall, cols.blueB, nil, nil, 'selectLayerMaterialBtn2') then
        materialTarget = 'Component 2'
        materialSelectionMgr.openWindow()
      end
      im.tooltip('Select a new material for Component 2.')
      im.SameLine()
      im.NextColumn()
      im.SetCursorPosY(im.GetCursorPosY() + max(0, (iconsSmall.y - im.GetTextLineHeight()) * 0.5))
      im.TextColored(cols.redB, ('[' ..selSpline.component2Material .. ']') or '[Not Set]')
      im.tooltip('The currently-selected material for Component 2.')
      im.NextColumn()
      im.Separator()

      -- Component 3 checkbox, material thumbnail, selection button and name.
      tmpPtr = im.BoolPtr(selSpline.isComponent3)
      if im.Checkbox('###7771', tmpPtr) then
        local statePre = splineMgr.deepCopyDecalSpline(selSpline)
        selSpline.isComponent3 = not selSpline.isComponent3
        selSpline.isDirty = true
        editor.history:commitAction("Toggle Component 3", { old = statePre, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        if selSpline.isComponent3 then
          selectedComponentTab = 3
        else
          selectedComponentTab = 1
        end
      end
      im.tooltip('Enable/Disable Component 3.')
      im.SameLine()
      im.NextColumn()
      mat = scenetree.findObject(selSpline.component3Material or "")
      if mat then
        local imgPath = mat:getField("diffuseMap", 0)
        local absPath = imgPath
        if absPath ~= "" then
          absPath = (string.find(absPath, "/") ~= nil and absPath or (mat:getPath() .. absPath))
        end
        local texObj = materialSelectionMgr.getTexObj(absPath)
        if texObj and texObj.texId then
          im.Image(texObj.texId, iconsSmall)
        else
          im.Dummy(iconsSmall)
        end
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.Text('Comp 3:')
      im.SameLine()
      im.NextColumn()
      if editor.uiIconImageButton(icons.youtube_searched_for, iconsSmall, cols.blueB, nil, nil, 'selectLayerMaterialBtn3') then
        materialTarget = 'Component 3'
        materialSelectionMgr.openWindow()
      end
      im.tooltip('Select a new material for Component 3.')
      im.SameLine()
      im.NextColumn()
      im.SetCursorPosY(im.GetCursorPosY() + max(0, (iconsSmall.y - im.GetTextLineHeight()) * 0.5))
      im.TextColored(cols.redB, ('[' ..selSpline.component3Material .. ']') or '[Not Set]')
      im.tooltip('The currently-selected material for Component 3.')
      im.NextColumn()
      im.Separator()

      -- Component 4 checkbox, material thumbnail, selection button and name.
      tmpPtr = im.BoolPtr(selSpline.isComponent4)
      if im.Checkbox('###7772', tmpPtr) then
        local statePre = splineMgr.deepCopyDecalSpline(selSpline)
        selSpline.isComponent4 = not selSpline.isComponent4
        selSpline.isDirty = true
        editor.history:commitAction("Toggle Component 4", { old = statePre, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        if selSpline.isComponent4 then
          selectedComponentTab = 4
        else
          selectedComponentTab = 1
        end
      end
      im.tooltip('Enable/Disable Component 4.')
      im.SameLine()
      im.NextColumn()
      mat = scenetree.findObject(selSpline.component4Material or "")
      if mat then
        local imgPath = mat:getField("diffuseMap", 0)
        local absPath = imgPath
        if absPath ~= "" then
          absPath = (string.find(absPath, "/") ~= nil and absPath or (mat:getPath() .. absPath))
        end
        local texObj = materialSelectionMgr.getTexObj(absPath)
        if texObj and texObj.texId then
          im.Image(texObj.texId, iconsSmall)
        else
          im.Dummy(iconsSmall)
        end
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.Text('Comp 4:')
      im.SameLine()
      im.NextColumn()
      if editor.uiIconImageButton(icons.youtube_searched_for, iconsSmall, cols.blueB, nil, nil, 'selectLayerMaterialBtn4') then
        materialTarget = 'Component 4'
        materialSelectionMgr.openWindow()
      end
      im.tooltip('Select a new material for Component 4.')
      im.SameLine()
      im.NextColumn()
      im.SetCursorPosY(im.GetCursorPosY() + max(0, (iconsSmall.y - im.GetTextLineHeight()) * 0.5))
      im.TextColored(cols.redB, ('[' ..selSpline.component4Material .. ']') or '[Not Set]')
      im.tooltip('The currently-selected material for Component 4.')
      im.NextColumn()
      im.Columns(1)

      -- If more than one component is being used, allow selection of mode (round robin or random).
      if selSpline.isComponent1 or selSpline.isComponent2 or selSpline.isComponent3 or selSpline.isComponent4 then
        im.Separator()
        im.TextColored(cols.greenB, "Distribution:")

        -- Distribution style: round robin or randomly distributed.
        tmpPtr = selSpline.isAliasRoundRobin and im.IntPtr(0) or im.IntPtr(1)
        im.Columns(2, "RoundRobinOrRandomCols", false)
        if im.RadioButton2("Round Robin", tmpPtr, 0) then
          local statePre = splineMgr.deepCopyDecalSpline(selSpline)
          selSpline.isAliasRoundRobin = true
          selSpline.isDirty = true
          editor.history:commitAction("Toggle Round Robin", { old = statePre, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip('Use a round robin pattern for the decal components.')
        im.SameLine()
        im.NextColumn()
        if im.RadioButton2("Random", tmpPtr, 1) then
          local statePre = splineMgr.deepCopyDecalSpline(selSpline)
          selSpline.isAliasRoundRobin = false
          selSpline.isDirty = true
          editor.history:commitAction("Toggle Random", { old = statePre, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip('Use a random pattern for the decal components.')
        im.NextColumn()
        im.Columns(1)
        im.Dummy(im.ImVec2(0, 3))

        -- Randomisation properties.
        if not selSpline.isAliasRoundRobin then
          im.PushItemWidth(-1)
          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.Columns(2, "randStyleWithResetCols", false)
          im.SetColumnWidth(0, 30)

          -- Random seed slider row.
          if selSpline.randomSeed ~= defaultParams.randomSeed then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetRandomSeedBtn') then
              selSpline.randomSeed = defaultParams.randomSeed
              selSpline.isDirty = true
            end
            im.tooltip("Reset to default")
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()
          im.NextColumn()
          im.PushItemWidth(-1)
          tmpPtr = im.IntPtr(selSpline.randomSeed)
          if im.SliderInt('###5751', tmpPtr, 0, 100000, "Random Seed = %d") then
            selSpline.randomSeed = tmpPtr[0]
            selSpline.isDirty = true
          end
          im.tooltip("Set the random seed for the decal components.")
          if im.IsItemActivated() then
            sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
          end
          if im.IsItemDeactivatedAfterEdit() then
            editor.history:commitAction("Adjust Random Seed", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
          end
          im.PopItemWidth()
          im.NextColumn()

          -- Component 1 random weight slider row.
          if selSpline.component1RandomWeight ~= defaultParams.component1RandomWeight then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetComponent1RandomWeightBtn') then
              selSpline.component1RandomWeight = defaultParams.component1RandomWeight
              selSpline.isDirty = true
            end
            im.tooltip("Reset to default")
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()
          im.NextColumn()
          im.PushItemWidth(-1)
          tmpPtr = im.FloatPtr(selSpline.component1RandomWeight)
          if im.SliderFloat('###5752', tmpPtr, 0.0, 1.0, "Component 1 Weight = %.2f") then
            selSpline.component1RandomWeight = tmpPtr[0]
            selSpline.isDirty = true
          end
          im.tooltip("Set the weight (similar to probability) of component 1.")
          if im.IsItemActivated() then
            sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
          end
          if im.IsItemDeactivatedAfterEdit() then
            editor.history:commitAction("Adjust Component 1 Weight", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
          end
          im.PopItemWidth()
          im.NextColumn()

          -- Component 2 random weight slider row.
          if selSpline.isComponent2 then
            if selSpline.component2RandomWeight ~= defaultParams.component2RandomWeight then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetComponent2RandomWeightBtn') then
                selSpline.component2RandomWeight = defaultParams.component2RandomWeight
                selSpline.isDirty = true
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            tmpPtr = im.FloatPtr(selSpline.component2RandomWeight)
            if im.SliderFloat('###5753', tmpPtr, 0.0, 1.0, "Component 2 Weight = %.2f") then
              selSpline.component2RandomWeight = tmpPtr[0]
              selSpline.isDirty = true
            end
            im.tooltip("Set the weight (similar to probability) of component 2.")
            if im.IsItemActivated() then
              sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
            end
            if im.IsItemDeactivatedAfterEdit() then
              editor.history:commitAction("Adjust Component 2 Weight", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()
          end

          -- Component 3 random weight slider row.
          if selSpline.isComponent3 then
            if selSpline.component3RandomWeight ~= defaultParams.component3RandomWeight then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetComponent3RandomWeightBtn') then
                selSpline.component3RandomWeight = defaultParams.component3RandomWeight
                selSpline.isDirty = true
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            tmpPtr = im.FloatPtr(selSpline.component3RandomWeight)
            if im.SliderFloat('###5754', tmpPtr, 0.0, 1.0, "Component 3 Weight = %.2f") then
              selSpline.component3RandomWeight = tmpPtr[0]
              selSpline.isDirty = true
            end
            im.tooltip("Set the weight (similar to probability) of component 3.")
            if im.IsItemActivated() then
              sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
            end
            if im.IsItemDeactivatedAfterEdit() then
              editor.history:commitAction("Adjust Component 3 Weight", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()
          end

          -- Component 4 random weight slider row.
          if selSpline.isComponent4 then
            if selSpline.component4RandomWeight ~= defaultParams.component4RandomWeight then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetComponent4RandomWeightBtn') then
                selSpline.component4RandomWeight = defaultParams.component4RandomWeight
                selSpline.isDirty = true
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            tmpPtr = im.FloatPtr(selSpline.component4RandomWeight)
            if im.SliderFloat('###5755', tmpPtr, 0.0, 1.0, "Component 4 Weight = %.2f") then
              selSpline.component4RandomWeight = tmpPtr[0]
              selSpline.isDirty = true
            end
            im.tooltip("Set the weight (similar to probability) of component 4.")
            if im.IsItemActivated() then
              sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
            end
            if im.IsItemDeactivatedAfterEdit() then
              editor.history:commitAction("Adjust Component 4 Weight", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()
          end
          im.PopStyleVar()
          im.PopItemWidth()
        end
      end
      im.Columns(1)
      im.Separator()

      -- Tabs for enabled components
      local enabledComponents = {}
      if selSpline.isComponent1 ~= false then table.insert(enabledComponents, 1) end
      if selSpline.isComponent2 then table.insert(enabledComponents, 2) end
      if selSpline.isComponent3 then table.insert(enabledComponents, 3) end
      if selSpline.isComponent4 then table.insert(enabledComponents, 4) end
      selectedComponentTab = min(max(1, selectedComponentTab), #enabledComponents)
      if im.BeginTabBar("decalComponentTabs") then
        for _, compIdx in ipairs(enabledComponents) do
          local tabName = "Comp "..tostring(compIdx)
          if im.BeginTabItem(tabName) then
            selectedComponentTab = compIdx
            local childName = "ComponentChild"..tostring(compIdx)
            im.PushStyleVar2(im.StyleVar_WindowPadding, im.ImVec2(4, 8))
            im.BeginChild1(childName, im.ImVec2(0, 350), true)
            if compIdx == 1 then
              -- Component 1 controls.
              im.Columns(1)
              im.TextColored(cols.greenB, "Component 1 Properties:")

              -- 'Number of Rows' slider.
              im.PushItemWidth(-1)
              im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
              im.Columns(2, "component1SlidersRow", false)
              im.SetColumnWidth(0, 30)
              if selSpline.numRows1 ~= defaultParams.numRows then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetNumRowsBtn') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.numRows1 = defaultParams.numRows
                  pop.propagateRowsCols(selSpline, 1)
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Number of Rows", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.IntPtr(selSpline.numRows1)
              if im.SliderInt("###4427", tmpPtr, 1, 4, "Num Rows = %d") then
                selSpline.numRows1 = tmpPtr[0]
                pop.propagateRowsCols(selSpline, 1)
                selSpline.isDirty = true
              end
              im.tooltip('Set the number of rows of Component 1.')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Number of Rows", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()

              -- 'Number of Columns' slider.
              if selSpline.numCols1 ~= defaultParams.numCols then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetNumColsBtn') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.numCols1 = defaultParams.numCols
                  pop.propagateRowsCols(selSpline, 1)
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Number of Columns", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.IntPtr(selSpline.numCols1)
              if im.SliderInt("###4428", tmpPtr, 1, 4, "Num Cols = %d") then
                selSpline.numCols1 = tmpPtr[0]
                pop.propagateRowsCols(selSpline, 1)
                selSpline.isDirty = true
              end
              im.tooltip('Set the number of columns of Component 1.')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Number of Columns", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()

              -- 'Decal Frame' slider.
              if selSpline.frame1 ~= defaultParams.frame then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetFrameBtn') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.frame1 = defaultParams.frame
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Decal Frame", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.IntPtr(selSpline.frame1)
              if im.SliderInt("###4429", tmpPtr, 0, selSpline.numCols1 * selSpline.numRows1 - 1, "Frame = %d") then
                local preState = splineMgr.deepCopyDecalSpline(selSpline)
                selSpline.frame1 = tmpPtr[0]
                selSpline.isDirty = true
                editor.history:commitAction("Change Decal Frame", { old = preState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.tooltip('Set the frame of Component 1 (after tiling by the number of rows and columns).')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Decal Frame", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()

              -- 'Decal Scale' slider.
              if selSpline.scale1 ~= defaultParams.scale then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetScaleBtn') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.scale1 = defaultParams.scale
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Decal Scale", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.FloatPtr(selSpline.scale1)
              if im.SliderFloat("###4430", tmpPtr, 0.1, 7.0, "Scale = %.1f") then
                selSpline.scale1 = tmpPtr[0]
                selSpline.isDirty = true
              end
              im.tooltip('Set the scale of Component 1.')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Decal Scale", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()
              im.Columns(1)

              im.Dummy(im.ImVec2(0, 3))
              im.Separator()
              im.TextColored(cols.greenB, "Pre Rotation:")
              im.Columns(4)
              tmpPtr = im.IntPtr(selSpline.rot1)
              if im.RadioButton2("0°###12000", tmpPtr, 0) then
                selSpline.rot1 = 0
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 0°.')
              im.SameLine()
              im.NextColumn()
              if im.RadioButton2("90°###12001", tmpPtr, 1) then
                selSpline.rot1 = 1
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 90°.')
              im.SameLine()
              im.NextColumn()
              if im.RadioButton2("180°###12002", tmpPtr, 2) then
                selSpline.rot1 = 2
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 180°.')
              im.SameLine()
              im.NextColumn()
              if im.RadioButton2("270°###12003", tmpPtr, 3) then
                selSpline.rot1 = 3
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 270°.')
              im.NextColumn()
              im.PopItemWidth()
              im.Columns(1)
              im.PopStyleVar() -- Pop GrabMinSize pushed for this component's sliders.
            elseif compIdx == 2 then
              -- Component 2 Controls.
              im.Columns(1)
              im.TextColored(cols.greenB, "Component 2 Properties:")

              -- 'Number of Rows' slider. [Only shown if the material is the only instance in the template.]
              im.PushItemWidth(-1)
              im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
              im.Columns(2, "component1SlidersRow", false)
              im.SetColumnWidth(0, 30)
              if selSpline.numRows2 ~= defaultParams.numRows then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetNumRowsBtn') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.numRows2 = defaultParams.numRows
                  pop.propagateRowsCols(selSpline, 2)
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Number of Rows", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.IntPtr(selSpline.numRows2)
              if im.SliderInt("###4431", tmpPtr, 1, 4, "Num Rows = %d") then
                selSpline.numRows2 = tmpPtr[0]
                pop.propagateRowsCols(selSpline, 2)
                selSpline.isDirty = true
              end
              im.tooltip('Set the number of rows of Component 2.')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Number of Rows", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()

              -- 'Number of Columns' slider. [Only shown if the layer is the only instance of its material.]
              if selSpline.numCols2 ~= defaultParams.numCols then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetNumColsBtn') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.numCols2 = defaultParams.numCols
                  pop.propagateRowsCols(selSpline, 2)
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Number of Columns", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.IntPtr(selSpline.numCols2)
              if im.SliderInt("###4432", tmpPtr, 1, 4, "Num Cols = %d") then
                selSpline.numCols2 = tmpPtr[0]
                pop.propagateRowsCols(selSpline, 2)
                selSpline.isDirty = true
              end
              im.tooltip('Set the number of columns of Component 2.')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Number of Columns", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()

              -- 'Decal Frame' slider.
              if selSpline.frame2 ~= defaultParams.frame then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetFrameBtn') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.frame2 = defaultParams.frame
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Decal Frame", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.IntPtr(selSpline.frame2)
              if im.SliderInt("###4433", tmpPtr, 0, selSpline.numCols2 * selSpline.numRows2 - 1, "Frame = %d") then
                local preState = splineMgr.deepCopyDecalSpline(selSpline)
                selSpline.frame2 = tmpPtr[0]
                selSpline.isDirty = true
                editor.history:commitAction("Change Decal Frame", { old = preState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.tooltip('Set the frame of Component 2 (after tiling by the number of rows and columns).')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Decal Frame", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()

              -- 'Decal Scale' slider.
              if selSpline.scale2 ~= defaultParams.scale then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetScaleBtn') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.scale2 = defaultParams.scale
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Decal Scale", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.FloatPtr(selSpline.scale2)
              if im.SliderFloat("###4434", tmpPtr, 0.1, 7.0, "Scale = %.1f") then
                selSpline.scale2 = tmpPtr[0]
                selSpline.isDirty = true
              end
              im.tooltip('Set the scale of Component 2.')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Decal Scale", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()
              im.Columns(1)

              im.Dummy(im.ImVec2(0, 3))
              im.Separator()
              im.TextColored(cols.greenB, "Pre Rotation:")
              im.PushItemWidth(-1)
              im.Columns(4)
              tmpPtr = im.IntPtr(selSpline.rot2)
              if im.RadioButton2("0°###12004", tmpPtr, 0) then
                selSpline.rot2 = 0
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 0°.')
              im.SameLine()
              im.NextColumn()
              if im.RadioButton2("90°###12005", tmpPtr, 1) then
                selSpline.rot2 = 1
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 90°.')
              im.SameLine()
              im.NextColumn()
              if im.RadioButton2("180°###12006", tmpPtr, 2) then
                selSpline.rot2 = 2
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 180°.')
              im.SameLine()
              im.NextColumn()
              if im.RadioButton2("270°###12007", tmpPtr, 3) then
                selSpline.rot2 = 3
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 270°.')
              im.NextColumn()
              im.PopItemWidth()
              im.Columns(1)
              im.PopStyleVar() -- Pop GrabMinSize pushed for this component's sliders.
            elseif compIdx == 3 then
              -- Component 3 Controls.
              im.Columns(1)
              im.TextColored(cols.greenB, "Component 3 Properties:")

              -- 'Number of Rows' slider. [Only shown if the material is the only instance in the template.]
              im.PushItemWidth(-1)
              im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
              im.Columns(2, "component3SlidersRow", false)
              im.SetColumnWidth(0, 30)
              if selSpline.numRows3 ~= defaultParams.numRows then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetNumRowsBtn') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.numRows3 = defaultParams.numRows
                  pop.propagateRowsCols(selSpline, 3)
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Number of Rows", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.IntPtr(selSpline.numRows3)
              if im.SliderInt("###4435", tmpPtr, 1, 4, "Num Rows = %d") then
                selSpline.numRows3 = tmpPtr[0]
                pop.propagateRowsCols(selSpline, 3)
                selSpline.isDirty = true
              end
              im.tooltip('Set the number of rows of Component 3.')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Number of Rows", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()

              -- 'Number of Columns' slider. [Only shown if the layer is the only instance of its material.]
              if selSpline.numCols3 ~= defaultParams.numCols then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetNumColsBtn') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.numCols3 = defaultParams.numCols
                  pop.propagateRowsCols(selSpline, 3)
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Number of Columns", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.IntPtr(selSpline.numCols3)
              if im.SliderInt("###4436", tmpPtr, 1, 4, "Num Cols = %d") then
                selSpline.numCols3 = tmpPtr[0]
                pop.propagateRowsCols(selSpline, 3)
                selSpline.isDirty = true
              end
              im.tooltip('Set the number of columns of Component 3.')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Number of Columns", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()

              -- 'Decal Frame' slider.
              if selSpline.frame3 ~= defaultParams.frame then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetFrameBtn3') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.frame3 = defaultParams.frame
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Decal Frame", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.IntPtr(selSpline.frame3)
              if im.SliderInt("###4437", tmpPtr, 0, selSpline.numCols3 * selSpline.numRows3 - 1, "Frame = %d") then
                local preState = splineMgr.deepCopyDecalSpline(selSpline)
                selSpline.frame3 = tmpPtr[0]
                selSpline.isDirty = true
                editor.history:commitAction("Change Decal Frame", { old = preState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.tooltip('Set the frame of Component 3 (after tiling by the number of rows and columns).')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Decal Frame", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()

              -- 'Decal Scale' slider.
              if selSpline.scale3 ~= defaultParams.scale then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetScaleBtn3') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.scale3 = defaultParams.scale
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Decal Scale", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.FloatPtr(selSpline.scale3)
              if im.SliderFloat("###4438", tmpPtr, 0.1, 7.0, "Scale = %.1f") then
                selSpline.scale3 = tmpPtr[0]
                selSpline.isDirty = true
              end
              im.tooltip('Set the scale of Component 3.')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Decal Scale", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()
              im.Columns(1)

              im.Dummy(im.ImVec2(0, 3))
              im.Separator()
              im.TextColored(cols.greenB, "Pre Rotation:")
              im.PushItemWidth(-1)
              im.Columns(4)
              tmpPtr = im.IntPtr(selSpline.rot3)
              if im.RadioButton2("0°###12008", tmpPtr, 0) then
                selSpline.rot3 = 0
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 0°.')
              im.SameLine()
              im.NextColumn()
              if im.RadioButton2("90°###12009", tmpPtr, 1) then
                selSpline.rot3 = 1
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 90°.')
              im.SameLine()
              im.NextColumn()
              if im.RadioButton2("180°###12010", tmpPtr, 2) then
                selSpline.rot3 = 2
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 180°.')
              im.SameLine()
              im.NextColumn()
              if im.RadioButton2("270°###12011", tmpPtr, 3) then
                selSpline.rot3 = 3
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 270°.')
              im.NextColumn()
              im.PopItemWidth()
              im.Columns(1)
              im.PopStyleVar() -- Pop GrabMinSize pushed for this component's sliders.
            elseif compIdx == 4 then
              -- Component 4 Controls.
              im.Columns(1)
              im.TextColored(cols.greenB, "Component 4 Properties:")

              -- 'Number of Rows' slider. [Only shown if the material is the only instance in the template.]
              im.PushItemWidth(-1)
              im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
              im.Columns(2, "component4SlidersRow", false)
              im.SetColumnWidth(0, 30)
              if selSpline.numRows4 ~= defaultParams.numRows then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetNumRowsBtn') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.numRows4 = defaultParams.numRows
                  pop.propagateRowsCols(selSpline, 4)
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Number of Rows", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.IntPtr(selSpline.numRows4)
              if im.SliderInt("###4439", tmpPtr, 1, 4, "Num Rows = %d") then
                selSpline.numRows4 = tmpPtr[0]
                pop.propagateRowsCols(selSpline, 4)
                selSpline.isDirty = true
              end
              im.tooltip('Set the number of rows of Component 4.')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Number of Rows", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()

              -- 'Number of Columns' slider. [Only shown if the layer is the only instance of its material.]
              if selSpline.numCols4 ~= defaultParams.numCols then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetNumColsBtn') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.numCols4 = defaultParams.numCols
                  pop.propagateRowsCols(selSpline, 4)
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Number of Columns", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.IntPtr(selSpline.numCols4)
              if im.SliderInt("###4440", tmpPtr, 1, 4, "Num Cols = %d") then
                selSpline.numCols4 = tmpPtr[0]
                pop.propagateRowsCols(selSpline, 4)
                selSpline.isDirty = true
              end
              im.tooltip('Set the number of columns of Component 4.')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Number of Columns", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()

              -- 'Decal Frame' slider.
              if selSpline.frame4 ~= defaultParams.frame then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetFrameBtn4') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.frame4 = defaultParams.frame
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Decal Frame", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.IntPtr(selSpline.frame4)
              if im.SliderInt("###4441", tmpPtr, 0, selSpline.numCols4 * selSpline.numRows4 - 1, "Frame = %d") then
                local preState = splineMgr.deepCopyDecalSpline(selSpline)
                selSpline.frame4 = tmpPtr[0]
                selSpline.isDirty = true
                editor.history:commitAction("Change Decal Frame", { old = preState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.tooltip('Set the frame of Component 4 (after tiling by the number of rows and columns).')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Decal Frame", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()

              -- 'Decal Scale' slider.
              if selSpline.scale4 ~= defaultParams.scale then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetScaleBtn4') then
                  local preEditState = splineMgr.deepCopyDecalSpline(selSpline)
                  selSpline.scale4 = defaultParams.scale
                  selSpline.isDirty = true
                  editor.history:commitAction("Reset Decal Scale", { old = preEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.FloatPtr(selSpline.scale4)
              if im.SliderFloat("###4442", tmpPtr, 0.1, 7.0, "Scale = %.1f") then
                selSpline.scale4 = tmpPtr[0]
                selSpline.isDirty = true
              end
              im.tooltip('Set the scale of Component 4.')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyDecalSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Decal Scale", { old = sliderPreEditState, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.PopItemWidth()
              im.NextColumn()
              im.Columns(1)

              im.Dummy(im.ImVec2(0, 3))
              im.Separator()
              im.TextColored(cols.greenB, "Pre Rotation:")
              im.PushItemWidth(-1)
              im.Columns(4)
              tmpPtr = im.IntPtr(selSpline.rot4)
              if im.RadioButton2("0°###12012", tmpPtr, 0) then
                selSpline.rot4 = 0
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 0°.')
              im.SameLine()
              im.NextColumn()
              if im.RadioButton2("90°###12013", tmpPtr, 1) then
                selSpline.rot4 = 1
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 90°.')
              im.SameLine()
              im.NextColumn()
              if im.RadioButton2("180°###12014", tmpPtr, 2) then
                selSpline.rot4 = 2
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 180°.')
              im.SameLine()
              im.NextColumn()
              if im.RadioButton2("270°###12015", tmpPtr, 3) then
                selSpline.rot4 = 3
                selSpline.isDirty = true
              end
              im.tooltip('Set the rotation to 270°.')
              im.NextColumn()
              im.PopItemWidth()
              im.Columns(1)
              im.PopStyleVar() -- Pop GrabMinSize pushed for this component's sliders.
            end
            im.Dummy(im.ImVec2(0, 3))
            im.Separator()
            im.PopStyleVar() -- Pop WindowPadding pushed for the component child.
            im.EndChild()
            im.EndTabItem()
          end
        end
        im.EndTabBar()
      end
    end
  end
  editor.endWindow()
end

-- Handles the material selection sub window.
local function onSelectMaterial(objId)
  local splines = splineMgr.getDecalSplines()
  local selSpline = splines[selectedSplineIdx]
  if selSpline then
    local statePre = splineMgr.deepCopyDecalSpline(selSpline)
    pop.tryRemove(selSpline)
    if materialTarget == 'Component 1' then
      selSpline.component1Material = objId
    elseif materialTarget == 'Component 2' then
      selSpline.component2Material = objId
    elseif materialTarget == 'Component 3' then
      selSpline.component3Material = objId
    elseif materialTarget == 'Component 4' then
      selSpline.component4Material = objId
    end
    selSpline.isDirty = true
    editor.history:commitAction("Select Layer Material", { old = statePre, new = splineMgr.deepCopyDecalSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
  end
end

-- World editor main callback.
local function onEditorGui()
  -- Ensure all decal splines are updated, even if this tool is not active.
  -- [This ensures any linked decal splines are also updated.]
  splineMgr.updateDirtyDecalSplines()

  -- If this tool is not active, render the shells of the splines but do nothing further.
  if not isDecalSplineActive then
    render.renderShells(splineMgr.getDecalSplines())
    return
  end

  -- Handle the main tool window UI.
  handleMainToolWindowUI()

  -- Handle the material selection UI.
  local splines = splineMgr.getDecalSplines()
  if #splines > 0 and splines[selectedSplineIdx] then
    materialSelectionMgr.handleMaterialSelectionSubWindow(true, onSelectMaterial)
  else
    materialSelectionMgr.closeWindow() -- Close the material selection window if there is no selected decal spline.
  end

  -- Handle the mouse and keyboard events.
  out.spline, out.node, out.isGizmoActive, out.isLockShape = selectedSplineIdx, selectedNodeIdx, isGizmoActive, isLockShape
  input.handleSplineEvents(
    splines,
    out,
    false, true, false, false, false, true, true, isLockShape,
    defaultSplineWidth,
    splineMgr.deepCopyDecalSpline, splineMgr.deepCopyDecalSplineState,
    splineMgr.copyDecalSplineProfile, splineMgr.pasteDecalSplineProfile,
    nil,
    splineMgr.joinDecalSplines,
    splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo,
    splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo)
  selectedSplineIdx, selectedNodeIdx, isGizmoActive, isLockShape = out.spline, out.node, out.isGizmoActive, out.isLockShape

  -- Render the decal splines (only if not linked to master spline).
  local selSpline = splines[out.spline]
  if selSpline then
    render.handleSplineRendering(splines, out.spline, out.node, isGizmoActive, false, isLockShape, false, false, elevScale)
    render.renderSplinePolylines(splines, out.spline)
  end
end

-- Called when the tool mode icon is pressed.
local function onActivate()
  editor.clearObjectSelection()
  editor.showWindow(toolWinName)
  isDecalSplineActive = true
end

-- Called when the tool is exited.
local function onDeactivate()
  editor.hideWindow(toolWinName)
  isDecalSplineActive = false
end

-- Called upon world editor initialisation.
local function onEditorInitialized()
  editor.editModes.decalSplineEditMode = {
    displayName = "Decal Spline",
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    icon = editor.icons.decalRoad,
    iconTooltip = "DecalSpline",
    auxShortcuts = {},
    hideObjectIcons = true }
  editor.registerWindow(toolWinName, toolWinSize)
end

-- Called when leaving the map. We need to remove all decal splines.
local function onClientEndMission()
  splineMgr.removeAllDecalSplines(true)
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
