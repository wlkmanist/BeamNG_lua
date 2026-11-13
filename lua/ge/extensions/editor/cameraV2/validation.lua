-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Bad raycasts or camera math can produce NaN or extreme coordinates that make
-- the editor camera difficult to recover. These shared checks reject unsafe
-- positions and rotations before Camera V2 applies them.

local M = {}

local worldCoordinateLimit = 10000000
local terrainHeightLimit = 1000000

function M.isFinite(value)
  return type(value) == "number"
    and value == value
    and value > -math.huge
    and value < math.huge
end

function M.isValidCoordinate(value)
  return M.isFinite(value)
end

function M.isValidXY(point)
  return point
    and M.isValidCoordinate(point.x)
    and M.isValidCoordinate(point.y)
end

function M.isValidPoint(point)
  return M.isValidXY(point) and M.isValidCoordinate(point.z)
end

function M.isReasonableCoordinate(value)
  return M.isFinite(value) and math.abs(value) <= worldCoordinateLimit
end

function M.isReasonableXY(point)
  return point
    and M.isReasonableCoordinate(point.x)
    and M.isReasonableCoordinate(point.y)
end

function M.isReasonablePoint(point)
  return M.isReasonableXY(point) and M.isReasonableCoordinate(point.z)
end

function M.isValidQuaternion(rotation)
  if not rotation
    or not M.isFinite(rotation.x)
    or not M.isFinite(rotation.y)
    or not M.isFinite(rotation.z)
    or not M.isFinite(rotation.w) then
    return false
  end
  local lengthSquared = rotation.x * rotation.x
    + rotation.y * rotation.y
    + rotation.z * rotation.z
    + rotation.w * rotation.w
  return M.isFinite(lengthSquared)
    and lengthSquared >= 0.25
    and lengthSquared <= 2.25
end

function M.isValidTerrainHeight(value)
  return M.isFinite(value) and math.abs(value) <= terrainHeightLimit
end

function M.terrainHeightAt(point)
  if not M.isReasonableXY(point) then return nil end
  local height = core_terrain.getTerrainHeight(vec3(point.x, point.y, 0))
  return M.isValidTerrainHeight(height) and height or nil
end

function M.isPointOnRaySegment(point, origin, direction, maximumDistance)
  if not M.isValidPoint(point)
    or not M.isValidPoint(origin)
    or not M.isValidPoint(direction)
    or not M.isFinite(maximumDistance)
    or maximumDistance < 0 then
    return false
  end
  local rayDirection = vec3(direction)
  if rayDirection:length() <= 0.0001 then return false end
  rayDirection:normalize()
  local delta = vec3(point) - vec3(origin)
  local projection = delta:dot(rayDirection)
  if not M.isFinite(projection)
    or projection < -0.01
    or projection > maximumDistance + 0.01 then
    return false
  end
  local perpendicularDistance = (delta - rayDirection * projection):length()
  return M.isFinite(perpendicularDistance) and perpendicularDistance <= 1
end

function M.worldCoordinateLimit()
  return worldCoordinateLimit
end

return M
