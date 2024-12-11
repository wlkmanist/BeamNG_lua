local M = {}
local config = extensions.ui_router_config

local moduleName = "ui_router"

-- hooks
local setupHookName = "initialized"
local stateChangedHookName = "stateChanged"
local stateChangedAngularHookName = "stateChangedAngular"
local stateChangedVueHookName = "stateChangedVue"
local stateChangeErrorHookName = "stateChangeError"

local notifyListeners = function(hookName, ...)
  local eventName = moduleName .. "_" .. hookName
  extensions.hook(eventName, ...)
  guihooks.trigger(eventName, ...)
end

-- START ShowHide: Show/hide js frameworks based on route
local executeAngular = function(navigation, show)
  notifyListeners(stateChangedAngularHookName, {
    navigationData = navigation,
    show = show
  })
end

local executeVue = function(navigation, show)
  notifyListeners(stateChangedVueHookName, {
    navigationData = navigation,
    show = show
  })
end

local typeHandlerMap = {
  [config.types.angular] = executeAngular,
  [config.types.vue] = executeVue
}

local typeStatus = {
  [config.types.angular] = {
    enabled = false,
  },
  [config.types.vue] = {
    enabled = false,
  },
}

local toggleTypeByRoute = function(navigation)
  for _, v in pairs(config.types) do
    local show = v == navigation.toRoute.type
    typeHandlerMap[v](show and navigation or nil, show)
  end
end
-- END ShowHide

M.history = {}
M.forwardStack = {}
M.initialized = false

-- pushes new route into history
M.push = function(routeName, params)
  dump("ui_router.push", {routeName, params})
  local route = config.routes[routeName]
  dump("ui_router_push route", route)
  local params = params or {}

  if route then
    local fromRoute = M.history[#M.history] and M.history[#M.history].toRoute or nil
    local navigationData = {
      toRoute = route,
      toRouteParams = params,
      fromRoute = fromRoute or nil,
      fromRouteParams = fromRoute and fromRoute.toRouteParams or nil
    }

    table.insert(M.history, navigationData)
    M.forwardStack = {}
    toggleTypeByRoute(navigationData)
  else
    notifyListeners(stateChangeErrorHookName, {routeName, params})
  end
end

-- removes top route from history and pushes new route to replace it
M.replace = function(routeName, params)
  local route = config.routes[routeName]
  if route then
    local fromRoute = M.history[#M.history] and M.history[#M.history].toRoute or nil
    local navigationData = {
      fromRoute = fromRoute,
      toRoute = route,
      params = params or {}
    }

    M.history[#M.history] = navigationData
    M.forwardStack = {}
  else
    notifyListeners(stateChangeErrorHookName, {routeName, params})
  end
end

M.goPrevious = function()
  if #M.history > 1 then
    local current = table.remove(M.history)
    table.insert(M.forwardStack, current)

    local previous = M.history[#M.history]
    toggleTypeByRoute(previous)
  end
end

M.goNext = function()
  if #M.forwardStack > 0 then
    local next = table.remove(M.forwardStack)
    table.insert(M.history, next)

    toggleTypeByRoute(next)
  end
end

M.addRoute = function(route)
  dump("ui_router.addRoute", route)
  config.routes[route.name] = route
end

M.setup = function()
  dump("ui_router.setup called")
  M.intialized = true
  notifyListeners(setupHookName, true)
end

M.setTypeEnabled = function(type, enabled)
  for k, v in pairs(config.types) do
    if v == type then
      typeStatus[type] = enabled
      -- TODO: emit event here to the app type
      -- app will react to show/hide and do not emit events from here or let app ignore the events
    end
  end
end

M.onUiReady = function()
  dump("ui_router_onUiReady")
  notifyListeners("uiReady")
end

return M