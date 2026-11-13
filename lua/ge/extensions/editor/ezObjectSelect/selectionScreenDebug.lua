-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local geometry = require("editor/ezObjectSelect/selectionGeometry")
local labelOverlay = require("editor/ezObjectSelect/selectionLabelOverlay")
local labels = require("editor/ezObjectSelect/selectionLabels")

local activeColor = im.GetColorU322(im.ImVec4(0.2, 1, 0.35, 0.95))
local activeFill = im.GetColorU322(im.ImVec4(0.2, 1, 0.35, 0.09))
local stackColor = im.GetColorU322(im.ImVec4(1, 0.88, 0, 0.95))
local stackFill = im.GetColorU322(im.ImVec4(1, 0.88, 0, 0.07))
local discoveryColor = im.GetColorU322(im.ImVec4(1, 1, 1, 0.95))
local discoveryFill = im.GetColorU322(im.ImVec4(1, 1, 1, 0.08))
local discoveryCircleFill = im.GetColorU322(im.ImVec4(1, 1, 1, 0.1))
local selectedColor = im.GetColorU322(im.ImVec4(1, 0.45, 0.05, 0.95))
local selectedFill = im.GetColorU322(im.ImVec4(1, 0.45, 0.05, 0.09))
local draggingColor = im.GetColorU322(im.ImVec4(1, 0.2, 0.8, 0.95))
local draggingFill = im.GetColorU322(im.ImVec4(1, 0.2, 0.8, 0.09))
local queryColor = im.GetColorU322(im.ImVec4(0.35, 0.78, 0.95, 0.95))
local distanceColor = im.GetColorU322(im.ImVec4(1, 1, 1, 0.7))
local cycleColor = im.GetColorU322(im.ImVec4(1, 0.25, 0.85, 0.95))
local debugWindowBg = im.ImVec4(0.16, 0.34, 0.46, 0.98)
local debugTitleBg = im.ImVec4(0.14, 0.45, 0.65, 1)
local debugTitleActiveBg = im.ImVec4(0.18, 0.58, 0.78, 1)
local debugTitleCollapsedBg = im.ImVec4(0.12, 0.38, 0.56, 1)
local debugBorder = im.ImVec4(0.35, 0.78, 0.95, 1)
local performanceLineColor = im.ImVec4(1, 0.55, 0.05, 1)
local performanceLineHoveredColor = im.ImVec4(1, 0.85, 0.1, 1)
local performanceSampleCount = 180
local performanceSamples = im.ArrayFloat(performanceSampleCount)
local performanceWriteIndex = 0
local performanceStoredCount = 0
local lastPerformanceFrameId = nil

local function recordPerformance(snapshot)
  if not snapshot.performanceFrameId
    or snapshot.performanceFrameId == lastPerformanceFrameId
    or not snapshot.performanceTime then
    return
  end
  lastPerformanceFrameId = snapshot.performanceFrameId
  performanceSamples[performanceWriteIndex] = snapshot.performanceTime
  performanceWriteIndex = (performanceWriteIndex + 1) % performanceSampleCount
  performanceStoredCount = math.min(performanceStoredCount + 1, performanceSampleCount)
end

function M.reset()
  performanceWriteIndex = 0
  performanceStoredCount = 0
  lastPerformanceFrameId = nil
  for index = 0, performanceSampleCount - 1 do performanceSamples[index] = 0 end
end

local function performanceStats()
  local total, maximum = 0, 0
  for index = 0, performanceStoredCount - 1 do
    local value = performanceSamples[index]
    total = total + value
    maximum = math.max(maximum, value)
  end
  local average = performanceStoredCount > 0 and total / performanceStoredCount or 0
  return average, maximum
end

local function shortObjectName(obj, objectId)
  local name = labels.objectName(obj, objectId)
  return #name > 34 and (name:sub(1, 31) .. "...") or name
end

local function screenPoint(point, camera)
  return im.ImVec2(point.x + camera.viewportX, point.y + camera.viewportY)
end

local function drawPolygon(drawList, polygon, camera, color, thickness)
  for index, first in ipairs(polygon) do
    local second = polygon[index % #polygon + 1]
    im.ImDrawList_AddLine(
      drawList,
      screenPoint(first, camera),
      screenPoint(second, camera),
      color,
      thickness)
  end
end

local function fillPolygon(drawList, polygon, camera, color)
  if #polygon < 3 then return end
  local first = screenPoint(polygon[1], camera)
  for index = 2, #polygon - 1 do
    im.ImDrawList_AddTriangleFilled(
      drawList,
      first,
      screenPoint(polygon[index], camera),
      screenPoint(polygon[index + 1], camera),
      color)
  end
end

local function closestPointOnSegment(point, first, second)
  local dx, dy = second.x - first.x, second.y - first.y
  local lengthSquared = dx * dx + dy * dy
  if lengthSquared <= 0.000001 then return {x = first.x, y = first.y} end
  local amount = clamp(
    ((point.x - first.x) * dx + (point.y - first.y) * dy) / lengthSquared,
    0,
    1)
  return {x = first.x + dx * amount, y = first.y + dy * amount}
end

local function closestPointOnPolygon(point, polygon)
  if not polygon or #polygon == 0 then return nil end
  local closest, bestDistanceSquared
  for index, first in ipairs(polygon) do
    local candidate = closestPointOnSegment(point, first, polygon[index % #polygon + 1])
    local dx, dy = candidate.x - point.x, candidate.y - point.y
    local distanceSquared = dx * dx + dy * dy
    if not bestDistanceSquared or distanceSquared < bestDistanceSquared then
      closest = candidate
      bestDistanceSquared = distanceSquared
    end
  end
  return closest
end

local function polygonTopCenter(proxy, camera)
  local minimumX, maximumX, minimumY = math.huge, -math.huge, math.huge
  for _, point in ipairs(proxy.polygon) do
    minimumX = math.min(minimumX, point.x)
    maximumX = math.max(maximumX, point.x)
    minimumY = math.min(minimumY, point.y)
  end
  return screenPoint({x = (minimumX + maximumX) * 0.5, y = minimumY}, camera)
end

local function metric(value)
  return value == math.huge and "--" or string.format("%.2f", value)
end

local function rejectionText(rejected)
  local keys = {}
  for key in pairs(rejected or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  local values = {}
  for _, key in ipairs(keys) do values[#values + 1] = key .. "=" .. rejected[key] end
  return #values > 0 and table.concat(values, "  ") or "none"
end

local function stackLines(snapshot, discoveryPixels)
  local stats = snapshot.queryStats or {}
  local cache = stats.cache or {}
  local lines = {
    "PICKING ENGINE",
    string.format(
      "white circle: DISCOVERY %.0f px    stack: strict cursor-inside-hull",
      discoveryPixels),
    "orange: SELECTED    green: CLICK TARGET    yellow: STACK    white: DISCOVERY",
    string.format(
      "stack=%d    discovery=%d    cycle=%s    frozen=%s",
      snapshot.stackCount,
      #(snapshot.discovery or {}),
      snapshot.cycleActive and "ON" or "off",
      snapshot.frozenTargetId and tostring(snapshot.frozenTargetId) or "no"),
    string.format(
      "source=%s  broad=%.0fpx  cache=%s  targets=%d  build=%.3fms  classify=%.3fms",
      stats.mode or "unknown",
      stats.broadRadius or 0,
      cache.status or "unknown",
      cache.targetCount or 0,
      cache.buildTime or 0,
      cache.classificationTime or 0)
  }
  if stats.pattern and stats.pattern ~= "" then
    lines[#lines + 1] = stats.patternError
      and ("pattern invalid: " .. tostring(stats.patternError))
      or ("pattern: " .. stats.pattern)
  end
  if stats.ignorePattern and stats.ignorePattern ~= "" then
    lines[#lines + 1] = stats.ignorePatternError
      and ("ignore pattern invalid: " .. tostring(stats.ignorePatternError))
      or ("ignore pattern: " .. stats.ignorePattern)
  end

  for index, candidate in ipairs(snapshot.candidates) do
    local marker = index == snapshot.activeIndex and ">" or " "
    local proxy = candidate.proxy
    lines[#lines + 1] = string.format(
      "%s %d  %-4s  %-34s  area=%7.0fpx2  depth=%s  range=%.2fm  bias=%.3f%s",
      marker,
      index,
      candidate.relation:upper(),
      shortObjectName(candidate.target, candidate.targetId),
      proxy.area,
      metric(proxy.rayEntry),
      proxy.cameraDistance,
      proxy.centerBias,
      proxy.cameraInside and "  CAMERA INSIDE" or "")
  end
  for _, proxy in ipairs(snapshot.discovery or {}) do
    lines[#lines + 1] = string.format(
      "  B  DISC  %-34s  edge=%5.1fpx  range=%.2fm",
      shortObjectName(proxy.target, proxy.targetId),
      proxy.cursorDistance,
      proxy.cameraDistance)
  end
  lines[#lines + 1] = string.format(
    "query screen=%d  close=%d  closeOnly=%d  acceptedCloseOnly=%d  total=%d    rejected: %s",
    stats.screen or 0,
    stats.nearCamera or 0,
    stats.nearOnly or 0,
    stats.qualifyingNearOnly or 0,
    stats.total or snapshot.sourceCount,
    rejectionText(snapshot.rejected))
  return lines
end

local function drawDetailsWindow(snapshot, discoveryPixels, viewport)
  local lineCount = math.min(#snapshot.candidates + #(snapshot.discovery or {}), 12) + 7
  local width = math.min(1000 * im.uiscale[0], viewport.Size.x - 24)
  local height = math.min(
    lineCount * (im.GetFontSize() + 4) + 20,
    viewport.Size.y * 0.45)
  im.SetNextWindowPos(
    im.ImVec2(
      viewport.Pos.x + (viewport.Size.x - width) * 0.5,
      viewport.Pos.y + viewport.Size.y - height - 16),
    im.Cond_FirstUseEver)
  im.SetNextWindowSize(im.ImVec2(width, height), im.Cond_FirstUseEver)
  im.PushStyleColor2(im.Col_WindowBg, debugWindowBg)
  im.PushStyleColor2(im.Col_TitleBg, debugTitleBg)
  im.PushStyleColor2(im.Col_TitleBgActive, debugTitleActiveBg)
  im.PushStyleColor2(im.Col_TitleBgCollapsed, debugTitleCollapsedBg)
  im.PushStyleColor2(im.Col_Border, debugBorder)
  if im.Begin("Easy Select Debug") then
    local average, maximum = performanceStats()
    im.TextUnformatted("Selection frame slice")
    if performanceStoredCount > 0 then
      im.PushStyleColor2(im.Col_PlotLines, performanceLineColor)
      im.PushStyleColor2(im.Col_PlotLinesHovered, performanceLineHoveredColor)
      im.PlotLines1(
        "##easySelectPerformance",
        performanceSamples,
        performanceStoredCount,
        performanceStoredCount == performanceSampleCount and performanceWriteIndex or 0,
        string.format(
          "current %.3f ms   avg %.3f ms   max %.3f ms",
          snapshot.performanceTime or 0,
          average,
          maximum),
        0,
        math.max(maximum * 1.1, 1),
        im.ImVec2(-1, 90 * im.uiscale[0]))
      im.PopStyleColor(2)
    else
      im.TextDisabled("Waiting for viewport samples")
    end
    im.Separator()
    for _, line in ipairs(stackLines(snapshot, discoveryPixels)) do
      im.TextUnformatted(line)
    end
  end
  im.End()
  im.PopStyleColor(5)
end

local function drawHoverRing(drawList, snapshot, discoveryPixels)
  local mouse = screenPoint(snapshot.mouse, snapshot.camera)
  im.ImDrawList_AddCircleFilled(drawList, mouse, discoveryPixels, discoveryCircleFill, 64)
  im.ImDrawList_AddCircle(drawList, mouse, discoveryPixels, discoveryColor, 64, 2)
  return mouse
end

local function drawCursorDebugGuide(drawList, snapshot, mouse)
  if snapshot.cycleActive and snapshot.cycleAnchor then
    local anchor = screenPoint(snapshot.cycleAnchor, snapshot.camera)
    im.ImDrawList_AddCircle(
      drawList,
      anchor,
      snapshot.cycleDeadZone or 6,
      cycleColor,
      32,
      3)
    im.ImDrawList_AddLine(drawList, anchor, mouse, cycleColor, 2)
  end
end

local function candidateColors(candidate, pick, selected, dragging, showSelectedTint)
  if dragging then return draggingColor, draggingFill end
  if selected then
    return selectedColor, showSelectedTint and selectedFill or nil
  end
  if candidate == pick then return activeColor, activeFill end
  return stackColor, stackFill
end

function M.draw(snapshot, options)
  options = options or {}
  if not snapshot or not snapshot.camera then return end
  recordPerformance(snapshot)
  if not snapshot.pick
    and #(snapshot.discovery or {}) == 0
    and not options.debugEnabled
    and not options.showHoverRing then
    return
  end

  local viewport = im.GetMainViewport()
  im.SetNextWindowPos(viewport.Pos)
  im.SetNextWindowSize(viewport.Size)
  local flags = bit.bor(
    im.WindowFlags_NoDecoration,
    im.WindowFlags_NoMove,
    im.WindowFlags_NoSavedSettings,
    im.WindowFlags_NoBringToFrontOnFocus,
    im.WindowFlags_NoNavFocus,
    im.WindowFlags_NoBackground,
    im.WindowFlags_NoInputs)
  im.Begin("##easySelectProxyOverlay", nil, flags)
  local drawList = im.GetWindowDrawList()
  local discoveryPixels = options.discoveryPixels or snapshot.discoveryRadius or 0
  local drawConvexHulls = options.outlineMode ~= 1
  local discovery = snapshot.discovery or {}
  local discoveryLimit = options.debugEnabled
    and #discovery
    or math.min(#discovery, math.max(options.maxDiscoveryOutlines or 5, 0))
  local discoveryOverflow = #discovery - discoveryLimit
  local outlinedTargetIds = {}
  local selectedById, draggingById = {}, {}
  for _, objectId in ipairs(options.selectedIds or {}) do selectedById[objectId] = true end
  for _, objectId in ipairs(options.draggingIds or {}) do draggingById[objectId] = true end
  local stateLabels = {}

  local mouse = screenPoint(snapshot.mouse, snapshot.camera)
  if (options.debugEnabled or options.showHoverRing) and not options.hideHoverRing then
    mouse = drawHoverRing(drawList, snapshot, discoveryPixels)
  end
  if options.debugEnabled then drawCursorDebugGuide(drawList, snapshot, mouse) end

  for index = 1, discoveryLimit do
    local proxy = discovery[index]
    outlinedTargetIds[proxy.targetId] = true
    local dragging = draggingById[proxy.targetId]
    local selected = selectedById[proxy.targetId]
    local stateColor = dragging and draggingColor
      or (selected and selectedColor or discoveryColor)
    local stateFill = dragging and draggingFill or nil
    if not dragging then
      if selected then
        stateFill = options.showSelectedTint and selectedFill or nil
      else
        stateFill = discoveryFill
      end
    end
    if drawConvexHulls then
      if stateFill then fillPolygon(drawList, proxy.polygon, snapshot.camera, stateFill) end
      drawPolygon(drawList, proxy.polygon, snapshot.camera, stateColor, 2)
    end
    if options.debugEnabled or options.showHoverRing then
      local closest = closestPointOnPolygon(snapshot.mouse, proxy.polygon)
      if closest then
        local closestScreen = screenPoint(closest, snapshot.camera)
        im.ImDrawList_AddLine(drawList, mouse, closestScreen, distanceColor, 1)
        im.ImDrawList_AddCircleFilled(drawList, closestScreen, 3, stateColor, 16)
      end
    end
    if dragging or selected then
      local state = options.debugSelectionText
        and (dragging and (options.draggingLabel or "DRAGGING") or "SELECTED")
        or nil
      stateLabels[#stateLabels + 1] = {
        position = polygonTopCenter(proxy, snapshot.camera),
        text = state
          and string.format("%s  %s", state, labels.objectName(proxy.target, proxy.targetId))
          or labels.objectName(proxy.target, proxy.targetId),
        color = stateColor
      }
    end
  end

  if discoveryOverflow > 0 and not options.debugEnabled then
    table.insert(stateLabels, 1, {
      text = string.format("+%d nearby", discoveryOverflow),
      color = discoveryColor,
      followMouse = true,
      priority = true
    })
  end

  local candidates = snapshot.candidates or {}
  local stackLimit = options.debugEnabled
    and #candidates
    or math.min(#candidates, math.max(options.maxStackOutlines or 5, 0))

  for index, candidate in ipairs(candidates) do
    if index <= stackLimit or candidate == snapshot.pick then
      local proxy = candidate.proxy
      outlinedTargetIds[candidate.targetId] = true
      local dragging = draggingById[candidate.targetId]
      local selected = selectedById[candidate.targetId]
      local stateColor, stateFill = candidateColors(
        candidate,
        snapshot.pick,
        selected,
        dragging,
        options.showSelectedTint)
      if drawConvexHulls then
        if stateFill then fillPolygon(drawList, proxy.polygon, snapshot.camera, stateFill) end
        drawPolygon(
          drawList,
          proxy.polygon,
          snapshot.camera,
          stateColor,
          candidate == snapshot.pick and 6 or 2)
      end

      if options.debugEnabled or options.showHoverRing then
        local closest = closestPointOnPolygon(snapshot.mouse, proxy.polygon)
        if closest then
          local closestScreen = screenPoint(closest, snapshot.camera)
          im.ImDrawList_AddLine(drawList, mouse, closestScreen, distanceColor, 1)
          im.ImDrawList_AddCircleFilled(drawList, closestScreen, 3, stateColor, 16)
        end
      end
      local state = nil
      if options.debugSelectionText then
        state = dragging and (options.draggingLabel or "DRAGGING")
          or (selected and "SELECTED"
            or (candidate == snapshot.pick and "PICK" or "STACK"))
      end
      if not state and candidate == snapshot.pick and snapshot.stackCount > 1 then
        state = "->"
      end
      local text = state
        and string.format(
          "%s %d/%d  %s",
          state,
          index,
          snapshot.stackCount,
          labels.objectName(candidate.target, candidate.targetId))
        or string.format(
          "%d/%d  %s",
          index,
          snapshot.stackCount,
          labels.objectName(candidate.target, candidate.targetId))
      if options.debugSelectionText and candidate == snapshot.pick and proxy.cameraInside then
        text = text .. "  [CAMERA INSIDE]"
      end
      stateLabels[#stateLabels + 1] = {
        position = polygonTopCenter(proxy, snapshot.camera),
        text = text,
        color = stateColor,
        followMouse = options.labelPlacementMode == 1
      }
    end
  end

  for _, objectId in ipairs(options.selectedIds or {}) do
    if not outlinedTargetIds[objectId] then
      local obj = scenetree.findObjectById(objectId)
      local proxy = obj and geometry.createProjectedProxy(obj, snapshot.camera) or nil
      if proxy then
        local dragging = draggingById[objectId]
        local stateColor = dragging and draggingColor or selectedColor
        if drawConvexHulls then
          local stateFill = dragging and draggingFill
            or (options.showSelectedTint and selectedFill or nil)
          if stateFill then fillPolygon(drawList, proxy.polygon, snapshot.camera, stateFill) end
          drawPolygon(drawList, proxy.polygon, snapshot.camera, stateColor, 4)
        end
        local state = options.debugSelectionText
          and (dragging and (options.draggingLabel or "DRAGGING") or "SELECTED")
          or nil
        stateLabels[#stateLabels + 1] = {
          position = polygonTopCenter(proxy, snapshot.camera),
          text = state
            and string.format("%s  %s", state, labels.objectName(obj, objectId))
            or labels.objectName(obj, objectId),
          color = stateColor
        }
      end
    end
  end
  labelOverlay.draw(drawList, stateLabels, mouse, viewport)
  im.End()
  if options.debugEnabled then drawDetailsWindow(snapshot, discoveryPixels, viewport) end
end

return M
