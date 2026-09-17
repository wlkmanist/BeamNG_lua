-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- snaproad is used in the world editor to provide snap-to-road functionality.

local logTag = ''
local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local cc = require('/lua/ge/extensions/gameplay/rally/util/colors')
-- local RallyEnums = require('/lua/ge/extensions/gameplay/rally/enums')
local normals = require('/lua/ge/extensions/gameplay/rally/snaproad/normals')
local geoPacenotes = require('/lua/ge/extensions/gameplay/rally/snaproad/geoPacenotes')
local kdTreeP3d = require('kdtreepoint3d')

local C = {}

local startingMinDist = 4294967295
local segmentSearchWindow = 6
local minAdjacentWaypointDistance = 2.0
local snaproadPrismHeight = 0.5
local snaproadPrismWidthDefault = 1.945

local function clamp01(v)
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

local function buildPointIndex(points)
  local count = points and #points or 0
  if count == 0 then
    return {
      points = points or {},
      kdTree = nil,
      stableIdIndex = {},
      prefixDistances = {},
      totalLength = 0,
    }
  end

  local kdT = kdTreeP3d.new(count)
  local stableIdIndex = {}
  local prefixDistances = {}
  local totalLength = 0

  for i, point in ipairs(points) do
    kdT:preLoad(i, point.pos.x, point.pos.y, point.pos.z)
    stableIdIndex[i] = {idx = i, point = point}
    if i == 1 then
      prefixDistances[i] = 0
    else
      local prevPoint = points[i - 1]
      totalLength = totalLength + prevPoint.pos:distance(point.pos)
      prefixDistances[i] = totalLength
    end
  end

  kdT:build()
  return {
    points = points,
    kdTree = kdT,
    stableIdIndex = stableIdIndex,
    prefixDistances = prefixDistances,
    totalLength = totalLength,
  }
end

function C:init(driveline)
  self._driveline = driveline

  self.cameraPathPlayer = require('/lua/ge/extensions/gameplay/rally/cameraPathPlayer')(self)

  self.show_corner_calls = false

  self.filter = {
    enabled = false,
    points = {},
    lowerLocation = nil,
    upperLocation = nil,
  }

  self.partition = {
    enabled = false,
    pacenote = nil,
    before_points = {},
    focus_points = {},
    after_points = {},
    corner_call_points = {},
  }

  self.partition_all_state = {
    enabled = false,
    notebook = nil,
    partitions = {},
    pacenote_partitions = {},
  }

  self.globalOpacity = 1.0

  self._allPointsIndex = buildPointIndex(self:_allPoints())
  self._filterPointsIndex = nil
end

-- function C:isRecceSourced()
--   return self.sourceType == RallyEnums.drivelineMode.recce
-- end

-- function C:isRouteSourced()
--   return self.sourceType == RallyEnums.drivelineMode.route
-- end

function C:setGlobalOpacity(globalOpacity)
  self.globalOpacity = globalOpacity
end

local adjustHeight = function(pos, r)
  -- local newZ = core_terrain.getTerrainHeight(pos)
  -- return vec3(pos.x, pos.y, newZ-(r*0.25))
  return pos
end

function C:_drawDebugPointPrisms(points, clr, alpha, adjustH, globalOpacity, prismWidth, fromLocation, toLocation, drawOnTop)
  if not points or #points < 2 then return end

  local clr = clr or self:_clrSnaproad()
  local alpha_shape = alpha or cc.snaproads_alpha
  local prismWidth = tonumber(prismWidth) or snaproadPrismWidthDefault

  alpha_shape = alpha_shape * (globalOpacity or 1)

  local function prismPos(pos)
    if adjustH then
      return adjustHeight(pos, snaproadPrismHeight)
    end
    return pos
  end

  for i = 1, #points - 1 do
    local fromPos = points[i].pos
    local toPos = points[i + 1].pos

    if i == 1 and fromLocation and fromLocation.pos then
      fromPos = fromLocation.pos
    end
    if i == #points - 1 and toLocation and toLocation.pos then
      toPos = toLocation.pos
    end

    debugDrawer:drawSquarePrism(
      prismPos(fromPos),
      prismPos(toPos),
      Point2F(snaproadPrismHeight, prismWidth),
      Point2F(snaproadPrismHeight, prismWidth),
      ColorF(clr[1],clr[2],clr[3], alpha_shape),
      not drawOnTop,
      false
    )
  end
end

function C:_drawDebugPartitionAllPrisms(partition, clr, prismWidth, drawOnTop)
  if not partition then return end

  local clr = clr or self:_clrSnaproad()
  local alpha_shape = cc.snaproads_alpha * self.globalOpacity
  local prismWidth = tonumber(prismWidth) or snaproadPrismWidthDefault
  local positions = {}

  local function addPos(pos)
    if not pos then return end

    local lastPos = positions[#positions]
    if lastPos and lastPos:distance(pos) < 0.0001 then return end

    table.insert(positions, vec3(pos))
  end

  if partition.limitBackLocation and partition.limitBackLocation.pos then
    addPos(partition.limitBackLocation.pos)
  end

  for _,point in ipairs(partition) do
    addPos(point.pos)
  end

  if partition.limitFwdLocation and partition.limitFwdLocation.pos then
    addPos(partition.limitFwdLocation.pos)
  end

  if #positions < 2 then return end

  for i = 1, #positions - 1 do
    debugDrawer:drawSquarePrism(
      positions[i],
      positions[i + 1],
      Point2F(snaproadPrismHeight, prismWidth),
      Point2F(snaproadPrismHeight, prismWidth),
      ColorF(clr[1],clr[2],clr[3], alpha_shape),
      not drawOnTop,
      false
    )
  end
end

function C:_drawDebugPoints(points, clr, alpha, radius, adjustH, globalOpacity)
  local clr = clr or self:_clrSnaproad()
  local alpha_shape = alpha or cc.snaproads_alpha
  local radius = radius or cc.snaproads_radius

  alpha_shape = alpha_shape * globalOpacity

  for _,point in ipairs(points) do
    local pos = point.pos

    local cached = point.cachedPacenotes
    if cached and cached.half then
      clr = cc.clr_blue
      radius = 0.75
    end

    if adjustH then
      pos = adjustHeight(pos, radius)
    end

    debugDrawer:drawSphere(
      pos,
      radius,
      ColorF(clr[1],clr[2],clr[3], alpha_shape)
    )
  end
end

function C:_drawDebugPointsCyl(points, clr, alpha, radius, adjustH, globalOpacity, h)
  local clr = clr or self:_clrSnaproad()
  local alpha_shape = alpha or cc.snaproads_alpha
  local radius = radius or 0.1
  local h = h or 2

  alpha_shape = alpha_shape * globalOpacity

  for _,point in ipairs(points) do
    local pos = point.pos

    if adjustH then
      pos = adjustHeight(pos, radius)
    end

    debugDrawer:drawCylinder(
      pos,
      pos + vec3(0,0,h),
      radius,
      ColorF(clr[1],clr[2],clr[3], alpha_shape)
    )
  end
end

-- this is used for Ctrl+click to create new pacenote.
function C:_drawDebugPartitionsAll(prismWidth, drawOnTop)
  local points = self.partition_all_state.partitions
  if not points then return end
  local clr = cc.clr_green

  for i,partition in ipairs(points) do
    self:_drawDebugPartitionAllPrisms(partition, clr, prismWidth, drawOnTop)
  end

  points = self.partition_all_state.pacenote_partitions
  clr = cc.waypoint_clr_background

  for i,partition in ipairs(points) do
    self:_drawDebugPartitionAllPrisms(partition, clr, prismWidth, drawOnTop)
  end
end

local function partitionOverlapsWindow(partition, window)
  if not window then return true end
  local partitionStart = partition.limitBackLocation and partition.limitBackLocation.distanceAlongRoute or 0
  local partitionEnd = partition.limitFwdLocation and partition.limitFwdLocation.distanceAlongRoute or math.huge
  return partitionEnd >= window.startDistance and partitionStart <= window.endDistance
end

function C:drawDebugPartitionsAllWindow(window, prismWidth, drawOnTop)
  local partitions = self.partition_all_state.partitions
  if not partitions then return end

  for _,partition in ipairs(partitions) do
    if partitionOverlapsWindow(partition, window) then
      self:_drawDebugPartitionAllPrisms(partition, cc.clr_green, prismWidth, drawOnTop)
    end
  end

  partitions = self.partition_all_state.pacenote_partitions
  if not partitions then return end

  for _,partition in ipairs(partitions) do
    if partitionOverlapsWindow(partition, window) then
      self:_drawDebugPartitionAllPrisms(partition, cc.waypoint_clr_background, prismWidth, drawOnTop)
    end
  end
end

function C:_clrSnaproad()
  -- if self:isRecceSourced() then
    return cc.snaproads_clr_recce
  -- elseif self:isRouteSourced() then
    -- return cc.snaproads_clr_route
  -- else
    -- return cc.snaproads_clr_recce
  -- end
end

local function pointsWithAppendedPoint(points, point)
  local out = {}
  for _, p in ipairs(points or {}) do
    table.insert(out, p)
  end
  if point then
    table.insert(out, point)
  end
  return out
end

local function pointsWithPrependedPoint(points, point)
  local out = {}
  if point then
    table.insert(out, point)
  end
  for _, p in ipairs(points or {}) do
    table.insert(out, p)
  end
  return out
end

function C:_drawDebugPartition(adjustH, prismWidth, drawOnTop)
  local points = self.partition.focus_points
  local clr = nil

  if self.filter.enabled then
    clr = cc.clr_white
  else
    clr = self:_clrSnaproad()
  end

  if self.show_corner_calls then
    -- self:_drawDebugPoints(self.partition.corner_call_points.points_at_to_cs, clr, nil, nil, adjustH, self.globalOpacity)
    -- self:_drawDebugCornerCalls()
  else
    self:_drawDebugPointPrisms(points, clr, nil, adjustH, self.globalOpacity, prismWidth, self.partition.fromLocation, self.partition.toLocation, drawOnTop)
  end

  points = self.partition.before_points
  clr = cc.waypoint_clr_background
  points = pointsWithAppendedPoint(points, self.partition.focus_points[1])
  self:_drawDebugPointPrisms(points, clr, nil, adjustH, self.globalOpacity, prismWidth, nil, self.partition.fromLocation, drawOnTop)

  points = self.partition.after_points
  clr = cc.waypoint_clr_background
  points = pointsWithPrependedPoint(points, self.partition.focus_points[#self.partition.focus_points])
  self:_drawDebugPointPrisms(points, clr, nil, adjustH, self.globalOpacity, prismWidth, self.partition.toLocation, nil, drawOnTop)
end

function C:measurePartition()
  local pn = self.partition.pacenote
  if not pn then
    return
  end
  geoPacenotes.measurePartition(pn, self.partition.focus_points)
end

function C:_drawDebugDefault(adjustH, clrOverride, prismWidth, drawOnTop)
  local points = self:_allPoints()
  self:_drawDebugPointPrisms(points, clrOverride, nil, adjustH, self.globalOpacity, prismWidth, nil, nil, drawOnTop)
  -- self:_drawDebugPointsCyl(self:driveline().debugPointsOriginal, cc.clr_black, 0.5, 0.1, adjustH, self.globalOpacity, 4)
  -- self:_drawDebugPointsCyl(self:driveline().debugPointsRefined, cc.clr_red, 0.5, 0.2, adjustH, self.globalOpacity, 3)
  -- self:_drawDebugPointsCyl(self:driveline().debugPointsOptimized, cc.clr_orange, 0.5, 0.3, adjustH, self.globalOpacity, 2)
  -- self:_drawDebugPoints(self:driveline().debugPointsFinal, cc.clr_yellow, nil, nil, adjustH, self.globalOpacity)
end

function C:drawDebugSnaproad(clrOverride, prismWidth, drawOnTop)
  -- if self.filter.enabled then
    -- self:_drawDebugFilter()
  if self.partition.enabled then
    self:_drawDebugPartition(nil, prismWidth, drawOnTop)
  elseif self.partition_all_state.enabled then
    self:_drawDebugPartitionsAll(prismWidth, drawOnTop)
  else
    self:_drawDebugDefault(false, clrOverride, prismWidth, drawOnTop)
  end
end

function C:drawDebugRecceApp()
  if self.partition.enabled then
    self:_drawDebugPartition(true)
  else
    self:_drawDebugDefault(true)
  end
end

function C:drawDebugCameraPlaying()
  local pn = self.partition.pacenote
  if self.partition.enabled and pn then
    local radius = 1.0
    local clr = cc.clr_black
    local alpha_shape = cc.snaproads_alpha_driving

    clr = cc.waypoint_clr_cs
    debugDrawer:drawSphere(
      adjustHeight(pn:getCornerStartWaypoint().pos, radius),
      radius,
      ColorF(clr[1],clr[2],clr[3], alpha_shape)
    )

    clr = cc.waypoint_clr_ce
    debugDrawer:drawSphere(
      adjustHeight(pn:getCornerEndWaypoint().pos, radius),
      radius,
      ColorF(clr[1],clr[2],clr[3], alpha_shape)
    )

    clr = cc.clr_white
    radius = cc.snaproads_radius_driving
    local points = self.partition.focus_points

    for _,point in ipairs(points) do
      local pos = point.pos
      debugDrawer:drawSphere(
        adjustHeight(pos, radius),
        radius,
        ColorF(clr[1],clr[2],clr[3], alpha_shape)
      )
    end
  end
end

local function mylerp(a, b, t)
  return a + (b - a) * t
end

local function createGradient(steps)
  local gradient = {}

  for i = 1, steps do
    local t = (i - 1) / (steps - 1)  -- Normalize t to 0-1
    local r, g, b

    if t <= 0.5 then
      -- Interpolate between red and yellow
      r = 1
      g = mylerp(0, 1, t * 2)  -- Double t because it's only half the gradient
      b = 0
    else
      -- Interpolate between yellow and green
      r = mylerp(1, 0, (t - 0.5) * 2)  -- Adjust t and double for second half
      g = 1
      b = 0
    end

    table.insert(gradient, {r, g, b})
  end

  return gradient
end

function C:groupPointsByCornerCall(points)
  if not self.styleData then return {} end
  -- if editor_rallyEditor then
    -- local cornerAnglesStyle = capture_data.cornerAnglesStyle
    -- local corner_angles_data = editor_rallyEditor.getTranscriptsWindow():getCornerAngles(force_reload)
    -- local style_data = nil
    -- for _,style in ipairs(corner_angles_data.pacenoteStyles) do
    --   if style.name == cornerAnglesStyle then
    --     style_data = style
    --   end
    -- end

  local sortedAngles = {}
  for i,angle in ipairs(self.styleData.angles) do
    table.insert(sortedAngles, angle)
  end
  local function sortByAngleRev(a, b)
    return a.fromAngleDegrees > b.fromAngleDegrees
  end
  table.sort(sortedAngles, sortByAngleRev)

  local steps = #sortedAngles - 1  -- Number of color steps in the gradient
  -- subtract 1 for Center
  local gradientColors = createGradient(steps)
  for i,angle in ipairs(sortedAngles) do
    angle.color = gradientColors[i]
  end
  sortedAngles[#sortedAngles].color = cc.clr_white

  local subgroups = {{points = {}, label_point=-1, calc=nil}}

  for _,point in ipairs(points) do
    local subgroup_points = subgroups[#subgroups].points

    local angle_data, cornerCallStr, pct = rallyUtil.determineCornerCall(sortedAngles, point.steering)
    point.calc = {
      angle_pct = pct,
      angle_data = angle_data,
      cornerCallStr = cornerCallStr,
    }

    if #subgroup_points == 0 then
      table.insert(subgroup_points, point)
      subgroups[#subgroups].calc = point.calc
    elseif subgroup_points[#subgroup_points].calc.cornerCallStr ~= point.calc.cornerCallStr then
      table.insert(subgroups, {points={point}, label_point=-1, calc=point.calc})
    else
      table.insert(subgroup_points, point)
      subgroups[#subgroups].calc = point.calc
    end
  end

  for _,grp in ipairs(subgroups) do
    local label_i = round(#grp.points / 2)
    grp.label_point = grp.points[label_i]
  end

  return subgroups
end

function C:_drawDebugCornerCalls()
  local radius = cc.snaproads_radius
  local shapeAlpha = cc.snaproads_alpha
  local textAlpha = 1.0
  local clr = nil
  local clr_text_fg = cc.clr_black
  local label_point = nil
  local clr_text_bg = nil
  local calc = nil

  local groups = self.partition.corner_call_points.groups

  for _,grp in ipairs(groups) do
    for _,cap in ipairs(grp.points) do
      clr = cap.calc.angle_data.color
      local pos = vec3(cap.pos)
      debugDrawer:drawSphere(pos, radius, ColorF(clr[1],clr[2],clr[3],shapeAlpha))
    end

    label_point = grp.label_point
    calc = grp.calc
    clr_text_bg = calc.angle_data.color

    debugDrawer:drawTextAdvanced(
      vec3(label_point.pos),
      String(calc.cornerCallStr..' '),
      ColorF(clr_text_fg[1], clr_text_fg[2], clr_text_fg[3], textAlpha),
      true,
      false,
      ColorI(clr_text_bg[1]*255, clr_text_bg[2]*255, clr_text_bg[3]*255, textAlpha*255)
    )
  end
end

function C:driveline()
  return self._driveline
end

function C:_allPoints()
  if self:driveline() then
    return self:driveline().points
  else
    return {}
  end
end

function C:_operativePoints()
  if self.filter.enabled then
    return self.filter.points
  else
    return self:_allPoints()
  end
end

function C:_rebuildAllPointIndex()
  self._allPointsIndex = buildPointIndex(self:_allPoints())
  self._filterPointsIndex = nil
end

function C:_invalidateFilterPointIndex()
  self._filterPointsIndex = nil
end

function C:_indexForPoints(useAllPoints)
  if useAllPoints or not self.filter.enabled then
    if not self._allPointsIndex or self._allPointsIndex.points ~= self:_allPoints() then
      self:_rebuildAllPointIndex()
    end
    return self._allPointsIndex
  end

  if not self._filterPointsIndex or self._filterPointsIndex.points ~= self.filter.points then
    self._filterPointsIndex = buildPointIndex(self.filter.points)
  end
  return self._filterPointsIndex
end

function C:minAdjacentWaypointDistance()
  return minAdjacentWaypointDistance
end

function C:totalRouteLength()
  local index = self:_indexForPoints(true)
  return index.totalLength or 0
end

function C:routeLocationForPoint(point)
  if not point then return nil end
  local index = self:_indexForPoints(true)
  local idx = point.id
  if not idx or not index.points[idx] then return nil end
  return {
    pos = vec3(point.pos),
    point = point,
    nearestPoint = point,
    fromPoint = point,
    toPoint = point.next or point.prev,
    segmentIndex = idx,
    xnorm = 0,
    distanceAlongRoute = index.prefixDistances[idx] or 0,
    distSq = 0,
  }
end

function C:compareRouteLocations(a, b)
  if not a or not b then return nil end
  local da = a.distanceAlongRoute
  local db = b.distanceAlongRoute
  if not da or not db then return nil end
  if math.abs(da - db) < 0.0001 then return 0 end
  return da < db and -1 or 1
end

function C:distanceBetweenRouteLocations(a, b)
  if not a or not b then return nil end
  if not a.distanceAlongRoute or not b.distanceAlongRoute then return nil end
  return math.abs(b.distanceAlongRoute - a.distanceAlongRoute)
end

function C:normalForSnapResult(result)
  if not result then return nil end
  local fromPoint = result.fromPoint
  local toPoint = result.toPoint
  if fromPoint and toPoint then
    if fromPoint == toPoint or fromPoint.pos:distance(toPoint.pos) < 0.0001 then
      return result.nearestPoint and self:forwardNormalVec(result.nearestPoint) or nil
    end
    local normVec = rallyUtil.calculateForwardNormal(fromPoint.pos, toPoint.pos)
    return vec3(normVec.x, normVec.y, normVec.z)
  elseif result.nearestPoint then
    return self:forwardNormalVec(result.nearestPoint)
  end
  return nil
end

function C:positionAtDistanceAlongRoute(distanceAlongRoute, useAllPoints)
  local index = self:_indexForPoints(useAllPoints)
  local points = index.points
  if not points or #points == 0 then return nil end
  if #points == 1 then
    return {
      pos = vec3(points[1].pos),
      fromPoint = points[1],
      toPoint = points[1],
      nearestPoint = points[1],
      segmentIndex = 1,
      xnorm = 0,
      distanceAlongRoute = 0,
      distSq = 0,
    }
  end

  local target = math.max(0, math.min(distanceAlongRoute or 0, index.totalLength or 0))
  for i = 1, #points - 1 do
    local segStartDist = index.prefixDistances[i] or 0
    local segEndDist = index.prefixDistances[i + 1] or segStartDist
    if target <= segEndDist or i == #points - 1 then
      local segLength = segEndDist - segStartDist
      local xnorm = segLength > 0 and ((target - segStartDist) / segLength) or 0
      local fromPoint = points[i]
      local toPoint = points[i + 1]
      local pos = vec3(lerp(fromPoint.pos, toPoint.pos, clamp01(xnorm)))
      return {
        pos = pos,
        fromPoint = fromPoint,
        toPoint = toPoint,
        nearestPoint = xnorm < 0.5 and fromPoint or toPoint,
        segmentIndex = i,
        xnorm = clamp01(xnorm),
        distanceAlongRoute = target,
        distSq = 0,
      }
    end
  end

  local lastPoint = points[#points]
  return {
    pos = vec3(lastPoint.pos),
    fromPoint = lastPoint.prev or lastPoint,
    toPoint = lastPoint,
    nearestPoint = lastPoint,
    segmentIndex = #points,
    xnorm = 1,
    distanceAlongRoute = index.totalLength or 0,
    distSq = 0,
  }
end

function C:advanceAlongRoute(pos, meters, fwd, limitPoints, useAllPoints)
  local current = self:closestSnapResult(pos, useAllPoints)
  if not current then return nil end

  local targetDist = current.distanceAlongRoute + (fwd and meters or -meters)
  if limitPoints then
    for _,limitPoint in ipairs(limitPoints) do
      local limitLoc = self:routeLocationForPoint(limitPoint)
      if limitLoc then
        if fwd and limitLoc.distanceAlongRoute < targetDist then
          targetDist = math.max(current.distanceAlongRoute, limitLoc.distanceAlongRoute - 0.001)
        elseif not fwd and limitLoc.distanceAlongRoute > targetDist then
          targetDist = math.min(current.distanceAlongRoute, limitLoc.distanceAlongRoute + 0.001)
        end
      end
    end
  end

  return self:positionAtDistanceAlongRoute(targetDist, useAllPoints)
end

function C:distanceBetweenPositions(posA, posB, useAllPoints)
  local locA = self:closestSnapResult(posA, useAllPoints)
  local locB = self:closestSnapResult(posB, useAllPoints)
  return self:distanceBetweenRouteLocations(locA, locB)
end

function C:_snapshotWaypoint(snapshotPn, key, fallbackWp)
  local snap = snapshotPn and snapshotPn[key] or nil
  return {
    pos = snap and snap.pos and vec3(snap.pos) or vec3(fallbackWp.pos),
    normal = snap and snap.normal and vec3(snap.normal) or (fallbackWp.normal and vec3(fallbackWp.normal) or nil),
    location = snap and snap.location or nil,
  }
end

function C:_applySnapLocationToWaypoint(wp, loc)
  if not (wp and loc) then return end
  wp:setPos(loc.pos)
  local normalVec = self:normalForSnapResult(loc)
  if normalVec then
    wp:setNormal(normalVec)
  end
end

function C:_repairPacenoteProjectionEntries(entries)
  local totalLength = self:totalRouteLength()
  local minGap = minAdjacentWaypointDistance
  local lowerBound = 0

  for _,entry in ipairs(entries) do
    if entry.csLoc and entry.ceLoc then
      local csDist = entry.csLoc.distanceAlongRoute
      local ceDist = entry.ceLoc.distanceAlongRoute

      if csDist < lowerBound then
        csDist = lowerBound
      end

      if ceDist < csDist + minGap then
        local ceTarget = csDist + minGap
        local csTarget = ceDist - minGap
        local canMoveCe = ceTarget <= totalLength
        local canMoveCs = csTarget >= lowerBound

        if canMoveCe and (not canMoveCs or math.abs(ceTarget - ceDist) <= math.abs(csDist - csTarget)) then
          ceDist = ceTarget
        elseif canMoveCs then
          csDist = csTarget
        else
          ceDist = math.min(totalLength, ceTarget)
          csDist = math.max(lowerBound, ceDist - minGap)
        end
      end

      if ceDist > totalLength then
        ceDist = totalLength
        csDist = math.max(lowerBound, ceDist - minGap)
      end

      entry.csLoc = self:positionAtDistanceAlongRoute(csDist, true) or entry.csLoc
      entry.ceLoc = self:positionAtDistanceAlongRoute(ceDist, true) or entry.ceLoc
      lowerBound = math.min(totalLength, entry.ceLoc.distanceAlongRoute + minGap)
    end
  end
end

function C:reprojectPacenoteWaypointsFromSnapshot(notebook, snapshot)
  if not notebook or not notebook.pacenotes then return end

  local entries = {}
  local snapshotPacenotes = snapshot and snapshot.pacenotes or {}

  for _,pn in ipairs(notebook.pacenotes.sorted) do
    if not pn.missing then
      local wpCs = pn:getCornerStartWaypoint()
      local wpCe = pn:getCornerEndWaypoint()
      if wpCs and wpCe then
        local pnSnapshot = snapshotPacenotes[pn.id]
        local csSnapshot = self:_snapshotWaypoint(pnSnapshot, 'cs', wpCs)
        local ceSnapshot = self:_snapshotWaypoint(pnSnapshot, 'ce', wpCe)
        table.insert(entries, {
          pn = pn,
          wpCs = wpCs,
          wpCe = wpCe,
          csLoc = self:closestSnapResult(csSnapshot.pos, true),
          ceLoc = self:closestSnapResult(ceSnapshot.pos, true),
        })
      end
    end
  end

  self:_repairPacenoteProjectionEntries(entries)

  for _,entry in ipairs(entries) do
    if entry.csLoc then
      self:_applySnapLocationToWaypoint(entry.wpCs, entry.csLoc)
    end
    if entry.ceLoc then
      self:_applySnapLocationToWaypoint(entry.wpCe, entry.ceLoc)
    end

    self:updateHalfpoint(entry.pn)
    entry.pn:invalidateCamPosCache()
  end

  if notebook.autofillDistanceCalls then
    notebook:autofillDistanceCalls()
  end
end

function C:reprojectPacenoteWaypoints(notebook, previousSnaproad, snapshot)
  if snapshot then
    return self:reprojectPacenoteWaypointsFromSnapshot(notebook, snapshot)
  end

  local fallbackSnapshot = { pacenotes = {} }
  if notebook and notebook.pacenotes then
    for _,pn in ipairs(notebook.pacenotes.sorted) do
      if not pn.missing then
        local wpCs = pn:getCornerStartWaypoint()
        local wpCe = pn:getCornerEndWaypoint()
        if wpCs and wpCe then
          fallbackSnapshot.pacenotes[pn.id] = {
            cs = {
              pos = vec3(wpCs.pos),
              normal = wpCs.normal and vec3(wpCs.normal) or nil,
              location = previousSnaproad and previousSnaproad:closestSnapResult(wpCs.pos, true) or nil,
            },
            ce = {
              pos = vec3(wpCe.pos),
              normal = wpCe.normal and vec3(wpCe.normal) or nil,
              location = previousSnaproad and previousSnaproad:closestSnapResult(wpCe.pos, true) or nil,
            },
          }
        end
      end
    end
  end

  return self:reprojectPacenoteWaypointsFromSnapshot(notebook, fallbackSnapshot)
end

function C:closestSnapResult(source_pos, useAllPoints)
  useAllPoints = useAllPoints or false

  if not useAllPoints and self.filter.enabled and self.filter.lowerLocation and self.filter.upperLocation then
    local lowerDist = self.filter.lowerLocation.distanceAlongRoute
    local upperDist = self.filter.upperLocation.distanceAlongRoute
    if lowerDist and upperDist and lowerDist <= upperDist then
      local routeLoc = self:closestSnapResult(source_pos, true)
      if not routeLoc or not routeLoc.distanceAlongRoute then return nil end

      local targetDist = math.max(lowerDist, math.min(routeLoc.distanceAlongRoute, upperDist))
      if math.abs(targetDist - routeLoc.distanceAlongRoute) > 0.0001 then
        routeLoc = self:positionAtDistanceAlongRoute(targetDist, true)
      end
      if routeLoc and routeLoc.pos then
        routeLoc.distSq = (routeLoc.pos - source_pos):squaredLength()
      end
      return routeLoc
    end
    return nil
  end

  local index = self:_indexForPoints(useAllPoints)
  local points = index.points
  if not points or #points == 0 then return nil end

  if #points == 1 or not index.kdTree then
    local point = points[1]
    return {
      pos = vec3(point.pos),
      point = point,
      nearestPoint = point,
      fromPoint = point,
      toPoint = point.next or point.prev,
      segmentIndex = 1,
      xnorm = 0,
      distanceAlongRoute = index.prefixDistances[1] or 0,
      distSq = (point.pos - source_pos):squaredLength(),
    }
  end

  local stableId = index.kdTree:findNearest(source_pos.x, source_pos.y, source_pos.z)
  local item = index.stableIdIndex[stableId]
  if not item then return nil end

  local itemIdx = item.idx
  local searchMin = math.max(1, itemIdx - segmentSearchWindow)
  local searchMax = math.min(#points - 1, itemIdx + segmentSearchWindow)
  local minDistSq = startingMinDist * startingMinDist
  local best = nil

  for i = searchMin, searchMax do
    local p1 = points[i]
    local p2 = points[i + 1]
    if p1 and p2 and ((not p1.id or not p2.id) or p2.id == p1.id + 1) then
      local distSq = source_pos:squaredDistanceToLineSegment(p1.pos, p2.pos)
      if distSq < minDistSq then
        local xnorm = clamp01(source_pos:xnormOnLine(p1.pos, p2.pos))
        local pos = vec3(lerp(p1.pos, p2.pos, xnorm))
        minDistSq = distSq
        best = {
          pos = pos,
          point = xnorm < 0.5 and p1 or p2,
          nearestPoint = xnorm < 0.5 and p1 or p2,
          fromPoint = p1,
          toPoint = p2,
          segmentIndex = i,
          xnorm = xnorm,
          distanceAlongRoute = (index.prefixDistances[i] or 0) + p1.pos:distance(p2.pos) * xnorm,
          distSq = distSq,
        }
      end
    end
  end

  return best or self:routeLocationForPoint(item.point)
end

-- source_pos - should be a vec3
function C:closestSnapPoint(source_pos, useAllPoints)
  local result = self:closestSnapResult(source_pos, useAllPoints)
  return result and result.nearestPoint or nil
end

function C:closestSnapPos(source_pos)
  local result = self:closestSnapResult(source_pos)
  if result then
    return result.pos
  else
    return source_pos
  end
end

-- function C:normalAlignPoints(point)
--   if not point then return nil, nil end
--
--   local fromPoint = nil
--   local toPoint = nil
--
--   if point.next then
--     fromPoint = point
--     toPoint = point.next
--   elseif point.prev then
--     toPoint = point.prev
--     fromPoint = point
--   else
--     toPoint = point + vec3(1,0,0)
--   end
--
--   return fromPoint, toPoint
-- end

function C:normalAlignPoints(point)
  return normals.normalAlignPoints(point)
end

-- function C:forwardNormalVec(point)
--   local fromPoint, toPoint = self:normalAlignPoints(point)
--   local normVec = rallyUtil.calculateForwardNormal(fromPoint.pos, toPoint.pos)
--   return vec3(normVec.x, normVec.y, normVec.z)
-- end

function C:forwardNormalVec(point)
  return normals.forwardNormalVec(point)
end

function C:pointsBackwards(fromPoint, steps, limitPoints)
  limitPoints = limitPoints or {}
  local toPoint = fromPoint

  for _ = 1,steps do
    local prevPoint = toPoint.prev
    if not prevPoint then return toPoint end

    for _,limitPoint in ipairs(limitPoints) do
      if prevPoint.id == limitPoint.id then
        return toPoint
      end
    end

    if prevPoint then
      toPoint = prevPoint
    end
  end
  return toPoint
end

function C:pointsForwards(fromPoint, steps, limitPoints)
  limitPoints = limitPoints or {}
  local toPoint = fromPoint

  for _ = 1,steps do
    local nextPoint = toPoint.next
    if not nextPoint then return toPoint end

    for _,lim in ipairs(limitPoints) do
      if nextPoint.id == lim.id then
        return toPoint
      end
    end

    if nextPoint then
      toPoint = nextPoint
    end
  end
  return toPoint
end

function C:distanceBackwards(fromPoint, meters, limitPoints)
  limitPoints = limitPoints or {}
  local toPoint = fromPoint
  local dist = 0

  while true do
    local prevPoint = toPoint.prev
    if prevPoint then
      dist = dist + vec3(toPoint.pos):distance(vec3(prevPoint.pos))

      for _,lim in ipairs(limitPoints) do
        if prevPoint.id == lim.id then
          return toPoint
        end
      end

      toPoint = prevPoint

      if dist > meters then
        return toPoint
      end
    else
      return toPoint
    end
  end
end

function C:distanceBackwardsResult(fromPos, meters, limitPoints)
  return self:advanceAlongRoute(fromPos, meters, false, limitPoints)
end

function C:distanceForwards(fromPoint, meters, limitPoints)
  limitPoints = limitPoints or {}
  local toPoint = fromPoint
  local dist = 0

  while true do
    local nextPoint = toPoint.next
    if nextPoint then
      dist = dist + vec3(toPoint.pos):distance(vec3(nextPoint.pos))

      for _,lim in ipairs(limitPoints) do
        if nextPoint.id == lim.id then
          -- break
          return toPoint
        end
      end

      toPoint = nextPoint

      if dist > meters then
        -- break
        return toPoint
      end
    else
      -- break
      return toPoint
    end
  end

  -- return toPoint
end

function C:distanceForwardsResult(fromPos, meters, limitPoints)
  return self:advanceAlongRoute(fromPos, meters, true, limitPoints)
end

-- function C:closestPointBackwards(sourcePoint, notebook)
-- end

function C:firstSnapPoint()
  return self:_allPoints()[1]
end

function C:prevSnapPos(srcPos)
  return self:prevSnapPoint(srcPos).pos
end

function C:prevSnapPoint(srcPos)
  local snapPoint = self:closestSnapPoint(srcPos)
  if not snapPoint then return nil end

  local points = self:_operativePoints()
  if not points or #points == 0 then return snapPoint end

  -- check if we are at the beginning of the points list
  if snapPoint.id == points[1].id then
    return snapPoint
  elseif snapPoint.prev then
    local newPoint = snapPoint.prev
    return newPoint
  else
    return snapPoint
  end
end

function C:nextSnapPos(srcPos)
  return self:nextSnapPoint(srcPos).pos
end

function C:nextSnapPoint(srcPos)
  local snapPoint = self:closestSnapPoint(srcPos)
  if not snapPoint then return nil end

  local points = self:_operativePoints()
  if not points or #points == 0 then return snapPoint end

  -- check if we are at the end of the points list
  if snapPoint.id == points[#points].id then
    return snapPoint
  elseif snapPoint.next then
    local newPoint = snapPoint.next
    return newPoint
  else
    return snapPoint
  end
end

function C:updateHalfpoint(pn)
  if not pn or pn.missing then return end

  local wp_cs = pn:getCornerStartWaypoint()
  local wp_ce = pn:getCornerEndWaypoint()
  if not (wp_cs and wp_ce) then return end

  -- Always use all points for halfpoint calculation, ignoring current filtering
  local loc_cs = self:closestSnapResult(wp_cs.pos, true)
  local loc_ce = self:closestSnapResult(wp_ce.pos, true)
  if not (loc_cs and loc_ce) then return end

  local dist = (loc_cs.distanceAlongRoute + loc_ce.distanceAlongRoute) * 0.5
  local loc_half = self:positionAtDistanceAlongRoute(dist, true)
  pn.halfpoint = loc_half and loc_half.nearestPoint or nil
  pn.halfpointLocation = loc_half
  pn.halfpointPos = loc_half and loc_half.pos or nil

  -- Invalidate camera position cache since halfpoint changed
  pn:invalidateCamPosCache()
end

function C:setPartitionToPacenote(pn)
  if not pn or pn.missing then return end

  self.partition.pacenote = pn
  local locStart = self:closestSnapResult(pn:getCornerStartWaypoint().pos, true)
  local locCe = self:closestSnapResult(pn:getCornerEndWaypoint().pos, true)
  if not (locStart and locCe) then return end
  local pointStart = locStart.fromPoint or locStart.nearestPoint
  local pointCe = locCe.toPoint or locCe.nearestPoint
  self:updateHalfpoint(pn)
  self:_partitionPoints(pointStart, pointCe, locStart, locCe)
end

function C:clearPartition()
  self.partition.enabled = false
  self.partition.pacenote = nil
  self.partition.before_points = {}
  self.partition.focus_points = {}
  self.partition.after_points = {}
  self.partition.fromLocation = nil
  self.partition.toLocation = nil
end

function C:_partitionPoints(fromPoint, toPoint, fromLoc, toLoc)
  if not (fromPoint and toPoint) then
    return
  end

  fromLoc = fromLoc or self:routeLocationForPoint(fromPoint)
  toLoc = toLoc or self:routeLocationForPoint(toPoint)
  if fromLoc and toLoc and self:compareRouteLocations(toLoc, fromLoc) == -1 then
    fromPoint, toPoint = toPoint, fromPoint
    fromLoc, toLoc = toLoc, fromLoc
  end

  -- reset state
  self.partition.enabled = true
  self.partition.before_points = {}
  self.partition.focus_points = {}
  self.partition.after_points = {}
  self.partition.corner_call_points = {}
  self.partition.fromLocation = fromLoc
  self.partition.toLocation = toLoc
  self:_clearPointCachedPartitions()

  -- fill the focus points
  local currPoint = fromPoint
  table.insert(self.partition.focus_points, currPoint)
  currPoint.partition = self.partition.focus_points

  while true do
    local nextPoint = currPoint.next

    if nextPoint then
      table.insert(self.partition.focus_points, nextPoint)
      nextPoint.partition = self.partition.focus_points

      if nextPoint.id >= toPoint.id then
        break
      end

      currPoint = nextPoint
    else
      break
    end
  end

  -- maybe fill the corner call points
  -- if self.show_corner_calls and self.partition.pacenote then
  --   self.partition.corner_call_points = {
  --     points_at_to_cs = {},
  --     points_cs_to_ce = {},
  --     groups = {},
  --   }

  --   local wp_cs = self.partition.pacenote:getCornerStartWaypoint()
  --   local point_cs = self:closestSnapPoint(wp_cs.pos)
  --   for i,point in ipairs(self.partition.focus_points) do
  --     if point_cs and point.id < point_cs.id then
  --       table.insert(self.partition.corner_call_points.points_at_to_cs, point)
  --     else
  --       table.insert(self.partition.corner_call_points.points_cs_to_ce, point)
  --     end
  --   end

  --   local groups = self:groupPointsByCornerCall(self.partition.corner_call_points.points_cs_to_ce)
  --   self.partition.corner_call_points.groups = groups
  -- end

  -- fill the before points
  local points = self:_allPoints()
  local currPoint = points[1]
  local toPoint = self.partition.focus_points[1]
  table.insert(self.partition.before_points, currPoint)
  while true do
    local nextPoint = currPoint.next

    if nextPoint then
      if nextPoint.id == toPoint.id then
        break
      else
        table.insert(self.partition.before_points, nextPoint)
      end

      currPoint = nextPoint
    else
      break
    end
  end

  -- fill the after points
  local points = self:_allPoints()
  local currPoint = self.partition.focus_points[#self.partition.focus_points]
  if currPoint.next then
    local toPoint = points[#points]
    while true do
      local nextPoint = currPoint.next

      if nextPoint then
        table.insert(self.partition.after_points, nextPoint)
        if nextPoint.id == toPoint.id then
          break
        end
        currPoint = nextPoint
      else
        break
      end
    end
  end
end

function C:clearAll()
  self.partition_all_state.enabled = false
  self.partition_all_state.notebook = nil
  self.partition_all_state.partitions = {}
  self.partition_all_state.pacenote_partitions = {}
  self:clearFilter()
  self:_clearPointCachedPartitions()
end

function C:_clearPointCachedPartitions()
  for _,point in ipairs(self:_allPoints()) do
    point.partition = nil
  end
end

function C:partitionAllPacenotes(notebook)
  -- reset state
  self.partition_all_state.enabled = true
  self.partition_all_state.notebook = notebook
  self.partition_all_state.partitions = {}
  self.partition_all_state.pacenote_partitions = {}
  self:_clearPointCachedPartitions()

  local pn_partitions = {}
  local partitions = {}

  local pt_curr = self:_allPoints()[1]

  local partition = {}
  local pn_partition = {}
  local prevCeLoc = nil

  for _,pn_curr in ipairs(notebook.pacenotes.sorted) do
    local wp_cs = pn_curr:getCornerStartWaypoint()
    local wp_ce = pn_curr:getCornerEndWaypoint()
    local pos_cs = wp_cs.pos
    local pos_ce = wp_ce.pos
    local loc_cs = self:closestSnapResult(pos_cs, true)
    local loc_ce = self:closestSnapResult(pos_ce, true)
    if loc_cs and loc_ce and self:compareRouteLocations(loc_ce, loc_cs) == -1 then
      loc_cs, loc_ce = loc_ce, loc_cs
    end
    wp_cs._driveline_location = loc_cs
    wp_ce._driveline_location = loc_ce
    wp_cs._driveline_point = loc_cs and loc_cs.nearestPoint or nil
    wp_ce._driveline_point = loc_ce and loc_ce.nearestPoint or nil

    partition = {}
    pn_partition = {}
    partition.limitBackLocation = prevCeLoc
    partition.limitFwdLocation = loc_cs
    pn_partition.limitBackLocation = loc_cs
    pn_partition.limitFwdLocation = loc_ce

    while pt_curr and loc_cs and self:routeLocationForPoint(pt_curr).distanceAlongRoute < loc_cs.distanceAlongRoute do
      table.insert(partition, pt_curr)
      pt_curr.partition = partition
      pt_curr = pt_curr.next
    end

    while pt_curr and loc_ce and self:routeLocationForPoint(pt_curr).distanceAlongRoute <= loc_ce.distanceAlongRoute do
      table.insert(pn_partition, pt_curr)
      pt_curr = pt_curr.next
    end

    partition.pacenote_after = pn_curr
    table.insert(partitions, partition)
    table.insert(pn_partitions, pn_partition)
    prevCeLoc = loc_ce
  end

  -- add points after the last pacenote to it's own partition
  partition = {}
  partition.limitBackLocation = prevCeLoc
  partition.limitFwdLocation = nil
  while pt_curr do
    table.insert(partition, pt_curr)
    pt_curr.partition = partition
    pt_curr = pt_curr.next
  end
  table.insert(partitions, partition)

  -- print('partitions:')
  -- for i,p in ipairs(partitions) do
  --   local s = ''
  --   for i,pt in ipairs(p) do
  --     s = s..', '..tostring(pt.id)
  --   end
  --   print(s)
  -- end

  self.partition_all_state.partitions = partitions
  self.partition_all_state.pacenote_partitions = pn_partitions
end

function C:clearFilter()
  self.filter.enabled = false
  self.filter.points = {}
  self.filter.lowerLocation = nil
  self.filter.upperLocation = nil
  self:_invalidateFilterPointIndex()
end

function C:setFilterToAllPartitions()
  if not self.partition_all_state.enabled then return end

  self.filter.enabled = true
  self.filter.points = {}
  self.filter.lowerLocation = nil
  self.filter.upperLocation = nil

  local partitions = self.partition_all_state.partitions

  for i,partition in ipairs(partitions) do
    for i,point in ipairs(partition) do
      table.insert(self.filter.points, point)
    end
  end
  self:_invalidateFilterPointIndex()
end

function C:setFilterPartitionPoint(point)
  if not self.partition_all_state.enabled then return end

  self.filter.enabled = true
  self.filter.points = {}
  self.filter.lowerLocation = nil
  self.filter.upperLocation = nil

  local partition = point.partition
  if not partition then
    self:_invalidateFilterPointIndex()
    return
  end

  for i,point in ipairs(partition) do
    table.insert(self.filter.points, point)
  end
  self:_invalidateFilterPointIndex()
end

function C:setFilter(wp)
  if not wp then return end
  -- if not wp then
  --   self.filter.enabled = false
  --   self.filter.points = {}
  --   self:clearPartition()
  --   return
  -- end

  -- self.filter.points = {}

  -- filtering modes:
  -- * AT is selected
  --   ->  back: cant go past prev AT
  --   ->  fwd:  cant go past self CS OR next note AT
  -- X CS is selected v1
  --   -> back: cant go past self AT OR cant go past prev CE
  --   -> fwd:  cant go past self CE
  -- * CS is selected v2 - moving CS back also moves AT back
  --   -> back: cant go past prev CE AND cant go past prev AT + 1
  --   -> fwd:  cant go past self CE
  -- * CE is selected
  --   -> back: cant go past self CS
  --   -> fwd:  cant go past next CS

  local notebook = wp.pacenote.notebook
  local pn_prev, pn_sel, pn_next = notebook:getAdjacentPacenoteSet(wp.pacenote.id)

  local limitBackPoint = nil
  local limitFwdPoint = nil
  local limitBackLoc = nil
  local limitFwdLoc = nil

  if wp:isCs() then
    if pn_prev then
      local prev_wp_ce = pn_prev:getCornerEndWaypoint()
      if prev_wp_ce then
        local loc = self:closestSnapResult(prev_wp_ce.pos, true)
        local point = loc and loc.nearestPoint or nil
        if loc then
          if limitBackLoc then
            if self:compareRouteLocations(limitBackLoc, loc) == -1 then
              limitBackLoc = loc
              limitBackPoint = point
            end
          else
            limitBackLoc = loc
            limitBackPoint = point
          end
        end
      end
    end

    -- CS forwards movement
    local wp_ce = pn_sel:getCornerEndWaypoint()
    if wp_ce then
      limitFwdLoc = self:closestSnapResult(wp_ce.pos, true)
      limitFwdPoint = limitFwdLoc and limitFwdLoc.nearestPoint or nil
    end
  elseif wp:isCe() then
    -- CE backwards movement
    local wp_cs = pn_sel:getCornerStartWaypoint()
    if wp_cs then
      limitBackLoc = self:closestSnapResult(wp_cs.pos, true)
      limitBackPoint = limitBackLoc and limitBackLoc.nearestPoint or nil
    end

    -- CE forwards movement
    if pn_next then
      local wp_cs_next = pn_next:getCornerStartWaypoint()
      if wp_cs_next then
        limitFwdLoc = self:closestSnapResult(wp_cs_next.pos, true)
        limitFwdPoint = limitFwdLoc and limitFwdLoc.nearestPoint or nil
      end
    end
  end

  local unfilteredPoints = self:_allPoints()

  limitBackPoint = limitBackPoint or unfilteredPoints[1]
  limitFwdPoint = limitFwdPoint or unfilteredPoints[#unfilteredPoints]
  limitBackLoc = limitBackLoc or self:routeLocationForPoint(limitBackPoint)
  limitFwdLoc = limitFwdLoc or self:routeLocationForPoint(limitFwdPoint)

  self.filter.enabled = true
  self.filter.points = {}

  local lowerDist = limitBackLoc and (limitBackLoc.distanceAlongRoute + minAdjacentWaypointDistance) or nil
  local upperDist = limitFwdLoc and (limitFwdLoc.distanceAlongRoute - minAdjacentWaypointDistance) or nil
  if lowerDist and upperDist and lowerDist <= upperDist then
    self.filter.lowerLocation = self:positionAtDistanceAlongRoute(lowerDist, true)
    self.filter.upperLocation = self:positionAtDistanceAlongRoute(upperDist, true)
  else
    self.filter.lowerLocation = nil
    self.filter.upperLocation = nil
  end

  for _,point in ipairs(unfilteredPoints) do
    local pointLoc = self:routeLocationForPoint(point)
    if pointLoc and lowerDist and upperDist
      and pointLoc.distanceAlongRoute > lowerDist
      and pointLoc.distanceAlongRoute < upperDist then
      table.insert(self.filter.points, point)
    end
  end
  self:_invalidateFilterPointIndex()

  -- self:_partitionPoints(self.filter.points[1], self.filter.points[#self.filter.points])
end

function C:setPartitionToFilter()
  if not self.filter.enabled then return end
  if self.filter.lowerLocation and self.filter.upperLocation then
    local fromPoint = self.filter.lowerLocation.fromPoint or self.filter.lowerLocation.nearestPoint
    local toPoint = self.filter.upperLocation.toPoint or self.filter.upperLocation.nearestPoint
    self:_partitionPoints(fromPoint, toPoint, self.filter.lowerLocation, self.filter.upperLocation)
    return
  end
  self:_partitionPoints(self.filter.points[1], self.filter.points[#self.filter.points])
end

function C:pointsForCameraPath(bufferBeforeMeters, bufferAfterMeters)
  if not self.partition.enabled then
    return nil
  end

  if #self.partition.focus_points == 0 then
    return nil
  end

  -- Find buffer points: 20m before corner start, 10m after corner end
  bufferBeforeMeters = bufferBeforeMeters or 40
  bufferAfterMeters = bufferAfterMeters or 20

  local cornerStartLoc = self.partition.fromLocation or self:routeLocationForPoint(self.partition.focus_points[1])
  local cornerEndLoc = self.partition.toLocation or self:routeLocationForPoint(self.partition.focus_points[#self.partition.focus_points])
  if not (cornerStartLoc and cornerEndLoc) then return nil end

  local startLoc = self:positionAtDistanceAlongRoute(cornerStartLoc.distanceAlongRoute - bufferBeforeMeters, true)
  local endLoc = self:positionAtDistanceAlongRoute(cornerEndLoc.distanceAlongRoute + bufferAfterMeters, true)
  local startPoint = startLoc and (startLoc.fromPoint or startLoc.nearestPoint)
  local endPoint = endLoc and (endLoc.toPoint or endLoc.nearestPoint)
  if not (startPoint and endPoint) then return nil end

  -- Collect all points from startPoint to endPoint
  local cameraPathPoints = {}
  local currentPoint = startPoint

  while currentPoint do
    table.insert(cameraPathPoints, currentPoint)

    if currentPoint.id == endPoint.id then
      break
    end

    currentPoint = currentPoint.next

    -- Safety check to prevent infinite loop
    if not currentPoint then
      break
    end
  end

  return cameraPathPoints
end

function C:playCameraPath()
  self.cameraPathPlayer:play()
end

function C:stopCameraPath()
  self.cameraPathPlayer:stop()
end

function C:partitionAllEnabled()
  return self.partition_all_state.enabled
end

function C:toggleCornerCalls()
  self.show_corner_calls = not self.show_corner_calls
  if self.partition.pacenote then
    self:setPartitionToPacenote(self.partition.pacenote)
  end
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end

