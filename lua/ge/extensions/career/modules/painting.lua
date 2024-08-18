-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"career_career"}

local blockedInputActions = core_input_actionFilter.createActionTemplate({"walkingMode", "bigMap"})

local inventoryId

local originComputerId
local chosenPaints
local chosenPackage
local walkingPositionBefore
local previousDefaultRotation

local prices = {
  basePrices = {
    factory = {money = {amount = 600, canBeNegative = false}},
    semiGloss = {money = {amount = 1000, canBeNegative = false}},
    gloss = {money = {amount = 1500, canBeNegative = false}},
    semiMetallic = {money = {amount = 1500, canBeNegative = false}},
    metallic = {money = {amount = 2500, canBeNegative = false}},
    matte = {money = {amount = 1800, canBeNegative = false}},
    chrome = {money = {amount = 3400, canBeNegative = false}},
    custom = {money = {amount = 4000, canBeNegative = false}},
  },
  clearcoatBase = {money = {amount = 500, canBeNegative = false}},
  clearcoatPolishFactor = {money = {amount = 1000, canBeNegative = false}},
}

local function getPrimerColor()
  local brightnessOffset = (math.random() * 2 - 1) * 0 -- no randomness for now
  local paint = {
    baseColor = {0.58 + brightnessOffset, 0.58 + brightnessOffset, 0.585 + brightnessOffset},
    clearcoat = 0,
    clearcoatRoughness = 1,
    metallic = 0,
    roughness = 0.475,
  }

  return paint
end

local function findBaseColors(partConditions)
  local colors
  for partName, partCondition in pairs(partConditions) do
    if not colors then
      if partCondition.visualState and partCondition.visualState.paint and partCondition.visualState.paint.originalPaints then
        colors = partCondition.visualState.paint.originalPaints
      end
    end
    if string.find(partName, "body") then
      if partCondition.visualState and partCondition.visualState.paint and partCondition.visualState.paint.originalPaints then
        return partCondition.visualState.paint.originalPaints
      end
    end
  end
  return colors
end

local function getPaintData()
  local data = {}
  local vehicleInfo = career_modules_inventory.getVehicles()[inventoryId]
  local partConditions = vehicleInfo.partConditions
  local colors = findBaseColors(partConditions)
  data.colors = colors
  data.prices = prices
  return data
end

local function startActual(_originComputerId)
  chosenPaints = nil
  chosenPackage = nil
  originComputerId = _originComputerId
  if originComputerId then
    guihooks.trigger('ChangeState', {state = 'painting', params = {}})
  end

  if gameplay_walk.isWalking() then
    walkingPositionBefore = getPlayerVehicle(0):getPosition()
  end

  core_input_actionFilter.setGroup('paintingBlockedActions', blockedInputActions)
  core_input_actionFilter.addAction(0, 'paintingBlockedActions', true)

  guihooks.trigger("onCareerPaintingStarted")
end

local function start(_inventoryId, _originComputerId)
  inventoryId = _inventoryId or career_modules_inventory.getInventoryIdsInClosestGarage(true)
  if not inventoryId or not career_modules_inventory.getMapInventoryIdToVehId()[inventoryId] then return end

  local numberOfBrokenParts = career_modules_insurance.getNumberOfBrokenParts(career_modules_inventory.getVehicles()[inventoryId].partConditions)
  if numberOfBrokenParts > 0 and numberOfBrokenParts < career_modules_insurance.getBrokenPartsThreshold() then
    career_modules_insurance.startRepair(inventoryId, nil, function() startActual(_originComputerId) end)
  else
    startActual(_originComputerId)
  end
end

local function close()
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
  career_modules_inventory.spawnVehicle(inventoryId, 2)

  local camData = core_camera.getCameraDataById(be:getPlayerVehicleID(0))
  if previousDefaultRotation and camData and camData.orbit then
    camData.orbit:setDefaultRotation(previousDefaultRotation)
    camData.orbit:init()
  end

  if walkingPositionBefore then
    local vehPos = getPlayerVehicle(0):getPosition()
    core_vehicleBridge.executeAction(getPlayerVehicle(0),'setFreeze', false)
    gameplay_walk.setWalkingMode(true, walkingPositionBefore, quatFromDir(vehPos - walkingPositionBefore))
    walkingPositionBefore = nil
  end

  core_input_actionFilter.setGroup('paintingBlockedActions', blockedInputActions)
  core_input_actionFilter.addAction(0, 'paintingBlockedActions', false)
end

local function getTotalPrice(package)
  local total = {money = {amount = 0, canBeNegative = false}}
  for index, paintOptions in ipairs(package) do
    if not tableIsEmpty(paintOptions) then
      total.money.amount = total.money.amount + prices.basePrices[paintOptions.paintClass].money.amount
      if paintOptions.clearCoat then
        total.money.amount = total.money.amount + prices.clearcoatBase.money.amount
        total.money.amount = total.money.amount + paintOptions.clearCoatPolish * prices.clearcoatPolishFactor.money.amount
      end
    end
  end
  return total
end

local function apply()
  local price = getTotalPrice(chosenPackage)
  if not career_modules_payment.canPay(price) then return end
  career_modules_payment.pay(price, {label = string.format("Repainted the vehicle"), tags = {"vehiclePainting", "buying"}})
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')

  if chosenPaints then
    local vehicle = career_modules_inventory.getVehicles()[inventoryId]
    for partName, partCondition in pairs(vehicle.partConditions) do
      if partCondition.visualState and partCondition.visualState.paint.originalPaints then
        -- TODO this always sets the odometer of all 3 paints back to 0
        partCondition.visualState.paint.odometer = 0
        partCondition.visualState.paint.originalPaints = chosenPaints
      end
    end
  end

  close()
  career_modules_inventory.setVehicleDirty(inventoryId)
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["painting"] then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
    local inventoryId = vehicleData.inventoryId
    local permissionStatus, permissionLabel = career_modules_permissions.getStatusForTag("vehicleModification")

    local buttonDisabled =
      vehicleData.needsRepair or
      menuData.tutorialTuningActive or
      menuData.tutorialPartShoppingActive or
      permissionStatus == "forbidden"

    local label = "Painting" ..(permissionLabel and ("\n"..permissionLabel) or "")

    local computerFunctionData = {
      id = "painting",
      label = label,
      callback = function() start(inventoryId, menuData.computerFacility.id) end,
      disabled = buttonDisabled
    }
    if vehicleData.needsRepair then
      computerFunctionData.disableReason = "fix vehicle body first"
    end

    computerFunctions.vehicleSpecific[inventoryId][computerFunctionData.id] = computerFunctionData
  end
end

local function sendShoppingCartData(package)
  local data = {}
  data.totalPrice = getTotalPrice(package)
  data.canPay = career_modules_payment.canPay(data.totalPrice)
  guihooks.trigger("sendPaintingShoppingCartData", data)
end

local function setPaints(paints, paintOptions)
  chosenPaints = paints
  chosenPackage = paintOptions

  sendShoppingCartData(chosenPackage)

  if tableSize(chosenPaints) < 3 then
    for i = tableSize(chosenPaints)+1, 3 do
      chosenPaints[i] = chosenPaints[i-1]
    end
  end

  local vehicleObject = be:getObjectByID(career_modules_inventory.getMapInventoryIdToVehId()[inventoryId])
  vehicleObject:queueLuaCommand(string.format("partCondition.setAllPartPaints(%s, 0)", serialize(chosenPaints)))
end

local function getFactoryPaint()
  local id = career_modules_inventory.getMapInventoryIdToVehId()[inventoryId]
  local info = core_vehicles.getVehicleDetails(id)
  return info.model and info.model.paints or {}
end

local function onUIOpened()
  -- Enter the vehicle (with one frame delay, because otherwise the UI doesnt show up)
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  local veh = be:getObjectByID(vehId)
  core_vehicleBridge.requestValue(veh, function()
    career_modules_inventory.enterVehicle(inventoryId)
    core_vehicleBridge.executeAction(veh,'setFreeze', true)

    -- we use setDefaultRotation instead of setRotation, because that one doesnt work reliably
    local vehCamData = core_camera.getCameraDataById(be:getPlayerVehicleID(0)).orbit
    if vehCamData then
      previousDefaultRotation = vehCamData.defaultRotation
    end
    core_camera.setByName(0, "orbit", true)
    core_camera.setDefaultRotation(vehId, vec3(145, -15, 0))
    core_camera.resetCamera(0)
    extensions.hook("onVehiclePaintingUiOpened")
  end, 'ping')
end

M.start = start
M.apply = apply
M.close = close
M.getPaintData = getPaintData
M.setPaints = setPaints
M.getFactoryPaint = getFactoryPaint

M.getPrimerColor = getPrimerColor

M.onComputerAddFunctions = onComputerAddFunctions
M.onUIOpened = onUIOpened

return M