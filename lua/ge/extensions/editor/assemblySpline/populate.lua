-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file,
-- You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local toolPrefixStr = 'Assembly Spline'

local minSpacingBetweenMolecules = 3.0

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local distrib = require('editor/assemblySpline/distribution')
local geom = require('editor/toolUtilities/geom')
local util = require('editor/toolUtilities/util')

-- Module constants.
local max, atan2, random, randomseed = math.max, math.atan2, math.random, math.randomseed
local twoPi = 2.0 * math.pi
local bridgeXAxis, up = vec3(1, 0, 0), vec3(0, 0, 1)
local defaultScale = vec3(1, 1, 1)
local preRotQuats = geom.getPreRotQuats()

-- Module state.
local staticMeshes = {}
local meshPools = {}
local finalPosns, finalTans, finalNormals = {}, {}, {}
local translationArray, rotationArray = {}, {}
local neededMeshes, existingMeshesByPath, counters = {}, {}, {}
local maxMolecules, maxRigidMeshes = 0, 0
local jitterQuat, finalRot, rootRot = quat(), quat(), quat()
local forwardRot, upRot, aligningRot = quat(), quat(), quat()
local directionRot, rollRot = quat(), quat()
local freedomJitterQuat, axisJitterQuat = quat(), quat()
local finalPos, tmpScale, bridgeInternalDir = vec3(), vec3(), vec3()
local posWS, vertOffsetVec, placedPosWS = vec3(), vec3(), vec3()
local sourcePosWS, placedForwardVec, placedUpVec = vec3(), vec3(), vec3()
local sourceForwardVec, sourceUpVec, freedomAxisWorld = vec3(), vec3(), vec3()
local sourceNailAxisWorld, targetNailAxisWorld = vec3(), vec3()
local bridgeSourceNailAxisWorld, bridgeTargetNailAxisWorld = vec3(), vec3()
local bridgeSourcePosWorld, targetAttachPosWS = vec3(), vec3()
local sourceNailProj, bridgeSourceNailProj = vec3(), vec3()
local targetNailProj, bridgeTargetNailProj = vec3(), vec3()
local tmpVec1, tmpVec2, tmpVec3, tmpVec4 = vec3(), vec3(), vec3(), vec3()


-- Manages mesh pools based on the distribution maps.
local function manageMeshPools(spline, rigidMaps, bridgeMaps)
  local splineId = spline.id
  local folder = scenetree.findObjectById(spline.sceneTreeFolderId)

  -- Count needed meshes per unique mesh path.
  table.clear(neededMeshes)
  for _, rigidMap in ipairs(rigidMaps) do
    for _, meshPath in ipairs(rigidMap) do
      if meshPath then -- Only count non-nil entries.
        neededMeshes[meshPath] = (neededMeshes[meshPath] or 0) + 1
      end
    end
  end
  for _, bridgeMap in ipairs(bridgeMaps) do
    for _, meshPath in ipairs(bridgeMap) do
      if meshPath then -- Only count non-nil entries.
        neededMeshes[meshPath] = (neededMeshes[meshPath] or 0) + 1
      end
    end
  end

  -- Organise existing meshes by their current mesh path.
  local meshesBySpline = staticMeshes[splineId] or {}
  for i = 1, #meshesBySpline do
    local obj = scenetree.findObjectById(meshesBySpline[i])
    if obj then
      local currentPath = obj:getField('shapeName', 0)
      existingMeshesByPath[currentPath] = existingMeshesByPath[currentPath] or {}
      table.insert(existingMeshesByPath[currentPath], obj)
    end
  end

  -- Process each needed mesh path - add/remove only what's needed.
  meshPools[splineId] = meshPools[splineId] or {}
  for meshPath, neededCount in pairs(neededMeshes) do
    meshPools[splineId][meshPath] = meshPools[splineId][meshPath] or {}
    local pathPool = meshPools[splineId][meshPath]
    local existingCount = #pathPool

    -- Add any extra meshes that are needed.
    for i = existingCount + 1, neededCount do
      local obj = createObject('TSStatic')
      obj:setField('shapeName', 0, meshPath)
      local id = Engine.generateUUID()
      obj:registerObject(string.format('Mesh_%s', id))
      folder:addObject(obj.obj)
      pathPool[i] = obj
    end

    -- Remove any excess meshes that we no longer need.
    for i = existingCount, neededCount + 1, -1 do
      local mesh = pathPool[i]
      if mesh and simObjectExists(mesh) then
        mesh:delete()
      end
      pathPool[i] = nil
    end
  end

  -- Delete meshes for paths that are no longer needed.
  for meshPath, pathPool in pairs(meshPools[splineId]) do
    if not neededMeshes[meshPath] then
      for i = #pathPool, 1, -1 do
        local mesh = pathPool[i]
        if mesh and simObjectExists(mesh) then
          mesh:delete()
        end
        pathPool[i] = nil
      end
    end
  end

  -- Clear the existing meshes by path table for reuse.
  for path, meshList in pairs(existingMeshesByPath) do
    table.clear(meshList)
    existingMeshesByPath[path] = nil
  end
end

-- Gets the folder for the given spline, and creates it if it doesn't exist.
local function ensureFolderExists(spline, splineIdx)
  local folder = scenetree.findObjectById(spline.sceneTreeFolderId)
  if not folder then
    local uniqueName = util.generateUniqueName(toolPrefixStr .. " " .. splineIdx, toolPrefixStr)
    folder = createObject("SimGroup")
    folder:registerObject(uniqueName .. " - " .. spline.id)
    scenetree.MissionGroup:addObject(folder)
    spline.sceneTreeFolderId = folder:getId()
    staticMeshes[spline.id] = nil
  end
end

-- Gets the next available mesh from the pool for the given path.
local function getNextMeshFromPool(path, splineId)
  local pathPool = meshPools[splineId] and meshPools[splineId][path] or {}
  local counter = counters[path] or 1
  if counter <= #pathPool then
    counters[path] = counter + 1
    return pathPool[counter]
  end
  return nil
end

-- Populate the given assembly spline with molecules spanned by bridges.
local function populateAssemblySpline(spline, splineIdx, molecule)
  if #spline.divPoints < 2 or not molecule or not molecule.rigids then
    return -- Early return for invalid spline or molecule.
  end

  -- Ensure that we have a folder for this assembly spline, in which to store all the meshes.
  ensureFolderExists(spline, splineIdx)

  -- Set the random seed to ensure deterministic variation (in distribution, jitter, etc.).
  randomseed(spline.splineRandomSeed)

  -- Sample the spline to get the placement positions on the spline, and their Frenet frames.
  local fullSpacing = minSpacingBetweenMolecules + spline.spacing
  geom.sampleSpline(spline.divPoints, spline.tangents, spline.normals, fullSpacing, finalPosns, finalTans, finalNormals)
  local numPlacements = #finalPosns

  -- Compute component maps for random/round robin distribution.
  -- [For every placement position, we compute the approriate variation for each mesh, based on the chosen distribution.]
  local rigidMaps, bridgeMaps = distrib.computeMeshMap(molecule, numPlacements, spline)

  -- Manage mesh pools based on the distribution maps.
  manageMeshPools(spline, rigidMaps, bridgeMaps)

  -- Initialise counters for each mesh path.
  table.clear(counters)
  for meshPath, _ in pairs(neededMeshes) do
    counters[meshPath] = 1
  end

  -- Ensure the placement caches are large enough for the assembly spline.
  local rigidMeshes = molecule.rigids
  local numRigidMeshes, numMolecules = #rigidMeshes, numPlacements
  if numMolecules > maxMolecules or numRigidMeshes > maxRigidMeshes then
    maxMolecules, maxRigidMeshes = max(maxMolecules, numMolecules), max(maxRigidMeshes, numRigidMeshes) -- Grow the indexing, if needed.
    for i = 1, maxMolecules * maxRigidMeshes do
      translationArray[i] = translationArray[i] or vec3() -- Create reusable vec3 and quat objects, as and when we need them.
      rotationArray[i] = rotationArray[i] or quat()
    end
  end
  for i = 1, maxMolecules * maxRigidMeshes do
    translationArray[i]:set(0, 0, 0) -- Clear all existing placement caches before use (reset to zero/identity).
    rotationArray[i]:set(0, 0, 0, 1)
  end

  -- Place all molecules (composed of rigid meshes) at each placement position.
  -- [Molecules are composed of rigid meshes, which have attachment frames with group numbering to match joins across meshes.]
  -- [We first place the root rigid mesh, then follow a pre-computed attachment sequence to place the other rigid meshes, in turn.]
  local placingOrder, attachSequence = molecule.placingOrder, molecule.rigidAttachmentSequence
  local attachSeqLength, verticalOffset, normalMode, splineId = #attachSequence, spline.verticalOffset, spline.normalMode, spline.id
  for i = 1, numPlacements do
    -- Position and Frenet frame at this spline sample point.
    local iMinus1 = i - 1
    local pos, tangent, normal = finalPosns[i], finalTans[i], nil
    if normalMode == 0 then
      normal = finalNormals[i] -- Local up (spline normals).
    elseif normalMode == 1 then
      normal = up -- Global up (world Z-axis).
    else
      normal = tmpVec4 -- Terrain up (mode 2).
      geom.getTerrainNormalInPlace(finalPosns[i], normal)
    end

    -- Place the root rigid mesh for this molecule first. This defines how the molecule is oriented on the spline.
    -- [We align to the spline's local binormal and normal, then apply a random jitter quaternion.]
    local rootMeshIdx = placingOrder[1]
    local rootComponent = rigidMaps[rootMeshIdx] and rigidMaps[rootMeshIdx][i]
    if rootComponent then -- Check if the root mesh is enabled before trying to place it.
      vertOffsetVec:setScaled2(normal, verticalOffset) -- The vertical offset vector (on local normal), in world space.
      pos:setAdd2(pos, vertOffsetVec) -- Apply the user's global vertical offset for all molecules.
      tmpVec1:setCross(tangent, normal) -- Unit binormal.
      finalRot:setFromDir(tmpVec1, normal) -- Set the base rotation to align the binormal to the spline tangent.
      geom.computeRandomJitterQuat(spline, tangent, tmpVec1, normal, jitterQuat) -- Gets a random jitter quaternion, for this molecule.
      rootRot:setMul2(preRotQuats[spline.preRot], finalRot) -- Apply pre-rotation FIRST, then base spline alignment.
      rootRot:setMul2(rootRot, jitterQuat) -- Apply jitter LAST.
      local mesh = getNextMeshFromPool(rootComponent, splineId)
      mesh:setPosRot(pos.x, pos.y, pos.z, rootRot.x, rootRot.y, rootRot.z, rootRot.w) -- Set the final pose of the root mesh.
      mesh.scale = defaultScale

      -- Store the translation/rotation which was used to place this root mesh, in the pre-allocated caches.
      local idx = iMinus1 * maxRigidMeshes + rootMeshIdx -- The 1D index of the root mesh (of this molecule), in the translation/rotation arrays.
      translationArray[idx]:set(pos)
      rotationArray[idx]:set(rootRot)

      -- Place the other rigid meshes for this molecule, using the molecule's pre-computed attachment sequence.
      -- [After the root rigid mesh has been placed, we follow the attachment sequence to place the other rigid meshes, in turn.]
      -- [This is done in two steps: align starting frame to target frame, then translate to the correct position.]
      for j = 1, attachSeqLength do
        -- Get the mesh space frame of the attachment point on the to-be-placed mesh.
        -- [This is the starting frame, to be matched to the target.]
        local sequenceStepData = attachSequence[j]
        local toPlaceMeshIdx, toPlaceAttachIdx = sequenceStepData.toPlaceMeshIdx, sequenceStepData.toPlaceAttachIdx
        local toPlaceComponent = rigidMaps[toPlaceMeshIdx] and rigidMaps[toPlaceMeshIdx][i]
        if toPlaceComponent then -- Only process this attachment step if the mesh to be placed is enabled.
          local toPlaceMesh = rigidMeshes[toPlaceMeshIdx] -- Get the original mesh for attachment data.
          local toPlaceAttachData = toPlaceMesh.attachments[toPlaceAttachIdx]
          local toPlacePosMS = toPlaceAttachData.attachPos -- The attachment point, in its mesh space.
          local toPlaceForwardMS, toPlaceUpMS = toPlaceAttachData.forward, toPlaceAttachData.up -- The frame, in mesh space.

          -- Get the world space position/frame of the already-placed attachment. This is the target, to which we align the starting frame.
          local placedMeshIdx, placedAttachIdx = sequenceStepData.alreadyPlacedMeshIdx, sequenceStepData.alreadyPlacedAttachIdx
          local placedMesh = rigidMeshes[placedMeshIdx]
          local placedAttachData = placedMesh.attachments[placedAttachIdx]
          idx = iMinus1 * maxRigidMeshes + placedMeshIdx -- The 1D index of the placed mesh in the translation/rotation arrays.
          local placedMeshPos, placedMeshRot = translationArray[idx], rotationArray[idx] -- The pose of the placed mesh.
          local placedAttachPos = placedAttachData.attachPos -- Attach position of the already-placed mesh, in local mesh space.
          local placedAttachForward, placedAttachUp = placedAttachData.forward, placedAttachData.up -- Frenet frame in local mesh space.
          tmpVec3:setRotate(placedMeshRot, placedAttachPos) -- Transform the attach position to world space (rotate then translate).
          placedPosWS:setAdd2(placedMeshPos, tmpVec3) -- 'Attach' anchor point for this mesh/attachment, in world space.
          placedForwardVec:setRotate(placedMeshRot, placedAttachForward) -- Transform the 'forward' direction vector to world space.
          placedUpVec:setRotate(placedMeshRot, placedAttachUp) -- Transform the 'up' direction vector to world space.

          -- Compute the quaternion required to rotate the starting frame onto the target frame. Done in two steps: first align forward, then align up.
          forwardRot:setRotationFromTo(toPlaceForwardMS, placedForwardVec) -- The rotation that aligns the forward vectors.
          tmpVec3:setRotate(forwardRot, toPlaceUpMS) -- Apply this rotation to the starting up vector.
          upRot:setRotationFromTo(tmpVec3, placedUpVec) -- Find the additional rotation needed to align the up vectors.
          aligningRot:setMul2(forwardRot, upRot) -- Combine the rotations: first align forward, then align up.

          -- Compute the translation required, post rotation, to ensure the frames line up exactly in world space. This gives the world space position.
          tmpVec3:setRotate(aligningRot, toPlacePosMS) -- The attachment point, post rotation, in its mesh space.
          posWS:setSub2(placedPosWS, tmpVec3) -- Translation required to move 'attach' point to 'attach' of the already-placed mesh.

          -- Apply random rotations around each freedom axis of the to-be-placed mesh.
          local freedomAxes = toPlaceAttachData.freedomAxes
          if freedomAxes and #freedomAxes > 0 then
            freedomJitterQuat:set(0, 0, 0, 1)
            for k = 1, #freedomAxes do
              local freedomAxis = freedomAxes[k]
              local randomAngle = random() * twoPi -- [0, 360] degrees.
              freedomAxisWorld:setRotate(aligningRot, freedomAxis)
              freedomAxisWorld:normalize()
              axisJitterQuat:setFromAxisAngle(freedomAxisWorld, randomAngle)
              freedomJitterQuat:setMul2(freedomJitterQuat, axisJitterQuat)
            end
            freedomJitterQuat:normalize()
            aligningRot:setMul2(aligningRot, freedomJitterQuat)

            -- Recompute position to maintain attachment point alignment after freedom axes rotation.
            tmpVec3:setRotate(aligningRot, toPlacePosMS) -- The attachment point, post freedom rotation, in its mesh space.
            posWS:setSub2(placedPosWS, tmpVec3) -- Translation required to move 'attach' point to 'attach' of the already-placed mesh.
          end

          -- Place the mesh in world space, with the correct pose.
          local placingMesh = getNextMeshFromPool(toPlaceComponent, splineId)
          placingMesh:setPosRot(posWS.x, posWS.y, posWS.z, aligningRot.x, aligningRot.y, aligningRot.z, aligningRot.w)
          placingMesh.scale = defaultScale

          -- Store the translation/rotation which was used to place this mesh, in the pre-allocated caches.
          -- [This allows us to handle later meshes which may be attached to this mesh.]
          idx = iMinus1 * maxRigidMeshes + toPlaceMeshIdx -- The 1D index of the to-be-placed mesh in the translation/rotation arrays.
          translationArray[idx]:set(posWS)
          rotationArray[idx]:set(aligningRot)
        end
      end
    end
  end

  -- Bridge meshes. Each bridge mesh is placed between two adjacent molecules, along the spline.
  -- [We align the bridge to span from the source molecule's attachment point to the target molecule's attachment point, in world space.]
  -- [We compute the roll angles required to align the nails at the source/target ends, then use the average to rotate the bridge around its X-axis.]
  -- [We then scale the bridge to match the distance between the two attachment points, and apply the user's sag factor only to bridges that support it.]
  local bridges, bridgeAttachments = molecule.bridges, molecule.bridgeAttachments
  local sagFactor = 1.0 + spline.sag * 0.1 -- The user sag factor (Z-scaling), used for bridges which support sag.
  local numBridges = #bridges
  for i = 2, numPlacements do -- Iterate over each adjacent pair of molecules, along the spline.
    local sourceMoleculeIdx, targetMoleculeIdx = i - 1, i
    for j = 1, numBridges do
      local bridge = bridges[j]
      local bridgeComponent = bridgeMaps[j] and bridgeMaps[j][sourceMoleculeIdx]
      if bridgeComponent then -- Only process this bridge if it is enabled.
        local attachData = bridgeAttachments[j] -- The pre-computed attachment data for this bridge's source attachment (always the first in list).
        local sourceMeshIdx, sourceAttachIdx = attachData.sourceMeshIdx, attachData.sourceAttachmentIdx -- The source mesh and attachment index.
        local targetMeshIdx, targetAttachIdx = attachData.targetMeshIdx, attachData.targetAttachmentIdx -- The target mesh and attachment index.
        local sourceMesh, targetMesh = rigidMeshes[sourceMeshIdx], rigidMeshes[targetMeshIdx] -- The source and target rigid meshes (in any molecule)
        local sourceAttachData = sourceMesh.attachments[sourceAttachIdx] -- The source rigid mesh attachment data.
        local targetAttachData = targetMesh.attachments[targetAttachIdx] -- The target rigid mesh attachment data.

        -- Get the attachment point data on the already-placed source rigid mesh, in world space.
        local sourceIdx = (sourceMoleculeIdx - 1) * maxRigidMeshes + sourceMeshIdx -- 1D index of source mesh in translation/rotation arrays.
        local sourceMeshPosWS, sourceMeshRot = translationArray[sourceIdx], rotationArray[sourceIdx] -- Source attach group, in world space.
        local sourceAttachPos, sourceAttachForward, sourceAttachUp = sourceAttachData.attachPos, sourceAttachData.forward, sourceAttachData.up
        tmpVec3:setRotate(sourceMeshRot, sourceAttachPos)
        sourcePosWS:setAdd2(sourceMeshPosWS, tmpVec3) -- Source attachment point in world space.
        sourceForwardVec:setRotate(sourceMeshRot, sourceAttachForward) -- Source forward direction in world space.
        sourceForwardVec:normalize()
        sourceUpVec:setRotate(sourceMeshRot, sourceAttachUp) -- Source up direction in world space.
        sourceUpVec:normalize()

        -- Get the target attachment point data in world space.
        local targetIdx = (targetMoleculeIdx - 1) * maxRigidMeshes + targetMeshIdx
        local targetMeshPosWS, targetMeshRot = translationArray[targetIdx], rotationArray[targetIdx]
        tmpVec3:setRotate(targetMeshRot, targetAttachData.attachPos)
        targetAttachPosWS:setAdd2(targetMeshPosWS, tmpVec3) -- Target attachment point in world space.

        -- Get the bridge source and target attachment data (nail joins).
        local attachmentDataFromBridge = bridge.attachments
        local bridgeSourceAttachData, bridgeTargetAttachData = attachmentDataFromBridge[1], attachmentDataFromBridge[2]

        -- Calculate the required direction alignment to align the bridge forward between source and target.
        bridgeInternalDir:setSub2(bridgeTargetAttachData.attachPos, bridgeSourceAttachData.attachPos)
        bridgeInternalDir:normalize() -- Bridge's internal direction from source to target (on the bridge, in local mesh space).
        tmpVec3:setSub2(targetAttachPosWS, sourcePosWS)
        tmpVec3:normalize() -- World space bridge direction.
        directionRot:setRotationFromTo(bridgeInternalDir, tmpVec3)

        -- Transform all four nail axes to world space (source and target from both the bridge and the resp. molecule meshes.)
        local sourceNailAxis = sourceAttachData.freedomAxes[1] -- Source nail axis in local mesh space.
        sourceNailAxisWorld:setRotate(sourceMeshRot, sourceNailAxis) -- Transform nail axes to world space.
        sourceNailAxisWorld:normalize()
        local targetNailAxis = targetAttachData.freedomAxes[1] -- Target nail axis in local mesh space.
        targetNailAxisWorld:setRotate(targetMeshRot, targetNailAxis) -- Transform nail axes to world space.
        targetNailAxisWorld:normalize()
        local bridgeSourceNailAxis = bridgeSourceAttachData.freedomAxes[1] -- Bridge source nail axis in local mesh space.
        bridgeSourceNailAxisWorld:setRotate(directionRot, bridgeSourceNailAxis) -- Transform bridge source nail axis in world space.
        bridgeSourceNailAxisWorld:normalize()
        local bridgeTargetNailAxis = bridgeTargetAttachData.freedomAxes[1] -- Bridge target nail axis in local mesh space.
        bridgeTargetNailAxisWorld:setRotate(directionRot, bridgeTargetNailAxis) -- Transform bridge target nail axis in world space.
        bridgeTargetNailAxisWorld:normalize()

        -- Compute the required roll angle to align the bridge at the source attachment point.
        tmpVec4:setScaled2(tmpVec3, sourceNailAxisWorld:dot(tmpVec3))
        sourceNailProj:setSub2(sourceNailAxisWorld, tmpVec4)
        sourceNailProj:normalize()
        tmpVec4:setScaled2(tmpVec3, bridgeSourceNailAxisWorld:dot(tmpVec3))
        bridgeSourceNailProj:setSub2(bridgeSourceNailAxisWorld, tmpVec4)
        bridgeSourceNailProj:normalize()
        tmpVec2:setCross(tmpVec3, bridgeSourceNailProj)
        local sourceRoll = atan2(sourceNailProj:dot(tmpVec2), sourceNailProj:dot(bridgeSourceNailProj))

        -- Compute the required roll angle to align the bridge at the target attachment point.
        tmpVec4:setScaled2(tmpVec3, targetNailAxisWorld:dot(tmpVec3))
        targetNailProj:setSub2(targetNailAxisWorld, tmpVec4)
        targetNailProj:normalize()
        tmpVec4:setScaled2(tmpVec3, bridgeTargetNailAxisWorld:dot(tmpVec3))
        bridgeTargetNailProj:setSub2(bridgeTargetNailAxisWorld, tmpVec4)
        bridgeTargetNailProj:normalize()
        tmpVec2:setCross(tmpVec3, bridgeTargetNailProj)
        local targetRoll = atan2(targetNailProj:dot(tmpVec2), targetNailProj:dot(bridgeTargetNailProj))

        -- Create the quaternion to rotate the bridge around its local X-axis (in mesh space), by the average roll angle.
        rollRot:setFromAxisAngle(bridgeXAxis, (sourceRoll + targetRoll) * 0.5) -- Rotate by the average roll angle.

        -- Combine roll and direction rotations (roll first, then direction).
        finalRot:setMul2(rollRot, directionRot)

        -- Calculate the required scaling for the bridge along its X axis (mesh space), so it spans exactly from source to target.
        local bridgeLocalSpan = bridgeSourceAttachData.attachPos:distance(bridgeTargetAttachData.attachPos)
        local actualDistance = sourcePosWS:distance(targetAttachPosWS)
        local scaleX = actualDistance / bridgeLocalSpan -- X scaling to make bridge span exactly from source to target.

        -- Calculate sag scaling (Z-Axis) for this bridge, if supported by this mesh.
        local scaleZ = bridge.isSag and sagFactor or 1.0

        -- Scale the bridge attachment points by the required scaling factor to match the distance between the source and target attachment points.
        local bridgeAttachPointSrc, bridgeAttachPointTgt = bridgeSourceAttachData.attachPos, bridgeTargetAttachData.attachPos
        tmpVec1:set(bridgeAttachPointSrc.x * scaleX, bridgeAttachPointSrc.y, bridgeAttachPointSrc.z * scaleZ)
        tmpVec2:set(bridgeAttachPointTgt.x * scaleX, bridgeAttachPointTgt.y, bridgeAttachPointTgt.z * scaleZ)

        -- Transform scaled bridge attachment points to world space. Aligning to the source ensures we align to target too (since its lined up now).
        bridgeSourcePosWorld:setRotate(finalRot, tmpVec1) -- Rotate the scaled source attachment point to world space.
        finalPos:setSub2(sourcePosWS, bridgeSourcePosWorld) -- Translate the source attachment point to the world space position of the source molecule.

        -- Place the bridge mesh in world space, with the composed final transform data.
        local mesh = getNextMeshFromPool(bridgeComponent, splineId) -- The bridge mesh, from the pool.
        mesh:setPosRot(finalPos.x, finalPos.y, finalPos.z, finalRot.x, finalRot.y, finalRot.z, finalRot.w)
        tmpScale:set(scaleX, 1.0, scaleZ) -- The full scaling vector (X to match span distance, Z for user sag).
        mesh.scale = tmpScale
      end
    end
  end
end

-- Tries to remove all the meshes for the given spline.
local function tryRemove(spline)
  local splineId = spline.id
  local meshesBySpline = staticMeshes[splineId]
  if meshesBySpline then
    for i = 1, #meshesBySpline do
      local obj = scenetree.findObjectById(meshesBySpline[i])
      if obj then
        obj:delete()
      end
    end
    staticMeshes[splineId] = nil
  end

  -- Clear mesh pools for this spline to prevent stale references.
  if meshPools[splineId] then
    for _, pathPool in pairs(meshPools[splineId]) do
      for i = #pathPool, 1, -1 do
        local mesh = pathPool[i]
        if mesh and simObjectExists(mesh) then
          mesh:delete()
        end
        pathPool[i] = nil
      end
    end
    meshPools[splineId] = nil
  end
end


-- Public interface.
M.populateAssemblySpline =                              populateAssemblySpline
M.tryRemove =                                           tryRemove

return M