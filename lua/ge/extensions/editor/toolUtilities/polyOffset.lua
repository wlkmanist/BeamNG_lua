-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Offsetting a polyline that carries one outward normal per edge.

local M = {}

-- Module constants.
local abs, sqrt = math.abs, math.sqrt
local MITER_LIMIT = 4.0
local OVERLAP_EPS = 0.05


local function lineIntersect(px, py, dx, dy, qx, qy, ex, ey)
  local denom = dx * ey - dy * ex
  if abs(denom) < 1e-9 then return nil end
  local t = ((qx - px) * ey - (qy - py) * ex) / denom
  return px + dx * t, py + dy * t
end

-- One offset point for a vertex turning between two edge normals: the mitre, clamped back along its own bisector where the
-- corner is too sharp to cut.
local function mitrePt(cx, cy, n1, n2, d)
  local bx, by = n1.x + n2.x, n1.y + n2.y
  local bl = sqrt(bx * bx + by * by)
  if bl < 1e-6 then bx, by, bl = n1.x, n1.y, 1 end
  bx, by = bx / bl, by / bl
  local half = bx * n1.x + by * n1.y   -- cos of half the turn: the mitre runs 1/cos further than the offset
  local len = (half > 1e-3) and (d / half) or (d * MITER_LIMIT)
  local lim = MITER_LIMIT * abs(d)
  if len > lim then len = lim elseif len < -lim then len = -lim end
  return cx + bx * len, cy + by * len
end

-- Offset a polyline sideways by signed distance d.
local function polyline(pts, nrm, d, join)
  local m = #pts
  local o = {}
  -- A ring comes in with its seam split into two coincident ends, but that seam is a corner like any other: mitred here,
  -- so both ends land on the one point the corner really turns through.
  local sx, sy
  if m > 3 and #nrm >= m - 1 and abs(pts[1].x - pts[m].x) < 1e-6 and abs(pts[1].y - pts[m].y) < 1e-6 then
    sx, sy = mitrePt(pts[1].x, pts[1].y, nrm[m - 1], nrm[1], d)
  end
  o[#o + 1] = sx and { x = sx, y = sy } or { x = pts[1].x + nrm[1].x * d, y = pts[1].y + nrm[1].y * d }
  for i = 2, m - 1 do
    local n1, n2 = nrm[i - 1], nrm[i]
    if abs(n1.x - n2.x) < 1e-6 and abs(n1.y - n2.y) < 1e-6 then
      o[#o + 1] = { x = pts[i].x + n1.x * d, y = pts[i].y + n1.y * d }
    else
      local cx, cy = pts[i].x, pts[i].y
      local b1x, b1y = cx + n1.x * d, cy + n1.y * d
      local a2x, a2y = cx + n2.x * d, cy + n2.y * d
      if join == 'chamfer' then
        o[#o + 1] = { x = b1x, y = b1y }; o[#o + 1] = { x = a2x, y = a2y }
      elseif join == 'miter' then
        -- One point per vertex, so two offsets of the same line pair up one for one. Chamfering a sharp corner instead
        -- doubles the run back on itself into a spike.
        local mx, my = mitrePt(cx, cy, n1, n2, d)
        o[#o + 1] = { x = mx, y = my }
      else
        local ix, iy = lineIntersect(b1x, b1y, cx - pts[i - 1].x, cy - pts[i - 1].y,
                                     a2x, a2y, pts[i + 1].x - cx, pts[i + 1].y - cy)
        if ix and sqrt((ix - cx) ^ 2 + (iy - cy) ^ 2) <= MITER_LIMIT * abs(d) then o[#o + 1] = { x = ix, y = iy }
        else o[#o + 1] = { x = b1x, y = b1y }; o[#o + 1] = { x = a2x, y = a2y } end
      end
    end
  end
  o[#o + 1] = sx and { x = sx, y = sy } or { x = pts[m].x + nrm[m - 1].x * d, y = pts[m].y + nrm[m - 1].y * d }
  return o
end

-- A closed ribbon from the line out to its offset. `overlap` is how far the base is sunk into the mass behind it.
local function run(pts, nrm, d, join, overlap)
  local m = #pts
  if m < 2 or abs(d) < 1e-4 then return nil end
  local ov = overlap or OVERLAP_EPS
  local outer = polyline(pts, nrm, d, join)
  local base = polyline(pts, nrm, (d >= 0 and -ov or ov))
  local ring = {}
  for i = 1, #base do ring[#ring + 1] = { x = base[i].x, y = base[i].y } end
  for i = #outer, 1, -1 do ring[#ring + 1] = { x = outer[i].x, y = outer[i].y } end
  return ring
end


-- Public interface.
M.MITER_LIMIT = MITER_LIMIT

M.lineIntersect = lineIntersect
M.mitrePt = mitrePt
M.polyline = polyline
M.run = run

return M