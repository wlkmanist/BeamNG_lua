-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared roadside-prop line placer.

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')
local kitPlacer = require('editor/toolUtilities/kitPlacer')
local siteLights = require('editor/toolUtilities/siteLights')
local util = require('editor/toolUtilities/util')

-- Module constants.
local max, floor, abs = math.max, math.floor, math.abs
local headInsetM = 0.35 -- the lamp head hangs this far in from the end of its arm and below the top of the mesh
local armMinM = 0.3     -- a mesh whose middle sits nearer its pole than this has no arm: it burns over its own head
local sin, cos, pi = math.sin, math.cos, math.pi
local preRotQuats = geom.getPreRotQuats() -- [0..3] = 0/90/180/270 deg about Z.
local quat90Z, quat180Z = preRotQuats[1], preRotQuats[2]
local globalUp = vec3(0, 0, 1)
local presets = { -- Curated presets.
  jersey = {
    name = 'Concrete / Jersey', shapePath = 'art/shapes/objects/jerseybarrier_3m.dae', preRot = 1, gapM = -0.18,
    nativeLenM = 3.0, normalMode = 'surface',
    -- Centre-pivot end piece (single asset, rotated to serve either end): it occupies the first/last plate SLOT. Oriented by
    -- the OUTWARD direction with one capPreRot (see runLine), so both ends ramp down-and-out regardless of rail direction.
    capMode = 'centre', capPath = 'art/shapes/objects/jerseybarrier_end.dae', capPreRot = 3,
  },
  plastic = {
    name = 'Plastic', shapePath = 'art/shapes/garage_and_dealership/Clutter/hr_plasticbarrier.dae', preRot = 0,
    gapM = -0.075, normalMode = 'surface',
    -- Alternate white/red down the run (meshSpline's plastic-barrier look); mids cycle these in order.
    altPaths = {
      'art/shapes/garage_and_dealership/Clutter/hr_plasticbarrier.dae',
      'art/shapes/garage_and_dealership/Clutter/hr_plasticbarrier_red.dae',
    },
  },
  fence = {
    name = 'Metal Fence', shapePath = 'art/shapes/objects/s_metal_fence.dae', preRot = 1, gapM = 0.2,
    normalMode = 'surface',
  },
  chainlink = {
    -- Long axis = local X, so no asset preRot (just the baseline quat90Z), tiny overlap to kill seams.
    name = 'Chainlink Fence', shapePath = 'art/shapes/objects/s_chainlink_old.dae', preRot = 0, gapM = -0.02,
    normalMode = 'surface',
  },
  scrap = {
    -- Battered corrugated-metal fence. Long axis = local X (no preRot); two 3.5 m panel variants alternate down the run for a
    -- ragged, non-repeating look, tiny overlap to hide the seams (any end-authored pivot is auto-corrected in pieceGeom).
    name = 'Scrap Fence', shapePath = 'art/shapes/objects/s_scrap_fence_35_a.dae', preRot = 0, gapM = -0.02,
    normalMode = 'surface',
    altPaths = {
      'art/shapes/objects/s_scrap_fence_35_a.dae',
      'art/shapes/objects/s_scrap_fence_35_b.dae',
    },
  },
  guardrail = {
    name = 'Guardrail', shapePath = 'art/shapes/objects/italy_guardrails_basic.dae', preRot = 0, gapM = 0.0,
    nativeLenM = 3.0, normalMode = 'surface',
    -- Tip-pivot directional terminals sitting ON the end joints (like populateRoadside's crash). cw/ccw swap by side so the
    -- flared end always turns the right way; capPreRot 0 = section orientation.
    capMode = 'tip', endMode = 'cwccw', capPreRot = 0,
    endCw = 'art/shapes/objects/italy_guardrails_basic_end_cw.dae',
    endCcw = 'art/shapes/objects/italy_guardrails_basic_end_ccw.dae',
  },
  -- The suite's lamp catalogue: every tool that stands a lamp takes its mesh, its facing and the light it throws from here.
  -- `reach` and `bright` mark a preset as a lamp; where the head hangs is read off the mesh itself (see lampHead).
  lampMast = {
    name = 'Mast Arm Lamp', shapePath = 'art/shapes/garage_and_dealership/Clutter/eca_lamppost.dae', preRot = 1,
    normalMode = 'global', pointStepM = 30.0, reach = 35, bright = 8,
  },
  lampVictorian = {
    name = 'Victorian Lamp', shapePath = 'art/shapes/objects/lamp1.dae', preRot = 1,
    normalMode = 'global', pointStepM = 25.0, reach = 20, bright = 4,
  },
  lampSingle = {
    name = 'Single Pole Lamp', shapePath = '/art/shapes/objects/pole_light_single.dae', preRot = 1,
    normalMode = 'global', pointStepM = 30.0, reach = 35, bright = 8,
  },
  lampTwin = {
    name = 'Twin Pole Lamp', shapePath = '/art/shapes/objects/pole_light_double.dae', preRot = 1,
    normalMode = 'global', pointStepM = 30.0, reach = 40, bright = 10,
  },
  -- Global 's_*' lamp set (assets/ content root, on any level). preRot carries the bridgeSpline
  -- calibration: relative to mast (preRot=1), street -> 0 and highway/sidewalk -> 2.
  lampStreet = {
    name = 'Street Lamp', shapePath = 'assets/meshes/props/urban/lighting/s_lamp_post_street_single_01.dae', preRot = 0,
    normalMode = 'global', pointStepM = 30.0, reach = 35, bright = 8,
  },
  lampHighway = {
    name = 'Highway Lamp', shapePath = 'assets/meshes/props/urban/lighting/s_lamp_post_single_highway_01.dae', preRot = 2,
    normalMode = 'global', pointStepM = 40.0, reach = 45, bright = 12,
  },
  lampSidewalk = {
    name = 'Sidewalk Lamp', shapePath = 'assets/meshes/props/urban/lighting/s_streetlamp_sidewalk_01.dae', preRot = 2,
    normalMode = 'global', pointStepM = 25.0, reach = 22, bright = 5,
  },
  -- Small upright street furniture. Point props like the lamps: one per sample, world-up, no chaining.
  bollard = {
    name = 'Bollard', shapePath = 'art/shapes/objects/bollard_yellow.dae', preRot = 0,
    normalMode = 'global', pointStepM = 4.0,
  },
  bollardStone = {
    name = 'Bollard (stone)', shapePath = 'art/shapes/garage_and_dealership/Clutter/si_bollard.DAE', preRot = 0,
    normalMode = 'global', pointStepM = 4.0,
  },
  bollardTall = {
    name = 'Bollard (tall lit)', shapePath = 'art/shapes/objects/s_bollard_big_lightpole.dae', preRot = 0,
    normalMode = 'global', pointStepM = 6.0,
  },
  bin = {
    name = 'Litter Bin', shapePath = 'art/shapes/garage_and_dealership/Clutter/clutter_city_bin_round.dae', preRot = 0,
    normalMode = 'global', pointStepM = 20.0,
  },
  binMetal = {
    name = 'Litter Bin (metal)', shapePath = 'art/shapes/garage_and_dealership/Clutter/italy_clutter_metal_bin.DAE', preRot = 0,
    normalMode = 'global', pointStepM = 20.0,
  },
  binSmall = {
    name = 'Litter Bin (small)', shapePath = 'art/shapes/garage_and_dealership/Clutter/italy_clutter_metal_bin_small.DAE', preRot = 0,
    normalMode = 'global', pointStepM = 20.0,
  },
  busShelter = {
    name = 'Bus Shelter', shapePath = 'art/shapes/objects/s_busstop_it.dae', preRot = 0,
    normalMode = 'global', pointStepM = 60.0,
  },
}

-- Module state.
local pools = {} -- placed-piece lists keyed by caller poolId (module-side, so the live TSStatics never get serialized).
local lightPools = {} -- the lights a pool's lamps throw, as { obj = light } entries so kitPlacer deletes and commits them alike
local ptBatch = nil -- optional spatial-hash across point-prop (lamp) runs: rejects placements closer than minGap to one already placed.
local pieceGeomCache = {} -- { len, pivot, axisX } per shapePath (from the asset bounding box), computed once.
local headCache = {} -- { x, y, z } per lamp shapePath: where its light hangs in the mesh's own frame
local base, tmpA, tmpB, outRot = quat(), quat(), quat(), quat()
local alongV, upV, midPos, placePos, axisTmp = vec3(), vec3(), vec3(), vec3(), vec3()
local sPos, sTan, sNrm = {}, {}, {} -- sampleSpline outputs (reused).
local railTans, railNrms = {}, {} -- per rail-point frame fed to sampleSpline (reused).


-- Piece geometry along travel for a preset, from the asset bounding box (cached).
local function pieceGeom(preset)
  local sp = preset.shapePath
  local g = pieceGeomCache[sp]
  if g then return g end
  local box = util.getMeshBox(sp)
  local e, c = box and box.extents, box and box.center
  local ex, ey = e and e.x or 0, e and e.y or 0
  local axisX = ex >= ey
  local len = axisX and ex or ey
  if not (len > 0.05) then len = 3.0 end
  local pivot = 0
  if preset.nativeLenM then
    len = preset.nativeLenM
  elseif c then
    pivot = axisX and c.x or c.y
  end
  g = { len = len, pivot = pivot, axisX = axisX }
  pieceGeomCache[sp] = g
  return g
end

-- Orient one placement into outRot for the given frame + asset preRot + road side. Mirrors populateRoadside.placeMesh:
-- final = (sideSign<0 ? quat180Z : I) * preRotQuats[preIdx] * quat90Z * setFromDir(along, up).
local function orient(along, up, preIdx, sideSign)
  base:setFromDir(along, up)
  tmpA:setMul2(preRotQuats[preIdx] or preRotQuats[0], quat90Z)
  if sideSign < 0 then
    tmpB:setMul2(quat180Z, tmpA)
    outRot:setMul2(tmpB, base)
  else
    outRot:setMul2(tmpA, base)
  end
end

-- The rotation a placement gets (see orient), for a tool that stands its own pieces. Shared: use or copy before the next call.
local function orientation(along, up, preIdx, sideSign)
  orient(along, up, preIdx, sideSign or 1)
  return outRot
end

-- Where a lamp's light hangs, in its mesh's own frame, off the bounding box: just under the top, and at the far end of the
-- arm when the mesh reaches out to one side of its pole. Cached per shape.
local function lampHead(sp)
  local h = headCache[sp]
  if h then return h end
  local box = util.getMeshBox(sp)
  local c, e = box and box.center, box and box.extents
  if not (c and e.z > 1) then
    h = { 0, 0, 6 }
  else
    local hx, hy = c.x, c.y
    if hx * hx + hy * hy > armMinM * armMinM then
      if abs(hx) >= abs(hy) then
        hx = hx + (hx > 0 and 1 or -1) * max(e.x * 0.5 - headInsetM, 0)
      else
        hy = hy + (hy > 0 and 1 or -1) * max(e.y * 0.5 - headInsetM, 0)
      end
    end
    h = { hx, hy, c.z + e.z * 0.5 - headInsetM }
  end
  headCache[sp] = h
  return h
end

-- The light record (see siteLights) for a lamp preset standing at (px, py, pz) turned by `q`, or nil for a preset that is
-- not a lamp. `scale`, `col`, `bright` and `reach` are optional, the last three overriding the catalogue's.
local function lampLight(presetKey, px, py, pz, q, scale, col, bright, reach)
  local preset = presets[presetKey]
  if not (preset and preset.reach) then return nil end
  local h, s = lampHead(preset.shapePath), scale or 1
  axisTmp:set(h[1] * s, h[2] * s, h[3] * s)
  axisTmp:setRotate(q, axisTmp)
  return { px = px + axisTmp.x, py = py + axisTmp.y, pz = pz + axisTmp.z, glow = col or siteLights.TONES.warm,
           radius = reach or preset.reach, brightness = bright or preset.bright }
end

-- Light the lamp placeOne just stood, into the pool's lights. `out` (optional) collects the record too.
local function lightLast(presetKey, P, folder, owner, lights, out)
  local lt = lampLight(presetKey, P.x, P.y, P.z, outRot)
  if not lt then return end
  local obj = siteLights.spawn(folder, owner .. '_lamp_' .. (#lights + 1), lt)
  lights[#lights + 1] = { obj = obj }
  if out then out[#out + 1] = lt end
end

-- Place one prop of shapePath at world (P) with the given along/up frame. `scl` is optional and passes straight through to
-- kitPlacer, so it takes a number for a uniform scale or {x,y,z} in the piece's own frame.
local function placeOne(sink, shapePath, P, along, up, preIdx, sideSign, pivotOff, axisX, scl)
  orient(along, up, preIdx, sideSign)
  if pivotOff and pivotOff ~= 0 then
    axisTmp:set(axisX and 1 or 0, axisX and 0 or 1, 0)
    axisTmp:setRotate(outRot, axisTmp)
    placePos:set(P.x - axisTmp.x * pivotOff, P.y - axisTmp.y * pivotOff, P.z - axisTmp.z * pivotOff)
    kitPlacer.placeTs(sink, shapePath, placePos.x, placePos.y, placePos.z, outRot.x, outRot.y, outRot.z, outRot.w, scl)
  else
    kitPlacer.placeTs(sink, shapePath, P.x, P.y, P.z, outRot.x, outRot.y, outRot.z, outRot.w, scl)
  end
end

-- Point-prop declustering.
local function beginPointBatch(minGap)
  ptBatch = (minGap and minGap > 0) and { cell = minGap, min2 = minGap * minGap, grid = {} } or nil
end

local function endPointBatch()
  ptBatch = nil
end

-- True (and records the point) if (x,y) is clear of every point already in the batch; false if too close. No-op pass when inactive.
local function batchAccept(x, y)
  if not ptBatch then return true end
  local cell, min2, grid = ptBatch.cell, ptBatch.min2, ptBatch.grid
  local ci, cj = floor(x / cell), floor(y / cell)
  for a = ci - 1, ci + 1 do
    local col = grid[a]
    if col then
      for b = cj - 1, cj + 1 do
        local bucket = col[b]
        if bucket then
          for k = 1, #bucket do
            local dx, dy = bucket[k][1] - x, bucket[k][2] - y
            if dx * dx + dy * dy < min2 then return false end
          end
        end
      end
    end
  end
  local col = grid[ci]; if not col then col = {}; grid[ci] = col end
  local bucket = col[cj]; if not bucket then bucket = {}; col[cj] = bucket end
  bucket[#bucket + 1] = { x, y }
  return true
end

-- Deletes a caller's pool of placed pieces.
local function removePool(poolId)
  kitPlacer.deleteList(lightPools[poolId])
  lightPools[poolId] = nil
  local list = pools[poolId]
  if not list then return end
  kitPlacer.deleteList(list)
  pools[poolId] = nil
end

-- Number of placed pieces currently in a pool (0 if empty / not built / committed). O(1) array length -- cheap enough to read
-- every frame for a stats readout.
local function poolCount(poolId)
  local list = pools[poolId]
  return list and #list or 0
end

-- A pool's placed pieces, for a bake reading them back off the scene. Read only.
local function poolList(poolId)
  return pools[poolId]
end

-- Burn: flip one pool's transient props, and the lights its lamps throw, to persistent (canSave=true) and detach them from
-- the pool.
local function commitPool(poolId)
  local list, lights = pools[poolId], lightPools[poolId]
  pools[poolId], lightPools[poolId] = nil, nil -- detach WITHOUT deleting.
  local uids = (list and #list > 0) and kitPlacer.commitSink({ list = list }) or {}
  if lights then
    local names = kitPlacer.commitSink({ list = lights })
    for i = 1, #names do uids[#uids + 1] = names[i] end
  end
  return uids
end

-- Place a preset at each supplied world point. `keepPool` and `ownerTag` work as they do in runLine.
-- A point may carry `scl` (a number, or {x,y,z} in the piece's frame) to fit that one instance.
local function placePoints(opts)
  if not opts.keepPool then removePool(opts.poolId) end
  local preset = opts.presetKey and presets[opts.presetKey]
  local pts = opts.points
  if not preset or not opts.folder or not pts or #pts == 0 then return 0 end
  local sideSign = opts.sideSign or 1
  local rec = opts.outPositions
  pools[opts.poolId] = pools[opts.poolId] or {}
  local owner = kitPlacer.safeName('HeroProp_', opts.poolId .. (opts.ownerTag and ('_' .. opts.ownerTag) or ''))
  local sink = kitPlacer.newSink(opts.folder, owner, true, pools[opts.poolId])
  if preset.reach then lightPools[opts.poolId] = lightPools[opts.poolId] or {} end
  local lights = preset.reach and lightPools[opts.poolId]
  for i = 1, #pts do
    local p = pts[i]
    local P = { x = p.x, y = p.y, z = p.z or 0 }
    alongV:set(p.ax or 1, p.ay or 0, 0)
    if alongV:squaredLength() > 1e-12 then alongV:normalize() else alongV:set(1, 0, 0) end
    placeOne(sink, preset.shapePath, P, alongV, globalUp, preset.preRot, sideSign, nil, nil, p.scl)
    if lights then lightLast(opts.presetKey, P, opts.folder, owner, lights, opts.outLights) end
    if rec then rec[#rec + 1] = P end
  end
  return sink.n
end

-- Scatter loose meshes at world points (random shape, yaw, lean, size, burial), into a pool. Deterministic in opts.seed.
--   poolId, folder, shapePaths, points ({x=,y=,z=}), seed, base, var, tiltMax, buryBase, buryVar, collidable, outPositions
local function placeScatter(opts)
  removePool(opts.poolId)
  local shapes = opts.shapePaths
  local pts = opts.points
  if not shapes or #shapes == 0 or not opts.folder or not pts or #pts == 0 then return 0 end
  pools[opts.poolId] = pools[opts.poolId] or {}
  local sink = kitPlacer.newSink(opts.folder, kitPlacer.safeName('HeroScatter_', opts.poolId), opts.collidable == true, pools[opts.poolId])
  local base, var = opts.base or 1.0, opts.var or 0.0
  local tiltMax = opts.tiltMax or 0.2
  local buryBase, buryVar = opts.buryBase or 0.03, opts.buryVar or 0.12
  local rec = opts.outPositions
  local s = floor((opts.seed or 1)) % 2147483647; if s < 1 then s = s + 2147483646 end
  for i = 1, #pts do
    local p = pts[i]
    local r = {}
    for k = 1, 5 do s = (s * 1103515245 + 12345) % 2147483648; r[k] = s / 2147483648 end
    local idx = 1 + floor(r[1] * #shapes); if idx > #shapes then idx = #shapes end
    local scl = base * (1 + var * (r[2] * 2 - 1)); if scl < 0.1 then scl = 0.1 end
    local a = r[3] * (2 * pi); local ys, yc = sin(a * 0.5), cos(a * 0.5) -- yaw about Z
    local phi, t = r[4] * (2 * pi), r[5] * tiltMax                      -- small lean about a random horizontal axis
    local ts, tc = sin(t * 0.5), cos(t * 0.5)
    local tx, ty = cos(phi) * ts, sin(phi) * ts
    local qx, qy, qz, qw = yc * tx - ys * ty, yc * ty + ys * tx, ys * tc, yc * tc -- q = qYaw * qTilt
    local z = (p.z or 0) - (buryBase + r[2] * buryVar * scl)
    kitPlacer.placeTs(sink, shapes[idx], p.x, p.y, z, qx, qy, qz, qw, scl)
    if rec then rec[#rec + 1] = { x = p.x, y = p.y, z = z } end
  end
  return sink.n
end

-- Build (or rebuild) one line of props along a rail. `keepPool` adds to the pool instead of replacing it, which is how
-- a run made of several rails is built -- a parapet broken by its flights arrives as a handful of open spans.
local function runLine(opts)
  if not opts.keepPool then removePool(opts.poolId) end
  local presetKey = opts.presetKey
  if not presetKey or presetKey == 'none' then return 0 end
  local preset = presets[presetKey]
  local pts = opts.railPts
  local n = pts and #pts or 0
  if not preset or n < 2 or not opts.folder then return 0 end
  local isGlobal = preset.normalMode == 'global'
  local sideSign = opts.sideSign or 1

  -- Per-point frame for sampleSpline: tangent from neighbours, up from railUps (surface) or world-up (global).
  local ups = opts.railUps
  for i = 1, n do
    local a, b = pts[max(1, i - 1)], pts[math.min(n, i + 1)]
    railTans[i] = railTans[i] or vec3()
    railTans[i]:set(b.x - a.x, b.y - a.y, b.z - a.z)
    if railTans[i]:squaredLength() > 1e-12 then railTans[i]:normalize() else railTans[i]:set(1, 0, 0) end
    railNrms[i] = railNrms[i] or vec3()
    if isGlobal or not (ups and ups[i]) then railNrms[i]:set(globalUp) else railNrms[i]:set(ups[i]); railNrms[i]:normalize() end
  end
  for i = n + 1, #railTans do railTans[i], railNrms[i] = nil, nil end

  local geom0 = pieceGeom(preset)
  local step = opts.stepM or (isGlobal and (preset.pointStepM or 25.0) or (geom0.len + (preset.gapM or 0.0) + (opts.extraGapM or 0.0)))
  if not (step > 0.05) then step = 0.05 end
  -- Point props (lamps) can lock a piece onto BOTH ends and even-fit the interior toward `step` (like bridgeSpline's lamp fill),
  -- so a run never overshoots/undershoots the ends. Chained pieces (barriers) already abut end-to-end, so they keep the plain walk.
  if isGlobal and opts.lockEnds then
    geom.sampleSplineEvenFit(pts, railTans, railNrms, step, opts.isLoop == true, sPos, sTan, sNrm)
  else
    geom.sampleSpline(pts, railTans, railNrms, step, sPos, sTan, sNrm)
  end
  local ns = #sPos
  if ns < 1 then return 0 end

  pools[opts.poolId] = pools[opts.poolId] or {}
  -- Object names are the owner id plus a running index, so several spans sharing one pool (see keepPool) have to differ
  -- in the owner id, or the second span names its pieces over the first's.
  local owner = kitPlacer.safeName('HeroProp_', opts.poolId .. (opts.ownerTag and ('_' .. opts.ownerTag) or ''))
  local sink = kitPlacer.newSink(opts.folder, owner, true, pools[opts.poolId])

  -- Point props (lamp posts): one instance at each spaced sample, world-up, no chaining/caps. When a point batch is active,
  -- skip any sample too close to a point already placed this batch (declusters where separate lines meet).
  if isGlobal then
    local rec = opts.outPositions -- optional: append each placed piece's world position (for a caller's terraform pads etc.)
    local rejectFn = opts.rejectFn -- optional: return true to veto a sample (e.g. keep props off crossing paths at junctions)
    if preset.reach then lightPools[opts.poolId] = lightPools[opts.poolId] or {} end
    local lights = preset.reach and lightPools[opts.poolId]
    for i = 1, ns do
      if not (rejectFn and rejectFn(sPos[i].x, sPos[i].y)) and batchAccept(sPos[i].x, sPos[i].y) then
        alongV:set(sTan[i]); alongV.z = 0
        if alongV:squaredLength() > 1e-12 then alongV:normalize() else alongV:set(1, 0, 0) end
        placeOne(sink, preset.shapePath, sPos[i], alongV, globalUp, preset.preRot, sideSign)
        if lights then lightLast(presetKey, sPos[i], opts.folder, owner, lights, opts.outLights) end
        if rec then rec[#rec + 1] = { x = sPos[i].x, y = sPos[i].y, z = sPos[i].z } end
      end
    end
    return sink.n
  end

  -- Chained barrier plates.
  local numSections = ns - 1
  if numSections < 1 then return sink.n end

  -- Resolve end pieces (directional cw/ccw swap by side for the guardrail; single centre piece for jersey).
  local hasCaps = preset.capMode ~= nil
  local centreCaps = preset.capMode == 'centre'
  local startPath, endPath, tipPreRot
  if hasCaps then
    if centreCaps then
      startPath, endPath = preset.capPath, preset.capPath
    else -- cwccw tip terminals: swap the flared mesh by side.
      if sideSign < 0 then startPath, endPath = preset.endCw, preset.endCcw else startPath, endPath = preset.endCcw, preset.endCw end
      tipPreRot = preset.capPreRot or 0
    end
  end

  -- Midpoint frame for interval [i, i+1]: chord tangent (so a rigid plate's ends land on both samples) + averaged up.
  local function intervalFrame(i)
    local p1, p2 = sPos[i], sPos[i + 1]
    midPos:set((p1.x + p2.x) * 0.5, (p1.y + p2.y) * 0.5, (p1.z + p2.z) * 0.5)
    alongV:setSub2(p2, p1)
    if alongV:squaredLength() > 1e-12 then alongV:normalize() else alongV:set(1, 0, 0) end
    local n1, n2 = sNrm[i], sNrm[i + 1]
    upV:set(n1.x + n2.x, n1.y + n2.y, n1.z + n2.z)
    if upV:squaredLength() > 1e-12 then upV:normalize() else upV:set(globalUp) end
  end

  -- Mid plates. Centre-pivot caps (jersey) take the first/last interval slots, so the mids skip those.
  local midLo, midHi = 1, numSections
  if centreCaps then
    if startPath then midLo = 2 end
    if endPath and numSections >= 2 then midHi = numSections - 1 end
  end
  local altPaths = preset.altPaths -- optional per-plate cycle (e.g. plastic white/red), else the single shapePath.
  local nAlt = altPaths and #altPaths or 0
  for i = midLo, midHi do
    intervalFrame(i)
    local path = nAlt > 0 and altPaths[((i - 1) % nAlt) + 1] or preset.shapePath
    placeOne(sink, path, midPos, alongV, upV, preset.preRot, sideSign, geom0.pivot, geom0.axisX)
  end

  if not hasCaps then return sink.n end
  if centreCaps then
    -- Centre-pivot terminals (jersey).
    local capPreRot = preset.capPreRot or 1
    if startPath then
      local p1, p2 = sPos[1], sPos[2]
      midPos:set((p1.x + p2.x) * 0.5, (p1.y + p2.y) * 0.5, (p1.z + p2.z) * 0.5)
      alongV:setSub2(p1, p2) -- outward at the start = away from the run.
      if alongV:squaredLength() > 1e-12 then alongV:normalize() else alongV:set(1, 0, 0) end
      local n1, n2 = sNrm[1], sNrm[2]
      upV:set(n1.x + n2.x, n1.y + n2.y, n1.z + n2.z)
      if upV:squaredLength() > 1e-12 then upV:normalize() else upV:set(globalUp) end
      placeOne(sink, startPath, midPos, alongV, upV, capPreRot, 1)
    end
    if endPath and numSections >= 2 then
      local p1, p2 = sPos[numSections], sPos[ns]
      midPos:set((p1.x + p2.x) * 0.5, (p1.y + p2.y) * 0.5, (p1.z + p2.z) * 0.5)
      alongV:setSub2(p2, p1) -- outward at the end = away from the run.
      if alongV:squaredLength() > 1e-12 then alongV:normalize() else alongV:set(1, 0, 0) end
      local n1, n2 = sNrm[numSections], sNrm[ns]
      upV:set(n1.x + n2.x, n1.y + n2.y, n1.z + n2.z)
      if upV:squaredLength() > 1e-12 then upV:normalize() else upV:set(globalUp) end
      placeOne(sink, endPath, midPos, alongV, upV, capPreRot, 1)
    end
  else -- Tip-pivot terminals (guardrail): sit ON the two end joints.
    if startPath then
      alongV:set(sTan[1]); if alongV:squaredLength() > 1e-12 then alongV:normalize() else alongV:set(1, 0, 0) end
      upV:set(sNrm[1]); if upV:squaredLength() > 1e-12 then upV:normalize() else upV:set(globalUp) end
      placeOne(sink, startPath, sPos[1], alongV, upV, tipPreRot, sideSign)
    end
    if endPath then
      alongV:set(sTan[ns]); if alongV:squaredLength() > 1e-12 then alongV:normalize() else alongV:set(1, 0, 0) end
      upV:set(sNrm[ns]); if upV:squaredLength() > 1e-12 then upV:normalize() else upV:set(globalUp) end
      placeOne(sink, endPath, sPos[ns], alongV, upV, tipPreRot, sideSign)
    end
  end

  return sink.n
end

-- The stock-art presets above are all a roadside tool asks for. The kit-baked furniture and civic pieces are cut by the
-- prop kit, which is not part of a release, so they live over there and register themselves through here.
local function addPresets(t)
  for k, v in pairs(t) do presets[k] = v end
end


-- Public interface.
M.presets = presets

M.addPresets = addPresets
M.orientation = orientation
M.lampLight = lampLight
M.runLine = runLine
M.placePoints = placePoints
M.placeScatter = placeScatter
M.removePool = removePool
M.poolCount = poolCount
M.poolList = poolList
M.commitPool = commitPool
M.beginPointBatch = beginPointBatch
M.endPointBatch = endPointBatch

return M