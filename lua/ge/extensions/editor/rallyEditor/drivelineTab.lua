-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local logTag = 'drivelineTab'
-- local simplifyRdpTol = 9.0  -- Default tolerance for spline simplification (in meters)
local simplifyRdpTol = 4.0  -- Default tolerance for spline simplification (in meters)

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local DrivelineV3 = require('/lua/ge/extensions/gameplay/rally/driveline/drivelineV3')
local drivelineUtil = require('/lua/ge/extensions/gameplay/rally/driveline/util')
local DrivelineEditSurface = require('/lua/ge/extensions/editor/rallyEditor/drivelineEditSurface')

-- Distance between surface probe samples along the race span (meters)
local surfaceProbeStep = 5.0

-- Authoritative groundmodel -> surface category map, derived from
-- art/groundmodels.json (canonical groundmodel names plus their aliases, since
-- terrain materials often store an alias name, e.g. DIRT_LOOSE -> GRAVEL). Keys
-- are upper-cased. Groundmodels that are not a drivable rally surface (metal,
-- wood, plastic, foliage, void, etc.) are intentionally left out -> "other".
local groundModelCategories = {}
local function registerGroundModels(category, names)
  for _, n in ipairs(names) do
    groundModelCategories[string.upper(n)] = category
  end
end
registerGroundModels('tarmac', {
  'ASPHALT', 'groundmodel_asphalt1', 'grid', 'concrete', 'concrete2',
  'ASPHALT_WET', 'asphalt_wet2', 'asphalt_wet3',
  'ASPHALT_OLD', 'groundmodel_asphalt_old',
  'ASPHALT_PREPPED', 'RUMBLE_STRIP', 'COBBLESTONE', 'SLIPPERY', 'KICKPLATE',
})
registerGroundModels('gravel', {
  'DIRT', 'dirt_grass', 'derby_dirt',
  'DIRT_DUSTY', 'rockydirt', 'dirt_rocky', 'dirt_rocky_large',
  'DIRT_DUSTY_LOOSE', 'dirt_loose_dusty', 'dirt_sandy',
  'GRAVEL', 'dirt_loose',
  'GRAVEL_WET', 'gravel_wet', 'gravel_riverbed',
  'MUD',
  'SAND', 'beachsand', 'sandtrap',
})
registerGroundModels('ice', { 'ICE', 'FRICTIONLESS' })
registerGroundModels('snow', { 'SNOW' })
-- rock and grass are "incidental" surfaces (bridges over rocky riverbeds, the
-- driveline slightly clipping a road edge onto grass). They are tracked
-- separately and rolled into the dominant surface at aggregation time.
registerGroundModels('rock', { 'ROCK', 'rock_cliff', 'rocks_large' })
registerGroundModels('grass', { 'GRASS', 'grass', 'grass2', 'grass3', 'grass4', 'forest', 'forest_floor' })

local function surfaceCategoryForGroundModel(gmName)
  if not gmName or gmName == '' then return 'other' end
  return groundModelCategories[string.upper(gmName)] or 'other'
end

local C = {}
C.windowDescription = 'Driveline Editor'

function C:init(rallyEditor)
  self.path = nil
  self.rallyEditor = rallyEditor
  self.drivelineLoaded = false
  self.loadError = nil
  self.loadMode = nil  -- 'recording' or 'final'

  -- Driveline V3 processor (created when path is set)
  self.drivelineV3 = nil

  -- UI state only
  self.isSplineView = true
  self.showRawPoints = false
  self.showFinalDrivelineVisualization = false
  self.selectedNodeIdx = 1

  -- Interactive editing state
  self.dragState = nil
  self.deletePressed = false

  -- Race distance calculation
  self.calculatedRaceDistance = nil
  self.drivelineStats = {
    pointCount = 0,
    length = 0
  }

  -- Buffer zone state (experimental)
  self.bufferEnabled = false
  self.bufferPoints = nil  -- Array of vec3 positions for buffer circles
  self.bufferRadius = 10.0  -- Fixed 10 meters
  self.bufferBounds = nil  -- {min = vec3, max = vec3} for optimization
end

function C:clearState()
  self.path = nil
  self.drivelineLoaded = false
  self.loadError = nil
  self.loadMode = nil
  self.drivelineV3 = nil
  self.isSplineView = true
  self.showRawPoints = false
  self.showFinalDrivelineVisualization = false
  self.selectedNodeIdx = 1
  self.dragState = nil
  self.deletePressed = false
  self.calculatedRaceDistance = nil
  self.drivelineStats = {
    pointCount = 0,
    length = 0
  }
  self.bufferEnabled = false
  self.bufferPoints = nil
  self.bufferRadius = 10.0
  self.bufferBounds = nil
end

function C:setPath(path)
  -- Check if we're switching to a different mission
  local switchingMission = false
  if self.path and path then
    local oldMissionDir = self.path:getMissionDir()
    local newMissionDir = path:getMissionDir()
    if oldMissionDir ~= newMissionDir then
      switchingMission = true
    end
  end

  self.path = path

  -- If switching missions, reset state
  if switchingMission then
    self.drivelineLoaded = false
    self.loadMode = nil
    self.drivelineV3 = nil
    self.bufferEnabled = false
    self.bufferPoints = nil
    self.bufferBounds = nil
    self.calculatedRaceDistance = nil
    self.drivelineStats = {
      pointCount = 0,
      length = 0
    }
  end

  -- Create DrivelineV3 instance with mission directory (only if not already created)
  if self.path and not self.drivelineV3 then
    local missionDir = self.path:getMissionDir()
    self.drivelineV3 = DrivelineV3(missionDir)

    -- Auto-load existing final driveline if available
    if self:hasFinalDriveline() and not self.drivelineLoaded then
      self:loadFromFinal()
    end
  end
end

function C:splineEditCallbacks()
  return {
    onCommit = function(host)
      host:recalculateRaceDistance()
    end,
    onHistoryRestore = function(host)
      host:recalculateRaceDistance()
    end
  }
end

-- called by RallyEditor when this tab is selected.
function C:selected()
  if not self.path then return end
  -- force redraw of shortcutLegend window
  extensions.hook("onEditorEditModeChanged", nil, nil)
end

-- called by RallyEditor when this tab is unselected.
function C:unselect()
  if not self.path then return end
  -- force redraw of shortcutLegend window
  extensions.hook("onEditorEditModeChanged", nil, nil)
end

function C:formatDistance(dist)
  if not dist or dist == 0 then
    return "0m"
  end

  local unit = 'm'
  if dist > 950 then
    dist = dist / 1000.0
    unit = 'km'
  end
  local dist_str = string.format("%.3f"..unit, dist)
  return dist_str
end

function C:getFinalDrivelineLength()
  if not self.drivelineV3 or not self.drivelineV3.finalDrivelinePoints then
    return 0
  end

  local length = 0
  for i = 1, #self.drivelineV3.finalDrivelinePoints - 1 do
    length = length + self.drivelineV3.finalDrivelinePoints[i].pos:distance(self.drivelineV3.finalDrivelinePoints[i + 1].pos)
  end
  return length
end

function C:formatDurationSecs(timeSecs)
  if not timeSecs or timeSecs <= 0 then
    return "N/A"
  end

  local totalTenths = math.floor(timeSecs * 10 + 0.5)
  local minutes = math.floor(totalTenths / 600)
  local secondsTenths = totalTenths - (minutes * 600)
  local seconds = math.floor(secondsTenths / 10)
  local tenths = secondsTenths % 10
  return string.format("%02d:%02d.%d", minutes, seconds, tenths)
end

function C:getMissionSilverTimeSecs()
  if not self.path then return nil end

  local missionDir = self.path:getMissionDir()
  if not missionDir then return nil end

  local info = jsonReadFile(missionDir..'/info.json')
  local silverTime = info and info.missionTypeData and info.missionTypeData.silverTime or nil
  if type(silverTime) == 'number' and silverTime > 0 then
    return silverTime
  end
  return nil
end

-- Check if recording driveline exists
function C:hasRecording()
  if not self.path then return false end
  local missionDir = self.path:getMissionDir()
  if not missionDir then return false end
  local drivelineFile = rallyUtil.drivelineFile(missionDir)
  return FS:fileExists(drivelineFile)
end

-- Check if final driveline exists
function C:hasFinalDriveline()
  if not self.path then return false end
  local missionDir = self.path:getMissionDir()
  if not missionDir then return false end
  local splineFile = rallyUtil.drivelineSplineFile(missionDir)
  if FS:fileExists(splineFile) then return true end
  local finalFile = rallyUtil.finalDrivelineFile(missionDir)
  return FS:fileExists(finalFile)
end

-- Load from recording (raw driveline)
function C:loadFromRecording()
  if not self.path then
    self.loadError = "No path/notebook loaded"
    return false
  end

  if not self.drivelineV3 then
    self.loadError = "DrivelineV3 not initialized"
    return false
  end

  -- Use DrivelineV3 to load and process the driveline from recording
  if self.drivelineV3:loadFromRecording() then
    self.drivelineLoaded = true
    self.loadMode = 'recording'
    self.loadError = nil
    self.isSplineView = true  -- Ensure spline view is enabled
    self:recalculateRaceDistance()
    log('I', logTag, 'Successfully loaded driveline from recording')
    return true
  else
    self.drivelineLoaded = false
    self.loadMode = nil
    self.loadError = "Failed to load driveline recording"
    log('E', logTag, 'Failed to load driveline from recording')
    return false
  end
end

-- Load from final driveline
function C:loadFromFinal()
  if not self.path then
    self.loadError = "No path/notebook loaded"
    return false
  end

  if not self.drivelineV3 then
    self.loadError = "DrivelineV3 not initialized"
    return false
  end

  -- Check if final driveline exists
  local hasFinal = self:hasFinalDriveline()

  if hasFinal then
    if not self.drivelineV3:loadDrivelineFromFile() then
      self.drivelineLoaded = false
      self.loadMode = nil
      self.loadError = "Failed to load saved driveline"
      log('E', logTag, 'Failed to load saved driveline')
      return false
    end

    log('I', logTag, 'Successfully loaded saved driveline')
  else
    log('I', logTag, 'No saved driveline found - creating blank spline')

    self.drivelineV3.spline = self.drivelineV3:createEmptySpline("Driveline")

    -- Initialize empty final driveline points
    self.drivelineV3.finalDrivelinePoints = {}

    -- Initialize properties
    self.drivelineV3.properties = self.drivelineV3.properties or {}
    if not self.drivelineV3.properties.speedLimitKph then
      self.drivelineV3.properties.speedLimitKph = 100
    end
    if not self.drivelineV3.properties.liaisonAllocatedTimeMins then
      self.drivelineV3.properties.liaisonAllocatedTimeMins = 5
    end
  end

  self.drivelineLoaded = true
  self.loadMode = 'final'
  self.loadError = nil
  self.isSplineView = true  -- Ensure spline view is enabled
  self:recalculateRaceDistance()
  return true
end

-- Load from race path
function C:loadFromRace()
  if not self.path then
    self.loadError = "No path/notebook loaded"
    return false
  end

  if not self.drivelineV3 then
    self.loadError = "DrivelineV3 not initialized"
    return false
  end

  local missionDir = self.path:getMissionDir()
  if not missionDir then
    self.loadError = "No mission directory"
    return false
  end

  -- Load the race path
  local racePath, err = rallyUtil.loadRacePath(missionDir)
  if not racePath then
    self.loadError = err or "Failed to load race path"
    log('E', logTag, 'Failed to load race path: ' .. tostring(err))
    return false
  end

  -- Hardcoded option: use AI detailed path points or pathnode points
  -- local useAiDetailedPath = false  -- Default to pathnode points
  local useAiDetailedPath = true  -- Default to AI detailed path points

  local pointsToUse = {}

  if useAiDetailedPath then
    -- Get AI path from race
    racePath:autoConfig()
    local aiPath, aiDetailedPath = racePath:getAiPath(true)
    if not aiDetailedPath or #aiDetailedPath == 0 then
      self.loadError = "Race has no AI path"
      log('E', logTag, 'Race has no AI path')
      return false
    end
    pointsToUse = aiDetailedPath
    log('I', logTag, 'Creating driveline from race using AI detailed path with ' .. #pointsToUse .. ' points')
  else
    -- Use pathnode points
    if not racePath.pathnodes or not racePath.pathnodes.sorted or #racePath.pathnodes.sorted == 0 then
      self.loadError = "Race has no pathnodes"
      log('E', logTag, 'Race has no pathnodes')
      return false
    end
    pointsToUse = racePath.pathnodes.sorted
    log('I', logTag, 'Creating driveline from race using pathnodes with ' .. #pointsToUse .. ' points')
  end

  -- Initialize empty spline structure with all required fields
  self.drivelineV3.spline = {
    nodes = {},
    widths = {},
    nmls = {},
    divPoints = {},
    divWidths = {},
    tangents = {},
    binormals = {},
    normals = {},
    discMap = {},
    isEnabled = true,
    isLoop = false,
    isDirty = true,
    name = "Driveline"
  }

  -- Convert points to spline nodes
  for i, pathPoint in ipairs(pointsToUse) do
    table.insert(self.drivelineV3.spline.nodes, vec3(pathPoint.pos))
    table.insert(self.drivelineV3.spline.widths, drivelineUtil.defaultSplineWidth)
    table.insert(self.drivelineV3.spline.nmls, vec3(0, 0, 1))
  end

  -- Update spline geometry
  if not self.drivelineV3:updateSplineGeometry() then
    self.drivelineLoaded = false
    self.loadMode = nil
    self.loadError = "Failed to update spline geometry"
    log('E', logTag, 'Failed to update spline geometry')
    return false
  end

  -- Initialize empty final driveline points (will be generated from spline)
  self.drivelineV3.finalDrivelinePoints = {}

  -- Initialize properties
  self.drivelineV3.properties = self.drivelineV3.properties or {}
  if not self.drivelineV3.properties.speedLimitKph then
    self.drivelineV3.properties.speedLimitKph = 100
  end
  if not self.drivelineV3.properties.liaisonAllocatedTimeMins then
    self.drivelineV3.properties.liaisonAllocatedTimeMins = 5
  end

  self.drivelineLoaded = true
  self.loadMode = 'race'
  self.loadError = nil
  self.isSplineView = true  -- Ensure spline view is enabled
  self:recalculateRaceDistance()
  log('I', logTag, 'Successfully loaded driveline from race')
  return true
end

function C:getDrivelineLength()
  if not self.drivelineLoaded or not self.drivelineV3 then
    return 0
  end

  -- Only available in recording mode
  if self.loadMode == 'recording' and self.drivelineV3.rawDrivelinePoints then
    local length = 0
    for i = 1, #self.drivelineV3.rawDrivelinePoints - 1 do
      local p1 = self.drivelineV3.rawDrivelinePoints[i].pos
      local p2 = self.drivelineV3.rawDrivelinePoints[i + 1].pos
      length = length + p1:distance(p2)
    end
    return length
  end

  return 0
end

function C:getDrivelinePointCount()
  if not self.drivelineLoaded or not self.drivelineV3 then
    return 0
  end

  -- Only available in recording mode
  if self.loadMode == 'recording' and self.drivelineV3.rawDrivelinePoints then
    return #self.drivelineV3.rawDrivelinePoints
  end

  return 0
end

function C:updateSplineGeometry()
  local ok = self.drivelineV3:updateSplineGeometry()
  if ok then
    self:recalculateRaceDistance()
  end
  return ok
end

-- Deep copy function for undo/redo
function C:deepCopySpline()
  return self.drivelineV3:deepCopySpline()
end

-- Undo callback
function C:undoSplineEdit(data)
  DrivelineEditSurface.undoSplineEdit(self, data)
  self:recalculateRaceDistance()
end

-- Redo callback
function C:redoSplineEdit(data)
  DrivelineEditSurface.redoSplineEdit(self, data)
  self:recalculateRaceDistance()
end

-- Create a new driveline from the edited spline
function C:createDrivelineFromSpline()
  local ok = self.drivelineV3:createDrivelineFromSpline()
  if ok then
    self:recalculateRaceDistance()
  end
  return ok
end

function C:resetDrivelineStats()
  self.drivelineStats = {
    pointCount = 0,
    length = 0
  }
end

function C:recalculateDrivelineStats()
  local pointCount = 0
  if self.drivelineV3 and self.drivelineV3.finalDrivelinePoints then
    pointCount = #self.drivelineV3.finalDrivelinePoints
  end

  self.drivelineStats = {
    pointCount = pointCount,
    length = self:getFinalDrivelineLength()
  }

  return self.drivelineStats
end

function C:recalculateRaceDistance()
  if not self.drivelineLoaded or not self.drivelineV3 then
    self.calculatedRaceDistance = nil
    self:resetDrivelineStats()
    return nil
  end

  if self.drivelineV3.spline and self.drivelineV3.spline.divPoints and #self.drivelineV3.spline.divPoints > 0 then
    self.drivelineV3:createDrivelineFromSpline()
  end

  self:recalculateDrivelineStats()
  return self:calculateRaceDistance()
end

-- Create a temporary rally manager with our current (possibly unsaved) drivelineV3
-- so we can query race path / distance against the in-editor geometry.
function C:createTempRallyManager()
  if not self.path then
    log('E', logTag, 'Cannot create rally manager: no path loaded')
    return nil
  end

  local missionDir = self.path:getMissionDir()
  local missionId = self.path:getMissionId()
  if not missionDir or not missionId then
    log('E', logTag, 'Cannot create rally manager: no mission directory or id')
    return nil
  end

  local RallyManager = require('/lua/ge/extensions/gameplay/rally/rallyManager')
  local tempRallyManager = RallyManager(missionDir, missionId)

  if not tempRallyManager:rebuildAssets() then
    log('W', logTag, 'Could not rebuild rally manager assets')
    return nil
  end

  -- Override with our current drivelineV3 (which may have unsaved edits)
  tempRallyManager.drivelineV3 = self.drivelineV3
  return tempRallyManager
end

function C:calculateRaceDistance()
  local tempRallyManager = self:createTempRallyManager()
  if not tempRallyManager then
    self.calculatedRaceDistance = false
    return nil
  end

  local distance = tempRallyManager:getRaceDistanceMeters()

  if distance then
    self.calculatedRaceDistance = distance
    log('I', logTag, string.format('Calculated race distance: %.2fm', distance))
    return distance
  else
    self.calculatedRaceDistance = false
    log('W', logTag, 'Could not calculate race distance (start/finish positions may not be defined)')
  end
  return nil
end

function C:setAverageSpeedFromSilverTimeAndRaceDistance()
  local silverTimeSecs = self:getMissionSilverTimeSecs()
  if not silverTimeSecs then
    log('W', logTag, 'Cannot set average speed: mission silver time not available')
    return false
  end

  local distance = self.calculatedRaceDistance
  if not distance then
    log('W', logTag, 'Cannot set average speed: race distance not available')
    return false
  end

  local distanceKm = distance / 1000
  local timeHours = silverTimeSecs / 3600
  local speedKph = distanceKm / timeHours
  self.drivelineV3.properties.speedLimitKph = math.max(0, speedKph)
  log('I', logTag, string.format('Set average speed from silver time: %.2fkph', speedKph))
  return true
end

-- Probe the terrain groundmodel along the race span (start line -> flying finish)
-- and return a map of category -> percentage (float, 1 decimal), only including
-- categories with a non-zero share. Returns nil if it can't be computed.
function C:computeSurfacePercentages(startPos, finishPos)
  if not self.drivelineV3 then return nil end

  local pts = self.drivelineV3:getPointsBetween(startPos, finishPos)
  if not pts or #pts < 2 then return nil end

  local terrain = core_terrain and core_terrain.getTerrain and core_terrain.getTerrain()
  if not terrain then
    log('W', logTag, 'Cannot probe surface: no terrain found')
    return nil
  end

  -- Debug: dump every terrain material and how it maps, independent of sampling.
  local matCount = terrain.getMaterialCount and terrain:getMaterialCount() or nil
  log('I', logTag, string.format('[surfaceProbe] terrain material count=%s', tostring(matCount)))
  if matCount then
    for i = 0, matCount - 1 do
      local mtl = terrain:getMaterial(i)
      local gm = mtl and mtl.getGroundmodelName and mtl:getGroundmodelName() or nil
      local internal = mtl and mtl.getInternalName and mtl:getInternalName() or nil
      local matName = terrain.getMaterialName and terrain:getMaterialName(i) or nil
      log('I', logTag, string.format('[surfaceProbe]   material[%d] gm=%q internal=%q matName=%q',
        i, tostring(gm), tostring(internal), tostring(matName)))
    end
  end

  -- Resolve each terrain material index to a category only once.
  -- matDebug[matIdx] = { gm=<groundmodelName>, internal=<internalName>, resolved=<name used>, category=<cat>, count=n }
  local matCategoryCache = {}
  local matDebug = {}
  local function categoryForPos(pos)
    local matIdx = terrain:getMaterialIdxWs(pos)
    local cat = matCategoryCache[matIdx]
    if cat == nil then
      local gmName, internalName = nil, nil
      local matName = terrain.getMaterialName and terrain:getMaterialName(matIdx) or nil
      local mtl = terrain:getMaterial(matIdx)
      if mtl then
        gmName = mtl.getGroundmodelName and mtl:getGroundmodelName() or nil
        internalName = mtl.getInternalName and mtl:getInternalName() or nil
      end
      local resolved = gmName
      if not resolved or resolved == '' then
        resolved = internalName
      end
      if not resolved or resolved == '' then
        resolved = matName
      end
      cat = surfaceCategoryForGroundModel(resolved)
      matCategoryCache[matIdx] = cat
      matDebug[matIdx] = { gm = gmName, internal = internalName, matName = matName, resolved = resolved, category = cat, count = 0 }
    end
    matDebug[matIdx].count = matDebug[matIdx].count + 1
    return cat
  end

  local counts = { tarmac = 0, gravel = 0, ice = 0, snow = 0, rock = 0, grass = 0, other = 0 }
  local total = 0

  -- Sample the first point, then roughly every surfaceProbeStep meters.
  local distSinceSample = surfaceProbeStep
  for i = 1, #pts do
    local pos = pts[i].pos
    if i > 1 then
      distSinceSample = distSinceSample + pts[i - 1].pos:distance(pos)
    end
    if i == 1 or distSinceSample >= surfaceProbeStep then
      distSinceSample = 0
      local cat = categoryForPos(pos)
      counts[cat] = (counts[cat] or 0) + 1
      total = total + 1
    end
  end

  -- Debug: report the raw results so we can see exactly what the terrain returns.
  log('I', logTag, string.format('[surfaceProbe] %d samples over %d driveline points, %d unique materials', total, #pts, tableSize(matDebug)))
  log('I', logTag, '[surfaceProbe] raw per-material results:')
  for matIdx, d in pairs(matDebug) do
    log('I', logTag, string.format('[surfaceProbe]   matIdx=%s gm=%q internal=%q matName=%q -> resolved=%q category=%s count=%d',
      tostring(matIdx), tostring(d.gm), tostring(d.internal), tostring(d.matName), tostring(d.resolved), tostring(d.category), d.count))
  end
  log('I', logTag, '[surfaceProbe] raw category counts: ' .. dumps(counts))

  if total == 0 then return nil end

  -- Roll the incidental buckets (rock, grass, other) into a real surface. If a
  -- single surface dominates (> 90% of all samples), they are almost certainly
  -- incidental geometry along an otherwise-uniform stage, so fold them into that
  -- surface. Otherwise treat them as gravel (the catch-all).
  local domCat, domCount = nil, -1
  for _, cat in ipairs({'tarmac', 'gravel', 'ice', 'snow'}) do
    if counts[cat] > domCount then
      domCat = cat
      domCount = counts[cat]
    end
  end
  local mergeTarget = (domCat and (domCount / total) > 0.90) and domCat or 'gravel'
  counts[mergeTarget] = counts[mergeTarget] + counts.rock + counts.grass + counts.other
  log('I', logTag, string.format('[surfaceProbe] rolled rock=%d grass=%d other=%d into %q (dominant=%q %.1f%%)',
    counts.rock, counts.grass, counts.other, mergeTarget, tostring(domCat), (domCount / total) * 100))

  local percentages = {}
  for _, cat in ipairs({'tarmac', 'gravel', 'ice', 'snow'}) do
    local pct = (counts[cat] / total) * 100
    if pct > 0 then
      percentages[cat] = math.floor(pct * 10 + 0.5) / 10  -- 1 decimal
    end
  end
  return percentages
end

-- Recompute the stored stats (race distance + surface composition) and persist
-- them into the driveline spline file under the top-level "stats" key.
function C:refreshStats()
  if not self.drivelineV3 then return false end

  local tempRallyManager = self:createTempRallyManager()
  if not tempRallyManager then
    log('W', logTag, 'Refresh Stats: could not build rally manager')
    return false
  end

  local distanceM = tempRallyManager:getRaceDistanceMeters()
  local startSP, finishSP = tempRallyManager:getStartAndFinishStartPositions()

  local stats = {}
  if distanceM then
    self.calculatedRaceDistance = distanceM
    stats.raceDistanceKms = math.floor((distanceM / 1000) * 1000 + 0.5) / 1000  -- 3 decimals
  end
  if startSP and finishSP then
    local percentages = self:computeSurfacePercentages(startSP.pos, finishSP.pos)
    if percentages then
      stats.surfacePercentages = percentages
    end
  end

  self.drivelineV3.stats = stats

  -- Persist to the spline file so the stored value is authoritative.
  if not self:saveFinalDriveline() then
    log('W', logTag, 'Refresh Stats: computed stats but failed to save spline file')
    return false
  end

  log('I', logTag, 'Refreshed stage stats: ' .. jsonEncode(stats))
  return true
end

function C:saveFinalDriveline()
  return DrivelineEditSurface.saveFinalDriveline(self)
end

-- Generate buffer zone around driveline (experimental)
function C:generateBuffer()
  if not self.drivelineV3 or not self.drivelineV3.finalDrivelinePoints or #self.drivelineV3.finalDrivelinePoints < 1 then
    log('E', logTag, 'Cannot generate buffer: no final driveline points')
    return false
  end

  local startTime = os.clock()

  -- Extract positions from final driveline points
  self.bufferPoints = {}
  for _, point in ipairs(self.drivelineV3.finalDrivelinePoints) do
    table.insert(self.bufferPoints, vec3(point.pos))
  end

  -- Compute bounding box with buffer radius margin
  local minX, minY, minZ = math.huge, math.huge, math.huge
  local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge

  for _, pos in ipairs(self.bufferPoints) do
    minX = math.min(minX, pos.x)
    minY = math.min(minY, pos.y)
    minZ = math.min(minZ, pos.z)
    maxX = math.max(maxX, pos.x)
    maxY = math.max(maxY, pos.y)
    maxZ = math.max(maxZ, pos.z)
  end

  -- Expand by buffer radius
  local margin = self.bufferRadius
  self.bufferBounds = {
    min = vec3(minX - margin, minY - margin, minZ - margin),
    max = vec3(maxX + margin, maxY + margin, maxZ + margin)
  }

  self.bufferEnabled = true

  local elapsed = os.clock() - startTime
  log('I', logTag, string.format('Generated buffer with %d circles in %.3fs', #self.bufferPoints, elapsed))
  return true
end

-- Check if a point is inside the buffer zone
function C:isPointInBuffer(point)
  if not self.bufferEnabled or not self.bufferPoints or not self.bufferBounds then
    return false
  end

  -- Quick reject: check if point is outside bounding box
  if point.x < self.bufferBounds.min.x or point.x > self.bufferBounds.max.x or
     point.y < self.bufferBounds.min.y or point.y > self.bufferBounds.max.y or
     point.z < self.bufferBounds.min.z or point.z > self.bufferBounds.max.z then
    return false
  end

  -- Check distance to each buffer point
  local radiusSq = self.bufferRadius * self.bufferRadius
  for _, bufferPos in ipairs(self.bufferPoints) do
    if point:squaredDistance(bufferPos) <= radiusSq then
      return true  -- Early exit on first hit
    end
  end

  return false
end

function C:draw(mouseInfo, dtReal, dtSim, dtRaw)
  if not self.path then
    im.Text("No notebook loaded.")
    return
  end

  im.HeaderText("Driveline Editor")

  -- Check what sources are available
  local hasRecording = self:hasRecording()
  local hasFinal = self:hasFinalDriveline()

  -- Status display
  if self.loadError then
    im.HeaderText("Source Selection")
    im.TextColored(im.ImVec4(1, 0, 0, 1), "Error: " .. self.loadError)
    im.Spacing()
  end

  if not self.drivelineLoaded then
    -- === SOURCE SELECTION ===
    im.HeaderText("Source Selection")
    im.TextWrapped("Choose a driveline source to begin editing:")
    im.Spacing()

    -- Show available sources
    if hasRecording then
      if im.Button("Load from Recording", im.ImVec2(-1, 30)) then
        self:loadFromRecording()
      end
      if self.path then
        local missionDir = self.path:getMissionDir()
        if missionDir then
          local drivelineFile = rallyUtil.drivelineFile(missionDir)
          im.tooltip(drivelineFile .. "\n\nStart fresh from your raw recording. Best for first-time setup.")
        end
      end
    else
      im.BeginDisabled()
      im.Button("Load from Recording (Not Found)", im.ImVec2(-1, 30))
      im.EndDisabled()
      im.tooltip("No recording found. Drive the stage in Recce mode first.")
    end

    im.Spacing()

    -- Always allow loading an existing driveline - will create blank if needed
    local buttonLabel = hasFinal and "Existing Driveline" or "Create New Driveline"
    if im.Button(buttonLabel, im.ImVec2(-1, 30)) then
      self:loadFromFinal()
    end
    if self.path then
      local missionDir = self.path:getMissionDir()
      if missionDir then
        local saveFile = rallyUtil.drivelineSplineFile(missionDir)
        if hasFinal then
          im.tooltip(saveFile .. "\n\nContinue editing your previously saved driveline.")
        else
          im.tooltip(saveFile .. "\n\nCreate a new driveline from scratch by placing nodes.")
        end
      end
    end

    im.Spacing()

    -- Create from Race button
    if im.Button("Create from Race", im.ImVec2(-1, 30)) then
      self:loadFromRace()
    end
    if self.path then
      local missionDir = self.path:getMissionDir()
      if missionDir then
        local raceFile = missionDir..'/race.race.json'
        im.tooltip(raceFile .. "\n\nCreate a driveline from the race's AI path.")
      end
    end

  elseif self.drivelineLoaded then
    -- === LOADED STATE ===
    im.HeaderText("Source")
    if self.loadMode == 'recording' then
      im.Text("Loaded from: Recording")
    elseif self.loadMode == 'final' then
      im.Text("Loaded from: Existing Driveline")
    elseif self.loadMode == 'race' then
      im.Text("Loaded from: Race Path")
    end

    -- Reload button
    im.SameLine()
    if im.SmallButton("Change Source") then
      self.drivelineLoaded = false
      self.loadMode = nil
      self.drivelineV3.spline = nil
      self.drivelineV3.rawDrivelinePoints = nil
      self.drivelineV3.finalDrivelinePoints = nil
      self.calculatedRaceDistance = nil
      self:resetDrivelineStats()
      self.bufferEnabled = false
      self.bufferPoints = nil
      self.bufferBounds = nil
    end
    im.tooltip("Go back to source selection")

    im.Spacing()
    im.Separator()

    -- === RAW DATA SECTION (only for recording mode) ===
    if self.loadMode == 'recording' then
      im.HeaderText("Driveline Recording")

      -- Show raw points checkbox
      local showRawPtr = im.BoolPtr(self.showRawPoints)
      if im.Checkbox("Show Raw Points", showRawPtr) then
        self.showRawPoints = showRawPtr[0]
      end
      im.tooltip("Display the raw recorded driveline points")

      local pointCount = self:getDrivelinePointCount()
      im.Text("Points: " .. tostring(pointCount))
      local length = self:getDrivelineLength()
      im.Text("Length: " .. self:formatDistance(length))

      im.Spacing()
      im.Separator()
    end

    -- === SPLINE SECTION ===
    im.HeaderText("Spline")
    im.SameLine()
    im.TextColored(im.ImVec4(0, 1, 1, 1), "(help)")
    im.tooltip("- Click nodes to select\n- Drag to move nodes\n- Click curve: Insert node\n- Click free space: Add to nearest end\n- DELETE: Remove node")

    -- Spline view toggle
    local splineViewPtr = im.BoolPtr(self.isSplineView)
    if im.Checkbox("Show Spline", splineViewPtr) then
      self.isSplineView = splineViewPtr[0]
    end
    im.tooltip("Toggle between raw points and editable spline curve")

    -- Simplification tolerance slider (only for recording mode)
    if self.loadMode == 'recording' then
      im.PushItemWidth(-1)
      local tolPtr = im.FloatPtr(self.drivelineV3.simplificationTolerance)
      if im.SliderFloat("###simplifyTol", tolPtr, 0.1, 6.0, "Tolerance = %.1fm") then
        self.drivelineV3.simplificationTolerance = tolPtr[0]
      end
      -- Regenerate spline when user releases the slider
      if im.IsItemDeactivatedAfterEdit() then
        self.drivelineV3:convertDrivelineToSpline()
        if self.drivelineV3:updateSplineGeometry() then
          self:recalculateRaceDistance()
        end
      end
      im.tooltip("Simplification tolerance. Lower = more nodes, higher = fewer nodes.")
      im.PopItemWidth()
    end

    -- Spline node count and length
    if self.drivelineV3.spline then
      im.Text("Nodes: " .. tostring(#self.drivelineV3.spline.nodes))
      if self.drivelineV3.spline.roadLength then
        im.Text("Length: " .. self:formatDistance(self.drivelineV3.spline.roadLength))
      end
    end

    -- Simplify Spline button (available for all load modes)
    if self.drivelineV3.spline and #self.drivelineV3.spline.nodes > 2 then
      if im.Button("Simplify Spline") then
        DrivelineEditSurface.simplifySpline(self, simplifyRdpTol, self:splineEditCallbacks())
      end
      im.tooltip("Reduce the number of spline nodes using RDP simplification (tolerance: " .. simplifyRdpTol .. "m).\n\nBack up your existing spline file before trying this.")
    end

    -- Save button
    im.PushStyleColor2(im.Col_Button, im.ImColorByRGB(0,100,0,255).Value)
    if im.Button("Save Driveline Spline") then
      self:saveFinalDriveline()
    end
    im.PopStyleColor(1)
    -- Show actual save path in tooltip
    if self.path then
      local missionDir = self.path:getMissionDir()
      if missionDir then
        local saveFile = rallyUtil.drivelineSplineFile(missionDir)
        im.tooltip(saveFile)
      end
    end

    im.Spacing()
    im.Separator()

    -- === DRIVELINE SECTION ===
    im.HeaderText("Driveline")

    -- Show driveline checkbox
    local showFinalVisualizationPtr = im.BoolPtr(self.showFinalDrivelineVisualization or false)
    if im.Checkbox("Show Driveline", showFinalVisualizationPtr) then
      self.showFinalDrivelineVisualization = showFinalVisualizationPtr[0]
    end
    im.tooltip("Display the driveline points in the 3D view")

    -- Show final driveline stats and controls
    if self.drivelineV3.finalDrivelinePoints then
      local stats = self.drivelineStats or {}
      im.Text("Points: " .. tostring(stats.pointCount or 0))
      im.Text("Length: " .. self:formatDistance(stats.length or 0))
      if self.calculatedRaceDistance then
        im.Text("Race Distance: " .. self:formatDistance(self.calculatedRaceDistance))
      elseif self.calculatedRaceDistance == false then
        im.TextColored(im.ImVec4(1, 0.5, 0, 1), "Race Distance: no start/finish positions found")
      else
        im.Text("Race Distance: N/A")
      end
      im.tooltip("Auto-calculated distance between start and finish positions.")

      -- Stored stage stats (persisted in the driveline spline file under "stats").
      -- The display always reflects the stored value; use Refresh Stats to recompute.
      local stats = self.drivelineV3.stats
      if stats and (stats.raceDistanceKms or stats.surfacePercentages) then
        if stats.raceDistanceKms then
          im.Text(string.format("Stored Race Distance: %.3f km", stats.raceDistanceKms))
        end
        if stats.surfacePercentages then
          local parts = {}
          for _, entry in ipairs({{'tarmac', 'Tarmac'}, {'gravel', 'Gravel'}, {'ice', 'Ice'}, {'snow', 'Snow'}}) do
            local pct = stats.surfacePercentages[entry[1]]
            if pct and pct > 0 then
              parts[#parts + 1] = string.format("%s %g%%", entry[2], pct)
            end
          end
          if #parts > 0 then
            im.TextUnformatted("Stored Surface: " .. table.concat(parts, " - "))
          end
        end
      else
        im.TextColored(im.ImVec4(0.7, 0.7, 0.7, 1), "Stored Stats: none - click Refresh Stats")
      end

      if im.Button("Refresh Stats") then
        self:refreshStats()
      end
      im.tooltip("Recompute race distance (start line to flying finish) and surface composition, then save them into the driveline spline file under the top-level \"stats\" key.")

      im.Spacing()
      im.Separator()

      -- Properties section
      im.HeaderText("Properties")
      self.drivelineV3.properties = self.drivelineV3.properties or {}
      if self.drivelineV3.properties.useRaycast == nil then
        self.drivelineV3.properties.useRaycast = false
      end
      if self.drivelineV3.properties.vertRayRaise == nil then
        self.drivelineV3.properties.vertRayRaise = 2.0
      end

      local useRaycastPtr = im.BoolPtr(self.drivelineV3.properties.useRaycast == true)
      if im.Checkbox("Use Raycast###useRaycast", useRaycastPtr) then
        self.drivelineV3.properties.useRaycast = useRaycastPtr[0]
        if self.drivelineV3.spline and self.drivelineV3.spline.nodes and #self.drivelineV3.spline.nodes >= 2 then
          self.drivelineV3.spline.isDirty = true
          self:updateSplineGeometry()
        end
      end
      im.tooltip("When disabled, driveline points snap to terrain height. When enabled, they use vertical raycast snapping.")

      im.SetNextItemWidth(160)
      local vertRayRaisePtr = im.FloatPtr(self.drivelineV3.properties.vertRayRaise)
      if im.SliderFloat("Raycast Raise (m)###vertRayRaise", vertRayRaisePtr, 0.1, 20.0, "%.1fm") then
        self.drivelineV3.properties.vertRayRaise = clamp(vertRayRaisePtr[0], 0.1, 20.0)
        if self.drivelineV3.properties.useRaycast and self.drivelineV3.spline and self.drivelineV3.spline.nodes and #self.drivelineV3.spline.nodes >= 2 then
          self.drivelineV3.spline.isDirty = true
          self:updateSplineGeometry()
        end
      end
      im.tooltip("How far above each point vertical raycast snapping starts. Larger values can catch bridge decks above the spline height.")

      -- im.PushItemWidth(-1)
      im.SetNextItemWidth(100)
      local speedLimitPtr = im.FloatPtr(self.drivelineV3.properties.speedLimitKph or 100)
      local speedLimitMph = speedLimitPtr[0] * 0.621371
      local label = string.format("(%.0f mph) Speed Limit (liaison) / Average Speed (special stage) kph###speedLimitKph", speedLimitMph)
      if im.InputFloat(label, speedLimitPtr, 1.0, 10.0, "%.0f") then
        self.drivelineV3.properties.speedLimitKph = math.max(0, speedLimitPtr[0])
      end
      im.tooltip("Speed Limit (liaison), OR Average Speed (special stage).\n\nFor liaisons/road sections, this is the speed limit used for enforcement.\n\nFor special stages, this is the average speed input for schedule allocation. Drive the course, then adjust up or down for a tighter or looser schedule and to support the vehicle performance range you want.")
      -- im.PopItemWidth()

      im.SetNextItemWidth(100)
      local liaisonTimePtr = im.IntPtr(self.drivelineV3.properties.liaisonAllocatedTimeMins or 5)
      if im.InputInt("Allocated Time (mins) - liaisons only###liaisonAllocatedTimeMins", liaisonTimePtr, 1, 5) then
        self.drivelineV3.properties.liaisonAllocatedTimeMins = math.max(1, liaisonTimePtr[0])
      end
      im.tooltip("Saved as the liaison/road-section allocation.\n\nThis is only used for liaison/road-section schedule timing and does not override special-stage schedule timing.")

      local silverTimeSecs = self:getMissionSilverTimeSecs()
      local averageSpeedKph = nil
      if silverTimeSecs and self.calculatedRaceDistance then
        averageSpeedKph = (self.calculatedRaceDistance / 1000) / (silverTimeSecs / 3600)
      end
      if silverTimeSecs then
        im.Text("Mission Silver Time: " .. self:formatDurationSecs(silverTimeSecs))
        im.tooltip("Silver time from the mission that owns the loaded Rally Editor notebook. Reference only; it does not change liaison allocated time or special-stage schedule allocation.")
        if averageSpeedKph then
          im.Text(string.format("Average Speed Preview: %.1f kph (%.0f mph)", averageSpeedKph, averageSpeedKph * 0.621371))
        else
          im.Text("Average Speed Preview: N/A (race distance unavailable)")
        end
      else
        im.Text("Mission Silver Time: N/A (not set)")
        im.Text("Average Speed Preview: N/A (silver time unavailable)")
      end
      local disableAverageSpeedButton = not (silverTimeSecs and averageSpeedKph)
      if disableAverageSpeedButton then im.BeginDisabled() end
      if im.Button("Set Average Speed from Silver Time") then
        self:setAverageSpeedFromSilverTimeAndRaceDistance()
      end
      if disableAverageSpeedButton then im.EndDisabled() end
      im.tooltip("Use the loaded notebook mission's silver time and the current driveline race distance to set the special-stage average speed.\n\nThis updates the same field used as Speed Limit (liaison) / Average Speed (special stage).")

      im.Spacing()

      --[[ EXPERIMENTAL: BUFFER ZONE
      im.Spacing()
      im.Separator()
      im.HeaderText("Experimental: Buffer Zone")

      if not self.bufferEnabled then
        if im.Button("Generate Buffer (30m)", im.ImVec2(-1, 30)) then
          self:generateBuffer()
        end
        im.tooltip("Generate a 30-meter buffer zone around the driveline for spatial queries")
      else
        im.Text(string.format("Buffer: %d circles, %.0fm radius", #self.bufferPoints, self.bufferRadius))

        if im.Button("Clear Buffer") then
          self.bufferEnabled = false
          self.bufferPoints = nil
          self.bufferBounds = nil
          log('I', logTag, 'Buffer cleared')
        end
        im.tooltip("Clear the buffer zone")
      end
      --]]
    end
  end
end

function C:drawDebugEntrypoint(mouseInfo)
  if not self.drivelineLoaded or not self.drivelineV3 then
    return
  end

  -- Render raw driveline as thin cylinder (polyline) if enabled (recording mode only)
  if self.loadMode == 'recording' and self.showRawPoints then
    self.drivelineV3:renderRawDriveline()
  end

  if self.isSplineView and self.drivelineV3.spline then
    -- Handle interactive spline editing
    self:handleSplineInteraction()

    -- Update geometry if dirty (only if we have enough nodes)
    if self.drivelineV3.spline.isDirty and #self.drivelineV3.spline.nodes >= 2 then
      if self.drivelineV3:updateSplineGeometry() then
        self.drivelineV3:createDrivelineFromSpline()
        self:recalculateDrivelineStats()
      end
    end

    -- Render smooth secondary geometry
    local splinePrismWidth = self.rallyEditor.getPrefDrivelineSplinePrismWidth and self.rallyEditor.getPrefDrivelineSplinePrismWidth()
    self.drivelineV3:renderSmoothCurve(splinePrismWidth)

    -- Render editable spline with interaction
    self.drivelineV3:renderSpline(self.selectedNodeIdx)
  end

  -- Render final driveline if enabled
  if self.showFinalDrivelineVisualization and self.drivelineV3.finalDrivelinePoints then
    self.drivelineV3:renderFinalDriveline()
  end

  --[[ Render buffer zone visualization (experimental)
  if self.bufferEnabled and self.bufferPoints and self.bufferBounds then
    -- Draw bounding box as wireframe
    local min, max = self.bufferBounds.min, self.bufferBounds.max
    local clr_bbox = ColorF(1, 1, 0, 1)  -- Yellow
    debugDrawer:drawLine(vec3(min.x, min.y, min.z), vec3(max.x, min.y, min.z), clr_bbox)
    debugDrawer:drawLine(vec3(max.x, min.y, min.z), vec3(max.x, max.y, min.z), clr_bbox)
    debugDrawer:drawLine(vec3(max.x, max.y, min.z), vec3(min.x, max.y, min.z), clr_bbox)
    debugDrawer:drawLine(vec3(min.x, max.y, min.z), vec3(min.x, min.y, min.z), clr_bbox)
    debugDrawer:drawLine(vec3(min.x, min.y, max.z), vec3(max.x, min.y, max.z), clr_bbox)
    debugDrawer:drawLine(vec3(max.x, min.y, max.z), vec3(max.x, max.y, max.z), clr_bbox)
    debugDrawer:drawLine(vec3(max.x, max.y, max.z), vec3(min.x, max.y, max.z), clr_bbox)
    debugDrawer:drawLine(vec3(min.x, max.y, max.z), vec3(min.x, min.y, max.z), clr_bbox)
    debugDrawer:drawLine(vec3(min.x, min.y, min.z), vec3(min.x, min.y, max.z), clr_bbox)
    debugDrawer:drawLine(vec3(max.x, min.y, min.z), vec3(max.x, min.y, max.z), clr_bbox)
    debugDrawer:drawLine(vec3(max.x, max.y, min.z), vec3(max.x, max.y, max.z), clr_bbox)
    debugDrawer:drawLine(vec3(min.x, max.y, min.z), vec3(min.x, max.y, max.z), clr_bbox)

    -- Draw buffer circles with binormals (sampled to avoid performance issues)
    local clr_buffer = ColorF(1, 0, 0, 0.02)  -- Semi-transparent red
    local clr_binormal = ColorF(0, 1, 1, 1)  -- Cyan for binormal lines
    local sampleRate = math.max(1, math.floor(#self.bufferPoints / 100))  -- Show ~100 circles max
    local binormalLength = self.bufferRadius

    for i = 1, #self.bufferPoints, sampleRate do
      local pos = self.bufferPoints[i]
      -- debugDrawer:drawSphere(pos, self.bufferRadius, clr_buffer)

      -- Compute tangent (direction along driveline)
      local tangent = vec3(1, 0, 0)  -- Default
      if i > 1 and i < #self.bufferPoints then
        -- Use direction between previous and next points
        local prevPos = self.bufferPoints[i - 1]
        local nextPos = self.bufferPoints[i + 1]
        tangent = (nextPos - prevPos):normalized()
      elseif i == 1 and #self.bufferPoints > 1 then
        -- First point: use direction to next
        tangent = (self.bufferPoints[i + 1] - pos):normalized()
      elseif i == #self.bufferPoints and #self.bufferPoints > 1 then
        -- Last point: use direction from previous
        tangent = (pos - self.bufferPoints[i - 1]):normalized()
      end

      -- Compute binormal (perpendicular to tangent, horizontal)
      local up = vec3(0, 0, 1)
      local binormal = tangent:cross(up):normalized()
      if binormal:length() < 0.1 then
        -- If tangent is vertical, use different reference
        binormal = vec3(1, 0, 0)
      end

      -- Draw binormal line
      local lineStart = pos - binormal * binormalLength
      local lineEnd = pos + binormal * binormalLength
      debugDrawer:drawLine(lineStart, lineEnd, clr_binormal)
    end

    -- Visualize map nodes with color-coded spheres
    local mapData = map.getMap()
    local nodeSize = 1.0
    if mapData and mapData.nodes then
      local clr_inside = ColorF(0, 1, 0, 1)  -- Green for inside bbox
      local clr_outside = ColorF(1, 0, 0, 1)  -- Red for outside bbox
      local clr_inBuffer = ColorF(1.0, 0, 1.0, 1)  -- Bright purple for inside buffer

      for nodeName, nodeData in pairs(mapData.nodes) do
        if nodeData.pos then
          local pos = nodeData.pos

          -- Check if inside bounding box
          local insideBbox = (pos.x >= min.x and pos.x <= max.x and
                              pos.y >= min.y and pos.y <= max.y and
                              pos.z >= min.z and pos.z <= max.z)

          if insideBbox then
            -- Check if actually in buffer
            local inBuffer = self:isPointInBuffer(pos)
            if inBuffer then
              debugDrawer:drawSphere(pos, nodeSize, clr_inBuffer)
            else
              debugDrawer:drawSphere(pos, nodeSize, clr_inside)
            end
          else
            debugDrawer:drawSphere(pos, nodeSize, clr_outside)
          end
        end
      end
    end
  end
  --]]
end

-- Handle spline interaction (mouse/keyboard input)
function C:handleSplineInteraction()
  DrivelineEditSurface.handleSplineInteraction(self, self:splineEditCallbacks())
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end

