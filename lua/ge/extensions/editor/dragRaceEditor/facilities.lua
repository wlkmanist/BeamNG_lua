-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local constants = require('/lua/ge/extensions/editor/dragRaceEditor/constants')
local state = require('/lua/ge/extensions/editor/dragRaceEditor/state')
local utils = require('/lua/ge/extensions/editor/dragRaceEditor/utils')
local dragSaveSystem = require('/lua/ge/extensions/gameplay/drag/saveSystem')
local im = ui_imgui
local ffi = require('ffi')

local M = {}

local allFacilities = {}
local selectedFacilityIndex = -1
local unsavedColor = im.ImVec4(1, 0.3, 0.1, 1.0)

M.loadAllFacilities = function()
  allFacilities = dragSaveSystem.getAllFacilities()
  for _, facility in ipairs(allFacilities) do
    facility._dirty = false
    if not facility._filePath then
      local levelPath = dragSaveSystem.getCurrentLevelDragPath()
      if levelPath then
        facility._filePath = levelPath .. facility.id .. ".facility.json"
      end
    end
  end
  log('D', 'drag_race_editor', 'Loaded ' .. #allFacilities .. ' facilities')
end

M.getAllFacilities = function()
  return allFacilities
end

M.hasSavedFacilities = function()
  for _, facility in ipairs(allFacilities) do
    if facility._filePath and not facility._dirty then
      return true
    end
  end
  return false
end

M.getSelectedFacilityIndex = function()
  return selectedFacilityIndex
end

M.setSelectedFacilityIndex = function(index)
  selectedFacilityIndex = index
end

M.getSelectedFacility = function()
  if selectedFacilityIndex > 0 and selectedFacilityIndex <= #allFacilities then
    return allFacilities[selectedFacilityIndex]
  end
  return nil
end

M.selectFacility = function(index)
  selectedFacilityIndex = index
  local state = require('/lua/ge/extensions/editor/dragRaceEditor/state')
  state.setZoneEditTarget(nil)
  state.setZoneEditPreviousEditMode(nil)
  if editor and editor.editMode and editor.editMode.displayName == "Edit Drag Zone" and editor.selectEditMode and editor.editModes and editor.editModes.objectSelect then
    editor.selectEditMode(editor.editModes.objectSelect)
  end

  local strips = require('/lua/ge/extensions/editor/dragRaceEditor/strips')
  local dragSettings = require('/lua/ge/extensions/editor/dragRaceEditor/dragSettings')
  strips.setSelectedStripIndex(-1)
  dragSettings.setSelectedSettingsIndex(-1)

  local facility = M.getSelectedFacility()
  if facility then
    log('D', 'drag_race_editor', 'Selected facility: ' .. facility.name)

    local currentSettings = dragSettings.getDragSettings()
    local levelName = getCurrentLevelIdentifier()
    if levelName then
      currentSettings.facilityId = "/levels/" .. levelName .. "/dragstrips/" .. facility.id .. ".facility.json"
    else
      currentSettings.facilityId = facility.id
    end

    dragSettings.setDragSettings(currentSettings)
    utils.markUnsavedChanges()
  end
end

M.addFacility = function()
  local facility = {
    id = "new_facility_" .. (#allFacilities + 1),
    name = "New Facility",
    description = "A new drag racing facility",
    stripIds = {},
    metadata = {
      created = os.date(),
      modified = os.date()
    },
    _filePath = nil,
    _dirty = true
  }

  table.insert(allFacilities, facility)
  M.selectFacility(#allFacilities)

  log('D', 'drag_race_editor', 'Created facility (unsaved): ' .. facility.id)
end

M.removeSelectedFacility = function()
  if selectedFacilityIndex > 0 and selectedFacilityIndex <= #allFacilities then
    table.remove(allFacilities, selectedFacilityIndex)
    selectedFacilityIndex = selectedFacilityIndex - 1
    if selectedFacilityIndex == 0 and #allFacilities > 0 then
      selectedFacilityIndex = 1
    end
    if #allFacilities <= 0 then
      selectedFacilityIndex = -1
    end
    utils.markUnsavedChanges()
  end
end

M.saveAllFacilities = function()
  local levelPath = dragSaveSystem.getCurrentLevelDragPath()
  if not levelPath then
    utils.logError("No level loaded, cannot save facilities")
    return false
  end

  if not FS:directoryExists(levelPath) then
    FS:directoryCreate(levelPath)
    if not FS:directoryExists(levelPath) then
      utils.logError("Failed to create dragstrips folder: " .. levelPath)
      return false
    end
  end

  for _, facility in ipairs(allFacilities) do
    if facility._dirty then
      local filePath = facility._filePath or (levelPath .. facility.id .. ".facility.json")
      local success = dragSaveSystem.saveFacility(facility, filePath)
      if success then
        facility._filePath = filePath
        facility._dirty = false
      end
    end
  end

  return true
end

M.saveFacility = function(facility)
  if not facility then return false end

  local levelPath = dragSaveSystem.getCurrentLevelDragPath()
  if not levelPath then
    utils.logError("No level loaded, cannot save facility")
    return false
  end

  local oldFilePath = facility._filePath
  local newFilePath = levelPath .. facility.id .. ".facility.json"

  if oldFilePath and oldFilePath ~= newFilePath and FS:fileExists(oldFilePath) then
    if FS:fileExists(newFilePath) then
      utils.logError("Cannot rename facility: file with new ID already exists: " .. newFilePath)
      return false
    end

    local renameResult = FS:renameFile(oldFilePath, newFilePath)
    if renameResult ~= 0 then
      utils.logError("Failed to rename facility file from " .. oldFilePath .. " to " .. newFilePath)
      return false
    end

    log('D', 'drag_race_editor', 'Renamed facility file from ' .. oldFilePath .. ' to ' .. newFilePath)
  end

  local success = dragSaveSystem.saveFacility(facility, newFilePath)

  if success then
    facility._filePath = newFilePath
    facility._dirty = false
    for i, f in ipairs(allFacilities) do
      if f.id == facility.id then
        allFacilities[i] = facility
        break
      end
    end
  end

  return success
end

M.drawFacilitiesList = function()
  im.Text("Facilities:")
  im.SameLine()
  if im.Button("Add##facilities_add") then
    M.addFacility()
  end
  im.SameLine()
  if im.Button("Remove##facilities_remove") then
    M.removeSelectedFacility()
  end
  im.SameLine()
  if im.Button("Save##facilities_save") then
    M.saveAllFacilities()
  end
  im.SameLine()
  if im.Button("Refresh##facilities_refresh") then
    M.loadAllFacilities()
  end

  im.NewLine()

  for i, facility in ipairs(allFacilities) do
    local isSelected = i == selectedFacilityIndex
    local label = string.format("%s (%d strips)", facility.id or "unnamed", #facility.stripIds or 0)

    if facility._dirty then
      im.PushStyleColor2(im.Col_Text, unsavedColor)
    end

    local wasSelected = im.Selectable1(label, isSelected)

    if facility._dirty then
      im.PopStyleColor()
    end

    if wasSelected then
      M.selectFacility(i)
    end

    if im.IsItemHovered() then
      local tooltip = string.format("Name: %s\nDescription: %s", facility.name or "N/A", facility.description or "N/A")
      if facility._dirty then
        tooltip = tooltip .. "\n[UNSAVED CHANGES]"
      end
      im.tooltip(tooltip)
    end
  end

  im.Spacing()
end

M.drawFacilityDetails = function()
  local facility = M.getSelectedFacility()
  if not facility then
    return
  end

  im.Text("Facility Details")
  im.Separator()

  im.Text("ID: ")
  im.SameLine()
  local id = im.ArrayChar(256, facility.id or "")
  if im.InputText("##facilityId", id, 256) then
    facility.id = ffi.string(id)
    facility._dirty = true
    utils.markUnsavedChanges()
  end

  im.Text("Name: ")
  im.SameLine()
  local name = im.ArrayChar(256, facility.name or "")
  if im.InputText("##facilityName", name, 256) then
    facility.name = ffi.string(name)
    facility._dirty = true
    utils.markUnsavedChanges()
  end

  im.Text("Description: ")
  im.SameLine()
  local description = im.ArrayChar(512, facility.description or "")
  if im.InputText("##facilityDescription", description, 512) then
    facility.description = ffi.string(description)
    facility._dirty = true
    utils.markUnsavedChanges()
  end

  im.NewLine()
  im.Separator()
  im.Text("Strips")
  im.Separator()

  if not facility.stripIds then
    facility.stripIds = {}
  end

  local allStrips = dragSaveSystem.getAllStrips()
  local stripOptions = {}
  local stripOptionsWithIds = {}

  for _, strip in ipairs(allStrips) do
    local stripId = strip.id
    local alreadyAdded = false

    for _, existingStripPath in ipairs(facility.stripIds) do
      local existingStripId = existingStripPath:match("([^/]+)%.strip%.json$") or existingStripPath
      if existingStripId == stripId then
        alreadyAdded = true
        break
      end
    end

    if not alreadyAdded then
      local displayName = strip.name or strip.id
      table.insert(stripOptions, displayName)
      stripOptionsWithIds[displayName] = stripId
    end
  end

  im.Text("Add Strip: ")
  im.SameLine()
  if #stripOptions > 0 then
    im.PushItemWidth(200)
    local search = state.getSearch()
    local selectedStripName = search:beginSearchableSimpleCombo(im, "addStripToFacility", "Select a strip...", stripOptions)
    if selectedStripName and selectedStripName ~= "Select a strip..." then
      local stripId = stripOptionsWithIds[selectedStripName]
      if stripId then
        local levelPath = dragSaveSystem.getCurrentLevelDragPath()
        local stripFilePath = nil
        if levelPath then
          stripFilePath = levelPath .. stripId .. ".strip.json"
        else
          stripFilePath = stripId
        end

        local alreadyExists = false
        for _, existingStripPath in ipairs(facility.stripIds) do
          local existingStripId = existingStripPath:match("([^/]+)%.strip%.json$") or existingStripPath
          if existingStripId == stripId or existingStripPath == stripFilePath then
            alreadyExists = true
            break
          end
        end

        if not alreadyExists then
          table.insert(facility.stripIds, stripFilePath)
          facility._dirty = true
          utils.markUnsavedChanges()
          log('D', 'drag_race_editor', 'Added strip ' .. stripId .. ' (' .. stripFilePath .. ') to facility ' .. facility.id)
        end
      end
    end
    im.PopItemWidth()
  else
    im.Text("No available strips to add")
  end

  im.NewLine()
  im.Text("Strips in facility: " .. #facility.stripIds)

  if #facility.stripIds > 0 then
    im.Indent()
    for i, stripFilePath in ipairs(facility.stripIds) do
      local stripId = stripFilePath:match("([^/]+)%.strip%.json$") or stripFilePath

      local stripName = stripId
      for _, strip in ipairs(allStrips) do
        if strip.id == stripId then
          stripName = strip.name or strip.id
          break
        end
      end

      im.Text(stripName)
      im.SameLine()
      if im.SmallButton("Remove##strip_" .. i) then
        table.remove(facility.stripIds, i)
        facility._dirty = true
        utils.markUnsavedChanges()
        log('D', 'drag_race_editor', 'Removed strip ' .. stripId .. ' from facility ' .. facility.id)
      end
    end
    im.Unindent()
  else
    im.Text("No strips added to this facility")
  end
end

M.drawFacilitiesPreview = function()
  local facility = M.getSelectedFacility()
  if not facility then return end

  debugDrawer:drawTextAdvanced(vec3(0, 0, 0), String("Facility: " .. facility.name), constants.CONSTANTS.COLORS.WHITE, true, false, constants.CONSTANTS.COLORS.BLACK)
end

return M
