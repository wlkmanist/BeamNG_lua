-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function getGameContext(...)
  if not gameplay_markerInteraction then
    extensions.load('gameplay_markerInteraction')
  end
  if gameplay_markerInteraction then
    return gameplay_markerInteraction.getGameContext(...)
  end
  return {}
end

local function toggleMenues()
  -- disabled for the time being
  --[[
  -- if missionSystem is offline, just use basic hook.
  if not settings.getValue("showMissionMarkers") then
    guihooks.trigger('MenuItemNavigation','toggleMenues')
    return
  else
    if core_input_bindings.isMenuActive then
      if gameplay_missions_missionManager.getForegroundMissionId() then
        if simTimeAuthority.getPause() then
          simTimeAuthority.pause(false)
        end
      end
    else
      if gameplay_missions_missionManager.getForegroundMissionId() then
        if not simTimeAuthority.getPause() then
          simTimeAuthority.pause(true)
        end
      end
    end
    guihooks.trigger('MenuItemNavigation','toggleMenues')
  end
  ]]

end

local function onAnyMissionChanged(state, mission)
  guihooks.trigger('onAnyMissionChanged', state, mission and mission.id)
end



M.onAnyMissionChanged = onAnyMissionChanged

M.getGameContext = getGameContext
M.toggleMenues = toggleMenues
return M
