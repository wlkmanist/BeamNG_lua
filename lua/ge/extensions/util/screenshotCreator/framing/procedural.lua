-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "util_screenshotCreator_thumbnailConfig",
  "util_screenshotCreator_nodeOutpaint",
  "util_screenshotCreator_settings",
  "util_screenshotCreator_vehicleSetup",
}

local defaultFov = 20
local defaultNearPlane = 0.1
local defaultResolution = {500, 281}
local defaultCameraHeight = 1.6
local cameraAxisDownOffset = 0.10
local mirrorFrameMarginPixels = 2
local maxNodesPerExtent = 100
local zeroMargin = {left = 0, right = 0, top = 0, bottom = 0, extraBottom = 0}
local selfChecked = false

local function applyCameraRotation(framingData, rotation)
  framingData.camRot = rotation
  framingData.camRight = rotation * vec3(1, 0, 0)
  framingData.camForward = rotation * vec3(0, 1, 0)
  framingData.camUp = rotation * vec3(0, 0, 1)
end

local function getBoundsFromNodes(nodes, axis0, axis1, axis2)
  if #nodes == 0 then return nil end

  local minExtents = {math.huge, math.huge, math.huge}
  local maxExtents = {-math.huge, -math.huge, -math.huge}
  local minWorldZ = math.huge
  local axes = {axis0, axis1, axis2}

  for _, node in ipairs(nodes) do
    minWorldZ = math.min(minWorldZ, node.point.z)
    for axisIndex, axis in ipairs(axes) do
      local extent = node.point:dot(axis)
      minExtents[axisIndex] = math.min(minExtents[axisIndex], extent)
      maxExtents[axisIndex] = math.max(maxExtents[axisIndex], extent)
    end
  end

  local center = axis0 * ((minExtents[1] + maxExtents[1]) * 0.5)
    + axis1 * ((minExtents[2] + maxExtents[2]) * 0.5)
    + axis2 * ((minExtents[3] + maxExtents[3]) * 0.5)
  local halfExtents = vec3(
    (maxExtents[1] - minExtents[1]) * 0.5,
    (maxExtents[2] - minExtents[2]) * 0.5,
    (maxExtents[3] - minExtents[3]) * 0.5
  )
  local x, y, z = axis0 * halfExtents.x, axis1 * halfExtents.y, axis2 * halfExtents.z

  return {
    center = center,
    halfExtents = halfExtents,
    minWorldZ = minWorldZ,
    corners = {
      center - x - y - z,
      center + x - y - z,
      center + x + y - z,
      center - x + y - z,
      center - x - y + z,
      center + x - y + z,
      center + x + y + z,
      center - x + y + z,
    },
  }
end

local function selectExtentNodes(nodes, axes)
  local extentNodes = {}
  for _, axis in ipairs(axes) do
    local maxNodes = {}
    local minNodes = {}
    for _, node in ipairs(nodes) do
      local extent = node.point:dot(axis)
      maxNodes[#maxNodes + 1] = {extent = extent, node = node}
      minNodes[#minNodes + 1] = {extent = extent, node = node}
    end
    table.sort(maxNodes, function(a, b) return a.extent > b.extent end)
    table.sort(minNodes, function(a, b) return a.extent < b.extent end)

    for index = 1, math.min(maxNodesPerExtent, #maxNodes) do
      extentNodes[#extentNodes + 1] = maxNodes[index].node
    end
    for index = 1, math.min(maxNodesPerExtent, #minNodes) do
      extentNodes[#extentNodes + 1] = minNodes[index].node
    end
  end
  return extentNodes
end

local function addRotationNode(rotationNodes, node)
  if not node.disabled then rotationNodes[#rotationNodes + 1] = node end
end

local function getRotationPoints(rotationNodes, axes, fallbackPoints)
  if #rotationNodes == 0 then return fallbackPoints end
  return selectExtentNodes(rotationNodes, axes)
end

local function selfCheck()
  local belowGroundNode = {point = vec3(0, 0, -2), belowGround = true}
  local mirrorNode = {point = vec3(3, 0, 0), automaticMirrorOutpaint = true}
  local disabledNode = {point = vec3(0, 4, 0), disabled = true}
  local rotationNodes = {}
  addRotationNode(rotationNodes, belowGroundNode)
  addRotationNode(rotationNodes, mirrorNode)
  addRotationNode(rotationNodes, disabledNode)
  assert(#rotationNodes == 2)

  local axes = {
    vec3(1, 0, 0),
    vec3(0, 1, 0),
    vec3(0, 0, 1)
  }
  local extentNodes = getRotationPoints(rotationNodes, axes)
  local foundBelowGround = false
  local foundMirror = false
  for _, node in ipairs(extentNodes) do
    foundBelowGround = foundBelowGround or node == belowGroundNode
    foundMirror = foundMirror or node == mirrorNode
  end
  assert(foundBelowGround and foundMirror)
  local fallbackPoints = {{point = vec3(1, 2, 3)}}
  assert(getRotationPoints({}, axes, fallbackPoints) == fallbackPoints)
  return true
end

local function getVehicleFramingData(context)
  local vehicle = context.vehicle
  local bb = vehicle:getSpawnWorldOOBB()
  local axis0, axis1, axis2 = bb:getAxis(0), bb:getAxis(1), bb:getAxis(2)
  local cameraAxis0, cameraAxis1, cameraAxis2 =
    extensions.util_screenshotCreator_thumbnailConfig.getReferenceAxes(vehicle, context.configName, bb)
  cameraAxis0 = cameraAxis0 or axis0
  cameraAxis1 = cameraAxis1 or axis1
  cameraAxis2 = cameraAxis2 or axis2

  local configKey = extensions.util_screenshotCreator_nodeOutpaint.getVehicleOutpaintKey(vehicle, context.configName)
  local disabledNodeMap = extensions.util_screenshotCreator_nodeOutpaint.getDisabledNodes(configKey)
  local allNodes = extensions.util_screenshotCreator_nodeOutpaint.getVehicleNodeData(vehicle)
  local enabledNodes = {}
  local disabledNodes = {}
  local belowGroundNodes = {}
  local mirrorNodes = {}
  local rotationNodes = {}
  local groundHeight = extensions.util_screenshotCreator_vehicleSetup.getFloorHeight(bb)

  for _, node in ipairs(allNodes) do
    node.disabled = disabledNodeMap[node.key] ~= nil or node.ignoreForThumbnailFraming
    addRotationNode(rotationNodes, node)
    if node.disabled then
      disabledNodes[#disabledNodes + 1] = node
    elseif node.point.z < groundHeight then
      node.belowGround = true
      belowGroundNodes[#belowGroundNodes + 1] = node
    elseif node.automaticMirrorOutpaint then
      mirrorNodes[#mirrorNodes + 1] = node
    else
      enabledNodes[#enabledNodes + 1] = node
    end
  end

  local bounds = getBoundsFromNodes(enabledNodes, axis0, axis1, axis2)
  local emptyEnabledNodes = bounds == nil
  if not bounds then
    local fallbackNodes = {}
    for index = 0, 7 do
      local point = bb:getPoint(index)
      if point.z >= groundHeight then
        fallbackNodes[#fallbackNodes + 1] = {point = point}
      end
    end
    bounds = getBoundsFromNodes(fallbackNodes, axis0, axis1, axis2)
  end
  if not bounds then
    return nil, "No above-ground framing points"
  end

  local halfExtents = bounds.halfExtents
  local cameraOffsetLocal = vec3(-0.75, -0.66, 0.07):normalized()
  local cameraOffset = (
    cameraAxis0 * cameraOffsetLocal.x
    + cameraAxis1 * cameraOffsetLocal.y
    + cameraAxis2 * cameraOffsetLocal.z
  ):normalized()
  local axisDownOffset = tonumber(context.cameraAxisDownOffset) or cameraAxisDownOffset
  local cameraAxisCenter = bounds.center - cameraAxis2 * axisDownOffset
  local lookAtPoint = cameraAxisCenter - cameraAxis1 * halfExtents.y / 8
  local cameraRotation = quatFromDir(-cameraOffset, cameraAxis2)
  local cameraRailDirection = vec3(cameraOffset.x, cameraOffset.y, 0)
  if cameraRailDirection:length() < 0.0001 then
    cameraRailDirection = vec3(-cameraAxis1.x, -cameraAxis1.y, 0)
  end
  cameraRailDirection:normalize()

  local cameraHeight = tonumber(context.cameraHeight) or defaultCameraHeight
  local cameraRailOrigin = vec3(lookAtPoint.x, lookAtPoint.y, groundHeight + cameraHeight)
  local axes = {axis0, axis1, axis2}
  local extentNodes
  if emptyEnabledNodes then
    extentNodes = {}
    for _, point in ipairs(bounds.corners) do
      extentNodes[#extentNodes + 1] = {point = point, name = "fallback bound"}
    end
  else
    extentNodes = selectExtentNodes(enabledNodes, axes)
  end

  local framingPoints = {}
  for _, node in ipairs(extentNodes) do
    framingPoints[#framingPoints + 1] = {
      cid = node.cid,
      name = node.name or "extent",
      point = node.point,
      color = {0.2, 0.8, 1},
    }
  end
  local rotationPoints = getRotationPoints(rotationNodes, axes, framingPoints)

  local framingData = {
    bb = bb,
    boundsCorners = bounds.corners,
    center = bounds.center,
    camAxisCenter = cameraAxisCenter,
    axis0 = axis0,
    axis1 = axis1,
    axis2 = axis2,
    halfExtents = halfExtents,
    camOffsetAxis = cameraOffset,
    lookAtPoint = lookAtPoint,
    cameraRailDirection = cameraRailDirection,
    cameraRailOrigin = cameraRailOrigin,
    configKey = configKey,
    allNodes = allNodes,
    disabledNodes = disabledNodes,
    belowGroundNodes = belowGroundNodes,
    mirrorNodes = mirrorNodes,
    mirrorFramingPoints = mirrorNodes,
    groundHeight = groundHeight,
    emptyEnabledNodes = emptyEnabledNodes,
    framingPoints = framingPoints,
    rotationPoints = rotationPoints,
  }
  applyCameraRotation(framingData, cameraRotation)
  return framingData
end

local function getMargin(context, resolution)
  local useMargins = context.useFramingMargins
  if useMargins == nil then useMargins = context.useMargins end
  if useMargins ~= true then return zeroMargin end
  if type(context.margin) == "table" then return context.margin end

  local settingsExtension = extensions.util_screenshotCreator_settings
  if settingsExtension and settingsExtension.getFramingMargin then
    return settingsExtension.getFramingMargin(resolution) or zeroMargin
  end
  return zeroMargin
end

local function getProjectionBounds(fov, aspectRatio, resolution, margin)
  local width = resolution[1]
  local height = resolution[2]
  local halfVerticalTan = math.tan(math.rad(fov) * 0.5)
  local halfHorizontalTan = halfVerticalTan * aspectRatio

  return {
    xMin = ((margin.left or 0) / width * 2 - 1) * halfHorizontalTan,
    xMax = ((width - (margin.right or 0)) / width * 2 - 1) * halfHorizontalTan,
    yMin = ((margin.bottom or 0) / height * 2 - 1) * halfVerticalTan,
    yMax = (1 - (margin.top or 0) / height * 2) * halfVerticalTan,
  }
end

local function getDirectionFromYawPitch(yaw, pitch)
  local cosPitch = math.cos(pitch)
  return vec3(math.sin(yaw) * cosPitch, math.cos(yaw) * cosPitch, math.sin(pitch))
end

local function optimizeCameraRotation(framingData, cameraPosition, bounds)
  local toTarget = framingData.lookAtPoint - cameraPosition
  local yaw = math.atan2(toTarget.x, toTarget.y)
  local pitch = math.atan2(toTarget.z, math.sqrt(toTarget.x * toTarget.x + toTarget.y * toTarget.y))
  local targetXCenter = (math.atan(bounds.xMin) + math.atan(bounds.xMax)) * 0.5
  local targetYCenter = (math.atan(bounds.yMin) + math.atan(bounds.yMax)) * 0.5
  local worldUp = vec3(0, 0, 1)

  for _ = 1, 12 do
    local cameraRotation = quatFromDir(getDirectionFromYawPitch(yaw, pitch), worldUp)
    local cameraRight = cameraRotation * vec3(1, 0, 0)
    local cameraForward = cameraRotation * vec3(0, 1, 0)
    local cameraUp = cameraRotation * vec3(0, 0, 1)
    local xMin, xMax = math.huge, -math.huge
    local yMin, yMax = math.huge, -math.huge

    for _, point in ipairs(framingData.rotationPoints or framingData.framingPoints) do
      local toPoint = point.point - cameraPosition
      local depth = toPoint:dot(cameraForward)
      if depth <= 0 then return cameraRotation end
      local xAngle = math.atan2(toPoint:dot(cameraRight), depth)
      local yAngle = math.atan2(toPoint:dot(cameraUp), depth)
      xMin = math.min(xMin, xAngle)
      xMax = math.max(xMax, xAngle)
      yMin = math.min(yMin, yAngle)
      yMax = math.max(yMax, yAngle)
    end

    yaw = yaw + (xMin + xMax) * 0.5 - targetXCenter
    pitch = clamp(pitch + (yMin + yMax) * 0.5 - targetYCenter, -math.pi * 0.49, math.pi * 0.49)
  end

  return quatFromDir(getDirectionFromYawPitch(yaw, pitch), worldUp)
end

local function pointsFit(points, cameraPosition, cameraRight, cameraForward, cameraUp, bounds, nearPlane)
  local epsilon = 0.000001
  for _, point in ipairs(points) do
    local toPoint = point.point - cameraPosition
    local depth = toPoint:dot(cameraForward)
    if depth <= nearPlane then return false end
    local screenX = toPoint:dot(cameraRight) / depth
    local screenY = toPoint:dot(cameraUp) / depth
    if screenX < bounds.xMin - epsilon or screenX > bounds.xMax + epsilon
      or screenY < bounds.yMin - epsilon or screenY > bounds.yMax + epsilon
    then
      return false
    end
  end
  return true
end

local function getFitAtDistance(framingData, bounds, distance, nearPlane, fixedRotation)
  local cameraPosition = framingData.cameraRailOrigin + framingData.cameraRailDirection * distance
  local cameraRotation = fixedRotation or optimizeCameraRotation(framingData, cameraPosition, bounds)
  local cameraRight = cameraRotation * vec3(1, 0, 0)
  local cameraForward = cameraRotation * vec3(0, 1, 0)
  local cameraUp = cameraRotation * vec3(0, 0, 1)
  if not pointsFit(
    framingData.framingPoints,
    cameraPosition,
    cameraRight,
    cameraForward,
    cameraUp,
    bounds,
    nearPlane
  ) then return nil end
  if not pointsFit(
    framingData.mirrorFramingPoints or {},
    cameraPosition,
    cameraRight,
    cameraForward,
    cameraUp,
    framingData.mirrorProjectionBounds or bounds,
    nearPlane
  ) then return nil end

  return {distance = distance, position = cameraPosition, rotation = cameraRotation}
end

local function solveCameraFit(framingData, bounds, nearPlane, fixedRotation)
  if fixedRotation then
    local fixedForward = fixedRotation * vec3(0, 1, 0)
    local railDirection = vec3(-fixedForward.x, -fixedForward.y, 0)
    if railDirection:length() >= 0.0001 then
      railDirection:normalize()
      framingData.cameraRailDirection = railDirection
    end
  end

  local lowDistance = 0.01
  local highDistance = math.max(framingData.halfExtents:length() * 2, 1)
  local fit = getFitAtDistance(framingData, bounds, highDistance, nearPlane, fixedRotation)
  local maxDistance = math.max(highDistance * 128, 1000)
  while not fit and highDistance < maxDistance do
    lowDistance = highDistance
    highDistance = highDistance * 2
    fit = getFitAtDistance(framingData, bounds, highDistance, nearPlane, fixedRotation)
  end
  if not fit then return nil end

  for _ = 1, 32 do
    local testDistance = (lowDistance + highDistance) * 0.5
    local testFit = getFitAtDistance(framingData, bounds, testDistance, nearPlane, fixedRotation)
    if testFit then
      highDistance = testDistance
      fit = testFit
    else
      lowDistance = testDistance
    end
  end
  return getFitAtDistance(framingData, bounds, highDistance, nearPlane, fixedRotation) or fit
end

local function addProjectedClearance(framingData, cameraPosition, fov, aspectRatio, resolution, margin)
  local halfHeightFactor = math.tan(math.rad(fov) * 0.5)
  local lowestClearancePoint

  for _, point in ipairs(framingData.framingPoints) do
    local toPoint = point.point - cameraPosition
    local depth = toPoint:dot(framingData.camForward)
    local halfHeight = halfHeightFactor * depth
    local halfWidth = halfHeight * aspectRatio
    if depth > 0 and halfWidth > 0 and halfHeight > 0 then
      local screenX = (toPoint:dot(framingData.camRight) / halfWidth + 1) * 0.5 * resolution[1]
      local screenY = (1 - toPoint:dot(framingData.camUp) / halfHeight) * 0.5 * resolution[2]
      local clearances = {
        {side = "left", value = screenX - (margin.left or 0)},
        {side = "right", value = resolution[1] - (margin.right or 0) - screenX},
        {side = "top", value = screenY - (margin.top or 0)},
        {side = "bottom", value = resolution[2] - (margin.bottom or 0) - screenY},
      }
      local closest = clearances[1]
      for index = 2, #clearances do
        if clearances[index].value < closest.value then closest = clearances[index] end
      end

      point.marginDistance = closest.value
      point.marginDistanceSide = closest.side
      point.screenX = screenX
      point.screenY = screenY
      point.framingDistance = depth
      if not lowestClearancePoint or point.marginDistance < lowestClearancePoint.marginDistance then
        lowestClearancePoint = point
      end
    end
  end

  return lowestClearancePoint and lowestClearancePoint.marginDistanceSide or "fallback"
end

local function resolve(context)
  if type(context) ~= "table" or not context.vehicle then
    return nil, "Procedural framing requires context.vehicle"
  end
  if not selfChecked then
    selfCheck()
    selfChecked = true
  end

  local resolution = context.resolution or defaultResolution
  local width = tonumber(resolution[1])
  local height = tonumber(resolution[2])
  if not width or not height or width <= 0 or height <= 0 then
    return nil, "Procedural framing requires a positive resolution"
  end
  resolution = {width, height}

  local fov = tonumber(context.fov or context.fieldOfView) or defaultFov
  if fov <= 0 or fov >= 180 then return nil, "Procedural framing requires 0 < fov < 180" end
  local nearPlane = tonumber(context.nearPlane) or defaultNearPlane
  local aspectRatio = tonumber(context.aspectRatio) or width / height
  if nearPlane < 0 or aspectRatio <= 0 then
    return nil, "Procedural framing requires a non-negative nearPlane and positive aspectRatio"
  end

  local framingData, framingError = getVehicleFramingData(context)
  if not framingData then return nil, framingError end
  local margin = getMargin(context, resolution)
  local projectionBounds = getProjectionBounds(fov, aspectRatio, resolution, margin)
  local mirrorMargin = {
    left = mirrorFrameMarginPixels,
    right = mirrorFrameMarginPixels,
    top = mirrorFrameMarginPixels,
    bottom = mirrorFrameMarginPixels
  }
  framingData.mirrorMargin = mirrorMargin
  framingData.mirrorProjectionBounds = getProjectionBounds(
    fov,
    aspectRatio,
    resolution,
    mirrorMargin
  )
  local fit = solveCameraFit(framingData, projectionBounds, nearPlane, context.fixedRotation)
  local finalCameraPosition

  if fit then
    finalCameraPosition = fit.position
    applyCameraRotation(framingData, fit.rotation)
  else
    local fallbackDistance = math.max(1, framingData.halfExtents:length() * 2)
    finalCameraPosition = framingData.cameraRailOrigin + framingData.cameraRailDirection * fallbackDistance
    local fallbackRotation = context.fixedRotation
      or optimizeCameraRotation(framingData, finalCameraPosition, projectionBounds)
    applyCameraRotation(framingData, fallbackRotation)
    fit = {
      distance = fallbackDistance,
      position = finalCameraPosition,
      rotation = fallbackRotation,
    }
  end

  framingData.finalCamPos = finalCameraPosition
  framingData.finalCamRot = framingData.camRot
  framingData.boundBy = addProjectedClearance(
    framingData,
    finalCameraPosition,
    fov,
    aspectRatio,
    resolution,
    margin
  )
  framingData.fit = fit
  framingData.margin = margin
  framingData.projectionBounds = projectionBounds

  return {
    pos = finalCameraPosition,
    rot = framingData.camRot,
    name = "procedural camera",
    debugData = framingData,
    framingData = framingData,
  }
end

local function onScreenshotCreatorCollectFramingModes(modes)
  modes[#modes + 1] = {
    id = "procedural",
    label = "Procedural",
    order = 100,
    supportsFixedRotation = true,
    resolve = resolve,
  }
end

M.resolve = resolve
M.frame = resolve
M.getVehicleFramingData = getVehicleFramingData
M.selfCheck = selfCheck
M.onScreenshotCreatorCollectFramingModes = onScreenshotCreatorCollectFramingModes

return M
