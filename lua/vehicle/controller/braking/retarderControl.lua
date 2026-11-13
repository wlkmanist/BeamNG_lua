-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--Purpose: Provides selectable auxiliary braking for vehicles equipped with a hydrodynamic retarder

local M = {}
M.type = "auxiliary"

local controlledRetarder

local throttleDisableElectricsName
local throttleDisableThreshold
local disableWhenThrottleApplied

local mode

local desiredRetarderCoef

local electricsNameActual
local electricsNameSetting
local electricsNameIsEnabled
local electricsNameLevelIndex

local lastRetarderCoef = -1
local retarderManualLevels
local retarderActiveSettingIndex

local hasBuiltPie

local modes = {
  off = "off",
  auto = "auto",
  manual = "manual"
}

local retarderSettings

local stateData
local stateDataNameSettingIndex

local function applyRetarderSetting(setting, silent)
  if setting == modes.auto then
    mode = modes.auto
    if not silent then
      guihooks.message("ui.radialmenu2.retarderControl.setAuto", 3, "vehicle.retarder." .. controlledRetarder.name)
    end
  elseif setting == modes.off then
    mode = modes.off
    if not silent then
      guihooks.message("ui.radialmenu2.retarderControl.setOff", 3, "vehicle.retarder." .. controlledRetarder.name)
    end
  elseif type(setting) == "number" then
    mode = modes.manual
    desiredRetarderCoef = setting
    if not silent then
      guihooks.message({txt = "ui.radialmenu2.retarderControl.setManual", context = {retarderLevel = desiredRetarderCoef * 100}}, 3, "vehicle.retarder." .. controlledRetarder.name)
    end
  else
    log("E", "retarderControl.applyRetarderSetting", string.format("Invalid setting: %q", setting))
    return
  end
end

local function setRetarderSettingIndex(settingIndex, silent)
  local setting = retarderSettings[settingIndex]
  if setting then
    retarderActiveSettingIndex = settingIndex
    applyRetarderSetting(setting, silent)
  end
end

local function setRetarderMode(newMode)
  for settingIndex, setting in pairs(retarderSettings) do
    if setting == newMode then
      setRetarderSettingIndex(settingIndex)
      return
    end
  end
  log("W", "retarderControl.setRetarderMode", string.format("Invalid mode: %q", newMode))
end

local function changeRetarderSettingIndex(indexChange)
  local newIndex = clamp(retarderActiveSettingIndex + indexChange, 1, #retarderSettings)
  setRetarderSettingIndex(newIndex)
end

local function updateGFX(dt)
  local retarderCoef
  local absDisableCoef = clamp(1 - (electrics.values.absActive or 0), 0, 1)

  if mode == modes.off then
    --retarder always off
    retarderCoef = 0
  elseif mode == modes.auto then
    --retarder copies brake application
    local brakeInput = electrics.values.brake_input or 0
    retarderCoef = brakeInput
  elseif mode == modes.manual then
    --manual retarder level
    retarderCoef = desiredRetarderCoef
  end

  --disable retarder when throttle is applied
  if disableWhenThrottleApplied and ((electrics.values[throttleDisableElectricsName] or 0) > throttleDisableThreshold or (electrics.values.isShifting or false)) then
    retarderCoef = 0
  end

  --disable retarder when ABS is active
  retarderCoef = clamp(retarderCoef * absDisableCoef, 0, 1)

  --apply retarder coef to hardware
  if retarderCoef ~= lastRetarderCoef then
    controlledRetarder:setRetarderCoef(retarderCoef)
    lastRetarderCoef = retarderCoef
  end

  electrics.values[electricsNameSetting] = retarderCoef
  electrics.values[electricsNameActual] = retarderCoef
  electrics.values[electricsNameIsEnabled] = retarderCoef > 0
  electrics.values[electricsNameLevelIndex] = retarderActiveSettingIndex
end

local function reset(jbeamData)
  lastRetarderCoef = -1
end

local function init(jbeamData)
  stateData = {}
  stateDataNameSettingIndex = M.name .. "_settingIndex"

  local retarderName = jbeamData.controlledRetarder or "retarder"
  controlledRetarder = powertrain.getDevice(retarderName)
  if not controlledRetarder or type(controlledRetarder.setRetarderCoef) ~= "function" then
    log("E", "retarderControl.init", string.format("Can't find requested retarder with name: %q, retarder controls won't work!", retarderName))
    M.updateGFX = nop
    return
  end

  electricsNameActual = jbeamData.electricsNameActual or (retarderName .. "_actual")
  electricsNameSetting = jbeamData.electricsNameSetting or (retarderName .. "_setting")
  electricsNameIsEnabled = jbeamData.electricsNameIsEnabled or (retarderName .. "_isEnabled")
  electricsNameLevelIndex = jbeamData.electricsNameLevelIndex or (retarderName .. "_levelIndex")

  retarderManualLevels = jbeamData.retarderManualLevels or {0.2, 0.4, 0.6, 0.8, 1.0}

  throttleDisableElectricsName = jbeamData.throttleDisableElectricsName or "throttle"
  throttleDisableThreshold = jbeamData.throttleDisableThreshold or 0.001
  disableWhenThrottleApplied = jbeamData.disableWhenThrottleApplied
  if disableWhenThrottleApplied == nil then
    disableWhenThrottleApplied = true
  end

  local hasAutoMode = jbeamData.hasAutoMode or false

  retarderSettings = {}
  if hasAutoMode then
    table.insert(retarderSettings, modes.auto)
  end
  table.insert(retarderSettings, modes.off)
  for _, manualLevel in pairs(retarderManualLevels) do
    table.insert(retarderSettings, manualLevel)
  end

  desiredRetarderCoef = 0
  setRetarderMode(modes.off)

  if not hasBuiltPie then
    core_quickAccess.addEntry(
      {
        level = "/root/playerVehicle/vehicleFeatures/",
        generator = function(entries)
          local folder = {
            title = "ui.radialmenu2.retarderControl",
            icon = "retarderControl",
            ["goto"] = "/root/playerVehicle/vehicleFeatures/retarderControl/",
            uniqueID = "retarderControl"
          }
          table.insert(entries, folder)
        end
      }
    )
    core_quickAccess.addEntry(
      {
        level = "/root/playerVehicle/vehicleFeatures/retarderControl/",
        generator = function(entries)
          if hasAutoMode then
            local autoEntry = {
              title = "ui.radialmenu2.retarderControl.setAuto",
              icon = "retarder_auto",
              uniqueID = "retarderControlerSetAuto_" .. M.name,
              onSelect = function()
                controller.getControllerSafe(M.name).setRetarderMode(modes.auto)
                return {"reload"}
              end
            }
            table.insert(entries, autoEntry)
          end
          local offEntry = {
            title = "ui.radialmenu2.retarderControl.setOff",
            icon = "retarder_off",
            uniqueID = "retarderControlerSetOff_" .. M.name,
            onSelect = function()
              controller.getControllerSafe(M.name).setRetarderMode(modes.off)
              return {"reload"}
            end
          }
          table.insert(entries, offEntry)

          for i, manualLevel in pairs(retarderManualLevels) do
            local settingIndex = i + 1 + (hasAutoMode and 1 or 0) --offset for auto mode and off mode
            local manualEntry = {
              title = {txt = "ui.radialmenu2.retarderControl.setManual", context = {retarderLevel = manualLevel * 100}},
              icon = "retarder_manual",
              uniqueID = "retarderControlerSetManual_" .. M.name .. "_" .. i,
              onSelect = function()
                controller.getControllerSafe(M.name).setRetarderSettingIndex(settingIndex)
                return {"reload"}
              end
            }
            table.insert(entries, manualEntry)
          end
        end
      }
    )
  end
  hasBuiltPie = true
end

local function getState()
  if retarderActiveSettingIndex then
    stateData[stateDataNameSettingIndex] = retarderActiveSettingIndex
  end
  return stateData
end

local function setState(data)
  if not data or not retarderSettings then
    return
  end

  local newSettingIndex = data[stateDataNameSettingIndex]
  if type(newSettingIndex) == "number" and newSettingIndex == newSettingIndex and retarderSettings[newSettingIndex] and newSettingIndex ~= retarderActiveSettingIndex then
    setRetarderSettingIndex(newSettingIndex, true)
  end
end

M.init = init
M.reset = reset
M.updateGFX = updateGFX

M.setRetarderSettingIndex = setRetarderSettingIndex
M.changeRetarderSettingIndex = changeRetarderSettingIndex
M.setRetarderMode = setRetarderMode

M.getState = getState
M.setState = setState

return M
