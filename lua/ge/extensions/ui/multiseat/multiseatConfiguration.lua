-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "core_playerPersonas",
}

local playerLimits = require("ge/extensions/core/multiseatPlayerLimits")

local MAX_PLAYERS = 64
local transaction
local revision = 0

M.AUTOMATIC_COLOR_DEFAULT = true

local function copyPersona(persona)
  return {
    id = persona.id,
    number = persona.number,
    displayName = persona.displayName,
    icon = persona.icon,
    color = deepcopy(persona.color),
    colorHex = persona.colorHex,
    vehicleFallbackPaint = deepcopy(persona.vehicleFallbackPaint),
    vehicle = deepcopy(persona.vehicle),
    preferences = deepcopy(persona.preferences),
  }
end

local function getVehicleSelection(veh)
  if not veh then return nil end
  return {
    model = veh.JBeam or veh.jbeam or veh:getField("JBeam", "0"),
    config = veh.partConfig or veh:getField("partConfig", "0"),
    automaticColor = settings.getValue("multiseatAutomaticColor", M.AUTOMATIC_COLOR_DEFAULT) == true,
  }
end

local function sortedPersonaNumbers()
  local numbers = {}
  for personaNumber in pairs(transaction.personas) do numbers[#numbers + 1] = personaNumber end
  table.sort(numbers)
  return numbers
end

local function getPlayerByPersona()
  local result = {}
  for player, personaNumber in ipairs(sortedPersonaNumbers()) do result[personaNumber] = player - 1 end
  return result
end

local function updatePersonaDisplayNames(playerByPersona)
  if transaction.platformManagesPlayers then
    local groupsById = {}
    for _, group in ipairs(transaction.deviceGroups) do groupsById[group.groupId] = group end
    for groupId, personaNumber in pairs(transaction.groupOwners) do
      local group = groupsById[groupId]
      local persona = transaction.personas[personaNumber]
      if group and persona then persona.displayName = group.label end
    end
    return
  end

  for personaNumber in pairs(playerByPersona) do
    local persona = transaction.personas[personaNumber]
    if persona and (persona.displayName == nil or persona.displayName == "") then
      persona.displayName = extensions.core_playerPersonas.getDefaultDisplayName(personaNumber)
    end
  end
end

-- the running gamemode's hard limit caps how many personas can exist
local function canAddPersona(personaNumber)
  if transaction.personas[personaNumber] then return true end
  local modeLimit = playerLimits.getCurrentModeLimit()
  return not modeLimit or tableSize(transaction.personas) < modeLimit
end

local function firstUnusedPersonaNumber()
  for personaNumber = 1, MAX_PLAYERS do
    if not transaction.personas[personaNumber] then
      return canAddPersona(personaNumber) and personaNumber or nil
    end
  end
end

local function firstUnusedPersonaNumberAfter(personaNumber)
  for candidate = personaNumber + 1, MAX_PLAYERS do
    if not transaction.personas[candidate] then
      return canAddPersona(candidate) and candidate or nil
    end
  end
end

local function ensurePersona(personaNumber)
  if not personaNumber then return nil end
  if not transaction.personas[personaNumber] then
    local persona = copyPersona(extensions.core_playerPersonas.preview(personaNumber))
    -- the first player keeps the vehicle that was already being driven
    if personaNumber == 1 and transaction.adoptVehicle then persona.vehicle = deepcopy(transaction.adoptVehicle) end
    transaction.personas[personaNumber] = persona
  end
  return transaction.personas[personaNumber]
end

local function personaHasOwner(personaNumber)
  for _, owner in pairs(transaction.manualOwners) do
    if owner == personaNumber then return true end
  end
  for _, owner in pairs(transaction.groupOwners) do
    if owner == personaNumber then return true end
  end
  return false
end

local function removeUnusedPersonas()
  for personaNumber in pairs(transaction.personas) do
    if not personaHasOwner(personaNumber) then transaction.personas[personaNumber] = nil end
  end
end

local function syncDeviceColorPreview()
  if not core_multiseat then return end
  if not transaction then
    core_multiseat.clearDeviceColors()
    return
  end
  core_multiseat.previewDeviceColors(M.getCommitConfiguration())
end

local function notifyChanged()
  revision = revision + 1
  transaction.revision = revision
  syncDeviceColorPreview()
  guihooks.trigger("MultiseatConfigurationChanged", revision)
end

local function endConfigurationEdit()
  if core_multiseat.endConfigurationEdit then
    core_multiseat.endConfigurationEdit(
      core_input_bindings and core_input_bindings.devices or nil,
      core_input_bindings and core_input_bindings.getAssignedPlayers() or nil
    )
  end
end

local function reconcileInventory()
  if not transaction then return end

  local previousManualGroups = {}
  for _, group in ipairs(transaction.manualGroups) do previousManualGroups[group.id] = group end
  local manualGroups = {}
  local seenManualIds = {}
  local devices = core_input_bindings and core_input_bindings.devices or {}
  for _, assignment in ipairs(core_multiseat.getDeviceAssignmentsFor(devices, {})) do
    seenManualIds[assignment.id] = true
    if not transaction.removedManualGroups[assignment.id] then
      local live = deepcopy(assignment)
      local previous = previousManualGroups[assignment.id]
      if previous and transaction.manualOwners[assignment.id] ~= nil then
        local liveDeviceIds = tableValuesAsLookupDict(live.deviceIds)
        for _, deviceId in ipairs(previous.deviceIds or {}) do
          if not liveDeviceIds[deviceId] then live.deviceIds[#live.deviceIds + 1] = deviceId end
        end
        local liveMetadataIds = {}
        for _, metadata in ipairs(live.deviceMetadata or {}) do liveMetadataIds[metadata.id] = true end
        for _, metadata in ipairs(previous.deviceMetadata or {}) do
          if metadata.id and not liveMetadataIds[metadata.id] then
            live.deviceMetadata[#live.deviceMetadata + 1] = deepcopy(metadata)
          end
        end
      end
      manualGroups[#manualGroups + 1] = live
    end
  end
  for groupId, group in pairs(previousManualGroups) do
    if not seenManualIds[groupId]
      and not transaction.removedManualGroups[groupId]
      and transaction.manualOwners[groupId] ~= nil
    then
      local missing = deepcopy(group)
      missing.connected = false
      manualGroups[#manualGroups + 1] = missing
    end
  end
  table.sort(manualGroups, function(a, b)
    if (a.id == "keyboard-mouse") ~= (b.id == "keyboard-mouse") then return a.id == "keyboard-mouse" end
    return tostring(a.id) < tostring(b.id)
  end)
  transaction.manualGroups = manualGroups

  local previousDeviceGroups = {}
  for _, group in ipairs(transaction.deviceGroups) do previousDeviceGroups[group.groupId] = group end
  local deviceGroups = {}
  local liveGroupIds = {}
  for _, group in ipairs(core_multiseat.getDeviceGroupsFor(devices, {})) do
    liveGroupIds[group.groupId] = true
    deviceGroups[#deviceGroups + 1] = {
      id = group.id,
      groupId = group.groupId,
      label = group.label,
      devices = deepcopy(group.devices),
      connected = true,
    }
  end
  for groupId, group in pairs(previousDeviceGroups) do
    if not liveGroupIds[groupId] and transaction.groupOwners[groupId] ~= nil then
      local missing = deepcopy(group)
      missing.connected = false
      for _, device in ipairs(missing.devices or {}) do device.connected = false end
      deviceGroups[#deviceGroups + 1] = missing
    end
  end
  table.sort(deviceGroups, function(a, b) return a.groupId < b.groupId end)
  transaction.deviceGroups = deviceGroups
  removeUnusedPersonas()
  local signatureParts = {}
  for _, group in ipairs(manualGroups) do
    signatureParts[#signatureParts + 1] = "m:" .. group.id .. "=" .. table.concat(group.deviceIds, ",") .. "@" .. tostring(group.connected)
  end
  for _, group in ipairs(deviceGroups) do
    local deviceIds = {}
    for _, device in ipairs(group.devices) do deviceIds[#deviceIds + 1] = device.id end
    signatureParts[#signatureParts + 1] = "g:" .. tostring(group.groupId) .. "="
      .. table.concat(deviceIds, ",") .. "@" .. tostring(group.connected)
  end
  local signature = table.concat(signatureParts, ";")
  local changed = transaction.inventorySignature ~= nil and transaction.inventorySignature ~= signature
  transaction.inventorySignature = signature
  return changed
end

local function seedFromLive()
  local participantsByPlayer = {}
  for _, participant in ipairs(core_multiseat.getJoinedParticipants()) do
    local player = participant.assignment.playerIndex
    participantsByPlayer[player] = participant
    transaction.personas[participant.persona.number] = copyPersona(participant.persona)
  end

  if transaction.platformManagesPlayers then
    local groups = core_multiseat.getDeviceGroups()
    transaction.deviceGroups = deepcopy(groups)
    for _, group in ipairs(groups) do
      local participant = participantsByPlayer[group.playerIndex]
      if participant then transaction.groupOwners[group.groupId] = participant.persona.number end
    end
  else
    transaction.manualGroups = deepcopy(core_multiseat.getDeviceAssignments())
    for _, assignment in ipairs(transaction.manualGroups) do
      local participant = participantsByPlayer[assignment.playerIndex]
      if participant then transaction.manualOwners[assignment.id] = participant.persona.number end
    end
  end
  removeUnusedPersonas()
end

local function seedAdoptVehicle()
  local currentVehicle = getPlayerVehicle(0)
  if not currentVehicle or currentVehicle:getJBeamFilename() == "unicycle" then return end
  transaction.adoptVehicleId = currentVehicle:getId()
  transaction.adoptVehicle = getVehicleSelection(currentVehicle)
end

local function seedFromCachedAssignments()
  if not core_multiseat.getCachedPlayerAssignments then
    log("I", "multiseatAssignmentCache", "seed skipped: core cache API unavailable")
    return false
  end
  local cached = core_multiseat.getCachedPlayerAssignments()
  local inventory = {}
  if transaction.platformManagesPlayers then
    for _, group in ipairs(transaction.deviceGroups) do inventory[#inventory + 1] = tostring(group.groupId) end
  else
    for _, group in ipairs(transaction.manualGroups) do
      inventory[#inventory + 1] = tostring(group.id) .. "[" .. table.concat(group.deviceIds, ",") .. "]"
    end
  end
  log("I", "multiseatAssignmentCache", "seed requested: platformMode="
    .. tostring(transaction.platformManagesPlayers) .. " inventory=" .. table.concat(inventory, ";")
    .. " cached=" .. dumps(cached))
  if type(cached) ~= "table"
    or (cached.platformManagesPlayers == true) ~= (transaction.platformManagesPlayers == true)
  then
    log("I", "multiseatAssignmentCache", "seed skipped: cache missing or platform mode changed")
    return false
  end

  local seeded = false
  if transaction.platformManagesPlayers then
    for _, group in ipairs(transaction.deviceGroups) do
      local personaNumber = tonumber(cached.groupOwners and cached.groupOwners[group.groupId])
      if personaNumber and personaNumber >= 1 and personaNumber <= MAX_PLAYERS and not personaHasOwner(personaNumber) and canAddPersona(personaNumber) then
        ensurePersona(personaNumber)
        transaction.groupOwners[group.groupId] = personaNumber
        seeded = true
      end
    end
  else
    for _, group in ipairs(transaction.manualGroups) do
      local personaNumber
      for _, deviceId in ipairs(group.deviceIds) do
        personaNumber = tonumber(cached.manualOwnersByDevice and cached.manualOwnersByDevice[deviceId])
        if personaNumber then break end
      end
      if personaNumber and personaNumber >= 1 and personaNumber <= MAX_PLAYERS and canAddPersona(personaNumber) then
        ensurePersona(personaNumber)
        transaction.manualOwners[group.id] = personaNumber
        seeded = true
      end
    end
  end
  log("I", "multiseatAssignmentCache", "seed applied: manualOwners="
    .. dumps(transaction.manualOwners) .. " groupOwners=" .. dumps(transaction.groupOwners))
  return seeded
end

local function ensureSessionBaseline()
  if not transaction or transaction.sessionOwners then return end
  transaction.sessionOwners = deepcopy(transaction.manualOwners)
  transaction.sessionGroupOwners = deepcopy(transaction.groupOwners)
  transaction.sessionRemoved = deepcopy(transaction.removedManualGroups)
end

function M.begin(options)
  if transaction then
    reconcileInventory()
    ensureSessionBaseline()
    return M.getPreview()
  end

  options = options or {}
  if core_multiseat.beginConfigurationEdit then core_multiseat.beginConfigurationEdit() end
  transaction = {
    platformManagesPlayers = core_multiseat.isPlatformManagingPlayers() == true,
    manualOwners = {},
    removedManualGroups = {},
    groupOwners = {},
    personas = {},
    manualGroups = {},
    deviceGroups = {},
    source = options.source,
    revision = revision,
    baseline = core_multiseat.exportConfiguration and core_multiseat.exportConfiguration() or nil,
  }
  reconcileInventory()
  if transaction.baseline and transaction.baseline.enabled then
    log("I", "multiseatAssignmentCache", "configuration begin: seeding active assignments")
    seedFromLive()
  else
    log("I", "multiseatAssignmentCache", "configuration begin: seeding cached assignments")
    seedAdoptVehicle()
    transaction.seededFromCache = seedFromCachedAssignments()
  end
  ensureSessionBaseline()
  notifyChanged()
  return M.getPreview()
end

function M.isActive()
  return transaction ~= nil
end

function M.discard()
  if not transaction then return false end
  if transaction.committed and transaction.baseline then
    core_multiseat.restoreConfiguration(transaction.baseline)
  end
  transaction = nil
  endConfigurationEdit()
  revision = revision + 1
  syncDeviceColorPreview()
  guihooks.trigger("MultiseatConfigurationChanged", revision)
  return true
end

local function findManualGroup(deviceId)
  for _, group in ipairs(transaction.manualGroups) do
    if group.id == deviceId or group.primaryDeviceId == deviceId then return group end
    for _, id in ipairs(group.deviceIds) do
      if id == deviceId then return group end
    end
  end
end

local function countManualOwners(personaNumber)
  local count = 0
  for _, owner in pairs(transaction.manualOwners) do
    if owner == personaNumber then count = count + 1 end
  end
  return count
end

function M.toggleDevicePlayer(deviceId)
  if not transaction or transaction.platformManagesPlayers then return false end
  reconcileInventory()
  local selected = findManualGroup(deviceId)
  if not selected then return false end

  local currentPersona = transaction.manualOwners[selected.id]
  if currentPersona then
    transaction.manualOwners[selected.id] = nil
    removeUnusedPersonas()
  else
    local personaNumber = firstUnusedPersonaNumber()
    if not personaNumber then return false end
    ensurePersona(personaNumber)
    transaction.manualOwners[selected.id] = personaNumber
  end
  notifyChanged()
  return true
end

-- personaNumber 1..MAX_PLAYERS assigns the device to that player, nil or 0 unassigns it
function M.setDevicePlayer(deviceId, personaNumber)
  if not transaction or transaction.platformManagesPlayers then return false end
  reconcileInventory()
  local selected = findManualGroup(deviceId)
  if not selected then return false end

  personaNumber = tonumber(personaNumber)
  if personaNumber == 0 then personaNumber = nil end
  if personaNumber and (personaNumber < 1 or personaNumber > MAX_PLAYERS) then return false end
  if personaNumber and not canAddPersona(personaNumber) then return false end
  if transaction.manualOwners[selected.id] == personaNumber then return false end

  if personaNumber then ensurePersona(personaNumber) end
  transaction.manualOwners[selected.id] = personaNumber
  removeUnusedPersonas()
  notifyChanged()
  return true
end

function M.removeDevice(deviceId)
  if not transaction or transaction.platformManagesPlayers then return false end
  reconcileInventory()
  local selected = findManualGroup(deviceId)
  if not selected or selected.connected ~= false then return false end

  transaction.removedManualGroups[selected.id] = true
  transaction.manualOwners[selected.id] = nil
  for index, group in ipairs(transaction.manualGroups) do
    if group.id == selected.id then
      table.remove(transaction.manualGroups, index)
      break
    end
  end
  removeUnusedPersonas()
  notifyChanged()
  return true
end

function M.moveDevicePlayer(deviceId, direction)
  if not transaction or transaction.platformManagesPlayers then return false end
  direction = tonumber(direction)
  if direction ~= -1 and direction ~= 1 then return false end
  reconcileInventory()
  local selected = findManualGroup(deviceId)
  if not selected then return false end

  local currentPersona = transaction.manualOwners[selected.id]
  if direction < 0 then
    if not currentPersona then return false end
    local previousPersona
    for _, personaNumber in ipairs(sortedPersonaNumbers()) do
      if personaNumber == currentPersona then break end
      previousPersona = personaNumber
    end
    transaction.manualOwners[selected.id] = previousPersona
    removeUnusedPersonas()
  else
    local targetPersona
    if currentPersona then
      local currentFound = false
      for _, personaNumber in ipairs(sortedPersonaNumbers()) do
        if currentFound then
          targetPersona = personaNumber
          break
        end
        currentFound = personaNumber == currentPersona
      end
      if not targetPersona then
        if countManualOwners(currentPersona) <= 1 then return false end
        targetPersona = firstUnusedPersonaNumberAfter(currentPersona)
        if not targetPersona then return false end
        ensurePersona(targetPersona)
      end
    else
      targetPersona = sortedPersonaNumbers()[1]
      if not targetPersona then
        targetPersona = firstUnusedPersonaNumber()
        if not targetPersona then return false end
        ensurePersona(targetPersona)
      end
    end
    transaction.manualOwners[selected.id] = targetPersona
    removeUnusedPersonas()
  end
  notifyChanged()
  return true
end

function M.cycleDevicePlayer(deviceId)
  if not transaction or transaction.platformManagesPlayers then return false end
  reconcileInventory()
  local selected = findManualGroup(deviceId)
  if not selected then return false end

  local currentPersona = transaction.manualOwners[selected.id]
  if not currentPersona then
    local personaNumber = firstUnusedPersonaNumber()
    if not personaNumber then return false end
    ensurePersona(personaNumber)
    transaction.manualOwners[selected.id] = personaNumber
  else
    local previousPersona
    for _, personaNumber in ipairs(sortedPersonaNumbers()) do
      if personaNumber == currentPersona then break end
      previousPersona = personaNumber
    end
    transaction.manualOwners[selected.id] = previousPersona
    removeUnusedPersonas()
  end
  notifyChanged()
  return true
end

function M.joinDeviceGroup(groupId)
  if not transaction or not transaction.platformManagesPlayers then return false end
  reconcileInventory()
  groupId = tonumber(groupId)
  if groupId == nil or transaction.groupOwners[groupId] then return false end
  local personaNumber = groupId
  if personaNumber < 1 or personaNumber > MAX_PLAYERS or transaction.personas[personaNumber] then
    personaNumber = firstUnusedPersonaNumber()
  end
  if not personaNumber or not canAddPersona(personaNumber) then return false end
  ensurePersona(personaNumber)
  transaction.groupOwners[groupId] = personaNumber
  notifyChanged()
  return true
end

function M.leavePlayer(player)
  if not transaction then return false end
  local playerByPersona = getPlayerByPersona()
  local personaNumber
  for candidate, candidatePlayer in pairs(playerByPersona) do
    if candidatePlayer == tonumber(player) then personaNumber = candidate; break end
  end
  if not personaNumber then return false end
  for id, owner in pairs(transaction.manualOwners) do
    if owner == personaNumber then transaction.manualOwners[id] = nil end
  end
  for id, owner in pairs(transaction.groupOwners) do
    if owner == personaNumber then transaction.groupOwners[id] = nil end
  end
  transaction.personas[personaNumber] = nil
  notifyChanged()
  return true
end

function M.setPersonaData(personaNumber, data, emitChange)
  if not transaction or type(data) ~= "table" then return false end
  local persona = transaction.personas[tonumber(personaNumber)]
  if not persona then return false end
  for key, value in pairs(data) do persona[key] = deepcopy(value) end
  if emitChange ~= false then notifyChanged() end
  return true
end

function M.getPersona(personaNumber)
  if not transaction then return nil end
  local persona = transaction.personas[tonumber(personaNumber)]
  return persona and deepcopy(persona) or nil
end

function M.getPreview()
  if not transaction then M.begin() end
  reconcileInventory()
  local playerByPersona = getPlayerByPersona()
  updatePersonaDisplayNames(playerByPersona)
  local availablePlayers = {}
  local deviceGroups = {}

  if transaction.platformManagesPlayers then
    for _, group in ipairs(transaction.deviceGroups) do
      local owner = transaction.groupOwners[group.groupId]
      local data = deepcopy(group)
      data.playerIndex = owner and playerByPersona[owner] or -1
      deviceGroups[#deviceGroups + 1] = data
    end
  else
    for _, group in ipairs(transaction.manualGroups) do
      local owner = transaction.manualOwners[group.id]
      local player = owner and playerByPersona[owner] or -1
      local persona = owner and transaction.personas[owner]
      availablePlayers[#availablePlayers + 1] = {
        id = "local-device:" .. group.id,
        player = player,
        label = group.deviceLabel or group.id,
        icon = group.inputIcon,
        deviceId = group.primaryDeviceId or group.id,
        deviceIds = deepcopy(group.deviceIds),
        deviceLabel = group.deviceLabel,
        connected = group.connected ~= false,
        optedIn = player >= 0,
        color = persona and persona.colorHex or nil,
        joinDisabled = false,
      }
    end
  end

  local availablePersonas = {}
  for _, personaNumber in ipairs(sortedPersonaNumbers()) do
    local persona = transaction.personas[personaNumber]
    availablePersonas[#availablePersonas + 1] = {
      id = persona.id,
      number = persona.number,
      player = playerByPersona[personaNumber],
      label = persona.displayName,
      icon = persona.icon,
      color = persona.colorHex,
      optedIn = true,
      joinDisabled = false,
    }
  end

  local count = #availablePersonas
  return {
    availablePlayers = availablePlayers,
    availablePersonas = availablePersonas,
    -- how many players can be assigned at all, regardless of what the current content recommends
    maxPlayers = MAX_PLAYERS,
    joinedPersonas = deepcopy(availablePersonas),
    deviceGroups = deviceGroups,
    platformManagesPlayers = transaction.platformManagesPlayers,
    playerLimit = {
      limit = MAX_PLAYERS,
      hard = transaction.platformManagesPlayers,
      atLimit = count >= MAX_PLAYERS,
      exceeded = count > MAX_PLAYERS,
    },
    revision = transaction.revision,
  }
end

function M.getPlayers()
  local players = {}
  if not transaction then return players end
  for player = 0, #sortedPersonaNumbers() - 1 do players[#players + 1] = player end
  return players
end

function M.getCommitConfiguration()
  if not transaction then return nil end
  reconcileInventory()
  local playerByPersona = getPlayerByPersona()
  updatePersonaDisplayNames(playerByPersona)
  local manualAssignments = {}
  local manualDeviceMetadata = {}
  for _, group in ipairs(transaction.manualGroups) do
    local owner = transaction.manualOwners[group.id]
    local player = owner and playerByPersona[owner] or -1
    for _, deviceId in ipairs(group.deviceIds) do manualAssignments[deviceId] = player end
    for _, metadata in ipairs(group.deviceMetadata or {}) do
      if metadata.id then manualDeviceMetadata[metadata.id] = deepcopy(metadata) end
    end
  end
  local groupAssignments = {}
  for groupId, owner in pairs(transaction.groupOwners) do
    groupAssignments[groupId] = playerByPersona[owner]
  end
  local participants = {}
  for _, personaNumber in ipairs(sortedPersonaNumbers()) do
    participants[#participants + 1] = {
      playerIndex = playerByPersona[personaNumber],
      personaNumber = personaNumber,
      persona = deepcopy(transaction.personas[personaNumber]),
    }
  end
  return {
    platformManagesPlayers = transaction.platformManagesPlayers,
    personaOptInMode = transaction.platformManagesPlayers,
    manualAssignments = manualAssignments,
    manualDeviceMetadata = manualDeviceMetadata,
    groupAssignments = groupAssignments,
    platformDeviceGroups = deepcopy(transaction.deviceGroups),
    participants = participants,
    adoptVehicleId = transaction.adoptVehicleId,
  }
end

local function assignmentsEqual(a, b, keys)
  for key in pairs(keys or {}) do
    if (tonumber(a[key]) or -1) ~= (tonumber(b[key]) or -1) then return false end
  end
  for key in pairs(a or {}) do
    if (tonumber(a[key]) or -1) ~= (tonumber(b[key]) or -1) then return false end
  end
  return true
end

local function valuesEqual(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for key, value in pairs(a) do
    if not valuesEqual(value, b[key]) then return false end
  end
  for key in pairs(b) do
    if a[key] == nil then return false end
  end
  return true
end

local function buildChangeLog(config)
  local baseline = transaction.baseline or {}
  local changes = {
    enabled = baseline.enabled ~= true and {from = baseline.enabled == true, to = true} or nil,
    roster = {
      added = {},
      removed = {},
      playerIdChanged = {},
    },
    personas = {},
    deviceAssignments = {},
    deviceGroups = {},
  }

  local beforeByPersona = {}
  for _, entry in ipairs(baseline.joinedPlayers or {}) do
    beforeByPersona[entry.personaNumber] = {
      playerIndex = entry.playerIndex,
      persona = extensions.core_playerPersonas.get(entry.personaNumber),
    }
  end
  local afterByPersona = {}
  for _, participant in ipairs(config.participants) do
    afterByPersona[participant.personaNumber] = participant
    local before = beforeByPersona[participant.personaNumber]
    if not before then
      changes.roster.added[#changes.roster.added + 1] = {
        personaNumber = participant.personaNumber,
        playerIndex = participant.playerIndex,
      }
    else
      if before.playerIndex ~= participant.playerIndex then
        changes.roster.playerIdChanged[#changes.roster.playerIdChanged + 1] = {
          personaNumber = participant.personaNumber,
          from = before.playerIndex,
          to = participant.playerIndex,
        }
      end
      local changedFields = {}
      for _, field in ipairs({"id", "displayName", "icon", "color", "vehicle"}) do
        if not valuesEqual(before.persona and before.persona[field], participant.persona[field]) then
          changedFields[#changedFields + 1] = field
        end
      end
      if #changedFields > 0 then
        changes.personas[#changes.personas + 1] = {
          personaNumber = participant.personaNumber,
          fields = changedFields,
        }
      end
    end
  end
  for personaNumber, before in pairs(beforeByPersona) do
    if not afterByPersona[personaNumber] then
      changes.roster.removed[#changes.roster.removed + 1] = {
        personaNumber = personaNumber,
        playerIndex = before.playerIndex,
      }
    end
  end

  if not config.platformManagesPlayers then
    local assignmentKeys = {}
    for deviceId in pairs(baseline.manuallyAssignedPlayers or {}) do assignmentKeys[deviceId] = true end
    for deviceId in pairs(config.manualAssignments or {}) do assignmentKeys[deviceId] = true end
    for deviceId in pairs(assignmentKeys) do
      local before = tonumber(baseline.manuallyAssignedPlayers and baseline.manuallyAssignedPlayers[deviceId]) or -1
      local after = tonumber(config.manualAssignments and config.manualAssignments[deviceId]) or -1
      if before ~= after then
        changes.deviceAssignments[#changes.deviceAssignments + 1] = {
          deviceId = deviceId,
          from = before,
          to = after,
        }
      end
    end
  else
    local groupKeys = {}
    for groupId in pairs(baseline.platformDeviceGroupPlayers or {}) do groupKeys[groupId] = true end
    for groupId in pairs(config.groupAssignments or {}) do groupKeys[groupId] = true end
    for groupId in pairs(groupKeys) do
      local before = tonumber(baseline.platformDeviceGroupPlayers and baseline.platformDeviceGroupPlayers[groupId]) or -1
      local after = tonumber(config.groupAssignments and config.groupAssignments[groupId]) or -1
      if before ~= after then
        changes.deviceGroups[#changes.deviceGroups + 1] = {
          groupId = groupId,
          from = before,
          to = after,
        }
      end
    end
  end
  return changes
end

function M.hasUserChanges()
  if not transaction then return false end
  ensureSessionBaseline()
  return transaction.seededFromCache == true
    or not valuesEqual(transaction.manualOwners, transaction.sessionOwners)
    or not valuesEqual(transaction.groupOwners, transaction.sessionGroupOwners)
    or not valuesEqual(transaction.removedManualGroups, transaction.sessionRemoved)
end

function M.clearCachedAssignments()
  if not transaction or transaction.baseline and transaction.baseline.enabled then return false end
  if not core_multiseat.cachePlayerAssignments then return false end
  return core_multiseat.cachePlayerAssignments({
    platformManagesPlayers = transaction.platformManagesPlayers,
    participants = {},
    manualAssignments = {},
    groupAssignments = {},
  })
end

function M.hasChanges()
  if not transaction then return false end
  local config = M.getCommitConfiguration()
  local baseline = transaction.baseline
  if not baseline or not baseline.enabled then return true end
  if #config.participants ~= #(baseline.joinedPlayers or {}) then return true end
  local baselineByPersona = {}
  for _, entry in ipairs(baseline.joinedPlayers or {}) do
    baselineByPersona[entry.personaNumber] = entry.playerIndex
  end
  for _, participant in ipairs(config.participants) do
    if baselineByPersona[participant.personaNumber] ~= participant.playerIndex then return true end
  end
  if config.platformManagesPlayers then
    return not assignmentsEqual(
      config.groupAssignments,
      baseline.platformDeviceGroupPlayers or {},
      baseline.platformDeviceGroupPlayers or {}
    )
  end
  local deviceKeys = {}
  for devname in pairs(config.manualAssignments) do deviceKeys[devname] = true end
  for devname in pairs(baseline.manuallyAssignedPlayers or {}) do deviceKeys[devname] = true end
  return not assignmentsEqual(config.manualAssignments, baseline.manuallyAssignedPlayers or {}, deviceKeys)
end

function M.commitCore()
  local config = M.getCommitConfiguration()
  if not config or #config.participants == 0 then return false, "no_players" end
  local changeLog = buildChangeLog(config)
  config.deferParticipantNotification = true
  local success, reason = core_multiseat.applyConfiguration(config)
  if not success then return false, reason end
  transaction.committed = true
  transaction.committedConfig = config
  transaction.changeLog = changeLog
  return true, config
end

function M.completeCommit()
  if not transaction or not transaction.committed then return false end
  local changeLog = transaction.changeLog
  if core_multiseat.finalizeConfiguration then core_multiseat.finalizeConfiguration() end
  transaction = nil
  endConfigurationEdit()
  revision = revision + 1
  syncDeviceColorPreview()
  guihooks.trigger("MultiseatConfigurationChanged", revision)
  log("I", "multiseatConfiguration", "Applied configuration changes: " .. dumps(changeLog or {}))
  return true
end

function M.rollbackCommit()
  if not transaction or not transaction.committed or not transaction.baseline then return false end
  local restored = core_multiseat.restoreConfiguration(transaction.baseline)
  transaction.committed = false
  transaction.committedConfig = nil
  transaction.changeLog = nil
  return restored
end

function M.commit()
  local success, configOrReason = M.commitCore()
  if not success then return false, configOrReason end
  M.completeCommit()
  return true, configOrReason
end

function M.onClientEndMission()
  transaction = nil
  endConfigurationEdit()
  syncDeviceColorPreview()
end

function M.onInputBindingsChanged()
  if transaction and reconcileInventory() then notifyChanged() end
end

return M
