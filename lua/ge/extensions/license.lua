-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local stateCache = {}

local function isValid()
  if stateCache['tech'] == nil then
    if ResearchVerifier == nil then
      return false
    end
    stateCache['tech'] = ResearchVerifier.isTechLicenseVerified() or false
  end
  return stateCache['tech']
end

local function isCommercial()
  if stateCache['commercial'] == nil then
    if CommercialVerifier == nil then
      return false
    end
    stateCache['commercial'] = CommercialVerifier.isCommercialLicense() or false
  end
  return stateCache['commercial']
end

local function requestState()
  guihooks.trigger('TechLicenseState', isValid())
end

-- returns true if it makes sense to load this inputmap
local function isAllowedInputmapPath(path)
  if isValid() then return true end
  return string.find(path, "_beamng.tech") == nil
end

-- returns true if it makes sense to load this inputmap
local function isAllowedActionsPath(path)
  if isValid() then return true end
  return string.find(path, "_beamng.tech") == nil
end

M.isValid = isValid
M.isCommercial = isCommercial
M.requestState = requestState
M.isAllowedInputmapPath = isAllowedInputmapPath
M.isAllowedActionsPath  = isAllowedActionsPath

return M

