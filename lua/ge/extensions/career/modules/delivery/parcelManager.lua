-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local ffi = require('ffi')
M.dependencies = {"freeroam_facilities", "career_modules_delivery_general"}

local cargoLocationsChangedThisFrame = false

local allCargo = {}
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dTasklist
M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dProgress = career_modules_delivery_progress
  dTasklist = career_modules_delivery_tasklist
end

local allVehiclesWithCargo = {}

local transientMoves = {}


local function norm(value, min, max)
  return (value - min) / (max - min);
end


-----------------------------------
-- Adding/Moving Cargo functions --
-----------------------------------

local function addCargo(cargo, silent)
  table.insert(allCargo, cargo)
  if not silent then
    extensions.hook("onCargoGenerated", cargo)
  end
end

local function changeCargoLocation(cargoId, newLocation)
  cargoLocationsChangedThisFrame = true
  if not newLocation or not next(newLocation) then
    log("E","","Trying to set location to nil or empty! " .. dumps(cargoId) .. " -> ".. dumps(newLocation))
  end
  for _, cargo in ipairs(allCargo) do
    if cargo.id == cargoId then
      --log("I", "", cargo.name .. " -> " .. dumps(newLocation))

      -- check if storages need to be adjusted
      if cargo.materialType and cargo.location and cargo.location.type == "facilityParkingspot" then
        dGenerator.changeMaterialAmountInFacility(cargo.location.facId, cargo.materialType, -cargo.slots)
      end

      if newLocation.vehId and not cargo.loadedAtTimeStamp then
        cargo.loadedAtTimeStamp = cargo.loadedAtTimeStamp or dGeneral.time()
        print(cargo.name .." loaded at ".. cargo.loadedAtTimeStamp)
      end
      cargo.location = newLocation

      -- check if storages need to be adjusted
      if cargo.materialType and cargo.location and cargo.location.type == "facilityParkingspot" then
        dGenerator.changeMaterialAmountInFacility(cargo.location.facId, cargo.materialType, cargo.slots)
      end

      if M.sameLocation(cargo.destination, newLocation) then
        cargo.data.delivered = true
      end
    end
  end
end

local function addTransientMoveCargo(cargoId, targetLocation)
  local move = {
    cargoId = cargoId,
    targetLocation = targetLocation
  }
  local cargo = M.getCargoById(cargoId)
  --print("Adding Transient Move to Cargo " .. cargo.name .. " -> " .. dumps(move))
  if cargo._transientMove then
    log("E","",string.format("Cargo %d already has a transient move: %s!", cargoId, dumps(move)))
    return
  end
  cargo._transientMove = move
  table.insert(transientMoves, move)

end
M.addTransientMoveCargo = addTransientMoveCargo

local function getTransientMoveCargo()
  local ret = {}
  for _, cargo in ipairs(allCargo) do
    if cargo._transientMove then
      table.insert(ret, cargo)
    end
  end
  return ret
end
M.getTransientMoveCargo = getTransientMoveCargo

local function clearTransientMoveForCargo(cargoId)
  local moveIdx = -1
  for i, move in ipairs(transientMoves) do
    if move.cargoId == cargoId then
      moveIdx = i
    end
  end
  if moveIdx == -1 then
    --log("E","","Could not find transient move for cargo with ID " .. cargoId .. "!")
    return
  end
  local cargo = M.getCargoById(cargoId)
  cargo._transientMove = nil
  table.remove(transientMoves, moveIdx)
end
M.clearTransientMoveForCargo = clearTransientMoveForCargo

local function clearAllTransientMoves()
  table.clear(transientMoves)
  for _, cargo in ipairs(allCargo) do
    cargo._transientMove = nil
  end
end
M.clearAllTransientMoves = clearAllTransientMoves

local function applyTransientMoves(currentLocation)
  --print("Applying transient moves...")
  --if not currentLocation then
    --log("E","","Trying to apply transient moves without a location...")
    --return
  --end
  local newMoves = {}
  local movedCargo, remainingCargo = {}, {}
  local hasMergeableCargo = false
  for _, move in ipairs(transientMoves) do
    local cargo = M.getCargoById(move.cargoId)
    if not cargo then
      log("W","","Missing Cargo for transient move? " .. dumps(move))
    else
      if not currentLocation or M.sameLocation(currentLocation, cargo.location) then
        --print("Moved Transient Cargo " .. cargo.name .. " -> " .. dumps(move))
        -- basic cargo fields
        M.changeCargoLocation(move.cargoId, move.targetLocation)

        cargo._transientMove = nil
        -- loaner orgs
        cargo.loanerOrganisations = cargo.loanerOrganisations or {}
        if cargo.location.vehId then
          tableMerge(cargo.loanerOrganisations, career_modules_loanerVehicles.getLoaningOrgsOfVehicle(cargo.location.vehId))
        end
        table.insert(movedCargo, cargo)
        hasMergeableCargo = hasMergeableCargo or cargo.merge
      else
        table.insert(newMoves, move)
        table.insert(remainingCargo, cargo)
        --print("Not moving transient cargo " .. cargo.name .. " -> " .. dumps(move))
      end
    end
  end
  transientMoves = newMoves
  cargoLocationsChangedThisFrame = true

  if hasMergeableCargo then
    for _, movedCargo in ipairs(movedCargo) do
      for _, cargo in ipairs(allCargo) do
        if    cargo.merge and movedCargo.merge
          and cargo.id ~= movedCargo.id
          and cargo.materialType == movedCargo.materialType
          and M.sameLocation(cargo.location, movedCargo.location) then
          -- update the cargo and clear the movedCargo
          movedCargo.location = {type="delete"}
          local materialData = dGenerator.getMaterialsTemplatesById(cargo.materialType)
          cargo.slots = cargo.slots + movedCargo.slots
          cargo.weight = materialData.density * cargo.slots
          cargo.rewards.money = cargo.slots
          log("I","",string.format("Merged Cargo %d into %d.", movedCargo.id, cargo.id))
        end
      end
    end
  end



  return movedCargo, remainingCargo
end
M.applyTransientMoves = applyTransientMoves

local function getTransientMovesForTargetLocationWithCargo(targetLocation)
  local ret = {}
  for _, cargo in ipairs(allCargo) do
    if cargo._transientMove and M.sameLocation(cargo._transientMove.targetLocation, targetLocation) then
      table.insert(ret, cargo)
    end
  end
  return ret
end
M.getTransientMovesForTargetLocationWithCargo = getTransientMovesForTargetLocationWithCargo



local function clearTransientFlags()
  log("E","","Clearing Transient flags no longer needed!")
end

local function onTrailerAttached(objId1, objId2)
  for _, cargo in ipairs(allCargo) do
    if cargo.location and cargo.location.vehId then
      cargo.loanerOrganisations = cargo.loanerOrganisations or {}
      tableMerge(cargo.loanerOrganisations, career_modules_loanerVehicles.getLoaningOrgsOfVehicle(cargo.location.vehId))
    end
  end
end

local function undoTransientCargo()
  log("E","","undoTransientCargo")
  -- TODO: undoing transient cargo cleanup
  --[[
  for _, cargo in ipairs(allCargo) do
    if cargo.transient then
      cargo.location = cargo.origin
      cargo.transient = nil
    end
  end
  ]]
end

M.addCargo = addCargo
M.changeCargoLocation = changeCargoLocation
M.clearTransientFlags = clearTransientFlags
M.undoTransientCargo = undoTransientCargo

-----------------------------
-- Finding Cargo Functions --
-----------------------------

local function sameLocationCargo(cargo, otherLoc)
  return M.sameLocation(cargo.location, otherLoc)
end

local function sameLocation(a,b)
  local same = true
  for k, v in pairs(a) do
    same = same and a[k] == b[k]
  end
  return same
end

local function getAllCargoCustomFilter(filter, ...)
  local ret = {}
  for _, cargo in ipairs(allCargo) do
    if filter(cargo, ...) then
      table.insert(ret, cargo)
    end
  end
  return ret
end

local function getAllCargoForLocation(loc)
  return M.getAllCargoCustomFilter(M.sameLocationCargo, loc)
end



local function getAllCargoForLocationUnexpired(loc)
  local ret = {}
  for _, cargo in ipairs(allCargo) do
    if M.sameLocation(cargo.location, loc) and cargo.offerExpiresAt > dGeneral.time() then
      table.insert(ret, cargo)
    end
  end
  return ret
end


local function getAllCargoForLocationUnexpiredUndelivered(loc, timeExpire, timeGenerated)
  local ret = {}
  for _, cargo in ipairs(allCargo) do
    if    M.sameLocation(cargo.location, loc)
      and not M.sameLocation(cargo.location, cargo.destination)
      and cargo.offerExpiresAt > (timeExpire or dGeneral.time())
      and cargo.generatedAtTimestamp <= (timeGenerated or math.huge) then
      table.insert(ret, cargo)
    end
  end
  return ret
end

local function getAllCargoForFacilityUnexpiredUndelivered(facId, timeExpire, timeGenerated)
  local ret = {}
  for _, cargo in ipairs(allCargo) do
    if cargo.location.type == "facilityParkingspot" and cargo.location.facId == facId
      and not M.sameLocation(cargo.location, cargo.destination)
      and cargo.offerExpiresAt > (timeExpire or dGeneral.time())
      and cargo.generatedAtTimestamp <= (timeGenerated or math.huge) then
      table.insert(ret, cargo)
    end
  end
  return ret
end
M.getAllCargoForFacilityUnexpiredUndelivered = getAllCargoForFacilityUnexpiredUndelivered

local function getAllCargoForDestinationStillAtOriginUnexpired(loc, timeExpire, timeGenerated)
  local ret = {}
  for _, cargo in ipairs(allCargo) do
    if    M.sameLocation(cargo.destination, loc)
      and M.sameLocation(cargo.location, cargo.origin)
      and cargo.offerExpiresAt > (timeExpire or dGeneral.time())
      and cargo.generatedAtTimestamp <= (timeGenerated or math.huge) then
      table.insert(ret, cargo)
    end
  end
  return ret
end


local function getAllCargoForDestinationFacilityStillAtOriginUnexpired(facId)
  local ret = {}
  for _, cargo in ipairs(allCargo) do
    if    cargo.destination.facId == facId
      and M.sameLocation(cargo.location, cargo.origin)
      and cargo.offerExpiresAt > dGeneral.time() then
      table.insert(ret, cargo)
    end
  end
  return ret
end


local function getAllCargoAtFacilityUnexpired(facId)
  local ret = {}
  for _, cargo in ipairs(allCargo) do
    if    M.sameLocation(cargo.location, cargo.origin)
      and cargo.location.facId == facId
      and cargo.offerExpiresAt > dGeneral.time() then
      table.insert(ret, cargo)
    end
  end
  return ret
end

local function getAllCargoInVehicles(includeTransient)
  local ret = {}
  for _, cargo in ipairs(allCargo) do
    if cargo.location.type == "vehicle" or (includeTransient and cargo._transientMove) then
      table.insert(ret, cargo)
    end
  end
  return ret
end

M.sameLocationCargo = sameLocationCargo
M.sameLocation = sameLocation
M.getAllCargoCustomFilter = getAllCargoCustomFilter
M.getAllCargoForLocation = getAllCargoForLocation
M.getAllCargoForLocationUnexpired = getAllCargoForLocationUnexpired
M.getAllCargoForLocationUnexpiredUndelivered = getAllCargoForLocationUnexpiredUndelivered
M.getAllCargoForDestinationStillAtOriginUnexpired = getAllCargoForDestinationStillAtOriginUnexpired
M.getAllCargoForDestinationFacilityStillAtOriginUnexpired = getAllCargoForDestinationFacilityStillAtOriginUnexpired
M.getAllCargoAtFacilityUnexpired = getAllCargoAtFacilityUnexpired
M.getAllCargoInVehicles = getAllCargoInVehicles

local function getLocationLabelShort(loc)
  if loc.type == "facilityParkingspot" then
    return string.format("%s",
      dGenerator.getFacilityById(loc.facId).name)
  elseif loc.type == "vehicle" then
    if be:getPlayerVehicleID(0) == loc.vehId then
      return string.format("Current Vehicle (%d)", loc.vehId)
    else
      return string.format("Other Vehicle (%d)", loc.vehId)
    end
  elseif loc.type == "playerAvatar" then
    return "Player Avatar"
  elseif loc.type == "multi" then
    if #loc.destinations == 1 then
      return M.getLocationLabelShort(loc.destinations[1])
    end
    return string.format("%d possible locations",#loc.destinations)
  else
    return "Unknown"
  end
end


local function getLocationLabelLong(loc)
  if loc.type == "facilityParkingspot" then
    local ps = dGenerator.getParkingSpotByPath(loc.psPath)
    return ps.customFields:has("name") and string.format("%s - %s",
      dGenerator.getFacilityById(loc.facId).name,
      ps.customFields:get("name")) or dGenerator.getFacilityById(loc.facId).name

  elseif loc.type == "vehicle" then
    if be:getPlayerVehicleID(0) == loc.vehId then
      return string.format("Current Vehicle (%d)", loc.vehId)
    else
      return string.format("Other Vehicle (%d)", loc.vehId)
    end
  elseif loc.type == "multi" then
    if #loc.destinations == 1 then
      return M.getLocationLabelShort(loc.destinations[1])
    end
    return string.format("%d possible locations",#loc.destinations)
  elseif loc.type == "playerAvatar" then
    return "Player Avatar"
  else
    return "Unknown"
  end
end


local function getCargoById(cargoId)
  for _, c in ipairs(allCargo) do
    if c.id == cargoId then

      return c
    end
  end
end


local function getRewardsWithBreakdown(cargo)
  local originalRewards, breakdown, adjustedRewards = deepcopy(cargo.rewards), {} , deepcopy(cargo.rewards)

  -- check modifiers adjustment on rewards
  for _,mod in ipairs(cargo.modifiers or {}) do
    if mod.type == "timed" then
      local timedStatus = nil
      local timedMultiplier = nil
      local expiredTime = dGeneral.time() - cargo.loadedAtTimeStamp

      if expiredTime <= mod.timeUntilDelayed then
        timedStatus = "On Time"
        timedMultiplier = 1
      elseif expiredTime <= mod.timeUntilLate then
        timedStatus = "Delayed"
        timedMultiplier = (0.2 + ((expiredTime-mod.timeUntilDelayed) / (mod.timeUntilLate-mod.timeUntilDelayed)) *0.6)
      else
        timedMultiplier = 0.2
        timedStatus = "Late"
      end

      local timedElement = {
        label = timedStatus,
        rewards = {money = -(1-timedMultiplier) * originalRewards.money},
        simpleBreakdownType = "bonus",
      }
      if timedMultiplier == 1 then
        timedElement.rewards.money = math.ceil(originalRewards.money/10)
      end
      if cargo.organization then
        if timedMultiplier == 1 then
          timedElement.rewards[cargo.organization.."Reputation"] = math.ceil(originalRewards[cargo.organization.."Reputation"]/2)
        elseif timedMultiplier > 0.2 then
          timedElement.rewards[cargo.organization.."Reputation"] = -(1-timedMultiplier) * originalRewards[cargo.organization.."Reputation"]
        else
          timedElement.rewards[cargo.organization.."Reputation"] = -1.5 * originalRewards[cargo.organization.."Reputation"]
        end
      end

      table.insert(breakdown, timedElement)
    end
  end

  -- check loaner cut for cargo
  for organizationId, _ in pairs(cargo.loanerOrganisations or {}) do
    local organization = freeroam_organizations.getOrganization(organizationId)
    local level = organization.reputation.level
    local organizationCut = (organization.reputationLevels[level+2].loanerCut and organization.reputationLevels[level+2].loanerCut.value or 0.5)

    local organizationElement = {
      label = string.format("Loaner Organization (%d%% cut)", round(organizationCut * 100)),
      rewards = {money = -organizationCut * originalRewards.money},
      simpleBreakdownType = "loaner",
    }
    organizationElement.rewards[organizationId.."Reputation"] = 5 + round(cargo.data.originalDistance/1000)

    table.insert(breakdown, organizationElement)
  end

  -- compute final adjusted rewards
  for _, bd in ipairs(breakdown) do
    for key, amount in pairs(bd.rewards) do
      adjustedRewards[key] = (adjustedRewards[key] or 0) + amount
    end
  end

  return originalRewards, breakdown, adjustedRewards
end
M.getRewardsWithBreakdown = getRewardsWithBreakdown


local lowestIdSort = function(a,b) return a.ids[1] < b.ids[1] end

local function addParcelRewardsSummary(cargo)
  if not next(cargo) then return end
  local ret = {}

  --current location also needs to be the same, but that is guaranteed by the caller of this function
  local cargoByGroupId = {}
  for _, c in ipairs(cargo) do
    local gId = string.format("%d-%d", c.groupId, c.loadedAtTimeStamp or -1)
    cargoByGroupId[gId] = cargoByGroupId[gId] or {}
    -- finalize the fields that require "costly" computation at this point
    table.insert(cargoByGroupId[gId], c)
    c.originalRewards, c.breakdown, c.adjustedRewards = getRewardsWithBreakdown(c)
  end
  -- format each group individually
  for gId, group in pairs(cargoByGroupId) do
     -- this function is copied over from cargoscreen... TODO: cleanup
    local formatted = dCargoScreen.formatCargoGroup(group)
    formatted.summaryId = gId
    -- patch in the rewards from the first element in the group to be used for the group as a whole (will be multiplied on UI side for display)
    formatted.originalRewards, formatted.breakdown, formatted.adjustedRewards = group[1].originalRewards, group[1].breakdown, group[1].adjustedRewards
    table.insert(ret, formatted)
  end
  table.sort(ret, lowestIdSort)

  return ret
end
M.addParcelRewardsSummary = addParcelRewardsSummary


local lastFrameTime = -1

local function updateModifiers(dtSim)
  if not career_modules_delivery_general.isDeliveryModeActive() then return end

  local secondsChanged = math.floor(dGeneral.time()) ~= math.floor(lastFrameTime)
  --if secondsChanged then print("SC") end
  for _,cargo in ipairs(allCargo) do
    if cargo.location.type == "vehicle" then
      for _,mod in ipairs(cargo.modifiers or {}) do
        if mod.type == "timed"then

          local expiredTime = dGeneral.time() - cargo.loadedAtTimeStamp

          if not mod.delayedMessageFlag and expiredTime > mod.timeUntilDelayed then
            guihooks.trigger('Message',{clear = nil, ttl = 10, msg = string.format("Delivery of %s to %s is now delayed.",cargo.name, M.getLocationLabelShort(cargo.destination)), category = "delivery", icon = "warning"})
            mod.delayedMessageFlag = true
          elseif not mod.lateMessageFlag and expiredTime > mod.timeUntilLate then
            guihooks.trigger('Message',{clear = nil, ttl = 10, msg = string.format("Delivery of %s to %s is now late.",cargo.name, M.getLocationLabelShort(cargo.destination)), category = "delivery", icon = "warning"})
            mod.lateMessageFlag = true
          end
        end
      end
      if secondsChanged then
        dTasklist.updateTasklistForCargoId(cargo.id)
      end
    end
  end
  lastFrameTime = dGeneral.time()
end



local cleanUpInterval, cleanUpTimer = 10, 0
local offerDeletionDelay = 120

local function onUpdate(dtReal, dtSim, dtRaw)
  if not dGeneral then return end
  profilerPushEvent("Delivery CargoManager")

  updateModifiers(dtSim)

  if cargoLocationsChangedThisFrame then
    dTasklist.sendCargoToTasklist()
    M.cleanUpCargo()
  end
  cleanUpTimer = cleanUpTimer + dtSim
  if cleanUpTimer > cleanUpInterval then
    M.cleanUpCargo()
  end
  cargoLocationsChangedThisFrame = false
  profilerPopEvent("Delivery CargoManager")
end

local function cleanUpCargo()
  cleanUpTimer = 0
  local newCargo = {}
  local deletedCount = 0
  for _, cargo in ipairs(allCargo) do
    if    cargo.location.type == "delete"
      or (M.sameLocation(cargo.location, cargo.origin) and cargo.offerExpiresAt < dGeneral.time() - offerDeletionDelay and not cargo._transientMove) then
      deletedCount = deletedCount + 1
    else
      table.insert(newCargo, cargo)
    end
  end
  if deletedCount > 0 then
    allCargo = newCargo
  end
end


local function onBranchTierReached(skill, tier)
  if skill == "delivery" then
    local prevMult, nextMult = dProgress.getMoneyMultiplerForSkill('delivery', tier-1), dProgress.getMoneyMultiplerForSkill('delivery', tier)
    log("I","",string.format("Reached tier %d of delivery. Increasing money rewards from %0.2f to %0.2f", tier, prevMult, nextMult))
    for _, cargo in ipairs(allCargo) do
      if cargo.rewards and cargo.rewards.money then
        cargo.rewards.money = cargo.rewards.money / prevMult * nextMult
      end
    end
  end
end
M.onBranchTierReached = onBranchTierReached

M.getLocationLabelShort = getLocationLabelShort
M.getLocationLabelLong = getLocationLabelLong
M.getCargoById = getCargoById
M.addParcelRewards = addParcelRewards
M.cleanUpCargo = cleanUpCargo
M.onUpdate = onUpdate
M.onTrailerAttached = onTrailerAttached
return M