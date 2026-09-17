-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Aerial chase drone: floats above and behind the car on its heading and looks at it. A spring-
-- damper flies a weighted body toward the target (momentum + overshoot, sluggish climb), it banks
-- into turns, follows the terrain (tunnel/bridge aware) and keeps a safe distance from buildings.
-- All motion runs on dtSim, so it stays consistent under fast-forward / slow-mo.

local downVec = vec3(0, 0, -1)
local up = vec3(0, 0, 1)
local clearance = 2.0 -- min metres kept above the floor
local roofGap = 0.8   -- min metres kept below a ceiling (tunnel/overpass)

-- horizontal directions probed for nearby meshes (walls/buildings)
local probeDirs = {}
for i = 0, 5 do
  local a = i * math.pi / 3
  probeDirs[i + 1] = vec3(math.cos(a), math.sin(a), 0)
end

local function approachDir(cur, gx, gy, rate, dt)
  local k = 1 - math.exp(-rate * dt)
  cur.x, cur.y = cur.x + (gx - cur.x) * k, cur.y + (gy - cur.y) * k
  local l = math.sqrt(cur.x * cur.x + cur.y * cur.y)
  if l > 1e-4 then cur.x, cur.y = cur.x / l, cur.y / l end
end

-- nearest static surface below (x,y,fromZ); nil if none within reach
local function surfaceUnder(x, y, fromZ, reach)
  local o = vec3(x, y, fromZ)
  local hit = castRayStatic(o, downVec, reach)
  if hit >= reach then return nil end
  return o.z - hit
end

-- nearest static surface above (x,y,fromZ); nil if none within reach
local function ceilingAbove(x, y, fromZ, reach)
  local o = vec3(x, y, fromZ)
  local hit = castRayStatic(o, up, reach)
  if hit >= reach then return nil end
  return o.z + hit
end

-- one semi-implicit spring-damper step on a single axis (returns new pos, vel)
local function springStep(pos, vel, target, k, c, dt, accUp, accDown)
  local a = k * (target - pos) - c * vel
  if accUp then a = clamp(a, -accDown, accUp) end
  vel = vel + a * dt
  pos = pos + vel * dt
  return pos, vel
end

local C = {}
C.__index = C

function C:init()
  self.disabledByDefault = true
  self.icon = "cameraFocusOnVehicle1"
  -- tunables (all exposed via listParams below)
  self.camDist    = self.camDist or 12
  self.defaultDistance = 12 -- reset value for the 'dist' param
  self.camMinDist = 4
  self.camMaxDist = 80
  self.height     = self.height or 6
  self.fov        = self.fov or 55
  self.bank       = self.bank or 2.0   -- how hard it rolls into turns
  self.floating   = self.floating or 1.2 -- weight/inertia: higher = floatier, more overshoot/lag
  self.safeDist   = self.safeDist or 2.0 -- keep this clear of buildings/meshes (0 disables)
  self:reset()
end

function C:reset()
  self.placed = false
  self.t = 0
  self.rollSmoothed = 0
  self.vel = vec3()
  self.positionOffset = self.positionOffset or vec3()
  self.positionOffset:set(0, 0, 0)
  self.orbitYaw = 0
  self.orbitPitch = 0
end

function C:setDistance(d) self.camDist = clamp(d or self.camDist, self.camMinDist, self.camMaxDist) end
function C:setFOV(fov) self.fov = fov end
function C:onCameraChanged(focused) if focused then self.placed = false end end

function C:placeInit(position)
  self.pos = vec3(position)
  self.vel:set(0, 0, 0)
  self.lastHead = nil
end

-- Keep an altitude that follows the car (so tunnels/bridges work). Under open sky we additionally
-- rise to skim hills; under cover we stay inside, below the roof and above the floor.
function C:clampAltitude(x, y, z, car)
  local covered = ceilingAbove(car.x, car.y, car.z + 1.0, 60) ~= nil
  local lo, hi
  if covered then
    local fl = surfaceUnder(x, y, car.z + 1.5, 120)
    lo = (fl and fl + clearance) or (car.z - 2)
    local rf = ceilingAbove(x, y, car.z + 0.5, 60) or ceilingAbove(car.x, car.y, car.z + 1.0, 60)
    if rf then hi = rf - roofGap end
  else
    local fl = surfaceUnder(x, y, z + 300, 600) -- from well above so tall hills lift the drone
    lo = fl and fl + clearance
  end
  if lo and z < lo then z = lo end
  if hi and z > hi then z = hi end
  if lo and hi and lo > hi then z = (lo + hi) * 0.5 end -- pinched space: sit in the middle
  return z
end

function C:listParams()
  return {
    { key = 'dist',     icon = 'fa-ruler-horizontal', title = 'Distance',           kind = 'range', type = 'float', value = self.camDist,  default = self.defaultDistance, min = self.camMinDist or 1, max = self.camMaxDist or 50, step = 0.5, unit = 'm' },
    { key = 'height',   icon = 'fa-ruler-vertical',   title = 'Height',             kind = 'range', type = 'float', value = self.height,   default = 6,   min = 1,   max = 40, step = 0.5, unit = 'm' },
    { key = 'bank',     icon = 'fa-rotate',           title = 'Bank into turns',    kind = 'range', type = 'float', value = self.bank,     default = 1,   min = 0,   max = 2,  step = 0.1 },
    { key = 'float',    icon = 'fa-feather',          title = 'Weight (inertia)',   kind = 'range', type = 'float', value = self.floating, default = 1.2, min = 0.2, max = 3,  step = 0.1 },
    { key = 'safeDist', icon = 'fa-shield-halved',    title = 'Building clearance', kind = 'range', type = 'float', value = self.safeDist, default = 2,   min = 0,   max = 5,  step = 0.5, unit = 'm' },
    { key = 'fov',      icon = 'fa-expand',           title = 'Field of view',      kind = 'range', type = 'int',   value = self.fov,      default = 55,  min = 10,  max = 140, step = 1, unit = '°' },
  }
end

function C:setParam(key, value)
  if key == 'dist' then self:setDistance(tonumber(value) or self.camDist)
  elseif key == 'fov' then self:setFOV(tonumber(value) or self.fov)
  elseif key == 'height' then self.height = clamp(tonumber(value) or self.height, 1, 40)
  elseif key == 'bank' then self.bank = clamp(tonumber(value) or self.bank, 0, 2)
  elseif key == 'float' then self.floating = clamp(tonumber(value) or self.floating, 0.2, 3)
  elseif key == 'safeDist' then self.safeDist = clamp(tonumber(value) or self.safeDist, 0, 5) end
end

function C:serialize()
  return { dist = self.camDist, fov = self.fov, height = self.height,
           bank = self.bank, float = self.floating, safeDist = self.safeDist,
           positionOffset = {x = self.positionOffset.x, y = self.positionOffset.y, z = self.positionOffset.z},
           orbitYaw = self.orbitYaw, orbitPitch = self.orbitPitch }
end

function C:deserialize(s)
  if type(s) ~= 'table' then return end
  if s.dist then self.camDist = s.dist end
  if s.fov then self.fov = s.fov end
  if s.height then self.height = s.height end
  if s.bank then self.bank = s.bank end
  if s.float then self.floating = s.float end
  if s.safeDist then self.safeDist = s.safeDist end
  if s.positionOffset then self.positionOffset:set(s.positionOffset.x, s.positionOffset.y, s.positionOffset.z) end
  if s.orbitYaw then self.orbitYaw = s.orbitYaw end
  if s.orbitPitch then self.orbitPitch = s.orbitPitch end
  self.placed = false
end

-- Keep a safe distance from static meshes (buildings/walls). Returns a corrected x,y,z:
--  1) stay on the car's side of any wall between the car and the drone (keeps the shot clear),
--  2) push out of anything within safeDist around the drone (horizontal ring).
function C:avoid(x, y, z, car)
  local safe = self.safeDist
  local tx, ty, tz = x - car.x, y - car.y, z - car.z
  local dist = math.sqrt(tx * tx + ty * ty + tz * tz)
  if dist > 1e-3 then
    local inv = 1 / dist
    local dx, dy, dz = tx * inv, ty * inv, tz * inv
    local hit = castRayStatic(vec3(car.x, car.y, car.z), vec3(dx, dy, dz), dist)
    if hit < dist - safe then
      local d = math.max(2, hit - safe)
      x, y, z = car.x + dx * d, car.y + dy * d, car.z + dz * d
    end
  end
  for i = 1, #probeDirs do
    local dv = probeDirs[i]
    local hit = castRayStatic(vec3(x, y, z), dv, safe)
    if hit < safe then
      local s = safe - hit
      x, y = x - dv.x * s, y - dv.y * s
    end
  end
  return x, y, z
end

local idle = vec3()
function C:update(data)
  data.res.collisionCompatible = false
  if not data.veh then return true end -- follows the player vehicle; hold if there is none
  local dt = data.dtSim -- physics dt: respects time scaling (fast-forward / slow-mo / pause)
  local vid = data.veh:getID()
  local cx, cy, cz = be:getObjectOOBBCenterXYZ(vid)
  local car = vec3(cx, cy, cz)

  -- smoothed travel heading (hold last when nearly stopped)
  local speed = math.sqrt(data.vel.x * data.vel.x + data.vel.y * data.vel.y)
  if not self.head then self.head = vec3(0, 1, 0) end
  if speed > 1.5 and dt > 1e-6 then approachDir(self.head, data.vel.x / speed, data.vel.y / speed, 3, dt) end

  -- heading turn rate, for banking
  local turn = 0
  if self.lastHead and dt > 1e-6 then
    local cross = self.lastHead.x * self.head.y - self.lastHead.y * self.head.x
    local dot = clamp(self.lastHead.x * self.head.x + self.lastHead.y * self.head.y, -1, 1)
    turn = math.atan2(cross, dot) / dt
  end
  self.lastHead = self.lastHead or vec3()
  self.lastHead:set(self.head)

  local zoom = MoveManager.zoomIn - MoveManager.zoomOut
  if zoom ~= 0 then self:setDistance(self.camDist - zoom * dt * 12) end

  -- Rotation bindings orbit the desired drone position around the vehicle.
  local yawInput = MoveManager.yawRelative + 8 * data.dt * (MoveManager.yawRight - MoveManager.yawLeft)
  local pitchInput = MoveManager.pitchRelative - 4 * data.dt * (MoveManager.pitchUp - MoveManager.pitchDown)
  self.orbitYaw = self.orbitYaw - math.rad(7 * yawInput)
  self.orbitPitch = clamp(self.orbitPitch + math.rad(7 * pitchInput), math.rad(-60), math.rad(60))

  local bx, by = -self.head.x * self.camDist, -self.head.y * self.camDist
  local cosYaw, sinYaw = math.cos(self.orbitYaw), math.sin(self.orbitYaw)
  local horizontalScale = math.cos(self.orbitPitch)
  local ox = (bx * cosYaw - by * sinYaw) * horizontalScale
  local oy = (bx * sinYaw + by * cosYaw) * horizontalScale
  local oz = self.height + math.sin(self.orbitPitch) * self.camDist
  local desired = vec3(car.x + ox, car.y + oy, car.z + oz) + self.positionOffset

  -- Movement bindings translate the desired position in the current camera frame.
  local mx = MoveManager.right - MoveManager.left + MoveManager.absXAxis
  local my = MoveManager.forward - MoveManager.backward + MoveManager.absYAxis
  local mz = MoveManager.up - MoveManager.down + MoveManager.absZAxis
  local inputLength = math.sqrt(mx * mx + my * my + mz * mz)
  if inputLength > 1e-5 and data.dt > 0 then
    local lookDir = car - desired
    if lookDir:squaredLength() < 1e-6 then lookDir:set(0, 1, 0) end
    local moveRotation = quatFromDir(lookDir:normalized(), up)
    local moveInput = vec3(mx, my, mz)
    if inputLength > 1 then moveInput:setScaled(1 / inputLength) end
    local nudgeSpeed = (data.fastSpeedModifier and 15 or 5) * data.dt
    self.positionOffset:setAdd(moveRotation * moveInput * nudgeSpeed)
    desired:set(car.x + ox, car.y + oy, car.z + oz)
    desired:setAdd(self.positionOffset)
  end

  desired.z = self:clampAltitude(desired.x, desired.y, desired.z, car)
  if not self.placed or data.teleported then self:placeInit(desired); self.placed = true end

  -- fly a weighted body toward the target: spring-damper with momentum + overshoot (underdamped),
  -- with a softer, acceleration-limited vertical axis so climbing feels heavier than the horizontal.
  if dt > 1e-6 then
    local k = 14 / clamp(self.floating, 0.2, 3)
    local c = 2 * 0.5 * math.sqrt(k) -- damping ratio 0.5 -> visible overshoot
    local kz, cz = k * 0.55, 2 * 0.5 * math.sqrt(k * 0.55)
    local rem = dt
    while rem > 1e-6 do
      local sdt = rem > 0.02 and 0.02 or rem -- sub-step so big fast-forward steps stay stable
      rem = rem - sdt
      self.pos.x, self.vel.x = springStep(self.pos.x, self.vel.x, desired.x, k, c, sdt)
      self.pos.y, self.vel.y = springStep(self.pos.y, self.vel.y, desired.y, k, c, sdt)
      self.pos.z, self.vel.z = springStep(self.pos.z, self.vel.z, desired.z, kz, cz, sdt, 8, 14)
    end
  end

  -- keep clear of buildings/meshes; cancel velocity into the correction so momentum can't punch through
  if self.safeDist > 0 then
    local sx, sy, sz = self:avoid(self.pos.x, self.pos.y, self.pos.z, car)
    local dx, dy, dz = sx - self.pos.x, sy - self.pos.y, sz - self.pos.z
    local cl = math.sqrt(dx * dx + dy * dy + dz * dz)
    if cl > 1e-4 then
      local nx, ny, nz = dx / cl, dy / cl, dz / cl
      local vn = self.vel.x * nx + self.vel.y * ny + self.vel.z * nz
      if vn < 0 then self.vel.x, self.vel.y, self.vel.z = self.vel.x - nx * vn, self.vel.y - ny * vn, self.vel.z - nz * vn end
      self.pos:set(sx, sy, sz)
    end
  end

  -- bank into turns
  local targetRoll = clamp(-turn * 0.15, -0.5, 0.5) * self.bank
  self.rollSmoothed = self.rollSmoothed + (targetRoll - self.rollSmoothed) * (1 - math.exp(-4 * dt))

  -- look at the car
  local dir = vec3(car.x - self.pos.x, car.y - self.pos.y, car.z - self.pos.z)
  if dir:squaredLength() < 1e-6 then dir:set(0, 1, 0) end
  dir:normalize()
  local q = quatFromDir(dir, up)
  q = q * quatFromEuler(0, self.rollSmoothed, 0) -- roll = camera-local Y

  -- subtle idle hover so it feels alive when nearly still
  self.t = self.t + dt
  idle:set(0.03 * math.sin(self.t * 0.7), 0.03 * math.sin(self.t * 0.9 + 1.3), 0.02 * math.sin(self.t * 1.3 + 2.1))

  data.res.pos = self.pos + idle
  data.res.rot = q
  data.res.fov = self.fov
  data.res.targetPos:set(car)
  return true
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
