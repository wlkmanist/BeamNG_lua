
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local smoothingStrengthFac = 20.0 -- A factor which controls the strength of the smoothing applied to the acceleration/gyroscopic readings.

local epsilon = 1e-30

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module constants.
local max = math.max
local oneThird = 1.0 / 3.0

-- Module state.
local state = {} -- The persistant state of this sensor instance.
local sm = {} -- The smoother state.
local edge1, edge2, edge1Norm, edge2Norm = vec3(), vec3(), vec3(), vec3()
local normal, projPos, currentPos, accel = vec3(), vec3(), vec3(), vec3()
local a1, a2, a3, v1, v2, v3 = vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
local baryCenter, translation, aRot1, aRot2, aRot3 = vec3(), vec3(), vec3(), vec3(), vec3()
local r1, r2, r3, r, curl = vec3(), vec3(), vec3(), vec3(), vec3()
local totalAccel, vCenter, angVel, angAccel = vec3(), vec3(), vec3(), vec3()
local forwardTS, upTS, rightTS, forwardWS, upWS, rightWS = vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
local tempVec1, tempVec2, tempVec3, tmpPosWS = vec3(), vec3(), vec3(), vec3()


-- Gets the latest reading data for this sensor instance.
local function getLatest() return state.latestReading end

-- Sets the flag which indicates if this sensor instance should include gravity in its computation.
local function setIsUsingGravity(value) state.isUsingGravity = value end

-- Sets the flag which indicates if this sensor instance should be visualised.
local function setIsVisualised(value) state.isVisualised = value end

-- Increments the timer which tracks the time since the last poll.
local function incrementTimer(dtSim) state.timeSinceLastPoll = state.timeSinceLastPoll + dtSim end

-- Gets the data for this sensor instance (state and readings).
local function getSensorData()
  tmpPosWS:setAdd2(currentPos, obj:getPosition())  -- Vehicle space -> World space.
  return {
    isVisualised = state.isVisualised,
    isUsingGravity = state.isUsingGravity,
    timeSinceLastPoll = state.timeSinceLastPoll,
    GFXUpdateTime = state.GFXUpdateTime,
    currentPos = tmpPosWS,
    currentDir = forwardWS,
    rawReadings = state.readings,
  }
end

-- Computes the sensor frame (forward, up, right) in world space from triangle geometry.
local function computeSensorFrame(node1, node2, node3)
  -- Compute triangle edges and normal.
  edge1:setSub2(node2, node1)
  edge2:setSub2(node3, node1)
  edge1Norm:set(edge1)
  edge1Norm:normalize()
  edge2Norm:set(edge2)
  edge2Norm:normalize()
  normal:setCross(edge1Norm, edge2Norm)

  -- Compute the local triangle Frenet frame (triangle space).
  forwardTS:set(state.triangleSpaceForward)
  upTS:set(state.triangleSpaceUp)
  rightTS:setCross(edge1Norm, normal)

  -- Transform the triangle space Frenet frame to world space.
  tempVec1:setScaled2(edge1Norm, forwardTS.x)
  tempVec2:setScaled2(normal, forwardTS.y)
  tempVec3:setScaled2(rightTS, forwardTS.z)
  forwardWS:setAdd2(tempVec1, tempVec2)
  forwardWS:setAdd(tempVec3)
  forwardWS:normalize()
  tempVec1:setScaled2(edge1Norm, upTS.x)
  tempVec2:setScaled2(normal, upTS.y)
  tempVec3:setScaled2(rightTS, upTS.z)
  upWS:setAdd2(tempVec1, tempVec2)
  upWS:setAdd(tempVec3)
  upWS:normalize()
  rightWS:setCross(forwardWS, upWS)
  rightWS:normalize()
end

local function computeInitialGravityInSensorFrame()
  if not state.isUsingGravity then
    return 0.0, 0.0, 0.0 -- No gravity, so no need to compute anything.
  end
  local n1, n2, n3 = obj:getNodePosition(state.node1Idx), obj:getNodePosition(state.node2Idx), obj:getNodePosition(state.node3Idx) -- Initial node positions.
  computeSensorFrame(n1, n2, n3) -- Compute the sensor frame in world space.
  local gravity = obj:getGravityVector() -- Gravity vector in world space.
  return gravity:dot(forwardWS), gravity:dot(upWS), gravity:dot(rightWS) -- Transform gravity from world space to the sensor frame.
end

-- Initialises all smoothers with proper gravity values.
-- [Gravity is included, so as to avoid jumps in the data at startup.]
local function initSmoothers()
  local initGravX, initGravY, initGravZ = computeInitialGravityInSensorFrame() -- Gravity vector in sensor frame.
  local inOutRate = state.inOutRate

  -- Create acceleration smoothers (3 passes).
  sm.sm1AccX = newTemporalSmoothingNonLinear(inOutRate, inOutRate, initGravX)
  sm.sm1AccY = newTemporalSmoothingNonLinear(inOutRate, inOutRate, initGravY)
  sm.sm1AccZ = newTemporalSmoothingNonLinear(inOutRate, inOutRate, initGravZ)
  sm.sm2AccX = newTemporalSmoothingNonLinear(inOutRate, inOutRate, initGravX)
  sm.sm2AccY = newTemporalSmoothingNonLinear(inOutRate, inOutRate, initGravY)
  sm.sm2AccZ = newTemporalSmoothingNonLinear(inOutRate, inOutRate, initGravZ)

  -- Create gyroscopic smoothers.
  sm.sm1GyroX = newTemporalSmoothingNonLinear(inOutRate, inOutRate, 0.0)
  sm.sm1GyroY = newTemporalSmoothingNonLinear(inOutRate, inOutRate, 0.0)
  sm.sm1GyroZ = newTemporalSmoothingNonLinear(inOutRate, inOutRate, 0.0)
  sm.sm2GyroX = newTemporalSmoothingNonLinear(inOutRate, inOutRate, 0.0)
  sm.sm2GyroY = newTemporalSmoothingNonLinear(inOutRate, inOutRate, 0.0)
  sm.sm2GyroZ = newTemporalSmoothingNonLinear(inOutRate, inOutRate, 0.0)
end

-- Initialises this sensor instance.
local function init(data)
  state.sensorId = data.sensorId -- The unique Id (integer) for this sensor instance.

  state.node1Idx, state.node2Idx, state.node3Idx = data.nodeIndex1, data.nodeIndex2, data.nodeIndex3 -- The attach triangle node indices.

  state.b1, state.b2, state.b3 = data.u, data.v, 1.0 - data.u - data.v -- Linear combo in barycentric coords, of the sensor on its attachment triangle.
  state.w1, state.w2, state.w3 = max(0.0, state.b1), max(0.0, state.b2), max(0.0, state.b3) -- Positive-valued barycentric interpolation weights.

  state.triangleSpaceForward = data.triangleSpaceForward -- The 'forward' vector in triangle space.
  state.triangleSpaceUp = data.triangleSpaceUp -- The 'up' vector in triangle space.
  state.signedProjDist = data.signedProjDist -- The signed distance from the sensor triangle plane to the sensor.

  state.isVisualised = data.isVisualised -- A flag which indicates if this Advanced IMU sensor should be visualised.
  state.isUsingGravity = data.isUsingGravity -- A flag which indicates if this Advanced IMU should include gravity in its computation.

  state.physicsTimer = 0.0 -- State for a timer to track the time since the last physics step update.
  state.physicsUpdateTime = max(physicsDt, data.physicsUpdateTime) -- How often the physics should be updated, in seconds.
  state.GFXUpdateTime = max(physicsDt, data.GFXUpdateTime) -- The GFX step update time (ie how often readings data is available to the user).
  state.timeSinceLastPoll = 0.0 -- The time since the last graphics step update.

  state.smoothedAccelReading, state.smoothedGyroReading = vec3(), vec3() -- The smoothed acceleration/gyroscopic readings.
  state.smootherStrength = math.max(0.0, math.min(5.0, data.smootherStrength)) -- The strength of the smoothing applied to the acceleration/gyroscopic readings.
  state.inOutRate = smoothingStrengthFac / state.smootherStrength -- Inverse proportional to smoothing strength.
  state.readings = {} -- The array of raw sensor readings (since the last graphics step update).

  initSmoothers() -- Initialise the smoothers.

  -- Initialise the latest reading structure.
  state.latestReading = {
    time = 0.0,
    mass = 0.0,
    accRaw = { 0, 0, 0 },
    accSmooth = { 0, 0, 0 },
    angVel = { 0, 0, 0 },
    angVelSmooth = { 0, 0, 0 },
    angAccel = { 0, 0, 0 },
    pos = { 0, 0, 0 },
    dirX = { 0, 0, 0 },
    dirY = { 0, 0, 0 },
    dirZ = { 0, 0, 0 },
  }
end

-- Resets this sensor instance.
local function reset()
  table.clear(state.readings) -- Clear the readings array.
  state.timeSinceLastPoll = state.timeSinceLastPoll % max(state.GFXUpdateTime, epsilon) -- Reset the timer.
end

-- Physics step update for this sensor instance.
local function update(dtSim)
  -- Manage the update timer. [We cycle the timer to ensure update regularity.]
  state.physicsTimer = state.physicsTimer + dtSim
  if state.physicsTimer < state.physicsUpdateTime then
    return -- Not ready for a physics step update yet. Leave immediately.
  end
  local trueDt = state.physicsTimer -- The true time delta since last physics update.
  state.physicsTimer = state.physicsTimer - state.physicsUpdateTime -- Wind back the timer, respecting the remainder time.

  -- Compute the current position of the sensor, in world space.
  local node1 = obj:getNodePosition(state.node1Idx) -- Current node positions, in world space.
  local node2 = obj:getNodePosition(state.node2Idx)
  local node3 = obj:getNodePosition(state.node3Idx)
  edge1:setSub2(node2, node1) -- Attach triangle edge vectors.
  edge2:setSub2(node3, node1)
  edge1Norm:set(edge1)
  edge1Norm:normalize()
  edge2Norm:set(edge2)
  edge2Norm:normalize()
  normal:setCross(edge1Norm, edge2Norm) -- Triangle normal.
  normal:normalize()
  tempVec1:setScaled2(edge2, state.b1)
  tempVec2:setScaled2(edge1, state.b2)
  projPos:setAdd2(node1, tempVec1)
  projPos:setAdd(tempVec2) -- The projection of the world-space position onto the triangle plane.
  tempVec3:setScaled2(normal, state.signedProjDist)
  currentPos:setAdd2(projPos, tempVec3) -- The current world-space position of the sensor.

  -- Get the kinematics properties at each triangle corner.
  local m1, m2, m3 = obj:getNodeMass(state.node1Idx), obj:getNodeMass(state.node2Idx), obj:getNodeMass(state.node3Idx) -- Node masses.
  a1:setScaled2(obj:getNodeForceVector(state.node1Idx), 1.0 / m1) -- Compute acceleration at each node, using Newton II [a := F / m].
  a2:setScaled2(obj:getNodeForceVector(state.node2Idx), 1.0 / m2)
  a3:setScaled2(obj:getNodeForceVector(state.node3Idx), 1.0 / m3)
  v1:set(obj:getNodeVelocityVector(state.node1Idx)) -- Velocity vectors at each node.
  v2:set(obj:getNodeVelocityVector(state.node2Idx))
  v3:set(obj:getNodeVelocityVector(state.node3Idx))

  -- Isolate the rotational component of each node acceleration vector, by subtracting the translation component.
  translation:setAdd2(a1, a2)
  translation:setAdd(a3)
  translation:setScaled(oneThird)
  aRot1:setSub2(a1, translation)
  aRot2:setSub2(a2, translation)
  aRot3:setSub2(a3, translation)

  -- Compute the barycenter of the attachment triangle.
  baryCenter:setAdd2(node1, node2)
  baryCenter:setAdd(node3)
  baryCenter:setScaled(oneThird)

  -- Compute the curl and divergence at the projected point (on triangle plane).
  r1:setSub2(node1, baryCenter) -- Vectors from the barycenter to each node.
  r2:setSub2(node2, baryCenter)
  r3:setSub2(node3, baryCenter)
  tempVec1:setCross(r1, aRot1)
  tempVec1:setScaled(state.w1)
  tempVec2:setCross(r2, aRot2)
  tempVec2:setScaled(state.w2)
  tempVec3:setCross(r3, aRot3)
  tempVec3:setScaled(state.w3)
  curl:setAdd2(tempVec1, tempVec2) -- The curl at the projected point.
  curl:setAdd(tempVec3)
  local divergence = r1:dot(aRot1) * state.w1 + r2:dot(aRot2) * state.w2 + r3:dot(aRot3) * state.w3 -- The divergence at the projected point.

  -- Compute the total acceleration vector at the sensor position, and also the angular velocity/acceleration terms.
  r:setSub2(currentPos, baryCenter)
  local invDenom = 1.0 / (r1:squaredLength() * state.w1 + r2:squaredLength() * state.w2 + r3:squaredLength() * state.w3 + epsilon)
  tempVec1:setCross(curl, r)
  tempVec2:setScaled2(r, divergence)
  tempVec3:setAdd2(tempVec1, tempVec2)
  tempVec3:setScaled(invDenom)
  totalAccel:setAdd2(translation, tempVec3)
  if state.isUsingGravity then -- Add on the acceleration due to gravity (as a vector), if requested.
    totalAccel:setAdd(obj:getGravityVector())
  end

  -- Compute the angular velocity at the projected point.
  vCenter:setAdd2(v1, v2)
  vCenter:setAdd(v3)
  vCenter:setScaled(oneThird)
  tempVec1:setSub2(v1, vCenter)
  tempVec2:setSub2(v2, vCenter)
  tempVec3:setSub2(v3, vCenter)
  angVel:setCross(r1, tempVec1)
  angVel:setScaled(state.w1) -- The angular velocity at the projected point.

  -- Compute the angular acceleration at the projected point.
  tempVec1:setCross(r2, tempVec2)
  tempVec1:setScaled(state.w2)
  tempVec2:setCross(r3, tempVec3)
  tempVec2:setScaled(state.w3)
  angVel:setAdd(tempVec1)
  angVel:setAdd(tempVec2)
  angVel:setScaled(invDenom)
  angAccel:setScaled2(curl, invDenom) -- The angular acceleration at the projected point.

  -- Compute the local triangle Frenet frame (triangle space).
  forwardTS:set(state.triangleSpaceForward) -- The 'forward' vector in triangle space.
  upTS:set(state.triangleSpaceUp) -- The 'up' vector in triangle space.
  rightTS:setCross(edge1Norm, normal) -- The 'right' vector in triangle space.
  rightTS:normalize()

  -- Transform the triangle space Frenet frame to world space, at the sensor current position.
  tempVec1:setScaled2(edge1Norm, forwardTS.x)
  tempVec2:setScaled2(normal, forwardTS.y)
  tempVec3:setScaled2(rightTS, forwardTS.z)
  forwardWS:setAdd2(tempVec1, tempVec2)
  forwardWS:setAdd(tempVec3)
  forwardWS:normalize() -- The 'forward' vector in world space.
  tempVec1:setScaled2(edge1Norm, upTS.x)
  tempVec2:setScaled2(normal, upTS.y)
  tempVec3:setScaled2(rightTS, upTS.z)
  upWS:setAdd2(tempVec1, tempVec2)
  upWS:setAdd(tempVec3)
  upWS:normalize() -- The 'up' vector in world space.
  rightWS:setCross(forwardWS, upWS)
  rightWS:normalize() -- The 'right' vector in world space.

  -- Transform the total acceleration vector to world space.
  accel:set(totalAccel:dot(forwardWS), totalAccel:dot(upWS), totalAccel:dot(rightWS))

  -- Compute the local mass using barycentric interpolation from the three node mass values.
  local interpMass = m1 * state.w1 + m2 * state.w2 + m3 * state.w3

  -- Smooth the acceleration/gyroscopic vectors using three cascading passes of a variable dt smoother.
  -- Smoothing Pass 1.
  local accel1X, accel1Y, accel1Z = sm.sm1AccX:get(accel.x, trueDt), sm.sm1AccY:get(accel.y, trueDt), sm.sm1AccZ:get(accel.z, trueDt)
  local gyro1X, gyro1Y, gyro1Z = sm.sm1GyroX:get(angVel.x, trueDt), sm.sm1GyroY:get(angVel.y, trueDt), sm.sm1GyroZ:get(angVel.z, trueDt)

  -- Smoothing Pass 2.
  local accel2X, accel2Y, accel2Z = sm.sm2AccX:get(accel1X, trueDt), sm.sm2AccY:get(accel1Y, trueDt), sm.sm2AccZ:get(accel1Z, trueDt)
  local gyro2X, gyro2Y, gyro2Z = sm.sm2GyroX:get(gyro1X, trueDt), sm.sm2GyroY:get(gyro1Y, trueDt), sm.sm2GyroZ:get(gyro1Z, trueDt)

  -- Set final smoothed readings.
  state.smoothedAccelReading:set(accel2X, accel2Y, accel2Z)
  state.smoothedGyroReading:set(gyro2X, gyro2Y, gyro2Z)

  -- Gather the latest reading data.
  tmpPosWS:setAdd2(currentPos, obj:getPosition()) -- Vehicle space -> World space.
  state.latestReading = {
    time = obj:getSimTime(),
    mass = interpMass,
    accRaw = accel:toTable(),
    accSmooth = state.smoothedAccelReading:toTable(),
    angVel = angVel:toTable(),
    angVelSmooth = state.smoothedGyroReading:toTable(),
    angAccel = angAccel:toTable(),
    pos = tmpPosWS:toTable(),
    dirX = forwardWS:toTable(),
    dirY = upWS:toTable(),
    dirZ = rightWS:toTable() }

  -- Store the latest readings for this advanced IMU sensor in the extension. This is used for sending back on the physics step.
  extensions.tech_advancedIMU.cacheLatestReading(state.sensorId, state.latestReading)

  -- Add the data to the readings array, for later retrieval. This is used for sending bulk data back on the graphics step.
  state.readings[#state.readings + 1] = state.latestReading
end


-- Public interface.
M.getSensorData =                                       getSensorData
M.getLatest =                                           getLatest
M.setIsUsingGravity =                                   setIsUsingGravity
M.setIsVisualised =                                     setIsVisualised
M.incrementTimer =                                      incrementTimer

M.init =                                                init
M.reset =                                               reset

M.update =                                              update

return M