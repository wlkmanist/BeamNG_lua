-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Module constants.
local intersectionTol = 1e-3                                                                        -- A tolerance used when determining if line segments intersect circles.
local splineSmoothingVal = 0.5                                                                      -- The smoothing value used when fitting splines to polylines, in [0, 1].
local duplicateNodeTol = 1e-4                                                                       -- A tolerance used when checking if two nodes are sufficiently distant.
local tolUG = 1.0                                                                                   -- The tolerance used for determining if a road is underground, or not.
local minTunnelLen = 5                                                                              -- The minimum number of div points which can comprise a tunnel length.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}


-- External modules used.
local profileMgr = require('editor/tech/roadArchitect/profiles')                                    -- Manages the profiles structure.
local tMesh = require('editor/tech/roadArchitect/tunnelMesh')                                       -- Manages the road tunnel meshes.
local util = require('editor/tech/roadArchitect/utilities')                                         -- The Road Architect utilities module.

-- Private constants.
local im = ui_imgui
local min, max, abs, floor, ceil = math.min, math.max, math.abs, math.floor, math.ceil
local sin, cos, acos, atan2, pi, sqrt, rad = math.sin, math.cos, math.acos, math.atan2, math.pi, math.sqrt, math.rad
local twoPi, deg2Rad, rad2Deg = pi * 2.0, pi / 180.0, 180.0 / pi
local tmp1, tmp2, tmp3= vec3(0, 0), vec3(0, 0), vec3(0, 0)
local tgt_2D, pLast, tmpLat = vec3(0, 0), vec3(0, 0), vec3(0, 0)
local pStart_2D, pMid_2D, pEnd_2D = vec3(0, 0), vec3(0, 0), vec3(0, 0)
local vertical = vec3(0, 0, 1)
local oneThird, twoThirds = 0.3333333333333333333333333333, 0.666666666666666666666666666667
local qVals = { 0.0, 0.00390625, 0.03125, 0.125, 0.25, 0.5, 0.75, 0.875, 0.9375, 0.96875, 0.984375, 1.0 }
local numQVals = #qVals
local splSm = splineSmoothingVal * 2


-- Computes the (small) angle between two unit vectors, in radians.
local function angleBetweenVecsNorm(a, b) return acos(a:dot(b)) end

-- Computes the (small) angle between two vectors of arbitrary length, in radians.
local function angleBetweenVecs(a, b) return angleBetweenVecsNorm(a:normalized(), b:normalized()) end

-- Find the interpolation parameter in [0, 1] at which p lies on line segment a->b.
local function getInterpP(p, a, b) return p:distance(a) / b:distance(a) end

-- Linearly interpolates between two sets of lane width values and (left and right) relative height offset values.
local function lerpWAndH(w1, w2, hL1, hL2, hR1, hR2, q)
  local w_q, hL_q, hR_q = {}, {}, {}
  for k, _ in pairs(w1) do
    local w1Key, hL1Key, hR1Key = w1[k][0], hL1[k][0], hR1[k][0]
    w_q[k], hL_q[k], hR_q[k] = im.FloatPtr(w1Key + q * (w2[k][0] - w1Key)), im.FloatPtr(hL1Key + q * (hL2[k][0] - hL1Key)), im.FloatPtr(hR1Key + q * (hR2[k][0] - hR1Key))
  end
  return w_q, hL_q, hR_q
end

-- Attemps to fit a circle (2D) to three given points.
local function circle2DFrom3Points(p1, p2, p3)
  local p1x, p1y, p2x, p2y, p3x, p3y = p1.x, p1.y, p2.x, p2.y, p3.x, p3.y
  local dot22 = p2x * p2x + p2y * p2y
  local bc = (p1x * p1x + p1y * p1y - dot22) * 0.5
  local cd = (dot22 - p3x * p3x - p3y * p3y) * 0.5
  local det = (p1x - p2x) * (p2y - p3y) - (p2x - p3x) * (p1y - p2y)
  if abs(det) < 1e-12 then
    return nil, nil
  end
  local detInv = 1.0 / det
  local cx = (bc * (p2y - p3y) - cd * (p1y - p2y)) * detInv
  local cy = ((p1x - p2x) * cd - (p2x - p3x) * bc) * detInv
  return vec3(cx, cy)
end

-- Computes the 2D incircle of a triangle (from the three given triangle vertices v0-v1-v2).
-- Returns the center and radius of the incircle.
local function computeIncircle2D(v0, v1, v2)
  local a, b, c = v2:distance(v1), v2:distance(v0), v1:distance(v0)
  local center = vec3((a * v0.x + b * v1.x + c * v2.x), (a * v0.y + b * v1.y + c * v2.y), 0.0) / (a + b + c)
  return center, center:distanceToLineSegment(v0, v1)
end

-- Finds the intersection between line segment (a->b) and circle (c, r).
-- This function either returns the point of intersection, or nil if there is no intersection.
local function intLineSegAndCircle(a, b, c, r)
  local rayDir = b - a
  rayDir:normalize()
  local q1, q2 = intersectsRay_Sphere(a, rayDir, c, r)
  local isct1, isct2 = a + q1 * rayDir, a + q2 * rayDir
  if isct1:squaredDistanceToLineSegment(a, b) < intersectionTol then
    return isct1
  elseif isct2:squaredDistanceToLineSegment(a, b) < intersectionTol then
    return isct2
  end
  return nil
end

-- Rotates vector v around unit axis k, by angle theta (in radians).
-- [This function uses the standard Rodrigues formula].
local function rotateVecAroundAxis(v, k, theta)
  local c = cos(theta)
  return v * c + k:cross(v) * sin(theta) + k * k:dot(v) * (1.0 - c)
end

-- Removes all adjacent duplicates (repeated points) from a given polyline.
-- [Also removes duplicates in the corresponding normals, rots, widths and heights from the given collections].
local function removeDuplicates(poly, normals, rots, offs, widths, heightsL, heightsR)
  local numDiscPoints, ctr = #poly, 2
  local pDiscPost, nDiscPost, rDiscPost, oDiscPost, wDiscPost = { poly[1] }, { normals[1] }, { rots[1] }, { offs[1]}, { widths[1] }
  local hLDiscPost, hRDiscPost = { heightsL[1] }, { heightsR[1] }
  for i = 2, numDiscPoints do
    if poly[i]:squaredDistance(poly[i - 1]) > duplicateNodeTol then
      pDiscPost[ctr], nDiscPost[ctr], rDiscPost[ctr], oDiscPost[ctr] = poly[i], normals[i], rots[i], offs[i]
      wDiscPost[ctr], hLDiscPost[ctr], hRDiscPost[ctr] = widths[i], heightsL[i], heightsR[i]
      ctr = ctr + 1
    end
  end
  return pDiscPost, nDiscPost, rDiscPost, oDiscPost, wDiscPost, hLDiscPost, hRDiscPost
end

-- Computes unit normal vectors for each point in a given polyline, based on the selected lateral angle at each node.
local function getUnitNormals(road)
  local poly = road.nodes
  local normals, numNodes = {}, #poly
  for i = 1, numNodes do
    local tgt = poly[min(numNodes, i + 1)].p - poly[max(1, i - 1)].p                                -- Compute the sparse tangent vector (the axis of rotation for this node).
    tgt:normalize()
    normals[i] = rotateVecAroundAxis(vertical, tgt, poly[i].rot[0] * deg2Rad)                       -- Rotate the vertical around the axis of rotation by the selected angle.
  end
  return normals
end

-- Identifies all the tunnel sections within the given road.
local function identifyTunnelSections(rData, extraS, extraE)

  -- Determine the left and right lateral edge indices.
  local rD1, lIdx, rIdx = rData[1], nil, nil
  for i = -20, 20 do
    if rD1[i] then
      lIdx = i
      break
    end
  end
  for i = 20, -20, -1 do
    if rD1[i] then
      rIdx = i
      break
    end
  end

  -- Iterate over the road longitudinally, and identify all the individual tunnelled sections.
  local sections, sCtr, rDataSize, isInside, sS = {}, 1, #rData, false, nil
  for i = 1, rDataSize do
    local rD = rData[i]
    local rDLeft = rD[lIdx]
    local rLeft, rRight = rDLeft[4], rD[rIdx][3]                                                    -- Test both the left-most and right-most lateral road points.
    local zLeft = core_terrain.getTerrainHeight(rLeft)
    local zRight = core_terrain.getTerrainHeight(rRight)
    if zLeft > rLeft.z + tolUG and zRight > rRight.z + tolUG then
      if not isInside then
        sS, isInside = i, true
      end
    else
      if isInside then
        if i - 1 > sS + minTunnelLen then                                                           -- Only include sections which span a sufficient number of div points.
          sections[sCtr] = { s = max(1, sS - extraS), e = min(rDataSize, i + extraE) }
          sCtr = sCtr + 1
        end
      end
      isInside = false
    end
  end
  if isInside then
    if rDataSize > sS + minTunnelLen then                                                           -- Only include sections which span a sufficient number of div points.
      sections[sCtr] = { s = max(1, sS - extraS), e = rDataSize }
      sCtr = sCtr + 1
    end
  end
  return sections
end

-- Fits a spline using the given four points to define the start/end tangents.
-- [Catmull-Rom is fitted through X and Y, monotonic Steffen preconditioning is applied for Z].
-- [The splines return an array in the 'node' format, with metadata included].
local function fitSpline(p1, p2, p3, p4, w1, w2, hL1, hL2, hR1, hR2, rot1, rot2, off1, off2)
  local nodes = {}
  local p1z, p2z, p3z, p4z, p2p3 = p1.z, p2.z, p3.z, p4.z, p3 - p2
  local d1, d2, d3 = max(1e-30, p1:distance(p2)), p2:distance(p3), max(1e-30, p3:distance(p4))
  local m1, m2, sd2 = (p2 - p1) / d1 + (p1 - p3) / (d1 + d2), (p2 - p4) / (d2 + d3) + (p4 - p3) / d3, splSm * d2
  local delta0, delta1, delta2 = p2z - p1z, p3z - p2z, p4z - p3z
  local signDelta1, absDelta1 = sign2(delta1), abs(delta1)
  local n1 = (sign2(delta0) + signDelta1) * min(abs(delta0), absDelta1, 0.5 * abs((delta0 + delta1) * 0.5))
  local n2 = (signDelta1 + sign2(delta2)) * min(absDelta1, abs(delta2), 0.5 * abs((delta1 + delta2) * 0.5))
  local n1PlusN2 = n1 + n2
  for j = 1, numQVals do
    local q = qVals[j]
    local tt, t_1 = q * q, q - 1
    local t_1sq = t_1 * t_1
    local pos = q * t_1sq * sd2 * m1 + tt * t_1 * sd2 * m2 + t_1sq * (2.0 * q + 1) * p2 - tt * (2.0 * q - 3.0) * p3 + splSm * t_1 * (q * t_1 + tt) * p2p3
    pos.z = p2z + q * (n1 + q * (delta1 - n1 + (q - 1.0) * (n1PlusN2 - 2.0 * delta1)))
    local wd, hL, hR = lerpWAndH(w1, w2, hL1, hL2, hR1, hR2, q)
    nodes[j] = {
      p = pos,
      isLocked = false,
      rot = im.FloatPtr(lerp(rot1, rot2, q)),
      height = im.FloatPtr(pos.z),
      widths = wd, heightsL = hL, heightsR = hR,
      incircleRad = im.FloatPtr(1.0),
      offset = lerp(off1, off2, q) }
  end
  return nodes
end

-- Fits a spline through a standard (user) road.
-- [Catmull-Rom is fitted through X and Y, monotonic Steffen preconditioning is applied for Z].
local function fitSplineStandardRoad(road)

  -- Compute the normals from the given polyline (the reference nodes).
  local poly = road.nodes
  local normals = getUnitNormals(road)

  -- Starting line segment [evaluated across [0, 1], inclusive].
  local pDisc, nDisc, rDisc, oDisc, wDisc, hLDisc, hRDisc, ctr = {}, {}, {}, {}, {}, {}, {}, 1
  pLast:set(1e99, 1e99, 1e99)
  local targetLonResInv, polyLen = 1.0 / road.targetLonRes[0], #poly
  local pL, pR, norm1, norm2 = poly[1], poly[2], normals[1], normals[2]
  local rot1, rot2, off1, off2 = pL.rot[0], pR.rot[0], pL.offset, pR.offset
  local w1, w2, hL1, hL2, hR1, hR2 = pL.widths, pR.widths, pL.heightsL, pR.heightsL, pL.heightsR, pR.heightsR
  local i1, i2, i3, i4 = poly[1].p, pL.p, pR.p, poly[min(polyLen, 3)].p
  local i1z, i2z, i3z, i4z, i2i3 = i1.z, i2.z, i3.z, i4.z, i3 - i2
  local delta0, delta1, delta2 = i2z - i1z, i3z - i2z, i4z - i3z
  local signDelta1, absDelta1 = sign2(delta1), abs(delta1)
  local n1 = (sign2(delta0) + signDelta1) * min(abs(delta0), absDelta1, 0.5 * abs((delta0 + delta1) * 0.5))
  local n2 = (signDelta1 + sign2(delta2)) * min(absDelta1, abs(delta2), 0.5 * abs((delta1 + delta2) * 0.5))
  local n1PlusN2 = n1 + n2
  local dd23 = i2:distance(i3)
  local d1, d2, d3 = max(1e-30, sqrt(i1:distance(i2))), sqrt(dd23), max(1e-30, sqrt(i3:distance(i4)))
  local m1, m2, sd2 = (i2 - i1) / d1 + (i1 - i3) / (d1 + d2), (i2 - i4) / (d2 + d3) + (i4 - i3) / d3, splSm * d2
  local splineGran = ceil(dd23 * targetLonResInv)
  local splineGranInv = 1.0 / splineGran
  for j = 0, splineGran do                                                                          -- Include start point, since it is the first line segment.
    local q = j * splineGranInv
    local tt, t_1 = q * q, q - 1
    local t_1sq = t_1 * t_1
    local p = q * t_1sq * sd2 * m1 + tt * t_1 * sd2 * m2 + t_1sq * (2.0 * q + 1) * i2 - tt * (2.0 * q - 3.0) * i3 + splSm * t_1 * (q * t_1 + tt) * i2i3
    p.z = i2z + q * (n1 + q * (delta1 - n1 + (q - 1.0) * (n1PlusN2 - 2.0 * delta1)))
    pDisc[ctr] = p
    nDisc[ctr], rDisc[ctr], oDisc[ctr] = lerp(norm1, norm2, q), lerp(rot1, rot2, q), lerp(off1, off2, q)
    wDisc[ctr], hLDisc[ctr], hRDisc[ctr] = lerpWAndH(w1, w2, hL1, hL2, hR1, hR2, q)
    ctr, pLast = ctr + 1, p
  end

  -- All the remaining line segments [evaluated across (0, 1], limited].
  for i = 3, polyLen do
    local iMinus1 = i - 1
    pL, pR, norm1, norm2 = poly[iMinus1], poly[i], normals[iMinus1], normals[i]
    local rot1, rot2, off1, off2 = pL.rot[0], pR.rot[0], pL.offset, pR.offset
    w1, w2, hL1, hL2, hR1, hR2 = pL.widths, pR.widths, pL.heightsL, pR.heightsL, pL.heightsR, pR.heightsR
    i1, i2, i3, i4 = poly[i - 2].p, pL.p, pR.p, poly[min(polyLen, i + 1)].p
    i1z, i2z, i3z, i4z, i2i3 = i1.z, i2.z, i3.z, i4.z, i3 - i2
    delta0, delta1, delta2 = i2z - i1z, i3z - i2z, i4z - i3z
    signDelta1, absDelta1 = sign2(delta1), abs(delta1)
    n1 = (sign2(delta0) + signDelta1) * min(abs(delta0), absDelta1, 0.5 * abs((delta0 + delta1) * 0.5))
    n2 = (signDelta1 + sign2(delta2)) * min(absDelta1, abs(delta2), 0.5 * abs((delta1 + delta2) * 0.5))
    n1PlusN2 = n1 + n2
    dd23 = i2:distance(i3)
    d1, d2, d3 = max(1e-30, sqrt(i1:distance(i2))), sqrt(dd23), max(1e-30, sqrt(i3:distance(i4)))
    m1, m2, sd2 = (i2 - i1) / d1 + (i1 - i3) / (d1 + d2), (i2 - i4) / (d2 + d3) + (i4 - i3) / d3, splSm * d2
    splineGran = ceil(dd23 * targetLonResInv)
    splineGranInv = 1.0 / splineGran
    for j = 1, splineGran do                                                                      -- Do not include start point here (to avoid duplicate disc. points).
      local q = j * splineGranInv
      local tt, t_1 = q * q, q - 1
      local t_1sq= t_1 * t_1
      local p = q * t_1sq * sd2 * m1 + tt * t_1 * sd2 * m2 + t_1sq * (2.0 * q + 1) * i2 - tt * (2.0 * q - 3.0) * i3 + splSm * t_1 * (q * t_1 + tt) * i2i3
      p.z = i2z + q * (n1 + q * (delta1 - n1 + (q - 1.0) * (n1PlusN2 - 2.0 * delta1)))
      pDisc[ctr] = p
      nDisc[ctr], rDisc[ctr], oDisc[ctr] = lerp(norm1, norm2, q), lerp(rot1, rot2, q), lerp(off1, off2, q)
      wDisc[ctr], hLDisc[ctr], hRDisc[ctr] = lerpWAndH(w1, w2, hL1, hL2, hR1, hR2, q)
      ctr, pLast = ctr + 1, p
    end
  end

  return pDisc, nDisc, rDisc, oDisc, wDisc, hLDisc, hRDisc
end

-- Fits a spline through a link road.
-- [Catmull-Rom is fitted through X and Y, monotonic Steffen preconditioning is applied for Z].
local function fitSplineLinkRoad(r, roads, map)

  -- First, fit a Chordal CR spline between the two tributory roads, to get appropriate reference nodes.
  local r1, r2 = roads[map[r.startR]], roads[map[r.endR]]
  local r1I1, r1I2, r2I1, r2I2 = r.idxL1, r.idxL2, r.idxR1, r.idxR2
  local rData1, rData2 = r1.renderData, r2.renderData
  local rData1Len, rData2Len = #rData1, #rData2
  local secondLast1, secondLast2 = rData1Len - 1, rData2Len - 1
  local i1 = r.idxL0a_1 + r.idxL0a_2 * 2 + r.idxL0a_l * rData1Len + r.idxL0a_l2 * secondLast1       -- Compute the appropriate indices from the stored contributions.
  local i2 = r.idxL0b_1 + r.idxL0b_2 * 2 + r.idxL0b_l * rData1Len + r.idxL0b_l2 * secondLast1       -- [The masking here avoids branching].
  local i3 = r.idxR0a_1 + r.idxR0a_2 * 2 + r.idxR0a_l * rData2Len + r.idxR0a_l2 * secondLast2
  local i4 = r.idxR0b_1 + r.idxR0b_2 * 2 + r.idxR0b_l * rData2Len + r.idxR0b_l2 * secondLast2
  local f2, f3 = rData1[i2][r1I1], rData2[i3][r2I1]
  local t1, t2, t3, t4 = rData1[i1][r1I1][r1I2], f2[r1I2], f3[r2I2], rData2[i4][r2I1][r2I2]
  local poly = fitSpline(
    t1, t2, t3, t4,
    r.w1, r.w2, r.hL1, r.hL2, r.hR1, r.hR2,
    f2[12] * rad2Deg * r.rot1, f3[12] * rad2Deg * r.rot2,
    f2[13] * r.rot1, f3[13] * r.rot2)
  r.nodes = poly

  -- Compute the corresponding normals for each node in the reference polyline.
  local normals = getUnitNormals(r)

  -- Fit through the first line segment of the reference polyline.
  local pDisc, nDisc, rDisc, oDisc, wDisc, hLDisc, hRDisc, ctr = {}, {}, {}, {}, {}, {}, {}, 1
  pLast:set(1e99, 1e99, 1e99)
  local targetLonResInv, polyLen = 1.0 / r.targetLonRes[0], #poly
  local pL, pR, norm1, norm2 = poly[1], poly[2], normals[1], normals[2]
  local rot1, rot2, off1, off2 = pL.rot[0], pR.rot[0], pL.offset, pR.offset
  local w1, w2, hL1, hL2, hR1, hR2 = pL.widths, pR.widths, pL.heightsL, pR.heightsL, pL.heightsR, pR.heightsR
  local i1, i2, i3, i4 = t1, t2, pR.p, poly[min(polyLen, 3)].p
  local i1z, i2z, i3z, i4z, i2i3 = i1.z, i2.z, i3.z, i4.z, i3 - i2
  local delta0, delta1, delta2 = i2z - i1z, i3z - i2z, i4z - i3z
  local signDelta1, absDelta1 = sign2(delta1), abs(delta1)
  local n1 = (sign2(delta0) + signDelta1) * min(abs(delta0), absDelta1, 0.5 * abs((delta0 + delta1) * 0.5))
  local n2 = (signDelta1 + sign2(delta2)) * min(absDelta1, abs(delta2), 0.5 * abs((delta1 + delta2) * 0.5))
  local n1PlusN2 = n1 + n2
  local d23 = i2:distance(i3)
  local d1, d2, d3 = max(1e-30, sqrt(i1:distance(i2))), sqrt(d23), max(1e-30, sqrt(i3:distance(i4)))
  local m1, m2, sd2 = (i2 - i1) / d1 + (i1 - i3) / (d1 + d2), (i2 - i4) / (d2 + d3) + (i4 - i3) / d3, splSm * d2
  r.nodes[1].p = i2
  local splineGran = ceil(d23 * targetLonResInv)
  local splineGranInv = 1.0 / splineGran
  for j = 0, splineGran do
    local q = j * splineGranInv
    local tt, t_1 = q * q, q - 1
    local t_1sq = t_1 * t_1
    local p = q * t_1sq * sd2 * m1 + tt * t_1 * sd2 * m2 + t_1sq * (2.0 * q + 1) * i2 - tt * (2.0 * q - 3.0) * i3 + splSm * t_1 * (q * t_1 + tt) * i2i3
    p.z = i2z + q * (n1 + q * (delta1 - n1 + (q - 1.0) * (n1PlusN2 - 2.0 * delta1)))
    pDisc[ctr], nDisc[ctr], rDisc[ctr], oDisc[ctr] = p, lerp(norm1, norm2, q), lerp(rot1, rot2, q), lerp(off1, off2, q)
    wDisc[ctr], hLDisc[ctr], hRDisc[ctr] = lerpWAndH(w1, w2, hL1, hL2, hR1, hR2, q)
    ctr, pLast = ctr + 1, p
  end

  -- Fit through the intermediate line segments of the reference polyline.
  local lastIdx = polyLen - 1
  for i = 3, lastIdx do
    local iMinus1 = i - 1
    pL, pR, norm1, norm2 = poly[iMinus1], poly[i], normals[iMinus1], normals[i]
    rot1, rot2, off1, off2 = pL.rot[0], pR.rot[0], pL.offset, pR.offset
    w1, w2, hL1, hL2, hR1, hR2 = pL.widths, pR.widths, pL.heightsL, pR.heightsL, pL.heightsR, pR.heightsR
    i1, i2, i3, i4 = poly[i - 2].p, pL.p, pR.p, poly[i + 1].p
    i1z, i2z, i3z, i4z, i2i3 = i1.z, i2.z, i3.z, i4.z, i3 - i2
    delta0, delta1, delta2 = i2z - i1z, i3z - i2z, i4z - i3z
    signDelta1, absDelta1 = sign2(delta1), abs(delta1)
    n1 = (sign2(delta0) + signDelta1) * min(abs(delta0), absDelta1, 0.5 * abs((delta0 + delta1) * 0.5))
    n2 = (signDelta1 + sign2(delta2)) * min(absDelta1, abs(delta2), 0.5 * abs((delta1 + delta2) * 0.5))
    n1PlusN2 = n1 + n2
    d23 = i2:distance(i3)
    d1, d2, d3 = max(1e-30, sqrt(i1:distance(i2))), sqrt(d23), max(1e-30, sqrt(i3:distance(i4)))
    m1, m2, sd2 = (i2 - i1) / d1 + (i1 - i3) / (d1 + d2), (i2 - i4) / (d2 + d3) + (i4 - i3) / d3, splSm * d2
    splineGran = ceil(d23 * targetLonResInv)
    splineGranInv = 1.0 / splineGran
    for j = 1, splineGran do                                                                        -- Do not include start point here (to avoid duplicate disc. points).
      local q = j * splineGranInv
      local tt, t_1 = q * q, q - 1
      local t_1sq = t_1 * t_1
      local p = q * t_1sq * sd2 * m1 + tt * t_1 * sd2 * m2 + t_1sq * (2.0 * q + 1) * i2 - tt * (2.0 * q - 3.0) * i3 + splSm * t_1 * (q * t_1 + tt) * i2i3
      p.z = i2z + q * (n1 + q * (delta1 - n1 + (q - 1.0) * (n1PlusN2 - 2.0 * delta1)))
      pDisc[ctr], nDisc[ctr], rDisc[ctr], oDisc[ctr] = p, lerp(norm1, norm2, q), lerp(rot1, rot2, q), lerp(off1, off2, q)
      wDisc[ctr], hLDisc[ctr], hRDisc[ctr] = lerpWAndH(w1, w2, hL1, hL2, hR1, hR2, q)
      ctr, pLast = ctr + 1, p
    end
  end

  -- Fit through the last line segment of the reference polyline.
  local secondLast = polyLen - 1
  pL, pR, norm1, norm2 = poly[secondLast], poly[polyLen], normals[secondLast], normals[polyLen]
  rot1, rot2, off1, off2 = pL.rot[0], pR.rot[0], pL.offset, pR.offset
  w1, w2, hL1, hL2, hR1, hR2 = pL.widths, pR.widths, pL.heightsL, pR.heightsL, pL.heightsR, pR.heightsR
  i1, i2, i3, i4 = poly[max(1, polyLen - 2)].p, pL.p, t3, t4
  i1z, i2z, i3z, i4z, i2i3 = i1.z, i2.z, i3.z, i4.z, i3 - i2
  delta0, delta1, delta2 = i2z - i1z, i3z - i2z, i4z - i3z
  signDelta1, absDelta1 = sign2(delta1), abs(delta1)
  n1 = (sign2(delta0) + signDelta1) * min(abs(delta0), absDelta1, 0.5 * abs((delta0 + delta1) * 0.5))
  n2 = (signDelta1 + sign2(delta2)) * min(absDelta1, abs(delta2), 0.5 * abs((delta1 + delta2) * 0.5))
  n1PlusN2 = n1 + n2
  d23 = i2:distance(i3)
  d1, d2, d3 = max(1e-30, sqrt(i1:distance(i2))), sqrt(d23), max(1e-30, sqrt(i3:distance(i4)))
  m1, m2, sd2 = (i2 - i1) / d1 + (i1 - i3) / (d1 + d2), (i2 - i4) / (d2 + d3) + (i4 - i3) / d3, splSm * d2
  splineGran = ceil(d23 * targetLonResInv)
  splineGranInv = 1.0 / splineGran
  r.nodes[#r.nodes].p = i3
  for j = 1, splineGran do                                                                          -- Do not include start point here (to avoid duplicate disc. points).
    local q = j * splineGranInv
    local tt, t_1 = q * q, q - 1
    local t_1sq = t_1 * t_1
    local p = q * t_1sq * sd2 * m1 + tt * t_1 * sd2 * m2 + t_1sq * (2.0 * q + 1) * i2 - tt * (2.0 * q - 3.0) * i3 + splSm * t_1 * (q * t_1 + tt) * i2i3
    p.z = i2z + q * (n1 + q * (delta1 - n1 + (q - 1.0) * (n1PlusN2 - 2.0 * delta1)))
    pDisc[ctr], nDisc[ctr], rDisc[ctr], oDisc[ctr] = p, lerp(norm1, norm2, q), lerp(rot1, rot2, q), lerp(off1, off2, q)
    wDisc[ctr], hLDisc[ctr], hRDisc[ctr] = lerpWAndH(w1, w2, hL1, hL2, hR1, hR2, q)
    ctr, pLast = ctr + 1, p
  end

  return pDisc, nDisc, rDisc, oDisc, wDisc, hLDisc, hRDisc
end

-- Computes the full angle between two vectors, using a direction.
local function calcSpanAngle(center, rotDir, p1, p2)
  local n2, n3 = p1 - center, p2 - center
  return (twoPi + atan2(n2:dot(n3:cross(rotDir)), n2:dot(n3))) % twoPi
end

-- Fits a circular arc segment through a road.
local function fitArc(road)

  -- Determine if an arc can be fitted through the given data.
  local nodes = road.nodes
  local numNodes, cen, p1, p2, p3 = #nodes, nil, nil, nil, nil
  if numNodes > 2 then
    p1, p2, p3 = nodes[1].p, nodes[2].p, nodes[3].p
    cen = circle2DFrom3Points(p1, p2, p3)                                                        -- Find the (2D) circle which fits through the (three) road nodes.
  end
  if not cen then
    return fitSplineStandardRoad(road)                                                              -- If an arc cannot be fitted through the given nodes, fit a spline instead.
  end

  -- Compute the sparse normals of the given polyline.
  local normals = getUnitNormals(road)

  -- Discretise the arc to produce a fitted polyline.
  local pDisc, nDisc, rDisc, oDisc, wDisc, hLDisc, hRDisc = {}, {}, {}, {}, {}, {}, {}
  pStart_2D:set(p1.x, p1.y, 0.0)
  pMid_2D:set(p2.x, p2.y, 0.0)
  pEnd_2D:set(p3.x, p3.y, 0.0)
  local v1 = pStart_2D - cen
  local theta, signFac = 0.0, -sign2((p2 - p1):cross(vertical):dot(p3-p1))
  local rotDir = (pStart_2D - pEnd_2D):cross(pMid_2D - pEnd_2D):normalized()
  theta = signFac * calcSpanAngle(cen, rotDir, pStart_2D, pEnd_2D)
  local z1, z2, norm1, norm2 = p1.z, p3.z, normals[1], normals[3]
  local nd1, nd3 = nodes[1], nodes[3]
  local rot1, rot2, off1, off2 = nd1.rot[0], nd3.rot[0], nd1.offset, nd3.offset
  local w1, w2 = nd1.widths, nd3.widths
  local hL1, hL2, hR1, hR2 = nd1.heightsL, nd3.heightsL, nd1.heightsR, nd3.heightsR
  local arcGran = ceil((p1:distance(p2) + p2:distance(p3)) / max(1, road.targetArcRes[0]))
  local arcGranInv = 1.0 / arcGran
  for i = 0, arcGran do
    local q, idx = i * arcGranInv, i + 1
    local p = cen + rotateVecAroundAxis(v1, vertical, q * theta)
    p.z = lerp(z1, z2, q)
    pDisc[idx] = p
    nDisc[idx], rDisc[idx], oDisc[idx] = lerp(norm1, norm2, q), lerp(rot1, rot2, q), lerp(off1, off2, q)
    wDisc[idx], hLDisc[idx], hRDisc[idx] = lerpWAndH(w1, w2, hL1, hL2, hR1, hR2, q)
  end

  return pDisc, nDisc, rDisc, oDisc, wDisc, hLDisc, hRDisc
end

-- Fits civil engineering style splines through a given road (line-spline-arc-spline-line sequences),
-- and interpolates a local orthonormal frame across this discretisation.
local function fitCivEngAndFrame(road)

  -- Compute the sparse normals of the given polyline.
  local poly = road.nodes
  local normals = getUnitNormals(road)

  -- If there are only two nodes, fit a spline instead.
  local polyLen = #poly
  if polyLen < 3 then
    return fitSplineStandardRoad(road)
  end

  -- Attempt to fit civil-engineering style splines at each corner.
  local poly1 = poly[1]
  local pDisc, nDisc, rDisc, oDisc, wDisc, hLDisc, hRDisc = { poly1.p }, { normals[1] }, { poly1.rot[0] }, { poly1.offset }, { poly1.widths }, { poly1.heightsL }, { poly1.heightsR }
  local ctr, polyLenMinus1 = 2, polyLen - 1
  local targetLonResInv, targetArcResInv = 1.0 / road.targetLonRes[0], 1.0 / road.targetArcRes[0]
  for i = 2, polyLenMinus1 do

    -- Compute the three triangle points which will define the circular arc.
    -- [This is the node position and a point on each connecting line segment, which depend on the selected incircle radius].
    local iMinus1, iPlus1 = i - 1, i + 1
    local node, nM, nP = poly[i], poly[iMinus1], poly[iPlus1]
    local pI, pLast, pNext, icRad = node.p, nM.p, nP.p, node.incircleRad[0]
    local vLast, vNext = pLast - pI, pNext - pI
    local pIm, pIp = pI + icRad * vLast, pI + icRad * vNext

    -- Compute the incircle.
    tmp1:set(pI.x, pI.y, 0.0)
    tmp2:set(pIm.x, pIm.y, 0.0)
    tmp3:set(pIp.x, pIp.y, 0.0)
    local iCen_2D, iRad = computeIncircle2D(tmp1, tmp2, tmp3)
    iRad = iRad + 1e-5

    -- Compute the two intersection points on each of the triangle edges which touch the node.
    -- [At these intersections, the linear segment tangents match the arc tangent, so continuity exists].
    local p1_2D, p3_2D = intLineSegAndCircle(tmp1, tmp2, iCen_2D, iRad), intLineSegAndCircle(tmp1, tmp3, iCen_2D, iRad)

    -- Interpolate to get the bounding values at each joining point on the line-spline-arc-spline-line section.
    local qA, qB = getInterpP(p1_2D, pIm, pI), getInterpP(p3_2D, pI, pIp)                                                     -- Interpolation parameters.
    local un1, un2, un3 = normals[iMinus1], normals[i], normals[iPlus1]                                                       -- Normals.
    local nU1, nU4 = lerp(un1, un2, qA), lerp(un2, un3, qB)
    local nU2, nU3 = lerp(nU1, nU4, oneThird), lerp(nU1, nU4, twoThirds)
    local ro1, ro2, ro3 = poly[iMinus1].rot[0], poly[i].rot[0], poly[iPlus1].rot[0]
    local rU1, rU4 = lerp(ro1, ro2, qA), lerp(ro2, ro3, qB)                                                                   -- Rotation.
    local rU2, rU3 = lerp(rU1, rU4, oneThird), lerp(rU1, rU4, twoThirds)
    local oo1, oo2, oo3 = poly[iMinus1].offset, poly[i].offset, poly[iPlus1].offset                                           -- Lateral offset.
    local oU1, oU4 = lerp(oo1, oo2, qA), lerp(oo2, oo3, qB)
    local oU2, oU3 = lerp(oU1, oU4, oneThird), lerp(oU1, oU4, twoThirds)
    local zp1, zp2, zp3 = pLast.z, pI.z, pNext.z                                                                              -- Elevation.
    local zU1, zU4 = lerp(zp1, zp2, qA), lerp(zp2, zp3, qB)
    local zU2, zU3 = lerp(zU1, zU4, oneThird), lerp(zU1, zU4, twoThirds)
    local wU1, hLU1, hRU1 = lerpWAndH(nM.widths, node.widths, nM.heightsL, node.heightsL, nM.heightsR, node.heightsR, qA)     -- Lane widths and left/right relative height offsets.
    local wU4, hLU4, hRU4 = lerpWAndH(node.widths, nP.widths, node.heightsL, nP.heightsL, node.heightsR, nP.heightsR, qB)
    local wU2, hLU2, hRU2 = lerpWAndH(wU1, wU4, hLU1, hLU4, hRU1, hRU4, oneThird)
    local wU3, hLU3, hRU3 = lerpWAndH(wU1, wU4, hLU1, hLU4, hRU1, hRU4, twoThirds)

    -- Determine the angular domain for the arc.
    -- [The sign of theta depends on the sign of the distance to the lateral plane of the current point.]
    local v1_2D = p1_2D - iCen_2D
    local tgt_3D = pIp - pIm
    tgt_2D:set(tgt_3D.x, tgt_3D.y, 0.0)
    tgt_2D:normalize()
    local signFac = -sign2(tgt_2D:cross(un2):dot(pIp - pI))
    local theta = angleBetweenVecs(v1_2D, p3_2D - iCen_2D) * signFac
    local vStart_2D, vEnd_2D = rotateVecAroundAxis(v1_2D, vertical, oneThird * theta), rotateVecAroundAxis(v1_2D, vertical, twoThirds * theta)
    local u1_2D, u2_2D, u3_2D = p1_2D, iCen_2D + vStart_2D, iCen_2D + vEnd_2D
    local arcAngle = angleBetweenVecs(u2_2D - iCen_2D, u3_2D - iCen_2D) * signFac

    -- Fit a discretised line.
    -- [The points and width values are linearly-interpolated, and the normals are spherically-interpolated].
    local lastIdx = ctr - 1
    local nn1, rr1, ww1, hhL1, hhR1 = nDisc[lastIdx], rDisc[lastIdx], wDisc[lastIdx], hLDisc[lastIdx], hRDisc[lastIdx]
    local pStart_3D = pDisc[lastIdx]
    pStart_2D:set(pStart_3D.x, pStart_3D.y, 0.0)
    local i1, i2, i3, i4 = pDisc[max(1, lastIdx - 1)], pStart_3D, u1_2D, u2_2D
    i3.z, i4.z = zU1, zU2
    local i2i3 = i3 - i2
    local d23 = i2:distance(i3)
    local d1, d2, d3 = max(1e-30, sqrt(i1:distance(i2))), sqrt(d23), max(1e-30, sqrt(i3:distance(i4)))
    local m1, m2, sd2 = (i2 - i1) / d1 + (i1 - i3) / (d1 + d2), (i2 - i4) / (d2 + d3) + (i4 - i3) / d3, splSm * d2
    local splineGran = min(10, ceil(d23 * targetLonResInv))
    local splineGranInv = 1.0 / splineGran
    for j = 0, splineGran do
      local q = j * splineGranInv
      local tt, t_1 = q * q, q - 1
      local t_1sq = t_1 * t_1
      pDisc[ctr] = q * t_1sq * sd2 * m1 + tt * t_1 * sd2 * m2 + t_1sq * (2.0 * q + 1) * i2 - tt * (2.0 * q - 3.0) * i3 + splSm * t_1 * (q * t_1 + tt) * i2i3
      nDisc[ctr], rDisc[ctr], oDisc[ctr] = lerp(nn1, nU1, q), lerp(rr1, rU1, q), lerp(oo1, oU1, q)
      wDisc[ctr], hLDisc[ctr], hRDisc[ctr] = lerpWAndH(ww1, wU1, hhL1, hLU1, hhR1, hRU1, q)
      ctr = ctr + 1
    end

    -- Compute the arc section.
    -- [This is done before computing the Clothoid sections].
    local arcGran = min(6, ceil(u3_2D:distance(u2_2D) * targetArcResInv) + 1)
    local arcGranInv = 1.0 / arcGran
    local pArc, nArc, rArc, oArc, wArc, hLArc, hRArc = {}, {}, {}, {}, {}, {}, {}
    for j = 0, arcGran do
      local idx, q = j + 1, j * arcGranInv
      pArc[idx] = iCen_2D + rotateVecAroundAxis(vStart_2D, vertical, q * arcAngle)
      pArc[idx].z = lerp(zU2, zU3, q)
      nArc[idx], rArc[idx], oArc[idx] = lerp(nU2, nU3, q), lerp(rU2, rU3, q), lerp(oU2, oU3, q)
      wArc[idx], hLArc[idx], hRArc[idx] = lerpWAndH(wU2, wU3, hLU2, hLU3, hRU2, hRU3, q)
    end

    -- Fit a spline between the first line and the arc.
    local pClo1, nClo1, rClo1, oClo1, wClo1, hLClo1, hRClo1 = {}, {}, {}, {}, {}, {}, {}
    i1, i2, i3, i4 = pIm, pDisc[ctr - 1], pArc[1], pArc[2]
    i2i3 = i3 - i2
    d23 = i2:distance(i3)
    d1, d2, d3 = max(1e-30, sqrt(i1:distance(i2))), sqrt(d23), max(1e-30, sqrt(i3:distance(i4)))
    m1, m2, sd2 = (i2 - i1) / d1 + (i1 - i3) / (d1 + d2), (i2 - i4) / (d2 + d3) + (i4 - i3) / d3, splSm * d2
    splineGran = min(7, ceil(d23 * targetLonResInv) + 1)
    splineGranInv = 1.0 / splineGran
    for j = 0, splineGran do
      local idx, q = j + 1, j * splineGranInv
      local tt, t_1 = q * q, q - 1
      local t_1sq = t_1 * t_1
      pClo1[idx] = q * t_1sq * sd2 * m1 + tt * t_1 * sd2 * m2 + t_1sq * (2.0 * q + 1) * i2 - tt * (2.0 * q - 3.0) * i3 + splSm * t_1 * (q * t_1 + tt) * i2i3
      nClo1[idx], rClo1[idx], oClo1[idx] = lerp(nU1, nU2, q), lerp(rU1, rU2, q), lerp(oU1, oU2, q)
      wClo1[idx], hLClo1[idx], hRClo1[idx] = lerpWAndH(wU1, wU2, hLU1, hLU2, hRU1, hRU2, q)
    end

    -- Fit a spline between the arc and the second line.
    local pClo2, nClo2, rClo2, oClo2, wClo2, hLClo2, hRClo2 = {}, {}, {}, {}, {}, {}, {}
    local pArcLen = #pArc
    i1, i2, i3, i4 = pArc[pArcLen - 1], pArc[pArcLen], p3_2D, pIp
    i3.z = zU4
    i2i3 = i3 - i2
    d23 = i2:distance(i3)
    d1, d2, d3 = max(1e-30, sqrt(i1:distance(i2))), sqrt(d23), max(1e-30, sqrt(i3:distance(i4)))
    m1, m2, sd2 = (i2 - i1) / d1 + (i1 - i3) / (d1 + d2), (i2 - i4) / (d2 + d3) + (i4 - i3) / d3, splSm * d2
    splineGran = min(7, ceil(d23 * targetLonResInv) + 1)
    splineGranInv = 1.0 / splineGran
    for j = 0, splineGran do
      local idx, q = j + 1, j * splineGranInv
      local tt, t_1 = q * q, q - 1
      local t_1sq = t_1 * t_1
      pClo2[idx] = q * t_1sq * sd2 * m1 + tt * t_1 * sd2 * m2 + t_1sq * (2.0 * q + 1) * i2 - tt * (2.0 * q - 3.0) * i3 + splSm * t_1 * (q * t_1 + tt) * i2i3
      nClo2[idx], rClo2[idx], oClo2[idx] = lerp(nU3, nU4, q), lerp(rU3, rU4, q), lerp(oU3, oU4, q)
      wClo2[idx], hLClo2[idx], hRClo2[idx] = lerpWAndH(wU3, wU4, hLU3, hLU4, hRU3, hRU4, q)
    end

    -- Append [Clothoid 1 - Arc - Clothoid 2] multi-section to the discretised points array.
    local numClo1 = #pClo1
    for j = 1, numClo1 do
      pDisc[ctr], nDisc[ctr], rDisc[ctr], oDisc[ctr] = pClo1[j], nClo1[j], rClo1[j], oClo1[j]
      wDisc[ctr], hLDisc[ctr], hRDisc[ctr] = wClo1[j], hLClo1[j], hRClo1[j]
      ctr = ctr + 1
    end
    for j = 1, pArcLen do
      pDisc[ctr], nDisc[ctr], rDisc[ctr], oDisc[ctr] = pArc[j], nArc[j], rArc[j], oArc[j]
      wDisc[ctr], hLDisc[ctr], hRDisc[ctr] = wArc[j], hLArc[j], hRArc[j]
      ctr = ctr + 1
    end
    local numClo2 = #pClo2
    for j = 1, numClo2 do
      pDisc[ctr], nDisc[ctr], rDisc[ctr], oDisc[ctr] = pClo2[j], nClo2[j], rClo2[j], oClo2[j]
      wDisc[ctr], hLDisc[ctr], hRDisc[ctr] = wClo2[j], hLClo2[j], hRClo2[j]
      ctr = ctr + 1
    end
  end

  -- Fit a final discretised line between the last multi-section and the very last point.
  -- [The points and lane widths are linearly-interpolated, and the normals are spherically-interpolated].
  local ctrLast = ctr - 1
  local nLast = poly[polyLen]
  local i1, i2, i3 = pDisc[ctr - 2], pDisc[ctrLast], nLast.p
  local i2i3 = i3 - i2
  local norm1, norm2 = nDisc[ctrLast], normals[polyLen]
  local w1, w2, rot1, rot2, off1, off2 = wDisc[ctrLast], nLast.widths, rDisc[ctrLast], nLast.rot[0], oDisc[ctrLast], nLast.offset
  local hL1, hL2, hR1, hR2 = hLDisc[ctrLast], nLast.heightsL, hRDisc[ctrLast], nLast.heightsR
  local d23 = i2:distance(i3)
  local d1, d2 = max(1e-30, sqrt(i1:distance(i2))), sqrt(d23)
  local m1, m2, sd2 = (i2 - i1) / d1 + (i1 - i3) / (d1 + d2), (i2 - i3) / d2, splSm * d2
  local splineGran = ceil(d23 * targetLonResInv)
  local splineGranInv = 1.0 / splineGran
  for j = 0, splineGran do
    local q = j * splineGranInv
    local tt, t_1 = q * q, q - 1
    local t_1sq = t_1 * t_1
    pDisc[ctr] = q * t_1sq * sd2 * m1 + tt * t_1 * sd2 * m2 + t_1sq * (2.0 * q + 1) * i2 - tt * (2.0 * q - 3.0) * i3 + splSm * t_1 * (q * t_1 + tt) * i2i3
    nDisc[ctr], rDisc[ctr], oDisc[ctr] = lerp(norm1, norm2, q), lerp(rot1, rot2, q), lerp(off1, off2, q)
    wDisc[ctr], hLDisc[ctr], hRDisc[ctr] = lerpWAndH(w1, w2, hL1, hL2, hR1, hR2, q)
    ctr = ctr + 1
  end

  -- Remove any duplicate adjacents (nodes, normals and lane widths).
  pDisc, nDisc, rDisc, oDisc, wDisc, hLDisc, hRDisc = removeDuplicates(pDisc, nDisc, rDisc, oDisc, wDisc, hLDisc, hRDisc)

  return pDisc, nDisc, rDisc, oDisc, wDisc, hLDisc, hRDisc
end

-- Computes the geometric data for the given road, ready for rendering.
-- This function performs either CR-spline-fitting or line-spline-arc-spline-line (civil engineering style) fitting to the reference nodes.
-- The structure is indexed as [point][lane id][1:12] where:
--  [1:4] are the cross sectional points, clockwise from top-left,
--  [5:6] are the unit normal/lateral vectors (same for all lanes),
--  [7] is the lane midpoint position at the point,
--  [8] is the lane type (string).
--  [9:11] is the lane width and left/right relative heights.
--  [12] is the signed lateral rotation angle (super-elevation), same for all lanes.
--  [13] The lateral lane offset value (same for every lane, at this disc. pt).
local function computeRoadRenderData(road, roads, map)

  -- Filter by case:
  -- i) Standard roads: if the user has requested a civil engineering style spline, this is handled separately.
  -- ii) Link roads: a fresh CR-Chordal spline is fitted through the reference nodes, then centripetal CR spline fitting is applied.
  -- iii) Arc roads: circular-arc fitted splines comprising of exactly three nodes.
  -- iv) Standard roads: the default is to use centripetal CR spline fitting through the nodes.
  local pDisc, nDisc, rDisc, oDisc, wDisc, hLDisc, hRDisc = nil, nil, nil, nil, nil, nil, nil
  if road.isCivilEngRoads[0] then
    pDisc, nDisc, rDisc, oDisc, wDisc, hLDisc, hRDisc = fitCivEngAndFrame(road)
  elseif road.isLinkRoad then
    pDisc, nDisc, rDisc, oDisc, wDisc, hLDisc, hRDisc = fitSplineLinkRoad(road, roads, map)
  elseif road.isArc then
    pDisc, nDisc, rDisc, oDisc, wDisc, hLDisc, hRDisc = fitArc(road)
  else
    pDisc, nDisc, rDisc, oDisc, wDisc, hLDisc, hRDisc = fitSplineStandardRoad(road)
  end

  -- Compute the render data for this road (sub node data at each discretisation point on the fitted polyline).
  local profile, laneKeys, leftKeys, rightKeys = road.profile, road.laneKeys, road.leftKeys, road.rightKeys
  local numLaneKeys, numLeftKeys, numRightKeys = #laneKeys, #leftKeys, #rightKeys
  local isConformToTerrain, numDiscPoints = road.isConformRoadToTerrain[0], #pDisc

  -- Fetch the existing render data table, if it exists, or allocate a new table (new roads will require this).
  local renderData = road.renderData or {}
  if #renderData > numDiscPoints then
    table.clear(renderData)                                                                         -- If there are less points than in last frame, clear all existing render data.
  end

  for i = 1, numDiscPoints do

    -- Compute the unit tangent and lateral vectors, at this disc. point.
    local tgt = pDisc[min(numDiscPoints, i + 1)] - pDisc[max(1, i - 1)]
    tgt:normalize()
    local nml = nDisc[i]
    tmpLat:set(nml.y * tgt.z - nml.z * tgt.y, nml.z * tgt.x - nml.x * tgt.z, nml.x * tgt.y - nml.y * tgt.x)

    -- Fetch the render data for this discretisation point, if it exists, or allocate a new table (new roads will require this).
    local rData = renderData[i] or {}
    if #rData > numLaneKeys then
      table.clear(rData)                                                                            -- If the number of lanes have changed, clear the table for this disc. point.
    end

    -- First, do the left lanes first, from inner to outer.
    -- [Splitting road into two sides ensures the reference line is rendered at the center, without needing an offset].
    local p, n, w, hL, hR = pDisc[i], nDisc[i], wDisc[i], hLDisc[i], hRDisc[i]
    local rotRad, off, pWork = rad(rDisc[i]), oDisc[i], p
    for j = numLeftKeys, 1, -1 do
      local k = leftKeys[j]
      local laneWidth, heightL, heightR = w[k][0], hL[k][0], hR[k][0]
      local laneWidthVec = laneWidth * tmpLat
      local nHL, nHR = n * heightL, n * heightR
      local lu, ru = pWork + nHL, pWork - laneWidthVec + nHR                                        -- The lane inner-most/outer-most points.
      pWork = pWork - laneWidthVec
      local rdk = rData[k]
      if not rdk then
        rdk = {}
        rdk[6] = vec3(0, 0)
      end
      local oVec = tmpLat * off                                                                     -- The lateral offset vector.
      local p1, p2, p3, p4 = ru + oVec, lu + oVec, lu - nHL + oVec, ru - nHR + oVec                 -- The four cross-sectional points from top-left, clockwise, to bottom-right.
      rdk[1], rdk[2], rdk[3], rdk[4] = p1, p2, p3, p4                                               -- [1:4] The four cross-sectional points, clockwise from top left.
      rdk[5] = n                                                                                    -- [5] The road section unit normal vector (not quad local).
      rdk[6]:set(tmpLat.x, tmpLat.y, tmpLat.z)                                                      -- [6] The road section unit lateral vectors (not quad local).
      rdk[7] = (p1 + p2) * 0.5                                                                      -- [7] The lane midpoint (on top face).
      rdk[8] = profile[k].type                                                                      -- [8] The lane type ('road_lane', 'sidewalk', 'island', etc).
      rdk[9], rdk[10], rdk[11] = laneWidth, heightL, heightR                                        -- [9:11] The lane width, left/right relative heights.
      rdk[12] = rotRad                                                                              -- [12] The signed lateral rotation angle (super-elevation).
      rdk[13] = off                                                                                 -- [13] The lateral lane offset value (same for every lane, at this disc. pt).
      rData[k] = rdk
    end

    -- Next, do the right lanes, from inner to outer.
    -- [Note: points [1:4] are flipped here, to ensure they follow clockwise from left-top on both sides].
    pWork = p
    for j = 1, numRightKeys do
      local k = rightKeys[j]
      local laneWidth, heightL, heightR = w[k][0], hL[k][0], hR[k][0]
      local laneWidthVec = laneWidth * tmpLat
      local nHL, nHR = n * heightL, n * heightR
      local lu, ru = pWork + nHL, pWork + laneWidthVec + nHR                                        -- The lane inner-most/outer-most points.
      pWork = pWork + laneWidthVec
      local rdk = rData[k]
      if not rdk then
        rdk = {}
        rdk[6] = vec3(0, 0)
      end
      local oVec = tmpLat * off                                                                     -- The lateral offset vector.
      local p1, p2, p3, p4 = lu + oVec, ru + oVec, ru - nHR + oVec, lu - nHL + oVec                 -- The four cross-sectional points from top-left, clockwise, to bottom-right.
      rdk[1], rdk[2], rdk[3], rdk[4] = p1, p2, p3, p4                                               -- [1:4] The four cross-sectional points, clockwise from top left.
      rdk[5] = n                                                                                    -- [5] The road section unit normal vector (not quad local).
      rdk[6]:set(tmpLat.x, tmpLat.y, tmpLat.z)                                                      -- [6] The road section unit lateral vectors (not quad local).
      rdk[7] = (p1 + p2) * 0.5                                                                      -- [7] The lane midpoint (on top face).
      rdk[8] = profile[k].type                                                                      -- [8] The lane type ('road_lane', 'sidewalk', 'island', etc).
      rdk[9], rdk[10], rdk[11] = laneWidth, heightL, heightR                                        -- [9:11] The lane width, left/right relative heights.
      rdk[12] = rotRad                                                                              -- [12] The signed lateral rotation angle (super-elevation).
      rdk[13] = off                                                                                 -- [13] The lateral lane offset value (same for every lane, at this disc. pt).
      rData[k] = rdk
    end
    renderData[i] = rData
  end

  -- If the road is set to conform to the terrain, offset the profile vertically, as required.
  -- [The terrain height under the left and right points are sampled, and the four quad points are offset].
  if isConformToTerrain then
    for i = 1, numDiscPoints do
      local rD = renderData[i]
      for j = 1, numLaneKeys do
        local rDL = rD[laneKeys[j]]
        local l1, l2, l3, l4 = rDL[1], rDL[2], rDL[3], rDL[4]
        tmp1:set(l1.x, l1.y, 0)
        tmp2:set(l2.x, l2.y, 0)
        local gL = core_terrain.getTerrainHeight(tmp1)                                              -- Get the terrain height value under the left and right points.
        local gR = core_terrain.getTerrainHeight(tmp2)
        tmp1:set(0, 0, l4.z - gL)                                                                   -- The left and right vertical offset vectors, required to conform the road.
        tmp2:set(0, 0, l3.z - gR)
        rDL[1], rDL[2], rDL[3], rDL[4] = l1 - tmp1, l2 - tmp2, l3 - tmp2, l4 - tmp1
        rDL[7] = rDL[7] - (tmp1 + tmp2) * 0.5                                                       -- The lane midpoint.
      end
    end
  end

  -- Set the road render data on the road.
  road.renderData = renderData

  -- Handle any tunneled sections for this road.
  if road.isAllowTunnels[0] and extensions.editor_terrainEditor.getTerrainBlock() then
    table.clear(road.tunnels)
    local tSections = identifyTunnelSections(renderData, road.extraS[0], road.extraE[0])
    local numTSections = #tSections
    for i = 1, numTSections do
      local sec = tSections[i]
      road.tunnels[i] = {
        s = sec.s, e = sec.e,
        radGran = road.radGran[0], radOffset = road.radOffset[0],
        thickness = road.thickness[0], zOffsetFromRoad = road.zOffsetFromRoad[0],
        protrudeS = road.protrudeS[0], protrudeE = road.protrudeE[0] }
    end
  end
end


-- Public interface.
M.fitSpline =                                             fitSpline
M.computeRoadRenderData =                                 computeRoadRenderData

return M