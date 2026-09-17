-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local logTag = 'rallyEditor'
local cc = require('/lua/ge/extensions/gameplay/rally/util/colors')
local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

-- Visual size constants
local POINT_SPHERE_RADIUS = 2.0
local HOVER_SPHERE_RADIUS = 3.0
local INDICATOR_SPHERE_RADIUS = 2.5
local LINE_PRISM_SIZE = 0.5
local ROUTE_PRISM_SIZE = 0.5  -- larger for better visibility of route measurement
local INTERSECTION_PLANE_HEIGHT = 2.0
local ALPHA = 0.5
local TEXT_ALPHA = 1.0

-- Interaction thresholds
local SNAP_THRESHOLD = 5.0  -- maximum distance from snaproad to add a point

local C = {}
C.windowDescription = 'Measurements'

function C:init(rallyEditor)
  self.rallyEditor = rallyEditor
  self.measurements = {}
  self.selectedMeasurementId = nil
  self.selectedPointIndex = nil
  self.nextMeasurementId = 1
  self.snaproad = nil
  self.mouseInfo = {}
  self.isDragging = false
  self.draggedPointIndex = nil
  self.hoverPointIndex = nil
  self.hoverMeasurementId = nil
  self.dragStarted = false  -- track if we've actually started moving
  self.lastMousePos = nil  -- mouse position when drag started
  self.pointSelectRadius = 8.0 -- distance in meters to select a point
  self.pulseTime = 0  -- accumulated time for pulsating effect
  self.updatedAt = os.time()  -- timestamp of last save
end

function C:clearState()
  self.path = nil
  self.measurements = {}
  self.selectedMeasurementId = nil
  self.selectedPointIndex = nil
  self.nextMeasurementId = 1
  self.snaproad = nil
  self.mouseInfo = {}
  self.isDragging = false
  self.draggedPointIndex = nil
  self.hoverPointIndex = nil
  self.hoverMeasurementId = nil
  self.dragStarted = false
  self.lastMousePos = nil
  self.pulseTime = 0
  self.updatedAt = os.time()
end

-- Get the measurements file path
function C:getMeasurementsFilePath()
  local missionDir = self.rallyEditor.getMissionDir()
  if not missionDir then
    log('E', logTag, 'Cannot get measurements file path: no mission directory')
    return nil
  end
  return missionDir .. '/measurements.json'
end

-- Serialize measurements to JSON-compatible format
function C:serialize()
  local data = {
    measurements = {},
    nextMeasurementId = self.nextMeasurementId,
    updatedAt = self.updatedAt
  }

  for id, measurement in pairs(self.measurements) do
    local serializedPoints = {}
    for i, point in ipairs(measurement.points) do
      -- Store only position, convert vec3 to table
      local serializedPoint = {x = point.x, y = point.y, z = point.z}
      table.insert(serializedPoints, serializedPoint)
    end

    data.measurements[tostring(id)] = {
      id = measurement.id,
      name = measurement.name,
      points = serializedPoints,
      followRoute = measurement.followRoute,
      color = measurement.color,
      textColor = measurement.textColor
    }
  end

  return data
end

-- Deserialize measurements from JSON data
function C:deserialize(data)
  if not data then return end

  self.measurements = {}
  self.updatedAt = data.updatedAt or os.time()

  local maxId = 0
  for idStr, measurement in pairs(data.measurements or {}) do
    local deserializedPoints = {}
    for i, point in ipairs(measurement.points or {}) do
      -- Convert table to vec3
      table.insert(deserializedPoints, vec3(point.x, point.y, point.z))
    end

    self.measurements[measurement.id] = {
      id = measurement.id,
      name = measurement.name,
      points = deserializedPoints,
      totalDistance = 0,  -- will be recalculated
      followRoute = measurement.followRoute or false,
      color = measurement.color or {cc.clr_yellow[1], cc.clr_yellow[2], cc.clr_yellow[3]},
      textColor = measurement.textColor or {cc.clr_black[1], cc.clr_black[2], cc.clr_black[3]}
    }

    -- Track the highest ID
    if measurement.id > maxId then
      maxId = measurement.id
    end
  end

  -- Set nextMeasurementId to one after the highest existing ID
  self.nextMeasurementId = maxId + 1

  log('I', logTag, 'Loaded ' .. tableSize(self.measurements) .. ' measurements')
end

-- Save measurements to file (auto-save)
function C:saveMeasurements()
  local filePath = self:getMeasurementsFilePath()
  if not filePath then
    log('E', logTag, 'Cannot save measurements: no file path')
    return false
  end

  self.updatedAt = os.time()
  local data = self:serialize()
  jsonWriteFile(filePath, data, true)
  log('D', logTag, 'Auto-saved measurements to: ' .. filePath)
  return true
end

-- Load measurements from file
function C:loadMeasurements()
  local filePath = self:getMeasurementsFilePath()
  if not filePath then
    log('E', logTag, 'Cannot load measurements: no file path')
    return false
  end

  if not FS:fileExists(filePath) then
    log('D', logTag, 'No measurements file found at: ' .. filePath)
    return false
  end

  local data = jsonReadFile(filePath)
  if not data then
    log('E', logTag, 'Failed to read measurements file: ' .. filePath)
    return false
  end

  -- If file doesn't have updatedAt timestamp, use file modification time
  if not data.updatedAt then
    local fileInfo = FS:stat(filePath)
    if fileInfo then
      data.updatedAt = fileInfo.filetime
    end
  end

  self:deserialize(data)

  -- Recalculate distances for all measurements
  for id, measurement in pairs(self.measurements) do
    self:calculateMeasurementDistance(id)
  end

  log('I', logTag, 'Loaded measurements from: ' .. filePath)
  return true
end

-- this is the notebook. why am I still calling it a path???
function C:setPath(path)
  self.path = path
end

-- Set the snaproad for distance calculations
function C:setSnaproad(snaproad)
  self.snaproad = snaproad
end

-- called by RallyEditor when this tab is selected.
function C:selected()
  if not self.path then return end

  -- Get the snaproad from the pacenotes window
  local pacenotesWindow = self.rallyEditor.getPacenotesWindow()
  if pacenotesWindow then
    local snaproad = pacenotesWindow:getSnaproad()
    if snaproad then
      self:setSnaproad(snaproad)
      log('D', logTag, 'Got snaproad from pacenotes window')
    else
      log('W', logTag, 'No snaproad available from pacenotes window')
    end
  else
    log('W', logTag, 'Could not get pacenotes window from rally editor')
  end

  -- Auto-load measurements if file exists
  self:loadMeasurements()

  -- force redraw of shortcutLegend window
  extensions.hook("onEditorEditModeChanged", nil, nil)
end

-- called by RallyEditor when this tab is unselected.
function C:unselect()
  if not self.path then return end

  -- force redraw of shortcutLegend window
  extensions.hook("onEditorEditModeChanged", nil, nil)
end

-- Draw debug visualization for measurements and snaproad
function C:drawDebugEntrypoint()
  if not self.path then return end

  -- Draw snaproad if available
  if self.snaproad then
    local snaproadPrismWidth = self.rallyEditor.getPrefDrivelineSplinePrismWidth and self.rallyEditor.getPrefDrivelineSplinePrismWidth()
    self.snaproad:drawDebugSnaproad(cc.clr_black, snaproadPrismWidth)
  end

  -- Draw measurement points
  self:drawMeasurementPoints()
end

-- Draw measurement points and lines
function C:drawMeasurementPoints()
  local alpha = 1.0
  local radius = POINT_SPHERE_RADIUS

  for _, measurement in pairs(self.measurements) do
    if #measurement.points > 0 then
      -- Draw points
      for i, point in ipairs(measurement.points) do
        local pos = point
        local color = measurement.color
        local pointRadius = radius

        -- Only highlight selected point if this is the selected measurement
        local isSelected = measurement.id == self.selectedMeasurementId and i == self.selectedPointIndex
        if isSelected then
          -- Apply pulsating effect to selected point (scale between 1.0 and 1.25)
          local pulseScale = 1.0 + 0.25 * (math.sin(self.pulseTime * 4) * 0.5 + 0.5)
          pointRadius = radius * pulseScale
        end

        debugDrawer:drawSphere(pos, pointRadius, ColorF(color[1], color[2], color[3], ALPHA), false, false)

        -- Draw white sphere around selected point
        if isSelected then
          debugDrawer:drawSphere(pos, HOVER_SPHERE_RADIUS, ColorF(cc.clr_white[1], cc.clr_white[2], cc.clr_white[3], 1.0), false, false)
        end

        -- Draw intersection plane
        local normal = vec3(0, 1, 0) -- default forward direction

        -- Calculate direction from snaproad or adjacent points
        if self.snaproad then
          local snapResult = self.snaproad:closestSnapResult(pos, true)
          if snapResult and snapResult.fromPoint and snapResult.toPoint then
            normal = (vec3(snapResult.toPoint.pos) - vec3(snapResult.fromPoint.pos)):normalized()
          end
        end

        -- Fallback to direction to next point
        if normal:length() < 0.5 and i < #measurement.points then
          local nextPoint = measurement.points[i + 1]
          normal = (nextPoint - pos):normalized()
        end

        -- Or use direction from previous point
        if normal:length() < 0.5 and i > 1 then
          local prevPoint = measurement.points[i - 1]
          normal = (pos - prevPoint):normalized()
        end

        local plane_radius = radius * 2
        local midWidth = plane_radius * 2
        local side = normal:cross(vec3(0, 0, 1)) * (plane_radius - (midWidth / 2))

        -- draw intersection plane
        debugDrawer:drawSquarePrism(
          pos + side,
          pos + 0.25 * normal + side,
          Point2F(INTERSECTION_PLANE_HEIGHT, midWidth),
          Point2F(0, 0),
          ColorF(color[1], color[2], color[3], ALPHA),
          false, false
        )

        -- Draw point number label (only for selected measurement)
        if measurement.id == self.selectedMeasurementId then
          local labelPos = pos + vec3(0, 0, 2)  -- offset upward for visibility

          debugDrawer:drawTextAdvanced(
            labelPos,
            String("p" .. i),
            ColorF(measurement.textColor[1], measurement.textColor[2], measurement.textColor[3], TEXT_ALPHA),
            true,
            false,
            ColorI(measurement.color[1]*255, measurement.color[2]*255, measurement.color[3]*255, TEXT_ALPHA*255),
            false,
            false
          )
        end

        -- Draw measurement name and distance at both ends
        if i == 1 or i == #measurement.points then
          local measurementLabelPos = pos + vec3(0, 0, 4)  -- higher up for visibility
          local distanceText = string.format("%s | %.2fm", measurement.name, measurement.totalDistance)

          -- Draw cylinder connecting point to label
          debugDrawer:drawCylinder(
            pos,
            measurementLabelPos,
            0.25,
            ColorF(measurement.color[1], measurement.color[2], measurement.color[3], ALPHA),
            false, false
          )

          debugDrawer:drawTextAdvanced(
            measurementLabelPos,
            String(distanceText),
            ColorF(measurement.textColor[1], measurement.textColor[2], measurement.textColor[3], TEXT_ALPHA),
            true,
            false,
            ColorI(measurement.color[1]*255, measurement.color[2]*255, measurement.color[3]*255, TEXT_ALPHA*255),
            false,
            false
          )
        end
      end

      -- Draw lines between consecutive points
      if #measurement.points > 1 then
        local driveline = self.snaproad and self.snaproad:driveline()
        if measurement.followRoute and driveline and driveline.points then
          -- Draw prisms following the route, accounting for continuous positions
          for i = 2, #measurement.points do
            local point1 = measurement.points[i-1]
            local point2 = measurement.points[i]

            -- Find which segments the points are on
            local drivelinePoints = driveline.points
            local minDistSq1, minDistSq2 = math.huge, math.huge
            local seg1P1, seg1P2, xnorm1
            local seg2P1, seg2P2, xnorm2

            for j = 1, #drivelinePoints - 1 do
              local p1 = drivelinePoints[j]
              local p2 = drivelinePoints[j + 1]
              if p1 and p2 then
                local distSq1 = point1:squaredDistanceToLineSegment(p1.pos, p2.pos)
                if distSq1 < minDistSq1 then
                  minDistSq1 = distSq1
                  seg1P1, seg1P2 = p1, p2
                  xnorm1 = point1:xnormOnLine(p1.pos, p2.pos)
                end

                local distSq2 = point2:squaredDistanceToLineSegment(p1.pos, p2.pos)
                if distSq2 < minDistSq2 then
                  minDistSq2 = distSq2
                  seg2P1, seg2P2 = p1, p2
                  xnorm2 = point2:xnormOnLine(p1.pos, p2.pos)
                end
              end
            end

            if seg1P1 and seg1P2 and seg2P1 and seg2P2 then
              if seg1P1.id == seg2P1.id then
                -- Both points on the same segment - draw one prism
                debugDrawer:drawSquarePrism(
                  point1, point2,
                  Point2F(ROUTE_PRISM_SIZE, ROUTE_PRISM_SIZE),
                  Point2F(ROUTE_PRISM_SIZE, ROUTE_PRISM_SIZE),
                  ColorF(measurement.color[1], measurement.color[2], measurement.color[3], ALPHA),
                  false, false
                )
              else
                -- Points on different segments
                local id1 = seg1P1.id
                local id2 = seg2P1.id

                if id2 > id1 then
                  -- Forward direction
                  -- Draw from point1 to end of its segment
                  debugDrawer:drawSquarePrism(
                    point1, vec3(seg1P2.pos),
                    Point2F(ROUTE_PRISM_SIZE, ROUTE_PRISM_SIZE),
                    Point2F(ROUTE_PRISM_SIZE, ROUTE_PRISM_SIZE),
                    ColorF(measurement.color[1], measurement.color[2], measurement.color[3], ALPHA),
                    false, false
                  )

                  -- Draw intermediate segments
                  for j = id1 + 1, id2 - 1 do
                    if drivelinePoints[j] and drivelinePoints[j+1] then
                      local pos1 = vec3(drivelinePoints[j].pos)
                      local pos2 = vec3(drivelinePoints[j+1].pos)
                      debugDrawer:drawSquarePrism(
                        pos1, pos2,
                        Point2F(ROUTE_PRISM_SIZE, ROUTE_PRISM_SIZE),
                        Point2F(ROUTE_PRISM_SIZE, ROUTE_PRISM_SIZE),
                        ColorF(measurement.color[1], measurement.color[2], measurement.color[3], ALPHA),
                        false, false
                      )
                    end
                  end

                  -- Draw from start of point2's segment to point2
                  debugDrawer:drawSquarePrism(
                    vec3(seg2P1.pos), point2,
                    Point2F(ROUTE_PRISM_SIZE, ROUTE_PRISM_SIZE),
                    Point2F(ROUTE_PRISM_SIZE, ROUTE_PRISM_SIZE),
                    ColorF(measurement.color[1], measurement.color[2], measurement.color[3], ALPHA),
                    false, false
                  )
                else
                  -- Backward direction
                  -- Draw from point1 back to start of its segment
                  debugDrawer:drawSquarePrism(
                    point1, vec3(seg1P1.pos),
                    Point2F(ROUTE_PRISM_SIZE, ROUTE_PRISM_SIZE),
                    Point2F(ROUTE_PRISM_SIZE, ROUTE_PRISM_SIZE),
                    ColorF(measurement.color[1], measurement.color[2], measurement.color[3], ALPHA),
                    false, false
                  )

                  -- Draw intermediate segments (backwards)
                  for j = id1 - 1, id2 + 1, -1 do
                    if drivelinePoints[j] and drivelinePoints[j+1] then
                      local pos1 = vec3(drivelinePoints[j].pos)
                      local pos2 = vec3(drivelinePoints[j+1].pos)
                      debugDrawer:drawSquarePrism(
                        pos1, pos2,
                        Point2F(ROUTE_PRISM_SIZE, ROUTE_PRISM_SIZE),
                        Point2F(ROUTE_PRISM_SIZE, ROUTE_PRISM_SIZE),
                        ColorF(measurement.color[1], measurement.color[2], measurement.color[3], ALPHA),
                        false, false
                      )
                    end
                  end

                  -- Draw from point2 to end of its segment
                  debugDrawer:drawSquarePrism(
                    point2, vec3(seg2P2.pos),
                    Point2F(ROUTE_PRISM_SIZE, ROUTE_PRISM_SIZE),
                    Point2F(ROUTE_PRISM_SIZE, ROUTE_PRISM_SIZE),
                    ColorF(measurement.color[1], measurement.color[2], measurement.color[3], ALPHA),
                    false, false
                  )
                end
              end
            end
          end
        else
          -- Draw direct lines between measurement points
          for i = 2, #measurement.points do
            local pos1 = measurement.points[i-1]
            local pos2 = measurement.points[i]
            local color = measurement.color
            debugDrawer:drawSquarePrism(
              pos1, pos2,
              Point2F(LINE_PRISM_SIZE, LINE_PRISM_SIZE),
              Point2F(LINE_PRISM_SIZE, LINE_PRISM_SIZE),
              ColorF(color[1], color[2], color[3], ALPHA),
              false, false
            )
          end
        end
      end
    end
  end
end

-- CRUD Operations for Measurements

-- Create a new measurement
function C:createMeasurement(name)
  -- Generate a random HSV color that's bright and vibrant
  local h = math.random()  -- Hue: 0 to 1 (full color spectrum)
  local s = 0.7 + math.random() * 0.3  -- Saturation: 0.7 to 1.0 (highly saturated)
  local v = 0.8 + math.random() * 0.2  -- Value: 0.8 to 1.0 (bright colors)

  local r, g, b = HSVtoRGB(h, s, v)

  -- Calculate luminance to determine appropriate text color
  local luminance = 0.299 * r + 0.587 * g + 0.114 * b
  local textColor = luminance > 0.5 and {0.0, 0.0, 0.0} or {1.0, 1.0, 1.0}

  local measurement = {
    id = self.nextMeasurementId,
    name = name or ("Measurement " .. self.nextMeasurementId),
    points = {},
    totalDistance = 0,
    followRoute = true,
    color = {r, g, b},
    textColor = textColor
  }
  self.measurements[measurement.id] = measurement
  self.nextMeasurementId = self.nextMeasurementId + 1
  self:selectMeasurement(measurement.id)
  self:saveMeasurements()  -- auto-save
  log('D', logTag, 'Created measurement: ' .. measurement.name)
  return measurement
end

-- Get measurement by ID
function C:getMeasurement(measurementId)
  return self.measurements[measurementId]
end

-- Update measurement name
function C:updateMeasurement(measurementId, name)
  local measurement = self.measurements[measurementId]
  if measurement then
    measurement.name = name
    log('D', logTag, 'Updated measurement: ' .. measurementId .. ' to ' .. name)
  end
end

-- Delete measurement
function C:deleteMeasurement(measurementId)
  if self.measurements[measurementId] then
    log('D', logTag, 'Deleted measurement: ' .. self.measurements[measurementId].name)
    self.measurements[measurementId] = nil
    if self.selectedMeasurementId == measurementId then
      self.selectedMeasurementId = nil
      self.selectedPointIndex = nil
    end

    -- Recalculate nextMeasurementId based on remaining measurements
    local maxId = 0
    for id, _ in pairs(self.measurements) do
      if id > maxId then
        maxId = id
      end
    end
    self.nextMeasurementId = maxId + 1

    self:saveMeasurements()  -- auto-save
  end
end

-- Select a measurement
function C:selectMeasurement(measurementId)
  self.selectedMeasurementId = measurementId
  self.selectedPointIndex = nil
  log('D', logTag, 'Selected measurement: ' .. tostring(measurementId))
end

-- Add point to measurement
function C:addPointToMeasurement(measurementId, point)
  local measurement = self.measurements[measurementId]
  if measurement then
    local pos = vec3(point)

    table.insert(measurement.points, pos)
    self.selectedPointIndex = #measurement.points  -- Select the newly added point
    self:calculateMeasurementDistance(measurementId)
    self:saveMeasurements()  -- auto-save
  end
end

-- Remove point from measurement
function C:removePointFromMeasurement(measurementId, pointIndex)
  local measurement = self.measurements[measurementId]
  if measurement and measurement.points[pointIndex] then
    table.remove(measurement.points, pointIndex)
    self:calculateMeasurementDistance(measurementId)
    if self.selectedPointIndex == pointIndex then
      self.selectedPointIndex = nil
    elseif self.selectedPointIndex and self.selectedPointIndex > pointIndex then
      self.selectedPointIndex = self.selectedPointIndex - 1
    end
    self:saveMeasurements()  -- auto-save
  end
end

-- Move point up in measurement (decrease index)
function C:movePointUp(measurementId, pointIndex)
  local measurement = self.measurements[measurementId]
  if measurement and pointIndex > 1 and measurement.points[pointIndex] then
    local temp = measurement.points[pointIndex]
    measurement.points[pointIndex] = measurement.points[pointIndex - 1]
    measurement.points[pointIndex - 1] = temp
    self.selectedPointIndex = pointIndex - 1
    self:calculateMeasurementDistance(measurementId)
    self:saveMeasurements()  -- auto-save
  end
end

-- Move point down in measurement (increase index)
function C:movePointDown(measurementId, pointIndex)
  local measurement = self.measurements[measurementId]
  if measurement and pointIndex < #measurement.points and measurement.points[pointIndex] then
    local temp = measurement.points[pointIndex]
    measurement.points[pointIndex] = measurement.points[pointIndex + 1]
    measurement.points[pointIndex + 1] = temp
    self.selectedPointIndex = pointIndex + 1
    self:calculateMeasurementDistance(measurementId)
    self:saveMeasurements()  -- auto-save
  end
end

-- Calculate total distance for a measurement
function C:calculateMeasurementDistance(measurementId)
  local measurement = self.measurements[measurementId]
  if not measurement then
    return 0
  end

  if #measurement.points < 2 then
    measurement.totalDistance = 0
    return 0
  end

  local totalDistance = 0

  local driveline = self.snaproad and self.snaproad:driveline()
  if measurement.followRoute and driveline and driveline.points then
    -- Calculate distance by following the route along snaproad, accounting for continuous positions
    for i = 2, #measurement.points do
      local point1 = measurement.points[i-1]
      local point2 = measurement.points[i]

      -- Find which segments the points are on
      local drivelinePoints = driveline.points
      local minDistSq1, minDistSq2 = math.huge, math.huge
      local seg1P1, seg1P2, xnorm1
      local seg2P1, seg2P2, xnorm2

      for j = 1, #drivelinePoints - 1 do
        local p1 = drivelinePoints[j]
        local p2 = drivelinePoints[j + 1]
        if p1 and p2 then
          local distSq1 = point1:squaredDistanceToLineSegment(p1.pos, p2.pos)
          if distSq1 < minDistSq1 then
            minDistSq1 = distSq1
            seg1P1, seg1P2 = p1, p2
            xnorm1 = point1:xnormOnLine(p1.pos, p2.pos)
          end

          local distSq2 = point2:squaredDistanceToLineSegment(p1.pos, p2.pos)
          if distSq2 < minDistSq2 then
            minDistSq2 = distSq2
            seg2P1, seg2P2 = p1, p2
            xnorm2 = point2:xnormOnLine(p1.pos, p2.pos)
          end
        end
      end

      if seg1P1 and seg1P2 and seg2P1 and seg2P2 then
        local distance = 0

        if seg1P1.id == seg2P1.id then
          -- Both points on the same segment
          local segmentLength = (vec3(seg1P2.pos) - vec3(seg1P1.pos)):length()
          distance = segmentLength * math.abs(xnorm2 - xnorm1)
        else
          -- Points on different segments
          local id1 = seg1P1.id
          local id2 = seg2P1.id

          if id2 > id1 then
            -- Forward direction
            -- Distance from point1 to end of its segment
            local seg1Length = (vec3(seg1P2.pos) - vec3(seg1P1.pos)):length()
            distance = distance + seg1Length * (1 - xnorm1)

            -- Distance through intermediate segments
            for j = id1 + 1, id2 - 1 do
              if drivelinePoints[j] and drivelinePoints[j+1] then
                local pos1 = vec3(drivelinePoints[j].pos)
                local pos2 = vec3(drivelinePoints[j+1].pos)
                distance = distance + (pos2 - pos1):length()
              end
            end

            -- Distance from start of point2's segment to point2
            local seg2Length = (vec3(seg2P2.pos) - vec3(seg2P1.pos)):length()
            distance = distance + seg2Length * xnorm2
          else
            -- Backward direction
            -- Distance from point1 back to start of its segment
            local seg1Length = (vec3(seg1P2.pos) - vec3(seg1P1.pos)):length()
            distance = distance + seg1Length * xnorm1

            -- Distance through intermediate segments (backwards)
            for j = id1 - 1, id2 + 1, -1 do
              if drivelinePoints[j] and drivelinePoints[j+1] then
                local pos1 = vec3(drivelinePoints[j].pos)
                local pos2 = vec3(drivelinePoints[j+1].pos)
                distance = distance + (pos2 - pos1):length()
              end
            end

            -- Distance from point2 to end of its segment
            local seg2Length = (vec3(seg2P2.pos) - vec3(seg2P1.pos)):length()
            distance = distance + seg2Length * (1 - xnorm2)
          end
        end

        totalDistance = totalDistance + distance
      else
        -- Fallback to straight line distance
        totalDistance = totalDistance + (point2 - point1):length()
      end
    end
  else
    -- Direct distance between measurement points (not following route)
    for i = 2, #measurement.points do
      local point1 = measurement.points[i-1]
      local point2 = measurement.points[i]
      totalDistance = totalDistance + (point2 - point1):length()
    end
  end

  measurement.totalDistance = totalDistance
  return totalDistance
end

-- Find the nearest point to the mouse position
function C:findNearestPoint(mousePos)
  local nearestIndex = nil
  local nearestMeasurementId = nil
  local nearestDist = math.huge
  local nearestPoint = nil

  -- Search across all measurements
  for measurementId, measurement in pairs(self.measurements) do
    if measurement.points and #measurement.points > 0 then
      for i, point in ipairs(measurement.points) do
        local dist = (point - mousePos):length()
        if dist < nearestDist then
          nearestDist = dist
          nearestIndex = i
          nearestMeasurementId = measurementId
          nearestPoint = point
        end
      end
    end
  end

  return nearestMeasurementId, nearestIndex, nearestPoint, nearestDist
end

-- Handle mouse interactions for placing, selecting, and moving measurement points
function C:handleMouseInput()
  if not self.mouseInfo.valid then
    return
  end

  if not self.mouseInfo.rayCast then return end

  local pos_rayCast = self.mouseInfo.rayCast.pos
  local snapPos = pos_rayCast
  local distToSnaproad = 0

  -- Snap to snaproad if available
  if self.snaproad then
    snapPos = self.snaproad:closestSnapPos(pos_rayCast)
    distToSnaproad = (pos_rayCast - snapPos):length()
  end

  -- Check if we're within threshold to add points
  local withinSnapThreshold = distToSnaproad < SNAP_THRESHOLD

  -- Find nearest point to mouse across all measurements
  local nearestMeasurementId, nearestIndex, nearestPoint, nearestDist = self:findNearestPoint(snapPos)

  -- Update hover state
  if nearestDist < self.pointSelectRadius then
    self.hoverPointIndex = nearestIndex
    self.hoverMeasurementId = nearestMeasurementId
  else
    self.hoverPointIndex = nil
    self.hoverMeasurementId = nil
  end

  -- Handle mouse down
  if self.mouseInfo.down then
    if not self.isDragging then
      -- Check if we're clicking on an existing point
      if self.hoverPointIndex and self.hoverMeasurementId then
        -- Select the measurement and point
        self:selectMeasurement(self.hoverMeasurementId)
        self.selectedPointIndex = self.hoverPointIndex
        self.isDragging = true
        self.draggedPointIndex = self.hoverPointIndex
        self.lastMousePos = vec3(pos_rayCast)  -- Store initial mouse position

        log('D', logTag, 'Selected measurement ' .. self.hoverMeasurementId .. ', point ' .. self.hoverPointIndex .. ' for dragging')
      elseif withinSnapThreshold and self.selectedMeasurementId then
        -- Calculate continuous position on road segment using raw raycast position
        local continuousPos = pos_rayCast
        local driveline = self.snaproad and self.snaproad:driveline()
        if driveline and driveline.points then
          local drivelinePoints = driveline.points
          local minDistSq = math.huge
          local bestP1, bestP2

          for i = 1, #drivelinePoints - 1 do
            local p1 = drivelinePoints[i]
            local p2 = drivelinePoints[i + 1]
            if p1 and p2 then
              local distSq = pos_rayCast:squaredDistanceToLineSegment(p1.pos, p2.pos)
              if distSq < minDistSq then
                minDistSq = distSq
                bestP1 = p1
                bestP2 = p2
              end
            end
          end

          if bestP1 and bestP2 then
            local xnorm = pos_rayCast:xnormOnLine(bestP1.pos, bestP2.pos)
            continuousPos = vec3(lerp(bestP1.pos, bestP2.pos, clamp(xnorm, 0, 1)))
          end
        end

        -- Create a new point at continuous position
        self:addPointToMeasurement(self.selectedMeasurementId, continuousPos)
        log('D', logTag, 'Added measurement point at: ' .. tostring(continuousPos))
      else
        -- Clicked outside threshold, deselect current point
        self.selectedPointIndex = nil
        log('D', logTag, 'Deselected point (clicked outside snap threshold)')
      end
    end
  end

  -- Handle dragging
  if self.isDragging and self.draggedPointIndex and self.selectedMeasurementId then
    local selectedMeasurement = self:getMeasurement(self.selectedMeasurementId)
    if selectedMeasurement then
      if self.mouseInfo.hold and self.lastMousePos then
        -- Update the dragged point position while dragging
        self.dragStarted = true

        -- Calculate mouse movement delta (XY only)
        local deltaXY = vec3(pos_rayCast.x - self.lastMousePos.x,
                             pos_rayCast.y - self.lastMousePos.y,
                             0)

        -- Apply delta to current point position
        local currentPoint = selectedMeasurement.points[self.draggedPointIndex]
        local targetPos = currentPoint + deltaXY

        -- Project onto road segment for continuous positioning
        local driveline = self.snaproad and self.snaproad:driveline()
        if driveline and driveline.points then
          local drivelinePoints = driveline.points
          local minDistSq = math.huge
          local bestP1, bestP2

          -- Find the closest segment using squaredDistanceToLineSegment
          for i = 1, #drivelinePoints - 1 do
            local p1 = drivelinePoints[i]
            local p2 = drivelinePoints[i + 1]
            if p1 and p2 then
              local distSq = targetPos:squaredDistanceToLineSegment(p1.pos, p2.pos)
              if distSq < minDistSq then
                minDistSq = distSq
                bestP1 = p1
                bestP2 = p2
              end
            end
          end

          -- Project onto the closest segment using xnorm
          if bestP1 and bestP2 then
            local xnorm = targetPos:xnormOnLine(bestP1.pos, bestP2.pos)
            local newPos = lerp(bestP1.pos, bestP2.pos, clamp(xnorm, 0, 1))
            selectedMeasurement.points[self.draggedPointIndex] = vec3(newPos)
          else
            selectedMeasurement.points[self.draggedPointIndex] = vec3(targetPos)
          end
        else
          selectedMeasurement.points[self.draggedPointIndex] = vec3(targetPos)
        end

        self.lastMousePos = vec3(pos_rayCast)
        self:calculateMeasurementDistance(self.selectedMeasurementId)
      elseif not self.mouseInfo.down then
        -- Mouse released, stop dragging
        if self.dragStarted then
          self:saveMeasurements()  -- auto-save after drag
        end
        self.isDragging = false
        self.draggedPointIndex = nil
        self.dragStarted = false
        self.lastMousePos = nil
        log('D', logTag, 'Finished dragging point')
      end
    end
  end

  -- Draw hover/drag indicator
  if self.hoverPointIndex and self.hoverMeasurementId and not self.isDragging then
    -- Draw white sphere on hovered point
    local hoverMeasurement = self:getMeasurement(self.hoverMeasurementId)
    if hoverMeasurement then
      local pos = hoverMeasurement.points[self.hoverPointIndex]
      local radius = HOVER_SPHERE_RADIUS
      local color = cc.clr_white
      debugDrawer:drawSphere(pos, radius, ColorF(color[1], color[2], color[3], 1.0), false, false)
    end
  elseif not self.hoverPointIndex and not self.isDragging and self.snaproad and withinSnapThreshold and self.selectedMeasurementId then
    -- Calculate continuous position on road segment using raw raycast position
    local continuousPos = pos_rayCast
    local driveline = self.snaproad and self.snaproad:driveline()
    if driveline and driveline.points then
      local drivelinePoints = driveline.points
      local minDistSq = math.huge
      local bestP1, bestP2

      -- Find the closest segment
      for i = 1, #drivelinePoints - 1 do
        local p1 = drivelinePoints[i]
        local p2 = drivelinePoints[i + 1]
        if p1 and p2 then
          local distSq = pos_rayCast:squaredDistanceToLineSegment(p1.pos, p2.pos)
          if distSq < minDistSq then
            minDistSq = distSq
            bestP1 = p1
            bestP2 = p2
          end
        end
      end

      -- Project onto the closest segment
      if bestP1 and bestP2 then
        local xnorm = pos_rayCast:xnormOnLine(bestP1.pos, bestP2.pos)
        continuousPos = vec3(lerp(bestP1.pos, bestP2.pos, clamp(xnorm, 0, 1)))
      end
    end

    -- Draw white sphere at continuous position to show where new point would be created
    local radius = INDICATOR_SPHERE_RADIUS
    local color = cc.clr_white
    debugDrawer:drawSphere(continuousPos, radius, ColorF(color[1], color[2], color[3], ALPHA), false, false)

    -- Draw label for adding new point
    local labelPos = continuousPos + vec3(0, 0, 2)
    debugDrawer:drawTextAdvanced(
      labelPos,
      String("Click to Add Point"),
      ColorF(cc.clr_black[1], cc.clr_black[2], cc.clr_black[3], TEXT_ALPHA),
      true,
      false,
      ColorI(cc.clr_white[1]*255, cc.clr_white[2]*255, cc.clr_white[3]*255, TEXT_ALPHA*255),
      false,
      false
    )
  end
end

function C:draw(mouseInfo, dtReal, dtSim, dtRaw)
  if not self.path then return end

  -- Update pulse time for animation
  self.pulseTime = self.pulseTime + (dtSim or 0)

  self.mouseInfo = mouseInfo
  if self.rallyEditor.allowGizmo() then
    self:handleMouseInput()
  end

  im.HeaderText("Measurements")
  im.Text("Track distance measurements along the snaproad.")

  -- Create new measurement button
  if im.Button("Create New Measurement") then
    self:createMeasurement()
  end

  im.SameLine()
  if im.Button("Delete Measurement") then
    if self.selectedMeasurementId then
      self:deleteMeasurement(self.selectedMeasurementId)
    end
  end

  -- Auto-save timestamp display
  im.SameLine()
  local diff = os.time() - self.updatedAt
  if diff > 3600*24 then
    im.Text(string.format("saved %dd ago", math.floor(diff / (3600*24))))
  elseif diff > 3600 then
    im.Text(string.format("saved %dh ago", math.floor(diff / 3600)))
  elseif diff > 60 then
    im.Text(string.format("saved %dm ago", math.floor(diff / 60)))
  else
    im.Text(string.format("saved %ds ago", diff))
  end

  -- Commented out manual save/load buttons (now using auto-save)
  -- im.SameLine()
  -- im.PushStyleColor2(im.Col_Button, im.ImColorByRGB(0,100,0,255).Value)
  -- if im.Button("Save") then
  --   self:saveMeasurements()
  -- end
  -- im.PopStyleColor(1)
  -- if im.IsItemHovered() then
  --   im.BeginTooltip()
  --   local filePath = self:getMeasurementsFilePath()
  --   im.Text("Save measurements to:")
  --   im.Text(filePath or "N/A")
  --   im.EndTooltip()
  -- end
  --
  -- im.SameLine()
  -- if im.Button("Load") then
  --   self:loadMeasurements()
  -- end
  -- if im.IsItemHovered() then
  --   im.BeginTooltip()
  --   local filePath = self:getMeasurementsFilePath()
  --   im.Text("Load measurements from:")
  --   im.Text(filePath or "N/A")
  --   im.EndTooltip()
  -- end

  im.Separator()

  -- Measurements list
  im.HeaderText("Measurements List")

  im.BeginChild1("measurements", im.ImVec2(0, 200), im.WindowFlags_ChildWindow)

  for measurementId, measurement in pairs(self.measurements) do
    local isSelected = measurement.id == self.selectedMeasurementId
    local displayText = string.format("%s (%.2fm, %d points)",
                                     measurement.name,
                                     measurement.totalDistance,
                                     #measurement.points)

    if im.Selectable1(displayText, isSelected) then
      self:selectMeasurement(measurement.id)
    end


  end

  im.EndChild()

  -- Selected measurement details
  if self.selectedMeasurementId then
    local selectedMeasurement = self:getMeasurement(self.selectedMeasurementId)
    if selectedMeasurement then
      im.Separator()
      im.HeaderText("Selected Measurement: " .. selectedMeasurement.name)

      -- Follow Route toggle
      local followRoute = im.BoolPtr(selectedMeasurement.followRoute)
      if im.Checkbox("Follow Route", followRoute) then
        selectedMeasurement.followRoute = followRoute[0]
        self:calculateMeasurementDistance(self.selectedMeasurementId)
        self:saveMeasurements()  -- auto-save
        log('D', logTag, 'Follow Route set to: ' .. tostring(selectedMeasurement.followRoute))
      end
      if im.IsItemHovered() then
        im.BeginTooltip()
        im.Text("When enabled, measures distance by following the snaproad between points.")
        im.Text("When disabled, measures direct straight-line distance between points.")
        im.EndTooltip()
      end

      -- Color picker
      im.Text("Measurement Color:")
      local colorPtr = im.ArrayFloat(3)
      colorPtr[0] = selectedMeasurement.color[1]
      colorPtr[1] = selectedMeasurement.color[2]
      colorPtr[2] = selectedMeasurement.color[3]
      if im.ColorEdit3("##MeasurementColor", colorPtr) then
        selectedMeasurement.color[1] = colorPtr[0]
        selectedMeasurement.color[2] = colorPtr[1]
        selectedMeasurement.color[3] = colorPtr[2]
        self:saveMeasurements()  -- auto-save
      end

      -- Text color selector (black or white)
      im.Text("Text Color:")
      local isWhiteText = selectedMeasurement.textColor[1] > 0.5
      local textColorValue = im.IntPtr(isWhiteText and 1 or 0)
      if im.SliderInt("##TextColor", textColorValue, 0, 1, textColorValue[0] == 0 and "Black" or "White") then
        if textColorValue[0] == 1 then
          selectedMeasurement.textColor = {1.0, 1.0, 1.0}
        else
          selectedMeasurement.textColor = {0.0, 0.0, 0.0}
        end
        self:saveMeasurements()  -- auto-save
      end

      im.Text(string.format("Total Distance: %.2f meters", selectedMeasurement.totalDistance))
      im.Text(string.format("Number of Points: %d", #selectedMeasurement.points))

      -- Points list
      im.HeaderText("Points")
      if im.Button("Move Up") then
        if self.selectedPointIndex then
          self:movePointUp(self.selectedMeasurementId, self.selectedPointIndex)
        end
      end

      im.SameLine()
      if im.Button("Move Down") then
        if self.selectedPointIndex then
          self:movePointDown(self.selectedMeasurementId, self.selectedPointIndex)
        end
      end

      im.SameLine()
      if im.Button("Delete Point") then
        if self.selectedPointIndex then
          self:removePointFromMeasurement(self.selectedMeasurementId, self.selectedPointIndex)
        end
      end

      im.Text("Click in 3D world to add measurement points")

      im.BeginChild1("points", im.ImVec2(0, 150), im.WindowFlags_ChildWindow)

      local points = selectedMeasurement.points

      for i, point in ipairs(points) do
        local isPointSelected = i == self.selectedPointIndex
        local pointText = string.format("Point %d: (%.1f, %.1f, %.1f)",
                                        i, point.x, point.y, point.z)

        if im.Selectable1(pointText, isPointSelected) then
          self.selectedPointIndex = i
        end
      end

      im.EndChild()
    end
  end

  self:drawDebugEntrypoint()
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
