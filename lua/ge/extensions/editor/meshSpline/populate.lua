-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local toolPrefixStr = 'Mesh Spline' -- The global prefix for the mesh spline tool.

local largeSpacingThreshold = 5.0 -- Threshold above which to use local spline data instead of chord-based positioning.

local epsilon = 1e-6

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')
local util = require('editor/toolUtilities/util')

-- Module constants.
local max, random, randomseed = math.max, math.random, math.randomseed
local scaleVec = vec3(1, 1, 1)
local zeroVec, globalUp = vec3(0, 0, 0), vec3(0, 0, 1)
local preRotQuats = geom.getPreRotQuats()

-- Module state.
local staticMeshes = {}
local finalPosns, finalTans, finalNormals = {}, {}, {}
local pathsMap, counters = {}, {}
local meshPaths, meshPreRots, meshIsStart, meshIsEnd = {}, {}, {}, {}
local componentNames, componentProbabilities = {}, {}
local jitterQuat, rot, tmpRot1 = quat(), quat(), quat()
local tmpPos, tmpTan, tmpBinormal, tmpVec1 = vec3(), vec3(), vec3(), vec3()


-- Computes a map from each mesh unit to the mesh properties which it should use.
local function computeMeshMap(numMeshes, spline)
  -- Build the active component list and weights (dense, 1..N).
  table.clear(componentNames)
  table.clear(componentProbabilities)
  local n = 1
  componentNames[n] = 1
  componentProbabilities[n] = max(epsilon, spline.mainRandomWeight)
  if spline.isAlias1 then
    n = n + 1
    componentNames[n] = 2
    componentProbabilities[n] = max(epsilon, spline.alias1RandomWeight)
  end
  if spline.isAlias2 then
    n = n + 1
    componentNames[n] = 3
    componentProbabilities[n] = max(epsilon, spline.alias2RandomWeight)
  end
  if spline.isAlias3 then
    n = n + 1
    componentNames[n] = 4
    componentProbabilities[n] = max(epsilon, spline.alias3RandomWeight)
  end

  -- Hoist component paths and pre-rot indices into compact arrays (no per-iter table lookups).
  local compPath1, compRot1 = spline.mainComponentPath, spline.rot
  local compPath2, compRot2 = spline.alias1ComponentPath, spline.alias1Rot
  local compPath3, compRot3 = spline.alias2ComponentPath, spline.alias2Rot
  local compPath4, compRot4 = spline.alias3ComponentPath, spline.alias3Rot

  -- Precompute cumulative probabilities once (only if random mode).
  local useRoundRobin = spline.isAliasRoundRobin
  local total = 0.0
  for i = 1, n do
    total = total + componentProbabilities[i]
  end
  local totalInv = (not useRoundRobin and total > 0.0) and (1.0 / total) or 1.0

  -- Reset outputs.
  table.clear(meshPaths); table.clear(meshPreRots); table.clear(pathsMap)
  table.clear(meshIsStart); table.clear(meshIsEnd)

  -- Cache start/end cap info.
  local hasStartCap, hasEndCap = spline.isStartCap, spline.isEndCap
  local startCapPath, startCapPre = spline.startCapComponentPath, preRotQuats[spline.startCapRot]
  local endCapPath, endCapPre = spline.endCapComponentPath,   preRotQuats[spline.endCapRot]

  -- Populate mesh assignments.
  for i = 1, numMeshes do
    local path, preRot

    -- Start/End caps override component selection.
    if (i == 1 and hasStartCap) then
      path, preRot = startCapPath, startCapPre
      meshIsStart[i], meshIsEnd[i] = true, false
    elseif (i == numMeshes and hasEndCap) then
      path, preRot = endCapPath, endCapPre
      meshIsStart[i], meshIsEnd[i] = false, true
    else
      meshIsStart[i], meshIsEnd[i] = false, false

      local ctype
      if useRoundRobin then -- Even round-robin over the active components.
        local idx = ((i - 1) % n) + 1
        ctype = componentNames[idx]
      else -- Random draw using cumulative probabilities.
        local r, cumulative = random(), 0.0
        for j = 1, n do
          cumulative = cumulative + (componentProbabilities[j] * totalInv)
          if r <= cumulative then
            ctype = componentNames[j]
            break
          end
        end
        ctype = ctype or componentNames[n] -- guard against r == 1.0 edge.
      end

      -- Map component type to path + prerot.
      if ctype == 1 then
        path, preRot = compPath1, preRotQuats[compRot1]
      elseif ctype == 2 then
        path, preRot = compPath2, preRotQuats[compRot2]
      elseif ctype == 3 then
        path, preRot = compPath3, preRotQuats[compRot3]
      else
        path, preRot = compPath4, preRotQuats[compRot4]
      end
    end

    pathsMap[path] = (pathsMap[path] or 0) + 1
    meshPaths[i] = path
    meshPreRots[i] = preRot
  end

  return meshPaths, meshPreRots, meshIsStart, meshIsEnd, pathsMap
end

-- Manages mesh pools for any component type.
local function manageComponentPool(spline, componentType, componentPath, componentId, splineName, meshesBySpline)
  meshesBySpline[componentId] = meshesBySpline[componentId] or {}
  local componentMeshes = meshesBySpline[componentId]
  local numNeeded, numInPool = pathsMap[componentId] or 0, #componentMeshes

  -- Add any extra meshes which may be needed.
  for i = numInPool + 1, numNeeded do
    local meshId = string.format("MeshSpline_%s_%s_%d", spline.id, componentType, i)
    local mesh = createObject('TSStatic')
    mesh.cansave = true
    mesh:setField('shapeName', 0, componentPath)
    mesh:registerObject(meshId)
    mesh.scale = scaleVec
    local folder = scenetree.findObjectById(spline.sceneTreeFolderId)
    folder:addObject(mesh.obj)
    componentMeshes[i] = mesh
  end

  -- Remove any excess meshes which we no longer need.
  for i = numInPool, numNeeded + 1, -1 do
    local mesh = componentMeshes[i]
    if mesh and simObjectExists(mesh) then
      mesh:delete()
    end
    componentMeshes[i] = nil
  end
end

-- Ensure that we have the exact number of static meshes for each component type.
local function manageMeshPools(spline, splineIdx)
  -- Ensure the mesh spline has a scene tree folder.
  -- [If it doesn't exist (maybe user deleted it), then create a new one.]
  local folder = scenetree.findObjectById(spline.sceneTreeFolderId)
  if not folder then
    local baseName = string.format(toolPrefixStr .. " %d", splineIdx)
    local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)
    folder = createObject("SimGroup")
    folder:registerObject(string.format("%s - %s", uniqueName, spline.id))
    folder.cansave = true
    scenetree.MissionGroup:addObject(folder)
    spline.sceneTreeFolderId = folder:getId()
    staticMeshes[spline.id] = staticMeshes[spline.id] or {}
    table.clear(staticMeshes[spline.id])
  end

  local splineName, splineId = spline.name, spline.id
  staticMeshes[splineId] = staticMeshes[splineId] or {}
  local meshesBySpline = staticMeshes[splineId]

  -- Manage the pool of static meshes for the main components.
  manageComponentPool(spline, "Main", spline.centerMeshPath, spline.mainComponentPath, splineName, meshesBySpline)
  if spline.isAlias1 then
    manageComponentPool(spline, "Alias1", spline.alias1MeshPath, spline.alias1ComponentPath, splineName, meshesBySpline)
  end
  if spline.isAlias2 then
    manageComponentPool(spline, "Alias2", spline.alias2MeshPath, spline.alias2ComponentPath, splineName, meshesBySpline)
  end
  if spline.isAlias3 then
    manageComponentPool(spline, "Alias3", spline.alias3MeshPath, spline.alias3ComponentPath, splineName, meshesBySpline)
  end

  -- Manage the single static mesh for the start cap.
  local startCapPath = spline.startCapMeshPath
  local startCapId = spline.startCapComponentPath
  if spline.isStartCap and not meshesBySpline[startCapId] then
    local meshId = string.format("MeshSpline_%s_StartCap", spline.id)
    local mesh = createObject('TSStatic')
    mesh.cansave = true
    mesh:setField('shapeName', 0, startCapPath)
    mesh:registerObject(meshId)
    mesh.scale = scaleVec
    folder:addObject(mesh.obj) -- Add the mesh to the spline's scene tree folder.
    meshesBySpline[startCapId] = { mesh }
  end

  -- Manage the single static mesh for the end cap.
  local endCapPath = spline.endCapMeshPath
  local endCapId = spline.endCapComponentPath
  if spline.isEndCap and not meshesBySpline[endCapId] then
    local meshId = string.format("MeshSpline_%s_EndCap", spline.id)
    local mesh = createObject('TSStatic')
    mesh.cansave = true
    mesh:setField('shapeName', 0, endCapPath)
    mesh:registerObject(meshId)
    mesh.scale = scaleVec
    folder:addObject(mesh.obj) -- Add the mesh to the spline's scene tree folder.
    meshesBySpline[endCapId] = { mesh }
  end
end

-- Populates a mesh spline with instances of a static mesh along its length.
local function populateMeshSpline(spline, splineIdx)
  local length = spline.extentsL_Center
  local meshPathCenter = spline.centerMeshPath
  if not length or not meshPathCenter or #spline.divPoints < 2 then
    return
  end

  -- Seed jitter/placement RNG deterministically per spline.
  randomseed(spline.splineRandomSeed)

  -- If rotated 90/270°, use width for oriented length.
  if (spline.rot % 2) == 1 then
    length = spline.extentsW_Center
  end

  -- Sample equidistant points along the spline; outputs are reused tables.
  geom.sampleSpline(spline.divPoints, spline.tangents, spline.normals, length + spline.spacing, finalPosns, finalTans, finalNormals)

  -- Decide mesh distribution and collect counts.
  computeMeshMap(#finalPosns, spline)

  -- Ensure mesh pools exist and match demand.
  manageMeshPools(spline, splineIdx)

  -- Init per-component counters.
  table.clear(counters)
  for k in next, pathsMap do
    counters[k] = 1
  end

  -- Hoist invariants used in the loop.
  local meshesBySpline = staticMeshes[spline.id]
  local normalMode = spline.normalMode
  local verticalOffset = spline.verticalOffset
  local isCenteredLeft = spline.isCenteredLeft
  local useLocalSplineData = (spline.spacing > largeSpacingThreshold) and (not isCenteredLeft)
  local quat90Z = preRotQuats[1]

  -- Place meshes.
  for i = 1, #meshPaths do
    local p1 = finalPosns[i]
    local p2 = finalPosns[i + 1] or (finalPosns[i] + (finalPosns[i] - (finalPosns[i - 1] or zeroVec)))

    -- Tangent: chord vs local (branchless on spacing/centering).
    if useLocalSplineData then
      tmpTan:set(finalTans[i])
      tmpTan:normalize()
    else
      tmpTan:setSub2(p2, p1)
      tmpTan:normalize()
    end

    -- Frame + base rotation.
    local normal
    if normalMode == 0 then
      normal = finalNormals[i]
      rot:setFromDir(tmpTan, normal)
    elseif normalMode == 1 then
      normal = globalUp
      tmpTan.z = 0
      rot:setFromDir(tmpTan, globalUp)
    else
      geom.getTerrainNormalInPlace(p1, tmpVec1)
      normal = tmpVec1
      rot:setFromDir(tmpTan, normal)
    end
    tmpBinormal:setCross(tmpTan, normal)

    -- Position.
    if meshIsStart[i] or meshIsEnd[i] then
      tmpPos:setAdd2(p1, p2)
      tmpPos:setScaled2(tmpPos, 0.5)
    else
      if isCenteredLeft then
        tmpPos:set(p2)
      else
        if useLocalSplineData then
          tmpPos:set(p1)
        else
          tmpPos:setAdd2(p1, p2)
          tmpPos:setScaled2(tmpPos, 0.5)
        end
      end
    end
    tmpPos.z = tmpPos.z + verticalOffset

    -- Rotation: prerot, base, jitter.
    tmpRot1:setMul2(meshPreRots[i], quat90Z)
    rot:setMul2(tmpRot1, rot)
    geom.computeRandomJitterQuat(spline, tmpTan, tmpBinormal, normal, jitterQuat)
    rot:setMul2(rot, jitterQuat)

    -- Place mesh.
    local componentPath = meshPaths[i]
    local idx = counters[componentPath]; counters[componentPath] = idx + 1
    meshesBySpline[componentPath][idx]:setPosRot(tmpPos.x, tmpPos.y, tmpPos.z, rot.x, rot.y, rot.z, rot.w)
  end
end

-- Attempts to removes the static meshes of the mesh spline, from the scene.
local function tryRemove(spline)
  local splineId = spline.id
  local meshesBySpline = staticMeshes[splineId]
  if meshesBySpline then
    for _, v in pairs(meshesBySpline) do
      local numMeshesByShape = #v
      for i = 1, numMeshesByShape do
        local mesh = v[i]
        if mesh and simObjectExists(mesh) then
          mesh:delete()
        end
      end
    end
    staticMeshes[splineId] = nil
  end
end


-- Public interface.
M.populateMeshSpline =                                  populateMeshSpline
M.tryRemove =                                           tryRemove

return M