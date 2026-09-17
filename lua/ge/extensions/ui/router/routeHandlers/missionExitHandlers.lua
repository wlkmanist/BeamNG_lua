-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.missionDetailsExitHandler = function()
  if extensions.gameplay_missions_missionScreen.isAnyMissionActive() then
    local isMissionStartOrEndScreen = extensions.gameplay_missions_missionScreen.isMissionStartOrEndScreenActive()
    if isMissionStartOrEndScreen then
      return ui_router.navigate("mission.control", {
        mode = isMissionStartOrEndScreen
      })
    end
  end

  ui_router.navigate("play")
end

M.pauseExitHandler = function()
  local screenMode = gameplay_missions_missionScreen and gameplay_missions_missionScreen.isMissionStartOrEndScreenActive()
  if screenMode then
    return ui_router.navigate("mission.control", {
      mode = screenMode
    })
  end

  return ui_router.navigate("play")
end

M.missionVehicleSelectorBackHandler = function()
  local screenMode = extensions.gameplay_missions_missionScreen.isMissionStartOrEndScreenActive()
  if screenMode then
    return ui_router.navigate("mission.control", {
      mode = screenMode
    })
  end

  return ui_router.navigate("play")
end

return M
