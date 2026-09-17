-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local im = ui_imgui
M.debugOrder = 2
M.debugName = "Vehicles"

M.drawDebugMenu = function()
  if im.Button("Add this Vehicle as new vehicle to inventory") then
    local inventoryId = career_modules_inventory.addVehicle(be:getPlayerVehicleID(0))
    career_modules_inventory.enterVehicle(inventoryId)
  end

  if im.Button("Respawn Current Vehicle") then
    career_modules_inventory.debugRespawnCurrentVehicle()
  end

  local currentVehicle = career_modules_inventory.getCurrentVehicle()

  if currentVehicle then
    im.Text("Current Vehicle: " .. currentVehicle .. " (" .. career_modules_inventory.getVehicles()[currentVehicle].model .. ")")
  end

  local vehicleToSell
  if im.BeginChild1("Owned Vehicles", im.ImVec2(0, 150), true) then
    im.Text("Change to one of your vehicles")

    for id, data in pairs(career_modules_inventory.getVehicles()) do
      if im.Button("id " .. id .. " (" .. data.model .. ")") then
        career_modules_inventory.enterVehicle(id)
      end
      im.SameLine()

      if im.Button(string.format("sell ##%d",  id)) then
        vehicleToSell = id
      end
    end
  end
  im.EndChild()

  if vehicleToSell then
    career_modules_inventory.sellVehicleFromInventory(vehicleToSell)
  end
end

return M