-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local splitScreenLayouts = require("ge/extensions/render/splitScreenLayouts")
local multiseatConfiguration = require("ge/extensions/ui/multiseat/multiseatConfiguration")
local M = {}

local PROVIDER_ID = "general"
local SAME_VEHICLE_FIELD = "sameVehicleForEveryone"
local GATHER_VEHICLES_FIELD = "gatherVehicles"
local RESEAT_PLAYERS_FIELD = "reseatAllPlayers"
local AUTOMATIC_COLOR_FIELD = "automaticColor"
local MAX_PER_PLAYER_LAYOUT_SETTING = 8
local HIGHER_PLAYER_COUNT_LAYOUT_SETTING = MAX_PER_PLAYER_LAYOUT_SETTING + 1

local function getScreenSize()
  local canvas = scenetree.findObject("Canvas")
  if canvas and canvas.getWindowClientSizeXY then
    local width, height = canvas:getWindowClientSizeXY()
    if width and height and width >= 2 and height >= 2 then
      return width, height
    end
  end
  local videoMode = GFXDevice.getVideoMode()
  if videoMode and videoMode.width and videoMode.height and videoMode.height >= 2 then
    return videoMode.width, videoMode.height
  end
  return 1920, 1080
end

local function buildLayoutField(playerCount, previewPlayerCount)
  local options = splitScreenLayouts.getOptions(previewPlayerCount or playerCount, getScreenSize())
  local value = settings.getValue("multiseatLayout" .. playerCount, "automatic")
  if value == "shared" then value = "automatic" end
  if playerCount == HIGHER_PLAYER_COUNT_LAYOUT_SETTING then
    for index = #options, 1, -1 do
      if options[index].value ~= "automatic" then
        table.remove(options, index)
      end
    end
  end
  return {
    id = "layout" .. playerCount,
    type = "layout",
    playerCount = playerCount,
    label = {
      txt = "ui.multiseat.settings.layout.playerCount",
      context = {count = playerCount == HIGHER_PLAYER_COUNT_LAYOUT_SETTING and "9+" or playerCount},
    },
    value = value,
    options = options,
  }
end

local function getPlayerMarkersEnabled()
  if core_multiseat and core_multiseat.getPlayerMarkersEnabled then
    return core_multiseat.getPlayerMarkersEnabled()
  end
  local enabled = settings.getValue("multiseatTags", true)
  return enabled ~= false and enabled ~= "never"
end

local function buildSameVehicleField()
  local vehicles, value = ui_multiseat_multiseatVehicles.getSharedVehicleOptions()
  if not vehicles then return nil end
  local options = {
    {
      value = "selector",
      label = "ui.multiseat.settings.pickVehicleFromSelector",
    },
  }
  for _, vehicle in ipairs(vehicles) do options[#options + 1] = vehicle end
  return {
    id = SAME_VEHICLE_FIELD,
    type = "actionSelect",
    label = "ui.multiseat.settings.sameVehicle",
    value = value,
    options = options,
  }
end

local function buildGatherVehiclesField()
  local options = ui_multiseat_multiseatVehicles.getGatherVehicleOptions()
  if not options then return nil end
  return {
    id = GATHER_VEHICLES_FIELD,
    type = "select",
    label = "ui.multiseat.settings.gatherVehicles",
    value = "",
    dropdown = true,
    allowEmpty = true,
    options = options,
  }
end

local function buildReseatPlayersField()
  if #ui_multiseat_multiseatVehicles.getOwnedVehicles() < 1 then return nil end
  return {
    id = RESEAT_PLAYERS_FIELD,
    type = "switch",
    label = "ui.multiseat.settings.reseatAllPlayers",
    value = false,
  }
end

function M.onGetMultiseatGameSettings(providers)
  local fields = {}
  local assignedPlayerCount = #multiseatConfiguration.getPreview().joinedPersonas
  fields[#fields + 1] = buildSameVehicleField()
  fields[#fields + 1] = buildGatherVehiclesField()
  fields[#fields + 1] = buildReseatPlayersField()
  fields[#fields + 1] = {
    id = AUTOMATIC_COLOR_FIELD,
    type = "switch",
    label = "ui.multiseat.settings.automaticColor",
    value = ui_multiseat_multiseatVehicles.getAutomaticColorEnabled(),
  }
  fields[#fields + 1] = {
    id = "showPlayerMarkers",
    type = "switch",
    label = "ui.options.gameplay.multiseatTags",
    value = getPlayerMarkersEnabled(),
    applyMode = "immediate",
  }
  for playerCount = 2, HIGHER_PLAYER_COUNT_LAYOUT_SETTING do
    local previewPlayerCount = playerCount == HIGHER_PLAYER_COUNT_LAYOUT_SETTING
      and math.max(playerCount, assignedPlayerCount)
      or playerCount
    fields[#fields + 1] = buildLayoutField(playerCount, previewPlayerCount)
  end

  providers[#providers + 1] = {
    id = PROVIDER_ID,
    title = "ui.multiseat.settings.general",
    placement = "afterVehicles",
    applyMode = "apply",
    fields = fields,
  }
end

function M.onMultiseatGameSettingAction(providerId, fieldId, result, value)
  if providerId ~= PROVIDER_ID then return end
  if fieldId == SAME_VEHICLE_FIELD then
    if value == "selector" then
      result.success = ui_multiseat_multiseatVehicles.openVehicleSelectorForAllPlayers()
    else
      result.success = ui_multiseat_multiseatVehicles.stageSameVehicleForAllPlayers(value)
    end
  end
end

function M.onMultiseatGameSettingChanged(providerId, fieldId, value)
  if providerId ~= PROVIDER_ID then return end
  if fieldId == AUTOMATIC_COLOR_FIELD then
    ui_multiseat_multiseatVehicles.stageAutomaticColorForAllPlayers(value)
  elseif fieldId == "showPlayerMarkers" then
    if core_multiseat and core_multiseat.setPlayerMarkersEnabled then
      core_multiseat.setPlayerMarkersEnabled(value)
    else
      settings.setValue("multiseatTags", value)
    end
  end
end

function M.onValidateMultiseatGameSettings(stagedSettings, _activeSettings, result)
  local general = stagedSettings[PROVIDER_ID]
  if not general then
    result.success = false
    result.reason = "missing_general_multiseat_settings"
    return
  end

  if type(general.showPlayerMarkers) ~= "boolean" then
    result.success = false
    result.reason = "invalid_player_marker_mode"
    return
  end
  if type(general[AUTOMATIC_COLOR_FIELD]) ~= "boolean" then
    result.success = false
    result.reason = "invalid_automatic_color_mode"
    return
  end

  for playerCount = 2, HIGHER_PLAYER_COUNT_LAYOUT_SETTING do
    local layoutId = general["layout" .. playerCount]
    local valid
    if playerCount == HIGHER_PLAYER_COUNT_LAYOUT_SETTING then
      valid = layoutId == "automatic"
    else
      valid = layoutId ~= "shared" and splitScreenLayouts.isValid(playerCount, layoutId)
    end
    if not valid then
      result.success = false
      result.reason = "invalid_multiseat_layout"
      return
    end
  end
end

function M.onApplyMultiseatGameSettings(stagedSettings, _activeSettings, result)
  local general = stagedSettings[PROVIDER_ID]
  if not general then return end

  settings.setValue("multiseatAutomaticColor", general[AUTOMATIC_COLOR_FIELD])
  for playerCount = 2, HIGHER_PLAYER_COUNT_LAYOUT_SETTING do
    settings.setValue("multiseatLayout" .. playerCount, general["layout" .. playerCount])
  end
  if render_splitScreen and render_splitScreen.refreshLayout then
    render_splitScreen.refreshLayout()
  end
  if general[GATHER_VEHICLES_FIELD] ~= nil and general[GATHER_VEHICLES_FIELD] ~= "" then
    ui_multiseat_multiseatVehicles.gatherVehicles(general[GATHER_VEHICLES_FIELD])
  end
  if general[RESEAT_PLAYERS_FIELD] == true then
    ui_multiseat_multiseatVehicles.reseatAllPlayers()
  end

  result.valueOverrides = result.valueOverrides or {}
  result.valueOverrides[PROVIDER_ID] = result.valueOverrides[PROVIDER_ID] or {}
  result.valueOverrides[PROVIDER_ID][GATHER_VEHICLES_FIELD] = ""
  result.valueOverrides[PROVIDER_ID][RESEAT_PLAYERS_FIELD] = false
end

return M
