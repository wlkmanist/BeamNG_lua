-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local jbeamIO = require("jbeam/io")

local baseMaterial = "character_display"
local faceSlotType = "skin_character_face"
local faceMaterials -- face part name -> material name
local faceOptions -- {value = part name, label = display name}, sorted by label

local function loadFaces()
  if faceMaterials then return end
  faceMaterials, faceOptions = {}, {}
  local ioCtx = jbeamIO.startLoading({"/vehicles/unicycle/"})
  for _, partName in ipairs(jbeamIO.getAvailablePartNamesForSlot(ioCtx, faceSlotType)) do
    local part = jbeamIO.getPart(ioCtx, partName)
    faceMaterials[partName] = part.skinName and (baseMaterial .. "." .. faceSlotType .. "." .. part.skinName) or baseMaterial
    faceOptions[#faceOptions + 1] = {value = partName, label = part.information.name}
  end
  table.sort(faceOptions, function(a, b) return a.label < b.label end)
  jbeamIO.finishLoading()
end

local function isFacePart(partName)
  loadFaces()
  return faceMaterials[partName] ~= nil
end

-- shared table, do not modify
local function getFaceOptions()
  loadFaces()
  return faceOptions
end

local function getRandomFacePart()
  loadFaces()
  return faceOptions[math.random(#faceOptions)].value
end

local function getFaceMaterial(partName)
  loadFaces()
  return faceMaterials[partName] or baseMaterial
end

-- material instances only exist for materials known when the vehicle finishes loading, so every face is registered on each occupant head
local function process(vehicleObj, vehicle)
  if not vehicle.occupantSystem or not vehicle.occupantSystem.enabled then return end
  for _, prop in pairs(vehicle.props or {}) do
    if (prop.originalMesh or prop.mesh) == "character_head" then
      local msc = vehicleObj:getSwitchableMaterial(baseMaterial, baseMaterial, prop.mesh)
      if msc >= 0 then
        loadFaces()
        vehicleObj:switchMaterial(msc, baseMaterial)
        for _, material in pairs(faceMaterials) do vehicleObj:switchMaterial(msc, material) end
        vehicleObj:resetMaterials(msc)
        prop.faceMaterialSwitch = msc
      end
    end
  end
end

M.isFacePart = isFacePart
M.getFaceOptions = getFaceOptions
M.getRandomFacePart = getRandomFacePart
M.getFaceMaterial = getFaceMaterial
M.process = process

return M
