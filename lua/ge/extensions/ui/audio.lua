-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local audioChannel = "AudioGui"
local managedSources = {}

local function onFirstUpdate()
  local soundsJson = jsonReadFile("ui/soundClasses.json")
  M.ui_sound_classes = soundsJson or {}
end

local function getManagedSourceCacheKey(sourceKey, instanceId)
  if instanceId == nil then
    return sourceKey
  end

  return sourceKey .. ":" .. tostring(instanceId)
end

local function isManagedSourceEvent(event)
  return event.type == "source" or event.sourceKey ~= nil or event.action ~= nil or event.parameters ~= nil or event.stopBeforePlay ~= nil or event.recreateBeforePlay ~= nil
end

local function getCachedManagedSource(cacheKey)
  local sourceId = managedSources[cacheKey]
  if not sourceId then
    return nil
  end

  local source = type(sourceId) == "number" and scenetree.findObjectById(sourceId)
  if source then
    return source
  end

  managedSources[cacheKey] = nil
  return nil
end

local function createManagedSource(event, cacheKey)
  if not event.sfx then
    return nil
  end

  local sourceId = Engine.Audio.createSource(audioChannel, event.sfx)
  if not sourceId or sourceId == 0 then
    return nil
  end

  managedSources[cacheKey] = sourceId
  return type(sourceId) == "number" and scenetree.findObjectById(sourceId)
end

local function deleteManagedSource(cacheKey)
  local sourceId = managedSources[cacheKey]
  if not sourceId then
    return
  end

  Engine.Audio.deleteSource(sourceId)
  managedSources[cacheKey] = nil
end

local function getManagedSourceCacheKeyForEvent(event, instanceId)
  local sourceKey = event.sourceKey or event.sfx
  if not sourceKey then
    return nil
  end

  return getManagedSourceCacheKey(sourceKey, instanceId)
end

local function getManagedSource(event, instanceId)
  local sourceKey = event.sourceKey or event.sfx
  if not sourceKey then
    return nil
  end

  local cacheKey = getManagedSourceCacheKey(sourceKey, instanceId)
  return getCachedManagedSource(cacheKey) or createManagedSource(event, cacheKey)
end

local function applyParameters(source, parameters)
  if not source or type(parameters) ~= "table" then
    return
  end

  for name, value in pairs(parameters) do
    source:setParameter(name, value)
  end
end

local function playManagedSourceEvent(event, instanceId)
  local action = event.action or "play"
  local cacheKey = getManagedSourceCacheKeyForEvent(event, instanceId)

  if action == "play" and event.recreateBeforePlay and cacheKey then
    deleteManagedSource(cacheKey)
  end

  local source = getManagedSource(event, instanceId)
  if not source then
    return
  end

  if action == "play" then
    applyParameters(source, event.parameters)
    if event.stopBeforePlay then
      source:stop(-1)
    end
    source:play(-1)
  elseif action == "setParameters" then
    applyParameters(source, event.parameters)
  end
end

local function playEventSound(className, eventName, instanceId)
  local sound_class = (M.ui_sound_classes or {})[className] or {}
  local event = sound_class[eventName]
  if event then
    if event.sfx and not isManagedSourceEvent(event) then
      Engine.Audio.playOnce('AudioGui', event.sfx)
      return
    end

    playManagedSourceEvent(event, instanceId)
  end
end

local function startHoldActivateSound(instanceId)
  playEventSound("bng_hold_activate", "start", instanceId)
end

local function completeHoldActivateSound(instanceId)
  playEventSound("bng_hold_activate", "complete", instanceId)
end

local function cancelHoldActivateSound(instanceId)
  playEventSound("bng_hold_activate", "cancel", instanceId)
end

M.onFirstUpdate = onFirstUpdate
M.playEventSound = playEventSound
M.startHoldActivateSound = startHoldActivateSound
M.completeHoldActivateSound = completeHoldActivateSound
M.cancelHoldActivateSound = cancelHoldActivateSound

return M