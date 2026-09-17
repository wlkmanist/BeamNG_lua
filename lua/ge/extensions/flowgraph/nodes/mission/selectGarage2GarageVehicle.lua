-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Select Garage Vehicle'
C.description = 'Selects a random vehicle config from available options with used config tracking.'
C.category = 'once_instant'
C.author = 'BeamNG'

C.pinSchema = {
  {dir = 'out', type = 'flow', name = 'loaded', default = false, description= 'Triggers once after a vehicle is selected.', impulse = true},

  {dir = 'out', type = 'string', name = 'model', description = 'Selected vehicle model'},
  {dir = 'out', type = 'string', name = 'config', description = 'Selected vehicle config'},
  {dir = 'out', type = 'string', name = 'name', description = 'Formatted vehicle name for UI display'},
}
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle
C.tags = {}

function C:init()
  self.selectedModel = nil
  self.selectedConfig = nil
  self.selectedName = nil
  self.state = 1
  self.usedConfigs = {} -- Track used configs as {[model] = {[config] = true}}

  self.pinOut.loaded.value = false

  self.pinOut.model.value = nil
  self.pinOut.config.value = nil
  self.pinOut.name.value = nil
end

function C:_executionStarted()
  -- Don't reset used lists, only reset state and outputs
  self.selectedModel = nil
  self.selectedConfig = nil
  self.selectedName = nil
  self.state = 1

  self.pinOut.loaded.value = false

  self.pinOut.model.value = nil
  self.pinOut.config.value = nil
  self.pinOut.name.value = nil
end

function C:resetData()
  -- Don't reset used lists - keep them persistent
  self.selectedModel = nil
  self.selectedConfig = nil
  self.selectedName = nil
  self.state = 1

  self.pinOut.loaded.value = false

  self.pinOut.model.value = nil
  self.pinOut.config.value = nil
  self.pinOut.name.value = nil
end

function C:workOnce()
  self:resetData()
end

-- Get all available configs from vehicleOptions (flat list format)
local function getAllAvailableConfigs(vehicleOptions)
  local configs = {}
  if not vehicleOptions then
    return configs
  end

  -- vehicleOptions is a flat list: [{model, config, name}, ...]
  for _, cfg in ipairs(vehicleOptions) do
    if cfg.model and cfg.config then
      table.insert(configs, {
        model = cfg.model,
        config = cfg.config,
        name = cfg.name or cfg.config
      })
    end
  end

  return configs
end

function C:work()
  if self.state == 1 then
    -- Get mission instance
    local mission = self.mgr.activity
    if not mission then
      log("E","SelectGarage2GarageVehicle","No mission instance available")
      return
    end

    -- Ensure vehicleOptions are generated
    if not mission.vehicleOptions then
      if mission.generateVehicleOptions then
        mission:generateVehicleOptions()
      else
        log("E","SelectGarage2GarageVehicle","Mission does not have vehicleOptions or generateVehicleOptions method")
        return
      end
    end

    if not mission.vehicleOptions or #mission.vehicleOptions == 0 then
      log("E","SelectGarage2GarageVehicle","No vehicle options available")
      return
    end

    -- Get all available configs
    local allConfigs = getAllAvailableConfigs(mission.vehicleOptions)

    if #allConfigs == 0 then
      log("E","SelectGarage2GarageVehicle","No configs found in vehicle options")
      return
    end

    -- Check if all configs are used, reset if so
    local totalUsed = 0
    for _, modelConfigs in pairs(self.usedConfigs) do
      for _ in pairs(modelConfigs) do
        totalUsed = totalUsed + 1
      end
    end
    if #allConfigs == totalUsed then
      self.usedConfigs = {}
      -- Change random seed for more randomness
      math.randomseed(os.time())
      log("D","","Cleared used configs. Can now use all of them again")
    end

    -- Filter out used configs
    local availableConfigs = {}
    for _, configData in ipairs(allConfigs) do
      if not self.usedConfigs[configData.model] or not self.usedConfigs[configData.model][configData.config] then
        table.insert(availableConfigs, configData)
      end
    end

    if #availableConfigs == 0 then
      log("E","SelectGarage2GarageVehicle","No available configs")
      return
    end

    -- Select random config
    local selectedIndex = math.random(1, #availableConfigs)
    local selected = availableConfigs[selectedIndex]

    self.selectedModel = selected.model
    self.selectedConfig = selected.config
    self.selectedName = selected.name or (selected.model .. "/" .. selected.config)

    -- Track used config
    if not self.usedConfigs[selected.model] then
      self.usedConfigs[selected.model] = {}
    end
    self.usedConfigs[selected.model][selected.config] = true

    -- Setup out pin values
    self.pinOut.model.value = self.selectedModel
    self.pinOut.config.value = self.selectedConfig
    self.pinOut.name.value = self.selectedName

    self.pinOut.loaded.value = true

    log("I","",string.format("G2G Vehicle: %s/%s (%s)",
      self.pinOut.model.value, self.pinOut.config.value,
      self.pinOut.name.value))
    self.state = 2
  elseif self.state == 2 then
    self.pinOut.loaded.value = false
  end
end

return _flowgraph_createNode(C)

