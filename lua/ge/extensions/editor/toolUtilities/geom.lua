-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This is a utility class containing geometric functions, for use with spline-editing tools.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local autoBankTuning = 500 -- The tuning factor for the auto banking of a spline.
local maxBankDeg = 15 -- The maximum bank angle in degrees for sharpest corners.

local maxRayDist = 10000 -- The maximum distance for the camera -> mouse ray, in meters.

local defaultMinNumDivisions = 10 -- The minimum number of subdivisions used when interpolating the secondary geometry properties of a spline.
local maxDivisionSpacing = 20.0 -- The maximum allowed spacing between consecutive division points.
local maxDivisionsHardCap = 2000

local endMargin = 10 -- The margin to add to the first and last points of a polygon, in meters.

local minScale = 0.01 -- The minimum scale for the adaptive sampling of a spline.
local kappaSensitivity = 150 -- The sensitivity of the adaptive sampling of a spline to curvature.

local mouseToNodetol = 2 -- The distance tolerance used when testing if the mouse is close to a node, in meters.                                                                        -- The sq. distance tolerance used when testing if the mouse is close to a spline.
local intermediateTolSq = 1 -- The sq. distance tolerance used when testing if the mouse is close to a spline.

local barScale = 0.5 -- The scale factor for the bar points (height = barScale * velocity).

local epsilon = 1e-6 -- A small value used to avoid division by zero.
local closeTolSq = 4.1 -- The sq. distance tolerance used when testing if two nodes are close to each other, in meters squared.

local splitPartingDistance = 2 -- The distance to push apart the two splines at the split point, in meters.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local kdTreeB2d = require('kdtreebox2d')
local util = require('editor/toolUtilities/util')

-- Module constants.
local abs, min, max, floor, ceil, rad = math.abs, math.min, math.max, math.floor, math.ceil, math.rad
local sin, cos, tan, acos, atan2, pi, sqrt = math.sin, math.cos, math.tan, math.acos, math.atan2, math.pi, math.sqrt
local random, huge = math.random, math.huge
local globalUp = vec3(0, 0, 1)
local preRotQuats = {
  [0] = quat(0, 0, 0, 1), -- 0° (identity).
  [1] = quat(0, 0, 0.70710678, 0.70710678), -- 90°.
  [2] = quat(0, 0, 1, 0), -- 180°.
  [3] = quat(0, 0, 0.70710678, -0.70710678), -- 270°.
}

-- Module state.
local intersections, leftPts, rightPts = {}, {}, {}
local rsX, rsY, rsZ, rsW, rsCum = {}, {}, {}, {}, {}
local tmpQuat = quat()
local tmpPoint2I = Point2I(0, 0)
local pThis, pLast, mousePos2D, tmpTangent = vec3(), vec3(), vec3(), vec3()
local tmp0, tmp1, tmp2, tmp3 = vec3(), vec3(), vec3(), vec3()
local ab, bc, abNorm, bcNorm, tmpTan = vec3(), vec3(), vec3(), vec3(), vec3()


-- Returns the pre-rotation quaternions.
local function getPreRotQuats() return preRotQuats end

-- Returns the scale factor for the bar points.
local function getBarScale() return barScale end

-- Squared XY distance between two points (ignores Z).
local function squaredDistance2D(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

-- Closest point on a polyline to p (3D). Writes into outPos; returns squared distance.
local function closestPointOnPolyline(pts, p, outPos)
  local bestD, n = huge, #pts
  if n < 2 then return bestD end
  for i = 1, n - 1 do
    local a, b = pts[i], pts[i + 1]
    local abx, aby, abz = b.x - a.x, b.y - a.y, b.z - a.z
    local lenSq = abx * abx + aby * aby + abz * abz
    local t = 0
    if lenSq > 1e-12 then
      t = ((p.x - a.x) * abx + (p.y - a.y) * aby + (p.z - a.z) * abz) / lenSq
      if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local hx, hy, hz = a.x + abx * t, a.y + aby * t, a.z + abz * t
    local dx, dy, dz = p.x - hx, p.y - hy, p.z - hz
    local d = dx * dx + dy * dy + dz * dz
    if d < bestD then
      bestD = d
      outPos:set(hx, hy, hz)
    end
  end
  return bestD
end

-- Tip-to-tip height smooth: fix z[1] and z[n], rewrite interior Z via Steffen along XY length.
local function smoothNodesHeightSteffen(nodes)
  local n = nodes and #nodes or 0
  if n < 3 then return false end
  local cum = { [1] = 0 }
  for i = 2, n do
    local dx = nodes[i].x - nodes[i - 1].x
    local dy = nodes[i].y - nodes[i - 1].y
    cum[i] = cum[i - 1] + sqrt(dx * dx + dy * dy)
  end
  local total = cum[n]
  if total < 1e-6 then return false end
  local z0, z1 = nodes[1].z, nodes[n].z
  local x0, x1, x2, x3 = -total, 0, total, total + total
  for i = 2, n - 1 do
    local s = cum[i]
    if s < 0 then s = 0 elseif s > total then s = total end
    nodes[i].z = monotonicSteffen(z0, z0, z1, z1, x0, x1, x2, x3, s)
  end
  return true
end

-- Closest point on polyline to p in XY (Z lerped).
local function closestPointOnPolyline2D(pts, p, outPos, tMin, tMax, closed)
  tMin, tMax = tMin or 0, tMax or 1
  local bestD, n = huge, #pts
  if n < 2 then return bestD end
  local lastSeg = closed and n or (n - 1)
  for i = 1, lastSeg do
    local a, b = pts[i], pts[(i % n) + 1]
    local abx, aby = b.x - a.x, b.y - a.y
    local lenSq = abx * abx + aby * aby
    if lenSq > 1e-12 then
      local t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / lenSq
      if t < 0 then t = 0 elseif t > 1 then t = 1 end
      local segTMin = (not closed and i == 1) and tMin or 0
      local segTMax = (not closed and i == n - 1) and tMax or 1
      if t >= segTMin and t <= segTMax then
        local hx = a.x + abx * t
        local hy = a.y + aby * t
        local dx, dy = p.x - hx, p.y - hy
        local d = dx * dx + dy * dy
        if d < bestD then
          bestD = d
          outPos:set(hx, hy, a.z + (b.z - a.z) * t)
        end
      end
    end
  end
  return bestD
end

-- Where two ribbons that leave a shared junction stop overlapping, as arc length along A measured from the hub (hx, hy)..
local function ribbonOverlapEnd2D(hx, hy, a, aFromStart, b, bFromStart, clearM, stepM, maxM)
  local na = a and #a or 0
  local nb = b and #b or 0
  if na < 2 or nb < 2 or stepM <= 0 then return maxM end
  local clearSq = clearM * clearM
  local aStep = aFromStart and 1 or -1
  local aFirst, aLast = aFromStart and 1 or na, aFromStart and na or 1
  local bStep = bFromStart and 1 or -1
  local bFirst, bLast = bFromStart and 1 or nb, bFromStart and nb or 1

  -- Last usable B vertex: out from its tip until maxM of arc length is covered.
  local bEnd = bLast
  local bAcc, bk = 0, bFirst
  while bk ~= bLast do
    local p, q = b[bk], b[bk + bStep]
    local dx, dy = q.x - p.x, q.y - p.y
    bAcc = bAcc + sqrt(dx * dx + dy * dy)
    bk = bk + bStep
    if bAcc >= maxM then bEnd = bk; break end
  end

  local s, acc = 0, 0
  local ax, ay = hx, hy -- current A segment start; the first segment is the hub stub
  local ai = aFirst     -- index of the current A segment's end vertex
  while true do
    local q = a[ai]
    local dx, dy = q.x - ax, q.y - ay
    local segLen = sqrt(dx * dx + dy * dy)
    if segLen > 1e-9 then
      local inv = 1.0 / segLen
      while s <= acc + segLen do
        if s > maxM then return maxM end
        local t = (s - acc) * inv
        local px, py = ax + dx * t, ay + dy * t
        -- Only whether ANY of B is within clearM matters, not the true minimum, so bail on the first hit. Every
        -- station inside the overlap (i.e. all but the last) then costs a segment or two.
        local hit = false
        local ux, uy = hx, hy
        local bi = bFirst
        while true do
          local v = b[bi]
          local ex, ey = v.x - ux, v.y - uy
          local eLenSq = ex * ex + ey * ey
          if eLenSq > 1e-12 then
            local bt = ((px - ux) * ex + (py - uy) * ey) / eLenSq
            if bt < 0 then bt = 0 elseif bt > 1 then bt = 1 end
            local gx, gy = px - (ux + ex * bt), py - (uy + ey * bt)
            if gx * gx + gy * gy < clearSq then hit = true; break end
          end
          if bi == bEnd then break end
          ux, uy = v.x, v.y
          bi = bi + bStep
        end
        if not hit then return s end
        s = s + stepM
      end
      acc = acc + segLen
    end
    if ai == aLast then break end
    ax, ay = q.x, q.y
    ai = ai + aStep
  end
  return maxM
end

-- Returns the squared distance between two line segments.
local function squaredSegSegDist(a0, a1, b0, b1, outP1, outP2)
  local a0X, a0Y, a0Z = a0.x, a0.y, a0.z
  local a1X, a1Y, a1Z = a1.x, a1.y, a1.z
  local b0X, b0Y, b0Z = b0.x, b0.y, b0.z
  local b1X, b1Y, b1Z = b1.x, b1.y, b1.z
  local ux, uy, uz = a1X - a0X, a1Y - a0Y, a1Z - a0Z
  local vx, vy, vz = b1X - b0X, b1Y - b0Y, b1Z - b0Z
  local wx, wy, wz = a0X - b0X, a0Y - b0Y, a0Z - b0Z

  -- Compute the dot products.
  local a = ux * ux + uy * uy + uz * uz
  local b = ux * vx + uy * vy + uz * vz
  local c = vx * vx + vy * vy + vz * vz
  local d = ux * wx + uy * wy + uz * wz
  local e = vx * wx + vy * wy + vz * wz

  -- Compute s, t - the parameters of the closest points on the segments.
  local denom = a * c - b * b + epsilon
  local denomInv = 1.0 / denom
  local s = (b * e - c * d) * denomInv
  local t = (a * e - b * d) * denomInv
  s = max(0, min(1, s))
  t = max(0, min(1, t))

  -- Compute the distance vector.
  local dx = wx + s * ux - t * vx
  local dy = wy + s * uy - t * vy
  local dz = wz + s * uz - t * vz

  -- Compute the closest points on the segments.
  outP1:set(a0X + s * ux, a0Y + s * uy, a0Z + s * uz)
  outP2:set(b0X + t * vx, b0Y + t * vy, b0Z + t * vz)

  -- Return the squared distance.
  return dx * dx + dy * dy + dz * dz
end

-- Checks if the mouse is over a node of any spline in the given collection of splines.
-- [Splines - The collection of splines to check, which must have a member array 'nodes', containing the ordered points of the splines.]
local function isMouseOverNode(splines)
  -- Get the camera-to-mouse ray.
  local ray = getCameraMouseRay()
  local rayPos, rayDir = ray.pos, ray.dir

  -- Check each spline in turn.
  for i = 1, #splines do
    local nodes = splines[i].nodes
    for j = 1, #nodes do
      local a, b = intersectsRay_Sphere(rayPos, rayDir, nodes[j], mouseToNodetol) -- Get any intersection points between the ray and node sphere.
      if min(a, b) < maxRayDist then -- If they do exist, the mouse is over this node, so we have found target.
        return true, i, j -- Return the spline/node indices along with the true result.
      end
    end
  end

  -- The mouse is not over any node, so return nil.
  return false, nil, nil
end

-- Checks if the mouse is over the given polyline. `closed` also tests the edge from the last node back to the first, which
-- is a real edge of a polygon and not of a polyline.
local function isMouseOverPolyline(points, mousePos, closed)
  -- Project the mouse position onto the {z = 0} plane.
  mousePos2D:set(mousePos.x, mousePos.y, 0.0)

  -- Check each node, in each spline, in turn.
  local n = #points
  for j = 1, closed and n or (n - 1) do
    local p0, p1 = points[j], points[j % n + 1]
    tmp1:set(p0.x, p0.y, 0.0)
    tmp2:set(p1.x, p1.y, 0.0)
    if mousePos2D:squaredDistanceToLineSegment(tmp1, tmp2) < intermediateTolSq then
      return true, j
    end
  end

  -- The mouse is not over the polyline, so return nil.
  return false, nil
end

-- Checks if the mouse is over a bar.
-- [Splines - The collection of splines to check, which must have a member 1D array 'barPoints', containing the ordered points of the bars.]
local function isMouseOverBar(splines)
  local ray = getCameraMouseRay()
  local rayPos, rayDir = ray.pos, ray.dir
  for i = 1, #splines do
    local spline = splines[i]
    if spline and spline.isEnabled then
      local barPoints = spline.barPoints
      if barPoints and #barPoints > 0 then
        for j = 1, #barPoints do
          local a, b = intersectsRay_Sphere(rayPos, rayDir, barPoints[j], mouseToNodetol) -- The intersection points between ray and node sphere.
          if min(a, b) < maxRayDist then -- If one exists, the mouse is over this bar point.
            return true, i, j -- Returns: isOverBar, spline index in give table, bar index in given table.
          end
        end
      end
    end
  end
  return false, nil, nil
end

-- Checks if the mouse is over a node in the navigation graph.
local function isMouseOverGraphNode(nodes)
  local ray = getCameraMouseRay()
  local rayPos, rayDir = ray.pos, ray.dir
  for key, node in pairs(nodes) do
    local a, b = intersectsRay_Sphere(rayPos, rayDir, node, mouseToNodetol) -- Get any intersection points between the ray and node sphere.
    if min(a, b) < maxRayDist then -- If they do exist, the mouse is over this node, so we have found target.
      return true, key -- Return the node key along with the true result.
    end
  end
  return false, nil
end

-- Returns the axis-aligned bounding box of the given array of points.
local function getAABB(points)
  local xMin, xMax, yMin, yMax = huge, -huge, huge, -huge
  for i = 1, #points do
    local p = points[i]
    local pX, pY = p.x, p.y
    xMin, xMax, yMin, yMax = min(xMin, pX), max(xMax, pX), min(yMin, pY), max(yMax, pY)
  end
  return { xMin = xMin, xMax = xMax, yMin = yMin, yMax = yMax }
end

-- Oriented bounding box of a 2D polygon (array of {[1]=x,[2]=y}) via PCA.
local function polygonOBB(poly)
  local n = #poly
  local cx, cy = 0, 0
  for i = 1, n do cx = cx + poly[i][1]; cy = cy + poly[i][2] end
  cx, cy = cx / n, cy / n
  local sxx, sxy, syy = 0, 0, 0
  for i = 1, n do
    local dx, dy = poly[i][1] - cx, poly[i][2] - cy
    sxx = sxx + dx * dx; sxy = sxy + dx * dy; syy = syy + dy * dy
  end
  local theta = 0.5 * atan2(2 * sxy, sxx - syy)
  local ct, st = cos(theta), sin(theta)
  local minU, maxU, minV, maxV = huge, -huge, huge, -huge
  for i = 1, n do
    local dx, dy = poly[i][1] - cx, poly[i][2] - cy
    local u, v = dx * ct + dy * st, -dx * st + dy * ct
    if u < minU then minU = u end; if u > maxU then maxU = u end
    if v < minV then minV = v end; if v > maxV then maxV = v end
  end
  local mu, mv = (minU + maxU) * 0.5, (minV + maxV) * 0.5
  return cx + mu * ct - mv * st, cy + mu * st + mv * ct, (maxU - minU) * 0.5, (maxV - minV) * 0.5, theta
end

-- Computes a polygonal outline from the given spline. Includes a given margin.
-- [Polygons are fast to deal with using scanline spans.]
-- [Returns: polygon]
local function computeSplinePolygon(spline, margin, polygon)
  -- Create the left and right edge polylines.
  table.clear(leftPts); table.clear(rightPts)
  local divPoints, tangents, binormals, divWidths = spline.divPoints, spline.tangents, spline.binormals, spline.divWidths
  local numDiv = #divPoints
  for i = 1, numDiv do
    local p, bin = divPoints[i], binormals[i]
    local halfWidth = divWidths[i] * 0.5 + margin
    local pX, pY, latX, latY = p.x, p.y, bin.x * halfWidth, bin.y * halfWidth
    leftPts[i], rightPts[i] = vec3(pX - latX, pY - latY, 0), vec3(pX + latX, pY + latY, 0)
  end

  -- Move the first and last points outwards by the margin.
  tmpTan:setScaled2(tangents[1], endMargin)
  leftPts[1]:setSub(tmpTan)
  rightPts[1]:setSub(tmpTan)
  tmpTan:setScaled2(tangents[numDiv], endMargin)
  leftPts[numDiv]:setAdd(tmpTan)
  rightPts[numDiv]:setAdd(tmpTan)

  -- Create the polygon from the left and right edge polylines.
  table.clear(polygon)
  local ctr = 1
  for i = 1, numDiv do
    polygon[ctr] = leftPts[i]
    ctr = ctr + 1
  end
  for i = numDiv, 1, -1 do
    polygon[ctr] = rightPts[i]
    ctr = ctr + 1
  end
end

-- Checks if the given point (p) is inside the given triangle (a, b, c).
local function isPointInTriangle(p, a, b, c)
  local v0, v1, v2 = c - a, b - a, p - a
  local dot00, dot01, dot02, dot11, dot12 = v0:dot(v0), v0:dot(v1), v0:dot(v2), v1:dot(v1), v1:dot(v2)
  local denom = dot00 * dot11 - dot01 * dot01
  if denom == 0 then
    return false
  end
  local invDenom = 1.0 / denom
  local u = (dot11 * dot02 - dot01 * dot12) * invDenom
  local v = (dot00 * dot12 - dot01 * dot02) * invDenom
  return (u >= 0.0 and v >= 0.0 and (u + v) <= 1.0)
end

-- Returns the normal of the terrain at the given world-space point.
local function getTerrainNormal(p)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  te:worldToGridByPoint2I(p, tmpPoint2I, tb) -- World point to grid.
  local gx, gy = tmpPoint2I.x, tmpPoint2I.y
  local dzdx = (tb:getHeightGrid(gx + 1, gy) - tb:getHeightGrid(gx - 1, gy)) * 0.5 -- Sample neighbourhood.
  local dzdy = (tb:getHeightGrid(gx, gy + 1) - tb:getHeightGrid(gx, gy - 1)) * 0.5
  local normal = vec3(-dzdx, -dzdy, 1)
  normal:normalize()
  return normal
end

-- Returns the normal of the terrain at the given world-space point, in-place.
local function getTerrainNormalInPlace(p, out)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  te:worldToGridByPoint2I(p, tmpPoint2I, tb) -- World point to grid.
  local gx, gy = tmpPoint2I.x, tmpPoint2I.y
  local dzdx = (tb:getHeightGrid(gx + 1, gy) - tb:getHeightGrid(gx - 1, gy)) * 0.5 -- Sample neighbourhood.
  local dzdy = (tb:getHeightGrid(gx, gy + 1) - tb:getHeightGrid(gx, gy - 1)) * 0.5
  out:set(-dzdx, -dzdy, 1)
  out:normalize()
end

-- Rotates vector v around the z-axis, by angle theta (in radians). In place.
local function rotateVecAroundZ(vec, v, angle)
  local vX, vY = v.x, v.y
  local cosA, sinA = cos(angle), sin(angle)
  vec:set(vX * cosA - vY * sinA, vX * sinA + vY * cosA, v.z)
end

-- Rotates vector v around unit axis k, by angle theta (in radians).
-- [Uses the standard Rodrigues formula].
local function rotateVecAroundAxis(v, k, theta)
  local c, s = cos(theta), sin(theta)
  tmp0:setCross(k, v)
  tmp0:setScaled(s)
  local kDotV = k:dot(v)
  tmp1:setScaled2(k, kDotV * (1.0 - c))
  tmp0:setAdd(tmp1)
  tmp2:set(v.x * c, v.y * c, v.z * c)
  tmp0:setAdd(tmp2)
  return tmp0:copy()
end

-- Rotates vector v around unit axis k, by angle theta (radians) into 'out' without allocations.
-- out = v * cos(theta) + (k x v) * sin(theta) + k * (k . v) * (1 - cos(theta))
local function rotateVecAroundAxisInlined(v, k, theta, out)
  local c, s = cos(theta), sin(theta)
  local oneMinusC = 1.0 - c
  tmp0:setCross(k, v) -- tmp0 = k x v.
  tmp0:setScaled(s)
  local kDotV = k:dot(v) -- tmp1 = k * (k . v) * (1 - c).
  tmp1:setScaled2(k, kDotV * oneMinusC)
  out:setScaled2(v, c) -- out = v * c + tmp0 + tmp1.
  out:setAdd(tmp0)
  out:setAdd(tmp1)
  return out
end

-- Curvature radius approximation using 3 points.
local function computeTurningRadius(p1, p2, p3)
  ab:setSub2(p2, p1)
  bc:setSub2(p3, p2)
  local abLen, bcLen = ab:length(), bc:length()
  abNorm:set(ab)
  abNorm:normalize()
  bcNorm:set(bc)
  bcNorm:normalize()
  local dot = clamp(abNorm:dot(bcNorm), -1.0, 1.0)
  local angle = acos(dot)
  local avgLen = 0.5 * (abLen + bcLen)
  return avgLen / tan(angle * 0.5 + epsilon)
end

-- Checks if the given line segment (a, b) intersects with the given line segment (c, d).
local function isLineSegIntersect(a, b, c, d)
  local xnorm, xnorm2 = closestLinePoints(a, b, c, d)
  return xnorm >= 0.0 and xnorm <= 1.0 and xnorm2 >= 0.0 and xnorm2 <= 1.0
end

-- Finds the intersection point between two line segments. Inlined.
local function intersection2LineSegs(p1, p2, q1, q2, out)
  local xnorm, xnorm2 = closestLinePoints(p1, p2, q1, q2)
  if xnorm >= 0.0 and xnorm <= 1.0 and xnorm2 >= 0.0 and xnorm2 <= 1.0 then
    local p1X, p1Y = p1.x, p1.y
    out:set(p1X + xnorm * (p2.x - p1X), p1Y + xnorm * (p2.y - p1Y), 0)
    return out
  end
  return nil
end

local function classifyAlong(t, eps)
  if t <= -eps then return -2 end
  if t < eps then return -1 end
  if t - 1 <= -eps then return 0 end
  if t - 1 < eps then return 1 end
  return 2
end

local function pointsSame2D(a, b, eps)
  eps = eps or 1e-10
  return abs(a.x - b.x) < eps and abs(a.y - b.y) < eps
end

local function pointsCompare2D(a, b, eps)
  eps = eps or 1e-10
  if abs(a.x - b.x) >= eps then return a.x < b.x and -1 or 1 end
  if abs(a.y - b.y) < eps then return 0 end
  return a.y < b.y and -1 or 1
end

local function pointAboveOrOnLine2D(pt, left, right, eps)
  eps = eps or 1e-10
  return (right.x - left.x) * (pt.y - left.y) - (right.y - left.y) * (pt.x - left.x) >= -eps
end

local function pointsCollinear2D(a, b, c, eps)
  eps = eps or 1e-10
  return abs((a.x - b.x) * (b.y - c.y) - (a.y - b.y) * (b.x - c.x)) < eps
end

-- p is taken to be collinear with left->right; false if it is either endpoint, or outside them.
-- The test is on the DOT PRODUCT, not on the normalised position along the line. Both read the same at a metre or so, but the
-- dot carries units of length squared, so on a two millimetre edge a normalised test tolerates a p that is an endpoint to
-- within a ten-thousandth of the edge -- and the sweep that calls this then splits a segment at its own end, leaving a
-- zero-length piece that corrupts the fill.
local function pointBetween2D(p, left, right, eps)
  eps = eps or 1e-10
  local plx, ply = p.x - left.x, p.y - left.y
  local rlx, rly = right.x - left.x, right.y - left.y
  local dot = plx * rlx + ply * rly
  if dot < eps then return false end
  local sqlen = rlx * rlx + rly * rly
  if dot - sqlen > -eps then return false end
  return true
end

-- Returns { pt={x,y}, alongA, alongB } or nil if parallel (along* Martinez codes).
local function linesIntersect2D(a0, a1, b0, b1, eps)
  eps = eps or 1e-10
  local adx, ady = a1.x - a0.x, a1.y - a0.y
  local bdx, bdy = b1.x - b0.x, b1.y - b0.y
  local axb = adx * bdy - ady * bdx
  if abs(axb) < eps then return nil end
  -- Solved here rather than through closestLinePoints, which divides by the Gram determinant uu*vv - uv*uv. On two near
  -- parallel segments that is the difference of two nearly equal fourth powers of length and comes back as pure round off, so
  -- the pair of parameters it returns no longer describes the same point -- and the sweep that calls this then splits a
  -- segment at a point metres off its own line. The cross below cancels one order of magnitude instead of two.
  local dx, dy = a0.x - b0.x, a0.y - b0.y
  local A = (bdx * dy - bdy * dx) / axb
  local B = (adx * dy - ady * dx) / axb
  return {
    pt = { x = a0.x + A * adx, y = a0.y + A * ady },
    alongA = classifyAlong(A, eps),
    alongB = classifyAlong(B, eps),
  }
end

-- t along p0+t*d0 at intersection with p1+u*d1 (nil if parallel). Unit d0 => t in metres.
local function lineDirsHitT2D(p0x, p0y, d0x, d0y, p1x, p1y, d1x, d1y, eps)
  eps = eps or 1e-10
  local cross = d0x * d1y - d0y * d1x
  if abs(cross) < eps then return nil end
  -- Direct, for the reason given on linesIntersect2D. Shallow corners on a mitred outset are exactly the near parallel case.
  return ((p1x - p0x) * d1y - (p1y - p0y) * d1x) / cross
end

-- Sample a cubic Bezier in XY (inclusive endpoints). segs = number of segments (default 14).
local function sampleCubicBezier2D(p0, p1, p2, p3, segs)
  segs = segs or 14
  local pts = {}
  for i = 0, segs do
    local t = i / segs
    local u = 1 - t
    local u2, t2 = u * u, t * t
    local a, b, c, d = u2 * u, 3 * u2 * t, 3 * u * t2, t2 * t
    pts[#pts + 1] = {
      x = a * p0.x + b * p1.x + c * p2.x + d * p3.x,
      y = a * p0.y + b * p1.y + c * p2.y + d * p3.y,
    }
  end
  return pts
end

-- Point at arc length `s` (>= 0) from the moving tip along a node polyline (XY).
local function pointAtArcFromTip(nodes, d, fromStart, s)
  local n = #nodes
  if fromStart then
    if s <= 0 then return nodes[1].x, nodes[1].y end
    for i = 2, n do
      if d[i] >= s then
        local seg = d[i] - d[i - 1]
        local t = seg > 1e-9 and (s - d[i - 1]) / seg or 0
        local a, b = nodes[i - 1], nodes[i]
        return a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t
      end
    end
    return nodes[n].x, nodes[n].y
  end
  if s <= 0 then return nodes[n].x, nodes[n].y end
  for i = n - 1, 1, -1 do
    if d[i] >= s then
      local seg = d[i] - d[i + 1]
      local t = seg > 1e-9 and (s - d[i + 1]) / seg or 0
      local a, b = nodes[i + 1], nodes[i]
      return a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t
    end
  end
  return nodes[1].x, nodes[1].y
end

-- Reshape one END of a node polyline in place (2D x/y; z untouched).
local function reshapeLeadInBezier2D(nodes, fromStart, p0x, p0y, gx, gy, L)
  local n = #nodes
  if n < 2 or L <= 1e-6 then return end
  -- Arc length of each node from the moving tip, along the ORIGINAL geometry.
  local d = {}
  if fromStart then
    d[1] = 0
    for i = 2, n do
      local a, b = nodes[i - 1], nodes[i]
      d[i] = d[i - 1] + sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y))
    end
  else
    d[n] = 0
    for i = n - 1, 1, -1 do
      local a, b = nodes[i + 1], nodes[i]
      d[i] = d[i + 1] + sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y))
    end
  end
  local total = fromStart and d[n] or d[1]
  local Lc = min(L, total)
  if Lc <= 1e-6 then return end
  -- Merge point M = original point Lc in from the tip, with the arm's OWN inward heading Tm there.
  local mx, my = pointAtArcFromTip(nodes, d, fromStart, Lc)
  local h = max(0.5, min(3.0, Lc * 0.25))
  local aheadX, aheadY = pointAtArcFromTip(nodes, d, fromStart, min(Lc + h, total))
  local backX, backY = pointAtArcFromTip(nodes, d, fromStart, max(Lc - h, 0.0))
  local tmx, tmy = aheadX - backX, aheadY - backY
  local tl = sqrt(tmx * tmx + tmy * tmy)
  if tl > 1e-6 then tmx, tmy = tmx / tl, tmy / tl else tmx, tmy = gx, gy end
  -- Cubic Bezier: P0 = shifted tip leaving along g; P3 = M rejoining along Tm; inner handles at Lc/3.
  local P1x, P1y = p0x + gx * (Lc / 3), p0y + gy * (Lc / 3)
  local P2x, P2y = mx - tmx * (Lc / 3), my - tmy * (Lc / 3)
  for i = 1, n do
    if d[i] < Lc then
      local t = d[i] / Lc
      local u = 1 - t
      local a2, b2, c2, e2 = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
      nodes[i].x = a2 * p0x + b2 * P1x + c2 * P2x + e2 * mx
      nodes[i].y = a2 * p0y + b2 * P1y + c2 * P2y + e2 * my
    end
  end
end

-- Offset a 2D polyline along its local normal, toward (cx, cy).
local function pathLeftNormal2D(path, i, n)
  local ax, ay, bx, by
  if i == 1 then
    ax, ay, bx, by = path[1].x, path[1].y, path[2].x, path[2].y
  elseif i == n then
    ax, ay, bx, by = path[n - 1].x, path[n - 1].y, path[n].x, path[n].y
  else
    ax, ay, bx, by = path[i - 1].x, path[i - 1].y, path[i + 1].x, path[i + 1].y
  end
  local tx, ty = bx - ax, by - ay
  local tlen = sqrt(tx * tx + ty * ty)
  if tlen < 1e-9 then return nil end
  return -ty / tlen, tx / tlen
end

-- Which handed side (left normal of the ordered path) points TOWARD (cx, cy).
local function pathTowardCentreSide2D(path, cx, cy)
  local n, vote = #path, 0
  for i = 1, n do
    local nx, ny = pathLeftNormal2D(path, i, n)
    if nx then
      local p = path[i]
      vote = vote + (nx * (cx - p.x) + ny * (cy - p.y))
    end
  end
  return (vote >= 0) and 1 or -1
end

local function insetPathAlongNormal2D(path, cx, cy, insetM)
  if not path or #path < 2 or insetM <= 0 then return path end
  local n, out = #path, {}
  local towardSide = pathTowardCentreSide2D(path, cx, cy) -- inset heads toward the centre
  for i = 1, n do
    local p = path[i]
    local nx, ny = pathLeftNormal2D(path, i, n)
    if not nx then
      out[i] = { x = p.x, y = p.y }
    else
      nx, ny = nx * towardSide, ny * towardSide
      out[i] = { x = p.x + nx * insetM, y = p.y + ny * insetM }
    end
  end
  return out
end

local miterClipLimit = 1.5 -- SVG stroke-linejoin: miter-clip

-- Miter-clipped parallel offset of an OPEN 2D polyline: one output point per source vertex (so paired rails stay
-- index-aligned) with z carried through. Corners keep true perpendicular width, unlike offsetPathFromCenter2D's
-- per-vertex normals. The side is chosen ONCE for the whole path so it cannot flip halfway along: away from
-- (cx, cy), or toward it when inward.
local function offsetPathMiter2D(pts, dist, cx, cy, z, inward)
  local n = #pts
  local out = {}
  if n < 2 or dist == 0 then
    for i = 1, n do out[i] = { x = pts[i].x, y = pts[i].y, z = pts[i].z or z } end
    return out
  end

  -- Left-of-travel segment normals; a degenerate (zero-length) segment inherits a neighbour's.
  local lnx, lny = {}, {}
  for i = 1, n - 1 do
    local dx, dy = pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y
    local len = sqrt(dx * dx + dy * dy)
    if len < 1e-9 then lnx[i], lny[i] = 0, 0 else lnx[i], lny[i] = -dy / len, dx / len end
  end
  for i = 1, n - 1 do
    if lnx[i] == 0 and lny[i] == 0 then
      for j = i - 1, 1, -1 do
        if lnx[j] ~= 0 or lny[j] ~= 0 then lnx[i], lny[i] = lnx[j], lny[j] break end
      end
      if lnx[i] == 0 and lny[i] == 0 then
        for j = i + 1, n - 1 do
          if lnx[j] ~= 0 or lny[j] ~= 0 then lnx[i], lny[i] = lnx[j], lny[j] break end
        end
      end
    end
  end

  -- Decide the side by SUMMING the outward test over the WHOLE path, not just the first segment: a path that
  -- starts radially (a rim arc embedding into an arm) has a near-zero, ambiguous first normal, and keying off it
  -- alone mis-flips the whole strip inward. The sum is dominated by the long tangential run (each term scales
  -- with radial distance), so the strip reliably lands on the outside.
  local signed = dist
  local vote, sumAbs = 0, 0
  for i = 1, n - 1 do
    if lnx[i] ~= 0 or lny[i] ~= 0 then
      local mx = (pts[i].x + pts[i + 1].x) * 0.5
      local my = (pts[i].y + pts[i + 1].y) * 0.5
      local d = (mx - cx) * lnx[i] + (my - cy) * lny[i]
      vote = vote + d
      sumAbs = sumAbs + abs(d)
    end
  end
  -- A near-CANCELLING vote means a mostly-radial path (two radial legs meeting at a near-point), where the sign is
  -- noise. Break the tie off the vertex CLOSEST to the centre: take the side that pushes THAT point to a larger
  -- radius, so the innermost point can never cross inside. A decisive vote is untouched.
  if sumAbs > 1e-9 and abs(vote) < 0.15 * sumAbs then
    local mi, mr2 = 1, huge
    for i = 1, n do
      local dx, dy = pts[i].x - cx, pts[i].y - cy
      local r2 = dx * dx + dy * dy
      if r2 < mr2 then mr2, mi = r2, i end
    end
    local ni = min(mi, n - 1)
    if (pts[mi].x - cx) * lnx[ni] + (pts[mi].y - cy) * lny[ni] < 0 then signed = -dist end
  elseif vote < 0 then
    signed = -dist
  end
  if inward then signed = -signed end

  out[1] = { x = pts[1].x + lnx[1] * signed, y = pts[1].y + lny[1] * signed, z = pts[1].z or z }
  for i = 2, n - 1 do
    local n0x, n0y, n1x, n1y = lnx[i - 1], lny[i - 1], lnx[i], lny[i]
    local vx, vy = pts[i].x, pts[i].y
    local bx, by = n0x + n1x, n0y + n1y
    local bl = sqrt(bx * bx + by * by)
    local ox, oy
    if bl < 1e-9 then
      ox, oy = vx + n0x * signed, vy + n0y * signed
    else
      bx, by = bx / bl, by / bl
      local cosHalf = bx * n0x + by * n0y
      if abs(cosHalf) < 1e-6 then
        ox, oy = vx + n0x * signed, vy + n0y * signed
      else
        local miterLen = signed / cosHalf
        local maxLen = miterClipLimit * abs(signed)
        if abs(miterLen) > maxLen then miterLen = (miterLen > 0 and 1 or -1) * maxLen end
        ox, oy = vx + bx * miterLen, vy + by * miterLen
      end
    end
    out[i] = { x = ox, y = oy, z = pts[i].z or z }
  end
  out[n] = { x = pts[n].x + lnx[n - 1] * signed, y = pts[n].y + lny[n - 1] * signed, z = pts[n].z or z }
  return out
end

-- Offset a 2D polyline AWAY from (cx, cy) along its local normal.
local function offsetPathFromCenter2D(path, cx, cy, distM, distArr)
  if not path or #path < 2 or (distM <= 0 and not distArr) then return path end
  local n, out = #path, {}
  local outSide = -pathTowardCentreSide2D(path, cx, cy) -- opposite of the toward-centre side
  for i = 1, n do
    local p = path[i]
    local nx, ny = pathLeftNormal2D(path, i, n)
    if not nx then
      out[i] = { x = p.x, y = p.y, z = p.z }
    else
      local d = distArr and (distArr[i] or 0) or distM
      nx, ny = nx * outSide, ny * outSide
      out[i] = { x = p.x + nx * d, y = p.y + ny * d, z = p.z }
    end
  end
  return out
end

-- Area-weighted centroid of one or more closed 2D rings ({x,y} verts). Returns cx, cy or nil.
local function multiPolygonCentroidXY(regions)
  if not regions or #regions < 1 then return nil, nil end
  local sumA, sumCx, sumCy = 0, 0, 0
  for r = 1, #regions do
    local ring = regions[r]
    local n = ring and #ring or 0
    if n >= 3 then
      local a, cx, cy = 0, 0, 0
      for i = 1, n do
        local p, q = ring[i], ring[(i % n) + 1]
        local cross = p.x * q.y - q.x * p.y
        a = a + cross
        cx = cx + (p.x + q.x) * cross
        cy = cy + (p.y + q.y) * cross
      end
      a = a * 0.5
      local absA = abs(a)
      if absA > 1e-8 then
        sumA = sumA + absA
        sumCx = sumCx + (cx / (6 * a)) * absA
        sumCy = sumCy + (cy / (6 * a)) * absA
      end
    end
  end
  if sumA < 1e-8 then return nil, nil end
  return sumCx / sumA, sumCy / sumA
end

-- Cumulative 3D chord lengths along a polyline. Returns cum[1..n], total.
local function polylineCumLength3D(pts)
  local cum, n = { 0 }, pts and #pts or 0
  for i = 2, n do
    cum[i] = cum[i - 1] + pts[i]:distance(pts[i - 1])
  end
  return cum, cum[n] or 0
end

-- 2D (XY-only) sibling of polylineCumLength3D for plain {x,y} points (no vec3 :distance): out[i] = distance from pts[1]
-- to pts[i]. Takes an optional reused `out` table (cleared then refilled) so a hot rebuild allocates nothing; omit for a
-- fresh one. Returns out and its total length.
local function polylineCumLength2D(pts, out)
  out = out or {}
  table.clear(out)
  local n = pts and #pts or 0
  out[1] = 0
  for i = 2, n do
    local a, b = pts[i - 1], pts[i]
    local dx, dy = b.x - a.x, b.y - a.y
    out[i] = out[i - 1] + sqrt(dx * dx + dy * dy)
  end
  return out, out[n] or 0
end

-- Whether a shape signature (a flat list of numbers and strings) moved since `old`: numbers by more than tolM, strings at all.
local function sigMoved(old, new, tolM)
  if not old or #old ~= #new then return true end
  for i = 1, #new do
    local a, b = old[i], new[i]
    if type(a) == 'number' and type(b) == 'number' then
      if abs(a - b) > tolM then return true end
    elseif a ~= b then
      return true
    end
  end
  return false
end

-- Ramer-Douglas-Peucker simplification of a polyline (perpendicular distance measured in full 3D).
local function simplifyRDP(points, tolM)
  local n = points and #points or 0
  if n < 3 or not tolM or tolM <= 0 then return points end
  local keep = {}
  keep[1], keep[n] = true, true
  local tolSq = tolM * tolM
  local stack = { 1, n } -- flat pairs (lo, hi) to subdivide
  while #stack > 0 do
    local hi = stack[#stack]; stack[#stack] = nil
    local lo = stack[#stack]; stack[#stack] = nil
    if hi > lo + 1 then
      local a, b = points[lo], points[hi]
      local az, bz = a.z or 0, b.z or 0 -- 3D: a node XY-straight but Z-bent (incline crest/dip) must not be dropped;
      local ex, ey, ez = b.x - a.x, b.y - a.y, bz - az -- z defaults to 0 so plain {x,y} callers (flat rings) still work
      local lenSq = ex * ex + ey * ey + ez * ez
      local maxD, maxI = -1, nil
      for i = lo + 1, hi - 1 do
        local p = points[i]
        local px, py, pz = p.x - a.x, p.y - a.y, (p.z or 0) - az
        local d
        if lenSq > 1e-12 then
          local t = (px * ex + py * ey + pz * ez) / lenSq
          local dx, dy, dz = px - ex * t, py - ey * t, pz - ez * t
          d = dx * dx + dy * dy + dz * dz
        else
          d = px * px + py * py + pz * pz -- degenerate chord: distance to the shared endpoint
        end
        if d > maxD then maxD, maxI = d, i end
      end
      if maxI and maxD > tolSq then
        keep[maxI] = true
        stack[#stack + 1] = lo; stack[#stack + 1] = maxI
        stack[#stack + 1] = maxI; stack[#stack + 1] = hi
      end
    end
  end
  local out = {}
  for i = 1, n do if keep[i] then out[#out + 1] = points[i] end end
  return out
end

-- Thin a tessellated curve down to chords of about `chord` metres.
local function chordify(pts, n, chord, flags)
  if n < 3 then return pts, flags end
  local out, outF = { pts[1] }, flags and { flags[1] } or nil
  local lastX, lastY = pts[1].x, pts[1].y
  for i = 2, n - 1 do
    local p = pts[i]
    local dx, dy = p.x - lastX, p.y - lastY
    if (flags and flags[i]) or dx * dx + dy * dy >= chord * chord then
      out[#out + 1] = p
      if outF then outF[#out] = flags[i] end
      lastX, lastY = p.x, p.y
    end
  end
  out[#out + 1] = pts[n]
  if outF then outF[#out] = flags[n] end
  return out, outF
end

-- Welds out near-coincident consecutive nodes, in place.
local function weldShortSegments(nodes, widths, minLen)
  local n = nodes and #nodes or 0
  if n <= 2 then return n end
  local minSq = minLen * minLen
  local w = 1 -- write cursor = last kept index; node 1 stays in place
  for j = 2, n - 1 do
    if nodes[j]:squaredDistance(nodes[w]) >= minSq then
      w = w + 1
      nodes[w], widths[w] = nodes[j], widths[j]
    end
  end
  -- Always keep the true end node; if it crowds the last kept node, overwrite that one instead of appending.
  if w >= 2 and nodes[n]:squaredDistance(nodes[w]) < minSq then
    nodes[w], widths[w] = nodes[n], widths[n]
  else
    w = w + 1
    nodes[w], widths[w] = nodes[n], widths[n]
  end
  for i = w + 1, n do
    nodes[i], widths[i] = nil, nil
  end
  return w
end

-- Densifies a polyline so no segment exceeds maxSpacing.
local function densifyByMaxSpacing(points, maxSpacing)
  local n = points and #points or 0
  if n < 2 or not maxSpacing or maxSpacing <= 0 then return points end
  local out = { points[1] }
  for i = 2, n do
    local a, b = points[i - 1], points[i]
    local pieces = math.ceil(a:distance(b) / maxSpacing) -- segments to split into (>= 1)
    if pieces > 1 then
      local dir = b - a
      for k = 1, pieces - 1 do
        out[#out + 1] = a + dir * (k / pieces)
      end
    end
    out[#out + 1] = b
  end
  return out
end

-- Resamples a polyline (nodes = vec3[], widths = number[]).
local function resampleUniformNodesWidths(nodes, widths, spacing)
  local n = nodes and #nodes or 0
  if n < 2 or not spacing or spacing <= 0 then return n end
  -- Snapshot originals + build cumulative 3D length (so we can overwrite nodes while sampling).
  local total = 0
  rsCum[1] = 0
  for i = 1, n do
    local p = nodes[i]
    rsX[i], rsY[i], rsZ[i], rsW[i] = p.x, p.y, p.z, widths[i]
    if i > 1 then
      local dx, dy, dz = rsX[i] - rsX[i - 1], rsY[i] - rsY[i - 1], rsZ[i] - rsZ[i - 1]
      total = total + sqrt(dx * dx + dy * dy + dz * dz)
      rsCum[i] = total
    end
  end
  if total < epsilon then return n end -- fully degenerate: leave for the weld pass to collapse.

  local intervals = max(1, floor(total / spacing + 0.5))
  local outN = intervals + 1
  local step = total / intervals
  local seg = 1
  for k = 1, outN do
    local d = (k == outN) and total or (k - 1) * step
    while seg < n - 1 and rsCum[seg + 1] < d do seg = seg + 1 end
    local d0, d1 = rsCum[seg], rsCum[seg + 1]
    local t = (d1 > d0) and (d - d0) / (d1 - d0) or 0
    local p = nodes[k] or vec3()
    nodes[k] = p
    p:set(rsX[seg] + (rsX[seg + 1] - rsX[seg]) * t,
          rsY[seg] + (rsY[seg + 1] - rsY[seg]) * t,
          rsZ[seg] + (rsZ[seg + 1] - rsZ[seg]) * t)
    widths[k] = rsW[seg] + (rsW[seg + 1] - rsW[seg]) * t
  end
  for i = outN + 1, n do nodes[i], widths[i] = nil, nil end
  return outN
end

-- Chaikin corner-cutting for a closed polygon of {x=,y=} points.
local function smoothClosedPolygonChaikin(poly, iterations)
  local pts = poly
  for _ = 1, (iterations or 1) do
    local n = #pts
    if n < 3 then return pts end
    local out = {}
    for i = 1, n do
      local a, b = pts[i], pts[(i % n) + 1]
      out[#out + 1] = { x = a.x * 0.75 + b.x * 0.25, y = a.y * 0.75 + b.y * 0.25 }
      out[#out + 1] = { x = a.x * 0.25 + b.x * 0.75, y = a.y * 0.25 + b.y * 0.75 }
    end
    pts = out
  end
  return pts
end

-- Squared distance from point (px,py) to the FINITE segment AB (t clamped to the segment) - for hot proximity tests.
local function distSqPointSeg2D(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  local t = (l2 > 1e-12) and ((px - ax) * dx + (py - ay) * dy) / l2 or 0
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local ex, ey = px - (ax + dx * t), py - (ay + dy * t)
  return ex * ex + ey * ey
end

-- Proper crossing of open segments AB x CD: returns the parameter t on AB in (0,1) at the interior crossing, else nil
-- (parallel, or the crossing lies on/at an endpoint). Endpoints are excluded so touching strips don't read as a fold.
local function segCrossParam2D(ax, ay, bx, by, cx, cy, dx, dy)
  local r1x, r1y = bx - ax, by - ay
  local r2x, r2y = dx - cx, dy - cy
  local denom = r1x * r2y - r1y * r2x
  if abs(denom) < 1e-9 then return nil end
  local sx, sy = cx - ax, cy - ay
  local t = (sx * r2y - sy * r2x) / denom
  local u = (sx * r1y - sy * r1x) / denom
  if t > 1e-4 and t < 1 - 1e-4 and u > 1e-4 and u < 1 - 1e-4 then return t end
  return nil
end

-- 2D point-in-polygon (ray cast) for a ring of {x=,y=} verts. Winding-agnostic (even-odd).
local function pointInRing2D(px, py, ring)
  local n, inside = #ring, false
  local j = n
  for i = 1, n do
    local a, b = ring[i], ring[j]
    if ((a.y > py) ~= (b.y > py)) and (px < (b.x - a.x) * (py - a.y) / (b.y - a.y) + a.x) then
      inside = not inside
    end
    j = i
  end
  return inside
end

-- One side of a box kept, Sutherland-Hodgman. The cut lands exactly on the line, so the corner two cuts make is the box's
-- own corner to the last bit.
local function clipAxis(pts, a, b, c, keepLess)
  local out, n = {}, #pts
  if n == 0 then return out end
  local s = keepLess and -1 or 1
  local p = pts[n]
  local pin = (p[a] - c) * s >= 0
  for i = 1, n do
    local q = pts[i]
    local qin = (q[a] - c) * s >= 0
    if qin ~= pin then
      local t = (c - p[a]) / (q[a] - p[a])
      out[#out + 1] = { [a] = c, [b] = p[b] + (q[b] - p[b]) * t }
    end
    if qin then out[#out + 1] = q end
    p, pin = q, qin
  end
  return out
end

-- A ring cut to the box x0..x1, y0..y1. A concave ring comes back as one ring that runs along the box edge between its
-- pieces, which covers the same ground inside the box.
local function clipRingRect2D(pts, x0, x1, y0, y1)
  pts = clipAxis(pts, 'x', 'y', x0, false)
  pts = clipAxis(pts, 'x', 'y', x1, true)
  pts = clipAxis(pts, 'y', 'x', y0, false)
  return clipAxis(pts, 'y', 'x', y1, true)
end

-- Point-in-triangle (2D, barycentric). Scalar (no vec3 alloc) for tight inner loops such as ear clipping.
local function pointInTri2D(px, py, ax, ay, bx, by, cx, cy)
  local v0x, v0y = cx - ax, cy - ay
  local v1x, v1y = bx - ax, by - ay
  local v2x, v2y = px - ax, py - ay
  local d00 = v0x * v0x + v0y * v0y
  local d01 = v0x * v1x + v0y * v1y
  local d02 = v0x * v2x + v0y * v2y
  local d11 = v1x * v1x + v1y * v1y
  local d12 = v1x * v2x + v1y * v2y
  local denom = d00 * d11 - d01 * d01
  if denom == 0 then return false end
  local inv = 1.0 / denom
  local u = (d11 * d02 - d01 * d12) * inv
  local v = (d00 * d12 - d01 * d02) * inv
  return u >= 0 and v >= 0 and (u + v) <= 1
end

-- A ring handed over CLOSED -- its first point repeated at the end, which is what a walk along the edges wants -- with the
-- repeat dropped. The same array back when there is no repeat, so the usual case costs a comparison.
local function openRing2D(r)
  local n = #r
  if n < 2 or r[n].x ~= r[1].x or r[n].y ~= r[1].y then return r end
  local out = {}
  for i = 1, n - 1 do out[i] = r[i] end
  return out
end

-- Ear-clipping triangulation of a simple 2D polygon (array of {x=,y=} verts, either winding).
-- The closing repeat has to go before any of this: it is a zero-length edge, so the corner on either side of it has no turn
-- in it and neither can ever be clipped as an ear. On most outlines the clip gets round them; on some it stalls, comes up
-- short of the n-2 triangles a cap needs, and the WHOLE cap is thrown away.
local function triangulatePolygon2D(poly)
  poly = openRing2D(poly)
  local n = #poly
  local tris = {}
  if n < 3 then return tris end
  -- Index list in CCW order (reverse a CW ring) so the convex/ear tests share one winding.
  local idx, area2 = {}, 0
  for i = 1, n do local j = (i % n) + 1; area2 = area2 + (poly[i].x * poly[j].y - poly[j].x * poly[i].y) end
  if area2 < 0 then for i = 1, n do idx[i] = n - i + 1 end else for i = 1, n do idx[i] = i end end
  local m, guard = n, 0
  while m > 3 and guard < 8 * n do
    guard = guard + 1
    local bestI, bestQ, forceI = nil, -1, nil
    for i = 1, m do
      local ip, ic, inx = idx[i == 1 and m or i - 1], idx[i], idx[i == m and 1 or i + 1]
      local ax, ay, bx, by, cx, cy = poly[ip].x, poly[ip].y, poly[ic].x, poly[ic].y, poly[inx].x, poly[inx].y
      local cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
      if cross > 1e-10 then -- convex corner
        if not forceI then forceI = i end
        local ear = true
        local ex, ey = cx - ax, cy - ay
        local L2 = ex * ex + ey * ey
        for j = 1, m do
          local ij = idx[j]
          if ij ~= ip and ij ~= ic and ij ~= inx then
            local px, py = poly[ij].x, poly[ij].y
            -- Skip a point that coincides exactly with a corner (e.g. a hole-bridge seam duplicate) so it can't
            -- falsely block an otherwise valid ear; a strict no-op for rings with distinct vertices.
            local onCorner = (px == ax and py == ay) or (px == bx and py == by) or (px == cx and py == cy)
            if not onCorner then
              -- A vertex ON the diagonal the ear closes is inside it in exact arithmetic but either side in floating point;
              -- clipped past, it is left hanging on a straight run with nothing to close it, and the whole cap fails.
              local t = ((px - ax) * ex + (py - ay) * ey) / L2
              local off = ex * (py - ay) - ey * (px - ax)
              if (t > 0 and t < 1 and off * off <= 1e-12 * L2) or pointInTri2D(px, py, ax, ay, bx, by, cx, cy) then
                ear = false; break
              end
            end
          end
        end
        if ear then
          -- Area over summed edge lengths: highest for an equilateral ear, towards zero for a sliver. Clipping the BEST
          -- ear rather than the first is what keeps a cap off long thin triangles, which the GPU shades in 2x2 pixel
          -- quads and so pays for at up to four times their coverage.
          local q = cross / ((bx - ax) ^ 2 + (by - ay) ^ 2 + (cx - bx) ^ 2 + (cy - by) ^ 2 + (ax - cx) ^ 2 + (ay - cy) ^ 2)
          if q > bestQ then bestI, bestQ = i, q end
        end
      end
    end
    local pick = bestI or forceI
    if not pick then break end -- no convex vertex: degenerate, bail
    local ip, ic, inx = idx[pick == 1 and m or pick - 1], idx[pick], idx[pick == m and 1 or pick + 1]
    tris[#tris + 1] = { ip, ic, inx }
    table.remove(idx, pick); m = m - 1
  end
  if m == 3 then tris[#tris + 1] = { idx[1], idx[2], idx[3] } end
  if #tris ~= n - 2 then return {} end -- incomplete cap (degenerate ring): let the caller fall back
  return tris
end

-- Twice the signed area of a 2D ring ({x=,y=} verts). Positive => CCW (x-right, y-up).
local function ringSignedArea2(ring)
  local a, n = 0, #ring
  for i = 1, n do local j = (i % n) + 1; a = a + (ring[i].x * ring[j].y - ring[j].x * ring[i].y) end
  return a
end

-- Turn at b going a -> b -> c. Positive => left, so on a CCW ring a positive turn is a convex corner.
local function turn2(a, b, c)
  return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
end

-- Does the wedge of interior at ring[i] face b? On a convex corner the interior is the wedge between the two edges, on a
-- reflex one it is everything BUT that wedge, which is why the test cannot just be "left of both edges".
local function inWedge2D(ring, i, b)
  local n = #ring
  local a, prv, nxt = ring[i], ring[i == 1 and n or i - 1], ring[(i % n) + 1]
  if turn2(prv, a, nxt) > 0 then
    return turn2(a, b, nxt) <= 0 and turn2(a, prv, b) <= 0
  end
  return turn2(a, b, nxt) > 0 or turn2(a, prv, b) > 0
end

-- Which vertex of `ring` a hole whose leftmost point is M can be joined to without the bridge crossing anything.
local function bridgeTarget2D(ring, M)
  local n = #ring
  -- The ray from M along -x leaves through an edge that descends past M.y (the interior of a CCW ring lies to the left of
  -- each edge, so its left-hand boundary runs downwards). Take the nearest such edge and its lower-x end as the first guess.
  local qx, cand = -huge, nil
  for i = 1, n do
    local a, b = ring[i], ring[(i % n) + 1]
    if a.y >= M.y and M.y >= b.y and b.y ~= a.y then
      local ix = a.x + (M.y - a.y) / (b.y - a.y) * (b.x - a.x)
      if ix <= M.x and ix > qx then
        qx = ix
        cand = (a.x < b.x) and i or ((i % n) + 1)
        if ix == M.x then return cand end -- the hole is already touching this edge
      end
    end
  end
  if not cand then return nil end -- nothing to the left: the hole is not inside this ring at all

  -- Any vertex standing inside the triangle (M, where the ray landed, the guess) would have the bridge cut across it. Of
  -- those, take the one at the shallowest angle to the ray which can actually see M -- a vertex whose interior wedge faces
  -- the other way is on the far side of its own boundary, and joining to it would put the bridge outside the polygon.
  local P = ring[cand]
  local best, tanMin = cand, huge
  for i = 1, n do
    local v = ring[i]
    if v.x >= P.x and v.x <= M.x and v.x ~= M.x
       and pointInTri2D(v.x, v.y, M.x, M.y, qx, M.y, P.x, P.y) and inWedge2D(ring, i, M) then
      local t = abs(M.y - v.y) / (M.x - v.x)
      if t < tanMin or (t == tanMin and v.x > ring[best].x) then best, tanMin = i, t end
    end
  end
  return best
end

-- Merge hole rings into an outer ring with bridge edges. `count` caps how many of `holes` are taken.
local function bridgeHoles2D(outer, holes, count)
  local ring = {}
  if ringSignedArea2(outer) < 0 then
    for i = #outer, 1, -1 do ring[#ring + 1] = { x = outer[i].x, y = outer[i].y, z = outer[i].z } end
  else
    for i = 1, #outer do ring[#ring + 1] = { x = outer[i].x, y = outer[i].y, z = outer[i].z } end
  end

  -- Copy + normalise each hole to CW, note its min-x vertex, then bridge holes in ascending min-x order.
  local hs = {}
  for h = 1, (count or #holes) do
    local src = holes[h]
    if src and #src >= 3 then
      local hr = {}
      if ringSignedArea2(src) > 0 then
        for i = #src, 1, -1 do hr[#hr + 1] = { x = src[i].x, y = src[i].y, z = src[i].z } end
      else
        for i = 1, #src do hr[#hr + 1] = { x = src[i].x, y = src[i].y, z = src[i].z } end
      end
      local mi = 1
      for i = 2, #hr do
        if hr[i].x < hr[mi].x or (hr[i].x == hr[mi].x and hr[i].y < hr[mi].y) then mi = i end
      end
      hs[#hs + 1] = { ring = hr, mi = mi, mx = hr[mi].x }
    end
  end
  table.sort(hs, function(a, b) return a.mx < b.mx end)

  for hh = 1, #hs do
    local hr, mi = hs[hh].ring, hs[hh].mi
    local bi = bridgeTarget2D(ring, hr[mi])
    if bi then
      -- Splice: outer[1..bi], hole from M all the way round back to M, bridge vertex again, then outer[bi+1..].
      local merged = {}
      for i = 1, bi do merged[#merged + 1] = ring[i] end
      for k = 0, #hr do merged[#merged + 1] = hr[((mi - 1 + k) % #hr) + 1] end
      merged[#merged + 1] = { x = ring[bi].x, y = ring[bi].y, z = ring[bi].z }
      for i = bi + 1, #ring do merged[#merged + 1] = ring[i] end
      ring = merged
    end
  end
  return ring
end

-- Do these two segments cross, touch, or pass within `tol` of each other?
local function segsFoul2D(a, b, c, d, tol)
  if segCrossParam2D(a.x, a.y, b.x, b.y, c.x, c.y, d.x, d.y) then return true end
  local t2 = tol * tol
  return distSqPointSeg2D(a.x, a.y, c.x, c.y, d.x, d.y) <= t2
      or distSqPointSeg2D(b.x, b.y, c.x, c.y, d.x, d.y) <= t2
      or distSqPointSeg2D(c.x, c.y, a.x, a.y, b.x, b.y) <= t2
      or distSqPointSeg2D(d.x, d.y, a.x, a.y, b.x, b.y) <= t2
end

local function ringsFoul2D(r, s, tol)
  for i = 1, #r do
    local a, b = r[i], r[(i % #r) + 1]
    for j = 1, #s do
      if segsFoul2D(a, b, s[j], s[(j % #s) + 1], tol) then return true end
    end
  end
  return false
end

-- A hole must stand this far off anything else. Below it, the bridge to it runs down a gap narrower than the tolerance
-- the ear tests work to, and the whole cap collapses rather than the one hole.
local HOLE_CLEAR = 1e-3

-- The holes that can actually be cut: wholly inside the outline, and clear of every hole already taken. Anything else is
-- not a hole in this polygon -- it is a notch in its edge, or another hole's overlap -- and no triangulation of a ring
-- with bridges to it exists.
local function usableHoles2D(outer, holes)
  local out = {}
  for h = 1, #holes do
    local r = holes[h]
    if r and #r >= 3 and abs(ringSignedArea2(r)) > 1e-9 then
      local ok = true
      for i = 1, #r do
        if not pointInRing2D(r[i].x, r[i].y, outer) then ok = false; break end
      end
      if ok and ringsFoul2D(r, outer, HOLE_CLEAR) then ok = false end
      for k = 1, #out do
        if not ok then break end
        if ringsFoul2D(r, out[k], HOLE_CLEAR) or pointInRing2D(r[1].x, r[1].y, out[k])
           or pointInRing2D(out[k][1].x, out[k][1].y, r) then ok = false end
      end
      if ok then out[#out + 1] = openRing2D(r) end
    end
  end
  return out
end

-- Triangulate a 2D polygon that may have holes. Returns the ring the triangles index into and the triangles.
local function triangulateWithHoles2D(outer, holes)
  outer = openRing2D(outer) -- before the holes are bridged in, or the repeat ends up buried in the middle of the merged ring
  local hs = holes and #holes > 0 and usableHoles2D(outer, holes) or nil
  if not hs or #hs == 0 then return outer, triangulatePolygon2D(outer) end
  -- Ear clipping a ring carrying bridges can still stall on an arrangement that is legal but awkward, and the cost of that
  -- is the WHOLE cap. So give up the holes one at a time instead: a floor left unpierced reads as a mistake, a floor that
  -- never appears reads as a hole in the world.
  for n = #hs, 1, -1 do
    local merged = bridgeHoles2D(outer, hs, n)
    local tris = triangulatePolygon2D(merged)
    if #tris > 0 then return merged, tris end
  end
  return outer, triangulatePolygon2D(outer)
end

-- The nearest edge from `i` stepping by `step` that has a normal. A ring handed over with its first point repeated at the end
-- has a zero-length closing edge, and a corner mitred against that has one normal where it wants two, so it moves twice as far.
local function liveEdge(nx, ny, i, step, n)
  for _ = 1, n do
    if nx[i] ~= 0 or ny[i] ~= 0 then return i end
    i = (i + step - 1) % n + 1
  end
  return i
end

-- A closed ring pushed OUTWARD by a small `dist`, corners mitred.
local function outsetClosedRing2D(ring, dist)
  local n = ring and #ring or 0
  if n < 3 or not dist or dist <= 1e-9 then return ring end
  local s = (ringSignedArea2(ring) >= 0) and 1 or -1 -- outward is to the RIGHT of each directed edge when wound CCW
  local nx, ny = {}, {}
  for i = 1, n do
    local a, b = ring[i], ring[i % n + 1]
    local ex, ey = b.x - a.x, b.y - a.y
    local L = sqrt(ex * ex + ey * ey)
    if L > 1e-9 then nx[i], ny[i] = ey / L * s, -ex / L * s else nx[i], ny[i] = 0, 0 end
  end
  local out = {}
  for i = 1, n do
    local pe = liveEdge(nx, ny, (i == 1) and n or (i - 1), -1, n)
    local ce = liveEdge(nx, ny, i, 1, n)
    local mx, my = nx[pe] + nx[ce], ny[pe] + ny[ce]
    local ml = sqrt(mx * mx + my * my)
    if ml > 1e-6 then
      -- How far the VERTEX travels to move both its edges out by `dist`: a corner's bisector is shorter than the normals it
      -- splits. Capped, because at a hairpin that length runs away and would throw a spike across whatever lies beyond.
      local t = min(2 * dist / ml, dist * 4)
      out[i] = { x = ring[i].x + mx / ml * t, y = ring[i].y + my / ml * t, z = ring[i].z }
    else
      out[i] = { x = ring[i].x + nx[ce] * dist, y = ring[i].y + ny[ce] * dist, z = ring[i].z }
    end
  end
  return out
end

-- The same, but only for the sides `move[i]` picks out; every other side stays exactly on the line it was on. A vertex
-- between a side that moves and one that does not slides ALONG the stationary side to meet the moved one, so the two
-- stay a closed ring with no notch at the changeover. Vertex count is unchanged.
local function outsetRingSides2D(ring, dist, move)
  local n = ring and #ring or 0
  if n < 3 or not dist or dist <= 1e-9 or not move then return ring end
  local s = (ringSignedArea2(ring) >= 0) and 1 or -1 -- outward is to the RIGHT of each directed edge when wound CCW
  local ax, ay, px, py = {}, {}, {}, {}
  for i = 1, n do
    local a, b = ring[i], ring[i % n + 1]
    local ex, ey = b.x - a.x, b.y - a.y
    local L = sqrt(ex * ex + ey * ey)
    ax[i], ay[i] = (L > 1e-9) and ex / L or 0, (L > 1e-9) and ey / L or 0
    local d = move[i] and dist or 0
    px[i], py[i] = a.x + ay[i] * d * s, a.y - ax[i] * d * s -- a point on the side once it has moved
  end
  local out = {}
  for i = 1, n do
    local pe = (i == 1) and n or (i - 1)
    -- Where the two sides meeting at this vertex now cross. Nearly parallel ones -- a straight run split in two, or a
    -- hairpin -- either have no crossing or throw it miles away, so there the vertex just takes its own side's offset.
    local den = ax[pe] * ay[i] - ay[pe] * ax[i]
    local moved = nil
    if den > 1e-9 or den < -1e-9 then
      local t = ((px[i] - px[pe]) * ay[i] - (py[i] - py[pe]) * ax[i]) / den
      local ix, iy = px[pe] + ax[pe] * t, py[pe] + ay[pe] * t
      if (ix - ring[i].x) ^ 2 + (iy - ring[i].y) ^ 2 <= (dist * 4) ^ 2 then moved = { x = ix, y = iy, z = ring[i].z } end
    end
    out[i] = moved or { x = px[i], y = py[i], z = ring[i].z }
  end
  return out
end

-- Inset a CLOSED polygon of {x=,y=} verts inward by up to dist, along each vertex's averaged edge normal (the
-- true local inward direction, so it works on concave rings where a centroid-ward push would send points to the
-- wrong side).
local function insetClosedRing2D(ring, dist)
  local n = ring and #ring or 0
  if n < 3 or not dist or dist <= 0 then return ring end
  -- Signed area picks the winding so the inward normal points into the polygon.
  local area2 = 0
  for i = 1, n do local a, b = ring[i], ring[(i % n) + 1]; area2 = area2 + (a.x * b.y - b.x * a.y) end
  local s = (area2 >= 0) and 1 or -1 -- CCW: interior is to the LEFT of each directed edge
  local nx, ny = {}, {}            -- per-edge inward unit normals (edge i = ring[i]->ring[i+1])
  for i = 1, n do
    local a, b = ring[i], ring[(i % n) + 1]
    local ex, ey = b.x - a.x, b.y - a.y
    local el = sqrt(ex * ex + ey * ey)
    if el > 1e-9 then nx[i], ny[i] = -ey / el * s, ex / el * s else nx[i], ny[i] = 0, 0 end
  end
  local out = {}
  for i = 1, n do
    local ox, oy = ring[i].x, ring[i].y
    local pe = liveEdge(nx, ny, (i == 1) and n or (i - 1), -1, n) -- previous edge
    local ce = liveEdge(nx, ny, i, 1, n)
    local mx, my = nx[pe] + nx[ce], ny[pe] + ny[ce]
    local ml = sqrt(mx * mx + my * my)
    if ml > 1e-6 then
      local dx, dy = mx / ml, my / ml
      -- How far the VERTEX travels to move both its edges in by `dist`: a corner's bisector is shorter than the
      -- normals it splits, so at a right angle it has to run out by root two. `ml` falls with the corner's angle.
      local t = 2 * dist / ml
      if not pointInRing2D(ox + dx * t, oy + dy * t, ring) then
        local lo, hi = 0, dist -- largest offset that stays inside
        for _ = 1, 7 do
          local mid = (lo + hi) * 0.5
          if pointInRing2D(ox + dx * mid, oy + dy * mid, ring) then lo = mid else hi = mid end
        end
        t = lo * 0.9 -- small margin off the boundary
      end
      out[i] = { x = ox + dx * t, y = oy + dy * t, z = ring[i].z }
    else
      out[i] = { x = ox, y = oy, z = ring[i].z }
    end
  end
  return out
end

-- Split a 2D polyline into the runs that stay clear of a blocked region.
local function splitPolylineByBlocked(pts, isBlocked, stepM, minKeepM)
  local n = pts and #pts or 0
  local runs = {}
  if n < 1 then return runs end
  stepM = stepM and stepM > 0.05 and stepM or 1.0
  if n == 1 then
    if not isBlocked(pts[1].x, pts[1].y) then runs[1] = { { x = pts[1].x, y = pts[1].y } } end
    return runs
  end
  local prevBlocked = isBlocked(pts[1].x, pts[1].y)
  local cur = (not prevBlocked) and { { x = pts[1].x, y = pts[1].y } } or nil
  local px, py = pts[1].x, pts[1].y
  for j = 1, n - 1 do
    local ax, ay = pts[j].x, pts[j].y
    local bx, by = pts[j + 1].x, pts[j + 1].y
    local dx, dy = bx - ax, by - ay
    local steps = max(1, ceil(sqrt(dx * dx + dy * dy) / stepM))
    for s = 1, steps do
      local t = s / steps
      local sx, sy = ax + dx * t, ay + dy * t
      local blk = isBlocked(sx, sy)
      if blk ~= prevBlocked then
        local mx, my = (px + sx) * 0.5, (py + sy) * 0.5 -- boundary ~ midpoint of the crossing step
        if prevBlocked then
          cur = { { x = mx, y = my } }                 -- blocked -> clear: open a run at the boundary
        elseif cur then
          cur[#cur + 1] = { x = mx, y = my }; runs[#runs + 1] = cur; cur = nil -- clear -> blocked: close it
        end
        prevBlocked = blk
      end
      if s == steps and not blk and cur then cur[#cur + 1] = { x = bx, y = by } end -- keep the original node
      px, py = sx, sy
    end
  end
  if cur then runs[#runs + 1] = cur end
  local out = {}
  for r = 1, #runs do
    local run = runs[r]
    if #run >= 2 then
      local L = 0
      for k = 2, #run do
        local ddx, ddy = run[k].x - run[k - 1].x, run[k].y - run[k - 1].y
        L = L + sqrt(ddx * ddx + ddy * ddy)
      end
      if L >= (minKeepM or 0) then out[#out + 1] = run end
    end
  end
  return out
end

-- Z of the first sample at arc distance `dist` from start or finish tip.
local function polylineZAtArcFromTip(pts, cum, total, fromStart, dist)
  dist = min(max(dist, 0), total)
  local n = #pts
  if fromStart then
    for i = 2, n do
      if cum[i] >= dist then return pts[i].z end
    end
    return pts[n].z
  end
  for i = n - 1, 1, -1 do
    if (total - cum[i]) >= dist then return pts[i].z end
  end
  return pts[1].z
end

-- Unit XY direction outward past a tip (away from the polyline). Walks minWalkM
-- along the chain so a short back-folded first segment cannot reverse the aim.
local function tipOutwardXY(pts, fromStart, minWalkM)
  local n = pts and #pts or 0
  if n < 2 then return 0, 0 end
  local tipI = fromStart and 1 or n
  local step = fromStart and 1 or -1
  local tip = pts[tipI]
  local i, acc = tipI, 0
  while acc < (minWalkM or 0) do
    local j = i + step
    if j < 1 or j > n then break end
    local dx, dy = pts[j].x - pts[i].x, pts[j].y - pts[i].y
    acc = acc + sqrt(dx * dx + dy * dy)
    i = j
  end
  local ax, ay = pts[i].x - tip.x, pts[i].y - tip.y
  local len = sqrt(ax * ax + ay * ay)
  if len < 1e-9 then return 0, 0 end
  return -ax / len, -ay / len
end

-- Computes the (small) angle between two unit vectors, in radians.
local function angleBetweenVecsNorm(a, b) return acos(a:dot(b)) end

-- Computes the (small) angle between two vectors of arbitrary length, in radians.
local function angleBetweenVecs(a, b)
  tmp0:set(a)
  tmp0:normalize()
  tmp1:set(b)
  tmp1:normalize()
  return acos(tmp0:dot(tmp1))
end

-- Compute the signed angle between two vectors around a given axis.
-- [Assumes vectors are in plane of rotation.]
local function signedAngleBetweenVecs(a, b, axis)
  local dotAB = clamp(a:dot(b), -1, 1)
  local angle = acos(dotAB)
  tmp0:setCross(a, b)
  local sign = tmp0:dot(axis) >= 0 and 1 or -1
  return angle * sign
end

-- Compute the signed angle between two vectors around a given axis.
-- [Vectors are projected onto the plane of rotation before computation.]
local function signedAngleAroundAxis(fromVec, toVec, axis)
  local fromProj = fromVec:projectToOriginPlane(axis)
  local toProj = toVec:projectToOriginPlane(axis)
  local dot = max(-1, min(1, fromProj:dot(toProj)))
  local angle = acos(dot) -- The unsigned angle.
  local sign = (fromProj:cross(toProj)):dot(axis) >= 0 and 1 or -1 -- Determine the sign of the angle.
  return angle * sign * (180 / pi) -- Signed angle in degrees.
end

-- Inverse bilinear on the XY plane: the (u, v) with p = lerp(lerp(q1, q2, u), lerp(q3, q4, u), v), or nil
-- when p lies outside the quad. u runs across q1->q2, v along q1->q3.
local function quadUV(px, py, q1, q2, q3, q4)
  local ex, ey = q2.x - q1.x, q2.y - q1.y
  local fx, fy = q3.x - q1.x, q3.y - q1.y
  local gx, gy = q4.x - q3.x - ex, q4.y - q3.y - ey
  local hx, hy = px - q1.x, py - q1.y
  local A = gx * fy - gy * fx
  local B = ex * fy - ey * fx + hx * gy - hy * gx
  local C = hx * ey - hy * ex

  local v1, v2
  if abs(A) < 1e-9 then -- untwisted quad (g parallel to f): the quadratic degenerates to a linear equation
    if abs(B) < 1e-12 then return nil end
    v1 = -C / B
  else
    local disc = B * B - 4 * A * C
    if disc < 0 then return nil end -- p is off the surface entirely
    -- Both roots via the cancellation-free pairing, so they stay accurate for the near-untwisted quads that
    -- make up most of a ribbon (where A is small and the naive formula loses all of its digits).
    local sq = sqrt(disc)
    local qq = -0.5 * (B + (B >= 0 and sq or -sq))
    v1 = qq / A
    if abs(qq) > 1e-30 then v2 = C / qq end
  end

  for i = 1, 2 do
    local v = (i == 1) and v1 or v2
    if v and v == v and v >= 0 and v <= 1 then
      local dx, dy = ex + v * gx, ey + v * gy
      local u = (abs(dx) > abs(dy)) and ((hx - fx * v) / dx) or ((hy - fy * v) / dy)
      if u == u and u >= 0 and u <= 1 then
        -- Both coordinates, not just the one u came from: on a quad collapsed to a triangle v = 1 is always a root, and
        -- with p in line with the collapsed edge that one coordinate holds for any v -- a point metres off reads as inside.
        local rx, ry = hx - (ex + gx * v) * u - fx * v, hy - (ey + gy * v) * u - fy * v
        if rx * rx + ry * ry <= 1e-6 then return u, v end
      end
    end
  end
  return nil
end

-- Intersects the given point with the given quadrilateral, and returns the height at the intersection point.
local function intersectsUpQuadBarycentric(p, q)
  local u, v = quadUV(p.x, p.y, q[1], q[2], q[3], q[4])
  if u then
    return lerp(lerp(q[1].z, q[2].z, u), lerp(q[3].z, q[4].z, u), v)
  end
  return false
end

-- Determines if the given point is inside the given quadrilateral.
local function pointInQuadBarycentric(p, q)
  return quadUV(p.x, p.y, q[1], q[2], q[3], q[4]) ~= nil
end

-- Computes the bounding box of the given sources.
local function computeSourcesAABB(sources)
  local xMin, xMax, yMin, yMax = huge, -huge, huge, -huge
  for i = 1, #sources do
    local source = sources[i]
    for j = 1, #source do
      local p = source[j].pos
      local x, y = p.x, p.y
      xMin, xMax, yMin, yMax = min(xMin, x), max(xMax, x), min(yMin, y), max(yMax, y)
    end
  end
  return { xMin = xMin, xMax = xMax, yMin = yMin, yMax = yMax }
end

-- Gets quadrilaterals, with lateral bloating (no longitudinal stretching).
local function getAllQuadrilaterals(sources, margin)
  local quads, ctr = {}, 1
  for i = 1, #sources do
    local source = sources[i]
    for j = 2, #source do
      local s1, s2 = source[j - 1], source[j]
      local p1, p2 = s1.pos, s2.pos
      if j == 2 then
        p1 = p1 + (p1 - p2):normalized() * margin -- Bloat the first point longitudinally.
      elseif j == #source then
        p2 = p2 + (p2 - p1):normalized() * margin -- Bloat the last point longitudinally.
      end
      local bin1, bin2 = s1.binormal, s2.binormal
      local hw1, hw2 = s1.width * 0.5 + margin, s2.width * 0.5 + margin -- Half widths, bloated laterally.
      local lateral1, lateral2 = bin1 * hw1, bin2 * hw2
      quads[ctr] = { p1 - lateral1, p1 + lateral1, p2 - lateral2, p2 + lateral2 } -- Set quad, widened sideways only (not lengthened).
      ctr = ctr + 1
    end
  end
  return quads
end

-- Creates and populates a kd-tree containing the given quadrilaterals.
local function populateTreeQuads(quads)
  local tree = kdTreeB2d.new(#quads)
  for i = 1, #quads do
    local q = quads[i]
    local q1, q2, q3, q4 = q[1], q[2], q[3], q[4]
    local q1X, q1Y, q2X, q2Y, q3X, q3Y, q4X, q4Y = q1.x, q1.y, q2.x, q2.y, q3.x, q3.y, q4.x, q4.y
    tree:preLoad(i, min(q1X, q2X, q3X, q4X), min(q1Y, q2Y, q3Y, q4Y), max(q1X, q2X, q3X, q4X), max(q1Y, q2Y, q3Y, q4Y))
  end
  tree:build()
  return tree
end

-- Splits a spline at the given node index, returning two sets of geometry.
-- [Returns: nodes1, widths1, nmls1, nodes2, widths2, nmls2 (split arrays).]
-- Copies a per-node corner-override entry so split/join hand each output spline its OWN entry instead of aliasing the source's.
-- An entry is either false (auto) or a small flat table of overrides ({ radiusM, extraWidenM, apron, superElevDeg, taperM }); the
-- non-table case passes straight through. Keeps the engineered per-corner settings (e.g. corner radius) alive across cut/join.
local function copyCorner(c)
  if type(c) == 'table' then
    local t = {}
    for k, v in pairs(c) do t[k] = v end
    return t
  end
  return c or false -- nil (a sparse hole) or false -> auto; keeps the carried array DENSE so splineInput's index math stays valid.
end

-- `corners` (optional) is a parallel per-node override array carried through the split so engineered tools keep their per-corner
-- radius/widen/etc. It is returned as two extra trailing values (corners1, corners2), index-aligned to nodes1/nodes2; callers that
-- don't pass it get nil and are unaffected.
local function splitSplineGeometry(nodes, widths, nmls, splitNodeIdx, corners)
  local numNodes = #nodes
  if splitNodeIdx < 1 or splitNodeIdx > numNodes then
    return nil, nil, nil, nil, nil, nil -- Invalid split index.
  end

  -- Copy the first half of the geometry.
  local nodes1, widths1, nmls1, corners1 = {}, {}, {}, corners and {} or nil
  for i = 1, splitNodeIdx do
    nodes1[i], widths1[i], nmls1[i] = vec3(nodes[i]), widths[i], vec3(nmls[i])
    if corners then corners1[i] = copyCorner(corners[i]) end
  end

  -- Copy the second half of the geometry.
  local nodes2, widths2, nmls2, corners2 = {}, {}, {}, corners and {} or nil
  for i = splitNodeIdx, numNodes do
    local j = i - splitNodeIdx + 1
    nodes2[j], widths2[j], nmls2[j] = vec3(nodes[i]), widths[i], vec3(nmls[i])
    if corners then corners2[j] = copyCorner(corners[i]) end
  end

  -- Push apart the shared split point for visual clarity.
  if #nodes1 > 1 and #nodes2 > 1 then
    local tangent = nodes[min(numNodes, splitNodeIdx + 1)] - nodes[max(1, splitNodeIdx - 1)]
    tangent:normalize()
    local offset = tangent * splitPartingDistance

    -- Move the end of first spline away from split point.
    nodes1[#nodes1] = nodes1[#nodes1] - offset
    -- Move the start of second spline away from split point.
    nodes2[1] = nodes2[1] + offset
  end

  return nodes1, widths1, nmls1, nodes2, widths2, nmls2, corners1, corners2
end

-- Splits a loop spline at the given node index, returning reordered geometry.
-- [Returns: nodesNew, widthsNew, nmlsNew (reordered loop arrays).]
-- `corners` (optional) is carried through the reorder and returned as a 4th value (cornersNew), index-aligned to nodesNew.
local function splitLoopSplineGeometry(nodes, widths, nmls, splitNodeIdx, corners)
  local numNodes = #nodes
  if splitNodeIdx < 1 or splitNodeIdx > numNodes then
    return nil, nil, nil -- Invalid split index.
  end

  local nodesNew, widthsNew, nmlsNew, cornersNew, ctr = {}, {}, {}, corners and {} or nil, 1
  for i = splitNodeIdx, numNodes do -- Copy from split point to end.
    nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(nodes[i]), widths[i], vec3(nmls[i])
    if corners then cornersNew[ctr] = copyCorner(corners[i]) end
    ctr = ctr + 1
  end
  for i = 1, splitNodeIdx - 1 do -- Copy from start to split point.
    nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(nodes[i]), widths[i], vec3(nmls[i])
    if corners then cornersNew[ctr] = copyCorner(corners[i]) end
    ctr = ctr + 1
  end

  -- Push apart the two splines at the split point.
  if #nodesNew > 1 then
    local tangent = nodesNew[2] - nodesNew[#nodesNew]
    tangent:normalize()
    local offset = tangent * splitPartingDistance
    nodesNew[1] = nodesNew[1] + offset
    nodesNew[#nodesNew] = nodesNew[#nodesNew] - offset
  end

  return nodesNew, widthsNew, nmlsNew, cornersNew
end

-- Joins two spline geometries at the specified node indices.
local function joinSplineGeometry(n1, w1, nm1, nodeIdx1, n2, w2, nm2, nodeIdx2, c1, c2)
  local wantC = c1 ~= nil and c2 ~= nil
  local nodesNew, widthsNew, nmlsNew, cornersNew, ctr = {}, {}, {}, wantC and {} or nil, 1

  if nodeIdx1 == 1 and nodeIdx2 == 1 then -- Start-Start: reverse spline2, append spline1.
    for i = #n2, 1, -1 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n2[i]), w2[i], vec3(nm2[i])
      if wantC then cornersNew[ctr] = copyCorner(c2[i]) end
      ctr = ctr + 1
    end
    for i = 2, #n1 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n1[i]), w1[i], vec3(nm1[i])
      if wantC then cornersNew[ctr] = copyCorner(c1[i]) end
      ctr = ctr + 1
    end
  elseif nodeIdx1 == 1 and nodeIdx2 == #n2 then -- Start-End: append spline2, then spline1.
    for i = 1, #n2 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n2[i]), w2[i], vec3(nm2[i])
      if wantC then cornersNew[ctr] = copyCorner(c2[i]) end
      ctr = ctr + 1
    end
    for i = 2, #n1 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n1[i]), w1[i], vec3(nm1[i])
      if wantC then cornersNew[ctr] = copyCorner(c1[i]) end
      ctr = ctr + 1
    end
  elseif nodeIdx1 == #n1 and nodeIdx2 == 1 then -- End-Start: append spline2 to spline1.
    for i = 1, #n1 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n1[i]), w1[i], vec3(nm1[i])
      if wantC then cornersNew[ctr] = copyCorner(c1[i]) end
      ctr = ctr + 1
    end
    for i = 2, #n2 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n2[i]), w2[i], vec3(nm2[i])
      if wantC then cornersNew[ctr] = copyCorner(c2[i]) end
      ctr = ctr + 1
    end
  elseif nodeIdx1 == #n1 and nodeIdx2 == #n2 then -- End-End: reverse spline2, append to spline1.
    for i = 1, #n1 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n1[i]), w1[i], vec3(nm1[i])
      if wantC then cornersNew[ctr] = copyCorner(c1[i]) end
      ctr = ctr + 1
    end
    for i = #n2 - 1, 1, -1 do
      nodesNew[ctr], widthsNew[ctr], nmlsNew[ctr] = vec3(n2[i]), w2[i], vec3(nm2[i])
      if wantC then cornersNew[ctr] = copyCorner(c2[i]) end
      ctr = ctr + 1
    end
  else
    return nil, nil, nil -- Invalid node indices.
  end

  return nodesNew, widthsNew, nmlsNew, cornersNew
end

-- Flips the direction of the given spline.
local function flipSplineDirection(spline)
  local nodes, widths, nmls = spline.nodes, spline.widths, spline.nmls
  local newNodes, newWidths, newNmls = {}, {}, {}
  for i = #nodes, 1, -1 do
    table.insert(newNodes, nodes[i])
    table.insert(newWidths, widths[i])
    table.insert(newNmls, nmls[i])
  end
  spline.nodes, spline.widths, spline.nmls = newNodes, newWidths, newNmls
  local corners = spline.corners -- engineered per-corner overrides, aligned with the nodes
  if corners then
    local newCorners = {}
    for i = #nodes, 1, -1 do newCorners[#newCorners + 1] = corners[i] or false end
    spline.corners = newCorners
  end
  spline.isDirty = true
end

-- Compute the closest point on the given ribbon segment, to the given point.
local function closestRibbonSegPointToPoint(segIdx, ribbon, p)
  if segIdx <= ribbon.numSegs then
    local twoSegIdx = segIdx * 2
    local i1, i2, i3, i4 = twoSegIdx - 1, twoSegIdx, twoSegIdx + 1, twoSegIdx + 2
    local nodes = ribbon.nodes
    local c0, c1, c2, c3 = nodes[i1], nodes[i2], nodes[i3], nodes[i4]
    local pT1 = p:triangleClosestPoint(c0, c1, c2)
    local pT2 = p:triangleClosestPoint(c1, c2, c3)
    local dSq1, dSq2 = p:squaredDistance(pT1), p:squaredDistance(pT2)
    if dSq2 < dSq1 then
      return pT2, dSq2
    end
    return pT1, dSq1
  end
  return nil, nil
end

-- Given a polyline and a polygon, returns sequences of consecutive indices that are inside the polygon.
local function getNodeSpansInsidePolygon(nodes, polygon)
  local spans, ctr = {}, 1
  local currentSpan = nil
  for i = 1, #nodes do
    if nodes[i]:inPolygon(polygon) then
      if not currentSpan then
        currentSpan = { i, i } -- start a new span.
      else
        currentSpan[2] = i -- extend current span.
      end
    else
      if currentSpan then
        spans[ctr] = currentSpan
        ctr = ctr + 1
        currentSpan = nil
      end
    end
  end
  if currentSpan then
    spans[ctr] = currentSpan -- Capture final span if list ends while inside.
    ctr = ctr + 1
  end
  return spans
end

-- Projects the given point onto the given spline.
-- [Returns: closest point (p), s in [0,1], t in [-inf,inf]; or nil if outside segment bounds.]
local function projectPointToSpline(pos, spline)
  local divPoints, binormals, widths = spline.divPoints, spline.binormals, spline.divWidths
  local bestDistSq, bestProj, bestS = huge, nil, 0.0
  local bestIdx, bestT, bestSegment = 1, 0.0, 1

  -- Precompute segment lengths and total
  local segLengths, totalLength = table.new(#divPoints, 0), 0.0
  for i = 1, #divPoints - 1 do
    local len = divPoints[i]:distance(divPoints[i + 1])
    segLengths[i] = len
    totalLength = totalLength + len
  end

  -- Find closest projection
  local accumulated = 0.0
  for i = 1, #divPoints - 1 do
    local p0, p1 = divPoints[i], divPoints[i + 1]
    local seg = p1 - p0
    local lenSq = seg:squaredLength()
    if lenSq > 0 then
      local t = clamp((pos - p0):dot(seg) / lenSq, 0, 1)
      local proj = p0 + seg * t
      local distSq = (proj - pos):squaredLength()
      if distSq < bestDistSq then
        bestDistSq = distSq
        bestProj = proj
        bestS = (accumulated + segLengths[i] * t) / totalLength
        bestIdx = i
        bestT = t
        bestSegment = i
      end
    end
    accumulated = accumulated + segLengths[i]
  end

  -- Reject if projected onto the first or last segment near their outer ends
  local numSegs = #divPoints - 1
  local edgeTol = 1e-3
  if (bestSegment == 1     and bestT < edgeTol) or
     (bestSegment == numSegs and bestT > 1.0 - edgeTol) then
    return nil, nil, nil
  end

  -- Interpolate binormal and width
  local bin = lerp(binormals[bestIdx], binormals[bestIdx + 1], bestT)
  bin:normalize()
  local width = widths[bestIdx] * (1 - bestT) + widths[bestIdx + 1] * bestT

  local t = 2.0 * (pos - bestProj):dot(bin) / width
  return bestProj, bestS, t
end

-- Sample along true arc-length of the given polyline, to compute the positions and Frenet frame at regular intervals.
-- [Returns: outPosns, outTans, outNormals]
local function sampleSpline(divPoints, tangents, normals, spacing, outPosns, outTans, outNormals)
  table.clear(outPosns); table.clear(outTans); table.clear(outNormals)
  if not (spacing > 0) then return end
  local nextDist, accDist, ctr, i = 0.0, 0.0, 1, 2
  while i <= #divPoints do
    local iMinusOne = i - 1
    local p1, p2 = divPoints[iMinusOne], divPoints[i]
    tmpTangent:set(p2.x - p1.x, p2.y - p1.y, p2.z - p1.z)
    local segLen = tmpTangent:length()
    if segLen ~= segLen or accDist + segLen < nextDist then -- NaN segment, or can't reach the next sample: move on.
      if segLen == segLen then accDist = accDist + segLen end
      i = i + 1
    else
      local t = (nextDist - accDist) / segLen
      tmp0:setScaled2(tmpTangent, t)
      tmp0:setAdd2(p1, tmp0)
      outPosns[ctr] = vec3(tmp0)
      outTans[ctr] = lerp(tangents[iMinusOne], tangents[i], t)
      outTans[ctr]:normalize()
      outNormals[ctr] = lerp(normals[iMinusOne], normals[i], t)
      outNormals[ctr]:normalize()
      ctr = ctr + 1
      nextDist = nextDist + spacing
    end
  end
end

-- Even-fit sampler for discrete props (lamp posts / bollards).
local function sampleSplineEvenFit(divPoints, tangents, normals, targetSpacing, isLoop, outPosns, outTans, outNormals)
  table.clear(outPosns); table.clear(outTans); table.clear(outNormals)
  local np = #divPoints
  if np < 2 or not (targetSpacing > 0) then return end

  -- Total arc length along the dense polyline (matches what the walk below traverses).
  local totalLen = 0.0
  for i = 2, np do
    tmpTangent:set(divPoints[i].x - divPoints[i - 1].x, divPoints[i].y - divPoints[i - 1].y, divPoints[i].z - divPoints[i - 1].z)
    totalLen = totalLen + tmpTangent:length()
  end
  if not (totalLen > 0) then return end

  local n = max(1, floor(totalLen / targetSpacing + 0.5)) -- interval count whose spacing is closest to the target.
  local step = totalLen / n

  -- Walk the polyline once, emitting n samples at arc 0, step, 2*step, ... (start + interior; for an open run the final
  -- end sample is forced on afterwards, for a loop these n samples already close the ring without a duplicate).
  local ctr, nextDist, accDist, i = 1, 0.0, 0.0, 2
  while ctr <= n and i <= np do
    local iMinusOne = i - 1
    local p1, p2 = divPoints[iMinusOne], divPoints[i]
    tmpTangent:set(p2.x - p1.x, p2.y - p1.y, p2.z - p1.z)
    local segLen = tmpTangent:length()
    if segLen ~= segLen or accDist + segLen < nextDist then
      if segLen == segLen then accDist = accDist + segLen end
      i = i + 1
    else
      local t = segLen > 0 and ((nextDist - accDist) / segLen) or 0
      tmp0:setScaled2(tmpTangent, t)
      tmp0:setAdd2(p1, tmp0)
      outPosns[ctr] = vec3(tmp0)
      outTans[ctr] = lerp(tangents[iMinusOne], tangents[i], t)
      outTans[ctr]:normalize()
      outNormals[ctr] = lerp(normals[iMinusOne], normals[i], t)
      outNormals[ctr]:normalize()
      ctr = ctr + 1
      nextDist = nextDist + step
    end
  end

  -- Open spline: force the final sample exactly onto the end point so the run always terminates with an item there
  -- (float drift in the walk can otherwise miss the last position). Loops intentionally skip this.
  if not isLoop then
    outPosns[n + 1] = vec3(divPoints[np])
    outTans[n + 1] = vec3(tangents[np]); outTans[n + 1]:normalize()
    outNormals[n + 1] = vec3(normals[np]); outNormals[n + 1]:normalize()
  end
end

-- Road-ribbon up for a unit along direction: up ⊥ along, bank from upRef.
-- prevAcross (optional vec3) keeps lateral sign continuous across a placement run.
local function ribbonUpFromAlong(along, upRef, outUp, prevAcross)
  tmp1:setCross(along, upRef)
  if tmp1:squaredLength() < 1e-12 then
    tmp1:setCross(along, globalUp)
  end
  if tmp1:squaredLength() < 1e-12 then
    tmp1:set(1, 0, 0)
  else
    tmp1:normalize()
  end
  if prevAcross and prevAcross:squaredLength() > 1e-12 and tmp1:dot(prevAcross) < 0 then
    tmp1:setScaled(-1)
  end
  outUp:setCross(tmp1, along)
  if outUp:squaredLength() < 1e-12 then
    outUp:set(globalUp)
  else
    outUp:normalize()
  end
  if outUp:dot(upRef) < 0 then
    tmp1:setScaled(-1)
    outUp:setScaled(-1)
  end
  if prevAcross then prevAcross:set(tmp1) end
end

-- Mid-interval frame for rigid kit panels on a graded/banked edge (fences, barriers).
local function ribbonIntervalFrame(p1, p2, t1, t2, n1, n2, outPos, outTan, outUp, prevAcross)
  outPos:setAdd2(p1, p2)
  outPos:setScaled2(outPos, 0.5)
  outTan:setSub2(p2, p1)
  if outTan:squaredLength() < 1e-12 then -- Degenerate interval: fall back to station tangents.
    local tb = t2 or t1
    outTan:setAdd2(t1, tb)
  end
  if outTan:squaredLength() < 1e-12 then
    outTan:set(1, 0, 0)
  else
    outTan:normalize()
  end
  local nb = n2 or n1
  tmp0:setAdd2(n1, nb)
  if tmp0:squaredLength() < 1e-12 then
    tmp0:set(n1)
  else
    tmp0:normalize()
  end
  if tmp0:squaredLength() < 1e-12 then
    tmp0:set(globalUp)
  end
  ribbonUpFromAlong(outTan, tmp0, outUp, prevAcross)
end

-- Estimate local curvature at a point on a polyline of vec3s.
-- Returns 0 for endpoints or degenerate segments.
local function estimateCurvatureAt(points, i)
  if i <= 1 or i >= #points then
    return 0.0
  end
  tmp0:setSub2(points[i], points[i - 1])
  tmp1:setSub2(points[i + 1], points[i])
  local len0, len1 = tmp0:length(), tmp1:length()
  if len0 < 1e-6 or len1 < 1e-6 then
    return 0.0
  end
  tmp0:normalize()
  tmp1:normalize()
  local dot = clamp(tmp0:dot(tmp1), -1, 1)
  local angle = acos(dot)
  local avgLen = 0.5 * (len0 + len1)
  return avgLen < 1e-6 and 0.0 or angle / avgLen
end

-- Adaptive sampling along the given spline, to compute the positions and Frenet frame at regular intervals.
-- [Adaptive in the sense that small curvature segments are sampled more densely, and large curvature segments are sampled more sparsely.]
-- [Returns: outPosns, outTans, outNormals, outScales]
local function sampleSplineAdaptive(divPoints, tangents, normals, meshLength, outPosns, outTans, outNormals, outScales)
  table.clear(outPosns); table.clear(outTans); table.clear(outNormals); table.clear(outScales)
  -- Same termination guard as sampleSpline: a non-finite / non-positive meshLength would stall nextDist and spin forever.
  if not (meshLength > 0) then return end
  local nextDist, accDist, ctr, i = 0.0, 0.0, 1, 2
  while i <= #divPoints do
    local iMinusOne = i - 1
    local p1, p2 = divPoints[iMinusOne], divPoints[i]
    tmpTangent:set(p2.x - p1.x, p2.y - p1.y, p2.z - p1.z)
    local segLen = tmpTangent:length()
    if segLen ~= segLen or accDist + segLen < nextDist then -- NaN segment, or can't reach the next sample: move on.
      if segLen == segLen then accDist = accDist + segLen end
      i = i + 1
    else
      local t = (nextDist - accDist) / segLen
      tmp0:setScaled2(tmpTangent, t)
      tmp0:setAdd2(p1, tmp0)
      outPosns[ctr] = vec3(tmp0)
      outTans[ctr] = lerp(tangents[iMinusOne], tangents[i], t)
      outTans[ctr]:normalize()
      outNormals[ctr] = lerp(normals[iMinusOne], normals[i], t)
      outNormals[ctr]:normalize()
      local curvature = estimateCurvatureAt(divPoints, i)
      outScales[ctr] = max(minScale, 1.0 / (1.0 + kappaSensitivity * curvature)) -- Maps curvature to a normalised scale [minScale, 1].
      nextDist = nextDist + meshLength * outScales[ctr]
      ctr = ctr + 1
    end
  end
end

-- Translates the given spline by the given amount on the binormal (lateral) direction.
local function translateSpline(pts, binormals, t, out)
  table.clear(out)
  for i = 1, #pts do
    local p, bin = pts[i], binormals[i]
    out[i] = vec3(p.x + bin.x * t, p.y + bin.y * t, p.z + bin.z * t)
  end
end

-- Converts curvature to banking angle in radians. maxDeg (cap on the sharpest curves) and tuning
-- (curv at which the cap is reached; higher = max reached at a tighter radius) are optional per-call
-- overrides; they default to the module constants so existing callers are unchanged.
local function curvatureToBankAngle(curv, bankStrength, maxDeg, tuning)
  local scaled = min(curv * (tuning or autoBankTuning), 1.0)
  return scaled * bankStrength * rad(maxDeg or maxBankDeg)
end

-- Rolls a spline's per-station frame by a READY-MADE signed bank fraction (bankT[i] in [-1, 1], + = curving left),
-- peakRad being the angle a full-magnitude station reaches. The caller owns both the curvature -> fraction mapping and
-- the arc-length RUNOFF that eases the roll in and out. Deriving the angle per station from local curvature here is
-- what this function used to do, and it made the bank a square wave: full tilt the instant a corner starts, flat again
-- on the straight, and a sign flip across an S-curve with nothing in between.
local function applyBankFraction(spline, bankT, peakRad)
  if not bankT or not peakRad or peakRad == 0 then return end
  local normals, binormals, tangents = spline.normals, spline.binormals, spline.tangents
  if not normals or not tangents then return end
  for i = 1, #normals do
    local f, t = bankT[i], tangents[i]
    if f and f ~= 0 and normals[i] and t then
      local ang = -f * peakRad
      normals[i]:set(rotateVecAroundAxis(normals[i], t, ang))
      if binormals and binormals[i] then binormals[i]:set(rotateVecAroundAxis(binormals[i], t, ang)) end
    end
  end
end

-- Computes a random jitter quaternion, for Z-only jitter.
local function computeRandomJitterQuat_ZOnly(jitter, nmlVec, outQuat)
  outQuat:setFromAxisAngle(nmlVec, (random() * 2 - 1) * jitter)
  return outQuat
end

-- Computes a random jitter quaternion, for component-wise jitter.
-- [The result is written into 'outQuat' (modified in-place).]
local function computeRandomJitterQuat(spline, tgt, rightVec, nmlVec, outQuat)
  outQuat:set(0, 0, 0, 1) -- Initialize to identity quaternion.
  local jitterForward, jitterRight, jitterUp = spline.jitterForward, spline.jitterRight, spline.jitterUp
  if jitterForward and jitterForward > 0.0 then
    local angleF = (random() * 2 - 1) * jitterForward
    tmpQuat:setFromAxisAngle(tgt, angleF)
    outQuat:setMul2(tmpQuat, outQuat)
  end
  if jitterRight and jitterRight > 0.0 then
    local angleR = (random() * 2 - 1) * jitterRight
    tmpQuat:setFromAxisAngle(rightVec, angleR)
    outQuat:setMul2(tmpQuat, outQuat)
  end
  if jitterUp and jitterUp > 0.0 then
    local angleU = (random() * 2 - 1) * jitterUp
    tmpQuat:setFromAxisAngle(nmlVec, angleU)
    outQuat:setMul2(tmpQuat, outQuat)
  end
  return outQuat
end

-- Computes a random jitter quaternion based on join freedom axes.
-- [The result is written into 'outQuat' (modified in-place).]
local function computeRandomJitterQuatFromFreedomAxes(spline, freedomAxes, outQuat)
  outQuat:set(0, 0, 0, 1) -- Initialize to identity.
  local jitterAmount = (spline.jitterForward + spline.jitterRight + spline.jitterUp) / 3.0
  if jitterAmount > 0.0 and freedomAxes and #freedomAxes > 0 then
    for i = 1, #freedomAxes do
      local angle = (random() * 2 - 1) * jitterAmount
      tmpQuat:setFromAxisAngle(freedomAxes[i], angle)
      outQuat:setMul2(tmpQuat, outQuat)
    end
  end
  return outQuat
end

-- Re-compute the rib points, in free-floating 3D space.
local function updateRibPointsFree(spline)
  local nodes, ribPoints = spline.nodes, spline.ribPoints
  if #nodes < 2 then
    return -- Early return if there are less than two nodes.
  end

  local widths, discMap, binormals, ctr = spline.widths, spline.discMap, spline.binormals, 1
  for i = 1, #nodes do
    local divIdx = discMap[i] -- Map the node index to the discretised geometry index.
    local bin, halfWidth = binormals[divIdx], widths[i] * 0.5
    tmp0:set(bin.x * halfWidth, bin.y * halfWidth, bin.z * halfWidth)
    local node = nodes[i]
    ribPoints[ctr] = ribPoints[ctr] or vec3()
    ribPoints[ctr]:setSub2(node, tmp0) -- Left point.
    ribPoints[ctr + 1] = ribPoints[ctr + 1] or vec3()
    ribPoints[ctr + 1]:setAdd2(node, tmp0) -- Right point.
    ctr = ctr + 2
  end

  -- Remove excess vec3 objects.
  local numRibPoints = #nodes * 2
  for i = numRibPoints + 1, #ribPoints do
    ribPoints[i] = nil
  end
end

-- Update the rib points. using vertical raycasting to conform them to the nearest surface below .
local function updateRibPointsRaycast(spline)
  local nodes, ribPoints = spline.nodes, spline.ribPoints
  if #nodes < 2 then
    return -- Early return if there are less than two nodes.
  end

  local widths, discMap, binormals, ctr = spline.widths, spline.discMap, spline.binormals, 1
  for i = 1, #nodes do
    local divIdx = discMap[i] -- Map the node index to the discretised geometry index.
    tmp0:setScaled2(binormals[divIdx], widths[i] * 0.5)
    local node = nodes[i]
    ribPoints[ctr] = ribPoints[ctr] or vec3()
    ribPoints[ctr]:setSub2(node, tmp0) -- Left point.
    ribPoints[ctr + 1] = ribPoints[ctr + 1] or vec3()
    ribPoints[ctr + 1]:setAdd2(node, tmp0) -- Right point.
    util.vertRaycast(ribPoints[ctr]) -- Conform left point to terrain.
    util.vertRaycast(ribPoints[ctr + 1]) -- Conform right point to terrain.
    ctr = ctr + 2
  end

  -- Remove excess vec3 objects.
  local numRibPoints = #nodes * 2
  for i = numRibPoints + 1, #ribPoints do
    ribPoints[i] = nil
  end
end

-- Update the bar points.
local function updateBarPoints(spline, isBarsLimits)
  local nodes, barPoints = spline.nodes, spline.barPoints
  local vals = isBarsLimits and spline.velLimits or spline.vels

  -- Ensure velocities exist for all nodes.
  if not vals or #vals == 0 then
    vals = {}
    for i = 1, #nodes do
      vals[i] = 30.0 -- Default velocity of 30 m/s.
    end
    if isBarsLimits then
      spline.velLimits = vals
    else
      spline.vels = vals
    end
  elseif #vals < #nodes then
    -- Extend velocities array if it's too short.
    for i = #vals + 1, #nodes do
      vals[i] = vals[#vals] or 30.0 -- Use last velocity or default.
    end
  end

  for i = 1, #nodes do
    util.vertRaycast(nodes[i])
    tmp1:set(nodes[i].x, nodes[i].y, nodes[i].z + vals[i] * barScale)
    barPoints[i] = barPoints[i] or vec3()
    barPoints[i]:set(tmp1)
  end

  -- Remove excess vec3 objects.
  for i = #nodes + 1, #barPoints do
    barPoints[i] = nil
  end
end

-- Update the bar points for a graph path.
-- [spline - The spline to update bar points for.]
-- [graphData - The navigation graph data.]
-- [isBarsLimit - Whether to use velLimits (true) or vels (false) for bar heights.]
local function updateBarPointsGraph(spline, graphData, isBarsLimit)
  local graphDataNodes = graphData.nodes
  local graphNodes, barPoints = spline.graphNodes, spline.barPoints
  local vals = isBarsLimit and spline.velLimits or spline.vels

  -- Ensure velocities exist for all graph nodes.
  if not vals or #vals == 0 then
    vals = {}
    for i = 1, #graphNodes do
      vals[i] = 30.0 -- Default velocity of 30 m/s.
    end
    if isBarsLimit then
      spline.velLimits = vals
    else
      spline.vels = vals
    end
  elseif #vals < #graphNodes then
    -- Extend velocities array if it's too short.
    for i = #vals + 1, #graphNodes do
      vals[i] = vals[#vals] or 30.0 -- Use last velocity or default.
    end
  end

  for i = 1, #graphNodes do
    local node = graphDataNodes[graphNodes[i]]
    util.vertRaycast(node)
    tmp1:set(node.x, node.y, node.z + vals[i] * barScale)
    barPoints[i] = barPoints[i] or vec3()
    barPoints[i]:set(tmp1)
  end

  -- Remove excess vec3 objects.
  for i = #graphNodes + 1, #barPoints do
    barPoints[i] = nil
  end
end

-- Computes the scanline spans for the given polygon.
-- [The scanline spans are the spans of the polygon on the Y-axis, in grid space.]
-- [The spans are stored in the given spansXMin, spansXMax, and spansY tables.]
local function getScanlineSpans(gMinY, gMaxY, te, tb, polygon, spansXMin, spansXMax, spansY)
  table.clear(spansXMin); table.clear(spansXMax); table.clear(spansY)
  local numPolygonNodes, ctr = #polygon, 1
  for y = gMinY, gMaxY do
    table.clear(intersections)
    tmpPoint2I.x, tmpPoint2I.y = 0, y
    local yWorld = te:gridToWorldByPoint2I(tmpPoint2I, tb).y
    local iCtr = 1
    for i = 1, numPolygonNodes do
      local a, b = polygon[i], polygon[i % numPolygonNodes + 1] -- Wrapped line segment [a, b] on polygon.
      local aX, aY, bX, bY = a.x, a.y, b.x, b.y
      if (aY <= yWorld and bY > yWorld) or (bY <= yWorld and aY > yWorld) then -- Note: Ignores odd numbers of intersections.
        local t = (yWorld - aY) / (bY - aY)
        local x = aX + t * (bX - aX)
        intersections[iCtr] = x
        iCtr = iCtr + 1
      end
    end
    table.sort(intersections)
    for i = 1, #intersections - 1, 2 do
      local x1, x2 = intersections[i], intersections[i + 1]
      tmp1:set(x1, yWorld, 0)
      te:worldToGridByPoint2I(tmp1, tmpPoint2I, tb)
      local xStart = tmpPoint2I.x
      tmp1:set(x2, yWorld, 0)
      te:worldToGridByPoint2I(tmp1, tmpPoint2I, tb)
      local xEnd = tmpPoint2I.x
      spansXMin[ctr], spansXMax[ctr], spansY[ctr] = xStart, xEnd, y
      ctr = ctr + 1
    end
  end
end

-- Computes the signed distance field (SDF) of the given mask.
local function computeSDF(mask)
  -- Initialise the distance map.
  local w, h = #mask[1], #mask
  local sdf, maxDist = {}, w + h
  for y = 1, h do
    sdf[y] = {}
    for x = 1, w do
      sdf[y][x] = mask[y][x] == 0 and 0 or maxDist
    end
  end

  -- Forward pass.
  for y = 1, h do
    for x = 1, w do
      local d = sdf[y][x]
      if x > 1 then d = min(d, sdf[y][x - 1] + 1) end
      if y > 1 then d = min(d, sdf[y - 1][x] + 1) end
      if x > 1 and y > 1 then d = min(d, sdf[y - 1][x - 1] + 1.414) end
      if x < w and y > 1 then d = min(d, sdf[y - 1][x + 1] + 1.414) end
      sdf[y][x] = d
    end
  end

  -- Backward pass.
  for y = h, 1, -1 do
    for x = w, 1, -1 do
      local d = sdf[y][x]
      if x < w then d = min(d, sdf[y][x + 1] + 1) end
      if y < h then d = min(d, sdf[y + 1][x] + 1) end
      if x < w and y < h then d = min(d, sdf[y + 1][x + 1] + 1.414) end
      if x > 1 and y < h then d = min(d, sdf[y + 1][x - 1] + 1.414) end
      sdf[y][x] = d
    end
  end

  return sdf
end

-- Fast, non-allocating version of catmullRomCentripetal
-- [If outVec is provided, sets it and returns it. Otherwise creates a new vec3.]
local function catmullRomCentripetalFast(p0, p1, p2, p3, t, s, outVec)
  outVec = outVec or vec3()
  s = s * 2
  local d1, d2, d3 = max(sqrt(p0:distance(p1)), 1e-30), max(sqrt(p1:distance(p2)), 1e-30), max(sqrt(p2:distance(p3)), 1e-30)
  local sd2, tt, t_1 = s * d2, t * t, t - 1
  local t_1sq, c21 = t_1 * t_1, s * t_1 * (t * t_1 + tt)
  local m1c, m2c = t * t_1sq * sd2, tt * t_1 * sd2
  local m1c_d1, m1c_d1d2 = m1c / d1, m1c / (d1 + d2)
  local m2c_d2d3, m2c_d3 = m2c / (d2 + d3), m2c / d3
  local t_1sq_2t1, c21_tt_2t3 = t_1sq * (2 * t + 1) - c21, c21 - tt * (2 * t - 3)
  local p0X, p0Y, p0Z = p0.x, p0.y, p0.z
  local p1X, p1Y, p1Z = p1.x, p1.y, p1.z
  local p2X, p2Y, p2Z = p2.x, p2.y, p2.z
  local p3X, p3Y, p3Z = p3.x, p3.y, p3.z
  outVec:set(
    (p1X - p0X) * m1c_d1 + (p0X - p2X) * m1c_d1d2 + (p1X - p3X) * m2c_d2d3 + (p3X - p2X) * m2c_d3 + t_1sq_2t1 * p1X + c21_tt_2t3 * p2X,
    (p1Y - p0Y) * m1c_d1 + (p0Y - p2Y) * m1c_d1d2 + (p1Y - p3Y) * m2c_d2d3 + (p3Y - p2Y) * m2c_d3 + t_1sq_2t1 * p1Y + c21_tt_2t3 * p2Y,
    (p1Z - p0Z) * m1c_d1 + (p0Z - p2Z) * m1c_d1d2 + (p1Z - p3Z) * m2c_d2d3 + (p3Z - p2Z) * m2c_d3 + t_1sq_2t1 * p1Z + c21_tt_2t3 * p2Z
  )
  return outVec
end

-- Open-spline CR neighbors. Optional spline.crGhostStart / crGhostFinish replace the clamped
-- duplicate at an end so a tip tangent can be prescribed without inventing authoring nodes.
local function crSegmentPoints(spline, j, numNodes, isLoop, nodes)
  local i1, i2, i3, i4
  if isLoop then
    i1 = ((j - 2) % numNodes) + 1
    i2 = ((j - 1) % numNodes) + 1
    i3 = (j % numNodes) + 1
    i4 = ((j + 1) % numNodes) + 1
    return nodes[i1], nodes[i2], nodes[i3], nodes[i4], i1, i2, i3, i4
  end
  i1, i2, i3, i4 = max(1, j - 1), j, j + 1, min(numNodes, j + 2)
  local p0, p1, p2, p3 = nodes[i1], nodes[i2], nodes[i3], nodes[i4]
  if j == 1 and spline.crGhostStart then p0 = spline.crGhostStart end
  if j == numNodes - 1 and spline.crGhostFinish then p3 = spline.crGhostFinish end
  return p0, p1, p2, p3, i1, i2, i3, i4
end

-- Checks if the mouse is over the given spline (insert-node / hover pick).
-- Uses camera ray ↔ centerline closest approach so elevated roads work.
-- Returns: hit, segmentIndex, pointOnSpline.
-- maxDistSq: optional ray↔centerline tolerance (squared). Pass a large value (e.g. math.huge) to get the
-- nearest point unconditionally — used when dragging a handle that sits off the centerline (road edge).
local function isMouseOverSpline(spline, maxDistSq)
  local ray = getCameraMouseRay()
  local rayPos, rayDir = ray.pos, ray.dir
  tmp3:set(rayPos.x + rayDir.x * maxRayDist, rayPos.y + rayDir.y * maxRayDist, rayPos.z + rayDir.z * maxRayDist)

  local tol = maxDistSq or intermediateTolSq

  -- Engineered roads: the rendered centreline follows the clothoid divPoints, which deviate from a Catmull-Rom through
  -- the control nodes -- so hit-testing the Catmull curve (below) misses the road the user actually sees, and insert-node
  -- never triggers. Test the real divPoint polyline instead, then map the hit back to its control-node segment via
  -- discMap (the divPoint index anchoring each node) so the inserted node lands in the right place along the spline.
  local divPoints = spline.geometryMode == 'engineered' and spline.divPoints
  if divPoints and #divPoints >= 2 then
    local discMap, nodes = spline.discMap, spline.nodes
    local bestDistSq, bestLower = tol, nil
    pLast:set(huge, huge, huge)
    for j = 1, #divPoints do
      pThis:set(divPoints[j])
      if pLast.x < 1e20 then
        local distSq = squaredSegSegDist(pThis, pLast, rayPos, tmp3, tmp1, tmp2)
        if distSq < bestDistSq then
          bestDistSq, bestLower = distSq, j - 1 -- lower divPoint index of the hit segment
          tmp0:set(tmp1)
        end
      end
      pLast:set(pThis)
    end
    if not bestLower then return false, nil, nil end
    -- Largest control segment j whose anchor divPoint index (discMap[j]) is <= the hit's divPoint index.
    local numNodes = nodes and #nodes or 0
    local idxLower = max(1, numNodes - 1)
    if discMap and numNodes >= 2 then
      for j = 1, numNodes - 1 do
        if bestLower < (discMap[j + 1] or huge) then idxLower = j; break end
      end
    end
    return true, idxLower, vec3(tmp0)
  end

  local bestDistSq, bestJ = tol, nil
  pLast:set(huge, huge, huge)
  local points = spline.nodes
  local numPoints, isLoop = #points, spline.isLoop
  -- A polyline spline runs dead straight node to node, so each leg's two ends are the whole segment (the curve is exact at
  -- t = 0 and 1): one step instead of walking a curve that isn't there.
  local divs = spline.isPolyline and 1 or defaultMinNumDivisions
  local step = 1.0 / divs
  for j = 1, numPoints - (isLoop and 0 or 1) do
    local i1, i2, i3, i4
    if isLoop then
      i1, i2, i3, i4 = ((j - 2 + numPoints) % numPoints) + 1, ((j - 1) % numPoints) + 1, (j % numPoints) + 1, ((j + 1) % numPoints) + 1
    else
      i1, i2, i3, i4 = max(1, j - 1), j, j + 1, min(numPoints, j + 2)
    end
    local p0, p1, p2, p3 = points[i1], points[i2], points[i3], points[i4]
    for k = 0, divs do
      pThis:set(catmullRomCentripetalFast(p0, p1, p2, p3, k * step, 0.5))
      if pLast.x < 1e20 then
        local distSq = squaredSegSegDist(pThis, pLast, rayPos, tmp3, tmp1, tmp2)
        if distSq < bestDistSq then
          bestDistSq, bestJ = distSq, j
          tmp0:set(tmp1) -- point on the spline
        end
      end
      pLast:set(pThis)
    end
  end
  if bestJ then
    return true, bestJ, vec3(tmp0)
  end
  return false, nil, nil
end

-- Interpolates the given points with Catmull-Rom splines.
local function catmullRomNodesOnly(nodes, gran)
  local granInv = 1.0 / gran
  local pts, ctr, startIdx, numNodes = {}, 1, 0, #nodes
  for j = 1, numNodes - 1 do
    local p0, p1, p2, p3 = nodes[max(1, j - 1)], nodes[j], nodes[j + 1], nodes[min(numNodes, j + 2)]
    local z0, z1, z2, z3 = p0.z, p1.z, p2.z, p3.z
    for k = startIdx, gran do
      local t = k * granInv
      pts[ctr] = pts[ctr] or vec3()
      catmullRomCentripetalFast(p0, p1, p2, p3, t, 0.5, pts[ctr])
      pts[ctr].z = monotonicSteffen(z0, z1, z2, z3, 0, 1, 2, 3, t + 1)
      ctr = ctr + 1
    end
    startIdx = 1
  end
  for i = ctr, #pts do -- Remove excess elements.
    pts[i] = nil
  end
  return pts
end

-- Interpolates the given points with Catmull-Rom splines.
-- [Only works for a single array of nodes.]
local function catmullRomNodesWidthsOnly(nodes, widths, gran, isLoop)
  local granInv = 1.0 / gran
  local pts, wds, ctr, startIdx, numNodes = {}, {}, 1, 0, #nodes
  for j = 1, numNodes - (isLoop and 0 or 1) do
    local i1, i2, i3, i4
    if isLoop then
      i1, i2, i3, i4 = ((j - 2) % numNodes) + 1, ((j - 1) % numNodes) + 1, (j % numNodes) + 1, ((j + 1) % numNodes) + 1
    else
      i1, i2, i3, i4 = max(1, j - 1), j, j + 1, min(numNodes, j + 2)
    end
    local p0, p1, p2, p3 = nodes[i1], nodes[i2], nodes[i3], nodes[i4]
    local z0, z1, z2, z3 = p0.z, p1.z, p2.z, p3.z
    local w0, w1, w2, w3 = widths[i1], widths[i2], widths[i3], widths[i4]
    for k = startIdx, gran do
      local t = k * granInv
      pts[ctr] = pts[ctr] or vec3()
      catmullRomCentripetalFast(p0, p1, p2, p3, t, 0.5, pts[ctr])
      local tPlus1 = t + 1
      pts[ctr].z = monotonicSteffen(z0, z1, z2, z3, 0, 1, 2, 3, tPlus1) -- Use a monotonic spline for Z, to stop overshooting under the surface.
      wds[ctr] = monotonicSteffen(w0, w1, w2, w3, 0, 1, 2, 3, tPlus1) -- Use a monotonic spline for the width interpolation.
      ctr = ctr + 1
    end
    startIdx = 1
  end
  for i = ctr, #pts do  -- Remove excess elements.
    pts[i], wds[i] = nil, nil
  end
  return pts, wds
end

-- Interpolates the given points with Catmull-Rom splines.
-- [Only works for a single array of nodes.]
local function catmullRomNodesWidthsVelVelLimits(spline, gran)
  -- First, remove any duplicate nodes.
  local nodesRaw, widthsRaw, velocitiesRaw, velLimitsRaw, isLoop = spline.nodes, spline.widths, spline.vels, spline.velLimits, spline.isLoop
  local nodes, widths, velocities, velLimits, ctr = { nodesRaw[1] }, { widthsRaw[1] }, { velocitiesRaw[1] }, { velLimitsRaw[1] }, 2
  for i = 2, #nodesRaw do
    local p1, p2 = nodesRaw[i - 1], nodesRaw[i]
    if p1:squaredDistance(p2) > closeTolSq then
      nodes[ctr], widths[ctr], velocities[ctr], velLimits[ctr] = nodesRaw[i], widthsRaw[i], velocitiesRaw[i], velLimitsRaw[i]
      ctr = ctr + 1
    end
  end

  -- Perform spline fitting with Catmull-Rom splines.
  local granInv = 1.0 / gran
  local pts, wds, vels, lims, ctr, startIdx, numNodes = {}, {}, {}, {}, 1, 0, #nodes
  for j = 1, numNodes - (isLoop and 0 or 1) do
    local i1, i2, i3, i4
    if isLoop then
      i1, i2, i3, i4 = ((j - 2) % numNodes) + 1, ((j - 1) % numNodes) + 1, (j % numNodes) + 1, ((j + 1) % numNodes) + 1
    else
      i1, i2, i3, i4 = max(1, j - 1), j, j + 1, min(numNodes, j + 2)
    end
    local p0, p1, p2, p3 = nodes[i1], nodes[i2], nodes[i3], nodes[i4]
    local z0, z1, z2, z3 = p0.z, p1.z, p2.z, p3.z
    local w0, w1, w2, w3 = widths[i1], widths[i2], widths[i3], widths[i4]
    local v0, v1, v2, v3 = velocities[i1], velocities[i2], velocities[i3], velocities[i4]
    local l0, l1, l2, l3 = velLimits[i1], velLimits[i2], velLimits[i3], velLimits[i4]
    for k = startIdx, gran do
      local t = k * granInv
      pts[ctr] = catmullRomCentripetalFast(p0, p1, p2, p3, t, 0.5)
      local tPlus1 = t + 1
      pts[ctr].z = monotonicSteffen(z0, z1, z2, z3, 0, 1, 2, 3, tPlus1) -- Use a monotonic spline for Z, to stop overshooting under the surface.
      wds[ctr] = monotonicSteffen(w0, w1, w2, w3, 0, 1, 2, 3, tPlus1) -- Use a monotonic spline for the width interpolation.
      vels[ctr] = monotonicSteffen(v0, v1, v2, v3, 0, 1, 2, 3, tPlus1) -- Use a monotonic spline for the velocity interpolation.
      lims[ctr] = monotonicSteffen(l0, l1, l2, l3, 0, 1, 2, 3, tPlus1) -- Use a monotonic spline for the velocity limit interpolation.
      ctr = ctr + 1
    end
    startIdx = 1
  end
  return pts, wds, vels, lims
end

-- Compute the local Frenet frame at each division point.
-- Zero-length spans must not normalize (that yields NaN binormals → Inf DecalRoad nodes).
local function computeFrenetFrame(spline)
  local divPoints, tangents, binormals, normals = spline.divPoints, spline.tangents, spline.binormals, spline.normals
  local numDivPoints = #divPoints
  local isLoop = spline.isLoop
  local twoMinusNumDivPoints = 2 - numDivPoints
  for i = 1, numDivPoints do
    local iPrev, iNext
    if isLoop then
      iPrev = ((i - twoMinusNumDivPoints) % numDivPoints) + 1
      iNext = (i % numDivPoints) + 1
    else
      iPrev, iNext = max(1, i - 1), min(numDivPoints, i + 1)
    end
    tangents[i] = tangents[i] or vec3()
    binormals[i] = binormals[i] or vec3()
    normals[i] = normals[i] or vec3()
    if normals[i]:squaredLength() < 1e-10 then
      normals[i]:set(globalUp)
    end

    tangents[i]:setSub2(divPoints[iNext], divPoints[iPrev])
    if tangents[i]:squaredLength() > 1e-10 then
      tangents[i]:normalize()
    elseif i > 1 then
      tangents[i]:set(tangents[i - 1])
    else
      tangents[i]:set(1, 0, 0)
    end

    tmp1:setCross(tangents[i], normals[i])
    if tmp1:squaredLength() < 1e-10 then
      tmp1:setCross(tangents[i], globalUp)
    end
    if tmp1:squaredLength() > 1e-10 then
      tmp1:normalize()
    elseif i > 1 then
      tmp1:set(binormals[i - 1])
    else
      tmp1:set(0, 1, 0)
    end
    binormals[i]:set(tmp1)
    if i > 1 and binormals[i]:dot(binormals[i - 1]) < 0 then
      binormals[i]:setScaled(-1)
    end

    tmp2:setCross(binormals[i], tangents[i])
    if tmp2:squaredLength() > 1e-10 then
      tmp2:normalize()
    else
      tmp2:set(globalUp)
    end
    normals[i]:set(tmp2)
  end
  for i = numDivPoints + 1, #tangents do -- Remove excess elements.
    tangents[i], binormals[i] = nil, nil
  end
end

-- Interpolates the nodes and widths of the given spline with 'standard' Catmull-Rom splines to generate the secondary geometry properties.
-- [Points are raycast to the surface below.]
-- [The secondary geometry data is stored in the given spline object.]
-- [minNumDivIn - minimum number of divisions per segment]
-- [minSpacing - minimum spacing between division points in meters (optional, prevents over-dense points)]
-- [rayRaise - vertical raycast start offset in meters (optional)]
local function catmullRomRaycast(spline, minNumDivIn, minSpacing, rayRaise)
  local minNumDivisionsFinal = minNumDivIn or defaultMinNumDivisions
  rayRaise = rayRaise or spline.rayRaise -- per-spline override: start the conform raycast higher so a chord
  -- that sags below a hilltop between sparse nodes still starts above the terrain (nil => vertRaycast default).
  local divPoints, divWidths, normals, discMap = spline.divPoints, spline.divWidths, spline.normals, spline.discMap
  local nodes, widths, nmls = spline.nodes, spline.widths, spline.nmls
  local numNodes, startIdx, ctr = #nodes, 0, 1
  local isLoop = spline.isLoop
  for j = 1, numNodes - (isLoop and 0 or 1) do
    discMap[j] = max(1, ctr - 1)
    local p0, p1, p2, p3, i1, i2, i3, i4 = crSegmentPoints(spline, j, numNodes, isLoop, nodes)
    local n0, n1, n2, n3 = nmls[i1], nmls[i2], nmls[i3], nmls[i4]
    local w0, w1, w2, w3 = widths[i1], widths[i2], widths[i3], widths[i4]
    tmp0:set(p0.x, p0.y, w0)
    tmp1:set(p1.x, p1.y, w1)
    tmp2:set(p2.x, p2.y, w2)
    tmp3:set(p3.x, p3.y, w3)
    local segmentLength = p1:distance(p2)
    local numDivisions = max(minNumDivisionsFinal, floor(segmentLength / maxDivisionSpacing + 0.5))
    -- If minimum spacing is specified, limit the maximum number of divisions to prevent over-dense points
    if minSpacing and minSpacing > 0 then
      local maxDivisions = max(1, floor(segmentLength / minSpacing))
      numDivisions = min(numDivisions, maxDivisions)
    end
    local step = 1.0 / numDivisions
    for k = startIdx, numDivisions do
      local t = k * step
      divPoints[ctr] = divPoints[ctr] or vec3()
      normals[ctr] = normals[ctr] or vec3()
      catmullRomCentripetalFast(p0, p1, p2, p3, t, 0.5, divPoints[ctr])
      util.vertRaycast(divPoints[ctr], rayRaise, spline.rayPostFloat)
      catmullRomCentripetalFast(n0, n1, n2, n3, t, 0.5, normals[ctr])
      divWidths[ctr] = monotonicSteffen(w0, w1, w2, w3, 0, 1, 2, 3, t + 1)
      ctr = ctr + 1
    end
    startIdx = 1
  end
  if not isLoop then
    discMap[#nodes] = ctr - 1 -- For the loop case, we do not set the last node->divPoint map, since the divPoints extend beyond the last node.
  end
  for i = ctr, #divPoints do -- Remove excess elements.
    divPoints[i], divWidths[i], normals[i] = nil, nil, nil
  end
  computeFrenetFrame(spline)
end

-- Interpolates the nodes and widths of the given spline with 'standard' Catmull-Rom splines to generate the secondary geometry properties.
-- [Points are conformed to the terrain.]
-- [The secondary geometry data is stored in the given spline object.]
-- [minSpacing - minimum spacing between division points in meters (optional, prevents over-dense points)]
-- [rayRaise - vertical raycast start offset in meters when falling back to raycast (optional)]
local function catmullRomConformToTerrain(spline, minNumDivIn, minSpacing, rayRaise)
  local terrain = core_terrain.getTerrain()
  if not terrain then
    return catmullRomRaycast(spline, minNumDivIn, minSpacing, rayRaise) -- If no terrain block, use the raycast version.
  end
  local minNumDivisionsFinal = minNumDivIn or defaultMinNumDivisions
  local divPoints, divWidths, normals, discMap = spline.divPoints, spline.divWidths, spline.normals, spline.discMap
  local nodes, widths, nmls = spline.nodes, spline.widths, spline.nmls
  local numNodes, startIdx, ctr = #nodes, 0, 1
  local isLoop = spline.isLoop
  for j = 1, numNodes - (isLoop and 0 or 1) do
    discMap[j] = max(1, ctr - 1)
    local i1, i2, i3, i4
    if isLoop then
      i1, i2, i3, i4 = ((j - 2) % numNodes) + 1, ((j - 1) % numNodes) + 1, (j % numNodes) + 1, ((j + 1) % numNodes) + 1
    else
      i1, i2, i3, i4 = max(1, j - 1), j, j + 1, min(numNodes, j + 2)
    end
    local p0, p1, p2, p3 = nodes[i1], nodes[i2], nodes[i3], nodes[i4]
    local n0, n1, n2, n3 = nmls[i1], nmls[i2], nmls[i3], nmls[i4]
    local w0, w1, w2, w3 = widths[i1], widths[i2], widths[i3], widths[i4]
    tmp0:set(p0.x, p0.y, w0)
    tmp1:set(p1.x, p1.y, w1)
    tmp2:set(p2.x, p2.y, w2)
    tmp3:set(p3.x, p3.y, w3)
    local segmentLength = p1:distance(p2)
    local numDivisions = max(minNumDivisionsFinal, floor(segmentLength / maxDivisionSpacing + 0.5))
    -- If minimum spacing is specified, limit the maximum number of divisions to prevent over-dense points
    if minSpacing and minSpacing > 0 then
      local maxDivisions = max(1, floor(segmentLength / minSpacing))
      numDivisions = min(numDivisions, maxDivisions)
    end
    local step = 1.0 / numDivisions
    for k = startIdx, numDivisions do
      local t = k * step
      divPoints[ctr] = divPoints[ctr] or vec3()
      normals[ctr] = normals[ctr] or vec3()
      catmullRomCentripetalFast(p0, p1, p2, p3, t, 0.5, divPoints[ctr])
      divPoints[ctr].z = terrain:getHeight(divPoints[ctr])
      catmullRomCentripetalFast(n0, n1, n2, n3, t, 0.5, normals[ctr])
      divWidths[ctr] = monotonicSteffen(w0, w1, w2, w3, 0, 1, 2, 3, t + 1)
      ctr = ctr + 1
    end
    startIdx = 1
  end
  if not isLoop then
    discMap[#nodes] = ctr - 1 -- For the loop case, we do not set the last node->divPoint map, since the divPoints extend beyond the last node.
  end
  for i = ctr, #divPoints do -- Remove excess elements.
    divPoints[i], divWidths[i], normals[i] = nil, nil, nil
  end
  computeFrenetFrame(spline)
end

-- Interpolates the nodes and widths of the given spline with 'standard' Catmull-Rom splines to generate the secondary geometry properties.
-- [The secondary geometry data is stored in the given spline object.]
local function catmullRomFree(spline, minNumDivIn, deckZ, maxSpacingIn)
  local minNumDivisionsFinal = minNumDivIn or defaultMinNumDivisions
  local divPoints, divWidths, normals, discMap = spline.divPoints, spline.divWidths, spline.normals, spline.discMap
  local nodes, widths, nmls = spline.nodes, spline.widths, spline.nmls
  local numNodes, startIdx, ctr = #nodes, 0, 1
  local isLoop = spline.isLoop
  for j = 1, numNodes - (isLoop and 0 or 1) do
    discMap[j] = max(1, ctr - 1)
    local p0, p1, p2, p3, i1, i2, i3, i4 = crSegmentPoints(spline, j, numNodes, isLoop, nodes)
    local n0, n1, n2, n3 = nmls[i1], nmls[i2], nmls[i3], nmls[i4]
    local z0, z1, z2, z3 = p0.z, p1.z, p2.z, p3.z
    local w0, w1, w2, w3 = widths[i1], widths[i2], widths[i3], widths[i4]
    local numDivisions = min(maxDivisionsHardCap, max(minNumDivisionsFinal, floor(p1:distance(p2) / (maxSpacingIn or maxDivisionSpacing) + 0.5)))
    local step = 1.0 / numDivisions
    for k = startIdx, numDivisions do
      local t = k * step
      local tPlus1 = t + 1
      divPoints[ctr] = divPoints[ctr] or vec3()
      normals[ctr] = normals[ctr] or vec3()
      catmullRomCentripetalFast(p0, p1, p2, p3, t, 0.5, divPoints[ctr])
      if not deckZ then divPoints[ctr].z = monotonicSteffen(z0, z1, z2, z3, 0, 1, 2, 3, tPlus1) end
      catmullRomCentripetalFast(n0, n1, n2, n3, t, 0.5, normals[ctr])
      divWidths[ctr] = monotonicSteffen(w0, w1, w2, w3, 0, 1, 2, 3, tPlus1)
      ctr = ctr + 1
    end
    startIdx = 1
  end
  if not isLoop then
    discMap[#nodes] = ctr - 1 -- For the loop case, we do not set the last node->divPoint map, since the divPoints extend beyond the last node.
  end
  for i = ctr, #divPoints do -- Remove excess elements.
    divPoints[i], divWidths[i], normals[i] = nil, nil, nil
  end
  computeFrenetFrame(spline)
end

-- Helper function to calculate curvature at a specific node for banking
local function calculateCurvatureAtNode(nodes, nodeIdx)
  local numNodes = #nodes
  if nodeIdx < 2 or nodeIdx > numNodes - 1 then
    return 0 -- No curvature at endpoints
  end

  local p0, p1, p2 = nodes[nodeIdx - 1], nodes[nodeIdx], nodes[nodeIdx + 1]

  -- The caller banks about this axis.
  tmpTangent:setSub2(p1, p2)
  tmpTangent:normalize()

  -- The turn in plan per metre of the two legs (a grade change is no corner), negative turning left.
  local ax, ay, bx, by = p1.x - p0.x, p1.y - p0.y, p2.x - p1.x, p2.y - p1.y
  local la, lb = sqrt(ax * ax + ay * ay), sqrt(bx * bx + by * by)
  if la < 1e-5 or lb < 1e-5 then return 0 end
  return -2 * atan2(ax * by - ay * bx, ax * bx + ay * by) / (la + lb)
end

-- Interpolates the nodes and widths of the given spline with Catmull-Rom splines, applying auto banking with falloff.
-- [The secondary geometry data is stored in the given spline object.]
local function catmullRomFreeWithBanking(spline, minNumDivIn, bankStrength, maxDegIn, tuningIn, deckZ, maxSpacingIn)
  local minNumDivisionsFinal = minNumDivIn or defaultMinNumDivisions
  local divPoints, divWidths, normals, discMap = spline.divPoints, spline.divWidths, spline.normals, spline.discMap
  local nodes, widths, nmls = spline.nodes, spline.widths, spline.nmls
  local numNodes, startIdx, ctr = #nodes, 0, 1
  local isLoop = spline.isLoop
  -- See catmullRomFree for the Z rule: centripetal XY always; Steffen Z for ground roads, smooth Catmull-Rom Z for
  -- elevated decks (deckZ true) so a bridge eases its descent instead of staying high then dropping off a cliff.
  for j = 1, numNodes - (isLoop and 0 or 1) do
    discMap[j] = max(1, ctr - 1)
    local p0, p1, p2, p3, i1, i2, i3, i4 = crSegmentPoints(spline, j, numNodes, isLoop, nodes)
    local n0, n1, n2, n3 = nmls[i1], nmls[i2], nmls[i3], nmls[i4]
    local z0, z1, z2, z3 = p0.z, p1.z, p2.z, p3.z
    local w0, w1, w2, w3 = widths[i1], widths[i2], widths[i3], widths[i4]
    local numDivisions = min(maxDivisionsHardCap, max(minNumDivisionsFinal, floor(p1:distance(p2) / (maxSpacingIn or maxDivisionSpacing) + 0.5)))
    local step = 1.0 / numDivisions

    for k = startIdx, numDivisions do
      local t = k * step
      local tPlus1 = t + 1
      divPoints[ctr] = divPoints[ctr] or vec3()
      normals[ctr] = normals[ctr] or vec3()

      catmullRomCentripetalFast(p0, p1, p2, p3, t, 0.5, divPoints[ctr])
      if not deckZ then divPoints[ctr].z = monotonicSteffen(z0, z1, z2, z3, 0, 1, 2, 3, tPlus1) end

      -- Interpolate base normals first
      catmullRomCentripetalFast(n0, n1, n2, n3, t, 0.5, normals[ctr])

      -- Apply banking with falloff for nodes 1 and 2 (the main nodes of this segment)
      if bankStrength > 0 then
        -- Calculate banking for node 1 (i2) with falloff based on distance from t=0
        local falloff1 = max(0, 1.0 - abs(t) * (spline.autoBankFalloff or 2.0)) -- Falloff from t=0 to t=1/falloff
        if falloff1 > 0 then
          local curvature1 = calculateCurvatureAtNode(nodes, i2)
          if curvature1 ~= 0 then
            local bankAngle1 = -sign(curvature1) * curvatureToBankAngle(abs(curvature1), bankStrength, maxDegIn, tuningIn) * falloff1
            local rotated1 = rotateVecAroundAxis(normals[ctr], tmpTangent, bankAngle1)
            normals[ctr]:setLerp(normals[ctr], rotated1, falloff1 * 0.5)
          end
        end

        -- Calculate banking for node 2 (i3) with falloff based on distance from t=1
        local falloff2 = max(0, 1.0 - abs(t - 1) * (spline.autoBankFalloff or 2.0)) -- Falloff from t=0.5 to t=1
        if falloff2 > 0 then
          local curvature2 = calculateCurvatureAtNode(nodes, i3)
          if curvature2 ~= 0 then
            local bankAngle2 = -sign(curvature2) * curvatureToBankAngle(abs(curvature2), bankStrength, maxDegIn, tuningIn) * falloff2
            local rotated2 = rotateVecAroundAxis(normals[ctr], tmpTangent, bankAngle2)
            normals[ctr]:setLerp(normals[ctr], rotated2, falloff2 * 0.5)
          end
        end
      end

      divWidths[ctr] = monotonicSteffen(w0, w1, w2, w3, 0, 1, 2, 3, tPlus1)
      ctr = ctr + 1
    end
    startIdx = 1
  end

  if not isLoop then
    discMap[#nodes] = ctr - 1 -- For the loop case, we do not set the last node->divPoint map, since the divPoints extend beyond the last node.
  end

  for i = ctr, #divPoints do -- Remove excess elements.
    divPoints[i], divWidths[i], normals[i] = nil, nil, nil
  end

  computeFrenetFrame(spline)
end

-- Computes the graph path from the given nodes and populates the spline's geometry data.
local function computeGraphPathFromNodes(spline)
  local nodes, path = spline.graphNodes, spline.graphPath
  if #nodes < 2 then
    return -- Not enough nodes to compute a path.
  end

  -- Initialize the spline's geometry arrays if they don't exist.
  if not spline.divPoints then
    spline.divPoints = {}
  end
  if not spline.divWidths then
    spline.divWidths = {}
  end
  if not spline.normals then
    spline.normals = {}
  end

  -- Compute the path and populate geometry.
  local ctr, startIdx = 1, 1
  for i = 1, #nodes - 1 do
    local section = map.getPath(nodes[i], nodes[i + 1])
    for j = startIdx, #section do
      path[ctr] = section[j]

      -- Get the actual position from the navgraph
      local nodePos = map.getMap().nodes[section[j]].pos

      -- Populate the spline's geometry with the navgraph path points
      spline.divPoints[ctr] = spline.divPoints[ctr] or vec3()
      spline.divPoints[ctr]:set(nodePos)

      -- Set default width and normal for intermediate points
      spline.divWidths[ctr] = 5.0 -- Default width
      spline.normals[ctr] = spline.normals[ctr] or vec3(0, 0, 1)
      spline.normals[ctr]:set(map.surfaceNormal(nodePos, 1.0))

      ctr = ctr + 1
    end
    startIdx = 2 -- Set the start index to 2 for all [2, .., n] iterations, so as to avoid duplicates in subsequent iterations.
  end

  -- Remove excess elements from all arrays.
  for i = ctr, #path do
    path[i] = nil
  end
  for i = ctr, #spline.divPoints do
    spline.divPoints[i], spline.divWidths[i], spline.normals[i] = nil, nil, nil
  end

  -- Compute the Frenet frame for proper spline surface rendering.
  if #spline.divPoints > 1 then
    computeFrenetFrame(spline)
  end
end

-- Perpendicular distance of point (px,py) from segment (ax,ay)->(bx,by) in XY. Degenerate segment -> distance to A.
local function perpDistPointSeg2D(ax, ay, bx, by, px, py)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  if l2 < 1e-12 then
    local ex, ey = px - ax, py - ay
    return sqrt(ex * ex + ey * ey)
  end
  local t = ((px - ax) * dx + (py - ay) * dy) / l2
  local ex, ey = px - (ax + dx * t), py - (ay + dy * t)
  return sqrt(ex * ex + ey * ey)
end

-- 2D scalar primitives on plain components (no vec3 / table churn - for hot geometry paths).
local function cross2(ax, ay, bx, by) return ax * by - ay * bx end

local function dot2(ax, ay, bx, by) return ax * bx + ay * by end

local function normalize2(x, y)
  local l = sqrt(x * x + y * y)
  if l < 1e-12 then return 0, 0 end
  return x / l, y / l
end

-- Which way a post, pier or newel STANDING ON A CORNER faces, given the direction in and the direction out.
local function cornerAxis(ix, iy, ox, oy, period)
  local ia = atan2(iy, ix)
  local turn = atan2(oy, ox) - ia
  turn = turn - (2 * pi) * floor(turn / (2 * pi) + 0.5) -- the actual turn, not one that went the long way round
  period = period or (pi * 0.5)
  -- Ties go to the SMALLER turn rather than always downwards. A chamfer turns exactly half a period, and rounding that the one way
  -- folded a left-hand 45 to -45 where a right-hand 45 stayed put: the two leaned the same way instead of mirroring, which is what
  -- made a run of them read as though the posts had been dropped in at random.
  local k = turn / period
  turn = turn - period * ((k >= 0) and ceil(k - 0.5) or floor(k + 0.5))
  local th = ia + turn * 0.5
  return cos(th), sin(th)
end

-- Intersect two INFINITE lines P+s*D and Q+s*E; returns ix,iy or nil when parallel (thin point-returning wrapper on
-- lineDirsHitT2D, which returns the parameter along the first line).
local function lineIntersect2D(px, py, dx, dy, qx, qy, ex, ey, eps)
  local t = lineDirsHitT2D(px, py, dx, dy, qx, qy, ex, ey, eps)
  if not t then return nil end
  return px + dx * t, py + dy * t
end

-- Intersect two RAYS (forward only) P+s*D and Q+u*E; returns ix,iy or nil (parallel, or the hit lies behind either ray).
local function rayIntersect2D(px, py, dx, dy, qx, qy, ex, ey, eps)
  eps = eps or 1e-9
  local den = cross2(dx, dy, ex, ey)
  if den < eps and den > -eps then return nil end
  local sx, sy = qx - px, qy - py
  local s = cross2(sx, sy, ex, ey) / den
  local u = cross2(sx, sy, dx, dy) / den
  if s < -eps or u < -eps then return nil end
  return px + dx * s, py + dy * s
end


-- Public interface.
M.cross2 =                                              cross2
M.dot2 =                                                dot2
M.normalize2 =                                          normalize2
M.cornerAxis =                                          cornerAxis
M.lineIntersect2D =                                     lineIntersect2D
M.rayIntersect2D =                                      rayIntersect2D
M.perpDistPointSeg2D =                                  perpDistPointSeg2D
M.distSqPointSeg2D =                                    distSqPointSeg2D
M.segCrossParam2D =                                     segCrossParam2D

M.getPreRotQuats =                                      getPreRotQuats

M.getBarScale =                                         getBarScale

M.squaredSegSegDist =                                   squaredSegSegDist
M.squaredDistance2D =                                   squaredDistance2D
M.closestPointOnPolyline =                              closestPointOnPolyline
M.ribbonOverlapEnd2D =                                  ribbonOverlapEnd2D
M.closestPointOnPolyline2D =                            closestPointOnPolyline2D
M.smoothNodesHeightSteffen =                            smoothNodesHeightSteffen

M.isMouseOverNode =                                     isMouseOverNode
M.isMouseOverSpline =                                   isMouseOverSpline
M.isMouseOverPolyline =                                 isMouseOverPolyline
M.isMouseOverBar =                                      isMouseOverBar
M.isMouseOverGraphNode =                                isMouseOverGraphNode

M.getAABB =                                             getAABB
M.polygonOBB =                                          polygonOBB
M.computeSplinePolygon =                                computeSplinePolygon
M.isPointInTriangle =                                   isPointInTriangle
M.getTerrainNormal =                                    getTerrainNormal
M.getTerrainNormalInPlace =                             getTerrainNormalInPlace
M.rotateVecAroundZ =                                    rotateVecAroundZ
M.rotateVecAroundAxis =                                 rotateVecAroundAxis
M.rotateVecAroundAxisInlined =                          rotateVecAroundAxisInlined
M.computeTurningRadius =                                computeTurningRadius

M.isLineSegIntersect =                                  isLineSegIntersect
M.intersection2LineSegs =                               intersection2LineSegs
M.pointsSame2D =                                        pointsSame2D
M.pointsCompare2D =                                     pointsCompare2D
M.pointAboveOrOnLine2D =                                pointAboveOrOnLine2D
M.pointsCollinear2D =                                   pointsCollinear2D
M.pointBetween2D =                                      pointBetween2D
M.linesIntersect2D =                                    linesIntersect2D
M.lineDirsHitT2D =                                      lineDirsHitT2D
M.sampleCubicBezier2D =                                 sampleCubicBezier2D
M.reshapeLeadInBezier2D =                               reshapeLeadInBezier2D
M.insetPathAlongNormal2D =                              insetPathAlongNormal2D
M.offsetPathMiter2D =                                   offsetPathMiter2D
M.offsetPathFromCenter2D =                              offsetPathFromCenter2D
M.multiPolygonCentroidXY =                              multiPolygonCentroidXY
M.polylineCumLength3D =                                 polylineCumLength3D
M.polylineCumLength2D =                                 polylineCumLength2D
M.densifyByMaxSpacing =                                 densifyByMaxSpacing
M.smoothClosedPolygonChaikin =                          smoothClosedPolygonChaikin
M.insetClosedRing2D =                                   insetClosedRing2D
M.outsetClosedRing2D =                                  outsetClosedRing2D
M.outsetRingSides2D =                                   outsetRingSides2D
M.pointInRing2D =                                       pointInRing2D
M.clipRingRect2D =                                      clipRingRect2D
M.pointInTri2D =                                        pointInTri2D
M.triangulatePolygon2D =                                triangulatePolygon2D
M.ringSignedArea2 =                                     ringSignedArea2
M.bridgeHoles2D =                                       bridgeHoles2D
M.triangulateWithHoles2D =                              triangulateWithHoles2D
M.sigMoved =                                            sigMoved
M.simplifyRDP =                                         simplifyRDP
M.chordify =                                            chordify
M.weldShortSegments =                                   weldShortSegments
M.resampleUniformNodesWidths =                          resampleUniformNodesWidths
M.splitPolylineByBlocked =                              splitPolylineByBlocked
M.polylineZAtArcFromTip =                               polylineZAtArcFromTip
M.tipOutwardXY =                                        tipOutwardXY

M.angleBetweenVecsNorm =                                angleBetweenVecsNorm
M.angleBetweenVecs =                                    angleBetweenVecs
M.signedAngleBetweenVecs =                              signedAngleBetweenVecs
M.signedAngleAroundAxis =                               signedAngleAroundAxis

M.quadUV =                                              quadUV
M.intersectsUpQuadBarycentric =                         intersectsUpQuadBarycentric
M.pointInQuadBarycentric =                              pointInQuadBarycentric
M.computeSourcesAABB =                                  computeSourcesAABB
M.getAllQuadrilaterals =                                getAllQuadrilaterals
M.populateTreeQuads =                                   populateTreeQuads

M.splitSplineGeometry =                                 splitSplineGeometry
M.splitLoopSplineGeometry =                             splitLoopSplineGeometry
M.joinSplineGeometry =                                  joinSplineGeometry
M.flipSplineDirection =                                 flipSplineDirection

M.closestRibbonSegPointToPoint =                        closestRibbonSegPointToPoint
M.getNodeSpansInsidePolygon =                           getNodeSpansInsidePolygon

M.projectPointToSpline =                                projectPointToSpline
M.sampleSpline =                                        sampleSpline
M.sampleSplineEvenFit =                                 sampleSplineEvenFit
M.sampleSplineAdaptive =                                sampleSplineAdaptive
M.ribbonUpFromAlong =                                   ribbonUpFromAlong
M.ribbonIntervalFrame =                                 ribbonIntervalFrame
M.translateSpline =                                     translateSpline

M.computeRandomJitterQuat_ZOnly =                       computeRandomJitterQuat_ZOnly
M.computeRandomJitterQuat =                             computeRandomJitterQuat
M.computeRandomJitterQuatFromFreedomAxes =              computeRandomJitterQuatFromFreedomAxes

M.updateRibPointsFree =                                 updateRibPointsFree
M.updateRibPointsRaycast =                              updateRibPointsRaycast
M.updateBarPoints =                                     updateBarPoints
M.updateBarPointsGraph =                                updateBarPointsGraph

M.computeSDF =                                          computeSDF
M.getScanlineSpans =                                    getScanlineSpans

M.catmullRomCentripetalFast =                           catmullRomCentripetalFast
M.catmullRomNodesOnly =                                 catmullRomNodesOnly
M.catmullRomNodesWidthsOnly =                           catmullRomNodesWidthsOnly
M.catmullRomNodesWidthsVelVelLimits =                   catmullRomNodesWidthsVelVelLimits
M.catmullRomRaycast =                                   catmullRomRaycast
M.catmullRomConformToTerrain =                          catmullRomConformToTerrain
M.catmullRomFree =                                      catmullRomFree
M.catmullRomFreeWithBanking =                           catmullRomFreeWithBanking
M.computeFrenetFrame =                                  computeFrenetFrame
M.curvatureToBankAngle =                                curvatureToBankAngle
M.applyBankFraction =                                   applyBankFraction

M.computeGraphPathFromNodes =                           computeGraphPathFromNodes

return M