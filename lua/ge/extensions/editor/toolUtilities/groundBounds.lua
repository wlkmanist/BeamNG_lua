-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- What a ground tool is NOT allowed to have: the road its outline was drawn across, the buildings standing in it, and any
-- ground another tool has already surfaced. And the other half of the same conversation -- telling everyone else what this
-- tool is standing on.
--
-- Every tool that draws an outline on the terrain and then covers it asks exactly these questions, so they are asked here
-- rather than once per tool. `owner` throughout is the name that tool publishes its own claims under, so that whatever it
-- has staked is not handed back to it as something to keep off.

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')
local polyBool = require('editor/toolUtilities/polyBool')
local groundClaims = require('editor/toolUtilities/groundClaims')
local networkState = require('editor/toolUtilities/networkState')

-- Module constants.
local ROAD_MARGIN = 0.10
local ROAD_STANDOFF = 0.6
-- How near a clipped side has to run to the outline it was cut from to be counted as part of it. The boolean reproduces the
-- subject's own vertices, so this is slack for the arithmetic rather than a distance anyone would measure.
local DRAWN_TOL = 0.05
-- And how near another tool's ground has to run for the join to count as flush. A real distance, this one: the same 200 mm
-- the placer's pavement calls buried.
local SEAM_TOL = 0.20
local SIDE_STEPS = 4 -- points asked down a side before it is called one thing or the other
local APART_TOL = 0.05 -- nearer than this an obstacle goes through the boolean even if it only touches
local CROP_PAD = 1.0 -- how far wide of the outline an obstacle is cut back to before it is taken out
local min, max, huge = math.min, math.max, math.huge


--- Everything near this outline that `owner` may not pave: road and junction surfaces, and every claim another ground tool
--- has staked -- a placed building's footprint, a park. `site` is the shelf folder of the site being edited, if it has one:
--- wherever a copy of it already stands, that copy is this outline and not something in its way. `roadMargin` keeps it
--- further off the roads than the default.
local function obstacles(ring, owner, site, roadMargin)
  local obs, roads = groundClaims.obstructions(ring, owner, networkState.surfaces(), max(roadMargin or 0, ROAD_MARGIN), nil, site)
  local stand = {}
  for i = 1, #obs do
    stand[i] = roads[obs[i]] and (geom.outsetClosedRing2D(obs[i], ROAD_STANDOFF) or obs[i]) or obs[i]
  end
  return obs, stand
end

--- Does the whole of side `i` run along one of `rings`? Asked at points down its length rather than only at its middle: a
--- side that runs off the end of whatever it is being tested against is a different side for the half that does not, and a
--- side is one thing or the other as a whole.
local function sideOn(ring, i, rings, tol)
  local n = #ring
  local a, b = ring[i], ring[i % n + 1]
  for s = 0, SIDE_STEPS do
    local f = s / SIDE_STEPS
    local x, y = a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f
    local near = false
    for r = 1, #rings do
      local q = rings[r]
      local m = #q
      for g = 1, m do
        if geom.distSqPointSeg2D(x, y, q[g].x, q[g].y, q[g % m + 1].x, q[g % m + 1].y) < tol * tol then
          near = true
          break
        end
      end
      if near then break end
    end
    if not near then return false end
  end
  return true
end

--- Two things about each side of a clipped piece. They are independent, and both are needed:
---   cut[i]    the subtraction made this side. It is not the outline at all -- there is a road or a building on the far side
---             of it -- so nothing the perimeter is dressed with belongs along it
---   flush[i]  it lies against ground another tool has already surfaced, so the paving is left open there and the two read
---             as one continuous surface instead of meeting at a wall
local function sidesOf(ring, drawn, claims)
  local cut, flush = {}, {}
  for i = 1, #ring do
    if not sideOn(ring, i, drawn, DRAWN_TOL) then cut[i] = true end
    if sideOn(ring, i, claims, SEAM_TOL) then flush[i] = true end
  end
  return cut, flush
end

--- Are two rings well clear of each other: no side of one crossing or within `APART_TOL` of a side of the other, and
--- neither inside the other? Subtracting such a ring changes nothing, and the boolean is the cost of a clip.
local function ringsApart(a, b)
  local tol2 = APART_TOL * APART_TOL
  local na, nb = #a, #b
  for i = 1, na do
    local p, q = a[i], a[i % na + 1]
    local ax0, ax1 = min(p.x, q.x) - APART_TOL, max(p.x, q.x) + APART_TOL
    local ay0, ay1 = min(p.y, q.y) - APART_TOL, max(p.y, q.y) + APART_TOL
    for k = 1, nb do
      local r, s = b[k], b[k % nb + 1]
      if max(r.x, s.x) >= ax0 and min(r.x, s.x) <= ax1 and max(r.y, s.y) >= ay0 and min(r.y, s.y) <= ay1 then
        if geom.segCrossParam2D(p.x, p.y, q.x, q.y, r.x, r.y, s.x, s.y)
          or geom.distSqPointSeg2D(p.x, p.y, r.x, r.y, s.x, s.y) < tol2
          or geom.distSqPointSeg2D(q.x, q.y, r.x, r.y, s.x, s.y) < tol2
          or geom.distSqPointSeg2D(r.x, r.y, p.x, p.y, q.x, q.y) < tol2
          or geom.distSqPointSeg2D(s.x, s.y, p.x, p.y, q.x, q.y) < tol2 then
          return false
        end
      end
    end
  end
  return not (geom.pointInRing2D(b[1].x, b[1].y, a) or geom.pointInRing2D(a[1].x, a[1].y, b))
end

local function apartFromAll(regions, o)
  for i = 1, #regions do
    if not ringsApart(regions[i], o) then return false end
  end
  return true
end

--- The outline minus everything above, as a list of `{ ring, holes, cut, flush }` to surface one at a time.
local function clip(ring, obs, owner, site)
  if not (ring and #ring >= 3) then return {} end
  local areas
  if not obs or #obs == 0 then
    areas = { { ring = ring, holes = {} } }
  else
    -- A road runs on far past the outline and the boolean pays for every metre of it, so each obstacle is cut down to the
    -- outline's box first, wide enough that the cut's own edges never touch it. Taken one at a time: cut to the same box,
    -- two of them share its edge, and subtracted together the shared edge cancels and loses them both.
    local x0, y0, x1, y1 = huge, huge, -huge, -huge
    for i = 1, #ring do
      local p = ring[i]
      x0, y0, x1, y1 = min(x0, p.x), min(y0, p.y), max(x1, p.x), max(y1, p.y)
    end
    x0, y0, x1, y1 = x0 - CROP_PAD, y0 - CROP_PAD, x1 + CROP_PAD, y1 + CROP_PAD
    local res = { regions = { ring } }
    for i = 1, #obs do
      local o = geom.clipRingRect2D(obs[i], x0, x1, y0, y1)
      if #o >= 3 and not apartFromAll(res.regions, o) then
        res = polyBool.difference(res, { regions = { o } })
        if #(res.regions or {}) == 0 then break end
      end
    end
    areas = polyBool.areas(res.regions or {})
  end
  -- The claims are asked for again rather than picked back out of `obs`, which has the roads mixed in with them by now and
  -- no way to say which is which. Asked even when nothing was clipped: an outline can butt straight onto a neighbour's ground
  -- without a single node of it being taken away, and the join still wants to be a join. Only the ones near it.
  local drawn, claims = { ring }, groundClaims.obstructions(ring, owner, nil, 0, SEAM_TOL, site)
  for i = 1, #areas do areas[i].cut, areas[i].flush = sidesOf(areas[i].ring, drawn, claims) end
  return areas
end

--- The biggest of them, for a tool that lays ONE thing on its outline rather than one per piece. A car park cut in two by a
--- road is two car parks, and the second is a second lot to draw -- not something to infer from the first.
local function largest(areas)
  local best, bestA = nil, -1
  for i = 1, #(areas or {}) do
    local a = math.abs(geom.ringSignedArea2(areas[i].ring) or 0)
    if a > bestA then best, bestA = areas[i], a end
  end
  return best
end

--- Which clipped piece a point is on, if it is on one at all. What everything standing round the perimeter asks before it
--- stands -- a flight of steps, a lamp on the wall -- and the flights want the piece itself, since the wall is laid one
--- piece at a time and a flight has to open the one it comes through.
local function pieceAt(areas, x, y)
  for a = 1, #(areas or {}) do
    local ar = areas[a]
    if geom.pointInRing2D(x, y, ar.ring) then
      for k = 1, #(ar.holes or {}) do
        if geom.pointInRing2D(x, y, ar.holes[k]) then return nil end
      end
      return a
    end
  end
  return nil
end

--- Tell the other ground tools what this one is standing on. No margin: two surfaces meeting should read as one, and a gap
--- would show as a strip of bare terrain the width of whatever was allowed.
local function publish(owner, rings) groundClaims.publish(owner, rings, 0) end

--- A fingerprint of everything outside an outline that its shape depends on, so a road or a building moved under one rebuilds
--- it. Asked every frame of every outline, so neither half builds a ring to answer: the roads fingerprint what a scan would
--- read without scanning, and a claim is counted when it is published rather than measured here.
local function sig() return networkState.sig() + groundClaims.sig() * 104729 end


-- Public interface.
M.obstacles = obstacles
M.clip = clip
M.largest = largest
M.pieceAt = pieceAt
M.publish = publish
M.sig = sig

return M