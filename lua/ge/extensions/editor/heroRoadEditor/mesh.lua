-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Drivable procedural-surface mesh for a Hero Road group. Builds one collision-enabled ProceduralMesh per group by
-- sweeping the profile cross-section (from profile.lua) along the 3D centreline (divPoints). The spline is the
-- divider/reference line, so the carriageway is offset -leftExt / +rightExt along the horizontal 'right' vector.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User variables.
local craterCellM = 0.14 -- Base sub-cell size (m) when locally subdividing a deck quad under a pothole (finer = smoother crater).
local craterMaxSub = 24 -- Hard cap on sub-divisions per quad axis, so a huge Refine-collapsed quad under a pothole can't explode.
local craterTargetSpan = 36 -- Target sub-cells across a crater's DIAMETER.
local craterDensifyCells = 8 -- Insert extra stations under a pothole so no deck quad there spans more than this many crater cells.
local craterRimK = 1.8 -- Radius (in noise space) of the circle the rim fBm is sampled on: sets the rim's lobe count (organic outline).
local craterRimOct = 3 -- fBm octaves for the rim outline (kept low: the rim is a smooth-ish lobed outline, not fine grain).
local craterMinFeatCells = 5.0 -- Finest roughness wavelength, in sub-cells: keeps surface detail >= this many triangles wide so it
                               -- reads as smooth eroded lumps instead of per-triangle facets (aliasing) at high noise.
local defaultCarriagewayMaterial = 'm_asphalt_new_01' -- Default asphalt material for the carriageway.
local defaultShoulderMaterial = 'm_asphalt_new_01' -- Default shoulder material (own selection later).
local defaultTexLenM = 4.0 -- Default texture tile length along the road (m per repeat).
local defaultTexWidthM = 4.0 -- Default texture tile width across the road (m per repeat).
local defaultChamferWidthM = 0.6 -- Perimeter chamfer flare-out width (m): a shallow asphalt valance overhanging the terrain seam to hide it.
local defaultChamferDropM = 0.1 -- Perimeter chamfer vertical drop (m) from the deck outer edge down to the rim (shallow = overhangs, hides seam).
local maxChamferAngleDeg = 70.0 -- Steepest chamfer tilt (deg); matches the Shape tab slider.
local endExtM = 1.0 -- Co-planar deck extension (m) past each end, so a full-length decal drape lands on the mesh (and for later terrain blending).

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local meshPart = require('editor/toolUtilities/meshPart')
local profile = require('editor/heroRoadEditor/profile')
local meshRefine = require('editor/heroRoadEditor/meshRefine')
local surfaceKit = require('editor/toolUtilities/surfaceKit')
local noise = require('editor/toolUtilities/noise')

-- Module constants.
local sqrt, sin, cos, floor, max, min = math.sqrt, math.sin, math.cos, math.floor, math.max, math.min
local abs, ceil, log, PI = math.abs, math.ceil, math.log, math.pi
local LOG2 = log(2)

-- Module state.---
local lodPreviewCache = {} -- Per-group cache (keyed by id) of the last LOD triangle-count preview


-- The scene-object name for a group's mesh (stable per group id, so a rebuild always replaces the previous one). The live
-- surface is chunked like the bake, so pass the chunk index n for 'HeroRoad_<id>_<n>'; nil gives the legacy unsuffixed name
-- (still deleted by removeMesh so older single-mesh builds are cleaned up).
local function meshName(group, n)
  local base = 'HeroRoad_' .. tostring(group.id)
  if n then return base .. '_' .. n end
  return base
end

-- Gather a[idx[1..#idx]] into a new compact array (subsamples a per-station array to the refined station set). Module
-- scope (not nested in build) so LuaJIT can compile it.
local function pickByIndex(a, idx)
  local n = #idx
  local o = table.new(n, 0)
  for i = 1, n do o[i] = a[idx[i]] end
  return o
end

-- Deletes the group's live ProceduralMesh(es): the legacy unsuffixed one AND every chunk 'HeroRoad_<id>_<n>' up to the first gap.
local function removeMesh(group)
  local obj = scenetree.findObject(meshName(group))
  if obj then obj:delete() end
  local n = 1
  while true do
    local o = scenetree.findObject(meshName(group, n))
    if not o then break end
    o:delete()
    n = n + 1
  end
  group.meshId = nil
  group.meshIds = nil
  group.triCount = 0
  group.triCountRaw = 0 -- Full-res triangle count (shown left of the refined count); cleared with the mesh.
  group.meshMaxEdgeM = nil -- Longest triangle edge (measured on the last full build); cleared with the mesh.
  group.meshEdgeL = nil -- Outer top edges (used by the ribbon wireframe + sidewalks); stale edges must not outlive the mesh.
  group.meshEdgeR = nil
  group.divBankR = nil -- Per-divPoint banked right axis (heatmap overlay); stale axes must not outlive the mesh.
  group.meshEdgeDirL = nil -- Outward banked lateral per side (sidewalk rails ride these); cleared with the mesh.
  group.meshEdgeDirR = nil
  group.meshEdgeUp = nil -- Per-station banked road normal (barrier/fence up); cleared with the mesh.
  group.meshGrid = nil -- Full world top-surface grid (used by terraform); stale grid must not outlive the mesh.
end

-- Places one station's local cross-section (pts: {o,dz}) into world using a proper orthonormal ROAD frame, then
-- banks it about the true tangent. Returns an array of world corner tables {x,y,z}, one per cross-section point.
--   T = tangent (travel), R = normalize(cross(T, worldUp)) (horizontal right), N = normalize(cross(R, T)) (road normal).
-- Banking rotates R,N about T (NOT about world-up), and crown (dz) is applied along N -- so an inclined, banked road
-- tilts correctly instead of shearing/twisting.
local function worldStation(centre, tangent, bank, pts)
  local tx, ty, tz = tangent.x, tangent.y, tangent.z
  local tl = sqrt(tx * tx + ty * ty + tz * tz)
  if tl > 1e-9 then tx, ty, tz = tx / tl, ty / tl, tz / tl end

  -- R = cross(T, worldUp(0,0,1)) = (ty, -tx, 0); horizontal.
  local rx, ry, rz = ty, -tx, 0.0
  local rl = sqrt(rx * rx + ry * ry)
  if rl > 1e-6 then rx, ry = rx / rl, ry / rl else rx, ry, rz = 1.0, 0.0, 0.0 end

  -- N = cross(R, T); road-surface normal (points up on a level road, tilts with grade).
  local nx = ry * tz - rz * ty
  local ny = rz * tx - rx * tz
  local nz = rx * ty - ry * tx
  local nl = sqrt(nx * nx + ny * ny + nz * nz)
  if nl > 1e-9 then nx, ny, nz = nx / nl, ny / nl, nz / nl else nx, ny, nz = 0.0, 0.0, 1.0 end

  local ce, se = cos(bank), sin(bank)
  -- Banked axes: R' = R*cos + N*sin, N' = N*cos - R*sin (rotation about T).
  local rpx, rpy, rpz = rx * ce + nx * se, ry * ce + ny * se, rz * ce + nz * se
  local npx, npy, npz = nx * ce - rx * se, ny * ce - ry * se, nz * ce - rz * se

  local out = {}
  for j = 1, #pts do
    local o, dz = pts[j].o, pts[j].dz
    out[j] = {
      x = centre.x + rpx * o + npx * dz,
      y = centre.y + rpy * o + npy * dz,
      z = centre.z + rpz * o + npz * dz,
    }
  end
  return out, npx, npy, npz, rpx, rpy, rpz -- also the banked road normal N' (smooth shading) and banked right R' (sidewalk lateral).
end

-- Co-planar tangent extension: step distance d along tangent t. Returns dx,dy,dz (0 when t is degenerate).
local function tanStep(t, d)
  local tl = sqrt(t.x * t.x + t.y * t.y + t.z * t.z)
  if tl < 1e-9 then return 0.0, 0.0, 0.0 end
  local s = d / tl
  return t.x * s, t.y * s, t.z * s
end

-- Horizontal unit dir, falling back to (fx,fy) when degenerate.
local function unitXY(dx, dy, fx, fy)
  local l = sqrt(dx * dx + dy * dy)
  if l > 1e-6 then return dx / l, dy / l end
  return fx, fy
end

-- Chamfer rim vertex: deck point p pushed horizontally outward by chamW (dir ox,oy) and down by chamDrop.
local function rimVert(p, ox, oy, chamW, chamDrop)
  return { x = p.x + ox * chamW, y = p.y + oy * chamW, z = p.z - chamDrop }
end

-- Start / end chamfer rim row, with mitred corners (the corner rim sums the side + end outward so the bevels meet cleanly).
local function endRow(Wj, cj, ohx, ohy, numCols, cols2, chamW, chamDrop)
  local olx, oly = unitXY(Wj[1].x - cj.x, Wj[1].y - cj.y, -1, 0)
  local orx, ory = unitXY(Wj[numCols].x - cj.x, Wj[numCols].y - cj.y, 1, 0)
  local row = table.new(cols2, 0)
  row[1] = rimVert(Wj[1], olx + ohx, oly + ohy, chamW, chamDrop)
  for c = 1, numCols do row[c + 1] = rimVert(Wj[c], ohx, ohy, chamW, chamDrop) end
  row[cols2] = rimVert(Wj[numCols], orx + ohx, ory + ohy, chamW, chamDrop)
  return row
end

-- TG row r -> deck station (row 1 = start cap ~ station 1, row m+2 = end cap ~ station m).
local function tgStation(r, m) return max(1, min(r - 1, m)) end

-- Chamfer edge normal: the shoulder's own slope (GN) beside a shoulder, else the smooth road normal (roadNT).
local function edgeN(sr, dcol, isSh, GN, roadNT) if isSh then return GN[sr][dcol] end return roadNT[sr] end

-- Material + UV tiling of deck band b (shoulder gravel beside a shoulder, carriageway otherwise). When mergeSh is set the
-- shoulder shares the carriageway submesh (its own tiling is kept) -- see mergeShoulder in build() for why.
local function bandPart(b, bandMat, shoulderPart, shU, shV, roadPart, cwU, cwV, mergeSh)
  if bandMat[b] == profile.MAT_SHOULDER then return (mergeSh and roadPart or shoulderPart), shU, shV end
  return roadPart, cwU, cwV
end

-- Emit one chamfer quad (flat facet ref up, planar-projected UVs).
local function chamQuad(part, su, sv, p1, p2, p3, p4, n1, n2, n3, n4)
  meshPart.face4n(part, p1, p2, p3, p4, 0, 0, 1,
    { p1.x * su, p1.y * sv }, { p2.x * su, p2.y * sv }, { p3.x * su, p3.y * sv }, { p4.x * su, p4.y * sv },
    n1, n2, n3, n4)
end

-- Unit vector, falling back to +Z when degenerate.
local function unitVec(x, y, z)
  local l = sqrt(x * x + y * y + z * z)
  if l > 1e-9 then return x / l, y / l, z / l end
  return 0.0, 0.0, 1.0
end

local function craterDepthAt(craters, s, t)
  local best = 0.0
  for i = 1, #craters do
    local c = craters[i]
    local ds, dt = s - c.sC, t - c.tC
    if ds * ds + dt * dt < c.Rmax * c.Rmax then
      -- Rotate into the crater frame, then normalize by the ellipse semi-axes (ea along the crater's long axis, eb across).
      local u = ds * c.eca + dt * c.esa
      local w = -ds * c.esa + dt * c.eca
      local ru, rw = u / c.ea, w / c.eb
      local rr = sqrt(ru * ru + rw * rw)
      if rr < 1.6 then
        -- Lobed rim is an ANGULAR modulation (constant along each ray).
        local rim = 1.0
        if rr > 1e-6 then
          local inv = 1.0 / rr
          local rimN = noise.fbm(ru * inv * craterRimK + c.ox, rw * inv * craterRimK + c.oy, craterRimOct, noise.defaultFbmLacunarity, noise.defaultFbmGain)
          rim = 1.0 + c.irr * 0.5 * rimN
        end
        if rim > 1e-3 then
          local r = rr / rim
          if r < 1.0 then
            local dd
            if r <= c.floor then
              dd = c.depth
            else
              local x = (r - c.floor) / (1.0 - c.floor)
              dd = c.depth * (1.0 - x * x * (3.0 - 2.0 * x))
            end
            if c.rough > 0.0 then
              local win = 1.0 - r * r -- Windowed fBm: strongest in the interior, 0 at the rim (r=1) so the crater still closes crack-free.
              dd = dd + c.depth * c.rough * win * noise.fbm(u * c.roughFreq + c.ox, w * c.roughFreq + c.oy, c.roughOct, noise.defaultFbmLacunarity, noise.defaultFbmGain)
            end
            if dd > best then best = dd end
          end
        end
      end
    end
  end
  return best
end

-- Does a deck quad's (s,t) bbox overlap any crater's footprint?
-- Cheap AABB gate so only the handful of quads under a pothole pay the subdivision cost.
local function quadHitsAnyCrater(craters, sLo, sHi, tLo, tHi)
  for i = 1, #craters do
    local c = craters[i]
    if c.sC + c.Rmax >= sLo and c.sC - c.Rmax <= sHi and c.tC + c.Rmax >= tLo and c.tC - c.Rmax <= tHi then
      return true
    end
  end
  return false
end

-- Emit one carriageway deck quad.
local function emitDeckQuad(part, P00, P10, P11, P01, uL, uR, vP, vA, n0x, n0y, n0z, n1x, n1y, n1z, craters, sPrev, sCur, tL, tR, flatShade)
  local sLo, sHi = sPrev, sCur; if sLo > sHi then sLo, sHi = sHi, sLo end
  local tLo, tHi = tL, tR; if tLo > tHi then tLo, tHi = tHi, tLo end
  if not craters or not quadHitsAnyCrater(craters, sLo, sHi, tLo, tHi) then
    -- Flat quad, no pothole here.
    if flatShade then
      meshPart.face4(part, P00, P10, P11, P01, 0, 0, 1, { uL, vP }, { uR, vP }, { uR, vA }, { uL, vA })
    else
      local snx, sny, snz = unitVec(n0x + n1x, n0y + n1y, n0z + n1z)
      meshPart.face4(part, P00, P10, P11, P01, 0, 0, 1, { uL, vP }, { uR, vP }, { uR, vA }, { uL, vA }, snx, sny, snz)
    end
    return
  end

  local cell = craters.cell or craterCellM -- radius-scaled cell (bounds the tri budget so a big crater can't explode).
  local ns = min(craterMaxSub, max(1, ceil(abs(sCur - sPrev) / cell)))
  local nt = min(craterMaxSub, max(1, ceil(abs(tR - tL) / cell)))
  -- Unit surface tangents (approx orthonormal with the base normal): +s along the left edge, +t along the bottom edge. The
  -- displaced normal tilts opposite the crater's (s,t) gradient (standard offset-surface / bump-map result).
  local tsx, tsy, tsz = unitVec(P01.x - P00.x, P01.y - P00.y, P01.z - P00.z)
  local ttx, tty, ttz = unitVec(P10.x - P00.x, P10.y - P00.y, P10.z - P00.z)
  local eps = 0.03

  local W1 = nt + 1
  local pos, uvv, nrm = {}, {}, {}
  for ia = 0, ns do
    local fa = ia / ns
    local s = sPrev + (sCur - sPrev) * fa
    local v = vP + (vA - vP) * fa
    -- Carve direction for this row: the two stations' normals blended by fa. At fa=0 it is exactly n0 and at fa=1 exactly
    -- n1, so the shared boundary row carves along the SAME direction as the neighbouring segment (no lateral rip).
    local bnx, bny, bnz = unitVec(n0x + (n1x - n0x) * fa, n0y + (n1y - n0y) * fa, n0z + (n1z - n0z) * fa)
    for ic = 0, nt do
      local fc = ic / nt
      local t = tL + (tR - tL) * fc
      -- Bilinear base point (the quad is near-planar) then push down the crater depth along this row's normal.
      local bx = (P00.x * (1 - fc) + P10.x * fc) * (1 - fa) + (P01.x * (1 - fc) + P11.x * fc) * fa
      local by = (P00.y * (1 - fc) + P10.y * fc) * (1 - fa) + (P01.y * (1 - fc) + P11.y * fc) * fa
      local bz = (P00.z * (1 - fc) + P10.z * fc) * (1 - fa) + (P01.z * (1 - fc) + P11.z * fc) * fa
      local d = craterDepthAt(craters, s, t)
      local idx = ia * W1 + ic + 1
      pos[idx] = { x = bx - bnx * d, y = by - bny * d, z = bz - bnz * d }
      uvv[idx] = { uL + (uR - uL) * fc, v }
      local gs = (craterDepthAt(craters, s + eps, t) - craterDepthAt(craters, s - eps, t)) / (2 * eps)
      local gt = (craterDepthAt(craters, s, t + eps) - craterDepthAt(craters, s, t - eps)) / (2 * eps)
      local nnx, nny, nnz = unitVec(bnx - tsx * gs - ttx * gt, bny - tsy * gs - tty * gt, bnz - tsz * gs - ttz * gt)
      nrm[idx] = { x = nnx, y = nny, z = nnz }
    end
  end
  for ia = 0, ns - 1 do
    for ic = 0, nt - 1 do
      local i00 = ia * W1 + ic + 1
      local i01 = i00 + 1
      local i10 = i00 + W1
      local i11 = i10 + 1
      meshPart.face4n(part, pos[i00], pos[i01], pos[i11], pos[i10], 0, 0, 1,
        uvv[i00], uvv[i01], uvv[i11], uvv[i10], nrm[i00], nrm[i01], nrm[i11], nrm[i10])
    end
  end
end

-- Precompute the per-crater descriptors (arc s, lateral t, effective radius, floor fraction, seed) for a group, in the (s,t)
-- surface frame the sweep uses. total = full arc length. nil when the group has no potholes.
local function buildCraters(group, total)
  local pot = group.potholes
  if not pot or #pot == 0 or not total or total <= 1e-6 then return nil end
  local craters = {}
  local maxRmax = 0
  for i = 1, #pot do
    local ph = pot[i]
    local seed = ph.seed or 1
    -- Footprint is an ellipse oriented to the ROAD: length runs ALONG the road (semi-axis ea), width ACROSS it (eb). Old saves
    -- that only stored a single radiusM fall back to a round crater of that radius.
    local baseR = max(0.05, ph.radiusM or 2.0)
    local ea = max(0.1, (ph.lengthM or baseR * 2) * 0.5)
    local eb = max(0.1, (ph.widthM or baseR * 2) * 0.5)
    local meanR = (ea + eb) * 0.5
    -- Single artist knob 'noise' drives the natural-variation params (rim raggedness + surface roughness). Capped at 0.25
    -- (anything above looks crazy); clamped here too so an older pothole saved at a higher value still renders sanely.
    local nz = min(max(ph.noise or 0.15, 0.0), 0.25)
    local irr = nz
    local rough = nz * 0.8
    -- Align the long axis to the road, with a small seed-driven jitter (up to ~±0.15 rad at max noise) so a row of potholes
    -- never looks rubber-stamped.
    local ang = (((seed * 0.6180339887) % 1.0) - 0.5) * nz * 1.2
    local Rmax = max(ea, eb) * (1.0 + irr * 0.6) * 1.05
    craters[i] = {
      sC = (ph.t or 0.5) * total,
      tC = ph.lateralM or 0.0,
      R = meanR,
      ea = ea, eb = eb, eca = cos(ang), esa = sin(ang),
      depth = max(0.0, ph.depthM or 0.1),
      floor = 0.53, -- fixed wall shape (~rimSharp 0.55): flat-ish floor, moderately steep wall.
      irr = irr,
      rough = rough,
      roughFreq = 1.0 / (meanR * 0.35), -- fixed roughness feature size (~0.35 of mean semi-axis): looks natural, never aliases the mesh.
      -- Per-crater domain offset into the shared simplex field: spreads seeds far apart so no two potholes sample the same bumps.
      ox = (seed % 977) * 0.911 + 11.3,
      oy = (floor(seed / 977) % 653) * 1.317 + 5.7,
      Rmax = Rmax,
    }
    if Rmax > maxRmax then maxRmax = Rmax end
  end
  -- Sub-cell scales with the biggest crater so tris stay ~constant per pothole (span^2, not radius^2): small craters keep the
  -- fine base cell; a big one coarsens just enough that the local subdivision can't balloon (and freeze the per-frame rebuild).
  craters.cell = max(craterCellM, (2 * maxRmax) / craterTargetSpan)
  -- Band-limit the surface roughness to the tessellation. minFeat is the finest wavelength the mesh can draw cleanly; because
  -- the local grid under a pothole is densified to ~craters.cell (see the densify pass in assemble), this limit is honest --
  -- the actual triangle size really is ~craters.cell, so a feature >= minFeat spans enough triangles to read as a smooth lump.
  local minFeat = craters.cell * craterMinFeatCells
  for i = 1, #craters do
    local c = craters[i]
    local baseWav = 1.0 / c.roughFreq
    if baseWav <= minFeat then
      -- Sub-resolvable roughness: clamp its wavelength to the floor AND fade its amplitude out (a bump only a few triangles
      -- wide can't be drawn smoothly, so drawing it at full height just makes jagged facets). Fully gone at half the floor.
      c.roughFreq = 1.0 / minFeat
      c.roughOct = 1
      c.rough = c.rough * clamp((baseWav / minFeat - 0.5) * 2.0, 0.0, 1.0)
    else
      c.roughOct = min(4, max(1, 1 + floor(log(baseWav / minFeat) / LOG2)))
    end
  end
  return craters
end

-- Assembles the drivable geometry into a list of material parts.
local function assemble(group, opts, jLo, jHi, isFirst, isLast, cutArcs)
  local div, tangents = group.divPoints, group.tangents
  local n = div and #div or 0
  if n < 2 then return nil end

  local tolM = opts and opts.tol
  local maxSegM = opts and opts.maxSeg
  local emitChamfer = not (opts and opts.emitChamfer == false)

  local stations, bandMat = profile.build(group)
  if not stations then return nil end
  local numBands = #bandMat
  local numCols = #stations[1].pts -- cross-section points per station (col 1 = outer left, numCols = outer right).

  local roadPart = meshPart.newPart()
  roadPart.material = group.carriagewayMaterial or defaultCarriagewayMaterial
  local shoulderPart = meshPart.newPart()
  shoulderPart.material = group.shoulderMaterial or defaultShoulderMaterial

  local mergeShoulder = (shoulderPart.material == roadPart.material)

  -- Groundmodel: world-space paint stamps routed onto carriageway quads (physics groundmodel per triangle, invisible visually).
  -- Build the spatial lookup once; a distinct painted surface gets its own material part (submesh) lazily, base zones stay on
  -- roadPart. surfParts is keyed by material name so all patches of one surface share ONE submesh (cost = #distinct materials).
  local surfGrid = surfaceKit.buildGrid(group.surfaceStamps)
  local surfMatName = surfaceKit.resolveMaterials(roadPart.material) -- surface index -> material (variant if it exists, else base).
  local surfParts, surfOrder = {}, {}
  local function surfacePart(mi)
    local matName = surfMatName[mi] or roadPart.material
    if matName == roadPart.material then return roadPart end
    local p = surfParts[matName]
    if not p then p = meshPart.newPart(); p.material = matName; surfParts[matName] = p; surfOrder[#surfOrder + 1] = p end
    return p
  end

  -- Ordered sweep stations. We add a co-planar tangent extension at BOTH ends (same cross-section as the end station),
  -- so a full-length decal drape lands entirely on the mesh -- and so the ends can later blend to terrain.
  local centres, tans, banks, ptsA = {}, {}, {}, {}
  local m = 0
  local bx, by, bz = tanStep(tangents[1], -endExtM) -- start cap, extended backward along the first tangent.
  m = m + 1; centres[m] = { x = div[1].x + bx, y = div[1].y + by, z = div[1].z + bz }; tans[m] = tangents[1]; banks[m] = stations[1].bank; ptsA[m] = stations[1].pts
  for i = 1, n do
    m = m + 1; centres[m] = div[i]; tans[m] = tangents[i]; banks[m] = stations[i].bank; ptsA[m] = stations[i].pts
  end
  local ex, ey, ez = tanStep(tangents[n], endExtM) -- end cap, extended forward along the last tangent.
  m = m + 1; centres[m] = { x = div[n].x + ex, y = div[n].y + ey, z = div[n].z + ez }; tans[m] = tangents[n]; banks[m] = stations[n].bank; ptsA[m] = stations[n].pts

  -- Precompute the world cross-section (+ smooth road normal + banked right R') at every sweep station.
  local W, Nx, Ny, Nz, Rx, Ry, Rz = {}, {}, {}, {}, {}, {}, {}
  for j = 1, m do
    W[j], Nx[j], Ny[j], Nz[j], Rx[j], Ry[j], Rz[j] = worldStation(centres[j], tans[j], banks[j], ptsA[j])
  end

  -- Stash the BANKED right axis (R') per divPoint for the design heatmap overlay: sweep station j maps to divPoint j-1 (j=1 is
  -- the start cap, j=m the end cap), so div i uses station i+1. Captured here -- BEFORE the refine decimation below drops
  -- stations -- so it stays 1:1 with divPoints (which the overlay's colour arrays are indexed by). The overlay offsets its
  -- edges along this tilted axis so a superelevated corner can't rise over the ribbon and hide it.
  local dBR = group.divBankR or {}; group.divBankR = dBR
  for i = 1, n do
    local j = i + 1
    local v = dBR[i]
    if v then v:set(Rx[j], Ry[j], Rz[j]) else dBR[i] = vec3(Rx[j], Ry[j], Rz[j]) end
  end
  for i = n + 1, #dBR do dBR[i] = nil end

  -- Full-res triangle count.
  local m0, cols0 = m, numCols
  group.triCountRaw = 2 * ((m0 - 1) * (cols0 - 1) + 2 * (m0 + 1) + 2 * (cols0 - 1))

  -- Refine pass (optional): crack-free LINE decimation.
  if tolM and tolM > 1e-5 then
    -- Lateral first (global): drop whole collinear columns within tolM.
    local keptC = meshRefine.decimateCols(ptsA, bandMat, tolM, m)
    if #keptC < numCols then
      local nc = #keptC
      for j = 1, m do
        local oldW, oldP = W[j], ptsA[j]
        local nW, nP = table.new(nc, 0), table.new(nc, 0)
        for c = 1, nc do local k = keptC[c]; nW[c], nP[c] = oldW[k], oldP[k] end
        W[j], ptsA[j] = nW, nP
      end
      local nb = table.new(nc - 1, 0)
      for b = 1, nc - 1 do nb[b] = bandMat[keptC[b]] end -- band material is uniform between kept columns (boundaries kept).
      bandMat, numCols, numBands = nb, nc, nc - 1
    end
    -- Longitudinal: multi-channel RDP over stations (uses the outer columns, which the lateral pass always keeps). Force-keep
    -- the stations either side of a groundmodel material change in ANY (kept) band -- not just at the crown, so paint on the
    -- sides only keeps its ends too -- so the (invisible but physical) grip boundary doesn't drift more than a station on a
    -- decimated LOD. Mirrors the lateral band-boundary keep in decimateCols.
    local surfKeep = nil
    if surfGrid then
      surfKeep = {}
      local prevRow, row = table.new(numBands, 0), table.new(numBands, 0)
      for j = 1, m do
        local Wj = W[j]
        for b = 1, numBands do
          local p, q = Wj[b], Wj[b + 1]
          local mi = surfaceKit.materialAt(surfGrid, group.surfaceStamps, (p.x + q.x) * 0.5, (p.y + q.y) * 0.5)
          if j > 1 and mi ~= prevRow[b] then surfKeep[j - 1] = true; surfKeep[j] = true end
          row[b] = mi
        end
        prevRow, row = row, prevRow
      end
    end
    local keptS = meshRefine.decimateStations(centres, W, numCols, tolM, m, maxSegM, surfKeep)
    if #keptS < m then
      centres, tans, banks, ptsA, W = pickByIndex(centres, keptS), pickByIndex(tans, keptS), pickByIndex(banks, keptS), pickByIndex(ptsA, keptS), pickByIndex(W, keptS)
      Nx, Ny, Nz = pickByIndex(Nx, keptS), pickByIndex(Ny, keptS), pickByIndex(Nz, keptS)
      Rx, Ry, Rz = pickByIndex(Rx, keptS), pickByIndex(Ry, keptS), pickByIndex(Rz, keptS)
      m = #keptS
    end
  end

  -- Arc length of the (decimated) stations. Potholes are placed in this frame, and the sweep's UV-v runs off it.
  local arc = table.new(m, 0); arc[1] = 0
  for j = 2, m do
    local dx, dy, dz = centres[j].x - centres[j - 1].x, centres[j].y - centres[j - 1].y, centres[j].z - centres[j - 1].z
    arc[j] = arc[j - 1] + sqrt(dx * dx + dy * dy + dz * dz)
  end
  local total = arc[m]

  -- Procedural potholes (LOD0 + collision only -- opts.potholes): descriptors in the (arc s, lateral t) surface frame the sweep
  -- uses below. Built BEFORE the station insertion so their footprints can drive the densification (soft inserts) below.
  local craters = (opts and opts.potholes) and buildCraters(group, total) or nil

  -- Station insertion list, sorted by arc: chunk cut rings (HARD -- real chunk boundaries, only when baking) plus a soft
  -- densification under each pothole. The Refine pass collapses the flat deck under a pothole to one long quad; emitDeckQuad
  -- then can't subdivide it finely enough (craterMaxSub cap) and the crater comes out as big facets. Splitting that quad into
  -- ~craterDensifyCells-cell pieces first lets the crater reach full resolution. Each entry is { a = arc, cut = bool }.
  local haveCuts = cutArcs and #cutArcs > 0
  local insArcs = nil
  if haveCuts or craters then
    insArcs = {}
    if haveCuts then for i = 1, #cutArcs do insArcs[#insArcs + 1] = { a = cutArcs[i], cut = true } end end
    if craters then
      local step = max(0.1, craters.cell * craterDensifyCells)
      for i = 1, #craters do
        local c = craters[i]
        local a, aHi = c.sC - c.Rmax, c.sC + c.Rmax
        while a < aHi do
          if a > 1e-3 and a < total - 1e-3 then insArcs[#insArcs + 1] = { a = a, cut = false } end
          a = a + step
        end
        if aHi > 1e-3 and aHi < total - 1e-3 then insArcs[#insArcs + 1] = { a = aHi, cut = false } end
      end
    end
    table.sort(insArcs, function(x, y) return x.a < y.a end)
    -- Merge near-duplicate inserts (a station right next to another just makes a sliver quad). A cut wins the shared slot so
    -- its exact arc -- shared across LODs for crack-free baked seams -- is preserved.
    local merged = {}
    local minGap = max(0.05, (craters and craters.cell or 0.2) * 0.5)
    for i = 1, #insArcs do
      local e = insArcs[i]
      local last = merged[#merged]
      if last and (e.a - last.a) < minGap then
        if e.cut and not last.cut then last.a = e.a; last.cut = true end
      else
        merged[#merged + 1] = e
      end
    end
    insArcs = merged
  end

  -- Insert the stations: interpolate a fresh cross-section at each arc. Cut entries also mark a chunk boundary.
  if insArcs and #insArcs > 0 then
    local nC, nT, nB, nP, nW = {}, {}, {}, {}, {}
    local nNx, nNy, nNz, nRx, nRy, nRz = {}, {}, {}, {}, {}, {}
    local isCut = {} -- new-grid index -> true when that station is a chunk boundary (a cut ring, or a station a cut coincides with).
    local o, ci = 0, 1
    local EPS = 1e-3
    for j = 1, m do
      -- Inserts at/behind this station's arc coincide with it (it's already a ring -- no insert). Mark cut ones' upcoming slot.
      while ci <= #insArcs and insArcs[ci].a <= arc[j] + EPS do
        if insArcs[ci].cut then isCut[o + 1] = true end
        ci = ci + 1
      end
      o = o + 1
      nC[o], nT[o], nB[o], nP[o], nW[o] = centres[j], tans[j], banks[j], ptsA[j], W[j]
      nNx[o], nNy[o], nNz[o] = Nx[j], Ny[j], Nz[j]
      nRx[o], nRy[o], nRz[o] = Rx[j], Ry[j], Rz[j]
      -- Inserts strictly inside (arc[j], arc[j+1]) each get a fresh interpolated station.
      if j < m then
        local segLo, segHi = arc[j], arc[j + 1]
        local segLen = segHi - segLo
        while segLen > 1e-6 and ci <= #insArcs and insArcs[ci].a < segHi - EPS do
          local t = (insArcs[ci].a - segLo) / segLen
          o = o + 1
          local ca, cb = centres[j], centres[j + 1]
          nC[o] = { x = ca.x + (cb.x - ca.x) * t, y = ca.y + (cb.y - ca.y) * t, z = ca.z + (cb.z - ca.z) * t }
          nT[o] = tans[j] -- interior tangent unused downstream (only the true end caps read tans); copy the neighbour.
          nB[o] = banks[j] -- bank already baked into W above; unused downstream after this.
          local Wa, Wb, Pa, Pb = W[j], W[j + 1], ptsA[j], ptsA[j + 1]
          local w, p = table.new(numCols, 0), table.new(numCols, 0)
          for c = 1, numCols do
            local a, b = Wa[c], Wb[c]
            w[c] = { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t }
            p[c] = { o = Pa[c].o + (Pb[c].o - Pa[c].o) * t }
          end
          nW[o], nP[o] = w, p
          local ax, ay, az = Nx[j] + (Nx[j + 1] - Nx[j]) * t, Ny[j] + (Ny[j + 1] - Ny[j]) * t, Nz[j] + (Nz[j + 1] - Nz[j]) * t
          local al = sqrt(ax * ax + ay * ay + az * az); if al > 1e-9 then ax, ay, az = ax / al, ay / al, az / al else ax, ay, az = 0, 0, 1 end
          nNx[o], nNy[o], nNz[o] = ax, ay, az
          local rx, ry, rz = Rx[j] + (Rx[j + 1] - Rx[j]) * t, Ry[j] + (Ry[j + 1] - Ry[j]) * t, Rz[j] + (Rz[j + 1] - Rz[j]) * t
          local rl = sqrt(rx * rx + ry * ry + rz * rz); if rl > 1e-9 then rx, ry, rz = rx / rl, ry / rl, rz / rl else rx, ry, rz = 1, 0, 0 end
          nRx[o], nRy[o], nRz[o] = rx, ry, rz
          if insArcs[ci].cut then isCut[o] = true end
          ci = ci + 1
        end
      end
    end
    centres, tans, banks, ptsA, W = nC, nT, nB, nP, nW
    Nx, Ny, Nz, Rx, Ry, Rz = nNx, nNy, nNz, nRx, nRy, nRz
    m = o
    -- Chunk boundaries: station 1, every marked cut station, then the final station (only meaningful when baking with cuts).
    if haveCuts then
      local cutIdx = { 1 }
      for k = 2, o do if isCut[k] then cutIdx[#cutIdx + 1] = k end end
      if cutIdx[#cutIdx] ~= o then cutIdx[#cutIdx + 1] = o end
      group.meshCutIdx = cutIdx
    end
  end

  -- Cumulative arc length (unscaled) per station -- feeds continuous UV-v AND lets the chunk baker slice on real stations so
  -- neighbouring chunks share a boundary ring and their textures stay continuous (v isn't reset per chunk).
  local vArc = table.new(m, 0)
  vArc[1] = 0
  for j = 2, m do
    local dx, dy, dz = centres[j].x - centres[j - 1].x, centres[j].y - centres[j - 1].y, centres[j].z - centres[j - 1].z
    vArc[j] = vArc[j - 1] + sqrt(dx * dx + dy * dy + dz * dz)
  end
  group.meshVArc, group.meshStationCount = vArc, m -- stashed so the chunk baker can pick boundaries without a second grid build.

  -- Fold each pothole's local subdivision into the 'Original' count so it stays >= the After-refine (LOD0) count.
  if craters then
    local extra = 0
    for i = 1, #craters do
      local c = craters[i]
      extra = extra + ceil(2 * PI * c.Rmax * c.Rmax / (craterCellM * craterCellM))
    end
    group.triCountRaw = group.triCountRaw + extra
  end

  -- Central-difference per-vertex top-surface normals over the grid.
  local GN = table.new(m, 0)
  for j = 1, m do
    local Wj, Wp, Wn = W[j], W[max(1, j - 1)], W[min(m, j + 1)]
    local gj = table.new(numCols, 0)
    for c = 1, numCols do
      local a, b = Wj[max(1, c - 1)], Wj[min(numCols, c + 1)]
      local q, r = Wp[c], Wn[c]
      local tux, tuy, tuz = b.x - a.x, b.y - a.y, b.z - a.z
      local tvx, tvy, tvz = r.x - q.x, r.y - q.y, r.z - q.z
      local nx = tvy * tuz - tvz * tuy
      local ny = tvz * tux - tvx * tuz
      local nz = tvx * tuy - tvy * tux
      if nz < 0 then nx, ny, nz = -nx, -ny, -nz end
      local nl = sqrt(nx * nx + ny * ny + nz * nz)
      if nl > 1e-9 then nx, ny, nz = nx / nl, ny / nl, nz / nl else nx, ny, nz = 0, 0, 1 end
      gj[c] = { x = nx, y = ny, z = nz }
    end
    GN[j] = gj
  end

  -- Stash the ACTUAL banked outer top edges (incl. the end-cap extensions) so terraform carves to the real mesh
  -- footprint -- banking + end extension included -- instead of a flat centreline ribbon (col 1 = outer left, numCols = outer right).
  local edgeL, edgeR = table.new(m, 0), table.new(m, 0)
  -- Outward banked lateral unit per side (R' is the +right axis of the banked frame): sidewalks build their rails from the
  -- real banked edge point + this direction, so kerb/slab sit ON the road edge and roll with the banking (never floating).
  local edgeDirL, edgeDirR = table.new(m, 0), table.new(m, 0)
  -- Per-station banked road normal (N', points up, tilts with grade + banking): the 'up' surface props (barriers/fences)
  -- lean along, so they roll with the road instead of standing plumb on a banked corner.
  local edgeUp = table.new(m, 0)
  for j = 1, m do
    local l, r = W[j][1], W[j][numCols]
    edgeL[j] = vec3(l.x, l.y, l.z)
    edgeR[j] = vec3(r.x, r.y, r.z)
    edgeDirL[j] = { x = -Rx[j], y = -Ry[j], z = -Rz[j] }
    edgeDirR[j] = { x = Rx[j], y = Ry[j], z = Rz[j] }
    edgeUp[j] = vec3(Nx[j], Ny[j], Nz[j])
  end
  group.meshEdgeL, group.meshEdgeR = edgeL, edgeR
  group.meshEdgeDirL, group.meshEdgeDirR = edgeDirL, edgeDirR
  group.meshEdgeUp = edgeUp

  -- Per-material UV tiling (world metres per texture repeat): u (across) uses TexWidth, v (along) uses TexLen. Without this
  -- the UVs were raw metres (1 tile / m), which stretches/over-tiles the asphalt. Carriageway and shoulder tile separately.
  local cwU = 1.0 / max(0.05, group.carriagewayTexWidth or defaultTexWidthM)
  local cwV = 1.0 / max(0.05, group.carriagewayTexLenM or defaultTexLenM)
  local shU = 1.0 / max(0.05, group.shoulderTexWidth or defaultTexWidthM)
  local shV = 1.0 / max(0.05, group.shoulderTexLenM or defaultTexLenM)

  -- Sweep the deck: one quad per band per segment. v (UV length) accumulates real 3D distance along the centreline;
  -- u is the lateral offset (m) of each cross-section point. Both are scaled by the per-material tiling above.
  jLo = jLo or 1; jHi = jHi or m
  if isFirst == nil then isFirst = true end
  if isLast == nil then isLast = true end
  local isFull = jLo == 1 and jHi == m
  for j = jLo + 1, jHi do
    local prevW, curW = W[j - 1], W[j]
    local prevPts = ptsA[j - 1]
    local vPrev, vAccum = vArc[j - 1], vArc[j] -- absolute arc lengths, so a chunk not starting at station 1 keeps continuous UV-v.

    for b = 1, numBands do
      local isShoulder = bandMat[b] == profile.MAT_SHOULDER
      local part, su, sv = bandPart(b, bandMat, shoulderPart, shU, shV, roadPart, cwU, cwV, mergeShoulder)
      if surfGrid then -- route painted deck quads (carriageway + shoulders) to their surface submesh (by XY centroid).
        local cx = (prevW[b].x + prevW[b + 1].x + curW[b].x + curW[b + 1].x) * 0.25
        local cy = (prevW[b].y + prevW[b + 1].y + curW[b].y + curW[b + 1].y) * 0.25
        local mi = surfaceKit.materialAt(surfGrid, group.surfaceStamps, cx, cy)
        if not surfaceKit.isBase(mi) then part = surfacePart(mi) end
      end
      local uL, uR = prevPts[b].o * su, prevPts[b + 1].o * su
      local vP, vA = vPrev * sv, vAccum * sv
      emitDeckQuad(part, prevW[b], prevW[b + 1], curW[b + 1], curW[b], uL, uR, vP, vA,
        Nx[j - 1], Ny[j - 1], Nz[j - 1], Nx[j], Ny[j], Nz[j],
        craters, vPrev, vAccum, prevPts[b].o, prevPts[b + 1].o, isShoulder)
    end
  end

  -- Perimeter chamfer (side and end skirts toggle independently). chamferAngleDeg tilts the facet without changing its length:
  -- 0 = a flat lip, up to maxChamferAngleDeg (steeper reads as a wall).
  local chamW = group.chamferWidthM or defaultChamferWidthM
  local chamDrop = group.chamferDropM or defaultChamferDropM
  if group.chamferAngleDeg then
    local len, a = sqrt(chamW * chamW + chamDrop * chamDrop), math.rad(min(max(group.chamferAngleDeg, 0.0), maxChamferAngleDeg))
    chamW, chamDrop = len * cos(a), len * sin(a)
  end
  local sideCham = group.sideChamfers ~= false
  local endCham = group.endChamfers ~= false
  if emitChamfer and (sideCham or endCham) then

    local bhx, bhy = unitXY(-tans[1].x, -tans[1].y, -1, 0) -- start cap outward = backward along the first tangent.
    local fhx, fhy = unitXY(tans[m].x, tans[m].y, 1, 0) -- end cap outward = forward along the last tangent.
    local cols2 = numCols + 2

    local TG = table.new(m + 2, 0)
    for j = 1, m do
      local Wj, cj = W[j], centres[j]
      local olx, oly = unitXY(Wj[1].x - cj.x, Wj[1].y - cj.y, -1, 0) -- outward-left (deck centre -> left edge).
      local orx, ory = unitXY(Wj[numCols].x - cj.x, Wj[numCols].y - cj.y, 1, 0) -- outward-right.
      local row = table.new(cols2, 0)
      row[1] = rimVert(Wj[1], olx, oly, chamW, chamDrop)
      for c = 1, numCols do row[c + 1] = Wj[c] end
      row[cols2] = rimVert(Wj[numCols], orx, ory, chamW, chamDrop)
      TG[j + 1] = row
    end
    -- Start / end rim rows, with mitred corners (endRow sums the side + end outward so the bevels meet cleanly).
    TG[1] = endRow(W[1], centres[1], bhx, bhy, numCols, cols2, chamW, chamDrop)
    TG[m + 2] = endRow(W[m], centres[m], fhx, fhy, numCols, cols2, chamW, chamDrop)

    -- Chamfer shading + material.
    local roadNT = table.new(m, 0)
    for j = 1, m do
      local nx, ny, nz = Nx[j], Ny[j], Nz[j]
      local nl = sqrt(nx * nx + ny * ny + nz * nz)
      if nl > 1e-9 then nx, ny, nz = nx / nl, ny / nl, nz / nl else nx, ny, nz = 0, 0, 1 end
      roadNT[j] = { x = nx, y = ny, z = nz }
    end

    -- Side chamfers hang off the outer bands (band 1 left, band numBands right).
    local lSh, rSh = bandMat[1] == profile.MAT_SHOULDER, bandMat[numBands] == profile.MAT_SHOULDER
    local lPart, lU, lV = bandPart(1, bandMat, shoulderPart, shU, shV, roadPart, cwU, cwV, mergeShoulder)
    local rPart, rU, rV = bandPart(numBands, bandMat, shoulderPart, shU, shV, roadPart, cwU, cwV, mergeShoulder)
    -- TG row r spans deck stations (r-1)->(r): rows 2..m+1 are the stations, row 1 the start-cap rim, row m+2 the end-cap rim.
    -- For a chunk we emit the side valance across its own stations, and only include the cap-rim corner bevel on the true road
    -- ends while the end chamfers are on (without them the bevel would hang past the bare end).
    if sideCham then
      local rStart = isFirst and (endCham and 1 or 2) or (jLo + 1)
      local rEnd = isLast and (endCham and (m + 1) or m) or jHi
      for r = rStart, rEnd do
        local sa, sb = tgStation(r, m), tgStation(r + 1, m)
        chamQuad(lPart, lU, lV, TG[r][1], TG[r + 1][1], TG[r + 1][2], TG[r][2],
          edgeN(sa, 1, lSh, GN, roadNT), edgeN(sb, 1, lSh, GN, roadNT), edgeN(sb, 1, lSh, GN, roadNT), edgeN(sa, 1, lSh, GN, roadNT))       -- left side.
        chamQuad(rPart, rU, rV, TG[r][cols2], TG[r][cols2 - 1], TG[r + 1][cols2 - 1], TG[r + 1][cols2],
          edgeN(sa, numCols, rSh, GN, roadNT), edgeN(sa, numCols, rSh, GN, roadNT), edgeN(sb, numCols, rSh, GN, roadNT), edgeN(sb, numCols, rSh, GN, roadNT)) -- right side.
      end
    end
    -- Front/back chamfers cross the full width, so each spanwise quad inherits the material + normal of the deck band (c-1) it
    -- sits under -- carriageway across the lanes, shoulder across the shoulders.
    if endCham then
      for c = 2, numCols do
        local b = c - 1
        local part, su, sv = bandPart(b, bandMat, shoulderPart, shU, shV, roadPart, cwU, cwV, mergeShoulder)
        local isSh = bandMat[b] == profile.MAT_SHOULDER
        if isFirst then
          chamQuad(part, su, sv, TG[1][c], TG[1][c + 1], TG[2][c + 1], TG[2][c],
            edgeN(1, c - 1, isSh, GN, roadNT), edgeN(1, c, isSh, GN, roadNT), edgeN(1, c, isSh, GN, roadNT), edgeN(1, c - 1, isSh, GN, roadNT))  -- start edge (true road start only).
        end
        if isLast then
          chamQuad(part, su, sv, TG[m + 2][c], TG[m + 1][c], TG[m + 1][c + 1], TG[m + 2][c + 1],
            edgeN(m, c - 1, isSh, GN, roadNT), edgeN(m, c - 1, isSh, GN, roadNT), edgeN(m, c, isSh, GN, roadNT), edgeN(m, c, isSh, GN, roadNT))  -- end edge (true road end only).
        end
      end
    end
  end

  -- Terraform footprint = the DECK TOP grid W (NOT the chamfer).
  group.meshGrid = W

  -- Collect the non-empty material parts (shoulder part is empty when shoulders are off; surface parts exist only where painted).
  local parts = {}
  if #roadPart.verts >= 3 then parts[#parts + 1] = roadPart end
  if #shoulderPart.verts >= 3 then parts[#parts + 1] = shoulderPart end
  for i = 1, #surfOrder do if #surfOrder[i].verts >= 3 then parts[#parts + 1] = surfOrder[i] end end
  if #parts == 0 then return nil end

  if isFull then
    local tf = 0; for pi = 1, #parts do tf = tf + #parts[pi].faces end
    group.triCount = floor(tf / 3) -- whole-road count across all material submeshes (a chunk holds a slice).
    -- Measure the longest triangle EDGE in the built geometry (real number, not an estimate) so the Refine max-segment cap can
    -- be verified at a glance. Longitudinal edges are bounded by each LOD's own Max tri length; the longest edge is usually a deck-quad
    -- diagonal (~sqrt(seg^2 + width^2)). Stored on the group + logged; the UI shows it beside the triangle count.
    local maxE2 = 0
    for pi = 1, #parts do
      local V, F = parts[pi].verts, parts[pi].faces
      for f = 1, #F, 3 do
        local a, b, c = V[F[f].v + 1], V[F[f + 1].v + 1], V[F[f + 2].v + 1]
        local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z; local e = dx * dx + dy * dy + dz * dz; if e > maxE2 then maxE2 = e end
        dx, dy, dz = c.x - b.x, c.y - b.y, c.z - b.z; e = dx * dx + dy * dy + dz * dz; if e > maxE2 then maxE2 = e end
        dx, dy, dz = a.x - c.x, a.y - c.y, a.z - c.z; e = dx * dx + dy * dy + dz * dz; if e > maxE2 then maxE2 = e end
      end
    end
    group.meshMaxEdgeM = sqrt(maxE2)
  end
  return parts
end

-- The arc positions (metres) of the chunk cut marks for a road of the given TOTAL arc length.
local function cutMarks(total, chunkLenM)
  chunkLenM = max(20, chunkLenM or 120)
  local cuts = {}
  if not total or total <= chunkLenM * 1.5 then return cuts end -- short enough for one chunk.
  local a = chunkLenM
  while a < total - chunkLenM * 0.5 do cuts[#cuts + 1] = a; a = a + chunkLenM end
  return cuts
end

-- How many DAE chunks a bake WILL produce for the given total arc length + chunk length (mirrors the chunk baker). The UI uses this
-- with the SAME arc length the bake uses (group.meshVArc[end], not the node polyline) so its preview is never off by one.
local function chunkCount(total, chunkLenM)
  local n = #cutMarks(total, chunkLenM)
  return n == 0 and 1 or (n + 1)
end

-- Assemble opts for one LOD from its own Quality (cm) + Max tri length (m). Quality 0 (or ~0) means NO decimation (full res).
local function lodOpts(qualityCm, maxSegM)
  local tol = (qualityCm or 0) * 0.01
  if tol <= 1e-5 then return { tol = nil, maxSeg = maxSegM } end
  return { tol = tol, maxSeg = maxSegM }
end

-- The LOD ladder for a group, in FIXED slot order: LOD0 (the near / live / drivable mesh, built at the Resolution 'Refine'),
-- then LOD1, LOD2. Each level has its OWN refine Quality + Max tri length + display size.
local function lodDefs(group)
  local levels = {
    { size = group.lodSize0 or 400, q = group.lodQualityCm0 or 1.0, ms = group.lodMaxSegM0 or 20 },
    { size = group.lodSize1 or 150, q = group.lodQualityCm1 or 3.0, ms = group.lodMaxSegM1 or 30 },
    { size = group.lodSize2 or 40,  q = group.lodQualityCm2 or 8.0, ms = group.lodMaxSegM2 or 45 },
  }
  -- The FAR slot (smallest size) is either a coarsest visible LOD or, when lodFarNull, a 'nulldetail' level: below its size the
  -- shape renders nothing (terrain + decals carry the look). In null mode that slot is NOT a visible mesh, so we build one fewer
  -- visible LOD and hand its size back as nullSize for the DAE. This is the standard BeamNG nulldetail LOD -- see daeExport.
  local farNull = group.lodFarNull ~= false
  local nullSize = farNull and levels[#levels].size or nil
  local visN = farNull and (#levels - 1) or #levels -- how many of the levels are visible mesh LODs.
  local defs = {}
  for i = 1, visN do
    defs[i] = { size = max(1, levels[i].size), opts = lodOpts(levels[i].q, levels[i].ms) }
  end
  -- The coarsest visible LOD drops the perimeter chamfer: that seam-hiding skirt is sub-pixel at the distance this level is
  -- shown (so it can't pop when switching in), and it's ~25-50% of the deck's triangles -- worth shedding on the far level
  -- that covers most of the scene. Nearer LODs (incl. LOD0 / the live mesh) keep it, where the terrain seam is visible.
  if #defs >= 2 then defs[#defs].opts.emitChamfer = false end
  -- Potholes are carved into LOD0 (the near / live / collision-source mesh) only: they're a close-up surface detail, and baking
  -- them into the coarse far LODs would defeat the decimation. LOD0's opts flag also drives the live build + the lodPreview count.
  defs[1].opts.potholes = true
  return defs, nullSize
end

-- Triangle count of a parts list (each part's .faces holds 3 index entries per triangle).
local function partsTriCount(parts)
  local t = 0
  for p = 1, #parts do t = t + #parts[p].faces end
  return floor(t / 3)
end

-- Build EVERY chunk for one assemble opts (one LOD tolerance, or the collision build) using the GIVEN cutArcs. Passing the
-- SAME cutArcs to all LODs is what keeps each level's chunk seams on shared rings (crack-free WITHIN a level); different
-- levels are never drawn together, so they need not align to each other. Returns a list of parts-lists (one per chunk).
local function assembleChunksWithCuts(group, opts, cutArcs)
  if #cutArcs == 0 then
    local p = assemble(group, opts)
    return p and { p } or nil
  end
  assemble(group, opts, nil, nil, nil, nil, cutArcs) -- augmented build once -> the cut station indices for THIS tolerance.
  local cutIdx = group.meshCutIdx
  if not cutIdx or #cutIdx < 3 then
    local p = assemble(group, opts)
    return p and { p } or nil
  end
  local out, nb = {}, #cutIdx
  for k = 1, nb - 1 do
    out[k] = assemble(group, opts, cutIdx[k], cutIdx[k + 1], k == 1, k == nb - 1, cutArcs) or {}
  end
  return out
end

-- Build the full baked payload for a group: for each ~chunkLenM chunk, its visible LOD set + one deck-only collision mesh.
-- cutArcs is computed ONCE from the full-res total arc length and shared by every LOD and the collision build, so all levels
-- have the same chunk count and each level's neighbours meet crack-free. Consecutive LODs with near-equal triangle counts are
-- dropped (a straight/flat that can't decimate further shouldn't ship a redundant level). Returns a list of chunks, each
-- { lods = { {size, parts}, ... }, col = { part, ... } }, or nil when there's nothing to build.
local function buildChunkLODs(group, chunkLenM)
  chunkLenM = max(20, chunkLenM or 120)
  local defs, nullSize = lodDefs(group)

  local probe = assemble(group, defs[1].opts) -- LOD0 (full) probe -> total arc length for the cut marks.
  if not probe then return nil end
  local total = group.meshVArc[group.meshStationCount] or 0
  local cutArcs = cutMarks(total, chunkLenM)

  local lodChunks = {}
  for li = 1, #defs do
    lodChunks[li] = assembleChunksWithCuts(group, defs[li].opts, cutArcs)
    if not lodChunks[li] then return nil end
  end
  -- Collision = the DETAIL deck surface (all bands, no chamfer) at a tiny tolerance: imperceptible to a tire but sheds the
  -- flat-straight triangles. It is the ONLY collision source (the TSStatic uses collisionType 'Collision Mesh'); the visible
  -- LODs contribute none.
  local colOpts = { tol = (group.collisionTolCm or 1.0) * 0.01, maxSeg = group.lodMaxSegM0 or 20, emitChamfer = false, potholes = true }
  local colChunks = assembleChunksWithCuts(group, colOpts, cutArcs)
  if not colChunks then return nil end

  local nCh, out = #lodChunks[1], {}
  for c = 1, nCh do
    local lods, prevTri = {}, nil
    for li = 1, #defs do
      local parts = lodChunks[li][c]
      if parts and #parts > 0 then
        local tris = partsTriCount(parts)
        if li == 1 or prevTri == nil or tris < prevTri * 0.98 then -- LOD0 always kept; others only if they save >2%.
          lods[#lods + 1] = { size = defs[li].size, parts = parts }
          prevTri = tris
        end
      end
    end
    if #lods > 0 then out[#out + 1] = { lods = lods, col = colChunks[c] or {} } end -- compact: never leave a nil hole.
  end
  if #out == 0 then return nil end
  return out, nullSize -- nullSize (px) -> the far 'nulldetail' level for every chunk, or nil when the far slot is a visible LOD.
end

-- Compute, for the Export panel, the whole-road triangle count of each visible LOD.
local function lodPreview(group)
  local defs, nullSize = lodDefs(group)
  -- Potholes change the LOD0 triangle count (local subdivision) but nothing above; fold them into the cache signature so the
  -- Export count refreshes on any pothole edit, cheaply.
  local pot = group.potholes
  local potN, potH = pot and #pot or 0, 0.0
  for i = 1, potN do
    local ph = pot[i]
    potH = potH + (ph.t or 0) * 131.0 + (ph.radiusM or 0) * 71.0 + (ph.depthM or 0) * 53.0 +
      (ph.lateralM or 0) * 17.0 + (ph.noise or 0) * 29.0 + (ph.lengthM or 0) * 43.0 +
      (ph.widthM or 0) * 37.0 + (ph.seed or 0) % 1000
  end
  local sig = string.format('%d|%d|%d|%.2f|%.2f|%.2f|%.1f|%.1f|%.1f|%d|%d|%d|%s|%s|%.1f|%.1f|%.1f|%d|%.2f',
    group.lodSize0 or 400, group.lodSize1 or 150, group.lodSize2 or 40,
    group.lodQualityCm0 or 1.0, group.lodQualityCm1 or 3.0, group.lodQualityCm2 or 8.0,
    group.lodMaxSegM0 or 20, group.lodMaxSegM1 or 30, group.lodMaxSegM2 or 45,
    group.latRes or 16, group.lonRes or 100, group.meshStationCount or 0,
    tostring(group.lodFarNull ~= false),
    group.geometryMode or 'spline', group.engRadiusM or 40.0, group.engTransM or 15.0, group.engVertLenM or 40.0,
    potN, potH)
  local cached = lodPreviewCache[group.id]
  if cached and cached.sig == sig then return cached.result end

  local s = { -- snapshot the fields assemble overwrites (all reassigned, not mutated in place, so refs restore cleanly).
    triCountRaw = group.triCountRaw, triCount = group.triCount, meshMaxEdgeM = group.meshMaxEdgeM,
    meshVArc = group.meshVArc, meshStationCount = group.meshStationCount,
    meshEdgeL = group.meshEdgeL, meshEdgeR = group.meshEdgeR, meshEdgeDirL = group.meshEdgeDirL,
    meshEdgeDirR = group.meshEdgeDirR, meshEdgeUp = group.meshEdgeUp, meshGrid = group.meshGrid,
  }
  local lodsRes, prevTri, maxEdge = {}, nil, 0
  for li = 1, #defs do
    local parts = assemble(group, defs[li].opts)
    local tris = parts and partsTriCount(parts) or 0
    if li == 1 then maxEdge = group.meshMaxEdgeM or 0 end
    local kept = (li == 1) or (prevTri == nil) or (tris < prevTri * 0.98)
    if kept then prevTri = tris end
    lodsRes[li] = { size = defs[li].size, tris = tris, kept = kept }
  end
  local result = { lods = lodsRes, nullSize = nullSize } -- nullSize (px) set when the far slot vanishes instead of drawing a mesh.
  group.triCountRaw, group.triCount, group.meshMaxEdgeM = s.triCountRaw, s.triCount, s.meshMaxEdgeM
  group.meshVArc, group.meshStationCount = s.meshVArc, s.meshStationCount
  group.meshEdgeL, group.meshEdgeR, group.meshEdgeDirL, group.meshEdgeDirR, group.meshEdgeUp =
    s.meshEdgeL, s.meshEdgeR, s.meshEdgeDirL, s.meshEdgeDirR, s.meshEdgeUp
  group.meshGrid = s.meshGrid
  group.lodMaxEdgeM = maxEdge

  lodPreviewCache[group.id] = { sig = sig, result = result }
  return result
end

-- (Re)builds the LIVE drivable ProceduralMesh for the group (the normal editor path): assembles the geometry at LOD0's OWN
-- refine setting (defs[1].opts -- the near level's Quality + Max tri length), then creates one collision-enabled scene mesh
-- from the material parts. The live/editable surface IS LOD0: you drive and test exactly what the bake writes as the near LOD
-- (collision is built from this same mesh), and the derived fields (edges, grid, vArc, ...) sidewalks/terraform read come off
-- it too, so the whole near assembly is consistent. Coarser LODs are only produced at bake time (see buildChunkLODs).
local function build(group)
  removeMesh(group)
  local folder = group.sceneTreeFolderId and scenetree.findObjectById(group.sceneTreeFolderId)
  if not folder then return end
  local lod0 = lodDefs(group)[1].opts -- LOD0 refine bag (the near level); the live mesh is built at exactly this tolerance.
  local full = assemble(group, lod0) -- LOD0 road: also sets the derived fields (edges, grid, vArc, ...) sidewalks/terraform read.
  if not full then return end

  -- Chunk the live surface the SAME way the bake does (shared cut arcs, same chunkLenM). createMesh's engine collision build
  -- is super-linear in vert count, so one huge mesh spikes/freezes a long road; bounding each chunk keeps it flat. Only kicks
  -- in past chunkLenM -- a short road yields one mesh, exactly as before -- and the live seams line up with the baked seams.
  local total = group.meshVArc and group.meshStationCount and group.meshVArc[group.meshStationCount] or 0
  local cutArcs = cutMarks(total, max(20, group.chunkLenM or 120))

  local chunks
  if #cutArcs == 0 then
    chunks = { full }
  else
    -- The chunked re-assembles below clobber the derived fields the full assemble just set; snapshot + restore them (all are
    -- reassigned wholesale, not mutated in place, so restoring the refs is clean -- same contract lodPreview relies on).
    local s = {
      triCountRaw = group.triCountRaw, triCount = group.triCount, meshMaxEdgeM = group.meshMaxEdgeM,
      meshVArc = group.meshVArc, meshStationCount = group.meshStationCount,
      meshEdgeL = group.meshEdgeL, meshEdgeR = group.meshEdgeR, meshEdgeDirL = group.meshEdgeDirL,
      meshEdgeDirR = group.meshEdgeDirR, meshEdgeUp = group.meshEdgeUp, meshGrid = group.meshGrid,
    }
    chunks = assembleChunksWithCuts(group, lod0, cutArcs) or { full }
    group.triCountRaw, group.triCount, group.meshMaxEdgeM = s.triCountRaw, s.triCount, s.meshMaxEdgeM
    group.meshVArc, group.meshStationCount = s.meshVArc, s.meshStationCount
    group.meshEdgeL, group.meshEdgeR, group.meshEdgeDirL, group.meshEdgeDirR, group.meshEdgeUp =
      s.meshEdgeL, s.meshEdgeR, s.meshEdgeDirL, s.meshEdgeDirR, s.meshEdgeUp
    group.meshGrid = s.meshGrid
  end

  group.meshIds = {}
  for c = 1, #chunks do
    local parts = chunks[c]
    if parts and #parts > 0 then
      local m = createObject('ProceduralMesh')
      m:registerObject(meshName(group, c))
      m.canSave = false -- Rebuilt from the spline on load; never persisted directly (this is the transient Edit surface).
      folder:addObject(m.obj)
      m:createMesh({ parts }) -- Triggers the engine collision build for THIS chunk only (bounded, so a long road can't spike).
      group.meshIds[c] = m:getId()
    end
  end
  group.meshId = group.meshIds[1] -- Legacy single-id readers (e.g. groupMgr's hadMesh check) just need any one handle.
end

-- LIGHT rebuild of just the outer top edges (meshEdgeL/R) used WHILE dragging, when the full grid/collision/decals are torn
-- down for perf. It reuses the SAME machinery the drivable mesh does -- profile.build (widening + fold caps + banking) and
-- worldStation -- on ONLY the two outermost cross-section points, plus the identical co-planar end-cap extension. So the ribbon
-- traces exactly the edge the released mesh will (single source of truth, no flat-vs-banked width mismatch). The full build
-- overwrites these with the decimated/cut version on release -- same curve, just fewer points.
local function buildRibbonEdges(group)
  local div, tangents = group.divPoints, group.tangents
  local n = div and #div or 0
  if n < 2 or not tangents then group.meshEdgeL, group.meshEdgeR = nil, nil; return end
  local stations = profile.build(group)
  if not stations then group.meshEdgeL, group.meshEdgeR = nil, nil; return end

  -- Same sweep-station list the mesh uses: a co-planar tangent extension at each end (end cap = the end station's section + bank).
  local bx, by, bz = tanStep(tangents[1], -endExtM)
  local cap0 = { x = div[1].x + bx, y = div[1].y + by, z = div[1].z + bz }
  local ex, ey, ez = tanStep(tangents[n], endExtM)
  local capN = { x = div[n].x + ex, y = div[n].y + ey, z = div[n].z + ez }
  local m = n + 2
  local eL, eR = table.new(m, 0), table.new(m, 0)
  local dBR = group.divBankR or {}; group.divBankR = dBR -- banked right axis per divPoint, for the heatmap overlay (see build()).
  local pair = {} -- reused 2-point section (outer-left, outer-right) fed to worldStation for the banked edge positions.
  for w = 1, m do
    local si = max(1, min(n, w - 1)) -- w=1 -> start cap @ station 1, w=m -> end cap @ station n, else div station w-1.
    local centre = (w == 1 and cap0) or (w == m and capN) or div[si]
    local pts = stations[si].pts
    pair[1], pair[2] = pts[1], pts[#pts]
    local out, _, _, _, rx, ry, rz = worldStation(centre, tangents[si], stations[si].bank, pair)
    eL[w] = vec3(out[1].x, out[1].y, out[1].z)
    eR[w] = vec3(out[2].x, out[2].y, out[2].z)
    if w >= 2 and w <= n + 1 then -- interior stations map to div i = w-1 (skip the two caps).
      local i = w - 1
      local v = dBR[i]
      if v then v:set(rx, ry, rz) else dBR[i] = vec3(rx, ry, rz) end
    end
  end
  for i = n + 1, #dBR do dBR[i] = nil end
  group.meshEdgeL, group.meshEdgeR = eL, eR
end

-- FLAT, world-up carriageway edge frames for a TERRAIN-mode road.
local function buildTerrainEdges(group)
  local div, binormals = group.divPoints, group.binormals
  local n = div and #div or 0
  if n < 2 or not binormals then
    group.meshEdgeL, group.meshEdgeR, group.meshEdgeDirL, group.meshEdgeDirR, group.meshEdgeUp = nil, nil, nil, nil, nil
    return
  end
  local lExt = group.leftExtM or defaultTexWidthM -- carriageway half-widths (lanes x width, split per side); no shoulders in terrain mode.
  local rExt = group.rightExtM or defaultTexWidthM
  local eL, eR = table.new(n, 0), table.new(n, 0)
  local dL, dR, up = table.new(n, 0), table.new(n, 0), table.new(n, 0)
  for i = 1, n do
    local b = binormals[i]
    local bx, by = b.x, b.y -- flatten the lateral to horizontal so kerbs/poles sit plumb regardless of grade.
    local bl = sqrt(bx * bx + by * by)
    if bl > 1e-9 then bx, by = bx / bl, by / bl else bx, by = 1, 0 end
    local p = div[i]
    eL[i] = vec3(p.x - bx * lExt, p.y - by * lExt, p.z) -- carriageway is offset -leftExt / +rightExt along the right (binormal), same as the deck.
    eR[i] = vec3(p.x + bx * rExt, p.y + by * rExt, p.z)
    dL[i] = vec3(-bx, -by, 0) -- outward-left / outward-right unit (barrierMgr applies edge + dir*offset).
    dR[i] = vec3(bx, by, 0)
    up[i] = vec3(0, 0, 1)
  end
  group.meshEdgeL, group.meshEdgeR = eL, eR
  group.meshEdgeDirL, group.meshEdgeDirR = dL, dR
  group.meshEdgeUp = up
  group.meshGrid = nil -- no deck grid in terrain mode (terraform sources come from these edges instead).
end

-- LOD0 (near-level) rebuild -- runs from the dirty pipeline on any edit.
local function updateMesh(group)
  build(group)
end


-- Public interface.
M.updateMesh = updateMesh
M.removeMesh = removeMesh
M.buildRibbonEdges = buildRibbonEdges
M.buildTerrainEdges = buildTerrainEdges
M.buildExportParts = assemble
M.buildChunkLODs = buildChunkLODs
M.lodPreview = lodPreview
M.chunkCount = chunkCount

return M