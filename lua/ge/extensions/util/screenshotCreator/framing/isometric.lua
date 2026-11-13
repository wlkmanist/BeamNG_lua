-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "util_screenshotCreator_thumbnailConfig",
  "util_screenshotCreator_framing_procedural"
}

local fixedDistance = 15
local cameraOffsetLocal = vec3(-1, -1, 0.75):normalized()
local defaultResolution = {500, 281}
local defaultFov = 20

local function applyCameraRotation(framingData, rotation)
  framingData.camRot = rotation
  framingData.camRight = rotation * vec3(1, 0, 0)
  framingData.camForward = rotation * vec3(0, 1, 0)
  framingData.camUp = rotation * vec3(0, 0, 1)
end

local function getTargetProjectionCenter(context)
  local resolution = context.resolution or defaultResolution
  local width = tonumber(resolution[1]) or defaultResolution[1]
  local height = tonumber(resolution[2]) or defaultResolution[2]
  local fov = tonumber(context.fov or context.fieldOfView) or defaultFov
  local useMargins = context.useFramingMargins
  if useMargins == nil then useMargins = context.useMargins end
  local margin = useMargins and context.margin or nil
  margin = margin or {left = 0, right = 0, top = 0, bottom = 0}
  local halfVerticalTan = math.tan(math.rad(fov) * 0.5)
  local halfHorizontalTan = halfVerticalTan * width / height
  local xMin = ((margin.left or 0) / width * 2 - 1) * halfHorizontalTan
  local xMax = ((width - (margin.right or 0)) / width * 2 - 1) * halfHorizontalTan
  local yMin = ((margin.bottom or 0) / height * 2 - 1) * halfVerticalTan
  local yMax = (1 - (margin.top or 0) / height * 2) * halfVerticalTan
  return (xMin + xMax) * 0.5, (yMin + yMax) * 0.5
end

local function centerCameraOrthogonally(framingData, cameraPosition, context)
  local targetX, targetY = getTargetProjectionCenter(context)
  local totalRightOffset = 0
  local totalUpOffset = 0

  for _ = 1, 8 do
    local xMin, xMax = math.huge, -math.huge
    local yMin, yMax = math.huge, -math.huge
    local xMinDepth, xMaxDepth
    local yMinDepth, yMaxDepth

    for _, framingPoint in ipairs(framingData.framingPoints) do
      local toPoint = framingPoint.point - cameraPosition
      local depth = toPoint:dot(framingData.camForward)
      if depth > 0.0001 then
        local screenX = toPoint:dot(framingData.camRight) / depth
        local screenY = toPoint:dot(framingData.camUp) / depth
        if screenX < xMin then xMin, xMinDepth = screenX, depth end
        if screenX > xMax then xMax, xMaxDepth = screenX, depth end
        if screenY < yMin then yMin, yMinDepth = screenY, depth end
        if screenY > yMax then yMax, yMaxDepth = screenY, depth end
      end
    end

    if not xMinDepth or not xMaxDepth or not yMinDepth or not yMaxDepth then break end
    local rightOffset = (xMin + xMax - targetX * 2) / (1 / xMinDepth + 1 / xMaxDepth)
    local upOffset = (yMin + yMax - targetY * 2) / (1 / yMinDepth + 1 / yMaxDepth)
    cameraPosition = cameraPosition
      + framingData.camRight * rightOffset
      + framingData.camUp * upOffset
    totalRightOffset = totalRightOffset + rightOffset
    totalUpOffset = totalUpOffset + upOffset

    if math.abs(rightOffset) < 0.0001 and math.abs(upOffset) < 0.0001 then break end
  end

  return cameraPosition, totalRightOffset, totalUpOffset
end

local function resolve(context)
  if type(context) ~= "table" or not context.vehicle then
    return nil, "Fixed isometric framing requires context.vehicle"
  end

  local vehicle = context.vehicle
  local framingData = util_screenshotCreator_framing_procedural.getVehicleFramingData(context)
  local axis0, axis1, axis2 = util_screenshotCreator_thumbnailConfig.getReferenceAxes(
    vehicle,
    context.configName,
    framingData.bb
  )
  local cameraOffset = (
    axis0 * cameraOffsetLocal.x
    + axis1 * cameraOffsetLocal.y
    + axis2 * cameraOffsetLocal.z
  ):normalized()
  local cameraPosition = framingData.center + cameraOffset * fixedDistance
  local cameraRotation = quatFromDir(framingData.center - cameraPosition, axis2)

  applyCameraRotation(framingData, cameraRotation)
  local rightOffset, upOffset
  cameraPosition, rightOffset, upOffset = centerCameraOrthogonally(
    framingData,
    cameraPosition,
    context
  )
  framingData.camAxisCenter = framingData.center
  framingData.lookAtPoint = framingData.center
  framingData.camOffsetAxis = cameraOffset
  framingData.finalCamPos = cameraPosition
  framingData.finalCamRot = cameraRotation
  framingData.boundBy = "fixed distance"
  framingData.fit = {
    distance = fixedDistance,
    offsetX = rightOffset,
    offsetY = upOffset,
    position = cameraPosition,
    rotation = cameraRotation
  }

  return {
    pos = cameraPosition,
    rot = cameraRotation,
    name = "fixed isometric camera",
    debugData = framingData,
    framingData = framingData
  }
end

local function onScreenshotCreatorCollectFramingModes(modes)
  modes[#modes + 1] = {
    id = "fixedIsometric",
    label = "Fixed isometric",
    order = 150,
    fixedDistance = fixedDistance,
    supportsFixedRotation = false,
    resolve = resolve
  }
end

M.resolve = resolve
M.frame = resolve
M.onScreenshotCreatorCollectFramingModes = onScreenshotCreatorCollectFramingModes

return M
