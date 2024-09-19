-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local min = math.min
local max = math.max
local abs = math.abs
local acos = math.acos
local ceil = math.ceil
local pi = math.pi

local M = {}
M.routePlanner = require('/lua/ge/extensions/gameplay/route/route')()
M.debugPath = false

local decals = {}
local numDecals = 0

local arrowPoolId
local arrowLerpInfos = {}
local wpToArrowMap = {}
local arrowToWpMap = {}
local upVec = vec3(0,0,1)

local arrowScale = 3

-- global functions for backwards compatibility
local deprecationWarningDone = {}
local function deprecationWarning(oldFunction, newFunction)
  if not deprecationWarningDone[oldFunction] then
    log('W', logTag, string.format('function "%s" is deprecated. Please use function "%s" instead', oldFunction, newFunction))
    deprecationWarningDone[oldFunction] = true
  end
end

local function getPathLength()
  if M.routePlanner.path and M.routePlanner.path[1] then
    return M.routePlanner.path[1].distToTarget
  end
  return 0
end

local function getPathPositionDirection(dist, lastNodeData)
  local walkDist = lastNodeData.dist
  for i = lastNodeData.i, (lastNodeData.pathSize - 1) do
    local a = lastNodeData.path[i].pos
    local b = lastNodeData.path[i + 1].pos
    local nodeDist = (b-a):length()
    if walkDist + nodeDist >= dist then
      local factor = (dist - walkDist) / nodeDist
      local position = (a * (1 - factor)) + (b * factor)
      local normal = (b-a):normalized()
      lastNodeData.i = i
      lastNodeData.dist = walkDist
      return position, normal
    else
      walkDist = walkDist + nodeDist
    end
  end
  lastNodeData.i = lastNodeData.pathSize
  lastNodeData.dist = walkDist
  return nil
end

local decalScale = 3
local function getNewData()
  -- create decals
  local data = {
    texture = 'art/shapes/arrows/arrow_groundmarkers_1.png',
    pos = vec3(),
    position = vec3(0, 0, 0),
    forwardVec = vec3(0, 0, 0),
    color = ColorF(M.color[1], M.color[2], M.color[3], 0 ),
    scale = vec3(1*decalScale, 1*decalScale, 1*decalScale),
    fadeStart = 150,
    fadeEnd = 200
  }
  return data
end

local function calculateAlpha(pos, start, dist)
  local linearAlpha = min(dist, max(0, pos - start)) / dist
  return 0.5-square(square(1-linearAlpha)) -- increase opacity much sooner than a linear ramp
end

M.decalPool = {}
M.decalPoolCount = 0
M.decalDrawingDistance = 150--m
M.decalBlendOffset = 1--m
M.decalBlendStart = 7--m
M.decalBlendEnd = 120--m
--M.stepDistance = 5
local function increaseDecalPool(max)
  while M.decalPoolCount < max do
    M.decalPoolCount = M.decalPoolCount +1
    table.insert(M.decalPool, getNewData())
  end
end

local function inverseLerp(min, max, value)
 if abs(max - min) < 1e-30 then return min end
 return (value - min) / (max - min)
end

local function generateDecalsForSegment(from, to, idx, first)
  local last = M.startingStep - ceil(to.distToTarget/M.stepDistance)
  for i = first+1, last, 1 do

    local t = inverseLerp(M.startingStep-from.distToTarget/M.stepDistance, M.startingStep-to.distToTarget/M.stepDistance, i)
    local distFromVehicle = M.startingDist-lerp(from.distToTarget, to.distToTarget, t)
    if distFromVehicle > M.decalDrawingDistance then return idx, false, i end

    M.decalPool[idx].pos = lerp(from.pos, to.pos, t)
    M.decalPool[idx].position:set(M.decalPool[idx].pos.x, M.decalPool[idx].pos.y, M.decalPool[idx].pos.z)
    local normal = (to.pos - from.pos):normalized()
    M.decalPool[idx].forwardVec:set(normal.x, normal.y, normal.z)
    M.decalPool[idx].color.a = 0
    if distFromVehicle > M.decalBlendEnd then
      M.decalPool[idx].color.a = max(M.decalPool[idx].color.a, 1-(distFromVehicle - M.decalBlendEnd) / (M.decalDrawingDistance-M.decalBlendEnd))
    elseif distFromVehicle < M.decalBlendStart then
      M.decalPool[idx].color.a = max(M.decalPool[idx].color.a, ((distFromVehicle-M.decalBlendOffset) / (M.decalBlendStart-M.decalBlendOffset)))
    else
      M.decalPool[idx].color.a = 1
    end
    -- enable this line for "quicker" blending
    --M.decalPool[idx].color.a = 1-square(1-M.decalPool[idx].color.a)
    idx = idx + 1
  end
  return idx, (M.startingDist-to.distToTarget) < M.decalDrawingDistance, last
end

local function getUnusedArrow()
  local arrowPool = scenetree.findObjectById(arrowPoolId)
  if arrowPool then
    for i = 0, arrowPool:size() - 1 do
      local arrow = arrowPool:at(i)
      if arrow and arrow.hidden then return Sim.upcast(arrow) end
    end
  end
end

local arrowHeight = vec3(0,0,4)
local renderedWpArrows = {}
local arrowScaleVec = vec3()
local function generateRouteDecals(startPos)
  profilerPushEvent("Groundmarkers generateRouteDecals")

  if M.decalPoolCount == 0 then
    increaseDecalPool(M.decalDrawingDistance/M.stepDistance + 10)
  end

  local path = M.routePlanner.path
  local totalDist = (startPos - path[1].pos):length() + path[1].distToTarget
  M.startingDist = totalDist
  M.startingStep = ceil(totalDist/M.stepDistance)+1

  local nextIdx, cont, first = 1, true, 1
  local i = 1
  local dirPrevPoint
  local prevPointId
  table.clear(renderedWpArrows)

  while cont do
    -- Check if we need to draw floating arrows
    if i < #M.routePlanner.path then
      local vehicleDist = totalDist - path[i].distToTarget
      local dirNextPoint = (M.routePlanner.path[i+1].pos - path[i].pos)
      dirNextPoint:normalize()
      if dirPrevPoint and vehicleDist > M.decalBlendOffset and (path[i].linkCount and path[i].linkCount > 2) and path[i].wp then
        local nodeToNodeAngle = acos(dirPrevPoint:cosAngle(dirNextPoint)) * 180/pi

        -- Check if the route has the smallest angle of any possible path of the intersection
        local routeHasSmallestAngle = true
        if nodeToNodeAngle <= 25 then
          for wpId, edgeInfo in pairs(map.getGraphpath().graph[path[i].wp]) do
            if prevPointId ~= wpId then
              local connectedNodePos = map.getMap().nodes[wpId].pos
              local dirConnectedNode = (connectedNodePos - path[i].pos); dirConnectedNode:normalize()
              local connectedNodeAngle = acos(dirPrevPoint:cosAngle(dirConnectedNode)) * 180/pi
              if nodeToNodeAngle > connectedNodeAngle then
                routeHasSmallestAngle = false
                break
              end
            end
          end
        end
        if nodeToNodeAngle > 25 or not routeHasSmallestAngle then

          -- Show an arrow
          if not wpToArrowMap[path[i].wp] then
            local arrow = getUnusedArrow()
            if arrow then
              wpToArrowMap[path[i].wp] = arrow:getId()
              arrowToWpMap[arrow:getId()] = path[i].wp
              arrow.hidden = false

              local pos = path[i].pos + arrowHeight
              local rot = quatFromDir(dirNextPoint, upVec)
              arrow:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
              -- TODO Removed the exaggerate angle for now
              --[[ if nodeToNodeAngle <= 25 then
                -- Add rotation lerp info when the angle is too shallow
                local rightDir = dirPrevPoint:cross(upVec)
                local rightTurn = rightDir:dot(dirNextPoint) > 0
                local exaggeratedDir = vec3()
                exaggeratedDir:setLerp(rightTurn and rightDir or -rightDir, dirPrevPoint, 0.5)
                arrowLerpInfos[arrow:getId()] = {pos = pos, realRot = rot, exaggeratedRot = quatFromDir(exaggeratedDir, upVec)}
              end ]]
            end
          end

          -- Blend the arrow in or out
          if wpToArrowMap[path[i].wp] then
            local arrow = scenetree.findObjectById(wpToArrowMap[path[i].wp])
            if arrow then
              local lerpFactor
              if vehicleDist <= M.decalBlendStart then
                lerpFactor = (clamp(vehicleDist, M.decalBlendOffset, M.decalBlendStart)-M.decalBlendOffset) / (M.decalBlendStart-M.decalBlendOffset)
              else
                lerpFactor = 1 - (clamp(vehicleDist, M.decalBlendEnd, M.decalDrawingDistance)-M.decalBlendEnd) / (M.decalDrawingDistance-M.decalBlendEnd)
              end
              local arrowInfo = arrowLerpInfos[arrow:getId()]
              if arrowInfo then
                -- lerp the arrow rotation as you are coming closer
                local rot = arrowInfo.realRot:nlerp(arrowInfo.exaggeratedRot, (clamp(vehicleDist - 30, 0, 30)) / 30)
                arrow:setPosRot(arrowInfo.pos.x, arrowInfo.pos.y, arrowInfo.pos.z, rot.x, rot.y, rot.z, rot.w)
              end
              arrow:setField('instanceColor', 0, spaceSeparated4Values(M.floatingArrowColor[1], M.floatingArrowColor[2], M.floatingArrowColor[3], lerpFactor))
              arrow:setField('instanceColor1', 0, spaceSeparated4Values(0, 0, 0, lerpFactor))
              local exaggeratedScale = clamp(vehicleDist-60, arrowScale, 5)
              arrowScaleVec:set(exaggeratedScale, exaggeratedScale, exaggeratedScale)
              arrow:setScale(arrowScaleVec)
              arrow:updateInstanceRenderData()
              renderedWpArrows[path[i].wp] = true
            end
          end
        end
      end
      dirPrevPoint = dirNextPoint
      prevPointId = M.routePlanner.path[i+1].wp
    end

    if path[i+1] then
      nextIdx, cont, first = generateDecalsForSegment(path[i], path[i+1], nextIdx, first)
      i = i+1
      cont = cont and path[i+1]
    else
      cont = nil
    end
  end
  M.activeDecalCount = nextIdx+1
  for i = max(nextIdx-1,1), M.decalPoolCount do
    M.decalPool[i].color.a = 0
  end

  -- Hide unused arrows
  local arrowPool = scenetree.findObjectById(arrowPoolId)
  if arrowPool then
    for i = 0, arrowPool:size() - 1 do
      local arrow = arrowPool:at(i)
      local wp = arrowToWpMap[arrow:getId()]
      if wp and not renderedWpArrows[wp] then
        arrow.hidden = true
        arrowToWpMap[arrow:getId()] = nil
        wpToArrowMap[wp] = nil
        arrowLerpInfos[arrow:getId()] = nil
      end
    end
  end
  profilerPopEvent()
end

local appTimer = 0
local appInterval = 0.25
local lastGenerationPos
local function onPreRender(dt)
  if not M.endWP then return end

  profilerPushEvent("Groundmarkers onPreRender")

  local veh = getPlayerVehicle(0)
  if veh then
    M.routePlanner:trackVehicle(veh)
  end
  local vehiclePos = veh and veh:getPosition() or core_camera.getPosition()

  if freeroam_bigMapMode.bigMapActive() or not lastGenerationPos or lastGenerationPos:distance(vehiclePos) > 1 then
    generateRouteDecals(vehiclePos)
    lastGenerationPos = vehiclePos
  end

  if M.debugPath then
    for i, wp in ipairs(M.routePathTmp or {}) do
      debugDrawer:drawSphere(vec3(wp), 0.25, ColorF(1, 0.4, 1,0.2))
      debugDrawer:drawTextAdvanced(wp, String(i), ColorF(1,1,1,1), true, false, ColorI(0,0,0,192))
    end
    for i, e in ipairs(M.routePlanner.path) do
      debugDrawer:drawSphere(vec3(e.pos), 1, ColorF(0.23, 0.4, 0.1,0.6))
      if i > 1 then
        debugDrawer:drawSquarePrism(
          vec3(e.pos), vec3(M.routePlanner.path[i-1].pos),
          Point2F(2,0.5),
          Point2F(2,0.5),
          ColorF(0.23, 0.5,0.2, 0.6))
      end
    end
  end

  Engine.Render.DynamicDecalMgr.addDecals(M.decalPool, M.activeDecalCount)
  appTimer = appTimer + dt
  if appTimer > appInterval then
    appTimer = 0
    M.sendToApp()
  end
  profilerPopEvent()
end

local function sendToApp()
  local data = {
    markers = {},
    color = string.format("#%02X%02X%02XFF", M.color[1]*255, M.color[2]*255, M.color[3]*255)
  }
  local id = 1
  for i, e in ipairs(M.routePlanner.path) do
    data.markers[id] = e.pos.x
    data.markers[id+1] = e.pos.y
    id = id+2
  end

  guihooks.trigger("NavigationGroundMarkersUpdate", data)
end

local function setPath(wp, options)
  profilerPushEvent("Groundmarkers setFocus")
  options = options or {}
  M.endWP = nil
  -- clear pool
  M.decalPoolCount = 0
  M.decalPool = {}
  M.activeDecalCount = 0
  lastGenerationPos = nil

  M.stepDistance = options.step or 4
  M.color = options.color or {0, 0.4, 1}
  M.floatingArrowColor = M.color

  M.clearPathOnReachingTarget = options.clearPathOnReachingTarget ~= false

  M.cutOffDrivability = options.cutOffDrivability
  M.penaltyAboveCutoff = options.penaltyAboveCutoff
  M.penaltyBelowCutoff = options.penaltyBelowCutoff
  M.renderDecals = options.renderDecals ~= false
  M.endWP = (type(wp) == 'table' and wp) or {wp}
  if not wp or tableIsEmpty(M.endWP) then
    M.routePlanner:clear()
    M.endWP = nil
    local data = {
      markers = {}
    }
    guihooks.trigger("NavigationGroundMarkersUpdate", data)
  else
    local veh = getPlayerVehicle(0)
    local vehiclePos = vec3(veh and veh:getPosition() or core_camera.getPosition())
    local multiPath = {}
    table.insert(multiPath, vehiclePos)
    for _, w in ipairs(M.endWP) do
      if type(w) == 'string' then
        if not map.getMap().nodes[w] then
          log("W","","Could not find WP to build route! Ignoring WP: " .. dumps(w))
        else
          table.insert(multiPath, map.getMap().nodes[w].pos)
        end
      elseif type(w) == 'table' and #w == 3 then
        table.insert(multiPath, vec3(w))
      else
        table.insert(multiPath, w)
      end
    end

    profilerPushEvent("Groundmarkers route setupPath")
    M.routePathTmp = multiPath
    M.routePlanner:setRouteParams(M.cutOffDrivability, nil, M.penaltyAboveCutoff, M.penaltyBelowCutoff)
    M.routePlanner:setupPathMulti(multiPath)
    if veh then
      M.routePlanner:trackVehicle(veh)
    end
    --generateRouteDecals()
    profilerPopEvent()
    M.sendToApp()
  end

  wpToArrowMap = {}
  arrowToWpMap = {}
  arrowLerpInfos = {}

  local group = scenetree.findObject("arrowPool")
  if not group then
    if M.endWP then
      -- Create the group if there is none yet and we passed an end point
      group = createObject("SimGroup")
      group:registerObject("arrowPool")
      group.canSave = false
      for i = 0, 10 do
        local arrow = createObject('TSStatic')
        arrow:setField('shapeName', 0, "art/shapes/arrows/s_arrow_floating.dae")
        arrow.scale = vec3(arrowScale, arrowScale, arrowScale)
        arrow.useInstanceRenderData = true
        arrow:setField('instanceColor', 1, "1 1 1 1")
        arrow:setField('instanceColor1', 1, ""..M.floatingArrowColor[1].." "..M.floatingArrowColor[2].." "..M.floatingArrowColor[3].." 1")
        arrow.canSave = false
        arrow.hidden = true
        arrow:registerObject(Sim.getUniqueName("arrow"))
        group:addObject(arrow)
      end
      arrowPoolId = group:getId()
    end
  else
    for i = 0, group:size() - 1 do
      local arrow = group:at(i)
      arrow.hidden = true
    end
    arrowPoolId = group:getId()
  end

  profilerPopEvent()
end

local function setFocus(wp, step, _fadeStart, _fadeEnd, _endPos, _disableVeh, _color, _cutOffDrivability, _penaltyAboveCutoff, _penaltyBelowCutoff, _renderDecals)
  deprecationWarning("core_groundmarkers.setFocus", "core_groundmarkers.setPath")
  local options = {
    step = step,
    color = _color,
    cutOffDrivability = _cutOffDrivability,
    penaltyAboveCutoff = _penaltyAboveCutoff,
    penaltyBelowCutoff = _penaltyBelowCutoff,
    renderDecals = _renderDecals,
  }
  setPath(wp, options)
end

local function clearArrows()
  local arrowPool = scenetree.findObject("arrowPool")
  if arrowPool then
    for i = 0, arrowPool:size() - 1 do
      local arrow = arrowPool:at(i)
      if arrow then arrow:delete() end
    end
    arrowPool:delete()
  end
  wpToArrowMap = {}
  arrowToWpMap = {}
  arrowLerpInfos = {}
end

local function resetAll()
  --cleanup on level exit
  setPath(nil)

  decals = {}

  M.cutOffDrivability = nil
  M.penaltyAboveCutoff = nil
  M.penaltyBelowCutoff = nil
  M.renderDecals = nil

  clearArrows()
end

local function onClientEndMission()
  resetAll()
end

local function onExtensionUnloaded()
  resetAll()
end

local function onSerialize()
  clearArrows()
end

local function currentlyHasTarget()
  return M.endWP ~= nil
end
local function getTargetPos()
  return M.endWP and M.endWP[1]
end

M.onAnyMissionChanged = function(state) if state == "started" or state == "stopped" then M.resetAll() end end

-- public interface
M.onPreRender = onPreRender
M.setPath = setPath
M.getPathLength = getPathLength
M.onClientEndMission = onClientEndMission
M.onExtensionUnloaded = onExtensionUnloaded
M.onSerialize = onSerialize
M.resetAll = resetAll
M.generateRouteDecals = generateRouteDecals
M.sendToApp = sendToApp
M.currentlyHasTarget = currentlyHasTarget
M.getTargetPos = getTargetPos

-- deprecated
M.setFocus = setFocus

return M
