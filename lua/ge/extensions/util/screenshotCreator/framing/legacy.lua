-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"core_vehicle_manager", "util_screenshotCreator_settings", "util_screenshotCreator_thumbnailConfig"}

local fixedFov = 20
local defaultNearPlane = 0.1
local defaultResolution = {500, 281}
local cameraAxisDownOffset = 0.10
local minCameraHeight = 0.75 -- above the lowest framing node
local legacyVehicleMargin = {top = 12, right = 12, left = 5, bottom = 1}
local zeroMargin = {left = 0, right = 0, top = 0, bottom = 0, extraBottom = 0}

local function applyCameraRotation(framingData, rotation)
  framingData.camRot = rotation
  framingData.camRight = rotation * vec3(1, 0, 0)
  framingData.camForward = rotation * vec3(0, 1, 0)
  framingData.camUp = rotation * vec3(0, 0, 1)
end

-- world node positions without antenna/flag, non-colliding helper and underground nodes, which would stretch the framing box
local function getFramingNodes(vehicle)
  local data = core_vehicle_manager.getVehicleData(vehicle:getId())
  local nodeData = data and data.vdata and data.vdata.nodes or {}
  local position = vehicle:getPosition()
  local minZ = be:getSurfaceHeightBelow(position + vec3(0, 0, 2)) - 0.02
  local nodes, allNodes = {}, {}
  for cid = 0, vehicle:getNodeCount() - 1 do
    local point = position + vehicle:getNodePosition(cid)
    local node = nodeData[cid] or {}
    local part = string.lower(node.partOrigin or "")
    allNodes[#allNodes + 1] = point
    if point.z >= minZ and node.collision ~= false and not node.ignoreForThumbnailFraming
      and not part:find("anten", 1, true) and not part:find("flag", 1, true)
    then
      nodes[#nodes + 1] = point
    end
  end
  return #nodes > 0 and nodes or allNodes
end

local function getVehicleFramingData(vehicle, fixedRotation, configName)
  local bb = vehicle:getSpawnWorldOOBB()
  local axis0, axis1, axis2 = util_screenshotCreator_thumbnailConfig.getReferenceAxes(vehicle, configName, bb)
  local allNodes = getFramingNodes(vehicle)
  local minExtent, maxExtent = vec3(math.huge, math.huge, math.huge), vec3(-math.huge, -math.huge, -math.huge)
  for _, node in ipairs(allNodes) do
    local extent = vec3(node:dot(axis0), node:dot(axis1), node:dot(axis2))
    minExtent = vec3(math.min(minExtent.x, extent.x), math.min(minExtent.y, extent.y), math.min(minExtent.z, extent.z))
    maxExtent = vec3(math.max(maxExtent.x, extent.x), math.max(maxExtent.y, extent.y), math.max(maxExtent.z, extent.z))
  end
  local halfExtents = (maxExtent - minExtent) * 0.5
  local centerExtent = (maxExtent + minExtent) * 0.5
  local center = axis0 * centerExtent.x + axis1 * centerExtent.y + axis2 * centerExtent.z
  local cameraOffsetLocal = vec3(-0.75, -0.66, 0.07):normalized()
  local cameraOffset = (
    axis0 * cameraOffsetLocal.x
    + axis1 * cameraOffsetLocal.y
    + axis2 * cameraOffsetLocal.z
  ):normalized()
  local cameraAxisCenter = center - axis2 * cameraAxisDownOffset
  local lookAtPoint = cameraAxisCenter - axis1 * halfExtents.y / 8
  local cameraRotation = fixedRotation or quatFromDir(-cameraOffset, axis2)

  local extentNodes = {}
  local maxNodesPerExtent = 100
  local skippedExtremeNodesPerExtent = 0
  for axisIndex, axis in ipairs({axis0, axis1, axis2}) do
    local maxNodes = {}
    local minNodes = {}
    for _, node in ipairs(allNodes) do
      local extent = node:dot(axis)
      maxNodes[#maxNodes + 1] = {extent = extent, node = node}
      minNodes[#minNodes + 1] = {extent = extent, node = node}
    end

    table.sort(maxNodes, function(a, b) return a.extent > b.extent end)
    table.sort(minNodes, function(a, b) return a.extent < b.extent end)

    local maxCount = math.min(maxNodesPerExtent + skippedExtremeNodesPerExtent, #maxNodes)
    local minCount = math.min(maxNodesPerExtent + skippedExtremeNodesPerExtent, #minNodes)
    for nodeIndex = skippedExtremeNodesPerExtent + 1, maxCount do
      extentNodes[#extentNodes + 1] = {
        axis = axis,
        node = maxNodes[nodeIndex].node,
        index = axisIndex
      }
    end
    for nodeIndex = skippedExtremeNodesPerExtent + 1, minCount do
      extentNodes[#extentNodes + 1] = {
        axis = axis,
        node = minNodes[nodeIndex].node,
        index = axisIndex
      }
    end
  end

  local framingPoints = {}
  for _, extentNode in ipairs(extentNodes) do
    framingPoints[#framingPoints + 1] = {
      name = "extent",
      point = extentNode.node,
      color = {0.2, 0.8, 1}
    }
  end

  local framingData = {
    bb = bb,
    center = center,
    camAxisCenter = cameraAxisCenter,
    axis0 = axis0,
    axis1 = axis1,
    axis2 = axis2,
    halfExtents = halfExtents,
    floorZ = minExtent.z,
    camOffsetAxis = cameraOffset,
    lookAtPoint = lookAtPoint,
    framingPoints = framingPoints
  }
  applyCameraRotation(framingData, cameraRotation)
  return framingData
end

local function getFramingMargin(context, resolution)
  local useMargins = context.useFramingMargins
  if useMargins == nil then useMargins = context.useMargins end
  if useMargins ~= true then
    return zeroMargin
  end

  if type(context.margin) == "table" then return context.margin end

  if resolution[1] ~= defaultResolution[1] or resolution[2] ~= defaultResolution[2] then
    return zeroMargin
  end

  local settingsExtension = util_screenshotCreator_settings
  local controls = settingsExtension.getControls()
  local target = settingsExtension.getMarginTarget(controls.selectedMargin[0])
  return {
    left = target.left + legacyVehicleMargin.left,
    right = target.right + legacyVehicleMargin.right,
    top = target.top + legacyVehicleMargin.top,
    bottom = target.bottom + legacyVehicleMargin.bottom,
    extraBottom = target.extraBottom
  }
end

local function getProjectionBounds(aspectRatio, resolution, margin)
  local halfVerticalTan = math.tan(math.rad(fixedFov) * 0.5)
  local halfHorizontalTan = halfVerticalTan * aspectRatio
  return {
    xMin = (margin.left / resolution[1] * 2 - 1) * halfHorizontalTan,
    xMax = ((resolution[1] - margin.right) / resolution[1] * 2 - 1) * halfHorizontalTan,
    yMin = (margin.bottom / resolution[2] * 2 - 1) * halfVerticalTan,
    yMax = (1 - margin.top / resolution[2] * 2) * halfVerticalTan
  }
end

local function projectPoint(framingData, point)
  local toPoint = point - framingData.lookAtPoint
  return {
    right = toPoint:dot(framingData.camRight),
    up = toPoint:dot(framingData.camUp),
    forward = toPoint:dot(framingData.camForward)
  }
end

local function getFitIntervalsAtDistance(framingData, bounds, distance, nearPlane)
  local xMin, xMax = -math.huge, math.huge
  local yMin, yMax = -math.huge, math.huge

  for _, framingPoint in ipairs(framingData.framingPoints) do
    local projected = framingPoint.projected or projectPoint(framingData, framingPoint.point)
    framingPoint.projected = projected

    local depth = projected.forward + distance
    if depth <= nearPlane then return nil end

    local pointXMin = projected.right - bounds.xMax * depth
    local pointXMax = projected.right - bounds.xMin * depth
    local pointYMin = projected.up - bounds.yMax * depth
    local pointYMax = projected.up - bounds.yMin * depth
    xMin = math.max(xMin, pointXMin)
    xMax = math.min(xMax, pointXMax)
    yMin = math.max(yMin, pointYMin)
    yMax = math.min(yMax, pointYMax)

    if xMin > xMax or yMin > yMax then return nil end
  end

  return {xMin = xMin, xMax = xMax, yMin = yMin, yMax = yMax}
end

local function solveCameraFit(framingData, bounds, nearPlane)
  local minForward = math.huge
  for _, framingPoint in ipairs(framingData.framingPoints) do
    local projected = projectPoint(framingData, framingPoint.point)
    framingPoint.projected = projected
    minForward = math.min(minForward, projected.forward)
  end

  local lowDistance = math.max(nearPlane - minForward + 0.01, 0.01)
  local highDistance = math.max(lowDistance, framingData.halfExtents:length() * 2, 1)
  local intervals = getFitIntervalsAtDistance(framingData, bounds, highDistance, nearPlane)
  local maxDistance = math.max(highDistance * 128, 1000)

  while not intervals and highDistance < maxDistance do
    lowDistance = highDistance
    highDistance = highDistance * 2
    intervals = getFitIntervalsAtDistance(framingData, bounds, highDistance, nearPlane)
  end
  if not intervals then return nil end

  for _ = 1, 32 do
    local testDistance = (lowDistance + highDistance) * 0.5
    local testIntervals = getFitIntervalsAtDistance(framingData, bounds, testDistance, nearPlane)
    if testIntervals then
      highDistance = testDistance
      intervals = testIntervals
    else
      lowDistance = testDistance
    end
  end

  intervals = getFitIntervalsAtDistance(framingData, bounds, highDistance, nearPlane) or intervals
  local preferredX = -((bounds.xMin + bounds.xMax) * 0.5) * highDistance
  local preferredY = -((bounds.yMin + bounds.yMax) * 0.5) * highDistance
  return {
    distance = highDistance,
    offsetX = clamp(preferredX, intervals.xMin, intervals.xMax),
    offsetY = clamp(preferredY, intervals.yMin, intervals.yMax),
    intervals = intervals
  }
end

local function addProjectedClearance(framingData, cameraPosition, aspectRatio, resolution, margin)
  local halfHeightFactor = math.tan(math.rad(fixedFov) * 0.5)
  local lowestClearancePoint
  for _, framingPoint in ipairs(framingData.framingPoints) do
    local toPoint = framingPoint.point - cameraPosition
    local depth = toPoint:dot(framingData.camForward)
    local halfHeight = halfHeightFactor * depth
    local halfWidth = halfHeight * aspectRatio
    if depth > 0 and halfWidth > 0 and halfHeight > 0 then
      local screenX = (toPoint:dot(framingData.camRight) / halfWidth + 1) * 0.5 * resolution[1]
      local screenY = (1 - toPoint:dot(framingData.camUp) / halfHeight) * 0.5 * resolution[2]
      local clearances = {
        {side = "left", value = screenX - margin.left},
        {side = "right", value = resolution[1] - margin.right - screenX},
        {side = "top", value = screenY - margin.top},
        {side = "bottom", value = resolution[2] - margin.bottom - screenY}
      }
      local closest = clearances[1]
      for index = 2, #clearances do
        if clearances[index].value < closest.value then closest = clearances[index] end
      end
      framingPoint.marginDistance = closest.value
      framingPoint.marginDistanceSide = closest.side
      framingPoint.screenX = screenX
      framingPoint.screenY = screenY
      framingPoint.framingDistance = depth
      if not lowestClearancePoint
        or framingPoint.marginDistance < lowestClearancePoint.marginDistance
      then
        lowestClearancePoint = framingPoint
      end
    end
  end
  return lowestClearancePoint and lowestClearancePoint.marginDistanceSide or "fallback"
end

local function resolve(context)
  if type(context) ~= "table" or not context.vehicle then
    return nil, "Legacy framing requires context.vehicle"
  end

  local resolution = context.resolution or defaultResolution
  resolution = {tonumber(resolution[1]) or defaultResolution[1], tonumber(resolution[2]) or defaultResolution[2]}
  local aspectRatio = tonumber(context.aspectRatio) or resolution[1] / resolution[2]
  local nearPlane = tonumber(context.nearPlane) or defaultNearPlane
  local framingData = getVehicleFramingData(context.vehicle, context.fixedRotation, context.configName)
  local margin = getFramingMargin(context, resolution)
  local bounds = getProjectionBounds(aspectRatio, resolution, margin)
  local function solvePosition()
    local fit = solveCameraFit(framingData, bounds, nearPlane) or {
      distance = math.max(1, framingData.halfExtents:length() * 2),
      offsetX = 0,
      offsetY = 0
    }
    return framingData.lookAtPoint
      - framingData.camForward * fit.distance
      + framingData.camRight * fit.offsetX
      + framingData.camUp * fit.offsetY, fit
  end
  local cameraPosition, fit = solvePosition()

  -- tiny objects: raise the camera to the cap by pitching it down, the refit keeps every framing point in view
  local minCameraZ = framingData.floorZ + minCameraHeight
  if not context.fixedRotation and cameraPosition.z < minCameraZ then
    local up = framingData.axis2
    local offset = framingData.camOffsetAxis
    local horizontal = (offset - up * offset:dot(up)):normalized()
    local function setElevation(elevation)
      framingData.camOffsetAxis = horizontal * math.cos(elevation) + up * math.sin(elevation)
      applyCameraRotation(framingData, quatFromDir(-framingData.camOffsetAxis, up))
    end
    local low, high = math.asin(clamp(offset:dot(up), -1, 1)), math.rad(85)
    for _ = 1, 20 do
      local elevation = (low + high) * 0.5
      setElevation(elevation)
      if solvePosition().z < minCameraZ then low = elevation else high = elevation end
    end
    setElevation(high)
    cameraPosition, fit = solvePosition()
  end

  framingData.finalCamPos = cameraPosition
  framingData.finalCamRot = framingData.camRot
  framingData.boundBy = addProjectedClearance(
    framingData,
    cameraPosition,
    aspectRatio,
    resolution,
    margin
  )
  framingData.fit = fit

  return {
    pos = cameraPosition,
    rot = framingData.camRot,
    fov = fixedFov,
    name = "legacy camera",
    debugData = framingData,
    framingData = framingData
  }
end

local function onScreenshotCreatorCollectFramingModes(modes)
  modes[#modes + 1] = {
    id = "legacy",
    label = "Legacy (pre-r186184)",
    order = 50,
    fixedFov = fixedFov,
    supportsFixedRotation = true,
    resolve = resolve
  }
end

M.resolve = resolve
M.frame = resolve
M.getVehicleFramingData = getVehicleFramingData
M.onScreenshotCreatorCollectFramingModes = onScreenshotCreatorCollectFramingModes

return M
