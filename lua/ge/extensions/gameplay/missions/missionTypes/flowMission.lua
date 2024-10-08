-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

-- This is called when a mission of this type is being created. Load files, initialize variables etc
function C:init()
  self.missionTypeLabel = "bigMap.missionLabels."..self.missionType
  self.progressKeyTranslations = {default = "missions.progressKeyLabels.default", custom = 'missions.progressKeyLabels.custom'}
  -- copy in the generic progress setup for this missiontype
  local setup = deepcopy(gameplay_missions_missions.getMissionProgressSetupData(self.missionType))
  for k, v in pairs(setup) do
  --  self[k] = v
  end
end

function C:getProgressKeyTranslation(progressKey)
  if self.progressKeyTranslations then
    return self.progressKeyTranslations[progressKey] or progressKey
  end
  return progressKey
end
function C:setupFlowgraphManager(fgFile, variables)
  local relativePath = self.missionFolder.."/"..fgFile
  local absolutePath = fgFile
  local path = FS:fileExists(relativePath) and relativePath or (FS:fileExists(absolutePath) and absolutePath or nil)
  if not path then
    log("E", "", "Unable to locate fgPath file for activity "..dumps(self.id)..", neither as relative nor absolute dir: "..dumps(fgFile))
    return true
  end
  -- load the flowgraph and set its variables
  self.mgr = core_flowgraphManager.loadManager(path)
  self.mgr.transient = true -- prevent flowgraph from re-strating flowgraphs after ctrl+L
  self.mgr.activity = self
  self.mgr.description = self.description or self.mgr.description
  self.mgr.name = self.name or self.mgr.name
  self.progress = self.progress or {}
  self.progress.attempts = self.progress.attempts or {}
  self.progressVariables = next(self.progress.attempts) and self.progress.attempts[#self.progress.attempts].data or {}
  if self.progressVariables.attempts then
    log("E", "", "Cannot use reserved word \"attempts\" as a progress variable name in activity "..dumps(self.id)..". Value: "..dumps(self.progressVariables.attempts))
    return true
  end
  for name, value in pairs(self.progressVariables) do
    if self.progress[name] ~= nil then
      value = self.progress[name] -- if any progress was saved, use self.progress value, instead of the default value at self.progressVariables
    end
    if self:addOrSetVariable(name, value) then
      return true
    end
  end
  for name, value in pairs(variables or {}) do
    if self.progressVariables[name] ~= nil then
      log("E", "", "Cannot use "..dumps(name).." from 'fgVariables', since it was already reserved for use by 'progressVariables': "..self.id)
      return true
    else
      if self:addOrSetVariable(name, value) then
        return true
      end
    end
  end
end

-- common settings that any mission type may use (vehicles, traffic, time of day, etc.)
function C:getCommonSettingsData()
  local data = {}

  if self.setupModules.vehicles.enabled then
    local values = {}
    local setupModule = self.setupModules.vehicles
    setupModule.vehicles = setupModule.vehicles or {}

    for i, v in ipairs(setupModule.vehicles) do
      -- this is temporary until a nice vehicle selection UI gets done
      if v.model then
        local vehModelConfig
        local model = core_vehicles.getModel(v.model).model
        if model and model.Name then
          vehModelConfig = model.Brand and model.Brand.." "..model.Name or model.Name
        else
          vehModelConfig = v.model
        end
        if not string.endswith(vehModelConfig, " ") then
          vehModelConfig = vehModelConfig.." "
        end

        --local config = v.config and core_vehicles.getModel(v.model).configs[v.config]
        --if config and config.Configuration then
          --vehModelConfig = vehModelConfig..config.Configuration
        --end

        table.insert(values, {l = vehModelConfig, v = i})
      end
    end

    local lastIdx = #values + 1
    if setupModule.includePlayerVehicle or lastIdx == 1 then
      table.insert(values, {l = 'Player Vehicle', v = lastIdx, type = 'player'})
    end

    local initIdx = (setupModule.includePlayerVehicle and setupModule.prioritizePlayerVehicle) and lastIdx or 1
    if values[1] then -- maybe should use values[2]
      table.insert(data, {
        key = 'setupModuleVehicles',
        label = 'ui.busRoute.vehicle',
        type = 'select',
        values = values,
        value = initIdx
      })
    end
  end

  if self.setupModules.traffic.enabled then
    table.insert(data, {
      key = 'setupModuleTraffic',
      label = 'missions.missions.general.userSettings.trafficEnabled',
      type = 'bool',
      value = self.setupModules.traffic.useTraffic
    })
  end

  --if self.setupModules.timeOfDay.enabled and self.setupModules.timeOfDay.enableUserTime then

  --end

  return data
end

-- apply common settings for the mission
function C:processCommonSettings(settings)
  self.setupModules.vehicles._selectionIdx = settings.setupModuleVehicles or 0
  self.setupModules.vehicles.usePlayerVehicle = (self.setupModules.vehicles.enabled and self.setupModules.vehicles.vehicles and not self.setupModules.vehicles.vehicles[self.setupModules.vehicles._selectionIdx]) and true or false
  self.setupModules.traffic.useTraffic = settings.setupModuleTraffic and true or false
end

function C:processUserSettings(settings)
  self.userSettings = settings
end

-- enables backwards compatibility for older missions
function C:setBackwardsCompatibility(keyAliases)
  keyAliases = keyAliases or {} -- aliases for mission variable names (because they may be different in various mission types)
  local playerModel, playerConfig, playerConfigPath
  if not self.setupModules.vehicles.enabled and self.missionTypeData[keyAliases.presetVehicleActive or "presetVehicleActive"] then
    self.setupModules.vehicles.enabled = true
    self.setupModules.vehicles.mode = "provided"
    playerModel = self.missionTypeData[keyAliases.playerModel or "playerModel"]
    playerConfig = self.missionTypeData[keyAliases.playerConfig or "playerConfig"]
    playerConfigPath = self.missionTypeData[keyAliases.playerConfigPath or "playerConfigPath"]
  end

  if self.setupModules.vehicles.mode then
    local hasPlayerVehicle = self.setupModules.vehicles.mode == "own" or self.setupModules.vehicles.mode == "choice"
    local prioritizePlayerVehicle = self.setupModules.vehicles.mode == "own"
    local paintName
    local useCustomConfig = false

    if self.setupModules.vehicles.mode ~= "own" and self.setupModules.vehicles.playerModel then
      playerModel = self.setupModules.vehicles.playerModel
      playerConfig = self.setupModules.vehicles.playerConfig
      playerConfigPath = self.setupModules.vehicles.playerConfigPath
      paintName = self.setupModules.vehicles.playerPaintName
      useCustomConfig = self.setupModules.vehicles.isCustomConfig
    end

    table.clear(self.setupModules.vehicles)
    self.setupModules.vehicles.enabled = true
    self.setupModules.vehicles.includePlayerVehicle = hasPlayerVehicle
    self.setupModules.vehicles.prioritizePlayerVehicle = prioritizePlayerVehicle
    self.setupModules.vehicles.vehicles = {}
    self.setupModules.vehicles._compatibility = true
    self.additionalAttributes.vehicle = nil

    if playerModel then
      table.insert(self.setupModules.vehicles.vehicles, {
        model = playerModel,
        config = playerConfig,
        configPath = playerConfigPath,
        paintName = paintName,
        useCustomConfig = useCustomConfig
      })
    end
  end

  if not self.additionalAttributes.vehicle then -- auto generates this attribute
    if not self.setupModules.vehicles.enabled then -- this assumes that the mission type will use the player vehicle
      self.additionalAttributes.vehicle = "own"
    else
      local vehicleExists = self.setupModules.vehicles.vehicles[1]
      if self.setupModules.vehicles.includePlayerVehicle then
        self.additionalAttributes.vehicle = vehicleExists and "choice" or "own"
      else
        self.additionalAttributes.vehicle = vehicleExists and "provided" or "own"
      end
    end
  end
end

-- when the activity starts.
function C:onStart()
  if not self.mgr then
    if self:setupFlowgraphManager(self.fgPath, self.fgVariables) then
      log("E", "", "There has been an error setting up the FG. See errors above. ("..dumps(self.id)..")")
      return true
    end
  end
  -- setup existing progress variables.
  for name, v in pairs(self.progressVariables or {}) do
    local value = v
    if self.progress[name] ~= nil then
      value = self.progress[name] -- if any progress was saved, use self.progress value, instead of the default value at self.progressVariables
    end
    if self:addOrSetVariable(name, value) then
      log("E", "", "Cannot set fg variable "..dumps(name).." for activity "..dumps(self.id).." to value: "..dumps(value))
    end
  end

  if self.userSettings then
    for name, value in pairs(self.userSettings) do
      if self:addOrSetVariable(name, value) then
        log("E", "", "Cannot set user setting variable "..dumps(name).." for activity "..dumps(self.id).." to value: "..dumps(value))
      end
    end
    self.userSettings = nil
  end

  -- start mgr and call first frame
  if self.mgr.runningState == 'stopped' then
    self.mgr:setRunning(true)
  end
  --self.mgr:broadcastCall('onStartActivity')
end

function C:onFlowgraphStateStarted(stateName, state, transData)
  if self.script and self.script.onFlowgraphStateStarted then
    self.script:onFlowgraphStateStarted(stateName, state, transData)
  end
end

function C:onFlowgraphStateStopped(stateName, state)
  if self.script and self.script.onFlowgraphStateStopped then
    self.script:onFlowgraphStateStopped(stateName, state)
  end
end

-- update each frame
function C:onUpdate(dtReal, dtSim, dtRaw)
  --self.mgr:broadcastCall('onUpdate', dtReal, dtSim, dtRaw)
  if self.script and self.script.onUpdate then
    self.script:onUpdate(dtReal, dtSim, dtRaw)
  end
end

function C:onStop(data)
  data = data or {}
  -- if not stopped, call last frame and stop mgr.
  if self.mgr and self.mgr.runningState ~= 'stopped' then
    --self.mgr:broadcastCall('onStopActivity')
    self.mgr:setRunning(false, data.stopInstant)
  end
  if data.abandoned then
    --TODO retrieve attempt data from flowgraph, use it in newAttempt
    local attempt = data.attempt or gameplay_missions_progress.newAttempt("abandoned")
    --gameplay_missions_progress.aggregateAttempt(self.id, attempt)
    --gameplay_missions_progress.saveMissionSaveData(self.id)
  end
  extensions.hook("onMissionProgressChanged", self)
end

function C:attemptAbandonMission()
  if self.mgr:hasNodeForHook('onRequestAbandon') then
    self.mgr:broadcastCall('onRequestAbandon')
    return true
  end
  return nil
end


function C:addOrSetVariable(name, value)
  log("D","","Setting Mission Variable: " .. name .. " --> " .. dumps(value))
  local t = type(value)
  if     t == "boolean"               then t = "bool"
  elseif t == "string"                then -- it's ok already
  elseif t == "number"                then -- it's ok already
  elseif t == "table" and #value == 3 then t = "vec3"
  elseif t == "table" and #value == 4 then t = "quat"
  else
    log("E", "", "Cannot add Mission Variable "..dumps(name).." for activity "..dumps(self.id)..": unable to find a usable type, given its value: "..dumps(value))
    return true
  end
  local mergeStrat = nil
  local fixedType = nil
  local undeletable = nil
  if self.mgr.variables:variableExists(name) then
    if not self.mgr.variables:changeBase(name, value) then -- modify value only
      log("E", "", "Cannot set Mission Variable "..dumps(name).." for activity "..dumps(self.id))
      return true
    end
  else
    log("W", "", "Cannot set Mission Variable "..dumps(name).." for activity "..dumps(self.id) .." - The variable does not exit in the FG.")
    --if not self.mgr.variables:addVariable(name, value, t, mergeStrat, fixedType, undeletable) then
    --  log("E", "", "Cannot add fg variable "..dumps(name).." for activity "..dumps(self.id))
    --  return true
    --end
  end
end

function C:retrieveProgressFromFlowgraph()
  for name,_ in pairs(self.progressVariables or {}) do
    local value, exists = self.mgr.variables:get(name)
    if exists then
      self.progress[name] = value
    else
      log("E", "", "Unable to read progresss variable "..dumps(name).." for activity: "..dumps(self.id))
    end
  end
end

local sortBtns = function(a,b)
  if a.order == b.order then
    return a.label < b.label
  else
    return a.order < b.order
  end
end
function C:getGameContextUiButtons()
  if not self.mgr then return end
  local results = self.mgr:broadcastCallReturn('onGatherGameContextUiButtons')
  local byId = {}
  for _, btn in ipairs(results) do
    if not byId[btn.id] or (btn.active and not byId[btn.id].active) then
      byId[btn.id] = btn
    end
  end
  table.clear(results)
  for id, btn in pairs(byId) do
    table.insert(results, btn)
  end
  table.sort(results, sortBtns)
  return results
end


return function(derivedClass, ...)
  local o = ... or {}
  setmetatable(o, C)
  C.__index = C
  o:init()
  for k, v in pairs(derivedClass) do
    o[k] = v
  end
  local init = o:init()
  return o, init
end
