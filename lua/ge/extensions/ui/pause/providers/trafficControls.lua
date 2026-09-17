-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local buttonModule = require("ge/extensions/ui/gridSelectorUtils/buttonModule")
local buttonInstance = buttonModule.create()
local actionButtons = {}

local function getTrafficExt()
  return gameplay_traffic or (extensions and extensions.gameplay_traffic)
end

local function getParkingExt()
  return gameplay_parking or (extensions and extensions.gameplay_parking)
end

local function getPoliceExt()
  return gameplay_police or (extensions and extensions.gameplay_police)
end

local function countVehicleIds(vehIds)
  local counts = {
    total = 0,
    active = 0,
    inactive = 0,
  }

  if type(vehIds) ~= "table" then return counts end

  for _, vehId in ipairs(vehIds) do
    if type(vehId) == "number" and getObjectByID(vehId) then
      counts.total = counts.total + 1
      if be:getObjectActive(vehId) then
        counts.active = counts.active + 1
      else
        counts.inactive = counts.inactive + 1
      end
    end
  end

  return counts
end

local function getTrafficVehicleIds()
  local ids = {}
  local seen = {}
  local trafficExt = getTrafficExt()
  local state = trafficExt and trafficExt.getState and trafficExt.getState() or "off"
  local trafficList = trafficExt and trafficExt.getTrafficList and trafficExt.getTrafficList() or nil

  if state == "on" and type(trafficList) == "table" then
    for _, vehId in ipairs(trafficList) do
      if type(vehId) == "number" and getObjectByID(vehId) and not seen[vehId] then
        table.insert(ids, vehId)
        seen[vehId] = true
      end
    end
  end

  return ids
end

local function isPoliceTrafficVehicle(vehId)
  local obj = getObjectByID(vehId)
  if not obj then return false end
  local modelData = core_vehicles.getModel(obj.jbeam)
  local _, configKey = path.splitWithoutExt(obj.partConfig)
  local configData = modelData and modelData.configs and modelData.configs[configKey]
  local configTypeLower = string.lower(configData and configData["Config Type"] or "")
  if configTypeLower == "police" then return true end

  local pc = string.lower(obj.partConfig or "")
  return string.endswith(pc, ".pc") and string.find(pc, "police") ~= nil
end

local function countPoliceVehicleIds(policeExt, trafficIds)
  local policeIds = policeExt and policeExt.getPoliceVehicles and tableKeys(policeExt.getPoliceVehicles()) or nil
  local counts = countVehicleIds(policeIds)

  if counts.total > 0 then return counts end

  local fallbackIds = {}
  for _, vehId in ipairs(trafficIds or {}) do
    if isPoliceTrafficVehicle(vehId) then
      table.insert(fallbackIds, vehId)
    end
  end

  return countVehicleIds(fallbackIds)
end

local function getCounts()
  local parkingExt = getParkingExt()
  local policeExt = getPoliceExt()
  local trafficIds = getTrafficVehicleIds()
  local driving = countVehicleIds(trafficIds)
  local parked = countVehicleIds(parkingExt and parkingExt.getParkedCarsList and parkingExt.getParkedCarsList() or nil)
  local police = countPoliceVehicleIds(policeExt, trafficIds)

  return {
    driving = driving,
    parked = parked,
    police = police,
    total = {
      total = driving.total + parked.total,
      active = driving.active + parked.active,
      inactive = driving.inactive + parked.inactive,
    },
  }
end

local function startTraffic()
  local trafficExt = getTrafficExt()
  if not trafficExt then return false end
  trafficExt.activate()
  trafficExt.setTrafficVars({aiMode = "traffic", enableRandomEvents = true})
  if extensions and extensions.telemetry_core then
    extensions.telemetry_core.startActivity("trafficEnabled")
  end
  return true
end

local function stopTraffic()
  local trafficExt = getTrafficExt()
  if not trafficExt then return false end
  trafficExt.deactivate(true)
  if extensions and extensions.telemetry_core then
    extensions.telemetry_core.endActivity("trafficEnabled")
  end
  return true
end

local function removeTraffic()
  local parkingExt = getParkingExt()
  local trafficExt = getTrafficExt()
  if parkingExt and parkingExt.deleteVehicles then
    parkingExt.deleteVehicles()
  end
  if trafficExt and trafficExt.deleteVehicles then
    trafficExt.deleteVehicles()
  end
  if extensions and extensions.telemetry_core then
    extensions.telemetry_core.endActivity("trafficEnabled")
  end
  return true
end

local function spawnTraffic(useTraffic, useParked, options)
  local trafficExt = getTrafficExt()
  if not trafficExt or not trafficExt.setupTrafficWaitForUi then return false end
  trafficExt.setupTrafficWaitForUi(useTraffic, useParked, options)
  if extensions and extensions.telemetry_core then
    extensions.telemetry_core.startActivity("trafficEnabled")
  end
  return true
end

local function isTrafficEnabled(state, parkingActive, counts)
  local totalCount = counts and counts.total and counts.total.total or 0
  return totalCount > 0 and (state == "on" or parkingActive == true)
end

local function toggleTraffic()
  local trafficExt = getTrafficExt()
  local parkingExt = getParkingExt()
  local counts = getCounts()
  local state = trafficExt and trafficExt.getState and trafficExt.getState() or "off"
  local parkingActive = parkingExt and parkingExt.getState and parkingExt.getState() or false

  if isTrafficEnabled(state, parkingActive, counts) then
    return removeTraffic()
  end

  return spawnTraffic(true, true)
end

local function getOrCreateButton(actionName, callback, meta)
  if actionButtons[actionName] then return actionButtons[actionName] end
  meta = meta or {}
  meta.action = actionName
  actionButtons[actionName] = buttonInstance.addButton(callback, meta)
  return actionButtons[actionName]
end

local function cloneButton(meta, disabled)
  local cloned = deepcopy(meta)
  cloned.disabled = disabled == true
  return cloned
end

local function getResolvedTrafficAmount()
  local amount = settings.getValue("trafficAmount")
  if amount == 0 then
    amount = getMaxVehicleAmount(10)
  end

  local trafficExt = getTrafficExt()
  if trafficExt and trafficExt.getIdealSpawnAmount then
    amount = trafficExt.getIdealSpawnAmount(amount)
  end

  return math.max(0, math.floor((tonumber(amount) or 0) + 0.5))
end

local function getResolvedExtraTrafficAmount()
  return math.max(0, math.floor((tonumber(settings.getValue("trafficExtraAmount")) or 0) + 0.5))
end

local function getResolvedParkedAmount()
  local amount = settings.getValue("trafficParkedAmount")
  if amount == 0 then
    local trafficExt = getTrafficExt()
    if trafficExt and trafficExt.getIdealSpawnAmount then
      amount = clamp(trafficExt.getIdealSpawnAmount(nil, true), 4, 16)
    else
      amount = clamp(getMaxVehicleAmount(10), 4, 16)
    end
  end

  return math.max(0, math.floor((tonumber(amount) or 0) + 0.5))
end

local function buildSpawnAmountMetadata(useTraffic, useParked, options)
  options = type(options) == "table" and options or {}
  local trafficAmount = useTraffic and getResolvedTrafficAmount() or 0
  local extraTrafficAmount = useTraffic and getResolvedExtraTrafficAmount() or 0
  local policeAmount = useTraffic and options.police and math.ceil(trafficAmount * 0.25) or 0
  local parkedAmount = 0

  if useParked and (not useTraffic or settings.getValue("trafficParkedVehicles")) then
    parkedAmount = getResolvedParkedAmount()
  end

  local totalTrafficAmount = trafficAmount + extraTrafficAmount

  return {
    total = totalTrafficAmount + parkedAmount,
    traffic = totalTrafficAmount,
    activeTraffic = trafficAmount,
    extraTraffic = extraTrafficAmount,
    normalTraffic = math.max(0, totalTrafficAmount - policeAmount),
    police = policeAmount,
    parked = parkedAmount,
  }
end

local function cloneSpawnButton(meta, disabled, useTraffic, useParked, options)
  local cloned = cloneButton(meta, disabled)
  cloned.spawnAmount = buildSpawnAmountMetadata(useTraffic, useParked, options)
  return cloned
end

local function buildActions(editable, counts)
  local trafficExt = getTrafficExt()
  local state = trafficExt and trafficExt.getState and trafficExt.getState() or "off"
  local canChange = editable ~= false

  local startBtn = getOrCreateButton("startTraffic", startTraffic, {
    label = _tr("ui.radialmenu2.traffic.start"),
    icon = "play",
    accent = "secondary",
  })
  local stopBtn = getOrCreateButton("stopTraffic", stopTraffic, {
    label = _tr("ui.radialmenu2.traffic.stop"),
    icon = "pause",
    accent = "secondary",
  })
  local removeBtn = getOrCreateButton("removeTraffic", removeTraffic, {
    label = _tr("ui.radialmenu2.traffic.remove"),
    icon = "trashBin1",
    accent = "attention",
  })
  local spawnNormalBtn = getOrCreateButton("spawnNormalTraffic", function()
    return spawnTraffic(true, true)
  end, {
    label = _tr("ui.radialmenu2.traffic.spawnNormal"),
    icon = "cars",
    accent = "secondary",
  })
  local spawnPoliceBtn = getOrCreateButton("spawnPoliceTraffic", function()
    return spawnTraffic(true, true, {police = true})
  end, {
    label = _tr("ui.radialmenu2.traffic.spawnPolice"),
    icon = "carChase01",
    accent = "secondary",
  })
  local spawnParkedBtn = getOrCreateButton("spawnParkedTraffic", function()
    return spawnTraffic(false, true)
  end, {
    label = _tr("ui.radialmenu2.traffic.spawnParked"),
    icon = "parking",
    accent = "secondary",
  })
  local toggleBtn = getOrCreateButton("toggleTraffic", toggleTraffic, {
    label = "Traffic",
    icon = "trafficLight",
    accent = "secondary",
  })
  return {
    toggle = cloneButton(toggleBtn, not canChange),
    controls = {
      cloneButton(startBtn, not canChange or be:getObjectCount() <= 1),
      cloneButton(stopBtn, not canChange or state ~= "on"),
      cloneButton(removeBtn, not canChange or state ~= "on"),
    },
    spawn = {
      cloneSpawnButton(spawnNormalBtn, not canChange, true, true),
      cloneSpawnButton(spawnPoliceBtn, not canChange, true, true, {police = true}),
      cloneSpawnButton(spawnParkedBtn, not canChange, false, true),
    },
  }
end

function M.getData(payload)
  payload = type(payload) == "table" and payload or {}
  local editable = payload.editable
  local trafficExt = getTrafficExt()
  local parkingExt = getParkingExt()
  local counts = getCounts()
  local state = trafficExt and trafficExt.getState and trafficExt.getState() or "off"
  local parkingActive = parkingExt and parkingExt.getState and parkingExt.getState() or false

  local enabled = isTrafficEnabled(state, parkingActive, counts)
  local actions = buildActions(editable, counts)

  return {
    requestId = payload.requestId,
    state = state,
    parkingActive = parkingActive,
    enabled = enabled,
    canActivateExisting = be:getObjectCount() > 1,
    driving = counts.driving,
    parked = counts.parked,
    police = counts.police,
    total = counts.total,
    actions = actions,
  }
end

function M.executeTrafficControlAction(buttonId, payload)
  if not buttonId then return false end
  return buttonInstance.executeButton(buttonId, payload)
end

return M
