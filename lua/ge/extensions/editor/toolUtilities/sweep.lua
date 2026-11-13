-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Carrying a section along a path of frames, which is how every thin metal thing on this building is cut: a gutter, a
-- length of pipe, a bend, a conduit, a duct riser. A piece is a section and a path, and nothing here knows or cares
-- which of those it is being asked to make.
--
-- A frame is an origin and two axes. The section is written in that frame's own (s, t), so the same section swept along
-- +X, up +Z or round a turn comes out laid the right way each time without being rewritten.

local M = {}

-- Module dependencies.
local meshPart = require('editor/toolUtilities/meshPart')

-- Module constants.
local cos, sin, sqrt, pi = math.cos, math.sin, math.sqrt, math.pi
local SQRT2 = sqrt(2)
local face4, face3 = meshPart.face4, meshPart.face3


local function P(x, y, z) return { x = x, y = y, z = z } end

-- One frame of a swept path: the section's own (s, t) lands at o + a*s + b*t.
local function fr(ox, oy, oz, ax, ay, az, bx, by, bz)
  return { ox = ox, oy = oy, oz = oz, ax = ax, ay = ay, az = az, bx = bx, by = by, bz = bz }
end

local function at(f, s, t)
  return P(f.ox + f.ax * s + f.bx * t, f.oy + f.ay * s + f.by * t, f.oz + f.az * s + f.bz * t)
end

-- Which way a section is wound, so a face's reference direction can be turned OUT of the material rather than into it.
-- Handing a builder the same section reversed is therefore how a bore gets its faces looking inward.
local function winding(sect)
  local a, n = 0, #sect
  for k = 1, n do
    local j = (k % n) + 1
    a = a + sect[k][1] * sect[j][2] - sect[j][1] * sect[k][2]
  end
  return a >= 0 and 1 or -1
end

-- Sweep a closed section along a path of frames, one quad per section edge per step. UVs run the section's arc length
-- across and the distance travelled along, so a piece the placer stretches still tiles.
local function loft(p, sect, path, uv)
  local n, sgn = #sect, winding(sect)
  local run = 0
  for i = 1, #path - 1 do
    local f0, f1 = path[i], path[i + 1]
    local dx, dy, dz = f1.ox - f0.ox, f1.oy - f0.oy, f1.oz - f0.oz
    local v0 = run * uv
    run = run + sqrt(dx * dx + dy * dy + dz * dz)
    local v1 = run * uv
    local arc = 0
    for k = 1, n do
      local j = (k % n) + 1
      local s0, t0, s1, t1 = sect[k][1], sect[k][2], sect[j][1], sect[j][2]
      local ds, dt = s1 - s0, t1 - t0
      local u0 = arc * uv
      arc = arc + sqrt(ds * ds + dt * dt)
      local ns, nt = dt * sgn, -ds * sgn
      face4(p, at(f0, s0, t0), at(f0, s1, t1), at(f1, s1, t1), at(f1, s0, t0),
            f0.ax * ns + f0.bx * nt, f0.ay * ns + f0.by * nt, f0.az * ns + f0.bz * nt,
            { u0, v0 }, { arc * uv, v0 }, { arc * uv, v1 }, { u0, v1 })
    end
  end
end

-- Close one end of a loft, facing along the path (`sgn` 1) or back down it. Fanned, so the section has to be convex:
-- a section that is not is always butted into the next piece instead.
local function cap(p, sect, f, sgn, uv)
  local nx = (f.ay * f.bz - f.az * f.by) * sgn
  local ny = (f.az * f.bx - f.ax * f.bz) * sgn
  local nz = (f.ax * f.by - f.ay * f.bx) * sgn
  local a = sect[1]
  for k = 2, #sect - 1 do
    local b, c = sect[k], sect[k + 1]
    face3(p, at(f, a[1], a[2]), at(f, b[1], b[2]), at(f, c[1], c[2]), nx, ny, nz,
          { a[1] * uv, a[2] * uv }, { b[1] * uv, b[2] * uv }, { c[1] * uv, c[2] * uv })
  end
end

-- The flat band between two sections of the same count, at one frame: the mouth of an open pipe.
local function ring(p, inner, outer, f, sgn, uv)
  local nx = (f.ay * f.bz - f.az * f.by) * sgn
  local ny = (f.az * f.bx - f.ax * f.bz) * sgn
  local nz = (f.ax * f.by - f.ay * f.bx) * sgn
  local n = #inner
  for k = 1, n do
    local j = (k % n) + 1
    face4(p, at(f, inner[k][1], inner[k][2]), at(f, outer[k][1], outer[k][2]),
             at(f, outer[j][1], outer[j][2]), at(f, inner[j][1], inner[j][2]), nx, ny, nz,
          { inner[k][1] * uv, inner[k][2] * uv }, { outer[k][1] * uv, outer[k][2] * uv },
          { outer[j][1] * uv, outer[j][2] * uv }, { inner[j][1] * uv, inner[j][2] * uv })
  end
end

-- Sweep BETWEEN two sections of the same count, one frame each: how a head narrows from its mouth down to its spigot.
-- The same quad per section edge the straight loft lays, only with both ends free to be their own shape.
local function taper(p, s0, s1, f0, f1, uv)
  local n, sgn = #s0, winding(s0)
  local dx, dy, dz = f1.ox - f0.ox, f1.oy - f0.oy, f1.oz - f0.oz
  local v1 = sqrt(dx * dx + dy * dy + dz * dz) * uv
  local arc = 0
  for k = 1, n do
    local j = (k % n) + 1
    local a0, b0, a1, b1 = s0[k], s0[j], s1[k], s1[j]
    local ds, dt = b0[1] - a0[1], b0[2] - a0[2]
    local u0 = arc * uv
    arc = arc + sqrt(ds * ds + dt * dt)
    local ns, nt = dt * sgn, -ds * sgn
    face4(p, at(f0, a0[1], a0[2]), at(f0, b0[1], b0[2]), at(f1, b1[1], b1[2]), at(f1, a1[1], a1[2]),
          f0.ax * ns + f0.bx * nt, f0.ay * ns + f0.by * nt, f0.az * ns + f0.bz * nt,
          { u0, 0 }, { arc * uv, 0 }, { arc * uv, v1 }, { u0, v1 })
  end
end

-- A run along +X carrying a section laid in (y, z).
local function alongX(x0, x1)
  return { fr(x0, 0, 0, 0, 1, 0, 0, 0, 1), fr(x1, 0, 0, 0, 1, 0, 0, 0, 1) }
end

-- A run along +Y carrying a section laid in (x, z).
local function alongY(y0, y1)
  return { fr(0, y0, 0, 1, 0, 0, 0, 0, 1), fr(0, y1, 0, 1, 0, 0, 0, 0, 1) }
end

-- A run up +Z carrying a section laid in (x, y), optionally off the axis.
local function alongZ(z0, z1, cx, cy)
  cx, cy = cx or 0, cy or 0
  return { fr(cx, cy, z0, 1, 0, 0, 0, 1, 0), fr(cx, cy, z1, 1, 0, 0, 0, 1, 0) }
end

local function boxX(p, x0, x1, y0, y1, z0, z1, uv)
  local s = { { y0, z0 }, { y1, z0 }, { y1, z1 }, { y0, z1 } }
  local path = alongX(x0, x1)
  loft(p, s, path, uv)
  cap(p, s, path[1], -1, uv)
  cap(p, s, path[2], 1, uv)
end

-- The same box, stood up and swept on Z instead of run along X. A loft takes U round its section and V along its path, so
-- the two lay a face's texture at right angles to each other: this is the one to cut anything whose material has a WAY UP,
-- like brick, whose courses come out on end off boxX.
local function boxZ(p, x0, x1, y0, y1, z0, z1, uv)
  local s = { { x0, y0 }, { x1, y0 }, { x1, y1 }, { x0, y1 } }
  local path = alongZ(z0, z1)
  loft(p, s, path, uv)
  cap(p, s, path[1], -1, uv)
  cap(p, s, path[2], 1, uv)
end

local function circleSection(r, n)
  local s = {}
  for k = 1, n do
    local a = (k - 1) / n * 2 * pi
    s[k] = { r * cos(a), r * sin(a) }
  end
  return s
end

-- A square section about the origin, or a rectangle when handed a second half-size.
local function boxSection(hx, hy)
  hy = hy or hx
  return { { hx, hy }, { -hx, hy }, { -hx, -hy }, { hx, -hy } }
end

-- A regular OCTAGON about the origin, `m` from the centre out to each of its eight flats.
local function octSection(m)
  local k = m * (SQRT2 - 1) -- where a diagonal flat runs into an axis-aligned one
  return { { m, k }, { k, m }, { -k, m }, { -m, k }, { -m, -k }, { -k, -m }, { k, -m }, { m, -k } }
end

-- An octagonal post standing up +Z between two heights, capped at both ends: the shape above, swept, since every caller
-- that wants one wants exactly this and none of them want the three calls it takes.
local function octPost(p, m, z0, z1, uv)
  local s = octSection(m)
  local path = alongZ(z0, z1)
  loft(p, s, path, uv)
  cap(p, s, path[1], -1, uv)
  cap(p, s, path[2], 1, uv)
end

local function reversed(sect)
  local o, n = {}, #sect
  for k = 1, n do o[k] = sect[n + 1 - k] end
  return o
end

-- A rectangle written as EIGHT points rather than four, taken round at the same angles a circle of the same count is,
-- so a flat plate can be closed from one onto the other.
local function rect8(hx, hy, cy)
  cy = cy or 0
  return { { hx, cy }, { hx, cy + hy }, { 0, cy + hy }, { -hx, cy + hy },
           { -hx, cy }, { -hx, cy - hy }, { 0, cy - hy }, { hx, cy - hy } }
end

-- A quarter turn in plan: in along +X at the origin, out toward `sy` on Y. The section is carried round unrolled, so a
-- trough stays upright through the turn the way a pressed angle does.
local function turnPath(R, sy, ang, segs)
  local path = {}
  for i = 0, segs do
    local th = i / segs * ang
    local c, s = cos(th), sin(th)
    path[i + 1] = fr(R * s, sy * (R - R * c), 0, -sy * s, c, 0, 0, 0, 1)
  end
  return path
end

-- A turn in the vertical plane: in along +Z at the origin, out leaning onto -Y, which is outward off the wall.
local function kinkPath(R, ang, segs)
  local path = {}
  for i = 0, segs do
    local th = i / segs * ang
    local c, s = cos(th), sin(th)
    path[i + 1] = fr(0, -R + R * c, R * s, 1, 0, 0, 0, c, s)
  end
  return path
end


-- Public interface.
M.P = P
M.fr = fr
M.at = at
M.loft = loft
M.cap = cap
M.ring = ring
M.taper = taper
M.alongX = alongX
M.alongY = alongY
M.alongZ = alongZ
M.boxX = boxX
M.boxZ = boxZ
M.circleSection = circleSection
M.boxSection = boxSection
M.octSection = octSection
M.octPost = octPost
M.reversed = reversed
M.rect8 = rect8
M.turnPath = turnPath
M.kinkPath = kinkPath

return M