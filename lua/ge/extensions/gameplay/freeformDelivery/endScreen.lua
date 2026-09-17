-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "freeformDelivery_endScreen"

function M.collectStatistics(delivery, startTime)
  if not delivery then
    log('E', logTag, 'No delivery provided')
    return nil
  end

  if not startTime or startTime == 0 then
    log('E', logTag, 'Invalid start time')
    return nil
  end

  local currentTime = os.clock()
  local elapsedTime = currentTime - startTime

  local progress = gameplay_freeformDelivery_goals.getProgress()
  if not progress then
    log('E', logTag, 'Failed to get progress')
    return nil
  end

  -- Collect vehicle damage statistics
  local vehicleDamages = {}
  local mapObjects = map and map.objects
  for _, vehicle in ipairs(delivery.vehicles or {}) do
    local veh = gameplay_freeformDelivery_utils.getVehicleObjectByDeliveryId(vehicle.id)
    if veh and mapObjects then
      local vehId = veh.id or (veh.getId and veh:getId())
      local vehData = vehId and mapObjects[vehId]
      if vehData then
        vehicleDamages[vehicle.id] = {
          name = vehicle.name or vehicle.id,
          damage = vehData.damage
        }
      end
    end
  end

  -- Build statistics object
  local stats = {
    time = elapsedTime,
    timeStr = gameplay_freeformDelivery_utils.formatTime(elapsedTime),
    goalsTotal = progress.total,
    goalsCompleted = progress.completed,
    goalsRequired = progress.required,
    goalsRequiredCompleted = progress.requiredCompleted,
    vehicleDamages = vehicleDamages,
    allRequiredComplete = progress.allRequiredComplete
  }

  return stats
end

return M
