local M = {}

M.dependencies = {"ui_router", "ui_router_routeManager", "ui_menuManager", "ui_legal"}

local Required = {"vue", "angular"}
local readyMap = {}

for _, t in ipairs(Required) do
  readyMap[t] = false
end

----------------------------------------------------------
-- Public API
----------------------------------------------------------
M.initialize = function(headlessMode)
  if headlessMode then
    extensions.hook('onUiReady')
  else
    extensions.load("ui_router")
  end
end

M.uiReady = function(uiType)
  if readyMap[uiType] == nil then
    log("W", "", "unknown uiType " .. tostring(uiType))
    return
  end

  extensions.hook("onUiReady", uiType)
  readyMap[uiType] = true

  if M.initialized then
    M.checkAndSyncRoute(uiType)
  else
    M._checkAllUiReady()
  end
end

M.isUiReady = function(uiType)
  if uiType then
    return readyMap[uiType]
  end

  for _, ok in pairs(readyMap) do
    if not ok then
      return false
    end
  end

  return true
end

M.checkAndSyncRoute = function(uiType)
  -- If not initialized, this is a first load, not a refresh
  if not M.initialized then
    return false
  end

  -- F5 reload: frameworks re-announce uiReady independently while Lua still
  -- marks them ready. Emit a refresh for all, so Angular-owned screens are restored
  -- even when only Vue re-announces
  local currentRoute = extensions.ui_router.getCurrent()
  if currentRoute then
    for _, frameworkId in ipairs(Required) do
      if frameworkId == uiType or readyMap[frameworkId] then
        guihooks.trigger("ui_router_routeRefresh", {
          request = currentRoute.request,
          resolved = currentRoute.resolved,
          refreshedBy = frameworkId
        })
      end
    end
  end

  return true
end

M.onExtensionLoaded = function()
  -- disable automatic unload
  setExtensionUnloadMode(M, "manual")
end

----------------------------------------------------------
-- Private API
----------------------------------------------------------
M._checkAllUiReady = function()
  if not M.isUiReady() then
    return
  end
  M.initialized = true
  extensions.hook("onAllUiReady")

  if not tech_license.isValid() then
    if not ui_legal.isOnlineConsentSet() then
      return extensions.ui_router.navigate("legal.onlineFeatures")
    end

    if core_settings_settings.getValue("showedInputLayoutPopupV37") == false then
      return extensions.ui_router.navigate("buttonLayout")
    end
  end

  -- dump("Online consent is set, continuing to the game or menu")
  local goingIntoGame = (core_gamestate and core_gamestate.state and core_gamestate.state.state == 'freeroam')
    or (core_gamestate and core_gamestate.loading and core_gamestate.loading())
  if goingIntoGame then
    extensions.ui_router.navigate("play")
  else
    extensions.ui_router.navigate("menu")
  end
end

return M
