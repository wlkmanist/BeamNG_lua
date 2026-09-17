-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local constants = require('/lua/ge/extensions/editor/dragRaceEditor/constants')
local state = require('/lua/ge/extensions/editor/dragRaceEditor/state')
local utils = require('/lua/ge/extensions/editor/dragRaceEditor/utils')
local strips = require('/lua/ge/extensions/editor/dragRaceEditor/strips')
local dragSettings = require('/lua/ge/extensions/editor/dragRaceEditor/dragSettings')
local zones = require('/lua/ge/extensions/editor/dragRaceEditor/zones')
local input = require('/lua/ge/extensions/editor/dragRaceEditor/input')

local M = {}
local im = ui_imgui
local ffi = require('ffi')
local dragSaveSystem = require('/lua/ge/extensions/gameplay/drag/saveSystem')

local function drawFileMenu()
  if im.BeginMenu("File") then
    if im.MenuItem1("Save All") then
      local savedCount = 0

      local allStrips = strips.getAllStrips()
      for _, strip in ipairs(allStrips) do
        if strip._dirty then
          if strips.saveStrip(strip) then
            savedCount = savedCount + 1
          end
        end
      end

      local allSettings = dragSettings.getAllSettings()
      for _, settingsFile in ipairs(allSettings) do
        if settingsFile._dirty then
          if dragSettings.saveDragSettings(settingsFile.path) then
            savedCount = savedCount + 1
          end
        end
      end

      if savedCount > 0 then
        log('D', 'drag_race_editor', 'Saved ' .. savedCount .. ' items')
        utils.clearUnsavedChanges()
      else
        log('D', 'drag_race_editor', 'No dirty items to save')
      end
    end

    im.Separator()

    if im.MenuItem1("Clear All") then
      local removedCount = 0

      local allStrips = strips.getAllStrips()
      local currentStripIndex = strips.getSelectedStripIndex()
      for i = #allStrips, 1, -1 do
        local strip = allStrips[i]
        if strip and strip._dirty then
          if i == currentStripIndex then
            strips.setSelectedStripIndex(-1)
          end
          table.remove(allStrips, i)
          removedCount = removedCount + 1
          if currentStripIndex > i then
            currentStripIndex = currentStripIndex - 1
            strips.setSelectedStripIndex(currentStripIndex)
          end
        end
      end

      local allSettings = dragSettings.getAllSettings()
      local currentSettingsIndex = dragSettings.getSelectedSettingsIndex()
      for i = #allSettings, 1, -1 do
        local settingsFile = allSettings[i]
        if settingsFile and settingsFile._dirty then
          if i == currentSettingsIndex then
            dragSettings.setSelectedSettingsIndex(-1)
          end
          table.remove(allSettings, i)
          removedCount = removedCount + 1
          if currentSettingsIndex > i then
            currentSettingsIndex = currentSettingsIndex - 1
            dragSettings.setSelectedSettingsIndex(currentSettingsIndex)
          end
        end
      end

      if removedCount > 0 then
        log('D', 'drag_race_editor', 'Removed ' .. removedCount .. ' unsaved items')
        utils.clearUnsavedChanges()
      else
        log('D', 'drag_race_editor', 'No unsaved items to remove')
      end
    end

    im.Separator()

    if im.MenuItem1("Refresh Editor") then
      log('D', 'drag_race_editor', 'Refreshing editor - reloading all files')
      strips.loadAllStrips()
      dragSettings.loadAllSettings()
      log('D', 'drag_race_editor', 'Editor refresh complete')
    end

    im.EndMenu()
  end
end

local function drawMenuBar()
  if im.BeginMenuBar() then
    drawFileMenu()
    im.EndMenuBar()
  end
end

local dragEditorDataLoaded = false
local zoneEditor = zones.init()
local lastZoneEditTarget = nil

local DRAG_ZONE_EDIT_MODE_NAME = "Edit Drag Zone"

local function getSelectedZoneTarget()
  return state.getZoneEditTarget()
end

--- Like crawl drawBoundariesAlways: keep zone editor in sync with selection (and switch zone when target changes).
local function drawZonesAlways()
  if not editor.editMode or editor.editMode.displayName ~= DRAG_ZONE_EDIT_MODE_NAME then return end
  local target = getSelectedZoneTarget()
  if not target then return end
  if target ~= lastZoneEditTarget then
    zoneEditor:syncBack()
    zoneEditor:clearZone()
    lastZoneEditTarget = target
    local zoneData = (target.type == 'stripZone' and target.strip and target.strip.stripZone)
      or (target.type == 'laneZone' and target.lane and target.lane.zone)
    if zoneData then
      local zoneInstance = zones.zoneFromData(zoneData)
      if zoneInstance then
        zoneEditor:setZone(zoneInstance, target)
      end
    end
  end
end

local function onDragZoneEditModeActivate()
  editor.clearObjectSelection()
  local target = getSelectedZoneTarget()
  if not target then return end
  local zoneData = (target.type == 'stripZone' and target.strip and target.strip.stripZone)
    or (target.type == 'laneZone' and target.lane and target.lane.zone)
  if not zoneData then return end
  local zoneInstance = zones.zoneFromData(zoneData)
  if zoneInstance then
    zoneEditor:setZone(zoneInstance, target)
    lastZoneEditTarget = target
  end
end

local function onDragZoneEditModeDeactivate()
  zoneEditor:syncBack()
  zoneEditor:clearZone()
  lastZoneEditTarget = nil
  state.setZoneEditTarget(nil)
  state.setZoneEditPreviousEditMode(nil)
  editor.clearObjectSelection()
end

local function onDragZoneEditModeUpdate()
  local target = getSelectedZoneTarget()
  if not target then return end
  if not zoneEditor.zone then return end
  input.updateMouseInfo()
  local mouseInfo = input.getMouseInfo()
  zoneEditor:draw(mouseInfo)
end

local function onEditorInitialized()
  editor.registerWindow(constants.CONSTANTS.WINDOW_NAME, im.ImVec2(constants.CONSTANTS.WINDOW_SIZE.x, constants.CONSTANTS.WINDOW_SIZE.y))
  editor.addWindowMenuItem("Drag Race Editor", function() M.show() end, {groupMenuName="Gameplay"})

  if state.getDragRaceData() == nil then
    state.setDragRaceData(utils.createNewDragRaceData())
  end

  editor.editModes.dragZoneEditMode = {
    displayName = DRAG_ZONE_EDIT_MODE_NAME,
    onUpdate = onDragZoneEditModeUpdate,
    onActivate = onDragZoneEditModeActivate,
    onDeactivate = onDragZoneEditModeDeactivate,
    auxShortcuts = {},
    icon = editor.icons and editor.icons.tb_zone or nil,
    iconTooltip = "Drag Zone Editor",
    hideObjectIcons = true
  }
  editor.editModes.dragZoneEditMode.auxShortcuts[bit.bor(editor.AuxControl_LMB, editor.AuxControl_Shift)] = "Add zone vertex"
  editor.editModes.dragZoneEditMode.auxShortcuts[bit.bor(editor.AuxControl_LMB, editor.AuxControl_Alt)] = "Insert vertex between"
  editor.editModes.dragZoneEditMode.auxShortcuts[bit.bor(editor.AuxControl_LMB, editor.AuxControl_Ctrl)] = "Select multiple vertices"
end

local function onSerialize()
  return {
    currentFileDir = state.getCurrentFileDir(),
    currentFileName = state.getCurrentFileName(),
    dragRaceData = state.getDragRaceData(),
    hasUnsavedChanges = state.getHasUnsavedChanges(),
    selectedStripIndex = strips.getSelectedStripIndex(),
    selectedSettingsIndex = dragSettings.getSelectedSettingsIndex()
  }
end

local function onDeserialized(data)
  if data then
    state.setCurrentFileDir(data.currentFileDir or state.getCurrentFileDir())
    state.setCurrentFileName(data.currentFileName or state.getCurrentFileName())
    state.setDragRaceData(data.dragRaceData or state.getDragRaceData())
    state.setHasUnsavedChanges(data.hasUnsavedChanges or false)
    strips.setSelectedStripIndex(data.selectedStripIndex or -1)
    dragSettings.setSelectedSettingsIndex(data.selectedSettingsIndex or -1)
  end
end

local function show()
  editor.clearObjectSelection()
  editor.showWindow(constants.CONSTANTS.WINDOW_NAME)
end

local function onEditorGui()
  drawZonesAlways()
  if editor.beginWindow(constants.CONSTANTS.WINDOW_NAME, constants.CONSTANTS.WINDOW_NAME, im.WindowFlags_MenuBar) then
    if not dragEditorDataLoaded then
      dragEditorDataLoaded = true
      if getCurrentLevelIdentifier() then
        log('D', 'drag_race_editor', 'Drag Race Editor opened, loading data for level')
        strips.loadAllStrips()
        dragSettings.loadAllSettings()
      end
    end
    drawMenuBar()

    utils.showError()

    im.Columns(2, 'mainLayout')

    im.BeginChild1("leftPanel", im.ImVec2(0, 0), true)
    strips.drawStripsList()
    im.Separator()
    dragSettings.drawSettingsList()
    im.EndChild()

    im.NextColumn()

    im.BeginChild1("rightPanel", im.ImVec2(0, 0), true)
    local selectedStrip = strips.getSelectedStrip()
    local selectedSettings = dragSettings.getSelectedSettings()

    if selectedStrip then
      strips.drawStripDetails()
      strips.drawLaneEditor()
    elseif selectedSettings then
      dragSettings.drawSettingsDetails()
    else
      im.Text("Select a strip or drag settings file to view details")
    end

    im.EndChild()

    im.Columns(0)

    utils.updateMouseInfo()
    strips.drawStripsPreview()

  end
  editor.endWindow()
end

M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.show = show
M.onEditorInitialized = onEditorInitialized
M.onEditorGui = onEditorGui

M.selectStrip = strips.selectStrip

return M
