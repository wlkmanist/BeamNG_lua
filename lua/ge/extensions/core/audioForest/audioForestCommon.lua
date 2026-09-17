-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- Module dependencies.
local kdTreePoint3D = require('kdtreepoint3d')

-- Module constants.
local abs, floor = math.abs, math.floor
local rshift = bit.rshift

-- Internal node-cloud defaults.
local defaultCfg = {
  minNodeSpacing = 20.0,
  thinningOuterRadiusMul = 1.5,
  nodeHeightBlend = 0.50,
  classT0 = 1 / 3,
  classT1 = 2 / 3,
  volumeClassPercentile = 0.95,
  pitchNormPercentile = 0.95,
}

-- Thinning priority queue.
-- One queue entry is stored across these arrays at the same index.
-- Priority: neighbour count desc, height score desc, candidate id asc.
local queueCandidateId, queueNeighbourCount, queueHeightScore = {}, {}, {}
local queueLength = 0

local function clearThinningQueue()
  table.clear(queueCandidateId)
  table.clear(queueNeighbourCount)
  table.clear(queueHeightScore)
  queueLength = 0
end

local function pushThinningCandidate(candidateId, neighbourCount, heightScore)
  local i = queueLength + 1
  queueLength = i
  while i > 1 do
    local p = rshift(i, 1)
    local parentId, parentCount, parentScore = queueCandidateId[p], queueNeighbourCount[p], queueHeightScore[p]
    if neighbourCount < parentCount or (neighbourCount == parentCount and (heightScore < parentScore or (heightScore == parentScore and candidateId >= parentId))) then
      break
    end
    queueCandidateId[i], queueNeighbourCount[i], queueHeightScore[i] = parentId, parentCount, parentScore
    i = p
  end
  queueCandidateId[i], queueNeighbourCount[i], queueHeightScore[i] = candidateId, neighbourCount, heightScore
end

local function popThinningCandidate()
  local n = queueLength
  if n <= 0 then
    return nil
  end

  local resultId, resultCount, resultScore = queueCandidateId[1], queueNeighbourCount[1], queueHeightScore[1]
  local lastId, lastCount, lastScore = queueCandidateId[n], queueNeighbourCount[n], queueHeightScore[n]
  queueCandidateId[n], queueNeighbourCount[n], queueHeightScore[n] = nil, nil, nil
  n = n - 1
  queueLength = n

  if n > 0 then
    local p, child = 1, 2
    while child <= n do
      local best = child
      local bestId, bestCount, bestScore = queueCandidateId[child], queueNeighbourCount[child], queueHeightScore[child]
      local r = child + 1
      if r <= n then
        local rightId, rightCount, rightScore = queueCandidateId[r], queueNeighbourCount[r], queueHeightScore[r]
        if rightCount > bestCount or (rightCount == bestCount and (rightScore > bestScore or (rightScore == bestScore and rightId < bestId))) then
          best = r
          bestId, bestCount, bestScore = rightId, rightCount, rightScore
        end
      end
      if lastCount > bestCount or (lastCount == bestCount and (lastScore > bestScore or (lastScore == bestScore and lastId < bestId))) then
        break
      end
      queueCandidateId[p], queueNeighbourCount[p], queueHeightScore[p] = bestId, bestCount, bestScore
      p = best
      child = p + p
    end
    queueCandidateId[p], queueNeighbourCount[p], queueHeightScore[p] = lastId, lastCount, lastScore
  end

  return resultId, resultCount, resultScore
end

local function popValidThinningCandidate(done, neighbourCount)
  while queueLength > 0 do
    local candidateId, queuedNeighbourCount = popThinningCandidate()
    if candidateId and (not done[candidateId]) and ((neighbourCount[candidateId] or 0) == queuedNeighbourCount) then
      return candidateId
    end
  end
end

-- Resolves forest item scale to axis components.
local function getScale3(item)
  local s = item and item.getScale and item:getScale() or nil
  if type(s) == 'number' then
    return s, s, s
  end
  if s then
    return s.x or 1.0, s.y or 1.0, s.z or 1.0
  end
  return 1.0, 1.0, 1.0
end

-- Computes the scaled object-box volume used for default classing.
local function getItemVolume(item)
  local box = item and item.getObjBox and item:getObjBox() or nil
  if not box then
    return 0.0
  end
  local sx, sy, sz = getScale3(item)
  local minExtents, maxExtents = box.minExtents, box.maxExtents
  local dx = (maxExtents.x - minExtents.x) * sx
  local dy = (maxExtents.y - minExtents.y) * sy
  local dz = (maxExtents.z - minExtents.z) * sz
  return abs(dx) * abs(dy) * abs(dz)
end

-- Computes a percentile value from an array prefix.
local function computePercentile(values, n, percentile)
  if not values or n < 1 then
    return 0.0
  end
  table.sort(values)
  local idx = floor((n - 1) * (percentile or 0.95)) + 1
  return values[idx] or 0.0
end

-- Converts normalized volume to a default S/M/L class id.
local function computeDefaultClassFromNormVol(normVol, classT0, classT1)
  local t0, t1 = classT0 or defaultCfg.classT0, classT1 or defaultCfg.classT1
  if t0 > t1 then
    t0, t1 = t1, t0
  end
  if normVol < t0 then return 1 end
  if normVol < t1 then return 2 end
  return 3
end

-- Converts a class id to the normalized audio value.
local function classIdToVal(cls)
  if cls == 1 then return 0.0 end
  if cls == 2 then return 0.5 end
  return 1.0
end

-- Creates an empty node cloud result.
local function emptyCloud(minSpacing)
  return {
    minNodeSpacing = minSpacing or defaultCfg.minNodeSpacing,
    nodeCount = 0,
    nodeX = {},
    nodeY = {},
    nodeZ = {},
    nodeDepth = {},
    nodeAvgNormVol = {},
    nodeSourceCount = {},
    pitchDensityInv = 0.0,
    kdNodes = nil,
  }
end

local function startRuntimePrepass(forestObj, st)
  local data = forestObj and forestObj.getData and forestObj:getData() or nil
  local all = data and data.getItems and data:getItems() or nil
  return {
    all = all,
    allCount = all and #all or 0,
    i = 1,
    includeByShape = (st and st.includeByShape) or {},
    shapeByData = {},
    shapeVol = {},
    shapeMaxZ = {},
    includedItem = {},
    includedShape = {},
    volList = {},
    volN = 0,
    itemCount = 0,
    isReady = false,
  }
end

local function stepRuntimePrepass(p, maxSteps)
  local steps = 0
  maxSteps = maxSteps or 10000
  while p and p.i <= p.allCount and steps < maxSteps do
    local item = p.all[p.i]
    local itemData = item:getData()
    local shape = p.shapeByData[itemData]
    if shape == nil then
      shape = itemData:getShapeFile()
      p.shapeByData[itemData] = shape
    end
    if p.includeByShape[shape] ~= false then
      p.itemCount = p.itemCount + 1
      p.includedItem[p.itemCount] = item
      p.includedShape[p.itemCount] = shape
      if p.shapeVol[shape] == nil then
        local box = item:getObjBox()
        local vol = 0.0
        if box then
          local sx, sy, sz = getScale3(item)
          local minExtents, maxExtents = box.minExtents, box.maxExtents
          vol = abs((maxExtents.x - minExtents.x) * sx) * abs((maxExtents.y - minExtents.y) * sy) * abs((maxExtents.z - minExtents.z) * sz)
          p.shapeMaxZ[shape] = maxExtents.z
        else
          p.shapeMaxZ[shape] = 0.0
        end
        p.shapeVol[shape] = vol
        p.volN = p.volN + 1
        p.volList[p.volN] = vol
      end
    end
    p.i = p.i + 1
    steps = steps + 1
  end
  if p and p.i > p.allCount then
    p.isReady = true
  end
  return p and p.isReady
end

-- Builds a shared runtime/editor audio node cloud from forest items.
local function buildNodeCloudFromForest(forestObj, st, cfg, opts)
  cfg = cfg or defaultCfg
  opts = opts or {}

  local minSpacing = cfg.minNodeSpacing or defaultCfg.minNodeSpacing
  local outerRadiusMul = cfg.thinningOuterRadiusMul or defaultCfg.thinningOuterRadiusMul
  local zBlend = cfg.nodeHeightBlend or defaultCfg.nodeHeightBlend
  local classT0 = cfg.classT0 or defaultCfg.classT0
  local classT1 = cfg.classT1 or defaultCfg.classT1
  local volumeClassPercentile = cfg.volumeClassPercentile or defaultCfg.volumeClassPercentile
  local pitchDensityPercentile = cfg.pitchDensityPercentile or cfg.pitchNormPercentile or defaultCfg.pitchNormPercentile

  local classSelByShape = (st and st.classSelByShape) or {}
  local classOverrideByShape = (st and st.classOverrideByShape) or {}

  local prepass = opts.prepass or startRuntimePrepass(forestObj, st)
  while not prepass.isReady do
    stepRuntimePrepass(prepass, 1e300)
  end
  local shapeVol, shapeMaxZ = prepass.shapeVol, prepass.shapeMaxZ
  local includedItem, includedShape = prepass.includedItem, prepass.includedShape
  local volList, volN, itemCount = prepass.volList, prepass.volN, prepass.itemCount

  if itemCount < 1 then
    return emptyCloud(minSpacing)
  end

  local volP95 = computePercentile(volList, volN, volumeClassPercentile)
  if volP95 <= 0.0 then
    volP95 = 1.0
  end

  local shapeClassVal = {}
  for shape, vol in pairs(shapeVol) do
    local n = (vol or 0.0) / volP95
    if n < 0.0 then n = 0.0 elseif n > 1.0 then n = 1.0 end
    local cls = computeDefaultClassFromNormVol(n, classT0, classT1)
    if classOverrideByShape[shape] then
      local o = tonumber(classSelByShape[shape])
      if o == 1 or o == 2 or o == 3 then
        cls = o
      end
    end
    shapeClassVal[shape] = classIdToVal(cls)
  end

  local minSpacingSq = minSpacing * minSpacing
  local outerRadius = minSpacing * outerRadiusMul
  local outerRadiusSq = outerRadius * outerRadius

  local itemX, itemY, itemTerrZ, itemTopZ, itemClassVal, itemRow = {}, {}, {}, {}, {}, {}
  local kdItems = kdTreePoint3D.new(itemCount)
  local shapeToRow = opts.shapeToRow
  local includeEditorFields = opts.includeEditorFields and true or false
  local k = 0

  -- Pass 2 builds item arrays and an item KD tree.
  for i = 1, itemCount do
    local item = includedItem[i]
    local shape = includedShape[i]
    k = k + 1
    local pos = item:getPosition()
    local x, y = pos.x, pos.y
    local terrZ = pos.z or 0.0
    local _, _, sz = getScale3(item)
    local topZ = terrZ + (shapeMaxZ[shape] or 0.0) * sz
    itemX[k], itemY[k], itemTerrZ[k], itemTopZ[k], itemClassVal[k] = x, y, terrZ, topZ, shapeClassVal[shape] or 0.5
    if includeEditorFields and shapeToRow then
      itemRow[k] = shapeToRow[shape]
    end
    kdItems:preLoad(k, x, y, terrZ)
  end

  kdItems:build()

  local score = {}
  for i = 1, itemCount do
    local h = (itemTopZ[i] or 0.0) - (itemTerrZ[i] or 0.0)
    if h < 0.0 then h = 0.0 end
    score[i] = h
  end

  local done = {}
  local neighbourCount = {}
  local seed = 1
  local nodeX, nodeY, nodeZ, nodeDepth, nodeAvgNormVol, nodeSourceCount = {}, {}, {}, {}, {}, {}
  local nodeTypeRow = includeEditorFields and {} or nil
  local nodeClassId = includeEditorFields and {} or nil
  local nodeCount = 0
  local sourceCountHist, maxSourceCount = {}, 0
  clearThinningQueue()

  -- Pass 3 greedily thins items into audio nodes.
  while true do
    local best = popValidThinningCandidate(done, neighbourCount)
    if not best then
      while seed <= itemCount and done[seed] do
        seed = seed + 1
      end
      if seed > itemCount then
        break
      end
      best = seed
    end

    done[best] = true
    nodeCount = nodeCount + 1
    nodeX[nodeCount] = itemX[best]
    nodeY[nodeCount] = itemY[best]
    nodeZ[nodeCount] = itemTerrZ[best] or 0.0
    nodeDepth[nodeCount] = (score[best] or 0.0) * zBlend
    if includeEditorFields then
      nodeTypeRow[nodeCount] = itemRow[best]
    end

    local sumNorm = itemClassVal[best] or 0.5
    local normCount = 1
    local bx, by, bz = itemX[best], itemY[best], itemTerrZ[best] or 0.0
    local qx0, qy0, qz0 = bx - outerRadius, by - outerRadius, bz - outerRadius
    local qx1, qy1, qz1 = bx + outerRadius, by + outerRadius, bz + outerRadius

    for j in kdItems:queryNotNested(qx0, qy0, qz0, qx1, qy1, qz1) do
      if j ~= best and (not done[j]) then
        local dx = itemX[j] - bx
        local dy = itemY[j] - by
        local dz = (itemTerrZ[j] or 0.0) - bz
        local d = dx * dx + dy * dy + dz * dz
        if d <= minSpacingSq then
          done[j] = true
          sumNorm = sumNorm + (itemClassVal[j] or 0.5)
          normCount = normCount + 1
        elseif d <= outerRadiusSq then
          local nc = (neighbourCount[j] or 0) + 1
          neighbourCount[j] = nc
          pushThinningCandidate(j, nc, score[j] or 0.0)
        end
      end
    end

    local avg = (normCount > 0) and (sumNorm / normCount) or 0.0
    nodeAvgNormVol[nodeCount] = avg
    nodeSourceCount[nodeCount] = normCount
    sourceCountHist[normCount] = (sourceCountHist[normCount] or 0) + 1
    if normCount > maxSourceCount then
      maxSourceCount = normCount
    end
    if includeEditorFields then
      nodeClassId[nodeCount] = computeDefaultClassFromNormVol(avg, classT0, classT1)
    end
  end

  local targetSourceCountRank = floor((nodeCount - 1) * pitchDensityPercentile) + 1
  local sourceCountRank = 0
  local sourceP95 = 1
  for i = 1, maxSourceCount do
    sourceCountRank = sourceCountRank + (sourceCountHist[i] or 0)
    if sourceCountRank >= targetSourceCountRank then
      sourceP95 = i
      break
    end
  end
  local pitchDensityInv = sourceP95 > 0 and (1.0 / sourceP95) or 0.0

  local kdNodes = kdTreePoint3D.new(nodeCount)

  -- Pass 4 builds the runtime KD tree from thinned nodes.
  for i = 1, nodeCount do
    local x, y = nodeX[i], nodeY[i]
    local zT = (nodeZ[i] or 0.0) + (nodeDepth[i] or 0.0)
    kdNodes:preLoad(i, x, y, zT)
  end

  kdNodes:build()

  return {
    minNodeSpacing = minSpacing,
    nodeCount = nodeCount,
    nodeX = nodeX,
    nodeY = nodeY,
    nodeZ = nodeZ,
    nodeDepth = nodeDepth,
    nodeAvgNormVol = nodeAvgNormVol,
    nodeSourceCount = nodeSourceCount,
    pitchDensityInv = pitchDensityInv,
    nodeTypeRow = nodeTypeRow,
    nodeClassId = nodeClassId,
    kdNodes = kdNodes,
  }
end

-- Public interface.
M.getItemVolume = getItemVolume
M.computeDefaultClassFromNormVol = computeDefaultClassFromNormVol
M.startRuntimePrepass = startRuntimePrepass
M.stepRuntimePrepass = stepRuntimePrepass
M.buildNodeCloudFromForest = buildNodeCloudFromForest

return M