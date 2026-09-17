-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local dequeue = require('dequeue')
local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local audioTiming = require('/lua/ge/extensions/gameplay/rally/audioTiming')

local C = {}
local logTag = ''

function C:init(rallyManager)
  self.rallyManager = rallyManager
  self.pacenoteMetadataOfflineStructured = nil
  self.pacenoteMetadataOnlineStructuredAndFreeform = nil
  self.cornerGapMs = 0
  self.phraseGapMs = 0
  self.linkWordGapMs = 0
  self.pacenoteGapMs = 0
  self.enableSpeedScaling = true
  self.codriverTimingOffsetSeconds = 0

  self.queue = dequeue.new()
  self.currAudioObj = nil
  self.activeAudioChannels = {}
  self.activeAudioChannelCount = 0
  self.nextAudioChannelExpiry = nil


  self:_loadPacenoteMetadata()
  self:_loadVoicepackTimingDefaults()
  -- self:resetQueue()

  -- self.damageAudioPlayedAt = nil
  -- self.damageTimeoutSecs = 1.5
end


function C:_loadPacenoteMetadata()
end

function C:getCornerGapMs()
  return self.cornerGapMs or 0
end

function C:setCornerGapMs(ms)
  self.cornerGapMs = audioTiming.clampCornerGapMs(ms)
end

function C:getPhraseGapMs()
  return self.phraseGapMs or 0
end

function C:setPhraseGapMs(ms)
  self.phraseGapMs = audioTiming.clampPhraseGapMs(ms)
end

function C:getLinkWordGapMs()
  return self.linkWordGapMs or 0
end

function C:setLinkWordGapMs(ms)
  self.linkWordGapMs = audioTiming.clampLinkWordGapMs(ms)
end

function C:getPacenoteGapMs()
  return self.pacenoteGapMs or 0
end

function C:setPacenoteGapMs(ms)
  self.pacenoteGapMs = audioTiming.clampPacenoteGapMs(ms)
end

function C:isSpeedScalingEnabled()
  return self.enableSpeedScaling ~= false
end

function C:getCodriverTimingOffsetSeconds()
  return tonumber(self.codriverTimingOffsetSeconds) or 0
end

function C:_loadVoicepackTimingDefaults()
  local _, voicepackEntry
  if self.rallyManager and self.rallyManager.notebook and self.rallyManager.notebook.resolveActiveVoicepack then
    _, voicepackEntry = self.rallyManager.notebook:resolveActiveVoicepack()
  end

  self:setCornerGapMs(voicepackEntry and voicepackEntry.cornerGapMs or 0)
  self:setPhraseGapMs(voicepackEntry and voicepackEntry.phraseGapMs or 0)
  self:setLinkWordGapMs(voicepackEntry and voicepackEntry.linkWordGapMs or self:getPhraseGapMs())
  self:setPacenoteGapMs(voicepackEntry and voicepackEntry.pacenoteGapMs or 0)
  self.enableSpeedScaling = not voicepackEntry or voicepackEntry.enableSpeedScaling ~= false
  self.codriverTimingOffsetSeconds = voicepackEntry and voicepackEntry.codriverTimingOffsetSeconds or 0
end

function C:_getAudioObjGapAfterMs(audioObj)
  if not audioObj then return 0 end
  if audioObj.category == 'linkword' then
    return self:getLinkWordGapMs()
  end
  if audioObj.structuredTimingAfter == 'clip' then
    if audioObj.category == 'corner' and audioObj.nextCategory == 'corner' then
      return self:getCornerGapMs()
    end
    return self:getPhraseGapMs()
  elseif audioObj.structuredTimingAfter == 'pacenote' then
    return self:getPacenoteGapMs()
  end
  return 0
end

-- single source of truth for a clip's playback length incl. its trailing gap/overlap
function C:_audioObjEffectiveLen(audioObj)
  local audioLen = tonumber(audioObj and audioObj.audioLen) or 0
  local gapSecs = self:_getAudioObjGapAfterMs(audioObj) / 1000
  return math.max(audioLen + gapSecs, 0.01)
end

-- total spoken duration of a pacenote: all clip effective lengths minus the
-- trailing pacenote gap (that gap is spacing to the next note, not this note ending)
function C:pacenoteEffectiveAudioLen(pacenote)
  local audioObjs = pacenote and pacenote:audioObjs()
  if not audioObjs or #audioObjs == 0 then return 0 end
  local total = 0
  for _, obj in ipairs(audioObjs) do
    total = total + self:_audioObjEffectiveLen(obj)
  end
  local last = audioObjs[#audioObjs]
  return total - (self:_getAudioObjGapAfterMs(last) / 1000)
end

function C:resetQueue()
  -- log('D', logTag, "resetQueue")
  self.queue = dequeue.new()

  self:_stopAudio()

  self.currAudioObj = nil
end

function C:_trackAudioChannel(channelId, expiresAt)
  if type(channelId) ~= 'number' then return end

  if not self.activeAudioChannels[channelId] then
    self.activeAudioChannelCount = (self.activeAudioChannelCount or 0) + 1
  end

  self.activeAudioChannels[channelId] = { expiresAt = expiresAt }

  if expiresAt and (not self.nextAudioChannelExpiry or expiresAt < self.nextAudioChannelExpiry) then
    self.nextAudioChannelExpiry = expiresAt
  end
end

function C:_pruneFinishedAudioChannels(force)
  local count = self.activeAudioChannelCount or 0
  if count == 0 then
    self.nextAudioChannelExpiry = nil
    return
  end

  if not force and not self.nextAudioChannelExpiry then return end

  local now = rallyUtil.getTime()
  if not force and now < self.nextAudioChannelExpiry then return end

  local nextExpiry = nil
  for channelId, channelInfo in pairs(self.activeAudioChannels) do
    local expiresAt = channelInfo.expiresAt
    if expiresAt and now >= expiresAt then
      self.activeAudioChannels[channelId] = nil
      count = count - 1
    elseif expiresAt and (not nextExpiry or expiresAt < nextExpiry) then
      nextExpiry = expiresAt
    end
  end

  self.activeAudioChannelCount = math.max(count, 0)
  self.nextAudioChannelExpiry = nextExpiry
end

function C:_stopAudio()
  self:_pruneFinishedAudioChannels(true)

  if (self.activeAudioChannelCount or 0) == 0 then return end

  for channelId, _ in pairs(self.activeAudioChannels) do
    Engine.Audio.intercomStopPacenote(channelId)
  end

  self.activeAudioChannels = {}
  self.activeAudioChannelCount = 0
  self.nextAudioChannelExpiry = nil
end

function C:handleDamage()
  if self.currAudioObj then
    if not self.currAudioObj.damage then
      if (self.activeAudioChannelCount or 0) > 0 then
        -- immediately stop playing and clear currAudioObj so isPlaying will return false.
        -- the note that was playing wont be played again.
        self:_stopAudio()
        self.currAudioObj = nil
        self.queue = dequeue.new()
      end
    end
  end
end

function C:enqueuePauseSecs(secs, addToFront)
  addToFront = addToFront or false
  -- log('I', logTag, string.format('enqueuePauseSecs: pause=%0.2fs front=%s', secs, tostring(addToFront)))

  -- for now I'm OK with creating garbage-collectable objects because pauses are
  -- only used at start and finish lines, not during core competitive driving.
  local pauseAudioObj = {
    audioType = 'pause',
    audioLen = secs,
    time = nil,
    timeout = nil,
  }

  if addToFront then
    self.queue:push_left(pauseAudioObj)
  else
    self.queue:push_right(pauseAudioObj)
  end
end

local audioObjs = nil
function C:enqueueAudioObjs(audioObjs, addToFront)
  if not audioObjs then return 0 end

  local count = 0
  for _, audioObj in ipairs(audioObjs) do
    self:_enqueueAudioObj(audioObj, addToFront)
    count = count + 1
  end
  return count
end

function C:enqueuePacenoteAudio(pacenote, addToFront)
  profilerPushEvent("AudioManager - enqueuePacenoteAudio")

  -- log('D', logTag, string.format("RallyMode: playing pacenote: name='%s' audioMode='%s' note='%s'", pacenote.name, pacenote:getAudioModeString(), compiledPacenote.noteText))

  audioObjs = pacenote:audioObjs()
  if not audioObjs then
    log('E', logTag, "enqueuePacenoteAudio: no audio objects found")
    return
  end

  self:enqueueAudioObjs(audioObjs, addToFront)

  profilerPopEvent("AudioManager - enqueuePacenoteAudio")
end

function C:enqueueSystemPacenote(pacenote, addToFront, audioLen)
  if pacenote then
    log('D', logTag, string.format("RallyMode: playing system pacenote: '%s'", pacenote.text))

    -- Check if system audio file exists
    if not pacenote.audioFname or pacenote.audioFname == '' or not FS:fileExists(pacenote.audioFname) then
      log('E', logTag, string.format("enqueueSystemPacenote: audio file not found: %s", tostring(pacenote.audioFname)))
      guihooks.message(string.format("Can't find audio file for system pacenote '%s'.", pacenote.name), 5)
      return
    end

    -- Use provided audioLen or default to 1.0 seconds for system pacenotes
    local systemAudioLen = audioLen or 1.0

    -- Create audioObj for system pacenote
    local audioObj = {
      audioType = 'pacenote',
      pacenoteFname = pacenote.audioFname,
      audioLen = systemAudioLen,
      time = nil,
      timeout = nil,
      pacenote = { name = pacenote.name }  -- minimal pacenote reference for system notes
    }

    self:_enqueueAudioObj(audioObj, addToFront)
  else
    log('E', logTag, string.format("enqueueSystemPacenote: couldnt find system pacenote with name '%s'", pacenote.name))
  end
end

local function concreteAudioObj(audioObj)
  if not audioObj or not audioObj.audioCandidates then return audioObj end

  local candidates = audioObj.audioCandidates
  if #candidates == 0 then return nil end
  local candidate = candidates[math.random(#candidates)]
  local out = {}
  for k, v in pairs(audioObj) do
    if k ~= 'audioCandidates' then
      out[k] = v
    end
  end
  out.pacenoteFname = candidate.fname
  out.audioLen = candidate.audioLen
  return out
end

function C:_enqueueAudioObj(audioObj, addToFront)
  addToFront = addToFront or false

  audioObj = concreteAudioObj(audioObj)
  if not audioObj then
    log('E', logTag, "_enqueueAudioObj: no audioObj provided")
    return
  end

  if addToFront then
    self.queue:push_left(audioObj)
  else
    self.queue:push_right(audioObj)
  end
end

function C:isPlaying()
  if self.currAudioObj and self.currAudioObj.timeout then
    return rallyUtil.getTime() < self.currAudioObj.timeout
  else
    return false
  end
end

local queueInfo = {}
function C:getQueueInfo()
  queueInfo.queueSize = self.queue:length()
  queueInfo.paused = not self:isPlaying()
  return queueInfo
end

local playbackObj = {filename=nil}

function C:playNextInQueue()
  if not self:isPlaying() then
    self.currAudioObj = self.queue:pop_left()
    if self.currAudioObj then
      if self.currAudioObj.audioType == 'pacenote' then
        local fname = self.currAudioObj.pacenoteFname
        if not fname or fname == '' then
          log('W', logTag, "playNextInQueue: skipping pacenote with empty filename")
          self.currAudioObj = nil
          return
        end
        self.currAudioObj.time = rallyUtil.getTime()
        playbackObj.filename = fname
        if not self.currAudioObj.audioLen or self.currAudioObj.audioLen == 0 then
          log('W', logTag, string.format("playNextInQueue: pacenote has nil or 0 audioLen: fname=%s", tostring(fname)))
        end
        if self.currAudioObj.audioLen then
          self.currAudioObj.timeout = self.currAudioObj.time + self:_audioObjEffectiveLen(self.currAudioObj)
        end
        -- log('D', logTag, string.format("playing a thing: fname=%s", playbackObj.filename))
        local channelId = Engine.Audio.intercomPlayPacenote(playbackObj)
        if type(channelId) == 'number' then
          local channelExpiresAt = nil
          if self.currAudioObj.audioLen then
            channelExpiresAt = self.currAudioObj.time + self.currAudioObj.audioLen
          end
          self:_trackAudioChannel(channelId, channelExpiresAt)
        end
      elseif self.currAudioObj.audioType == 'pause' then
        log('D', logTag, string.format("playing a pause: secs=%0.2f", self.currAudioObj.audioLen))
        self.currAudioObj.time = rallyUtil.getTime()
        self.currAudioObj.timeout = self.currAudioObj.time + self.currAudioObj.audioLen
      else
        log('E', logTag, string.format('unknown audioType: %s', self.currAudioObj.audioType))
      end
    end
  end
end

function C:onUpdate(dtReal, dtSim, dtRaw)
  profilerPushEvent("AudioManager - onUpdate")
  self:_pruneFinishedAudioChannels()
  self:playNextInQueue()
  profilerPopEvent("AudioManager - onUpdate")
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
