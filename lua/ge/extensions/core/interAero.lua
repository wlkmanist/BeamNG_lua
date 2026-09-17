-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- slip streaming (green)
local slipReach = 3       -- lateral span of air wake having any effect (meters beyond vehicle width, per side)
local slipFull = 0.5      -- lateral span of air wake having full effect (meters beyond vehicle width, per side)
local slipStrength = 0.25 -- effect multiplier
local slipSec = 1.5       -- longitudinal span of air wake (in seconds)
local slipWidthReach = 4  -- longitudinal span of transition (from Full to Reach lateral span)
-- bump drafting (blue)
local bumpReach = 0.4     -- lateral span of smoothed air (meters beyond vehicle width, per side)
local bumpSec = 0.065     -- longitudinal span of smoothed air (in seconds)
local bumpStrength = 0.1  -- effect multiplier
-- side drafting (red)
local sideReach = 1.25    -- lateral reach (in meters, added to vehicle body width)
local sideStrength = 0.1  -- effect multiplier
local sideContrib = 0.85  -- effect contribution per side: 0.5 means half contribution (linear sum), 1 means full contribution (max value), values in between get a non-linear mix of both

-- dev helpers
local debugDrawEnabled = false
--local debugSpeed = 320 -- uses fake speed (kmh)
--local mouseWidth = 2.0 -- uses fake vehicle via mouse pointer with this width
local profilerType = nil
--local profilerType = "simple"
--local profilerType = "detail" -- TODO comment out all profiling code before release, for performance
local profiler, p, pd

-- helpers
local max, min, sqrt, abs = math.max, math.min, math.sqrt, math.abs
local solidTmp = ColorF(0,0,0,0) local function solid(color, alpha) solidTmp.r, solidTmp.g, solidTmp.b, solidTmp.a = color.r, color.g, color.b, alpha or 1 return solidTmp end
local coloriTmp = ColorI(0,0,0,0) local function colori(colorf) coloriTmp.r, coloriTmp.g, coloriTmp.b, coloriTmp.a = colorf.r*255, colorf.g*255, colorf.b*255, colorf.a*255 return coloriTmp end
local colorBlueF = ColorF(0.2, 0.5, 1, 0.3)
local colorWhiteF = ColorF(1, 1, 1, 0.1)
local colorBlackF = ColorF(0, 0, 0, 0.1)
local colorYellowF = ColorF(1, 1, 0, 0.1)
local colorOrangeF = ColorF(1, 0.5, 0, 0.1)
local colorLightOrangeF = ColorF(1, 0.75, 0.3, 0.1)
local colorGreenF = ColorF(0, 1, 0, 0.15)
local colorRedF = ColorF(1, 0, 0, 0.2)
local itemsPerEffect = 3 -- used in these tables: slips, bumps, sideL, sideR
local tmp, tmp2 = vec3(), vec3()
local slipsWind, bumpsWind, sidesWind = vec3(), vec3(), vec3()
local slipWidthReachInv = 1 / slipWidthReach
local function dzShortCurve(x) return clamp(1.2*x, 0, 1) end
local function dzLongCurve(x) return clamp(1.8*linearCurve(x), 0, 1) end
local function dzLooongCurve(x) return clamp(2.5*linearCurve(x), 0, 1) end
local function linearCurve(x) return clamp(x > 1 and 0 or x, 0, 1) end
local function sideCurveDist(x) x = linearCurve(1-x) return 2*clamp(8*x*square(1-x), 0, 0.5) end
local function xnormOptimized(self, a, abx, aby, abz, denInv) return denInv * (abx*(a.x-self.x) + aby*(a.y-self.y) + abz*(a.z-self.z)) end
local function squaredDistanceFlat(self, a) local tmp = self.x - a.x local d = tmp * tmp tmp = self.y - a.y return d + tmp * tmp end
local function getSlipLongitudinalFactor(dist, fullDist, maxDist)
  local fadeDist = max(dist - fullDist, 0)
  local fadeRangeInv = 1 / (max(maxDist - fullDist, 0) + 1e-30)
  return square(linearCurve(1 - fadeDist * fadeRangeInv))
end
-- incremental lateral reach of slipstream behind car
local function getSlipRadii(dist, hwidth, slipLen)
  local widthN = 1 - square(square(linearCurve(1 - dist * slipWidthReachInv)))
  local fullRad = slipFull * widthN
  local phase2N = clamp((dist - slipWidthReach) / (slipLen - slipWidthReach + 1e-30), 0, 1)
  local maxRad = fullRad + (slipReach - slipFull) * phase2N
  return hwidth + maxRad, hwidth + fullRad
end
local accelThresholdSq = square(40*9.8) -- 40 Gs of acceleration
local function objectTeleportedOptimized(curVel, prevVel, dtSimInv) return curVel:squaredDistance(prevVel) * dtSimInv > accelThresholdSq end -- custom optimized version of 'objectTeleported'

local function getVehicleTemplate(veh)
  local oobb = veh:getSpawnWorldOOBB()
  local hw, hl = oobb:getHalfExtentsXYZ()
  return {
    hwidth = hw, len = 2*hl,
    vel = vec3(), velNorm = vec3(), up = vec3(), velPrev = vec3(),
    pos = vec3(veh:getSpawnWorldOOBBCenterXYZ()), dir = vec3(), front = vec3(),
    effectsStart = vec3(), effectsCenter = vec3(), effectsEnd = vec3(),
    slips = {}, bumps = {}, sideL = {}, sideR = {},
    wind = vec3(), lastWind = vec3(),
    slipRad = hw + slipReach, bumpRad = hw + bumpReach, sideRad = hw + sideReach,
  }
end

--MARK: computeVehicle
local function computeVehicle(veh, result, dtSimInv, posxOverride, posyOverride)
  if pd then pd:add("fill.compute.pause") end
  result = result or getVehicleTemplate(veh)
  if pd then pd:add("fill.compute.template") end
  result.up:set(veh:getDirectionVectorUpXYZ())
  --result.dir:set(veh:getDirectionVectorXYZ()) --TODO directional width
  if pd then pd:add("fill.compute.basic") end
  tmp:set(result.pos)
  result.pos:set(veh:getSpawnWorldOOBBCenterXYZ())
  if posxOverride then result.pos.x = posxOverride end
  if posyOverride then result.pos.y = posyOverride end
  if pd then pd:add("fill.compute.pos") end
  result.vel:setSub2(result.pos, tmp)
  result.vel:setScaled(dtSimInv)
  if debugSpeed then result.vel:set(0, -debugSpeed/3.6, 0) end
  --local teleported = objectTeleported(result.pos, tmp, result.velPrev, 1/dtSimInv)
  local teleported = objectTeleportedOptimized(result.vel, result.velPrev, dtSimInv)
  if pd then pd:add("fill.compute.vel") end
  result.velPrev:set(result.vel)
  if teleported then result.vel:set(0, 0, 0) end
  result.velLen = result.vel:length()
  result.velNorm:setScaled2(result.vel, 1 / (result.velLen+1e-30)) -- optimization: avoid sqrt from normalize()
  -- TODO: compute current length and width, based on vehicle direction
  result.front:setAddScaled(result.pos, result.velNorm, 0.5*result.len) -- TODO: compute current front, based on vehicle direction
  if pd then pd:add("fill.compute.etc") end

  -- slipstream
  result.slipStart = 0.5 -- 50cm inside front bumper
  result.slipEnd = result.slipStart + result.velLen*slipSec
  -- bumpdraft
  result.bumpStart = result.len - 0.5 -- 50cm inside rear bumper
  result.bumpEnd = result.bumpStart + result.velLen*bumpSec
  -- sidedraft
  result.sideStart = result.len * 0.15
  result.sideEnd = result.len - 0.5  -- 50cm inside rear bumper
  -- global check
  result.effectsLen = result.slipEnd - result.slipStart -- optimization: assume slipstream engulfs the rest of effects
  result.effectsRadSq = square(result.effectsLen * 0.5)
  result.effectsStart:set(result.front)
  result.effectsEnd:setAddScaled(result.front, result.velNorm, -result.effectsLen)
  result.effectsCenter:setAddScaled(result.front, result.velNorm, -result.effectsLen*0.5)
  if pd then pd:add("fill.compute.effects") end
  return result
end

-- MARK: TODO
-- - begin considering lossy optimizations, beyond al current lossless optimizations (e.g. 1st candidate gonna be temporal spread of stuff that already changes at low frequencies)
-- - dynamic orientation-based width (e.g. tandem drift slipstream effects, nascar big-ones, etc) but will kill some of the GC and cache optimization. is the fps loss actually worth in those situations of all things?
-- - verify possible tiny wind leak due to setter optimization, implement sth that stil retains the optimizations
-- - since we cannot do CFD, and we cannot assume fixed-shape due to softbody physics, research a more reasonable compromise baseline of parameters
-- - evaluate pros/cons of frontal drag area calculations: cases of reduced realism, cases of improved realism, impact on spawn load times, blablahblah
-- - evaluate physics core changes for basic aero bias effects, how much fps will that sacrifice, etc

-- MARK: closest effects
local function writeClosest(selection, otherId, distance, overlap, maxItems)
  local n = #selection
  local maxSize = maxItems * itemsPerEffect
  if n == maxSize and selection[n - itemsPerEffect + 2] < distance then return end

  local index = 1
  while index <= n and selection[index+1] < distance do
    index = index + itemsPerEffect
  end

  if n == maxSize then
    for i = n - 2 * itemsPerEffect + 1, index, -itemsPerEffect do
      selection[i + itemsPerEffect] = selection[i]
      selection[i + itemsPerEffect + 1] = selection[i+1]
      selection[i + itemsPerEffect + 2] = selection[i+2]
    end
  else
    for i = n - itemsPerEffect + 1, index, -itemsPerEffect do
      selection[i + itemsPerEffect] = selection[i]
      selection[i + itemsPerEffect + 1] = selection[i+1]
      selection[i + itemsPerEffect + 2] = selection[i+2]
    end
  end
  selection[index] = otherId
  selection[index+1] = distance
  selection[index+2] = overlap
end

-- MARK: coverage calc
local function getSlipCoverageFactor(dist, fullRad, maxRad)
  if dist <= fullRad then return 1 end
  if maxRad <= fullRad + 1e-30 then return 0 end
  if dist >= maxRad then return 0 end
  return 1 - (dist - fullRad) / (maxRad - fullRad)
end

local function integrateSlipCoveragePrefix(dist, fullRad, maxRad)
  if dist <= 0 then return 0 end
  if maxRad <= fullRad + 1e-30 then return min(dist, fullRad) end
  if dist <= fullRad then return dist end
  if dist >= maxRad then return 0.5 * (fullRad + maxRad) end
  return fullRad + (maxRad * (dist - fullRad) - 0.5 * (dist * dist - fullRad * fullRad)) / (maxRad - fullRad)
end

local function integrateSlipCoverage(startPos, endPos, centerPos, fullRad, maxRad)
  if endPos <= startPos then return 0 end
  if endPos <= centerPos then return integrateSlipCoveragePrefix(centerPos - startPos, fullRad, maxRad) - integrateSlipCoveragePrefix(centerPos - endPos, fullRad, maxRad) end
  if startPos >= centerPos then return integrateSlipCoveragePrefix(endPos - centerPos, fullRad, maxRad) - integrateSlipCoveragePrefix(startPos - centerPos, fullRad, maxRad) end
  return integrateSlipCoveragePrefix(centerPos - startPos, fullRad, maxRad) + integrateSlipCoveragePrefix(endPos - centerPos, fullRad, maxRad)
end

local function takeCoverageImpl(segments, segmentCount, startPos, endPos, centerPos, fullRad, maxRad, maxCoverageInv)
  local coverage = 0
  local coverageN = 0
  local writeIdx = 1
  for i = 1, segmentCount, 2 do
    local segStart, segEnd = segments[i], segments[i+1]
    local overlapStart = max(segStart, startPos)
    local overlapEnd = min(segEnd, endPos)
    if overlapEnd > overlapStart then
      coverage = coverage + overlapEnd - overlapStart
      if maxCoverageInv ~= nil then
        coverageN = coverageN + integrateSlipCoverage(overlapStart, overlapEnd, centerPos, fullRad, maxRad) * maxCoverageInv
      end
      if segStart < overlapStart then
        segments[writeIdx] = segStart
        segments[writeIdx+1] = overlapStart
        writeIdx = writeIdx + 2
      end
      if overlapEnd < segEnd then
        segments[writeIdx] = overlapEnd
        segments[writeIdx+1] = segEnd
        writeIdx = writeIdx + 2
      end
    else
      segments[writeIdx] = segStart
      segments[writeIdx+1] = segEnd
      writeIdx = writeIdx + 2
    end
  end
  return coverage, writeIdx - 1, coverageN
end

local function takeCoverage(segments, segmentCount, startPos, endPos)
  local coverage, newSegmentCount = takeCoverageImpl(segments, segmentCount, startPos, endPos)
  return coverage, newSegmentCount
end

local function takeSlipCoverage(segments, segmentCount, startPos, endPos, centerPos, fullRad, maxRad, maxCoverageInv)
  local _, newSegmentCount, coverageN = takeCoverageImpl(segments, segmentCount, startPos, endPos, centerPos, fullRad, maxRad, maxCoverageInv)
  return coverageN, newSegmentCount
end

-- MARK: draw helpers
local tmpca, tmpcb, tmpcc, tmpcd = vec3(), vec3(), vec3(), vec3()
local function drawCoverageSegment(anchor, lateralDir, startPos, endPos, color)
  if endPos <= startPos then return end
  tmpca:setAddScaled(anchor, lateralDir, startPos)
  tmpcb:setAddScaled(anchor, lateralDir, endPos)
  debugDrawer:drawCylinder(tmpca, tmpcb, 0.06, color, false)
end

local function drawCoverageSegments(anchor, lateralDir, hwidth, segments, segmentCount, coveredColor)
  local coverageStart = -hwidth
  for i = 1, segmentCount, 2 do
    local uncoveredStart, uncoveredEnd = segments[i], segments[i+1]
    drawCoverageSegment(anchor, lateralDir, coverageStart, uncoveredStart, solid(coveredColor))
    drawCoverageSegment(anchor, lateralDir, uncoveredStart, uncoveredEnd, solid(colorBlackF, 0.2))
    coverageStart = uncoveredEnd
  end
  drawCoverageSegment(anchor, lateralDir, coverageStart, hwidth, solid(coveredColor))
end

local function drawProgressBar(anchor, dir, startPos, endPos, amount, color)
  if endPos <= startPos then return end
  local splitPos = startPos + (endPos - startPos) * clamp(amount, 0, 1)
  drawCoverageSegment(anchor, dir, startPos, splitPos, solid(color))
  drawCoverageSegment(anchor, dir, splitPos, endPos, solid(colorBlackF, 0.2))
end

local vehicles = {}
local function clearVehicleCache(vehId) vehicles[vehId] = nil end
local vehIteratorCtx = {}
local coverSegments = {}
local blinkTimer = 0
local blink
local function calculateAero(dtReal, dtSim)
  local dtSimInv = 1 / dtSim
  local playerVehId = be:getPlayerVehicleID(0)
  if p then p:add("pre") end

  -- MARK: fill
  -- recompute basic data
  local maxSide = 0
  for vehId, veh in activeVehiclesIterator(vehIteratorCtx) do
    local v = dtSim > 0.0001 and computeVehicle(veh, vehicles[vehId], dtSimInv)
    if v then
      vehicles[vehId] = v
      if pd then pd:add("fill.compute") end
      maxSide = max(maxSide, v.sideRad, v.slipRad)
      if pd then pd:add("fill.max") end
    end
  end
  if mouseWidth and debugDrawEnabled then
    local v = vehicles[1337]
    if not v then
      local vref = select(2, next(vehicles))
      if vref then
        v = lpack.decode(lpack.encode(vref))
        v.hwidth = mouseWidth*0.5
        v.slipRad = v.hwidth + slipReach
        v.bumpRad = v.hwidth + bumpReach
        v.sideRad = v.hwidth + sideReach
        vehicles[1337] = v
        maxSide = max(maxSide, v.hwidth)
      end
    end
    if v then
      local hit = cameraMouseRayCast() -- generates GC workload, debug only so oh well...
      local pos = hit and hit.pos or v.pos
      computeVehicle(getPlayerVehicle(0), v, dtSimInv, pos.x, pos.y)
      if debugDrawEnabled then
        local capsuleRadius = min(v.hwidth, v.len * 0.5)
        tmp:setAddScaled(v.front, v.velNorm, -capsuleRadius)
        tmp2:setAddScaled(v.front, v.velNorm, -(v.len - capsuleRadius))
        debugDrawer:drawSphere(tmp, capsuleRadius, solid(colorWhiteF, 1.0))
        debugDrawer:drawCylinder(tmp, tmp2, capsuleRadius, solid(colorWhiteF, 1.0))
        debugDrawer:drawSphere(tmp2, capsuleRadius, solid(colorWhiteF, 1.0))
      end
    end
    if pd then p:add("fill.mouse") end
  end
  maxSide = maxSide + slipReach -- we assume slipReach is greater than rest of extras
  if p then p:add("fill") end

  -- MARK: culling
  -- cull potential active pairs
  for thisId, this in pairs(vehicles) do
    if pd then pd:add("pairsCull0") end
    if this.velLen < 2 then goto continueThis end -- filter stationary vehicles/objects
    tmp:set(this.effectsStart) tmp:setSub(this.effectsEnd)
    local abx, aby, abz = tmp.x, tmp.y, tmp.z
    local denInv = 1 / (abx*abx + aby*aby + abz*abz + 1e-30)
    local maxDistSq = square(this.hwidth + maxSide)
    local effectsCenter, effectsRadSq, up = this.effectsCenter, this.effectsRadSq, this.up
    if pd then pd:add("pairsCull1") end
    for otherId, other in pairs(vehicles) do
      if pd then pd:add("pairsCull2") end
      if squaredDistanceFlat(effectsCenter, other.front) > effectsRadSq then goto continue end -- filter by simplistic circle check
      local asx, asy, asz = effectsCenter.x-other.front.x, effectsCenter.y-other.front.y, effectsCenter.z-other.front.z
      local behind = (abx*asx + aby*asy + abz*asz) * denInv
      local lateralSq = square(asx - abx*behind) + square(asy - aby*behind) + square(asz - abz*behind)
      if pd then pd:add("pairsCull3") end
      if lateralSq > maxDistSq then goto continue end -- filter by distance to wake aero effects centerline
      if pd then pd:add("pairsCull4") end
      if otherId == thisId then goto continue end
      local behind = xnormOptimized(other.effectsStart, this.effectsStart, abx, aby, abz, denInv)
      behind = behind * this.effectsLen
      if pd then pd:add("pairsXnorm") end
      local isSlip = behind > this.slipStart and behind < this.slipEnd and lateralSq < square(this.slipRad + other.hwidth)
      local isBump = behind > this.bumpStart and behind < this.bumpEnd and lateralSq < square(this.bumpRad + other.hwidth)
      local isSide = behind > this.sideStart and behind < this.sideEnd and lateralSq < square(this.sideRad + other.hwidth)
      if pd then pd:add("pairsCull5") end
      if not isSlip and not isBump and not isSide then goto continue end
      local isRight = up.x*(aby*asz - abz*asy) + up.y*(abz*asx - abx*asz) + up.z*(abx*asy - aby*asx) > 0
      local lateral = sqrt(lateralSq)
      if pd then pd:add("pairsLatUp") end
      if isSlip then writeClosest(other.slips, thisId, behind - this.slipStart, lateral * (isRight and -1 or 1), 4) end
      if isBump then writeClosest(this.bumps, otherId, behind - this.bumpStart, lateral * (isRight and 1 or -1), 2) end
      if isSide then writeClosest(isRight and this.sideR or this.sideL, otherId, lateral, behind - this.sideStart, 1) end
      if pd then pd:add("pairsCull6") end
      ::continue::
    end
    ::continueThis::
  end
  if p then p:add("pairs") end

  if debugDrawEnabled then
    blinkTimer = blinkTimer - dtReal
    if blinkTimer < 0 then blinkTimer = blinkTimer + 0.3 end
    blink = blinkTimer > 0.25
  end

  -- compute effects of pairs
  for thisId, this in pairs(vehicles) do
    sidesWind:set(0, 0, 0)
    bumpsWind:set(0, 0, 0)
    slipsWind:set(0, 0, 0)
      -- MARK: slip streaming
    coverSegments[1], coverSegments[2] = -this.hwidth, this.hwidth
    local coverCount = 2
    for i = 1, #this.slips, itemsPerEffect do
      local otherId, dist, lateral = this.slips[i], this.slips[i+1], this.slips[i+2]
      local other = vehicles[otherId] -- the other vehicle in front of ours
      local slipLen = other.slipEnd - other.slipStart
      if pd then pd:add("computeEffects.slip.common") end

      -- lateral calculations
      local slipRad, slipFullRad = getSlipRadii(dist, other.hwidth, slipLen)
      local maxCoverageInv = 1 / (integrateSlipCoverage(-this.hwidth, this.hwidth, 0, slipFullRad, slipRad) + 1e-30)
      local lateralStart = max(-this.hwidth, lateral - slipRad)
      local lateralEnd = min(this.hwidth, lateral + slipRad)
      local coverageN
      coverageN, coverCount = takeSlipCoverage(coverSegments, coverCount, lateralStart, lateralEnd, lateral, slipFullRad, slipRad, maxCoverageInv)
      if pd then pd:add("computeEffects.slip.lateral") end

      -- longitudinal calculations
      local longN = getSlipLongitudinalFactor(dist, other.len, slipLen)
      if pd then pd:add("computeEffects.slip.longitudinal") end

      -- debug draw
      if debugDrawEnabled and (thisId == playerVehId or thisId == 1337) then
        tmp:setCross(other.up, other.velNorm) tmp:normalize()
        for seg = 0, 19 do
          local segDist0 = slipLen * square(seg / 20)
          local segDist1 = slipLen * square((seg + 1) / 20)
          local segRad0 = getSlipRadii(segDist0, other.hwidth, slipLen)
          local segRad1 = getSlipRadii(segDist1, other.hwidth, slipLen)
          tmpcb:setAddScaled(other.effectsStart, other.velNorm, -(other.slipStart + segDist0))
          tmpcc:setAddScaled(other.effectsStart, other.velNorm, -(other.slipStart + segDist1))
          tmpca:setAddScaled(tmpcb, tmp, segRad0)
          tmpcd:setAddScaled(tmpcc, tmp, segRad1)
          debugDrawer:drawCylinder(tmpca, tmpcd, 0.1, solid(colorGreenF, blink and 0.0 or 0.6), false)
          tmpca:setAddScaled(tmpcb, tmp, -segRad0)
          tmpcd:setAddScaled(tmpcc, tmp, -segRad1)
          debugDrawer:drawCylinder(tmpca, tmpcd, 0.1, solid(colorGreenF, blink and 0.0 or 0.6), false)
          -- draw 10 spheres laterally at the segment midpoint to visualize the local lateral strength
          local segDistMid = 0.5 * (segDist0 + segDist1)
          local segRad, segFullRad = getSlipRadii(segDistMid, other.hwidth, slipLen)
          tmp2:setAddScaled(other.effectsStart, other.velNorm, -(other.slipStart + segDistMid))
          for j = 0, 9 do
            local sampleOffset = segRad * (2 * (j + 0.5) / 10 - 1)
            local cf = getSlipCoverageFactor(abs(sampleOffset), segFullRad, segRad)
            local lf = getSlipLongitudinalFactor(segDistMid, other.len, slipLen)
            local total = cf * lf
            tmpca:setAddScaled(tmp2, tmp, sampleOffset)
            debugDrawer:drawSphere(tmpca, 0.1+ 0.3 * total, solid(cf >=1 and colorGreenF or colorGreenF, blink and 0.0 or 0.45))
          end
        end
        debugDrawer:drawTextAdvanced(other.pos, string.format("SLIPSTREAM +%.1fkmh %.0f%% (%.1fkmh @ distance: %.0f%%, coverage: %.0f%%)", other.velLen*3.6*coverageN*longN, coverageN*longN*100,other.velLen*3.6, longN*100, coverageN*100), solid(colorBlackF), true, false, colori(colorGreenF), false, false)
      end
      if coverageN > 0 then
        local weight = coverageN * longN
        slipsWind:setAddScaled(slipsWind, other.vel, slipStrength*weight)
        if debugDrawEnabled and thisId == playerVehId then
          --debugDrawer:drawTextAdvanced(other.pos, string.format("SLIPSTREAM +%.1fkmh (%.1fkmh @ distance: %.0f%%, coverage: %.0f%%)", other.velLen*3.6*weight, other.velLen*3.6, longN*100, coverageN*100), solid(colorBlackF), true, false, colori(colorGreenF), false, false)
          debugDrawer:drawCylinder(this.front, other.pos, 0.025, solid(colorGreenF, blink and 0.0 or 0.5), false)
        end
      end
    end
    table.clear(this.slips)
    if debugDrawEnabled then
      tmp:setCross(this.velNorm, this.up)
      tmp:normalize()
      drawCoverageSegments(this.front, tmp, this.hwidth, coverSegments, coverCount, colorGreenF)
    end
    if pd then pd:add("computeEffects.slip") end

    -- MARK: bump drafting
    local lenInv = 1 / (this.bumpEnd-this.bumpStart + 1e-30)
    local thisWidthInv = 1 / (2*this.hwidth + 1e-30)
    coverSegments[1], coverSegments[2] = -this.hwidth, this.hwidth
    coverCount = 2
    for i = 1, #this.bumps, itemsPerEffect do
      local otherId, dist, lateral = this.bumps[i], this.bumps[i+1], this.bumps[i+2]
      local other = vehicles[otherId]
      local lateralStart = max(-this.hwidth, lateral - other.bumpRad)
      local lateralEnd = min(this.hwidth, lateral + other.bumpRad)
      local coverage
      coverage, coverCount = takeCoverage(coverSegments, coverCount, lateralStart, lateralEnd)
      if coverage > 0 then
        local coverageN = coverage * thisWidthInv
        local distN = linearCurve(1 - dist * lenInv)
        local weight = bumpStrength * coverageN * distN
        bumpsWind:setAddScaled(bumpsWind, other.vel, weight)
        if debugDrawEnabled and thisId == playerVehId then
          debugDrawer:drawTextAdvanced(other.front, string.format("BUMPDRAFT +%.1fkmh (%.1fkmh @ distance: %.0f%%, coverage: %.0f%%)", other.velLen*3.6*weight, other.velLen*3.6, distN*100, coverageN*100), solid(colorBlackF), true, false, colori(colorBlueF), false, false)
          debugDrawer:drawCylinder(this.pos, other.front, 0.025, solid(colorBlueF, blink and 0.0 or 0.5), false)
        end
      end
      if pd then pd:add("computeEffects.pair") end
    end
    table.clear(this.bumps)
    if debugDrawEnabled then
      tmp2:setAddScaled(this.front, this.velNorm, -this.len)
      drawCoverageSegments(tmp2, tmp, this.hwidth, coverSegments, coverCount, colorBlueF)
    end
    if pd then pd:add("computeEffects.bump") end

    -- MARK: side drafting
    lenInv = 1 / (this.sideEnd-this.sideStart + 1e-30) -- TODO should be other instead of this?? check
    local sideL, sideR
    for i = 1, #this.sideL, itemsPerEffect do -- LEFT --
      local otherId, lateral, dist = this.sideL[i], this.sideL[i+1], this.sideL[i+2]
      local other = vehicles[otherId]
      dist = dist * lenInv
      local distN = sideCurveDist(dist)
      local coverage = this.sideRad + other.hwidth - lateral
      local coverageN = clamp(coverage / 0.5*sideReach, 0, 1)
      sideL = distN * coverageN
      if debugDrawEnabled and thisId == playerVehId and sideL > 0 then
        debugDrawer:drawTextAdvanced(other.front, string.format("SIDEDRAFT-L -%.0fkmh (%.0fkmh, distance: %.0f%%, coverage: %.0f%%)", sideStrength*sideContrib*sideL*this.velLen*3.6, this.velLen*3.6, distN*100, coverageN*100), solid(colorBlackF), true, false, colori(colorRedF), false, false)
        debugDrawer:drawCylinder(this.pos, other.front, 0.025, solid(colorRedF, blink and 0.0 or 0.5), false)
      end
      if pd then pd:add("computeEffects.pair") end
    end
    table.clear(this.sideL)
    for i = 1, #this.sideR, itemsPerEffect do -- RIGHT --
      local otherId, lateral, dist = this.sideR[i], this.sideR[i+1], this.sideR[i+2]
      local other = vehicles[otherId]
      dist = dist * lenInv
      local distN = sideCurveDist(dist)
      local coverage = this.sideRad + other.hwidth - lateral
      local coverageN = clamp(coverage / (0.5*sideReach + 1e-30), 0, 1)
      sideR = distN * coverageN
      if debugDrawEnabled and thisId == playerVehId and sideR > 0 then
        debugDrawer:drawTextAdvanced(other.front, string.format("SIDEDRAFT-R -%.0fkmh (%.0fkmh, distance: %.0f%%, coverage: %.0f%%)", sideStrength*sideContrib*sideR*this.velLen*3.6, this.velLen*3.6, distN*100, coverageN*100), solid(colorBlackF), true, false, colori(colorRedF), false, false)
        debugDrawer:drawCylinder(this.pos, other.front, 0.025, solid(colorRedF, blink and 0.0 or 0.5), false)
      end
      if pd then pd:add("computeEffects.pair") end
    end
    table.clear(this.sideR)
    -- combine LEFT+RIGHT side drafting:
    this.wind:setAdd2(slipsWind, bumpsWind)
    if pd then pd:add("computeEffects.sum") end
    if sideL or sideR then
      sideL, sideR = sideL or 0, sideR or 0
      local sideTotal = clamp(sideContrib * (sideL + sideR) - (2 * sideContrib - 1) * sideL * sideR, 0, 1)
      sidesWind:setAddScaled(sidesWind, this.vel, -sideStrength * sideTotal)
      this.wind:setAdd(sidesWind)
      if pd then pd:add("computeEffects.side") end
    end

    -- MARK: apply
    if this.lastWind:squaredDistance(this.wind) > square(0.28) then
      local veh = getObjectByID(thisId)
      if veh then veh:setWindAero(this.wind.x, this.wind.y, this.wind.z) end
      --log("I", "", string.format("[this vel: %.0fkmh] Wind requested for vehicle %d: %.0fkmh (slip: %.0fkmh, bump: %.0fkmh, side: %.0fkmh)", this.velLen*3.6, thisId, this.wind:length()*3.6, slipsWind:length()*3.6, bumpsWind:length()*3.6, sidesWind:length()*3.6))
      this.lastWind:set(this.wind)
      if pd then pd:add("computeEffects.wind") end
    end

    -- MARK: viz
    if debugDrawEnabled then
      local windLen = this.wind:length()
      local f = windLen/this.velLen / (2*this.len + 1e-30)
      -- side draft
      tmp:setCross(this.up, this.velNorm) tmp:normalize()
      tmp2:setScaled2(this.velNorm, -1)
      tmpcc:setAddScaled(this.front, tmp, this.hwidth)
      tmpcd:setAddScaled(this.front, tmp, -this.hwidth)
      drawProgressBar(tmpcc, this.velNorm, -this.len, 0, sideL or 0, colorRedF)
      drawProgressBar(tmpcd, this.velNorm, -this.len, 0, sideR or 0, colorRedF)
      -- results:
      tmp:setAddScaled(this.pos, slipsWind, f) debugDrawer:drawCylinder(this.pos, tmp, 0.03, solid(colorGreenF, 1), false)
      tmp2:setAddScaled(tmp, bumpsWind, f)     debugDrawer:drawCylinder(tmp, tmp2, 0.06, solid(colorBlueF, 1), false)
      tmp:setAddScaled(tmp2, sidesWind, f)     debugDrawer:drawCylinder(tmp2, tmp, 0.08, solid(colorRedF, 0.3), false)
      tmp:setAddScaled(this.pos, this.wind, f) debugDrawer:drawCylinder(this.pos, tmp, 0.01, solid(colorWhiteF, 0.8), false)

      -- focused car
      debugDrawer:drawTextAdvanced(this.pos, string.format("%.0fkmh%s", windLen*3.6, (thisId == playerVehId or thisId == 1337) and string.format(" (%.0fkmh)", this.velLen*3.6) or ""), solid(colorBlackF), true, false, colori(thisId == playerVehId and colorOrangeF or colorLightOrangeF), false, false)
      if thisId == playerVehId or thisId == 1337 then
        tmp:set(this.pos) tmp.z = tmp.z + 5
        debugDrawer:drawCylinder(this.pos, tmp, 0.025, solid(blink and colorBlackF or colorWhiteF), false)
        tmp:setAddScaled(this.effectsStart, this.velNorm, -this.slipStart) tmp2:setAddScaled(this.effectsStart, this.velNorm, -this.slipEnd)
        debugDrawer:drawCylinder(tmp, tmp2, this.slipRad, colorGreenF)
        tmp:setAddScaled(this.effectsStart, this.velNorm, -this.bumpStart) tmp2:setAddScaled(this.effectsStart, this.velNorm, -this.bumpEnd)
        debugDrawer:drawCylinder(tmp, tmp2, this.bumpRad, colorBlueF)
        tmp:setAddScaled(this.effectsStart, this.velNorm, -this.sideStart) tmp2:setAddScaled(this.effectsStart, this.velNorm, -this.sideEnd)
        debugDrawer:drawCylinder(tmp, tmp2, this.sideRad, colorRedF)
      end
    end
  end
  if p then p:add("computeEffects") end
end

-- MARK: main
local pCache = profilerType == "detail" and LuaProfiler("interAero =====================================")
local pTimer = 0.1
local profilerLvl = 0
local debugDrawEnabledOrig = debugDrawEnabled
local elapsedMin = math.huge
local elapsedMinTime = 0
local time = 0
local function onUpdate(dtReal, dtSim, dtRaw)
  local profilerSimpleStart
  if profilerType then
    pTimer = pTimer - dtReal
    debugDrawEnabled = debugDrawEnabledOrig
    if pTimer <= 0 then
      debugDrawEnabled = false
      profilerLvl = profilerType == "simple" and -1 or ((profilerLvl + 1) % 3)
      if profilerLvl <= 0 then
        pTimer = pTimer + (profilerType == "simple" and 0.1 or 1)
        profilerSimpleStart = profilerType == "simple" and os.clockhp() or nil
      end
      profiler = profilerLvl > -1 and pCache or nil
      p = profilerLvl > 0 and pCache or nil
      pd = profilerLvl > 1 and pCache or nil
    end
  end
  if profiler then profiler:start() end
  calculateAero(dtReal, dtSim)
  if profiler and profilerLvl == 0 then profiler:add("-----------------------------------------") end
  if profiler then profiler:finish(true, nil) end
  if profilerSimpleStart then
    local elapsed = os.clockhp() - profilerSimpleStart
    if elapsed < elapsedMin then
      elapsedMin = elapsed
      elapsedMinTime = 0
      log("I", "", string.format("Aero min: %.4f ms", elapsedMin*1000))
    end
  end
  if profilerType == "simple" then
    time = time + dtReal
    elapsedMinTime = elapsedMinTime + dtReal
    if (time > 10 and time-dtReal < 10) or (elapsedMinTime > 10 and elapsedMinTime-dtReal < 10) then
      log("I", "", string.format("Aero min: %.4f ms (%.0fs, %.0fs stable)%s", elapsedMin*1000, time, elapsedMinTime, elapsedMinTime > 10 and "---- MARK" or ""))
    end
  end
  profiler, p, pd = nil, nil, nil
end

M.onUpdate = onUpdate
M.onVehicleActiveChanged = clearVehicleCache
M.onVehicleSpawned = clearVehicleCache -- required to update cache when vehicle is replaced with a different one
M.onVehicleDestroyed = clearVehicleCache

return M
