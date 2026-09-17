-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This is a utility for homologating a spline against a preset, so as to ensure it meets the specified geometric standards of various road types.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local optimiseIterPerFrame = 5 -- The number of optimisation iterations to run per frame.

local slopeEaseFactor = 0.1 -- The ease factor for the slope adjustment.

local radiusLook = 5 -- Number of points to look ahead and behind, for radius analysis.
local radViolationTol = 0.01 -- The tolerance for corner radius curvature.
local radSmoothingAlpha = 0.2 -- Laplacian smoothing strength.

local bankStepDeg = 1.0 -- For banking optimisation, the step size to use.

local widthNudgeAmount = 0.05 -- The amount to nudge widths by, in percent.

local epsilon = 1e-6 -- A small value used to avoid division by zero.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')
local roadStds = require('editor/toolUtilities/roadDesignStandards')

-- Module constants.
local min, max, random = math.min, math.max, math.random
local abs, asin, rad, deg = math.abs, math.asin, math.rad, math.deg
local globalUp = vec3(0, 0, 1)
local presetsMap = roadStds.getPresetsMap()

-- Module State:
local dists = {}
local ab, bc, rotatedNormal = vec3(), vec3(), vec3()
local tmp1, tmp2, tmp3 = vec3(), vec3(), vec3()
local p0_2D, p1_2D, p2_2D = vec3(), vec3(), vec3()


-- Returns the optimization iterations per frame.
local function getOptimisationIterationsPerFrame() return optimiseIterPerFrame end

-- Slope analysis.
local function analyseSlope(spline)
  local divPoints, eSlopeNorm = spline.divPoints, spline.eSlopeNorm
  local pre = presetsMap[spline.homologationPreset]
  local maxSlope = pre.maxSlope
  local invSlope = 1.0 / (maxSlope + epsilon)
  table.clear(eSlopeNorm)
  local worstNorm, worstIdx = -1, -1
  for i = 2, #divPoints - 1 do
    local p0, p1, p2 = divPoints[i - 1], divPoints[i], divPoints[i + 1]

    -- Backward slope.
    ab:set(p1.x - p0.x, p1.y - p0.y, 0)
    local horizLenBack = ab:length() + epsilon
    local dzBack = p1.z - p0.z
    local slopeBack = abs(dzBack / horizLenBack)

    -- Forward slope.
    bc:set(p2.x - p1.x, p2.y - p1.y, 0)
    local horizLenFwd = bc:length() + epsilon
    local dzFwd = p2.z - p1.z
    local slopeFwd = abs(dzFwd / horizLenFwd)

    -- Combine the backward and forward slopes, and compute the penalty.
    local slope = max(slopeBack, slopeFwd)
    local penalty = max(0, slope - maxSlope)
    local norm = penalty * invSlope
    eSlopeNorm[i] = norm

    -- Update the worst slope if this is the new worst.
    if norm > worstNorm then
      worstNorm = norm
      worstIdx = i
    end
  end
  spline.slopeWorstDivIdx = worstIdx
  spline.slopeWorstNorm = (worstNorm > 0) and worstNorm or 0.0
end

-- Corner radius analysis.
local function analyseRadius(spline)
  local divPoints, eRadiusNorm = spline.divPoints, spline.eRadiusNorm
  local pre = presetsMap[spline.homologationPreset]
  local minRadius = pre.minRadius
  table.clear(eRadiusNorm)
  local maxNorm, maxDivIdx = -1, -1

  for i = 1, #divPoints do
    local iBack, iFwd = i - radiusLook, i + radiusLook
    if iBack < 1 or iFwd > #divPoints then
      eRadiusNorm[i] = 0.0
      goto continue -- Out of bounds.
    end

    -- Compute the corner radius.
    tmp1:set(divPoints[iBack].x, divPoints[iBack].y, 0) -- Do in 2D.
    tmp2:set(divPoints[i].x, divPoints[i].y, 0)
    tmp3:set(divPoints[iFwd].x, divPoints[iFwd].y, 0)
    local radius = geom.computeTurningRadius(tmp1, tmp2, tmp3)
    if not radius or radius ~= radius or radius <= 0 then
      eRadiusNorm[i] = 0.0
      goto continue -- Invalid radius.
    end

    -- Compute the penalty.
    local norm
    if radius < minRadius then
      norm = 1.0
    elseif radius < minRadius * 2 then
      local t = (radius - minRadius) / minRadius
      norm = 1.0 - t
    else
      norm = 0.0
    end
    eRadiusNorm[i] = norm

    -- Update the worst radius if this is the new worst.
    if norm > maxNorm then
      maxNorm = norm
      maxDivIdx = i
    end

    ::continue::
  end

  spline.radiusWorstDivIdx = maxDivIdx
  spline.radiusWorstNorm = (maxNorm > 0) and maxNorm or 0.0
end

-- Banking analysis.
local function analyseBanking(spline)
  local divPoints, tangents, eBankingNorm = spline.divPoints, spline.tangents, spline.eBankingNorm
  local nmls, nodes, discMap = spline.nmls, spline.nodes, spline.discMap
  local pre = presetsMap[spline.homologationPreset]
  local maxBankDeg = pre.maxBanking
  table.clear(eBankingNorm)

  for divIdx = 1, #divPoints do
    -- Find corresponding node indices for divIdx.
    local nodeIdx = 1
    for i = 1, #nodes - 1 do
      if discMap[i] <= divIdx and divIdx <= discMap[i + 1] then
        nodeIdx = i
        break
      end
    end

    local idxA, idxB = nodeIdx, nodeIdx + 1
    local dA, dB = discMap[idxA], discMap[idxB]
    local alpha = (divIdx - dA) / max((dB - dA), epsilon)

    -- Lerp between node normals.
    local nml = lerp(nmls[idxA], nmls[idxB], alpha)
    nml:normalize()

    -- Get tangent.
    local tangent = tangents[divIdx]
    local tangentHoriz = vec3(tangent.x, tangent.y, 0)
    if tangentHoriz:length() < epsilon then
      tangentHoriz:set(1, 0, 0) -- Fallback to X axis if vertical.
    else
      tangentHoriz:normalize()
    end

    -- Compute the bank angle.
    local sideAxis = globalUp:cross(tangentHoriz) -- The side axis (perpendicular in horizontal plane).
    sideAxis:normalize()
    local bankComponent = nml:dot(sideAxis) -- The lateral component of the normal.
    bankComponent = clamp(bankComponent, -1, 1)
    local signedBankDeg = deg(asin(bankComponent)) -- The signed bank angle in degrees.

    -- Compute penalty only if over limit.
    local excess = max(0, abs(signedBankDeg) - maxBankDeg)
    local norm = excess / maxBankDeg

    eBankingNorm[divIdx] = clamp(norm, 0, 1)
  end
end

-- Width gradient analysis.
local function analyseWidth(spline)
  local divWidths, eWidthNorm = spline.divWidths, spline.eWidthNorm
  local divPoints = spline.divPoints
  local pre = presetsMap[spline.homologationPreset]
  local maxGrad = pre.maxWidthGradient
  table.clear(eWidthNorm)
  local numDivs = #divWidths
  for i = 1, numDivs - 1 do
    local iPlus1 = i + 1
    local w0, w1 = divWidths[i], divWidths[iPlus1]
    local p0, p1 = divPoints[i], divPoints[iPlus1]
    tmp1:set(p0.x, p0.y, 0)
    tmp2:set(p1.x, p1.y, 0)
    local d = tmp1:distance(tmp2) + epsilon
    local grad = abs(w1 - w0) / d
    local norm = clamp((grad - maxGrad) / maxGrad, 0, 1)
    eWidthNorm[i] = norm
  end
  eWidthNorm[numDivs] = eWidthNorm[numDivs - 1] or 0 -- Last entry for stability.
end

-- Jump table for the metric analysers.
local analyserJumpTable = {
  [0] = analyseSlope,
  [1] = analyseRadius,
  [2] = analyseBanking,
  [3] = analyseWidth,
}

-- analyses the spline based on the current metric.
local function analyseSpline(spline)
  local func = analyserJumpTable[spline.splineAnalysisMode]
  func(spline)
end

-- Optimises the slope of the spline.
local function optimiseSlope(spline)
  local nodes = spline.nodes
  local numNodes = #nodes
  local startZ, endZ = nodes[1].z, nodes[numNodes].z
  local pre = presetsMap[spline.homologationPreset]
  local maxSlope = pre.maxSlope

  -- Precompute cumulative distances in XY.
  table.clear(dists)
  dists[1] = 0.0
  for i = 2, numNodes do
    local iMinus1 = i - 1
    local a, b = nodes[iMinus1], nodes[i]
    tmp1:set(b.x, b.y, 0)
    tmp2:set(a.x, a.y, 0)
    dists[i] = dists[iMinus1] + tmp1:distance(tmp2)
  end
  local totalDist = dists[#dists]
  if totalDist == 0 then
    return -- All nodes too close to each other, so do nothing.
  end

  -- Pick a random interior node.
  local i = random(2, numNodes - 1)

  -- Check slopes on both segments.
  local p0, p1, p2 = nodes[i - 1], nodes[i], nodes[i + 1]
  p0_2D:set(p0.x, p0.y, 0)
  p1_2D:set(p1.x, p1.y, 0)
  p2_2D:set(p2.x, p2.y, 0)
  local slope1 = abs(p1.z - p0.z) / (p0_2D:distance(p1_2D) + epsilon)
  local slope2 = abs(p2.z - p1.z) / (p1_2D:distance(p2_2D) + epsilon)

  local allowed = maxSlope
  if slope1 <= allowed and slope2 <= allowed then
    return -- Already acceptable, don't touch.
  end

  -- Adjust toward geometric ramp only if needed.
  local t = dists[i] / totalDist
  local targetZ = startZ + t * (endZ - startZ)
  local oldZ = nodes[i].z
  nodes[i].z = lerp(oldZ, targetZ, slopeEaseFactor)

  -- Recompute the spline geometry and score it.
  geom.catmullRomFree(spline)
  analyseSpline(spline)
end

-- Optimises the corner radius curvature of the spline.
local function optimiseRadius(spline)
  local nodes, nNodes = spline.nodes, #spline.nodes
  if nNodes < 3 then
    return
  end

  -- Score the spline with respect to corner radius curvature.
  analyseRadius(spline)

  -- Check if there is a violation. This will stop the smoothing as soon as the spline is in the legal envelope defined by the preset.
  local eRadiusNorm, violationFound = spline.eRadiusNorm, false
  for i = 1, #eRadiusNorm do
    if eRadiusNorm[i] > radViolationTol then
      violationFound = true
      break
    end
  end
  if not violationFound then
    return -- All within preset envelope, skip smoothing.
  end

  -- Laplacian smoothing.
  for i = 2, nNodes - 1 do
    local pPrev, pCurr, pNext = nodes[i - 1], nodes[i], nodes[i + 1]
    local mx, my = (pPrev.x + pNext.x) * 0.5, (pPrev.y + pNext.y) * 0.5
    local pCurrX, pCurrY = pCurr.x, pCurr.y
    pCurr.x, pCurr.y = pCurrX + (mx - pCurrX) * radSmoothingAlpha, pCurrY + (my - pCurrY) * radSmoothingAlpha
  end

  -- Recompute the spline geometry and re-score it.
  geom.catmullRomFree(spline)
  analyseRadius(spline)
end

-- Optimises the banking of the spline.
local function optimiseBanking(spline)
  local nodes, nmls, tangents, discMap = spline.nodes, spline.nmls, spline.tangents, spline.discMap
  local pre = presetsMap[spline.homologationPreset]
  local maxBankDeg = pre.maxBanking

  -- Compute the twist angle (consistent with analyse function).
  local i = random(1, #nodes) -- Pick a random node (including endpoints).
  local divIdx = discMap[i] or 1
  local tangent, normal = tangents[divIdx], nmls[i]

  -- Compute signed bank angle (positive = right bank, negative = left bank).
  local signedBankDeg = deg(geom.signedAngleBetweenVecs(globalUp, normal, tangent))

  if abs(signedBankDeg) <= maxBankDeg + epsilon then
    return -- Already within the preset envelope, skip optimisation.
  end

  -- Compute target at the envelope boundary, preserving sign.
  local targetDeg = signedBankDeg > 0 and maxBankDeg or -maxBankDeg
  local deltaDeg = targetDeg - signedBankDeg
  local step = clamp(deltaDeg, -bankStepDeg, bankStepDeg) -- Clamp to fixed stable step.

  -- Rotate normal around tangent.
  local angleRad = rad(step)
  geom.rotateVecAroundAxisInlined(normal, tangent, angleRad, rotatedNormal)
  rotatedNormal:normalize()
  nmls[i] = rotatedNormal

  -- Recompute geometry and score the spline.
  geom.catmullRomFree(spline)
  analyseSpline(spline)
end

-- Optimises the width of the spline.
local function optimiseWidth(spline)
  local nodes, widths = spline.nodes, spline.widths
  local nNodes = #nodes
  if nNodes < 3 then
    return -- Not enough nodes to optimise.
  end

  -- Pre-compute distances.
  table.clear(dists)
  dists[1] = 0.0
  for i = 2, nNodes do
    local iMinus1 = i - 1
    tmp1:set(nodes[i])
    tmp1.z = 0.0
    tmp2:set(nodes[iMinus1])
    tmp2.z = 0.0
    dists[i] = dists[iMinus1] + tmp1:distance(tmp2)
  end

  -- Get the preset constraint.
  local pre = presetsMap[spline.homologationPreset]
  local maxGrad = pre.maxWidthGradient

  local idx = random(1, nNodes - 1) -- A random node.
  local idxPlus1 = idx + 1
  local w0, w1 = widths[idx], widths[idxPlus1]
  local segLen = dists[idxPlus1] - dists[idx]
  local allowedDelta = maxGrad * segLen -- The allowed change in width.
  local delta = w1 - w0 -- The current change in width.

  -- If the current width is too much, nudge it down.
  if abs(delta) > allowedDelta + epsilon then
    local excess = abs(delta) - allowedDelta
    local nudge = min(excess, widthNudgeAmount)
    local direction = delta > 0 and 1 or -1 -- The direction to nudge.

    -- Nudge distribution, by case.
    local isFixed0, isFixed1 = (idx == 1), (idxPlus1 == nNodes) -- Detect endpoints.
    if not isFixed0 and not isFixed1 then
      local nudgeSize = 0.5 * nudge * direction -- Case: both ends are free, so nudge both.
      widths[idx] = widths[idx] + nudgeSize
      widths[idxPlus1] = widths[idxPlus1] - nudgeSize
    elseif not isFixed0 then
      widths[idx] = widths[idx] + nudge * direction -- Case: only the last end is fixed, so nudge the first width.
    elseif not isFixed1 then
      widths[idxPlus1] = widths[idxPlus1] - nudge * direction -- Case: only the first end is fixed, so nudge the second width.
    end

    -- Recompute the spline geometry and score it.
    geom.catmullRomFree(spline)
    analyseWidth(spline)
  end
end

-- Jump table for the metric optimisers.
local optimiserJumpTable = {
  [0] = optimiseSlope,
  [1] = optimiseRadius,
  [2] = optimiseBanking,
  [3] = optimiseWidth,
}

-- Dispatcher with iteration loop.
local function optimiseSpline(spline, numIter)
  -- Ensure geometry is up to date, and score the spline.
  geom.catmullRomFree(spline)
  analyseSpline(spline)
  spline.isDirty = true

  -- Run the optimiser the required number of times in this frame.
  -- [Dispatch to the appropriate optimiser based on the optimisation mode.]
  local func = optimiserJumpTable[spline.splineAnalysisMode]
  for _ = 1, numIter do
    func(spline)
  end
end


-- Public interface.
M.getOptimisationIterationsPerFrame =                   getOptimisationIterationsPerFrame

M.analyseSpline =                                       analyseSpline
M.optimiseSpline =                                      optimiseSpline

return M