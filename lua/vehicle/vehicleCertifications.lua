-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

local max = math.max

local function getTorquePower()
  local engines = powertrain.getDevicesByCategory("engine")
  if not engines or #engines <= 0 then
    log("I", "vehicleCertifications", "Can't find any engine, not getting static performance data")
    return 0, 0
  end

  local maxRPM = 0
  local maxTorque = -1
  local maxPower = -1
  if #engines > 1 then
    local torqueData = {}
    for _, v in pairs(engines) do
      local tData = v:getTorqueData()
      maxRPM = max(maxRPM, tData.maxRPM)
      table.insert(torqueData, tData)
    end

    local torqueCurve = {}
    local powerCurve = {}
    for _, td in ipairs(torqueData) do
      local engineCurves = td.curves[td.finalCurveName]
      for rpm, torque in pairs(engineCurves.torque) do
        torqueCurve[rpm] = (torqueCurve[rpm] or 0) + torque
      end
      for rpm, power in pairs(engineCurves.power) do
        powerCurve[rpm] = (powerCurve[rpm] or 0) + power
      end
    end
    for _, torque in pairs(torqueCurve) do
      maxTorque = max(maxTorque, torque)
    end
    for _, power in pairs(powerCurve) do
      maxPower = max(maxPower, power)
    end
  else
    local torqueData = engines[1]:getTorqueData()
    maxRPM = torqueData.maxRPM
    maxTorque = torqueData.maxTorque
    maxPower = torqueData.maxPower
  end

  return maxTorque, maxPower, maxRPM
end

local function getWeight()
  local stats = obj:calcBeamStats()
  return stats.total_weight
end

local function getAeroLegality()
  return true
end

local function getPowertrainLayout()
  local propulsedWheelsCount = 0
  local wheelCount = 0

  local avgWheelPos = vec3(0, 0, 0)
  for _, wd in pairs(wheels.wheels) do
    wheelCount = wheelCount + 1
    local wheelNodePos = v.data.nodes[wd.node1].pos --find the wheel position
    avgWheelPos = avgWheelPos + wheelNodePos --sum up all positions
    if wd.isPropulsed then
      propulsedWheelsCount = propulsedWheelsCount + 1
    end
  end

  avgWheelPos = avgWheelPos / wheelCount --make the average of all positions

  local vectorForward = vec3(v.data.nodes[v.data.refNodes[0].ref].pos) - vec3(v.data.nodes[v.data.refNodes[0].back].pos) --vector facing forward
  local vectorUp = vec3(v.data.nodes[v.data.refNodes[0].up].pos) - vec3(v.data.nodes[v.data.refNodes[0].ref].pos)
  local vectorRight = vectorForward:cross(vectorUp) --vector facing to the right

  local propulsedWheelLocations = {fr = 0, fl = 0, rr = 0, rl = 0}
  for _, wd in pairs(wheels.wheels) do
    if wd.isPropulsed then
      local wheelNodePos = vec3(v.data.nodes[wd.node1].pos) --find the wheel position
      local wheelVector = wheelNodePos - avgWheelPos --create a vector from our "center" to the wheel
      local dotForward = vectorForward:dot(wheelVector) --calculate dot product of said vector and forward vector
      local dotLeft = vectorRight:dot(wheelVector) --calculate dot product of said vector and left vector

      if dotForward >= 0 then
        if dotLeft >= 0 then
          propulsedWheelLocations.fr = propulsedWheelLocations.fr + 1
        else
          propulsedWheelLocations.fl = propulsedWheelLocations.fl + 1
        end
      else
        if dotLeft >= 0 then
          propulsedWheelLocations.rr = propulsedWheelLocations.rr + 1
        else
          propulsedWheelLocations.rl = propulsedWheelLocations.rl + 1
        end
      end
    end
  end

  local layout = {}
  layout.poweredWheelsFront = propulsedWheelLocations.fl + propulsedWheelLocations.fr
  layout.poweredWheelsRear = propulsedWheelLocations.rl + propulsedWheelLocations.rr

  return layout
end

local function getTransmissionStyle()
  local transmissionTypes = {}
  local transmissions = powertrain.getDevicesByCategory("gearbox")
  for _, v in pairs(transmissions) do
    transmissionTypes[v.type] = true
  end

  return transmissionTypes
end

local function getPropulsionType()
end

local function getFuelTypes()
  local energyStorages = energyStorage.getStorages()
  local fuelTypes = {}
  for _, v in pairs(energyStorages) do
    if v.type == "fuelTank" then
      fuelTypes[v.type .. ":" .. v.energyType] = true
    elseif v.type == "electricBattery" then
      fuelTypes[v.type] = true
    elseif v.type ~= "n2oTank" then
      fuelTypes[v.type] = true
    end
  end

  return fuelTypes
end

local function getInductionTypes()
  local engines = powertrain.getDevicesByType("combustionEngine")
  local inductionTypes = {}
  for _, v in pairs(engines) do
    inductionTypes.naturalAspiration = true
    if v.turbocharger.isExisting then
      inductionTypes.turbocharger = true
    end
    if v.supercharger.isExisting then
      inductionTypes.supercharger = true
    end
    if v.nitrousOxideInjection.isExisting then
      inductionTypes.N2O = true
    end
  end

  return inductionTypes
end

local function getCertifications()
  local torque, power, maxRPM = getTorquePower()
  local certifications = {
    power = power,
    torque = torque,
    maxRPM = maxRPM,
    weight = getWeight(),
    powertrainLayout = getPowertrainLayout(),
    transmissionStyle = getTransmissionStyle(),
    propulsionType = getPropulsionType(),
    fuelTypes = getFuelTypes(),
    inductionTypes = getInductionTypes(),
    isAeroLegal = getAeroLegality()
  }

  return certifications
end

local function reset()
end

local function init()
end

M.init = init
M.reset = reset

M.getCertifications = getCertifications

return M
