-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared curve-widening for engineered roads.

local M = {}

-- Module constants.
local sqrt, acos, abs, min, max = math.sqrt, math.acos, math.abs, math.min, math.max
local curveWidenMaxM = 2.5    -- max total widening (m, split both sides) at/below the full-widening radius.
-- Widening onset/full radii are fractions of the LINK'S OWN design radius (engRadiusM), not absolutes. They used to be a flat
-- 12 m onset / 8 m full, which no road ever reached: engineeredGeom designs auto corners at engRadiusM and the TN templates set
-- that from 22 m (urban street) to 110 m (motorway), so every corner sat far above a 12 m onset and the widening evaluated to
-- exactly zero no matter where the Corner Widening slider was. Keying off the design radius makes it mean what it should --
-- "this corner is tighter than the road was laid out for, so give it extra width" -- and it scales with road class instead of
-- only ever firing on a hairpin.
local curveWidenStartFrac = 1.0  -- no widening while a corner is at or above the design radius.
local curveWidenFullFrac = 0.35  -- full widening at/below this fraction of it.
local curveWidenFloorR = 6.0     -- absolute floor for the full-widening radius, so a tight-by-design street still has a ramp.
local defaultDesignR = 40.0      -- fallback when a group carries no engRadiusM (matches engineeredGeom's DEFAULT_R).
local defaultWidenRunoffM = 20.0 -- default taper length (m) the widening eases in/out over. Decoupled from Transition (per-group override curveWidenRunoffM), so a tight corner with no room for a spiral can still taper its width gently.
local offtrackLenM = 6.0         -- edgeWiden: design vehicle (rigid truck) wheelbase plus front overhang, whose offtracking a lane widens for.
local minLaneWidenM = 0.3        -- edgeWiden: per-lane widening under this is dropped, as real roads do.


-- Signed horizontal curvature at station i (0 at endpoints / degenerate). +ve = left turn, -ve = right turn.
local function signedCurvatureAt(div, i, n)
  if i <= 1 or i >= n then return 0.0 end
  local p0, p1, p2 = div[i - 1], div[i], div[i + 1]
  local ax, ay = p1.x - p0.x, p1.y - p0.y
  local bx, by = p2.x - p1.x, p2.y - p1.y
  local la, lb = sqrt(ax * ax + ay * ay), sqrt(bx * bx + by * by)
  if la < 1e-6 or lb < 1e-6 then return 0.0 end
  local d = (ax * bx + ay * by) / (la * lb)
  if d > 1 then d = 1 elseif d < -1 then d = -1 end
  local curv = acos(d) / (0.5 * (la + lb))
  if (ax * by - ay * bx) < 0 then curv = -curv end -- cross-product z sign: <0 = right turn.
  return curv
end

-- Cumulative arc-length along the divPoints (s[1] = 0). Used so runoff is a real distance, not a station count
-- (Catmull-Rom clusters stations at corners, so an index-space window physically collapses exactly at the node).
local function arcLengths(div, n)
  local s = { 0.0 }
  for i = 2, n do
    local dx, dy, dz = div[i].x - div[i - 1].x, div[i].y - div[i - 1].y, div[i].z - div[i - 1].z
    s[i] = s[i - 1] + sqrt(dx * dx + dy * dy + dz * dz)
  end
  return s
end

-- Box-smooths a signed array in place over a PHYSICAL half-window hw (meters), using the arc-length table s.
--
-- Each sample is weighted by the arc length it stands for, never counted. The window was already made physical so it
-- couldn't collapse at a node, but an unweighted mean over it is still whatever the DENSE side says: the engineered
-- sampler steps curves at R*MAX_CURVE_STEP_RAD (sub-metre, ~0.2 m round a hairpin) and straights at up to 5 m, so a
-- window straddling a tangent point holds tens of corner stations against one or two straight ones and hands the
-- corner ~95% of the average. The runoff that is supposed to ease the width in over curveWidenRunoffM then collapses
-- into a step at the corner boundary -- a lateral kink where the straight meets the arc. Weighting by run length is
-- what engineeredGeom's grade smoothers already do for the same reason.
local function smoothByDistance(arr, s, n, hw)
  if n < 3 or hw <= 0 then return end
  local src, d = {}, {}
  for i = 1, n do
    src[i] = arr[i]
    d[i] = max(1e-6, (s[min(n, i + 1)] - s[max(1, i - 1)]) * 0.5)
  end
  for i = 1, n do
    local lo, hi = s[i] - hw, s[i] + hw
    local sum, wsum = src[i] * d[i], d[i]
    local j = i - 1
    while j >= 1 and s[j] >= lo do sum = sum + src[j] * d[j]; wsum = wsum + d[j]; j = j - 1 end
    j = i + 1
    while j <= n and s[j] <= hi do sum = sum + src[j] * d[j]; wsum = wsum + d[j]; j = j + 1 end
    arr[i] = sum / wsum
  end
end

-- Adds interpolated per-corner extra widening (interior-node overrides) onto the per-station widen array. Node overrides map
-- to stations via discMap (node -> its centreline station index), then interpolate by arc-length like the base width does.
local function addNodeWidening(widen, s, n, discMap, corners)
  local numNodes = discMap and #discMap or 0
  if numNodes < 2 or not corners then return end
  local nodeExtra, any = {}, false
  for i = 1, numNodes do
    local o = corners[i]
    local ex = (o and o.extraWidenM) or 0.0
    nodeExtra[i] = ex
    if abs(ex) > 1e-9 then any = true end
  end
  if not any then return end
  local a = 1
  for k = 1, n do
    local sk = s[k]
    while a < numNodes - 1 and sk > (s[discMap[a + 1]] or sk) do a = a + 1 end
    local sa = s[discMap[a]] or 0.0
    local sb = s[discMap[a + 1]] or sa
    local span = sb - sa
    local tt = span > 1e-6 and max(0.0, min(1.0, (sk - sa) / span)) or 0.0
    widen[k] = widen[k] + nodeExtra[a] + (nodeExtra[a + 1] - nodeExtra[a]) * tt
  end
end

-- Total auto widening (m, both sides) at signed curvature c: 0 above curveWidenStartR so GENTLE bends don't widen, ramping to
-- curveWidenMaxM at/below curveWidenFullR -- only genuinely tight corners widen. The taper LENGTH (how gradually it eases in/out)
-- is set separately by the runoff smoothing in stationWiden, decoupled from the geometric Transition.
local function curveWidenAmount(c, wmax, startR, fullR)
  if wmax <= 0.0 then return 0.0 end
  local ac = abs(c)
  if ac < 1e-6 then return 0.0 end
  local R = 1.0 / ac
  if R >= startR then return 0.0 end
  local f = (startR - R) / max(1e-6, startR - fullR)
  if f > 1.0 then f = 1.0 end
  -- Smoothstep the ramp so it has ZERO slope where it leaves 0 (onset) and where it reaches wmax (full): a plain linear ramp corners
  -- at both shoulders (a C0 slope break), and box-smoothing a corner still leaves a visible width kink. Smoothstep removes the corner
  -- at the source, so the taper eases in/out; it's monotone in f, so it can't overshoot the target width (what a Steffen fit buys us,
  -- but here we have a dense per-station signal, not sparse knots to interpolate).
  return wmax * f * f * (3.0 - 2.0 * f)
end

-- Per-station TOTAL curve widening (m, split both sides): the auto curvature widening plus any engineered per-corner extraWidenM,
-- arc-length smoothed. Zero on straights / when curveWidenMaxM = 0 with no corner overrides, and zero unless engineered mode.
local function stationWiden(group, div, s, n)
  -- Curve widening is an ENGINEERED-road feature: those corners have real design radii/clothoids, so widening is meaningful and
  -- the curvature is exact. Smooth (Catmull-Rom) roads are free-form with only a noisy finite-diff curvature, so they don't widen.
  local wmax = group.geometryMode == 'engineered' and max(0.0, group.curveWidenMaxM or curveWidenMaxM) or 0.0
  local widen = {}
  if wmax > 0.0 then
    local exactCurv = group.divCurv
    if not (exactCurv and #exactCurv == n) then exactCurv = nil end
    local hw = max(1.0, (group.curveWidenRunoffM or defaultWidenRunoffM) * 0.5)
    -- Key the widening off SUSTAINED curvature: smooth the raw (exact or finite-diff) curvature over the runoff BEFORE testing the
    -- onset. A gentle bend only touches tight curvature for a moment, so smoothing dilutes it back under the onset (no widening);
    -- it also kills the finite-diff spikes Catmull-Rom sampling throws at nodes. A real tight arc (hairpin) stays tight through the
    -- smoothing and still widens. So widening tracks "how tight is this corner, really", not a one-station reading.
    local curv = {}
    for i = 1, n do curv[i] = exactCurv and exactCurv[i] or signedCurvatureAt(div, i, n) end
    smoothByDistance(curv, s, n, hw)
    -- Thresholds off this link's design radius (see curveWidenStartFrac).
    local designR = max(curveWidenFloorR, group.engRadiusM or defaultDesignR)
    local startR = designR * curveWidenStartFrac
    local fullR = max(curveWidenFloorR, designR * curveWidenFullFrac)
    for i = 1, n do widen[i] = curveWidenAmount(curv[i], wmax, startR, fullR) end
    -- Two more passes over the widening itself -> a triangular kernel (C2 taper). The smoothstep in curveWidenAmount already kills the
    -- shoulder corners; these passes round the whole runoff so the width glides base->wmax->base with no slope break, even when a small
    -- Transition makes curvature step hard into the arc. Box averages never overshoot, so the target width is never exceeded.
    smoothByDistance(widen, s, n, hw)
    smoothByDistance(widen, s, n, hw)
  else
    for i = 1, n do widen[i] = 0.0 end
  end
  if group.geometryMode == 'engineered' then addNodeWidening(widen, s, n, group.discMap, group.corners) end
  return widen
end

-- Bakes the per-station curve widening into group.divWidths in place (call once per dirty pass, right after the base widths are
-- sampled). For tools whose mesh is built symmetrically from divWidths this widens the tarmac itself; heroRoad widens its mesh
-- carriageway separately and uses this only to move markings/ribbon out to the widened edge. No-op when nothing widens.
local function applyDivWidthWiden(group)
  local div = group.divPoints
  local dw = group.divWidths
  local n = div and #div or 0
  if n < 2 or not dw then return end
  local widen = stationWiden(group, div, arcLengths(div, n), n)
  local m = min(n, #dw)
  for i = 1, m do dw[i] = dw[i] + widen[i] end
end

-- Real-world corner widening (m) per station on each edge, travel-left and travel-right: every lane takes the design
-- vehicle's offtracking on the bend's sustained radius, R - sqrt(R^2 - L^2), dropped under minLaneWidenM, the whole capped
-- at the road's Corner Widening. It goes on the inside edge of the bend; a divided road widens each carriageway on its outer
-- edge, the median having no room for it. Engineered roads only (their curvature is exact).
local function edgeWiden(group, div, s, n, lanesL, lanesR, divided)
  local outL, outR = {}, {}
  for i = 1, n do outL[i], outR[i] = 0.0, 0.0 end
  local cap = group.geometryMode == 'engineered' and max(0.0, group.curveWidenMaxM or curveWidenMaxM) or 0.0
  if cap <= 0.0 or n < 3 then return outL, outR end
  local exactCurv = group.divCurv
  if not (exactCurv and #exactCurv == n) then exactCurv = nil end
  local hw = max(1.0, (group.curveWidenRunoffM or defaultWidenRunoffM) * 0.5)
  local curv = {}
  for i = 1, n do curv[i] = exactCurv and exactCurv[i] or signedCurvatureAt(div, i, n) end
  smoothByDistance(curv, s, n, hw)
  local extra = {}
  for i = 1, n do extra[i] = 0.0 end
  addNodeWidening(extra, s, n, group.discMap, group.corners)
  local L2 = offtrackLenM * offtrackLenM
  for i = 1, n do
    local c = curv[i]
    local w = 0.0
    if abs(c) > 1e-6 then
      local R = 1.0 / abs(c)
      w = (R * R > L2) and (R - sqrt(R * R - L2)) or offtrackLenM
      if w < minLaneWidenM then w = 0.0 end
    end
    if divided then
      outL[i] = min(cap, lanesL * w) + extra[i] * 0.5
      outR[i] = min(cap, lanesR * w) + extra[i] * 0.5
    elseif c > 0 then
      outL[i] = min(cap, (lanesL + lanesR) * w) + extra[i]
    else
      outR[i] = min(cap, (lanesL + lanesR) * w) + extra[i]
    end
  end
  smoothByDistance(outL, s, n, hw)
  smoothByDistance(outL, s, n, hw)
  smoothByDistance(outR, s, n, hw)
  smoothByDistance(outR, s, n, hw)
  return outL, outR
end


-- Public interface.
M.DEFAULT_MAX = curveWidenMaxM
M.DEFAULT_RUNOFF = defaultWidenRunoffM

M.stationWiden = stationWiden
M.applyDivWidthWiden = applyDivWidthWiden
M.edgeWiden = edgeWiden
M.signedCurvatureAt = signedCurvatureAt
M.arcLengths = arcLengths
M.smoothByDistance = smoothByDistance

return M