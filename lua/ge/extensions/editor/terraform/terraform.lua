-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local doiMultFactor = 2.5 -- The multiplier for the AABB margin.

local relaxSweepsPerStep = 14 -- Laplacian sweeps per unit of the 'smooth' slider (feathering relaxation; see relaxFeathering).
local relaxSweepsMax = 400 -- Cap on total relaxation sweeps (a big DOI band is fully smooth well before this; keeps a button press snappy).
local relaxOmega = 1.7 -- Successive over-relaxation factor for relaxFeathering (1 = plain Gauss-Seidel, must stay under 2).
local targetSweeps = 24 -- Relaxation sweeps over the blend target before it is written (see smoothTarget).
local spillBatterSlope = 1 / 1.5 -- Steepest the ground falls away from a held surface where a spill holds it down (1:1.5).
local smoothPasses = 5 -- Default blur iterations over the transition apron (callers may override).

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- External modules.
local ffi = require('ffi')
local geom = require('editor/toolUtilities/geom')
local perlin = require('editor/toolUtilities/perlin') -- Currently unused, since simplex is preferred.
local noise = require('editor/toolUtilities/noise')
local util = require('editor/toolUtilities/util')
local scatter = require('editor/toolUtilities/foliageScatter')

-- Module constants.
local im = ui_imgui
local min, max, floor, ceil = math.min, math.max, math.floor, math.ceil
local sqrt, huge, abs = math.sqrt, math.huge, math.abs
local MASK_STRIDE = 131072
local touchedEps = 1e-3 -- A baseline cell whose height moved more than this since the carve wrote it was edited since: revert skips it.

-- How far past a footprint's edge the ground is held: the half-cell skin it is stamped with, and the one-cell ring round that.
local function heldReach(squareSize) return (0.5 + sqrt(2)) * squareSize end

-- Module state.
local final, mod, mask, height = {}, {}, {}, {}
local cone = {} -- spill floor: the highest spill-slope cone off any held cell (see spillCones)
local clip = {} -- 1 = cell past a clipped road end (terraformToSources `clips`): left at natural ground.
-- Per-cell scratch for finishTerraform, grown to the largest window seen.
local cellCap, lineCap = 0, 0
local colD2, colNy, dist2, near, tgt, fin, free -- per window cell
local envV, envZ -- per row
local cH, cM, cP, fH, fM, fP = {}, {}, {}, {}, {}, {}
local dH, dM, dP = {}, {}, {} -- 'cut' (lower-only) accumulators: bridge under-deck clearance shave.
local cI, fI, dI = {}, {}, {}
local cD, fD, dD = {}, {}, {}
local kH, kM = {}, {} -- 'ceil' accumulators: the lowest height a cell may end at (a deck above it), applied after the blend.
local lH, lM = {}, {} -- 'floor' accumulators: the highest height a cell must reach (cover over a tunnel), applied after the blend.
local rH = {} -- held cells a 'fill' raised (cover over a tunnel): the blend off them, and their ring, never lower the ground.
local sH, sM = {}, {} -- 'spill' accumulators: the highest a blended cell may end at, never under its own ground (see stampQuad).
local prioArr = {} -- Winning footprint priority per window vertex (set in the merge; used by the 1-ring dilation).
local ringCand = {} -- 1-ring candidates per cell, by band: { z, d2 } of the nearest carve edge just outside a footprint (see stampQuad).
local gMin, gMax, tmpPoint2I = Point2I(0, 0), Point2I(0, 0), Point2I(0, 0)
local tmp1, tmp2, tmpWS = vec3(), vec3(), vec3()
local occZ, occPrio = {}, {}
-- RIM, a sunk square's strip past its wall: over the paving, under every road band, so a road's edge ring always holds.
local PRIO = { LAKE = 1, CARPARK = 1.5, OPENSPACE = 1.75, BUILDING = 2, PAVING = 2.5, PATH = 3, STRUCTURE = 4, RIM = 4.2,
               AREAWAY = 4.3, GROUND = 5, RAIL = 5.5 }
local baseHeights = nil    -- ffi double[(w+1)*(h+1)]: raw grid heights at snapshot time
local baseW, baseH = 0, 0
local baseOccZ, baseOccPrio = nil, nil
-- Set for the ONE write that follows, by carvePad: the heights go in and nothing else does. Consumed where it is read, so
-- it cannot leak into the next caller's pass.
local quietOnce = false
-- And by a caller that files the undo step for its pass itself (`baselineOut.ownStep`): the level is marked edited, but
-- no step is filed here.
local unfiledOnce = false


local function resetMask()
  table.clear(occZ); table.clear(occPrio)
end

-- The last valid grid index per axis. The block holds one sample per cell, not one more: its far edge is index N, which the
-- engine wraps round to 0, so a write there lands on the opposite edge of the map.
local function gridDims(tb)
  local ext, sq = tb:getWorldBox():getExtents(), tb:getSquareSize()
  return floor(ext.x / sq + 0.5) - 1, floor(ext.y / sq + 0.5) - 1
end

-- Every height write ends here: the grid refreshed over the cells tmp1..tmp2, and the plants standing on them set back on
-- the ground they now find.
local function updateGrid(tb)
  tb:updateGrid(tmp1, tmp2)
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  if not te then return end
  tmpPoint2I.x, tmpPoint2I.y = tmp1.x, tmp1.y
  local a = te:gridToWorldByPoint2I(tmpPoint2I, tb)
  local ax, ay = a.x, a.y
  tmpPoint2I.x, tmpPoint2I.y = tmp2.x, tmp2.y
  local b = te:gridToWorldByPoint2I(tmpPoint2I, tb)
  local sq = tb:getSquareSize()
  scatter.redrape(ax - sq, ay - sq, b.x + sq, b.y + sq)
end

local function snapshotBaseline()
  local tb = extensions.editor_terrainEditor and extensions.editor_terrainEditor.getTerrainBlock()
  if not tb then return end
  baseW, baseH = gridDims(tb)
  local stride = baseW + 1
  baseHeights = ffi.new('double[?]', stride * (baseH + 1))
  for x = 0, baseW do
    for y = 0, baseH do
      baseHeights[y * stride + x] = tb:getHeightGrid(x, y)
    end
  end
  -- Mask snapshot = the post-water state (lake claims only; the network hasn't stamped yet).
  baseOccZ, baseOccPrio = {}, {}
  for k, v in pairs(occZ) do baseOccZ[k] = v end
  for k, v in pairs(occPrio) do baseOccPrio[k] = v end
end

local function restoreBaseline()
  local tb = extensions.editor_terrainEditor and extensions.editor_terrainEditor.getTerrainBlock()
  if not tb or not baseHeights then return end
  local stride = baseW + 1
  local xMin, yMin, xMax, yMax = huge, huge, -huge, -huge
  for x = 0, baseW do
    for y = 0, baseH do
      local z = baseHeights[y * stride + x]
      if tb:getHeightGrid(x, y) ~= z then -- only rewrite cells a pass actually moved
        tb:setHeightGrid(x, y, max(0, z))
        if x < xMin then xMin = x end; if x > xMax then xMax = x end
        if y < yMin then yMin = y end; if y > yMax then yMax = y end
      end
    end
  end
  if xMin <= xMax then
    tmp1:set(xMin, yMin, 0); tmp2:set(xMax, yMax, 0)
    updateGrid(tb)
  end
  -- Roll the occupancy mask back to the post-water state so the network re-stamps clean (a reclassified bridge
  -- is no longer blocked by its own pass-1 ground claim).
  table.clear(occZ); table.clear(occPrio)
  if baseOccZ then for k, v in pairs(baseOccZ) do occZ[k] = v end end
  if baseOccPrio then for k, v in pairs(baseOccPrio) do occPrio[k] = v end end
end

-- Priority band owning a terrain cell in the persistent occupancy mask (absolute grid coords).
local function cellPriorityAt(gx, gy)
  return occPrio[gx * MASK_STRIDE + gy] or 0
end

-- Combine one footprint claim into an accumulator. d2: a skin claim's squared distance to its surface (0 inside).
local function combine(H, M, P, I, D, idx, z, prio, lower, interior, d2)
  if M[idx] == 0 then
    H[idx] = z; M[idx] = 1; P[idx] = prio; I[idx] = interior; D[idx] = d2
  elseif prio > P[idx] then
    H[idx] = z; P[idx] = prio; I[idx] = interior; D[idx] = d2
  elseif prio == P[idx] then
    -- Interior beats skin.
    if interior and not I[idx] then
      H[idx] = z; I[idx] = true -- interior supersedes the earlier skin claim outright
    elseif I[idx] and not interior then
      -- skin claim on a cell an interior stamp already owns: ignore
    elseif interior then
      if lower then
        if z < H[idx] then H[idx] = z end
      elseif z > H[idx] then H[idx] = z end
    elseif d2 < D[idx] then
      -- Skins take the nearest surface: a short ribbon segment's end edge passes by too, at its own height up or down the grade.
      H[idx] = z; D[idx] = d2
    end
  end
end

-- A cell just outside a carve footprint: each band's nearest edge height there, for the 1-ring to take.
local function ringCandidate(idx, z, prio, d2)
  local c = ringCand[idx]
  if not c then c = {}; ringCand[idx] = c end
  local e = c[prio]
  if not e then c[prio] = { z, d2 } elseif d2 < e[2] then e[1], e[2] = z, d2 end
end

local function accumulate(idx, z, mode, prio, interior, d2)
  d2 = d2 or 0
  if mode == 'fill' then
    combine(fH, fM, fP, fI, fD, idx, z, prio, false, interior, d2)
  elseif mode == 'cut' then
    combine(dH, dM, dP, dI, dD, idx, z, prio, true, interior, d2)
  elseif mode == 'ceil' then
    if interior and (kM[idx] == 0 or z < kH[idx]) then kH[idx] = z; kM[idx] = 1 end
  elseif mode == 'floor' then
    if interior and (lM[idx] == 0 or z > lH[idx]) then lH[idx] = z; lM[idx] = 1 end
  elseif mode == 'spill' then
    if interior and (sM[idx] == 0 or z < sH[idx]) then sH[idx] = z; sM[idx] = 1 end
  else
    combine(cH, cM, cP, cI, cD, idx, z, prio, true, interior, d2)
  end
end

-- Closest point on segment a->b to p (2D): parameter t in [0, 1] and the squared distance to it.
local function segClosest2D(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local len2 = dx * dx + dy * dy
  local t = 0
  if len2 > 1e-12 then
    t = ((px - ax) * dx + (py - ay) * dy) / len2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
  end
  local ox, oy = px - (ax + dx * t), py - (ay + dy * t)
  return t, ox * ox + oy * oy
end

-- Nearest point on a quad's boundary to p, as (u, v) plus the squared distance.
local function quadNearestUV(px, py, q1, q2, q3, q4)
  local t, d2 = segClosest2D(px, py, q1.x, q1.y, q2.x, q2.y)
  local bu, bv, bd2 = t, 0, d2
  t, d2 = segClosest2D(px, py, q3.x, q3.y, q4.x, q4.y)
  if d2 < bd2 then bu, bv, bd2 = t, 1, d2 end
  t, d2 = segClosest2D(px, py, q1.x, q1.y, q3.x, q3.y)
  if d2 < bd2 then bu, bv, bd2 = 0, t, d2 end
  t, d2 = segClosest2D(px, py, q2.x, q2.y, q4.x, q4.y)
  if d2 < bd2 then bu, bv, bd2 = 1, t, d2 end
  return bu, bv, bd2
end

-- A terraform undo step: the cells it moved, in flat blocks rather than a table per cell. A grade moves millions of cells,
-- and every table a step holds is walked by each garbage collection for as long as the step is on the stack.
local function newStep(n)
  return { n = 0, x = ffi.new('int32_t[?]', n), y = ffi.new('int32_t[?]', n),
           old = ffi.new('double[?]', n), new = ffi.new('double[?]', n) }
end

local function stepAdd(s, x, y, old, new)
  local i = s.n
  s.x[i], s.y[i], s.old[i], s.new[i] = x, y, old, new
  s.n = i + 1
end

-- Writes one side of a step ('old' or 'new') back into the terrain.
local function writeStep(s, side)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  if not tb or s.n < 1 then return end

  local xs, ys, zs = s.x, s.y, s[side]
  local xMin, xMax, yMin, yMax = huge, -huge, huge, -huge
  for i = 0, s.n - 1 do
    local dx, dy = xs[i], ys[i]
    tb:setHeight(dx, dy, max(0.0, zs[i]))
    xMin, xMax = min(xMin, dx), max(xMax, dx)
    yMin, yMax = min(yMin, dy), max(yMax, dy)
  end
  tmp1:set(xMin, yMin, 0)
  tmp2:set(xMax, yMax, 0)
  updateGrid(tb)
end

-- Undo callback for terraforming operations.
local function terraformUndo(data) writeStep(data, 'old') end

-- Redo callback for terraforming operations.
local function terraformRedo(data) writeStep(data, 'new') end

-- Terraforms the heightmap using the given terraforming data.
-- [Also commits the modification to support undo/redo].
local function modifyTerrainFromHeightArray(xSize, ySize, bXMin, bXMax, bYMin, bYMax, tb)
  local quiet, filed = quietOnce, not (quietOnce or unfiledOnce)
  quietOnce, unfiledOnce = false, false
  local step
  if filed then
    local n = 0
    for idx = 0, xSize * ySize - 1 do
      if mod[idx] > 0.5 then n = n + 1 end
    end
    step = newStep(n)
  end
  for x = 0, xSize - 1 do
    local rx = x + bXMin
    for y = 0, ySize - 1 do
      local idx = y * xSize + x
      if mod[idx] > 0.5 then
        local ry = y + bYMin
        local z = final[idx]
        if step then stepAdd(step, rx, ry, max(0, tb:getHeightGrid(rx, ry)), z) end
        tb:setHeightGrid(rx, ry, max(0, z))
      end
    end
  end

  -- Update the terrain block.
  tmp1:set(bXMin, bYMin, 0)
  tmp2:set(bXMax, bYMax, 0)
  updateGrid(tb)
  -- A scratch pad is not an edit to the map: no dirty flag asking for the level to be saved, and nothing on the undo stack
  -- for Ctrl+Z to take back out from under the tool that put it there.
  if quiet then return end
  editor_terrainEditor.setTerrainDirty()

  -- Commit the terraforming action to the undo/redo history.
  if step and step.n > 0 then
    util.commitStep("Terraform", step, terraformUndo, terraformRedo)
  end
end

local function ensureScratch(n, longest)
  if n > cellCap then
    cellCap = n
    colD2, dist2, tgt, fin = ffi.new('double[?]', n), ffi.new('double[?]', n), ffi.new('double[?]', n), ffi.new('double[?]', n)
    colNy, near, free = ffi.new('int32_t[?]', n), ffi.new('int32_t[?]', n), ffi.new('uint8_t[?]', n)
  end
  if longest > lineCap then
    lineCap = longest
    envV, envZ = ffi.new('int32_t[?]', longest), ffi.new('double[?]', longest + 1)
  end
end

-- Exact squared distance (cells) from every window cell to the nearest held (mask) cell, and that cell's index (-1 when
-- the window holds none): the nearest held row down each column, then the lower envelope of the parabolas it gives along
-- each row (Felzenszwalb and Huttenlocher).
local function distanceField(xSize, ySize)
  for x = 0, xSize - 1 do
    local last = -1
    for y = 0, ySize - 1 do
      local idx = y * xSize + x
      if mask[idx] == 1 then last = y end
      colNy[idx] = last
    end
    last = -1
    for y = ySize - 1, 0, -1 do
      local idx = y * xSize + x
      if mask[idx] == 1 then last = y end
      local best = colNy[idx]
      if last >= 0 and (best < 0 or last - y < y - best) then best = last end
      colNy[idx] = best
      colD2[idx] = best >= 0 and (y - best) * (y - best) or huge
    end
  end
  for y = 0, ySize - 1 do
    local row = y * xSize
    local k = -1
    for q = 0, xSize - 1 do
      local fq = colD2[row + q]
      if fq < huge then
        local s = -huge
        while k >= 0 do
          local v = envV[k]
          s = (fq + q * q - colD2[row + v] - v * v) / (2 * (q - v))
          if s > envZ[k] then break end
          k = k - 1
        end
        k = k + 1
        envV[k], envZ[k] = q, s
      end
    end
    local j = 0
    for q = 0, xSize - 1 do
      local idx = row + q
      if k < 0 then
        dist2[idx], near[idx] = huge, -1
      else
        while j < k and envZ[j + 1] < q do j = j + 1 end
        local v = envV[j]
        dist2[idx] = (q - v) * (q - v) + colD2[row + v]
        near[idx] = colNy[row + v] * xSize + v
      end
    end
  end
end

-- The height each band cell grades toward (into `tgt`), made continuous.
-- The nearest held height alone is a Voronoi partition: it jumps by the whole height difference along the seam between
-- two held surfaces at different levels, as a plaza edge and the foot of a flight cut into it are. The falloff weight is
-- smooth across that seam, so the written ground would not be. Relaxing the target against the held cells turns the jump
-- into a grade before any of it is written. Cells past reach are left out of the average rather than pinned to natural
-- ground, so the band's outer edge stays free and the falloff keeps the shape the caller asked for.
local function smoothTarget(xSize, ySize, reach2)
  for i = 0, xSize * ySize - 1 do
    local nr = near[i]
    tgt[i] = nr >= 0 and height[nr] or height[i]
  end
  for _ = 1, targetSweeps do
    for y = 0, ySize - 1 do
      local row = y * xSize
      for x = 0, xSize - 1 do
        local idx = row + x
        if free[idx] > 0 then
          local sum, count = 0.0, 0
          if x > 0 and dist2[idx - 1] <= reach2 then sum = sum + tgt[idx - 1]; count = count + 1 end
          if x < xSize - 1 and dist2[idx + 1] <= reach2 then sum = sum + tgt[idx + 1]; count = count + 1 end
          if y > 0 and dist2[idx - xSize] <= reach2 then sum = sum + tgt[idx - xSize]; count = count + 1 end
          if y < ySize - 1 and dist2[idx + xSize] <= reach2 then sum = sum + tgt[idx + xSize]; count = count + 1 end
          if count > 0 then tgt[idx] = tgt[idx] + relaxOmega * (sum / count - tgt[idx]) end
        end
      end
    end
  end
end

-- Relax the DOI feathering (in `fin`) into a smooth grade between the fixed road edge and the fixed natural terrain.
-- Held, read but never moved: the road and its 1-ring, the flat margin apron the batter rests on, and everything the
-- blend did not reach. Only cells marked 2 in `free` move.
local function relaxFeathering(xSize, ySize, sweeps)
  for _ = 1, sweeps do
    for y = 0, ySize - 1 do
      local row = y * xSize
      for x = 0, xSize - 1 do
        local idx = row + x
        if free[idx] == 2 then
          local sum, count = 0.0, 0
          if x > 0 then sum = sum + fin[idx - 1]; count = count + 1 end
          if x < xSize - 1 then sum = sum + fin[idx + 1]; count = count + 1 end
          if y > 0 then sum = sum + fin[idx - xSize]; count = count + 1 end
          if y < ySize - 1 then sum = sum + fin[idx + xSize]; count = count + 1 end
          -- Over-relaxed: plain averaging is Gauss-Seidel, which needs on the order of (band width in cells) squared
          -- sweeps to actually converge, so a wide DOI came out damped rather than smooth. omega < 2 stays stable.
          fin[idx] = fin[idx] + relaxOmega * (sum / count - fin[idx])
        end
      end
    end
  end
end

-- The highest of the cones falling `step` per cell from every held cell (a chamfer sweep each way): the lowest a spill may
-- hold the ground down to without cutting a step into it.
local function spillCones(xSize, ySize, step)
  local diag = step * sqrt(2)
  for i = 0, xSize * ySize - 1 do cone[i] = mask[i] == 1 and height[i] or -huge end
  for y = 0, ySize - 1 do
    for x = 0, xSize - 1 do
      local idx = y * xSize + x
      local c = cone[idx]
      if x > 0 then c = max(c, cone[idx - 1] - step) end
      if y > 0 then
        c = max(c, cone[idx - xSize] - step)
        if x > 0 then c = max(c, cone[idx - xSize - 1] - diag) end
        if x < xSize - 1 then c = max(c, cone[idx - xSize + 1] - diag) end
      end
      cone[idx] = c
    end
  end
  for y = ySize - 1, 0, -1 do
    for x = xSize - 1, 0, -1 do
      local idx = y * xSize + x
      local c = cone[idx]
      if x < xSize - 1 then c = max(c, cone[idx + 1] - step) end
      if y < ySize - 1 then
        c = max(c, cone[idx + xSize] - step)
        if x < xSize - 1 then c = max(c, cone[idx + xSize + 1] - diag) end
        if x > 0 then c = max(c, cone[idx + xSize - 1] - diag) end
      end
      cone[idx] = c
    end
  end
end

-- Falloff weight (1 at the road edge -> 0 at the DOI) as a smoothstep.
local function meltWeight(eff, DOIInv, falloffExp)
  local base = 1.0 - eff * DOIInv
  if base <= 0.0 then return 0.0 elseif base >= 1.0 then return 1.0 end
  base = base ^ falloffExp -- pre-warp the normalized distance (falloff slider); a no-op at 1.
  return base * base * (3.0 - 2.0 * base)
end

-- Shared tail for all terraform entry points.
-- World XY of a window's first cell, and the grid step: a cell's world point is this plus its index times the step.
local function windowOrigin(te, tb, bXMin, bYMin)
  tmpPoint2I.x, tmpPoint2I.y = bXMin, bYMin
  local p = te:gridToWorldByPoint2I(tmpPoint2I, tb)
  return p.x, p.y, tb:getSquareSize()
end

-- Shared tail for all terraform entry points. Held (mask) cells keep their height. A cell within reach of one blends from
-- its own ground toward the relaxed target (see smoothTarget) by the falloff weight on its distance past the apron, and
-- the batter past the apron is then relaxed `passes` worth (see relaxFeathering).
local function finishTerraform(DOI, falloffExp, roughness, scale, xSize, ySize, bXMin, bXMax, bYMin, bYMax, tb, te, apronCells, passes, protect, useClip, useCeil)
  apronCells = apronCells or 0
  local nPasses = passes or smoothPasses
  local reach = DOI + apronCells
  local reach2, apron2 = reach * reach, apronCells * apronCells
  local DOIInv = 1.0 / DOI
  local n = xSize * ySize

  ensureScratch(n, max(xSize, ySize))
  distanceField(xSize, ySize)
  -- free: 0 held or out of reach, 1 band cell whose target relaxes, 2 one that also feathers (blended, past the apron).
  for idx = 0, n - 1 do
    local d2 = dist2[idx]
    if mask[idx] == 1 or d2 > reach2 then free[idx] = 0
    elseif d2 > apron2 and not (useClip and clip[idx] == 1) then free[idx] = 2
    else free[idx] = 1 end
  end
  smoothTarget(xSize, ySize, reach2)

  -- Every cell not held already carries its own ground in `height` (the callers' seeding).
  for idx = 0, n - 1 do
    local o = height[idx]
    if mask[idx] == 1 then
      fin[idx] = o
      mod[idx] = 1
    elseif free[idx] > 0 and not (useClip and clip[idx] == 1) then
      fin[idx] = o + (tgt[idx] - o) * meltWeight(max(0, sqrt(dist2[idx]) - apronCells), DOIInv, falloffExp)
      mod[idx] = 1
    else
      fin[idx] = o
    end
  end

  -- Apply noise, if requested.
  if roughness > 0 then
    local noiseFreq, noiseStrength, fbmOctaves, fbmLacunarity, fbmGain = noise.mapNoiseParameters(roughness, scale)
    local ox, oy, sq = windowOrigin(te, tb, bXMin, bYMin)
    for idx = 0, n - 1 do
      -- Roughen the transition apron, never the authoritative surface (roads stay flat).
      if mod[idx] == 1 and mask[idx] ~= 1 then
        local x = idx % xSize
        local y = (idx - x) / xSize
        local nz = noise.fbm((ox + x * sq) * noiseFreq, (oy + y * sq) * noiseFreq, fbmOctaves, fbmLacunarity, fbmGain)
        local eff = max(0, sqrt(dist2[idx]) - apronCells)
        fin[idx] = fin[idx] + nz * noiseStrength * meltWeight(eff, DOIInv, falloffExp)
      end
    end
  end

  if nPasses > 0 then relaxFeathering(xSize, ySize, min(relaxSweepsMax, nPasses * relaxSweepsPerStep)) end
  table.clear(final)
  for idx = 0, n - 1 do final[idx] = fin[idx] end

  -- Spills, floors, then ceilings, over the finished blend and smoothing: no blend runs on up past a spill (a held surface
  -- is not a blend), nothing a floor holds up can be blended back down into a tunnel, and nothing a ceiling holds down can
  -- be raised back into a deck. A spill never holds the ground under a spill slope falling from any held surface, so it
  -- cannot cut a step into the ground beside a road.
  if useCeil then
    spillCones(xSize, ySize, spillBatterSlope * tb:getSquareSize())
    for idx = 0, xSize * ySize - 1 do
      if mask[idx] ~= 1 and near[idx] >= 0 and rH[near[idx]] and final[idx] < height[idx] then final[idx] = height[idx] end
      if sM[idx] == 1 and mask[idx] ~= 1 then
        local cap = max(sH[idx], cone[idx])
        if final[idx] > cap then final[idx] = cap; mod[idx] = 1 end
      end
      if lM[idx] == 1 and final[idx] < lH[idx] then final[idx] = lH[idx]; mod[idx] = 1 end
      if kM[idx] == 1 and final[idx] > kH[idx] then final[idx] = kH[idx]; mod[idx] = 1 end
    end
  end

  -- Drop protected cells from the write set (leave them at their original height). Only the world XY of
  -- already-modified cells is tested, so the cost is confined to the touched window.
  if protect then
    local ox, oy, sq = windowOrigin(te, tb, bXMin, bYMin)
    for x = 0, xSize - 1 do
      for y = 0, ySize - 1 do
        local idx = y * xSize + x
        if mod[idx] > 0.5 and protect(ox + x * sq, oy + y * sq) then mod[idx] = 0 end
      end
    end
  end

  -- Set the final changes in the terrain and manage undo/redo history.
  modifyTerrainFromHeightArray(xSize, ySize, bXMin, bXMax, bYMin, bYMax, tb)
end

-- True if (px, py) lies past any clipped road end: in front of its end plane and within `reachM` (+ the road half-width) of it.
-- Each clip is { x, y, dx, dy, hw }: end-centre, unit outward direction (XY), road half-width (m).
local function beyondClippedEnd(px, py, clips, reachM)
  for i = 1, #clips do
    local c = clips[i]
    local rx, ry = px - c.x, py - c.y
    if rx * c.dx + ry * c.dy > 0 then
      local r = reachM + c.hw
      if rx * rx + ry * ry < r * r then return true end
    end
  end
  return false
end

-- Terraform heightmap based on quad weights and an SDF falloff.
-- `clips` (optional): road ends whose falloff must not spill forward (see beyondClippedEnd); the road deck itself is still held.
local function terraformToSources(DOI, margin, falloffExp, roughness, scale, sources, smoothPasses, baselineOut, clips)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  if not sources or not tb or not te then
    return -- Early return if no sources, terrain block, or terrain editor.
  end

  -- Get the terrain block's world box.
  local extents = tb:getWorldBox():getExtents()
  local center = tb:getWorldBox():getCenter()
  local centerX, centerY = center.x, center.y
  local xHalf, yHalf = extents.x * 0.5, extents.y * 0.5
  local tXMin, tXMax = centerX - xHalf, centerX + xHalf
  local tYMin, tYMax = centerY - yHalf, centerY + yHalf
  local zMin = tb:getPosition().z
  local squareSize = tb:getSquareSize()
  local apronCells = (squareSize > 0) and (max(0, margin or 0) / squareSize) or 0

  -- Get the AABB of the union of sources.
  local box = geom.computeSourcesAABB(sources)
  DOI = max(1.0, DOI)
  local reachPad = (DOI + apronCells + 2) * squareSize
  local boxPad = max(DOI * doiMultFactor, reachPad)
  box.xMin = box.xMin - boxPad
  box.xMax = box.xMax + boxPad
  box.yMin = box.yMin - boxPad
  box.yMax = box.yMax + boxPad

  -- Get the grid bounds of the union of sources.
  tmp1:set(floor(max(tXMin, box.xMin)), floor(max(tYMin, box.yMin)), 0)
  tmp2:set(ceil(min(tXMax, box.xMax)), ceil(min(tYMax, box.yMax)), 0)
  te:worldToGridByPoint2I(tmp1, gMin, tb)
  te:worldToGridByPoint2I(tmp2, gMax, tb)
  local gw, gh = gridDims(tb)
  local bXMin, bXMax, bYMin, bYMax = max(0, gMin.x), min(gw, gMax.x), max(0, gMin.y), min(gh, gMax.y)
  local xSize, ySize = bXMax - bXMin + 1, bYMax - bYMin + 1
  if xSize < 1 or ySize < 1 then return end

  -- Hold only the road footprint plus ~one support cell (the network's 1-ring analog), NOT the full margin --
  -- the margin blends as the apron above.
  local quads = geom.getAllQuadrilaterals(sources, squareSize)
  local tree = geom.populateTreeQuads(quads)

  -- Initialize the height and mask arrays.
  table.clear(mod); table.clear(mask); table.clear(height)
  table.clear(clip)
  local useClip = clips and #clips > 0
  local clipReachM = (DOI + apronCells + 2) * squareSize
  local ox, oy = windowOrigin(te, tb, bXMin, bYMin)
  for x = 0, xSize - 1 do
    local gX = bXMin + x
    for y = 0, ySize - 1 do
      local idx = y * xSize + x
      local gY = bYMin + y
      local pWSX, pWSY, z = ox + x * squareSize, oy + y * squareSize, nil
      tmpWS:set(pWSX, pWSY, 0)
      for tIdx in tree:queryNotNested(pWSX, pWSY, pWSX, pWSY) do
        local hitZ = geom.intersectsUpQuadBarycentric(tmpWS, quads[tIdx]) -- Sample using bilinear interpolation over the quad.
        if hitZ then
          z = min(hitZ - zMin, z or huge)
        end
      end
      if z then -- This grid point is directly underneath the source, so it's a mask.
        height[idx] = z -- Use the sampled height of the source here.
        mask[idx] = 1
        mod[idx] = 1
      else -- This grid point is not directly underneath the source, so it's not a mask.
        height[idx] = tb:getHeightGrid(gX, gY) -- Use the original terrain height here.
        mask[idx] = 0
        mod[idx] = 0
        if useClip and beyondClippedEnd(pWSX, pWSY, clips, clipReachM) then clip[idx] = 1 end
      end
    end
  end

  -- Baseline capture (opt-in).
  local origCap
  if baselineOut then
    origCap = table.new(xSize * ySize, 0)
    for x = 0, xSize - 1 do
      local gX = bXMin + x
      for y = 0, ySize - 1 do origCap[y * xSize + x] = tb:getHeightGrid(gX, bYMin + y) end
    end
  end

  finishTerraform(DOI, falloffExp, roughness, scale, xSize, ySize, bXMin, bXMax, bYMin, bYMax, tb, te, apronCells, smoothPasses, nil, useClip)

  -- Keep only the cells the carve actually moved, with the height it wrote (read back, so it matches the stored precision).
  if baselineOut then
    local bx, by, bz, bw, n = table.new(0, 0), table.new(0, 0), table.new(0, 0), table.new(0, 0), 0
    for x = 0, xSize - 1 do
      for y = 0, ySize - 1 do
        local idx = y * xSize + x
        if mod[idx] and mod[idx] > 0.5 then
          n = n + 1
          local gX, gY = bXMin + x, bYMin + y
          bx[n] = gX; by[n] = gY; bz[n] = origCap[idx]; bw[n] = tb:getHeightGrid(gX, gY)
        end
      end
    end
    baselineOut.gx, baselineOut.gy, baselineOut.z, baselineOut.w, baselineOut.n = bx, by, bz, bw, n
    baselineOut.xMin, baselineOut.yMin, baselineOut.xMax, baselineOut.yMax = bXMin, bYMin, bXMax, bYMax
  end
end

-- Restore a window captured by terraformToSources(..., baselineOut): writes the stashed original heights straight
-- back (raw, then one grid refresh over the recorded bounds). Cells edited since the carve (hand sculpting, another
-- road's carve) no longer hold the height the carve wrote (`bl.w`), so they are left as they are.
local function revertBaseline(bl, recordHistory)
  if not bl or not bl.n or bl.n < 1 then return end
  local tb = extensions.editor_terrainEditor and extensions.editor_terrainEditor.getTerrainBlock()
  if not tb then return end
  local gx, gy, gz, gw = bl.gx, bl.gy, bl.z, bl.w
  local step = recordHistory and newStep(bl.n) or nil
  for i = 1, bl.n do
    local x, y = gx[i], gy[i]
    local cur = tb:getHeightGrid(x, y)
    local w = gw and gw[i]
    if not w or abs(cur - w) <= touchedEps then
      local z = max(0, gz[i])
      if step then stepAdd(step, x, y, max(0, cur), z) end
      tb:setHeightGrid(x, y, z)
    end
  end
  tmp1:set(bl.xMin, bl.yMin, 0); tmp2:set(bl.xMax, bl.yMax, 0)
  updateGrid(tb)
  if step then
    editor_terrainEditor.setTerrainDirty()
    if step.n > 0 then util.commitStep("Restore Terrain", step, terraformUndo, terraformRedo) end
  end
end

-- Takes the carve `from` up and lays `to` down in its place, both recorded with the heights they wrote (`w`) and either of
-- them nil, writing only the cells whose height changes: each one written is a call into the engine, and a carve swapped
-- for one much like it differs in a handful of cells out of millions.
local function swapBaseline(from, to)
  if not from and not to then return end
  local tb = extensions.editor_terrainEditor and extensions.editor_terrainEditor.getTerrainBlock()
  if not tb then return end
  local x0 = min(from and from.xMin or huge, to and to.xMin or huge)
  local y0 = min(from and from.yMin or huge, to and to.yMin or huge)
  local x1 = max(from and from.xMax or -huge, to and to.xMax or -huge)
  local y1 = max(from and from.yMax or -huge, to and to.yMax or -huge)
  local h = y1 - y0 + 1
  -- Where each of `to`'s cells is in its record (0: not in it), over the window the two span.
  local at = ffi.new('int32_t[?]', (x1 - x0 + 1) * h)
  if to then
    local gx, gy = to.gx, to.gy
    for j = 1, to.n do at[(gx[j] - x0) * h + gy[j] - y0] = j end
  end
  local wx0, wy0, wx1, wy1 = huge, huge, -huge, -huge
  local function put(x, y, z)
    tb:setHeightGrid(x, y, z)
    if x < wx0 then wx0 = x end; if x > wx1 then wx1 = x end
    if y < wy0 then wy0 = y end; if y > wy1 then wy1 = y end
  end
  if from then
    local gx, gy, gz, gw, tw = from.gx, from.gy, from.z, from.w, to and to.w
    for i = 1, from.n do
      local x, y = gx[i], gy[i]
      local k = (x - x0) * h + y - y0
      local j, z = at[k], nil
      if j > 0 then z = tw[j]; at[k] = 0 else z = max(0, gz[i]) end
      if not gw or z ~= gw[i] then put(x, y, z) end
    end
  end
  if to then
    local gx, gy, gw = to.gx, to.gy, to.w
    for j = 1, to.n do
      local x, y = gx[j], gy[j]
      if at[(x - x0) * h + y - y0] > 0 then put(x, y, gw[j]) end
    end
  end
  if wx0 <= wx1 then
    tmp1:set(wx0, wy0, 0); tmp2:set(wx1, wy1, 0)
    updateGrid(tb)
  end
end

-- Merge a per-run baseline window into the accumulator (concat the moved-cell records + union the grid bounds).
local function mergeBaseline(dst, src)
  if not src or not src.n or src.n < 1 then return end
  local n0 = dst.n or 0
  local dgx, dgy, dz, dw, sgx, sgy, sz, sw = dst.gx, dst.gy, dst.z, dst.w, src.gx, src.gy, src.z, src.w
  for i = 1, src.n do dgx[n0 + i] = sgx[i]; dgy[n0 + i] = sgy[i]; dz[n0 + i] = sz[i] end
  if dw and sw then for i = 1, src.n do dw[n0 + i] = sw[i] end end
  dst.n = n0 + src.n
  dst.xMin, dst.yMin = min(dst.xMin, src.xMin), min(dst.yMin, src.yMin)
  dst.xMax, dst.yMax = max(dst.xMax, src.xMax), max(dst.yMax, src.yMax)
end

-- Baseline-memory carve. Each source RUN is terraformed on its OWN tight AABB rather than one union box: the bridge's two abutments sit
-- at opposite ends, so a union box would span the whole deck and churn the SDF/smoothing passes over the empty middle for nothing (a
-- continuous single-run source -- road/fence/etc. -- has no empty middle, so it takes the loop once and behaves exactly as before).
local function carveToSources(obj, DOI, margin, falloffExp, roughness, scale, sources, smoothPasses, clips)
  revertBaseline(obj.terraBaseline)
  if not sources or #sources == 0 then obj.terraBaseline = nil; return end
  local merged = { gx = table.new(0, 0), gy = table.new(0, 0), z = table.new(0, 0), w = table.new(0, 0), n = 0, xMin = huge, yMin = huge, xMax = -huge, yMax = -huge }
  local runBl = {}
  for i = 1, #sources do
    local run = sources[i]
    if run and #run > 0 then
      terraformToSources(DOI, margin, falloffExp, roughness, scale, { run }, smoothPasses, runBl, clips)
      mergeBaseline(merged, runBl)
    end
  end
  obj.terraBaseline = merged.n > 0 and merged or nil
end

-- Like carveToSources, but each element of `groups` is itself a LIST of runs terraformed together in ONE terraformToSources pass (a single
-- baseline capture over their shared window). Use when one region is built from several OVERLAPPING strips (e.g. a crowned bridge abutment's
-- lateral crown facets): carving them as separate runs would double-capture the shared cells - the 2nd run recording already-moved terrain as
-- the "original" - and corrupt the restore baseline. Groups themselves should be disjoint (e.g. the two abutments), so merging is clean.
local function carveToSourceGroups(obj, DOI, margin, falloffExp, roughness, scale, groups, smoothPasses, clips)
  revertBaseline(obj.terraBaseline)
  if not groups or #groups == 0 then obj.terraBaseline = nil; return end
  local merged = { gx = table.new(0, 0), gy = table.new(0, 0), z = table.new(0, 0), w = table.new(0, 0), n = 0, xMin = huge, yMin = huge, xMax = -huge, yMax = -huge }
  local runBl = {}
  for i = 1, #groups do
    local g = groups[i]
    if g and #g > 0 then
      terraformToSources(DOI, margin, falloffExp, roughness, scale, g, smoothPasses, runBl, clips)
      mergeBaseline(merged, runBl)
    end
  end
  obj.terraBaseline = merged.n > 0 and merged or nil
end

-- Restore the terrain an object carved (leaves the object itself in place) and forget the record. Returns true if there was a
-- carve to undo (so callers can grey their button). recordHistory makes it a Ctrl+Z-able terrain edit; delete paths pass false.
local function restoreBaseline(obj, recordHistory)
  if obj and obj.terraBaseline and (obj.terraBaseline.n or 0) > 0 then
    revertBaseline(obj.terraBaseline, recordHistory)
    obj.terraBaseline = nil
    return true
  end
  obj.terraBaseline = nil
  return false
end

-- The ground as it was before the carves recorded in `baselines` (terraBaseline records), as a lookup `height(x, y)` (nil off
-- the terrain): their record of the cells they moved, and the live terrain everywhere else. Where two records hold a cell, the
-- first one listed wins.
local function groundBefore(baselines)
  local tb = extensions.editor_terrainEditor and extensions.editor_terrainEditor.getTerrainBlock()
  local orig, pos, sq
  if tb then
    pos, sq = tb:getPosition(), tb:getSquareSize()
    for _, bl in ipairs(baselines) do
      if bl and bl.n and bl.n > 0 then
        orig = orig or {}
        local gx, gy, gz = bl.gx, bl.gy, bl.z
        for i = 1, bl.n do
          local k = gy[i] * 65536 + gx[i]
          if orig[k] == nil then orig[k] = gz[i] end
        end
      end
    end
  end
  local p = vec3()
  return function(x, y)
    if orig then
      local z = orig[floor((y - pos.y) / sq + 0.5) * 65536 + floor((x - pos.x) / sq + 0.5)]
      if z then return z + pos.z end
    end
    p:set(x, y, 0)
    return core_terrain.getTerrainHeight(p)
  end
end

-- Shared 'Terraform To X' + 'Restore Terrain' button pair for the engineered-spline tools,
-- `own` (optional): { run (obj, p), restore (obj), hasCarve (obj) }, a tool's own carve in place of the plain ribbon one.
local function terraformButtons(obj, canTerraform, p, label, icons, cols, iconsBig, own)
  if canTerraform then
    if editor.uiIconImageButton(icons.terrainToLine, iconsBig, cols.blueB, nil, nil, 'terraformTo' .. label .. 'Btn') then
      if own then own.run(obj, p)
      else carveToSources(obj, p.doi, p.margin, p.falloff, p.roughness or 0, p.scale or 0, util.getSourcesSingle(obj), floor(p.smooth or 0)) end
    end
    im.tooltip('Terraform the terrain to the selected ' .. label .. '.')
  else
    im.Dummy(iconsBig)
  end
  im.SameLine()
  -- Restore: blue when there's a carve to undo, dimmed otherwise. recordHistory=true so it's Ctrl+Z-able (only terrain moves).
  local hasCarve = obj and (own and own.hasCarve(obj) or (not own and obj.terraBaseline and (obj.terraBaseline.n or 0) > 0))
  if editor.uiIconImageButton(icons.settings_backup_restore, iconsBig, hasCarve and cols.blueB or cols.blueD, nil, nil, 'restoreTerrain' .. label .. 'Btn') and hasCarve then
    if own then own.restore(obj) else restoreBaseline(obj, true) end
  end
  im.tooltip('Restore the terrain this ' .. label .. ' carved back to how it was before terraforming (leaves it in place). Undo with Ctrl+Z.')
end

-- Grow the {xmin, xmax, ymin, ymax} bounds table `b` to include (x, y).
local function accBounds(b, x, y)
  if x < b[1] then b[1] = x end
  if x > b[2] then b[2] = x end
  if y < b[3] then b[3] = y end
  if y > b[4] then b[4] = y end
end

local stampPad = 2 -- window pad (grid cells) for the per-feature raster scan: half-cell skin + one cell of index slack

-- Local grid-index window (padded by stampPad) covering a world XY AABB, clamped to the feature window.
local function gridWindow(te, tb, aXMin, aXMax, aYMin, aYMax, xSize, ySize, bXMin, bYMin)
  tmp1:set(aXMin, aYMin, 0); te:worldToGridByPoint2I(tmp1, gMin, tb)
  tmp2:set(aXMax, aYMax, 0); te:worldToGridByPoint2I(tmp2, gMax, tb)
  local x0 = max(0, min(gMin.x, gMax.x) - stampPad - bXMin)
  local x1 = min(xSize - 1, max(gMin.x, gMax.x) + stampPad - bXMin)
  local y0 = max(0, min(gMin.y, gMax.y) - stampPad - bYMin)
  local y1 = min(ySize - 1, max(gMin.y, gMax.y) + stampPad - bYMin)
  return x0, x1, y0, y1
end

-- Stamp a ribbon quad's footprint: every cell inside the quad, plus the half-cell edge skin (so a ribbon
-- narrower than one cell still lands a continuous line of cells). A carve also offers its edge height to the cells
-- out to ring2 beyond, so the 1-ring carries the surface's own grade rather than its lowest neighbour's.
local function stampQuad(te, tb, quad, mode, prio, xSize, ySize, bXMin, bYMin, zMin, halfCell2, ring2, ox, oy, sq)
  local q1, q2, q3, q4 = quad[1], quad[2], quad[3], quad[4]
  local x0, x1, y0, y1 = gridWindow(te, tb,
    min(q1.x, q2.x, q3.x, q4.x), max(q1.x, q2.x, q3.x, q4.x),
    min(q1.y, q2.y, q3.y, q4.y), max(q1.y, q2.y, q3.y, q4.y), xSize, ySize, bXMin, bYMin)
  for x = x0, x1 do
    local px = ox + x * sq
    for y = y0, y1 do
      local py = oy + y * sq
      local u, v = geom.quadUV(px, py, q1, q2, q3, q4)
      local uc, vc, hit, interior, d2
      if u ~= nil then
        uc, vc, hit, interior, d2 = u, v, true, true, 0
      else
        local nu, nv
        nu, nv, d2 = quadNearestUV(px, py, q1, q2, q3, q4)
        if d2 <= halfCell2 then
          uc, vc, hit, interior = nu, nv, true, false
        elseif mode == 'carve' and d2 <= ring2 then
          ringCandidate(y * xSize + x, lerp(lerp(q1.z, q2.z, nu), lerp(q3.z, q4.z, nu), nv) - zMin, prio, d2)
        end
      end
      if hit then
        local z = lerp(lerp(q1.z, q2.z, uc), lerp(q3.z, q4.z, uc), vc) - zMin
        if mode == 'spill' then z = max(z, tb:getHeightGrid(bXMin + x, bYMin + y)) end
        accumulate(y * xSize + x, z, mode, prio, interior, d2)
      end
    end
  end
end

-- Stamp a junction's footprint: cells inside its sealed polygon(s), plus the half-cell edge skin. Level z
-- (the hub grade). No support ring here -- the one-cell dilation after the merge adds it.
-- slope (optional): { x, y, gx, gy } leans the stamp as a plane through (x, y, zWorld) rising gx, gy per metre.
local function stampRings(te, tb, rings, zWorld, mode, prio, xSize, ySize, bXMin, bYMin, zMin, halfCell2, slope, ox, oy, sq)
  local zLocal = zWorld - zMin
  local aXMin, aXMax, aYMin, aYMax = huge, -huge, huge, -huge
  for r = 1, #rings do
    local ring = rings[r]
    for k = 1, #ring do
      local p = ring[k]
      if p.x < aXMin then aXMin = p.x end
      if p.x > aXMax then aXMax = p.x end
      if p.y < aYMin then aYMin = p.y end
      if p.y > aYMax then aYMax = p.y end
    end
  end
  if aXMin > aXMax then return end
  local x0, x1, y0, y1 = gridWindow(te, tb, aXMin, aXMax, aYMin, aYMax, xSize, ySize, bXMin, bYMin)
  for x = x0, x1 do
    for y = y0, y1 do
      local pWS = tmpWS
      pWS:set(ox + x * sq, oy + y * sq, 0)
      local hit, interior, best2 = false, false, 0
      for r = 1, #rings do
        if pWS:inPolygon(rings[r]) then hit, interior = true, true; break end
      end
      if not hit then
        best2 = huge
        for r = 1, #rings do
          local ring = rings[r]
          local m = #ring
          for k = 1, m do
            local a, b = ring[k], ring[(k % m) + 1]
            local _, d2 = segClosest2D(pWS.x, pWS.y, a.x, a.y, b.x, b.y)
            if d2 < best2 then best2 = d2 end
          end
        end
        hit = best2 <= halfCell2
      end
      if hit then
        local z = slope and zLocal + slope.gx * (pWS.x - slope.x) + slope.gy * (pWS.y - slope.y) or zLocal
        accumulate(y * xSize + x, z, mode, prio, interior, best2)
      end
    end
  end
end

-- Terraform the heightmap from explicit features, with cell-overlap 1-ring support and per-feature mode.
--
-- `claimOnly` stops after the merge: the occupancy mask is written and not one height is. See claimFeatures below.
local function terraformToQuads(DOI, margin, falloffExp, roughness, scale, features, passes, protect, priority,
                                baselineOut, claimOnly)
  priority = priority or 0
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  if not features or #features == 0 or not tb or not te then
    return
  end

  local extents = tb:getWorldBox():getExtents()
  local center = tb:getWorldBox():getCenter()
  local xHalf, yHalf = extents.x * 0.5, extents.y * 0.5
  local tXMin, tXMax = center.x - xHalf, center.x + xHalf
  local tYMin, tYMax = center.y - yHalf, center.y + yHalf
  local zMin = tb:getPosition().z
  local squareSize = tb:getSquareSize()
  -- Footprint rasterisation tolerance.
  local halfCell2 = (squareSize * 0.5) * (squareSize * 0.5)
  local ring2 = heldReach(squareSize) ^ 2 -- farthest a 1-ring cell lies from the surface its footprint skins
  local apronCells = (squareSize > 0) and (max(0, margin or 0) / squareSize) or 0

  -- Union XY AABB of all feature geometry.
  local b = { huge, -huge, huge, -huge }
  for i = 1, #features do
    local f = features[i]
    if f.quad then
      accBounds(b, f.quad[1].x, f.quad[1].y); accBounds(b, f.quad[2].x, f.quad[2].y)
      accBounds(b, f.quad[3].x, f.quad[3].y); accBounds(b, f.quad[4].x, f.quad[4].y)
    elseif f.rings then
      for r = 1, #f.rings do
        local ring = f.rings[r]
        for k = 1, #ring do accBounds(b, ring[k].x, ring[k].y) end
      end
    end
  end
  local fXMin, fXMax, fYMin, fYMax = b[1], b[2], b[3], b[4]
  if fXMin > fXMax then
    return
  end

  DOI = max(5.0, DOI)
  local boxPad = DOI * doiMultFactor -- Expand the AABB well past the DOI so the falloff reaches zero.
  fXMin, fXMax = fXMin - boxPad, fXMax + boxPad
  fYMin, fYMax = fYMin - boxPad, fYMax + boxPad

  -- Clamp to the terrain and convert to the grid window.
  tmp1:set(floor(max(tXMin, fXMin)), floor(max(tYMin, fYMin)), 0)
  tmp2:set(ceil(min(tXMax, fXMax)), ceil(min(tYMax, fYMax)), 0)
  te:worldToGridByPoint2I(tmp1, gMin, tb)
  te:worldToGridByPoint2I(tmp2, gMax, tb)
  local gw, gh = gridDims(tb)
  local bXMin, bXMax, bYMin, bYMax = max(0, gMin.x), min(gw, gMax.x), max(0, gMin.y), min(gh, gMax.y)
  local xSize, ySize = bXMax - bXMin + 1, bYMax - bYMin + 1
  if xSize < 1 or ySize < 1 then
    return
  end

  -- Reset accumulators.
  table.clear(cH); table.clear(cM); table.clear(cP)
  table.clear(fH); table.clear(fM); table.clear(fP)
  table.clear(dH); table.clear(dM); table.clear(dP)
  table.clear(ringCand); table.clear(rH)
  for i = 0, xSize * ySize - 1 do
    cM[i] = 0; fM[i] = 0; dM[i] = 0; kM[i] = 0; lM[i] = 0; sM[i] = 0
  end

  local ox, oy = windowOrigin(te, tb, bXMin, bYMin)
  for i = 1, #features do
    local f = features[i]
    local mode = f.mode or 'carve'
    local prio = f.priority or priority
    if f.quad then
      stampQuad(te, tb, f.quad, mode, prio, xSize, ySize, bXMin, bYMin, zMin, halfCell2, ring2, ox, oy, squareSize)
    elseif f.rings then
      stampRings(te, tb, f.rings, f.z or zMin, mode, prio, xSize, ySize, bXMin, bYMin, zMin, halfCell2, f.slope, ox, oy, squareSize)
    end
  end

  -- Priority: ground carve (roads/rail/paths, min) wins any overlap.
  for x = 0, xSize - 1 do
    local gX = bXMin + x
    for y = 0, ySize - 1 do
      local idx = y * xSize + x
      local gY = bYMin + y
      -- Pick the winning footprint claim.
      local srcZ, srcPrio
      if cM[idx] > 0 then srcZ, srcPrio = cH[idx], cP[idx] end
      -- A road carved over a tunnel keeps its own grade: the floor gives way to it.
      if cM[idx] > 0 or dM[idx] > 0 then lM[idx] = 0 end
      -- Bridge under-deck cut.
      if dM[idx] > 0 and (srcPrio == nil or dP[idx] > srcPrio) then
        local cur = tb:getHeightGrid(gX, gY)
        srcZ, srcPrio = (cur > dH[idx]) and dH[idx] or cur, dP[idx]
      end
      local raised = false
      if fM[idx] > 0 and (srcPrio == nil or fP[idx] > srcPrio) and tb:getHeightGrid(gX, gY) < fH[idx] then
        srcZ, srcPrio, raised = fH[idx], fP[idx], true
      end
      local key = gX * MASK_STRIDE + gY
      local oPrio = occPrio[key]
      if oPrio and oPrio > (srcPrio or priority) then
        -- Owned by a higher-priority surface (e.g. a road cell during the building pass): hold it at the owner's
        -- height so the blend can't lower it, and don't rewrite it (a no-op that keeps the driving surface exact).
        height[idx] = occZ[key]; mask[idx] = 1; mod[idx] = 0
        prioArr[idx] = oPrio
      elseif srcZ then
        local winZ = srcZ
        if oPrio == srcPrio and occZ[key] < winZ then winZ = occZ[key] end -- same priority: min rule
        occZ[key] = winZ; occPrio[key] = srcPrio
        height[idx] = winZ; mask[idx] = 1; mod[idx] = 1
        prioArr[idx] = srcPrio
        rH[idx] = raised or nil
      else
        height[idx] = tb:getHeightGrid(gX, gY); mask[idx] = 0; mod[idx] = 0
        prioArr[idx] = -1
      end
    end
  end

  -- 1-ring support = STRICT one-cell dilation of the merged footprint. A surface's ring also takes cells a lower band
  -- holds (another road's verge, a junction pad), so a road's edge never drops to whatever lies beside it. Not an
  -- areaway's: it is walled, and the half-cell stamp already keeps the road's edge on held cells.
  local ringIdx, ringZ, ringP, ringR, nRing = {}, {}, {}, {}, 0
  for x = 0, xSize - 1 do
    for y = 0, ySize - 1 do
      local idx = y * xSize + x
      local own = mask[idx] == 1 and prioArr[idx] or -1
      local bestP, bestZ, bestR = -1, huge, nil
      for dy = -1, 1 do
        local ny = y + dy
        if ny >= 0 and ny < ySize then
          local base = ny * xSize + x
          for dx = -1, 1 do
            local nx = x + dx
            if nx >= 0 and nx < xSize then
              local nIdx = base + dx
              local np = prioArr[nIdx]
              if mask[nIdx] == 1 and np > own then
                if np > bestP or (np == bestP and height[nIdx] < bestZ) then bestP, bestZ, bestR = np, height[nIdx], rH[nIdx] end
              end
            end
          end
        end
      end
      if bestP > own and own ~= PRIO.AREAWAY then
        local c = ringCand[idx]
        if c and c[bestP] then bestZ, bestR = c[bestP][1], nil end
        nRing = nRing + 1; ringIdx[nRing] = idx; ringZ[nRing] = bestZ; ringP[nRing] = bestP; ringR[nRing] = bestR
      end
    end
  end
  -- Let go of now, not at the next pass: a table per cell, and held between passes it is the most the GC has to walk.
  ringCand = {}
  for i = 1, nRing do
    local idx = ringIdx[i]
    local x = idx % xSize
    local y = (idx - x) / xSize
    local prio = ringP[i]
    local key = (bXMin + x) * MASK_STRIDE + (bYMin + y)
    local oPrio = occPrio[key]
    if not (oPrio and oPrio > prio) then -- never overwrite a higher-priority owner's cell
      local winZ = ringZ[i]
      if oPrio == prio and occZ[key] < winZ then winZ = occZ[key] end -- same priority: keep the lower support
      if ringR[i] then winZ = max(winZ, tb:getHeightGrid(bXMin + x, bYMin + y)) end
      occZ[key] = winZ; occPrio[key] = prio
      height[idx] = winZ; mask[idx] = 1; mod[idx] = 1; lM[idx] = 0
      prioArr[idx] = prio
      rH[idx] = ringR[i]
    end
  end

  -- A claim pass wanted the occupancy mask and nothing else, and the mask is now written. Everything below moves ground.
  if claimOnly then return end

  -- Baseline capture (opt-in).
  local origCap
  if baselineOut then
    origCap = table.new(xSize * ySize, 0)
    for x = 0, xSize - 1 do
      local gX = bXMin + x
      for y = 0, ySize - 1 do origCap[y * xSize + x] = tb:getHeightGrid(gX, bYMin + y) end
    end
  end

  -- apronCells: smooth flat skirt of 'margin' metres before the falloff (avoids a jaggy frozen shelf).
  local ownStep = baselineOut and baselineOut.ownStep
  unfiledOnce = ownStep or false
  finishTerraform(DOI, falloffExp, roughness, scale, xSize, ySize, bXMin, bXMax, bYMin, bYMax, tb, te, apronCells, passes, protect, nil, true)
  unfiledOnce = false

  -- Keep only the cells the carve actually moved (mod > 0.5) as a sparse original-height record for revertBaseline().
  -- A caller filing its own step also gets the heights written (read back, so they match the stored precision), which is
  -- what lets it lay the carve back down.
  if baselineOut then
    local bx, by, bz, n = table.new(0, 0), table.new(0, 0), table.new(0, 0), 0
    local bw = ownStep and table.new(0, 0) or nil
    for x = 0, xSize - 1 do
      for y = 0, ySize - 1 do
        local idx = y * xSize + x
        if mod[idx] and mod[idx] > 0.5 then
          n = n + 1
          bx[n] = bXMin + x; by[n] = bYMin + y; bz[n] = origCap[idx]
          if bw then bw[n] = tb:getHeightGrid(bx[n], by[n]) end
        end
      end
    end
    baselineOut.gx, baselineOut.gy, baselineOut.z, baselineOut.w, baselineOut.n = bx, by, bz, bw, n
    baselineOut.xMin, baselineOut.yMin, baselineOut.xMax, baselineOut.yMax = bXMin, bYMin, bXMax, bYMax
  end
end

--- Claim every cell a feature set covers, at this priority, without moving a single height.
local function claimFeatures(features, priority)
  if not features or #features == 0 then return end
  terraformToQuads(0, 0, 0, 0, 1, features, 0, nil, priority, nil, true)
end

--- Cut a set of features into a tool's own scratch pad. The same carve as terraformToQuads and, so that what a tool shows
--- on its pad is what the placer will cut for real, the same falloff -- but the level is left alone: no dirty flag and no
--- undo entry. The pad's owner remembers the heights (`baselineOut`) and hands them back itself.
---
--- No priority band: a pad holds one site and nothing else is claiming ground on it, so the site's own shapes settle their
--- overlaps between themselves on the same-band min rule.
local function carvePad(DOI, margin, falloffExp, features, passes, baselineOut)
  if not features or #features == 0 then return end
  quietOnce = true
  terraformToQuads(DOI, margin, falloffExp, 0, 0, features, passes, nil, 0, baselineOut)
  quietOnce = false
end

-- Like carveToSources, but the pad is given as explicit crowned QUADS stamped with the EXACT bilinear per-cell Z (terraformToQuads) instead of
-- min-Z strip runs - so a crowned / arbitrary-width deck abutment lands exactly on the deck top with no boundary dips (a strip carve dips a few
-- cm below at each crown breakpoint). One terraformToQuads pass over both approaches -> one revertable baseline.
local function carveToQuads(obj, DOI, margin, falloffExp, roughness, scale, features, smoothPasses)
  revertBaseline(obj.terraBaseline)
  if not features or #features == 0 then obj.terraBaseline = nil; return end
  resetMask() -- standalone carve: start from a clean occupancy mask so no stale claim from a prior carve min-blends the pad below the deck top
  local bl = {}
  terraformToQuads(DOI, margin, falloffExp, roughness, scale, features, smoothPasses, nil, 0, bl)
  obj.terraBaseline = (bl.n and bl.n > 0) and bl or nil
end

-- Lower one grid vertex to (deck top - margin) only if terrain currently pokes ABOVE the deck top there.
-- `ctx` carries the clamp's mutable state (touched-cell bbox, changed count, undo history) and its terrain refs.
local function clampCell(ctx, gX, gY, deckTopWorldZ)
  if gX < 0 or gY < 0 or gX > ctx.gw or gY > ctx.gh then return end
  local topLocal = deckTopWorldZ - ctx.zMin
  local oldZ = ctx.tb:getHeightGrid(gX, gY)
  if oldZ > topLocal + 1e-3 then -- terrain sticks up through the deck
    local target = topLocal - ctx.margin
    if target < 0 then target = 0 end
    ctx.tb:setHeightGrid(gX, gY, target)
    local key = gY * (ctx.gw + 1) + gX
    local rec = ctx.histByIdx[key]
    if rec then
      rec.new = target
    else
      rec = { old = max(0, oldZ), new = target, x = gX, y = gY }
      ctx.histByIdx[key] = rec
      ctx.history[#ctx.history + 1] = rec
    end
    ctx.changed = ctx.changed + 1
    if gX < ctx.wXMin then ctx.wXMin = gX end; if gX > ctx.wXMax then ctx.wXMax = gX end
    if gY < ctx.wYMin then ctx.wYMin = gY end; if gY > ctx.wYMax then ctx.wYMax = gY end
  end
end

-- Absolute grid-index window (one cell of slack) covering a world XY AABB, clamped to the terrain.
local function cellWindow(te, tb, aXMin, aXMax, aYMin, aYMax, gw, gh)
  tmp1:set(aXMin, aYMin, 0); te:worldToGridByPoint2I(tmp1, gMin, tb)
  tmp2:set(aXMax, aYMax, 0); te:worldToGridByPoint2I(tmp2, gMax, tb)
  local x0 = max(0,  min(gMin.x, gMax.x) - 1)
  local x1 = min(gw, max(gMin.x, gMax.x) + 1)
  local y0 = max(0,  min(gMin.y, gMax.y) - 1)
  local y1 = min(gh, max(gMin.y, gMax.y) + 1)
  return x0, x1, y0, y1
end

-- Direct, unconditional lower-only terrain clamp under a set of surface footprints (bridge decks).
local function clampBelowDecks(features, marginM)
  local tb = extensions.editor_terrainEditor and extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor and extensions.editor_terrainEditor.getTerrainEditor()
  if not features or #features == 0 or not tb or not te then return 0 end
  local zMin = tb:getPosition().z
  local margin = marginM or 0.4
  local squareSize = tb:getSquareSize()
  local halfCell2 = (squareSize * 0.5) * (squareSize * 0.5)
  local gw, gh = gridDims(tb) -- max valid grid index per axis (vertices span 0..gw, 0..gh)
  -- Clamp state: touched-cell bbox (one updateGrid at the end), changed count, and the undo history (every lowered vertex).
  local ctx = { tb = tb, gw = gw, gh = gh, zMin = zMin, margin = margin,
                changed = 0, wXMin = huge, wYMin = huge, wXMax = -huge, wYMax = -huge,
                history = {}, histByIdx = {} }

  for i = 1, #features do
    local f = features[i]
    if f.quad then
      local q1, q2, q3, q4 = f.quad[1], f.quad[2], f.quad[3], f.quad[4]
      local x0, x1, y0, y1 = cellWindow(te, tb,
        min(q1.x, q2.x, q3.x, q4.x), max(q1.x, q2.x, q3.x, q4.x),
        min(q1.y, q2.y, q3.y, q4.y), max(q1.y, q2.y, q3.y, q4.y), gw, gh)
      for gX = x0, x1 do
        tmpPoint2I.x = gX
        for gY = y0, y1 do
          tmpPoint2I.y = gY
          local pWS = te:gridToWorldByPoint2I(tmpPoint2I, tb)
          local uc, vc, hit = nil, nil, false
          local u, v = geom.quadUV(pWS.x, pWS.y, q1, q2, q3, q4)
          if u ~= nil then
            uc, vc, hit = u, v, true
          else
            local nu, nv, d2 = quadNearestUV(pWS.x, pWS.y, q1, q2, q3, q4)
            if d2 <= halfCell2 then uc, vc, hit = nu, nv, true end
          end
          if hit then
            clampCell(ctx, gX, gY, lerp(lerp(q1.z, q2.z, uc), lerp(q3.z, q4.z, uc), vc))
          end
        end
      end
    elseif f.rings then
      local rings = f.rings
      local zTop = f.z or zMin
      local aXMin, aXMax, aYMin, aYMax = huge, -huge, huge, -huge
      for r = 1, #rings do
        local ring = rings[r]
        for k = 1, #ring do
          local p = ring[k]
          if p.x < aXMin then aXMin = p.x end; if p.x > aXMax then aXMax = p.x end
          if p.y < aYMin then aYMin = p.y end; if p.y > aYMax then aYMax = p.y end
        end
      end
      if aXMin <= aXMax then
        local x0, x1, y0, y1 = cellWindow(te, tb, aXMin, aXMax, aYMin, aYMax, gw, gh)
        for gX = x0, x1 do
          tmpPoint2I.x = gX
          for gY = y0, y1 do
            tmpPoint2I.y = gY
            local pWS = te:gridToWorldByPoint2I(tmpPoint2I, tb)
            local hit = false
            for r = 1, #rings do
              if pWS:inPolygon(rings[r]) then hit = true; break end
            end
            if hit then clampCell(ctx, gX, gY, zTop) end
          end
        end
      end
    end
  end

  if ctx.wXMin <= ctx.wXMax then
    tmp1:set(ctx.wXMin, ctx.wYMin, 0); tmp2:set(ctx.wXMax, ctx.wYMax, 0)
    updateGrid(tb)
    editor_terrainEditor.setTerrainDirty()
  end
  if #ctx.history > 0 then
    local step = newStep(#ctx.history)
    for i = 1, #ctx.history do
      local r = ctx.history[i]
      stepAdd(step, r.x, r.y, r.old, r.new)
    end
    util.commitStep("Clamp Under Decks", step, terraformUndo, terraformRedo)
  end
  return ctx.changed
end


-- Public interface.
M.PRIO =                                                PRIO

M.heldReach =                                           heldReach
M.gridDims =                                            gridDims
M.resetMask =                                           resetMask
M.snapshotBaseline =                                    snapshotBaseline
M.restoreBaseline =                                     restoreBaseline
M.cellPriorityAt =                                      cellPriorityAt
M.terraformToSources =                                  terraformToSources
M.revertBaseline =                                      revertBaseline
M.swapBaseline =                                        swapBaseline
M.carveToSources =                                      carveToSources
M.carveToSourceGroups =                                 carveToSourceGroups
M.carveToQuads =                                        carveToQuads
M.restoreBaseline =                                     restoreBaseline
M.groundBefore =                                        groundBefore
M.terraformButtons =                                    terraformButtons
M.terraformToQuads =                                    terraformToQuads
M.claimFeatures =                                       claimFeatures
M.carvePad =                                            carvePad
M.clampBelowDecks =                                     clampBelowDecks

return M