-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local geometry = require("editor/ezObjectSelect/selectionGeometry")

local function scaledPoint(point, scale)
  return vec3(point.x * scale.x, point.y * scale.y, point.z * scale.z)
end

local function localPatterns(box, scale)
  local extents = box:getExtents()
  local center = box:getCenter()
  local scaledX = math.abs(extents.x * scale.x)
  local scaledY = math.abs(extents.y * scale.y)
  local isLongX = scaledX >= scaledY

  local shortFirst, shortSecond, longFirst, longSecond
  if isLongX then
    shortFirst = vec3(box.minExtents.x, center.y, box.minExtents.z)
    shortSecond = vec3(box.maxExtents.x, center.y, box.minExtents.z)
    longFirst = vec3(center.x, box.minExtents.y, box.minExtents.z)
    longSecond = vec3(center.x, box.maxExtents.y, box.minExtents.z)
  else
    shortFirst = vec3(center.x, box.minExtents.y, box.minExtents.z)
    shortSecond = vec3(center.x, box.maxExtents.y, box.minExtents.z)
    longFirst = vec3(box.minExtents.x, center.y, box.minExtents.z)
    longSecond = vec3(box.maxExtents.x, center.y, box.minExtents.z)
  end

  local shortOriginFirst = vec3(shortFirst.x, shortFirst.y, 0)
  local shortOriginSecond = vec3(shortSecond.x, shortSecond.y, 0)
  return {
    isLongX = isLongX,
    scaledX = scaledX,
    scaledY = scaledY,
    shortEdge = {
      firstLocal = scaledPoint(shortFirst, scale),
      secondLocal = scaledPoint(shortSecond, scale)
    },
    longEdge = {
      firstLocal = scaledPoint(longFirst, scale),
      secondLocal = scaledPoint(longSecond, scale)
    },
    shortEdgeOrigin = {
      firstLocal = scaledPoint(shortOriginFirst, scale),
      secondLocal = scaledPoint(shortOriginSecond, scale)
    }
  }
end

function M.describeBox(box, scale)
  if not geometry.validBox(box) then return nil end
  return localPatterns(box, scale or vec3(1, 1, 1))
end

function M.describeMeshBox(meshBox, scale)
  if not meshBox
    or not meshBox.minExtents
    or not meshBox.maxExtents
    or not meshBox.center
    or not meshBox.extents then
    return nil
  end
  local box = {
    minExtents = meshBox.minExtents,
    maxExtents = meshBox.maxExtents
  }
  function box:getCenter() return meshBox.center end
  function box:getExtents() return meshBox.extents end
  return localPatterns(box, scale or vec3(1, 1, 1))
end

local function worldPattern(pattern, transform, originPosition)
  local first = vec3(transform:mulP3F(pattern.firstLocal))
  local second = vec3(transform:mulP3F(pattern.secondLocal))
  return {
    first = first,
    second = second,
    firstOffset = first - originPosition,
    secondOffset = second - originPosition,
    centerOffset = (first + second) * 0.5 - originPosition
  }
end

function M.describeObject(obj)
  if not obj or not obj.getPosition then return nil end
  local originPosition = vec3(obj:getPosition())
  if obj.getObjBox and obj.getTransform and obj.getScale then
    local localDescription = M.describeBox(obj:getObjBox(), obj:getScale())
    if localDescription then
      local transform = obj:getTransform()
      return {
        isLongX = localDescription.isLongX,
        scaledX = localDescription.scaledX,
        scaledY = localDescription.scaledY,
        shortEdge = worldPattern(localDescription.shortEdge, transform, originPosition),
        longEdge = worldPattern(localDescription.longEdge, transform, originPosition),
        shortEdgeOrigin = worldPattern(
          localDescription.shortEdgeOrigin,
          transform,
          originPosition)
      }
    end
  end

  local worldBox = obj.getWorldBox and obj:getWorldBox() or nil
  if not geometry.validBox(worldBox) then return nil end
  local center = worldBox:getCenter()
  local extents = worldBox:getExtents()
  local isLongX = extents.x >= extents.y
  local shortFirst, shortSecond, longFirst, longSecond
  if isLongX then
    shortFirst = vec3(worldBox.minExtents.x, center.y, worldBox.minExtents.z)
    shortSecond = vec3(worldBox.maxExtents.x, center.y, worldBox.minExtents.z)
    longFirst = vec3(center.x, worldBox.minExtents.y, worldBox.minExtents.z)
    longSecond = vec3(center.x, worldBox.maxExtents.y, worldBox.minExtents.z)
  else
    shortFirst = vec3(center.x, worldBox.minExtents.y, worldBox.minExtents.z)
    shortSecond = vec3(center.x, worldBox.maxExtents.y, worldBox.minExtents.z)
    longFirst = vec3(worldBox.minExtents.x, center.y, worldBox.minExtents.z)
    longSecond = vec3(worldBox.maxExtents.x, center.y, worldBox.minExtents.z)
  end
  local function fallbackPattern(first, second)
    return {
      first = first,
      second = second,
      firstOffset = first - originPosition,
      secondOffset = second - originPosition,
      centerOffset = (first + second) * 0.5 - originPosition
    }
  end
  local originDelta = originPosition.z - worldBox.minExtents.z
  return {
    isLongX = isLongX,
    scaledX = extents.x,
    scaledY = extents.y,
    shortEdge = fallbackPattern(shortFirst, shortSecond),
    longEdge = fallbackPattern(longFirst, longSecond),
    shortEdgeOrigin = fallbackPattern(
      shortFirst + vec3(0, 0, originDelta),
      shortSecond + vec3(0, 0, originDelta))
  }
end

return M
