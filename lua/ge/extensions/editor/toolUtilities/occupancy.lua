-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Coarse 2D occupancy grid shared by pier keep-out and vegetation keep-out. The roads are handed in; the Rail Network posts
-- its tracks and junctions through setRail, and both are stamped together.

local M = {}

-- Module dependencies.
local groundClaims = require('editor/toolUtilities/groundClaims')
local geom = require('editor/toolUtilities/geom')

-- Module constants.
local floor, ceil, min, max, sqrt, huge = math.floor, math.ceil, math.min, math.max, math.sqrt, math.huge
local cellSizeM = 1.0
local invCell = 1.0 / cellSizeM
local ribbonPadM = 0.5   -- transport ribbons (roads)
local riverPadM = 1.0    -- extra keep-out beyond the river half-width
local buildingPadM = 1.0 -- extra keep-out beyond the footprint edge
local fencePadM = 0.5    -- fences/walls/hedges (thin lines)
local lakePadM = 1.0     -- extra keep-out beyond the lake shoreline (keeps trees off the water and its bank)
local claimPadM = 0.5    -- ground another tool has surfaced (a placed building, a square, a park); see the claims pass in stampAll
local coarseCells = 8    -- fine cells per side of an overhangAt block

-- Module state.
local originX, originY = 0, 0
local gridW, gridH = 0, 0
local cells = {} -- nil empty, string owner, false = multi-owner (its owners in sharers)
local sharers = {} -- multi-owner cell -> { owner = true }: blocked() passes one its cluster owns outright
local ownerOf = {} -- road / deck / junction owner -> the group or junction it was stamped from
local tmpP, tmpQ = vec3(), vec3()
-- The other tools' claims, in a layer of their own over the same grid: they change far more often than the network does, and
-- restamping them should not mean restamping every road.
local claimCells, claimSharers = {}, {}
local tgt, tgtSharers = cells, sharers -- the layer being stamped
local baseBB = nil       -- the grid's bounds before the claims were added to them
local statRivers = {}    -- { { pts = { {x,y}, ... }, halfW = n }, ... }
local statBuildings = {} -- { { {x,y}, ... }, ... } (filled polygons)
local statFences = {}    -- { { {x,y}, ... }, ... } (thin polylines)
local statLakes = {}     -- { { {x,y}, ... }, ... } (filled shoreline polygons)
local lastGroups, lastJcts, lastClearSegs = nil, nil, nil -- what the grid was last filled from, so a late claim can be stamped without a remesh
local claimSig = nil     -- the claims revision those cells were stamped at; see freshen
local railGet, railRevFn = nil, nil -- the Rail Network's tracks and junction pads, and its revision; see setRail
local stampedRev = nil   -- the rail revision the grid was stamped at
local gridRev = 0        -- bumped whenever any cell is stamped again; see revision
local coarse, coarseW = {}, 0 -- blocks of the grid with a road, rail or junction run stamped in them; see overhangAt
-- Ground only plants keep off, which nothing else here is asked about: PAVED (1), which a trunk may not stand on, and BUILT
-- (2), which a crown may not grow up through either. Handed in by whichever tool lays it; see setPlantKeepOut.
local PAVED, BUILT = 1, 2
local plantCells = {}
local builtCoarse = {} -- the blocks with BUILT cells, as coarse is for roads
local plantGet, plantRevFn = nil, nil
local plantRev = nil     -- the source's revision the plant layer was stamped at
local plantBB = nil      -- the bounds of what it handed in then, which the grid has to cover


-- Padded half-extents (left, right) of a link ribbon.
local function ribbonHalfExtents(g)
  local widths = g.divWidths
  local half = ((widths and widths[1]) or 6) * 0.5
  -- Hard shoulder widens the paved surface, so include its CONSTANT (full) width so trees/props keep off it (the
  -- taper is a surface detail; a conservative constant keep-out along the whole side is correct here).
  return (g.leftExtM or half) + (g.hardShoulderLeftM or 0) + ribbonPadM,
    (g.rightExtM or half) + (g.hardShoulderRightM or 0) + ribbonPadM
end

local function ownerGroup(id) return 'g' .. tostring(id) end

-- A link's stretch on a bridge span: its own owner, so a pier may stand under its own deck but never on the same road where it
-- runs on the ground.
local function ownerDeck(id) return 'g' .. tostring(id) .. 'b' end

-- Under ground, every owner ends in 't': a link's tunnel stretches, a tunnel junction, the ground a tunnel claims for its
-- cover. Plants stand over it (see buried); everything else keeps off it as off any other owner.
local function ownerTunnel(id) return 'g' .. tostring(id) .. 't' end

local function ownerJct(id) return 'j' .. tostring(id) end
local function ownerJctTunnel(id) return 'j' .. tostring(id) .. 't' end

-- A rail track, its bridge stretches and a rail junction: road and rail ids are numbered apart, so they are kept apart here.
local function ownerRail(id) return 'gr' .. tostring(id) end
local function ownerRailDeck(id) return 'gr' .. tostring(id) .. 'b' end
local function ownerRailTunnel(id) return 'gr' .. tostring(id) .. 't' end
local function ownerRailJct(id) return 'jr' .. tostring(id) end

local function buried(owner) return owner:byte(-1) == 116 end -- 't'

-- The roads restamp the grid themselves once they settle; the rail's changes are picked up from its revision.
local function railRev() return railRevFn and railRevFn() or 0 end

local function idx(ix, iy)
  if ix < 0 or iy < 0 or ix >= gridW or iy >= gridH then return nil end
  return iy * gridW + ix + 1
end

local function stampCell(ix, iy, owner)
  local i = idx(ix, iy)
  if not i then return end
  local cur = tgt[i]
  if cur == nil then
    tgt[i] = owner
  elseif cur == false then
    tgtSharers[i][owner] = true
  elseif cur ~= owner then
    tgt[i] = false
    tgtSharers[i] = { [cur] = true, [owner] = true }
  end
end

-- Both layers read as one cell: an owner in each is a shared cell, as if they had been stamped into the same one.
local function cellAt(i)
  local b, c = cells[i], claimCells[i]
  if c == nil then return b end
  if b == nil then return c end
  return false
end

local function worldToCell(x, y)
  return floor((x - originX) * invCell), floor((y - originY) * invCell)
end

-- Road, rail or junction a crown could hang over: not one under ground.
local function isRoadRailOwner(owner)
  local h = owner:byte(1)
  return (h == 103 or h == 106) and not buried(owner) -- 'g' (road/rail) or 'j' (junction)
end

-- Cells ix0..ix1 of row iy (inside the grid) as having road or rail in their blocks; see roadRailNear.
local function markCoarse(iy, ix0, ix1)
  local row = floor(iy / coarseCells) * coarseW + 1
  for cx = floor(ix0 / coarseCells), floor(ix1 / coarseCells) do coarse[row + cx] = true end
end

local function stampDisc(x, y, radius, owner)
  local r = radius + cellSizeM * 0.5
  local ix0, iy0 = worldToCell(x - r, y - r)
  local ix1, iy1 = worldToCell(x + r, y + r)
  local rSq = r * r
  local road = isRoadRailOwner(owner)
  for iy = iy0, iy1 do
    for ix = ix0, ix1 do
      local cx = originX + (ix + 0.5) * cellSizeM
      local cy = originY + (iy + 0.5) * cellSizeM
      local dx, dy = cx - x, cy - y
      if dx * dx + dy * dy <= rSq then
        stampCell(ix, iy, owner)
        if road and idx(ix, iy) then markCoarse(iy, ix, ix) end
      end
    end
  end
end

-- Swept cells are gathered as one run of cells per row and stamped once: neighbouring segments of a line cover nearly the
-- same cells, and stamping each of them again is what made a rebuild slow. All the sweeps of one gather share one owner.
local spanA, spanB, spanRows = {}, {}, {}

local function stampRun(iy, a, b, owner)
  for ix = a, b do stampCell(ix, iy, owner) end
  if isRoadRailOwner(owner) then markCoarse(iy, a, b) end
end

local function addSpan(iy, a, b, owner)
  local pa = spanA[iy]
  if pa then
    local pb = spanB[iy]
    if a <= pb + 1 and b >= pa - 1 then
      spanA[iy], spanB[iy] = min(pa, a), max(pb, b)
      return
    end
    stampRun(iy, pa, pb, owner)
  else
    spanRows[#spanRows + 1] = iy
  end
  spanA[iy], spanB[iy] = a, b
end

local function stampSpans(owner)
  for k = 1, #spanRows do
    local iy = spanRows[k]
    stampRun(iy, spanA[iy], spanB[iy], owner)
    spanA[iy], spanB[iy], spanRows[k] = nil, nil, nil
  end
end

-- The cells whose centres lie within halfW (plus half a cell) of segment ab: the same cells as a disc stamped all along it.
-- Each row meets the capsule in one interval, the hull of where it meets the two end discs and the band between them.
local function sweepSegment(ax, ay, bx, by, halfW, owner)
  local r = halfW + cellSizeM * 0.5
  local rSq = r * r
  local dx, dy = bx - ax, by - ay
  local lSq = dx * dx + dy * dy
  local rLen = r * sqrt(lSq)
  local iy0 = max(0, ceil((min(ay, by) - r - originY) * invCell - 0.5))
  local iy1 = min(gridH - 1, floor((max(ay, by) + r - originY) * invCell - 0.5))
  for iy = iy0, iy1 do
    local cy = originY + (iy + 0.5) * cellSizeM
    local lo, hi = huge, -huge
    local ey = cy - ay
    if ey * ey <= rSq then
      local h = sqrt(rSq - ey * ey)
      lo, hi = ax - h, ax + h
    end
    local fy = cy - by
    if fy * fy <= rSq then
      local h = sqrt(rSq - fy * fy)
      lo, hi = min(lo, bx - h), max(hi, bx + h)
    end
    if lSq > 1e-12 then
      local sLo, sHi = -huge, huge
      local base = ax * dx - ey * dy -- 0 <= (x - ax) * dx + ey * dy <= lSq
      if dx ~= 0 then
        local p, q = base / dx, (base + lSq) / dx
        if p > q then p, q = q, p end
        sLo, sHi = p, q
      elseif ey * dy < 0 or ey * dy > lSq then
        sLo = huge
      end
      local c = dx * ey + dy * ax -- |c - dy * x| <= r * len
      if dy ~= 0 then
        local p, q = (c - rLen) / dy, (c + rLen) / dy
        if p > q then p, q = q, p end
        sLo, sHi = max(sLo, p), min(sHi, q)
      elseif (dx * ey) * (dx * ey) > rLen * rLen then
        sLo = huge
      end
      if sLo <= sHi then lo, hi = min(lo, sLo), max(hi, sHi) end
    end
    if lo <= hi then
      local ix0 = max(0, ceil((lo - originX) * invCell - 0.5))
      local ix1 = min(gridW - 1, floor((hi - originX) * invCell - 0.5))
      if ix0 <= ix1 then addSpan(iy, ix0, ix1, owner) end
    end
  end
end

-- Stamp a whole polyline as a swept disc of the given half-width.
local function stampPolyline(pts, halfW, owner)
  local n = #pts
  if n == 0 then return end
  if n == 1 then stampDisc(pts[1].x, pts[1].y, halfW, owner); return end
  for k = 1, n - 1 do
    sweepSegment(pts[k].x, pts[k].y, pts[k + 1].x, pts[k + 1].y, halfW, owner)
  end
  stampSpans(owner)
end

local function pointInPoly(px, py, poly)
  local inside = false
  local n = #poly
  local j = n
  for i = 1, n do
    local xi, yi = poly[i].x, poly[i].y
    local xj, yj = poly[j].x, poly[j].y
    if ((yi > py) ~= (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi) then
      inside = not inside
    end
    j = i
  end
  return inside
end

local function cellBox(poly)
  local minX, maxX, minY, maxY = huge, -huge, huge, -huge
  for i = 1, #poly do
    local p = poly[i]
    minX, maxX = min(minX, p.x), max(maxX, p.x)
    minY, maxY = min(minY, p.y), max(maxY, p.y)
  end
  local ix0, iy0 = worldToCell(minX, minY)
  local ix1, iy1 = worldToCell(maxX, maxY)
  return ix0, iy0, ix1, iy1
end

-- Every cell in the polygon's box whose centre pointInPoly would call inside, a row at a time: a centre is inside when an odd
-- number of the row's edge crossings lie at or left of it, which is the spans between alternate sorted crossings.
-- Holes are more crossings in the same row, so a cell in one is outside again.
local xs = {}
local function addCrossings(loop, cy, m)
  local n = #loop
  local j = n
  for i = 1, n do
    local xi, yi = loop[i].x, loop[i].y
    local xj, yj = loop[j].x, loop[j].y
    if (yi > cy) ~= (yj > cy) then
      m = m + 1
      xs[m] = (xj - xi) * (cy - yi) / (yj - yi) + xi
    end
    j = i
  end
  return m
end

local function fillCells(poly, holes, fn)
  local ix0, iy0, ix1, iy1 = cellBox(poly)
  for iy = iy0, iy1 do
    local cy = originY + (iy + 0.5) * cellSizeM
    local m = addCrossings(poly, cy, 0)
    for h = 1, #(holes or {}) do m = addCrossings(holes[h], cy, m) end
    for k = #xs, m + 1, -1 do xs[k] = nil end
    if m > 1 then
      table.sort(xs)
      for k = 1, m - 1, 2 do
        local a, b = xs[k], xs[k + 1]
        for ix = max(ix0, floor((a - originX) * invCell - 0.5)), min(ix1, floor((b - originX) * invCell - 0.5) + 1) do
          local cx = originX + (ix + 0.5) * cellSizeM
          if cx >= a and cx < b then fn(ix, iy) end
        end
      end
    end
  end
end

local function stampFill(poly, owner)
  fillCells(poly, nil, function(ix, iy) stampCell(ix, iy, owner) end)
end

-- Fill the interior of a footprint polygon, then stamp its edges so the keep-out includes a pad ring outside.
local function stampPolyFill(poly, owner, pad)
  local n = #poly
  if n < 3 then return end
  stampFill(poly, owner)
  if pad and pad > 0 then
    for i = 1, n do
      local a, b = poly[i], poly[(i % n) + 1]
      sweepSegment(a.x, a.y, b.x, b.y, pad, owner)
    end
    stampSpans(owner)
  end
end

-- Fill the TRUE interior of a junction's sealed polygon (point-in-poly per cell), plus a ribbon-pad skin along
-- its edges. Using the real polygon rather than its axis-aligned bbox stops a skewed/diagonal junction's empty
-- corners from being stamped as keep-out -- those false corners were dropping buildings and excluding trees/piers
-- that actually sat clear of the pad.
local function stampRing(ring, owner)
  if not ring or #ring < 3 then return end
  stampFill(ring, owner)
  local n = #ring
  for i = 1, n do
    local a, b = ring[i], ring[(i % n) + 1]
    sweepSegment(a.x, a.y, b.x, b.y, ribbonPadM, owner)
  end
  stampSpans(owner)
end

local function expandBounds(bb, x, y)
  bb.minX, bb.maxX = min(bb.minX, x), max(bb.maxX, x)
  bb.minY, bb.maxY = min(bb.minY, y), max(bb.maxY, y)
end

local function expandForPts(bb, pts, rad)
  for i = 1, #pts do
    expandBounds(bb, pts[i].x - rad, pts[i].y - rad)
    expandBounds(bb, pts[i].x + rad, pts[i].y + rad)
  end
end

-- The grid over the network and the statics with these claims added: its origin and size, or a size of nothing.
local function gridFor(claimed)
  local bb = { minX = baseBB.minX, maxX = baseBB.maxX, minY = baseBB.minY, maxY = baseBB.maxY }
  local any = baseBB.any
  for i = 1, #claimed do expandForPts(bb, claimed[i], claimPadM); any = true end
  if plantBB then
    expandBounds(bb, plantBB.minX, plantBB.minY)
    expandBounds(bb, plantBB.maxX, plantBB.maxY)
    any = true
  end
  if not any then return 0, 0, 0, 0 end
  local pad = cellSizeM * 2
  return bb.minX - pad, bb.minY - pad, max(1, ceil((bb.maxX - bb.minX + 2 * pad) * invCell) + 1),
         max(1, ceil((bb.maxY - bb.minY + 2 * pad) * invCell) + 1)
end

-- Ground another tool has already surfaced: a placed building's footprint, a plaza, a park. `tags` holds each ring's
-- groundClaims tag; one tagged 'buried' is under ground.
local function stampClaims(claimed, tags)
  gridRev = gridRev + 1
  table.clear(claimCells)
  table.clear(claimSharers)
  tgt, tgtSharers = claimCells, claimSharers
  for i = 1, #claimed do stampPolyFill(claimed[i], tags[i] == 'buried' and 'c' .. i .. 't' or 'c' .. i, claimPadM) end
  tgt, tgtSharers = cells, sharers
end

-- What the plant source hands in now, and the box it spans: nil where it hands in nothing.
local function gatherPlants()
  if not plantGet then return {}, {}, nil end
  local paved, built = plantGet()
  paved, built = paved or {}, built or {}
  local bb = { minX = huge, maxX = -huge, minY = huge, maxY = -huge }
  for i = 1, #paved do expandForPts(bb, paved[i].ring, 0) end
  for i = 1, #built do expandForPts(bb, built[i], 0) end
  return paved, built, (bb.minX <= bb.maxX) and bb or nil
end

local function plantAt(ix, iy, kind)
  local k = idx(ix, iy)
  if not k then return end
  plantCells[k] = kind
  if kind == BUILT then builtCoarse[floor(iy / coarseCells) * coarseW + floor(ix / coarseCells) + 1] = true end
end

-- `paved` is { { ring, holes }, ... }, `built` a list of rings. A built ring's outline is walked as well as filled, so a flight
-- too narrow to hold a cell centre still marks the cells it crosses.
local function stampPlants(paved, built)
  gridRev = gridRev + 1
  table.clear(plantCells)
  table.clear(builtCoarse)
  if gridW < 1 then return end
  for i = 1, #paved do
    fillCells(paved[i].ring, paved[i].holes, function(ix, iy) plantAt(ix, iy, PAVED) end)
  end
  local function asBuilt(ix, iy) plantAt(ix, iy, BUILT) end
  for i = 1, #built do
    local ring = built[i]
    fillCells(ring, nil, asBuilt)
    local n = #ring
    for k = 1, n do
      local a, b = ring[k], ring[k % n + 1]
      local dx, dy = b.x - a.x, b.y - a.y
      local steps = max(1, ceil(sqrt(dx * dx + dy * dy) * 2 * invCell))
      for s = 0, steps - 1 do
        local f = s / steps
        asBuilt(worldToCell(a.x + dx * f, a.y + dy * f))
      end
    end
  end
end

local function expandForGroups(bb, groups)
  local any = false
  for i = 1, #groups do
    local g = groups[i]
    if g and g.isEnabled ~= false and g.divPoints and #g.divPoints >= 2 then
      local lExt, rExt = ribbonHalfExtents(g)
      expandForPts(bb, g.divPoints, max(lExt, rExt))
      any = true
    end
  end
  return any
end

-- Each road or track as its ribbon: one owner where it runs on the ground, others along its bridge and tunnel stretches.
local function stampGroups(groups, clearSegs, owner, deckOwner, tunnelOwner)
  for i = 1, #groups do
    local g = groups[i]
    if g and g.isEnabled ~= false and g.divPoints and g.binormals and #g.divPoints >= 2 then
      local own, deckOwn, tunOwn = owner(g.id), deckOwner(g.id), tunnelOwner(g.id)
      ownerOf[own], ownerOf[deckOwn], ownerOf[tunOwn] = g, g, g
      local div = g.divPoints
      local lExt, rExt = ribbonHalfExtents(g)
      local rad = max(lExt, rExt)
      local ground = clearSegs and clearSegs(g, 'bridge')
      local open = clearSegs and clearSegs(g, 'tunnel')
      local runOwner = nil
      for di = 1, #div - 1 do
        local o = (ground and not ground[di]) and deckOwn or (open and not open[di]) and tunOwn or own
        if o ~= runOwner then
          if runOwner then stampSpans(runOwner) end
          runOwner = o
        end
        sweepSegment(div[di].x, div[di].y, div[di + 1].x, div[di + 1].y, rad, o)
      end
      stampSpans(runOwner)
    end
  end
end

-- clearSegs(g, kind) gives a link's per-segment mask (false along its spans of that kind, 'bridge' or 'tunnel'), or nil when
-- it has none. It is handed in by the network that owns the spans.
local function rebuild(groups, jcts, clearSegs)
  -- Kept so that ground claimed LATER can be stamped without the network having to remesh for it. See freshen.
  lastGroups, lastJcts, lastClearSegs = groups, jcts, clearSegs
  claimSig = groundClaims.sig()
  stampedRev = railRev()
  gridRev = gridRev + 1
  table.clear(cells)
  table.clear(sharers)
  table.clear(claimCells)
  table.clear(claimSharers)
  table.clear(ownerOf)
  local bb = { minX = huge, maxX = -huge, minY = huge, maxY = -huge }
  local tracks, pads, railClear = {}, {}, nil
  if railGet then tracks, pads, railClear = railGet() end
  local any = expandForGroups(bb, groups)
  any = expandForGroups(bb, tracks) or any
  for i = 1, #pads do
    for _, ln in ipairs(pads[i].lines) do expandForPts(bb, ln.pts, ln.halfW + ribbonPadM); any = true end
  end

  for i = 1, #jcts do
    local j = jcts[i]
    local sealed = j and j.sealed
    if sealed and sealed.regions then
      for r = 1, #sealed.regions do
        local ring = sealed.regions[r]
        if ring then
          for k = 1, #ring do
            expandBounds(bb, ring[k].x, ring[k].y)
            any = true
          end
        end
      end
    elseif j and j.pos then
      expandBounds(bb, j.pos.x - 20, j.pos.y - 20)
      expandBounds(bb, j.pos.x + 20, j.pos.y + 20)
      any = true
    end
  end

  for i = 1, #statRivers do expandForPts(bb, statRivers[i].pts, statRivers[i].halfW + riverPadM); any = any or #statRivers[i].pts > 0 end
  for i = 1, #statBuildings do expandForPts(bb, statBuildings[i], buildingPadM); any = any or #statBuildings[i] > 0 end
  for i = 1, #statFences do expandForPts(bb, statFences[i], fencePadM); any = any or #statFences[i] > 0 end
  for i = 1, #statLakes do expandForPts(bb, statLakes[i], lakePadM); any = any or #statLakes[i] > 0 end
  bb.any = any
  baseBB = bb
  local claimTags = {}
  local claimed = groundClaims.others({}, nil, nil, claimTags)
  -- Only the plant layer's bounds now; it is stamped when something asks for it (freshenPlants).
  local _, _, pbb = gatherPlants()
  plantBB, plantRev = pbb, nil
  table.clear(plantCells)
  table.clear(builtCoarse)
  originX, originY, gridW, gridH = gridFor(claimed)
  table.clear(coarse)
  coarseW = floor((gridW - 1) / coarseCells) + 1
  if gridW == 0 then return end

  tgt, tgtSharers = cells, sharers
  stampGroups(groups, clearSegs, ownerGroup, ownerDeck, ownerTunnel)
  stampGroups(tracks, railClear, ownerRail, ownerRailDeck, ownerRailTunnel)
  for i = 1, #pads do
    local pad = pads[i]
    local owner = ownerRailJct(pad.id)
    ownerOf[owner] = pad
    for _, ln in ipairs(pad.lines) do stampPolyline(ln.pts, ln.halfW + ribbonPadM, owner) end
  end

  for i = 1, #jcts do
    local j = jcts[i]
    if j then
      local owner = j.isTunnel and ownerJctTunnel(j.id) or ownerJct(j.id)
      ownerOf[owner] = j
      local sealed = j.sealed
      if sealed and sealed.regions then
        for r = 1, #sealed.regions do
          stampRing(sealed.regions[r], owner)
        end
      elseif j.pos then
        stampDisc(j.pos.x, j.pos.y, 8.0, owner)
      end
    end
  end

  -- Static obstacles: unique owners (never in a bridge cluster's allow-set, so piers are always rejected on
  -- them; trees see them as occupied like anything else).
  for i = 1, #statRivers do stampPolyline(statRivers[i].pts, statRivers[i].halfW + riverPadM, 'r' .. i) end
  for i = 1, #statBuildings do stampPolyFill(statBuildings[i], 'b' .. i, buildingPadM) end
  for i = 1, #statFences do stampPolyline(statFences[i], fencePadM, 'f' .. i) end
  for i = 1, #statLakes do stampPolyFill(statLakes[i], 'l' .. i, lakePadM) end

  stampClaims(claimed, claimTags)
end

-- The claims registry is written by tools that know nothing about this grid, and a square or a park drawn AFTER the last
-- remesh changes what ground is spoken for with nothing left to call rebuild for it. Only the claims are stamped again,
-- unless they have moved the grid's own bounds, which moves every cell.
local function freshen()
  if railRev() ~= stampedRev then
    rebuild(lastGroups or {}, lastJcts or {}, lastClearSegs)
    return
  end
  local sig = groundClaims.sig()
  if sig == claimSig then return end
  if not baseBB then
    rebuild(lastGroups or {}, lastJcts or {}, lastClearSegs)
    return
  end
  local claimTags = {}
  local claimed = groundClaims.others({}, nil, nil, claimTags)
  local ox, oy, w, h = gridFor(claimed)
  if ox ~= originX or oy ~= originY or w ~= gridW or h ~= gridH then
    rebuild(lastGroups or {}, lastJcts or {}, lastClearSegs)
    return
  end
  claimSig = sig
  stampClaims(claimed, claimTags)
end

-- The plant layer the same way: stamped again on its own when its source moves on, unless that has moved the grid's bounds.
-- Only the queries that read it bring it up to date, so a building dragged about costs nothing until the woods ask.
local function freshenPlants()
  freshen()
  if not plantRevFn or plantRevFn() == plantRev then return end
  if not baseBB then rebuild(lastGroups or {}, lastJcts or {}, lastClearSegs) end
  local paved, built, bb = gatherPlants()
  plantBB = bb
  local ox, oy, w, h = gridFor(groundClaims.others({}))
  if ox ~= originX or oy ~= originY or w ~= gridW or h ~= gridH then
    rebuild(lastGroups or {}, lastJcts or {}, lastClearSegs)
  end
  plantRev = plantRevFn()
  stampPlants(paved, built)
end

local function allowedSetForCluster(cluster)
  local allow = {}
  for i = 1, #cluster.groupIds do
    allow[ownerDeck(cluster.groupIds[i])] = true
  end
  for i = 1, #cluster.jctIds do
    allow[ownerJct(cluster.jctIds[i])] = true
  end
  return allow
end

local function ownedOutside(cur, shared, allow, pass)
  if cur == false then
    for o in pairs(shared) do
      if not allow[o] and not (pass and pass(o)) then return true end
    end
    return false
  end
  return cur ~= nil and not allow[cur] and not (pass and pass(cur))
end

-- True if any cell in the axis-aligned footprint is owned outside the cluster. pass(owner), if given, lets more owners by.
local function blocked(cluster, x, y, halfX, halfY, pass)
  freshen()
  if gridW < 1 or gridH < 1 then return false end
  local allow = cluster._pierAllow
  if not allow then
    allow = allowedSetForCluster(cluster)
    cluster._pierAllow = allow
  end
  local ix0, iy0 = worldToCell(x - halfX, y - halfY)
  local ix1, iy1 = worldToCell(x + halfX, y + halfY)
  for iy = iy0, iy1 do
    for ix = ix0, ix1 do
      local i = idx(ix, iy)
      if i and (ownedOutside(cells[i], sharers[i], allow, pass) or ownedOutside(claimCells[i], claimSharers[i], allow, pass)) then
        return true
      end
    end
  end
  return false
end

-- The height of the road (at its nearest point to x, y) or junction stamped as owner, or nil for any other owner.
local function heightAt(owner, x, y)
  local o = ownerOf[owner]
  if not o then return nil end
  if not o.divPoints then return o.pos and o.pos.z end
  tmpP:set(x, y, 0)
  if geom.closestPointOnPolyline2D(o.divPoints, tmpP, tmpQ) == huge then return nil end
  return tmpQ.z
end

-- True if a road or junction other than skip's (a road's ownerFor; its deck stretches too) is stamped within radius of
-- (x, y) at a height between zLo and zHi there.
local nearOwners = {}
local function roadBetween(x, y, radius, zLo, zHi, skip)
  if gridW < 1 or gridH < 1 then return false end
  table.clear(nearOwners)
  local ix0, iy0 = worldToCell(x - radius, y - radius)
  local ix1, iy1 = worldToCell(x + radius, y + radius)
  for iy = iy0, iy1 do
    for ix = ix0, ix1 do
      local i = idx(ix, iy)
      local cur = i and cells[i]
      if cur == false then
        for o in pairs(sharers[i]) do nearOwners[o] = true end
      elseif cur then
        nearOwners[cur] = true
      end
    end
  end
  nearOwners[skip or ''], nearOwners[(skip or '') .. 'b'], nearOwners[(skip or '') .. 't'] = nil, nil, nil
  for o in pairs(nearOwners) do
    local z = heightAt(o, x, y)
    if z and z > zLo and z < zHi then return true end
  end
  return false
end

-- A cell of one layer with something above ground in it.
local function surfaced(cur, shared)
  if cur == nil then return false end
  if cur == false then
    for o in pairs(shared) do
      if not buried(o) then return true end
    end
    return false
  end
  return not buried(cur)
end

-- True if anything is stamped within radius of the point (owner-agnostic), the plant layer included, but not what is under
-- ground: a tree stands on the hill over a tunnel. Used for vegetation keep-out.
local function occupiedAt(x, y, radius)
  freshenPlants()
  if gridW < 1 or gridH < 1 then return false end
  radius = radius or 0
  local ix0, iy0 = worldToCell(x - radius, y - radius)
  local ix1, iy1 = worldToCell(x + radius, y + radius)
  for iy = iy0, iy1 do
    for ix = ix0, ix1 do
      local i = idx(ix, iy)
      if i and (plantCells[i] ~= nil or surfaced(cells[i], sharers[i]) or surfaced(claimCells[i], claimSharers[i])) then
        return true
      end
    end
  end
  return false
end

--- Changes whenever the grid does: a tool keeping things off it compares this rather than asking again of every point.
local function revision()
  freshenPlants()
  return gridRev
end

-- Like occupiedAt but IGNORES cells owned solely by ownerId (the caller's own ribbon, its deck and tunnel stretches included).
local function occupiedAtExcluding(x, y, radius, ownerId)
  freshen()
  if gridW < 1 or gridH < 1 then return false end
  radius = radius or 0
  local deckId, tunId = ownerId and ownerId .. 'b', ownerId and ownerId .. 't'
  local ix0, iy0 = worldToCell(x - radius, y - radius)
  local ix1, iy1 = worldToCell(x + radius, y + radius)
  for iy = iy0, iy1 do
    for ix = ix0, ix1 do
      local i = idx(ix, iy)
      if i then
        local cur = cellAt(i)
        if cur ~= nil and cur ~= ownerId and cur ~= deckId and cur ~= tunId then return true end
      end
    end
  end
  return false
end

-- Occupancy owner string for a group, so callers can pass it to occupiedAtExcluding.
local function ownerFor(g)
  return ownerGroup(g.id)
end

-- True if a TRANSPORT cell (road group 'g', path 'p', or junction 'j', or a multi-owner cell) lies within radius.
local function transportAt(x, y, radius)
  freshen()
  if gridW < 1 or gridH < 1 then return false end
  radius = radius or 0
  local ix0, iy0 = worldToCell(x - radius, y - radius)
  local ix1, iy1 = worldToCell(x + radius, y + radius)
  for iy = iy0, iy1 do
    for ix = ix0, ix1 do
      local i = idx(ix, iy)
      if i then
        local cur = cellAt(i)
        if cur == false then return true end -- multi-owner: at least one owner overlaps here; be conservative
        if type(cur) == 'string' then
          local h = cur:byte(1)
          if h == 103 or h == 106 or h == 112 then return true end -- 'g' (road/rail) or 'j' (junction) or 'p' (path)
        end
      end
    end
  end
  return false
end

-- Like transportAt but PATHS ARE IGNORED: true only for a road/rail ribbon 'g' or junction 'j' (or a multi-owner
-- cell, kept conservative since its owners are lost).
local function roadRailAt(x, y, radius)
  freshen()
  if gridW < 1 or gridH < 1 then return false end
  radius = radius or 0
  local ix0, iy0 = worldToCell(x - radius, y - radius)
  local ix1, iy1 = worldToCell(x + radius, y + radius)
  for iy = iy0, iy1 do
    for ix = ix0, ix1 do
      local i = idx(ix, iy)
      if i then
        local cur = cellAt(i)
        if cur == false then return true end -- multi-owner: at least one road/rail may overlap here; be conservative
        if type(cur) == 'string' then
          local h = cur:byte(1)
          if h == 103 or h == 106 then return true end -- 'g' (road/rail) or 'j' (junction); 'p' (path) ignored
        end
      end
    end
  end
  return false
end

-- A road, rail or junction cell of the network layer: a shared cell only if one of its owners is.
local function isRoadRail(i)
  local cur = cells[i]
  if cur == nil then return false end
  if cur == false then
    for o in pairs(sharers[i]) do
      if isRoadRailOwner(o) then return true end
    end
    return false
  end
  return isRoadRailOwner(cur)
end

-- True if a road, rail or junction cell centre, or a BUILT one of the plant layer, lies within radius of the point: what a
-- crown that wide would hang over or grow up through. A disc rather than roadRailAt's box, and exact about shared cells.
-- Blocks with neither in them are passed over whole, so a point far from both costs a handful of lookups whatever the
-- radius. A junction's filled middle marks no blocks, but nothing outside it can reach it without crossing the edge skin,
-- which does.
local function overhangAt(x, y, radius)
  freshenPlants()
  if gridW < 1 or gridH < 1 then return false end
  local ix0, iy0 = worldToCell(x - radius, y - radius)
  local ix1, iy1 = worldToCell(x + radius, y + radius)
  ix0, iy0, ix1, iy1 = max(ix0, 0), max(iy0, 0), min(ix1, gridW - 1), min(iy1, gridH - 1)
  if ix0 > ix1 or iy0 > iy1 then return false end
  local near = false
  for cy = floor(iy0 / coarseCells), floor(iy1 / coarseCells) do
    for cx = floor(ix0 / coarseCells), floor(ix1 / coarseCells) do
      local k = cy * coarseW + cx + 1
      if coarse[k] or builtCoarse[k] then near = true; break end
    end
    if near then break end
  end
  if not near then return false end
  local rSq = radius * radius
  for iy = iy0, iy1 do
    local dy = originY + (iy + 0.5) * cellSizeM - y
    for ix = ix0, ix1 do
      local dx = originX + (ix + 0.5) * cellSizeM - x
      if dx * dx + dy * dy <= rSq then
        local i = iy * gridW + ix + 1
        if plantCells[i] == BUILT or isRoadRail(i) then return true end
      end
    end
  end
  return false
end

--- The ground plants keep off besides everything else here: `get()` returns `paved, built`, where paved is
--- { { ring = r, holes = { r, ... } }, ... } a trunk may not stand on and built is { r, ... } a crown may not reach either.
--- `rev()` changes whenever either does. One source; see occupiedAt and overhangAt.
local function setPlantKeepOut(get, rev)
  plantGet, plantRevFn, plantRev = get, rev, nil
end

-- True if a BUILDING cell (owner 'b', stamped footprint + buildingPadM) lies within radius.
local function buildingAt(x, y, radius)
  freshen()
  if gridW < 1 or gridH < 1 then return false end
  radius = radius or 0
  local ix0, iy0 = worldToCell(x - radius, y - radius)
  local ix1, iy1 = worldToCell(x + radius, y + radius)
  for iy = iy0, iy1 do
    for ix = ix0, ix1 do
      local i = idx(ix, iy)
      if i then
        local cur = cellAt(i)
        if type(cur) == 'string' and cur:byte(1) == 98 then return true end -- 'b' building
      end
    end
  end
  return false
end

local function clearClusterCache(cluster)
  if cluster then cluster._pierAllow = nil end
end

-- The Rail Network's side: get() answers its tracks (as road groups are read), its junction pads ({ id, pos, lines = { { pts,
-- halfW } } }) and its tracks' clearSegs; rev() is bumped whenever any of that changes.
local function setRail(get, rev)
  railGet, railRevFn = get, rev
end

-- What a rail bridge's piers may stand under, for blocked: the bridge stretches of these tracks and these junctions.
local function railCluster(trackIds, jctIds)
  local allow = {}
  for _, id in ipairs(trackIds) do allow[ownerRailDeck(id)] = true end
  for _, id in ipairs(jctIds) do allow[ownerRailJct(id)] = true end
  return { _pierAllow = allow }
end

-- Static obstacle registration (importer). Each setter replaces its own kind; the lists persist across
-- rebuild() so pier remeshing keeps avoiding them without the tool knowing about non-transport geometry.
local function setRivers(list) statRivers = list or {} end
local function setBuildings(list) statBuildings = list or {} end
local function setFences(list) statFences = list or {} end
local function setLakes(list) statLakes = list or {} end
local function clearStatics() statRivers, statBuildings, statFences, statLakes = {}, {}, {}, {} end


-- Public interface.
M.rebuild = rebuild
M.pointInPoly = pointInPoly
M.blocked = blocked
M.heightAt = heightAt
M.roadBetween = roadBetween
M.occupiedAt = occupiedAt
M.revision = revision
M.occupiedAtExcluding = occupiedAtExcluding
M.ownerFor = ownerFor
M.transportAt = transportAt
M.roadRailAt = roadRailAt
M.overhangAt = overhangAt
M.setPlantKeepOut = setPlantKeepOut
M.buildingAt = buildingAt
M.clearClusterCache = clearClusterCache
M.setRail = setRail
M.railRev = railRev
M.railCluster = railCluster
M.setRivers = setRivers
M.setBuildings = setBuildings
M.setFences = setFences
M.setLakes = setLakes
M.clearStatics = clearStatics

return M