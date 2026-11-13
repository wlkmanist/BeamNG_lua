--[[
This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
If a copy of the bCDDL was not distributed with this
file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
]]

-- wheel type expander for the jbeam 'hubWheelsTSV' section
-- the file name must match the jbeam section name, that is how the dispatcher finds it

local M = {}

local jbeamUtils = require("jbeam/utils")

-- these are defined in C, do not change the values
local NORMALTYPE = 0
local BEAM_ANISOTROPIC = 1
local BEAM_SUPPORT = 7

local function addHubWheelTSV(vehicle, wheelKey, wheel)
  local node1   = vehicle.nodes[wheel.node1]
  local node2   = vehicle.nodes[wheel.node2]
  local nodeArm = vehicle.nodes[wheel.nodeArm]

  if node1 == nil or node2 == nil then
    log('W', "jbeam.addHubWheelTSV","invalid hubWheel")
    return
  end

  local nodebase = vehicle.maxIDs.nodes
  wheel.treadCoef = wheel.treadCoef or 1
  if wheel.radius == nil then    wheel.radius = 0.5 end
  if wheel.hubRadius == nil then wheel.hubRadius = 0.65 * wheel.radius end
  if wheel.numRays == nil then wheel.numRays = 10 end

  -- add collision to the wheels nodes ;)
  wheel.collision = true

  -- fix it like this
  local node1_pos = vec3(node1.pos)
  local node2_pos = vec3(node2.pos)

  local width = node1_pos:distance(node2_pos)

  -- swap nodes?
  if node1_pos.z > node2_pos.z then
    --log('D', "jbeam.addHubWheelTSV","swapping hubWheel nodes ...")
    node1, node2 = node2, node1
  end

  -- calculate axis
  local axis = node2_pos - node1_pos
  axis:normalize()

  local midpoint = (node2_pos + node1_pos) * 0.5
  if wheel.wheelOffset ~= nil then
    local offset = wheel.wheelOffset
    midpoint = midpoint + axis * offset
  end

  if wheel.tireWidth ~= nil then
    local halfWidth = 0.5 * wheel.tireWidth
    node1_pos = midpoint - axis * halfWidth
    node2_pos = midpoint + axis * halfWidth
  end

  local rayVec = axis:perpendicularN() * wheel.radius
  local rayRot = quatFromAxisAngle(axis, 2 * math.pi / (wheel.numRays* 2))

  -- add nodes first
  local n = 0
  for i = 0, wheel.numRays - 1, 1 do
    -- outer
    local rayPoint = node1_pos + rayVec
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
  if hubOptions.hubBeamSpring ~= nil then hubOptions.beamSpring = hubOptions.hubBeamSpring end
  if hubOptions.hubBeamDamp ~= nil then hubOptions.beamDamp = hubOptions.hubBeamDamp end
  if hubOptions.hubBeamDeform ~= nil then hubOptions.beamDeform = hubOptions.hubBeamDeform end
  if hubOptions.hubBeamStrength ~=nil then hubOptions.beamStrength = hubOptions.hubBeamStrength end
  if hubOptions.hubNodeWeight ~= nil then hubOptions.nodeWeight = hubOptions.hubNodeWeight end
  if hubOptions.hubCollision ~= nil then hubOptions.collision = hubOptions.hubCollision end
  if hubOptions.hubNodeMaterial ~= nil then hubOptions.nodeMaterial = hubOptions.hubNodeMaterial end
  if hubOptions.hubFrictionCoef ~= nil then hubOptions.frictionCoef = hubOptions.hubFrictionCoef end

  rayVec = axis:perpendicularN() * wheel.hubRadius

  if wheel.hubWidth ~= nil then
    local halfWidth = 0.5 * wheel.hubWidth
    node1_pos = midpoint - axis * halfWidth
    node2_pos = midpoint + axis * halfWidth
  end

  local n = 0
  for i = 0, wheel.numRays - 1, 1 do
    -- inner
    rayPoint = node2_pos + rayVec
    rayVec = rayRot * rayVec
    n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, hubOptions)
    table.insert(hubNodes, vehicle.nodes[n])

    -- outer
    local rayPoint = node1_pos + rayVec
    rayVec = rayRot * rayVec
    n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, hubOptions)
    table.insert(hubNodes, vehicle.nodes[n])
  end

  local sideOptions = deepcopy(wheel)
  sideOptions.beamSpring   = sideOptions.wheelSideBeamSpring
  sideOptions.beamDamp     = sideOptions.wheelSideBeamDamp
  sideOptions.beamDeform   = sideOptions.wheelSideBeamDeform
  sideOptions.beamStrength = sideOptions.wheelSideBeamStrength

  -- hub-tire beams options
  local reinforcementOptions = deepcopy(wheel)
  reinforcementOptions.beamSpring   = reinforcementOptions.wheelReinforcementBeamSpring
  reinforcementOptions.beamDamp     = reinforcementOptions.wheelReinforcementBeamDamp
  reinforcementOptions.beamDeform   = reinforcementOptions.wheelReinforcementBeamDeform
  reinforcementOptions.beamStrength = reinforcementOptions.wheelReinforcementBeamStrength
  reinforcementOptions.springExpansion = reinforcementOptions.wheelReinforcementBeamSpringExpansion
  reinforcementOptions.dampExpansion   = reinforcementOptions.wheelReinforcementBeamDampExpansion

  local treadOptions = deepcopy(wheel)
  treadOptions.beamSpring      = treadOptions.wheelTreadBeamSpring
  treadOptions.beamDamp        = treadOptions.wheelTreadBeamDamp
  treadOptions.beamDeform      = treadOptions.wheelTreadBeamDeform
  treadOptions.beamStrength    = treadOptions.wheelTreadBeamStrength
  treadOptions.springExpansion = treadOptions.wheelTreadBeamSpringExpansion
  treadOptions.dampExpansion   = treadOptions.wheelTreadBeamDampExpansion

  local peripheryOptions     = deepcopy(treadOptions)
  if peripheryOptions.wheelPeripheryBeamSpring ~=nil then peripheryOptions.beamSpring = peripheryOptions.wheelPeripheryBeamSpring end
  if peripheryOptions.wheelPeripheryBeamDamp ~= nil then peripheryOptions.beamDamp = peripheryOptions.wheelPeripheryBeamDamp end
  if peripheryOptions.wheelPeripheryBeamDeform ~= nil then peripheryOptions.beamDeform = peripheryOptions.wheelPeripheryBeamDeform end
  if peripheryOptions.wheelPeripheryBeamStrength ~= nil then peripheryOptions.beamStrength = peripheryOptions.wheelPeripheryBeamStrength end

  local supportOptions = deepcopy(hubOptions)
  supportOptions.beamPrecompression = (0.75 * wheel.hubRadius / wheel.radius) + 0.25

  local reinforcementBeams = {}
  local sideBeams = {}
  local treadBeams = {}

  for i = 0, wheel.numRays - 1, 1 do
    local i2 = 2*i
    local nextdelta = 2*((i+1)%wheel.numRays)
    local outhubnode = hubnodebase + i2
    local inhubnode = outhubnode + 1
    local nextouthubnode = hubnodebase + nextdelta
    local nextinhubnode = nextouthubnode + 1
    local intirenode = nodebase + i2
    local outtirenode = intirenode + 1
    local nextintirenode = nodebase + nextdelta
    local nextouttirenode = nextintirenode + 1
    --tire tread
    table.insert( treadBeams,
      jbeamUtils.addBeamWithOptions(vehicle, intirenode,  outtirenode,    BEAM_ANISOTROPIC, treadOptions) )
    table.insert( treadBeams,
      jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nextintirenode, BEAM_ANISOTROPIC, treadOptions) )
    -- Periphery beams
    jbeamUtils.addBeamWithOptions(vehicle, intirenode,  nextintirenode,  NORMALTYPE, peripheryOptions)
    jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nextouttirenode, NORMALTYPE, peripheryOptions)

    --hub tread
    jbeamUtils.addBeamWithOptions(vehicle, outhubnode, inhubnode,      NORMALTYPE, hubOptions)
    jbeamUtils.addBeamWithOptions(vehicle, inhubnode,  nextouthubnode, NORMALTYPE, hubOptions)
    --hub periphery beams
    jbeamUtils.addBeamWithOptions(vehicle, outhubnode, nextouthubnode, NORMALTYPE, hubOptions)
    jbeamUtils.addBeamWithOptions(vehicle, inhubnode,  nextinhubnode,  NORMALTYPE, hubOptions)

    --hub axis beams
    jbeamUtils.addBeamWithOptions(vehicle, outhubnode, wheel.node1, NORMALTYPE, hubOptions)
    jbeamUtils.addBeamWithOptions(vehicle, outhubnode, wheel.node2, NORMALTYPE, hubOptions)
    jbeamUtils.addBeamWithOptions(vehicle, inhubnode,  wheel.node1, NORMALTYPE, hubOptions)
    jbeamUtils.addBeamWithOptions(vehicle, inhubnode,  wheel.node2, NORMALTYPE, hubOptions)

    --hub tire beams
    table.insert( reinforcementBeams,
      jbeamUtils.addBeamWithOptions(vehicle, outhubnode,  intirenode,     BEAM_ANISOTROPIC, reinforcementOptions) )
    table.insert( reinforcementBeams,
      jbeamUtils.addBeamWithOptions(vehicle, inhubnode,   outtirenode,    BEAM_ANISOTROPIC, reinforcementOptions) )
    table.insert( sideBeams,
      jbeamUtils.addBeamWithOptions(vehicle, outhubnode,  outtirenode,    BEAM_ANISOTROPIC, sideOptions) )
    table.insert( sideBeams,
      jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nextouthubnode, BEAM_ANISOTROPIC, sideOptions) )
    table.insert( sideBeams,
      jbeamUtils.addBeamWithOptions(vehicle, inhubnode,   intirenode,     BEAM_ANISOTROPIC, sideOptions) )
    table.insert( sideBeams,
      jbeamUtils.addBeamWithOptions(vehicle, inhubnode,   nextintirenode, BEAM_ANISOTROPIC, sideOptions) )

    -- Support beams
    if wheel.enableTireSideSupportBeams then
      jbeamUtils.addBeamWithOptions(vehicle, wheel.node1, intirenode,  BEAM_SUPPORT, supportOptions)
      jbeamUtils.addBeamWithOptions(vehicle, wheel.node2, outtirenode, BEAM_SUPPORT, supportOptions)
    end
  end

  wheel.nodes = hubNodes
  wheel.reinforcementBeams = reinforcementBeams
  wheel.sideBeams = sideBeams
  wheel.treadBeams = treadBeams
end

M.process = addHubWheelTSV

return M
