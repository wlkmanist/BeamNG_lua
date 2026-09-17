-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = "crawl_general"
M.dependencies = { 'gameplay_crawl_saveSystem', 'gameplay_crawl_utils', 'gameplay_crawl_boundary', 'gameplay_crawl_display' }

M.activeTrail = nil
M.crawlersData = {}

local crawlersData = M.crawlersData

local function clear(force)
  if M.activeTrail then
    gameplay_crawl_utils.unloadPrefabs()
  end

  M.activeTrail = nil
  gameplay_crawl_utils.clear(force)
  table.clear(crawlersData)
end


local function setupCrawl(trail, veh, isFromMission)
  if not trail or not veh then
    log('E', logTag, 'Cannot setup crawl: no valid trail data')
    return false
  end

  if M.activeTrail then
    gameplay_crawl_utils.stopCrawl(true)
    table.clear(crawlersData)
  end

  local boundary = gameplay_crawl_saveSystem.getBoundaryById(trail.boundaryId)
  local path = gameplay_crawl_saveSystem.getPathById(trail.pathId)
  local startingPosition = gameplay_crawl_saveSystem.getStartingPositionById(trail.startingPositionId)

  if not boundary or not path then
    log('E', logTag, 'Missing required boundary or path data for trail: ' .. trail.name)
    return false
  end

  M.activeTrail = {
    trail = trail,
    boundary = boundary,
    path = deepcopy(path),
    startingPosition = startingPosition,
    prefabs = trail.prefabs or {},
    isFromMission = isFromMission or false
  }

  if trail.pathReversed then
    M.activeTrail.path.nodes = arrayReverse(M.activeTrail.path.nodes)

    local reverseRot180 = quatFromAxisAngle(vec3(0, 1, 0), math.pi)
    for _, node in ipairs(M.activeTrail.path.nodes) do
      if node.rotation then
        node.rotation = reverseRot180 * node.rotation
      end
    end

    if trail.startingPositionIdReversed and trail.startingPositionIdReversed ~= "" then
      startingPosition = gameplay_crawl_saveSystem.getStartingPositionById(trail.startingPositionIdReversed)
      M.activeTrail.startingPosition = startingPosition
    elseif M.activeTrail.path.nodes and #M.activeTrail.path.nodes > 0 then
      local firstNode = M.activeTrail.path.nodes[1]
      if firstNode and firstNode.pos then
        local rot = firstNode.rotation or quat(0, 0, 0, 1)
        startingPosition = {
          transform = {
            position = firstNode.pos,
            rotation = rot,
            radius = 10.0
          }
        }
        M.activeTrail.startingPosition = startingPosition
      end
    end
  end

  local crawlerData = gameplay_crawl_utils.setupCrawlerData(veh)
  table.insert(crawlersData, crawlerData)

  gameplay_crawl_utils.loadPrefabs(M.activeTrail.prefabs)

  if startingPosition and isFromMission then
    spawn.safeTeleport(veh, startingPosition.transform.position, startingPosition.transform.rotation, nil, nil, nil, nil, true)
  end

  return true
end

local function startCrawlFreeroam(trail, veh)
  if not trail or not veh then
    log('E', logTag, 'Cannot start crawl: no valid trail data')
    return
  end

  if M.activeTrail then
    gameplay_crawl_utils.stopCrawl(true)
    table.clear(crawlersData)
  end

  if not setupCrawl(trail, veh, false) then
    log('E', logTag, 'Failed to setup crawl')
    return
  end

  local crawlerData = crawlersData[1]
  if not crawlerData then
    log('E', logTag, 'No crawler data found after setup')
    return
  end

  if gameplay_crawl_utils.startCrawl(veh:getID(), trail, crawlerData, false) then
    extensions.hook('onCrawlStarted', {trail = trail})
    -- Hide the freeroam start marker while the crawl is running
    if gameplay_rawPois then
      gameplay_rawPois.clear()
    end
  end
end

local function startCrawlFlowgraph(trail, veh)
  if not trail or not veh then
    log('E', logTag, 'Cannot start crawl: no valid trail data')
    return false
  end

  if M.activeTrail and M.activeTrail.trail and M.activeTrail.trail.name == trail.name then
    local crawlerData = crawlersData[1]
    if not crawlerData then
      crawlerData = gameplay_crawl_utils.setupCrawlerData(veh)
      table.insert(crawlersData, crawlerData)
    end

    if gameplay_crawl_utils.startCrawl(veh:getID(), trail, crawlerData, true) then
      extensions.hook('onCrawlStarted', {trail = trail})
      return true
    else
      return false
    end
  end

  if not setupCrawl(trail, veh, true) then
    log('E', logTag, 'Failed to setup crawl')
    return false
  end

  local crawlerData = crawlersData[1]
  if not crawlerData then
    log('E', logTag, 'No crawler data found after setup')
    return false
  end

  if gameplay_crawl_utils.startCrawl(veh:getID(), trail, crawlerData, true) then
    extensions.hook('onCrawlStarted', {trail = trail})
    return true
  else
    return false
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if M.activeTrail then
    gameplay_crawl_utils.updateCrawl(dtSim)
  end
end

local function getBigMapTpPosRot(poi, veh)
  local trail = gameplay_crawl_saveSystem.getTrailById(poi.data.trailId)
  if trail and trail.startingPositionId then
    local startingPos = gameplay_crawl_saveSystem.getStartingPositionById(trail.startingPositionId)
    if startingPos then
      local pos = startingPos.transform.position
      local rot = startingPos.transform.rotation or quat(0, 0, 0, 1)

      return pos, rot
    end
  end
  return nil, nil
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  local crawlPath = levelIdentifier and ('/levels/' .. levelIdentifier .. '/crawls/')
  local trails = gameplay_crawl_saveSystem.getAllTrails(crawlPath)
  if trails and not M.activeTrail and (career_career.isActive() or settings.getValue("enableCrawlInFreeroam")) then
    for _, trail in ipairs(trails) do
      local startingPosition = nil
      if trail.startingPositionId then
        startingPosition = gameplay_crawl_saveSystem.getStartingPositionById(trail.startingPositionId)
      end

      if startingPosition then
        local pos = startingPosition.transform.position
        local radius = startingPosition.transform.radius or 10
        local rotation = startingPosition.transform.rotation

        local poi = {
          id = string.format("crawl##%s", trail._fileName or "trail"),
          data = { type = "crawl", trailId = trail._filePath },
          markerInfo = {
            crawlMarker = {
              pos = pos,
              rot = rotation,
              radius = radius,
              iconPos = startingPosition.iconPosition,
              onInside = function(interactData)
              end,
            }
          }
        }
        poi.markerInfo.bigmapMarker = {
          pos = pos,
          icon = "mission_rockcrawling01_triangle",
          name = trail.name or _tr("ui.crawl.trailName"),
          description = _tr("ui.crawl.trailDescription"),
          thumbnail = trail.thumbnail,
          previews = {trail.thumbnail},
          quickTravelPosRotFunction = getBigMapTpPosRot
        }

        local trailStats = gameplay_crawl_saveSystem.getPlayerTrailStats(trail._filePath)
        if trailStats and trailStats.bestPenaltyPoints < math.huge then
          poi.markerInfo.bigmapMarker.description = poi.markerInfo.bigmapMarker.description .. "\n" .. core_locales.contextTranslate("ui.crawl.bestPenaltyPointsValue", {points = trailStats.bestPenaltyPoints})
        end
        if trailStats then
          poi.markerInfo.bigmapMarker.aggregatePrimary = {label = 'bigMap.progressLabels.bestPoints', value = trailStats.bestPenaltyPoints < math.huge and trailStats.bestPenaltyPoints or "-"}
        end
        table.insert(elements, poi)
      end
    end
  end
end


local function onActivityAcceptGatherData(elemData, activityData)
  for _, elem in ipairs(elemData) do
    if elem.type == "crawl" then
      local trail = gameplay_crawl_saveSystem.getTrailById(elem.trailId)

      local pathStats = nil
      if trail.pathId then
        pathStats = gameplay_crawl_utils.calculatePathStats(trail.pathId, trail.pathReversed)
      end

      local props = {}

      if pathStats then
        table.insert(props, {
          icon = "ui_icons_distance",
          keyLabel = _tr("bigMap.progressLabels.distance"),
          valueLabel = string.format("%.1f m", pathStats.totalDistance)
        })

        if pathStats.elevationGain > 0 then
          table.insert(props, {
            icon = "ui_icons_elevation_up",
            keyLabel = _tr("ui.crawl.elevationGain"),
            valueLabel = string.format("%.1f m", pathStats.elevationGain)
          })
        end

        if pathStats.elevationLoss > 0 then
          table.insert(props, {
            icon = "ui_icons_elevation_down",
            keyLabel = _tr("ui.crawl.elevationLoss"),
            valueLabel = string.format("%.1f m", pathStats.elevationLoss)
          })
        end
      end

      local trailStats = gameplay_crawl_saveSystem.getPlayerTrailStats(elem.trailId)
      if trailStats then
                if trailStats.bestPenaltyPoints < math.huge then
          table.insert(props, {
            icon = "ui_icons_points",
            keyLabel = _tr("missions.crawl.progressLabels.bestPointsAchieved"),
            valueLabel = string.format("%d", trailStats.bestPenaltyPoints)
          })
        end

        if trailStats.bestTime < math.huge then
          table.insert(props, {
            icon = "ui_icons_time",
            keyLabel = _tr("bigMap.progressLabels.bestTime"),
            valueLabel = string.format("%.2fs", trailStats.bestTime)
          })
        end

        if trailStats.attempts > 0 then
          table.insert(props, {
            icon = "ui_icons_attempts",
            keyLabel = _tr("bigMap.progressLabels.attempts"),
            valueLabel = tostring(trailStats.attempts)
          })
        end
      end

      local data = {
        data = elem,
        icon = "mission_rockcrawling01_triangle",
        heading = trail.name,
        preheadings = {_tr("ui.crawl.freeroamCrawl")},
        props = props,
        buttonLabel = _tr("ui.crawl.play"),
        buttonFun = function()
          local veh = be:getPlayerVehicle(0)
          if veh then
            startCrawlFreeroam(trail, veh)
          end
          ui_missionInfo.closeDialogue()
        end,
      }
      table.insert(activityData, data)
    end
  end
end

local function onActivityIndexVisible(data)
  if not data then
    if M.activeTrail and not M.activeTrail.isFromMission then
      local activeCrawlerId = gameplay_crawl_utils.getActiveCrawlerId()
      if not activeCrawlerId then
        clear(true)
      end
    end
    if not M.activeTrail then
      gameplay_crawl_utils.clearMarkers()
    end
    return
  end

  if gameplay_crawl_utils.getActiveCrawlerId() then
    return
  end

  if data.type == "crawl" then
    if M.activeTrail and M.activeTrail.trail and M.activeTrail.trail._filePath == data.trailId then
      return
    end

    local trail = gameplay_crawl_saveSystem.getTrailById(data.trailId)
    if trail then
      local veh = be:getPlayerVehicle(0)
      if veh then
        setupCrawl(trail, veh, false)
      end

      local path = deepcopy(gameplay_crawl_saveSystem.getPathById(trail.pathId))
      if trail.pathReversed then
        path.nodes = arrayReverse(path.nodes)
      end
      gameplay_crawl_utils.setupCrawlMarkers(path)
    end
  end
end

local function onDrawOnMinimap(td)
  if M.activeTrail then
    local boundary = M.activeTrail.boundary
    if boundary then
      boundary:drawMinimap(td)
    end
  end
end

local function onExtensionLoaded()
  clear(true)
  gameplay_crawl_saveSystem.ensurePlayerSaveDirectories()
end

local function onSerialize()
  clear(true)
end

local function onVehicleSwitched(oldId, newId)
  if M.activeTrail and not (M.activeTrail.isFromMission) then
    clear(true)
  end
end

local function onVehicleDestroyed(vehId)
  if M.activeTrail and not (M.activeTrail.isFromMission) then
    clear(true)
  end
end

local function onAnyMissionChanged(status, id)
  if status == "stopped" then
    clear(true)
  end
end

local function onCrawlCleared()
  -- utils.clear() nils activeTrail and fires this hook on any teardown (stop, disqualification,
  -- vehicle switch, etc). Keep general's crawler list in sync and re-evaluate the freeroam POI
  -- list so the start marker becomes available again.
  table.clear(crawlersData)
  if gameplay_rawPois then
    gameplay_rawPois.clear()
  end
end

local function onCrawlResultsShown(eventData)
  local time = eventData.time
  local points = eventData.points

  if M.activeTrail and M.activeTrail.trail then
    local trailId = M.activeTrail.trail._filePath or M.activeTrail.trail.id
    if trailId then
      gameplay_crawl_saveSystem.addNewPlayerScore(trailId, time, points)
    end
  end
end

local function onMPSessionChanged(old, new)
  if not old and new then
    extensions.load("gameplay_crawl_freeroamMultiplayer")
  elseif old and not new then
    extensions.unload("gameplay_crawl_freeroamMultiplayer")
  end
end


M.clear = clear
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onActivityAcceptGatherData = onActivityAcceptGatherData
M.onActivityIndexVisible = onActivityIndexVisible
M.onDrawOnMinimap = onDrawOnMinimap
M.onExtensionLoaded = onExtensionLoaded
M.onSerialize = onSerialize
M.onMPSessionChanged = onMPSessionChanged
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleDestroyed = onVehicleDestroyed
M.onAnyMissionChanged = onAnyMissionChanged
M.onCrawlCleared = onCrawlCleared
M.onCrawlResultsShown = onCrawlResultsShown
M.onUpdate = onUpdate
M.startCrawlFreeroam = startCrawlFreeroam
M.startCrawlFlowgraph = startCrawlFlowgraph
M.setupCrawl = setupCrawl

return M