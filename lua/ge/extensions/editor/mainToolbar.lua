-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'core_environment'}
local imUtils = require('ui/imguiUtils')
local logTag = 'editor_main_toolbar'
local im = ui_imgui
local toolbarOpen = im.BoolPtr(true)
local toolbarWindowName = "mainToolbar"
local gridSnapComboItemCurrent = im.IntPtr(-1)
local rotateSnapComboItemCurrent = im.IntPtr(-1)
local scaleSnapComboItemCurrent = im.IntPtr(-1)
local FadeIconsPtr = im.FloatPtr(0)
local camSpeedPtr = im.FloatPtr(0)
local todPtr = im.FloatPtr(0)
local todYearPtr = im.IntPtr(0)
local todMonthPtr = im.IntPtr(0)
local todDayPtr = im.IntPtr(0)
local manualEVPtr = im.FloatPtr(0)
local initialAutoExposure
local initialManualEV
local autoExposurePtr = im.BoolPtr(true)
local vehicleActionMaps = {"VehicleCommonActionMap", "VehicleSpecificActionMap"}
local editModeSetsPath = "settings/editor/editModeSets.json"
local defaultEditModeSetsPath = "settings/editor/defaultEditModeSets.json"
local allEditModesListName = "All"

local gridSnapWidgetsComboItemsTbl = {"0.1", "0.2", "0.25", "0.5", "1", "1.5", "2", "2.5", "3", "4", "5", "10", "15", "20"}
local gridSnapWidgetsComboItems = im.ArrayCharPtrByTbl(gridSnapWidgetsComboItemsTbl)
local rotateSnapWidgetsComboItemsTbl = {"5", "15", "22.5", "45"}
local rotateSnapWidgetsComboItems = im.ArrayCharPtrByTbl(rotateSnapWidgetsComboItemsTbl)

-- Terrain Snapping
local terrainSnapSettingsOpen = false
-- Grid Snapping
local gridSnapSettingsOpen = false

-- Variables to store modes data
local availableModesList = {}
local selectedModesList = {}
local allModes = {}
local allModesPopulated = false;

local editModeSets = {}
local selectedSetIndex = 1
local editModeSetsVersion = 1  -- set from default file when loading; used when saving
local editingSetIndex = -1
local editingSetName = im.ArrayChar(100, "")

local function saveEditModeSets()
  local dataToSave = {
    version = editModeSetsVersion,
    sets = editModeSets,
    selectedSetIndex = selectedSetIndex
  }
  jsonWriteFile(editModeSetsPath, dataToSave, true)
end

local function addEditModeSet(name)
  table.insert(editModeSets, {name = name, modes = {}})
  saveEditModeSets()
end

local function deleteEditModeSet(index)
  local set = editModeSets[index]
  if not set then return end

  if set.name == allEditModesListName then
    return
  end

  if #editModeSets > 1 then  -- Keep at least one set
    table.remove(editModeSets, index)
    if selectedSetIndex >= index then
      selectedSetIndex = math.max(1, selectedSetIndex - 1)
    end
    saveEditModeSets()
  end
end

local function saveModesToSet()
  local currentSet = editModeSets[selectedSetIndex]
  if currentSet and currentSet.name ~= allEditModesListName then
    currentSet.modes = {}
    for _, mode in ipairs(selectedModesList) do
      table.insert(currentSet.modes, {name = mode.name, key = mode.key})
    end
    saveEditModeSets()
  end
  -- Don't save changes to All - it should always contain all modes
end

local function findModeInAvailableModes(key)
  for _, mode in ipairs(allModes) do
    if mode.key == key then
      return true
    end
  end
  return false
end

local function getModesFromSet(index)
  local set = editModeSets[index]
  local modesInSet = {}
  if set then
    for _, mode in ipairs(set.modes) do
      if findModeInAvailableModes(mode.key) then
        table.insert(modesInSet, mode.key)
      end
    end
    table.insert(modesInSet, 1, "objectSelect")
    table.insert(modesInSet, 2, "createObject")
  end
  return modesInSet
end

local function loadModesFromSet(index)
  selectedSetIndex = index
  local set = editModeSets[index]
  selectedModesList = {}

  -- reset the selected bool when a set is clicked in the list
  for _, mode in ipairs(allModes) do
    mode.selected = false
  end

  if set then
    for _, mode in ipairs(set.modes) do
      if findModeInAvailableModes(mode.key) then
        table.insert(selectedModesList, {name = mode.name, key = mode.key})
      end
    end
    saveEditModeSets()
  end
end

local function startEditingSetName(index)
  editingSetIndex = index
  local set = editModeSets[index]
  if set then
    ffi.copy(editingSetName, set.name)
  end
end

local function finishEditingSetName()
  if editingSetIndex > 0 and editingSetIndex <= #editModeSets then
    local newName = ffi.string(editingSetName)
    if newName ~= "" then
      editModeSets[editingSetIndex].name = newName
      saveEditModeSets()
    end
  end
  editingSetIndex = -1
end

local function loadEditModeSets()
  -- default edit mode sets from settings/editor/defaultEditModeSets.json
  local defaultVersion = 1
  local defaultData = nil
  if FS:fileExists(defaultEditModeSetsPath) then
    local ok, defaultRead = pcall(jsonReadFile, defaultEditModeSetsPath)
    if ok and defaultRead and type(defaultRead) == "table" and defaultRead.sets and type(defaultRead.sets) == "table" and #defaultRead.sets > 0 then
      defaultVersion = tonumber(defaultRead.version) or 1
      defaultData = defaultRead
    end
  end
  -- minimal fallback only when no valid default JSON (single empty "All" set).
  if not defaultData then
    defaultData = { version = defaultVersion, sets = {{name = allEditModesListName, modes = {}}}, selectedSetIndex = 1 }
  end

  editModeSetsVersion = defaultVersion

  local useUserFile = false
  if FS:fileExists(editModeSetsPath) then
    local success, data = pcall(jsonReadFile, editModeSetsPath)
    if success and data and type(data) == "table" and data.sets and type(data.sets) == "table" then
      local loadedVersion = tonumber(data.version)
      if loadedVersion and loadedVersion == defaultVersion then
        useUserFile = true
        editModeSets = data.sets
        selectedSetIndex = data.selectedSetIndex or 1
        editModeSetsVersion = loadedVersion
      end
    end
    if not useUserFile then
      -- version missing or different, or invalid file: backup old file then replace entirely with default (no merge)
      if data and type(data) == "table" then
        local backupPath = "settings/editor/editModeSets_beforeVersionUpgrade.json"
        jsonWriteFile(backupPath, data, true)
      end
      jsonWriteFile(editModeSetsPath, defaultData, true)
      editModeSets = defaultData.sets
      selectedSetIndex = defaultData.selectedSetIndex or 1
    end
  else
    -- no user file: use default in memory
    editModeSets = defaultData.sets
    selectedSetIndex = defaultData.selectedSetIndex or 1
  end

  -- ensure we have at least one set (use default from JSON or minimal fallback)
  if #editModeSets == 0 then
    editModeSets = defaultData.sets
  end

  -- validate selectedSetIndex
  if selectedSetIndex < 1 or selectedSetIndex > #editModeSets then
    selectedSetIndex = 1
  end

  loadModesFromSet(selectedSetIndex)
end

-- Function to move selected modes up in the list
local function moveSelectedModesUp()
  local selectedIndices = {}
  for i, mode in ipairs(selectedModesList) do
    if mode.selected then
      table.insert(selectedIndices, i)
    end
  end

  if #selectedIndices == 0 then return end

  -- Sort indices in ascending order
  table.sort(selectedIndices)

  -- Check if selection is continuous
  for i = 1, #selectedIndices - 1 do
    if selectedIndices[i + 1] - selectedIndices[i] > 1 then
      return -- Not continuous, don't move
    end
  end

  -- Check if we can move up (first selected item must be > 1)
  if selectedIndices[1] <= 1 then return end

  -- Extract selected items
  local selectedItems = {}

  for i = #selectedIndices, 1, -1 do
    table.insert(selectedItems, table.remove(selectedModesList, selectedIndices[i]))
  end

  -- Insert selected items one position up
  local insertIndex = selectedIndices[1] - 1
  for i = #selectedItems, 1, -1 do
    table.insert(selectedModesList, insertIndex, selectedItems[i])
  end

  saveModesToSet()
end

-- Function to move selected modes down in the list
local function moveSelectedModesDown()
  local selectedIndices = {}
  for i, mode in ipairs(selectedModesList) do
    if mode.selected then
      table.insert(selectedIndices, i)
    end
  end

  if #selectedIndices == 0 then return end

  -- Sort indices in ascending order first to check continuity
  table.sort(selectedIndices)

  -- Check if selection is continuous
  for i = 1, #selectedIndices - 1 do
    if selectedIndices[i + 1] - selectedIndices[i] > 1 then
      return -- Not continuous, don't move
    end
  end

  -- Store the last selected index before sorting for removal
  local lastSelectedIndex = selectedIndices[#selectedIndices]

  -- Check if we can move down (last selected item must be < list length)
  if lastSelectedIndex >= #selectedModesList then return end

  -- Extract selected items
  local selectedItems = {}
  for i = #selectedIndices, 1, -1 do
    table.insert(selectedItems, table.remove(selectedModesList, selectedIndices[i]))
  end
  -- Insert selected items one position down
  local insertIndex = lastSelectedIndex + 2 - #selectedIndices
  for i = 1, #selectedItems do
    table.insert(selectedModesList, insertIndex, selectedItems[i])
    insertIndex = insertIndex + 1
  end

  saveModesToSet()
end

-- Function to check if move up button should be enabled
local function canMoveUp()
  local selectedIndices = {}
  for i, mode in ipairs(selectedModesList) do
    if mode.selected then
      table.insert(selectedIndices, i)
    end
  end

  if #selectedIndices == 0 then return false end

  -- Sort indices in ascending order
  table.sort(selectedIndices)

  -- Check if selection is continuous
  for i = 1, #selectedIndices - 1 do
    if selectedIndices[i + 1] - selectedIndices[i] > 1 then
      return false -- Not continuous
    end
  end

  -- Check if we can move up (first selected item must be > 1)
  return selectedIndices[1] > 1
end

-- Function to check if move down button should be enabled
local function canMoveDown()
  local selectedIndices = {}
  for i, mode in ipairs(selectedModesList) do
    if mode.selected then
      table.insert(selectedIndices, i)
    end
  end

  if #selectedIndices == 0 then return false end

  -- Sort indices in ascending order
  table.sort(selectedIndices)

  -- Check if selection is continuous
  for i = 1, #selectedIndices - 1 do
    if selectedIndices[i + 1] - selectedIndices[i] > 1 then
      return false -- Not continuous
    end
  end

  -- Check if we can move down (last selected item must be < list length)
  return selectedIndices[#selectedIndices] < #selectedModesList
end

local function deselectAllAvailableModes()
  for _, mode in ipairs(allModes) do
    mode.selected = false
  end
end

local function deselectAllSelectedModes()
  for _, mode in ipairs(selectedModesList) do
    mode.selected = false
  end
end

local modesManagerOpen = im.BoolPtr(false)
local buttonColor_active = im.GetStyleColorVec4(im.Col_ButtonActive)
local buttonColor_inactive = im.GetStyleColorVec4(im.Col_Button)
local function drawGeneralToolbarButtons()
  if editor.uiIconImageButton(editor.icons.insert_drive_file, nil, nil, nil, nil) then
    editor.doNewLevel()
  end
  if im.IsItemHovered() then im.BeginTooltip() im.Text("New Level") im.EndTooltip() end
  im.SameLine()

  if editor.uiIconImageButton(editor.icons.folder, nil, nil, nil, nil) then
    editor.doOpenLevel()
  end
  if im.IsItemHovered() then im.BeginTooltip() im.Text("Open Level") im.EndTooltip() end
  im.SameLine()

  if editor.uiIconImageButton(editor.icons.save, nil, nil, nil, nil) then
    editor.doSaveLevel()
  end
  if im.IsItemHovered() then im.BeginTooltip() im.Text("Save Level") im.EndTooltip() end
  im.SameLine()

  if editor.uiIconImageButton(editor.icons.undo, nil, nil, nil, nil) then
    editor.undo()
  end
  if im.IsItemHovered() then im.BeginTooltip() im.Text("Undo") im.EndTooltip() end
  im.SameLine()

  if editor.uiIconImageButton(editor.icons.redo, nil, nil, nil, nil) then
    editor.redo()
  end
  if im.IsItemHovered() then im.BeginTooltip() im.Text("Redo") im.EndTooltip() end
  im.SameLine()

  if editor.uiIconImageButton(editor.icons.content_cut, nil, nil, nil, nil) then
    editor.cut()
  end
  if im.IsItemHovered() then im.BeginTooltip() im.Text("Cut") im.EndTooltip() end
  im.SameLine()

  if editor.uiIconImageButton(editor.icons.content_copy, nil, nil, nil, nil) then
    editor.copy()
  end
  if im.IsItemHovered() then im.BeginTooltip() im.Text("Copy") im.EndTooltip() end
  im.SameLine()

  if editor.uiIconImageButton(editor.icons.content_paste, nil, nil, nil, nil) then
    editor.paste()
  end
  if im.IsItemHovered() then im.BeginTooltip() im.Text("Paste") im.EndTooltip() end
  im.SameLine()

  if editor.uiIconImageButton(editor.icons.settings, nil, nil, nil, nil) then
    editor.showPreferences()
  end
  if im.IsItemHovered() then im.BeginTooltip() im.Text("Editor Preferences") im.EndTooltip() end
  im.SameLine()

  local vehicleButtonBgColor = im.GetStyleColorVec4(im.Col_Button)
  if editor.getPreference("ui.general.enableVehicleControls") then vehicleButtonBgColor = im.GetStyleColorVec4(im.Col_ButtonActive) end
  if editor.uiIconImageButton(editor.icons.directions_car, nil, nil, nil, vehicleButtonBgColor) then
    editor.setPreference("ui.general.enableVehicleControls", not editor.getPreference("ui.general.enableVehicleControls"))
  end
  if im.IsItemHovered() then im.BeginTooltip() im.Text("Enable driving the vehicle in editor") im.EndTooltip() end
  im.SameLine()
end

local function axisGizmoButtonsGui()
  local mode = editor.getAxisGizmoMode()
  local bgColor = nil
  local iconButtonWidth = editor.getDefaultIconButtonSize().x

  if mode == editor.AxisGizmoMode_Translate then bgColor = im.GetStyleColorVec4(im.Col_ButtonActive) else bgColor = nil end
  if editor.uiIconImageButton(editor.icons.move, nil, nil, nil, bgColor) then
    editor.setAxisGizmoMode(editor.AxisGizmoMode_Translate)
  end
  if im.IsItemHovered() then im.BeginTooltip() im.Text("Translate (Key 1)") im.EndTooltip() end
  im.SameLine()

  if mode == editor.AxisGizmoMode_Rotate then bgColor = im.GetStyleColorVec4(im.Col_ButtonActive) else bgColor = nil end
  if editor.uiIconImageButton(editor.icons.rotate, nil, nil, nil, bgColor) then
    editor.setAxisGizmoMode(editor.AxisGizmoMode_Rotate)
  end
  if im.IsItemHovered() then im.BeginTooltip() im.Text("Rotate (Key 2)") im.EndTooltip() end
  im.SameLine()

  if mode == editor.AxisGizmoMode_Scale then bgColor = im.GetStyleColorVec4(im.Col_ButtonActive) else bgColor = nil end
  if editor.uiIconImageButton(editor.icons.scale, nil, nil, nil, bgColor) then
    editor.setAxisGizmoMode(editor.AxisGizmoMode_Scale)
  end
  if im.IsItemHovered() then im.BeginTooltip() im.Text("Scale (Key 3)") im.EndTooltip() end
  im.SameLine()

  local alignment = editor.getAxisGizmoAlignment()
  local alignIcon = nil

  if alignment == 0 then alignIcon = editor.icons.align_world end
  if alignment == 1 then alignIcon = editor.icons.align_local end

  if editor.uiIconImageButton(alignIcon) then
    if alignment == 0 then
      editor.setAxisGizmoAlignment(1)
    else
      editor.setAxisGizmoAlignment(0)
    end
  end
  if im.IsItemHovered() then im.BeginTooltip()
    if alignment == 0 then im.Text("World Coordinates (Key 4)") end
    if alignment == 1 then im.Text("Local Coordinates (Key 4)") end
    im.EndTooltip()
  end

  im.SameLine()

  -- GRID SNAPPING
  local gridSnapEnabled = editor.getPreference("snapping.general.snapToGrid")
  local gridSize = worldEditorCppApi.getGridSize()

  if gridSnapEnabled then bgColor = im.GetStyleColorVec4(im.Col_ButtonActive) else bgColor = nil end
  if editor.uiIconImageButton(editor.icons.snap_grid, nil, nil, nil, bgColor) then
    gridSnapEnabled = not gridSnapEnabled
    worldEditorCppApi.setGridSnap(gridSnapEnabled, gridSize)
    editor.setPreference("snapping.general.gridSize", gridSize)
    editor.setPreference("snapping.general.snapToGrid", gridSnapEnabled)
  end
  if im.IsItemHovered() then im.BeginTooltip() im.Text("Grid Snap. Right Click for options") im.EndTooltip() end
  im.SameLine()

  if im.IsItemHovered() and im.IsMouseClicked(1) then
    gridSnapSettingsOpen = not gridSnapSettingsOpen
  end

  im.PushItemWidth(50)
  if gridSnapComboItemCurrent[0] == -1 then
    for i, val in pairs(gridSnapWidgetsComboItemsTbl) do
      if tonumber(val) == gridSize then gridSnapComboItemCurrent[0] = i - 1 end
    end
  end
  if im.Combo1("##gridsize", gridSnapComboItemCurrent, gridSnapWidgetsComboItems) then
    local size = tonumber(gridSnapWidgetsComboItemsTbl[gridSnapComboItemCurrent[0] + 1])
    worldEditorCppApi.setGridSnap(gridSnapEnabled, size)
    editor.setPreference("snapping.general.gridSize", size)
  end
  if im.IsItemHovered() then im.SetTooltip("Grid Size") end
  im.PopItemWidth()

  im.SameLine()

  -- ROTATE SNAPPING
  local rotateSnapEnabled = editor.getPreference("snapping.general.rotateSnapEnabled")
  local rotateSnapSize = worldEditorCppApi.getRotateSnapAngle()

  if rotateSnapEnabled then bgColor = im.GetStyleColorVec4(im.Col_ButtonActive) else bgColor = nil end
  if editor.uiIconImageButton(editor.icons.snap_rotate, nil, nil, nil, bgColor) then
    rotateSnapEnabled = not rotateSnapEnabled
    worldEditorCppApi.setRotateSnap(rotateSnapEnabled, rotateSnapSize)
    editor.setPreference("snapping.general.rotateSnapSize", rotateSnapSize)
    editor.setPreference("snapping.general.rotateSnapEnabled", rotateSnapEnabled)
  end
  if im.IsItemHovered() then im.BeginTooltip() im.Text("Rotate Snap") im.EndTooltip() end
  im.SameLine()

  im.PushItemWidth(50)
  if rotateSnapComboItemCurrent[0] == -1 then
    for i, val in pairs(rotateSnapWidgetsComboItemsTbl) do
      if tonumber(val) == rotateSnapSize then rotateSnapComboItemCurrent[0] = i - 1 end
    end
  end
  if im.Combo1("##rotateSnapSize", rotateSnapComboItemCurrent, rotateSnapWidgetsComboItems) then
    local size = tonumber(rotateSnapWidgetsComboItemsTbl[rotateSnapComboItemCurrent[0] + 1])
    worldEditorCppApi.setRotateSnap(rotateSnapEnabled, size)
    editor.setPreference("snapping.general.rotateSnapSize", size)
  end
  if im.IsItemHovered() then im.SetTooltip("Rotate Snap Angle") end
  im.PopItemWidth()
  im.SameLine()

  if editor.getPreference("snapping.terrain.enabled") then bgColor = im.GetStyleColorVec4(im.Col_ButtonActive) else bgColor = nil end
  local windowPos = im.ImVec2(im.GetWindowPos().x + im.GetCursorPosX(), im.GetWindowPos().y + im.GetCursorPosY() + 30)
  if editor.uiIconImageButton(editor.icons.terrain_snap, nil, nil, nil, bgColor) then
    editor.setPreference("snapping.terrain.enabled", not editor.getPreference("snapping.terrain.enabled"))
  end
  if im.IsItemHovered() then im.SetTooltip("Toggle Terrain Snap. Right Click for options") end
  im.SameLine()

  if im.IsItemHovered() and im.IsMouseClicked(1) then
    terrainSnapSettingsOpen = not terrainSnapSettingsOpen
  end

  -- Time of Day
  if editor.uiIconImageButton(editor.icons.simobject_timeofday, im.ImVec2(iconButtonWidth, iconButtonWidth), nil, nil, nil, nil) then
    im.OpenPopup("TODCamSlidersPopup")
  end
  im.tooltip("Time Of Day Settings")

  if im.BeginPopup("TODCamSlidersPopup") then
      if im.BeginTable('TODCamSlidersTable', 2, nil) then
        im.TableSetupColumn("")
        im.TableSetupColumn("")

        im.TableNextRow()
        local tod = core_environment.getTimeOfDay()
        if tod then
          todPtr[0] = tod.time * 100
        else
          todPtr[0] = 0
          im.BeginDisabled()
        end
        im.TableSetColumnIndex(0)
        im.PushItemWidth(80)
        im.TextUnformatted("Time of day")
        im.TableSetColumnIndex(1)
        im.PushItemWidth(120)
        if editor.uiSliderFloat("##Time of day", todPtr, 0, 100, "%.1f", 1) then
          if tod then
            tod.time = todPtr[0] / 100
            core_environment.setTimeOfDay(tod)
          end
        end
        im.SameLine()
        local todTime = tod and tod.time or 0
        local seconds = ((todTime + 0.5) % 1) * 86400
        local hours = math.floor(seconds / 3600)
        local mins = math.floor(seconds / 60 - (hours * 60))
        im.Text(string.format("%02.f", hours) .. ":" .. string.format("%02.f", mins))
        if not tod then
          im.EndDisabled()
        end

        if not tod then
          im.BeginDisabled()
        end
        local now = os.date("*t")
        local dateInputWidth = 120 * im.uiscale[0]
        todYearPtr[0] = tod and (tod.year or now.year) or now.year
        todMonthPtr[0] = tod and (tod.month or now.month) or now.month
        todDayPtr[0] = tod and (tod.day or now.day) or now.day

        im.TableNextRow()
        im.TableSetColumnIndex(0)
        im.TextUnformatted("Year")
        im.TableSetColumnIndex(1)
        im.SetNextItemWidth(dateInputWidth)
        if editor.uiInputInt("##TODYear", todYearPtr, 1, 10) and tod then
          tod.year = math.max(1, math.min(9999, todYearPtr[0]))
          core_environment.setTimeOfDay(tod)
        end

        im.TableNextRow()
        im.TableSetColumnIndex(0)
        im.TextUnformatted("Month")
        im.TableSetColumnIndex(1)
        im.SetNextItemWidth(dateInputWidth)
        if editor.uiInputInt("##TODMonth", todMonthPtr, 1, 1) and tod then
          tod.month = math.max(1, math.min(12, todMonthPtr[0]))
          core_environment.setTimeOfDay(tod)
        end

        im.TableNextRow()
        im.TableSetColumnIndex(0)
        im.TextUnformatted("Day")
        im.TableSetColumnIndex(1)
        im.SetNextItemWidth(dateInputWidth)
        if editor.uiInputInt("##TODDay", todDayPtr, 1, 1) and tod then
          tod.day = math.max(1, math.min(31, todDayPtr[0]))
          core_environment.setTimeOfDay(tod)
        end
        if not tod then
          im.EndDisabled()
        end
        im.EndTable()
      end
    im.EndPopup()
  end
  im.SameLine()

  -- Auto Exposure
  if editor.uiIconImageButton(editor.icons.exposure, im.ImVec2(iconButtonWidth, iconButtonWidth), nil, nil, nil, nil) then
    im.OpenPopup("ExposureCamSlidersPopup")
  end
  im.tooltip("Exposure Settings")

  if im.BeginPopup("ExposureCamSlidersPopup") then
      if im.BeginTable('ExposureCamSlidersTable', 2, nil) then
        im.TableSetupColumn("")
        im.TableSetupColumn("")

        im.TableNextRow()
        local localExposure = scenetree.findObject("PostEffectLocalExposureObject")
        if localExposure then
          manualEVPtr[0] = localExposure.manualEV
          autoExposurePtr[0] = localExposure.autoExposure
          if initialAutoExposure == nil then
            initialAutoExposure = localExposure.autoExposure
            initialManualEV = localExposure.manualEV
          end
        else
          im.BeginDisabled()
        end
        local autoExposure = localExposure and localExposure.autoExposure
        im.TableSetColumnIndex(0)
        im.PushItemWidth(80)
        if not (autoExposure and autoExposure == true) then
          im.TextUnformatted("Manual Exposure")
        end
        im.TableSetColumnIndex(1)
        im.PushItemWidth(120)
        if not (autoExposure and autoExposure == true) then
          if editor.uiSliderFloat("##Manual Exposure", manualEVPtr, -20, 20, "%.1f", 1) then
            localExposure.manualEV = manualEVPtr[0]
          end
        end
        im.SameLine()
        if im.Checkbox("Auto exposure###autoExposure", autoExposurePtr) and localExposure then
          localExposure.autoExposure = autoExposurePtr[0]
        end
        if not localExposure then
          im.EndDisabled()
        end
        im.EndTable()
      end
    im.EndPopup()
  end
  im.SameLine()
  -- Editor icons and camera settings
  if editor.uiIconImageButton(editor.icons.photo_camera, im.ImVec2(iconButtonWidth, iconButtonWidth), nil, nil, nil, nil) then
    im.OpenPopup("EditorIconsAndCameraPopup")
  end
  im.tooltip("Editor Icons & Camera Settings")

  if im.BeginPopup("EditorIconsAndCameraPopup") then
      if im.BeginTable('EditorIconsAndCameraTable', 2, nil) then
        im.TableSetupColumn("")
        im.TableSetupColumn("")

        im.TableNextRow()
        im.TableSetColumnIndex(0)
        if not editor.disableModifyFadeIconsDistance then
          FadeIconsPtr[0] = editor.getPreference("gizmos.objectIcons.fadeIconsDistance")
          if editor.getPreference("gizmos.objectIcons.fadeIconsDistance") ~= FadeIconsPtr[0] then
            editor.setPreference("gizmos.objectIcons.fadeIconsDistance", FadeIconsPtr[0])
          end
        end
        im.PushItemWidth(100)
        im.TextUnformatted("Icons Distance")
        im.TableSetColumnIndex(1)
        im.PushItemWidth(120)
        if editor.uiSliderFloat("##Icons Distance", FadeIconsPtr, 100, 500, "%.0f") then
          editor.setPreference("gizmos.objectIcons.fadeIconsDistance", FadeIconsPtr[0])
        end
        im.tooltip("Adjust icons visibility (CTRL + Scroll Wheel)")

        im.TableNextRow()
        im.TableSetColumnIndex(0)
        if not editor.keyModifiers.shift then
          camSpeedPtr[0] = core_camera.getSpeed()
          if editor.getPreference("camera.general.freeCameraMoveSpeed") ~= camSpeedPtr[0] then
            editor.setPreference("camera.general.freeCameraMoveSpeed", camSpeedPtr[0])
          end
        end
        im.PushItemWidth(100)
        im.TextUnformatted("Camera Speed")
        im.TableSetColumnIndex(1)
        im.PushItemWidth(120)
        if editor.uiSliderFloat("##Camera Speed", camSpeedPtr, 2, 100, "%.1f") then
          editor.setCameraSpeed(camSpeedPtr[0])
          editor.setPreference("camera.general.freeCameraMoveSpeed", camSpeedPtr[0])
        end
        im.tooltip("Adjust camera speed (Alt + Scroll Wheel)")

        im.EndTable()
      end
    im.EndPopup()
  end

  im.SameLine()
  if terrainSnapSettingsOpen then
    im.SetNextWindowPos(windowPos, im.Cond_Appearing)
    local wndOpen = im.BoolPtr(terrainSnapSettingsOpen)
    im.Begin("Terrain Snap Settings", wndOpen, im.WindowFlags_NoCollapse)
    local relRotation = im.BoolPtr(editor.getPreference("snapping.terrain.relRotation"))
    if im.Checkbox("Keep relative rotation", relRotation) then
      editor.setPreference("snapping.terrain.relRotation", relRotation[0])
    end
    local individual = im.BoolPtr(editor.getPreference("snapping.terrain.indObjects"))
    if im.Checkbox("Treat objects individually", individual) then
      editor.setPreference("snapping.terrain.indObjects", individual[0])
    end
    local useRaycast = im.BoolPtr(editor.getPreference("snapping.terrain.useRayCast"))
    if im.Checkbox("Use raycast", useRaycast) then
      editor.setPreference("snapping.terrain.useRayCast", useRaycast[0])
    end

    local snapModeRadioValue
    if editor.getPreference("snapping.terrain.snapToCenter") then snapModeRadioValue = im.IntPtr(1)
    elseif editor.getPreference("snapping.terrain.snapToBB") then snapModeRadioValue = im.IntPtr(2)
    elseif editor.getPreference("snapping.terrain.keepHeight") then snapModeRadioValue = im.IntPtr(3)
    else snapModeRadioValue = im.IntPtr(0) end
    if im.RadioButton2("Snap to Origin", snapModeRadioValue, im.Int(0)) then
      editor.setPreference("snapping.terrain.snapToCenter", false)
      editor.setPreference("snapping.terrain.snapToBB", false)
      editor.setPreference("snapping.terrain.keepHeight", false)
    end
    if im.RadioButton2("Snap to Center", snapModeRadioValue, im.Int(1)) then
      editor.setPreference("snapping.terrain.snapToCenter", true)
      editor.setPreference("snapping.terrain.snapToBB", false)
      editor.setPreference("snapping.terrain.keepHeight", false)
    end
    if im.RadioButton2("Snap to Bounding Box", snapModeRadioValue, im.Int(2)) then
      editor.setPreference("snapping.terrain.snapToCenter", false)
      editor.setPreference("snapping.terrain.snapToBB", true)
      editor.setPreference("snapping.terrain.keepHeight", false)
    end
    if im.RadioButton2("Keep height", snapModeRadioValue, im.Int(3)) then
      editor.setPreference("snapping.terrain.snapToCenter", false)
      editor.setPreference("snapping.terrain.snapToBB", false)
      editor.setPreference("snapping.terrain.keepHeight", true)
    end
    im.End()
    if not wndOpen[0] then
      terrainSnapSettingsOpen = false
    end
  end

  if gridSnapSettingsOpen then
    im.SetNextWindowPos(windowPos, im.Cond_Appearing)
    local wndOpen = im.BoolPtr(gridSnapSettingsOpen)
    im.Begin("Grid Snap Settings", wndOpen, im.WindowFlags_NoCollapse)
    local useLastObject = im.BoolPtr(editor.getPreference("snapping.grid.useLastObjectSelected"))
    if im.Checkbox("Use the last object selected as the reference object", useLastObject) then
      editor.setPreference("snapping.grid.useLastObjectSelected", useLastObject[0])
    end
    im.End()
    if not wndOpen[0] then
      gridSnapSettingsOpen = false
    end
  end
end

local function drawAlwaysVisibleToolbars()
  for key, val in pairs(editor.editModes) do
    if val["toolbarAlwaysVisible"] and val.onToolbar then
      val.onToolbar()
    end
  end
end

local function toolbarAlwaysVisibleModeExists()
  for key, val in pairs(editor.editModes) do
    if val["toolbarAlwaysVisible"] and val.onToolbar then
      return true
    end
  end
  return false
end

local function createAllEditModesList()
  local sortedKeys = {}
  for key, val in pairs(editor.editModes) do
    if key ~= "objectSelect" and key ~= "createObject" and val.icon then table.insert(sortedKeys, key) end
  end

  local function sorter(a, b)
    local ord1 = editor.editModes[a].sortOrder
    local ord2 = editor.editModes[b].sortOrder
    return ord1 < ord2
  end

  -- first sort by name
  table.sort(sortedKeys)

  -- assign a default sort order (index of editMode) to the ones that dont have one
  local idx = 1
  for _, key in pairs(sortedKeys) do
    if key ~= "objectSelect" and key ~= "createObject" then
      if nil == editor.editModes[key].sortOrder then
        editor.editModes[key].sortOrder = idx
      end
    end
    idx = idx + 1
  end
  -- second sort by sort order (if available)
  table.sort(sortedKeys, sorter)

  -- we always want object select to be first edit mode and object create right after it
  table.insert(sortedKeys, 1, "objectSelect")
  table.insert(sortedKeys, 2, "createObject")

  return sortedKeys
end

local function getModeKeyWithDisplayName(displayName)
  for key, val in pairs(editor.editModes) do
    if val.displayName == displayName then
      return key
    end
  end
  return nil
end

-- Function to get modes from current edit mode set
local function getModesFromCurrentSet()
  local currentSet = editModeSets[selectedSetIndex]
  if not currentSet or not currentSet.modes or #currentSet.modes == 0 then
    -- if no modes selected or current set is empty, use All
    currentSet = nil
    for _, set in ipairs(editModeSets) do
      if set.name == allEditModesListName then
        currentSet = set
        break
      end
    end
  end

  if not currentSet or not currentSet.modes then
    return {}
  end

  local setModes = {}
  for _, modeName in ipairs(currentSet.modes) do
    -- Find the mode key by display name
    for key, val in pairs(editor.editModes) do
      if val.displayName == modeName then
        -- Skip object select since we already added it first
        if key ~= "objectSelect" then
          table.insert(setModes, key)
        end
        break
      end
    end
  end
  return setModes
end

local function onEditorGuiToolBar()
  if editor.headless then return end
  -- no menu, dont show toolbars
  if not editor.menuHeight then return end

  im.PushStyleColor2(im.Col_Button, im.ImVec4(0,0,0,0))
  if editor.beginWindow(toolbarWindowName, "Main Toolbar", nil, true) then
    drawGeneralToolbarButtons()
    im.SameLine() im.Spacing()
    editor.uiVertSeparator(32, im.ImVec2(0,0))
    im.Spacing() im.SameLine()
    axisGizmoButtonsGui()
    im.SameLine() im.Spacing()
    editor.uiVertSeparator(32, im.ImVec2(0,0))
    im.Spacing()
    extensions.hook("onEditorGuiGeneralToolbar")
    im.SameLine()
    local iconButtonWidth = editor.getDefaultIconButtonSize().x*im.uiscale[0] + 6 + 2*im.GetStyle().FramePadding.x + im.GetStyle().ItemSpacing.x
    local widthLeftToolBar = im.GetContentRegionAvailWidth()-iconButtonWidth*1.5
    local maxNumEditModesToShow = 0
    if widthLeftToolBar >= iconButtonWidth then
      maxNumEditModesToShow = math.floor(widthLeftToolBar/iconButtonWidth)
    end

    if not allModesPopulated then
      allModesPopulated = true
      allModes = {}
      for key, val in pairs(editor.editModes) do
        if val.icon and key ~= "objectSelect" and key ~= "createObject" then
          table.insert(allModes, {
            name = val.iconTooltip,
            key = key,
            selected = false,
          })
        end
      end
    end

    -- EDIT MODE SELECTION BUTTON
    local popupOpen = im.IsPopupOpen("EditModeSetsPopup")
    local icon = popupOpen and editor.icons.keyboard_arrow_down or editor.icons.menu
    if editor.uiIconImageButton(icon, im.ImVec2(editor.getDefaultIconButtonSize().x, editor.getDefaultIconButtonSize().y), nil, nil, nil) then
      im.OpenPopup("EditModeSetsPopup")
    end

    if im.IsItemHovered() then im.BeginTooltip() im.Text("Select Edit Mode Set") im.EndTooltip() end

    -- Edit Mode Sets popup
    im.SetNextWindowSizeConstraints(im.ImVec2(200, 300), im.ImVec2(400, 600))
    im.SetNextWindowSize(im.ImVec2(0, 0), im.Cond_Always)
    if im.BeginPopup("EditModeSetsPopup", im.WindowFlags_NoCollapse) then
      im.Spacing()

      -- List of edit mode sets
      for i, set in ipairs(editModeSets) do
        local bgColor = i == selectedSetIndex and buttonColor_active or buttonColor_inactive
        im.PushStyleColor2(im.Col_Header, bgColor)
        if im.Selectable1(set.name .. "##editModeSetPopup_" .. i, i == selectedSetIndex) then
          loadModesFromSet(i)
        end
        im.PopStyleColor()
      end

      im.Spacing()
      im.Spacing()
      im.Separator()
      im.Spacing()
      if im.Button("Edit Sets...") then
        availableModesList = {}
        selectedModesList = {}
        modesManagerOpen[0] = true
        im.CloseCurrentPopup()
      end
      im.EndPopup()
    end

    if modesManagerOpen[0] then
      if selectedSetIndex and not tableIsEmpty(getModesFromSet(selectedSetIndex)) then
        loadModesFromSet(selectedSetIndex)
      end
      modesManagerOpen[0] = false
      im.OpenPopup("CustomizeToolbarLayout")
    end

    im.SetNextWindowSize(im.ImVec2(900, 500), im.Cond_FirstUseEver)
    if im.BeginPopup("CustomizeToolbarLayout", 0) then
      -- Left panel (Edit Mode Sets)
      im.BeginGroup()
      if im.Button("New Set") then
        local newSetName = string.format("Edit Mode Set %d", #editModeSets + 1)
        addEditModeSet(newSetName)
        selectedSetIndex = #editModeSets
        loadModesFromSet(selectedSetIndex)
      end
      im.SameLine()

      -- disable delete button for All
      local currentSet = editModeSets[selectedSetIndex]
      local isDefaultSet = currentSet and currentSet.name == allEditModesListName
      if isDefaultSet then im.BeginDisabled() end
      if im.Button("Delete Set") then
        deleteEditModeSet(selectedSetIndex)
        loadModesFromSet(selectedSetIndex)
      end
      if isDefaultSet then im.EndDisabled() end

      im.BeginChild1("EditModeSets", im.ImVec2(200, 400), true)
      for i, set in ipairs(editModeSets) do
        if set.name == allEditModesListName then
          goto continue
        end
        if i == editingSetIndex then
          -- Show text input when editing
          im.PushItemWidth(-1)
          if im.InputText("##SetName" .. i, editingSetName, 32, im.InputTextFlags_EnterReturnsTrue) then
            finishEditingSetName()
          end
          im.PopItemWidth()

          -- Handle focus loss or Escape to cancel editing
          if not im.IsItemActive() and (im.IsMouseClicked(0) or im.IsKeyPressed(im.Key_Escape)) then
            finishEditingSetName()
          end
        else
          -- Show selectable when not editing
          local bgColor = i == selectedSetIndex and buttonColor_active or buttonColor_inactive
          im.PushStyleColor2(im.Col_Header, bgColor)
          if im.Selectable1(set.name .. "##editModeSetList_" .. i, i == selectedSetIndex) then
            loadModesFromSet(i)
          end
          im.PopStyleColor()

          -- Handle double-click to start editing
          if im.IsItemHovered() and im.IsMouseDoubleClicked(0) then
            startEditingSetName(i)
          end
        end
        ::continue::
      end
      im.EndChild()
      im.EndGroup()

      im.SameLine()
      im.BeginGroup()
      -- Right panel header


      im.BeginGroup()

      -- Function to search for a key in selected modes list
      local function findKeyInSelectedModes(key)
        for _, mode in ipairs(selectedModesList) do
          if mode.key == key then
            return true
          end
        end
        return false
      end

      if selectedSetIndex >= 2 then
        local allModesCount = allModes and #allModes or 0
        local selectedModesCount = selectedModesList and #selectedModesList or 0
        im.Text("Available Modes (" .. (allModesCount - selectedModesCount) .. ")")
      else
        im.Text("Available Modes")
      end
      im.BeginChild1("AvailableModes", im.ImVec2(250, 320), true)

      -- don't show available modes for All
      if selectedSetIndex > 1 then
        for i, mode in ipairs(allModes) do
          if findKeyInSelectedModes(mode.key) then
            goto continue
          end
          local bgColor = mode.selected and buttonColor_active or buttonColor_inactive
          im.PushStyleColor2(im.Col_Header, bgColor)
          if im.Selectable1(mode.name .. "##availableMode_" .. (mode.key or i), mode.selected) then
            mode.selected = not mode.selected
          end
          im.PopStyleColor()
          ::continue::
        end
      end
      im.EndChild()

      -- Deselect All button for available modes
      im.Spacing()
      local anyModeSelected = false
      for _, mode in ipairs(allModes) do
        if mode.selected then
          anyModeSelected = true
          break
        end
      end

      if not anyModeSelected then im.BeginDisabled() end
      if im.Button("Deselect All##Available", im.ImVec2(120, 25)) then
        deselectAllAvailableModes()
      end
      if im.IsItemHovered() then im.BeginTooltip() im.Text("Deselect all available modes") im.EndTooltip() end
      if not anyModeSelected then im.EndDisabled() end

      im.EndGroup()
      im.SameLine()

      -- Middle section with arrow buttons
      im.BeginGroup()
      im.Dummy(im.ImVec2(0, 80)) -- Spacing to center buttons vertically

      -- disable all mode management buttons for All
      local currentSet = editModeSets[selectedSetIndex]
      local isDefaultSet = currentSet and currentSet.name == allEditModesListName
      if isDefaultSet then im.BeginDisabled() end

      -- Move all to right
      if editor.uiIconImageButton(editor.icons.fast_forward, im.ImVec2(editor.getDefaultIconButtonSize().x, editor.getDefaultIconButtonSize().y)) then
        -- Move all items to selected list
        for _, mode in ipairs(allModes) do
          if not findKeyInSelectedModes(mode.key) then
            table.insert(selectedModesList, {name = mode.name, key = mode.key, selected = false})
          end
        end
        -- Save changes to current set
        saveModesToSet()
      end
      im.tooltip("Move All To Right")
      im.Spacing()

      -- Move selected to right
      if not anyModeSelected then im.BeginDisabled() end
      if editor.uiIconImageButton(editor.icons.arrow_forward, im.ImVec2(editor.getDefaultIconButtonSize().x, editor.getDefaultIconButtonSize().y)) then
        -- Add selected modes
        for i, mode in ipairs(allModes) do
          if mode.selected then
            table.insert(selectedModesList, {name = mode.name, key = mode.key, selected = false})
            mode.selected = false
          end
        end
        -- Save changes to current set
        saveModesToSet()
      end
      if not anyModeSelected then im.EndDisabled() end
      im.tooltip("Move Selected To Right")
      im.Spacing()
      -- Check if any items are selected in selected list
      local hasSelectedSelected = false
      for _, mode in ipairs(selectedModesList) do
        if mode.selected then
          hasSelectedSelected = true
          break
        end
      end

      -- Move selected to left
      if not hasSelectedSelected then im.BeginDisabled() end
      if editor.uiIconImageButton(editor.icons.arrow_back, im.ImVec2(editor.getDefaultIconButtonSize().x, editor.getDefaultIconButtonSize().y)) then
        -- First find indices to remove
        local indicesToRemove = {}
        for i, mode in ipairs(selectedModesList) do
          if mode.selected then
            table.insert(availableModesList, {name = mode.name, selected = false})
            table.insert(indicesToRemove, i)
          end
        end

        -- Then remove from highest index to lowest to avoid shifting issues
        for i = #indicesToRemove, 1, -1 do
          table.remove(selectedModesList, indicesToRemove[i])
        end
        -- Save changes to current set
        saveModesToSet()
      end
      if not hasSelectedSelected then im.EndDisabled() end
      im.tooltip("Move Selected To Left")
      im.Spacing()

      -- Move all to left
      if editor.uiIconImageButton(editor.icons.fast_rewind, im.ImVec2(editor.getDefaultIconButtonSize().x, editor.getDefaultIconButtonSize().y)) then
        -- Move all items to available list
        for _, mode in ipairs(selectedModesList) do
          if not findKeyInSelectedModes(mode.key) then
            table.insert(availableModesList, {name = mode.name, selected = false})
          end
        end
        -- Clear the selected list
        for k in pairs(selectedModesList) do selectedModesList[k] = nil end
        -- Save changes to current set
        saveModesToSet()
      end
      im.tooltip("Move All To Left")

      -- end disabled state for All
      if isDefaultSet then im.EndDisabled() end

        im.EndGroup()
        im.SameLine()

        -- Right column (Selected Modes)
        im.BeginGroup()
        if selectedSetIndex >= 2 then
          im.Text("Selected Modes (" .. #selectedModesList .. ")")
        else
          im.Text("Selected Modes")
        end
        im.BeginChild1("SelectedModes", im.ImVec2(250, 320), true)
      -- dont show available modes for All
        if selectedSetIndex > 1 then
          for i, mode in ipairs(selectedModesList) do
            local bgColor = mode.selected and buttonColor_active or buttonColor_inactive
            im.PushStyleColor2(im.Col_Header, bgColor)
            if im.Selectable1(mode.name .. "##selectedMode_" .. (mode.key or i), mode.selected) then
              deselectAllSelectedModes()
              mode.selected = true
            end
            im.PopStyleColor()
          end
        end
        im.EndChild()

        -- Up/Down arrow buttons for reordering
        im.Spacing()

        -- Check if buttons should be enabled
        local canMoveUpEnabled = canMoveUp()
        local canMoveDownEnabled = canMoveDown()

        -- Up button
        if not canMoveUpEnabled then im.BeginDisabled() end
        if editor.uiIconImageButton(editor.icons.arrow_upward, im.ImVec2(editor.getDefaultIconButtonSize().x, editor.getDefaultIconButtonSize().y)) then
          moveSelectedModesUp()
        end
        if im.IsItemHovered() then
          im.BeginTooltip()
          if canMoveUpEnabled then
            im.Text("Move selected modes up")
          else
            im.Text("Select continuous items to move up")
          end
          im.EndTooltip()
        end
        if not canMoveUpEnabled then im.EndDisabled() end

        im.SameLine()

        -- Down button
        if not canMoveDownEnabled then im.BeginDisabled() end
        if editor.uiIconImageButton(editor.icons.arrow_downward, im.ImVec2(editor.getDefaultIconButtonSize().x, editor.getDefaultIconButtonSize().y)) then
          moveSelectedModesDown()
        end
        if im.IsItemHovered() then
          im.BeginTooltip()
          if canMoveDownEnabled then
            im.Text("Move selected modes down")
          else
            im.Text("Select continuous items to move down")
          end
          im.EndTooltip()
        end
        if not canMoveDownEnabled then im.EndDisabled() end

        -- Deselect All button for selected modes
        im.Spacing()
        local hasSelectedSelected = false
        for _, mode in ipairs(selectedModesList) do
          if mode.selected then
            hasSelectedSelected = true
            break
          end
        end

        if not hasSelectedSelected then im.BeginDisabled() end
        if im.Button("Deselect All##Selected", im.ImVec2(120, 25)) then
          deselectAllSelectedModes()
        end
        if im.IsItemHovered() then im.BeginTooltip() im.Text("Deselect all selected modes") im.EndTooltip() end
        if not hasSelectedSelected then im.EndDisabled() end

        im.EndGroup()

        im.EndGroup() -- End right panel group

        -- Bottom buttons
        im.Spacing()
        im.Separator()
      im.Spacing()
      if im.Button("Close", im.ImVec2(120, 0)) then
        modesManagerOpen[0] = false
        im.CloseCurrentPopup()
        saveModesToSet()
      end
      im.EndPopup()
    end

    im.SameLine()

    -- EDIT MODE BUTTONS
    if editor.editModes then
      im.SameLine()
      local sortedKeys = {}

      if selectedSetIndex ~= 1 then
        sortedKeys = getModesFromSet(selectedSetIndex)
      else
        sortedKeys = createAllEditModesList()
      end

      local numIconsLeftToShow = maxNumEditModesToShow
      local numEditModes = 0

      for _, key in ipairs(sortedKeys) do
        local val = editor.editModes[key]
        if val and val.icon then
          numEditModes = numEditModes + 1
        end
      end

      local isSelectedModeShownOnToolbar = false

      for _, key in ipairs(sortedKeys) do
        if numIconsLeftToShow <= 0 then
          break
        end

        local val = editor.editModes[key]

        if val and val.icon then
          numIconsLeftToShow = numIconsLeftToShow - 1

          if val == editor.editMode then
            isSelectedModeShownOnToolbar = true
          end
        end
      end

      numIconsLeftToShow = maxNumEditModesToShow
      local skippedEditMode = nil
      for _, key in ipairs(sortedKeys) do
        local breakIndex = isSelectedModeShownOnToolbar and 0 or 1
        if numIconsLeftToShow <= breakIndex then
          skippedEditMode = editor.editModes[key]
          break
        end
        local val = editor.editModes[key]
        if val and val.icon then
          local bgColor = nil

          if editor.editMode == val then
            bgColor = im.GetStyleColorVec4(im.Col_ButtonActive)
          end
          numIconsLeftToShow = numIconsLeftToShow - 1

          local pos = im.GetCursorPos()
          im.SetCursorPos(im.ImVec2(pos.x + 6, pos.y))
          local pushedModeBtn = editor.uiIconImageButton(val.icon, nil, nil, nil, bgColor,nil, nil, nil, true)

          if pushedModeBtn and val ~= editor.editMode then
            editor.selectEditMode(val)
          elseif pushedModeBtn then
            editor.selectEditMode(editor.editModes.objectSelect)
          end

          if pushedModeBtn then
            for _, val in pairs(editor.editModes) do
              -- toolbar is always visible in create mode
              local isVisible = editor.editMode == editor.editModes.createObject and val == editor.editMode
              val["toolbarAlwaysVisible"] = isVisible
            end
          end

          if val.iconTooltip and im.IsItemHovered() then
            im.BeginTooltip()
            im.Text(val.iconTooltip)
            im.EndTooltip()
          end
          im.SameLine()
        end
      end

      --Add the selected edit mode as the last icon on the toolbar
      for _, key in ipairs(sortedKeys) do
        local val = editor.editModes[key]
        if val and val.icon and val == editor.editMode and not isSelectedModeShownOnToolbar then
          local bgColor = nil
          if editor.editMode == val then
            bgColor = im.GetStyleColorVec4(im.Col_ButtonActive)
          end
          numIconsLeftToShow = numIconsLeftToShow - 1
          local pushedModeBtn = editor.uiIconImageButton(val.icon, nil, nil, nil, bgColor, nil, nil ,nil, true)

          if pushedModeBtn and val ~= editor.editMode then
            editor.selectEditMode(val)
          elseif pushedModeBtn then
            editor.selectEditMode(editor.editModes.objectSelect)
          end

          if pushedModeBtn then
            for _, val in pairs(editor.editModes) do
              -- toolbar is always visible in create mode
              local isVisible = editor.editMode == editor.editModes.createObject and val == editor.editMode
              val["toolbarAlwaysVisible"] = isVisible
            end
          end

          if val.iconTooltip and im.IsItemHovered() then
            im.BeginTooltip()
            im.Text(val.iconTooltip)
            im.EndTooltip()
          end
          im.SameLine()
          break
        end
      end

      if maxNumEditModesToShow < numEditModes then
          if editor.uiIconImageButton(editor.icons.fast_forward, im.ImVec2(editor.getDefaultIconButtonSize().x/2.0, editor.getDefaultIconButtonSize().y), nil, nil, nil, nil) then
            im.OpenPopup("EditModePopup")
          end
      end

      if im.BeginPopup("EditModePopup") then
        local index = 0
        local bgColor = nil
        local buttonWidthMax = 0
        local buttonWidth = editor.getDefaultIconButtonSize().x
        if editor.editMode == skippedEditMode then
          bgColor = im.GetStyleColorVec4(im.Col_ButtonActive)
        end

        if skippedEditMode and skippedEditMode.icon and editor.editMode == skippedEditMode then
          im.SetCursorPosY(im.GetCursorPosY() + 5)
          editor.uiIconImage(skippedEditMode.icon, im.ImVec2(iconButtonWidth*0.9, iconButtonWidth*0.9), bgColor)
          im.SameLine()

          if im.Button(skippedEditMode.iconTooltip .. "##skippedEditMode", im.ImVec2(120, iconButtonWidth)) and skippedEditMode ~= editor.editMode then
            editor.selectEditMode(skippedEditMode)
          end
        end

        local uiScaling = editor.getPreference("ui.general.scale") or 1.0;
        for _, key in ipairs(sortedKeys) do
          local val = editor.editModes[key]
          if index < maxNumEditModesToShow - (isSelectedModeShownOnToolbar and 0 or 1) then
            goto continue
          end
          if val and val.iconTooltip then
            local textSize = (im.CalcTextSize(val.iconTooltip).x)*uiScaling+im.GetStyle().FramePadding.x*2
            if textSize > buttonWidthMax then
              buttonWidthMax = textSize
            end
          end
          ::continue::
        end

        for _, key in ipairs(sortedKeys) do
          local val = editor.editModes[key]
          local bgColor = nil
          if editor.editMode == val then
            bgColor = im.GetStyleColorVec4(im.Col_ButtonActive)
          end
          if index < maxNumEditModesToShow - (isSelectedModeShownOnToolbar and 0 or 1) then
            goto continue
          end
          if val and val.icon then
            im.SetCursorPosY(im.GetCursorPosY() + 3)
            editor.uiIconImage(val.icon, im.ImVec2(buttonWidth*uiScaling*0.9, buttonWidth*uiScaling*0.9), bgColor)
            im.SameLine()
            im.SetCursorPosY(im.GetCursorPosY() + 3)
            if im.Selectable1(val.iconTooltip .. "##editModePopup_" .. key, false, nil, im.ImVec2(buttonWidthMax, buttonWidth*uiScaling)) and val ~= editor.editMode then
              editor.selectEditMode(val)
            end
          end
          ::continue::
          index = index + 1
        end
        im.EndPopup()
      end

      im.SameLine() im.Spacing()
      editor.uiVertSeparator(32, im.ImVec2(0,0))

      extensions.hook("onEditorGuiEditModesToolbar")
    end
    local noDisplay = false
    if editor.editMode and editor.getPreference("ui.general.singleLineToolbar") then
      if not editor.editMode.onToolbar and not toolbarAlwaysVisibleModeExists() then
        noDisplay = true
        goto finishWindow
      end

      editor.uiVertSeparator(editor.getPreference("ui.general.iconButtonSize"), im.ImVec2(0,0))
      drawAlwaysVisibleToolbars()
      --Draw Current Mode's toolbar if not already drawn.
      if not editor.editMode["toolbarAlwaysVisible"] and editor.editMode.onToolbar then
        editor.editMode.onToolbar()
      end
      extensions.hook("onEditorGuiEditModeToolbar")
      im.SameLine()
    end
    local minToolbarWidth = 550 * (1+im.uiscale[0])/2
    local trailingSpacerWidth = im.GetContentRegionAvailWidth() - minToolbarWidth
    if trailingSpacerWidth > 0 then
      im.Dummy(im.ImVec2(trailingSpacerWidth, 0))
    end
  end
  ::finishWindow::
  editor.endWindow()
  if noDisplay then
    goto safeFinish
  end

  if editor.editMode and not editor.getPreference("ui.general.singleLineToolbar") then
    if not editor.editMode.onToolbar and not toolbarAlwaysVisibleModeExists() then
      goto safeFinish
    end
    --TODO: replace with begin/endWindow
    im.Begin("Toolbar2", nil, toolbarFlags)
    drawAlwaysVisibleToolbars()
    --Draw Current Mode's toolbar if not already drawn.
    if not editor.editMode["toolbarAlwaysVisible"] and editor.editMode.onToolbar then
      editor.editMode.onToolbar()
    end
    extensions.hook("onEditorGuiEditModeToolbar")
    im.End()
  end
  ::safeFinish::
  im.PopStyleColor()
end

local function onEditorInitialized()
  editor.registerWindow(toolbarWindowName)
  editor.showWindow(toolbarWindowName)
  -- Load edit mode sets from file
  loadEditModeSets()
end

local function onEditorPreferenceValueChanged(path, value)
  if path == "ui.general.enableVehicleControls" then
    for _, mapName in ipairs(vehicleActionMaps) do
      local map = scenetree.findObject(mapName)
      if map then
        map:setEnabled(editor.getPreference("ui.general.enableVehicleControls"))
      end
    end
  end
end

local function onEditorSaveState(state)
end

local function onEditorLoadState(state)
end

local function onEditorDeactivated()
  local localExposure = scenetree.findObject("PostEffectLocalExposureObject")
  if localExposure then
    if initialAutoExposure ~= nil then
      localExposure.autoExposure = initialAutoExposure
      localExposure.manualEV = initialManualEV
    end
  end
  initialAutoExposure = nil
  initialManualEV = nil
end

M.onEditorGuiToolBar = onEditorGuiToolBar
M.onEditorInitialized = onEditorInitialized
M.onEditorPreferenceValueChanged = onEditorPreferenceValueChanged
M.onEditorSaveState = onEditorSaveState
M.onEditorLoadState = onEditorLoadState
M.onEditorDeactivated = onEditorDeactivated

return M