-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = { "ui_appContainers" }

local function onExtensionLoaded()
  ui_appContainers.registerContainer({
    id = "topRight",
    trigger = "setTopRightAppVisibility",
    apps = {
    }
  })
end

M.onExtensionLoaded = onExtensionLoaded

return M
