-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dPages, dProgress, dParcelMods
M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dPages = career_modules_delivery_pages
  dProgress = career_modules_delivery_progress
end

local modifiers = {
  timed = {
    makeTemplate = function(g,p,distance)
      local time = (distance / 13) + 30 * math.random() + 30
      return {
        type = "timed",
        deliveryTime = time,
        paddingTime = time * 0.2 + 10,
        timeMessageFlag = false,
        paddingTimeMessageFlag = false,
        moneyMultipler = 1.5,
      }
    end,
    unlockLabel = "Time Sensitive Deliveries",
  },
  post = {
    makeTemplate = function(g,p,distance)
      return {
        type = "post",
        moneyMultipler = 1.2,
      }
    end,
    unlockLabel = "General Post Parcels",
  },
  precious = {
    requirements = {
      delivery = 2
    },
    penalty = 3,
    makeTemplate = function(g,p,distance)
      return {
        type = "precious",
        moneyMultipler = 2.5,
      }
    end,
    unlockLabel = "Precious Cargo",
  },
  supplies = {
    requirements = {
      delivery = 2
    },
    makeTemplate = function(g,p,distance)
      return {
        type = "supplies",
        moneyMultipler = 1.0,
      }
    end,
    unlockLabel = "Supply & Logistics Cargo",
  },
  large = {
    requirements = {
      delivery = 2
    },
    makeTemplate = function(g,p,distance)
      return {
        type = "large",
        moneyMultipler = 1.2,
      }
    end,
    unlockLabel = "Large & Heavy Cargo",
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

local function calculateTimedModifierTime(distance)
  local r = math.random()+1
  return (distance / 13) + (30 * r)
end
M.calculateTimedModifierTime = calculateTimedModifierTime

local modifierProbability = 1
local largeSlotThreshold = 65
local heavyWeightThreshold = 80
local function generateModifiers(item, parcelTemplate, distance)
  local mods = {}
  math.randomseed(item.groupSeed)

  local r = math.random()
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

  return mods
end
M.generateModifiers = generateModifiers


local function isParcelModUnlocked(modKey)
  local unlocked = true
  for skill, level in pairs(modifiers[modKey].requirements or {}) do
    if career_branches.getBranchLevel(skill) < level then
      unlocked = false
    end
  end
  return unlocked
end
M.isParcelModUnlocked = isParcelModUnlocked

local function lockedBecauseOfMods(modKeys)
  local minTier = math.huge
  local locked = false
  for key, _ in pairs(modKeys) do
    if not isParcelModUnlocked(key) then
      minTier = math.min(minTier, modifiers[key].requirements.delivery)
      locked = true
    end
  end
  return locked, minTier
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
M.getParcelModProgressLabel = function(key) return modifiers[key].unlockLabel end


local function trackModifierStats(cargo)
  for _, m in ipairs(cargo.modifiers or {}) do
    progress[m.type] = progress[m.type] or {}
    progress[m.type].delivered = (progress[m.type].delivered or 0) + 1
    if m.type == "timed" then
      local prog = progress.timed
      if m.expirationTimeStamp and dGeneral.time() < m.expirationTimeStamp then
        prog.onTimeDeliveries = (prog.onTimeDeliveries or 0) + 1
      elseif m.expirationTimeStamp and m.definitiveExpirationTimeStamp and dGeneral.time() > m.expirationTimeStamp and dGeneral.time() < m.definitiveExpirationTimeStamp then
        prog.delayedDeliveries = (prog.delayedDeliveries or 0) + 1
      elseif m.definitiveExpirationTimeStamp and dGeneral.time() > m.definitiveExpirationTimeStamp then
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