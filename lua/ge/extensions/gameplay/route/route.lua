-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local onPathDist = 18
local pathJobMaxDt = 0.00000000001

local function logRouteJobDuration(label, t0)
  log('I', 'route', string.format('%s: route calculated in %.3f s', label, os.clock() - t0))
end

local routeDebugPathJobs = true
local function debugLog(...)
  if not routeDebugPathJobs then return end
  local n = select('#', ...)
  if n == 0 then return end
  local parts = { ... }
  local s = tostring(parts[1])
  for i = 2, n do
    s = s .. ' ' .. tostring(parts[i])
  end
  log('I', 'route', s)
end
debugLog = nop

function C:init()
  self.path = {}
  self.dirMult = 1e3
  self.distance = 0
  self._pathMultiJobHandle = nil
  self._recalculateJobHandle = nil
  self._recalculateAnchorPos = nil
end

function C:setRouteParams(cutOffDrivability, dirMult, penaltyAboveCutoff, penaltyBelowCutoff, wD, wZ)
  self.cutOffDrivability = cutOffDrivability
  self.dirMult = dirMult or 1e3
  self.penaltyAboveCutoff = penaltyAboveCutoff
  self.penaltyBelowCutoff = penaltyBelowCutoff
  self.wD = wD
  self.wZ = wZ
  --log("I","",dumps("setRouteParams", cutOffDrivability, dirMult, penaltyAboveCutoff, penaltyBelowCutoff, wD, wZ))
end

local function fixStartEnd(p, a, b)
  profilerPushEvent("Route - fixStartEnd")
  local xnorm = p.pos:xnormOnLine(a.pos, b.pos)
  if xnorm > 0 then
    a.pos = lerp(a.pos, b.pos, xnorm)
    a.wp = nil
  end

  a.distToTarget = a.pos:distance(b.pos) + (b.distToTarget or 0)

  profilerPopEvent("Route - fixStartEnd")
end

function C:stepAhead(stepDist, reset) -- returns data from a distance along the route (and also saves the last position, to optimize for looping)
  if not self.lastDist or reset then
    self.lastIndexAtDist = 1
    self.lastDist = 0
  end
  if not self.path[2] then return end

  local pathCount = #self.path
  stepDist = stepDist + self.lastDist
  for i = self.lastIndexAtDist, pathCount - 1 do
    local v1, v2 = self.path[i], self.path[i + 1]
    local length = v1.distToTarget - v2.distToTarget

    if stepDist > length then
      stepDist = stepDist - length
    else
      self.lastDist = stepDist
      self.lastIndexAtDist = i
      local xnorm = clamp(stepDist / (length + 1e-30), 0, 1)
      return {n1 = v1.wp, n2 = v2.wp, idx = i, pos = linePointFromXnorm(v1.pos, v2.pos, xnorm), xnorm = xnorm}
    end
  end

  return {n1 = self.path[pathCount - 1].wp, n2 = self.path[pathCount].wp, idx = pathCount - 1, pos = self.path[pathCount].pos, xnorm = 1}
end

function C:calcDistance()
  local dist = 0
  if self.path[1] then self.path[1].distToTarget = 0 end
  if not self.path[2] then
    self.distance = dist
    return dist
  end
  for i = #self.path, 2, -1 do
    self.path[i].distToTarget = dist
    dist = dist + self.path[i].pos:distance(self.path[i - 1].pos)
  end
  self.path[1].distToTarget = dist
  self.distance = dist

  return dist
end

function C:setupPath(fromPos, toPos)
  self:setupPathMulti({fromPos, toPos})
end

function C:setupPathMultiWaypoints(wpList)
  profilerPushEvent("Route - setupPathMultiWaypoints")
  for i = 1, #wpList-1 do
    local path = map.getPath(wpList[i], wpList[i + 1], self.cutOffDrivability, self.dirMult, self.penaltyAboveCutoff, self.penaltyBelowCutoff)
    local pathLen = #self.path
    for j, pwp in ipairs(path) do
      if not self.path[pathLen] or self.path[pathLen].wp ~= pwp then
        table.insert(self.path, {pos = map.getMap().nodes[pwp].pos, wp = pwp, linkCount = map.getNodeLinkCount(pwp)})
      end
    end
  end

  self:calcDistance()
  profilerPopEvent("Route - setupPathMultiWaypoints")
end

-- getPathFn(from, to) -> node path array (sync getPointToPointPath or job-based getPointToPointPathJob from a jobsystem coroutine)
-- Returns the built path table; does not assign self.path (so async jobs can swap only when finished).
local function runSetupPathMultiBuild(self, positions, getPathFn)
  profilerPushEvent("Route - setupPathMulti")
  local path = {}
  table.insert(path, {pos = vec3(positions[1]), wp = nil})
  for i = 1, #positions-1 do
    local from, to = positions[i], positions[i+1]
    profilerPushEvent("Route - get point to point")
    local nodePath = getPathFn(from, to)
    profilerPopEvent("Route - get point to point")
    local lastIdx = #path
    for _, p in ipairs(nodePath) do
      table.insert(path, {pos = map.getMap().nodes[p].pos, wp = p, linkCount = map.getNodeLinkCount(p)})
    end
    table.insert(path, {pos = vec3(to), wp = nil, fixed = true})
    if #path >= 3 and #nodePath >= 2 then
      fixStartEnd(path[lastIdx], path[lastIdx+1], path[lastIdx+2])
    end
    if #path >= 3 and #nodePath >= 2 then
      fixStartEnd(path[#path], path[#path-1], path[#path-2])
    end
  end

  -- merge too-close nodes into one and preserve fields wp and fixed
  local closeDistSquared = 1
  local newPath = {path[1]}
  local last = path[1]
  for i = 2, #path do
    local cur = path[i]
    if cur.pos:squaredDistance(last.pos) <= closeDistSquared then
      last.wp = last.wp or cur.wp
      last.fixed = last.fixed or cur.fixed
    else
      last = cur
      table.insert(newPath, cur)
    end
  end
  path = newPath

  if #path >= 3 then
    fixStartEnd(path[1], path[2], path[3])
    if path[1].pos:squaredDistance(path[2].pos) < onPathDist * onPathDist then
      table.remove(path, 1)
    end
  end
  if #path >= 3 then
    fixStartEnd(path[#path], path[#path-1], path[#path-2])
  end

  profilerPopEvent("Route - setupPathMulti")
  return path
end

local function runSetupPathMulti(self, positions, getPathFn)
  self.path = runSetupPathMultiBuild(self, positions, getPathFn)
  self:calcDistance()
end

function C:setupPathMulti(positions)
  local inst = self
  runSetupPathMulti(inst, positions, function(from, to)
    return map.getPointToPointPath(from, to, inst.cutOffDrivability, inst.dirMult, inst.penaltyAboveCutoff, inst.penaltyBelowCutoff, inst.wD, inst.wZ)
  end)
end

local function cancelPathMultiJob(inst)
  local h = inst._pathMultiJobHandle
  if h and h.running then
    debugLog('setupPathMultiJob: cancel active path job')
    extensions.core_jobsystem.cancelJob(h)
    inst._pathMultiJobHandle = nil
  end
end

local function cancelRecalculateJob(inst)
  local h = inst._recalculateJobHandle
  if h and h.running then
    debugLog('recalculateRoute: cancel active recalculate job')
    extensions.core_jobsystem.cancelJob(h)
    inst._recalculateJobHandle = nil
  end
  inst._recalculateAnchorPos = nil
end

local function setRecalculateAnchor(inst, startPos)
  if not inst._recalculateAnchorPos then
    inst._recalculateAnchorPos = vec3()
  end
  inst._recalculateAnchorPos:set(startPos)
end

-- Same as setupPathMulti but pathfinding runs in core_jobsystem (yields between search steps). Optional onComplete(route) when done.
-- self.path is updated only when the job finishes. If called again while a job is still active, the previous job is cancelled and replaced (warning logged).
function C:setupPathMultiJob(positions, onComplete)
  local inst = self
  cancelRecalculateJob(inst)
  local prev = inst._pathMultiJobHandle
  if prev and prev.running then
    log('W', 'route', 'setupPathMultiJob: previous path job still active; cancelling and replacing it')
    debugLog('setupPathMultiJob: replacing previous path job')
    extensions.core_jobsystem.cancelJob(prev)
    inst._pathMultiJobHandle = nil
  end
  debugLog('setupPathMultiJob: scheduling, waypoints=', #positions)
  local jobHandle = extensions.core_jobsystem.create(function(job, positions, onComplete)
    local t0 = os.clock()
    debugLog('setupPathMultiJob: job started (coroutine running)')
    local newPath = runSetupPathMultiBuild(inst, positions, function(from, to)
      return map.getPointToPointPathJob(job, from, to, inst.cutOffDrivability, inst.dirMult, inst.penaltyAboveCutoff, inst.penaltyBelowCutoff, inst.wD, inst.wZ)
    end)
    debugLog('setupPathMultiJob: build finished, path nodes=', #newPath)
    inst.path = newPath
    inst:calcDistance()
    if onComplete then onComplete(inst) end
    logRouteJobDuration('setupPathMultiJob', t0)
    debugLog('setupPathMultiJob: work finished (before job exit)')
  end, global_pathJobMaxDt or pathJobMaxDt, positions, onComplete)
  inst._pathMultiJobHandle = jobHandle
  jobHandle.setExitCallback(function(handle)
    debugLog('setupPathMultiJob: job finished (exit callback, coroutine dead)')
    if inst._pathMultiJobHandle == handle then
      inst._pathMultiJobHandle = nil
    end
  end)
end

function C:clear()
  cancelPathMultiJob(self)
  cancelRecalculateJob(self)
  self._recalculateAnchorPos = nil
  table.clear(self.path)
end

function C:getNextFixedWP()
  for _, wp in ipairs(self.path) do
    if wp.fixed then return wp.pos end
  end
end

function C:unflagFirstFixedNode()
  for _, wp in ipairs(self.path) do
    if wp.fixed then
      wp.fixed = nil
      return true
    end
  end
  return false
end

local function stitchRecalculateTail(path, savedTail)
  if #path > 0 and path[#path].fixed then
    table.remove(path, #path)
  end
  local closeDistSquared = 1
  for _, wp in ipairs(savedTail) do
    local last = path[#path]
    if last and wp.pos:squaredDistance(last.pos) <= closeDistSquared then
      last.wp = last.wp or wp.wp
      last.fixed = last.fixed or wp.fixed
    else
      table.insert(path, wp)
    end
  end
end

function C:recalculateRoute(startPos)
  debugLog('recalculateRoute: scheduling, startPos=', startPos)
  profilerPushEvent("Route - recalculateRoute")

  cancelPathMultiJob(self)
  cancelRecalculateJob(self)

  local fixedIdx
  for i, wp in ipairs(self.path) do
    if wp.fixed then
      fixedIdx = i
      break
    end
  end

  local inst = self

  if not fixedIdx then
    local lastPos = self.path[#self.path] and self.path[#self.path].pos
    if not lastPos then
      profilerPopEvent("Route - recalculateRoute")
      return
    end
    local positions = {startPos, lastPos}
    debugLog('recalculateRoute: job (no fixed WP) queued, positions=', #positions)
    local jobHandle = extensions.core_jobsystem.create(function(job, positions)
      local t0 = os.clock()
      debugLog('recalculateRoute: job started (no fixed WP), coroutine running')
      local newPath = runSetupPathMultiBuild(inst, positions, function(from, to)
        return map.getPointToPointPathJob(job, from, to, inst.cutOffDrivability, inst.dirMult, inst.penaltyAboveCutoff, inst.penaltyBelowCutoff, inst.wD, inst.wZ)
      end)
      debugLog('recalculateRoute: build finished (no fixed WP), path nodes=', #newPath)
      inst.path = newPath
      inst:calcDistance()
      extensions.hook('onRecalculatedRoute')
      logRouteJobDuration('recalculateRoute (no fixed WP)', t0)
      debugLog('recalculateRoute: work finished (no fixed WP, before job exit)')
    end, global_pathJobMaxDt or pathJobMaxDt, positions)
    inst._recalculateJobHandle = jobHandle
    setRecalculateAnchor(inst, startPos)
    jobHandle.setExitCallback(function(handle)
      debugLog('recalculateRoute: job finished (no fixed WP, exit callback, coroutine dead)')
      if inst._recalculateJobHandle == handle then
        inst._recalculateJobHandle = nil
        inst._recalculateAnchorPos = nil
      end
    end)
    profilerPopEvent("Route - recalculateRoute")
    return
  end

  local savedTail = {}
  for i = fixedIdx, #self.path do
    table.insert(savedTail, self.path[i])
  end
  local positions = {startPos, savedTail[1].pos}

  debugLog('recalculateRoute: job (fixed WP) queued, tailLen=', #savedTail)
  local jobHandle = extensions.core_jobsystem.create(function(job, positions, savedTail)
    local t0 = os.clock()
    debugLog('recalculateRoute: job started (fixed WP), coroutine running')
    local newPath = runSetupPathMultiBuild(inst, positions, function(from, to)
      return map.getPointToPointPathJob(job, from, to, inst.cutOffDrivability, inst.dirMult, inst.penaltyAboveCutoff, inst.penaltyBelowCutoff, inst.wD, inst.wZ)
    end)
    stitchRecalculateTail(newPath, savedTail)
    debugLog('recalculateRoute: build finished (fixed WP), path nodes=', #newPath)
    inst.path = newPath
    inst:calcDistance()
    extensions.hook('onRecalculatedRoute')
    logRouteJobDuration('recalculateRoute (fixed WP)', t0)
    debugLog('recalculateRoute: work finished (fixed WP, before job exit)')
  end, global_pathJobMaxDt or pathJobMaxDt, positions, savedTail)
  inst._recalculateJobHandle = jobHandle
  setRecalculateAnchor(inst, startPos)
  jobHandle.setExitCallback(function(handle)
    debugLog('recalculateRoute: job finished (fixed WP, exit callback, coroutine dead)')
    if inst._recalculateJobHandle == handle then
      inst._recalculateJobHandle = nil
      inst._recalculateAnchorPos = nil
    end
  end)
  profilerPopEvent("Route - recalculateRoute")
end

--local offPathDist = 25
function C:getPositionOffset(currentPos)
  profilerPushEvent("Route - getPositionOffset")
  -- go through all segments and check where we are on that line
  local minDistance, totalMinDist = math.huge, math.huge
  local lowIdx = 0
  for i = 1, #self.path-1 do
    local distSq = currentPos:squaredDistanceToLineSegment(self.path[i].pos, self.path[i+1].pos)
    totalMinDist = math.min(totalMinDist, distSq)

    if distSq > minDistance then break end

    if self.lockFixedNodes and self.path[i].fixed then
      break
    end

    if distSq < onPathDist * onPathDist then
      minDistance = distSq
      lowIdx = i
    elseif self.path[i].fixed then
      break
    end
  end
  profilerPopEvent("Route - getPositionOffset")
  return lowIdx, math.sqrt(totalMinDist)
end

function C:shortenPath(idx)
  profilerPushEvent("Route - shortenPath")
  for i = 2, idx do
    table.remove(self.path, 1)
  end
  profilerPopEvent("Route - shortenPath")
end

function C:trackVehicle(veh) return self:updatePathForPos(veh:getPosition()) end
function C:trackCamera() return self:updatePathForPos(core_camera.getPosition()) end
function C:trackPosition(pos) return self:updatePathForPos(pos) end

local startEndPosTable = {pos = vec3()}
function C:updatePathForPos(pos)
  profilerPushEvent("Route - updatePathForPos")
  -- are we there yet? no path or only one element remaining?
  if not next(self.path) or #self.path < 2 then
    self.done = true
    profilerPopEvent("Route - updatePathForPos")
    return
  end

  -- did we pass any of the first positions, moving forward on the track?
  local idx, routeDist = self:getPositionOffset(pos)
  local onPathDistSq = onPathDist * onPathDist

  -- Close enough to the route line: cancel an in-flight async recalculation (back on route)
  if routeDist < onPathDist then
    cancelRecalculateJob(self)
  elseif self._recalculateJobHandle and self._recalculateJobHandle.running and self._recalculateAnchorPos then
    -- Still off-route but moved too far from where this recalculation started: redo from current position
    if pos:squaredDistance(self._recalculateAnchorPos) > onPathDistSq then
      print("recalculateRoute(pos)")
      cancelRecalculateJob(self)
      self:recalculateRoute(pos)
    end
  end

  if idx == 0 and routeDist >= onPathDist then
    if not (self._recalculateJobHandle and self._recalculateJobHandle.running) then
      self:recalculateRoute(pos)
    end
  elseif idx >= 2 then
    -- if we passed the first segment, truncate path accordingly
    self:shortenPath(idx)
  end
  if not (self.lockFixedNodes and self.path[1] and self.path[1].fixed) then
    startEndPosTable.pos:set(pos)
    fixStartEnd(startEndPosTable, self.path[1], self.path[2])
  end
  profilerPopEvent("Route - updatePathForPos")
  return idx, routeDist
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end