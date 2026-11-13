-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Deck sweep: a crowned slab swept along any centreline as ONE unique mesh. The cross-section (a carriageway crowned at the
-- line, flat footway strips outboard of it, vertical sides and a flat soffit) is laid at every station of the dense line, the
-- stations are decimated to a chordal tolerance (plan and vertical apart) on the centre AND both outer top edges, and each end can taper into a short
-- skirt (top ramped down, soffit pulled up to a thin lip) that seals to the ground. Extents may vary per station.

local M = {}

-- Module dependencies.
local meshPart = require('editor/toolUtilities/meshPart')
local meshRefine = require('editor/heroRoadEditor/meshRefine')

-- Module constants.
local sqrt, min, max = math.sqrt, math.min, math.max
local face4, face4n = meshPart.face4, meshPart.face4n
local minBand = 1e-4 -- a band narrower than this at both of its stations is not emitted


-- A section field: a number, or an array indexed by dense station.
local function at(v, i)
  if type(v) == 'table' then return v[i] end
  return v
end

local function V(x, y, z) return { x = x, y = y, z = z } end

-- Unit frame at dense station i: along t (3D, central difference), across c (horizontal, up x t) and up m = t x c (pitched
-- with the grade, so the section stands square to the deck).
local function frameAt(dp, i)
  local n = #dp
  local a, b = dp[max(1, i - 1)], dp[min(n, i + 1)]
  local tx, ty, tz = b.x - a.x, b.y - a.y, b.z - a.z
  local tl = sqrt(tx * tx + ty * ty + tz * tz)
  if tl < 1e-9 then tx, ty, tz, tl = 1, 0, 0, 1 end
  tx, ty, tz = tx / tl, ty / tl, tz / tl
  local cx, cy = -ty, tx
  local cl = sqrt(cx * cx + cy * cy)
  if cl < 1e-9 then cx, cy, cl = 0, 1, 1 end
  cx, cy = cx / cl, cy / cl
  return tx, ty, tz, cx, cy, -tz * cy, tz * cx, tx * cy - ty * cx
end

-- The five top columns of the section at station i: outer left footway edge, left carriageway edge, crown, right carriageway
-- edge, outer right footway edge. Returns the lateral offsets and the heights (the footway is flat at the carriageway edge).
-- `crown` = the crown drop at this station.
local function columns(sec, i, crown)
  local eL, eR = at(sec.extL, i), at(sec.extR, i)
  local fL, fR = at(sec.fwL, i) or 0, at(sec.fwR, i) or 0
  local zL = eL > 1e-6 and -crown or 0
  local zR = eR > 1e-6 and -crown or 0
  return { -(eL + fL), -eL, 0, eR, eR + fR }, { zL, zL, 0, zR, zR }
end

-- One cross-section ring at dense station i, slid `off` along its tangent (the chamfer tip), top lowered by `drop`, soffit at bz.
-- Normals come from the undropped section, so a skirt shades exactly like the deck it continues.
local function ring(dp, i, sec, crown, s, off, drop, bz)
  local tx, ty, tz, cx, cy, mx, my, mz = frameAt(dp, i)
  local p = dp[i]
  local px, py, pz = p.x + tx * off, p.y + ty * off, p.z + tz * off
  local ys, zs = columns(sec, i, crown)
  local top, nTop = {}, {}
  for k = 1, 5 do
    local y, z = ys[k], zs[k] - drop
    top[k] = V(px + cx * y + mx * z, py + cy * y + my * z, pz + mz * z)
  end
  local m = V(mx, my, mz)
  for k = 1, 4 do
    local dy, dz = ys[k + 1] - ys[k], zs[k + 1] - zs[k]
    local nx, ny, nz = mx * dy - cx * dz, my * dy - cy * dz, mz * dy
    local nl = sqrt(nx * nx + ny * ny + nz * nz)
    nTop[k] = nl > 1e-9 and V(nx / nl, ny / nl, nz / nl) or m
  end
  local yl, yr = ys[1], ys[5]
  return {
    s = s, ys = ys, zs = zs, drop = drop, bz = bz, px = px, py = py, pz = pz,
    t = V(tx, ty, tz), c = V(cx, cy, 0), m = m, top = top, nTop = nTop,
    botL = V(px + cx * yl + mx * bz, py + cy * yl + my * bz, pz + mz * bz),
    botR = V(px + cx * yr + mx * bz, py + cy * yr + my * bz, pz + mz * bz),
    nL = V(-cx, -cy, 0), nR = V(cx, cy, 0), nB = V(-mx, -my, -mz),
  }
end

-- The faces between two consecutive rings: four top bands (carriageway on topPart, footways on bodyPart), both sides, soffit.
-- Metric UVs: u = arc along the deck, v = lateral offset (top / soffit) or height (sides).
local function bridge(a, b, topPart, bodyPart)
  local m = a.m
  for k = 1, 4 do
    if a.ys[k + 1] - a.ys[k] > minBand or b.ys[k + 1] - b.ys[k] > minBand then
      local part = (k == 2 or k == 3) and topPart or bodyPart
      face4n(part, a.top[k], b.top[k], b.top[k + 1], a.top[k + 1], m.x, m.y, m.z,
        { a.s, a.ys[k] }, { b.s, b.ys[k] }, { b.s, b.ys[k + 1] }, { a.s, a.ys[k + 1] }, a.nTop[k], b.nTop[k], b.nTop[k], a.nTop[k])
    end
  end
  local c = a.c
  local zaL, zbL, zaR, zbR = a.zs[1] - a.drop, b.zs[1] - b.drop, a.zs[5] - a.drop, b.zs[5] - b.drop
  face4n(bodyPart, a.top[1], b.top[1], b.botL, a.botL, -c.x, -c.y, 0,
    { a.s, zaL }, { b.s, zbL }, { b.s, b.bz }, { a.s, a.bz }, a.nL, b.nL, b.nL, a.nL)
  face4n(bodyPart, a.top[5], b.top[5], b.botR, a.botR, c.x, c.y, 0,
    { a.s, zaR }, { b.s, zbR }, { b.s, b.bz }, { a.s, a.bz }, a.nR, b.nR, b.nR, a.nR)
  face4n(bodyPart, a.botL, b.botL, b.botR, a.botR, -m.x, -m.y, -m.z,
    { a.s, a.ys[1] }, { b.s, b.ys[1] }, { b.s, b.ys[5] }, { a.s, a.ys[5] }, a.nB, b.nB, b.nB, a.nB)
end

-- Close one end of the sweep: a quad per top band down to the soffit, facing out along sign * tangent.
local function cap(r, sign, bodyPart)
  local t, c, m, bz = r.t, r.c, r.m, r.bz
  for k = 1, 4 do
    local y0, y1 = r.ys[k], r.ys[k + 1]
    if y1 - y0 > minBand then
      local b0 = V(r.px + c.x * y0 + m.x * bz, r.py + c.y * y0 + m.y * bz, r.pz + m.z * bz)
      local b1 = V(r.px + c.x * y1 + m.x * bz, r.py + c.y * y1 + m.y * bz, r.pz + m.z * bz)
      face4(bodyPart, r.top[k], r.top[k + 1], b1, b0, t.x * sign, t.y * sign, t.z * sign,
        { y0, r.zs[k] - r.drop }, { y1, r.zs[k + 1] - r.drop }, { y1, bz }, { y0, bz })
    end
  end
end

-- Sweep the deck along the dense line `dp` (vec3s or {x,y,z} tables).
-- sec  = { extL, extR, fwL, fwR (numbers or per-station arrays), crown, flatEnd (m the crown eases out to flat over at each end;
--          nil/0 = none), slabT, topMat, bodyMat, chamfer = { len, drop, lipT } | nil }
-- opts = { tol (plan chordal tolerance, m), tolZ (vertical chordal tolerance, m; nil = tol bounds both), maxSeg (longest kept gap, m) }
-- Returns the parts plus the kept dense station indices, or nil for a degenerate line.
local function build(dp, sec, opts)
  local n = #dp
  if n < 2 then return nil end
  local arc, W, crown = { 0 }, {}, {}
  for i = 2, n do
    local a, b = dp[i - 1], dp[i]
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    arc[i] = arc[i - 1] + sqrt(dx * dx + dy * dy + dz * dz)
  end
  local total = arc[n]
  if total < 1e-3 then return nil end
  local flat = sec.flatEnd or 0
  for i = 1, n do
    local f = 1
    if flat > 1e-6 then
      f = min(1, min(arc[i], total - arc[i]) / flat)
      f = f * f * (3 - 2 * f)
    end
    crown[i] = sec.crown * f
    local _, _, _, cx, cy, mx, my, mz = frameAt(dp, i)
    local ys, zs = columns(sec, i, crown[i])
    local p, yl, zl, yr, zr = dp[i], ys[1], zs[1], ys[5], zs[5]
    W[i] = { V(p.x + cx * yl + mx * zl, p.y + cy * yl + my * zl, p.z + mz * zl), V(p.x + cx * yr + mx * zr, p.y + cy * yr + my * zr, p.z + mz * zr) }
  end
  local kept = meshRefine.decimateStations(dp, W, 2, opts.tol, n, opts.maxSeg, nil, opts.tolZ)

  -- atStart / atEnd = false leave that end square (it butts onto another slab rather than meeting the ground).
  local cf, rings = sec.chamfer, {}
  if cf and cf.atStart ~= false then rings[1] = ring(dp, 1, sec, crown[1], -cf.len, -cf.len, cf.drop, -crown[1] - cf.lipT - cf.drop) end
  for j = 1, #kept do
    local i = kept[j]
    rings[#rings + 1] = ring(dp, i, sec, crown[i], arc[i], 0, 0, -sec.slabT)
  end
  if cf and cf.atEnd ~= false then rings[#rings + 1] = ring(dp, n, sec, crown[n], total + cf.len, cf.len, cf.drop, -crown[n] - cf.lipT - cf.drop) end

  local bodyPart = meshPart.newPart()
  bodyPart.material = sec.bodyMat
  local topPart = bodyPart
  if sec.topMat ~= sec.bodyMat then
    topPart = meshPart.newPart()
    topPart.material = sec.topMat
  end
  for j = 1, #rings - 1 do bridge(rings[j], rings[j + 1], topPart, bodyPart) end
  cap(rings[1], -1, bodyPart)
  cap(rings[#rings], 1, bodyPart)
  local parts = { bodyPart }
  if topPart ~= bodyPart then parts[2] = topPart end
  return parts, kept
end


-- Public interface.
M.build = build

return M