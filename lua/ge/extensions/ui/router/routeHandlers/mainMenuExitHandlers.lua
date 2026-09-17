-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.mainmenuExitHandler = function()
  if gameplay_garageMode.isActive() then
    ui_router.navigate("garage")
    return
  end

  local gameContext = core_gamestate.state
  dump("mainmenuExitHandler: gameContext", gameContext)
  if gameContext.state == "freeroam" then
    ui_router.navigate("play")
    return
  end
end

return M