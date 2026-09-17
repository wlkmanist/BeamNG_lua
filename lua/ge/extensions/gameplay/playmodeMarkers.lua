-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"gameplay_rawPois"}
local playmodeClusters = nil
local markersByClusterId = {}
local playmodeKd = nil

-- this list should be built dynamicly
local playmodeMarkerTypeNames = {
  missionMarker = true,
  parkingMarker = true,
  zoneMarker = true,
  walkingMarker = true,
  gasStationMarker = true,
  driftLineMarker = true,
  invisibleTrigger = true,
  inspectVehicleMarker = true,
  crawlMarker = true,
  vehicleTrigger = true,
}

local function idSort(a,b) return a.id<b.id end

local iconRendererName = "markerIconRenderer"
local bigmapIconRendererName = "bigmapIconRenderer"
local iconRendererId = nil
local bigmapIconRendererId = nil
local function removeBigmapIconRenderer()
  if bigmapIconRendererId and scenetree.findObjectById(bigmapIconRendererId) then
    local bigmapIconRendererObj = scenetree.findObjectById(bigmapIconRendererId)
    if bigmapIconRendererObj then
      bigmapIconRendererObj:delete()
    end
    bigmapIconRendererId = nil
  end
end
local function removeIconRenderer()
  if iconRendererId and scenetree.findObjectById(iconRendererId) then
    local iconRendererObj = scenetree.findObjectById(iconRendererId)
    if iconRendererObj then
      iconRendererObj:delete()
    end
    iconRendererId = nil
  end
end
local function clearPlaymodeClusters()
  if playmodeClusters or playmodeKd or next(markersByClusterId) then
    log("D","","Playmode clusters and markers cleared")
  end
  playmodeClusters = nil
  playmodeKd = nil
  for _, marker in pairs(markersByClusterId) do
    marker:clearObjects()
  end
  table.clear(markersByClusterId)

  --if iconRendererId and scenetree.findObjectById(iconRendererId) then
    --local iconRendererObj = scenetree.findObjectById(iconRendererId)
    --iconRendererObj:removeAllIcons()
  --end
end


local function createIconRenderer(rendererName, maxIconScale, loadAtlas)
  local rendererObj = createObject("BeamNGWorldIconsRenderer")
  rendererObj:registerObject(rendererName)
  rendererObj.maxIconScale = maxIconScale
  rendererObj.mConstantSizeIcons = true
  rendererObj.canSave = false
  if loadAtlas then
    rendererObj:loadIconAtlas("core/art/gui/images/iconAtlas.png", "core/art/gui/images/iconAtlas.json")
  end
  return rendererObj:getId()
end

local function setupIconRenderers()
  local bigmapRendererExists = bigmapIconRendererId and scenetree.findObjectById(bigmapIconRendererId)
  local markerRendererExists = iconRendererId and scenetree.findObjectById(iconRendererId)

  if markerRendererExists and bigmapRendererExists then
    return
  end

  if not markerRendererExists then
    iconRendererId = createIconRenderer(iconRendererName, 2, true)
  end
  if not bigmapRendererExists then
    bigmapIconRendererId = createIconRenderer(bigmapIconRendererName, 1, false)
  end
end
M.getIconRendererId = function()
  setupIconRenderers()
  return iconRendererId
end
M.getIconRendererObj = function()
  setupIconRenderers()
  return scenetree.findObjectById(iconRendererId)
end
M.getBigmapRendererId = function()
  setupIconRenderers()
  return bigmapIconRendererId
end
M.getBigmapRendererObj = function()
  setupIconRenderers()
  return scenetree.findObjectById(bigmapIconRendererId)
end

local function sanitizeCluster(cluster)
  for _, key in ipairs({"id","visibilityPos","visibilityRadius"}) do
    if not cluster[key] then log("E","","No ".. key .. " for cluster " .. (cluster.id or dumps(cluster)))
    end
  end
end

local function clusterPlaymodePois(pois)
  -- first, sort/duplicate all pois by their markerTypes
  local poisByMarkerType = {}
  for markerType, _ in pairs(playmodeMarkerTypeNames) do
    poisByMarkerType[markerType] = {}
    for _, poi in ipairs(pois) do
      if poi.markerInfo[markerType] then
        table.insert(poisByMarkerType[markerType], poi)
      end
    end
  end
  local allClusters = {}
  -- let each markertype cluster their own markers in their own way
  for markerType, _ in pairs(playmodeMarkerTypeNames) do
    local factory = require('lua/ge/extensions/gameplay/markers/'..markerType)
    factory.cluster(poisByMarkerType[markerType], allClusters)
  end

  table.sort(allClusters, idSort)

  -- check all clusters if they have required fields
  for _, cluster in ipairs(allClusters) do
    sanitizeCluster(cluster)
  end
  return allClusters
end

local clusterGeneration = -1
local function checkGeneration()
  if clusterGeneration < gameplay_rawPois.getRawPoiGeneration() then
    clearPlaymodeClusters()
    clusterGeneration = gameplay_rawPois.getRawPoiGeneration()
    log("D","","Playmode markers/clusters cleared. New Generation: " .. clusterGeneration)
  end
end
local function getPlaymodeClusters()
  checkGeneration()
  if not playmodeClusters then
    local pois, rawPoiGeneration = gameplay_rawPois.getRawPoiListByLevel(getCurrentLevelIdentifier())

    playmodeClusters = clusterPlaymodePois(pois)
  end
  return playmodeClusters
end

local kdTree = require('kdtreebox2d') -- change to KD Tree?
local function getPlaymodeClustersAsQuadtree()
  checkGeneration()
  if not playmodeKd then
    playmodeKd = kdTree.new()
    for _, cluster in ipairs(getPlaymodeClusters()) do
      playmodeKd:preLoad(cluster.id, cluster.visibilityPos.x-cluster.visibilityRadius, cluster.visibilityPos.y-cluster.visibilityRadius, cluster.visibilityPos.x+cluster.visibilityRadius, cluster.visibilityPos.y+cluster.visibilityRadius)
    end
    playmodeKd:build()
  end
  return playmodeKd
end
M.getPlaymodeClusters = getPlaymodeClusters
M.getPlaymodeClustersAsQuadtree = getPlaymodeClustersAsQuadtree

local function getMarkerForCluster(cluster)
  checkGeneration()
  if not markersByClusterId[cluster.id] then
    local marker = cluster.create()
    marker:createObjects()
    marker:setup(cluster)
    markersByClusterId[cluster.id] = marker
  end
  return markersByClusterId[cluster.id]
end
M.getMarkerForCluster = getMarkerForCluster


-- this can be adjusted to allow other states to have playmode markers
M.validPlaymodeMarkersStates = {
  freeroam = true,
  career = true,
}
local function isStateWithPlaymodeMarkers()
  if core_gamestate.state and M.validPlaymodeMarkersStates[core_gamestate.state.state] then
    return true
  end
  return false
end
M.isStateWithPlaymodeMarkers = isStateWithPlaymodeMarkers

M.onClientStartMission = setupIconRenderers
M.onClientEndMission = function()
  clearPlaymodeClusters()
  removeIconRenderer()
  removeBigmapIconRenderer()
end

M.onSerialize = function()
  clearPlaymodeClusters()
  removeIconRenderer()
  removeBigmapIconRenderer()
end
M.clear = clearPlaymodeClusters

return M
