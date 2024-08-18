-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.canvasCreated = false

M.checkDeviceIsNonINTEL = function(newDevice)
  -- log("I", "", "checkDeviceIsNonINTEL called.....")
  if newDevice == M.checkedLastDevice then
    return
  end

  M.checkedLastDevice = newDevice;

  if string.find(string.upper(newDevice), "INTEL") == nil then
    return
  end

  local adapters = GFXInit.getAdapters()
  for _,adapter in ipairs(adapters) do
    dump(adapter.fullDesc)
    if string.find(string.upper(newDevice), "INTEL") ~= nil then
      TorqueScriptLua.call( 'MessageBoxOK', 'Performance Warning', 'You are using an Intel GPU, please choose a different one to improve performance' )
      return
    end
  end
end

M.createCanvas = function(windowPlacement)
  if getConsoleVariable("$forceFullscreen") then
    setConsoleVariable("$pref::Video::displayOutputDevice", "")
  end

  M.checkDeviceIsNonINTEL(getDisplayDeviceInformation())

  local canvas = scenetree.findObject("Canvas")
  if not canvas then
    -- Create the Canvas
    canvas = createObject("GuiCanvas")
    canvas.displayWindow = false
    canvas:registerObject("Canvas")
  end

  if getConsoleVariable("$pref::Video::autoDetect") then
    core_settings_graphic.autoDetectApplyGraphicsQuality()
  end

  return canvas
end

M.initializeCanvas = function()
    -- Don't duplicate the canvas.
    if M.canvasCreated then
      log("E", "canvas", "Cannot instantiate more than one canvas!")
      return
    end

    local graphicsOptions = core_settings_graphic.getOptions()
    local windowPlacement = graphicsOptions.WindowPlacement.get()

    local canvas = M.createCanvas(windowPlacement)
    if not canvas then
      log("E", "canvas", "Canvas creation failed. Shutting down.")
      quit()
    end

    M.canvasCreated = true;
    return canvas
end

M.showCursor = function()
  -- log("I", "canvas", "showCursor called")
  lockMouse(false)
  local canvas = scenetree.findObject("Canvas")
  if canvas then
    canvas:setCursorVisible(true)
  end
end

M.hideCursor = function()
  -- log("I", "canvas", "hideCursor called")
  lockMouse(true)
  local canvas = scenetree.findObject("Canvas")
  if canvas then
    canvas:setCursorVisible(false)
  end
end

return M