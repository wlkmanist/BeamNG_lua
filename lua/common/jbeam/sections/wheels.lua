--[[
This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
If a copy of the bCDDL was not distributed with this
file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
This module contains a set of functions which manipulate behaviours of vehicles.
]]

-- this function provides various construction functions for wheels

local M = {}

local jbeamUtils = require("jbeam/utils")

-- the order decides wheelID and node cid assignment, do not reorder
local wheelSections = {"wheels", "monoHubWheels", "hubWheelsTSV", "hubWheelsTSI", "hubWheels", "pressureWheels"}
local handlers = {}

local function processWheel(vehicle, wheelSection, wheelCreationFunction)
  if vehicle[wheelSection] ~= nil then
    for k = 0, tableSizeC(vehicle[wheelSection]) - 1 do
      local v = vehicle[wheelSection][k]
      --log('D', "jbeam.processWheel"," * "..tostring(k).." = "..tostring(v).." ["..type(v).."]")
      if v.numRays == nil or v.numRays > 0 then
        local wheelID = jbeamUtils.increaseMax(vehicle, 'wheels')
        v.wheelID = wheelID
        wheelCreationFunction(vehicle, k, v)
        vehicle.wheels[wheelID] = v
        vehicle.wheels[wheelID].wheelSection = wheelSection
        vehicle[wheelSection][k] = nil -- everything is in wheels now
      end
    end
  end
  if not tableIsEmpty(vehicle[wheelSection]) then
    --log('D', "jbeam.processWheel"," - processed "..tableSize(vehicle[wheelSection]).." of "..wheelSection.."(s)")
  end
end

local addStrapsToEverything = false
local function addWheelAttachments(vehicle)
  if vehicle.flexbodies == nil then return end

  if addStrapsToEverything then
    -- Collect attachments separately to avoid mutating during iteration.
    local toAdd = {}
    for _, flexbody in pairs(vehicle.flexbodies) do
      local mesh = flexbody.mesh
      local groups = flexbody["[group]:"]
      -- Only wrap tire meshes and skip any strap/attachment entries.
      if type(mesh) == "string" and string.find(mesh, "tire_", 1, true) and not string.find(mesh, "strap", 1, true) and not flexbody._isAttachment then
        --log('I', "jbeam.addWheelAttachments", "candidate tire flexbody: " .. mesh)
        local hasWheelGroup = false
        if type(groups) == "string" then
          hasWheelGroup = groups:sub(1, 6) == "wheel_"
        elseif type(groups) == "table" then
          for _, group in ipairs(groups) do
            if type(group) == "string" and group:sub(1, 6) == "wheel_" then
              hasWheelGroup = true
              break
            end
          end
        end

        if hasWheelGroup then
          -- Clone the tire flexbody and swap the mesh to the strap.
          local attachment = deepcopy(flexbody)
          attachment.mesh = "tire_02c_22x10_39strap"
          attachment._isAttachment = true
          table.insert(toAdd, attachment)
          --log('I', "jbeam.addWheelAttachments", "added strap flexbody for: " .. mesh)
        end
      end
    end

    -- Append generated strap flexbodies.
    for _, attachment in ipairs(toAdd) do
      table.insert(vehicle.flexbodies, attachment)
    end
  end
end

local function processWheels(vehicle)
  profilerPushEvent('jbeam/wheels.processWheels')
  if vehicle.wheels ~= nil  then
    vehicle.maxIDs.wheels = nil
  end
  vehicle.wheels = {}

  for _, section in ipairs(wheelSections) do
    if not tableIsEmpty(vehicle[section]) then
      local handler = handlers[section]
      if handler == nil then
        handler = require("jbeam/sections/wheelTypes/" .. section).process
        handlers[section] = handler
      end
      processWheel(vehicle, section, handler)
    end
  end

  addWheelAttachments(vehicle)

  profilerPopEvent('jbeam/wheels.processWheels')
  return true
end

local function processRotators(vehicle)
  if vehicle.rotators ~= nil then
    for rotId = 0, tableSizeC(vehicle.rotators) - 1 do
      local rotData = vehicle.rotators[rotId]
      --log('D', "jbeam.postProcess"," * "..tostring(k).." = "..tostring(v).." ["..type(v).."]")
      local wheelID = jbeamUtils.increaseMax(vehicle, 'wheels')
      rotData.wheelID = wheelID
      jbeamUtils.addRotator(vehicle, rotId, rotData)
      vehicle.wheels[wheelID] = rotData
    end
  end
  if not tableIsEmpty(vehicle.rotators) then
    --log('D', "jbeam.postProcess"," - processed "..tableSize(vehicle.rotators).." of rotator(s)")
  end

  -- remove wheels with no nodes and renumber the cids
  local newWheels = {}
  local wheelId = 0
  for wheelKey = 0, tableSizeC(vehicle.wheels) - 1 do
    local wheel = vehicle.wheels[wheelKey]
    if wheel.nodes == nil or next(wheel.nodes) == nil then
      log('W', "jbeam.pushToPhysics","*** wheel: "..wheel.name.." doesn't have any node bindings")
    else
      newWheels[wheelId] = wheel
      wheel.cid = wheelId
      wheelId = wheelId + 1
    end
  end
  vehicle.wheels = newWheels
end

M.processWheels = processWheels
M.processRotators = processRotators

return M
