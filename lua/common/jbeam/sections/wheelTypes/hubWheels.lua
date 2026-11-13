--[[
This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
If a copy of the bCDDL was not distributed with this
file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
]]

-- wheel type expander for the jbeam 'hubWheels' section
-- the file name must match the jbeam section name, that is how the dispatcher finds it

local M = {}

local jbeamUtils = require("jbeam/utils")

-- these are defined in C, do not change the values
local NORMALTYPE = 0
local BEAM_ANISOTROPIC = 1
local BEAM_PRESSURED = 3
local BEAM_SUPPORT = 7

local function addHubWheel(vehicle, wheelKey, wheel)
  local node1   = vehicle.nodes[wheel.node1]
  local node2   = vehicle.nodes[wheel.node2]
  local nodeArm = vehicle.nodes[wheel.nodeArm]
  if node1 == nil or node2 == nil then
    log('W', "jbeam.addHubWheel","invalid hubWheel")
    return
  end

  local nodebase = vehicle.maxIDs.nodes
  wheel.treadCoef = wheel.treadCoef or 1

  if wheel.radius == nil then    wheel.radius = 0.5 end
  if wheel.hubRadius == nil then wheel.hubRadius = 0.65 * wheel.radius end
  if wheel.numRays == nil then wheel.numRays = 10    end

  -- add collision to the wheels nodes ;)
  wheel.collision = true

  -- fix it like this
  local node1_pos = vec3(node1.pos)
  local node2_pos = vec3(node2.pos)

  --log('D', "jbeam.addHubWheel","n1 = " .. tostring(node1_pos) .. " , n2 = " .. tostring(node2_pos))

  local tireWidth = node1_pos:distance(node2_pos)
  local hubWidth = tireWidth
  --log('D', "jbeam.addHubWheel","hubWheel width: "..width)

  -- swap nodes?
  if node1_pos.z > node2_pos.z then
    --log('D', "jbeam.addHubWheel","swapping hubWheel nodes ...")
    node1, node2 = node2, node1
  end

  -- calculate axis
  local axis = node2_pos - node1_pos
  local axisLength = axis:length()
  axis:normalize()

  local midpoint = (node2_pos + node1_pos) * 0.5
  if wheel.wheelOffset ~= nil then
    local offset = wheel.wheelOffset
    midpoint = midpoint + axis * offset
  end

  if wheel.tireWidth ~= nil then
    tireWidth = wheel.tireWidth
    local halfWidth = 0.5 * wheel.tireWidth
    node1_pos = midpoint - axis * halfWidth
    node2_pos = midpoint + axis * halfWidth
  end

  --log('D', "jbeam.addHubWheel","wheel axis:" .. tostring(axis))

  local rayVec = axis:perpendicularN() * wheel.radius
  --log('D', "jbeam.addHubWheel","rayVector: " .. tostring(rayVec))

  local rayRot = quatFromAxisAngle(axis, 2 * math.pi / (wheel.numRays* 2))
  --log('D', "jbeam.addHubWheel","rayRot: " .. tostring(rayRot))

  -- add tire nodes first
  local n = 0
  local rayPoint
  for i = 0, wheel.numRays - 1, 1 do
    -- outer
    rayPoint = node1_pos + rayVec
    rayVec = rayRot * rayVec
    n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, wheel)

    -- inner
    rayPoint = node2_pos + rayVec
    rayVec = rayRot * rayVec
    n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, wheel)
  end

  -- add Hub nodes
  local hubNodes = {}
  local hubnodebase = vehicle.maxIDs.nodes

  local hubOptions = deepcopy(wheel)
  hubOptions.beamSpring = hubOptions.hubBeamSpring or hubOptions.beamSpring
  hubOptions.beamDamp = hubOptions.hubBeamDamp or hubOptions.beamDamp
  hubOptions.beamDeform = hubOptions.hubBeamDeform or hubOptions.beamDeform
  hubOptions.beamStrength = hubOptions.hubBeamStrength or hubOptions.beamStrength
  hubOptions.nodeWeight = hubOptions.hubNodeWeight or hubOptions.nodeWeight
  hubOptions.collision = hubOptions.hubCollision or hubOptions.collision
  hubOptions.nodeMaterial = hubOptions.hubNodeMaterial or hubOptions.nodeMaterial
  hubOptions.frictionCoef = hubOptions.hubFrictionCoef or hubOptions.frictionCoef

  rayVec = axis:perpendicularN() * wheel.hubRadius

  if wheel.hubWidth ~= nil then
    hubWidth = wheel.hubWidth
    local halfWidth = 0.5 * wheel.hubWidth
    node1_pos = midpoint - axis * halfWidth
    node2_pos = midpoint + axis * halfWidth
  end

  for i = 0, wheel.numRays - 1, 1 do
    -- outer
    rayPoint = node1_pos + rayVec
    rayVec = rayRot * rayVec
    local n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, hubOptions)
    table.insert(hubNodes, vehicle.nodes[n])

    -- inner
    rayPoint = node2_pos + rayVec
    rayVec = rayRot * rayVec
    n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, hubOptions)
    table.insert(hubNodes, vehicle.nodes[n])
  end

  -- Hub Cap
  local hubcapOptions = deepcopy(wheel)
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
  hubcapOptions.wheelID = nil

  local hubcapnodebase
  if wheel.enableHubcaps ~= nil and wheel.enableHubcaps == true and wheel.numRays%2 ~= 1 then
    local hubcapOffset
    if wheel.hubcapOffset ~= nil then
      hubcapOffset = wheel.hubcapOffset
      hubcapOffset = axis * hubcapOffset
    end

    local n = 0
    hubcapnodebase = vehicle.maxIDs.nodes

    local hubCapNumRays = wheel.numRays/2
    rayVec = axis:perpendicularN() * hubcapOptions.hubcapRadius

    local tmpRot = quatFromAxisAngle(axis, 2 * math.pi / (hubCapNumRays * 4))

    rayVec = tmpRot * rayVec
    -- all hub node rotation
    rayRot = quatFromAxisAngle(axis, 2 * math.pi / (hubCapNumRays))

    for i = 0, hubCapNumRays -1, 1 do
      local rayPoint = node1_pos + rayVec - hubcapOffset
      rayVec = rayRot * rayVec
      n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, hubcapOptions)
    end

    --hubcapOptions.collision = false
    --hubcapOptions.selfCollision = false
    hubcapOptions.nodeWeight = wheel.hubcapCenterNodeWeight
    --make the center rigidifying node
    local hubcapAxis = node1_pos + axis * wheel.hubcapWidth
    n = jbeamUtils.addNodeWithOptions(vehicle, hubcapAxis, NORMALTYPE, hubcapOptions)

    --hubcapOptions.collision = nil
    --hubcapOptions.selfCollision = nil
    hubcapOptions.nodeWeight = nil
  end

  local hubcapAttachOptions = deepcopy(wheel)
  hubcapAttachOptions.beamSpring = hubcapAttachOptions.hubcapAttachBeamSpring or hubcapAttachOptions.beamSpring
  hubcapAttachOptions.beamDamp = hubcapAttachOptions.hubcapAttachBeamDamp or hubcapAttachOptions.beamDamp
  hubcapAttachOptions.beamDeform = hubcapAttachOptions.hubcapAttachBeamDeform or hubcapAttachOptions.beamDeform
  hubcapAttachOptions.beamStrength = hubcapAttachOptions.hubcapAttachBeamStrength or hubcapAttachOptions.beamStrength
  hubcapAttachOptions.breakGroup = hubcapAttachOptions.hubcapBreakGroup or hubcapAttachOptions.breakGroup
  hubcapAttachOptions.wheelID = nil

  -- hub-tire beams options
  local treadOptions = deepcopy(wheel)
  treadOptions.beamSpring      = treadOptions.wheelTreadBeamSpring or treadOptions.beamSpring
  treadOptions.beamDamp        = treadOptions.wheelTreadBeamDamp or treadOptions.beamDamp
  treadOptions.beamDeform      = treadOptions.wheelTreadBeamDeform or treadOptions.beamDeform
  treadOptions.beamStrength    = treadOptions.wheelTreadBeamStrength or treadOptions.beamStrength
  treadOptions.springExpansion = treadOptions.wheelTreadBeamSpringExpansion or treadOptions.springExpansion
  treadOptions.dampExpansion   = treadOptions.wheelTreadBeamDampExpansion or treadOptions.dampExpansion

  local enableTreadReinforcementBeams = false
  if wheel.enableTreadReinforcementBeams ~= nil and wheel.enableTreadReinforcementBeams == true then
    enableTreadReinforcementBeams = true
  end

  local treadReinfOptions           = deepcopy(treadOptions)
  treadReinfOptions.beamSpring      = treadReinfOptions.wheelTreadReinforcementBeamSpring or treadReinfOptions.beamSpring
  treadReinfOptions.beamDamp        = treadReinfOptions.wheelTreadReinforcementBeamDamp or treadReinfOptions.beamDamp
  treadReinfOptions.beamDeform      = treadReinfOptions.wheelTreadReinforcementBeamDeform or treadReinfOptions.beamDeform
  treadReinfOptions.beamStrength    = treadReinfOptions.wheelTreadReinforcementBeamStrength or treadReinfOptions.beamStrength

  local peripheryOptions     = deepcopy(treadOptions)
  peripheryOptions.beamSpring = peripheryOptions.wheelPeripheryBeamSpring or peripheryOptions.beamSpring
  peripheryOptions.beamDamp = peripheryOptions.wheelPeripheryBeamDamp or peripheryOptions.beamDamp
  peripheryOptions.beamDeform = peripheryOptions.wheelPeripheryBeamDeform or peripheryOptions.beamDeform
  peripheryOptions.beamStrength = peripheryOptions.wheelPeripheryBeamStrength or peripheryOptions.beamStrength

  local supportOptions = deepcopy(hubOptions)
  supportOptions.beamPrecompression = (0.75 * wheel.hubRadius / wheel.radius) + 0.25

  -- Pressured Beam options
  local sideBeamLength =     wheel.radius - wheel.hubRadius
  local reinfBeamLength = math.sqrt(sideBeamLength * sideBeamLength + axisLength * axisLength)
  local pressuredOptions = deepcopy(wheel)
  pressuredOptions.pressurePSI = pressuredOptions.pressurePSI or 30
  pressuredOptions.beamSpring = pressuredOptions.pressureSpring or pressuredOptions.springExpansion
  pressuredOptions.beamDamp = pressuredOptions.pressureDamp or pressuredOptions.dampExpansion
  pressuredOptions.beamStrength = pressuredOptions.pressureStrength or pressuredOptions.beamStrength
  pressuredOptions.beamDeform = pressuredOptions.pressureDeform or pressuredOptions.beamDeform
  pressuredOptions.volumeCoef = 1 --2 * sideBeamLength / (wheel.numRays * sideBeamLength) --sideBeamLength / (wheel.numRays * (2 * sideBeamLength + 4 * reinfBeamLength))
  pressuredOptions.surface = math.pi * (wheel.radius * tireWidth + wheel.hubRadius * hubWidth) / (wheel.numRays*2)

  local reinfPressureOptions = deepcopy(pressuredOptions)
  reinfPressureOptions.pressurePSI = reinfPressureOptions.reinforcementPressurePSI or reinfPressureOptions.pressurePSI
  reinfPressureOptions.beamSpring = reinfPressureOptions.reinforcementPressureSpring or reinfPressureOptions.pressureSpring
  reinfPressureOptions.beamDamp = reinfPressureOptions.reinforcementPressureDamp or reinfPressureOptions.pressureDamp
  reinfPressureOptions.beamStrength = reinfPressureOptions.reinforcementPressureStrength or reinfPressureOptions.pressureStrength
  reinfPressureOptions.beamDeform = reinfPressureOptions.reinforcementPressureDeform or reinfPressureOptions.pressureDeform
  reinfPressureOptions.volumeCoef = 1 --reinfBeamLength / (wheel.numRays * (2 * sideBeamLength + 4 * reinfBeamLength))
  reinfPressureOptions.surface = math.pi * (wheel.radius*wheel.radius - wheel.hubRadius*wheel.hubRadius) / (wheel.numRays*4)

  local sideOptions = deepcopy(wheel)
  sideOptions.beamSpring   = sideOptions.wheelSideBeamSpring or 0
  sideOptions.beamDamp     = sideOptions.wheelSideBeamDamp or 0
  sideOptions.beamDeform   = sideOptions.wheelSideBeamDeform or sideOptions.beamDeform
  sideOptions.beamStrength = sideOptions.wheelSideBeamStrength or sideOptions.beamStrength
  sideOptions.springExpansion = sideOptions.wheelSideBeamSpringExpansion or sideOptions.springExpansion
  sideOptions.dampExpansion   = sideOptions.wheelSideBeamDampExpansion or sideOptions.dampExpansion

  local VDisplacement = wheel.wheelSideDisplacement or 1

  local enableVbeams = false
  if wheel.enableTireSideVBeams ~= nil and wheel.enableTireSideVBeams == true then
    enableVbeams = true
  end

  local pressuredBeams = {}
  local treadBeams = {}
  local b = 0
  for i = 0, wheel.numRays - 1, 1 do
    local i2 = 2*i
    local nextdelta = 2*((i+1)%wheel.numRays)
    local inhubnode = hubnodebase + i2
    local outhubnode = inhubnode + 1
    local nextinhubnode = hubnodebase + nextdelta
    local nextouthubnode = nextinhubnode + 1
    local intirenode = nodebase + i2
    local outtirenode = intirenode + 1
    local nextintirenode = nodebase + nextdelta
    local nextouttirenode = nextintirenode + 1

    if wheel.enableHubcaps ~= nil and wheel.enableHubcaps == true and wheel.numRays%2 ~= 1 and i < ((wheel.numRays)/2) then
      local hubcapnode = hubcapnodebase + i
      local nexthubcapnode = hubcapnodebase + ((i+1)%(wheel.numRays/2))
      local nextnexthubcapnode = hubcapnodebase + ((i+2)%(wheel.numRays/2))
      local hubcapaxisnode = hubcapnode + (wheel.numRays/2) - i
      local hubcapinhubnode = inhubnode + i2
      local nexthubcapinhubnode = hubcapinhubnode + 2
      local hubcapouthubnode = hubcapinhubnode + 1

      --hubcap periphery
      b = jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, nexthubcapnode,    NORMALTYPE, hubcapOptions)
      --attach to center node
      b = jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, hubcapaxisnode,    NORMALTYPE, hubcapOptions)
      --attach to axis
      if wheel.enableExtraHubcapBeams == true then
        jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, wheel.node1, NORMALTYPE, hubcapOptions)
        jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, wheel.node2, NORMALTYPE, hubcapOptions)
        if i == 1 then
          jbeamUtils.addBeamWithOptions(vehicle, hubcapaxisnode, wheel.node1, NORMALTYPE, hubcapOptions)
          jbeamUtils.addBeamWithOptions(vehicle, hubcapaxisnode, wheel.node2, NORMALTYPE, hubcapOptions)
        end
      end

      --span beams
      b = jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, nextnexthubcapnode,    NORMALTYPE, hubcapOptions)

      --attach it
      b = jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, hubcapinhubnode,    NORMALTYPE, hubcapAttachOptions)
      b = jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, nexthubcapinhubnode,    NORMALTYPE, hubcapAttachOptions)
      b = jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, hubcapouthubnode,    BEAM_SUPPORT, hubcapAttachOptions)

      --self:jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, wheel.node1,    NORMALTYPE, hubcapAttachOptions)
      --self:jbeamUtils.addBeamWithOptions(vehicle, hubcapnode, wheel.node2,    NORMALTYPE, hubcapAttachOptions)
    end

    --tire tread
    table.insert( treadBeams,
      jbeamUtils.addBeamWithOptions(vehicle, intirenode,  outtirenode,    BEAM_ANISOTROPIC, treadOptions) )
    table.insert( treadBeams,
      jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nextintirenode, BEAM_ANISOTROPIC, treadOptions) )

    -- paired treadnodes
    vehicle.nodes[intirenode].pairedNode = outtirenode
    vehicle.nodes[outtirenode].pairedNode = nextintirenode

    -- Periphery beams
    b = jbeamUtils.addBeamWithOptions(vehicle, intirenode,  nextintirenode,  NORMALTYPE, peripheryOptions)
    b = jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nextouttirenode, NORMALTYPE, peripheryOptions)

    --hub tread
    b = jbeamUtils.addBeamWithOptions(vehicle, inhubnode,  outhubnode,      NORMALTYPE, hubOptions)
    b = jbeamUtils.addBeamWithOptions(vehicle, outhubnode, nextinhubnode, NORMALTYPE, hubOptions)

    --hub periphery beams
    b = jbeamUtils.addBeamWithOptions(vehicle, outhubnode, nextouthubnode, NORMALTYPE, hubOptions)
    b = jbeamUtils.addBeamWithOptions(vehicle, inhubnode,  nextinhubnode,  NORMALTYPE, hubOptions)

    --hub axis beams
    b = jbeamUtils.addBeamWithOptions(vehicle, inhubnode,  wheel.node1, NORMALTYPE, hubOptions)
    b = jbeamUtils.addBeamWithOptions(vehicle, inhubnode,  wheel.node2, NORMALTYPE, hubOptions)
    b = jbeamUtils.addBeamWithOptions(vehicle, outhubnode, wheel.node1, NORMALTYPE, hubOptions)
    b = jbeamUtils.addBeamWithOptions(vehicle, outhubnode, wheel.node2, NORMALTYPE, hubOptions)

    --hub tire beams
    table.insert( pressuredBeams,
      jbeamUtils.addBeamWithOptions(vehicle, inhubnode,   intirenode,     BEAM_PRESSURED, pressuredOptions) )
    table.insert( pressuredBeams,
      jbeamUtils.addBeamWithOptions(vehicle, outhubnode,  outtirenode,    BEAM_PRESSURED, pressuredOptions) )
    table.insert( pressuredBeams,
      jbeamUtils.addBeamWithOptions(vehicle, intirenode,  outhubnode,     BEAM_PRESSURED, reinfPressureOptions)    )
    table.insert( pressuredBeams,
      jbeamUtils.addBeamWithOptions(vehicle, inhubnode,   outtirenode,    BEAM_PRESSURED, reinfPressureOptions) )
    table.insert( pressuredBeams,
      jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nextinhubnode,  BEAM_PRESSURED, reinfPressureOptions) )
    table.insert( pressuredBeams,
      jbeamUtils.addBeamWithOptions(vehicle, outhubnode,  nextintirenode, BEAM_PRESSURED, reinfPressureOptions) )

    --tire side V beams
    if enableVbeams then
      local inhubDnode = hubnodebase + 2*((i+1-VDisplacement)%wheel.numRays)
      local outhubDnode = inhubDnode + 1
      local nextinhubDnode = hubnodebase + 2*((i+VDisplacement)%wheel.numRays)
      local nextouthubDnode = nextinhubDnode + 1
      b = jbeamUtils.addBeamWithOptions(vehicle, outtirenode,  nextouthubDnode,  BEAM_ANISOTROPIC, sideOptions)
      b = jbeamUtils.addBeamWithOptions(vehicle, outhubDnode,   nextouttirenode, BEAM_ANISOTROPIC, sideOptions)
      b = jbeamUtils.addBeamWithOptions(vehicle, nextintirenode, inhubDnode,  BEAM_ANISOTROPIC, sideOptions)
      b = jbeamUtils.addBeamWithOptions(vehicle, nextinhubDnode,  intirenode, BEAM_ANISOTROPIC, sideOptions)
    end

    if enableTreadReinforcementBeams then
      local intirenode2 = nodebase + 2*((i+2)%wheel.numRays)
      local outtirenode2 = intirenode2 + 1
      table.insert( treadBeams,
        jbeamUtils.addBeamWithOptions(vehicle, intirenode,  outtirenode2, NORMALTYPE, treadReinfOptions) )
      table.insert( treadBeams,
        jbeamUtils.addBeamWithOptions(vehicle, outtirenode, intirenode2, NORMALTYPE, treadReinfOptions) )
    end

    -- Support beams
    if wheel.enableTireSideSupportBeams then
      jbeamUtils.addBeamWithOptions(vehicle, wheel.node1, intirenode,  BEAM_SUPPORT, supportOptions)
      jbeamUtils.addBeamWithOptions(vehicle, wheel.node2, outtirenode, BEAM_SUPPORT, supportOptions)
    end
  end

  wheel.nodes = hubNodes
  wheel.pressuredBeams = pressuredBeams
end

M.process = addHubWheel

return M
