-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function buildOptionHelpers()
  return {
    mpNametagsEnabled = {
      set = function(value)
        if multiplayer_nametags then
          multiplayer_nametags.nametagsEnabled = value
        end
      end,
      -- get = function()
      --   if multiplayer_nametags then
      --     return multiplayer_nametags.nametagsEnabled
      --   end
      -- end
    },
    mpNametagDistance = {
      set = function(value)
        if multiplayer_nametags then
          multiplayer_nametags.nametagDistance = value
        end
      end,
      -- get = function()
      --   if multiplayer_nametags then
      --     return multiplayer_nametags.nametagDistance
      --   end
      -- end
    },
    mpEnableSwitchingToPlayerVehicles = {
      set = function(value)
        if multiplayer_vehicleSync then
          multiplayer_vehicleSync.enableSwitchingToPlayerVehicles(value)
        end
      end
    },
    mpDebugMode = {
      set = function(value)
        if multiplayer_multiplayer then
          multiplayer_multiplayer.debugMode = value
        end
      end
    },

    mpUseCustomServiceURL = {
      set = function(value)
        if multiplayer_sessionManager then
          multiplayer_sessionManager.useCustomServiceURL = value
        end
      end,
      -- get = function()
      --   if multiplayer_sessionManager then
      --     return multiplayer_sessionManager.useCustomServiceURL
      --   end
      -- end
    },
    mpCustomServiceURL = {
      set = function(value)
        if multiplayer_sessionManager then
          multiplayer_sessionManager.customServiceURL = value
        end
      end,
      -- get = function()
      --   if multiplayer_sessionManager then
      --     return multiplayer_sessionManager.customServiceURL
      --   end
      -- end
    }
  }
end

M.buildOptionHelpers = buildOptionHelpers

return M
