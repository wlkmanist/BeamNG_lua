-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local geometry = require("editor/ezObjectSelect/selectionGeometry")
local screenDebug = require("editor/ezObjectSelect/selectionScreenDebug")

local activeColor = ColorF(0.2, 1, 0.35, 0.8)
local stackColor = ColorF(1, 0.88, 0, 0.8)
local discoveryColor = ColorF(1, 1, 1, 0.7)
local selectedColor = ColorF(1, 0.45, 0.05, 0.75)
local draggingColor = ColorF(1, 0.2, 0.8, 0.65)
local filteredLargeColor = ColorF(1, 0.1, 0.1, 0.9)
local distanceColor = ColorF(0.1, 0.85, 1, 0.9)
local axisXColor = ColorF(1, 0.2, 0.2, 0.95)
local axisYColor = ColorF(0.2, 1, 0.3, 0.95)
local axisZColor = ColorF(0.25, 0.55, 1, 0.95)

local distanceBackground = ColorI(26, 217, 255, 230)

local boxEdges = {
  {1, 2}, {1, 3}, {1, 5},
  {2, 4}, {2, 6},
  {3, 4}, {3, 7},
  {4, 8},
  {5, 6}, {5, 7},
  {6, 8},
  {7, 8}
}
local boxFaces = {
  {1, 2, 4, 3},
  {5, 7, 8, 6},
  {1, 3, 7, 5},
  {2, 6, 8, 4},
  {1, 5, 6, 2},
  {3, 4, 8, 7}
}

local function textColorForBackground(red, green, blue)
  local luminance = 0.299 * red + 0.587 * green + 0.114 * blue
  return luminance > 0.5 and ColorF(0, 0, 0, 1) or ColorF(1, 1, 1, 1)
end

local distanceTextColor = textColorForBackground(0.1, 0.85, 1)

local function drawCorners(corners, color, thickness, depthTest)
  for _, edge in ipairs(boxEdges) do
    debugDrawer:drawLineInstance(
      corners[edge[1]],
      corners[edge[2]],
      thickness,
      color,
      depthTest == true)
  end
end

local function drawBoxFill(corners, lineColor, depthTest)
  local fillColor = color(
    lineColor.r * 255,
    lineColor.g * 255,
    lineColor.b * 255,
    0.06 * 255)
  for _, face in ipairs(boxFaces) do
    debugDrawer:drawTriSolid(
      corners[face[1]],
      corners[face[2]],
      corners[face[3]],
      fillColor,
      depthTest == true)
    debugDrawer:drawTriSolid(
      corners[face[1]],
      corners[face[3]],
      corners[face[4]],
      fillColor,
      depthTest == true)
  end
end

local function drawObjectBox(obj, color, depthTest, drawLines)
  if not obj or not obj.getWorldBox then return end
  local box = obj:getWorldBox()
  if not geometry.validBox(box) then return end
  if drawLines then
    local corners = geometry.getWorldCorners(obj)
    if corners then
      drawBoxFill(corners, color, depthTest)
      drawCorners(corners, color, 4, depthTest)
    end
  end
end

local function drawProxyBox(proxy, color, thickness, depthTest)
  if not proxy or not proxy.worldCorners then return end
  drawBoxFill(proxy.worldCorners, color, depthTest)
  drawCorners(proxy.worldCorners, color, thickness, depthTest)
end

local function drawSelectionAxes(selectedIds, options)
  if not selectedIds or #selectedIds == 0 then return end
  local obj = scenetree.findObjectById(selectedIds[#selectedIds])
  if not obj or not obj.getPosition then return end
  local pivot = vec3(obj:getPosition())
  local axes = {
    x = vec3(1, 0, 0),
    y = vec3(0, 1, 0),
    z = vec3(0, 0, 1)
  }
  if options.axisLocal and obj.getTransform then
    local transform = obj:getTransform()
    for index, name in ipairs({"x", "y", "z"}) do
      local axis = vec3(transform:getColumn(index - 1))
      local axisLength = axis:length()
      if axisLength > 0.0001 then axes[name] = axis / axisLength end
    end
  end
  local length = clamp((pivot - core_camera.getPosition()):length() * 0.025, 0.5, 4)
    * (options.axisLengthScale or 1)
  local width = options.axisLineWidth or 3
  debugDrawer:drawLineInstance(pivot, pivot + axes.x * length, width, axisXColor, false)
  debugDrawer:drawLineInstance(pivot, pivot + axes.y * length, width, axisYColor, false)
  debugDrawer:drawLineInstance(pivot, pivot + axes.z * length, width, axisZColor, false)
end

local function distanceBoundaryPoint(camera, radius, angle)
  local origin = camera.rangeOrigin or camera.pos
  local horizontalRadius = radius
  local point
  for _ = 1, 3 do
    point = vec3(
      origin.x + math.cos(angle) * horizontalRadius,
      origin.y + math.sin(angle) * horizontalRadius,
      origin.z)
    local height = core_terrain.getTerrainHeight(point)
    if not height then return nil end
    local verticalDistance = height - origin.z
    if math.abs(verticalDistance) > radius then return nil end
    horizontalRadius = math.sqrt(radius * radius - verticalDistance * verticalDistance)
    point.z = height + 0.5
  end
  return point
end

local function drawDistanceBoundary(camera, radius, showLabel)
  if not radius or radius <= 0 or not core_terrain.getTerrain() then return end
  local previous
  for index = 0, 64 do
    local angle = index / 64 * math.pi * 2
    local point = distanceBoundaryPoint(camera, radius, angle)
    if point and previous then debugDrawer:drawLineInstance(previous, point, 3, distanceColor) end
    previous = point
  end
  if not showLabel then return end

  local horizontalForward = vec3(camera.forward.x, camera.forward.y, 0)
  local horizontalLength = horizontalForward:length()
  if horizontalLength <= 0.0001 then return end
  horizontalForward = horizontalForward / horizontalLength
  local labelPosition = distanceBoundaryPoint(
    camera,
    radius,
    math.atan2(horizontalForward.y, horizontalForward.x))
  if not labelPosition then return end
  labelPosition.z = labelPosition.z + 0.3
  debugDrawer:drawTextAdvanced(
    labelPosition,
    String("MAX PICK DISTANCE"),
    distanceTextColor,
    true,
    false,
    distanceBackground,
    false,
    false)
end

function M.drawWorld(snapshot, options)
  options = options or {}
  local drawBoundingBoxes = options.outlineMode == 1
  local draggingIds = options.draggingIds or {}
  local draggingById = {}
  for _, id in ipairs(draggingIds) do draggingById[id] = true end
  local selectedById = {}
  for _, id in ipairs(options.selectedIds or {}) do selectedById[id] = true end
  local drawnIds = {}

  if options.showFilteredLarge and snapshot then
    for _, proxy in ipairs(snapshot.filteredLarge or {}) do
      drawProxyBox(proxy, filteredLargeColor, 4, options.depthTest)
    end
  end

  if snapshot then
    local discovery = snapshot.discovery or {}
    local discoveryLimit = options.debugEnabled
      and #discovery
      or math.min(#discovery, math.max(options.maxDiscoveryOutlines or 5, 0))
    for index = 1, discoveryLimit do
      local proxy = discovery[index]
      local dragging = draggingById[proxy.targetId]
      local selected = selectedById[proxy.targetId]
      local color = dragging and draggingColor or (selected and selectedColor or discoveryColor)
      local depthTest = options.depthTest
      if dragging then
        depthTest = options.dragDepthTest
      elseif selected then
        depthTest = options.selectedDepthTest
      end
      if drawBoundingBoxes then
        drawProxyBox(proxy, color, 2, depthTest)
      end
      drawnIds[proxy.targetId] = true
    end
  end

  if snapshot and snapshot.pick then
    local candidates = snapshot.candidates or {}
    local stackLimit = options.debugEnabled
      and #candidates
      or math.min(#candidates, math.max(options.maxStackOutlines or 5, 0))
    for index, candidate in ipairs(candidates) do
      if index <= stackLimit or candidate == snapshot.pick then
        local color
        if draggingById[candidate.targetId] then
          color = draggingColor
        elseif selectedById[candidate.targetId] then
          color = selectedColor
        elseif candidate == snapshot.pick then
          color = activeColor
        else
          color = stackColor
        end
        local dragging = draggingById[candidate.targetId]
        local depthTest = dragging and options.dragDepthTest
          or selectedById[candidate.targetId] and options.selectedDepthTest
          or options.depthTest
        if drawBoundingBoxes then
          drawProxyBox(
            candidate.proxy,
            color,
            candidate == snapshot.pick and 5 or 2,
            depthTest)
        end
        drawnIds[candidate.targetId] = true
      end
    end
  end

  for _, id in ipairs(options.selectedIds or {}) do
    if not draggingById[id] and not drawnIds[id] then
      drawObjectBox(
        scenetree.findObjectById(id),
        selectedColor,
        options.selectedDepthTest,
        drawBoundingBoxes)
    end
  end
  for _, id in ipairs(draggingIds) do
    drawObjectBox(
      scenetree.findObjectById(id),
      draggingColor,
      options.dragDepthTest,
      drawBoundingBoxes)
  end
  if options.showSelectionAxes ~= false then drawSelectionAxes(options.selectedIds, options) end

  if (options.debugEnabled or options.showDistanceRing) and snapshot and snapshot.camera then
    drawDistanceBoundary(
      snapshot.camera,
      options.maxDistance,
      options.debugEnabled)
  end
end

function M.drawScreen(snapshot, options)
  screenDebug.draw(snapshot, options)
end

function M.reset()
  screenDebug.reset()
end

return M
