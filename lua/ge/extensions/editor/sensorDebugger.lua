-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Window->Tech->Sensor Debugger, visible with .tech license

local M = {}

-- not doing this rn because it can break for non-tech versions
-- M.dependencies = {"tech_sensors"}

local im = ui_imgui

local toolWindowName = 'CameraSensorDebugger'
local enabled = false
local isOpen = false

local camIds = {}

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  if not ResearchVerifier.isTechLicenseVerified() then
    enabled = false
    return
  end
  extensions.load('tech/cameraPreview')
  enabled = true

  editor.registerWindow(toolWindowName, im.ImVec2(600, 600))
  editor.addWindowMenuItem('Camera Sensor Debug', onWindowMenuItem, {groupMenuName = 'Tech'})
end

local function startAllPreviews()
  local camData = tech_cameraPreview.getCamData()
  for id, cam in pairs(camData) do
    if not cam.visualize[0] then
      cam.visualize[0] = true
      tech_cameraPreview.changeCamDebugState(cam)
    end
    cam.showColor[0] = true
    cam.showAnnotation[0] = true
    cam.showDepth[0] = true
  end
end

local function stopAllPreviews()
  local camData = tech_cameraPreview.getCamData()
  for id, cam in pairs(camData) do
    if cam.visualize[0] then
      cam.visualize[0] = false
      tech_cameraPreview.changeCamDebugState(cam)
    end
  end
end

local function onEditorGui()
  if not enabled then return end

  if editor.beginWindow(toolWindowName, 'Camera Sensor Debug') then
    local camData = tech_cameraPreview.getCamData()
    if next(camData) == nil then
      im.Text('No camera sensors found.')
    else
      if im.Button("Preview all cameras") then
        startAllPreviews()
      end
      im.SameLine()
      if im.Button("Hide all cameras") then
        stopAllPreviews()
      end
    end
    for id, cam in pairs(camData) do
      im.Text(tech_sensors.getCameraSensorName(cam.id))
      if im.Checkbox("Visualize##" .. cam.id, cam.visualize) then
        tech_cameraPreview.changeCamDebugState(cam)
      end
      if cam.visualize[0] then
        tech_cameraPreview.visualizeCameraById(cam.id)
      end
      im.Separator()
    end
    isOpen = true
  elseif isOpen then
    stopAllPreviews()
    isOpen = false
  end
  editor.endWindow()
end

M.onEditorInitialized = onEditorInitialized
M.onEditorGui = onEditorGui

return M
