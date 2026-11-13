-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- PART FOCUS CAMERA
-- Frames one vehicle part while the parts menu has it highlighted. Hidden, so it never appears in
-- the camera cycle: core_vehicle_partFocusCamera switches to it and back on its own.
-- Target point and distance are pushed through setRef / setDefaultDistance and eased here.
-- Orbit / zoom are user-driven (mouse + keyboard), same pattern as a normal orbit camera.

local C = {}
C.__index = C

-- starts at zero speed but picks up quickly, then takes its time to settle: for moves the user asked
-- for and is waiting on
local function easeBrisk(t)
  local rest = 1 - math.min(t, 1)
  return smoothstep(1 - rest * rest)
end

function C:init()
  self.isGlobal = true
  self.hidden = true

  self.defaultYaw = 135
  self.defaultPitch = -14
  self.fov = 35
  self.easeRate = 3
  self.camMinDist = 0.6
  self.camMaxDist = 80
  self.zoomRate = 0.007 -- distance fraction per ms at full zoom input, so holding roughly doubles it per second
  self.wheelStep = 0.12 -- distance fraction per mouse wheel notch

  self.camRot = vec3(self.defaultYaw, self.defaultPitch, 0)
  self.targetPos = vec3(0, 0, 0)
  self.currentPos = vec3(0, 0, 0)
  self.currentOffset = nil -- nil means snap on the first frame rather than fly in from the origin
  self.targetDistance = 4
  self.currentDistance = nil

  self.transitionElapsed = nil -- set while gliding to a newly selected part
  self.transitionDuration = 1
  self.transitionEase = smootheststep
  self.transitionStartOffset = vec3()
  self.transitionStartDistance = 0
  self.hopFactor = 0.5 -- extra distance per metre travelled, reached at the middle of a glide
  self.hopMax = 6
  self.hopDistance = 0
end

-- snap jumps straight onto the next target, for when the global camera transition does the blending.
-- Otherwise the view glides from where it is now over duration, with a quicker start when brisk.
function C:retarget(snap, duration, brisk)
  if snap or not self.currentOffset then
    self.currentOffset = nil
    self.transitionElapsed = nil
    return
  end
  self.transitionStartOffset:set(self.currentOffset)
  self.transitionStartDistance = self.currentDistance
  self.transitionDuration = math.max(duration or 0, 0.001)
  self.transitionEase = brisk and easeBrisk or smootheststep
  self.transitionElapsed = 0
end

function C:setRef(pos)
  if not pos then return end
  -- a vehicle reset or teleport moves the part in one step: snap there instead of flying across the
  -- world, which would drag the view through the terrain (collisionCompatible is off). A glide to a
  -- far part of a long vehicle covers that distance on purpose.
  if self.currentOffset and not self.transitionElapsed and self.currentPos:squaredDistance(pos) > 25 then
    self.currentOffset = nil
  end
  self.targetPos = vec3(pos)
end

function C:setDefaultDistance(d)
  if d and d > 0 then
    self.targetDistance = clamp(d, self.camMinDist, self.camMaxDist)
  end
end

function C:reset()
  self.currentOffset = nil
  self.currentDistance = nil
  self.transitionElapsed = nil
  self.camRot:set(self.defaultYaw, self.defaultPitch, 0)
end

function C:update(data)
  data.res.collisionCompatible = false -- the point of interest is usually inside the vehicle

  -- a reset stalls the frame, and the orbit/zoom steps below scale with dt: uncapped that turns one
  -- long frame into a wild spin
  local dt = math.min(data.dt or 0, 0.1)

  -- pull the focus point here rather than let the driver push it from onUpdate: that hook runs before
  -- the frame's physics step, which would leave the framing one step behind the vehicle
  local driver = extensions.core_vehicle_partFocusCamera
  if driver then driver.updateTarget(dt, self) end

  -- smooth the offset from the vehicle rather than the world point: the vehicle's own motion has to be
  -- followed exactly, only moving the focus to another part should glide. data.pos is the anchor the
  -- driver builds the focus point on, so the two cannot drift apart on the floating point grid.
  local targetOffset = self.targetPos - data.pos
  self.hopDistance = 0
  if not self.currentOffset then
    self.currentOffset = targetOffset
    self.currentDistance = self.targetDistance
    self.transitionElapsed = nil
  elseif self.transitionElapsed then
    -- eased at both ends: a close-in camera that starts or stops abruptly is hard to watch
    self.transitionElapsed = self.transitionElapsed + dt
    local t = self.transitionEase(self.transitionElapsed / self.transitionDuration)
    self.currentOffset = self.transitionStartOffset + (targetOffset - self.transitionStartOffset) * t
    self.currentDistance = self.transitionStartDistance + (self.targetDistance - self.transitionStartDistance) * t
    -- pulls back mid-glide in proportion to the travel, so a long jump shows where on the vehicle it lands
    local travel = targetOffset:distance(self.transitionStartOffset)
    self.hopDistance = math.min(travel * self.hopFactor, self.hopMax) * math.sin(math.pi * t)
    if self.transitionElapsed >= self.transitionDuration then self.transitionElapsed = nil end
  else
    local ease = math.min(1, dt * self.easeRate)
    self.currentOffset = self.currentOffset + (targetOffset - self.currentOffset) * ease
    self.currentDistance = self.currentDistance + (self.targetDistance - self.currentDistance) * ease
  end
  self.currentPos:setAdd2(data.pos, self.currentOffset)

  -- mouse / stick look
  local yawDif = 0.1 * (MoveManager.yawRight - MoveManager.yawLeft)
  local pitchDif = 0.1 * (MoveManager.pitchDown - MoveManager.pitchUp)
  local maxRot = 180
  local dtfactor = dt * 1000
  local mouseYaw = sign(MoveManager.yawRelative) * math.min(math.abs(MoveManager.yawRelative * 10), maxRot * dt) + yawDif * dtfactor
  local mousePitch = sign(-MoveManager.pitchRelative) * math.min(math.abs(MoveManager.pitchRelative * 10), maxRot * dt) + pitchDif * dtfactor

  -- keyboard orbit
  local maxRotKeyboard = 80
  local keyboardYaw = (MoveManager.left - MoveManager.right) * maxRotKeyboard * dt
  local keyboardPitch = (MoveManager.forward - MoveManager.backward) * maxRotKeyboard * dt

  if mouseYaw ~= 0 or mousePitch ~= 0 then
    self.camRot.x = self.camRot.x - mouseYaw
    self.camRot.y = self.camRot.y - mousePitch
  end
  if keyboardYaw ~= 0 or keyboardPitch ~= 0 then
    self.camRot.x = self.camRot.x - keyboardYaw
    self.camRot.y = self.camRot.y - keyboardPitch
  end

  self.camRot.y = clamp(self.camRot.y, -85, 85)
  self.camRot.x = (self.camRot.x + 360) % 360
  if self.camRot.x > 180 then
    self.camRot.x = self.camRot.x - 360
  end

  -- Zoom keys are read the way orbit reads them, input left in place so holding keeps zooming. Wheel
  -- notches come banked from the driver and apply as whole steps. Both are a fraction of the current
  -- distance rather than orbit's fixed metres, because this camera frames anything from a bolt to a
  -- whole frame.
  local heldZoom = (MoveManager.zoomIn - MoveManager.zoomOut) * dtfactor * self.zoomRate
  local wheelZoom = (driver and driver.consumeZoomSteps() or 0) * self.wheelStep
  local zoomChange = heldZoom - wheelZoom
  if zoomChange ~= 0 then
    local zoomed = clamp(self.currentDistance * (1 + zoomChange), self.camMinDist, self.camMaxDist)
    self.currentDistance = zoomed
    self.targetDistance = zoomed
    if self.transitionElapsed then self.transitionStartDistance = zoomed end
  end

  local yaw = math.rad(self.camRot.x)
  local pitch = math.rad(self.camRot.y)
  local dir = vec3(math.sin(yaw) * math.cos(pitch), -math.cos(yaw) * math.cos(pitch), -math.sin(pitch))
  local camPos = self.currentPos + dir * (self.currentDistance + self.hopDistance)

  data.res.pos = camPos
  data.res.rot = quatFromDir(self.currentPos - camPos)
  data.res.fov = self.fov

  -- false makes the camera system drop this global camera, so a view the driver no longer holds
  -- falls back to its vehicle camera instead of freezing on the last part
  return driver ~= nil and driver.isActive()
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
