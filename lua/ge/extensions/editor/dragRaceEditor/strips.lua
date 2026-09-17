-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local constants = require('/lua/ge/extensions/editor/dragRaceEditor/constants')
local state = require('/lua/ge/extensions/editor/dragRaceEditor/state')
local utils = require('/lua/ge/extensions/editor/dragRaceEditor/utils')
local zones = require('/lua/ge/extensions/editor/dragRaceEditor/zones')
local dragSaveSystem = require('/lua/ge/extensions/gameplay/drag/saveSystem')
local im = ui_imgui
local ffi = require('ffi')

local M = {}

local allStrips = {}
local selectedStripIndex = -1
local selectedLaneIndex = -1
local selectedBoundaryIndex = -1
local unsavedColor = im.ImVec4(1, 0.3, 0.1, 1.0)
local warningColor = (editor and editor.color and editor.color.warning) and editor.color.warning.Value or im.ImVec4(1, 0.85, 0.3, 1.0)

-- Lane color name -> RGB (0-1) for zone/boundary debug draws.
local LANE_COLOR_RGB = {
  blue = { 0.2, 0.4, 1 },
  red = { 1, 0.3, 0.3 },
  green = { 0.3, 0.8, 0.3 },
  yellow = { 1, 0.9, 0.2 },
  purple = { 0.7, 0.3, 1 },
  orange = { 1, 0.5, 0.1 },
}
local function laneColorToRgb(name)
  return LANE_COLOR_RGB[name or "blue"] or LANE_COLOR_RGB.blue
end

local function drawDragStripSceneObjectNameRow(stripId, laneIndex, middleId, optional, greenColor, redColor, yellowColor)
  local name = stripId .. "_" .. middleId .. "_" .. laneIndex
  local found = scenetree.findObject(name) ~= nil
  if found then
    im.TextColored(greenColor, "  [OK]  " .. name)
  elseif optional then
    im.TextColored(yellowColor, "  [~~]  " .. name .. "  (optional)")
  else
    im.TextColored(redColor, "  [--]  " .. name)
  end
end

local function beamNgWaypointAtSceneName(name)
  if not name or name == "" then
    return nil
  end
  local o = scenetree.findObject(name)
  if o and o.getClassName and o:getClassName() == "BeamNGWaypoint" then
    return o
  end
  return nil
end

local function drawStripLevelBeamNgWaypointRow(stripId, wpType, greenColor, redColor)
  local name = stripId .. "_" .. tostring(wpType)
  if beamNgWaypointAtSceneName(name) then
    im.TextColored(greenColor, "  [OK]  " .. name)
  else
    im.TextColored(redColor, "  [--]  " .. name)
  end
end

local function drawLaneBeamNgWaypointRow(stripId, laneIndex, wpType, optional, greenColor, redColor, yellowColor)
  local name = dragSaveSystem.laneWaypointSceneName(stripId, wpType, laneIndex)
  if beamNgWaypointAtSceneName(name) then
    im.TextColored(greenColor, "  [OK]  " .. name)
  elseif optional then
    im.TextColored(yellowColor, "  [~~]  " .. name .. "  (optional)")
  else
    im.TextColored(redColor, "  [--]  " .. name)
  end
end

--- Renames lane BeamNGWaypoints and tree/display objects from legacy prefab names to strip convention. Returns count renamed.
local function renameLaneSceneToConvention(stripId, lane, laneIndex)
  if not stripId or stripId == "" or not lane then
    return 0
  end
  local renamed = 0

  if lane.waypoints then
    for _, wp in ipairs(lane.waypoints) do
      if wp.type then
        local newName = dragSaveSystem.laneWaypointSceneName(stripId, wp.type, laneIndex)
        local candidates = {
          wp.name,
          stripId .. "_" .. wp.type .. "_" .. laneIndex,
          "drag_" .. laneIndex .. "_" .. wp.type,
        }
        for _, old in ipairs(candidates) do
          if old and old ~= "" and old ~= newName then
            local o = scenetree.findObject(old)
            if o and o.getClassName and o:getClassName() == "BeamNGWaypoint" then
              o:setName(newName)
              wp.name = newName
              renamed = renamed + 1
              break
            end
          end
        end
      end
    end
  end

  local LEGACY_MAP = {
    { legacy = "Prestagelight_", conventionId = "prestage" },
    { legacy = "Stagelight_", conventionId = "stage" },
    { legacy = "Amberlight1_", conventionId = "amber1" },
    { legacy = "Amberlight2_", conventionId = "amber2" },
    { legacy = "Amberlight3_", conventionId = "amber3" },
    { legacy = "Greenlight_", conventionId = "green" },
    { legacy = "Redlight_", conventionId = "red" },
    { legacy = "WinLight_Timeboard_", conventionId = "winTimeboard" },
    { legacy = "WinLight_Driver_", conventionId = "winDriver" },
  }
  for _, entry in ipairs(LEGACY_MAP) do
    local oldName = entry.legacy .. laneIndex
    local obj = scenetree.findObject(oldName)
    if obj then
      obj:setName(stripId .. "_" .. entry.conventionId .. "_" .. laneIndex)
      renamed = renamed + 1
    end
  end

  local LEGACY_DISPLAY_SUFFIXES = { [1] = "_r", [2] = "_l" }
  local suffix = LEGACY_DISPLAY_SUFFIXES[laneIndex]
  if suffix then
    for i = 1, 5 do
      local oldTime = scenetree.findObject("display_time_" .. i .. suffix)
      if oldTime then
        oldTime:setName(stripId .. "_displayTime" .. i .. "_" .. laneIndex)
        renamed = renamed + 1
      end
      local oldSpeed = scenetree.findObject("display_speed_" .. i .. suffix)
      if oldSpeed then
        oldSpeed:setName(stripId .. "_displaySpeed" .. i .. "_" .. laneIndex)
        renamed = renamed + 1
      end
    end
  end

  if laneIndex == 1 then
    local blueObj = scenetree.findObject("BlueLight")
    if blueObj then
      blueObj:setName(stripId .. "_blueLight")
      renamed = renamed + 1
    end
  end

  return renamed
end

M.loadAllStrips = function()
  allStrips = dragSaveSystem.getAllStrips()
  for _, strip in ipairs(allStrips) do
    strip._dirty = false
    if not strip._filePath then
      local levelPath = dragSaveSystem.getCurrentLevelDragPath()
      if levelPath then
        strip._filePath = levelPath .. strip.id .. ".strip.json"
      end
    end
  end
  log('D', 'drag_race_editor', 'Loaded ' .. #allStrips .. ' strips')
end

M.getAllStrips = function()
  return allStrips
end

M.hasSavedStrips = function()
  for _, strip in ipairs(allStrips) do
    if strip._filePath and not strip._dirty then
      return true
    end
  end
  return false
end

M.getSelectedStripIndex = function()
  return selectedStripIndex
end

M.setSelectedStripIndex = function(index)
  selectedStripIndex = index
end

M.getSelectedStrip = function()
  if selectedStripIndex > 0 and selectedStripIndex <= #allStrips then
    return allStrips[selectedStripIndex]
  end
  return nil
end

M.selectStrip = function(index)
  selectedStripIndex = index
  state.setZoneEditTarget(nil)
  state.setZoneEditPreviousEditMode(nil)
  if editor and editor.editMode and editor.editMode.displayName == "Edit Drag Zone" and editor.selectEditMode and editor.editModes and editor.editModes.objectSelect then
    editor.selectEditMode(editor.editModes.objectSelect)
  end

  local dragSettings = require('/lua/ge/extensions/editor/dragRaceEditor/dragSettings')
  dragSettings.setSelectedSettingsIndex(-1)

  local strip = M.getSelectedStrip()
  if strip then
    log('D', 'drag_race_editor', 'Selected strip: ' .. strip.name)

    local currentSettings = dragSettings.getDragSettings()
    local levelName = getCurrentLevelIdentifier()
    if levelName then
      currentSettings.stripId = "/levels/" .. levelName .. "/dragstrips/" .. strip.id .. ".strip.json"
    else
      currentSettings.stripId = strip.id
    end

    dragSettings.setDragSettings(currentSettings)
    utils.markUnsavedChanges()
  end
end

M.addStrip = function()
  log('D', 'drag_race_editor', 'Add strip button clicked')

  local defaultStrip = {
    id = "new_strip_" .. (#allStrips + 1),
    name = "New Strip",
    description = "A new drag racing strip",
    endCamera = nil,
    metadata = {
      created = os.date(),
      modified = os.date()
    },
    lanes = {
      {
        id = "lane_left",
        name = "Left Lane",
        shortName = "Left",
        longName = "Left Lane",
        color = "blue",
        laneOrder = 1,
        waypoints = {
          {
            type = "stage",
            transform = {
              position = {x = 0, y = 0, z = 0},
              rotation = {x = 0, y = 0, z = 0, w = 1},
              scale = {x = 1, y = 1, z = 1}
            }
          },
          {
            type = "endLine",
            transform = {
              position = {x = 0, y = 0, z = 0},
              rotation = {x = 0, y = 0, z = 0, w = 1},
              scale = {x = 1, y = 1, z = 1}
            }
          }
        },
        boundary = nil,
        metadata = {
          created = os.date(),
          modified = os.date()
        }
      },
      {
        id = "lane_right",
        name = "Right Lane",
        shortName = "Right",
        longName = "Right Lane",
        color = "red",
        laneOrder = 2,
        waypoints = {
          {
            type = "stage",
            transform = {
              position = {x = 0, y = 0, z = 0},
              rotation = {x = 0, y = 0, z = 0, w = 1},
              scale = {x = 1, y = 1, z = 1}
            }
          },
          {
            type = "endLine",
            transform = {
              position = {x = 0, y = 0, z = 0},
              rotation = {x = 0, y = 0, z = 0, w = 1},
              scale = {x = 1, y = 1, z = 1}
            }
          }
        },
        boundary = nil,
        metadata = {
          created = os.date(),
          modified = os.date()
        }
      }
    },
    _filePath = nil,
    _dirty = true
  }

  table.insert(allStrips, defaultStrip)
  M.selectStrip(#allStrips)

  log('D', 'drag_race_editor', 'Created strip (unsaved): ' .. defaultStrip.id)
end

M.removeSelectedStrip = function()
  if selectedStripIndex > 0 and selectedStripIndex <= #allStrips then
    table.remove(allStrips, selectedStripIndex)
    selectedStripIndex = selectedStripIndex - 1
    if selectedStripIndex == 0 and #allStrips > 0 then
      selectedStripIndex = 1
    end
    if #allStrips <= 0 then
      selectedStripIndex = -1
    end
    utils.markUnsavedChanges()
  end
end

M.saveStrip = function(strip)
  if not strip then return false end

  local levelPath = dragSaveSystem.getCurrentLevelDragPath()
  if not levelPath then
    utils.logError("No level loaded, cannot save strip")
    return false
  end

  if not FS:directoryExists(levelPath) then
    FS:directoryCreate(levelPath)
    if not FS:directoryExists(levelPath) then
      utils.logError("Failed to create dragstrips folder: " .. levelPath)
      return false
    end
  end

  local oldFilePath = strip._filePath
  local newFilePath = levelPath .. strip.id .. ".strip.json"

  if oldFilePath and oldFilePath ~= newFilePath and FS:fileExists(oldFilePath) then
    if FS:fileExists(newFilePath) then
      utils.logError("Cannot rename strip: file with new ID already exists: " .. newFilePath)
      return false
    end

    local renameResult = FS:renameFile(oldFilePath, newFilePath)
    if renameResult ~= 0 then
      utils.logError("Failed to rename strip file from " .. oldFilePath .. " to " .. newFilePath)
      return false
    end

    log('D', 'drag_race_editor', 'Renamed strip file from ' .. oldFilePath .. ' to ' .. newFilePath)
  end

  local success = dragSaveSystem.saveStrip(strip, newFilePath)

  if success then
    strip._filePath = newFilePath
    strip._dirty = false
  end

  return success
end

M.drawStripsList = function()
  im.Spacing()
  if not utils.dragSectionHeader("Strips", "##dragRaceStripsList", true) then
    return
  end

  if im.Button("Add##strips_add") then
    log('D', 'drag_race_editor', 'Strips Add button clicked')
    M.addStrip()
  end
  im.SameLine()
  if im.Button("Remove##strips_remove") then
    log('D', 'drag_race_editor', 'Strips Remove button clicked')
    M.removeSelectedStrip()
  end
  im.SameLine()
  if im.Button("Save##strips_save") then
    log('D', 'drag_race_editor', 'Strips Save button clicked')
    local strip = M.getSelectedStrip()
    if strip then
      M.saveStrip(strip)
    end
  end
  im.SameLine()
  if im.Button("Refresh##strips_refresh") then
    log('D', 'drag_race_editor', 'Strips Refresh button clicked')
    M.loadAllStrips()
  end

  im.Spacing()

  for i, strip in ipairs(allStrips) do
    local isSelected = i == selectedStripIndex
    local laneCount = strip.lanes and #strip.lanes or 0
    local label = string.format("%s (%d lanes)", strip.id or "unnamed", laneCount)

    if strip._dirty then
      im.PushStyleColor2(im.Col_Text, unsavedColor)
    end

    local wasSelected = im.Selectable1(label, isSelected)

    if strip._dirty then
      im.PopStyleColor()
    end

    if wasSelected then
      M.selectStrip(i)
    end

    if im.IsItemHovered() then
      local tooltip = string.format("Name: %s\nDescription: %s", strip.name or "N/A", strip.description or "N/A")
      if strip._dirty then
        tooltip = tooltip .. "\n[UNSAVED CHANGES]"
      end
      im.tooltip(tooltip)
    end
  end

  im.Spacing()
end

M.drawStripDetails = function()
  local strip = M.getSelectedStrip()
  if not strip then
    return
  end

  im.Spacing()

  local stripTitle = strip.name or strip.id or "Strip"
  if not utils.dragSectionHeader(stripTitle, "##stripDetailRoot", true) then
    return
  end

  im.Spacing()
  if utils.dragSectionHeader("Basics", "##stripBasics", true) then
    im.Text("ID: ")
    im.SameLine()
    local id = im.ArrayChar(256, strip.id or "")
    if im.InputText("##stripId", id, 256) then
      strip.id = ffi.string(id)
      strip._dirty = true
      utils.markUnsavedChanges()
    end

    im.Text("Name: ")
    im.SameLine()
    local name = im.ArrayChar(256, strip.name or "")
    if im.InputText("##stripName", name, 256) then
      strip.name = ffi.string(name)
      strip._dirty = true
      utils.markUnsavedChanges()
    end

    im.Text("Description: ")
    im.SameLine()
    local description = im.ArrayChar(512, strip.description or "")
    if im.InputText("##stripDescription", description, 512) then
      strip.description = ffi.string(description)
      strip._dirty = true
      utils.markUnsavedChanges()
    end

    im.Spacing()
    im.Spacing()
    im.Text("End camera")
    im.Spacing()
    im.Text("Enable end camera for this strip.")
    im.NewLine()
    local hasEndCamera = strip.endCamera ~= nil
    local endCameraPtr = im.BoolPtr(hasEndCamera)
    if im.Checkbox("Has end camera##stripEndCamCb", endCameraPtr) then
      if endCameraPtr[0] and not strip.endCamera then
        strip.endCamera = {
          transform = {
            position = {x = 0, y = 0, z = 0},
            rotation = {x = 0, y = 0, z = 0, w = 1},
            scale = {x = 1, y = 1, z = 1}
          }
        }
      elseif not endCameraPtr[0] then
        strip.endCamera = nil
      end
      strip._dirty = true
      utils.markUnsavedChanges()
    end

    im.Spacing()
    im.Spacing()
    im.Text("Strip zone")
    im.Spacing()
    im.TextWrapped("Optional. Scene volume: leaving it (offline) clears and unloads drag.")
    im.NewLine()
    if strip.stripZone then
      im.Text("Present (" .. (strip.stripZone.vertices and #strip.stripZone.vertices or 0) .. " vertices)")
      im.SameLine()
      if im.Button("Remove strip zone##strip_zone_remove") then
        strip.stripZone = nil
        strip._dirty = true
        utils.markUnsavedChanges()
      end
    else
      if im.Button("Add strip zone##strip_zone_add") then
        strip.stripZone = {
          name = "Strip Zone",
          vertices = {},
          color = { 1, 1, 1 },
          top = { active = false, pos = { 0, 0, 10 }, normal = { 0, 0, 1 } },
          bot = { active = false, pos = { 0, 0, -10 }, normal = { 0, 0, -1 } }
        }
        strip._dirty = true
        utils.markUnsavedChanges()
      end
      if im.IsItemHovered() then
        im.tooltip("Create an empty zone; select it below to edit in the scene.")
      end
      im.NewLine()
      im.TextColored(warningColor, "Strip zone not set. Add one for \"clear when player leaves\" (offline).")
    end

    im.Spacing()
    im.TextColored(im.ImVec4(0.8, 0.6, 0.2, 1.0), "Edit in scene")
    if editor.editModes and editor.editModes.dragZoneEditMode then
      local current = state.getZoneEditTarget()
      im.Indent()
      if strip.stripZone then
        local n = strip.stripZone.vertices and #strip.stripZone.vertices or 0
        local label = "Strip zone (" .. n .. " vertices)"
        local target = { type = 'stripZone', strip = strip }
        local isSelected = current and current.type == 'stripZone' and current.strip == strip
        if im.Selectable1(label, isSelected) then
          if isSelected then
            state.setZoneEditTarget(nil)
            state.setZoneEditPreviousEditMode(nil)
            if editor.editMode and editor.editMode.displayName == "Edit Drag Zone" then
              editor.selectEditMode(editor.editModes.objectSelect)
            end
          else
            state.setZoneEditPreviousEditMode(editor.editMode)
            state.setZoneEditTarget(target)
            if editor.editMode ~= editor.editModes.dragZoneEditMode then
              editor.selectEditMode(editor.editModes.dragZoneEditMode)
            end
          end
        end
        if im.IsItemHovered() then im.tooltip(isSelected and "Click to stop editing" or "Click to edit zone in scene") end
      end
      im.Unindent()
    end
  end

  im.Spacing()
  if utils.dragSectionHeader("Lanes", "##stripLanes", true) then
    local laneCount = strip.lanes and #strip.lanes or 0
    im.Text("Count: " .. laneCount)
    im.NewLine()

    if im.Button("Add Lane##strip_add_lane") then
      local newLane = {
        id = "lane_" .. (laneCount + 1),
        name = "Lane " .. (laneCount + 1),
        shortName = "L" .. (laneCount + 1),
        longName = "Lane " .. (laneCount + 1),
        color = "green",
        laneOrder = laneCount + 1,
        waypoints = {
          {
            type = "stage",
            transform = {
              position = {x = 0, y = 0, z = 0},
              rotation = {x = 0, y = 0, z = 0, w = 1},
              scale = {x = 1, y = 1, z = 1}
            }
          },
          {
            type = "endLine",
            transform = {
              position = {x = 0, y = 0, z = 0},
              rotation = {x = 0, y = 0, z = 0, w = 1},
              scale = {x = 1, y = 1, z = 1}
            }
          }
        },
        boundary = nil,
        metadata = {
          created = os.date(),
          modified = os.date()
        }
      }

      if not strip.lanes then
        strip.lanes = {}
      end
      table.insert(strip.lanes, newLane)
      strip._dirty = true
      utils.markUnsavedChanges()
    end

    im.SameLine()
    if im.Button("Remove selected lane##strip_rm_lane") then
      if selectedLaneIndex > 0 and selectedLaneIndex <= #strip.lanes then
        table.remove(strip.lanes, selectedLaneIndex)
        selectedLaneIndex = -1
        strip._dirty = true
        utils.markUnsavedChanges()
      end
    end

    if strip.lanes and #strip.lanes > 0 then
      im.Spacing()
      im.Text("Select lane:")
      im.Indent()
      for i, lane in ipairs(strip.lanes) do
        local isLaneSelected = i == selectedLaneIndex
        local laneLabel = string.format("%d. %s (%s)", i, lane.name or "Unnamed", lane.color or "unknown")
        if im.Selectable1(laneLabel, isLaneSelected) then
          selectedLaneIndex = i
        end
      end
      im.Unindent()
    end
  end

  im.Spacing()
end

M.editLane = function(stripIndex, laneIndex)
  if stripIndex > 0 and stripIndex <= #allStrips then
    local strip = allStrips[stripIndex]
    if strip and strip.lanes and laneIndex > 0 and laneIndex <= #strip.lanes then
      selectedStripIndex = stripIndex
      selectedLaneIndex = laneIndex
      return strip.lanes[laneIndex]
    end
  end
  return nil
end

M.getSelectedLane = function()
  local strip = M.getSelectedStrip()
  if strip and strip.lanes and selectedLaneIndex > 0 and selectedLaneIndex <= #strip.lanes then
    return strip.lanes[selectedLaneIndex]
  end
  return nil
end

M.drawLaneEditor = function()
  local strip = M.getSelectedStrip()
  if not strip or not strip.lanes or selectedLaneIndex <= 0 or selectedLaneIndex > #strip.lanes then
    return
  end

  local lane = strip.lanes[selectedLaneIndex]
  if not lane then
    return
  end

  local laneIndex = selectedLaneIndex
  local li = tostring(laneIndex)

  im.Spacing()

  local laneTitle = lane.name or lane.id or ("Lane " .. li)
  if not utils.dragSectionHeader(laneTitle, "##laneRoot" .. li, true) then
    return
  end

  im.Spacing()
  if utils.dragSectionHeader("Basics", "##laneBasics" .. li, true) then
    im.Text("ID: ")
    im.SameLine()
    local id = im.ArrayChar(256, lane.id or "")
    if im.InputText("##laneId", id, 256) then
      lane.id = ffi.string(id)
      strip._dirty = true
      utils.markUnsavedChanges()
    end

    im.Text("Name: ")
    im.SameLine()
    local name = im.ArrayChar(256, lane.name or "")
    if im.InputText("##laneName", name, 256) then
      lane.name = ffi.string(name)
      strip._dirty = true
      utils.markUnsavedChanges()
    end

    im.Text("Short Name: ")
    im.SameLine()
    local shortName = im.ArrayChar(256, lane.shortName or "")
    if im.InputText("##laneShortName", shortName, 256) then
      lane.shortName = ffi.string(shortName)
      strip._dirty = true
      utils.markUnsavedChanges()
    end

    im.Text("Long Name: ")
    im.SameLine()
    local longName = im.ArrayChar(256, lane.longName or "")
    if im.InputText("##laneLongName", longName, 256) then
      lane.longName = ffi.string(longName)
      strip._dirty = true
      utils.markUnsavedChanges()
    end

    im.Text("Color: ")
    im.SameLine()
    im.PushItemWidth(100)
    local colors = {"blue", "red", "green", "yellow", "purple", "orange"}
    local search = state.getSearch()
    local selectedColor = search:beginSearchableSimpleCombo(im, "laneColor##lane" .. li, lane.color or "blue", colors)
    if selectedColor then
      lane.color = selectedColor
      strip._dirty = true
      utils.markUnsavedChanges()
    end
    im.PopItemWidth()

    im.Text("Lane Order: ")
    im.SameLine()
    local laneOrder = im.IntPtr(lane.laneOrder or 1)
    if im.InputInt("##laneOrder", laneOrder) then
      lane.laneOrder = laneOrder[0]
      strip._dirty = true
      utils.markUnsavedChanges()
    end
  end

  im.Spacing()
  if utils.dragSectionHeader("Lane scene", "##laneSceneNames" .. li, false) then
    local stripId = strip.id or ""

    if stripId == "" then
      im.TextColored(warningColor, "Set strip ID for scene name rows and rename tool.")
    else
      local greenColor = im.ImVec4(0.3, 0.9, 0.3, 1)
      local redColor = im.ImVec4(1, 0.3, 0.3, 1)
      local yellowColor = im.ImVec4(1, 0.85, 0.3, 1)

      local hasStripWps = strip.waypoints and #strip.waypoints > 0
      local hasLaneWps = lane.waypoints and #lane.waypoints > 0
      if not hasStripWps and not hasLaneWps then
        im.Text("No waypoint types in JSON (strip or lane).")
      end

      if hasStripWps then
        im.Text("Strip waypoints (BeamNGWaypoint):")
        for _, wp in ipairs(strip.waypoints) do
          if wp.type then
            drawStripLevelBeamNgWaypointRow(stripId, wp.type, greenColor, redColor)
          end
        end
        im.Spacing()
      end

      if hasLaneWps then
        im.Text("Lane waypoints (BeamNGWaypoint):")
        for _, wp in ipairs(lane.waypoints) do
          if wp.type then
            drawLaneBeamNgWaypointRow(stripId, laneIndex, wp.type, false, greenColor, redColor, yellowColor)
          end
        end
        im.Spacing()
      end

      local REQUIRED_LIGHT_IDS = {
        "prestage", "stage", "amber1", "amber2", "amber3", "green", "red",
      }
      local OPTIONAL_LIGHT_IDS = {
        "winTimeboard", "winDriver",
      }
      local OPTIONAL_DISPLAY_IDS = {
        "displayTime1", "displayTime2", "displayTime3", "displayTime4", "displayTime5",
        "displaySpeed1", "displaySpeed2", "displaySpeed3", "displaySpeed4", "displaySpeed5",
      }

      im.Text("Lights (required):")
      for _, lightId in ipairs(REQUIRED_LIGHT_IDS) do
        drawDragStripSceneObjectNameRow(stripId, laneIndex, lightId, false, greenColor, redColor, yellowColor)
      end

      im.Text("Lights (optional):")
      for _, lightId in ipairs(OPTIONAL_LIGHT_IDS) do
        drawDragStripSceneObjectNameRow(stripId, laneIndex, lightId, true, greenColor, redColor, yellowColor)
      end

      im.Text("Display Digits (optional):")
      for _, digitId in ipairs(OPTIONAL_DISPLAY_IDS) do
        drawDragStripSceneObjectNameRow(stripId, laneIndex, digitId, true, greenColor, redColor, yellowColor)
      end

      im.Text("Strip-level (optional):")
      local blueName = stripId .. "_blueLight"
      local blueFound = scenetree.findObject(blueName) ~= nil
      if blueFound then
        im.TextColored(greenColor, "  [OK]  " .. blueName)
      else
        im.TextColored(yellowColor, "  [~~]  " .. blueName .. "  (optional)")
      end

      im.NewLine()
      im.Separator()
      im.TextWrapped("Rename tool: migrates old prefab/JSON names to current convention for this lane (BeamNGWaypoints → " .. stripId .. "_wp_<type>_" .. laneIndex .. "; tree & digits → " .. stripId .. "_<id>_" .. laneIndex .. ").")
      im.Spacing()
      if im.Button("Rename waypoints & lights to convention##lane" .. laneIndex) then
        local n = renameLaneSceneToConvention(stripId, lane, laneIndex)
        strip._dirty = true
        utils.markUnsavedChanges()
        if n > 0 and map and map.reset then
          local ok, err = pcall(map.reset)
          if not ok then
            log("E", "drag_editor", "map.reset() (navgraph rebuild) failed: " .. tostring(err))
          end
        end
        log("I", "drag_editor", "Renamed " .. n .. " scene object(s) for lane " .. laneIndex)
      end
      if im.IsItemHovered() then
        im.tooltip("Waypoints: JSON name, old stripId_type_lane, or drag_<lane>_type → canonical _wp_ name. Lights: Prestagelight_, Stagelight_, Amberlight_, etc.; display_time_/display_speed_; BlueLight on lane 1.")
      end
    end
  end

  im.Spacing()
  if utils.dragSectionHeader("Zone   scene", "##laneZonePanel" .. li, false) then
    im.TextWrapped("Out-of-lane disqualification volume. Edit vertices in scene after selecting below.")
    im.Spacing()
    if lane.zone then
      if im.Button("Remove zone##lane_zone_remove" .. li) then
        lane.zone = nil
        strip._dirty = true
        utils.markUnsavedChanges()
      end
    else
      if im.Button("Add zone##lane_zone_add" .. li) then
        lane.zone = {
          name = (lane.name or lane.id or "Lane") .. " Zone",
          vertices = {},
          color = { 1, 1, 1 },
          top = { active = false, pos = { 0, 0, 10 }, normal = { 0, 0, 1 } },
          bot = { active = false, pos = { 0, 0, -10 }, normal = { 0, 0, -1 } }
        }
        strip._dirty = true
        utils.markUnsavedChanges()
      end
      if im.IsItemHovered() then im.tooltip("Create empty zone; select it below to edit in scene.") end
      im.Spacing()
      im.TextColored(warningColor, "Lane zone not set. OBB boundary is used for backward compatibility.")
    end
    if editor.editModes and editor.editModes.dragZoneEditMode and lane.zone then
      im.Spacing()
      im.Text("Edit in scene:")
      im.Indent()
      local current = state.getZoneEditTarget()
      local i = selectedLaneIndex
      local n = lane.zone.vertices and #lane.zone.vertices or 0
      local label = (lane.name or ("Lane " .. i)) .. " Zone (" .. n .. " vertices)"
      local target = { type = 'laneZone', strip = strip, laneIndex = i, lane = lane }
      local isSelected = current and current.type == 'laneZone' and current.strip == strip and current.laneIndex == i
      if im.Selectable1(label .. "##lane_zone_scene" .. li, isSelected) then
        if isSelected then
          state.setZoneEditTarget(nil)
          state.setZoneEditPreviousEditMode(nil)
          if editor.editMode and editor.editMode.displayName == "Edit Drag Zone" then
            editor.selectEditMode(editor.editModes.objectSelect)
          end
        else
          state.setZoneEditPreviousEditMode(editor.editMode)
          state.setZoneEditTarget(target)
          if editor.editMode ~= editor.editModes.dragZoneEditMode then
            editor.selectEditMode(editor.editModes.dragZoneEditMode)
          end
        end
      end
      if im.IsItemHovered() then im.tooltip(isSelected and "Click to stop editing" or "Click to edit zone in scene") end
      im.Unindent()
    end
  end

  im.Spacing()
end

M.drawZonesInWorld = function()
  local strip = M.getSelectedStrip()
  if not strip then return end
  local editing = state.getZoneEditTarget()
  local stripZoneClr = { 0.9, 0.9, 0.95 }
  if strip.stripZone and (strip.stripZone.vertices and #strip.stripZone.vertices > 0) then
    local skip = editing and editing.type == 'stripZone' and editing.strip == strip
    if not skip then
      local zone = zones.zoneFromData(strip.stripZone)
      if zone then zone:drawDebug('faded', stripZoneClr) end
    end
  end
  if strip.lanes then
    for i, lane in ipairs(strip.lanes) do
      if lane.zone and (lane.zone.vertices and #lane.zone.vertices > 0) then
        local skip = editing and editing.type == 'laneZone' and editing.strip == strip and editing.laneIndex == i
        if not skip then
          local zone = zones.zoneFromData(lane.zone)
          if zone then zone:drawDebug('faded', laneColorToRgb(lane.color)) end
        end
      end
    end
  end
end

M.drawStripsPreview = function()
  local strip = M.getSelectedStrip()
  if not strip then return end

  debugDrawer:drawTextAdvanced(vec3(0, 0, 0), String("Strip: " .. strip.name), constants.CONSTANTS.COLORS.WHITE, true, false, constants.CONSTANTS.COLORS.BLACK)
  M.drawZonesInWorld()
end

M.enableBoundaryGizmo = function(boundary)
  if not boundary then return end

  local pos = vec3(boundary.transform.position.x, boundary.transform.position.y, boundary.transform.position.z)
  local rot = quat(boundary.transform.rotation.x, boundary.transform.rotation.y, boundary.transform.rotation.z, boundary.transform.rotation.w)

  local transform = rot:getMatrix()
  transform:setPosition(pos)
  editor.setAxisGizmoTransform(transform)

  -- Set up gizmo callbacks
  editor.updateAxisGizmo(
    function() M.beginBoundaryDrag(boundary) end,
    function() M.endBoundaryDrag(boundary) end,
    function() M.draggingBoundary(boundary) end
  )
end

M.beginBoundaryDrag = function(boundary)
  M.boundaryDragStart = {
    position = {x = boundary.transform.position.x, y = boundary.transform.position.y, z = boundary.transform.position.z},
    rotation = {x = boundary.transform.rotation.x, y = boundary.transform.rotation.y, z = boundary.transform.rotation.z, w = boundary.transform.rotation.w},
    scale = {x = boundary.transform.scale.x, y = boundary.transform.scale.y, z = boundary.transform.scale.z}
  }
end

M.draggingBoundary = function(boundary)
  local strip = M.getSelectedStrip()
  if not strip then return end

  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
    local newPos = vec3(editor.getAxisGizmoTransform():getColumn(3))
    boundary.transform.position = {x = newPos.x, y = newPos.y, z = newPos.z}
    strip._dirty = true
    utils.markUnsavedChanges()
  elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then
    local gizmoTransform = editor.getAxisGizmoTransform()
    local rotation = QuatF(0,0,0,1)
    rotation:setFromMatrix(gizmoTransform)
    boundary.transform.rotation = {x = rotation.x, y = rotation.y, z = rotation.z, w = rotation.w}
    strip._dirty = true
    utils.markUnsavedChanges()
  elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Scale then
    local sclVec = vec3(worldEditorCppApi.getAxisGizmoScale())
    boundary.transform.scale = {x = sclVec.x, y = sclVec.y, z = sclVec.z}
    strip._dirty = true
    utils.markUnsavedChanges()
  end
end

M.endBoundaryDrag = function(boundary)
  M.boundaryDragStart = nil
end

M.drawAxisBox = function(corner, x, y, z, clr)
  for _, face in ipairs({{x,y,z},{x,z,y},{y,z,x}}) do
    local a,b,c = face[1],face[2],face[3]
    debugDrawer:drawLine((corner    ), (corner+c    ), ColorF(0,0,0,0.75))
    debugDrawer:drawLine((corner+a  ), (corner+c+a  ), ColorF(0,0,0,0.75))
    debugDrawer:drawLine((corner+b  ), (corner+c+b  ), ColorF(0,0,0,0.75))
    debugDrawer:drawLine((corner+a+b), (corner+c+a+b), ColorF(0,0,0,0.75))
    debugDrawer:drawTriSolid(
      vec3(corner    ),
      vec3(corner+a  ),
      vec3(corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(corner+b  ),
      vec3(corner    ),
      vec3(corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(corner+a  ),
      vec3(corner    ),
      vec3(corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(corner    ),
      vec3(corner+b  ),
      vec3(corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c+corner    ),
      vec3(c+corner+a  ),
      vec3(c+corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c+corner+b  ),
      vec3(c+corner    ),
      vec3(c+corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c+corner+a  ),
      vec3(c+corner    ),
      vec3(c+corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c+corner    ),
      vec3(c+corner+b  ),
      vec3(c+corner+a+b),
      clr)
  end
end

M.drawBoundariesInWorld = function()
  local strip = M.getSelectedStrip()
  if not strip or not strip.lanes then return end

  for i, lane in ipairs(strip.lanes) do
    if lane.boundary then
      local pos = vec3(lane.boundary.transform.position.x, lane.boundary.transform.position.y, lane.boundary.transform.position.z)
      local rot = quat(lane.boundary.transform.rotation.x, lane.boundary.transform.rotation.y, lane.boundary.transform.rotation.z, lane.boundary.transform.rotation.w)
      local scl = vec3(lane.boundary.transform.scale.x, lane.boundary.transform.scale.y, lane.boundary.transform.scale.z)
      local isSelected = selectedBoundaryIndex == i
      local rgb = laneColorToRgb(lane.color)

      local x = rot * vec3(scl.x, 0, 0)
      local y = rot * vec3(0, scl.y, 0)
      local z = rot * vec3(0, 0, scl.z)
      local sclSum = (x + y + z)
      local corner = -sclSum + pos

      if isSelected then
        M.drawAxisBox(corner, x * 2, y * 2, z * 2, color(255, 0, 255, 0.3 * 255))
        debugDrawer:drawTextAdvanced(pos, String("Boundary"), ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 255))
      else
        local r, g, b = math.floor(rgb[1] * 255), math.floor(rgb[2] * 255), math.floor(rgb[3] * 255)
        M.drawAxisBox(corner, x * 2, y * 2, z * 2, color(r, g, b, 0.2 * 255))
      end
    end
  end
end

return M
