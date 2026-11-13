-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Grade & corner-radius compliance heatmap for the Hero Road Editor.

local M = {}

-- Module dependencies.
local curveWiden = require('editor/toolUtilities/curveWiden')
local util = require('editor/toolUtilities/util')
local tris = require('editor/toolUtilities/render/tris')

-- Module constants.
local abs, sqrt, acos, pi = math.abs, math.sqrt, math.acos, math.pi
local heatLift = 0.10 -- lift the fill this far (m) above the deck so it clears the crown bulge/markings and never z-fights.
local classes = { -- Road classes to score against.
  highway  = { label = 'Highway',  minRadiusM = 200, maxGradePct = 6,  desc = 'Highway / freeway: long sweeping curves and gentle grades (~75 km/h+ geometry).' },
  rural    = { label = 'Rural',    minRadiusM = 90,  maxGradePct = 8,  desc = 'Rural / country road: medium flowing bends, hillier grades (~55 km/h geometry).' },
  urban    = { label = 'Urban',    minRadiusM = 40,  maxGradePct = 12, desc = 'Urban street: junction-scale corners, steeper street grades (~35 km/h geometry).' },
  mountain = { label = 'Mountain', minRadiusM = 15,  maxGradePct = 15, desc = 'Mountain pass: tight bends and steep climbs (~20 km/h geometry).' },
  rally    = { label = 'Rally',    minRadiusM = 8,   maxGradePct = 20, desc = 'Rally / off-road: hairpins and very steep, anything-goes terrain.' },
}
local classOrder = { 'highway', 'rural', 'urban', 'mountain', 'rally' } -- tightest standard (biggest radius / gentlest grade) -> weakest, left to right.
local defaultClassId = 'rural'

-- Scratch (module-scoped so the per-frame draw allocates nothing): outer-left / crown-centre / outer-right of two stations.
local eL1, eC1, eR1 = vec3(), vec3(), vec3()
local eL2, eC2, eR2 = vec3(), vec3(), vec3()

-- Per-station curvature / grade scratch, reused across frames (the compute runs every frame the overlay is on).
local curvBuf, gradeBuf, deflBuf = {}, {}, {}
-- Deflection-angle gate for the RADIUS score.
local deflGate0 = 1.0 * pi / 180.0 -- <= 1 deg: a tangent kink, no curve required -> no radius violation.
local deflGate1 = 5.0 * pi / 180.0 -- >= 5 deg: a genuine corner -> radius scored at full weight (linear ramp between).
local smoothHalfM = 4.0 -- Physical half-window (m) the curvature + grade are box-smoothed over BEFORE colouring.


-- Fills group.heatGrade[i] / group.heatRadius[i] (0 = compliant .. 1 = full violation).
local function compute(group)
  local div = group.divPoints
  local n = div and #div or 0
  local hg = group.heatGrade or {}; group.heatGrade = hg
  local hr = group.heatRadius or {}; group.heatRadius = hr
  table.clear(hg)
  table.clear(hr)
  if n < 3 then return end

  local cls = classes[group.roadClass] or classes[defaultClassId]
  local minR = cls.minRadiusM
  local maxG = cls.maxGradePct * 0.01 -- percent -> slope.

  -- Engineered mode carries the EXACT centreline curvature (incl. clothoids) in divCurv; spline mode has none, so fall back
  -- to a finite-difference estimate. Guard the length in case a stale array survived a mode switch.
  local exact = group.divCurv
  if exact and #exact ~= n then exact = nil end
  local s = curveWiden.arcLengths(div, n) -- 3D arc length so the grade is dz/ds along the real road, not per-station.

  -- Sample the raw per-station signals: signed curvature (exact clothoid where available, else finite-diff) and grade = central
  -- dz/ds (one-sided at the ends). Both are then smoothed below so the ramps read the SUSTAINED corner / grade, not one station.
  local kap, grade = curvBuf, gradeBuf
  for i = 1, n do
    kap[i] = exact and (exact[i] or 0.0) or curveWiden.signedCurvatureAt(div, i, n)
    local g
    if i == 1 then
      local ds = s[2] - s[1]; g = ds > 1e-6 and (div[2].z - div[1].z) / ds or 0.0
    elseif i == n then
      local ds = s[n] - s[n - 1]; g = ds > 1e-6 and (div[n].z - div[n - 1].z) / ds or 0.0
    else
      local ds = s[i + 1] - s[i - 1]; g = ds > 1e-6 and (div[i + 1].z - div[i - 1].z) / ds or 0.0
    end
    grade[i] = g
  end
  for i = n + 1, #kap do kap[i], grade[i] = nil, nil end -- drop leftovers from a longer previous road so # stays == n.

  -- Two arc-length box passes each (triangular kernel): keys the heat off sustained curvature / grade, so it eases in/out of a
  -- corner or crest instead of spiking at the spiral<->arc join, and finite-diff noise (spline mode) washes out.
  curveWiden.smoothByDistance(kap, s, n, smoothHalfM); curveWiden.smoothByDistance(kap, s, n, smoothHalfM)
  curveWiden.smoothByDistance(grade, s, n, smoothHalfM); curveWiden.smoothByDistance(grade, s, n, smoothHalfM)

  -- Per-station deflection weight (0..1): the "is this a real corner" gate described above. Each station takes the deflection of
  -- its nearest node (discMap maps node -> its centreline station; node stations increase along the road, so a single forward
  -- pointer finds the nearest). nil when we can't align the nodes to stations (e.g. a stale discMap) -> fall back to no gate.
  local defl = deflBuf
  local nodes, dm = group.nodes, group.discMap
  local nN = nodes and #nodes or 0
  local haveGate = dm and nN >= 3 and #dm == nN
  if haveGate then
    for k = 1, n do defl[k] = 0.0 end
    for k = n + 1, #defl do defl[k] = nil end
    local ni = 2 -- nearest interior node pointer (endpoints never turn).
    for k = 1, n do
      while ni < nN - 1 and abs((s[dm[ni + 1]] or s[k]) - s[k]) <= abs((s[dm[ni]] or s[k]) - s[k]) do ni = ni + 1 end
      local a, b, c = nodes[ni - 1], nodes[ni], nodes[ni + 1]
      local w = 0.0
      if a and b and c then
        local ax, ay, bx, by = b.x - a.x, b.y - a.y, c.x - b.x, c.y - b.y
        local la, lb = sqrt(ax * ax + ay * ay), sqrt(bx * bx + by * by)
        if la > 1e-6 and lb > 1e-6 then
          local d = (ax * bx + ay * by) / (la * lb)
          if d > 1 then d = 1 elseif d < -1 then d = -1 end
          local ang = acos(d) -- unsigned deflection = the arc's central angle.
          if ang >= deflGate1 then w = 1.0
          elseif ang > deflGate0 then local t = (ang - deflGate0) / (deflGate1 - deflGate0); w = t * t * (3.0 - 2.0 * t) end
        end
      end
      defl[k] = w
    end
  end

  for i = 1, n do
    -- Corner radius. Mirror homologation's radius ramp: full-width blue at/above 2*minR, ramps 0->1 across 2*minR..minR,
    -- solid red below minR (the class's tightest acceptable corner).
    local ak = abs(kap[i])
    local rn = 0.0
    if ak > 1e-9 then
      local R = 1.0 / ak
      if R < minR then rn = 1.0
      elseif R < 2.0 * minR then rn = 1.0 - (R - minR) / minR end
    end
    if haveGate then rn = rn * defl[i] end -- near-straight kinks (sub-degree deflection) are not min-radius violations.
    hr[i] = rn

    -- Grade. 0 until the class limit, ramping to red by 2x the limit.
    local gn = 0.0
    if maxG > 1e-9 then
      gn = (abs(grade[i]) - maxG) / maxG
      if gn < 0.0 then gn = 0.0 elseif gn > 1.0 then gn = 1.0 end
    end
    hg[i] = gn
  end
end

-- Returns the drawn violation value at station i for the selected metric ('grade' or 'radius').
local function metricAt(hg, hr, metric, i)
  if metric == 'radius' then return hr[i] or 0.0 end
  return hg[i] or 0.0
end

-- Writes one station's three overlay points (outer-left, crown-centre, outer-right) into L/C/R. Centre = divPoints (the
-- crown TOP, the highest point of the section); edges = centre +- the BANKED right axis (group.divBankR, the same tilted
-- axis the mesh sweeps its edges along) * carriageway half-width. Because the edges follow superelevation, a banked corner
-- can't rise above the ribbon and eat it; and because the crown top is a shared vertex, the camber can't poke through the
-- middle either. Falls back to the flat horizontal lateral (binormals) if the banked axis isn't built yet.
local function stationTri(group, i, L, C, R)
  local c = group.divPoints[i]
  local half = (group.divWidths[i] or 0.0) * 0.5
  local ax, ay, az
  local r3 = group.divBankR and group.divBankR[i]
  if r3 then ax, ay, az = r3.x, r3.y, r3.z else local b = group.binormals[i]; ax, ay, az = b.x, b.y, b.z end
  C:set(c.x, c.y, c.z + heatLift)
  L:set(c.x - ax * half, c.y - ay * half, c.z - az * half + heatLift)
  R:set(c.x + ax * half, c.y + ay * half, c.z + az * half + heatLift)
end

-- Draws the filled violation ribbon for the selected road only (matches Master Spline; bounds cost). Two half-panels per
-- segment (outer-left -> crown, crown -> outer-right) so it hugs the cambered/banked deck. Colour per near station via
-- Master Spline's blue->red ramp; both windings so it reads from any angle. `metric` is 'grade' or 'radius'.
local function draw(group, metric)
  local div = group.divPoints
  local n = div and #div or 0
  if n < 2 then return end
  local hg, hr = group.heatGrade, group.heatRadius
  if not (hg and hr and group.divWidths and group.binormals) then return end

  stationTri(group, 1, eL1, eC1, eR1)
  for i = 1, n - 1 do
    stationTri(group, i + 1, eL2, eC2, eR2)
    local t = metricAt(hg, hr, metric, i)
    local r, g, b = util.getHueBasedColour255(t)
    local col = color(r, g, b, 210)
    tris.drawTriCulled(eL1, eC1, eL2, col); tris.drawTriCulled(eC1, eC2, eL2, col) -- left panel (front + back winding).
    tris.drawTriCulled(eL2, eC1, eL1, col); tris.drawTriCulled(eL2, eC2, eC1, col)
    tris.drawTriCulled(eC1, eR1, eC2, col); tris.drawTriCulled(eR1, eR2, eC2, col) -- right panel.
    tris.drawTriCulled(eC2, eR1, eC1, col); tris.drawTriCulled(eC2, eR2, eR1, col)
    eL1:set(eL2); eC1:set(eC2); eR1:set(eR2) -- this station becomes the previous one for the next segment.
  end
end


-- Public interface.
M.classes = classes
M.classOrder = classOrder

M.compute = compute
M.draw = draw

return M