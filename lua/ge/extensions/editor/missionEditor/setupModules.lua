-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local C = {}

function C:init(missionEditor)
  self.missionEditor = missionEditor
  self.name = "SetupModules"
end

local paintNameKeys = {"paintName", "paintName2", "paintName3"}

function C:setMission(mission)
  self.mission = mission
  self.missionInstance = gameplay_missions_missions.getMissionById(mission.id)

  self:setBackwardsCompatibility()
  self.blockedSetupModules = tableValuesAsLookupDict(self.missionInstance.blockedSetupModules or {})

  self.vehicleGroupData = self.mission.setupModules.vehicles.vehicles
  self.vehicleIncludePlayer = im.BoolPtr(self.mission.setupModules.vehicles.includePlayerVehicle and true or false)
  self.vehiclePrioritizePlayer = im.BoolPtr(self.mission.setupModules.vehicles.prioritizePlayerVehicle and true or false)
  self.vehicleSelectors = {}

  self.trafficAmountInput = im.IntPtr(self.mission.setupModules.traffic.amount or 3)
  self.trafficActiveAmountInput = im.IntPtr(self.mission.setupModules.traffic.activeAmount or 3)
  self.trafficParkedAmountInput = im.IntPtr(self.mission.setupModules.traffic.parkedAmount or 0)
  self.trafficRespawnRateInput = im.FloatPtr(self.mission.setupModules.traffic.respawnRate or 1)
  self.trafficUseTrafficInput = im.BoolPtr(self.mission.setupModules.traffic.useTraffic and true or false)
  self.trafficPrevTrafficInput = im.BoolPtr(self.mission.setupModules.traffic.usePrevTraffic and true or false)
  self.trafficUserOptionsInput = im.BoolPtr(self.mission.setupModules.traffic.useGameOptions and true or false)
  self.trafficSimpleVehsInput = im.BoolPtr(self.mission.setupModules.traffic.useSimpleVehs and true or false)
  self.trafficUseCustomGroup = im.BoolPtr(self.mission.setupModules.traffic.useCustomGroup and true or false)

  self.todInput = im.FloatPtr(self.mission.setupModules.timeOfDay.time or 0)
end

function C:setBackwardsCompatibility()
  -- check for patched data from mission instance and apply it to the mission data
  for k, v in pairs(self.missionInstance.setupModules) do
    if v._compatibility then
      v._compatibility = nil
      self.mission.setupModules[k] = deepcopy(v)
    end
  end
end

function C:getMissionIssues(m)
  self:setMission(m)
  local issues = {}

  for k, v in pairs(m.setupModules) do
    if v.enabled == nil or (v.enabled and tableSize(v) <= 1) then
      table.insert(issues, {label = 'Missing or malformed data for setup module: '..k, severity = 'error'})
    end
  end

  -- TODO: add more issues

  return issues
end

local function todToTime(val)
  local seconds = ((val + 0.50001) % 1) * 86400
  local hours = math.floor(seconds / 3600)
  local mins = math.floor(seconds / 60 - (hours * 60))
  local secs = math.floor(seconds - hours * 3600 - mins * 60)
  return string.format("%02d:%02d:%02d", hours, mins, secs)
end

function C:draw()
  im.PushID1(self.name)
  im.Columns(2)
  im.SetColumnWidth(0,150)

  im.Text("Vehicles")
  im.NextColumn()

  local setupModule = self.mission.setupModules.vehicles
  local isBlocked = self.blockedSetupModules.vehicles
  self.mission.setupModules.vehicles.enabled = not isBlocked
  if isBlocked then
    im.BeginDisabled()
  end
  if im.Checkbox("##setupModuleVehiclesEnabled", im.BoolPtr(setupModule.enabled)) then
    setupModule.enabled = not setupModule.enabled
    self.mission._dirty = true
  end
  im.SameLine()
  if setupModule.enabled then
    if not setupModule.vehicles then
      table.clear(setupModule)
      setupModule.enabled = true
      setupModule.vehicles = self.vehicleGroupData or {}
      setupModule.includePlayerVehicle = self.vehicleIncludePlayer[0]
      setupModule.prioritizePlayerVehicle = self.vehiclePrioritizePlayer[0]
    end

    im.Text("Vehicle Setup")

    local baseCount = #setupModule.vehicles -- provided vehicles only
    local count = baseCount
    if setupModule.includePlayerVehicle then
      count = count + 1
    end
    im.Text("Number of vehicles selectable for this mission: "..count)
    if im.Button("Add New Provided Vehicle") then
      table.insert(setupModule.vehicles, {model = "pickup"})
    end
    im.tooltip("Adds a vehicle that the user can choose to use for this mission.")

    im.Dummy(im.ImVec2(0, 5))

    if not self.vehicleSelectors[baseCount] then
      for i = #self.vehicleSelectors + 1, baseCount do
        local currVeh = setupModule.vehicles[i] or {}
        local data = {
          model = currVeh.model or "pickup",
          config = currVeh.config or "",
          configPath = currVeh.configPath or "",
          paintName = currVeh.paintName or "",
          paintName2 = currVeh.paintName2 or "",
          paintName3 = currVeh.paintName3 or "",
          useCustomConfig = im.BoolPtr(currVeh.useCustomConfig and true or false)
        }
        table.insert(self.vehicleSelectors, data)
      end
    end

    local delIdx
    for i = 1, baseCount do
      im.Text("Provided Vehicle #"..i)
      im.SameLine()
      if im.Button("Delete##vehicleSelector"..i) then
        delIdx = i
      end
      local currSelection = self.vehicleSelectors[i]
      if ui_flowgraph_editor.vehicleSelector(currSelection) then -- model, config, configPath
        setupModule.vehicles[i].model = currSelection.model
        setupModule.vehicles[i].config = currSelection.config
        setupModule.vehicles[i].configPath = currSelection.configPath
        currSelection.paints = nil
        --im.PushItemWidth(im.GetContentRegionAvailWidth())
        im.Columns(1)
        currSelection._updated = true
        self.mission._dirty = true
      end

      if not currSelection.paints then -- load available model paints
        local model = core_vehicles.getModel(currSelection.model)
        if model and model.model then
          currSelection.paints = model.model.paints
          currSelection.paintKeys = currSelection.paints and tableKeysSorted(currSelection.paints) or {}
        end
      else
        for j, key in ipairs(paintNameKeys) do
          im.PushItemWidth(200)
          local label = currSelection.paints[currSelection[key]] and currSelection[key] or "(Default)"
          if im.BeginCombo("Paint "..j.."##vehicleSelector"..i, label) then
            if im.Selectable1("(Default)", currSelection[key] == nil) then
              currSelection[key] = nil
              currSelection._updatedPaint = true
              self.mission._dirty = true
            end
            for _, paint in ipairs(currSelection.paintKeys) do
              if im.Selectable1(paint, currSelection[key] == paint) then
                currSelection[key] = paint
                currSelection._updatedPaint = true
                self.mission._dirty = true
              end
            end
            im.EndCombo()
          end
          im.PopItemWidth()

          if currSelection._updatedPaint then
            setupModule.vehicles[i][key] = currSelection[key]
            currSelection._updatedPaint = nil
          end
        end

        if im.Checkbox("Use Custom Part Configuration##vehicleSelector"..i, currSelection.useCustomConfig) then
          setupModule.vehicles[i].useCustomConfig = currSelection.useCustomConfig[0]
          self.mission._dirty = true
        end
        im.tooltip("If true, enables a custom part configuration (.pc) file for this model.")
        if setupModule.vehicles[i].useCustomConfig then -- enable selection of custom file (or custom.pc by default)
          if not setupModule.vehicles[i].customConfigPath then
            setupModule.vehicles[i].customConfigPath = self.mission.missionFolder.."/custom.pc"
            self.mission._dirty = true
          end
          if not currSelection.customConfigPath then
            currSelection.customConfigPath = im.ArrayChar(1024, setupModule.vehicles[i].customConfigPath)
          end
          if editor.uiInputFile("Custom Config##vehicleSelector"..i, currSelection.customConfigPath, nil, nil, {{"Part config files", ".pc"}}, im.InputTextFlags_EnterReturnsTrue) then
            setupModule.vehicles[i].customConfigPath = ffi.string(currSelection.customConfigPath)
            self.mission._dirty = true
          end
        else
          setupModule.vehicles[i].customConfigPath = nil
          currSelection.customConfigPath = nil
        end
      end

      im.Dummy(im.ImVec2(0, 5))
    end

    if delIdx and setupModule.vehicles[delIdx] then
      table.remove(setupModule.vehicles, delIdx)
      table.remove(self.vehicleSelectors, delIdx)
    end

    if im.Checkbox("Add Player Vehicle to Selections##vehicle", self.vehicleIncludePlayer) then
      setupModule.includePlayerVehicle = self.vehicleIncludePlayer[0]
      self.mission._dirty = true
    end
    im.tooltip("If true, the current player vehicle can be used for the mission.")
    if not setupModule.includePlayerVehicle then
      im.BeginDisabled()
    end
    if im.Checkbox("Set Player Vehicle as Priority##vehicle", self.vehiclePrioritizePlayer) then
      setupModule.prioritizePlayerVehicle = self.vehiclePrioritizePlayer[0]
      self.mission._dirty = true
    end
    im.tooltip("If true, the current player vehicle becomes the default vehicle for the mission.")
    if not setupModule.includePlayerVehicle then
      im.EndDisabled()
    end
    --if baseCount < 1 then
      --setupModule.includePlayerVehicle = true -- always true if no other vehicles were provided
    --end
  else
    if isBlocked then
      im.Text("Player vehicle setup is not available for this mission type.")
    else
      table.clear(setupModule)
      setupModule.enabled = false
      im.Text("Select this to enable player vehicle setup.")
    end
  end
  if isBlocked then
    im.EndDisabled()
  end

  im.Separator()
  im.NextColumn()
  im.Text("Traffic")
  im.NextColumn()

  setupModule = self.mission.setupModules.traffic
  isBlocked = self.blockedSetupModules.traffic
  if isBlocked then
    setupModule.enabled = false
    im.BeginDisabled()
  end
  if im.Checkbox("##setupModuleTrafficEnabled", im.BoolPtr(setupModule.enabled)) then
    setupModule.enabled = not setupModule.enabled
    self.mission._dirty = true
  end
  im.SameLine()
  if setupModule.enabled then
    if not setupModule.amount then -- init values
      setupModule.useTraffic = true -- initializes as true
      self.trafficUseTrafficInput[0] = setupModule.useTraffic
      setupModule.amount = self.trafficAmountInput[0]
      setupModule.activeAmount = self.trafficActiveAmountInput[0]
      setupModule.parkedAmount = self.trafficParkedAmountInput[0]
      setupModule.respawnRate = self.trafficRespawnRateInput[0]
      setupModule.usePrevTraffic = self.trafficPrevTrafficInput[0]
      setupModule.useGameOptions = self.trafficUserOptionsInput[0]
      setupModule.useSimpleVehs = self.trafficSimpleVehsInput[0]
      setupModule.useCustomGroup = self.trafficUseCustomGroup[0]
    end

    im.Text("Traffic Setup")
    im.PushItemWidth(100)
    if im.InputInt("Amount##traffic", self.trafficAmountInput, 1) then
      setupModule.amount = self.trafficAmountInput[0]
      self.mission._dirty = true
    end
    im.tooltip("Amount of traffic vehicles to spawn; -1 = auto amount")
    im.PopItemWidth()
    im.PushItemWidth(100)
    if im.InputInt("Active Amount##traffic", self.trafficActiveAmountInput, 1) then
      setupModule.activeAmount = self.trafficActiveAmountInput[0]
      self.mission._dirty = true
    end
    im.tooltip("Amount of active traffic vehicles running at the same time; other vehicles stay hidden until they get cycled.")
    im.PopItemWidth()
    if setupModule.amount ~= 0 and setupModule.activeAmount <= 0 then
      im.SameLine()
      im.TextColored(im.ImVec4(1, 1, 0, 1), " Warning: All traffic vehicles will start out as hidden.")
    end

    im.PushItemWidth(100)
    if im.InputInt("Parked Amount##traffic", self.trafficParkedAmountInput, 1) then
      setupModule.parkedAmount = self.trafficParkedAmountInput[0]
      self.mission._dirty = true
    end
    im.tooltip("Amount of parked vehicles to spawn.")
    im.PopItemWidth()
    im.PushItemWidth(100)
    if im.InputFloat("Respawn Rate##traffic", self.trafficRespawnRateInput, 0.1, nil, "%.2f") then
      setupModule.respawnRate = self.trafficRespawnRateInput[0]
      self.mission._dirty = true
    end
    im.tooltip("Traffic respawn rate; values can range from 0 to 3.")
    im.PopItemWidth()
    if setupModule.respawnRate and setupModule.respawnRate <= 0 then
      im.SameLine()
      im.TextColored(im.ImVec4(1, 1, 0, 1), " Warning: All traffic vehicles will not respawn during gameplay.")
    end

    local innerDisabled = false
    if im.Checkbox("Enable Traffic as Default Setting##traffic", self.trafficUseTrafficInput) then
      setupModule.useTraffic = self.trafficUseTrafficInput[0]
      self.mission._dirty = true
    end
    im.tooltip("If true, this mission will start with traffic enabled unless the user changes the setting.")

    if im.Checkbox("Keep Previous Traffic##traffic", self.trafficPrevTrafficInput) then
      setupModule.usePrevTraffic = self.trafficPrevTrafficInput[0]
      self.mission._dirty = true
    end
    im.tooltip("If true, this mission will try to use traffic that already existed in freeroam.")

    if im.Checkbox("Use Settings From Traffic Options##traffic", self.trafficUserOptionsInput) then
      setupModule.useGameOptions = self.trafficUserOptionsInput[0]
      self.mission._dirty = true
    end

    if not innerDisabled and setupModule.useGameOptions then innerDisabled = true end
    if innerDisabled then im.BeginDisabled() end
    if im.Checkbox("Use Simple Vehicles##traffic", self.trafficSimpleVehsInput) then
      setupModule.useSimpleVehs = self.trafficSimpleVehsInput[0]
      innerDisabled = true
      self.mission._dirty = true
    end
    if innerDisabled then im.EndDisabled() end

    if not innerDisabled and setupModule.useSimpleVehs then innerDisabled = true end
    if innerDisabled then im.BeginDisabled() end
    if im.Checkbox("Use Custom Vehicle Group##traffic", self.trafficUseCustomGroup) then
      setupModule.useCustomGroup = self.trafficUseCustomGroup[0]
      self.mission._dirty = true
    end
    im.tooltip("If true, enables a custom vehicle group to use for traffic.")
    if setupModule.useCustomGroup then
      if not setupModule.customGroupFile then
        setupModule.customGroupFile = self.mission.missionFolder.."/custom.vehGroup.json"
        self.mission._dirty = true
      end
      if not self.trafficCustomGroupInput then
        self.trafficCustomGroupInput = im.ArrayChar(1024, setupModule.customGroupFile)
      end

      if editor.uiInputFile("Vehicle Group##traffic", self.trafficCustomGroupInput, nil, nil, {{"Vehicle group files", ".vehGroup.json"}}, im.InputTextFlags_EnterReturnsTrue) then
        setupModule.customGroupFile = ffi.string(self.trafficCustomGroupInput)
        self.mission._dirty = true
      end
    else
      setupModule.customGroupFile = nil
      self.trafficCustomGroupInput = nil
    end
    if innerDisabled then im.EndDisabled() end
  else
    if isBlocked then
      im.Text("Traffic setup is not available for this mission type.")
    else
      table.clear(self.mission.setupModules.traffic)
      setupModule.enabled = false
      im.Text("Select this to enable traffic setup.")
    end
  end
  if isBlocked then
    im.EndDisabled()
  end

  im.Separator()
  im.NextColumn()
  im.Text("Time Of Day")
  im.NextColumn()

  setupModule = self.mission.setupModules.timeOfDay
  isBlocked = self.blockedSetupModules.timeOfDay
  if isBlocked then
    setupModule.enabled = false
    im.BeginDisabled()
  end
  if im.Checkbox("##setupModuleTodEnabled", im.BoolPtr(setupModule.enabled)) then
    setupModule.enabled = not setupModule.enabled
    if setupModule.enabled then
      setupModule.time = setupModule.time or (core_environment and core_environment.getTimeOfDay() and core_environment.getTimeOfDay().time)
    else
      setupModule.time = nil
    end
    self.todInput[0] = setupModule.time or 0
    self.mission._dirty = true
  end
  im.SameLine()
  if setupModule.enabled then
    im.PushItemWidth(100)
    if im.InputFloat("##tod", self.todInput) then
      self.todInput[0] = math.max(self.todInput[0],0)
      self.todInput[0] = math.min(self.todInput[0],1)
      setupModule.time = self.todInput[0]
      self.mission._dirty = true
    end
    im.SameLine()
    im.Text(todToTime(self.todInput[0]))
    im.SameLine()
    if im.BeginCombo("##todSelector","...") then
      if im.Selectable1("Now") then
        setupModule.time = (core_environment and core_environment.getTimeOfDay() and core_environment.getTimeOfDay().time)
        self.mission._dirty = true
      end
      for i = 0, 48 do
        local val = (i / 48 + 0.5) % 1
        if im.Selectable1(todToTime(val)) then
          setupModule.time = val
          self.todInput[0] = val
          self.mission._dirty = true
        end
      end
      im.EndCombo()
    end
  else
    if isBlocked then
      im.Text("Time of day setup is not available for this mission type.")
    else
      table.clear(setupModule)
      setupModule.enabled = false
      im.Text("Select this to set time of day.")
    end
  end
  if isBlocked then
    im.EndDisabled()
  end

  im.Columns(1)
  im.PopID()
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
