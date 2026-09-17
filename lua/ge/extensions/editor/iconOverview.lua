-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = 'editor_icon_overview'
local imgui = ui_imgui
local imUtils = require('ui/imguiUtils')
local toolWindowName = "iconOverview"
local icons
local size = imgui.ImVec2(32,32)
local style
local io
local filter = imgui.ImGuiTextFilter()
local iconClipper = imgui.ImGuiListClipper()
local filteredIcons = {}
local showClipperDebug = false
local clipperDebugText = ""
local lastClipperDebugText = ""

local function menu()
  if imgui.BeginMenuBar() then
    if imgui.MenuItem1("Re-create icon atlas") then
      editor.createIconAtlas()
      icons = tableKeys(editor.icons)
      table.sort(icons)
    end
    imgui.EndMenuBar()
  end
end

local function onEditorGui()
  if editor.beginWindow(toolWindowName, "Available Icons") then
    menu()
    M.drawContent(function(v) imgui.SetClipboardText(v) end)
  end
  editor.endWindow()
end

local function drawContent(selectedFun)
  if not selectedFun then selectedFun = nop end
  if editor.uiInputSearchTextFilter("##iconFilter", filter, imgui.GetContentRegionAvailWidth(), nil, editEnded) then
    if ffi.string(imgui.TextFilter_GetInputBuf(filter)) == "" then
      imgui.ImGuiTextFilter_Clear(filter)
    end
  end
  if imgui.BeginChild1("iconChild", imgui.ImVec2(0, imgui.GetContentRegionAvail().y-imgui.GetFontSize() - 2*imgui.GetStyle().ItemSpacing.y), false) then
    local availableWidth = imgui.GetContentRegionAvailWidth()

    table.clear(filteredIcons)
    for i = 1, #icons do
      local v = icons[i]
      if imgui.ImGuiTextFilter_PassFilter(filter, v) then
        filteredIcons[#filteredIcons + 1] = v
      end
    end

    local buttonWidth = (size.x * imgui.uiscale[0]) + (style.FramePadding.x * 2)
    local itemStrideX = buttonWidth + style.ItemSpacing.x
    local itemsPerRow = math.max(1, math.floor((availableWidth + style.ItemSpacing.x) / itemStrideX))

    local rowHeight = (size.y * imgui.uiscale[0]) + (style.FramePadding.y * 2) + style.ItemSpacing.y
    local rowCount = math.ceil(#filteredIcons / itemsPerRow)

    local debugMinRow, debugMaxRowExcl, debugDrawn = nil, nil, 0
    if rowCount > 0 then
      imgui.ImGuiListClipper_Begin(iconClipper, rowCount, rowHeight)
      while imgui.ImGuiListClipper_Step(iconClipper) do
        if showClipperDebug then
          debugMinRow = debugMinRow and math.min(debugMinRow, iconClipper.DisplayStart) or iconClipper.DisplayStart
          debugMaxRowExcl = debugMaxRowExcl and math.max(debugMaxRowExcl, iconClipper.DisplayEnd) or iconClipper.DisplayEnd
        end
        for row = iconClipper.DisplayStart, iconClipper.DisplayEnd - 1 do
          local base = (row * itemsPerRow)
          for col = 1, itemsPerRow do
            local v = filteredIcons[base + col]
            if not v then break end
            if col ~= 1 then imgui.SameLine() end
            if editor.icons[v] then
              if editor.uiIconImageButton(editor.icons[v], size, imgui.ImColorByRGB(255,255,255,255).Value, nil, imgui.ImColorByRGB(128,128,128,128).Value, v) then
                selectedFun(v)
              end
            else
              log('E', logTag, "Icon with key '" .. v .. "' not existent!")
            end
            imgui.tooltip(v)
            if showClipperDebug then debugDrawn = debugDrawn + 1 end
          end
        end
      end
    end

    if showClipperDebug then
      if debugMinRow == nil then
        clipperDebugText = string.format("clipper: rows 0..0, items 0..0, drawn 0 / %d (itemsPerRow=%d)", #filteredIcons, itemsPerRow)
      else
        local firstIndex = debugMinRow * itemsPerRow + 1
        local lastIndex = math.min(#filteredIcons, debugMaxRowExcl * itemsPerRow)
        local firstKey = filteredIcons[firstIndex] or ""
        local lastKey = filteredIcons[lastIndex] or ""
        clipperDebugText = string.format("clipper: rows %d..%d, items %d..%d (%s .. %s), drawn %d / %d (itemsPerRow=%d)",
          debugMinRow, debugMaxRowExcl - 1, firstIndex, lastIndex, firstKey, lastKey, debugDrawn, #filteredIcons, itemsPerRow)
      end
      if clipperDebugText ~= lastClipperDebugText then
        lastClipperDebugText = clipperDebugText
        log('I', logTag, clipperDebugText)
      end
    end
  end
  imgui.EndChild()
  if showClipperDebug then
    imgui.TextUnformatted(clipperDebugText)
  end
end

local function onEditorActivated()
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  icons = tableKeys(editor.icons)
  table.sort(icons)
  style = imgui.GetStyle()
  editor.registerWindow(toolWindowName, imgui.ImVec2(600, 600))
  editor.addWindowMenuItem("Available Icons", onWindowMenuItem, {groupMenuName = 'Debug'})
end

local function onExtensionLoaded()
end

M.onEditorInitialized = onEditorInitialized
M.onEditorActivated = onEditorActivated
M.onEditorGui = onEditorGui
M.onExtensionLoaded = onExtensionLoaded
M.open = onWindowMenuItem
M.drawContent = drawContent
return M