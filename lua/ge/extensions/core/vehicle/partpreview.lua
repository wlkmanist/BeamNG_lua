-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
--
-- Part preview helper for vehicle config UI.
-- Purpose: compare current vs candidate parts and drive a temporary flexmesh preview
-- without respawning the vehicle.
-- Use case: hover/focus previews in the part packs UI.

local M = {}

local jbeamIO = require('jbeam/io')
local vehManager = extensions.core_vehicle_manager
local previewMeshesByVehId = {}

local function getVehData(inVehID)
  local vehObj = inVehID and getObjectByID(inVehID) or getPlayerVehicle(0)
  if not vehObj then return end
  local vehID = vehObj:getID()
  local vehData = vehManager.getVehicleData(vehID)
  if not vehData then return end
  return vehObj, vehData, vehID
end

local function buildChosenMap(node, out, nodeKey)
  out = out or {}
  if not node then return out end
  local slotName = node.id or nodeKey
  if slotName and node.chosenPartName then out[slotName] = node.chosenPartName end
  if node.children then
    for childKey, child in pairs(node.children) do
      buildChosenMap(child, out, childKey)
    end
  end
  return out
end

local function collectMeshesFromPart(part)
  local meshes = {}
  if part and part.flexbodies then
    for _, flexbody in pairs(part.flexbodies) do
      local meshName = flexbody.mesh or flexbody[1]
      if meshName and meshName ~= "" and meshName ~= "mesh" then
        meshes[meshName] = true
      end
    end
  end
  if part and part.props then
    for _, prop in pairs(part.props) do
      local meshName = prop.mesh or prop[2]
      if meshName and meshName ~= "" and meshName ~= "mesh" then
        meshes[meshName] = true
      end
    end
  end
  return meshes
end


local function collectActiveMeshesForPart(vdata, partName)
  local meshes = {}
  if vdata.flexbodies then
    for _, flexbody in pairs(vdata.flexbodies) do
      if flexbody.partPath == partName and flexbody.mesh and flexbody.mesh ~= "" then
        meshes[flexbody.mesh] = true
      end
    end
  end
  if vdata.props then
    for _, prop in pairs(vdata.props) do
      if prop.partPath == partName and prop.mesh and prop.mesh ~= "" then
        meshes[prop.mesh] = true
      end
    end
  end
  return meshes
end

local function meshesToList(meshes)
  local list = {}
  for meshName in pairs(meshes or {}) do
    list[#list + 1] = meshName
  end
  table.sort(list)
  return list
end

local function safeGetPart(ioCtx, partName)
  if not partName or partName == "" then return nil end
  local ok, part = pcall(jbeamIO.getPart, ioCtx, partName)
  if not ok then
    jbeamIO.getAvailableParts(ioCtx)
    ok, part = pcall(jbeamIO.getPart, ioCtx, partName)
  end
  if not ok then return nil end
  return part
end

local function clearPartPreview(inVehID)
  local vehObj, _, vehID = getVehData(inVehID)
  if not vehObj then return end
  local state = previewMeshesByVehId[vehID]
  if not state then return end
  for meshName, alpha in pairs(state) do
    vehObj:setMeshAlpha(alpha, meshName, false)
  end
  previewMeshesByVehId[vehID] = nil
end

local function getFlexmeshChanges(partsBySlot, inVehID)
  local _, vehData = getVehData(inVehID)
  if not vehData or type(partsBySlot) ~= "table" then return {} end
  local chosenMap = buildChosenMap(vehData.config.partsTree or {})
  local ioCtx = vehData.ioCtx
  local changes = {}
  for slotName, partName in pairs(partsBySlot) do
    if type(partName) == "string" and partName ~= "" then
      local currentPartName = chosenMap[slotName]
      local oldPart = safeGetPart(ioCtx, currentPartName)
      local newPart = safeGetPart(ioCtx, partName)
      if oldPart and newPart then
        local oldMeshes = {}
        local newMeshes = {}
        if oldPart.flexbodies then
          for _, flexbody in pairs(oldPart.flexbodies) do
            local meshName = flexbody.mesh or flexbody[1]
            if meshName and meshName ~= "" and meshName ~= "mesh" then
              oldMeshes[meshName] = true
            end
          end
        end
        if newPart.flexbodies then
          for _, flexbody in pairs(newPart.flexbodies) do
            local meshName = flexbody.mesh or flexbody[1]
            if meshName and meshName ~= "" and meshName ~= "mesh" then
              newMeshes[meshName] = true
            end
          end
        end
        for meshName in pairs(oldMeshes) do
          if not newMeshes[meshName] then
            changes[#changes + 1] = {
              slotName = slotName,
              oldPartName = currentPartName,
              newPartName = partName,
              oldMesh = meshName,
              newMesh = nil,
            }
          end
        end
        for meshName in pairs(newMeshes) do
          if not oldMeshes[meshName] then
            changes[#changes + 1] = {
              slotName = slotName,
              oldPartName = currentPartName,
              newPartName = partName,
              oldMesh = nil,
              newMesh = meshName,
            }
          end
        end
      else
        log('W', 'partpreview', 'missing part data for slot ' .. tostring(slotName))
      end
    end
  end
  log('I', 'partpreview', 'flexmesh changes: ' .. dumps(changes))
  return changes
end

local function previewPartMeshes(partsBySlot, inVehID)
  local vehObj, vehData, vehID = getVehData(inVehID)
  if not vehObj or type(partsBySlot) ~= "table" then return end
  clearPartPreview(vehID)

  dump('previewPartMeshes', partsBySlot, inVehID)


  getFlexmeshChanges(partsBySlot, vehID)

  local chosenMap = buildChosenMap(vehData.config.partsTree or {})
  local ioCtx = vehData.ioCtx
  local previewState = {}

  for slotName, partName in pairs(partsBySlot) do
    if type(partName) == "string" and partName ~= "" then
      local currentPartName = chosenMap[slotName]
      local newPart = safeGetPart(ioCtx, partName)
      local meshesToHide = currentPartName and collectActiveMeshesForPart(vehData.vdata, currentPartName) or {}
      local meshesToShow = newPart and collectMeshesFromPart(newPart) or {}

      for meshName in pairs(meshesToHide) do
        if previewState[meshName] == nil then
          previewState[meshName] = vehObj:getMeshAlpha(meshName)
        end
        vehObj:setMeshAlpha(0, meshName, false)
      end
      for meshName in pairs(meshesToShow) do
        if previewState[meshName] == nil then
          previewState[meshName] = vehObj:getMeshAlpha(meshName)
        end
        vehObj:setMeshAlpha(1, meshName, false)
      end
    end
  end

  previewMeshesByVehId[vehID] = previewState
end

local function reset()
  previewMeshesByVehId = {}
end

M.previewPartMeshes = previewPartMeshes
M.clearPartPreview = clearPartPreview
M.getFlexmeshChanges = getFlexmeshChanges
M.reset = reset

return M
