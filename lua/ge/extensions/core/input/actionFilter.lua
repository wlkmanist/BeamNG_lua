-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local actionGroups = {}
local blockedActionGroups = {}
local blockedActions = {}
local actionMapPlayerMasks = {}

local actionTemplates = {}

local function createActionTemplate(templateNames, actionWhitelist, actionBlackList)
  local template = {}
  for _, entry in ipairs(templateNames) do
    if actionTemplates[entry] then
      if not actionWhitelist then
        arrayConcat(template, actionTemplates[entry])
      else
        for _, actionName in ipairs(actionTemplates[entry]) do
          if not tableContains(actionWhitelist, actionName) then
            table.insert(template, actionName)
          end
        end
      end
    end
  end
  if actionBlackList then
    arrayConcat(template, actionBlackList)
  end
  return template
end

actionTemplates.vehicleTeleporting = {"dropPlayerAtCamera", "dropPlayerAtCameraNoReset", "recover_vehicle", "recover_vehicle_alt", "recover_to_last_road", "reload_vehicle", "reload_all_vehicles", "loadHome", "saveHome", "reset_all_physics" } -- no "reset_physics" as this is often used as a normal reset in scenarios
actionTemplates.vehicleMenues = {"vehicle_selector", "parts_selector", "vehicledebugMenu"}
actionTemplates.nodegrabber = {"nodegrabberAction", "nodegrabberGrab", "nodegrabberRender", "nodegrabberStrength", "nodegrabberPadMode"}
actionTemplates.physicsControls = {"slower_motion", "faster_motion", "toggle_slow_motion"}
arrayConcat(actionTemplates.physicsControls, actionTemplates.nodegrabber)
actionTemplates.aiControls = {"toggleTraffic", "toggleAITraffic"}
actionTemplates.vehicleSwitching = {"switch_next_vehicle", "switch_previous_vehicle"}
actionTemplates.editor = {"editorToggle", "objectEditorToggle", "editorSafeModeToggle"}
actionTemplates.freeCam = {"toggleCamera", "dropCameraAtPlayer"}
--if shipping_build then
--  arrayConcat(actionTemplates.freeCam, actionTemplates.editor)
--end
actionTemplates.gameCam = {"camera_1","camera_10","camera_2","camera_3","camera_4","camera_5","camera_6","camera_7","camera_8","camera_9", "center_camera", "look_back", "rotate_camera_down","rotate_camera_horizontal", "rotate_camera_hz_mouse", "rotate_camera_left", "rotate_camera_right", "rotate_camera_up", "rotate_camera_vertical", "rotate_camera_vt_mouse", "switch_camera_next", "switch_camera_prev", "changeCameraSpeed", "movedown", "movefast", "moveup", "rollAbs", "xAxisAbs", "yAxisAbs", "yawAbs", "zAxisAbs", "pitchAbs"}
actionTemplates.funStuff = {"forceField", "funBoom", "funBreak", "funExtinguish", "funFire", "funHinges", "funTires", "funRandomTire", "latchesOpen", "latchesClose", "funBoost", "funBoostBackwards", "funFling", "funFlingDownward"}
actionTemplates.walkingMode = {"toggleWalkingMode"}
actionTemplates.photoMode = {"photomode"}
actionTemplates.trackBuilder = {"toggleTrackBuilder"}
actionTemplates.bigMap = {"toggleBigMap"}
actionTemplates.couplers = {"couplersLock", "couplersToggle", "couplersUnlock"}
actionTemplates.vehicleTriggers = {"triggerAction0", "triggerAction1", "triggerAction2"}
actionTemplates.radialMenu = {"menu_item_focus_lr", "menu_item_focus_ud"}
actionTemplates.pause = {"pause"}
actionTemplates.missionPopup = {"accept", "decline"}
actionTemplates.resetPhysics = {"reset_physics"}
actionTemplates.vehicleRecovery = {"recover_vehicle", "recover_vehicle_alt", "recover_to_last_road"}
actionTemplates.vehicleTeleportOnly = {"dropPlayerAtCamera", "dropPlayerAtCameraNoReset", "loadHome", "saveHome"}
actionTemplates.appedit = {"appedit"}
actionTemplates.miniMap = {"toggle_minimap"}
actionTemplates.radialMenuActivate = {"toggleRadialMenuSandbox", "toggleRadialMenuPlayerVehicle", "toggleRadialMenuFavorites", "toggleRadialMenuMulti"}
actionTemplates.setShifterMode = {"toggleShifterMode", "gearR", "gear1", "gear2", "gear3", "gear4", "gear5", "gear6", "gear7", "gear8", "gearN"}
actionTemplates.uiReloading = {"cefdev_reload_ui"}

actionTemplates.competitive = createActionTemplate({"vehicleTeleporting", "vehicleMenues", "physicsControls", "aiControls", "vehicleSwitching", "freeCam", "funStuff", "editor"})


local function addToFilter(filter, actionName, filtered)
  if type(actionGroups[actionName]) == 'table' then
    for i, a in ipairs(actionGroups[actionName]) do
      ActionMap.addToFilter(filter, a, filtered )
      blockedActions[filter][a] = filtered
    end
  else
    ActionMap.addToFilter(filter, actionName, filtered)
    blockedActions[filter][actionName] = filtered
  end
end

local function clearCFilter(filter)
  ActionMap.clearFilters(filter)
  blockedActions[filter] = {}
end

local function updateFilters(filter)
  clearCFilter(filter)
  for actionGroupName, filtered in pairs(blockedActionGroups[filter]) do
    if filtered then
      addToFilter(filter, actionGroupName, filtered)
    end
  end
  extensions.hook("onActionFilterUpdated")
end

local function addAction(filter, actionName, filtered)
  blockedActionGroups[filter] = blockedActionGroups[filter] or {}
  blockedActionGroups[filter][actionName] = filtered
  updateFilters(filter)
end

local function clear(filter)
  clearCFilter(filter)
  blockedActionGroups[filter] = {}
end

local function setGroup(name, arrayValues)
  actionGroups[name] = arrayValues
end

local function getGroup(name)
  return actionGroups[name]
end

local function isActionBlocked(actionName)
  for filter, actions in pairs(blockedActions) do
    if actions[actionName] then
      return true
    end
  end
end

local function normalizeActionMapName(mapName)
  if type(mapName) ~= "string" then return nil end
  return mapName:sub(-9) == "ActionMap" and mapName or (mapName .. "ActionMap")
end

local function applyActionMapPlayerMask(mapName)
  local effectiveMask = -1
  for _, playerMask in pairs(actionMapPlayerMasks[mapName] or {}) do
    effectiveMask = bit.band(effectiveMask, playerMask)
  end
  local actionMap = scenetree.findObject(mapName)
  if actionMap then actionMap.playerMask = effectiveMask end
end

local function setActionMapPlayerMask(owner, mapName, playerMask)
  mapName = normalizeActionMapName(mapName)
  if type(owner) ~= "string" or not mapName or type(playerMask) ~= "number" then return false end
  actionMapPlayerMasks[mapName] = actionMapPlayerMasks[mapName] or {}
  actionMapPlayerMasks[mapName][owner] = playerMask
  applyActionMapPlayerMask(mapName)
  return true
end

local function clearActionMapPlayerMask(owner, mapName)
  mapName = normalizeActionMapName(mapName)
  local ownerMasks = mapName and actionMapPlayerMasks[mapName]
  if not ownerMasks then return end
  ownerMasks[owner] = nil
  if not next(ownerMasks) then actionMapPlayerMasks[mapName] = nil end
  applyActionMapPlayerMask(mapName)
end

local function clearActionMapPlayerMasks(owner)
  local mapNames = {}
  for mapName in pairs(actionMapPlayerMasks) do
    mapNames[#mapNames + 1] = mapName
  end
  for _, mapName in ipairs(mapNames) do
    local ownerMasks = actionMapPlayerMasks[mapName]
    ownerMasks[owner] = nil
    if not next(ownerMasks) then actionMapPlayerMasks[mapName] = nil end
    applyActionMapPlayerMask(mapName)
  end
end

local function setActionMapPlayerBlocked(owner, mapName, player, blocked)
  mapName = normalizeActionMapName(mapName)
  if not mapName or type(player) ~= "number" then return false end
  local ownerMasks = actionMapPlayerMasks[mapName]
  local playerMask = ownerMasks and ownerMasks[owner] or -1
  local playerBit = bit.lshift(1, player)
  if blocked then
    playerMask = bit.band(playerMask, bit.bnot(playerBit))
  else
    playerMask = bit.bor(playerMask, playerBit)
  end
  return setActionMapPlayerMask(owner, mapName, playerMask)
end

local function onSerialize()
  local data = {}
  data.actionGroups = actionGroups
  data.blockedActionGroups = blockedActionGroups
  data.actionMapPlayerMasks = actionMapPlayerMasks
  return data
end

local function onDeserialized(v)
  actionGroups = v.actionGroups
  blockedActionGroups = v.blockedActionGroups
  actionMapPlayerMasks = v.actionMapPlayerMasks or {}
  for mapName in pairs(actionMapPlayerMasks) do
    applyActionMapPlayerMask(mapName)
  end
end

local function onInputBindingsChanged()
  for mapName in pairs(actionMapPlayerMasks) do
    applyActionMapPlayerMask(mapName)
  end
end

local function onExtensionUnloaded()
  for mapName in pairs(actionMapPlayerMasks) do
    local actionMap = scenetree.findObject(mapName)
    if actionMap then actionMap.playerMask = -1 end
  end
end

local function getActionTemplates()
  return actionTemplates
end

local function getBlockedActions()
  return blockedActions
end

M.addAction = addAction
M.clear = clear
M.setGroup = setGroup
M.getGroup = getGroup
M.isActionBlocked = isActionBlocked
M.setActionMapPlayerMask = setActionMapPlayerMask
M.clearActionMapPlayerMask = clearActionMapPlayerMask
M.clearActionMapPlayerMasks = clearActionMapPlayerMasks
M.setActionMapPlayerBlocked = setActionMapPlayerBlocked
M.createActionTemplate = createActionTemplate
M.getActionTemplates = getActionTemplates

M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onInputBindingsChanged = onInputBindingsChanged
M.onExtensionUnloaded = onExtensionUnloaded

-- debug
M.getBlockedActions = getBlockedActions

return M
