-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local validPermissionModes = {
  driver = true,
  passenger = true,
  unrestricted = true,
}

local function slotAllowsOccupants(slot)
  if slot.type == "seat_occupant" then return true end
  local allowTypes = slot.allowTypes
  if type(allowTypes) == "string" then return allowTypes == "seat_occupant" end
  for _, slotType in ipairs(allowTypes or {}) do
    if slotType == "seat_occupant" then return true end
  end
  return false
end

local function activePartsUseOccupantSystem(activePartsData)
  for _, part in pairs(activePartsData or {}) do
    for _, slot in ipairs(part.slots2 or part.slots or {}) do
      if slotAllowsOccupants(slot) then return true end
    end
  end
  return false
end

local function process(_, vehicle, activePartsData)
  local byId = {}
  for key, slot in pairs(vehicle.occupantSlots or {}) do
    local id = type(slot) == "table" and (slot.id or slot.name or key) or nil
    if id ~= nil then
      id = tostring(id)
      if byId[id] then
        log("E", "jbeam.occupantSlots", "Duplicate occupant slot id: " .. id)
      else
        slot.id = id
        if not validPermissionModes[slot.defaultPermissionMode] then
          if slot.defaultPermissionMode ~= nil then
            log("W", "jbeam.occupantSlots", string.format(
              "Invalid permission mode %q for occupant slot %q; inferring from its camera",
              tostring(slot.defaultPermissionMode),
              id
            ))
          end
          slot.defaultPermissionMode = slot.cameraName == "driver" and "driver" or "passenger"
        end
        if slot.seatSide ~= "left" and slot.seatSide ~= "right" and slot.seatSide ~= "center" then
          if slot.exitSide == "left" or slot.exitSide == "right" then
            slot.seatSide = slot.exitSide
          elseif slot.driverSide == "left" or slot.driverSide == "right" then
            slot.seatSide = slot.driverSide
          elseif id:match("L$") then
            slot.seatSide = "left"
          elseif id:match("R$") then
            slot.seatSide = "right"
          else
            slot.seatSide = "center"
          end
        end
        slot.cameraName = "occupant." .. id
        slot.entryTrigger = slot.entryTrigger or ("enterSeat_" .. id)
        slot.cargoGroup = slot.cargoGroup or (id .. "Occupant")
        if type(slot.actionMaps) == "string" then
          slot.actionMaps = {slot.actionMaps}
        elseif type(slot.actionMaps) ~= "table" then
          slot.actionMaps = {}
        end
        byId[id] = slot
      end
    end
  end
  vehicle.occupantSlotsById = byId
  if type(vehicle.occupantSystem) ~= "table" then
    vehicle.occupantSystem = {}
  end
  vehicle.occupantSystem.enabled = vehicle.occupantSystem.enabled == true
    or next(byId) ~= nil
    or activePartsUseOccupantSystem(activePartsData)
end

M.process = process

return M
