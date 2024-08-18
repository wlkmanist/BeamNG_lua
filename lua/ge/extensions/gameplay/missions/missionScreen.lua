-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'gameplay_missions_missions', 'gameplay_markerInteraction'}
local preselectedMissionId = nil

local repairCostMoney = 1000
local repairCostBonusStar = 1
M.getRepairCostForStartingRepairType = function(type)
  if type == "moneyRepair" then return { money = repairCostMoney} end
  if type == "bonusStarRepair" then return { bonusStars = repairCostMoney} end
end

-- formats a single mission.
local function formatMission(m)
  local info = {
    id = m.id,
    name = m.name,
    description = m.description,
    previews = {m.previewFile},
    missionTypeLabel = m.missionTypeLabel or mission.missionType,
    userSettings = m:getUserSettingsData() or {},
    defaultUserSettings = m.defaultUserSettings or {},
    activeStars = M.getActiveStarsForUserSettings(m.id, m.defaultUserSettings),
    additionalAttributes = {},
    progress = m.saveData.progress,
    currentProgressKey = m.currentProgressKey or m.defaultProgressKey,
    unlocks = m.unlocks,
    hasUserSettingsUnlocked = gameplay_missions_progress.missionHasUserSettingsUnlocked(m.id),
    devMission = m.devMission,
  }

  info.hasUserSettings = #info.userSettings > 0
  local additionalAttributes, additionalAttributesSortedKeys = gameplay_missions_missions.getAdditionalAttributes()

  for _, attKey in ipairs(additionalAttributesSortedKeys) do
    local att = additionalAttributes[attKey]
    local mAttKey = m.additionalAttributes[attKey]
    local val
    if type(mAttKey) == 'string' then
      val = att.valuesByKey[m.additionalAttributes[attKey]]
    elseif type(mAttKey) == 'table' then
      val = m.additionalAttributes[attKey]
    end
    if val then
      table.insert(info.additionalAttributes, {
        icon = att.icon or "",
        labelKey = att.translationKey,
        valueKey = val.translationKey
      })
    end
  end
  for _, customAtt in ipairs(m.customAdditionalAttributes or {}) do
    table.insert(info.additionalAttributes, customAtt)
  end
  info.formattedProgress =  gameplay_missions_progress.formatSaveDataForUi(m.id)

  -- pre-format aggregates for the UI. This formatting might be the default later and then be moved to gameplay_missions_progress
  for key, prog in pairs(info.formattedProgress.formattedProgressByKey) do
    local ownAggregate = {}
    for i, label in ipairs(prog.ownAggregate.labels) do
      table.insert(ownAggregate, {
        label = label,
        value = prog.ownAggregate.rows[1][i]
      })
    end
    prog.ownAggregate = ownAggregate
  end

  info.leaderboardKey = m.defaultLeaderboardKey or 'recent'

  --info.gameContextUiButtons = {}
  info.gameContextUiButtons = m.getMissionScreenDataUiButtons and m:getMissionScreenDataUiButtons()
  return info
end

-- gets all the missions at the current location (mission marker), and returns them in a list already formatted.
local function getMissionsAtCurrentLocationFormatted()
  if not M.isStateFreeroam() then return nil end
  local dataToSend = {}
  local currentInteractableElements = gameplay_markerInteraction.getCurrentInteractableElements()
  if not currentInteractableElements then return end

  for _, m in ipairs(currentInteractableElements) do
    if m.missionId then
      table.insert(dataToSend, M.formatMission(gameplay_missions_missions.getMissionById(m.missionId)))
    end
  end
  table.sort(dataToSend, gameplay_missions_unlocks.depthIdSort)
  return dataToSend
end

local function formatOngoingMission()
 local activeMission = nil
  for _, m in ipairs(gameplay_missions_missions.get()) do
    if m.id == gameplay_missions_missionManager.getForegroundMissionId() then
      activeMission = m
    end
  end
  return {context = 'ongoingMission', mission = M.formatMission(activeMission)}
end

local function getMissionScreenData()
  if gameplay_missions_missionManager.getForegroundMissionId() ~= nil then
    -- case when there is currently a mission going on.
    return formatOngoingMission()
  else
    -- case when there are no ongoing missions.
    local missions = M.getMissionsAtCurrentLocationFormatted()
    if M.isStateFreeroam() and missions and next(missions) then
      extensions.hook("onAvailableMissionsSentToUi", context)
      local ret = {
        context = 'availableMissions',
        missions = missions,
        --isWalking = gameplay_walk.isWalking(),
        --isCareerActive = career_career.isActive(),
        selectedMissionId = preselectedMissionId,
      }

      if career_career.isActive() then
        if career_modules_permissions then
          local status, message = career_modules_permissions.getStatusForTag("interactMission")
          if message then
            ret.startWarning = {label = message, title ="Delivery in progress!" }
          end
        end
      end
      --[[ TODO: preselected mission refactor
      if fromMissionMenu then
        preselectedMissionId = nil
      end
      ]]
      return ret
    else
      if fromMissionMenu then
        preselectedMissionId = nil
      end
      return {context = 'empty' }
    end
  end
end

local defaultStartingOptions = {{ enabled = true, label = "ui.scenarios.start.start", type = "defaultStart" }}
local cantStartWalkingOptions = {{ enabled = false, label = "Cannot start this challenge on foot with current settings." }}
local function sendStartingOptions(id, options)
  local ret = {
    missionId = id,
    options = options,
  }
  guihooks.trigger("missionStartingOptionsForUserSettingsReady", ret)
  return
end

local function requestStartingOptionsForUserSettings(id, userSettings)
  local m = gameplay_missions_missions.getMissionById(id)
  if m then
    if not career_career.isActive() then
      -- outside of career, a mission can always be started
      sendStartingOptions(id, defaultStartingOptions)
      return
    end

    if (career_modules_linearTutorial and career_modules_linearTutorial.isLinearTutorialActive()) then
      -- during the tutorial, mission can be started without repair.
      sendStartingOptions(id, defaultStartingOptions)
      return
    end

    local missionUserSettings = m:getUserSettingsData() or {}
    
    local missionUserSettingByKey = {}
    for _, setting in ipairs(missionUserSettings) do
      missionUserSettingByKey[setting.key] = setting
    end

    -- figure out if the user intends to use their own vehicle.
    local usesOwnVehicle = false
    for _, setting in ipairs(userSettings) do
      if setting.key == "setupModuleVehicles" and missionUserSettingByKey[setting.key] then
        local val = missionUserSettingByKey[setting.key].values[setting.value]
        if val and val.type == "player" then
          usesOwnVehicle = true
        end
      end
    end

    if not usesOwnVehicle then
      -- if not using own vehicle, mission can always be started normally.
      sendStartingOptions(id, defaultStartingOptions)
      return
    end

    -- if the player uses own vehicle and walks, disable starting.
    if gameplay_walk.isWalking() then
      sendStartingOptions(id, cantStartWalkingOptions)
      return
    end

    -- if we reached this, it means we need to check the repair status of the car and send options accordingly.
    -- getting repair status is async though.
    local currentVehicle = career_modules_inventory.getCurrentVehicle()
    if not currentVehicle then
      -- this shouldnt happen tho... just to be sure.
      log("W","","Player has no vehicle, but none of the previous starting options triggered. Something wrong?")
      sendStartingOptions(id, {{enabled=false, label="Something wrong..."}})
      return
    end

    career_modules_inventory.updatePartConditions(career_modules_inventory.getVehicleIdFromInventoryId(currentVehicle), currentVehicle,
    function()
      local needsRepair = career_modules_insurance.inventoryVehNeedsRepair(currentVehicle)
      if not needsRepair then
        -- all good! vehicle not damaged, can start normally.
        sendStartingOptions(id, defaultStartingOptions)
        return
      end

      -- build repair options based on player currency.
      local bonusStarCount = career_modules_playerAttributes.getAttributeValue('bonusStars')
      local money = career_modules_playerAttributes.getAttributeValue('money')
      local repairOptions = {
        {
          enabled = false,
          label = "Vehicle needs to be repaired to start",
          optionLabel = "Don't repair",
        }, {
          enabled = bonusStarCount >= repairCostBonusStar,
          label = bonusStarCount >= repairCostBonusStar and "Pay Repair and Start" or "Not enough bonus stars for repair",
          optionsLabel = string.format("Repair for %d bonus star", repairCostBonusStar),
          type = "bonusStarRepair"
        }, {
          enabled = money >= repairCostMoney,
          label = money >= repairCostMoney and "Pay Repair and Start" or "Not enough money to repair",
          optionsLabel = string.format("Repair for %d$",repairCostMoney),
          type = "moneyRepair",
        }
      }
      sendStartingOptions(id, repairOptions)
    end)
  end
end
M.requestStartingOptionsForUserSettings = requestStartingOptionsForUserSettings



local function getActiveStarsForUserSettings(id, userSettings)
  local m = gameplay_missions_missions.getMissionById(id)
  if m then
    local defaultUserSettings = m.defaultUserSettings
    local flattendedSettings = {}
    for _, setting in ipairs(userSettings) do
      flattendedSettings[setting.key] = setting.value
    end

    -- check if settings are actually equal
    local same = true
    for k, v in pairs(defaultUserSettings) do
      same = same and flattendedSettings[k] == v
    end
    for k, v in pairs(flattendedSettings) do
      same = same and defaultUserSettings[k] == v
    end

    -- if same, enable all stars. if false, enable only bonus stars.
    -- TODO: make this a mission base class function. this way, each mission can handle this on its own.
    -- for example, some bonus stars could only be active with specific user settings (traffic on etc)
    local starKeys, defaultCache = m.careerSetup._activeStarCache.sortedStars, m.careerSetup._activeStarCache.defaultStarKeysByKey
    local activeStars = {}
    for _, key in ipairs(starKeys) do
      if defaultCache[key] then
        activeStars[key] = same
      else
        activeStars[key] = true
      end
    end

    -- message if stars are disabled...
    local message = nil
    if not same then
      message = "Default Stars are only available with default mission settings."
    end

    return {
      message = message,
      activeStars = activeStars
    }
  end
  return {}
end
M.getActiveStarsForUserSettings = getActiveStarsForUserSettings


local function startMissionById(id, userSettings, startingOptions)
  local m = gameplay_missions_missions.getMissionById(id)
  if m then
    if m.unlocks.startable then
      local flatSettings = {}
      for _, setting in ipairs(userSettings) do
        flatSettings[setting.key] = setting.value
      end
      gameplay_missions_missionManager.startWithFade(m, flatSettings, startingOptions or {})
      return
    else
      log("E","","Trying to start mission that is not startable due to unlocks: " .. dumps(id))
    end
  else
    log("E","","Trying to start mission with invalid id: " .. dumps(id))
  end

end

local function stopMissionById(id, force)
  for _, m in ipairs(gameplay_missions_missions.get()) do
    if m.id == id then
      gameplay_missions_missionManager.attemptAbandonMissionWithFade(m, force)
      return
    end
  end
end

local function changeUserSettings(id, settings)
  local mission = gameplay_missions_missions.getMissionById(id)
  if not mission then return end
  mission:processUserSettings(settings)
  guihooks.trigger('missionProgressKeyChanged', id, mission.currentProgressKey)
end


local function setPreselectedMissionId(mId)
  preselectedMissionId = mId
end

local function isStateFreeroam()
  if core_gamestate.state and (core_gamestate.state.state == "freeroam" or core_gamestate.state.state == 'career') then
    return true
  end
  return false
end

M.isStateFreeroam = isStateFreeroam

M.formatMission = formatMission
M.getMissionsAtCurrentLocationFormatted = getMissionsAtCurrentLocationFormatted
M.startMissionById = startMissionById
M.stopMissionById = stopMissionById
M.changeUserSettings = changeUserSettings
M.setPreselectedMissionId = setPreselectedMissionId
M.getMissionScreenData = getMissionScreenData
return M