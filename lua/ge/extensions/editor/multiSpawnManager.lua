-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local logTag = "editor_multiSpawnManager"
local toolModeName = "vehicleGroupManager"
local toolName = "Vehicle Groups Manager"
local generatorWindowName = "generatorTester"
local overwriteGroupWindowName = "overwriteGroup"

local currGroup, lastUsed = {}, {}
local commonGroups, tempGroup
local prevFilePath = "vehicleGroups/"
local prevFileName = "traffic.vehGroup.json"
local spawnState = 0
local comboItemWidth = 0
local amountWarn = 12
local timedTexts = {}
local colorWarning, colorError = im.ImVec4(1, 1, 0, 1), im.ImVec4(1, 0, 0, 1)
local defaultPaint = createVehiclePaint({x = 1, y = 1, z = 1, w = 1})
local defaultGenerator = {amount = 10, allMods = false, allConfigs = false, country = "default"}
local paintKeysTable = {{"paintName", "paint"}, {"paintName2", "paint2"}, {"paintName3", "paint3"}}

local options = {}
options.spawnModesDict = {road = "Road", traffic = "Traffic", lineAhead = "Line (Ahead)", lineBehind = "Line (Behind)", lineLeft = "Line (Left)", lineRight = "Line (Right)", lineAbove = "Line (Above)", raceGrid = "Race Grid", raceGridAlt = "Race Grid (Alt)"}
options.spawnMode = "road"
options.spawnModeValue = options.spawnModesDict.road

options.types = {Car = "Car", Truck = "Truck", Prop = "Prop", Trailer = "Trailer", Utility = "Utility", Automation = "Automation"}
options.typesSorted = {"Car", "Truck", "Prop", "Trailer", "Utility", "Automation"}
options.models, options.configs, options.paints = {}, {}, {}
options.vehIdx, options.amount, options.spawnGap = 1, 1, 15
options.newTag = ""
options.generatedGroup = {}
options.groupListIdx = 0
options.shuffle = false
options.showAdvanced = false

M.filePaths = {"vehicleGroups/", "settings/editor/vehicleGroups/"}

local selections = {
  {name = "Type", type = "types", key = "type", sortedRef = "typesSorted", default = "Car", active = true},
  {name = "Model", type = "models", key = "model", sortedRef = "modelsSorted", default = "(None)", active = true},
  {name = "Config", type = "configs", key = "config", sortedRef = "configsSorted", default = "(Default)", active = true},
  {name = "Paint 1", type = "paints", key = "paintName", paintKey = "paint", sortedRef = "paintsSorted", default = "(Default)", active = true},
  {name = "Paint 2", type = "paints", key = "paintName2", paintKey = "paint2", sortedRef = "paintsSorted", default = "(Default)", active = false},
  {name = "Paint 3", type = "paints", key = "paintName3", paintKey = "paint3", sortedRef = "paintsSorted", default = "(Default)", active = false}
}

local function convertBaseColor(val) -- converts or gets the base color to the {x, y, z, w} format
  if type(val) == "table" and val.baseColor then
    if val.baseColor[4] then
      return {x = val.baseColor[1], y = val.baseColor[2], z = val.baseColor[3], w = val.baseColor[4]}
    end
    if val.baseColor.x and val.baseColor.y and val.baseColor.z and val.baseColor.w then
      return val.baseColor
    end
  else
    return defaultPaint.baseColor
  end
end

local function createSortedArray(t) -- returns a sorted list of values from a dict
  if type(t) ~= "table" then return {} end

  local sorted = {}
  for _, v in pairs(t) do
    table.insert(sorted, v)
  end
  table.sort(sorted)
  return sorted
end

local function validateName(name, prevName) -- checks for duplicate names
  local valid = true

  repeat -- recursive check
    valid = true
    for _, v in ipairs(commonGroups) do
      if name == v.name and prevName ~= v then
        name = name.." - Copy"
        valid = false
      end
    end
  until valid

  return name
end

local function getVehType(model) -- gets the vehicle type from the model
  local vehType

  local modelData = core_vehicles.getModel(model)
  if modelData and next(modelData) then
    vehType = modelData.model.Type or vehType
  end

  return vehType
end

local function paintToFloatPtr(old) -- converts a paint table to a floatPtr
  if type(old) ~= "table" then old = defaultPaint end
  local t = convertBaseColor(old)

  return im.ImVec4ToFloatPtr(im.ImVec4(t.x or 1, t.y or 1, t.z or 1, t.w or 1))
end

local function paintToColor8(old) -- converts a paint table to a color8 table
  if type(old) ~= "table" then old = defaultPaint end
  local t = old
  local bc = convertBaseColor(old)
  local cTable = {clr = im.ArrayFloat(4), pbr = {}}

  cTable.clr[0] = im.Float(tonumber(bc.x) or 1)
  cTable.clr[1] = im.Float(tonumber(bc.y) or 1)
  cTable.clr[2] = im.Float(tonumber(bc.z) or 1)
  cTable.clr[3] = im.Float(tonumber(bc.w) or 1)

  cTable.pbr[1] = im.FloatPtr(t.metallic or 0.2)
  cTable.pbr[2] = im.FloatPtr(t.roughness or 0.5)
  cTable.pbr[3] = im.FloatPtr(t.clearcoat or 0.8)
  cTable.pbr[4] = im.FloatPtr(t.clearcoatRoughness or 0)

  return cTable
end

local function parseGroupData() -- loads and checks the vehicle group data every frame
  local idx = options.vehIdx
  if not currGroup.data[idx] then currGroup.data[idx] = {} end -- group initialization
  local currGroupData = currGroup.data[idx]
  local newIndex = false

  if not currGroupData.type then currGroupData.type = getVehType(currGroupData.model) or "Car" end

  if not lastUsed.idx or lastUsed.type ~= currGroupData.type then -- runs once to fetch model data
    options.models = {none = "(None)"}
    lastUsed.type = currGroupData.type

    local modelsData = core_vehicles.getModelList().models
    for _, m in pairs(modelsData) do
      if m.Type == currGroupData.type then
        local name = m.key
        if m.Name then
          if m.Brand then
            name = m.Brand.." "..m.Name
          else
            name = m.Name
          end
        end

        options.models[string.lower(m.key)] = name.." ["..string.lower(m.key).."]"
      end
    end

    options.modelsSorted = createSortedArray(options.models)
    lastUsed.idx = lastUsed.idx or 0
  end

  if lastUsed.idx ~= idx then -- processes whenever vehicle index is updated
    lastUsed.idx = idx
    lastUsed.model = nil
    lastUsed.paints = {false, false, false}
    options.paintsData = {}
    options.configsSorted, options.paintsSorted = {}, {}
    newIndex = true -- this flag is used to prevent resetting of config and paint selections
  end

  if not lastUsed.model or lastUsed.model ~= currGroupData.model then -- processes whenever model is updated to fetch new config and paint data
    options.configs = {base = "(Default)"}
    options.paints = {base = "(Default)", random = "(Random)", custom = "(Custom)"}

    -- reset selections if model selection gets updated
    if not newIndex then
      currGroupData.config, currGroupData.paintName, currGroupData.paintName2, currGroupData.paintName3 = nil, nil, nil, nil
    end
    lastUsed.model = currGroupData.model
    currGroupData.type = getVehType(currGroupData.model) or currGroupData.type

    if lastUsed.model then
      local modelData = core_vehicles.getModel(currGroupData.model)
      if modelData and next(modelData) then
        local configsData = modelData.configs -- get list of model configs
        for _, c in pairs(configsData) do
          local name = c.Configuration or c.key
          options.configs[c.key] = name.." ["..c.key.."]"
        end

        options.paintsData = modelData.model.paints -- get list of model paints
        if options.paintsData then
          for k, v in pairs(options.paintsData) do
            options.paints[k] = k -- not sure about this
          end
        end
      end
    end

    options.configsSorted = createSortedArray(options.configs)
    options.paintsSorted = createSortedArray(options.paints)
  end
end

local function refineGroup(groupData) -- cleans up data in custom group
  if not groupData.tags then
    groupData.tags = {}
  end

  if groupData.type == "custom" then
    groupData.generator = nil

    local finalData = {}

    for _, v in ipairs(groupData.data) do
      if v[1] then -- backwards compatible
        v.model = v[1]
        v.config = v[2]
        for i, x in ipairs(groupData.data) do
          groupData.data[i] = nil
        end
      end

      if v.model and v.model ~= "none" then
        local veh = {
          model = v.model,
          config = v.config,
          paint = v.paint,
          paint2 = v.paint2,
          paint3 = v.paint3,
          paintName = v.paintName,
          paintName2 = v.paintName2,
          paintName3 = v.paintName3
        }

        for k, p in pairs({paint = "paintName", paint2 = "paintName2", paint3 = "paintName3"}) do -- clear some values if they are not needed
          if veh[p] == "base" then
            veh[p] = nil
          end
          if not veh[p] or veh[p] == "random" then
            veh[k] = nil
          end
        end

        table.insert(finalData, veh)
      end
    end

    groupData.data = finalData
  else
    groupData.data = nil
  end

  return groupData
end

local function autoLoadGroups() -- loads all groups
  commonGroups = {}
  local commonFiles = {}
  for _, v in ipairs(M.filePaths) do
    local files = FS:findFiles(v, "*.vehGroup.json", -1, true, true)
    table.sort(files)
    commonFiles = arrayConcat(commonFiles, files)
  end
  for _, f in ipairs(commonFiles) do
    local temp = jsonReadFile(f)
    if temp and temp.name then
      table.insert(commonGroups, {name = temp.name, file = f})
    end
  end
end

local function loadGroup(filePath) -- loads and prepares a group from a file
  local tempGroup = jsonReadFile(filePath)

  if tempGroup then
    local oldIdx
    for i, v in ipairs(commonGroups) do
      if v.file == filePath then
        oldIdx = i -- file path already exists in common groups
        break
      end
    end

    if commonGroups[options.groupListIdx] then
      commonGroups[options.groupListIdx].cache = deepcopy(currGroup)
    end
    options.groupListIdx = oldIdx or #commonGroups + 1
    options.vehIdx = 1
    table.clear(lastUsed)

    currGroup = refineGroup(tempGroup)
    prevFilePath, prevFileName = path.split(filePath)
    if not oldIdx then
      table.insert(commonGroups, {name = currGroup.name, file = filePath})
    end
    log("I", logTag, "Loaded "..currGroup.name.." from "..filePath.." .")
  else
    log("W", logTag, "Failed to read data from "..filePath.." .")
  end
end

local function saveGroup(file, filePath) -- saves the current group to file
  currGroup = refineGroup(currGroup)
  jsonWriteFile(filePath, currGroup, true)
  prevFilePath, prevFileName = path.split(filePath)
  commonGroups[options.groupListIdx].file = filePath
  log("I", logTag, "Saved "..currGroup.name.." to "..filePath.." .")
end

local function selectGroup(idx) -- selects a group from the list, by index; also caches previous data
  idx = idx or 0
  if idx ~= options.groupListIdx then
    if commonGroups[options.groupListIdx] then
      commonGroups[options.groupListIdx].cache = deepcopy(currGroup) -- keep the old group data, so that it can be returned later
    end
    options.groupListIdx = idx
    options.vehIdx = 1
    table.clear(lastUsed)

    if commonGroups[idx] then
      if commonGroups[idx].cache then
        currGroup = deepcopy(commonGroups[idx].cache)
      else
        if commonGroups[idx].file then
          loadGroup(commonGroups[idx].file)
        else -- no file?
          log("W", logTag, "No file path found for "..commonGroups[idx].name.." .")
        end
      end
    else
      currGroup = {}
    end
  end
end

local function createGroup(data) -- creates a new vehicle group to edit
  data = data or {}
  local newName = "Custom Group "
  local newIdx = #commonGroups + 1

  selectGroup(newIdx)
  currGroup = {
    name = data.name or newName..newIdx,
    type = data.type or "custom",
    tags = data.tags or {},
    data = data.data
  }

  table.insert(commonGroups, {name = currGroup.name})
end

local function editGroup() -- displays options and modifies the currently selected group
  im.TextUnformatted("Edit Group")

  if not next(lastUsed) then
    if not currGroup.type then
      currGroup.type = "custom"
    elseif currGroup.type == "locked" then -- compatibility
      currGroup.type = "generator"
    end
  end

  -- custom: user can select each vehicle in the available slots
  -- generator: user can set parameters and multispawn will provide the vehicle group

  local edited = im.BoolPtr(false)
  im.PushItemWidth(comboItemWidth)
  local var = im.ArrayChar(128, currGroup.name)
  editor.uiInputText("Group Name##editGroup", var, nil, nil, nil, nil, edited)
  im.PopItemWidth()
  if edited[0] then
    currGroup.name = ffi.string(var)
    commonGroups[options.groupListIdx].name = currGroup.name
  end

  im.BeginChild1("groupType##editGroup", im.ImVec2(comboItemWidth, 32 * im.uiscale[0]), im.WindowFlags_None)
  local val = currGroup.type == "custom" and im.IntPtr(1) or im.IntPtr(2)

  if im.RadioButton2("Custom##editGroup", val, im.Int(1)) then
    currGroup.type = "custom"
  end
  im.tooltip("User defined vehicle selections.")
  im.SameLine()
  im.Dummy(im.ImVec2(5, 0))
  im.SameLine()

  if im.RadioButton2("Generator##editGroup", val, im.Int(2)) then
    currGroup.type = "generator"
  end
  im.tooltip("Auto generated vehicle selections.")
  im.Dummy(im.ImVec2(5, 0))
  im.SameLine()
  im.EndChild()

  im.SameLine()
  im.TextUnformatted("Group Type")

  im.BeginChild1("groupTags##editGroup", im.ImVec2(comboItemWidth, 64 * im.uiscale[0]), im.WindowFlags_None)

  if not currGroup.tags[1] then
    im.TextUnformatted("No tags applied")
  else
    for i, v in ipairs(currGroup.tags) do
      im.TextUnformatted(v)
      im.SameLine()
      if editor.uiIconImageButton(editor.icons.close, im.ImVec2(20, 20)) then
        table.remove(currGroup.tags, i)
        break
      end
      im.tooltip("Remove Tag")
      im.SameLine()
      im.Dummy(im.ImVec2(8, 0))
      if i % 4 ~= 0 then
        im.SameLine()
      end
    end
    im.Dummy(im.ImVec2(0, 0))
  end

  var = im.ArrayChar(128, options.newTag)
  im.PushItemWidth(math.max(100, comboItemWidth - 100))
  editor.uiInputText("##editGroupTags", var, nil, nil, nil, nil, edited)
  im.PopItemWidth()
  if edited[0] then
    options.newTag = ffi.string(var)
  end
  im.SameLine()
  if im.Button("Add Tag") then
    if options.newTag ~= "" and not arrayFindValueIndex(currGroup.tags, options.newTag) then
      table.insert(currGroup.tags, options.newTag)
      options.newTag = ""
    end
  end
  im.EndChild()

  im.SameLine()
  im.TextUnformatted("Group Tags")

  im.Dummy(im.ImVec2(0, 5))

  ---- generator ----

  if currGroup.type ~= "custom" then
    if not currGroup.generator or currGroup.generator[1] then currGroup.generator = deepcopy(defaultGenerator) end

    local generator = currGroup.generator

    im.PushItemWidth(100)
    local var = im.IntPtr(generator.amount)
    if im.InputInt("Collection Amount##editGroup", var, 1) then
      generator.amount = math.max(1, var[0])
    end
    im.PopItemWidth()

    var = im.BoolPtr(generator.allMods)
    if im.Checkbox("Use Mod Vehicles##editGroup", var) then
      generator.allMods = var[0]
    end

    var = im.BoolPtr(generator.allConfigs)
    if im.Checkbox("Use All Configs##editGroup", var) then
      generator.allConfigs = var[0]
    end

    im.Dummy(im.ImVec2(0, 5))

    if not options.showAdvanced then
      if im.Button("Show More Options##generator") then
        options.showAdvanced = true
      end
    else
      if not generator.minPop then generator.minPop = 0 end

      im.PushItemWidth(100)
      var = im.IntPtr(generator.minPop)
      if im.InputInt("Minimum Population##editGroup", var, 1) then
        generator.minPop = math.max(0, var[0])
      end
      im.PopItemWidth()
      im.tooltip("Minimum population required for model / config to be usable (useful for filtering out super rare configs).")

      if not generator.modelPopPower then generator.modelPopPower = 0 end

      im.PushItemWidth(100)
      var = im.FloatPtr(generator.modelPopPower)
      if im.InputFloat("Model Population Power##editGroup", var, 0.05, nil, "%.2f") then
        generator.modelPopPower = math.max(0, var[0])
      end
      im.PopItemWidth()
      im.tooltip("Exponent to apply to population; lower values mean that the model will be less biased to be selected by its base population value.")

      if not generator.configPopPower then generator.configPopPower = 0 end

      im.PushItemWidth(100)
      var = im.FloatPtr(generator.configPopPower)
      if im.InputFloat("Config Population Power##editGroup", var, 0.05, nil, "%.2f") then
        generator.configPopPower = math.max(0, var[0])
      end
      im.PopItemWidth()
      im.tooltip("Exponent to apply to population; lower values mean that the config will be less biased to be selected by its base population value.")

      if not generator.popDecreaseFactor then generator.popDecreaseFactor = 0.05 end

      im.PushItemWidth(100)
      var = im.FloatPtr(generator.popDecreaseFactor)
      if im.InputFloat("Population Decrease Factor##editGroup", var, 0.01, nil, "%.2f") then
        generator.popDecreaseFactor = math.max(0, var[0])
      end
      im.PopItemWidth()
      im.tooltip("Population multiplier after vehicle insertion; use low values to prevent repeat models / configs.")

      local edited = im.BoolPtr(false)
      im.PushItemWidth(comboItemWidth)
      var = im.ArrayChar(128, generator.country)
      editor.uiInputText("Country##editGroup", var, nil, nil, nil, nil, edited)
      im.PopItemWidth()
      im.tooltip("Country name; allows domestic vehicles to be selected more often.")

      if edited[0] then
        generator.country = ffi.string(var)
      end
    end

    im.Dummy(im.ImVec2(0, 5))
    if im.Button("Test Generator...##editGroup") then
      editor.openModalWindow(generatorWindowName)
    end

    -- group generator modal window
    if editor.beginModalWindow(generatorWindowName, "Generator Tester") then
      if im.Button("Generate Group##testGenerator") then
        core_multiSpawn.useFullData = true
        options.generatedGroup = core_multiSpawn.createGroup(currGroup.generator.amount, currGroup.generator)
      end
      im.SameLine()

      if im.Button("Copy Group") then
        if options.generatedGroup[1] then
          local tempData = deepcopy(currGroup)
          tempData.name = tempData.name.." - Copy"
          tempData.type = "custom"
          tempData.data = deepcopy(options.generatedGroup)
          createGroup(tempData)

          core_multiSpawn.useFullData = false
          table.clear(options.generatedGroup)
          editor.closeModalWindow(generatorWindowName)
        end
      end
      im.SameLine()

      if im.Button("Close##testGenerator") then
        core_multiSpawn.useFullData = false
        table.clear(options.generatedGroup)
        editor.closeModalWindow(generatorWindowName)
      end

      im.Dummy(im.ImVec2(0, 5))
      im.Separator()

      im.BeginChild1("Generated Group##editGroup", im.ImVec2(im.GetContentRegionAvailWidth(), 470 * im.uiscale[0]), im.WindowFlags_ChildWindow)
      local width = im.GetContentRegionAvailWidth() - 100

      im.Columns(3, "list", false)
      im.SetColumnWidth(0, 40)
      im.SetColumnWidth(1, width)

      im.TextUnformatted("Index")
      im.NextColumn()
      im.TextUnformatted("Config Name")
      im.NextColumn()
      im.TextUnformatted("Population")
      im.NextColumn()

      im.Columns(1)
      im.Separator()

      im.Columns(3, "list", false)
      im.SetColumnWidth(0, 40)
      im.SetColumnWidth(1, width)

      for i, v in ipairs(options.generatedGroup) do
        im.TextUnformatted(tostring(i))
        im.NextColumn()

        local modelName, configName
        local model = core_vehicles.getModel(v.model).model
        if model.Name then
          modelName = model.Brand and model.Brand.." "..model.Name or model.Name
        else
          modelName = v.model
        end
        local config = v.config and core_vehicles.getModel(v.model).configs[v.config]
        configName = config and config.Configuration or ""
        im.TextUnformatted(modelName.." "..configName)
        im.NextColumn()
        im.TextUnformatted(tostring(v.configPop))
        im.NextColumn()
      end
      im.Columns(1)
      im.EndChild()
      editor.endModalWindow()
    end

  ---- custom vehicle group ----

  else
    if not currGroup.data then currGroup.data = {} end

    if im.ArrowButton("##idxLeft", im.Dir_Left) then options.vehIdx = math.max(1, options.vehIdx - 1) end
    im.SameLine()
    if im.ArrowButton("##idxRight", im.Dir_Right) then options.vehIdx = options.vehIdx + 1 end
    im.SameLine()

    im.TextUnformatted("Vehicle #"..tostring(options.vehIdx))
    parseGroupData() -- this is the main function that updates the current model, config, and paint tables

    local idx = options.vehIdx
    local currGroupData = currGroup.data[idx]

    -- vehicle type
    local currSelection = currGroupData.type or "none"
    im.PushItemWidth(comboItemWidth)
    if im.BeginCombo("Type", options.types[currSelection] or "Car") then
      for _, v in ipairs(options.typesSorted) do
        local selected = options.types[currSelection] == v
        if im.Selectable1(v, selected) then
          currGroupData.type = tableFindKey(options.types, v)
          if selected then im.SetItemDefaultFocus() end
        end
      end
      im.EndCombo()
    end
    im.PopItemWidth()

    -- vehicle model
    currSelection = currGroupData.model or "none"
    im.PushItemWidth(comboItemWidth)
    if im.BeginCombo("Model", options.models[currSelection] or "(None)") then
      for _, v in ipairs(options.modelsSorted) do
        local selected = options.models[currSelection] == v
        if im.Selectable1(v, selected) then
          currGroupData.model = tableFindKey(options.models, v)
          if selected then im.SetItemDefaultFocus() end
        end
      end
      im.EndCombo()
    end
    im.PopItemWidth()

    if currGroupData.model then
      -- vehicle config
      currSelection = currGroupData.config or "none"
      im.PushItemWidth(comboItemWidth)
      if im.BeginCombo("Config", options.configs[currSelection] or "(Default)") then
        for _, v in ipairs(options.configsSorted) do
          local selected = options.configs[currSelection] == v
          if im.Selectable1(v, selected) then
            currGroupData.config = tableFindKey(options.configs, v)
            if selected then im.SetItemDefaultFocus() end
          end
        end
        im.EndCombo()
      end
      im.PopItemWidth()

      im.Dummy(im.ImVec2(0, 5))

      -- vehicle paints (3)
      for i, paintKeys in ipairs(paintKeysTable) do
        local isHovered = false
        local currPaint = defaultPaint

        currSelection = currGroupData[paintKeys[1]] or "none"
        if currGroupData[paintKeys[1]] == "custom" then
          currPaint = currGroupData[paintKeys[1]] or defaultPaint
        else
          if options.paintsData then
            currPaint = options.paintsData[currSelection] or defaultPaint
          end
        end

        im.PushItemWidth(comboItemWidth)
        if im.BeginCombo("Paint "..i, options.paints[currSelection] or "(Default)") then
          for _, v in ipairs(options.paintsSorted) do
            local selected = options.paints[currSelection] == v
            if im.Selectable1(v, selected) then
              currGroupData[paintKeys[1]] = tableFindKey(options.paints, v)
              currGroupData[paintKeys[2]] = options.paintsData[v]
              if selected then im.SetItemDefaultFocus() end
            end

            if im.IsItemHovered() then
              isHovered = true
              currPaint = options.paintsData[v] or defaultPaint
            end
          end
          im.EndCombo()
        end
        im.PopItemWidth()

        if isHovered or currGroupData[paintKeys[1]] ~= "custom" then -- display current color widget
          im.SameLine()
          im.ColorEdit4("##color"..i, paintToFloatPtr(currPaint), im.flags(im.ColorEditFlags_NoPicker, im.ColorEditFlags_NoInputs))
        else
          if not lastUsed.paints[i] then -- display customized color widget
            lastUsed.paints[i] = paintToColor8(currPaint)
          end

          local editEnded = im.BoolPtr(false)
          editor.uiColorEdit8("##colorExtra"..i, lastUsed.paints[i], nil, editEnded)
          if editEnded[0] then
            local cc = lastUsed.paints[i]
            local baseColor = {x = cc.clr[0], y = cc.clr[1], z = cc.clr[2], w = cc.clr[3]}
            local metallicData = {cc.pbr[1][0], cc.pbr[2][0], cc.pbr[3][0], cc.pbr[4][0]}
            currGroupData[paintKeys[2]] = createVehiclePaint(baseColor, metallicData)

            lastUsed.paints[i] = paintToColor8(currGroupData[paintKeys[2]])
          end
        end

        if not options.showAdvanced then break end
      end
    end

    im.Dummy(im.ImVec2(0, 5))

    if not options.showAdvanced then
      if im.Button("Show More Options##custom") then
        options.showAdvanced = true
      end
    end
  end

  -- confirm overwrite group modal window
  if editor.beginModalWindow(overwriteGroupWindowName, "Confirm") then
    im.TextUnformatted("Are you sure?")
    im.TextUnformatted("This will overwrite the current group.")
    if im.Button("Yes##overwriteGroup") then
      currGroup.type = "custom"
      currGroup.data = core_multiSpawn.spawnedVehsToGroup()
      options.vehIdx = 1
      table.clear(lastUsed)
      editor.closeModalWindow(overwriteGroupWindowName)
    end
    im.SameLine()
    if im.Button("No##overwriteGroup") then
      editor.closeModalWindow(overwriteGroupWindowName)
    end

    editor.endModalWindow()
  end
end

local function spawnGroup() -- spawns the current vehicle group into the world
  im.TextUnformatted("Spawn Group")

  im.PushItemWidth(comboItemWidth)
  if im.BeginCombo("Spawn Mode##multiSpawn", options.spawnModeValue) then
    for _, v in ipairs(options.spawnModesSorted) do
      local selected = options.spawnModeValue == v
      if im.Selectable1(v, selected) then
        options.spawnMode, options.spawnModeValue = tableFindKey(options.spawnModesDict, v), v
      end
      if selected then
        im.SetItemDefaultFocus()
      end
    end
    im.EndCombo()
  end
  im.PopItemWidth()

  im.PushItemWidth(100)
  local var = im.IntPtr(options.spawnGap)
  if im.InputInt("Spacing##multiSpawn", var, 1) then
    options.spawnGap = clamp(var[0], 1, 200)
  end
  im.PopItemWidth()

  var = im.BoolPtr(options.shuffle)
  if currGroup.type == "generator" then
    var = im.BoolPtr(true)
    im.BeginDisabled()
  end
  if im.Checkbox("Shuffle##multiSpawn", var) then
    options.shuffle = var[0]
  end
  if currGroup.type == "generator" then im.EndDisabled() end

  im.Dummy(im.ImVec2(0, 5))

  im.PushItemWidth(100)
  var = im.IntPtr(options.amount)
  if im.InputInt("Amount##multiSpawn", var, 1) then
    options.amount = clamp(var[0], 1, 1000)
  end
  im.PopItemWidth()

  if options.amount > amountWarn then
    im.TextColored(colorWarning, "Warning, too many vehicles may result in poor performance!")
  end

  if spawnState == 1 then
    if not scenetree.MissionGroup then
      log("W", logTag, "No level loaded, unable to spawn vehicles!")
      spawnState = 0
    else
      currGroup = refineGroup(currGroup)
      if currGroup.generator then
        tempGroup = core_multiSpawn.createGroup(currGroup.generator.amount, currGroup.generator)
      elseif currGroup.data then
        tempGroup = currGroup.data
      else
        log("W", logTag, "No vehicle group data exists!")
        spawnState = 0
      end

      if spawnState == 1 then
        core_multiSpawn.spawnGroup(tempGroup, options.amount, {name = options.groupKey, shuffle = options.shuffle, mode = options.spawnMode, gap = options.spawnGap})
        tempGroup = nil
      end
    end
    spawnState = 2
  end

  if im.Button("Spawn##multiSpawn") then
    spawnState = 1
  end
  im.SameLine()

  if im.Button("Delete##multiSpawn") then
    core_multiSpawn.deleteVehicles(options.amount)
  end

  if spawnState > 0 then
    im.SameLine()
    im.TextColored(colorWarning, "Please wait...") -- while loading vehicles
  end
end

local function onEditorGui(dt)
  if editor.beginWindow(toolModeName, toolName, im.WindowFlags_MenuBar) then
    comboItemWidth = im.GetWindowWidth() * 0.6
    if not commonGroups then -- first frame
      options.spawnModesSorted = createSortedArray(options.spawnModesDict)
      autoLoadGroups()
    end

    im.BeginMenuBar()
    if im.BeginMenu("File") then
      if im.MenuItem1("New") then
        createGroup()
      end
      if im.MenuItem1("Load...") then
        editor_fileDialog.openFile(function(data) loadGroup(data.filepath) end, {{"Vehicle group files", ".vehGroup.json"}}, false, prevFilePath)
      end
      if im.MenuItem1("Save") then
        if commonGroups[options.groupListIdx].file then
          saveGroup(nil, commonGroups[options.groupListIdx].file)
        else
          extensions.editor_fileDialog.saveFile(function(data) saveGroup(nil, data.filepath) end, {{"Vehicle group files", ".vehGroup.json"}}, false, prevFilePath)
        end
      end
      if im.MenuItem1("Save as...") then
        extensions.editor_fileDialog.saveFile(function(data) saveGroup(nil, data.filepath) end, {{"Vehicle group files", ".vehGroup.json"}}, false, prevFilePath)
      end
      im.EndMenu()
    end

    if im.BeginMenu("Tools") then
      if im.MenuItem1("Shuffle Group") then
        if next(currGroup) and currGroup.data then
          currGroup.data = arrayShuffle(currGroup.data)
          table.clear(lastUsed)
        end
      end
      if im.MenuItem1("Duplicate Group") then
        if next(currGroup) then
          local tempData = deepcopy(currGroup)
          tempData.name = tempData.name.." - Copy"
          createGroup(tempData)
        end
      end
      if im.MenuItem1("Set Scene Vehicles to Group") then
        if next(currGroup) then
          editor.openModalWindow(overwriteGroupWindowName)
        end
      end

      im.EndMenu()
    end

    if timedTexts.save then
      im.SameLine()
      im.TextColored(colorWarning, timedTexts.save[1])
    end
    im.EndMenuBar()

    im.TextUnformatted("Current Vehicle Group: ")
    im.SameLine()
    im.PushItemWidth(im.GetContentRegionAvailWidth())
    local currName = commonGroups[options.groupListIdx] and commonGroups[options.groupListIdx].name or "(None)"
    if im.BeginCombo("##commonGroups", currName) then
      for i, v in ipairs(commonGroups) do
        if im.Selectable1(v.name.."##groupListIdx"..i, currName == v.name) then
          selectGroup(i)
        end
      end
      im.EndCombo()
    end
    im.PopItemWidth()

    im.Separator()

    if commonGroups[options.groupListIdx] then
      editGroup()
      im.Dummy(im.ImVec2(0, 5))
      im.Separator()
      spawnGroup()
    else
      im.TextUnformatted("Create or select a vehicle group to continue.")
      if im.Button("New Group") then
        createGroup()
      end
    end
  end

  for k, v in pairs(timedTexts) do
    if v[2] then
      v[2] = v[2] - dt
      if v[2] <= 0 then timedTexts[k] = nil end
    end
  end

  editor.endWindow()
end

local function onVehicleGroupSpawned()
  spawnState = 0
end

local function onWindowMenuItem()
  editor.clearObjectSelection()
  editor.showWindow(toolModeName)
end

local function onEditorInitialized()
  editor.registerWindow(toolModeName, im.ImVec2(500, 540))
  editor.registerModalWindow(generatorWindowName, im.ImVec2(440, 500), nil, true)
  editor.registerModalWindow(overwriteGroupWindowName, im.ImVec2(240, 100), nil, true)
  editor.addWindowMenuItem(toolName, onWindowMenuItem, {groupMenuName = "Gameplay"})
end

-- public interface
M.onVehicleGroupSpawned = onVehicleGroupSpawned
M.onWindowMenuItem = onWindowMenuItem
M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
M.loadGroup = loadGroup
M.saveGroup = saveGroup

return M