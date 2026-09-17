-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {
  'core_vehicleBridge',
  'core_vehicle_manager',
  'gameplay_freeformDelivery_utils',
  'gameplay_freeformDelivery_setup'
}
local logTag = "freeformDelivery_odometer"

-- Track vehicles with odometer tracking enabled
local trackedVehicles = {} -- vehId -> {deliveryVehicleId, startingOdometer, currentOdometer, maxOdometer, vehData}
local pendingOdometerRequests = {} -- Track vehicles waiting for odometer data
local odometerUpdateTimer = 0
local odometerUpdateInterval = 1.0 / 8.0 -- Update 8 times per second
local odometerMessageId = "delivery_odometer"

local Text = {
  notAvailable = "missions.freeformDelivery.common.notAvailable",
  unknownVehicle = "missions.freeformDelivery.common.vehicle.unknown",
  odometer = "missions.freeformDelivery.common.odometer",
  allowedOdometer = "missions.freeformDelivery.common.allowedOdometer",
  odometerLimitExceeded = "missions.freeformDelivery.common.odometerLimitExceeded",
}

local function contextTranslate(key, vars)
  if core_locales and core_locales.contextTranslate then
    return core_locales.contextTranslate(key, vars)
  end
  return _tr(key)
end

-- Conversion constants
local CONVERSIONS = {
  M_TO_FT = 3.2808399
}

-- Format distance value (similar to distanceMinor from vehicleSpecifications)
local function formatDistance(value)
  if type(value) ~= 'number' or value < 0 then
    return _tr(Text.notAvailable)
  end
  local metricOrImperial = settings.getValue('uiUnitLength')
  -- value is in m
  if metricOrImperial == 'metric' then
    return string.format("%0.2f m", value)
  else
    return string.format("%0.2f ft", value * CONVERSIONS.M_TO_FT)
  end
end

-- Request odometer value for a vehicle (async)
local function requestOdometer(vehId, deliveryVehicleId, vehData, maxOdometer)
  if not core_vehicleBridge then
    log('W', logTag, 'core_vehicleBridge not available')
    return false
  end

  local veh = getObjectByID(vehId)
  if not veh then
    log('W', logTag, 'Vehicle not found: ' .. tostring(vehId))
    return false
  end

  -- Mark as pending
  pendingOdometerRequests[vehId] = true

  core_vehicleBridge.requestValue(veh, function(res)
    pendingOdometerRequests[vehId] = nil

    local mainPartName = "/" .. vehData.config.mainPartName
    local part = res.result and res.result[mainPartName]
    if not part then
      log('W', logTag, 'Could not find part ' .. tostring(mainPartName) .. ' - starting odometer will be -1')
      trackedVehicles[vehId] = {
        deliveryVehicleId = deliveryVehicleId,
        startingOdometer = -1,
        currentOdometer = -1,
        maxOdometer = maxOdometer,
        vehData = vehData
      }
    else
      local odometer = part.odometer or -1
      trackedVehicles[vehId] = {
        deliveryVehicleId = deliveryVehicleId,
        startingOdometer = odometer,
        currentOdometer = odometer,
        maxOdometer = maxOdometer,
        vehData = vehData
      }
      log('I', logTag, string.format('Vehicle %s starting odometer: %.2f m (%.2f km)', deliveryVehicleId, odometer, odometer / 1000))
    end
  end, 'getPartConditions')

  return true
end

-- Setup odometer tracking for vehicles with the flag
function M.setup(delivery)
  if not delivery or not delivery.vehicles then return end

  trackedVehicles = {}
  pendingOdometerRequests = {}
  odometerUpdateTimer = 0

  if not core_vehicleBridge then
    log('W', logTag, 'core_vehicleBridge not available, odometer tracking disabled')
    return
  end

  if not core_vehicle_manager then
    log('W', logTag, 'core_vehicle_manager not available, odometer tracking disabled')
    return
  end

  -- Find vehicles with odometer tracking flag
  for _, vehicleDef in ipairs(delivery.vehicles) do
    if vehicleDef.trackOdometer then
      -- Get vehicle ID from setup module
      local vehId = gameplay_freeformDelivery_setup.getVehicleId(vehicleDef.id)
      if vehId then
        local vehData = core_vehicle_manager.getVehicleData(vehId)
        if vehData then
          local veh = getObjectByID(vehId)
          if not vehicleDef.partsInitialized then
            veh:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, %f)", 0, 0))
            vehicleDef.partsInitialized = true
          end
          -- Pass maxOdometer if specified in vehicle definition
          local maxOdometer = vehicleDef.maxOdometer or nil
          requestOdometer(vehId, vehicleDef.id, vehData, maxOdometer)
        else
          log('W', logTag, 'Could not get vehicle data for: ' .. tostring(vehicleDef.id))
        end
      else
        log('W', logTag, 'Vehicle ID not found for: ' .. tostring(vehicleDef.id))
      end
    end
  end
end

-- Check if odometer requests are complete
function M.isSetupComplete()
  return next(pendingOdometerRequests) == nil
end

-- Update odometer values (called 8 times per second)
function M.update(dtReal)
  if not core_vehicleBridge or not core_vehicle_manager then return end

  -- Update timer
  odometerUpdateTimer = odometerUpdateTimer + dtReal
  if odometerUpdateTimer < odometerUpdateInterval then return end
  odometerUpdateTimer = 0

  -- Update odometer for all tracked vehicles and check for maxOdometer violations
  for vehId, vehicleData in pairs(trackedVehicles) do
    local veh = getObjectByID(vehId)
    if veh then
      core_vehicleBridge.requestValue(veh, function(res)
        local mainPartName = "/" .. vehicleData.vehData.config.mainPartName
        local part = res.result and res.result[mainPartName]
        if part and part.odometer then
          vehicleData.currentOdometer = part.odometer

          -- Check if maxOdometer is exceeded
          if vehicleData.maxOdometer and vehicleData.currentOdometer >= 0 and vehicleData.startingOdometer >= 0 then
            local distanceTraveled = vehicleData.currentOdometer - vehicleData.startingOdometer
            if distanceTraveled > vehicleData.maxOdometer then
              -- Fail the delivery (only if still active)
              if gameplay_freeformDelivery_freeformDelivery.isActive() then
                local vehicleName = vehicleData.deliveryVehicleId or _tr(Text.unknownVehicle)
                local failReason = contextTranslate(Text.odometerLimitExceeded, {
                  vehicleName = vehicleName,
                  distance = formatDistance(distanceTraveled),
                  maxDistance = formatDistance(vehicleData.maxOdometer)
                })
                log('E', logTag, 'Odometer limit exceeded: ' .. failReason)
                gameplay_freeformDelivery_freeformDelivery.finish(true, failReason)
              end
            end
          end
        end
      end, 'getPartConditions')
    end
  end
end

-- Get odometer data for a vehicle
function M.getOdometerData(vehId)
  return trackedVehicles[vehId]
end

-- Get odometer data by delivery vehicle ID
function M.getOdometerDataByDeliveryId(deliveryVehicleId)
  for vehId, data in pairs(trackedVehicles) do
    if data.deliveryVehicleId == deliveryVehicleId then
      return data
    end
  end
  return nil
end

-- Update tasklist message with current odometer
local lastMessage = nil
function M.updateTasklistMessage()
  local playerVehId = be:getPlayerVehicleID(0)
  local odometerData = trackedVehicles[playerVehId]

  if not odometerData then
    -- Player vehicle doesn't have odometer tracking, remove message
    lastMessage = nil
    guihooks.trigger("DiscardTasklistItem", odometerMessageId)
    return
  end

  -- Calculate distance traveled (difference from starting odometer)
  local distanceTraveled = -1
  if odometerData.startingOdometer >= 0 and odometerData.currentOdometer >= 0 then
    distanceTraveled = odometerData.currentOdometer - odometerData.startingOdometer
  end

  -- Build message showing only the difference
  local message = ""
  if distanceTraveled >= 0 then
    if odometerData.maxOdometer then
      message = contextTranslate(Text.allowedOdometer, {
        distance = formatDistance(distanceTraveled),
        maxDistance = formatDistance(odometerData.maxOdometer)
      })
    else
      message = contextTranslate(Text.odometer, { distance = formatDistance(distanceTraveled) })
    end
  else
    message = contextTranslate(Text.odometer, { distance = _tr(Text.notAvailable) })
  end

  if lastMessage ~= message then
    lastMessage = message
    -- Update tasklist message
    guihooks.trigger("SetTasklistTask", {
      id = odometerMessageId,
      type = "message",
      label = message,
      done = false,
      fail = false
    })
  end
end

function M.cleanup()
  trackedVehicles = {}
  pendingOdometerRequests = {}
  odometerUpdateTimer = 0
  lastMessage = nil
  guihooks.trigger("DiscardTasklistItem", odometerMessageId)
end

return M
