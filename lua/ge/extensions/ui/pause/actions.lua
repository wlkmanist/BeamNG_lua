-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local buttonModule = require("ge/extensions/ui/gridSelectorUtils/buttonModule")
local buttonInstance = buttonModule.create()

local function registerButton(metadata, callback)
  if metadata.visible == false then
    return metadata
  end
  local cloned = deepcopy(metadata)
  local registered = buttonInstance.addButton(callback, cloned)
  cloned.buttonId = registered.buttonId
  return cloned
end

function M.clearActions()
  buttonInstance.clearButtonFunctions()
end

function M.executeAction(buttonId, payload)
  return buttonInstance.executeButton(buttonId, payload)
end

function M.registerButton(metadata, callback)
  return registerButton(metadata or {}, callback or function() return false end)
end

function M.getAllButtonInfos()
  return buttonInstance.getAllButtonInfos()
end

M.onExtensionLoaded = function()
  setExtensionUnloadMode(M, "manual")
end

local MODS_TAB_ID = "mods"

local modTabsById = {}
local modTabOrder = {}
local modButtonsById = {}

local function notifyModActionsChanged()
  guihooks.trigger("PauseModActionsChanged", M.getVisibleModTabs())
end

local function removeOrderedId(list, id)
  for i, value in ipairs(list) do
    if value == id then
      table.remove(list, i)
      return
    end
  end
end

local function removeModTab(id)
  local tab = modTabsById[id]
  if not tab then return false end

  for _, buttonId in ipairs(tab.buttonOrder) do
    modButtonsById[buttonId] = nil
  end
  modTabsById[id] = nil
  removeOrderedId(modTabOrder, id)
  return true
end

local function cloneModButton(button)
  return {
    id = button.id,
    tabId = button.tabId,
    label = button.label,
    icon = button.icon,
    componentName = button.componentName,
    props = button.props,
    card2ComponentName = button.card2ComponentName,
    card2Props = button.card2Props,
  }
end

function M.registerModTab(tab)
  if not tab or not tab.id then
    return {success = false, reason = "missing_id"}
  end

  local existing = modTabsById[tab.id]
  modTabsById[tab.id] = {
    id = tab.id,
    label = tab.label or tab.id,
    icon = tab.icon,
    card2ComponentName = tab.card2ComponentName,
    card2Props = tab.card2Props,
    buttonOrder = existing and existing.buttonOrder or {},
  }
  if not existing then
    table.insert(modTabOrder, tab.id)
  end

  notifyModActionsChanged()
  return {success = true}
end

function M.unregisterModTab(id)
  if not removeModTab(id) then
    return {success = false, reason = "not_found"}
  end

  notifyModActionsChanged()
  return {success = true}
end

function M.registerModButton(button)
  if not button or not button.id or not button.tabId then
    return {success = false, reason = "missing_id_or_tab"}
  end

  if not modTabsById[button.tabId] then
    if button.tabId == MODS_TAB_ID then
      modTabsById[MODS_TAB_ID] = {
        id = MODS_TAB_ID,
        label = _tr("ui.dashboard.mods"),
        icon = "wrench",
        buttonOrder = {},
      }
      table.insert(modTabOrder, MODS_TAB_ID)
    else
      return {success = false, reason = "unknown_tab"}
    end
  end

  local existing = modButtonsById[button.id]
  if existing and existing.tabId ~= button.tabId then
    local oldTab = modTabsById[existing.tabId]
    if oldTab then
      removeOrderedId(oldTab.buttonOrder, button.id)
      if existing.tabId == MODS_TAB_ID and #oldTab.buttonOrder == 0 then
        removeModTab(MODS_TAB_ID)
      end
    end
  end

  local tab = modTabsById[button.tabId]
  if not existing or existing.tabId ~= button.tabId then
    table.insert(tab.buttonOrder, button.id)
  end
  modButtonsById[button.id] = cloneModButton(button)

  notifyModActionsChanged()
  return {success = true}
end

function M.unregisterModButton(id)
  local button = modButtonsById[id]
  if not button then
    return {success = false, reason = "not_found"}
  end

  local tab = modTabsById[button.tabId]
  modButtonsById[id] = nil

  if tab then
    removeOrderedId(tab.buttonOrder, id)
    if button.tabId == MODS_TAB_ID and #tab.buttonOrder == 0 then
      removeModTab(MODS_TAB_ID)
    end
  end

  notifyModActionsChanged()
  return {success = true}
end

--- shaped for buildPauseTabs
function M.getVisibleModTabs()
  local result = {}
  for _, tabId in ipairs(modTabOrder) do
    local tab = modTabsById[tabId]
    local buttons = {}
    for _, buttonId in ipairs(tab.buttonOrder) do
      local button = modButtonsById[buttonId]
      if button then
        table.insert(buttons, cloneModButton(button))
      end
    end
    if #buttons > 0 then
      table.insert(result, {
        tabId = "mod:" .. tab.id,
        isModTab = true,
        label = tab.label,
        icon = tab.icon,
        card2ComponentName = tab.card2ComponentName,
        card2Props = tab.card2Props,
        buttons = buttons,
        visible = true,
        enabled = true,
      })
    end
  end
  return result
end

return M
