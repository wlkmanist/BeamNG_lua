-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Optick rolling capture: the first toggle starts recording only the last few seconds,
-- the next one saves them to <userFolder>/optick/ and stops recording.

local M = {}

local logTag = 'optickRollingCapture'
local windowSeconds = 20

local function notify(msg)
  log('I', logTag, msg)
  ui_message(msg, 10, logTag)
end

function M.toggle()
  local profiler = Engine.Profiler
  if profiler.isCapturing() then
    FS:directoryCreate('optick', true)
    local path = FS:getUserPath() .. 'optick/optick_rolling_' .. os.date('%Y-%m-%d_%H-%M-%S') .. '.opt'
    profiler.stopCapture()
    profiler.saveCapture(path)
    notify('Saved Optick capture: ' .. path)
    if launchOptick then launchOptick(path) end
  else
    profiler.startRollingCapture(windowSeconds)
    notify('Optick rolling capture started (last ' .. windowSeconds .. ' s). Press again to save it.')
  end
end

return M
