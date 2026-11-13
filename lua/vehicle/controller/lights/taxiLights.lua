-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--Purpose: Displays taxi availability and service states through sign lighting

local M = {}
M.type = "auxiliary"

local taxiStates = {
  available = "available",
  occupied = "occupied",
  reserved = "reserved",
  offDuty = "offDuty",
  driverDistress = "driverDistress"
}

local stateElectrics
local taxiState

local stateData
local stateDataNameTaxiState

local function updateGFX(dt)
  --iterate the possible electrics and update them according to the taxi state
  for state, electricsName in pairs(stateElectrics) do
    electrics.values[electricsName] = taxiState == state and 1 or 0
  end
end

local function setTaxiState(state)
  taxiState = state
end

local function getTaxiState()
  return taxiState
end

local function reset(jbeamData)
  taxiState = taxiStates.offDuty
end

local function init(jbeamData)
  taxiState = taxiStates.offDuty

  stateData = {}
  stateDataNameTaxiState = M.name .. "_state"

  local baseName = M.name
  stateElectrics = {}
  --build an electric for every possible state
  for _, state in pairs(taxiStates) do
    stateElectrics[state] = baseName .. "_" .. state
  end
end

local function getState()
  stateData[stateDataNameTaxiState] = taxiState
  return stateData
end

local function setState(data)
  if not data then
    return
  end

  local newTaxiState = data[stateDataNameTaxiState]
  if taxiStates[newTaxiState] and newTaxiState ~= taxiState then
    setTaxiState(newTaxiState)
  end
end

M.init = init
M.reset = reset

M.updateGFX = updateGFX

M.setTaxiState = setTaxiState
M.getTaxiState = getTaxiState

M.getState = getState
M.setState = setState

return M
