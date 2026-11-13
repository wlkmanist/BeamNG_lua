-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Turning what an editor just built in the world into what a manifest carries. Every site is designed standing somewhere on
-- a map and placed somewhere else entirely, so the one thing all three bakes do alike is subtract their own origin from
-- everything before writing it down: the geometry, the kit transforms, the lamps, the planting, the ground plan.
--
-- `ox, oy, oz` throughout is that origin. Whatever an editor picks for it does not matter to the placer, which re-pivots on
-- the bounds it reads back -- but it has to be the SAME origin for every list in the one manifest, or a square's lamps stand
-- ten metres off its paving.

local M = {}

-- Module constants.
local floor, min, max, sqrt = math.floor, math.min, math.max, math.sqrt
-- Plan polygons are ground for a heightmap of metre-ish cells to be graded against, so the millimetre is already finer than
-- anything downstream can act on. Rounded rather than stored full width, which only makes the json fatter.
local MM = 1000


local function round3(v) return floor(v * MM + 0.5) / MM end

--- One plan polygon, local to the bake origin. Nil for anything that is not a polygon, so a caller can collect the return
--- straight into a list and never has to check.
local function localRing(ring, ox, oy)
  if #(ring or {}) < 3 then return nil end
  local out = {}
  for i = 1, #ring do out[i] = { x = round3(ring[i].x - ox), y = round3(ring[i].y - oy) } end
  return out
end

--- A polyline the same way. Also does for the unit normals that go with one, called with a zero origin.
local function localPts(pts, ox, oy)
  local out = {}
  for i = 1, #(pts or {}) do out[i] = { x = round3(pts[i].x - ox), y = round3(pts[i].y - oy) } end
  return out
end

--- A list of them, nil when nothing in it was a polygon: an absent key in the manifest reads as "this site has none of
--- these", which is what every reader of a ground plan already expects.
local function localRings(rings, ox, oy)
  local out = {}
  for i = 1, #(rings or {}) do
    local r = localRing(rings[i], ox, oy)
    if r then out[#out + 1] = r end
  end
  return (#out > 0) and out or nil
end

--- The shapes a site asks the ground to be cut to, in its own frame. Terraform takes a feature one of two ways and every
--- producer in the tools emits one of them: a graded QUAD, whose four corners carry their own heights, or a set of RINGS
--- sharing one height. So this needs to know nothing about what any particular feature is FOR -- a tier floor, a flight's
--- rake, a retaining band -- which is the point: an editor works out what it wants from the terrain and the placer carves it
--- without either of them having to agree about anything but these two shapes.
---
--- Ring points go out flat, because a ring's height is the feature's and saying it per point is a second copy of the same
--- number. Whatever reads this back makes them vec3 again, which is what terraform tests polygons with.
local function localFeatures(features, ox, oy, oz)
  local out = nil
  for i = 1, #(features or {}) do
    local f = features[i]
    local rec = nil
    if f.quad and #f.quad >= 4 then
      local q = {}
      for k = 1, 4 do
        local p = f.quad[k]
        q[k] = { x = round3(p.x - ox), y = round3(p.y - oy), z = round3((p.z or oz) - oz) }
      end
      rec = { quad = q }
    else
      local rings = localRings(f.rings, ox, oy)
      if rings then rec = { rings = rings, z = round3((f.z or oz) - oz) } end
    end
    if rec then
      rec.mode = f.mode or 'carve'
      rec.band = f.band
      out = out or {}
      out[#out + 1] = rec
    end
  end
  return out
end

--- The terrain paint a site lays, in its own frame. Each coat is `{ m, ring }` or `{ m, xs, ys }` (cell by cell) from the
--- editor, and goes out named by layer, since an index is only good for the one terrain it was read off.
local function localPaint(coats, ox, oy)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  if not tb then return nil end
  local out = {}
  for i = 1, #(coats or {}) do
    local c = coats[i]
    local layer = tb:getMaterialName(c.m)
    if layer and c.ring then
      local ring = localRing(c.ring, ox, oy)
      if ring then out[#out + 1] = { layer = layer, ring = ring } end
    elseif layer and c.xs and #c.xs > 0 then
      local cells = {}
      for k = 1, #c.xs do cells[2 * k - 1], cells[2 * k] = round3(c.xs[k] - ox), round3(c.ys[k] - oy) end
      out[#out + 1] = { layer = layer, cells = cells }
    end
  end
  return (#out > 0) and out or nil
end

--- The kit placements, grouped by the shape they place. One group per distinct mesh becomes one instanced draw at the far
--- end, so a square with two hundred identical bollards costs one shape and two hundred transforms rather than two hundred
--- of each.
local function groupInstances(instances, ox, oy, oz)
  local byShape, order = {}, {}
  for i = 1, #(instances or {}) do
    local it = instances[i]
    if it.shape then
      -- Keyed by shape AND colour: the same lantern in two tones cannot share one group, because the tone is set on the
      -- object and not in the mesh.
      -- And by `street`: a piece standing on the pavement rather than on the site, which a placer seats on whatever
      -- pavement it is put down beside.
      -- And by `stand`: a post on the ground line, its height as baked, which a placer stretches to that pavement.
      local gl = it.glow
      local key = gl and (it.shape .. '|' .. gl[1] .. ',' .. gl[2] .. ',' .. gl[3]) or it.shape
      if it.street then key = key .. '|street' end
      if it.stand then key = key .. '|stand' .. it.stand end
      local g = byShape[key]
      if not g then
        g = { shape = it.shape, xf = {}, glow = gl, street = it.street or nil, stand = it.stand }
        byShape[key] = g
        order[#order + 1] = g
      end
      local xf, s = g.xf, it.scl
      local sx, sy, sz = 1, 1, 1
      if type(s) == 'number' then sx, sy, sz = s, s, s
      elseif type(s) == 'table' then sx, sy, sz = s.x or 1, s.y or 1, s.z or 1 end
      xf[#xf + 1] = it.px - ox; xf[#xf + 1] = it.py - oy; xf[#xf + 1] = it.pz - oz
      xf[#xf + 1] = it.ax or 1; xf[#xf + 1] = it.ay or 0; xf[#xf + 1] = it.az or 0
      xf[#xf + 1] = it.ux or 0; xf[#xf + 1] = it.uy or 0; xf[#xf + 1] = it.uz or 1
      xf[#xf + 1] = sx; xf[#xf + 1] = sy; xf[#xf + 1] = sz
    end
  end
  return order
end

--- Read the frames of already-placed kit pieces back off the scene, appending them to `out` as the same instance records
--- `groupInstances` takes.
local function harvestGlow(o)
  if o:getField('nightEmissive', 0) ~= '1' then return nil end
  local s = o:getField('nightEmissiveColor', 0)
  if not s or s == '' then return nil end
  local r, g, b = s:match('([%-%d%.eE]+)%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)')
  if not r then return nil end
  return { tonumber(r), tonumber(g), tonumber(b) }
end

local function harvestKit(list, out)
  out = out or {}
  for i = 1, #(list or {}) do
    -- A tool keeps its pieces either as kit entries or as the objects themselves, and both are a list of things standing in
    -- the scene. Taking either saves every caller wrapping one shape to look like the other.
    local e = list[i]
    local o = e and (e.obj or e)
    if o and simObjectExists(o) then
      local shape = o:getField('shapeName', 0)
      if shape and shape ~= '' then
        local glow = harvestGlow(o)
        local m = o:getTransform()
        local a, u, p = m:getColumn(0), m:getColumn(2), m:getColumn(3)
        local la = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
        local lu = sqrt(u.x * u.x + u.y * u.y + u.z * u.z)
        if la > 1e-9 and lu > 1e-9 then
          local s = o.scale
          out[#out + 1] = { shape = shape, glow = glow,
                            px = p.x, py = p.y, pz = p.z,
                            ax = a.x / la, ay = a.y / la, az = a.z / la,
                            ux = u.x / lu, uy = u.y / lu, uz = u.z / lu,
                            scl = { x = s.x, y = s.y, z = s.z } }
        end
      end
    end
  end
  return out
end

--- How many pieces a group list stands, for a readout that wants to say so before anything is written.
local function instanceCount(groups)
  local n = 0
  for i = 1, #(groups or {}) do n = n + #groups[i].xf / 12 end
  return n
end

--- The lamps that go with the pieces, in the site's own frame like everything else here.
local function localLamps(lights, ox, oy, oz)
  local out = {}
  for i = 1, #(lights or {}) do
    local lt = lights[i]
    -- `glow` where the lamp came off a lit fixture, `col` where it came off a tone the tool set. The same three numbers
    -- either way, and not worth making one tool rename its own field to satisfy the other.
    local c = lt.glow or lt.col or { 1, 1, 1 }
    out[i] = { x = lt.px - ox, y = lt.py - oy, z = lt.pz - oz,
               r = lt.radius, b = lt.brightness, col = { c[1], c[2], c[3] }, street = lt.street or nil }
    -- A lamp that aims goes out as a cone and the direction it looks, in the site's own frame so the placer can turn it with
    -- the rest. Absent for the bulbs, which is what tells the two apart on the way back in.
    if lt.dx then
      out[i].dir = { lt.dx, lt.dy, lt.dz }
      out[i].cone = lt.cone
    end
  end
  return (#out > 0) and out or nil
end

--- Planting travels as anchors rather than as scattered items, because the forest belongs to the level and not to the site:
--- whatever places this re-scatters them when it burns.
local function localPlants(anchors, ox, oy, oz)
  local out = nil
  for i = 1, #(anchors or {}) do
    local g = anchors[i]
    if g.items then
      local list = {}
      for k = 1, #g.items do
        local it = g.items[k]
        list[k] = { x = round3(it.x - ox), y = round3(it.y - oy), sp = it.sp, s = it.s, a = round3(it.a or 0) }
      end
      if #list > 0 then
        out = out or {}
        out[#out + 1] = { items = list }
      end
    elseif next(g.species or {}) ~= nil then
      local pts, list = g.points, {}
      for k = 1, #pts do
        local p = pts[k]
        list[k] = { x = p.x - ox, y = p.y - oy, z = p.z - oz }
      end
      out = out or {}
      -- The seed travels already worked out, so whatever replants this does not have to know how a palette seed becomes a
      -- scatter seed. Same number as the editor used, so the same plants come up in the same places at the same sizes.
      out[#out + 1] = { points = list, species = g.species, speciesWeights = g.speciesWeights,
                        size = g.size, vary = g.vary, seed = g.seed, drape = g.drape or nil, street = g.street or nil }
    end
  end
  return out
end

--- How many plants a bake would carry, across every anchor. Only for the readout.
local function plantCount(anchors)
  local n = 0
  for i = 1, #(anchors or {}) do
    local g = anchors[i]
    n = n + #(g.items or g.points or {})
  end
  return n
end

--- The extent of everything the bake places, so the placer can frame a site, pick it under the cursor and know how much room
--- it needs before it has loaded a single mesh.
local function bounds(parts, instances, ox, oy, oz)
  local lx, ly, lz = 1e30, 1e30, 1e30
  local hx, hy, hz = -1e30, -1e30, -1e30
  for p = 1, #(parts or {}) do
    local v = parts[p].verts
    for i = 1, #v do
      local x, y, z = v[i].x - ox, v[i].y - oy, v[i].z - oz
      lx, ly, lz = min(lx, x), min(ly, y), min(lz, z)
      hx, hy, hz = max(hx, x), max(hy, y), max(hz, z)
    end
  end
  for i = 1, #(instances or {}) do
    local it = instances[i]
    local x, y, z = it.px - ox, it.py - oy, it.pz - oz
    lx, ly, lz = min(lx, x), min(ly, y), min(lz, z)
    hx, hy, hz = max(hx, x), max(hy, y), max(hz, z)
  end
  if lx > hx then return { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 } end
  return { x = lx, y = ly, z = lz }, { x = hx, y = hy, z = hz }
end


-- Public interface.
M.localRing = localRing
M.localPts = localPts
M.localRings = localRings
M.localFeatures = localFeatures
M.localPaint = localPaint
M.groupInstances = groupInstances
M.harvestKit = harvestKit
M.instanceCount = instanceCount
M.localLamps = localLamps
M.localPlants = localPlants
M.plantCount = plantCount
M.bounds = bounds

return M