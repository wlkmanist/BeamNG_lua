-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

local standardLineHeight = 0.5
local ghostLineHeight = standardLineHeight + 0.10
local ghostLineWidthScale = 0.75
local defaultDrivelineWidth = 1.945
local defaultDrawDistance = 100

function C:init(rallyEditor)
  self.rallyEditor = rallyEditor
  self.cache = nil
end

local function allSnaproadPoints(snaproad)
  if not (snaproad and snaproad.driveline and snaproad:driveline()) then return {} end
  return snaproad:driveline().points or {}
end

local function orderedSnapLocations(snaproad, fromPos, toPos)
  if not (snaproad and snaproad.closestSnapResult and snaproad.compareRouteLocations) then return nil, nil end

  local fromLoc = snaproad:closestSnapResult(fromPos, true)
  local toLoc = snaproad:closestSnapResult(toPos, true)
  if not (fromLoc and toLoc) then return nil, nil end

  if snaproad:compareRouteLocations(toLoc, fromLoc) == -1 then
    fromLoc, toLoc = toLoc, fromLoc
  end

  return fromLoc, toLoc
end

local function routePositionsBetween(snaproad, fromPos, toPos)
  local fromLoc, toLoc = orderedSnapLocations(snaproad, fromPos, toPos)
  if not (fromLoc and toLoc) then return nil, nil, nil end

  local positions = { vec3(fromLoc.pos) }
  local points = allSnaproadPoints(snaproad)
  local fromIndex = fromLoc.segmentIndex or 1
  local toIndex = toLoc.segmentIndex or fromIndex

  for i = fromIndex + 1, toIndex do
    if points[i] and points[i].pos then
      table.insert(positions, vec3(points[i].pos))
    end
  end

  table.insert(positions, vec3(toLoc.pos))
  return positions, fromLoc, toLoc
end

local function drivelineWidth(rallyEditor)
  if rallyEditor and rallyEditor.getPrefDrivelineSplinePrismWidth then
    return rallyEditor.getPrefDrivelineSplinePrismWidth()
  end
  return defaultDrivelineWidth
end

local function drawRoutePrisms(positions, color, prismWidth)
  if not positions or #positions < 2 then return end

  for i = 2, #positions do
    local prev = positions[i - 1]
    local curr = positions[i]
    if prev and curr and prev:distance(curr) > 0.01 then
      debugDrawer:drawSquarePrism(
        prev,
        curr,
        Point2F(ghostLineHeight, prismWidth),
        Point2F(ghostLineHeight, prismWidth),
        color
      )
    end
  end
end

local function lowerBound(entries, distance)
  local lo = 1
  local hi = #entries + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if entries[mid].distanceAlongRoute < distance then
      lo = mid + 1
    else
      hi = mid
    end
  end
  return lo
end

local function drawDistance(rallyEditor)
  if rallyEditor and rallyEditor.getPrefPacenoteLabelDistance then
    return rallyEditor.getPrefPacenoteLabelDistance()
  end
  return defaultDrawDistance
end

local function selectedRouteDistance(activePath, pacenoteToolsState, snaproad)
  if not (activePath and activePath.pacenotes and pacenoteToolsState and pacenoteToolsState.selected_pn_id) then return nil end
  if not (snaproad and snaproad.closestSnapResult) then return nil end

  for _, pacenote in ipairs(activePath.pacenotes.sorted) do
    if pacenote and pacenote.id == pacenoteToolsState.selected_pn_id then
      local cs = pacenote:getCornerStartWaypoint()
      if not (cs and cs.pos) then return nil end

      local loc = snaproad:closestSnapResult(cs.pos, true)
      return loc and loc.distanceAlongRoute or nil
    end
  end
  return nil
end

local function closestEntryIndex(entries, distance)
  if not (entries and distance) then return nil end

  local afterIndex = lowerBound(entries, distance)
  local beforeIndex = afterIndex - 1
  local after = entries[afterIndex]
  local before = entries[beforeIndex]

  if before and after then
    if math.abs(before.distanceAlongRoute - distance) <= math.abs(after.distanceAlongRoute - distance) then
      return beforeIndex
    end
    return afterIndex
  end
  if after then return afterIndex end
  if before then return beforeIndex end
  return nil
end

function C:buildCache(path, snaproad)
  local entries = {}

  for _, pacenote in ipairs(path.pacenotes.sorted) do
    if pacenote and not pacenote.missing then
      local cs = pacenote:getCornerStartWaypoint()
      local ce = pacenote:getCornerEndWaypoint()

      if cs and ce then
        local positions, csLoc = routePositionsBetween(snaproad, cs.pos, ce.pos)
        if positions and csLoc and csLoc.distanceAlongRoute then
          table.insert(entries, {
            pacenote = pacenote,
            positions = positions,
            labelPos = vec3(csLoc.pos),
            distanceAlongRoute = csLoc.distanceAlongRoute,
          })
        end
      end
    end
  end

  table.sort(entries, function(a, b)
    return a.distanceAlongRoute < b.distanceAlongRoute
  end)

  self.cache = {
    path = path,
    snaproad = snaproad,
    entries = entries,
  }

  return self.cache
end

function C:getCache(path, snaproad)
  if self.cache and self.cache.path == path and self.cache.snaproad == snaproad then
    return self.cache
  end
  return self:buildCache(path, snaproad)
end

function C:drawEntry(entry, lineColor, textAlpha, textBgAlpha, drawLabel, prismWidth)
  -- Ghost driveline rendering is disabled for now; keep labels visible without the route prism overlay.
  -- drawRoutePrisms(entry.positions, lineColor, prismWidth)
  if not drawLabel then return end

  local pacenote = entry.pacenote
  local label = nil
  if self.rallyEditor.getGhostNotebookLabelForPacenote then
    label = self.rallyEditor.getGhostNotebookLabelForPacenote(pacenote)
  end
  label = label or pacenote.name

  if label and label ~= '' then
    debugDrawer:drawTextAdvanced(
      entry.labelPos,
      String(label),
      ColorF(1, 1, 1, textAlpha),
      true,
      false,
      ColorI(0, 31, 115, textBgAlpha),
      false,
      false
    )
  end
end

function C:draw(path, snaproad, globalOpacity, pacenoteToolsState, activePath)
  if not path or not path.pacenotes or not snaproad then return end
  if not (core_camera and core_camera.getPosition and snaproad.closestSnapResult) then return end

  local cache = self:getCache(path, snaproad)
  local entries = cache and cache.entries or {}
  if #entries == 0 then return end

  local camLoc = snaproad:closestSnapResult(core_camera.getPosition(), true)
  if not (camLoc and camLoc.distanceAlongRoute) then return end

  globalOpacity = globalOpacity or 1.0
  local lineColor = ColorF(0.0, 0.12, 0.45, 0.85 * globalOpacity)
  local selectedTextAlpha = 1.0 * globalOpacity
  local adjacentTextAlpha = 0.5 * globalOpacity
  local prismWidth = drivelineWidth(self.rallyEditor) * ghostLineWidthScale

  local distance = drawDistance(self.rallyEditor)
  local minDistance = camLoc.distanceAlongRoute - distance
  local maxDistance = camLoc.distanceAlongRoute + distance
  local startIndex = lowerBound(entries, minDistance)
  local selectedDistance = selectedRouteDistance(activePath, pacenoteToolsState, snaproad)
  local selectedIndex = closestEntryIndex(entries, selectedDistance)
  local selectedWaypointActive = pacenoteToolsState and pacenoteToolsState.selected_wp_id ~= nil
  local showAdjacentText = not self.rallyEditor.getPrefShowAdjacentPacenoteText or self.rallyEditor.getPrefShowAdjacentPacenoteText()

  for i = startIndex, #entries do
    local entry = entries[i]
    if entry then
      if entry.distanceAlongRoute > maxDistance then
        break
      end
      local drawLabel = false
      local textAlpha = selectedTextAlpha
      if selectedIndex then
        drawLabel = i == selectedIndex
        if showAdjacentText and selectedWaypointActive then
          if self.rallyEditor.getPrefShowPreviousPacenote and self.rallyEditor.getPrefShowPreviousPacenote() then
            drawLabel = drawLabel or i == selectedIndex - 1
          end
          if self.rallyEditor.getPrefShowNextPacenote and self.rallyEditor.getPrefShowNextPacenote() then
            drawLabel = drawLabel or i == selectedIndex + 1
          end
        elseif showAdjacentText then
          drawLabel = drawLabel or i == selectedIndex - 1 or i == selectedIndex + 1
        end
        if i ~= selectedIndex then
          textAlpha = adjacentTextAlpha
        end
      else
        drawLabel = true
      end
      self:drawEntry(entry, lineColor, textAlpha, math.floor(220 * textAlpha), drawLabel, prismWidth)
    end
  end
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
