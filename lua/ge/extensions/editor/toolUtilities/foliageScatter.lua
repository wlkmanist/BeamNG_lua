-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = 'foliageScatter'

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')

-- Module constants.
local floor, sin, cos, sqrt, pi = math.floor, math.sin, math.cos, math.sqrt, math.pi
local min, max, ceil, atan2, abs = math.min, math.max, math.ceil, math.atan2, math.abs
local twoPi = pi * 2.0
local kR2AlphaX = 0.7548776662466927 -- R2 low-discrepancy sequence constants. alpha_d = 1 / g^d, g solves g^3 = g + 1.
local kR2AlphaY = 0.5698402909980532
local classPresets = { -- Per-class distribution defaults.
  forest  = { spacingM = 6.0,  scaleVariance = 0.20 },
  dense   = { spacingM = 4.0,  scaleVariance = 0.18 },
  sparse  = { spacingM = 12.0, scaleVariance = 0.22 },
  shrub   = { spacingM = 2.5,  scaleVariance = 0.20 },
  orchard = { spacingM = 7.0,  scaleVariance = 0.08 },
}
local classOrder = { 'forest', 'dense', 'sparse', 'shrub', 'orchard' } -- stable UI ordering
local suggestedSpecies = { 'tree_oak_forest_a', 'tree_beech_forest_a', 'tree_aspen_forest_a' }
local defaultDistribution = {
  class = 'forest',
  spacingM = 6.0,
  densityScale = 1.0,   -- >1 packs more candidates in, <1 thins out (multiplies the candidate count)
  scaleVariance = 0.20, -- 0 = every instance at scale 1.0; higher = wider random spread around 1.0
  alignToNormal = false,
  slopeMaxDeg = 35.0, -- reject ground steeper than this
  seed = 1337,
}
local shrubKeywords = { 'bush', 'shrub', 'fern', 'hedge', 'flower', 'plant', 'grass', 'reed' }
local perZoneInstanceCap = 60000 -- safety cap per zone so a huge polygon can't lock the editor
local drapeEps = 0.005 -- how far off the ground a draped plant may sit before redrape moves it

-- Module state.
local drapedSources = {} -- fn(out) per tool whose plants stand straight on the terrain: appends its item lists
local drapeLists, drapeMinZ = {}, {}


-- Deterministic hash in [0,1) from a float seed + integer salt (sine hash.
local function hash01(seed, salt)
  local s = sin(seed * 12.9898 + (salt or 0) * 78.233) * 43758.5453
  return s - floor(s)
end

-- Sum of three decorrelated hashes -> approx.
local function gauss3(seed, salt)
  return hash01(seed, salt) + hash01(seed, (salt or 0) + 31) + hash01(seed, (salt or 0) + 61)
end

local function fracN(x) return x - floor(x) end

-- Local-space floor of a ForestItemData mesh (AABB minExtents.z).
local function itemBaseMinZ(obj)
  if not obj or not obj.getObjBox then return 0 end
  local ok, box = pcall(function() return obj:getObjBox() end)
  if not ok or not box then return 0 end
  local lo, hi = box.minExtents, box.maxExtents
  if not lo or not hi or hi.z <= lo.z then return 0 end
  return lo.z
end

-- How far a ForestItemData mesh reaches out from its origin across the ground at scale 1 (the AABB's widest horizontal
-- side), so it holds whichever way the item is turned. Only a planted item has a box, so one is planted and taken up again.
local function itemCrownR(fd, obj)
  if not fd or not obj then return 0 end
  local item = fd:createNewItem(obj, MatrixF(true), 1)
  if not item then return 0 end
  local box = item:getObjBox()
  fd:removeItem(item)
  local lo, hi = box.minExtents, box.maxExtents
  return max(-lo.x, hi.x, -lo.y, hi.y, 0)
end

-- Returns the level's Forest object, creating an (empty) one if the level has none.
local function ensureForest()
  local forest = core_forest.getForestObject()
  if not forest then
    forest = worldEditorCppApi.createObject("Forest")
    if not forest then log('E', logTag, 'Could not create a Forest object.'); return nil, nil end
    forest:registerObject("")
    forest:setName("theForest")
    scenetree.MissionGroup:addObject(forest)
    editor.setDirty()
    log('I', logTag, 'Created a Forest object for the level.')
  end
  return forest, forest:getData()
end

-- Lists the ForestItemData names available in the level (sorted). These are the species the tools can plant.
local function listForestItemData()
  local out = {}
  local names = scenetree.findClassObjects("ForestItemData") or {}
  for i = 1, #names do
    local o = scenetree.findObject(names[i])
    if o then
      local nm = (o.getName and o:getName()) or names[i]
      out[#out + 1] = tostring(nm)
    end
  end
  table.sort(out)
  return out
end

-- Picks a sensible default species selection from what the level actually has.
local function defaultSpeciesSelection()
  local sel = {}
  local names = listForestItemData()
  for i = 1, #suggestedSpecies do
    for j = 1, #names do
      if names[j] == suggestedSpecies[i] then sel[names[j]] = true; return sel end
    end
  end
  if names[1] then sel[names[1]] = true end
  return sel
end

-- Like defaultSpeciesSelection but biased to a low shrub.
local function defaultShrubSelection()
  local sel = {}
  local names = listForestItemData()
  for k = 1, #shrubKeywords do
    for j = 1, #names do
      if string.find(string.lower(names[j]), shrubKeywords[k], 1, true) then sel[names[j]] = true; return sel end
    end
  end
  if names[1] then sel[names[1]] = true end
  return sel
end

-- Resolves the ticked species set { name = true } to a pool of { obj, minZ, weight } for planting.
local function resolvePool(species, weights)
  local pool = {}
  if not species then return pool end
  local names = {}
  if species[1] ~= nil then -- array form
    for i = 1, #species do names[#names + 1] = species[i] end
  else -- set form { name = true }
    for nm, on in pairs(species) do if on then names[#names + 1] = nm end end
  end
  table.sort(names)
  for i = 1, #names do
    local obj = scenetree.findObject(names[i])
    if obj then
      local w = weights and weights[names[i]]
      if w == nil then w = 1.0 end
      pool[#pool + 1] = { obj = obj, name = names[i], minZ = itemBaseMinZ(obj), weight = (w > 0) and w or 0 }
    end
  end
  return pool
end

-- Removes a list of planted forest items (from a previous scatter of the same zone).
local function removeItems(fd, items)
  if not fd or not items then return end
  for i = 1, #items do
    if items[i] then fd:removeItem(items[i]) end
  end
  table.clear(items)
end

--- A tool's live planting taken out of the forest for a level save, which writes the forest as it finds it. Each list keeps
--- its slots, and `relay` puts the same items back into them once the save is done.
local function lift(lists)
  local forest = core_forest and core_forest.getForestObject()
  local fd = forest and forest:getData()
  if not fd then return nil end
  local held = { fd = fd }
  for l = 1, #lists do
    local items, rec = lists[l], {}
    for i = 1, #items do
      local it = items[i]
      if it then
        rec[i] = { it:getData(), editor.matrixToTable(it:getTransform()), it:getScale() }
        fd:removeItem(it)
      end
    end
    held[l] = { items = items, rec = rec }
  end
  return held
end

local function relay(held)
  if not held then return end
  for l = 1, #held do
    local h = held[l]
    for i, r in pairs(h.rec) do h.items[i] = held.fd:createNewItem(r[1], editor.tableToMatrix(r[2]), r[3]) end
  end
end

-- Builds a flat {x=,y=} ring (dropping z) for the fast even-odd point-in-polygon test.
local function to2DRing(ring)
  local out = {}
  for i = 1, #ring do out[i] = { x = ring[i].x, y = ring[i].y } end
  return out
end

-- Poisson spacing acceleration grid: bucketed placed points so a candidate can reject in O(1) if anything
-- already sits within minDist.
local function newSpacingGrid(cell)
  return { cell = max(0.25, cell or 1.0), buckets = {} }
end

local function spacingFree(grid, x, y, minDist)
  local cell = grid.cell
  local cx, cy = floor(x / cell), floor(y / cell)
  local minSq = minDist * minDist
  local buckets = grid.buckets
  for gx = cx - 1, cx + 1 do
    local col = buckets[gx]
    if col then
      for gy = cy - 1, cy + 1 do
        local list = col[gy]
        if list then
          for k = 1, #list do
            local p = list[k]
            local dx, dy = p.x - x, p.y - y
            if dx * dx + dy * dy < minSq then return false end
          end
        end
      end
    end
  end
  return true
end

local function spacingStamp(grid, x, y)
  local cell = grid.cell
  local cx, cy = floor(x / cell), floor(y / cell)
  local col = grid.buckets[cx]
  if not col then col = {}; grid.buckets[cx] = col end
  local list = col[cy]
  if not list then list = {}; col[cy] = list end
  list[#list + 1] = { x = x, y = y }
end

-- Scatters forest instances inside a polygon and returns the array of placed item handles.
local function scatterArea(params)
  local ring = params.ring
  if not ring or #ring < 3 then return {}, 0 end
  local fd = params.forestData
  if not fd then local _; _, fd = ensureForest() end
  if not fd then return {}, 0 end

  local pool = resolvePool(params.species, params.speciesWeights)
  if #pool < 1 then
    return {}, 0
  end

  -- Species are chosen by weighted random, per placed instance.
  local totalWeight = 0
  for i = 1, #pool do totalWeight = totalWeight + (pool[i].weight or 0) end
  if totalWeight <= 0 then -- all weights zero -> fall back to equal weighting so something still plants
    totalWeight = #pool
    for i = 1, #pool do pool[i].weight = 1 end
  end

  local ring2 = to2DRing(ring)
  local holes2 = {}
  if params.holes then
    for i = 1, #params.holes do holes2[i] = to2DRing(params.holes[i]) end
  end

  local spacing = max(params.spacingM or defaultDistribution.spacingM, 0.5)
  local density = max(params.densityScale or 1.0, 0.01)
  local scaleVar = max(params.scaleVariance or defaultDistribution.scaleVariance or 0, 0)
  local scaleBase = max(params.scaleBase or 1.0, 0.05) -- baseline size multiplier (< 1 = generally smaller plants)
  local alignToNormal = params.alignToNormal == true
  local slopeMaxDeg = params.slopeMaxDeg or defaultDistribution.slopeMaxDeg
  local slopeCosMin = cos(slopeMaxDeg * pi / 180.0)
  local seed = params.seed or 0
  local occupiedFn = params.occupiedFn
  local holdFn = params.holdFn -- true: the spot stays in the plan (and in record) but nothing is planted on it; its slot is false
  local cap = params.maxInstances or perZoneInstanceCap
  local record = params.record

  local aabb = geom.getAABB(ring)
  local dx, dy = aabb.xMax - aabb.xMin, aabb.yMax - aabb.yMin
  if dx <= 0 or dy <= 0 then return {}, 0 end

  local areaPerTree = max(spacing * spacing, 0.25)
  local numCandidates = ceil((dx * dy) / areaPerTree * density)
  numCandidates = min(numCandidates, cap * 4) -- keep the loop bounded on huge polygons
  if numCandidates <= 0 then return {}, 0 end

  local perturb = spacing * 0.5 / 3.0
  local minDist = spacing * 0.8
  local grid = newSpacingGrid(minDist)

  local items = {}
  local rx, ry = 0.5, 0.5
  local sx = 0.5 + fracN(seed * kR2AlphaX)
  local sy = 0.5 + fracN(seed * kR2AlphaY)
  rx, ry = fracN(sx), fracN(sy)

  local pose, pos, rot, nrm = MatrixF(true), vec3(0, 0, 0), vec3(0, 0, 0), vec3(0, 0, 1)
  local placed = 0

  for i = 1, numCandidates do
    local bx = aabb.xMin + rx * dx
    local by = aabb.yMin + ry * dy

    if geom.pointInRing2D(bx, by, ring2) then
      -- Reject candidates inside any hole ring.
      local inHole = false
      for h = 1, #holes2 do
        if geom.pointInRing2D(bx, by, holes2[h]) then inHole = true; break end
      end
      if not inHole then
        local cseed = seed + i * 0.6180339887498949
        local px = bx + (gauss3(cseed, 1) - 1.5) * perturb
        local py = by + (gauss3(cseed, 2) - 1.5) * perturb

        local blocked = occupiedFn and occupiedFn(px, py, minDist * 0.5) or false
        if not blocked and spacingFree(grid, px, py, minDist) then
          pos:set(px, py, 0)
          local slopeOk = true
          if slopeMaxDeg < 89.0 then
            geom.getTerrainNormalInPlace(pos, nrm)
            if nrm.z < slopeCosMin then slopeOk = false end
          end
          if slopeOk then
            -- Weighted-random species per placed instance (uncorrelated with position -> no banding).
            local pick
            local r = hash01(cseed, 5) * totalWeight
            local acc = 0
            for pi = 1, #pool do
              acc = acc + (pool[pi].weight or 0)
              if r <= acc then pick = pool[pi]; break end
            end
            pick = pick or pool[#pool]
            -- Size: baseline scaleBase, plus a symmetric random spread of amplitude scaleVar around it, floored positive.
            local scale = max(0.05, scaleBase * (1.0 + (hash01(cseed, 3) * 2.0 - 1.0) * scaleVar))
            local yaw = hash01(cseed, 4) * twoPi
            pos.z = (core_terrain.getTerrainHeight(pos) or 0) - (pick.minZ or 0) * scale
            if alignToNormal then
              -- Tilt local up toward the terrain normal (approx. euler from the normal), plus yaw.
              rot:set(atan2(nrm.y, nrm.z), -atan2(nrm.x, nrm.z), yaw)
            else
              rot:set(0, 0, yaw)
            end
            pose:setFromEuler(rot)
            pose:setPosition(pos)
            items[#items + 1] = not (holdFn and holdFn(px, py, pick.name, scale)) and fd:createNewItem(pick.obj, pose, scale)
            if record then
              record[#record + 1] = { x = px, y = py, sp = pick.name, s = scale, a = yaw,
                                      rx = alignToNormal and rot.x or nil, ry = alignToNormal and rot.y or nil }
            end
            spacingStamp(grid, px, py)
            placed = placed + 1
            if placed >= cap then break end
          end
        end
      end
    end

    -- Advance the R2 sequence.
    rx = fracN(rx + kR2AlphaX)
    ry = fracN(ry + kR2AlphaY)
  end

  log('D', logTag, string.format('scatterArea: ringVerts=%d pool=%d candidates=%d placed=%d', #ring, #pool, numCandidates, placed))
  return items, placed
end

-- Scatters an evenly-spaced ROW of forest instances along a resampled centreline.
local function scatterLine(params)
  local pts = params.divPoints
  if not pts or #pts < 2 then return {}, 0 end
  local fd = params.forestData
  if not fd then local _; _, fd = ensureForest() end
  if not fd then return {}, 0 end

  local pool = resolvePool(params.species, params.speciesWeights)
  if #pool < 1 then
    log('W', logTag, 'scatterLine: no species selected / resolved; nothing planted (tick at least one species).')
    return {}, 0
  end
  local totalWeight = 0
  for i = 1, #pool do totalWeight = totalWeight + (pool[i].weight or 0) end
  if totalWeight <= 0 then totalWeight = #pool; for i = 1, #pool do pool[i].weight = 1 end end

  local spacing = max(params.spacingM or defaultDistribution.spacingM, 0.5)
  local posVar = max(params.posVariance or 0, 0)
  local scaleVar = max(params.scaleVariance or defaultDistribution.scaleVariance or 0, 0)
  local scaleBase = max(params.scaleBase or 1.0, 0.05) -- baseline size multiplier (< 1 = generally smaller plants)
  local alignToNormal = params.alignToNormal == true
  local slopeMaxDeg = params.slopeMaxDeg or 89.0
  local slopeCosMin = cos(slopeMaxDeg * pi / 180.0)
  local seed = params.seed or 0
  local occupiedFn = params.occupiedFn
  local cap = params.maxInstances or perZoneInstanceCap
  local binormals = params.binormals

  -- Cumulative arc length over the resampled centreline (2D distance; z is draped later per instance).
  local numPts = #pts
  local cum = { 0.0 }
  for i = 2, numPts do
    local a, b = pts[i - 1], pts[i]
    local dx, dy = b.x - a.x, b.y - a.y
    cum[i] = cum[i - 1] + sqrt(dx * dx + dy * dy)
  end
  local totalLen = cum[numPts]
  if totalLen <= spacing * 0.25 then return {}, 0 end

  local numSlots = floor(totalLen / spacing)
  if numSlots < 1 then return {}, 0 end

  local items = {}
  local pose, pos, rot, nrm = MatrixF(true), vec3(0, 0, 0), vec3(0, 0, 0), vec3(0, 0, 1)
  local placed = 0
  local seg = 2 -- current cumulative index such that cum[seg-1] <= s <= cum[seg]

  for k = 0, numSlots do
    -- Longitudinal jitter keeps the row off a perfect grid; clamp so slots never cross.
    local jitterAlong = (hash01(seed, k * 2 + 1) * 2.0 - 1.0) * posVar * spacing * 0.5
    local s = min(totalLen, max(0.0, k * spacing + jitterAlong))

    while seg < numPts and cum[seg] < s do seg = seg + 1 end
    local a, b = pts[seg - 1], pts[seg]
    local segLen = cum[seg] - cum[seg - 1]
    local t = (segLen > 1e-6) and ((s - cum[seg - 1]) / segLen) or 0.0

    local bx = a.x + (b.x - a.x) * t
    local by = a.y + (b.y - a.y) * t

    -- Lateral direction: prefer the supplied binormal, else the 2D perpendicular of the segment dir.
    local lx, ly
    local bn = binormals and (binormals[seg] or binormals[seg - 1])
    if bn then
      lx, ly = bn.x, bn.y
    else
      local dx, dy = b.x - a.x, b.y - a.y
      lx, ly = -dy, dx
    end
    local ln = sqrt(lx * lx + ly * ly)
    if ln > 1e-6 then lx, ly = lx / ln, ly / ln else lx, ly = 0.0, 1.0 end

    local lateral = (hash01(seed, k * 2 + 2) * 2.0 - 1.0) * posVar * spacing * 0.5
    local px = bx + lx * lateral
    local py = by + ly * lateral

    local blocked = occupiedFn and occupiedFn(px, py, spacing * 0.4) or false
    if not blocked then
      pos:set(px, py, 0)
      local slopeOk = true
      if slopeMaxDeg < 89.0 then
        geom.getTerrainNormalInPlace(pos, nrm)
        if nrm.z < slopeCosMin then slopeOk = false end
      end
      if slopeOk then
        local cseed = seed + k * 0.6180339887498949
        local pick
        local r = hash01(cseed, 5) * totalWeight
        local acc = 0
        for pi = 1, #pool do
          acc = acc + (pool[pi].weight or 0)
          if r <= acc then pick = pool[pi]; break end
        end
        pick = pick or pool[#pool]
        local scale = max(0.05, scaleBase * (1.0 + (hash01(cseed, 3) * 2.0 - 1.0) * scaleVar))
        local yaw = hash01(cseed, 4) * twoPi
        pos.z = (core_terrain.getTerrainHeight(pos) or 0) - (pick.minZ or 0) * scale
        if alignToNormal then
          if slopeMaxDeg >= 89.0 then geom.getTerrainNormalInPlace(pos, nrm) end
          rot:set(atan2(nrm.y, nrm.z), -atan2(nrm.x, nrm.z), yaw)
        else
          rot:set(0, 0, yaw)
        end
        pose:setFromEuler(rot)
        pose:setPosition(pos)
        items[#items + 1] = fd:createNewItem(pick.obj, pose, scale)
        placed = placed + 1
        if placed >= cap then break end
      end
    end
  end

  log('D', logTag, string.format('scatterLine: divPts=%d pool=%d len=%.1f slots=%d placed=%d', numPts, #pool, totalLen, numSlots, placed))
  return items, placed
end

-- Places exactly one instance at each supplied world point and returns the placed handles.
local function scatterPoints(params)
  local pts = params.points
  if not pts or #pts < 1 then return {}, 0 end
  local fd = params.forestData
  if not fd then local _; _, fd = ensureForest() end
  if not fd then return {}, 0 end

  local pool = resolvePool(params.species, params.speciesWeights)
  if #pool < 1 then return {}, 0 end
  local totalWeight = 0
  for i = 1, #pool do totalWeight = totalWeight + (pool[i].weight or 0) end
  if totalWeight <= 0 then totalWeight = #pool; for i = 1, #pool do pool[i].weight = 1 end end

  local scaleVar = max(params.scaleVariance or 0, 0)
  local scaleBase = max(params.scaleBase or 1.0, 0.05) -- baseline size multiplier (< 1 = generally smaller plants)
  local seed = params.seed or 0
  local occupiedFn = params.occupiedFn
  local onPointZ = params.onPointZ -- true: seat on each point's own z (+zLift) instead of the terrain (e.g. bushes IN a planter)
  local zLift = params.zLift or 0
  local record = params.record -- see scatterArea: what was actually planted, for a bake to write down
  local items, placed = {}, 0
  local pose, pos, rot = MatrixF(true), vec3(0, 0, 0), vec3(0, 0, 0)
  for i = 1, #pts do
    local p = pts[i]
    local px, py = p.x, p.y
    -- A point may come as a plain table or as a vec3, and only a table can carry a turn to face. Asking a vec3 for a
    -- field it has no member for is an error rather than a nil, so it is never asked.
    local pYaw = (type(p) == 'table') and p.yaw or nil
    if not (occupiedFn and occupiedFn(px, py, 0.5)) then
      local cseed = seed + i * 0.6180339887498949
      local pick, r, acc = nil, hash01(cseed, 5) * totalWeight, 0
      for pi = 1, #pool do acc = acc + (pool[pi].weight or 0); if r <= acc then pick = pool[pi]; break end end
      pick = pick or pool[#pool]
      local scale = max(0.05, scaleBase * (1.0 + (hash01(cseed, 3) * 2.0 - 1.0) * scaleVar))
      pos:set(px, py, 0)
      local baseZ = onPointZ and ((p.z or 0) + zLift) or (core_terrain.getTerrainHeight(pos) or 0)
      pos.z = baseZ - (pick.minZ or 0) * scale
      local yaw = pYaw or hash01(cseed, 4) * twoPi
      rot:set(0, 0, yaw)
      pose:setFromEuler(rot)
      pose:setPosition(pos)
      items[#items + 1] = fd:createNewItem(pick.obj, pose, scale)
      if record then record[#record + 1] = { x = px, y = py, sp = pick.name, s = scale, a = yaw } end
      placed = placed + 1
    end
  end
  return items, placed
end

-- Returns a fresh copy of the default distribution params (for seeding a new zone).
local function getDefaultDistribution() return deepcopy(defaultDistribution) end

-- Returns the class preset table.
local function getClassPresets() return classPresets end

-- Returns the stable class ordering (for UI).
local function getClassOrder() return classOrder end

--- Plant a list of plants that have already been decided: this species, this size, this turn, here. No choosing left to do,
--- so nothing about the result depends on the order they arrive in or on a seed.
local pose1, pos1, rot1 = MatrixF(true), vec3(0, 0, 0), vec3(0, 0, 0)
--- One of them, or nil when its species is not in the level. `byName` caches the species across calls.
local function plantOne(it, fd, byName)
  local sp = byName[it.sp]
  if sp == nil then
    local obj = scenetree.findObject(it.sp)
    sp = obj and { obj = obj, minZ = itemBaseMinZ(obj) } or false
    byName[it.sp] = sp
  end
  if not sp then return nil end
  local scale = it.s or 1
  pos1:set(it.x, it.y, 0)
  -- Seated on the ground under it, the same way it was seated where it was designed. The species' own floor is taken off
  -- so a trunk meets the ground rather than hovering by however deep its root ball is modelled.
  pos1.z = (core_terrain.getTerrainHeight(pos1) or 0) - (sp.minZ or 0) * scale
  rot1:set(it.rx or 0, it.ry or 0, it.a or 0)
  pose1:setFromEuler(rot1)
  pose1:setPosition(pos1)
  return fd:createNewItem(sp.obj, pose1, scale)
end

local function plantItems(items, fd, out)
  local byName = {}
  for i = 1, #items do
    local item = plantOne(items[i], fd, byName)
    if item then out[#out + 1] = item end
  end
end

--- Sow a whole PLAN: a list of anchor groups. A group either names its points and lets the scatter choose what goes on them,
--- or carries the plants themselves already chosen. Both are here because both are what a site honestly has: a bed of shrubs
--- is a recipe, and a wood that was scattered over an area once and must come up the same way again is not.
local function sowGroups(groups, fd)
  local out = {}
  if not fd then local _; _, fd = ensureForest() end
  if not fd then return out end
  for i = 1, #(groups or {}) do
    local g = groups[i]
    if g.items and #g.items > 0 then
      plantItems(g.items, fd, out)
    elseif g.points and #g.points > 0 and next(g.species or {}) ~= nil then
      local got = scatterPoints({ points = g.points, forestData = fd,
                                  species = g.species, speciesWeights = g.speciesWeights,
                                  scaleBase = g.size, scaleVariance = g.vary,
                                  seed = g.seed or 1, onPointZ = not g.drape })
      for k = 1, #got do out[#out + 1] = got[k] end
    end
  end
  return out
end

--- A tool whose plants stand straight on the terrain hands its item lists over here, so the ground moving under them sets
--- them back on it. `fn(out)` appends each list; a slot may be false.
local function addDraped(fn) drapedSources[#drapedSources + 1] = fn end

--- Every draped plant inside the world box set back on the terrain under it, seated the way it was planted. A moved item is
--- written back into its list, so the tool holding it holds the moved one. Returns how many moved.
local function redrape(x0, y0, x1, y1)
  local forest = core_forest and core_forest.getForestObject()
  local fd = forest and forest:getData()
  if not fd then return 0 end
  for i = 1, #drapedSources do drapedSources[i](drapeLists) end
  local n = 0
  for l = 1, #drapeLists do
    local items = drapeLists[l]
    for i = 1, #items do
      local it = items[i]
      local p = it and it:getPosition()
      if p and p.x >= x0 and p.x <= x1 and p.y >= y0 and p.y <= y1 then
        local data = it:getData()
        local nm = data:getName()
        local mz = drapeMinZ[nm]
        if mz == nil then mz = itemBaseMinZ(scenetree.findObject(nm)); drapeMinZ[nm] = mz end
        local scale = it:getScale()
        pos1:set(p.x, p.y, 0)
        pos1.z = (core_terrain.getTerrainHeight(pos1) or 0) - mz * scale
        if abs(pos1.z - p.z) > drapeEps then
          pose1:setFromEuler(it:getTransform():toEuler())
          pose1:setPosition(pos1)
          items[i] = fd:updateItem(it:getKey(), p, data, pose1, scale, it:getUid())
          n = n + 1
        end
      end
    end
  end
  table.clear(drapeLists)
  return n
end


-- Public interface.
M.ensureForest = ensureForest
M.listForestItemData = listForestItemData
M.defaultSpeciesSelection = defaultSpeciesSelection
M.defaultShrubSelection = defaultShrubSelection
M.removeItems = removeItems
M.lift = lift
M.relay = relay
M.scatterArea = scatterArea
M.scatterLine = scatterLine
M.scatterPoints = scatterPoints
M.sowGroups = sowGroups
M.plantOne = plantOne
M.itemCrownR = itemCrownR
M.addDraped = addDraped
M.redrape = redrape
M.getDefaultDistribution = getDefaultDistribution
M.getClassPresets = getClassPresets
M.getClassOrder = getClassOrder

return M