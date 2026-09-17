-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local doiMultFactor = 2.5 -- The multiplier for the AABB margin.

local globalSmoothRadius = 4 -- The number of grid cells to smooth over.
local smoothPasses = 5 -- Default blur iterations over the transition apron (callers may override).

local defaultFbmLacunarity = 2.0 -- Frequency multiplier per octave.
local defaultFbmGain = 0.5 -- Amplitude multiplier per octave.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- External modules.
local toolMgr = require('editor/toolManager')
local geom = require('editor/toolUtilities/geom')
local perlin = require('editor/toolUtilities/perlin') -- Currently unused, since simplex is preferred.
local simplex = require('editor/toolUtilities/simplex')

-- Module constants.
local min, max, floor, ceil = math.min, math.max, math.floor, math.ceil
local sqrt, huge = math.sqrt, math.huge

-- Module state.
local final, mod, mask, height = {}, {}, {}, {}
local sdf, closestX, closestY = {}, {}, {}
local globalTemp = {}
-- terraformToQuads accumulators: claimed FOOTPRINT height + claimed flag (0 = unclaimed, 1 = claimed) +
-- claiming PRIORITY per grid vertex, one set per mode. Only footprint cells are stamped here. A HIGHER-priority
-- claim wins a cell outright (a road always beats a path there, regardless of height); at EQUAL priority,
-- carve/cut combine by MIN (lowest grade wins a grade separation) and fill by MAX. Feeding priority per feature
-- lets the whole network terraform in ONE pass (so a single transition/blur, no per-band seam on shared verges)
-- while still keeping roads/rail above structures above paths. The 1-ring support is added AFTER the merge as a
-- strict one-cell dilation of the footprint -- never a metric radius.
local cH, cM, cP, fH, fM, fP = {}, {}, {}, {}, {}, {}
local dH, dM, dP = {}, {}, {} -- 'cut' (lower-only) accumulators: bridge under-deck clearance shave.
local prioArr = {} -- Winning footprint priority per window vertex (set in the merge; used by the 1-ring dilation).
local gMin, gMax, tmpPoint2I = Point2I(0, 0), Point2I(0, 0), Point2I(0, 0)
local tmp1, tmp2 = vec3(), vec3()

-- Persistent terrain-wide occupancy mask, shared across EVERY terraformToQuads call of an import (lakes,
-- transport ground, transport structures, buildings). One entry per stamped terrain cell, keyed by absolute
-- grid coords (gx * MASK_STRIDE + gy), holding the LOWEST footprint height claimed there (occZ, local frame =
-- worldZ - zMin) and the priority of the surface that owns it (occPrio). Rules when a stamp of priority P wants
-- a cell already owned at priority Q with height Zq:
--   * P <  Q : rejected -- the higher-priority surface owns it (transport is untouchable by buildings/lakes).
--   * P >  Q : override  -- higher priority always wins regardless of height (roads must never be buried).
--   * P == Q : min rule  -- only lower it (Z = min(Z, Zq)); a road under a grade separation keeps its cut.
-- resetMask() clears it at the start of each import. STRIDE exceeds any terrain grid extent.
local MASK_STRIDE = 131072
local occZ, occPrio = {}, {}
-- Priority bands (higher wins). Roads/rail (GROUND) sit at the top so a driving/rail surface can never be
-- lifted or overwritten by anything around it, then their STRUCTUREs (bridge/tunnel abutments). PATHs are
-- transport too but rank BELOW road/rail/structure -- a footpath must never win a cell off a road or drag its
-- terrain down (it yields and floats instead). All transport still outranks BUILDING and LAKE.
local PRIO = { LAKE = 1, BUILDING = 2, PATH = 3, STRUCTURE = 4, GROUND = 5 }


local function resetMask()
  table.clear(occZ); table.clear(occPrio)
end

-- Combine one FOOTPRINT claim into an accumulator. 'lower' picks the winner direction (carve/cut = lower z
-- wins, fill = higher z wins), 'prio' is the claiming surface's priority band. Rule: first claim sets the cell;
-- a HIGHER-priority claim overrides it outright (regardless of z, so a road always beats a path on a shared
-- cell); an EQUAL-priority claim settles by the mode's min/max (lowest road wins a grade separation, overlapping
-- segments of one surface settle to the same value with no notch); a lower-priority claim is ignored. The
-- 1-ring is a separate one-cell dilation done after the merge.
local function combine(H, M, P, idx, z, prio, lower)
  if M[idx] == 0 then
    H[idx] = z; M[idx] = 1; P[idx] = prio
  elseif prio > P[idx] then
    H[idx] = z; P[idx] = prio
  elseif prio == P[idx] then
    if lower then
      if z < H[idx] then H[idx] = z end
    else
      if z > H[idx] then H[idx] = z end
    end
  end
end

local function accumulate(idx, z, mode, prio)
  if mode == 'fill' then
    combine(fH, fM, fP, idx, z, prio, false)
  elseif mode == 'cut' then
    combine(dH, dM, dP, idx, z, prio, true)
  else
    combine(cH, cM, cP, idx, z, prio, true)
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

-- Nearest point on a quad's BOUNDARY to p, as (u, v) plus the squared distance. Corner order matches
-- the bilinear convention used throughout (q1,q2 = the u edge at v=0; q3,q4 = the u edge at v=1), so the
-- four sides are v=0, v=1, u=0 and u=1 and a hit's (u,v) feeds the same bilinear height lerp as an
-- interior sample. Used for the 1-ring support cells, which by definition sit outside the quad and so have
-- no inverse-bilinear preimage at all.
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


-- Maps the given roughness and scale to the appropriate low-level noise parameters.
local function mapNoiseParameters(roughness, scale)
  roughness, scale = clamp(roughness, 0, 1), clamp(scale, 0, 1) -- Clamp the input roughness and scale to the range [0, 1].
  local noiseStrength = lerp(0.0, 1.0, roughness) -- Amplitude mapping.
  local noiseFreq = lerp(0.02, 0.2, scale) -- Frequency mapping: large bumps ~ 50m wavelength => freq ~= 0.02, small bumps ~ 5m wavelength => freq ~= 0.2.
  local fbmOctaves = floor(lerp(3, 6, scale) + 0.5) -- Octave mapping: avoid flickering patterns (three layers), richer detail (six layers).
  return noiseFreq, noiseStrength, fbmOctaves, defaultFbmLacunarity, defaultFbmGain
end

-- Undo callback for terraforming operations.
local function terraformUndo(data)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  if not tb then
    return -- Early return if no terrain block.
  end

  -- Remove all spline meshes before terraforming to prevent collision mesh conflicts.
  toolMgr.removeAllSplineToolMeshes()

  local xMin, xMax, yMin, yMax = huge, -huge, huge, -huge
  for i = 1, #data do
    local d = data[i]
    local dx, dy = d.x, d.y
    tb:setHeight(dx, dy, max(0.0, d.old))
    xMin, xMax = min(xMin, dx), max(xMax, dx)
    yMin, yMax = min(yMin, dy), max(yMax, dy)
  end
  tmp1:set(xMin, yMin, 0)
  tmp2:set(xMax, yMax, 0)
  tb:updateGrid(tmp1, tmp2)
end

-- Redo callback for terraforming operations.
local function terraformRedo(data)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  if not tb then
    return -- Early return if no terrain block.
  end

  -- Remove all spline meshes before terraforming to prevent collision mesh conflicts.
  toolMgr.removeAllSplineToolMeshes()

  local xMin, xMax, yMin, yMax = huge, -huge, huge, -huge
  for i = 1, #data do
    local d = data[i]
    local dx, dy = d.x, d.y
    tb:setHeight(dx, dy, max(0.0, d.new))
    xMin, xMax = min(xMin, dx), max(xMax, dx)
    yMin, yMax = min(yMin, dy), max(yMax, dy)
  end
  tmp1:set(xMin, yMin, 0)
  tmp2:set(xMax, yMax, 0)
  tb:updateGrid(tmp1, tmp2)
end

-- Terraforms the heightmap using the given terraforming data.
-- [Also commits the modification to support undo/redo].
local function modifyTerrainFromHeightArray(xSize, ySize, bXMin, bXMax, bYMin, bYMax, tb)
  local history, hCtr = {}, 1
  for x = 0, xSize - 1 do
    local rx = x + bXMin
    for y = 0, ySize - 1 do
      local idx = y * xSize + x
      if mod[idx] > 0.5 then
        local ry = y + bYMin
        local z = final[idx]
        local zOld = max(0, tb:getHeightGrid(rx, ry))
        tb:setHeightGrid(rx, ry, max(0, z))
        history[hCtr] = { old = zOld, new = z, x = rx, y = ry }
        hCtr = hCtr + 1
      end
    end
  end

  -- Update the terrain block.
  tmp1:set(bXMin, bYMin, 0)
  tmp2:set(bXMax, bYMax, 0)
  tb:updateGrid(tmp1, tmp2)
  editor_terrainEditor.setTerrainDirty()

  -- Commit the terraforming action to the undo/redo history.
  editor.history:commitAction("Terraform", history, terraformUndo, terraformRedo, true)
end

-- Blurs the heightmap using the given radius. When preserveMask is set, mask==1 vertices are held
-- at their exact source height (their neighbours still blend toward that height): the terraformed
-- surface itself is authoritative and must not be smoothed down at its edges (else roads / sidewalks
-- on an embankment sink below their meshes and appear to float).
local function blur(xSize, ySize, preserveMask)
  -- X pass.
  table.clear(globalTemp)
  for x = 0, xSize - 1 do
    for y = 0, ySize - 1 do
      local idx = y * xSize + x
      if preserveMask and mask[idx] == 1 then
        globalTemp[idx] = final[idx] -- Keep the authoritative surface height as the blend source.
      else
        local sum, count = 0.0, 0
        local yTimesXSize = y * xSize
        for dx = -globalSmoothRadius, globalSmoothRadius do
          local nx = x + dx
          local nIdx = yTimesXSize + nx
          if nx >= 0 and nx < xSize then
            sum = sum + final[nIdx]
            count = count + 1
          end
        end
        globalTemp[idx] = count > 0 and sum / count or final[idx]
      end
    end
  end

  -- Y pass (with fade-in for outer non-modified points near mod zone).
  for x = 0, xSize - 1 do
    for y = 0, ySize - 1 do
      local idx = y * xSize + x
      local isMod = mod[idx] == 1
      if not (preserveMask and mask[idx] == 1) then
        local sum, count = 0.0, 0
        local influence = 0
        for dy = -globalSmoothRadius, globalSmoothRadius do
          local ny = y + dy
          if ny >= 0 and ny < ySize then
            local nIdx = ny * xSize + x
            sum = sum + globalTemp[nIdx]
            count = count + 1
            influence = influence + (mod[nIdx] or 0)
          end
        end
        if isMod then
          final[idx] = count > 0 and sum / count or globalTemp[idx]
        elseif influence > 0 then -- Blend softened final value toward blur only if neighbours were affected.
          local w = clamp(influence / (2 * globalSmoothRadius + 1), 0, 1)
          final[idx] = lerp(final[idx], sum / count, w)
        end
      end
    end
  end
end

-- Fractal Brownian Motion.
local function fbm(x, y, octaves, lacunarity, gain)
  local total, frequency, amplitude, maxAmplitude = 0, 1, 1, 0
  for _ = 1, octaves do
    total = total + simplex.noise(x * frequency, y * frequency) * amplitude
    maxAmplitude = maxAmplitude + amplitude
    amplitude = amplitude * gain
    frequency = frequency * lacunarity
  end
  return total / maxAmplitude
end

-- Attempts to update the SDF for the given grid point, if better than the current value.
local function tryUpdate(x, y, nx, ny, xSize, ySize)
  if nx < 0 or ny < 0 or nx > xSize or ny > ySize then
    return
  end
  local nIdx = ny * xSize + nx
  local cx, cy = closestX[nIdx], closestY[nIdx]
  if cx and cy and cx >= 0 and cy >= 0 then
    local dx, dy = x - cx, y - cy
    local dist = dx * dx + dy * dy
    local idx = y * xSize + x
    if dist < sdf[idx] * sdf[idx] then
      sdf[idx] = sqrt(dist)
      closestX[idx], closestY[idx] = cx, cy
    end
  end
end

-- Two forward/backward sweeps that propagate the seeded (sdf=0) cells outward into an approximate SDF.
local function propagateSDF(xSize, ySize)
  for _ = 1, 2 do
    for x = 0, xSize - 1 do
      for y = 0, ySize - 1 do
        tryUpdate(x, y, x - 1, y, xSize, ySize)
        tryUpdate(x, y, x + 1, y, xSize, ySize)
        tryUpdate(x, y, x, y - 1, xSize, ySize)
        tryUpdate(x, y, x, y + 1, xSize, ySize)
      end
    end
    for x = xSize - 1, 0, -1 do
      for y = ySize - 1, 0, -1 do
        tryUpdate(x, y, x - 1, y, xSize, ySize)
        tryUpdate(x, y, x + 1, y, xSize, ySize)
        tryUpdate(x, y, x, y - 1, xSize, ySize)
        tryUpdate(x, y, x, y + 1, xSize, ySize)
      end
    end
  end
end

-- Shared tail for all terraform entry points: given a populated mask/height field over the
-- grid window [bXMin..bXMax] x [bYMin..bYMax], propagate the SDF, diffuse the heightmap out to
-- the DOI, optionally add noise, smooth, and commit (with undo). Assumes the caller has already
-- filled height/mask/sdf/mod/closestX/closestY for every vertex in the window.
-- 'apronCells' holds a flat margin of that many grid cells at the surface height before the falloff
-- starts (a smooth skirt, unlike a frozen shelf), giving a gentle, non-jaggy transition to terrain.
-- 'protect' (optional) is a predicate protect(worldX, worldY) -> bool: any modified cell whose world XY it
-- rejects is left at its original height (dropped from the write set). Used to keep an external keep-out
-- region (e.g. the transport network's 1-ring) untouched while terraforming buildings around it.
local function finishTerraform(DOI, falloffExp, roughness, scale, xSize, ySize, bXMin, bXMax, bYMin, bYMax, tb, te, preserveMask, apronCells, passes, protect)
  apronCells = apronCells or 0
  local nPasses = passes or smoothPasses
  local reach = DOI + apronCells
  local DOIInv = 1.0 / DOI

  propagateSDF(xSize, ySize)

  -- Commit: mask cells keep their held height; a cell within reach blends from the original terrain toward
  -- its nearest surface height by the falloff weight; everything else stays at the original terrain.
  table.clear(final)
  for x = 0, xSize - 1 do
    local rx = bXMin + x
    for y = 0, ySize - 1 do
      local idx = y * xSize + x
      if mask[idx] == 1 then
        final[idx] = height[idx]
        mod[idx] = 1
      elseif sdf[idx] <= reach then
        local cx, cy = closestX[idx], closestY[idx]
        local o = tb:getHeightGrid(rx, bYMin + y)
        if cx and cy and cx >= 0 and cy >= 0 then
          local srcH = height[cy * xSize + cx]
          local eff = sdf[idx] - apronCells
          if eff < 0 then eff = 0 end
          local w = clamp((1.0 - eff * DOIInv) ^ falloffExp, 0, 1)
          final[idx] = o + (srcH - o) * w
          mod[idx] = 1
        else
          final[idx] = o
        end
      else
        final[idx] = tb:getHeightGrid(rx, bYMin + y)
      end
    end
  end

  -- Apply noise, if requested.
  if roughness > 0 then
    local noiseFreq, noiseStrength, fbmOctaves, fbmLacunarity, fbmGain = mapNoiseParameters(roughness, scale)
    for x = 0, xSize - 1 do
      local rx = bXMin + x
      for y = 0, ySize - 1 do
        local idx = y * xSize + x
        -- Roughen the transition apron, never the authoritative surface (roads stay flat).
        if mod[idx] == 1 and not (preserveMask and mask[idx] == 1) then
          tmpPoint2I.x, tmpPoint2I.y = rx, bYMin + y
          local pWS = te:gridToWorldByPoint2I(tmpPoint2I, tb)
          local n = fbm(pWS.x * noiseFreq, pWS.y * noiseFreq, fbmOctaves, fbmLacunarity, fbmGain)
          local eff = sdf[idx] - apronCells
          if eff < 0 then eff = 0 end
          local w = clamp((1.0 - eff * DOIInv) ^ falloffExp, 0, 1)
          final[idx] = final[idx] + n * noiseStrength * w
        end
      end
    end
  end

  -- Smoothing passes for the transitions ONLY. preserveMask holds the road + 1-ring EXACT on every pass, so a
  -- locked (paved) cell is never averaged -- it keeps its ribbon grade to the millimetre. Nothing after this
  -- touches a mask cell (the old deep-interior polish did, which put ripples on the pavement; it's gone).
  for _ = 1, nPasses do
    blur(xSize, ySize, preserveMask)
  end

  -- Drop protected cells from the write set (leave them at their original height). Only the world XY of
  -- already-modified cells is tested, so the cost is confined to the touched window.
  if protect then
    for x = 0, xSize - 1 do
      local gx = bXMin + x
      for y = 0, ySize - 1 do
        local idx = y * xSize + x
        if mod[idx] > 0.5 then
          tmpPoint2I.x, tmpPoint2I.y = gx, bYMin + y
          local pWS = te:gridToWorldByPoint2I(tmpPoint2I, tb)
          if protect(pWS.x, pWS.y) then mod[idx] = 0 end
        end
      end
    end
  end

  -- Set the final changes in the terrain and manage undo/redo history.
  modifyTerrainFromHeightArray(xSize, ySize, bXMin, bXMax, bYMin, bYMax, tb)
end

-- Terraform heightmap based on quad weights and an SDF falloff.
-- Terraforms the current heightmap using the given terraforming data.
-- The sources structure is an array containing each source element (eg a road).
-- Each source element is an array containing ordered polyline points with the following structure:
-- { pos = vec3(x, y, z), width = f, binormal = vec3(x, y, z) }.
-- 'DOI' (Domain of Influence) is the max distance at which the terraforming will affect, in meters.
-- 'margin' is the distance which the terraforming will affect the outer edge of the sources, in meters.
-- 'falloffExp' is the falloff exponent for the terraforming.
-- 'roughness' and 'scale' are the roughness and scale of the noise, respectively.
local function terraformToSources(DOI, margin, falloffExp, roughness, scale, sources)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  if not sources or not tb or not te then
    return -- Early return if no sources, terrain block, or terrain editor.
  end

  -- Remove all spline meshes before terraforming to prevent collision mesh conflicts.
  toolMgr.removeAllSplineToolMeshes()

  -- Get the terrain block's world box.
  local extents = tb:getWorldBox():getExtents()
  local center = tb:getWorldBox():getCenter()
  local centerX, centerY = center.x, center.y
  local xHalf, yHalf = extents.x * 0.5, extents.y * 0.5
  local tXMin, tXMax = centerX - xHalf, centerX + xHalf
  local tYMin, tYMax = centerY - yHalf, centerY + yHalf
  local zMin = tb:getPosition().z

  -- Get the AABB of the union of sources.
  local box = geom.computeSourcesAABB(sources)
  DOI = max(5.0, DOI)
  local boxPad = DOI * doiMultFactor -- Expand the AABB by more than the DOI, to ensure fall off to zero.
  box.xMin = box.xMin - boxPad
  box.xMax = box.xMax + boxPad
  box.yMin = box.yMin - boxPad
  box.yMax = box.yMax + boxPad

  -- Get the grid bounds of the union of sources.
  tmp1:set(floor(max(tXMin, box.xMin)), floor(max(tYMin, box.yMin)), 0)
  tmp2:set(ceil(min(tXMax, box.xMax)), ceil(min(tYMax, box.yMax)), 0)
  te:worldToGridByPoint2I(tmp1, gMin, tb)
  te:worldToGridByPoint2I(tmp2, gMax, tb)
  local bXMin, bXMax, bYMin, bYMax = gMin.x, gMax.x, gMin.y, gMax.y
  local xSize, ySize = bXMax - bXMin + 1, bYMax - bYMin + 1

  -- Get the quadrilaterals of the sources and populate a kd-tree with them.
  local quads = geom.getAllQuadrilaterals(sources, margin)
  local tree = geom.populateTreeQuads(quads)

  -- Initialize the height, mask, SDF, and closest X/Y arrays.
  table.clear(mod); table.clear(mask);
  table.clear(height); table.clear(sdf);
  table.clear(closestX); table.clear(closestY)
  for x = 0, xSize - 1 do
    local gX = bXMin + x
    for y = 0, ySize - 1 do
      local idx = y * xSize + x
      local gY = bYMin + y
      tmpPoint2I.x, tmpPoint2I.y = gX, gY
      local pWS = te:gridToWorldByPoint2I(tmpPoint2I, tb)
      local pWSX, pWSY, z = pWS.x, pWS.y, nil
      for tIdx in tree:queryNotNested(pWSX, pWSY, pWSX, pWSY) do
        local hitZ = geom.intersectsUpQuadBarycentric(pWS, quads[tIdx]) -- Sample using bilinear interpolation over the quad.
        if hitZ then
          z = min(hitZ - zMin, z or huge)
        end
      end
      if z then -- This grid point is directly underneath the source, so it's a mask.
        height[idx] = z -- Use the sampled height of the source here.
        mask[idx] = 1
        sdf[idx] = 0 -- Set the SDF here, since we know its zero.
        mod[idx] = 1
        closestX[idx], closestY[idx] = x, y
      else -- This grid point is not directly underneath the source, so it's not a mask.
        height[idx] = tb:getHeightGrid(gX, gY) -- Use the original terrain height here.
        mask[idx] = 0
        sdf[idx] = huge -- Set the SDF to infinity for now.
        mod[idx] = 0
        closestX[idx], closestY[idx] = -1, -1
      end
    end
  end

  finishTerraform(DOI, falloffExp, roughness, scale, xSize, ySize, bXMin, bXMax, bYMin, bYMax, tb, te)
end

-- Terraform the heightmap from explicit features, with cell-overlap 1-ring support and per-feature
-- mode. Each feature is either:
--   { quad = { v1, v2, v3, v4 }, mode = 'carve'|'fill' }   -- 4 world-space vec3 corners (u across
--       v1->v2, v along v1->v3; corner z carries banking / portal taper), or
--   { rings = { ring, ... }, z = worldZ, mode = 'carve'|'fill' } -- flat multi-polygon (junctions);
--       each ring is an ordered list of vec3.
-- 'carve' claims are authoritative and combine by min (excavation authority = the min rule). 'fill'
-- claims only raise terrain that is below the target (deep terrain is left untouched) and combine by
-- max. Where a cell is claimed by both, carve wins (open roads are never buried). Between two DIFFERENT
-- surfaces a footprint cell and a 1-ring support cell are treated identically -- the lowest carve wins, so
-- a road passing over another (its surface high overhead) can never raise the lower road's supported
-- shoulder; it simply floats above the min-carved terrain until it is bridged. One surface's own claims
-- are resolved differently (footprint first, then nearest support): see combine.
-- 'priority' (optional, default 0): the DEFAULT band a feature claims cells at, both within this call and in
-- the persistent occupancy mask (see PRIO / occZ). Each feature may override it with f.priority, so a mixed set
-- (roads > structures > paths) can be terraformed in ONE call and get a single shared transition/blur instead
-- of a per-band seam. A footprint + 1-ring cell owned at a HIGHER priority (e.g. a road, when this is a building
-- pass) is held at the owner's height and never rewritten; at the SAME priority the min rule applies; a HIGHER
-- priority claim overrides a lower one unconditionally. This is the shared keep-out that gives transport
-- absolute priority over everything, with no per-call lock set to thread around.
local function terraformToQuads(DOI, margin, falloffExp, roughness, scale, features, passes, protect, priority)
  priority = priority or 0
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  if not features or #features == 0 or not tb or not te then
    return
  end

  toolMgr.removeAllSplineToolMeshes()

  local extents = tb:getWorldBox():getExtents()
  local center = tb:getWorldBox():getCenter()
  local xHalf, yHalf = extents.x * 0.5, extents.y * 0.5
  local tXMin, tXMax = center.x - xHalf, center.x + xHalf
  local tYMin, tYMax = center.y - yHalf, center.y + yHalf
  local zMin = tb:getPosition().z
  local squareSize = tb:getSquareSize()
  -- Footprint rasterisation tolerance: a cell is claimed as footprint if its centre is inside the surface
  -- polygon OR within half a grid cell of its edge. That conservative half-cell skin means a ribbon narrower
  -- than one cell still stamps a continuous line of cells (no dropouts / peel-up) without reaching a whole
  -- cell past the true edge. The 1-ring support is then a STRICT one-cell dilation of this footprint (added
  -- after the merge) -- exactly the ring the bilinear patch needs to not sag at the edge, and never more.
  local halfCell2 = (squareSize * 0.5) * (squareSize * 0.5)
  -- Window pad (grid cells) for the per-feature raster scan: half-cell skin + one cell of index slack.
  local stampPad = 2
  local apronCells = (squareSize > 0) and (max(0, margin or 0) / squareSize) or 0

  -- Union XY AABB of all feature geometry.
  local fXMin, fXMax, fYMin, fYMax = huge, -huge, huge, -huge
  local function accBounds(p)
    local x, y = p.x, p.y
    if x < fXMin then fXMin = x end
    if x > fXMax then fXMax = x end
    if y < fYMin then fYMin = y end
    if y > fYMax then fYMax = y end
  end
  for i = 1, #features do
    local f = features[i]
    if f.quad then
      accBounds(f.quad[1]); accBounds(f.quad[2]); accBounds(f.quad[3]); accBounds(f.quad[4])
    elseif f.rings then
      for r = 1, #f.rings do
        local ring = f.rings[r]
        for k = 1, #ring do accBounds(ring[k]) end
      end
    end
  end
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
  local bXMin, bXMax, bYMin, bYMax = gMin.x, gMax.x, gMin.y, gMax.y
  local xSize, ySize = bXMax - bXMin + 1, bYMax - bYMin + 1
  if xSize < 1 or ySize < 1 then
    return
  end

  -- Reset accumulators.
  table.clear(cH); table.clear(cM); table.clear(cP)
  table.clear(fH); table.clear(fM); table.clear(fP)
  table.clear(dH); table.clear(dM); table.clear(dP)
  for i = 0, xSize * ySize - 1 do
    cM[i] = 0; fM[i] = 0; dM[i] = 0
  end

  -- Local grid-index window (padded) covering a world XY AABB.
  local function gridRange(aXMin, aXMax, aYMin, aYMax)
    tmp1:set(aXMin, aYMin, 0); te:worldToGridByPoint2I(tmp1, gMin, tb)
    tmp2:set(aXMax, aYMax, 0); te:worldToGridByPoint2I(tmp2, gMax, tb)
    local x0 = max(0, min(gMin.x, gMax.x) - stampPad - bXMin)
    local x1 = min(xSize - 1, max(gMin.x, gMax.x) + stampPad - bXMin)
    local y0 = max(0, min(gMin.y, gMax.y) - stampPad - bYMin)
    local y1 = min(ySize - 1, max(gMin.y, gMax.y) + stampPad - bYMin)
    return x0, x1, y0, y1
  end

  -- Stamp a ribbon quad's FOOTPRINT: every cell inside the quad, plus the half-cell edge skin (so a ribbon
  -- narrower than one cell still lands a continuous line of cells). No support ring here -- that's the
  -- one-cell dilation after the merge. Height is the bilinear grade at the cell (or its nearest edge point).
  local function stampQuad(quad, mode, prio)
    local q1, q2, q3, q4 = quad[1], quad[2], quad[3], quad[4]
    local x0, x1, y0, y1 = gridRange(
      min(q1.x, q2.x, q3.x, q4.x), max(q1.x, q2.x, q3.x, q4.x),
      min(q1.y, q2.y, q3.y, q4.y), max(q1.y, q2.y, q3.y, q4.y))
    for x = x0, x1 do
      tmpPoint2I.x = bXMin + x
      for y = y0, y1 do
        tmpPoint2I.y = bYMin + y
        local pWS = te:gridToWorldByPoint2I(tmpPoint2I, tb)
        -- geom.quadUV, not LuaVec3:invBilinear2D: the latter's fixed choice of quadratic root reports every
        -- interior cell of a widening/narrowing segment as outside the footprint, so the whole segment took
        -- its height from the quad boundary at the wrong station along the ribbon -- a downward-biased (min
        -- rule) error proportional to the grade, which is why carved roads came out bumpy on inclines and
        -- sat below their own smooth ribbon.
        local u, v = geom.quadUV(pWS.x, pWS.y, q1, q2, q3, q4)
        local uc, vc, hit
        if u ~= nil then
          uc, vc, hit = u, v, true
        else
          local nu, nv, d2 = quadNearestUV(pWS.x, pWS.y, q1, q2, q3, q4)
          if d2 <= halfCell2 then uc, vc, hit = nu, nv, true end
        end
        if hit then
          local z = lerp(lerp(q1.z, q2.z, uc), lerp(q3.z, q4.z, uc), vc) - zMin
          accumulate(y * xSize + x, z, mode, prio)
        end
      end
    end
  end

  -- Stamp a junction's FOOTPRINT: cells inside its sealed polygon(s), plus the half-cell edge skin. Level z
  -- (the hub grade). No support ring here -- the one-cell dilation after the merge adds it.
  local function stampRings(rings, zWorld, mode, prio)
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
    local x0, x1, y0, y1 = gridRange(aXMin, aXMax, aYMin, aYMax)
    for x = x0, x1 do
      tmpPoint2I.x = bXMin + x
      for y = y0, y1 do
        tmpPoint2I.y = bYMin + y
        local pWS = te:gridToWorldByPoint2I(tmpPoint2I, tb)
        local hit = false
        for r = 1, #rings do
          if pWS:inPolygon(rings[r]) then hit = true; break end
        end
        if not hit then
          local best2 = huge
          for r = 1, #rings do
            local ring = rings[r]
            local m = #ring
            for k = 1, m do
              local d = pWS:distanceToLineSegment(ring[k], ring[(k % m) + 1])
              if d * d < best2 then best2 = d * d end
            end
          end
          hit = best2 <= halfCell2
        end
        if hit then
          accumulate(y * xSize + x, zLocal, mode, prio)
        end
      end
    end
  end

  for i = 1, #features do
    local f = features[i]
    local mode = f.mode or 'carve'
    local prio = f.priority or priority
    if f.quad then
      stampQuad(f.quad, mode, prio)
    elseif f.rings then
      stampRings(f.rings, f.z or zMin, mode, prio)
    end
  end

  -- Priority: ground carve (roads/rail/paths, min) wins any overlap; then a bridge cut lowers terrain
  -- that pokes above the deck underside (never raises); then a tunnel fill raises cover over a bore.
  -- Every claim is reconciled against the persistent occupancy mask (occZ/occPrio) so that, across ALL passes,
  -- a higher-priority surface (transport) can never be overwritten or lifted by a lower one, and equal
  -- priorities settle to the lowest carve.
  for x = 0, xSize - 1 do
    local gX = bXMin + x
    for y = 0, ySize - 1 do
      local idx = y * xSize + x
      local gY = bYMin + y
      -- Pick the winning footprint claim: highest priority wins; carve > cut > fill breaks a priority tie.
      -- cut/fill only apply where terrain actually poked into their zone (cut lowers a knoll under a deck; fill
      -- raises cover over a bore) -- elsewhere they leave no footprint.
      local srcZ, srcPrio
      if cM[idx] > 0 then srcZ, srcPrio = cH[idx], cP[idx] end
      if dM[idx] > 0 and (srcPrio == nil or dP[idx] > srcPrio) and tb:getHeightGrid(gX, gY) > dH[idx] then
        srcZ, srcPrio = dH[idx], dP[idx]
      end
      if fM[idx] > 0 and (srcPrio == nil or fP[idx] > srcPrio) and tb:getHeightGrid(gX, gY) < fH[idx] then
        srcZ, srcPrio = fH[idx], fP[idx]
      end
      local key = gX * MASK_STRIDE + gY
      local oPrio = occPrio[key]
      if oPrio and oPrio > (srcPrio or priority) then
        -- Owned by a higher-priority surface (e.g. a road cell during the building pass): hold it at the owner's
        -- height so the blend can't lower it, and don't rewrite it (a no-op that keeps the driving surface exact).
        height[idx] = occZ[key]; mask[idx] = 1; sdf[idx] = 0; mod[idx] = 0
        prioArr[idx] = oPrio
        closestX[idx], closestY[idx] = x, y
      elseif srcZ then
        local winZ = srcZ
        if oPrio == srcPrio and occZ[key] < winZ then winZ = occZ[key] end -- same priority: min rule
        occZ[key] = winZ; occPrio[key] = srcPrio
        height[idx] = winZ; mask[idx] = 1; sdf[idx] = 0; mod[idx] = 1
        prioArr[idx] = srcPrio
        closestX[idx], closestY[idx] = x, y
      else
        height[idx] = tb:getHeightGrid(gX, gY); mask[idx] = 0; sdf[idx] = huge; mod[idx] = 0
        prioArr[idx] = -1
        closestX[idx], closestY[idx] = -1, -1
      end
    end
  end

  -- 1-ring support = STRICT one-cell dilation of the merged footprint. Any non-footprint cell that touches a
  -- footprint cell (8-neighbourhood) is claimed for the HIGHEST-priority adjacent footprint (so a road's ring
  -- belongs to the road and a neighbouring path can never claim it), held at the LOWEST grade among that
  -- priority's adjacent footprints (roads win, the ring can never lift the edge). Exactly one ring, never a
  -- metre more. Collected against the pre-dilation mask, then applied, so a fresh support cell can't seed a
  -- second ring.
  local ringIdx, ringZ, ringP, nRing = {}, {}, {}, 0
  for x = 0, xSize - 1 do
    for y = 0, ySize - 1 do
      local idx = y * xSize + x
      if mask[idx] == 0 then
        local bestP, bestZ = -1, huge
        for dy = -1, 1 do
          local ny = y + dy
          if ny >= 0 and ny < ySize then
            local base = ny * xSize + x
            for dx = -1, 1 do
              local nx = x + dx
              if nx >= 0 and nx < xSize then
                local nIdx = base + dx
                if mask[nIdx] == 1 then
                  local np = prioArr[nIdx]
                  if np > bestP then bestP, bestZ = np, height[nIdx]
                  elseif np == bestP and height[nIdx] < bestZ then bestZ = height[nIdx] end
                end
              end
            end
          end
        end
        if bestP >= 0 then
          nRing = nRing + 1; ringIdx[nRing] = idx; ringZ[nRing] = bestZ; ringP[nRing] = bestP
        end
      end
    end
  end
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
      occZ[key] = winZ; occPrio[key] = prio
      height[idx] = winZ; mask[idx] = 1; sdf[idx] = 0; mod[idx] = 1
      prioArr[idx] = prio
      closestX[idx], closestY[idx] = x, y
    end
  end

  -- preserveMask: keep carved road / junction cells exactly at the ribbon height (no smoothing down).
  -- apronCells: smooth flat skirt of 'margin' metres before the falloff (avoids a jaggy frozen shelf).
  finishTerraform(DOI, falloffExp, roughness, scale, xSize, ySize, bXMin, bXMax, bYMin, bYMax, tb, te, true, apronCells, passes, protect)
end


-- Public interface.
M.PRIO =                                                PRIO
M.resetMask =                                           resetMask
M.terraformToSources =                                  terraformToSources
M.terraformToQuads =                                    terraformToQuads

return M