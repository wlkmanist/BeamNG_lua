-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

local moduleName = "interactSpecialLights"
M.moduleActions = {}
M.moduleLookups = {}

local function setTaxiLightState(params)
  local dataTypeCheck, dataTypeError = checkTableDataTypes(params, {"string"})
  if not dataTypeCheck then
    return {failReason = dataTypeError}
  end

  local state = params[1]
  for _, taxiLights in ipairs(controller.getControllersByType("lights/taxiLights")) do
    taxiLights.setTaxiState(state)
  end
end

local function getTaxiLightState(params)
  local dataTypeCheck, dataTypeError = checkTableDataTypes(params, {})
  if not dataTypeCheck then
    return {failReason = dataTypeError}
  end

  local taxiLights = controller.getControllersByType("lights/taxiLights")[1]
  return {result = taxiLights and taxiLights.getTaxiState() or nil}
end

local function requestRegistration(gi)
  gi.registerModule(moduleName, M.moduleActions, M.moduleLookups)
end

local function onExtensionLoaded()
  M.moduleActions.setTaxiLightState = setTaxiLightState
  M.moduleLookups.taxiLightState = getTaxiLightState
end

M.onExtensionLoaded = onExtensionLoaded
M.requestRegistration = requestRegistration

return M
