-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Vehicle Selector'
C.color = ui_flowgraph_editor.nodeColors.ui
C.icon = ui_flowgraph_editor.nodeIcons.ui
C.description = "Opens a start screen (via the ui module) with a vehicle selector for an opponent."
C.behaviour = {singleActive = true}
C.pinSchema = {
  {dir = 'in', type = 'flow', name = 'flow', description = 'Inflow for this node.'},
  {dir = 'in', type = 'flow', name = 'reset', description = 'Resets this node.', impulse = true},
  {dir = 'in', type = 'string', name = 'title', description = 'Title shown on the start screen.'},
  {dir = 'in', type = {'string', 'table'}, tableType = 'multiTranslationObject', name = 'text', description = 'Description text shown on the start screen.'},
  {dir = 'in', type = 'string', name = 'startButtonText', description = 'Text for the start button.', hidden = true},
  {dir = 'in', type = 'string', name = 'changeOpponentLabel', description = 'Label for the change-opponent button (dynamic, coming from lua).', default = 'Change Opponent'},
  {dir = 'in', type = 'string', name = 'abandonLabel', description = 'Label for the abandon button (dynamic, coming from lua).', default = 'Abandon'},
  {dir = 'in', type = 'bool', name = 'saveSelection', description = 'If true, the last selected vehicle is kept across restarts. If false, it resets to the default (the player vehicle) on every restart.', default = false, hardcoded = true},

  {dir = 'out', type = 'flow', name = 'flow', description = 'Outflow once the start button is pressed.'},
  {dir = 'out', type = 'flow', name = 'exit', description = 'Flows when the abandon button is pressed.'},
  {dir = 'out', type = 'string', name = 'model', description = 'The model of the selected opponent vehicle.'},
  {dir = 'out', type = 'string', name = 'config', description = 'The config of the selected opponent vehicle.'},
  {dir = 'out', type = {'color', 'string'}, name = 'color', description = 'The color of the selected opponent vehicle.'},
  {dir = 'out', type = 'number', name = 'dial', hidden = true, description = 'The drag race time dial of the selected opponent vehicle.'},
}
C.dependencies = {'core_input_bindings'}

local function flattenSpecValue(value)
  if type(value) == 'table' then
    local parts = {}
    for _, seg in ipairs(value) do
      if type(seg) == 'table' and seg.text ~= nil then
        table.insert(parts, tostring(seg.text))
      end
    end
    return table.concat(parts, " ")
  end
  return tostring(value)
end

local function getVehicleDial(model, config)
  if not model or not config or config == "" then return 12 end
  local okCfg, cfg = pcall(core_vehicles.getConfig, model, config)
  if okCfg and cfg and cfg["Drag Times"] then
    return cfg["Drag Times"].time_1_4 or 12
  end
  return 12
end

local function getVehicleColor(model, config, additionalData)
  if not model then return nil end
  local okModel, modelData = pcall(core_vehicles.getModel, model)
  if not okModel or not modelData or not modelData.model then return nil end
  local modelDetails = modelData.model
  local configDetails = (config and config ~= "" and modelData.configs and modelData.configs[config]) or nil

  local paintName = (additionalData and additionalData.paint)
    or (configDetails and configDetails.defaultPaintName1)
    or modelDetails.defaultPaintName1

  local paint = paintName and modelDetails.paints and modelDetails.paints[paintName]
  if not paint or not paint.baseColor then return nil end

  local color = {}
  for _, c in ipairs(paint.baseColor) do
    table.insert(color, tostring(c))
  end
  return color
end

local function getVehicleDisplayData(model, config)
  if not model then return nil end
  local ok, modelData = pcall(core_vehicles.getModel, model)
  if not ok or not modelData or not modelData.model then return nil end
  local modelDetails = modelData.model
  local configDetails = {}
  if config and config ~= "" then
    local okCfg, cfg = pcall(core_vehicles.getConfig, model, config)
    if okCfg and cfg then configDetails = cfg end
  end

  local data = {
    model = model,
    config = config,
    name = configDetails.Name or modelDetails.Name or model,
    thumbnail = configDetails.preview or modelDetails.preview,
    stats = {},
  }

  if not ui_vehicleSelector_vehicleSpecifications then
    extensions.load('ui_vehicleSelector_vehicleSpecifications')
  end
  if ui_vehicleSelector_vehicleSpecifications and ui_vehicleSelector_vehicleSpecifications.makeSpec then
    local rawStats = {}
    for _, key in ipairs({'Power', 'Weight', 'Top Speed'}) do
      ui_vehicleSelector_vehicleSpecifications.makeSpec(modelDetails, configDetails, key, rawStats)
    end
    for _, stat in ipairs(rawStats) do
      table.insert(data.stats, {label = stat.key, value = flattenSpecValue(stat.value)})
    end
  end

  return data
end

function C:init()
  self.built = false
  self.done = false
  self.exited = false
  self._needsRebuild = false
  self._selectedVehData = nil
end

-- The last selection is stored on the flowgraph manager so it is shared across every
-- Vehicle Selector node in the project and survives restarts (used when saveSelection is on).
function C:getSavedVehData()
  return self.mgr and self.mgr._vehicleSelectorSavedVeh or nil
end

function C:setSavedVehData(vehData)
  if self.mgr then
    self.mgr._vehicleSelectorSavedVeh = vehData
  end
end

function C:_executionStarted()
  for _, p in pairs(self.pinOut) do
    p.value = false
  end
  self.built = false
  self.done = false
  self.exited = false
  self._needsRebuild = false
  self._selectedVehData = nil
end

function C:_executionStopped()
  self:closeDialogue()
  self.built = false
  self.done = false
  self.exited = false
  self._needsRebuild = false
  self._selectedVehData = nil
end

function C:onClientEndMission()
  self:closeDialogue()
end

function C:reset()
  self.built = false
  self.done = false
  self.exited = false
  self._needsRebuild = false
  for _, pn in pairs(self.pinOut) do
    pn.value = false
  end
end

function C:closeDialogue()
  if self.built then
    guihooks.trigger('ChangeState', 'play')
    if self.mgr.modules.ui then
      self.mgr.modules.ui.uiLayout = nil
    end
  end
end

function C:getSelectedVehicleDisplayData()
  if not self._selectedVehData then return nil end
  return getVehicleDisplayData(self._selectedVehData.model, self._selectedVehData.config)
end

function C:getDefaultVehicle()
  local ok, details = pcall(core_vehicles.getCurrentVehicleDetails)
  if not ok or not details or not details.current or not details.current.key then
    return nil
  end
  return {model = details.current.key, config = details.current.config_key}
end

function C:buildScreen()
  local ui = self.mgr.modules.ui
  if not ui then
    log('E', 'vehicleSelector', 'ui module not available on this flowgraph manager.')
    return
  end

  ui:startUIBuilding('startScreen', self)
  ui:addHeader({header = self.pinIn.title.value or self.graph.mgr.name})
  ui:setStartButtonText(self.pinIn.startButtonText.value or "ui.scenarios.start.start")

  local text = self.pinIn.text.value
  if (type(text) == 'table' and text.txt == '') or text == '' then
    text = nil
  end
  if text then
    ui:addUIElement({
      type = 'textPanel',
      header = self.pinIn.title.value or "",
      text = text,
      pages = {main = true},
    })
  end

  ui:addUIElement({
    type = 'vehicleSelector',
    header = self.pinIn.title.value or "",
    vehicle = self:getSelectedVehicleDisplayData(),
    pages = {main = true},
  })

  ui:addScreenButton(function()
    self:requestChangeOpponent()
  end, {
    label = self.pinIn.changeOpponentLabel.value or "Change Opponent",
    keepLayout = true,
    main = false,
  })

  ui:addScreenButton(function()
    self:abandonFromUi()
  end, {
    label = self.pinIn.abandonLabel.value or "Abandon",
    main = false,
  })

  ui:finishUIBuilding()
end

function C:requestChangeOpponent()
  if not ui_vehicleSelector_general then
    extensions.load('ui_vehicleSelector_general')
  end
  if not (ui_vehicleSelector_general and ui_vehicleSelector_general.openVehicleSelectorForChallenge) then
    log('W', 'vehicleSelector', 'ui_vehicleSelector_general.openVehicleSelectorForChallenge not available.')
    return
  end

  ui_vehicleSelector_general.openVehicleSelectorForChallenge(function(model, config, additionalData)
    if model then
      self._selectedVehData = {model = model, config = config, additionalData = additionalData}
      self:setSavedVehData(self._selectedVehData)
    end
    self._needsRebuild = true
  end)
end

function C:startFromUi()
  self.done = true
  self:closeDialogue()
end

function C:abandonFromUi()
  self.exited = true
  self:closeDialogue()
end

function C:work()
  if self.pinIn.reset.value then
    self:reset()
    return
  end

  if not self.pinIn.flow.value then
    self.pinOut.flow.value = false
    self.pinOut.exit.value = false
    return
  end

  if not self.built then
    if not self._selectedVehData then
      local saved = self:getSavedVehData()
      if self.pinIn.saveSelection.value and saved then
        self._selectedVehData = saved
      else
        self._selectedVehData = self:getDefaultVehicle()
      end
    end
    self:buildScreen()
    self.built = true
  elseif self._needsRebuild and not self.done and not self.exited then
    self._needsRebuild = false
    self:buildScreen()
  end

  if self._selectedVehData then
    self.pinOut.model.value = self._selectedVehData.model
    self.pinOut.config.value = self._selectedVehData.config or ""
    self.pinOut.color.value = getVehicleColor(self._selectedVehData.model, self._selectedVehData.config, self._selectedVehData.additionalData)
    self.pinOut.dial.value = getVehicleDial(self._selectedVehData.model, self._selectedVehData.config)
  else
    self.pinOut.model.value = nil
    self.pinOut.config.value = nil
    self.pinOut.color.value = nil
    self.pinOut.dial.value = nil
  end

  self.pinOut.flow.value = self.done
  self.pinOut.exit.value = self.exited
end

return _flowgraph_createNode(C)
