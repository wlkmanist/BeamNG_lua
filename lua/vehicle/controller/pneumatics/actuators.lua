-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.type = "auxiliary"
M.defaultOrder = 50

local abs = math.abs
local max = math.max
local min = math.min
local sqrt = math.sqrt
local clamp = clamp
local round = round

local psiToPascal = 6894.757293178
local pascalToPSI = 1 / psiToPascal
local flowRateCoefMap = {}

-- dependent on shape of flow orifice - closer to 1.0 for rounded orifices, decreases with sharpness of edges
-- we use a constant value of 0.97, which is a decent approximation of a round hole (e.g. a tube connection) without being unrealistically close to 1.0
local dischargeCoefficient = 0.97

local airTank = nil
local beamGroups = nil
local enableCrossFlow = false
local averagePressure = 0
local totalBeamCount = 0
local enableDebug = false

-- TODO: Compare internal calculated pressure with actual internal beam pressure (should match)

local function lookupFlowRate(flowRateCoef)
  local key = round(flowRateCoef * 100)
  return flowRateCoefMap[key] or (flowRateCoef < 0.5 and 0 or 1)
end

local function setBeamPressureCore(cid, pressure, maxPressure, spring, damp)
  obj:setBeamPressureRel(cid, max(0, pressure - powertrain.currentEnvPressure), max(0, maxPressure - powertrain.currentEnvPressure), spring, damp)
end

local function setBeamGroupValveState(groupName, valveState)
  local groupData = beamGroups[groupName]
  if not groupData then
    log("W", "actuators.setBeamGroupValveState", "Can't find pressure beam group: " .. groupName)
  else
    groupData.valveState = clamp(valveState, -1, 1)
  end
end

local function setBeamGroupsValveState(groupNames, valveState)
  for _, g in pairs(groupNames) do
    setBeamGroupValveState(g, valveState)
  end
end

local function toggleBeamGroupValveState(groupName)
  local groupData = beamGroups[groupName]
  if not groupData then
    log("W", "actuators.toggleBeamGroupValveState", "Can't find pressure beam group: " .. groupName)
  else
    local currentValveState = groupData.valveState or 0
    local valveState = currentValveState < 0 and 1 or -1
    groupData.valveState = valveState
  end
end

local function toggleBeamGroupsValveState(groupNames)
  for _, g in pairs(groupNames) do
    toggleBeamGroupValveState(g)
  end
end

local function getValveState(groupName)
  local groupData = beamGroups[groupName]
  if not groupData then
    log("W", "actuators.getValveState", "Can't find pressure beam group: " .. groupName)
    return 0
  end
  return groupData.valveState
end

local function getAverageFlowRate(groupName)
  local groupData = beamGroups[groupName]
  if not groupData then
    log("W", "actuators.getAverageFlowRate", "Can't find pressure beam group: " .. groupName)
    return 0
  end
  return groupData.averageFlowRate
end

local function getBeamGroupsAverageFlowRate(groupNames)
  local sum = 0
  local count = 0
  for _, name in ipairs(groupNames) do
    sum = sum + getAverageFlowRate(name)
    count = count + 1
  end
  return count > 0 and (sum / count) or 0
end

local function updateFixedStep(dt)
  local tankPressure = airTank.currentPressure
  local airDensity = airTank.remainingMass * airTank.invCapacity
  local invAirDensity = 1 / airDensity
  local pressureSum = 0
  local overallEnergyDelta = 0

  for _, g in pairs(beamGroups) do
    local desiredFlowCoef = abs(g.valveState)
    local flowRateSum = 0
    g.averagePressure = 0

    for _, v in pairs(g.beams) do
      local beamLength = obj:getBeamLength(v.cid)
      local beamVolume = v.surface * beamLength + 1e-30
      local invBeamVolume = 1 / beamVolume

      local sourcePressure, flowPressureDiff
      local airVolumeMoved, airEnergyMoved
      local prevEnergy, energyTransferred
      local flowRate = 0

      if enableCrossFlow then
        -- Flow simulation between actuators: flow is calculated using the difference between each actuator's pressure and the average pressure
        sourcePressure = averagePressure
        flowPressureDiff = sourcePressure - v.currentPressure
        flowRate = dischargeCoefficient * v.supplyHoseCrossSectionArea * sign(flowPressureDiff) * lookupFlowRate(2 * abs(flowPressureDiff) * invAirDensity)

        -- Determine volume of air and resulting energy transfer based on flow rate
        airVolumeMoved = flowRate * dt
        airEnergyMoved = sourcePressure * airVolumeMoved
        prevEnergy = v.storedEnergy

        -- Compute new pressure and energy delta
        v.storedEnergy = max(0, v.storedEnergy + airEnergyMoved)
        v.currentPressure = v.storedEnergy * invBeamVolume -- PV = e, therefore P = e / V
        energyTransferred = v.storedEnergy - prevEnergy
        overallEnergyDelta = overallEnergyDelta + energyTransferred
      end

      -- Flow simulation for individual actuator (between actuator and environment/supply)

      if g.valveState > 0 then
        -- airflow occurring between actuator and air tank
        sourcePressure = min(tankPressure, v.maxSupplyPressure)
        flowPressureDiff = sourcePressure - v.currentPressure
        flowRate = dischargeCoefficient * desiredFlowCoef * v.supplyHoseCrossSectionArea * sign(flowPressureDiff) * lookupFlowRate(abs(flowPressureDiff) / sourcePressure)
      else
        -- airflow occurring between actuator and environment
        sourcePressure = powertrain.currentEnvPressure
        flowPressureDiff = sourcePressure - v.currentPressure

        -- if the absolute actuator pressure is more than twice the env pressure,
        -- flow rate is limited by the speed of sound, so we clamp the maximum to the constant quickReleaseFlowRate.
        local relativeCurrentPressure = v.currentPressure - powertrain.currentEnvPressure
        local flowRateCoef = clamp(relativeCurrentPressure * powertrain.invCurrentEnvPressure, -1, 1)

        flowRate = -v.pressureDumpFlowRate * desiredFlowCoef * sign(flowRateCoef) * lookupFlowRate(abs(flowRateCoef))
      end

      if abs(flowPressureDiff) > 10 then
        flowRateSum = flowRateSum + flowRate

        airVolumeMoved = flowRate * dt
        airEnergyMoved = sourcePressure * airVolumeMoved
        prevEnergy = v.storedEnergy

        -- determine new stored energy quantity
        v.storedEnergy = max(0, v.storedEnergy + airEnergyMoved)

        -- determine amount of energy to move between actuator and air tank, if valve is in that position
        energyTransferred = v.storedEnergy - prevEnergy

        if g.valveState > 0 then
          v.energyDeltaThisTick = v.energyDeltaThisTick + energyTransferred
          airTank.storedEnergy = max(0, airTank.storedEnergy - energyTransferred)
        end

        -- determine new pressure
        v.currentPressure = v.storedEnergy * invBeamVolume -- PV = e, therefore P = e / V
        pressureSum = pressureSum + v.currentPressure

        setBeamPressureCore(v.cid, v.currentPressure, v.maxBeamPressure, v.spring, v.damp)
      end

      g.averagePressure = g.averagePressure + v.currentPressure
    end

    if g.beamCount > 0 then
      local invBeamCount = 1 / g.beamCount
      g.averageFlowRate = flowRateSum * invBeamCount
      g.averagePressure = g.averagePressure * invBeamCount
    else
      g.averageFlowRate = 0
    end
  end

  -- since we update the stored energy of the air tank more than once per GFX step, we should update the pressure when we're done as well
  airTank.currentPressure = airTank.storedEnergy * airTank.invCapacity

  if totalBeamCount > 0 then
    averagePressure = pressureSum / totalBeamCount
  else
    averagePressure = 0
  end
end

local function updateGFX(dt)
  for _, g in pairs(beamGroups) do
    if g.enableDebug then
      streams.drawGraph(g.name .. "_avgPressure", { value = g.averagePressure * pascalToPSI, unit = "PSI" })
    end

    for _, v in pairs(g.beams) do
      if v.enableDebug then
        streams.drawGraph(v.name .. "_pressure", { value = v.currentPressure * pascalToPSI, unit = "PSI" })
        streams.drawGraph(v.name .. "_energyDelta", { value = v.energyDeltaThisTick, unit = "J" })
      end

      v.energyDeltaThisTick = 0
    end

    if g.hasSoundData then
      local increasing = g.averageFlowRate > 0
      local startFlowRateThreshold = increasing and g.startFlowRateThresholdPressureIncrease or g.startFlowRateThresholdPressureDecrease
      local stopFlowRateThreshold = increasing and g.stopFlowRateThresholdPressureIncrease or g.stopFlowRateThresholdPressureDecrease
      local volumeFactor = increasing and g.flowRateVolumeFactorIncrease or g.flowRateVolumeFactorDecrease
      local volumeCoef = volumeFactor == 0 and 1 or clamp(abs(g.averageFlowRate) * volumeFactor, 0, 1)

      if g.isPlayingIncrease then
        obj:setVolume(g.soundLoopIncrease, g.volumeIncrease * volumeCoef)
      end
      if g.isPlayingDecrease then
        obj:setVolume(g.soundLoopDecrease, g.volumeDecrease * volumeCoef)
      end

      if abs(g.averageFlowRate) > startFlowRateThreshold then
        -- Start playing the appropriate sound

        if increasing then
          obj:stopSFX(g.soundLoopDecrease)
          g.isPlayingDecrease = false
          if not g.isPlayingIncrease then
            obj:setVolume(g.soundLoopIncrease, g.volumeIncrease * volumeCoef)
            obj:cutSFX(g.soundLoopIncrease)
            obj:playSFX(g.soundLoopIncrease)
            g.isPlayingIncrease = true
          end
        else
          obj:stopSFX(g.soundLoopIncrease)
          g.isPlayingIncrease = false
          if not g.isPlayingDecrease then
            obj:setVolume(g.soundLoopDecrease, g.volumeDecrease * volumeCoef)
            obj:cutSFX(g.soundLoopDecrease)
            obj:playSFX(g.soundLoopDecrease)
            g.isPlayingDecrease = true
          end
        end
      elseif abs(g.averageFlowRate) < stopFlowRateThreshold then
        -- Stop playing all sounds

        obj:stopSFX(g.soundLoopIncrease)
        obj:stopSFX(g.soundLoopDecrease)
        g.isPlayingIncrease = false
        g.isPlayingDecrease = false
      end
    end

    electrics.values[g.avgPressureElectricsName] = g.averagePressure - powertrain.currentEnvPressure
  end
end

local function reset()
  for _, g in pairs(beamGroups) do
    for _, v in pairs(g.beams) do
      v.targetPressure = v.defaultPressure
      v.currentPressure = v.defaultPressure
    end
    g.hasChangedVelocity = false
    g.averagePressure = 0
  end

  -- compute average pressure of all beams
  averagePressure = 0
  totalBeamCount = 0

  for _, g in pairs(beamGroups) do
    for _, b in ipairs(g.beams) do
      averagePressure = averagePressure + b.currentPressure
      totalBeamCount = totalBeamCount + 1
    end
  end

  if totalBeamCount > 0 then
    averagePressure = averagePressure / totalBeamCount
  end
end

local function init(jbeamData)
  local airTankName = jbeamData.airTankName or "mainAirTank"

  airTank = energyStorage.getStorage(airTankName)

  if not airTank then
    log("E", "actuators.init", "Air tank not found: " .. airTankName)
    M.updateFixedStep = nop
  end

  -- compute a lookup table to quickly approximate sqrt(x) in updateFixedStep
  flowRateCoefMap = {}
  for i = 0, 100 do
    flowRateCoefMap[i] = sqrt(i / 100)
  end

  local supplyHoseRadius = jbeamData.supplyHoseRadius or 0.0075 -- meters
  local pressureDumpFlowRate = jbeamData.pressureDumpFlowRate or 0.01 -- m^3/s (used when valve is open to atmosphere)
  local maxSupplyPressure = jbeamData.maxSupplyPressure or math.huge
  if type(jbeamData.maxSupplyPressurePSI) == "number" then
    maxSupplyPressure = jbeamData.maxSupplyPressurePSI * psiToPascal + 101325
  end

  enableCrossFlow = jbeamData.crossFlowBetweenBeams or false
  enableDebug = jbeamData.debug or false

  local pressureBeamData = v.data[jbeamData.pressuredBeams] or {}

  local pressuredBeamNames = {}
  for _, v in pairs(pressureBeamData) do
    local name = v.beamName
    pressuredBeamNames[name] = true
  end

  local relevantBeams = {}
  local beams = v.data.beams
  for i = 0, tableSizeC(beams) - 1 do
    local v = beams[i]
    if v.name and pressuredBeamNames[v.name] then
      relevantBeams[v.name] = {
        cid = v.cid,
        defaultPressure = v.pressure,
        maxPressure = v.maxPressure,
        spring = v.beamSpring,
        damp = v.beamDamp,
        surface = v.surface
      }
    end
  end

  beamGroups = {}
  for _, pressureData in pairs(pressureBeamData) do
    local name = pressureData.beamName
    local groupName = pressureData.groupName

    local beamSupplyHoseRadius = pressureData.supplyHoseRadius or supplyHoseRadius
    local supplyHoseCrossSectionArea = math.pi * beamSupplyHoseRadius ^ 2
    local beamPressureDumpFlowRate = pressureData.pressureDumpFlowRate or pressureDumpFlowRate
    local beamMaxSupplyPressure = pressureData.maxSupplyPressure or maxSupplyPressure
    if type(pressureData.maxSupplyPressurePSI) == "number" then
      beamMaxSupplyPressure = pressureData.maxSupplyPressurePSI * psiToPascal + 101325
    end

    local beamEnableDebug = pressureData.debug or false

    if not beamGroups[groupName] then
      beamGroups[groupName] = {
        name = groupName,
        beams = {},
        beamCount = 0,
        isPlayingIncrease = false,
        isPlayingDecrease = false,
        valveState = 0,
        averageFlowRate = 0,
        averagePressure = 0,
        avgPressureElectricsName = M.name .. "_" .. groupName .. "_pressure_avg",
        enableDebug = false,
      }
    end

    local group = beamGroups[groupName]

    if not relevantBeams[name] then
      log("W", "actuators.init", "Can't find beam with name: " .. name)
    else
      local beamLength = obj:getBeamLength(relevantBeams[name].cid)
      local beamVolume = relevantBeams[name].surface * beamLength

      local beamData = {
        name = name,
        cid = relevantBeams[name].cid,
        maxBeamPressure = relevantBeams[name].maxPressure,
        spring = relevantBeams[name].spring,
        damp = relevantBeams[name].damp,
        surface = relevantBeams[name].surface,
        defaultPressure = relevantBeams[name].defaultPressure,
        currentPressure = relevantBeams[name].defaultPressure,
        storedEnergy = relevantBeams[name].defaultPressure * beamVolume,
        energyDeltaThisTick = 0,
        supplyHoseCrossSectionArea = supplyHoseCrossSectionArea,
        pressureDumpFlowRate = beamPressureDumpFlowRate,
        maxSupplyPressure = beamMaxSupplyPressure,
        enableDebug = beamEnableDebug and enableDebug,
      }

      --log("D", "actuators.init", ("beam %q volume: %f"):format(name, beamVolume))

      table.insert(group.beams, beamData)
      group.beamCount = group.beamCount + 1
      group.enableDebug = group.enableDebug or beamEnableDebug
    end
  end

  -- compute average pressure of all beams
  averagePressure = 0
  totalBeamCount = 0

  for _, g in pairs(beamGroups) do
    for _, b in ipairs(g.beams) do
      averagePressure = averagePressure + b.currentPressure
      totalBeamCount = totalBeamCount + 1
    end
  end

  if totalBeamCount > 0 then
    averagePressure = averagePressure / totalBeamCount
  end
end

local function initSounds(jbeamData)
  local pressureBeamSoundData = v.data[jbeamData.groupSounds] or {}

  for _, v in pairs(pressureBeamSoundData) do
    local groupData = beamGroups[v.groupName]
    if groupData then
      groupData.hasSoundData = true
      groupData.volumeIncrease = v.volumeIncrease or v.volume or 1
      groupData.volumeDecrease = v.volumeDecrease or v.volume or 1
      groupData.soundNode = v.node or 0
      groupData.startFlowRateThresholdPressureIncrease = v.startFlowRateThresholdPressureIncrease or v.startFlowRateThreshold or 5.5e-5
      groupData.startFlowRateThresholdPressureDecrease = v.startFlowRateThresholdPressureDecrease or v.startFlowRateThreshold or 5.5e-5
      groupData.stopFlowRateThresholdPressureIncrease = v.stopFlowRateThresholdPressureIncrease or v.stopFlowRateThreshold or 5e-5
      groupData.stopFlowRateThresholdPressureDecrease = v.stopFlowRateThresholdPressureDecrease or v.stopFlowRateThreshold or 5e-5
      groupData.flowRateVolumeFactorIncrease = v.flowRateVolumeFactorIncrease or v.flowRateVolumeFactor or 0
      groupData.flowRateVolumeFactorDecrease = v.flowRateVolumeFactorDecrease or v.flowRateVolumeFactor or 0
      if v.soundIncrease then
        groupData.soundLoopIncrease = obj:createSFXSource(v.soundIncrease, "AudioDefaultLoop3D", "pneumatics_up_" .. v.groupName, groupData.soundNode)
      end
      if v.soundDecrease then
        groupData.soundLoopDecrease = obj:createSFXSource(v.soundDecrease, "AudioDefaultLoop3D", "pneumatics_down_" .. v.groupName, groupData.soundNode)
      end
    else
      log("W", "actuators.initSounds", "Can't find group with name: " .. v.groupName)
    end
  end
end

local function resetSounds()
  for _, g in pairs(beamGroups) do
    if g.soundLoopIncrease then
      obj:setVolume(g.soundLoopIncrease, 0)
      g.isPlayingIncrease = false
    end
    if g.soundLoopDecrease then
      obj:setVolume(g.soundLoopDecrease, 0)
      g.isPlayingDecrease = false
    end
  end
end

M.init = init
M.reset = reset
M.initSounds = initSounds
M.resetSounds = resetSounds
M.updateFixedStep = updateFixedStep
M.updateGFX = updateGFX

M.setBeamGroupValveState = setBeamGroupValveState
M.setBeamGroupsValveState = setBeamGroupsValveState
M.toggleBeamGroupValveState = toggleBeamGroupValveState
M.toggleBeamGroupsValveState = toggleBeamGroupsValveState
M.getValveState = getValveState
M.getAverageFlowRate = getAverageFlowRate
M.getBeamGroupsAverageFlowRate = getBeamGroupsAverageFlowRate

return M
