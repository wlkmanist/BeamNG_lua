-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = "crawl_boundary"

local spawnedBoundaryMarkersId = nil
local boundaryObjects = {}
local visibilityRadius = 100

local animationDuration = 0.5
local fadeInDuration = 0.3
local fadeOutDuration = 0.2
local scaleUpDuration = 0.4
local maxScale = 1.0
local minScale = 0.1

local boundaryQuadtree = nil
local quadtreeBounds = nil
local visibleLookupScratch = {}

local crawlerExitPoints = {}
local crawlerDNFApplied = {}

local function buildBoundaryQuadtree()
  if not boundaryObjects or not next(boundaryObjects) then
    return
  end

  local minX, minY = math.huge, math.huge
  local maxX, maxY = -math.huge, -math.huge

  for _, objectInfo in pairs(boundaryObjects) do
    local pos = objectInfo.finalPosition
    minX = math.min(minX, pos.x)
    minY = math.min(minY, pos.y)
    maxX = math.max(maxX, pos.x)
    maxY = math.max(maxY, pos.y)
  end

  quadtreeBounds = {minX = minX, minY = minY, maxX = maxX, maxY = maxY}

  local quadtree = require('quadtree')
  boundaryQuadtree = quadtree.newQuadtree()

  for objectId, objectInfo in pairs(boundaryObjects) do
    local pos = objectInfo.finalPosition
    boundaryQuadtree:preLoad(objectId, pos.x - 0.5, pos.y - 0.5, pos.x + 0.5, pos.y + 0.5)
  end

  boundaryQuadtree:build(6)

  log('D', logTag, string.format('Built quadtree with %d objects, bounds: %.1f x %.1f',
    #boundaryObjects, maxX - minX, maxY - minY))
end

local function updateBoundaryAnimations(dtSim)
  if not boundaryObjects then
    return
  end

  local playerPos = nil
  if gameplay_crawl_utils and gameplay_crawl_utils.getPlayerPosition then
    playerPos = gameplay_crawl_utils.getPlayerPosition()
  else
    playerPos = core_camera.getPosition()
  end

  if not playerPos then
    return
  end

  if boundaryQuadtree then
    local queryX, queryY = playerPos.x, playerPos.y
    local queryRadius = visibilityRadius

    -- Reuse a persistent set instead of allocating two tables every frame.
    table.clear(visibleLookupScratch)
    for objectId in boundaryQuadtree:queryNotNested(
      queryX - queryRadius, queryY - queryRadius,
      queryX + queryRadius, queryY + queryRadius
    ) do
      local objectInfo = boundaryObjects[objectId]
      if objectInfo and playerPos:distance(objectInfo.finalPosition) <= queryRadius then
        visibleLookupScratch[objectId] = true
      end
    end

    for objectId, objectInfo in pairs(boundaryObjects) do
      local isCurrentlyVisible = visibleLookupScratch[objectId] or false
      local wasVisible = objectInfo.lastVisible
      local animState = objectInfo.animationState
      local isAnimating = animState == "appearing" or animState == "disappearing"

      -- Skip idle, off-screen objects entirely: avoids a findObjectById call per object per frame.
      if isCurrentlyVisible or wasVisible or isAnimating then
        local obj = scenetree.findObjectById(objectId)
        if obj then
          if isCurrentlyVisible and not wasVisible then
            objectInfo.animationState = "appearing"
            objectInfo.animationTimer = 0
            objectInfo.steadyApplied = false
            obj.hidden = false
          elseif not isCurrentlyVisible and wasVisible then
            objectInfo.animationState = "disappearing"
            objectInfo.animationTimer = 0
            objectInfo.steadyApplied = false
          end

          if objectInfo.animationState == "appearing" then
            objectInfo.animationTimer = objectInfo.animationTimer + dtSim

            if objectInfo.animationTimer >= animationDuration then
              objectInfo.animationState = "visible"
              objectInfo.animationTimer = 0
              obj:setScale(vec3(maxScale, maxScale, maxScale))
              obj:setField('instanceColor', 0, '1 1 1 1')
              objectInfo.steadyApplied = true
            else
              local scaleT = math.min(objectInfo.animationTimer / scaleUpDuration, 1.0)
              local alphaT = math.min(objectInfo.animationTimer / fadeInDuration, 1.0)

              local currentScale = lerp(minScale, maxScale, smootherstep(scaleT))
              local currentAlpha = lerp(0.0, 1.0, smootherstep(alphaT))

              obj:setScale(vec3(currentScale, currentScale, currentScale))
              obj:setField('instanceColor', 0, string.format('1 1 1 %.2f', currentAlpha))
            end

          elseif objectInfo.animationState == "disappearing" then
            objectInfo.animationTimer = objectInfo.animationTimer + dtSim

            if objectInfo.animationTimer >= fadeOutDuration then
              objectInfo.animationState = "hidden"
              objectInfo.animationTimer = 0
              obj.hidden = true
            else
              local alphaT = 1.0 - (objectInfo.animationTimer / fadeOutDuration)
              local currentAlpha = lerp(0.0, 1.0, smootherstep(alphaT))

              obj:setField('instanceColor', 0, string.format('1 1 1 %.2f', currentAlpha))
            end

          elseif objectInfo.animationState == "visible" then
            -- Only push scale/color once on entering the steady visible state.
            if not objectInfo.steadyApplied then
              obj:setScale(vec3(maxScale, maxScale, maxScale))
              obj:setField('instanceColor', 0, '1 1 1 1')
              objectInfo.steadyApplied = true
            end
          end

          objectInfo.lastVisible = isCurrentlyVisible
        else
          boundaryObjects[objectId] = nil
        end
      end
    end
  end
end

local function resetBoundaryObjects()
  for objectId, objectInfo in pairs(boundaryObjects) do
    local obj = scenetree.findObjectById(objectId)
    if obj then
      obj.hidden = true
      obj:setScale(vec3(minScale, minScale, minScale))
      obj:setField('instanceColor', 0, '1 1 1 0')
    end
  end

  boundaryObjects = {}
  log('D', logTag, 'Reset boundary objects tracking')
end

-- Utility function to spawn flag markers along crawl boundary
local function spawnBoundaryMarkers(boundary, spacing)
  if not boundary or not boundary.vertices or #boundary.vertices < 3 then
    log('W', logTag, 'Invalid boundary for spawning markers')
    return
  end

  spacing = spacing or 2.0 -- Default spacing of 2 meters

  -- Clean up existing boundary markers
  if spawnedBoundaryMarkersId then
    local group = scenetree.findObjectById(spawnedBoundaryMarkersId)
    if group then
      group:delete()
    end
    spawnedBoundaryMarkersId = nil
  end

  -- Reset boundary objects tracking
  resetBoundaryObjects()

  -- Create a new group for boundary markers
  local markerGroup = createObject("SimGroup")
  markerGroup:registerObject(Sim.getUniqueName("BoundaryMarkers"))
  scenetree.MissionGroup:addObject(markerGroup)
  spawnedBoundaryMarkersId = markerGroup:getId()

  local flagMeshPath = "/art/shapes/race/flagMarker.dae"
  local points = {}

  -- Generate points along the boundary perimeter
  for i, vertex in ipairs(boundary.vertices) do
    local nextIdx = vertex.next or (i == #boundary.vertices and 1 or i + 1)
    local nextVertex = boundary.vertices[nextIdx]

    local startPos = vertex.pos
    local endPos = nextVertex.pos
    local segmentLength = startPos:distance(endPos)

    local numMarkers = math.floor(segmentLength / spacing)
    if numMarkers < 1 then numMarkers = 1 end

    for j = 0, numMarkers - 1 do
      local t = j / numMarkers
      local pos = lerp(startPos, endPos, t)

      if core_terrain then
        pos.z = core_terrain.getTerrainHeight(pos) or pos.z
      else
        pos.z = be:getSurfaceHeightBelow(pos + vec3(0, 0, 1)) + 0.1
      end

      local terrainNormal = vec3(0, 0, 1)
      if core_terrain then
        terrainNormal = core_terrain.getTerrainSmoothNormal(pos) or vec3(0, 0, 1)
      else
        terrainNormal = map.surfaceNormal(pos, 1) or vec3(0, 0, 1)
      end

      local worldUp = vec3(0, 0, 1)
      local terrainUpDot = terrainNormal:dot(worldUp)

      if terrainUpDot >= 0.5 then
        local dirVec = (endPos - startPos):normalized()
        local rot = quatFromDir(dirVec, worldUp)
        table.insert(points, {pos = pos, rot = rot})
      end
    end
  end

  for i, point in ipairs(points) do
    local name = Sim.getUniqueName("BoundaryFlag_" .. i)
    local marker = createObject('TSStatic')
    marker:setField('shapeName', 0, flagMeshPath)
    marker.scale = vec3(1, 1, 1)
    marker.useInstanceRenderData = true
    marker:setField('instanceColor', 0, '1 1 1 1')
    marker:setInternalName('boundaryMarker')
    marker.canSave = false
    marker:registerObject(name)

    local objectId = marker:getId()
    boundaryObjects[objectId] = {
      finalPosition = vec3(point.pos),
      animationState = "hidden",
      animationTimer = 0,
      lastVisible = false
    }

    marker:setPosRot(point.pos.x, point.pos.y, point.pos.z, point.rot.x, point.rot.y, point.rot.z, point.rot.w)
    marker:setScale(vec3(minScale, minScale, minScale))
    marker:setField('instanceColor', 0, '1 1 1 0')
    marker:updateInstanceRenderData()

    markerGroup:addObject(marker)
  end

  buildBoundaryQuadtree()

  log('D', logTag, string.format('Spawned %d boundary markers along crawl boundary', #points))
  return spawnedBoundaryMarkersId
end

local function cleanupBoundaryMarkers()
  if spawnedBoundaryMarkersId then
    local group = scenetree.findObjectById(spawnedBoundaryMarkersId)
    if group then
      group:delete()
    end
    spawnedBoundaryMarkersId = nil
  end

  resetBoundaryObjects()
end

local function checkBoundary(site, crawler, crawlStates)
  if not site then
    log('E', logTag, 'No site data available')
    return false
  end

  local state = crawlStates and crawlStates[crawler.id]
  if not state or not state.active then
    return false
  end

  local currentCorners = crawler.dynamicData.currentCorners
  if not currentCorners or #currentCorners == 0 then
    local vehPos = crawler.dynamicData.bbCenter
    if site:containsPoint2D(vehPos) then
      crawlerExitPoints[crawler.id] = nil
      crawlerDNFApplied[crawler.id] = nil
      return true
    else
      if not crawlerExitPoints[crawler.id] then
        crawlerExitPoints[crawler.id] = vec3(vehPos)
        log('D', logTag, string.format('Crawler %s exited boundary at %f, %f, %f', crawler.id, vehPos.x, vehPos.y, vehPos.z))
      else
        local exitPoint = crawlerExitPoints[crawler.id]
        local distanceFromExit = vehPos:distance(exitPoint)

        if distanceFromExit >= 10.0 then
          if not crawlerDNFApplied[crawler.id] then
            if gameplay_crawl_utils and gameplay_crawl_utils.applyPenalty then
              gameplay_crawl_utils.applyPenalty(crawler.id, 'dnf')
              crawlerDNFApplied[crawler.id] = true
              log('D', logTag, string.format('Applied DNF penalty for crawler %s - center point %f meters from exit point', crawler.id, distanceFromExit))
            end
          end
          return false
        end
      end

      if gameplay_crawl_utils.onBoundaryViolation then
        gameplay_crawl_utils.onBoundaryViolation(crawler.id)
      end
      return true
    end
  end

  -- Check all corners
  local outsideCorners = 0
  local totalCorners = #currentCorners
  local maxDistanceFromExit = 0

  for i, corner in ipairs(currentCorners) do
    if not site:containsPoint2D(corner) then
      outsideCorners = outsideCorners + 1

      if not crawlerExitPoints[crawler.id] then
        -- First time outside - save the exit point
        crawlerExitPoints[crawler.id] = vec3(corner)
        log('D', logTag, string.format('Crawler %s exited boundary at corner %f, %f, %f', crawler.id, corner.x, corner.y, corner.z))
      else
        -- Check distance from exit point
        local exitPoint = crawlerExitPoints[crawler.id]
        local distanceFromExit = corner:distance(exitPoint)
        maxDistanceFromExit = math.max(maxDistanceFromExit, distanceFromExit)
      end
    end
  end

  -- If any corners are inside, clear the exit point
  if outsideCorners < totalCorners then
    crawlerExitPoints[crawler.id] = nil
    crawlerDNFApplied[crawler.id] = nil
  end

  -- Check for DNF penalty based on distance from exit point
  -- Only apply DNF if ALL corners are outside AND distance is 10+ meters
  if outsideCorners >= totalCorners and maxDistanceFromExit >= 10.0 then
    -- Player is 10+ meters from exit point with all wheels outside - apply DNF penalty only once
    if not crawlerDNFApplied[crawler.id] then
      if gameplay_crawl_utils and gameplay_crawl_utils.applyPenalty then
        gameplay_crawl_utils.applyPenalty(crawler.id, 'dnf')
        crawlerDNFApplied[crawler.id] = true
        log('D', logTag, string.format('Applied DNF penalty for crawler %s - all %d wheels outside and %f meters from exit point', crawler.id, totalCorners, maxDistanceFromExit))
      end
    end
    return false
  end

  -- Apply boundary violation penalty if any corners are outside (but not disqualified)
  if outsideCorners > 0 then
    if gameplay_crawl_utils.onBoundaryViolation then
      gameplay_crawl_utils.onBoundaryViolation(crawler.id)
      log('D', logTag, string.format('Boundary violation penalty for crawler %s - %d/%d corners outside', crawler.id, outsideCorners, totalCorners))
    end
  end

  return true
end

-- Returns the recorded boundary exit point for a crawler, or nil if inside the boundary
local function getCrawlerExitPoint(crawlerId)
  return crawlerExitPoints[crawlerId]
end

-- Function to clear exit point for a specific crawler
local function clearCrawlerExitPoint(crawlerId)
  if crawlerExitPoints[crawlerId] then
    crawlerExitPoints[crawlerId] = nil
    crawlerDNFApplied[crawlerId] = nil
    log('D', logTag, string.format('Cleared exit point and DNF flag for crawler %s', crawlerId))
  end
end

-- Function to clear all exit points
local function clearAllExitPoints()
  crawlerExitPoints = {}
  crawlerDNFApplied = {}
  log('D', logTag, 'Cleared all crawler exit points and DNF flags')
end

-- Function to set visibility radius for boundary markers
local function setVisibilityRadius(radius)
  visibilityRadius = radius or 200
  log('D', logTag, string.format('Set boundary markers visibility radius to %d meters', visibilityRadius))
end

-- Function to set animation timing
local function setAnimationTiming(duration, fadeIn, fadeOut, scaleUp)
  animationDuration = duration or 0.5
  fadeInDuration = fadeIn or 0.3
  fadeOutDuration = fadeOut or 0.2
  scaleUpDuration = scaleUp or 0.4

  log('D', logTag, string.format('Set animation timing: duration=%.1fs, fadeIn=%.1fs, fadeOut=%.1fs, scaleUp=%.1fs',
    animationDuration, fadeInDuration, fadeOutDuration, scaleUpDuration))
end

-- Function to rebuild quadtree (useful if boundary objects change)
local function rebuildQuadtree()
  buildBoundaryQuadtree()
end

-- Function to get quadtree statistics for debugging
local function getQuadtreeStats()
  if not boundaryQuadtree then
    return {built = false, objectCount = 0}
  end

  return {
    built = true,
    objectCount = #boundaryObjects,
    bounds = quadtreeBounds
  }
end

-- Function to trigger appearing animation for all currently visible objects
local function triggerAppearingAnimation()
  if not boundaryObjects then
    return
  end

  for objectId, objectInfo in pairs(boundaryObjects) do
    local obj = scenetree.findObjectById(objectId)
    if obj and not obj.hidden then
      -- Reset to initial animation state
      objectInfo.animationState = "appearing"
      objectInfo.animationTimer = 0
      objectInfo.lastVisible = true

      -- Set initial visual state
      obj:setScale(vec3(minScale, minScale, minScale))
      obj:setField('instanceColor', 0, '1 1 1 0')
      obj.hidden = false
    end
  end

  log('D', logTag, 'Triggered appearing animation for visible boundary markers')
end

-- Export functions
M.spawnBoundaryMarkers = spawnBoundaryMarkers
M.cleanupBoundaryMarkers = cleanupBoundaryMarkers
M.checkBoundary = checkBoundary
M.updateBoundaryAnimations = updateBoundaryAnimations
M.resetBoundaryObjects = resetBoundaryObjects
M.setVisibilityRadius = setVisibilityRadius
M.setAnimationTiming = setAnimationTiming
M.rebuildQuadtree = rebuildQuadtree
M.getQuadtreeStats = getQuadtreeStats
M.triggerAppearingAnimation = triggerAppearingAnimation
M.clearCrawlerExitPoint = clearCrawlerExitPoint
M.getCrawlerExitPoint = getCrawlerExitPoint
M.clearAllExitPoints = clearAllExitPoints

return M
