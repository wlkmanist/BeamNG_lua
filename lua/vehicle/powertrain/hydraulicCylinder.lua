-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local max = math.max
local min = math.min
local abs = math.abs
local sqrt = math.sqrt
local pi = math.pi

--**/VALVE LOGIC**--
--types of dcv: (directional control valve)
--float center: A B connect to T, P blocked, so, slipForce = 0, pumpFlow is blocked
--[WON'T DO] open center: A B and P connect to T, so, slipForce = 0, pumpFlow is free
--tandem center: A B blocked, P connected to T, so slipForce is high, pumpFlow is free, attention, more than one cylinder/valve might act unexpectedly, remember that this is open to tank if no input exists!
--closed center: A B P T blocked, so slipForce is high, pumpFlow is blocked
--drop: special hybrid valve type where A & B are conencted to T upon activation (wheeloader bucket drops to ground, also used for one sided cylinder ie dump truck)
--bypass: special valve type where fluid is allowed to flow into the cylinder when the load is in the same direction as actuation
--**VALVE LOGIC**--

local valveUpdateFunctions

--update the blend stage between normal stages
local function updateBlendedStage(cylinder, stage)
  local blendFactor = linearScale(cylinder.currentExtend, stage.stageExtendStart, stage.stageExtendEnd, 0, 1)
  local invBlendFactor = 1 - blendFactor

  stage.cylinderExtendArea = stage.cylinderExtendAreaStart * invBlendFactor + stage.cylinderExtendAreaEnd * blendFactor
  stage.shaftArea = stage.shaftAreaStart * invBlendFactor + stage.shaftAreaEnd * blendFactor
  stage.cylinderContractArea = stage.cylinderContractAreaStart * invBlendFactor + stage.cylinderContractAreaEnd * blendFactor
  stage.regenAreaRatio = stage.regenAreaRatioStart * invBlendFactor + stage.regenAreaRatioEnd * blendFactor
  stage.invRegenAreaRatio = stage.invRegenAreaRatioStart * invBlendFactor + stage.invRegenAreaRatioEnd * blendFactor
  stage.cylinderActiveArea = cylinder.valveSign >= 0 and stage.cylinderExtendArea or stage.cylinderContractArea
end

local function getRawCylinderStage(cylinder)
  if #cylinder.stages <= 1 then
    cylinder.currentStageId = 1
    return cylinder.stages[1]
  end

  local currentExtend = cylinder.currentExtend
  local currentStageId = cylinder.currentStageId or 0
  local currentStage = cylinder.stages[currentStageId]

  --exit early if we did not switch stages
  if currentStage and currentExtend >= currentStage.stageExtendStart and currentExtend < currentStage.stageExtendEnd then
    return currentStage
  end

  local firstStage = cylinder.stages[1]
  local lastStage = cylinder.stages[#cylinder.stages]
  if currentExtend < firstStage.stageExtendStart then
    cylinder.currentStageId = 1
    return firstStage
  end
  if currentExtend > lastStage.stageExtendEnd then
    cylinder.currentStageId = #cylinder.stages
    return lastStage
  end

  local searchOffset = 1 --start search closest to current stage
  --stop searching when we checked all stages, this is only a backup and should never happen
  local maxSearchOffset = #cylinder.stages - 1

  --search all stages in both directions, starting from the current stage, this is O(1) normally since the stage won't jump more than 1 typically
  while searchOffset <= maxSearchOffset do
    --check next stage
    local candidateInc = cylinder.stages[currentStageId + searchOffset]
    if candidateInc and currentExtend >= candidateInc.stageExtendStart and currentExtend < candidateInc.stageExtendEnd then
      cylinder.currentStageId = currentStageId + searchOffset
      return candidateInc
    end
    --check previous stage
    local candidateDec = cylinder.stages[currentStageId - searchOffset]
    if candidateDec and currentExtend >= candidateDec.stageExtendStart and currentExtend < candidateDec.stageExtendEnd then
      cylinder.currentStageId = currentStageId - searchOffset
      return candidateDec
    end
    searchOffset = searchOffset + 1 --did not find stage, check again with a larger offset
  end

  --this should never happen, but if it does, return the first stage
  log("W", "hydraulicCylinder.getCylinderStage", "No stage found for cylinder " .. cylinder.name)
  cylinder.currentStageId = 1

  return cylinder.stages[1]
end

local function getCylinderStageTelescopic(cylinder)
  local rawStage = cylinder:getRawCylinderStage()
  if rawStage.isTransitionStage then
    cylinder:updateBlendedStage(rawStage)
  end
  return rawStage
end

local function getCylinderStageConventional(cylinder)
  return cylinder.stages[1]
end

local function updateDummy(cylinder, inputPressure, dt)
  return 0, 0
end

local function updateFloat(cylinder, inputPressure, dt)
  local stage = cylinder:getCylinderStage()
  local invBeamCount = cylinder.invBeamCount
  local speedLimit = cylinder.maxSpeed
  local flowDragCoef = cylinder.minimumDragCoef
  local frictionForce = cylinder.frictionCoef * invBeamCount
  local cylinderActiveArea = stage.cylinderActiveArea
  local valvePosition = cylinder.valvePosition
  local valveSign = cylinder.valveSign
  --cylinder.inputPressure = inputPressure --debug
  inputPressure = inputPressure * abs(valvePosition)

  if cylinder.hasRegen then
    if valveSign == cylinder.regenDirection then
      speedLimit = speedLimit * stage.regenAreaRatio
      flowDragCoef = flowDragCoef * stage.invRegenAreaRatio
      cylinderActiveArea = stage.shaftArea
    end
  end

  local cylinderForce = inputPressure * cylinderActiveArea * valveSign
  local cylinderForceSmooth = cylinder.cylinderForceSmoother:get(cylinderForce)
  cylinderForce = sign(cylinderForce) * min(abs(cylinderForceSmooth), abs(cylinderForce)) * invBeamCount

  local currentExtend = 0
  local currentBeamVelocity = 0
  cylinder.cylinderFlow = 0

  for i = 1, cylinder.beamCount do
    local cid = cylinder.beamCids[i]
    local forwardVelocity = max(0, cylinder.previousBeamVelocities[cid] * valveSign)
    local dragForce = (forwardVelocity * forwardVelocity * cylinderActiveArea * flowDragCoef + frictionForce) * invBeamCount
    cylinder.dragForce = dragForce --debug
    --cylinder.cylinderForce = cylinderForce --debug
    --actuateBeam(int outId, float force, float speedLimit, float slipForce, float frictionForce, float slipSpeedLimit, float minExtend, float maxExtend, float virtualMassOut, float virtualMass)
    local beamVelocity = obj:actuateBeam(cid, cylinderForce, speedLimit, 0, dragForce, cylinder.cylinderReliefSlipSpeedLimit, cylinder.minExtend, cylinder.maxExtend, cylinder.virtualMassOut, cylinder.virtualMass)
    currentBeamVelocity = currentBeamVelocity + cylinder.beamVelocitySmoothers[cid]:get(beamVelocity)
    currentExtend = currentExtend + obj:getBeamLength(cid)
    cylinder.previousBeamVelocities[cid] = cylinder.beamVelocitySmoothers[cid]:value(beamVelocity)
    cylinder.cylinderFlow = cylinder.cylinderFlow + (beamVelocity * valveSign) * cylinderActiveArea * invBeamCount
  end

  cylinder.currentExtend = currentExtend * invBeamCount
  cylinder.currentExtendPercent = linearScale(cylinder.currentExtend, cylinder.minExtend, cylinder.maxExtend, 0, 1)
  cylinder.velocity = currentBeamVelocity * invBeamCount

  return max(0, cylinder.cylinderFlow), 0
end

local function updateClosed(cylinder, inputPressure, dt)
  local stage = cylinder:getCylinderStage()
  local invBeamCount = cylinder.invBeamCount
  local speedLimit = cylinder.maxSpeed
  local slipSpeedLimit = cylinder.cylinderReliefSlipSpeedLimit
  local flowDragCoef = cylinder.flowDragCoef
  local frictionForce = cylinder.frictionCoef * invBeamCount
  local cylinderActiveArea = stage.cylinderActiveArea
  local slipForce = cylinder.cylinderReliefPressure * cylinderActiveArea
  local valveSign = cylinder.valveSign
  --cylinder.inputPressure = inputPressure --debug

  if cylinder.hasRegen then
    if valveSign == cylinder.regenDirection then
      speedLimit = speedLimit * stage.regenAreaRatio
      flowDragCoef = flowDragCoef * stage.invRegenAreaRatio
      cylinderActiveArea = stage.shaftArea
    end
  end

  local cylinderForce = inputPressure * cylinderActiveArea * valveSign
  local cylinderForceSmooth = cylinder.cylinderForceSmoother:get(cylinderForce)
  cylinderForce = sign(cylinderForce) * min(abs(cylinderForceSmooth), abs(cylinderForce)) * invBeamCount

  local currentExtend = 0
  local currentBeamVelocity = 0
  cylinder.cylinderFlow = 0

  for i = 1, cylinder.beamCount do
    local cid = cylinder.beamCids[i]
    local forwardVelocity = max(0, cylinder.previousBeamVelocities[cid] * valveSign)
    local dragForce = (forwardVelocity * forwardVelocity * cylinderActiveArea * flowDragCoef + frictionForce) * invBeamCount
    --cylinder.dragForce = dragForce --debug
    --cylinder.cylinderForce = cylinderForce --debug
    --actuateBeam(int outId, float force, float speedLimit, float slipForce, float frictionForce, float slipSpeedLimit, float minExtend, float maxExtend, float virtualMassOut, float virtualMass)
    local beamVelocity = obj:actuateBeam(cid, cylinderForce, speedLimit, slipForce, dragForce, slipSpeedLimit, cylinder.minExtend, cylinder.maxExtend, cylinder.virtualMassOut, cylinder.virtualMass)
    currentBeamVelocity = currentBeamVelocity + cylinder.beamVelocitySmoothers[cid]:get(beamVelocity)
    currentExtend = currentExtend + obj:getBeamLength(cid)
    cylinder.previousBeamVelocities[cid] = cylinder.beamVelocitySmoothers[cid]:value(beamVelocity)
    cylinder.cylinderFlow = cylinder.cylinderFlow + (beamVelocity * valveSign) * cylinderActiveArea * invBeamCount
  end

  cylinder.currentExtend = currentExtend * invBeamCount
  cylinder.currentExtendPercent = linearScale(cylinder.currentExtend, cylinder.minExtend, cylinder.maxExtend, 0, 1)
  cylinder.velocity = currentBeamVelocity * invBeamCount

  return max(0, cylinder.cylinderFlow), 0
end

local function updateTandem(cylinder, inputPressure, dt)
  local stage = cylinder:getCylinderStage()
  local invBeamCount = cylinder.invBeamCount
  local speedLimit = cylinder.maxSpeed
  local slipSpeedLimit = cylinder.cylinderReliefSlipSpeedLimit
  local flowDragCoef = cylinder.flowDragCoef
  local frictionForce = cylinder.frictionCoef * invBeamCount
  local cylinderActiveArea = stage.cylinderActiveArea
  local slipForce = cylinder.cylinderReliefPressure * cylinderActiveArea
  local valveSign = cylinder.valveSign
  --cylinder.inputPressure = inputPressure --debug

  if cylinder.hasRegen then
    if valveSign == cylinder.regenDirection then
      speedLimit = speedLimit * stage.regenAreaRatio
      flowDragCoef = flowDragCoef * stage.invRegenAreaRatio
      cylinderActiveArea = stage.shaftArea
    end
  end

  local cylinderForce = inputPressure * cylinderActiveArea * valveSign
  local cylinderForceSmooth = cylinder.cylinderForceSmoother:get(cylinderForce)
  cylinderForce = sign(cylinderForce) * min(abs(cylinderForceSmooth), abs(cylinderForce)) * invBeamCount

  local currentExtend = 0
  local currentBeamVelocity = 0
  cylinder.cylinderFlow = 0

  for i = 1, cylinder.beamCount do
    local cid = cylinder.beamCids[i]
    local forwardVelocity = max(0, cylinder.previousBeamVelocities[cid] * valveSign)
    local dragForce = (forwardVelocity * forwardVelocity * cylinderActiveArea * flowDragCoef + frictionForce) * invBeamCount
    --cylinder.dragForce = dragForce --debug
    --cylinder.cylinderForce = cylinderForce --debug
    --actuateBeam(int outId, float force, float speedLimit, float slipForce, float frictionForce, float slipSpeedLimit, float minExtend, float maxExtend, float virtualMassOut, float virtualMass)
    local beamVelocity = obj:actuateBeam(cid, cylinderForce, speedLimit, slipForce, dragForce, slipSpeedLimit, cylinder.minExtend, cylinder.maxExtend, cylinder.virtualMassOut, cylinder.virtualMass)
    currentBeamVelocity = currentBeamVelocity + cylinder.beamVelocitySmoothers[cid]:get(beamVelocity)
    currentExtend = currentExtend + obj:getBeamLength(cid)
    cylinder.previousBeamVelocities[cid] = cylinder.beamVelocitySmoothers[cid]:value(beamVelocity)
    cylinder.cylinderFlow = cylinder.cylinderFlow + (beamVelocity * valveSign) * cylinderActiveArea * invBeamCount
  end

  cylinder.currentExtend = currentExtend * invBeamCount
  cylinder.currentExtendPercent = linearScale(cylinder.currentExtend, cylinder.minExtend, cylinder.maxExtend, 0, 1)
  cylinder.velocity = currentBeamVelocity * invBeamCount

  local centerOpening = max(0, 1 - abs(cylinder.valvePosition))
  local maxBypassFlow = inputPressure * cylinder.tandemCenterFlowCoef
  local tankFlow = maxBypassFlow * centerOpening

  return max(0, cylinder.cylinderFlow), tankFlow
end

local function updateDrop(cylinder, inputPressure, dt)
  local stage = cylinder:getCylinderStage()
  local invBeamCount = cylinder.invBeamCount
  local speedLimit = cylinder.maxSpeed
  local slipSpeedLimit = cylinder.cylinderReliefSlipSpeedLimit
  local flowDragCoef = cylinder.flowDragCoef
  local frictionForce = cylinder.frictionCoef * invBeamCount
  local cylinderActiveArea = stage.cylinderActiveArea
  local slipForce = cylinder.cylinderReliefPressure * cylinderActiveArea
  local valvePosition = cylinder.valvePosition
  local valveSign = cylinder.valveSign
  --cylinder.inputPressure = inputPressure --debug

  if valvePosition < cylinder.dropInputThreshold then
    local dropInput = linearScale(abs(valvePosition), abs(cylinder.dropInputThreshold), 1, 0, 1)
    slipForce = linearScale(dropInput, 0, 1, slipForce, 0)
    slipSpeedLimit = linearScale(dropInput * dropInput, 0, 1, 0, cylinder.cylinderReliefSlipSpeedLimit)
    inputPressure = 0
  end

  if cylinder.hasRegen then
    if valveSign == cylinder.regenDirection then
      speedLimit = speedLimit * stage.regenAreaRatio
      flowDragCoef = flowDragCoef * stage.invRegenAreaRatio
      cylinderActiveArea = stage.shaftArea
    end
  end

  local cylinderForce = inputPressure * cylinderActiveArea * valveSign
  local cylinderForceSmooth = cylinder.cylinderForceSmoother:get(cylinderForce)
  cylinderForce = sign(cylinderForce) * min(abs(cylinderForceSmooth), abs(cylinderForce)) * invBeamCount

  local currentExtend = 0
  local currentBeamVelocity = 0
  cylinder.cylinderFlow = 0

  for i = 1, cylinder.beamCount do
    local cid = cylinder.beamCids[i]
    local forwardVelocity = max(0, cylinder.previousBeamVelocities[cid] * valveSign)
    local dragForce = (forwardVelocity * forwardVelocity * cylinderActiveArea * flowDragCoef + frictionForce) * invBeamCount
    --cylinder.dragForce = dragForce --debug
    --cylinder.cylinderForce = cylinderForce --debug
    --actuateBeam(int outId, float force, float speedLimit, float slipForce, float frictionForce, float slipSpeedLimit, float minExtend, float maxExtend, float virtualMassOut, float virtualMass)
    local beamVelocity = obj:actuateBeam(cid, cylinderForce, speedLimit, slipForce, dragForce, slipSpeedLimit, cylinder.minExtend, cylinder.maxExtend, cylinder.virtualMassOut, cylinder.virtualMass)
    currentBeamVelocity = currentBeamVelocity + cylinder.beamVelocitySmoothers[cid]:get(beamVelocity)
    currentExtend = currentExtend + obj:getBeamLength(cid)
    cylinder.previousBeamVelocities[cid] = cylinder.beamVelocitySmoothers[cid]:value(beamVelocity)
    cylinder.cylinderFlow = cylinder.cylinderFlow + (beamVelocity * valveSign) * cylinderActiveArea * invBeamCount
  end

  cylinder.currentExtend = currentExtend * invBeamCount
  cylinder.currentExtendPercent = linearScale(cylinder.currentExtend, cylinder.minExtend, cylinder.maxExtend, 0, 1)
  cylinder.velocity = currentBeamVelocity * invBeamCount

  local tankFlow = 0
  --special hybrid valve type where A & B are conencted to T upon activation (wheeloader bucket drops to ground)
  --experiment if scaling might be a better option rather than outright using a threshold
  if valvePosition < cylinder.dropInputThreshold then
    --set beam velocity to 0 to not affect the acc
    cylinder.cylinderFlow = 0
    tankFlow = 0 --tank flow currently doesn't do anything special, but is here for potential future use
  end

  return max(0, cylinder.cylinderFlow), tankFlow
end

local function updateBypass(cylinder, inputPressure, dt)
  local stage = cylinder:getCylinderStage()
  local invBeamCount = cylinder.invBeamCount
  local speedLimit = cylinder.maxSpeed
  local bypassSpeedLimit = cylinder.maxBypassSpeed
  local slipSpeedLimit = cylinder.cylinderReliefSlipSpeedLimit
  local flowDragCoef = cylinder.flowDragCoef
  local frictionForce = cylinder.frictionCoef * invBeamCount
  local cylinderActiveArea = stage.cylinderActiveArea
  local slipForce = cylinder.cylinderReliefPressure * cylinderActiveArea
  local valvePosition = cylinder.valvePosition
  local valveSign = cylinder.valveSign
  --cylinder.inputPressure = inputPressure --debug

  if cylinder.hasRegen then
    if valveSign == cylinder.regenDirection then
      speedLimit = speedLimit * stage.regenAreaRatio
      bypassSpeedLimit = bypassSpeedLimit * stage.regenAreaRatio
      flowDragCoef = flowDragCoef * stage.invRegenAreaRatio
      cylinderActiveArea = stage.shaftArea
    end
  end

  local cylinderForce = inputPressure * cylinderActiveArea * valveSign
  local cylinderForceSmooth = cylinder.cylinderForceSmoother:get(cylinderForce)
  cylinderForce = sign(cylinderForce) * min(abs(cylinderForceSmooth), abs(cylinderForce)) * invBeamCount

  --used to calculate how much flow would occur through the control valve with no resistance from the cylinder
  local bypassFlowCoef = sqrt(abs(cylinderForce) / (cylinderActiveArea * flowDragCoef))

  local bypassOpen = 0

  --since there are multiple beams, we need to check the condition individually for contribution to bypassOpen value
  for i = 1, cylinder.beamCount do
    local cid = cylinder.beamCids[i]
    bypassOpen = bypassOpen + (valveSign * obj:getBeamStress(cid) > 0 and 1 or 0)
  end

  bypassOpen = bypassOpen * cylinder.invBeamCount
  local bypassOpenSmooth = cylinder.bypassSmoother:get(bypassOpen)

  slipForce = slipForce * (1 - bypassOpenSmooth)
  cylinderForce = cylinderForce * (1 - bypassOpenSmooth)
  flowDragCoef = flowDragCoef * (1 - bypassOpenSmooth * abs(valvePosition))
  speedLimit = linearScale(bypassOpenSmooth, 0, 1, speedLimit, bypassSpeedLimit)

  local currentExtend = 0
  local currentBeamVelocity = 0
  cylinder.cylinderFlow = 0

  for i = 1, cylinder.beamCount do
    local cid = cylinder.beamCids[i]
    local forwardVelocity = max(0, cylinder.previousBeamVelocities[cid] * valveSign)
    local bypassVelocity = bypassFlowCoef * forwardVelocity
    local dragForce = (forwardVelocity * forwardVelocity * cylinderActiveArea * flowDragCoef + frictionForce) * invBeamCount
    --cylinder.dragForce = dragForce --debug
    --cylinder.cylinderForce = cylinderForce --debug
    --actuateBeam(int outId, float force, float speedLimit, float slipForce, float frictionForce, float slipSpeedLimit, float minExtend, float maxExtend, float virtualMassOut, float virtualMass)
    local beamVelocity = obj:actuateBeam(cid, cylinderForce, speedLimit, slipForce, dragForce, slipSpeedLimit, cylinder.minExtend, cylinder.maxExtend, cylinder.virtualMassOut, cylinder.virtualMass)
    currentBeamVelocity = currentBeamVelocity + cylinder.beamVelocitySmoothers[cid]:get(beamVelocity)
    currentExtend = currentExtend + obj:getBeamLength(cid)
    cylinder.previousBeamVelocities[cid] = cylinder.beamVelocitySmoothers[cid]:value(beamVelocity)
    cylinder.cylinderFlow = cylinder.cylinderFlow + (bypassOpenSmooth * bypassVelocity + (1 - bypassOpenSmooth) * beamVelocity * valveSign) * cylinderActiveArea * invBeamCount
  end

  cylinder.currentExtend = currentExtend * invBeamCount
  cylinder.currentExtendPercent = linearScale(cylinder.currentExtend, cylinder.minExtend, cylinder.maxExtend, 0, 1)
  cylinder.velocity = currentBeamVelocity * invBeamCount

  return max(0, cylinder.cylinderFlow), 0
end

local function setValveType(cylinder, valveType)
  if not valveUpdateFunctions[valveType] then
    log("E", "hydraulicCylinder.setValveType", string.format("Invalid valve type: %s", valveType))
    cylinder.update = updateDummy
    return
  end
  cylinder.valveType = valveType
  cylinder.update = valveUpdateFunctions[valveType] or updateDummy
end

--proxy for direct vs position control modes
local function getValvePosition(valvePosition, cylinder, dt)
  if cylinder.valveMode == "direct" then
    return valvePosition
  elseif cylinder.valveMode == "position" then
    local targetPosition = cylinder.targetPosition
    local currentPosition = cylinder.currentExtendPercent

    local closedLoopValvePosition
    local usePID = true
    local error = targetPosition - currentPosition

    if usePID then
      ------ pid way ------
      closedLoopValvePosition = cylinder.positionModeTargetPositionPID:get(currentPosition, targetPosition, dt)
    else
      --needs to target hydro VELOCITY, not POSITION. Need to create a target velocity  based on current and target position manually.
      --line fitting:
      --lineFitting:get(currentValvePosition, currentHydroVelocity)
      --local targetValvePosition = lineFitting:getX(targetHydroVelocity)
      ------- line fitting stuff

      local cylinderVelocity = (cylinder.lastPositionModePosition - currentPosition) / dt
      cylinder.lastPositionModePosition = currentPosition
      local targetVelocity = error / 0.1 -- 0.1 seconds to reach target position, no matter how large the error

      cylinder.positionModeVelocityLineFitting:get(valvePosition, cylinderVelocity)
      closedLoopValvePosition = cylinder.positionModeVelocityLineFitting:getX(targetVelocity)
    end

    --if we reached our target, return to direct mode
    if abs(error) < 0.005 then
      cylinder.valveMode = "direct"
    -- if cylinder.name == "liftR" then
    --   print(cylinder.name .. " -> direct mode")
    -- end
    end
    return clamp(closedLoopValvePosition, -1, 1)
  end
end

local function updateStageActiveArea(cylinder, stage)
  stage.cylinderActiveArea = (cylinder.valveSign >= 0 and stage.cylinderExtendArea or stage.cylinderContractArea)
end

local function updateGFX(cylinder, dt)
  local valvePosition = electrics.values[cylinder.directionElectricsName] or 0
  valvePosition = valvePosition * cylinder.direction or 1
  valvePosition = getValvePosition(valvePosition, cylinder, dt) --update valve position if required by valve mode
  local valveSign = sign(valvePosition)
  valvePosition = sqrt(sqrt(abs(valvePosition))) * valveSign

  cylinder.valvePosition = valvePosition
  cylinder.valveSign = valveSign
  for _, stage in ipairs(cylinder.stages) do
    cylinder:updateStageActiveArea(stage)
  end
  cylinder.flowDragCoef = linearScale(abs(valvePosition), 0, 1, cylinder.maximumDragCoef, cylinder.minimumDragCoef)

  if cylinder.currentExtendElectricsName then
    electrics.values[cylinder.currentExtendElectricsName] = cylinder.currentExtend
  end
  if cylinder.currentExtendPercentElectricsName then
    electrics.values[cylinder.currentExtendPercentElectricsName] = cylinder.currentExtendPercent
  end
end

local function updateSounds(cylinder, dt)
  if cylinder.movementSound then
    local absVelocitySmooth = cylinder.movementVelocitySmoothing:get(abs(cylinder.velocity), dt)
    local volume = linearScale(absVelocitySmooth, cylinder.movementLoopVolumeMinVelocity, cylinder.movementLoopVolumeMaxVelocity, cylinder.movementLoopVolumeMin, cylinder.movementLoopVolumeMax)
    obj:setVolumePitchCT(cylinder.movementSound, volume, 1, 0, 0)

    if cylinder.showDebugGraphSound then
      guihooks.graph({"Velocity", cylinder.velocity, 0.2, "", true}, {"Velocity (smooth)", absVelocitySmooth, 0.2, "", true}, {"Volume", volume, 1, ""})
    end
  end
end

local function initSounds(cylinder, cylinderData)
  local cylinderMovementEvent = cylinderData.movementLoopEvent
  local movementLoopNode = cylinderData.movementLoopNode and beamstate.nodeNameMap[cylinderData.movementLoopNode]
  local movementLoopNodeId = movementLoopNode or 0
  if cylinderMovementEvent then
    cylinder.movementSound = obj:createSFXSource2(cylinderMovementEvent, "AudioDefaultLoop3D", "movementSound", movementLoopNodeId, 1)
    obj:setVolumePitchCT(cylinder.movementSound, 0, 0, 0, 0)
    obj:playSFX(cylinder.movementSound)
  end

  bdebug.setNodeDebugText("Hydraulics", movementLoopNodeId, cylinder.name .. " - Cylinder Movement Loop: " .. (cylinderMovementEvent or "no event"))

  local velocitySmoothingInRate = cylinderData.movementLoopVelocitySmoothingInRate or 5
  local velocitySmoothingStartAccel = cylinderData.movementLoopVelocitySmoothingStartAccel or 2
  local velocitySmoothingStopAccel = cylinderData.movementLoopVelocitySmoothingStopAccel or 2
  local velocitySmoothingOutRate = cylinderData.movementLoopVelocitySmoothingOutRate or 5
  cylinder.movementVelocitySmoothing = newTemporalSigmoidSmoothing(velocitySmoothingInRate, velocitySmoothingStartAccel, velocitySmoothingStopAccel, velocitySmoothingOutRate)

  cylinder.movementLoopVolumeMin = cylinderData.movementLoopVolumeMin or 0
  cylinder.movementLoopVolumeMax = cylinderData.movementLoopVolumeMax or 1
  cylinder.movementLoopVolumeMinVelocity = cylinderData.movementLoopVolumeMinVelocity or 0.001
  cylinder.movementLoopVolumeMaxVelocity = cylinderData.movementLoopVolumeMaxVelocity or 0.05

  cylinder.showDebugGraphSound = cylinderData.showDebugGraphSound or false
end

local function resetSounds(cylinder, cylinderData)
  cylinder.movementVelocitySmoothing:reset()
end

local function reset(cylinder, jbeamData)
  cylinder.cylinderForceSmoother:reset()
  cylinder.bypassSmoother:reset()
  cylinder.velocity = 0
  cylinder.currentExtend = 0
  cylinder.currentExtendPercent = 0

  cylinder.valvePosition = 0
  cylinder.valveSign = 0

  for _, stage in ipairs(cylinder.stages) do
    cylinder:updateStageActiveArea(stage)
  end

  cylinder.lastPositionModePosition = 0

  table.clear(cylinder.stateData)

  for _, bvs in pairs(cylinder.beamVelocitySmoothers) do
    bvs:reset()
  end
  for k, _ in pairs(cylinder.previousBeamVelocities) do
    cylinder.previousBeamVelocities[k] = 0
  end

  cylinder.currentStageId = cylinder.initialStageId

  if cylinder.currentExtendElectricsName then
    electrics.values[cylinder.currentExtendElectricsName] = cylinder.currentExtend
  end
  if cylinder.currentExtendPercentElectricsName then
    electrics.values[cylinder.currentExtendPercentElectricsName] = cylinder.currentExtendPercent
  end
end

local function getState(cylinder)
  cylinder.stateData[cylinder.stateDataNameTargetPosition] = cylinder.currentExtendPercent
  return cylinder.stateData
end

local function setState(cylinder, data)
  if not data then
    return
  end

  local targetPosition = data[cylinder.stateDataNameTargetPosition]
  if targetPosition then
    if abs(cylinder.currentExtendPercent - targetPosition) > 0.005 then
      cylinder.targetPosition = targetPosition
      cylinder.valveMode = "position"
    end
  end
end

local function new(cylinderData, pumpDevice)
  valveUpdateFunctions = {
    float = updateFloat,
    closed = updateClosed,
    tandem = updateTandem,
    drop = updateDrop,
    bypass = updateBypass
  }

  local cylinder = {
    connectedPump = pumpDevice,
    name = cylinderData.name,
    direction = sign(cylinderData.direction or 1), -- either 1 or -1, -1 inverts the direction of movement
    valveType = cylinderData.valveType or "closed", --float, closed, tandem, drop, bypass
    hasRegen = cylinderData.hasRegen or false,
    regenDirection = cylinderData.regenDirection or 1,
    dropInputThreshold = cylinderData.dropInputThreshold or -0.8,
    tandemCenterFlowCoef = cylinderData.tandemCenterFlowCoef or 0.1,
    cylinderReliefPressure = cylinderData.cylinderReliefPressure or 50000000,
    cylinderReliefSlipSpeedLimit = cylinderData.cylinderReliefSlipSpeedLimit or 0.1,
    minimumDragCoef = cylinderData.minimumDragCoef or 10000000,
    maximumDragCoef = cylinderData.maximumDragCoef or 100000000,
    frictionCoef = cylinderData.frictionCoef or 1,
    stageTransitionZoneWidth = cylinderData.stageTransitionZoneWidth or 0.03,
    blendedStage = {},
    maxSpeed = cylinderData.maxSpeed,
    minExtend = cylinderData.minExtend,
    maxExtend = cylinderData.maxExtend,
    virtualMassOut = cylinderData.virtualMassOut or -1,
    currentExtend = 0,
    currentExtendPercent = 0,
    velocity = 0,
    lastPositionModePosition = 0,
    directionElectricsName = cylinderData.directionElectricsName,
    currentExtendElectricsName = cylinderData.currentExtendElectricsName,
    currentExtendPercentElectricsName = cylinderData.currentExtendPercentElectricsName,
    valveMode = "direct", --direct, position
    beamCids = {},
    beamCount = 0,
    invBeamCount = 0,
    beamVelocitySmoothers = {},
    previousBeamVelocities = {},
    stateData = {},
    --removes force spikes when the valve opens
    cylinderForceSmoothing = cylinderData.cylinderForceSmoothing or 100,
    --stabilises the drag and smooths flow from the pump
    cylinderVelocitySmoothing = cylinderData.cylinderVelocitySmoothing or 20,
    reset = reset,
    initSounds = initSounds,
    resetSounds = resetSounds,
    update = updateDummy, --default to dummy update function, changes based on valve type
    updateSounds = updateSounds,
    updateGFX = updateGFX,
    getState = getState,
    setState = setState,
    setValveType = setValveType,
    updateStageActiveArea = updateStageActiveArea,
    getRawCylinderStage = getRawCylinderStage,
    updateBlendedStage = updateBlendedStage
  }

  cylinder.stateDataNameTargetPosition = cylinder.connectedPump.name .. "_" .. cylinder.name .. "_target_position"

  cylinder.virtualMass = cylinderData.virtualMass or cylinder.virtualMassOut
  cylinder.cylinderForceSmoother = newExponentialSmoothing(cylinder.cylinderForceSmoothing)
  cylinder.bypassSmoother = newExponentialSmoothing(50)
  cylinder.maxBypassSpeed = cylinderData.maxBypassSpeed or cylinder.cylinderReliefSlipSpeedLimit

  cylinder.dragCoefRange = max(cylinder.maximumDragCoef - cylinder.minimumDragCoef, 0)
  cylinder.flowDragCoef = 0

  cylinder.valvePosition = 0
  cylinder.valveSign = 0

  cylinder.stages = {}

  --default to single stage get
  cylinder.getCylinderStage = getCylinderStageConventional

  if not cylinderData.stages then
    local shaftDiameter = max(cylinderData.shaftDiameter or 0, 0.0001)
    local pistonDiameter = max(cylinderData.pistonDiameter or 0, 0.001)
    local defaultStage = {
      stageExtendStart = cylinder.minExtend,
      stageExtendEnd = cylinder.maxExtend,
      cylinderExtendArea = pistonDiameter * pistonDiameter * pi / 4,
      shaftArea = shaftDiameter * shaftDiameter * pi / 4
    }
    defaultStage.regenAreaRatio = defaultStage.cylinderExtendArea / defaultStage.shaftArea
    defaultStage.invRegenAreaRatio = defaultStage.shaftArea / defaultStage.cylinderExtendArea
    defaultStage.cylinderContractArea = defaultStage.cylinderExtendArea - defaultStage.shaftArea
    table.insert(cylinder.stages, defaultStage)
  else
    local tempStages = {}
    local stageCount = #cylinderData.stages

    for i = 1, stageCount do
      local stageData = cylinderData.stages[i]
      local stage = {
        stageExtendStart = stageData.stageExtendStart,
        stageExtendEnd = stageData.stageExtendEnd,
        cylinderExtendArea = stageData.pistonDiameter * stageData.pistonDiameter * pi / 4,
        shaftArea = stageData.shaftDiameter * stageData.shaftDiameter * pi / 4
      }
      stage.regenAreaRatio = stage.cylinderExtendArea / stage.shaftArea
      stage.invRegenAreaRatio = stage.shaftArea / stage.cylinderExtendArea
      stage.cylinderContractArea = stage.cylinderExtendArea - stage.shaftArea
      table.insert(tempStages, stage)
    end

    if stageCount > 1 then
      --if we have multiple stages, use the telescopic get method
      cylinder.getCylinderStage = getCylinderStageTelescopic

      local stageTransitionZoneHalfWidth = cylinder.stageTransitionZoneWidth * 0.5
      --iterate again and add transition stages
      for i = 1, stageCount do
        local currentStage = tempStages[i]
        local nextStage = tempStages[i + 1]

        --not for first stage
        if i > 1 then
          --adjust start for transition zone
          currentStage.stageExtendStart = currentStage.stageExtendStart + stageTransitionZoneHalfWidth
        end

        --insert current stage
        table.insert(cylinder.stages, currentStage)

        if not nextStage then
          break
        end

        --don't add transition stage past last stage
        if i < stageCount then
          --adjust end for transition zone
          currentStage.stageExtendEnd = currentStage.stageExtendEnd - stageTransitionZoneHalfWidth

          --create transition stage
          local transitionStage = {
            stageExtendStart = currentStage.stageExtendEnd,
            stageExtendEnd = currentStage.stageExtendEnd + cylinder.stageTransitionZoneWidth,
            cylinderExtendAreaStart = currentStage.cylinderExtendArea,
            cylinderExtendAreaEnd = nextStage.cylinderExtendArea,
            cylinderContractAreaStart = currentStage.cylinderContractArea,
            cylinderContractAreaEnd = nextStage.cylinderContractArea,
            shaftAreaStart = currentStage.shaftArea,
            shaftAreaEnd = nextStage.shaftArea,
            regenAreaRatioStart = currentStage.regenAreaRatio,
            regenAreaRatioEnd = nextStage.regenAreaRatio,
            invRegenAreaRatioStart = currentStage.invRegenAreaRatio,
            invRegenAreaRatioEnd = nextStage.invRegenAreaRatio,
            isTransitionStage = true,
            --these are to be filled by the actual transition code at runtime based on the start and end values
            cylinderExtendArea = nil,
            shaftArea = nil,
            cylinderContractArea = nil,
            regenAreaRatio = nil,
            invRegenAreaRatio = nil
          }

          --insert transition stage after current stage
          table.insert(cylinder.stages, transitionStage)
        end
      end
    end
  end

  for _, stage in ipairs(cylinder.stages) do
    cylinder:updateStageActiveArea(stage)
  end

  --cylinder.positionModeVelocityLineFitting = newLineFitting(30)
  cylinder.positionModeTargetPositionPID = newPIDStandard(1, 0.4, 0, -1, 1, 10, 10, -1, 1)

  cylinder:setValveType(cylinder.valveType)

  local currentExtend = 0
  for _, bt in pairs(cylinderData.beamTags) do
    if beamstate.tagBeamMap[bt] then
      for _, cid in pairs(beamstate.tagBeamMap[bt]) do
        table.insert(cylinder.beamCids, cid)
        cylinder.beamVelocitySmoothers[cid] = newExponentialSmoothing(cylinder.cylinderVelocitySmoothing)
        cylinder.previousBeamVelocities[cid] = 0
        cylinder.beamCount = cylinder.beamCount + 1
        currentExtend = currentExtend + obj:getBeamRestLength(cid)
      end
    end
  end
  cylinder.invBeamCount = 1 / cylinder.beamCount
  cylinder.currentExtend = currentExtend * cylinder.invBeamCount
  cylinder.currentExtendPercent = linearScale(cylinder.currentExtend, cylinder.minExtend, cylinder.maxExtend, 0, 1)

  cylinder.initialStageId = 1
  for stageId, stage in ipairs(cylinder.stages) do
    local isLastStage = stageId == #cylinder.stages
    if cylinder.currentExtend >= stage.stageExtendStart and (cylinder.currentExtend < stage.stageExtendEnd or (isLastStage and cylinder.currentExtend <= stage.stageExtendEnd)) then
      cylinder.initialStageId = stageId
      break
    end
  end
  cylinder.currentStageId = cylinder.initialStageId

  if cylinder.currentExtendElectricsName then
    electrics.values[cylinder.currentExtendElectricsName] = cylinder.currentExtend
  end
  if cylinder.currentExtendPercentElectricsName then
    electrics.values[cylinder.currentExtendPercentElectricsName] = cylinder.currentExtendPercent
  end

  return cylinder
end

M.new = new

return M
