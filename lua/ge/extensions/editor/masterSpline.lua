-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local defaultSplineWidth = 10.0 -- The default width for a spline when adding a new node, in meters.

local simplifyRdpTol = 9.0 -- The tolerance for the RDP simplification of the spline.

local latMin, latMax = -5.0, 5.0 -- The minimum and maximum values for the lateral position slider.
local DOImin, DOImax = 0.0, 500.0 -- The minimum and maximum values for the DOI (Domain Of Influence) slider.
local terraMarginMin, terraMarginMax = 1.0, 20.0 -- The minimum and maximum values for the terraform margin slider.
local terraFalloffMin, terraFalloffMax = 1.0, 5.0 -- The minimum and maximum values for the terraform falloff slider.

local elevScale = 100.0 -- The scale factor for the elevation drop lines (used for blue->red colour transition).

local autoRoadDefaults = {
  baseWidth = 10.0, -- The default base width value for the Auto Road.
  minBaseWidth = 1.0, -- The minimum value for the base width slider.
  maxBaseWidth = 100.0, -- The maximum value for the base width slider.
  slopeAvoidance = 1.0, -- The default slope avoidance value for the Auto Road feature.
  bankingStrength = 0.35, -- The default banking strength value for the Auto Road feature.
  widthBlend = 0.5, -- The default width blending value for the Auto Road feature (0 = no width variation, 1 = full width variation).
  addedWidth = 0.0, -- The default added width value for the Auto Road.
}

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- External dependencies.
local splineMgr = require('editor/masterSpline/splineMgr')
local layerMgr = require('editor/masterSpline/layerMgr')
local auto = require('editor/masterSpline/autoRoadGen')
local jumps = require('editor/masterSpline/jumpTables')
local meshSplineLink = require('editor/meshSpline/splineMgr')
local assemblySplineLink = require('editor/assemblySpline/splineMgr')
local decalSplineLink = require('editor/decalSpline/splineMgr')
local roadSplineLink = require('editor/roadSpline/groupMgr')
local terra = require('editor/terraform/terraform')
local input = require('editor/toolUtilities/splineInput')
local render = require('editor/toolUtilities/render')
local skeleton = require('editor/toolUtilities/skeleton')
local maskExport = require('editor/toolUtilities/splineMaskExport')
local rdp = require('editor/toolUtilities/rdp')
local roadDesignStandards = require('editor/toolUtilities/roadDesignStandards')
local util = require('editor/toolUtilities/util')
local geom = require('editor/toolUtilities/geom')
local style = require('editor/toolUtilities/style')

-- Register this tool with the shared spline input utilities.
input.registerSplineTool(
  splineMgr.getToolPrefixStr(),
  splineMgr.getMasterSplines,
  splineMgr.getEditModeKey,
  splineMgr.deepCopyMasterSpline,
  splineMgr.captureTransTierState,
  'editor_masterSpline'
)

-- Module constants.
local im = ui_imgui
local min, max, sin = math.min, math.max, math.sin
local toolWindowName, toolWindowSize = "masterSpline", im.ImVec2(200, 400) -- The main tool window of the editor. The main UI entry point.
local sliderDefaults = layerMgr.getSliderDefaults()
local roadDesignPresetStrs = roadDesignStandards.getPresetStrings()
local presetsMap = roadDesignStandards.getPresetsMap()
local iconsSmall, iconsBig = im.ImVec2(24, 24), im.ImVec2(36, 36)
local cols = style.getImguiCols('crystal')
local pulseFreq, pulseCol1, pulseCol2 = 1.0, cols.blueB, cols.redB
local pulseDelta = im.ImVec4(pulseCol2.x - pulseCol1.x, pulseCol2.y - pulseCol1.y, pulseCol2.z - pulseCol1.z, pulseCol2.w - pulseCol1.w)
local setLinkJumpTable = jumps.setLinkJumpTable
local toolNavigation = jumps.toolNavigation
local serializeJumpTable = jumps.serializeJumpTable
local removeJumpTable = jumps.removeJumpTable

-- Module state.
local isMasterSplineEditorActive = false
local selectedSplineIdx, selectedNodeIdx, selectedLayerIdx = 1, 1, 1
local isGizmoActive = false
local isLockShape = false
local isSplineAnalysisEnabled = false
local previousSelectedSplineIdx = -1
local sliderPreEditState = nil
local terraParams = {
  terraDOI = sliderDefaults.defaultDOI,
  terraMargin = sliderDefaults.defaultTerraMargin,
  terraFalloff = sliderDefaults.defaultTerraFalloff,
  terraRoughness = sliderDefaults.defaultTerraRoughness,
  terraScale = sliderDefaults.defaultTerraScale,
}
local autoParams = {
  baseWidth = autoRoadDefaults.baseWidth,
  slopeAvoidance = autoRoadDefaults.slopeAvoidance,
  bankingStrength = autoRoadDefaults.bankingStrength,
  widthBlend = autoRoadDefaults.widthBlend,
}
local out = {
  spline = selectedSplineIdx,
  node = selectedNodeIdx,
  layer = selectedLayerIdx,
  isGizmoActive = isGizmoActive,
  isLockShape = isLockShape,
}


-- Sets the selected spline index (for cross-tool selection).
local function setSelectedSplineIdx(idx) selectedSplineIdx = idx end

-- Sets the selected node index (for cross-tool selection).
local function setSelectedNodeIdx(idx) selectedNodeIdx = idx end

-- Serialisation callback.
local function onSerialize()
  local masterSplines = splineMgr.getMasterSplines()
  local serializedMasterSplines = {}
  for i = 1, #masterSplines do
    local masterSpline = masterSplines[i]
    serializedMasterSplines[i] = splineMgr.serializeMasterSpline(masterSpline)
  end
  for i = 1, #masterSplines do -- Unlink all splines before removing master splines.
    splineMgr.unlinkAllSplines(masterSplines[i])
  end
  splineMgr.removeAllMasterSplines()

  -- Reload the collision after all linked splines have been removed.
  -- [They can interfere after deserialisation - the collision is baked into the scene.]
  be:reloadCollision()

  return serializedMasterSplines
end

-- Deserialisation callback.
local function onDeserialized(data)
  local masterSplines = splineMgr.getMasterSplines() -- Unlink all splines before removing master splines.
  for i = 1, #masterSplines do
    splineMgr.unlinkAllSplines(masterSplines[i])
  end
  splineMgr.removeAllMasterSplines()
  for i = 1, #data do
    local masterSpline = splineMgr.deserializeMasterSpline(data[i])
    splineMgr.addToMasterSplineArray(masterSpline)
  end

  -- Recompute the master spline id -> index map.
  util.computeIdToIdxMap(splineMgr.getMasterSplines(), splineMgr.getIdToIdxMap())
end

-- Render the design profile UI.
local function renderDesignProfileUI(selSpline, icons)
  im.TextColored(cols.greenB, "Design Profile:")
  im.Columns(6, "designProfilePresetRow", false)
  im.SetColumnWidth(0, 39)
  im.SetColumnWidth(1, 39)
  im.SetColumnWidth(2, 39)
  im.SetColumnWidth(3, 39)
  im.SetColumnWidth(4, 39)
  im.SetColumnWidth(5, 39)
  im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
  im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

  -- 'Preset 1' button.
  local btnCol = selSpline.homologationPreset == roadDesignPresetStrs[1] and cols.blueB or cols.blueD
  if editor.uiIconImageButton(icons.highwayShoulderMerge, iconsBig, btnCol, nil, nil, 'preset1Btn') then
    local oldState = splineMgr.deepCopyMasterSpline(selSpline)
    selSpline.homologationPreset = roadDesignPresetStrs[1]
    selSpline.isDirty = true
    editor.history:commitAction("Switch AutoPilot Preset", { old = oldState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
  end
  im.tooltip(string.format('Switch AutoPilot preset to: [%s].', roadDesignPresetStrs[1]))
  im.SameLine()
  im.NextColumn()

  -- 'Preset 2' button.
  btnCol = selSpline.homologationPreset == roadDesignPresetStrs[2] and cols.blueB or cols.blueD
  if editor.uiIconImageButton(icons.roadSidewalkTransition, iconsBig, btnCol, nil, nil, 'preset2Btn') then
    local oldState = splineMgr.deepCopyMasterSpline(selSpline)
    selSpline.homologationPreset = roadDesignPresetStrs[2]
    selSpline.isDirty = true
    editor.history:commitAction("Switch AutoPilot Preset", { old = oldState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
  end
  im.tooltip(string.format('Switch AutoPilot preset to: [%s].', roadDesignPresetStrs[2]))
  im.SameLine()
  im.NextColumn()

  -- 'Preset 3' button.
  btnCol = selSpline.homologationPreset == roadDesignPresetStrs[3] and cols.blueB or cols.blueD
  if editor.uiIconImageButton(icons.create_forest, iconsBig, btnCol, nil, nil, 'preset3Btn') then
    local oldState = splineMgr.deepCopyMasterSpline(selSpline)
    selSpline.homologationPreset = roadDesignPresetStrs[3]
    selSpline.isDirty = true
    editor.history:commitAction("Switch AutoPilot Preset", { old = oldState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
  end
  im.tooltip(string.format('Switch AutoPilot preset to: [%s].', roadDesignPresetStrs[3]))
  im.SameLine()
  im.NextColumn()

  -- 'Preset 4' button.
  btnCol = selSpline.homologationPreset == roadDesignPresetStrs[4] and cols.blueB or cols.blueD
  if editor.uiIconImageButton(icons.ac_unit, iconsBig, btnCol, nil, nil, 'preset4Btn') then
    local oldState = splineMgr.deepCopyMasterSpline(selSpline)
    selSpline.homologationPreset = roadDesignPresetStrs[4]
    selSpline.isDirty = true
    editor.history:commitAction("Switch AutoPilot Preset", { old = oldState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
  end
  im.tooltip(string.format('Switch AutoPilot preset to: [%s].', roadDesignPresetStrs[4]))
  im.SameLine()
  im.NextColumn()

  -- 'Preset 5' button.
  btnCol = selSpline.homologationPreset == roadDesignPresetStrs[5] and cols.blueB or cols.blueD
  if editor.uiIconImageButton(icons.simobject_terrainblock, iconsBig, btnCol, nil, nil, 'preset5Btn') then
    local oldState = splineMgr.deepCopyMasterSpline(selSpline)
    selSpline.homologationPreset = roadDesignPresetStrs[5]
    selSpline.isDirty = true
    editor.history:commitAction("Switch AutoPilot Preset", { old = oldState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
  end
  im.tooltip(string.format('Switch AutoPilot preset to: [%s].', roadDesignPresetStrs[5]))
  im.SameLine()
  im.NextColumn()

  -- 'Preset 6' button.
  btnCol = selSpline.homologationPreset == roadDesignPresetStrs[6] and cols.blueB or cols.blueD
  if editor.uiIconImageButton(icons.terrain, iconsBig, btnCol, nil, nil, 'preset6Btn') then
    local oldState = splineMgr.deepCopyMasterSpline(selSpline)
    selSpline.homologationPreset = roadDesignPresetStrs[6]
    selSpline.isDirty = true
    editor.history:commitAction("Switch AutoPilot Preset", { old = oldState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
  end
  im.tooltip(string.format('Switch AutoPilot preset to: [%s].', roadDesignPresetStrs[6]))
  im.NextColumn()
  im.PopStyleVar(2)
end

-- Main tool window UI.
local function handleMainToolWindowUI()
  if editor.beginWindow(toolWindowName, "Master Spline Editor", im.WindowFlags_NoCollapse) then
    local icons = editor.icons
    local splines = splineMgr.getMasterSplines()

    -- Top buttons row.
    im.Columns(5, "topMasterButtonsRow", false)
    im.SetColumnWidth(0, 39)
    im.SetColumnWidth(1, 39)
    im.SetColumnWidth(2, 39)
    im.SetColumnWidth(3, 39)
    im.SetColumnWidth(4, 39)
    im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
    im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

    -- 'Add New Master Spline' button.
    if editor.uiIconImageButton(icons.roadStackPlus, iconsBig, cols.blueB, nil, nil, 'addNewMasterSplineBtn') then
      local newSpline = splineMgr.addNewMasterSpline()
      editor.history:commitAction("Add New Master Spline", { masterSplineId = newSpline.id }, splineMgr.undoAddNewMasterSpline, splineMgr.redoAddNewMasterSpline, true)
      selectedSplineIdx = #splines
    end
    im.tooltip('Add a new Master Spline.')
    im.SameLine()
    im.NextColumn()

    -- 'Import From Bitmap Mask' button.
    if editor.uiIconImageButton(icons.floppyDiskPlus, iconsBig, cols.blueB, nil, nil, 'importFromBitmapMaskBtn') then
      extensions.editor_fileDialog.openFile(
        function(data)
          if data.filepath then
            local paths = skeleton.getPathsFromPng(data.filepath)
            if #paths > 0 then
              -- Capture complete state before import
              local preState = {
                masterSplines = splineMgr.deepCopyAllMasterSplines(),
                linkedSplines = splineMgr.captureLinkedSplinesState()
              }

              splineMgr.convertPathsToMasterSplines(paths)

              -- Capture complete state after import
              local postState = {
                masterSplines = splineMgr.deepCopyAllMasterSplines(),
                linkedSplines = splineMgr.captureLinkedSplinesState()
              }

              editor.history:commitAction("Import Master Splines From Bitmap", { old = preState, new = postState }, splineMgr.transMasterSplineEditUndo, splineMgr.transMasterSplineEditRedo, true)
            end
          end
        end,
        {{"PNG",".png"}},
        false,
        "/")
    end
    im.tooltip('Import Master Splines from a bitmap mask.')
    im.SameLine()
    im.NextColumn()

    -- 'Remove All Master Splines' button.
    if #splines > 0 then
      if editor.uiIconImageButton(icons.trashBin2, iconsBig, cols.blueB, nil, nil, 'removeAllMasterSplinesBtn') then
        -- Capture complete state before removal
        local statePre = {
          masterSplines = splineMgr.deepCopyAllMasterSplines(),
          linkedSplines = splineMgr.captureLinkedSplinesState()
        }

        for i = 1, #splines do
          splineMgr.unlinkAllSplines(splines[i])
        end
        splineMgr.removeAllMasterSplines()

        -- Capture complete state after removal
        local statePost = {
          masterSplines = splineMgr.deepCopyAllMasterSplines(),
          linkedSplines = splineMgr.captureLinkedSplinesState()
        }

        editor.history:commitAction("Remove All Master Splines", { old = statePre, new = statePost }, splineMgr.transMasterSplineEditUndo, splineMgr.transMasterSplineEditRedo, true)
        selectedSplineIdx = 1
      end
      im.tooltip('Remove all Master Splines from the session.')
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Lock Shape' toggle button.
    local selSpline = splines[selectedSplineIdx]
    if selSpline and selSpline.isEnabled then
      local btnCol = isLockShape and cols.blueB or cols.blueD
      if editor.uiIconImageButton(icons.roadGuideArrowSolid, iconsBig, btnCol, nil, nil, 'lockShapeBtn') then
        isLockShape = not isLockShape
      end
      im.tooltip((isLockShape and 'Unlock the shape of the Master Spline to move nodes separately' or 'Lock the shape of the Master Spline to move nodes rigidly'))
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Export Spline Mask' button.
    if #splines > 0 then
      if editor.uiIconImageButton(icons.folder, iconsBig, cols.blueB, nil, nil, 'exportSplineMaskBtn') then
        local sources = util.getAllSources(splines)
        extensions.editor_fileDialog.saveFile(
          function(data)
            maskExport.export(data.filepath, sources, 1.0) -- TODO: Uses a 1m margin. Maybe make this a parameter later.
          end,
          {{"PNG",".png"}},
          false,
          "/",
          "File already exists.\nDo you want to overwrite the file?")
      end
      im.tooltip('Export the session as a .PNG mask file. Will not include any disabled Master Splines.')
    else
      im.Dummy(iconsBig)
    end
    im.NextColumn()

    im.PopStyleVar(2)
    im.Columns(1)
    im.Separator()

    -- Master Splines list.
    if #splines > 0 then
      im.TextColored(cols.greenB, "Master Splines:")
      selectedSplineIdx = max(1, min(#splines, selectedSplineIdx)) -- Ensure the selected layer index is within bounds.
      local didSplineIdxChange = (previousSelectedSplineIdx ~= selectedSplineIdx)
      previousSelectedSplineIdx = selectedSplineIdx
      im.PushItemWidth(-1)
      if im.BeginListBox('###1363', im.ImVec2(-1, 180)) then
        im.Columns(4, "splineListBoxColumns", true)
        im.SetColumnWidth(0, 30)
        im.SetColumnWidth(1, 180)
        im.SetColumnWidth(2, 35)
        im.SetColumnWidth(3, 35)
        im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(4, 2))
        im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
        local wCtr = 22322
        for i = 1, #splines do
          local spline = splines[i]
          local flag = i == selectedSplineIdx
          if im.Selectable1("###" .. tostring(wCtr), flag, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
            selectedSplineIdx = i
            spline.isDirty = true -- Set dirty on selection.
          end
          if didSplineIdxChange and i == selectedSplineIdx then
            im.SetScrollHereY(0.5) -- Scrolls so the selected Master Spline is centered vertically
            selectedLayerIdx = 1
          end
          wCtr = wCtr + 1
          im.SameLine()
          im.NextColumn()

          -- 'Master Spline Name' input field.
          local splineNamePtr = im.ArrayChar(32, spline.name)
          if spline.isEnabled then
            if im.InputText("###" .. tostring(wCtr), splineNamePtr, 32) then
              local preState = splineMgr.deepCopyMasterSpline(spline)
              spline.name = ffi.string(splineNamePtr)
              local statePost = splineMgr.deepCopyMasterSpline(spline)
              preState.isUpdateSceneTree = true
              statePost.isUpdateSceneTree = true
              editor.history:commitAction("Edit Master Spline Name", { old = preState, new = statePost }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
            end
            im.tooltip('Edit the Master Spline name.')
          else
            im.TextColored(cols.dullWhite, ffi.string(splineNamePtr))
            im.tooltip('This Master Spline is disabled.')
          end
          if im.IsItemActive() then
            selectedSplineIdx = i
          end
          wCtr = wCtr + 1
          im.SameLine()
          im.NextColumn()

          -- 'Remove Selected Master Spline' button.
          if spline and spline.isEnabled then
            if editor.uiIconImageButton(icons.trashBin2, iconsSmall, cols.blueB, nil, nil, 'removeMasterSpline' .. i) then
              -- Capture complete state before removal
              local statePre = {
                masterSplines = splineMgr.deepCopyAllMasterSplines(),
                linkedSplines = splineMgr.captureLinkedSplinesState()
              }

              splineMgr.unlinkAllSplines(spline)
              splineMgr.removeMasterSpline(i)

              -- Capture complete state after removal
              local statePost = {
                masterSplines = splineMgr.deepCopyAllMasterSplines(),
                linkedSplines = splineMgr.captureLinkedSplinesState()
              }

              editor.history:commitAction("Remove Master Spline", { old = statePre, new = statePost }, splineMgr.transMasterSplineEditUndo, splineMgr.transMasterSplineEditRedo, true)
              editor.endWindow()
              return
            end
            im.tooltip("Remove this Master Spline from the session.")
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()
          im.NextColumn()

          -- 'Enable/Disable Master Spline' toggle button.
          local eyeIcon = spline.isEnabled and icons.lock_open or icons.lock_outline
          local iconCol = spline.isEnabled and cols.fullWhite or cols.dullWhite
          if editor.uiIconImageButton(eyeIcon, iconsSmall, iconCol, nil, nil, "toggleEnableDisableBtn" .. i) then
            local statePre = splineMgr.deepCopyMasterSpline(spline)
            spline.isEnabled = not spline.isEnabled
            spline.isDirty = true
            selectedSplineIdx = i
            editor.history:commitAction("Toggle Master Spline Enable/Disable", { old = statePre, new = splineMgr.deepCopyMasterSpline(spline) }, splineMgr.singleMasterSplineEditUndo, splineMgr.singleMasterSplineEditRedo, true)
          end
          im.tooltip(spline.isEnabled and "Disable this Master Spline (content will remain but will be uneditable)" or "Enable this Master Spline (content will be editable)")
          im.NextColumn()
          im.Separator()
        end
        im.PopStyleVar(2)
        im.EndListBox()
      end
      im.Separator()

      -- Buttons underneath the Master Spline list box.
      im.Columns(6, "buttonsUnderneathMasterSplineListBox", false)
      im.SetColumnWidth(0, 39)
      im.SetColumnWidth(1, 39)
      im.SetColumnWidth(2, 39)
      im.SetColumnWidth(3, 39)
      im.SetColumnWidth(4, 39)
      im.SetColumnWidth(5, 39)
      im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
      im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

      -- 'Go To Master Spline' button.
      if selSpline and #selSpline.nodes > 0 then
        if editor.uiIconImageButton(icons.cameraFocusTopDown, iconsBig, cols.blueB, nil, nil, 'goToMasterSplineBtn') then
          util.goToSpline(selSpline.divPoints)
        end
        im.tooltip('Move the camera to the selected Master Spline.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Conform To Surface Below' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLinking and #selSpline.nodes > 0 and not selSpline.isOptimising and not selSpline.isLink then
        local btnCol = selSpline.isConformToTerrain and cols.blueB or cols.blueD
        if editor.uiIconImageButton(icons.lineToTerrain, iconsBig, btnCol, nil, nil, 'conformToTerrainBtn') then
          local statePre = splineMgr.deepCopyMasterSpline(selSpline)
          selSpline.isConformToTerrain = not selSpline.isConformToTerrain
          selSpline.isOptimising = false
          selSpline.isAutoBanking = false
          selSpline.isDirty = true
          editor.history:commitAction("Conform To Surface Below", { old = statePre, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
        end
        im.tooltip((selSpline.isConformToTerrain and 'Unconform' or 'Conform') .. ' the selected Master Spline to the surface below.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Split Master Spline' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink and selSpline.nodes[selectedNodeIdx] and #selSpline.nodes > 2 and (selSpline.isLoop or (selectedNodeIdx > 1 and selectedNodeIdx < #selSpline.nodes)) then
        if editor.uiIconImageButton(icons.content_cut, iconsBig, cols.blueB, nil, nil, 'splitBtn') then
          -- Capture complete state before split
          local statePre = {
            masterSplines = splineMgr.deepCopyAllMasterSplines(),
            linkedSplines = splineMgr.captureLinkedSplinesState()
          }

          splineMgr.splitMasterSpline(selSpline, selectedSplineIdx, selectedNodeIdx)

          -- Capture complete state after split
          local statePost = {
            masterSplines = splineMgr.deepCopyAllMasterSplines(),
            linkedSplines = splineMgr.captureLinkedSplinesState()
          }

          editor.history:commitAction("Split Master Spline", { old = statePre, new = statePost }, splineMgr.transMasterSplineEditUndo, splineMgr.transMasterSplineEditRedo, true)
        end
        im.tooltip('Splits the selected Master Spline into two, at the selected node.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Flip Direction' button.
      if selSpline and selSpline.isEnabled and #selSpline.nodes > 1 then
        if editor.uiIconImageButton(icons.cached, iconsBig, cols.blueB, nil, nil, 'flipDirectionBtn') then
          local statePre = splineMgr.deepCopyMasterSpline(selSpline)
          geom.flipSplineDirection(selSpline)
          selSpline.isDirty = true
          editor.history:commitAction("Flip Master Spline Direction", { old = statePre, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
        end
        im.tooltip('Flips the direction of the selected master spline (back to front).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Simplify Spline' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink and selSpline.nodes[selectedNodeIdx] and #selSpline.nodes > 2 then
        if editor.uiIconImageButton(icons.routeSimple, iconsBig, cols.blueB, nil, nil, 'simplifySplineBtn') then
          local statePre = splineMgr.deepCopyMasterSpline(selSpline)
          rdp.simplifyNodesWidthsNormals(selSpline.nodes, selSpline.widths, selSpline.nmls, simplifyRdpTol)
          selectedNodeIdx = max(1, min(#selSpline.nodes, selectedNodeIdx))
          selSpline.isDirty = true
          editor.history:commitAction("Simplify Master Spline", { old = statePre, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
        end
        im.tooltip('Simplifies the selected Master Spline (reduces the number of nodes).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Export to glTF' button.
      if selSpline and selSpline.isEnabled and #selSpline.nodes > 1 then
        if editor.uiIconImageButton(icons.floppyDisk, iconsBig, nil, nil, nil, 'exportToGLTFBtn') then
          extensions.editor_fileDialog.saveFile(
            function(data)
              local gltf = util.buildRibbonGLTF(selSpline.divPoints, selSpline.divWidths, selSpline.binormals)
              jsonWriteFile(data.filepath, gltf, true)
            end,
            {{"glTF Scene", ".gltf"}},
            false,
            "/",
            "File already exists.\nDo you want to overwrite the file?")
        end
        im.tooltip('Export the selected Master Spline to a GLTF file.')
      else
        im.Dummy(iconsBig)
      end
      im.NextColumn()
      im.Columns(1)
      im.PopStyleVar(2)
    end

    im.Columns(1)

    -- Auto Banking section.
    if selSpline and selSpline.isEnabled and not selSpline.isConformToTerrain then
      im.Separator()
      im.TextColored(cols.greenB, "Auto Banking:")
      im.Columns(2, "autoBankingSlidersRow", false)
      im.SetColumnWidth(0, 30)

      -- 'Auto Banking Strength' slider.
      if selSpline.bankStrength ~= sliderDefaults.defaultBankStrength then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetBankAutoBankingStrengthBtn') then
          local preEditState = splineMgr.deepCopyMasterSpline(selSpline)
          selSpline.bankStrength = sliderDefaults.defaultBankStrength
          selSpline.isDirty = true
          editor.history:commitAction("Reset Auto Banking Strength", { old = preEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
        end
        im.tooltip("Reset to default.")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      local tmpPtr = im.FloatPtr(selSpline.bankStrength)
      if im.SliderFloat('###4433', tmpPtr, 0.0, 1.0, "Auto Banking Strength = %.2f") then
        selSpline.bankStrength = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the strength of auto banking for the selected Master Spline.')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyMasterSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Auto Banking Strength", { old = sliderPreEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      -- 'Auto Banking Falloff' slider.
      if selSpline.autoBankFalloff ~= sliderDefaults.defaultAutoBankFalloff then
        if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetAutoBankFalloffBtn') then
          local preEditState = splineMgr.deepCopyMasterSpline(selSpline)
          selSpline.autoBankFalloff = sliderDefaults.defaultAutoBankFalloff
          selSpline.isDirty = true
          editor.history:commitAction("Reset Auto Banking Falloff", { old = preEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
        end
        im.tooltip("Reset to default.")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      tmpPtr = im.FloatPtr(selSpline.autoBankFalloff)
      if im.SliderFloat('###4434', tmpPtr, 0.5, 2.0, "Auto Banking Falloff = %.1f") then
        selSpline.autoBankFalloff = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set how quickly auto banking falls off from nodes (higher = tighter domain of influence).')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyMasterSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Auto Banking Falloff", { old = sliderPreEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()

      im.Columns(1)

      -- 'Set Auto Banking' toggle button.
      local btnCol = selSpline.isAutoBanking and cols.blueB or cols.blueD
      local btnIcon = selSpline.isAutoBanking and icons.signal_cellular_null or icons.signal_cellular_4_bar
      if editor.uiIconImageButton(btnIcon, iconsBig, btnCol, nil, nil, 'setAutoBankingBtn') then
        local statePre = splineMgr.deepCopyMasterSpline(selSpline)
        selSpline.isAutoBanking = not selSpline.isAutoBanking
        selSpline.isDirty = true
        editor.history:commitAction("Toggle Auto Banking", { old = statePre, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
      end
      im.tooltip(selSpline.isAutoBanking and 'Disable Auto Banking for the selected Master Spline.' or 'Enable Auto Banking for the selected Master Spline.')
    end

    -- Tabs section.
    if selSpline then
      im.Separator()

      -- Tab bar for organising the interface.
      local selectedTab = 0 -- Default to first tab.
      if im.BeginTabBar("MasterSplineTabs") then
        if im.BeginTabItem("Layers") then
          selectedTab = 0
          im.EndTabItem()
        end
        if im.BeginTabItem("Terrain") then
          selectedTab = 1
          im.EndTabItem()
        end
        if im.BeginTabItem("Optimization") then
          selectedTab = 2
          im.EndTabItem()
        end
        if im.BeginTabItem("Generation") then
          selectedTab = 3
          im.EndTabItem()
        end
        im.EndTabBar()
      end

      -- Automatically enable/disable spline analysis based on tab selection.
      isSplineAnalysisEnabled = (selectedTab == 2)

      -- Tab content.
      im.PushStyleVar2(im.StyleVar_WindowPadding, im.ImVec2(4, 8)) -- Reduce horizontal padding
      if im.BeginChild1("TabContentChild", im.ImVec2(0, 0), true) then
        if selectedTab == 0 and selSpline.isEnabled then -- Layers tab.
          -- Layers list box.
          if selSpline and selSpline.isEnabled and not selSpline.isOptimising then
            im.TextColored(cols.greenB, "Layers:")
            local layers = selSpline.layers
            selectedLayerIdx = max(1, min(#layers, selectedLayerIdx)) -- Ensure the selected layer index is within bounds.
            im.PushItemWidth(-1)
            if im.BeginListBox('###5363', im.ImVec2(-1, 180)) then
              im.Columns(4, "layerListBoxColumns", true)
              im.SetColumnWidth(0, 32)
              im.SetColumnWidth(1, 180)
              im.SetColumnWidth(2, 35)
              im.SetColumnWidth(3, 35)
              im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(4, 2))
              im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
              local wCtr = 51322
              for i = 1, #layers do
                local layer = layers[i]
                if layer then
                  -- Selectable row.
                  local flag = i == selectedLayerIdx
                  if im.Selectable1("###" .. tostring(wCtr), flag, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
                    selectedLayerIdx = i
                  end
                  wCtr = wCtr + 1
                  im.NextColumn()

                  -- Layer name.
                  im.PushItemWidth(-1)
                  local layerNamePtr = im.ArrayChar(32, layer.name)
                  if im.InputText("###" .. tostring(wCtr), layerNamePtr, 32) then
                    local preState = splineMgr.deepCopyMasterSpline(selSpline)
                    layer.name = ffi.string(layerNamePtr)
                    layer.isDirty = true
                    -- Update the linked spline's name to match the layer name.
                    if layer.linkedSplineId then
                      splineMgr.updateLinkedSplineName(layer.linkedSplineId, layer.linkType, layer.name)
                    end
                    editor.history:commitAction("Rename Layer", { old = preState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
                  end
                  im.tooltip('Edit the layer name.')
                  if im.IsItemActive() then
                    selectedLayerIdx = i
                  end
                  im.PopItemWidth()
                  wCtr = wCtr + 1
                  im.NextColumn()

                  -- 'Remove Selected Layer' button.
                  if editor.uiIconImageButton(icons.trashBin2, iconsSmall, cols.blueB, nil, nil, 'removeLayerBtn' .. i) then
                    -- Capture layer data and linked spline data before deletion.
                    local layerData = {
                      name = layer.name,
                      id = layer.id,
                      isDirty = layer.isDirty,
                      isLink = layer.isLink,
                      linkType = layer.linkType,
                      linkedSplineId = layer.linkedSplineId,
                      linkedSplineName = layer.linkedSplineName,
                      isFlip = layer.isFlip,
                      position = layer.position,
                      isTrackWidth = layer.isTrackWidth,
                    }

                    local linkedSplineData = nil
                    if layer.linkedSplineId then
                      if serializeJumpTable[layer.linkType] then
                        local splineData = serializeJumpTable[layer.linkType](layer.linkedSplineId)
                        if splineData then
                          linkedSplineData = {
                            type = layer.linkType,
                            id = layer.linkedSplineId,
                            data = splineData,
                          }
                        end
                      end
                    end

                    -- Remove the layer and linked spline
                    layerMgr.removeLayer(i, selSpline)
                    if layer.linkedSplineId then
                      if removeJumpTable[layer.linkType] then
                        removeJumpTable[layer.linkType](layer.linkedSplineId)
                      end
                    end

                    selectedLayerIdx = max(1, min(#selSpline.layers, selectedLayerIdx)) -- Ensure the selected layer index remains within bounds, post-removal.

                    local payload = {
                      masterSplineId = selSpline.id,
                      layerIndex = i,
                      layerData = layerData,
                      linkedSplineData = linkedSplineData,
                    }

                    editor.history:commitAction("Remove Layer", payload, splineMgr.undoLayerRemove, splineMgr.redoLayerRemove, true)
                    editor.endWindow()
                    return
                  end
                  im.tooltip('Remove this layer from the session.')
                  im.NextColumn()

                  -- 'Go To' button (only show for linked layers).
                  if layer.linkedSplineId and layer.linkType then
                    if editor.uiIconImageButton(icons.cameraFocusTopDown, iconsSmall, cols.blueB, nil, nil, 'goToLayerBtn' .. tostring(i)) then
                      -- Navigate to the linked spline's tool.
                      local toolInfo = toolNavigation[layer.linkType]
                      if toolInfo then
                        local modeKey = toolInfo.getModeKey()
                        local targetSplines = toolInfo.getSplines()
                        if modeKey and targetSplines then
                          -- Find the actual spline index in the target tool.
                          local actualSplineIdx = nil
                          for j = 1, #targetSplines do
                            if targetSplines[j].id == layer.linkedSplineId then
                              actualSplineIdx = j
                              break
                            end
                          end
                          if actualSplineIdx then
                            -- Switch to the target tool.
                            editor.selectEditMode(editor.editModes[modeKey])
                            local toolUIModule = extensions[toolInfo.uiModule]
                            if toolUIModule and toolUIModule.setSelectedSplineIdx then
                              toolUIModule.setSelectedSplineIdx(actualSplineIdx)
                            end
                          end
                        end
                      end
                    end
                    im.tooltip('Go to the linked spline in its tool')
                  else
                    im.Dummy(iconsSmall)
                  end
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
          if selSpline and selSpline.isEnabled and not selSpline.isOptimising then
            im.Columns(5, "buttonsUnderneathLayersListBox", false)
            im.SetColumnWidth(0, 39)
            im.SetColumnWidth(1, 39)
            im.SetColumnWidth(2, 39)
            im.SetColumnWidth(3, 39)
            im.SetColumnWidth(4, 39)
            im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
            im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

            -- 'Create And Link Road Spline' button.
            if editor.uiIconImageButton(icons.roadStack, iconsBig, cols.blueB, nil, nil, 'createLinkRoadSplineBtn') then
              local roadSplines = roadSplineLink.getGroups()
              local splineName = "[link] Road Spline " .. (#roadSplines + 1)
              layerMgr.addNewLayer(selSpline) -- Add new layer first.
              selectedLayerIdx = #selSpline.layers
              local selectedLayer = selSpline.layers[selectedLayerIdx]
              selectedLayer.name = splineName -- Set proper layer name.
              roadSplineLink.addNewGroup()
              local newRoadSplines = roadSplineLink.getCurrentRoadSplineList()
              if #newRoadSplines > 0 then
                local newSpline = newRoadSplines[#newRoadSplines] -- Get the newly created spline.
                local fullRoadSplines = roadSplineLink.getGroups()
                local idx = roadSplineLink.getIdToIdxMap()[newSpline.id]
                if idx and fullRoadSplines[idx] then
                  fullRoadSplines[idx].name = splineName
                end
                -- Link the road spline to the layer.
                setLinkJumpTable[newSpline.type](newSpline.id, selSpline.id, true)
                selectedLayer.linkType = newSpline.type
                selectedLayer.linkedSplineId = newSpline.id
                selectedLayer.linkedSplineName = newSpline.name
                selectedLayer.isTrackWidth = true -- Road splines get isTrackWidth = true.
                selectedLayer.isDirty = true

                -- Create payload for layer-specific undo/redo.
                local layerData = {
                  name = selectedLayer.name,
                  id = selectedLayer.id,
                  isDirty = selectedLayer.isDirty,
                  isLink = selectedLayer.isLink,
                  linkType = selectedLayer.linkType,
                  linkedSplineId = selectedLayer.linkedSplineId,
                  linkedSplineName = selectedLayer.linkedSplineName,
                  isFlip = selectedLayer.isFlip,
                  position = selectedLayer.position,
                  isTrackWidth = selectedLayer.isTrackWidth,
                }

                local linkedSplineData = {
                  type = newSpline.type,
                  id = newSpline.id,
                  data = serializeJumpTable[newSpline.type](newSpline.id),
                }

                local payload = {
                  masterSplineId = selSpline.id,
                  layerIndex = selectedLayerIdx,
                  layerData = layerData,
                  linkedSplineData = linkedSplineData,
                }

                editor.history:commitAction("Create Layer & Link Road Spline", payload, splineMgr.undoLayerAdd, splineMgr.redoLayerAdd, true)
              end
            end
            im.tooltip('Create a new layer with a new road spline linked to it')
            im.SameLine()
            im.NextColumn()

            -- 'Create And Link Mesh Spline' button.
            if editor.uiIconImageButton(icons.bSpline, iconsBig, cols.blueB, nil, nil, 'createLinkMeshSplineBtn') then
              local meshSplines = meshSplineLink.getMeshSplines()
              local splineName = "[link] Mesh Spline " .. (#meshSplines + 1)
              layerMgr.addNewLayer(selSpline) -- Add new layer first.
              selectedLayerIdx = #selSpline.layers
              local selectedLayer = selSpline.layers[selectedLayerIdx]
              selectedLayer.name = splineName -- Set proper layer name.
              meshSplineLink.addNewMeshSpline()
              local newMeshSplines = meshSplineLink.getCurrentMeshSplineList()
              if #newMeshSplines > 0 then
                local newSpline = newMeshSplines[#newMeshSplines] -- Get the newly created spline.
                local fullMeshSplines = meshSplineLink.getMeshSplines()
                local idx = meshSplineLink.getSplineMap()[newSpline.id]
                if idx and fullMeshSplines[idx] then
                  fullMeshSplines[idx].name = splineName
                end
                -- Link the mesh spline to the layer.
                setLinkJumpTable[newSpline.type](newSpline.id, selSpline.id, true)
                selectedLayer.linkType = newSpline.type
                selectedLayer.linkedSplineId = newSpline.id
                selectedLayer.linkedSplineName = newSpline.name
                selectedLayer.isDirty = true

                -- Create payload for layer-specific undo/redo.
                local payload = {
                  masterSplineId = selSpline.id,
                  layerIndex = selectedLayerIdx,
                  linkedSplineData = {
                    type = newSpline.type,
                    id = newSpline.id,
                    data = serializeJumpTable[newSpline.type](newSpline.id),
                  },
                }

                editor.history:commitAction("Create Layer & Link Mesh Spline", payload, splineMgr.undoLayerAdd, splineMgr.redoLayerAdd, true)
              end
            end
            im.tooltip('Create a new layer with a new mesh spline linked to it')
            im.SameLine()
            im.NextColumn()

            -- 'Create And Link Assembly Spline' button.
            if editor.uiIconImageButton(icons.gyroscope, iconsBig, cols.blueB, nil, nil, 'createLinkAssemblySplineBtn') then
              local assemblySplines = assemblySplineLink.getAssemblySplines()
              local splineName = "[link] Assembly Spline " .. (#assemblySplines + 1)
              layerMgr.addNewLayer(selSpline) -- Add new layer first.
              selectedLayerIdx = #selSpline.layers
              local selectedLayer = selSpline.layers[selectedLayerIdx]
              selectedLayer.name = splineName -- Set proper layer name.
              assemblySplineLink.addNewAssemblySpline()
              local newAssemblySplines = assemblySplineLink.getCurrentAssemblySplineList()
              if #newAssemblySplines > 0 then
                local newSpline = newAssemblySplines[#newAssemblySplines] -- Get the newly created spline.
                local fullAssemblySplines = assemblySplineLink.getAssemblySplines()
                local idx = assemblySplineLink.getSplineMap()[newSpline.id]
                if idx and fullAssemblySplines[idx] then
                  fullAssemblySplines[idx].name = splineName
                end
                -- Link the assembly spline to the layer.
                setLinkJumpTable[newSpline.type](newSpline.id, selSpline.id, true)
                selectedLayer.linkType = newSpline.type
                selectedLayer.linkedSplineId = newSpline.id
                selectedLayer.linkedSplineName = newSpline.name
                selectedLayer.isDirty = true

                -- Create payload for layer-specific undo/redo.
                local payload = {
                  masterSplineId = selSpline.id,
                  layerIndex = selectedLayerIdx,
                  linkedSplineData = {
                    type = newSpline.type,
                    id = newSpline.id,
                    data = serializeJumpTable[newSpline.type](newSpline.id),
                  },
                }

                editor.history:commitAction("Create Layer & Link Assembly Spline", payload, splineMgr.undoLayerAdd, splineMgr.redoLayerAdd, true)
              end
            end
            im.tooltip('Create a new layer with a new assembly spline linked to it')
            im.SameLine()
            im.NextColumn()

            -- 'Create And Link Decal Spline' button.
            if editor.uiIconImageButton(icons.decalRoad, iconsBig, cols.blueB, nil, nil, 'createLinkDecalSplineBtn') then
              local decalSplines = decalSplineLink.getDecalSplines()
              local splineName = "[link] Decal Spline " .. (#decalSplines + 1)
              layerMgr.addNewLayer(selSpline) -- Add new layer first.
              selectedLayerIdx = #selSpline.layers
              local selectedLayer = selSpline.layers[selectedLayerIdx]
              selectedLayer.name = splineName -- Set proper layer name.
              decalSplineLink.addNewDecalSpline()
              local newDecalSplines = decalSplineLink.getCurrentDecalSplineList()
              if #newDecalSplines > 0 then
                local newSpline = newDecalSplines[#newDecalSplines] -- Get the newly created spline.
                local fullDecalSplines = decalSplineLink.getDecalSplines()
                local idx = decalSplineLink.getSplineMap()[newSpline.id]
                if idx and fullDecalSplines[idx] then
                  fullDecalSplines[idx].name = splineName
                end
                -- Link the decal spline to the layer.
                setLinkJumpTable[newSpline.type](newSpline.id, selSpline.id, true)
                selectedLayer.linkType = newSpline.type
                selectedLayer.linkedSplineId = newSpline.id
                selectedLayer.linkedSplineName = newSpline.name
                selectedLayer.isDirty = true

                -- Create payload for layer-specific undo/redo.
                local layerData = {
                  name = selectedLayer.name,
                  id = selectedLayer.id,
                  isDirty = selectedLayer.isDirty,
                  isLink = selectedLayer.isLink,
                  linkType = selectedLayer.linkType,
                  linkedSplineId = selectedLayer.linkedSplineId,
                  linkedSplineName = selectedLayer.linkedSplineName,
                  isFlip = selectedLayer.isFlip,
                  position = selectedLayer.position,
                }

                local linkedSplineData = {
                  type = newSpline.type,
                  id = newSpline.id,
                  data = serializeJumpTable[newSpline.type](newSpline.id),
                }

                local payload = {
                  masterSplineId = selSpline.id,
                  layerIndex = selectedLayerIdx,
                  layerData = layerData,
                  linkedSplineData = linkedSplineData,
                }

                editor.history:commitAction("Create Layer & Link Decal Spline", payload, splineMgr.undoLayerAdd, splineMgr.redoLayerAdd, true)
              end
            end
            im.tooltip('Create a new layer with a new decal spline linked to it')
            im.SameLine()
            im.NextColumn()

            -- 'Remove All Layers' button.
            if selSpline and #selSpline.layers > 0 and selSpline.isEnabled and not selSpline.isOptimising then
              if editor.uiIconImageButton(icons.trashBin2, iconsBig, cols.redB, nil, nil, 'removeAlLayersBtn') then
                -- Capture complete state before removal (including linked splines).
                local preState = {
                  masterSplines = { splineMgr.deepCopyMasterSpline(selSpline) },
                  linkedSplines = splineMgr.captureLinkedSplinesState()
                }

                splineMgr.unlinkAllSplines(selSpline)
                layerMgr.removeAllLayers(selSpline)
                selectedLayerIdx = 1

                -- Capture complete state after removal.
                local postState = {
                  masterSplines = { splineMgr.deepCopyMasterSpline(selSpline) },
                  linkedSplines = splineMgr.captureLinkedSplinesState()
                }

                editor.history:commitAction("Remove All Layers", { old = preState, new = postState }, splineMgr.transMasterSplineEditUndo, splineMgr.transMasterSplineEditRedo, true)
              end
              im.tooltip('Remove all layers from the Master Spline')
            else
              im.Dummy(iconsBig)
            end
            im.NextColumn()
            im.PopStyleVar(2)
            im.Columns(1)
            im.Separator()

            -- Layer-specific UI (for the selected layer).
            if selSpline and selSpline.isEnabled and selSpline.layers[selectedLayerIdx] and not selSpline.isOptimising then
              -- Layer-specific controls.
              im.TextColored(cols.greenB, "Layer Controls:")
              im.Dummy(im.ImVec2(0, 2))
              im.PushItemWidth(-1)
              im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)

              -- 'Flip Laterally' checkbox.
              local selectedLayer = selSpline.layers[selectedLayerIdx]
              local tmpPtr = im.BoolPtr(selectedLayer.isFlip)
              if im.Checkbox("Flip Lateral", tmpPtr) then
                local preState = splineMgr.deepCopyMasterSpline(selSpline)
                selectedLayer.isFlip = tmpPtr[0]
                selectedLayer.isDirty = true
                editor.history:commitAction("Change Flip Lateral", { old = preState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
              end
              im.tooltip('Toggle whether this layer should be flipped laterally (left <--> right).')

              im.PopStyleVar()
              im.PopItemWidth()

              -- Layer-specific controls.
              im.Columns(1)
              im.PushItemWidth(-1)
              im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)

              -- 'Lateral Position' slider.
              if selectedLayer.position ~= sliderDefaults.defaultLateralPosition then
                if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetPosBtn') then
                  local preEditState = splineMgr.deepCopyMasterSpline(selSpline)
                  selectedLayer.position = sliderDefaults.defaultLateralPosition
                  selectedLayer.isDirty = true
                  editor.history:commitAction("Reset Position", { old = preEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
                end
                im.tooltip("Reset to default")
              else
                im.Dummy(iconsSmall)
              end
              im.SameLine()
              im.NextColumn()
              im.PushItemWidth(-1)
              tmpPtr = im.FloatPtr(selectedLayer.position)
              if im.SliderFloat("###8131", tmpPtr, latMin, latMax, "Lateral Position = %.2f") then
                selectedLayer.position = tmpPtr[0]
                selectedLayer.isDirty = true
              end
              im.tooltip('Set the lateral position of the layer on the Master Spline (-1.0 = left edge, 0.0 = center, 1.0 = right edge).')
              if im.IsItemActivated() then
                sliderPreEditState = splineMgr.deepCopyMasterSpline(selSpline)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Position", { old = sliderPreEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
              end
              im.NextColumn()
              im.PopStyleVar()
              im.Separator()
            end
          end
        elseif selectedTab == 1 and selSpline.isEnabled then -- Terrain tab.
          if selSpline.isConformToTerrain then
            im.Columns(1)
            im.TextColored(cols.greenB, "Spline Is Conformed To Surface")
            im.Text("Terraforming controls are disabled.")
          else
            im.Columns(1)
            im.TextColored(cols.greenB, "Terraforming:")

            -- Terraforming controls.
            im.Columns(2, "terrainSlidersRow", false)
            im.SetColumnWidth(0, 30)

            -- 'DOI' slider.
            if terraParams.terraDOI ~= sliderDefaults.defaultDOI then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetDOIBtn') then
                local preEditState = splineMgr.deepCopyMasterSpline(selSpline)
                terraParams.terraDOI = sliderDefaults.defaultDOI
                selSpline.isDirty = true
                editor.history:commitAction("Reset DOI", { old = preEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            local tmpPtr = im.FloatPtr(terraParams.terraDOI)
            if im.SliderFloat('###23811', tmpPtr, DOImin, DOImax, "DOI = %.2f") then
              terraParams.terraDOI = tmpPtr[0]
              selSpline.isDirty = true
            end
            im.tooltip('Set the Domain Of Influence, in meters.')
            if im.IsItemActivated() then
              sliderPreEditState = splineMgr.deepCopyMasterSpline(selSpline)
            end
                          if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust DOI", { old = sliderPreEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
              end
            im.PopItemWidth()
            im.NextColumn()

            -- 'Terraform Margin' slider.
            if terraParams.terraMargin ~= sliderDefaults.defaultTerraMargin then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetTerraMarginBtn') then
                local preEditState = splineMgr.deepCopyMasterSpline(selSpline)
                terraParams.terraMargin = sliderDefaults.defaultTerraMargin
                selSpline.isDirty = true
                editor.history:commitAction("Reset Terraform Margin", { old = preEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            tmpPtr = im.FloatPtr(terraParams.terraMargin)
            if im.SliderFloat('###34341', tmpPtr, terraMarginMin, terraMarginMax, "Terraform Margin = %.2f") then
              terraParams.terraMargin = tmpPtr[0]
              selSpline.isDirty = true
            end
            im.tooltip('Set the margin around the spline, in meters.')
            if im.IsItemActivated() then
              sliderPreEditState = splineMgr.deepCopyMasterSpline(selSpline)
            end
            if im.IsItemDeactivatedAfterEdit() then
              editor.history:commitAction("Adjust Terraform Margin", { old = sliderPreEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()

            -- 'Terraform Falloff' slider.
            if terraParams.terraFalloff ~= sliderDefaults.defaultTerraFalloff then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetTerraFalloffBtn') then
                local preEditState = splineMgr.deepCopyMasterSpline(selSpline)
                terraParams.terraFalloff = sliderDefaults.defaultTerraFalloff
                selSpline.isDirty = true
                editor.history:commitAction("Reset Terraform Falloff", { old = preEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            tmpPtr = im.FloatPtr(terraParams.terraFalloff)
            if im.SliderFloat('###32226', tmpPtr, terraFalloffMin, terraFalloffMax, "Terraform Falloff = %.2f") then
              terraParams.terraFalloff = tmpPtr[0]
              selSpline.isDirty = true
            end
            im.tooltip('Set the slope falloff exponent (1 = soft, 5 = sharp).')
            if im.IsItemActivated() then
              sliderPreEditState = splineMgr.deepCopyMasterSpline(selSpline)
            end
            if im.IsItemDeactivatedAfterEdit() then
              editor.history:commitAction("Adjust Terraform Falloff", { old = sliderPreEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()

            -- 'Terraform Roughness' slider.
            if terraParams.terraRoughness ~= sliderDefaults.defaultTerraRoughness then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetTerraRoughnessBtn') then
                local preEditState = splineMgr.deepCopyMasterSpline(selSpline)
                terraParams.terraRoughness = sliderDefaults.defaultTerraRoughness
                selSpline.isDirty = true
                editor.history:commitAction("Reset Terraform Roughness", { old = preEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            tmpPtr = im.FloatPtr(terraParams.terraRoughness)
            if im.SliderFloat('###32227', tmpPtr, 0.0, 1.0, "Noise Roughness = %.2f") then
              terraParams.terraRoughness = tmpPtr[0]
              selSpline.isDirty = true
            end
            im.tooltip('Set the noise roughness/amplitude (0 = no noise, 1 = full roughness).')
            if im.IsItemActivated() then
              sliderPreEditState = splineMgr.deepCopyMasterSpline(selSpline)
            end
            if im.IsItemDeactivatedAfterEdit() then
              editor.history:commitAction("Adjust Terraform Roughness", { old = sliderPreEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()

            -- 'Terraform Scale' slider.
            if terraParams.terraScale ~= sliderDefaults.defaultTerraScale then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetTerraScaleBtn') then
                local preEditState = splineMgr.deepCopyMasterSpline(selSpline)
                terraParams.terraScale = sliderDefaults.defaultTerraScale
                selSpline.isDirty = true
                editor.history:commitAction("Reset Terraform Scale", { old = preEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            tmpPtr = im.FloatPtr(terraParams.terraScale)
            if im.SliderFloat('###32228', tmpPtr, 0.0, 1.0, "Noise Scale = %.2f") then
              terraParams.terraScale = tmpPtr[0]
              selSpline.isDirty = true
            end
            im.tooltip('Set the scale/frequency of the noise (low = large bumps, high = small bumps).')
            if im.IsItemActivated() then
              sliderPreEditState = splineMgr.deepCopyMasterSpline(selSpline)
            end
            if im.IsItemDeactivatedAfterEdit() then
              editor.history:commitAction("Adjust Terraform Scale", { old = sliderPreEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()
            im.Columns(1)

            -- 'Terraform To Master Spline' button.
            if selSpline and selSpline.isEnabled and #selSpline.nodes > 1 and not selSpline.isConformToTerrain and not selSpline.isOptimising then
              if editor.uiIconImageButton(icons.terrainToLine, iconsBig, cols.blueB, nil, nil, 'terraformToMasterSplineBtn') then
                local sources = util.getSourcesSingle(selSpline)
                terra.terraformToSources(
                  terraParams.terraDOI, terraParams.terraMargin, terraParams.terraFalloff,
                  terraParams.terraRoughness, terraParams.terraScale,
                  sources)
                selSpline.isDirty = true
              end
              im.tooltip('Terraform the terrain to the selected Master Spline.')
            else
              im.Dummy(iconsBig)
            end
            im.NextColumn()
            im.Columns(1)
            im.Separator()
          end
        elseif selectedTab == 2 and selSpline.isEnabled then -- Spline Analysis tab.
          renderDesignProfileUI(selSpline, icons)
          im.Separator()
          im.Columns(1)
          im.TextColored(cols.greenB, "Constraints:")
          local tmpPtr = im.IntPtr(selSpline.splineAnalysisMode)

          if im.RadioButton2("[Slope Gradient Compliance]", tmpPtr, 0) then
            selSpline.splineAnalysisMode = 0
            selSpline.isDirty = true
          end
          im.tooltip('Analyze slope gradient violations against road design standards.')

          if im.RadioButton2("[Corner Radius Compliance]", tmpPtr, 1) then
            selSpline.splineAnalysisMode = 1
            selSpline.isDirty = true
          end
          im.tooltip('Analyze corner radius violations for safe vehicle turning.')

          if im.RadioButton2("[Banking Angle Compliance]", tmpPtr, 2) then
            selSpline.splineAnalysisMode = 2
            selSpline.isDirty = true
          end
          im.tooltip('Analyze banking angle violations for proper vehicle dynamics.')

          if im.RadioButton2("[Width Rate Of Change Compliance]", tmpPtr, 3) then
            selSpline.splineAnalysisMode = 3
            selSpline.isDirty = true
          end
          im.tooltip('Analyze width gradient violations for smooth lane transitions.')
          im.Dummy(im.ImVec2(0, 3))
          im.Separator()

          -- 'Optimise' toggle button / 'Generate Auto Road' button.
          im.Columns(1)
          im.TextColored(cols.greenB, "Live Optimize:")
          if #selSpline.nodes > 2 then
            local btnCol = cols.blueB
            if selSpline.isOptimising then -- If optimising, pulse the colour of the button to indicate that it is executing.
              local t = os.clock() * pulseFreq
              local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
              btnCol = im.ImVec4(pulseCol1.x + pulseDelta.x * s, pulseCol1.y + pulseDelta.y * s, pulseCol1.z + pulseDelta.z * s, pulseCol1.w + pulseDelta.w * s)
            end
            if editor.uiIconImageButton(icons.puzzleModule, iconsBig, btnCol, nil, nil, 'optimiseBtn') then
              local oldState = splineMgr.deepCopyMasterSpline(selSpline)
              selSpline.isOptimising = not selSpline.isOptimising
              selSpline.isDirty = true
              editor.history:commitAction("Toggle Live Optimize", { old = oldState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
            end
            im.tooltip(selSpline.isOptimising and 'Disable Live Optimize for the selected Master Spline.' or 'Enable Live Optimize for the selected Master Spline.')
          end
          im.Separator()
        elseif selectedTab == 3 and selSpline.isEnabled then -- Path Generation tab.
          renderDesignProfileUI(selSpline, icons) -- Show the design profiles panel.
          im.Columns(1)

          -- Path Generation controls.
          if #selSpline.nodes > 1 then
            im.Separator()
            im.TextColored(cols.greenB, "Generator Settings:")
            im.Columns(2, "autoRoadSlidersRow", false)
            im.SetColumnWidth(0, 30)

            -- 'Base Width' slider.
            if autoParams.baseWidth ~= autoRoadDefaults.baseWidth then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetBaseWidthBtn') then
                local preEditState = splineMgr.deepCopyMasterSpline(selSpline)
                autoParams.baseWidth = autoRoadDefaults.baseWidth
                editor.history:commitAction("Reset Base Width", { old = preEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            local tmpPtr = im.FloatPtr(autoParams.baseWidth)
            if im.SliderFloat("###35412", tmpPtr, autoRoadDefaults.minBaseWidth, autoRoadDefaults.maxBaseWidth, "Base Width = %.2f") then
              autoParams.baseWidth = tmpPtr[0]
            end
            im.tooltip('Set the base width of the Auto Road, in meters.')
            if im.IsItemActivated() then
              sliderPreEditState = splineMgr.deepCopyMasterSpline(selSpline)
            end
            if im.IsItemDeactivatedAfterEdit() then
              editor.history:commitAction("Adjust Base Width", { old = sliderPreEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()

            -- 'Slope Avoidance' slider.
            if autoParams.slopeAvoidance ~= autoRoadDefaults.slopeAvoidance then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetSlopeAvoidanceBtn') then
                local preEditState = splineMgr.deepCopyMasterSpline(selSpline)
                autoParams.slopeAvoidance = autoRoadDefaults.slopeAvoidance
                editor.history:commitAction("Reset Slope Avoidance", { old = preEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            tmpPtr = im.FloatPtr(autoParams.slopeAvoidance)
            if im.SliderFloat("###35415", tmpPtr, 0, 1, "Slope Avoidance = %.2f") then
              autoParams.slopeAvoidance = tmpPtr[0]
            end
            im.tooltip('Set the slope avoidance of the Auto Road (0 = path will accept large slopes, 1 = strong slope avoidance).')
            if im.IsItemActivated() then
              sliderPreEditState = splineMgr.deepCopyMasterSpline(selSpline)
            end
            if im.IsItemDeactivatedAfterEdit() then
              editor.history:commitAction("Adjust Slope Avoidance", { old = sliderPreEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()

            -- 'Width Blend' slider.
            if autoParams.widthBlend ~= autoRoadDefaults.widthBlend then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetWidthBlendBtn') then
                local preEditState = splineMgr.deepCopyMasterSpline(selSpline)
                autoParams.widthBlend = autoRoadDefaults.widthBlend
                editor.history:commitAction("Reset Width Blend", { old = preEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            tmpPtr = im.FloatPtr(autoParams.widthBlend)
            if im.SliderFloat("###65422", tmpPtr, 0, 1, "Added Width = %.2f") then
              autoParams.widthBlend = tmpPtr[0]
            end
            im.tooltip('Set the amount of added width for corners (0 = no added width, 1 = max extra width).')
            if im.IsItemActivated() then
              sliderPreEditState = splineMgr.deepCopyMasterSpline(selSpline)
            end
            if im.IsItemDeactivatedAfterEdit() then
              editor.history:commitAction("Adjust Added Width Blend", { old = sliderPreEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()

            -- 'Banking Strength' slider.
            if autoParams.bankingStrength ~= autoRoadDefaults.bankingStrength then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetBankingStrengthBtn') then
                local preEditState = splineMgr.deepCopyMasterSpline(selSpline)
                autoParams.bankingStrength = autoRoadDefaults.bankingStrength
                editor.history:commitAction("Reset Banking Strength", { old = preEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(iconsSmall)
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            tmpPtr = im.FloatPtr(autoParams.bankingStrength)
            if im.SliderFloat("###35417", tmpPtr, 0, 1, "Banking Strength = %.2f") then
              autoParams.bankingStrength = tmpPtr[0]
            end
            im.tooltip('Set the banking strength of the Auto Road (0 = no banking, 1 = strong banking).')
            if im.IsItemActivated() then
              sliderPreEditState = splineMgr.deepCopyMasterSpline(selSpline)
            end
            if im.IsItemDeactivatedAfterEdit() then
              editor.history:commitAction("Adjust Banking Strength", { old = sliderPreEditState, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()

            im.Columns(1)
            im.Columns(3, "previewBtns", false)
            im.SetColumnWidth(0, 39)
            im.SetColumnWidth(1, 39)
            im.SetColumnWidth(2, 39)
            im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
            im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

            -- 'Generate Auto Road Preview' button.
            if selSpline and selSpline.isEnabled then
              if editor.uiIconImageButton(icons.flash_auto, iconsBig, cols.blueB, nil, nil, 'generateAutoRoadPreviewBtn') then
                auto.generateAutoPreview(selSpline, autoParams, presetsMap[selSpline.homologationPreset])
              end
              im.tooltip('Create an auto-generated spline preview through all nodes.')
            else
              im.Dummy(iconsBig)
            end
            im.SameLine()
            im.NextColumn()

            -- 'Clear Auto Road Preview' button.
            if auto.isPreview() then
              if editor.uiIconImageButton(icons.trashBin2, iconsBig, cols.blueB, nil, nil, 'clearAutoRoadPreviewBtn') then
                auto.clearPreview()
              end
              im.tooltip('Clear the auto-generated road preview.')
            else
              im.Dummy(iconsBig)
            end
            im.SameLine()
            im.NextColumn()

            -- 'Create Auto Road From Preview' button.
            if auto.isPreview() then
              if editor.uiIconImageButton(icons.touch_app, iconsBig, cols.redB, nil, nil, 'createAutoRoadFromPreviewBtn') then
                local statePre = splineMgr.deepCopyMasterSpline(selSpline)
                auto.createAutoRoad(selSpline, autoParams.bankingStrength, autoParams.autoBankFalloff)
                editor.history:commitAction("Create Auto Road", { old = statePre, new = splineMgr.deepCopyMasterSpline(selSpline) }, splineMgr.lightSplineUndo, splineMgr.lightSplineRedo, true)
              end
              im.tooltip('Convert the auto-generated preview into a master spline.')
            else
              im.Dummy(iconsBig)
            end
            im.NextColumn()
            im.Separator()
            im.PopStyleVar(2) -- Pop FramePadding/ItemSpacing pushed for the preview buttons.
          end
        end -- End of TabContentChild.
      end -- End of tab content.
      im.PopStyleVar() -- Restore original padding.
      im.EndChild() -- Must always be called for BeginChild1, regardless of return value.
    else
      if not selSpline then
        im.Text("No master splines.")
        im.Text("Click the 'Add' button to add one.")
      end
    end
    im.Columns(1)
  end
  editor.endWindow()
end

-- Main editor callback.
local function onEditorGui()
  -- Manage the Live Optimise of the selected Master Spline only.
  splineMgr.manageLiveOptimise(selectedSplineIdx)

  -- Ensure all Master Splines are updated, even if this tool is not active.
  splineMgr.updateDirtyMasterSplines(isSplineAnalysisEnabled)

  -- If this tool is not active, render the shells of the splines but do nothing further.
  if not isMasterSplineEditorActive then
    render.renderShells(splineMgr.getMasterSplines())
    return
  end

  -- Handle the main tool window UI.
  handleMainToolWindowUI()

  -- Handle the mouse and keyboard events.
  local masterSplines = splineMgr.getMasterSplines()
  local selMasterSpline = masterSplines[selectedSplineIdx]
  out.spline, out.node, out.layer, out.isGizmoActive, out.isLockShape = selectedSplineIdx, selectedNodeIdx, selectedLayerIdx, isGizmoActive, isLockShape
  input.handleSplineEvents(
    masterSplines,
    out,
    (not (selMasterSpline and selMasterSpline.isAutoBanking) and not (selMasterSpline and selMasterSpline.isConformToTerrain)),
    selMasterSpline and selMasterSpline.isConformToTerrain,
    true, false, false, false, true, isLockShape,
    defaultSplineWidth,
    splineMgr.deepCopyMasterSpline,
    splineMgr.captureTransTierState,
    nil, nil,
    nil,
    splineMgr.joinMasterSplines,
    splineMgr.lightSplineUndo, splineMgr.lightSplineRedo,
    splineMgr.transMasterSplineEditUndo, splineMgr.transMasterSplineEditRedo)
  selectedSplineIdx, selectedNodeIdx, selectedLayerIdx, isGizmoActive, isLockShape = out.spline, out.node, out.layer, out.isGizmoActive, out.isLockShape

  -- Render the spline (nodes, polyline, handles etc).
  render.handleSplineRendering(
    masterSplines, selectedSplineIdx, selectedNodeIdx,
    isGizmoActive, true, isLockShape, true, true,
    elevScale)

  -- Render the surface.
  if isSplineAnalysisEnabled then
    render.renderHomologatedSurface(masterSplines, selectedSplineIdx) -- Render a heatmap surface, to show high error spots.
  else
    render.renderRibbonWireFrame(masterSplines, selectedSplineIdx, 2)
  end

  -- Render the selected layer.
  local selLayer = selMasterSpline and selMasterSpline.layers[selectedLayerIdx]
  if selLayer and selMasterSpline.isEnabled then
    if selLayer.linkedSplineId and selLayer.linkType then
      local toolInfo = toolNavigation[selLayer.linkType]
      if toolInfo then
        local splines = toolInfo.getSplines()
        local idMap = toolInfo.getIdToIdxMap()
        local idx = idMap[selLayer.linkedSplineId]
        if idx then
          render.renderMasterLayer(selLayer, splines[idx], splines[idx].isConformToTerrain, 20)
        end
      end
    end
  end

  -- Handle the Auto Road preview (includes preview rendering).
  auto.handlePreview(selMasterSpline)
end

-- Called when the tool mode icon is pressed.
local function onActivate()
  editor.clearObjectSelection()
  editor.showWindow(toolWindowName)
  isMasterSplineEditorActive = true

  -- Recompute the master spline id -> index map.
  util.computeIdToIdxMap(splineMgr.getMasterSplines(), splineMgr.getIdToIdxMap()) -- Probably not needed here, but just in case.
end

-- Called when the tool is exited.
local function onDeactivate()
  editor.hideWindow(toolWindowName)
  isMasterSplineEditorActive = false
end

-- Editor initialisation.
local function onEditorInitialized()
  editor.editModes.masterSpline = {
    displayName = "Master Spline",
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    icon = editor.icons.group,
    iconTooltip = "MasterSpline",
    auxShortcuts = {},
    hideObjectIcons = true }
  editor.registerWindow(toolWindowName, toolWindowSize)
end

-- Called when leaving the map. We need to remove all Master Splines.
local function onClientEndMission()
  local masterSplines = splineMgr.getMasterSplines() -- Unlink all splines before removing master splines.
  for i = 1, #masterSplines do
    splineMgr.unlinkAllSplines(masterSplines[i])
  end
  splineMgr.removeAllMasterSplines()

  -- Recompute the master spline id -> index map.
  util.computeIdToIdxMap(splineMgr.getMasterSplines(), splineMgr.getIdToIdxMap())
end

-- Dependencies (ensures proper serialisation order).
M.dependencies = {
  'editor_assemblySpline',
  'editor_decalSpline',
  'editor_meshSpline',
  'editor_roadSpline',
}


-- Public interface.
M.setSelectedSplineIdx =                                setSelectedSplineIdx
M.setSelectedNodeIdx =                                  setSelectedNodeIdx

M.onSerialize =                                         onSerialize
M.onDeserialized =                                      onDeserialized

M.onEditorGui =                                         onEditorGui
M.onEditorInitialized =                                 onEditorInitialized
M.onClientEndMission =                                  onClientEndMission

return M
