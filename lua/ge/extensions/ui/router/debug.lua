local M = {}
M.dependencies = {"ui_imgui"}

local im = ui_imgui
local NavigationState = require("ge/extensions/ui/router/navigationState")
local RouteManager = require("ge/extensions/ui/router/routeManager")

local windowOpen = nil
local windowInitialized = false
local autoOpenRequested = false
local openDelayFrames = 0
local routeInputBuf = nil
local lastActionResult = nil

local cache = {
  currentRouteRef = nil,
  currentRoute = nil,
  pendingRouteRef = nil,
  pendingRoute = nil,
  breadcrumbs = nil
}

local routeModuleCache = {
  routeCount = 0,
  tree = nil
}

local skipKeys = {
  children = true
}

local function ensureImguiState()
  if not windowOpen then
    windowOpen = im.BoolPtr(false)
  end
  if not routeInputBuf then
    routeInputBuf = im.ArrayChar(256)
  end
  return true
end

local function renderTable(tbl, depth)
  depth = depth or 0
  if type(tbl) ~= "table" then
    im.TextWrapped(tostring(tbl))
    return
  end

  for k, v in pairs(tbl) do
    if not skipKeys[k] then
      local label = tostring(k)
      if type(v) == "table" then
        if im.TreeNode1(label) then
          renderTable(v, depth + 1)
          im.TreePop()
        end
      else
        im.Text(label .. ": " .. tostring(v))
      end
    end
  end
end

local function refreshCache()
  local liveCurrentEntry = NavigationState.getCurrentEntry()
  if liveCurrentEntry ~= cache.currentRouteRef then
    cache.currentRouteRef = liveCurrentEntry
    cache.currentRoute = liveCurrentEntry
    cache.breadcrumbs = liveCurrentEntry and liveCurrentEntry.resolved and liveCurrentEntry.resolved.breadcrumbs or {}
  end

  local livePendingEntry = NavigationState.getPendingEntry()
  if livePendingEntry ~= cache.pendingRouteRef then
    cache.pendingRouteRef = livePendingEntry
    cache.pendingRoute = livePendingEntry
  end
end

local function drawCurrentRouteNode()
  im.SeparatorText("Current Route")

  local node = cache.currentRoute
  if not node then
    im.TextWrapped("No current route")
    return
  end

  if type(node) == "table" then
    local name = node.request and node.request.name
    if name then
      im.Text("Name: " .. name)
      im.Separator()
    end
    renderTable(node)
  else
    im.Text("Route: " .. tostring(node))
  end
end

local function drawPendingRouteNode()
  im.SeparatorText("Pending Route")

  local node = cache.pendingRoute
  if not node then
    im.TextWrapped("No pending route")
    return
  end

  if type(node) == "table" then
    local name = node.request and node.request.name
    if name then
      im.Text("Name: " .. name)
      im.Separator()
    end
    renderTable(node)
  else
    im.Text("Route: " .. tostring(node))
  end
end

local function drawBreadcrumbs()
  im.SeparatorText("Breadcrumbs")

  local crumbs = cache.breadcrumbs
  if not crumbs or #crumbs == 0 then
    im.TextWrapped("No breadcrumbs")
    return
  end

  for i, entry in ipairs(crumbs) do
    if type(entry) == "table" then
      local label = entry.name or ("crumb " .. i)
      if im.TreeNode1(label .. "##breadcrumb" .. i) then
        renderTable(entry)
        im.TreePop()
      end
    else
      im.BulletText(i .. ". " .. tostring(entry))
    end
  end
end

local function drawActions()
  if not im.CollapsingHeader1("Actions") then
    return
  end

  im.InputText("##routeName", routeInputBuf, im.ArraySize(routeInputBuf))
  local routeName = ffi.string(routeInputBuf)

  im.SameLine()
  if im.Button("Navigate") then
    if routeName ~= "" then
      lastActionResult = extensions.ui_router.navigate(routeName)
      ffi.fill(routeInputBuf, im.ArraySize(routeInputBuf))
    end
  end

  if im.Button("Back") then
    lastActionResult = extensions.ui_router.back()
  end

  if lastActionResult then
    im.SeparatorText("Last Result")
    renderTable(lastActionResult)
  end
end

local function buildRouteModuleTree()
  local allRoutes = RouteManager.getAllRoutes()
  if not allRoutes or #allRoutes == 0 then
    routeModuleCache.routeCount = 0
    routeModuleCache.tree = nil
    return
  end

  if #allRoutes == routeModuleCache.routeCount and routeModuleCache.tree then
    return
  end

  local modules = {}
  for _, name in ipairs(allRoutes) do
    local dotPos = string.find(name, "%.")
    local moduleName = dotPos and string.sub(name, 1, dotPos - 1) or name
    if not modules[moduleName] then
      modules[moduleName] = {}
    end
    table.insert(modules[moduleName], name)
  end

  local tree = {}
  for moduleName, routes in pairs(modules) do
    table.sort(routes)
    table.insert(tree, {
      name = moduleName,
      routes = routes
    })
  end
  table.sort(tree, function(a, b)
    return a.name < b.name
  end)

  routeModuleCache.routeCount = #allRoutes
  routeModuleCache.tree = tree
end

local function drawRouteModules()
  if not im.CollapsingHeader1("Route Modules") then
    return
  end

  buildRouteModuleTree()

  if not routeModuleCache.tree then
    im.TextWrapped("No routes registered")
    return
  end

  for _, mod in ipairs(routeModuleCache.tree) do
    if im.TreeNode1(mod.name) then
      for _, routeName in ipairs(mod.routes) do
        if im.TreeNode1(routeName .. "##route") then
          local config = RouteManager.getRoute(routeName)
          if config then
            renderTable(config)
          else
            im.TextWrapped("(no config)")
          end
          im.TreePop()
        end
      end
      im.TreePop()
    end
  end
end

M.onExtensionLoaded = function()
  local showDebugger = not disableHwWarnings
  autoOpenRequested = showDebugger
end

M.onUpdate = function()
  if autoOpenRequested then
    if openDelayFrames > 0 then
      openDelayFrames = openDelayFrames - 1
      return
    end

    ensureImguiState()
    autoOpenRequested = false
    windowOpen[0] = true
  end

  if not windowOpen or not windowOpen[0] then
    return
  end

  if not windowInitialized then
    im.SetNextWindowSize(im.ImVec2(450, 600), im.Cond_FirstUseEver)
    windowInitialized = true
  end

  if im.Begin("Router Debugger", windowOpen) then
    refreshCache()
    drawCurrentRouteNode()
    drawPendingRouteNode()
    drawBreadcrumbs()
    drawActions()
    drawRouteModules()
  end
  im.End()
end

M.open = function()
  if not ensureImguiState() then
    autoOpenRequested = true
    return
  end
  windowOpen[0] = true
end

M.close = function()
  if windowOpen then
    windowOpen[0] = false
  end
end

M.toggle = function()
  if not ensureImguiState() then
    autoOpenRequested = true
    return
  end
  windowOpen[0] = not windowOpen[0]
end

return M
