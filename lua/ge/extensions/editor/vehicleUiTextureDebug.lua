-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'ui_imgui'}

local im

local toolWindowName = 'Vehicle UI Textures'

local selectedVehicleId = nil
local selectedTag = nil

local function vehId(veh)
  if not veh then return nil end
  if veh.getId then return veh:getId() end
  if veh.getID then return veh:getID() end
  return nil
end

local function vehLabel(veh)
  if not veh then return "(nil)" end
  local id = vehId(veh)
  local jb = veh.jbeam and tostring(veh.jbeam) or "?"
  return string.format("%s [%s]", tostring(id), jb)
end

local function collectSortedTags(tags)
  local list = {}
  if not tags then return list end
  if type(tags) ~= "table" then return list end
  for _, t in ipairs(tags) do
    list[#list + 1] = t
  end
  if #list == 0 then
    for _, t in pairs(tags) do
      list[#list + 1] = t
    end
  end
  table.sort(list, function(a, b) return tostring(a) < tostring(b) end)
  return list
end

local function tagInList(tag, list)
  for _, t in ipairs(list) do
    if t == tag then return true end
  end
  return false
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  im = ui_imgui
  editor.registerWindow(toolWindowName, im.ImVec2(520, 420))
  editor.addWindowMenuItem(toolWindowName, onWindowMenuItem, {groupMenuName = 'Vehicles'})
end

local function onEditorGui()
  if not editor.beginWindow(toolWindowName, "Vehicle UI Textures") then
    editor.endWindow()
    return
  end

  local vehicles = getAllVehicles()
  if not vehicles or #vehicles == 0 then
    im.Text("No vehicles spawned.")
    selectedVehicleId = nil
    selectedTag = nil
    editor.endWindow()
    return
  end

  local foundSel = false
  for _, v in ipairs(vehicles) do
    if vehId(v) == selectedVehicleId then
      foundSel = true
      break
    end
  end
  if not foundSel then
    selectedVehicleId = vehId(vehicles[1])
    selectedTag = nil
  end

  local vehComboLabel = "(none)"
  for _, v in ipairs(vehicles) do
    if vehId(v) == selectedVehicleId then
      vehComboLabel = vehLabel(v)
      break
    end
  end

  if im.BeginCombo("Vehicle", vehComboLabel) then
    for _, v in ipairs(vehicles) do
      local id = vehId(v)
      if im.Selectable1(vehLabel(v), id == selectedVehicleId) then
        selectedVehicleId = id
        selectedTag = nil
      end
    end
    im.EndCombo()
  end

  local veh = getObjectByID(selectedVehicleId)
  if not veh then
    im.Text("Could not resolve vehicle object.")
    editor.endWindow()
    return
  end

  local tags = veh:getActiveUITextureTagNames()
  if #tags == 0 then
    im.TextColored(im.ImVec4(1, 0.35, 0.35, 1), "no HTML textures found.")
    editor.endWindow()
    return
  end

  local tagList = collectSortedTags(tags)

  if #tagList == 0 then
    im.Text("No active UI texture tags.")
    selectedTag = nil
    editor.endWindow()
    return
  end

  if not selectedTag or not tagInList(selectedTag, tagList) then
    selectedTag = tagList[1]
  end

  if im.BeginCombo("Tag", tostring(selectedTag)) then
    for _, t in ipairs(tagList) do
      if im.Selectable1(tostring(t), t == selectedTag) then
        selectedTag = t
      end
    end
    im.EndCombo()
  end

  im.Separator()

  local openVal = veh:getConsoleOpenUITexture(selectedTag)
  local isOpen = openVal and openVal ~= false and openVal ~= 0
  im.Text("UI texture console open: " .. tostring(openVal))
  if im.Button(isOpen and "Hide console" or "Show console") then
    veh:openConsoleUITexture(selectedTag, not isOpen)
  end

  if im.Button("Dump texture##vehicleUiTexDumpBtn") then
    local datetime = os.date("!%Y-%m-%dT%H-%M-%S")
    local targetFilename = "/vehicle_ui_" .. tostring(selectedTag) .. "_" .. datetime .. ".png"

    if veh:dumpCEFTexture(selectedTag, targetFilename) then
      log("I", logTag, "dumpCEFTexture ok: " .. tostring(targetFilename) )
    else
      log("E", logTag, "dumpCEFTexture failed: " .. tostring(selectedTag) )
    end
  end

  im.Separator()

  local info = veh:getActiveUITextureDebugInfo(selectedTag)
  if type(info) ~= "table" then
    im.TextColored(im.ImVec4(1, 0.35, 0.35, 1), "getActiveUITextureDebugInfo() did not return a table.")
  else
    im.Text("fps: " .. tostring(info.fps))
    im.Text("tagName: " .. tostring(info.tagName))
    im.Text("texWidth: " .. tostring(info.texWidth))
    im.Text("texHeight: " .. tostring(info.texHeight))
    im.Text("usageMode: " .. tostring(info.usageMode))
    im.Text("startURL:")
    im.TextWrapped(tostring(info.startURL))

  end

  editor.endWindow()
end

M.onEditorInitialized = onEditorInitialized
M.onEditorGui = onEditorGui

return M
