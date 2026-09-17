-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local min = math.min
local max = math.max

local targetPosOffset = nil
local baseTargetPos = nil

local steeringPID

local function updateGFX(dt)
  if baseTargetPos then
    local myPos = obj:getPosition()
    local targetPos = baseTargetPos + vec3((myPos.x - 20) * targetPosOffset.x, (myPos.y - 20) * targetPosOffset.y, (myPos.z - 20) * targetPosOffset.z)
    local distanceVector = targetPos - myPos
    local directionVector = obj:getDirectionVector()
    local angleError = (distanceVector:dot(directionVector) / (directionVector:length() * distanceVector:length()))
    local vectorLeft = obj:getDirectionVectorUp():cross(directionVector)
    local angleSign = distanceVector:dot(vectorLeft)

    angleError = min(max((angleError - sign(angleError)), -1), 1) * sign(angleSign)
    angleError = sign(angleError) * math.sqrt(math.abs(angleError))

    local steering = -steeringPID:get(angleError, 0, dt)
    input.event("steering", steering, 1)
  end
end

local function setTargetDirection(target, mode)
  if not target then
    local direction = obj:getDirectionVector():z0()
    local pos = obj:getPosition()
    baseTargetPos = pos + direction * 20
  else
    baseTargetPos = target
  end
  targetPosOffset = vec3(0, 1, 0)
  print("Targetpos: " .. dumps(baseTargetPos))
  print("Using steering mode: " .. mode)

  if mode == "offroad" then
    steeringPID = newPIDStandard(0.8, 0.5, 0.0, -1, 1)
  else
    steeringPID = newPIDStandard(0.4, 0.0, 0.0, -1, 1)
  end
  --steeringPID:setDebug(true)
end

local function stop()
  input.event("steering", 0, 0)
  targetPosOffset = nil
  baseTargetPos = nil
end

local function onInit()
  targetPosOffset = nil
  baseTargetPos = nil
end

-- public interface
M.onInit = onInit
M.onReset = onInit
M.updateGFX = updateGFX
M.setTargetDirection = setTargetDirection
M.stop = stop

return M
