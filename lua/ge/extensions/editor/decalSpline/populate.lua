-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local toolPrefixStr = 'Decal Spline' -- The global prefix for the decal spline tool.

local decalLength = 4.0 -- The assumed length of a decal.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')
local util = require('editor/toolUtilities/util')

-- Module constants.
local min, max, random = math.min, math.max, math.random
local zeroVec = vec3(0, 0, 0)
local preRotQuats = geom.getPreRotQuats()

-- Module state.
local templateFolderId = nil -- The id of the folder for the shared templates.
local decalInstances = {} -- list of decal instances for each decal spline.
local templateIds = {} -- list of active decal template ids.
local instanceCounters = {} -- list of instance counters for each decal template.
local finalPosns, finalTans, finalNormals = {}, {}, {}
local components, cycle = {}, {}
local jitterQuat, rot = quat(), quat()
local tmpTan = vec3()


-- Sample a decal based on normalised probabilities.
local function sample(decals)
  local r = random()
  local cumulative = 0
  for _, decal in ipairs(decals) do
    cumulative = cumulative + decal.normalized
    if r <= cumulative then
      return decal
    end
  end
end

-- Generate a random pattern of selected decals.
local function generateRandomPattern(components, numDecals)
  -- Normalise the probabilities of the components.
  local total = 0
  for _, decal in ipairs(components) do
    total = total + decal.probability
  end
  local totalInv = 1.0 / total
  for _, decal in ipairs(components) do
    decal.normalized = decal.probability * totalInv
  end

  -- Sample the decals based on the normalised probabilities.
  local result = {}
  for _ = 1, numDecals do
    table.insert(result, sample(components).name)
  end
  return result
end

-- Computes a map from each position to the component which it should use.
local function computeComponentMap(numPositions, spline)
  -- Determine the pattern of decals to use (either round-robin or random).
  table.clear(components)
  table.clear(cycle)
  table.insert(components, { name = 'component1', probability = max(0.000001, spline.component1RandomWeight) })
  if spline.isComponent2 then table.insert(components, { name = 'component2', probability = max(0.000001, spline.component2RandomWeight) }) end
  if spline.isComponent3 then table.insert(components, { name = 'component3', probability = max(0.000001, spline.component3RandomWeight) }) end
  if spline.isComponent4 then table.insert(components, { name = 'component4', probability = max(0.000001, spline.component4RandomWeight) }) end
  if spline.isAliasRoundRobin then
    local numComponents = #components
    for i = 1, numPositions do
      local decalIndex = ((i - 1) % numComponents) + 1  -- Cycle through the decals evenly in the round-robin pattern.
      table.insert(cycle, components[decalIndex].name)
    end
  else
    cycle = generateRandomPattern(components, numPositions) -- Generate a random pattern of selected decals, based on the user's weightings.
  end

  -- Create a map from each decal unit to the decal properties which it should use.
  local map = {}
  for i = 1, numPositions do
    local decalName = cycle[i]
    local path, preRot, numRows, numCols, scale, frame = nil, nil, nil, nil, nil, nil

    if decalName == 'component1' then
      path = spline.component1Material
      preRot = preRotQuats[spline.rot1]
      numRows = spline.numRows1
      numCols = spline.numCols1
      scale = spline.scale1
      frame = spline.frame1
    elseif decalName == 'component2' then
      path = spline.component2Material
      preRot = preRotQuats[spline.rot2]
      numRows = spline.numRows2
      numCols = spline.numCols2
      scale = spline.scale2
      frame = spline.frame2
    elseif decalName == 'component3' then
      path = spline.component3Material
      preRot = preRotQuats[spline.rot3]
      numRows = spline.numRows3
      numCols = spline.numCols3
      scale = spline.scale3
      frame = spline.frame3
    elseif decalName == 'component4' then
      path = spline.component4Material
      preRot = preRotQuats[spline.rot4]
      numRows = spline.numRows4
      numCols = spline.numCols4
      scale = spline.scale4
      frame = spline.frame4
    end

    map[i] = { path = path, preRot = preRot, numRows = numRows, numCols = numCols, scale = scale, frame = frame }
  end
  return map
end

-- Attempts to removes the decals of the decal spline, from the scene.
local function tryRemove(spline)
  -- First, remove all the relevant decal instances.
  local splineId = spline.id
  local decalsBySpline = decalInstances[splineId]
  if decalsBySpline then
    for material, v in pairs(decalsBySpline) do
      local numDecalsByShape = #v
      for i = 1, numDecalsByShape do
        local decal = v[i]
        if decal then
          editor.deleteDecalInstance(decal)
          instanceCounters[material] = instanceCounters[material] - 1
        end
      end
    end
    decalInstances[splineId] = nil
  end

  -- Now check if any templates are no longer needed, and remove them.
  for material, numInstances in pairs(instanceCounters) do
    if numInstances < 1 then
      local template = scenetree.findObjectById(templateIds[material])
      if template then
        template:delete()
        templateIds[material] = nil
      end
    end
  end
end

-- Removes the folder for the shared templates.
local function removeFolder()
  if templateFolderId then
    local folder = scenetree.findObjectById(templateFolderId)
    if folder then
      folder:delete()
    end
  end
end

-- Populates a decal spline with instances of decals along its length.
local function populateDecalSpline(spline, splines)
  if #spline.divPoints < 2 then
    return -- Not enough positions to populate the decal spline.
  end

  -- Ensure we have a folder for the shared templates.
  if not templateFolderId or not scenetree.findObjectById(templateFolderId) then
    local uniqueName = util.generateUniqueName("DecalSpline - Templates", toolPrefixStr)
    local folderNameId = Engine.generateUUID()
    local newFolder = createObject("SimGroup")
    newFolder:registerObject(string.format("%s - %s", uniqueName, folderNameId))
    scenetree.MissionGroup:addObject(newFolder)
    templateFolderId = newFolder:getId()
    for i = 1, #splines do
      tryRemove(splines[i]) -- Remove the decals of all decal splines.
    end
    table.clear(decalInstances) -- Reset the template/instance tables.
    table.clear(instanceCounters)
    table.clear(templateIds)
  end

  -- Sample along spline's arc-length using the div points.
  geom.sampleSpline(spline.divPoints, spline.tangents, spline.normals, decalLength + spline.spacing, finalPosns, finalTans, finalNormals)

  -- Compute a map from each position to its assigned properties (for round-robin or random distributions).
  local componentMap = computeComponentMap(#finalPosns, spline)

  -- Create the decal templates/instances for each component on the decal spline, in order.
  local splineId = spline.id
  local decalsBySpline = decalInstances[splineId]
  decalsBySpline = decalsBySpline or {}

  -- Populate the decal spline.
  local jitter, rot_q90 = spline.jitter, preRotQuats[1]
  for i = 1, #componentMap do
    -- The points of the line segment, on which this decal instance will be placed.
    local p1 = finalPosns[i]
    local p2 = finalPosns[i + 1] or (finalPosns[i] + (finalPosns[i] - (finalPosns[i - 1] or zeroVec)))

    -- Compute the Frenet frame which will be used to orient the decal.
    tmpTan:set(p2.x - p1.x, p2.y - p1.y, p2.z - p1.z)
    tmpTan:normalize()
    local normal = finalNormals[i]

    -- Compute jittered rotation (Z-only jitter).
    geom.computeRandomJitterQuat_ZOnly(jitter, normal, jitterQuat)

    -- Compute the full rotation.
    local mapData = componentMap[i]
    rot:setFromDir(tmpTan, normal)
    rot = mapData.preRot * rot_q90 * rot
    rot = jitterQuat * rot
    local finalTgt, finalUp = rot:toDirUp()

    -- Create the template if needed (either not created yet, or not found in the scene tree, or not found in the id list).
    local componentPath = mapData.path
    if not templateIds[componentPath] then
      local template = createObject("DecalData")
      template:setField("texRows", 0, mapData.numRows)
      template:setField("texCols", 0, mapData.numCols)
      template:setField("material", 0, componentPath)
      local name = Sim.getUniqueName(componentPath) -- Get a unique name for the decal data object.
      template:registerObject(name)
      templateIds[componentPath] = template:getId()
      if templateFolderId then
        local folder = scenetree.findObjectById(templateFolderId)
        if folder then
          folder:addObject(template)
        end
      end
      -- Register the template with the persistence manager so it gets saved
      scenetree.decalPersistMan:setDirty(template, editor.getDecalDataFilePath())
    end

    -- Create the decal instance and store it in the decal instances table.
    local template = scenetree.findObjectById(templateIds[componentPath])
    if template then
      local decal = editor.addDecalInstanceWithTan(p2, finalUp, finalTgt, template, mapData.scale, mapData.frame, 3, 1)
      decalInstances[splineId] = decalInstances[splineId] or {} -- Ensure we have a table for this spline.
      decalInstances[splineId][componentPath] = decalInstances[splineId][componentPath] or {} -- Ensure we have a table (in the spline table) for this material.
      table.insert(decalInstances[splineId][componentPath], decal)
      instanceCounters[componentPath] = instanceCounters[componentPath] or 0 -- Create/Reset the instance counter for the material, if it doesn't exist.
      instanceCounters[componentPath] = instanceCounters[componentPath] + 1 -- Increment the instance counter for the material.
    end
  end
end

-- On a change of num rows/num cols, we need to update the same properties in the other components.
local function propagateRowsCols(spline, componentIdx)
  if componentIdx == 1 then
    if spline.component1Material == spline.component2Material then
      spline.numRows2, spline.numCols2 = spline.numRows1, spline.numCols1
      spline.frame2 = max(0, min(spline.frame2, spline.numRows2 * spline.numCols2 - 1))
    end
    if spline.component1Material == spline.component3Material then
      spline.numRows3, spline.numCols3 = spline.numRows1, spline.numCols1
      spline.frame3 = max(0, min(spline.frame3, spline.numRows3 * spline.numCols3 - 1))
    end
    if spline.component1Material == spline.component4Material then
      spline.numRows4, spline.numCols4 = spline.numRows1, spline.numCols1
      spline.frame4 = max(0, min(spline.frame4, spline.numRows4 * spline.numCols4 - 1))
    end
  elseif componentIdx == 2 then
    if spline.component2Material == spline.component1Material then
      spline.numRows1, spline.numCols1 = spline.numRows2, spline.numCols2
      spline.frame1 = max(0, min(spline.frame1, spline.numRows1 * spline.numCols1 - 1))
    end
    if spline.component2Material == spline.component3Material then
      spline.numRows3, spline.numCols3 = spline.numRows2, spline.numCols2
      spline.frame3 = max(0, min(spline.frame3, spline.numRows3 * spline.numCols3 - 1))
    end
    if spline.component2Material == spline.component4Material then
      spline.numRows4, spline.numCols4 = spline.numRows2, spline.numCols2
      spline.frame4 = max(0, min(spline.frame4, spline.numRows4 * spline.numCols4 - 1))
    end
  elseif componentIdx == 3 then
    if spline.component3Material == spline.component1Material then
      spline.numRows1, spline.numCols1 = spline.numRows3, spline.numCols3
      spline.frame1 = max(0, min(spline.frame1, spline.numRows1 * spline.numCols1 - 1))
    end
    if spline.component3Material == spline.component2Material then
      spline.numRows2, spline.numCols2 = spline.numRows3, spline.numCols3
      spline.frame2 = max(0, min(spline.frame2, spline.numRows2 * spline.numCols2 - 1))
    end
    if spline.component3Material == spline.component4Material then
      spline.numRows4, spline.numCols4 = spline.numRows3, spline.numCols3
      spline.frame4 = max(0, min(spline.frame4, spline.numRows4 * spline.numCols4 - 1))
    end
  elseif componentIdx == 4 then
    if spline.component4Material == spline.component1Material then
      spline.numRows1, spline.numCols1 = spline.numRows4, spline.numCols4
      spline.frame1 = max(0, min(spline.frame1, spline.numRows1 * spline.numCols1 - 1))
    end
    if spline.component4Material == spline.component2Material then
      spline.numRows2, spline.numCols2 = spline.numRows4, spline.numCols4
      spline.frame2 = max(0, min(spline.frame2, spline.numRows2 * spline.numCols2 - 1))
    end
    if spline.component4Material == spline.component3Material then
      spline.numRows3, spline.numCols3 = spline.numRows4, spline.numCols4
      spline.frame3 = max(0, min(spline.frame3, spline.numRows3 * spline.numCols3 - 1))
    end
  end
end


-- Public interface.
M.populateDecalSpline =                                 populateDecalSpline

M.tryRemove =                                           tryRemove

M.removeFolder =                                        removeFolder
M.propagateRowsCols =                                   propagateRowsCols

return M