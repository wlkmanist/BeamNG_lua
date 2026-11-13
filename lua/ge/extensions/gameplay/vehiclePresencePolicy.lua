-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local validModes = {
  driver = true,
  passenger = true,
  unrestricted = true,
}

local function isValidMode(mode)
  return validModes[mode] == true
end

local function normalizeMode(mode, fallback)
  return isValidMode(mode) and mode or (isValidMode(fallback) and fallback or "passenger")
end

local function defaultUnseatedMode(context)
  if context and (context.mode == "freeroam" or not context.mode) and not context.isMultiseatActive then
    return "unrestricted"
  end
  return "passenger"
end

local function allowsActionMap(mode, mapKind)
  return mode == "unrestricted" or (mode == "driver" and mapKind == "driving")
end

M.isValidMode = isValidMode
M.normalizeMode = normalizeMode
M.defaultUnseatedMode = defaultUnseatedMode
M.allowsActionMap = allowsActionMap

return M
