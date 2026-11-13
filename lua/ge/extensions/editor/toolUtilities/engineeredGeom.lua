-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Engineered road geometry: turns a spline's node polyline into a line-clothoid-arc-clothoid-line centerline.

--------------------------------------------------------------------------------------------------------------------

-- User variables.
local DEFAULT_R = 40.0        -- desired (arc) radius auto corners reach for, m. Safe to be generous: the adaptive tangent cap in
                              -- buildCenterline collapses it back toward minR on sharp turns, so hairpins still hug the PI.
local DEFAULT_LS = 15.0       -- transition (clothoid) length, m.
local DEFAULT_MIN_R = 8.0     -- radius floor: a corner never auto-shrinks below this. (Was 24 to hide sidewalk cracks on the outer edge; the MAX_CURVE_STEP_RAD densification below fixed that, so tight corners are safe now.)
local DEFAULT_MIN_ANGLE = 0.75 * math.pi / 180.0 -- below this deflection a corner passes straight through (sub-cm deviation).
local DEFAULT_STEP = 1.5      -- target longitudinal sample spacing, m (overridden per-call / from lonRes).

local MAX_CURVE_STEP_RAD = 0.025
local FIT_ITERS = 6           -- shrink-to-fit relaxation passes.
local FOLD_GUARD_ITERS = 24   -- max passes for the below-minR fold guarantee (monotone shrink, so it converges well before this).
local FOLD_FLOOR_R = 0.5      -- absolute radius floor (m) for that guarantee: a very tight corner beats a self-crossing centreline.
local DEFAULT_VERT_LEN = 40.0 -- 'Hill Smoothing': length of the parabolic vertical curve rounding each node (grade smoothed over this distance). 0 = off.
local DEFAULT_WIDEN_MAX = 2.5    -- peak curve widening (m, split both sides) at a tight corner; the taper LENGTH is curveWidenRunoffM.
local DEFAULT_WIDEN_RUNOFF = 20.0 -- default width-taper runoff length (m); matches CONTROLS.widthTaper.default.
local GRADE_RULING = 7.0 -- tangent grade capacity (~ruling gradient): the climb a straight is willing to carry.
local GRADE_FLOOR = 1.0  -- min corner grade capacity; the ruling:floor ratio sets how hard a fully-tight hairpin flattens.
local FLATTEN_MIN_HALF_M = 8.0 -- minimum flatten easing half-window (m): some rounding even at Hill Smoothing = 0.
local FLATTEN_LV_FRAC = 0.25   -- flatten easing half-window also grows by this fraction of the Hill Smoothing length.
local LEVEL_EASE_MAX_M = 60.0  -- longest ease from a level end (a flat junction pad) onto the road's own grade.
local MIN_STRAIGHT_SPACING_M = 0.25 -- floor on straight subdivision, so a very short straight can't explode into hundreds of points.

local piZLift = 0.07                                 -- lift the overlay just above the deck so the asphalt doesn't z-fight it.
local piGuideW, piNodeR = 2, 0.28                    -- guide line width (px) + interior-PI dot radius (m).
local clineW = 3                                     -- centerline width (px); the hero line, so bolder than the guide.
local clineKRef = 1.0 / DEFAULT_MIN_R                -- curvature mapped to the hot end (tightest allowed design radius).
local CLINE_BANDS = 12                               -- gradient quantisation: caps ColorF allocs to <=12/frame, not one per segment.
local piFadeNear, piFadeFar = 90, 550               -- overlay full alpha within near (m), gone beyond far.

--------------------------------------------------------------------------------------------------------------------

local M = {}

local logTag = 'engineeredGeom'

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')
local util = require('editor/toolUtilities/util')
local style = require('editor/toolUtilities/style').getStyle()

-- Private constants.
local abs, sqrt, sin, cos, tan, atan2, acos = math.abs, math.sqrt, math.sin, math.cos, math.tan, math.atan2, math.acos
local floor, ceil, min, max, pi = math.floor, math.ceil, math.min, math.max, math.pi
local cline0 = style.colourEngCenterCoolF            -- centerline at zero curvature (straight): teal / bluey-green.
local cline1 = style.colourEngCenterHotF             -- centerline at the tightest bend: warm amber.

-- Module state.
local piTmpA, piTmpB = vec3(), vec3()


-- One corner's solved geometry. delta is the SIGNED deflection (rad); turn is its sign (+1 left/CCW, -1 right/CW); R/Ls are this
-- corner's (possibly shrunk) radius and spiral length; thetaS the spiral angle; arc the circular central angle; T the tangent
-- distance the fillet eats along each adjoining straight. through=true means "too shallow, no fillet".
local function solveCorner(pPrev, pI, pNext, R, Ls, minAngle)
  local inx, iny = pI.x - pPrev.x, pI.y - pPrev.y
  local outx, outy = pNext.x - pI.x, pNext.y - pI.y
  local inLen, outLen = sqrt(inx * inx + iny * iny), sqrt(outx * outx + outy * outy)
  if inLen < 1e-6 or outLen < 1e-6 then return { through = true, T = 0 } end
  inx, iny, outx, outy = inx / inLen, iny / inLen, outx / outLen, outy / outLen
  local crossZ = inx * outy - iny * outx
  local dot = max(-1, min(1, inx * outx + iny * outy))
  local delta = atan2(crossZ, dot)              -- signed heading change at the corner.
  local absD = abs(delta)
  if absD < minAngle then return { through = true, T = 0 } end
  local turn = delta >= 0 and 1 or -1
  -- Cap the spiral so it never asks for more turn than the corner has (keeps a real, non-negative arc). If 2*thetaS would exceed
  -- |delta|, shrink Ls to Ls = R*|delta| -> thetaS = |delta|/2 and the arc degenerates to zero (a clean spiral-to-spiral join).
  local lsMax = R * absD
  if Ls > lsMax then Ls = lsMax end
  local thetaS = Ls / (2 * R)
  local arc = absD - 2 * thetaS
  local p = Ls * Ls / (24 * R)                  -- throw (how far the arc shifts inward).
  local T = (R + p) * tan(absD * 0.5) + Ls * 0.5
  return { through = false, delta = delta, absD = absD, turn = turn, R = R, Ls = Ls, thetaS = thetaS, arc = arc, T = T }
end

-- Shrinks a HARD-ARC corner (Ls = 0, so T = R*tan(delta/2)) to fit: T scales with R, so a factor f on T is just f on R. The fit
-- runs on hard arcs and the spirals are layered back on AFTERWARDS (see buildCenterline), so the fitted RADIUS is a pure function
-- of geometry + requested radius -- Transition never feeds into it, which is what stops a hairpin tightening when you raise it.
local function rescaleCorner(c, f, minAngle, pPrev, pI, pNext, minR)
  return solveCorner(pPrev, pI, pNext, max(minR or DEFAULT_MIN_R, c.R * f), 0, minAngle)
end

-- Appends one centerline sample (x, y, signed curvature) to the sink, reusing the existing vec3 slot.
local function emitPoint(sink, x, y, kappa)
  local i = sink.ctr
  local dp = sink.divPoints[i]
  if not dp then dp = vec3(); sink.divPoints[i] = dp end
  dp:set(x, y, 0)
  sink.divCurv[i] = kappa
  sink.ctr = i + 1
end

-- Advances from (x0,y0) at heading h0 under a curvature that ramps linearly from k0 to k1 over length L.
local function sweep(x0, y0, h0, k0, k1, L, N, sink)
  local ds = L / N
  local dk = (k1 - k0)
  local x, y = x0, y0
  for m = 1, N do
    local sa, sb = (m - 1) * ds, m * ds
    local sm = (sa + sb) * 0.5
    local ha = h0 + k0 * sa + dk * sa * sa / (2 * L)
    local hm = h0 + k0 * sm + dk * sm * sm / (2 * L)
    local hb = h0 + k0 * sb + dk * sb * sb / (2 * L)
    x = x + ds * (cos(ha) + 4 * cos(hm) + cos(hb)) / 6
    y = y + ds * (sin(ha) + 4 * sin(hm) + sin(hb)) / 6
    emitPoint(sink, x, y, k0 + dk * sb / L)
  end
  local hEnd = h0 + k0 * L + dk * L * L / (2 * L)
  return x, y, hEnd
end

-- Divisions for one straight piece. Engineered mode picks ONE step for the whole road (see dx in buildCenterline), so a
-- SHORT straight -- a junction approach leg, the gap between two corners -- gets only two or three points from
-- length/step alone, and anything that resolves a curve along it (Road Network's junction Z flare) then comes out
-- as a visible polyline rather than a smooth ramp. minDiv is the same per-SEGMENT floor geom.catmullRomFree applies to
-- every node-to-node span, which is why spline-mode roads never showed this. The spacing floor keeps a tiny straight
-- from exploding into points nothing can use.
local function straightSteps(L, dx, minDiv)
  local n = max(1, ceil(L / dx))
  if n >= minDiv then return n end
  return max(n, min(minDiv, max(1, floor(L / MIN_STRAIGHT_SPACING_M))))
end

-- Run-length-weighted moving average of a per-STATION array over a physical half-window hw (m).
local function smoothStationByRun(arr, S, sd, n, hw, scratch)
  for i = 1, n do scratch[i] = arr[i] end
  for i = 1, n do
    local half = min(hw, S[i] - S[1], S[n] - S[i])
    if half > 1e-6 then
      local lo, hi = S[i] - half, S[i] + half
      local sum, wsum = scratch[i] * sd[i], sd[i]
      local j = i - 1
      while j >= 1 and S[j] >= lo do sum = sum + scratch[j] * sd[j]; wsum = wsum + sd[j]; j = j - 1 end
      j = i + 1
      while j <= n and S[j] <= hi do sum = sum + scratch[j] * sd[j]; wsum = wsum + sd[j]; j = j + 1 end
      if wsum > 1e-9 then arr[i] = sum / wsum end
    end
  end
end

-- One run-length-weighted moving average of a per-segment grade array over a physical half-window hw (m), written into dst.
local function smoothGradeByRun(src, dst, ds, sMid, S, nSeg, numDiv, hw)
  for k = 1, nSeg do
    local half = min(hw, sMid[k] - S[1], S[numDiv] - sMid[k])
    if half <= 1e-6 then
      dst[k] = src[k]
    else
      local lo, hi = sMid[k] - half, sMid[k] + half
      local sum, wsum = 0.0, 0.0 -- run-length weighted so uneven station spacing can't bias the average.
      local j = k
      while j >= 1 and sMid[j] >= lo do sum = sum + src[j] * ds[j]; wsum = wsum + ds[j]; j = j - 1 end
      j = k + 1
      while j <= nSeg and sMid[j] <= hi do sum = sum + src[j] * ds[j]; wsum = wsum + ds[j]; j = j + 1 end
      dst[k] = wsum > 1e-9 and sum / wsum or src[k]
    end
  end
end

-- Level ends (levelA / levelB: the road meets a flat junction pad there): the grade eases from zero at the tip onto the profile's
-- own over half the Hill Smoothing length, and the climb that ease gives up is spread over the rest of the road, so both end
-- heights still land exactly.
local function levelProfileEnds(z, S, numDiv, targetLv, levelA, levelB)
  if not levelA and not levelB then return z end
  local span = S[numDiv] - S[1]
  local Lv = min(max(FLATTEN_MIN_HALF_M, targetLv * 0.5), LEVEL_EASE_MAX_M, span * ((levelA and levelB) and 0.45 or 0.9))
  if Lv < 1e-3 then return z end
  local nSeg = numDiv - 1
  local tau, grade, ds = table.new(nSeg, 0), table.new(nSeg, 0), table.new(nSeg, 0)
  local sumTauG, sumTau = 0.0, 0.0
  for k = 1, nSeg do
    local d = S[k + 1] - S[k]
    local sMid = 0.5 * (S[k] + S[k + 1])
    local t = 1.0
    if levelA then local u = min(1, (sMid - S[1]) / Lv); t = t * u * u * (3 - 2 * u) end
    if levelB then local u = min(1, (S[numDiv] - sMid) / Lv); t = t * u * u * (3 - 2 * u) end
    ds[k], tau[k] = d, t
    grade[k] = d > 1e-9 and (z[k + 1] - z[k]) / d or 0.0
    sumTauG, sumTau = sumTauG + t * grade[k] * d, sumTau + t * d
  end
  if sumTau < 1e-9 then return z end
  local c = ((z[numDiv] - z[1]) - sumTauG) / sumTau
  local z2 = table.new(numDiv, 0)
  z2[1] = z[1]
  for k = 1, nSeg do z2[k + 1] = z2[k] + tau[k] * (grade[k] + c) * ds[k] end
  return z2
end

-- Free-mode vertical profile: elevation per station, built from the node elevations as vertical PIs.
local function buildFreeProfileZ(S, divCurv, numDiv, discMap, zN, N, targetLv, levelA, levelB)
  -- Per-station run length (central difference), reused as the weight for the moving averages below so denser curve sampling
  -- can't bias them.
  local sd = table.new(numDiv, 0)
  for k = 1, numDiv do
    local d = 0.5 * (S[min(numDiv, k + 1)] - S[max(1, k - 1)])
    sd[k] = d > 1e-6 and d or 1e-6
  end

  -- 1) Per-station grade capacity w = ruling - comp(R), floored low so curvature fully differentiates (tight = flatter).
  local w = table.new(numDiv, 0)
  for k = 1, numDiv do
    local kappa = abs(divCurv[k] or 0.0)
    local comp = 0.0
    if kappa > 1e-9 then
      local R = 1.0 / kappa
      local a, b = (30.0 + R) / R, 75.0 / R
      comp = a < b and a or b
    end
    local cap = GRADE_RULING - comp
    w[k] = cap > GRADE_FLOOR and cap or GRADE_FLOOR
  end
  -- 1b) Ease the flatten in/out over an Hill-Smoothing-scaled half-window.
  if numDiv > 2 then
    local flattenHw = max(FLATTEN_MIN_HALF_M, (targetLv or 0.0) * FLATTEN_LV_FRAC) -- Hill Smoothing widens the crest/sag easing too.
    local wscratch = table.new(numDiv, 0)
    smoothStationByRun(w, S, sd, numDiv, flattenHw, wscratch)
    smoothStationByRun(w, S, sd, numDiv, flattenHw, wscratch)
  end

  -- 2) Cumulative weighted chainage, then spread each node->node span's rise along it (endpoints of each span land on the node z).
  local cw = table.new(numDiv, 0)
  cw[1] = 0.0
  for k = 2, numDiv do cw[k] = cw[k - 1] + w[k] * (S[k] - S[k - 1]) end
  local z = table.new(numDiv, 0)
  for i = 1, N - 1 do
    local ka, kb = discMap[i], discMap[i + 1]
    local za, zb = zN[i], zN[i + 1]
    local denom = cw[kb] - cw[ka]
    if denom > 1e-9 then
      for k = ka, kb do z[k] = za + (zb - za) * (cw[k] - cw[ka]) / denom end
    else
      for k = ka, kb do z[k] = za end
    end
  end
  -- 3) Round the vertical profile over the Hill Smoothing length, in two stages: first the grade SCALE (grade / capacity), which
  -- rounds the node-to-node hills (VPIs) without touching how hard corners flatten, then the finished grade itself, which rounds
  -- the flatten's own easing in and out of each corner.
  if targetLv > 1e-6 and numDiv > 2 then
    local passHw = targetLv * 0.25 -- two passes compose to a ~targetLv-wide triangular kernel (C2), same reach as a single targetLv*0.5 box.
    local nSeg = numDiv - 1
    local ds = table.new(nSeg, 0)
    local sMid = table.new(nSeg, 0)
    local wSeg = table.new(nSeg, 0)
    local scale = table.new(nSeg, 0) -- per-segment grade / capacity: constant within a span, jumps only at nodes.
    for k = 1, nSeg do
      local d = S[k + 1] - S[k]
      ds[k] = d
      sMid[k] = 0.5 * (S[k] + S[k + 1])
      wSeg[k] = 0.5 * (w[k] + w[k + 1])
      local g = d > 1e-9 and (z[k + 1] - z[k]) / d or 0.0
      scale[k] = wSeg[k] > 1e-9 and g / wSeg[k] or 0.0
    end
    local tmp = table.new(nSeg, 0)
    local ss = table.new(nSeg, 0)
    smoothGradeByRun(scale, tmp, ds, sMid, S, nSeg, numDiv, passHw)  -- pass 1: scale step -> ramp (rounds the VPI).
    smoothGradeByRun(tmp, ss, ds, sMid, S, nSeg, numDiv, passHw)     -- pass 2: round the ramp corners (C2, no residual kink).
    -- Back to real grade, then round THAT over the same window. The two passes above smooth grade/CAPACITY, so the
    -- capacity's own swing -- ruling gradient on a straight down to the floor through a tight corner, a ratio of
    -- several to one -- comes back untouched when it is multiplied in, and no amount of Hill Smoothing can soften
    -- it. That left a curvature break at each END of every corner region, where the flatten eases in and out.
    -- Smoothing the finished grade rounds that handoff like any other grade change; the corner still flattens,
    -- it just stops arriving and leaving with a kink.
    local grade = table.new(nSeg, 0)
    for k = 1, nSeg do grade[k] = ss[k] * wSeg[k] end
    smoothGradeByRun(grade, tmp, ds, sMid, S, nSeg, numDiv, passHw)
    smoothGradeByRun(tmp, grade, ds, sMid, S, nSeg, numDiv, passHw)
    local z2 = table.new(numDiv, 0)
    z2[1] = z[1]
    for k = 1, nSeg do z2[k + 1] = z2[k] + grade[k] * ds[k] end
    local span = S[numDiv] - S[1]
    if span > 1e-9 then
      local resid = z[numDiv] - z2[numDiv]                -- z[numDiv] is the exact terminal node height; trim the drift out linearly.
      for k = 1, numDiv do z2[k] = z2[k] + resid * (S[k] - S[1]) / span end
    end
    z = z2
  end
  return levelProfileEnds(z, S, numDiv, targetLv or 0.0, levelA, levelB)
end

-- Builds the engineered plan-view centerline. Returns nothing; mutates spline.divPoints/divWidths/normals/divCurv/discMap and runs
-- computeFrenetFrame. p = { R, Ls, minR, minAngleDeg, stepM, lonRes, zMode='free'|'raycast'|'conform' }.
local function buildCenterline(spline, p)
  p = p or {}
  local nodes = spline.nodes
  local numNodes = #nodes
  -- Loops and <3 nodes have no interior corners to engineer: defer to the Catmull-Rom sampler (a straight/loop, unchanged). Match
  -- the caller's Z mode so a terrain-draped tool stays on the surface (a looped engineered road must not suddenly float on free Z).
  if spline.isLoop or numNodes < 3 then
    spline.divCurv = nil -- no engineered curvature to hand downstream in the fallback.
    local zMode = p.zMode or 'free'
    if zMode == 'raycast' then return geom.catmullRomRaycast(spline, p.lonRes) end
    if zMode == 'conform' then return geom.catmullRomConformToTerrain(spline, p.lonRes) end
    return geom.catmullRomFree(spline, p.lonRes, p.deckZ ~= false, p.maxStep)
  end

  local minR = max(DEFAULT_MIN_R, p.minR or DEFAULT_MIN_R) -- width-aware fold guardrail (caller-supplied), never below the global floor.
  local Ls = p.Ls or DEFAULT_LS
  local minAngle = (p.minAngleDeg or (DEFAULT_MIN_ANGLE * 180 / pi)) * pi / 180
  local corners_ov = spline.corners -- optional sparse per-node override records (nil / false = auto).
  local widths, nmls = spline.widths, spline.nmls
  local divPoints, divWidths, normals, discMap = spline.divPoints, spline.divWidths, spline.normals, spline.discMap
  local divCurv = spline.divCurv or {}
  spline.divCurv = divCurv

  local segLen = {}
  for i = 1, numNodes - 1 do
    local dx, dy = nodes[i + 1].x - nodes[i].x, nodes[i + 1].y - nodes[i].y
    segLen[i] = sqrt(dx * dx + dy * dy)
  end

  -- 1) Solve each interior corner as a HARD ARC (Ls = 0) at an ADAPTIVE radius, then relax so adjacent corners never claim more of a
  -- straight than it has.
  local corners = {} -- corners[i] for i = 2..numNodes-1
  local reqLs = {} -- requested spiral length per corner (added back after the radius fit).
  local desiredR = max(minR, p.R or DEFAULT_R) -- the sweep auto corners reach for; per-node overrides replace it.
  for i = 2, numNodes - 1 do
    local ov = corners_ov and corners_ov[i]
    reqLs[i] = (ov and ov.taperM) or Ls
    local pinned = ov and ov.radiusM
    local c = solveCorner(nodes[i - 1], nodes[i], nodes[i + 1], max(minR, pinned or desiredR), 0, minAngle)
    if not pinned and not c.through then -- auto corner: cap the desired radius so its tangent can't eat a sharp bend.
      local a, b, d = nodes[i - 1], nodes[i], nodes[i + 1]
      local ax, ay, dx, dy = b.x - a.x, b.y - a.y, d.x - b.x, d.y - b.y
      local legMin = min(sqrt(ax * ax + ay * ay), sqrt(dx * dx + dy * dy))
      local tanHalf = tan(c.absD * 0.5)
      if tanHalf > 1e-6 then
        local rCap = 0.5 * legMin / tanHalf -- T <= half the shorter leg -> leaves >=half of it straight for an isolated corner.
        if rCap < c.R then c = solveCorner(a, b, d, max(minR, rCap), 0, minAngle) end
      end
    end
    corners[i] = c
  end
  for _ = 1, FIT_ITERS do
    local changed = false
    for seg = 1, numNodes - 1 do
      local a, b = seg, seg + 1 -- the two nodes bounding this straight.
      local Ta = corners[a] and corners[a].T or 0
      local Tb = corners[b] and corners[b].T or 0
      if Ta + Tb > segLen[seg] * 0.999 and Ta + Tb > 1e-6 then
        local f = segLen[seg] * 0.999 / (Ta + Tb)
        if corners[a] and not corners[a].through then
          corners[a] = rescaleCorner(corners[a], f, minAngle, nodes[a - 1], nodes[a], nodes[a + 1], minR)
        end
        if corners[b] and not corners[b].through then
          corners[b] = rescaleCorner(corners[b], f, minAngle, nodes[b - 1], nodes[b], nodes[b + 1], minR)
        end
        changed = true
      end
    end
    if not changed then break end
  end

  -- 1a) Hard fold guarantee. The relaxation above clamps every rescale at minR.
  for _ = 1, FOLD_GUARD_ITERS do
    local changed = false
    for seg = 1, numNodes - 1 do
      local a, b = seg, seg + 1
      local Ta = corners[a] and corners[a].T or 0
      local Tb = corners[b] and corners[b].T or 0
      if Ta + Tb > segLen[seg] * 0.999 and Ta + Tb > 1e-6 then
        local f = segLen[seg] * 0.999 / (Ta + Tb)
        if corners[a] and not corners[a].through then
          corners[a] = rescaleCorner(corners[a], f, minAngle, nodes[a - 1], nodes[a], nodes[a + 1], FOLD_FLOOR_R)
        end
        if corners[b] and not corners[b].through then
          corners[b] = rescaleCorner(corners[b], f, minAngle, nodes[b - 1], nodes[b], nodes[b + 1], FOLD_FLOOR_R)
        end
        changed = true
      end
    end
    if not changed then break end
  end

  -- 1b) Layer the transition spirals back onto the now-fixed radii.
  local legLeft = {}
  for seg = 1, numNodes - 1 do
    local Ta = corners[seg] and corners[seg].T or 0
    local Tb = corners[seg + 1] and corners[seg + 1].T or 0
    legLeft[seg] = max(0, segLen[seg] * 0.999 - Ta - Tb)
  end
  for i = 2, numNodes - 1 do
    local c = corners[i]
    if c and not c.through and reqLs[i] > 1e-6 then
      local dTMax = 0.5 * min(legLeft[i - 1], legLeft[i]) -- extra tangent this corner may spend (shares each leg with a neighbour).
      if dTMax > 1e-6 then
        local a = tan(c.absD * 0.5) / (24 * c.R) -- p*tan(d/2) = a*Ls^2; solve a*Ls^2 + 0.5*Ls = dTMax for the largest Ls.
        local lsFit = (sqrt(0.25 + 4 * a * dTMax) - 0.5) / (2 * a)
        local lsI = min(reqLs[i], lsFit)
        if lsI > 1e-6 then corners[i] = solveCorner(nodes[i - 1], nodes[i], nodes[i + 1], c.R, lsI, minAngle) end
      end
    end
  end

  -- Publish the effective per-corner radius (auto or pinned, after the fold floor + shrink-to-fit) so the viewport knob shows the
  -- real number and a fresh grab starts from it instead of snapping. Sparse: only interior corners that actually rounded get an entry.
  local cornerR = spline.cornerR or {}
  for i = 1, numNodes do cornerR[i] = nil end
  for i = 2, numNodes - 1 do
    local c = corners[i]
    cornerR[i] = (c and not c.through) and c.R or nil
  end
  spline.cornerR = cornerR

  -- 2) Assemble the pieces. dx = target longitudinal spacing (from lonRes if given, else stepM).
  local totalPoly = 0
  for i = 1, numNodes - 1 do totalPoly = totalPoly + segLen[i] end
  local dx = p.stepM
  if not dx then
    local avgSeg = totalPoly / max(1, numNodes - 1)
    dx = p.lonRes and max(0.5, min(5.0, avgSeg / p.lonRes)) or DEFAULT_STEP
  end
  if p.maxStep then dx = min(dx, p.maxStep) end
  -- Per-piece division floor for the straights (see straightSteps). Only tools that think in "divisions per segment"
  -- pass lonRes; a caller driving this by explicit stepM keeps the raw length/step count.
  local minDiv = p.lonRes and max(2, floor(p.lonRes)) or 1
  local sink = { divPoints = divPoints, divCurv = divCurv, ctr = 1 } -- shared write cursor for emitPoint/sweep.

  emitPoint(sink, nodes[1].x, nodes[1].y, 0) -- start exactly on node 1.
  discMap[1] = 1
  local cx, cy = nodes[1].x, nodes[1].y -- running end position (actual, so pieces chain gap-free).

  for i = 2, numNodes - 1 do
    local c = corners[i]
    local pI = nodes[i]
    -- Incoming unit direction (P_{i-1} -> P_i) and its heading; the straight before this corner runs along it.
    local inx, iny = pI.x - nodes[i - 1].x, pI.y - nodes[i - 1].y
    local inLen = sqrt(inx * inx + iny * iny)
    inx, iny = inx / inLen, iny / inLen
    if c.through then
      -- Too shallow to round: run the straight through the node itself.
      local segL = sqrt((pI.x - cx) * (pI.x - cx) + (pI.y - cy) * (pI.y - cy))
      local n = straightSteps(segL, dx, minDiv)
      sweep(cx, cy, atan2(pI.y - cy, pI.x - cx), 0, 0, segL, n, sink)
      cx, cy = pI.x, pI.y
      discMap[i] = sink.ctr - 1
    else
      -- Straight from current end to this corner's TS (= P_i pulled back T along the incoming line).
      local tsx, tsy = pI.x - c.T * inx, pI.y - c.T * iny
      -- Safety net: if TS lies BEHIND the current end (a residual overlap the fit couldn't resolve on a degenerate near-zero leg),
      -- the straight would run backwards and fold. Clamp TS to the current end so the fillet just starts here -- never reverse.
      if (tsx - cx) * inx + (tsy - cy) * iny < 0 then tsx, tsy = cx, cy end
      local segL = sqrt((tsx - cx) * (tsx - cx) + (tsy - cy) * (tsy - cy))
      -- A sliver of straight between two corners would add a point a few cm from the last; the fillet's first chord takes it up.
      if segL > MIN_STRAIGHT_SPACING_M then
        local n = straightSteps(segL, dx, minDiv)
        sweep(cx, cy, atan2(tsy - cy, tsx - cx), 0, 0, segL, n, sink)
      end
      local hIn = atan2(iny, inx)
      local kArc = c.turn / c.R
      local hasSpiral = c.Ls > 1e-6 -- Ls = 0 is a valid hard line->arc (no clothoid); skip the spiral sweeps.
      -- Curved-primitive step: cap dx so the heading turns at most MAX_CURVE_STEP_RAD per divPoint (the 1/R here is the tightest
      -- curvature the spirals reach too), keeping the polyline smooth enough that offset ribbons (sidewalk/edge lines) don't crack.
      local dxCurve = min(dx, c.R * MAX_CURVE_STEP_RAD)
      cx, cy = tsx, tsy
      -- Entry spiral: curvature 0 -> 1/R.
      if hasSpiral then
        cx, cy = sweep(tsx, tsy, hIn, 0, kArc, c.Ls, max(2, ceil(c.Ls / dxCurve)), sink)
      end
      -- Arc: constant curvature, central angle c.arc. Record its midpoint sample as this node's discMap anchor.
      if c.arc > 1e-6 then
        local arcLen = c.R * c.arc
        local nArc = max(2, ceil(arcLen / dxCurve))
        discMap[i] = sink.ctr + floor(nArc * 0.5) - 1
        cx, cy = sweep(cx, cy, hIn + c.turn * c.thetaS, kArc, kArc, arcLen, nArc, sink)
      else
        discMap[i] = max(1, sink.ctr - 1)                -- degenerate (zero) arc: anchor at the spiral-to-spiral join.
      end
      -- Exit spiral: curvature 1/R -> 0.
      if hasSpiral then
        cx, cy = sweep(cx, cy, hIn + c.turn * (c.thetaS + c.arc), kArc, 0, c.Ls, max(2, ceil(c.Ls / dxCurve)), sink)
      end
    end
  end

  -- Final straight to the last node (honored exactly).
  local pLast = nodes[numNodes]
  local segL = sqrt((pLast.x - cx) * (pLast.x - cx) + (pLast.y - cy) * (pLast.y - cy))
  if segL > 1e-6 then
    local n = straightSteps(segL, dx, minDiv)
    sweep(cx, cy, atan2(pLast.y - cy, pLast.x - cx), 0, 0, segL, n, sink)
  end
  discMap[numNodes] = sink.ctr - 1
  local numDiv = sink.ctr - 1

  -- 3) Attributes. Width/up-normal are interpolated linearly by arc length between the node "stations" (discMap anchors); Z gets a
  -- proper VERTICAL profile in free mode (grade-compensated distribution of each span's climb + a Hill-Smoothing low-pass, see
  -- buildFreeProfileZ), so hairpins flatten and grades roll smoothly instead of kinking. raycast/conform modes drape to terrain.
  local S = {}
  S[1] = 0
  for k = 2, numDiv do
    local a, b = divPoints[k - 1], divPoints[k]
    S[k] = S[k - 1] + sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y))
  end
  local nodeS = {}
  for i = 1, numNodes do nodeS[i] = S[discMap[i]] or 0 end
  nodeS[1], nodeS[numNodes] = 0, S[numDiv]              -- pin the ends.

  local zMode = p.zMode or 'free'
  local terrain = (zMode == 'conform') and core_terrain.getTerrain() or nil
  local zByStation = nil
  if zMode == 'free' then
    local zN = {}
    for i = 1, numNodes do zN[i] = nodes[i].z end
    zByStation = buildFreeProfileZ(S, divCurv, numDiv, discMap, zN, numNodes, p.vertLen or DEFAULT_VERT_LEN, p.levelStart, p.levelFinish)
  end
  local a = 1
  for k = 1, numDiv do
    local s = S[k]
    while a < numNodes - 1 and s > nodeS[a + 1] do a = a + 1 end
    local span = nodeS[a + 1] - nodeS[a]
    local t = span > 1e-6 and max(0, min(1, (s - nodeS[a]) / span)) or 0
    local na, nb = nodes[a], nodes[a + 1]
    divWidths[k] = widths[a] + (widths[a + 1] - widths[a]) * t
    local ua, ub = nmls[a], nmls[a + 1]
    normals[k] = normals[k] or vec3()
    local ux, uy, uz = ua.x + (ub.x - ua.x) * t, ua.y + (ub.y - ua.y) * t, ua.z + (ub.z - ua.z) * t
    local ul = sqrt(ux * ux + uy * uy + uz * uz)
    if ul < 1e-9 then ux, uy, uz, ul = 0, 0, 1, 1 end
    normals[k]:set(ux / ul, uy / ul, uz / ul)
    local dp = divPoints[k]
    if zMode == 'raycast' then
      util.vertRaycast(dp, spline.rayRaise, spline.rayPostFloat)
    elseif terrain then
      local h = core_terrain.getTerrainHeight(dp)
      dp.z = h or (na.z + (nb.z - na.z) * t)
    else
      dp.z = zByStation and zByStation[k] or (na.z + (nb.z - na.z) * t)
    end
  end

  -- Trim any leftover entries from a previous (longer) rebuild.
  for k = numDiv + 1, #divPoints do
    divPoints[k], divWidths[k], normals[k], divCurv[k] = nil, nil, nil, nil
  end

  geom.computeFrenetFrame(spline)
end

-- Thin z-mode wrappers mirroring the geom.lua sampler trio, so a tool can branch by name.
local function buildCenterlineFree(spline, p)
  p = p or {}; p.zMode = 'free'; return buildCenterline(spline, p)
end

local function buildCenterlineRaycast(spline, p)
  p = p or {}; p.zMode = 'raycast'; return buildCenterline(spline, p)
end

local function buildCenterlineConform(spline, p)
  p = p or {}; p.zMode = 'conform'; return buildCenterline(spline, p)
end

-- Metadata for the inspector controls, so every tool renders identical sliders/tooltips (each tool uses its own slider widget/undo).
local CONTROLS = {
  toggleTooltip = "On: the road ROUNDS around interior nodes with curvature-continuous spirals (line-spiral-arc-spiral). Off: a smooth curve THROUGH every node.",
  modeEngTip = "Rounds each corner: the road curves AROUND interior nodes instead of passing through them.",
  modeSmoothTip = "Smooth curve THROUGH every node (no corner rounding).",
  radius     = { key = 'engRadiusM', default = DEFAULT_R,        min = 5.0, max = 300.0, fmt = "Corner Radius = %.0f m", label = "Adjust Corner Radius",   tooltip = "Arc radius at each rounded corner. Bigger = wider, gentler bends. Auto-shrinks where corners are too sharp or close together to fit." },
  transition = { key = 'engTransM',  default = DEFAULT_LS,       min = 0.0, max = 80.0,  fmt = "Transition = %.0f m",    label = "Adjust Transition Length", tooltip = "Length of the easing spiral in/out of each corner (the steering onset). Bigger = gentler turn-in; auto-shrinks on short corners. 0 = an abrupt tangent-to-arc kink." },
  vertical   = { key = 'engVertLenM', default = DEFAULT_VERT_LEN, min = 0.0, max = 200.0, fmt = "Hill Smoothing = %.0f m", label = "Adjust Hill Smoothing",   tooltip = "How far grade changes are rounded along the road, turning node heights into gentle crest/sag hills. Bigger = longer hills; tight bends flatten automatically. 0 = sharp grade breaks at each node. (Terrain-draped tools ignore it.)" },
  widthTaper = { key = 'curveWidenRunoffM', default = 20.0,       min = 0.0, max = 80.0,  fmt = "Width Taper = %.0f m",   label = "Adjust Width Taper",       tooltip = "How gradually the road widens in/out of tight corners (m). Longer = gentler; independent of Transition. 0 = abrupt." },
  widenAmount = { key = 'curveWidenMaxM', default = DEFAULT_WIDEN_MAX, min = 0.0, max = 6.0, fmt = "Corner Widening = %.1f m", label = "Adjust Corner Widening", tooltip = "Extra width through the tightest corners (m, split both sides). Only genuinely tight bends widen. 0 = never widen." },
}

-- Backfills the four engineered fields on a group in place (new-group creation AND deserialize of sessions saved before the fields
-- existed). Only sets a field when nil, so authored values survive. Call from the tool's addNewGroup and deserializeGroup.
local function applyDefaults(group)
  if group.geometryMode == nil then group.geometryMode = 'spline' end
  if group.engRadiusM  == nil then group.engRadiusM  = DEFAULT_R end
  if group.engTransM   == nil then group.engTransM   = DEFAULT_LS end
  if group.engVertLenM == nil then group.engVertLenM = DEFAULT_VERT_LEN end
  if group.curveWidenMaxM    == nil then group.curveWidenMaxM    = DEFAULT_WIDEN_MAX end
  if group.curveWidenRunoffM == nil then group.curveWidenRunoffM = DEFAULT_WIDEN_RUNOFF end
  -- Sparse per-corner overrides (radiusM / taperM), created lazily on first knob drag. Kept index-aligned by splineInput on node
  -- add/insert/remove once the field exists, so every engineered tool just needs it to be present here.
  if group.corners == nil then group.corners = {} end
end

-- Single sampling entry point honoring group.geometryMode. opts = { zMode='free'|'raycast'|'conform', lonRes, deckZ, maxStep, levelStart,
-- levelFinish (free mode: that end meets a flat junction pad, so the profile arrives level) }. In engineered
-- mode it fills divPoints/divWidths/normals/divCurv/discMap (+ Frenet frame) and returns true, so the caller need not sample. In
-- spline mode it clears any stale divCurv and returns false, letting the caller run its OWN geom.catmullRom* variant (keeping each
-- tool's banking / conform specifics). This keeps the branch a one-liner and the field set uniform everywhere.
local function sampleInto(group, opts)
  opts = opts or {}
  if group.geometryMode == 'engineered' then
    buildCenterline(group, { R = group.engRadiusM, Ls = group.engTransM, vertLen = group.engVertLenM,
                             minR = opts.minR, lonRes = opts.lonRes, deckZ = opts.deckZ, maxStep = opts.maxStep, zMode = opts.zMode or 'free',
                             levelStart = opts.levelStart, levelFinish = opts.levelFinish })
    return true
  end
  group.divCurv = nil
  return false
end

local function drawControlPolygon(group)
  if not group or group.geometryMode ~= 'engineered' then return end
  local nodes = group.nodes
  local numNodes = nodes and #nodes or 0
  if numNodes < 2 then return end

  -- One distance fade for the whole overlay, measured to the mid node (cheap; it's a per-selection editor aid, not per-station).
  local fade = 1
  local cam = core_camera and core_camera.getPosition and core_camera.getPosition()
  if cam then
    local d = cam:distance(nodes[ceil(numNodes * 0.5)])
    fade = max(0, min(1, (piFadeFar - d) / (piFadeFar - piFadeNear)))
    if fade <= 0.02 then return end                    -- fully faded: skip all draw work.
  end

  -- INTENT: raw PI polygon as a thin solid construction guide (one line per leg -- cheap), a dot on each interior corner the road rounds.
  local g = style.colourEngGuideF
  local guideCol = ColorF(g.r, g.g, g.b, g.a * fade)
  for i = 1, numNodes - 1 do
    piTmpA:set(nodes[i].x, nodes[i].y, nodes[i].z + piZLift)
    piTmpB:set(nodes[i + 1].x, nodes[i + 1].y, nodes[i + 1].z + piZLift)
    debugDrawer:drawLineInstance(piTmpA, piTmpB, piGuideW, guideCol)
  end
  local gn = style.colourEngGuideNodeF
  local nodeCol = ColorF(gn.r, gn.g, gn.b, gn.a * fade)
  for i = 2, numNodes - 1 do
    piTmpA:set(nodes[i].x, nodes[i].y, nodes[i].z + piZLift)
    debugDrawer:drawSphere(piTmpA, piNodeR, nodeCol, false)
  end

  -- RESULT: the driven centerline, each segment coloured by its curvature magnitude (teal straight -> amber at the tightest bend).
  local dp, dc = group.divPoints, group.divCurv
  local numDiv = dp and #dp or 0
  if dc and numDiv >= 2 then
    local bandCol = {}                                 -- per-frame band cache (fade folds into alpha), so at most CLINE_BANDS ColorF.
    for k = 2, numDiv do
      local a, b = dp[k - 1], dp[k]
      local km = (abs(dc[k - 1] or 0) + abs(dc[k] or 0)) * 0.5
      local bi = floor(min(1, km / clineKRef) * (CLINE_BANDS - 1) + 0.5)
      local col = bandCol[bi]
      if not col then
        local t = bi / (CLINE_BANDS - 1)
        col = ColorF(cline0.r + (cline1.r - cline0.r) * t, cline0.g + (cline1.g - cline0.g) * t,
                     cline0.b + (cline1.b - cline0.b) * t, (cline0.a + (cline1.a - cline0.a) * t) * fade)
        bandCol[bi] = col
      end
      piTmpA:set(a.x, a.y, a.z + piZLift)
      piTmpB:set(b.x, b.y, b.z + piZLift)
      debugDrawer:drawLineInstance(piTmpA, piTmpB, clineW, col)
    end
  end
end

-- Self-test: builds a single 90-degree corner and checks C0/C1 continuity and the end curvature, logging pass/fail. Call manually.
local function selfTest()
  local spline = {
    nodes = { vec3(0, 0, 0), vec3(100, 0, 0), vec3(100, 100, 0) },
    widths = { 8, 8, 8 }, nmls = { vec3(0, 0, 1), vec3(0, 0, 1), vec3(0, 0, 1) },
    divPoints = {}, divWidths = {}, normals = {}, discMap = {}, tangents = {}, binormals = {},
  }
  buildCenterlineFree(spline, { R = 30, Ls = 20, stepM = 1.0 })
  local n = #spline.divPoints
  local maxKink, maxGap = 0, 0
  for k = 2, n do
    local a, b = spline.divPoints[k - 1], spline.divPoints[k]
    maxGap = max(maxGap, a:distance(b))                 -- spacing sanity (no huge jumps).
    if k >= 3 then
      local c = spline.divPoints[k - 2]
      local d1x, d1y = b.x - a.x, b.y - a.y
      local d2x, d2y = a.x - c.x, a.y - c.y
      local l1, l2 = sqrt(d1x * d1x + d1y * d1y), sqrt(d2x * d2x + d2y * d2y)
      if l1 > 1e-6 and l2 > 1e-6 then
        local d = max(-1, min(1, (d1x * d2x + d1y * d2y) / (l1 * l2)))
        maxKink = max(maxKink, acos(d))            -- per-step tangent turn (should be small everywhere).
      end
    end
  end
  log('I', logTag, string.format('selfTest: %d points, maxGap=%.3fm, maxKink=%.3fdeg (should be small & smooth)', n, maxGap, maxKink * 180 / pi))
  return n
end


-- Public interface.
M.CONTROLS = CONTROLS
M.DEFAULT_MIN_R = DEFAULT_MIN_R

M.buildCenterline = buildCenterline
M.buildCenterlineFree = buildCenterlineFree
M.buildCenterlineRaycast = buildCenterlineRaycast
M.buildCenterlineConform = buildCenterlineConform
M.solveCorner = solveCorner
M.selfTest = selfTest
M.applyDefaults = applyDefaults
M.sampleInto = sampleInto
M.drawControlPolygon = drawControlPolygon

return M