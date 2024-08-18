-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local jbeamIO = require('jbeam/io')

local salesTax = 0.07

local shoppingSessionActive = false
local initialVehicle
local initialVehicleParts
local previewVehicle
local shoppingCart

local partsInShop = {}
local partToSlotMap
local currentVehicle
local partShopId = 0
local partsToAdd = {}
local slotToPartIdMap
local slotsNiceName = {}
local partsNiceName = {}

local tutorialPartNames = {bx_cargo_load_box_m_seat_R = true, covet_cargo_load_box_M_seat_R = true, etki_cargo_load_box_M_seat_R = true}

local tether -- tether object for aborting shopping when walking too far away

-- TODO it needs to be decided, which parts come with their own subparts when you buy them and which parts you can use the existing subparts of the vehicle for
-- for now, i will assume that parts come with default subparts, except when a fitting part is already in the vehicle

local function openUIState()
  -- TODO we send all data every time a part changes. we should send only smaller updates
  guihooks.trigger('ChangeState', {state = 'partShopping', params = {}})
end

local function getCurrentVehicleVehId()
  if not currentVehicle then return end
  return career_modules_inventory.getVehicleIdFromInventoryId(currentVehicle)
end

local function getCurrentVehicleObj()
  if not currentVehicle then return end
  return be:getObjectByID(getCurrentVehicleVehId())
end

local function generatePart(partName, currentVehicleData, availableParts, slot, vehicleObj)
  local jbeamData = jbeamIO.getPart(currentVehicleData.ioCtx, partName)
  if not jbeamData then return end

  local part = {}
  part.name = partName
  part.value = jbeamData.information.value or 100
  part.partCondition = {integrityValue = 1, odometer = 0, visualValue = 1}
  part.description = availableParts[partName] or "no description found"
  part.tags = {}
  part.slot = slot
  part.vehicleModel = vehicleObj:getJBeamFilename()
  part.year = 2023
  part.partShopId = partShopId
  partShopId = partShopId + 1

  part.finalValue = math.max(roundNear(career_modules_valueCalculator.getPartValue(part), 5) - 0.01, 0)
  return part
end

local function buildPartTree(slotName, availableParts, chosenParts, slotMap)
  local partName = chosenParts[slotName]
  local partInfo = availableParts[partName]
  local part = {name = partName, niceName = partInfo.description, slotName = slotName, slots = {}}
  partsNiceName[part.name] = part.niceName

  for slotName, slotInfo in pairs(partInfo.slotInfoUi) do
    if slotMap[slotName] and not tableIsEmpty(slotMap[slotName]) then -- Filter out slots with no possible parts
      local slotInfo = {slotName = slotName, slotNiceName = slotsNiceName[slotName]}
      table.insert(part.slots, slotInfo)

      local partInSlotName = chosenParts[slotInfo.slotName]
      if partInSlotName and partInSlotName ~= "" then
        slotInfo.part = buildPartTree(slotInfo.slotName, availableParts, chosenParts, slotMap)
      end
    end
  end
  table.sort(part.slots, function(a,b) return a.slotNiceName < b.slotNiceName end)

  return part
end

local function generatePartShop()
  local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())
  local availableParts = jbeamIO.getAvailableParts(currentVehicleData.ioCtx)
  local slotMap = jbeamIO.getAvailableSlotMap(currentVehicleData.ioCtx)
  local vehicleObj = getCurrentVehicleObj()

  -- for now: loop through the available slots for each part and create one part in the shop per slot (for parts that can fit into multiple slots)
  partsInShop = {}
  for _, partName in pairs(currentVehicleData.chosenParts) do
    if partName ~= "" then
      local partInfo = availableParts[partName]
      if partInfo.slotInfoUi then
        for slotName, slotInfo in pairs(partInfo.slotInfoUi) do
          slotsNiceName[slotName] = slotInfo.description
        end
      end

      for mainSlotName, chosenPartSlotInfo in pairs(partInfo.slotInfoUi) do
        for _, allowedSlotPartName in ipairs(slotMap[mainSlotName] or {}) do
          local part = generatePart(allowedSlotPartName, currentVehicleData, availableParts, mainSlotName, vehicleObj)
          if part.slot ~= "main" and not part.description.isAuxiliary then
            partsInShop[allowedSlotPartName] = part
          end
        end
      end
    end
  end

  partsNiceName = {}
  local partTree = buildPartTree("main", availableParts, currentVehicleData.chosenParts, slotMap)
  return partTree
end

local function buildSearchSlotList()
  local searchSlotDict = {}
  for slotName, slotNiceName in pairs(slotsNiceName) do
    local slotData = {}
    slotData.slotName = slotName
    slotData.slotNiceName = slotNiceName
    searchSlotDict[slotName] = slotData
  end

  -- Add the nice part name from the part that is in the vehicle
  for partName, part in pairs(partsInShop) do
    if not searchSlotDict[part.slot].partNiceName then
      searchSlotDict[part.slot].partNiceName = previewVehicle.config.parts[part.slot] and partsNiceName[previewVehicle.config.parts[part.slot]]
    end
  end

  local searchSlotList = {}
  for slotName, slotInfo in pairs(searchSlotDict) do
    table.insert(searchSlotList, slotInfo)
  end
  table.sort(searchSlotList, function(a,b) return a.slotNiceName < b.slotNiceName end)
  return searchSlotList
end

local function updateShoppingCart()
  shoppingCart.total = 0
  shoppingCart.partsInList = {}
  shoppingCart.partsOutList = {}
  shoppingCart.partsOut = {}
  shoppingCart.slotList = {}

  for slot, part in pairs(shoppingCart.partsIn) do
    shoppingCart.partsIn[slot] = part
    shoppingCart.partsOut[slot] = career_modules_partInventory.getInventory()[slotToPartIdMap[currentVehicle][slot]]
  end
  for slot, partName in pairs(initialVehicle.config.parts) do
    if partName ~= "" and (not previewVehicle.config.parts[slot] or previewVehicle.config.parts[slot] == "") then
      shoppingCart.partsOut[slot] = career_modules_partInventory.getInventory()[slotToPartIdMap[currentVehicle][slot]]
    end
  end

  -- Convert the partsIn/partsOut tables to lists
  local slotsAdded = {}
  local counter = 1
  for slot, part in pairs(shoppingCart.partsIn) do
    shoppingCart.slotList[counter] = slot
    shoppingCart.partsInList[counter] = part
    shoppingCart.partsOutList[counter] = shoppingCart.partsOut[part.slot]
    slotsAdded[part.slot] = true
    counter = counter + 1
  end

  for slot, part in pairs(shoppingCart.partsOut) do
    if not slotsAdded[part.slot] then
      shoppingCart.slotList[counter] = slot
      shoppingCart.partsOutList[counter] = part
      slotsAdded[part.slot] = true
      counter = counter + 1
    end
  end

  -- Calculate the total price of the whole shopping cart
  local total = 0
  for slot, part in pairs(shoppingCart.partsIn) do
    total = total + part.finalValue
  end

  shoppingCart.taxes = total * salesTax
  shoppingCart.total = total + shoppingCart.taxes
end

local function sendShoppingDataToUI()
  local partTree
  partTree = generatePartShop()

  local shoppingData = {}
  shoppingData.partsInShop = partsInShop
  shoppingData.partTree = partTree
  shoppingData.shoppingCart = shoppingCart
  shoppingData.slotsNiceName = slotsNiceName
  shoppingData.searchSlotList = buildSearchSlotList()
  shoppingData.vehicleSlotToPartMap = {}
  for partId, part in pairs(career_modules_partInventory.getInventory()) do
    if part.location == currentVehicle then
      shoppingData.vehicleSlotToPartMap[part.slot] = part
    end
  end
  if not career_modules_linearTutorial.getTutorialFlag("partShoppingComplete") then
    shoppingData.tutorialPartNames = tutorialPartNames
  end

  shoppingData.playerMoney = career_modules_playerAttributes.getAttributeValue("money")
  guihooks.trigger("partShoppingData", shoppingData)
end

local function updatePreviewVehicle(currentPartConditions)
  -- get the data
  local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())
  if not currentVehicleData then
    log('E', 'inventory', 'unable to get vehicle data')
    return false
  end
  if not currentVehicle then return end

  previewVehicle.config.parts = deepcopy(currentVehicleData.chosenParts)
  if currentPartConditions then
    previewVehicle.partConditions = currentPartConditions
  end
  updateShoppingCart()
  sendShoppingDataToUI()
  core_vehicleBridge.executeAction(be:getObjectByID(career_modules_inventory.getVehicleIdFromInventoryId(previewVehicle.id)),'setFreeze', true)
end

local originComputerId
local function startShoppingActual(_originComputerId)
  local vehicles = career_modules_inventory.getVehicles()
  shoppingCart = {partsIn = {}, partsOut = {}, total = 0, partsInList = {}, partsOutList = {}, slotList = {}}
  shoppingSessionActive = true
  slotToPartIdMap = deepcopy(career_modules_partInventory.getSlotToPartIdMap())

  initialVehicle = deepcopy(vehicles[currentVehicle])
  local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())
  initialVehicle.config.parts = deepcopy(currentVehicleData.chosenParts)

  previewVehicle = deepcopy(initialVehicle)

  partShopId = 0
  partsToAdd = {}
  generatePartShop()
  originComputerId = _originComputerId

  M.setupTether()


  openUIState()

  if gameplay_walk.isWalking() then
    gameplay_walk.setRot(getCurrentVehicleObj():getPosition() - getPlayerVehicle(0):getPosition())
  end

  core_vehicleBridge.executeAction(be:getObjectByID(career_modules_inventory.getVehicleIdFromInventoryId(previewVehicle.id)),'setFreeze', true)
  extensions.hook("onPartShoppingStarted")
end

local function setupTether()
    -- calculate the size of the vehicle to use for tethering
  local vehCenter, vehRadius = vec3(), vec3()
  local oobb = getCurrentVehicleObj():getSpawnWorldOOBB()
  for i = 0, 7 do
    vehCenter = vehCenter + oobb:getPoint(i)
  end
  vehCenter = vehCenter / 8
  vehRadius = (oobb:getPoint(0) - oobb:getPoint(6)):length()
  -- calculate computer position
  local computerPos = freeroam_facilities.getAverageDoorPositionForFacility(freeroam_facilities.getFacility("computer",originComputerId))

  local distBetweenVehicleAndComputer = (computerPos-vehCenter):length()
  -- this smoothly scales the radius from 100% for 4m or less distance to 150% for 12m or more radius
  local radiusMultipler = ((clamp(distBetweenVehicleAndComputer,4,12)-4)/16 + 1)
  -- these radii are tuned for the wcusa garage!
  tether = career_modules_tether.startCapsuleTetherBetweenStatics(computerPos, 6*radiusMultipler, vehCenter, vehRadius + (5*radiusMultipler), M.cancelShopping)
end

local function startShopping(inventoryId, _originComputerId)
  currentVehicle = inventoryId or career_modules_inventory.getCurrentVehicle()
  if not currentVehicle then
    currentVehicle = career_modules_inventory.getInventoryIdsInClosestGarage(true)
  end
  if not currentVehicle then return end

  local numberOfBrokenParts = career_modules_insurance.getNumberOfBrokenParts(career_modules_inventory.getVehicles()[currentVehicle].partConditions)
  if numberOfBrokenParts > 0 and numberOfBrokenParts < career_modules_insurance.getBrokenPartsThreshold() then
    career_modules_insurance.startRepair(currentVehicle, nil, function() startShoppingActual(_originComputerId) end)
  else
    startShoppingActual(_originComputerId)
  end
end

local function focusSlot(slot)
  local partName = previewVehicle.config.parts[slot]
  local nodeId
  for _, nodeData in ipairs(M.nodeDataFromVELua) do
    if nodeData.partOrigin == partName then
      nodeId = nodeData.cid
      break
    end
  end
  if not nodeId then return end
  local veh = getCurrentVehicleObj()
  local bb = veh:getSpawnWorldOOBB()
  core_camera.setByName(0, 'free')
  core_camera.setPosition(0, (veh:getNodePosition(nodeId)) * 2 + veh:getPosition())
  core_camera.setRotation(0, quatFromDir((veh:getNodePosition(nodeId) + veh:getPosition()) - core_camera.getPosition()))
end
M.focusSlot = focusSlot

local function getDefaultPartName(jbeamData, slotName)
  for _, slot in ipairs(jbeamData.slots2) do
    -- TODO this should probably check if "slotName" is any of the allowTypes, not just the first
    if slot.allowTypes[1] == slotName and slot.default and slot.default ~= "" then return slot.default end
  end
end

-- "parts" needs to be all parts added in this shopping session
local function getNeededAdditionalParts(parts, inventoryId)
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  local vehicleObj = be:getObjectByID(vehId)
  local jbeamFileName = vehicleObj:getJBeamFilename()
  local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())
  local availableParts = jbeamIO.getAvailableParts(currentVehicleData.ioCtx)
  local slotMap = jbeamIO.getAvailableSlotMap(currentVehicleData.ioCtx)

  -- Make a map from part to its slot
  local partToSlotMap = {}
  for slotName, partNames in pairs(slotMap) do
    for _, partName in ipairs(partNames) do
      partToSlotMap[partName] = slotName
    end
  end

  -- Make a map from slot to its part for the parts which were already in the vehicle and the parts which we want to add
  local combinedSlotToPartMap = deepcopy(slotToPartIdMap[inventoryId])
  for _, part in pairs(parts) do
    if part then
      combinedSlotToPartMap[part.slot] = true
    end
  end

  -- add the default part if the slot is empty and they have a default part
  local addedParts = false
  local resultParts = deepcopy(parts)
  for _, part in pairs(parts) do
    if part.description.slotInfoUi then
      for slotName, slotInfo in pairs(part.description.slotInfoUi) do

        if not combinedSlotToPartMap[slotName] then -- found an empty slot
          local jbeamData = jbeamIO.getPart(currentVehicleData.ioCtx, part.name)
          local partNameToGenerate = getDefaultPartName(jbeamData, slotName)

          if partNameToGenerate then -- found a default part name
            local newGeneratedPart = generatePart(partNameToGenerate, currentVehicleData, availableParts, slotName, vehicleObj)

            if newGeneratedPart then -- the default part exists in the jbeam
              resultParts[newGeneratedPart.slot] = newGeneratedPart
              addedParts = true
            end
          end
        end
      end
    end
  end

  return resultParts, addedParts
end

local function findIncompatiblePartsInShoppingCartRec(partName, availableParts, vehicleParts)
  local description = availableParts[partName]
  if not description.slotInfoUi then return end
  for slot, _ in pairs(description.slotInfoUi) do
    local subPartName = vehicleParts[slot]
    if subPartName then
      vehicleParts[slot] = nil
      if subPartName ~= "" then
        findIncompatiblePartsInShoppingCartRec(subPartName, availableParts, vehicleParts)
      end
    end
  end
end

local function findIncompatiblePartsInShoppingCart()
  local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())
  local availableParts = jbeamIO.getAvailableParts(currentVehicleData.ioCtx)

  local mainPartName = jbeamIO.getMainPartName(currentVehicleData.ioCtx)
  local vehicleParts = deepcopy(previewVehicle.config.parts)
  -- Remove all parts of the "vehicleParts" list that are in the vehicle correctly. Then only the incorrect ones will remain
  findIncompatiblePartsInShoppingCartRec(mainPartName, availableParts, vehicleParts)
  return vehicleParts
end

local function updateInstalledParts()
  if not shoppingSessionActive then return end

  previewVehicle = deepcopy(initialVehicle)
  local spawnOptions = {}
  spawnOptions.config = previewVehicle.config
  spawnOptions.keepOtherVehRotation = true
  shoppingCart.partsIn = deepcopy(partsToAdd)
  local addedParts
  repeat
    shoppingCart.partsIn, addedParts = getNeededAdditionalParts(shoppingCart.partsIn, currentVehicle)
  until not addedParts

  -- Add new parts to preview vehicle data
  for _, part in pairs(shoppingCart.partsIn) do
    spawnOptions.config.parts[part.slot] = part.name
  end

  -- Find and remove parts from the shopping cart that are not compatible anymore after the installed parts have changed
  local incompatibleParts = findIncompatiblePartsInShoppingCart()
  for slot, partName in pairs(incompatibleParts) do
    shoppingCart.partsIn[slot] = nil
    partsToAdd[slot] = nil
    spawnOptions.config.parts[slot] = nil
  end

  -- Add the partCondition of the new parts to the previewVehicle
  for _, part in pairs(shoppingCart.partsIn) do
    previewVehicle.partConditions[part.name] = part.partCondition
  end

  core_vehicles.replaceVehicle(previewVehicle.model, spawnOptions, getCurrentVehicleObj())
  getCurrentVehicleObj():queueLuaCommand(string.format("partCondition.initConditions(%s, nil, nil, nil, {%s})", serialize(previewVehicle.partConditions), serialize(career_modules_painting.getPrimerColor())))
  -- Doing the callback immediately will result in wrong values for some parts, so we do it one frame later
  core_vehicleBridge.requestValue(getCurrentVehicleObj(),
  function()
    queueCallbackInVehicle(getCurrentVehicleObj(), "career_modules_partShopping.updatePreviewVehicle", "partCondition.getConditions()")
  end
  , 'ping')
end

local function removePart(part)
  if not shoppingSessionActive then return end
  partsToAdd[part.slot] = nil
  updateInstalledParts()
end

local function installPart(part)
  if not shoppingSessionActive then return end
  part.sourcePart = true
  partsToAdd[part.slot] = part
  updateInstalledParts()

  extensions.hook("onPartShoppingPartInstalled",{part = part})
end

local function installPartByPartShopId(partShopId)
  for partName, part in pairs(partsInShop) do
    if part.partShopId == partShopId then
      installPart(part)
      return
    end
  end
end

local function removePartBySlot(slot)
  for partName, part in pairs(partsInShop) do
    if part.slot == slot then
      removePart(part)
      return
    end
  end
end

local function closeMenu()
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
  if tether then
    tether.remove = true
    tether = nil
  end
end

local function endShopping()
  shoppingSessionActive = false
  initialVehicleParts = nil
  closeMenu()
end

local function cancelShopping()
  if shoppingSessionActive then
    career_modules_inventory.spawnVehicle(currentVehicle, 2)
    endShopping()
  end
end

local function updateInventory()
  local vehicle = career_modules_inventory.getVehicles()[currentVehicle]
  for slot, part in pairs(shoppingCart.partsOut) do
    part.location = 0
    vehicle.changedSlots[slot] = true
  end

  for slot, part in pairs(shoppingCart.partsIn) do
    part.location = currentVehicle
    part.partShopId = nil
    part.sourcePart = nil
    part.finalValue = nil
    vehicle.changedSlots[slot] = true
    career_modules_partInventory.addPartToInventory(part)
  end
end

local function getBuyingLabel()
  local text = "Bought new parts: "
  for i=1,tableSize(shoppingCart.partsInList) - 1 do
    local part = shoppingCart.partsInList[i]
    text = text .. part.description.description .. ", "
  end
  local part = shoppingCart.partsInList[tableSize(shoppingCart.partsInList)]
  text = text .. part.description.description
  return text
end

local function applyShopping()
  if career_modules_playerAttributes.getAttributeValue("money") < shoppingCart.total then return end

  local vehicles = career_modules_inventory.getVehicles()
  vehicles[currentVehicle] = previewVehicle
  updateInventory()
  endShopping()
  local buyingLabel = getBuyingLabel()
  career_modules_playerAttributes.addAttributes({money=-shoppingCart.total}, {tags={"partsBought", "buying"},label=buyingLabel})
  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  else
    career_modules_inventory.updatePartConditions(nil, currentVehicle)
  end

  if not career_modules_linearTutorial.getTutorialFlag("partShoppingComplete") then
    career_career.closeAllMenus()
  end

  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')

  core_vehicleBridge.executeAction(be:getObjectByID(career_modules_inventory.getVehicleIdFromInventoryId(previewVehicle.id)),'setFreeze', false)

  extensions.hook("onPartShoppingTransactionComplete")
end

local function isShoppingSessionActive()
  return shoppingSessionActive
end

local function getPartsInShop()
  return partsInShop
end

local function getShoppingCart()
  return shoppingCart
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["partShop"] then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
    local inventoryId = vehicleData.inventoryId
    local permissionStatus, permissionLabel = career_modules_permissions.getStatusForTag("vehicleModification")

    local buttonDisabled =
      vehicleData.needsRepair or
      menuData.tutorialTuningActive or
      permissionStatus == "forbidden"

    local label = "Purchase Parts" ..(permissionLabel and ("\n"..permissionLabel) or "")

    local computerFunctionData = {
      id = "partShop",
      label = label,
      callback = function() startShopping(inventoryId, menuData.computerFacility.id) end,
      disabled = buttonDisabled
    }
    if vehicleData.needsRepair then
      computerFunctionData.disableReason = "fix vehicle body first"
    end

    computerFunctions.vehicleSpecific[inventoryId][computerFunctionData.id] = computerFunctionData
  end
end

M.startShopping = startShopping
M.installPart = installPart
M.installPartByPartShopId = installPartByPartShopId
M.removePartBySlot = removePartBySlot
M.updatePreviewVehicle = updatePreviewVehicle
M.cancelShopping = cancelShopping
M.applyShopping = applyShopping
M.sendShoppingDataToUI = sendShoppingDataToUI

M.getPartsInShop = getPartsInShop
M.getShoppingCart = getShoppingCart
M.isShoppingSessionActive = isShoppingSessionActive

M.setupTether = setupTether
M.onComputerAddFunctions = onComputerAddFunctions

return M