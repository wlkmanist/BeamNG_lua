-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local im = ui_imgui

M.dependencies = {
  "ui_imgui",
  "ui_vehicleSelector_tileGrouping",
  "core_vehicles",
  "util_screenshotCreator_settings",
  "util_screenshotCreator_shippedConfigs"
}

local vehicleList -- table array {vehicleFolder, selectedPtr, displayName, vehicleType, groupName, groupOrder}
local vehicleTypeFilters = {
  {key = "Car", label = "Cars", addLabel = "Add all Cars", active = im.BoolPtr(false)},
  {key = "Truck", label = "Trucks", addLabel = "Add all Trucks", active = im.BoolPtr(false)},
  {key = "Heavy Machinery", label = "Heavy Machinery", addLabel = "Add all Heavy Machinery", active = im.BoolPtr(false)},
  {key = "Trailer", label = "Trailers", addLabel = "Add all Trailers", active = im.BoolPtr(false)},
  {key = "Prop", label = "Props", addLabel = "Add all Props", active = im.BoolPtr(false)},
  {key = "Other", label = "Other", addLabel = "Add all Other", active = im.BoolPtr(false)}
}

local function getVehicleFilterKey(vehicleType)
  if vehicleType == "Car"
    or vehicleType == "Truck"
    or vehicleType == "Heavy Machinery"
    or vehicleType == "Trailer"
    or vehicleType == "Prop" then
    return vehicleType
  end
  return "Other"
end

local function vehicleMatchesTypeFilters(vehicle)
  local vehicleFilterKey = getVehicleFilterKey(vehicle[4])
  local hasActiveFilter = false
  for _, filter in ipairs(vehicleTypeFilters) do
    if filter.active[0] then
      hasActiveFilter = true
      if filter.key == vehicleFilterKey then
        return true
      end
    end
  end
  return not hasActiveFilter
end

local function isVehicleVisible(vehicle)
  return not util_screenshotCreator_settings.getControls().shippedConfigsOnly[0]
    or util_screenshotCreator_shippedConfigs.isModelShipped(vehicle[1])
end

local function populate()
  vehicleList = {}
  local models = core_vehicles.getModelList().models
  local modelKeys = {}
  for key in pairs(models) do
    table.insert(modelKeys, key)
  end
  table.sort(modelKeys)

  local getTypeGroup = ui_vehicleSelector_tileGrouping.getGroupModeFunction("Type")
  for _, key in ipairs(modelKeys) do
    local model = models[key]
    local groupName, groupOrder = getTypeGroup(model.Type)
    table.insert(vehicleList, {
      key,
      im.BoolPtr(false),
      (model.Brand and (model.Brand .. " ") or "") .. model.Name,
      model.Type,
      groupName,
      groupOrder
    })
  end

  table.sort(vehicleList, function(a, b)
    if a[5] == b[5] then return a[3] < b[3] end
    if a[6] == b[6] then return a[5] < b[5] end
    return a[6] < b[6]
  end)
end

local function ensurePopulated()
  if not vehicleList then
    populate()
  end
end

local function addVehicleFilterToSelection(filterKey)
  for _, vehicle in ipairs(vehicleList) do
    if isVehicleVisible(vehicle) and getVehicleFilterKey(vehicle[4]) == filterKey then
      vehicle[2][0] = true
    end
  end
end

local function drawVehicleSelectionList(selected)
  local currentGroup
  for _, vehicle in ipairs(vehicleList) do
    if isVehicleVisible(vehicle) and vehicle[2][0] == selected then
      if vehicle[5] ~= currentGroup then
        currentGroup = vehicle[5]
        im.SeparatorText(currentGroup)
      end
      local matchesFilters = vehicleMatchesTypeFilters(vehicle)
      if not matchesFilters then im.BeginDisabled(true) end
      im.Selectable2(vehicle[3] .. " (" .. vehicle[1] .. ")", vehicle[2])
      if not matchesFilters then im.EndDisabled() end
    end
  end
end

function M.selectPlayerVehicle()
  ensurePopulated()
  local playerVehicle = getPlayerVehicle(0)
  if playerVehicle then
    for _, vehicle in ipairs(vehicleList) do
      vehicle[2][0] = isVehicleVisible(vehicle) and vehicle[1] == playerVehicle.JBeam
    end
  else
    log("E", "selectCurVeh", "Failed to get current vehicle")
  end
end

function M.drawTab()
  if not im.BeginTabItem("Models selection") then return end
  ensurePopulated()

  im.TextUnformatted("Type filters")
  for _, filter in ipairs(vehicleTypeFilters) do
    im.Checkbox(filter.label, filter.active)
    im.SameLine()
    if im.SmallButton(filter.addLabel) then
      addVehicleFilterToSelection(filter.key)
    end
  end
  im.tooltip("Active filters are combined with OR. Non-matching models remain visible but cannot be selected.")
  im.Separator()

  if im.SmallButton("Player Vehicle Model") then
    M.selectPlayerVehicle()
  end
  im.SameLine()
  if im.SmallButton("Select All") then
    for _, vehicle in ipairs(vehicleList) do
      if isVehicleVisible(vehicle) then vehicle[2][0] = true end
    end
  end
  im.SameLine()
  if im.SmallButton("Unselect All") then
    for _, vehicle in ipairs(vehicleList) do
      vehicle[2][0] = false
    end
  end
  im.SameLine()
  if im.SmallButton("Invert Selection") then
    for _, vehicle in ipairs(vehicleList) do
      if isVehicleVisible(vehicle) then vehicle[2][0] = not vehicle[2][0] end
    end
  end

  local halfWidth = im.GetContentRegionAvailWidth() / 2
  if im.BeginChild1("unselectedSection", im.ImVec2(halfWidth, 0), true) then
    im.Text("Unselected Models")
    if im.BeginChild1("unselectedVehs", im.ImVec2(0, 0), true) then
      drawVehicleSelectionList(false)
    end
  end
  im.EndChild()
  im.EndChild()

  im.SameLine()
  if im.BeginChild1("selected", im.ImVec2(halfWidth, 0), true) then
    im.Text("Selected Models")
    if im.BeginChild1("selectedVehs", im.ImVec2(0, 0), true) then
      drawVehicleSelectionList(true)
    end
  end
  im.EndChild()
  im.EndChild()

  im.EndTabItem()
end

function M.getSelectedModels()
  ensurePopulated()
  local models = {}
  for _, vehicle in pairs(vehicleList) do
    if isVehicleVisible(vehicle) and vehicle[2][0] then
      table.insert(models, vehicle[1])
    end
  end

  if not models[1] then
    models = {getPlayerVehicle(0).JBeam}
  end

  return models
end

function M.getSelectedCount()
  ensurePopulated()
  local count = 0
  for _, vehicle in pairs(vehicleList) do
    if isVehicleVisible(vehicle) and vehicle[2][0] then
      count = count + 1
    end
  end
  return count
end

function M.repopulate()
  populate()
end

return M
