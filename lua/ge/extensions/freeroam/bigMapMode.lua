-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local useVueBigMap = true -- uncomment this to use the vue big map
local useOrthoCamera = false
local debugWindow = false

local cameraModeName = useOrthoCamera and "bigMapOrtho" or "bigMap"

M.dependencies = {'gameplay_rawPois', 'core_groundMarkers','core_camera','core_terrain', 'freeroam_bigMapMarkers', 'ui_pause_camera'}
if useOrthoCamera then
  table.insert(M.dependencies, 'core_orthoCamera')
end
local logTag = 'bigMapMode'
local imgui = ui_imgui

local xVector = vec3(1,0,0)
local yVector = vec3(0,1,0)
local zVector = vec3(0,0,1)
local invisibleColor = ColorI(255,255,255,0)
local pureWhite = ColorI(255,255,255,255)
local upVector = vec3(0,0,1)

local groundMarkerAlphaSmoother = newTemporalSmoothing()
local fogDensitySmoother = newTemporalSmoothing()
local cloudCoverSmoother = newTemporalSmoothing()
local routeAnimCounter = 1
local poiSelectCallback
local horizontalOffsetFactor = 1
local verticalOffsetFactor = 1

local verticalResolution = 1080
local minZoomFactor = 20000 -- smaller number means you can zoom in further
local navPathSimplificationFactor = 200 -- smaller number means more simplification
local routeAnimSpeedFactor = 3 -- bigger number means faster route animation

local bigMap = false

local previousCloudCover
local previousCamMode
local previousFogDensity
local previousTod
local previousVisibleDistance
local previousUiVisibility
local previousDOF
local previousFreeCamData

local selectedPreviewMissionId
local hoveredPreviewMissionId

M.selectedPoiId = nil
M.hoveredPoiId = nil
M.hoveredListItem = nil
local transitionActive = false -- false = no transition, 1 = transition to big map, 2 = transition from big map
local transitionProgress = 0
local transitionTime = 0
local bigMapCamRotation
local bigMapInitialCamPos
local mapBoundaries
local mouseMoved = false
local lastMouseOverMap = false
local uiHasFocus = true
local camHeightAboveTerrain = 0
local airSoundId = nil
local mapBoundsFogPool
local simplifiedPath
local simplifiedPathDistance
local showNavigationMarker
local routePreview
local transitionSoundId
local currentlyVisibleIds = {}
local missionToOpenOnStart
local pendingAutoSelectPoiId

local cameraAdditionalHeightFactor = 0
local navigationBoundariesFactor = 1

-- Level properties
local bigMapTod
local showLevelBorders

local blockedInputActions = core_input_actionFilter.createActionTemplate({"gameCam", "vehicleTeleporting", "funStuff", "freeCam", "physicsControls", "vehicleSwitching", "walkingMode", "vehicleMenues", "aiControls", "photoMode", "couplers", "pause", "missionPopup", "resetPhysics", "appedit", "miniMap"})
local areBigMapActionsBlocked = false
local areUiActionsBlocked = false

local uiActions = {"menu_item_select"}

local function blockUiActions(block)
  core_input_actionFilter.setGroup('bigmapUiActions', uiActions)
  core_input_actionFilter.addAction(0, 'bigmapUiActions', block)
  areUiActionsBlocked = block == true
end

local function drawDebugStatus(text, isGood)
  local color = isGood and imgui.ImVec4(0.35, 1, 0.35, 1) or imgui.ImVec4(1, 0.4, 0.4, 1)
  imgui.TextColored(color, text)
end

local function getVisibleIdsInfo(limit)
  local visibleIds = {}
  local visibleCount = 0
  for _, id in pairs(currentlyVisibleIds or {}) do
    visibleCount = visibleCount + 1
    if #visibleIds < limit then
      table.insert(visibleIds, tostring(id))
    end
  end

  table.sort(visibleIds)
  local visibleLabel = #visibleIds > 0 and table.concat(visibleIds, ", ") or "-"
  if visibleCount > #visibleIds then
    visibleLabel = visibleLabel .. ", ..."
  end
  return visibleCount, visibleLabel
end

local function resetCamMovement()
  core_camera.moveForwardBackward(0)
  core_camera.moveLeftRight(0)
  core_camera.moveforward(0)
  core_camera.movebackward(0)
  core_camera.moveleft(0)
  core_camera.moveright(0)
end

local function clearCylinderCache()
  if mapBoundsFogPool then
    for _, fog in ipairs(mapBoundsFogPool) do
      fog:delete()
    end
    mapBoundsFogPool = nil
  end
end

local function setLevelProperties()
  if scenetree.theLevelInfo then
    bigMapTod = tonumber(scenetree.theLevelInfo.bigMapTimeOfDay) or previousTod
    showLevelBorders = scenetree.theLevelInfo.bigMapLevelBorderVisible
  end
end

local function getTransitionSmoothingRate(from, to, transitionDuration)
  return math.max(math.abs((to or 0) - (from or 0)) / math.max(transitionDuration, 1e-6), 1e-6)
end

local function createLevelBounds()
  if not mapBoundsFogPool then
    mapBoundsFogPool = {}
    for i = 1, 4 do
      local fog = createObject('TSStatic')
      fog:setField('shapeName', 0, "art/shapes/interface/bigmap/bigmap_fog_b_small.dae")

      fog.canSave = false
      fog.useInstanceRenderData = true
      fog.dynamic = true
      fog:registerObject(Sim.getUniqueName("mapBoundFog" .. i))
      mapBoundsFogPool[i] = fog
    end
  end

  local color = spaceSeparated4Values(0,0,0,0)
  for _, fog in ipairs(mapBoundsFogPool) do
    fog.hidden = false
    fog:setField('instanceColor', 0, color)
  end

  local extents = mapBoundaries:getExtents()
  local edgePoint1 = vec3((mapBoundaries.maxExtents.x + mapBoundaries.minExtents.x) / 2, mapBoundaries.minExtents.y, mapBoundaries.maxExtents.z)
  local rayMaxDist = extents.z * 1.1
  local rayDist = castRayStatic(edgePoint1, vec3(0,0,-1), rayMaxDist)
  if rayDist < rayMaxDist then
    edgePoint1.z = edgePoint1.z - rayDist
  end
  local edgePoint2 = vec3(mapBoundaries.minExtents.x, (mapBoundaries.maxExtents.y + mapBoundaries.minExtents.y) / 2, mapBoundaries.maxExtents.z)
  local rayDist = castRayStatic(edgePoint2, vec3(0,0,-1), rayMaxDist)
  if rayDist < rayMaxDist then
    edgePoint2.z = edgePoint2.z - rayDist
  end
  local edgePoint3 = vec3((mapBoundaries.maxExtents.x + mapBoundaries.minExtents.x) / 2, mapBoundaries.maxExtents.y, mapBoundaries.maxExtents.z)
  local rayDist = castRayStatic(edgePoint3, vec3(0,0,-1), rayMaxDist)
  if rayDist < rayMaxDist then
    edgePoint3.z = edgePoint3.z - rayDist
  end
  local edgePoint4 = vec3(mapBoundaries.maxExtents.x, (mapBoundaries.maxExtents.y + mapBoundaries.minExtents.y) / 2, mapBoundaries.maxExtents.z)
  local rayDist = castRayStatic(edgePoint4, vec3(0,0,-1), rayMaxDist)
  if rayDist < rayMaxDist then
    edgePoint4.z = edgePoint4.z - rayDist
  end
  local rot1 = quatFromDir(vec3(-1,0,0), vec3(0,0.6,1))
  local rot2 = quatFromDir(vec3(0,1,0), vec3(0.6,0,1))
  local rot3 = quatFromDir(vec3(1,0,0), vec3(0,-0.6,1))
  local rot4 = quatFromDir(vec3(0,-1,0), vec3(-0.6,0,1))
  mapBoundsFogPool[1]:setPosRot(edgePoint1.x, edgePoint1.y, edgePoint1.z, rot1.x, rot1.y, rot1.z, rot1.w)
  mapBoundsFogPool[2]:setPosRot(edgePoint2.x, edgePoint2.y, edgePoint2.z, rot2.x, rot2.y, rot2.z, rot2.w)
  mapBoundsFogPool[3]:setPosRot(edgePoint3.x, edgePoint3.y, edgePoint3.z, rot3.x, rot3.y, rot3.z, rot3.w)
  mapBoundsFogPool[4]:setPosRot(edgePoint4.x, edgePoint4.y, edgePoint4.z, rot4.x, rot4.y, rot4.z, rot4.w)
  mapBoundsFogPool[1]:setScale(vec3(camHeightAboveTerrain * 0.001, extents.x/1000 * 6, 1))
  mapBoundsFogPool[2]:setScale(vec3(camHeightAboveTerrain * 0.001, extents.y/1000 * 6, 1))
  mapBoundsFogPool[3]:setScale(vec3(camHeightAboveTerrain * 0.001, extents.x/1000 * 6, 1))
  mapBoundsFogPool[4]:setScale(vec3(camHeightAboveTerrain * 0.001, extents.y/1000 * 6, 1))
end

local fovMax = 42
local function frameObject(bbox, pitch, yaw, useCamYaw)
  local camMode = core_camera.getGlobalCameras()[cameraModeName]
  pitch = pitch or camMode.angle
  yaw = yaw or camMode.rotAngle
  local upperEdgePoint = vec3((bbox.maxExtents.x + bbox.minExtents.x) / 2, bbox.maxExtents.y, bbox.maxExtents.z)
  local lowerEdgePoint = vec3((bbox.maxExtents.x + bbox.minExtents.x) / 2, bbox.minExtents.y, bbox.minExtents.z)
  local lowerCamFovAngle = pitch + (fovMax - (fovMax * cameraAdditionalHeightFactor))/2
  local upperCamFovAngle = pitch - (fovMax - (fovMax * cameraAdditionalHeightFactor))/2
  local lowerCamFovDir = quatFromAxisAngle(xVector, (lowerCamFovAngle) / 180 * math.pi):__mul(yVector)
  local upperCamFovDir = quatFromAxisAngle(xVector, (upperCamFovAngle) / 180 * math.pi):__mul(yVector)
  local planeNormal = upperCamFovDir:cross(xVector)
  local camPos = lowerEdgePoint - lowerCamFovDir * intersectsRay_Plane(lowerEdgePoint, -lowerCamFovDir, upperEdgePoint, planeNormal)
  if not useCamYaw then
    camPos = camPos - bbox:getCenter()
    camPos = quatFromAxisAngle(zVector, (yaw) / 180 * math.pi):__mul(camPos)
    camPos = camPos + bbox:getCenter()

    -- Move backwards by a certain amount to account for the rotated camera
    local backwardsOffset = (bbox:getCenter() - camPos) * 0.1
    backwardsOffset.z = 0
    camPos = camPos - backwardsOffset
  end
  return camPos
end

local function includeClustersInBbox(bbox)
  for i, poi in ipairs(gameplay_rawPois.getRawPoiListByLevel(getCurrentLevelIdentifier())) do
    if poi.markerInfo.bigmapMarker then
      bbox:extend(poi.markerInfo.bigmapMarker.pos)
    end
  end

  local mapData = map.getMap()
  if mapData and mapData.nodes then
    for _, node in pairs(mapData.nodes) do
      if node.pos:length() < 1e14 then
        bbox:extend(node.pos)
      end
    end
  end
end

local function calculateCamPos()
  local camMode = core_camera.getGlobalCameras()[cameraModeName]
  bigMapCamRotation = quatFromDir(vec3(0,0,-1), yVector)
  bigMapCamRotation = quatFromAxisAngle(xVector, -(90 - camMode.angle) / 180 * math.pi):__mul(bigMapCamRotation)
  bigMapCamRotation = bigMapCamRotation:__mul(quatFromAxisAngle(zVector, camMode.rotAngle / 180 * math.pi))

  local camPos = vec3(0,0,0)
  local bbox
  if core_terrain.getTerrain() then
    bbox = core_terrain.getTerrain():getWorldBox()
    includeClustersInBbox(bbox)
  else
    local playerVehicle = getPlayerVehicle(0)
    bbox = Box3F()
    bbox:setExtents(vec3(1000, 1000, 1000))
    bbox:setCenter(playerVehicle and playerVehicle:getPosition() + vec3(0,0,500) or vec3(0, 0, 0))
    includeClustersInBbox(bbox)
  end

  -- Clamp the bbox height to a certain minimum height, so all maps behave similarily
  local bboxCenter = bbox:getCenter()
  local extents = bbox:getExtents()
  local heightBefore = extents.z
  extents.z = math.max(extents.z, (extents.x + extents.y) / 12)
  local heightAfter = extents.z
  bboxCenter.z = bboxCenter.z + (heightAfter - heightBefore) / 2
  bbox:setExtents(extents)
  bbox:scale3F(vec3(1.1,1.1,1))
  bbox:setCenter(bboxCenter)

  camPos = frameObject(bbox)
  camHeightAboveTerrain = (camPos.z or 0) - (bbox.minExtents.z or 0)

  -- Add a small offset to the camera to make room for the ui sidebar and the topbar
  local camDir = bigMapCamRotation * yVector
  local camLeft = zVector:cross(camDir):normalized()
  camPos = camPos + camLeft * (camHeightAboveTerrain / 10) * horizontalOffsetFactor
  camPos = camPos + camDir:z0() * (camHeightAboveTerrain / 10) * verticalOffsetFactor

  bigMapInitialCamPos = camPos
  mapBoundaries = bbox

  local navigationBoundaries = Box3F()
  navigationBoundaries.minExtents = mapBoundaries.minExtents
  navigationBoundaries.maxExtents = mapBoundaries.maxExtents
  navigationBoundaries:scale3F(vec3(navigationBoundariesFactor, navigationBoundariesFactor, 1))
  camMode.mapBoundaries = navigationBoundaries
end

local function buildTransitionPath(endMarkerData)
  local camMode = core_camera.getGlobalCameras()[cameraModeName]
  local previousNearClip = 0.1
  if scenetree.theLevelInfo then
    previousNearClip = scenetree.theLevelInfo.nearClip
  end

  local path = { looped = false, manualFov = false}
  local startPos = core_camera.getPosition()
  local playerVehicle = getPlayerVehicle(0)
  if not bigMap then
    -- transition to big map
    local transitionEndPos = bigMapInitialCamPos
    local oobb = playerVehicle:getSpawnWorldOOBB()
    local aabb = Box3F()
    aabb.minExtents = oobb:getCenter() - oobb:getHalfExtents()
    aabb.maxExtents = oobb:getCenter() + oobb:getHalfExtents()

    local vehicleFramePos = frameObject(aabb, 90, nil, true)
    local camDir = core_camera.getQuat() * yVector
    local downwardsRot = quatFromDir(vec3(0,0,-1), camDir)
    local m1 = { fov = core_camera.getFovDeg(), movingEnd = true, movingStart = false, positionSmooth = 0.5, pos = startPos, rot = core_camera.getQuat(), time = 0, trackPosition = false, nearClip = previousNearClip  }
    local m2 = { fov = core_camera.getFovDeg(), movingEnd = true, movingStart = true, positionSmooth = 0.5, pos = vehicleFramePos + 5*(vehicleFramePos-aabb:getCenter()), rot = downwardsRot, time = camMode.posTransitionTime/3, trackPosition = false, nearClip = 1 }
    local m3 = { fov = core_camera.getFovDeg(), movingEnd = false, movingStart = true, positionSmooth = 0.5, pos = vehicleFramePos + 30*(vehicleFramePos-aabb:getCenter()), rot = downwardsRot, time = camMode.posTransitionTime/2, trackPosition = false, nearClip = 1 }
    local m4 = { fov = camMode.fovMax, movingEnd = true, movingStart = true, positionSmooth = 0.1, pos = transitionEndPos, rot = bigMapCamRotation, time = camMode.posTransitionTime, trackPosition = false, nearClip = camMode.nearClipValue}
    path.markers = {m1, m2, m3, m4}
  else
    -- transition to player cam
    local oobb = playerVehicle:getSpawnWorldOOBB()
    local aabb = Box3F()
    aabb.minExtents = oobb:getCenter() - oobb:getHalfExtents()
    aabb.maxExtents = oobb:getCenter() + oobb:getHalfExtents()

    local vehicleFramePos = frameObject(aabb, 90, nil, false)
    local playerCamDir = endMarkerData.rot * yVector
    local downwardsRot = quatFromDir(vec3(0,0,-1), playerCamDir)
    local m1 = { fov = core_camera.getFovDeg(), movingEnd = true, movingStart = false, positionSmooth = 0.5, pos = startPos, rot = core_camera.getQuat(), time = 0, trackPosition = false, nearClip = camMode.nearClipValue  }
    local m2 = { fov = camMode.fovMax, movingEnd = true, movingStart = true, positionSmooth = 0.5, pos = vehicleFramePos + 30*(vehicleFramePos-aabb:getCenter()), rot = downwardsRot, time = camMode.posTransitionTime/2, trackPosition = false, nearClip = 1 }
    local m3 = { fov = endMarkerData.fov, movingEnd = false, movingStart = true, positionSmooth = 0.5, pos = vehicleFramePos + 5*(vehicleFramePos-aabb:getCenter()), rot = downwardsRot, time = camMode.posTransitionTime*(2/3), trackPosition = false, nearClip = 1 }
    local m4 = { fov = endMarkerData.fov, movingEnd = true, movingStart = true, positionSmooth = 0.5, pos = endMarkerData.pos, rot = endMarkerData.rot, time = camMode.posTransitionTime, trackPosition = false, nearClip = previousNearClip }
    path.markers = {m1, m2, m3, m4}
  end

  return path
end

local function setTime(time)
  local tod = core_environment.getTimeOfDay()
  if tod then
    tod.time = time
    core_environment.setTimeOfDay(tod)
  end
end

local function setOnlyIdsVisible(list)
  currentlyVisibleIds = list or {}
  M.updateMergeRadius(1)
  freeroam_bigMapMarkers.setupFilter(currentlyVisibleIds, M.clusterMergeRadius)
end
M.setOnlyIdsVisible = setOnlyIdsVisible

local function simplifyRoute(route)
  if not route or #route == 0 then return {} end
  local simple = {}
  local distance = 0
  local stepSize = camHeightAboveTerrain / navPathSimplificationFactor
  for index = 1, tableSize(route) - 1 do
    local pos1 = route[index].pos
    local pos2 = route[index+1].pos
    if distance <= 0 then
      table.insert(simple, pos1)
    end
    distance = distance + pos1:distance(pos2)
    if distance > stepSize then
      distance = 0
    end
  end
  table.insert(simple, route[tableSize(route)].pos)
  return simple
end

local function resetRoute()
  routeAnimCounter = 1
  simplifiedPath = nil
  if core_groundMarkers.currentlyHasTarget() then
    simplifiedPath = simplifyRoute(core_groundMarkers.routePlanner.path)
    simplifiedPathDistance = core_groundMarkers.routePlanner:calcDistance()
  else
    showNavigationMarker = false
  end
end

local navDestinationForLuaReloads
local function setNavFocus(pos)
  extensions.hook("onSetBigmapNavFocus", pos)
  if not getPlayerVehicle(0) then
    pos = nil
  end
  navDestinationForLuaReloads = pos
  core_groundMarkers.setPath(pos, {clearPathOnReachingTarget = true})
  resetRoute()
end

local function onReachedTargetPos()
  setNavFocus(nil)
end

local mouseDragging
local lastMousePos

local function onUpdate(dtReal, dtSim, dtRaw)
  if not bigMap then return end

  profilerPushEvent("BigMap onPreRender")
  if airSoundId then
    local sound = scenetree.findObjectById(airSoundId)
    if sound then
      sound:setTransform(getCameraTransform())
    end
  end

  local camMode = core_camera.getGlobalCameras()[cameraModeName]
  if debugWindow then
    if imgui.Begin("Big Map") then
      if imgui.TreeNode1("Current Camera Debug") then
        local maxFovPtr = imgui.FloatPtr(camMode.fovMax)
        if imgui.SliderFloat("Max FOV", maxFovPtr, 5.0, 90.0, "%.0f") then
          camMode.fovMax = maxFovPtr[0]
          camMode.manualzoom:init(camMode.fovMax, camMode.fovMin, camMode.fovMax)
          camMode:onCameraChanged(true)
        end
        local minFovPtr = imgui.FloatPtr(camMode.fovMin)
        if imgui.SliderFloat("Min FOV", minFovPtr, 5.0, 90.0, "%.0f") then
          camMode.fovMin = minFovPtr[0]
          camMode.manualzoom:init(camMode.fovMax, camMode.fovMin, camMode.fovMax)
          camMode:onCameraChanged(true)
        end
        local anglePtr = imgui.FloatPtr(camMode.angle)
        if imgui.SliderFloat("Angle", anglePtr, 5.0, 90.0, "%.0f") then
          camMode.angle = anglePtr[0]
          camMode:onCameraChanged(true)
        end
        local rotAnglePtr = imgui.FloatPtr(camMode.rotAngle)
        if imgui.SliderFloat("Rotation", rotAnglePtr, 0.0, 360.0, "%.0f") then
          camMode.rotAngle = rotAnglePtr[0]
        end
        local posTransitionTimePtr = imgui.FloatPtr(camMode.posTransitionTime)
        if imgui.SliderFloat("position transition time", posTransitionTimePtr, 0.0, 10.0, "%.1f") then
          camMode.posTransitionTime = posTransitionTimePtr[0]
        end
        local transitionActivePtr = imgui.BoolPtr(camMode.transitionActive)
        if imgui.Checkbox("Activate camera transition", transitionActivePtr) then
          camMode.transitionActive = transitionActivePtr[0]
        end
        local movementSpeedPtr = imgui.FloatPtr(camMode.movementSpeed)
        if imgui.SliderFloat("movement speed", movementSpeedPtr, 0.0, 100.0, "%.0f") then
          camMode.movementSpeed = movementSpeedPtr[0]
        end
        imgui.TreePop()
      end

      if imgui.TreeNode1("UI / Selection Debug") then
        local visibleCount, visibleIdsLabel = getVisibleIdsInfo(10)
        imgui.Columns(3, "BigMapDebugColumns", false)

        imgui.Text("Field")
        imgui.NextColumn()
        imgui.Text("Value")
        imgui.NextColumn()
        imgui.Text("Status")
        imgui.NextColumn()
        imgui.Separator()

        imgui.Text("Selected element")
        imgui.NextColumn()
        imgui.Text(tostring(M.selectedPoiId))
        imgui.tooltip(tostring(M.selectedPoiId))
        imgui.NextColumn()
        drawDebugStatus(M.selectedPoiId and "Selected" or "None", M.selectedPoiId ~= nil)
        imgui.NextColumn()

        imgui.Text("Hovered element")
        imgui.NextColumn()
        imgui.Text(tostring(M.hoveredPoiId))
        imgui.tooltip(tostring(M.hoveredPoiId))
        imgui.NextColumn()
        drawDebugStatus(M.hoveredPoiId and "Hovered" or "None", M.hoveredPoiId ~= nil)
        imgui.NextColumn()

        imgui.Text("Hovered list element")
        imgui.NextColumn()
        imgui.Text(tostring(M.hoveredListItem))
        imgui.tooltip(tostring(M.hoveredListItem))
        imgui.NextColumn()
        drawDebugStatus(M.hoveredListItem and "Hovered" or "None", M.hoveredListItem ~= nil)
        imgui.NextColumn()

        imgui.Text("UI has focus")
        imgui.NextColumn()
        imgui.Text(tostring(uiHasFocus))
        imgui.NextColumn()
        drawDebugStatus(uiHasFocus and "Focused" or "Unfocused", uiHasFocus)
        imgui.NextColumn()

        imgui.Text("Visible IDs")
        imgui.NextColumn()
        imgui.Text(string.format("%d (%s)", visibleCount, visibleIdsLabel))
        imgui.NextColumn()
        drawDebugStatus(visibleCount > 0 and "Filtered" or "All", visibleCount > 0)
        imgui.NextColumn()

        imgui.Text("Bigmap actions blocked")
        imgui.NextColumn()
        imgui.Text(tostring(areBigMapActionsBlocked))
        imgui.NextColumn()
        drawDebugStatus(areBigMapActionsBlocked and "Blocked" or "Unblocked", areBigMapActionsBlocked)
        imgui.NextColumn()

        imgui.Text("UI actions blocked")
        imgui.NextColumn()
        imgui.Text(tostring(areUiActionsBlocked))
        imgui.NextColumn()
        drawDebugStatus(areUiActionsBlocked and "Blocked" or "Unblocked", not areUiActionsBlocked)
        imgui.NextColumn()

        imgui.Columns(1)
        imgui.TreePop()
      end
      imgui.End()
    end
  end

  if not transitionActive then
    local iconRenderer = gameplay_playmodeMarkers.getBigmapRendererObj()
    local playerVehicle = getPlayerVehicle(0)
    if iconRenderer and playerVehicle then
      local iconInfo = iconRenderer:getIconByName("playerVehicle")
      if iconInfo then
        iconInfo.worldPosition = playerVehicle:getPosition()
        iconInfo.customSizeFactor = 0.8 + math.sin(os.clock()*4)*0.1

        -- Project the vehicle direction vector on to the camera plane and then determine the angle
        local vehDir = playerVehicle:getDirectionVector()
        local vehicleDirLocalX, vehicleDirLocalY = vehDir:dot(core_camera.getRight()), vehDir:dot(core_camera.getUp())
        local vehicleDirXYLocal = vec3(vehicleDirLocalX,vehicleDirLocalY,0)
        local det = vehicleDirLocalX * yVector.y - vehicleDirLocalY * yVector.x
        local angle = math.atan2(det, vehicleDirXYLocal:dot(yVector))
        iconInfo.rotation = angle
        iconInfo.drawIconShadow = false
      end
    end

    -- check which markers are hovered
    local lastHover = M.hoveredPoiId
    local mouseOverMap = not getCEFFocusMouse()
    if mouseOverMap ~= lastMouseOverMap then
      lastMouseOverMap = mouseOverMap
      if mouseOverMap then
        -- edge-triggered: notify the UI as soon as the cursor starts hovering the native
        -- map (not just when a specific POI marker is hovered), so it can switch out of
        -- list-focus navigation into map-exploration hints/behavior
        guihooks.trigger("BigmapMouseOverMap")
      end
    end
    if mouseOverMap then
      local hover = freeroam_bigMapMarkers.handleMouse(camMode, mouseMoved, M.selectedPoiId)
      -- a marker is hovered
      if hover then
        if hover ~= M.hoveredPoiId and hover ~= M.selectedPoiId then
          -- A new marker has been hovered
          Engine.Audio.playOnce('AudioGui','event:>UI>Bigmap>Hover_Icon')
        end
        M.hoveredPoiId = hover
      else
        -- The cursor is on the map, but no icon is hovered
        M.hoveredPoiId = nil
      end
    else
      -- The cursor is somewhere on the cef area
      M.hoveredPoiId = nil
    end
    if lastHover ~= M.hoveredPoiId then
      extensions.hook("onBigmapHoveredPoiIdChanged",M.hoveredPoiId)
      guihooks.trigger("BigmapHoveredPoiChanged", M.hoveredPoiId)
    end
  else
    -- Interpolate stuff during the transition
    transitionTime = transitionTime + dtReal
    local transitionDuration = math.max(camMode.posTransitionTime, 1e-6)
    transitionProgress = transitionTime / transitionDuration

    local fogDensityGoal
    local cloudCoverGoal
    local todGoal
    local levelBoundAlpha = 0
    if transitionActive == 1 then
      fogDensityGoal = 0
      cloudCoverGoal = 0
      todGoal = bigMapTod
      levelBoundAlpha = clamp(transitionProgress, 0, 1)
    elseif transitionActive == 2 then
      -- Shadows are now handled by screen space shadows
      fogDensityGoal = previousFogDensity
      cloudCoverGoal = previousCloudCover
      todGoal = previousTod
      levelBoundAlpha = 1 - clamp(transitionProgress, 0, 1)
    else
      fogDensityGoal = 0
    end
    local fogDensityRate = getTransitionSmoothingRate(previousFogDensity, 0, transitionDuration)
    local fogDensity = fogDensitySmoother:getWithRateUncapped(fogDensityGoal, dtReal, fogDensityRate)
    core_environment.setFogDensity(fogDensity)
    if previousCloudCover then
      local cloudCoverRate = getTransitionSmoothingRate(previousCloudCover, 0, transitionDuration)
      core_environment.setCloudCover(cloudCoverSmoother:getWithRateUncapped(cloudCoverGoal, dtReal, cloudCoverRate))
    end

    if mapBoundsFogPool then
      local color = spaceSeparated4Values(0,0,0,levelBoundAlpha)
      for _, fog in ipairs(mapBoundsFogPool) do
        fog:setField('instanceColor', 0, color)
      end
    end

    local currentTod = core_environment.getTimeOfDay()
    if currentTod and todGoal then
      local currentTime = currentTod.time

      if currentTime ~= todGoal then
        local difference = math.abs(todGoal - currentTime)
        local interpolationSpeed = (dtReal / transitionDuration)* 0.5 / (2/3) -- transition speed is enough so that it can change by 0.5 in two thirds of the transition time
        if currentTime < todGoal then
          if difference <= 0.5 then
            currentTod.time = math.min(todGoal, currentTod.time + interpolationSpeed)
          else
            currentTod.time = (currentTod.time - interpolationSpeed) % 1
          end
        else
          if difference <= 0.5 then
            currentTod.time = math.max(todGoal, currentTod.time - interpolationSpeed)
          else
            currentTod.time = (currentTod.time + interpolationSpeed) % 1
          end
        end
        core_environment.setTimeOfDay(currentTod)
      end
    end
  end
  if imgui.IsMouseDragging(0) then
    mouseDragging = true
  end

  freeroam_bigMapMarkers.displayBigMapMarkers(dtReal)

  local mousePos = imgui.GetMousePos()
  if lastMousePos and (mousePos.x ~= lastMousePos.x or mousePos.y ~= lastMousePos.y) then
    mouseMoved = true
  end
  lastMousePos = mousePos
  profilerPopEvent("BigMap onPreRender")
end

local function setActive(active)
  bigMap = active
  if bigMap then
    M.onUpdate = onUpdate
  else
    M.onUpdate = nil
  end
  extensions.hookUpdate("onUpdate")
end

local function activateBigMapCallback()
  local iconRenderer = gameplay_playmodeMarkers.getBigmapRendererObj()
  if not iconRenderer then return end
  iconRenderer:loadIconAtlas("core/art/gui/images/iconAtlas.png", "core/art/gui/images/iconAtlas.json");
  local playerVehicle = getPlayerVehicle(0)
  iconRenderer:addIcon("playerVehicle", "player_marker", playerVehicle and playerVehicle:getPosition() or vec3(0,0,0))
  local iconInfo = iconRenderer:getIconByName("playerVehicle")
  iconInfo.color = pureWhite
  iconInfo.customSizeFactor = 0.7
  local camDir = core_camera.getQuat() * yVector
  iconRenderer:addIcon("controllerCrosshair", "crosshair", core_camera.getPosition() + camDir * 150);
  local iconInfo = iconRenderer:getIconByName("controllerCrosshair")
  iconInfo.color = pureWhite
  iconRenderer:addIcon("navigationMarker", "navigation_marker", vec3(0,0,0))
  local iconInfo = iconRenderer:getIconByName("navigationMarker")
  iconInfo.color = invisibleColor
  iconInfo.customSizeFactor = 0.5

  transitionActive = false

  core_environment.setFogDensity(0)
  core_environment.setCloudCover(0)
  setTime(bigMapTod)

  fogDensitySmoother:set(0)
  cloudCoverSmoother:set(0)
  setActive(true)
  M.updateMergeRadius(1)

  if mapBoundsFogPool then
    local color = spaceSeparated4Values(0,0,0,1)
    for _, fog in ipairs(mapBoundsFogPool) do
      fog:setField('instanceColor', 0, color)
    end
  end

  extensions.hook("onActivateBigMapCallback")
  guihooks.trigger('bigmapTransitionFinished')
end

local function enableBigMapControls(enable)
  if enable then
    pushActionMap("BigMap")
  else
    popActionMap("BigMap")
  end
  core_input_actionFilter.setGroup('bigmapBlockedActions', blockedInputActions)
  core_input_actionFilter.addAction(0, 'bigmapBlockedActions', enable)
  areBigMapActionsBlocked = enable == true
  blockUiActions(enable)
end

M.enableBigMapControls = enableBigMapControls

local function deactivateBigMapCallback(closeEscMenu)
  simTimeAuthority.popPauseRequest("bigMap")
  core_environment.setFogDensity(previousFogDensity)
  core_environment.setCloudCover(previousCloudCover)
  ui_visibility.set(previousUiVisibility)
  setTime(previousTod)
  if previousVisibleDistance then
    scenetree.theLevelInfo.visibleDistance = previousVisibleDistance
    scenetree.theLevelInfo:postApply()
  end

  if previousDOF then
    local DOFPostEffect = scenetree.findObject("DOFPostEffect")
    DOFPostEffect:enable()
  end
  setActive(false)

  -- unblock input action
  enableBigMapControls(false)
  transitionActive = false

  if mapBoundsFogPool then
    for _, fog in ipairs(mapBoundsFogPool) do
      fog.hidden = true
    end
  end
  freeroam_bigMapPoiProvider.requestMissionLocationsForMinimap()

  if closeEscMenu then
    -- guihooks.trigger('MenuHide')
    extensions.ui_router.navigate("play")
  end
  gameplay_markerInteraction.skipNextIconFading()
  --gameplay_markerInteraction.setForceReevaluateOpenPrompt()
  gameplay_rawPois.clear()
  freeroam_bigMapMarkers.clearMarkers()
  M.deselect()
  extensions.hook("onDeactivateBigMapCallback")
  poiSelectCallback = nil
end

local function endTransition(activateBigMap, closeEscMenu, stopTransitionSound)
  core_camera.setByName(0, not activateBigMap and previousCamMode or cameraModeName, false, activateBigMap and {initialCamData = {pos = bigMapInitialCamPos, rot = bigMapCamRotation}})
  ui_visibility.set(previousUiVisibility)

  if stopTransitionSound and transitionSoundId then
    local sfxSource = scenetree.findObjectById(transitionSoundId)
    if sfxSource then
      sfxSource:stop(0.1)
    end
  end

  if activateBigMap then
    activateBigMapCallback()
  else
    deactivateBigMapCallback(closeEscMenu)
  end
end

local camPath
local function startTransition(endMarkerData, closeEscMenu)
  extensions.hook("onBigmapStartTransition",activateBigMap, closeEscMenu)
  endMarkerData.pos = vec3(endMarkerData.pos)
  endMarkerData.rot = quat(endMarkerData.rot.x, endMarkerData.rot.y, endMarkerData.rot.z, endMarkerData.rot.w)
  camPath = buildTransitionPath(endMarkerData)
  local currentBigMap = bigMap
  local initData = {}

  initData.useDtReal = true
  initData.finishedPath = function()
    endTransition(not currentBigMap, closeEscMenu)
  end
  transitionActive = currentBigMap and 2 or 1
  transitionTime = 0
  transitionProgress = 0
  setActive(true)
  ui_visibility.set(false)
  core_paths.playPath(camPath, 0, initData)
  if transitionActive == 1 then
    local sfxSource = Engine.Audio.playOnce('AudioGui','event:>UI>Bigmap>Whoosh_In')
    transitionSoundId = sfxSource and sfxSource.sourceId
  else
    local sfxSource = Engine.Audio.playOnce('AudioGui','event:>UI>Bigmap>Whoosh_Out')
    transitionSoundId = sfxSource and sfxSource.sourceId
  end
end



local function enterBigMapActual(instant, ignoreUiStateChange, ignoreActionMaps, routeTarget, routeParams)
  if bigMap then return end
  extensions.hook("onBeforeBigMapActivated")
  --freeroam_bigMapMarkers.buildPoiList() -- removed(testing)
  --freeroam_bigMapMarkers.setupFilter()

  core_camera.setLookBack(0, false) -- Disable lookback before going into bigmap
  local canvas = scenetree.findObject("Canvas")
  if canvas then
    verticalResolution = GFXDevice.getVideoMode().height
  end
  gameplay_playmodeMarkers.getBigmapRendererId()
  gameplay_rawPois.clear()
  freeroam_bigMapMarkers.clearMarkers()

  resetRoute()


  -- make the action map let through inputs, so the throttle cant get stuck on the vehicle
  local am = scenetree.findObject("BigMapActionMap")
  if am then am.trapHandledEvents = false end

  previousCloudCover = core_environment.getCloudCover()
  if commands.isFreeCamera() then
    previousFreeCamData = {pos = core_camera.getPosition(), rot = core_camera.getQuat(), fov = core_camera.getFovDeg()}
  else
    previousFreeCamData = nil
  end
  previousCamMode = core_camera.getActiveCamName()
  if previousCamMode == "path" then previousCamMode = "orbit" end
  previousFogDensity = core_environment.getFogDensity()
  previousTod = core_environment.getTimeOfDay() and core_environment.getTimeOfDay().time
  previousUiVisibility = ui_visibility.get()

  local DOFPostEffect = scenetree.findObject("DOFPostEffect")
  if DOFPostEffect then
    previousDOF = DOFPostEffect:isEnabled()
    DOFPostEffect:disable()
  end

  simTimeAuthority.pushPauseRequest("bigMap")

  local camMode = core_camera.getGlobalCameras()[cameraModeName]
  setLevelProperties()
  calculateCamPos()
  if showLevelBorders then
    createLevelBounds()
  else
    clearCylinderCache()
  end

  previousVisibleDistance = nil
  if (camHeightAboveTerrain * 5) > scenetree.theLevelInfo.visibleDistance then
    previousVisibleDistance = scenetree.theLevelInfo.visibleDistance
    scenetree.theLevelInfo.visibleDistance = camHeightAboveTerrain * 5
    scenetree.theLevelInfo:postApply()
  end

  camMode.fovMin = clamp(minZoomFactor / camHeightAboveTerrain, 10, camMode.fovMax)
  if useOrthoCamera then
    camMode.fovMin = 50
  end
  local openedInstant = commands.isFreeCamera() or not getPlayerVehicle(0) or instant
  if openedInstant then
    -- In freecam, skip the path transition but keep the same finalization path as transition flow.
    commands.setGameCamera()
    endTransition(true)
  else
    core_camera.getGlobalCameras().transition:start(false, {callback = startTransition})
    core_camera.setByName(0, cameraModeName, false, {initialCamData = {pos = bigMapInitialCamPos, rot = bigMapCamRotation}})
  end

  local sound = scenetree.findObjectById(airSoundId)
  if sound then
    sound:play(-1)
    sound:setVolume(1)
    sound:setTransform(getCameraTransform())
  end

  groundMarkerAlphaSmoother:set(0)
  fogDensitySmoother:set(previousFogDensity)
  if previousCloudCover then
    cloudCoverSmoother:set(previousCloudCover)
  end
  transitionTime = 0
  transitionProgress = 0

  if not poiSelectCallback and not ignoreUiStateChange then
    if not useVueBigMap then
      guihooks.trigger('MenuOpenModule', {state = "menu.bigmap", params = {missionId = missionToOpenOnStart}})
    else
      -- guihooks.trigger('MenuOpenModule', {state = "bigmap", params = {instant = openedInstant}})
      if not routeTarget then
        routeTarget = "bigmap"
      end
      local params = type(routeParams) == "table" and deepcopy(routeParams) or {}
      params.instant = openedInstant
      ui_router.navigate(routeTarget, params)
    end
  end
  missionToOpenOnStart = nil

  -- block some actions
  if not ignoreActionMaps then
    enableBigMapControls(true)
  end

  extensions.hook("onBigMapActivated")
end

local function enterBigMap(options)
  -- dont allow opening the bigmap if a mission is starting/stopping
  if gameplay_missions_missionManager.getCurrentTaskdataTypeOrNil() then
    return
  end


  if ui_pause_camera and ui_pause_camera.stop then
    local stopped = ui_pause_camera.stop()
    if stopped then
      options.instant = true
      log("I",logTag, "Opening Bigmap instantly, because the pause camera was active")
    end
  end

  if bigMap or (core_camera.getActiveCamName() == cameraModeName and not commands.isFreeCamera()) or not getCurrentLevelIdentifier() then return end
  options = options or {}
  if options.missionId then
    missionToOpenOnStart = options.missionId
  end
  -- consumed once by the Vue bigmap after it has mounted and is ready to select (see getAndClearPendingAutoSelectPoiId)
  pendingAutoSelectPoiId = options.autoSelectPoiId
  if options.cameraAdditionalHeightFactor then
    cameraAdditionalHeightFactor = options.cameraAdditionalHeightFactor
  else
    cameraAdditionalHeightFactor = 0
  end

  if options.horizontalOffsetFactor then
    horizontalOffsetFactor = options.horizontalOffsetFactor
  else
    horizontalOffsetFactor = 1
  end

  if options.verticalOffsetFactor then
    verticalOffsetFactor = options.verticalOffsetFactor
  else
    verticalOffsetFactor = 1
  end

  if options.navigationBoundariesFactor then
    navigationBoundariesFactor = options.navigationBoundariesFactor
  else
    navigationBoundariesFactor = 1
  end

  if useOrthoCamera then
    options.instant = true
  end

  local routeParams = options.routeParams
  if options.mode then
    routeParams = routeParams or {}
    routeParams.mode = options.mode
  end

  enterBigMapActual(options.instant or (render_openxr and render_openxr.isSessionRunning()), options.ignoreUiStateChange, options.ignoreActionMaps, options.routeTarget, routeParams)
end

local function exitBigMap(instant, closeEscMenu, forceGameCam)
  if not bigMap then return end
  resetCamMovement()
  -- when forcing the game cam and previousFreeCamData is not nil, then we change it to orbit cam
  if forceGameCam and previousFreeCamData then
    previousFreeCamData = nil
    previousCamMode = "orbit"
  end

  instant = instant or useOrthoCamera or previousFreeCamData or (render_openxr and render_openxr.isSessionRunning())
  if instant then
    freeroam_bigMapMarkers.clearMarkers()
  else
    freeroam_bigMapMarkers.hideMarkers()
  end
  local playerVehicle = getPlayerVehicle(0)
  if playerVehicle and not instant and not transitionActive then
    core_camera.getGlobalCameras().transition:start(false, {callback = function(endMarkerData) startTransition(endMarkerData, closeEscMenu) end})
    core_camera.setByName(0, previousCamMode, false)
  else
    if previousFreeCamData or not playerVehicle then
      commands.setFreeCamera()
      if previousFreeCamData then
        local pos = previousFreeCamData.pos
        local rot = previousFreeCamData.rot
        core_camera.setPosRot(0, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
        core_camera.setFOV(0, previousFreeCamData.fov)
      end
    else
      core_camera.setByName(0, previousCamMode, false)
    end
    deactivateBigMapCallback(closeEscMenu)
  end
  local sound = scenetree.findObjectById(airSoundId)
  if sound then
    sound:stop(-1)
    sound:setVolume(1)
    sound:setTransform(getCameraTransform())
  end

  groundMarkerAlphaSmoother:set(1)
  fogDensitySmoother:set(0)
  cloudCoverSmoother:set(0)

  local iconRenderer = gameplay_playmodeMarkers.getBigmapRendererObj()
  if iconRenderer then
    iconRenderer:removeAllIcons()
  end
  currentlyVisibleIds = {}
end

local function bigMapActive()
  return bigMap
end

local function isTransitionActive()
  return transitionActive
end

local canOpenBigMapFromRoute = { play = true, pause = true }

local function toggleBigMap()
  if transitionActive then
    if transitionActive == 1 then
      endTransition(true, nil, true)
    else
      endTransition(false, true, true)
    end
  else
    if bigMap then
      if career_career.isActive()
        and career_modules_delivery_general.isDeliveryModeActive()
        and career_modules_delivery_cargoScreen.isCargoScreenOpen()
         then
        exitBigMap(true, true)
      else
        exitBigMap(false, true)
      end
    else
      local currentRoute = ui_router.getCurrent()
      if currentRoute and currentRoute.resolved and not canOpenBigMapFromRoute[currentRoute.resolved.name] then
        log("I", logTag, "Cannot open bigmap from route: " .. currentRoute.resolved.name)
        return
      end
      if gameplay_missions_missionManager.isCurrentlyProcessingStep() then
        log("I", logTag, "Cannot open bigmap, mission is processing step")
        return
      end
      if gameplay_taxi and gameplay_taxi.isTaxiRideActive() then
        gameplay_taxi.onChangeDestinationCalled()
      elseif career_career.isActive() and career_modules_delivery_general.isDeliveryModeActive() then
        career_modules_delivery_cargoScreen.enterMyCargo()
      else
        enterBigMap({ignoreUiStateChange = false})
      end
    end
  end
end

local function zoom(value)
  local camMode = core_camera.getGlobalCameras()[cameraModeName]
  if camMode then
    camMode:zoom(value)
  end
end

local zoomInValue = 0
local zoomOutValue = 0
local function zoomInOut(value, zoomIn)
  if zoomIn then
    zoomInValue = -value
  else
    zoomOutValue = value
  end
  core_camera.cameraZoom(zoomInValue + zoomOutValue)
end

local function controllerZoom(value, zoomIn)
  core_camera.cameraZoom(value)
end

local function pointRayDistance(point, rayPos, rayDir)
  return (point - rayPos):cross(rayDir):length() / rayDir:length()
end

local function onCameraPreRender(camData)
  if not bigMapActive() then return end
  profilerPushEvent("bigmap onCameraPreRender")
  if not transitionActive then
    local iconRenderer = gameplay_playmodeMarkers.getBigmapRendererObj()
    if iconRenderer then
      local iconInfo = iconRenderer:getIconByName("controllerCrosshair")
      if iconInfo then
        local camDir = camData.res.rot * yVector
        iconInfo.worldPosition = camData.res.pos + camDir * 150
        if mouseMoved or uiHasFocus then
          iconInfo.color = invisibleColor
        else
          iconInfo.color = pureWhite
        end
      end

      local iconInfo = iconRenderer:getIconByName("navigationMarker")
      if iconInfo then
        if showNavigationMarker and core_groundMarkers.currentlyHasTarget() then
          local resolutionFactor = 800 / M.getVerticalResolution()
          local camQuat = camData.res.rot
          local camUp = camQuat * upVector
          local camToCluster = core_groundMarkers.endWP[1] - camData.res.pos
          local camToClusterLeft = camUp:cross(camToCluster):normalized()
          local camToUpperPoint = quatFromAxisAngle(camToClusterLeft, (resolutionFactor * 0.015 * core_camera.getFovRad())):__mul(camToCluster)

          if useOrthoCamera then
            iconInfo.worldPosition = core_groundMarkers.endWP[1] + camData.res.rot * zVector * resolutionFactor * camData.res.fov/65
          else
            iconInfo.worldPosition = camData.res.pos + camToUpperPoint
          end
          iconInfo.color = pureWhite
        else
          iconInfo.color = invisibleColor
        end
      end
    end
  else
    -- Snap the camera to a straight line in part of the path to make it more stable
    if camPath then
      if transitionActive == 1 then
        if transitionTime < camPath.markers[3].time then
          local lineP1P3 = camPath.markers[3].pos - camPath.markers[1].pos
          local camVec = camData.res.pos - camPath.markers[1].pos
          local dotProduct = lineP1P3:dot(camVec)
          camData.res.pos = camPath.markers[1].pos + (lineP1P3:normalized() * (dotProduct / lineP1P3:length()))
        end
      elseif transitionActive == 2 then
        if transitionTime > camPath.markers[2].time then
          local lineP2P4 = camPath.markers[4].pos - camPath.markers[2].pos
          local camVec = camData.res.pos - camPath.markers[2].pos
          local dotProduct = lineP2P4:dot(camVec)
          camData.res.pos = camPath.markers[2].pos + (lineP2P4:normalized() * (dotProduct / lineP2P4:length()))
        end
      end
    end
  end

  -- Calculate the alpha based on the type and progress of transition
  local alphaGoal
  if transitionActive == 1 then
    alphaGoal = (transitionProgress > 0.5) and 1 or 0
  elseif transitionActive == 2 then
    alphaGoal = 0
  else
    alphaGoal = 1
  end
  local navRouteAlpha = groundMarkerAlphaSmoother:getWithRateUncapped(alphaGoal, camData.dtReal, 0.85)
  local simplifiedPathLength = simplifiedPath and tableSize(simplifiedPath)
  if simplifiedPathLength and simplifiedPathLength > 1 then
    local lineWidth = (camHeightAboveTerrain * camData.res.fov) / 20000
    local h, s, v = RGBtoHSV(unpack(core_groundMarkers.color)) -- groundMarkerColor
    local r, g, b = HSVtoRGB(h, s, 1)
    local color = ColorF(r, g, b, navRouteAlpha)
    for index = 1, routeAnimCounter do
      local pos1 = simplifiedPath[index]
      local pos2 = simplifiedPath[index+1]
      local b = camData.res.pos * 0.8
      local newPos1 = pos1 * 0.2; newPos1:setAdd(b)
      local newPos2 = pos2 * 0.2; newPos2:setAdd(b)
      if useOrthoCamera then
        pos1 = pos1 + camData.res.rot * -yVector * 100
        pos2 = pos2 + camData.res.rot * -yVector * 100
        debugDrawer:drawCylinder(pos1, pos2, camData.res.fov / 200, color)
      else
        debugDrawer:drawCylinder(newPos1, newPos2, lineWidth/2, color)
      end
    end

    -- speed up the animation for short paths
    local routeLengthMultiplier = 1
    if simplifiedPathDistance < 500 then
      routeLengthMultiplier = 2
    end

    local animCounterStep = (camData.dtReal) * simplifiedPathLength * routeLengthMultiplier * routeAnimSpeedFactor
    routeAnimCounter = math.min(simplifiedPathLength - 1, routeAnimCounter + animCounterStep)
  end

  -- display mission route preview
  if routePreview and #routePreview > 1 then
    local lineWidth = (camHeightAboveTerrain * camData.res.fov) / 20000
    local h, s, v = RGBtoHSV(unpack(core_groundMarkers.color or {0.1, 0.25, 0.5})) -- groundMarkerColor
    local r, g, b = HSVtoRGB(h, 0.3, 1) -- routePreviewCol
    local color = ColorF(r, g, b, navRouteAlpha * 0.7)

    for index = 1, #routePreview-1 do
      local pos1 = routePreview[index]
      local pos2 = routePreview[index+1]
      local b = camData.res.pos * 0.85
      local newPos1 = pos1 * 0.15; newPos1:setAdd(b)
      local newPos2 = pos2 * 0.15; newPos2:setAdd(b)
      if useOrthoCamera then
        pos1 = pos1 + camData.res.rot * -yVector * 100
        pos2 = pos2 + camData.res.rot * -yVector * 100
        debugDrawer:drawCylinder(pos1, pos2, camData.res.fov / 200, color)
      else
        debugDrawer:drawCylinder(newPos1, newPos2, lineWidth/6, color)
      end
    end
  end

  profilerPopEvent("bigmap onCameraPreRender")
end

local function getMissionById(missionId)
  local mission = gameplay_missions_missions.getMissionById(missionId)

  -- this is a hack for "-1"-location suffix
  if not mission then
    mission = gameplay_missions_missions.getMissionById(string.sub(missionId, 1, -3))
  end
  return mission
end

local function clearRoutePreview() routePreview = nil end
M.clearRoutePreview = clearRoutePreview
local function setRoutePreview(unsimplifiedRoute)
  if not unsimplifiedRoute then
    routePreview = nil
  else
    routePreview = simplifyRoute(unsimplifiedRoute)
  end
end
M.setRoutePreview = setRoutePreview
local function setRoutePreviewSimple(from, to)
  local ret = {from, to}
  -- calculate in-world route
  local route = require('/lua/ge/extensions/gameplay/route/route')()
  route:setupPathMulti(ret)
  routePreview = simplifyRoute(route.path)
end
M.setRoutePreviewSimple = setRoutePreviewSimple

local function showMissionWorldPreview(missionId)
  local poi = gameplay_rawPois.getRawPoiListByLevel(getCurrentLevelIdentifier())
  for _, p in ipairs(poi) do
    if p.id == missionId then
      if not p.data.type or p.data.type ~= "mission" then
        return
      end
    end
  end
  local mission = getMissionById(missionId)
  if not mission then return end

  if mission.getWorldPreviewRoute then
    routePreview = simplifyRoute(mission:getWorldPreviewRoute())
    return missionId
  else
    routePreview = nil
  end
end


-- called from the UI when a poi is hovered in the list.
local function poiHovered(poiIdInCluster, hovered)
  if hovered then
    hoveredPreviewMissionId = showMissionWorldPreview(poiIdInCluster)
  else
    if selectedPreviewMissionId then
      showMissionWorldPreview(selectedPreviewMissionId)
    else
      clearRoutePreview()
    end
    hoveredPreviewMissionId = nil
  end
  M.hoveredListItem = hovered and poiIdInCluster or nil
end

local function deselect()
  --local missionIds = getPoiIds()
  guihooks.trigger("onReducedPoiList", {missionIds = {}})
  extensions.hook("onPoiSelectedFromBigmap",nil)
  if M.selectedPoiId then
    M.selectedPoiId = nil

    if not hoveredPreviewMissionId then
      clearRoutePreview()
    end
    selectedPreviewMissionId = nil
    if poiSelectCallback then
      poiSelectCallback(nil)
    end
  end
end

local function navigateToMission(poiId)
  if career_modules_testDrive and career_modules_testDrive.isActive() then return end

  for i, cluster in ipairs(gameplay_playmodeMarkers.getPlaymodeClusters()) do
    local marker = gameplay_playmodeMarkers.getMarkerForCluster(cluster)
    if cluster.containedIdsLookup and cluster.containedIdsLookup[poiId] then
      cluster.focus = true
      setNavFocus(marker.pos)
      showNavigationMarker = false
      extensions.hook("onNavigateToMission", cluster.id)
      return marker
    end
  end
  -- if none has been found, use the bigmapMarkers instead
  for i, poi in ipairs(gameplay_rawPois.getRawPoiListByLevel(getCurrentLevelIdentifier())) do
    if poi.id ==  poiId and poi.markerInfo.bigmapMarker then
      local pos = poi.markerInfo.bigmapMarker.pos
      if poi.customNavigationFunction then
        pos = poi.customNavigationFunction(poi)
        resetRoute()
      else
        setNavFocus(pos)
      end
      showNavigationMarker = false
      extensions.hook("onNavigateToMission", poiId)
      return marker
    end
  end

  extensions.hook("onNavigateToMission", nil)
  setNavFocus(nil)
end

-- smoothly pan the bigmap camera so that the given poi is centered, without changing navigation/selection
local function panToPoi(poiId)
  if not poiId or poiId == "" or poiId == "null" or poiId == "undefined" then return end

  local targetPos
  for i, cluster in ipairs(gameplay_playmodeMarkers.getPlaymodeClusters()) do
    if cluster.containedIdsLookup and cluster.containedIdsLookup[poiId] then
      local marker = gameplay_playmodeMarkers.getMarkerForCluster(cluster)
      targetPos = marker and marker.pos
      break
    end
  end
  if not targetPos then
    for i, poi in ipairs(gameplay_rawPois.getRawPoiListByLevel(getCurrentLevelIdentifier())) do
      if poi.id == poiId and poi.markerInfo.bigmapMarker then
        targetPos = poi.markerInfo.bigmapMarker.pos
        break
      end
    end
  end
  if not targetPos then return end

  local cam = core_camera.getGlobalCameras()[cameraModeName]
  if cam and cam.panToWorldPos then
    cam:panToWorldPos(targetPos)
  end
end

local function setUiNavigationActive(active)
  if not bigMapActive() then
    return
  end

  uiHasFocus = active == true
  blockUiActions(not uiHasFocus)
end

local function onMenuItemNavigation()
  setUiNavigationActive(true)
end

-- returns and clears the poiId requested via enterBigMap({autoSelectPoiId = ...}), so the Vue
-- bigmap can select it once it has actually mounted (selecting eagerly here races the UI mount)
local function getAndClearPendingAutoSelectPoiId()
  local poiId = pendingAutoSelectPoiId
  pendingAutoSelectPoiId = nil
  return poiId
end

-- called from the UI
local function selectPoi(poiIdInCluster)
  if not poiIdInCluster or poiIdInCluster == "" or poiIdInCluster == "null" or poiIdInCluster == "undefined" then
    return M.deselect()
  end
  M.selectedPoiId = poiIdInCluster
  selectedPreviewMissionId = showMissionWorldPreview(poiIdInCluster)
  onMenuItemNavigation()
  extensions.hook("onPoiSelectedFromBigmap", poiIdInCluster)
  if poiSelectCallback then
    poiSelectCallback(poiIdInCluster)
  end
end

local function teleportFromBigmapToTarget(veh, pos, rot)
  if career_career.isActive() then
    spawn.safeTeleport(veh, pos, rot, nil, nil, nil, nil, false)
  else
    spawn.safeTeleport(veh, pos, rot)
    veh:resetBrokenFlexMesh()
  end

  if core_groundMarkers.currentlyHasTarget() then
    setNavFocus(core_groundMarkers.endWP[1])
  end
  exitBigMap(false, true, true)
  core_camera.resetCamera(0)
  extensions.hook("teleportedFromBigmap")
end

local function teleportToPoi(poiId)
  -- set target for markerInteraction
  for i, cluster in ipairs(gameplay_playmodeMarkers.getPlaymodeClusters()) do
    if cluster.containedIdsLookup and cluster.containedIdsLookup[poiId] then
      cluster.focus = true
      extensions.hook("onNavigateToMission", cluster.id)
      gameplay_markerInteraction.reachedTargetPos = cluster.pos
    end
  end

  for _, poi in ipairs(gameplay_rawPois.getRawPoiListByLevel(getCurrentLevelIdentifier())) do
    if poiId == poi.id then
      local veh = getPlayerVehicle(0)
      if veh then
        local pos, rot = (poi.markerInfo.bigmapMarker.quickTravelPosRotFunction or nop)(poi, veh)
        if pos and rot then
          teleportFromBigmapToTarget(veh, pos, rot)
        end
      end
    end
  end
end

local function camMoveController(upDown, value)
  if core_camera then
    if upDown then
      core_camera.moveForwardBackward(sign(value) * value^2)
    else
      core_camera.moveLeftRight(sign(value) * value^2)
    end
    if uiHasFocus and math.abs(value or 0) > 0.01 then
      guihooks.trigger("BigmapCameraMove", {upDown = upDown, value = value})
      uiHasFocus = false
    end
    -- if uiHasFocus then
    --   blockUiActions(true)
    --   uiHasFocus = false
    -- end
  end
  mouseMoved = false
end


local function camMoveKey(value, direction)
  if core_camera then
    if direction == 1 then
      core_camera.moveforward(value)
    elseif direction == 2 then
      core_camera.movebackward(value)
    elseif direction == 3 then
      core_camera.moveleft(value)
    else
      core_camera.moveright(value)
    end
  end
end

-- called when the user clicks the mouse
local function clickOnMap()
  -- deselecting the current marker
  --log("I", "", string.format("Sel: %s Hov: %s HasTgt: %s", M.selectedPoiId, M.hoveredPoiId, dumps(core_groundMarkers.currentlyHasTarget())))
  if M.selectedPoiId and (not M.hoveredPoiId or M.selectedPoiId == M.hoveredPoiId) then
    deselect()
    return
  end

  -- clicking the map to set a route anywhere.
  if not M.hoveredPoiId and not core_groundMarkers.currentlyHasTarget() then
    local ray
    if mouseMoved then
      ray = getCameraMouseRay()
    else
      local camDir = core_camera.getQuat() * yVector
      ray = {pos = core_camera.getPosition(), dir = camDir}
    end
    local hitDist = castRayStatic(ray.pos, ray.dir, 50000)
    if hitDist < 50000 then
      setNavFocus(ray.pos + ray.dir * hitDist)
      showNavigationMarker = true
      Engine.Audio.playOnce('AudioGui','event:>UI>Main>Click_Tonal_01')
    end
    return
  end

  -- remove navigation when the ground is clicked, but only when no mission is selected
  if not M.selectedPoiId and not M.hoveredPoiId and core_groundMarkers.currentlyHasTarget() then
    navigateToMission(nil)
    return
  end

  -- selecting a marker
  if M.hoveredPoiId then
    local missionIds = freeroam_bigMapMarkers.getIdsFromHoveredPoiId(M.hoveredPoiId)
    if not tableIsEmpty(missionIds) then
      local missionIdsById = {}
      for _, v in ipairs(missionIds) do
        missionIdsById[v] = true
      end
      guihooks.trigger("onReducedPoiList", {missionIds = missionIdsById, selectOrder = missionIds, defaultHighlight = mouseMoved ~= true})
      selectPoi(M.hoveredPoiId)
    end
    Engine.Audio.playOnce('AudioGui','event:>UI>Main>select')
    return
  end
end

local function onMouseButton(buttonDown)
  local camMode = core_camera.getGlobalCameras()[cameraModeName]
  if not buttonDown and not mouseDragging then
    clickOnMap()
  end
  if not buttonDown then
    mouseDragging = false
  end
  camMode:onMouseButton(buttonDown, mouseDragging)
end

local function onControllerSelect()
  -- check if ray intersects with iconPos / cluster.radius. then show it to UI
  if not mouseMoved and not uiHasFocus then
    clickOnMap()
  end
end

local function updateMergeRadius(factor)
  local camMode = core_camera.getGlobalCameras()[cameraModeName]
  if useOrthoCamera then
    M.clusterMergeRadius = lerp(camMode.fovMin / 20, camMode.fovMax / 20, factor )
  else
    local maxMergeRadius = (camHeightAboveTerrain * camMode.fovMax) / 1000
    local minMergeRadius = (camHeightAboveTerrain * camMode.fovMin) / 1000
    M.clusterMergeRadius = lerp(minMergeRadius, maxMergeRadius, factor)
  end
  freeroam_bigMapMarkers.setupFilter(currentlyVisibleIds, M.clusterMergeRadius)
  --updateOnlyIdsVisible(true)
end

local function onSerialize()
  local data = {}
  data.airSoundId = airSoundId
  data.bigMap = bigMap
  data.navDestinationForLuaReloads = navDestinationForLuaReloads
  data.showNavigationMarker = showNavigationMarker
  if bigMap then
    -- Just calling exitBigMap in onSerialize doesnt work correctly for some reason, so we have to do some stuff manually
    data.previousCamMode = previousCamMode
    data.previousFreeCamData = previousFreeCamData
    exitBigMap(true, true)
  end
  clearCylinderCache()

  return data
end

local function onDeserialized(v)
  airSoundId = v.airSoundId
  showNavigationMarker = v.showNavigationMarker
  if v.bigMap then
    extensions.core_jobsystem.create(
      function (job)
        job.sleep(0.1)
        simTimeAuthority.setInstant(simTimeAuthority.getInitialTimeScale() or 1)
        enterBigMapActual(true)
        previousCamMode = v.previousCamMode
        previousFreeCamData = v.previousFreeCamData
        if v.navDestinationForLuaReloads and not career_career.isActive() then
          setNavFocus(v.navDestinationForLuaReloads)
        end
      end
    )
  elseif v.navDestinationForLuaReloads and not career_career.isActive() then
    extensions.core_jobsystem.create(
      function (job)
        job.sleep(0.1)
        setNavFocus(v.navDestinationForLuaReloads)
      end
    )
  end
end

local function getVerticalResolution()
  return verticalResolution
end

local function onClientStartMission(levelPath)
  setActive(false)
  if not airSoundId then
    airSoundId = Engine.Audio.createSource('AudioGui', 'event:>UI>Bigmap>Ambience')
  else
    local sound = scenetree.findObjectById(airSoundId)
    if not sound then
      airSoundId = Engine.Audio.createSource('AudioGui', 'event:>UI>Bigmap>Ambience')
    end
  end
end

local function onClientEndMission(levelPath)
  clearCylinderCache()
  deselect()

  if airSoundId then
    local sound = scenetree.findObjectById(airSoundId)
    if sound then
      sound:delete()
    end
  end

end

local function onNavgraphReloaded()
  if bigMap then
    exitBigMap(true)
    enterBigMap({instant = true})
  end
end

local changeUiFilterPressed = {}
local function onChangeUiFilter(value, dir)
  if not changeUiFilterPressed[dir] and value > 0.65 then
    changeUiFilterPressed[dir] = true
    guihooks.trigger("onChangeBigmapFilterIndex", {change = dir})
  end

  if changeUiFilterPressed[dir] and value < 0.35 then
    changeUiFilterPressed[dir] = nil
  end
end


local function enterBigMapWithCustomPOIs(poiIds, callback, options)
  poiSelectCallback = callback
  if options and options.suppressUI then
    poiSelectCallback = nop
  end
  enterBigMap(options)
  setOnlyIdsVisible(poiIds)
end

local function isUsingOrthoCamera()
  return useOrthoCamera
end

-- testing for UI
local function setBigmapScreenBounds(windowSize, mapSize)

end
M.setBigmapScreenBounds = setBigmapScreenBounds

-- public interface
M.enterBigMap = enterBigMap
M.exitBigMap = exitBigMap
M.toggleBigMap = toggleBigMap
M.bigMapActive = bigMapActive
M.isTransitionActive = isTransitionActive
M.zoom = zoom
M.zoomInOut = zoomInOut
M.controllerZoom = controllerZoom
M.navigateToMission = navigateToMission
M.panToPoi = panToPoi
M.selectPoi = selectPoi
M.getAndClearPendingAutoSelectPoiId = getAndClearPendingAutoSelectPoiId
M.teleportToPoi = teleportToPoi
M.clusterMergeRadius = 10 -- TODO adjust this merge radius
M.updateMergeRadius = updateMergeRadius
M.deselect = deselect
M.setNavFocus = setNavFocus
M.getVerticalResolution = getVerticalResolution
M.poiHovered = poiHovered
M.enterBigMapWithCustomPOIs = enterBigMapWithCustomPOIs
M.resetRoute = resetRoute
M.isUsingOrthoCamera = isUsingOrthoCamera

M.onClientStartMission    = onClientStartMission
M.onClientEndMission      = onClientEndMission
M.onMouseButton = onMouseButton
M.onControllerSelect = onControllerSelect
M.camMoveController = camMoveController
M.camMoveKey = camMoveKey
M.onCameraPreRender = onCameraPreRender
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onMenuItemNavigation = onMenuItemNavigation
M.setUiNavigationActive = setUiNavigationActive
M.onNavgraphReloaded = onNavgraphReloaded
M.onChangeUiFilter = onChangeUiFilter
M.onReachedTargetPos = onReachedTargetPos

return M
