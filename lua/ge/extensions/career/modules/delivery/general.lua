-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"core_vehicleBridge"}
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dPages, dProgress, dVehicleTasks, dTasklist, dParcelMods, dVehOfferManager
M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dPages = career_modules_delivery_pages
  dProgress = career_modules_delivery_progress
  dVehicleTasks = career_modules_delivery_vehicleTasks
  dTasklist = career_modules_delivery_tasklist
  dParcelMods = career_modules_delivery_parcelMods
  dVehOfferManager = career_modules_delivery_vehicleOfferManager
end

local deliveryGameTime = 0

local deliveryModeActive = false
local deliveryAbandonPenaltyFactor = 0.1
M.getDeliveryAbandonPenaltyFactor = function() return deliveryAbandonPenaltyFactor end

-- Career general systems interaction (save/load, level setup)

local saveFile = "logisticsDatabase.json"
local loadData = {}
local function loadSaveData()
  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  if not saveSlot then return end
  local data = (savePath and jsonReadFile(savePath .. "/career/"..saveFile)) or {}

  loadData = data or {}
  dProgress.setProgress(loadData.progress)
  dParcelMods.setProgress(loadData.parcelModProgress)
  loadData.facilities = loadData.facilities or {}

  deliveryGameTime = loadData.general and loadData.general.gameTime or deliveryGameTime
  if loadData.general and loadData.general.osTime then
    log("I","",string.format("Save data age: %ds",os.time() - loadData.general.osTime))
    -- delete save data if the save is older than an hour
    if os.time() - loadData.general.osTime > 3600 then
      log("I","",string.format("Save data is older than 3600s (%d), wiping cargo and facility timers",os.time() - loadData.general.osTime))
      loadData.cargo = {}
      for key, fac in pairs(loadData.facilities) do
        fac.logisticGenerators = nil
      end
    end
  end

  --log("I","",string.format("Loaded save data for logistics: %d cargo", #loadData.cargo))
end
M.loadSaveData = loadSaveData
local function saveableCargoFilter(cargo)
  return cargo.offerExpiresAt > M.time() and cargo.location.type == "facilityParkingspot"
end
local function onSaveCurrentSaveSlot(currentSavePath)
  local filePath = currentSavePath .. "/career/" .. saveFile
  local saveData = {
    general = {},
    penalty = M.getDeliveryModePenalty(),
    parcels = {},
    vehicleOffers = {},
    facilities = {},
  }

  -- general data
  saveData.general.gameTime = M.time()
  saveData.general.osTime = os.time()
  saveData.progress = dProgress.getProgress()
  saveData.parcelModProgress = dProgress.getProgress()

  -- facility data

  -- parcels
  local saveableCargo = dParcelManager.getAllCargoCustomFilter(saveableCargoFilter)
  local maxGroupId = 0
  local groupMap = {}
  for _, cargo in ipairs(saveableCargo) do
    local elem = {
      rewards = cargo.rewards,
      templateId = cargo.templateId,
      name = cargo.name,
      type = cargo.type,
      slots = cargo.slots,
      offerExpiresAt = cargo.offerExpiresAt,
      location = cargo.location,
      origin = cargo.origin,
      destination = cargo.destination,
      data = cargo.data,
      generatorLabel = cargo.generatorLabel,
      modifiers = cargo.modifiers,
      generatedAtTimestamp = cargo.generatedAtTimestamp,
      weight = cargo.weight,
      groupSeed = cargo.groupSeed,
    }
    if not groupMap[cargo.groupId] then
      maxGroupId = maxGroupId + 1
      groupMap[cargo.groupId] = maxGroupId
    end
    elem.groupId = groupMap[cargo.groupId]
    table.insert(saveData.parcels, elem)
  end
  saveData.general.maxGroupId = maxGroupId

  local saveableVehicleOffers = dVehOfferManager.getAllOfferUnexpired()
  for _, offer in ipairs(saveableVehicleOffers) do
    -- vehicle offers dont need to be trunkated/cut before saving
    table.insert(saveData.vehicleOffers, offer)
  end

  -- facility data
  for _, facility in ipairs(dGenerator.getFacilities()) do
    local elem = {
      logisticGenerators = {},
      progress = facility.progress,
    }
    for i, generator in ipairs(facility.logisticGenerators or {}) do
      elem.logisticGenerators[i] = {
        nextGenerationTimestamp = generator.nextGenerationTimestamp
      }
    end
    saveData.facilities[facility.id] = elem
  end

  -- save the data to file
  career_saveSystem.jsonWriteFileSafe(filePath, saveData, true)
end
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

local function onCareerModulesActivated(alreadyInLevel)
  if alreadyInLevel then
    loadSaveData()
    map.assureLoad()
    dGenerator.setup(loadData)
  end
end
M.onCareerModulesActivated = onCareerModulesActivated

local function onClientStartMission(levelPath)
  loadSaveData()
  map.assureLoad()
  dGenerator.setup(loadData)
end
M.onClientStartMission = onClientStartMission


local fast = 1
M.time = function() return deliveryGameTime end



-- vehicle management

local function getVehicleName(vehId)
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  local niceVehicleName = inventoryId and career_modules_inventory.getVehicles()[inventoryId].niceName
  return niceVehicleName and niceVehicleName or ("Vehicle " .. vehId)
end
M.getVehicleName = getVehicleName


local mostRecentCargoContainerData = {}
local nearbyRadius = 25*25
local sortByVehIdAndContainerId = function(a,b) if a.vehId == b.vehId then return a.containerId < b.containerId else return a.vehId < b.vehId end end
local function getNearbyVehicleCargoContainers(callback)
  if not core_vehicleBridge then return {} end
  local vehCargoData = {}
  local playerPos = getPlayerVehicle(0)
  playerPos = playerPos and playerPos:getPosition() or core_camera.getPosition()
  local vehs = {}
  local refNodeClusterIdByVehId = {}
  for vehId, veh in activeVehiclesIterator() do
    if veh:getJBeamFilename() ~= "unicycle" and veh.playerUsable ~= false and (playerPos-veh:getPosition()):squaredLength() < nearbyRadius then
      vehCargoData[vehId] = -1
      vehs[vehId] = veh
      refNodeClusterIdByVehId[vehId] = veh:getNodeClusterId(veh:getRefNodeId())
    end
  end
  for vehId, veh in pairs(vehs) do

    core_vehicleBridge.requestValue(veh, function(vehCargoContainerData)
      vehCargoData[vehId] = {}

      for _, container in ipairs(vehCargoContainerData[1]) do

        local elem = {
          vehId = vehId,
          containerId = container.id,
          location = {type = "vehicle", vehId = veh:getID(), containerId = container.id},
          name = container.name,
          moveToLabel = getVehicleName(vehId) .. " " .. container.name,
          cargoTypesLookup = tableValuesAsLookupDict(container.cargoTypes),
          cargoTypesString = table.concat(container.cargoTypes,", "),
          totalCargoSlots = container.capacity,
          usedCargoSlots = 0,
          freeCargoSlots = container.capacity,
          refNodeClusterId = refNodeClusterIdByVehId[vehId],
          clusterId = container.nodeId and veh:getNodeClusterId(container.nodeId),
          position = (container.nodeId and veh:getNodePosition(container.nodeId) or vec3(0,0,0)) + veh:getPosition(),
        }


        if not elem.clusterId or elem.refNodeClusterId == elem.clusterId then
          elem.attachmentStatus = "attached"
        else
          local dist = (elem.position-veh:getPosition()):length()
          if dist < 10 then
            elem.attachmentStatus = "nearby"
          else
            elem.attachmentStatus = "lost"
          end
        end
        elem.rawCargo = dParcelManager.getAllCargoForLocation(elem.location)
        --for key, amount in pairs(elem.totalCargoSlots) do
        --  elem.usedCargoSlots[key] = 0
        --end
        for _, cargo in ipairs(elem.rawCargo) do
          elem.usedCargoSlots = elem.usedCargoSlots + cargo.slots
          elem.freeCargoSlots = elem.freeCargoSlots - cargo.slots
        end

        table.insert(vehCargoData[vehId], elem)
      end

      -- check if all cargo was sent
      for key, val in pairs(vehCargoData) do
        if val == -1 then return end
      end

      -- if we're still here, call the function callback to send data back
      local ret = {}
      for _, list in pairs(vehCargoData) do
        for _, elem in ipairs(list) do
          table.insert(ret, elem)
        end
      end
      table.sort(ret, sortByVehIdAndContainerId)
      mostRecentCargoContainerData = ret
      callback(ret)

    end, "getCargoContainers")
  end
  if not next(vehs) then
    callback({})
  end

end
M.getNearbyVehicleCargoContainers = getNearbyVehicleCargoContainers



local function updateContainerWeights(includeVehIds)
  log("I","","updateContainerWeights")
  local updatePerVehicle = {}
  for vehId, veh in activeVehiclesIterator() do
    if veh:getJBeamFilename() ~= "unicycle" and veh.playerUsable ~= false then
      updatePerVehicle[vehId] = {}
    end
  end
  for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles()) do
    updatePerVehicle[cargo.location.vehId][cargo.location.containerId] = updatePerVehicle[cargo.location.vehId][cargo.location.containerId] or {
      load = 0,
      containerId = cargo.location.containerId
    }
    if not cargo.weight then dump("No weight", cargo) end
    updatePerVehicle[cargo.location.vehId][cargo.location.containerId].load = updatePerVehicle[cargo.location.vehId][cargo.location.containerId].load + (cargo.weight or 0)
  end

  for vehId, data in pairs(updatePerVehicle) do
    local veh = scenetree.findObjectById(vehId)
    core_vehicleBridge.executeAction(veh, "setCargoContainers", updatePerVehicle[vehId])
    for _, con in pairs(updatePerVehicle[vehId]) do
      log("Container " .. con.containerId .. " => " .. con.load)
    end
  end
  log("I","","Cargo container weights updated.")

end
M.updateContainerWeights = updateContainerWeights


local colorForAttachmentDebug = {
  attached = ColorF(0.2,1,0.2, 0.75),
  nearby = ColorF(1,1,0.2, 0.75),
  lost = ColorF(1,0.2,0.2, 0.75),
}
local tickTimer = 0
M.onUpdate = function(dtReal, dtSim, dtRaw)
  profilerPushEvent("Delivery DeliveryManager")
  -- update game time
  if freeroam_bigMapMode.bigMapActive() and not freeroam_bigMapMode.isTransitionActive() then
    deliveryGameTime = deliveryGameTime + dtReal * fast
  else
    deliveryGameTime = deliveryGameTime + dtSim * fast
  end

  -- handle penalty from previous save
  if loadData.penalty and loadData.penalty > 0 then
    --ui_message(string.format("Penalty for abandoning cargo: %0.2f$", loadData.penalty),10, "exitDeliveryMode", "warning")
    guihooks.trigger("toastrMsg", {type="warning", title="Cargo abandoned", msg=string.format("Cargo from last save was abandoned. Penalty: %0.2f$", loadData.penalty)})
    log("I","",string.format("Penalty for abandoning cargo: %0.2f$", loadData.penalty))
    career_modules_playerAttributes.addAttributes({money=-loadData.penalty}, {tags={"gameplay", "delivery","fine"}, label="Penalty for abandoning cargo."})
    loadData.penalty = nil
  end

  tickTimer = tickTimer + dtSim
  if tickTimer > 1 then
    M.getNearbyVehicleCargoContainers(nop)
    tickTimer = tickTimer - 1
  end

  -- debug display for cargo boxes
  --[[
  if deliveryModeActive then
    for _, container in ipairs(mostRecentCargoContainerData) do
      simpleDebugText3d(container.name, container.position, 0.15, colorForAttachmentDebug[container.attachmentStatus])
    end
  end
  ]]

  profilerPopEvent("Delivery DeliveryManager")
end


-- poi list stuff
local function onGetRawPoiListForLevel(levelIdentifier, elements)

  --local nearbyVehicles = M.getNearbyVehicleCargoContainers()
  local playerDestinationParkingSpots = {}
  for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles()) do
    playerDestinationParkingSpots[cargo.destination.psPath] = playerDestinationParkingSpots[cargo.destination.psPath] or {facId = cargo.destination.facId, cargo = {}}
    table.insert(playerDestinationParkingSpots[cargo.destination.psPath].cargo, cargo)
  end

  -- figure out which facilities need to be active in order to drop of vehicles.
  local trailerTargetDestinations = dVehicleTasks.getTargetDestinationsForActiveTasks()
  local targetFacilityIds = {}
  for _, destination in ipairs(trailerTargetDestinations) do
    targetFacilityIds[destination.facId] = true
    playerDestinationParkingSpots[destination.psPath] = playerDestinationParkingSpots[destination.psPath] or {facId = destination.facId, cargo = {}}
    table.insert(playerDestinationParkingSpots[destination.psPath].cargo, "trailer")
  end

  for _, fac in ipairs(freeroam_facilities.getFacilitiesByType("deliveryProvider")) do
    -- only process facilities if the facility is visible
    local includeFac = dProgress.isFacilityVisible(fac.id) or targetFacilityIds[fac.id]

    if includeFac then
      local totalCargoCount = 0
      local lastPsPos = nil
      local allSpotsLookup = {}

      if next(fac.logisticTypesProvided) then
        for _, ps in ipairs(fac.pickUpSpots or {}) do
          allSpotsLookup[ps:getPath()] = ps
        end
      end

      for _, ps in ipairs(fac.dropOffSpots or {}) do
        if playerDestinationParkingSpots[ps:getPath()] or dCargoScreen.isCargoScreenOpen() then
          allSpotsLookup[ps:getPath()] = ps
        end
      end

      for _, ps in pairs(allSpotsLookup) do
        local id = string.format("delivery-parking-%s-%s", fac.id, ps:getPath())
        local loc = {type = "facilityParkingspot", facId = fac.id, psPath = ps:getPath()}
        local cargoCount = #dParcelManager.getAllCargoForLocationUnexpiredUndelivered(loc)
        totalCargoCount = totalCargoCount + cargoCount
        lastPsPos = ps.pos
        local icon = "poi_pickup_round"
        if playerDestinationParkingSpots[ps:getPath()] then
          icon = "poi_dropoff_round"
        end

        local focus = playerDestinationParkingSpots[ps:getPath()] ~= nil
        local elem = {
          id = id,
          data = {type = "logisticsParking", facId = fac.id, psPath = ps:getPath(), hasPlayerCargo = playerDestinationParkingSpots[ps:getPath()] and true or false },
          markerInfo = {
            -- only include parking marker if there is an action
            parkingMarker = cargoCount and {path = ps:getPath(), pos = ps.pos, rot = ps.rot, scl = ps.scl, icon = icon, focus = focus} or nil,
          }
        }
        --print(string.format("including: %s-%s (%s). visible: %s, target: %s",
        --  fac.id, ps.id,
        --  dParcelManager.getLocationLabelShort({type="facilityParkingspot", facId = fac.id, psPath = ps:getPath()}),
        --  dumps(dProgress.isFacilityVisible(fac.id)),
        --  dumps(targetFacilityIds[fac.id] and true or false)
        --  ))
        if dCargoScreen.isCargoScreenOpen() then
          elem.markerInfo.bigmapMarker = {pos = ps.pos, name = "Pickup "..fac.name, icon = icon}
        else
          if playerDestinationParkingSpots[ps:getPath()] then
            local desc = string.format("Deliver %d cargo items to this location.", #playerDestinationParkingSpots[ps:getPath()].cargo)
            elem.markerInfo.bigmapMarker = {
              pos = ps.pos,
              name = dParcelManager.getLocationLabelShort(loc),
              description = desc,
              icon = "poi_dropoff_round",
              previews = {fac.preview},
              thumbnail = fac.preview,
            }
          end
        end
        table.insert(elements, elem)
      end

      -- add trailer spots in a separate entry.
      if dCargoScreen.isCargoScreenOpen() then
        for _, ps in ipairs(fac.trailerSpots) do

          local id = string.format("delivery-parking-%s-%s", fac.id, ps:getPath())
          local loc = {type = "facilityParkingspot", facId = fac.id, psPath = ps:getPath()}

          local icon = "poi_pickup_round"
          if playerDestinationParkingSpots[ps:getPath()] then
            icon = "poi_dropoff_round"
          end

          local elem = {
            id = id,
            data = {type = "logisticsParking", facId = fac.id, psPath = ps:getPath(), hasPlayerCargo = playerDestinationParkingSpots[ps:getPath()] and true or false },
            markerInfo = {
              bigmapMarker = {pos = ps.pos, name = "Pickup "..fac.name, icon = icon}
            }
          }
          table.insert(elements, elem)

        end

     end

      -- one POI for the whole facility to display on bigmap under labourer branch.
      if not dCargoScreen.isCargoScreenOpen() then
        if dProgress.isFacilityUnlocked(fac.id) and next(fac.logisticTypesProvided) then
          local id = string.format("logisticsFacility-%s", fac.id)
          local elems = {}
          if fac.doors and next(fac.doors) then
            freeroam_facilities.walkingMarkerFormatFacility(fac, elems)
          end
          local elem = {
            id = id,
            data = {type = "logisticsOffice", facId = fac.id},
            markerInfo = {
              walkingMarker = next(elems) and elems[1].markerInfo.walkingMarker or nil,
              bigmapMarker = {pos = lastPsPos, name = fac.name, description = string.format("%s\n\n%d Item%s available here.",fac.description, totalCargoCount, totalCargoCount ~= 1 and "s" or ""), icon="poi_delivery_round", previews = {fac.preview}, thumbnail = fac.preview,} or nil
            }
          }
          table.insert(elements, elem)
        end
      end
    end
  end
end
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel



local function onActivityAcceptGatherData(elemData, activityData)
  for _, elem in ipairs(elemData) do
    if elem.type == "logisticsOffice" then
      local data = {
        icon = "poi_delivery_round",
        heading = dGenerator.getFacilityById(elem.facId).name,
        preheadings = {"Logistics Office"},
        sorting = {
          type = elem.type,
          id = elem.id
        },
        props = {{
          icon = "checkmark",
          keyLabel = "Cargo Overview"
        },{
          icon = "checkmark",
          keyLabel = "No Cargo Pickup"
        }},
        buttonLabel = "Inspect Cargo",
        buttonFun = function() dCargoScreen.enterCargoOverviewScreen(elem.facId) end
      }
      table.insert(activityData, data)
    elseif elem.type == "logisticsParking" then
      -- figure out how much/which cargo can be dropped of here
      local psPos = dGenerator.getParkingSpotByPath(elem.psPath).pos
      local parcelsClose = 0
      for _, container in ipairs(mostRecentCargoContainerData) do
        for _, cargo in ipairs(container.rawCargo) do
          parcelsClose  = parcelsClose + ((cargo.destination.psPath == elem.psPath and (container.position - psPos):squaredLength() < 25*25) and 1 or 0)
        end
      end

      local vehsClose, trailersClose = dVehicleTasks.canDropOffCargoAtPsPath(elem.psPath)

      local anyCargoClose = parcelsClose > 0 or vehsClose > 0 or trailersClose > 0
      -- cargo menu button
      local props = {}
      local data = {
        icon = "poi_pickup_round",
        heading = dParcelManager.getLocationLabelShort({type = "facilityParkingspot", facId = elem.facId, psPath = elem.psPath}),
        preheadings = {},
        sorting = {
          type = elem.type,
          id = elem.id
        },
        props = {},
        buttonLabel = anyCargoClose and "Drop Off" or "Inspect",
        buttonFun = function()

          if not anyCargoClose then
            dCargoScreen.enterCargoOverviewScreen(elem.facId, elem.psPath)
          else
            dProgress.unloadCargo(elem)
          end
        end
      }

      -- additional props and headings

      -- parcel props
      local loc = {type = "facilityParkingspot", facId = elem.facId, psPath = elem.psPath}
      local cargoCount = #dParcelManager.getAllCargoForLocationUnexpiredUndelivered(loc)
      if cargoCount > 0 then
        table.insert(data.props, {
          icon = "checkmark",
          keyLabel = string.format("%d parcel%s available", cargoCount, cargoCount ~= 1 and "s" or "")
        })
      end

      -- veh and trailer props
      local vehOffers, trailerOffers = {}, {}
      for _, offer in ipairs(dVehOfferManager.getAllOfferAtFacilityUnexpired(elem.facId)) do
        if offer.data.type == "vehicle" then
          table.insert(vehOffers, offer)
        end
        if offer.data.type == "trailer" then
          table.insert(trailerOffers, offer)
        end
      end
      if #vehOffers > 0 then
        table.insert(data.props, {
          icon = "checkmark",
          keyLabel = string.format("%d vehicle transport%s available", #vehOffers, #vehOffers ~= 1 and "s" or "")
        })
      end
      if #trailerOffers > 0 then
        table.insert(data.props, {
          icon = "checkmark",
          keyLabel = string.format("%d trailer transport%s available", #trailerOffers, #trailerOffers ~= 1 and "s" or "")
        })
      end

      -- headings
      if next(trailerOffers) or next(vehOffers) or cargoCount > 0 then
        table.insert(data.preheadings, "Delivery Facility")
      end
      if anyCargoClose then
        table.insert(data.preheadings, "Delivery Dropoff")
      end

      if not next(data.preheadings) then
        data.preheadings = {"Delivery Location"}
      end

      -- dropoff props
      if parcelsClose > 0 then
        table.insert(data.props, {
          icon = "checkmark",
          keyLabel = string.format("%sParcel%s dropoff", parcelsClose > 1 and ((parcelsClose).." ") or "", parcelsClose > 1 and "s" or "")
        })
      end
      if vehsClose > 0 then
        table.insert(data.props, {
          icon = "checkmark",
          keyLabel = "Vehicle dropoff"
        })
      end
      if trailersClose > 0 then
        table.insert(data.props, {
          icon = "checkmark",
          keyLabel = "Trailer dropoff"
        })
      end

      table.insert(activityData, data)

    end
  end
end
M.onActivityAcceptGatherData = onActivityAcceptGatherData


local deliveryActivity = {
  id = "deliveryMode",
  name = "Delivery Mode",

  vehicleModification = "warning",-- Slow and Fast Repairing, Changing and buying parts, tuning, painting
  vehicleSelling = "warning", --selling a vehicle
  vehicleStorage = "warning", --put vehicles into storage
  vehicleRetrieval = "allowed", --retrieve vehicles from storage

  vehicleShopping = "forbidden",

  interactRefuel = "allowed", --use the refueling POI to refuel vehicle
  interactMission = "warning", --use the mission POI to start a mission
  interactDelivery = "allowed", --use any delivery POI to start delivery mode

  recoveryFlipUpright = "allowed", --flip upright
  recoveryTowToRoad = "allowed", --tow to road
  recoveryTowToGarage = "warning", --tow to garage

  getLabel = function(tag, permission)
    local penalty = M.getDeliveryModePenalty()
    if     tag == "vehicleModification" then
      return string.format("Modifying a vehicle will end Delivery Mode (Penalty: %0.2f$)", penalty)
    elseif tag == "vehicleSelling" then
      return string.format("Selling a vehicle will end Delivery Mode (Penalty: %0.2f$)", penalty)
    elseif tag == "vehicleStorage" then
      return string.format("Storing a vehicle will end Delivery Mode (Penalty: %0.2f$)", penalty)
    elseif tag == "interactMission" then
      return string.format("Starting a Mission will end Delivery Mode (Penalty: %0.2f$)", penalty)
    elseif tag == "recoveryTowToGarage" then
      return string.format("Towing to garage will end Delivery Mode (Penalty: %0.2f$)", penalty)
    elseif tag == "vehicleShopping" then
      return "Disabled during Delivery Mode."
    end
  end
}

local function startDeliveryMode()
  if deliveryModeActive then return end
  log("I","","Delivery Mode Started.")
  deliveryModeActive = true
  career_modules_permissions.setForegroundActivity(deliveryActivity)
  gameplay_rawPois.clear()
  extensions.hook("onDeliveryModeStarted")
end

local function exitDeliveryMode()
  if not deliveryModeActive then return end
  log("I","","Delivery Mode Exited.")
  dParcelManager.clearTransientFlags()
  -- get all cargo currently in vehicles.
  local cargoInVehicles = dParcelManager.getAllCargoInVehicles()
  --dump(cargoInVehicles)
  if next(cargoInVehicles) then
    local totalMoneyRewards = 0
    for _, cargo in ipairs(cargoInVehicles) do
      totalMoneyRewards = totalMoneyRewards + cargo.rewards.money
      dParcelManager.changeCargoLocation(cargo.id, {type="deleted"})
    end
    if totalMoneyRewards > 0 then
      guihooks.trigger("toastrMsg", {type="warning", title="Cargo abandoned", msg=string.format("Cargo was thrown away because delivery mode ended. Penalty: %0.2f$", totalMoneyRewards * M.getDeliveryAbandonPenaltyFactor())})
      log("I","",string.format("Penalty for abandoning cargo: %0.2f$", totalMoneyRewards * M.getDeliveryAbandonPenaltyFactor()))
      career_modules_playerAttributes.addAttributes({money=-totalMoneyRewards  * M.getDeliveryAbandonPenaltyFactor()}, {tags={"gameplay", "delivery","fine"}, label="Penalty for abandoning cargo."})
      Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
    end
  end
  deliveryModeActive = false
  career_modules_permissions.clearForegroundActivityIfIdIs('deliveryMode')
  gameplay_rawPois.clear()
  core_groundMarkers.setFocus(nil)

  M.updateContainerWeights()
  dTasklist.clearAll()
  --core_gamestate.setGameState("career", "career")
  extensions.hook("onDeliveryModeStopped")
end

local function checkExitDeliveryMode()
  local cargoInVehicles = dParcelManager.getAllCargoInVehicles()
  local vehicleTasks = dVehicleTasks.getVehicleTasks()
  if not next(cargoInVehicles) and not next(vehicleTasks) then
    M.exitDeliveryMode()
  end
end

M.startDeliveryMode = startDeliveryMode
M.exitDeliveryMode = exitDeliveryMode
M.checkExitDeliveryMode = checkExitDeliveryMode
M.isDeliveryModeActive = function() return deliveryModeActive end
M.getDeliveryModePenalty = function()
  local cargoInVehicles = dParcelManager.getAllCargoInVehicles()
  --dump(cargoInVehicles)
  if next(cargoInVehicles) then
    local totalMoneyRewards = 0
    for _, cargo in ipairs(cargoInVehicles) do
      totalMoneyRewards = totalMoneyRewards + cargo.rewards.money
    end
    return totalMoneyRewards * M.getDeliveryAbandonPenaltyFactor()
  end
  return 0
end

-- actions that stop delivery mode

M.onPartShoppingStarted = function()
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because shopping started.")
    M.exitDeliveryMode()
  end
end

M.onCareerPaintingStarted = function()
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because painting started.")
    M.exitDeliveryMode()
  end
end

M.onCareerTuningStarted = function()
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because tuning started.")
    M.exitDeliveryMode()
  end
end

M.onTeleportedToGarage = function(garageId, veh)
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because towed to garage.")
    M.exitDeliveryMode()
  end
end

M.onAnyMissionChanged = function(change)
  if change == "started" then
    if deliveryModeActive then
      log("I","","Stopped Delivery mode because mission started.")
      M.exitDeliveryMode()
    end
  end
end

M.onInventoryPreRemoveVehicleObject = function(inventoryId, vehId)
  if deliveryModeActive then
    -- TODO: this needs to check for cargo in vehicle containers, not just vehicle
    local cargoInVehicle = dParcelManager.getAllCargoForLocation({type = "vehicle", vehId = vehId})
    if next(cargoInVehicle) then
      local totalMoneyRewards = 0
      for _, cargo in ipairs(cargoInVehicle) do
        totalMoneyRewards = totalMoneyRewards + cargo.rewards.money
        dParcelManager.changeCargoLocation(cargo.id, {type="deleted"})
      end
      if totalMoneyRewards > 0 then
        guihooks.trigger("toastrMsg", {type="warning", title="Cargo abandoned", msg=string.format("Cargo was thrown away because vehicle was put into storage. Penalty: %0.2f$", totalMoneyRewards * M.getDeliveryAbandonPenaltyFactor())})
        log("I","",string.format("Penalty for abandoning cargo: %0.2f$", totalMoneyRewards * M.getDeliveryAbandonPenaltyFactor()))
        career_modules_playerAttributes.addAttributes({money=-totalMoneyRewards  * M.getDeliveryAbandonPenaltyFactor()}, {tags={"gameplay", "delivery","fine"}, label="Penalty for abandoning cargo."})
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
      end
    end
    checkExitDeliveryMode()
  end
end

return M
