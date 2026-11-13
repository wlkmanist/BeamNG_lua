-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This is a utility class for managing the painting of the terrain underneath a spline.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local defaultMaterialIdx = 1  -- The default index of the painting material, in the material table.
local margin = 2  -- The margin to add to the spline bounds, in meters.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local geom = require("editor/toolUtilities/geom")

-- Module constants.
local min, max, sqrt = math.min, math.max, math.sqrt

-- Module state.
local tmp1, tmp2, posWS = vec3(), vec3(), vec3()
local gMin, gMax, tmpPoint2I = Point2I(0, 0), Point2I(0, 0), Point2I(0, 0)
local leftPts, rightPts, polygon = {}, {}, {}
local spansXMin, spansXMax, spansY = {}, {}, {}
local setMask = {}


-- Builds the outer left/right footprint boundary (world XY, z=0) into leftPts/rightPts, pushed out by the paint margin.
-- MESH roads: trace the ACTUAL deck outer edge (group.meshEdgeL/R). That edge is the real tarmac -- it already bakes in curve
-- widening, one-sided placeable laybys / overtaking bays, banking and the end-cap extensions -- so the paint follows it exactly.
-- TERRAIN roads (no deck grid): fall back to the centreline + per-station width (engineered curve widening lives in divWidths).
local function buildFootprint(group)
  local pMargin = group.paintMargin or 0
  table.clear(leftPts)
  table.clear(rightPts)

  local eL, eR = group.meshEdgeL, group.meshEdgeR
  if group.isMesh ~= false and eL and eR and #eL >= 2 and #eR == #eL then
    -- Prefer the banked outward dir arrays when present (full mesh build). When the preview mesh is pinned OFF the road only
    -- has ribbon edges, which set meshEdgeL/R but NOT the dir arrays -- so derive the outward push per side from the L/R pair
    -- (edge point minus the lane midpoint). Either way the edge points already include the layby bulge, so paint tracks it.
    local dL, dR = group.meshEdgeDirL, group.meshEdgeDirR
    local haveDir = dL and dR and #dL == #eL and #dR == #eL
    for i = 1, #eL do
      local pl, pr = eL[i], eR[i]
      local ndlx, ndly, ndrx, ndry
      if haveDir then
        ndlx, ndly, ndrx, ndry = dL[i].x, dL[i].y, dR[i].x, dR[i].y
      else
        local mx, my = (pl.x + pr.x) * 0.5, (pl.y + pr.y) * 0.5
        ndlx, ndly = pl.x - mx, pl.y - my
        ndrx, ndry = pr.x - mx, pr.y - my
        local ll = sqrt(ndlx * ndlx + ndly * ndly); if ll > 1e-6 then ndlx, ndly = ndlx / ll, ndly / ll end
        local rl = sqrt(ndrx * ndrx + ndry * ndry); if rl > 1e-6 then ndrx, ndry = ndrx / rl, ndry / rl end
      end
      leftPts[i]  = vec3(pl.x + ndlx * pMargin, pl.y + ndly * pMargin, 0)
      rightPts[i] = vec3(pr.x + ndrx * pMargin, pr.y + ndry * pMargin, 0)
    end
    return
  end

  -- Fallback (terrain road / no deck edge): reconstruct from the centreline. Fixed carriageway half-widths are the BASE, and
  -- engineered curve widening is baked into divWidths, so recover it (over the base total, split both sides) and add it back.
  local divPoints, binormals, divWidths = group.divPoints, group.binormals, group.divWidths
  local fixedL, fixedR = group.leftExtM, group.rightExtM
  local baseTotal = (fixedL and fixedR) and (fixedL + fixedR) or nil
  for i = 1, #divPoints do
    local p, bin = divPoints[i], binormals[i]
    local binX, binY = bin.x, bin.y
    local widen = baseTotal and max(0, (divWidths[i] or baseTotal) - baseTotal) * 0.5 or 0
    local lExt = (fixedL and (fixedL + widen) or (divWidths[i] * 0.5)) + pMargin
    local rExt = (fixedR and (fixedR + widen) or (divWidths[i] * 0.5)) + pMargin
    leftPts[i]  = vec3(p.x - binX * lExt, p.y - binY * lExt, 0)
    rightPts[i] = vec3(p.x + binX * rExt, p.y + binY * rExt, 0)
  end
end

-- Paint one closed world-XY polygon in the given terrain material, recording what was there into `store` so it can be put
-- back. `skip`, if given, is asked about each point and leaves the ground it claims alone.
local function paintPolygon(store, poly, materialIdx, skip)
  if not store or #poly < 3 then return end
  if store.paintedDataVals and #store.paintedDataVals > 0 then return end

  local box = geom.getAABB(poly)
  box.xMin, box.xMax = box.xMin - margin, box.xMax + margin
  box.yMin, box.yMax = box.yMin - margin, box.yMax + margin

  -- Convert the AABB from world space to grid space.
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  if not (tb and te) then return end
  tmp1:set(box.xMin, box.yMin, 0) te:worldToGridByPoint2I(tmp1, gMin, tb)
  tmp1:set(box.xMax, box.yMax, 0) te:worldToGridByPoint2I(tmp1, gMax, tb)
  local gMinX, gMinY, gMaxX, gMaxY = gMin.x, gMin.y, gMax.x, gMax.y

  -- Get the scanline spans for the polygon.
  geom.getScanlineSpans(gMinY, gMaxY, te, tb, poly, spansXMin, spansXMax, spansY)

  -- Paint the scanline spans.
  table.clear(setMask)
  local paintMaterialIdx = materialIdx or defaultMaterialIdx
  local capEstimate = #spansY * (gMaxX - gMinX + 1)
  local xVals, yVals, prevVals = table.new(capEstimate, 0), table.new(capEstimate, 0), table.new(capEstimate, 0)
  local width = gMaxX - gMinX + 1
  local ctr = 1
  for i = 1, #spansY do
    local y = spansY[i]
    for x = spansXMin[i], spansXMax[i] do
      tmpPoint2I.x, tmpPoint2I.y = x, spansY[i]
      posWS:set(te:gridToWorldByPoint2I(tmpPoint2I, tb))
      local idx = (y - gMinY) * width + (x - gMinX) + 1 -- 2D -> 1D index used for the mask.
      if not setMask[idx] and not (skip and skip(posWS.x, posWS.y)) then -- Only write to a point once, to keep the history clean.
        prevVals[ctr] = tb:getMaterialIdxWs(posWS)
        tb:setMaterialIdxWs(posWS, paintMaterialIdx)
        xVals[ctr], yVals[ctr] = posWS.x, posWS.y
        ctr = ctr + 1
        setMask[idx] = true
      end
    end
  end

  -- Update the grid after changes.
  tmp1:set(gMinX, gMinY, 0)
  tmp2:set(gMaxX, gMaxY, 0)
  tb:updateGridMaterials(tmp1, tmp2)
  tb:updateGrid(tmp1, tmp2)

  -- Store the painted data, so it can be reverted later.
  store.paintedDataX = xVals
  store.paintedDataY = yVals
  store.paintedDataVals = prevVals
  store.paintedDataBoxXMin = gMinX
  store.paintedDataBoxXMax = gMaxX
  store.paintedDataBoxYMin = gMinY
  store.paintedDataBoxYMax = gMaxY
end

-- Paints the given spline: work its footprint out, then paint that. `runs` (optional, divPoint index pairs { i0, i1 }): only
-- those stretches of it, into the one record.
local function paint(group, runs)
  if #group.paintedDataVals > 0 or #group.nodes < 2 or #group.divPoints < 2 then
    return -- If no painted data or spline invalid, then leave immediately.
  end

  -- Build the footprint boundary first (tracks the real widened deck edge), then paint inside it.
  buildFootprint(group)
  if #leftPts < 2 then return end

  local X, Y, V = {}, {}, {}
  local bx0, bx1, by0, by1 = math.huge, -math.huge, math.huge, -math.huge
  for _, r in ipairs(runs or { { 1, #leftPts } }) do
    local a, b = r[1], min(r[2], #leftPts)
    if b > a then
      table.clear(polygon)
      for i = a, b do polygon[#polygon + 1] = leftPts[i] end
      for i = b, a, -1 do polygon[#polygon + 1] = rightPts[i] end
      local part = {}
      paintPolygon(part, polygon, group.paintMaterialIdx)
      local pv = part.paintedDataVals
      if pv and #pv > 0 then
        for i = 1, #pv do
          local n = #V + 1
          X[n], Y[n], V[n] = part.paintedDataX[i], part.paintedDataY[i], pv[i]
        end
        bx0, bx1 = min(bx0, part.paintedDataBoxXMin), max(bx1, part.paintedDataBoxXMax)
        by0, by1 = min(by0, part.paintedDataBoxYMin), max(by1, part.paintedDataBoxYMax)
      end
    end
  end
  if #V == 0 then return end
  group.paintedDataX, group.paintedDataY, group.paintedDataVals = X, Y, V
  group.paintedDataBoxXMin, group.paintedDataBoxXMax, group.paintedDataBoxYMin, group.paintedDataBoxYMax = bx0, bx1, by0, by1
end

-- Reverts the terrain under whatever was painted back to the state it had before.
local function revert(group)
  if not group.paintedDataVals or #group.paintedDataVals < 1 then
    return -- If no painted data, there is nothing to revert.
  end

  -- Restore the materials.
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  if not tb then return end
  local stateX, stateY, stateVals = group.paintedDataX, group.paintedDataY, group.paintedDataVals
  for i = #stateVals, 1, -1 do -- last first: a square painted twice gets back the material it had before the first
    tmp1:set(stateX[i], stateY[i], 0)
    tb:setMaterialIdxWs(tmp1, stateVals[i]) -- Restore the original material index (before painting).
  end

  -- Update the grid after changes.
  tmp1:set(group.paintedDataBoxXMin, group.paintedDataBoxYMin, 0)
  tmp2:set(group.paintedDataBoxXMax, group.paintedDataBoxYMax, 0)
  tb:updateGridMaterials(tmp1, tmp2)
  tb:updateGrid(tmp1, tmp2)

  -- Remove the painted data from the group.
  table.clear(group.paintedDataX)
  table.clear(group.paintedDataY)
  table.clear(group.paintedDataVals)
  group.paintedDataBoxXMin, group.paintedDataBoxXMax, group.paintedDataBoxYMin, group.paintedDataBoxYMax = 0, 0, 0, 0
end

-- Reverts all terrain painting for all groups.
local function revertAll(groups)
  for i = 1, #groups do
    revert(groups[i])
  end
end


-- Public interface.
M.paint =                                               paint
M.paintPolygon =                                        paintPolygon

M.revert =                                              revert
M.revertAll =                                           revertAll

return M