-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- A cap over an outline that has to follow a height field: a square grid on the outline's own grain, cut to the outline.
--
-- Every cell clear of the outline is two triangles at the field's heights. Only the cells the outline runs through are cut,
-- and each of those is a handful of points, so no triangle is ever longer than a cell and none is a sliver -- which is what
-- splitting an ear-clipped cap towards the field could not promise: its fans off a long straight side halve into ever
-- thinner fans, and the field is still read only where they happen to land.

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')
local polyBool = require('editor/toolUtilities/polyBool')

-- Module constants.
local floor, min, max = math.floor, math.min, math.max
local ON_RIM2 = 1e-10   -- how near (squared, m) a cut point has to lie to an outline edge to take that edge's height
local WELD = 1e4        -- points are welded to a tenth of a millimetre, so two cells cutting the same edge share the point
local HOLE_PAD = 1e-3   -- how far past the cell a hole is cut before it is taken out, so it leaves nothing along the cell edge
local CUT_CACHE_MAX = 20000 -- cut cells kept per generation; two generations are held

-- One cell kept, cut exactly on its lines, so the corner two cuts make is the grid's own node to the last bit.
local clipRect = geom.clipRingRect2D

-- Module state.
-- Holed cells by their exact points. The boolean is a pure function of them and an edit hands most cells over unchanged.
local cutNew, cutOld, cutCount = {}, {}, 0

-- The cap being built, flat: corner k at (vx[k], vy[k], vz[k]), triangle t the corners tri[3t-2..3t]. Handed back as `mesh`,
-- so it holds only until the next build.
local vx, vy, vz, triBuf = {}, {}, {}, {}
local mesh = { x = vx, y = vy, z = vz, tri = triBuf, nv = 0, nt = 0 }
local weld = {}                     -- welded point key -> corner
local tHead, tTail = {}, {}         -- cell -> first / last outline edge running through it
local tNext, tR, tK = {}, {}, {}    -- per touch: the next in its cell, the ring, the edge's first point
local edgeAt, flipped = {}, {}      -- delaunay: edge key -> triangle, triangle -> pass it was flipped in
local idsBuf, cutBuf = {}, {}

-- What the build in hand reads.
local curR, curHasZ, curCf, curZAt
local weldU0, weldV0, weldSpan = 0, 0, 0

local function cutKey(cap, cut)
  local fmt, parts = string.format, {}
  for k = 1, #cap do parts[#parts + 1] = fmt('%.17g,%.17g', cap[k].x, cap[k].y) end
  for c = 1, #cut do
    parts[#parts + 1] = '|'
    local h = cut[c]
    for k = 1, #h do parts[#parts + 1] = fmt('%.17g,%.17g', h[k].x, h[k].y) end
  end
  return table.concat(parts, ';')
end

-- What is left of `cap` with every ring of `cut` taken out of it, as areas. Read only: the same tables go to every caller.
local function cutPieces(cap, cut)
  local key = cutKey(cap, cut)
  local pieces = cutNew[key]
  if pieces then return pieces end
  pieces = cutOld[key]
  if not pieces then
    -- One hole at a time: handed over together they are read even-odd, and where two overlap they cancel and pave the
    -- overlap back over.
    local res = { regions = { cap } }
    for c = 1, #cut do
      res = polyBool.difference(res, { regions = { cut[c] } })
      if #(res.regions or {}) == 0 then break end
    end
    pieces = polyBool.areas(res.regions or {})
  end
  if cutCount >= CUT_CACHE_MAX then cutOld, cutNew, cutCount = cutNew, {}, 0 end
  cutNew[key] = pieces
  cutCount = cutCount + 1
  return pieces
end

local function onOneSide(a, b, c, ua, ub, va, vb)
  return (a.x == ua and b.x == ua and c.x == ua) or (a.x == ub and b.x == ub and c.x == ub)
      or (a.y == va and b.y == va and c.y == va) or (a.y == vb and b.y == vb and c.y == vb)
end

-- An outline that wraps round outside a cell's corner is clipped to a run out along the cell's side and straight back, zero
-- wide, even where it crosses the cell only once. The triangulation fans across that run and lays a slab outside the outline,
-- so every point lying on one side with both its neighbours goes first. What is left covers exactly the same ground.
local function dropSpikes(cap, ua, ub, va, vb)
  local again = true
  while again do
    again = false
    for i = #cap, 1, -1 do
      local n = #cap
      if n < 3 then return cap end
      local a, b, c = cap[(i + n - 2) % n + 1], cap[i], cap[i % n + 1]
      if (a.x == b.x and a.y == b.y) or onOneSide(a, b, c, ua, ub, va, vb) then
        table.remove(cap, i)
        again = true
      end
    end
  end
  return cap
end

-- Whether corner `d` lies inside the circle through the anticlockwise corners `a, b, c`.
local function inCircle(a, b, c, d)
  local dx, dy = vx[d], vy[d]
  local ax, ay, bx, by, cx, cy = vx[a] - dx, vy[a] - dy, vx[b] - dx, vy[b] - dy, vx[c] - dx, vy[c] - dy
  return (ax * ax + ay * ay) * (bx * cy - cx * by) - (bx * bx + by * by) * (ax * cy - cx * ay)
       + (cx * cx + cy * cy) * (ax * by - bx * ay) > 1e-9
end

local function ccw(a, b, c)
  return (vx[b] - vx[a]) * (vy[c] - vy[a]) - (vy[b] - vy[a]) * (vx[c] - vx[a]) > 1e-12
end

-- Flip every inner edge whose two triangles would be fatter the other way round, until none would. The cuts of one cell are
-- triangulated without sight of the next, so where the outline passes close by a node they can join three points that all but
-- lie in a line -- flat on the ground, and a fold the moment the field puts a centimetre between them. The outline's own edges
-- have one triangle each and are never touched, and the grid's square cells are left as they are.
local function delaunay(nt)
  table.clear(flipped)
  for pass = 1, 32 do
    table.clear(edgeAt)
    local flips = 0
    for t = 1, nt do
      local b3 = 3 * t
      -- Read up front: a triangle flipped part way round still offers its old edges to those after it.
      local t1, t2, t3 = triBuf[b3 - 2], triBuf[b3 - 1], triBuf[b3]
      for k = 1, 3 do
        local i, j, c
        if k == 1 then i, j, c = t1, t2, t3 elseif k == 2 then i, j, c = t2, t3, t1 else i, j, c = t3, t1, t2 end
        local key = i < j and i * 1048576 + j or j * 1048576 + i
        local other = edgeAt[key]
        if other and flipped[t] ~= pass and flipped[other] ~= pass then
          local o3 = 3 * other
          local o1, o2, o3v = triBuf[o3 - 2], triBuf[o3 - 1], triBuf[o3]
          local d = (o1 ~= i and o1 ~= j) and o1 or ((o2 ~= i and o2 ~= j) and o2 or o3v)
          if inCircle(i, j, c, d) and ccw(c, i, d) and ccw(d, j, c) then
            triBuf[b3 - 2], triBuf[b3 - 1], triBuf[b3] = c, i, d
            triBuf[o3 - 2], triBuf[o3 - 1], triBuf[o3] = d, j, c
            flipped[t], flipped[other] = pass, pass
            flips = flips + 1
          end
        elseif not other then
          edgeAt[key] = t
        end
      end
    end
    if flips == 0 then break end
  end
end

local function inside(u, v)
  if not geom.pointInRing2D(u, v, curR[1]) then return false end
  for r = 2, #curR do
    if geom.pointInRing2D(u, v, curR[r]) then return false end
  end
  return true
end

-- A point's height: an outline edge's own where it lies on one that has heights, the field's anywhere else. `e` is the
-- first outline edge running through its cell.
local function zOf(u, v, e)
  while e do
    local r = tR[e]
    local pts = curR[r]
    local k = tK[e]
    local p, q = pts[k], pts[k % #pts + 1]
    local d2 = curHasZ[r] and geom.distSqPointSeg2D(u, v, p.x, p.y, q.x, q.y) or math.huge
    if d2 < ON_RIM2 then
      local L2 = (q.x - p.x) ^ 2 + (q.y - p.y) ^ 2
      local t = L2 > 0 and ((u - p.x) * (q.x - p.x) + (v - p.y) * (q.y - p.y)) / L2 or 0
      return p.z + (q.z - p.z) * min(1, max(0, t))
    end
    e = tNext[e]
  end
  local cf = curCf
  return curZAt(u * cf.ax + v * cf.inX, u * cf.ay + v * cf.inY)
end

local function vid(u, v, e)
  local key = (floor(u * WELD + 0.5) - weldU0) * weldSpan + (floor(v * WELD + 0.5) - weldV0)
  local id = weld[key]
  if not id then
    local cf = curCf
    id = mesh.nv + 1
    mesh.nv = id
    vx[id], vy[id], vz[id] = u * cf.ax + v * cf.inX, u * cf.ay + v * cf.inY, zOf(u, v, e)
    weld[key] = id
  end
  return id
end

-- Wound anticlockwise in the world, which the grain's frame turns over.
local function tri(a, b, c)
  if (vx[b] - vx[a]) * (vy[c] - vy[a]) - (vy[b] - vy[a]) * (vx[c] - vx[a]) < 0 then b, c = c, b end
  local n = mesh.nt + 1
  mesh.nt = n
  triBuf[3 * n - 2], triBuf[3 * n - 1], triBuf[3 * n] = a, b, c
end

--- The cap over `rings` (the outline, then its holes; open or closed) in world space, as the flat `mesh` (see above), or nil.
--- `cf` is the grain (`ax, ay` along it, `inX, inY` across), `zAt(x, y)` the field, `cell` the grid's pitch. A point on a
--- ring whose nodes carry heights keeps the straight line between them, since that is where its edging is swept; a ring
--- given without heights takes the field's along it.
local function build(rings, cf, zAt, cell)
  -- Everything is worked in the grain's frame, where the cells are square to the axes.
  local R, hasZ = {}, {}
  for r = 1, #rings do
    local src, pts = rings[r], {}
    local n = #src
    if n > 1 and src[1].x == src[n].x and src[1].y == src[n].y then n = n - 1 end
    for k = 1, n do
      local p = src[k]
      pts[k] = { x = p.x * cf.ax + p.y * cf.ay, y = p.x * cf.inX + p.y * cf.inY, z = p.z or 0 }
    end
    if n >= 3 then
      R[#R + 1] = pts
      hasZ[#R] = src[1].z ~= nil
    end
  end
  if #R == 0 then return nil end
  local outer = R[1]
  local u0, v0, u1, v1 = math.huge, math.huge, -math.huge, -math.huge
  for k = 1, #outer do
    local p = outer[k]
    u0, v0, u1, v1 = min(u0, p.x), min(v0, p.y), max(u1, p.x), max(v1, p.y)
  end
  local i0, i1, j0, j1 = floor(u0 / cell), floor(u1 / cell), floor(v0 / cell), floor(v1 / cell)
  local nI = i1 - i0 + 1

  -- Which outline edges run through each cell, by the box each edge spans, in the order they come.
  table.clear(tHead)
  table.clear(tTail)
  local nTouch = 0
  for r = 1, #R do
    local pts = R[r]
    for k = 1, #pts do
      local p, q = pts[k], pts[k % #pts + 1]
      for i = max(i0, floor(min(p.x, q.x) / cell)), min(i1, floor(max(p.x, q.x) / cell)) do
        for j = max(j0, floor(min(p.y, q.y) / cell)), min(j1, floor(max(p.y, q.y) / cell)) do
          local key = (j - j0) * nI + (i - i0)
          nTouch = nTouch + 1
          tR[nTouch], tK[nTouch], tNext[nTouch] = r, k, false
          local last = tTail[key]
          if last then tNext[last] = nTouch else tHead[key] = nTouch end
          tTail[key] = nTouch
        end
      end
    end
  end

  curR, curHasZ, curCf, curZAt = R, hasZ, cf, zAt
  mesh.nv, mesh.nt = 0, 0
  -- Welded on a key counted from a metre short of the grid's corner, exact while the cap spans under 9 km a side.
  table.clear(weld)
  weldU0, weldV0 = floor((i0 * cell - 1) * WELD), floor((j0 * cell - 1) * WELD)
  weldSpan = floor(((j1 + 1) * cell + 1) * WELD) - weldV0 + 1

  for j = j0, j1 do
    for i = i0, i1 do
      local ua, ub, va, vb = i * cell, (i + 1) * cell, j * cell, (j + 1) * cell
      local list = tHead[(j - j0) * nI + (i - i0)]
      if not list then
        if inside((ua + ub) * 0.5, (va + vb) * 0.5) then
          local a, b, c, d = vid(ua, va), vid(ub, va), vid(ub, vb), vid(ua, vb)
          tri(a, b, c)
          tri(a, c, d)
        end
      else
        local cap = dropSpikes(clipRect(outer, ua, ub, va, vb), ua, ub, va, vb)
        local cut, holed = cutBuf, false
        table.clear(cut)
        for r = 2, #R do
          local crossed = false
          local e = list
          while e do
            if tR[e] == r then
              crossed = true
              local h = clipRect(R[r], ua - HOLE_PAD, ub + HOLE_PAD, va - HOLE_PAD, vb + HOLE_PAD)
              if #h >= 3 then cut[#cut + 1] = h; holed = true end
              break
            end
            e = tNext[e]
          end
          -- No edge of it anywhere near the cell, so the cell is wholly inside the hole or wholly out of it.
          if not crossed and geom.pointInRing2D((ua + ub) * 0.5, (va + vb) * 0.5, R[r]) then cap = {} break end
        end
        if #cap >= 3 then
          -- The outline in and out of the cell more than once leaves the cut joined to itself along the cell's sides, and a
          -- hole through the cell has to be taken out of it: the boolean sorts out what is left of either.
          local crossings = 0
          for k = 1, #cap do
            local p = cap[k]
            local onU, onV = p.x == ua or p.x == ub, p.y == va or p.y == vb
            if p.z == nil and onU ~= onV then crossings = crossings + 1 end
          end
          local pieces
          if holed then
            pieces = cutPieces(cap, cut)
          elseif crossings > 2 then
            pieces = polyBool.areas(polyBool.unionMany({ { regions = { cap } } }).regions)
          else
            pieces = { { ring = cap, holes = {} } }
          end
          for s = 1, #pieces do
            local pc = pieces[s]
            local pv, pt = geom.triangulateWithHoles2D(pc.ring, (#pc.holes > 0) and pc.holes or nil)
            if pt and #pt > 0 then
              local ids = idsBuf
              for k = 1, #pv do ids[k] = vid(pv[k].x, pv[k].y, list) end
              for t = 1, #pt do
                local a, b, c = ids[pt[t][1]], ids[pt[t][2]], ids[pt[t][3]]
                if a ~= b and b ~= c and a ~= c then tri(a, b, c) end
              end
            end
          end
        end
      end
    end
  end
  curR, curHasZ, curCf, curZAt = nil, nil, nil, nil
  if mesh.nt == 0 then return nil end
  delaunay(mesh.nt)
  return mesh
end

--- Those of `rings` that can reach a cell of the grid a cap over `outer` is laid on. Any other is never clipped into a cell
--- and never holds a cell's centre, so the cap comes out the same without it.
local function reaching(outer, rings, cf, cell)
  local function box(ring)
    local u0, v0, u1, v1 = math.huge, math.huge, -math.huge, -math.huge
    for k = 1, #ring do
      local p = ring[k]
      local u, v = p.x * cf.ax + p.y * cf.ay, p.x * cf.inX + p.y * cf.inY
      u0, v0, u1, v1 = min(u0, u), min(v0, v), max(u1, u), max(v1, v)
    end
    return u0, v0, u1, v1
  end
  local u0, v0, u1, v1 = box(outer)
  u0, v0 = floor(u0 / cell) * cell - HOLE_PAD, floor(v0 / cell) * cell - HOLE_PAD
  u1, v1 = (floor(u1 / cell) + 1) * cell + HOLE_PAD, (floor(v1 / cell) + 1) * cell + HOLE_PAD
  local out = {}
  for r = 1, #rings do
    local a, b, c, d = box(rings[r])
    if c >= u0 and a <= u1 and d >= v0 and b <= v1 then out[#out + 1] = rings[r] end
  end
  return out
end


-- Public interface.
M.build = build
M.reaching = reaching

return M