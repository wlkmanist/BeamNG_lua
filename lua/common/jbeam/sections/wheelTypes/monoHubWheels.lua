--[[
This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
If a copy of the bCDDL was not distributed with this
file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
]]

-- wheel type expander for the jbeam 'monoHubWheels' section
-- the file name must match the jbeam section name, that is how the dispatcher finds it

local M = {}

local jbeamUtils = require("jbeam/utils")

-- these are defined in C, do not change the values
local NORMALTYPE = 0
local BEAM_ANISOTROPIC = 1
local BEAM_SUPPORT = 7

local function addMonoHubWheel(vehicle, wheelKey, wheel)
  --log('D', "jbeam.addMonoHubWheel","wheel jbeam.")
  --dump(wheel)
  local node1   = vehicle.nodes[wheel.node1]
  local node2   = vehicle.nodes[wheel.node2]
  local nodeArm = vehicle.nodes[wheel.nodeArm]

  if node1 == nil or node2 == nil then
    log('W', "jbeam.addMonoHubWheel","invalid monohub wheel")
    return
  end

  if wheel.radius == nil then    wheel.radius = 0.5 end
  if wheel.hubRadius == nil then wheel.hubRadius = 0.65 * wheel.radius end
  if wheel.numRays == nil then wheel.numRays = 10 end

  local nodebase = vehicle.maxIDs.nodes

  -- add collision to the wheels nodes ;)
  wheel.collision = true

  -- fix it like this
  local node1_pos = vec3(node1.pos)
  local node2_pos = vec3(node2.pos)

  --log('D', "jbeam.addMonoHubWheel","n1 = " .. tostring(node1_pos) .. " , n2 = " .. tostring(node2_pos))

  local width = node1_pos:distance(node2_pos)
  --log('D', "jbeam.addMonoHubWheel","monohub wheel width: "..width)

  -- swap nodes?
  if node1_pos.z > node2_pos.z then
    --log('D', "jbeam.addMonoHubWheel","swapping monohub wheel nodes ...")
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

  --log('D', "jbeam.addMonoHubWheel","wheel axis:" .. tostring(axis))

  local rayVec = axis:perpendicularN() * wheel.radius
  --log('D', "jbeam.addMonoHubWheel","rayVector: " .. tostring(rayVec))

  local rayRot = quatFromAxisAngle(axis, 2 * math.pi / (wheel.numRays* 2))

  --log('D', "jbeam.addMonoHubWheel","rayRot: " .. tostring(rayRot))

  if wheel.tireWidth ~= nil then
    local halfWidth = 0.5 * wheel.tireWidth
    node1_pos = midpoint - axis * halfWidth
    node2_pos = midpoint + axis * halfWidth
  end

  -- add nodes first
  for i = 0, wheel.numRays - 1, 1 do
    -- outer
    local rayPoint = node1_pos + rayVec
    rayVec = rayRot * rayVec
    local n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, wheel)

    -- inner
    rayPoint = node2_pos + rayVec
    rayVec = rayRot * rayVec
    n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, wheel)
  end

  -- then add the beams

  local sideOptions = deepcopy(wheel)
  sideOptions.beamSpring   = sideOptions.wheelSideBeamSpring
  sideOptions.beamDamp     = sideOptions.wheelSideBeamDamp
  sideOptions.beamDeform   = sideOptions.wheelSideBeamDeform
  sideOptions.beamStrength = sideOptions.wheelSideBeamStrength

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

  local hubOptions = deepcopy(wheel)
  if hubOptions.hubNodeWeight ~= nil then hubOptions.nodeWeight = hubOptions.hubNodeWeight end
  if hubOptions.hubCollision ~= nil then hubOptions.collision = hubOptions.hubCollision end
  if hubOptions.hubNodeMaterial ~= nil then hubOptions.nodeMaterial = hubOptions.hubNodeMaterial end
  if hubOptions.hubFrictionCoef ~= nil then hubOptions.frictionCoef = hubOptions.hubFrictionCoef end

  local supportOptions = deepcopy(hubOptions)
  supportOptions.beamPrecompression = (0.75 * wheel.hubRadius / wheel.radius) + 0.25

  for i = 0, wheel.numRays - 1, 1 do
    local intirenode = nodebase + 2*i
    local outtirenode = intirenode + 1
    local nextintirenode = nodebase + 2*((i+1)%wheel.numRays)
    local nextouttirenode = nextintirenode + 1
    -- Sides
    jbeamUtils.addBeamWithOptions(vehicle, wheel.node1, intirenode,  BEAM_ANISOTROPIC, sideOptions)
    jbeamUtils.addBeamWithOptions(vehicle, wheel.node2, outtirenode, BEAM_ANISOTROPIC, sideOptions)
    -- Tire tread
    jbeamUtils.addBeamWithOptions(vehicle, intirenode,  outtirenode,    BEAM_ANISOTROPIC, treadOptions)
    jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nextintirenode, BEAM_ANISOTROPIC, treadOptions)
    -- Periphery beams
    jbeamUtils.addBeamWithOptions(vehicle, intirenode,  nextintirenode,  NORMALTYPE, peripheryOptions)
    jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nextouttirenode, NORMALTYPE, peripheryOptions)
    -- Support beams
    jbeamUtils.addBeamWithOptions(vehicle, wheel.node1, intirenode,  BEAM_SUPPORT, supportOptions)
    jbeamUtils.addBeamWithOptions(vehicle, wheel.node2, outtirenode, BEAM_SUPPORT, supportOptions)
  end

  -- monoHub
  local rayVec = axis:perpendicularN() * wheel.hubRadius

  -- initial rotation
  local tmpRot = quatFromAxisAngle(axis, 2 * math.pi / (wheel.numRays * 4))

  rayVec = tmpRot * rayVec
  -- all hub node rotation
  rayRot = quatFromAxisAngle(axis, 2 * math.pi / (wheel.numRays))
  --log('D', "jbeam.addMonoHubWheel","rayVector: " .. tostring(rayVec))

  -- add monoHub nodes
  local hubNodes = {}
  local hubnodebase = vehicle.maxIDs.nodes

  for i = 0, wheel.numRays - 1, 1 do
    -- outer
    local rayPoint = midpoint + rayVec
    local n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, hubOptions)
    rayVec = rayRot * rayVec
    table.insert(hubNodes, vehicle.nodes[n])
  end

  if hubOptions.hubBeamSpring ~= nil then hubOptions.beamSpring = hubOptions.hubBeamSpring end
  if hubOptions.hubBeamDamp ~= nil then hubOptions.beamDamp = hubOptions.hubBeamDamp end
  if hubOptions.hubBeamDeform ~= nil then hubOptions.beamDeform = hubOptions.hubBeamDeform end
  if hubOptions.hubBeamStrength ~=nil then hubOptions.beamStrength = hubOptions.hubBeamStrength end

  -- hub-tire beams options
  local reinforcementOptions = deepcopy(wheel)
  reinforcementOptions.beamSpring   = reinforcementOptions.wheelReinforcementBeamSpring
  reinforcementOptions.beamDamp     = reinforcementOptions.wheelReinforcementBeamDamp
  reinforcementOptions.beamDeform   = reinforcementOptions.wheelReinforcementBeamDeform
  reinforcementOptions.beamStrength = reinforcementOptions.wheelReinforcementBeamStrength
  reinforcementOptions.springExpansion = reinforcementOptions.wheelReinforcementBeamSpringExpansion
  reinforcementOptions.dampExpansion   = reinforcementOptions.wheelReinforcementBeamDampExpansion

  for i = 0, wheel.numRays - 1, 1 do
    local hubnode = hubnodebase + i
    local nexthubnode = hubnodebase + ((i+1)%wheel.numRays)
    local intirenode = nodebase + 2*i
    local outtirenode = intirenode + 1
    local nextintirenode = nodebase + 2*((i+1)%wheel.numRays)
    -- hub-axis beams
    jbeamUtils.addBeamWithOptions(vehicle, wheel.node2, hubnode, NORMALTYPE, hubOptions)
    jbeamUtils.addBeamWithOptions(vehicle, wheel.node1, hubnode, NORMALTYPE, hubOptions)
    -- hub periphery beams
    jbeamUtils.addBeamWithOptions(vehicle, hubnode, nexthubnode, NORMALTYPE, hubOptions)

    -- hub-tire beams
    jbeamUtils.addBeamWithOptions(vehicle, hubnode, intirenode,  BEAM_ANISOTROPIC, reinforcementOptions)
    jbeamUtils.addBeamWithOptions(vehicle, hubnode, outtirenode, BEAM_ANISOTROPIC, reinforcementOptions)
    jbeamUtils.addBeamWithOptions(vehicle, hubnode, nextintirenode,  BEAM_ANISOTROPIC, reinforcementOptions)
    jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nexthubnode, BEAM_ANISOTROPIC, reinforcementOptions)

  end

  wheel.nodes = hubNodes
end

M.process = addMonoHubWheel

return M
