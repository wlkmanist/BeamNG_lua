-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career', 'career_modules_payment', 'career_modules_playerAttributes', 'career_modules_insurance_history', 'career_modules_tether'}

local plInsuranceDataFileName = "insurance"

-- static insurance information
local insuranceRenewalDistance = 100000
local maxAccidentForgiveness = 5
local defaultDriverScore = 64
local groupDiscountTiers = {
  {id = 1, min = 0, max = 50000, discount = 0.10},
  {id = 2, min = 50000, max = 100000, discount = 0.15},
  {id = 3, min = 100000, max = 150000, discount = 0.2},
  {id = 4, min = 150000, max = 500000, discount = 0.25},
  {id = 5, min = 500000, max = math.huge, discount = 0.3},
}

local insuranceEditTime = 600 -- have to wait between coverage editing
local testDriveClaimPrice = {money = { amount = 500, canBeNegative = true}}
local minimumDriverScore = 0
local maximumDriverScore = 100
local driverScoreIncrementAmount = 1
local quickRepairExtraPrice = 1000
local earlyTerminationPenalty = 25 -- percentage
--loaded default data
local availableCoverageOptions = {} -- to avoid copy pasting data in insurances.json, this table comprises coverage options niceName and descriptions
local availableClasses = {}
local availableInsurances = {} -- the default insurance data in game folder
local driverScoreTiers = {}

local safeDrivingScoreIncrease = 2
local driverScoreDecreaseDistance = 50000

-- player saved data
local plInsurancesData = {} -- the player's saved insurance data
local invVehs = {}
local plDriverScore
local lastDriverScoreKmIncrease
local totalDrivenDistance
local insuredDrivenDistance

-- to calculate distance driven
local vec3Zero = vec3(0,0,0)
local lastPos = vec3(0,0,0)

-- active insurance variables
local activeInsuranceId = -1

-- loyalty variables
local maxLoyaltyPerCarAndRenewal = 5
local minLoyaltyPerCarAndRenewal = 1

local conditions = {
  applicableValue = function(data, values)
    if not data.vehValue then return false end
    if values.min and values.max then
      return data.vehValue >= values.min and data.vehValue <= values.max
    elseif values.min and not values.max then
      return data.vehValue >= values.min
    elseif values.max and not values.min then
      return data.vehValue <= values.max
    end
  end,
  population = function(data, values)
    if not data.population then return false end
    if values.min and values.max then
      return data.population >= values.min and data.population <= values.max
    elseif values.min and not values.max then
      return data.population >= values.min
    elseif values.max and not values.min then
      return data.population <= values.max
    end
  end,
  bodyStyles = function(data, values)
    if not data.bodyStyle then return false end
    for _, bodyStyle in pairs(values) do
      if data.bodyStyle[bodyStyle] then
        return true
      end
    end
    return false
  end,
  commercialClass = function(data, values)
    if not data.commercialClass then return false end
    for _, commercialClass in pairs(values) do
      if commercialClass == data.commercialClass then
        return true
      end
    end
  end
}

-- gestures are commercial gestures
local gestures = {
  freeRepair = function(plInsuranceData)
    if plInsuranceData.accidentForgiveness >= maxAccidentForgiveness then return false end

    plInsuranceData.accidentForgiveness = plInsuranceData.accidentForgiveness + 1
    career_modules_insurance_history.addToPlHistory({
      type = "freeRepair",
      title = _tr("ui.career.insurance.freeRepair"),
      effects = {{type = "freeRepair", label = _tr("ui.career.insurance.freeRepair"), changedBy = 1, newValue = plInsuranceData.accidentForgiveness}},
      concernedInsuranceName = availableInsurances[plInsuranceData.insuranceId].name
    })
    ui_message(core_locales.contextTranslate("ui.career.insurance.freeRepairMessage", {insuranceName = availableInsurances[plInsuranceData.insuranceId].name}))

    return true
  end
}

local function getPlCoverageOptionValue(invVehId, coverageOptionName)
  if not invVehId then return end
  if not invVehs[invVehId] then return end

  if invVehs[invVehId].insuranceId > 0 then -- if insured
    local valueId = nil
    if availableCoverageOptions[coverageOptionName].isInsuranceWide then
      valueId = plInsurancesData[invVehs[invVehId].insuranceId].coverageOptionsData.currentCoverageOptions[coverageOptionName]
    else
      valueId = invVehs[invVehId].insuranceData.coverageOptionsData.currentCoverageOptions[coverageOptionName]
    end
    return availableInsurances[invVehs[invVehId].insuranceId].coverageOptions[coverageOptionName].choices[valueId].value
  end
end

local function saveInsurancesData(currentSavePath)
  local dataToSave =
  {
    plDriverScore = plDriverScore,
    lastDriverScoreKmIncrease = lastDriverScoreKmIncrease,
    totalDrivenDistance = totalDrivenDistance,
    insuredDrivenDistance = insuredDrivenDistance,
    plInsurancesData = plInsurancesData,
    invVehs = invVehs,
    plHistory = career_modules_insurance_history.getPlHistory(),
  }

  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/"..plInsuranceDataFileName..".json", dataToSave, true)
end

local function setActiveInsurance()
  local newVehId = be:getPlayerVehicleID(0)
  if newVehId == -1 then return end

  if gameplay_walk.isWalking() then
    activeInsuranceId = -1
  else
    local invVehId = career_modules_inventory.getInventoryIdFromVehicleId(newVehId)
    if invVehId then
      if invVehs[invVehId] then
        activeInsuranceId = invVehs[invVehId].insuranceId
        if activeInsuranceId > 0 then -- if the vehicle is insured ...
          local newVeh = scenetree.findObjectById(newVehId)
          if newVeh then
            lastPos:set(newVeh:getPosition())
          end
        end
      else
        activeInsuranceId = -1
      end
    else
      activeInsuranceId = -1
    end
  end
end

-- resetSomeData is there only for career debug
local function loadInsurancesData(resetSomeData)
  if resetSomeData == nil then
    resetSomeData = false
  end

  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot then return end

  driverScoreTiers = jsonReadFile("gameplay/insurance/driverScoreTiers.json").tiers

  availableCoverageOptions = jsonReadFile("gameplay/insurance/coverageOptions/coverageOptions.json").coverageOptions
  local perks = jsonReadFile("gameplay/insurance/perks/perks.json").perks

  -- load insurance providers, and translate their names and descriptions
  local insuranceProvidersFileNames = FS:findFiles("gameplay/insurance/providers", "*.json", -1, true, false)
  for _, insuranceProviderFileName in ipairs(insuranceProvidersFileNames) do
    local insuranceInfo = jsonReadFile(insuranceProviderFileName)
    availableInsurances[insuranceInfo.id] = insuranceInfo

    -- create the texts for the perks
    if insuranceInfo.perks then
      for perkId, perkInfo in pairs(insuranceInfo.perks) do
        local perkStaticData = perks[perkId]
        local suffixTranslatedIntro = _tr(perkStaticData.intro)
        local translatedIntro = ""
        if perkStaticData.valueType == "unit" then
          translatedIntro = perkInfo.value .. " " .. suffixTranslatedIntro
        elseif perkStaticData.valueType == "percentage" then
          translatedIntro = perkInfo.value * 100 .. "% " .. suffixTranslatedIntro
        elseif perkStaticData.valueType == "boolean" then
          translatedIntro = suffixTranslatedIntro
        end

        perkInfo.intro = translatedIntro
        perkInfo.description = _tr(perkStaticData.description)
      end
    end

    -- deductible discount perk
    local deductibleDiscountPerkValue = M.getPerkValueByInsuranceId(insuranceInfo.id, "reduceDeductible")
    if deductibleDiscountPerkValue then
      insuranceInfo.coverageOptions.deductible.perkText = insuranceInfo.perks.reduceDeductible.intro
      for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.deductible.choices) do
        coverageOptionInfo.oldValue = coverageOptionInfo.value
        coverageOptionInfo.value = coverageOptionInfo.value * (1 - deductibleDiscountPerkValue)
      end
    end

    -- paint repair perk
    local paintRepairPerkValue = M.getPerkValueByInsuranceId(insuranceInfo.id, "freeRepaintDuringRepair")
    if paintRepairPerkValue then
      insuranceInfo.coverageOptions.paintRepair.perkText = insuranceInfo.perks.freeRepaintDuringRepair.intro
      for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.paintRepair.choices) do
        coverageOptionInfo.oldPremiumInfluence = coverageOptionInfo.premiumInfluence
        coverageOptionInfo.premiumInfluence = 0
      end
    end

    -- free towing perk
    local freeTowingPerkValue = M.getPerkValueByInsuranceId(insuranceInfo.id, "freeTowing")
    if freeTowingPerkValue then
      local lastTowPremiumInfluence = 0
      insuranceInfo.coverageOptions.roadsideAssistance.perkText = insuranceInfo.perks.freeTowing.intro
      for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.roadsideAssistance.choices) do
        coverageOptionInfo.oldPremiumInfluence = coverageOptionInfo.premiumInfluence
        if coverageOptionInfo.value <= freeTowingPerkValue then
          if coverageOptionInfo.value < freeTowingPerkValue then
            coverageOptionInfo.disabled = true -- players can't select this option
          end
          lastTowPremiumInfluence = coverageOptionInfo.premiumInfluence
          coverageOptionInfo.premiumInfluence = 0
        else -- discount on tows number that are more than the perk covers
          coverageOptionInfo.premiumInfluence = coverageOptionInfo.premiumInfluence - lastTowPremiumInfluence
        end
      end
    end

    -- repair time discount perk
    local repairTimeDiscountPerkValue = M.getPerkValueByInsuranceId(insuranceInfo.id, "repairTimeDiscount")
    if repairTimeDiscountPerkValue then
      insuranceInfo.coverageOptions.repairTime.perkText = insuranceInfo.perks.repairTimeDiscount.intro
      for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.repairTime.choices) do
        coverageOptionInfo.premiumInfluence = coverageOptionInfo.premiumInfluence * (1 - repairTimeDiscountPerkValue)
      end
    end

    -- instant repair perk
    local instantRepairPerkValue = M.getPerkValueByInsuranceId(insuranceInfo.id, "instantRepair")
    if instantRepairPerkValue then
      insuranceInfo.coverageOptions.repairTime.perkText = insuranceInfo.perks.instantRepair.intro
      for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.repairTime.choices) do
        if coverageOptionInfo.value > 0 then
          coverageOptionInfo.disabled = true
        end
        coverageOptionInfo.premiumInfluence = 0
      end
    end

    for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.roadsideAssistance.choices) do
      coverageOptionInfo.choiceText = core_locales.contextTranslate("ui.career.insurance.coverageChoice.tows", {count = coverageOptionInfo.value})
    end
    for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.repairTime.choices) do
      coverageOptionInfo.choiceText = coverageOptionInfo.value / 60 > 0 and core_locales.contextTranslate("ui.career.insurance.coverageChoice.minutes", {count = coverageOptionInfo.value / 60}) or _tr("ui.career.insurance.coverageChoice.instant")
    end
    for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.deductible.choices) do
      coverageOptionInfo.choiceText = core_locales.contextTranslate("ui.career.insurance.coverageChoice.dollars", {amount = coverageOptionInfo.value})
    end
    insuranceInfo.name = _tr(insuranceInfo.name)
    insuranceInfo.slogan = _tr(insuranceInfo.slogan)
    for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions) do
      for choiceId, choiceInfo in pairs(coverageOptionInfo.choices) do --add id to each choice to make it more practical
        choiceInfo.id = choiceId
      end
      coverageOptionInfo.name = coverageOptionName
      coverageOptionInfo.unit = availableCoverageOptions[coverageOptionName].unit
      coverageOptionInfo.niceName = _tr(availableCoverageOptions[coverageOptionName].niceName)
      coverageOptionInfo.desc = _tr(availableCoverageOptions[coverageOptionName].desc)
    end
  end

  -- load insurance classes, and translate their names
  local classesFileNames = FS:findFiles("gameplay/insurance/classes", "*.json", -1, true, false)
  for _, className in ipairs(classesFileNames) do
    local classInfo = jsonReadFile(className)
    availableClasses[classInfo.id] = classInfo
    classInfo.name = _tr(classInfo.name)
    classInfo.description = _tr(classInfo.description)
  end

  -- load player data
  local savedPlInsuranceData = (savePath and jsonReadFile(savePath .. "/career/"..plInsuranceDataFileName..".json")) or {}
  local saveInfo = savePath and jsonReadFile(savePath .. "/info.json")
  local isFirstLoadEver = not savedPlInsuranceData.invVehs or saveInfo.version < career_saveSystem.getSaveSystemVersion()
  if isFirstLoadEver then -- first load ever
    invVehs = {}
    career_modules_insurance_history.initPlHistory()
    plDriverScore = 65
    lastDriverScoreKmIncrease = 0
    totalDrivenDistance = 0
    insuredDrivenDistance = 0
    plInsurancesData = {}
    for _, insuranceInfo in pairs(availableInsurances) do
      plInsurancesData[insuranceInfo.id] = {
        metersDriven = 0,
        accidentForgiveness = 0,
        roadsideAssistance = 0,
        score = 1,
        loyalty = 0,
        insuranceId = insuranceInfo.id,
        lastRenewedAt = 0,
        gesturesData = {},
        coverageOptionsData = {
          currentCoverageOptions = {}
        }
      }
      for gestureName, gestureInfo in pairs(insuranceInfo.gestures) do
        plInsurancesData[insuranceInfo.id].gesturesData[gestureName] = {
          lastHappenedAt = 0
        }
      end
      for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions) do
        if availableCoverageOptions[coverageOptionName].isInsuranceWide then
          plInsurancesData[insuranceInfo.id].coverageOptionsData.currentCoverageOptions[coverageOptionName] = coverageOptionInfo.baseValueId
        end
      end
      M.topUpRoadsideAssistance(insuranceInfo.id)
    end
  else
    plDriverScore = savedPlInsuranceData.plDriverScore or defaultDriverScore
    lastDriverScoreKmIncrease = savedPlInsuranceData.lastDriverScoreKmIncrease or 0
    totalDrivenDistance = savedPlInsuranceData.totalDrivenDistance or 0
    insuredDrivenDistance = savedPlInsuranceData.insuredDrivenDistance or 0
    invVehs = {}
    if savedPlInsuranceData.invVehs then
      -- making sure old broken nil insuranceId are converted to -1
      -- convert string keys to numbers
      for k, v in pairs(savedPlInsuranceData.invVehs) do
        if v.insuranceId == nil then
          log("W", "Career", "Repaired legacy invVeh entry " .. tostring(k) .. ": insuranceId was nil, coerced to -1")
          v.insuranceId = -1
        end
        invVehs[tonumber(k) or k] = v
      end
    end
    career_modules_insurance_history.setPlHistory(savedPlInsuranceData.plHistory)
    plInsurancesData = savedPlInsuranceData.plInsurancesData
  end
end

local function inventoryVehNeedsRepair(vehInvId)
  local vehInfo = career_modules_inventory.getVehicles()[vehInvId]
  if not vehInfo then return end
  return career_modules_valueCalculator.partConditionsNeedRepair(vehInfo.partConditions)
end

local function repairPartConditions(data)
  if not data.partConditions then return end
  if data.paintRepair == nil then data.paintRepair = true end

  for partPath, info in pairs(data.partConditions) do
    if info.integrityValue then
      if info.integrityValue == 0 then

        local inventoryPart
        if data.inventoryId then
          local partId = career_modules_partInventory.getPartPathToPartIdMap()[data.inventoryId][partPath]
          inventoryPart = career_modules_partInventory.getInventory()[partId]
          inventoryPart.repairCount = inventoryPart.repairCount or 0
          inventoryPart.repairCount = inventoryPart.repairCount + 1
          local vehicle = career_modules_inventory.getVehicles()[data.inventoryId]
          vehicle.changedSlots[inventoryPart.containingSlot] = true
        end

        -- reset the paint
        if info.visualState then
          if info.visualState.paint and info.visualState.paint.originalPaints then
            if data.paintRepair then
              info.visualState = {paint = {originalPaints = info.visualState.paint.originalPaints}}
            else
              local numberOfPaints = tableSize(info.visualState.paint.originalPaints)
              info.visualState = {paint = {originalPaints = {}}}
              for index = 1, numberOfPaints do
                info.visualState.paint.originalPaints[index] = career_modules_painting.getPrimerColor()
              end

              if inventoryPart then
                inventoryPart.primered = true
              end
            end
            info.visualState.paint.odometer = 0
          else
            -- if we dont have a replacement paint, just set visualState to nil
            info.visualState = nil
            info.visualValue = 1
          end
        end
      end

      if info.integrityState and info.integrityState.energyStorage then
        -- keep the fuel level
        for _, tankData in pairs(info.integrityState.energyStorage) do
          for attributeName, value in pairs(tankData) do
            if attributeName ~= "storedEnergy" then
              tankData[attributeName] = nil
            end
          end
        end
      else
        info.integrityState = nil
      end
      info.integrityValue = 1
    end
  end
end

-- when you damage a test drive vehicle, insurance needs to know
local function makeTestDriveDamageClaim(vehId)
  local label = core_locales.contextTranslate("ui.career.insurance.testDrive.claimMessage", {amount = testDriveClaimPrice.money.amount})
  ui_message(label)

  career_modules_payment.pay(testDriveClaimPrice, {label = label})

  career_modules_insurance_history.addToPlHistory({
    type = "testDriveClaim",
    title = _tr("ui.career.insurance.testDrive.claimTitle"),
    effects = {{type = "money", label = _tr("ui.career.insurance.effect.money"), changedBy = -testDriveClaimPrice.money.amount, newValue = career_modules_playerAttributes.getAttributeValue("money")}},
    concernedInsuranceName = _tr("ui.career.insurance.testDrive.concernedName"),
    other = {
      vehName = "ibishu n"
    }
  })
end
local originComputerId
local tether
local tetherRange = 7 -- meters
local function makeRepairClaim(invVehId, costs, vehInfo)
  local totalMoneyCost = 0
  local totalVoucherCost = 0
  for _, cost in pairs(costs) do
    if type(cost) == "number" then
      totalMoneyCost = totalMoneyCost + cost
    elseif type(cost) == "table" then
      totalMoneyCost = totalMoneyCost + (cost.money or 0)
      totalVoucherCost = totalVoucherCost + (cost.vouchers or 0)
    end
  end

  local insuranceId = invVehs[invVehId].id
  local hasUsedAccidentForgiveness = false

  if plInsurancesData[insuranceId].accidentForgiveness > 0 then
    plInsurancesData[insuranceId].accidentForgiveness = plInsurancesData[insuranceId].accidentForgiveness - 1
    hasUsedAccidentForgiveness = true
  else
    plDriverScore = math.max(plDriverScore - driverScoreIncrementAmount, minimumDriverScore)
  end

  lastDriverScoreKmIncrease = totalDrivenDistance

  local effects = {}
  if totalMoneyCost > 0 then
    table.insert(effects, {type = "money", label = _tr("ui.career.insurance.effect.money"), changedBy = -totalMoneyCost, newValue = career_modules_playerAttributes.getAttributeValue("money")})
  end
  if totalVoucherCost > 0 then
    table.insert(effects, {type = "vouchers", label = _tr("ui.career.insurance.effect.vouchers"), changedBy = -totalVoucherCost, newValue = career_modules_playerAttributes.getAttributeValue("vouchers")})
  end
  table.insert(effects, {type = "driverScore", label = _tr("ui.career.insurance.effect.driverScore"), changedBy = -driverScoreIncrementAmount, newValue = plDriverScore})

  local deductibleValue = costs.deductible
  if type(deductibleValue) == "table" then
    deductibleValue = (deductibleValue.money or 0) + (deductibleValue.vouchers or 0)
  end

  career_modules_insurance_history.addToPlHistory({
    type = "insuranceRepairClaim",
    title = _tr("ui.career.insurance.repairClaim.title"),
    effects = effects,
    concernedInsuranceName = availableInsurances[insuranceId].name,
    overrideText = hasUsedAccidentForgiveness and _tr("ui.career.insurance.repairClaim.accidentForgiveness") or nil,
    other = {
      vehDamagePrice = vehInfo and career_modules_valueCalculator.getRepairDetails(vehInfo).price or 0,
      deductible = deductibleValue or 0
    }
  })

  extensions.hook("onInsuranceRepairClaim")
  gameplay_achievement.unlockAchievement("CLAIM_FILED")
end

local function onAfterVehicleRepaired(vehInfo)
  career_modules_inventory.setVehicleDirty(vehInfo.id)
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(vehInfo.id)
  if vehId then
    career_modules_fuel.minimumRefuelingCheck(vehId)
    if gameplay_walk.isWalking() then
      local veh = getObjectByID(vehId)
      gameplay_walk.setRot(veh:getPosition() - getPlayerVehicle(0):getPosition())
    end
  end

  career_saveSystem.saveCurrent({vehInfo.id})
  extensions.hook("onVehicleRepaired", vehInfo.id)
end

local startRepairVehInfo
local function startRepairDelayed(vehInfo, repairTime)
  if career_modules_inventory.getVehicleIdFromInventoryId(vehInfo.id) then -- vehicle is currently spawned
    if vehInfo.id == career_modules_inventory.getCurrentVehicle() then
      startRepairVehInfo = {inventoryId = vehInfo.id, repairTime = repairTime}
      gameplay_walk.setWalkingMode(true)
      return -- This function gets called again after the player left the vehicle
    end
    career_modules_inventory.removeVehicleObject(vehInfo.id)
  end
  career_modules_inventory.delayVehicleAccess(vehInfo.id, repairTime, "repair")
  onAfterVehicleRepaired(vehInfo)
end

local function getDriverScoreTierData(score)
  if not score then score = plDriverScore end
  for _, tierData in pairs(driverScoreTiers) do
    if score >= tierData.min and score <= tierData.max then
      return tierData
    end
  end
  return driverScoreTiers[#driverScoreTiers]
end

local function getDriverScore()
  return plDriverScore
end

local function missionStartRepairCallback(vehInfo)
  guihooks.trigger('MenuOpenModule','menu.careermission')
  guihooks.trigger('gameContextPlayerVehicleDamageInfo', {needsRepair = inventoryVehNeedsRepair(vehInfo.id)})
end

local function startRepairInstant(vehInfo, callback, skipSound)
  if not skipSound then
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Vehicle_Recover')
  end

  if career_modules_inventory.getVehicleIdFromInventoryId(vehInfo.id) then -- vehicle is currently spawned
    career_modules_inventory.spawnVehicle(vehInfo.id, 2, callback and
    function()
      callback(vehInfo)
      onAfterVehicleRepaired(vehInfo)
    end)
    if callback then return end
  end
  onAfterVehicleRepaired(vehInfo)
end

local function startRepair(vehInvId, repairOptionData, callback)
  vehInvId = vehInvId or career_modules_inventory.getCurrentVehicle()
  repairOptionData = (repairOptionData and type(repairOptionData) == "table") and repairOptionData or {}

  local vehInfo = career_modules_inventory.getVehicles()[vehInvId]
  if not vehInfo then return end

  local totalCost = 0
  if repairOptionData.cost then
    for _, cost in pairs(repairOptionData.cost) do
      totalCost = totalCost + cost
    end
  end

  if totalCost > 0 then
    career_modules_payment.pay({money = {amount = totalCost, canBeNegative = true}}, {label = core_locales.contextTranslate("ui.career.insurance.payment.repairedVehicle", {name = career_modules_inventory.getVehicleNiceNameTranslated(vehInvId)})})
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
  end

  if repairOptionData.isInsuranceRepair then -- the player can repair on his own without insurance
    makeRepairClaim(vehInvId, repairOptionData.cost, vehInfo)
  else
    career_modules_insurance_history.addToPlHistory({
      type = "privateRepair",
      title = _tr("ui.career.insurance.privateRepair.title"),
      effects = {{type = "money", label = _tr("ui.career.insurance.effect.money"), changedBy = -totalCost, newValue = career_modules_playerAttributes.getAttributeValue("money")}},
      concernedInsuranceName = _tr("ui.career.insurance.privateRepair.concernedName"),
      other = {
        damageCost = career_modules_valueCalculator.getRepairDetails(vehInfo).price,
      }
    })
    if totalCost >= 10000 then
      gameplay_achievement.unlockAchievement("THAT_WAS_EXPENSIVE")
    end
  end

  -- the actual repair
  local paintRepair = getPlCoverageOptionValue(vehInvId, "paintRepair")
  local data = {
    partConditions = vehInfo.partConditions,
    paintRepair = paintRepair,
    inventoryId = vehInvId
  }
  repairPartConditions(data)

  if (repairOptionData and repairOptionData.repairTime) and repairOptionData.repairTime > 0 then
    startRepairDelayed(vehInfo, repairOptionData.repairTime)
  else
    startRepairInstant(vehInfo, callback, false)
  end
end


local function startRepairInGarage(invVehId, repairOptionData)
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(invVehId)
  extensions.hook("onRepairInGarage", invVehId)
  return startRepair(invVehId, repairOptionData, (vehId and repairOptionData.repairTime<= 0) and
    function(vehInfo)
      local vehObj = getObjectByID(vehId)
      if not vehObj then return end
      freeroam_facilities.teleportToGarage(career_modules_inventory.getClosestGarage().id, vehObj, false)
    end)
end

local function genericVehNeedsRepair(vehId, callback)
  local veh = getObjectByID(vehId)
  if not veh then return end
  core_vehicleBridge.requestValue(veh,
    function(res)
      local needsRepair = career_modules_valueCalculator.partConditionsNeedRepair(res.result)
      callback(needsRepair)
    end,
    'getPartConditions')
end

-- used to renew insurances and check insurance gestures
local function updateDistanceDriven(dtReal)
  local vehId = be:getPlayerVehicleID(0)
  local invVehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  if not invVehId then return end

  local vehicleData = map.objects[vehId]
  if not vehicleData then return end

  if lastPos ~= vec3Zero then
    local dist = lastPos:distance(vehicleData.pos)
    if(dist < 0.001 or dist > 10) then return end -- eehhhhhhhhh
    if plInsurancesData[activeInsuranceId] then
      plInsurancesData[activeInsuranceId].metersDriven = plInsurancesData[activeInsuranceId].metersDriven + dist
      insuredDrivenDistance = insuredDrivenDistance + dist
    end
    totalDrivenDistance = totalDrivenDistance + dist
  end

  lastPos:set(vehicleData.pos)
end

local function renewActiveInsurance(insuranceId)
  local renewalPrice = M.calculateInsurancePremium(insuranceId).totalPriceWithDriverScore
  local insuranceName = availableInsurances[insuranceId].name
  local logBookLabel = core_locales.contextTranslate("ui.career.insurance.renewed.logLabel", {insuranceName = insuranceName})
  career_modules_payment.pay({money = { amount = renewalPrice, canBeNegative = true}}, {label=logBookLabel})
  local label = core_locales.contextTranslate("ui.career.insurance.renewed.message", {insuranceName = insuranceName, price = renewalPrice})
  ui_message(label)

  -- check if the insurance has the accidentForgivenessAtRenewal perk
  local accidentForgivenessPerkValue = M.getPerkValueByInsuranceId(insuranceId, "accidentForgivenessAtRenewal")
  if accidentForgivenessPerkValue then
    plInsurancesData[insuranceId].accidentForgiveness = math.min(plInsurancesData[insuranceId].accidentForgiveness + accidentForgivenessPerkValue, maxAccidentForgiveness)
  end

  M.topUpRoadsideAssistance(insuranceId)

  plInsurancesData[insuranceId].lastRenewedAt = plInsurancesData[insuranceId].metersDriven
  career_modules_insurance_history.addToPlHistory({
    type = "insuranceRenewed",
    title = _tr("ui.career.insurance.renewed.title"),
    effects = {{type = "money", label = _tr("ui.career.insurance.effect.money"), changedBy = -renewalPrice, newValue = career_modules_playerAttributes.getAttributeValue("money")}},
    concernedInsuranceName = availableInsurances[activeInsuranceId].name
  })
end

local function sanitizeCoverageOption(insuranceId, coverageOptionId, invVehId)
  if not availableInsurances[insuranceId] then return end

  local insuranceInfo = availableInsurances[insuranceId]
  local coverageOptionData = insuranceInfo.coverageOptions[coverageOptionId]

  local data = {}
  data = {
    key = coverageOptionId,
    name = coverageOptionData.niceName,
    choices = coverageOptionData.choices,
    choiceType = availableCoverageOptions[coverageOptionId].choiceType,
    perkText = coverageOptionData.perkText,
    displayOrder = availableCoverageOptions[coverageOptionId].displayOrder or 999,
  }

  if availableCoverageOptions[coverageOptionId].isInsuranceWide then
    data.currentValueId = plInsurancesData[insuranceId].coverageOptionsData.currentCoverageOptions[coverageOptionId]
  else
    data.currentValueId = invVehs[invVehId].insuranceData.coverageOptionsData.currentCoverageOptions[coverageOptionId]
  end

  return data
end

local function sanitizeCoverageOptions(insuranceId, currentCoverageOptions, invVehId)
  local coverageOptionsData = {}

  for coverageOptionId, coverageOptionValueId in pairs(currentCoverageOptions) do
    table.insert(coverageOptionsData, sanitizeCoverageOption(insuranceId, coverageOptionId, invVehId))
  end

  -- sort by displayOrder
  table.sort(coverageOptionsData, function(a, b)
    return a.displayOrder < b.displayOrder
  end)

  return coverageOptionsData
end

local function getInvVehsUnderInsurance(insuranceId)
  local invVehList = {}
  for invVehId, data in pairs(invVehs) do
    if data.insuranceId == insuranceId then
      local vehData = deepcopy(data)
      local vehInfo = career_modules_inventory.getVehicles()[vehData.id]
      vehData.thumbnail = career_modules_inventory.getVehicleThumbnail(vehData.id) .. "?" .. (vehInfo and vehInfo.dirtyDate or "")
      vehData.needsRepair = inventoryVehNeedsRepair(vehData.id)
      table.insert(invVehList, vehData)
    end
  end
  return invVehList
end

local function getInvVehsUnderClass(classId)
  local invVehList = {}
  for invVehId, data in pairs(invVehs) do
    if availableInsurances[data.insuranceId] and availableInsurances[data.insuranceId].class == classId then
      table.insert(invVehList, data)
    end
  end
  return invVehList
end

local function addLoyaltyPoints(insuranceId)
  local invVehCount = #getInvVehsUnderInsurance(insuranceId)
  local totalPoints = 0
  for i = 1, invVehCount do
    local loyaltyPoints = math.max(maxLoyaltyPerCarAndRenewal / i, minLoyaltyPerCarAndRenewal)
    totalPoints = totalPoints + loyaltyPoints
  end

  plInsurancesData[insuranceId].loyalty = plInsurancesData[insuranceId].loyalty + totalPoints
  plInsurancesData[insuranceId].loyalty = math.floor(math.min(plInsurancesData[insuranceId].loyalty, maxLoyaltyPerCarAndRenewal))
end

--make player pay for insurance renewal every X meters
local function checkRenewInsurance()
  if plInsurancesData[activeInsuranceId].metersDriven - plInsurancesData[activeInsuranceId].lastRenewedAt >= insuranceRenewalDistance then
    renewActiveInsurance(activeInsuranceId)
    addLoyaltyPoints(activeInsuranceId)
  end
end

local function getActualRepairPrice(invVehId)
  return getPlCoverageOptionValue(invVehId, "deductible")
end

local insuranceMenuOpen = false
local closeMenuAfterSaving

-- can't edit insurance coverage options instantly without delays, or players will cheat the system
local function updateEditInsuranceCoverageOptionsTimer(dtReal)
  local sendDataToUI = false
  for _, invVehInsuranceData in pairs(invVehs) do
    if invVehInsuranceData.insuranceId and invVehInsuranceData.insuranceId > 0 then
      if invVehInsuranceData.insuranceData.coverageOptionsData.nextInsuranceEditTimer > 0 then
        invVehInsuranceData.insuranceData.coverageOptionsData.nextInsuranceEditTimer = invVehInsuranceData.insuranceData.coverageOptionsData.nextInsuranceEditTimer - dtReal
        sendDataToUI = true
      end
    end
  end

  if sendDataToUI and insuranceMenuOpen then
    M.sendUIData()
  end
end

-- gestures are commercial gestures, eg give the player a bonus after not having crashed for a while
local function checkInsuranceGestures()
  local insuranceData = availableInsurances[activeInsuranceId]
  local plInsuranceData = plInsurancesData[activeInsuranceId]
  for gestureName, _ in pairs(insuranceData.gestures) do -- every gesture is based on driven distance for now
    local lastHappenedAt = plInsuranceData.gesturesData[gestureName].lastHappenedAt or 0

    if plInsuranceData.metersDriven - lastHappenedAt > insuranceData.gestures[gestureName].distance then
      if gestures[gestureName](plInsuranceData) then
        plInsuranceData.gesturesData[gestureName].lastHappenedAt = plInsuranceData.metersDriven
      end
    end
  end
end

local function checkDriverScoreDecrease()
  local distSinceLastKm= totalDrivenDistance - lastDriverScoreKmIncrease
  if distSinceLastKm >= driverScoreDecreaseDistance then
    lastDriverScoreKmIncrease = totalDrivenDistance
    local oldScore = plDriverScore
    plDriverScore = math.min(plDriverScore + safeDrivingScoreIncrease, maximumDriverScore)
    if plDriverScore > oldScore then
      career_modules_insurance_history.addToPlHistory({
        type = "driverScoreIncrease",
        title = _tr("ui.career.insurance.safeDriving.title"),
        effects = {{type = "driverScore", label = _tr("ui.career.insurance.effect.driverScore"), changedBy = plDriverScore - oldScore, newValue = plDriverScore}},
        concernedInsuranceName = _tr("ui.career.insurance.safeDriving.concernedName")
      })
      ui_message(core_locales.contextTranslate("ui.career.insurance.safeDriving.message", {increase = safeDrivingScoreIncrease, score = plDriverScore}))
    end
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not gameplay_missions_missionManager.getForegroundMissionId() and not gameplay_walk.isWalking() then
    updateDistanceDriven(dtReal)
    if activeInsuranceId > 0 then
      checkRenewInsurance()
      checkInsuranceGestures()
      checkDriverScoreDecrease()
    end
  end
  updateEditInsuranceCoverageOptionsTimer(dtReal)
end

local function getInsurancesByClass(class)
  local insurances = {}
  for _, insuranceInfo in pairs(availableInsurances) do
    if insuranceInfo.class == class then
      table.insert(insurances, insuranceInfo)
    end
  end
  return insurances
end

local function getApplicableInsuranceClass(conditionData)

  if conditionData.jsonInsuranceClass then
    for className, value in pairs(conditionData.jsonInsuranceClass) do
      if value == true then
        return availableClasses[className]
      end
    end
  end

  -- for now still keeping the old logic just in case
  local applicableClasses = nil

  for _, classInfo in pairs(availableClasses) do
    if classInfo.applicableConditions then
      for condition, values in pairs(classInfo.applicableConditions.conditions) do -- that's an or condition
        if conditions[condition](conditionData, values) then
          if not applicableClasses then
            applicableClasses = {}
          end
          table.insert(applicableClasses, classInfo)
          break
        end
      end
    end
  end

  if applicableClasses then
    if #applicableClasses > 1 then
      table.sort(applicableClasses, function(a, b) return a.applicableConditions.priority > b.applicableConditions.priority end)
    end
    return applicableClasses[1]
  end

  return nil --should never reach here
end

local function getInsuranceClassFromVehicleShoppingData(data)
  local conditionData = {
    vehValue = data.Value,
    population = data.Population,
    bodyStyle = (data.BodyStyle and data.BodyStyle) or data.aggregates["Body Style"],
    jsonInsuranceClass = data.aggregates["InsuranceClass"],
  }
  if data["Commercial Class"] then
    conditionData.commercialClass = tonumber(string.match(data["Commercial Class"], "%d+"))
  end
  return getApplicableInsuranceClass(conditionData)
end

local function onEnterVehicleFinished(invVehId)
  if startRepairVehInfo then
    local vehInfo = career_modules_inventory.getVehicles()[startRepairVehInfo.vehId]
    career_modules_inventory.removeVehicleObject(startRepairVehInfo.vehId)
    startRepairDelayed(vehInfo)
    startRepairVehInfo = nil
  end
end

local function onVehicleSwitched()
  setActiveInsurance()
end

local function onCareerActive(active)
  if not active then return end
  loadInsurancesData()
end

local function onSaveCurrentProfile(currentSavePath)
  saveInsurancesData(currentSavePath)
end

local function formatPerkIconData(smallText, tooltipText, discount, isSignaturePerk)
  return {
    smallText = smallText,
    tooltipText = tooltipText,
    discount = discount,
    isSignaturePerk = isSignaturePerk,
  }
end

local function getTotalInsuranceVehsValue(insuranceId)
  -- computer total vehicles value under the insurance
  local totalValue = 0
  for _, invVehData in pairs(getInvVehsUnderInsurance(insuranceId)) do
    if invVehData.initialValue then
      totalValue = totalValue + invVehData.initialValue
    end
  end
  return totalValue
end

local function getInsuranceGroupDiscountTierData(insuranceId, optionalExtraValue, optionalRemovedValue)
  if #getInvVehsUnderInsurance(insuranceId) + ((optionalExtraValue and 1) or 0) - ((optionalRemovedValue and 1) or 0) <= 1 then
    return {
      id = 0,
      discount = 0
    }
  end

  local totalValue = getTotalInsuranceVehsValue(insuranceId)
  if optionalExtraValue then
    totalValue = totalValue + optionalExtraValue
  end
  if optionalRemovedValue then
    totalValue = totalValue - optionalRemovedValue
  end

  -- find the tier that the total value falls into
  for _, tier in pairs(groupDiscountTiers) do
    if tier.max then
      if totalValue >= tier.min and totalValue <= tier.max then
        return tier
      end
    else
      if totalValue >= tier.min then
        return tier
      end
    end
  end
  return {
    id = 0,
    discount = 0
  }
end

-- either invVehId or nonInvVehInfo must be provided
local function calculateVehiclePremium(invVehId, nonInvVehInfo, potentialCoverageOptions)
  local insuranceId, vehValue, insuranceClass
  local totalDiscount = 1

  local data = {
    cost = 0,
    costWithoutGroupDiscount = 0,
  }

  if nonInvVehInfo and next(nonInvVehInfo) then
    -- Potential vehicle: use insurance defaults
    insuranceId = nonInvVehInfo.insuranceId

    if insuranceId == -1 then
      return data
    end

    vehValue = nonInvVehInfo.vehValue
    insuranceClass = availableInsurances[insuranceId].class

    for coverageOptionId, coverageOptionData in pairs(potentialCoverageOptions or availableInsurances[insuranceId].coverageOptions) do
      if not availableCoverageOptions[coverageOptionId].isInsuranceWide then
        totalDiscount = totalDiscount * coverageOptionData.choices[coverageOptionData.baseValueId].premiumInfluence
      end
    end
  else
    local invVeh = invVehs[invVehId]
    insuranceId = invVeh.insuranceId

    if insuranceId == -1 then
      return data
    end

    vehValue = invVeh.initialValue
    insuranceClass = invVeh.requiredInsuranceClass.id

    -- Insured vehicle: use current coverage options
    for coverageOptionId, coverageOptionValueId in pairs(potentialCoverageOptions or invVeh.insuranceData.coverageOptionsData.currentCoverageOptions) do
      totalDiscount = totalDiscount * availableInsurances[insuranceId].coverageOptions[coverageOptionId].choices[coverageOptionValueId].premiumInfluence
    end
  end

  local groupDiscount = 1 - getInsuranceGroupDiscountTierData(insuranceId).discount
  local baseRate = vehValue * availableClasses[insuranceClass].coverageRate

  data.cost = baseRate * totalDiscount * groupDiscount
  data.costWithoutGroupDiscount = baseRate * totalDiscount
  return data
end

-- potentialCoverageOptions is used to simulate the premium. That's so that the player can test different coverage options without actually changing the insurance coverage
local function calculateInsurancePremium(insuranceId, potentialCoverageOptions, potentialVehiclesCoverageOptions, potentialNewVehValue)
  local details = {
    items = {
      vehsCoverage = {
        price = 0,
        priceWithoutGroupDiscount = 0,
        name = _tr("ui.career.insurance.multiVehicleDiscount"),
      },
    },
    totalPrice = 0,
    totalPriceWithDriverScore = 0,
    groupDiscountSavings = 0,
  }

  if not availableInsurances[insuranceId] then
    return details
  end

  if potentialCoverageOptions and not next(potentialCoverageOptions) then -- UI always send an empty table
    potentialCoverageOptions = nil
  end
  if potentialVehiclesCoverageOptions and not next(potentialVehiclesCoverageOptions) then -- UI always send an empty table
    potentialVehiclesCoverageOptions = nil
  end

  local hasVehicles = false

  for _, invVehData in pairs(getInvVehsUnderInsurance(insuranceId)) do
    hasVehicles = true
    local vehCoverageOptions = potentialVehiclesCoverageOptions and potentialVehiclesCoverageOptions[tostring(invVehData.id)]
    local vehPremium = calculateVehiclePremium(invVehData.id, nil, vehCoverageOptions)
    details.items.vehsCoverage.price = details.items.vehsCoverage.price + vehPremium.cost
    details.items.vehsCoverage.priceWithoutGroupDiscount = details.items.vehsCoverage.priceWithoutGroupDiscount + vehPremium.costWithoutGroupDiscount
  end
  if potentialNewVehValue then
    hasVehicles = true
    local vehPremium = calculateVehiclePremium(nil, {vehValue = potentialNewVehValue, insuranceId = insuranceId})
    details.items.vehsCoverage.price = details.items.vehsCoverage.price + vehPremium.cost
    details.items.vehsCoverage.priceWithoutGroupDiscount = details.items.vehsCoverage.priceWithoutGroupDiscount + vehPremium.costWithoutGroupDiscount
  end

  -- calculate group discount savings
  details.groupDiscountSavings = details.items.vehsCoverage.priceWithoutGroupDiscount - details.items.vehsCoverage.price

  if hasVehicles then
    for coverageOptionName, coverageOptionValueId in pairs(potentialCoverageOptions or plInsurancesData[insuranceId].coverageOptionsData.currentCoverageOptions) do
      local coverageOption = availableInsurances[insuranceId].coverageOptions[coverageOptionName]
      if availableCoverageOptions[coverageOptionName].isInsuranceWide then --only add insurance wide coverage options
        details.items[coverageOptionName] = {
          price = coverageOption.choices[coverageOptionValueId].premiumInfluence,
          name = coverageOption.niceName,
        }
      end
    end
  end

  for detailName, detailPrice in pairs(details.items) do
    details.totalPrice = details.totalPrice + detailPrice.price
  end
  details.totalPriceWithDriverScore = details.totalPrice * getDriverScoreTierData(plDriverScore).multiplier
  return details
end

local function getRenewsIn(insuranceId)
  if insuranceId == -1 or plInsurancesData[insuranceId] == nil then
    return 0
  end
  local metersRemaining = insuranceRenewalDistance - (plInsurancesData[insuranceId].metersDriven - plInsurancesData[insuranceId].lastRenewedAt)
  return math.ceil(metersRemaining / 1000)
end

local function calculateAddOnVehicleProRatedPrice(insuranceId, vehValue, tierData)
  local fullPrice = calculateVehiclePremium(nil, {vehValue = vehValue, insuranceId = insuranceId}).cost

  local metersRemaining = getRenewsIn(insuranceId) * 1000
  local proRatedRatio = metersRemaining / insuranceRenewalDistance
  return fullPrice * proRatedRatio * (tierData and (1 - tierData.discount or 0) or 1)
end

local function calculateAddVehiclePrice(insuranceId, vehValue)
  if #getInvVehsUnderInsurance(insuranceId) == 0 then
    return calculateInsurancePremium(insuranceId, nil, nil, vehValue).totalPriceWithDriverScore
  else
    return calculateAddOnVehicleProRatedPrice(insuranceId, vehValue, getInsuranceGroupDiscountTierData(insuranceId))
  end
end

local function getTotalInsuranceVehsValue(insuranceId)
  local totalValue = 0
  for _, invVehData in pairs(getInvVehsUnderInsurance(insuranceId)) do
    if invVehData.initialValue then
      totalValue = totalValue + invVehData.initialValue
    end
  end
  return totalValue
end

local function getInsuranceSanitizedData(insuranceId)
  local insuranceInfo = availableInsurances[insuranceId]
  local sanitizedData = {}
  local reduceDeductiblePerk = M.getPerkValueByInsuranceId(insuranceInfo.id, "reduceDeductible")
  local carsInsured = getInvVehsUnderInsurance(insuranceInfo.id)
  local currentTierData = getInsuranceGroupDiscountTierData(insuranceInfo.id)

  for _, invVehData in pairs(carsInsured) do
    invVehData.insuranceData.currentPremiumPrice = calculateVehiclePremium(invVehData.id).cost
    invVehData.insuranceData.coverageOptionsData.currentCoverageOptionsSanitized = sanitizeCoverageOptions(insuranceId, invVehData.insuranceData.coverageOptionsData.currentCoverageOptions, invVehData.id)
  end

  sanitizedData = {
    id = insuranceInfo.id,
    name = insuranceInfo.name,
    image = insuranceInfo.image and ("gameplay/insurance/providers/" .. insuranceInfo.image .. ".png") or nil,
    color = insuranceInfo.color,
    perks = insuranceInfo.perks,
    paperworkFees = insuranceInfo.paperworkFees,
    canPayPaperworkFees = career_modules_payment.canPay({money = {amount = insuranceInfo.paperworkFees, canBeNegative = false}}),
    slogan = insuranceInfo.slogan,
    carsInsuredCount = #carsInsured,
    carsInsured = carsInsured,
    totalInsuranceVehsValue = getTotalInsuranceVehsValue(insuranceInfo.id),
    renewsIn = getRenewsIn(insuranceInfo.id),
    renewsEvery = insuranceRenewalDistance / 1000,
    proRatedPercentage = getRenewsIn(insuranceInfo.id) * 1000 / insuranceRenewalDistance * 100,
    currentPremiumDetails = calculateInsurancePremium(insuranceInfo.id),
    coverageOptionsData = sanitizeCoverageOptions(insuranceInfo.id, plInsurancesData[insuranceInfo.id].coverageOptionsData.currentCoverageOptions),
    baseDeductibledData = {
      price = insuranceInfo.coverageOptions.deductible.choices[2].value,
      perkData = nil,
    },
    groupDiscountData = {
      groupDiscountTiers = deepcopy(groupDiscountTiers),
      currentTierData = currentTierData,
    },
  }

  if reduceDeductiblePerk then
    local isSignaturePerk = insuranceInfo.perks.reduceDeductible.isSignaturePerk or false
    sanitizedData.baseDeductibledData.perkData = formatPerkIconData(
      core_locales.contextTranslate("ui.career.insurance.perk.deductibleReduction", {percent = reduceDeductiblePerk * 100}),
      core_locales.contextTranslate("ui.career.insurance.perk.deductibleReductionTooltip", {insuranceName = insuranceInfo.name, percent = reduceDeductiblePerk * 100}),
      reduceDeductiblePerk, isSignaturePerk)
    sanitizedData.baseDeductibledData.oldPrice = insuranceInfo.coverageOptions.deductible.choices[2].oldValue
  end

  local groupDiscountData = sanitizedData.groupDiscountData
  if currentTierData.id > 0 then
    groupDiscountData.groupDiscountTiers[currentTierData.id].isCurrent = true
  end
  if groupDiscountData.currentTierData.id > 0 then
    groupDiscountData.mainText = _tr("ui.career.insurance.multiVehicleDiscountActive")
    groupDiscountData.secondaryText = _tr("ui.career.insurance.multiVehicleDiscountDescription")
  end

  return sanitizedData
end

local function getSanitizedInsuranceDataForPurchase(insuranceId, vehicleInfo)
  local sanitizedData = getInsuranceSanitizedData(insuranceId)
  local futureTierData = getInsuranceGroupDiscountTierData(insuranceId, vehicleInfo.Value)
  local newVehiclePremium = calculateVehiclePremium(nil, {vehValue = vehicleInfo.Value, insuranceId = insuranceId}).cost
  sanitizedData.vehicleName = vehicleInfo.Name
  sanitizedData.vehicleValue = vehicleInfo.Value
  sanitizedData.addVehiclePrice = calculateAddVehiclePrice(insuranceId, vehicleInfo.Value)
  sanitizedData.amountDue = sanitizedData.addVehiclePrice
  sanitizedData.nonProRatedVehiclePremium = newVehiclePremium
  sanitizedData.proRatedVehiclePremium = calculateAddOnVehicleProRatedPrice(insuranceId, vehicleInfo.Value, sanitizedData.groupDiscountData.currentTierData)
  sanitizedData.futurePremiumDetails = calculateInsurancePremium(insuranceId, nil, nil, vehicleInfo.Value)
  sanitizedData.groupDiscountData.futureTierData = futureTierData
  sanitizedData.groupDiscountData.willBumpTheirDiscount = (sanitizedData.groupDiscountData.currentTierData and futureTierData) and sanitizedData.groupDiscountData.currentTierData.id < futureTierData.id and not sanitizedData.groupDiscountData.willBumpTheirDiscount
  sanitizedData.groupDiscountData.willHaveGroupDiscountForTheFirstTime = sanitizedData.carsInsuredCount >= 1 and futureTierData.id > 0 and sanitizedData.groupDiscountData.currentTierData.id == 0
  if sanitizedData.groupDiscountData.futureTierData.id ~= sanitizedData.groupDiscountData.currentTierData.id then
    if sanitizedData.groupDiscountData.willHaveGroupDiscountForTheFirstTime then
      sanitizedData.groupDiscountData.mainText = _tr("ui.career.insurance.multiVehicleDiscountAvailable")
    else
      sanitizedData.groupDiscountData.mainText = _tr("ui.career.insurance.biggerDiscountAvailable")
    end
    sanitizedData.groupDiscountData.secondaryText = core_locales.contextTranslate("ui.career.insurance.tierAdvanceMessage", {
      tier = sanitizedData.groupDiscountData.futureTierData.id,
      discount = sanitizedData.groupDiscountData.futureTierData.discount * 100,
    })
  end
  return sanitizedData
end

-- Helper function to create "No insurance" card
local function createNoInsuranceCard()
  return {
    id = -1,
    name = _tr("ui.career.insurance.noInsurance"),
    perks = {
      {
        id = "noInsurance",
        intro = _tr("ui.career.insurance.noInsuranceCard.fullRepairCost"),
        value = 0,
        valueType = "boolean",
      },
      {
        id = "noInsurance",
        intro = _tr("ui.career.insurance.noInsuranceCard.noCoverage"),
        value = 0,
        valueType = "boolean",
      },
      {
        id = "noInsurance",
        intro = _tr("ui.career.insurance.noInsuranceCard.notRecommended"),
        value = 0,
        valueType = "boolean",
      },
    },
    initialBuyPrice = 0,
    slogan = _tr("ui.career.insurance.noInsurance"),
    --imagePath = "gameplay/insurance/providers/noInsurance.jpg",
    baseRenewalPriceData = {
      price = 0,
      perkData = nil,
    },
    baseDeductibledData = {
      price = 0,
      perkData = nil,
    },
  }
end

local function getCoverageRefundPrice(invVehId)
  return calculateVehiclePremium(invVehId).cost * getRenewsIn(invVehs[invVehId].insuranceId) * 1000 / insuranceRenewalDistance
end

local function getEarlyTerminationPenalty(invVehId)
  return getCoverageRefundPrice(invVehId) * earlyTerminationPenalty / 100
end

local function getNetRefundPrice(invVehId)
  return getCoverageRefundPrice(invVehId) - getEarlyTerminationPenalty(invVehId)
end
-- returns negative if ows money, positive if due money
local function calculateInsuranceSwitchingCost(invVehId, newInsuranceId)
  return getNetRefundPrice(invVehId) - calculateAddVehiclePrice(newInsuranceId, invVehs[invVehId].initialValue)
end

local function buildLeavingInsuranceInfo(invVehId)
  local currentInsuranceId = invVehs[invVehId].insuranceId
  local vehicleValue = invVehs[invVehId].initialValue

  local data = {
    currentInsuranceName = availableInsurances[currentInsuranceId] and availableInsurances[currentInsuranceId].name or _tr("ui.career.insurance.noInsuranceName"),
    vehicleCount = #getInvVehsUnderInsurance(currentInsuranceId),
    newVehicleCount = #getInvVehsUnderInsurance(currentInsuranceId) - 1,
    discountTierData = getInsuranceGroupDiscountTierData(currentInsuranceId),
    newDiscountTierData = getInsuranceGroupDiscountTierData(currentInsuranceId, nil, vehicleValue),
    coverageRefundPrice = getCoverageRefundPrice(invVehId),
    earlyTerminationPenalty = getEarlyTerminationPenalty(invVehId),
    netRefundPrice = getNetRefundPrice(invVehId),
    renewsIn = getRenewsIn(currentInsuranceId),
  }

  return data
end

local function getVehiclesInsuredCount()
  local count = 0
  for _, invVehData in pairs(invVehs) do
    if invVehData.insuranceId > 0 then
      count = count + 1
    end
  end
  return count
end

local function getPlayerAbstractData()
  local data = {
    driverScore = plDriverScore,
    totalDistanceDriven = totalDrivenDistance,
    insuredDistanceDriven = insuredDrivenDistance,
    uninsuredDistanceDriven = totalDrivenDistance - insuredDrivenDistance,
    driverScoreTier = getDriverScoreTierData(plDriverScore),
    repairHistory = {
      insuranceRepairs = career_modules_insurance_history.getInsuranceClaimsCount(),
      privateRepairs = career_modules_insurance_history.getNonInsuranceRepairsCount(),
    },
    driverScoreReset = {
      resetTo = defaultDriverScore,
      resetCost = M.getDriverScoreResetCost(),
    },
    financialSummary = {
      vehiclesInsuredCount = getVehiclesInsuredCount(),
      totalPremiumPaid = career_modules_insurance_history.getTotalPremiumPaid(),
      totalDeductiblePaid = career_modules_insurance_history.getTotalInsuranceRepairDeductiblesPaid(),
      totalPrivateRepairsPaid = career_modules_insurance_history.getTotalPrivateRepairsPaid(),
      damageCoveredByInsurance = career_modules_insurance_history.getDamageCostCoveredByInsurance(),
      totalPaid = 0,
    }
  }

  data.financialSummary.totalPaid = data.financialSummary.totalPremiumPaid + data.financialSummary.totalDeductiblePaid + data.financialSummary.totalPrivateRepairsPaid

  return data
end

local function buildInsuranceOptionsData(context)
  local data = {
    applicableInsurancesData = {},
    driverScoreData = {
      score = plDriverScore,
      tier = getDriverScoreTierData(plDriverScore),
    },
    vehicleInfo = deepcopy(context.vehicleInfo),
  }

  if context.type == "purchase" then
    data.defaultInsuranceId = context.defaultInsuranceId
    data.insuranceClassId = context.insuranceClassId
    data.purchaseData = {
      vehShopId = context.vehShopId,
      purchaseType = context.purchaseType,
      defaultInsuranceId = context.defaultInsuranceId,
      insuranceClassId = context.insuranceClassId,
      vehicleInfo = deepcopy(context.vehicleInfo),
    }
  elseif context.type == "change" then
    data.defaultInsuranceId = invVehs[context.invVehId].insuranceId
    data.currentInsuranceId = invVehs[context.invVehId].insuranceId
  end


  -- always add "No insurance" option
  local noInsuranceCard = createNoInsuranceCard()
  if context.type == "change" then
    noInsuranceCard.leavingInsuranceInfo = buildLeavingInsuranceInfo(context.invVehId)
  end
  table.insert(data.applicableInsurancesData, noInsuranceCard)

  -- build insurance options
  local applicableInsurances = getInsurancesByClass(context.insuranceClassId)
  for _, insuranceInfo in pairs(applicableInsurances) do
    local sanitizedData

    -- only add leaving insurance info if we're in the "change" context
    sanitizedData = getSanitizedInsuranceDataForPurchase(insuranceInfo.id, context.vehicleInfo)
    if context.type == "change" then
      sanitizedData.leavingInsuranceInfo = buildLeavingInsuranceInfo(context.invVehId)
      sanitizedData.netSwitchingCost = calculateInsuranceSwitchingCost(context.invVehId, insuranceInfo.id)
      sanitizedData.amountDue = sanitizedData.netSwitchingCost * -1
      if data.currentInsuranceId == insuranceInfo.id then
        sanitizedData.amountDue = 0
      end
      sanitizedData.canPay = career_modules_payment.canPay({money = {amount = sanitizedData.amountDue, canBeNegative = false}})
    end

    table.insert(data.applicableInsurancesData, sanitizedData)
  end

  -- sort by ID
  table.sort(data.applicableInsurancesData, function(a, b)
    return a.id < b.id
  end)

  return data
end

local function sendChangeInsuranceDataToTheUI(invVehId)
  local vehInfo = career_modules_inventory.getVehicles()[invVehId]
  local data = buildInsuranceOptionsData({
    type = "change",
    insuranceClassId = invVehs[invVehId].requiredInsuranceClass.id,
    invVehId = invVehId,
    vehicleInfo = {
      Name = invVehs[invVehId].name,
      Value = invVehs[invVehId].initialValue,
      thumbnail = career_modules_inventory.getVehicleThumbnail(invVehId) .. "?" .. (vehInfo.dirtyDate or ""),
      invVehId = invVehId,
    },
  })
  guihooks.trigger('chooseInsuranceData', data)
end

local function sendChooseInsuranceDataToTheUI(purchaseType, vehShopId, defaultInsuranceId)
  local vehicleInfo = career_modules_vehicleShopping.getVehicleInfoByShopId(vehShopId)
  local data = buildInsuranceOptionsData({
    type = "purchase",
    insuranceClassId = vehicleInfo.insuranceClass.id,
    vehicleInfo = vehicleInfo,
    defaultInsuranceId = defaultInsuranceId,
    purchaseType = purchaseType,
    vehShopId = vehShopId,
  })
  guihooks.trigger('chooseInsuranceData', data)
end

local function sendUIData()
  insuranceMenuOpen = true


  local uninsuredVehs = getInvVehsUnderInsurance(-1)

  local data = {
    invVehsInsurancesData = {},
    plClassesData = {},
    plHistory = career_modules_insurance_history.buildPlHistory(),
    driverScoreData = {
      score = plDriverScore,
      tier = getDriverScoreTierData(plDriverScore),
    },
    uninsuredVehsData = {
      title = _tr("ui.career.insurance.uninsured.title"),
      description = _tr("ui.career.insurance.uninsured.description"),
      carsUninsuredCount = #uninsuredVehs,
      carsUninsured = uninsuredVehs,
    },
    careerMoney = career_modules_playerAttributes.getAttributeValue("money"),
    careerVouchers = career_modules_playerAttributes.getAttributeValue("vouchers"),
  }

  -- format the data to make it easier to use in the UI
  for invVehId, invVehData in pairs(invVehs) do
    local invVehTileData = career_modules_inventory.getVehicleUiData(invVehId)

    if invVehTileData then
      invVehTileData.insuranceName = availableInsurances[invVehData.insuranceId] and availableInsurances[invVehData.insuranceId].name or _tr("ui.career.insurance.none")
      invVehTileData.individualRenewalPrice = calculateVehiclePremium(invVehId).cost
      data.invVehsInsurancesData[invVehId] = invVehTileData
    end
  end

  for classId, classData in pairs(availableClasses) do
    local carsInsured = #getInvVehsUnderClass(classId)
    data.plClassesData[classId] = {
      name = classData.name,
      description = classData.description,
      icon = classData.icon,
      carsInsured = carsInsured,
      priority = classData.applicableConditions.priority,
      insurances = {},
    }
    for _, insuranceInfo in pairs(getInsurancesByClass(classId)) do
      table.insert(data.plClassesData[classId].insurances, getInsuranceSanitizedData(insuranceInfo.id))
    end
  end

  guihooks.trigger('insurancesData', data)
end

-- remove the vehicle from the insuranced vehicles json files
local function onVehicleRemovedFromInventory(invVehId)
  invVehs[invVehId] = nil
end

-- pure setter: writes the new insurance on the invVeh entry and applies side-effects that
-- belong to the data itself (default coverage options, loyalty reset). No policy, no payment,
-- no history, no UI refresh. newInsuranceId can be -1 to mark the vehicle as uninsured.
local function applyInvVehInsurance(invVehId, newInsuranceId)
  if not invVehs[invVehId] then return end

  local oldInsuranceId = invVehs[invVehId].insuranceId

  if newInsuranceId > 0 then
    -- set the default vehicle specific coverage options
    for coverageOptionName, coverageOptionValue in pairs(availableInsurances[newInsuranceId].coverageOptions) do
      if not availableCoverageOptions[coverageOptionName].isInsuranceWide then
        invVehs[invVehId].insuranceData.coverageOptionsData.currentCoverageOptions[coverageOptionName] = coverageOptionValue.baseValueId
      end
    end

    -- set default insurance wide coverage options
    if #getInvVehsUnderInsurance(newInsuranceId) == 0 then
      for coverageOptionName, coverageOptionValue in pairs(availableInsurances[newInsuranceId].coverageOptions) do
        if availableCoverageOptions[coverageOptionName].isInsuranceWide then
          plInsurancesData[newInsuranceId].coverageOptionsData.currentCoverageOptions[coverageOptionName] = coverageOptionValue.baseValueId
        end
      end
    end
  end

  invVehs[invVehId].insuranceId = newInsuranceId

  -- loyalty gets reset to 0 if no vehicle is insured under the old insurance
  if oldInsuranceId and oldInsuranceId > 0 and plInsurancesData[oldInsuranceId] and #getInvVehsUnderInsurance(oldInsuranceId) == 0 then
    plInsurancesData[oldInsuranceId].loyalty = 0
  end
end

-- user-facing insurance change action. Enforces the "no switching while damaged" rule,
-- charges/refunds the switching fees, records history, and refreshes the UI.
-- newInsuranceId can be -1 to remove the insurance.
local function changeInvVehInsurance(invVehId, newInsuranceId)
  if not invVehs[invVehId] then return end
  if inventoryVehNeedsRepair(invVehId) then return end

  local insuranceChangeFees = calculateInsuranceSwitchingCost(invVehId, newInsuranceId)
  local insuranceName = newInsuranceId > 0 and availableInsurances[newInsuranceId].name or _tr("ui.career.insurance.none")

  applyInvVehInsurance(invVehId, newInsuranceId)
  gameplay_achievement.unlockAchievement("POLICY_REVIEW")

  local niceName = career_modules_inventory.getVehicle(invVehId).niceName
  local label = core_locales.contextTranslate("ui.career.insurance.changed.label", {vehicleName = niceName, insuranceName = insuranceName})
  local attributeLabel = {txt = "ui.career.insurance.changed.label", context = {vehicleName = niceName, insuranceName = insuranceName}}
  if insuranceChangeFees > 0 then
    career_modules_playerAttributes.addAttributes({money = insuranceChangeFees}, {label=attributeLabel})
    career_modules_insurance_history.addToPlHistory({
      type = "insuranceChanged",
      title = label,
      effects = {{type = "money", label = _tr("ui.career.insurance.effect.money"), changedBy = insuranceChangeFees, newValue = career_modules_playerAttributes.getAttributeValue("money")}},
      concernedInsuranceName = insuranceName
    })
  else
    if career_modules_payment.pay({money = {amount = insuranceChangeFees * -1, canBeNegative = false}}, {reason="insuranceChange"}) then
      career_modules_insurance_history.addToPlHistory({
        type = "insuranceChanged",
        title = label,
        effects = {{type = "money", label = _tr("ui.career.insurance.effect.money"), changedBy = -insuranceChangeFees, newValue = career_modules_playerAttributes.getAttributeValue("money")}},
        concernedInsuranceName = insuranceName
      })
    end
  end
  M.sendUIData()
end

-- apply the minimum applicable insurance to the vehicle, and save it to the json file
local function onVehicleAddedToInventory(data)
  local conditionData = {
    vehValue = career_modules_valueCalculator.getInventoryVehicleValue(data.inventoryId),
    population = data.vehicleInfo and data.vehicleInfo.Population or nil,
    bodyStyle = data.vehicleInfo and ((data.vehicleInfo.BodyStyle and data.vehicleInfo.BodyStyle) or data.vehicleInfo.aggregates["Body Style"]) or nil,
    jsonInsuranceClass = data.vehicleInfo and data.vehicleInfo.aggregates["InsuranceClass"] or nil,
  }

  -- extract commercial class from the vehicle info
  if data.vehicleInfo and data.vehicleInfo["Commercial Class"] then
    conditionData.commercialClass = tonumber(string.match(data.vehicleInfo["Commercial Class"], "%d+"))
  end

  -- for the tutorial car, there is no purchase data,
  local insuranceId = -1
  if data.purchaseData then
    if data.purchaseData.insuranceId then
      insuranceId = data.purchaseData.insuranceId
    end
  end

  local invVehData = career_modules_inventory.getVehicles()[data.inventoryId]
  local name = data.vehicleInfo and data.vehicleInfo.Name or invVehData.niceName
  local initialValue = data.vehicleInfo and data.vehicleInfo.Value or (invVehData.configBaseValue / 3)

  -- initialize the invVehs entry with default data. insuranceId starts at -1 (uninsured sentinel)
  -- so the invariant "always a number" holds even if the assignment below short-circuits.
  invVehs[data.inventoryId] = {
    insuranceId = -1,
    name = name,
    id = data.inventoryId,
    initialValue = initialValue,
    requiredInsuranceClass = getApplicableInsuranceClass(conditionData),
    insuranceData = {
      coverageOptionsData = {
        currentCoverageOptions = {},
        nextInsuranceEditTimer = 0,
      }
    }
  }
  -- initial assignment for a fresh inventory entry. Skip the "needs repair" gate and the
  -- paperwork-fee path: those belong to the user-driven changeInvVehInsurance flow, not to
  -- the act of registering a newly-purchased vehicle (which may already be damaged from a
  -- test drive).
  applyInvVehInsurance(data.inventoryId, insuranceId)
end

local function changeInvVehInsuranceCoverageOptions(invVehId, changedCoverageOptions)
  for coverageOptionName, coverageOptionValue in pairs(changedCoverageOptions) do
    local coverageOptionValueIndex = tableFindKey(availableInsurances[invVehs[invVehId].insuranceId].coverageOptions[coverageOptionName].changeability.changeParams.choices, coverageOptionValue)

    if plInsurancesData[invVehs[invVehId].insuranceId].coverageOptions[coverageOptionName] ~= nil then
      plInsurancesData[invVehs[invVehId].insuranceId].coverageOptions[coverageOptionName] = coverageOptionValueIndex
    end
  end

  career_modules_insurance_history.addToPlHistory({
    type = "insuranceCoverageChanged",
    title = _tr("ui.career.insurance.coverageChanged.title"),
    effects = {{type = "insuranceCoverageChanged", label = _tr("ui.career.insurance.coverageChanged.effect"), changedBy = -availableInsurances[invVehs[invVehId].insuranceId].paperworkFees, newValue = career_modules_playerAttributes.getAttributeValue("money")}},
    concernedInsuranceName = availableInsurances[invVehs[invVehId].insuranceId].name
  })

  local label = core_locales.contextTranslate("ui.career.insurance.coverageChanged.payment", {insuranceName = availableInsurances[invVehs[invVehId].insuranceId].name})
  career_modules_payment.pay({money = { amount = availableInsurances[invVehs[invVehId].insuranceId].paperworkFees, canBeNegative = false}}, {label=label})
  plInsurancesData[invVehs[invVehId].insuranceId].nextInsuranceEditTimer = insuranceEditTime

  M.sendUIData()
end

-- close the insurances computer menu
local function closeMenu(_closeMenuAfterSaving)
  closeMenuAfterSaving = career_career.isAutosaveEnabled() and _closeMenuAfterSaving

  if not closeMenuAfterSaving then
    if originComputerId then
      local computer = freeroam_facilities.getFacility("computer", originComputerId)
      career_modules_computer.openMenu(computer)
    else
      career_career.closeAllMenus()
    end
  end
end

local function onVehicleSaveFinished()
  if closeMenuAfterSaving then
    closeMenu()
    closeMenuAfterSaving = nil
  end
end

-- open the insurances computer menu
local function openMenu(_originComputerId)
  originComputerId = _originComputerId
  if originComputerId then
    tether = nil
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

    ui_router.navigate("career.computer.insurances")
    extensions.hook("onComputerInsurance")
  end
end

local function onMenuClosed()
  if tether then tether.remove = true tether = nil end
end

local function onExitInsurancesComputerScreen()
  insuranceMenuOpen = false
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if menuData.computerFacility.functions["insurances"] then
    local computerFunctionData = {
      id = "insurances",
      routeTarget = "career.computer.insurances",
      label = _tr("ui.career.insurance.title"),
      callback = function() openMenu(menuData.computerFacility.id) end,
      order = 15
    }
    if not menuData.hasBoughtStarterVehicle then
      computerFunctionData.disabled = true
      computerFunctionData.reason = career_modules_computer.reasons.hasBoughtStarterVehicle
    end
    computerFunctions.general[computerFunctionData.id] = computerFunctionData
  end
end

local function getDriverScoreResetCost()
  local currentScore = plDriverScore

  if currentScore >= defaultDriverScore then
    return 0
  end

  local distance = defaultDriverScore - currentScore
  local minCost = 500
  local maxCost = 20000

  local buyoutCost = minCost + math.abs(distance / defaultDriverScore) * (maxCost - minCost)

  return math.floor(buyoutCost)
end

local function resetDriverScore()
  local resetCost = getDriverScoreResetCost()
  if resetCost <= 0 then
    return false
  end

  local formattedPrice = {money = {amount = resetCost, canBeNegative = false}}
  if career_modules_payment.canPay(formattedPrice) then
    local oldScore = plDriverScore
    career_modules_payment.pay(formattedPrice, {label = _tr("ui.career.insurance.payment.driverScoreReset")})
    plDriverScore = defaultDriverScore
    career_modules_insurance_history.addToPlHistory({
      type = "driverScoreReset",
      title = _tr("ui.career.insurance.driverScoreReset.title"),
      effects = {
        {type = "money", label = _tr("ui.career.insurance.effect.money"), changedBy = -resetCost, newValue = career_modules_playerAttributes.getAttributeValue("money")},
        {type = "driverScore", label = _tr("ui.career.insurance.effect.driverScore"), changedBy = defaultDriverScore - oldScore, newValue = plDriverScore}
      }
    })
    sendUIData()
    career_modules_playerAbstract.sendPlayerAbstractDataToUI()
    return true
  end
  return false
end

local function getInvVehRepairTime(vehInvId)
  return getPlCoverageOptionValue(vehInvId, "repairTime")
end

local function getPlayerInsurancesData()
  return plInsurancesData
end

local function getQuickRepairExtraPrice()
  return quickRepairExtraPrice
end

local function getVehInsuranceInfo(vehInvId)
  if not invVehs[vehInvId] then return end
  return {
    isInsured = invVehs[vehInvId].insuranceId > 0,
    insuranceInfo = availableInsurances[invVehs[vehInvId].insuranceId],
    insuranceClass = invVehs[vehInvId].requiredInsuranceClass,
  }
end

local function expediteRepair(inventoryId, price)
  if career_modules_payment.pay({money = {amount = price, canBeNegative = false}}, {label = _tr("ui.career.insurance.payment.expeditedRepair")}) then
    local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
    vehInfo.timeToAccess = nil
    vehInfo.delayReason = nil
    career_modules_inventory.setVehicleDirty(inventoryId)
  end
end

local function saveNewInsuranceCoverageOptions(insuranceId, newCoverageOptions)
  if career_modules_payment.canPay({money = {amount = availableInsurances[insuranceId].paperworkFees, canBeNegative = false}}) then
    career_modules_payment.pay({money = {amount = availableInsurances[insuranceId].paperworkFees, canBeNegative = false}}, {label = _tr("ui.career.insurance.payment.coverageOptionsChanged")})
    gameplay_achievement.unlockAchievement("POLICY_REVIEW")
    -- check if roadsideAssistance was changed
    local oldRoadsideAssistance = plInsurancesData[insuranceId].coverageOptionsData.currentCoverageOptions["roadsideAssistance"]
    local newRoadsideAssistance = newCoverageOptions["roadsideAssistance"]

    plInsurancesData[insuranceId].coverageOptionsData.currentCoverageOptions = newCoverageOptions

    -- and if something was changed, top up roadside assistance
    if oldRoadsideAssistance ~= newRoadsideAssistance then
      M.topUpRoadsideAssistance(insuranceId)
    end

    sendUIData()
  end
end

local function saveNewVehicleCoverageOptions(vehicleId, newCoverageOptions)
  if career_modules_payment.canPay({money = {amount = availableInsurances[invVehs[vehicleId].insuranceId].paperworkFees, canBeNegative = false}}) then
    career_modules_payment.pay({money = {amount = availableInsurances[invVehs[vehicleId].insuranceId].paperworkFees, canBeNegative = false}}, {label = _tr("ui.career.insurance.payment.vehicleCoverageOptionsChanged")})
    invVehs[vehicleId].insuranceData.coverageOptionsData.currentCoverageOptions = newCoverageOptions
    sendUIData()
    gameplay_achievement.unlockAchievement("POLICY_REVIEW")
  end
end

local function topUpRoadsideAssistance(insuranceId)
  local roadsideAssistanceValueId = plInsurancesData[insuranceId].coverageOptionsData.currentCoverageOptions["roadsideAssistance"]
  local roadsideAssitanceCoverageAmount = availableInsurances[insuranceId].coverageOptions.roadsideAssistance.choices[roadsideAssistanceValueId].value
  plInsurancesData[insuranceId].roadsideAssistance = roadsideAssitanceCoverageAmount
end

local function isRoadSideAssistanceFree(invVehId)
  if not invVehs[invVehId] then return false end
  if not plInsurancesData[invVehs[invVehId].insuranceId] then return false end

  local value = plInsurancesData[invVehs[invVehId].insuranceId].roadsideAssistance
  return value > 0
end

local function useRoadsideAssistance(invVehId)
  if not invVehs[invVehId] then return end
  if not plInsurancesData[invVehs[invVehId].insuranceId] then return end

  plInsurancesData[invVehs[invVehId].insuranceId].roadsideAssistance = plInsurancesData[invVehs[invVehId].insuranceId].roadsideAssistance - 1
end

local function getTestDriveClaimPrice()
  return testDriveClaimPrice.money.amount
end

local function getPerkValueByInsuranceId(insuranceId, perkId)
  if availableInsurances[insuranceId] and availableInsurances[insuranceId].perks and availableInsurances[insuranceId].perks[perkId] then
    return availableInsurances[insuranceId].perks[perkId].value
  end
  return nil
end

local function getPerkValueByInvVehId(invVehId, perkId)
  local invVehData = invVehs[invVehId]
  if not invVehData then return nil end
  return getPerkValueByInsuranceId(invVehData.insuranceId, perkId)
end

local function getDefaultInsuranceForClassId(insuranceClassId)
  local matchingInsurances = {}

  -- collect all insurances that match the class
  for _, insuranceInfo in pairs(availableInsurances) do
    if insuranceInfo.class == insuranceClassId then
      table.insert(matchingInsurances, insuranceInfo)
    end
  end

  -- sort by id
  table.sort(matchingInsurances, function(a, b)
    return a.id < b.id
  end)

  return matchingInsurances[1]
end

local function getInvVehFuelDiscountData(invVehId)
local fuelDiscount = getPerkValueByInvVehId(invVehId, "fuelDiscount")

  local data = {
    hasFuelDiscount = fuelDiscount ~= nil,
    fuelDiscount = 0,
    perkData = nil,
  }

  if fuelDiscount then
    data.fuelDiscount = fuelDiscount
    data.insuranceName = availableInsurances[invVehs[invVehId].insuranceId].name
    local insuranceId = invVehs[invVehId].insuranceId
    local isSignaturePerk = availableInsurances[insuranceId].perks.fuelDiscount.isSignaturePerk or false
    data.perkData = formatPerkIconData(
      core_locales.contextTranslate("ui.career.insurance.perk.fuelDiscount", {percent = data.fuelDiscount * 100}),
      core_locales.contextTranslate("ui.career.insurance.perk.fuelDiscountTooltip", {insuranceName = data.insuranceName, percent = data.fuelDiscount * 100}),
      nil, isSignaturePerk)
    end

  return data
end

local function getInsuranceDataById(insuranceId)
  return availableInsurances[insuranceId]
end

local function openChooseInsuranceScreen()
  guihooks.trigger('ChangeState', {state = 'career.chooseInsurance', params = {}})
end

local function setDriverScore(score)
  plDriverScore = score
end

local function doesInsuranceExist(insuranceId)
  return availableInsurances[insuranceId] ~= nil
end

local function getInsuranceName(insuranceId)
  return availableInsurances[insuranceId] and availableInsurances[insuranceId].name or _tr("ui.career.insurance.noInsuranceName")
end

local function getAccidentForgivenessCount(insuranceId)
  return plInsurancesData[insuranceId] and plInsurancesData[insuranceId].accidentForgiveness or 0
end

local function getInvVehs()
  return invVehs
end

M.genericVehNeedsRepair = genericVehNeedsRepair
M.makeRepairClaim = makeRepairClaim
M.makeTestDriveDamageClaim = makeTestDriveDamageClaim
M.startRepairInstant = startRepairInstant
M.startRepair = startRepair
M.inventoryVehNeedsRepair = inventoryVehNeedsRepair
M.missionStartRepairCallback = missionStartRepairCallback
M.closeMenu = closeMenu
M.repairPartConditions = repairPartConditions
M.expediteRepair = expediteRepair
M.isRoadSideAssistanceFree = isRoadSideAssistanceFree
M.sendChooseInsuranceDataToTheUI = sendChooseInsuranceDataToTheUI
M.sendChangeInsuranceDataToTheUI = sendChangeInsuranceDataToTheUI
M.calculateAddVehiclePrice = calculateAddVehiclePrice
M.calculateInsurancePremium = calculateInsurancePremium
M.calculateVehiclePremium = calculateVehiclePremium
M.saveNewInsuranceCoverageOptions = saveNewInsuranceCoverageOptions
M.saveNewVehicleCoverageOptions = saveNewVehicleCoverageOptions
M.openChooseInsuranceScreen = openChooseInsuranceScreen
M.useRoadsideAssistance = useRoadsideAssistance

M.getInsuranceClassFromVehicleShoppingData = getInsuranceClassFromVehicleShoppingData
M.getInsuranceDataById = getInsuranceDataById
M.getVehInsuranceInfo = getVehInsuranceInfo
M.getQuickRepairExtraPrice = getQuickRepairExtraPrice
M.getInvVehRepairTime = getInvVehRepairTime
M.getPlayerInsurancesData = getPlayerInsurancesData
M.getPlHistory = function()
  return career_modules_insurance_history.getPlHistory()
end
M.getTestDriveClaimPrice = getTestDriveClaimPrice
M.getDefaultInsuranceForClassId = getDefaultInsuranceForClassId
M.getDriverScore = getDriverScore
M.resetDriverScore = resetDriverScore
M.getPlayerAbstractData = getPlayerAbstractData

M.startRepairInGarage = startRepairInGarage
M.openMenu = openMenu
M.sendUIData = sendUIData
M.changeInvVehInsuranceCoverageOptions = changeInvVehInsuranceCoverageOptions
M.changeInvVehInsurance = changeInvVehInsurance

-- hooks
M.onUpdate = onUpdate
M.onCareerActive = onCareerActive
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onComputerAddFunctions = onComputerAddFunctions
M.onVehicleSwitched = onVehicleSwitched
M.onEnterVehicleFinished = onEnterVehicleFinished
M.onMenuClosed = onMenuClosed
M.onExitInsurancesComputerScreen = onExitInsurancesComputerScreen
M.onVehicleSaveFinished = onVehicleSaveFinished

-- from vehicle inventory
M.onVehicleAddedToInventory = onVehicleAddedToInventory
M.onVehicleRemoved = onVehicleRemovedFromInventory

-- perks
M.getInvVehFuelDiscountData = getInvVehFuelDiscountData
M.getPerkValueByInvVehId = getPerkValueByInvVehId
M.getPerkValueByInsuranceId = getPerkValueByInsuranceId


-- internal use only
M.getActualRepairPrice = getActualRepairPrice
M.getPlCoverageOptionValue = getPlCoverageOptionValue
M.addToPlHistory = function(data)
  return career_modules_insurance_history.addToPlHistory(data)
end
M.formatPerkIconData = formatPerkIconData
M.getRenewsIn = getRenewsIn
M.topUpRoadsideAssistance = topUpRoadsideAssistance
M.getDriverScoreResetCost = getDriverScoreResetCost
M.sanitizeCoverageOption = sanitizeCoverageOption

M.getDriverScoreTierData = getDriverScoreTierData
M.doesInsuranceExist = doesInsuranceExist
M.getInsuranceName = getInsuranceName
M.getAccidentForgivenessCount = getAccidentForgivenessCount
M.getInvVehs = getInvVehs

-- career debug
M.resetPlPolicyData = function()
  loadInsurancesData(true)
end
M.setDriverScore = setDriverScore

return M