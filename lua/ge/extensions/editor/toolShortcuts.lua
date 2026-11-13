-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local toolWindowName = "editModeShortcuts"
local shortcutsPath = "settings/editor/editModeShortcuts.json"
local toolCount = 9
local hasCustomAssignments = false
local assignments = {}
local searchFilter = im.ImGuiTextFilter()

local function getModeLabel(modeKey)
  local mode = modeKey and editor.editModes[modeKey]
  if not mode then return "None" end
  return mode.iconTooltip or mode.displayName or modeKey
end

local function getDefaultModeKeys()
  local sortedKeys = {}
  for key, mode in pairs(editor.editModes) do
    if key ~= "objectSelect" and key ~= "createObject" and mode.icon then
      table.insert(sortedKeys, key)
    end
  end
  table.sort(sortedKeys)
  table.insert(sortedKeys, 1, "objectSelect")
  table.insert(sortedKeys, 2, "createObject")
  return sortedKeys
end

local function getAssignableModes()
  local modes = {}
  for key, mode in pairs(editor.editModes) do
    if mode.icon then
      table.insert(modes, {key = key, name = mode.iconTooltip or mode.displayName or key})
    end
  end
  table.sort(modes, function(a, b) return a.name < b.name end)
  return modes
end

local function saveAssignments()
  local data = {}
  for i = 1, toolCount do
    data["F" .. (i + 1)] = assignments[i] or ""
  end
  jsonWriteFile(shortcutsPath, data, true)
end

local function loadAssignments()
  hasCustomAssignments = false
  assignments = {}
  if not FS:fileExists(shortcutsPath) then return end
  local ok, data = pcall(jsonReadFile, shortcutsPath)
  if not ok or type(data) ~= "table" then return end
  hasCustomAssignments = true
  for i = 1, toolCount do
    local value = data["F" .. (i + 1)]
    if type(value) == "string" and value ~= "" then
      assignments[i] = value
    end
  end
end

local function getAssignedKey(index)
  if hasCustomAssignments then
    return assignments[index]
  end
  return getDefaultModeKeys()[index]
end

local function ensureCustomAssignments()
  if hasCustomAssignments then return end
  local defaults = getDefaultModeKeys()
  for i = 1, toolCount do
    assignments[i] = defaults[i]
  end
  hasCustomAssignments = true
end

local function setAssignment(index, modeKey)
  ensureCustomAssignments()
  assignments[index] = modeKey
  saveAssignments()
end

local function resetAssignments()
  local defaults = getDefaultModeKeys()
  assignments = {}
  for i = 1, toolCount do
    assignments[i] = defaults[i]
  end
  hasCustomAssignments = true
  saveAssignments()
end

local function openTool(index)
  local modeKey = getAssignedKey(index)
  local mode = modeKey and editor.editModes[modeKey]
  if mode then
    editor.selectEditMode(mode)
  end
end

local function openWindow()
  editor.showWindow(toolWindowName)
end

local function onEditorGui()
  if editor.beginWindow(toolWindowName, "Edit Mode Shortcuts") then
    im.TextUnformatted("Assign edit modes to F2-F10")
    im.Separator()

    local assignableModes = getAssignableModes()
    local iconSize = im.ImVec2(18, 18)

    for i = 1, toolCount do
      im.PushID1("editModeShortcut" .. i)
      local modeKey = getAssignedKey(i)
      local mode = modeKey and editor.editModes[modeKey]
      if mode and mode.icon then
        editor.uiIconImage(mode.icon, iconSize)
      else
        im.Dummy(iconSize)
      end
      im.SameLine()
      im.AlignTextToFramePadding()
      im.TextUnformatted("F" .. (i + 1))
      im.SameLine()
      im.SetNextItemWidth(-1)
      if im.BeginCombo("##mode", getModeLabel(modeKey), im.ComboFlags_HeightLarge) then
        if im.IsWindowAppearing() then
          im.ImGuiTextFilter_Clear(searchFilter)
          im.SetKeyboardFocusHere()
        end
        editor.uiInputSearchTextFilter("Search...", searchFilter, im.GetContentRegionAvailWidth())
        im.BeginChild1("##modeList", im.ImVec2(0, im.GetTextLineHeightWithSpacing() * 10), true)
        if im.ImGuiTextFilter_PassFilter(searchFilter, "None") then
          if im.Selectable1("None", modeKey == nil) then
            setAssignment(i, nil)
          end
        end
        for _, item in ipairs(assignableModes) do
          if im.ImGuiTextFilter_PassFilter(searchFilter, item.name) then
            if im.Selectable1(item.name .. "##" .. item.key, modeKey == item.key) then
              setAssignment(i, item.key)
            end
          end
        end
        im.EndChild()
        im.EndCombo()
      end
      im.PopID()
    end

    im.Separator()
    if im.Button("Reset to Defaults") then
      resetAssignments()
    end
  end
  editor.endWindow()
end

local function onEditorInitialized()
  loadAssignments()
  editor.registerWindow(toolWindowName, im.ImVec2(380, 380))
  for i = 1, toolCount do
    editor["openTool" .. i] = function()
      openTool(i)
    end
  end
end

M.openWindow = openWindow
M.onEditorInitialized = onEditorInitialized
M.onEditorGui = onEditorGui

return M
