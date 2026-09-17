-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local cc = require('/lua/ge/extensions/gameplay/rally/util/colors')

local M = {}

local snaproadPrismHeight = 0.5
local snaproadPrismWidthDefault = 1.945
local fullDrawDistanceRatio = 2 / 3

local function clamp01(v)
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

local function pacenotesForPath(path)
  return path and path.pacenotes and path.pacenotes.sorted or nil
end

local function distanceBetweenRouteValues(a, b)
  if not a or not b then return math.huge end
  return math.abs(a - b)
end

local function closestSnaproadLocationToCameraRay(snaproad, cameraPos, forward, pointDistances)
  if not (snaproad and snaproad._allPoints and snaproad.routeLocationForPoint) then
    return snaproad and snaproad.closestSnapResult and snaproad:closestSnapResult(cameraPos, true) or nil
  end

  if not forward then
    return snaproad:closestSnapResult(cameraPos, true)
  end

  local rayDir = vec3(forward)
  local rayLen = rayDir:length()
  if rayLen <= 0.0001 then
    return snaproad:closestSnapResult(cameraPos, true)
  end
  rayDir = rayDir * (1 / rayLen)

  local points = snaproad:_allPoints()
  if not points or #points < 2 then
    return snaproad:closestSnapResult(cameraPos, true)
  end

  local best = nil
  local bestDistSq = math.huge

  for i = 1, #points - 1 do
    local fromPoint = points[i]
    local toPoint = points[i + 1]
    if fromPoint and toPoint then
      local seg = toPoint.pos - fromPoint.pos
      local segLenSq = seg:dot(seg)
      if segLenSq > 0.000001 then
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
          local fromDist = pointDistances and pointDistances[fromPoint.id or i] or nil
          local toDist = pointDistances and pointDistances[toPoint.id or (i + 1)] or nil
          if not fromDist or not toDist then
            local fromLoc = snaproad:routeLocationForPoint(fromPoint)
            local toLoc = snaproad:routeLocationForPoint(toPoint)
            fromDist = fromLoc and fromLoc.distanceAlongRoute or 0
            toDist = toLoc and toLoc.distanceAlongRoute or fromDist
          end

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
      end
    end
  end

  return best or snaproad:closestSnapResult(cameraPos, true)
end

function M.getCameraLookSnaproadLocation(pacenoteToolsState, snaproad, cameraPos, pointDistances)
  if not (pacenoteToolsState and snaproad and cameraPos) then return nil end

  local forward = core_camera and core_camera.getForward and core_camera.getForward() or nil
  local cache = pacenoteToolsState._pacenoteLabelRaycastLocationCache
  if cache
      and cache.snaproad == snaproad
      and cache.cameraPosX == cameraPos.x
      and cache.cameraPosY == cameraPos.y
      and cache.cameraPosZ == cameraPos.z
      and cache.forwardX == (forward and forward.x or nil)
      and cache.forwardY == (forward and forward.y or nil)
      and cache.forwardZ == (forward and forward.z or nil) then
    return cache.location
  end

  local location = closestSnaproadLocationToCameraRay(snaproad, cameraPos, forward, pointDistances)
  pacenoteToolsState._pacenoteLabelRaycastLocationCache = {
    snaproad = snaproad,
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

local function buildPacenoteEntries(path, snaproad)
  local entries = {}
  local pacenotes = pacenotesForPath(path)
  if not (pacenotes and snaproad and snaproad.closestSnapResult) then return entries end

  for index,pacenote in ipairs(pacenotes) do
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

      if startDistance ~= math.huge then
        table.insert(entries, {
          index = index,
          pacenote = pacenote,
          wpCs = wpCs,
          csLoc = csLoc,
          ceLoc = ceLoc,
          startDistance = startDistance,
          endDistance = endDistance,
        })
      end
    end
  end

  return entries
end

local function closestCameraDistanceToEntries(entries, cameraPos)
  local closestDistSq = math.huge

  for _,entry in ipairs(entries) do
    if entry.wpCs and entry.wpCs.pos then
      closestDistSq = math.min(closestDistSq, cameraPos:squaredDistance(entry.wpCs.pos))
    end
    local wpCe = entry.pacenote and entry.pacenote:getCornerEndWaypoint()
    if wpCe and wpCe.pos then
      closestDistSq = math.min(closestDistSq, cameraPos:squaredDistance(wpCe.pos))
    end
  end

  return closestDistSq == math.huge and math.huge or math.sqrt(closestDistSq)
end

local function pivotIndexForEntries(entries, pivotDistance)
  local pivotIndex = nil
  local pivotRouteDistance = math.huge

  for i,entry in ipairs(entries) do
    local routeDistance = math.min(
      distanceBetweenRouteValues(entry.csLoc and entry.csLoc.distanceAlongRoute or nil, pivotDistance),
      distanceBetweenRouteValues(entry.ceLoc and entry.ceLoc.distanceAlongRoute or nil, pivotDistance)
    )
    if routeDistance < pivotRouteDistance then
      pivotRouteDistance = routeDistance
      pivotIndex = i
    end
  end

  return pivotIndex
end

local function buildPointDistances(snaproad)
  local points = snaproad and snaproad._allPoints and snaproad:_allPoints() or nil
  local distances = {}
  if not points then return distances end

  local totalLength = 0
  for i,point in ipairs(points) do
    distances[i] = totalLength
    if point.id then
      distances[point.id] = totalLength
    end
    local nextPoint = points[i + 1]
    if nextPoint then
      totalLength = totalLength + point.pos:distance(nextPoint.pos)
    end
  end

  return distances
end

local function minimumWindowForEntries(entries, pivotIndex, nearbyCount, pivotDistance, totalLength)
  if not pivotIndex then return nil, nil end

  local startIndex = math.max(1, pivotIndex - nearbyCount)
  local endIndex = math.min(#entries, pivotIndex + nearbyCount)
  local startDistance = pivotDistance or math.huge
  local endDistance = pivotDistance or -math.huge

  for i = startIndex, endIndex do
    local entry = entries[i]
    startDistance = math.min(startDistance, entry.startDistance)
    endDistance = math.max(endDistance, entry.endDistance)
  end

  if startIndex == 1 then
    startDistance = 0
  end
  if endIndex == #entries then
    endDistance = totalLength or endDistance
  end

  if startDistance == math.huge then return nil, nil end
  return startDistance, endDistance
end

function M.buildContext(path, snaproad, pacenoteToolsState, maxDistance, nearbyCount)
  if not (path and snaproad and pacenoteToolsState and core_camera and core_camera.getPosition) then return nil end

  maxDistance = tonumber(maxDistance) or 650
  nearbyCount = math.max(0, math.floor((tonumber(nearbyCount) or 3) + 0.5))

  local totalLength = snaproad.totalRouteLength and snaproad:totalRouteLength() or 0
  if totalLength <= 0 then return nil end

  local cameraPos = core_camera.getPosition()
  local entries = buildPacenoteEntries(path, snaproad)
  if #entries == 0 then return nil end

  local pointDistances = buildPointDistances(snaproad)
  local pivotLoc = M.getCameraLookSnaproadLocation(pacenoteToolsState, snaproad, cameraPos, pointDistances)
  if not (pivotLoc and pivotLoc.distanceAlongRoute) then return nil end

  local cameraDistance = math.min(closestCameraDistanceToEntries(entries, cameraPos), cameraPos:distance(pivotLoc.pos))
  local fullDrawDistance = maxDistance * fullDrawDistanceRatio
  if cameraDistance == math.huge or cameraDistance >= fullDrawDistance or cameraDistance > maxDistance then
    return nil
  end

  local pivotIndex = pivotIndexForEntries(entries, pivotLoc.distanceAlongRoute)
  local minStartDistance, minEndDistance = minimumWindowForEntries(entries, pivotIndex, nearbyCount, pivotLoc.distanceAlongRoute, totalLength)
  if not (minStartDistance and minEndDistance) then return nil end

  local t = clamp01(cameraDistance / math.max(fullDrawDistance, 0.0001))
  local startDistance = minStartDistance + (0 - minStartDistance) * t
  local endDistance = minEndDistance + (totalLength - minEndDistance) * t

  pacenoteToolsState._pacenoteLabelRaycastCursorPos = pivotLoc.pos

  return {
    entries = entries,
    pivotLoc = pivotLoc,
    pointDistances = pointDistances,
    startDistance = math.max(0, startDistance),
    endDistance = math.min(totalLength, endDistance),
    totalLength = totalLength,
  }
end

local function drawSnaproadPrisms(context, snaproad, prismWidth, drawOnTop, globalOpacity)
  if not (context and snaproad and snaproad._allPoints and snaproad.routeLocationForPoint) then return end

  local points = snaproad:_allPoints()
  if not points or #points < 2 then return end

  local clr = cc.snaproads_clr_recce
  local alphaShape = cc.snaproads_alpha * (globalOpacity or 1)
  prismWidth = tonumber(prismWidth) or snaproadPrismWidthDefault

  for i = 1, #points - 1 do
    local fromPoint = points[i]
    local toPoint = points[i + 1]
    local fromDist = context.pointDistances[fromPoint.id or i] or 0
    local toDist = context.pointDistances[toPoint.id or (i + 1)] or fromDist
    local segmentStart = math.min(fromDist, toDist)
    local segmentEnd = math.max(fromDist, toDist)

    if segmentStart > context.endDistance then break end

    if segmentEnd >= context.startDistance and segmentStart <= context.endDistance then
      local drawStart = math.max(segmentStart, context.startDistance)
      local drawEnd = math.min(segmentEnd, context.endDistance)
      if drawEnd > drawStart + 0.0001 then
        local segmentLength = math.max(0.0001, segmentEnd - segmentStart)
        local startXnorm = clamp01((drawStart - segmentStart) / segmentLength)
        local endXnorm = clamp01((drawEnd - segmentStart) / segmentLength)
        local startPos = vec3(lerp(fromPoint.pos, toPoint.pos, startXnorm))
        local endPos = vec3(lerp(fromPoint.pos, toPoint.pos, endXnorm))

        debugDrawer:drawSquarePrism(
          startPos,
          endPos,
          Point2F(snaproadPrismHeight, prismWidth),
          Point2F(snaproadPrismHeight, prismWidth),
          ColorF(clr[1], clr[2], clr[3], alphaShape),
          not drawOnTop,
          false
        )
      end
    end
  end
end

local function drawFocusedPacenotes(context, pacenoteToolsState, globalOpacity)
  if not (context and context.entries) then return end

  for _,entry in ipairs(context.entries) do
    if entry.endDistance >= context.startDistance and entry.startDistance <= context.endDistance then
      entry.pacenote:drawDebugPacenoteNoSelection(pacenoteToolsState, globalOpacity)
    end
  end
end

function M.draw(context, path, snaproad, pacenoteToolsState, globalOpacity, prismWidth, drawOnTop)
  drawSnaproadPrisms(context, snaproad, prismWidth, drawOnTop, globalOpacity)
  drawFocusedPacenotes(context, pacenoteToolsState, globalOpacity)
end

return M
