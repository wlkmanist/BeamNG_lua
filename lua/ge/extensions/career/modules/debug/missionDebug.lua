-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local im = ui_imgui
M.debugOrder = 3
M.debugName = "Missions"

M.drawDebugFunctions = function()
  if im.Selectable1("> Reload Missions") then gameplay_missions_missions.reloadCompleteMissionSystem() end
  if im.Selectable1("> Make All Missions Startable") then
    for _, mission in ipairs(gameplay_missions_missions.getAllMissions()) do
      gameplay_missions_unlocks.overrideStartable(mission, true)
      gameplay_missions_unlocks.overrideVisible(mission, true)
    end
    gameplay_rawPois.clear()
  end
end

return M
