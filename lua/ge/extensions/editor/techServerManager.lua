-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Window->Tech->BeamNGpy Server, visible with .tech license

local M = {}

-- not doing this rn because it can break for non-tech versions
-- M.dependencies = {"tech_techCore"}

local im = ui_imgui

local toolWindowName = 'TechServerManager'

local enabled = false
local openServerGuiData = {
  ip = im.ArrayChar(40, '127.0.0.1'),
  allInterfaces = im.BoolPtr(false),
  port = im.IntPtr(0),
}

local function drawOpenServerGUI()
  if not enabled then return end
  local serverRunning = tech_techCore.isServerRunning()
  im.Text(serverRunning and 'Status: Running' or 'Status: Stopped')
  if serverRunning then
    local tcomParams = tech_techCore.getTcomParams()
    ffi.copy(openServerGuiData.ip, tcomParams.ip)
    openServerGuiData.port[0] = tcomParams.port
  end

  if serverRunning then im.BeginDisabled() end
  if not openServerGuiData.allInterfaces[0] then
    im.InputText("Listen IP address", openServerGuiData.ip)
  end
  im.Checkbox('Listen on all interfaces', openServerGuiData.allInterfaces)
  im.InputInt('Port', openServerGuiData.port)
  if serverRunning then
    im.EndDisabled()
    if im.Button('Stop server') then
      tech_techCore.closeServer()
    end
  else
    if im.Button('Start server') then
      local ip
      if openServerGuiData.allInterfaces[0] then
        ip = '*'
      else
        ip = ffi.string(openServerGuiData.ip)
      end
      local port = openServerGuiData.port[0]
      tech_techCore.setTcomParams(ip, port)
      tech_techCore.openServer(port)
    end
  end
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  if not tech_license.isValid() then
    enabled = false
    return
  end
  extensions.load('tech/techCore')
  enabled = true
  local tcomParams = tech_techCore.getTcomParams()
  openServerGuiData.port[0] = tcomParams.port

  editor.registerWindow(toolWindowName, im.ImVec2(500, 155))
  editor.addWindowMenuItem('BeamNGpy Server', onWindowMenuItem, {groupMenuName = 'Tech'})
end

local function onEditorGui()
  if not enabled then return end

  if editor.beginWindow(toolWindowName, 'BeamNGpy Server', im.flags(im.WindowFlags_NoCollapse, im.WindowFlags_AlwaysAutoResize, im.WindowFlags_NoScrollbar)) then
    drawOpenServerGUI()
  end
  editor.endWindow()
end

M.onEditorInitialized = onEditorInitialized
M.onEditorGui = onEditorGui

return M
