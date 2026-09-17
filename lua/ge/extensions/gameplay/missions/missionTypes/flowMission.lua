-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local defaultPreviewCache = {

}

local missionDefaultEnvironmentTimeValue = "__missionDefaultEnvironmentTime"

local function resolveEnvironmentTime(environment, state)
  if type(environment) ~= "table" then return nil end

  if environment.normalizedTime ~= nil then
    local time = core_environment.getTimeOfDayValueForNormalizedTime(environment.normalizedTime, state)
    if time ~= nil then return time end
  end

  local time = environment.time
  if type(time) ~= "string" then
    return time
  end
  return core_environment.getSolarTimeOfDayValue(time, state)
end

local function getMissionEnvironmentTimeState(environment)
  local state = deepcopy(core_environment.getTimeOfDay() or {})
  local resolvedTime = resolveEnvironmentTime(environment, state)
  if resolvedTime ~= nil and resolvedTime ~= -1 then
    state.time = resolvedTime
  end
  return state
end

-- This is called when a mission of this type is being created. Load files, initialize variables etc
function C:init()
  self.missionTypeLabel = "bigMap.missionLabels."..self.missionType
  self.progressKeyTranslations = {default = "missions.progressKeyLabels.default", custom = 'missions.progressKeyLabels.custom'}

  self.defaultPreviewFile = "/gameplay/missionTypes/"..self.missionType.."/defaultPreview.jpg"
  local exists = defaultPreviewCache[self.defaultPreviewFile]
  if exists == nil then
    exists = FS:fileExists(self.defaultPreviewFile)
    defaultPreviewCache[self.defaultPreviewFile] = exists
  end
  if not exists then
    self.defaultPreviewFile = nil
  end
  -- copy in the generic progress setup for this missiontype
  local setup = deepcopy(gameplay_missions_missions.getMissionProgressSetupData(self.missionType))
  for k, v in pairs(setup) do
  --  self[k] = v
  end
  self.ignoreUserSettingsKeyForActiveStars = {
    setupModuleEnvironmentTime = true,
    useGroundmarkers = true,
    missionVehicleClass = true,
    shuffleGroup = true,
  }
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

-- common settings that any mission type may use (vehicles, traffic, environment, etc.)
function C:getCommonSettingsData()
  local data = {}

  if self.setupModules.vehicles.enabled then
    local values = {}
    local setupModule = self.setupModules.vehicles
    setupModule.vehicles = setupModule.vehicles or {}

    extensions.load("gameplay_vehiclePerformance")
    for i, v in ipairs(setupModule.vehicles) do
      local model = core_vehicles.getModel(v.model or "").model
      if model then
        local vehModelConfig
        if model.Name then
          vehModelConfig = model.Brand and model.Brand.." "..model.Name or model.Name
        else
          vehModelConfig = v.model
        end
        if not string.endswith(vehModelConfig, " ") then
          vehModelConfig = vehModelConfig.." "
        end

        local config = v.config and core_vehicles.getModel(v.model).configs[v.config]
        local thumb = nil

        if config and config.Configuration then
          --vehModelConfig = vehModelConfig..config.Configuration
          thumb = config.preview
        end

        local vehicleClass = gameplay_vehiclePerformance and gameplay_vehiclePerformance.getClassFromConfig(v.model, v.config) or nil
        table.insert(values, {l = vehModelConfig, v = i, thumb = thumb, vehicleClass = vehicleClass})
      end
    end

    local lastIdx = #values + 1
    if setupModule.includePlayerVehicle or lastIdx == 1 then
      local thumbnail = career_career.isActive() and career_modules_inventory and career_modules_inventory.getVehicleThumbnail(career_modules_inventory.getCurrentVehicle())
      thumbnail = thumbnail or gameplay_missions_missions.getNoVehicleThumbFilepath()
      table.insert(values, {l = 'missions.missions.general.userSettings.playerVehicle', v = lastIdx, type = 'player', thumb = thumbnail})
    end
    local allowCustom = setupModule.includePlayerVehicle and not self.careerSetup.showInCareer
    -- add a custom vehicle option
    -- disable custom vehicles for now
    if allowCustom and false then
      table.insert(values, {l = 'Custom', v = lastIdx + 1, type = 'custom', thumb = gameplay_missions_missions.getNoVehicleThumbFilepath(), viaUserSettingsKey = 'setupModuleVehiclesCustom'})
      table.insert(data, {
        key = 'setupModuleVehiclesCustom',
        label = 'Hidden',
        type = 'hidden',
        value = {model = "unselected", config = "unselected"}
      })
    end

    -- Default selection rules live in gameplay_vehiclePerformance.getDefaultMissionVehicleSpec
    -- so the UI (mission details / big map) and this settings panel stay in sync.
    local defaultSpec = gameplay_vehiclePerformance and gameplay_vehiclePerformance.getDefaultMissionVehicleSpec(setupModule)
    local initIdx = (defaultSpec and defaultSpec.kind == "player") and lastIdx or 1
    if values[1] then -- maybe should use values[2]
      table.insert(data, {
        key = 'setupModuleVehicles',
        label = 'ui.busRoute.vehicle',
        type = 'select',
        values = values,
        value = initIdx,
        currentOption = values[initIdx],
        isVehicleSelector = true,
        allowCustom = allowCustom,
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

  if self.setupModules.environment.enabled then
    if self.setupModules.environment.todUserSetting then
      local defaultValue = self.setupModules.environment.normalizedTime ~= nil
        and missionDefaultEnvironmentTimeValue
        or self.setupModules.environment.time
      local values = {{l = "ui.common.default", v = defaultValue}}
      for _, option in ipairs(core_environment.getSolarTimeOfDayOptions(getMissionEnvironmentTimeState(self.setupModules.environment))) do
        table.insert(values, {l = option.label, v = option.key})
      end

      table.insert(data, {
        key = 'setupModuleEnvironmentTime',
        label = 'missions.missions.general.userSettings.timeOfDay',
        type = 'select',
        values = values,
        value = defaultValue,
        currentOption = values[1]
      })
    end

    -- weather user setting can go here
  end

  return data
end

function C:setPreviewsForCustomVehicles(userSettings)
  for _, s in ipairs(userSettings or {}) do
    if s.type == "select" and s.isVehicleSelector then
      for _, v in ipairs(s.values) do
        if v.type == "custom" and v.viaUserSettingsKey == 'setupModuleVehiclesCustom' then
          -- get the via setting
          local viaSetting = nil
          for _, l in ipairs(userSettings) do
            if l.key == v.viaUserSettingsKey then
              viaSetting = l
              break
            end
          end
          if viaSetting.value.model == "unselected" or viaSetting.value.config == "unselected" or not viaSetting.value.model or not viaSetting.value.config then
            v.thumb = gameplay_missions_missions.getNoVehicleThumbFilepath()
            v.l = "Custom: (None Selected)"
            v.vehicleClass = nil
            goto continue
          end
          local model = core_vehicles.getModel(viaSetting.value.model or "").model
          if model then

            local vehModelConfig
            if model.Name then
              vehModelConfig = model.Brand and model.Brand.." "..model.Name or model.Name
            else
              vehModelConfig = viaSetting.value.model
            end
            if not string.endswith(vehModelConfig, " ") then
              vehModelConfig = vehModelConfig.." "
            end

            local config = viaSetting.value.config and core_vehicles.getModel(viaSetting.value.model).configs[viaSetting.value.config]
            local thumb = nil

            if config and config.Configuration then
              --vehModelConfig = vehModelConfig..config.Configuration
              thumb = config.preview
            end
            v.thumb = thumb
            v.l = "Custom: "..vehModelConfig
            extensions.load("gameplay_vehiclePerformance")
            v.vehicleClass = gameplay_vehiclePerformance and gameplay_vehiclePerformance.getClassFromConfig(viaSetting.value.model, viaSetting.value.config) or nil
          end
          break
        end
        ::continue::
      end
      s.currentOption = s.values[s.value]
    end
  end
end

-- apply common settings for the mission
function C:processCommonSettings(flatSettings)
  if gameplay_missions_missionManager.getForegroundMissionId() then
    log("E","","called processCommonSettings during mission active! This shouldnt happen.")
    print(debug.tracesimple())
  end
  local settings = self:getUserSettingsData() or {}
  self.setupModules.vehicles._customVehicle = nil
  local viaKey = nil
  for _, s in ipairs(settings) do
    if s.key == 'setupModuleVehicles' then
      if s.values[flatSettings.setupModuleVehicles] and s.values[flatSettings.setupModuleVehicles].type == "custom" then
        viaKey = s.values[flatSettings.setupModuleVehicles].viaUserSettingsKey
      end
    end
  end
  if viaKey then
    self.setupModules.vehicles._customVehicle = flatSettings[viaKey]
  end

  self.setupModules.vehicles._selectionIdx = flatSettings.setupModuleVehicles or 0
  self.setupModules.vehicles.usePlayerVehicle = (self.setupModules.vehicles.enabled and self.setupModules.vehicles.vehicles and not self.setupModules.vehicles.vehicles[self.setupModules.vehicles._selectionIdx]) and true or false
  self.setupModules.vehicles.useCustomConfig = self.setupModules.vehicles._customVehicle ~= nil
  self.setupModules.traffic.useTraffic = flatSettings.setupModuleTraffic and true or false
  if flatSettings.setupModuleEnvironmentTime ~= nil and flatSettings.setupModuleEnvironmentTime ~= missionDefaultEnvironmentTimeValue then
    self.setupModules.environment.time = flatSettings.setupModuleEnvironmentTime
    self.setupModules.environment.normalizedTime = nil
  end
end

function C:processUserSettings(settings)
  self.userSettings = settings
end

-- enables backwards compatibility for older missions
function C:setBackwardsCompatibility(keyAliases)
  keyAliases = keyAliases or {} -- aliases for mission variable names (because they may be different in various mission types)
  local playerModel, playerConfig, playerConfigPath
  if not self.setupModules.vehicles.enabled and self.missionTypeData[keyAliases.presetVehicleActive or "presetVehicleActive"] then -- old flowgraph variables
    self.setupModules.vehicles.enabled = true
    self.setupModules.vehicles.mode = "provided"
    playerModel = self.missionTypeData[keyAliases.playerModel or "playerModel"]
    playerConfig = self.missionTypeData[keyAliases.playerConfig or "playerConfig"]
    playerConfigPath = self.missionTypeData[keyAliases.playerConfigPath or "playerConfigPath"]
  end

  if self.setupModules.vehicles.mode then -- old player vehicle setup modes
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
    self.setupModules.vehicles._compatibility = true -- DEVS: use this flag whenever major categories are added or changed in setup modules
    self.additionalAttributes.vehicle = nil

    if playerModel then -- include the player vehicle info in the vehicles list
      table.insert(self.setupModules.vehicles.vehicles, {
        model = playerModel,
        config = playerConfig,
        configPath = playerConfigPath,
        paintName = paintName,
        useCustomConfig = useCustomConfig
      })
    end
  end

  if type(self.setupModules.timeOfDay) == "number" then
    self.setupModules.timeOfDay = {enabled = true, time = self.setupModules.timeOfDay}
  end

  if self.setupModules.timeOfDay and self.setupModules.timeOfDay.enabled then -- old time of day setup module
    local oldTime = self.setupModules.timeOfDay.time or 0
    self.setupModules.timeOfDay = nil

    self.setupModules.environment = {enabled = true}
    self.setupModules.environment.time = oldTime
    self.setupModules.environment.timeScale = 0
    self.setupModules.environment.windSpeed = 0
    self.setupModules.environment.windDirAngle = 0
    self.setupModules.environment.fogDensity = 0
    self.setupModules.environment._compatibility = true
  end

  if self.setupModules.environment and self.setupModules.environment.enabled and not self.setupModules.environment.cloudCover then
    self.setupModules.environment.cloudCover = 0
    self.setupModules.environment.cloudWindSpeed = 0
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

function C:getEntryFee(userSettings)
  local entryFee = self.careerSetup.entryFee or {}
  if entryFee[1] then
    local flat = {}
    for _, e in ipairs(entryFee) do
      flat[e.attributeKey] = e.rewardAmount
    end
    entryFee = flat
  end
  return next(entryFee) and entryFee or nil
end
function C:getDynamicStarReward(key, userSettings) end

-- when the activity starts.
function C:onStart()
  gameplay_missions_missions.logMissionIssues(self)

  if self.onPreStart then
    self:onPreStart()
  end
  if not self.mgr then
    local tempVariables = deepcopy(self.fgVariables)

    for k, v in pairs(self.oneOffVariables or {}) do
      tempVariables[k] = v
    end
    self.oneOffVariables = nil

    if self.preprocessMissionTypeData then
      tempVariables = self:preprocessMissionTypeData(tempVariables)
    end

    local fgPath = self.fgPath

    if self.getFgPath then
      fgPath = self:getFgPath()
    end

    if self:setupFlowgraphManager(fgPath, tempVariables) then
      log("E", "", "There has been an error setting up the FG. See errors above. ("..dumps(self.id)..")")
      return true
    end
  end

  -- if not self.mgr then
  --   if self:setupFlowgraphManager(self.fgPath, self.fgVariables) then
  --     log("E", "", "There has been an error setting up the FG. See errors above. ("..dumps(self.id)..")")
  --     return true
  --   end
  -- end
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

  self.lastUserSettings = {}
  if self.userSettings then
    for name, value in pairs(self.userSettings) do
      if self:addOrSetVariable(name, value) then
        log("E", "", "Cannot set user setting variable "..dumps(name).." for activity "..dumps(self.id).." to value: "..dumps(value))
      end
    end
    self.lastUserSettings = deepcopy(self.userSettings)
    self.userSettings = nil
  end

  -- start mgr and call first frame
  if self.mgr.runningState == 'stopped' then
    self.mgr:setRunning(true)
  end
  --self.mgr:broadcastCall('onStartActivity')
  if self.script and self.script.onStart then
    self.script:onStart()
  end
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

function C:onMissionScreenReady(mode)
  if self.script and self.script.onMissionScreenReady then
    self.script:onMissionScreenReady(mode)
  end

  if mode == 'startScreen' and self.setupModules.environment and self.setupModules.environment.timeScale > 0 then -- if world time passed by, reset it here
    local timeScale = self.setupModules.environment.timeScale
    local tod = {
      time = resolveEnvironmentTime(self.setupModules.environment, core_environment.getTimeOfDay()),
      play = (timeScale or 0) > 0,
    }
    if (timeScale or 0) > 0 then tod.dayLength = 1800 / timeScale end
    core_environment.setTimeOfDay(tod)
  end
end

-- update each frame
function C:onUpdate(dtReal, dtSim, dtRaw)
  --self.mgr:broadcastCall('onUpdate', dtReal, dtSim, dtRaw)
  if self.script and self.script.onUpdate then
    self.script:onUpdate(dtReal, dtSim, dtRaw)
  end

  if self.setupModules.environment and self.setupModules.environment._windVec then
    local wind = self.setupModules.environment._windVec

    for _, veh in ipairs(getAllVehicles()) do
      if veh:isReady() then
        veh:queueLuaCommand("obj:setWind("..string.format('%2f, %2f, %2f', wind.x, wind.y, wind.z)..")") -- wind gets applied every frame
      end
    end
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
  if self.script and self.script.onStop then
    self.script:onStop()
  end

  if self.onPostStop then
    self:onPostStop()
  end
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
    log("D", "", "  Ignoring Mission Variable "..dumps(name).." for activity "..dumps(self.id) .." - The variable does not exist in the FG.")
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

function C:getRules()
  local pages = {}
  local rulesFiles = {}
  for _, layer in ipairs(self.layers or {}) do
    local rulesFolder = layer.dir .. "rules/"
    arrayConcat(rulesFiles,FS:findFiles(rulesFolder, "*.html", -1, true, false))
  end
  table.sort(rulesFiles, function(a,b)
    local _, fnA, _ = path.split(a)
    local _, fnB, _ = path.split(b)
    return fnA < fnB
  end)
  for _, file in ipairs(rulesFiles) do
    local content = readFile(file):gsub("\r\n","")
    table.insert(pages, content)
  end
  return pages
end

function C:hasRules()
  -- disabled for now
  return false
  --return next(self:getRules()) ~= nil
end

function C:showRulesAsPopups()
  local entries = {}
  for _, page in ipairs(self:getRules()) do
    local entry = {
      type = "info",
      content = page,
      isPopup = true,
    }
    table.insert(entries, entry)
  end
  if next(entries) then
    guihooks.trigger("introPopupTutorial", entries)
  end
end

-- expose all script hooks to the mission type
local scriptHooks = {'onVehicleReset'}
for _, hook in ipairs(scriptHooks) do
  C[hook] = function(self, ...)
    if self.script and self.script[hook] then
      self.script[hook](self, ...)
    end
  end
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
