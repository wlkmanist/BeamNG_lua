local cc = require('/lua/ge/extensions/gameplay/rally/util/colors')
local util = require('editor/tech/roadArchitect/utilities')                                         -- A module containing miscellaneous utility functions.
local compositorUtil = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/compositorUtil')

local M = {}

local defaultMeasurementType = 'single'
local measurementTypeOrder = { 'single', 'split2', 'split3' }
local measurementTypes = {
  single = {
    id = 'single',
    label = 'Single fit',
    segmentCount = 1,
  },
  split2 = {
    id = 'split2',
    label = 'Two-part fit',
    segmentCount = 2,
  },
  split3 = {
    id = 'split3',
    label = 'Three-part fit',
    segmentCount = 3,
  },
}

local function normalizeMeasurementType(measurementType)
  if measurementTypes[measurementType] then return measurementType end
  return defaultMeasurementType
end

local function measurementTypeOptions()
  local out = {}
  for _, measurementType in ipairs(measurementTypeOrder) do
    table.insert(out, measurementTypes[measurementType])
  end
  return out
end

-- Module level color and alpha for prisms and text backgrounds
local prismColor = cc.clr_purple
local prismAlpha = 0.7

-- Helper function to convert RGB float color to ColorI for text backgrounds
local function getTextBackgroundColor(clr, alpha)
  return ColorI(clr[1] * 255, clr[2] * 255, clr[3] * 255, alpha * 255)
end

local function getNearestIntensityByDiameter(cornerIntensityTable, measuredDiameter)
  if not cornerIntensityTable or not measuredDiameter then
    return nil
  end

  return compositorUtil.getRangeValue(cornerIntensityTable, measuredDiameter, 'diameter')
end

local function detectCornerDirection(measurement)
  if not measurement or not measurement.p1 or not measurement.p2 or not measurement.p3 then
    return nil
  end

  local p1 = measurement.p1
  local p2 = measurement.p2
  local p3 = measurement.p3

  -- Calculate vectors
  local v1 = p2 - p1
  local v2 = p3 - p2

  -- Calculate cross product (z-component determines left/right)
  -- For a road in x-y plane, positive z means left turn, negative z means right turn
  local crossZ = v1.x * v2.y - v1.y * v2.x

  -- Do not classify measured corners as "straight". Whether a pacenote has a
  -- corner is user-controlled by the structured note's corner checkbox.
  return crossZ >= 0 and "left" or "right"
end

local function buildHairpinCandidate(measurement)
  if not measurement or not measurement.diameter or measurement.diameter <= 0 then return nil end

  local arcMeters = measurement.arcMeters or measurement.pointsLength or measurement.arcDistance
  local chordMeters = measurement.chordMeters or measurement.straightLineDistance
  local circumference = math.pi * measurement.diameter
  local arcRatio = arcMeters and circumference > 0 and (arcMeters / circumference) or nil
  local chordRatio = chordMeters and measurement.diameter > 0 and (chordMeters / measurement.diameter) or nil
  local arcDegrees = measurement.arcDegrees
  local fitQuality = measurement.fitQuality

  local score = 0
  local reasons = {}
  if measurement.diameter <= 35 then
    score = score + 1
    table.insert(reasons, 'smallDiameter')
  end
  if arcDegrees and arcDegrees >= 135 then
    score = score + 1
    table.insert(reasons, 'largeArcDegrees')
  end
  if arcRatio and arcRatio >= 0.35 then
    score = score + 1
    table.insert(reasons, 'longArcMetersVsCircumference')
  end
  if chordRatio and chordRatio <= 1.5 then
    score = score + 1
    table.insert(reasons, 'compactChord')
  end
  if fitQuality and fitQuality <= 0.15 then
    score = score + 1
    table.insert(reasons, 'usableFit')
  end

  return {
    isCandidate = score >= 4,
    score = score,
    maxScore = 5,
    reasons = reasons,
    diameterThreshold = 35,
    arcDegreesThreshold = 135,
    arcRatioThreshold = 0.35,
    chordRatioThreshold = 1.5,
    arcRatio = arcRatio,
    chordRatio = chordRatio,
  }
end

local function annotateMeasurement(measurement, cornerIntensityTable)
  if not measurement then return end

  measurement.intensity = measurement.diameter and getNearestIntensityByDiameter(cornerIntensityTable, measurement.diameter) or nil
  measurement.direction = detectCornerDirection(measurement)
  measurement.hairpinCandidate = buildHairpinCandidate(measurement)
end

local function annotateVariant(variant, cornerIntensityTable)
  if not variant then return end

  for _, measurement in ipairs(variant.segments or {}) do
    annotateMeasurement(measurement, cornerIntensityTable)
  end

  -- Multi-part variants project from the first segment's corner intensity while
  -- length/angle/chord values represent the selected variant as a whole.
  local representative = (variant.segments and variant.segments[1]) or variant
  if representative and representative ~= variant then
    variant.intensity = representative.intensity
    variant.direction = representative.direction
    variant.hairpinCandidate = representative.hairpinCandidate
  else
    annotateMeasurement(variant, cornerIntensityTable)
  end
end

local function calculateAndStoreIntensityDirection(pn)
  -- Get the text compositor to access corner intensity definitions
  local textCompositor = pn.notebook and pn.notebook:getTextCompositor()

  local config = textCompositor and textCompositor:getConfig() or nil
  local cornerCfg = config and config.componentTypes and config.componentTypes.corner
  local cornerIntensityTable = compositorUtil.cornerIntensityList(cornerCfg)

  for _, measurementType in ipairs(measurementTypeOrder) do
    annotateVariant(pn.measurements.variants and pn.measurements.variants[measurementType], cornerIntensityTable)
  end

  local measurement1 = pn.measurements.corner1
  local measurement2 = pn.measurements.corner2
  annotateMeasurement(measurement1, cornerIntensityTable)
  annotateMeasurement(measurement2, cornerIntensityTable)

  -- Calculate and store diameter change between corners
  local changeMeasurement1 = measurement1
  local changeMeasurement2 = measurement2
  local split2 = pn.measurements.variants and pn.measurements.variants.split2
  if not changeMeasurement2 and split2 and split2.segments then
    changeMeasurement1 = split2.segments[1]
    changeMeasurement2 = split2.segments[2]
  end

  if changeMeasurement1 and changeMeasurement2 and changeMeasurement1.diameter and changeMeasurement2.diameter then
    local diameterChange = changeMeasurement2.diameter - changeMeasurement1.diameter
    local changePercent = (diameterChange / changeMeasurement1.diameter) * 100

    pn.measurements.diameterChange = {
      change = diameterChange,
      changePercent = changePercent,
      isOpening = diameterChange > 0,
      isTightening = diameterChange < 0,
    }
  else
    pn.measurements.diameterChange = nil
  end
end

-- Calculate normalized RMSE to quantify how well points fit to a circle
-- Returns a value typically between 0.0 (perfect fit) and 0.2+ (poor fit)
-- Values < 0.05 = excellent, 0.05-0.15 = good, > 0.15 = poor/compound corner
local function calculateCircleFitQuality(center, radius, points)
  if not center or not radius or radius == 0 or not points or #points < 3 then
    return nil
  end

  local sumSquaredErrors = 0
  local n = #points

  for _, point in ipairs(points) do
    -- Calculate 2D distance from point to center (matching how radius was calculated)
    local distToCenter = math.sqrt((point.x - center.x)^2 + (point.y - center.y)^2)
    local error = distToCenter - radius
    sumSquaredErrors = sumSquaredErrors + (error * error)
  end

  local rmse = math.sqrt(sumSquaredErrors / n)
  local normalizedRMSE = rmse / radius

  return normalizedRMSE
end

-- Calculate circle from points using the simpler 2D method
local function calculateCircleFromPoints2(p1, p2, p3)
  local center = util.circle2DFrom3Points(p1, p2, p3)
  if not center then
    return nil, 0, 0
  end

  -- Calculate radius as distance from center to first point (2D)
  local radius = math.sqrt((p1.x - center.x)^2 + (p1.y - center.y)^2)

  -- Use average Z coordinate for center
  local centerZ = (p1.z + p2.z + p3.z) / 3
  center.z = centerZ

  -- Calculate arc distance between p1 and p3 through p2
  local startAngle = math.atan2(p1.y - center.y, p1.x - center.x)
  local endAngle = math.atan2(p3.y - center.y, p3.x - center.x)

  -- Determine direction of arc using cross product with middle point
  local cross = (p2 - p1):cross(p3 - p1)
  local clockwise = cross.z < 0

  -- Adjust angles based on direction to get the shorter arc
  if clockwise then
    if endAngle > startAngle then
      endAngle = endAngle - 2 * math.pi
    end
  else
    if endAngle < startAngle then
      endAngle = endAngle + 2 * math.pi
    end
  end

  -- Calculate arc distance
  local angleInRadians = math.abs(endAngle - startAngle)
  local arcDistance = radius * angleInRadians

  return center, radius, arcDistance
end

local function pathLength(points)
  local total = 0
  for i = 2, #(points or {}) do
    total = total + points[i]:distance(points[i-1])
  end
  return total
end

local function fitPathSegment(pathPoints, startIdx, endIdx)
  if not pathPoints or #pathPoints < 3 then return nil end
  startIdx = math.max(1, math.min(#pathPoints - 2, startIdx))
  endIdx = math.max(startIdx + 2, math.min(#pathPoints, endIdx))
  if endIdx > #pathPoints then return nil end

  local midIdx = math.floor((startIdx + endIdx) * 0.5)
  local p1 = vec3(pathPoints[startIdx])
  local p2 = vec3(pathPoints[midIdx])
  local p3 = vec3(pathPoints[endIdx])
  local center, radius, arcDistance = calculateCircleFromPoints2(p1, p2, p3)

  local segmentPoints = {}
  for i = startIdx, endIdx do
    table.insert(segmentPoints, vec3(pathPoints[i]))
  end

  local arcDegrees = (radius and radius > 0 and arcDistance) and (arcDistance / radius) * (180 / math.pi) or nil
  return {
    center = center,
    radius = radius,
    diameter = radius and (radius * 2) or nil,
    arcDistance = arcDistance,
    arcDegrees = arcDegrees,
    arcMeters = pathLength(segmentPoints),
    chordMeters = p1:distance(p3),
    straightLineDistance = p1:distance(p3),
    fitQuality = calculateCircleFitQuality(center, radius, segmentPoints),
    pointsLength = pathLength(segmentPoints),
    p1 = p1,
    p2 = p2,
    p3 = p3,
  }
end

local function buildSplitFit(pathPoints, segmentCount)
  local out = {}
  if not pathPoints or #pathPoints < (segmentCount + 2) then return out end

  local lastEnd = 1
  for segment = 1, segmentCount do
    local endIdx
    if segment == segmentCount then
      endIdx = #pathPoints
    else
      endIdx = math.floor(1 + ((#pathPoints - 1) * segment / segmentCount) + 0.5)
      endIdx = math.max(lastEnd + 2, math.min(#pathPoints - 1, endIdx))
    end

    local fit = fitPathSegment(pathPoints, lastEnd, endIdx)
    if fit then table.insert(out, fit) end
    lastEnd = endIdx
  end

  return out
end

local function weightedAverageFitQuality(segments)
  local totalWeight = 0
  local total = 0
  for _, segment in ipairs(segments or {}) do
    if segment.fitQuality then
      local weight = segment.pointsLength or segment.arcMeters or 1
      total = total + (segment.fitQuality * weight)
      totalWeight = totalWeight + weight
    end
  end
  if totalWeight <= 0 then return nil end
  return total / totalWeight
end

local function sumSegmentField(segments, fieldName)
  local total = 0
  local hasValue = false
  for _, segment in ipairs(segments or {}) do
    if segment[fieldName] then
      total = total + segment[fieldName]
      hasValue = true
    end
  end
  if not hasValue then return nil end
  return total
end

local function aggregateSegments(measurementType, segments)
  if not segments or #segments == 0 then return nil end
  if #segments == 1 then
    local single = deepcopy(segments[1])
    single.measurementType = measurementType
    single.segmentCount = 1
    single.segments = { segments[1] }
    single.totalPointsLength = single.pointsLength or single.arcMeters or single.arcDistance
    return single
  end

  local first = segments[1]
  local last = segments[#segments]
  local representative = first
  local splitPoints = {}
  for i = 1, #segments - 1 do
    table.insert(splitPoints, segments[i].p3)
  end

  return {
    measurementType = measurementType,
    segmentCount = #segments,
    segments = segments,
    splitPoints = splitPoints,
    splitPoint = splitPoints[1],
    center = representative.center,
    radius = representative.radius,
    diameter = representative.diameter,
    arcDistance = sumSegmentField(segments, 'arcDistance'),
    arcDegrees = sumSegmentField(segments, 'arcDegrees'),
    arcMeters = sumSegmentField(segments, 'arcMeters') or sumSegmentField(segments, 'pointsLength'),
    chordMeters = first.p1 and last.p3 and first.p1:distance(last.p3) or nil,
    straightLineDistance = first.p1 and last.p3 and first.p1:distance(last.p3) or nil,
    fitQuality = weightedAverageFitQuality(segments),
    pointsLength = sumSegmentField(segments, 'pointsLength') or sumSegmentField(segments, 'arcMeters'),
    totalPointsLength = sumSegmentField(segments, 'pointsLength') or sumSegmentField(segments, 'arcMeters'),
    p1 = first.p1,
    p2 = segments[math.floor((#segments + 1) * 0.5)].p2,
    p3 = last.p3,
  }
end

local function buildMeasurementPathPoints(focusPoints, startPos, endPos)
  local totalPoints = #focusPoints

  local closestToCS = 1
  local minDistCS = math.huge
  for i = 1, totalPoints do
    local dist = startPos:distance(vec3(focusPoints[i].pos))
    if dist < minDistCS then
      minDistCS = dist
      closestToCS = i
    end
  end

  local closestToCE = totalPoints
  local minDistCE = math.huge
  for i = 1, totalPoints do
    local dist = endPos:distance(vec3(focusPoints[i].pos))
    if dist < minDistCE then
      minDistCE = dist
      closestToCE = i
    end
  end

  if closestToCS > closestToCE then
    closestToCS, closestToCE = closestToCE, closestToCS
  end

  local pathPoints = {}
  table.insert(pathPoints, startPos)

  for i = closestToCS, closestToCE do
    table.insert(pathPoints, vec3(focusPoints[i].pos))
  end

  table.insert(pathPoints, endPos)
  return pathPoints
end

local function buildSingleFit(pathPoints, startPos, middlePos, endPos)
  local center, radius, arcDistance = calculateCircleFromPoints2(startPos, middlePos, endPos)
  local pointsLength = pathLength(pathPoints)
  local arcDegrees = (radius and radius > 0 and arcDistance) and (arcDistance / radius) * (180 / math.pi) or nil

  return {
    center = center,
    radius = radius,
    diameter = radius and (radius * 2) or nil,
    arcDistance = arcDistance,
    arcDegrees = arcDegrees,
    arcMeters = pointsLength,
    chordMeters = startPos:distance(endPos),
    straightLineDistance = startPos:distance(endPos),
    fitQuality = calculateCircleFitQuality(center, radius, pathPoints),
    pointsLength = pointsLength,
    p1 = startPos,
    p2 = middlePos,
    p3 = endPos,
  }
end

local function buildMeasurementVariants(pathPoints, singleFit)
  local variants = {
    single = aggregateSegments('single', { singleFit }),
    split2 = aggregateSegments('split2', buildSplitFit(pathPoints, 2)),
    split3 = aggregateSegments('split3', buildSplitFit(pathPoints, 3)),
  }
  return variants
end

local function buildMeasurementDiagnostics(pathPoints, fullFit)
  local variants = buildMeasurementVariants(pathPoints, fullFit or fitPathSegment(pathPoints, 1, #(pathPoints or {})))

  return {
    fullCircleFit = variants.single,
    twoCircleFit = variants.split2 and variants.split2.segments or {},
    threeCircleFit = variants.split3 and variants.split3.segments or {},
  }
end

-- Calculate circle from 3 points (adapted from geometry.lua)
-- local function calculateCircleFromPoints(p1, p2, p3)
--   -- Use 2D projections for circle calculation (ignore Z)
--   local p1z = vec3(p1.x, p1.y, 0)
--   local p2z = vec3(p2.x, p2.y, 0)
--   local p3z = vec3(p3.x, p3.y, 0)

--   local d1 = p1z - p3z
--   local d2 = p2z - p3z
--   local asql = d1:squaredLength()
--   local bsql = d2:squaredLength()
--   local adotb = d1:dot(d2)

--   -- calculate center
--   local condVec = d1:cross(d2)
--   local condVecSqLen = condVec:squaredLength()

--   if condVecSqLen < 1e-10 then
--     -- Points are nearly collinear, return nil
--     return nil, 0, 0, 0, 0
--   end

--   local center2d = p3z + ((bsql * (asql - adotb)) * d1 - (asql * (adotb - bsql)) * d2) / (2 * condVecSqLen)

--   -- Use average Z coordinate for center
--   local centerZ = (p1.z + p2.z + p3.z) / 3
--   local center = vec3(center2d.x, center2d.y, centerZ)

--   -- calculate horizontal radius (2D)
--   local horizontalRadius = math.sqrt((p1.x - center.x)^2 + (p1.y - center.y)^2)

--   -- calculate actual 3D radius (following road surface)
--   local actual3DRadius = p1:distance(center)

--   -- calculate angle
--   local angleCos = adotb / (math.sqrt(asql * bsql) + 1e-30)
--   local angleRad = math.acos(math.max(-1, math.min(1, angleCos)))
--   local angle = math.deg(angleRad) * 2

--   return center, horizontalRadius, actual3DRadius, angle
-- end

-- Calculate middle point between start and end positions
local function calculateMiddlePoint(pn, startPos, endPos, partition)
  local middlePos = nil
  if pn.halfpointPos then
    middlePos = vec3(pn.halfpointPos)
  elseif pn.halfpoint then
    -- log('D', logTag, 'using halfpoint')
    middlePos = vec3(pn.halfpoint.pos)
  else
    -- log('D', logTag, 'no halfpoint, calculating geometric middle point')
    -- Calculate geometric middle point between start and end
    middlePos = vec3(
      (startPos.x + endPos.x) / 2,
      (startPos.y + endPos.y) / 2,
      (startPos.z + endPos.z) / 2
    )

    -- Find the closest focus point to this geometric middle
    local focusPoints = partition.focus_points
    local closestDist = math.huge
    local closestPoint = nil

    for _, point in ipairs(focusPoints) do
      local dist = middlePos:distance(vec3(point.pos))
      if dist < closestDist then
        closestDist = dist
        closestPoint = point
      end
    end

    if closestPoint then
      middlePos = vec3(closestPoint.pos)
    end
  end

  return middlePos
end

-- Calculate arc length from angle and radius
-- local function calculateArcLength(startAngle, endAngle, horizontalRadius)
--   local angleInRadians = math.abs(endAngle - startAngle)
--   local arcLength = horizontalRadius * angleInRadians
--   return arcLength
-- end

-- Calculate arc midpoint position
local function calculateArcMidpoint(center, horizontalRadius, startAngle, endAngle, startPos, endPos)
  local midAngle = startAngle + (endAngle - startAngle) / 2
  local midProgress = 0.5
  local midZ = startPos.z + midProgress * (endPos.z - startPos.z)
  local midPoint = vec3(
    center.x + horizontalRadius * math.cos(midAngle),
    center.y + horizontalRadius * math.sin(midAngle),
    midZ
  )
  return midPoint
end

-- Calculate radius measurements
-- local function calculateRadiusMeasurements(horizontalRadius)
--   local diameter = horizontalRadius * 2
--   return diameter
-- end

-- Draw 3D arc following the actual road elevation
-- local function drawCircleArc(center, horizontalRadius, startPos, endPos, middlePos, clr, alpha)
--   local segments = 32
--   local startAngle = math.atan2(startPos.y - center.y, startPos.x - center.x)
--   local endAngle = math.atan2(endPos.y - center.y, endPos.x - center.x)

--   -- Determine direction of arc
--   local cross = (middlePos - startPos):cross(endPos - startPos)
--   local clockwise = cross.z < 0

--   if clockwise then
--     if endAngle > startAngle then
--       endAngle = endAngle - 2 * math.pi
--     end
--   else
--     if endAngle < startAngle then
--       endAngle = endAngle + 2 * math.pi
--     end
--   end

--   local angleStep = (endAngle - startAngle) / segments

--   -- Interpolate elevation along the arc for more realistic 3D representation
--   for i = 0, segments - 1 do
--      local angle1 = startAngle + i * angleStep
--      local angle2 = startAngle + (i + 1) * angleStep

--      -- Calculate progress along the arc (0 to 1)
--      local progress1 = i / segments
--      local progress2 = (i + 1) / segments

--      -- Interpolate Z coordinate based on actual road points
--      local z1 = startPos.z + progress1 * (endPos.z - startPos.z)
--      local z2 = startPos.z + progress2 * (endPos.z - startPos.z)

--      local pos1 = vec3(
--        center.x + horizontalRadius * math.cos(angle1),
--        center.y + horizontalRadius * math.sin(angle1),
--        z1
--      )
--      local pos2 = vec3(
--        center.x + horizontalRadius * math.cos(angle2),
--        center.y + horizontalRadius * math.sin(angle2),
--        z2
--      )

--      debugDrawer:drawCylinder(
--        adjustHeight(pos1, 0.1),
--        adjustHeight(pos2, 0.1),
--        0.1,
--        ColorF(clr[1], clr[2], clr[3], alpha)
--      )
--   end

--   return startAngle, endAngle
-- end

-- Draw 3D arc using square prisms with 1m height
local function drawCircleArcPrism(center, horizontalRadius, startPos, endPos, middlePos, clr, alpha)
  local segments = 32
  local startAngle = math.atan2(startPos.y - center.y, startPos.x - center.x)
  local endAngle = math.atan2(endPos.y - center.y, endPos.x - center.x)

  -- Determine direction of arc
  local cross = (middlePos - startPos):cross(endPos - startPos)
  local clockwise = cross.z < 0

  if clockwise then
    if endAngle > startAngle then
      endAngle = endAngle - 2 * math.pi
    end
  else
    if endAngle < startAngle then
      endAngle = endAngle + 2 * math.pi
    end
  end

  local angleStep = (endAngle - startAngle) / segments
  local prismWidth = 0.1 -- 0.1m width in cross-section
  local prismCrossHeight = 2.0 -- 2m height in cross-section
  local verticalHeight = 1.0 -- 1m vertical positioning height

  -- Draw rectangular prisms spanning between consecutive arc points
  for i = 0, segments - 1 do
     local angle1 = startAngle + i * angleStep
     local angle2 = startAngle + (i + 1) * angleStep

     local progress1 = i / segments
     local progress2 = (i + 1) / segments

     -- Interpolate Z coordinates based on actual road points
     local z1 = startPos.z + progress1 * (endPos.z - startPos.z)
     local z2 = startPos.z + progress2 * (endPos.z - startPos.z)

     local pos1 = vec3(
       center.x + horizontalRadius * math.cos(angle1),
       center.y + horizontalRadius * math.sin(angle1),
       z1
     )
     local pos2 = vec3(
       center.x + horizontalRadius * math.cos(angle2),
       center.y + horizontalRadius * math.sin(angle2),
       z2
     )

     -- Draw prism spanning from pos1 to pos2 directly at point positions
     debugDrawer:drawSquarePrism(
       pos1, -- First end point at arc point 1
       pos2, -- Second end point at arc point 2
       Point2F(prismCrossHeight, prismWidth), -- 2.0m x 0.1m cross-section
       Point2F(prismCrossHeight, prismWidth), -- 2.0m x 0.1m cross-section
       ColorF(clr[1], clr[2], clr[3], alpha),
       false,
       false
     )
  end

  return startAngle, endAngle
end

-- Draw arc length text at midpoint
local function drawArcLengthText(arcLength, midPoint, clr, alpha, diameter, prefix, fitQuality, arcDegrees)
  clr = clr or prismColor
  prefix = prefix or ""
  local arcLengthText = string.format("Length: %.0fm", arcLength)
  if diameter and fitQuality and arcDegrees then
    arcLengthText = string.format("%sLength: %.0fm | Diameter: %.0fm | Angle: %.0f° | Fit: %.3f", prefix, arcLength, diameter, arcDegrees, fitQuality)
  elseif diameter and arcDegrees then
    arcLengthText = string.format("%sLength: %.0fm | Diameter: %.0fm | Angle: %.0f°", prefix, arcLength, diameter, arcDegrees)
  elseif diameter and fitQuality then
    arcLengthText = string.format("%sLength: %.0fm | Diameter: %.0fm | Fit: %.3f", prefix, arcLength, diameter, fitQuality)
  elseif diameter then
    arcLengthText = string.format("%sLength: %.0fm | Diameter: %.0fm", prefix, arcLength, diameter)
  elseif fitQuality then
    arcLengthText = string.format("%sLength: %.0fm | Fit: %.3f", prefix, arcLength, fitQuality)
  else
    arcLengthText = string.format("%sLength: %.0fm", prefix, arcLength)
  end
  debugDrawer:drawTextAdvanced(
    vec3(midPoint.x, midPoint.y, midPoint.z),
    arcLengthText,
    ColorF(0, 0, 0, 1), -- black text
    true,
    false,
    getTextBackgroundColor(clr, alpha), -- use prism color for background
    false,
    false
  )
end


-- Draw radius lines using rectangular prisms with 2m height and 0.1m width cross-section
local function drawRadiusLinesPrism(center, startPos, endPos, horizontalRadius, diameter, clr, alpha)
  local prismWidth = 0.1 -- 0.1m width in cross-section
  local prismHeight = 2.0 -- 2m height in cross-section

  -- Draw single prism from center to startPos directly at point positions
  debugDrawer:drawSquarePrism(
    center, -- First end point at center
    startPos, -- Second end point at startPos
    Point2F(prismHeight, prismWidth), -- 2.0m x 0.1m cross-section
    Point2F(prismHeight, prismWidth), -- 2.0m x 0.1m cross-section
    ColorF(clr[1], clr[2], clr[3], alpha),
    false,
    false
  )

  -- Draw single prism from center to endPos directly at point positions
  debugDrawer:drawSquarePrism(
    center, -- First end point at center
    endPos, -- Second end point at endPos
    Point2F(prismHeight, prismWidth), -- 2.0m x 0.1m cross-section
    Point2F(prismHeight, prismWidth), -- 2.0m x 0.1m cross-section
    ColorF(clr[1], clr[2], clr[3], alpha),
    false,
    false
  )

  -- Draw radius text at center point
  -- local radiusText = string.format("Diameter: %.0fm", diameter)
  -- local textPos = vec3(center.x, center.y, center.z)

  -- debugDrawer:drawTextAdvanced(
  --   textPos,
  --   radiusText,
  --   ColorF(0, 0, 0, 1), -- black text
  --   true,
  --   false,
  --   getTextBackgroundColor(clr, alpha), -- use prism color for background
  --   false,
  --   false
  -- )
end

-- Draw pacenote measurements using minimal circle data and original points (always uses prisms)
function M.drawPacenoteMeasurement(center, radius, arcDistance, p1, p2, p3, clr, alpha, prefix, fitQuality, arcDegrees)
  clr = clr or prismColor
  alpha = alpha or prismAlpha
  prefix = prefix or ""

  if not center or radius <= 0 then
    -- No valid data, skip drawing
    return
  end

  -- Draw circle center
  -- debugDrawer:drawSphere(center, 2, ColorF(clr[1], clr[2], clr[3], alpha), false, false)

  -- Draw 3D arc using prisms
  local startAngle, endAngle = drawCircleArcPrism(center, radius, p1, p3, p2, clr, alpha)

  -- Calculate arc midpoint for text display
  local arcMidpoint = calculateArcMidpoint(center, radius, startAngle, endAngle, p1, p3)

  -- Draw radius lines using prisms
  local diameter = radius * 2
  drawRadiusLinesPrism(center, p1, p3, radius, diameter, clr, alpha)

  -- Draw arc length text at midpoint with diameter and fit quality
  drawArcLengthText(arcDistance, arcMidpoint, clr, alpha, diameter, prefix, fitQuality, arcDegrees)
end

function M.measurePartition(pn, focusPoints, skipAuto)
  local hasPoints = #focusPoints >= 3
  if not pn or not hasPoints then
    return
  end

  local startPos = vec3(pn:getCornerStartWaypoint().pos)
  local endPos = vec3(pn:getCornerEndWaypoint().pos)

  local middlePos = nil
  if pn.halfpointPos then
    middlePos = vec3(pn.halfpointPos)
  elseif pn.halfpoint then
    middlePos = vec3(pn.halfpoint.pos)
  else
    return
  end

  local pathPoints = buildMeasurementPathPoints(focusPoints, startPos, endPos)
  local singleFit = buildSingleFit(pathPoints, startPos, middlePos, endPos)
  local variants = buildMeasurementVariants(pathPoints, singleFit)

  pn.measurements.variants = variants
  pn.measurements.diagnostics = buildMeasurementDiagnostics(pathPoints, singleFit)

  -- Compatibility aliases. New projection/visualization code should prefer
  -- measurements.variants, but exports and debug tooling still read these names.
  pn.measurements.corner1 = variants.single
  pn.measurements.corner2 = nil
  pn.measurements.splitPoint = nil
  pn.measurements.splitPoints = nil
  pn.measurements.totalPointsLength = variants.single and variants.single.totalPointsLength or nil

  calculateAndStoreIntensityDirection(pn)

  local selectedType = normalizeMeasurementType(pn.corner and pn:corner() and pn:corner().measurementType or nil)
  local selectedMeasurement = variants[selectedType] or variants[defaultMeasurementType]
  pn.measurements.selectedType = selectedType
  pn.measurements.selected = selectedMeasurement
  pn.measurements.hairpinCandidate = selectedMeasurement and selectedMeasurement.hairpinCandidate or nil
end

M.calculateMiddlePoint = calculateMiddlePoint
M.calculateCircleFromPoints2 = calculateCircleFromPoints2
M.defaultMeasurementType = defaultMeasurementType
M.measurementTypes = measurementTypes
M.measurementTypeOrder = measurementTypeOrder
M.measurementTypeOptions = measurementTypeOptions
M.normalizeMeasurementType = normalizeMeasurementType

return M