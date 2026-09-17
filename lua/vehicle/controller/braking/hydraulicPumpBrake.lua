-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--Purpose: Used to simulate a brake system that is fed by a hydraulic pump rather than a master cylinder

local M = {}
M.type = "auxiliary"
M.defaultOrder = 50

local clamp = clamp

local relevantEngine
local engineRunningThresholdAV
local engineRunningSmoother

local hillAssistCoef = 0
local frontLockOutEnabled = false

local frontDamageBeamIds
local frontDamageBeamBrokenCoef
local rearDamageBeamIds
local rearDamageBeamBrokenCoef

local didAutoApplyParkingBrake = false

local function updateGFX(dt)
  --the engine technically runs the hydraulic pump for the brakes, so no spinning engine means no brake pressure
  --with no engine at all, we also have no brake pressure
  local engineRunning = relevantEngine and relevantEngine.outputAV1 > engineRunningThresholdAV
  --slightly smooth it to emulate pressure behavior of the pump
  local engineRunningCoef = engineRunningSmoother:get(engineRunning and 1 or 0, dt)
  local throttleInput = electrics.values.throttle
  local brakeInput = electrics.values.brake

  local brakeF = brakeInput
  local brakeR = brakeInput

  local throttleAdjustedHillAssistCoef = throttleInput <= 0 and hillAssistCoef or 0
  --brake pedal and hill assist are additive, but do not exceed normal brake torque if combined
  brakeR = clamp(brakeR + linearScale(throttleAdjustedHillAssistCoef, 0, 1, 0, 0.8), 0, 1)

  local frontDisableCoef = frontLockOutEnabled and 0 or 1

  brakeF = brakeF * engineRunningCoef * frontDisableCoef * frontDamageBeamBrokenCoef --disable front if lockout is enabled or beam is broken
  brakeR = brakeR * engineRunningCoef * rearDamageBeamBrokenCoef --disable rear if beam is broken

  --if main rear brake is not working (engine off or beam broken), auto apply parking brake
  if not engineRunning or rearDamageBeamBrokenCoef < 1 then
    didAutoApplyParkingBrake = true
    if controller.mainController.smartParkingBrake then
      controller.mainController.smartParkingBrake(1, FILTER_DIRECT, true)
    else
      input.event("parkingbrake", 1, FILTER_KBD)
    end
  elseif didAutoApplyParkingBrake and (engineRunning or rearDamageBeamBrokenCoef >= 1) then
    didAutoApplyParkingBrake = false
    if controller.mainController.smartParkingBrake then
      controller.mainController.smartParkingBrake(0, FILTER_DIRECT, false)
    end
  end

  electrics.values.brakeF = brakeF
  electrics.values.brakeR = brakeR

  --electrics values for props
  electrics.values.frontBrakeLockOut = frontLockOutEnabled and 1 or 0
  electrics.values.hillAssist = hillAssistCoef
end

local function beamBroken(id, energy)
  if frontDamageBeamBrokenCoef > 0 then
    for i = 1, #frontDamageBeamIds do
      if id == frontDamageBeamIds[i] then
        frontDamageBeamBrokenCoef = 0
        break
      end
    end
  end
  if rearDamageBeamBrokenCoef > 0 then
    for i = 1, #rearDamageBeamIds do
      if id == rearDamageBeamIds[i] then
        rearDamageBeamBrokenCoef = 0
        break
      end
    end
  end
end

local function setHillAssistCoef(coef)
  hillAssistCoef = clamp(coef, 0, 1)
  if hillAssistCoef <= 0.01 then
    hillAssistCoef = 0
  end
  guihooks.message(
    {
      txt = "vehicle.hydraulicPumpBrake.hillAssist",
      context = {coef = (roundNear(hillAssistCoef, 0.01) * 100) .. "%"}
    },
    2,
    "vehicle.hydraulicPumpBrake.hillAssist"
  )
end

local function changeHillAssistCoef(change)
  setHillAssistCoef(hillAssistCoef + change)
end

local function setFrontLockOutEnabled(enabled)
  frontLockOutEnabled = enabled
  guihooks.message(
    {
      txt = "vehicle.hydraulicPumpBrake.frontBrakeLockOut",
      context = {enabled = enabled}
    },
    2,
    "vehicle.hydraulicPumpBrake.frontBrakeLockOut"
  )
end

local function toggleFrontLockOutEnabled()
  setFrontLockOutEnabled(not frontLockOutEnabled)
end

local function reset(jbeamData)
  engineRunningSmoother:reset()
  frontDamageBeamBrokenCoef = 1
  rearDamageBeamBrokenCoef = 1
  didAutoApplyParkingBrake = false
end

local function init(jbeamData)
  local relevantEngineName = jbeamData.relevantEngineName or "mainEngine"
  relevantEngine = powertrain.getDevice(relevantEngineName)
  engineRunningThresholdAV = 10
  engineRunningSmoother = newTemporalSmoothing(1, 2)
  frontDamageBeamBrokenCoef = 1
  rearDamageBeamBrokenCoef = 1
  didAutoApplyParkingBrake = false

  local frontDamageBeamTag = jbeamData.frontDamageBeamTag
  frontDamageBeamIds = beamstate.tagBeamMap[frontDamageBeamTag] or {}
  local rearDamageBeamTag = jbeamData.rearDamageBeamTag
  rearDamageBeamIds = beamstate.tagBeamMap[rearDamageBeamTag] or {}
end

M.init = init
M.reset = reset

M.updateGFX = updateGFX

M.setHillAssistCoef = setHillAssistCoef
M.changeHillAssistCoef = changeHillAssistCoef
M.setFrontLockOutEnabled = setFrontLockOutEnabled
M.toggleFrontLockOutEnabled = toggleFrontLockOutEnabled

M.beamBroken = beamBroken

return M
