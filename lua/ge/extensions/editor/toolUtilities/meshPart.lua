-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Generic mesh-part assembly for baked kit pieces. A "part" is { verts, normals, uvs, faces } where each face entry is
-- { v, n, u } with 0-BASED indices -- the exact format both BeamNG's ProceduralMesh and the DAE exporter (daeExport)
-- consume. Every *Kit geometry module (bridgeKit, islandKit, ...) builds through here so they all share ONE winding
-- convention, and so daeExport's single winding-reversal is always correct for them.
--
-- WINDING: face4 winds each triangle for BeamNG's ProceduralMesh, whose front face has its geometric winding normal
-- pointing AWAY from the visible side; the stored SHADING normal points toward the visible side. daeExport reverses the
-- winding when baking to COLLADA (whose front face is the standard "winding normal toward viewer"). Every kit builds
-- through face4, so that single reversal is always correct -- don't hand-assemble faces with the opposite convention.

local M = {}

local sqrt, min, max, huge, floor, abs = math.sqrt, math.min, math.max, math.huge, math.floor, math.abs


-- A pooled part's entry tables, kept past a clear so the next part the pool hands out refills them rather than making new.
local spareOf = setmetatable({}, { __mode = 'k' })

--- Parts that are emitted and dropped, made again and again: `newPart(pool)` hands out the pool's parts in turn, refilling
--- the tables the last round left. Only for parts that are done with by the next `poolReset`. The engine copies a mesh's
--- data as it is created, so a part that has been through emitObject is done with.
local function newPool()
  return { n = 0 }
end

local function poolReset(pool)
  pool.n = 0
end

local function newPart(pool)
  if not pool then return { verts = {}, normals = {}, uvs = {}, faces = {} } end
  local n = pool.n + 1
  pool.n = n
  local p = pool[n]
  if p then
    for k in pairs(p) do
      if k ~= 'verts' and k ~= 'normals' and k ~= 'uvs' and k ~= 'faces' then p[k] = nil end
    end
    table.clear(p.verts)
    table.clear(p.normals)
    table.clear(p.uvs)
    table.clear(p.faces)
  else
    p = { verts = {}, normals = {}, uvs = {}, faces = {} }
    pool[n] = p
    spareOf[p] = { v = {}, n = {}, u = {}, f = {} }
  end
  return p
end

-- Append one vert/normal/uv, returning its 0-BASED index (ProceduralMesh faces are 0-based). Internal to face4 -- kits
-- assemble through face4, never vert-by-vert.
local function addV(part, x, y, z)
  local verts = part.verts
  local i = #verts + 1
  local sp = spareOf[part]
  local t = sp and sp.v[i]
  if t then
    t.x, t.y, t.z = x, y, z
  else
    t = { x = x, y = y, z = z }
    if sp then sp.v[i] = t end
  end
  verts[i] = t
  return i - 1
end

local function addN(part, x, y, z)
  local normals = part.normals
  local i = #normals + 1
  local sp = spareOf[part]
  local t = sp and sp.n[i]
  if t then
    t.x, t.y, t.z = x, y, z
  else
    t = { x = x, y = y, z = z }
    if sp then sp.n[i] = t end
  end
  normals[i] = t
  return i - 1
end

local function addU(part, u, v)
  local uvs = part.uvs
  local i = #uvs + 1
  local sp = spareOf[part]
  local t = sp and sp.u[i]
  if t then
    t.u, t.v = u, v
  else
    t = { u = u, v = v }
    if sp then sp.u[i] = t end
  end
  uvs[i] = t
  return i - 1
end

-- One face corner: vert `v`, normal `n`, uv `u`, all 0-based.
local function addF(part, v, n, u)
  local faces = part.faces
  local i = #faces + 1
  local sp = spareOf[part]
  local t = sp and sp.f[i]
  if t then
    t.v, t.n, t.u = v, n, u
  else
    t = { v = v, n = n, u = u }
    if sp then sp.f[i] = t end
  end
  faces[i] = t
end

-- Emit one quad p1->p2->p3->p4 into `part`, front visible from the (rx,ry,rz) side. BeamNG's ProceduralMesh front
-- face has its GEOMETRIC winding normal pointing AWAY from the visible side, so wind the triangles with their face
-- normal opposite ref and store the shading normal toward ref.
-- Optional snx/sny/snz overrides the stored SHADING normal (winding still follows the real geometry): used to shade the
-- sloped end-flap tops with the flat slab-top normal so the chamfer blends in instead of reading as a lit facet.
local function face4(part, p1, p2, p3, p4, rx, ry, rz, u1, u2, u3, u4, snx, sny, snz)
  local ux, uy, uz = p2.x - p1.x, p2.y - p1.y, p2.z - p1.z
  local vx, vy, vz = p4.x - p1.x, p4.y - p1.y, p4.z - p1.z
  local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
  if nx * rx + ny * ry + nz * rz > 0 then -- winding normal faces ref: flip so it faces AWAY (front faces ref)
    p2, p4 = p4, p2
    u2, u4 = u4, u2
    nx, ny, nz = -nx, -ny, -nz
  end
  local sx, sy, sz
  if snx then sx, sy, sz = snx, sny, snz else sx, sy, sz = -nx, -ny, -nz end -- shading normal toward the visible side
  local nl = sqrt(sx * sx + sy * sy + sz * sz)
  if nl > 1e-9 then sx, sy, sz = sx / nl, sy / nl, sz / nl end
  local ni = addN(part, sx, sy, sz)
  local i1 = addV(part, p1.x, p1.y, p1.z); local a1 = addU(part, u1[1], u1[2])
  local i2 = addV(part, p2.x, p2.y, p2.z); local a2 = addU(part, u2[1], u2[2])
  local i3 = addV(part, p3.x, p3.y, p3.z); local a3 = addU(part, u3[1], u3[2])
  local i4 = addV(part, p4.x, p4.y, p4.z); local a4 = addU(part, u4[1], u4[2])
  addF(part, i1, ni, a1); addF(part, i2, ni, a2); addF(part, i3, ni, a3)
  addF(part, i1, ni, a1); addF(part, i3, ni, a3); addF(part, i4, ni, a4)
end


-- Like face4, but with a distinct SHADING normal per corner (n1..n4 = {x,y,z}, toward the visible side), for smoothly
-- shading a bumpy surface from precomputed vertex normals -- instead of the single flat facet normal face4 stores, which
-- makes a displaced surface read as a patchwork of flat facets. Winding still follows the real geometry (ref side).
local function face4n(part, p1, p2, p3, p4, rx, ry, rz, u1, u2, u3, u4, n1, n2, n3, n4)
  local ux, uy, uz = p2.x - p1.x, p2.y - p1.y, p2.z - p1.z
  local vx, vy, vz = p4.x - p1.x, p4.y - p1.y, p4.z - p1.z
  local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
  if nx * rx + ny * ry + nz * rz > 0 then -- winding normal faces ref: flip so it faces AWAY (front faces ref)
    p2, p4 = p4, p2
    u2, u4 = u4, u2
    n2, n4 = n4, n2
  end
  local m1 = addN(part, n1.x, n1.y, n1.z)
  local m2 = addN(part, n2.x, n2.y, n2.z)
  local m3 = addN(part, n3.x, n3.y, n3.z)
  local m4 = addN(part, n4.x, n4.y, n4.z)
  local i1 = addV(part, p1.x, p1.y, p1.z); local a1 = addU(part, u1[1], u1[2])
  local i2 = addV(part, p2.x, p2.y, p2.z); local a2 = addU(part, u2[1], u2[2])
  local i3 = addV(part, p3.x, p3.y, p3.z); local a3 = addU(part, u3[1], u3[2])
  local i4 = addV(part, p4.x, p4.y, p4.z); local a4 = addU(part, u4[1], u4[2])
  addF(part, i1, m1, a1); addF(part, i2, m2, a2); addF(part, i3, m3, a3)
  addF(part, i1, m1, a1); addF(part, i3, m3, a3); addF(part, i4, m4, a4)
end


-- Emit one triangle p1->p2->p3 into `part`, front visible from the (rx,ry,rz) side (same winding contract as face4:
-- the geometric winding normal ends up pointing AWAY from ref, the stored shading normal toward it). For flat caps
-- (roofs / terraces) where a quad won't do.
local function face3(part, p1, p2, p3, rx, ry, rz, u1, u2, u3)
  local ux, uy, uz = p2.x - p1.x, p2.y - p1.y, p2.z - p1.z
  local vx, vy, vz = p3.x - p1.x, p3.y - p1.y, p3.z - p1.z
  local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
  if nx * rx + ny * ry + nz * rz > 0 then -- winding normal faces ref: flip so it faces AWAY (front faces ref)
    p2, p3 = p3, p2
    u2, u3 = u3, u2
    nx, ny, nz = -nx, -ny, -nz
  end
  local sx, sy, sz = -nx, -ny, -nz -- shading normal toward the visible side
  local nl = sqrt(sx * sx + sy * sy + sz * sz)
  if nl > 1e-9 then sx, sy, sz = sx / nl, sy / nl, sz / nl end
  local ni = addN(part, sx, sy, sz)
  local i1 = addV(part, p1.x, p1.y, p1.z); local a1 = addU(part, u1[1], u1[2])
  local i2 = addV(part, p2.x, p2.y, p2.z); local a2 = addU(part, u2[1], u2[2])
  local i3 = addV(part, p3.x, p3.y, p3.z); local a3 = addU(part, u3[1], u3[2])
  addF(part, i1, ni, a1); addF(part, i2, ni, a2); addF(part, i3, ni, a3)
end

--- Triangles over shared corners, all flat: corner i at (x[i], y[i], z[i]) with uv (u[i], v[i]), `nv` of them, and `nt`
--- triangles whose corners are tri[3t-2..3t]. Each is wound and shaded exactly as face3 lays it, but a corner is stored
--- once however many triangles meet at it.
local function faces3(part, x, y, z, u, v, nv, tri, nt, rx, ry, rz)
  local v0, u0 = #part.verts, #part.uvs
  for i = 1, nv do
    addV(part, x[i], y[i], z[i])
    addU(part, u[i], v[i])
  end
  for t = 1, nt do
    local i1, i2, i3 = tri[3 * t - 2], tri[3 * t - 1], tri[3 * t]
    local ux, uy, uz = x[i2] - x[i1], y[i2] - y[i1], z[i2] - z[i1]
    local vx, vy, vz = x[i3] - x[i1], y[i3] - y[i1], z[i3] - z[i1]
    local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    if nx * rx + ny * ry + nz * rz > 0 then
      i2, i3 = i3, i2
      nx, ny, nz = -nx, -ny, -nz
    end
    local sx, sy, sz = -nx, -ny, -nz
    local nl = sqrt(sx * sx + sy * sy + sz * sz)
    if nl > 1e-9 then sx, sy, sz = sx / nl, sy / nl, sz / nl end
    local ni = addN(part, sx, sy, sz)
    addF(part, v0 + i1 - 1, ni, u0 + i1 - 1)
    addF(part, v0 + i2 - 1, ni, u0 + i2 - 1)
    addF(part, v0 + i3 - 1, ni, u0 + i3 - 1)
  end
end

-- A quad that may really be a TRIANGLE, one corner having run into its neighbour: a moulding step springing off the
-- face behind it, a spandrel closing on the head it reaches, an arc facet meeting its own crown. Left a quad, half of
-- it is a triangle of no area -- three more indices that draw nothing.
local function quad(part, p1, p2, p3, p4, rx, ry, rz, u1, u2, u3, u4)
  local function same(a, b)
    return abs(a.x - b.x) < 1e-6 and abs(a.y - b.y) < 1e-6 and abs(a.z - b.z) < 1e-6
  end
  if same(p1, p2) then return face3(part, p1, p3, p4, rx, ry, rz, u1, u3, u4) end
  if same(p2, p3) then return face3(part, p1, p2, p4, rx, ry, rz, u1, u2, u4) end
  if same(p3, p4) or same(p4, p1) then return face3(part, p1, p2, p3, rx, ry, rz, u1, u2, u3) end
  return face4(part, p1, p2, p3, p4, rx, ry, rz, u1, u2, u3, u4)
end

-- ============================ 2D outlines ===================================
-- A closed ring of { x, y } pairs wound CCW, so an edge a->b has outward normal (dy, -dx) and an ear clip can trust its
-- own sign test. A kit lays its outline out in whatever order reads best where it is written and hands it through here.
local function ccwRing(poly)
  local s, n = 0, #poly
  for i = 1, n do local a, b = poly[i], poly[i % n + 1]; s = s + (a[1] * b[2] - b[1] * a[2]) end
  if s >= 0 then return poly end
  local o = {}
  for i = n, 1, -1 do o[#o + 1] = poly[i] end
  return o
end

local function inTri(px, py, ax, ay, bx, by, cx, cy)
  local d1 = (px - bx) * (ay - by) - (ax - bx) * (py - by)
  local d2 = (px - cx) * (by - cy) - (bx - cx) * (py - cy)
  local d3 = (px - ax) * (cy - ay) - (cx - ax) * (py - ay)
  return not (((d1 < 0) or (d2 < 0) or (d3 < 0)) and ((d1 > 0) or (d2 > 0) or (d3 > 0)))
end

-- Ear clipping over a CCW ring, as index triples into it.
local function triangulate(poly)
  local n = #poly
  local idx, out, guard = {}, {}, 0
  for i = 1, n do idx[i] = i end
  while #idx > 3 and guard < n do
    guard = guard + 1
    local cut = false
    for k = 1, #idx do
      local i0, i1, i2 = idx[(k - 2) % #idx + 1], idx[k], idx[k % #idx + 1]
      local a, b, c = poly[i0], poly[i1], poly[i2]
      if (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1]) > 1e-12 then
        local ok = true
        for m = 1, #idx do
          local j = idx[m]
          if j ~= i0 and j ~= i1 and j ~= i2 and inTri(poly[j][1], poly[j][2], a[1], a[2], b[1], b[2], c[1], c[2]) then
            ok = false
            break
          end
        end
        if ok then
          out[#out + 1] = { i0, i1, i2 }
          table.remove(idx, k)
          cut = true
          break
        end
      end
    end
    if not cut then break end
  end
  if #idx == 3 then out[#out + 1] = { idx[1], idx[2], idx[3] } end
  return out
end


-- The plan of a square post of half-width `d` about (cx, cy), its vertical arrises taken off by `cham`. Wound CCW, so an
-- edge's outward normal is (dy, -dx). Under a tenth of a millimetre it is the plain square, so one call site covers a
-- chamfered die and the crisp square work over it.
local function postPlan(d, cx, cy, cham)
  if cham < 1e-4 then
    return { { cx - d, cy - d }, { cx + d, cy - d }, { cx + d, cy + d }, { cx - d, cy + d } }
  end
  return { { cx - d + cham, cy - d }, { cx + d - cham, cy - d }, { cx + d, cy - d + cham }, { cx + d, cy + d - cham },
           { cx + d - cham, cy + d }, { cx - d + cham, cy + d }, { cx - d, cy + d - cham }, { cx - d, cy - d + cham } }
end

-- One stage of a dressed post -- a pier's die, a newel's cap -- as that plan extruded z0..z1, every face out and both
-- ends closed. UVs in metres scaled by `uv`: U round the plan and V up the stage, so the stone matches the wall the post
-- stands in. The masonry kits stack these to build a pier or a newel out of its mouldings, which is why this lives here
-- rather than in one of them: wallKit already depends on propKit, so neither can hold it for the other.
local function postStage(part, d, cx, cy, z0, z1, cham, uv)
  local pl = postPlan(d, cx, cy, cham or 0)
  local n, s, k = #pl, 0, uv or 1
  for i = 1, n do
    local a, b = pl[i], pl[i % n + 1]
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local l = sqrt(dx * dx + dy * dy)
    if l > 1e-9 then
      face4(part, { x = a[1], y = a[2], z = z0 }, { x = b[1], y = b[2], z = z0 },
                  { x = b[1], y = b[2], z = z1 }, { x = a[1], y = a[2], z = z1 },
            dy / l, -dx / l, 0,
            { s * k, z0 * k }, { (s + l) * k, z0 * k }, { (s + l) * k, z1 * k }, { s * k, z1 * k })
      s = s + l
    end
  end
  for i = 2, n - 1 do
    local a, b, e = pl[1], pl[i], pl[i + 1]
    local ua, ub, ue = { a[1] * k, a[2] * k }, { b[1] * k, b[2] * k }, { e[1] * k, e[2] * k }
    face3(part, { x = a[1], y = a[2], z = z1 }, { x = b[1], y = b[2], z = z1 }, { x = e[1], y = e[2], z = z1 },
          0, 0, 1, ua, ub, ue)
    face3(part, { x = a[1], y = a[2], z = z0 }, { x = e[1], y = e[2], z = z0 }, { x = b[1], y = b[2], z = z0 },
          0, 0, -1, ua, ue, ub)
  end
end

-- Rescale a built part list's UVs in place. Lets a kit lay its UVs out in plain metres, which is the only way to keep a
-- swept or lathed piece readable, then convert the lot to the kit's tiling in one place at bake time.
local function scaleUVs(parts, s)
  for i = 1, #parts do
    local uvs = parts[i].uvs
    for k = 1, #uvs do local t = uvs[k]; t.u, t.v = t.u * s, t.v * s end
  end
  return parts
end

-- Tint every part in a list wearing material `m`.
local function tintParts(parts, m, tint)
  if not tint then return parts end
  for i = 1, #parts do
    if parts[i].material == m then parts[i].tint = tint end
  end
  return parts
end

-- The triangles in a part list. The face list holds one entry per CORNER, three to a triangle, so what a bake actually
-- wrote can be reported rather than guessed at.
local function partsTris(parts)
  local n = 0
  for i = 1, #(parts or {}) do n = n + floor(#parts[i].faces / 3) end
  return n
end

-- The middle of a part list's extent. A shape is written around this and its static placed at it: written around the world
-- origin instead, it loses precision the further out the map it stands.
local function partsCentre(parts)
  local lox, loy, loz, hix, hiy, hiz = huge, huge, huge, -huge, -huge, -huge
  for i = 1, #(parts or {}) do
    local v = parts[i].verts
    for k = 1, #v do
      local p = v[k]
      lox, hix = min(lox, p.x), max(hix, p.x)
      loy, hiy = min(loy, p.y), max(hiy, p.y)
      loz, hiz = min(loz, p.z), max(hiz, p.z)
    end
  end
  if lox > hix then return 0, 0, 0 end
  return (lox + hix) * 0.5, (loy + hiy) * 0.5, (loz + hiz) * 0.5
end

-- ProceduralMesh fills its 16-bit index buffer with a 16-bit counter: past 65535 corners in one mesh the counter wraps,
-- the engine never leaves that loop and the game hangs. Corners (face entries) bound the engine's vertex count from above.
local MESH_CORNER_CAP = 60000

local function corners(parts)
  local n = 0
  for i = 1, #parts do n = n + #parts[i].faces end
  return n
end

local function remap(map, dst, src, i)
  if i == nil then return nil end
  local j = map[i]
  if not j then
    j = #dst
    dst[j + 1] = src[i + 1]
    map[i] = j
  end
  return j
end

-- Face entries c0..c1 of `src` as a part of their own, holding only the verts, normals and uvs they use.
local function slicePart(src, c0, c1)
  local dst = newPart()
  for k, v in pairs(src) do
    if dst[k] == nil then dst[k] = v end
  end
  local vMap, nMap, uMap = {}, {}, {}
  local f, df = src.faces, dst.faces
  for c = c0, c1 do
    local e = f[c]
    df[#df + 1] = { v = remap(vMap, dst.verts, src.verts, e.v), n = remap(nMap, dst.normals, src.normals, e.n),
                    u = remap(uMap, dst.uvs, src.uvs, e.u) }
  end
  return dst
end

-- `parts` dealt into lists of at most MESH_CORNER_CAP corners each, whole triangles only.
local function batches(parts)
  local out, cur, n = {}, {}, 0
  for i = 1, #parts do
    local p = parts[i]
    local m, c = #p.faces, 1
    while m - c + 1 >= 3 do
      local take = min(m - c + 1, MESH_CORNER_CAP - n)
      take = take - take % 3
      if take == 0 then
        out[#out + 1] = cur
        cur, n = {}, 0
      else
        cur[#cur + 1] = (c == 1 and take == m) and p or slicePart(p, c, c + take - 1)
        n, c = n + take, c + take
      end
    end
  end
  if #cur > 0 then out[#out + 1] = cur end
  return out
end

-- The parts each live mesh was made from, by mesh id, so it can still be written out as a shape after the fact. Pooled parts
-- are refilled for the next mesh, so a mesh made from any is not kept.
local liveParts = {}
local keptSinceSweep = 0
local SWEEP_EVERY = 2000

local function keepParts(m, parts)
  for i = 1, #parts do
    if spareOf[parts[i]] then return end
  end
  liveParts[m:getId()] = parts
  keptSinceSweep = keptSinceSweep + 1
  if keptSinceSweep < SWEEP_EVERY then return end
  keptSinceSweep = 0
  for id in pairs(liveParts) do
    if not scenetree.findObjectById(id) then liveParts[id] = nil end
  end
end

local function partsOf(id)
  return liveParts[id]
end

-- A surface draped decals lie on: a deck, a slab, a tunnel floor, a paved square. Decals clip to static shapes but not to
-- forest items, so whatever hands a tool's meshes over to a level keeps these as TSStatics. Saved with the object.
local function markDecalSurface(o)
  o.decalSurface = '1'
end

local function isDecalSurface(o)
  return o:getField('decalSurface', '') == '1'
end

local function emitOne(folder, name, parts, collide, decalSurface)
  local m = createObject('ProceduralMesh')
  if not m then return nil end
  m:registerObject(name or '')
  m.canSave = false
  if not collide then m:setField('collisionType', 0, 'None') end
  if decalSurface then markDecalSurface(m) end
  folder:addObject(m.obj)
  m:createMesh({ parts }) -- with collision on, this is where the engine cooks the hull
  keepParts(m, parts)
  return m
end

-- Build one ProceduralMesh named `name` from `parts`, in `folder`, replacing whatever was there under that name. A nil
-- name leaves it unnamed, for an owner that holds the mesh itself and clears it with its folder. Too many corners for one
-- mesh and it comes back as a SimGroup of several under that name instead; owners only test and delete what they get.
--
-- Nothing to collide with by default. Most of what is stamped this way is a floor the terrain has already been carved to
-- match, or a face on a piece that carries a hull of its own, and cooking a hull for it would only pay for the same surface
-- twice. Ask for `collide` where the mesh really is the only thing there -- a kerb standing over a carriageway that a car
-- is meant to feel. `decalSurface` marks it as a surface draped decals lie on.
local function emitObject(folder, name, parts, collide, decalSurface)
  if not folder or not parts or #parts == 0 then return nil end
  local stale = name and scenetree.findObject(name) -- a same-named mesh survives a Lua-only reload
  if stale then stale:delete() end
  local total = corners(parts)
  if total <= MESH_CORNER_CAP then return emitOne(folder, name, parts, collide, decalSurface) end
  local g = createObject('SimGroup')
  if not g then return nil end
  g:registerObject(name or '')
  g.canSave = false
  folder:addObject(g.obj)
  local b = batches(parts)
  for i = 1, #b do emitOne(g, nil, b[i], collide, decalSurface) end
  log('I', 'meshPart', string.format('%s: %d corners split over %d meshes', tostring(name), total, #b))
  return g
end


-- Public interface.
M.newPool = newPool
M.poolReset = poolReset
M.newPart = newPart
M.face4 = face4
M.face4n = face4n
M.face3 = face3
M.faces3 = faces3
M.quad = quad
M.ccwRing = ccwRing
M.triangulate = triangulate
M.postPlan = postPlan
M.postStage = postStage
M.scaleUVs = scaleUVs
M.tintParts = tintParts
M.partsTris = partsTris
M.partsCentre = partsCentre
M.emitObject = emitObject
M.partsOf = partsOf
M.markDecalSurface = markDecalSurface
M.isDecalSurface = isDecalSurface

return M