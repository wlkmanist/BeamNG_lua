-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Module constants.
local downShift = vec3(0, 0, 0.03)                                                                  -- The vertical offset when terraforming to the road top surface.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}


-- External modules used.
local kdTreeB2d = require('kdtreebox2d')
local roadMgr = require('editor/tech/roadArchitect/roads')                                          -- For managing the road structure/handling road calculations.

-- Private constants.
local min, max, floor, ceil = math.min, math.max, math.floor, math.ceil
local abs, sqrt = math.abs, math.sqrt
local negHuge = -math.huge

-- Module state.
local fullHistory = {}                                                                              -- An array containing the ordered history of terraforming operations.
local fullHistCtr = 1                                                                               -- A counter used with the ordered history array.


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
    tb:setHeight(d.x, d.y, d.old)
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
    tb:setHeight(d.x, d.y, d.new)
    xMin, xMax, yMin, yMax = min(xMin, d.x), max(xMax, d.x), min(yMin, d.y), max(yMax, d.y)
  end

  -- Update the grid after the changes.
  tb:updateGrid(vec3(xMin, yMin), vec3(xMax, yMax))
end

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

-- Determines if a given div point index is inside a tunnel or not.
local function isInTunnel(idx, tunnels, extraS, extraE)
  local numTunnels = #tunnels
  for i = 1, numTunnels do
    local t = tunnels[i]
    if t.s + extraS <= idx and idx <= t.e - extraE - 1 then
      return true
    end
  end
  return false
end

-- Function to perform morphological dilation.
local function dilateBool(matrix)
  local rows = #matrix
  local cols = #matrix[1]

  -- Create a copy of the input matrix to store the output.
  local output = {}
  for i = 0, rows do
      output[i] = {}
      for j = 0, cols do
          output[i][j] = matrix[i][j]
      end
  end

  -- Define the structuring element (8-connected neighborhood).
  local structuring_element = {
      {-1, -1}, {-1, 0}, {-1, 1},
      {0, -1},           {0, 1},
      {1, -1}, {1, 0}, {1, 1}
  }

  -- Perform dilation.
  for i = 0, rows do
      for j = 0, cols do
          if matrix[i][j] == 1 then
              for _, offset in ipairs(structuring_element) do
                  local ni = i + offset[1]
                  local nj = j + offset[2]
                  if ni >= 1 and ni <= rows and nj >= 1 and nj <= cols then
                      output[ni][nj] = 1
                  end
              end
          end
      end
  end

  return output
end

-- Function to perform morphological dilation on a floating-point matrix.
local function dilateFloat(matrix)
  local rows = #matrix
  local cols = #matrix[1]

  -- Initialize the output matrix with very low values (negative infinity).
  local output = {}
  for i = 0, rows do
      output[i] = {}
      for j = 0, cols do
          output[i][j] = negHuge
      end
  end

  -- Define the structuring element (8-connected neighborhood).
  local structuring_element = {
      {-1, -1}, {-1, 0}, {-1, 1},
      {0, -1},           {0, 1},
      {1, -1}, {1, 0}, {1, 1}
  }

  -- Perform dilation.
  for i = 0, rows do
      for j = 0, cols do
          local current_value = matrix[i][j]
          for _, offset in ipairs(structuring_element) do
              local ni = i + offset[1]
              local nj = j + offset[2]
              if ni >= 1 and ni <= rows and nj >= 1 and nj <= cols then
                  output[ni][nj] = max(output[ni][nj], current_value)
              end
          end
      end
  end

  return output
end

-- Conforms the local terrain to the road.
local function conformTerrainToRoad(rIdx, DOI)

 -- If there is no terrain block (eg smallgrid) then leave immediately.
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  if not tb or not te then
    return
  end

  -- Initialize the mask.
  local mask, height = {}, {}
  local box = roadMgr.computeAABB2D(rIdx)
  local gMin, gMax = Point2I(0, 0), Point2I(0, 0)
  te:worldToGridByPoint2I(vec3(floor(box.xMin - DOI), floor(box.yMin - DOI)), gMin, tb)
  te:worldToGridByPoint2I(vec3(ceil(box.xMax + DOI), ceil(box.yMax + DOI)), gMax, tb)
  local bXMin, bXMax, bYMin, bYMax = gMin.x, gMax.x, gMin.y, gMax.y
  local xSize, ySize = bXMax - bXMin, bYMax - bYMin
  for x = 0, xSize do
    local xPos = bXMin + x
    local innerM, innerH = {}, {}
    for y = 0, ySize do
      innerM[y], innerH[y] = 0, tb:getHeightGrid(xPos, bYMin + y)
    end
    mask[x], height[x] = innerM, innerH
  end

  -- Collect all bottom surface triangles from the road render data.
  local road = roadMgr.roads[rIdx]
  local tris, tCtr, rData, laneKeys = {}, 1, road.renderData, road.laneKeys
  local numDivs, numLaneKeys = #rData, #laneKeys
  for j = 2, numDivs do
    if not isInTunnel(j, road.tunnels, road.extraS[0], road.extraE[0]) then                         -- Do not include triangles inside tunnels.
      local div1, div2 = rData[j - 1], rData[j]
      for k = 1, numLaneKeys do
        local laneKey = laneKeys[k]
        local b, f = div1[laneKey], div2[laneKey]
        local f4, b3 = f[2] - downShift, b[1] - downShift
        tris[tCtr] = { a = f[1] - downShift, b = f4, c = b3 }
        tris[tCtr + 1] = { a = b[2] - downShift, b = f4, c = b3 }
        tCtr = tCtr + 2
      end
    end
  end

  -- Create and populate a kd-tree.
  local tree = kdTreeB2d.new(#tris)
  for i = 1, #tris do
    local t = tris[i]
    local tA, tB, tC = t.a, t.b, t.c
    local xMin, xMax = min(tA.x, min(tB.x, tC.x)), max(tA.x, max(tB.x, tC.x))
    local yMin, yMax = min(tA.y, min(tB.y, tC.y)), max(tA.y, max(tB.y, tC.y))
    tree:preLoad(i, xMin, yMin, xMax, yMax)
  end
  tree:build()

  -- Iterate over the grid bounding box, and add contributions to the road mask.
  local pWS = vec3(0, 0)
  for x = 0, xSize do
    local maskX, heightX = mask[x], height[x]
    local gX = bXMin + x
    for y = 0, ySize do
      local gY = bYMin + y
      local pWS_3F = te:gridToWorldByPoint2I(Point2I(gX, gY), tb)
      pWS:set(pWS_3F.x, pWS_3F.y, 0)

      for tIdx in tree:queryNotNested(pWS.x, pWS.y, pWS.x, pWS.y) do
        local tri = tris[tIdx]
        local tA, tB, tC = tri.a, tri.b, tri.c
        local tCA = tC - tA
        local tBC = tB - tC
        local triNorm = tCA:cross(tBC)                                                                -- TODO: this stuff can be pre-cached and stored in tris, per triangle.
        local sqTriNorm = triNorm:squaredLength()
        local z = intersectsUp_Triangle(pWS, tCA, tBC, tC, triNorm, sqTriNorm)
        if z then
          heightX[y] = (maskX[y] == 0 and z) or min(z, heightX[y])
          maskX[y] = 1
        end
      end
    end
  end

  -- Dilate the mask before performing terraforming.
  mask = dilateBool(mask)
  height = dilateFloat(height)

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

  -- Terraform the heightmap from the processed mask.
  local history, hCtr = {}, 1
  for x = 0, xSize do
    local heightX, modX, rx = height[x], mod[x], x + bXMin
    for y = 0, ySize do
      if modX[y] > 0.5 then
        local ry = y + bYMin
        local z = heightX[y]
        local zOld = tb:getHeightGrid(rx, ry)
        tb:setHeight(rx, ry, z)
        history[hCtr] = { old = zOld, new = z, x = rx, y = ry }
        hCtr = hCtr + 1
        fullHistory[fullHistCtr] = { x = rx, y = ry, z = z }
        fullHistCtr = fullHistCtr + 1
      end
    end
  end
  editor.history:commitAction("Terraform", history, terraformUndo, terraformRedo)

  -- Update the terrain block.
  tb:updateGrid(vec3(bXMin, bYMin), vec3(bXMax, bYMax))
end

-- Terraforms the whole terrain block to the existing road network.
local function terraformTB2Roads(DOIPixels)

  -- If there is no terrain block (eg smallgrid) then leave immediately.
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  if not tb or not te then
    return
  end

  -- Initialize the mask.
  local mask, height = {}, {}
  local box = roadMgr.computeAABB2DAllRoads()
  local gMin, gMax = Point2I(0, 0), Point2I(0, 0)
  te:worldToGridByPoint2I(vec3(floor(box.xMin - DOIPixels), floor(box.yMin - DOIPixels)), gMin, tb)
  te:worldToGridByPoint2I(vec3(ceil(box.xMax + DOIPixels), ceil(box.yMax + DOIPixels)), gMax, tb)
  local bXMin, bXMax, bYMin, bYMax = gMin.x, gMax.x, gMin.y, gMax.y
  local xSize, ySize = bXMax - bXMin, bYMax - bYMin
  for x = 0, xSize do
    local innerM, innerH = {}, {}
    for y = 0, ySize do
      innerM[y], innerH[y] = 0, 0
    end
    mask[x], height[x] = innerM, innerH
  end

  -- Set the bounding box perimeter to the current terrain heights there.
  local xULim, yULim = xSize - 1, ySize - 1
  for x = 1, xULim do
    local xPos = bXMin + x
    height[x][1] = tb:getHeightGrid(xPos, bYMin)
    height[x][yULim] = tb:getHeightGrid(xPos, bYMin + yULim)
    mask[x][1], mask[x][yULim] = 1, 1
  end
  for y = 1, yULim do
    local yPos = bYMin + y
    height[1][y] = tb:getHeightGrid(bXMin, yPos)
    height[xULim][y] = tb:getHeightGrid(bXMin + xULim, yPos)
    mask[1][y], mask[xULim][y] = 1, 1
  end

  -- Collect all bottom surface triangles from the road render data.
  local roads = roadMgr.roads
  local tris, tCtr = {}, 1
  for i = 1, #roads do
    local road = roadMgr.roads[i]
    if #road.nodes > 1 then
      local rData, laneKeys = road.renderData, road.laneKeys
      local numDivs, numLaneKeys = #rData, #laneKeys
      for j = 2, numDivs do
        if not isInTunnel(j, road.tunnels, road.extraS[0], road.extraE[0]) then                     -- Do not include triangles inside tunnels.
          local div1, div2 = rData[j - 1], rData[j]
          for k = 1, numLaneKeys do
            local laneKey = laneKeys[k]
            local b, f = div1[laneKey], div2[laneKey]
            local f4, b3 = f[2] - downShift, b[1] - downShift
            tris[tCtr] = { a = f[1] - downShift, b = f4, c = b3 }
            tris[tCtr + 1] = { a = b[2] - downShift, b = f4, c = b3 }
            tCtr = tCtr + 2
          end
        end
      end
    end
  end

  -- Create and populate a kd-tree.
  local tree = kdTreeB2d.new(#tris)
  for i = 1, #tris do
    local t = tris[i]
    local tA, tB, tC = t.a, t.b, t.c
    local xMin, xMax = min(tA.x, min(tB.x, tC.x)), max(tA.x, max(tB.x, tC.x))
    local yMin, yMax = min(tA.y, min(tB.y, tC.y)), max(tA.y, max(tB.y, tC.y))
    tree:preLoad(i, xMin, yMin, xMax, yMax)
  end
  tree:build()

  -- Iterate over the grid bounding box, and add contributions to the road mask.
  local pWS = vec3(0, 0)
  for x = 0, xSize do
    local maskX, heightX = mask[x], height[x]
    local gX = bXMin + x
    for y = 0, ySize do
      local gY = bYMin + y
      local pWS_3F = te:gridToWorldByPoint2I(Point2I(gX, gY), tb)
      pWS:set(pWS_3F.x, pWS_3F.y, 0)

      for tIdx in tree:queryNotNested(pWS.x, pWS.y, pWS.x, pWS.y) do
        local tri = tris[tIdx]
        local tA, tB, tC = tri.a, tri.b, tri.c
        local tCA = tC - tA
        local tBC = tB - tC
        local triNorm = tCA:cross(tBC)                                                                -- TODO: this stuff can be pre-cached and stored in tris, per triangle.
        local sqTriNorm = triNorm:squaredLength()
        local z = intersectsUp_Triangle(pWS, tCA, tBC, tC, triNorm, sqTriNorm)
        if z then
          heightX[y] = (maskX[y] == 0 and z) or min(z, heightX[max(0, y)])
          maskX[y] = 1
        end
      end
    end
  end

  -- Create the mod structure.
  -- [A structure which stores the increasing domain of influence].
  local mod = {}
  for x = 0, xSize do
    local inner, maskX = {}, mask[x]
    for y = 0, ySize do
      inner[y] = maskX[y]
    end
    mod[x] = inner
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

  local numIter = ceil(0.5 * sqrt(8 * DOIPixels + 1) - 1)
  local invI = {[0]=0}
  for i = 1, numIter * 2 + 1 do
    invI[i] = 1 / i
  end

  -- Iteratively process the mask.
  for i = numIter, 1, -1 do
    local halfkernSizeL = i
    local kernSizeL = halfkernSizeL * 2 + 1
    local xStart, xEnd = halfkernSizeL + 1, xSize - halfkernSizeL - 1
    local yStart, yEnd = halfkernSizeL + 1, ySize - halfkernSizeL - 1

    -- X.
    for y = yStart, yEnd do
      local numerS, denomS = 0, 0
      for s = 1, kernSizeL do
        local m = mod[s][y]
        numerS, denomS = numerS + m * height[s][y], denomS + m
      end

      for x = xStart, xEnd do
        changes[x][y] = numerS * invI[denomS]
        local frontEdge, backEdge = x + xStart, x - halfkernSizeL
        local mF, mB = mod[frontEdge][y], mod[backEdge][y]
        numerS = numerS + mF * height[frontEdge][y] - mB * height[backEdge][y]
        denomS = denomS + mF - mB
      end
    end

    -- Y.
    for x = xStart, xEnd do
      local numerS, denomS = 0, 0
      local heightX, modX, chX = height[x], mod[x], changes[x]
      for s = 1, kernSizeL do
        local m = modX[s]
        numerS, denomS = numerS + m * heightX[s], denomS + m
      end

      for y = yStart, yEnd do
        local numY = numerS * invI[denomS]
        chX[y] = (chX[y] + numY) / max(1, sign(abs(chX[y])) + sign(abs(numY)))
        local frontEdge, backEdge = y + xStart, y - halfkernSizeL
        local mF, mB = modX[frontEdge], modX[backEdge]
        numerS = numerS + mF * heightX[frontEdge] - mB * heightX[backEdge]
        denomS = denomS + mF - mB
      end
    end

    -- Copy the changes onto the mask, reset the fixed mask points and reset the changes array.
    for x = xStart, xEnd do
      local maskX, heightX, modX, chX = mask[x], height[x], mod[x], changes[x]
      for y = yStart, yEnd do
        local m = maskX[y]
        heightX[y] = (1 - m) * chX[y] + m * heightX[y]
        modX[y] = min(1, modX[y] + sign(abs(chX[y])))
      end
    end
  end

  -- Terraform the heightmap from the processed mask.
  local history, hCtr = {}, 1
  for x = 0, xSize do
    local heightX, modX, rx = height[x], mod[x], x + bXMin
    for y = 0, ySize do
      if modX[y] > 0.5 then
        local ry = y + bYMin
        local z = heightX[y]
        local zOld = tb:getHeightGrid(rx, ry)
        tb:setHeight(rx, ry, z)
        history[hCtr] = { old = zOld, new = z, x = rx, y = ry }
        hCtr = hCtr + 1
        fullHistory[fullHistCtr] = { x = rx, y = ry, z = z }
        fullHistCtr = fullHistCtr + 1
      end
    end
  end
  editor.history:commitAction("Terraform", history, terraformUndo, terraformRedo)

  -- Update the terrain block.
  tb:updateGrid(vec3(bXMin, bYMin), vec3(bXMax, bYMax))
end

-- Applies an ordered array of terraforming operations to the terrain.
-- [This will be the history from a previous session, which the user wishes to recover].
local function applyHistoryOnLoad(h)

  -- If there is no terrain block (eg smallgrid) then leave immediately.
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  if not tb then
    return
  end

  -- Reset the module history array.
  table.clear(fullHistory)
  fullHistCtr = 1

  -- Apply the history, in order.
  local numOps = #h
  local xMin, xMax, yMin, yMax = 1e99, -1e99, 1e99, -1e99
  for i = 1, numOps do
    local op = h[i]
    local x, y = op.x, op.y
    xMin, xMax, yMin, yMax = min(xMin, x), max(xMax, x), min(yMin, y), max(yMax, y)
    tb:setHeight(x, y, op.z)                                                                        -- Terraform the terrain at the stored position.
    fullHistory[fullHistCtr] = { x = op.x, y = op.y, z = op.z }                                     -- Also re-populate the module history array.
    fullHistCtr = fullHistCtr + 1
  end

  -- Update the grid after the changes.
  tb:updateGrid(vec3(xMin, yMin), vec3(xMax, yMax))
end


-- Public interface.
M.history =                                               fullHistory

M.conformTerrainToRoad =                                  conformTerrainToRoad
M.terraformTB2Roads =                                     terraformTB2Roads
M.applyHistoryOnLoad =                                    applyHistoryOnLoad

return M