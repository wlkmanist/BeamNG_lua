-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Module constants.
local downShift = vec3(0, 0, 0.03)                                                                  -- The vertical offset when terraforming to the road top surface.
local fixedMargin = 2.0                                                                             -- The fixed margin around the road.
local averagingMargin = 2.0                                                                      -- Used when averaging the mask.

local prominence = 500.0                                                                            -- The maximum allowed Z-value. Height is thus in range [0, prominence].

local lowerVec = vec3(0, 0, 999)

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}
local logTag = 'RoadArchitect'


-- External modules used.
local kdTreeB2d = require('kdtreebox2d')
local roadMgr = require('editor/tech/roadArchitect/roads')                                          -- For managing the road structure/handling road calculations.
local profileMgr = require('editor/tech/roadArchitect/profiles')                                    -- For managing the profiles structure.
local util = require('editor/tech/roadArchitect/utilities')                                         -- A module containing miscellaneous utility functions.

-- Private constants.
local im = ui_imgui
local min, max, floor, ceil = math.min, math.max, math.floor, math.ceil
local sqrt, exp, twoPi = math.sqrt, math.exp, 2.0 * math.pi
local uint16Scale = 65535 / prominence
local uint16ScaleInv = 1.0 / uint16Scale


-- Undo callback for terraforming operations.
local function terraformUndo(data)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  if not tb then
    return
  end

  -- Recover the heightmap.
  local xMin, xMax, yMin, yMax = 1e99, -1e99, 1e99, -1e99
  for i = 1, #data do
    local d = data[i]
    tb:setHeight(d.x, d.y, max(0, d.old))
    xMin, xMax, yMin, yMax = min(xMin, d.x), max(xMax, d.x), min(yMin, d.y), max(yMax, d.y)
  end

  -- Update the grid after the changes.
  tb:updateGrid(vec3(xMin, yMin), vec3(xMax, yMax))
end

-- Redo callback for terraforming operations.
local function terraformRedo(data)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  if not tb then
    return
  end

  -- Recover the heightmap.
  local xMin, xMax, yMin, yMax = 1e99, -1e99, 1e99, -1e99
  for i = 1, #data do
    local d = data[i]
    tb:setHeight(d.x, d.y, max(0, d.new))
    xMin, xMax, yMin, yMax = min(xMin, d.x), max(xMax, d.x), min(yMin, d.y), max(yMax, d.y)
  end

  -- Update the grid after the changes.
  tb:updateGrid(vec3(xMin, yMin), vec3(xMax, yMax))
end

-- TODO: THIS FUNCTION IS NOT CURRENTLY USED. IT NEEDS TESTED FURTHER, BEFORE REPLACE THE BARYCENTRIC METHOD BELOW.
local function intersectsUp_Triangle(rpos, ca, bc, c, norm, normSq)
  local rposc = rpos - c
  local pOnTri = rposc:dot(norm) / norm.z
  rposc.z = rposc.z - pOnTri
  local pacnorm = rposc:cross(norm)
  local bx, by = bc:dot(pacnorm), ca:dot(pacnorm)
  if min(bx, by) >= 0 and bx + by <= normSq then
    return -pOnTri
  end
  return false
end

-- Determines if the given point p is inside triangle a-b-c, and if so - returns the z-value of the point on the 3D triangle.
local function intersectsUp_Triangle_Barycentric(p, a, b, c)
  
  -- Calculate the 2D vectors.
  local ax, ay, bx, by, cx, cy, px, py = a.x, a.y, b.x, b.y, c.x, c.y, p.x, p.y
  local v0x, v0y = cx - ax, cy - ay
  local v1x, v1y = bx - ax, by - ay
  local v2x, v2y = px - ax, py - ay
  
  -- Calculate all the relevant dot products.
  local dot00 = v0x * v0x + v0y * v0y
  local dot01 = v0x * v1x + v0y * v1y
  local dot02 = v0x * v2x + v0y * v2y
  local dot11 = v1x * v1x + v1y * v1y
  local dot12 = v1x * v2x + v1y * v2y

  -- Compute barycentric coordinates.
  local invDenom = 1.0 / (dot00 * dot11 - dot01 * dot01)
  local u = (dot11 * dot02 - dot01 * dot12) * invDenom
  local v = (dot00 * dot12 - dot01 * dot02) * invDenom

  -- Check if point is in triangle, then if so - return the z-coordinate.
  if (u >= 0) and (v >= 0) and (u + v <= 1) then
    return (a + u * (c - a) + v * (b - a)).z
  end
  return false
end

-- Averages the height with neighbouring points.
local function averageMask(height, mod, fixedMask, xSize, ySize)
  local xTop, yTop = xSize - 1, ySize - 1
  for x = 1, xTop do
    local modX, fixedMaskX = mod[x], fixedMask[x]
    for y = 1, yTop do
      if modX[y] > 0.5 and fixedMaskX[y] < 0.5 then
        local sum, count = 0.0, 0
        for dx = -averagingMargin, averagingMargin do
          for dy = -averagingMargin, averagingMargin do
            local nx, ny = x + dx, y + dy
            if nx >= 0.0 and nx <= xSize and ny >= 0.0 and ny <= ySize then
              sum = sum + height[nx][ny]
              count = count + 1
            end
          end
        end
        height[x][y] = sum / count
      end
    end
  end
end

-- Refines the given collection of triangles by splitting them into four.
local function refineTriangles(tris)
  local trisOut, ctr = {}, 1
  for i = 1, #tris, 3 do
    local a, b, c = tris[i], tris[i + 1], tris[i + 2]
    local mAB = vec3((a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5)
    local mAC = vec3((a.x + c.x) * 0.5, (a.y + c.y) * 0.5, (a.z + c.z) * 0.5)
    local mBC = vec3((c.x + b.x) * 0.5, (c.y + b.y) * 0.5, (c.z + b.z) * 0.5)

    trisOut[ctr] = a
    trisOut[ctr + 1] = mAB
    trisOut[ctr + 2] = mAC

    trisOut[ctr + 3] = b
    trisOut[ctr + 4] = mAB
    trisOut[ctr + 5] = mBC

    trisOut[ctr + 6] = c
    trisOut[ctr + 7] = mBC
    trisOut[ctr + 8] = mAC

    trisOut[ctr + 9] = mBC
    trisOut[ctr + 10] = mAB
    trisOut[ctr + 11] = mAC

    ctr = ctr + 12
  end
  return trisOut
end

-- Bloats the given renderdata by the given amount [top surface only].
local function getTriangles(road, excess)
  local rData = road.renderData
  if #rData < 2 then
    return
  end

  -- Bloat the outermost points laterally, using the local binormal (lateral) vector.
  local lMin, lMax = profileMgr.getMinMaxLaneKeys(road.profile)
  local left, right = {}, {}
  local lastIdx = #rData
  for i = 1, lastIdx do
    local rD = rData[i]
    left[i] = rD[lMin][4] - rD[lMin][6] * excess
    right[i] = rD[lMax][3] + rD[lMax][6] * excess
  end

  -- Bloat the first and last points longitudinally.
  left[1] = left[1] + (left[1] - left[2]):normalized() * excess
  right[1] = right[1] + (right[1] - right[2]):normalized() * excess
  local lastIdx2nd = lastIdx - 1
  left[lastIdx] = left[lastIdx] + (left[lastIdx] - left[lastIdx2nd]):normalized() * excess
  right[lastIdx] = right[lastIdx] + (right[lastIdx] - right[lastIdx2nd]):normalized() * excess

  -- Now form the triangles.
  -- [Do not include any inside tunnel sections].
  local tunnels, extraS, extraE = road.tunnels, road.extraS[0], road.extraE[0]
  local tris, ctr = {}, 1
  for i = 2, lastIdx do
    if not util.isInTunnel(i, tunnels, extraS, extraE) then
      local iMinus1 = i - 1
      tris[ctr] = left[i]
      tris[ctr + 1] = right[i]
      tris[ctr + 2] = left[iMinus1]
      tris[ctr + 3] = left[iMinus1]
      tris[ctr + 4] = right[iMinus1]
      tris[ctr + 5] = right[i]
      ctr = ctr + 6
    end
  end

  -- Refine the triangles for smoother terraforming results.
  for i = 1, 5 do
    refineTriangles(tris)
  end

  return tris
end

-- Gets the bottom surface triangles from the relevant roads.
local function getTrianglesMulti(roads, box, excess)
  local tris, ctr = {}, 1
  for _, road in pairs(roads) do
    local rData = road.renderData
    if #rData > 1 and not road.isOverlay and not road.isBridge then

      -- Bloat the outermost points laterally, using the local binormal (lateral) vector.
      local lMin, lMax = profileMgr.getMinMaxLaneKeys(road.profile)
      local left, right = {}, {}
      local lastIdx = #rData
      for i = 1, lastIdx do
        local rD = rData[i]
        left[i] = rD[lMin][4] - rD[lMin][6] * excess
        right[i] = rD[lMax][3] + rD[lMax][6] * excess
      end

      -- Bloat the first and last points longitudinally.
      left[1] = left[1] + (left[1] - left[2]):normalized() * excess
      right[1] = right[1] + (right[1] - right[2]):normalized() * excess
      local lastIdx2nd = lastIdx - 1
      left[lastIdx] = left[lastIdx] + (left[lastIdx] - left[lastIdx2nd]):normalized() * excess
      right[lastIdx] = right[lastIdx] + (right[lastIdx] - right[lastIdx2nd]):normalized() * excess

      -- Now form the triangles.
      -- [Do not include any inside tunnel sections].
      local tunnels, extraS, extraE = road.tunnels, road.extraS[0], road.extraE[0]
      for i = 2, lastIdx do
        if util.isInBox(left[i], box) and not util.isInTunnel(i, tunnels, extraS, extraE) then
          local iMinus1 = i - 1
          tris[ctr] = left[i]
          tris[ctr + 1] = right[i]
          tris[ctr + 2] = left[iMinus1]
          tris[ctr + 3] = left[iMinus1]
          tris[ctr + 4] = right[iMinus1]
          tris[ctr + 5] = right[i]
          ctr = ctr + 6
        end
      end
    end
  end

  -- Refine the triangles for smoother terraforming results.
  for i = 1, 5 do
    refineTriangles(tris)
  end
  
  return tris
end

-- Creates and populates a kd-tree containing the given triangles.
local function populateTree(tris)
  local tree = kdTreeB2d.new(#tris)
  for i = 1, #tris, 3 do
    local tA, tB, tC = tris[i], tris[i + 1], tris[i + 2]
    local tAx, tAy, tBx, tBy, tCx, tCy = tA.x, tA.y, tB.x, tB.y, tC.x, tC.y
    tree:preLoad(i, min(tAx, tBx, tCx), min(tAy, tBy, tCy), max(tAx, tBx, tCx), max(tAy, tBy, tCy))
  end
  tree:build()
  return tree
end

-- Terraforms the heightmap using the given terraforming data.
-- [Also commits the modification to support undo/redo].
local function modifyTerrainFromHeightArray(height, mod, xSize, ySize, bXMin, bXMax, bYMin, bYMax, tb)
  local history, hCtr = {}, 1
  for x = 0, xSize do
    local heightX, modX, rx = height[x], mod[x], x + bXMin
    for y = 0, ySize do
      if modX[y] > 0.5 then
        local ry = y + bYMin
        local z = heightX[y]
        local zOld = max(0, tb:getHeightGrid(rx, ry))
        tb:setHeightGrid(rx, ry, max(0, z))
        history[hCtr] = { old = zOld, new = z, x = rx, y = ry }
        hCtr = hCtr + 1
      end
    end
  end
  editor.history:commitAction("Terraform", history, terraformUndo, terraformRedo)

  -- Update the terrain block.
  tb:updateGrid(vec3(bXMin, bYMin), vec3(bXMax, bYMax))
end

-- Conforms the local terrain to the road.
local function conformTerrainToRoad(rIdx, DOI, margin)

  -- If there is no terrain block (eg smallgrid) then leave immediately.
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  if not tb or not te then
    return
  end
  local extents = tb:getWorldBox():getExtents()
  local center = tb:getWorldBox():getCenter()
  local xHalf, yHalf = extents.x * 0.5, extents.y * 0.5
  local tXMin, tXMax, tYMin, tYMax = center.x - xHalf, center.x + xHalf, center.y - xHalf, center.y + xHalf
  local zOff = tb:getTransform():getPosition().z

  -- Compute the AABB.
  local box = roadMgr.computeAABB2D(rIdx)
  DOI = max(5.0, DOI)
  box.xMin, box.xMax, box.yMin, box.yMax = box.xMin - DOI, box.xMax + DOI, box.yMin - DOI, box.yMax + DOI

  -- Initialize the mask.
  local mask, height = {}, {}
  local gMin, gMax = Point2I(0, 0), Point2I(0, 0)
  te:worldToGridByPoint2I(vec3(floor(max(tXMin, box.xMin)), floor(max(tYMin, box.yMin))), gMin, tb)
  te:worldToGridByPoint2I(vec3(ceil(min(tXMax, box.xMax)), ceil(min(tYMax, box.yMax))), gMax, tb)
  local bXMin, bXMax, bYMin, bYMax = gMin.x, gMax.x, gMin.y, gMax.y
  local xSize, ySize = bXMax - bXMin, bYMax - bYMin
  for x = 0, xSize do
    local xPos = bXMin + x
    local innerM, innerH = {}, {}
    for y = 0, ySize do
      innerM[y], innerH[y] = 0, max(0, tb:getHeightGrid(xPos, bYMin + y))
    end
    mask[x], height[x] = innerM, innerH
  end

  -- Collect the coarse triangles and bloat them up to the inner margin, then populate a kd-tree with them.
  local tris = getTriangles(roadMgr.roads[rIdx], fixedMargin)
  local tree = populateTree(tris)

  -- Iterate over the grid bounding box, and add contributions to the road mask.
  local fixedMask = {}
  for x = 0, xSize do
    local fixedMaskX = {}
    local gX = bXMin + x
    for y = 0, ySize do
      fixedMaskX[y] = 0
      local gY = bYMin + y
      local pWS = te:gridToWorldByPoint2I(Point2I(gX, gY), tb)
      for tIdx in tree:queryNotNested(pWS.x, pWS.y, pWS.x, pWS.y) do
        local z = intersectsUp_Triangle_Barycentric(pWS, tris[tIdx], tris[tIdx + 1], tris[tIdx + 2])
        --local tA, tB, tC = tri.a, tri.b, tri.c
        --local tCA = tC - tA
        --local tBC = tB - tC
        --local triNorm = tCA:cross(tBC)                                                                -- TODO: this needs tested further before replace barycentric method.
        --local sqTriNorm = triNorm:squaredLength()
        --local z = intersectsUp_Triangle(pWS, tCA, tBC, tC, triNorm, sqTriNorm)
        if z then
          fixedMaskX[y] = 1
        end
      end
    end
    fixedMask[x] = fixedMaskX
  end

  -- Collect the triangles and bloat up to the outer margin, then populate a kd-tree with them.
  local tris = getTriangles(roadMgr.roads[rIdx], margin + fixedMargin)
  local tree = populateTree(tris)

  -- Iterate over the grid bounding box, and add contributions to the road mask.
  for x = 0, xSize do
    local maskX, heightX = mask[x], height[x]
    local gX = bXMin + x
    for y = 0, ySize do
      local gY = bYMin + y
      local pWS = te:gridToWorldByPoint2I(Point2I(gX, gY), tb)
      for tIdx in tree:queryNotNested(pWS.x, pWS.y, pWS.x, pWS.y) do
        local z = intersectsUp_Triangle_Barycentric(pWS, tris[tIdx], tris[tIdx + 1], tris[tIdx + 2])
        --local tA, tB, tC = tri.a, tri.b, tri.c
        --local tCA = tC - tA
        --local tBC = tB - tC
        --local triNorm = tCA:cross(tBC)                                                                -- TODO: this stuff can be pre-cached and stored in tris, per triangle.
        --local sqTriNorm = triNorm:squaredLength()
        --local z = intersectsUp_Triangle(pWS, tCA, tBC, tC, triNorm, sqTriNorm)
        if z then
          heightX[y] = (maskX[y] == 0 and z - zOff) or min(z - zOff, heightX[y])
          maskX[y] = 1
        end
      end
    end
  end

  -- Create the mod structure.
  -- [A structure which stores the increasing domain of influence].
  local mod = {}
  local chMod = {}
  for x = 0, xSize do
    local maskX =  mask[x]
    mod[x], chMod[x] = {}, {}
    for y = 0, ySize do
      mod[x][y] = maskX[y]
      chMod[x][y] = maskX[y]
    end
  end

  -- Allocate the changes structure.
  local changes = {}
  for x = 0, xSize do
    changes[x] = {}
    local chCol = changes[x]
    for y = 0, ySize do
      chCol[y] = 0.0
    end
  end

  local numIter = ceil(0.5 * sqrt(8 * DOI + 1) - 1)

  -- Iteratively process the mask.
  for i = numIter, 1, -1 do
    local halfkernSizeL = i
    local kernSizeL = halfkernSizeL * 2 + 1
    local invI = 1 / kernSizeL
    local xStart, xEnd = halfkernSizeL + 1, xSize - halfkernSizeL - 1
    local yStart, yEnd = halfkernSizeL + 1, ySize - halfkernSizeL - 1

    -- X.
    for y = yStart, yEnd do
      local numerS, denomS = 0, 0
      for s = 1, kernSizeL do
        numerS, denomS = numerS + height[s][y], denomS + mod[s][y]
      end

      for x = xStart, xEnd do
        if denomS == 0 then
          changes[x][y] = height[x][y]
        else
          changes[x][y] = numerS * invI
          chMod[x][y] = 1
        end
        local frontEdge, backEdge = x + xStart, x - halfkernSizeL
        numerS = numerS + height[frontEdge][y] - height[backEdge][y]
        denomS = denomS + mod[frontEdge][y] - mod[backEdge][y]
      end
    end

    -- Y.
    for x = xStart, xEnd do
      local numerS, denomS = 0, 0
      local heightX, modX, chModX, chX = height[x], mod[x], chMod[x], changes[x]
      for s = 1, kernSizeL do
        numerS, denomS = numerS + heightX[s], denomS + modX[s]
      end

      for y = yStart, yEnd do
        if denomS ~= 0 then
          chX[y] = (chX[y] + numerS * invI) * 0.5
          chModX[y] = 1
        end
        local frontEdge, backEdge = y + xStart, y - halfkernSizeL
        numerS = numerS + heightX[frontEdge] - heightX[backEdge]
        denomS = denomS + modX[frontEdge] - modX[backEdge]
      end
    end

    -- Copy the changes onto the mask, reset the fixed mask points and reset the changes array.
    for x = xStart, xEnd do
      local maskX, heightX, modX, chModX, chX = mask[x], height[x], mod[x], chMod[x], changes[x]
      for y = yStart, yEnd do
        local m = maskX[y]
        heightX[y] = (1 - m) * chX[y] + m * heightX[y]
        modX[y] = chModX[y]
      end
    end
  end

  -- Average the height with neighbouring points.
  averageMask(height, mod, fixedMask, xSize, ySize)

  -- Terraform the heightmap from the processed mask.
  modifyTerrainFromHeightArray(height, mod, xSize, ySize, bXMin, bXMax, bYMin, bYMax, tb)
end

-- Terraforms the whole terrain block to the existing road network (or the group with the given index).
-- [Does not include overlays or bridges].
local function terraformMultiRoads(DOI, margin, group)

  -- If there is no terrain block (eg smallgrid) then leave immediately.
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  if not tb or not te then
    return
  end
  local extents = tb:getWorldBox():getExtents()
  local center = tb:getWorldBox():getCenter()
  local xHalf, yHalf = extents.x * 0.5, extents.y * 0.5
  local tXMin, tXMax, tYMin, tYMax = center.x - xHalf, center.x + xHalf, center.y - xHalf, center.y + xHalf
  local zOff = tb:getTransform():getPosition().z

  -- Compute the bounding box of the whole road network or group (if given).
  local roads = roadMgr.getRoadsFromGroup(group)
  local box = util.computeAABB2DGroup(group, roadMgr.roads, roadMgr.map)
  DOI = max(5.0, DOI)
  box.xMin = box.xMin - DOI
  box.xMax = box.xMax + DOI
  box.yMin = box.yMin - DOI
  box.yMax = box.yMax + DOI

  -- Initialize the mask.
  local mask, height = {}, {}
  local gMin, gMax = Point2I(0, 0), Point2I(0, 0)
  te:worldToGridByPoint2I(vec3(floor(max(tXMin, box.xMin)), floor(max(tYMin, box.yMin))), gMin, tb)
  te:worldToGridByPoint2I(vec3(ceil(min(tXMax, box.xMax)), ceil(min(tYMax, box.yMax))), gMax, tb)
  local bXMin, bXMax, bYMin, bYMax = gMin.x, gMax.x, gMin.y, gMax.y
  local xSize, ySize = bXMax - bXMin, bYMax - bYMin
  for x = 0, xSize do
    local xPos = bXMin + x
    local innerM, innerH = {}, {}
    for y = 0, ySize do
      innerM[y], innerH[y] = 0, max(0, tb:getHeightGrid(xPos, bYMin + y))
    end
    mask[x], height[x] = innerM, innerH
  end

  -- Compute the triangles, expanded up to the inner margin, then populate a kd-tree with them.
  local tris = getTrianglesMulti(roads, box, fixedMargin)
  local tree = populateTree(tris)

  -- Iterate over the grid bounding box, and add contributions to the road mask.
  local fixedMask = {}
  for x = 0, xSize do
    local fixedMaskX = {}
    local gX = bXMin + x
    for y = 0, ySize do
      fixedMaskX[y] = 0
      local gY = bYMin + y
      local pWS = te:gridToWorldByPoint2I(Point2I(gX, gY), tb)
      for tIdx in tree:queryNotNested(pWS.x, pWS.y, pWS.x, pWS.y) do
        local z = intersectsUp_Triangle_Barycentric(pWS, tris[tIdx], tris[tIdx + 1], tris[tIdx + 2])
        --local tA, tB, tC = tri.a, tri.b, tri.c
        --local tCA = tC - tA
        --local tBC = tB - tC
        --local triNorm = tCA:cross(tBC)                                                                -- TODO: this needs tested further before replace barycentric method.
        --local sqTriNorm = triNorm:squaredLength()
        --local z = intersectsUp_Triangle(pWS, tCA, tBC, tC, triNorm, sqTriNorm)
        if z then
          fixedMaskX[y] = 1
        end
      end
    end
    fixedMask[x] = fixedMaskX
  end

  -- Compute the triangles, expanded up to the outer margin, and populate a kd-tree with them.
  local tris = getTrianglesMulti(roads, box, margin + fixedMargin)
  local tree = populateTree(tris)

  -- Iterate over the grid bounding box, and add contributions to the road mask.
  for x = 0, xSize do
    local maskX, heightX = mask[x], height[x]
    local gX = bXMin + x
    for y = 0, ySize do
      local gY = bYMin + y
      local pWS = te:gridToWorldByPoint2I(Point2I(gX, gY), tb)
      for tIdx in tree:queryNotNested(pWS.x, pWS.y, pWS.x, pWS.y) do
        local z = intersectsUp_Triangle_Barycentric(pWS, tris[tIdx], tris[tIdx + 1], tris[tIdx + 2])
        --local tA, tB, tC = tri.a, tri.b, tri.c
        --local tCA = tC - tA
        --local tBC = tB - tC
        --local triNorm = tCA:cross(tBC)                                                                -- TODO: this stuff can be pre-cached and stored in tris, per triangle.
        --local sqTriNorm = triNorm:squaredLength()
        --local z = intersectsUp_Triangle(pWS, tCA, tBC, tC, triNorm, sqTriNorm)
        if z then
          heightX[y] = (maskX[y] == 0 and z - zOff) or min(z - zOff, heightX[y])
          maskX[y] = 1
        end
      end
    end
  end

  -- Create the mod structure.
  -- [A structure which stores the increasing domain of influence].
  local mod = {}
  local chMod = {}
  for x = 0, xSize do
    local maskX =  mask[x]
    mod[x], chMod[x] = {}, {}
    for y = 0, ySize do
      mod[x][y] = maskX[y]
      chMod[x][y] = maskX[y]
    end
  end

  -- Allocate the changes structure.
  local changes = {}
  for x = 0, xSize do
    changes[x] = {}
    local chCol = changes[x]
    for y = 0, ySize do
      chCol[y] = 0.0
    end
  end

  local numIter = ceil(0.5 * sqrt(8 * DOI + 1) - 1)

  -- Iteratively process the mask.
  for i = numIter, 1, -1 do
    local halfkernSizeL = i
    local kernSizeL = halfkernSizeL * 2 + 1
    local invI = 1 / kernSizeL
    local xStart, xEnd = halfkernSizeL + 1, xSize - halfkernSizeL - 1
    local yStart, yEnd = halfkernSizeL + 1, ySize - halfkernSizeL - 1

    -- X.
    for y = yStart, yEnd do
      local numerS, denomS = 0, 0
      for s = 1, kernSizeL do
        numerS, denomS = numerS + height[s][y], denomS + mod[s][y]
      end

      for x = xStart, xEnd do
        if denomS == 0 then
          changes[x][y] = height[x][y]
        else
          changes[x][y] = numerS * invI
          chMod[x][y] = 1
        end
        local frontEdge, backEdge = x + xStart, x - halfkernSizeL
        numerS = numerS + height[frontEdge][y] - height[backEdge][y]
        denomS = denomS + mod[frontEdge][y] - mod[backEdge][y]
      end
    end

    -- Y.
    for x = xStart, xEnd do
      local numerS, denomS = 0, 0
      local heightX, modX, chModX, chX = height[x], mod[x], chMod[x], changes[x]
      for s = 1, kernSizeL do
        numerS, denomS = numerS + heightX[s], denomS + modX[s]
      end

      for y = yStart, yEnd do
        if denomS ~= 0 then
          chX[y] = (chX[y] + numerS * invI) * 0.5
          chModX[y] = 1
        end
        local frontEdge, backEdge = y + xStart, y - halfkernSizeL
        numerS = numerS + heightX[frontEdge] - heightX[backEdge]
        denomS = denomS + modX[frontEdge] - modX[backEdge]
      end
    end

    -- Copy the changes onto the mask, reset the fixed mask points and reset the changes array.
    for x = xStart, xEnd do
      local maskX, heightX, modX, chModX, chX = mask[x], height[x], mod[x], chMod[x], changes[x]
      for y = yStart, yEnd do
        local m = maskX[y]
        heightX[y] = (1 - m) * chX[y] + m * heightX[y]
        modX[y] = chModX[y]
      end
    end
  end

  -- Average the height with neighbouring points.
  averageMask(height, mod, fixedMask, xSize, ySize)

  -- Terraform the heightmap from the processed mask.
  modifyTerrainFromHeightArray(height, mod, xSize, ySize, bXMin, bXMax, bYMin, bYMax, tb)
end

-- Saves the heightmap to the given .png file.
local function writeHeightmapToPng(path)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  if not tb or not te then
    return {}
  end
  local extents = tb:getWorldBox():getExtents()
  local center = tb:getWorldBox():getCenter()
  local xHalf, yHalf = extents.x * 0.5, extents.y * 0.5
  local tXMin, tXMax, tYMin, tYMax = center.x - xHalf, center.x + xHalf, center.y - xHalf, center.y + xHalf
  local xSize, ySize = tXMax - tXMin, tYMax - tYMin

  local bmp = GBitmap()
  bmp:init(xSize, ySize)
  bmp:allocateBitmap(xSize, ySize, false, "GFXFormatR16")
  for x = 0, xSize do
    for y = 0, ySize do
      local val = max(0, tb:getHeightGrid(x, y)) * uint16Scale
      bmp:setTexel(x, y, val, val, val, val)
    end
  end
  bmp:saveFile(path)
end

-- Imports a terrain from the given path.
local function setHeightmapFromPng(path)

  -- If there is no terrain block (eg smallgrid) then leave immediately.
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  if not tb or not te then
    return
  end
  local extents = tb:getWorldBox():getExtents()
  local center = tb:getWorldBox():getCenter()
  local xHalf, yHalf = extents.x * 0.5, extents.y * 0.5
  local tXMin, tXMax, tYMin, tYMax = center.x - xHalf, center.x + xHalf, center.y - xHalf, center.y + xHalf
  local xSize, ySize = tXMax - tXMin, tYMax - tYMin

  -- Load the terrain.
  local bmp = GBitmap()
  if not bmp:loadFile(path) then
    log('E', logTag, 'Failed to load heightmap (.png) file [from path: ' .. path .. ']')
  end

  -- Apply the bitmap to the heightmap.
  for x = 0, xSize do
    local rx = x + tXMin
    for y = 0, ySize do
      tb:setHeightGrid(x, y, max(0, bmp:getTexel(x, y) * uint16ScaleInv))
    end
  end

  -- Update the terrain block.
  local gMin, gMax = Point2I(0, 0), Point2I(0, 0)
  te:worldToGridByPoint2I(vec3(floor(tXMin), floor(tYMin)), gMin, tb)
  te:worldToGridByPoint2I(vec3(ceil(tXMax), ceil(tYMax)), gMax, tb)
  tb:updateGrid(vec3(gMin.x, gMin.y), vec3(gMax.x, gMax.y))
end


-- Public interface.
M.conformTerrainToRoad =                                  conformTerrainToRoad
M.terraformMultiRoads =                                   terraformMultiRoads

M.writeHeightmapToPng =                                   writeHeightmapToPng
M.setHeightmapFromPng =                                   setHeightmapFromPng

return M