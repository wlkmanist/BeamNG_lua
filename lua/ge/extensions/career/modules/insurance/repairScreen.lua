local M = {}

M.dependencies = {'career_modules_valueCalculator', 'career_modules_inventory', 'career_modules_playerAttributes', 'career_modules_payment', 'career_modules_insurance_insurance', 'career_modules_tether'}

-- This module handles repair screen data preparation
-- It contains the logic for building repair screen data, separate from the main insurance module

local originComputerId
local vehicleToRepairData
local tether
local tetherRange = 7 -- meters

local function openRepairMenu(vehicle, _originComputerId)
  vehicleToRepairData = vehicle
  originComputerId = _originComputerId

  tether = nil
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    if computer then
      local door = computer.doors and computer.doors[1]
      if door then
        tether = career_modules_tether.startDoorTether(door, tetherRange, career_career.closeAllMenus)
      end
      if not tether then
        tether = career_modules_tether.startSphereTether(freeroam_facilities.getAverageDoorPositionForFacility(computer), tetherRange, career_career.closeAllMenus)
      end
    end
  end

  extensions.ui_router.navigate("career.computer.repair")
end

local function closeRepairMenu()
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["vehicleInventory"] then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
    local inventoryId = vehicleData.inventoryId
    local computerFunctionData = {
      id = "repair",
      routeTarget = "career.computer.repair",
      label = _tr("ui.career.shared.pathRepair"),
      callback = function() openRepairMenu(career_modules_inventory.getVehicles()[inventoryId], menuData.computerFacility.id) end,
      order = 5
    }

    -- tutorial
    if not menuData.hasBoughtStarterVehicle then
      computerFunctionData.disabled = true
      computerFunctionData.reason = career_modules_computer.reasons.hasBoughtStarterVehicle
    end

    -- generic gameplay reason
    local reason = career_modules_permissions.getStatusForTag({"vehicleRepair"}, {inventoryId = inventoryId})
    if not reason.allow then
      computerFunctionData.disabled = true
    end
    if reason.permission ~= "allowed" then
      computerFunctionData.reason = reason
    end

    computerFunctions.vehicleSpecific[inventoryId][computerFunctionData.id] = computerFunctionData
  end
end

local function getFutureDriverScoreAfterClaim(insuranceId, insuranceModule)
  local plInsurancesData = insuranceModule.getPlayerInsurancesData()
  local plDriverScore = insuranceModule.getDriverScore()
  local driverScoreIncrementAmount = 1
  return insuranceId and plInsurancesData[insuranceId] and plInsurancesData[insuranceId].accidentForgiveness > 0 and plDriverScore or plDriverScore - driverScoreIncrementAmount
end

local function getFuturePremiumAfterClaim(insuranceId, insuranceModule)
  local plInsurancesData = insuranceModule.getPlayerInsurancesData()
  local plDriverScore = insuranceModule.getDriverScore()
  local driverScoreIncrementAmount = 1

  if not insuranceId or not plInsurancesData[insuranceId] then return 0 end
  if plInsurancesData[insuranceId].accidentForgiveness > 0 then
    return insuranceModule.calculateInsurancePremium(insuranceId).totalPriceWithDriverScore
  else
    local futureTierData = insuranceModule.getDriverScoreTierData(plDriverScore - driverScoreIncrementAmount)
    return insuranceModule.calculateInsurancePremium(insuranceId).totalPrice * futureTierData.multiplier
  end
end

local function getRepairData()
  local insuranceModule = career_modules_insurance_insurance
  local invVehs = insuranceModule.getInvVehs()
  local invVehInfo = deepcopy(vehicleToRepairData)
  local insuranceId = invVehs[invVehInfo.id].insuranceId

  local data = {
    repairOptions = {
      noInsuranceRepairData = {
        repairTimeOptions = {},
        useInsurance = false,
      },
      insuranceRepairData = nil,
    },
    vehicleData = {
      damageCost = career_modules_valueCalculator.getRepairDetails(invVehInfo).price,
      name = career_modules_inventory.getVehicleNiceNameTranslated(invVehInfo.id),
      initialValue = invVehs[invVehInfo.id].initialValue,
      invVehId = invVehInfo.id,
      thumbnail = career_modules_inventory.getVehicleThumbnail(invVehInfo.id) .. "?" .. (invVehInfo.dirtyDate or ""),
      isInsured = invVehs[invVehInfo.id].insuranceId > 0,
      needsRepair = true,
    },
    playerAttributes = career_modules_playerAttributes.getAllAttributes(),
    driverScoreTierData = insuranceModule.getDriverScoreTierData(),
    futureDriverScore = getFutureDriverScoreAfterClaim(insuranceId, insuranceModule),
    driverScore = insuranceModule.getDriverScore(),
  }

  -- if the vehicle is insured, add repair insurance data
  if insuranceModule.doesInsuranceExist(insuranceId) then
    data.repairOptions.insuranceRepairData = {
      repairTimeOptions = {},
      useInsurance = true,
      renewsIn = insuranceModule.getRenewsIn(insuranceId),
      insuranceName = insuranceModule.getInsuranceName(insuranceId),
      currentPremium = insuranceModule.calculateInsurancePremium(insuranceId).totalPriceWithDriverScore,
      futurePremium = getFuturePremiumAfterClaim(insuranceId, insuranceModule),
      deductible = insuranceModule.getPlCoverageOptionValue(invVehInfo.id, "deductible"),
      accidentForgivenesses = insuranceModule.getAccidentForgivenessCount(insuranceId),
    }
  end

  local defaultRepairTimeChoiceData
  if insuranceModule.doesInsuranceExist(insuranceId) then
    defaultRepairTimeChoiceData = insuranceModule.sanitizeCoverageOption(insuranceId, "repairTime", invVehInfo.id)
    data.repairOptions.insuranceRepairData.repairTimeOptions = deepcopy(defaultRepairTimeChoiceData)
  end

  data.repairOptions.noInsuranceRepairData.repairTimeOptions = {
    name = _tr("insurance.perks.repairTime.name", "Repair time"),
    choiceType = "multiple",
    choices = {
      {id = 1, value = 0, premiumInfluence = 500, choiceText = _tr("ui.career.insurance.coverageChoice.instant")},
      {id = 2, value = 120, premiumInfluence = 350, choiceText = core_locales.contextTranslate("ui.career.insurance.coverageChoice.minutes", {count = 2})},
      {id = 3, value = 300, premiumInfluence = 150, choiceText = core_locales.contextTranslate("ui.career.insurance.coverageChoice.minutes", {count = 5})},
      {id = 4, value = 600, premiumInfluence = 50, choiceText = core_locales.contextTranslate("ui.career.insurance.coverageChoice.minutes", {count = 10})}
    }
  }

  if insuranceModule.doesInsuranceExist(insuranceId) then
    for _, choiceData in pairs(data.repairOptions.insuranceRepairData.repairTimeOptions.choices) do
      if choiceData.id == defaultRepairTimeChoiceData.currentValueId then
        choiceData.totalPrice = data.repairOptions.insuranceRepairData.deductible
        choiceData.premiumInfluence = 0 --so that the price to pay is 0
        local hasFreeInstantRepairPerk = insuranceModule.getPerkValueByInsuranceId(insuranceId, "instantRepair")
        choiceData.secondaryText = hasFreeInstantRepairPerk and _tr("ui.career.repair.freePolicyPerk") or _tr("ui.career.repair.alreadyPaidPolicyCoverage")
        data.repairOptions.noInsuranceRepairData.repairTimeOptions.currentValueId = choiceData.id
      elseif choiceData.value == 0 then
        choiceData.totalPrice = choiceData.premiumInfluence + data.repairOptions.insuranceRepairData.deductible
      end
      if choiceData.id == defaultRepairTimeChoiceData.currentValueId or choiceData.value == 0 then --only include that the player pay for and the instant repair
        choiceData.canPay = true
        choiceData.repairTimePrice = choiceData.premiumInfluence
        choiceData.disabled = false
      else
        choiceData.disabled = true
      end
    end
  end

  for _, choiceData in pairs(data.repairOptions.noInsuranceRepairData.repairTimeOptions.choices) do
    local totalPrice = choiceData.premiumInfluence + data.vehicleData.damageCost
    local canPay = career_modules_payment.canPay({money = {amount = totalPrice, canBeNegative = false}})
    choiceData.totalPrice = totalPrice
    choiceData.canPay = canPay
    choiceData.repairTimePrice = choiceData.oldPremiumInfluence and choiceData.oldPremiumInfluence or choiceData.premiumInfluence
  end

  return data
end

local function onMenuClosed()
  if tether then tether.remove = true tether = nil end
end

local function closeMenu()
  closeRepairMenu()
end

local function startRepairInGarage(invVehId, repairOptionData)
  local result = career_modules_insurance_insurance.startRepairInGarage(invVehId, repairOptionData)
  closeRepairMenu()
  return result
end

M.getRepairData = getRepairData
M.openRepairMenu = openRepairMenu
M.closeRepairMenu = closeRepairMenu
M.closeMenu = closeMenu
M.startRepairInGarage = startRepairInGarage

M.onComputerAddFunctions = onComputerAddFunctions
M.onMenuClosed = onMenuClosed

return M
