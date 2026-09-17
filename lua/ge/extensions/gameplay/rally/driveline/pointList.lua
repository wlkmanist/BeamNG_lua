-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local snaproadNormals = require('/lua/ge/extensions/gameplay/rally/snaproad/normals')
local cc = require('/lua/ge/extensions/gameplay/rally/util/colors')

local C = {}

-- PointList represents a series of points along a path
-- Each point has: pos, quat, ts, normal, prev, next, id, pacenoteDistances, cachedPacenotes
function C:init(points)
  self.points = points or {}
end

-- Create a new point with the standard format
function C:createPoint(pos, quat, ts)
  return {
    pos = vec3(pos),
    quat = quat or quat(0, 0, 0, 1),
    ts = ts or 0,
    normal = vec3(0, 0, 1),
    prev = nil,
    next = nil,
    id = nil,
    partition = nil,
    pacenoteDistances = {},
    cachedPacenotes = {
      cs = nil,
      ce = nil,
      at = nil,
      auto_at = nil,
      half = nil,
    }
  }
end

-- Set up prev/next relationships and IDs for all points
function C:setupPointRelationships()
  for i, point in ipairs(self.points) do
    point.id = i
    if i > 1 then
      point.prev = self.points[i - 1]
    else
      point.prev = nil
    end
    if i < #self.points then
      point.next = self.points[i + 1]
    else
      point.next = nil
    end
  end
end

-- Calculate and set normals for all points
function C:setupPointNormals()
  for i, point in ipairs(self.points) do
    point.normal = snaproadNormals.forwardNormalVec(point)
    -- Ensure pacenote fields exist
    if not point.pacenoteDistances then
      point.pacenoteDistances = {}
    end
    if not point.cachedPacenotes then
      point.cachedPacenotes = {
        cs = nil,
        ce = nil,
        at = nil,
        auto_at = nil,
        half = nil,
      }
    end
  end
end

-- Calculate total length of the point list
function C:calculateLength()
  if #self.points < 2 then
    return 0
  end

  local length = 0
  for i = 1, #self.points - 1 do
    local p1 = self.points[i].pos
    local p2 = self.points[i + 1].pos
    length = length + p1:distance(p2)
  end
  return length
end

-- Get number of points
function C:count()
  return #self.points
end

-- Get point at index
function C:get(index)
  return self.points[index]
end

-- Get all points
function C:getAll()
  return self.points
end

-- Set all points (and update relationships/normals)
function C:setAll(points)
  self.points = points
  self:setupPointRelationships()
  self:setupPointNormals()
end

-- Find nearest point to a given position
function C:findNearestPoint(srcPos)
  if #self.points == 0 then
    return nil
  end

  local minDistSq = math.huge
  local closestPoint = nil

  for _, point in ipairs(self.points) do
    local distSq = (point.pos - srcPos):squaredLength()
    if distSq < minDistSq then
      minDistSq = distSq
      closestPoint = point
    end
  end

  return closestPoint
end

-- Downsample stub (for compatibility with DrivelineRoute)
-- DrivelineV3 already performs simplification, so this just returns self
function C:downsample()
  return self
end

-- Draw debug visualization of all points
function C:drawDebug(drawLabels)
  if #self.points == 0 then
    return
  end

  drawLabels = drawLabels or false

  local clr = cc.recce_driveline_clr
  local alpha_shape = 0.3
  local radius = cc.snaproads_radius_recce
  local clr_txt = cc.clr_black

  for _, point in ipairs(self.points) do
    local pos = point.pos

    debugDrawer:drawSphere(
      pos,
      radius,
      ColorF(clr[1], clr[2], clr[3], alpha_shape)
    )

    if drawLabels then
      debugDrawer:drawTextAdvanced(
        pos,
        String(dumps(point.ts)),
        ColorF(clr_txt[1], clr_txt[2], clr_txt[3], 1),
        true,
        false,
        ColorI(clr[1]*255, clr[2]*255, clr[3]*255, 255)
      )
    end
  end
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
