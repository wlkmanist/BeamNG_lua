-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local simplifyRdpTol = 9.0 -- The tolerance for the RDP simplification of the spline.

local defaultSplineWidth = 10.0 -- The default width for a spline when adding a new node, in meters.
local layerBinSpacing = 10 -- The spacing between the lateral binormal lines for the layer wire-frame (in render visualisation).

local latMin, latMax = -5.0, 5.0 -- The minimum and maximum values for the lateral position slider.
local fadeMin, fadeMax = 0.0, 100.0 -- The minimum and maximum values for the fade slider.

local elevScale = 100.0 -- The scale factor for the elevation drop lines (used for blue->red colour transition).

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- External modules.
local groupMgr = require('editor/roadSpline/groupMgr')
local layerMgr = require('editor/roadSpline/layerMgr')
local import = require('editor/roadSpline/import')
local input = require('editor/toolUtilities/splineInput')
local materialSelectionMgr = require('editor/toolUtilities/materialSelectionMgr')
local render = require('editor/toolUtilities/render')
local poly = require('editor/toolUtilities/polygon')
local skeleton = require('editor/toolUtilities/skeleton')
local rdp = require('editor/toolUtilities/rdp')
local maskExport = require('editor/toolUtilities/splineMaskExport')
local util = require('editor/toolUtilities/util')
local geom = require('editor/toolUtilities/geom')
local style = require('editor/toolUtilities/style')
local paint = require('editor/toolUtilities/terrainPainter')

-- Module constants.
local im = ui_imgui
local min, max = math.min, math.max
local toolWindowName, toolWindowSize = "roadSplineEditor", im.ImVec2(200, 400)
local sliderDefaults = layerMgr.getSliderDefaults()
local iconsSmall, iconsBig = im.ImVec2(24, 24), im.ImVec2(36, 36)
local cols = style.getImguiCols('crystal')

-- Module state.
local isRoadSplineActive = false
local isDrawPolygon = false
local selectedGroupIdx, selectedNodeIdx, selectedLayerId = 1, 1, nil
local isGizmoActive = false
local isLockShape = false
local previousSelectedGroupIdx = -1
local sliderPreEditState = nil
local out = {
  spline = selectedGroupIdx,
  node = selectedNodeIdx,
  layer = selectedLayerId,
  isGizmoActive = isGizmoActive,
}

-- Register this tool with the shared spline input utilities.
input.registerSplineTool(
  groupMgr.getToolPrefixStr(),
  groupMgr.getGroups,
  groupMgr.getEditModeKey,
  groupMgr.deepCopyGroup,
  groupMgr.deepCopyAllGroups,
  'editor_roadSpline'
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
  return serializedGroups
end

-- Deserialisation callback.
local function onDeserialized(data)
  local groups = groupMgr.getGroups()
  table.clear(groups)
  for i = 1, #data do
    local group = groupMgr.deserializeGroup(data[i], true)
    groups[#groups + 1] = group
  end
  util.computeIdToIdxMap(groups, groupMgr.getIdToIdxMap()) -- Recompute the group id -> index map.
end

-- Main tool window UI.
local function handleMainToolWindowUI()
  if editor.beginWindow(toolWindowName, "Road Spline", im.WindowFlags_NoCollapse) then
    local icons = editor.icons
    local groups = groupMgr.getGroups()

    im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
    im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

    -- 'Add New Road Spline' button.
    if editor.uiIconImageButton(icons.roadStackPlus, iconsBig, cols.blueB, nil, nil, 'addNewRoadSplineBtn') then
      local oldState = groupMgr.deepCopyAllGroups()
      groupMgr.addNewGroup()
      local newState = groupMgr.deepCopyAllGroups()
      editor.history:commitAction("Add New Road Spline", { old = oldState, new = newState }, groupMgr.transGroupEditUndo, groupMgr.transGroupEditRedo, true)
      selectedGroupIdx = #groups
    end
    im.tooltip('Add a new road spline.')
    im.SameLine()

    -- 'Import From Bitmap Mask' button.
    if editor.uiIconImageButton(icons.floppyDiskPlus, iconsBig, cols.blueB, nil, nil, 'importFromBitmapMaskBtn') then
      extensions.editor_fileDialog.openFile(
        function(data)
          if data.filepath then
            local paths = skeleton.getPathsFromPng(data.filepath)
            if #paths > 0 then
              local preState = groupMgr.deepCopyAllGroups()
              groupMgr.convertPathsToRoadSplines(paths)
              editor.history:commitAction("Import Road Splines From Bitmap", { old = preState, new = groupMgr.deepCopyAllGroups() }, groupMgr.transGroupEditUndo, groupMgr.transGroupEditRedo, true)
            end
          end
        end,
        {{"PNG",".png"}},
        false,
        "/")
    end
    im.tooltip('Import road splines from a bitmap mask.')
    im.SameLine()

    -- 'Draw A Selection Polygon' button.
    local btnCol = isDrawPolygon and cols.blueB or cols.blueD
    if editor.uiIconImageButton(icons.rounded_corner, iconsBig, btnCol, nil, nil, 'drawPolygonBtn') then
      isDrawPolygon = not isDrawPolygon
      poly.clearPolygon() -- Ensure there is no residual polygon left over from the previous usage.
    end
    im.tooltip(isDrawPolygon and 'Click to stop drawing a selection polygon.' or 'Click to draw a selection polygon, to convert scene objects to a Road Spline.')
    im.SameLine()

    -- 'Remove All Splines' button.
    if #groups > 0 then
      if editor.uiIconImageButton(icons.trashBin2, iconsBig, cols.blueB, nil, nil, 'removeAllSplinesBtn') then
        local statePre = groupMgr.deepCopyAllGroups()
        groupMgr.removeAllGroups()
        editor.history:commitAction("Remove All Road Splines", { old = statePre, new = groupMgr.deepCopyAllGroups() }, groupMgr.transGroupEditUndo, groupMgr.transGroupEditRedo, true)
        selectedGroupIdx = 1
      end
      im.tooltip('Remove all road splines from the session.')
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
      im.tooltip((isLockShape and 'Unlock the shape of the road spline to move nodes separately' or 'Lock the shape of the road spline to move nodes rigidly'))
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()

    -- 'Export Spline Mask' button.
    if #groups > 0 then
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
      im.tooltip('Export the session as a .PNG mask file. Will not include any disabled Road Splines.')
    else
      im.Dummy(iconsBig)
    end

    im.PopStyleVar(2)
    im.Columns(1)
    im.Separator()

    -- Road splines list.
    if #groups > 0 then
      im.TextColored(cols.greenB, "Road Splines:")
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

          -- 'Road Spline Name' input field.
          im.PushItemWidth(180)
          local splineNamePtr = im.ArrayChar(32, group.name)
          if group.isLink then
            im.TextColored(cols.dullWhite, group.name)
            im.tooltip('This road spline is linked to a Master Spline. To edit or remove it, first unlink it from within the Master Spline Editor.')
          elseif not group.isEnabled then
            im.TextColored(cols.dullWhite, group.name)
            im.tooltip('This road spline is disabled. To edit or remove it, first enable it.')
          else
            if im.InputText("###" .. tostring(wCtr), splineNamePtr, 32) then
              group.name = ffi.string(splineNamePtr)
              if group.sceneTreeFolderId then
                local folder = scenetree.findObjectById(group.sceneTreeFolderId)
                if folder then
                  local preState = groupMgr.deepCopyGroup(group)
                  folder:setName(group.name)
                  editor.refreshSceneTreeWindow()
                  group.isDirty = true -- Ensures the mesh names are updated in the scene tree.
                  local postState = groupMgr.deepCopyGroup(group)
                  preState.isUpdateSceneTree = true
                  postState.isUpdateSceneTree = true
                  editor.history:commitAction("Edit Road Spline Name", { old = preState, new = postState }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
                end
              end
            end
            im.tooltip('Edit the road spline name.')
            if im.IsItemActive() then
              selectedGroupIdx = i
            end
          end
          im.PopItemWidth()
          wCtr = wCtr + 1
          im.SameLine()
          im.NextColumn()

          -- 'Remove Selected Road Spline' button.
          if selGroup and selGroup.isEnabled and not selGroup.isLink then
            if editor.uiIconImageButton(icons.trashBin2, iconsSmall, cols.blueB, nil, nil, 'removeRoadSpline' .. i) then
              materialSelectionMgr.closeWindow() -- If using the groups section, ensure the material selection window is closed.
              local statePre = groupMgr.deepCopyAllGroups()
              groupMgr.removeGroup(i)
              editor.history:commitAction("Remove Road Spline", { old = statePre, new = groupMgr.deepCopyAllGroups() }, groupMgr.transGroupEditUndo, groupMgr.transGroupEditRedo, true)
              editor.endWindow()
              return
            end
            im.tooltip("Remove this road spline from the session.")
          else
            im.Dummy(iconsSmall)
          end
          im.SameLine()

          -- 'Lock/Unlock' button.
          if not group.isLink then
            btnCol = group.isEnabled and cols.blueB or cols.blueD
            local btnIcon = group.isEnabled and icons.lock or icons.lock_open
            if editor.uiIconImageButton(btnIcon, iconsSmall, btnCol, nil, nil, 'lockUnlockRoadSplineToggleBtn' .. i) then
              local statePre = groupMgr.deepCopyGroup(group)
              group.isEnabled = not group.isEnabled
              selectedGroupIdx = i
              editor.history:commitAction("Toggle Road Spline Lock", { old = statePre, new = groupMgr.deepCopyGroup(group) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.tooltip((group.isEnabled and 'Disable' or 'Enable') .. ' this road spline.')
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

      -- Buttons underneath the road spline list box.
      im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
      im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

      -- 'Go To Road Spline' button.
      if selGroup and #selGroup.nodes > 0 then
        if editor.uiIconImageButton(icons.cameraFocusTopDown, iconsBig, cols.blueB, nil, nil, 'goToRoadSplineBtn') then
          materialSelectionMgr.closeWindow() -- If using the groups section, ensure the material selection window is closed.
          util.goToSpline(selGroup.divPoints)
        end
        im.tooltip('Move the camera to the selected Road Spline.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()

      -- 'Split Road Spline' button.
      if selGroup and selGroup.isEnabled and #selGroup.nodes > 2 and (selGroup.isLoop or (selectedNodeIdx > 1 and selectedNodeIdx < #selGroup.nodes)) then
        if editor.uiIconImageButton(icons.content_cut, iconsBig, cols.blueB, nil, nil, 'splitBtn') then
          materialSelectionMgr.closeWindow() -- If using the groups section, ensure the material selection window is closed.
          local statePre = groupMgr.deepCopyAllGroups()
          groupMgr.splitGroup(selGroup, selectedGroupIdx, selectedNodeIdx)
          local statePost = groupMgr.deepCopyAllGroups()
          editor.history:commitAction("Split Road Spline", { old = statePre, new = statePost }, groupMgr.transGroupEditUndo, groupMgr.transGroupEditRedo, true)
        end
        im.tooltip('Splits the selected road spline into two, at the selected node.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()

      -- 'Flip Direction' button.
      if selGroup and selGroup.isEnabled and not selGroup.isLink and #selGroup.nodes > 1 then
        if editor.uiIconImageButton(icons.cached, iconsBig, cols.blueB, nil, nil, 'flipDirectionBtn') then
          local statePre = groupMgr.deepCopyGroup(selGroup)
          geom.flipSplineDirection(selGroup)
          selGroup.isDirty = true
          editor.history:commitAction("Flip Road Spline Direction", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
        end
        im.tooltip('Flips the direction of the selected road spline (back to front).')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()

      -- 'Simplify Spline' button.
      if selGroup and selGroup.isEnabled and not selGroup.isLink and selGroup.nodes[selectedNodeIdx] and #selGroup.nodes > 2 then
        if editor.uiIconImageButton(icons.routeSimple, iconsBig, cols.blueB, nil, nil, 'simplifySplineBtn') then
          local statePre = groupMgr.deepCopyGroup(selGroup)
          rdp.simplifyNodesWidthsNormals(selGroup.nodes, selGroup.widths, selGroup.nmls, simplifyRdpTol)
          selectedNodeIdx = max(1, min(#selGroup.nodes, selectedNodeIdx))
          selGroup.isDirty = true
          editor.history:commitAction("Simplify Road Spline", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
        end
        im.tooltip('Simplifies the selected road spline (reduces the number of nodes).')
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
      im.Text("No road splines.")
      im.Text("Click the 'Add' button to add one.")
    end

    -- Spline properties controls.
    if selGroup then
      im.TextColored(cols.greenB, "Spline Properties:")
      im.Dummy(im.ImVec2(0, 3))

      -- Master 'Over Objects' checkbox.
      local tmpPtr = im.BoolPtr(selGroup.isOverObjects or false)
      if im.Checkbox("Over Objects", tmpPtr) then
        local statePre = groupMgr.deepCopyGroup(selGroup)
        local newValue = tmpPtr[0]
        selGroup.isOverObjects = newValue

        -- Update all layers in the group.
        for i = 1, #selGroup.layers do
          selGroup.layers[i].isOverObjects = newValue
          selGroup.layers[i].isDirty = true
        end

        selGroup.isDirty = true
        editor.history:commitAction("Change All Layers Over Objects", { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
      end
      im.tooltip('Toggle whether all layers in this spline should render over other objects.')
      im.Dummy(im.ImVec2(0, 3))
    end

    -- Road Spline-specific UI.
    if selGroup and selGroup.isEnabled then
      -- Tab bar for organising the interface.
      local selectedTab = 0 -- Default to first tab.
      if im.BeginTabBar("RoadSplineTabs") then
        if im.BeginTabItem("Layers") then
          selectedTab = 0
          im.EndTabItem()
        end
        if im.BeginTabItem("Painting") then
          selectedTab = 1
          im.EndTabItem()
        end
        im.EndTabBar()
      end

      -- Tab content.
      im.PushStyleVar2(im.StyleVar_WindowPadding, im.ImVec2(4, 8))
      if im.BeginChild1("TabContentChild", im.ImVec2(0, 0), true) then
        if selectedTab == 0 then -- Layers tab.
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
          im.tooltip('Toggle whether to include light tread marks on the Road Spline.')
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
          im.tooltip('Toggle whether to include heavy tread marks on the Road Spline.')
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
          im.tooltip('Toggle whether to include repair 1 fixes on the Road Spline.')
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
          im.tooltip('Toggle whether to include repair 2 fixes on the Road Spline.')
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
          im.tooltip('Toggle whether to include damaged asphalt wear 1 on the Road Spline.')
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
          im.tooltip('Toggle whether to include damaged asphalt wear 2 on the Road Spline.')
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
          im.tooltip('Toggle whether to include patches on the Road Spline.')
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
          im.tooltip('Toggle whether to include road cracks on the Road Spline.')
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
                    if texObj and texObj.texId then
                      im.Image(texObj.texId, iconsSmall)
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
                    if im.InputText("###" .. tostring(wCtr), layerNamePtr, 32) then
                      local preState = groupMgr.deepCopyGroup(selGroup)
                      layer.name = ffi.string(layerNamePtr)
                      layerMgr.removeDecalRoadInLayer(layer)
                      layer.isDirty = true
                      editor.history:commitAction("Rename Layer", { old = preState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
                    end
                    im.tooltip('Edit the layer name.')
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
                    im.tooltip('Remove this layer from the Road Spline.')
                  end
                  im.SameLine()

                  -- 'Enable/Disable Layer' toggle button.
                  local eyeIcon = layer.isEnabled and icons.lock_open or icons.lock_outline
                  local iconCol = layer.isEnabled and cols.fullWhite or cols.dullWhite
                  if editor.uiIconImageButton(eyeIcon, iconsSmall, iconCol, nil, nil, "toggleVisibleBtn" .. i) then
                    layer.isEnabled = not layer.isEnabled
                    selGroup.isDirty = true
                  end
                  im.tooltip(layer.isEnabled and "Disable this layer (content will be removed from the Road Spline)" or "Enable this layer (content will be included in the Road Spline)")
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
            im.tooltip('Add a new layer to the selected Road Spline.')
          else
            im.Dummy(iconsBig)
          end
          im.SameLine()

          -- 'Duplicate Layer' button.
          local selectedLayer, selectedIndex = getSelectedLayer(selGroup)
          if selGroup and selGroup.isEnabled and selectedLayer and selectedLayer.isEnabled and not selectedLayer.isLink and not selectedLayer.isHidden then
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
            im.tooltip('Remove all user-created layers from the selected Road Spline. Auto-generated layers will be preserved.')
          else
            im.Dummy(iconsBig)
          end
          im.PopStyleVar(2)
          im.Columns(1)
          if #groups > 0 and selGroup and selGroup.isEnabled then
            im.Separator()
          end

          -- Layer-specific UI (for the selected layer).
          selGroup = groupMgr.getGroups()[selectedGroupIdx]
          local selectedLayer, selectedIndex = getSelectedLayer(selGroup)
          if selGroup and selGroup.isEnabled and selectedLayer and selectedLayer.isEnabled and not selectedLayer.isHidden then

            -- 'Select Material' panel.
            im.TextColored(cols.greenB, "Layer Material:")
            if editor.uiIconImageButton(icons.youtube_searched_for, iconsBig, cols.blueB, nil, nil, 'selectLayerMaterialBtn') then
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
            im.Columns(2, "flipTrackCheckboxRow", false)

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
                selectedLayer.isDirty = true
                selGroup.isDirty = true
              end
              im.tooltip('Set the width of the layer.')
              if im.IsItemActivated() then
                sliderPreEditState = groupMgr.deepCopyGroup(selGroup)
              end
              if im.IsItemDeactivatedAfterEdit() then
                editor.history:commitAction("Adjust Width", { old = sliderPreEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
              end
              im.PopItemWidth()
            end
            im.NextColumn()

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
              selGroup.isDirty = true
            end
            im.tooltip('Set the lateral position of the layer (-1.0 = left edge, 0.0 = center, 1.0 = right edge).')
            if im.IsItemActivated() then
              sliderPreEditState = groupMgr.deepCopyGroup(selGroup)
            end
            if im.IsItemDeactivatedAfterEdit() then
              editor.history:commitAction("Adjust Position", { old = sliderPreEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()

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
              selGroup.isDirty = true
            end
            im.tooltip('Set the texture length of the layer.')
            if im.IsItemActivated() then
              sliderPreEditState = groupMgr.deepCopyGroup(selGroup)
            end
            if im.IsItemDeactivatedAfterEdit() then
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
              selGroup.isDirty = true
            end
            im.tooltip('Set the render priority of the layer.')
            if im.IsItemActivated() then
              sliderPreEditState = groupMgr.deepCopyGroup(selGroup)
            end
            if im.IsItemDeactivatedAfterEdit() then
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
              selGroup.isDirty = true
            end
            im.tooltip('Set the fade in of the layer.')
            if im.IsItemActivated() then
              sliderPreEditState = groupMgr.deepCopyGroup(selGroup)
            end
            if im.IsItemDeactivatedAfterEdit() then
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
              selGroup.isDirty = true
            end
            im.tooltip('Set the fade out of the layer.')
            if im.IsItemActivated() then
              sliderPreEditState = groupMgr.deepCopyGroup(selGroup)
            end
            if im.IsItemDeactivatedAfterEdit() then
              editor.history:commitAction("Adjust Fade Out", { old = sliderPreEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()

            -- Restore local slider spacing.
            im.PopStyleVar(1)
            im.PopItemWidth()
            im.Columns(1)
            im.Separator()
          else
            materialSelectionMgr.closeWindow() -- If no layer is selected, ensure the material selection window is closed.
          end
        elseif selectedTab == 1 then -- Painting tab.
          if selGroup and selGroup.isEnabled and #selGroup.nodes > 1 then
            im.TextColored(cols.greenB, "Terrain Painting:")
          -- Use the same 2-column slider layout as other spline tools.
          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.Columns(2, 'paintingSliderCols', false)
          im.SetColumnWidth(0, 30)

            -- 'Paint Margin' slider.
            if selGroup.paintMargin ~= sliderDefaults.defaultPaintMargin then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetPaintMarginBtn') then
                local preEditState = groupMgr.deepCopyGroup(selGroup)
                selGroup.paintMargin = sliderDefaults.defaultPaintMargin
                selGroup.isDirty = true
                editor.history:commitAction("Reset Paint Margin", { old = preEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(im.ImVec2(iconsSmall.x + 4, iconsSmall.y))
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            local tmpPtr = im.FloatPtr(selGroup.paintMargin or sliderDefaults.defaultPaintMargin)
            if im.SliderFloat('###81840', tmpPtr, 0.1, 50.0, "Paint Margin (m) = %.1f") then
              selGroup.paintMargin = tmpPtr[0]
              selGroup.isDirty = true
            end
            im.tooltip('Set the margin around the road spline for terrain painting.')
            if im.IsItemActivated() then
              sliderPreEditState = groupMgr.deepCopyGroup(selGroup)
            end
            if im.IsItemDeactivatedAfterEdit() then
              editor.history:commitAction("Adjust Paint Margin", { old = sliderPreEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()

            -- 'Paint Material' slider.
            if (selGroup.paintMaterialIdx or sliderDefaults.defaultPaintMaterialIdx) ~= sliderDefaults.defaultPaintMaterialIdx then
              if editor.uiIconImageButton(icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'resetPaintMaterialBtn') then
                local preEditState = groupMgr.deepCopyGroup(selGroup)
                selGroup.paintMaterialIdx = sliderDefaults.defaultPaintMaterialIdx
                selGroup.isDirty = true
                editor.history:commitAction("Reset Paint Material", { old = preEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
              end
              im.tooltip("Reset to default")
            else
              im.Dummy(im.ImVec2(iconsSmall.x + 4, iconsSmall.y))
            end
            im.SameLine()
            im.NextColumn()
            im.PushItemWidth(-1)
            tmpPtr = im.IntPtr(selGroup.paintMaterialIdx or sliderDefaults.defaultPaintMaterialIdx)
            if im.SliderInt('###81841', tmpPtr, 0, util.getNumMaterials(), "Paint Material = %d") then
              selGroup.paintMaterialIdx = tmpPtr[0]
              selGroup.isDirty = true
            end
            im.tooltip('Set the material to be used with terrain painting.')
            if im.IsItemActivated() then
              sliderPreEditState = groupMgr.deepCopyGroup(selGroup)
            end
            if im.IsItemDeactivatedAfterEdit() then
              editor.history:commitAction("Adjust Paint Material", { old = sliderPreEditState, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.PopItemWidth()
            im.NextColumn()
            im.PopStyleVar(1)
            im.Columns(1)
            im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
            im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))

            -- 'Paint Terrain' button.
            btnCol = (selGroup.isPainting and cols.blueB or cols.blueD)
            if editor.uiIconImageButton(icons.terrain_painting, iconsBig, btnCol, nil, nil, 'paintTerrainBtn') then
              local statePre = groupMgr.deepCopyGroup(selGroup)
              selGroup.isPainting = not selGroup.isPainting
              if not selGroup.isPainting then
                paint.revert(selGroup)
              end
              selGroup.isDirty = true
              local statePost = groupMgr.deepCopyGroup(selGroup)
              editor.history:commitAction("Toggle Terrain Painting", { old = statePre, new = statePost }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
            end
            im.tooltip('Switch terrain painting ' .. ((selGroup.isPainting and 'off') or 'on') .. '.')
            im.PopStyleVar(2)
            im.Columns(1)
            im.Separator()
          else
            im.TextColored(cols.redB, 'Add some nodes before painting.')
            im.Text('Create at least 2 nodes to enable terrain painting.')
          end
        end
      end
      im.EndChild() -- Must always be called for BeginChild1, regardless of return value.
      im.PopStyleVar()
    end
  end
  editor.endWindow()
end

-- Callback for when the user has selected a material.
local function onSelectMaterial(objId)
  local groups = groupMgr.getGroups()
  local selGroup = groups[selectedGroupIdx]
  local selectedLayer, selectedIndex = getSelectedLayer(selGroup)
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

-- Main editor callback.
local function onEditorGui()
  -- Ensure all Road Splines are updated, even if this tool is not active.
  groupMgr.updateDirtyGroups()

  -- If this tool is not active, render the shells of the splines but do nothing further.
  if not isRoadSplineActive then
    render.renderShells(groupMgr.getGroups())
    return
  end

  -- Handle the main tool window UI.
  handleMainToolWindowUI()

  -- Handle the front end if the user is drawing a selection polygon.
  if isDrawPolygon then
    poly.handleUserPolygon(onSelectionPolygonComplete)
    return -- Don't do anything further if the user is drawing a selection polygon.
  end

  -- Handle the material selection UI.
  local groups = groupMgr.getGroups()
  local selGroup = groups[selectedGroupIdx]
  local selectedLayer, selectedIndex = getSelectedLayer(selGroup)
  if selGroup and #selGroup.layers > 0 and selectedLayer then
    materialSelectionMgr.handleMaterialSelectionSubWindow(false, onSelectMaterial)
  else
    materialSelectionMgr.closeWindow() -- Close the material selection window if there is no selected layer.
  end

  -- Render the wire frame (only if not linked to master spline).
  if not selGroup then
    render.renderRibbonWireFrame(groups, selectedGroupIdx, 2)
  end

  -- Render the spline and layer visualisations with debugDraw (only if not linked to master spline).
  if selGroup then
    render.handleSplineRendering(groups, selectedGroupIdx, selectedNodeIdx, isGizmoActive, false, isLockShape, false, true, elevScale)
    if selectedLayer and selectedLayer.isEnabled and not selectedLayer.isHidden then
      render.renderLayer(selectedLayer, selGroup, true, 2)
    end
  end

  -- Handle the mouse and keyboard events.
  out.spline, out.node, out.layer, out.isGizmoActive, out.isLockShape = selectedGroupIdx, selectedNodeIdx, selectedIndex or 1, isGizmoActive, isLockShape
  input.handleSplineEvents(
    groups,
    out,
    false, true, true, false, false, true, true, isLockShape,
    defaultSplineWidth,
    groupMgr.deepCopyGroup, groupMgr.deepCopyAllGroups,
    groupMgr.copyGroupProfile, groupMgr.pasteGroupProfile,
    groupMgr.recreateAutoGeneratedLayers,
    groupMgr.joinRoadSplines,
    groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo,
    groupMgr.transGroupEditUndo, groupMgr.transGroupEditRedo)
  selectedGroupIdx, selectedNodeIdx, selectedIndex, isGizmoActive, isLockShape = out.spline, out.node, out.layer, out.isGizmoActive, out.isLockShape

  -- Update selectedLayerId based on the returned index
  if selectedIndex and selGroup and selGroup.layers[selectedIndex] then
    selectedLayerId = selGroup.layers[selectedIndex].id
  end
end

-- Called when the tool mode icon is pressed.
local function onActivate()
  isDrawPolygon = false
  poly.clearPolygon() -- Ensure there is no residual polygon left over from the previous usage.
  editor.clearObjectSelection()
  editor.showWindow(toolWindowName)
  materialSelectionMgr.closeWindow()
  isRoadSplineActive = true

  -- Recompute the group id -> index map.
  util.computeIdToIdxMap(groupMgr.getGroups(), groupMgr.getIdToIdxMap()) -- Probably not needed here, but just in case.
end

-- Called when the tool is exited.
local function onDeactivate()
  isDrawPolygon = false
  poly.clearPolygon() -- Ensure there is no residual polygon left over from the previous usage.
  editor.hideWindow(toolWindowName)
  materialSelectionMgr.closeWindow()
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
  editor.editModes.roadSplineEditor = {
    displayName = "Road Spline",
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    icon = editor.icons.roadStack,
    iconTooltip = "RoadSpline",
    auxShortcuts = {},
    hideObjectIcons = true
  }
  editor.registerWindow(toolWindowName, toolWindowSize)
  materialSelectionMgr.registerWindow()

  -- Set up the scenetree right click menu for importing.
  editor.addExtendedSceneTreeObjectMenuItem({
    title = "Convert to Road Spline",
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
