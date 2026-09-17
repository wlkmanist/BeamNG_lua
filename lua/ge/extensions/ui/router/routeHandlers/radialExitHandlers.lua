-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.radialBackHandler = function()
  if core_quickAccess and core_quickAccess.back and core_quickAccess.back() then
    return {
      result = true,
      success = true,
      data = nil,
    }
  end

  if core_quickAccess and core_quickAccess.setEnabled then
    core_quickAccess.setEnabled(false, "", false)
    return {
      result = true,
      success = true,
      data = nil,
    }
  end

  return {
    result = false,
    success = false,
    reason = "quick_access_unavailable",
  }
end

return M
