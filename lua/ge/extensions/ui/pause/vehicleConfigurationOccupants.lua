-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "gameplay_seatOccupants",
  "core_multiseat",
  "core_playerPersonas",
  "core_vehicle_configTarget",
  "core_vehicle_manager",
}

local defaultWeight = 89
local sessionVehicleId
local occupantsEnabled = true
local occupantTabActive = false

local function configuredVehicleId()
  return sessionVehicleId
    or (core_vehicle_configTarget and core_vehicle_configTarget.resolveVehicleId())
end

local function colorHex(color)
  if type(color) ~= "table" then return nil end
  return string.format(
    "#%02X%02X%02X",
    math.floor((color[1] or 0) * 255 + 0.5),
    math.floor((color[2] or 0) * 255 + 0.5),
    math.floor((color[3] or 0) * 255 + 0.5)
  )
end

local function collectPlayers()
  local playersById = {}
  local participants = core_multiseat and core_multiseat.getParticipants
    and core_multiseat.getParticipants() or {}
  local multiseatActive = (core_multiseat and core_multiseat.isMultiseatActive
      and core_multiseat.isMultiseatActive())
    or #participants > 1

  if multiseatActive then
    for _, participant in ipairs(participants) do
      local player = tonumber(participant.assignment and participant.assignment.playerIndex)
      if player ~= nil then
        local persona = participant.persona or {}
        playersById[player] = {
          id = player,
          label = persona.displayName,
          color = colorHex(persona.color),
          icon = persona.icon,
        }
      end
    end
  end

  if not playersById[0] then
    local persona = core_playerPersonas.get(1)
    if not multiseatActive then core_playerPersonas.applySoloColor(persona) end
    playersById[0] = {
      id = 0,
      color = persona and colorHex(persona.color) or nil,
    }
  end
  local players = {}
  for _, player in pairs(playersById) do players[#players + 1] = player end
  table.sort(players, function(a, b) return a.id < b.id end)
  return players, multiseatActive
end

local function applySessionOverride()
  if not sessionVehicleId or not gameplay_seatOccupants then return end
  gameplay_seatOccupants.setVehicleOccupantsEnabledOverride(
    sessionVehicleId,
    occupantTabActive or occupantsEnabled
  )
end

local function notifyChanged()
  guihooks.trigger("VehicleConfigOccupantsStateChanged")
end

local function seatById(vehId, seatId)
  for _, seat in ipairs(gameplay_seatOccupants.getSeats(vehId) or {}) do
    if seat.seatId == seatId then return seat end
  end
end

local function collectVehiclePartPaths(vehId)
  local result = {}
  local vehData = core_vehicle_manager.getVehicleData(vehId)
  local function walk(node)
    if not node then return end
    if node.partPath then result[node.partPath] = true end
    for _, child in pairs(node.children or {}) do walk(child) end
  end
  walk(vehData and vehData.config and vehData.config.partsTree)
  return result
end

function M.getState()
  local vehId = configuredVehicleId()
  if not vehId or not scenetree.findObjectById(vehId) then
    return {vehicleId = nil, seats = {}, players = {}}
  end
  local players, multiseatActive = collectPlayers()
  return {
    vehicleId = vehId,
    seats = gameplay_seatOccupants.getSeats(vehId) or {},
    players = players,
    multiseatActive = multiseatActive,
    vehiclePartPaths = collectVehiclePartPaths(vehId),
    enabledWhileConfiguring = occupantsEnabled,
  }
end

function M.beginSession(enabled)
  local nextVehicleId = configuredVehicleId()
  if sessionVehicleId and sessionVehicleId ~= nextVehicleId then
    gameplay_seatOccupants.setVehicleOccupantsEnabledOverride(sessionVehicleId, nil)
  end
  sessionVehicleId = nextVehicleId
  occupantsEnabled = enabled ~= false
  applySessionOverride()
  return M.getState()
end

function M.endSession()
  if sessionVehicleId and gameplay_seatOccupants then
    gameplay_seatOccupants.setVehicleOccupantsEnabledOverride(sessionVehicleId, nil)
  end
  sessionVehicleId = nil
  occupantTabActive = false
end

function M.setEnabledWhileConfiguring(enabled)
  occupantsEnabled = enabled ~= false
  applySessionOverride()
  return occupantsEnabled
end

function M.setOccupantTabActive(active)
  occupantTabActive = active == true
  applySessionOverride()
end

function M.setSeatOccupant(seatId, occupant)
  local vehId = configuredVehicleId()
  seatId = tostring(seatId or "")
  occupant = tostring(occupant or "")
  local seat = vehId and seatById(vehId, seatId)
  if not seat then return {success = false, reason = "seatMissing"} end

  if occupant == "empty" then
    gameplay_seatOccupants.clearOccupied(vehId, seatId)
    notifyChanged()
    return {success = true}
  end

  if occupant == "dummy" then
    if seat.occupied and seat.occupantType ~= "dummy" then
      gameplay_seatOccupants.clearOccupied(vehId, seatId)
    end
    local success, reason = gameplay_seatOccupants.setDummyOccupant(
      vehId,
      seatId,
      tonumber(seat.weight) or defaultWeight
    )
    notifyChanged()
    return {success = success == true, reason = reason}
  end

  local player = tonumber(occupant:match("^player:(%d+)$"))
  if player == nil then return {success = false, reason = "invalidOccupant"} end
  if seat.occupantType == "player" and seat.player == player then
    return {success = true}
  end
  if seat.occupied then gameplay_seatOccupants.clearOccupied(vehId, seatId) end
  if not gameplay_seatOccupants.requestEnterSeat(vehId, seatId, player) then
    notifyChanged()
    return {success = false, reason = "enterFailed"}
  end
  local success = gameplay_seatOccupants.setOccupied(
    vehId,
    seatId,
    player,
    tonumber(seat.weight) or defaultWeight
  )
  notifyChanged()
  return {success = success == true, reason = success and nil or "occupied"}
end

function M.unseatAll()
  local vehId = configuredVehicleId()
  if not vehId then return false end
  gameplay_seatOccupants.clearOccupied(vehId)
  notifyChanged()
  return true
end

function M.fillEmptySeatsWithDummies()
  local vehId = configuredVehicleId()
  if not vehId then return 0 end
  local added = 0
  for _, seat in ipairs(gameplay_seatOccupants.getSeats(vehId) or {}) do
    if not seat.occupied then
      local success = gameplay_seatOccupants.setDummyOccupant(vehId, seat.seatId, defaultWeight)
      if success then added = added + 1 end
    end
  end
  notifyChanged()
  return added
end

function M.removeAllDummies()
  local vehId = configuredVehicleId()
  if not vehId then return 0 end
  local removed = gameplay_seatOccupants.clearDummyOccupants(vehId)
  notifyChanged()
  return removed
end

function M.onSeatOccupantEnter(_, vehId)
  if vehId == sessionVehicleId then notifyChanged() end
end

function M.onSeatOccupantExit(_, vehId)
  if vehId == sessionVehicleId then notifyChanged() end
end

function M.onLocalParticipantsChanged()
  if sessionVehicleId then notifyChanged() end
end

function M.onVehicleSpawned(vehId)
  if vehId == sessionVehicleId then
    applySessionOverride()
    notifyChanged()
  end
end

M.onVehicleReplaced = M.onVehicleSpawned
M.onVehicleResetted = M.onVehicleSpawned

function M.onVehicleDestroyed(vehId)
  if vehId ~= sessionVehicleId then return end
  sessionVehicleId = nil
  notifyChanged()
end

function M.onVehicleConfigTargetChanged()
  if not sessionVehicleId then return end
  local previousVehicleId = sessionVehicleId
  local nextVehicleId = core_vehicle_configTarget and core_vehicle_configTarget.resolveVehicleId()
  if previousVehicleId == nextVehicleId then return end
  gameplay_seatOccupants.setVehicleOccupantsEnabledOverride(previousVehicleId, nil)
  sessionVehicleId = nextVehicleId
  applySessionOverride()
  notifyChanged()
end

function M.onExtensionUnloaded()
  M.endSession()
end

return M
