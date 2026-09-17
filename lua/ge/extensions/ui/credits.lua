-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- this 'just' plays the credits music in the background using fmod

local M = {}

local creditsSoundId = nil
local soundParams = nil
local creditsMusicFadeDuration = 0.4
local creditsMusicVolume = 0
local creditsMusicFade = nil

local function getCreditsSound()
  if not creditsSoundId then
    return nil
  end

  local snd = scenetree.findObjectById(creditsSoundId)
  return snd
end

local function deleteCreditsSound()
  local snd = getCreditsSound()
  if snd then
    if type(snd.stop) == "function" then
      snd:stop(-1)
    end
  end

  if creditsSoundId then
    Engine.Audio.deleteSource(creditsSoundId)
    creditsSoundId = nil
  end

  creditsMusicVolume = 0
  creditsMusicFade = nil
end

local function ensureCreditsSound()
  if not soundParams then
    soundParams = SFXParameterGroup("CreditsSoundParams")
  end

  if not creditsSoundId then
    creditsSoundId = Engine.Audio.createSource('AudioGui', 'event:>Music>credits')
    local snd = getCreditsSound()
    if snd then
      soundParams:addSource(snd.obj)
    end
  end

  return getCreditsSound()
end

local function setCreditsMusicVolume(volume)
  local snd = getCreditsSound()
  if not snd or type(snd.setVolume) ~= "function" then
    return false
  end

  creditsMusicVolume = volume
  snd:setVolume(volume)
  return true
end

local function startCreditsMusicFade(targetVolume, duration, onComplete)
  local snd = getCreditsSound()
  if not snd or type(snd.setVolume) ~= "function" then
    creditsMusicFade = nil
    return false
  end

  creditsMusicFade = {
    elapsed = 0,
    duration = math.max(duration or creditsMusicFadeDuration, 0.001),
    startVolume = creditsMusicVolume,
    targetVolume = targetVolume,
    onComplete = onComplete,
  }
  return true
end

local function startWithFade(duration)
  local snd = ensureCreditsSound()
  if not snd then
    return false
  end

  creditsMusicFade = nil
  local isPlaying = type(snd.isPlaying) == "function" and snd:isPlaying()
  if not isPlaying then
    setCreditsMusicVolume(0)
    snd:play(-1)
  end

  if not startCreditsMusicFade(1, duration) then
    setCreditsMusicVolume(1)
  end

  return true
end

local function stopWithFade(duration, onStopped)
  local function finishStop()
    deleteCreditsSound()
    if onStopped then
      onStopped()
    end
  end

  if not getCreditsSound() then
    finishStop()
    return
  end

  if not startCreditsMusicFade(0, duration, finishStop) then
    finishStop()
  end
end

local function onExtensionLoaded()
  startWithFade(creditsMusicFadeDuration)
end

local function onExtensionUnloaded()
  deleteCreditsSound()
  soundParams = nil
end

local function onUpdate(dtReal)
  if not creditsMusicFade then
    return
  end

  local snd = getCreditsSound()
  if not snd or type(snd.setVolume) ~= "function" then
    creditsMusicFade = nil
    return
  end

  local fade = creditsMusicFade
  fade.elapsed = fade.elapsed + math.max(dtReal or 0, 0)
  local progress = math.min(fade.elapsed / fade.duration, 1)
  local volume = fade.startVolume + (fade.targetVolume - fade.startVolume) * progress
  setCreditsMusicVolume(volume)

  if progress >= 1 then
    creditsMusicFade = nil
    if fade.onComplete then
      fade.onComplete()
    end
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate
M.startWithFade = startWithFade
M.stopWithFade = stopWithFade

return M