-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local util = require('editor/toolUtilities/util')
local rdp = require('editor/toolUtilities/rdp')
local render = require('editor/toolUtilities/render')
local zSnap = require('/lua/ge/extensions/editor/rallyEditor/zSnap')
local SnaproadNormals = require('/lua/ge/extensions/gameplay/rally/snaproad/normals')
local DrivelineUtil = require('/lua/ge/extensions/gameplay/rally/driveline/util')
local PointList = require('/lua/ge/extensions/gameplay/rally/driveline/pointList')
local DrivelineRecording = require('/lua/ge/extensions/gameplay/rally/recce/drivelineRecording')
local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = 'drivelineV3'

local defaultSpeedLimitKph = 100
local defaultLiaisonAllocatedTimeMins = 5
local defaultUseRaycast = false
local defaultVertRayRaise = 2.0

local function splineId(id)
  if id then return id end
  if Engine and Engine.generateUUID then return Engine.generateUUID() end
  return nil
end

local function vecToArray(v)
  return {v.x, v.y, v.z}
end

local function vecFromData(data)
  if not data then return nil end
  if data.x then return vec3(data.x, data.y, data.z) end
  return vec3(data[1], data[2], data[3])
end

function C:init(missionDir)
  self.missionDir = missionDir

  -- Driveline editing state
  self.rawDrivelinePoints = nil  -- Original recorded points
  self.spline = nil              -- Editable spline
  self.finalDrivelinePoints = nil  -- Generated output

  -- Processing parameters
  self.simplificationTolerance = DrivelineUtil.defaultSimplificationTolerance

  -- Properties
  self.properties = {
    speedLimitKph = defaultSpeedLimitKph,
    liaisonAllocatedTimeMins = defaultLiaisonAllocatedTimeMins,
    useRaycast = defaultUseRaycast,
    vertRayRaise = defaultVertRayRaise
  }

  -- Stats (stored under the top-level "stats" key of the spline file). Free-form
  -- so it can be seeded manually and read programmatically. See drivelineTab refreshStats.
  self.stats = nil
end

function C:createEmptySpline(name, isLoop, id)
  return {
    name = name or "Driveline",
    id = splineId(id),
    isDirty = true,
    isEnabled = true,
    isLoop = isLoop or false,

    nodes = {},
    widths = {},
    nmls = {},

    divPoints = {},
    divWidths = {},
    tangents = {},
    binormals = {},
    normals = {},
    discMap = {},
  }
end

function C:loadPropertiesFromData(data)
  local properties = data and data.properties or nil
  local vertRayRaise = properties and tonumber(properties.vertRayRaise) or defaultVertRayRaise
  self.properties = {
    speedLimitKph = properties and properties.speedLimitKph or defaultSpeedLimitKph,
    liaisonAllocatedTimeMins = properties and properties.liaisonAllocatedTimeMins or defaultLiaisonAllocatedTimeMins,
    useRaycast = properties and properties.useRaycast == true or defaultUseRaycast,
    vertRayRaise = clamp(vertRayRaise, 0.1, 20.0)
  }
end

function C:serializeSpline()
  if not self.spline or not self.spline.nodes or #self.spline.nodes < 2 then return nil end

  local data = {
    version = 1,
    name = self.spline.name or "Driveline",
    isLoop = self.spline.isLoop or false,
    nodes = {},
    widths = {},
    nmls = {},
    properties = self.properties or {},
    stats = self.stats or nil,
  }

  for i, node in ipairs(self.spline.nodes) do
    data.nodes[i] = vecToArray(node)
    data.widths[i] = self.spline.widths and self.spline.widths[i] or DrivelineUtil.defaultSplineWidth
    data.nmls[i] = vecToArray((self.spline.nmls and self.spline.nmls[i]) or vec3(0, 0, 1))
  end

  return data
end

function C:loadSplineFromData(data)
  if not data or not data.nodes or #data.nodes < 2 then
    log('E', logTag, 'Cannot load spline: insufficient spline nodes')
    return false
  end

  local spline = self:createEmptySpline(data.name or "Driveline", data.isLoop, data.id)
  for i, nodeData in ipairs(data.nodes) do
    local node = vecFromData(nodeData)
    if not node then
      log('E', logTag, 'Cannot load spline: invalid node at index ' .. tostring(i))
      return false
    end

    spline.nodes[i] = node
    spline.widths[i] = data.widths and data.widths[i] or DrivelineUtil.defaultSplineWidth
    spline.nmls[i] = (data.nmls and vecFromData(data.nmls[i])) or vec3(0, 0, 1)
  end

  self.spline = spline
  self:loadPropertiesFromData(data)
  self.stats = data.stats
  return true
end

function C:saveSplineToFile()
  if not self.missionDir then
    log('E', logTag, 'Cannot save driveline spline: no mission directory set')
    return false
  end

  local outputData = self:serializeSpline()
  if not outputData then
    log('E', logTag, 'Cannot save driveline spline: no spline handles to save')
    return false
  end

  local outputFile = rallyUtil.drivelineSplineFile(self.missionDir)
  local outputDir = outputFile:match("(.*/)")
  if outputDir then
    FS:directoryCreate(outputDir, true)
  end

  local file = io.open(outputFile, "w")
  if not file then
    log('E', logTag, 'Failed to open file for writing: ' .. outputFile)
    return false
  end

  file:write(jsonEncode(outputData))
  file:close()

  log('I', logTag, 'Successfully saved driveline spline to: ' .. outputFile)
  return true
end

function C:loadDrivelineSplineFromFile()
  if not self.missionDir then
    log('E', logTag, 'Cannot load driveline spline: no mission directory set')
    return false
  end

  local splineFile = rallyUtil.drivelineSplineFile(self.missionDir)
  if not FS:fileExists(splineFile) then
    log('D', logTag, 'Driveline spline file not found: ' .. splineFile)
    return false
  end

  local data = jsonReadFile(splineFile)
  if not self:loadSplineFromData(data) then
    log('E', logTag, 'Invalid or empty driveline spline file: ' .. splineFile)
    return false
  end

  if not self:updateSplineGeometry() then
    log('E', logTag, 'Failed to update spline geometry from: ' .. splineFile)
    return false
  end

  if not self:createDrivelineFromSpline() then
    log('E', logTag, 'Failed to create final driveline from spline: ' .. splineFile)
    return false
  end

  log('I', logTag, 'Loaded driveline spline from: ' .. splineFile)
  return true
end

-- Load raw driveline recording from recce
function C:loadRecceRecording()
  if not self.missionDir then
    log('E', logTag, 'Cannot load driveline: no mission directory set')
    return false
  end

  -- Load driveline using the recording loader
  local pointList = DrivelineRecording.load(self.missionDir)
  if not pointList then
    log('E', logTag, 'Failed to load driveline from: ' .. self.missionDir)
    return false
  end

  self.rawDrivelinePoints = pointList:getAll()
  -- log('I', logTag, 'Loaded driveline with ' .. #self.rawDrivelinePoints .. ' points')
  return true
end

-- Load final driveline from JSON file
function C:loadFinalDrivelineFromFile()
  if not self.missionDir then
    log('E', logTag, 'Cannot load final driveline: no mission directory set')
    return false
  end

  local finalDrivelineFile = rallyUtil.finalDrivelineFile(self.missionDir)
  if not FS:fileExists(finalDrivelineFile) then
    log('E', logTag, 'Final driveline file not found: ' .. finalDrivelineFile)
    return false
  end

  local data = jsonReadFile(finalDrivelineFile)
  if not data or not data.points or #data.points < 2 then
    log('E', logTag, 'Invalid or empty final driveline file: ' .. finalDrivelineFile)
    return false
  end

  -- Convert xyz arrays to vec3 positions
  local positions = {}
  for i, xyz in ipairs(data.points) do
    table.insert(positions, vec3(xyz[1], xyz[2], xyz[3]))
  end

  -- Use shared helper to create full point structure
  self.finalDrivelinePoints = self:createDrivelinePointsFromPositions(positions)
  if not self.finalDrivelinePoints then
    log('E', logTag, 'Failed to create driveline points from file: ' .. finalDrivelineFile)
    return false
  end

  -- Load properties if present
  self:loadPropertiesFromData(data)

  log('I', logTag, 'Loaded final driveline with ' .. #self.finalDrivelinePoints .. ' points from: ' .. finalDrivelineFile)
  return true
end

function C:loadDrivelineFromFile()
  local splineFile = self.missionDir and rallyUtil.drivelineSplineFile(self.missionDir) or nil
  if splineFile and FS:fileExists(splineFile) then
    return self:loadDrivelineSplineFromFile()
  end

  local finalDrivelineFile = self.missionDir and rallyUtil.finalDrivelineFile(self.missionDir) or nil
  if not (finalDrivelineFile and FS:fileExists(finalDrivelineFile)) then
    return false
  end

  if not self:loadFinalDrivelineFromFile() then
    return false
  end

  local pointsWithNormals = {}
  for _, point in ipairs(self.finalDrivelinePoints) do
    table.insert(pointsWithNormals, {pos = point.pos, normal = point.normal})
  end

  if not self:convertDrivelineToSpline(pointsWithNormals) then
    log('E', logTag, 'Failed to convert legacy final driveline to spline')
    return false
  end

  if not self:updateSplineGeometry() then
    log('E', logTag, 'Failed to update legacy spline geometry')
    return false
  end

  if not self:createDrivelineFromSpline() then
    log('E', logTag, 'Failed to create final driveline from legacy spline')
    return false
  end

  log('I', logTag, 'Loaded legacy final driveline fallback from: ' .. finalDrivelineFile)
  return true
end

-- Complete loading pipeline: load raw recording → convert → process → generate final points
function C:loadFromRecording()
  -- Load raw driveline recording from recce
  if not self:loadRecceRecording() then
    return false
  end

  -- Convert to spline
  if not self:convertDrivelineToSpline() then
    log('E', logTag, 'Failed to convert driveline to spline')
    return false
  end

  -- Update spline geometry
  if not self:updateSplineGeometry() then
    log('E', logTag, 'Failed to update spline geometry')
    return false
  end

  -- Generate final driveline points
  if not self:createDrivelineFromSpline() then
    log('E', logTag, 'Failed to create final driveline')
    return false
  end

  -- log('I', logTag, 'Successfully loaded and processed driveline')
  return true
end

-- Convert driveline points to spline structure with RDP simplification
function C:convertDrivelineToSpline(drivelinePoints)
  -- Use provided points or fall back to loaded points
  local points = drivelinePoints or self.rawDrivelinePoints

  if not points or #points < 2 then
    log('E', logTag, 'Cannot convert to spline: insufficient driveline points')
    return false
  end

  -- Store raw driveline points if not already stored
  if drivelinePoints then
    self.rawDrivelinePoints = drivelinePoints
  end

  self.spline = self:createEmptySpline("Rally Driveline")
  self.spline.isDirty = false

  local originalPointCount = #points

  -- Extract positions, widths, and normals into temporary arrays for simplification
  local tempNodes = {}
  local tempWidths = {}
  local tempNormals = {}
  for i, point in ipairs(points) do
    tempNodes[i] = vec3(point.pos)
    tempWidths[i] = DrivelineUtil.defaultSplineWidth
    tempNormals[i] = point.normal or vec3(0, 0, 1)
  end

  -- Simplify using RDP algorithm to reduce node count
  rdp.simplifyNodesWidthsNormals(tempNodes, tempWidths, tempNormals, self.simplificationTolerance)

  -- Convert simplified nodes to spline - force all widths to be constant
  for i = 1, #tempNodes do
    self.spline.nodes[i] = tempNodes[i]
    self.spline.widths[i] = DrivelineUtil.defaultSplineWidth  -- Force constant width
    self.spline.nmls[i] = tempNormals[i]
  end

  local simplifiedCount = #self.spline.nodes
  local reductionPercent = 100.0 * (1.0 - simplifiedCount / originalPointCount)
  log('I', logTag, string.format('Simplified %d driveline points to %d spline nodes (%.1f%% reduction)',
      originalPointCount, simplifiedCount, reductionPercent))

  return true
end

-- Update spline geometry (compute smooth curve, terrain conformance)
function C:updateSplineGeometry()
  if not self.spline then
    return false
  end

  if #self.spline.nodes < 2 then
    log('W', logTag, 'Not enough nodes to compute spline geometry')
    return false
  end

  -- Clear secondary geometry
  table.clear(self.spline.divPoints)
  table.clear(self.spline.divWidths)
  table.clear(self.spline.tangents)
  table.clear(self.spline.binormals)
  table.clear(self.spline.normals)
  table.clear(self.spline.discMap)

  -- Compute smooth spline geometry (conforms to terrain)
  zSnap.conformSplineGeometry(
    self.spline,
    self.properties and self.properties.useRaycast,
    DrivelineUtil.minSplineDivisions,
    DrivelineUtil.minSplineSpacing,
    self.properties and self.properties.vertRayRaise
  )

  -- Calculate road length from subdivided points
  self.spline.roadLength = util.getPolyLength(self.spline.divPoints)

  self.spline.isDirty = false
  return true
end

-- Helper: Convert array of positions to full driveline point structure
function C:createDrivelinePointsFromPositions(positions)
  if not positions or #positions < 2 then
    return nil
  end

  local points = {}

  -- Convert positions to driveline point format
  for i = 1, #positions do
    local pos = vec3(positions[i])

    -- Calculate direction quaternion
    local dir
    if i < #positions then
      dir = (vec3(positions[i + 1]) - pos):normalized()
    else
      dir = (pos - vec3(positions[i - 1])):normalized()
    end

    -- Create quaternion from forward direction
    local up = vec3(0, 0, 1)
    local right = dir:cross(up):normalized()
    local actualUp = right:cross(dir):normalized()
    local quat = quatFromDir(dir, actualUp)

    -- Create point with timestamp
    local point = {
      pos = pos,
      quat = quat,
      ts = i / 5.0,  -- Simulate 5 Hz recording rate
    }

    table.insert(points, point)
  end

  -- Set up prev/next relationships
  for i, point in ipairs(points) do
    point.id = i
    if i > 1 then
      point.prev = points[i - 1]
    end
    if i < #points then
      point.next = points[i + 1]
    end
  end

  -- Calculate normals and add pacenote fields
  for i, point in ipairs(points) do
    point.normal = SnaproadNormals.forwardNormalVec(point)
    point.pacenoteDistances = {}
    point.cachedPacenotes = {
      cs = nil,
      ce = nil,
      at = nil,
      auto_at = nil,
      half = nil,
    }
  end

  return points
end

-- Create a new driveline from the edited spline
function C:createDrivelineFromSpline()
  if not self.spline or not self.spline.divPoints or #self.spline.divPoints < 2 then
    log('W', logTag, 'Cannot create driveline: spline not ready')
    self.finalDrivelinePoints = nil
    return false
  end

  self.finalDrivelinePoints = self:createDrivelinePointsFromPositions(self.spline.divPoints)
  return self.finalDrivelinePoints ~= nil
end

-- Get a PointList from the final points
function C:getFinalPointList()
  if not self.finalDrivelinePoints or #self.finalDrivelinePoints < 2 then
    log('W', logTag, 'Cannot create PointList: no final points generated')
    return nil
  end

  return PointList(self.finalDrivelinePoints)
end

-- Deep copy function for undo/redo
function C:deepCopySpline()
  if not self.spline then return nil end

  local copy = {
    name = self.spline.name,
    id = self.spline.id,
    isDirty = self.spline.isDirty,
    isEnabled = self.spline.isEnabled,
    isLoop = self.spline.isLoop,
    roadLength = self.spline.roadLength,
    nodes = {},
    widths = {},
    nmls = {},
  }

  -- Copy nodes
  for i = 1, #self.spline.nodes do
    copy.nodes[i] = vec3(self.spline.nodes[i])
  end

  -- Copy widths
  for i = 1, #self.spline.widths do
    copy.widths[i] = self.spline.widths[i]
  end

  -- Copy normals
  for i = 1, #self.spline.nmls do
    copy.nmls[i] = vec3(self.spline.nmls[i])
  end

  return copy
end

-- Render raw driveline points
function C:renderRawDriveline()
  if not self.rawDrivelinePoints or #self.rawDrivelinePoints < 2 then
    return
  end

  -- Draw raw driveline as thin purpley pink cylinder
  local clr = ColorF(1.0, 0.3, 0.8, 0.8)  -- Purpley pink, opaque
  local radius = 0.15  -- Thin cylinder
  local pinHeight = 1.0  -- Height of vertical pins

  -- Draw line segments between points
  for i = 1, #self.rawDrivelinePoints - 1 do
    local p1 = self.rawDrivelinePoints[i].pos
    local p2 = self.rawDrivelinePoints[i + 1].pos
    debugDrawer:drawCylinder(p1, p2, radius, clr)
  end

  -- Draw vertical pins at each point
  for i = 1, #self.rawDrivelinePoints do
    local pos = self.rawDrivelinePoints[i].pos
    local pinTop = vec3(pos.x, pos.y, pos.z + pinHeight)
    debugDrawer:drawCylinder(pos, pinTop, radius * 0.7, clr)
  end
end

-- Render smooth spline curve
function C:renderSmoothCurve(lineWidth)
  if not self.spline or not self.spline.divPoints or #self.spline.divPoints < 2 then
    return
  end

  -- Draw smooth secondary geometry as a vehicle-width prism.
  local clr = ColorF(0.0, 0.5, 1.0, 0.5)  -- Light blue
  local lineHeight = 0.5
  lineWidth = tonumber(lineWidth) or 1.945

  for i = 1, #self.spline.divPoints - 1 do
    local p1 = self.spline.divPoints[i]
    local p2 = self.spline.divPoints[i + 1]
    debugDrawer:drawSquarePrism(
      p1,
      p2,
      Point2F(lineHeight, lineWidth),
      Point2F(lineHeight, lineWidth),
      clr
    )
  end
end

-- Render final driveline points
function C:renderFinalDriveline()
  if not self.finalDrivelinePoints or #self.finalDrivelinePoints < 2 then
    return
  end

  -- Draw final driveline as red cylinders with pins
  local clr = ColorF(1.0, 0.0, 0.0, 0.6)  -- Red, semi-transparent
  local radius = 0.18  -- Medium thickness
  local pinHeight = 1.2  -- Slightly taller pins

  -- Draw line segments between points
  for i = 1, #self.finalDrivelinePoints - 1 do
    local p1 = self.finalDrivelinePoints[i].pos
    local p2 = self.finalDrivelinePoints[i + 1].pos
    debugDrawer:drawCylinder(p1, p2, radius, clr)
  end

  -- Draw vertical pins at each point
  for i = 1, #self.finalDrivelinePoints do
    local pos = self.finalDrivelinePoints[i].pos
    local pinTop = vec3(pos.x, pos.y, pos.z + pinHeight)
    debugDrawer:drawCylinder(pos, pinTop, radius * 0.7, clr)
  end
end

-- Render editable spline with nodes
function C:renderSpline(selectedNodeIdx)
  if not self.spline or #self.spline.nodes == 0 then
    return
  end

  -- Render full spline if we have enough nodes
  if #self.spline.nodes >= 2 then
    -- Render the spline using the render utility (nodes only)
    render.handleSplineRendering(
      {self.spline},           -- splines array
      1,                       -- selectedSplineIdx
      selectedNodeIdx,         -- selectedNodeIdx (passed as parameter)
      false,                   -- isGizmoActive
      false,                   -- isRenderVerts
      false,                   -- isLockShape
      false,                   -- showVelocities
      true,                    -- showSpline
      0                        -- elevScale
    )

    -- Render start and end markers
    render.markupStart(self.spline.nodes[1])
    if not self.spline.isLoop then
      render.markupEnd(self.spline.nodes[#self.spline.nodes])
    end
  else
    -- For single node, just render it directly
    local node = self.spline.nodes[1]
    if selectedNodeIdx == 1 then
      render.drawSphereHighlightSelected(node)
    else
      render.drawSphereNode(node)
    end
    render.markupStart(node)
  end
end

function C:getSpeedLimitKph()
  return self.properties.speedLimitKph
end

function C:getLiaisonAllocatedTimeSecs()
  return self.properties.liaisonAllocatedTimeMins * 60
end

-- Projects p1 and p2 onto the final driveline segments and returns the ordered
-- segment range covering the span between them:
--   startIdx, startXnorm, endIdx, endXnorm (startIdx/startXnorm always come first)
-- Returns nil if the range cannot be resolved.
function C:_findSegmentRange(p1, p2)
  if not self.finalDrivelinePoints or #self.finalDrivelinePoints < 2 then
    return nil
  end

  -- Find which segments contain p1 and p2 (closest projection)
  local p1SegIdx, p1Xnorm = nil, nil
  local p2SegIdx, p2Xnorm = nil, nil
  local minP1Dist = math.huge
  local minP2Dist = math.huge

  for i = 1, #self.finalDrivelinePoints - 1 do
    local segStart = self.finalDrivelinePoints[i].pos
    local segEnd = self.finalDrivelinePoints[i + 1].pos

    -- Check p1
    local xnorm1 = p1:xnormOnLine(segStart, segEnd)
    local projectedP1 = segStart + (segEnd - segStart) * xnorm1
    local dist1 = p1:distance(projectedP1)
    if dist1 < minP1Dist then
      minP1Dist = dist1
      p1SegIdx = i
      p1Xnorm = xnorm1
    end

    -- Check p2
    local xnorm2 = p2:xnormOnLine(segStart, segEnd)
    local projectedP2 = segStart + (segEnd - segStart) * xnorm2
    local dist2 = p2:distance(projectedP2)
    if dist2 < minP2Dist then
      minP2Dist = dist2
      p2SegIdx = i
      p2Xnorm = xnorm2
    end
  end

  if not p1SegIdx or not p2SegIdx then
    return nil
  end

  -- Make sure p1 comes before p2
  if p1SegIdx > p2SegIdx or (p1SegIdx == p2SegIdx and p1Xnorm > p2Xnorm) then
    p1SegIdx, p2SegIdx = p2SegIdx, p1SegIdx
    p1Xnorm, p2Xnorm = p2Xnorm, p1Xnorm
  end

  return p1SegIdx, p1Xnorm, p2SegIdx, p2Xnorm
end

-- Returns the ordered list of finalDrivelinePoints covering the span between p1
-- and p2 (inclusive of the segment endpoints), or nil if it can't be resolved.
function C:getPointsBetween(p1, p2)
  local startIdx, _, endIdx, _ = self:_findSegmentRange(p1, p2)
  if not startIdx then return nil end

  local pts = {}
  for i = startIdx, math.min(endIdx + 1, #self.finalDrivelinePoints) do
    pts[#pts + 1] = self.finalDrivelinePoints[i]
  end
  return pts
end

function C:calculateDistanceBetweenPoints(p1, p2)
  -- calculate distance along the final points, using xnorm to calculate the partial start and end segments.
  local p1SegIdx, p1Xnorm, p2SegIdx, p2Xnorm = self:_findSegmentRange(p1, p2)
  if not p1SegIdx then
    return 0
  end

  local totalDist = 0

  -- Same segment
  if p1SegIdx == p2SegIdx then
    local segStart = self.finalDrivelinePoints[p1SegIdx].pos
    local segEnd = self.finalDrivelinePoints[p1SegIdx + 1].pos
    local segLength = segStart:distance(segEnd)
    totalDist = segLength * (p2Xnorm - p1Xnorm)
  else
    -- Partial distance from p1 to end of its segment
    local p1SegStart = self.finalDrivelinePoints[p1SegIdx].pos
    local p1SegEnd = self.finalDrivelinePoints[p1SegIdx + 1].pos
    local p1SegLength = p1SegStart:distance(p1SegEnd)
    totalDist = totalDist + p1SegLength * (1.0 - p1Xnorm)

    -- Full distance for segments in between
    for i = p1SegIdx + 1, p2SegIdx - 1 do
      local segStart = self.finalDrivelinePoints[i].pos
      local segEnd = self.finalDrivelinePoints[i + 1].pos
      totalDist = totalDist + segStart:distance(segEnd)
    end

    -- Partial distance from start of p2's segment to p2
    local p2SegStart = self.finalDrivelinePoints[p2SegIdx].pos
    local p2SegEnd = self.finalDrivelinePoints[p2SegIdx + 1].pos
    local p2SegLength = p2SegStart:distance(p2SegEnd)
    totalDist = totalDist + p2SegLength * p2Xnorm
  end

  return totalDist
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
