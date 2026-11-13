-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User variables.
local nearFarLimitSq = square(400.0) -- The maximum distance for near-field dynamic SFX emitters
local radiusLength = 0.5 -- The length of the radius multiplier.
local minAxisLimit = 1.0 -- The minimum axis limit.
local blueNoiseInterval = 3 -- The number of frames between random segment probes on an emitter host.

-- Weighting coefficients.  TODO - REMOVE LATER WHEN SYSTEM IS TUNED.
local widthCoeff = 100.0 -- The weight of the river width.
local depthCoeff = 100.0 -- The weight of the river depth.
local speedCoeff = 100.0 -- The speed coefficient.
local expOffset = 800 -- The exponential offset.

local diskFileName = "ribbonData.audioSFX.json" -- The name of the file where the ribbons are saved when level is saved.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}
local logTag = 'audioRibbon'

-- Module constants.
local min, max, floor, sqrt, huge = math.min, math.max, math.floor, math.sqrt, math.huge


-- Module state.
local ribbons = nil -- The collection of ribbons for which we compute dynamic audio emitters.
local ribbonNames = {} -- The collection of ribbon names (used for fast look-up).
-- The collections of near ribbons (full set of emitters), mid ribbons (inner point only) and far ribbons (round robin).
-- The three lists are disjoint;  the near list holds at most two ribbons, being the two closest ones.
local nearList, midList, farList = {}, {}, {}
-- The closest ribbons seen so far this frame, used to re-select the near list at the end of the frame.
local nearCandA, nearCandB = { key = nil, idx = nil, dSq = 0 }, { key = nil, idx = nil, dSq = 0 }
local farSegmentRoundRobinKey = nil -- The key used for the round-robin on the far list segments
local blueFrameTick = 0 -- Counts frames so that every emitter takes its random probe on the same frame.
local isBlueFrame = false -- True on the frames where the random probe replaces the directional probe.
local axes = { {}, {}, {}, {}, {} }
local axesCache = { {}, {}, {}, {}, {} }
local sfxEmitters = { {}, {}, {}, {}, {} }
local tmp0, tmp1, tmp2, tmp3, tmp4, tmp5 = vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
local tmpAxis1, tmpAxis2, tmpList = vec3(), vec3(), vec3()
local tmpBlueP = vec3()
local lPosition, lForward, lRight = vec3(), vec3(), vec3()


-- Compute the closest point to the given segment.  Returns the point as separate components, to avoid a copy at each call site.
local function closestPoint(segIdx, p, ribbon)
  local isAmbient = ribbon.isAmbient
  local isTopActive = ribbon.isTopActive
  local isUpRibbon = ribbon.isUpRibbon
  local isQuadAndVolume = ribbon.isQuadAndVolume

  local twoSegIdx = segIdx * 2
  local i1, i2, i3, i4 = twoSegIdx - 1, twoSegIdx, twoSegIdx + 1, twoSegIdx + 2
  local c0, c1, c2, c3 = ribbon.nodes[i1], ribbon.nodes[i2], ribbon.nodes[i3], ribbon.nodes[i4]
  local d0, d1, d2, d3 = ribbon.depths[i1], ribbon.depths[i2], ribbon.depths[i3], ribbon.depths[i4]
  -- The z-offset is a per-ribbon constant (the flags only change in the editor).  Collapsing the four
  -- branches into a single scale lets the common no-offset case skip the vertex copies entirely.
  local zScale
  if isAmbient or isQuadAndVolume then
    zScale = isUpRibbon and -0.5 or 0.5
  elseif isUpRibbon then
    zScale = isTopActive and 0.0 or -1.0
  else
    zScale = isTopActive and 1.0 or 0.0
  end
  local a, b, c, d
  if zScale == 0.0 then
    a, b, c, d = c0, c1, c2, c3
  else
    tmp0:set(c0); tmp0.z = tmp0.z + d0 * zScale
    tmp1:set(c1); tmp1.z = tmp1.z + d1 * zScale
    tmp2:set(c2); tmp2.z = tmp2.z + d2 * zScale
    tmp3:set(c3); tmp3.z = tmp3.z + d3 * zScale
    a, b, c, d = tmp0, tmp1, tmp2, tmp3
  end
  local u1, v1 = p:triangleClosestPointUV(a, b, c)
  tmp4:setTrianglePointFromUV(a, b, c, u1 ,v1)
  local u2, v2 = p:triangleClosestPointUV(b, c, d)
  tmp5:setTrianglePointFromUV(b, c, d, u2 ,v2)
  local dSq1, dSq2 = p:squaredDistance(tmp4), p:squaredDistance(tmp5)
  if dSq2 < dSq1 then
    return tmp5.x, tmp5.y, tmp5.z, dSq2, u2, v2, true
  end
  return tmp4.x, tmp4.y, tmp4.z, dSq1, u1, v1, false
end

-- Creates an SFX Emitter object.
local function createSfxEmitter(eventName)
    local emitter = createObject("SFXEmitter")
    emitter = Sim.upcast(emitter)
    if emitter then
      emitter:setTransform(MatrixF(true))
      emitter:setField("track", 0, ffi.string(eventName))
      emitter.canSave = false
      emitter:registerObject('DynamicSFXEmitter_' .. Engine.generateUUID())
      emitter:play()
      return emitter
    end
  return Sim.upcast(emitter)
end

-- Update the given (inner) SFX emitter host.
local function updateInnerEmitterHost(emit, ribbon, p, forceRandomProbe)
  local px, py, pz, bestSqDist, u, v, isFirstTriangle = closestPoint(emit.bestSeg, p, ribbon)

  if px then
    local emitPos = emit.pos
    emitPos:set(px, py, pz)

    -- The two probes below alternate rather than both running, which holds the cost at two segment tests every frame.
    local sampleSeg
    if not (isBlueFrame or forceRandomProbe) then
      -- Try the segment in the current search direction.  The direction only flips when the probe fails, so a
      -- listener travelling along the ribbon keeps probing the way it is moving and pays for a single segment test.
      local probeSeg = emit.bestSeg + emit.dir
      if probeSeg > 0 and probeSeg <= ribbon.numSegs then
        local qx, qy, qz, dSq, qu, qv, qIsFirstTriangle = closestPoint(probeSeg, p, ribbon)
        if dSq < bestSqDist then
          bestSqDist = dSq
          emitPos:set(qx, qy, qz)
          emit.bestSeg = probeSeg
          u, v, isFirstTriangle = qu, qv, qIsFirstTriangle
        else
          emit.dir = -emit.dir
        end
      else
        emit.dir = -emit.dir
      end
      -- The outer hosts still need a jump candidate on these frames, so hand them this host's own best point.
      sampleSeg = emit.bestSeg
      tmpBlueP:set(emitPos)
    else
      -- Try a random segment instead, which lets the emitter escape a local minimum the directional walk cannot leave.
      emit.bN = getBlueNoise1d(emit.bN)
      sampleSeg = max(1, floor(emit.bN * ribbon.numSegs))
      local bx, by, bz, dSq, bu, bv, bIsFirstTriangle = closestPoint(sampleSeg, p, ribbon)
      if sampleSeg ~= emit.bestSeg and dSq < bestSqDist then
        bestSqDist = dSq
        emitPos:set(bx, by, bz)
        emit.bestSeg = sampleSeg
        u, v, isFirstTriangle = bu, bv, bIsFirstTriangle
      end
      tmpBlueP:set(bx, by, bz)
    end

    return tmpBlueP, sampleSeg, u, v, isFirstTriangle, bestSqDist
  end
  return nil, nil, nil, nil, false, nil
end

-- Update the given (outer) SFX emitter host.
local function updateOuterEmitterHost(emit, ribbon, p, muteFlag, bluePoint, blueSeg, axis, axisCache, radius)
  local px, py, pz, bestSqDist, u, v, isFirstTriangle = closestPoint(emit.bestSeg, p, ribbon)
  local emitPos = emit.pos
  emitPos:set(px, py, pz)

  -- First, try the segment in the current search direction.  The direction only flips when the probe fails, so a
  -- listener travelling along the ribbon keeps probing the way it is moving and pays for a single segment test.
  local probeSeg = emit.bestSeg + emit.dir
  if probeSeg > 0 and probeSeg <= ribbon.numSegs then
    local qx, qy, qz, dSq, qu, qv, qIsFirstTriangle = closestPoint(probeSeg, p, ribbon)
    if dSq < bestSqDist then
      bestSqDist = dSq
      emitPos:set(qx, qy, qz)
      emit.bestSeg = probeSeg
      u, v, isFirstTriangle = qu, qv, qIsFirstTriangle
    else
      emit.dir = -emit.dir
    end
  else
    emit.dir = -emit.dir
  end

  -- Second, try the segment the inner host handed over;  its random sample on a blue frame, its own best point otherwise.
  -- bluePoint sits closest to the listener rather than to p, so its distance is an upper bound and only gates the full test.
  if blueSeg ~= emit.bestSeg and p:squaredDistance(bluePoint) < bestSqDist then
    local bx, by, bz, dSq, bu, bv, bIsFirstTriangle = closestPoint(blueSeg, p, ribbon)
    if dSq < bestSqDist then
      bestSqDist = dSq
      emitPos:set(bx, by, bz)
      emit.bestSeg = blueSeg
      u, v, isFirstTriangle = bu, bv, bIsFirstTriangle
    end
  end

  -- Update emitter data.
  local speed = ribbon.speed
  local segIdx = emit.bestSeg
  local twoSegIdx = segIdx * 2
  local i1, i2, i3, i4 = twoSegIdx - 1, twoSegIdx, twoSegIdx + 1, twoSegIdx + 2
  -- The pair index is segIdx, since i1 is 2 * segIdx - 1 and the index is always whole.
  local w1, w2 = ribbon.widths[segIdx], ribbon.widths[segIdx + 1]
  local d1, d2, d3, d4 = ribbon.depths[i1], ribbon.depths[i2], ribbon.depths[i3], ribbon.depths[i4]
  local width, depth = nil, nil
  local w = max(0, 1.0 - u - v)
  if isFirstTriangle then
    width = w1 * (u + v) + w2 * w
    depth = u * d1 + v * d2 + w * d3
  else
    width = u * w1 + w2 * (v + w)
    depth = u * d2 + v * d3 + w * d4
  end
  -- emit.pos is the closest point found by the search above, so its distance from p is sqrt(bestSqDist).
  local dist
  if ribbon.isQuadAndVolume then
    dist = max(0.0, sqrt(bestSqDist) - (depth * 0.5))                                           -- Distance to the ellipsoid here (not the surface).
  else
    dist = sqrt(bestSqDist)                                                                      -- Distance to the surface here (no ellipsoid).
  end
  local volCoeff = 1 / max(1, sqrt(dist))
  local volumeC = (speedCoeff * speed) * min(100, widthCoeff * width) * min(5, depthCoeff * depth)
  local volumeC = volCoeff * volumeC / (volumeC + expOffset)

  if muteFlag then
    volumeC = 0.0
  end
  emit.vol = volumeC

  local eventName = emit.eventNameStr
  local axisEntry = axis[eventName]
  if axisEntry == nil then
    axisEntry = axisCache[eventName]
    if axisEntry == nil then
      axisEntry = { pos = vec3() }
      axisCache[eventName] = axisEntry
    end
    axisEntry.loudness = -1
    axis[eventName] = axisEntry
  end

  local loudness = volumeC / max(1, radius + 1e-10)
  if loudness > axisEntry.loudness then
    axisEntry.loudness = loudness
    axisEntry.volume = volumeC
    axisEntry.pitch = speed
    axisEntry.color = width
    axisEntry.texture = volCoeff
    axisEntry.pos:set(p)
  end
end

-- Update the center SFX emitter host.
local function updateCenterEmitter(emit, ribbon, muteFlag, axis, axisCache, u, v, isFirstTriangle, bestSqDist)
  local speed = ribbon.speed
  local segIdx = emit.bestSeg
  local twoSegIdx = segIdx * 2
  local i1, i2, i3, i4 = twoSegIdx - 1, twoSegIdx, twoSegIdx + 1, twoSegIdx + 2
  -- The pair index is segIdx, since i1 is 2 * segIdx - 1 and the index is always whole.
  local w1, w2 = ribbon.widths[segIdx], ribbon.widths[segIdx + 1]
  local d1, d2, d3, d4 = ribbon.depths[i1], ribbon.depths[i2], ribbon.depths[i3], ribbon.depths[i4]
  local width, depth = nil, nil
  local w = max(0, 1.0 - u - v)
  if isFirstTriangle then
    width = w1 * (u + v) + w2 * w
    depth = u * d1 + v * d2 + w * d3
  else
    width = u * w1 + w2 * (v + w)
    depth = u * d2 + v * d3 + w * d4
  end
  -- emit.pos is the closest point found by the inner search, so its distance from the listener is sqrt(bestSqDist).
  local dist = max(0.0, sqrt(bestSqDist) - (depth * 0.5))
  local volCoeff = 1.0 / max(1.0, sqrt(dist))
  local volumeC = (speedCoeff * speed) * min(100, widthCoeff * width) * min(5, depthCoeff * depth)
  local volumeC = volCoeff * volumeC / (volumeC + expOffset)

  if muteFlag then
    volumeC = 0.0
  end
  emit.vol = volumeC

  local eventName = emit.eventNameStr
  local axisEntry = axis[eventName]
  if axisEntry == nil then
    axisEntry = axisCache[eventName]
    if axisEntry == nil then
      axisEntry = { pos = vec3() }
      axisCache[eventName] = axisEntry
    end
    axisEntry.loudness = -1
    axis[eventName] = axisEntry
  end

  local loudness = volumeC
  if loudness > axisEntry.loudness then
    axisEntry.loudness = loudness
    axisEntry.volume = volumeC
    axisEntry.pitch = speed
    axisEntry.color = width
    axisEntry.texture = volCoeff
    axisEntry.pos:set(emit.pos)
  end
end

-- Keeps track of the two closest ribbons seen so far this frame.
local function trackNearCandidate(key, ribbonIdx, dSq)
  local candA, candB = nearCandA, nearCandB
  if dSq < candA.dSq then
    candB.key, candB.idx, candB.dSq = candA.key, candA.idx, candA.dSq
    candA.key, candA.idx, candA.dSq = key, ribbonIdx, dSq
  elseif dSq < candB.dSq then
    candB.key, candB.idx, candB.dSq = key, ribbonIdx, dSq
  end
end

-- Frame update
local function onUpdate(dtReal, dtSim, dtRaw)
  if not ribbons or next(ribbons) == nil then
    return
  end

  -- Fetch the latest SFX listener pose.
  lPosition:set(SFXSystem.getPositionXYZ())
  lForward:set(SFXSystem.getForwardXYZ())
  lRight:set(SFXSystem.getRightXYZ())

  -- Every emitter takes its random probe on the same frame.  That probe replaces the directional one rather than
  -- adding to it, so synchronising them costs two segment tests per emitter on every frame either way.
  blueFrameTick = blueFrameTick + 1
  isBlueFrame = blueFrameTick >= blueNoiseInterval
  if isBlueFrame then
    blueFrameTick = 0
  end

  -- On first frame, populate the far list with all ribbons.
  if not next(midList) and not next(farList) and not next(nearList) then
    for i = 1, #ribbons do
      farList[ribbons[i].persistantId] = i
    end
  end

  -- Update the closest points/segments for relevant ribbons.
  -- [We update all closest points/segments of ribbons in the near/mid lists, but only one ribbon from the far list, chosen with a round robin selection].
  if next(farList) then
    farSegmentRoundRobinKey = tableRoundRobinKey(farList, farSegmentRoundRobinKey)
    local ribbonIdx = farList[farSegmentRoundRobinKey]
    local ribbon = ribbons[ribbonIdx]
    if ribbon and ribbon.isEnabled and ribbon.numSegs > 0 then
      -- The round robin visits one far ribbon per frame, so leaving it to the shared blue frame would alias against the
      -- rotation and starve some ribbons of a random probe entirely.  A directional step is useless at this range anyway.
      local innerEmitter = ribbon.emitters[1]
      local _, _, _, _, _, bestSqDist = updateInnerEmitterHost(innerEmitter, ribbon, lPosition, true)
      if (bestSqDist or innerEmitter.pos:squaredDistance(lPosition)) < nearFarLimitSq then
        midList[farSegmentRoundRobinKey] = ribbonIdx
        farList[farSegmentRoundRobinKey] = nil
      end
    end
  end

  -- Iterate over the ribbons in the near/mid lists and detect their contributions to the final audio output.
  table.clear(axes[1])
  table.clear(axes[2])
  table.clear(axes[3])
  table.clear(axes[4])
  table.clear(axes[5])
  nearCandA.key, nearCandA.dSq = nil, huge
  nearCandB.key, nearCandB.dSq = nil, huge

  -- The near ribbons get the full set of emitters, so they are the only ones which produce any audio.
  for k, ribbonIdx in pairs(nearList) do
    local ribbon = ribbons[ribbonIdx]
    local ribbonEmitters = ribbon.emitters
    local innerEmitter = ribbonEmitters[1]
    -- The inner host already measured the listener against the point it stored, so the near/far test below reuses that
    -- distance rather than measuring the same pair of points again.  It falls back when the host did not run.
    local dSq = nil
    if ribbon.isEnabled and ribbon.numSegs > 0 then
      local blueP, blueSeg, blueU, blueV, blueIsFirstTriangle, blueBestSqDist = updateInnerEmitterHost(innerEmitter, ribbon, lPosition)
      if blueP and blueBestSqDist then
        dSq = blueBestSqDist
        if ribbon.isAmbient then
          updateCenterEmitter(innerEmitter, ribbon, ribbon.isMuteA, axes[1], axesCache[1], blueU, blueV, blueIsFirstTriangle, blueBestSqDist)
        else
          local radius = max(minAxisLimit, max(1.0, sqrt(blueBestSqDist)) * radiusLength)
          tmpAxis1:setScaled2(lForward, radius)
          tmpAxis2:setScaled2(lRight, radius)
          tmpList:setAdd2(lPosition, tmpAxis1)
          updateOuterEmitterHost(ribbonEmitters[2], ribbon, tmpList, ribbon.isMuteA, blueP, blueSeg, axes[2], axesCache[2], radius)
          tmpList:setSub2(lPosition, tmpAxis1)
          updateOuterEmitterHost(ribbonEmitters[3], ribbon, tmpList, ribbon.isMuteB, blueP, blueSeg, axes[3], axesCache[3], radius)
          tmpList:setAdd2(lPosition, tmpAxis2)
          updateOuterEmitterHost(ribbonEmitters[4], ribbon, tmpList, ribbon.isMuteC, blueP, blueSeg, axes[4], axesCache[4], radius)
          tmpList:setSub2(lPosition, tmpAxis2)
          updateOuterEmitterHost(ribbonEmitters[5], ribbon, tmpList, ribbon.isMuteD, blueP, blueSeg, axes[5], axesCache[5], radius)
        end
      end
    end

    dSq = dSq or innerEmitter.pos:squaredDistance(lPosition)
    if dSq > nearFarLimitSq then
      -- The ribbon is too far away now, so move it from the near list to the far list.
      farList[k] = ribbonIdx
      nearList[k] = nil
    else
      trackNearCandidate(k, ribbonIdx, dSq)
    end
  end

  -- The mid ribbons only refresh their inner point, which keeps their distances current for the near selection below.
  for k, ribbonIdx in pairs(midList) do
    local ribbon = ribbons[ribbonIdx]
    local innerEmitter = ribbon.emitters[1]
    local dSq = nil
    if ribbon.isEnabled and ribbon.numSegs > 0 then
      local _, _, _, _, _, bestSqDist = updateInnerEmitterHost(innerEmitter, ribbon, lPosition)
      dSq = bestSqDist
    end

    dSq = dSq or innerEmitter.pos:squaredDistance(lPosition)
    if dSq > nearFarLimitSq then
      -- The ribbon is too far away now, so move it from the mid list to the far list.
      farList[k] = ribbonIdx
      midList[k] = nil
    else
      trackNearCandidate(k, ribbonIdx, dSq)
    end
  end

  -- Re-select the near list as the two closest ribbons.  Every distance compared above was refreshed this frame, so the
  -- near and mid ribbons rank against each other on equal terms.
  local candA, candB = nearCandA, nearCandB
  for k, ribbonIdx in pairs(nearList) do
    if k ~= candA.key and k ~= candB.key then
      midList[k] = ribbonIdx
      nearList[k] = nil
    end
  end
  if candA.key and not nearList[candA.key] then
    nearList[candA.key] = candA.idx
    midList[candA.key] = nil
  end
  if candB.key and not nearList[candB.key] then
    nearList[candB.key] = candB.idx
    midList[candB.key] = nil
  end

  -- Update and push the RTPC channel outputs for all dynamic SFX emitters in a single pass.
  -- Emitters that produced audio this frame take their values from the near-list ribbons;
  -- the rest are silenced (volume reset, other channels left as-is).
  for i = 1, 5 do
    local axis = axes[i]
    local sfxAxis = sfxEmitters[i]
    -- Create any emitters that first appeared this frame
    for eventName, event in pairs(axis) do
      if sfxAxis[eventName] == nil then
        sfxAxis[eventName] = {
          emitter = createSfxEmitter(eventName),
          vol = 0.0,
          pitch = 0.0,
          color = 0.0,
          texture = 0.0,
          pos = vec3(0.0, 0.0) }
      end
    end
    for eventName, sfxEmitterOnAxis in pairs(sfxAxis) do
      local event = axis[eventName]
      if event then
        sfxEmitterOnAxis.vol = event.volume
        sfxEmitterOnAxis.pitch = event.pitch
        sfxEmitterOnAxis.color = event.color
        sfxEmitterOnAxis.texture = event.texture
        sfxEmitterOnAxis.pos = event.pos
      else
        sfxEmitterOnAxis.vol = 0.0
      end
      local sfxEmitterObj = sfxEmitterOnAxis.emitter
      if simObjectExists(sfxEmitterObj) then
        if sfxEmitterOnAxis.vol ~= 0 then
          sfxEmitterObj:setPosition(sfxEmitterOnAxis.pos)
        end
        sfxEmitterObj:setVolumePitchCT(
          sfxEmitterOnAxis.vol,
          sfxEmitterOnAxis.pitch,
          sfxEmitterOnAxis.color,
          sfxEmitterOnAxis.texture)
      end
    end
  end
end

-- Re-computes the ribbon names map.
local function recomputeMap()
  table.clear(ribbonNames)
  for i = 1, #ribbons do
    ribbonNames[ribbons[i].persistantId] = true
  end
end

-- Clears all SFX emitters.
local function clearAllSFXEmitters()
  for i = 1, 5 do
    for _, sfxEmitterByAxis in pairs(sfxEmitters[i]) do
      if sfxEmitterByAxis.emitter and simObjectExists(sfxEmitterByAxis.emitter) then
        sfxEmitterByAxis.emitter:delete()
      end
    end
  end
  sfxEmitters = { {}, {}, {}, {}, {} }
end

-- Removes the ribbon with the given index.
local function removeRibbon(idx)
  clearAllSFXEmitters()
  local ribbon = ribbons[idx]
  ribbonNames[ribbon.persistantId] = nil
  table.remove(ribbons, idx)
  table.clear(nearList)
  table.clear(midList)
  table.clear(farList)
end

-- Updates the ribbon properties after the ribbon has been updated (eg a new node added, node deleted, etc).
local function updateRibbonData(ribbon)
  for i = 1, 5 do
    local emit = ribbon.emitters[i]
    emit.bestSeg = 1
    emit.dir = 1
  end

  ribbon.numSegs = max(0, ((#ribbon.nodes - 4) * 0.5) + 1)

  -- Compute the pair widths.
  ribbon.widths = ribbon.widths or {}
  table.clear(ribbon.widths)
  for i = 1, #ribbon.nodes, 2 do
    table.insert(ribbon.widths, ribbon.nodes[i]:distance(ribbon.nodes[i + 1]))
  end
end

-- Creates an SFX Emitter host object (stores the position and other relevant data for a dynamic SFX emitter).
local function createEmitterHost(eventName)
  return {
    bestSeg = 0,
    dir = 1,
    vol = 0,
    pos = vec3(huge, huge, huge),
    bN = 0,
    eventNameStr = eventName }
end

-- Serializes the ribbons (full).
local function serializeRibbons()
  local ribbonsCopy = {}
  if ribbons then
    for i = 1, #ribbons do
      local ribbon = ribbons[i]
      local nodesSer = {}
      if ribbon.nodes then
        for j = 1, #ribbon.nodes do
          local nd = ribbon.nodes[j]
          nodesSer[j] = { x = nd.x, y = nd.y, z = nd.z }
        end
      end
      ribbonsCopy[i] = {
        persistantId = ribbon.persistantId,
        name = ribbon.name,
        isMuteA = ribbon.isMuteA,
        isMuteB = ribbon.isMuteB,
        isMuteC = ribbon.isMuteC,
        isMuteD = ribbon.isMuteD,
        isEnabled = ribbon.isEnabled,
        isAmbient = ribbon.isAmbient,
        isUpRibbon = ribbon.isUpRibbon,
        isTopActive = ribbon.isTopActive,
        isQuadAndVolume = ribbon.isQuadAndVolume,
        nodes = nodesSer,
        depths = ribbon.depths,
        speed = ribbon.speed,
        eventNameA = ribbon.emitters[1].eventNameStr,
        eventNameF = ribbon.emitters[2].eventNameStr,
        eventNameB = ribbon.emitters[3].eventNameStr,
        eventNameR = ribbon.emitters[4].eventNameStr,
        eventNameL = ribbon.emitters[5].eventNameStr,
      }
    end
  end
  return ribbonsCopy
end

-- Writes the ribbons to a file in the AVRO .json style.
local function writeRibbonsToFile(filename, ribbons)
  local file = io.open(filename, "w")
  if not file then
    log('E', logTag, "Could not open file for writing: " .. filename)
    return
  end

  local indices = {}
  for i = 1, #ribbons do
    indices[i] = i
  end
  table.sort(indices, function(a, b)
    local ra, rb = ribbons[a], ribbons[b]
    local na = string.lower(ra.name or '')
    local nb = string.lower(rb.name or '')
    if na == nb then
      return (ra.persistantId or '') < (rb.persistantId or '')
    end
    return na < nb
  end)

  for _, ribbonIdx in ipairs(indices) do
    local ribbon = ribbons[ribbonIdx]
    local nodesSer = {}

    -- Serialise the nodes inline.
    for i = 1, #ribbon.nodes do
      local nd = ribbon.nodes[i]
      table.insert(nodesSer, string.format('{"x":%.10g,"y":%.10g,"z":%.10g,"depth":%.10g}', nd.x, nd.y, nd.z, ribbon.depths[i]))
    end

    -- Convert ribbon to JSON-like format (preserves key order).
    local isEnabled = 0
    if ribbon.isEnabled then
      isEnabled = 1
    end
    local isAmbient = 0
    if ribbon.isAmbient then
      isAmbient = 1
    end
    local isUpRibbon = 0
    if ribbon.isUpRibbon then
      isUpRibbon = 1
    end
    local isTopActive = 0
    if ribbon.isTopActive then
      isTopActive = 1
    end
    local isQuadAndVolume = 0
    if ribbon.isQuadAndVolume then
      isQuadAndVolume = 1
    end
    local jsonLine = string.format(
      '{"persistantId":"%s","name":"%s","isEnabled":%s,"isAmbient":%s,"isUpRibbon":%s,"isTopActive":%s,"isQuadAndVolume":%s,"speed":%.10g,' ..
      '"eventNameA":"%s","eventNameF":"%s","eventNameB":"%s","eventNameR":"%s","eventNameL":"%s",' ..
      '"nodes":[%s]}',
      ribbon.persistantId,
      ribbon.name,
      isEnabled,
      isAmbient,
      isUpRibbon,
      isTopActive,
      isQuadAndVolume,
      ribbon.speed,
      ribbon.emitters[1].eventNameStr,
      ribbon.emitters[2].eventNameStr,
      ribbon.emitters[3].eventNameStr,
      ribbon.emitters[4].eventNameStr,
      ribbon.emitters[5].eventNameStr,
      table.concat(nodesSer, ",")
    )

    file:write(jsonLine .. "\n")
  end
  file:close()
end

-- Reads the ribbons from file.
local function readRibbonsFromFile(filename)
  ribbons = {}
  local file = io.open(filename, "r")
  if not file then
    return
  end

  for line in file:lines() do
    local ribbon = {}
    local ribbonData = jsonDecode(line)
    if ribbonData then
      -- Rebuild the ribbon table.
      ribbon.persistantId = ribbonData.persistantId
      ribbon.name = ribbonData.name
      ribbon.isEnabled = ribbonData.isEnabled > 0.5
      ribbon.isAmbient = ribbonData.isAmbient > 0.5
      ribbon.isUpRibbon = ribbonData.isUpRibbon > 0.5
      ribbon.isTopActive = ribbonData.isTopActive > 0.5
      ribbon.isQuadAndVolume = ribbonData.isQuadAndVolume > 0.5
      ribbon.speed = ribbonData.speed
      ribbon.emitters =
        {
          createEmitterHost(ribbonData.eventNameA),
          createEmitterHost(ribbonData.eventNameF),
          createEmitterHost(ribbonData.eventNameB),
          createEmitterHost(ribbonData.eventNameR),
          createEmitterHost(ribbonData.eventNameL),
        }

      -- Rebuild the nodes table.
      ribbon.nodes = {}
      ribbon.depths = {}
      for _, nd in ipairs(ribbonData.nodes) do
        table.insert(ribbon.nodes, vec3(nd.x, nd.y, nd.z))
        table.insert(ribbon.depths, nd.depth)
      end
      updateRibbonData(ribbon)
      table.insert(ribbons, ribbon)
    end
  end
  file:close()
  recomputeMap()
end

-- Serializes the ribbons.
local function onSerialize()
  if not ribbons or #ribbons < 1 then
    return                                                                                          -- If there is no dynamic SFX emitter data, there is nothing to do.
  end

  local serializedribbonData = serializeRibbons()
  for j = #ribbons, 1, -1 do                                                                        -- First delete all the emitters.
    removeRibbon(j)
  end
  return serializedribbonData
end

-- Deserializes the ribbons.
local function onDeserialized(data)
  if not data then
    return                                                                                          -- If there is no dynamic SFX emitter data, there is nothing to do.
  end
  ribbons = ribbons or {}
  for i = 1, #data do
    local ribbon = data[i]
    local nodesCopy = {}
    if ribbon.nodes then
      for j = 1, #ribbon.nodes do
        local nd = ribbon.nodes[j]
        nodesCopy[j] = vec3(nd.x, nd.y, nd.z)
      end
    end

    local isMuteA, isMuteB, isMuteC, isMuteD = false, false, false, false
    if ribbon.isMuteA then isMuteA = ribbon.isMuteA end
    if ribbon.isMuteB then isMuteB = ribbon.isMuteB end
    if ribbon.isMuteC then isMuteC = ribbon.isMuteC end
    if ribbon.isMuteD then isMuteD = ribbon.isMuteD end

    ribbons[i] = {
      persistantId = ribbon.persistantId,
      name = ribbon.name,
      isEnabled = ribbon.isEnabled,
      isAmbient = ribbon.isAmbient,
      isUpRibbon = ribbon.isUpRibbon,
      isTopActive = ribbon.isTopActive,
      isQuadAndVolume = ribbon.isQuadAndVolume,
      isMuteA = isMuteA, isMuteB = isMuteB, isMuteC = isMuteC, isMuteD = isMuteD,
      nodes = nodesCopy,
      depths = ribbon.depths,
      speed = ribbon.speed,
      emitters =
        {
          createEmitterHost(ribbon.eventNameA),
          createEmitterHost(ribbon.eventNameF),
          createEmitterHost(ribbon.eventNameB),
          createEmitterHost(ribbon.eventNameR),
          createEmitterHost(ribbon.eventNameL),
        }
    }
    updateRibbonData(ribbons[i])
  end
  recomputeMap()
end

-- Called once on level save
local function onEditorBeforeSaveLevel()
  local levelName = getCurrentLevelIdentifier()
  if levelName and ribbons then
    local filepath = "levels/" .. levelName .. "/dynamicAudioEmitters/" .. diskFileName
    writeRibbonsToFile(filepath, ribbons)
  end
end

-- Deletes all SFX emitters and clears the ribbon state.
local function resetRibbons()
  clearAllSFXEmitters()
  if ribbons then
    table.clear(ribbons)
  else
    ribbons = {}
  end
  table.clear(ribbonNames)
  table.clear(nearList)
  table.clear(midList)
  table.clear(farList)
end

-- Called once on level load.
local function onClientCustomObjectSpawning()
  resetRibbons()
  local levelName = getCurrentLevelIdentifier()
  if levelName then
    local filepath = "levels/" .. levelName .. "/dynamicAudioEmitters/" .. diskFileName
    readRibbonsFromFile(filepath)
  end
end

-- Clears the near, mid and far lists.
local function clearNearFarLists()
  table.clear(nearList)
  table.clear(midList)
  table.clear(farList)
end

-- Clears the ribbon names map.
local function clearRibbonNames() table.clear(ribbonNames) end

-- Getters/setters.
local function getRibbons() return ribbons end
local function setRibbons(val) ribbons = val end
local function getRibbonNames() return ribbonNames end
local function getNearList() return nearList end
local function getMidList() return midList end
local function getFarList() return farList end
local function getSfxEmitters() return sfxEmitters end


-- Public interface.
M.onUpdate =                                              onUpdate
M.onSerialize =                                           onSerialize
M.onDeserialized =                                        onDeserialized
M.onEditorBeforeSaveLevel =                               onEditorBeforeSaveLevel
M.onClientCustomObjectSpawning =                          onClientCustomObjectSpawning
M.onClientEndMission =                                    resetRibbons
M.onExit =                                                clearAllSFXEmitters

M.createEmitterHost =                                     createEmitterHost
M.updateRibbonData =                                      updateRibbonData
M.removeRibbon =                                          removeRibbon
M.recomputeMap =                                          recomputeMap
M.clearAllSFXEmitters =                                   clearAllSFXEmitters
M.clearNearFarLists =                                     clearNearFarLists
M.clearRibbonNames =                                      clearRibbonNames

M.getRibbons =                                            getRibbons
M.setRibbons =                                            setRibbons
M.getRibbonNames =                                        getRibbonNames
M.getNearList =                                           getNearList
M.getMidList =                                            getMidList
M.getFarList =                                            getFarList
M.getSfxEmitters =                                        getSfxEmitters

return M