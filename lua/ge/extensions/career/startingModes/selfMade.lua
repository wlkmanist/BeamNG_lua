return {
  ignore = true,
  id = "selfMade",
  order = 300,
  tier = "minor",
  title = "Self-Made",
  description = "Start with nothing but a beaten down car, a handful of dollars and a dream.",
  image = "images/career/start_beater.jpg",
  initPlayerAttributes = function(playerAttributes)
    playerAttributes.setAttributes({money = 1000}, {label = "Starting Capital"})
  end,
  setupInventory = function(inventoryModule)
    local beaterFilter = {
      whiteList = {
        Years = {min = 1990, max = 2005},
        Value = {min = 1000, max = 50000},
        ["Config Type"] = {"Factory", "Service"},
      },
    }

    local targetValue = 4000 + math.random() * 1000
    log("I", "career.inventory", string.format("SelfMade starter generation started. Target value: $%d", targetValue))
    log("I", "career.inventory", string.format("SelfMade filter: Years %d-%d, Value %d-%d, ConfigType=%s/%s",
      beaterFilter.whiteList.Years.min,
      beaterFilter.whiteList.Years.max,
      beaterFilter.whiteList.Value.min,
      beaterFilter.whiteList.Value.max,
      beaterFilter.whiteList["Config Type"][1],
      beaterFilter.whiteList["Config Type"][2]
    ))

    local function estimateMileageForTarget(baseValue, year)
      local age = 2023 - year
      local low, high = 0, 2000000000
      local bestMileage = low
      local bestDiff = math.huge

      for _ = 1, 28 do
        local mid = (low + high) * 0.5
        local adjustedValue = career_modules_valueCalculator.getAdjustedVehicleBaseValue(baseValue, {
          mileage = mid,
          age = age
        })
        local diff = math.abs(adjustedValue - targetValue)
        if diff < bestDiff then
          bestDiff = diff
          bestMileage = mid
        end

        if adjustedValue > targetValue then
          low = mid
        else
          high = mid
        end
      end

      return bestMileage
    end

    local function pickYear(vehicleInfo, filter)
      local years = vehicleInfo.Years or (vehicleInfo.aggregates and vehicleInfo.aggregates.Years)
      local minYear = (years and years.min) or 2023
      local maxYear = (years and years.max) or 2023

      if filter.whiteList and filter.whiteList.Years then
        if filter.whiteList.Years.min then minYear = math.max(minYear, filter.whiteList.Years.min) end
        if filter.whiteList.Years.max then maxYear = math.min(maxYear, filter.whiteList.Years.max) end
      end

      if minYear > maxYear then
        minYear, maxYear = maxYear, minYear
      end
      return math.random(minYear, maxYear)
    end

    local configListGenerator = require('/lua/ge/extensions/util/configListGenerator')
    local eligibleVehicles = configListGenerator.getEligibleVehicles()
    log("I", "career.inventory", string.format("SelfMade eligible vehicles before filter: %d", #eligibleVehicles))
    local filteredVehicles = {}
    for _, vehicleInfo in ipairs(eligibleVehicles) do
      if configListGenerator.doesVehiclePassFilter(vehicleInfo, beaterFilter) then
        table.insert(filteredVehicles, vehicleInfo)
      end
    end
    log("I", "career.inventory", string.format("SelfMade eligible vehicles after filter: %d", #filteredVehicles))

    local selectedVehicle = nil
    local selectedYear = nil
    local selectedMileage = nil
    local selectedAdjustedValue = nil
    local selectedDiff = math.huge

    local inspectedCount = 0
    arrayShuffle(filteredVehicles)
    for _, vehicleInfo in ipairs(filteredVehicles) do
      inspectedCount = inspectedCount + 1
      local year = pickYear(vehicleInfo, beaterFilter)
      local mileage = estimateMileageForTarget(vehicleInfo.Value or 0, year)
      local adjustedValue = career_modules_valueCalculator.getAdjustedVehicleBaseValue(vehicleInfo.Value or 0, {
        mileage = mileage,
        age = 2023 - year
      })
      local diff = math.abs(adjustedValue - targetValue)
      if inspectedCount <= 10 then
        log("I", "career.inventory", string.format(
          "SelfMade candidate #%d: %s / %s | base=%.2f year=%d mileage=%.0f adjusted=%.2f diff=%.2f",
          inspectedCount,
          tostring(vehicleInfo.model_key),
          tostring(vehicleInfo.key),
          vehicleInfo.Value or 0,
          year,
          mileage,
          adjustedValue,
          diff
        ))
      end
      if diff < selectedDiff then
        selectedVehicle = vehicleInfo
        selectedYear = year
        selectedMileage = mileage
        selectedAdjustedValue = adjustedValue
        selectedDiff = diff
        log("I", "career.inventory", string.format(
          "SelfMade best so far: %s / %s | adjusted=%.2f target=%d diff=%.2f mileage=%.0f year=%d",
          tostring(selectedVehicle.model_key),
          tostring(selectedVehicle.key),
          selectedAdjustedValue,
          targetValue,
          selectedDiff,
          selectedMileage,
          selectedYear
        ))
      end
    end
    log("I", "career.inventory", string.format("SelfMade inspected candidates: %d", inspectedCount))

    if not selectedVehicle then
      log("W", "", "No eligible selfMade beater vehicle found; falling back to tutorial Sunburst.")
      selectedVehicle = {model_key = "sunburst2", key = "vehicles/sunburst2/apmTutorial_sunburst.pc"}
      selectedYear = 2005
      selectedMileage = 250000000
      selectedAdjustedValue = career_modules_valueCalculator.getAdjustedVehicleBaseValue(8000, {
        mileage = selectedMileage,
        age = 2023 - selectedYear
      })
    end

    local model = selectedVehicle.model_key
    local config = selectedVehicle.key
    local randomPaintName = nil
    local modelData = core_vehicles.getModel(model)
    local modelPaints = modelData and modelData.model and modelData.model.paints
    if modelPaints then
      local paintNames = tableKeys(modelPaints)
      if paintNames and #paintNames > 0 then
        randomPaintName = paintNames[math.random(#paintNames)]
      end
    end

    local pos, rot = vec3(838.51, -522.42, 165.75), quat(0, 0, 0, 1)
    local options = {
      config = config,
      pos = pos,
      rot = rot
    }
    if randomPaintName then
      options.paintName = randomPaintName
      options.paintName2 = randomPaintName
      options.paintName3 = randomPaintName
      log("I", "career.inventory", string.format("SelfMade selected random paint: %s", tostring(randomPaintName)))
    else
      log("W", "career.inventory", string.format("SelfMade could not determine random paint for model: %s", tostring(model)))
    end
    local spawningOptions = sanitizeVehicleSpawnOptions(model, options)
    spawningOptions.autoEnterVehicle = true
    log("I", "career.inventory", string.format(
      "SelfMade spawning selected vehicle: %s / %s | paint=%s year=%d mileage=%.0f adjusted=%.2f target=%d diff=%.2f",
      tostring(model),
      tostring(config),
      tostring(randomPaintName),
      selectedYear or -1,
      selectedMileage or -1,
      selectedAdjustedValue or -1,
      targetValue,
      selectedDiff or -1
    ))
    local veh = core_vehicles.spawnNewVehicle(model, spawningOptions)
    inventoryModule.addVehicle(veh:getID())
    core_vehicleBridge.executeAction(veh, 'initPartConditions', {}, selectedMileage, 1, 1)

    core_vehicleBridge.requestValue(veh, function(ret)
      for _, tank in ipairs(ret[1]) do
        core_vehicleBridge.executeAction(veh, 'setEnergyStorageEnergy', tank.name, tank.maxEnergy * 0.15)
      end
    end, 'energyStorage')
  end,
}
