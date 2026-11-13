-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- A kerbed footway swept along two rails, as one unique mesh.

local M = {}

-- Module dependencies.
local meshPart = require('editor/toolUtilities/meshPart')
local kerbSpec = require('editor/toolUtilities/kerbSpec')

-- Module constants.
local abs, sqrt, min, max, ceil, huge = math.abs, math.sqrt, math.min, math.max, math.ceil, math.huge
local face4 = meshPart.face4
local face4n = meshPart.face4n
-- A dropped kerb: how far along the walk it takes to come down to flush, and how long the flush part is where the crossing
-- itself says nothing. Long enough that the roll eases in and out instead of snapping.
local crossingRampM = 1.5
local crossingDepthM = 3.5
local crossingSampleM = 0.4 -- how finely the rail is resampled inside a crossing band, so the flush part has stations to sit on

-- Module state. Reused per station, so a whole run allocates nothing but its arc-length table.
local pA, pB, pC, pD = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }
local stA, stB = {}, {}
-- Shading normals: the kerb's outward face at each station, the arris the two share, and the tread's own up.
local nFaceA, nFaceB = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }
local nArrisA, nArrisB = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }
local nUp = { x = 0, y = 0, z = 1 }


-- The kerb's two shading normals at one station.
local function kerbNormals(st, face, arris)
  local h = sqrt(st.ax * st.ax + st.ay * st.ay)
  if h < 1e-9 then
    face.x, face.y, face.z = 0, 0, -1
    arris.x, arris.y, arris.z = 0, 0, 1
    return
  end
  local fx, fy = -st.ax / h, -st.ay / h
  face.x, face.y, face.z = fx, fy, 0
  local l = sqrt(2)
  arris.x, arris.y, arris.z = fx / l, fy / l, 1 / l
end


-- The part in `parts` wearing `mat`, added on first use. Two walks in the same stone share one part -- both sides of the same
-- road, every tier of the same bridge -- so one stone is one draw however many walks went into it.
local function partFor(parts, mat)
  for i = 1, #parts do
    if parts[i].material == mat then return parts[i] end
  end
  local p = meshPart.newPart()
  p.material = mat
  parts[#parts + 1] = p
  return p
end

-- One station's frame: the way across from the kerb to the back of the walk, how far that is, and how high the kerb stands
-- here -- which a dropped kerb takes down to nothing.
local function station(inner, outer, h, out)
  local dx, dy, dz = outer.x - inner.x, outer.y - inner.y, outer.z - inner.z
  local l = sqrt(dx * dx + dy * dy + dz * dz)
  if l < 1e-6 then return false end
  out.ax, out.ay, out.az = dx / l, dy / l, dz / l
  out.w, out.h = l, h
  return true
end

-- Sweep the walk between two matching rails of { x, y, z }: the kerb line on the road and the back of the paving.
-- opts: parts, paving, variant, caps (default true), scale (per-station kerb height, 0 is dropped), uvs (paving flags to
-- the metre), worldUv (lay the paving from world x,y), uRail (line the along-run UVs are measured on), bury, back.
local function build(inner, outer, opts)
  local n = min(inner and #inner or 0, outer and #outer or 0)
  if n < 2 or not (opts and opts.parts) then return 0 end
  local sp = kerbSpec.spec
  local vStart, vTop, vFaceEnd = kerbSpec.kerbRows(opts.variant)
  local kerbPart = partFor(opts.parts, sp.kerbMaterial)
  local slabPart = partFor(opts.parts, opts.paving or sp.slabMaterial)
  local scale, kerbW, bury = opts.scale, sp.kerbW, opts.bury or sp.buryM
  local pvUv, worldUv = opts.uvs or 1, opts.worldUv

  -- Along-run UVs are metres of walk, so joints come out the size they were authored. Measured on `uRail` where given: a
  -- course swept on its own offset is longer than the one below, so measuring each on itself unstacks their joints.
  local uSrc = opts.uRail
  if not (uSrc and #uSrc >= n) then uSrc = inner end
  local u = { 0 }
  for i = 2, n do
    local p, q = uSrc[i - 1], uSrc[i]
    local dz = (q.z or 0) - (p.z or 0) -- a rail handed over as a plan line carries no z, and measures flat
    u[i] = u[i - 1] + sqrt((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2 + dz * dz)
  end

  local function kerbH(i) return sp.kerbH * ((scale and scale[i]) or 1) end

  -- Which row of the sheet's face band the foot of a face of height `h` lands on. The band is spread at ONE fixed rate --
  -- the whole of it across the section this module is specified in, kerb plus bury -- rather than across whatever each
  -- caller happens to stand and bury.
  local vSpan = (vFaceEnd - vTop) / (sp.kerbH + sp.buryM)
  local function faceV(h)
    return vTop + vSpan * (h + bury)
  end

  local tris = 0
  for i = 1, n - 1 do
    local i0, i1, o0, o1 = inner[i], inner[i + 1], outer[i], outer[i + 1]
    if station(i0, o0, kerbH(i), stA) and station(i1, o1, kerbH(i + 1), stB) then
      -- UVs in the segment's own frame: its start distance plus each point's projection along it. Given a station's
      -- distance instead, the stone shears round a corner.
      local u0 = u[i]
      local sx, sy = i1.x - i0.x, i1.y - i0.y
      local sl = sqrt(sx * sx + sy * sy)
      local dx, dy = (sl > 1e-9) and sx / sl or 0, (sl > 1e-9) and sy / sl or 0
      local u1 = u0 + sl
      -- At a mitre the way across is the bisector, so a point out along it also stands further along the segment.
      local skA, skB = stA.ax * dx + stA.ay * dy, stB.ax * dx + stB.ay * dy
      local kuA, kuB = u0 + kerbW * skA, u1 + kerbW * skB
      local wuA, wuB = u0 + stA.w * skA, u1 + stB.w * skB
      kerbNormals(stA, nFaceA, nArrisA)
      kerbNormals(stB, nFaceB, nArrisB)
      -- Kerb face: the arris down past the road to the buried foot, in the sheet's own face rows. Seen from across the road,
      -- which is the way the inner rail was handed over.
      pA.x, pA.y, pA.z = i0.x, i0.y, i0.z + stA.h
      pB.x, pB.y, pB.z = i1.x, i1.y, i1.z + stB.h
      pC.x, pC.y, pC.z = i1.x, i1.y, i1.z - bury
      pD.x, pD.y, pD.z = i0.x, i0.y, i0.z - bury
      face4n(kerbPart, pA, pB, pC, pD, -stA.ax, -stA.ay, 0,
             { u0, vTop }, { u1, vTop }, { u1, faceV(stB.h) }, { u0, faceV(stA.h) },
             nArrisA, nArrisB, nFaceB, nFaceA)
      -- Kerb tread: the first stone's width of the walking surface. Shares the face's normal along the arris, or the
      -- bullnose baked on the sheet cannot read across it.
      pC.x, pC.y, pC.z = i1.x + stB.ax * kerbW, i1.y + stB.ay * kerbW, i1.z + stB.h + stB.az * kerbW
      pD.x, pD.y, pD.z = i0.x + stA.ax * kerbW, i0.y + stA.ay * kerbW, i0.z + stA.h + stA.az * kerbW
      face4n(kerbPart, pA, pB, pC, pD, 0, 0, 1,
             { u0, vTop }, { u1, vTop }, { kuB, vStart }, { kuA, vStart },
             nArrisA, nArrisB, nUp, nUp)
      -- The paving, out to the back of the walk. `worldUv` lays it from world x,y so stacked runs come out of one field
      -- of stone rather than each repeating the same slice.
      pA.x, pA.y, pA.z = pD.x, pD.y, pD.z
      pB.x, pB.y, pB.z = pC.x, pC.y, pC.z
      pC.x, pC.y, pC.z = o1.x, o1.y, o1.z + stB.h
      pD.x, pD.y, pD.z = o0.x, o0.y, o0.z + stA.h
      if worldUv then
        face4(slabPart, pA, pB, pC, pD, 0, 0, 1,
              { pA.x * pvUv, pA.y * pvUv }, { pB.x * pvUv, pB.y * pvUv },
              { pC.x * pvUv, pC.y * pvUv }, { pD.x * pvUv, pD.y * pvUv })
      else
        face4(slabPart, pA, pB, pC, pD, 0, 0, 1,
              { kuA * pvUv, kerbW * pvUv }, { kuB * pvUv, kerbW * pvUv },
              { wuB * pvUv, stB.w * pvUv }, { wuA * pvUv, stA.w * pvUv })
      end
      tris = tris + 6
      -- And its own edge carried down at the back, where nothing else closes it.
      if opts.back ~= false then
        pA.x, pA.y, pA.z = pD.x, pD.y, pD.z
        pB.x, pB.y, pB.z = pC.x, pC.y, pC.z
        pC.x, pC.y, pC.z = o1.x, o1.y, o1.z - bury
        pD.x, pD.y, pD.z = o0.x, o0.y, o0.z - bury
        face4(slabPart, pA, pB, pC, pD, stA.ax, stA.ay, 0,
              { wuA, 0 }, { wuB, 0 }, { wuB, stB.h + bury }, { wuA, stA.h + bury })
        tris = tris + 2
      end
    end
  end

  -- The two ends, each closed with one face across the whole section: the only two a walk ever shows.
  if opts.caps ~= false then
    for k = 1, 2 do
      local e, q = 1, 2
      if k == 2 then e, q = n, n - 1 end
      local i0, o0 = inner[e], outer[e]
      local ex, ey = i0.x - inner[q].x, i0.y - inner[q].y
      local el = sqrt(ex * ex + ey * ey)
      if el > 1e-6 and station(i0, o0, kerbH(e), stA) then
        pA.x, pA.y, pA.z = i0.x, i0.y, i0.z + stA.h
        pB.x, pB.y, pB.z = o0.x, o0.y, o0.z + stA.h
        pC.x, pC.y, pC.z = o0.x, o0.y, o0.z - bury
        pD.x, pD.y, pD.z = i0.x, i0.y, i0.z - bury
        face4(slabPart, pA, pB, pC, pD, ex / el, ey / el, 0,
              { 0, 0 }, { stA.w, 0 }, { stA.w, stA.h + bury }, { 0, stA.h + bury })
        tris = tris + 2
      end
    end
  end
  return tris
end

-- The per-station kerb-height multiplier for a walk crossed by pedestrian crossings: flush over each crossing, ramped
-- either side. `cum`, `centres` and `depths` are all arc lengths on the rail the walk is swept along. nil where none reach.
local function dropScale(cum, centres, depths)
  local n = cum and #cum or 0
  if n < 2 or not centres or #centres == 0 then return nil end
  local scale
  for c = 1, #centres do
    local halfFlat = (depths and depths[c] or crossingDepthM) * 0.5
    local need = halfFlat + crossingRampM
    if not scale then
      scale = {}
      for i = 1, n do scale[i] = 1 end
    end
    for i = 1, n do
      local d = abs(cum[i] - centres[c])
      local s
      if d <= halfFlat then s = 0
      elseif d >= need then s = 1
      else s = (d - halfFlat) / crossingRampM end
      if s < scale[i] then scale[i] = s end
    end
  end
  return scale
end

-- World XY on the centreline at normalized 2D-arc position t01 (matches the road tools' crossingFrame t -> point mapping, so
-- the dip lands exactly under the zebra decal). Returns px, py.
local function centrelinePointAtT(div, t01)
  local total = 0
  for i = 2, #div do total = total + sqrt((div[i].x - div[i - 1].x) ^ 2 + (div[i].y - div[i - 1].y) ^ 2) end
  if total <= 1e-6 then return div[1].x, div[1].y end
  local target = min(max(t01, 0), 1) * total
  local acc = 0
  for i = 1, #div - 1 do
    local a, b = div[i], div[i + 1]
    local segLen = sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    if acc + segLen >= target or i == #div - 1 then
      local tt = segLen > 1e-9 and min(max((target - acc) / segLen, 0), 1) or 0
      return a.x + (b.x - a.x) * tt, a.y + (b.y - a.y) * tt
    end
    acc = acc + segLen
  end
  return div[#div].x, div[#div].y
end

-- Arc position on the rail (station midpoints mx,my with cumulative arc cum) of the point nearest to (px,py).
local function nearestRailArc(mx, my, cum, n, px, py)
  local bestSq, bestArc = huge, 0
  for i = 1, n - 1 do
    local ax, ay = mx[i], my[i]
    local ex, ey = mx[i + 1] - ax, my[i + 1] - ay
    local lenSq = ex * ex + ey * ey
    local tt = 0
    if lenSq > 1e-10 then tt = min(max(((px - ax) * ex + (py - ay) * ey) / lenSq, 0), 1) end
    local qx, qy = ax + ex * tt, ay + ey * tt
    local d = (px - qx) ^ 2 + (py - qy) ^ 2
    if d < bestSq then bestSq = d; bestArc = cum[i] + tt * (cum[i + 1] - cum[i]) end
  end
  return bestArc
end

-- True when rail arc `s` is within a crossing influence zone.
local function inCrossingZone(centers, halfs, s)
  for c = 1, #centers do
    if s >= centers[c] - halfs[c] and s <= centers[c] + halfs[c] then return true end
  end
  return false
end

-- Densifies inner/outer within each crossing band (to ~crossingSampleM) and returns the densified rails + the per-station
-- dip multiplier. Without the densification a coarse rail can have NO station inside the crossing band, so nothing
-- sinks and the walk stays full-height across the zebra -- exactly the "not dipping" case. `crossings` are a road's
-- { t, depthM } and `div` its centreline. Returns the ORIGINAL rails + nil when the road has no crossings.
local function crossingDips(crossings, div, inner, outer)
  local n = min(#inner, #outer)
  if not crossings or #crossings == 0 or n < 2 then return inner, outer, nil end
  if not div or #div < 2 then return inner, outer, nil end

  -- Rail-centre plan positions + cumulative 2D arc, 1:1 with the rail stations.
  local mx, my = table.new(n, 0), table.new(n, 0)
  local cum = table.new(n, 0)
  mx[1], my[1], cum[1] = (inner[1].x + outer[1].x) * 0.5, (inner[1].y + outer[1].y) * 0.5, 0
  for i = 2, n do
    mx[i], my[i] = (inner[i].x + outer[i].x) * 0.5, (inner[i].y + outer[i].y) * 0.5
    cum[i] = cum[i - 1] + sqrt((mx[i] - mx[i - 1]) ^ 2 + (my[i] - my[i - 1]) ^ 2)
  end

  -- Each crossing's centre (world) projected onto the rail -> its arc + influence half-width (band + ramp + margin).
  local centers, halfs, depths = {}, {}, {}
  for c = 1, #crossings do
    local cr = crossings[c]
    local cx, cy = centrelinePointAtT(div, cr.t or 0.5)
    centers[c] = nearestRailArc(mx, my, cum, n, cx, cy)
    depths[c] = cr.depthM or crossingDepthM
    halfs[c] = depths[c] * 0.5 + crossingRampM + 0.2
  end

  -- Sweep the rails, subdividing any segment that touches a crossing zone down to ~crossingSampleM so the flat + ramp has
  -- vertices.
  local ni, no, ncum = table.new(n, 0), table.new(n, 0), table.new(n, 0)
  ni[1], no[1], ncum[1] = inner[1], outer[1], cum[1]
  for i = 1, n - 1 do
    local s0, s1 = cum[i], cum[i + 1]
    local segLen = s1 - s0
    local touches = inCrossingZone(centers, halfs, s0) or inCrossingZone(centers, halfs, s1)
      or inCrossingZone(centers, halfs, (s0 + s1) * 0.5)
    if segLen > crossingSampleM and touches then
      local nSub = ceil(segLen / crossingSampleM)
      local ia, ib, oa, ob = inner[i], inner[i + 1], outer[i], outer[i + 1]
      for k = 1, nSub do
        local f = k / nSub
        local m = #ni + 1
        ni[m] = { x = ia.x + (ib.x - ia.x) * f, y = ia.y + (ib.y - ia.y) * f, z = ia.z + (ib.z - ia.z) * f }
        no[m] = { x = oa.x + (ob.x - oa.x) * f, y = oa.y + (ob.y - oa.y) * f, z = oa.z + (ob.z - oa.z) * f }
        ncum[m] = s0 + segLen * f
      end
    else
      local m = #ni + 1
      ni[m], no[m], ncum[m] = inner[i + 1], outer[i + 1], s1
    end
  end

  -- Densification preserves arc length, so the crossing centre arcs still index into ncum. Build the dip from them.
  return ni, no, dropScale(ncum, centers, depths)
end

-- How far out from the inner rail the outer one belongs: the kerb plus one paving stone.
local function width()
  return kerbSpec.spec.kerbW + kerbSpec.spec.slabW
end

-- How far the walking surface stands above the road the inner rail sits on.
local function rise()
  return kerbSpec.spec.kerbH
end


-- Public interface.
M.crossingRampM = crossingRampM
M.crossingDepthM = crossingDepthM

M.build = build
M.dropScale = dropScale
M.crossingDips = crossingDips
M.width = width
M.rise = rise

return M