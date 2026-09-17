--[[
This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
If a copy of the bCDDL was not distributed with this
file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
This module contains a set of functions which manipulate behaviours of vehicles.
]]

-- extensions.load('jbeam_jbeamMod')

-- this is an example of how you could add things into jbeam loading

local M = {}

local function onJbeamLoadingPhase1(loadingProgress, objID, vehicle, unifyJournal, vehicleConfig, vars)
  log('I', 'extensions.jbeam.jbeamMod', 'onJbeamLoadingPhase1 called :)')
end

local function onJbeamLoadingPhase2(loadingProgress, objID, vehicle, unifyJournal, vehicleConfig, vars)
  log('I', 'extensions.jbeam.jbeamMod', 'onJbeamLoadingPhase2 called :)')
end

M.onJbeamLoadingPhase1 = onJbeamLoadingPhase1
M.onJbeamLoadingPhase2 = onJbeamLoadingPhase2

return M