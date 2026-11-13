-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Draggable "gate" handles that live on a polygon boundary ring.

local M = {}

-- Module dependencies.
local rSpheres = require('editor/toolUtilities/render/spheres')
local dbgDraw = require('utils/debugDraw')

-- Module constants.
local atan2, cos, sin, sqrt, huge = math.atan2, math.cos, math.sin, math.sqrt, math.huge


-- Vertex-average centre of a ring (NOT area-weighted -- deliberately matches the simple centre used to pick an outward
-- direction; see geom.multiPolygonCentroidXY for the area-weighted variant).
local function centroid(ring)
  local cx, cy, n = 0, 0, #ring
  for i = 1, n do
    cx = cx + ring[i].x
    cy = cy + ring[i].y
  end
  return cx / n, cy / n
end

-- Principal axis angle of the ring's point cloud (the long axis), used to seat default gates at opposite ends.
local function principalAngle(ring)
  local cx, cy = centroid(ring)
  local sxx, sxy, syy = 0, 0, 0
  for i = 1, #ring do
    local dx, dy = ring[i].x - cx, ring[i].y - cy
    sxx = sxx + dx * dx
    sxy = sxy + dx * dy
    syy = syy + dy * dy
  end
  return 0.5 * atan2(2 * sxy, sxx - syy)
end

-- Nearest point ON the ring boundary to (px,py). Returns qx, qy.
local function nearestOnRing(ring, px, py)
  local bx, by, bd, n = ring[1].x, ring[1].y, huge, #ring
  for i = 1, n do
    local a, b = ring[i], ring[(i % n) + 1]
    local ex, ey = b.x - a.x, b.y - a.y
    local el = ex * ex + ey * ey
    local t = el > 1e-9 and ((px - a.x) * ex + (py - a.y) * ey) / el or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local qx, qy = a.x + ex * t, a.y + ey * t
    local d = (qx - px) * (qx - px) + (qy - py) * (qy - py)
    if d < bd then bx, by, bd = qx, qy, d end
  end
  return bx, by
end

-- Every gate in the list given a name of its own, and the list handed back. A gate is otherwise known only by where it is
-- in its list, which shifts the moment one before it is removed -- no use to anything that has to keep hold of one. Called
-- from the accessors, so a list saved before this is named on the way out of the first one to ask for it.
local function tagGates(gates)
  for i = 1, #(gates or {}) do
    if not gates[i].id then gates[i].id = Engine.generateUUID() end
  end
  return gates
end

-- Snap a world point (px,py) to the nearest gate on the ring. Returns { edge, t }.
local function nearestGate(ring, px, py)
  local bi, bt, bd, n = 1, 0, huge, #ring
  for i = 1, n do
    local a, b = ring[i], ring[(i % n) + 1]
    local ex, ey = b.x - a.x, b.y - a.y
    local el = ex * ex + ey * ey
    local t = el > 1e-9 and ((px - a.x) * ex + (py - a.y) * ey) / el or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local qx, qy = a.x + ex * t, a.y + ey * t
    local d = (qx - px) * (qx - px) + (qy - py) * (qy - py)
    if d < bd then bi, bt, bd = i, t, d end
  end
  return { edge = bi, t = bt }
end

-- World position of a gate plus the OUTWARD unit normal of its edge (pointing away from the ring centre). Returns wx, wy, nx, ny.
local function gateWorldDir(ring, gate)
  local n = #ring
  local i = gate.edge or 1
  if i < 1 or i > n then i = 1 end
  local a, b = ring[i], ring[(i % n) + 1]
  local wx, wy = a.x + (b.x - a.x) * (gate.t or 0), a.y + (b.y - a.y) * (gate.t or 0)
  local ex, ey = b.x - a.x, b.y - a.y
  local el = sqrt(ex * ex + ey * ey)
  local nx, ny = (el > 1e-9) and ey / el or 0, (el > 1e-9) and -ex / el or 0
  local cx, cy = centroid(ring)
  if (cx - wx) * nx + (cy - wy) * ny > 0 then nx, ny = -nx, -ny end
  return wx, wy, nx, ny
end

-- A default pair of gates at opposite ends of the ring's long axis (entrance, exit).
local function defaultGates(ring)
  local theta = principalAngle(ring)
  local cx, cy = centroid(ring)
  local dx, dy = cos(theta), sin(theta)
  local ex, ey = nearestOnRing(ring, cx + dx * 1e5, cy + dy * 1e5)
  local xx, xy = nearestOnRing(ring, cx - dx * 1e5, cy - dy * 1e5)
  return nearestGate(ring, ex, ey), nearestGate(ring, xx, xy)
end

-- What a caller that gave no lift gets: the plane at zero. Up here rather than defaulted inline, so asking for it costs
-- no closure.
local function flatLift(x, y) return vec3(x, y, 0) end

-- Geometry of the grabbable widget for `gate`: the bar is floated `outDist` m outside the edge and spans `halfWidth` m each
-- way along it. `liftFn(x,y) -> vec3` lifts a world point to the terrain (identity plane if omitted). Returns the edge point,
-- the bar centre (grab knob), and the two bar ends -- or nil if the gate is invalid.
local function handleGeom(ring, gate, outDist, halfWidth, liftFn)
  if not gate then return nil end
  local wx, wy, nx, ny = gateWorldDir(ring, gate)
  if not wx then return nil end
  local tx, ty = -ny, nx -- along the edge (perpendicular to the outward normal)
  local cx, cy = wx + nx * outDist, wy + ny * outDist
  local L = liftFn or flatLift
  return L(wx, wy), L(cx, cy), L(cx - tx * halfWidth, cy - ty * halfWidth), L(cx + tx * halfWidth, cy + ty * halfWidth)
end

-- Draw the widget (given lifted points from handleGeom): a stalk from the edge to the floated bar, the bar with end dots, and
-- the centre grab knob (pulsing when hovered). `base`/`glow` are packed colours.
local function drawHandle(gp, cp, e1, e2, base, glow, hovered)
  local sc = rSpheres.getSphereScale(cp:distance(core_camera.getPosition()))
  dbgDraw.drawLineInstance_MinArg(gp, cp, 2, glow) -- stalk from the edge out to the floated bar
  dbgDraw.drawLineInstance_MinArg(e1, e2, 4, base) -- the width bar itself
  dbgDraw.drawSphere(e1, sc * 0.09, base) -- small end dots convey the gate width
  dbgDraw.drawSphere(e2, sc * 0.09, base)
  local k = 1.0
  if hovered then k = 1.3 + 0.25 * (0.5 + 0.5 * sin(os.clock() * 8.0)) end
  dbgDraw.drawSphere(cp, sc * 0.22 * k, glow) -- centre grab knob
  dbgDraw.drawSphere(cp, sc * 0.12, base)
end


-- Public interface.
M.nearestGate = nearestGate
M.gateWorldDir = gateWorldDir
M.tagGates = tagGates
M.defaultGates = defaultGates
M.handleGeom = handleGeom
M.drawHandle = drawHandle

return M