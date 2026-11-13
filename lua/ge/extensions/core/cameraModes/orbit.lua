-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- ORBIT CAMERA
local collision = require('core/cameraModes/collision')

local C = {}
C.__index = C
local vecY = vec3(0,1,0)
local vecZ = vec3(0,0,1)
local lookBackVec = vec3(0,-0.3,0)

local upperSpeedThreshold = 10
local lowerSpeedThreshold = 1
local pitchTransitionDelay = 1.5
local hdegToRad = math.pi/180 * 0.5

local function getRot(base, vf, vz)
  local nyn = vf:normalized()
  local nxn = nyn:cross(vz):projectToOriginPlane(vecZ):normalized()
  local nzn = nxn:cross(nyn):normalized()
  local nbase = base:normalized()
  return math.atan2(-nbase:dot(nxn), nbase:dot(nyn)), math.asin(nbase:dot(nzn))
end

function C:init()
  self.target = false
  self.camLastTargetPos = vec3()
  self.camLastTargetPos2 = vec3()
  self.camLastPos = vec3()
  self.camLastPos2 = vec3()
  self.camLastPosPerp = vec3()
  self.cameraResetted = 3
  self.lockCamera = false
  self.orbitOffset = vec3()
  self.preResetPos = vec3(1e+300, 0, 0)
  self.smoothedPitchOffset = newTemporalSigmoidSmoothing(2, 2, 2, 2)
  self.dynamicPitchQuat = quat()
  self.targetCenter = vec3(0, 0, 0)
  self.targetLeft = vec3(0, 0, 0)
  self.targetBack = vec3(0, 0, 0)
  self.configChanged = false
  self.icon = "aperture"
  self.collision = collision()
  self.collision:init()

  self:onVehicleCameraConfigChanged()
  self:onSettingsChanged()
  self:reset()
end

function C:calculateDynamicPitchLimit(data, targetPos)
  if not self.dynamicPitchLimit then
    local vehId = data.veh:getID()
    local veh = getObjectByID(vehId)
    local bottomRear = vec3()
    local bbHalfExtents = vec3()
    local bbCenter = vec3()

    bbHalfExtents:set(be:getObjectOOBBHalfExtentsXYZ(vehId))
    bottomRear:setAdd(vec3(0,-bbHalfExtents.y,0))
    bottomRear:setAdd(vec3(0,0,-bbHalfExtents.z))
    bbCenter:set(be:getObjectOOBBCenterXYZ(vehId))

    -- rotate targetPos around bbCenter by the inverse of the vehicle rotation
    local vehRot = quat(0,0,1,0) * quat(veh:getClusterRotationSlow(veh:getRefNodeId()))
    local localTargetPos = vehRot:inversed() * (targetPos - bbCenter)

    -- convert bottomRear to target pos coordinate system
    bottomRear:setSub(localTargetPos)

    -- defaultCamPos is relative to targetPos
    local defaultCamPos = vec3()

    defaultCamPos:set(
    math.sin(math.rad(self.defaultRotation.x)) * math.cos(math.rad(self.defaultRotation.y))
    , -math.cos(math.rad(self.defaultRotation.x)) * math.cos(math.rad(self.defaultRotation.y))
    , -math.sin(math.rad(self.defaultRotation.y)))
    defaultCamPos = defaultCamPos * self.defaultDistance

    local bottomRearDir = bottomRear - defaultCamPos
    local targetDir = -defaultCamPos
    local angleCamTargetCamBottomRear = math.acos(bottomRearDir:cosAngle(targetDir))

    self.dynamicPitchLimit = math.max(math.rad(self.fov/2) - angleCamTargetCamBottomRear, 0)
  end
  return self.dynamicPitchLimit
end

function C:onVehicleCameraConfigChanged()
  self.configChanged = true
  if self.defaultRotation == nil then
    self.defaultRotation = vec3(0, -17, 0)
  end
  self.defaultRotation = vec3(self.defaultRotation)
  self.offset = vec3(self.offset)
  if not self.camRot then self.camRot = vec3(self.defaultRotation) end
  self.camLastRot = vec3(math.rad(self.camRot.x), math.rad(self.camRot.y), 0)
  self.camMinDist = self.distanceMin or 3
  self.camMaxDist = (self.distanceMin or 5) * 10
  self.camDist = self.distance or 5
  self.camLastDist = self.distance or 5
  self.defaultDistance = self.distance or 5
  self.mode = self.mode or 'ref'
  self.skipFovModifier = self.skipFovModifier or false
  self.smoothedPitchOffset:set(0)
  self.dynamicPitchQuat:setFromEuler(0, 0, 0)
  self.dynamicPitchActive = false
  self.aboveCamPitchThreshold = false
  self.dynamicPitchLimit = nil
  self.fov = self.fov or 65
end

function C:onSettingsChanged()
  core_camera.clearInputs() --TODO is this really necessary?
  self.fovModifier = settings.getValue('cameraOrbitFovModifier')
  self.relaxation = settings.getValue('cameraOrbitRelaxation') or 3
  self.maxDynamicFov = settings.getValue('cameraOrbitMaxDynamicFov') or 35
  self.maxDynamicPitch = math.rad(settings.getValue('cameraOrbitMaxDrivingPitch') or 0)
  self.maxDynamicOffset = settings.getValue('cameraOrbitMaxDynamicOffset') or 0
  self.smoothingEnabled = settings.getValue('cameraOrbitSmoothing', true)
  self.multiseat = settings.getValue('multiseat')
  self.collision:onSettingsChanged()
end

function C:onVehicleSwitched()
  self.collision:onVehicleSwitched()
end

function C:reset()
  if self.cameraResetted == 0 then
    self.preResetPos = vec3(self.camLastTargetPos2)
    self.cameraResetted = 3
    self.collision:init()
  end
end

function C:setRotation(rot)
  self.camRot = vec3(rot)
end

-- Persist/restore this camera's own state for the video-stream views (see core_camera
-- get/setContextCameraState): the orbit rotation, distance and zoom.
function C:serialize()
  return {
    rot = self.camRot and { x = self.camRot.x, y = self.camRot.y, z = self.camRot.z } or nil,
    dist = self.camDist,
    fov = self.fov,
  }
end

function C:deserialize(s)
  if type(s) ~= 'table' then return end
  if s.rot then
    self:setRotation(vec3(s.rot.x, s.rot.y, s.rot.z))
    if self.camLastRot then self.camLastRot:set(math.rad(s.rot.x), math.rad(s.rot.y), 0) end
  end
  if s.dist then self.camDist = s.dist; self.camLastDist = s.dist end
  if s.fov then self.fov = s.fov end
  self.cameraResetted = 0 -- keep the restored rotation/distance instead of snapping to the default next frame
end

function C:setFOV(fov)
  self.fov = fov
end

-- tunables for the camera-control / video-stream UI: distance, smoothing and FOV
function C:listParams()
  return {
    { key = 'dist', icon = 'fa-ruler-horizontal', title = 'Distance', kind = 'range', type = 'float', value = self.camDist, default = self.defaultDistance, min = self.camMinDist or 1, max = self.camMaxDist or 50, step = 0.5, unit = 'm' },
    { key = 'smooth', icon = 'fa-wand-magic-sparkles', title = 'Smoothing', kind = 'bool', type = 'bool', value = self.smoothingEnabled == true },
    { key = 'fov', icon = 'fa-expand', title = 'Field of view', kind = 'range', type = 'int', value = self.fov, default = 65, min = 10, max = 140, step = 1, unit = '°' },
  }
end

function C:setParam(key, value)
  if key == 'dist' then self:setDistance(tonumber(value) or self.camDist)
  elseif key == 'smooth' then self.smoothingEnabled = value and true or false
  elseif key == 'fov' then self:setFOV(tonumber(value) or self.fov) end
end

function C:setOffset(v)
  self.orbitOffset = vec3(v)
end

function C:setRefNodes(centerNodeID, leftNodeID, backNodeID, dynamicFovRearNodeID)
  self.refNodes = self.refNodes or {}
  self.refNodes.ref = centerNodeID
  self.refNodes.left = leftNodeID
  self.refNodes.back = backNodeID
  self.rearNodeID = dynamicFovRearNodeID -- specifies which area of the vehicle will have constant screen-size during dolly zoom effect (dynamic FOV effect)
end

-- params in global coords
function C:setRef(center, left, back)
  local prevTarget = self.target
  self.target = center ~= nil and true or false
  self.targetCenter = center
  self.targetLeft = left
  self.targetBack = back
  if self.target ~= prevTarget then self:reset() end
end

function C:setTargetMode(targetMode, camBase)
  self.mode = targetMode
  self.camBase = camBase
end

function C:setDefaultDistance(d)
  self.defaultDistance = d
end

function C:setDistance(d)
  self.camDist = d
end

function C:setMaxDistance(d)
  self.camMaxDist = d
end

function C:setDefaultRotation(rot)
  self.defaultRotation = rot
end

function C:setSkipFovModifier(skip)
  self.skipFovModifier = skip
end

local function isManualRotation(mm)
  return mm.yawRelative ~= 0 or mm.pitchRelative ~= 0 or mm.yawRight > 0.01 or mm.yawLeft > 0.01 or mm.pitchDown > 0.01 or mm.pitchUp > 0.01
end

local ref, left, back = vec3(), vec3(), vec3()

local nx, ny, nz = vec3(), vec3(), vec3()

local targetPos, camdir, dir = vec3(), vec3(), vec3()

local lastCamPointVec, lastCamLastPerp, moveDir = vec3(), vec3(), vec3()

local rot, calculatedCamPos, camPos, updir, rear = vec3(), vec3(), vec3(), vec3(), vec3()

local lookDir, tempQuatB = vec3(), quat()

local bbCenter, bbHalfAxis1, lookBackDir = vec3(), vec3(), vec3()

function C:update(data)
  data.res.collisionCompatible = true
  if self.target then
    ref:set(self.targetCenter)
    left:set(self.targetLeft)
    back:set(self.targetBack)
  else
    if self.refNodes then
      ref:set(data.veh:getNodePositionXYZ(self.refNodes.ref))
      left:set(data.veh:getNodePositionXYZ(self.refNodes.left))
      back:set(data.veh:getNodePositionXYZ(self.refNodes.back))
    end
  end

  -- reset cam
  if self.cameraResetted == 3 then
    if self.lockCamera == false or self.configChanged == false then
      -- if a reload hasn't just happened
      self.camRot:set(self.defaultRotation)
      self.camDist = self.defaultDistance
      self.lockCamera = false
      self.accumManualYaw = 0
      core_camera.clearInputs()
    else
      self.cameraResetted = 0
    end
    self.configChanged = false
  end
  if data.teleported then
    self.smoothedPitchOffset:set(0)
    self.dynamicPitchQuat:setFromEuler(0, 0, 0)
    self.dynamicPitchActive = false
  end

  -- calculate the camera offset: rotate with the vehicle
  nx:setSub2(left, ref)
  ny:setSub2(back, ref)
  nz:setCross(nx, ny)
  ny:setCross(nz, nx)
  nx:normalize()
  ny:normalize()
  nz:normalize()

  if not self.camBase or self.cameraResetted > 0 then
    -- this needs to happen here as on init the node data is not existing yet
    if self.offset and self.offset.x and nx:length() ~= 0 and ny:length() ~= 0 then
      self.camBase = vec3(self.offset.x, self.offset.y, self.offset.z)
      local baseX, baseY, baseZ = self.camBase.x, self.camBase.y, self.camBase.z
      self.camOffset2 = self.camOffset2 or vec3()
      self.camOffset2:set(nx.x * baseX + ny.x * baseY + nz.x * baseZ, nx.y * baseX + ny.y * baseY + nz.y * baseZ, nx.z * baseX + ny.z * baseY + nz.z * baseZ)
      targetPos:setAdd2(data.pos, ref)
      if not self.target then
        targetPos:setAdd(self.camOffset2)
      end
    elseif self.camOffset2 then
      targetPos:setAdd2(data.pos, ref)
      targetPos:setAdd(self.camOffset2)
      self.camOffset2 = nil -- we only use previous offset for only one frame when needed
    else
      targetPos:setSub2(data.veh:getBBCenter(), push3(data.pos) + ref)
    end
  else
    if not self.camOffset2 then self.camOffset2 = vec3() end
    local baseX, baseY, baseZ = self.camBase.x, self.camBase.y, self.camBase.z
    self.camOffset2:set(nx.x * baseX + ny.x * baseY + nz.x * baseZ, nx.y * baseX + ny.y * baseY + nz.y * baseZ, nx.z * baseX + ny.z * baseY + nz.z * baseZ)
    targetPos:setAdd2(data.pos, ref)
    targetPos:setAdd(self.camOffset2)
  end

  local mm = MoveManager
  local yawDif = 0.1*(mm.yawRight - mm.yawLeft)
  local pitchDif = 0.1*(mm.pitchDown - mm.pitchUp)
  dir:set(vecY)

  if self.cameraResetted == 0 then
    if self.lockCamera == true then
      camdir:set(push3(self.camLastTargetPos) - self.camLastPos2)
      if (push3(targetPos) - self.camLastTargetPos):dot(camdir) < 0 then
        self.camRot.x = self.camRot.x + 180
        self.camLastRot.x = self.camLastRot.x + math.pi
        self.camLastPos2:set(push3(targetPos) + camdir)
        self.camLastPosPerp:set(push3(vecZ):cross(camdir):normalized() * (self.relaxation * -0.8) + targetPos)
      end
    end
  else
    self.lockCamera = false
    if self.cameraResetted >= 1 then
      dir:setSub2(ref, back)
      if targetPos:distance(self.preResetPos) < 4 then
        -- smoothly rotate back to default
        local rx, ry = getRot((self.camLastTargetPos - self.camLastPos), dir, nz)
        self.camLastRot.x = rx
        self.camLastRot.y = ry
        self.camRot.x = self.defaultRotation.x
      else
        self.camRot:set(self.defaultRotation)
        self.camLastRot:set(math.rad(self.camRot.x), math.rad(self.camRot.y) * 1.5, 0)
      end
      self.camLastPos2:setSub2(targetPos, dir)
      updir:setCross(vecZ, dir)
      updir:normalize()
      updir:setScaled(self.relaxation * -0.8)
      self.camLastPosPerp:setAdd2(updir, targetPos)
      dir:normalize()
    end
  end

  local maxRot = 4.5
  if yawDif ~= 0 or pitchDif ~= 0 or mm.yawRelative ~= 0 or mm.pitchRelative ~= 0 then
    maxRot = 1000
  end

  -- mouse rotation
  local dtfactor = data.dt * 1000
  local maxRotDt = maxRot * data.dt
  local mouseYaw = clamp(mm.yawRelative * 10, -maxRotDt, maxRotDt) + yawDif * dtfactor
  local mousePitch = clamp(mm.pitchRelative * -10, -maxRotDt, maxRotDt) + pitchDif * dtfactor
  if mouseYaw ~= 0 or mousePitch ~= 0 then
    -- only lock the camera once enough horizontal movement has accumulated
    self.accumManualYaw = (self.accumManualYaw or 0) + mouseYaw
    if self.cameraResetted == 0 and math.abs(self.accumManualYaw) > 10 then
      self.lockCamera = true
    end
    self.camRot.x = self.camRot.x - mouseYaw
    self.camRot.y = self.camRot.y - mousePitch
    --self.camRot.z = self.camRot.z + 300*data.dt*(MoveManager.rollRight - MoveManager.rollLeft)
  end

  self.camRot.y = math.min(math.max(self.camRot.y, -85), 85)

  -- make sure the rotation is never bigger than 2 PI
  if self.camRot.x > 180 then
    self.camRot.x = self.camRot.x - 360
  elseif self.camRot.x < -180 then
    self.camRot.x = self.camRot.x + 360
  end

  if self.camLastRot.x > math.pi then
    self.camLastRot.x = self.camLastRot.x - math.pi * 2
  elseif self.camLastRot.x < -math.pi then
    self.camLastRot.x = self.camLastRot.x + math.pi * 2
  end

  -- If the camera is colliding with something, dont increase the camDist
  local zoomChange = mm.zoomIn - mm.zoomOut
  local newCamDist = self.camDist
  if zoomChange ~= 0 then
    local adjustedSpeed = data.fastSpeedModifier and data.speed * 3 or data.speed
    local zoomStep = zoomChange * dtfactor * adjustedSpeed * 0.0001 * core_camera.getFovDeg()
    local collidingCamDist = self.collision:collidingCamDistance()
    if collidingCamDist then
      if zoomChange < 0 then newCamDist = collidingCamDist + zoomStep end
    else
      newCamDist = self.camDist + zoomStep
    end
  end
  self.camDist = clamp(newCamDist, self.camMinDist, self.camMaxDist or math.huge)

  if nx:squaredLength() == 0 or ny:squaredLength() == 0 then
    data.res.pos = data.pos
    data.res.rot = quatFromDir(vecY, vecZ)
    return false
  end

  if self.cameraResetted ~= 1 then
    lastCamPointVec:setSub2(targetPos, self.camLastPos2)
    lastCamLastPerp:setSub2(self.camLastPosPerp, targetPos)
    if lastCamPointVec:length() < self.relaxation and lastCamLastPerp:length() > self.relaxation * 0.8 then
      moveDir:setSub2(targetPos, self.camLastTargetPos); moveDir:normalize()
      if math.abs(push3(lastCamPointVec):normalized():dot(moveDir)) > math.abs(push3(lastCamLastPerp):normalized():dot(moveDir)) then
        self.camLastPos2:set(push3(lastCamPointVec):cross(lastCamLastPerp):cross(lastCamLastPerp):normalized() + targetPos)
        lastCamPointVec:setSub2(targetPos, self.camLastPos2)
      end
    end
    dir:set(lastCamPointVec)
    dir:normalize()

    -- flatten the rotation plane when camera moves perpendicularly
    local dirX, dirY = dir.x, dir.y
    local dirxylen = math.sqrt(dirX*dirX + dirY*dirY)
    local coef = math.sqrt(math.max(0, 1 - dirxylen))
    local dirWeight = math.max(0, 1 - coef)
    local dirxyWeight = coef / (dirxylen + 1e-30)
    dir:set(dirX * dirWeight + dirX * dirxyWeight, dirY * dirWeight + dirY * dirxyWeight, dir.z * dirWeight)
    dir:normalize()
  end

  lastCamPointVec:setSub2(self.camLastPos2, targetPos)
  lastCamPointVec:resize(self.relaxation)
  self.camLastPos2:setAdd2(lastCamPointVec, targetPos)

  rot:set(math.rad(self.camRot.x), math.rad(self.camRot.y), math.rad(self.camRot.z))

  -- smoothing
  local dist = self.camDist
  if self.smoothingEnabled then
    local ratio = 1 / (data.dt * 8)
    local ratioSum = ratio + 1
    local newWeight = 1 / ratioSum
    local lastWeight = ratio / ratioSum

    -- more than half a turn apart means the target is across the +-pi seam: wrap to take the short way around
    local rotxDelta = self.camLastRot.x - rot.x
    if math.abs(rotxDelta) > math.pi then
      self.camLastRot.x = self.camLastRot.x - sign(rotxDelta) * 2 * math.pi
    end

    local rotxDiff = newWeight * (rot.x - self.camLastRot.x)
    rot.x = self.camLastRot.x + clamp(rotxDiff, -maxRotDt, maxRotDt)
    rot.y = newWeight * rot.y + lastWeight * self.camLastRot.y
    dist = newWeight * self.camDist + lastWeight * self.camLastDist
  end

  local velLength = data.vel:length()

  local fov = self.fov
  local fovdistDiff = 0
  local fovModifier = self.skipFovModifier and 0 or self.fovModifier

  if (not self.target) and self.fov and fovModifier and self.maxDynamicFov and self.camDist then
    -- find where the rear of the vehicle is. this is roughly(*) the vehicle area that will occupy the same size in screen space, no matter the speed.
    -- (*) the camera is usually not right behind the car, but behind+higher: this angle is ignored for simplicity. The bounding box is usually a bit too big anyway, so the end result is close enough that we can ignore this asterisk (*) in our calculations. In the same way, if the user rotates the camera left or right, we ignore that horizontal angle too (we always use the same refToRear distance)
    if self.rearNodeID then
      rear:set(data.veh:getNodePositionXYZ(self.rearNodeID))
      rear:setAdd(data.pos)
    else
      local vehId = data.veh:getID()
      bbCenter:set(be:getObjectOOBBCenterXYZ(vehId))
      bbHalfAxis1:set(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
      rear:set(bbCenter)
      rear:setAdd(bbHalfAxis1)
    end

    -- compute how wide the rear of the car is (in screen space) when using the jbeam config (self.camDist). This 'originalWidth' will be preserved in screen space, no matter the FOV we end up applying
    local refToRear = rear:distance(targetPos)

    -- compute how much more FOV we're going to add depending on speed (from zero up to self.maxDynamicFov)
    fov = self.fov + fovModifier + self.maxDynamicFov * (math.min(1, velLength/130))

    -- the jbeam-config half-FOV tangent only moves when the fov settings do, so keep the last one around
    local baseFov = self.fov + fovModifier
    if baseFov ~= self.lastBaseFov then
      self.lastBaseFov = baseFov
      self.baseFovTan = math.tan(baseFov * hdegToRad)
    end

    -- apply final field of view
    -- compute and apply the camera distance that will preserve the originalWidth
    fovdistDiff = (self.camDist - refToRear) * (self.baseFovTan / math.tan(fov * hdegToRad) - 1)
  end

  local rotB = rot
  local dirB = dir

  if data.lookBack then
    rotB = lookBackVec
    lookBackDir:setSub2(back, ref)
    dirB = lookBackDir
  end

  local cosPitch = math.cos(rotB.y)
  calculatedCamPos:set(
    math.sin(rotB.x) * cosPitch
    , -math.cos(rotB.x) * cosPitch
    , -math.sin(rotB.y))
  tempQuatB:setFromDir(dirB)
  calculatedCamPos:setRotate(tempQuatB)
  calculatedCamPos:setScaled(dist + fovdistDiff)

  camPos:setAdd2(calculatedCamPos, targetPos)
  camPos:setAdd(self.orbitOffset)
  updir:setCross(vecZ, dir)
  updir:resize(self.relaxation * -0.8)
  self.camLastPosPerp:setAdd2(updir, targetPos)

  self.camLastTargetPos2:set(self.camLastTargetPos)
  self.camLastTargetPos:set(targetPos)
  self.camLastPos:set(camPos)
  self.camLastRot:set(rot)
  self.camLastDist = dist
  self.cameraResetted = math.max(self.cameraResetted - 1, 0)

  if isManualRotation(mm) then
    self.timeSinceManualRotation = 0
  else
    self.timeSinceManualRotation = self.timeSinceManualRotation and self.timeSinceManualRotation + data.dt or 0
  end

  if self.timeSinceManualRotation > 1 then
    -- Handle camera pitch threshold logic
    if self.aboveCamPitchThreshold then
      if velLength < lowerSpeedThreshold then
        -- Set initial timer value based on pitch offset
        local startTime = self.smoothedPitchOffset:value() == 1 and pitchTransitionDelay or 0
        self.belowThresholdTimer = (self.belowThresholdTimer or startTime) - data.dt
        -- Reset pitch threshold when timer expires
        if self.belowThresholdTimer <= 0 then
          self.aboveCamPitchThreshold = false
          self.belowThresholdTimer = nil
        end
      else
        -- Reset timer if speed increases
        self.belowThresholdTimer = nil
      end
    else
      self.aboveCamPitchThreshold = velLength > upperSpeedThreshold
    end

    -- dynamic pitch calculation
    local targetLerpValue = self.aboveCamPitchThreshold and 1 or 0
    self:calculateDynamicPitchLimit(data, targetPos)

    local normalizedPitchOffset
    if targetLerpValue == 1 then
      normalizedPitchOffset = self.smoothedPitchOffset:getWithRateAccel(targetLerpValue, data.dt, 0.3, 0.3, 0.3)
    else
      normalizedPitchOffset = self.smoothedPitchOffset:getWithRateAccel(targetLerpValue, data.dt, 0.5, 0.5, 0.5)
    end

    local maxDynamicPitch = self.multiseat and 0 or self.maxDynamicPitch
    local dynamicPitch = -math.min(maxDynamicPitch, self.dynamicPitchLimit) * normalizedPitchOffset
    self.dynamicPitchQuat:setFromEuler(dynamicPitch, 0, 0)
    self.dynamicPitchActive = dynamicPitch ~= 0
  else
    self.smoothedPitchOffset:get(self.smoothedPitchOffset:value(), data.dt)
  end

  -- height offset calculation
  local velocity = math.min(velLength, 70)
  local smoothedVelocity = math.max(velocity * 0.05 - 0.2, 0.0)
  local lengthValue = math.min((1.4 * smoothedVelocity) / (smoothedVelocity + 4.1), 1)

  lookDir:setSub2(targetPos, camPos)
  data.res.pos:set(camPos.x, camPos.y, camPos.z + lengthValue * self.maxDynamicOffset)
  data.res.rot:setFromDir(lookDir)
  if self.dynamicPitchActive then
    data.res.rot:setMul2(self.dynamicPitchQuat, data.res.rot)
  end
  data.res.fov = fov
  data.res.targetPos:set(targetPos)
  self.collision:update(data)
  return true
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end

