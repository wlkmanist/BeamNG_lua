-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local simplifyRdpTol = 9.0 -- The tolerance for the RDP simplification of the spline.

local defaultSplineWidth = 5.0 -- The default width for a spline when adding a new node, in meters.
local elevScale = 100.0 -- The scale factor for the elevation drop lines (used for blue->red colour transition).

local minVerticalOffset, maxVerticalOffset = -10.0, 10.0
local minJitterAmount, maxJitterAmount = 0.0, 0.1
local minAlignmentWeight, maxAlignmentWeight = 0.1, 50.0
local DOImin, DOImax = 0.0, 500.0
local terraMarginMin, terraMarginMax = 1.0, 20.0
local terraFalloffMin, terraFalloffMax = 1.0, 5.0

local maxRandomSeed = 10000

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

local splineMgr = require('editor/sidewalkSpline/splineMgr')
local kit = require('editor/sidewalkSpline/kit')
local pop = require('editor/sidewalkSpline/populate')
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
local toolWinName, toolWinSize = 'sidewalkSpline', im.ImVec2(300, 700)
local defaultParams = splineMgr.getDefaultSliderParams()
local cols = style.getImguiCols('crystal')
local iconsSmall, iconsBig = im.ImVec2(24, 24), im.ImVec2(36, 36)

-- Module state.
local isSidewalkSplineActive = false
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
  splineMgr.getSidewalkSplines,
  splineMgr.getEditModeKey,
  splineMgr.deepCopySidewalkSpline,
  splineMgr.deepCopySidewalkSplineState,
  'editor_sidewalkSpline'
)


-- Sets the selected spline index (for cross-tool selection).
local function setSelectedSplineIdx(idx)selectedSplineIdx = idx end

-- Sets the selected node index (for cross-tool selection).
local function setSelectedNodeIdx(idx) selectedNodeIdx = idx end

-- Serialise callback.
local function onSerialize()
  local sidewalkSplines = splineMgr.getSidewalkSplines()
  local numSplines = #sidewalkSplines
  local sidewalkSplinesSer = {}
  for i = 1, numSplines do
    sidewalkSplinesSer[i] = splineMgr.serializeSidewalkSpline(sidewalkSplines[i])
  end
  splineMgr.removeAllSidewalkSplines()
  return sidewalkSplinesSer
end

-- Deserialise callback.
local function onDeserialized(data)
  if data and #data > 0 then
    local sidewalkSplines = splineMgr.getSidewalkSplines()
    table.clear(sidewalkSplines)
    for i = 1, #data do
      local spline = splineMgr.deserializeSidewalkSpline(data[i], true)
      sidewalkSplines[#sidewalkSplines + 1] = spline
    end
    selectedSplineIdx = max(1, min(#sidewalkSplines, selectedSplineIdx))

    -- Update the spline map.
    util.computeIdToIdxMap(sidewalkSplines, splineMgr.getSplineMap())

    -- Update the mesh kit and sidewalk kit structures for each spline.
    for i = 1, #sidewalkSplines do
      local spline = sidewalkSplines[i]
      -- Only regenerate if we don't already have the data (e.g., for new splines)
      if not spline.meshKit or #spline.meshKit == 0 then
        if spline.isImported and spline.importedKit and spline.importedKit.reconstructedKit then
          -- For imported splines, use the stored reconstructed kit.
          spline.meshKit = spline.importedKit.reconstructedKit
          spline.kitDescription = kit.buildSidewalkKit(spline.meshKit, spline)
        else
          -- For folder-based splines, load from disk.
          spline.meshKit = kit.getSidewalkKit(spline.kitFolderPath)
          spline.kitDescription = kit.buildSidewalkKit(spline.meshKit, spline)
        end
      end
    end
  end
end

-- Handles the main tool window.
local function handleMainToolWindowUI()
  if editor.beginWindow(toolWinName, "Sidewalk Spline###21345", im.WindowFlags_NoCollapse) then
    local icons = editor.icons
    local sidewalkSplines = splineMgr.getSidewalkSplines()
    selectedSplineIdx = max(1, min(#sidewalkSplines, selectedSplineIdx)) -- Ensure the selected spline index is within bounds.

    -- Top buttons row.
    im.Columns(7, "topMasterButtonsRow", false)
    im.SetColumnWidth(0, 39)
    im.SetColumnWidth(1, 39)
    im.SetColumnWidth(2, 39)
    im.SetColumnWidth(3, 39)
    im.SetColumnWidth(4, 39)
    im.SetColumnWidth(5, 39)
    im.SetColumnWidth(6, 39)
    im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
    im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

    -- 'Add New sidewalk spline' button.
    if editor.uiIconImageButton(icons.bSpline, iconsBig, cols.blueB, nil, nil, 'addNewSidewalkSplineBtn') then
      local statePre = splineMgr.deepCopySidewalkSplineState()
      splineMgr.addNewSidewalkSpline()
      selectedSplineIdx = #sidewalkSplines + 1
      editor.history:commitAction("Add New sidewalk spline", { old = statePre, new = splineMgr.deepCopySidewalkSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
    end
    im.tooltip('Add a new sidewalk spline.')
    im.SameLine()
    im.NextColumn()

    -- 'Draw A Selection Polygon' button.
    local btnCol = isDrawPolygon and cols.blueB or cols.blueD
    if editor.uiIconImageButton(icons.rounded_corner, iconsBig, btnCol, nil, nil, 'drawPolygonBtn') then
      isDrawPolygon = not isDrawPolygon
      poly.clearPolygon() -- Ensure there is no residual polygon left over from the previous usage.
    end
    im.tooltip(isDrawPolygon and 'Click to stop drawing a selection polygon.' or 'Click to draw a selection polygon, to convert scene objects to a Sidewalk Spline.')
    im.SameLine()
    im.NextColumn()

    -- 'Remove All Sidewalk Splines' button.
    if #sidewalkSplines > 0 then
      if editor.uiIconImageButton(icons.trashBin2, iconsBig, cols.blueB, nil, nil, 'removeAllSidewalkSplinesBtn') then
        local statePre = splineMgr.deepCopySidewalkSplineState()
        splineMgr.removeAllSidewalkSplines(false)
        selectedSplineIdx = 1
        editor.history:commitAction("Remove All sidewalk splines", { old = statePre, new = splineMgr.deepCopySidewalkSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
      end
      im.tooltip('Remove all (enabled and not linked) sidewalk splines from the session.')
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Lock Shape' toggle button.
    local selSpline = sidewalkSplines[selectedSplineIdx]
    if #sidewalkSplines > 0 and selSpline and selSpline.isEnabled and not selSpline.isLink then
      btnCol = isLockShape and cols.blueB or cols.blueD
      if editor.uiIconImageButton(icons.roadGuideArrowSolid, iconsBig, btnCol, nil, nil, 'lockShapeBtn') then
        isLockShape = not isLockShape
      end
      im.tooltip((isLockShape and 'Unlock the shape of the sidewalk spline to move nodes separately' or 'Lock the shape of the sidewalk spline to move nodes rigidly'))
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- Save spline template button.
    if selSpline and selSpline.isEnabled then
      if editor.uiIconImageButton(icons.floppyDisk, iconsBig, cols.blueB, nil, nil, 'saveTemplateBtn') then
        extensions.editor_fileDialog.saveFile(
          function(data)
            jsonWriteFile(data.filepath, splineMgr.copySidewalkSplineProfile(selSpline), true)
          end,
          {{"JSON",".json"}},
          false,
          "/")
      end
      im.tooltip('Save the sidewalk spline template to disk.')
    else
      im.Dummy(iconsBig)
    end
    im.NextColumn()

    -- Export spline mask button.
    if #sidewalkSplines > 0 then
      if editor.uiIconImageButton(icons.folder, iconsBig, cols.blueB, nil, nil, 'exportSplineMaskBtn') then
        local sources = util.getAllSources(sidewalkSplines)
        extensions.editor_fileDialog.saveFile(
          function(data)
            maskExport.export(data.filepath, sources, 1.0) -- TODO: Uses a 1m margin. Maybe make this a parameter later.
          end,
          {{"PNG",".png"}},
          false,
          "/",
          "File already exists.\nDo you want to overwrite the file?")
      end
      im.tooltip('Export the session as a .PNG mask file. Will not include any disabled Sidewalk Splines.')
    else
      im.Dummy(iconsBig)
    end
    im.NextColumn()

    im.PopStyleVar(2)
    im.Columns(1)
    im.Separator()

    -- Sidewalk splines list.
    if #sidewalkSplines > 0 then
      im.TextColored(cols.greenB, "Sidewalk Splines:")
      im.PushItemWidth(-1)
      if im.BeginListBox('', im.ImVec2(-1, 180)) then
        im.Columns(4, "splineListBoxColumns", true)
        im.SetColumnWidth(0, 30)
        im.SetColumnWidth(1, 180)
        im.SetColumnWidth(2, 35)
        im.SetColumnWidth(3, 35)
        im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(4, 2))
        im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
        local wCtr = 88428
        for i = 1, #sidewalkSplines do
          local spline = sidewalkSplines[i]
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
            im.tooltip('This sidewalk spline is linked to a Master Spline. To edit or remove it, first unlink it from within the Master Spline Editor.')
          elseif not spline.isEnabled then
            im.TextColored(cols.dullWhite, spline.name)
            im.tooltip('This sidewalk spline is disabled. To edit or remove it, first enable it.')
          else
            if im.InputText("###" .. tostring(wCtr), splineNamePtr, 32) then
              spline.name = ffi.string(splineNamePtr)
              if spline.sceneTreeFolderId then
                local folder = scenetree.findObjectById(spline.sceneTreeFolderId)
                if folder then
                  local preState = splineMgr.deepCopySidewalkSpline(spline)
                  folder:setName(spline.name)
                  editor.refreshSceneTreeWindow()
                  spline.isDirty = true
                  local postState = splineMgr.deepCopySidewalkSpline(spline)
                  preState.isUpdateSceneTree = true
                  postState.isUpdateSceneTree = true
                  editor.history:commitAction("Edit Sidewalk Spline Name", { old = preState, new = postState }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
              end
            end
            im.tooltip('Edit the sidewalk spline name.')
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
            if editor.uiIconImageButton(icons.trashBin2, iconsSmall, cols.blueB, nil, nil, 'removeSpline') then
              local statePre = splineMgr.deepCopySidewalkSplineState()
              splineMgr.removeSidewalkSpline(i)
              if selectedSplineIdx > i then
                selectedSplineIdx = selectedSplineIdx - 1
              end
              selectedSplineIdx = max(1, min(#sidewalkSplines, selectedSplineIdx))
              editor.history:commitAction("Remove Sidewalk Spline", { old = statePre, new = splineMgr.deepCopySidewalkSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
              editor.endWindow()
              return
            end
            im.tooltip('Remove this sidewalk spline from the session.')
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()
          im.NextColumn()

          -- 'Enable/Disable' button.
          if not spline.isLink then
            btnCol = spline.isEnabled and cols.blueB or cols.blueD
            local btnIcon = spline.isEnabled and icons.lock or icons.lock_open
            if editor.uiIconImageButton(btnIcon, iconsSmall, btnCol, nil, nil, 'lockUnlockSidewalkSplineToggleBtn') then
              local statePre = splineMgr.deepCopySidewalkSpline(spline)
              spline.isEnabled = not spline.isEnabled
              pop.tryRemove(spline)
              spline.isDirty = true
              selectedSplineIdx = i
              editor.history:commitAction("Toggle Sidewalk Spline Lock", { old = statePre, new = splineMgr.deepCopySidewalkSpline(spline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
            end
            im.tooltip((spline.isEnabled and 'Disable' or 'Enable') .. ' this sidewalk spline.')
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

      -- Buttons underneath the sidewalk splines list box.
      im.Columns(6, "buttonsUnderneathListBox", false)
      im.SetColumnWidth(0, 40)
      im.SetColumnWidth(1, 40)
      im.SetColumnWidth(2, 40)
      im.SetColumnWidth(3, 40)
      im.SetColumnWidth(4, 40)
      im.SetColumnWidth(5, 40)
      im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
      im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

      -- 'Go To Selected Spline' button.
      if selSpline and selSpline.nodes and #selSpline.nodes > 1 then
        if editor.uiIconImageButton(icons.cameraFocusTopDown, iconsBig, cols.blueB, nil, nil, 'goToSelectedSplineBtn') then
          util.goToSpline(selSpline.divPoints)
        end
        im.tooltip('Go to this sidewalk spline (move camera).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Split sidewalk spline' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink and selSpline.nodes and selSpline.nodes[selectedNodeIdx] and #selSpline.nodes > 2 and (selSpline.isLoop or (selectedNodeIdx > 1 and selectedNodeIdx < #selSpline.nodes)) then
        if editor.uiIconImageButton(icons.content_cut, iconsBig, cols.blueB, nil, nil, 'splitSidewalkSplineBtn') then
          local statePre = splineMgr.deepCopySidewalkSplineState()
          splineMgr.splitSidewalkSpline(selectedSplineIdx, selectedNodeIdx)
          selectedSplineIdx = #sidewalkSplines
          editor.history:commitAction("Split New sidewalk spline", { old = statePre, new = splineMgr.deepCopySidewalkSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
        end
        im.tooltip('Splits the selected sidewalk spline into two, at the selected node.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Flip Direction' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink and #selSpline.nodes > 1 then
        if editor.uiIconImageButton(icons.cached, iconsBig, cols.blueB, nil, nil, 'flipDirectionBtn') then
          local statePre = splineMgr.deepCopySidewalkSpline(selSpline)
          geom.flipSplineDirection(selSpline)
          selSpline.isDirty = true
          editor.history:commitAction("Flip Sidewalk Spline Direction", { old = statePre, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip('Flips the direction of the selected sidewalk spline (back to front).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Simplify Spline' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink and selSpline.nodes and selSpline.nodes[selectedNodeIdx] and #selSpline.nodes > 2 then
        if editor.uiIconImageButton(icons.routeSimple, iconsBig, cols.blueB, nil, nil, 'simplifySplineBtn') then
          local statePre = splineMgr.deepCopySidewalkSpline(selSpline)
          rdp.simplifyNodes(selSpline.nodes, simplifyRdpTol)
          selectedNodeIdx = max(1, min(#selSpline.nodes, selectedNodeIdx))
          selSpline.isDirty = true
          editor.history:commitAction("Simplify Sidewalk Spline", { old = statePre, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip('Simplifies the selected sidewalk spline (reduces the number of nodes).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- Save template button.
      if selSpline and selSpline.isEnabled then
        if editor.uiIconImageButton(icons.floppyDisk, iconsBig, nil, nil, nil, 'saveTemplateBtn') then
          extensions.editor_fileDialog.saveFile(
            function(data)
              jsonWriteFile(data.filepath, splineMgr.copySidewalkSplineProfile(selSpline), true)
            end,
            {{"JSON",".json"}},
            false,
            "/",
            "File already exists.\nDo you want to overwrite the file?")
        end
        im.tooltip('Saves the template of the selected sidewalk spline to disk.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- Load template button.
      if selSpline and selSpline.isEnabled then
        if editor.uiIconImageButton(icons.roadFolder, iconsBig, cols.dullWhite, nil, nil, 'loadTemplateBtn') then
          extensions.editor_fileDialog.openFile(
            function(data)
              local preState = splineMgr.deepCopySidewalkSpline(selSpline)
              splineMgr.pasteSidewalkSplineProfile(selSpline, jsonReadFile(data.filepath))
              selSpline.isDirty = true
              editor.history:commitAction("Load Sidewalk Spline Template", { old = preState, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.objectSelectUndo, splineMgr.objectSelectRedo, true)
            end,
            {{"JSON",".json"}},
            false,
            "/")
        end
        im.tooltip('Sets the selected sidewalk spline to a template loaded from disk.')
      else
        im.Dummy(iconsBig)
      end
      im.NextColumn()

      im.PopStyleVar(2)
      im.Columns(1)
      im.Separator()

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

      -- Vertical Offset slider.
      if selSpline.verticalOffset ~= defaultParams.verticalOffset then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetVerticalOffsetBtn') then
          local preEditState = splineMgr.deepCopySidewalkSpline(selSpline)
          selSpline.verticalOffset = defaultParams.verticalOffset
          selSpline.isDirty = true
          editor.history:commitAction("Reset Vertical Offset", { old = preEditState, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      local tmpPtr = im.FloatPtr(selSpline.verticalOffset)
      if im.SliderFloat('###4456', tmpPtr, minVerticalOffset, maxVerticalOffset, "Vertical Offset (m) = %.2f") then
        selSpline.verticalOffset = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the vertical offset of the sidewalk pieces.')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopySidewalkSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Vertical Offset", { old = sliderPreEditState, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      -- Jitter slider.
      if selSpline.jitterAmount ~= defaultParams.jitterAmount then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetJitterAmountBtn') then
          local preEditState = splineMgr.deepCopySidewalkSpline(selSpline)
          selSpline.jitterAmount = defaultParams.jitterAmount
          selSpline.isDirty = true
          editor.history:commitAction("Reset Jitter", { old = preEditState, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      tmpPtr = im.FloatPtr(selSpline.jitterAmount)
      if im.SliderFloat('###3346', tmpPtr, minJitterAmount, maxJitterAmount, "Jitter = %.3f") then
        selSpline.jitterAmount = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the amount of random rotation jitter applied to pieces.')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopySidewalkSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Jitter", { old = sliderPreEditState, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      -- Alignment Weight slider.
      if selSpline.alignmentWeight ~= defaultParams.alignmentWeight then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetAlignmentWeightBtn') then
          local preEditState = splineMgr.deepCopySidewalkSpline(selSpline)
          selSpline.alignmentWeight = defaultParams.alignmentWeight
          selSpline.isDirty = true
          editor.history:commitAction("Reset Alignment Priority", { old = preEditState, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      local tmpPtr = im.FloatPtr(selSpline.alignmentWeight)
      if im.SliderFloat('###5757', tmpPtr, minAlignmentWeight, maxAlignmentWeight, "Alignment Priority = %.1f") then
        selSpline.alignmentWeight = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set how much to prioritize piece orientation vs distance. Higher values prefer better alignment over exact positioning.')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopySidewalkSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Alignment Priority", { old = sliderPreEditState, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      -- Random Seed slider.
      if selSpline.splineRandomSeed ~= defaultParams.splineRandomSeed then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetRandomSeedBtn') then
          local preEditState = splineMgr.deepCopySidewalkSpline(selSpline)
          selSpline.splineRandomSeed = defaultParams.splineRandomSeed
          selSpline.isDirty = true
          editor.history:commitAction("Reset Random Seed", { old = preEditState, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      local tmpIntPtr = im.IntPtr(selSpline.splineRandomSeed)
      if im.SliderInt('###2236', tmpIntPtr, 0, maxRandomSeed, "Random Seed = %d") then
        selSpline.splineRandomSeed = tmpIntPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the random seed for piece placement and variation selection.')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopySidewalkSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Random Seed", { old = sliderPreEditState, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      im.PopStyleVar()
      im.PopItemWidth()
      im.Columns(1)
      im.Separator()

      -- Tab bar.
      local selectedTab = 0 -- Default to first tab.
      if im.BeginTabBar("SidewalkSplineTabs") then
        if im.BeginTabItem("Sidewalk Kit") then
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
        if selectedTab == 0 then -- Sidewalk Kit tab.
          -- Kit Selection.
          im.Columns(2, "sidewalkKitSelectionColumns", false)
          im.SetColumnWidth(0, 40)
          if editor.uiIconImageButton(icons.folder, iconsSmall, cols.blueB, nil, nil, 'selectSidewalkKitBtn') then
            extensions.editor_fileDialog.openFile(
              function(data)
                if data.path then
                  local preState = splineMgr.deepCopySidewalkSpline(selSpline)
                  pop.tryRemove(selSpline)
                  selSpline.kitFolderPath = data.path
                  selSpline.meshKit = kit.getSidewalkKit(data.path)
                  selSpline.kitDescription = kit.buildSidewalkKit(selSpline.meshKit, selSpline)
                  selSpline.distributionGroups = kit.buildDistributionGroups(selSpline)
                  if selSpline.kitDescription then
                    selSpline.kitDescription.distributionGroups = selSpline.distributionGroups
                  end
                  local rectMeshPath, pizzaMeshPath = kit.getRectAndPizzaMeshPaths(selSpline.meshKit)
                  selSpline.rectMeshPath = rectMeshPath
                  selSpline.pizzaMeshPath = pizzaMeshPath
                  selSpline.isDirty = true
                  editor.history:commitAction("Select Sidewalk Kit", { old = preState, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.objectSelectUndo, splineMgr.objectSelectRedo, true)
                end
              end,
              {{"All Folders","*"}},
              true,
              "/")
          end
          im.tooltip('Select the Sidewalk Kit folder.')
          im.SameLine()
          im.NextColumn()
          im.SetCursorPosY(im.GetCursorPosY() + max(0, (iconsSmall.y - im.GetTextLineHeight()) * 0.5))
          if selSpline.kitFolderPath then
            im.Text('[' .. selSpline.kitFolderPath .. ']')
          else
            im.Text('[No sidewalk kit selected]')
          end
          im.tooltip('The currently-selected Sidewalk Kit folder.')
          im.NextColumn()
          im.Dummy(im.ImVec2(0, 3))

          -- Kit components (available for both imported and non-imported kits).
          im.Columns(1)
          im.Separator()
          local kitDescription = selSpline.kitDescription
          if kitDescription and kitDescription.pieces and #kitDescription.pieces > 0 then
            im.TextColored(cols.greenB, "Kit Components:")
            im.Columns(4, "kitCompCols", true)
            im.SetColumnWidth(0, 35)
            im.SetColumnWidth(1, 120)
            im.SetColumnWidth(2, 50)
            im.SetColumnWidth(3, 100)

            -- Component column headers.
            im.Text("Use")
            im.SameLine()
            im.NextColumn()
            im.Text("Mesh")
            im.SameLine()
            im.NextColumn()
            im.Text("Role")
            im.SameLine()
            im.NextColumn()
            im.Text("Variation")
            im.NextColumn()
            im.Separator()

            -- Component rows (iterate base pieces; enabled state comes from pieceEnabledStates).
            local pieces = kitDescription.pieces
            for i = 1, #pieces do
              local piece = pieces[i]
              local pieceIndex = piece.pieceIndex
              local preState = nil

              -- Enable/disable checkbox for base mesh.
              local isEnabled = kit.getPieceEnabled(selSpline, pieceIndex)
              tmpPtr = im.BoolPtr(isEnabled)
              if im.Checkbox("###piece_" .. tostring(pieceIndex), tmpPtr) then
                preState = splineMgr.deepCopySidewalkSpline(selSpline)
                kit.setPieceEnabled(selSpline, pieceIndex, tmpPtr[0])
                selSpline.kitDescription = kit.buildSidewalkKit(selSpline.meshKit, selSpline)
                selSpline.distributionGroups = kit.buildDistributionGroups(selSpline)
                if selSpline.kitDescription then
                  selSpline.kitDescription.distributionGroups = selSpline.distributionGroups
                end
                selSpline.isDirty = true
                editor.history:commitAction("Toggle Piece", { old = preState, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
              end
              im.tooltip(isEnabled and 'Do not include this component in the sidewalk.' or 'Include this component in the sidewalk.')
              im.SameLine()
              im.NextColumn()

              -- Base mesh name.
              local baseMeshName = piece.baseMesh and (piece.baseMesh.fileName or "Unknown") or "Unknown"
              im.TextColored(cols.purpleB, baseMeshName)
              im.tooltip(piece.baseMesh and piece.baseMesh.meshPath or "Unknown mesh path")
              im.SameLine()
              im.NextColumn()

              -- Role.
              im.TextColored(cols.redB, "[base]")
              im.tooltip("The base mesh of this component.")
              im.SameLine()
              im.NextColumn()

              -- Base variation marker.
              im.Text("")
              im.NextColumn()
              im.Separator()

              -- Show variations for this base mesh.
              if piece.variations then
                for j, variation in ipairs(piece.variations) do
                  -- Enable/disable checkbox for variation.
                  local varEnabled = kit.getPieceEnabled(selSpline, variation.varId)
                  local varTmpPtr = im.BoolPtr(varEnabled)
                  if im.Checkbox("###pieceVar_" .. tostring(pieceIndex) .. "_" .. tostring(j), varTmpPtr) then
                    preState = splineMgr.deepCopySidewalkSpline(selSpline)
                    kit.setPieceEnabled(selSpline, variation.varId, varTmpPtr[0])
                    selSpline.kitDescription = kit.buildSidewalkKit(selSpline.meshKit, selSpline)
                    selSpline.distributionGroups = kit.buildDistributionGroups(selSpline)
                    if selSpline.kitDescription then
                      selSpline.kitDescription.distributionGroups = selSpline.distributionGroups
                    end
                    selSpline.isDirty = true
                    editor.history:commitAction("Toggle Piece Variation", { old = preState, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                  end
                  im.tooltip(varEnabled and 'Do not include this variation in the sidewalk.' or 'Include this variation in the sidewalk.')
                  im.SameLine()
                  im.NextColumn()

                  -- Variation mesh name.
                  local varMeshName = variation.fileName or "Unknown"
                  im.TextColored(cols.dullWhite, " * " .. varMeshName)
                  im.tooltip(variation.meshPath or "Unknown mesh path")
                  im.SameLine()
                  im.NextColumn()

                  -- Role (empty for variations).
                  im.Text("")
                  im.SameLine()
                  im.NextColumn()

                  -- Variation number.
                  im.TextColored(cols.dullWhite, "var" .. tostring(j))
                  im.tooltip("This is variation " .. tostring(j) .. " of the base component.")
                  im.NextColumn()
                  im.Separator()
                end
              end
            end
            im.Columns(1)
          else
            im.TextColored(cols.redB, 'No sidewalk kit selected.')
            im.Text('Select a folder containing sidewalk meshes to continue.')
          end

        elseif selectedTab == 1 then -- Distribution tab.
          local isDistContent = false
          local kitDescription = selSpline.kitDescription
          if kitDescription and kitDescription.pieces and #kitDescription.pieces > 0 then
            local pieces = kitDescription.pieces
            for i = 1, #pieces do
              local piece = pieces[i]
              local pieceIndex = piece.pieceIndex

              -- Check if there are at least 2 enabled meshes in this component set (base + variations).
              local enabledCount = 0
              if kit.getPieceEnabled(selSpline, pieceIndex) then
                enabledCount = enabledCount + 1
              end
              if piece.variations then
                for j, variation in ipairs(piece.variations) do
                  if kit.getPieceEnabled(selSpline, variation.varId) then
                    enabledCount = enabledCount + 1
                  end
                end
              end

              if enabledCount >= 2 then
                local baseMeshName = piece.baseMesh and (piece.baseMesh.fileName or "Unknown") or "Unknown"
                im.TextColored(cols.greenB, baseMeshName:gsub("%.dae$", ""))
                im.SameLine()
                im.TextColored(cols.greenB, ":")

                -- Distribution radio buttons.
                selSpline.pieceDistribution = selSpline.pieceDistribution or {}
                selSpline.pieceDistribution[pieceIndex] = selSpline.pieceDistribution[pieceIndex] or {}
                local pieceDistData = selSpline.pieceDistribution[pieceIndex]
                if pieceDistData.isRandom == nil then
                  pieceDistData.isRandom = false
                end
                tmpPtr = im.IntPtr(pieceDistData.isRandom and 1 or 0)
                im.Columns(2, "DistributionCols" .. pieceIndex, false)
                if im.RadioButton2("Round Robin###dist" .. tostring(pieceIndex) .. "_0", tmpPtr, 0) then
                  local statePre = splineMgr.deepCopySidewalkSpline(selSpline)
                  pieceDistData.isRandom = false
                  tmpPtr[0] = 0
                  selSpline.isDirty = true
                  editor.history:commitAction("Set Round Robin", { old = statePre, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip('Use round robin pattern for this component set.')
                im.SameLine()
                im.NextColumn()
                if im.RadioButton2("Random###dist" .. tostring(pieceIndex) .. "_1", tmpPtr, 1) then
                  local statePre = splineMgr.deepCopySidewalkSpline(selSpline)
                  pieceDistData.isRandom = true
                  tmpPtr[0] = 1
                  selSpline.isDirty = true
                  editor.history:commitAction("Set Random", { old = statePre, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                end
                im.tooltip('Use random pattern for this component set.')
                im.NextColumn()
                im.Columns(1)

                -- Weight sliders (only if random is selected).
                if pieceDistData.isRandom then
                  -- Base mesh weight slider.
                  if kit.getPieceEnabled(selSpline, pieceIndex) then
                    im.PushItemWidth(-1)
                    im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
                    im.Columns(2, "WeightCols" .. pieceIndex, false)
                    im.SetColumnWidth(0, 30)

                    local baseWeight = selSpline.pieceDistribution and selSpline.pieceDistribution[pieceIndex] and selSpline.pieceDistribution[pieceIndex].baseWeight or 1.0
                    if baseWeight < 1.0 then
                      if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetBaseWeightBtn' .. pieceIndex) then
                        local statePre = splineMgr.deepCopySidewalkSpline(selSpline)
                        selSpline.pieceDistribution = selSpline.pieceDistribution or {}
                        selSpline.pieceDistribution[pieceIndex] = selSpline.pieceDistribution[pieceIndex] or {}
                        selSpline.pieceDistribution[pieceIndex].baseWeight = 1.0
                        selSpline.distributionGroups = kit.buildDistributionGroups(selSpline)
                        selSpline.isDirty = true
                        editor.history:commitAction("Reset Base Weight", { old = statePre, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                      end
                      im.tooltip("Reset to default.")
                    else
                      im.Dummy(iconsSmall)
                    end
                    im.SameLine()
                    im.NextColumn()
                    im.PushItemWidth(-1)
                    tmpPtr = im.FloatPtr(baseWeight)
                    if im.SliderFloat('###baseWeight' .. pieceIndex, tmpPtr, 0.0, 1.0, "Base Weight = %.2f") then
                      selSpline.pieceDistribution = selSpline.pieceDistribution or {}
                      selSpline.pieceDistribution[pieceIndex] = selSpline.pieceDistribution[pieceIndex] or {}
                      selSpline.pieceDistribution[pieceIndex].baseWeight = tmpPtr[0]
                      selSpline.isDirty = true
                    end
                    im.tooltip("Set the weight for the base component.")
                    if im.IsItemActivated() then
                      sliderPreEditState = splineMgr.deepCopySidewalkSpline(selSpline)
                    end
                    if im.IsItemDeactivatedAfterEdit() then
                      selSpline.distributionGroups = kit.buildDistributionGroups(selSpline)
                      editor.history:commitAction("Adjust Base Weight", { old = sliderPreEditState, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                    end
                    im.PopItemWidth()
                    im.NextColumn()

                    im.Columns(1)
                    im.PopStyleVar()
                    im.PopItemWidth()
                  end

                  -- Variation weight sliders.
                  if piece.variations then
                    for j, variation in ipairs(piece.variations) do
                      local varId = variation.varId
                      if kit.getPieceEnabled(selSpline, varId) then
                        im.PushItemWidth(-1)
                        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
                        im.Columns(2, "WeightCols" .. pieceIndex .. "_" .. j, false)
                        im.SetColumnWidth(0, 30)

                        local varWeight = selSpline.pieceDistribution and selSpline.pieceDistribution[pieceIndex] and selSpline.pieceDistribution[pieceIndex].varWeights and selSpline.pieceDistribution[pieceIndex].varWeights[varId] or 1.0
                        if varWeight < 1.0 then
                          if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetVarWeightBtn' .. pieceIndex .. '_' .. j) then
                            local statePre = splineMgr.deepCopySidewalkSpline(selSpline)
                            selSpline.pieceDistribution = selSpline.pieceDistribution or {}
                            selSpline.pieceDistribution[pieceIndex] = selSpline.pieceDistribution[pieceIndex] or {}
                            selSpline.pieceDistribution[pieceIndex].varWeights = selSpline.pieceDistribution[pieceIndex].varWeights or {}
                            selSpline.pieceDistribution[pieceIndex].varWeights[varId] = 1.0
                            selSpline.distributionGroups = kit.buildDistributionGroups(selSpline)
                            selSpline.isDirty = true
                            editor.history:commitAction("Reset Variation Weight", { old = statePre, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                          end
                          im.tooltip("Reset to default.")
                        else
                          im.Dummy(iconsSmall)
                        end
                        im.SameLine()
                        im.NextColumn()
                        im.PushItemWidth(-1)
                        tmpPtr = im.FloatPtr(varWeight)
                        if im.SliderFloat('###varWeight' .. pieceIndex .. '_' .. j, tmpPtr, 0.0, 1.0, "Var" .. j .. " Weight = %.2f") then
                          selSpline.pieceDistribution = selSpline.pieceDistribution or {}
                          selSpline.pieceDistribution[pieceIndex] = selSpline.pieceDistribution[pieceIndex] or {}
                          selSpline.pieceDistribution[pieceIndex].varWeights = selSpline.pieceDistribution[pieceIndex].varWeights or {}
                          selSpline.pieceDistribution[pieceIndex].varWeights[varId] = tmpPtr[0]
                          selSpline.isDirty = true
                        end
                        im.tooltip("Set the weight for variation " .. tostring(j) .. ".")
                        if im.IsItemActivated() then
                          sliderPreEditState = splineMgr.deepCopySidewalkSpline(selSpline)
                        end
                        if im.IsItemDeactivatedAfterEdit() then
                          selSpline.distributionGroups = kit.buildDistributionGroups(selSpline)
                          editor.history:commitAction("Adjust Variation Weight", { old = sliderPreEditState, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
                        end
                        im.PopItemWidth()
                        im.NextColumn()

                        im.Columns(1)
                        im.PopStyleVar()
                        im.PopItemWidth()
                      end
                    end
                  end
                end
                im.Separator()
                isDistContent = true
              end
            end

            if not isDistContent then
              im.Text('The selected kit has no enabled variations')
            end
          else
            im.Text('Select a sidewalk kit first.')
          end

        elseif selectedTab == 2 then -- Terrain tab.
          im.TextColored(cols.greenB, "Terraforming:")
          im.Columns(2, "terrainSlidersRow_sidewalk", false)
          im.SetColumnWidth(0, 30)

          -- 'DOI' slider.
          if terraParams.terraDOI ~= 50.0 then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetDOI_sidewalk') then
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
          if im.SliderFloat('###sidewalk_doi', tmpPtr, DOImin, DOImax, "DOI = %.2f") then
            terraParams.terraDOI = tmpPtr[0]
          end
          im.tooltip('Set the Domain Of Influence, in meters.')
          im.PopItemWidth()
          im.NextColumn()

          -- 'Terraform Margin' slider.
          if terraParams.terraMargin ~= 5.0 then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetMargin_sidewalk') then
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
          if im.SliderFloat('###sidewalk_margin', tmpPtr, terraMarginMin, terraMarginMax, "Terraform Margin = %.2f") then
            terraParams.terraMargin = tmpPtr[0]
          end
          im.PopItemWidth()
          im.NextColumn()

          -- 'Terraform Falloff' slider.
          if terraParams.terraFalloff ~= 2.0 then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetFalloff_sidewalk') then
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
          if im.SliderFloat('###sidewalk_falloff', tmpPtr, terraFalloffMin, terraFalloffMax, "Terraform Falloff = %.2f") then
            terraParams.terraFalloff = tmpPtr[0]
          end
          im.PopItemWidth()
          im.NextColumn()

          -- 'Terraform Roughness' slider.
          if terraParams.terraRoughness ~= 0.0 then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetRough_sidewalk') then
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
          if im.SliderFloat('###sidewalk_rough', tmpPtr, 0.0, 1.0, "Noise Roughness = %.2f") then
            terraParams.terraRoughness = tmpPtr[0]
          end
          im.PopItemWidth()
          im.NextColumn()

          -- 'Terraform Scale' slider.
          if terraParams.terraScale ~= 0.0 then
            if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetScale_sidewalk') then
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
          if im.SliderFloat('###sidewalk_scale', tmpPtr, 0.0, 1.0, "Noise Scale = %.2f") then
            terraParams.terraScale = tmpPtr[0]
          end
          im.PopItemWidth()
          im.NextColumn()

          im.Columns(1)
          im.Columns(2, "terraformButtonsRow_sidewalk", false)
          im.SetColumnWidth(0, 39)
          im.SetColumnWidth(1, 39)
          im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
          im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

          -- 'Conform To Surface Below' toggle button.
          if selSpline and selSpline.isEnabled then
            btnCol = selSpline.isConformToTerrain and cols.blueB or cols.blueD
            if editor.uiIconImageButton(icons.lineToTerrain, iconsBig, btnCol, nil, nil, 'conformToTerrainBtn') then
              local statePre = splineMgr.deepCopySidewalkSpline(selSpline)
              selSpline.isConformToTerrain = not selSpline.isConformToTerrain
              selSpline.isDirty = true
                              editor.history:commitAction("Conform To Surface Below", { old = statePre, new = splineMgr.deepCopySidewalkSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
            end
            im.tooltip((selSpline.isConformToTerrain and 'Unconform' or 'Conform') .. ' the selected sidewalk spline to the surface below.')
          else
            im.Dummy(iconsBig)
          end
          im.SameLine()
          im.NextColumn()

          -- 'Terraform To Sidewalk Spline' button.
          if selSpline and selSpline.isEnabled and not selSpline.isLink and #selSpline.nodes > 1 and not selSpline.isConformToTerrain then
            if editor.uiIconImageButton(icons.terrainToLine, iconsBig, cols.blueB, nil, nil, 'terraformToSidewalkSplineBtn') then
              local sources = util.getSourcesSingle(selSpline)
              terra.terraformToSources(terraParams.terraDOI, terraParams.terraMargin, terraParams.terraFalloff, terraParams.terraRoughness, terraParams.terraScale, sources)
            end
            im.tooltip('Terraform the terrain to the selected Sidewalk Spline.')
          else
            im.Dummy(iconsBig)
          end
          im.NextColumn()

          im.PopStyleVar(2)
          im.Columns(1)
          im.Separator()

        end -- End of tab content.
      end -- End of TabContentChild.
      im.EndChild()
      im.PopStyleVar() -- Restore original padding.
    else
      im.Text("No sidewalk splines.")
      im.Text("Click the 'Add' button to add one.")
    end
  end
  editor.endWindow()
end

-- Callback for when the user has finished drawing a selection polygon.
local function onSelectionPolygonComplete(polygon)
  isDrawPolygon = false
end

-- World editor main callback.
local function onEditorGui()
  -- Ensure all sidewalk splines are updated, even if this tool is not active.
  splineMgr.updateDirtySidewalkSplines()

  -- If this tool is not active, render the shells of the splines but do nothing further.
  if not isSidewalkSplineActive then
    render.renderShells(splineMgr.getSidewalkSplines())
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
  local splines = splineMgr.getSidewalkSplines()
  local isConformToTerrain = selectedSplineIdx and splines[selectedSplineIdx] and splines[selectedSplineIdx].isConformToTerrain
  out.spline, out.node, out.isGizmoActive, out.isLockShape = selectedSplineIdx, selectedNodeIdx, isGizmoActive, isLockShape
  input.handleSplineEvents(
    splines,
    out,
    true, isConformToTerrain, false, false, false, true, true, isLockShape,
    defaultSplineWidth,
    splineMgr.deepCopySidewalkSpline, splineMgr.deepCopySidewalkSplineState,
    splineMgr.copySidewalkSplineProfile, splineMgr.pasteSidewalkSplineProfile,
    nil,
    splineMgr.joinSidewalkSplines,
    splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo,
    splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo)
  selectedSplineIdx, selectedNodeIdx, isGizmoActive, isLockShape = out.spline, out.node, out.isGizmoActive, out.isLockShape

  -- Render the sidewalk splines with debugDraw.
  render.handleSplineRendering(splines, selectedSplineIdx, selectedNodeIdx, isGizmoActive, true, isLockShape, false, false, elevScale)

  -- Render polylines for sidewalk splines (matches other spline tools).
  render.renderSplinePolylines(splines, selectedSplineIdx)
end

-- Called when the tool mode icon is pressed.
local function onActivate()
  isDrawPolygon = false
  poly.clearPolygon() -- Ensure there is no residual polygon left over from the previous usage.
  editor.clearObjectSelection()
  editor.showWindow(toolWinName)
  isSidewalkSplineActive = true
end

-- Called when the tool is exited.
local function onDeactivate()
  isDrawPolygon = false
  poly.clearPolygon() -- Ensure there is no residual polygon left over from the previous usage.
  editor.hideWindow(toolWinName)
  isSidewalkSplineActive = false
end

-- Called upon world editor initialization.
local function onEditorInitialized()
  editor.editModes.sidewalkSplineEditMode = {
    displayName = "Sidewalk Spline",
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    icon = editor.icons.roadSidewalkTransition,
    iconTooltip = "SidewalkSpline",
    auxShortcuts = {},
    hideObjectIcons = true }
  editor.registerWindow(toolWinName, toolWinSize)
end

-- Called when leaving the map.
local function onClientEndMission() splineMgr.removeAllSidewalkSplines(true) end


-- Public interface.
M.setSelectedSplineIdx =                                  setSelectedSplineIdx
M.setSelectedNodeIdx =                                    setSelectedNodeIdx

M.onSerialize =                                           onSerialize
M.onDeserialized =                                        onDeserialized

M.onEditorGui =                                           onEditorGui
M.onEditorInitialized =                                   onEditorInitialized
M.onClientEndMission =                                    onClientEndMission

return M
