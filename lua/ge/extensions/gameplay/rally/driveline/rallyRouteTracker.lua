-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

-- The route corridor is a lateral band around the immutable static route
-- centerline. Leaving it freezes the recovery anchor until the vehicle comes
-- back inside the corridor.
local defaultCorridorHalfWidthMeters = 8

-- Re-entry is just inside the corridor so exact-boundary samples do not satisfy
-- both the off-route and on-route thresholds.
local reEntryInsideCorridorMarginMeters = 0.1

-- Initial tracker tuning. Rally Toolbox can adjust corridor width at runtime;
-- recoveryBackoffDistanceMeters is intentionally small so recovery lands near departure.
local defaultOptions = {
  -- Static-route segments to check behind the previous segment during normal local projection.
  searchBehind = 4,
  -- Static-route segments to check ahead of the previous segment during normal local projection.
  searchAhead = 8,
  -- Corridor half-width. The vehicle is considered off-route at or beyond this lateral distance.
  offRouteDistance = defaultCorridorHalfWidthMeters,
  -- Re-entry threshold, kept just inside offRouteDistance to avoid exact-boundary ambiguity.
  onRouteDistance = defaultCorridorHalfWidthMeters - reEntryInsideCorridorMarginMeters,
  -- Consecutive update ticks required before switching on-route/off-route state.
  transitionTicks = 2,
  -- Distance behind the tracked departure/current point used for recovery placement.
  recoveryBackoffDistanceMeters = 3,
  -- Largest normal forward progress jump accepted before falling back to a full-route projection.
  maxForwardJump = 80,
  -- Largest normal backward progress jump accepted before falling back to a full-route projection.
  maxBackwardJump = 20,
}

local function copyOptions(options)
  local ret = {}
  for k, v in pairs(defaultOptions) do
    ret[k] = v
  end
  if options then
    for k, v in pairs(options) do
      ret[k] = v
    end
    if options.recoveryBackoffDistance and not options.recoveryBackoffDistanceMeters then
      ret.recoveryBackoffDistanceMeters = options.recoveryBackoffDistance
    end
  end
  return ret
end

local function clamp01(v)
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

local function distToTargetAtSegment(path, segmentIdx, xnorm)
  local a = path and path[segmentIdx]
  local b = path and path[segmentIdx + 1]
  if not a or not b then return nil end
  return a.distToTarget - (a.distToTarget - b.distToTarget) * xnorm
end

local function posAtSegment(path, segmentIdx, xnorm)
  local a = path and path[segmentIdx]
  local b = path and path[segmentIdx + 1]
  if not a or not b then return nil end
  return vec3(a.pos) * (1 - xnorm) + vec3(b.pos) * xnorm
end

local function projectInRange(path, pos, firstIdx, lastIdx)
  local bestDistSq = math.huge
  local bestIdx = nil
  local bestXnorm = 0

  for i = firstIdx, lastIdx do
    local a = path[i]
    local b = path[i + 1]
    if a and b then
      local distSq = pos:squaredDistanceToLineSegment(a.pos, b.pos)
      if distSq < bestDistSq then
        bestDistSq = distSq
        bestIdx = i
        bestXnorm = clamp01(pos:xnormOnLine(a.pos, b.pos))
      end
    end
  end

  if not bestIdx then return nil end

  local distToTarget = distToTargetAtSegment(path, bestIdx, bestXnorm)
  local routePos = posAtSegment(path, bestIdx, bestXnorm)
  return {
    segmentIdx = bestIdx,
    xnorm = bestXnorm,
    distSq = bestDistSq,
    lateralDist = math.sqrt(bestDistSq),
    distToTarget = distToTarget,
    routePos = routePos,
  }
end

local function projectFull(path, pos)
  if not path or #path < 2 then return nil end
  return projectInRange(path, pos, 1, #path - 1)
end

-- Diagnostic-only: shallow copy of a projection candidate for debug capture.
local function copyCandidate(p)
  if not p then return nil end
  return {
    segmentIdx = p.segmentIdx,
    xnorm = p.xnorm,
    distToTarget = p.distToTarget,
    lateralDist = p.lateralDist,
    routePos = p.routePos and vec3(p.routePos) or nil,
  }
end

local function projectLocal(path, pos, segmentIdx, options)
  if not path or #path < 2 then return nil end
  if not segmentIdx then return projectFull(path, pos) end

  local firstIdx = math.max(1, segmentIdx - options.searchBehind)
  local lastIdx = math.min(#path - 1, segmentIdx + options.searchAhead)
  local projection = projectInRange(path, pos, firstIdx, lastIdx)
  if projection then return projection end

  return projectFull(path, pos)
end

function C:init(path, options)
  self.path = path
  self.options = copyOptions(options)
  -- Diagnostic-only capture flag; when false the extra projectFull is never run.
  self.debugCaptureEnabled = false
  self:reset()
end

function C:reset(pos)
  self.segmentIdx = nil
  self.xnorm = 0
  self.distToTarget = nil
  self.distFromStart = nil
  self.routePos = nil
  self.lateralDist = nil
  self.state = 'unknown'
  self.offRouteTicks = 0
  self.onRouteTicks = 0
  self.lastProjection = nil
  self.lastRecoverableDistToTarget = nil
  self.lastRecoverableRoutePos = nil
  self.departure = nil
  self.recoveryDistToTarget = nil

  -- Diagnostic-only debug capture fields (do not affect behavior).
  self.debugLastProjectionSource = nil
  self.debugLocalCandidate = nil
  self.debugFullCandidate = nil
  self.debugWindow = nil

  if pos then
    self:update(pos, { allowJump = true, forceFullSearch = true })
  end
end

function C:setDebugCapture(enabled)
  self.debugCaptureEnabled = enabled and true or false
end

function C:setPath(path)
  self.path = path
  self:reset()
end

function C:setCorridorWidth(width)
  width = tonumber(width)
  if not width then return end

  self.options.offRouteDistance = clamp(width, 0.1, 15)
  self.options.onRouteDistance = math.max(self.options.offRouteDistance - reEntryInsideCorridorMarginMeters, 0.1)
end

function C:getCorridorWidth()
  return self.options.offRouteDistance
end

function C:getOptions()
  return self.options
end

function C:project(pos, options)
  options = options or {}
  if options.forceFullSearch then
    return projectFull(self.path, pos)
  end
  return projectLocal(self.path, pos, self.segmentIdx, self.options)
end

function C:_acceptProjection(projection, allowJump)
  if not projection or not projection.distToTarget then return false end
  if allowJump or not self.distToTarget then return true end

  local deltaFromStart = (self.distToTarget or projection.distToTarget) - projection.distToTarget
  if deltaFromStart > self.options.maxForwardJump then return false end
  if deltaFromStart < -self.options.maxBackwardJump then return false end
  return true
end

function C:_updateRecoveryCandidate(pos, projection)
  self.lastRecoverableDistToTarget = projection.distToTarget
  self.lastRecoverableRoutePos = projection.routePos and vec3(projection.routePos) or nil
  local recoveryDist = projection.distToTarget + self.options.recoveryBackoffDistanceMeters
  local maxDist = self.path and self.path[1] and self.path[1].distToTarget or recoveryDist
  self.recoveryDistToTarget = math.min(recoveryDist, maxDist)
end

function C:_snapshotDeparture(pos, projection)
  local recoveryDist = self.recoveryDistToTarget
  if not recoveryDist and projection and projection.distToTarget then
    local maxDist = self.path and self.path[1] and self.path[1].distToTarget or projection.distToTarget
    recoveryDist = math.min(projection.distToTarget + self.options.recoveryBackoffDistanceMeters, maxDist)
  end

  self.departure = {
    distToTarget = projection and projection.distToTarget or self.distToTarget,
    routePos = projection and projection.routePos and vec3(projection.routePos) or nil,
    vehiclePos = pos and vec3(pos) or nil,
    lateralDist = projection and projection.lateralDist or self.lateralDist,
    segmentIdx = projection and projection.segmentIdx or self.segmentIdx,
  }
  self.recoveryDistToTarget = recoveryDist
end

-- Diagnostic-only: mirrors projectLocal's window math for debug capture.
function C:_computeDebugWindow(segmentIdx, forceFullSearch)
  if forceFullSearch or not segmentIdx then
    return { fullSearch = true }
  end
  local pathLen = self.path and #self.path or 0
  return {
    firstIdx = math.max(1, segmentIdx - self.options.searchBehind),
    lastIdx = math.min(pathLen - 1, segmentIdx + self.options.searchAhead),
  }
end

function C:update(pos, updateOptions)
  updateOptions = updateOptions or {}
  if not pos then return nil end

  -- Snapshot segmentIdx before it is overwritten so the debug window reflects
  -- the window actually searched this frame.
  local prevSegmentIdx = self.segmentIdx
  local debugWindow = self:_computeDebugWindow(prevSegmentIdx, updateOptions.forceFullSearch)

  local projection = self:project(pos, updateOptions)
  local localProjection = projection
  local fallbackFull = nil
  local projectionSource = 'local'
  if not self:_acceptProjection(projection, updateOptions.allowJump or updateOptions.forceFullSearch) then
    projection = projectFull(self.path, pos)
    fallbackFull = projection
    projectionSource = 'full'
    if not self:_acceptProjection(projection, true) then
      -- Held path: previous projection is reused. Capture diagnostics only.
      self.debugLastProjectionSource = 'held'
      self.debugWindow = debugWindow
      self.debugLocalCandidate = copyCandidate(localProjection)
      self.debugFullCandidate = copyCandidate(fallbackFull)
      return self.lastProjection
    end
  end
  if not projection then return nil end

  -- Diagnostic-only capture (no effect on behavior). The extra projectFull for
  -- fullCandidate comparison only runs when debug capture is enabled.
  self.debugLastProjectionSource = projectionSource
  self.debugWindow = debugWindow
  self.debugLocalCandidate = copyCandidate(localProjection)
  if fallbackFull then
    self.debugFullCandidate = copyCandidate(fallbackFull)
  elseif self.debugCaptureEnabled then
    self.debugFullCandidate = copyCandidate(projectFull(self.path, pos))
  else
    self.debugFullCandidate = nil
  end

  local startDistToTarget = self.path and self.path[1] and self.path[1].distToTarget or 0

  self.segmentIdx = projection.segmentIdx
  self.xnorm = projection.xnorm
  self.distToTarget = projection.distToTarget
  self.distFromStart = startDistToTarget - projection.distToTarget
  self.routePos = projection.routePos
  self.lateralDist = projection.lateralDist
  self.lastProjection = projection

  local wasOffRoute = self.state == 'offRoute'
  if projection.lateralDist >= self.options.offRouteDistance then
    self.offRouteTicks = self.offRouteTicks + 1
    self.onRouteTicks = 0
    if self.offRouteTicks >= self.options.transitionTicks and self.state ~= 'offRoute' then
      self.state = 'offRoute'
      self:_snapshotDeparture(pos, projection)
    end
  elseif projection.lateralDist <= self.options.onRouteDistance then
    self.onRouteTicks = self.onRouteTicks + 1
    self.offRouteTicks = 0
    if self.onRouteTicks >= self.options.transitionTicks then
      self.state = 'onRoute'
      if wasOffRoute then
        self.departure = nil
      end
      self:_updateRecoveryCandidate(pos, projection)
    elseif self.state ~= 'offRoute' then
      self:_updateRecoveryCandidate(pos, projection)
    end
  end

  if self.state == 'unknown' then
    self.state = projection.lateralDist <= self.options.offRouteDistance and 'onRoute' or 'offRoute'
    if self.state == 'onRoute' then
      self:_updateRecoveryCandidate(pos, projection)
    else
      self:_snapshotDeparture(pos, projection)
    end
  end

  return projection
end

function C:getRecoveryDistToTarget(backoffDistance)
  local baseDist = nil
  if self.state == 'offRoute' then
    baseDist = self.departure and self.departure.distToTarget or self.lastRecoverableDistToTarget or self.distToTarget
  else
    baseDist = self.lastRecoverableDistToTarget or self.distToTarget
  end
  if not baseDist then return nil end

  local maxDist = self.path and self.path[1] and self.path[1].distToTarget or baseDist
  return math.min(baseDist + (backoffDistance or self.options.recoveryBackoffDistanceMeters), maxDist)
end

function C:getState()
  return {
    state = self.state,
    segmentIdx = self.segmentIdx,
    xnorm = self.xnorm,
    distToTarget = self.distToTarget,
    distFromStart = self.distFromStart,
    routePos = self.routePos,
    lateralDist = self.lateralDist,
    offRouteDistance = self.options.offRouteDistance,
    onRouteDistance = self.options.onRouteDistance,
    lastRecoverableDistToTarget = self.lastRecoverableDistToTarget,
    lastRecoverableRoutePos = self.lastRecoverableRoutePos,
    recoveryDistToTarget = self:getRecoveryDistToTarget(),
    departure = self.departure,
    projectionSource = self.debugLastProjectionSource,
    localCandidate = self.debugLocalCandidate,
    fullCandidate = self.debugFullCandidate,
    window = self.debugWindow,
    searchBehind = self.options.searchBehind,
    searchAhead = self.options.searchAhead,
  }
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
