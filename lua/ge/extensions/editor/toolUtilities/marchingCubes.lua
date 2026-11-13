-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Marching cubes surface extraction (Lorensen & Cline 1987, tables after Paul Bourke). Extracts a triangle mesh from a
-- scalar density field sampled on a regular 3D grid, at the iso = 0 crossing, treating F > 0 as INSIDE (solid). Returns a raw
-- indexed mesh { verts (positions), tris (1-based) } in the sampler's coordinate space. No normals: the caller re-derives
-- smooth (area-weighted) normals after welding/decimation, so computing per-vertex gradient normals here would be wasted work.

local M = {}

-- Module constants.
local floor = math.floor
local band, bor, lshift = bit.band, bit.bor, bit.lshift


local function maxi(a, b) if a > b then return a end return b end

-- Triangle list per cube case: triples of edge indices (0-11), terminated by -1. 256 rows.
local triTable = {
[0]={-1},
{0,8,3,-1},{0,1,9,-1},{1,8,3,9,8,1,-1},{1,2,10,-1},{0,8,3,1,2,10,-1},{9,2,10,0,2,9,-1},{2,8,3,2,10,8,10,9,8,-1},
{3,11,2,-1},{0,11,2,8,11,0,-1},{1,9,0,2,3,11,-1},{1,11,2,1,9,11,9,8,11,-1},{3,10,1,11,10,3,-1},{0,10,1,0,8,10,8,11,10,-1},
{3,9,0,3,11,9,11,10,9,-1},{9,8,10,10,8,11,-1},{4,7,8,-1},{4,3,0,7,3,4,-1},{0,1,9,8,4,7,-1},{4,1,9,4,7,1,7,3,1,-1},
{1,2,10,8,4,7,-1},{3,4,7,3,0,4,1,2,10,-1},{9,2,10,9,0,2,8,4,7,-1},{2,10,9,2,9,7,2,7,3,7,9,4,-1},{8,4,7,3,11,2,-1},
{11,4,7,11,2,4,2,0,4,-1},{9,0,1,8,4,7,2,3,11,-1},{4,7,11,9,4,11,9,11,2,9,2,1,-1},{3,10,1,3,11,10,7,8,4,-1},
{1,11,10,1,4,11,1,0,4,7,11,4,-1},{4,7,8,9,0,11,9,11,10,11,0,3,-1},{4,7,11,4,11,9,9,11,10,-1},{9,5,4,-1},
{9,5,4,0,8,3,-1},{0,5,4,1,5,0,-1},{8,5,4,8,3,5,3,1,5,-1},{1,2,10,9,5,4,-1},{3,0,8,1,2,10,4,9,5,-1},
{5,2,10,5,4,2,4,0,2,-1},{2,10,5,3,2,5,3,5,4,3,4,8,-1},{9,5,4,2,3,11,-1},{0,11,2,0,8,11,4,9,5,-1},
{0,5,4,0,1,5,2,3,11,-1},{2,1,5,2,5,8,2,8,11,4,8,5,-1},{10,3,11,10,1,3,9,5,4,-1},{4,9,5,0,8,1,8,10,1,8,11,10,-1},
{5,4,0,5,0,11,5,11,10,11,0,3,-1},{5,4,8,5,8,10,10,8,11,-1},{9,7,8,5,7,9,-1},{9,3,0,9,5,3,5,7,3,-1},
{0,7,8,0,1,7,1,5,7,-1},{1,5,3,3,5,7,-1},{9,7,8,9,5,7,10,1,2,-1},{10,1,2,9,5,0,5,3,0,5,7,3,-1},
{8,0,2,8,2,5,8,5,7,10,5,2,-1},{2,10,5,2,5,3,3,5,7,-1},{7,9,5,7,8,9,3,11,2,-1},{9,5,7,9,7,2,9,2,0,2,7,11,-1},
{2,3,11,0,1,8,1,7,8,1,5,7,-1},{11,2,1,11,1,7,7,1,5,-1},{9,5,8,8,5,7,10,1,3,10,3,11,-1},
{5,7,0,5,0,9,7,11,0,1,0,10,11,10,0,-1},{11,10,0,11,0,3,10,5,0,8,0,7,5,7,0,-1},{11,10,5,7,11,5,-1},{10,6,5,-1},
{0,8,3,5,10,6,-1},{9,0,1,5,10,6,-1},{1,8,3,1,9,8,5,10,6,-1},{1,6,5,2,6,1,-1},{1,6,5,1,2,6,3,0,8,-1},
{9,6,5,9,0,6,0,2,6,-1},{5,9,8,5,8,2,5,2,6,3,2,8,-1},{2,3,11,10,6,5,-1},{11,0,8,11,2,0,10,6,5,-1},
{0,1,9,2,3,11,5,10,6,-1},{5,10,6,1,9,2,9,11,2,9,8,11,-1},{6,3,11,6,5,3,5,1,3,-1},{0,8,11,0,11,5,0,5,1,5,11,6,-1},
{3,11,6,0,3,6,0,6,5,0,5,9,-1},{6,5,9,6,9,11,11,9,8,-1},{5,10,6,4,7,8,-1},{4,3,0,4,7,3,6,5,10,-1},
{1,9,0,5,10,6,8,4,7,-1},{10,6,5,1,9,7,1,7,3,7,9,4,-1},{6,1,2,6,5,1,4,7,8,-1},{1,2,5,5,2,6,3,0,4,3,4,7,-1},
{8,4,7,9,0,5,0,6,5,0,2,6,-1},{7,3,9,7,9,4,3,2,9,5,9,6,2,6,9,-1},{3,11,2,7,8,4,10,6,5,-1},
{5,10,6,4,7,2,4,2,0,2,7,11,-1},{0,1,9,4,7,8,2,3,11,5,10,6,-1},{9,2,1,9,11,2,9,4,11,7,11,4,5,10,6,-1},
{8,4,7,3,11,5,3,5,1,5,11,6,-1},{5,1,11,5,11,6,1,0,11,7,11,4,0,4,11,-1},{0,5,9,0,6,5,0,3,6,11,6,3,8,4,7,-1},
{6,5,9,6,9,11,4,7,9,7,11,9,-1},{10,4,9,6,4,10,-1},{4,10,6,4,9,10,0,8,3,-1},{10,0,1,10,6,0,6,4,0,-1},
{8,3,1,8,1,6,8,6,4,6,1,10,-1},{1,4,9,1,2,4,2,6,4,-1},{3,0,8,1,2,9,2,4,9,2,6,4,-1},{0,2,4,4,2,6,-1},
{8,3,2,8,2,4,4,2,6,-1},{10,4,9,10,6,4,11,2,3,-1},{0,8,2,2,8,11,4,9,10,4,10,6,-1},{3,11,2,0,1,6,0,6,4,6,1,10,-1},
{6,4,1,6,1,10,4,8,1,2,1,11,8,11,1,-1},{9,6,4,9,3,6,9,1,3,11,6,3,-1},{8,11,1,8,1,0,11,6,1,9,1,4,6,4,1,-1},
{3,11,6,3,6,0,0,6,4,-1},{6,4,8,11,6,8,-1},{7,10,6,7,8,10,8,9,10,-1},{0,7,3,0,10,7,0,9,10,6,7,10,-1},
{10,6,7,1,10,7,1,7,8,1,8,0,-1},{10,6,7,10,7,1,1,7,3,-1},{1,2,6,1,6,8,1,8,9,8,6,7,-1},
{2,6,9,2,9,1,6,7,9,0,9,3,7,3,9,-1},{7,8,0,7,0,6,6,0,2,-1},{7,3,2,6,7,2,-1},{2,3,11,10,6,8,10,8,9,8,6,7,-1},
{2,0,7,2,7,11,0,9,7,6,7,10,9,10,7,-1},{1,8,0,1,7,8,1,10,7,6,7,10,2,3,11,-1},{11,2,1,11,1,7,10,6,1,6,7,1,-1},
{8,9,6,8,6,7,9,1,6,11,6,3,1,3,6,-1},{0,9,1,11,6,7,-1},{7,8,0,7,0,6,3,11,0,11,6,0,-1},{7,11,6,-1},
{7,6,11,-1},{3,0,8,11,7,6,-1},{0,1,9,11,7,6,-1},{8,1,9,8,3,1,11,7,6,-1},{10,1,2,6,11,7,-1},
{1,2,10,3,0,8,6,11,7,-1},{2,9,0,2,10,9,6,11,7,-1},{6,11,7,2,10,3,10,8,3,10,9,8,-1},{7,2,3,6,2,7,-1},
{7,0,8,7,6,0,6,2,0,-1},{2,7,6,2,3,7,0,1,9,-1},{1,6,2,1,8,6,1,9,8,8,7,6,-1},{10,7,6,10,1,7,1,3,7,-1},
{10,7,6,1,7,10,1,8,7,1,0,8,-1},{0,3,7,0,7,10,0,10,9,6,10,7,-1},{7,6,10,7,10,8,8,10,9,-1},{6,8,4,11,8,6,-1},
{3,6,11,3,0,6,0,4,6,-1},{8,6,11,8,4,6,9,0,1,-1},{9,4,6,9,6,3,9,3,1,11,3,6,-1},{6,8,4,6,11,8,2,10,1,-1},
{1,2,10,3,0,11,0,6,11,0,4,6,-1},{4,11,8,4,6,11,0,2,9,2,10,9,-1},{10,9,3,10,3,2,9,4,3,11,3,6,4,6,3,-1},
{8,2,3,8,4,2,4,6,2,-1},{0,4,2,4,6,2,-1},{1,9,0,2,3,4,2,4,6,4,3,8,-1},{1,9,4,1,4,2,2,4,6,-1},
{8,1,3,8,6,1,8,4,6,6,10,1,-1},{10,1,0,10,0,6,6,0,4,-1},{4,6,3,4,3,8,6,10,3,0,3,9,10,9,3,-1},{10,9,4,6,10,4,-1},
{4,9,5,7,6,11,-1},{0,8,3,4,9,5,11,7,6,-1},{5,0,1,5,4,0,7,6,11,-1},{11,7,6,8,3,4,3,5,4,3,1,5,-1},
{9,5,4,10,1,2,7,6,11,-1},{6,11,7,1,2,10,0,8,3,4,9,5,-1},{7,6,11,5,4,10,4,2,10,4,0,2,-1},
{3,4,8,3,5,4,3,2,5,10,5,2,11,7,6,-1},{7,2,3,7,6,2,5,4,9,-1},{9,5,4,0,8,6,0,6,2,6,8,7,-1},
{3,6,2,3,7,6,1,5,0,5,4,0,-1},{6,2,8,6,8,7,2,1,8,4,8,5,1,5,8,-1},{9,5,4,10,1,6,1,7,6,1,3,7,-1},
{1,6,10,1,7,6,1,0,7,8,7,0,9,5,4,-1},{4,0,10,4,10,5,0,3,10,6,10,7,3,7,10,-1},{7,6,10,7,10,8,5,4,10,4,8,10,-1},
{6,9,5,6,11,9,11,8,9,-1},{3,6,11,0,6,3,0,5,6,0,9,5,-1},{0,11,8,0,5,11,0,1,5,5,6,11,-1},
{6,11,3,6,3,5,5,3,1,-1},{1,2,10,9,5,11,9,11,8,11,5,6,-1},{0,11,3,0,6,11,0,9,6,5,6,9,1,2,10,-1},
{11,8,5,11,5,6,8,0,5,10,5,2,0,2,5,-1},{6,11,3,6,3,5,2,10,3,10,5,3,-1},{5,8,9,5,2,8,5,6,2,3,8,2,-1},
{9,5,6,9,6,0,0,6,2,-1},{1,5,8,1,8,0,5,6,8,3,8,2,6,2,8,-1},{1,5,6,2,1,6,-1},
{1,3,6,1,6,10,3,8,6,5,6,9,8,9,6,-1},{10,1,0,10,0,6,9,5,0,5,6,0,-1},{0,3,8,5,6,10,-1},{10,5,6,-1},
{11,5,10,7,5,11,-1},{11,5,10,11,7,5,8,3,0,-1},{5,11,7,5,10,11,1,9,0,-1},{10,7,5,10,11,7,9,8,1,8,3,1,-1},
{11,1,2,11,7,1,7,5,1,-1},{0,8,3,1,2,7,1,7,5,7,2,11,-1},{9,7,5,9,2,7,9,0,2,2,11,7,-1},
{7,5,2,7,2,11,5,9,2,3,2,8,9,8,2,-1},{2,5,10,2,3,5,3,7,5,-1},{8,2,0,8,5,2,8,7,5,10,2,5,-1},
{9,0,1,5,10,3,5,3,7,3,10,2,-1},{9,8,2,9,2,1,8,7,2,10,2,5,7,5,2,-1},{1,3,5,3,7,5,-1},{0,8,7,0,7,1,1,7,5,-1},
{9,0,3,9,3,5,5,3,7,-1},{9,8,7,5,9,7,-1},{5,8,4,5,10,8,10,11,8,-1},{5,0,4,5,11,0,5,10,11,11,3,0,-1},
{0,1,9,8,4,10,8,10,11,10,4,5,-1},{10,11,4,10,4,5,11,3,4,9,4,1,3,1,4,-1},{2,5,1,2,8,5,2,11,8,4,5,8,-1},
{0,4,11,0,11,3,4,5,11,2,11,1,5,1,11,-1},{0,2,5,0,5,9,2,11,5,4,5,8,11,8,5,-1},{9,4,5,2,11,3,-1},
{2,5,10,3,5,2,3,4,5,3,8,4,-1},{5,10,2,5,2,4,4,2,0,-1},{3,10,2,3,5,10,3,8,5,4,5,8,0,1,9,-1},
{5,10,2,5,2,4,1,9,2,9,4,2,-1},{8,4,5,8,5,3,3,5,1,-1},{0,4,5,1,0,5,-1},{8,4,5,8,5,3,9,0,5,0,3,5,-1},
{9,4,5,-1},{4,11,7,4,9,11,9,10,11,-1},{0,8,3,4,9,7,9,11,7,9,10,11,-1},{1,10,11,1,11,4,1,4,0,7,4,11,-1},
{3,1,4,3,4,8,1,10,4,7,4,11,10,11,4,-1},{4,11,7,9,11,4,9,2,11,9,1,2,-1},{9,7,4,9,11,7,9,1,11,2,11,1,0,8,3,-1},
{11,7,4,11,4,2,2,4,0,-1},{11,7,4,11,4,2,8,3,4,3,2,4,-1},{2,9,10,2,7,9,2,3,7,7,4,9,-1},
{9,10,7,9,7,4,10,2,7,8,7,0,2,0,7,-1},{3,7,10,3,10,2,7,4,10,1,10,0,4,0,10,-1},{1,10,2,8,7,4,-1},
{4,9,1,4,1,7,7,1,3,-1},{4,9,1,4,1,7,0,8,1,8,7,1,-1},{4,0,3,7,4,3,-1},{4,8,7,-1},{9,10,8,10,11,8,-1},
{3,0,9,3,9,11,11,9,10,-1},{0,1,10,0,10,8,8,10,11,-1},{3,1,10,11,3,10,-1},{1,2,11,1,11,9,9,11,8,-1},
{3,0,9,3,9,11,1,2,9,2,11,9,-1},{0,2,11,8,0,11,-1},{3,2,11,-1},{2,3,8,2,8,10,10,8,9,-1},{9,10,2,0,9,2,-1},
{2,3,8,2,8,10,0,1,8,1,10,8,-1},{1,10,2,-1},{1,3,8,9,1,8,-1},{0,9,1,-1},{0,3,8,-1},{-1},
}

-- Edge-crossing mask per cube case, DERIVED from triTable (union of all edges its triangles reference). Deriving it avoids
-- hand-transcribing a second 256-entry table that must stay perfectly in sync with triTable.
local edgeMask = {}
for ci = 0, 255 do
  local tri = triTable[ci]
  local m, ti = 0, 1
  while tri[ti] and tri[ti] ~= -1 do m = bor(m, lshift(1, tri[ti])); ti = ti + 1 end
  edgeMask[ci] = m
end

-- Cube corner offsets (Bourke numbering): corner c is at (base + (cx,cy,cz)*cell).
local cornerOff = {
  [0]={0,0,0},{1,0,0},{1,1,0},{0,1,0},{0,0,1},{1,0,1},{1,1,1},{0,1,1},
}
-- The two corners each of the 12 edges connects.
local edgeCorners = {
  [0]={0,1},{1,2},{2,3},{3,0},{4,5},{5,6},{6,7},{7,4},{0,4},{1,5},{2,6},{3,7},
}

-- ---------------------------------------------------------------------------------------------- per-run grid scratch
-- Filled by polygonize before the marching loop; read by the module-level helpers below (no closures). Single-threaded.
local gNx, gNy, gNz, gNxny = 0, 0, 0, 0
local gVal = {}
local gX0, gY0, gZ0, gCell = 0, 0, 0, 1 -- grid origin + spacing: corner (i,j,k) is at (gX0+i*gCell, ...). Lets edgeVertex derive
                                        -- positions on demand instead of storing ptx/pty/ptz for every corner (only crossings need them).
-- Structure-of-arrays vertex output: three parallel coordinate arrays instead of a {x,y,z} table per vertex (no per-vertex
-- allocation; the whole mesh pipeline downstream stays SoA). gNV is the running count so edgeVertex avoids a # on each append.
local gVX, gVY, gVZ = {}, {}, {}
local gNV = 0
local gEdgeCache = {}

-- Interpolated + cached vertex on the edge between grid corners (ai,aj,ak) and (bi,bj,bk). Returns its 1-based index.
local function edgeVertex(ai, aj, ak, bi, bj, bk)
  local ka = (ak * gNy + aj) * gNx + ai
  local kb = (bk * gNy + bj) * gNx + bi
  local lo, hi = ka, kb
  if lo > hi then lo, hi = hi, lo end
  local key = lo * (gNxny * gNz) + hi
  local hit = gEdgeCache[key]
  if hit then return hit end

  local ca = ka + 1
  local cb = kb + 1
  local va, vb = gVal[ca], gVal[cb]
  local t = 0.5
  local d = vb - va
  if d ~= 0 then t = -va / d end
  if t < 0 then t = 0 elseif t > 1 then t = 1 end

  local ax, ay, az = gX0 + ai * gCell, gY0 + aj * gCell, gZ0 + ak * gCell
  -- Position only. No normal: gradient shading normals here are dead (the mesh pipeline re-derives smooth normals post-weld).
  local vi = gNV + 1
  gNV = vi
  gVX[vi] = ax + t * ((gX0 + bi * gCell) - ax)
  gVY[vi] = ay + t * ((gY0 + bj * gCell) - ay)
  gVZ[vi] = az + t * ((gZ0 + bk * gCell) - az)
  gEdgeCache[key] = vi
  return vi
end

-- Extract the iso=0 surface of `sampleFn(sampleCtx, x, y, z)` (POSITIVE-INSIDE) over the AABB `bounds` at grid spacing `cell`.
-- Returns an SoA indexed mesh { vx,vy,vz (positions), ta,tb,tc (1-based tri corner indices), nv, nt }, or nil if empty.
--
-- store (optional): a pre-sampled shared value grid, so neighbouring chunks don't re-evaluate the field on their shared corner
-- planes (that seam re-sampling was ~1/6 of all field calls). When given, the corner values are COPIED from it instead of calling
-- sampleFn; the copy is bit-identical to sampling here (same world corners, deterministic field). Fields:
--   sval      -- flat value array, one column's z-strip after another
--   colBase   -- per global corner-column: the offset such that sval[colBase[col] + gk] is the value at global (col, gk)
--   colStride -- corner columns per grid row (= global NX + 1); col = gj*colStride + gi + 1 (1-based)
--   gi0,gj0,gk0 -- this chunk's global corner origin (its local corner (i,j,k) is global (gi0+i, gj0+j, gk0+k))
local function polygonize(bounds, cell, sampleFn, sampleCtx, store)
  local x0, y0, z0 = bounds.minx, bounds.miny, bounds.minz
  local nx = maxi(2, floor((bounds.maxx - x0) / cell) + 2)
  local ny = maxi(2, floor((bounds.maxy - y0) / cell) + 2)
  local nz = maxi(2, floor((bounds.maxz - z0) / cell) + 2)

  gNx, gNy, gNz, gNxny = nx, ny, nz, nx * ny
  gX0, gY0, gZ0, gCell = x0, y0, z0, cell
  -- Reuse the scratch buffers across chunks: table.clear keeps the array capacity, so the big val buffer + the edge cache aren't
  -- reallocated (and GC'd) for every one of the dozens of chunks per rebuild. The vertex arrays stay FRESH -- they're returned to
  -- the caller, which keeps them alive past the next polygonize call.
  table.clear(gVal)
  table.clear(gEdgeCache)
  gVX, gVY, gVZ = {}, {}, {}
  gNV = 0
  local val = gVal
  local nxny = gNxny

  -- Fill the corner values. COLUMN-MAJOR (k innermost): all samples of one (x,y) column run back to back, so (in the sampling
  -- branch) the sampler's per-column memo (field.lua caches the O(#footprint) project + terrainAt per x,y) hits on every z after
  -- the first. Index is computed explicitly so this fill order matches the (k*ny+j)*nx+i layout the cube loop reads. Only the
  -- field VALUE is stored per corner; corner positions are derived on demand in edgeVertex (from gX0/gCell), so the ~2M ptx/pty/ptz
  -- writes the old code did for every corner (when only the few thousand crossings need a position) are gone.
  if store then
    -- Shared store: copy this chunk's corners out of the pre-sampled grid (no field re-evaluation on the shared seam planes).
    local sval, colBase, cs = store.sval, store.colBase, store.colStride
    local gi0, gj0, gk0 = store.gi0, store.gj0, store.gk0
    for j = 0, ny - 1 do
      local rowCol = (gj0 + j) * cs + gi0 + 1 -- 1-based global corner column for local (0, j)
      for i = 0, nx - 1 do
        local base = colBase[rowCol + i] + gk0 -- sval[base + k] is the value at global (col, gk0 + k)
        local idx = (j * nx + i) + 1
        for k = 0, nz - 1 do
          val[idx] = sval[base + k]
          idx = idx + nxny
        end
      end
    end
  else
    for j = 0, ny - 1 do
      local wy = y0 + j * cell
      for i = 0, nx - 1 do
        local wx = x0 + i * cell
        local idx = (j * nx + i) + 1 -- column base; step by nxny per k (avoids the k*nxny multiply on every corner)
        for k = 0, nz - 1 do
          val[idx] = sampleFn(sampleCtx, wx, wy, z0 + k * cell)
          idx = idx + nxny
        end
      end
    end
  end

  local ta, tb, tc = {}, {}, {} -- SoA triangle corner indices (parallel arrays; no {a,b,c} table per tri)
  local nt = 0
  local cornerCache = {} -- 12 edge-vertex indices for the current cube (overwritten each cube before it is read).
  for k = 0, nz - 2 do
    for j = 0, ny - 2 do
      for i = 0, nx - 2 do
        -- Cube case index: bit c set when corner c is inside (air, F < 0).
        local base = (k * ny + j) * nx + i + 1
        local ci = 0
        if val[base] < 0 then ci = ci + 1 end
        if val[base + 1] < 0 then ci = ci + 2 end
        if val[base + 1 + nx] < 0 then ci = ci + 4 end
        if val[base + nx] < 0 then ci = ci + 8 end
        if val[base + nxny] < 0 then ci = ci + 16 end
        if val[base + 1 + nxny] < 0 then ci = ci + 32 end
        if val[base + 1 + nx + nxny] < 0 then ci = ci + 64 end
        if val[base + nx + nxny] < 0 then ci = ci + 128 end

        local edges = edgeMask[ci]
        if edges ~= 0 then
          for e = 0, 11 do
            if band(edges, lshift(1, e)) ~= 0 then
              local ec = edgeCorners[e]
              local a, b = cornerOff[ec[1]], cornerOff[ec[2]]
              cornerCache[e] = edgeVertex(i + a[1], j + a[2], k + a[3], i + b[1], j + b[2], k + b[3])
            end
          end
          local tri = triTable[ci]
          local ti = 1
          while tri[ti] and tri[ti] ~= -1 do
            local a = cornerCache[tri[ti]]
            local b = cornerCache[tri[ti + 1]]
            local c = cornerCache[tri[ti + 2]]
            if a and b and c and a ~= b and b ~= c and a ~= c then
              nt = nt + 1
              ta[nt] = a; tb[nt] = b; tc[nt] = c
            end
            ti = ti + 3
          end
        end
      end
    end
  end

  -- gVal / gEdgeCache are intentionally NOT released here: they're module-persistent scratch, cleared (not reallocated) at the top
  -- of the next call. The vertex arrays are handed to the caller as-is (fresh this call).
  if nt == 0 then return nil end

  return { vx = gVX, vy = gVY, vz = gVZ, ta = ta, tb = tb, tc = tc, nv = gNV, nt = nt }
end


-- Public interface.
M.polygonize = polygonize

return M