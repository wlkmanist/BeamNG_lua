-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career', 'career_modules_inspectVehicle', 'util_configListGenerator'}

local jbeamIO = require('jbeam/io')
local routePlanner = require('gameplay/route/route')()
local imgui = ui_imgui

local vehicleDeliveryDelay = 60
local shopGenerationDelay = 15 * 60
local salesTax = 0.07

local starterVehicleMileages = {bx = 165746239, etki = 285817342, covet = 80174611}
local starterVehicleYears = {bx = 1990, etki = 1989, covet = 1989}

local lastGenerationTime = 0

local vehiclesInShop
local currentSeller

local purchaseData
local paySoundId

local tether
local tetherRange = 4 --meter

local function convertKeysToStrings(t)
  local newTable = {}
  for k,v in pairs(t) do
    newTable[tostring(k)] = v
  end
  return newTable
end

local function getShoppingData()
  local data = {}
  data.vehiclesInShop = convertKeysToStrings(vehiclesInShop)
  data.currentSeller = currentSeller
  if currentSeller then
    local dealership = freeroam_facilities.getDealership(currentSeller)
    data.currentSellerNiceName = dealership.name
  end
  data.playerAttributes = career_modules_playerAttributes.getAllAttributes()
  data.inventoryHasFreeSlot = career_modules_inventory.hasFreeSlot()
  data.numberOfFreeSlots = career_modules_inventory.getNumberOfFreeSlots()

  data.tutorialPurchase = (not career_modules_linearTutorial.getTutorialFlag("purchasedFirstCar")) or nil

  local permissionStatus, permissionLabel = career_modules_permissions.getStatusForTag("vehicleShopping")

  data.disableShopping = false
  if permissionStatus == "forbidden" then
    data.disableShopping = true
    data.disableShoppingReason = permissionLabel
  end

  return data
end

local function generateVehicleList()
  local eligibleVehicles = util_configListGenerator.getEligibleVehicles(not career_career.hasBoughtStarterVehicle())
  local sellers = {}

  -- get the dealerships from the level
  local facilities = deepcopy(freeroam_facilities.getFacilities(getCurrentLevelIdentifier()))
  for _, dealership in ipairs(facilities.dealerships) do
    if career_career.hasBoughtStarterVehicle() then
      dealership.filter = dealership.filter or {}
      table.insert(sellers, dealership)
    else
      if dealership.containsStarterVehicles then
        dealership.filter = {whiteList = {careerStarterVehicle = {true}}}
        dealership.subFilters = nil
        table.insert(sellers, dealership)
      end
    end
  end

  if career_career.hasBoughtStarterVehicle() then
    for _, dealership in ipairs(facilities.privateSellers) do
      table.insert(sellers, dealership)
    end
  end
  table.sort(sellers, function(a,b) return a.id < b.id end)

  vehiclesInShop = {}
  for _, seller in ipairs(sellers) do
    local randomVehicleInfos = util_configListGenerator.getRandomVehicleInfos(seller, 10, eligibleVehicles)

    for _, randomVehicleInfo in ipairs(randomVehicleInfos) do
      randomVehicleInfo.sellerId = seller.id
      randomVehicleInfo.sellerName = seller.name
      local filter = randomVehicleInfo.filter
      local years = randomVehicleInfo.Years or randomVehicleInfo.aggregates.Years

      if career_career.hasBoughtStarterVehicle() then
        randomVehicleInfo.year = years and math.random(years.min, years.max) or 2023
        if filter.whiteList and filter.whiteList.Mileage then
          randomVehicleInfo.Mileage = randomGauss3()/3 * (filter.whiteList.Mileage.max - filter.whiteList.Mileage.min) + filter.whiteList.Mileage.min
        else
          randomVehicleInfo.Mileage = 0
        end
      else
        -- values for the starter vehicles
        randomVehicleInfo.year = starterVehicleYears[randomVehicleInfo.model_key]
        randomVehicleInfo.Mileage = starterVehicleMileages[randomVehicleInfo.model_key]
      end

      randomVehicleInfo.Value = career_modules_valueCalculator.getAdjustedVehicleBaseValue(randomVehicleInfo.Value, {mileage = randomVehicleInfo.Mileage, age = 2023 - randomVehicleInfo.year})
      randomVehicleInfo.shopId = tableSize(vehiclesInShop) + 1

      -- compute taxes and fees
      randomVehicleInfo.fees = seller.fees or 0

      if seller.id == "private" then
        local parkingSpots = gameplay_parking.getParkingSpots().byName
        local parkingSpotNames = tableKeys(parkingSpots)

        -- get a random parking spot on the map
        -- TODO needs some error handling when there are no parking spots
        local parkingSpotName, parkingSpot
        repeat
          parkingSpotName = parkingSpotNames[math.random(tableSize(parkingSpotNames))]
          parkingSpot = parkingSpots[parkingSpotName]
        until not parkingSpot.customFields.tags.notprivatesale

        randomVehicleInfo.parkingSpotName = parkingSpotName
        randomVehicleInfo.pos = parkingSpot.pos
      else
        local dealership = freeroam_facilities.getDealership(seller.id)
        randomVehicleInfo.pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
      end

      local requiredInsurance = career_modules_insurance.getMinApplicablePolicyFromVehicleShoppingData(randomVehicleInfo)
      if requiredInsurance then
        randomVehicleInfo.requiredInsurance = requiredInsurance
      end
      vehiclesInShop[randomVehicleInfo.shopId] = randomVehicleInfo
    end
  end
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

local function spawnVehicle(vehicleInfo, dealershipToMoveTo, followUpAction)
  local spawnOptions = {}
  spawnOptions.config = vehicleInfo.key
  spawnOptions.autoEnterVehicle = false
  local newVeh = core_vehicles.spawnNewVehicle(vehicleInfo.model_key, spawnOptions)
  if dealershipToMoveTo then moveVehicleToDealership(newVeh, dealershipToMoveTo) end
  core_vehicleBridge.executeAction(newVeh,'setIgnitionLevel', 0)

  local closestGarage = career_modules_inventory.getClosestGarage()
  local garagePos, _ = freeroam_facilities.getGaragePosRot(closestGarage)
  local delay = getDeliveryDelay(vehicleInfo.pos:distance(garagePos))
  newVeh:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, %f) obj:queueGameEngineLua('career_modules_vehicleShopping.onVehicleSpawnFinished(%d, %d, %d)')", vehicleInfo.Mileage, getVisualValueFromMileage(vehicleInfo.Mileage), newVeh:getID(), followUpAction or -1, delay))
  return newVeh
end

local function onVehicleSpawnFinished(vehId, followUpAction, delay)
  local veh = be:getObjectByID(vehId)
  local inventoryId = career_modules_inventory.addVehicle(vehId)
  if followUpAction == 1 then -- add to inventory
    career_modules_inventory.delayVehicleAccess(inventoryId, delay, "bought")
  end
end

local function payForVehicle()
  local label = string.format("Bought a vehicle: %s", purchaseData.vehicleInfo.niceName)
  if purchaseData.tradeInVehicleInfo then
    label = label .. string.format(" and traded in vehicle id %d: %s", purchaseData.tradeInVehicleInfo.id, purchaseData.tradeInVehicleInfo.niceName)
  end
  career_modules_playerAttributes.addAttributes({money=-purchaseData.prices.finalPrice}, {tags={"vehicleBought","buying"},label=label})
  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
end

local deleteAddedVehicle
local function buyVehicleAndSendToGarage()
  if career_modules_playerAttributes.getAttributeValue("money") < purchaseData.prices.finalPrice
  or not career_modules_inventory.hasFreeSlot() then
    return
  end
  payForVehicle()
  spawnVehicle(purchaseData.vehicleInfo, nil, 1)
  deleteAddedVehicle = true
end

local function buyVehicleAndSpawnInParkingSpot()
  if career_modules_playerAttributes.getAttributeValue("money") < purchaseData.prices.finalPrice
  or not career_modules_inventory.hasFreeSlot() then
    return
  end
  payForVehicle()
  local newVehObj = spawnVehicle(purchaseData.vehicleInfo, purchaseData.vehicleInfo.sellerId)
  if gameplay_walk.isWalking() then
    gameplay_walk.setRot(newVehObj:getPosition() - getPlayerVehicle(0):getPosition())
  end
end

local function navigateToPos(pos)
  -- TODO this should better take vec3s directly
  core_groundMarkers.setFocus(vec3(pos.x, pos.y, pos.z))
  guihooks.trigger('ChangeState', {state = 'play', params = {}})
end

local function getDistanceToPoint(pos)
  routePlanner:setupPath(getPlayerVehicle(0):getPosition(), pos)
  return routePlanner.path[1].distToTarget
end

-- TODO At this point, the part conditions of the previous vehicle should have already been saved. for example when entering the garage
local originComputerId
local function openShop(seller, _originComputerId)
  currentSeller = seller
  originComputerId = _originComputerId

  local currentTime = os.time()
  if (currentTime > lastGenerationTime + shopGenerationDelay) and not career_modules_inspectVehicle.getSpawnedVehicleInfo() then
    log("I", "Career", "New vehicle shop seed")
    lastGenerationTime = currentTime
    vehiclesInShop = nil
  end

  if not vehiclesInShop then
    math.randomseed(lastGenerationTime - (lastGenerationTime % shopGenerationDelay))
    generateVehicleList()
  end

  for id, vehicleInfo in ipairs(vehiclesInShop) do
    if vehicleInfo.pos then
      vehicleInfo.distance = getDistanceToPoint(vehicleInfo.pos)
      vehicleInfo.quickTravelPrice = career_modules_quickTravel.getPriceForQuickTravel(vehicleInfo.pos)
    else
      vehicleInfo.distance = 0
    end
  end

  local tetherPos = vec3()
  if currentSeller then
    tetherPos = freeroam_facilities.getAverageDoorPositionForFacility(freeroam_facilities.getFacility("dealership",currentSeller))
  elseif originComputerId then
    tetherPos = freeroam_facilities.getAverageDoorPositionForFacility(freeroam_facilities.getFacility("computer",originComputerId))
  end

  tether = career_modules_tether.startSphereTether(tetherPos, tetherRange, M.endShopping)

  guihooks.trigger('ChangeState', {state = 'vehicleShopping', params = {}})
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

local function buySpawnedVehicle()
  if career_modules_playerAttributes.getAttributeValue("money") >= purchaseData.prices.finalPrice
  and career_modules_inventory.hasFreeSlot() then
    local vehObj = be:getObjectByID(purchaseData.vehId)
    local plateText = core_vehicles.regenerateVehicleLicenseText(vehObj)
    core_vehicles.setPlateText(plateText, vehObj:getID())
    payForVehicle()
    local newInventoryId = career_modules_inventory.addVehicle(vehObj:getID())
    removeNonUsedPlayerVehicles = true
    if be:getPlayerVehicleID(0) == vehObj:getID() then
      career_modules_inventory.enterVehicle(newInventoryId)
    end
  end
end

local function sendPurchaseDataToUi()
  local vehicleShopInfo = deepcopy(getVehiclesInShop()[purchaseData.shopId])
  vehicleShopInfo.shopId = purchaseData.shopId
  vehicleShopInfo.niceName = vehicleShopInfo.Brand .. " " .. vehicleShopInfo.Name
  vehicleShopInfo.deliveryDelay = getDeliveryDelay(vehicleShopInfo.distance)
  purchaseData.vehicleInfo = vehicleShopInfo

  local tradeInValue = purchaseData.tradeInVehicleInfo and purchaseData.tradeInVehicleInfo.Value or 0
  local taxes = math.max((vehicleShopInfo.Value + vehicleShopInfo.fees - tradeInValue) * salesTax, 0)
  local finalPrice = vehicleShopInfo.Value + vehicleShopInfo.fees + taxes - tradeInValue
  purchaseData.prices = {fees = vehicleShopInfo.fees, taxes = taxes, finalPrice = finalPrice}
  local spawnedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
  purchaseData.vehId = spawnedVehicleInfo and spawnedVehicleInfo.vehId

  local data = {
    vehicleInfo = purchaseData.vehicleInfo,
    playerMoney = career_modules_playerAttributes.getAttributeValue("money"),
    inventoryHasFreeSlot = career_modules_inventory.hasFreeSlot(),
    purchaseType = purchaseData.purchaseType,
    forceTradeIn = not career_modules_linearTutorial.getTutorialFlag("purchasedFirstCar") or nil,
    tradeInVehicleInfo = purchaseData.tradeInVehicleInfo,
    prices = purchaseData.prices
  }

  local playerInsuranceData = career_modules_insurance.getPlayerPolicyData()[data.vehicleInfo.requiredInsurance.id]
  if playerInsuranceData then
    data.ownsRequiredInsurance = playerInsuranceData.owned
  else
    data.ownsRequiredInsurance = false
  end

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

local function onClientStartMission()
  vehiclesInShop = nil
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
    vehicle.config.parts[part.slot] = part.name
    vehicle.originalParts[part.slot] = {name = part.name, value = part.value}

    if part.description.slotInfoUi then
      for slot, _ in pairs(part.description.slotInfoUi) do
        allSlotsInVehicle[slot] = true
      end
    end
    -- Also check if we do the same for part shopping or part inventory or vehicle shopping
  end

  -- remove old leftover slots that dont exist anymore
  local slotsToRemove = {}
  for slot, partName in pairs(vehicle.config.parts) do
    if not allSlotsInVehicle[slot] then
      slotsToRemove[slot] = true
    end
  end
  for slot, _ in pairs(slotsToRemove) do
    vehicle.config.parts[slot] = nil
  end

  -- every part that is now in "vehicle.config.parts", but not in "vehicle.originalParts" is either a part that no longer exists in the game or it is just some way to denote an empty slot (like "none")
  -- in both cases we change the slot to a unified ""
  for slot, partName in pairs(vehicle.config.parts) do
    if not vehicle.originalParts[slot] then
      vehicle.config.parts[slot] = ""
    end
  end

  vehicle.changedSlots = {}

  if deleteAddedVehicle then
    career_modules_inventory.removeVehicleObject(inventoryId)
    deleteAddedVehicle = nil
  end

  endShopping()
  career_modules_inspectVehicle.setInspectScreen(false)

  extensions.hook("onVehicleAddedToInventory", {inventoryId = inventoryId, vehicleInfo = purchaseData and purchaseData.vehicleInfo})

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
  career_modules_inspectVehicle.startInspection(vehicleInfo, teleportToVehicle)
  job.sleep(0.5)
  ui_fadeScreen.stop(0.5)
  job.sleep(1.0)

  --notify other extensions
  extensions.hook("onVehicleShoppingVehicleShown", {vehicleInfo = vehicleInfo})
end

local function showVehicle(shopId)
  local vehicleInfo = getVehiclesInShop()[shopId]
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo)
end

local function quickTravelToVehicle(shopId)
  local vehicleInfo = vehiclesInShop[shopId]
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo, true)
end

local function openPurchaseMenu(purchaseType, shopId)
  guihooks.trigger('ChangeState', {state = 'vehiclePurchase', params = {}})
  purchaseData = {shopId = shopId, purchaseType = purchaseType}
  extensions.hook("onVehicleShoppingPurchaseMenuOpened", {purchaseType = purchaseType, shopId = shopId})
end

local function buyFromPurchaseMenu(purchaseType, makeDelivery)
  if purchaseData.tradeInVehicleInfo then
    career_modules_inventory.removeVehicle(purchaseData.tradeInVehicleInfo.id)
  end

  if purchaseType == "inspect" then
    if makeDelivery then
      deleteAddedVehicle = true
    end
    career_modules_inspectVehicle.buySpawnedVehicle()
  elseif purchaseType == "instant" then
    career_modules_inspectVehicle.showVehicle(nil)
    if makeDelivery then
      buyVehicleAndSendToGarage()
    else
      buyVehicleAndSpawnInParkingSpot()
    end
  end

  -- remove the vehicle from the shop and update the other vehicles shopIds
  table.remove(vehiclesInShop, purchaseData.vehicleInfo.shopId)
  for id, vehInfo in ipairs(vehiclesInShop) do
    vehInfo.shopId = id
  end
end

local function cancelPurchase(purchaseType)
  if purchaseType == "inspect" then
    career_career.closeAllMenus()
  elseif purchaseType == "instant" then
    openShop(currentSeller, originComputerId)
  end
end

local function removeTradeInVehicle()
  purchaseData.tradeInVehicleInfo = nil
  sendPurchaseDataToUi()
end

local function openInventoryMenuForTradeIn()
  career_modules_inventory.openMenu(
    {{callback = function(inventoryId)
      local vehicle = career_modules_inventory.getVehicles()[inventoryId]
      if vehicle then
        purchaseData.tradeInVehicleInfo = {id = inventoryId, niceName = vehicle.niceName, Value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId)}
        guihooks.trigger('ChangeState', {state = 'vehiclePurchase', params = {}})
      end
    end, buttonText = "Trade-In", repairRequired = true}}, "Trade-In",
    {
      repairEnabled = false,
      sellEnabled = false,
      favoriteEnabled = false,
      storingEnabled = false
    },
    function()
      guihooks.trigger('ChangeState', {state = 'vehiclePurchase', params = {}})
    end
  )
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end

  -- load from saveslot
  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  if not saveSlot or not savePath then return end

  local data = jsonReadFile(savePath .. "/career/vehicleShop.json")
  if data then
    lastGenerationTime = os.time(data.lastGenerationTime)
  else
    lastGenerationTime = 0
  end
end

local function onSaveCurrentSaveSlot(currentSavePath, oldSaveDate, forceSyncSave)
  local data = {}
  data.lastGenerationTime = os.date("*t", lastGenerationTime)
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/vehicleShop.json", data, true)
end

local function getCurrentSellerId()
  return currentSeller
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["vehicleShop"] then return end
  local computerFunctionData = {
    id = "vehicleShop",
    label = "Purchase Vehicles",
    callback = function() openShop(nil, menuData.computerFacility.id) end,
    disabled = menuData.tutorialPartShoppingActive or menuData.tutorialTuningActive
  }
  computerFunctions.general[computerFunctionData.id] = computerFunctionData
end

M.openShop = openShop
M.showVehicle = showVehicle
M.navigateToPos = navigateToPos
M.buySpawnedVehicle = buySpawnedVehicle
M.quickTravelToVehicle = quickTravelToVehicle
M.generateVehicleList = generateVehicleList
M.getShoppingData = getShoppingData
M.sendPurchaseDataToUi = sendPurchaseDataToUi
M.getCurrentSellerId = getCurrentSellerId
M.getVisualValueFromMileage = getVisualValueFromMileage

M.openPurchaseMenu = openPurchaseMenu
M.buyFromPurchaseMenu = buyFromPurchaseMenu
M.openInventoryMenuForTradeIn = openInventoryMenuForTradeIn
M.removeTradeInVehicle = removeTradeInVehicle

M.endShopping = endShopping
M.cancelShopping = cancelShopping
M.cancelPurchase = cancelPurchase

M.getVehiclesInShop = getVehiclesInShop

M.onClientStartMission = onClientStartMission
M.onVehicleSpawnFinished = onVehicleSpawnFinished
M.onAddedVehiclePartsToInventory = onAddedVehiclePartsToInventory
M.onEnterVehicleFinished = onEnterVehicleFinished
M.onExtensionLoaded = onExtensionLoaded
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onShoppingMenuClosed = onShoppingMenuClosed
M.onComputerAddFunctions = onComputerAddFunctions

return M