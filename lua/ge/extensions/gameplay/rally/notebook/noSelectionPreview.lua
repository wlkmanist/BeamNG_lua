-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local cc = require('/lua/ge/extensions/gameplay/rally/util/colors')

local M = {}

local snaproadPrismHeight = 0.5
local snaproadPrismWidthDefault = 1.945
local pacenoteLabelModeAll = "all"
local overviewMaxRouteSegments = 700
local projectionSearchDistanceFactor = 1.25

local function clamp01(v)
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

local function rainbowColorAt(t)
  local x = clamp01(t or 0)
  local r = math.min(1, math.max(0, 4 * x - 2))
  local g = math.min(1, math.max(0, 2 - math.abs(4 * x - 2)))
  local b = math.min(1, math.max(0, 2 - 4 * x))
  return {r, g, b}
end

local function textColorForBackground(clr)
  local luminance = 0.299 * clr[1] + 0.587 * clr[2] + 0.114 * clr[3]
  return luminance > 0.5 and cc.clr_black or cc.clr_white
end

local function colorForDistance(totalLength, distanceAlongRoute)
  if not totalLength or totalLength <= 0 then return rainbowColorAt(0) end
  return rainbowColorAt((distanceAlongRoute or 0) / totalLength)
end

local function lowerBoundValues(values, distance)
  local lo = 1
  local hi = #values + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if values[mid] < distance then
      lo = mid + 1
    else
      hi = mid
    end
  end
  return lo
end

local function lowerBoundEntries(entries, distance)
  local lo = 1
  local hi = #entries + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if entries[mid].markerDistance < distance then
      lo = mid + 1
    else
      hi = mid
    end
  end
  return lo
end

local function buildPointDistances(points)
  local byPointId = {}
  local byIndex = {}
  local totalLength = 0

  for i, point in ipairs(points or {}) do
    byIndex[i] = totalLength
    if point.id then
      byPointId[point.id] = totalLength
    end

    local nextPoint = points[i + 1]
    if nextPoint then
      totalLength = totalLength + point.pos:distance(nextPoint.pos)
    end
  end

  return byPointId, byIndex, totalLength
end

local function distanceForPoint(model, point, fallbackIndex)
  if point and point.id and model.pointDistances[point.id] then
    return model.pointDistances[point.id]
  end
  if fallbackIndex and model.pointDistancesByIndex[fallbackIndex] then
    return model.pointDistancesByIndex[fallbackIndex]
  end
  return 0
end

local function colorForSnapResultSegment(model, location)
  if location and location.fromPoint and location.toPoint and location.fromPoint ~= location.toPoint then
    local fromDist = distanceForPoint(model, location.fromPoint, location.segmentIndex)
    local toDist = distanceForPoint(model, location.toPoint, location.segmentIndex and (location.segmentIndex + 1) or nil)
    return colorForDistance(model.totalLength, (fromDist + toDist) * 0.5)
  end

  return colorForDistance(model.totalLength, location and location.distanceAlongRoute or 0)
end

local function pacenotesForPath(path)
  return path and path.pacenotes and path.pacenotes.sorted or nil
end

local function buildPacenoteEntries(path, snaproad, model)
  local entries = {}
  local maxSpan = 0
  local pacenotes = pacenotesForPath(path)
  if not (pacenotes and snaproad and snaproad.closestSnapResult) then return entries, maxSpan end

  for index, pacenote in ipairs(pacenotes) do
    if pacenote and not pacenote.missing then
      local wpCs = pacenote:getCornerStartWaypoint()
      local wpCe = pacenote:getCornerEndWaypoint()
      local csLoc = wpCs and snaproad:closestSnapResult(wpCs.pos, true) or nil
      local ceLoc = wpCe and snaproad:closestSnapResult(wpCe.pos, true) or nil
      local startDistance = math.huge
      local endDistance = -math.huge

      if csLoc and csLoc.distanceAlongRoute then
        startDistance = math.min(startDistance, csLoc.distanceAlongRoute)
        endDistance = math.max(endDistance, csLoc.distanceAlongRoute)
      end
      if ceLoc and ceLoc.distanceAlongRoute then
        startDistance = math.min(startDistance, ceLoc.distanceAlongRoute)
        endDistance = math.max(endDistance, ceLoc.distanceAlongRoute)
      end

      local markerLoc = csLoc or ceLoc
      if markerLoc and markerLoc.distanceAlongRoute and startDistance ~= math.huge then
        local markerColor = colorForSnapResultSegment(model, markerLoc)
        table.insert(entries, {
          index = index,
          pacenote = pacenote,
          wpCs = wpCs,
          wpCe = wpCe,
          csLoc = csLoc,
          ceLoc = ceLoc,
          startDistance = startDistance,
          endDistance = endDistance,
          markerDistance = markerLoc.distanceAlongRoute,
          markerColor = markerColor,
          markerTextColor = textColorForBackground(markerColor),
        })
        maxSpan = math.max(maxSpan, math.abs(endDistance - startDistance))
      end
    end
  end

  table.sort(entries, function(a, b)
    return a.markerDistance < b.markerDistance
  end)

  return entries, maxSpan
end

local function buildModel(path, snaproad)
  if not (path and snaproad and snaproad._allPoints) then return nil end

  local points = snaproad:_allPoints()
  if not points or #points < 2 then return nil end

  local pointDistances, pointDistancesByIndex, totalLength = buildPointDistances(points)
  if totalLength <= 0 then return nil end

  local model = {
    path = path,
    snaproad = snaproad,
    points = points,
    pointDistances = pointDistances,
    pointDistancesByIndex = pointDistancesByIndex,
    totalLength = totalLength,
  }
  model.entries, model.maxEntrySpan = buildPacenoteEntries(path, snaproad, model)
  -- Empty notebooks still need a route-only model so the snaproad is visible
  -- before the first pacenote is created.
  return model
end

local function modelFor(pacenoteToolsState, path, snaproad)
  if not pacenoteToolsState then return nil end

  local cache = pacenoteToolsState._noSelectionPreviewModel
  local points = snaproad and snaproad._allPoints and snaproad:_allPoints() or nil
  if cache and cache.path == path and cache.snaproad == snaproad and cache.points == points then
    return cache
  end

  cache = buildModel(path, snaproad)
  pacenoteToolsState._noSelectionPreviewModel = cache
  return cache
end

function M.invalidate(pacenoteToolsState)
  if pacenoteToolsState then
    pacenoteToolsState._noSelectionPreviewModel = nil
    pacenoteToolsState._noSelectionPreviewRaycastCache = nil
  end
end

local function segmentProjectionToCameraRay(model, cameraPos, rayDir, best, bestDistSq, i)
  local points = model.points
  local fromPoint = points[i]
  local toPoint = points[i + 1]
  if not (fromPoint and toPoint) then return best, bestDistSq end

  local seg = toPoint.pos - fromPoint.pos
  local segLenSq = seg:dot(seg)
  if segLenSq <= 0.000001 then return best, bestDistSq end

  local fromCamera = fromPoint.pos - cameraPos
  local segDotRay = seg:dot(rayDir)
  local denom = segLenSq - segDotRay * segDotRay
  local xnorm = 0

  if math.abs(denom) > 0.000001 then
    xnorm = (segDotRay * rayDir:dot(fromCamera) - seg:dot(fromCamera)) / denom
  end
  xnorm = clamp01(xnorm)

  local snapPos = vec3(lerp(fromPoint.pos, toPoint.pos, xnorm))
  local rayDistance = math.max(0, rayDir:dot(snapPos - cameraPos))
  local rayPos = cameraPos + rayDir * rayDistance
  local distSq = snapPos:squaredDistance(rayPos)

  if distSq < bestDistSq then
    local fromDist = distanceForPoint(model, fromPoint, i)
    local toDist = distanceForPoint(model, toPoint, i + 1)
    bestDistSq = distSq
    best = {
      pos = snapPos,
      fromPoint = fromPoint,
      toPoint = toPoint,
      nearestPoint = xnorm < 0.5 and fromPoint or toPoint,
      segmentIndex = i,
      xnorm = xnorm,
      distanceAlongRoute = fromDist + (toDist - fromDist) * xnorm,
      distSq = distSq,
      rayPos = rayPos,
    }
  end

  return best, bestDistSq
end

local function searchSegmentRange(model, cameraPos, rayDir, best, bestDistSq, minIndex, maxIndex)
  local points = model.points
  minIndex = math.max(1, minIndex)
  maxIndex = math.min(#points - 1, maxIndex)
  if maxIndex < minIndex then return best, bestDistSq end

  for i = minIndex, maxIndex do
    best, bestDistSq = segmentProjectionToCameraRay(model, cameraPos, rayDir, best, bestDistSq, i)
  end
  return best, bestDistSq
end

local function searchAroundRouteDistance(model, cameraPos, rayDir, best, bestDistSq, centerDistance, searchDistance)
  if not centerDistance then return best, bestDistSq end

  local startIndex = math.max(1, lowerBoundValues(model.pointDistancesByIndex, centerDistance - searchDistance) - 1)
  local endIndex = math.min(#model.points - 1, lowerBoundValues(model.pointDistancesByIndex, centerDistance + searchDistance))
  return searchSegmentRange(model, cameraPos, rayDir, best, bestDistSq, startIndex, endIndex)
end

local function closestSnaproadLocationToCameraRay(model, cameraPos, forward, searchDistance, previousLocation, nearCameraLoc)
  local snaproad = model.snaproad
  if not (snaproad and snaproad.closestSnapResult) then return nil end
  if not (snaproad._allPoints and snaproad.routeLocationForPoint) then
    return nearCameraLoc or snaproad:closestSnapResult(cameraPos, true)
  end

  if not forward then
    return nearCameraLoc or snaproad:closestSnapResult(cameraPos, true)
  end

  local rayDir = vec3(forward)
  local rayLen = rayDir:length()
  if rayLen <= 0.0001 then
    return snaproad:closestSnapResult(cameraPos, true)
  end
  rayDir = rayDir * (1 / rayLen)

  local best = nil
  local bestDistSq = math.huge

  searchDistance = math.max(1, tonumber(searchDistance) or 1)

  nearCameraLoc = nearCameraLoc or snaproad:closestSnapResult(cameraPos, true)
  if nearCameraLoc and nearCameraLoc.distanceAlongRoute then
    best, bestDistSq = searchAroundRouteDistance(model, cameraPos, rayDir, best, bestDistSq, nearCameraLoc.distanceAlongRoute, searchDistance)
  end

  if previousLocation and previousLocation.distanceAlongRoute then
    best, bestDistSq = searchAroundRouteDistance(model, cameraPos, rayDir, best, bestDistSq, previousLocation.distanceAlongRoute, searchDistance)
  end

  if forward then
    local lookAheadLoc = snaproad:closestSnapResult(cameraPos + rayDir * searchDistance, true)
    if lookAheadLoc and lookAheadLoc.distanceAlongRoute then
      best, bestDistSq = searchAroundRouteDistance(model, cameraPos, rayDir, best, bestDistSq, lookAheadLoc.distanceAlongRoute, searchDistance)
    end
  end

  return best or nearCameraLoc or snaproad:closestSnapResult(cameraPos, true)
end

local function cameraLookSnaproadLocation(pacenoteToolsState, model, cameraPos, overviewDistance, nearCameraLoc)
  local forward = core_camera and core_camera.getForward and core_camera.getForward() or nil
  local cache = pacenoteToolsState._noSelectionPreviewRaycastCache
  if cache
      and cache.model == model
      and cache.cameraPosX == cameraPos.x
      and cache.cameraPosY == cameraPos.y
      and cache.cameraPosZ == cameraPos.z
      and cache.forwardX == (forward and forward.x or nil)
      and cache.forwardY == (forward and forward.y or nil)
      and cache.forwardZ == (forward and forward.z or nil) then
    return cache.location
  end

  local searchDistance = (tonumber(overviewDistance) or 650) * projectionSearchDistanceFactor
  local location = closestSnaproadLocationToCameraRay(model, cameraPos, forward, searchDistance, cache and cache.location or nil, nearCameraLoc)
  pacenoteToolsState._noSelectionPreviewRaycastCache = {
    model = model,
    cameraPosX = cameraPos.x,
    cameraPosY = cameraPos.y,
    cameraPosZ = cameraPos.z,
    forwardX = forward and forward.x or nil,
    forwardY = forward and forward.y or nil,
    forwardZ = forward and forward.z or nil,
    location = location,
  }
  return location
end

local function drawRoutePrism(fromPos, toPos, clr, alphaShape, prismWidth, drawOnTop)
  debugDrawer:drawSquarePrism(
    fromPos,
    toPos,
    Point2F(snaproadPrismHeight, prismWidth),
    Point2F(snaproadPrismHeight, prismWidth),
    ColorF(clr[1], clr[2], clr[3], alphaShape),
    not drawOnTop,
    false
  )
end

local function drawNearRoute(model, startDistance, endDistance, prismWidth, drawOnTop, globalOpacity)
  local points = model.points
  local distances = model.pointDistancesByIndex
  if not points or #points < 2 then return end

  local clr = cc.snaproads_clr_recce
  local alphaShape = cc.snaproads_alpha * (globalOpacity or 1)
  prismWidth = tonumber(prismWidth) or snaproadPrismWidthDefault

  local startIndex = math.max(1, lowerBoundValues(distances, startDistance) - 1)
  for i = startIndex, #points - 1 do
    local fromPoint = points[i]
    local toPoint = points[i + 1]
    local segmentStart = distances[i] or 0
    local segmentEnd = distances[i + 1] or segmentStart

    if segmentStart > endDistance then break end

    if fromPoint and toPoint and segmentEnd >= startDistance and segmentStart <= endDistance then
      local drawStart = math.max(segmentStart, startDistance)
      local drawEnd = math.min(segmentEnd, endDistance)
      if drawEnd > drawStart + 0.0001 then
        local segmentLength = math.max(0.0001, segmentEnd - segmentStart)
        local startXnorm = clamp01((drawStart - segmentStart) / segmentLength)
        local endXnorm = clamp01((drawEnd - segmentStart) / segmentLength)
        local startPos = vec3(lerp(fromPoint.pos, toPoint.pos, startXnorm))
        local endPos = vec3(lerp(fromPoint.pos, toPoint.pos, endXnorm))
        drawRoutePrism(startPos, endPos, clr, alphaShape, prismWidth, drawOnTop)
      end
    end
  end
end

local function drawOverviewRoute(model, prismWidth, drawOnTop, globalOpacity)
  local points = model.points
  local distances = model.pointDistancesByIndex
  if not points or #points < 2 then return end

  local alphaShape = cc.snaproads_alpha * (globalOpacity or 1)
  prismWidth = tonumber(prismWidth) or snaproadPrismWidthDefault

  local step = math.max(1, math.ceil((#points - 1) / overviewMaxRouteSegments))
  for i = 1, #points - 1, step do
    local endIndex = math.min(#points, i + step)
    local fromPoint = points[i]
    local toPoint = points[endIndex]
    if fromPoint and toPoint then
      local fromDist = distances[i] or 0
      local toDist = distances[endIndex] or fromDist
      local clr = colorForDistance(model.totalLength, (fromDist + toDist) * 0.5)
      drawRoutePrism(fromPoint.pos, toPoint.pos, clr, alphaShape, prismWidth, drawOnTop)
    end
  end
end

local function labelIdsAroundPivot(model, pivotDistance, nearbyCount)
  local ids = {}
  nearbyCount = math.max(0, math.floor((tonumber(nearbyCount) or 3) + 0.5))
  if nearbyCount == 0 then return ids end

  local pivotIndex = lowerBoundEntries(model.entries, pivotDistance)
  if pivotIndex > #model.entries then pivotIndex = #model.entries end
  if pivotIndex < 1 then pivotIndex = 1 end

  local startIndex = math.max(1, pivotIndex - nearbyCount)
  local endIndex = math.min(#model.entries, pivotIndex + nearbyCount)
  for i = startIndex, endIndex do
    ids[model.entries[i].pacenote.id] = true
  end
  return ids
end

local function drawNearPacenotes(model, pacenoteToolsState, startDistance, endDistance, labelIds, labelMode, globalOpacity)
  local nearColor = cc.waypoint_clr_background
  local nearTextColor = cc.clr_white
  local startIndex = math.max(1, lowerBoundEntries(model.entries, startDistance - (model.maxEntrySpan or 0)) - 1)
  for i = startIndex, #model.entries do
    local entry = model.entries[i]
    if entry.markerDistance > endDistance then break end
    if entry.endDistance >= startDistance and entry.startDistance <= endDistance then
      local showLabel = labelMode == pacenoteLabelModeAll or labelIds[entry.pacenote.id] == true
      entry.pacenote:drawDebugPacenoteNoSelectionRainbow(
        pacenoteToolsState,
        globalOpacity,
        nearColor,
        showLabel,
        nearTextColor
      )
    end
  end
end

local function drawOverviewPacenotes(model, pacenoteToolsState, labelMode, globalOpacity)
  local showLabels = labelMode == pacenoteLabelModeAll
  for _, entry in ipairs(model.entries) do
    entry.pacenote:drawDebugPacenoteNoSelectionRainbow(
      pacenoteToolsState,
      globalOpacity,
      entry.markerColor,
      showLabels,
      entry.markerTextColor
    )
  end
end

function M.draw(path, snaproad, pacenoteToolsState, globalOpacity, prismWidth, drawOnTop, opts)
  if not (path and snaproad and pacenoteToolsState and core_camera and core_camera.getPosition) then return false end

  opts = opts or {}
  local overviewDistance = tonumber(opts.overviewDistance) or 650
  local model = modelFor(pacenoteToolsState, path, snaproad)
  if not model then return false end

  local cameraPos = core_camera.getPosition()
  local nearCameraLoc = snaproad.closestSnapResult and snaproad:closestSnapResult(cameraPos, true) or nil
  if nearCameraLoc and nearCameraLoc.pos and cameraPos:distance(nearCameraLoc.pos) >= overviewDistance then
    drawOverviewRoute(model, prismWidth, drawOnTop, globalOpacity)
    drawOverviewPacenotes(model, pacenoteToolsState, opts.labelMode, globalOpacity)
    return true
  end

  local pivotLoc = cameraLookSnaproadLocation(pacenoteToolsState, model, cameraPos, overviewDistance, nearCameraLoc)
  if not (pivotLoc and pivotLoc.distanceAlongRoute and pivotLoc.pos) then return false end

  pacenoteToolsState._pacenoteLabelRaycastCursorPos = pivotLoc.pos
  local halfWindow = overviewDistance
  local startDistance = math.max(0, pivotLoc.distanceAlongRoute - halfWindow)
  local endDistance = math.min(model.totalLength, pivotLoc.distanceAlongRoute + halfWindow)
  local labelIds = labelIdsAroundPivot(model, pivotLoc.distanceAlongRoute, opts.nearCameraCount)

  drawNearRoute(model, startDistance, endDistance, prismWidth, drawOnTop, globalOpacity)
  drawNearPacenotes(model, pacenoteToolsState, startDistance, endDistance, labelIds, opts.labelMode, globalOpacity)
  return true
end

function M.nearWindow(path, snaproad, pacenoteToolsState, opts)
  if not (path and snaproad and pacenoteToolsState and core_camera and core_camera.getPosition) then return nil end

  opts = opts or {}
  local overviewDistance = tonumber(opts.overviewDistance) or 650
  local model = modelFor(pacenoteToolsState, path, snaproad)
  if not model then return nil end
  if #model.entries == 0 then return nil end

  local cameraPos = core_camera.getPosition()
  local nearCameraLoc = snaproad.closestSnapResult and snaproad:closestSnapResult(cameraPos, true) or nil
  if nearCameraLoc and nearCameraLoc.pos and cameraPos:distance(nearCameraLoc.pos) >= overviewDistance then
    return nil
  end

  local pivotLoc = cameraLookSnaproadLocation(pacenoteToolsState, model, cameraPos, overviewDistance, nearCameraLoc)
  if not (pivotLoc and pivotLoc.distanceAlongRoute and pivotLoc.pos) then return nil end

  return {
    startDistance = math.max(0, pivotLoc.distanceAlongRoute - overviewDistance),
    endDistance = math.min(model.totalLength, pivotLoc.distanceAlongRoute + overviewDistance),
    pivotDistance = pivotLoc.distanceAlongRoute,
    pivotPos = pivotLoc.pos,
  }
end

return M
