-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Module constants.
local toolPrefixStr = 'Drive Path Spline' -- The global prefix for the drive path spline tool.
local editModeKey = 'drivePathSplineEditMode' -- The edit mode key for this tool.

local minSplineDivisions = 10 -- The minimum number of subdivisions to use for a drive path spline.
local splitPartingDistance = 1.0 -- The distance by which to part a spline which is being split, at the split point.
local minImportSize = 10.0 -- The minimum size of a mesh spline to import.

local zExtra = 3.0 -- Extra z-offset to add to the ribbon points when vertical raycasting.
local zFloat = 0.15 -- The z-offset to add to the ribbon points, to avoid z-fighting with the terrain.

local vehShiftZ = 0.3 -- The z-offset to add to the vehicle when setting its position.

-- Default slider parameters for UI.
local defaultParams = {
  isFreeMode = true,
  delayTime = 0.0,
  aggression = 0.3,
  numLaps = 1,
  routeSpeed = 31.3,
  routeSpeedMode = 'off',
  isAvoidCars = true,
  isDriveInLane = true,
  isLoop = false,
  startingNode = 1,
  speedProfileMode = 0, -- 0 = off, 1 = speed targets, 2 = speed limits (script only).
}

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}
local logTag = 'drivePathSpline'

-- External modules.
local geom = require('editor/toolUtilities/geom')
local util = require('editor/toolUtilities/util')

-- Module constants.
local abs, min, max = math.abs, math.min, math.max
local globalUp = vec3(0, 0, 1)

-- Module state.
local drivePathSplines = {}
local splineMap = {}
local sceneVehicles, cachedVehiclePoses = {}, {}
local navGraphData = nil
local tmpPoint2I = Point2I(0, 0)
local tmp1 = vec3()
local tmpRot = quat()


-- Fetches the tool prefix string.
local function getToolPrefixStr() return toolPrefixStr end

-- Fetches the edit mode key.
local function getEditModeKey() return editModeKey end

-- Fetches the drive path splines.
local function getDrivePathSplines() return drivePathSplines end

-- Fetches the drive path spline map.
local function getSplineMap() return splineMap end

-- Sets the drive path spline with the given index.
local function setDrivePathSpline(spline, idx)
  drivePathSplines[idx] = spline
  spline.isDirty = true
end

-- Sets the drive path splines (full table).
local function setDrivePathSplines(splines)
  for i = 1, #splines do
    setDrivePathSpline(splines[i], i)
  end
end

-- Computes the active vehicles in the scene.
local function computeActiveVehicles()
  table.clear(sceneVehicles)
  local ctr = 1
  for vid, veh in activeVehiclesIterator() do
    sceneVehicles[ctr] = { vid = vid, veh = veh, name = veh:getName(), isLink = false, linkSplineId = nil }
    ctr = ctr + 1
  end
end

-- Returns the active vehicles.
local function getActiveVehicles(isForce)
  if isForce or #sceneVehicles < 1 then
    computeActiveVehicles()
  end
  return sceneVehicles
end

-- Returns the vehicle with the given Id.
local function getVehicleById(vid)
  for i = 1, #sceneVehicles do
    local vehicle = sceneVehicles[i]
    if vehicle and vehicle.vid == vid then
      return vehicle
    end
  end
  return nil
end

-- Computes the left and right edge lines of a ribbon between two spheres.
local function computeRibbonLines(p1, r1, p2, r2)
  local dir = p2 - p1
  dir:normalize()
  local side = dir:cross(globalUp) -- Perp.
  side:normalize()
  local sideR1, sideR2 = side * r1, side * r2
  local pL, pR, qL, qR = p1 + sideR1, p2 + sideR2, p1 - sideR1, p2 - sideR2

  tmp1:set(pL.x, pL.y, pL.z + zExtra)
  util.vertRaycast(tmp1)
  pL.z = tmp1.z + zFloat

  tmp1:set(pR.x, pR.y, pR.z + zExtra)
  util.vertRaycast(tmp1)
  pR.z = tmp1.z + zFloat

  tmp1:set(qL.x, qL.y, qL.z + zExtra)
  util.vertRaycast(tmp1)
  qL.z = tmp1.z + zFloat

  tmp1:set(qR.x, qR.y, qR.z + zExtra)
  util.vertRaycast(tmp1)
  qR.z = tmp1.z + zFloat

  return pL, pR, qL, qR -- Laterally offset points.
end

-- Gets the nav graph.
local function getNavGraph()
  if navGraphData then
    return navGraphData -- If we already have the nav graph data cached, return that immediately.
  end

  local graphPath = map.getGraphpath()
  if not graphPath then
    return nil -- No nav graph data available yet, so return nil and keep navGraphData nil.
  end

  -- The graph is available, so compute the node-to-node lines as an unrolled 1D array.
  local graph, positions, radius = graphPath.graph, graphPath.positions, graphPath.radius
  local lines, edgeSeen = {}, {}
  for fromIdx, targets in pairs(graph) do
    local p0, w0 = positions[fromIdx], radius[fromIdx]
    if p0 then
      for toIdx, _ in pairs(targets) do
        local key = fromIdx < toIdx and (fromIdx .. "-" .. toIdx) or (toIdx .. "-" .. fromIdx)
        if not edgeSeen[key] then
          edgeSeen[key] = true
          local p1, w1 = positions[toIdx], radius[toIdx]
          if p1 then
            local pL, pR, qL, qR = computeRibbonLines(p0, w0, p1, w1)
            table.insert(lines, { pL = pL, pR = pR, qL = qL, qR = qR, cL = p0, cR = p1 })
          end
        end
      end
    end
  end

  -- Cache the nav graph data.
  navGraphData = {
    graph = graph,
    nodes = positions,
    widths = radius,
    lines = lines,
  }

  return navGraphData
end

-- Returns the default slider parameters.
local function getDefaultSliderParams() return defaultParams end

-- Resets all the geometry of the given drive path spline.
local function resetGeometry(spline)
  if spline then
    table.clear(spline.nodes)
    table.clear(spline.widths)
    table.clear(spline.nmls)
    table.clear(spline.vels)
    table.clear(spline.velLimits)

    table.clear(spline.graphNodes)
    table.clear(spline.graphPath)

    spline.isDirty = true
  end
end

-- Adds a new drive path spline.
local function addNewDrivePathSpline()
  -- Ensure we have a unique drive path spline name.
  local baseName = string.format(toolPrefixStr .. " %d", #drivePathSplines + 1)
  local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)

  -- Create a new drive path spline.
  table.insert(drivePathSplines, {
    name = uniqueName,
    id = Engine.generateUUID(),
    isDirty = true,
    isEnabled = true,
    isFreeMode = defaultParams.isFreeMode,

    isVehicleLink = false, -- Link status for vehicles.
    linkVehId = nil,

    nodes = {}, -- Primary geometry.
    widths = {},
    nmls = {},
    vels = {},
    velLimits = {},

    divPoints = {}, -- Secondary geometry.
    divWidths = {},
    tangents = {},
    binormals = {},
    normals = {},
    discMap = {},

    ribPoints = {}, -- Spline handles.
    barPoints = {},

    graphNodes = {}, -- Path data (for NavGraph Mode only).
    graphPath = {},

    roadLength = 0.0,

    delayTime = defaultParams.delayTime,
    routeSpeed = defaultParams.routeSpeed,
    routeSpeedMode = defaultParams.routeSpeedMode,
    aggression = defaultParams.aggression,
    numLaps = defaultParams.numLaps,
    isAvoidCars = defaultParams.isAvoidCars,
    isDriveInLane = defaultParams.isDriveInLane,
    isLoop = defaultParams.isLoop,
    startingNode = defaultParams.startingNode,
    speedProfileMode = defaultParams.speedProfileMode,
  })

  -- Update the spline map.
  util.computeIdToIdxMap(drivePathSplines, splineMap)
end

-- Removes the drive path spline with the given index.
local function removeDrivePathSpline(idx)
  table.remove(drivePathSplines, idx) -- Remove the drive path spline from the list.
  util.computeIdToIdxMap(drivePathSplines, splineMap) -- Update the spline map.
end

-- Removes all drive path splines.
-- [If isIncludeDisabled is true, then all drive path splines will be removed, including disabled ones.]
-- [If isIncludeDisabled is false, then only enabled drive path splines will be removed.]
local function removeAllDrivePathSplines(isIncludeDisabled)
  if isIncludeDisabled then
    for i = #drivePathSplines, 1, -1 do
      local spline = drivePathSplines[i]
      if spline then
        removeDrivePathSpline(i)
      end
    end
  else
    for i = #drivePathSplines, 1, -1 do
      local spline = drivePathSplines[i]
      if spline and spline.isEnabled then -- Only remove enabled and unlinked drive path splines.
        removeDrivePathSpline(i)
      end
    end
  end
end

-- Deep copies the given drive path spline.
local function deepCopyDrivePathSpline(spline)
  local copy = {}

  -- Deep copy the properties.
  copy.name = spline.name -- Keep the same name.
  copy.id = spline.id -- Keep the same id.
  copy.isDirty = true -- Set dirty so geometry is updated.
  copy.isVehicleLink = spline.isVehicleLink -- Keep the same vehicle link status.
  copy.linkVehId = spline.linkVehId
  copy.isEnabled = spline.isEnabled
  copy.isFreeMode = spline.isFreeMode

  copy.delayTime = spline.delayTime
  copy.routeSpeed = spline.routeSpeed
  copy.routeSpeedMode = spline.routeSpeedMode
  copy.aggression = spline.aggression
  copy.numLaps = spline.numLaps
  copy.isAvoidCars = spline.isAvoidCars
  copy.isDriveInLane = spline.isDriveInLane
  copy.isLoop = spline.isLoop
  copy.startingNode = spline.startingNode
  copy.roadLength = spline.roadLength
  copy.speedProfileMode = spline.speedProfileMode

  -- Deep copy the nodes.
  local numNodes = #(spline.nodes or {})
  local copyNodes = table.new(numNodes, 0)
  local splineNodes = spline.nodes
  for i = 1, numNodes do
    copyNodes[i] = vec3(splineNodes[i])
  end
  copy.nodes = copyNodes

  -- Deep copy the widths.
  copy.widths = util.fastArrayCopy(spline.widths)

  -- Deep copy the nmls.
  local numNmls = #(spline.nmls or {})
  local copyNmls = table.new(numNmls, 0)
  local splineNmls = spline.nmls
  for i = 1, numNmls do
    copyNmls[i] = vec3(splineNmls[i])
  end
  copy.nmls = copyNmls

  -- Deep copy the per-node velocities and velocity limits.
  copy.vels = util.fastArrayCopy(spline.vels)
  copy.velLimits = util.fastArrayCopy(spline.velLimits)

  -- Deep copy the graph nodes and path.
  copy.graphNodes = util.fastArrayCopy(spline.graphNodes)
  copy.graphPath = deepcopy(spline.graphPath)

  -- Skip computed geometry - will be regenerated on update.
  copy.ribPoints = {}
  copy.barPoints = {}
  copy.divPoints = {}
  copy.divWidths = {}
  copy.tangents = {}
  copy.binormals = {}
  copy.normals = {}
  copy.discMap = {}

  return copy
end

-- Deep copies the full drive path spline state.
local function deepCopyDrivePathSplineState()
  local numSplines = #drivePathSplines
  local copy = table.new(numSplines, 0)
  for i = 1, numSplines do
    copy[i] = deepCopyDrivePathSpline(drivePathSplines[i])
  end
  return copy
end

-- Splits the selected drive path spline into two, at the selected node.
local function splitDrivePathSpline(selectedSplineIdx, selectedNodeIdx)
  local spline = drivePathSplines[selectedSplineIdx]
  if not spline then return end

  if spline.isLoop then
    -- Unwrap loop in place starting from the split point, convert to open spline.
    local splineNodes, splineWidths, splineNmls = spline.nodes, spline.widths, spline.nmls
    local splineVels, splineVelLimits, splineGraphNodes = spline.vels, spline.velLimits, spline.graphNodes
    local numNodes = #splineNodes

    local nodesNew, widthsNew, nmlsNew = table.new(numNodes, 0), table.new(numNodes, 0), table.new(numNodes, 0)
    local velsNew, velLimitsNew, graphNodesNew = table.new(numNodes, 0), table.new(numNodes, 0), table.new(numNodes, 0)

    local ctr = 1
    for i = selectedNodeIdx, numNodes do
      nodesNew[ctr] = vec3(splineNodes[i])
      widthsNew[ctr] = splineWidths[i]
      nmlsNew[ctr] = vec3(splineNmls[i])
      velsNew[ctr] = splineVels[i]
      velLimitsNew[ctr] = splineVelLimits[i]
      graphNodesNew[ctr] = splineGraphNodes[i]
      ctr = ctr + 1
    end
    for i = 1, selectedNodeIdx - 1 do
      nodesNew[ctr] = vec3(splineNodes[i])
      widthsNew[ctr] = splineWidths[i]
      nmlsNew[ctr] = vec3(splineNmls[i])
      velsNew[ctr] = splineVels[i]
      velLimitsNew[ctr] = splineVelLimits[i]
      graphNodesNew[ctr] = splineGraphNodes[i]
      ctr = ctr + 1
    end

    -- Push apart the split point visually.
    local tangent = nodesNew[2] - nodesNew[#nodesNew]
    tangent:normalize()
    local offset = tangent * splitPartingDistance
    nodesNew[1] = nodesNew[1] + offset
    nodesNew[#nodesNew] = nodesNew[#nodesNew] - offset

    spline.nodes = nodesNew
    spline.widths = widthsNew
    spline.nmls = nmlsNew
    spline.vels = velsNew
    spline.velLimits = velLimitsNew
    spline.graphNodes = graphNodesNew
    spline.isLoop = false
    spline.isDirty = true

  else
    local copy = deepCopyDrivePathSpline(spline)
    removeDrivePathSpline(selectedSplineIdx)

    -- Add first half (A)
    addNewDrivePathSpline()
    local splineA = drivePathSplines[#drivePathSplines]
    splineA.name = copy.name .. '_split_A'
    splineA.isDirty = true
    splineA.isEnabled = true
    splineA.isFreeMode = copy.isFreeMode
    splineA.isVehicleLink = false
    splineA.linkVehId = nil
    splineA.routeSpeed = copy.routeSpeed
    splineA.routeSpeedMode = copy.routeSpeedMode
    splineA.aggression = copy.aggression
    splineA.numLaps = copy.numLaps
    splineA.isAvoidCars = copy.isAvoidCars
    splineA.isDriveInLane = copy.isDriveInLane
    splineA.isLoop = false
    splineA.startingNode = 1
    splineA.roadLength = 0.0
    splineA.speedProfileMode = copy.speedProfileMode

    for i = 1, selectedNodeIdx do
      table.insert(splineA.nodes, copy.nodes[i])
      table.insert(splineA.widths, copy.widths[i])
      table.insert(splineA.nmls, copy.nmls[i])
      table.insert(splineA.vels, copy.vels[i])
      table.insert(splineA.velLimits, copy.velLimits[i])
      table.insert(splineA.graphNodes, copy.graphNodes[i])
    end

    local nds = splineA.nodes
    local tangent = nds[#nds] - nds[#nds - 1]
    tangent:normalize()
    nds[#nds] = nds[#nds] - (tangent * splitPartingDistance)

    -- Add second half (B)
    addNewDrivePathSpline()
    local splineB = drivePathSplines[#drivePathSplines]
    splineB.name = copy.name .. '_split_B'
    splineB.isDirty = true
    splineB.isEnabled = true
    splineB.isFreeMode = copy.isFreeMode
    splineB.isVehicleLink = false
    splineB.linkVehId = nil
    splineB.routeSpeed = copy.routeSpeed
    splineB.routeSpeedMode = copy.routeSpeedMode
    splineB.aggression = copy.aggression
    splineB.numLaps = copy.numLaps
    splineB.isAvoidCars = copy.isAvoidCars
    splineB.isDriveInLane = copy.isDriveInLane
    splineB.isLoop = false
    splineB.startingNode = 1
    splineB.roadLength = 0.0
    splineB.speedProfileMode = copy.speedProfileMode

    for i = selectedNodeIdx, #copy.nodes do
      table.insert(splineB.nodes, copy.nodes[i])
      table.insert(splineB.widths, copy.widths[i])
      table.insert(splineB.nmls, copy.nmls[i])
      table.insert(splineB.vels, copy.vels[i])
      table.insert(splineB.velLimits, copy.velLimits[i])
      table.insert(splineB.graphNodes, copy.graphNodes[i])
    end

    nds = splineB.nodes
    tangent = nds[1] - nds[2]
    tangent:normalize()
    nds[1] = nds[1] - (tangent * splitPartingDistance)

    util.computeIdToIdxMap(drivePathSplines, splineMap)
  end
end

-- Joins two unlooped Drive Path Splines into one, modifying spline1 and deleting spline2.
local function joinDrivePathSplines(splineIdx1, nodeIdx1, splineIdx2, nodeIdx2)
  local spline1, spline2 = drivePathSplines[splineIdx1], drivePathSplines[splineIdx2]
  if not spline1 or not spline2 then return end

  -- Extract geometry and drive path-specific arrays
  local n1, w1, nm1 = spline1.nodes, spline1.widths, spline1.nmls
  local v1, vl1, g1 = spline1.vels, spline1.velLimits, spline1.graphNodes

  local n2, w2, nm2 = spline2.nodes, spline2.widths, spline2.nmls
  local v2, vl2, g2 = spline2.vels, spline2.velLimits, spline2.graphNodes

  local nodesNew, widthsNew, nmlsNew = {}, {}, {}
  local velsNew, velLimitsNew, graphNodesNew = {}, {}, {}
  local ctr = 1

  -- Determine join case and concatenate in correct order
  if nodeIdx1 == 1 and nodeIdx2 == 1 then
    -- Start-Start: reverse spline2, append spline1
    for i = #n2, 1, -1 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n2[i]), w2[i], vec3(nm2[i])
      velsNew[ctr], velLimitsNew[ctr], graphNodesNew[ctr] = v2[i], vl2[i], g2[i]
      ctr = ctr + 1
    end
    for i = 2, #n1 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n1[i]), w1[i], vec3(nm1[i])
      velsNew[ctr], velLimitsNew[ctr], graphNodesNew[ctr] = v1[i], vl1[i], g1[i]
      ctr = ctr + 1
    end

  elseif nodeIdx1 == 1 and nodeIdx2 == #n2 then
    -- Start-End: append spline2, then spline1
    for i = 1, #n2 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n2[i]), w2[i], vec3(nm2[i])
      velsNew[ctr], velLimitsNew[ctr], graphNodesNew[ctr] = v2[i], vl2[i], g2[i]
      ctr = ctr + 1
    end
    for i = 2, #n1 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n1[i]), w1[i], vec3(nm1[i])
      velsNew[ctr], velLimitsNew[ctr], graphNodesNew[ctr] = v1[i], vl1[i], g1[i]
      ctr = ctr + 1
    end

  elseif nodeIdx1 == #n1 and nodeIdx2 == 1 then
    -- End-Start: append spline2 to spline1
    for i = 1, #n1 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n1[i]), w1[i], vec3(nm1[i])
      velsNew[ctr], velLimitsNew[ctr], graphNodesNew[ctr] = v1[i], vl1[i], g1[i]
      ctr = ctr + 1
    end
    for i = 2, #n2 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n2[i]), w2[i], vec3(nm2[i])
      velsNew[ctr], velLimitsNew[ctr], graphNodesNew[ctr] = v2[i], vl2[i], g2[i]
      ctr = ctr + 1
    end

  elseif nodeIdx1 == #n1 and nodeIdx2 == #n2 then
    -- End-End: reverse spline2, append to spline1
    for i = 1, #n1 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n1[i]), w1[i], vec3(nm1[i])
      velsNew[ctr], velLimitsNew[ctr], graphNodesNew[ctr] = v1[i], vl1[i], g1[i]
      ctr = ctr + 1
    end
    for i = #n2 - 1, 1, -1 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n2[i]), w2[i], vec3(nm2[i])
      velsNew[ctr], velLimitsNew[ctr], graphNodesNew[ctr] = v2[i], vl2[i], g2[i]
      ctr = ctr + 1
    end
  else
    return
  end

  -- Apply joined geometry to spline1
  spline1.nodes = nodesNew
  spline1.widths = widthsNew
  spline1.nmls = nmlsNew
  spline1.vels = velsNew
  spline1.velLimits = velLimitsNew
  spline1.graphNodes = graphNodesNew
  spline1.isLoop = false
  spline1.startingNode = 1
  spline1.roadLength = 0.0
  spline1.isDirty = true

  -- Remove spline2 directly for stability
  removeDrivePathSpline(splineIdx2)

  -- Recompute the ID-to-Index map for consistency
  util.computeIdToIdxMap(drivePathSplines, splineMap)
end

-- Flips the geometry of the given drive path spline, such that the nodes are reversed (and so are the widths, normals, velocities and velocity limits).
local function flipSpline(spline)
  local copy = deepCopyDrivePathSpline(spline)
  local nodesCopy, widthsCopy, nmlsCopy, velsCopy, velLimitsCopy, graphNodesCopy = copy.nodes, copy.widths, copy.nmls, copy.vels, copy.velLimits, copy.graphNodes
  table.clear(spline.nodes)
  table.clear(spline.widths)
  table.clear(spline.nmls)
  table.clear(spline.vels)
  table.clear(spline.velLimits)
  table.clear(spline.graphNodes)
  table.clear(spline.ribPoints)
  table.clear(spline.barPoints)
  local ctr = 1
  for i = #nodesCopy, 1, -1 do
    spline.nodes[ctr] = nodesCopy[i]
    spline.widths[ctr] = widthsCopy[i]
    spline.nmls[ctr] = nmlsCopy[i]
    spline.vels[ctr] = velsCopy[i]
    spline.velLimits[ctr] = velLimitsCopy[i]
    spline.graphNodes[ctr] = graphNodesCopy[i]
    ctr = ctr + 1
  end
  spline.isDirty = true
end

-- Sets the pose of the given vehicle to the first node of the given drive path spline, pointing towards the second node.
local function resetVehiclePose(spline, vehicle)
  local veh, startingNode = vehicle.veh, spline.startingNode
  if spline.isFreeMode then
    -- CASE: FREE MODE.
    local nodes = spline.nodes
    if veh and nodes and #nodes > 1 then
      if not cachedVehiclePoses[vehicle.vid] then
        cachedVehiclePoses[vehicle.vid] = { pos = vec3(veh:getPosition()), rot = quat(veh:getRotation()) }
      end
      local dir = nodes[max(1, startingNode - 1)] - nodes[min(startingNode + 1, #nodes)] -- Starting direction.
      dir:normalize()
      tmpRot:setFromDir(dir, globalUp)
      local n = nodes[startingNode]
      veh:setPositionRotation(n.x, n.y, n.z + vehShiftZ, tmpRot.x, tmpRot.y, tmpRot.z, tmpRot.w)
    end
  else
    -- CASE: NAV GRAPH MODE.
    local splineGraphNodes = spline.graphNodes
    if veh and splineGraphNodes and #splineGraphNodes > 1 and navGraphData then
      local graphNodes = navGraphData.nodes
      if not cachedVehiclePoses[vehicle.vid] then
        cachedVehiclePoses[vehicle.vid] = { pos = vec3(veh:getPosition()), rot = quat(veh:getRotation()) }
      end
      local dir = graphNodes[splineGraphNodes[max(1, startingNode - 1)]] - graphNodes[splineGraphNodes[min(startingNode + 1, #splineGraphNodes)]] -- Starting direction.
      dir:normalize()
      tmpRot:setFromDir(dir, globalUp)
      local pStart = graphNodes[splineGraphNodes[startingNode]]
      veh:setPositionRotation(pStart.x, pStart.y, pStart.z + vehShiftZ, tmpRot.x, tmpRot.y, tmpRot.z, tmpRot.w)
    end
  end
end

-- Links the given drive path spline to the given vehicle.
local function linkSpline(spline, vehicle)
  if spline and vehicle then
    spline.isVehicleLink = true
    spline.linkVehId = vehicle.vid
    vehicle.isLink = true
    vehicle.linkSplineId = spline.id
    resetVehiclePose(spline, vehicle) -- Reset the vehicle pose to the first node of the drive path spline.
  end
end

-- Unlinks the given drive path spline from its vehicle.
local function unlinkSpline(spline, vehicle)
  if spline and vehicle then
    vehicle.isLink = false
    vehicle.linkSplineId = nil
    spline.isVehicleLink = false
    spline.linkVehId = nil

    -- Restore the vehicle pose.
    local veh, vid = vehicle.veh, vehicle.vid
    if veh and cachedVehiclePoses[vid] then
      local pos, rot = cachedVehiclePoses[vid].pos, cachedVehiclePoses[vid].rot
      veh:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
      cachedVehiclePoses[vid] = nil
    end
  end
end

-- Resets all the vehicle <-> drive path spline links stored in the scene vehicles.
local function resetAllLinksInVehicles()
  for i = 1, #sceneVehicles do
    local vehicle = sceneVehicles[i]
    vehicle.isLink = false
    vehicle.linkSplineId = nil
  end
end

-- Re-link all the vehicles to the drive path splines.
local function relinkAllVehiclesToSplines()
  for i = 1, #drivePathSplines do
    local spline = drivePathSplines[i]
    linkSpline(spline, getVehicleById(spline.linkVehId))
  end
end

-- Undo/redo core function.
local function singleSplineEditUndoRedoCore(data)
  resetAllLinksInVehicles()
  local idx = splineMap[data.id]
  if idx then
    local spline = drivePathSplines[idx]
    spline.name = data.name
    spline.isDirty = true -- Set the dirty flag to true.
    spline.isVehicleLink = data.isVehicleLink
    spline.linkVehId = data.linkVehId

    spline.nodes = data.nodes
    spline.widths = data.widths
    spline.nmls = data.nmls
    spline.vels = data.vels
    spline.velLimits = data.velLimits
    spline.graphNodes = data.graphNodes
    spline.graphPath = data.graphPath

    spline.isEnabled = data.isEnabled
    spline.delayTime = data.delayTime
    spline.routeSpeed = data.routeSpeed
    spline.routeSpeedMode = data.routeSpeedMode
    spline.aggression = data.aggression
    spline.numLaps = data.numLaps
    spline.isAvoidCars = data.isAvoidCars
    spline.isDriveInLane = data.isDriveInLane
    spline.isLoop = data.isLoop
    spline.startingNode = data.startingNode
    spline.roadLength = data.roadLength
    spline.speedProfileMode = data.speedProfileMode
  end
  relinkAllVehiclesToSplines()
end

-- Handles the undo for a single drive path spline.
local function singleSplineEditUndo(drivePathSplineData)
  local data = drivePathSplineData.old
  if data then
    singleSplineEditUndoRedoCore(data)
  end
end

-- Handles the redo for a single drive path spline.
local function singleSplineEditRedo(drivePathSplineData)
  local data = drivePathSplineData.new
  if data then
    singleSplineEditUndoRedoCore(data)
  end
end

-- Handles the undo for trans drive path spline edits.
local function transSplineEditUndo(data)
  resetAllLinksInVehicles() -- Remove all existing links in both vehicles and drive path splines.
  removeAllDrivePathSplines(true)
  setDrivePathSplines(data.old)
  for i = 1, #drivePathSplines do
    drivePathSplines[i].isDirty = true
  end
  util.computeIdToIdxMap(drivePathSplines, splineMap) -- Update the spline map.
  relinkAllVehiclesToSplines() -- Re-link all the vehicles to the drive path splines.
end

-- Handles the redo for trans drive path spline edits.
local function transSplineEditRedo(data)
  resetAllLinksInVehicles() -- Remove all existing links in both vehicles and drive path splines.
  removeAllDrivePathSplines(true)
  setDrivePathSplines(data.new)
  for i = 1, #drivePathSplines do
    drivePathSplines[i].isDirty = true
  end
  util.computeIdToIdxMap(drivePathSplines, splineMap) -- Update the spline map.
  relinkAllVehiclesToSplines() -- Re-link all the vehicles to the drive path splines.
end

-- Serializes a drive path spline to a table.
local function serializeDrivePathSpline(spline)
  local data = {}
  data.name = spline.name
  data.id = spline.id
  data.isVehicleLink = spline.isVehicleLink -- Keep the same vehicle link status.
  data.linkVehId = spline.linkVehId
  data.isEnabled = spline.isEnabled -- Keep the same enabled status.
  data.isFreeMode = spline.isFreeMode
  data.delayTime = spline.delayTime
  data.routeSpeed = spline.routeSpeed
  data.routeSpeedMode = spline.routeSpeedMode
  data.aggression = spline.aggression
  data.numLaps = spline.numLaps
  data.isAvoidCars = spline.isAvoidCars
  data.isDriveInLane = spline.isDriveInLane
  data.isLoop = spline.isLoop
  data.startingNode = spline.startingNode
  data.roadLength = spline.roadLength
  data.speedProfileMode = spline.speedProfileMode

  -- Serialise the nodes data.
  local numNodes = #spline.nodes
  local copyNodes = table.new(numNodes, 0)
  local splineNodes = spline.nodes
  for i = 1, numNodes do
    local n = splineNodes[i]
    copyNodes[i] = { x = n.x, y = n.y, z = n.z }
  end
  data.nodes = copyNodes

  -- Serialise the per-node widths data.
  data.widths = spline.widths

  -- Serialise the per-node normals data.
  local numNmls = #(spline.nmls or {})
  local copyNmls = table.new(numNmls, 0)
  local splineNmls = spline.nmls
  for i = 1, numNmls do
    local n = splineNmls[i]
    copyNmls[i] = { x = n.x, y = n.y, z = n.z }
  end
  data.nmls = copyNmls

  -- Serialise the per-node velocities and velocity limits data.
  data.vels = spline.vels
  data.velLimits = spline.velLimits

  -- Serialise the graph nodes and path data.
  data.graphNodes = spline.graphNodes
  data.graphPath = spline.graphPath

  return data
end

-- Deserializes a drive path spline from a table.
local function deserializeDrivePathSpline(data)
  local spline = {}
  spline.name = data.name
  spline.id = data.id
  spline.isDirty = true -- Set dirty so geometry is updated.
  spline.isVehicleLink = (data.isVehicleLink == true or data.isVehicleLink == 1) and true or false
  spline.linkVehId = data.linkVehId
  spline.isEnabled = (data.isEnabled == true or data.isEnabled == 1) and true or false
  spline.isFreeMode = (data.isFreeMode == true or data.isFreeMode == 1) and true or false
  spline.delayTime = data.delayTime
  spline.routeSpeed = data.routeSpeed
  if data.routeSpeedMode then
    spline.routeSpeedMode = data.routeSpeedMode
  else
    local isRouteSpeedLimit = (data.isRouteSpeedLimit == true or data.isRouteSpeedLimit == 1) and true or false
    spline.routeSpeedMode = isRouteSpeedLimit and 'limit' or 'set'
  end
  spline.aggression = data.aggression
  spline.numLaps = data.numLaps
  spline.isAvoidCars = (data.isAvoidCars == true or data.isAvoidCars == 1) and true or false
  spline.isDriveInLane = (data.isDriveInLane == true or data.isDriveInLane == 1) and true or false
  spline.isLoop = (data.isLoop == true or data.isLoop == 1) and true or false
  spline.startingNode = data.startingNode
  spline.roadLength = data.roadLength
  spline.speedProfileMode = data.speedProfileMode or 0

  -- Deserialise the nodes data.
  local splineNodes = data.nodes or {}
  local numNodes = #splineNodes
  local copyNodes = table.new(numNodes, 0)
  for i = 1, numNodes do
    local n = splineNodes[i]
    copyNodes[i] = vec3(n.x, n.y, n.z)
  end
  spline.nodes = copyNodes

  -- Deserialise the per-node widths data.
  spline.widths = data.widths or {}

  -- Deserialise the per-node normals data.
  local nmls = data.nmls or {}
  local numNmls = #nmls
  local copyNmls = table.new(numNmls, 0)
  for i = 1, numNmls do
    local n = nmls[i]
    copyNmls[i] = vec3(n.x, n.y, n.z)
  end
  spline.nmls = copyNmls

  -- Deserialise the per-node velocities and velocity limits data.
  spline.vels = data.vels or {}
  spline.velLimits = data.velLimits or {}

  -- Deserialise the graph nodes and path data.
  spline.graphNodes = data.graphNodes or {}
  spline.graphPath = data.graphPath or {}

  -- Deserialise the handle points.
  spline.ribPoints = {}
  spline.barPoints = {}

  -- Allocate secondary geometry data.
  spline.divPoints = {}
  spline.divWidths = {}
  spline.tangents = {}
  spline.binormals = {}
  spline.normals = {}
  spline.discMap = {}

  return spline
end

-- Ensures that velocities exist for all nodes in a spline.
local function ensureVelocitiesExist(spline)
  -- Ensure vels array exists and has values for all nodes.
  if not spline.vels or #spline.vels == 0 then
    spline.vels = {}
    for i = 1, #spline.nodes do
      spline.vels[i] = 30.0 -- Default velocity of 30 m/s.
    end
  elseif #spline.vels < #spline.nodes then
    -- Extend velocities array if it's too short.
    for i = #spline.vels + 1, #spline.nodes do
      spline.vels[i] = spline.vels[#spline.vels] or 30.0 -- Use last velocity or default.
    end
  end

  -- Ensure velLimits array exists and has values for all nodes.
  if not spline.velLimits or #spline.velLimits == 0 then
    spline.velLimits = {}
    for i = 1, #spline.nodes do
      spline.velLimits[i] = 70.0 -- Default velocity limit of 70 m/s.
    end
  elseif #spline.velLimits < #spline.nodes then
    -- Extend velocity limits array if it's too short.
    for i = #spline.velLimits + 1, #spline.nodes do
      spline.velLimits[i] = spline.velLimits[#spline.velLimits] or 70.0 -- Use last velocity limit or default.
    end
  end
end

-- Updates the geometry of any dirty drive path splines.
local function updateDirtyDrivePathSplines()
  for i = 1, #drivePathSplines do
    local spline = drivePathSplines[i]
    if spline.isDirty then
      -- Check if we have less than 2 nodes - if so, clean up and skip processing.
      if #spline.nodes < 2 then
        -- Clear secondary geometry.
        table.clear(spline.divPoints)
        table.clear(spline.divWidths)
        table.clear(spline.tangents)
        table.clear(spline.binormals)
        table.clear(spline.normals)
        table.clear(spline.discMap)
        table.clear(spline.ribPoints)
        table.clear(spline.barPoints)
        spline.roadLength = 0.0
        spline.isDirty = false
      else
        if spline.isFreeMode then -- CASE: FREE MODE.
          local nodes = spline.nodes
          for j = 1, #nodes do
            util.vertRaycast(nodes[j])
          end
          if (spline.speedProfileMode or 0) ~= 0 then
            local isBarsLimits = spline.speedProfileMode == 2
            ensureVelocitiesExist(spline) -- Ensure velocities exist before updating bar points.
            geom.updateBarPoints(spline, isBarsLimits) -- Update the bar points.
          else
            table.clear(spline.barPoints)
          end
          geom.catmullRomRaycast(spline, minSplineDivisions) -- Ensure the secondary geometry is updated and conforms to the terrain.
          geom.updateRibPointsRaycast(spline) -- Update the rib points.
          spline.isDirty = false -- Spline is updated, so clear the dirty flag.
        else -- CASE: NAV GRAPH MODE.
          if navGraphData then
            geom.computeGraphPathFromNodes(spline) -- Populates the spline with the ordered nav graph path (note: stores keys not points).
            if (spline.speedProfileMode or 0) == 1 then
              geom.updateBarPointsGraph(spline, navGraphData, false) -- Update the bar points using speed targets.
            else
              table.clear(spline.barPoints)
            end
            spline.roadLength = util.getPolyLength(spline.nodes) -- Update the spline length.
            spline.isDirty = false -- Spline is updated, so clear the dirty flag.
          else
            -- Nav graph data not available yet, skip this spline and keep it dirty for next update.
            -- Continue to next iteration without updating this spline.
          end
        end
      end
    end
  end
end

-- Converts the given paths (traced from a bitmap) to drive path splines.
local function convertPathsToDrivePathSplines(paths)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  for i = 1, #paths do
    local path = paths[i]

    -- Create a new drive path spline.
    addNewDrivePathSpline()
    local spline = drivePathSplines[#drivePathSplines]

    -- Convert the grid points to world space.
    local points = path.points
    local pointsWS, numPoints = {}, #points
    for j = 1, numPoints do
      local pointGrid = points[j]
      tmpPoint2I.x, tmpPoint2I.y = pointGrid.x, pointGrid.y
      pointsWS[j] = te:gridToWorldByPoint2I(tmpPoint2I, tb)
    end

    -- If the path is sufficiently large, then import it.
    local aabb = geom.getAABB(pointsWS)
    if min(abs(aabb.xMax - aabb.xMin), abs(aabb.yMax - aabb.yMin)) > minImportSize then
      spline.nodes, spline.widths = pointsWS, path.widths -- Set the nodes and widths directly.
      for j = 1, numPoints do
        spline.nmls[j] = geom.getTerrainNormal(pointsWS[j]) -- Compute the normals for each node.
      end
    end
  end
  log('I', logTag, string.format("Converted %d traced paths to drive path splines. %d paths were too small to import.", #paths, #paths - #drivePathSplines))
end


-- Public interface.
M.getToolPrefixStr =                                    getToolPrefixStr
M.getEditModeKey =                                      getEditModeKey

M.getDrivePathSplines =                                 getDrivePathSplines
M.getSplineMap =                                        getSplineMap
M.setDrivePathSplines =                                 setDrivePathSplines
M.setDrivePathSpline =                                  setDrivePathSpline

M.computeActiveVehicles =                               computeActiveVehicles
M.getActiveVehicles =                                   getActiveVehicles
M.getVehicleById =                                      getVehicleById

M.getNavGraph =                                         getNavGraph

M.resetGeometry =                                       resetGeometry

M.getDefaultSliderParams =                              getDefaultSliderParams

M.addNewDrivePathSpline =                               addNewDrivePathSpline

M.splitDrivePathSpline =                                splitDrivePathSpline
M.joinDrivePathSplines =                                joinDrivePathSplines

M.flipSpline =                                          flipSpline
M.removeDrivePathSpline =                               removeDrivePathSpline
M.removeAllDrivePathSplines =                           removeAllDrivePathSplines

M.deepCopyDrivePathSpline =                             deepCopyDrivePathSpline
M.deepCopyDrivePathSplineState =                        deepCopyDrivePathSplineState

M.singleSplineEditUndo =                                singleSplineEditUndo
M.singleSplineEditRedo =                                singleSplineEditRedo
M.transSplineEditUndo =                                 transSplineEditUndo
M.transSplineEditRedo =                                 transSplineEditRedo

M.updateDirtyDrivePathSplines =                         updateDirtyDrivePathSplines

M.convertPathsToDrivePathSplines =                      convertPathsToDrivePathSplines

M.serializeDrivePathSpline =                            serializeDrivePathSpline
M.deserializeDrivePathSpline =                          deserializeDrivePathSpline
M.deepCopyDrivePathSplineState =                        deepCopyDrivePathSplineState

M.resetVehiclePose =                                    resetVehiclePose
M.linkSpline =                                          linkSpline
M.unlinkSpline =                                        unlinkSpline
M.relinkAllVehiclesToSplines =                          relinkAllVehiclesToSplines

return M