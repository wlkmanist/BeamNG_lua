-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local voicepack = require('/lua/ge/extensions/gameplay/rally/voicepack')
local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local AudioManager = require('/lua/ge/extensions/gameplay/rally/audioManager')
local TextCompositor = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/textCompositor')

local C = {}

local logTag = 'startScreenRallySettings'

C.name = 'StartScreen Rally Settings'
C.color = ui_flowgraph_editor.nodeColors.ui
C.description = 'Rally start-screen settings: codriver and mission behavior toggles.'
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = '', chainFlow = true },
  { dir = 'out', type = 'flow', name = 'flow', description = '', chainFlow = true },
}

C.tags = { 'start', 'screen', 'intro', 'ui', 'rally', 'settings' }

local settingKeys = {
  rallyRepairVehicleOnRecovery = true,
  rallyEnableFalseStarts = true,
  rallyEnableEarlyTimeControlPenalties = true,
}

-- each style voices this note at its own level of detail
local samplePacenote = {
  schemaVersion = 3,
  items = {
    ['1'] = { type = 'caution', level = 1 },
    ['2'] = { type = 'early' },
    ['4'] = { type = 'corner', direction = 1, intensity = 50 },
  },
}
local sampleDistanceBefore = 'and'
-- pre-recorded packs (e.g. pro) only exist per stage, so all of them preview this recording of the same note
local recordedSampleMissionId = 'automation_test_track/rallyStage/002-mixedstage'
local recordedSampleBasename = 'pacenote_27.ogg' -- "and care early 2 right minus off camber"
local sampleCompositors = {}

local function getLoopManager()
  if extensions.isExtensionLoaded('gameplay_rallyLoop') and gameplay_rallyLoop then
    return gameplay_rallyLoop.getManager()
  end
  return nil
end

local function clipAudioObjs(entry, basename)
  local metadataEntry = voicepack.getEntryMetadata(entry)[basename]
  local audioLen = metadataEntry and tonumber(metadataEntry.audioLen)
  local fname = voicepack.getEntryAudioFile(entry, basename)
  if not (audioLen and fname and FS:fileExists(fname)) then return nil end
  return { { audioType = 'pacenote', pacenoteFname = fname, audioLen = audioLen } }
end

local function intercomCheckAudioObjs(entry)
  return clipAudioObjs(entry, rallyUtil.makeSystemPacenoteAudioFilename('commsCheck', 1))
end

local function getSampleCompositor(style)
  if sampleCompositors[style] == nil then
    local compositor = TextCompositor(style)
    sampleCompositors[style] = compositor:load() and compositor or false
  end
  return sampleCompositors[style] or nil
end

local function composedSampleAudioObjs(entry)
  local compositor = entry.compositorStyle and getSampleCompositor(entry.compositorStyle)
  if not compositor then return nil end

  local metadata = voicepack.getEntryMetadata(entry)
  local phrases = compositor:compositePhraseEntries(samplePacenote, sampleDistanceBefore, '') or {}
  local audioObjs = {}
  for i, phrase in ipairs(phrases) do
    local basename = rallyUtil.makePacenoteAudioFilename(compositor:pacenoteHash(phrase.text))
    local candidates = voicepack.getAudioCandidatesForEntry(entry, metadata, basename, { phrase.variant })
    if #candidates == 0 then return nil end
    table.insert(audioObjs, {
      audioType = 'pacenote',
      audioCandidates = candidates,
      category = phrase.category,
      nextCategory = phrases[i + 1] and phrases[i + 1].category,
      structuredTimingAfter = i == #phrases and 'pacenote' or 'clip',
    })
  end
  return #audioObjs > 0 and audioObjs or nil
end

local function recordedSampleAudioObjs(entry)
  local sampleEntry = voicepack.scanMission('/gameplay/missions/'..recordedSampleMissionId, recordedSampleMissionId).pro
  if not (sampleEntry and sampleEntry.persona == entry.persona) then return nil end
  return clipAudioObjs(sampleEntry, recordedSampleBasename)
end

function C:init()
  self.panel = {
    type = 'coDriverSelector',
    header = 'missions.missions.rally.startScreen.settingsHeader',
    options = {},
    selectedValue = '',
    settings = {},
    pages = { main = true },
  }
  self.pendingValue = nil
  self.pendingSettings = {}
end

function C:_executionStarted()
  self.pendingValue = nil
  self.pendingSettings = {}
end

function C:getMission(loopManager)
  if loopManager then return loopManager:getRallyLoopMission() end
  return self.mgr.activity
end

function C:buildLoopOptions(loopManager)
  local loopMission = loopManager:getRallyLoopMission()
  if not (loopMission and loopMission.missionTypeData) then return nil end

  local currentValue = loopMission.lastUserSettings and loopMission.lastUserSettings.rallyVoicepackPick or ''
  local setting = voicepack.buildLoopMissionUserSetting(loopMission.missionTypeData, currentValue)
  if not setting then return nil end

  local options = {}
  for _, o in ipairs(setting.values or {}) do
    table.insert(options, { label = o.l, value = o.v, shortLabel = o.shortLabel, detail = o.detail })
  end
  return options, setting.value
end

function C:buildStageOptions(rm)
  local missionDir = rm:getMissionDir()
  local missionId = rm:getMissionId()
  local currentValue = voicepack.settingValueForPick(rm:getVoicepackPick())
  local setting = voicepack.buildMissionUserSetting(missionDir, missionId, currentValue)
  if not setting then return nil end

  local options = {}
  for _, o in ipairs(setting.values or {}) do
    table.insert(options, { label = o.l, value = o.v, shortLabel = o.shortLabel, detail = o.detail })
  end
  return options, setting.value
end

function C:buildBoolSettings(mission)
  if not (mission and mission.getUserSettingsData) then return {} end

  local result = {}
  for _, setting in ipairs(mission:getUserSettingsData() or {}) do
    if setting.type == 'bool' and settingKeys[setting.key] then
      local value = self.pendingSettings[setting.key]
      if value == nil then value = setting.value == true end
      table.insert(result, {
        key = setting.key,
        label = setting.label,
        type = setting.type,
        value = value,
      })
    end
  end
  return result
end

function C:work()
  self.pinOut.flow.value = self.pinIn.flow.value

  local options, selectedValue
  local loopManager = getLoopManager()
  local mission = self:getMission(loopManager)
  if loopManager then
    options, selectedValue = self:buildLoopOptions(loopManager)
  else
    local rm = gameplay_rally and gameplay_rally.getRallyManager()
    if not rm then
      log('W', logTag, 'no rally manager available; skipping settings panel')
      return
    end
    options, selectedValue = self:buildStageOptions(rm)
  end

  if not options or #options == 0 then
    log('W', logTag, 'no codriver options available; skipping settings panel')
    return
  end

  for _, option in ipairs(options) do
    local entry = self:resolveEntry(option.value)
    option.hasVisualPacenotes = not entry or entry.compositorStyle ~= nil
  end

  local visualPacenotes = self.pendingSettings.rallyVisualPacenotes
  if visualPacenotes == nil then visualPacenotes = settings.getValue('rallyVisualPacenotes') == true end

  self.panel.options = options
  self.panel.selectedValue = self.pendingValue or selectedValue or ''
  self.panel.visualPacenotes = visualPacenotes
  self.panel.settings = self:buildBoolSettings(mission)
  self.panel.note = loopManager and 'missions.missions.rally.startScreen.settings.loopTimeNote' or nil
  self.mgr.modules.ui:addUIElement(self.panel)

  local entry = self:resolveEntry(self.panel.selectedValue)
  self:playSample(entry, entry and intercomCheckAudioObjs(entry))
end

function C:resolveEntry(value)
  local loopManager = getLoopManager()
  if loopManager then
    local loopMission = loopManager:getRallyLoopMission()
    return loopMission and voicepack.resolveLoopMissionSettingEntry(loopMission.missionTypeData, value)
  end
  local rm = gameplay_rally and gameplay_rally.getRallyManager()
  return rm and voicepack.resolveEntry(rm:getMissionDir(), voicepack.pickFromSettingValue(value), rm:getMissionId())
end

function C:playSample(entry, audioObjs)
  self.sampleAudio = self.sampleAudio or AudioManager()
  self.sampleAudio:resetQueue()
  if not audioObjs then return end
  self.sampleAudio:setVoicepackTiming(entry)
  self.sampleAudio:enqueueAudioObjs(audioObjs)
end

function C:onUpdate(dtReal, dtSim, dtRaw)
  if self.sampleAudio then self.sampleAudio:onUpdate(dtReal, dtSim, dtRaw) end
end

function C:onCoDriverSelectedByPanel(value)
  self.pendingValue = value
  self.panel.selectedValue = value
  local entry = self:resolveEntry(value)
  self:playSample(entry, entry and (composedSampleAudioObjs(entry) or recordedSampleAudioObjs(entry) or intercomCheckAudioObjs(entry)))
end

function C:onVisualPacenotesChangedByPanel(value)
  value = value == true
  self.pendingSettings.rallyVisualPacenotes = value
  self.panel.visualPacenotes = value
end

-- Update the mission's session-local settings immediately so the loop manager can
-- reliably re-read them in its own Start hook regardless of extension hook order.
-- Cloud persistence remains deferred until Start is committed.
function C:onRallyStartSettingChanged(key, value)
  if type(key) == 'table' then
    local payload = key
    key = payload.key
    value = payload.value
  end
  if not settingKeys[key] then return end
  value = value == true
  self.pendingSettings[key] = value

  local mission = self:getMission(getLoopManager())
  if mission then
    mission.lastUserSettings = mission.lastUserSettings or {}
    mission.lastUserSettings[key] = value
  end

  for _, setting in ipairs(self.panel.settings or {}) do
    if setting.key == key then
      setting.value = value
      break
    end
  end
end

function C:onUIStartButtonClicked()
  if self.sampleAudio then self.sampleAudio:resetQueue() end

  for key, value in pairs(self.pendingSettings) do
    if settings and settings.setValue then settings.setValue(key, value) end
  end
  self.pendingSettings = {}

  if self.pendingValue ~= nil then
    self:applyPick(self.pendingValue)
    self.pendingValue = nil
  end
end

function C:applyPick(value)
  local rm = gameplay_rally and gameplay_rally.getRallyManager()
  local loopManager = getLoopManager()

  if loopManager then
    local loopMission = loopManager:getRallyLoopMission()
    if loopMission then
      loopMission.lastUserSettings = loopMission.lastUserSettings or {}
      loopMission.lastUserSettings.rallyVoicepackPick = value
      voicepack.addLoopMissionSettingToMRU(loopMission.missionTypeData, value)
    end
    if rm then
      local pick = voicepack.resolveLoopVoicepackPick(rm:getMissionDir(), rm:getMissionId(), value)
        or voicepack.pickFromSettingValue(value)
      if not rm:reloadVoicepackAssets(pick, { writeSettings = false }) then
        log('E', logTag, 'failed to reload rally assets after codriver selection')
      end
    end
  else
    if not rm then
      log('W', logTag, 'no rally manager available; ignoring codriver selection')
      return
    end
    local pick = voicepack.pickFromSettingValue(value)
    if not rm:reloadVoicepackAssets(pick, { writeSettings = true }) then
      log('E', logTag, 'failed to reload rally assets after codriver selection')
    end
  end
end

return _flowgraph_createNode(C)
