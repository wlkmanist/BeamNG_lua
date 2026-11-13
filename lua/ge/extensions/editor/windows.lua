-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- TODO: add favourites section

local M = {}

local ffi = require('ffi')
local im = ui_imgui
local imguiUtils = require('ui/imguiUtils')
local windowName = "windows"
local filter = im.ImGuiTextFilter()

local windowPos
local windowSize

-- [windowKey] = os.clock() deadline for highlight rect
local highlightUntil = {}
local highlightDuration = 3.5
local highlightColor = im.ImVec4(1, 0.45, 0.05, 1)

local function getImGuiWindowName(windowKey, data)
  return ((data and data.title) or windowKey) .. "##" .. windowKey
end

local function resetWindowPos(windowKey, data)
  local vp = im.GetMainViewport()
  local w, h = 400, 300
  if data.lastSize then
    w, h = data.lastSize.x, data.lastSize.y
  elseif data.defaultSize then
    w, h = data.defaultSize.x, data.defaultSize.y
  end
  local pos = im.ImVec2(vp.Pos.x + (vp.Size.x - w) * 0.5, vp.Pos.y + (vp.Size.y - h) * 0.5)
  im.SetWindowPos2(getImGuiWindowName(windowKey, data), pos, im.Cond_Always)
  data.forcePos = {x = pos.x, y = pos.y}
end

local function drawHighlights(windowsData)
  local now = os.clock()
  local dl = nil
  for key, untilTime in pairs(highlightUntil) do
    if now >= untilTime then
      highlightUntil[key] = nil
    else
      local data = windowsData[key]
      if data and data.lastPos and data.lastSize then
        if not dl then dl = im.GetForegroundDrawList1() end
        local p1 = im.ImVec2(data.lastPos.x, data.lastPos.y)
        local p2 = im.ImVec2(data.lastPos.x + data.lastSize.x, data.lastPos.y + data.lastSize.y)
        im.ImDrawList_AddRect(dl, p1, p2, im.GetColorU322(highlightColor), 0, 0, 3 * im.uiscale[0])
      end
    end
  end
end

local function windowPosCheck()
  local mainViewport = im.GetMainViewport()
  local mVPos = mainViewport.Pos
  local mVSize = mainViewport.Size
  local moveWindow = false

  if windowPos.x + windowSize.x -40 < mVPos.x then
    moveWindow = true
  end
  if windowPos.y < mVPos.y then
    moveWindow = true
  end
  if windowPos.x > mVPos.x + mVSize.x then
    moveWindow = true
  end
  if windowPos.y > mVPos.y + mVSize.y then
    moveWindow = true
  end

  if moveWindow then
    im.SetWindowPos2("Windows##" .. windowName, im.ImVec2(mainViewport.Pos.x + 40, mainViewport.Pos.y + 40), im.Cond_Always)
  end
end

local function onEditorGui()
  if editor.beginWindow(windowName, "Windows") then

    windowPos = im.GetWindowPos()
    windowSize = im.GetWindowSize()
    windowPosCheck()

    local windowsData = editor.getWindowsState()
    local windows = {}
    for key, data in pairs(windowsData) do
      table.insert(windows, {key = key, title = data.title or key})
    end
    table.sort(windows, function(a, b) return a.title:lower() < b.title:lower() end)

    editor.uiInputSearchTextFilter("##windowsFilter", filter, im.GetContentRegionAvailWidth())
    if im.BeginChild1("Windows##Child", nil, true) then
      im.Columns(2, "windowsColumns")
      for _, entry in ipairs(windows) do
        if im.ImGuiTextFilter_PassFilter(filter, entry.title) then
          local data = windowsData[entry.key]
          im.TextUnformatted(entry.title)
          im.NextColumn()
          if im.Button("Move to center##" .. entry.key) then
            resetWindowPos(entry.key, data)
          end
          im.SameLine()
          if im.Button("Highlight##" .. entry.key) then
            highlightUntil[entry.key] = os.clock() + highlightDuration
          end
          im.NextColumn()
        end
      end
    end
    im.EndChild()
  end
  editor.endWindow()

  drawHighlights(editor.getWindowsState())
end

local function onWindowMenuItem()
  editor.showWindow(windowName)
end

local function onEditorInitialized()
  editor.registerWindow(windowName, im.ImVec2(800, 500))
  editor.editModes.assetBrowserEditMode = {
    onToolbar = nil,
    icon = nil,
  }

  editor.addWindowMenuItem("Window Position Reset...", onWindowMenuItem)
end

M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized

return M
