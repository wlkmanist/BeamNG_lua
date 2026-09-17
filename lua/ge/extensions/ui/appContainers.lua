-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "appContainers"
local debugEnabled = false
local im = ui_imgui

local containersById = {}

local legacyContainerIdMap = {
  utilityApps = "topLeft",
  gameplayApps = "topCenter",
  secondaryApps = "topRight",
}

local function resolveContainerId(containerId)
  return legacyContainerIdMap[containerId] or containerId
end

local function cloneApps(apps)
  local result = {}
  for appId, app in pairs(apps or {}) do
    result[appId] = { visible = app.visible and true or false }
  end
  return result
end

local function getContainer(containerId)
  local resolvedId = resolveContainerId(containerId)
  return resolvedId, containersById[resolvedId]
end

local function registerContainer(config)
  if type(config) ~= "table" or not config.id then
    log("E", logTag, "registerContainer requires config.id")
    return false
  end

  if containersById[config.id] then
    log("W", logTag, "container already registered: " .. tostring(config.id))
    return false
  end

  containersById[config.id] = {
    id = config.id,
    trigger = config.trigger,
    debugLabel = config.debugLabel or config.id,
    apps = cloneApps(config.apps),
  }

  return true
end

local function setAppVisibility(containerId, appId, visible)
  local resolvedId, container = getContainer(containerId)
  if not container then
    log("E", logTag, "container not found: " .. tostring(containerId))
    return
  end

  local app = container.apps[appId]
  if not app then
    log("E", logTag, "app not found: " .. tostring(appId) .. " for container: " .. tostring(resolvedId))
    return
  end

  app.visible = visible and true or false

  guihooks.trigger(container.trigger, {
    appId = appId,
    visible = app.visible,
    allApps = container.apps
  })
end

local function getAppVisibility(containerId, appId)
  local resolvedId, container = getContainer(containerId)
  if not container then
    log("E", logTag, "container not found: " .. tostring(containerId))
    return false
  end

  local app = container.apps[appId]
  if not app then
    log("E", logTag, "app not found: " .. tostring(appId) .. " for container: " .. tostring(resolvedId))
    return false
  end

  return app.visible
end

local function hideAllApps(containerId)
  local resolvedId, container = getContainer(containerId)
  if not container then
    log("E", logTag, "container not found: " .. tostring(containerId))
    return
  end

  for _, app in pairs(container.apps) do
    app.visible = false
  end

  guihooks.trigger(container.trigger, {
    hideAll = true,
    allApps = container.apps
  })

  extensions.hook("onUIContainerAppsHidden", resolvedId)
end

local function showApp(containerId, appId)
  setAppVisibility(containerId, appId, true)
end

local function hideApp(containerId, appId)
  setAppVisibility(containerId, appId, false)
end

local function toggleApp(containerId, appId)
  setAppVisibility(containerId, appId, not getAppVisibility(containerId, appId))
end

local function getVisibleApps(containerId)
  local _, container = getContainer(containerId)
  if not container then
    log("E", logTag, "container not found: " .. tostring(containerId))
    return {}
  end

  local visibleApps = {}
  for appId, app in pairs(container.apps) do
    if app.visible then
      table.insert(visibleApps, appId)
    end
  end

  return visibleApps
end

local function getAvailableApps(containerId)
  local _, container = getContainer(containerId)
  if not container then
    log("E", logTag, "container not found: " .. tostring(containerId))
    return {}
  end

  return cloneApps(container.apps)
end

local function onSerialize()
  local data = {}
  for containerId, container in pairs(containersById) do
    data[containerId] = {}
    for appId, app in pairs(container.apps) do
      data[containerId][appId] = app.visible
    end
  end
  return data
end

local function onDeserialize(data)
  if type(data) ~= "table" then
    return
  end

  for serializedContainerId, apps in pairs(data) do
    if type(apps) == "table" then
      local containerId = resolveContainerId(serializedContainerId)
      for appId, visible in pairs(apps) do
        setAppVisibility(containerId, appId, visible)
      end
    end
  end
end

local function setDebug(enabled)
  debugEnabled = enabled and true or false
end

local function setVerboseLogging(enabled)
  return enabled and true or false
end

local function onExtensionLoaded()
end

local function onExtensionUnloaded()
  containersById = {}
end

local function onUpdate()
  if not debugEnabled or not im then
    return
  end

  im.Begin("App Containers Debug")

  for containerId, container in pairs(containersById) do
    im.Text("Container: " .. containerId)

    local visibleApps = getVisibleApps(containerId)
    im.Text("Visible Apps: " .. #visibleApps .. "/" .. tableSize(container.apps))

    for _, appId in ipairs(tableKeysSorted(container.apps)) do
      local app = container.apps[appId]
      local isVisible = app.visible
      local buttonText = (isVisible and "Hide " or "Show ") .. appId
      if im.Button(buttonText .. "##" .. containerId .. "_" .. appId) then
        setAppVisibility(containerId, appId, not isVisible)
      end
      im.SameLine()
      im.Text(isVisible and "Y" or "N")
    end

    im.Separator()
    if im.Button("Hide All##" .. containerId) then
      hideAllApps(containerId)
    end
    im.SameLine()
    if im.Button("Show All##" .. containerId) then
      for appId, _ in pairs(container.apps) do
        showApp(containerId, appId)
      end
    end
  end

  im.End()
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate

M.registerContainer = registerContainer
M.resolveContainerId = resolveContainerId

M.setVerboseLogging = setVerboseLogging
M.setDebug = setDebug

M.setAppVisibility = setAppVisibility
M.getAppVisibility = getAppVisibility
M.showApp = showApp
M.hideApp = hideApp
M.toggleApp = toggleApp
M.hideAllApps = hideAllApps
M.getVisibleApps = getVisibleApps
M.getAvailableApps = getAvailableApps

M.onSerialize = onSerialize
M.onDeserialize = onDeserialize

return M
