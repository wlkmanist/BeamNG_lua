-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = { "ui_appContainers" }

local logTag = "appContainers_topCenter"
local verboseLogging = false
local debug = false
local im = ui_imgui

local CONTAINER_ID = "topCenter"
local FLASH_MESSAGE_QUEUE_LIMIT = 50
local FLASH_MESSAGE_EVENT = "TopCenterAppsFlashMessage"

local flashMessageQueue = {}
local currentMessage = nil

local function setAppVisibility(containerId, appId, visible)
  ui_appContainers.setAppVisibility(containerId, appId, visible)
end

local function getAppVisibility(containerId, appId)
  return ui_appContainers.getAppVisibility(containerId, appId)
end

local function hideAllApps(containerId)
  ui_appContainers.hideAllApps(containerId)
end

local function showApp(containerId, appId)
  ui_appContainers.showApp(containerId, appId)
end

local function hideApp(containerId, appId)
  ui_appContainers.hideApp(containerId, appId)
end

local function toggleApp(containerId, appId)
  ui_appContainers.toggleApp(containerId, appId)
end

local function getVisibleApps(containerId)
  return ui_appContainers.getVisibleApps(containerId)
end

local function getAvailableApps(containerId)
  return ui_appContainers.getAvailableApps(containerId)
end

local function setContainerContext(containerId, context)
  if verboseLogging then
    log("W", logTag, "setContainerContext is deprecated, use setAppVisibility instead")
  end
  if not context then
    hideAllApps(containerId)
    return
  end
  hideAllApps(containerId)
  showApp(containerId, context)
end

local function resetContainerContext(containerId)
  if verboseLogging then
    log("W", logTag, "resetContainerContext is deprecated, use hideAllApps instead")
  end
  hideAllApps(containerId)
end

local function getContainerContext(containerId)
  if verboseLogging then
    log("W", logTag, "getContainerContext is deprecated, use getVisibleApps instead")
  end
  local visibleApps = getVisibleApps(containerId)
  return visibleApps[1] or nil
end

local function setDebug(enabled)
  debug = enabled and true or false
end

local function setVerboseLogging(enabled)
  verboseLogging = enabled and true or false
end

local function onScenarioFlashMessage(data)
  if data and #data > 0 then
    showApp(CONTAINER_ID, "flashMessage")
  end

  local isCountdown = false
  local goTtl = nil
  if type(data) == "table" then
    for i = 1, #data do
      local head = data[i] and data[i][1]
      if type(head) == "number" or head == "ui.scenarios.go" then
        isCountdown = true
      end
      if head == "ui.scenarios.go" then
        goTtl = data[i][2] or 1
      end
    end
  end

  if isCountdown then
    showApp(CONTAINER_ID, "countdown")
    if goTtl then
      M._countdownHideTimer = goTtl
    end
  end
end

local function onScenarioFlashMessageClear()
  hideApp(CONTAINER_ID, "flashMessage")
end

local function onScenarioNotRunning()
  hideApp(CONTAINER_ID, "flashMessage")
end

local function queueFlashMessage(messageData, source)
  local duration = 3.0
  if messageData and messageData[1] and messageData[1][2] then
    duration = messageData[1][2]
  end

  local message = {
    data = messageData,
    source = source,
    duration = duration,
    timer = 0
  }

  if #flashMessageQueue >= FLASH_MESSAGE_QUEUE_LIMIT then
    table.remove(flashMessageQueue, 1)
  end
  table.insert(flashMessageQueue, message)
end

local function processNextMessage()
  if #flashMessageQueue > 0 and not currentMessage then
    currentMessage = table.remove(flashMessageQueue, 1)
    currentMessage.timer = 0
    showApp(CONTAINER_ID, "flashMessage")
    guihooks.trigger(FLASH_MESSAGE_EVENT, currentMessage.data)
  end
end

local function clearMessagesFromSource(source)
  for i = #flashMessageQueue, 1, -1 do
    if flashMessageQueue[i].source == source then
      table.remove(flashMessageQueue, i)
    end
  end

  if currentMessage and currentMessage.source == source then
    currentMessage = nil
    if #flashMessageQueue == 0 then
      hideApp(CONTAINER_ID, "flashMessage")
    else
      processNextMessage()
    end
  end
end

local function clearAllFlashMessages()
  flashMessageQueue = {}
  currentMessage = nil
  hideApp(CONTAINER_ID, "flashMessage")
end

local function onGameplayFlashMessage(data)
  if not data or not data.source then
    if verboseLogging then
      log("W", logTag, "Invalid flash message data received")
    end
    return
  end

  local sourceToAppId = { drift = "drift", drag = "drag" }
  local appId = sourceToAppId[data.source]
  if not appId then
    if verboseLogging then
      log("W", logTag, "Unknown flash message source: " .. tostring(data.source))
    end
    return
  end

  if getAppVisibility(CONTAINER_ID, appId) then
    queueFlashMessage(data.data, data.source)
    processNextMessage()
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if currentMessage then
    currentMessage.timer = currentMessage.timer + dtSim
    if currentMessage.timer >= currentMessage.duration then
      currentMessage = nil
      if #flashMessageQueue == 0 then
        hideApp(CONTAINER_ID, "flashMessage")
      else
        processNextMessage()
      end
    end
  else
    processNextMessage()
  end

  if M._countdownHideTimer and M._countdownHideTimer > 0 then
    M._countdownHideTimer = M._countdownHideTimer - dtSim
    if M._countdownHideTimer <= 0 then
      hideApp(CONTAINER_ID, "countdown")
      M._countdownHideTimer = nil
    end
  end

  if debug and im then
    im.Begin("TopCenter App Containers Debug")
    im.Text("Queue Size: " .. #flashMessageQueue)
    im.Text("Current Message: " .. (currentMessage and "Active" or "None"))
    im.End()
  end
end

local function onExtensionLoaded()
  ui_appContainers.registerContainer({
    id = CONTAINER_ID,
    trigger = "setTopCenterAppVisibility",
    apps = {
      arrowGPS = { visible = false },
      rally = { visible = false },
      drift = { visible = false },
      drag = { visible = false },
      pointsBar = { visible = false },
      flashMessage = { visible = false },
      countdown = { visible = false },
    }
  })
end

local function onExtensionUnloaded()
  flashMessageQueue = {}
  currentMessage = nil
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate


M.onGameplayFlashMessage = onGameplayFlashMessage
M.clearMessagesFromSource = clearMessagesFromSource
M.clearAllFlashMessages = clearAllFlashMessages
M.onScenarioFlashMessage = onScenarioFlashMessage
M.onScenarioFlashMessageClear = onScenarioFlashMessageClear
M.onScenarioNotRunning = onScenarioNotRunning

M.setVerboseLogging = setVerboseLogging
M.setDebug = setDebug

M.setContainerContext = setContainerContext
M.getContainerContext = getContainerContext
M.resetContainerContext = resetContainerContext
M.getAvailableContexts = getAvailableApps

M.setAppVisibility = setAppVisibility
M.getAppVisibility = getAppVisibility
M.showApp = showApp
M.hideApp = hideApp
M.toggleApp = toggleApp
M.hideAllApps = hideAllApps
M.getVisibleApps = getVisibleApps
M.getAvailableApps = getAvailableApps

return M
