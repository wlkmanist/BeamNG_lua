-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local im = ui_imgui

local debugMode = false
local forceUnfadeDebug = false
local debugModifierStates = {
  modifier1 = false,
  modifier2 = false,
  modifier3 = false,
  modifier4 = false,
  modifier5 = false,
  modifier6 = false
}

M.dependencies = {
  "core_input_actions",
  "core_input_bindings"
}

local modifierCategories = {
  vehicle_specific = true,
  vehicle = true,
  --gameplay = true,
  --slowmotion = true,
  --camera = true,
  --menu = true,
}

local actionsToAlwaysShow = {
  toggleWalkingMode = true,
  activateStarterMotor = true,
  toggleShowVehicleSpecificActions = true,
  toggle_slow_motion = true,
  toggleShowBindingsLegendApp = true,
  nodegrabberPadMode = true,
  switch_next_vehicle = true,
}

local actionJsonFilePath = "ui/bindingAppActions.json"

local MODIFIER_L_SHIFT = 1
local MODIFIER_R_SHIFT = 2
local MODIFIER_L_CTRL = 4
local MODIFIER_R_CTRL = 8
local MODIFIER_L_ALT = 16
local MODIFIER_R_ALT = 32
local MODIFIER1 = 64
local MODIFIER2 = 128
local MODIFIER3 = 256
local MODIFIER4 = 512
local MODIFIER5 = 1024
local MODIFIER6 = 2048

local actionLimit = 50

local actionData = {}
local actionCategoryActive = {}
local modifiersActive = {}
local boundModifierActions
local hideVehicleSpecificActionsOnModifierPressed
local showBasicDrivingControls = false
local basicDrivingSignature = nil
local basicDrivingLastGearboxMode = nil
local registeredGearboxModeVehicles = {}
local addActions

local jsonActions = {}

-- Fade control state (real-time based)
local fadeDelaySeconds = 7
local fadeDelayTimer = 0
local isFaded = false

-- Debug ImGui window to test fade behavior quickly
local function setDebug(enabled)
  debugMode = enabled
end

local function shouldFade()
  return false
  --[[if forceUnfadeDebug then return false end
  if fadeDelayTimer < fadeDelaySeconds then return false end
  if not settings.getValue("bindingsLegendShowApp", true) then return true end
  if actionCategoryActive["vehicleSpecific"] then return false end
  if not tableIsEmpty(actionData) then return false end
  return true]]
end

local function dispatchFadeIfChanged(forceValue)
  local newValue = forceValue
  if newValue == nil then
    newValue = shouldFade()
  end
  if isFaded ~= newValue then
    isFaded = newValue
    guihooks.trigger("setBindingsLegendFade", isFaded)
  end
end

local function resetFade()
  fadeDelayTimer = 0
end

local function fadeUpdate(dtReal)
  -- Evaluate fade while visible; when already faded we wait for explicit activity to unfade
  fadeDelayTimer = fadeDelayTimer + dtReal
  dispatchFadeIfChanged()
end

local function drawDebugWindow()
  if not debugMode or not im then return end
  if im.Begin("BindingsLegend Debug") then
    local var = im.FloatPtr(fadeDelaySeconds)
    im.PushItemWidth(120)
    if im.InputFloat("Fade delay (sec)", var, 0.5, 1.0, "%.1f", im.InputTextFlags_EnterReturnsTrue) then
      fadeDelaySeconds = math.max(0, var[0])
    end

    im.Separator()
    im.Text("Delay Timer: " .. string.format("%.2f", fadeDelayTimer))
    im.Text("VehicleSpecific visible: " .. tostring(actionCategoryActive["vehicleSpecific"]))
    im.Text("Should fade:   " .. tostring(shouldFade()))
    im.Text("Is faded:      " .. tostring(isFaded))

    local forceUnfade = im.BoolPtr(forceUnfadeDebug)
    if im.Checkbox("Force Unfade", forceUnfade) then
      forceUnfadeDebug = forceUnfade[0]
    end

    im.SameLine()
    if im.Button("Force Fade") then
      dispatchFadeIfChanged(true)
    end

    im.Separator()
    if im.Button("Show Vehicle Specific") then
      M.enableShowVehicleSpecificActions(true)
    end

    im.SameLine()
    if im.Button("Hide Vehicle Specific") then
      M.enableShowVehicleSpecificActions(false)
    end

    im.SameLine()
    if im.Button("Trigger Vehicle Switch") then
      local currentVehicleId = be:getPlayerVehicleID(0)
      if currentVehicleId then
        M.onVehicleSwitched(0, currentVehicleId, 0)
      end
    end

    im.Separator()
    im.Text("Modifiers:")
    local modifierChanged = false

    for i = 1, 6 do
      local modifierKey = "modifier" .. i
      local modifierPtr = im.BoolPtr(debugModifierStates[modifierKey])
      if im.Checkbox("Modifier " .. i, modifierPtr) then
        debugModifierStates[modifierKey] = modifierPtr[0]
        modifierChanged = true
      end
      if i % 3 ~= 0 then
        im.SameLine()
      end
    end

    if modifierChanged then
      local newModifiers = 0
      if debugModifierStates.modifier1 then newModifiers = bit.bor(newModifiers, MODIFIER1) end
      if debugModifierStates.modifier2 then newModifiers = bit.bor(newModifiers, MODIFIER2) end
      if debugModifierStates.modifier3 then newModifiers = bit.bor(newModifiers, MODIFIER3) end
      if debugModifierStates.modifier4 then newModifiers = bit.bor(newModifiers, MODIFIER4) end
      if debugModifierStates.modifier5 then newModifiers = bit.bor(newModifiers, MODIFIER5) end
      if debugModifierStates.modifier6 then newModifiers = bit.bor(newModifiers, MODIFIER6) end
      M.onModifierChanged(newModifiers)
    end
  end
  im.End()
end

local function isActionMapActive(actionMapName)
  local name = actionMapName.."ActionMap"
  for _, actionMap in ipairs(ActionMap:getList().active) do
    if actionMap.enabled and actionMap.name == name then
      return true
    end
  end
  return false
end

local function parseActionDirection(action)
  if not action.direction then return end
  return action.direction:match("^(%S+)")
end

local function getVehicleSpecificActions()
  local result = {}
  local actionsByName = {}
  local activeActions = core_input_actions.getActiveActions()
  for _, device in ipairs(core_input_bindings.bindings) do
    for _, binding in ipairs(device.contents.bindings) do
      local actionInfo = activeActions[binding.action]
      if actionInfo and actionInfo.cat == "vehicle_specific" and not binding.unused and not core_input_actionFilter.isActionBlocked(binding.action) then
        -- Get the title from the action definition
        if (not actionInfo.actionMap or isActionMapActive(actionInfo.actionMap)) then
          if not actionsByName[binding.action] then
            local action = deepcopy(actionInfo)
            action.label = actionInfo.title
            action.order = actionInfo.order or 999  -- fallback to 999 if no order defined
            action.action = binding.action
            action.inputActionOnClick = true
            action.direction = parseActionDirection(action)

            actionsByName[action.action] = action
          end
        end
      end
    end
  end

  for _, action in pairs(actionsByName) do
    table.insert(result, action)
  end
  return result
end

local function isActionAvailable(actionName)
  local activeActions = core_input_actions.getActiveActions()
  local actionInfo = activeActions[actionName]
  if not actionInfo then return false end
  if core_input_actionFilter.isActionBlocked(actionName) then return false end
  if actionInfo.actionMap and not isActionMapActive(actionInfo.actionMap) then return false end
  return true
end

local function appendBasicDrivingAction(actions, seenActions, actionName, order, showIfController)
  if seenActions[actionName] or not isActionAvailable(actionName) then return end
  seenActions[actionName] = true
  local actionData = {
    action = actionName,
    order = order,
    inputActionOnClick = true
  }
  if showIfController ~= nil then
    actionData.showIfController = showIfController
  end
  table.insert(actions, actionData)
end

local function getCurrentGearboxMode()
  local playerVehicle = be:getPlayerVehicle(0)
  if playerVehicle then
    local cachedMode = core_vehicleBridge.getCachedVehicleData(playerVehicle:getID(), "gearboxMode")
    if cachedMode ~= nil then
      return cachedMode
    end
  end
  return settings.getValue("defaultGearboxBehavior", "arcade")
end

local function ensureCurrentVehicleGearboxModeRegistered()
  local playerVehicle = be:getPlayerVehicle(0)
  if not playerVehicle then return end
  local vehicleId = playerVehicle:getID()
  if registeredGearboxModeVehicles[vehicleId] then return end
  core_vehicleBridge.registerValueChangeNotification(playerVehicle, "gearboxMode")
  registeredGearboxModeVehicles[vehicleId] = true
end

local function unregisterAllGearboxModeRegistrations()
  for vehicleId in pairs(registeredGearboxModeVehicles) do
    local vehicle = getObjectByID(vehicleId)
    if vehicle then
      core_vehicleBridge.unregisterValueChangeNotification(vehicle, "gearboxMode")
    end
    registeredGearboxModeVehicles[vehicleId] = nil
  end
end

local function getBasicDrivingActions()
  local actions = {}
  local seenActions = {}

  appendBasicDrivingAction(actions, seenActions, "accelerate", 1)
  appendBasicDrivingAction(actions, seenActions, "brake", 2)

  appendBasicDrivingAction(actions, seenActions, "steering", 3, true)
  appendBasicDrivingAction(actions, seenActions, "steer_left", 4, false)
  appendBasicDrivingAction(actions, seenActions, "steer_right", 5, false)

  local selectedMode = getCurrentGearboxMode()
  local autoClutchEnabled = settings.getValue("autoClutch", false) == true
  if selectedMode == "realistic" then
    appendBasicDrivingAction(actions, seenActions, "shiftUp", 6)
    appendBasicDrivingAction(actions, seenActions, "shiftDown", 7)
    if not autoClutchEnabled then
      appendBasicDrivingAction(actions, seenActions, "clutch", 8)
    end
  end

  return actions
end

local function actionListSignature(actions)
  local actionNames = {}
  for i, action in ipairs(actions) do
    actionNames[i] = action.action
  end
  return table.concat(actionNames, "|")
end

local function refreshBasicDrivingActions(force)
  if not showBasicDrivingControls then return end
  local actions = getBasicDrivingActions()
  local signature = actionListSignature(actions)
  if not force and signature == basicDrivingSignature then return end
  basicDrivingSignature = signature
  addActions("basicDriving", actions, {priority = 11, hideConstant = true})
end

local function getActionDataSetByLabel(label)
  for i, actionDataSet in ipairs(actionData) do
    if actionDataSet.label == label then
      return actionDataSet
    end
  end
end

local function sortActions(actions)
  -- Sort actions by category first, then by order
  table.sort(actions, function(a, b)
    if a.cat ~= b.cat then
      return (a.cat or "") > (b.cat or "")
    end
    if a.order ~= b.order then
      return (a.order or 999) < (b.order or 999)
    end
    return a.action < b.action
  end)
end

local function getModifiersFromControl(control)
  local normalizedControl = string.gsub(control, "%-", " ")
  local controlParts = string.split(normalizedControl)
  local bindingModifiers = {}

  -- Get all parts except the last (which is the actual control)
  for i = 1, #controlParts - 1 do
    table.insert(bindingModifiers, controlParts[i])
  end
  return bindingModifiers
end

local function isActionFilteredOut(actionInfo, actionName)
  if not modifierCategories[actionInfo.cat] and not actionsToAlwaysShow[actionName] then return true end
  return core_input_actionFilter.isActionBlocked(actionName)
end

local function getBoundModifierActions()
  if boundModifierActions then
    -- get the modifier data from the cache and only update the active state
    for actionName, action in pairs(boundModifierActions) do
      if actionName == "modifier1modifier2" then
        -- do nothing
      elseif actionName == "shift" then
        action.active = modifiersActive["shift"]
      elseif actionName == "ctrl" then
        action.active = modifiersActive["ctrl"]
      elseif actionName == "alt" then
        action.active = modifiersActive["alt"]
      else
        local modifierNumber = actionName:match("customModifier(%d+)")
        if modifierNumber then
          action.active = modifiersActive["modifier" .. modifierNumber]
        end
      end
    end
    return boundModifierActions
  end

  -- search which modifiers are used by any action
  local result = {}
  local activeActions = core_input_actions.getActiveActions()
  for i = 1, 6 do
    local foundActionUsingModifier = false
    local foundModifierAction = false
    for _, device in ipairs(core_input_bindings.bindings) do
      for _, binding in ipairs(device.contents.bindings) do

        local actionInfo = activeActions[binding.action]
        if not foundActionUsingModifier and not binding.unused and not isActionFilteredOut(actionInfo, binding.action) then
          local modifiers = getModifiersFromControl(binding.control)
          if #modifiers == 1 and modifiers[1] == "modifier" .. i then
            foundActionUsingModifier = true
          end
        end

        if binding.action == "customModifier" .. i then
          foundModifierAction = true
        end

        if foundActionUsingModifier and foundModifierAction then
          result["customModifier" .. i] = {
            active = modifiersActive["modifier" .. i]
          }
          goto continueBoundModifierActions
        end
      end
    end
    -- modifier action was not found
    result["customModifier" .. i] = {
      active = modifiersActive["modifier" .. i],
      disabled = true
    }
    ::continueBoundModifierActions::
  end

  -- search for combined modifier actions
  for _, device in ipairs(core_input_bindings.bindings) do
    for _, binding in ipairs(device.contents.bindings) do

      local actionInfo = activeActions[binding.action]
      if not binding.unused and not isActionFilteredOut(actionInfo, binding.action) then
        local modifiers = getModifiersFromControl(binding.control)
        if #modifiers == 2 and modifiers[1] == "modifier1" and modifiers[2] == "modifier2" then
          result["modifier1modifier2"] = {}
          goto continueCombindedModifierActions
        end
      end
    end
  end
  -- combined modifier action was not found
  result["modifier1modifier2"] = {
    disabled = true
  }
  ::continueCombindedModifierActions::

  result["shift"] = { active = modifiersActive["shift"] }
  result["ctrl"] = { active = modifiersActive["ctrl"] }
  result["alt"] = { active = modifiersActive["alt"] }
  boundModifierActions = result
  return result
end

local function setActionDefaults(actions)
  local activeActions = core_input_actions.getActiveActions()
  for _, action in ipairs(actions) do
    if action.inputActionOnClick == nil then
      action.inputActionOnClick = true
    end
    if action.label == nil then
      action.label = activeActions[action.action].title
    end
  end
end

local function setAdditionalDataDefaults(additionalData)
  if additionalData.resetFade == nil then
    additionalData.resetFade = true
  end
end

local uiActionsEmptyBefore = true
local function sendDataToUI(forceResetFade)
  local uiData = {actions = {}, constantActions = {}, additionalData = {}, modifierActionInfos = {}, showApp = settings.getValue("bindingsLegendShowApp", true)}

  local highestPriority = 0
  local highestPriorityIndex
  for i, actionDataSet in ipairs(actionData) do
    if actionDataSet.additionalData and actionDataSet.additionalData.priority and actionDataSet.additionalData.priority > highestPriority then
      highestPriority = actionDataSet.additionalData.priority
      highestPriorityIndex = i
    end
  end

  -- construct uiData table
  for i, actionDataSet in ipairs(actionData) do
    if actionDataSet.additionalData then
      tableMerge(uiData.additionalData, actionDataSet.additionalData)
    end
    if not (highestPriorityIndex and actionDataSet.additionalData.priority ~= highestPriority) then
      sortActions(actionDataSet.actions)
      arrayConcat(uiData.actions, actionDataSet.actions)
    end
  end

  if actionCategoryActive["vehicleSpecific"] then
    -- highlight vehicle specific actions that are used with this modifier combination
    local vehicleSpecificDataSet = getActionDataSetByLabel("vehicleSpecific")
    local modifiedDataSet = getActionDataSetByLabel("modified")
    for _, action in ipairs(vehicleSpecificDataSet.actions) do
      action.highlighted = nil
      for _, modifiedAction in ipairs(modifiedDataSet and modifiedDataSet.actions or {}) do
        if action.action == modifiedAction.action then
          action.highlighted = true
          break
        end
      end
    end

    if vehicleSpecificDataSet.additionalData.removeIfOverwrittenWithHigherPriority then
      uiData.additionalData.vehicleSpecificStatus = "fleeting"
    else
      uiData.additionalData.vehicleSpecificStatus = "enabled"
    end
  else
    uiData.additionalData.vehicleSpecificStatus = "disabled"

    for i = #uiData.actions, 1, -1 do
      local action = uiData.actions[i]
      if action.hidden then
        table.remove(uiData.actions, i)
      end
    end
  end

  if tableIsEmpty(getVehicleSpecificActions()) then
    uiData.additionalData.vehicleSpecificStatus = "inactive"
  end

  uiData.modifierActionInfos = getBoundModifierActions()

  for i = #uiData.actions, 1, -1 do
    local action = uiData.actions[i]
    if core_input_actionFilter.isActionBlocked(action.action) then
      table.remove(uiData.actions, i)
    end
  end

  setAdditionalDataDefaults(uiData.additionalData)

  if not actionCategoryActive["vehicleSpecific"] and uiData.additionalData.hideConstant then
    uiData.constantActions = {}
    uiData.modifierActionInfos = {}
  end

  setActionDefaults(uiData.constantActions)

  if #uiData.actions + #uiData.constantActions > actionLimit then
    -- Cut the list to actionLimit size
    local trimmedActions = {}
    for i = #uiData.actions - actionLimit, #uiData.actions do
      table.insert(trimmedActions, uiData.actions[i])
    end
    uiData.actions = trimmedActions
  end

  guihooks.trigger("setActionsForLegend", uiData)
  if settings.getValue("bindingsLegendShowApp", true) and (uiData.additionalData.resetFade and (#uiData.actions > 0 or not uiActionsEmptyBefore) or forceResetFade) then
    -- New data pushed to UI: unfade and restart inactivity delay
    resetFade()
  end
  uiActionsEmptyBefore = tableIsEmpty(uiData.actions)
end

local function removeActionCategoryByLabel(label)
  for i, actionDataSet in ipairs(actionData) do
    if actionDataSet.label == label then
      table.remove(actionData, i)
    end
  end
  actionCategoryActive[label] = nil
end

-- Removes action sets with "removeIfOverwrittenWithHigherPriority" when their priority is lower than the provided newPriority.
local function removeLowerPriorityOptInActionSets(newPriority)
  if not newPriority then return end
  for i = #actionData, 1, -1 do
    local actionSet = actionData[i]
    if actionSet and actionSet.additionalData and actionSet.additionalData.removeIfOverwrittenWithHigherPriority then
      local actionSetPriority = actionSet.additionalData.priority or 0
      if actionSetPriority < newPriority then
        actionCategoryActive[actionSet.label] = nil
        table.remove(actionData, i)
      end
    end
  end
end

local function doesActionSetWithHigherPriorityExist(priority)
  for _, actionSet in ipairs(actionData) do
    if actionSet.additionalData and actionSet.additionalData.priority and actionSet.additionalData.priority > priority then
      return true
    end
  end
end

function addActions(label, actions, additionalData)
  removeActionCategoryByLabel(label)

  -- if removeIfOverwrittenWithHigherPriority is true, and an action set with higher priority exists, don't add the new action set
  if additionalData and additionalData.removeIfOverwrittenWithHigherPriority and doesActionSetWithHigherPriorityExist(additionalData.priority) then
    return
  end

  if not tableIsEmpty(actions) then
    setActionDefaults(actions)
    setAdditionalDataDefaults(additionalData)
    removeLowerPriorityOptInActionSets(additionalData and additionalData.priority)

    table.insert(actionData, {actions = actions, additionalData = additionalData, label = label})
    actionCategoryActive[label] = true
  end
  sendDataToUI()
end

local function addConstantActions(actions)
  for _, action in ipairs(actions) do
    table.insert(actionData, {actions = {action}, additionalData = {priority = 10}, label = "constant"})
  end
end

local function getBindingsByDeviceName(deviceName)
  for _, device in ipairs(core_input_bindings.bindings) do
    if device.devname == deviceName then
      return device.contents.bindings
    end
  end
end

local function isModifierCombinationFilteredOut(modifierNames)
  return #modifierNames == 1 and modifierNames[1] == "shift"
end

local function onModifierChanged(newModifiers)
  local modifierNames = {}
  if bit.band(newModifiers, MODIFIER_L_SHIFT) == MODIFIER_L_SHIFT or bit.band(newModifiers, MODIFIER_R_SHIFT) == MODIFIER_R_SHIFT then table.insert(modifierNames, "shift") end
  if bit.band(newModifiers, MODIFIER_L_CTRL) == MODIFIER_L_CTRL or bit.band(newModifiers, MODIFIER_R_CTRL) == MODIFIER_R_CTRL then table.insert(modifierNames, "ctrl") end
  if bit.band(newModifiers, MODIFIER_L_ALT) == MODIFIER_L_ALT or bit.band(newModifiers, MODIFIER_R_ALT) == MODIFIER_R_ALT then table.insert(modifierNames, "alt") end
  if bit.band(newModifiers, MODIFIER1) == MODIFIER1 then table.insert(modifierNames, "modifier1") end
  if bit.band(newModifiers, MODIFIER2) == MODIFIER2 then table.insert(modifierNames, "modifier2") end
  if bit.band(newModifiers, MODIFIER3) == MODIFIER3 then table.insert(modifierNames, "modifier3") end
  if bit.band(newModifiers, MODIFIER4) == MODIFIER4 then table.insert(modifierNames, "modifier4") end
  if bit.band(newModifiers, MODIFIER5) == MODIFIER5 then table.insert(modifierNames, "modifier5") end
  if bit.band(newModifiers, MODIFIER6) == MODIFIER6 then table.insert(modifierNames, "modifier6") end

  local actions = {}
  local bindingsByAction = {}

  if not tableIsEmpty(modifierNames) then
    local activeActions = core_input_actions.getActiveActions()
    for _, deviceName in ipairs(core_input_bindings.getRecentDevices()) do
      local bindingsByDevice = getBindingsByDeviceName(deviceName)
      for _, binding in ipairs(bindingsByDevice or {}) do
        local actionInfo = activeActions[binding.action]

        if actionInfo and actionInfo.title and not binding.unused and not isActionFilteredOut(actionInfo, binding.action) then
          -- Check if binding.control contains exactly these modifiers
          local bindingModifiers = getModifiersFromControl(binding.control)

          -- Check if modifiers match exactly
          local modifiersMatch = #bindingModifiers == #modifierNames
          if modifiersMatch then
            for _, modifier in ipairs(modifierNames) do
              if not tableContains(bindingModifiers, modifier) then
                modifiersMatch = false
                break
              end
            end
          end

          if modifiersMatch and #modifierNames > 0 then
            -- Get the title from the action definition
            if (not actionInfo.actionMap or isActionMapActive(actionInfo.actionMap)) then
              if not bindingsByAction[binding.action] then
                local action = deepcopy(actionInfo)
                action.action = binding.action
                action.label = actionInfo.title
                action.order = actionInfo.order or 999  -- fallback to 999 if no order defined
                action.hidden = isModifierCombinationFilteredOut(modifierNames)
                action.direction = parseActionDirection(action)
                bindingsByAction[binding.action] = {{device = deviceName, control = binding.control:match("([^ ]+)$")}} -- remove the modifiers from the controls in this case
                action.bindings = bindingsByAction[binding.action]
                table.insert(actions, action)
              end
            end
          end
        end
      end
    end
  end

  local previousModifierCount = tableSize(modifiersActive)
  table.clear(modifiersActive)
  for _, modifier in ipairs(modifierNames) do
    modifiersActive[modifier] = true
  end
  local newModifierCount = tableSize(modifiersActive)
  if hideVehicleSpecificActionsOnModifierPressed and newModifierCount > previousModifierCount then
    hideVehicleSpecificActionsOnModifierPressed = nil
    removeActionCategoryByLabel("vehicleSpecific")
  end

  local additionalData = {
    modifiersActive = modifiersActive,
    priority = 9
  }

  addActions("modified", actions, additionalData)
end

local function onUpdate(dtReal, dtSim, dtRaw)
  fadeUpdate(dtReal)

  if not getPlayerVehicle(0) then return end

  if showBasicDrivingControls then
    ensureCurrentVehicleGearboxModeRegistered()
    local currentGearboxMode = getCurrentGearboxMode()
    if currentGearboxMode ~= basicDrivingLastGearboxMode then
      basicDrivingLastGearboxMode = currentGearboxMode
      refreshBasicDrivingActions(true)
    end
    refreshBasicDrivingActions(false)
  end

  for _, actionDataSet in ipairs(actionData) do
    if actionDataSet.additionalData then
      if actionDataSet.additionalData.ttl then
        actionDataSet.additionalData.ttl = actionDataSet.additionalData.ttl - dtReal
        if actionDataSet.additionalData.ttl <= 0 then
          removeActionCategoryByLabel(actionDataSet.label)
          sendDataToUI()
        end
      end
    end
  end

  drawDebugWindow()
end

local registeredVehicles = {}

local function setShowBasicDrivingControls(enable)
  local shouldEnable = enable == true
  if showBasicDrivingControls == shouldEnable then
    if shouldEnable then
      refreshBasicDrivingActions(true)
    end
    return
  end

  showBasicDrivingControls = shouldEnable
  basicDrivingSignature = nil
  basicDrivingLastGearboxMode = nil

  if showBasicDrivingControls then
    ensureCurrentVehicleGearboxModeRegistered()
    basicDrivingLastGearboxMode = getCurrentGearboxMode()
    refreshBasicDrivingActions(true)
  else
    unregisterAllGearboxModeRegistrations()
    removeActionCategoryByLabel("basicDriving")
    sendDataToUI(true)
  end
end

local function enableShowVehicleSpecificActions(enable)
  if not settings.getValue("bindingsLegendShowApp", true) or (not enable) == (not actionCategoryActive["vehicleSpecific"]) then
    return
  end

  local vehicleSpecificActions
  if enable then
    vehicleSpecificActions = getVehicleSpecificActions()
    if tableIsEmpty(vehicleSpecificActions) then
      return
    end
    hideVehicleSpecificActionsOnModifierPressed = nil
    addActions("vehicleSpecific", vehicleSpecificActions, {priority = 10})
  else
    removeActionCategoryByLabel("vehicleSpecific")
  end
  sendDataToUI()
end

local function toggleShowVehicleSpecificActions()
  enableShowVehicleSpecificActions(not actionCategoryActive["vehicleSpecific"])
end

local function onClientStartMission()
end

local function onClientEndMission()
  table.clear(actionData)
  table.clear(actionCategoryActive)
  basicDrivingSignature = nil
  basicDrivingLastGearboxMode = nil
  unregisterAllGearboxModeRegistrations()
end

local function onActionFilterUpdated()
  boundModifierActions = nil
  basicDrivingSignature = nil
  sendDataToUI()
end

local function onInputBindingsChanged()
  boundModifierActions = nil
  basicDrivingSignature = nil
  sendDataToUI()
end

local function onSettingsChanged()
  basicDrivingSignature = nil
  basicDrivingLastGearboxMode = nil
  if showBasicDrivingControls then
    ensureCurrentVehicleGearboxModeRegistered()
    refreshBasicDrivingActions(true)
    return
  end
  sendDataToUI(true)
end

local function showToggleVehicleSpecificActionsMessage()
  if settings.getValue("bindingsLegendShowApp", true) then
    guihooks.trigger("Message", {
      ttl = 10,
      category = "vehicleSpecificController",
      icon = "car",
      actionItems = fillActionLabelSimple{"toggleShowVehicleSpecificActions"},
      showIfController = true,
    })
    guihooks.trigger("Message", {
      msg = "ui.inputActions.menu.toggleShowBindingsLegendApp.message.keyboard",
      ttl = 10,
      category = "vehicleSpecificKeyboard",
      icon = "car",
      showIfController = false,
    })
  end
end

local function onVehicleSwitched(oldId, newId, player)
  if oldId ~= newId then
    boundModifierActions = nil
    enableShowVehicleSpecificActions(false)
    local vehicleSpecificActions = getVehicleSpecificActions()
    if not tableIsEmpty(vehicleSpecificActions) then
      if tableIsEmpty(modifiersActive) then
        -- go into a "fleeting" vehicle specific actions state that will be removed after 7 seconds and also overwritten by a higher priority action set
        addActions("vehicleSpecific", vehicleSpecificActions, {priority = 8, removeIfOverwrittenWithHigherPriority = true, ttl = 10})
      else
        -- in this case, the player probably entered/exited a vehicle with a modifier action, so we keep the vehicle specific actions through the modifier being released
        hideVehicleSpecificActionsOnModifierPressed = true
        addActions("vehicleSpecific", vehicleSpecificActions, {priority = 10, ttl = 10})
      end
      showToggleVehicleSpecificActionsMessage()
    end
    sendDataToUI()
  end
end

local function onExtensionLoaded()
  local bindingAppActions = jsonReadFile(actionJsonFilePath)
  if bindingAppActions then
    jsonActions = bindingAppActions
  end
end

local function triggerInputAction(action, value)
  local activeActions = core_input_actions.getActiveActions()
  core_input_actions.executeCommand(activeActions[action], value, be:getPlayerVehicleID(0))
end

local function onDeviceChanged()
  boundModifierActions = nil
  basicDrivingSignature = nil
  sendDataToUI()
end

local function onDeserialized(data)
  core_jobsystem.create(function(job)
    boundModifierActions = nil
  end)
end

local function toggleShowApp()
  enableShowVehicleSpecificActions(false)
  resetFade()
  settings.setValue("bindingsLegendShowApp", not settings.getValue("bindingsLegendShowApp", true))
  sendDataToUI()
end

M.addActions = addActions
M.sendDataToUI = sendDataToUI
M.toggleShowVehicleSpecificActions = toggleShowVehicleSpecificActions
M.enableShowVehicleSpecificActions = enableShowVehicleSpecificActions
M.showToggleVehicleSpecificActionsMessage = showToggleVehicleSpecificActionsMessage
M.setDebug = setDebug
M.setShowBasicDrivingControls = setShowBasicDrivingControls
M.triggerInputAction = triggerInputAction
M.resetFade = resetFade
M.toggleShowApp = toggleShowApp

M.onModifierChanged = onModifierChanged
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onVehicleSwitched = onVehicleSwitched
M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onDeviceChanged = onDeviceChanged
M.onActionFilterUpdated = onActionFilterUpdated
M.onSettingsChanged = onSettingsChanged
M.onDeserialized = onDeserialized

return M
