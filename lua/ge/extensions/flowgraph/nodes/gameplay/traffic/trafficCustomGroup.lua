-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Generate Vehicle Group'
C.description = 'Generates vehicle group data, to be used with the Spawn Vehicle Group node. Available modes: "Parameters" or "Custom".'
C.color = ui_flowgraph_editor.nodeColors.traffic
C.icon = ui_flowgraph_editor.nodeIcons.traffic
C.category = 'provider'
C.dependencies = {'gameplay_traffic_trafficUtils'}
C.tags = {'spawn', 'vehicle', 'group', 'traffic', 'multispawn'}

C.pinSchema = {
  {dir = 'out', type = 'table', name = 'group', tableType = 'vehicleGroupData', description = 'Vehicle group data.'}
}

local modes = {settings = 'Parameters', custom = 'Custom'}
local paramsModesList = {'standard', 'simpleTraffic', 'simpleParked', 'fromSettings', 'fromWorld'}

function C:init()
  self.mode = 'settings'
  self.count = 0
  self:resetParams()
end

function C:resetParams()
  self.params = {mode = 'standard', useCars = true, useTrucks = false, useLargeTrucks = false, worldPlayer = false, worldTraffic = false}
end

function C:drawCustomProperties()
  -- mode select
  im.PushItemWidth(im.GetContentRegionAvailWidth())
  if im.BeginCombo('Mode', modes[self.mode]) then
    if im.Selectable1('Parameters##vehicleGroupNode', self.mode == 'settings') then
      self.mode = 'settings'
      self:updatePins(self.count, 0)
      self:resetParams()
    end
    if im.Selectable1('Custom##vehicleGroupNode', self.mode == 'custom') then
      self.mode = 'custom'
      self:updatePins(self.count, 1)
      self:resetParams()
    end
    im.EndCombo()
  end
  im.PopItemWidth()

  if self.mode == 'settings' then
    local val = im.IntPtr(arrayFindValueIndex(paramsModesList, self.params.mode) or 1)
    if im.RadioButton2('Standard Vehicles##vehicleGroupNode', val, im.Int(1)) then
      self.params.mode = paramsModesList[1]
    end
    if im.RadioButton2('Simple Traffic Cars##vehicleGroupNode', val, im.Int(2)) then
      self.params.mode = paramsModesList[2]
    end
    if im.RadioButton2('Simple Parked Cars##vehicleGroupNode', val, im.Int(3)) then
      self.params.mode = paramsModesList[3]
    end
    if im.RadioButton2('Copy from Main Traffic Settings##vehicleGroupNode', val, im.Int(4)) then
      self.params.mode = paramsModesList[4]
    end
    if im.RadioButton2('Copy from Spawned Vehicles##vehicleGroupNode', val, im.Int(5)) then
      self.params.mode = paramsModesList[5]
    end

    im.Separator()

    if self.params.mode == 'standard' then -- additional filters for standard mode
      local var = im.BoolPtr(self.params.useCars)
      if im.Checkbox('Cars##vehicleGroupNode', var) then
        self.params.useCars = var[0]
      end
      var = im.BoolPtr(self.params.useTrucks)
      if im.Checkbox('Small Trucks##vehicleGroupNode', var) then
        self.params.useTrucks = var[0]
      end
      var = im.BoolPtr(self.params.useLargeTrucks)
      if im.Checkbox('Large Trucks & Buses##vehicleGroupNode', var) then
        self.params.useLargeTrucks = var[0]
      end
    elseif self.params.mode == 'fromWorld' then
      local var = im.BoolPtr(self.params.worldPlayer)
      if im.Checkbox('Include Player Vehicle##vehicleGroupNode', var) then
        self.params.worldPlayer = var[0]
      end
      var = im.BoolPtr(self.params.worldTraffic)
      if im.Checkbox('Include Traffic##vehicleGroupNode', var) then
        self.params.worldTraffic = var[0]
      end
      im.TextUnformatted("Note: This will use the default vehicle as a fallback.")
    end
  else
    -- select amount of pins
    local count = im.IntPtr(self.count)
    if im.InputInt('Count', count) then
      self:updatePins(self.count, math.max(1, count[0]))
    end
  end
end

function C:onStateStarted()
  self.done = false
end

function C:updatePins(old, new)
  if new < old then
    for i = old, new + 1, -1 do
      for _, link in pairs(self.graph.links) do
        if link.targetPin == self.pinInLocal['model_'..i]then
          self.graph:deleteLink(link)
        end
        if link.targetPin == self.pinInLocal['config_'..i] then
          self.graph:deleteLink(link)
        end
      end
      self:removePin(self.pinInLocal['model_'..i])
      self:removePin(self.pinInLocal['config_'..i])
    end
  else
    for i = old + 1, new do
      -- direction, type, name, default, description, autoNumber
      self:createPin('in', 'string', 'model_'..i)
      self:createPin('in', {'string', 'table'}, 'config_'..i)
    end
  end
  self.count = new
end

function C:_executionStarted()
  self.done = false
end

function C:buildGroup() -- builds vehicle group from pin inputs
  self.group.name = 'Custom Group'
  self.group.type = 'custom'
  self.group.data = {}
  for i = 1, self.count do
    local model, config = self.pinIn['model_'..i].value, self.pinIn['config_'..i].value
    if model then
      table.insert(self.group.data, {model = model, config = config})
    end
  end
end

function C:generateGroup() -- builds vehicle group from settings
  self.group.name = 'Custom Group'
  self.group.type = 'generator'
  self.group.generator = deepcopy(self.params)
  self.group.generator.allMods = true -- assuming all mods are allowed
  self.group.generator.allConfigs = true
  self.group.generator.minPop = 10

  if self.params.mode == 'fromSettings' then
    self.group.data = gameplay_traffic_trafficUtils.createTrafficGroup(20)
  elseif self.params.mode == 'fromWorld' then
    self.group.data = core_multiSpawn.spawnedVehsToGroup(not self.params.worldPlayer, not self.params.worldTraffic)
    if not self.group.data[1] then
      self.group.data = core_multiSpawn.spawnedVehsToGroup(false, not self.params.worldTraffic) -- force fallback to player vehicle
    end
    for _, v in ipairs(self.group.data) do -- clear paint data
      v.paint, v.paint2, v.paint3 = nil, nil, nil
      v.paintName, v.paintName2, v.paintName3 = nil, nil, nil
    end
  else
    self.group.generator = tableMerge(self.group.generator, gameplay_traffic_trafficUtils.getBaseGroupParams())
    local filters = self.group.generator.filters
    if self.params.mode == 'simpleTraffic' then
      filters.Type = {proptraffic = 1}
    elseif self.params.mode == 'simpleParked' then
      filters.Type = {propparked = 1}
    elseif self.params.mode == 'standard' then
      filters.Type = {
        car = self.params.useCars and 1 or 0,
        truck = (self.params.useTrucks or self.params.useLargeTrucks) and 1 or 0,
        other = 0
      }
      if self.params.useLargeTrucks then
        filters["Derby Class"] = {["heavy truck"] = 1, other = 0} -- e.g. citybus, us_semi
      else
        filters["Derby Class"] = {["heavy truck"] = 0, other = 1}
      end
    end

    self.group.data = core_multiSpawn.createGroup(20, self.group.generator)
  end
end

function C:work()
  -- only set out pin once per execution.
  if not self.done then
    self.group = {}
    if self.mode == 'settings' then
      self:generateGroup()
    else
      if not self.pinIn['model_'..self.count].value then return end -- delay until value is ready, just in case
      self:buildGroup()
    end

    if not self.group.data or not self.group.data[1] then -- group data needs to exist for output
      log('I', 'trafficCustomGroup', 'Empty vehicle group data, now creating default data...')
      self.group.data = {{model = 'pickup'}}
    end
    self.pinOut.group.value = self.group
    self.done = true
  end
end

function C:_onSerialize(res)
  res.mode = self.mode

  if self.mode == 'settings' then
    res.params = self.params
  else
    res.count = self.count
  end
end

function C:_onDeserialized(data)
  self.mode = data.mode
  if self.mode == 'file' then
    log('W', 'trafficCustomGroup', 'File mode is no longer supported for this node; please use File Vehicle Group')
    self.mode = 'settings'
  end
  if self.mode == 'settings' then
    self.params = data.params
    if not self.params or self.params.auto then
      log('W', 'trafficCustomGroup', 'Outdated settings found, resetting parameters to default')
      self:resetParams()
    end
  else
    self:updatePins(self.count, data.count)
  end
end

return _flowgraph_createNode(C)