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
  { dir = 'in', type = 'number', name = 'playerDial', default = -1, description = '' },
  { dir = 'out', type = 'table', name = 'vehicleGroup', description = '' },
}

C.tags = {}

C.dependencies = {'gameplay_drag_dragBridge'}

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

-- Get list of available paint names for a vehicle model
local function getAvailablePaints(modelKey)
  local modelData = core_vehicles.getModel(modelKey)
  if modelData and modelData.model and modelData.model.paints then
    return tableKeys(tableValuesAsLookupDict(modelData.model.paints))
  end
  return {}
end

-- Filter vehicle configs to only include valid cars/trucks
function C:filterValidVehicleConfigs()
  local vehConfigs = {}
  local configs = core_vehicles.getConfigList()

  for i, v in pairs(configs.configs) do
    local modelData = core_vehicles.getModel(v.model_key)
    if modelData and modelData.model then
      local model = modelData.model
      local isValid = (model.Type == 'Car' or model.Type == 'Truck') and model['isAuxiliary'] ~= true
      if isValid and not string.match(i, 'simple_traffic') then
        table.insert(vehConfigs, v)
      end
    end
  end

  return vehConfigs
end

-- Create a vehicle entry from a config
function C:createVehicleEntry(config)
  local paints = getAvailablePaints(config.model_key)
  local paint = (#paints > 0) and paints[math.random(#paints)] or nil

  local dial = 12
  if config["Drag Times"] then
    dial = config["Drag Times"].time_1_4
  end

  return {
    model = config.model_key,
    config = config.key,
    paint = paint,
    dial = dial
  }
end

-- Generate opponents using player vehicle with different colors
function C:getPlayerVehicleAsFallback(count)
  local randomVehicles = {}
  local currentVeh = core_vehicles.getCurrentVehicleDetails()

  if not currentVeh or not currentVeh.model or not currentVeh.model.model or not currentVeh.configs then
    return randomVehicles
  end

  local modelKey = currentVeh.model.model
  local configKey = currentVeh.configs.Name or "base"
  local paints = getAvailablePaints(modelKey)
  local playerDial = currentVeh.configs["Drag Times"] and currentVeh.configs["Drag Times"].time_1_4 or 12

  for i = 1, count do
    local paint = (#paints > 0) and paints[math.random(#paints)] or nil
    table.insert(randomVehicles, {
      model = modelKey,
      config = configKey,
      paint = paint,
      dial = playerDial
    })
  end

  return randomVehicles
end

-- Get player dial time from various sources
function C:getPlayerDial(currentVeh)
  local dial = self.pinIn.playerDial.value or -1

  if dial >= 0 then
    return dial
  end

  -- Try to get from save file
  if gameplay_drag_dragBridge then
    local configTimes = gameplay_drag_dragBridge.getDialTimes()
    if configTimes then
      local currentConfig = gameplay_drag_dragBridge.generateHashFromFile()
      if configTimes[currentConfig] then
        return configTimes[currentConfig].time_1_4
      end
    end
  end

  -- Fallback to vehicle config
  if currentVeh and currentVeh.configs and currentVeh.configs["Drag Times"] then
    return currentVeh.configs["Drag Times"].time_1_4
  end

  return 12
end

-- Generate opponents for bracket race mode
function C:generateBracketRaceOpponents(vehConfigs, count)
  local randomVehicles = {}

  if #vehConfigs == 0 then
    return randomVehicles
  end

  for i = 1, count do
    math.randomseed(os.time())
    local selectedConfig = vehConfigs[math.random(#vehConfigs)]
    local entry = self:createVehicleEntry(selectedConfig)
    entry.dial = (entry.dial - 0.5) -- Adjust dial for bracket race
    table.insert(randomVehicles, entry)
  end

  return randomVehicles
end

-- Generate opponents with similar dial times
function C:generateSimilarOpponents(vehConfigs, dial, count, currentVeh)
  local randomVehicles = {}
  local similarVehicles = {}

  -- Find vehicles with similar dial times
  for _, v in pairs(vehConfigs) do
    if v["Drag Times"] then
      local time = v["Drag Times"].time_1_4
      if time >= (dial - 0.5) and time < (dial + 0.1) then
        table.insert(similarVehicles, v)
      end
    end
  end

  -- Fallback to current vehicle config if no similar vehicles found
  if #similarVehicles == 0 and currentVeh and currentVeh.configs then
    table.insert(similarVehicles, currentVeh.configs)
  end

  if #similarVehicles == 0 then
    log("E", "", "No similar vehicles found")
    return randomVehicles
  end

  -- Generate random selection
  for i = 1, count do
    local selectedConfig = similarVehicles[math.random(#similarVehicles)]
    table.insert(randomVehicles, self:createVehicleEntry(selectedConfig))
  end

  return randomVehicles
end

function C:selectVehicle()
  local vehConfigs = self:filterValidVehicleConfigs()
  local dragData = gameplay_drag_dragBridge and gameplay_drag_dragBridge.getData() or nil
  local numberOfOpponents = self.pinIn.numberOfOpponents.value
  local randomVehicles = {}

  -- Handle bracket race mode
  if dragData and dragData.dragType == "bracketRace" then
    randomVehicles = self:generateBracketRaceOpponents(vehConfigs, numberOfOpponents)
  else
    -- Regular race mode - find similar vehicles
    local currentVeh = core_vehicles.getCurrentVehicleDetails()
    local dial = self:getPlayerDial(currentVeh)

    randomVehicles = self:generateSimilarOpponents(vehConfigs, dial, numberOfOpponents, currentVeh)
  end

  -- Fallback: use player vehicle with different colors if no vehicles generated
  if #randomVehicles == 0 then
    randomVehicles = self:getPlayerVehicleAsFallback(numberOfOpponents)
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
  self.pinOut.vehicleGroup.value = group
end

return _flowgraph_createNode(C)
