--[[
This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
If a copy of the bCDDL was not distributed with this
file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
This module contains a set of functions which manipulate behaviours of vehicles.
]]

local M = {}

local min, max = math.min, math.max
local str_byte, str_sub, str_len, str_find = string.byte, string.sub, string.len, string.find

local jbeamUtils = require("jbeam/utils")

-- these are defined in C, do not change the values
local NORMALTYPE = 0

local function cleanCameraData(d)
  for k, v in pairs(d) do
    -- delete unneeded data to keep the messages small
    if k == 'group' or k == 'firstGroup' or k == 'partPath' or k == 'childParts'
    or k == 'partName' or k == 'slotType' or k == 'collision' or k == 'selfCollision'
    or k == 'nodeWeight' or  k == 'beamDamp' or k == 'beamDeform' or k == 'beamSpring'
    or k == 'beamDamp' or k == 'cid' or k == 'globalSkin' or k == 'beamStrength'
    or k == 'skinName' or k == 'skinType' then
      d[k] = nil
    elseif type(v) == 'table' then
      cleanCameraData(v)
    end
  end
end

local function getCameraData(vehicle)
  local cameraData = {}
  for k,v in pairs(vehicle.cameras) do
    v = deepcopy(v) or {}
    -- shift ipair() iterable indices, from 0..N-1  to  1..N
    if v[0] ~= nil then
      table.insert(v, 1, v[0])
      v[0] = nil
    end
    cameraData[k] = v
  end
  cleanCameraData(cameraData)
  return cameraData
end

-- Camera retrocompatibility conversions:
local function upgradeCamera(vehicle, oldName, newName)
  if vehicle[oldName] ~= nil then
    if vehicle.cameras[newName] then
      --log("E", "", "Overwriting existing vehicle.cameras."..newName.." with old deprecated vehicle."..oldName.." field")
    end
    if oldName == "camerasInternal" or oldName == "camerasRelative" then
      local driverCameraSet = false -- only set 'driver' once
      for k, v in pairs(vehicle[oldName]) do
        -- rename variable "type" to "name"
        if v.type ~= nil then
          --log("W", "", "Renaming deprecated 'type' camera field to 'name': vehicle."..oldName.."::"..dumps(v.type))
          v.name = v.type
          v.type = nil
        end
        -- backward compatibility for old cockpitCamera flag
        if oldName == "camerasInternal" and v.cockpitCamera == true and v.name == nil and not driverCameraSet then
          --log("W", "", "Renaming deprecated 'cockpitCamera' flag to 'driver'")
          v.name = 'driver'
          driverCameraSet = true
        end
        -- backward compatibility for old 'dash' name
        if v.name == "dash" then
          --log("W", "", "Renaming deprecated 'dash' onboard camera to 'driver'")
          v.name = "driver"
        end
        if v.name == "driver" then
          v.rightHandCamera = v.rightHandCamera or false -- replace missing field with actual, explicit value
          if v.rightHandDoor == nil then
            v.rightHandDoor = v.rightHandCamera -- by default, the vehicle is entered/exited from the same side as the camera is located (used for e.g. walking mode)
          end
          if v.idLeft then
            vehicle.cameraRefNodes.driver = { left = v.idLeft, back = v.idBack, ref  = v.idRef }
          end
        end
      end
    end
    vehicle.cameras[newName] = vehicle[oldName]
    vehicle[oldName] = nil
    --log("W", "", "Upgraded old deprecated vehicle."..oldName.." to new vehicle.cameras."..newName.." field")
  end
end

local function processOnboard(vehicle)
  if vehicle.cameras ~= nil and vehicle.cameras.onboard ~= nil then
    for icKey, icam in pairs(vehicle.cameras.onboard) do
      if type(icam.x) == 'number' and type(icam.y) == 'number' and type(icam.z) == 'number' then
        icam.x, icam.y, icam.z = jbeamUtils.getPosAfterNodeRotateOffsetMove(icam, icam.x, icam.y, icam.z)

        local camNodeID = jbeamUtils.addNodeWithOptions(vehicle, vec3(icam.x, icam.y, icam.z), NORMALTYPE, icam)

        if icam.id1 ~= nil then jbeamUtils.addBeamWithOptions(vehicle, camNodeID, icam.id1, NORMALTYPE, icam) end
        if icam.id2 ~= nil then jbeamUtils.addBeamWithOptions(vehicle, camNodeID, icam.id2, NORMALTYPE, icam) end
        if icam.id3 ~= nil then jbeamUtils.addBeamWithOptions(vehicle, camNodeID, icam.id3, NORMALTYPE, icam) end
        if icam.id4 ~= nil then jbeamUtils.addBeamWithOptions(vehicle, camNodeID, icam.id4, NORMALTYPE, icam) end
        if icam.id5 ~= nil then jbeamUtils.addBeamWithOptions(vehicle, camNodeID, icam.id5, NORMALTYPE, icam) end
        if icam.id6 ~= nil then jbeamUtils.addBeamWithOptions(vehicle, camNodeID, icam.id6, NORMALTYPE, icam) end
        if icam.id7 ~= nil then jbeamUtils.addBeamWithOptions(vehicle, camNodeID, icam.id7, NORMALTYPE, icam) end
        if icam.id8 ~= nil then jbeamUtils.addBeamWithOptions(vehicle, camNodeID, icam.id8, NORMALTYPE, icam) end
        icam.camNodeID = camNodeID
      else
        icam.camNodeID = icam.idCam or icam.idRef
      end
      if icam.name == "driver" then -- backwards compat: convert legacy 'driver' into an occupant
      vehicle.cameras.driver = { seatId = "driver", camNodeID = icam.camNodeID, seatSide = icam.rightHandCamera and "right" or "left" }
      end
    end
    --log('D', "jbeam.postProcess"," - processed "..tableSize(vehicle.cameras.onboard).." cameras.onboard")
  end
end

local function processOccupantCameras(vehicle)
  local slots = vehicle.occupantSlotsById
  local onboard = vehicle.cameras and vehicle.cameras.onboard
  if not slots or not onboard then return end

  vehicle.cameras.occupant = vehicle.cameras.occupant or {}
  local sourceKeys = {}
  for seatId, slot in pairs(slots) do
    local sourceName = "occupant." .. seatId
    local source
    local sourceKey
    for key, onboardCamera in pairs(onboard) do
      if onboardCamera.occupantSlotId == seatId then
        source = onboardCamera
        sourceKey = key
        break
      end
    end
    if source then
      local camera = deepcopy(source)
      camera.name = seatId
      camera.seatId = seatId
      camera.seatSide = slot.seatSide
      camera.defaultPermissionMode = slot.defaultPermissionMode
      camera.displayName = slot.displayName
      tableMergeRecursive(camera, slot.camera or {})
      vehicle.cameras.occupant[seatId] = camera
      local defaultRefNodes = vehicle.refNodes and vehicle.refNodes[0] or {}
      vehicle.cameraRefNodes["occupant." .. seatId] = {
        ref = source.idRef or defaultRefNodes.ref,
        left = source.idLeft or defaultRefNodes.left,
        back = source.idBack or defaultRefNodes.back,
      }
      sourceKeys[#sourceKeys + 1] = sourceKey
    else
      log("W", "jbeam.camera", string.format(
        "No onboard camera anchor %q found for occupant slot %q",
        sourceName,
        seatId
      ))
    end
  end
  for _, key in ipairs(sourceKeys) do
    onboard[key] = nil
  end
end

local function processRelative(vehicle)
  -- emulation mode for camerasRelative
  if vehicle.cameras.relative == nil and vehicle.cameras.onboard then
    -- backward compatibility: import onboard cameras
    vehicle.cameras.relative = {}
    -- try to emulate one from deducing values from the onboard camera system
    for icKey, icam in pairs(vehicle.cameras.onboard) do
      if type(icam.x) == 'number' and type(icam.y) == 'number' and type(icam.z) == 'number' then
        local cr = {}
        local nPos = {x=icam.x, y=icam.y, z=icam.z}
        if vehicle.refNodes and vehicle.refNodes[0] and vehicle.refNodes[0].ref and vehicle.nodes[vehicle.refNodes[0].ref] then
          local refNode = vehicle.nodes[vehicle.refNodes[0].ref]
          cr.pos = nPos - vec3(refNode.pos) -- calculate out the refnode
          cr.pos.x = - cr.pos.x -- invert X and Y axis for some reason?!
          cr.pos.y = - cr.pos.y -- invert X and Y axis for some reason?!
        end
        cr.name = icam.name
        cr.fov = icam.fov
        cr.rot = vec3(0, 180, 0) -- look forward by default
        table.insert(vehicle.cameras.relative, cr)
      end
    end
  elseif vehicle.cameras.relative ~= nil then
    if vehicle.refNodes and vehicle.refNodes[0] and vehicle.refNodes[0].ref and vehicle.nodes[vehicle.refNodes[0].ref] then
      local refNodePos = vec3(vehicle.nodes[vehicle.refNodes[0].ref].pos)

      -- convert position table to vec3
      for _, cr in pairs(vehicle.cameras.relative) do
        cr.pos = vec3(cr)
        cr.x, cr.y, cr.z = nil, nil, nil

        cr.pos = cr.pos - refNodePos -- calculate out the refnode
        cr.pos.x = - cr.pos.x -- invert X and Y axis for some reason?!
        cr.pos.y = - cr.pos.y -- invert X and Y axis for some reason?!

        -- some default values
        if cr.rot == nil then
          cr.rot = vec3()
        else
          cr.rot = vec3(cr.rot)
        end
        if cr.fov == nil then cr.fov = 70 end

        -- rotation is 180 dg off? O_o
        cr.rot = cr.rot + vec3(0, 180, 0)
      end
    end
  end
end

local function processOnboard2(vehicle)
  -- Onboard cameras
  if vehicle.cameras.onboard ~= nil then
    local counter = 1
    local foundCameras = {}
    for k, v in pairs(vehicle.cameras.onboard) do
      -- automatic numeric naming
      if v.name == nil or type(v.name) ~= 'string' then
        v.name = 'onboard_' .. tostring(counter)
        v.order = v.order or counter + 20
        counter = counter + 1
      end
      if v.fov == nil then v.fov = 75 end
      if v.isInside == nil and (v.name == "driver" or v.name == "rider") then
        log("I", "", string.format("Backwards compatibility: setting isInside=true for camera '%s'", v.name))
        v.isInside = true
      end

      -- check for duplicates:
      if foundCameras[v.name] then
        log('E', "jbeam.pushToPhysics", "Ignoring onboard camera with duplicate name: " .. tostring(v.name))
      end
      foundCameras[v.name] = 1
    end
    --log("I", "", "Found cameras: "..dumps(vehicle.cameras.onboard))
  end
end

local function process(objID, vehicle)
  profilerPushEvent('jbeam/camera.process')

  vehicle.cameras = vehicle.cameras or {}
  vehicle.cameraRefNodes = vehicle.cameraRefNodes or {}
  upgradeCamera(vehicle, "camerasInternal", "onboard")
  upgradeCamera(vehicle, "cameraExternal",  "orbit")
  upgradeCamera(vehicle, "camerasRelative", "relative")
  upgradeCamera(vehicle, "cameraChase",     "chase")

  processOnboard(vehicle)
  processOccupantCameras(vehicle)
  processRelative(vehicle)
  processOnboard2(vehicle)

  vehicle.cameraData = getCameraData(vehicle)

  --[[
  if vehicle.mirrors then
    if obj then
      obj:queueGameEngineLua("extensions.load('core_vehicleMirrors')")
    else
      extensions.load('core_vehicleMirrors')
    end
  end
  --]]
  profilerPopEvent('jbeam/camera.process')
end

M.process = process

return M
