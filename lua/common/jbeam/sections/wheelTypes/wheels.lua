--[[
This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
If a copy of the bCDDL was not distributed with this
file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
]]

-- wheel type expander for the jbeam 'wheels' section
-- the file name must match the jbeam section name, that is how the dispatcher finds it

local M = {}

local jbeamUtils = require("jbeam/utils")

-- these are defined in C, do not change the values
local NORMALTYPE = 0
local BEAM_ANISOTROPIC = 1

local function addWheel(vehicle, wheelKey, wheel)
  --log('D', "jbeam.addWheel","wheel jbeam.")
  --dump(wheel)
  local node1   = vehicle.nodes[wheel.node1]
  local node2   = vehicle.nodes[wheel.node2]
  local nodeArm = vehicle.nodes[wheel.nodeArm]

  if node1 == nil or node2 == nil then
    log('W', "jbeam.addWheel","invalid wheel")
    return
  end

  local nodebase = vehicle.maxIDs.nodes

  if wheel.radius == nil then wheel.radius = 0.5 end
  if wheel.numRays == nil then wheel.numRays = 10 end

  -- add collision to the wheels nodes ;)
  wheel.collision = true

  -- fix it like this
  local node1_pos = vec3(node1.pos)
  local node2_pos = vec3(node2.pos)

  --log('D', "jbeam.addWheel","n1 = " .. tostring(node1_pos) .. " , n2 = " .. tostring(node2_pos))

  local width = node1_pos:distance(node2_pos)
  --log('D', "jbeam.addWheel","wheel width: "..width)

  -- swap nodes?
  if node1_pos.z > node2_pos.z then
    --log('D', "jbeam.addWheel","swapping wheel nodes ...")
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

  --log('D', "jbeam.addWheel","wheel axis:" .. tostring(axis))


  local rayVec = axis:perpendicularN() * wheel.radius
  --log('D', "jbeam.addWheel","rayVector: " .. tostring(rayVec))

  local rayRot = quatFromAxisAngle(axis, 2 * math.pi / (wheel.numRays* 2))
  --log('D', "jbeam.addWheel","rayRot: " .. tostring(rayRot))

  if wheel.tireWidth ~= nil then
    local halfWidth = 0.5 * wheel.tireWidth
    node1_pos = midpoint - axis * halfWidth
    node2_pos = midpoint + axis * halfWidth
  end

  -- add nodes first
  local wheelNodes = {}
  local n = 0
  for i = 0, wheel.numRays - 1, 1 do
    -- outer
    local rayPoint = node1_pos + rayVec
    rayVec = rayRot * rayVec
    n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, wheel)
    table.insert(wheelNodes, vehicle.nodes[n])

    -- inner
    rayPoint = node2_pos + rayVec
    rayVec = rayRot * rayVec
    n = jbeamUtils.addNodeWithOptions(vehicle, rayPoint, NORMALTYPE, wheel)
    table.insert(wheelNodes, vehicle.nodes[n])
  end

  -- then add the beams
  --local wheelBeams = {}
  local b = 0

  local sideOptions = deepcopy(wheel)
  sideOptions.beamSpring   = sideOptions.wheelSideBeamSpring
  sideOptions.beamDamp     = sideOptions.wheelSideBeamDamp
  sideOptions.beamDeform   = sideOptions.wheelSideBeamDeform
  sideOptions.beamStrength = sideOptions.wheelSideBeamStrength

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

  --dump(wheel)
  -- the rest
  for i = 0, wheel.numRays - 1, 1 do
    local intirenode = nodebase + 2*i
    local outtirenode = intirenode + 1
    local nextintirenode = nodebase + 2*((i+1)%wheel.numRays)
    local nextouttirenode = nextintirenode + 1
    -- sides
    b = jbeamUtils.addBeamWithOptions(vehicle, wheel.node1, intirenode,  BEAM_ANISOTROPIC, sideOptions)
    --table.insert(wheelBeams, b.cid)
    b = jbeamUtils.addBeamWithOptions(vehicle, wheel.node2, outtirenode, BEAM_ANISOTROPIC, sideOptions)
    --table.insert(wheelBeams, b.cid)

    -- reinforcement (X) beams
    b = jbeamUtils.addBeamWithOptions(vehicle, wheel.node2, intirenode,   BEAM_ANISOTROPIC,    reinforcementOptions)
    --table.insert(wheelBeams, b.cid)
    b = jbeamUtils.addBeamWithOptions(vehicle, wheel.node1, outtirenode, BEAM_ANISOTROPIC,    reinforcementOptions)
    --table.insert(wheelBeams, b.cid)

    -- tread
    b = jbeamUtils.addBeamWithOptions(vehicle, intirenode, outtirenode,  BEAM_ANISOTROPIC, treadOptions)
    --table.insert(wheelBeams, b.cid)
    -- Periphery beam
    b = jbeamUtils.addBeamWithOptions(vehicle, intirenode, nextintirenode, NORMALTYPE, peripheryOptions)
    --table.insert(wheelBeams, b.cid)
    -- Periphery beam
    b = jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nextouttirenode, NORMALTYPE, peripheryOptions)
    --table.insert(wheelBeams, b.cid)
    b = jbeamUtils.addBeamWithOptions(vehicle, outtirenode, nextintirenode, BEAM_ANISOTROPIC, treadOptions)
    --table.insert(wheelBeams, b.cid)
  end

  -- record the wheel nodes
  wheel.nodes = wheelNodes
  -- record the wheel beams
  -- vehicle.wheels[wheelKey].beams = wheelBeams
end

M.process = addWheel

return M
