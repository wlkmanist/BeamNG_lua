-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Generate Drag Race Opponents'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle
C.description = "Gives you a random amount of vehicles configurations determinated by the player vehicle."
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'vehId', default = 0, description = "Vehicle ID. If not present, player vehicle will be used." },
  { dir = 'in', type = 'number', name = 'numberOfOpponents', default = 1, description = 'Number of generated vehicles.' },
  { dir = 'out', type = 'table', name = 'vehicleGroup', description = '' },
}

C.tags = {}

function C:init()
  self.selectedOpponents = {}
  self.playerId = -1
end

function C:drawCustomProperties()
  local reason = nil
  return reason
end

function C:drawMiddle(builder, style)
  builder:Middle()
end

function C:selectVehicle()
  local randomVehicles = {}
  local configs = core_vehicles.getConfigList()
  local weightPower

  --Get the possible vehicle configurations
  local vehConfigs = {}
  for i,v in pairs(configs.configs) do
    local model = core_vehicles.getModel(v.model_key).model

    local passType = true
    passType = passType and (model.Type == 'Car' or model.Type == 'Truck') and model['isAuxiliary'] ~= true -- always only use cars or trucks
    if passType and not string.match(i, 'simple_traffic') then
      table.insert(vehConfigs, v)
    end
  end

  --Get the player configuration if there is any at all.
  local currentVeh = core_vehicles.getCurrentVehicleDetails()
  local currentConfig
  if currentVeh.current.key and currentVeh.current.config_key then
    currentConfig = currentVeh.current.key .. " " .. currentVeh.current.config_key
  else
    local min, max = currentVeh.model.aggregates["Weight/Power"].min, currentVeh.model.aggregates["Weight/Power"].max
    weightPower = ((max - min)/2) + ((max - min)/2) * math.random()
  end

  local similarVehicles = {}
  local similarVehicleCount = 0

  --Save the currentVehicle Weight/Power value to use for comparison
  if not weightPower then
    for _,v in pairs(vehConfigs) do
      if currentConfig and currentConfig == (v.model_key .. " " .. v.key) then
        if v["Weight/Power"] then
          weightPower = v["Weight/Power"]
        end
      end
    end
  end

  --Find vehicles with a very close to the same Weight/Power values
  for i,v in pairs(vehConfigs) do
    if (v["Weight/Power"] and weightPower)then
      if v["Weight/Power"] >= weightPower - (weightPower * 0.2) and v["Weight/Power"] < weightPower then
        table.insert(similarVehicles, v)
        similarVehicleCount = similarVehicleCount + 1
      end
    end
  end

  --Add a random selection of vehicles
  for i = 1, self.pinIn.numberOfOpponents.value do
    local selectedConfig = similarVehicles[math.random(similarVehicleCount)]
    local m = selectedConfig.model_key
    local c = selectedConfig.key
    local p = tableKeys(tableValuesAsLookupDict(core_vehicles.getModel(selectedConfig.model_key).model.paints or {}))
    local n = selectedConfig.Name
    table.insert(randomVehicles, {
          model = m,
          config = c,
          name = n,
          paint = p[math.random(#p)],
        })
  end

  return randomVehicles
end

function C:_executionStarted()
  self.selectedOpponents = {}
  self.playerId = 0
end

function C:workOnce()
  math.randomseed(os.time())
  local group = self:selectVehicle()
  if #group ~= self.pinIn.numberOfOpponents.value then
    log("E", "generateDragOpponent.lua", "Not enough vehicles selected to proceed, trying again")
    group = self:selectVehicle()
  end
  self.pinOut.vehicleGroup.value = group
end

return _flowgraph_createNode(C)
