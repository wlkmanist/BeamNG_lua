-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dPages, dProgress, dParcelMods, dVehOfferManager, dVehicleTasks
M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dPages = career_modules_delivery_pages
  dProgress = career_modules_delivery_progress
  dParcelMods = career_modules_delivery_parcelMods
  dVehOfferManager = career_modules_delivery_vehicleOfferManager
  dVehicleTasks = career_modules_delivery_vehicleTasks
end

local progress = {}

local progressTemplate = {

  cargoDeliveredByType = {
    parcel = 0,
    vehicle = 0,
    trailer = 0,
    material = 0,
  }
}

local deliverySystemsUnlockInfo = {
  parcelDelivery = { skill="delivery", moneyMult = function(t) return math.pow(1.2, t-1) end },
  trailerDelivery = { skill="delivery", name = "Trailer Delivery", requirements = {delivery = 3}, moneyMult = function(t) return math.pow(1.2, t-1) end },
  vehicleDelivery = { skill="delivery", name = "Car Jockey", requirements = {delivery = 2}, moneyMult = function(t) return math.pow(1.2, t-1) end },
  --materialsDelivery = { labourerXp = 200, moneyMult = function(t) return math.pow(1.2, t-1) end },
}

local skillUnlockDescriptions = {
  delivery = {
    {
      unlocks= {
        {type="unlockCard", heading="Small Packages", description="Deliver small and light-weight packages..", icon="boxPickUp03"}
      },
      description = {type="text", heading="Standard Cargo", description="Start with the essentials of delivering standard parcels, focusing on efficiency and reliability."}
    },
    {
      unlocks= {
        {type="unlockCard", heading="Large Packages", description="Deliver larger and heavier packages.", icon="boxPickUp03" },
        {type="unlockCard", heading="Car Jockey", description="Unlock the Car Jockey skill and try your hand at delivering vehicles for clients.", icon="keys1" }
      },
      description = {type="text", heading="Premium Cargo", description="Transporting larger, heavier packages challenges your delivery skills and route optimization for higher rewards and increased demand."}
    },
    {
      unlocks= {
        {type="unlockCard", heading="Small Trailers", description="Deliver small and medium-sized trailers using cars and pickup trucks.", icon="smallTrailer" },
      },
      description = {type="text", heading="Trailer Delivery", description="Begin transporting trailers from location A to B, enhancing your delivery capacity and logistical challenges."}
    },
    {
      unlocks= {
        {type="unlockCard", heading="Large Trailers", description="Deliver full-sized transport trailers.", icon="semiTrailer" }
      },
      description = {type="text", heading="Heavy-duty Trailers", description="Take on the challenge of delivering large trailers. Hone your skills in truck handling and logistics for major hauls."}
    },
    {
      unlocks= {
        {type="unlockCard", heading="Hazardous Materials", description="Coming Soon!", icon="hazardLights" }
      },
      description = {type="text", heading="Fluids Delivery", description="Specialize in transporting fluid materials with tanker trailers, coordinating multiple drop-offs per journey."}
    },
  },
  vehicleDelivery = {
    {
      unlocks= {
        {type="unlockCard", heading="Junkers and beaters", description="Older high-mileage beaters that perform very poorly.", icon="carCrash" }
      },
      description = {type="text", heading="Junker Vehicles", description="Deliver low-value vehicles while focusing on careful handling to avoid further depreciation."}
    },
    {
      unlocks= {
        {type="unlockCard", heading="Gently used vehicles", description="Small/Midsize vehicles of reasonable value and in good working condition.", icon="car" }
      },
      description = {type="text", heading="Used Vehicles", description="Deliver small and midsized vehicles, emphasizing efficiency and the maintenance of vehicle condition."}
    },
    {
      unlocks= {
        {type="unlockCard", heading="Semi-trucks", description="Larger vehicles and semi-trucks and other commercial vehicles.", icon="deliveryTruck" }
      },
      description = {type="text", heading="Large Vehicles", description="Deliver large vehicles and learn to adapt to their unique size and handling requirements."}
    },
    {
      unlocks= {
        {type="unlockCard", heading="Brand new vehicles", description="Factory fresh vehicles in all sizes, complete with that new-car smell.", icon="carCoin" }
      },
      description = {type="text", heading="New Vehicles", description="Deliver new vehicles while ensuring they arrive in pristine condition."}
    },
    {
      unlocks= {
        {type="unlockCard", heading="High-value Vehicles", description="High-priced, high-speed, customized, rare classics, and other top-of-the-line vehicles", icon="turbineL" },
      },
      description = {type="text", heading="Exotic Vehicles", description="Deliver top-tier vehicles, requiring exceptional care, discretion, and skill."}
    },
  }
}
M.getSkillUnlockDescription = function() return skillUnlockDescriptions end


M.getModifierRequirements = function() return modifierRequirements end


M.setProgress = function(data)
  progress = data or deepcopy(progressTemplate)
end

M.getProgress = function()
  return progress
end

M.unlockTimedDeliveries = function()

end



M.unlockTimedFragileDeliveries = function()

end



M.onCargoDelivered = function(cargoItems, sumChange)
  progress.cargoDeliveredByType.parcel = progress.cargoDeliveredByType.parcel + #cargoItems

  local affectedFacilities = {}

  for _, cargo in ipairs(cargoItems) do
    local cargoOrigFacility = dGenerator.getFacilityById(cargo.origin.facId)
    cargoOrigFacility.progress.deliveredFromHere.countByType.parcel = cargoOrigFacility.progress.deliveredFromHere.countByType.parcel + 1
    cargoOrigFacility.progress.deliveredFromHere.moneySum = cargoOrigFacility.progress.deliveredFromHere.moneySum + (cargo.rewards.money or 0)

    local cargoDestFacility = dGenerator.getFacilityById(cargo.destination.facId)
    cargoDestFacility.progress.deliveredToHere.countByType.parcel = cargoDestFacility.progress.deliveredToHere.countByType.parcel + 1
    cargoDestFacility.progress.deliveredToHere.moneySum = cargoDestFacility.progress.deliveredToHere.moneySum + (cargo.rewards.money or 0)

    dParcelMods.trackModifierStats(cargo)

    affectedFacilities[cargo.origin.facId] = true
    affectedFacilities[cargo.destination.facId] = true
  end

  extensions.hook("onDeliveryFacilityProgressStatsChanged", affectedFacilities)
end


M.onVehicleTaskFinished = function(offer)
  progress.cargoDeliveredByType[offer.data.type] = progress.cargoDeliveredByType[offer.data.type] + 1

  local vehOrigFacility = dGenerator.getFacilityById(offer.origin.facId)
  vehOrigFacility.progress.deliveredFromHere.countByType[offer.data.type] = vehOrigFacility.progress.deliveredFromHere.countByType[offer.data.type] + 1
  vehOrigFacility.progress.deliveredFromHere.moneySum = vehOrigFacility.progress.deliveredFromHere.moneySum + (offer.rewards.money or 0)

  local vehDestFacility = dGenerator.getFacilityById(offer.dropOffFacId)
  vehDestFacility.progress.deliveredToHere.countByType[offer.data.type] = vehDestFacility.progress.deliveredToHere.countByType[offer.data.type] + 1
  vehDestFacility.progress.deliveredToHere.moneySum = vehDestFacility.progress.deliveredToHere.moneySum + (offer.rewards.money or 0)

  local affectedFacilities = {}
  affectedFacilities[offer.origin.facId] = true
  affectedFacilities[offer.dropOffFacId] = true
  extensions.hook("onDeliveryFacilityProgressStatsChanged", affectedFacilities)
end



local deliverySkills = {delivery = true, vehicleDelivery=true}
local unlockStatus = nil
M.aggregateBefore = function()
--[[
  local facilityStatus = {}
  for _, fac in ipairs(dGenerator.getFacilities()) do
    facilityStatus[fac.id] = {
      visible = M.isFacilityVisible(fac.id),
      unlocked = M.isFacilityUnlocked(fac.id)
    }
  end]]

  unlockStatus = {
    --systemStatus = M.getDeliverySystemsUnlockedSimple(),
    --parcelModStatus = dParcelMods.getParcelModUnlockStatusSimple(),
    --vehicleTagsStatus = dVehOfferManager.getVehicleTagUnlockedSimple(),
    skillLevels = {}
  }
  for skill, _ in pairs(skillUnlockDescriptions) do
    unlockStatus.skillLevels[skill] = career_branches.getBranchLevel(skill)
  end
  --dump(unlockStatus)
  --dump("delivery skill " .. career_branches.getBranchLevel('delivery'))
end

M.aggregateAfter = function()
  -- check facility unlocking status
  --[[
  local unlockedFacilitesIds = {}
  for id, status in pairs(unlockStatus.facilityStatus) do
    if not status.unlocked and M.isFacilityUnlocked(id) then
      unlockedFacilitesIds[id] = true
    end
  end

  for _, id in ipairs(tableKeysSorted(unlockedFacilitesIds)) do
    career_modules_logbook.deliveryFacilityUnlocked(id)
    guihooks.trigger('Message',{clear = nil, ttl = 10, msg = string.format("You can now deliver items from %s!",dGenerator.getFacilityById(id).name), category = "deliveryUnlock"..id, icon = "local_shipping"})
  end]]

  local results = {}
  --[[
  for sys, unlocked in pairs(M.getDeliverySystemsUnlockedSimple()) do
    --print(string.format("%s from %s to %s", sys, dumps(unlockStatus.systemStatus[sys]), dumps(unlocked)))
    if unlocked and not unlockStatus.systemStatus[sys] then
      table.insert(results, {
        type = "unlock",
        heading = "Unlock:",
        label = string.format("%s now available",sys.name),
        showSystemPopup = sys,
      })
    end
  end
  ]]
  for skill, _ in pairs(skillUnlockDescriptions) do
    for lvl = unlockStatus.skillLevels[skill], career_branches.getBranchLevel(skill) do
      for _, unlock in ipairs(skillUnlockDescriptions[skill][lvl] or {}) do
        table.insert(results, unlock.unlocks)
      end
    end

  end
  --[[
  --local unlockedMods = {}
  for mod, unlocked in pairs(dParcelMods.getParcelModUnlockStatusSimple()) do
    --print(string.format("%s from %s to %s", mod, dumps(unlockStatus.parcelModStatus[mod]), dumps(unlocked)))
    if unlocked and not unlockStatus.parcelModStatus[mod] then
      --table.insert(unlockedMods,)
      table.insert(results, {
        type = "unlock",
        heading = "Parcel Modifier unlocked!",
        label = string.format("%s now available",dParcelMods.getParcelModProgressLabel(mod)),
      })
    end
  end

  for tag, unlocked in pairs(dVehOfferManager.getVehicleTagUnlockedSimple()) do
    --print(string.format("%s from %s to %s", tag, dumps(unlockStatus.vehicleTagsStatus[tag]), dumps(unlocked)))
    if unlocked and not unlockStatus.vehicleTagsStatus[tag] then
      table.insert(results, {
        type = "unlock",
        heading = "Vehicle Category Unlocked!",
        label = string.format("%s now available",dVehOfferManager.getVehicleTagLabelPlural(tag)),
      })
    end
  end
  ]]
  unlockStatus = nil
  return results
end



local unloadedCargoStatus = nil
M.unloadCargo = function(location)
  if unloadedCargoStatus ~= nil then log("W","","Already unloading cargo...") end
  unloadedCargoStatus = {}
  unloadedCargoStatus.affectedOfferIds = {}
  unloadedCargoStatus.parcelResults = {}
  unloadedCargoStatus.vehicleResults = {}
  unloadedCargoStatus.trailerResults = {}
  M.aggregateBefore()
  -- unload cargo
  dGeneral.getNearbyVehicleCargoContainers(function(playerCargoContainers)
    local playerDestinationParkingSpots = {}
    local playerVehIds = {}
    for _, con in ipairs(playerCargoContainers) do
      playerVehIds[con.vehId] = true
      for _, cargo in ipairs(con.rawCargo) do
        playerDestinationParkingSpots[cargo.destination.psPath] = playerDestinationParkingSpots[cargo.destination.psPath] or {facId = cargo.destination.facId, cargo = {}}
        table.insert(playerDestinationParkingSpots[cargo.destination.psPath].cargo, cargo)
      end
    end
    if playerDestinationParkingSpots[location.psPath] then
      -- move all the cargo in the players inventory, whose destination is this parking spot to the parking spot
      local psLoc = {type = "facilityParkingspot", facId = location.facId, psPath = location.psPath}
      for _, con in ipairs(playerCargoContainers) do
        for _, cargo in ipairs(con.rawCargo) do
          if dParcelManager.sameLocation(cargo.destination, psLoc) then
            dParcelManager.changeCargoLocation(cargo.id, cargo.destination)
          end
        end
      end
      unloadedCargoStatus.parcelResults = dParcelManager.checkDeliveredCargo()

      dGeneral.updateContainerWeights(tableKeys(playerVehIds))
      -- check saving
      --local ps = database.getParkingSpotByPath(elem.psPath)
      --local veh = be:getPlayerVehicle(0)
      --if not ps or not veh then return end
      --local inside = ps:checkParking(veh)
    end
    unloadedCargoStatus.affectedOfferIds = dVehicleTasks.checkDeliveredCargo()
    M.unloadCargoComplete()
    -- try to re-open the prompt
  end)
end

M.addVehicleTasksResult = function(result)
  unloadedCargoStatus.affectedOfferIds[result.offerId] = nil
  local resultList = result.type .. "Results"
  table.insert(unloadedCargoStatus[resultList], result)
  M.unloadCargoComplete()
end

local function rewardMapToRewardList(rewards)
  local newRewards = {}
  local attributes = tableKeys(rewards or {})
  career_branches.orderAttributeKeysByBranchOrder(attributes)

  for _, key in ipairs(attributes) do
    local amount = rewards[key]
    local rewardInfo = {attributeKey = key, rewardAmount = amount}

    if key == "money" or key == "beamXP" then
      amount = amount - (amount%0.01)
      rewardInfo.rewardAmount = amount
    else
      local value = career_modules_playerAttributes.getAttributeValue(key)
      local branchData = career_branches.getBranchById(key)
      local level, curLvlProgress, neededForNext, min, max = career_branches.calcBranchLevelFromValue(value, key)
      local valueBefore = math.max(0, curLvlProgress - rewardInfo.rewardAmount)
      rewardInfo.branchInfo = {
        name = branchData.name,
        level = {txt='ui.career.lvlLabel', context={lvl=level}},
        value = curLvlProgress,
        valueBefore = valueBefore,
        animValue = valueBefore,
        min = 0,
        max = neededForNext
      }
    end
    table.insert(newRewards, rewardInfo)
  end
  return newRewards
end

local showSystemPopup = {}
M.unloadCargoComplete = function()
  -- still waiting for vehicles to be finished
  if next(unloadedCargoStatus.affectedOfferIds) then return end

  unloadedCargoStatus.summary = {
    rewards = {},
  }
  unloadedCargoStatus.sortedResults = {}
  for _, result in ipairs(unloadedCargoStatus.parcelResults) do
    table.insert(unloadedCargoStatus.sortedResults, result)
  end
  for _, result in ipairs(unloadedCargoStatus.vehicleResults) do
    table.insert(unloadedCargoStatus.sortedResults, result)
  end
  for _, result in ipairs(unloadedCargoStatus.trailerResults) do
    table.insert(unloadedCargoStatus.sortedResults, result)
  end
  unloadedCargoStatus.parcelResults = nil
  unloadedCargoStatus.vehicleResults = nil
  unloadedCargoStatus.trailerResults = nil

  local itemLabels = {}
  for _, result in ipairs(unloadedCargoStatus.sortedResults) do
    table.insert(itemLabels, result.label)
    for key, amount in pairs(result.adjustedRewards) do
      unloadedCargoStatus.summary.rewards[key] = (unloadedCargoStatus.summary.rewards[key] or 0) + amount
    end
    result.rewards = rewardMapToRewardList(result.originalRewards)
    for _, bd in ipairs(result.breakdown) do
      bd.rewards = rewardMapToRewardList(bd.rewards)
    end
  end

  career_modules_playerAttributes.addAttributes(unloadedCargoStatus.summary.rewards, {tags={"gameplay","delivery","reward"}, label="Reward for delivering: " .. table.concat(itemLabels, ", ")})
  unloadedCargoStatus.summary.rewards = rewardMapToRewardList(unloadedCargoStatus.summary.rewards)

  unloadedCargoStatus.summary.unlocks = M.aggregateAfter()
  table.clear(showSystemPopup)
  for _, unlock in ipairs(unloadedCargoStatus.summary.unlocks) do
    if unlock.showSystemPopup then
      table.insert(showSystemPopup, unlock.showSystemPopup)
    end
  end

  gameplay_markerInteraction.closeViewDetailPrompt(true)
  guihooks.trigger("OpenDeliveryEndScreen", unloadedCargoStatus)
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Info_Open')
  career_saveSystem.saveCurrent()
  dGeneral.checkExitDeliveryMode()

  gameplay_rawPois.clear()

  unloadedCargoStatus = nil
end

M.unloadCargoPopupClosed = function()
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_02')
  career_modules_linearTutorial.introPopup("cargoDelivered")
  if next(showSystemPopup) then
    for _, key in ipairs(showSystemPopup) do
      career_modules_linearTutorial.introPopup(key.."Unlocked")
    end
  end
  gameplay_markerInteraction.setForceReevaluateOpenPrompt()
end



M.isFacilityUnlocked = function(facId)
  local fac = dGenerator.getFacilityById(facId)
  if not fac.unlockCondition then
    return true
  end
  if fac.unlockCondition.type == "minItemCount" then
    local val = fac.progress.itemsDeliveredToHere.count
    local tgt = fac.unlockCondition.target
    if val >= tgt then
      return true
    else
      return false, {
        disabledReasonHeader = "Facility not yet unlocked!",
        disabledReasonContent = string.format("Deliver %d Items here to be able to deliver from here.",tgt),
        progress = {
          {type="progressBar",minValue=0,maxValue=tgt,currValue=val, label=string.format("%d / %d Items delivered.", val, tgt)}
        }
      }
    end
  elseif fac.unlockCondition.type == "branchLevel" then
  end
  return true
end

M.isFacilityVisible = function(facId)
  local fac = dGenerator.getFacilityById(facId)
  if not fac.visibleCondition then
    return true
  end
  if fac.visibleCondition.type == "minItemCount" then
    local val = fac.progress.itemsDeliveredToHere.count
    local tgt = fac.unlockCondition.target
    if val >= tgt then
      return true
    else
      return false
    end
  end
  return true
end


M.getFacilityCountForCargoCount = function(direction)
  local count = 0
  for _, facility in ipairs(dGenerator.getFacilities()) do
    local c = 0
    for key, v in pairs(facility.progress[direction].countByType) do
      c = c + v
    end
    if c > 0 then count = count + 1 end
  end
  return count
end




M.getMoneyMultiplerForSystem = function(system, tier)

return deliverySystemsUnlockInfo[system].moneyMult(tier or career_branches.getBranchLevel(deliverySystemsUnlockInfo[system].skill))
end

M.isParcelDeliveryUnlocked    = function() return true end
M.isTrailerDeliveryUnlocked   = function() return career_branches.getBranchXP("delivery") >= deliverySystemsUnlockInfo.trailerDelivery.requirements.delivery end
M.isVehicleDeliveryUnlocked   = function() return career_branches.getBranchXP("delivery") >= deliverySystemsUnlockInfo.vehicleDelivery.requirements.delivery end
M.isMaterialsDeliveryUnlocked = function() return false end

M.getDeliverySystemsUnlockedSimple = function()
  local unlockInfo = {}
  for key, info in pairs(deliverySystemsUnlockInfo) do
    if info.requirements then
      unlockInfo[key] = career_branches.getBranchLevel("delivery") >= info.requirements.delivery
    end
  end
  return unlockInfo
end

local deliverySkillUnlockInfo = {
  delivery = { name = "Cargo Delivery" },
  vehicleDelivery = { name = "Car Jockey", requirements = {delivery = 4}},
}

M.getDeliverySystemsUnlocked = function()
  local unlockInfo = {}
  local deliverySkill = career_branches.getBranchById("delivery")
  for key, info in pairs(deliverySkillUnlockInfo) do

    local unlocked = (not info.requirements) or career_branches.getBranchLevel("delivery") >= info.requirements.delivery
    if unlocked then
      unlockInfo[key] = {
        unlocked = true
      }
    else
      local currValue, maxValue = career_branches.getBranchXP("delivery"), deliverySkill.levels[info.requirements.delivery+1].requiredValue
      unlockInfo[key] = {
        unlocked = false,
        header = info.name .. " requires delivery skill level >= " .. info.requirements.delivery,
        progress = {
          {type="progressBar",minValue=0,maxValue=maxValue,currValue=currValue, label=string.format("%d / %d Delivery XP", currValue, maxValue),}
        }
      }
    end
  end
  return unlockInfo
end

--[[
local function onGetSkillUnlockInfoForUi(skill, unlocks)

  if skill.id ~= "delivery" then return end
  for key, info in pairs(deliverySystemsUnlockInfo) do
    table.insert(unlocks[3], {type="text", label="Vehicle Deliveries" })
  end
end

M.onGetSkillUnlockInfoForUi = onGetSkillUnlockInfoForUi

]]

return M