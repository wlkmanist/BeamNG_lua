-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "freeformDelivery_vehicleSleep"

local trackedVehicles = {}

local function computeDefaultWakeDistance(sleepDistance)
  return math.max(sleepDistance - 50, sleepDistance * 0.8)
end

local function normalizeVehicleSleepSettings(vehicleDef)
  if not vehicleDef then return false end

  local sleepDistance = vehicleDef.sleepDistance
  if sleepDistance == nil then
    return false
  end

  if type(sleepDistance) ~= "number" or sleepDistance <= 0 then
    log('E', logTag, "Invalid sleepDistance for vehicle " .. tostring(vehicleDef.id) .. ". Expected number > 0.")
    vehicleDef.sleepDistance = nil
    vehicleDef.wakeDistance = nil
    return false
  end

  local wakeDistance = vehicleDef.wakeDistance
  local computedWakeDistance = computeDefaultWakeDistance(sleepDistance)
  local wakeDistanceMissing = wakeDistance == nil or type(wakeDistance) ~= "number" or wakeDistance <= 0

  if wakeDistanceMissing then
    wakeDistance = computedWakeDistance
  elseif wakeDistance > sleepDistance then
    log('E', logTag, string.format(
      "Invalid wakeDistance for vehicle %s (wakeDistance %.2f > sleepDistance %.2f). Using default.",
      tostring(vehicleDef.id), wakeDistance, sleepDistance
    ))
    wakeDistance = computedWakeDistance
  end

  vehicleDef.wakeDistance = wakeDistance
  return true
end

function M.setup(delivery)
  trackedVehicles = {}
  if not delivery or not delivery.vehicles then return end

  for _, vehicleDef in ipairs(delivery.vehicles) do
    if normalizeVehicleSleepSettings(vehicleDef) then
      local sleepDistance = vehicleDef.sleepDistance
      local veh = gameplay_freeformDelivery_utils.getVehicleObjectByDeliveryId(vehicleDef.id)
      if veh then
        local wakeDistance = vehicleDef.wakeDistance
        trackedVehicles[vehicleDef.id] = {
          deliveryVehicleId = vehicleDef.id,
          vehId = veh:getID(),
          sleepDistance = sleepDistance,
          wakeDistance = wakeDistance,
          sleeping = false,
          cameraDistance = math.huge,
          playerVehicleDistance = math.huge
        }
        veh:setActive(1)
      else
        log('W', logTag, "Could not track vehicle for sleep logic: " .. tostring(vehicleDef.id))
      end
    end
  end
end

function M.update()
  if not next(trackedVehicles) then return end

  local cameraPos = core_camera and core_camera.getPosition() or nil
  local playerVeh = be:getPlayerVehicle(0)
  local playerVehPos = playerVeh and playerVeh:getPosition()

  -- Without both references there is no meaningful sleep/wake comparison.
  if not cameraPos and not playerVehPos then return end

  for _, state in pairs(trackedVehicles) do
    local veh = getObjectByID(state.vehId)
    if veh then
      veh = Sim.upcast(veh)
      local vehPos = gameplay_freeformDelivery_utils.getCachedVehiclePosition(veh)
      if vehPos then
        local cameraDistance = cameraPos and vehPos:distance(cameraPos) or math.huge
        local playerVehicleDistance = playerVehPos and vehPos:distance(playerVehPos) or math.huge
        state.cameraDistance = cameraDistance
        state.playerVehicleDistance = playerVehicleDistance

        local shouldSleep = cameraDistance > state.sleepDistance and playerVehicleDistance > state.sleepDistance
        local shouldWake = cameraDistance < state.wakeDistance or playerVehicleDistance < state.wakeDistance

        if state.sleeping then
          if shouldWake then
            veh:setActive(1)
            state.sleeping = false
          end
        elseif shouldSleep then
          veh:setActive(0)
          state.sleeping = true
        end
      end
    end
  end
end

function M.getDebugData()
  local result = {}
  for _, state in pairs(trackedVehicles) do
    table.insert(result, {
      id = state.deliveryVehicleId,
      sleeping = state.sleeping,
      sleepDistance = state.sleepDistance,
      wakeDistance = state.wakeDistance,
      cameraDistance = state.cameraDistance,
      playerVehicleDistance = state.playerVehicleDistance
    })
  end
  table.sort(result, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return result
end

function M.cleanup()
  for _, state in pairs(trackedVehicles) do
    local veh = getObjectByID(state.vehId)
    if veh then
      veh = Sim.upcast(veh)
      veh:setActive(1)
    end
  end
  trackedVehicles = {}
end

return M
