-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

-- get available color corrections files
local function getColorCorrections()
  local result = {}
  for i,file in ipairs(FS:findFiles('art/postfx', '*.png', 0, false, false)) do
    table.insert(result, {filename=file})
  end
  return result
end

M.getColorCorrections = getColorCorrections
return M