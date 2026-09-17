-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local simplifyRdpTol = 9.0 -- The tolerance for the RDP simplification of the spline.
local defaultSplineWidth = 10.0 -- The default width for a spline when adding a new node, in meters.

local minDelayTime, maxDelayTime = 0.0, 60.0 -- The min/max allowable starting delay times for a drive path spline, in seconds.
local minRouteSpeed, maxRouteSpeed = 0.0, 100.0 -- The min/max allowable route speeds for a drive path spline, in meters per second.
local minAggression, maxAggression = 0.3, 1.0 -- The min/max allowable aggression for a drive path spline.
local minNumLaps, maxNumLaps = 1, 10 -- The min/max allowable number of laps for a drive path spline, when looping is used.
local elevScale = 17.0 -- The scale factor for the elevation drop lines (used for blue->red colour transition).

local flashTimeLow, flashTimeHigh = 1, 2 -- The flash phase times for the colour of the 'Optimize' button when optimising, in seconds.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}
local logTag = 'drivePathEditor'

-- External modules.
local splineMgr = require('editor/drivePathEditor/splineMgr')
local playback = require('editor/drivePathEditor/playback')
local record = require('editor/drivePathEditor/record')
local input = require('editor/toolUtilities/splineInput')
local render = require('editor/toolUtilities/render')
local skeleton = require('editor/toolUtilities/skeleton')
local rdp = require('editor/toolUtilities/rdp')
local util = require('editor/toolUtilities/util')
local style = require('editor/toolUtilities/style')

-- Register this tool with the shared spline input utilities.
input.registerSplineTool(
  splineMgr.getToolPrefixStr(),
  splineMgr.getDrivePathSplines,
  splineMgr.getEditModeKey,
  splineMgr.deepCopyDrivePathSpline,
  splineMgr.deepCopyDrivePathSplineState,
  'editor_drivePathEditor'
)

-- Module constants.
local im = ui_imgui
local min, max = math.min, math.max
local toolWinName, toolWinSize = 'drivePathEditor', im.ImVec2(300, 700)
local toolPrefixStr = splineMgr.getToolPrefixStr()
local defaultParams = splineMgr.getDefaultSliderParams()
local cols = style.getImguiCols('crystal')
local iconsSmall, iconsBig = im.ImVec2(24, 24), im.ImVec2(36, 36)

-- Module state.
local isDrivePathEditorActive = false
local isGizmoActive = false
local isRenderSplineWhenPlaying = true
local selectedSplineIdx = 1
local selectedNodeIdx = 1
local selectedVehicleIdx = 1
local sliderPreEditState = nil
local isLockShape = false
local isPlaying = false
local isRecording = false
local velocityUnitsInt = 2 -- 0 = m/s, 1 = mph, 2 = kph.
local flashTimer, flashTime = hptimer(), 0.0
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
  local drivePathSplines = splineMgr.getDrivePathSplines()
  local numSplines = #drivePathSplines
  local drivePathSplinesSer, ctr = {}, 1
  for i = 1, numSplines do
    drivePathSplinesSer[ctr] = splineMgr.serializeDrivePathSpline(drivePathSplines[i])
    ctr = ctr + 1
  end
  splineMgr.removeAllDrivePathSplines()
  return drivePathSplinesSer
end

-- Deserialise callback.
local function onDeserialized(data)
  if data and #data > 0 then
    local drivePathSplines = splineMgr.getDrivePathSplines()
    table.clear(drivePathSplines)
    for i = 1, #data do
      local spline = splineMgr.deserializeDrivePathSpline(data[i])
      drivePathSplines[#drivePathSplines + 1] = spline
    end
    selectedSplineIdx = max(1, min(#drivePathSplines, selectedSplineIdx))

    -- Update the spline map.
    util.computeIdToIdxMap(drivePathSplines, splineMgr.getSplineMap())

    -- Re-link all the vehicles to the drive path splines.
    splineMgr.getActiveVehicles(true)
    splineMgr.relinkAllVehiclesToSplines()
  end
end

-- Handles the main tool window.
local function handleMainToolWindowUI()
  if editor.beginWindow(toolWinName, "Drive Path Editor###8874", im.WindowFlags_NoCollapse) then
    local icons = editor.icons
    local drivePathSplines = splineMgr.getDrivePathSplines()
    local sceneVehicles = splineMgr.getActiveVehicles(false)
    selectedSplineIdx = max(1, min(#drivePathSplines, selectedSplineIdx)) -- Ensure the selected spline index is within bounds.

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

    -- 'Add New Drive Path Spline' button.
    if not isPlaying and not isRecording then
      if editor.uiIconImageButton(icons.bSpline, iconsBig, cols.blueB, nil, nil, 'addNewDrivePathSplineBtn') then
        local statePre = splineMgr.deepCopyDrivePathSplineState()
        splineMgr.addNewDrivePathSpline()
        selectedSplineIdx = #drivePathSplines
        editor.history:commitAction("Add New drive path spline", { old = statePre, new = splineMgr.deepCopyDrivePathSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
      end
      im.tooltip('Add a new drive path spline.')
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Import From Bitmap Mask' button.
    if not isPlaying and not isRecording then
      if editor.uiIconImageButton(icons.floppyDiskPlus, iconsBig, cols.blueB, nil, nil, 'importFromBitmapMaskBtn') then
        extensions.editor_fileDialog.openFile(
          function(data)
            if data.filepath then
              local paths = skeleton.getPathsFromPng(data.filepath)
              if #paths > 0 then
                local preState = splineMgr.deepCopyDrivePathSplineState()
                splineMgr.convertPathsToDrivePathSplines(paths)
                editor.history:commitAction("Import Drive Path Splines From Bitmap", { old = preState, new = splineMgr.deepCopyDrivePathSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
              end
            end
          end,
          {{"PNG",".png"}},
          false,
          "/")
      end
      im.tooltip('Import drive path splines from a bitmap mask.')
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Remove All Drive Path Splines' button.
    if #drivePathSplines > 0 and not isPlaying and not isRecording then
      if editor.uiIconImageButton(icons.trashBin2, iconsBig, cols.blueB, nil, nil, 'removeAllDrivePathSplinesBtn') then
        local statePre = splineMgr.deepCopyDrivePathSplineState()
        splineMgr.removeAllDrivePathSplines(false)
        selectedSplineIdx = 1
        editor.history:commitAction("Remove All drive path splines", { old = statePre, new = splineMgr.deepCopyDrivePathSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
      end
      im.tooltip('Remove all drive path splines from the session.')
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Speed/Speed Limit Toggle' button.
    local selSpline = drivePathSplines[selectedSplineIdx]
    if selSpline and selSpline.isFreeMode and #drivePathSplines > 0 and selSpline.isEnabled and not isPlaying and not isRecording then
      local speedProfileMode = selSpline.speedProfileMode or 0
      if speedProfileMode ~= 0 then
        local isBarsLimit = speedProfileMode == 2
        local btnIcon = isBarsLimit and icons.cars or icons.car
        if editor.uiIconImageButton(btnIcon, iconsBig, cols.blueB, nil, nil, 'speedLimitToggleBtn') then
          selSpline.speedProfileMode = isBarsLimit and 1 or 2
          selSpline.isDirty = true
        end
        im.tooltip(isBarsLimit and 'Switch bars to speed targets (v).' or 'Switch bars to speed limits (vl).')
      else
        if editor.uiIconImageButton(icons.car, iconsBig, cols.blueB, nil, nil, 'speedLimitToggleBtn') then
          selSpline.speedProfileMode = 1
          selSpline.isDirty = true
        end
        im.tooltip('Enable per-node speed targets (v).')
      end
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Lock Shape' toggle button.
    if #drivePathSplines > 0 and selSpline and selSpline.isEnabled and not isPlaying and not isRecording then
      local btnCol = isLockShape and cols.blueB or cols.blueD
      if editor.uiIconImageButton(icons.roadGuideArrowSolid, iconsBig, btnCol, nil, nil, 'lockShapeBtn') then
        isLockShape = not isLockShape
      end
      im.tooltip((isLockShape and 'Unlock the shape of the drive path spline to move nodes separately' or 'Lock the shape of the drive path spline to move nodes rigidly'))
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Save Session' button.
    if #drivePathSplines > 0 then
      if editor.uiIconImageButton(icons.floppyDisk, iconsBig, nil, nil, nil, 'saveSessionBtn') then
        extensions.editor_fileDialog.saveFile(
          function(data)
            if data.filepath then
              local numSplines = #drivePathSplines
              local drivePathSplinesSer, ctr = table.new(numSplines, 0), 1
              for i = 1, numSplines do
                drivePathSplinesSer[ctr] = splineMgr.serializeDrivePathSpline(drivePathSplines[i])
                ctr = ctr + 1
              end
              local serData = { splines = drivePathSplinesSer, mapName = core_levels.getLevelName(getMissionFilename()), tool = toolPrefixStr }
              jsonWriteFile(data.filepath, serData, true)
            end
          end,
          {{"JSON",".json"}},
          false,
          "/")
      end
      im.tooltip('Save the current session to disk.')
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Load Session' button.
    if editor.uiIconImageButton(icons.folder, iconsBig, nil, nil, nil, 'loadSessionBtn') then
      extensions.editor_fileDialog.openFile(
        function(data)
          if data.filepath then
            local serData = jsonReadFile(data.filepath)
            if serData.mapName ~= core_levels.getLevelName(getMissionFilename()) then
              log('E', logTag, 'The currently-loaded map does not match the map in the saved session file. Please switch to the map: ' .. serData.mapName)
              editor.endWindow()
              return
            end
            if serData.tool ~= toolPrefixStr then
              log('E', logTag, 'The currently-loaded tool does not match the tool in the saved session file. Please switch to the tool: ' .. serData.tool)
              editor.endWindow()
              return
            end
            local preState = splineMgr.deepCopyDrivePathSplineState()
            onDeserialized(serData.splines)
            editor.history:commitAction("Load Session", { old = preState, new = splineMgr.deepCopyDrivePathSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
          end
        end,
        {{"JSON",".json"}},
        false,
        "/")
    end
    im.tooltip('Load a previously-saved session from disk.')
    im.NextColumn()

    im.PopStyleVar(2)
    im.Columns(1)
    im.Separator()

    -- Drive Path Splines list.
    if #drivePathSplines > 0 then
      im.TextColored(cols.greenB, "Drive Path Splines:")
      im.PushItemWidth(-1)
      if im.BeginListBox('drivePathSplineListBox', im.ImVec2(-1, 180)) then
        im.Columns(5, "drivePathSplineListBoxColumns", true)
        im.SetColumnWidth(0, 30)
        im.SetColumnWidth(1, 180)
        im.SetColumnWidth(2, 35)
        im.SetColumnWidth(3, 35)
        im.SetColumnWidth(4, 35)
        im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(4, 2))
        im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
        local wCtr = 41225
        for i = 1, #drivePathSplines do
          local spline = drivePathSplines[i]
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
          if not spline.isEnabled then
            im.TextColored(cols.dullWhite, spline.name)
            im.tooltip('This drive path spline is disabled. To edit or remove it, first enable it.')
          else
            if im.InputText("###" .. tostring(wCtr), splineNamePtr, 32) then
              spline.name = ffi.string(splineNamePtr)
            end
            im.tooltip('Edit the drive path spline name.')
            if im.IsItemActive() then
              selectedSplineIdx = i
            end
          end
          im.PopItemWidth()
          wCtr = wCtr + 1
          im.SameLine()
          im.NextColumn()

          -- 'Remove Selected Drive Path Spline' button.
          if spline.isEnabled and not isPlaying and not isRecording then
            if editor.uiIconImageButton(icons.trashBin2, iconsSmall, cols.blueB, nil, nil, 'removeSpline') then
              local statePre = splineMgr.deepCopyDrivePathSplineState()
              splineMgr.removeDrivePathSpline(i)
              if selectedSplineIdx > i then
                selectedSplineIdx = selectedSplineIdx - 1
              end
              selectedSplineIdx = max(1, min(#drivePathSplines, selectedSplineIdx))
              editor.history:commitAction("Remove drive path spline", { old = statePre, new = splineMgr.deepCopyDrivePathSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
              editor.endWindow()
              return
            end
            im.tooltip('Remove this drive path spline from the session.')
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()
          im.NextColumn()

          -- 'Enable/Disable Drive Path Spline' button.
          if not isPlaying and not isRecording then
            local btnCol = spline.isEnabled and cols.blueB or cols.blueD
            local btnIcon = spline.isEnabled and icons.lock or icons.lock_open
            if editor.uiIconImageButton(btnIcon, iconsSmall, btnCol, nil, nil, 'lockUnlockDrivePathSplineToggleBtn') then
              local statePre = splineMgr.deepCopyDrivePathSpline(spline)
              spline.isEnabled = not spline.isEnabled
              spline.isDirty = true
              selectedSplineIdx = i
              editor.history:commitAction("Toggle drive path spline Lock", { old = statePre, new = splineMgr.deepCopyDrivePathSpline(spline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
            end
            im.tooltip((spline.isEnabled and 'Disable' or 'Enable') .. ' this drive path spline.')
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()
          im.NextColumn()

          -- 'Link/Unlink To Vehicle' button.
          if spline.isEnabled and not isPlaying and not isRecording then
            if spline.isVehicleLink then
              if editor.uiIconImageButton(icons.jointLocked, iconsSmall, cols.dullWhite, nil, nil, 'unlinkSplineToVehicleBtn') then
                local statePre = splineMgr.deepCopyDrivePathSplineState()
                splineMgr.unlinkSpline(spline, splineMgr.getVehicleById(spline.linkVehId))
                selectedSplineIdx = i
                editor.history:commitAction("Unlink Drive Path Spline", { old = statePre, new = splineMgr.deepCopyDrivePathSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
              end
              im.tooltip('Unlink this drive path spline from its vehicle.')
            else
              local vehicle = splineMgr.getVehicleById(spline.linkVehId)
              if not vehicle or not vehicle.isLink then
                if editor.uiIconImageButton(icons.jointUnlocked, iconsSmall, nil, nil, nil, 'linkSplineToVehicleBtn') then
                  local statePre = splineMgr.deepCopyDrivePathSplineState()
                  splineMgr.linkSpline(spline, sceneVehicles[selectedVehicleIdx])
                  selectedSplineIdx = i
                  editor.history:commitAction("Link Drive Path Spline", { old = statePre, new = splineMgr.deepCopyDrivePathSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
                end
                im.tooltip('Link this drive path spline to its vehicle.')
              else
                im.Dummy(iconsSmall)
              end
            end
          else
            im.Dummy(iconsSmall)
          end
          im.NextColumn()
          im.Separator()
        end
        im.PopStyleVar(2)
        im.EndListBox()
      end
      im.Columns(1)
      im.Separator()

      -- Buttons underneath the drive path splines list box.
      im.Columns(4, "buttonsUnderneathListBox", false)
      im.SetColumnWidth(0, 40)
      im.SetColumnWidth(1, 40)
      im.SetColumnWidth(2, 40)
      im.SetColumnWidth(3, 40)
      im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
      im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

      -- 'Go To Selected Spline' button.
      if (#selSpline.nodes > 1 or #selSpline.graphNodes > 1) and not isPlaying and not isRecording then
        if editor.uiIconImageButton(icons.cameraFocusTopDown, iconsBig, cols.blueB, nil, nil, 'goToSelectedSplineBtn') then
          if selSpline.isFreeMode then
            util.goToSpline(selSpline.divPoints)
          else
            local graphData = splineMgr.getNavGraph()
            if graphData then
              local nds = {}
              for i = 1, #selSpline.graphNodes do
                nds[i] = graphData.nodes[selSpline.graphNodes[i]] -- For the NavGraph mode, we need to convert the node indices to node positions first.
              end
              util.goToSpline(nds)
            end
          end
        end
        im.tooltip('Go to this drive path spline (move camera).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Flip Spline' button.
      if selSpline.isEnabled and (#selSpline.nodes > 1 or #selSpline.graphNodes > 1) and not isPlaying and not isRecording then
        if editor.uiIconImageButton(icons.sync, iconsBig, cols.blueB, nil, nil, 'flipDrivePathSplineBtn') then
          local statePre = splineMgr.deepCopyDrivePathSplineState()
          splineMgr.flipSpline(selSpline)
          editor.history:commitAction("Flip Drive Path Spline", { old = statePre, new = splineMgr.deepCopyDrivePathSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
        end
        im.tooltip('Flip the selected drive path spline back to front.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Split drive path spline' button.
      if selSpline.isFreeMode and selSpline.isEnabled and selSpline.nodes[selectedNodeIdx] and #selSpline.nodes > 2 and (selSpline.isLoop or (selectedNodeIdx > 1 and selectedNodeIdx < #selSpline.nodes)) and not isPlaying and not isRecording then
        if editor.uiIconImageButton(icons.content_cut, iconsBig, cols.blueB, nil, nil, 'splitDrivePathSplineBtn') then
          local statePre = splineMgr.deepCopyDrivePathSplineState()
          splineMgr.splitDrivePathSpline(selectedSplineIdx, selectedNodeIdx)
          selectedSplineIdx = #drivePathSplines
          editor.history:commitAction("Split New drive path spline", { old = statePre, new = splineMgr.deepCopyDrivePathSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
        end
        im.tooltip('Splits the selected drive path spline into two, at the selected node.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Simplify Spline' button.
      if selSpline and selSpline.isEnabled and not selSpline.isLink and selSpline.nodes[selectedNodeIdx] and #selSpline.nodes > 2 and not isPlaying and not isRecording then
        if editor.uiIconImageButton(icons.routeSimple, iconsBig, cols.blueB, nil, nil, 'simplifySplineBtn') then
          local statePre = splineMgr.deepCopyDrivePathSpline(selSpline)
          rdp.simplifyNodesWidthsNormals(selSpline.nodes, selSpline.widths, selSpline.nmls, simplifyRdpTol)
          selectedNodeIdx = max(1, min(#selSpline.nodes, selectedNodeIdx))
          selSpline.isDirty = true
          editor.history:commitAction("Simplify Drive Path Spline", { old = statePre, new = splineMgr.deepCopyDrivePathSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip('Simplifies the selected drive path spline (reduces the number of nodes).')
      else
        im.Dummy(iconsBig)
      end
      im.NextColumn()
      im.PopStyleVar(2)

      im.Columns(1)
      im.Separator()

      if not isPlaying and not isRecording then
        if selSpline.isVehicleLink then
          local vehicle = splineMgr.getVehicleById(selSpline.linkVehId)
          if vehicle then
            im.Text(string.format('Linked To Vehicle: [%s]', vehicle.name))
          else
            selSpline.isVehicleLink = false -- Previously-linked vehicle no longer exists, so unlink the spline.
            selSpline.linkVehId = nil
          end
        else
          im.Text('Not Linked: [select a vehicle then click link icon]')
        end
      else
        im.Text('')
      end
      im.Separator()
    end

    -- Active Vehicles list.
    if #sceneVehicles > 0 then
      im.TextColored(cols.greenB, "Scene Vehicles:")
      im.PushItemWidth(-1)
      if im.BeginListBox('vehicleListBox', im.ImVec2(-1, 180)) then
        im.Columns(5, "vehicleListBoxColumns", true)
        im.SetColumnWidth(0, 30)
        im.SetColumnWidth(1, 180)
        im.SetColumnWidth(2, 35)
        im.SetColumnWidth(3, 35)
        im.SetColumnWidth(4, 35)
        im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(4, 2))
        im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
        local wCtr = 823671
        for i = 1, #sceneVehicles do
          local vehicle = sceneVehicles[i]
          local flag = i == selectedVehicleIdx
          if im.Selectable1("###" .. tostring(wCtr), flag, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
            selectedVehicleIdx = i
          end
          wCtr = wCtr + 1
          im.SameLine()
          im.NextColumn()

          im.PushItemWidth(180)
          im.Text(vehicle.name)
          im.tooltip('Select this vehicle.')
          if im.IsItemActive() then
            selectedVehicleIdx = i
          end
          im.PopItemWidth()
          im.SameLine()
          im.NextColumn()

          -- 'Remove Vehicle' button.
          if not isPlaying and not isRecording then
            if editor.uiIconImageButton(icons.trashBin2, iconsSmall, cols.blueB, nil, nil, 'removeVehicle') then
              if vehicle.veh then
                vehicle.veh:delete()
                table.remove(sceneVehicles, i)
                selectedVehicleIdx = max(1, min(#sceneVehicles, selectedVehicleIdx))
                editor.endWindow()
                return
              end
            end
            im.tooltip('Remove this vehicle from the session.')
          else
            im.Dummy(iconsSmall)
          end
          im.NextColumn()

          -- 'Go To Vehicle' button.
          if not isPlaying and not isRecording then
            if editor.uiIconImageButton(icons.cameraFocusOnVehicle2, iconsSmall, cols.blueB, nil, nil, 'goToVehicleBtn') then
              core_camera.setByName(0, "orbit", false)
              be:enterVehicle(0, vehicle.veh)
              selectedVehicleIdx = i
            end
            im.tooltip('Go to this vehicle (move camera).')
          else
            im.Dummy(iconsSmall)
          end
          im.NextColumn()

          -- 'Link/Unlink Vehicle' button.
          local splines = splineMgr.getDrivePathSplines()
          if not isPlaying and not isRecording then
            if vehicle.isLink then
              if editor.uiIconImageButton(icons.jointLocked, iconsSmall, cols.dullWhite, nil, nil, 'unlinkVehicleBtn') then
                local preState = splineMgr.deepCopyDrivePathSplineState()
                splineMgr.unlinkSpline(splines[splineMgr.getSplineMap()[vehicle.linkSplineId]], vehicle)
                selectedVehicleIdx = i
                editor.history:commitAction("Unlink Vehicle", { old = preState, new = splineMgr.deepCopyDrivePathSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
              end
              im.tooltip('Unlink this vehicle from its drive path spline.')
            else
              local linkedSpline = splines[selectedSplineIdx]
              if linkedSpline and not linkedSpline.isVehicleLink then
                if editor.uiIconImageButton(icons.jointUnlocked, iconsSmall, nil, nil, nil, 'linkVehicleBtn') then
                  local preState = splineMgr.deepCopyDrivePathSplineState()
                  splineMgr.linkSpline(splines[selectedSplineIdx], vehicle)
                  selectedVehicleIdx = i
                  editor.history:commitAction("Link Vehicle", { old = preState, new = splineMgr.deepCopyDrivePathSplineState() }, splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo, true)
                end
                im.tooltip('Link this vehicle to the selected drive path spline.')
              else
                im.Dummy(iconsSmall)
              end
            end
          else
            im.Dummy(iconsSmall)
          end
          im.NextColumn()
          im.Separator()
        end
        im.PopStyleVar(2)
        im.EndListBox()
      end
      im.Columns(1)
      im.Separator()

      -- Buttons underneath the scene vehicles list box.
      im.Columns(4, "btnsUnderVehListRow", false)
      im.SetColumnWidth(0, 39)
      im.SetColumnWidth(1, 39)
      im.SetColumnWidth(2, 39)
      im.SetColumnWidth(3, 39)
      im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
      im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

      -- 'Refresh Scene Vehicles List' button.
      if not isPlaying and not isRecording then
        if editor.uiIconImageButton(icons.refresh, iconsBig, cols.blueB, nil, nil, 'refreshSceneVehiclesListBtn') then
          sceneVehicles = splineMgr.getActiveVehicles(true)
        end
        im.tooltip('Refresh the scene vehicles list.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Render Spline When Playing' button.
      if not isRecording then
        local btnIcon = isRenderSplineWhenPlaying and icons.visibility or icons.visibility_off
        local btnCol = isRenderSplineWhenPlaying and cols.blueB or cols.blueD
        if editor.uiIconImageButton(btnIcon, iconsBig, btnCol, nil, nil, 'renderSplineWhenPlayingBtn') then
          isRenderSplineWhenPlaying = not isRenderSplineWhenPlaying
        end
        im.tooltip(isRenderSplineWhenPlaying and 'Hide the splines when playing.' or 'Show the spline when playing.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Master Play/Stop' button.
      if #drivePathSplines > 0 and #sceneVehicles > 0 and not isRecording then
        local btnIcon = isPlaying and icons.stop or icons.play_arrow
        local btnCol = cols.blueB
        if isPlaying then
          if flashTime > flashTimeHigh then
            flashTime = 0
          elseif flashTime > flashTimeLow then
            btnCol = cols.redB
          else
            btnCol = nil
          end
          flashTime = max(-1.0, flashTime + flashTimer:stopAndReset() * 0.001)
        end
        if editor.uiIconImageButton(btnIcon, iconsBig, btnCol, nil, nil, 'playStopToggleBtn') then
          isPlaying = not isPlaying
          if isPlaying then
            playback.startPlayback(drivePathSplines, sceneVehicles)
          else
            playback.stopPlayback()
          end
        end
        im.tooltip(isPlaying and 'Click to stop playback.' or 'Click to start playback (all linked vehicles in session).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Record Vehicle' button.
      if #sceneVehicles > 0 and sceneVehicles[selectedVehicleIdx] and not sceneVehicles[selectedVehicleIdx].isLink then
        local btnIcon = isRecording and icons.stop or icons.play_arrow
        local btnCol = cols.redB
        if isRecording then
          if flashTime > flashTimeHigh then
            flashTime = 0
          elseif flashTime > flashTimeLow then
            btnCol = cols.redB
          else
            btnCol = nil
          end
          flashTime = max(-1.0, flashTime + flashTimer:stopAndReset() * 0.001)
        end
        if editor.uiIconImageButton(btnIcon, iconsBig, btnCol, nil, nil, 'recordBtn') then
          isRecording = not isRecording
          if isRecording then
            record.startRecord(sceneVehicles[selectedVehicleIdx])
            playback.startPlayback(drivePathSplines, sceneVehicles)
            isPlaying = true
          else
            record.stopRecord(sceneVehicles)
            playback.stopPlayback()
            isPlaying = false
            selectedSplineIdx = #drivePathSplines
          end
        end
        im.tooltip(isRecording and 'Click to stop recording.' or 'Click to start recording (selected vehicle).')
      else
        im.Dummy(iconsBig)
      end
      im.NextColumn()
      im.PopStyleVar(2)
      im.Columns(1)
      im.Separator()

      -- Show the selected vehicle's linked spline.
      local selVehicle = sceneVehicles[selectedVehicleIdx]
      local splines, splineMap = splineMgr.getDrivePathSplines(), splineMgr.getSplineMap()
      local linkedSpline = splines[splineMap[selVehicle.linkSplineId]]
      if not isPlaying and not isRecording then
        if linkedSpline and selVehicle and selVehicle.isLink then
          im.TextColored(cols.redB, 'Linked To Drive Path Spline: ')
          im.SameLine()
          im.Text(string.format('[%s]', linkedSpline.name))
        else
          im.TextColored(cols.redB, 'Not Linked: ')
          im.SameLine()
          im.Text('[select a drive path spline then click link icon]')
        end
      elseif isRecording then
        im.TextColored(cols.redB, 'Recording In Progress... ')
        im.SameLine()
        im.Text(string.format('[time: %.2fs]', record.getRecordingTime()))
      elseif isPlaying then
        im.TextColored(cols.redB, 'Playback In Progress... ')
        im.SameLine()
        im.Text(string.format('[time: %.2fs]', playback.getPlaybackTime()))
      else
        im.Text('')
      end
      im.Dummy(im.ImVec2(0, 3))
      im.Separator()
    end

    if isPlaying or isRecording then
      editor.endWindow()
      return -- If we're playing, don't show anything further.
    end

    -- Velocity Units (m/s, mph, kph).
    if #drivePathSplines > 0 then
      im.TextColored(cols.greenB, "Velocity Units:")
      local tmpPtr = im.IntPtr(0)
      if velocityUnitsInt == 1 then
        tmpPtr = im.IntPtr(1)
      elseif velocityUnitsInt == 2 then
        tmpPtr = im.IntPtr(2)
      end
      im.Columns(3, "velocityUnits", false)
      if im.RadioButton2("m/s", tmpPtr, 0) then
        velocityUnitsInt = 0
      end
      im.tooltip('m/s.')
      im.SameLine()
      im.NextColumn()
      if im.RadioButton2("mph", tmpPtr, 1) then
        velocityUnitsInt = 1
      end
      im.tooltip('mph.')
      im.SameLine()
      im.NextColumn()
      if im.RadioButton2("kph", tmpPtr, 2) then
        velocityUnitsInt = 2
      end
      im.tooltip('kph.')
      im.NextColumn()
      im.Columns(1)
      im.Dummy(im.ImVec2(0, 3))
      im.Separator()
    end

    -- If the selected spline is disabled, don't show anything further.
    if not selSpline or not selSpline.isEnabled then
      editor.endWindow()
      return
    end

    im.Columns(1)
    im.TextColored(cols.greenB, "Trajectory Type:")

    -- Trajectory type (wpTargetList or script).
    local tmpPtr = im.IntPtr(0)
    if selSpline.isFreeMode then
      tmpPtr = im.IntPtr(1)
    end
    im.Columns(2, "Trajectory Type", false)
    if im.RadioButton2("NavGraph Mode", tmpPtr, 0) then
      splineMgr.resetGeometry(selSpline)
      selSpline.isFreeMode = false
      if (selSpline.speedProfileMode or 0) == 2 then
        selSpline.speedProfileMode = 1
      end
    end
    im.tooltip('wpTargetList: follow shortest paths between consecutive navgraph nodes.')
    im.SameLine()
    im.NextColumn()
    if im.RadioButton2("Free Mode", tmpPtr, 1) then
      splineMgr.resetGeometry(selSpline)
      selSpline.isFreeMode = true
    end
    im.tooltip('script: explicit world-space trajectory.')
    im.NextColumn()
    im.Columns(1)

    -- Properties checkboxes and sliders.
    im.Dummy(im.ImVec2(0, 3))
    im.Separator()
    im.TextColored(cols.greenB, "Properties:")

    -- Speed Profile.
    im.TextColored(cols.greenB, "Speed Profile:")
    local spPtr = im.IntPtr(selSpline.speedProfileMode or 0)
    im.Columns(3, "Speed Profile Mode", false)
    if im.RadioButton2("Off", spPtr, 0) then
      selSpline.speedProfileMode = 0
      selSpline.isDirty = true
    end
    im.tooltip('Do not send per-node speeds/limits to ai.driveUsingPath.')
    im.SameLine()
    im.NextColumn()
    if im.RadioButton2("Speed (v)", spPtr, 1) then
      selSpline.speedProfileMode = 1
      selSpline.isDirty = true
    end
    im.tooltip('Per-node speed targets (v).')
    im.SameLine()
    im.NextColumn()
    im.BeginDisabled(not selSpline.isFreeMode)
    if im.RadioButton2("Limit (vl)", spPtr, 2) then
      selSpline.speedProfileMode = 2
      selSpline.isDirty = true
    end
    im.EndDisabled()
    im.tooltip(selSpline.isFreeMode and 'Per-edge speed limits (vl). Uses vl only (no v).' or 'Speed limits (vl) are only supported for script trajectories.')
    im.NextColumn()
    im.Columns(1)
    im.Dummy(im.ImVec2(0, 3))
    im.Separator()

    -- Route Speed Mode.
    im.TextColored(cols.greenB, "Route Speed Mode:")
    local rsm = selSpline.routeSpeedMode or 'off'
    local rsmInt = 0
    if rsm == 'set' then
      rsmInt = 1
    elseif rsm == 'limit' then
      rsmInt = 2
    elseif rsm == 'legal' then
      rsmInt = 3
    end
    local rsmPtr = im.IntPtr(rsmInt)
    if im.RadioButton2("Off###routeSpeedModeOff", rsmPtr, 0) then
      selSpline.routeSpeedMode = 'off'
      selSpline.isDirty = true
    end
    im.tooltip('Do not send routeSpeed/routeSpeedMode to ai.driveUsingPath.')
    im.SameLine()
    if im.RadioButton2("Set###routeSpeedModeSet", rsmPtr, 1) then
      selSpline.routeSpeedMode = 'set'
      selSpline.isDirty = true
    end
    im.tooltip('Try to hit routeSpeed exactly.')
    im.SameLine()
    if im.RadioButton2("Limit###routeSpeedModeLimit", rsmPtr, 2) then
      selSpline.routeSpeedMode = 'limit'
      selSpline.isDirty = true
    end
    im.tooltip('Do not exceed routeSpeed.')
    im.SameLine()
    if im.RadioButton2("Legal###routeSpeedModeLegal", rsmPtr, 3) then
      selSpline.routeSpeedMode = 'legal'
      selSpline.isDirty = true
    end
    im.tooltip('Stay below roadSpeedLimit (and/or vl upper bounds) with aggression.')
    im.Columns(1)

    -- Sliders.
    im.Columns(1)
    im.PushItemWidth(-1)
    im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
    im.Columns(2, 'splinePropertiesCols', false)
    im.SetColumnWidth(0, 30)

    -- 'Delay Time' slider.
    if selSpline.delayTime ~= defaultParams.delayTime then
      if editor.uiIconImageButton(icons.star_border, iconsSmall, cols.blueB, nil, nil, 'resetDelayTimeBtn') then
        local preEditState = splineMgr.deepCopyDrivePathSpline(selSpline)
        selSpline.delayTime = defaultParams.delayTime
        selSpline.isDirty = true
        editor.history:commitAction("Reset Delay Time", { old = preEditState, new = splineMgr.deepCopyDrivePathSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.tooltip("Reset to default")
    else
      im.Dummy(iconsSmall)
    end
    im.SameLine()
    im.NextColumn()
    im.PushItemWidth(-1)
    tmpPtr = im.FloatPtr(selSpline.delayTime)
    if im.SliderFloat('###5756', tmpPtr, minDelayTime, maxDelayTime, "Delay Time (s) = %.2f") then
      selSpline.delayTime = tmpPtr[0]
      selSpline.isDirty = true
    end
    im.tooltip('Set the starting delay time for the selected spline, in seconds.')
    if im.IsItemActivated() then
      sliderPreEditState = splineMgr.deepCopyDrivePathSpline(selSpline)
    end
    if im.IsItemDeactivatedAfterEdit() then
      editor.history:commitAction("Adjust Delay Time", { old = sliderPreEditState, new = splineMgr.deepCopyDrivePathSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
    end
    im.PopItemWidth()
    im.NextColumn()

    -- 'Starting Node' slider.
    if #selSpline.nodes > 1 then
      if selSpline.startingNode ~= defaultParams.startingNode then
        if editor.uiIconImageButton(icons.star_border, iconsSmall, cols.blueB, nil, nil, 'resetStartingNodeBtn') then
          local preEditState = splineMgr.deepCopyDrivePathSpline(selSpline)
          selSpline.startingNode = defaultParams.startingNode
          selSpline.isDirty = true
          editor.history:commitAction("Reset Starting Node", { old = preEditState, new = splineMgr.deepCopyDrivePathSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      tmpPtr = im.IntPtr(selSpline.startingNode)
      if im.SliderInt('###97756', tmpPtr, 1, #selSpline.nodes, "Starting Node = %d") then
        selSpline.startingNode = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the starting node for the selected spline.')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyDrivePathSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Starting Node", { old = sliderPreEditState, new = splineMgr.deepCopyDrivePathSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()
    end

    -- 'Route Speed' slider.
    if (selSpline.routeSpeedMode or 'off') ~= 'off' then
      if selSpline.routeSpeed ~= defaultParams.routeSpeed then
        if editor.uiIconImageButton(icons.star_border, iconsSmall, cols.blueB, nil, nil, 'resetRouteSpeedBtn') then
          local preEditState = splineMgr.deepCopyDrivePathSpline(selSpline)
          selSpline.routeSpeed = defaultParams.routeSpeed
          selSpline.isDirty = true
          editor.history:commitAction("Reset Route Speed", { old = preEditState, new = splineMgr.deepCopyDrivePathSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      tmpPtr = im.FloatPtr(selSpline.routeSpeed)
      if im.SliderFloat('###5316', tmpPtr, minRouteSpeed, maxRouteSpeed, "Route Speed (m/s) = %.2f") then
        selSpline.routeSpeed = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the route speed of the drive path spline, in meters per second.')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyDrivePathSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Route Speed", { old = sliderPreEditState, new = splineMgr.deepCopyDrivePathSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()
    else
      im.Dummy(iconsSmall)
      im.NextColumn()
      im.Dummy(iconsSmall)
      im.NextColumn()
    end

    -- 'Aggression' slider.
    if selSpline.aggression ~= defaultParams.aggression then
      if editor.uiIconImageButton(icons.star_border, iconsSmall, cols.blueB, nil, nil, 'resetAggressionBtn') then
        local preEditState = splineMgr.deepCopyDrivePathSpline(selSpline)
        selSpline.aggression = defaultParams.aggression
        selSpline.isDirty = true
        editor.history:commitAction("Reset Aggression", { old = preEditState, new = splineMgr.deepCopyDrivePathSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.tooltip("Reset to default")
    else
      im.Dummy(iconsSmall)
    end
    im.SameLine()
    im.NextColumn()
    im.PushItemWidth(-1)
    tmpPtr = im.FloatPtr(selSpline.aggression)
    if im.SliderFloat('###5757', tmpPtr, minAggression, maxAggression, "Aggression = %.3f") then
      selSpline.aggression = tmpPtr[0]
      selSpline.isDirty = true
    end
    im.tooltip('Set the amount of aggression for the drive path spline.')
    if im.IsItemActivated() then
      sliderPreEditState = splineMgr.deepCopyDrivePathSpline(selSpline)
    end
    if im.IsItemDeactivatedAfterEdit() then
      editor.history:commitAction("Adjust Aggression", { old = sliderPreEditState, new = splineMgr.deepCopyDrivePathSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
    end
    im.PopItemWidth()
    im.NextColumn()

    -- 'Number Of Laps' slider.
    if selSpline.isLoop then
      if selSpline.numLaps ~= defaultParams.numLaps then
        if editor.uiIconImageButton(icons.star_border, iconsSmall, cols.blueB, nil, nil, 'resetNumLapsBtn') then
          local preEditState = splineMgr.deepCopyDrivePathSpline(selSpline)
          selSpline.numLaps = defaultParams.numLaps
          selSpline.isDirty = true
          editor.history:commitAction("Reset Num Laps", { old = preEditState, new = splineMgr.deepCopyDrivePathSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
        end
        im.tooltip("Reset to default")
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()
      im.PushItemWidth(-1)
      tmpPtr = im.IntPtr(selSpline.numLaps)
      if im.SliderInt('###5759', tmpPtr, minNumLaps, maxNumLaps, "Num Laps = %d") then
        selSpline.numLaps = tmpPtr[0]
        selSpline.isDirty = true
      end
      im.tooltip('Set the number of laps for the drive path spline.')
      if im.IsItemActivated() then
        sliderPreEditState = splineMgr.deepCopyDrivePathSpline(selSpline)
      end
      if im.IsItemDeactivatedAfterEdit() then
        editor.history:commitAction("Adjust Num Laps", { old = sliderPreEditState, new = splineMgr.deepCopyDrivePathSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
      end
      im.PopItemWidth()
      im.NextColumn()
    end

    -- Laps warning for wpTargetList.
    if selSpline.isLoop and (selSpline.numLaps or 1) > 1 and not selSpline.isFreeMode then
      local graphNodes = selSpline.graphNodes
      if graphNodes and #graphNodes > 1 then
        local startIdx = selSpline.startingNode or 1
        startIdx = max(1, min(#graphNodes, startIdx))
        if graphNodes[#graphNodes] ~= graphNodes[startIdx] then
          im.TextColored(cols.redB, 'Warning: For laps, the last wpTargetList node must match the starting node.')
        end
      end
    end

    im.Columns(1)
    im.Columns(2, "drivePathSplineCheckboxes", false)

    -- 'Drive In Lane' checkbox (wpTargetList only).
    im.BeginDisabled(selSpline.isFreeMode)
    tmpPtr = im.BoolPtr(selSpline.isDriveInLane)
    if im.Checkbox("Drive In Lane", tmpPtr) then
      selSpline.isDriveInLane = tmpPtr[0]
      local statePre = splineMgr.deepCopyDrivePathSpline(selSpline)
      selSpline.isDirty = true
      editor.history:commitAction("Toggle Drive In Lane", { old = statePre, new = splineMgr.deepCopyDrivePathSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
    end
    im.EndDisabled()
    im.tooltip(selSpline.isFreeMode and 'driveInLane only applies to wpTargetList.' or 'Sets the driveInLane flag for wpTargetList pathfinding.')
    im.SameLine()
    im.NextColumn()

    -- 'Avoid Cars' checkbox.
    tmpPtr = im.BoolPtr(selSpline.isAvoidCars)
    if im.Checkbox("Avoid Cars", tmpPtr) then
      selSpline.isAvoidCars = tmpPtr[0]
      local statePre = splineMgr.deepCopyDrivePathSpline(selSpline)
      selSpline.isDirty = true
      editor.history:commitAction("Toggle Avoid Cars", { old = statePre, new = splineMgr.deepCopyDrivePathSpline(selSpline) }, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, true)
    end
    im.tooltip('Sets the avoidCars flag for the drive path spline.')
    im.NextColumn()

    im.PopStyleVar()
    im.Columns(1)
    im.Dummy(im.ImVec2(0, 3))
    im.Separator()
  end
  editor.endWindow()
end

-- World editor main callback.
local function onEditorGui()
  -- Ensure all drive path splines are updated, even if this tool is not active.
  -- [This ensures any linked drive path splines are also updated.]
  splineMgr.updateDirtyDrivePathSplines()

  -- If this tool is not active, render the shells of the splines but do nothing further.
  if not isDrivePathEditorActive then
    render.renderShells(splineMgr.getDrivePathSplines())
    return
  end

  -- Handle the main tool window UI.
  handleMainToolWindowUI()

  -- Handle the ongoing playback events, if active.
  if isPlaying then
    playback.handlePlayback()
    if isRenderSplineWhenPlaying then
      render.renderWireframeRibbons(splineMgr.getDrivePathSplines()) -- Render just the wireframe ribbons.
    end
  end

  -- Handle the ongoing recording events, if active.
  if isRecording then
    record.handleRecord()
  end

  if isPlaying or isRecording then
    return -- Don't render anything further if we are playing or recording.
  end

  -- Render the front end depending on the mode.
  local splines = splineMgr.getDrivePathSplines()
  local selSpline = splines[selectedSplineIdx]
  if not selSpline or selSpline.isFreeMode then -- ** FREE MODE FRONT END: **
    -- Handle the mouse and keyboard events.
    out.spline, out.node, out.isGizmoActive, out.isLockShape = selectedSplineIdx, selectedNodeIdx, isGizmoActive, isLockShape
    local speedProfileMode = selSpline and (selSpline.speedProfileMode or 0) or 0
    local useBars = speedProfileMode ~= 0
    local isBarsLimit = speedProfileMode == 2
    input.handleSplineEvents(
      splines,
      out,
      false, true, true, useBars, isBarsLimit, false, true, isLockShape,
      defaultSplineWidth,
      splineMgr.deepCopyDrivePathSpline, splineMgr.deepCopyDrivePathSplineState,
      nil, nil,
      nil,
      splineMgr.joinDrivePathSplines,
      splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo,
      splineMgr.transSplineEditUndo, splineMgr.transSplineEditRedo)
    selectedSplineIdx, selectedNodeIdx, isGizmoActive, isLockShape = out.spline, out.node, out.isGizmoActive, out.isLockShape

    -- Render the drive path spline.
    render.handleSplineRendering(splines, selectedSplineIdx, selectedNodeIdx, isGizmoActive, false, isLockShape, false, true, elevScale)
    if selSpline and selSpline.isEnabled then
      if useBars then
        render.renderVelocities(selSpline, isBarsLimit, velocityUnitsInt, elevScale)
      end
      render.renderRibbonWireFrame(splines, selectedSplineIdx) -- Render the colored wireframe surface.
      local nodes = selSpline.nodes
      if #nodes > 0 then
        render.markupStart(nodes[1])
        if not selSpline.isLoop and #nodes > 1 then
          render.markupEnd(nodes[#nodes])
        end
      end
    end
  else -- ** NAVGRAPH MODE FRONT END: **
    -- Attempt to get the nav graph data.
    local graphData = splineMgr.getNavGraph()
    if not graphData then
      return -- There is no nav graph data, so leave without doing anything further.
    end

    -- Handle the mouse and keyboard events.
    local speedProfileMode = selSpline.speedProfileMode or 0
    local useBars = speedProfileMode == 1
    input.handleNavGraphEvents(selSpline, graphData.nodes, splineMgr.deepCopyDrivePathSpline, splineMgr.singleSplineEditUndo, splineMgr.singleSplineEditRedo, false, useBars)

    -- Render the path along with the nav graph.
    render.renderNavGraph(graphData)
    render.renderGraphPath(selSpline.graphPath, graphData)

    -- Render the spline using the computed navgraph path geometry.
    if selSpline.divPoints and #selSpline.divPoints > 1 then
      render.renderDrivePathSurface(selSpline)
      if useBars then
        render.renderVelocities(selSpline, false, velocityUnitsInt, elevScale)
      end
    end

    if useBars then
      render.drawBarPoints(selSpline.barPoints, elevScale)
    end
    render.renderChosenNodes(selSpline.graphNodes, graphData)
    if useBars then
      render.renderVelocitiesGraph(selSpline, velocityUnitsInt, elevScale, false)
    end
  end
end

-- Called when the tool mode icon is pressed.
local function onActivate()
  editor.clearObjectSelection()
  editor.showWindow(toolWinName)
  isDrivePathEditorActive = true

  -- Disable the AI for all vehicles.
  for _, veh in activeVehiclesIterator() do
    veh:queueLuaCommand('ai.setState({mode = "stop"})')
  end
end

-- Called when the tool is exited.
local function onDeactivate()
  editor.hideWindow(toolWinName)
  isDrivePathEditorActive = false
end

-- Called upon world editor initialization.
local function onEditorInitialized()
  editor.editModes.drivePathSplineEditMode = {
    displayName = "Drive Path Spline",
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    icon = editor.icons.fg_traffic_cone,
    iconTooltip = "Drive Path Editor",
    auxShortcuts = {},
    hideObjectIcons = true }
  editor.registerWindow(toolWinName, toolWinSize)
end

-- Called once when leaving the map. We need to remove all drive path splines.
local function onClientEndMission()
  splineMgr.removeAllDrivePathSplines(true) -- We remove all drive path splines (even disabled), so we don't have to worry about bad TSStatic pointers post-load.
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
