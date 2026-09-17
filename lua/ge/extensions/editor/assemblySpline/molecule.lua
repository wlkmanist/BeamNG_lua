-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file,
-- You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local rootFilenameStr = "root" -- The expected string to appear in the filename of the root mesh.
local bridgeFilenameStr = "bridge" -- The expected string to appear in the filename of all bridge meshes.
local sagFilenameStr = "sag" -- The expected string to appear in the filename of sag-enabled bridge meshes.
local variationFilenameStr = "var" -- The expected string to appear in variation filenames.

local anchorPrefixStr = "nail" -- The expected prefix for all tool-compatible anchor point names.

local pointTypeStr = "point" -- The expected name for the'point' anchor point.
local headTypeStr = "head" -- The expected name for the 'head' anchor point.
local auxTypeStr = "aux" -- The expected name for the 'aux' anchor point.

local nailJoinTypeStr = "nail" -- A 'nail' join is a 1-DOF join containing two points (point, head), with rotation around the nail axis.
local fixedJoinTypeStr = "fixed" -- A 'fixed' join is a 0-DOF join containing three points (point, head, aux), with no rotation.
local ballJoinTypeStr = "ball" -- A 'ball' join is a 3-DOF join containing one point (point), with no rotation.

local epsilon = 1e-12

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}
local logtag = "assemblySpline.molecule"

-- Module constants.
local abs = math.abs
local anchorPrefixStrWithDot = anchorPrefixStr .. '.'

-- Module state.
local forwardRot, upRot, aligningRot = quat(), quat(), quat()
local placedPosWS, posWS, attachAnchorPostRotateMS = vec3(), vec3(), vec3()
local placedForwardVec, placedUpVec, rotatedUp = vec3(), vec3(), vec3()


-- Checks if the rigid mesh with the given id is enabled or disabled for the given spline.
local function getRigidEnabled(spline, meshId)
  if not spline.rigidEnabledStates then
    return true -- Default to enabled if no state exists.
  end
  -- Only return true if explicitly set to true, otherwise return false.
  return spline.rigidEnabledStates[meshId] == true
end

-- Sets the enabled state for the rigid mesh with the given id for the given spline.
local function setRigidEnabled(spline, meshId, enabled)
  spline.rigidEnabledStates = spline.rigidEnabledStates or {}
  spline.rigidEnabledStates[meshId] = enabled
end

-- Checks if the bridge mesh with the given id is enabled or disabled for the given spline.
local function getBridgeEnabled(spline, meshId)
  if not spline.bridgeEnabledStates then
    return true -- Default to enabled if no state exists.
  end
  -- Only return true if explicitly set to true, otherwise return false.
  return spline.bridgeEnabledStates[meshId] == true
end

-- Sets the enabled state for the bridge mesh with the given ID for the given spline.
local function setBridgeEnabled(spline, meshId, enabled)
  spline.bridgeEnabledStates = spline.bridgeEnabledStates or {}
  spline.bridgeEnabledStates[meshId] = enabled
end

-- Gets the random distribution flag for the rigid mesh with the given ID for the given spline.
local function getRigidRandom(spline, meshId)
  if not spline.rigidRandomStates then
    return false -- Default to round robin if no state exists
  end
  return spline.rigidRandomStates[meshId] == true
end

-- Sets the random distribution flag for the rigid mesh with the given ID for the given spline.
local function setRigidRandom(spline, meshId, isRandom)
  spline.rigidRandomStates = spline.rigidRandomStates or {}
  spline.rigidRandomStates[meshId] = isRandom
end

-- Gets the random weight for the rigid mesh with the given ID for the given spline.
local function getRigidRandomWeight(spline, meshId)
  if not spline.rigidRandomWeights then
    return 1.0 -- Default weight if no state exists
  end
  return spline.rigidRandomWeights[meshId] or 1.0
end

-- Sets the random weight for the rigid mesh with the given ID for the given spline.
local function setRigidRandomWeight(spline, meshId, weight)
  spline.rigidRandomWeights = spline.rigidRandomWeights or {}
  spline.rigidRandomWeights[meshId] = weight
end

-- Gets the random distribution flag for the bridge mesh with the given ID for the given spline.
local function getBridgeRandom(spline, meshId)
  if not spline.bridgeRandomStates then
    return false -- Default to round robin if no state exists
  end
  return spline.bridgeRandomStates[meshId] == true
end

-- Sets the random distribution flag for the bridge mesh with the given ID for the given spline.
local function setBridgeRandom(spline, meshId, isRandom)
  spline.bridgeRandomStates = spline.bridgeRandomStates or {}
  spline.bridgeRandomStates[meshId] = isRandom
end

-- Gets the random weight for the bridge mesh with the given ID for the given spline.
local function getBridgeRandomWeight(spline, meshId)
  if not spline.bridgeRandomWeights then
    return 1.0 -- Default weight if no state exists
  end
  return spline.bridgeRandomWeights[meshId] or 1.0
end

-- Sets the random weight for the bridge mesh with the given ID for the given spline.
local function setBridgeRandomWeight(spline, meshId, weight)
  spline.bridgeRandomWeights = spline.bridgeRandomWeights or {}
  spline.bridgeRandomWeights[meshId] = weight
end

-- Gets the assembly kit from the selected .dae file (will take all siblings and extract bounding box data).
local function getAssemblyKit(kitFolderPath)
  if not kitFolderPath or kitFolderPath == "" then
    return {}, "" -- Early return if invalid filepath provided.
  end

  -- Collect all .dae files in the folder and subfolders.
  local meshPaths = FS:findFiles(kitFolderPath, "*.dae", -1, true)

  local assemblyKit, ctr = {}, 1
  for _, path in ipairs(meshPaths) do
    assemblyKit[ctr] = {
      id = Engine.generateUUID(), -- Unique id for this mesh
      meshPath = path, -- Path to the mesh file.
      fileName = path:match("^.+/(.+)$"), -- File name of the mesh file.
      isRandom = false, -- Whether to use random distribution (false = round robin, true = random).
      randomWeight = 1.0, -- Weight for random distribution (0.0 to 1.0).
    }
    ctr = ctr + 1
  end

  return assemblyKit
end

-- Determine all the attachment points for the given mesh.
local function getAttachmentPoints(meshPath)
  -- Create a temporary mesh to read the attachment points from.
  local obj = createObject('TSStatic')
  obj.cansave = false
  obj:setField('shapeName', 0, meshPath)
  obj:registerObject('temp_parseAnchorPoints')

  -- Get all anchor point names from this mesh.
  local anchorNames = obj:getAnchorNames()

  -- Collect and group the attachment points from the anchors.
  local attachData, joinGroups = {}, {}
  for _, anchorName in ipairs(anchorNames) do
    if anchorName:sub(1, 5) == anchorPrefixStrWithDot then
      local parts = {}
      for part in anchorName:gmatch("[^%.]+") do -- Parse the anchor point name into parts.
        parts[#parts + 1] = part
      end

      -- Validate against the tool anchor point format: [nail.joinName.point.aliasName].
      -- [1] = prefix to identify use for this tool, [2] = unique join name, [3] = point type, [4] = alias name (optional).
      if #parts >= 3 and parts[1] == anchorPrefixStr then
        local joinName, pointType, aliasName = parts[2], parts[3], parts[4]
        if pointType == pointTypeStr or pointType == headTypeStr or pointType == auxTypeStr then -- Ensure the point type is valid.
          local isExist, pos = obj:getNodeTransform(anchorName) -- Get the anchor point position in local mesh space.
          if isExist then
            local joinKey = aliasName and (joinName .. "." .. aliasName) or joinName -- Unique key for this join group, including alias.
            if not joinGroups[joinKey] then -- Initialise a join group if it doesn't exist yet.
              joinGroups[joinKey] = {
                joinName = joinKey, -- The full join name, including alias.
                baseJoinName = joinName, -- The base join name, without alias.
                aliasName = aliasName or "main", -- The alias name, or "main" if none.
                points = {}, -- The points for this join group.
             }
            end
            joinGroups[joinKey].points[pointType] = vec3(pos.x, pos.y, pos.z) -- Store the point.
          else
            log('W', logtag, string.format("Anchor point [%s] not found in mesh: [%s]", anchorName, meshPath))
          end
        else
          log('W', logtag, string.format("Invalid point type [%s] in anchor: [%s]", pointType, anchorName))
        end
      else
        log('W', logtag, string.format("Invalid anchor point format: [%s]", anchorName))
      end
    end
  end

  -- Convert valid join groups to mesh attachment data.
  for joinName, joinGroup in pairs(joinGroups) do
    local points = joinGroup.points
    if points.point then
      local attachPos = points.point
      if points.aux then -- Three-point fixed join: [0 degrees of freedom].
        if points.head then
          local nailVector = points.head - points.point
          local auxVector = points.aux - points.point
          if nailVector:squaredLength() > epsilon and auxVector:squaredLength() > epsilon then
            nailVector:normalize()
            auxVector:normalize()
            local cross = nailVector:cross(auxVector)
            if cross:squaredLength() > epsilon then -- Ensure the aux point is not collinear with the nail vector.
              cross:normalize()
              local forwardON = nailVector:copy() -- Orthonormalise the basis.
              local upON = cross:copy()
              local rightON = forwardON:cross(upON)
              rightON:normalize()
              upON:setCross(rightON, forwardON)
              upON:normalize()
              attachData[#attachData + 1] = {
                joinName = joinName,
                aliasName = joinGroup.aliasName,
                attachPos = attachPos,
                forward = forwardON,
                up = upON,
                freedomAxes = {}, -- No degrees of freedom for this type of join.
                joinType = fixedJoinTypeStr
              }
            else
              log('W', logtag, string.format("Nail and aux vectors are collinear in join [%s] in mesh: [%s]", joinName, meshPath))
            end
          else
            log('W', logtag, string.format("Invalid vectors in three-point join [%s] in mesh: [%s]", joinName, meshPath))
          end
        else
          log('W', logtag, string.format("Three-point join [%s] missing 'head' anchor in mesh: [%s]", joinName, meshPath))
        end
      elseif points.head then -- Two-point nail: [1 degree of freedom with rotation around nail axis].
        local nailVector = points.head - points.point
        if nailVector:squaredLength() > epsilon then
          -- Orthogonalise nail axis to local mesh X-axis (bridge direction).
          local localXAxis = vec3(1, 0, 0) -- Local mesh X-axis.
          nailVector:normalize()
          local dot = nailVector:dot(localXAxis)
          if abs(dot) > 0.9 then
            localXAxis:set(0, 1, 0) -- Nail is too close to X-axis, use Y-axis instead.
            dot = nailVector:dot(localXAxis)
          end

          -- Project the nail vector to be perpendicular to the local X-axis.
          local projectedNail, scaledXAxis = nailVector:copy(), localXAxis:copy()
          scaledXAxis:setScaled2(scaledXAxis, dot)
          projectedNail:setSub2(projectedNail, scaledXAxis)
          projectedNail:normalize()

          -- Create orthonormal basis: X-axis, projected nail, and their cross product.
          local forwardON = localXAxis:copy() -- Local X-axis (bridge direction).
          local upON = projectedNail:copy() -- Orthogonalized nail axis.
          local rightON = forwardON:cross(upON) -- Third axis to complete orthonormal basis.
          rightON:normalize()
          upON:setCross(rightON, forwardON) -- Recompute 'up' to ensure perfect orthonormality.
          upON:normalize()
          attachData[#attachData + 1] = {
            joinName = joinName,
            baseJoinName = joinGroup.baseJoinName,
            aliasName = joinGroup.aliasName,
            attachPos = attachPos,
            forward = forwardON,
            up = upON,
            freedomAxes = { projectedNail }, -- The only freedom axis is the orthogonalised nail vector.
            joinType = nailJoinTypeStr
          }
        else
          log('W', logtag, string.format("Nail vector too short in join [%s] in mesh: [%s]", joinName, meshPath))
        end
      else -- One-point ball joint: [3 degrees of freedom].
        attachData[#attachData + 1] = {
          joinName = joinName,
          baseJoinName = joinGroup.baseJoinName,
          aliasName = joinGroup.aliasName,
          attachPos = attachPos,
          forward = vec3(1, 0, 0), -- Default world forward, since we have no definite forward direction.
          up = vec3(0, 0, 1), -- Default world up, since we have no definite up direction.
          freedomAxes = { vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1) }, -- Three axes of freedom for this type of join.
          joinType = ballJoinTypeStr
        }
      end
    else
      log('W', logtag, string.format("Join [%s] missing required 'point' anchor in mesh: [%s]", joinName, meshPath))
    end
  end

  -- Remove the temporary mesh.
  obj:delete()

  return attachData
end

-- Gets the mesh bounding box in local mesh space.
local function getMeshBoundingBox(meshPath)
  local obj = createObject('TSStatic')
  obj.cansave = false
  obj:setField('shapeName', 0, meshPath)
  obj:registerObject('temp_getBoundingBox')
  local objBox = obj:getObjBox() -- The mesh bounding box in local mesh space.
  local extents = objBox:getExtents() -- The extents of the mesh bounding box.
  local center = objBox:getCenter() -- The pivot (center) of the mesh bounding box.
  obj:delete()
  local halfExtents = extents * 0.5
  return {
    minExtents = center - halfExtents,
    maxExtents = center + halfExtents,
    center = center,
    extents = extents
  }
end

-- Moves an attachment point to the nearest boundary (start or end) in X direction.
local function moveAttachmentToBoundary(attachment, boundingBox, isSource, sourceEndX)
  -- Determine which boundary to move the attachment point to.
  local currentX, startX, endX = attachment.attachPos.x, boundingBox.minExtents.x, boundingBox.maxExtents.x
  local targetX = nil
  if isSource then
    targetX = (currentX - startX) < (endX - currentX) and startX or endX -- Source goes to whichever end is closer.
  else
    targetX = (sourceEndX == startX) and endX or startX -- Target goes to the opposite end from source.
  end

  -- Apply translation to all provided attachment points.
  local translationX = targetX - currentX -- Required translation to move the attachment point to the boundary.
  attachment.attachPos.x = attachment.attachPos.x + translationX
  if attachment.head then
    attachment.head.x = attachment.head.x + translationX
  end
  if attachment.aux then
    attachment.aux.x = attachment.aux.x + translationX
  end

  return targetX -- Return the target X position for reference.
end

-- Post-processing step to correct bridge attachment points to mesh boundaries.
-- [This is done to allow bridge anchor points to be placed away from the bridge X-min and X-max boundaries.]
-- [We also move the corresponding rigid attachment points accordingly, to match the correction on the bridge.]
-- [We force the points on to the boundaries, so that when we scale the bridge (in X) there is no overhang past the attach points.]
local function correctBridgeAttachmentPoints(molecule)
  if not molecule or not molecule.bridges or not molecule.bridgeAttachments then
    return -- Early return if invalid data provided.
  end

  -- Process each bridge, in turn.
  for i, bridge in ipairs(molecule.bridges) do
    local bridgeAttachData = molecule.bridgeAttachments[i]
    local sourceMeshIdx, targetMeshIdx = bridgeAttachData.sourceMeshIdx, bridgeAttachData.targetMeshIdx
    local bridgeBox = getMeshBoundingBox(bridge.mesh.meshPath) -- Get the mesh bounding box in local mesh space.

    -- Compute the quaternion which aligns the source bridge attachment to the source rigid attachment.
    local bridgeSourceAttachment = bridge.attachments[1]
    local bridgeAttachPos = bridgeSourceAttachment.attachPos
    local bridgeAttachForward, bridgeAttachUp = bridgeSourceAttachment.forward, bridgeSourceAttachment.up
    local sourceRigidAttachment = molecule.rigids[sourceMeshIdx].attachments[bridgeAttachData.sourceAttachmentIdx]
    local rigidAttachPos = sourceRigidAttachment.attachPos
    local rigidAttachForward, rigidAttachUp = sourceRigidAttachment.forward, sourceRigidAttachment.up
    placedPosWS:set(rigidAttachPos)
    placedForwardVec:set(rigidAttachForward)
    placedUpVec:set(rigidAttachUp)
    forwardRot:setRotationFromTo(bridgeAttachForward, placedForwardVec) -- Align the forward vectors.
    rotatedUp:setRotate(forwardRot, bridgeAttachUp)
    upRot:setRotationFromTo(rotatedUp, placedUpVec) -- Align the up vectors.
    aligningRot:setMul2(forwardRot, upRot) -- Combine the forward and up rotations to get the final alignment quaternion.

    -- Compute world space join position (the unique join point at which both meshes join).
    attachAnchorPostRotateMS:setRotate(aligningRot, bridgeAttachPos)
    posWS:setSub2(placedPosWS, attachAnchorPostRotateMS)

    -- Move bridge attachment to its closest boundary in its X dimension (only moves the x component).
    local sourceEndX = moveAttachmentToBoundary(bridgeSourceAttachment, bridgeBox, true, nil)

    -- Calculate the world space position of the bridge attachment after boundary move.
    attachAnchorPostRotateMS:setRotate(aligningRot, bridgeSourceAttachment.attachPos)
    local newBridgeWorldPos = posWS + attachAnchorPostRotateMS

    -- Calculate where the rigid attachment needs to be, to maintain the same world join position.
    -- [This needs to be maintained across meshes, so that the behaviour would be the same as if it was not corrected.]
    sourceRigidAttachment.attachPos:set(newBridgeWorldPos)
    if sourceRigidAttachment.head then
      sourceRigidAttachment.head:set(newBridgeWorldPos + (sourceRigidAttachment.head - rigidAttachPos))
    end
    if sourceRigidAttachment.aux then
      sourceRigidAttachment.aux:set(newBridgeWorldPos + (sourceRigidAttachment.aux - rigidAttachPos))
    end

    -- Compute the quaternion which aligns the target bridge attachment to the target rigid attachment.
    local targetRigidAttachment = molecule.rigids[targetMeshIdx].attachments[bridgeAttachData.targetAttachmentIdx]
    local bridgeTargetAttachment = bridge.attachments[2]
    placedPosWS:set(targetRigidAttachment.attachPos)
    placedForwardVec:set(targetRigidAttachment.forward)
    placedUpVec:set(targetRigidAttachment.up)
    forwardRot:setRotationFromTo(bridgeTargetAttachment.forward, placedForwardVec) -- Align the forward vectors.
    rotatedUp:setRotate(forwardRot, bridgeTargetAttachment.up)
    upRot:setRotationFromTo(rotatedUp, placedUpVec) -- Align the up vectors.
    aligningRot:setMul2(forwardRot, upRot) -- Combine the forward and up rotations to get the final alignment quaternion.

    -- Compute the world space join position of the target bridge attachment.
    attachAnchorPostRotateMS:setRotate(aligningRot, bridgeTargetAttachment.attachPos)
    posWS:setSub2(placedPosWS, attachAnchorPostRotateMS)

    -- Move bridge target attachment to the boundary (the opposite X boundary to the source end).
    moveAttachmentToBoundary(bridgeTargetAttachment, bridgeBox, false, sourceEndX)

    -- Calculate new world space position and update rigid attachment.
    attachAnchorPostRotateMS:setRotate(aligningRot, bridgeTargetAttachment.attachPos)
    local newRigidLocalPos = posWS + attachAnchorPostRotateMS
    targetRigidAttachment.attachPos:set(newRigidLocalPos)
    if targetRigidAttachment.head then
      targetRigidAttachment.head:set(newRigidLocalPos + (targetRigidAttachment.head - targetRigidAttachment.attachPos))
    end
    if targetRigidAttachment.aux then
      targetRigidAttachment.aux:set(newRigidLocalPos + (targetRigidAttachment.aux - targetRigidAttachment.attachPos))
    end
  end
end

-- Build the molecule from the given assembly kit.
local function buildMolecule(assemblyKit, spline)
  -- Group variations with their base meshes (all variations are enabled by default)/
  local baseToVariations = {}
  for _, mesh in ipairs(assemblyKit) do
    if mesh.fileName:lower():find(variationFilenameStr) then
      local baseName = mesh.fileName:match("(.+)_var") .. ".dae" -- Find the base mesh by taking everything before '_var' and adding '.dae'.
      baseToVariations[baseName] = baseToVariations[baseName] or {}
      table.insert(baseToVariations[baseName], mesh)
    end
  end

  -- Get the base meshes from the assembly kit, excluding variations.
  local baseMeshes = {}
  for _, mesh in ipairs(assemblyKit) do
    if not mesh.fileName:lower():find(variationFilenameStr) then
      baseMeshes[#baseMeshes + 1] = mesh
    end
  end
  if #baseMeshes < 1 then
    return nil -- We need at least one base mesh to build the molecule.
  end

  -- Filter into rigids and bridges arrays.
  local rigids, bridges = {}, {}
  for _, mesh in ipairs(baseMeshes) do
    local entry = {
      mesh = mesh, -- The core mesh data.
      attachments = getAttachmentPoints(mesh.meshPath), -- The attachment points for this mesh.
      variations = baseToVariations[mesh.fileName] or {}, -- The found variations of this mesh.
      isRandom = false, -- Whether to use random distribution for this component group.
      randomWeight = 1.0, -- Weight for random distribution for this component group.
      isSag = mesh.fileName:lower():find(sagFilenameStr) ~= nil, -- Check if this mesh supports sag.
    }
    if mesh.fileName:lower():find(bridgeFilenameStr) then
      bridges[#bridges + 1] = entry -- Add to bridges array (it contains the bridge identifier string in its filename).
    else
      rigids[#rigids + 1] = entry -- Add to rigids array.
    end
  end
  if #rigids < 1 then
    log('W', logtag, 'Invalid molecule: no rigid meshes found.')
    return nil -- We need at least one rigid mesh to build a molecule.
  end

  -- Create an expanded bridges array with entries for each instance of each bridge.
  -- [Bridges are generic and can attach to multiple join points on the molecule, so we create separate entries for each instance.]
  local expandedBridges, numRigids = {}, #rigids
  for i = 1, #bridges do
    local bridge = bridges[i]
    local bridgeAttachments = bridge.attachments
    local sourceMatchCtr, targetMatchCtr = 0, 0 -- Count the number of matches for this bridge.
    for j = 1, numRigids do
      local rigid = rigids[j]
      local rigidAttachments = rigid.attachments
      for k = 1, #rigidAttachments do
        local attachment = rigidAttachments[k]
        local baseJoinName = attachment.baseJoinName
        if baseJoinName == bridgeAttachments[1].joinName then -- Check for the bridge source join name.
          sourceMatchCtr = sourceMatchCtr + 1
        end
        if baseJoinName == bridgeAttachments[2].joinName then -- Check for the bridge target join name.
          targetMatchCtr = targetMatchCtr + 1
        end
      end
    end
    if sourceMatchCtr ~= targetMatchCtr then -- Validation of source and target matches.
      log('W', logtag, string.format("Bridge [%s] has different number of source and target matches: [%d] vs [%d]",
        bridge.mesh.fileName, sourceMatchCtr, targetMatchCtr))
      return nil -- We cannot have open bridges (those which have a different number of source and target matches).
    end

    -- Create entries for each required instance of this bridge.
     local bridgeMesh = bridge.mesh
     for _ = 1, sourceMatchCtr do
      local newBridgeEntry = {
        mesh = {
          id = Engine.generateUUID(), -- Unique id for this bridge instance.
          meshPath = bridgeMesh.meshPath, -- Same mesh path as original.
          fileName = bridgeMesh.fileName, -- Same file name as original.
        },
        attachments = bridge.attachments, -- Same attachment data as original.
        variations = {}, -- Create a new variations array for this bridge instance.
        isRandom = bridge.isRandom, -- Same distribution mode as original.
        randomWeight = bridge.randomWeight, -- Same weight as original.
        isSag = bridge.isSag, -- Whether this bridge supports sag
      }
      -- Copy variations with new unique ids for this bridge instance.
      for _, variation in ipairs(bridge.variations) do
        local newVariation = deepcopy(variation)
        newVariation.id = Engine.generateUUID() -- New unique id for this variation instance (to distinguish from base or other variations).
        newVariation.isRandom = newVariation.isRandom or false
        newVariation.randomWeight = newVariation.randomWeight or 1.0
        table.insert(newBridgeEntry.variations, newVariation)
      end
      expandedBridges[#expandedBridges + 1] = newBridgeEntry
    end
  end

  -- Find the root mesh.
  local rootIdx = nil
  for i, m in ipairs(rigids) do
    if m.mesh.fileName:lower():find(rootFilenameStr) then
      rootIdx = i -- The user has defined the root mesh, so we take that as the root.
      break
    end
  end
  if not rootIdx then -- The user has not defined the root mesh, so we take the first rigid mesh as the root.
    if #rigids > 0 then
      rootIdx = 1
      log('W', logtag, 'No mesh with "root" in name found. Using first rigid mesh as root: ' .. rigids[rootIdx].mesh.fileName)
    else
      log('W', logtag, 'Invalid molecule: no rigid meshes found.')
      return nil -- We need at least one rigid mesh to build a molecule.
    end
  end

  -- Compute the attachment data for the molecule (an ordered list of placement moves).
  local isPlaced, numPlaced = { [rootIdx] = true }, 1
  local placingOrder = { rootIdx }
  local rigidAttachmentSequence = {}
  local isMakingProgress = true
  while numPlaced < #rigids and isMakingProgress do
    isMakingProgress = false
    for i = 1, #rigids do -- Iterate over all rigid meshes.
      local trialMesh = rigids[i]
      local trialMeshAttachments = trialMesh.attachments
      local numTrialMeshAttachments = #trialMeshAttachments
      if not isPlaced[i] then
        for j, _ in pairs(isPlaced) do -- Iterate over all placed meshes.
          local placedMesh = rigids[j]
          local placedMeshAttachments = placedMesh.attachments
          local numPlacedMeshAttachments = #placedMeshAttachments
          for k = 1, numTrialMeshAttachments do -- Iterate over all trial mesh attachments.
            local trialAttachment = trialMeshAttachments[k]
            for l = 1, numPlacedMeshAttachments do -- Iterate over all placed mesh attachments.
              local placedAttachment = placedMeshAttachments[l]
              if trialAttachment.joinName == placedAttachment.joinName then
                isPlaced[i] = true
                table.insert(placingOrder, i)
                table.insert(rigidAttachmentSequence, {
                  alreadyPlacedMeshIdx = j, -- The index of the already placed mesh.
                  alreadyPlacedAttachIdx = l, -- The index of the already placed attachment, in the already placed mesh's attachment list.
                  toPlaceMeshIdx = i, -- The index of the to-place mesh.
                  toPlaceAttachIdx = k, -- The index of the to-place attachment, in the to-place mesh's attachment list.
                })
                numPlaced = numPlaced + 1
                isMakingProgress = true
                break
              end
            end
            if isPlaced[i] then
              break
            end
          end
          if isPlaced[i] then
            break
          end
        end
      end
    end
  end

  -- Validation check: Abort if there are any unplaced rigids.
  if numPlaced < #rigids then
    for i = 1, #rigids do
      if not isPlaced[i] then
        log('W', logtag, 'Invalid molecule: unplaced rigid mesh: ' .. tostring(rigids[i].mesh.fileName))
      end
    end
    return nil
  end

  -- Collect all the unique alias names from the rigid mesh attachments.
  local aliasNames, aliasCtr = {}, 1
  for j = 1, numRigids do
    local rigidMesh = rigids[j]
    local rigidMeshAttachments = rigidMesh.attachments
    for k = 1, #rigidMeshAttachments do
      local rigidAttachment = rigidMeshAttachments[k]
      local aliasName = rigidAttachment.aliasName
      local found = false -- Check if this alias name is already in our list.
      for m = 1, aliasCtr - 1 do
        if aliasNames[m] == aliasName then
          found = true
          break
        end
      end
      if not found then
        aliasNames[aliasCtr] = aliasName
        aliasCtr = aliasCtr + 1
      end
    end
  end

  -- Sort alias names to ensure consistent ordering (main, alias1, alias2, etc.)
  table.sort(aliasNames)

  -- Compute the attachment data for each bridge.
  local bridgeAttachments = {}
  for i = 1, #expandedBridges do
    local bridgeMesh, attachmentsForThisBridge = expandedBridges[i], {}
    local attachments = bridgeMesh.attachments
    if #attachments ~= 2 then
      log('W', logtag, 'Bridge must have exactly 2 attachment points: ' .. tostring(bridgeMesh.mesh.fileName))
      return nil -- Bridges must have exactly 2 attachment points (source and target).
    end

    -- Find matching rigid mesh attachments for this bridge instance.
    local bridgeSourceAttachment, bridgeTargetAttachment = attachments[1], attachments[2]
    local bridgeSourceJoinName, bridgeTargetJoinName = bridgeSourceAttachment.joinName, bridgeTargetAttachment.joinName
    local expectedAlias = aliasNames[i] or "main" -- The alias name for this bridge instance.
    local isSourceFound, isTargetFound = false, false
    for j = 1, numRigids do
      local rigidMesh = rigids[j]
      local rigidMeshAttachments = rigidMesh.attachments
      for k = 1, #rigidMeshAttachments do
        local rigidAttachment = rigidMeshAttachments[k]
        local rigidBaseJoinName, rigidAliasName = rigidAttachment.baseJoinName, rigidAttachment.aliasName
        if bridgeSourceJoinName == rigidBaseJoinName and rigidAliasName == expectedAlias then
          attachmentsForThisBridge.sourceMeshIdx = j -- The index of the molecule rigid mesh which contains the source attachment.
          attachmentsForThisBridge.sourceAttachmentIdx = k -- The index of the source attachment in the rigid mesh.
          isSourceFound = true
        elseif bridgeTargetJoinName == rigidBaseJoinName and rigidAliasName == expectedAlias then
          attachmentsForThisBridge.targetMeshIdx = j -- The index of the molecule rigid mesh which contains the target attachment.
          attachmentsForThisBridge.targetAttachmentIdx = k -- The index of the target attachment in the rigid mesh.
          isTargetFound = true
        end
        if isSourceFound and isTargetFound then
          break
        end
      end
      if isSourceFound and isTargetFound then
        break
      end
    end
    bridgeAttachments[i] = attachmentsForThisBridge
    if not isSourceFound or not isTargetFound then
      log('W', logtag, 'Bridge could not attach to molecule: ' .. tostring(bridgeMesh.mesh.fileName))
      return nil -- We cannot have free bridges. They must span across molecules.
    end
  end

  -- Initialise enabled states for all meshes and their variations (all enabled by default, but only if not already set).
  if spline then
    for _, rigid in ipairs(rigids) do
      if spline.rigidEnabledStates == nil or spline.rigidEnabledStates[rigid.mesh.id] == nil then
        setRigidEnabled(spline, rigid.mesh.id, true) -- Base mesh is enabled by default
      end
      if spline.rigidRandomStates == nil or spline.rigidRandomStates[rigid.mesh.id] == nil then
        setRigidRandom(spline, rigid.mesh.id, false) -- Default to round robin
      end
      if spline.rigidRandomWeights == nil or spline.rigidRandomWeights[rigid.mesh.id] == nil then
        setRigidRandomWeight(spline, rigid.mesh.id, 1.0) -- Default weight
      end
      for _, variation in ipairs(rigid.variations) do
        if spline.rigidEnabledStates == nil or spline.rigidEnabledStates[variation.id] == nil then
          setRigidEnabled(spline, variation.id, true) -- Variations are enabled by default
        end
        if spline.rigidRandomWeights == nil or spline.rigidRandomWeights[variation.id] == nil then
          setRigidRandomWeight(spline, variation.id, 1.0) -- Default weight for variations
        end
      end
    end
    for _, bridge in ipairs(expandedBridges) do
      if spline.bridgeEnabledStates == nil or spline.bridgeEnabledStates[bridge.mesh.id] == nil then
        setBridgeEnabled(spline, bridge.mesh.id, true) -- Base bridge mesh is enabled by default.
      end
      if spline.bridgeRandomStates == nil or spline.bridgeRandomStates[bridge.mesh.id] == nil then
        setBridgeRandom(spline, bridge.mesh.id, false) -- Default to round robin
      end
      if spline.bridgeRandomWeights == nil or spline.bridgeRandomWeights[bridge.mesh.id] == nil then
        setBridgeRandomWeight(spline, bridge.mesh.id, 1.0) -- Default weight
      end
      for _, variation in ipairs(bridge.variations) do
        if spline.bridgeEnabledStates == nil or spline.bridgeEnabledStates[variation.id] == nil then
          setBridgeEnabled(spline, variation.id, true) -- Variations are enabled by default
        end
        if spline.bridgeRandomWeights == nil or spline.bridgeRandomWeights[variation.id] == nil then
          setBridgeRandomWeight(spline, variation.id, 1.0) -- Default weight for variations
        end
      end
    end
  end

  -- Filter variations tables to only include enabled variations.
  if spline then
    for _, rigid in ipairs(rigids) do
      local enabledVariations = {}
      for _, variation in ipairs(rigid.variations) do
        if getRigidEnabled(spline, variation.id) then
          table.insert(enabledVariations, variation)
        end
      end
      rigid.variations = enabledVariations
    end
    for _, bridge in ipairs(expandedBridges) do
      local enabledVariations = {}
      for _, variation in ipairs(bridge.variations) do
        if getBridgeEnabled(spline, variation.id) then
          table.insert(enabledVariations, variation)
        end
      end
      bridge.variations = enabledVariations
    end
  end

  -- Check if any bridges support sag.
  local isSagEnabled = false
  for _, bridge in ipairs(expandedBridges) do
    if bridge.isSag then
      isSagEnabled = true
      break
    end
  end

  -- Build the molecule structure.
  local molecule = {
    rigids = rigids, -- The list of rigid meshes in the molecule.
    placingOrder = placingOrder, -- The ordered array of rigid mesh indices, used to build the molecule from the rigid meshes.
    rigidAttachmentSequence = rigidAttachmentSequence,-- The ordered list of placements to build the molecule from the rigid meshes.
    bridges = expandedBridges, -- The list of bridge meshes which span between consecutive pairs of molecules.
    bridgeAttachments = bridgeAttachments, -- The attachment data for each bridge.
    isSagEnabled = isSagEnabled, -- Whether any bridges in this molecule support sag
  }

  -- Post-process bridge attachment points to move them to mesh boundaries.
  correctBridgeAttachmentPoints(molecule)

  return molecule
end

-- Apply enabled states to a molecule after deserialisation.
local function applyEnabledStatesToMolecule(spline, molecule)
  if not spline or not molecule then
    return -- Early return if no spline or molecule provided.
  end

  -- Apply rigid enabled states.
  if molecule.rigids and spline.rigidEnabledStates then
    for _, rigid in ipairs(molecule.rigids) do
      if spline.rigidEnabledStates[rigid.mesh.id] ~= nil then
        setRigidEnabled(spline, rigid.mesh.id, spline.rigidEnabledStates[rigid.mesh.id])
      end
      for _, variation in ipairs(rigid.variations) do
        if spline.rigidEnabledStates[variation.id] ~= nil then
          setRigidEnabled(spline, variation.id, spline.rigidEnabledStates[variation.id])
        end
      end
    end
  end

  -- Apply bridge enabled states.
  if molecule.bridges and spline.bridgeEnabledStates then
    for _, bridge in ipairs(molecule.bridges) do
      if spline.bridgeEnabledStates[bridge.mesh.id] ~= nil then
        setBridgeEnabled(spline, bridge.mesh.id, spline.bridgeEnabledStates[bridge.mesh.id])
      end
      for _, variation in ipairs(bridge.variations) do
        if spline.bridgeEnabledStates[variation.id] ~= nil then
          setBridgeEnabled(spline, variation.id, spline.bridgeEnabledStates[variation.id])
        end
      end
    end
  end
end


-- Public interface.
M.getRigidEnabled =                                     getRigidEnabled
M.setRigidEnabled =                                     setRigidEnabled
M.getBridgeEnabled =                                    getBridgeEnabled
M.setBridgeEnabled =                                    setBridgeEnabled

M.getRigidRandom =                                      getRigidRandom
M.setRigidRandom =                                      setRigidRandom
M.getRigidRandomWeight =                                getRigidRandomWeight
M.setRigidRandomWeight =                                setRigidRandomWeight

M.getBridgeRandom =                                     getBridgeRandom
M.setBridgeRandom =                                     setBridgeRandom
M.getBridgeRandomWeight =                               getBridgeRandomWeight
M.setBridgeRandomWeight =                               setBridgeRandomWeight

M.getAssemblyKit =                                      getAssemblyKit
M.buildMolecule =                                       buildMolecule
M.applyEnabledStatesToMolecule =                        applyEnabledStatesToMolecule

return M