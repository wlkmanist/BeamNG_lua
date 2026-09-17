-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
--[[
  extensions.load('gameplay_freeformDelivery_freeformDelivery')
  gameplay_freeformDelivery_freeformDelivery.load('gameplay/missions/driver_training/delivery/001-deliveryIntro/delivery.delivery.json')
  gameplay_freeformDelivery_freeformDelivery.start()
]]

local M = {}
--M.onExtensionLoaded = function() setExtensionUnloadMode(M, "manual") end
M.dependencies = {
  'core_vehicles',
  'core_gamestate',
  'gameplay_sites_sitesManager',
  'core_flowgraphManager',
  'core_quickAccess',
  'gameplay_freeformDelivery_utils',
  'gameplay_freeformDelivery_loader',
  'gameplay_freeformDelivery_setup',
  'gameplay_freeformDelivery_goals',
  'gameplay_freeformDelivery_tasklist',
  'gameplay_freeformDelivery_markers',
  'gameplay_freeformDelivery_endScreen',
  'gameplay_freeformDelivery_hints',
  'gameplay_freeformDelivery_routes',
  'gameplay_freeformDelivery_debug',
  'gameplay_freeformDelivery_odometer',
  'gameplay_freeformDelivery_vehicleSleep',
  'core_groundMarkers',
  'core_input_actionFilter',
  'ui_apps_genericMissionData'
}

local logTag = "freeformDelivery"



local Text = {
  delivery = "missions.freeformDelivery.common.bigmapGroup.delivery.label",
  clearRoute = "missions.freeformDelivery.common.quickAccess.clearRoute.title",
  clearRouteDescription = "missions.freeformDelivery.common.quickAccess.clearRoute.description",
  navigateTo = "missions.freeformDelivery.common.quickAccess.navigateTo.title",
  navigateToDescription = "missions.freeformDelivery.common.quickAccess.navigateTo.description",
  endDelivery = "missions.freeformDelivery.common.quickAccess.endDelivery.title",
  endDeliveryDescription = "missions.freeformDelivery.common.quickAccess.endDelivery.description",
}

local function contextTranslate(key, vars)
  if core_locales and core_locales.contextTranslate then
    return core_locales.contextTranslate(key, vars)
  end
  return _tr(key)
end

-- Debug configuration (accessible by submodules via gameplay_freeformDelivery_freeformDelivery.debug)
M.debug = {
  enabled = false,
  targetAreas = {
    location = true,
    zone = true,
    parkingSpot = true
  },
  p = nil --LuaProfiler("freeformDelivery")
}


-- State
local currentDelivery = nil
local isLoaded = false -- True when delivery is loaded and setup complete
local isActive = false -- True when delivery is active (goals, hints, markers visible)
local isFinished = false -- True when delivery has finished/failed (UI hidden, timer stopped, but vehicles still spawned)
local isFailed = false -- True when delivery failed (e.g., odometer exceeded)
local failReason = nil -- Reason for failure (e.g., "Vehicle exceeded maximum distance")
local startTime = 0
local setupPending = false -- True when setup is in progress, waiting for completion
local setupPendingStartTime = 0
local SETUP_TIMEOUT_SECONDS = 20

-- Action filter group name
local ACTION_FILTER_GROUP = 'freeformDeliveryBlockedActions'
local blockedActionTemplates = {"vehicleTeleporting", "vehicleMenues", "physicsControls", "aiControls", "vehicleSwitching", "freeCam", "funStuff"}
local unregisterQuickAccessMenu -- forward declaration

-- Helper function to cleanup all submodules
local function cleanupAllSubmodules()
  gameplay_freeformDelivery_goals.cleanup()
  gameplay_freeformDelivery_markers.cleanup()
  gameplay_freeformDelivery_tasklist.cleanup()
  gameplay_freeformDelivery_hints.cleanup()
  gameplay_freeformDelivery_routes.cleanup()
  gameplay_freeformDelivery_odometer.cleanup()
  gameplay_freeformDelivery_vehicleSleep.cleanup()
end

-- Expose isActive for quickAccess
function M.isActive()
  return isActive
end

-- Expose isFinished state
function M.isFinished()
  return isFinished
end

-- Expose isFailed state
function M.isFailed()
  return isFailed
end

-- Expose failReason
function M.getFailReason()
  return failReason
end

-- Public API
function M.load(path)
  if isActive or isLoaded or isFinished then
    log('W', logTag, 'Cannot load delivery while one is loaded/active/finished. Call teardown() first.')
    print(debug.tracesimple())
    return false
  end

  local deliveryData = gameplay_freeformDelivery_loader.load(path)
  if not deliveryData then
    log('E', logTag, 'Failed to load delivery from: ' .. tostring(path))
    return false
  end

  currentDelivery = deliveryData
  log('I', logTag, 'Loading delivery: ' .. (deliveryData.name or path))

  -- Setup vehicles, routes data, and put player in vehicle
  local success = gameplay_freeformDelivery_setup.setup(currentDelivery)
  if not success then
    log('E', logTag, 'Failed to setup delivery')
    currentDelivery = nil
    return false
  end

  -- Setup routes data (but don't activate UI)
  gameplay_freeformDelivery_routes.setup(currentDelivery)

  -- Setup odometer tracking for vehicles with the flag
  gameplay_freeformDelivery_odometer.setup(currentDelivery)
  gameplay_freeformDelivery_vehicleSleep.setup(currentDelivery)

  -- Block action filters (do this during loading, not starting)
  if core_input_actionFilter then
    local blockedActions = core_input_actionFilter.createActionTemplate(blockedActionTemplates)
    core_input_actionFilter.setGroup(ACTION_FILTER_GROUP, blockedActions)
    core_input_actionFilter.addAction(0, ACTION_FILTER_GROUP, true)
    log('I', logTag, 'Blocked action filters: ' .. table.concat(blockedActionTemplates, ', '))
  end

  -- Mark setup as pending - will be marked complete in onUpdate when setup is done
  setupPending = true
  setupPendingStartTime = os.clock()
  isLoaded = false

  -- Open debug window automatically when delivery is loaded
  gameplay_freeformDelivery_debug.toggleDebugWindow()



  log('I', logTag, 'Delivery setup started, waiting for completion...')
  return true
end

function M.isLoaded()
  return isLoaded
end

function M.getCurrentDelivery()
  return currentDelivery
end

function M.getStartTime()
  return startTime
end


function M.getSetupPending()
  return setupPending
end

function M.start()
  if not currentDelivery then
    log('E', logTag, 'No delivery loaded. Call load() first.')
    return false
  end

  if not isLoaded then
    log('E', logTag, 'Delivery not fully loaded yet. Wait for load() to complete.')
    return false
  end

  if isActive then
    log('W', logTag, 'Delivery already active.')
    return false
  end

  log('I', logTag, 'Starting delivery: ' .. currentDelivery.name)

  -- Reset finished state if we're restarting from finished state
  isFinished = false



  -- Reset clears routes/odometer module state, so re-setup on each start.
  gameplay_freeformDelivery_routes.setup(currentDelivery)
  gameplay_freeformDelivery_odometer.setup(currentDelivery)
  gameplay_freeformDelivery_vehicleSleep.setup(currentDelivery)

  -- Setup goals (make them visible and active)
  gameplay_freeformDelivery_goals.setup(currentDelivery)

  -- Setup markers (make them visible)
  gameplay_freeformDelivery_markers.setup(currentDelivery)

  -- Setup tasklist (make it visible)
  gameplay_freeformDelivery_tasklist.setup(currentDelivery)

  -- Setup hints (make them visible)
  gameplay_freeformDelivery_hints.setup(currentDelivery)

  -- Activate delivery
  isActive = true
  startTime = os.clock()

  log('I', logTag, 'Delivery started')
  return true
end

function M.finish(failed, reason)
  if not isActive then
    log('W', logTag, 'No active delivery to finish.')
    return false
  end

  if failed then
    log('W', logTag, 'Finishing delivery (FAILED): ' .. currentDelivery.name)
    if reason then
      log('W', logTag, 'Failure reason: ' .. tostring(reason))
    end
  else
    log('I', logTag, 'Finishing delivery: ' .. currentDelivery.name)
  end

  -- Calculate and store elapsed time
  if startTime > 0 then
    local elapsedTime = os.clock() - startTime
    currentDelivery.elapsedTime = elapsedTime
    log('I', logTag, string.format('Delivery elapsed time: %.2f seconds', elapsedTime))
  end

  -- Store failure state
  isFailed = failed or false
  failReason = reason or nil

  -- Hide UI elements (markers, tasklist, hints, routes)
  -- Goals: only hide from tasklist, keep internal state for evaluation
  gameplay_freeformDelivery_goals.hideFromTasklist()
  gameplay_freeformDelivery_markers.cleanup()
  gameplay_freeformDelivery_tasklist.cleanup()
  gameplay_freeformDelivery_hints.cleanup()
  gameplay_freeformDelivery_routes.cleanup()
  gameplay_freeformDelivery_odometer.cleanup()

  -- Freeze all delivery vehicles
  gameplay_freeformDelivery_setup.freezeAllVehicles(true)

  -- Clear timer display
  ui_apps_genericMissionData.setData({category = "freeformDelivery_timer", clear = true})

  -- Transition to finished state (timer disabled, no goals/hints showing)
  isActive = false
  isFinished = true
  -- Note: startTime is preserved so getResults() can still work
  -- Note: currentDelivery is preserved so teardown can access it later
  -- Note: goals and goalStates are preserved so evaluation functions still work
  -- Note: elapsedTime is stored in currentDelivery for access in constructor
  -- Note: isFailed and failReason are preserved for evaluation

  -- Remove quickaccess generators so delivery entries are not shown after ending.
  unregisterQuickAccessMenu()

  if failed then
    log('I', logTag, 'Delivery failed (transitioned to finished state)')
  else
    log('I', logTag, 'Delivery finished (transitioned to finished state)')
  end
  return true
end

function M.getProgress()
  -- Can get progress when active or finished (but not when just loaded)
  if (not isActive and not isFinished) or not currentDelivery then
    return nil
  end

  return gameplay_freeformDelivery_goals.getProgress()
end

function M.getResults()
  -- Can get results when active or finished (but not when just loaded)
  if (not isActive and not isFinished) or not currentDelivery or startTime == 0 then
    return nil
  end

  -- Use endScreen's collectStatistics function
  return gameplay_freeformDelivery_endScreen.collectStatistics(currentDelivery, startTime)
end

function M.reset()
  if not isActive and not isFinished then
    log('W', logTag, 'No active or finished delivery to reset.')
    return false
  end

  log('I', logTag, 'Resetting delivery: ' .. currentDelivery.name)

  -- Cleanup UI elements (hide goals, markers, tasklist, hints)
  cleanupAllSubmodules()

  -- Clear timer display
  ui_apps_genericMissionData.setData({category = "freeformDelivery_timer", clear = true})

  -- Unfreeze all delivery vehicles
  gameplay_freeformDelivery_setup.freezeAllVehicles(false)

  -- Restore vehicle positions and reset physics
  gameplay_freeformDelivery_setup.restoreVehicleTransforms()

  -- Re-apply player start on every start so restarts behave like fresh attempts
  gameplay_freeformDelivery_setup.setupPlayer(currentDelivery)

  -- Reset start time
  startTime = 0

  -- Deactivate delivery (return to loaded-but-not-active state)
  -- Goals will be reset when start() is called again
  isActive = false
  isFinished = false
  isFailed = false
  failReason = nil

  log('I', logTag, 'Delivery reset complete (returned to loaded state)')
  return true
end

local function endDeliveryAndLog()
  if not isActive then
    log('W', logTag, 'No active delivery to end')
    return
  end

  log('I', logTag, 'Ending delivery via quickAccess menu')

  -- Collect statistics using endScreen module
  local stats = gameplay_freeformDelivery_endScreen.collectStatistics(currentDelivery, startTime)
  if stats then
    log('I', logTag, '=== DELIVERY SUMMARY ===')
    log('I', logTag, string.format('Delivery: %s', currentDelivery.name or "Unknown"))
    log('I', logTag, string.format('Time: %s', stats.timeStr))
    log('I', logTag, string.format('Goals: %d/%d completed (%d/%d required)',
      stats.goalsCompleted or 0, stats.goalsTotal or 0,
      stats.goalsRequiredCompleted or 0, stats.goalsRequired or 0))
    log('I', logTag, '=======================')
  end

  -- Transition to finished state (instead of immediate cleanup)
  M.finish()
end

local quickAccessInitialized = false
local QUICKACCESS_SANDBOX_GENERATOR_ID = 'freeformDelivery_sandboxGenerator'
local QUICKACCESS_DELIVERY_GENERATOR_ID = 'freeformDelivery_deliveryGenerator'
local QUICKACCESS_DELIVERY_CATEGORY_ID = 'freeformDelivery_category'

function unregisterQuickAccessMenu()
  if not core_quickAccess then return end

  core_quickAccess.addEntry({
    level = '/root/sandbox/delivery/',
    uniqueID = QUICKACCESS_DELIVERY_GENERATOR_ID,
    generator = function() end
  })

  quickAccessInitialized = false
  if core_quickAccess.reload then
    core_quickAccess.reload()
  end
end

-- Generate route menu entries
local function generateRouteEntries()
  local entries = {}

  -- Add clear route entry (only show if a route is currently set)
  local currentRoute = gameplay_freeformDelivery_routes.getCurrentRoute()
  if currentRoute then
    table.insert(entries, {
      title = _tr(Text.clearRoute),
      icon = "trashBin2",
      desc = _tr(Text.clearRouteDescription),
      uniqueID = 'freeformDelivery_clearRoute',
      startSlot = 1,
      endSlot = 1,
      onSelect = function()
        gameplay_freeformDelivery_routes.clearRoute()
        return {'hide'}
      end
    })
  end

  -- Add route entries
  local availableRoutes = gameplay_freeformDelivery_routes.getRoutes()
  if availableRoutes and #availableRoutes > 0 then
    for i, route in ipairs(availableRoutes) do
      local routeName = gameplay_freeformDelivery_routes.getRouteName(route)
      local routeIcon = route.icon
      if not routeIcon then
        if route.vehicleId then
          routeIcon = "car"
        elseif route.targetAreaId then
          local targetArea = currentDelivery and gameplay_freeformDelivery_utils.findTargetArea(currentDelivery, route.targetAreaId)
          routeIcon = (targetArea and targetArea.type == "parkingSpot") and "parking" or "locationDestination"
        else
          routeIcon = "location1"
        end
      end
      table.insert(entries, {
        title = contextTranslate(Text.navigateTo, { destination = routeName }),
        icon = routeIcon,
        desc = contextTranslate(Text.navigateToDescription, { destination = routeName }),
        uniqueID = 'freeformDelivery_route_' .. i,
        onSelect = function()
          if route.targetAreaId then
            gameplay_freeformDelivery_routes.setRouteToTargetArea(route.targetAreaId, route)
          elseif route.vehicleId then
            gameplay_freeformDelivery_routes.setRouteToVehicle(route.vehicleId, route)
          end
          return {'hide'}
        end
      })
    end
  end

  return entries
end

local function registerQuickAccessMenu()
  if not core_quickAccess then return end
  if quickAccessInitialized then return end
  quickAccessInitialized = true

  -- Register delivery category in sandbox menu
  core_quickAccess.addEntry({
    level = '/root/sandbox/',
    uniqueID = QUICKACCESS_SANDBOX_GENERATOR_ID,
    generator = function(entries)
      if not isActive then return end
      table.insert(entries, {
        title = _tr(Text.delivery),
        ["goto"] = '/root/sandbox/delivery/',
        icon = 'boxTruckFast',
        uniqueID = QUICKACCESS_DELIVERY_CATEGORY_ID,
        categoryOrder = 1
      })
    end
  })

  -- Register entry in delivery category
  core_quickAccess.addEntry({
    level = '/root/sandbox/delivery/',
    uniqueID = QUICKACCESS_DELIVERY_GENERATOR_ID,
    generator = function(entries)
      if not isActive then return end

      -- Add end delivery entry (always in slot 0)
      table.insert(entries, {
        title = _tr(Text.endDelivery),
        icon = "checkmarkBold",
        desc = _tr(Text.endDeliveryDescription),
        uniqueID = 'freeformDelivery_end',
        startSlot = 0,
        endSlot = 0,
        onSelect = function()
          endDeliveryAndLog()
          return {'hide'}
        end
      })

      -- Add route entries
      local routeEntries = generateRouteEntries()
      for _, entry in ipairs(routeEntries) do
        table.insert(entries, entry)
      end
    end
  })
end

local function onBeforeRadialOpened()
  registerQuickAccessMenu()
end

local function onQuickAccessLoaded()
  quickAccessInitialized = false
end

local highLevelP = nil--LuaProfiler("highLevel")

-- Update vehicle cache for all delivery vehicles
local function updateVehicleCache()
  if not gameplay_freeformDelivery_setup or not currentDelivery or not currentDelivery.vehicles then
    return
  end

  local allVehicles = {}
  for _, vehicleData in ipairs(currentDelivery.vehicles) do
    local veh = gameplay_freeformDelivery_utils.getVehicleObjectByDeliveryId(vehicleData.id)
    if veh then
      table.insert(allVehicles, veh)
    end
  end
  gameplay_freeformDelivery_utils.updateVehicleCacheList(allVehicles)
end

-- Main update loop
local timerData = {
  title = "missions.missions.general.time",
  category = "freeformDelivery_timer",
  style = "time",
  order = 100,
}
local function onUpdate(dtReal, dtSim, dtRaw)
  if highLevelP then highLevelP:start() end

  -- Check if setup is pending and wait for completion
  if setupPending then
    local setupComplete = gameplay_freeformDelivery_setup.isSetupComplete()
    local odometerComplete = gameplay_freeformDelivery_odometer.isSetupComplete()

    if setupComplete and odometerComplete then
      setupPending = false
      setupPendingStartTime = 0
      isLoaded = true
      log('I', logTag, 'Delivery loaded and setup complete (ready to start)')
    else
      if setupPendingStartTime > 0 and (os.clock() - setupPendingStartTime) >= SETUP_TIMEOUT_SECONDS then
        log('E', logTag, string.format('Delivery setup timeout after %.1f seconds. Aborting and tearing down.', SETUP_TIMEOUT_SECONDS))
        M.teardown()
        if highLevelP then highLevelP:finish(false) end
        return
      end
      if highLevelP then highLevelP:finish(false) end
      return
    end
  end

  -- Only update delivery systems if active (not finished)
  if not isActive then
    if highLevelP then highLevelP:finish(false) end
    return
  end

  if highLevelP then highLevelP:add("setup check") end

  -- Update vehicle cache before other systems use it
  updateVehicleCache()
  if highLevelP then highLevelP:add("update vehicle cache") end

  -- Update all delivery systems
  gameplay_freeformDelivery_goals.update(dtReal, dtSim, dtRaw, M.debug.p)
  if highLevelP then highLevelP:add("goals.update") end

  gameplay_freeformDelivery_markers.update(dtReal, dtSim, dtRaw, M.debug.p)
  if highLevelP then highLevelP:add("markers.update") end

  gameplay_freeformDelivery_tasklist.update(M.debug.p)
  if highLevelP then highLevelP:add("tasklist.update") end

  gameplay_freeformDelivery_hints.update(dtReal, dtSim, dtRaw, M.debug.p)
  if highLevelP then highLevelP:add("hints.update") end

  gameplay_freeformDelivery_routes.update(dtReal, dtSim, dtRaw, M.debug.p)
  if highLevelP then highLevelP:add("routes.update") end

  -- Update odometer tracking
  gameplay_freeformDelivery_odometer.update(dtReal)
  if highLevelP then highLevelP:add("odometer.update") end

  gameplay_freeformDelivery_vehicleSleep.update()
  if highLevelP then highLevelP:add("vehicleSleep.update") end

  -- Update timer display using genericMissionData
  if startTime >= 0 then
    local elapsedTime = os.clock() - startTime
    timerData.txt = elapsedTime
    timerData.minutes = string.format("%02d", math.floor(elapsedTime / 60))
    timerData.seconds = string.format("%02d", math.floor(elapsedTime % 60))
    timerData.style = "text"
    ui_apps_genericMissionData.setData(timerData)
  end

  -- Check completion timer and auto-finish if needed
  if gameplay_freeformDelivery_goals.updateCompletionTimer(dtReal) then
    if highLevelP then highLevelP:add("completionTimer check") end
    M.finish()
    if highLevelP then highLevelP:add("finish") end
  else
    if highLevelP then highLevelP:add("completionTimer check") end
  end

  if highLevelP then highLevelP:finish(dtSim > 0) end
end
M.onUpdate = onUpdate
M.onBeforeRadialOpened = onBeforeRadialOpened
M.onQuickAccessLoaded = onQuickAccessLoaded

-- Teardown: Actually removes vehicles, unloads delivery, etc.
function M.teardown(keepVehicles)
  keepVehicles = keepVehicles or false
  if not isLoaded and not isActive and not isFinished and not setupPending then return end

  log('I', logTag, 'Tearing down delivery (removing vehicles, unloading, etc.)')

  -- Unblock action filters
  if core_input_actionFilter then
    core_input_actionFilter.addAction(0, ACTION_FILTER_GROUP, false)
    log('I', logTag, 'Unblocked action filters')
  end

  -- Cleanup all sub-modules (UI already cleaned up in finish(), but do it again to be safe)
  cleanupAllSubmodules()

  -- Clear timer display
  ui_apps_genericMissionData.setData({category = "freeformDelivery_timer", clear = true})

  -- Unfreeze all delivery vehicles
  gameplay_freeformDelivery_setup.freezeAllVehicles(false)

  -- Actually remove vehicles and unload delivery
  gameplay_freeformDelivery_setup.cleanup(currentDelivery, keepVehicles)

  gameplay_rawPois.clear()

  -- Reset state
  currentDelivery = nil
  isLoaded = false
  isActive = false
  isFinished = false
  isFailed = false
  failReason = nil
  startTime = 0
  unregisterQuickAccessMenu()
  setupPending = false
  setupPendingStartTime = 0

  log('I', logTag, 'Delivery teardown complete')
end

-- Legacy cleanup function (now calls teardown for backwards compatibility)
function M.cleanup()
  M.teardown()
end

function M.onExtensionUnloaded()
  M.teardown()
end

local function onClientEndMission()
  M.teardown()
end

M.onClientEndMission = onClientEndMission
return M
