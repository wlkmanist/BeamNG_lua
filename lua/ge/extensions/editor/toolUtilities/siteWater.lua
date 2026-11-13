-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- The standing and falling water a site carries: the pools of a cascade centrepiece, the sheets that spill between them,
-- and the spray off both. Water is not a mesh, so none of it can go into a baked shell. An open space carries it in its
-- manifest as figures instead, and whatever stands the site up spawns the objects again -- the same way the lamps go.
--
-- Everything here works off ONE record, which the editor keeps live on the site and the manifest carries in the site's
-- own frame. The whole assembly stands at a single point on a single grain, and one x, one y and one angle are the
-- whole of the placement: a site turned on the ground turns its water by turning those two.
--
-- A pool may stand off that point, since a pond is somewhere on the square rather than in the middle of the fountain,
-- and it carries its offset and its own turn in the site's frame for the purpose. A fountain's basins do not use
-- either -- they are all centred on the piece, which is why they were the only thing here to begin with.

local M = {}

-- Module dependencies.
local kitPlacer = require('editor/toolUtilities/kitPlacer')

-- Module constants.
local max, min, floor, cos, sin, sqrt = math.max, math.min, math.floor, math.cos, math.sin, math.sqrt
local abs, pi = math.abs, math.pi
local format = string.format
local LEAST_M = 1.0      -- the smallest a pool is asked to be, the floor the other water tools hold to
local LEAST_FALL_M = 0.1 -- a sheet's own floor: a cut corner sheds a ribbon a hand wide, and must be allowed to
local EDGES = 8          -- a bowl spills over every edge of its rim: four flats and the four cut corners between
local OCTANT = math.pi / 4
local DIAG = sqrt(2)
local FALL_SLOPE = 1.6   -- drop over run, about 58 degrees
local FALL_LAND_M = 0.12 -- the margin kept between where a sheet lands and the edge of the pool catching it
local FALL_DEPTH = 1.5   -- the render depth a fall's volume is given, which is what its depth colour comes off
local MITRE = 0.82842712
local JOIN_M = 0.04      -- a little width over the mitre, so the joins cannot show a hairline
local SPRAY_EMITTER = 'BNGP_sprinkler'
local SPRAY_MAX = 8
local SPRAY_SPAN = 0.8   -- the share of an edge a row covers, so the ends of two edges do not pile up at a corner
local SPRAY_ROOM = 0.35
local SPRAY_OUT = 0.45   -- how far a plume leans away from the piece, against straight up
local SPRAY_VEL0, SPRAY_VEL1 = 0.8, 4.2
local SPRAY_JIT = 0.8    -- how far a count may be dealt off what was asked for, at full variation
local SPRAY_VAR = 0.5    -- how far a throw may be dealt off the power set, at full variation
local JET_VEL0, JET_VEL1 = 0.7, 2.6
local JET_LEAN0, JET_LEAN = 0.55, 1.15  -- radians, so 31 degrees off vertical up to 66
local JET_LEAN_VAR = 0.25 -- how far a single jet's lean is dealt off the ring's, at full variation
local JET_RING = 0.08     -- how far off the axis the nozzles sit
local JET_G = 9.81
local JET_EJECT = 3.0    -- the sprinkler datablock's own ejectionVelocity, which the node's velocity multiplies
local SPOUT_EL = 0.70    -- how far a spout is tipped up off the horizontal, in radians, about 40 degrees
local SPOUT_REACH = 0.75
local SPOUT_K = 1.5
local SPOUT_VEL0, SPOUT_VEL1 = 0.8, 2.6

-- Module state.
local WET = { WaterBlock = true, River = true, ParticleEmitterNode = true }


-- Deterministic 0..1 from a real key, so a fountain is reproducible from its seed alone. The same sine hash the layout
-- uses, kept here rather than reached for, so nothing in toolUtilities depends on a tool's own folder.
local function hash01(k)
  local x = sin(k * 12.9898) * 43758.5453
  return x - floor(x)
end

-- An ornamental pool: dark, still and shallow. The park editor's lake skin with the waves taken off, the ripple
-- scaled down to a few metres rather than a lake's hundred, and the foam pulled back to a lace at the stonework.
local function applyPoolLook(o)
  o:setField('fullReflect', 0, 'false')
  o:setField('baseColor', 0, '20 54 58 255') -- standing water over dark stone, green rather than open-sky blue
  o:setField('rippleTex', 0, '/core/art/water/ripple.dds')
  o:setField('foamTex', 0, '/core/art/water/foam.dds')
  o:setField('depthGradientTex', 0, '/core/art/water/river_depthcolor_ramp_b.png')
  o:setField('depthGradientMax', 0, '0.08') -- a basin this shallow has to reach the deep end of the ramp early
  o:setField('clarity', 0, '0.02')
  o:setField('cubemap', 0, 'DefaultSkyCubemap')
  o:setField('fresnelBias', 0, '0.0')
  o:setField('fresnelPower', 0, '12.0')
  -- A basin being fed by falling water is not a still lake: without movement on it the surface reads as dark glass,
  -- and a tight specular on top of that reads as polish. Broad highlight, and ripple that actually travels.
  o:setField('specularPower', 0, '120')
  o:setField('overallWaveMagnitude', 0, '0')
  o:setField('overallRippleMagnitude', 0, '0.75')
  o:setField('foamMaxDepth', 0, '0.1')
  o:setField('overallFoamOpacity', 0, '1.2')
  o:setField('reflectivity', 0, '0.05')
  o:setField('reflectTexSize', 0, '128')
  o:setField('reflectMaxRateMs', 0, '30')
  o:setField('viscosity', 0, '0.001')
  o:setField('waterFogDensity', 0, '4.0')
  o:setField('rippleDir', 0, '0.0 1.0'); o:setField('rippleDir', 1, '0.707 0.707'); o:setField('rippleDir', 2, '0.5 0.86')
  o:setField('rippleSpeed', 0, '0.09'); o:setField('rippleSpeed', 1, '0.12'); o:setField('rippleSpeed', 2, '0.06')
  o:setField('rippleTexScale', 0, '2.0 2.0'); o:setField('rippleTexScale', 1, '1.5 3.0'); o:setField('rippleTexScale', 2, '4.0 4.0')
end

-- A falling sheet: the river tool's white-water skin off its waterfalls, with the texture scales pulled in from a
-- cliff's twenty metres to a rim's one so the foam reads at the size of the drop it is on.
local function applyFallLook(o, flow)
  o:setField('fullReflect', 0, 'false')
  o:setField('baseColor', 0, '163 163 163 255')
  o:setField('foamTex', 0, '/assets/materials/tileable/water/water_effects/waterfall_foam_b.color.dds')
  o:setField('rippleTex', 0, '/assets/materials/tileable/water/water_effects/waterfall_foam_nm.normal.dds')
  o:setField('depthGradientTex', 0, '/assets/materials/tileable/water/depthcolor_ramp/river_depthcolor_ramp_b.png')
  o:setField('cubemap', 0, 'DefaultSkyCubemap')
  o:setField('depthGradientMax', 0, '1.5')
  o:setField('overallFoamOpacity', 0, tostring(2.5 + 4.0 * flow))
  o:setField('overallRippleMagnitude', 0, tostring(2.0 + 4.0 * flow))
  o:setField('overallWaveMagnitude', 0, '0')
  o:setField('foamMaxDepth', 0, '6')
  o:setField('reflectNormalUp', 0, 'true')
  o:setField('rippleDir', 0, '0.0 1.0'); o:setField('rippleDir', 1, '0.0 1.0'); o:setField('rippleDir', 2, '0.0 1.0')
  o:setField('rippleSpeed', 0, '0.7'); o:setField('rippleSpeed', 1, '1.0'); o:setField('rippleSpeed', 2, '0.3')
  o:setField('rippleTexScale', 0, '4 2'); o:setField('rippleTexScale', 1, '1.5 3'); o:setField('rippleTexScale', 2, '4 1.2')
end

-- One pool: a rectangle turned onto its own heading, surface at `p.z`, carried `p.depth` below that so there is always
-- ground under it to draw against. `half` is the half width along that heading and `halfV` across it, which a fountain
-- basin leaves alone -- it is square -- and a pond sets to the box its outline needs.
local function makePool(tag, folder, p, ids, names, sub)
  local o = createObject('WaterBlock')
  if not o then return end
  o.cansave = false
  applyPoolLook(o)
  local nm = kitPlacer.safeName('PZWater_' .. tag .. '_', sub)
  o:registerObject(nm)
  folder:addObject(o)
  local m = MatrixF(true)
  m:setFromEuler(vec3(0, 0, p.th or 0))
  m:setPosition(vec3(p.x, p.y, p.z))
  o:setTransform(m)
  local wu = max(p.half * 2, LEAST_M)
  local wv = max((p.halfV or p.half) * 2, LEAST_M)
  -- The surface grid has to be finer than the block itself, or the engine clamps it and warns for every pool -- and
  -- kept well finer than that besides, because the surface is laid in whole cells of this and whatever is left over of
  -- the block past the last full cell is not drawn. Anything asking for a box that certainly reaches its own edge has
  -- to allow a margin wider than one cell, which is why this is held down to half a metre rather than a whole one.
  o:setField('gridElementSize', 0, tostring(max(0.25, min(0.5, min(wu, wv) * 0.2))))
  o:setScale(vec3(wu, wv, max(p.depth, LEAST_M)))
  ids[#ids + 1] = o:getId(); names[#names + 1] = nm
end

-- Edge k of a rim, anticlockwise from the corner cut before its +X face: odd is a cut corner, even a flat. Gives the
-- way it faces once turned onto the site's grain, how far out it stands, how wide it runs, and how far out the pool
-- below reaches on that heading -- a square sheet reaches out by its diagonal, so a corner has the most room of all.
local function rimEdge(f, k)
  local a = (k - 2) * OCTANT
  local ca, sa = cos(a), sin(a)
  local dx, dy = ca * f.ct - sa * f.sn, ca * f.sn + sa * f.ct
  local catch = f.catch or 0
  if k % 2 == 1 then return dx, dy, (2 * f.r - f.c) / DIAG, f.c * DIAG, catch * DIAG end
  return dx, dy, f.r, 2 * (f.r - f.c), catch
end

-- How far clear of the rim the whole rim's water is thrown: enough to keep the ribbons off vertical, but never so
-- far that the tightest edge overshoots the pool catching it.
local function fallRun(f)
  local run = (f.zTop - f.zBot) / FALL_SLOPE
  for k = 1, EDGES do
    local _, _, r0, _, catch = rimEdge(f, k)
    run = min(run, catch - r0 - FALL_LAND_M)
  end
  return max(0.06, run)
end

-- One edge's sheet, hung off the drip edge of the bowl above and thrown into the pool below. It covers the whole of
-- its edge and widens with the mitre as it goes out, so it meets its neighbours at every node.
local function makeFall(tag, folder, f, dx, dy, r0, w, run, flow, ids, names, sub)
  local o = createObject('River')
  if not o then return end
  o.cansave = false
  applyFallLook(o, flow)
  local nm = kitPlacer.safeName('PZFall_' .. tag .. '_', sub)
  o:registerObject(nm)
  folder:addObject(o)
  local up = vec3(0, 0, 1)
  local zs = { f.zTop, (f.zTop + f.zBot) * 0.5, f.zBot - 0.04 }
  local outs = { 0.02, run * 0.5, run }
  for i = 1, 3 do
    local out = outs[i]
    local r = r0 + out
    local wi = max(w + MITRE * out + JOIN_M, LEAST_FALL_M)
    o:insertNodeNoRegen(vec3(f.x + dx * r, f.y + dy * r, zs[i]), wi, FALL_DEPTH, up, i - 1)
  end
  o:regenerate()
  ids[#ids + 1] = o:getId(); names[#names + 1] = nm
end

-- One emitter, thrown along (ax, ay, az). A ParticleEmitterNode ejects along its own Z and cones off that, so the
-- heading goes in as the frame's third column and the other two are whatever is square to it.
local function makeEmitter(tag, folder, x, y, z, ax, ay, az, v, ids, names, kind, sub)
  local em = createObject('ParticleEmitterNode')
  if not em then return end
  em.cansave = false
  em:setField('emitter', 0, SPRAY_EMITTER)
  em:setField('dataBlock', 0, 'lightExampleEmitterNodeData1')
  em:setField('velocity', 0, format('%.2f', v))
  local nm = kitPlacer.safeName('PZ' .. kind .. '_' .. tag .. '_', sub)
  em:registerObject(nm)
  folder:addObject(em)
  local out = vec3(ax, ay, az)
  if out:squaredLength() < 1e-12 then out:set(0, 0, 1) end
  out = out:normalized()
  -- Any pair square to the throw will do for the other two columns, so long as the reference is not along it.
  local ref = (abs(out.z) > 0.99) and vec3(0, 1, 0) or vec3(0, 0, 1)
  local right = out:cross(ref):normalized()
  local m = MatrixF(true)
  m:setColumn(0, right)
  m:setColumn(1, out:cross(right):normalized())
  m:setColumn(2, out)
  m:setPosition(vec3(x, y, z))
  em:setTransform(m)
  ids[#ids + 1] = em:getId(); names[#names + 1] = nm
end

-- A throw dealt off the power asked for. Zero variation gives every plume the same one, which is what makes a ring
-- read as one emitter copied round; full variation spreads them half either side.
local function dealt(v, var, key)
  return v * (1 + (hash01(key) * 2 - 1) * var * SPRAY_VAR)
end

-- Spray along where one edge's sheet lands, spread across the plunge rather than sat at its midpoint. `w` is the
-- sheet's width down there, which is wider than the edge it left, and `catch` how far the pool reaches on this
-- heading, which is what decides whether the row has room to stand on the plunge or has to come in off it.
local function sprayRow(tag, folder, f, dx, dy, r0, w, run, catch, n, v, var, key, ids, names, sub)
  local r = max(min(r0 + run, catch - SPRAY_ROOM), 0)
  for s = 1, n do
    local t = (n > 1) and ((s - 1) / (n - 1) - 0.5) * w * SPRAY_SPAN or 0
    makeEmitter(tag, folder, f.x + dx * r - dy * t, f.y + dy * r + dx * t, f.zBot,
      dx * SPRAY_OUT, dy * SPRAY_OUT, 1, dealt(v, var, key + s * 3.9), ids, names, 'Spray', sub .. '_' .. s)
  end
end

-- The hardest a jet at this lean may be thrown and still come down within `reach` of the axis, having fallen `drop`
-- to get there. Solving the throw of a projectile launched above its landing plane for the range wanted gives
-- v = Rg / sqrt(2g cos(lean) (R sin(lean) + drop cos(lean))). Drag only shortens the real arc, so this errs inward.
-- A jet with no lean travels nowhere sideways and is left alone; that is the single-jet case.
local function jetCap(lean, reach, drop)
  local s, c = sin(lean), cos(lean)
  if lean < 1e-3 or c < 1e-3 or reach <= 0 then return JET_VEL1 end
  local d = 2 * JET_G * c * (reach * s + max(drop, 0) * c)
  if d < 1e-6 then return JET_VEL1 end
  return reach * JET_G / sqrt(d) / JET_EJECT
end

-- The jets off one crown and the ring of spouts round the foot of it. A single jet is always sent straight up, since
-- one leaning jet just looks like a fountain aimed wrong. A ring is spread evenly round the axis and thrown well out,
-- each jet on its own lean, so they arc off the top and come down over the water below.
--
-- `cr.reach` is how far out an arc may land and still be in that water, and `cr.drop` how far it falls to get there.
-- Both are the caller's to work out, because what catches the water is the caller's business: a cascade throws into
-- its own bottom basin, a pond into itself.
local function makeCrown(tag, folder, cr, ids, names, sub)
  local var = min(max(cr.var or 0.5, 0), 1)
  local seed = (cr.seed or 1) * 7.1
  local nj = min(max(floor((cr.jets or 0) + 0.5), 0), SPRAY_MAX)
  if nj > 0 and cr.jetZ then
    local v = JET_VEL0 + min(max(cr.jetPow or 0.5, 0), 1) * (JET_VEL1 - JET_VEL0)
    local ring = (nj > 1) and JET_RING or 0
    local lean0 = (nj > 1) and (JET_LEAN0 + min(max(cr.jetOut or 0, 0), 1) * (JET_LEAN - JET_LEAN0)) or 0
    -- Anything the arc clips on the way -- and a fountain's tiers rise into it -- only brings the water down sooner.
    local reach = max(cr.reach or 0, 0) - SPRAY_ROOM
    local drop = max(cr.drop or 0, 0)
    for i = 1, nj do
      local a = (i - 1) / nj * 2 * pi
      local lean = lean0 * (1 + (hash01(seed + i * 1.3) * 2 - 1) * var * JET_LEAN_VAR)
      local cl, sl = cos(lean), sin(lean)
      local cx, sx = cos(a), sin(a)
      local ux, uy = cx * sl, sx * sl               -- the heading, leaned out off vertical
      local ox, oy = cx * ring, sx * ring           -- and the nozzle it leaves, set off the axis
      makeEmitter(tag, folder, cr.x + ox * cr.ct - oy * cr.sn, cr.y + ox * cr.sn + oy * cr.ct, cr.jetZ,
        ux * cr.ct - uy * cr.sn, ux * cr.sn + uy * cr.ct, cl,
        min(dealt(v, var, seed + i * 2.7), jetCap(lean, reach, drop)), ids, names, 'Jet', sub .. '_' .. i)
    end
  end
  local ns = min(max(floor((cr.spouts or 0) + 0.5), 0), SPRAY_MAX)
  if ns > 0 and cr.spoutZ then
    local ce, se = cos(SPOUT_EL), sin(SPOUT_EL)
    local v = min(max(sqrt(max(cr.spoutRoom or 0, 0) * SPOUT_REACH) * SPOUT_K, SPOUT_VEL0), SPOUT_VEL1)
    for i = 1, ns do
      -- Turned onto the site's grain like everything else the piece carries, so the ring lines up with its faces.
      local a = (i - 1) / ns * 2 * pi
      local ux, uy = cos(a), sin(a)
      local dx, dy = ux * cr.ct - uy * cr.sn, ux * cr.sn + uy * cr.ct
      makeEmitter(tag, folder, cr.x + dx * cr.spoutR, cr.y + dy * cr.spoutR, cr.spoutZ,
        dx * ce, dy * ce, se, dealt(v, var, seed + i * 4.3), ids, names, 'Spout', sub .. '_' .. i)
    end
  end
end

--- Everything wet under one folder, off. Swept by class rather than by a list of ids kept somewhere, because undo
--- restores a document whose ids belong to objects that have since been deleted: what is actually in the folder is the
--- only account of it that cannot go stale.
local function remove(folder)
  if not folder then return end
  local doomed = {}
  for i = 0, folder:getCount() - 1 do
    local o = folder:getObject(i)
    if o and o.getClassName and WET[o:getClassName()] then doomed[#doomed + 1] = o end
  end
  for i = 1, #doomed do doomed[i]:delete() end
end

--- Flood whatever the centrepiece put down, then hang a sheet off each face of every bowl that spills. `tag` names the
--- site standing it, so two of the same square on one map do not fight over object names. Returns the ids and the names.
local function build(ca, folder, tag)
  remove(folder)
  local pools = ca and ca.pools
  if not (pools and folder) then return nil, nil end
  tag = tostring(tag or 'site')
  local ids, names = {}, {}
  for i = 1, #pools do makePool(tag, folder, pools[i], ids, names, i) end
  local flow = min(max(ca.flow or 0.55, 0), 1)
  -- Power is a throw, which is what sets how big a plume reads; variation is how far each one is dealt off it.
  local var = min(max(ca.sprayVar or 0.5, 0), 1)
  local sprayV = SPRAY_VEL0 + min(max(ca.sprayPow or 0.5, 0), 1) * (SPRAY_VEL1 - SPRAY_VEL0)
  for i = 1, #(ca.falls or {}) do
    local f = ca.falls[i]
    local flatW = max(2 * (f.r - f.c), 1e-3)
    local sprays = min(max(floor((f.sprays or 0) + 0.5), 0), SPRAY_MAX)
    local run = fallRun(f)
    for k = 1, EDGES do
      local dx, dy, r0, edgeW, catch = rimEdge(f, k)
      makeFall(tag, folder, f, dx, dy, r0, edgeW, run, flow, ids, names, i .. '_' .. k)
      if sprays > 0 then
        local key = (ca.spraySeed or 1) * 13.7 + i * 5.3 + k * 2.1
        local jit = 1 + (hash01(key) * 2 - 1) * var * SPRAY_JIT
        local n = max(1, min(SPRAY_MAX, floor(sprays * edgeW / flatW * jit + 0.5)))
        sprayRow(tag, folder, f, dx, dy, r0, edgeW + MITRE * run, run, catch, n, sprayV, var, key, ids, names,
          i .. '_' .. k)
      end
    end
  end
  for i = 1, #(ca.crowns or {}) do makeCrown(tag, folder, ca.crowns[i], ids, names, 'c' .. i) end
  return ids, names
end

--- Flip every pool to persistent and hand back its names, which is what a burn's undo deletes by.
local function commit(ids)
  local names = {}
  for i = 1, #(ids or {}) do
    local o = scenetree.findObjectById(ids[i])
    if o then
      o.canSave = true; o.cansave = true
      local nm = o.getName and o:getName()
      if nm and nm ~= '' then names[#names + 1] = tostring(nm) end
    end
  end
  return names
end

--- The record a manifest carries, in the site's own frame. Only what `build` reads: the editor's centrepiece knows a
--- great deal more about itself -- its apron, its grab handles, its balustrade -- and none of that is water.
---
--- The one anchor and the one angle are the whole of the placement. Everything else is a radius, a half-width or a
--- height off that anchor, so a site turned on the ground turns its water simply by turning those two.
local function localise(ca, ox, oy, oz)
  if not (ca and ca.pools and #ca.pools > 0) then return nil end
  local out = { x = ca.x - ox, y = ca.y - oy, th = ca.th or 0,
                flow = ca.flow, sprayPow = ca.sprayPow, sprayVar = ca.sprayVar, spraySeed = ca.spraySeed,
                pools = {}, crowns = {} }
  -- Each pool off the anchor rather than on it, and each with its own turn off the grain: a fountain's basins sit at
  -- nought on both and a pond somewhere across the square sits wherever it was drawn.
  for i = 1, #ca.pools do
    local p = ca.pools[i]
    out.pools[i] = { ox = p.x - ca.x, oy = p.y - ca.y, oth = (p.th or 0) - (ca.th or 0),
                     z = p.z - oz, half = p.half, halfV = p.halfV, depth = p.depth }
  end
  for i = 1, #(ca.crowns or {}) do
    local c = ca.crowns[i]
    out.crowns[i] = { ox = c.x - ca.x, oy = c.y - ca.y,
                      jets = c.jets, jetPow = c.jetPow, jetOut = c.jetOut, jetZ = c.jetZ and (c.jetZ - oz) or nil,
                      spouts = c.spouts, spoutZ = c.spoutZ and (c.spoutZ - oz) or nil,
                      spoutR = c.spoutR, spoutRoom = c.spoutRoom,
                      reach = c.reach, drop = c.drop, var = c.var, seed = c.seed }
  end
  local falls = {}
  for i = 1, #(ca.falls or {}) do
    local f = ca.falls[i]
    falls[i] = { r = f.r, c = f.c, catch = f.catch, sprays = f.sprays,
                 zTop = f.zTop - oz, zBot = f.zBot - oz }
  end
  out.falls = (#falls > 0) and falls or nil
  return out
end

--- And back the other way: a manifest record stood at a place, on a heading, ready for `build`. The turn is the site's,
--- so the anchor swings round the placement and the grain takes the yaw straight on top of its own.
---
--- `ox, oy` is the point in the site's own frame that the placement turns about -- the middle of its footprint rather than
--- the bake origin at a corner. Everything else a placement stands is measured off the same two numbers.
local function place(rec, px, py, pz, yaw, ox, oy)
  if not (rec and rec.pools) then return nil end
  yaw = yaw or 0
  local c, s = cos(yaw), sin(yaw)
  local lx, ly = (rec.x or 0) - (ox or 0), (rec.y or 0) - (oy or 0)
  local x, y = px + lx * c - ly * s, py + lx * s + ly * c
  local th = (rec.th or 0) + yaw
  local ca = { x = x, y = y, th = th, ct = cos(th), sn = sin(th),
               flow = rec.flow, sprayPow = rec.sprayPow, sprayVar = rec.sprayVar, spraySeed = rec.spraySeed,
               pools = {}, crowns = {} }
  -- Each offset swung round the placement by the same turn the anchor took, so the assembly keeps its own arrangement
  -- however the site is stood.
  for i = 1, #rec.pools do
    local p = rec.pools[i]
    local qx, qy = p.ox or 0, p.oy or 0
    ca.pools[i] = { x = x + qx * c - qy * s, y = y + qx * s + qy * c, z = pz + p.z,
                    half = p.half, halfV = p.halfV, depth = p.depth, th = th + (p.oth or 0) }
  end
  for i = 1, #(rec.crowns or {}) do
    local cr = rec.crowns[i]
    local qx, qy = cr.ox or 0, cr.oy or 0
    ca.crowns[i] = { x = x + qx * c - qy * s, y = y + qx * s + qy * c, ct = ca.ct, sn = ca.sn,
                     jets = cr.jets, jetPow = cr.jetPow, jetOut = cr.jetOut,
                     jetZ = cr.jetZ and (pz + cr.jetZ) or nil,
                     spouts = cr.spouts, spoutZ = cr.spoutZ and (pz + cr.spoutZ) or nil,
                     spoutR = cr.spoutR, spoutRoom = cr.spoutRoom,
                     reach = cr.reach, drop = cr.drop, var = cr.var, seed = cr.seed }
  end
  if rec.falls then
    ca.falls = {}
    for i = 1, #rec.falls do
      local f = rec.falls[i]
      ca.falls[i] = { x = x, y = y, r = f.r, c = f.c, catch = f.catch, sprays = f.sprays,
                      zTop = pz + f.zTop, zBot = pz + f.zBot, ct = ca.ct, sn = ca.sn }
    end
  end
  return ca
end


-- Public interface.
M.build = build
M.remove = remove
M.commit = commit
M.localise = localise
M.place = place

return M