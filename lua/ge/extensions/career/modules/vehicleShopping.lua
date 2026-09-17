-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career', 'util_configListGenerator'}

local moduleVersion = 61

local vehicleShopDirtyDate

local vehicleDeliveryDelay = 60
local vehicleOfferTimeToLive = 10 * 60
local timeToRemoveSoldVehicle = 5 * 60
local dealershipTimeBetweenOffers = 1 * 60
local salesTax = 0.07
local customLicensePlatePrice = 300

local vehiclesInShop = {}
local sellersInfos = {}
local currentSeller

-- Lua-owned vehicle-shopping UI state (source of truth for the Vue screens).
-- selectedSellerId: the dealership/private-seller filter chosen in the UI (distinct
-- from currentSeller, which means the player is physically at a dealership).
local selectedSellerId
local shoppingScreenTag
local buyingAvailable = true
local marketplaceAvailable = true

local staticSellerState = {}

local vehicleWatchlist = {}

local purchaseData

local tether
local tetherRange = 4 --meter

local function generateSoldVehicleValue(shopId)
  local vehicleInfo = M.getVehicleInfoByShopId(shopId)
  if not vehicleInfo then return end
  local value = vehicleInfo.Value * (0.9 + math.random() * 0.1)
  return round(value / 10) * 10
end

local function convertKeysToStrings(t)
  local unsoldVehicles = {}
  local soldVehicles = {}
  for k,v in ipairs(t) do
    if v.soldViewCounter and v.soldViewCounter > 0 then
      table.insert(soldVehicles, v)
    else
      table.insert(unsoldVehicles, v)
    end
  end
  return unsoldVehicles, soldVehicles
end

local privateSellersPreview = "/levels/west_coast_usa/facilities/privateSeller_dealership.jpg"
local TUTORIAL_BUY_VEHICLE_DEALERSHIP_ID = "apmStarterVehicles"

local function getUiDealershipsData(unsoldVehicles)
  local dealerships = freeroam_facilities.getFacilitiesByType("dealership")
  local isInTutorial = career_modules_tutorial and career_modules_tutorial.isActive()
      and career_modules_tutorial.getCurrentStep() == "09spmSignup"

  local vehicleCountPerDealership = {}
  for _, vehicle in ipairs(unsoldVehicles) do
    vehicleCountPerDealership[vehicle.sellerId] = (vehicleCountPerDealership[vehicle.sellerId] or 0) + 1
  end
  local data = {}
  for _, dealership in ipairs(dealerships) do

    table.insert(data, {
      id = dealership.id,
      name = _tr(dealership.name),
      description = _tr(dealership.description),
      vehicleCount = vehicleCountPerDealership[dealership.id] or 0,
      preview = dealership.preview,
      icon = "carDealer",
      remotePurchaseOnly = dealership.remotePurchaseOnly or false,
      disabled = isInTutorial and dealership.id ~= TUTORIAL_BUY_VEHICLE_DEALERSHIP_ID,
      disabledReason = isInTutorial and dealership.id ~= TUTORIAL_BUY_VEHICLE_DEALERSHIP_ID and _tr("ui.career.vehicleShopping.disabledDuringOnboarding") or nil,
    })
  end
  table.sort(data, function(a,b) return a.name < b.name end)
    table.insert(data, {
      id = "private",
      name = _tr("ui.career.vehicleShopping.privateSellers"),
      vehicleCount = vehicleCountPerDealership["private"] or 0,
      preview = privateSellersPreview,
      icon = "personSolid",
      disabled = isInTutorial,
      disabledReason = isInTutorial and _tr("ui.career.vehicleShopping.disabledDuringOnboarding") or nil,
    })
  return data
end

local function getShoppingData()
  local data = {}
  data.vehiclesInShop, data.soldVehicles = convertKeysToStrings(vehiclesInShop)
  data.uiDealershipsData = getUiDealershipsData(data.vehiclesInShop)
  data.currentSeller = currentSeller
  if currentSeller then
    local dealership = freeroam_facilities.getDealership(currentSeller)
    data.currentSellerNiceName = _tr(dealership.name)
  end

  -- route-relevant UI state, owned by Lua
  data.selectedSellerId = selectedSellerId
  data.screenTag = shoppingScreenTag
  data.buyingAvailable = buyingAvailable
  data.marketplaceAvailable = marketplaceAvailable
  data.playerAttributes = career_modules_playerAttributes.getAllAttributes()
  data.inventoryHasFreeSlot = career_modules_inventory.hasFreeSlot()
  data.numberOfFreeSlots = career_modules_inventory.getNumberOfFreeSlots()

  data.hasboughtStarterVehicle = career_career.hasBoughtStarterVehicle()

  data.disableShopping = false
  local reason = career_modules_permissions.getStatusForTag("vehicleShopping")
  if not reason.allow then
    data.disableShopping = true
  end
  if reason.permission ~= "allowed" then
    data.disableShoppingReason = reason.label or "not allowed (TODO)"
  end

  return data
end

local function sendShoppingDataToUI()
  guihooks.trigger("vehicleShoppingData", getShoppingData())
end

local function normalizePopulations(configs, scalingFactor)
  local sum = 0
  for _, configInfo in ipairs(configs) do
    configInfo.adjustedPopulation = configInfo.Population or 1
    sum = sum + configInfo.adjustedPopulation
  end
  local average = sum / tableSize(configs)
  for _, configInfo in ipairs(configs) do
    local distanceFromAverage = configInfo.adjustedPopulation - average
    configInfo.adjustedPopulation = round(configInfo.adjustedPopulation - scalingFactor * distanceFromAverage)
  end
end

local function getRoundedPrice(value, priceRoundingType)
  if priceRoundingType == "prestige" then
    -- Always round up to a price ending in 495 or 995
    local thousands = math.floor(value / 1000)
    local candidate495 = thousands * 1000 + 495
    if value <= candidate495 then return candidate495 end
    local candidate995 = thousands * 1000 + 995
    if value <= candidate995 then return candidate995 end
    return (thousands + 1) * 1000 + 495
  elseif priceRoundingType == "private" then
    -- Always round up to the next multiple of 100
    return math.ceil(value / 100) * 100
  elseif priceRoundingType == "dealer" then
    -- Round up to nearest 20 (ends in 20, 40, 60, 80, 00)
    return math.ceil(value / 20) * 20
  else
    -- Always round up to the next multiple of 10
    return math.ceil(value / 10) * 10
  end
end

local function generateShopId()
  local shopId = 0
  while true do
    shopId = math.floor(math.random() * 1000000)
    for _, vehInfo in ipairs(vehiclesInShop) do
      if vehInfo.shopId == shopId then
        break
      end
    end
    return shopId
  end
end

local function getVehicleInfoByShopId(shopId)
  for _, vehInfo in ipairs(vehiclesInShop) do
    if vehInfo.shopId == shopId then
      return vehInfo
    end
  end
  return nil
end

local function getEligibleVehiclesWithoutDealershipVehicles(eligibleVehicles, seller)
  local eligibleVehiclesWithoutDealershipVehicles = deepcopy(eligibleVehicles)
  local configsInDealership = {}
  for _, vehicleInfo in ipairs(vehiclesInShop) do
    if vehicleInfo.sellerId == seller.id then
      configsInDealership[vehicleInfo.model_key] = configsInDealership[vehicleInfo.model_key] or {}
      configsInDealership[vehicleInfo.model_key][vehicleInfo.key] = true
    end
  end

  for i = #eligibleVehiclesWithoutDealershipVehicles, 1, -1 do
    local vehicleInfo = eligibleVehiclesWithoutDealershipVehicles[i]
    if configsInDealership[vehicleInfo.model_key] and configsInDealership[vehicleInfo.model_key][vehicleInfo.key] then
      table.remove(eligibleVehiclesWithoutDealershipVehicles, i)
    end
  end
  return eligibleVehiclesWithoutDealershipVehicles
end

-- find a random parking spot on the map for a private sale vehicle
local function findPrivateSaleParkingSpot(randomVehicleInfo)
  local parkingSpots = gameplay_parking.getParkingSpots().byName
  local parkingSpotNames = tableKeys(parkingSpots)

  -- get a random parking spot on the map that fits the vehicle
  local parkingSpotName, parkingSpot
  if randomVehicleInfo.BoundingBox and randomVehicleInfo.BoundingBox[2] then
    local counter = 0
    repeat
      counter = counter + 1
      local size = tableSize(parkingSpotNames)
      local name = parkingSpotNames[math.random(size)]
      local spot = parkingSpots[name]
      if not spot.customFields.tags.notprivatesale and spot:boxFits(randomVehicleInfo.BoundingBox[2][1], randomVehicleInfo.BoundingBox[2][2], randomVehicleInfo.BoundingBox[2][3]) then
        parkingSpotName, parkingSpot = name, spot
      end
    until parkingSpotName or counter >= 50
  end

  -- if we didnt find a fitting parking spot, try to find any parking spot that is not a private sale parking spot, even if it doesn't fit (the safe spawn will ususally kind of make it work anyway)
  if not parkingSpotName then
    local counter = 0
    repeat
      counter = counter + 1
      local size = tableSize(parkingSpotNames)
      local name = parkingSpotNames[math.random(size)]
      local spot = parkingSpots[name]
      if not spot.customFields.tags.notprivatesale then
        parkingSpotName, parkingSpot = name, spot
      end
    until parkingSpotName or counter >= 50
  end

  -- last resort: nothing suitable found, just grab any parking spot
  if not parkingSpotName then
    local size = tableSize(parkingSpotNames)
    parkingSpotName = parkingSpotNames[math.random(size)]
    parkingSpot = parkingSpots[parkingSpotName]
  end

  return parkingSpotName, parkingSpot
end

local function updateVehicleList(fromScratch)
  vehicleShopDirtyDate = os.date("!%Y-%m-%dT%H:%M:%SZ")

  local sellers = {}

  if fromScratch then
    vehiclesInShop = {}
    vehicleWatchlist = {}
    staticSellerState = {}
  end

  -- get the dealerships and private sellers from the level
  local facilities = deepcopy(freeroam_facilities.getFacilities(getCurrentLevelIdentifier()))
  for _, dealership in ipairs(facilities.dealerships) do
    dealership.filter = dealership.filter or {}
    table.insert(sellers, dealership)
    if dealership.staticInventory then
      staticSellerState[dealership.id] = staticSellerState[dealership.id] or { initialized = false }
    end
  end
  for _, privateSeller in ipairs(facilities.privateSellers or {}) do
    privateSeller.filter = privateSeller.filter or {}
    table.insert(sellers, privateSeller)
  end


  table.sort(sellers, function(a,b) return a.id < b.id end)

  local currentTime = os.time()

  -- keep the currently spawned/test-driven vehicle in the shop so it doesn't get removed while in use
  local protectedShopId
  local spawnedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
  if spawnedVehicleInfo then
    protectedShopId = spawnedVehicleInfo.shopId
  end

  -- remove vehicles that have expired or whose model data no longer exists (e.g. a mod was removed)
  for i = #vehiclesInShop, 1, -1 do
    local vehicleInfo = vehiclesInShop[i]
    local model = core_vehicles.getModel(vehicleInfo.model_key)
    if not model or next(model) == nil then
      log("I", "Career", "Removing shop vehicle with missing model data: " .. tostring(vehicleInfo.model_key))
      -- if the removed vehicle is the currently spawned/test-driven one, cancel the inspect/test-drive state and despawn it
      if spawnedVehicleInfo and vehicleInfo.shopId == protectedShopId then
        career_modules_inspectVehicle.leaveSaleCallback("despawn", false, false)
      end
      vehicleWatchlist[vehicleInfo.shopId] = nil
      table.remove(vehiclesInShop, i)
    else
      local offerTime = currentTime - vehicleInfo.generationTime
      if vehicleInfo.shopId ~= protectedShopId and offerTime > vehicleInfo.offerTTL and not vehicleInfo.staticOffer then -- vehicle offer has expired
        if vehicleWatchlist[vehicleInfo.shopId] then
          if type(vehicleWatchlist[vehicleInfo.shopId]) ~= "number" then
            vehicleWatchlist[vehicleInfo.shopId] = currentTime + timeToRemoveSoldVehicle -- time to remove the vehicle from the watchlist
            if not vehicleInfo.soldFor then
              vehicleInfo.soldFor = generateSoldVehicleValue(vehicleInfo.shopId)
            end
          end
          vehicleInfo.soldViewCounter = vehicleInfo.soldViewCounter or 0
          vehicleInfo.soldViewCounter = vehicleInfo.soldViewCounter + 1
          if currentTime > vehicleWatchlist[vehicleInfo.shopId] then
            vehicleWatchlist[vehicleInfo.shopId] = nil -- remove the vehicle from the watchlist
            table.remove(vehiclesInShop, i)
          end
        else
          table.remove(vehiclesInShop, i)
        end
      end
    end
  end

  local eligibleVehicles = util_configListGenerator.getEligibleVehicles()
  normalizePopulations(eligibleVehicles, 0.4)

  for _, seller in ipairs(sellers) do
    if not sellersInfos[seller.id] then
      sellersInfos[seller.id] = {
        lastGenerationTime = 0,
      }
    end
    if fromScratch then
      sellersInfos[seller.id].lastGenerationTime = 0
    end

    local randomVehicleInfos = {}
    if seller.staticInventory then
      if not staticSellerState[seller.id].initialized then
        for _, vehicleInfo in ipairs(seller.staticInventoryVehicles) do
          local newVehicleInfo = deepcopy(core_vehicles.getConfig(vehicleInfo.model, vehicleInfo.config))
          newVehicleInfo.staticOffer = true
          newVehicleInfo.year = vehicleInfo.year or 2000
          newVehicleInfo.Mileage = vehicleInfo.mileage or 0
          newVehicleInfo.negotiationPossible = vehicleInfo.negotiationPossible
          newVehicleInfo.Brand = newVehicleInfo.aggregates.Brand and next(newVehicleInfo.aggregates.Brand) or ""
          table.insert(randomVehicleInfos, newVehicleInfo)
          newVehicleInfo.discountPercentage = vehicleInfo.discountPercentage or 0
        end
        staticSellerState[seller.id].initialized = true
      end
    else
      -- vehicleGenerationMultiplier lowers the time between offers
      local adjustedTimeBetweenOffers = dealershipTimeBetweenOffers / (seller.vehicleGenerationMultiplier or 1)
      local maxVehicles = math.floor(vehicleOfferTimeToLive / adjustedTimeBetweenOffers)  -- Higher cap for lower time between offers
      local numberOfVehiclesToGenerate = math.min(math.floor((currentTime - sellersInfos[seller.id].lastGenerationTime) / adjustedTimeBetweenOffers), maxVehicles)
      log("I", "Career", "Generating " .. numberOfVehiclesToGenerate .. " vehicles for " .. seller.id)

      -- generate the vehicles without duplicating vehicles that are already in the dealership
      local eligibleVehiclesWithoutDealershipVehicles = getEligibleVehiclesWithoutDealershipVehicles(eligibleVehicles, seller)
      local newRandomVehicleInfos = util_configListGenerator.getRandomVehicleInfos(seller, numberOfVehiclesToGenerate, eligibleVehiclesWithoutDealershipVehicles, "adjustedPopulation")
      arrayConcat(randomVehicleInfos, newRandomVehicleInfos)

      -- generate the remaining vehicles without a duplicate check
      local numberOfMissingVehicles = numberOfVehiclesToGenerate - tableSize(newRandomVehicleInfos)
      if numberOfMissingVehicles > 0 then
        log("I", "Career", "Generating " .. numberOfMissingVehicles .. " more vehicles without duplicate check for " .. seller.id)
        for i = 1, numberOfMissingVehicles do
          local newRandomVehicleInfos = util_configListGenerator.getRandomVehicleInfos(seller, 1, eligibleVehicles, "adjustedPopulation")
          arrayConcat(randomVehicleInfos, newRandomVehicleInfos)
        end
      end
    end

    for i, randomVehicleInfo in ipairs(randomVehicleInfos) do
      -- Distribute generation times evenly between lastGenerationTime and currentTime
      randomVehicleInfo.generationTime = currentTime - ((i-1) * dealershipTimeBetweenOffers)
      randomVehicleInfo.offerTTL = randomVehicleInfo.staticOffer and math.huge or vehicleOfferTimeToLive

      randomVehicleInfo.sellerId = seller.id
      randomVehicleInfo.sellerName = _tr(seller.name)
      local filter = randomVehicleInfo.filter
      local years = randomVehicleInfo.Years or randomVehicleInfo.aggregates.Years

      -- static offers already have a year and mileage
      if not randomVehicleInfo.staticOffer then
        -- get a random year between the min and max year of the filter and the years of the vehicle
        local minYear = (years and years.min) or 2023
        if filter.whiteList and filter.whiteList.Years and filter.whiteList.Years.min then
          minYear = math.max(minYear, filter.whiteList.Years.min)
        end
        local maxYear = (years and years.max) or 2023
        if filter.whiteList and filter.whiteList.Years and filter.whiteList.Years.max then
          maxYear = math.min(maxYear, filter.whiteList.Years.max)
        end
        randomVehicleInfo.year = math.random(minYear, maxYear)

        -- get a random mileage between the min and max mileage of the filter
        if filter.whiteList and filter.whiteList.Mileage then
          randomVehicleInfo.Mileage = randomGauss3()/3 * (filter.whiteList.Mileage.max - filter.whiteList.Mileage.min) + filter.whiteList.Mileage.min
        else
          randomVehicleInfo.Mileage = 0
        end
      end
      randomVehicleInfo.Value = career_modules_valueCalculator.getAdjustedVehicleBaseValue(randomVehicleInfo.Value, {mileage = randomVehicleInfo.Mileage, age = 2023 - randomVehicleInfo.year})
      randomVehicleInfo.shopId = generateShopId()

      -- compute taxes and fees
      randomVehicleInfo.fees = seller.fees or 0

      if seller.id == "private" then
        local parkingSpotName, parkingSpot = findPrivateSaleParkingSpot(randomVehicleInfo)

        randomVehicleInfo.parkingSpotName = parkingSpotName
        randomVehicleInfo.pos = parkingSpot.pos
        randomVehicleInfo.negotiationPersonality = career_modules_marketplace.generatePersonality(false)
        randomVehicleInfo.sellerName = randomVehicleInfo.negotiationPersonality.name
      else

        local dealership = freeroam_facilities.getDealership(seller.id)
        if not dealership.remotePurchaseOnly then
          randomVehicleInfo.pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
        end
        local personalityKey = seller.id  -- Use dealership ID as personality key
        randomVehicleInfo.negotiationPersonality = career_modules_marketplace.generatePersonality(false, {personalityKey})
      end

      local vehicleInsuranceClass = career_modules_insurance_insurance.getInsuranceClassFromVehicleShoppingData(randomVehicleInfo)
      if vehicleInsuranceClass then
        randomVehicleInfo.insuranceClass = vehicleInsuranceClass
      end

      if randomVehicleInfo.negotiationPossible == nil then
        randomVehicleInfo.negotiationPossible = true
      end
      randomVehicleInfo.marketValue = randomVehicleInfo.Value
      -- Apply markup to create asking price
      randomVehicleInfo.Value = getRoundedPrice(randomVehicleInfo.Value * (randomVehicleInfo.negotiationPersonality.priceMultiplier or 1), seller.priceRoundingType)

      if seller.remotePurchaseOnly then
        randomVehicleInfo.remotePurchaseOnly = true
      end
      randomVehicleInfo.discountPercentage = randomVehicleInfo.discountPercentage or 0

      if seller.discountChances then
        local discountPercentage = 0
        local roll = math.random() * 100
        local cumulativeChance = 0
        for _, discountChance in ipairs(seller.discountChances) do
          local chance = math.max(discountChance.probability or 0, 0)
          cumulativeChance = cumulativeChance + chance
          if roll < cumulativeChance then
            discountPercentage = discountChance.discountPercentage or 0
            break
          end
        end
        randomVehicleInfo.discountPercentage = discountPercentage
      end
      if (randomVehicleInfo.discountPercentage or 0) > 0 then
        randomVehicleInfo.negotiationPossible = false
        randomVehicleInfo.negotiationDisabledReason = _tr("ui.career.vehiclePurchase.negotiationUnavailableDiscounted")
      end

      table.insert(vehiclesInShop, randomVehicleInfo)

    end
    if not tableIsEmpty(randomVehicleInfos) then
      sellersInfos[seller.id].lastGenerationTime = currentTime
    end
  end

  log("I", "Career", "Vehicles in shop: " .. tableSize(vehiclesInShop))
end

local function moveVehicleToDealership(vehObj, dealershipId)
  local dealership = freeroam_facilities.getDealership(dealershipId)
  local parkingSpots = freeroam_facilities.getParkingSpotsForFacility(dealership)
  local parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(vehObj:getID(), parkingSpots)
  parkingSpot:moveResetVehicleTo(vehObj:getID(), nil, nil, nil, nil, true)
end

local function getDeliveryDelay(distance)
  if distance < 500 then return 1 end
  return vehicleDeliveryDelay
end

local function getVisualValueFromMileage(mileage)
  mileage = clamp(mileage, 0, 2000000000)
  if mileage <= 10000000 then
    return 1
  elseif mileage <= 50000000 then
    return rescale(mileage, 10000000, 50000000, 1, 0.95)
  elseif mileage <= 100000000 then
    return rescale(mileage, 50000000, 100000000, 0.95, 0.925)
  elseif mileage <= 200000000 then
    return rescale(mileage, 100000000, 200000000, 0.925, 0.88)
  elseif mileage <= 500000000 then
    return rescale(mileage, 200000000, 500000000, 0.88, 0.825)
  elseif mileage <= 1000000000 then
    return rescale(mileage, 500000000, 1000000000, 0.825, 0.8)
  else
    return rescale(mileage, 1000000000, 2000000000, 0.8, 0.75)
  end
end

local spawnFollowUpActions

local function spawnVehicle(vehicleInfo, dealershipToMoveTo)
  local spawnOptions = {}
  spawnOptions.config = vehicleInfo.key
  spawnOptions.autoEnterVehicle = false
  local newVeh = core_vehicles.spawnNewVehicle(vehicleInfo.model_key, spawnOptions)
  if dealershipToMoveTo then moveVehicleToDealership(newVeh, dealershipToMoveTo) end
  core_vehicleBridge.executeAction(newVeh,'setIgnitionLevel', 0)

  newVeh:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, %f) obj:queueGameEngineLua('career_modules_vehicleShopping.onVehicleSpawnFinished(%d)')", vehicleInfo.Mileage, getVisualValueFromMileage(vehicleInfo.Mileage), newVeh:getID()))
  return newVeh
end

local function onVehicleSpawnFinished(vehId)
  local inventoryId = career_modules_inventory.addVehicle(vehId, nil, {finalPrice = purchaseData.prices.finalPrice})

  if spawnFollowUpActions then
    if spawnFollowUpActions.delayAccess then
      career_modules_inventory.delayVehicleAccess(inventoryId, spawnFollowUpActions.delayAccess, "bought")
    end
    if spawnFollowUpActions.licensePlateText then
      career_modules_inventory.setLicensePlateText(inventoryId, spawnFollowUpActions.licensePlateText)
    end
    spawnFollowUpActions = nil
  end
end

local function unlockNegotiationAchievements()
  local vehicleInfo = purchaseData.vehicleInfo
  local askingPrice = vehicleInfo.originalSellValue
  local negotiatedPrice = vehicleInfo.Value
  if not askingPrice or not negotiatedPrice or negotiatedPrice >= askingPrice then return end

  gameplay_achievement.unlockAchievement("GOOD_DEAL")
  if negotiatedPrice <= askingPrice * 0.8 then
    gameplay_achievement.unlockAchievement("DEAL_MAKER")
  end
end

local function payForVehicle()
  local label = {
    txt = "ui.career.vehicleShopping.boughtVehicle",
    context = {vehicleName = purchaseData.vehicleInfo.niceName},
  }
  if purchaseData.tradeInVehicleInfo then
    label = {
      txt = "ui.career.vehicleShopping.boughtVehicleWithTradeIn",
      context = {
        vehicleName = purchaseData.vehicleInfo.niceName,
        id = purchaseData.tradeInVehicleInfo.id,
        tradeInVehicleName = purchaseData.tradeInVehicleInfo.niceName,
      },
    }
  end
  career_modules_playerAttributes.addAttributes({money=-purchaseData.prices.finalPrice}, {tags={"vehicleBought","buying"},label=label})
  if purchaseData.prices.finalPrice >= 100000 then
    gameplay_achievement.unlockAchievement("SERIOUS_PURCHASE")
  end
  unlockNegotiationAchievements()
  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  vehicleWatchlist[purchaseData.shopId] = nil
end

local deleteAddedVehicle
local function buyVehicleAndSendToGarage(options)
  if career_modules_playerAttributes.getAttributeValue("money") < purchaseData.prices.finalPrice then
    return
  end
  payForVehicle()

  local closestGarage = career_modules_inventory.getClosestGarage()
  local garagePos, _ = freeroam_facilities.getGaragePosRot(closestGarage)
  local delay = purchaseData.vehicleInfo.pos and getDeliveryDelay(purchaseData.vehicleInfo.pos:distance(garagePos)) or 0
  spawnFollowUpActions = {delayAccess = delay, licensePlateText = options.licensePlateText}
  local veh = spawnVehicle(purchaseData.vehicleInfo)
  if career_career.hasBoughtStarterVehicle() then
    deleteAddedVehicle = true
  else
    freeroam_facilities.teleportToGarage(closestGarage.id, veh, false)
    gameplay_walk.getInVehicle(veh)
    commands.setGameCamera()
  end
end

local function buyVehicleAndSpawnInParkingSpot(options)
  if career_modules_playerAttributes.getAttributeValue("money") < purchaseData.prices.finalPrice then
    return
  end
  payForVehicle()
  spawnFollowUpActions = {licensePlateText = options.licensePlateText}
  local newVehObj = spawnVehicle(purchaseData.vehicleInfo, purchaseData.vehicleInfo.sellerId)
  if gameplay_walk.isWalking() then
    gameplay_walk.setRot(newVehObj:getPosition() - getPlayerVehicle(0):getPosition())
  end
end

local function navigateToPos(pos)
  -- TODO this should better take vec3s directly
  core_groundMarkers.setPath(vec3(pos.x, pos.y, pos.z))
  extensions.ui_router.navigate("play")
end

local originComputerId
local function openShop(seller, _originComputerId, screenTag)
  currentSeller = seller
  originComputerId = _originComputerId

  updateVehicleList()

  local sellerInfos = {}
  for id, vehicleInfo in ipairs(vehiclesInShop) do
    if vehicleInfo.pos then
      if vehicleInfo.sellerId ~= "private" then
        local sellerInfo = sellerInfos[vehicleInfo.sellerId]
        if sellerInfo then
          vehicleInfo.distance = sellerInfo.distance
          vehicleInfo.quickTravelPrice = sellerInfo.quicktravelPrice
        else
          local quicktravelPrice, distance = career_modules_quickTravel.getPriceForQuickTravel(vehicleInfo.pos)
          sellerInfos[vehicleInfo.sellerId] = {distance = distance, quicktravelPrice = quicktravelPrice}
          vehicleInfo.distance = distance
          vehicleInfo.quickTravelPrice = quicktravelPrice
        end
      else
        local quicktravelPrice, distance = career_modules_quickTravel.getPriceForQuickTravel(vehicleInfo.pos)
        vehicleInfo.distance = distance
        vehicleInfo.quickTravelPrice = quicktravelPrice
      end
    else
      vehicleInfo.distance = 0
    end
  end

  local computer
  if currentSeller then
    local tetherPos = freeroam_facilities.getAverageDoorPositionForFacility(freeroam_facilities.getFacility("dealership",currentSeller))
    tether = career_modules_tether.startSphereTether(tetherPos, tetherRange, M.endShopping)
  elseif originComputerId then
    computer = freeroam_facilities.getFacility("computer", originComputerId)
    tether = career_modules_tether.startDoorTether(computer.doors[1], nil, M.endShopping)
  end

  -- store route-relevant UI state in Lua. selectedSellerId defaults to the
  -- physical dealership when shopping at one, or nil (seller grid) from a computer.
  shoppingScreenTag = screenTag
  buyingAvailable = (not computer or computer.functions.vehicleShop) and true or false
  marketplaceAvailable = (career_career.hasBoughtStarterVehicle() and not currentSeller) and true or false
  selectedSellerId = currentSeller

  -- physical dealership: go straight to its vehicle list. computer: show the
  -- seller grid first (VehicleShoppingMain only renders the grid; the list lives
  -- on the .vehicles child route).
  if currentSeller then
    extensions.ui_router.navigate("career.computer.vehicleShopping.vehicles")
  else
    extensions.ui_router.navigate("career.computer.vehicleShopping")
  end
  extensions.hook("onVehicleShoppingMenuOpened", {seller = currentSeller})
end

local function endShopping()
  career_career.closeAllMenus()
  extensions.hook("onVehicleShoppingMenuClosed", {})
end

local function cancelShopping()
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
end

-- Router back handler: computer-origin shopping returns to the computer menu,
-- dealership-origin shopping exits to play (mirrors cancelShopping).
local function requestExit()
  cancelShopping()
end

-- Router lifecycle: emit the shopping data once the destination view has mounted.
local function onRouteMount(context, toRoute, fromRoute, data)
  sendShoppingDataToUI()
end

-- UI selected a dealership/private seller: store it, notify listeners (tutorial),
-- push fresh data, then navigate to the vehicle list screen.
local function selectSeller(sellerId)
  if type(sellerId) ~= "string" or sellerId == "" then return end
  selectedSellerId = sellerId
  extensions.hook("onVehicleShoppingSelectedSellerIdChanged", sellerId)
  sendShoppingDataToUI()
  extensions.ui_router.navigate("career.computer.vehicleShopping.vehicles")
end

local function clearSelectedSeller()
  selectedSellerId = nil
  extensions.hook("onVehicleShoppingSelectedSellerIdChanged", nil)
  sendShoppingDataToUI()
end

local function requestVehicleListExit()
  if currentSeller then
    return cancelShopping()
  end
  clearSelectedSeller()
  return extensions.ui_router.navigate("career.computer.vehicleShopping")
end

local function getSelectedSellerBreadcrumbTitle()
  if not selectedSellerId then return nil end
  if selectedSellerId == "private" then
    return _tr("ui.career.vehicleShopping.privateSellers")
  end
  local dealership = freeroam_facilities.getDealership(selectedSellerId)
  if dealership and dealership.name then
    return _tr(dealership.name)
  end
  return nil
end

local function onShoppingMenuClosed()
  if tether then tether.remove = true tether = nil end
end

local function getVehiclesInShop()
  return vehiclesInShop
end

local removeNonUsedPlayerVehicles
local function removeUnusedPlayerVehicles()
  for inventoryId, vehId in pairs(career_modules_inventory.getMapInventoryIdToVehId()) do
    if inventoryId ~= career_modules_inventory.getCurrentVehicle() then
      career_modules_inventory.removeVehicleObject(inventoryId)
    end
  end
end

local function buySpawnedVehicle(buyVehicleOptions)
  if career_modules_playerAttributes.getAttributeValue("money") >= purchaseData.prices.finalPrice then
    local vehObj = getObjectByID(purchaseData.vehId)
    payForVehicle()
    local newInventoryId = career_modules_inventory.addVehicle(vehObj:getID(), nil, {finalPrice = purchaseData.prices.finalPrice})
    if buyVehicleOptions.licensePlateText then
      career_modules_inventory.setLicensePlateText(newInventoryId, buyVehicleOptions.licensePlateText)
    end
    removeNonUsedPlayerVehicles = true
    if be:getPlayerVehicleID(0) == vehObj:getID() then
      career_modules_inventory.enterVehicle(newInventoryId)
    end
  end
end

local function sendPurchaseDataToUi()
  local vehicleShopInfo = deepcopy(getVehicleInfoByShopId(purchaseData.shopId))
  vehicleShopInfo.shopId = purchaseData.shopId
  vehicleShopInfo.niceName = vehicleShopInfo.Brand .. " " .. vehicleShopInfo.Name
  vehicleShopInfo.deliveryDelay = getDeliveryDelay(vehicleShopInfo.distance)
  purchaseData.vehicleInfo = vehicleShopInfo
  --purchaseData.vehicleInfo.Value = 1000

  local discountPercentage = vehicleShopInfo.discountPercentage or 0
  if discountPercentage > 0 then
    vehicleShopInfo.negotiationPossible = false
    vehicleShopInfo.negotiationDisabledReason = _tr("ui.career.vehiclePurchase.negotiationUnavailableDiscounted")
  end
  local discount = 0
  if discountPercentage > 0 then
    discount = -1 * (vehicleShopInfo.Value * (discountPercentage / 100))
  end

  local tradeInValue = purchaseData.tradeInVehicleInfo and purchaseData.tradeInVehicleInfo.Value or 0
  local taxableBase = math.max(vehicleShopInfo.Value + vehicleShopInfo.fees - tradeInValue + discount, 0)
  local taxes = taxableBase * salesTax
  local finalPrice = taxableBase + taxes
  purchaseData.prices = {fees = vehicleShopInfo.fees, taxes = taxes, finalPrice = finalPrice, customLicensePlate = customLicensePlatePrice, discount = discount}
  local spawnedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
  purchaseData.vehId = spawnedVehicleInfo and spawnedVehicleInfo.vehId

  if not purchaseData.insuranceId then
    if vehicleShopInfo.insuranceClass and vehicleShopInfo.insuranceClass.id then
      purchaseData.insuranceId = career_modules_insurance_insurance.getDefaultInsuranceForClassId(vehicleShopInfo.insuranceClass.id).id
    end
  end

  purchaseData.insuranceOptions = {
    insuranceId = purchaseData.insuranceId,
    shopId = purchaseData.shopId,
  }
  -- -1 means no insurance picked
  if purchaseData.insuranceId >= 0 then
    local insuranceInfo = career_modules_insurance_insurance.getInsuranceDataById(purchaseData.insuranceId)
    purchaseData.insuranceOptions.spendingReason = core_locales.contextTranslate("ui.career.vehicleShopping.insurancePolicySpending", {
      policyName = core_locales.translateWithOrWithoutContext(insuranceInfo.name),
    })
    purchaseData.insuranceOptions.priceMoney = career_modules_insurance_insurance.calculateAddVehiclePrice(purchaseData.insuranceId, purchaseData.vehicleInfo.Value)
  end

  local data = {
    vehicleInfo = purchaseData.vehicleInfo,
    playerMoney = career_modules_playerAttributes.getAttributeValue("money"),
    inventoryHasFreeSlot = career_modules_inventory.hasFreeSlot(),
    purchaseType = purchaseData.purchaseType,
    tradeInVehicleInfo = purchaseData.tradeInVehicleInfo,
    discountPercentage = discountPercentage,
    prices = purchaseData.prices,
    alreadyDidTestDrive = career_modules_inspectVehicle.getDidTestDrive(),
    insuranceOptions = purchaseData.insuranceOptions,
  }

  local atDealership = (purchaseData.purchaseType == "instant" and currentSeller) or (purchaseData.purchaseType == "inspect" and vehicleShopInfo.sellerId ~= "private")

  -- allow trade in only when at a dealership
  if atDealership then
    data.tradeInEnabled = true
  end

  -- allow location selection in all cases except when on the computer
  if (atDealership or vehicleShopInfo.sellerId == "private") then
    data.locationSelectionEnabled = true
  end

  if not career_career.hasBoughtStarterVehicle() then
    data.forceNoDelivery = true
  end

  guihooks.trigger("vehiclePurchaseData", data)
end

local function resetShopState()
  vehiclesInShop = {}
  sellersInfos = {}
  vehicleWatchlist = {}
  staticSellerState = {}
  currentSeller = nil
  selectedSellerId = nil
  shoppingScreenTag = nil
  buyingAvailable = true
  marketplaceAvailable = true
end

local function onAddedVehiclePartsToInventory(inventoryId, newParts)

  -- Update the vehicle parts with the actual parts that are installed (they differ from the pc file)
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]

  -- set the year of the vehicle
  vehicle.year = purchaseData and purchaseData.vehicleInfo.year or 1990

  vehicle.originalParts = {}
  local allSlotsInVehicle = {main = true}

  for partName, part in pairs(newParts) do
    part.year = vehicle.year
    vehicle.originalParts[part.containingSlot] = {name = part.name, value = part.value}

    if part.description.slotInfoUi then
      for slot, _ in pairs(part.description.slotInfoUi) do
        allSlotsInVehicle[slot] = true
      end
    end
  end

  vehicle.changedSlots = {}

  if deleteAddedVehicle then
    career_modules_inventory.removeVehicleObject(inventoryId)
    deleteAddedVehicle = nil
  end

  endShopping()

  extensions.hook("onVehicleAddedToInventory", {inventoryId = inventoryId, vehicleInfo = purchaseData and purchaseData.vehicleInfo, purchaseData = purchaseData})

  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end
end

local function onEnterVehicleFinished()
  if removeNonUsedPlayerVehicles then
   --removeUnusedPlayerVehicles()
   removeNonUsedPlayerVehicles = nil
  end
end

local function startInspectionWorkitem(job, vehicleInfo, teleportToVehicle)
  ui_fadeScreen.start(0.5)
  job.sleep(1.0)
  extensions.ui_router.navigate("play")
  career_modules_inspectVehicle.startInspection(vehicleInfo, teleportToVehicle)
  job.sleep(0.5)
  ui_fadeScreen.stop(0.5)
  job.sleep(1.0)

  --notify other extensions
  extensions.hook("onVehicleShoppingVehicleShown", {vehicleInfo = vehicleInfo})
end

local function showVehicle(shopId)
  local vehicleInfo = getVehicleInfoByShopId(shopId)
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo)
end

local function quickTravelToVehicle(shopId)
  local vehicleInfo = getVehicleInfoByShopId(shopId)
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo, true)
end

local function openPurchaseMenu(purchaseType, shopId, insuranceId)
  vehicleWatchlist[shopId] = "unsold"
  extensions.ui_router.navigate("career.computer.vehicleShopping.vehicles.vehiclePurchase")
  purchaseData = {shopId = shopId, purchaseType = purchaseType, insuranceId = insuranceId}
  extensions.hook("onVehicleShoppingPurchaseMenuOpened", {purchaseType = purchaseType, shopId = shopId})
end

local function updateInsuranceSelection(insuranceId)
  if purchaseData then
    purchaseData.insuranceId = insuranceId
    sendPurchaseDataToUi()
  end
end

local function buyFromPurchaseMenu(purchaseType, options)
  if purchaseData.tradeInVehicleInfo then
    career_modules_inventory.removeVehicle(purchaseData.tradeInVehicleInfo.id)
  end

  local buyVehicleOptions = {licensePlateText = options.licensePlateText}
  if purchaseType == "inspect" then
    if options.makeDelivery then
      deleteAddedVehicle = true
    end
    career_modules_inspectVehicle.buySpawnedVehicle(buyVehicleOptions)
  elseif purchaseType == "instant" then
    career_modules_inspectVehicle.showVehicle(nil)
    if options.makeDelivery then
      buyVehicleAndSendToGarage(buyVehicleOptions)
    else
      buyVehicleAndSpawnInParkingSpot(buyVehicleOptions)
    end
  end
  if buyVehicleOptions.licensePlateText then
    career_modules_playerAttributes.addAttributes({money=-purchaseData.prices.customLicensePlate}, {tags={"buying"}, label="ui.career.vehicleShopping.boughtCustomLicensePlate"})
  end

  -- store insurance ID in purchaseData to be applied when vehicle is added to inventory
  if options.insuranceId then
    purchaseData.insuranceId = options.insuranceId
  end

  -- remove the vehicle from the shop
  for i, vehInfo in ipairs(vehiclesInShop) do
    if vehInfo.shopId == purchaseData.vehicleInfo.shopId then
      table.remove(vehiclesInShop, i)
      break
    end
  end
end

local function cancelPurchase(purchaseType)
  if purchaseType == "inspect" then
    career_career.closeAllMenus()
  elseif purchaseType == "instant" then
    openShop(currentSeller, originComputerId)
  end
end

local function requestPurchaseExit()
  local purchaseType = purchaseData and purchaseData.purchaseType
  if purchaseType == "inspect" then
    career_career.closeAllMenus()
    return
  end
  extensions.ui_router.navigate("career.computer.vehicleShopping.vehicles")
end

local function removeTradeInVehicle()
  purchaseData.tradeInVehicleInfo = nil
  sendPurchaseDataToUi()
end

local function openInventoryMenuForTradeIn()
  career_modules_inventory.openMenu(
    {{
      callback = function(inventoryId)
        local vehicle = career_modules_inventory.getVehicles()[inventoryId]
        if vehicle then
          purchaseData.tradeInVehicleInfo = {id = inventoryId, niceName = vehicle.niceName, Value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId), takesNoInventorySpace = vehicle.takesNoInventorySpace}
          guihooks.trigger('UINavigation', 'back', 1)
        end
      end,
      buttonText = _tr("ui.career.vehicleShopping.tradeIn"),
      repairRequired = true,
      ownedRequired = true,
    }}, _tr("ui.career.vehicleShopping.tradeIn"),
    {
      repairEnabled = false,
      sellEnabled = false,
      favoriteEnabled = false,
      storingEnabled = false,
      returnLoanerEnabled = false
    },
    "career.computer.vehicleShopping.vehicles.vehiclePurchase"
  )
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end

  resetShopState()

  -- load from saveslot
  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot or not savePath then return end

  local saveInfo = savePath and jsonReadFile(savePath .. "/info.json")
  local outdated = not saveInfo or saveInfo.version < moduleVersion

  local data = not outdated and jsonReadFile(savePath .. "/career/vehicleShop.json")
  if data then
    vehiclesInShop = data.vehiclesInShop or {}
    sellersInfos = data.sellersInfos or {}
    vehicleShopDirtyDate = data.dirtyDate
    vehicleWatchlist = data.vehicleWatchlist or {}
    staticSellerState = data.staticSellerState or {}

    for _, vehicleInfo in ipairs(vehiclesInShop) do
      vehicleInfo.pos = vec3(vehicleInfo.pos)
    end
  end
end

local function onSaveCurrentProfile(currentSavePath)
  local data = {}
  data.vehiclesInShop = vehiclesInShop
  data.sellersInfos = sellersInfos
  data.dirtyDate = vehicleShopDirtyDate
  data.vehicleWatchlist = vehicleWatchlist
  data.staticSellerState = staticSellerState
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/vehicleShop.json", data, true)
end

local function getCurrentSellerId()
  return currentSeller
end

local function onComputerAddFunctions(menuData, computerFunctions)
  local computerFunctionData = {
    id = "vehicleShop",
    routeTarget = "career.computer.vehicleShopping",
    label = _tr("ui.career.vehicleShopping.vehicleMarketplace"),
    callback = function() openShop(nil, menuData.computerFacility.id) end,
    order = 10
  }
  -- tutorial active
  --[[
  if menuData.tutorialPartShoppingActive or menuData.tutorialTuningActive then
    computerFunctionData.disabled = true
    computerFunctionData.reason = career_modules_computer.reasons.tutorialActive
  end
  ]]
  -- generic gameplay reason
  local reason = career_modules_permissions.getStatusForTag("vehicleShopping")
  if not reason.allow then
    computerFunctionData.disabled = true
  end
  if reason.permission ~= "allowed" then
    computerFunctionData.reason = reason
  end

  computerFunctions.general[computerFunctionData.id] = computerFunctionData
end

local currentUiState
local function onUpdate()
  if tableIsEmpty(vehicleWatchlist) or (currentUiState and currentUiState ~= "play") then return end
  local currentTime = os.time()
  local inspectedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
  for shopId, status in pairs(vehicleWatchlist) do
    if status == "unsold" and (not inspectedVehicleInfo or inspectedVehicleInfo.shopId ~= shopId) then
      local vehicleInfo = getVehicleInfoByShopId(shopId)
      if vehicleInfo then
        local offerTime = currentTime - vehicleInfo.generationTime
        if offerTime > vehicleInfo.offerTTL then
          vehicleInfo.soldFor = generateSoldVehicleValue(shopId)
          vehicleWatchlist[shopId] = "sold"
          guihooks.trigger("toastrMsg", {
            type = "info",
            title = _tr("ui.career.vehicleShopping.watchlistVehicleSoldTitle"),
            msg = core_locales.contextTranslate("ui.career.vehicleShopping.watchlistVehicleSoldMsg", {
              vehicleName = core_locales.translateWithOrWithoutContext(vehicleInfo.Name),
              price = string.format("%.2f", vehicleInfo.soldFor),
            }),
          })
          gameplay_achievement.unlockAchievement("TOO_LATE")
          break
        end
      end
    end
  end
end

local function onUiChangedState(toState)
  currentUiState = toState
end

M.openShop = openShop
M.showVehicle = showVehicle
M.navigateToPos = navigateToPos
M.buySpawnedVehicle = buySpawnedVehicle
M.quickTravelToVehicle = quickTravelToVehicle
M.updateVehicleList = updateVehicleList
M.getShoppingData = getShoppingData
M.sendShoppingDataToUI = sendShoppingDataToUI
M.onRouteMount = onRouteMount
M.selectSeller = selectSeller
M.getSelectedSellerBreadcrumbTitle = getSelectedSellerBreadcrumbTitle
M.sendPurchaseDataToUi = sendPurchaseDataToUi
M.getCurrentSellerId = getCurrentSellerId
M.getVisualValueFromMileage = getVisualValueFromMileage
M.getVehicleInfoByShopId = getVehicleInfoByShopId

M.openPurchaseMenu = openPurchaseMenu
M.updateInsuranceSelection = updateInsuranceSelection
M.buyFromPurchaseMenu = buyFromPurchaseMenu
M.openInventoryMenuForTradeIn = openInventoryMenuForTradeIn
M.removeTradeInVehicle = removeTradeInVehicle

M.endShopping = endShopping
M.cancelShopping = cancelShopping
M.requestExit = requestExit
M.requestVehicleListExit = requestVehicleListExit
M.cancelPurchase = cancelPurchase
M.requestPurchaseExit = requestPurchaseExit

M.getVehiclesInShop = getVehiclesInShop

M.onVehicleSpawnFinished = onVehicleSpawnFinished
M.onAddedVehiclePartsToInventory = onAddedVehiclePartsToInventory
M.onEnterVehicleFinished = onEnterVehicleFinished
M.onExtensionLoaded = onExtensionLoaded
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onShoppingMenuClosed = onShoppingMenuClosed
M.onComputerAddFunctions = onComputerAddFunctions
M.onUpdate = onUpdate
M.onUiChangedState = onUiChangedState

M.getEligibleVehiclesWithoutDealershipVehicles = getEligibleVehiclesWithoutDealershipVehicles

return M