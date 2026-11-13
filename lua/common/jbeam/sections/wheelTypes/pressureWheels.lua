--[[
This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
If a copy of the bCDDL was not distributed with this
file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
]]

-- wheel type expander for the jbeam 'pressureWheels' section
-- the file name must match the jbeam section name, that is how the dispatcher finds it

local M = {}

local jbeamUtils = require("jbeam/utils")

-- these are defined in C, do not change the values
local NORMALTYPE = 0
local NONCOLLIDABLE = 2
local BEAM_ANISOTROPIC = 1
local BEAM_LBEAM = 4
local BEAM_SUPPORT = 7

local function cleanupWheelOptions(options)
  options.hubBeamSpring = nil
  options.hubBeamDamp = nil
  options.hubBeamDampCutoffHz = nil
  options.hubBeamDeform = nil
  options.hubBeamStrength = nil
  options.hubNodeWeight = nil
  options.hubCollision = nil
  options.hubNodeMaterial = nil
  options.hubFrictionCoef = nil
  options.hubGroup = nil
  options.disableHubMeshBreaking = nil
  options.hubSideBeamSpring = nil
  options.hubSideBeamDamp = nil
  options.hubSideBeamDeform = nil
  options.hubSideBeamStrength = nil
  options.hubSideBeamDampCutoffHz = nil
  options.hubReinfBeamSpring = nil
  options.hubReinfBeamDamp = nil
  options.hubReinfBeamDeform = nil
  options.hubReinfBeamStrength = nil
  options.hubReinfBeamDampCutoffHz = nil
  options.hubTreadBeamSpring = nil
  options.hubTreadBeamDamp = nil
  options.hubTreadBeamDeform = nil
  options.hubTreadBeamStrength = nil
  options.hubTreadBeamDampCutoffHz = nil
  options.hubPeripheryBeamSpring = nil
  options.hubPeripheryBeamDamp = nil
  options.hubPeripheryBeamDeform = nil
  options.hubPeripheryBeamStrength = nil
  options.hubPeripheryBeamDampCutoffHz = nil
  options.hubStabilizerBeamSpring = nil
  options.hubStabilizerBeamDamp = nil
  options.hubStabilizerBeamDeform = nil
  options.hubStabilizerBeamStrength = nil
  options.hubcapBeamSpring = nil
  options.hubcapBeamDamp = nil
  options.hubcapBeamDeform = nil
  options.hubcapBeamStrength = nil
  options.hubcapNodeWeight = nil
  options.hubcapCollision = nil
  options.hubcapNodeMaterial = nil
  options.hubcapFrictionCoef = nil
  options.hubcapGroup = nil
  options.disableHubcapMeshBreaking = nil
  options.hubcapAttachBeamSpring = nil
  options.hubcapAttachBeamDamp = nil
  options.hubcapAttachBeamDeform = nil
  options.hubcapAttachBeamStrength = nil
  options.hubcapBreakGroup = nil
  options.wheelSideBeamSpring = nil
  options.wheelSideBeamDamp = nil
  options.wheelSideBeamDeform = nil
  options.wheelSideBeamStrength = nil
  options.wheelSideBeamSpringExpansion = nil
  options.wheelSideBeamDampExpansion = nil
  options.wheelSideTransitionZone = nil
  options.wheelSideBeamPrecompression = nil
  options.wheelSideReinfBeamSpring = nil
  options.wheelSideReinfBeamDamp = nil
  options.wheelSideReinfBeamDeform = nil
  options.wheelSideReinfBeamStrength = nil
  options.wheelSideReinfBeamSpringExpansion = nil
  options.wheelSideReinfBeamDampExpansion = nil
  options.wheelSideReinfTransitionZone = nil
  options.wheelSideReinfBeamPrecompression = nil
  options.wheelReinfBeamSpring = nil
  options.wheelReinfBeamDamp = nil
  options.wheelReinfBeamSpringExpansion = nil
  options.wheelReinfBeamDampExpansion = nil
  options.wheelReinfBeamDeform = nil
  options.wheelReinfBeamStrength = nil
  options.wheelReinfBeamPrecompression = nil
  options.wheelReinfBeamDampCutoffHz = nil
  options.wheelTreadBeamSpring = nil
  options.wheelTreadBeamDamp = nil
  options.wheelTreadBeamDeform = nil
  options.wheelTreadBeamStrength = nil
  options.wheelTreadBeamPrecompression = nil
  options.wheelTreadBeamDampCutoffHz = nil
  options.wheelTreadReinfBeamSpring = nil
  options.wheelTreadReinfBeamDamp = nil
  options.wheelTreadReinfBeamDeform = nil
  options.wheelTreadReinfBeamStrength = nil
  options.wheelTreadReinfBeamPrecompression = nil
  options.wheelTreadReinfBeamDampCutoffHz = nil
  options.wheelPeripheryBeamSpring = nil
  options.wheelPeripheryBeamDamp = nil
  options.wheelPeripheryBeamDeform = nil
  options.wheelPeripheryBeamStrength = nil
  options.wheelPeripheryBeamPrecompression = nil
  options.wheelPeripheryBeamDampCutoffHz = nil
  options.wheelPeripheryReinfBeamSpring = nil
  options.wheelPeripheryReinfBeamDamp = nil
  options.wheelPeripheryReinfBeamDeform = nil
  options.wheelPeripheryReinfBeamStrength = nil
  options.wheelPeripheryReinfBeamPrecompression = nil
  options.wheelPeripheryReinfBeamDampCutoffHz = nil
  options.hubRadius = nil
  options.hubWidth = nil
  options.tireWidth = nil
  options.name = nil
  options.wheelOffset = nil
  options.radius = nil
  options.rotorMaterial = nil
  options.numRays = nil
  options.torqueArm = nil
  options.torqueArm2 = nil
  options.wheelDir = nil
  options.padMaterial = nil
  options.pressurePSI = nil
  options.parkingTorque = nil
  options.steerAxisDown = nil

  return options
end

local function cleanupBeamOptions(options)
  options.selfCollision = nil
  options.frictionCoef = nil
  options.loadSensitivitySlope = nil
  options.treadCoef = nil
  options.fullLoadCoef = nil
  options.collision = nil
  options.slidingFrictionCoef = nil

  return options
end

local function addPressTri(tris, presGroup, presPSI, n1, n2, n3, dCoef, tType, sDragCoef)
  tableInsertC(tris, {
      id1 = n1, id2 = n2, id3 = n3,
      dragCoef = dCoef, triangleType = tType,
      pressureGroup = presGroup, pressurePSI = presPSI, skinDragCoef = sDragCoef
    })
end

local function addTri(tris, n1, n2, n3, dCoef, tType)
  tableInsertC(tris, {
      id1 = n1, id2 = n2, id3 = n3,
      dragCoef = dCoef, triangleType = tType
    })
end

local function addPressureWheel(vehicle, wheelKey, wheel)
  local node1   = vehicle.nodes[wheel.node1]
  local node2   = vehicle.nodes[wheel.node2]

  -- Stabilizer
  wheel.nodeStabilizer = wheel.nodeStabilizer or wheel.nodeS
  wheel.treadCoef = wheel.treadCoef or 1
  wheel.hubNodeWeight = wheel.hubNodeWeight or 25
  wheel.nodeS = nil
  local nodeStabilizerExists = false
  local wheelAngleRad = math.rad(wheel.wheelAngle or 0)

  if wheel.nodeStabilizer and wheel.nodeStabilizer ~= 9999 and vehicle.nodes[wheel.nodeStabilizer] then
    nodeStabilizerExists = true
  else
    wheel.nodeStabilizer = nil
  end

  if node1 == nil or node2 == nil then
    log('W', "jbeam.addPressureWheel","invalid pressureWheel")
    return
  end

  local nodebase = vehicle.maxIDs.nodes

  local tireExists = true
  if wheel.radius == nil then
    tireExists = false
    wheel.radius = 0.5
  end

  if wheel.pressurePSI == nil then
    tireExists = false
  end

  if wheel.hasTire ~= nil and wheel.hasTire == false then
    tireExists = false
  end

  if wheel.hubRadius == nil then wheel.hubRadius = 0.65 * wheel.radius end
  if wheel.numRays == nil then wheel.numRays = 10 end

  -- add collision to the wheels nodes ;)
  wheel.collision = true

  -- calculate surface
  -- if tireExists and wheel.tireWidth and wheel.hubWidth and wheel.radius and wheel.hubRadius then
  --   wheel._surface = math.pi * (2 * (wheel.tireWidth * wheel.radius + wheel.hubWidth * wheel.hubRadius) +
  --     (wheel.radius + wheel.hubRadius) * math.sqrt(square(wheel.radius - wheel.hubRadius) + square(wheel.tireWidth - wheel.hubRadius)))
  -- end

  local node1_pos = vec3(node1.pos)
  local node2_pos = vec3(node2.pos)

  -- calculate axis
  local axis = node2_pos - node1_pos
  axis:normalize()

  wheel.hubWidth = wheel.hubWidth or axis:length()

  local midpoint = (node2_pos + node1_pos) * 0.5

  if type(wheel.offsetFromNode) == "number" then
    local halfHwidth = 0.5 * wheel.hubWidth * axis
    if wheel.offsetFromNode == 1 then
      midpoint = node1_pos + halfHwidth
    elseif wheel.offsetFromNode == 2 then
      midpoint = node2_pos - halfHwidth
    end
  end

  if wheel.wheelOffset ~= nil then
    local offset = wheel.wheelOffset
    midpoint = midpoint + axis * offset
  end

  if wheel.tireWidth ~= nil then
    local halfTWidth = 0.5 * wheel.tireWidth * axis
    node1_pos = midpoint - halfTWidth
    node2_pos = midpoint + halfTWidth
  end

  if type(wheel.hubWeight) == "number" then
    wheel.hubNodeWeight = wheel.hubWeight / (2 *wheel.numRays)
  end

  if type(wheel.tireWeight) == "number" then
    wheel.nodeWeight = wheel.tireWeight / (2 * wheel.numRays)
  end

  if type(wheel.hubWeightGainRatio) == "number" and wheel.hubWeightGainRatio >= 0 and wheel.hubWeightGainRatio < 1 then
    wheel.nodeWeight = wheel.nodeWeight * (1-wheel.hubWeightGainRatio)
    wheel.hubNodeWeight = wheel.hubNodeWeight + wheel.nodeWeight * wheel.hubWeightGainRatio
  end

  local cleanwheel = deepcopy(wheel)
  cleanwheel.axleBeams = nil
  cleanwheel.childParts = nil
  cleanwheel.slotType = nil
  cleanwheel.enableABS = nil
  cleanwheel.enableBrakeThermals = nil
  cleanwheel.enableHubcaps = nil
  cleanwheel.enableTireLbeams = nil
  cleanwheel.enableTirePeripheryReinfBeams = nil
  cleanwheel.enableTireReinfBeams = nil
  cleanwheel.enableTireSideReinfBeams = nil
  cleanwheel.enableTreadReinfBeams = nil
  cleanwheel.hasTire = nil
  cleanwheel.brakeDiameter = nil
  cleanwheel.brakeInputSplit = nil
  cleanwheel.brakeMass = nil
  cleanwheel.brakeSplitCoef = nil
  cleanwheel.brakeSpring = nil
  cleanwheel.brakeTorque = nil
  cleanwheel.brakeType = nil
  cleanwheel.brakeVentingCoef = nil
  cleanwheel.heatCoefNodeToEnv = nil
  cleanwheel.heatCoefEnvMultStationary = nil
  cleanwheel.heatCoefEnvTerminalSpeed = nil
  cleanwheel.heatCoefNodeToCore = nil
  cleanwheel.heatCoefCoreToNodes = nil
  cleanwheel.heatCoefNodeToSurface = nil
  cleanwheel.heatCoefFriction = nil
  cleanwheel.heatCoefFlashFriction = nil
  cleanwheel.heatCoefStrain = nil
  cleanwheel.heatAffectsPressure = nil
  cleanwheel.smokingTemp = nil
  cleanwheel.meltingTemp = nil
  cleanwheel.frictionLowTemp = nil
  cleanwheel.frictionHighTemp = nil
  cleanwheel.frictionLowSlope = nil
  cleanwheel.frictionHighSlope = nil
  cleanwheel.frictionSlopeSmoothCoef = nil
  cleanwheel.frictionCoefLow = nil
  cleanwheel.frictionCoefMiddle = nil
  cleanwheel.frictionCoefHigh = nil

  local wheelNodes = cleanupWheelOptions(deepcopy(cleanwheel))

  local conicityFactor = wheel.conicityFactor and clamp(wheel.conicityFactor, 0.5, 1.5) or 1

  local rayRot = quatFromAxisAngle(axis, 2 * math.pi / (wheel.numRays* 2))

  local rayVec
  local treadNodes = {}
  if tireExists then
    rayVec = axis:perpendicularN() * wheel.radius
    rayVec = quatFromAxisAngle(axis, -wheelAngleRad) * rayVec
    local hasEvenRayCount = wheel.numRays % 2 == 0
    -- add nodes first
    local rayRot2 = quatFromAxisAngle(axis, 2 * math.pi / (wheel.numRays))
    local conicityVec = rayRot * (rayVec * conicityFactor)
    local conicityVec2 = rayVec * (2 - conicityFactor)

    for i = 0, wheel.numRays - 1, 1 do
      -- outer
      local rayPoint = node1_pos + conicityVec2
      conicityVec2 = rayRot2 * conicityVec2
      local n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, wheelNodes)
      table.insert(treadNodes, vehicle.nodes[n])
      if hasEvenRayCount then
        --safe opposite tread node for dynamic tire radius measurement
        vehicle.nodes[n].oppositeTreadNodeCid = (i <= (wheel.numRays - 1) / 2) and (n + wheel.numRays) or (n - wheel.numRays)
      end

      -- inner
      rayPoint = node2_pos + conicityVec
      conicityVec = rayRot2 * conicityVec
      n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, wheelNodes)
      table.insert(treadNodes, vehicle.nodes[n])
      if hasEvenRayCount then
        --safe opposite tread node for dynamic tire radius measurement
        vehicle.nodes[n].oppositeTreadNodeCid = (i <= (wheel.numRays - 1) / 2) and (n + wheel.numRays) or (n - wheel.numRays)
      end
    end
  end

  -- add Hub nodes
  local hubNodes = {}
  local hubnodebase = vehicle.maxIDs.nodes
  local hubOptions = deepcopy(cleanwheel)
  hubOptions.beamSpring = hubOptions.hubBeamSpring or hubOptions.beamSpring
  hubOptions.beamDamp = hubOptions.hubBeamDamp or hubOptions.beamDamp
  hubOptions.beamDeform = hubOptions.hubBeamDeform or hubOptions.beamDeform
  hubOptions.beamStrength = hubOptions.hubBeamStrength or hubOptions.beamStrength
  hubOptions.dampCutoffHz = hubOptions.hubBeamDampCutoffHz or nil
  hubOptions.nodeWeight = hubOptions.hubNodeWeight or hubOptions.nodeWeight
  hubOptions.collision = hubOptions.hubCollision or hubOptions.collision
  hubOptions.nodeMaterial = hubOptions.hubNodeMaterial or hubOptions.nodeMaterial
  hubOptions.frictionCoef = hubOptions.hubFrictionCoef or hubOptions.frictionCoef
  hubOptions.group = hubOptions.hubGroup or hubOptions.group
  hubOptions.disableMeshBreaking = hubOptions.disableHubMeshBreaking or hubOptions.disableMeshBreaking

  local minAxleNodeWeightRay = math.min(node1.nodeWeight, node2.nodeWeight) / wheel.numRays
  local frontSpacing = (node1_pos-midpoint):length()
  local backSpacing = (node2_pos-midpoint):length()
  local hubNodeWeightCoef = math.max(0.85 * wheel.hubNodeWeight - 0.33 * (wheel.nodeWeight or 0), 0.01)
  local sMinWeight = minAxleNodeWeightRay * hubNodeWeightCoef / (minAxleNodeWeightRay + hubNodeWeightCoef)

  local hubSideOptions = deepcopy(hubOptions)
  if type(hubSideOptions.hubSideBeamSpring) == "number" and hubSideOptions.hubSideBeamSpring < 0 then
    --highest side beam spring is priority to keep expansion at a minimum, so its currently based only on the node weights, and the other beams get reduced if needed
    hubSideOptions.beamSpring = 9500000 * sMinWeight * hubSideOptions.hubSideBeamSpring * -1
  else
    hubSideOptions.beamSpring = hubSideOptions.hubSideBeamSpring or hubSideOptions.beamSpring
  end

  if type(hubSideOptions.hubSideBeamDamp) == "number" and hubSideOptions.hubSideBeamDamp < 0 then
    hubSideOptions.beamDamp = 0.012 * math.sqrt(sMinWeight * hubSideOptions.beamSpring) * hubSideOptions.hubSideBeamDamp * -1
  else
    hubSideOptions.beamDamp = hubSideOptions.hubSideBeamDamp or hubSideOptions.beamDamp
  end

  hubSideOptions.beamDeform = hubSideOptions.hubSideBeamDeform or hubSideOptions.beamDeform
  hubSideOptions.beamStrength = hubSideOptions.hubSideBeamStrength or hubSideOptions.beamStrength
  hubSideOptions.dampCutoffHz = hubSideOptions.hubSideBeamDampCutoffHz or hubOptions.dampCutoffHz

  local hubReinfOptions = deepcopy(hubSideOptions)
  --additional check needed because wheels in the past had hubReinf undefined and defaulting to hubSide values
  if type(hubReinfOptions.hubReinfBeamSpring) == "number" and hubReinfOptions.hubReinfBeamSpring < 0 then
    --calculate the angle of the hub reinf beams (cross section of wheel hub), choose the minimum angle between front and back spacing
    local hubReinfAngle = math.atan((math.min(frontSpacing, backSpacing) + wheel.hubWidth * 0.5) / wheel.hubRadius)
    local hubReinfAngleCoef = math.cos(3 * hubReinfAngle - math.pi * 0.666) * 0.25 + 0.75
    hubReinfOptions.beamSpring = 8500000 * sMinWeight * hubReinfAngleCoef * hubReinfOptions.hubReinfBeamSpring * -1
  else
    hubReinfOptions.beamSpring = hubReinfOptions.hubReinfBeamSpring or hubReinfOptions.beamSpring
  end
  --additional check needed because wheels in the past had hubReinf undefined and defaulting to hubSide values
  if type(hubReinfOptions.hubReinfBeamDamp) == "number" and hubReinfOptions.hubReinfBeamDamp < 0 then
    hubReinfOptions.beamDamp = 0.012 * math.sqrt(sMinWeight * hubReinfOptions.beamSpring) * hubReinfOptions.hubReinfBeamDamp * -1
  else
    hubReinfOptions.beamDamp = hubReinfOptions.hubReinfBeamDamp or hubReinfOptions.beamDamp
  end

  hubReinfOptions.beamDeform = hubReinfOptions.hubReinfBeamDeform or hubReinfOptions.beamDeform
  hubReinfOptions.beamStrength = hubReinfOptions.hubReinfBeamStrength or hubReinfOptions.beamStrength
  hubReinfOptions.dampCutoffHz = hubReinfOptions.hubReinfBeamDampCutoffHz or hubOptions.dampCutoffHz

  local hubTreadAngle = 2 * math.atan(math.pi * wheel.hubRadius / (wheel.numRays * wheel.hubWidth))

  local hubTreadOptions = deepcopy(hubOptions)
  if type(hubTreadOptions.hubTreadBeamSpring) == "number" and hubTreadOptions.hubTreadBeamSpring < 0 then
    --for wide wheels, decrease the tread beam spring
    local hubTreadAngleCoef = math.cos(2 * (hubTreadAngle)) * 0.2 + 0.8
    hubTreadOptions.beamSpring = 3000000 * wheel.hubNodeWeight * hubTreadAngleCoef * hubTreadOptions.hubTreadBeamSpring * -1
  else
    hubTreadOptions.beamSpring = hubTreadOptions.hubTreadBeamSpring or hubTreadOptions.beamSpring
  end
  if type(hubTreadOptions.hubTreadBeamDamp) == "number" and hubTreadOptions.hubTreadBeamDamp < 0 then
    hubTreadOptions.beamDamp = 0.012 * math.sqrt(wheel.hubNodeWeight * hubTreadOptions.beamSpring) * hubTreadOptions.hubTreadBeamDamp * -1
  else
    hubTreadOptions.beamDamp = hubTreadOptions.hubTreadBeamDamp or hubTreadOptions.beamDamp
  end

  hubTreadOptions.beamDeform = hubTreadOptions.hubTreadBeamDeform or hubTreadOptions.beamDeform
  hubTreadOptions.beamStrength = hubTreadOptions.hubTreadBeamStrength or hubTreadOptions.beamStrength
  hubTreadOptions.dampCutoffHz = hubTreadOptions.hubTreadBeamDampCutoffHz or hubOptions.dampCutoffHz

  local hubPeripheryOptions = deepcopy(hubOptions)
  if type(hubPeripheryOptions.hubPeripheryBeamSpring) == "number" and hubPeripheryOptions.hubPeripheryBeamSpring < 0 then
    --for narrow wheels, decrease the periphery beam spring
    local hubPeripheryAngleCoef = math.cos(hubTreadAngle * 0.5) * 0.2 + 0.8
    hubPeripheryOptions.beamSpring = 3000000 * wheel.hubNodeWeight * hubPeripheryAngleCoef * hubPeripheryOptions.hubPeripheryBeamSpring * -1
  else
    hubPeripheryOptions.beamSpring = hubPeripheryOptions.hubPeripheryBeamSpring or hubPeripheryOptions.beamSpring
  end
  if type(hubPeripheryOptions.hubPeripheryBeamDamp) == "number" and hubPeripheryOptions.hubPeripheryBeamDamp < 0 then
    hubPeripheryOptions.beamDamp = 0.012 * math.sqrt(wheel.hubNodeWeight * hubPeripheryOptions.beamSpring) * hubPeripheryOptions.hubPeripheryBeamDamp * -1
  else
    hubPeripheryOptions.beamDamp = hubPeripheryOptions.hubPeripheryBeamDamp or hubPeripheryOptions.beamDamp
  end

  hubPeripheryOptions.beamDeform = hubPeripheryOptions.hubPeripheryBeamDeform or hubPeripheryOptions.beamDeform
  hubPeripheryOptions.beamStrength = hubPeripheryOptions.hubPeripheryBeamStrength or hubPeripheryOptions.beamStrength
  hubPeripheryOptions.dampCutoffHz = hubPeripheryOptions.hubPeripheryBeamDampCutoffHz or hubOptions.dampCutoffHz

  local hubStabilizerOptions = deepcopy(hubSideOptions)
  hubStabilizerOptions.beamSpring = hubStabilizerOptions.hubStabilizerBeamSpring or hubStabilizerOptions.beamSpring
  hubStabilizerOptions.beamDamp = hubStabilizerOptions.hubStabilizerBeamDamp or hubStabilizerOptions.beamDamp
  hubStabilizerOptions.beamDeform = hubStabilizerOptions.hubStabilizerBeamDeform or hubStabilizerOptions.beamDeform
  hubStabilizerOptions.beamStrength = hubStabilizerOptions.hubStabilizerBeamStrength or hubStabilizerOptions.beamStrength
  hubStabilizerOptions.dampCutoffHz = hubStabilizerOptions.hubStabilizerBeamDampCutoffHz or hubOptions.dampCutoffHz

  --print(hubSideOptions.beamSpring .. "," .. hubSideOptions.beamDamp)
  --print(hubReinfOptions.beamSpring .. "," .. hubReinfOptions.beamDamp)
  --print(hubTreadOptions.beamSpring .. "," .. hubTreadOptions.beamDamp)
  --print(hubPeripheryOptions.beamSpring .. "," .. hubPeripheryOptions.beamDamp)

  cleanupWheelOptions(hubOptions) -- used for nodes
  cleanupBeamOptions(cleanupWheelOptions(hubSideOptions))
  cleanupBeamOptions(cleanupWheelOptions(hubReinfOptions))
  cleanupBeamOptions(cleanupWheelOptions(hubTreadOptions))
  cleanupBeamOptions(cleanupWheelOptions(hubPeripheryOptions))
  cleanupBeamOptions(cleanupWheelOptions(hubStabilizerOptions))

  if wheel.hubWidth ~= nil then
    local halfWidth = 0.5 * wheel.hubWidth
    node1_pos = midpoint - axis * halfWidth
    node2_pos = midpoint + axis * halfWidth
  end

  rayVec = axis:perpendicularN() * wheel.hubRadius
  rayVec = quatFromAxisAngle(axis, -wheelAngleRad) * rayVec

  for i = 0, wheel.numRays - 1, 1 do
    -- inner
    local rayPoint = node2_pos + rayVec
    rayVec = rayRot * rayVec
    local n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, hubOptions)
    table.insert(hubNodes, vehicle.nodes[n])

    -- outer
    rayPoint = node1_pos + rayVec
    rayVec = rayRot * rayVec
    n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, hubOptions)
    table.insert(hubNodes, vehicle.nodes[n])
  end

-- Hub Cap
  local hubcapOptions = deepcopy(cleanwheel)
  hubcapOptions.beamSpring = hubcapOptions.hubcapBeamSpring or hubcapOptions.beamSpring
  hubcapOptions.beamDamp = hubcapOptions.hubcapBeamDamp or hubcapOptions.beamDamp
  hubcapOptions.beamDeform = hubcapOptions.hubcapBeamDeform or hubcapOptions.beamDeform
  hubcapOptions.beamStrength = hubcapOptions.hubcapBeamStrength or hubcapOptions.beamStrength
  hubcapOptions.nodeWeight = hubcapOptions.hubcapNodeWeight or hubcapOptions.nodeWeight
  hubcapOptions.collision = hubcapOptions.hubcapCollision or hubcapOptions.collision
  hubcapOptions.nodeMaterial = hubcapOptions.hubcapNodeMaterial or hubcapOptions.nodeMaterial
  hubcapOptions.frictionCoef = hubcapOptions.hubcapFrictionCoef or hubcapOptions.frictionCoef
  hubcapOptions.hubcapRadius = hubcapOptions.hubcapRadius or hubcapOptions.hubRadius
  hubcapOptions.group = hubcapOptions.hubcapGroup or hubcapOptions.group
  hubcapOptions.disableMeshBreaking = hubcapOptions.disableHubcapMeshBreaking or hubOptions.disableMeshBreaking
  hubcapOptions.wheelID = nil

  cleanupWheelOptions(hubcapOptions) -- used for nodes

  local hubcapnodebase
  if wheel.enableHubcaps ~= nil and wheel.enableHubcaps == true and wheel.numRays%2 ~= 1 then
    local hubcapOffset
    if wheel.hubcapOffset ~= nil then
      hubcapOffset = wheel.hubcapOffset
      hubcapOffset = axis * hubcapOffset
    end

    hubcapnodebase = vehicle.maxIDs.nodes

    local hubCapNumRays = wheel.numRays/2
    rayVec = axis:perpendicularN() * hubcapOptions.hubcapRadius
    --rayVec = quatFromAxisAngle(axis, - wheelAngleRad + 2 * math.pi / (hubCapNumRays * 4)) * rayVec
    rayRot = quatFromAxisAngle(axis, 2 * math.pi / hubCapNumRays)

    for i = 0, hubCapNumRays -1, 1 do
      local rayPoint = node1_pos + rayVec - hubcapOffset
      rayVec = rayRot * rayVec
      jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, hubcapOptions)
    end

    --hubcapOptions.collision = false
    --hubcapOptions.selfCollision = false
    hubcapOptions.nodeWeight = wheel.hubcapCenterNodeWeight
    --make the center rigidifying node
    local hubcapAxis = node1_pos + axis * wheel.hubcapWidth
    jbeamUtils.addNodeWithOptions(vehicle, hubcapAxis, NORMALTYPE, hubcapOptions)

    --hubcapOptions.collision = nil
    --hubcapOptions.selfCollision = nil
    hubcapOptions.nodeWeight = nil
  end

  local hubcapAttachOptions = deepcopy(cleanwheel)
  hubcapAttachOptions.beamSpring = hubcapAttachOptions.hubcapAttachBeamSpring or hubcapAttachOptions.beamSpring
  hubcapAttachOptions.beamDamp = hubcapAttachOptions.hubcapAttachBeamDamp or hubcapAttachOptions.beamDamp
  hubcapAttachOptions.beamDeform = hubcapAttachOptions.hubcapAttachBeamDeform or hubcapAttachOptions.beamDeform
  hubcapAttachOptions.beamStrength = hubcapAttachOptions.hubcapAttachBeamStrength or hubcapAttachOptions.beamStrength
  hubcapAttachOptions.breakGroup = hubcapAttachOptions.hubcapBreakGroup or hubcapAttachOptions.breakGroup
  hubcapAttachOptions.wheelID = nil
  hubcapAttachOptions.disableMeshBreaking = true

  local hubcapSupportOptions = deepcopy(hubcapAttachOptions)
  hubcapSupportOptions.beamSpring = hubcapSupportOptions.hubcapSupportBeamSpring or hubcapSupportOptions.beamSpring
  hubcapSupportOptions.beamDamp = hubcapSupportOptions.hubcapSupportBeamDamp or hubcapSupportOptions.beamDamp
  hubcapSupportOptions.beamDeform = hubcapSupportOptions.hubcapSupportBeamDeform or hubcapSupportOptions.beamDeform
  hubcapSupportOptions.beamStrength = hubcapSupportOptions.hubcapSupportBeamStrength or hubcapSupportOptions.beamStrength
  hubcapSupportOptions.breakGroup = nil
  hubcapSupportOptions.wheelID = nil
  hubcapSupportOptions.disableMeshBreaking = true

  local sideOptions = deepcopy(cleanwheel)
  sideOptions.beamSpring = sideOptions.wheelSideBeamSpring or 0
  sideOptions.beamDamp = sideOptions.wheelSideBeamDamp or 0
  sideOptions.beamDeform = sideOptions.wheelSideBeamDeform or sideOptions.beamDeform
  sideOptions.beamStrength = sideOptions.wheelSideBeamStrength or sideOptions.beamStrength
  sideOptions.springExpansion = sideOptions.wheelSideBeamSpringExpansion or sideOptions.springExpansion
  sideOptions.dampExpansion = sideOptions.wheelSideBeamDampExpansion or sideOptions.dampExpansion
  sideOptions.transitionZone = sideOptions.wheelSideTransitionZone or sideOptions.transitionZone
  sideOptions.beamPrecompression = sideOptions.wheelSideBeamPrecompression or 1

  local sideReinfOptions = deepcopy(sideOptions)
  sideReinfOptions.beamSpring = sideOptions.wheelSideReinfBeamSpring or 0
  sideReinfOptions.beamDamp = sideOptions.wheelSideReinfBeamDamp or 0
  sideReinfOptions.beamDeform = sideOptions.wheelSideReinfBeamDeform or sideOptions.beamDeform
  sideReinfOptions.beamStrength = sideOptions.wheelSideReinfBeamStrength or sideOptions.beamStrength
  sideReinfOptions.springExpansion = sideOptions.wheelSideReinfBeamSpringExpansion or sideOptions.springExpansion
  sideReinfOptions.dampExpansion = sideOptions.wheelSideReinfBeamDampExpansion or sideOptions.dampExpansion
  sideReinfOptions.transitionZone = sideOptions.wheelSideReinfTransitionZone or sideOptions.transitionZone
  sideReinfOptions.beamPrecompression = sideOptions.wheelSideReinfBeamPrecompression or 1
  sideReinfOptions.disableMeshBreaking = true

  local reinfOptions = deepcopy(cleanwheel)
  reinfOptions.beamSpring = reinfOptions.wheelReinfBeamSpring or 0
  reinfOptions.beamDamp = reinfOptions.wheelReinfBeamDamp or 0
  reinfOptions.springExpansion = reinfOptions.wheelReinfBeamSpringExpansion--stage2 will use beamSpring, beamDamp
  reinfOptions.dampExpansion = reinfOptions.wheelReinfBeamDampExpansion
  reinfOptions.beamDeform = reinfOptions.wheelReinfBeamDeform or reinfOptions.beamDeform
  reinfOptions.beamStrength = reinfOptions.wheelReinfBeamStrength or reinfOptions.beamStrength
  reinfOptions.beamPrecompression = reinfOptions.wheelReinfBeamPrecompression or 1
  reinfOptions.dampCutoffHz = reinfOptions.wheelReinfBeamDampCutoffHz or nil
  reinfOptions.disableMeshBreaking = true

  local treadOptions = deepcopy(cleanwheel)
  treadOptions.beamSpring = treadOptions.wheelTreadBeamSpring or treadOptions.beamSpring
  treadOptions.beamDamp = treadOptions.wheelTreadBeamDamp or treadOptions.beamDamp
  treadOptions.beamDeform = treadOptions.wheelTreadBeamDeform or treadOptions.beamDeform
  treadOptions.beamStrength = treadOptions.wheelTreadBeamStrength or treadOptions.beamStrength
  treadOptions.beamPrecompression = treadOptions.wheelTreadBeamPrecompression or 1
  treadOptions.dampCutoffHz = treadOptions.wheelTreadBeamDampCutoffHz or nil
  treadOptions.disableMeshBreaking = true

  local treadReinfOptions = deepcopy(treadOptions)
  treadReinfOptions.beamSpring = treadOptions.wheelTreadReinfBeamSpring or treadOptions.beamSpring
  treadReinfOptions.beamDamp = treadOptions.wheelTreadReinfBeamDamp or treadOptions.beamDamp
  treadReinfOptions.beamDeform = treadOptions.wheelTreadReinfBeamDeform or treadOptions.beamDeform
  treadReinfOptions.beamStrength = treadOptions.wheelTreadReinfBeamStrength or treadOptions.beamStrength
  treadReinfOptions.beamPrecompression = treadOptions.wheelTreadReinfBeamPrecompression or 1
  treadReinfOptions.dampCutoffHz = treadOptions.wheelTreadReinfBeamDampCutoffHz or nil
  treadReinfOptions.disableMeshBreaking = true

  local peripheryOptions = deepcopy(treadOptions)
  peripheryOptions.beamSpring = peripheryOptions.wheelPeripheryBeamSpring or peripheryOptions.beamSpring
  peripheryOptions.beamDamp = peripheryOptions.wheelPeripheryBeamDamp or peripheryOptions.beamDamp
  peripheryOptions.beamDeform = peripheryOptions.wheelPeripheryBeamDeform or peripheryOptions.beamDeform
  peripheryOptions.beamStrength = peripheryOptions.wheelPeripheryBeamStrength or peripheryOptions.beamStrength
  peripheryOptions.beamPrecompression = peripheryOptions.wheelPeripheryBeamPrecompression or 1
  peripheryOptions.dampCutoffHz = peripheryOptions.wheelPeripheryBeamDampCutoffHz or nil

  local peripheryReinfOptions = deepcopy(peripheryOptions)
  peripheryReinfOptions.beamSpring = peripheryReinfOptions.wheelPeripheryReinfBeamSpring or peripheryOptions.beamSpring
  peripheryReinfOptions.beamDamp = peripheryReinfOptions.wheelPeripheryReinfBeamDamp or peripheryOptions.beamDamp
  peripheryReinfOptions.beamDeform = peripheryReinfOptions.wheelPeripheryReinfBeamDeform or peripheryOptions.beamDeform
  peripheryReinfOptions.beamStrength = peripheryReinfOptions.wheelPeripheryReinfBeamStrength or peripheryOptions.beamStrength
  peripheryReinfOptions.beamPrecompression = peripheryReinfOptions.wheelPeripheryReinfBeamPrecompression or 1
  peripheryReinfOptions.dampCutoffHz = peripheryOptions.wheelPeripheryReinfBeamDampCutoffHz or nil

  local tireSupportOptions = deepcopy(cleanwheel)
  tireSupportOptions.beamSpring = tireSupportOptions.tireSupportBeamSpring or tireSupportOptions.beamSpring
  tireSupportOptions.beamDamp = tireSupportOptions.tireSupportBeamDamp or tireSupportOptions.beamDamp
  tireSupportOptions.beamDeform = tireSupportOptions.tireSupportBeamDeform or tireSupportOptions.beamDeform
  tireSupportOptions.beamStrength = tireSupportOptions.tireSupportBeamStrength or tireSupportOptions.beamStrength
  tireSupportOptions.precompressionRange = (wheel.hubRadius - wheel.radius) * (tireSupportOptions.tireSupportBeamSidewallRatio or 0.9)
  tireSupportOptions.beamLongExtent = tireSupportOptions.tireSupportBeamLongExtent or (wheel.radius - wheel.hubRadius) * 2 * (tireSupportOptions.tireSupportBeamSidewallRatio or 0.9)

  cleanupBeamOptions(cleanupWheelOptions(hubcapAttachOptions))
  cleanupBeamOptions(cleanupWheelOptions(sideOptions))
  cleanupBeamOptions(cleanupWheelOptions(sideReinfOptions))
  cleanupBeamOptions(cleanupWheelOptions(reinfOptions))
  cleanupBeamOptions(cleanupWheelOptions(treadOptions))
  cleanupBeamOptions(cleanupWheelOptions(treadReinfOptions))
  cleanupBeamOptions(cleanupWheelOptions(peripheryOptions))
  cleanupBeamOptions(cleanupWheelOptions(peripheryReinfOptions))

  vehicle.triangles = vehicle.triangles or {}
  local pressureGroupName = '_wheelPressureGroup' .. wheel.wheelID
  local wheelPressure = wheel.pressurePSI or 10
  local wheelDragCoef = wheel.dragCoef or 100
  local wheelSkinDragCoef = wheel.skinDragCoef or 10
  local wheelTreadTriangleType = NORMALTYPE
  local wheelSide1TriangleType = NORMALTYPE
  local wheelSide2TriangleType = NORMALTYPE

  if (wheel.triangleCollision or false) == false then
    wheelTreadTriangleType = NONCOLLIDABLE
    wheelSide1TriangleType = NONCOLLIDABLE
    wheelSide2TriangleType = NONCOLLIDABLE
  end

  if wheel.treadTriangleCollision == false then
    wheelTreadTriangleType = NONCOLLIDABLE
  end

  if wheel.side1TriangleCollision == false then
    wheelSide1TriangleType = NONCOLLIDABLE
  end

  if wheel.side2TriangleCollision == false then
    wheelSide2TriangleType = NONCOLLIDABLE
  end

  local hubTriangleCollision = wheel.hubTriangleCollision == true and true or false
  local hubSide1TriangleCollision = wheel.hubSide1TriangleCollision == true and true or false
  local hubSide2TriangleCollision = wheel.hubSide2TriangleCollision == true and true or false

  local rimBeams = {}
  local sideBeams = {}
  local peripheryBeams = {}
  local treadBeams = {}
  local reinfBeams = {}

  local inaxisnode = wheel.node1
  local outaxisnode = wheel.node2
  local vTris = vehicle.triangles

  for i = 0, wheel.numRays - 1 do
    local i2 = 2*i
    local nextdelta = 2*((i+1)%wheel.numRays)
    local outhubnode = hubnodebase + i2
    local inhubnode = outhubnode + 1
    local nextouthubnode = hubnodebase + nextdelta
    local nextinhubnode = nextouthubnode + 1
    local previntirenode = nodebase + 2 *((i + wheel.numRays - 1)%wheel.numRays)
    local intirenode = nodebase + i2
    local prevouttirenode = previntirenode + 1
    local outtirenode = intirenode + 1
    local nextintirenode = nodebase + nextdelta
    local nextouttirenode = nextintirenode + 1
    local nextnextintirenode = nodebase + 2*((i+2)%wheel.numRays)
    local nextnextouttirenode = nextnextintirenode + 1
    -- Hub caps
    if wheel.enableHubcaps and wheel.numRays%2 ~= 1 and i < ((wheel.numRays)/2) then
      local hubcapnode = hubcapnodebase + i
      local nexthubcapnode = hubcapnodebase + ((i+1)%(wheel.numRays/2))
      local nextnexthubcapnode = hubcapnodebase + ((i+2)%(wheel.numRays/2))
      local hubcapaxisnode = hubcapnode + (wheel.numRays/2) - i
      local hubcapinhubnode = inhubnode + i2
      local prevhubcaphubnode = hubnodebase + 2 *((i2 + wheel.numRays - 1)%wheel.numRays)+1
      local nexthubcapinhubnode = hubcapinhubnode + 2
      local hubcapouthubnode = hubcapinhubnode - 1

      --hubcap periphery
      jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, nexthubcapnode,    NORMALTYPE, hubcapOptions)
      --attach to center node
      jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, hubcapaxisnode,    NORMALTYPE, hubcapOptions)
      --attach to axis
      if wheel.enableExtraHubcapBeams == true then
        --jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, wheel.node1, NORMALTYPE, hubcapAttachOptions)
        --jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, wheel.node2, NORMALTYPE, hubcapAttachOptions)
        if i == 1 then
          jbeamUtils.addBeamWithOptions(vehicle, hubcapaxisnode, wheel.node1, NORMALTYPE, hubcapAttachOptions)
          jbeamUtils.addBeamWithOptions(vehicle, hubcapaxisnode, wheel.node2, NORMALTYPE, hubcapAttachOptions)
        end
      end

      --span beams
      jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, nextnexthubcapnode,    NORMALTYPE, hubcapOptions)

      --attach it
      jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, hubcapinhubnode,   NORMALTYPE,   hubcapAttachOptions)
      jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, prevhubcaphubnode, NORMALTYPE,   hubcapAttachOptions)
      jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, hubcapouthubnode,  NORMALTYPE,   hubcapAttachOptions)
      jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, hubcapouthubnode,  BEAM_SUPPORT, hubcapSupportOptions)

      --self:jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, wheel.node1,    NORMALTYPE, hubcapAttachOptions)
      --self:jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, wheel.node2,    NORMALTYPE, hubcapAttachOptions)
    end

    --hub tread
    jbeamUtils.addBeamWithOptions(vehicle, outhubnode, inhubnode,      NORMALTYPE, hubTreadOptions)
    jbeamUtils.addBeamWithOptions(vehicle, inhubnode,  nextouthubnode, NORMALTYPE, hubTreadOptions)

    --hub periphery beams
    jbeamUtils.addBeamWithOptions(vehicle, outhubnode, nextouthubnode, NORMALTYPE, hubPeripheryOptions)
    jbeamUtils.addBeamWithOptions(vehicle, inhubnode,  nextinhubnode,  NORMALTYPE, hubPeripheryOptions)

    --hub axis beams
    table.insert(rimBeams, jbeamUtils.addBeamWithOptions(vehicle, outhubnode, inaxisnode, NORMALTYPE, hubReinfOptions))
    table.insert(rimBeams, jbeamUtils.addBeamWithOptions(vehicle, outhubnode, outaxisnode, NORMALTYPE, hubSideOptions))
    table.insert(rimBeams, jbeamUtils.addBeamWithOptions(vehicle, inhubnode,  inaxisnode, NORMALTYPE, hubSideOptions))
    table.insert(rimBeams, jbeamUtils.addBeamWithOptions(vehicle, inhubnode,  outaxisnode, NORMALTYPE, hubReinfOptions))

    --Beams to stability node
    if nodeStabilizerExists then
      jbeamUtils.addBeamWithOptions(vehicle, outhubnode,  wheel.nodeStabilizer, NORMALTYPE, hubStabilizerOptions)
    end

    if hubSide1TriangleCollision then
      addTri(vTris, nextouthubnode, outhubnode, outaxisnode, 0, NORMALTYPE)
    end

    if hubSide2TriangleCollision then
      addTri(vTris, inhubnode, nextinhubnode, inaxisnode, 0, NORMALTYPE)
    end

    if tireExists then
      --tire tread
      table.insert( treadBeams,
        jbeamUtils.addBeamWithOptions(vehicle, intirenode,  outtirenode,    NORMALTYPE, treadOptions) )
      table.insert( treadBeams,
        jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nextintirenode, NORMALTYPE, treadOptions) )

      --tread reinforcement
      if wheel.enableTreadReinfBeams then
        table.insert( treadBeams,
          jbeamUtils.addBeamWithOptions(vehicle, intirenode, nextouttirenode, NORMALTYPE, treadReinfOptions) )
        table.insert( treadBeams,
          jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nextnextintirenode, NORMALTYPE, treadReinfOptions) )
      end

      -- paired treadnodes
      vehicle.nodes[intirenode].pairedNode = outtirenode
      vehicle.nodes[intirenode].pairedNode2 = prevouttirenode
      vehicle.nodes[outtirenode].pairedNode = nextintirenode
      vehicle.nodes[outtirenode].pairedNode2 = intirenode

      -- Periphery beams
      table.insert(peripheryBeams,
        jbeamUtils.addBeamWithOptions(vehicle, intirenode,  nextintirenode,  NORMALTYPE, peripheryOptions) )
      table.insert(peripheryBeams,
        jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nextouttirenode, NORMALTYPE, peripheryOptions) )

      --hub tire beams
      table.insert( sideBeams,
        jbeamUtils.addBeamWithOptions(vehicle, outhubnode,  outtirenode,    BEAM_ANISOTROPIC, sideOptions) )
      table.insert( sideBeams,
        jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nextouthubnode, BEAM_ANISOTROPIC, sideOptions) )
      table.insert( sideBeams,
        jbeamUtils.addBeamWithOptions(vehicle, inhubnode,   intirenode,     BEAM_ANISOTROPIC, sideOptions) )
      table.insert( sideBeams,
        jbeamUtils.addBeamWithOptions(vehicle, inhubnode,   nextintirenode, BEAM_ANISOTROPIC, sideOptions) )

      --reinf beams
      if wheel.enableTireReinfBeams then
        table.insert( reinfBeams,
          jbeamUtils.addBeamWithOptions(vehicle, intirenode,  outhubnode,     NORMALTYPE, reinfOptions) )
        table.insert( reinfBeams,
          jbeamUtils.addBeamWithOptions(vehicle, inhubnode,   outtirenode,    NORMALTYPE, reinfOptions) )
      elseif wheel.enableTireLbeams then
          table.insert( reinfBeams,
            jbeamUtils.addBeamWithOptions(vehicle, intirenode,  outhubnode,     BEAM_LBEAM, reinfOptions, inhubnode ))
          table.insert( reinfBeams,
            jbeamUtils.addBeamWithOptions(vehicle, inhubnode,   outtirenode,    BEAM_LBEAM, reinfOptions, outhubnode ))
      end

      --side reinf beams
      if wheel.enableTireSideReinfBeams then
        table.insert( sideBeams,
          jbeamUtils.addBeamWithOptions(vehicle, outhubnode, nextouttirenode, BEAM_ANISOTROPIC, sideReinfOptions) )
        table.insert( sideBeams,
          jbeamUtils.addBeamWithOptions(vehicle, outtirenode, hubnodebase + 2*((i+2)%wheel.numRays), BEAM_ANISOTROPIC, sideReinfOptions) )
        table.insert( sideBeams,
          jbeamUtils.addBeamWithOptions(vehicle, intirenode, nextinhubnode, BEAM_ANISOTROPIC, sideReinfOptions) )
        table.insert( sideBeams,
          jbeamUtils.addBeamWithOptions(vehicle, inhubnode, nodebase + 2*((i+2)%wheel.numRays), BEAM_ANISOTROPIC, sideReinfOptions) )
      end

      if wheel.enableTirePeripheryReinfBeams then
      -- Periphery beams
        table.insert(peripheryBeams,
          jbeamUtils.addBeamWithOptions(vehicle, intirenode, nextnextintirenode,  NORMALTYPE, peripheryReinfOptions) )
        table.insert(peripheryBeams,
          jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nextnextouttirenode, NORMALTYPE, peripheryReinfOptions) )
      end

      if wheel.enableTireSupportBeams then
        jbeamUtils.addBeamWithOptions(vehicle, inaxisnode, intirenode, BEAM_SUPPORT, tireSupportOptions)
        jbeamUtils.addBeamWithOptions(vehicle, outaxisnode, outtirenode, BEAM_SUPPORT, tireSupportOptions)
      end

      -- hub pressure tris
      addPressTri(vTris, pressureGroupName, wheelPressure, inhubnode, nextouthubnode, outhubnode, wheelDragCoef * 0.1, NONCOLLIDABLE)
      addPressTri(vTris, pressureGroupName, wheelPressure, inhubnode, nextinhubnode, nextouthubnode, wheelDragCoef * 0.1, NONCOLLIDABLE)

      -- tread pressure tris
      addPressTri(vTris, pressureGroupName, wheelPressure, intirenode, outtirenode, nextintirenode, wheelDragCoef * 0.2, wheelTreadTriangleType, wheelSkinDragCoef)
      addPressTri(vTris, pressureGroupName, wheelPressure, nextintirenode, outtirenode, nextouttirenode, wheelDragCoef * 0.2, wheelTreadTriangleType, wheelSkinDragCoef)

      -- outside pressure tris
      addPressTri(vTris, pressureGroupName, wheelPressure, outtirenode, outhubnode, nextouthubnode, wheelDragCoef * 0.5, wheelSide1TriangleType)
      addPressTri(vTris, pressureGroupName, wheelPressure, outtirenode, nextouthubnode, nextouttirenode, wheelDragCoef * 0.5, wheelSide1TriangleType)

      -- inside pressure tris
      addPressTri(vTris, pressureGroupName, wheelPressure, inhubnode, intirenode, nextintirenode, wheelDragCoef * 0.5, wheelSide2TriangleType)
      addPressTri(vTris, pressureGroupName, wheelPressure, nextinhubnode, inhubnode, nextintirenode, wheelDragCoef * 0.5, wheelSide2TriangleType)
    else
      if hubTriangleCollision then
        -- hub tris
        addTri(vTris, nextouthubnode, inhubnode, outhubnode, wheelDragCoef * 0.1, NORMALTYPE)
        addTri(vTris, nextinhubnode, inhubnode, nextouthubnode, wheelDragCoef * 0.1, NORMALTYPE)
      end
    end
  end

  wheel.nodes = hubNodes
  wheel.treadNodes = treadNodes
  wheel.rimBeams = rimBeams
  wheel.sideBeams = sideBeams
  wheel.peripheryBeams = peripheryBeams
  wheel.reinfBeams = reinfBeams
  wheel.treadBeams = treadBeams
  wheel.pressureGroup = pressureGroupName
end

M.process = addPressureWheel

return M
