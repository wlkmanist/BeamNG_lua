-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dParcelMods, dTutorial
M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dProgress = career_modules_delivery_progress
  dTutorial = career_modules_delivery_tutorial
end

local modifiers = {
  timed = {
    unlockFlag = "smallPackagesDelivery",
    makeTemplate = function(g,p,distance)
      local time = (distance / 13) + 30 * math.random() + 30
      return {
        type = "timed",
        timeUntilDelayed = time,
        timeUntilLate = time * 1.25 + 15,
        --paddingTime = time * 0.2 + 10,
        --timeMessageFlag = false,
        --paddingTimeMessageFlag = false,
        moneyMultipler = 1.5,
      }
    end,
    unlockLabel = "ui.career.delivery.parcelMods.timed.unlockLabel",
    priority = 1,
    icon = "stopwatchSectionSolidEnd",
    label = "ui.career.delivery.parcelMods.timed.label",
    shortDescription = "ui.career.delivery.parcelMods.timed.description",
    important = true,
  },
  post = {
    unlockFlag = "smallPackagesDelivery",
    makeTemplate = function(g,p,distance)
      return {
        type = "post",
        moneyMultipler = 1.2,
      }
    end,
    unlockLabel = "ui.career.delivery.parcelMods.post.unlockLabel",
    priority = 2,
    icon = "envelope",
    label = "ui.career.delivery.parcelMods.post.label",
    shortDescription = "",
    hidden=true,
  },
  precious = {
    unlockFlag = "largePackagesDelivery",
    penalty = 3,
    makeTemplate = function(g,p,distance)
      return {
        type = "precious",
        moneyMultipler = 2.5,
        abandonMultiplier = 1.0,
      }
    end,
    unlockLabel = "ui.career.delivery.parcelMods.precious.unlockLabel",
    priority = 3,
    icon = "fragile",
    label = "ui.career.delivery.parcelMods.precious.label",
    shortDescription = "ui.career.delivery.parcelMods.precious.description",
    important = true,

  },
  supplies = {
    unlockFlag = "largePackagesDelivery",
    makeTemplate = function(g,p,distance)
      return {
        type = "supplies",
        moneyMultipler = 1.0,
      }
    end,
    unlockLabel = "ui.career.delivery.parcelMods.supplies.unlockLabel",
    priority = 4,
    icon = "cardboardBox",
    label = "ui.career.delivery.parcelMods.supplies.label",
    shortDescription = "",
    hidden=true,
  },
  large = {
    unlockFlag = "largePackagesDelivery",
    makeTemplate = function(g,p,distance)
      return {
        type = "large",
        moneyMultipler = 1.2,
      }
    end,
    unlockLabel = "ui.career.delivery.parcelMods.large.unlockLabel",
    priority = 5,
    icon = "group",
    label = "ui.career.delivery.parcelMods.large.label",
    shortDescription = "ui.career.delivery.parcelMods.large.description"
  },
  fluid = {
    unlockFlag = "hazardousMaterialsDelivery",
    makeTemplate = function(g,p,distance)
      return {
        type = "fluid",
      }
    end,
    unlockLabel = "ui.career.delivery.parcelMods.fluid.unlockLabel",
    priority = 6,
    icon = "droplet",
    label = "ui.career.delivery.parcelMods.fluid.label",
    shortDescription = "ui.career.delivery.parcelMods.fluid.description"
  },
  dryBulk = {
    unlockFlag = "hazardousMaterialsDelivery",
    makeTemplate = function(g,p,distance)
      return {
        type = "dryBulk",
      }
    end,
    unlockLabel = "ui.career.delivery.parcelMods.dryBulk.unlockLabel",
    priority = 6,
    icon = "rocks",
    label = "ui.career.delivery.parcelMods.dryBulk.label",
    shortDescription = "ui.career.delivery.parcelMods.dryBulk.description"
  },
  parcel = {
    unlockFlag = "smallPackagesDelivery",
    makeTemplate = function(g,p,distance)
      return {
        type = "parcel",
      }
    end,
    unlockLabel = "ui.career.delivery.parcelMods.parcel.unlockLabel",
    priority = 6,
    icon = "cardboardBox",
    label = "ui.career.delivery.parcelMods.parcel.label",
    shortDescription = "ui.career.delivery.parcelMods.parcel.description",
    hidden=true,
  },
  hazardous = {
    unlockFlag = "hazardousMaterialsDelivery",
    makeTemplate = function(g,p,distance)
      return {
        type = "hazardous",
      }
    end,
    unlockLabel = "ui.career.delivery.parcelMods.hazardous.unlockLabel",
    priority = 6,
    icon = "roadblockL",
    label = "ui.career.delivery.parcelMods.hazardous.label",
    shortDescription = "ui.career.delivery.parcelMods.hazardous.description",

  },
}


local progressTemplate = {
  timed = {
    delivieries = 0,
    onTimeDeliveries = 0,
    delayedDeliveries = 0,
    lateDeliveries = 0,
  },
  large = {
    delivieries = 0,
  },
  precious = {
    delivieries = 0,
    lost = 0,
  },
  heavy = {
    delivieries = 0,
  },
  post = {
    delivieries = 0
  }
}

local progress = deepcopy(progressTemplate)

M.setProgress = function(data)
  progress = data or deepcopy(progressTemplate)
end

M.getProgress = function()
  return progress
end

M.getModData = function(key)
  local modifier = modifiers[key]
  if not modifier then return nil end
  local data = {}
  for field, value in pairs(modifier) do
    data[field] = value
  end
  data.unlockLabel = _tr(data.unlockLabel)
  data.label = _tr(data.label)
  data.shortDescription = data.shortDescription ~= "" and _tr(data.shortDescription) or ""
  return data
end
M.getModifierIcon = function(key) return modifiers[key].icon end
M.getLabelAndShortDescription = function(key)
  local modifier = modifiers[key]
  return _tr(modifier.label), modifier.shortDescription ~= "" and _tr(modifier.shortDescription) or ""
end
M.isImportant = function(key) return modifiers[key].important or false end

local function calculateTimedModifierTime(distance)
  local r = math.random()+1
  return (distance / 13) + (30 * r)
end
M.calculateTimedModifierTime = calculateTimedModifierTime

local sortByPrio = function(a,b) return modifiers[a.type].priority < modifiers[b.type].priority end

local modifierProbability = 1
local largeSlotThreshold = 65
local heavyWeightThreshold = 80
local function generateModifiers(item, parcelTemplate, distance)
  local mods = {}
  math.randomseed(item.groupSeed)

  local r = math.random()
  --for _, modKey in ipairs(tableKeysSorted(modifiers)) do
  for _, modKey in ipairs(tableKeysSorted(parcelTemplate.modChance)) do
    if r <= parcelTemplate.modChance[modKey] then
      local modTemplate = modifiers[modKey].makeTemplate(item.groupSeed, parcelTemplate, distance)
      table.insert(mods, modTemplate)
    end
    r = math.random()
  end

  if item.slots >= largeSlotThreshold or item.weight >= heavyWeightThreshold and not parcelTemplate.modChance.large then
    table.insert(mods, modifiers.large.makeTemplate())
  end

  table.sort(mods, sortByPrio)
  return mods
end
M.generateModifiers = generateModifiers


local function isParcelModUnlocked(modKey)
  if not modifiers[modKey] or not modifiers[modKey].unlockFlag then return false end
  return career_modules_unlockFlags.getFlag(modifiers[modKey].unlockFlag)
end
M.isParcelModUnlocked = isParcelModUnlocked

local function lockedBecauseOfMods(modKeys)
  local minTier = 1
  local locked = false
  local definitions = {}
  for key, _ in pairs(modKeys) do
    if modifiers[key] and modifiers[key].unlockFlag then
      local unlockFlag = modifiers[key].unlockFlag
      local flagDefinition = career_modules_unlockFlags.getFlagDefinition(unlockFlag)
      table.insert(definitions, flagDefinition)
      if not career_modules_unlockFlags.getFlag(unlockFlag) then
        locked = true
      end
    end
  end
  table.sort(definitions, function(a,b) return (a and a.level or 0) > (b and b.level or 0) end)
  return locked, definitions[1]
end
M.lockedBecauseOfMods = lockedBecauseOfMods


local function getParcelModUnlockStatusSimple()
  local status = {}
  for modKey, info in pairs(modifiers) do
    status[modKey] = isParcelModUnlocked(modKey)
  end
  return status
end
M.getParcelModUnlockStatusSimple = getParcelModUnlockStatusSimple
M.getParcelModProgressLabel = function(key) return _tr(modifiers[key].unlockLabel) end


local function trackModifierStats(cargo)
  for _, mod in ipairs(cargo.modifiers or {}) do
    progress[mod.type] = progress[mod.type] or {}
    progress[mod.type].delivered = (progress[mod.type].delivered or 0) + 1
    if mod.type == "timed" then
      local prog = progress.timed
      local expiredTime = dGeneral.time() - cargo.loadedAtTimeStamp

      if expiredTime <= mod.timeUntilDelayed then
        prog.onTimeDeliveries = (prog.onTimeDeliveries or 0) + 1
      elseif expiredTime <= mod.timeUntilLate then
        prog.delayedDeliveries = (prog.delayedDeliveries or 0) + 1
      else
        prog.lateDeliveries = (prog.lateDeliveries or 0) + 1
      end
    end
  end
end
M.trackModifierStats = trackModifierStats



--[[
local function onGetSkillUnlockInfoForUi(skill, unlocks)
  if skill.id ~= "delivery" then return end
  unlocks[1] = unlocks[1] or {}
  local modsByTier = {}
  for modKey, info in pairs(modifiers) do
    local tier = 1
    if info.requirements and info.requirements.delivery then
      tier = info.requirements.delivery
    end
    modsByTier[tier] = modsByTier[tier] or {}
    table.insert(modsByTier[tier], modKey)
  end
  for tier, list in pairs(modsByTier) do
    table.sort(list)
    unlocks[tier] = unlocks[tier] or {}
    for _, value in ipairs(list) do
      table.insert(unlocks[tier], {type="text", label = value})
    end
  end
end

M.onGetSkillUnlockInfoForUi = onGetSkillUnlockInfoForUi

]]
return M