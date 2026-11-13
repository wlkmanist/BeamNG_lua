-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--Purpose: Animates rotating parts such as pulleys from measured linear travel

local M = {}
M.type = "auxiliary"

local sensorBeamId

local startingSensorBeamLength
local effectiveRadius
local angularOutputElectricsName
local angularOutputElectricsMultiplier
local invTwoPi = 1 / (2 * math.pi)

local isActiveCoef

--we measure the overall length via the sensor beam and then distribute it evenly across the segment beams
local function updateGFX(dt)
  --read sensor beam length and calculate movement based on starting length
  local sensorBeamLength = obj:getBeamLength(sensorBeamId)
  local sensorBeamMovement = sensorBeamLength - startingSensorBeamLength

  -- arc length = angle * radius -> angle = arc length / radius
  local rotation = ((sensorBeamMovement / effectiveRadius) * invTwoPi) % 1 --normalize rad to fractional rotations
  electrics.values[angularOutputElectricsName] = rotation * angularOutputElectricsMultiplier --convert rotation fractional to whatever scale we need
end

local function beamBroken(id, energy)
  --if one of the beams breaks, the system cannot work anymore and we need to stop doing anything
  if isActiveCoef > 0 and id == sensorBeamId then
    isActiveCoef = 0
  end
end

local function reset(jbeamData)
  isActiveCoef = 1
  startingSensorBeamLength = obj:getBeamLength(sensorBeamId)
  if angularOutputElectricsName then
    electrics.values[angularOutputElectricsName] = 0
  end
end

local function init(jbeamData)
  sensorBeamId = nil

  local sensorBeamTag = jbeamData.sensorBeamTag

  local sensorBeams = beamstate.tagBeamMap[sensorBeamTag] or {}

  sensorBeamId = sensorBeams[1]
  effectiveRadius = jbeamData.effectiveRadius
  angularOutputElectricsName = jbeamData.angularOutputElectricsName
  angularOutputElectricsMultiplier = jbeamData.angularOutputElectricsMultiplier or 360

  if not sensorBeamId then
    log("E", "beamSegments.init", M.name .. ": sensorBeamTag '" .. sensorBeamTag .. "' has no matching sensor beam")
    log("E", "beamSegments.init", M.name .. ": beamSegments system will not work correctly")
    return
  end

  startingSensorBeamLength = obj:getBeamLength(sensorBeamId)
  if effectiveRadius and angularOutputElectricsName and effectiveRadius > 0 then
    electrics.values[angularOutputElectricsName] = 0
  else
    log("W", "beamSegments.init", M.name .. ": pulleyRadius is <= 0, pulley rotation output disabled")
  end

  if not effectiveRadius or effectiveRadius == 0 then
    log("E", "linearToAngularTransform.init", M.name .. ": effectiveRadius is nil or 0, linearToAngularTransform system will not work correctly")
    return
  end

  if not angularOutputElectricsName then
    log("E", "linearToAngularTransform.init", M.name .. ": angularOutputElectricsName is nil, linearToAngularTransform system will not work correctly")
    return
  end

  isActiveCoef = 1

  M.updateGFX = updateGFX
end

M.init = init
M.reset = reset

M.updateGFX = nil

M.beamBroken = beamBroken

return M
