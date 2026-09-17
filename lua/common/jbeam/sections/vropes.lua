--[[
This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
If a copy of the bCDDL was not distributed with this
file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
This module contains a set of functions which manipulate behaviours of vehicles.
]]

local M = {}

local jbeamUtils = require("jbeam/utils")


local function findPropIdByName(vehicle, propName)
  for _, prop in pairs(vehicle.props) do
    if prop.name == propName then
      --dump{ "Prop found: " .. tostring(propName) .. " with id: " .. tostring(prop.cid) .. dumps(prop) }
      return prop.cid
    end
  end
  log('E', 'jbeam.ropes', 'Prop not found: ' .. tostring(propName))
  return nil
end

-- Process ropes from the ropes section in JBeam files
local function processRopes(objID, vehicleObj, vehicle)
  profilerPushEvent('processRopes')

  --dump{"ROPES", vehicle.vropes}

  -- Initialize rope IDs array if it doesn't exist
  local newRopeIds = {}

  if vehicle.vropes ~= nil and vehicleObj then
    local rope_count = 0
    -- After tableSchema processing, ropes is now a dictionary/object
    for ropeName, ropeConfig in pairs(vehicle.vropes) do
      --dump({"ropeName", ropeName, "ropeConfig", ropeConfig})
      if ropeConfig and ropeConfig.anchorAProp and ropeConfig.anchorBProp then

        --dump({"ropeConfig.anchorAProp", ropeConfig.anchorAProp, "ropeConfig.anchorBProp", ropeConfig.anchorBProp})
        -- Get anchor node positions
        local anchorAProp = findPropIdByName(vehicle, ropeConfig.anchorAProp)
        local anchorBProp = findPropIdByName(vehicle, ropeConfig.anchorBProp)

        if anchorAProp and anchorBProp then
          -- Create the rope visual
          local ropeId = createRopeVisual()
          if ropeId then
            local rope = getRopeVisual(ropeId)
            if rope then
              -- Set anchor positions

              rope.vehiclePropIdA = anchorAProp
              rope.vehiclePropIdB = anchorBProp
              --rope.anchorA = vec3(anchorAProp.pos.x, anchorAProp.pos.y, anchorAProp.pos.z)
              --rope.anchorB = vec3(anchorBProp.pos.x, anchorBProp.pos.y, anchorBProp.pos.z)

              -- Set rope directions (default to pointing down if not specified)
              rope.dirA = ropeConfig.dirA and vec3(ropeConfig.dirA.x, ropeConfig.dirA.y, ropeConfig.dirA.z) or vec3(0, 0, -1)
              rope.dirB = ropeConfig.dirB and vec3(ropeConfig.dirB.x, ropeConfig.dirB.y, ropeConfig.dirB.z) or vec3(0, 0, -1)

              -- Set rope properties with defaults
              rope.nodeCount = ropeConfig.nodeCount or 16
              rope.lengthScale = ropeConfig.lengthScale or 1.2
              rope.diameter = ropeConfig.diameter or 0.05
              rope.damping = ropeConfig.damping or 0.995
              rope.bendStiffness = ropeConfig.bendStiffness or 0.8
              rope.useXPBD = ropeConfig.useXPBD or false
              rope.useBending = ropeConfig.useBending ~= false  -- Default to true unless explicitly false
              rope.bendSegmentLength = ropeConfig.bendSegmentLength or 2
              rope.useWorldCollision = ropeConfig.useWorldCollision or false
              rope.useSelfCollision = ropeConfig.useSelfCollision or false
              rope.useStrainLimit = ropeConfig.useStrainLimit ~= false  -- Default to true unless explicitly false
              rope.maxStrainLimit = ropeConfig.maxStrainLimit or 2.0
              rope.totalMass = ropeConfig.totalMass or 0.5
              rope.massFalloff = ropeConfig.massFalloff or 0.0
              rope.iterations = ropeConfig.iterations or 1
              rope.youngsModulus = ropeConfig.youngsModulus or 1e6
              rope.renderRope = ropeConfig.renderRope ~= false  -- Default to true
              rope.windScale = ropeConfig.windScale or 0.5
              rope.windDrag = ropeConfig.windDrag or 0.5
              rope.materialName = ropeConfig.materialName or ""
              rope.anchorAFixed = ropeConfig.anchorAFixed or false
              rope.anchorBFixed = ropeConfig.anchorBFixed or false
              rope.simFPS = ropeConfig.simFPS or 60

              -- Rebuild the rope with new properties
              rope:rebuild()

              -- Add rope ID to the vehicle's rope IDs array for automatic rendering
              table.insert(newRopeIds, ropeId)

              rope_count = rope_count + 1
              log('I', 'jbeam.ropes', 'Created rope ' .. ropeId .. ' (' .. tostring(ropeName) .. ') between nodes ' .. ropeConfig.anchorAProp .. ' and ' .. ropeConfig.anchorBProp)
            else
              log('E', 'jbeam.ropes', 'Failed to get rope visual for ropeId: ' .. tostring(ropeId))
            end
          else
            log('E', 'jbeam.ropes', 'Failed to create rope visual for rope: ' .. tostring(ropeName))
          end
        else
          log('E', 'jbeam.ropes', 'Invalid anchor nodes for rope ' .. tostring(ropeName) .. ': anchorA=' .. tostring(ropeConfig.anchorAProp) .. ', anchorB=' .. tostring(ropeConfig.anchorBProp))
        end
      else
        log('E', 'jbeam.ropes', 'Rope configuration missing required anchorAProp or anchorBProp for rope: ' .. tostring(ropeName))
      end
    end
    log('D', 'jbeam.ropes', 'Processed ' .. rope_count .. ' ropes')

    vehicleObj.ropeIds = newRopeIds

  end

  profilerPopEvent('processRopes')
end

local function process(objID, vehicleObj, vehicle)
  profilerPushEvent('jbeam/ropes.process')

  -- Process ropes from the ropes section
  processRopes(objID, vehicleObj, vehicle)

  profilerPopEvent('jbeam/ropes.process')
end

M.process = process

return M