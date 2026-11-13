-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- this lets the camera fly on the first path of the map

local C = {}
C.__index = C

local sqrt = math.sqrt
local origin = vec3(0,0,0)
local xVector = vec3(1, 0, 0)
local yVector = vec3(0, 1, 0)
local zVector = vec3(0, 0, 1)

function C:init()
  self.isGlobal = true
  self.hidden = true
  self.ctrlPoint = 0
  self.camT = 0
  self.customData = nil
  self.path = nil
  self.lastSpeed = nil
  self.pathName = nil

  -- This is for backwards compatibility. Might just be a typo of "pathName", but i'll keep it in for safety
  self.pathname = nil
end

local function calculateTnorm(d12, d23, d34, t1, t2, t3, t)
  return clamp((monotonicSteffen(0, d12, d12 + d23, d12 + d23 + d34, 0, t1, t1 + t2, t1 + t2 + t3, t1 + t) - d12) / d23, 0, 1)
end

-- Look-at `to` from `from`, keeping the roll twist from `sourceRot` (marker authoring).
-- Without this, quatFromDir(..., worldUp) flattens roll to 0 whenever Track Vehicle is on.
local function lookAtPreservingRoll(from, to, sourceRot)
  local dir = to - from
  if dir:squaredLength() < 1e-10 then return sourceRot end
  local look = quatFromDir(dir, zVector)
  if not sourceRot then return look end
  local srcFwd = sourceRot * yVector
  if srcFwd:squaredLength() < 1e-10 then return look end
  local srcLook = quatFromDir(srcFwd, zVector)
  return (look * (srcLook:inversed() * sourceRot)):normalized()
end

-- Gimbal decomposition, shared with the path camera editor so what the graphs
-- show is what plays back. Pitch is positive nose-down.
local function facingYawPitchRoll(rot)
  local f = (rot * yVector):normalized()
  local u = (rot * zVector):normalized()
  local yaw = math.deg(math.atan2(f.x, f.y))
  local pitchDown = math.deg(math.asin(clamp(-f:dot(zVector), -1, 1)))
  local wUpProj = zVector - f * zVector:dot(f)
  if wUpProj:squaredLength() < 1e-12 then return yaw, pitchDown, 0 end
  wUpProj:normalize()
  local uProj = u - f * u:dot(f)
  if uProj:squaredLength() < 1e-12 then return yaw, pitchDown, 0 end
  uProj:normalize()
  local roll = math.deg(math.atan2(wUpProj:cross(uProj):dot(f), wUpProj:dot(uProj)))
  return yaw, pitchDown, roll
end

local function quatFromYawPitchRoll(yawDeg, pitchDownDeg, rollDeg)
  local yaw = math.rad(yawDeg or 0)
  local pitch = math.rad(pitchDownDeg or 0)
  local roll = math.rad(rollDeg or 0)
  local cp, sp = math.cos(pitch), math.sin(pitch)
  local sy, cy = math.sin(yaw), math.cos(yaw)
  local fwd = vec3(sy * cp, cy * cp, -sp)
  if fwd:squaredLength() < 1e-12 then fwd = vec3(0, 1, 0) else fwd:normalize() end
  local up0 = zVector - fwd * zVector:dot(fwd)
  if up0:squaredLength() < 1e-12 then
    up0 = xVector - fwd * xVector:dot(fwd)
  end
  up0:normalize()
  if math.abs(roll) > 1e-8 then
    local c, s = math.cos(roll), math.sin(roll)
    up0 = up0 * c + fwd:cross(up0) * s
    up0:normalize()
  end
  return quatFromDir(fwd, up0)
end

local function markerTrackOffset(m)
  local o = m and m.trackOffset
  if type(o) == 'table' then
    return tonumber(o.x) or 0, tonumber(o.y) or 0, tonumber(o.z) or 0
  end
  return 0, 0, 0
end

-- Interpolate per-marker track offsets (Steffen, same as FOV). Falls back to the
-- editor/workbench global getTrackingOffset when no marker has an offset set.
local function resolveTrackingOffset(markers, n1, n2, n3, n4, t1, t2, t3, camTLocal)
  local x1, y1, z1 = markerTrackOffset(markers[n1])
  local x2, y2, z2 = markerTrackOffset(markers[n2])
  local x3, y3, z3 = markerTrackOffset(markers[n3])
  local x4, y4, z4 = markerTrackOffset(markers[n4])
  local hasKeyframe = (x1 ~= 0 or y1 ~= 0 or z1 ~= 0 or x2 ~= 0 or y2 ~= 0 or z2 ~= 0
    or x3 ~= 0 or y3 ~= 0 or z3 ~= 0 or x4 ~= 0 or y4 ~= 0 or z4 ~= 0
    or (markers[n1] and markers[n1].trackOffset) or (markers[n2] and markers[n2].trackOffset)
    or (markers[n3] and markers[n3].trackOffset) or (markers[n4] and markers[n4].trackOffset))
  if hasKeyframe then
    return {
      x = monotonicSteffen(x1, x2, x3, x4, 0, t1, t1 + t2, t1 + t2 + t3, t1 + camTLocal),
      y = monotonicSteffen(y1, y2, y3, y4, 0, t1, t1 + t2, t1 + t2 + t3, t1 + camTLocal),
      z = monotonicSteffen(z1, z2, z3, z4, 0, t1, t1 + t2, t1 + t2 + t3, t1 + camTLocal),
    }
  end
  -- Legacy / live-tweak: World Editor or Workbench global offset
  if extensions then
    if extensions.editor_camPathEditor and extensions.editor_camPathEditor.getTrackingOffset then
      local o = extensions.editor_camPathEditor.getTrackingOffset()
      if o then return o end
    end
    for _, name in ipairs(extensions.getLoadedExtensionsNames()) do
      if name:find('pathCameraEditor', 1, true) then
        local e = rawget(extensions, name)
        if e and type(e.getTrackingOffset) == 'function' then
          local o = e.getTrackingOffset()
          if o then return o end
        end
      end
    end
  end
  return nil
end

-- Vehicle pose as (pos, rot) for attach-to-vehicle markers.
local function vehiclePoseFrom(veh)
  if not veh then return nil, nil end
  return veh:getPosition(), quatFromDir(vec3(veh:getDirectionVector()), vec3(veh:getDirectionVectorUp()))
end

local function localPosToWorld(localPos, vehPos, vehRot)
  return vehPos + vehRot * localPos
end

-- Camera quats in BeamNG compose as world = local * veh (same as relative cam /
-- screenshotCreator). Using veh * local flips pitch relative to the car.
local function localRotToWorld(localRot, vehRot)
  return (localRot * vehRot):normalized()
end

local function poseFromTracks(path, t, marker, vehPos, vehRot, lookTarget)
  local ev = core_paths.evalTransform and core_paths.evalTransform(path, t)
  if not ev then return nil end
  local p = vec3(ev.posX or 0, ev.posY or 0, ev.posZ or 0)
  local r = quatFromYawPitchRoll(ev.yaw or 0, ev.pitch or 0, ev.roll or 0)
  if marker and marker.attachToVehicle and vehPos then
    p = localPosToWorld(p, vehPos, vehRot)
    r = localRotToWorld(r, vehRot)
  end
  if marker and marker.trackPosition and lookTarget then
    r = lookAtPreservingRoll(p, lookTarget, r)
  end
  return p, r, ev.fov
end

local function worldRotToLocal(worldRot, vehRot)
  return (worldRot * vehRot:inversed()):normalized()
end

function C:getTimeToNext(path, index)
  local markers = path.markers
  if self.customData and self.customData.useJsonVersion then
    return (index < #markers) and (markers[index+1].time - markers[index].time) or (path.looped and core_paths.loopDuration(path) or 2)
  else
    return markers[index].time
  end
end

function C:getGlobalTime(path, index, looped)
  if self.customData and self.customData.useJsonVersion then
    if looped and (index == 1) then
      return path.markers[#path.markers].time + core_paths.loopDuration(path)
    else
      return path.markers[index].time
    end
  else
    local globalTime = 0
    for i=1, index - 1 do
      globalTime = globalTime + path.markers[i].time
    end
    return globalTime
  end
end

local function cubicBezier(a, b, t)
  local inv = 1 - t
  return 3 * inv * inv * t * a + 3 * inv * t * t * b + t * t * t
end

-- Optional 2D temporal Bézier. prefix is 'motion' (drone/position) or 'rotMotion' (gimbal).
local function hasMotionFields(fromMarker, toMarker, prefix)
  return fromMarker[prefix .. 'Out'] ~= nil or toMarker[prefix .. 'In'] ~= nil
    or fromMarker[prefix .. 'OutTime'] ~= nil or toMarker[prefix .. 'InTime'] ~= nil
end

local function applyMotionCurve(time, duration, fromMarker, toMarker, prefix)
  prefix = prefix or 'motion'
  if duration <= 1e-6 or not hasMotionFields(fromMarker, toMarker, prefix) then
    return time
  end
  local u = clamp(time / duration, 0, 1)
  local outTime = clamp(tonumber(fromMarker[prefix .. 'OutTime']) or (1 / 3), 0.02, 0.96)
  local inTime = clamp(tonumber(toMarker[prefix .. 'InTime']) or (1 / 3), 0.02, 0.96)
  if outTime + inTime > 0.98 then
    local scale = 0.98 / (outTime + inTime)
    outTime, inTime = outTime * scale, inTime * scale
  end
  local outProgress = clamp(outTime * math.max(tonumber(fromMarker[prefix .. 'Out']) or 1, 0), 0, 1)
  local inProgress = clamp(inTime * math.max(tonumber(toMarker[prefix .. 'In']) or 1, 0), 0, 1)

  -- Invert the monotonic x Bézier so clock time remains the independent axis.
  local curveT = core_paths.invertCubicBezier(outTime, 1 - inTime, u)
  return cubicBezier(outProgress, 1 - inProgress, curveT) * duration
end

function C:update(data)
  if self.customData and self.customData.getNextPath then
    if self.customData.useJsonVersion then
      if not self.path then
        self.path = self.customData:getNextPath()
      end
    else
      if not self.pathName then
        self.pathName = self.customData:getNextPath()
      end
    end
  end

  local path
  if self.customData and self.customData.useJsonVersion then
    path = self.path
  else
    path = core_paths.getPath(self.pathName)
  end
  if not path or #path.markers < 2 then return end
  local markers = path.markers

  data.dt = data.dtSim -- switch to physics dt, to respect time scaling
  if self.customData and self.customData.useDtReal then
    data.dt = data.dtReal -- allow to use real DT
  end
  if path.replay then
    self.camT = core_replay.getPositionSeconds()
    if self.camT > markers[#markers].time then
      self.camT = markers[#markers].time
    end
    self.ctrlPoint = 0
  else
    self.camT = self.camT + data.dt
  end

  self.fovOffset = self.fovOffset or 0
  path.rotFixId = path.rotFixId or 1

  if self.ctrlPoint == 0 then
    if self.customData and self.customData.useJsonVersion and (self.camT < markers[1].time) then
      local holdPos, holdRot = markers[1].pos, markers[1].rot
      if markers[1].attachToVehicle and data.veh then
        local vp, vr = vehiclePoseFrom(data.veh)
        if vp then holdPos, holdRot = localPosToWorld(holdPos, vp, vr), localRotToWorld(holdRot, vr) end
      end
      data.res.pos:set(holdPos)
      data.res.rot:set(holdRot)
      if path.manualFov then
        if self.fovOffset > 0 then
          local rdz = 4.5*data.dt*(MoveManager.zoomIn - MoveManager.zoomOut) * 120 / (120 - markers[1].fov) * 0.5
          self.fovOffset = clamp(self.fovOffset + rdz, -1, 1)
          data.res.fov = clamp(markers[1].fov + (120 - markers[1].fov) * self.fovOffset, 10, 120)
        else
          local rdz = 4.5*data.dt*(MoveManager.zoomIn - MoveManager.zoomOut) * 120 / (markers[1].fov - 10) * 0.5
          self.fovOffset = clamp(self.fovOffset + rdz, -1, 1)
          data.res.fov = clamp(markers[1].fov + (markers[1].fov - 10) * self.fovOffset, 10, 120)
        end
      else
        data.res.fov = markers[1].fov
      end
      return true
    else
      self.ctrlPoint = 1
    end
  end

  -- simulate interpolated camera
  local n1, n2, n3, n4 = core_paths.getMarkerIds(path, self.ctrlPoint)

  local nextTime = self:getGlobalTime(path, n3, path.looped)
  while self.camT > nextTime and self.ctrlPoint <= core_paths.getEndIdx(path) - 1 do
    if self.customData and self.customData.onNextControlPoint then
      self.customData:onNextControlPoint(self.ctrlPoint+1, #path.markers)
    end
    self.ctrlPoint = self.ctrlPoint + 1
    n1, n2, n3, n4 = core_paths.getMarkerIds(path, self.ctrlPoint)
    nextTime = self:getGlobalTime(path, n3, path.looped)
  end

  if self.ctrlPoint ~= self.lastFrameCtrlPoint then
    -- Passed a marker
    self.lastCtrlPointR2 = deepcopy(self.lastFrameR2)
    if markers[n2].cut then
      local cutPos, cutRot, cutFov = markers[n3].pos, markers[n3].rot, markers[n3].fov or 60
      local vp, vr
      if data.veh then vp, vr = vehiclePoseFrom(data.veh) end
      local tracked = nil
      if markers[n3].trackPosition and data.pos then tracked = data.pos end
      local tp, tr, tf = poseFromTracks(path, self.camT, markers[n3], vp, vr, tracked)
      if tp then cutPos, cutRot, cutFov = tp, tr, tf or cutFov
      elseif markers[n3].attachToVehicle and vp then
        cutPos, cutRot = localPosToWorld(cutPos, vp, vr), localRotToWorld(cutRot, vr)
      end
      data.res.pos:set(cutPos)
      data.res.rot:set(cutRot)
      data.res.fov = cutFov
      self.ctrlPoint = self.ctrlPoint + 1
      return true
    end
  end

  self.lastFrameCtrlPoint = self.ctrlPoint
  local rawT = self.camT - self:getGlobalTime(path, n2)
  local t1, t2, t3 = self:getTimeToNext(path, n1), self:getTimeToNext(path, n2), self:getTimeToNext(path, n3)
  local camTLocal = applyMotionCurve(rawT, t2, markers[n2], markers[n3], 'motion')
  local rotTLocal = hasMotionFields(markers[n2], markers[n3], 'rotMotion')
    and applyMotionCurve(rawT, t2, markers[n2], markers[n3], 'rotMotion')
    or camTLocal
  -- Each Euler axis may run on its own clock, falling back to the shared gimbal
  -- curve. Yaw can hold while pitch keeps easing, like a real gimbal operator.
  local function axisTime(prefix)
    if hasMotionFields(markers[n2], markers[n3], prefix) then
      return applyMotionCurve(rawT, t2, markers[n2], markers[n3], prefix)
    end
    return rotTLocal
  end
  local yawTLocal, pitchTLocal, rollTLocal = axisTime('yawMotion'), axisTime('pitchMotion'), axisTime('rollMotion')
  local perAxisRot = yawTLocal ~= rotTLocal or pitchTLocal ~= rotTLocal or rollTLocal ~= rotTLocal

  -- Attach-to-vehicle: markers store poses in vehicle-local space so the path
  -- rides with the car (orbit/follow) without matching world speed by hand.
  local vehPos, vehRot
  local a1, a2, a3, a4 = markers[n1].attachToVehicle, markers[n2].attachToVehicle, markers[n3].attachToVehicle, markers[n4].attachToVehicle
  local anyAttach = a1 or a2 or a3 or a4
  local allAttach = a1 and a2 and a3 and a4
  if anyAttach and data.veh then
    vehPos, vehRot = vehiclePoseFrom(data.veh)
  end
  if anyAttach and not vehPos then
    -- No vehicle available: fall back to treating stored poses as world.
    allAttach = false
  end

  local p1, p2, p3, p4
  if allAttach then
    p1, p2, p3, p4 = markers[n1].pos, markers[n2].pos, markers[n3].pos, markers[n4].pos
  else
    local function resolvePos(m)
      if m.attachToVehicle and vehPos then return localPosToWorld(m.pos, vehPos, vehRot) end
      return m.pos
    end
    p1, p2, p3, p4 = resolvePos(markers[n1]), resolvePos(markers[n2]), resolvePos(markers[n3]), resolvePos(markers[n4])
  end

  if path.markers[n2].movingStart and (n1 == n2) then
    -- Add a virtual marker at the start for p1, so the cam speed is smoother
    if p3:distance(p2) == 0 then
      p1 = p2
      t1 = 0
    else
      local direction = catmullRomChordal(p1, p2, p3, p4, 0.1, markers[n2].positionSmooth) - p2
      p1 = p2 - direction
      t1 = t2 * direction:length() / p3:distance(p2)
    end
  end

  -- TODO with movingEnd the rotation doesnt have the correct timing
  if path.markers[n2].movingEnd and (n3 == n4) then
    -- Add a virtual marker at the end for p4, so the cam speed is smoother
    if p3:distance(p2) == 0 then
      p4 = p3
      t3 = 0
    else
      local direction = p3 - catmullRomChordal(p1, p2, p3, p4, 0.9, markers[n2].positionSmooth)
      p4 = p3 + direction
      t3 = t2 * direction:length() / p3:distance(p2)
    end
  end

  local tNorm = calculateTnorm(p1:distance(p2), p2:distance(p3), p3:distance(p4), t1, t2, t3, camTLocal)
  local pos = catmullRomChordal(p1, p2, p3, p4, tNorm, markers[n2].positionSmooth)
  if allAttach and vehPos then
    pos = localPosToWorld(pos, vehPos, vehRot)
  end

  local target = origin
  if data.pos then
    target = data.pos

    -- Apply tracking offset (per-marker keyframes, or legacy editor global).
    if data.veh then
      local trackingOffset = resolveTrackingOffset(markers, n1, n2, n3, n4, t1, t2, t3, camTLocal)
      if trackingOffset then
        local veh = data.veh
        local forward = vec3(veh:getDirectionVector())
        local up = vec3(veh:getDirectionVectorUp())
        local right = up:cross(forward):normalized()
        local offsetWorld = right * trackingOffset.x + forward * trackingOffset.y + up * trackingOffset.z
        target = target + offsetWorld
      end
    end
  end
  -- Look at the vehicle while keeping each marker's authored roll (world-up look-at was wiping it).
  local function sourceRot(m)
    if m.attachToVehicle and vehRot then return localRotToWorld(m.rot, vehRot) end
    return m.rot
  end
  local function trackedRot(m)
    return lookAtPreservingRoll(pos, target, sourceRot(m))
  end
  local allAttachNoTrack = allAttach and vehRot
    and not markers[n1].trackPosition and not markers[n2].trackPosition
    and not markers[n3].trackPosition and not markers[n4].trackPosition

  local r1, r2, r3, r4
  if allAttachNoTrack then
    -- Interpolate orientation in vehicle space, then bank with the car.
    r1 = self.lastCtrlPointR2 and worldRotToLocal(self.lastCtrlPointR2, vehRot) or markers[n1].rot
    r2, r3, r4 = markers[n2].rot, markers[n3].rot, markers[n4].rot
  else
    r1 = self.lastCtrlPointR2 or (markers[n1].trackPosition and trackedRot(markers[n1]) or sourceRot(markers[n1]))
    r2 = markers[n2].trackPosition and trackedRot(markers[n2]) or sourceRot(markers[n2])
    r3 = markers[n3].trackPosition and trackedRot(markers[n3]) or sourceRot(markers[n3])
    r4 = markers[n4].trackPosition and trackedRot(markers[n4]) or sourceRot(markers[n4])
  end

  if path.markers[n2].movingStart and (n1 == n2) then
    -- Set the correct rotation to the virtual marker at the start
    local catMullRot = catmullRomCentripetal(r1, r2, r3, r4, 0.1):normalized()
    r1 = r2:nlerp(catMullRot, -1)
  end

  if path.markers[n2].movingEnd and (n3 == n4) then
    -- Set the correct rotation to the virtual marker at the end
    local catMullRot = catmullRomCentripetal(r1, r2, r3, r4, 0.9):normalized()
    r4 = r3:nlerp(catMullRot, -1)
  end

  -- Fix rotations
  for i = path.rotFixId, self.ctrlPoint - 2 do
    if markers[i].rot:dot(markers[i + 1].rot) < 0 then
      markers[i + 1].rot = -markers[i + 1].rot
    end
  end
  path.rotFixId = self.ctrlPoint

  if r1:dot(r2) < 0 then r2 = -r2 end
  if r2:dot(r3) < 0 then r3 = -r3 end
  if r3:dot(r4) < 0 then r4 = -r4 end
  self.lastFrameR2 = allAttachNoTrack and localRotToWorld(r2, vehRot) or r2

  local d12, d23, d34 = sqrt(r1:distance(r2)), sqrt(r2:distance(r3)), sqrt(r3:distance(r4))
  local function rotAt(tLocal)
    return catmullRomCentripetal(r1, r2, r3, r4, calculateTnorm(d12, d23, d34, t1, t2, t3, tLocal)):normalized()
  end

  local rot = rotAt(rotTLocal)
  if perAxisRot then
    -- Sample the same orientation spline once per axis and recombine, so the
    -- curve through the markers is untouched and only the timing differs.
    local yaw = facingYawPitchRoll(yawTLocal == rotTLocal and rot or rotAt(yawTLocal))
    local _, pitch = facingYawPitchRoll(pitchTLocal == rotTLocal and rot or rotAt(pitchTLocal))
    local _, _, roll = facingYawPitchRoll(rollTLocal == rotTLocal and rot or rotAt(rollTLocal))
    rot = quatFromYawPitchRoll(yaw, pitch, roll)
  end
  if allAttachNoTrack then
    rot = localRotToWorld(rot, vehRot)
  end
  local fov = monotonicSteffen(markers[n1].fov or 60, markers[n2].fov or 60, markers[n3].fov or 60, markers[n4].fov or 60, 0, t1, t1 + t2, t1 + t2 + t3, t1 + camTLocal)
  do
    local lookTarget = (markers[n2].trackPosition or markers[n3].trackPosition) and target or nil
    local tp, tr, tf = poseFromTracks(path, self.camT, markers[n2], vehPos, vehRot, lookTarget)
    if tp then pos, rot, fov = tp, tr, tf or fov end
  end
  if markers[n1].nearClip then
    local nearClip = monotonicSteffen(markers[n1].nearClip or 0.1, markers[n2].nearClip or 0.1, markers[n3].nearClip or 0.1, markers[n4].nearClip or 0.1, 0, t1, t1 + t2, t1 + t2 + t3, t1 + camTLocal)
    data.res.nearClip = nearClip
  end
  -- restarting when reached the end
  if self.ctrlPoint >= core_paths.getEndIdx(path) - 1 and self.camT >= nextTime then
    local looping = path.looped == true
    self.ctrlPoint = 0
    if looping then
      -- Keep the leftover dt so the wrap lands on marker 1 without a one-frame hitch.
      self.camT = math.max(0, self.camT - nextTime)
    else
      self.camT = 0
      self.lastCtrlPointR2 = nil
      self.lastFrameR2 = nil
    end

    if self.customData then
      if self.customData.finishedPath then
        self.customData:finishedPath()
      end
      if self.customData.useJsonVersion then
        self.path = self.customData:getNextPath()
      else
        self.pathName = self.customData:getNextPath()
      end
    end
  end

  -- application
  data.res.pos:set(pos)
  data.res.rot:set(rot)
  if path.manualFov then
    if self.fovOffset > 0 then
      local rdz = 4.5*data.dt*(MoveManager.zoomIn - MoveManager.zoomOut) * 120 / (120 - fov) * 0.5
      self.fovOffset = clamp(self.fovOffset + rdz, -1, 1)
      data.res.fov = clamp(fov + (120 - fov) * self.fovOffset, 10, 120)
    else
      local rdz = 4.5*data.dt*(MoveManager.zoomIn - MoveManager.zoomOut) * 120 / (fov - 10) * 0.5
      self.fovOffset = clamp(self.fovOffset + rdz, -1, 1)
      data.res.fov = clamp(fov + (fov - 10) * self.fovOffset, 10, 120)
    end
  else
    data.res.fov = fov
  end

  if path.replay and markers[self.ctrlPoint] and markers[self.ctrlPoint].bullettime and markers[self.ctrlPoint].bullettime ~= self.lastSpeed then
    core_replay.setSpeed(markers[self.ctrlPoint].bullettime)
    self.lastSpeed = markers[self.ctrlPoint].bullettime
  end

  return true
end

local function replayExists(replay)
  if replay == "" then return false end
  return FS:fileExists(replay)
end

function C:setCustomData(data)
  self:reset()
  self.customData = data
  self.camT = data.offset or 0
  if self.customData.path and self.customData.path.replay then
    if replayExists(self.customData.path.replay) then
      if (self.customData.path.replay ~= core_replay.getLoadedFile()) then
        core_replay.loadFile(self.customData.path.replay)
      end
    else
      self.customData.path.replay = nil
    end
  end
end

function C:reset()
  if self.customData and self.customData.reset then
    self.customData:reset()
  end
  self.path = nil
  self.camT = 0
  self.ctrlPoint = 0
  self.fovOffset = 0
  self.pathName = nil

  -- This is for backwards compatibility. Might just be a typo of "pathName", but i'll keep it in for safety
  self.pathname = nil
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
