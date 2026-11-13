-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Solid-triangle drawing for the spline-editing tools. Split out of the old monolithic render.lua. Depends on
-- debugDraw + the shared style, plus geom for the polygon-fill helper. Triangles cull against the same 600 m radius
-- as the other geometry.

local M = {}

-- Module dependencies.
local dbgDraw = require('utils/debugDraw')
local styleCore = require('editor/toolUtilities/style')
local geom = require('editor/toolUtilities/geom')

-- Module constants.
local min, max, huge = math.min, math.max, math.huge
local cullDist = 600.0
local cullDistSq = cullDist * cullDist
local style = styleCore.getStyle()

-- Module state.
local sfXs = {}
local sfA, sfB, sfC, sfD = vec3(), vec3(), vec3(), vec3()


local function drawTriCulled(a, b, c, col)
  local camPos = core_camera.getPosition()
  if a:squaredDistance(camPos) < cullDistSq and b:squaredDistance(camPos) < cullDistSq and c:squaredDistance(camPos) < cullDistSq then
    dbgDraw.drawTriSolid(a, b, c, col, true)
  end
end
local function drawTriNotSelectedSurface(a, b, c) drawTriCulled(a, b, c, style.colourNotSelectedSurf) end
local function drawTriPreviewSurface(a, b, c) drawTriCulled(a, b, c, style.colourPreviewSurf) end
local function drawTriActiveSurface(a, b, c) drawTriCulled(a, b, c, style.colourActiveSurf) end

-- Fill a simple (possibly concave) polygon given its vertices as vec3s already lifted to the draw height. Ear-clips
-- in 2D (x,y) via geom, then draws solid, culled triangles in packed colour `col`. No-op for < 3 verts or a
-- degenerate ring (triangulation returns nothing, so the caller's outline is all that shows).
local function drawFilledPolygon(verts, col)
  local n = #verts
  if n < 3 then return end
  local tris = geom.triangulatePolygon2D(verts)
  for t = 1, #tris do
    local tri = tris[t]
    drawTriCulled(verts[tri[1]], verts[tri[2]], verts[tri[3]], col)
  end
end

-- Fill a set of 2D regions (each ring = array of {x=,y=}), holes included, using the EVEN-ODD rule via horizontal
-- scanlines: a point inside an odd number of rings is filled, so opposite-wound hole rings punch true voids and
-- overlapping outer rings don't double up. Handles concave shapes and multiple disjoint regions with no
-- triangulation. `zFn(x,y)` lifts each corner to the draw height (e.g. terrain height); `step` is the scan spacing
-- (auto-sized from the bounds when omitted). The scan-resolution staircase on diagonal edges is hidden by the
-- caller's exact outline pass. Meant for preview fills, not for cooked geometry.
local function drawFilledRegions2D(regions, col, zFn, step)
  local nr = #regions
  if nr == 0 then return end
  local ymin, ymax = huge, -huge
  for r = 1, nr do
    local ring = regions[r]
    for i = 1, #ring do
      local py = ring[i].y
      if py < ymin then ymin = py end
      if py > ymax then ymax = py end
    end
  end
  if ymax <= ymin then return end
  step = step or max(0.25, min(3.0, (ymax - ymin) / 100))
  local half = step * 0.5

  local y = ymin + half
  while y < ymax do
    -- Collect x-crossings of every ring edge at this scanline (half-open rule avoids double-counting at vertices).
    local m = 0
    for r = 1, nr do
      local ring = regions[r]
      local cnt = #ring
      local a = ring[cnt]
      for i = 1, cnt do
        local b = ring[i]
        local ay, by = a.y, b.y
        if (ay <= y and by > y) or (by <= y and ay > y) then
          m = m + 1
          sfXs[m] = a.x + (y - ay) / (by - ay) * (b.x - a.x)
        end
        a = b
      end
    end
    -- Insertion sort (m is tiny) then fill even-odd spans.
    for i = 2, m do
      local v = sfXs[i]; local j = i - 1
      while j >= 1 and sfXs[j] > v do sfXs[j + 1] = sfXs[j]; j = j - 1 end
      sfXs[j + 1] = v
    end
    local y0, y1 = max(ymin, y - half), min(ymax, y + half)
    for i = 1, m - 1, 2 do
      local x0, x1 = sfXs[i], sfXs[i + 1]
      if x1 > x0 then
        sfA:set(x0, y0, zFn(x0, y0))
        sfB:set(x1, y0, zFn(x1, y0))
        sfC:set(x1, y1, zFn(x1, y1))
        sfD:set(x0, y1, zFn(x0, y1))
        drawTriCulled(sfA, sfB, sfC, col)
        drawTriCulled(sfA, sfC, sfD, col)
      end
    end
    y = y + step
  end
end


-- Public interface.
M.drawTriCulled = drawTriCulled
M.drawTriNotSelectedSurface = drawTriNotSelectedSurface
M.drawTriPreviewSurface = drawTriPreviewSurface
M.drawTriActiveSurface = drawTriActiveSurface
M.drawFilledPolygon = drawFilledPolygon
M.drawFilledRegions2D = drawFilledRegions2D

return M