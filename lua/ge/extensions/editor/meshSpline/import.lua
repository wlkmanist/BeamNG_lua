-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local rdpLightTolerance = 0.5

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}
local logtag = "meshSpline.import"


-- Module dependencies.
local splineMgr = require('editor/meshSpline/splineMgr')
local rdp = require('editor/toolUtilities/rdp')
local fit = require('editor/toolUtilities/fitPoly')
local util = require('editor/toolUtilities/util')

-- Module constants.
local abs = math.abs
local scaleVec = vec3(1, 1, 1)

-- Module state.
local isImportDelayUpdate = false
local importDelayFrameCount = 0
local meshRot = quat()
local tangent, meshXAxis = vec3(), vec3()


-- Handle delayed spline updates.
-- [We need to wait until the collision mesh has been updated, then update the spline which was created by the import.]
local function handleDelayedSplineUpdates()
  if isImportDelayUpdate then
    importDelayFrameCount = importDelayFrameCount + 1
    if importDelayFrameCount >= 2 then
      local meshSplines = splineMgr.getMeshSplines()
      if #meshSplines > 0 then
        local spline = meshSplines[#meshSplines]
        spline.isDirty = true
      end
      isImportDelayUpdate = false
      importDelayFrameCount = 0
    end
  end
end

-- Analyses the mesh paths in a spline sequence, identifying patterns and the presence of caps.
local function analyseMeshSequence(meshPaths)
  if #meshPaths == 0 then
    return nil, nil, false, nil, false, nil -- Early return if no mesh paths.
  end

  -- Count occurrences of first and last mesh paths.
  local first, last = meshPaths[1], meshPaths[#meshPaths]
  local isStartCap, isEndCap, startCapPath, endCapPath = false, false, nil, nil
  local firstCount, lastCount = 0, 0
  for i = 1, #meshPaths do
    if meshPaths[i] == first then
      firstCount = firstCount + 1
    end
    if meshPaths[i] == last then
      lastCount = lastCount + 1
    end
  end

  -- Identify start cap: appears only once at the beginning, OR appears twice total (start + end).
  if firstCount == 1 or (firstCount == 2 and first == last) then
    isStartCap, startCapPath = true, first
  end

  -- Identify end cap: appears only once at the end, OR appears twice total (start + end).
  if lastCount == 1 or (lastCount == 2 and first == last) then
    isEndCap, endCapPath = true, last
  end

  -- Remove caps from bulk before doing distribution analysis (these are possible outliers).
  local mainMeshes, ctr = {}, 1
  local startIdx = isStartCap and 2 or 1
  local endIdx = isEndCap and (#meshPaths - 1) or #meshPaths
  for i = startIdx, endIdx do
    mainMeshes[ctr] = meshPaths[i]
    ctr = ctr + 1
  end

  -- Get a list of all the unique mesh paths in the collection.
  local uniquePaths = {}
  for _, path in ipairs(mainMeshes) do -- Count the number of times each mesh path appears.
    uniquePaths[path] = (uniquePaths[path] or 0) + 1
  end
  local uniqueList = {}
  for path in pairs(uniquePaths) do -- Create a list of unique mesh paths.
    table.insert(uniqueList, path)
  end

  -- Determine which type of distribution we have.
  local meshType, meshInfo = nil, nil
  if #uniqueList == 1 then
    meshType, meshInfo = 'single', uniqueList[1] -- The selection contains a single variant of a mesh.
  else
    -- Determine if we have a round robin distribution.
    local sequence = {}
    for i, path in ipairs(mainMeshes) do
      local idx = (i - 1) % #uniqueList + 1
      if not sequence[idx] then
        sequence[idx] = path
      elseif sequence[idx] ~= path then
        sequence = nil
        break
      end
    end
    if sequence then -- Round robin identified.
      meshType, meshInfo = 'round robin', sequence
    else -- Fallback to random distribution.
      meshType, meshInfo = 'random', {}
      local total = #mainMeshes
      for path, count in pairs(uniquePaths) do
        meshInfo[path] = count / total
      end
    end
  end

  return meshType, meshInfo, isStartCap, startCapPath, isEndCap, endCapPath
end

-- Sets the mesh box data in the selected spline.
local function setMeshSplineBoxData(path, spline)
  -- Create a temporary mesh, so we can extract its world box and extents data.
  local obj = createObject('TSStatic')
  obj:setField('shapeName', 0, path)
  obj:setField('decalType', 0, 'None')
  obj:registerObject('Mesh Under Audition [temporary]')
  scenetree.MissionGroup:addObject(obj)
  obj:setPosRot(0.0, 0.0, 2000, 0, 0, 0, 1)
  obj.scale = scaleVec
  obj.cansave = false
  local worldBox = obj:getWorldBox()
  local center = obj:getPosition()
  local minExtents, maxExtents = worldBox.minExtents, worldBox.maxExtents -- Get the extents of the temporary mesh.
  local box = obj:getObjBox()
  local extents = box:getExtents()
  obj:delete() -- Delete the temporary mesh, now that we have the data we need.

  -- Set the extents data in the selected spline.
  spline.boxXLeft_Center, spline.boxXRight_Center = center.x - minExtents.x, maxExtents.x - center.x
  spline.boxYLeft_Center, spline.boxYRight_Center = center.y - minExtents.y, maxExtents.y - center.y
  spline.boxZLeft_Center, spline.boxZRight_Center = center.z - minExtents.z, maxExtents.z - center.z
  spline.extentsL_Center, spline.extentsW_Center, spline.extentsH_Center = extents.x, extents.y, extents.z
end

-- Determines prerotation for any mesh by comparing its orientation to the spline tangent at its position.
local function getPrerotationForMesh(ordered, idx, splineTangent)
  if idx <= 0 or idx > #ordered then
    return 0 -- If there is no component, default to 0.
  end

  -- Get the mesh's local X-axis in world space.
  local mesh = ordered[idx].obj
  local rot = mesh:getRotation()
  meshRot.x, meshRot.y, meshRot.z, meshRot.w = rot.x, rot.y, rot.z, rot.w
  meshXAxis:set(1, 0, 0)
  meshXAxis:setRotate(meshRot, meshXAxis)

  -- Compare spline tangent with mesh X-axis to determine rotation.
  local dotProduct = splineTangent:dot(meshXAxis)
  if abs(dotProduct) > 0.707 then -- Tangent is roughly aligned with mesh X-axis
    return dotProduct > 0 and 0 or 2 -- 0° or 180°
  else -- Tangent is roughly perpendicular to mesh X-axis.
    local crossProduct = splineTangent:cross(meshXAxis)
    return crossProduct.z > 0 and 1 or 3 -- 90° or 270°
  end
end

-- Determines prerotation for start/end caps by comparing mesh orientation to spline tangent.
local function getPrerotationForCap(ordered, isStartCap, isEndCap)
  if #ordered < 2 then
    return 0, 0 -- Need at least 2 points to compute tangent.
  end

  -- Compute start cap pre-rotation if needed.
  local startCapRot = 0
  if isStartCap then
    local startPos = ordered[1].obj:getPosition()
    local nextPos = ordered[2].obj:getPosition()
    tangent:setSub2(nextPos, startPos) -- Compute tangent at start (direction from start to next point).
    tangent:normalize()
    startCapRot = getPrerotationForMesh(ordered, 1, tangent)
  end

  -- Compute end cap pre-rotation if needed.
  local endCapRot = 0
  if isEndCap then
    local endPos = ordered[#ordered].obj:getPosition()
    local prevPos = ordered[#ordered - 1].obj:getPosition()
    tangent:setSub2(endPos, prevPos) -- Compute tangent at end (direction from previous point to end).
    tangent:normalize()
    endCapRot = getPrerotationForMesh(ordered, #ordered, tangent)
  end

  return startCapRot, endCapRot
end

-- Helper to determine prerotation for a component type by consensus, using proper spline tangent analysis.
local function getPrerotationForComponent(ordered, meshPath)
  if not meshPath then
    return 0 -- If there is no mesh path, default to 0.
  end

  -- Count the number of votes for each pre-rotation.
  local votes = { 0, 0, 0, 0 } -- [votes for 0°, 90°, 180°, 270°].
  for i = 1, #ordered do
    if ordered[i].meshName == meshPath then
      -- Compute the spline tangent at this mesh's position.
      local meshPos = ordered[i].obj:getPosition()
      local prevPos, nextPos = nil, nil

      -- Find the previous and next positions for tangent calculation.
      if i == 1 then -- First mesh: tangent from first to second.
        prevPos = meshPos
        nextPos = ordered[2].obj:getPosition()
      elseif i == #ordered then -- Last mesh: tangent from second-to-last to last.
        prevPos = ordered[#ordered - 1].obj:getPosition()
        nextPos = meshPos
      else -- Middle mesh: tangent from previous to next.
        prevPos = ordered[i - 1].obj:getPosition()
        nextPos = ordered[i + 1].obj:getPosition()
      end

      -- Compute tangent at this mesh's position.
      tangent:setSub2(nextPos, prevPos)
      tangent:normalize()

      -- Get pre-rotation for this mesh instance.
      local prerot = getPrerotationForMesh(ordered, i, tangent)
      local idx = prerot + 1 -- Convert 0-based to 1-based index.
      votes[idx] = votes[idx] + 1
    end
  end

  -- Return the pre-rotation with the most votes.
  local maxVotes, bestPrerot = 0, 0
  for i = 1, 4 do
    if votes[i] > maxVotes then
      maxVotes = votes[i]
      bestPrerot = i - 1 -- Convert back to 0-based.
    end
  end

  return bestPrerot
end

-- Determines the pre-rotation values for each component type.
local function determineComponentPrerotations(ordered, isStartCap, isEndCap)
  -- Get all unique mesh paths from the ordered collection.
  local uniqueMeshes = {}
  for i = 1, #ordered do
    local meshPath = ordered[i].meshName
    if not uniqueMeshes[meshPath] then
      uniqueMeshes[meshPath] = true
      table.insert(uniqueMeshes, meshPath)
    end
  end

  -- Determine the pre-rotation for each component type.
  local rotMain, rotVar1, rotVar2, rotVar3, rotStartCap, rotEndCap = 0, 0, 0, 0, 0, 0
  if #uniqueMeshes >= 1 then
    rotMain = getPrerotationForComponent(ordered, uniqueMeshes[1]) -- Get the pre-rotation for the main mesh.
  end
  if #uniqueMeshes >= 2 then
    rotVar1 = getPrerotationForComponent(ordered, uniqueMeshes[2]) -- Get the pre-rotation for the first variation.
  end
  if #uniqueMeshes >= 3 then
    rotVar2 = getPrerotationForComponent(ordered, uniqueMeshes[3]) -- Get the pre-rotation for the second variation.
  end
  if #uniqueMeshes >= 4 then
    rotVar3 = getPrerotationForComponent(ordered, uniqueMeshes[4]) -- Get the pre-rotation for the third variation.
  end

  -- Use the new cap prerotation logic for start/end caps.
  if isStartCap or isEndCap then
    rotStartCap, rotEndCap = getPrerotationForCap(ordered, isStartCap, isEndCap)
  end

  return rotMain, rotVar1, rotVar2, rotVar3, rotStartCap, rotEndCap
end

-- Converts a list of ordered TSStatic objects into a mesh spline.
local function convertComponentsToMeshSpline(components)
  -- Analyse the mesh sequence to determine what the mesh spline properties should be.
  local meshPaths = {}
  for i = 1, #components do -- Create an array of mesh paths.
    meshPaths[i] = components[i].meshName
  end
  local meshType, meshInfo, isStartCap, startCapPath, isEndCap, endCapPath = analyseMeshSequence(meshPaths)

  -- Collect the positions and widths of all the ordered objects.
  local positions, widths = {}, {}
  for i = 1, #components do
    local comp = components[i]
    comp.obj = Sim.upcast(comp.obj)
    local pos = vec3(comp.obj:getPosition())
    positions[i], widths[i] = pos, 10.0 -- Use dummy widths.
  end

  -- Simplify the positions using RDP, up to some light tolerance.
  rdp.simplifyNodes(positions, rdpLightTolerance)

  -- Filter out nodes too close in XY-plane, up to some tolerance.
  local filteredPositions = util.filterClosePointsXY(positions, 5.0)

  -- Create a new mesh spline.
  local meshSplines = splineMgr.getMeshSplines()
  splineMgr.addNewMeshSpline()
  local spline = meshSplines[#meshSplines]
  spline.name = spline.name .. " [Imported]"
  spline.nodes = filteredPositions
  spline.widths = widths
  spline.nmls = {}
  for _ = 1, #filteredPositions do
    table.insert(spline.nmls, vec3(0, 0, 1)) -- Default to global up.
  end
  spline.isDirty = true

  -- Set start cap properties.
  spline.isStartCap = isStartCap
  if isStartCap and startCapPath then
    spline.startCapMeshPath = startCapPath
    spline.startCapMeshName = startCapPath:match("([^/]+)$")
  end

  -- Set end cap properties.
  spline.isEndCap = isEndCap
  if isEndCap and endCapPath then
    spline.endCapMeshPath = endCapPath
    spline.endCapMeshName = endCapPath:match("([^/]+)$")
  end

  -- Set the mesh sequence (round robin or random).
  if meshType == "round robin" then
    spline.isAliasRoundRobin = true
    local meshes = meshInfo

    -- Center mesh + aliases.
    spline.centerMeshPath = meshes[1]
    spline.centerMeshName = meshes[1]:match("([^/]+)$")

    setMeshSplineBoxData(meshes[1], spline)

    if #meshes >= 2 then
      spline.isAlias1 = true
      spline.alias1MeshPath = meshes[2]
      spline.alias1MeshName = meshes[2]:match("([^/]+)$")
    end
    if #meshes >= 3 then
      spline.isAlias2 = true
      spline.alias2MeshPath = meshes[3]
      spline.alias2MeshName = meshes[3]:match("([^/]+)$")
    end
    if #meshes >= 4 then
      spline.isAlias3 = true
      spline.alias3MeshPath = meshes[4]
      spline.alias3MeshName = meshes[4]:match("([^/]+)$")
    end

  elseif meshType == "single" then
    spline.isAliasRoundRobin = false
    spline.centerMeshPath = meshInfo  -- This will just be a single path string in this case.
    spline.centerMeshName = meshInfo:match("([^/]+)$")

    setMeshSplineBoxData(meshInfo, spline)

  elseif meshType == "random" then
    spline.isAliasRoundRobin = false

    -- Sort meshes by frequency, in descending order.
    local sortedMeshes = {}
    for meshPath, freq in pairs(meshInfo) do
      table.insert(sortedMeshes, { path = meshPath, freq = freq })
    end
    table.sort(sortedMeshes, function(a, b) return a.freq > b.freq end)

    -- Assign center mesh and aliases.
    if #sortedMeshes >= 1 then
      spline.centerMeshPath = sortedMeshes[1].path
      spline.centerMeshName = sortedMeshes[1].path:match("([^/]+)$")
      spline.mainRandomWeight = sortedMeshes[1].freq

      setMeshSplineBoxData(sortedMeshes[1].path, spline)
    end
    if #sortedMeshes >= 2 then
      spline.isAlias1 = true
      spline.alias1MeshPath = sortedMeshes[2].path
      spline.alias1MeshName = sortedMeshes[2].path:match("([^/]+)$")
      spline.alias1RandomWeight = sortedMeshes[2].freq
    end
    if #sortedMeshes >= 3 then
      spline.isAlias2 = true
      spline.alias2MeshPath = sortedMeshes[3].path
      spline.alias2MeshName = sortedMeshes[3].path:match("([^/]+)$")
      spline.alias2RandomWeight = sortedMeshes[3].freq
    end
    if #sortedMeshes >= 4 then
      spline.isAlias3 = true
      spline.alias3MeshPath = sortedMeshes[4].path
      spline.alias3MeshName = sortedMeshes[4].path:match("([^/]+)$")
      spline.alias3RandomWeight = sortedMeshes[4].freq
    end
  end

  -- Calculate the spline spacing parameter.
  local orderedPositions = {}
  for i = 1, #components do -- Create an array of ordered positions.
    orderedPositions[i] = components[i].obj:getPosition()
  end
  local distances = {}
  for i = 1, #orderedPositions - 1 do -- Calculate the distances between each pair of ordered positions.
    distances[i] = orderedPositions[i]:distance(orderedPositions[i + 1])
  end
  table.sort(distances)
  local filteredDistances = {}
  for i = 2, #distances - 1 do -- Remove largest and smallest distances (outliers).
    table.insert(filteredDistances, distances[i])
  end
  local filteredAvgDist = 0.0
  for i = 1, #filteredDistances do -- Calculate the average distance.
    filteredAvgDist = filteredAvgDist + filteredDistances[i]
  end
  filteredAvgDist = filteredAvgDist / #filteredDistances
  local boxLength = spline.extentsL_Center
  if spline.rot == 1 or spline.rot == 3 then -- If the spline is rotated 90°, use the width of the box. Otherwise, use the length.
    boxLength = spline.extentsW_Center
  end
  spline.spacing = filteredAvgDist - boxLength -- The spacing parameter is the average distance minus the box length. This is used to ensure that the spline is evenly spaced.

  -- Determine prerotations for each component.
  spline.rot, spline.alias1Rot, spline.alias2Rot, spline.alias3Rot, spline.startCapRot, spline.endCapRot =
    determineComponentPrerotations(components, isStartCap, isEndCap)
end

-- Undo callback for the import operation.
local function convertTSStatics2MeshSpline_Undo(data)
  splineMgr.removeAllMeshSplines(true) -- Remove current splines.
  splineMgr.setMeshSplines(data.old) -- Restore the spline state in the tool, to what it was before the conversion.

  -- Update the spline map after restoring the old state.
  local meshSplines = splineMgr.getMeshSplines()
  util.computeIdToIdxMap(meshSplines, splineMgr.getSplineMap())

  if data.deletedTSStatics then -- Recreate the deleted TSStatic objects
    for _, entry in ipairs(data.deletedTSStatics) do
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
  editor.refreshSceneTreeWindow()
end

-- Redo callback for the import operation.
local function convertTSStatics2MeshSpline_Redo(data)
  splineMgr.removeAllMeshSplines(true) -- Remove current splines.
  splineMgr.setMeshSplines(data.new) -- Restore the spline state in the tool, to what it was after the conversion.

  -- Update the spline map after restoring the new state.
  local meshSplines = splineMgr.getMeshSplines()
  util.computeIdToIdxMap(meshSplines, splineMgr.getSplineMap())

  if data.deletedTSStatics then -- Delete the previously restored TSStatic objects (if any still exist)
    for _, entry in ipairs(data.deletedTSStatics) do
      if entry.name then
        local obj = scenetree.findObject(entry.name)
        if obj and obj:getClassName() == "TSStatic" then
          obj:delete()
        end
      end
    end
  end
  editor.refreshSceneTreeWindow()

  -- Reload collision mesh
  be:reloadCollision()
end

-- Convert the selected TSStatic objects to a mesh spline.
local function convertTSStatics2MeshSpline(collection)
  if not collection or #collection == 0 then
    log("W", logtag, "No TSStatic objects selected.")
    return -- Early return if no TSStatic objects are selected.
  end

  -- Create a backup of the current spline state.
  local preState = splineMgr.deepCopyMeshSplineState()

  -- Collect valid TSStatic objects from selection.
  local components, ctr = {}, 1
  for i = 1, #collection do
    local obj = scenetree.findObjectById(collection[i])
    if obj and obj:getClassName() == "TSStatic" then -- Check if the object is a TSStatic.
      local shape = obj.shapeName
      if shape and shape ~= "" then
        components[ctr] = { obj = obj, meshName = shape }
        ctr = ctr + 1
      end
    end
  end
  if #components < 2 then
    log("W", logtag, "Need at least two valid TSStatic objects to form a mesh spline.")
    return -- Early return if there are less than two valid TSStatic objects.
  end

  -- Fit the TSStatic objects to a polyline.
  local ordered = fit.fitPoly(components)

  -- Check if all components are present.
  local originalIds = {}
  for i = 1, #components do -- Count the number of missing TSStatic objects.
    originalIds[components[i].obj:getID()] = true
  end
  local orderedIds = {}
  for i = 1, #ordered do -- Count the number of extra TSStatic objects.
    orderedIds[ordered[i].obj:getID()] = true
  end
  local missingCount = 0
  for id in pairs(originalIds) do -- Count the number of missing TSStatic objects.
    if not orderedIds[id] then
      missingCount = missingCount + 1
    end
  end
  local extraCount = 0
  for id in pairs(orderedIds) do -- Count the number of extra TSStatic objects.
    if not originalIds[id] then
      extraCount = extraCount + 1
    end
  end

  -- Backup the TSStatic objects.
  local tsStaticBackup = {}
  for i = 1, #ordered do
    local obj = ordered[i].obj
    if obj then
      local group = obj:getGroup()
      table.insert(tsStaticBackup, {
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

  -- Convert to mesh spline.
  convertComponentsToMeshSpline(ordered)

  -- Update the spline map to ensure undo operations can find the imported spline.
  local meshSplines = splineMgr.getMeshSplines()
  util.computeIdToIdxMap(meshSplines, splineMgr.getSplineMap())

  -- Delete used TSStatic objects, and clean up parent groups if now empty.
  local cleanedGroups = {}
  for i = 1, #ordered do
    local obj = ordered[i].obj
    if obj and Sim.upcast(obj) then
      local group = obj:getGroup()
      obj:delete()
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

  -- Commit the action to the history.
  editor.history:commitAction(
    "Convert TSStatics to Mesh Spline",
    { old = preState, new = splineMgr.deepCopyMeshSplineState(), deletedTSStatics = tsStaticBackup },
    convertTSStatics2MeshSpline_Undo,
    convertTSStatics2MeshSpline_Redo,
    true
  )

  editor.refreshSceneTreeWindow()

  -- Reload collision mesh
  be:reloadCollision()

  -- Set flag for delayed update. We need to wait until the collision mesh has been updated.
  isImportDelayUpdate = true
end

-- Import a mesh spline from the given selection polygon.
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
  convertTSStatics2MeshSpline(meshesInPolygon)
end


-- Public interface.
M.handleDelayedSplineUpdates =                          handleDelayedSplineUpdates

M.convertTSStatics2MeshSpline =                         convertTSStatics2MeshSpline
M.importFromPolygon =                                   importFromPolygon

return M