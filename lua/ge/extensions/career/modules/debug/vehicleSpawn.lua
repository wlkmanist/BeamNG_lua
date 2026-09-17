-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.debugName = "Vehicle Spawn"
M.debugOrder = 12
M.dependencies = {"gameplay_sites_sitesManager"}

local im = ui_imgui
local ps = nil
local firstUpdate = false

-- poi list stuff
local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if not ps then
    --log("E","","No parking marker for debug!")
    return
  end
  table.insert(elements, {
    id = "debugVehicleSpawn",
    data = {type = "debugVehicleSpawn", id = "debugVehicleSpawn"},
    markerInfo = {
      parkingMarker = {path = ps:getPath(), pos = ps.pos, rot = ps.rot, scl = ps.scl },
    }
  })
end
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel

local function drawDebugMenu()
  if not firstUpdate then
    -- load all targets
    local sites = gameplay_sites_sitesManager.loadSites("/levels/west_coast_usa/facilities.sites.json")
    ps = sites.parkingSpots.byName['debugParking']
    gameplay_rawPois.clear()
    firstUpdate = true
  end

  if im.Begin("Vehicle Spawn") then
    if im.Button("Spawn and rent a vehicle") then
      M.spawnVehicle("sunburst", "race_M", true)
    end
  end
  im.End()
end
M.drawDebugMenu = drawDebugMenu

local function spawnVehicle(model, config, addToInventory)
  extensions.load("util_stepHandler")
  local partConditionsDone = false
  local sequence = {
    -- fade to black
    util_stepHandler.makeStepFadeToBlack(),
    -- spawn vehicle and trigger initialization
    util_stepHandler.makeStepSpawnVehicleSimple(model, config,
      function(step, vehId)
        local vehObj = scenetree.findObjectById(vehId)
        core_vehicleBridge.executeAction(vehObj, 'initPartConditions', {}, 0, 1, 1)
        core_vehicleBridge.requestValue(vehObj,
          function(res)
            partConditionsDone = true
            if addToInventory then
              career_modules_inventory.addVehicle(vehId, nil, {owned = false})
            end
          end
          , 'ping')
      end
      ),
    -- wait until initialization is done
    util_stepHandler.makeStepReturnTrueFunction(
      function() return partConditionsDone end
      ),
    util_stepHandler.makeStepFadeFromBlack()
  }
  -- start sequence
  util_stepHandler.startStepSequence(sequence)
end
M.spawnVehicle = spawnVehicle

local buttonOptions = {}
M.buttonPressed = function(i)
  buttonOptions[i]()
end

local function onPoiDetailPromptOpening(elemData, promptData)
  local valid = false
  for _, elem in ipairs(elemData) do
    if elem.type == "debugVehicleSpawn" then
      valid = true
    end
  end
  if not valid then return end

  local ret = {}
  ret.label = "Debug"
  ret.buttonText = "Open Debug Menu"
  ret.buttonFun = function()
    local buttons = {}
    table.clear(buttonOptions)


    table.insert(buttons, {
      label = "Spawn 'Rented' Vehicle",
      luaCallback = "career_modules_debug_vehicleSpawn.spawnVehicle('sunburst','race_M')",
      enabled = true,
    })

    table.insert(buttons, {
      label = "Spawn 'Rented' Trailer",
      luaCallback = "career_modules_debug_vehicleSpawn.spawnVehicle('boxutility','loaded_200')",
      enabled = true,
    })

    table.insert(buttons, {
      label = "Spawn Trailer and add to Inventory",
      luaCallback = "career_modules_debug_vehicleSpawn.spawnVehicle('boxutility','loaded_200', true)",
      enabled = true,
    })


    local data = {text = "Debug Tester", buttons = buttons, class = "recoveryPrompt"}
    guihooks.trigger('showConfirmationDialog', data)
    gameplay_markerInteraction.closeViewDetailPrompt(true)
  end
  table.insert(promptData, ret)
end

M.onPoiDetailPromptOpening = onPoiDetailPromptOpening

return M
