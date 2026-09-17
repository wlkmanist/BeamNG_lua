-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local utilRos = require('tech/ros/util')
local persistence = require('editor/tech/ros/rosEditorPersistence')
local fieldCatalog = require('editor/tech/ros/editorFieldCatalog')
local inspector = require('editor/tech/ros/rosEditorInspector')

local M = {}

local function selectVehicleRow(editorState, rowIndex1Based)
  editorState.selectedVehicleRowIndex = rowIndex1Based
  editorState.selectedSensorRowIndex[0] = 0
  editorState.invalidateSensorIdBuffer()
end

local function addDraftSensorOfType(editorState, draftWork, typeName)
  local defaultEntry = persistence.getDefaultSensorEntry(editorState, typeName)
  draftWork.sensors[#draftWork.sensors + 1] = {
    id = string.format('%s_%d', typeName, #draftWork.sensors + 1),
    type = typeName,
    restrictFields = false,
    config = defaultEntry and defaultEntry.config and utilRos.deepCopy(defaultEntry.config) or {},
  }
  editorState.selectedSensorRowIndex[0] = #draftWork.sensors - 1
  editorState.invalidateSensorIdBuffer()
end

local function drawAddSensorTypeGrid(editorState, draftWork)
  local typeCount = #editorState.sensorTypeNamesInOrder
  if typeCount < 1 then return end
  im.Text('Add sensor')
  local availableWidth = im.GetContentRegionAvailWidth()
  local spacing = im.GetStyle().ItemSpacing.x
  local minCellWidth = 118 * im.uiscale[0]
  local cols = math.max(2, math.floor((availableWidth + spacing) / (minCellWidth + spacing)))
  cols = math.min(cols, typeCount)
  local cellWidth = (availableWidth - spacing * (cols - 1)) / cols
  local cellHeight = math.max(34 * im.uiscale[0], im.GetFontSize() + 14 * im.uiscale[0])
  local iconSize = im.ImVec2(18 * im.uiscale[0], 18 * im.uiscale[0])

  im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(spacing, 6))
  for idx, typeName in ipairs(editorState.sensorTypeNamesInOrder) do
    if idx > 1 and (idx - 1) % cols ~= 0 then im.SameLine(0, spacing) end
    im.PushID4(idx)
    im.BeginChild1('rosAddCell', im.ImVec2(cellWidth, cellHeight), true, im.WindowFlags_NoScrollbar)
    local iconTexture = fieldCatalog.resolveSensorTypeIcon(typeName)
    if editor.uiIconImageButton(iconTexture, iconSize, nil, typeName, nil, 'addType') then
      addDraftSensorOfType(editorState, draftWork, typeName)
    end
    im.EndChild()
    im.PopID()
  end
  im.PopStyleVar()
end

local function drawVehicleRow(editorState, rowIndex, row, rosCore, iconSize)
  local vehicleId = row.vehicleId
  local isRosOn = rosCore and rosCore.isVehicleRosActive and rosCore.isVehicleRosActive(vehicleId)

  im.TableSetBgColor(im.TableBgTarget_RowBg0, im.GetColorU322(isRosOn
    and im.ImVec4(0.18, 0.4, 0.22, 0.55)
    or im.ImVec4(0.22, 0.22, 0.26, 0.45)))

  im.TableSetColumnIndex(0)
  local label = string.format('%d  %s  (%s)', vehicleId, row.displayName or '?', row.jbeamName or '?')
  if isRosOn then
    local sensorCount = #persistence.getOrCreateDraftWork(editorState, vehicleId).sensors
    label = label .. string.format('  -  %d active sensor%s', sensorCount, sensorCount == 1 and '' or 's')
  end
  if im.Selectable1(label .. '##rosVsel', rowIndex == editorState.selectedVehicleRowIndex, 0, im.ImVec2(0, 0)) then
    selectVehicleRow(editorState, rowIndex)
  end

  im.TableSetColumnIndex(1)
  if editor.uiIconImageButton(editor.icons.cameraFocusOnVehicle2, iconSize, nil, nil, nil, 'rosF' .. vehicleId) then
    core_camera.setByName(0, 'orbit', false)
    be:enterVehicle(0, scenetree.findObject(vehicleId))
  end
  im.SetItemTooltip('Focus camera on this vehicle')

  im.TableSetColumnIndex(2)
  if editor.uiIconImageButton(editor.icons.folder, iconSize, nil, nil, nil, 'rosLd' .. vehicleId) then
    selectVehicleRow(editorState, rowIndex)
    persistence.loadTemplateFileIntoDraft(editorState, vehicleId)
  end
  im.SetItemTooltip('Load sensor template (JSON) for this vehicle')

  im.TableSetColumnIndex(3)
  if editor.uiIconImageButton(editor.icons.save, iconSize, nil, nil, nil, 'rosSv' .. vehicleId) then
    persistence.saveDraftToTemplateFile(editorState, vehicleId)
  end
  im.SetItemTooltip('Save this vehicle\'s sensor draft as a JSON template')

  im.TableSetColumnIndex(4)
  local canRun = #persistence.getOrCreateDraftWork(editorState, vehicleId).sensors >= 1
  if not canRun then im.BeginDisabled() end
  local runIcon = isRosOn and editor.icons.refresh or editor.icons.play_arrow
  if editor.uiIconImageButton(runIcon, iconSize, nil, nil, nil, 'rosGo' .. vehicleId) then
    persistence.launchRosForVehicle(editorState, vehicleId)
  end
  if not canRun then im.EndDisabled() end
  im.SetItemTooltip(isRosOn and 'Reload ROS for this vehicle (re-apply merged draft)'
    or 'Launch ROS for this vehicle')

  im.TableSetColumnIndex(5)
  if not isRosOn then im.BeginDisabled() end
  if editor.uiIconImageButton(editor.icons.stop, iconSize, nil, nil, nil, 'rosSt' .. vehicleId) then
    persistence.stopRosForVehicle(editorState, vehicleId)
  end
  if not isRosOn then im.EndDisabled() end
  im.SetItemTooltip('Stop ROS for this vehicle')
end

local function drawVehicleTable(editorState)
  im.Text('Scene vehicles')
  local rosCore = persistence.getRosCore()
  local tblFlags = bit.bor(
    im.TableFlags_BordersOuter, im.TableFlags_BordersInnerH,
    im.TableFlags_SizingStretchProp, im.TableFlags_ScrollY)
  local iconSize = im.ImVec2(22 * im.uiscale[0], 22 * im.uiscale[0])
  local actionColumnWidth = 28 * im.uiscale[0]

  if not im.BeginTable('##rosVehTbl', 6, tblFlags, im.ImVec2(-1, 120 * im.uiscale[0])) then return end
  im.TableSetupColumn('Vehicle', im.TableColumnFlags_WidthStretch)
  im.TableSetupColumn('##focus', im.TableColumnFlags_WidthFixed, actionColumnWidth)
  im.TableSetupColumn('##load', im.TableColumnFlags_WidthFixed, actionColumnWidth)
  im.TableSetupColumn('##save', im.TableColumnFlags_WidthFixed, actionColumnWidth)
  im.TableSetupColumn('##run', im.TableColumnFlags_WidthFixed, actionColumnWidth)
  im.TableSetupColumn('##stop', im.TableColumnFlags_WidthFixed, actionColumnWidth)

  for i, row in ipairs(editorState.sceneVehicleRows) do
    im.TableNextRow()
    drawVehicleRow(editorState, i, row, rosCore, iconSize)
  end
  im.EndTable()
end

local function drawSensorList(editorState, draftWork)
  im.Text('Sensors on this vehicle')
  if im.BeginListBox('##rosSensList', im.ImVec2(-1, 100 * im.uiscale[0])) then
    for i = 1, #draftWork.sensors do
      local sensor = draftWork.sensors[i]
      im.PushID4(i)
      fieldCatalog.drawSensorTypeIcon(sensor.type, im.ImVec2(18 * im.uiscale[0], 18 * im.uiscale[0]))
      im.SameLine()
      local rowLabel = string.format('%s  ·  %s', sensor.id or '?', sensor.type or '?')
      if im.Selectable1(rowLabel, i - 1 == editorState.selectedSensorRowIndex[0]) then
        editorState.selectedSensorRowIndex[0] = i - 1
        editorState.invalidateSensorIdBuffer()
      end
      im.PopID()
    end
    im.EndListBox()
  end

  if im.Button('Remove selected sensor##rosRm') then
    local removeIndex = editorState.selectedSensorRowIndex[0] + 1
    if removeIndex >= 1 and removeIndex <= #draftWork.sensors then
      table.remove(draftWork.sensors, removeIndex)
      editorState.selectedSensorRowIndex[0] = math.max(0,
        math.min(#draftWork.sensors - 1, editorState.selectedSensorRowIndex[0]))
      editorState.invalidateSensorIdBuffer()
    end
  end
end

local function drawRosLibSelector(editorState)
  local rosLoaded = persistence.isRosLibLoaded()
  im.Text('ROS 2 library')
  im.SameLine()
  im.TextColored(rosLoaded and im.ImVec4(0.5, 1, 0.5, 1) or im.ImVec4(0.75, 0.75, 0.75, 1),
    persistence.getRosLibPath() or 'Not loaded')

  if not rosLoaded then
    im.SameLine()
    if im.Button('Browse...##rosLibBrowse') then persistence.browseAndLoadRosLib(editorState) end

    local lastPath = persistence.getLastRosLibPathSuggestion()
    if lastPath then
      im.SameLine()
      if im.Button('Load last used##rosLibLoadLast') then persistence.loadRosLib(editorState, lastPath) end
      im.SetItemTooltip(lastPath)
    end
  end

  if editorState.rosLibLoadError then
    if editorState.rosLibLoadError and string.find(editorState.rosLibLoadError, 'The specified procedure could not be found.', 1, true) then
      editorState.rosLibLoadError = 'Incompatible ROS 2 library version. Please make sure your ROS2 environment is set up correctly.'
    end
    im.TextColored(im.ImVec4(1, 0.4, 0.4, 1), editorState.rosLibLoadError)
  end
  return rosLoaded
end

local function drawRosEditorBody(editorState)
  if not persistence.loadRosDefaultsIfNeeded(editorState) then
    im.TextColored(im.ImVec4(1, 0.4, 0.4, 1), 'rosDefaults.json missing or empty.')
    return
  end

  persistence.refreshSceneVehicleRows(editorState)
  persistence.removeDraftConfigsForDespawnedVehicles(editorState)

  local vehicleCount = #editorState.sceneVehicleRows
  if vehicleCount < 1 then
    im.Text('No vehicles in the scene.')
    return
  end

  editorState.selectedVehicleRowIndex = math.max(1,
    math.min(vehicleCount, editorState.selectedVehicleRowIndex))

  im.Separator()
  drawVehicleTable(editorState)

  local selectedRow = editorState.sceneVehicleRows[editorState.selectedVehicleRowIndex]
  local draftWork = persistence.getOrCreateDraftWork(editorState, selectedRow.vehicleId)

  im.Separator()
  drawAddSensorTypeGrid(editorState, draftWork)

  im.Separator()
  drawSensorList(editorState, draftWork)

  inspector.drawSelectedSensorInspector(editorState, draftWork)
end

function M.drawRosWorldEditorWindow(editorState)
  if not editor.beginWindow(editorState.WINDOW_ID, 'ROS 2 Editor###title', im.WindowFlags_None) then return end

  local rosLoaded = drawRosLibSelector(editorState)
  im.Separator()

  if not rosLoaded then im.BeginDisabled() end
  drawRosEditorBody(editorState)
  if not rosLoaded then im.EndDisabled() end

  editor.endWindow()
end

return M
