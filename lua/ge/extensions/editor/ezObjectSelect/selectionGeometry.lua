-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local epsilon = 0.000001
local boxEdges = {
  {1, 2}, {1, 3}, {1, 5},
  {2, 4}, {2, 6},
  {3, 4}, {3, 7},
  {4, 8},
  {5, 6}, {5, 7},
  {6, 8},
  {7, 8}
}

local function finite(value)
  return value == value and math.abs(value) < 1e10
end

function M.validBox(box)
  if not box or not box.minExtents or not box.maxExtents then return false end
  local mn, mx = box.minExtents, box.maxExtents
  return finite(mn.x) and finite(mn.y) and finite(mn.z)
    and finite(mx.x) and finite(mx.y) and finite(mx.z)
    and mn.x <= mx.x and mn.y <= mx.y and mn.z <= mx.z
end

local function boxCorners(minimum, maximum)
  return {
    vec3(minimum.x, minimum.y, minimum.z),
    vec3(maximum.x, minimum.y, minimum.z),
    vec3(minimum.x, maximum.y, minimum.z),
    vec3(maximum.x, maximum.y, minimum.z),
    vec3(minimum.x, minimum.y, maximum.z),
    vec3(maximum.x, minimum.y, maximum.z),
    vec3(minimum.x, maximum.y, maximum.z),
    vec3(maximum.x, maximum.y, maximum.z)
  }
end

local function boxSignature(signatureType, box, result)
  if not M.validBox(box) then return nil end
  result = result or {}
  table.clear(result)
  local mn, mx = box.minExtents, box.maxExtents
  result[1] = signatureType
  result[2], result[3], result[4] = mn.x, mn.y, mn.z
  result[5], result[6], result[7] = mx.x, mx.y, mx.z
  return result
end

function M.getBoundsSignature(obj, result)
  if obj.isSubClassOf and obj:isSubClassOf("BeamNGVehicle") then
    return obj.getWorldBox and boxSignature("vehicleWorldAabb", obj:getWorldBox(), result) or nil
  end

  if obj.getObjBox and obj.getTransform and obj.getScale then
    local objectBox = obj:getObjBox()
    if M.validBox(objectBox) then
      local transform = obj:getTransform()
      local scale = obj:getScale()
      local signature = result or {}
      table.clear(signature)
      signature[1] = "oriented"
      for columnIndex = 0, 3 do
        local column = transform:getColumn(columnIndex)
        signature[#signature + 1] = column.x
        signature[#signature + 1] = column.y
        signature[#signature + 1] = column.z
      end
      signature[#signature + 1] = scale.x
      signature[#signature + 1] = scale.y
      signature[#signature + 1] = scale.z
      local mn, mx = objectBox.minExtents, objectBox.maxExtents
      signature[#signature + 1] = mn.x
      signature[#signature + 1] = mn.y
      signature[#signature + 1] = mn.z
      signature[#signature + 1] = mx.x
      signature[#signature + 1] = mx.y
      signature[#signature + 1] = mx.z
      return signature
    end
  end

  return obj.getWorldBox and boxSignature("worldAabb", obj:getWorldBox(), result) or nil
end

function M.boundsSignaturesEqual(first, second)
  if not first or not second or #first ~= #second then return false end
  for index, value in ipairs(first) do
    if value ~= second[index] then return false end
  end
  return true
end

function M.createCameraContext()
  local position = core_camera.getPosition()
  local rotation = core_camera.getQuat()
  local fov = core_camera.getFovRad and core_camera.getFovRad() or nil
  local viewport = im.GetMainViewport()
  local frustum = Engine.sceneGetCameraFrustum()
  if not position or not rotation or not fov or not viewport or not frustum then return nil end

  local width, height = viewport.Size.x, viewport.Size.y
  if width <= 0 or height <= 0 then return nil end
  local cameraRotation = quat(rotation)
  local cameraPosition = vec3(position)
  local cameraForward = cameraRotation * vec3(0, 1, 0)
  local rangeOrigin = vec3(cameraPosition)
  local rangeHit = Engine.castRay(
    cameraPosition,
    cameraPosition + cameraForward * 5000,
    true,
    false)
  if rangeHit then
    rangeOrigin = vec3(rangeHit.pt)
  else
    local terrainHeight = core_terrain.getTerrainHeight(rangeOrigin)
    if terrainHeight then
      rangeOrigin.z = terrainHeight
    else
      local hit = Engine.castRay(
        cameraPosition,
        cameraPosition - vec3(0, 0, 5000),
        true,
        false)
      if hit then rangeOrigin = vec3(hit.pt) end
    end
  end
  return {
    pos = cameraPosition,
    rangeOrigin = rangeOrigin,
    right = cameraRotation * vec3(1, 0, 0),
    forward = cameraForward,
    up = cameraRotation * vec3(0, 0, 1),
    halfTan = math.tan(fov * 0.5),
    aspect = width / height,
    width = width,
    height = height,
    viewportX = viewport.Pos.x,
    viewportY = viewport.Pos.y,
    nearDistance = math.max(frustum:getNearDist() or 0.01, 0.001)
  }
end

local function worldCornersForObject(obj)
  if obj.isSubClassOf and obj:isSubClassOf("BeamNGVehicle") then
    local worldBox = obj.getWorldBox and obj:getWorldBox() or nil
    if M.validBox(worldBox) then
      return boxCorners(worldBox.minExtents, worldBox.maxExtents), "vehicleWorldAabb"
    end
  end

  if obj.getObjBox and obj.getTransform and obj.getScale then
    local objectBox = obj:getObjBox()
    if M.validBox(objectBox) then
      local transform = obj:getTransform()
      local scale = obj:getScale()
      local localCorners = boxCorners(objectBox.minExtents, objectBox.maxExtents)
      local worldCorners = {}
      for index, point in ipairs(localCorners) do
        local scaled = vec3(point.x * scale.x, point.y * scale.y, point.z * scale.z)
        worldCorners[index] = vec3(transform:mulP3F(scaled))
      end
      return worldCorners, "oriented"
    end
  end

  if obj.getWorldBox then
    local worldBox = obj:getWorldBox()
    if M.validBox(worldBox) then
      return boxCorners(worldBox.minExtents, worldBox.maxExtents), "worldAabb"
    end
  end
  return nil, "invalidBounds"
end

function M.getWorldCorners(obj)
  return worldCornersForObject(obj)
end

function M.getObjectVolume(obj)
  if not obj then return nil end
  local box, scale
  if obj.isSubClassOf and obj:isSubClassOf("BeamNGVehicle") then
    box = obj.getWorldBox and obj:getWorldBox() or nil
  elseif obj.getObjBox and obj.getTransform and obj.getScale then
    local objectBox = obj:getObjBox()
    if M.validBox(objectBox) then
      box = objectBox
      scale = obj:getScale()
    else
      box = obj.getWorldBox and obj:getWorldBox() or nil
    end
  else
    box = obj.getWorldBox and obj:getWorldBox() or nil
  end
  if not M.validBox(box) then return nil end

  local minimum, maximum = box.minExtents, box.maxExtents
  local x = maximum.x - minimum.x
  local y = maximum.y - minimum.y
  local z = maximum.z - minimum.z
  if scale then
    x = x * math.abs(scale.x)
    y = y * math.abs(scale.y)
    z = z * math.abs(scale.z)
  end
  local volume = x * y * z
  return volume == volume and volume >= 0 and volume < math.huge and volume or nil
end

local function orientedBoxFromCorners(corners)
  local center = vec3(0, 0, 0)
  for _, corner in ipairs(corners) do center = center + corner end
  center = center / #corners

  local vectors = {
    corners[2] - corners[1],
    corners[3] - corners[1],
    corners[5] - corners[1]
  }
  local axes, halfExtents = {}, {}
  for index, vector in ipairs(vectors) do
    local length = vector:length()
    if length <= epsilon then return nil end
    axes[index] = vector / length
    halfExtents[index] = length * 0.5
  end
  return {center = center, axes = axes, halfExtents = halfExtents}
end

local function cameraDepth(point, camera)
  return (point - camera.pos):dot(camera.forward)
end

local function projectPoint(point, camera)
  local relative = point - camera.pos
  local depth = relative:dot(camera.forward)
  if depth < camera.nearDistance - epsilon then return nil end
  local x = relative:dot(camera.right) / (depth * camera.halfTan * camera.aspect)
  local y = relative:dot(camera.up) / (depth * camera.halfTan)
  return {x = (x + 1) * 0.5 * camera.width, y = (1 - y) * 0.5 * camera.height}
end

local function clippedProjectionPoints(corners, camera)
  local depths = {}
  local worldPoints = {}
  for index, corner in ipairs(corners) do
    local depth = cameraDepth(corner, camera)
    depths[index] = depth
    if depth >= camera.nearDistance then worldPoints[#worldPoints + 1] = corner end
  end

  for _, edge in ipairs(boxEdges) do
    local firstIndex, secondIndex = edge[1], edge[2]
    local firstDepth, secondDepth = depths[firstIndex], depths[secondIndex]
    if (firstDepth < camera.nearDistance) ~= (secondDepth < camera.nearDistance) then
      local amount = (camera.nearDistance - firstDepth) / (secondDepth - firstDepth)
      worldPoints[#worldPoints + 1] = corners[firstIndex]
        + (corners[secondIndex] - corners[firstIndex]) * amount
    end
  end

  local projected = {}
  for _, point in ipairs(worldPoints) do
    local screenPoint = projectPoint(point, camera)
    if screenPoint then projected[#projected + 1] = screenPoint end
  end
  return projected
end

local function cross2d(origin, first, second)
  return (first.x - origin.x) * (second.y - origin.y)
    - (first.y - origin.y) * (second.x - origin.x)
end

local function convexHull(points)
  if #points < 3 then return nil end
  table.sort(points, function(first, second)
    if math.abs(first.x - second.x) > epsilon then return first.x < second.x end
    return first.y < second.y
  end)

  local unique = {}
  for _, point in ipairs(points) do
    local previous = unique[#unique]
    if not previous or math.abs(point.x - previous.x) > epsilon
      or math.abs(point.y - previous.y) > epsilon then
      unique[#unique + 1] = point
    end
  end
  if #unique < 3 then return nil end

  local lower = {}
  for _, point in ipairs(unique) do
    while #lower >= 2 and cross2d(lower[#lower - 1], lower[#lower], point) <= epsilon do
      table.remove(lower)
    end
    lower[#lower + 1] = point
  end

  local upper = {}
  for index = #unique, 1, -1 do
    local point = unique[index]
    while #upper >= 2 and cross2d(upper[#upper - 1], upper[#upper], point) <= epsilon do
      table.remove(upper)
    end
    upper[#upper + 1] = point
  end

  table.remove(lower)
  table.remove(upper)
  for _, point in ipairs(upper) do lower[#lower + 1] = point end
  return #lower >= 3 and lower or nil
end

local function polygonMetrics(polygon)
  local twiceArea = 0
  local centroidX, centroidY = 0, 0
  for index, first in ipairs(polygon) do
    local second = polygon[index % #polygon + 1]
    local cross = first.x * second.y - second.x * first.y
    twiceArea = twiceArea + cross
    centroidX = centroidX + (first.x + second.x) * cross
    centroidY = centroidY + (first.y + second.y) * cross
  end

  if math.abs(twiceArea) <= epsilon then return nil end
  local factor = 1 / (3 * twiceArea)
  return math.abs(twiceArea) * 0.5, {
    x = centroidX * factor,
    y = centroidY * factor
  }
end

local function pointInPolygon(point, polygon)
  local inside = false
  local previous = polygon[#polygon]
  for _, current in ipairs(polygon) do
    if ((current.y > point.y) ~= (previous.y > point.y))
      and point.x < (previous.x - current.x) * (point.y - current.y)
        / (previous.y - current.y) + current.x then
      inside = not inside
    end
    previous = current
  end
  return inside
end

local function pointSegmentDistance(point, first, second)
  local dx, dy = second.x - first.x, second.y - first.y
  local lengthSquared = dx * dx + dy * dy
  if lengthSquared <= epsilon then
    local px, py = point.x - first.x, point.y - first.y
    return math.sqrt(px * px + py * py)
  end
  local amount = clamp(
    ((point.x - first.x) * dx + (point.y - first.y) * dy) / lengthSquared,
    0,
    1)
  local px = point.x - (first.x + dx * amount)
  local py = point.y - (first.y + dy * amount)
  return math.sqrt(px * px + py * py)
end

local function distanceToPolygon(point, polygon)
  if pointInPolygon(point, polygon) then return 0 end
  local distance = math.huge
  for index, first in ipairs(polygon) do
    distance = math.min(distance, pointSegmentDistance(point, first, polygon[index % #polygon + 1]))
  end
  return distance
end

local function pointToOrientedBox(point, box)
  local relative = point - box.center
  local closest = vec3(box.center)
  local inside = true
  for index, axis in ipairs(box.axes) do
    local distance = relative:dot(axis)
    local extent = box.halfExtents[index]
    if math.abs(distance) > extent + epsilon then inside = false end
    closest = closest + axis * clamp(distance, -extent, extent)
  end
  return closest, inside
end

local function rayEntryDistance(origin, direction, box)
  local nearDistance, farDistance = -math.huge, math.huge
  local relative = origin - box.center
  for index, axis in ipairs(box.axes) do
    local rayOrigin = relative:dot(axis)
    local rayDirection = direction:dot(axis)
    local extent = box.halfExtents[index]
    if math.abs(rayDirection) <= epsilon then
      if rayOrigin < -extent or rayOrigin > extent then return math.huge end
    else
      local first = (-extent - rayOrigin) / rayDirection
      local second = (extent - rayOrigin) / rayDirection
      if first > second then first, second = second, first end
      nearDistance = math.max(nearDistance, first)
      farDistance = math.min(farDistance, second)
      if nearDistance > farDistance then return math.huge end
    end
  end
  if farDistance < 0 then return math.huge end
  return math.max(nearDistance, 0)
end

function M.createProjectedProxy(obj, camera, boundsSignature)
  local corners, boundsType = worldCornersForObject(obj)
  if not corners then return nil, boundsType end
  local orientedBox = orientedBoxFromCorners(corners)
  if not orientedBox then return nil, "degenerateBounds" end

  local polygon = convexHull(clippedProjectionPoints(corners, camera))
  if not polygon then return nil, "outsideNearPlane" end
  local area, centroid = polygonMetrics(polygon)
  if not area then return nil, "degenerateProjection" end

  local cameraClosestPoint, cameraInside = pointToOrientedBox(camera.pos, orientedBox)
  local rangeOrigin = camera.rangeOrigin or camera.pos
  local closestPoint = pointToOrientedBox(rangeOrigin, orientedBox)
  local volume = orientedBox.halfExtents[1]
    * orientedBox.halfExtents[2]
    * orientedBox.halfExtents[3]
    * 8
  return {
    source = obj,
    sourceId = obj:getID(),
    boundsType = boundsType,
    worldCorners = corners,
    polygon = polygon,
    area = area,
    centroid = centroid,
    cameraDistance = (rangeOrigin - closestPoint):length(),
    viewDistance = (camera.pos - cameraClosestPoint):length(),
    volume = volume,
    cameraInside = cameraInside,
    orientedBox = orientedBox,
    boundsSignature = boundsSignature or M.getBoundsSignature(obj)
  }
end

function M.updateCursorMetrics(proxy, mousePosition)
  proxy.cursorDistance = distanceToPolygon(mousePosition, proxy.polygon)
  local centerDx = mousePosition.x - proxy.centroid.x
  local centerDy = mousePosition.y - proxy.centroid.y
  proxy.centerBias = math.sqrt(centerDx * centerDx + centerDy * centerDy)
    / math.max(math.sqrt(proxy.area), 1)
  return proxy
end

function M.updateRayEntry(proxy, rayOrigin, rayDirection)
  proxy.rayEntry = rayOrigin and rayDirection
    and rayEntryDistance(rayOrigin, rayDirection, proxy.orientedBox) or math.huge
  return proxy
end

function M.createProxy(obj, camera, mousePosition, rayOrigin, rayDirection)
  local proxy, reason = M.createProjectedProxy(obj, camera)
  if not proxy then return nil, reason end
  M.updateCursorMetrics(proxy, mousePosition)
  M.updateRayEntry(proxy, rayOrigin, rayDirection)
  return proxy
end

return M
