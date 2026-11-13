-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local abs = math.abs
local aeroData = {}

local frontRightWheelPos = nil
local frontLeftWheelPos = nil
local rearLeftWheelPos = nil
local rearRightWheelPos = nil

local isEnabled = false

local function onInit()
  isEnabled = false
end

local function updateGFX(dt)
  if not isEnabled then
    return
  end
  --obj:setWind(0,55.55,0)
  --obj:setWind(0,0,55.55)
  -- Body axes as (right, fwd, up), right handed, matching the workbench aero panel.
  M.directionVector = obj:getDirectionVector()
  M.directionVectorUp = obj:getDirectionVectorUp()
  M.directionVectorRight = M.directionVector:cross(M.directionVectorUp)

  -- Everything is referenced to the centre of gravity. Under free rolling the drag
  -- is balanced by the car's own inertia, which acts through the CoG, so a moment
  -- taken there carries no dependence on the centre of pressure, the drag height or
  -- the axle heights.
  local cog = obj:calcCenterOfGravityRel(false)

  aeroData.vehID = obj:getID()
  aeroData.totalAeroForce = obj:calcTotalAeroForces()
  -- calcTotalAeroTorque returns the negative of the usual sum (r - P) x F moment:
  -- sampling it about two points a metre apart shifts it by +(offset x F) where the
  -- textbook convention gives -(offset x F). Flip it for the physical moment.
  aeroData.totalAeroTorque = -obj:calcTotalAeroTorque(cog)
  aeroData.test = 100

  local force = aeroData.totalAeroForce
  local moment = aeroData.totalAeroTorque

  --obj.debugDrawProxy:drawSphere(0.05, cog + obj:getPosition(), color(255,0,255,255))
  aeroData.totalAeroForceVehicle = vec3(force:dot(M.directionVectorRight), force:dot(M.directionVector), force:dot(M.directionVectorUp))
  aeroData.afX = aeroData.totalAeroForceVehicle.x
  aeroData.afY = aeroData.totalAeroForceVehicle.y
  aeroData.afZ = aeroData.totalAeroForceVehicle.z
  --print(M.afX..' '..M.afY..' '..M.afZ)

  -- (pitch, roll, yaw): pitch positive is nose up, roll positive leans the car to
  -- the right, yaw positive turns the nose to the left.
  aeroData.totalAeroTorqueVehicle = vec3(moment:dot(M.directionVectorRight), moment:dot(M.directionVector), moment:dot(M.directionVectorUp))
  aeroData.aTX = aeroData.totalAeroTorqueVehicle.x
  aeroData.aTY = aeroData.totalAeroTorqueVehicle.y
  aeroData.aTZ = aeroData.totalAeroTorqueVehicle.z
  --print(M.aTX..' '..M.aTY..' '..M.aTZ)

  for _, wd in pairs(wheels.wheels) do
    -- Offsets from the vehicle origin, the same space calcCenterOfGravityRel uses.
    local middlePos = (obj:getNodePosition(wd.node1) + obj:getNodePosition(wd.node2)) * 0.5

    if wd.name == aeroData.wheelNameFR then
      frontRightWheelPos = middlePos
    end
    if wd.name == aeroData.wheelNameFL then
      frontLeftWheelPos = middlePos
    end
    if wd.name == aeroData.wheelNameRR then
      rearLeftWheelPos = middlePos
    end
    if wd.name == aeroData.wheelNameRL then
      rearRightWheelPos = middlePos
    end
  end

  aeroData.rearDownForce = 0
  aeroData.frontDownForce = 0
  aeroData.percentFront = 0
  aeroData.percentRear = 0

  if frontRightWheelPos and frontLeftWheelPos and rearLeftWheelPos and rearRightWheelPos then
    local frontAxlePos = (frontRightWheelPos + frontLeftWheelPos) * 0.5
    local rearAxlePos = (rearRightWheelPos + rearLeftWheelPos) * 0.5

    --obj.debugDrawProxy:drawSphere(0.02, rearAxlePos, color(255,0,0,255))
    --obj.debugDrawProxy:drawSphere(0.02, frontAxlePos, color(255,0,0,255))

    -- Vertical reaction the ground has to supply at each axle, assuming free
    -- rolling: no horizontal tyre force, so only the longitudinal distance from the
    -- CoG to each axle matters and the heights drop out. Positive is downforce.
    local a = (frontAxlePos - cog):dot(M.directionVector)
    local b = -(rearAxlePos - cog):dot(M.directionVector)
    local wheelbase = a + b

    if wheelbase > 1e-6 then
      local down = -force:dot(M.directionVectorUp)
      local pitch = aeroData.totalAeroTorqueVehicle.x
      aeroData.frontDownForce = (down * b - pitch) / wheelbase
      aeroData.rearDownForce = (down * a + pitch) / wheelbase

      -- Below about a newton the split is only noise, so don't dress it up as a
      -- percentage.
      local total = abs(aeroData.frontDownForce) + abs(aeroData.rearDownForce)
      if total > 1 then
        aeroData.percentFront = aeroData.frontDownForce / total * 100
        aeroData.percentRear = aeroData.rearDownForce / total * 100
      end
    end

  --print(aeroData.frontDownForce..' '..aeroData.rearDownForce..' '..aeroData.afX..' '..aeroData.afY..' '..aeroData.afZ)
  --print("%F:"..' '..string.format("%.2f",aeroData.percentFront)..' '.."%R:"..' '..string.format("%.2f",aeroData.percentRear)..' '.."Net Force X:"..' '..string.format("%.2f",aeroData.afX)..' '.."Y:"..''..string.format("%.2f",aeroData.afY)..' '.."Z:"..''..string.format("%.2f",aeroData.afZ))
  end
end

local function getAeroData()
  return aeroData
end

local function setWheelNames(FL, FR, RL, RR)
  aeroData.wheelNameFL = FL
  aeroData.wheelNameFR = FR
  aeroData.wheelNameRL = RL
  aeroData.wheelNameRR = RR
end

local function enable()
  if not aeroData.wheelNameStrings then
    aeroData.wheelNameStrings = {}
    for _, wd in pairs(wheels.wheels) do
      table.insert(aeroData.wheelNameStrings, wd.name)
    end
  end
  isEnabled = true
end

local function disable()
  isEnabled = false
  aeroData.wheelNameStrings = nil
end

-- public interface
M.onInit = onInit
M.updateGFX = updateGFX
M.getAeroData = getAeroData
M.setWheelNames = setWheelNames

M.enable = enable
M.disable = disable

return M
