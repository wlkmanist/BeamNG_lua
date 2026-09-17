-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file,
-- You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- Module dependencies.
local mol = require('editor/assemblySpline/molecule')

-- Module constants.
local random = math.random
local emptyTable = {}

-- Module state.
local rigidMaps, bridgeMaps = {}, {}
local componentMeshData, componentProbabilities = {}, {}
local resultArrays = {} -- Pre-allocated arrays keyed by component id.


-- Sample a component based on normalised probabilities.
local function sampleComponent(componentCount)
  local r = random()
  local cumulative = 0
  for i = 1, componentCount do
    cumulative = cumulative + componentProbabilities[i]
    if r <= cumulative then
      return i
    end
  end
  return 1 -- Fallback to first component.
end

-- Generate a random distribution of selected components.
local function generateRandomPattern(componentGroup, numPlacements, spline, isBridge)
  local componentCount = 0
  local componentGroupMesh = componentGroup.mesh
  local isEnabled = isBridge and mol.getBridgeEnabled(spline, componentGroupMesh.id) or mol.getRigidEnabled(spline, componentGroupMesh.id)
  if isEnabled then -- Include the base component, if enabled.
    componentCount = componentCount + 1
    componentMeshData[componentCount] = componentGroupMesh
    componentProbabilities[componentCount] = componentGroup.randomWeight
  end
  for _, variation in ipairs(componentGroup.variations) do
    local varEnabled = isBridge and mol.getBridgeEnabled(spline, variation.id) or mol.getRigidEnabled(spline, variation.id)
    if varEnabled then -- Include this variation, if enabled.
      componentCount = componentCount + 1
      componentMeshData[componentCount] = variation
      componentProbabilities[componentCount] = variation.randomWeight
    end
  end

  if componentCount == 0 then
    return {} -- Early return if no components available.
  end

  -- Normalise probabilities.
  local total = 0
  for i = 1, componentCount do
    total = total + componentProbabilities[i]
  end
  local totalInv = 1.0 / total
  for i = 1, componentCount do
    componentProbabilities[i] = componentProbabilities[i] * totalInv
  end

  -- Generate random distribution.
  local componentId = componentGroup.mesh.id
  local resultArray = resultArrays[componentId] or {}
  resultArrays[componentId] = resultArray
  table.clear(resultArray)
  for i = 1, numPlacements do
    local componentIndex = sampleComponent(componentCount)
    resultArray[i] = componentMeshData[componentIndex].meshPath
  end
  return resultArray
end

-- Generate a round robin distribution of selected components.
local function generateRoundRobinPattern(componentGroup, numPlacements, spline, isBridge)
  -- Build component list from base + enabled variations using parallel arrays.
  local componentCount = 0
  local componentGroupMesh = componentGroup.mesh
  local isEnabled = isBridge and mol.getBridgeEnabled(spline, componentGroupMesh.id) or mol.getRigidEnabled(spline, componentGroupMesh.id)
  if isEnabled then
    componentCount = componentCount + 1
    componentMeshData[componentCount] = componentGroupMesh
  end
  for _, variation in ipairs(componentGroup.variations) do
    local varEnabled = isBridge and mol.getBridgeEnabled(spline, variation.id) or mol.getRigidEnabled(spline, variation.id)
    if varEnabled then
      componentCount = componentCount + 1
      componentMeshData[componentCount] = variation
    end
  end

  -- Early return if no components available.
  if componentCount == 0 then
    return {}
  end

  -- Generate round robin distribution.
  local componentId = componentGroup.mesh.id
  local resultArray = resultArrays[componentId] or {}
  resultArrays[componentId] = resultArray
  table.clear(resultArray)
  for i = 1, numPlacements do
    local componentIndex = ((i - 1) % componentCount) + 1
    resultArray[i] = componentMeshData[componentIndex].meshPath
  end
  return resultArray
end

-- Compute component maps for all rigid and bridge components.
local function computeMeshMap(molecule, numPlacements, spline)
  -- Clear existing result arrays for each component
  for _, rigid in ipairs(molecule.rigids) do
    if resultArrays[rigid.mesh.id] then
      table.clear(resultArrays[rigid.mesh.id])
    end
  end
  for _, bridge in ipairs(molecule.bridges) do
    if resultArrays[bridge.mesh.id] then
      table.clear(resultArrays[bridge.mesh.id])
    end
  end

  -- Compute maps for rigid components.
  table.clear(rigidMaps)
  for i, rigid in ipairs(molecule.rigids) do
    -- Check if any component in this group (base + variations) is enabled.
    local hasEnabledComponent = mol.getRigidEnabled(spline, rigid.mesh.id)
    for _, variation in ipairs(rigid.variations) do
      if mol.getRigidEnabled(spline, variation.id) then
        hasEnabledComponent = true
        break
      end
    end

    if hasEnabledComponent then
      if rigid.isRandom then
        rigidMaps[i] = generateRandomPattern(rigid, numPlacements, spline, false)
      else
        rigidMaps[i] = generateRoundRobinPattern(rigid, numPlacements, spline, false)
      end
    else
      rigidMaps[i] = emptyTable -- No components enabled, return empty array.
    end
  end

  -- Compute maps for bridge components.
  table.clear(bridgeMaps)
  for i, bridge in ipairs(molecule.bridges) do
    -- Check if any component in this group (base + variations) is enabled.
    local hasEnabledComponent = mol.getBridgeEnabled(spline, bridge.mesh.id)
    for _, variation in ipairs(bridge.variations) do
      if mol.getBridgeEnabled(spline, variation.id) then
        hasEnabledComponent = true
        break
      end
    end

    if hasEnabledComponent then
      if bridge.isRandom then
        bridgeMaps[i] = generateRandomPattern(bridge, numPlacements - 1, spline, true)
      else
        bridgeMaps[i] = generateRoundRobinPattern(bridge, numPlacements - 1, spline, true)
      end
    else
      bridgeMaps[i] = emptyTable -- No components enabled, return empty array.
    end
  end

  return rigidMaps, bridgeMaps
end


-- Public interface.
M.computeMeshMap =                                      computeMeshMap

return M