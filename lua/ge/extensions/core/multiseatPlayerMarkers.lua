-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local validModes = {
  always = true,
  smart = true,
  never = true,
}

function M.normalize(mode)
  if mode == true then return "smart" end
  if mode == false then return "never" end
  return validModes[mode] and mode or "smart"
end

function M.getMode()
  local stored = settings.getValue("multiseatTags", "smart")
  local mode = M.normalize(stored)
  if mode ~= stored then settings.setValue("multiseatTags", mode) end
  return mode
end

function M.setMode(mode)
  mode = M.normalize(mode)
  settings.setValue("multiseatTags", mode)
  return mode
end

function M.isEnabled(mode)
  return M.normalize(mode) ~= "never"
end

return M
