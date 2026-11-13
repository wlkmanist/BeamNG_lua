-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local toolPrefixStr = 'Mesh Spline' -- The global prefix for the mesh spline tool.

local largeSpacingThreshold = 5.0 -- Threshold above which to use local spline data instead of chord-based positioning.

local epsilon = 1e-6

-- Floor for the tiling period so a large negative overlap (Spacing) can't drive the period toward zero and spawn a
-- near-infinite number of pieces. The samplers already bail at period <= 0 (empty run), but a tiny POSITIVE period would
-- still explode the instance count, so we clamp to whichever is larger: an absolute floor, or a fraction of the piece.
local minPeriodFrac = 0.1
local minPeriodAbs = 0.1

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')
local populationEngine = require('editor/meshSpline/populationEngine')
local splineLock = require('editor/toolUtilities/splineLock')
local util = require('editor/toolUtilities/util')

-- Module constants.
local floor, max, random, randomseed = math.floor, math.max, math.random, math.randomseed
local scaleVec = vec3(1, 1, 1)
local zeroVec, globalUp = vec3(0, 0, 0), vec3(0, 0, 1)
local preRotQuats = geom.getPreRotQuats()

-- Module state.
local staticMeshes = {}
local lockApplied = {} -- spline id -> the lock state last applied to its meshes (see splineLock.sync).
local finalPosns, finalTans, finalNormals = {}, {}, {}
local pathsMap, counters = {}, {}
local meshPaths, meshPreRots, meshIsStart, meshIsEnd = {}, {}, {}, {}
local componentNames, componentProbabilities = {}, {}
local jitterQuat, rot, tmpRot1 = quat(), quat(), quat()
local tmpPos, tmpTan, tmpBinormal, tmpVec1 = vec3(), vec3(), vec3(), vec3()
local tmpDir, tmpAxisWorld = vec3(), vec3()
local axisXObj, axisYObj = vec3(1, 0, 0), vec3(0, 1, 0)


-- Oriented piece length along the run: object X normally, object Y when rotated 90/270 (odd rot). nil until measured.
local function pieceLength(spline)
  if (spline.rot % 2) == 1 then return spline.extentsW_Center end
  return spline.extentsL_Center
end

-- The period actually used to tile the run: piece length + Spacing, floored (see minPeriodFrac/minPeriodAbs) so a heavy
-- negative overlap can't collapse it. Single source of truth shared by the placement and the UI's even-fit label.
local function effectivePeriod(spline)
  local length = pieceLength(spline)
  if not length then return nil end
  return max(max(minPeriodAbs, length * minPeriodFrac), length + (spline.spacing or 0))
end

-- Slider floor for Spacing on this piece: the value that reaches the minimum allowed period (max overlap) for its length.
-- Below this the period would be clamped anyway, so we stop the slider here to keep it a live, honest control.
local function minSpacingFor(spline)
  local length = pieceLength(spline)
  if not length then return nil end
  return max(minPeriodAbs, length * minPeriodFrac) - length
end

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

-- Creates one generated mesh in the spline's folder, in the spline's current lock state.
local function createMesh(spline, shapePath, name, folder)
  local mesh = createObject('TSStatic')
  mesh:setField('shapeName', 0, shapePath)
  splineLock.applyObject(mesh, not spline.isEnabled, true) -- solid only once locked: a live preview would leave stale hulls behind it
  mesh:registerObject(Sim.getUniqueName(name))
  mesh.scale = scaleVec
  splineLock.tag(mesh, toolPrefixStr, spline)
  folder:addObject(mesh.obj)
  return mesh
end

-- Manages mesh pools for any component type.
local function manageComponentPool(spline, componentType, componentPath, componentId, splineName, meshesBySpline)
  meshesBySpline[componentId] = meshesBySpline[componentId] or {}
  local componentMeshes = meshesBySpline[componentId]
  local numNeeded, numInPool = pathsMap[componentId] or 0, #componentMeshes

  -- Add any extra meshes which may be needed.
  local folder = scenetree.findObjectById(spline.sceneTreeFolderId)
  for i = numInPool + 1, numNeeded do
    componentMeshes[i] = createMesh(spline, componentPath, string.format("MeshSpline_%s_%s_%d", spline.id, componentType, i), folder)
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
    folder.cansave = not spline.isEnabled -- Transient while editing; saves with the level while the spline is locked.
    scenetree.MissionGroup:addObject(folder)
    spline.sceneTreeFolderId = folder:getId()
    staticMeshes[spline.id] = staticMeshes[spline.id] or {}
    table.clear(staticMeshes[spline.id])
  end

  local splineName, splineId = spline.name, spline.id
  staticMeshes[splineId] = staticMeshes[splineId] or {}
  local meshesBySpline = staticMeshes[splineId]
  for _, list in pairs(meshesBySpline) do splineLock.dropDeleted(list) end -- meshes deleted by hand get recreated below.

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
  if spline.isStartCap and not (meshesBySpline[startCapId] and meshesBySpline[startCapId][1]) then
    meshesBySpline[startCapId] = { createMesh(spline, startCapPath, string.format("MeshSpline_%s_StartCap", spline.id), folder) }
  end

  -- Manage the single static mesh for the end cap.
  local endCapPath = spline.endCapMeshPath
  local endCapId = spline.endCapComponentPath
  if spline.isEndCap and not (meshesBySpline[endCapId] and meshesBySpline[endCapId][1]) then
    meshesBySpline[endCapId] = { createMesh(spline, endCapPath, string.format("MeshSpline_%s_EndCap", spline.id), folder) }
  end
end

-- Calls fn(mesh, true) for every mesh the tool holds for the spline (the splineLock `each`).
local function eachObject(spline, fn)
  for _, list in pairs(staticMeshes[spline.id] or {}) do
    for i = 1, #list do fn(list[i], true) end
  end
end

-- Brings the spline's existing meshes in line with its lock state. On unlock, any mesh whose shape was swapped by hand while
-- locked gets its own shape back and scales are reset; the placement pass then moves everything back.
local function syncLockState(spline)
  if spline.isEnabled and lockApplied[spline.id] then
    local shapeById = {
      [spline.mainComponentPath or ''] = spline.centerMeshPath,
      [spline.alias1ComponentPath or ''] = spline.alias1MeshPath,
      [spline.alias2ComponentPath or ''] = spline.alias2MeshPath,
      [spline.alias3ComponentPath or ''] = spline.alias3MeshPath,
      [spline.startCapComponentPath or ''] = spline.startCapMeshPath,
      [spline.endCapComponentPath or ''] = spline.endCapMeshPath,
    }
    for id, list in pairs(staticMeshes[spline.id] or {}) do
      for i = 1, #list do
        local mesh = list[i]
        if mesh and simObjectExists(mesh) then
          if shapeById[id] and mesh:getField('shapeName', 0) ~= shapeById[id] then
            mesh:setField('shapeName', 0, shapeById[id])
            mesh:postApply()
          end
          mesh.scale = scaleVec
        end
      end
    end
  end
  splineLock.sync(lockApplied, spline, toolPrefixStr, function(fn) eachObject(spline, fn) end)
end

-- A locked spline whose meshes exist only has its lock state applied: the tool does not move them. Returns true if so.
local function keepLocked(spline)
  if spline.isEnabled or not splineLock.hasAny(function(fn) eachObject(spline, fn) end) then return false end
  syncLockState(spline)
  return true
end

-- Populates a mesh spline with instances of a static mesh along its length.
local function populateMeshSpline(spline, splineIdx)
  if keepLocked(spline) then return end
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

  -- Discrete props (large spacing, e.g. lamp posts / bollards) sit ON each sample point; tiling meshes (small spacing,
  -- e.g. barriers / fences) abut end-to-end within each cell. Computed here (before sampling) because 'lock ends' even-fit
  -- sampling only applies to discrete props.
  local isDiscrete = spline.spacing > largeSpacingThreshold

  -- Sample points along the spline; outputs are reused tables. Period = mesh length + gap (centre-to-centre for discrete),
  -- floored by effectivePeriod so a heavy negative overlap can't spawn a near-infinite number of pieces.
  -- With 'lock ends' on a discrete run, use the even-fit sampler: an item is pinned to both ends and the interior is
  -- spaced as evenly as possible near that target period.
  populationEngine.sample(spline, effectivePeriod(spline), finalPosns, finalTans, finalNormals, isDiscrete and spline.isFixedEnds)

  -- Decide mesh distribution and collect counts.
  computeMeshMap(#finalPosns, spline)

  -- Ensure mesh pools exist and match demand.
  syncLockState(spline)
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
  local quat90Z = preRotQuats[1]

  -- Pivot-agnostic tiling anchor. negExt/posExt are the origin->face distances along the tiling axis (object X for
  -- rot 0/180, object Y for rot 90/270), read from the mesh's measured bounding box; their sum is the cell length.
  -- Seating each piece so its back cut-face lands on the cell's trailing sample makes any origin (end, centre, or
  -- anywhere between) tile seam-to-seam. Fall back to a centred pivot for splines that predate the box measurement.
  local rotIsOdd = (spline.rot % 2) == 1
  local tilingAxisObj = rotIsOdd and axisYObj or axisXObj
  local negExt, posExt
  if rotIsOdd then
    negExt, posExt = spline.boxYLeft_Center, spline.boxYRight_Center
  else
    negExt, posExt = spline.boxXLeft_Center, spline.boxXRight_Center
  end
  negExt = negExt or (length * 0.5)
  posExt = posExt or (length * 0.5)

  -- Place meshes.
  for i = 1, #meshPaths do
    local p1 = finalPosns[i]
    local p2 = finalPosns[i + 1] or (finalPosns[i] + (finalPosns[i] - (finalPosns[i - 1] or zeroVec)))

    -- Tangent: discrete props follow the local spline tangent; tiling meshes use the cell chord to align seam-to-seam.
    if isDiscrete then
      tmpTan:set(finalTans[i])
      tmpTan:normalize()
    else
      tmpTan:setSub2(p2, p1)
      tmpTan:normalize()
    end

    -- Frame.
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

    -- Base rotation (pre-jitter): prerot * quat90Z * frame. Assembled before positioning so the pivot offset can read
    -- which way the mesh's tiling axis actually points.
    tmpRot1:setMul2(meshPreRots[i], quat90Z)
    rot:setMul2(tmpRot1, rot)

    -- Position.
    if meshIsStart[i] or meshIsEnd[i] then
      tmpPos:setAdd2(p1, p2)          -- Cap: centre of its cell (per-cap extents aren't measured, so caps stay centred).
      tmpPos:setScaled2(tmpPos, 0.5)
      -- Cap longitudinal offset: caps aren't box-measured, so they can only be centred in their cell -- fine for meshes
      -- authored to the jersey convention, but a custom cap (e.g. snowbank ends) lands with a gap. Let the artist nudge
      -- the cap along the run to seam it. + moves it forward along the run direction (tmpTan).
      local capOff = meshIsStart[i] and (spline.startCapOffset or 0) or (spline.endCapOffset or 0)
      if capOff ~= 0 then
        tmpAxisWorld:setScaled2(tmpTan, capOff) -- tmpTan is already normalized here; tmpAxisWorld is free in the cap branch.
        tmpPos:setAdd2(tmpPos, tmpAxisWorld)
      end
    elseif isDiscrete then
      tmpPos:set(p1)                  -- Discrete prop: on the sample point (first instance at the spline start).
    else
      -- Tiling mesh: seat it so its back cut-face lands on p1 (the cell's trailing sample), whatever the authored
      -- origin. Rotate the object tiling axis into world to find which face points 'back' along the run, then push the
      -- origin forward off p1 by that face's distance. Origin-at-front collapses to p2, centre-origin to the midpoint.
      tmpAxisWorld:setRotate(rot, tilingAxisObj)
      local backExtent = (tmpAxisWorld:dot(tmpTan) >= 0) and negExt or posExt
      tmpDir:set(tmpTan)
      tmpDir:normalize()
      tmpPos:setScaled2(tmpDir, backExtent)
      tmpPos:setAdd2(p1, tmpPos)
    end
    tmpPos.z = tmpPos.z + verticalOffset

    -- Jitter.
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
  lockApplied[splineId] = nil
end

-- Lua reload: the tool lets go of a locked spline's meshes without deleting them (they are the level's) and returns their ids
-- per component, for adopt() to pick up again.
local function release(spline)
  local ids = {}
  for componentId, list in pairs(staticMeshes[spline.id] or {}) do
    local l = {}
    for i = 1, #list do
      if list[i] and simObjectExists(list[i]) then l[#l + 1] = list[i]:getId() end
    end
    ids[componentId] = l
  end
  staticMeshes[spline.id] = nil
  lockApplied[spline.id] = nil
  return ids
end

-- Takes back the meshes release() let go of (those still in the scene), as they are.
local function adopt(spline, ids)
  local meshesBySpline = {}
  for componentId, l in pairs(ids) do
    local list = {}
    for i = 1, #l do
      local mesh = scenetree.findObjectById(l[i])
      if mesh then list[#list + 1] = mesh end
    end
    meshesBySpline[componentId] = list
  end
  staticMeshes[spline.id] = meshesBySpline
  lockApplied[spline.id] = not spline.isEnabled
end

-- A spline is 'discrete' (props sitting on sample points, e.g. lamps) rather than 'tiling' (barriers abutting end-to-end)
-- when its gap exceeds the threshold. The UI uses this to show the discrete-only 'Lock ends' toggle.
local function isDiscreteSpline(spline)
  return spline and spline.spacing and spline.spacing > largeSpacingThreshold
end

-- For the 'Lock ends' UI label: given the current spline, returns the effective centre-to-centre spacing (m) and the
-- number of gaps that even-fit would produce, so the user sees the real spacing they'll get (e.g. "≈ 19.0 m"). Returns
-- nil when it can't be computed (too few points / no mesh length yet).
local function evenFitInfo(spline)
  if not spline or #spline.divPoints < 2 then return nil end
  local period = effectivePeriod(spline)
  if not (period and period > 0) then return nil end
  local L = util.getPolyLength(spline.divPoints)
  if not (L > 0) then return nil end
  local n = max(1, floor(L / period + 0.5))
  return L / n, n
end


-- Public interface.
M.isDiscreteSpline =                                    isDiscreteSpline
M.evenFitInfo =                                         evenFitInfo
M.minSpacingFor =                                       minSpacingFor
M.populateMeshSpline =                                  populateMeshSpline
M.tryRemove =                                           tryRemove
M.eachObject =                                          eachObject
M.release =                                             release
M.adopt =                                               adopt

return M