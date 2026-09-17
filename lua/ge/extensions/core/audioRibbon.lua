-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Module constants.
local nearFarLimitSq = square(500.0) -- The maximum distance for near-field dynamic SFX emitters
local radiusLength = 0.5 -- The length of the radius multiplier.
local minAxisLimit = 1.0 -- The minimum axis limit.

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
local min, max, floor, ceil, sqrt, huge = math.min, math.max, math.floor, math.ceil, math.sqrt, math.huge


-- Module state.
local ribbons = nil -- The collection of ribbons for which we compute dynamic audio emitters.
local ribbonNames = {} -- The collection of ribbon names (used for fast look-up).
local nearList, farList = {}, {} -- The collection of near and far ribbons.
local farSegmentRoundRobinKey = nil -- The key used for the round-robin on the far list segments
local axes = { {}, {}, {}, {}, {} }
local axesCache = { {}, {}, {}, {}, {} }
local sfxEmitters = { {}, {}, {}, {}, {} }
local tmp0, tmp1, tmp2, tmp3, tmp4, tmp5 = vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
local tmpAxis1, tmpAxis2, tmpList = vec3(), vec3(), vec3()
local tmpEmitP, tmpBlueP = vec3(), vec3()
local lPosition, lForward, lRight = vec3(), vec3(), vec3()


-- Compute the closest point to the given segment.
local function closestPoint(segIdx, p, ribbon, retP)
  local isAmbient = ribbon.isAmbient
  local isTopActive = ribbon.isTopActive
  local isUpRibbon = ribbon.isUpRibbon
  local isQuadAndVolume = ribbon.isQuadAndVolume

  local twoSegIdx = segIdx * 2
  local i1, i2, i3, i4 = twoSegIdx - 1, twoSegIdx, twoSegIdx + 1, twoSegIdx + 2
  local c0, c1, c2, c3 = ribbon.nodes[i1], ribbon.nodes[i2], ribbon.nodes[i3], ribbon.nodes[i4]
  local d0, d1, d2, d3 = ribbon.depths[i1], ribbon.depths[i2], ribbon.depths[i3], ribbon.depths[i4]
  tmp0:set(c0)
  tmp1:set(c1)
  tmp2:set(c2)
  tmp3:set(c3)
  if isAmbient or isQuadAndVolume then
    if not isUpRibbon then
      tmp0.z = tmp0.z + d0 * 0.5
      tmp1.z = tmp1.z + d1 * 0.5
      tmp2.z = tmp2.z + d2 * 0.5
      tmp3.z = tmp3.z + d3 * 0.5
    else
      tmp0.z = tmp0.z - d0 * 0.5
      tmp1.z = tmp1.z - d1 * 0.5
      tmp2.z = tmp2.z - d2 * 0.5
      tmp3.z = tmp3.z - d3 * 0.5
    end
  else
    if isUpRibbon and not isTopActive then
      tmp0.z = tmp0.z - d0
      tmp1.z = tmp1.z - d1
      tmp2.z = tmp2.z - d2
      tmp3.z = tmp3.z - d3
    elseif not isUpRibbon and isTopActive then
      tmp0.z = tmp0.z + d0
      tmp1.z = tmp1.z + d1
      tmp2.z = tmp2.z + d2
      tmp3.z = tmp3.z + d3
    end
  end
  local u1, v1 = p:triangleClosestPointUV(tmp0, tmp1, tmp2)
  tmp4:setTrianglePointFromUV(tmp0, tmp1, tmp2, u1 ,v1)
  local u2, v2 = p:triangleClosestPointUV(tmp1, tmp2, tmp3)
  tmp5:setTrianglePointFromUV(tmp1, tmp2, tmp3, u2 ,v2)
  local dSq1, dSq2 = p:squaredDistance(tmp4), p:squaredDistance(tmp5)
  if dSq2 < dSq1 then
    retP:set(tmp5)
    return retP, dSq2, u2, v2, true
  end
  retP:set(tmp4)
  return retP, dSq1, u1, v1, false
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
local function updateInnerEmitterHost(emit, ribbon, p)
  local pClosest, bestSqDist, u, v, isFirstTriangle = closestPoint(emit.bestSeg, p, ribbon, tmpEmitP)

  if pClosest then
    emit.pos:set(pClosest.x, pClosest.y, pClosest.z)

    -- First, try the segment directly below the current segment.
    local dSq = huge
    if emit.bestSeg > 1 then
      pClosest, dSq, u, v, isFirstTriangle = closestPoint(emit.bestSeg - 1, p, ribbon, tmpEmitP)
      if dSq < bestSqDist then
        bestSqDist = dSq
        emit.pos:set(pClosest.x, pClosest.y, pClosest.z)
        emit.bestSeg = emit.bestSeg - 1
      end
    end

    -- Second, try the segment directly above the current segment.
    if emit.bestSeg < ribbon.numSegs then
      pClosest, dSq, u, v, isFirstTriangle = closestPoint(emit.bestSeg + 1, p, ribbon, tmpEmitP)
      if dSq < bestSqDist then
        bestSqDist = dSq
        emit.pos:set(pClosest.x, pClosest.y, pClosest.z)
        emit.bestSeg = emit.bestSeg + 1
      end
    end

    -- Third, try a random segment.
    emit.bN = getBlueNoise1d(emit.bN)
    local segSample = max(1, floor(emit.bN * ribbon.numSegs))
    local pClosest, dSq = closestPoint(segSample, p, ribbon, tmpEmitP)
    if segSample ~= emit.bestSeg then
      if dSq < bestSqDist then
        bestSqDist = dSq
        emit.pos:set(pClosest.x, pClosest.y, pClosest.z)
        emit.bestSeg = segSample
      end
    end

    tmpBlueP:set(pClosest.x, pClosest.y, pClosest.z)
    return tmpBlueP, segSample, u, v, isFirstTriangle
  end
  return nil, nil, nil, nil, false
end

-- Update the given (outer) SFX emitter host.
local function updateOuterEmitterHost(emit, ribbon, p, muteFlag, bluePoint, blueSeg, axis, axisCache, radius)
  local pClosest, bestSqDist, u, v, isFirstTriangle = closestPoint(emit.bestSeg, p, ribbon, tmpEmitP)
  emit.pos:set(pClosest.x, pClosest.y, pClosest.z)

  -- First, try the segment directly below the current segment.
  local dSq = huge
  if emit.bestSeg > 1 then
    pClosest, dSq, u, v, isFirstTriangle = closestPoint(emit.bestSeg - 1, p, ribbon, tmpEmitP)
    if dSq < bestSqDist then
      bestSqDist = dSq
      emit.pos:set(pClosest.x, pClosest.y, pClosest.z)
      emit.bestSeg = emit.bestSeg - 1
    end
  end

  -- Second, try the segment directly above the current segment.
  if emit.bestSeg < ribbon.numSegs then
    pClosest, dSq, u, v, isFirstTriangle = closestPoint(emit.bestSeg + 1, p, ribbon, tmpEmitP)
    if dSq < bestSqDist then
      bestSqDist = dSq
      emit.pos:set(pClosest.x, pClosest.y, pClosest.z)
      emit.bestSeg = emit.bestSeg + 1
    end
  end

  -- Third, try a random segment.
  if blueSeg ~= emit.bestSeg then
    local dSq = p:squaredDistance(bluePoint)
    if dSq < bestSqDist then
      bestSqDist = dSq
      emit.pos:set(bluePoint.x, bluePoint.y, bluePoint.z)
      emit.bestSeg = blueSeg
    end
  end

  -- Update emitter data.
  if #ribbon.nodes > 3 then
    local speed = ribbon.speed
    local segIdx = emit.bestSeg
    local twoSegIdx = segIdx * 2
    local i1, i2, i3, i4 = twoSegIdx - 1, twoSegIdx, twoSegIdx + 1, twoSegIdx + 2
    local pairIdx = ceil(i1 * 0.5)
    local w1, w2 = ribbon.widths[pairIdx], ribbon.widths[pairIdx + 1]
    local d1, d2, d3, d4 = ribbon.depths[i1], ribbon.depths[i2], ribbon.depths[i3], ribbon.depths[i4]
    local width, depth = nil, nil
    local w = max(0, 1.0 - u - v)
    if isFirstTriangle then
      width = u * w1 + v * w1 + w * w2
      depth = u * d1 + v * d2 + w * d3
    else
      width = u * w1 + v * w2 + w * w2
      depth = u * d2 + v * d3 + w * d4
    end
    local dist = huge
    if ribbon.isQuadAndVolume then
      dist = max(0.0, p:distance(emit.pos) - (depth * 0.5))                                     -- Distance to the ellipsoid here (not the surface).
    else
      dist = p:distance(emit.pos)                                                               -- Distance to the surface here (no ellipsoid).
    end
    local volCoeff = 1 / max(1, sqrt(dist))
    local volumeC = (speedCoeff * speed) * min(100, widthCoeff * width) * min(5, depthCoeff * depth)
    local volumeC = volCoeff * volumeC / (volumeC + expOffset)

    if muteFlag then
      volumeC = 0.0
    end
    emit.vol = volumeC

    axisCache[emit.eventNameStr] = axisCache[emit.eventNameStr] or { pos = vec3() }
    if axis[emit.eventNameStr] == nil then
      axis[emit.eventNameStr] = axisCache[emit.eventNameStr]
      axis[emit.eventNameStr].loudness = -1
    end

    local loudness = volumeC / max(1, radius + 1e-10)
    if loudness > axis[emit.eventNameStr].loudness then
      axis[emit.eventNameStr].loudness = loudness
      axis[emit.eventNameStr].volume = volumeC
      axis[emit.eventNameStr].pitch = speed
      axis[emit.eventNameStr].color = width
      axis[emit.eventNameStr].texture = volCoeff
      axis[emit.eventNameStr].pos:set(p)
    end
  end
end

-- Update the center SFX emitter host.
local function updateCenterEmitter(emit, ribbon, p, muteFlag, axis, axisCache, u, v, isFirstTriangle)
  if #ribbon.nodes > 3 then
    local speed = ribbon.speed
    local segIdx = emit.bestSeg
    local twoSegIdx = segIdx * 2
    local i1, i2, i3, i4 = twoSegIdx - 1, twoSegIdx, twoSegIdx + 1, twoSegIdx + 2
    local pairIdx = ceil(i1 * 0.5)
    local w1, w2 = ribbon.widths[pairIdx], ribbon.widths[pairIdx + 1]
    local d1, d2, d3, d4 = ribbon.depths[i1], ribbon.depths[i2], ribbon.depths[i3], ribbon.depths[i4]
    local width, depth = nil, nil
    local w = max(0, 1.0 - u - v)
    if isFirstTriangle then
      width = u * w1 + v * w1 + w * w2
      depth = u * d1 + v * d2 + w * d3
    else
      width = u * w1 + v * w2 + w * w2
      depth = u * d2 + v * d3 + w * d4
    end
    local dist = max(0.0, p:distance(emit.pos) - (depth * 0.5))
    local volCoeff = 1.0 / max(1.0, sqrt(dist))
    local volumeC = (speedCoeff * speed) * min(100, widthCoeff * width) * min(5, depthCoeff * depth)
    local volumeC = volCoeff * volumeC / (volumeC + expOffset)

    if muteFlag then
      volumeC = 0.0
    end
    emit.vol = volumeC

    axisCache[emit.eventNameStr] = axisCache[emit.eventNameStr] or { pos = vec3() }
    if axis[emit.eventNameStr] == nil then
      axis[emit.eventNameStr] = axisCache[emit.eventNameStr]
      axis[emit.eventNameStr].loudness = -1
    end

    local loudness = volumeC
    if loudness > axis[emit.eventNameStr].loudness then
      axis[emit.eventNameStr].loudness = loudness
      axis[emit.eventNameStr].volume = volumeC
      axis[emit.eventNameStr].pitch = speed
      axis[emit.eventNameStr].color = width
      axis[emit.eventNameStr].texture = volCoeff
      axis[emit.eventNameStr].pos:set(emit.pos)
    end
  end
end

-- Frame update
local function onUpdate(dtReal, dtSim, dtRaw)
  if not ribbons or #ribbons < 1 then
    return
  end

  -- Fetch the latest SFX listener pose.
  lPosition:set(SFXSystem.getPositionXYZ())
  lForward:set(SFXSystem.getForwardXYZ())
  lRight:set(SFXSystem.getRightXYZ())

  -- On first frame, populate the near list with all ribbons.
  if not next(nearList) and not next(farList) then
    for i = 1, #ribbons do
      nearList[ribbons[i].persistantId] = i
    end
  end

  -- Update the closest points/segments for relevant ribbons.
  -- [We update all closest points/segments of ribbons in the near list, but only one ribbon from the far list, chosen with a round robin selection].
  if next(farList) then
    farSegmentRoundRobinKey = tableRoundRobinKey(farList, farSegmentRoundRobinKey)
    local ribbonIdx = farList[farSegmentRoundRobinKey]
    local ribbon = ribbons[ribbonIdx]
    if ribbon and ribbon.isEnabled and #ribbon.nodes > 3 then
      updateInnerEmitterHost(ribbon.emitters[1], ribbon, lPosition)
      if ribbon.emitters[1].pos:squaredDistance(lPosition) < nearFarLimitSq then
        nearList[farSegmentRoundRobinKey] = ribbonIdx
        farList[farSegmentRoundRobinKey] = nil
      end
    end
  end

  -- Iterate over the ribbons in the near list and detect their contributions to the final audio output.
  table.clear(axes[1])
  table.clear(axes[2])
  table.clear(axes[3])
  table.clear(axes[4])
  table.clear(axes[5])
  for k, ribbonIdx in pairs(nearList) do
    local ribbon = ribbons[ribbonIdx]
    if ribbon.isEnabled and #ribbon.nodes > 3 then
      local blueP, blueSeg, blueU, blueV, blueIsFirstTriangle = updateInnerEmitterHost(ribbon.emitters[1], ribbon, lPosition)
      if blueP then
        local ribbonEmitters = ribbon.emitters
        if ribbon.isAmbient then
          updateCenterEmitter(ribbonEmitters[1], ribbon, lPosition, ribbon.isMuteA, axes[1], axesCache[1], blueU, blueV, blueIsFirstTriangle)
        else
          local radius = max(minAxisLimit, max(1.0, ribbon.emitters[1].pos:distance(lPosition)) * radiusLength)
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

    -- For every ribbon in the near list, if it is too far, move it from the near list to the far list.
    if ribbon.emitters[1].pos:squaredDistance(lPosition) > nearFarLimitSq then
      farList[k] = ribbonIdx
      nearList[k] = nil
    end
  end

  -- Reset the volume RTPC channel for all existing dynamic SFX emitters, before updating them.
  for i = 1, 5 do
    for _, sfxEmitterOnAxis in pairs(sfxEmitters[i]) do
      sfxEmitterOnAxis.vol = 0.0
    end
  end

  -- Update the existing SFX emitters with the recently-computed data from the near-list ribbons.
  for i = 1, 5 do
    local axis = axes[i]
    for eventName, event in pairs(axis) do
      if sfxEmitters[i][eventName] == nil then
        sfxEmitters[i][eventName] = {
          emitter = createSfxEmitter(eventName),
          vol = 0.0,
          pitch = 0.0,
          color = 0.0,
          texture = 0.0,
          pos = vec3(0.0, 0.0) }
      end
      sfxEmitters[i][eventName].vol = event.volume
      sfxEmitters[i][eventName].pitch = event.pitch
      sfxEmitters[i][eventName].color = event.color
      sfxEmitters[i][eventName].texture = event.texture
      sfxEmitters[i][eventName].pos = event.pos
    end
  end

  -- Update the RTPC channel outputs for all existing dynamic SFX emitters.
  for i = 1, 5 do
    for _, sfxEmitterOnAxis in pairs(sfxEmitters[i]) do
      if simObjectExists(sfxEmitterOnAxis.emitter) then
        if sfxEmitterOnAxis.vol ~= 0 then
          sfxEmitterOnAxis.emitter:setPosition(sfxEmitterOnAxis.pos)
        end
        sfxEmitterOnAxis.emitter:setVolumePitchCT(
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
  table.clear(farList)
end

-- Updates the ribbon properties after the ribbon has been updated (eg a new node added, node deleted, etc).
local function updateRibbonData(ribbon)
  ribbon.emitters[1].bestSeg = 1
  ribbon.emitters[2].bestSeg = 1
  ribbon.emitters[3].bestSeg = 1
  ribbon.emitters[4].bestSeg = 1
  ribbon.emitters[5].bestSeg = 1

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

-- Called once on level load.
local function onClientCustomObjectSpawning()
  if not ribbons then
    ribbons, ribbonNames = {}, {}
  end
  if #ribbons > 0 then
    table.clear(ribbons)
    table.clear(ribbonNames)
    table.clear(nearList)
    table.clear(farList)
    sfxEmitters = { {}, {}, {}, {}, {} }
  end
  local levelName = getCurrentLevelIdentifier()
  if levelName then
    local filepath = "levels/" .. levelName .. "/dynamicAudioEmitters/" .. diskFileName
    readRibbonsFromFile(filepath)
  end
end

-- Clears the near and far lists.
local function clearNearFarLists()
  table.clear(nearList)
  table.clear(farList)
end

-- Clears the ribbon names map.
local function clearRibbonNames() table.clear(ribbonNames) end

-- Getters/setters.
local function getRibbons() return ribbons end
local function setRibbons(val) ribbons = val end
local function getRibbonNames() return ribbonNames end
local function getNearList() return nearList end
local function getFarList() return farList end
local function getSfxEmitters() return sfxEmitters end


-- Public interface.
M.onUpdate =                                              onUpdate
M.onSerialize =                                           onSerialize
M.onDeserialized =                                        onDeserialized
M.onEditorBeforeSaveLevel =                               onEditorBeforeSaveLevel
M.onClientCustomObjectSpawning =                          onClientCustomObjectSpawning
M.onExit = clearAllSFXEmitters

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
M.getFarList =                                            getFarList
M.getSfxEmitters =                                        getSfxEmitters

return M