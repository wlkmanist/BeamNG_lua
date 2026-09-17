-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local anchorPrefixStr = "nail" -- The expected prefix for all tool-compatible anchor point names.

local rdpLightTolerance = 0.5

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}
local logtag = "assemblySpline.import"

-- Module dependencies.
local splineMgr = require('editor/assemblySpline/splineMgr')
local mol = require('editor/assemblySpline/molecule')
local rdp = require('editor/toolUtilities/rdp')
local fit = require('editor/toolUtilities/fitPoly')
local geom = require('editor/toolUtilities/geom')
local util = require('editor/toolUtilities/util')

-- Module constants.
local pi = math.pi
local twoPi, piOver4 = pi * 2.0, pi * 0.25
local globalUp = vec3(0, 0, 1)

-- Module state.
local isImportDelayUpdate = false
local importDelayFrameCount = 0
local cleanedGroups = {}
local orderedPositions, distances, filteredDistances = {}, {}, {}
local votes = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
local tmpRot = quat()
local tangent, expectedBinormal, actualBinormal = vec3(), vec3(), vec3()


-- Handle delayed spline updates.
-- [We need to wait until the collision mesh has been updated, then update the spline which was created by the import.]
local function handleDelayedSplineUpdates()
  if isImportDelayUpdate then
    importDelayFrameCount = importDelayFrameCount + 1
    if importDelayFrameCount >= 2 then
      local assemblySplines = splineMgr.getAssemblySplines()
      if #assemblySplines > 0 then
        local spline = assemblySplines[#assemblySplines]
        spline.isDirty = true
      end
      isImportDelayUpdate, importDelayFrameCount = false, 0
    end
  end
end

-- Backup TSStatic objects before deletion.
local function backupTSStatics(components)
  local backup = {}
  for i = 1, #components do
    local obj = components[i].obj
    if obj then
      local group = obj:getGroup()
      table.insert(backup, {
        id = obj:getID(),
        name = obj:getName(),
        shapeName = obj.shapeName,
        pos = obj:getPosition(),
        rot = obj:getField("rotation", 0),
        scale = obj.scale,
        groupId = group and group:getID() or nil
      })
    end
  end
  return backup
end

-- Restore TSStatic objects from backup.
local function restoreTSStatics(backup)
  for _, entry in ipairs(backup) do
    local obj = createObject("TSStatic")
    obj:setField("shapeName", 0, entry.shapeName)
    obj:setPosition(entry.pos)
    if type(entry.rot) == "string" then
      local x, y, z, w = string.match(entry.rot, "([%-%d%.eE]+)%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)")
      if x and y and z and w then
        obj:setField("rotation", 0, string.format("%s %s %s %s", x, y, z, w))
      else
        log("W", logtag, "Invalid rotation format in undo. Skipping setRotation.")
      end
    end
    obj.scale = entry.scale
    if entry.name then
      obj:registerObject(entry.name)
    else
      local fallbackName = (entry.shapeName:match("([^/]+)%.dae$") or entry.shapeName:match("([^/]+)$")) or "RestoredTSStatic"
      obj:registerObject(fallbackName)
    end
    local parent = entry.groupId and scenetree.findObjectById(entry.groupId)
    if parent then
      parent:addObject(obj)
    else
      scenetree.MissionGroup:addObject(obj)
    end
  end
end

-- Delete TSStatic objects from the backup.
local function deleteTSStaticsFromBackup(backup)
  for _, entry in ipairs(backup) do
    if entry.name then
      local obj = scenetree.findObject(entry.name)
      if obj and obj:getClassName() == "TSStatic" then
        obj:delete()
      end
    end
  end
end

-- Clean up empty parent groups.
local function cleanupEmptyGroups(components)
  table.clear(cleanedGroups)
  for i = 1, #components do
    local obj = components[i].obj
    if obj and Sim.upcast(obj) then
      local group = obj:getGroup()
      if group and Sim.upcast(group) and not cleanedGroups[group:getID()] then
        local onlyTSStatics = true
        for j = 0, group:size() - 1 do
          local sibling = group:at(j)
          if sibling and Sim.upcast(sibling) and sibling:getClassName() ~= "TSStatic" then
            onlyTSStatics = false
            break
          end
        end
        if onlyTSStatics and group:size() == 0 then
          group:delete()
        end
        cleanedGroups[group:getID()] = true
      end
    end
  end
end

-- Validate if a TSStatic object has tool-compatible anchor points.
local function validateToolCompatibleTSStatic(obj)
  if not obj or obj:getClassName() ~= "TSStatic" then
    return false -- Early return if the object is not a TSStatic.
  end
  for _, anchorName in ipairs(obj:getAnchorNames()) do -- Check if any anchor points have the nail prefix.
    if anchorName:sub(1, 5) == anchorPrefixStr .. '.' then
      return true
    end
  end
  return false
end

-- Validate and collect tool-compatible TSStatic objects from selection.
local function validateToolCompatibleTSStatics(collection)
  local validComponents, invalidCount, ctr = {}, 0, 1
  for i = 1, #collection do
    local obj = scenetree.findObjectById(collection[i])
    if validateToolCompatibleTSStatic(obj) then
      validComponents[ctr] = { obj = obj, meshName = obj.shapeName }
      ctr = ctr + 1
    else
      invalidCount = invalidCount + 1
    end
  end
  if invalidCount > 0 then
    log("W", logtag, string.format("Skipped %d TSStatic objects that don't have tool-compatible anchor points (nail.*)", invalidCount))
  end
  return validComponents
end

-- Analyse distribution pattern for a component group (base + variations).
local function analyseComponentGroupDistribution(components, baseMeshPath)
  -- Filter components to only include this base mesh and its variations.
  local groupComponents = {}
  for i = 1, #components do
    local comp = components[i]
    local fileName = comp.meshName:match("^.+/(.+)$") or comp.meshName:match("^(.+)$")
    if comp.meshName == baseMeshPath then
      table.insert(groupComponents, comp)
    elseif fileName:lower():find("var") then -- Check if this is a variation of the base mesh.
      local baseFileName = baseMeshPath:match("^.+/(.+)$") or baseMeshPath:match("^(.+)$")
      local baseName = fileName:match("(.+)_var") .. ".dae"
      if baseName == baseFileName then
        table.insert(groupComponents, comp)
      end
    end
  end
  local numGroupComponents = #groupComponents
  if numGroupComponents < 2 then
    return false, 1.0 -- Single component, default to round robin.
  end

  -- Get all the unique mesh paths in this group.
  local uniquePaths = {}
  local pathCounts = {}
  for i = 1, #groupComponents do
    local meshPath = groupComponents[i].meshName
    if not pathCounts[meshPath] then
      pathCounts[meshPath] = 0
      table.insert(uniquePaths, meshPath)
    end
    pathCounts[meshPath] = pathCounts[meshPath] + 1
  end
  local numUniquePaths = #uniquePaths

  -- Check if we have the single mesh type.
  if numUniquePaths == 1 then
    return false, 1.0
  end

  -- Analyze sequence to determine if it's round robin or random.
  local sequence = {}
  for i = 1, numGroupComponents do
    local meshPath = groupComponents[i].meshName
    local idx = (i - 1) % numUniquePaths + 1
    if not sequence[idx] then
      sequence[idx] = meshPath
    elseif sequence[idx] ~= meshPath then
      local totalWeight, total = 0, numGroupComponents
      for _, count in pairs(pathCounts) do -- Not round robin, must be random - calculate average weight.
        totalWeight = totalWeight + (count / total)
      end
      local avgWeight = totalWeight / numUniquePaths
      return true, avgWeight
    end
  end

  -- Round robin detected.
  return false, 1.0
end

-- Reconstruct assembly kit from selected TSStatic objects.
local function reconstructAssemblyKit(components)
  -- Count occurrences of each mesh path and group components.
  local meshPathCounts, uniqueMeshPaths, meshPathToComponents = {}, {}, {}
  for i = 1, #components do
    local comp = components[i]
    local meshPath = comp.meshName
    if not meshPathCounts[meshPath] then
      meshPathCounts[meshPath] = 0
      uniqueMeshPaths[#uniqueMeshPaths + 1] = meshPath
      meshPathToComponents[meshPath] = {}
    end
    meshPathCounts[meshPath] = meshPathCounts[meshPath] + 1
    table.insert(meshPathToComponents[meshPath], comp)
  end

  -- Build assembly kit structure similar to getAssemblyKit
  local assemblyKit = {}
  local rootMeshPath = nil

  for i = 1, #uniqueMeshPaths do
    local meshPath = uniqueMeshPaths[i]
    local fileName = meshPath:match("^.+/(.+)$") or meshPath:match("^(.+)$")

    -- Check if this is the root mesh (contains "root" in filename).
    if fileName:lower():find("root") then
      -- Prefer root meshes without "var" in the name
      if not rootMeshPath or not fileName:lower():find("var") then
        rootMeshPath = meshPath
      end
    end

    -- Analyse distribution pattern for this component group.
    local isRandom, distributionData = analyseComponentGroupDistribution(components, meshPath)

    -- Create kit entry
    assemblyKit[i] = {
      id = Engine.generateUUID(),
      meshPath = meshPath,
      fileName = fileName,
      isRandom = isRandom,
      randomWeight = isRandom and distributionData or 1.0,
      components = meshPathToComponents[meshPath] -- Store original components for reference
    }
  end

  -- If no root mesh found, use the first rigid mesh as root (same logic as buildMolecule)
  if not rootMeshPath then
    if #uniqueMeshPaths > 0 then
      rootMeshPath = uniqueMeshPaths[1]
      log("W", logtag, string.format("No mesh with 'root' in name found. Using first rigid mesh as root: %s", rootMeshPath))
    else
      log("W", logtag, "No rigid meshes found.")
      return nil
    end
  end

  log("I", logtag, string.format("Reconstructed assembly kit with %d unique meshes, root: %s", #assemblyKit, rootMeshPath or "none"))

  return assemblyKit, rootMeshPath
end

-- Set assembly spline properties.
local function setAssemblySplineProperties(spline, components)
  -- Set basic properties.
  spline.name = spline.name .. " [Imported]"
  spline.isDirty = true

  -- Set default properties for imported assembly spline.
  spline.spacing = 10.0
  spline.verticalOffset = 0.0
  spline.normalMode = 2
  spline.sag = 0.0
  spline.isConformToTerrain = false
  spline.preRot = 0
  spline.jitterForward = 0.0
  spline.jitterRight = 0.0
  spline.jitterUp = 0.0
  spline.splineRandomSeed = 0

  -- Initialize empty kit and molecule data (to be set later by user).
  spline.kitFolderPath = nil
  spline.meshKit = {}
  spline.moleculeDescription = {}
  spline.rigidEnabledStates = {}
  spline.bridgeEnabledStates = {}
end

-- Determines the prerotation for a single mesh instance.
local function getPrerotationForInstance(ordered, idx)
  if idx <= 0 or idx > #ordered then
    return 0 -- If there is no component, default to 0.
  end

  -- Extract Y rotation (around Z-axis) from the quaternion.
  local rot = ordered[idx].obj:getRotation()
  tmpRot.x, tmpRot.y, tmpRot.z, tmpRot.w = rot.x, rot.y, rot.z, rot.w
  local euler = tmpRot:toEulerYXZ()
  local yaw = euler.z % twoPi -- Normalise to 0-2pi range.

  -- Map to 0-3 rotation index (0°, 90°, 180°, 270°).
  if yaw < piOver4 or yaw >= 7 * piOver4 then
    return 0 -- 0°: aligned with world X.
  elseif yaw >= piOver4 and yaw < 3 * piOver4 then
    return 1 -- 90°: rotated clockwise.
  elseif yaw >= 3 * piOver4 and yaw < 5 * piOver4 then
    return 2 -- 180°: opposite.
  else
    return 3 -- 270°: rotated counter-clockwise.
  end
end

-- Determines the prerotation for a component type by consensus.
local function getPrerotationForComponent(ordered, meshPath)
  if not meshPath then
    return 0 -- If there is no mesh path, default to 0.
  end

  -- Count the number of votes for each pre-rotation.
  votes[0], votes[1], votes[2], votes[3] = 0, 0, 0, 0
  for i = 1, #ordered do
    if ordered[i].meshName == meshPath then
      local prerot = getPrerotationForInstance(ordered, i)
      votes[prerot] = votes[prerot] + 1
    end
  end

  -- Find the pre-rotation value with the most votes.
  local v0, v1, v2, v3 = votes[0], votes[1], votes[2], votes[3]
  if v1 > v0 and v1 > v2 and v1 > v3 then
    return 1
  elseif v2 > v0 and v2 > v1 and v2 > v3 then
    return 2
  elseif v3 > v0 and v3 > v1 and v3 > v2 then
    return 3
  else
    return 0 -- Default to 0 if all are equal or 0 has the most votes.
  end
end

-- Calculate spline spacing from ordered positions and box dimensions.
local function calculateSplineSpacing(ordered, rootMeshPath)
  -- Collect the positions, in order.
  table.clear(orderedPositions)
  for i = 1, #ordered do
    orderedPositions[i] = ordered[i].obj:getPosition()
  end

  -- Calculate the distances between each consecutive position.
  table.clear(distances)
  for i = 1, #orderedPositions - 1 do
    distances[i] = orderedPositions[i]:distance(orderedPositions[i + 1])
  end

  -- Sort the distances and remove the smallest and largest.
  table.sort(distances); table.clear(filteredDistances)
  local ctr = 1
  for i = 2, #distances - 1 do
    filteredDistances[ctr] = distances[i]
    ctr = ctr + 1
  end

  -- Calculate the average distance.
  local filteredAvgDist, numFilteredDistances = 0.0, #filteredDistances
  for i = 1, numFilteredDistances do
    filteredAvgDist = filteredAvgDist + filteredDistances[i]
  end

  -- Handle case where filtering removed all distances.
  if numFilteredDistances > 0 then
    filteredAvgDist = filteredAvgDist / numFilteredDistances
  else
    filteredAvgDist = #distances > 0 and distances[1] or 1.0 -- Use first distance if available, otherwise default spacing.
  end

  -- Get box dimensions for the root mesh using shared utility.
  local extents = util.getMeshBox(rootMeshPath).extents

  return filteredAvgDist - extents.x * 2.0 -- Use length for spacing calculation.
end

-- Determine if spline should be flipped based on binormal alignment.
local function shouldFlipSplineDirection(ordered, rootMeshPath)
  local alignmentCount = 0
  local totalCount = 0

  -- Check each root mesh to see if its binormal aligns with spline tangent.
  for i = 1, #ordered do
    if ordered[i].meshName == rootMeshPath then
      totalCount = totalCount + 1

      -- Calculate expected spline tangent at this position.
      local currentPos = ordered[i].obj:getPosition()
      if i == 1 and #ordered > 1 then -- First point: use direction to next point.
        local nextPos = ordered[i + 1].obj:getPosition()
        tangent:setSub2(nextPos, currentPos)
      elseif i == #ordered and #ordered > 1 then -- Last point: use direction from previous point.
        local prevPos = ordered[i - 1].obj:getPosition()
        tangent:setSub2(currentPos, prevPos)
      elseif #ordered > 2 then -- Middle point: use smoothed direction.
        local prevPos = ordered[i - 1].obj:getPosition()
        local nextPos = ordered[i + 1].obj:getPosition()
        tangent:setSub2(nextPos, prevPos)
      else
        break -- Single component, can't determine direction.
      end
      tangent:normalize()

      -- Calculate expected binormal (cross product of tangent and normal).
      expectedBinormal:setCross(tangent, globalUp)
      expectedBinormal:normalize()

      -- Get actual binormal from root mesh rotation.
      local meshRot = ordered[i].obj:getRotation()
      tmpRot.x, tmpRot.y, tmpRot.z, tmpRot.w = meshRot.x, meshRot.y, meshRot.z, meshRot.w
      actualBinormal:set(0, 1, 0) -- Start with Y-axis (binormal in mesh space).
      actualBinormal:setRotate(tmpRot, actualBinormal)
      actualBinormal:normalize()

      -- Check if binormals are aligned (dot product > 0).
      if expectedBinormal:dot(actualBinormal) > 0 then
        alignmentCount = alignmentCount + 1
      end
    end
  end

  -- If less than half are aligned, flip the spline.
  return totalCount > 0 and alignmentCount < totalCount * 0.5
end

-- Converts the components to an assembly spline.
local function convertComponentsToAssemblySpline(ordered, assemblyKit, rootMeshPath, components)
  -- Collect positions and create widths array.
  local positions, widths = {}, {}
  for i = 1, #ordered do
    local comp = ordered[i]
    positions[i] = comp.obj:getPosition()
    widths[i] = 10.0 -- Default width.
  end

  -- Simplify the positions using the RDP algorithm.
  rdp.simplifyNodes(positions, rdpLightTolerance)

  -- Filter out nodes which are too close in the XY-plane.
  local filteredPositions = util.filterClosePointsXY(positions, 5.0)

  -- Create a new assembly spline.
  local assemblySplines = splineMgr.getAssemblySplines()
  splineMgr.addNewAssemblySpline()
  local spline = assemblySplines[#assemblySplines]
  setAssemblySplineProperties(spline, ordered) -- Set the core spline properties.
  spline.nodes = filteredPositions -- Set the spline primary geometry.
  spline.widths = widths
  spline.nmls = {}
  for i = 1, #filteredPositions do
    spline.nmls[i] =  vec3(0, 0, 1) -- Use global Z-axis.
  end

  -- Determine if we should flip the spline direction.
  if shouldFlipSplineDirection(ordered, rootMeshPath) then
    geom.flipSplineDirection(spline)
  end

  -- Calculate and set spacing.
  local spacing = calculateSplineSpacing(ordered, rootMeshPath)
  spline.spacing = spacing

  -- Calculate and set pre-rotation for the root mesh.
  local rootPreRot = getPrerotationForComponent(ordered, rootMeshPath)
  spline.preRot = rootPreRot

  -- Set the reconstructed assembly kit and build molecule.
  if assemblyKit and #assemblyKit > 0 then
    -- Mark this as an imported spline and store the import data.
    spline.isImported = true
    spline.importedKit = {
      originalComponents = components,
      reconstructedKit = assemblyKit,
      rootMeshPath = rootMeshPath,
      sourceMeshPaths = {}
    }

    -- Store the original mesh paths for reference.
    for i = 1, #components do
      spline.importedKit.sourceMeshPaths[i] = components[i].meshName
    end

    -- Set the mesh kit and build molecule.
    spline.meshKit = assemblyKit
    spline.kitFolderPath = rootMeshPath and rootMeshPath:match("^(.+)/[^/]+$") or nil
    spline.moleculeDescription = mol.buildMolecule(assemblyKit, spline) -- Build molecule from the reconstructed kit.

    log("I", logtag, "Successfully imported assembly spline with kit data.")
  end
end

-- Undo callback for the import operation.
local function convertTSStatics2AssemblySpline_Undo(data)
  if splineMgr.transSplineEditUndo then
    splineMgr.transSplineEditUndo(data)
  end
  if data.deletedTSStatics then
    restoreTSStatics(data.deletedTSStatics)
  end

  -- Update the spline map.
  local assemblySplines = splineMgr.getAssemblySplines()
  util.computeIdToIdxMap(assemblySplines, splineMgr.getSplineMap())

  editor.refreshSceneTreeWindow()
end

-- Redo callback for the import operation.
local function convertTSStatics2AssemblySpline_Redo(data)
  if splineMgr.transSplineEditRedo then
    splineMgr.transSplineEditRedo(data)
  end
  if data.deletedTSStatics then
    deleteTSStaticsFromBackup(data.deletedTSStatics)
  end

  -- Update the spline map.
  local assemblySplines = splineMgr.getAssemblySplines()
  util.computeIdToIdxMap(assemblySplines, splineMgr.getSplineMap())

  editor.refreshSceneTreeWindow()
  be:reloadCollision() -- Reload collision mesh.
end

-- Convert the selected TSStatic objects to an assembly spline.
local function convertTSStatics2AssemblySpline(collection)
  if not collection or #collection == 0 then
    log("W", logtag, "No TSStatic objects selected.")
    return
  end

  -- Create a backup of the current spline state.
  local preState = splineMgr.deepCopyAssemblySplineState()

  -- Validate and collect tool-compatible TSStatic objects from selection
  local components = validateToolCompatibleTSStatics(collection)

  if #components < 2 then
    log("W", logtag, "Need at least two tool-compatible TSStatic objects to form an assembly spline.")
    return
  end

  -- Reconstruct assembly kit from components.
  local assemblyKit, rootMeshPath = reconstructAssemblyKit(components)
  if not assemblyKit or #assemblyKit == 0 then
    log("W", logtag, "Failed to reconstruct assembly kit from components.")
    return
  end

  -- Filter components to only include root mesh and its variations for polyline fitting.
  local rootComponents = {}
  for i = 1, #components do
    local comp = components[i]
    local fileName = comp.meshName:match("^.+/(.+)$") or comp.meshName:match("^(.+)$")
    if comp.meshName == rootMeshPath then
      table.insert(rootComponents, comp)
    elseif fileName:lower():find("var") then -- Check if this is a variation of the root mesh.
      local rootFileName = rootMeshPath:match("^.+/(.+)$") or rootMeshPath:match("^(.+)$")
      local baseName = fileName:match("(.+)_var") .. ".dae"
      if baseName == rootFileName then
        table.insert(rootComponents, comp)
      end
    end
  end

  -- Fit the root components to a polyline.
  local ordered = fit.fitPoly(rootComponents)
  if not ordered or #ordered < 2 then
    log("W", logtag, "Failed to fit root components to a polyline. Need at least 2 root components.")
    return
  end

  -- Backup the TSStatic objects.
  local tsStaticBackup = backupTSStatics(components)

  -- Convert to assembly spline with kit and molecule.
  convertComponentsToAssemblySpline(ordered, assemblyKit, rootMeshPath, components)

  -- Update the spline map to ensure undo operations can find the imported spline.
  local assemblySplines = splineMgr.getAssemblySplines()
  util.computeIdToIdxMap(assemblySplines, splineMgr.getSplineMap())

  -- Delete used TSStatic objects and clean up parent groups.
  for i = 1, #components do
    local obj = components[i].obj
    if obj and Sim.upcast(obj) then
      obj:delete()
    end
  end
  cleanupEmptyGroups(components)

  -- Reload collision mesh.
  be:reloadCollision()

  -- Commit the action to the history.
  editor.history:commitAction(
    "Convert TSStatics to Assembly Spline",
    { old = preState, new = splineMgr.deepCopyAssemblySplineState(), deletedTSStatics = tsStaticBackup },
    convertTSStatics2AssemblySpline_Undo,
    convertTSStatics2AssemblySpline_Redo,
    true
  )

  editor.refreshSceneTreeWindow()

  -- Set flag for delayed update.
  isImportDelayUpdate = true
end

-- Import an assembly spline from the given selection polygon.
local function importFromPolygon(polygon)
  local meshesInPolygon = {}
  for _, meshName in pairs(scenetree.findClassObjects("TSStatic")) do
    local obj = scenetree.findObject(meshName)
    if obj then
      local pos = obj:getPosition()
      if pos:inPolygon(polygon) then
        table.insert(meshesInPolygon, obj:getID())
      end
    end
  end
  convertTSStatics2AssemblySpline(meshesInPolygon)
end


-- Public interface.
M.handleDelayedSplineUpdates =                          handleDelayedSplineUpdates

M.validateToolCompatibleTSStatic =                      validateToolCompatibleTSStatic

M.convertTSStatics2AssemblySpline =                     convertTSStatics2AssemblySpline
M.importFromPolygon =                                   importFromPolygon

return M