-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = 'util_resolution'

local function getVideoModeSnapshot()
  if not GFXDevice or type(GFXDevice.getVideoMode) ~= "function" then
    return nil
  end

  local vm = GFXDevice.getVideoMode()
  if type(vm) ~= "table" then
    return nil
  end

  return {
    width = tonumber(vm.width),
    height = tonumber(vm.height),
    displayMode = tostring(vm.displayMode or ""),
  }
end

-- Sets the game window to a specific resolution in Window mode (NOT borderless)
-- Console usage:
--   extensions.reload('util_resolution')
--   extensions.util_resolution.setWindowedResolution(1280, 720)
local function setWindowedResolution(width, height)
  if type(width) ~= 'number' or type(height) ~= 'number' then
    log('E', logTag, 'Invalid arguments. Usage: setWindowedResolution(number width, number height)')
    return
  end

  local vm = GFXDevice.getVideoMode()
  if vm.width == width and vm.height == height and vm.displayMode == 'Window' then
    log('I', logTag, string.format('Video mode already set to %dx%d (Window)', width, height))
    return
  end

  vm.width = width
  vm.height = height
  vm.displayMode = 'Window'

  log('I', logTag, string.format('[CMD] Setting video mode to %dx%d (Window)', width, height))
  GFXDevice.setVideoMode(vm)
end

M.getVideoModeSnapshot = getVideoModeSnapshot
M.setWindowedResolution = setWindowedResolution

return M


