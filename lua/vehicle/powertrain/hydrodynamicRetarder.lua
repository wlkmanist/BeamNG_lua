-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.outputPorts = {}
M.deviceCategories = {retarder = true, torqueConsumer = true}

local abs = math.abs
local floor = math.floor
local max = math.max
local clamp = clamp

local avToRPM = 9.549296596425384

local function setRetarderCoef(device, coef)
  device.desiredRetarderCoef = clamp(coef or 0, 0, 1)
end

local function updateSounds(device, dt)
  local smootherInputAV = device.retarderWhineAVSmoother:get(abs(device.inputAV), dt)
  local volume = linearScale(smootherInputAV, 0, 5, 0, 1)

  local pitch = smootherInputAV * avToRPM
  local colour = device.desiredRetarderCoef

  obj:setVolumePitchCT(device.retarderWhineLoop, volume, pitch, colour, 0)
end

local function updateVelocity(device, dt)
  device.inputAV = device.outputAV1 * device.gearRatio
  device.parent[device.parentOutputAVName] = device.inputAV
end

local function updateTorqueBroken(device, dt)
  local inputFrictionTorque = (device.friction * clamp(device.inputAV, -1, 1) + device.dynamicFriction * device.inputAV) * device.wearFrictionCoef * device.damageFrictionCoef
  local availableRotorTorque = (device.parent[device.parentOutputTorqueName] - inputFrictionTorque) * device.gearRatio
  device.outputAV1 = device.outputAV1 + availableRotorTorque * device.invVirtualInertia * dt
end

local function updateTorque(device, dt)
  local inputFrictionTorque = (device.friction * clamp(device.inputAV, -1, 1) + device.dynamicFriction * device.inputAV) * device.wearFrictionCoef * device.damageFrictionCoef
  local availableRotorTorque = (device.parent[device.parentOutputTorqueName] - inputFrictionTorque) * device.gearRatio
  local rotorAV = device.outputAV1
  local rotorRPM = floor(abs(rotorAV) * avToRPM)
  local fullBrakeTorque = device.brakeTorqueCurve[rotorRPM] or 0
  local smoothedRetarderCoef = device.retarderCoefSmoother:get(device.desiredRetarderCoef)
  local retarderTorque = rotorAV == 0 and 0 or -sign(rotorAV) * fullBrakeTorque * smoothedRetarderCoef
  local netRotorTorque = availableRotorTorque + retarderTorque

  device.outputAV1 = rotorAV + netRotorTorque * device.invVirtualInertia * dt

  local dissipatedPower = max(0, -retarderTorque * rotorAV)
  if dissipatedPower <= 0 or device.coolantEnergyCoef <= 0 then
    return
  end

  device.parentEngine = device.parentEngine or powertrain.getPropulsionDeviceForDevice(device)
  local thermals = device.parentEngine and device.parentEngine.thermals
  if thermals and type(thermals.additionalCoolantEnergyPerStep) == "number" then
    thermals.additionalCoolantEnergyPerStep = thermals.additionalCoolantEnergyPerStep + dissipatedPower * dt * device.coolantEnergyCoef
  end
end

local function updateGFX(device, dt)
end

local function selectUpdates(device)
  device.velocityUpdate = updateVelocity
  device.torqueUpdate = (device.isBroken or device.brakeTorqueCurve == nil) and updateTorqueBroken or updateTorque
  device.updateGFX = updateGFX
end

local function applyDeformGroupDamage(device, damageAmount)
  device.damageFrictionCoef = device.damageFrictionCoef + linearScale(damageAmount, 0, 0.01, 0, 0.1)
end

local function setPartCondition(device, subSystem, odometer, integrity, visual)
  device.wearFrictionCoef = linearScale(odometer, 30000000, 1000000000, 1, 2)
  local integrityState = integrity
  if type(integrity) == "number" then
    local integrityValue = integrity
    integrityState = {damageFrictionCoef = linearScale(integrityValue, 1, 0, 1, 50), isBroken = false}
  end

  device.damageFrictionCoef = integrityState.damageFrictionCoef or 1

  if integrityState.isBroken then
    device:onBreak()
  end
end

local function getPartCondition(device)
  local integrityState = {damageFrictionCoef = device.damageFrictionCoef, isBroken = device.isBroken}
  local integrityValue = linearScale(device.damageFrictionCoef, 1, 50, 1, 0)
  if device.isBroken then
    integrityValue = 0
  end
  return integrityValue, integrityState
end

local function validate(device)
  return device.brakeTorqueCurve ~= nil
end

local function onBreak(device)
  device.isBroken = true
  selectUpdates(device)
end

local function calculateInertia(device)
  local gearRatio = abs(device.gearRatio)

  device.cumulativeInertia = device.virtualInertia / gearRatio / gearRatio
  device.invCumulativeInertia = 1 / device.cumulativeInertia
  device.invVirtualInertia = 1 / device.virtualInertia
  device.cumulativeGearRatio = device.gearRatio
  device.maxCumulativeGearRatio = gearRatio
end

local function resetSounds(device)
  device.retarderWhineAVSmoother:reset()
end

local function initSounds(device, jbeamData)
  local retarderWhineSample = jbeamData.retarderWhineEvent or "event:>Vehicle>Retarder>retarder_01"
  device.retarderWhineLoop = obj:createSFXSource(retarderWhineSample, "AudioDefaultLoop3D", "RetarderWhine", device.transmissionNodeID or sounds.engineNode, 0)

  bdebug.setNodeDebugText("Powertrain", device.transmissionNodeID or sounds.engineNode, device.name .. ": " .. retarderWhineSample)

  local inputAVSmoothing = jbeamData.retarderWhinePitchCoefSmoothing or 100
  device.retarderWhineAVSmoother = newLinearSmoothing(inputAVSmoothing, inputAVSmoothing)
end

local function reset(device, jbeamData)
  device.friction = jbeamData.friction or 0
  device.dynamicFriction = jbeamData.dynamicFriction or 0

  device.outputAV1 = 0
  device.inputAV = 0
  device.outputTorque1 = 0

  device.isBroken = false
  device.desiredRetarderCoef = 0
  device.retarderCoefSmoother:reset()

  device.wearFrictionCoef = 1
  device.damageFrictionCoef = 1

  selectUpdates(device)
end

local function new(jbeamData)
  local device = {
    deviceCategories = shallowcopy(M.deviceCategories),
    requiredExternalInertiaOutputs = shallowcopy(M.requiredExternalInertiaOutputs),
    outputPorts = shallowcopy(M.outputPorts),
    name = jbeamData.name,
    type = jbeamData.type,
    inputName = jbeamData.inputName,
    inputIndex = jbeamData.inputIndex,
    friction = jbeamData.friction or 0,
    dynamicFriction = jbeamData.dynamicFriction or 0,
    wearFrictionCoef = 1,
    damageFrictionCoef = 1,
    desiredRetarderCoef = 0,
    cumulativeInertia = 1,
    invCumulativeInertia = 1,
    cumulativeGearRatio = 1,
    maxCumulativeGearRatio = 1,
    isPhysicallyDisconnected = true,
    outputAV1 = 0,
    inputAV = 0,
    outputTorque1 = 0,
    isBroken = false,
    retarderCoefSmoother = newExponentialSmoothing(jbeamData.strengthSmoothing or 10),
    reset = reset,
    onBreak = onBreak,
    validate = validate,
    calculateInertia = calculateInertia,
    applyDeformGroupDamage = applyDeformGroupDamage,
    setPartCondition = setPartCondition,
    getPartCondition = getPartCondition,
    initSounds = initSounds,
    resetSounds = resetSounds,
    updateSounds = updateSounds,
    setRetarderCoef = setRetarderCoef
  }

  device.gearRatio = jbeamData.gearRatio or 1
  device.virtualInertia = jbeamData.virtualInertia or 0.1
  device.invVirtualInertia = 1 / device.virtualInertia

  local torqueDropOffRange = max(floor(jbeamData.torqueDropOffRange or 500), 10)
  device.torqueDropOffRange = torqueDropOffRange
  device.brakeTorqueCurve = nil
  local hasValidBrakeTorqueCurve = true

  local brakeTorqueTable
  if type(jbeamData.brakeTorque) ~= "table" then
    log("E", "hydrodynamicRetarder2.new", string.format("Device %q is missing the required brakeTorque table", device.name))
    hasValidBrakeTorqueCurve = false
  else
    brakeTorqueTable = tableFromHeaderTable(jbeamData.brakeTorque)
    if type(brakeTorqueTable) ~= "table" then
      log("E", "hydrodynamicRetarder2.new", string.format("Device %q has a malformed brakeTorque table", device.name))
      hasValidBrakeTorqueCurve = false
    end
  end

  local points = {}
  if hasValidBrakeTorqueCurve then
    for rowIndex, row in ipairs(brakeTorqueTable) do
      local rpm = row.rpm
      local torque = row.torque
      if rpm == nil then
        log("E", "hydrodynamicRetarder2.new", string.format("Device %q brakeTorque row %d has an invalid rpm", device.name, rowIndex))
        hasValidBrakeTorqueCurve = false
        break
      end
      if torque == nil then
        log("E", "hydrodynamicRetarder2.new", string.format("Device %q brakeTorque row %d has an invalid torque", device.name, rowIndex))
        hasValidBrakeTorqueCurve = false
        break
      end
      points[rowIndex] = {rpm, torque}
    end
  end

  if hasValidBrakeTorqueCurve and #points < 2 then
    log("E", "hydrodynamicRetarder2.new", string.format("Device %q brakeTorque requires at least two data rows", device.name))
    hasValidBrakeTorqueCurve = false
  end

  if hasValidBrakeTorqueCurve then
    table.sort(
      points,
      function(a, b)
        return a[1] < b[1]
      end
    )

    for pointIndex = 2, #points do
      if points[pointIndex][1] == points[pointIndex - 1][1] then
        log("E", "hydrodynamicRetarder2.new", string.format("Device %q brakeTorque contains duplicate rpm %d", device.name, points[pointIndex][1]))
        hasValidBrakeTorqueCurve = false
        break
      end
    end
  end

  if hasValidBrakeTorqueCurve then
    device.brakeTorqueCurve = createCurve(points)
    local lastPoint = points[#points]
    local lastRPM = lastPoint[1]
    local lastTorque = lastPoint[2]

    for rpm = points[1][1], lastRPM do
      device.brakeTorqueCurve[rpm] = max(device.brakeTorqueCurve[rpm] or 0, 0)
    end

    for rpmOffset = 1, torqueDropOffRange do
      device.brakeTorqueCurve[lastRPM + rpmOffset] = lastTorque * (1 - rpmOffset / torqueDropOffRange)
    end
  end

  local coolantEnergyCoef = jbeamData.coolantEnergyCoef
  device.coolantEnergyCoef = clamp(coolantEnergyCoef or 1, 0, 1)

  device.breakTriggerBeam = jbeamData.breakTriggerBeam
  if device.breakTriggerBeam and device.breakTriggerBeam == "" then
    device.breakTriggerBeam = nil
  end

  selectUpdates(device)

  return device
end

M.new = new

return M
