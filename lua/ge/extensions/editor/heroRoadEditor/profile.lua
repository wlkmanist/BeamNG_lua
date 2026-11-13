-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Cross-section profile for a Hero Road group. Turns the lane profile + crown/shoulder params into a per-station 2D
-- cross-section (lateral offset o, vertical dz relative to the centreline plane) plus a curvature-driven bank angle.

local M = {}

-- External modules.
local curveWiden = require('editor/toolUtilities/curveWiden')

-- Module constants.
local sqrt, acos, rad = math.sqrt, math.acos, math.rad
local abs, min, max, floor = math.abs, math.min, math.max, math.floor
local runoffHalfM = 18.0 -- Physical half-window (meters) for smoothing the bank/crown transition (the runoff length).
local foldSafety = 0.8 -- Inner offset is clamped to this fraction of the local turn radius (keeps the surface unfolded).
local pinchRampM = 8.0 -- Physical half-window (meters) over which a fold-cap pinch ramps in/out (keeps the taper smooth).
local defaultLatRes = 4 -- Default lateral subdivisions per side across the carriageway (higher = smoother crown).
local guardMarginM = 1.5 -- Smallest centreline radius (m) this group can round before the inner-edge fold cap starts biting.
local MAT_ROAD, MAT_SHOULDER = 'road', 'shoulder' -- Band material keys (resolved to real materials in mesh.lua).


-- Reads the resolved profile parameters from a group (with defaults).
local function params(group)
  local crownOn = group.crownOn ~= false
  return {
    leftExt = group.leftExtM or 5.0,
    rightExt = group.rightExtM or 5.0,
    crossfall = crownOn and ((group.crossfallPct or 2.5) * 0.01) or 0.0,
    shW = max(0.0, group.shoulderWidthM or 0.0),
    shoulderFall = (group.shoulderFallPct or 6.0) * 0.01,
    eMax = rad(group.superElevMaxDeg or 6.0),
    minRadius = max(1.0, group.superMinRadiusM or 80.0),
  }
end

-- The band-material layout (left -> right), one entry per cross-section SEGMENT (= #pts - 1). latRes carriageway
-- segments per side; the outermost segment on each side is the shoulder (when present).
local function bandLayout(hasShoulder, latRes)
  local bands = {}
  if hasShoulder then bands[#bands + 1] = MAT_SHOULDER end
  for _ = 1, latRes * 2 do bands[#bands + 1] = MAT_ROAD end
  if hasShoulder then bands[#bands + 1] = MAT_SHOULDER end
  return bands
end

-- Parabolic crown drop at lateral offset o over half-width ext (apex flat at the centre -> no central crease, smooth to
-- drive). Same edge drop as a linear crossfall (crossfall*ext) but rounded; cf fades the whole crown out into a corner.
local function crownDz(pr, o, ext, cf)
  if ext <= 1e-6 then return 0.0 end
  local x = o / ext
  return -pr.crossfall * ext * x * x * cf
end

-- Optional per-station peak-bank angle (rad) from per-corner superElevDeg overrides, interpolated via discMap like widening.
-- Returns nil when no corner overrides banking (the caller then uses the scalar group eMax -- no per-station array, no cost).
local function buildNodeSuperElev(group, s, n, eMax)
  local discMap, corners = group.discMap, group.corners
  local numNodes = discMap and #discMap or 0
  if numNodes < 2 or not corners then return nil end
  local nodeE, any = {}, false
  for i = 1, numNodes do
    local o = corners[i]
    if o and o.superElevDeg ~= nil then nodeE[i] = rad(o.superElevDeg); any = true
    else nodeE[i] = eMax end
  end
  if not any then return nil end
  local out, a = {}, 1
  for k = 1, n do
    local sk = s[k]
    while a < numNodes - 1 and sk > (s[discMap[a + 1]] or sk) do a = a + 1 end
    local sa = s[discMap[a]] or 0.0
    local sb = s[discMap[a + 1]] or sa
    local span = sb - sa
    local tt = span > 1e-6 and max(0.0, min(1.0, (sk - sa) / span)) or 0.0
    out[k] = nodeE[a] + (nodeE[a + 1] - nodeE[a]) * tt
  end
  return out
end

-- Carriageway height at |o| for a half-width whose CROWN spans [0, crownSpan]: normal crown within the crown span, then
-- FLAT at the crown-edge height beyond it (a placeable widening's bay/lane is level, meeting the carriageway flush). o may
-- be signed; crownDz reads |o| only so the sign is irrelevant.
local function deckDz(pr, o, crownSpan, cf)
  if crownSpan <= 1e-6 then return 0.0 end
  if abs(o) >= crownSpan then return crownDz(pr, crownSpan, crownSpan, cf) end -- flat bay beyond the crown edge.
  return crownDz(pr, o, crownSpan, cf)
end

-- Builds one cross-section (left -> right) of { o, dz } for crown factor cf in [0,1], with latRes lateral subdivisions
-- per side across the carriageway (so the crown is sampled smoothly). Shoulders are one extra segment beyond each edge.
-- Two independent per-side extras (both default 0, so an unwidened road is byte-identical to before):
--   crownExtL/R -- CURVE widening: stretches the crown out over the widened tarmac (camber carries across the widened lane).
--   flatExtL/R  -- PLACEABLE widening (layby/lane/bay): a FLAT band appended beyond the crown edge at the edge height.
-- The column COUNT is unchanged (shoulder + latRes*2 + shoulder); the outer columns just spread across the total half-width,
-- so every station has the same section shape and the sweep still stitches quad-for-quad (near-zero extra triangles).
local function crossSectionPts(pr, cf, latRes, crownExtL, crownExtR, flatExtL, flatExtR, shf)
  shf = shf or 1.0 -- shoulder-fall factor (1 = full fall; 0 flattens the shoulders, used by the flat-end taper).
  local crownL = pr.leftExt + (crownExtL or 0.0)   -- crown spans [0, crownL] on the left.
  local crownR = pr.rightExt + (crownExtR or 0.0)  -- crown spans [0, crownR] on the right.
  local totL = crownL + (flatExtL or 0.0)          -- full left half-width (crown + flat bay).
  local totR = crownR + (flatExtR or 0.0)          -- full right half-width.
  local edgeDzL = crownDz(pr, crownL, crownL, cf)  -- crown-edge height (the flat bay + shoulder hang off this).
  local edgeDzR = crownDz(pr, crownR, crownR, cf)
  local pts = {}
  if pr.shW > 1e-4 then -- left shoulder (drops from the widened left edge).
    pts[#pts + 1] = { o = -(totL + pr.shW), dz = edgeDzL - pr.shoulderFall * pr.shW * shf }
  end
  for k = latRes, 1, -1 do -- left carriageway: outer edge (-totL) -> centre.
    local o = -totL * (k / latRes)
    pts[#pts + 1] = { o = o, dz = deckDz(pr, o, crownL, cf) }
  end
  pts[#pts + 1] = { o = 0.0, dz = 0.0 } -- centre (crown apex).
  for k = 1, latRes do -- right carriageway: centre -> outer edge (+totR).
    local o = totR * (k / latRes)
    pts[#pts + 1] = { o = o, dz = deckDz(pr, o, crownR, cf) }
  end
  if pr.shW > 1e-4 then -- right shoulder (drops from the widened right edge).
    pts[#pts + 1] = { o = totR + pr.shW, dz = edgeDzR - pr.shoulderFall * pr.shW * shf }
  end
  return pts
end

-- Horizontal 'right' vector for a tangent (matches mesh.lua's frame): R = normalize(cross(T, worldUp)) = (ty,-tx,0).
local function rightXY(t)
  local rx, ry = t.y, -t.x
  local rl = sqrt(rx * rx + ry * ry)
  if rl > 1e-6 then return rx / rl, ry / rl end
  return 1.0, 0.0
end

-- Per-station EXACT fold caps (max inner offset on each side), derived straight from the discrete frame instead of a
-- curvature estimate. The inner edge folds/crumples exactly when consecutive inner-edge points stop advancing along the
-- road: (P[i+1]-P[i])·Tseg <= 0, with P = centre + o·R. For a segment i->i+1 that's |dC| + o·dot(R[i+1]-R[i], Tseg) <= 0,
-- so the binding side (where o·dRT < 0) can carry at most |o| = |dC|/|dRT| (the discrete turn radius). Capping to a
-- safe fraction of that keeps every inner column strictly forward-monotone -> no fold, for any tightness or incline.
local function frameCaps(div, tangents, n)
  local capL, capR = {}, {}
  local BIG = 1e9
  for i = 1, n do capL[i] = BIG; capR[i] = BIG end
  for i = 1, n - 1 do
    local a, b = div[i], div[i + 1]
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    local dCT = sqrt(dx * dx + dy * dy + dz * dz) -- forward step length along the chord.
    if dCT > 1e-6 then
      local tsx, tsy = dx / dCT, dy / dCT -- chord direction (horizontal part; R is horizontal so z is irrelevant here).
      local r0x, r0y = rightXY(tangents[i])
      local r1x, r1y = rightXY(tangents[i + 1])
      local dRT = (r1x - r0x) * tsx + (r1y - r0y) * tsy -- how fast R swings into the travel direction.
      if dRT > 1e-9 then -- R swings +; the -o (left) side is the inner one that would fold.
        local cap = dCT / dRT
        if cap < capL[i] then capL[i] = cap end
        if cap < capL[i + 1] then capL[i + 1] = cap end
      elseif dRT < -1e-9 then -- +o (right) side is inner.
        local cap = dCT / -dRT
        if cap < capR[i] then capR[i] = cap end
        if cap < capR[i + 1] then capR[i + 1] = cap end
      end
    end
  end
  return capL, capR
end

-- Per-station fold caps from the EXACT signed curvature (engineered mode). Same sign/frame convention as frameCaps: with
-- R = (t.y,-t.x) we have dR/ds = kappa*T, so the swing rate dRT/ds = kappa -- kappa>0 turns the frame so the LEFT (-o) side is
-- inner, kappa<0 the RIGHT (+o). The inner side can carry at most |o| = 1/|kappa| (the true turn radius) before folding; the
-- outer side is unbounded. Curvature is smooth by construction (0 on straights, linear through clothoids, 1/R on arcs), so this
-- has NONE of the discrete-frame spikes that erodeMin would otherwise smear into a broad false 'bite' out of the inner edge.
local function curvatureCaps(curv, n)
  local capL, capR = {}, {}
  local BIG = 1e9
  for i = 1, n do
    local k = curv[i] or 0.0
    local ak = abs(k)
    if ak > 1e-9 then
      local r = 1.0 / ak
      if k > 0.0 then capL[i] = r; capR[i] = BIG else capR[i] = r; capL[i] = BIG end
    else
      capL[i] = BIG; capR[i] = BIG
    end
  end
  return capL, capR
end

-- Windowed MIN (erosion) of a cap array over a PHYSICAL half-window hw (meters). Spreads each tight cap outward so the
-- pinch ramps in/out over a real distance instead of collapsing in one segment (the wide->pinch step is what crumples).
local function erodeMin(arr, s, n, hw)
  if n < 3 or hw <= 0 then return end
  local src = {}
  for i = 1, n do src[i] = arr[i] end
  for i = 1, n do
    local lo, hi = s[i] - hw, s[i] + hw
    local m = src[i]
    local j = i - 1
    while j >= 1 and s[j] >= lo do if src[j] < m then m = src[j] end; j = j - 1 end
    j = i + 1
    while j <= n and s[j] <= hi do if src[j] < m then m = src[j] end; j = j + 1 end
    arr[i] = m
  end
end

-- Fits a station's offsets inside the per-side fold caps. Snapping every over-cap inner column onto the SAME limit collapses
-- them into zero-width sliver quads (the visible "bite"); instead we uniformly squash the binding side so its outer edge sits
-- exactly at the cap and the inner columns stay evenly spaced -- a clean fan/pinch with no degenerate triangles, rectangular
-- grid preserved. A no-op unless a side actually exceeds its cap (the common case: caps are BIG, so both scale factors are 1).
local function applyCaps(pts, capL, capR)
  local limL, limR = capL * foldSafety, capR * foldSafety
  local extL, extR = 0.0, 0.0
  for j = 1, #pts do
    local o = pts[j].o
    if o < 0.0 then if -o > extL then extL = -o end
    elseif o > 0.0 then if o > extR then extR = o end end
  end
  local fL = (extL > limL and extL > 1e-6) and (limL / extL) or 1.0
  local fR = (extR > limR and extR > 1e-6) and (limR / extR) or 1.0
  if fL < 1.0 or fR < 1.0 then
    for j = 1, #pts do
      local o = pts[j].o
      if o < 0.0 then if fL < 1.0 then pts[j].o = o * fL end
      elseif o > 0.0 then if fR < 1.0 then pts[j].o = o * fR end end
    end
  end
end

-- Smoothstep on [0,1] (clamped): zero slope at both ends, so a taper eases in/out with no width kink (the same shape
-- OpenDRIVE's cubic width record and curveWiden's onset ramp use).
local function smoothstep01(x)
  if x <= 0.0 then return 0.0 elseif x >= 1.0 then return 1.0 end
  return x * x * (3.0 - 2.0 * x)
end

-- Per-station FLAT widening (m) for each side from group.widenings (laybys / overtaking lanes / stopping areas) AND from
-- group.junctions (bell-mouth flares).
local function buildPlaceableWiden(group, s, n)
  local widenings, junctions = group.widenings, group.junctions
  local nW = (widenings and #widenings) or 0
  local nJ = (junctions and #junctions) or 0
  if (nW + nJ) == 0 or n < 2 then return nil, nil end
  local total = s[n]
  if not total or total <= 1e-6 then return nil, nil end
  local wl, wr = nil, nil
  for k = 1, nW + nJ do
    local width, tin, bay, tout, t01, side
    if k <= nW then
      local it = widenings[k]
      width, tin, bay, tout, t01, side = it.widthM, it.taperInM, it.bayLenM, it.taperOutM, it.t, it.side
    else
      local it = junctions[k - nW] -- junction bell-mouth mapped onto the widening trapezoid (flare width, bevel tapers, throat bay).
      width, tin, bay, tout, t01, side = it.flareM, it.bevelM, it.lengthM, it.bevelM, it.t, it.side
    end
    width = max(0.0, width or 0.0)
    tin = max(0.0, tin or 0.0)
    bay = max(0.0, bay or 0.0)
    tout = max(0.0, tout or 0.0)
    local span = tin + bay + tout
    if width > 1e-6 and span > 1e-6 then
      local centre = min(max(t01 or 0.5, 0.0), 1.0) * total
      local a0 = centre - span * 0.5 -- start of entry taper.
      local a1 = a0 + tin            -- full width reached.
      local a2 = a1 + bay            -- full width ends.
      local a3 = a2 + tout           -- back to 0 (end of exit taper).
      local arr
      if side == 'left' then wl = wl or {}; arr = wl else wr = wr or {}; arr = wr end
      for i = 1, n do
        local si, f = s[i], 0.0
        if si > a0 and si < a3 then
          if si < a1 then f = tin > 1e-6 and smoothstep01((si - a0) / tin) or 1.0
          elseif si <= a2 then f = 1.0
          else f = tout > 1e-6 and smoothstep01((a3 - si) / tout) or 1.0 end
        end
        local v = f * width
        local cur = arr[i]
        if not cur or v > cur then arr[i] = v end
      end
    end
  end
  return wl, wr
end

-- Builds the per-station cross-sections + bank for the group.
-- Returns: stations (array over divPoints of { pts = {{o,dz}...}, bank = radians }), bandMat (material key per band).
local function build(group)
  local div, tangents = group.divPoints, group.tangents
  local n = div and #div or 0
  if n < 2 or not tangents then return nil, nil end

  local pr = params(group)
  local latRes = max(1, floor(group.latRes or defaultLatRes))
  local bandMat = bandLayout(pr.shW > 1e-4, latRes)

  local s = curveWiden.arcLengths(div, n)

  -- Normalized bank fraction t in [-1,1] from local curvature (capped at the min radius), then ARC-LENGTH runoff. Engineered mode
  -- carries an EXACT signed curvature per station (0 on straights, linear ramp through the spirals, constant 1/R on arcs), so bank
  -- develops along the clothoid the way real superelevation runoff does -- prefer it when it aligns with these live stations.
  local exactCurv = group.divCurv
  if not (exactCurv and #exactCurv == n) then exactCurv = nil end
  local t = {}
  for i = 1, n do
    local c = exactCurv and exactCurv[i] or curveWiden.signedCurvatureAt(div, i, n)
    local mag = min(1.0, abs(c) * pr.minRadius) -- |curv| = 1/minRadius reaches full bank.
    t[i] = c >= 0 and mag or -mag
  end
  curveWiden.smoothByDistance(t, s, n, runoffHalfM)
  local widen = curveWiden.stationWiden(group, div, s, n) -- carriageway widening added to leftExt/rightExt below (same array baked into divWidths, so markings track it).
  local eStation = nil -- per-station peak-bank override (engineered corners only); nil = use the scalar pr.eMax everywhere.
  if group.geometryMode == 'engineered' then
    eStation = buildNodeSuperElev(group, s, n, pr.eMax)
    if eStation then curveWiden.smoothByDistance(eStation, s, n, runoffHalfM) end
  end

  -- Per-side fold caps (max inner offset before the deck self-intersects), then erode over distance so the pinch ramps smoothly
  -- (no crumple). Engineered mode uses the EXACT curvature (spike-free) so the deck only pinches where the design truly turns
  -- tighter than the road is wide; freehand mode has no exact curvature, so fall back to the discrete-frame estimate.
  local capL, capR
  if exactCurv then capL, capR = curvatureCaps(exactCurv, n) else capL, capR = frameCaps(div, tangents, n) end
  erodeMin(capL, s, n, pinchRampM)
  erodeMin(capR, s, n, pinchRampM)

  -- Placeable widenings (laybys / overtaking lanes / stopping areas): a FLAT per-side band appended beyond the crown, distinct
  -- from the symmetric curve widening above (which stretches the crown). nil arrays when the road has none.
  local wFlatL, wFlatR = buildPlaceableWiden(group, s, n)

  -- Flat ends: ramp the whole cross-section (crown + shoulder-fall + bank) out to flat/horizontal over the last flatEndLenM at
  -- each open end, so the deck edge is a straight level line that drops cleanly into hand-shaped flat terrain (chamfers unchanged).
  -- ef in [0,1] is 0 at the very end and eases to 1 by flatEndLenM inward; a loop has no ends, and off leaves ef = 1 everywhere.
  local flatEnds = group.flatEnds == true and not group.isLoop
  local flatLen = max(0.0, group.flatEndLenM or 0.0)
  local doFlat = flatEnds and flatLen > 1e-6
  local total = s[n]

  local stations = {}
  for i = 1, n do
    local ti = t[i]
    local ef = 1.0
    if doFlat then ef = smoothstep01(min(s[i], total - s[i]) / flatLen) end -- taper by arc distance to the nearer end.
    local hw = widen[i] * 0.5 -- symmetric curve widening about the centreline (stretches the crown).
    local fL = wFlatL and wFlatL[i] or 0.0
    local fR = wFlatR and wFlatR[i] or 0.0
    local pts = crossSectionPts(pr, (1.0 - abs(ti)) * ef, latRes, hw, hw, fL, fR, ef) -- crown fades on curves (cf) AND at flat ends (ef); shoulders flatten with ef.
    applyCaps(pts, capL[i], capR[i])
    stations[i] = { pts = pts, bank = ti * (eStation and eStation[i] or pr.eMax) * ef }
  end

  return stations, bandMat
end

local function minSafeRadius(group)
  local pr = params(group)
  local wmax = max(0.0, group.curveWidenMaxM or curveWiden.DEFAULT_MAX)
  -- Side chamfers flare BEYOND the outer edge (mesh.lua defaultChamferWidthM); count them so the auto-radius floor keeps real
  -- headroom before the fold cap bites.
  local chamfer = group.sideChamfers ~= false and max(0.0, group.chamferWidthM or 0.6) or 0.0
  local innerHalf = max(pr.leftExt, pr.rightExt) + pr.shW + chamfer + wmax * 0.5
  return innerHalf / foldSafety + guardMarginM
end

-- Straight-section cross-section (full crown, no bank, no fold clamp) for the read-only UI preview.
local function previewCrossSection(group)
  local pr = params(group)
  local latRes = max(1, floor(group.latRes or defaultLatRes))
  return crossSectionPts(pr, 1.0, latRes), bandLayout(pr.shW > 1e-4, latRes)
end


-- Public interface.
M.MAT_ROAD = MAT_ROAD
M.MAT_SHOULDER = MAT_SHOULDER

M.build = build
M.previewCrossSection = previewCrossSection
M.minSafeRadius = minSafeRadius

return M