-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.outputPorts = {}
M.deviceCategories = {hydraulicPowerSource = true}

local max = math.max
local min = math.min
local abs = math.abs
local sqrt = math.sqrt

local avToRPM = 9.549296596425384

local function updateTorque(device, dt)
  --accumulator
  device.accumulatorPressure = device.accumulatorWorkingPressure / device.accumulatorMaxVolume * device.accumulatorOilVolume
  device.accumulatorOutFlow = 0

  for _, consumer in ipairs(device.connectedConsumers) do
    local consumerFlow, tankFlow = consumer:update(device.accumulatorPressure, dt)
    device.accumulatorOutFlow = device.accumulatorOutFlow + consumerFlow + tankFlow
  end

  device.reliefFullyOpenPressure = device.reliefOpeningPressure + device.reliefPressureRange --pre-compute TODO

  --gradually open relief flow as pressure builds, otherwise we get unstable pressure limit

  local reliefPressureScale = linearScale(device.accumulatorPressure, device.reliefOpeningPressure, device.reliefFullyOpenPressure, 0, 1)
  device.reliefFlow = 0.6 * device.reliefValveArea * reliefPressureScale * sqrt(2 * abs(device.accumulatorPressure) * 0.0012) -- 0.6: efficiency, 0.0012: oil density

  device.accumulatorOutFlow = device.accumulatorOutFlow + device.reliefFlow

  device[device.outputTorqueName] = 0 --set to 0 to stop children receiving torque

  -- ------------- Accumulator input -----------------------------
  device.accumulatorOilVolume = clamp(device.accumulatorOilVolume - device.accumulatorOutFlow * dt, 0, device.accumulatorMaxVolume * 2)
end

local function updateGFX(device, dt)
  for _, consumer in ipairs(device.connectedConsumers) do
    consumer:updateGFX(dt)
  end

  --consumer side---
  device.accumulatorInFlow = 0
  if not device.isBroken and device.hydraulicPTOSupplyPressureElectricsName and device.hydraulicPTOSupplyFlowElectricsName and device.hydraulicPTOSupplyMaxFlowRateElectricsName then
    local supplyPressure = electrics.values[device.hydraulicPTOSupplyPressureElectricsName] or 0 --supply pressure from our supply (which can be another consumer, but we don't care)
    local localPressure = device.accumulatorPressure
    local maxPTOFlowRate = electrics.values[device.hydraulicPTOSupplyMaxFlowRateElectricsName] or 0

    local accInFlowRate = min(max(supplyPressure - localPressure, 0) * device.consumerPressureDiffFlowRateCoef, maxPTOFlowRate * 1.1) --prevent backflow from remote acc to pump acc, TODO check if good idea
    device.accumulatorInFlow = accInFlowRate

    device.accumulatorOilVolume = clamp(device.accumulatorOilVolume + accInFlowRate * dt, 0, device.accumulatorMaxVolume * 2)
    electrics.values[device.hydraulicPTOSupplyFlowElectricsName] = accInFlowRate
  elseif device.hydraulicPTOSupplyFlowElectricsName then
    electrics.values[device.hydraulicPTOSupplyFlowElectricsName] = 0
  end

  ---supply side---
  --send our own consumer pressure to further potential consumers of our own down the line
  --don't send more than our own supply pressure so that if a tank loses supply, this will propagate to the next consumer
  -- for the initial supply with a compressor, current and supply are the same, so it doesn't matter there
  electrics.values[device.hydraulicPTOConsumerPressureElectricsName] = device.accumulatorPressure
  electrics.values[device.hydraulicPTOConsumerMaxFlowRateElectricsName] = device.pumpFlowRate
  local ptoFlowOut = 0
  for _, flowElectricsName in pairs(device.hydraulicPTOConsumerFlowElectricsNames) do
    ptoFlowOut = ptoFlowOut + (electrics.values[flowElectricsName] or 0)
  end
  device.accumulatorOilVolume = clamp(device.accumulatorOilVolume - ptoFlowOut * dt, 0, device.accumulatorMaxVolume * 2)
  ------

  if device.showDebugGraph then
    guihooks.graph({"Pressure", device.accumulatorPressure, 25000000, ""}, {"PTO In Flow", device.accumulatorInFlow, 0.005}, {"RPM", device.inputAV * avToRPM, 200}, {"Relief Flow", device.reliefFlow, 0.01})
  end
end

local function updateSounds(device, dt)
  for _, consumer in ipairs(device.connectedConsumers) do
    consumer:updateSounds(dt)
  end
end

local function onCouplerAttached(device, nodeId, obj2id, obj2nodeId, attachForce)
  --if the attached node is our supply node (ie the one where WE connect to OUR supply) and we act as consumer
  if device.hydraulicPTOSupplyCouplerNodeLookup[nodeId] then
    --print("we are consumer")
    --we now need to create the correct electrics names to sync with our supply consiting of the agreed upon base name and the supply's objId
    device.hydraulicPTOSupplyPressureElectricsName = device.hydraulicPTOPressureBaseElectricsName .. "_" .. obj2id
    device.hydraulicPTOSupplyFlowElectricsName = device.hydraulicPTOFlowBaseElectricsName .. "_" .. obj2id .. "_" .. objectId
    device.hydraulicPTOSupplyMaxFlowRateElectricsName = device.hydraulicPTOMaxFlowRateBaseElectricsName .. "_" .. obj2id

    --initialize both pressure and flow to 0, flow will then be updated by us and pressure by the supply
    electrics.values[device.hydraulicPTOSupplyPressureElectricsName] = 0
    electrics.values[device.hydraulicPTOSupplyFlowElectricsName] = 0
    electrics.values[device.hydraulicPTOSupplyMaxFlowRateElectricsName] = 0
    --print(device.hydraulicPTOSupplyPressureElectricsName)
    --print(device.hydraulicPTOSupplyFlowElectricsName)
    --print(device.hydraulicPTOSupplyMaxFlowRateElectricsName)
    beamstate.sendExportCouplerData(obj2id, obj2nodeId, {electrics = {device.hydraulicPTOSupplyPressureElectricsName, device.hydraulicPTOSupplyMaxFlowRateElectricsName}})
  end

  --if we just attached to our own consumer (ie we act as supply)
  if device.hydraulicPTOConsumerCouplerNodeLookup[nodeId] then
    --print("we are supply")
    --initialize the reported pressure and flow to 0, flow is then constantly updated from the consumer via the coupler and pressure by us
    electrics.values[device.hydraulicPTOConsumerPressureElectricsName] = 0
    electrics.values[device.hydraulicPTOConsumerMaxFlowRateElectricsName] = 0
    local flowElectricsName = device.hydraulicPTOFlowBaseElectricsName .. "_" .. objectId .. "_" .. obj2id
    device.hydraulicPTOConsumerFlowElectricsNames[obj2id] = flowElectricsName
    electrics.values[flowElectricsName] = 0
    beamstate.sendExportCouplerData(obj2id, obj2nodeId, {electrics = {flowElectricsName}})
  end
end

local function onCouplerDetached(device, nodeId, obj2id, obj2nodeId, breakForce)
  --if the decoupled node is our supply node (ie the one where WE connect to OUR supply)
  if device.hydraulicPTOSupplyCouplerNodeLookup[nodeId] then
    device.supplyPressure = 0
    --if we had any stored supply electric names
    if device.hydraulicPTOSupplyPressureElectricsName then
      --kill the value of the electric
      electrics.values[device.hydraulicPTOSupplyPressureElectricsName] = nil
      --and kill the supply specific name
      device.hydraulicPTOSupplyPressureElectricsName = nil
    end
    if device.hydraulicPTOSupplyFlowElectricsName then
      electrics.values[device.hydraulicPTOSupplyFlowElectricsName] = nil
      device.hydraulicPTOSupplyFlowElectricsName = nil
    end
    if device.hydraulicPTOSupplyMaxFlowRateElectricsName then
      electrics.values[device.hydraulicPTOSupplyMaxFlowRateElectricsName] = nil
      device.hydraulicPTOSupplyMaxFlowRateElectricsName = nil
    end
  end

  --if we just lost our own consumer
  if device.hydraulicPTOConsumerCouplerNodeLookup[nodeId] then
    local flowElectricsName = device.hydraulicPTOConsumerFlowElectricsNames[obj2id]
    if flowElectricsName then
      electrics.values[flowElectricsName] = nil
      device.hydraulicPTOConsumerFlowElectricsNames[obj2id] = nil
    end
  end
end

local function selectUpdates(device)
  device.velocityUpdate = nop
  device.torqueUpdate = updateTorque
end

local function applyDeformGroupDamage(device, damageAmount)
end

local function setPartCondition(device, subSystem, odometer, integrity, visual)
  local integrityState = integrity
  if type(integrity) == "number" then
    local integrityValue = integrity
    integrityState = {isBroken = false}
  end

  if integrityState.isBroken then
    device:onBreak()
  end
end

local function getPartCondition(device)
  local integrityState = {isBroken = device.isBroken}
  local integrityValue = 1
  if device.isBroken then
    integrityValue = 0
  end
  return integrityValue, integrityState
end

local function validate(device)
  return true
end

local function onBreak(device)
  device.isBroken = true
  device.accumulatorPressure = 0
  device.accumulatorOilVolume = 0
  device.accumulatorInFlow = 0
  device.accumulatorOutFlow = 0
  device.reliefFlow = 0
  electrics.values[device.hydraulicPTOConsumerPressureElectricsName] = 0
  electrics.values[device.hydraulicPTOConsumerMaxFlowRateElectricsName] = 0
  if device.hydraulicPTOSupplyFlowElectricsName then
    electrics.values[device.hydraulicPTOSupplyFlowElectricsName] = 0
  end
  selectUpdates(device)
end

local function calculateInertia(device)
  local outputInertia
  local cumulativeGearRatio = 1
  local maxCumulativeGearRatio = 1
  --the pump only has virtual inertia
  outputInertia = device.virtualInertia --some default inertia

  device.cumulativeInertia = outputInertia / device.gearRatio / device.gearRatio
  device.invCumulativeInertia = device.cumulativeInertia > 0 and 1 / device.cumulativeInertia or 0
  device.cumulativeGearRatio = cumulativeGearRatio * device.gearRatio
  device.maxCumulativeGearRatio = maxCumulativeGearRatio * device.gearRatio
end

local function getState(device)
  table.clear(device.stateData)
  device.stateData[device.stateDataNameAccumulatorOilVolume] = device.accumulatorOilVolume
  for _, consumer in ipairs(device.connectedConsumers) do
    if consumer.getState then
      local consumerState = consumer:getState()
      if type(consumerState) == "table" then
        tableMergeRecursive(device.stateData, consumerState)
      end
    end
  end
  return device.stateData
end

local function setState(device, data)
  if not data then
    return
  end

  local newAccumulatorOilVolume = data[device.stateDataNameAccumulatorOilVolume]
  if not device.isBroken and type(newAccumulatorOilVolume) == "number" and newAccumulatorOilVolume == newAccumulatorOilVolume and newAccumulatorOilVolume ~= math.huge and newAccumulatorOilVolume ~= -math.huge then
    device.accumulatorOilVolume = clamp(newAccumulatorOilVolume, 0, device.accumulatorMaxVolume * 2)
    device.accumulatorPressure = device.accumulatorWorkingPressure / device.accumulatorMaxVolume * device.accumulatorOilVolume
  end

  for _, consumer in ipairs(device.connectedConsumers) do
    if consumer.setState then
      consumer:setState(data)
    end
  end
end

local function initSounds(device, jbeamData)
  for _, consumer in ipairs(device.connectedConsumers) do
    if consumer.initSounds then
      consumer:initSounds(device.consumerJbeamData[consumer.name])
    end
  end
end

local function resetSounds(device, jbeamData)
  for _, consumer in ipairs(device.connectedConsumers) do
    if consumer.resetSounds then
      consumer:resetSounds(device.consumerJbeamData[consumer.name])
    end
  end
end

local function reset(device, jbeamData)
  device.gearRatio = jbeamData.gearRatio or 1
  device.friction = jbeamData.friction or 0
  device.cumulativeInertia = 1
  device.invCumulativeInertia = 1
  device.cumulativeGearRatio = 1
  device.maxCumulativeGearRatio = 1

  device.inputAV = 0
  device.lastInputAV = 0
  device.visualShaftAngle = 0
  device.virtualMassAV = 0

  device.isBroken = false

  device.accumulatorPressure = device.initialAccumulatorPressure
  device.accumulatorOilVolume = device.initialAccumulatorOilVolume
  device.accumulatorOutFlow = 0
  device.accumulatorInFlow = 0

  device[device.outputTorqueName] = 0
  device[device.outputAVName] = 0

  electrics.values[device.hydraulicPTOConsumerPressureElectricsName] = 0
  electrics.values[device.hydraulicPTOConsumerMaxFlowRateElectricsName] = 0
  for _, flowElectricsName in pairs(device.hydraulicPTOConsumerFlowElectricsNames) do
    electrics.values[flowElectricsName] = 0
  end

  device.hydraulicPTOSupplyPressureElectricsName = nil --received via electrics from supply vehicle
  device.hydraulicPTOSupplyFlowElectricsName = nil --received via electrics from supply vehicle
  device.hydraulicPTOSupplyMaxFlowRateElectricsName = nil --received via electrics from supply vehicle

  table.clear(device.stateData)

  selectUpdates(device)

  for _, consumer in ipairs(device.connectedConsumers) do
    consumer:reset(device.consumerJbeamData[consumer.name])
  end

  return device
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
    gearRatio = jbeamData.gearRatio or 1,
    friction = jbeamData.friction or 0,
    dynamicFriction = jbeamData.dynamicFriction or 0,
    cumulativeInertia = 1,
    invCumulativeInertia = 1,
    virtualInertia = 1,
    cumulativeGearRatio = 1,
    maxCumulativeGearRatio = 1,
    isPhysicallyDisconnected = true,
    electricsName = jbeamData.electricsName,
    visualShaftAVName = jbeamData.visualShaftAVName,
    inputAV = 0,
    lastInputAV = 0,
    visualShaftAngle = 0,
    virtualMassAV = 0,
    isBroken = false,
    nodeCid = jbeamData.node,
    showDebugGraph = jbeamData.showDebugGraph or false,
    stateData = {},
    reset = reset,
    onBreak = onBreak,
    validate = validate,
    calculateInertia = calculateInertia,
    applyDeformGroupDamage = applyDeformGroupDamage,
    setPartCondition = setPartCondition,
    getPartCondition = getPartCondition,
    initSounds = initSounds,
    resetSounds = resetSounds,
    updateGFX = updateGFX,
    updateSounds = updateSounds,
    onCouplerAttached = onCouplerAttached,
    onCouplerDetached = onCouplerDetached,
    getState = getState,
    setState = setState,
    torqueDiff = 0
  }

  device.connectedConsumers = {}
  device.stateDataNameAccumulatorOilVolume = device.name .. "_accumulatorOilVolume"

  device.accumulatorWorkingPressure = jbeamData.accumulatorWorkingPressure or 25000000

  device.accumulatorMaxVolume = jbeamData.accumulatorMaxVolume or 0.001

  local configuredInitialPressure = jbeamData.initialAccumulatorPressure
  local configuredInitialOilVolume = jbeamData.initialAccumulatorOilVolume
  if type(configuredInitialPressure) == "number" then
    device.initialAccumulatorPressure = clamp(configuredInitialPressure, 0, device.accumulatorWorkingPressure * 2)
    device.initialAccumulatorOilVolume = device.initialAccumulatorPressure * device.accumulatorMaxVolume / device.accumulatorWorkingPressure
    if type(configuredInitialOilVolume) == "number" and abs(configuredInitialOilVolume - device.initialAccumulatorOilVolume) > max(device.accumulatorMaxVolume * 1e-6, 1e-12) then
      log("W", "hydraulicAccumulator.new", "initialAccumulatorPressure: " .. tostring(configuredInitialPressure) .. ", initialAccumulatorOilVolume: " .. tostring(configuredInitialOilVolume) .. ", derivedAccumulatorOilVolume: " .. tostring(device.initialAccumulatorOilVolume))
    end
  elseif type(configuredInitialOilVolume) == "number" then
    device.initialAccumulatorOilVolume = clamp(configuredInitialOilVolume, 0, device.accumulatorMaxVolume * 2)
    device.initialAccumulatorPressure = device.accumulatorWorkingPressure / device.accumulatorMaxVolume * device.initialAccumulatorOilVolume
  else
    device.initialAccumulatorOilVolume = device.accumulatorMaxVolume
    device.initialAccumulatorPressure = device.accumulatorWorkingPressure
  end

  device.reliefOpeningPressure = jbeamData.reliefOpeningPressure or device.accumulatorWorkingPressure * 1.05
  device.reliefPressureRange = jbeamData.reliefPressureRange or 2000000
  device.reliefValveArea = jbeamData.reliefValveArea or 0.0001

  device.accumulatorPressure = device.initialAccumulatorPressure
  device.accumulatorOilVolume = device.initialAccumulatorOilVolume
  device.accumulatorOutFlow = 0
  device.accumulatorInFlow = 0

  device.hydraulicPTOPressureElectricsName = jbeamData.hydraulicPTOPressureElectricsName or "hydraulicPTOPressure"
  device.hydraulicPTOMaxFlowRateElectricsName = jbeamData.hydraulicPTOMaxFlowRateElectricsName or "hydraulicPTOMaxFlowRate"
  device.hydraulicPTOFlowElectricsName = jbeamData.hydraulicPTOFlowElectricsName or "hydraulicPTOFlow"

  electrics.values[device.hydraulicPTOFlowElectricsName] = 0

  local hydraulicConsumerFactories = {}
  hydraulicConsumerFactories.hydraulicCylinder = require("powertrain/hydraulicCylinder")
  --hydraulicConsumerFactories.hydraulicRotator = require("powertrain/hydraulicRotator")

  device.consumerJbeamData = {}
  for _, ph in pairs(v.data.powertrainHydros or {}) do
    if ph.connectedPump == device.name then
      local consumerJbeamData = deepcopy(tableMerge(ph, v.data[ph.name] or {}))
      local consumerName = consumerJbeamData.name
      if device.consumerJbeamData[consumerName] then
        log("E", "hydraulicAccumulator.new", "duplicateConsumerName: " .. tostring(consumerName) .. ", accumulatorName: " .. device.name)
      else
        local consumerType = ph.type
        local factory = hydraulicConsumerFactories[consumerType]
        if factory and type(factory.new) == "function" then
          local consumer = factory.new(consumerJbeamData, device)
          table.insert(device.connectedConsumers, consumer)
          device.consumerJbeamData[consumerName] = consumerJbeamData
        else
          log("E", "hydraulicAccumulator.new", "consumerType: " .. tostring(consumerType) .. ", consumerName: " .. tostring(consumerName))
        end
      end
    end
  end

  device.outputTorqueName = "outputTorque1"
  device.outputAVName = "outputAV1"
  device[device.outputTorqueName] = 0
  device[device.outputAVName] = 0

  device.mode = "connected"

  device.breakTriggerBeam = jbeamData.breakTriggerBeam
  if device.breakTriggerBeam and device.breakTriggerBeam == "" then
    --get rid of the break beam if it's just an empty string (cancellation)
    device.breakTriggerBeam = nil
  end

  --base electrics name that needs to match between vehicles for a connection to work
  --one could make multiple pressure systems using different names
  device.hydraulicPTOPressureBaseElectricsName = jbeamData.hydraulicPTOPressureBaseSyncName or "hydraulicPTOPressure"
  device.hydraulicPTOFlowBaseElectricsName = jbeamData.hydraulicPTOFlowBaseSyncName or "hydraulicPTOFlow"
  device.hydraulicPTOMaxFlowRateBaseElectricsName = jbeamData.hydraulicPTOMaxFlowRateBaseSyncName or "hydraulicPTOMaxFlowRate"
  --these are the electrics names for communication with our CONSUMER
  device.hydraulicPTOConsumerPressureElectricsName = device.hydraulicPTOPressureBaseElectricsName .. "_" .. objectId
  device.hydraulicPTOConsumerMaxFlowRateElectricsName = device.hydraulicPTOMaxFlowRateBaseElectricsName .. "_" .. objectId
  device.hydraulicPTOConsumerFlowElectricsNames = {}

  --these are the electrics names for communication with our SUPPLY, they are generated upon coupling
  --TODO this only supports a single consumer for our supply, to fix this, the electrics name needs to consist of both the supply id and our consumer id...
  device.hydraulicPTOSupplyPressureElectricsName = nil --received via electrics from supply vehicle
  device.hydraulicPTOSupplyFlowElectricsName = nil --received via electrics from supply vehicle
  device.hydraulicPTOSupplyMaxFlowRateElectricsName = nil --received via electrics from supply vehicle

  electrics.values[device.hydraulicPTOConsumerPressureElectricsName] = 0
  electrics.values[device.hydraulicPTOConsumerMaxFlowRateElectricsName] = 0

  --used for looking up if a given coupler belongs to us
  device.hydraulicPTOSupplyCouplerNodeLookup = {}
  local ptoSupplyNodeNames = jbeamData.hydraulicPTOSupplyCouplerNodeNames or {}
  for _, nodeName in pairs(ptoSupplyNodeNames) do
    if beamstate.nodeNameMap[nodeName] then
      device.hydraulicPTOSupplyCouplerNodeLookup[beamstate.nodeNameMap[nodeName]] = true
    end
  end
  --used for looking up if a given coupler belongs to us
  device.hydraulicPTOConsumerCouplerNodeLookup = {}
  local ptoConsumerNodeNames = jbeamData.hydraulicPTOConsumerCouplerNodeNames or {}
  for _, nodeName in pairs(ptoConsumerNodeNames) do
    if beamstate.nodeNameMap[nodeName] then
      device.hydraulicPTOConsumerCouplerNodeLookup[beamstate.nodeNameMap[nodeName]] = true
    end
  end

  --how quickly a pressure difference between local and supply pressure is equalized, this has stability implications as it a P factor
  device.consumerPressureDiffFlowRateCoef = jbeamData.consumerPressureDiffFlowRateCoef or 0.001

  selectUpdates(device)

  return device
end

M.new = new

return M
