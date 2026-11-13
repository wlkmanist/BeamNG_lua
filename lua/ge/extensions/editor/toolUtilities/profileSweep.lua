-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Profile sweep: open 2D strips (lateral y, height z) swept along a line of stations that carry their own frames, as one unique
-- mesh. Unlike deckSweep, the frame is the caller's (a road's banked binormal and normal), so the section turns with the road.
-- The stations are decimated to a chordal tolerance on the centre and two key points of the section.

local M = {}

-- Module dependencies.
local meshPart = require('editor/toolUtilities/meshPart')
local meshRefine = require('editor/heroRoadEditor/meshRefine')

-- Module constants.
local sqrt = math.sqrt


local function V(x, y, z) return { x = x, y = y, z = z } end

-- World point of section point (y, z) at station a.
local function at(a, y, z)
  return V(a.x + a.bx * y + a.nx * z, a.y + a.by * y + a.ny * z, a.z + a.bz * y + a.nz * z)
end

-- World direction of section direction (y, z) at station a.
local function dirAt(a, y, z)
  return V(a.bx * y + a.nx * z, a.by * y + a.ny * z, a.bz * y + a.nz * z)
end

-- Arc length along a strip's points.
local function stripArc(pts)
  local cum = { 0 }
  for k = 2, #pts do
    local dy, dz = pts[k][1] - pts[k - 1][1], pts[k][2] - pts[k - 1][2]
    cum[k] = cum[k - 1] + sqrt(dy * dy + dz * dz)
  end
  return cum
end

-- Sweep `strips` along the stations `st` ({ x, y, z, bx, by, bz (across), nx, ny, nz (up), s (arc) } each).
-- strip = { pts = { { y, z }, ... }, nrm = { { ny, nz }, ... } (unit, toward the visible side), mat }
-- opts  = { tol, tolZ, maxSeg (the decimation, as deckSweep), keyL, keyR (the section points it watches, { y, z }) }
-- Returns the parts (one per material) and the kept station indices, or nil for fewer than two stations.
local function build(st, strips, opts)
  local n = #st
  if n < 2 then return nil end
  local W = {}
  for i = 1, n do W[i] = { at(st[i], opts.keyL[1], opts.keyL[2]), at(st[i], opts.keyR[1], opts.keyR[2]) } end
  local kept = meshRefine.decimateStations(st, W, 2, opts.tol, n, opts.maxSeg, nil, opts.tolZ)

  local byMat, parts = {}, {}
  for si = 1, #strips do
    local sp = strips[si]
    local part = byMat[sp.mat]
    if not part then
      part = meshPart.newPart()
      part.material = sp.mat
      byMat[sp.mat] = part
      parts[#parts + 1] = part
    end
    local pts, nrm, cum = sp.pts, sp.nrm, stripArc(sp.pts)
    for j = 1, #kept - 1 do
      local a, b = st[kept[j]], st[kept[j + 1]]
      for k = 1, #pts - 1 do
        local p0, p1, n0, n1 = pts[k], pts[k + 1], nrm[k], nrm[k + 1]
        local na0, na1 = dirAt(a, n0[1], n0[2]), dirAt(a, n1[1], n1[2])
        local nb0, nb1 = dirAt(b, n0[1], n0[2]), dirAt(b, n1[1], n1[2])
        meshPart.face4n(part, at(a, p0[1], p0[2]), at(b, p0[1], p0[2]), at(b, p1[1], p1[2]), at(a, p1[1], p1[2]),
          na0.x + na1.x, na0.y + na1.y, na0.z + na1.z,
          { a.s, cum[k] }, { b.s, cum[k] }, { b.s, cum[k + 1] }, { a.s, cum[k + 1] }, na0, nb0, nb1, na1)
      end
    end
  end
  return parts, kept
end


-- Public interface.
M.at = at
M.build = build

return M