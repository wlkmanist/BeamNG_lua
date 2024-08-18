-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local ffi = require('ffi')
M.dependencies = {"freeroam_facilities", "career_modules_delivery_general"}

local cargoLocationsChangedThisFrame = false

local allCargo = {}
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dPages, dProgress, dTasklist
M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dPages = career_modules_delivery_pages
  dProgress = career_modules_delivery_progress
  dTasklist = career_modules_delivery_tasklist
end

local allVehiclesWithCargo = {}
local smoothnessTemplate = {
  lastPos = nil,
  lastVel = nil,
  lastAcc = nil,
  fwd = vec3(),
  smootherAcc = nil,
  smootherJer = nil,
  veh = nil,
  up = vec3(),
  currPos = vec3(),
  currVel = vec3(),
  currAcc = vec3(),
  currJer = vec3(),
  smAcc = nil,
  jer = nil,
  smJer = nil,
  smoothValue = nil,
}

local function norm(value, min, max)
  return (value - min) / (max - min);
end


-----------------------------------
-- Adding/Moving Cargo functions --
-----------------------------------

local function addCargo(cargo)
  table.insert(allCargo, cargo)
  extensions.hook("onCargoGenerated", cargo)
end

local function changeCargoLocation(cargoId, newLocation, markTransient)
  cargoLocationsChangedThisFrame = true
  if not newLocation or not next(newLocation) then
    log("E","","Trying to set location to nil or empty! " .. dumps(cargoId) .. " -> ".. dumps(newLocation))
  end
  for _, cargo in ipairs(allCargo) do
    if cargo.id == cargoId then
      if markTransient then
        if not cargo.transient then
          cargo._preTransientLocation = deepcopy(cargo.location)
        end
      end
      cargo.location = newLocation
      if markTransient then
        cargo.transient = not M.sameLocation(cargo.origin, newLocation)
      end

      if M.sameLocation(cargo.destination, newLocation) then
        cargo.data.delivered = true
      end
    end
  end
end

local function clearTransientFlags()
  for _, cargo in ipairs(allCargo) do
    -- transient items need to have a setup when they are loaded for the first time into a car
    if cargo.transient then
      if not cargo.loadedAtTimeStamp and cargo.location.type == "vehicle" then
        cargo.loadedAtTimeStamp = dGeneral.time()
        for _, d in ipairs(cargo.modifiers) do
          if d.type == "timed" then
            d.expirationTimeStamp = dGeneral.time() + d.deliveryTime
            d.definitiveExpirationTimeStamp = dGeneral.time() + d.deliveryTime + d.paddingTime
          elseif d.type == "fragile" then
            allVehiclesWithCargo[cargo.location.vehId] = deepcopy(smoothnessTemplate)
          end
        end
      end
    end
    cargo.transient = nil
    cargo._preTransientLocation = nil
  end
end

local function undoTransientCargo()
  for _, cargo in ipairs(allCargo) do
    if cargo.transient then
      cargo.location = cargo.origin
      cargo.transient = nil
    end
  end
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

local function getAllCargoInVehicles()
  local ret = {}
  for _, cargo in ipairs(allCargo) do
    if cargo.location.type == "vehicle" then
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
  else
    return "Unknown"
  end
end


local function getLocationLabelLong(loc)
  if loc.type == "facilityParkingspot" then
    local ps = dGenerator.getParkingSpotByPath(loc.psPath)
    return string.format("%s - %s",
      dGenerator.getFacilityById(loc.facId).name,
      ps.customFields:get("name") or ps.id)
  elseif loc.type == "vehicle" then
    if be:getPlayerVehicleID(0) == loc.vehId then
      return string.format("Current Vehicle (%d)", loc.vehId)
    else
      return string.format("Other Vehicle (%d)", loc.vehId)
    end
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


local function checkDeliveredCargo()
  local delivered = {}
  for _, c in ipairs(allCargo) do
    if M.sameLocation(c.destination, c.location) then
      table.insert(delivered, c)
    end
  end
  if not next(delivered) then return end



  -- TODO: this should check each vehicle individually
  local fragileCargoStillInVehicle = false
  for _, c in ipairs(allCargo) do
    if c.location.type == "vehicle" then
      for _,v in ipairs(c.modifiers) do
        if v.type == "fragile" then
          fragileCargoStillInVehicle = true
        end
      end
    end
  end
  if not fragileCargoStillInVehicle then
    allVehiclesWithCargo = {}
  end

  local resultElements = {}
  local sumChange = {}
  local penaltyMessages = {}
  local cargoByGroupId = {}
  for _, c in ipairs(delivered) do
    c.location = {type = "delete"}
    local gId = string.format("%d-%s-%d", c.groupId, c.transient or false, c.loadedAtTimeStamp or -1)
    cargoByGroupId[gId] = cargoByGroupId[gId] or {}
    table.insert(cargoByGroupId[gId], c)
  end
  for _, groupId in ipairs(tableKeysSorted(cargoByGroupId)) do
    local c = cargoByGroupId[groupId][1]
    local count = #cargoByGroupId[groupId]
    local resultElement = {
      type = "parcel",
      label = c.name .. " x"..count,
      originalRewards = deepcopy(c.rewards),
      breakdown = {},
      adjustedRewards = {},
    }

    for key, amount in pairs(c.rewards) do
      resultElement.originalRewards[key] = resultElement.originalRewards[key] * count
    end

    local timedStatus = nil
    local timedMultiplier = nil

    if #c.modifiers > 0 then
      for _,v in ipairs(c.modifiers) do
        if v.type == "timed" then
          local penaltyForTime = 0
          if v.expirationTimeStamp and v.definitiveExpirationTimeStamp then
            if dGeneral.time() < v.expirationTimeStamp then
              timedStatus = "On Time"
              timedMultiplier = 1
            elseif dGeneral.time() < v.definitiveExpirationTimeStamp then
              timedMultiplier = 1 - (0.1 + norm(dGeneral.time(), v.expirationTimeStamp, v.definitiveExpirationTimeStamp)*0.5)
              timedStatus = "Delayed"
            else
              timedMultiplier = 0.2
              timedStatus = "Late"
            end
          end
        end
      end
    end

    if timedStatus then
      local timedElement = {
        label = timedStatus,
        rewards = {money = -(1-timedMultiplier) * resultElement.originalRewards.money}
      }
      if timedMultiplier == 1 then
        timedElement.rewards.money = math.ceil(resultElement.originalRewards.money/10)
      end
      table.insert(resultElement.breakdown, timedElement)
    end

    resultElement.adjustedRewards = deepcopy(resultElement.originalRewards)
    for _, bd in ipairs(resultElement.breakdown) do
      for key, amount in pairs(bd.rewards) do
        resultElement.adjustedRewards[key] = resultElement.adjustedRewards[key] + amount
      end
    end
    --dump(resultElement)
    table.insert(resultElements, resultElement)
    for _, c in ipairs(cargoByGroupId[groupId]) do
      c.rewards = deepcopy(resultElement.adjustedRewards)
      for key, amount in pairs(c.rewards) do
        c.rewards[key] = c.rewards[key] / count
      end
      --print(string.format("%s %d %s", c.name, c.id, dumps(c.rewards)))
    end


  end
  extensions.hook("onCargoDelivered", delivered)




  return resultElements
end

local accMult, jerkMult = 0.03, 2
local debugFragile = true
local function getVehiclesSmoothnessValues(dtSim)
  if dtSim < 10e-10 then
    return
  end

  -- Assuming you have vectors for position, forward, and up
  for vehId,vehData in pairs(allVehiclesWithCargo) do
    if not vehData.veh then
      vehData.veh = scenetree.findObjectById(vehId)

    end
    if not vehData.veh then
      log("E","","The vehicle ID: " .. vehId .. " is not in the scene, the calculations for the fragile will not be done.")
      return
    end
    vehData.oobb = vehData.veh:getSpawnWorldOOBB()

    vehData.currPos:set(vehData.oobb:getPoint(0))
    vehData.currPos:setAdd(vehData.oobb:getPoint(3))
    vehData.currPos:setAdd(vehData.oobb:getPoint(4))
    vehData.currPos:setAdd(vehData.oobb:getPoint(7))
    vehData.currPos:setScaled(0.25)

    if vehData.lastPos then
      vehData.currVel:set(vehData.currPos)
      vehData.currVel:setSub(vehData.lastPos)
      vehData.currVel:setScaled(1/dtSim)
    else
      vehData.currVel = vec3()
    end
    if vehData.lastVel then
      vehData.currAcc:set(vehData.currVel)
      vehData.currAcc:setSub(vehData.lastVel)
      vehData.currAcc:setScaled(1/dtSim)
    else
      vehData.currAcc = vec3()
    end
    if vehData.lastAcc then
      vehData.currJer:set(vehData.currAcc)
      vehData.currJer:setSub(vehData.lastAcc)
      vehData.currJer:setScaled(1/dtSim)
    else
      vehData.currJer = vec3()
    end

    --simpleDebugText3d("Pos", vehData.currPos, 0.25,  ColorF(1,0,0,0.5))
    --simpleDebugText3d("Acc", vehData.currPos + vehData.currAcc*0.05, 0.25,  ColorF(0,1,0,0.5))
    --simpleDebugText3d("Jer", vehData.currPos + vehData.currJer*0.002, 0.25,  ColorF(0,0,1,0.5))

    vehData.smootherAcc = vehData.smootherAcc or newTemporalSmoothing(20, 20)
    vehData.smAcc = vehData.smootherAcc:getUncapped(vehData.currAcc:length(), dtSim)

    if not vehData.smootherJer then vehData.smootherJer = newTemporalSmoothing(15, 50) end
    vehData.jer = vehData.currJer:length() / 5000
    vehData.smJer = vehData.smootherJer:getUncapped(vehData.jer, dtSim)
    if vehData.smJer > 2 then vehData.smootherJer:set(2) vehData.smJer = 2 end

    vehData.lastPos = vehData.lastPos or vec3()
    vehData.lastVel = vehData.lastVel or vec3()
    vehData.lastAcc = vehData.lastAcc or vec3()

    vehData.lastPos:set(vehData.currPos)
    vehData.lastVel:set(vehData.currVel)
    vehData.lastAcc:set(vehData.currAcc)

    vehData.smoothValue = vehData.smAcc * accMult + vehData.smJer * jerkMult

    if debugFragile then
      local str = string.format("smVal: %0.2f  ", vehData.smoothValue)
      for i = 0, (vehData.smAcc * accMult)*10 do
        str = str .. "A"
      end
      str = str .. " "
      for i = 0, (vehData.smJer * jerkMult)*10 do
        str = str .. "J"
      end
      log(vehData.smoothValue > 0.5 and "E" or "I", "", str)
    end
  end

end

local lastFrameTime = -1
local fragileSmoothMultiplier = 6
local function checkModifiers(dtSim)
  if not career_modules_delivery_general.isDeliveryModeActive() then return end

  local secondsChanged = math.floor(dGeneral.time()) ~= math.floor(lastFrameTime)
  --if secondsChanged then print("SC") end
  for _,item in ipairs(allCargo) do
    if item.location.type == "vehicle" and not item.transient then
      if #item.modifiers > 0 then
        for _,v in ipairs(item.modifiers) do
          if v.type == "timed"then
            if v.expirationTimeStamp - dGeneral.time() <= 0 and v.definitiveExpirationTimeStamp - dGeneral.time() > 0 and not v.timeMessageFlag then
              v.timeMessageFlag = true
              guihooks.trigger('Message',{clear = nil, ttl = 10, msg = string.format("Delivery of %s to %s is now delayed.",item.name, M.getLocationLabelShort(item.destination)), category = "delivery", icon = "warning"})
            elseif v.definitiveExpirationTimeStamp - dGeneral.time() <= 0 and not v.paddingTimeMessageFlag then
              v.paddingTimeMessageFlag = true
              guihooks.trigger('Message',{clear = nil, ttl = 10, msg = string.format("Delivery of %s to %s is now late.",item.name, M.getLocationLabelShort(item.destination)), category = "delivery", icon = "warning"})
            end
          elseif v.type == "fragile" then
            local vData = allVehiclesWithCargo[item.location.vehId]
            if vData then
              if vData.smoothValue then
                local diff = vData.smoothValue - v.sensitivity

                if diff > 0 then
                  v.currentHealth = math.max(v.currentHealth - (diff * dtSim) * fragileSmoothMultiplier, 0)
                end
              end
            end
          end
        end
        if secondsChanged then
          dTasklist.updateTasklistForCargoId(item.id)
        end
      end
    end
  end
  lastFrameTime = dGeneral.time()
end


local offerDeletionDelay = 120
local function cleanUpCargo()
  local newCargo = {}
  local deletedCount = 0
  for _, cargo in ipairs(allCargo) do
    if    cargo.location.type == "delete" or M.sameLocation(cargo.location, cargo.origin)
      and cargo.offerExpiresAt < dGeneral.time() - offerDeletionDelay then
      deletedCount = deletedCount + 1
    else
      table.insert(newCargo, cargo)
    end
  end
  if deletedCount > 0 then
    allCargo = newCargo
    log("I","","Deleted " .. deletedCount .. " cargo entries.")
  end
end


local function onUpdate(dtReal, dtSim, dtRaw)
  if not dGeneral then return end
  profilerPushEvent("Delivery CargoManager")

  getVehiclesSmoothnessValues(dtSim)
  checkModifiers(dtSim)

  if cargoLocationsChangedThisFrame then
    dTasklist.sendCargoToTasklist()
    M.cleanUpCargo()
  end
  cargoLocationsChangedThisFrame = false
  profilerPopEvent("Delivery CargoManager")
end


local function onBranchTierReached(skill, tier)
  if skill == "delivery" then
    local prevMult, nextMult = dProgress.getMoneyMultiplerForSystem('parcelDelivery', tier-1), dProgress.getMoneyMultiplerForSystem('parcelDelivery', tier)
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
M.checkDeliveredCargo = checkDeliveredCargo
M.cleanUpCargo = cleanUpCargo
M.onUpdate = onUpdate
return M