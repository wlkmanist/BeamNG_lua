-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = 'editor_bulk_rename'
local imgui = ui_imgui
local imUtils = require('ui/imguiUtils')
local objectHistoryActions = require("editor/api/objectHistoryActions")()
local toolWindowName = "bulkRename"
local filter = imgui.ImGuiTextFilter()
local renamePatternInput = imgui.ArrayChar(1024, "%o")
local fieldToRenamePtr = imgui.IntPtr(0)
local fieldToSearchPtr = imgui.IntPtr(0)
local whatSetPtr = imgui.IntPtr(0)
local useGeneratedNamePtr = imgui.BoolPtr(1)
local foundCount = 0
local previewNames = {}
local maxPreviewNamesCount = 10
local objectIds = {}
local collisionCount = 0

local function generateNewName(name, pattern, counter)
    local newName = pattern

    -- replace %n or things like %4n with the counter
    newName = newName:gsub("%%(%d*)n", function(width)
      if width == "" then
        return tostring(counter)
      else
        return string.format("%0" .. width .. "d", counter)
      end
    end)
    -- replace %o with the old name
    newName = newName:gsub("%%o", name)

    return newName
end

local function doBulkRename()
  local changeInternalName = fieldToRenamePtr[0] == 1
  local ids = {}
  local newNames = {}
  local fieldName

  for id, entry in pairs(previewNames) do
    table.insert(ids, id)
    table.insert(newNames, entry.new)
  end

  if changeInternalName then
    fieldName = "internalName"
  else
    fieldName = "name"
  end

  objectHistoryActions.changeObjectFieldMultipleValuesWithUndo(ids, fieldName, newNames)
  editor_sceneTree.recacheAllNodes()
end

local function findCollisionWithNewName(ownerId, newName)
  for id, entry in pairs(previewNames) do
    -- we skip the id we check with the others
    if ownerId ~= id then
      if entry.new == newName then
        return id
      end
    end
  end

  return 0
end

local function checkNameCollisions()
  local changeInternalName = fieldToRenamePtr[0] == 1

  collisionCount = 0

  for id, entry in pairs(previewNames) do
    local objId
    entry.collidedWithId = 0

    -- search first in our current set
    objId = findCollisionWithNewName(id, entry.new)

    if objId == 0 then
      -- otherwise, search the whole tree
      local obj = scenetree.findObject(entry.new)
      if obj then
        if obj:getID() ~= id then
          objId = obj:getID()
        end
      end
    end

    if objId ~= 0 then
      -- we have unique name collision only on `name` field, internalName can collide
      if not changeInternalName then
        entry.collidedWithId = objId
        collisionCount = collisionCount + 1
      end
    end
  end
end

local function updatePreview()
  local matchInternalName = fieldToSearchPtr[0] == 1
  local filterStr = ffi.string(imgui.TextFilter_GetInputBuf(filter))

  if whatSetPtr[0] == 1 and filterStr ~= "" then
    objectIds = Sim.findObjectsByNameMask(ffi.string(imgui.TextFilter_GetInputBuf(filter)), matchInternalName, useGeneratedNamePtr[0])
  elseif whatSetPtr[0] == 0 then
    objectIds = deepcopy(editor.selection.object)

    if not objectIds then objectIds = {} end
  end

  foundCount = #objectIds
  previewNames = {}

  local counter = 1
  local name = ""
  local obj

  for _, id in ipairs(objectIds) do
    obj = scenetree.findObjectById(id)

    if obj then
      local oldName = obj:getGeneratedDisplayName(matchInternalName)
      name = generateNewName(oldName, ffi.string(renamePatternInput), counter)
      previewNames[id] = {old = oldName, new = name}
      counter = counter + 1
    end
  end

  checkNameCollisions()
end

local function onEditorGui()
  if editor.beginWindow(toolWindowName, "Bulk Rename") then

    imgui.Text("Field to rename:")
    if imgui.RadioButton2("name", fieldToRenamePtr, 0) then
      updatePreview()
    end
    if imgui.RadioButton2("internalName", fieldToRenamePtr, 1) then
      updatePreview()
    end

    imgui.Spacing()
    imgui.Separator()

    imgui.Text("Objects to rename:")
    if imgui.RadioButton2("Current Selection", whatSetPtr, 0) then
      updatePreview()
    end

    if imgui.RadioButton2("Match Pattern", whatSetPtr, 1) then
      updatePreview()
    end

    if whatSetPtr[0] == 1 then
      imgui.Text("Field to search:")
      if imgui.RadioButton2("name##searchField", fieldToSearchPtr, 0) then
        updatePreview()
      end
      if imgui.RadioButton2("internalName##searchField", fieldToSearchPtr, 1) then
        updatePreview()
      end
      if imgui.Checkbox("Also use object asset filename in filtering", useGeneratedNamePtr) then
        updatePreview()
      end
      imgui.Separator()

      imgui.Text("Search Pattern: (use * to match any substring, ? to match any single character)")
      if editor.uiInputSearchTextFilter("##renameFilter", filter, imgui.GetContentRegionAvailWidth(), nil, nil) then
        updatePreview()
        if ffi.string(imgui.TextFilter_GetInputBuf(filter)) == "" then
          imgui.ImGuiTextFilter_Clear(filter)
        end
      end
    end

    imgui.Separator()
    imgui.Text("Rename Pattern: (use %n or %Xn, where X is the number width, to insert counter, or %o to insert old name)")

    if editor.uiInputText("##renamePattern", renamePatternInput, 1024) then
      updatePreview()
    end

    imgui.Spacing()
    imgui.PushStyleColor2(imgui.Col_Button, imgui.ImColorByRGB(10, 150, 0, 255))
    if imgui.Button("   R E N A M E   ") then
      doBulkRename()
    end
    imgui.PopStyleColor()
    imgui.Spacing()

    imgui.Separator()
    imgui.Text("Found: " .. tostring(foundCount))
    imgui.Separator()
    imgui.Text("Preview:")

    imgui.BeginChild1("TableChild", imgui.ImVec2(0, 0), 0)
    if imgui.BeginTable("RenamePreviewTable", 4, bit.bor(imgui.TableFlags_Borders, imgui.TableFlags_RowBg, imgui.TableFlags_ScrollY)) then
        -- Setup columns
        imgui.TableSetupColumn("Old Name", imgui.TableColumnFlags_WidthStretch)
        imgui.TableSetupColumn("New Name", imgui.TableColumnFlags_WidthStretch)
        imgui.TableSetupColumn("ID", imgui.TableColumnFlags_WidthStretch)

        local collisionCountStr = ""

        if collisionCount ~= 0 then
          collisionCountStr = " (" .. tostring(collisionCount) .. ")"
        end

        imgui.TableSetupColumn("Collision ID" .. collisionCountStr, imgui.TableColumnFlags_WidthStretch)
        imgui.TableSetupScrollFreeze(0, 1)
        imgui.TableHeadersRow()

        -- Populate rows
        for id, entry in pairs(previewNames) do
            imgui.TableNextRow()
            imgui.TableSetColumnIndex(0)
            imgui.Text(entry.old)
            imgui.TableSetColumnIndex(1)
            imgui.Text(entry.new)
            imgui.TableSetColumnIndex(2)
            imgui.Text(tostring(id))
            imgui.TableSetColumnIndex(3)

            if entry.collidedWithId ~= 0 then
              imgui.TextColored(imgui.ImVec4(255, 0, 0, 255), tostring(entry.collidedWithId))
            end
        end

        imgui.EndTable()
    end

    imgui.EndChild()
  end
  editor.endWindow()
end

local function onEditorActivated()
end

local function onEditorObjectSelectionChanged()
  updatePreview()
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  editor.registerWindow(toolWindowName, imgui.ImVec2(600, 600))
  editor.addWindowMenuItem("Bulk Rename", onWindowMenuItem)
end

local function onExtensionLoaded()
end

M.onEditorInitialized = onEditorInitialized
M.onEditorActivated = onEditorActivated
M.onEditorGui = onEditorGui
M.onExtensionLoaded = onExtensionLoaded
M.onEditorObjectSelectionChanged = onEditorObjectSelectionChanged
return M