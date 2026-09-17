-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local waypointTypes = require('/lua/ge/extensions/gameplay/rally/notebook/waypointTypes')
local cc = require('/lua/ge/extensions/gameplay/rally/util/colors')
local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local voicepackMod = require('/lua/ge/extensions/gameplay/rally/voicepack')
local RallyEnums = require('/lua/ge/extensions/gameplay/rally/enums')
local normalizer = require('/lua/ge/extensions/gameplay/rally/util/normalizer')
-- local SettingsManager = require('/lua/ge/extensions/gameplay/rally/settingsManager')
local Structured = require('/lua/ge/extensions/gameplay/rally/notebook/structured')
local geoPacenotes = require('/lua/ge/extensions/gameplay/rally/snaproad/geoPacenotes')
local zSnap = require('/lua/ge/extensions/editor/rallyEditor/zSnap')
local FocusedNearDraw = require('/lua/ge/extensions/gameplay/rally/notebook/focusedNearDraw')

local C = {}
local logTag = ''
local structured = 'structured'

local pn_drawMode_noSelection = 'no_selection'
local pn_drawMode_partitionedSnaproad = 'partitioned_snaproad'
local pn_drawMode_background = 'background'
local pn_drawMode_next = 'next'
local pn_drawMode_previous = 'previous'
local pn_drawMode_selected = 'selected'

local defaultSlowCornerReleaseType = RallyEnums.slowCornerReleaseType.csHalf
local distanceMeasureWaypointCornerStart = 'cs'
local distanceMeasureWaypointCornerEnd = 'ce'
local defaultDistanceMeasureWaypoint = distanceMeasureWaypointCornerEnd
local pacenoteLabelModeAll = "all"
local pacenoteLabelModeDistance = "distance"

local function normalizeDistanceMeasureWaypoint(value)
  if value == distanceMeasureWaypointCornerStart then
    return distanceMeasureWaypointCornerStart
  end
  return defaultDistanceMeasureWaypoint
end

C.noteFields = {
  before = 'before',
  beforeMeters = 'beforeMeters',
  note = 'note',
  after = 'after',
  afterMeters = 'afterMeters',
}

function C:init(notebook, name, forceId)
  self.notebook = notebook
  self.id = forceId or notebook:getNextUniqueIdentifier()
  self.pk = rallyUtil.randomId()
  self.name = name or ("Pacenote " .. self.id)
  self.todo = false
  self.playback_rules = nil
  self.isolate = false
  self.triggerType = RallyEnums.triggerType.dynamic
  self.slowCornerReleaseType = defaultSlowCornerReleaseType
  self.slowCorner = false
  self.ignoreDistanceCalls = false
  self.includeLinkWord = true
  self.distanceBeforeModifier = false
  self.distanceMeasureWaypoint = nil
  self.audioMode = RallyEnums.pacenoteAudioMode.auto
  self.notes = {}
  for _,lang in ipairs(self.notebook:getLanguages()) do
    lang = lang.language
    self.notes[lang] = {}
    self.notes[lang].before = ''
    self.notes[lang].beforeMeters = -1
    self.notes[lang].note = {}
    self.notes[lang].after = ''
    self.notes[lang].afterMeters = -1
  end

  self.structured = Structured()

  self.pacenoteWaypoints = require('/lua/ge/extensions/gameplay/util/sortedList')(
    "pacenoteWaypoints",
    self,
    require('/lua/ge/extensions/gameplay/rally/notebook/pacenoteWaypoint')
  )
  self.metadata = {}

  self.sortOrder = 999999
  self.validation_issues = {}
  self.draw_debug_lang = nil
  self._cachedCompiledData = nil
  self._compileFailed = false
  self.halfpoint = nil
  self._cachedLength = nil
  self._cachedCamPos = nil
  self.visualSerialNo = -1
  self.measurements = {
    corner1 = nil,
    corner2 = nil,
    splitPoint = nil,
    variants = nil,
    selectedType = nil,
    selected = nil,
  }
end

-- used by pacenoteWaypoints.lua
function C:getNextUniqueIdentifier()
  return self.notebook:getNextUniqueIdentifier()
end

function C:getNextWaypointType()
  local foundTypes = {
    [waypointTypes.wpTypeCornerStart] = false,
    [waypointTypes.wpTypeCornerEnd] = false,
  }

  for _,wp in pairs(self.pacenoteWaypoints.objects) do
    foundTypes[wp.waypointType] = true
  end

  if foundTypes[waypointTypes.wpTypeCornerStart] == false then
    return waypointTypes.wpTypeCornerStart
  elseif foundTypes[waypointTypes.wpTypeCornerEnd] == false then
    return waypointTypes.wpTypeCornerEnd
  end
end

function C:setAllRadii(newRadius, wpType)
  for _,wp in ipairs(self.pacenoteWaypoints.sorted) do
    if not wpType or wp.waypointType == wpType then
      wp.radius = newRadius
    end
  end
end

function C:allToTerrain()
  for _,wp in ipairs(self.pacenoteWaypoints.sorted) do
    wp:setPos(zSnap.zSnapWithCurrentMethod(wp.pos))
  end
end

-- function C:_noteOutputFreeformWithVars(lang)
--   lang = lang or self:selectedCodriverLanguage()
--   local txt = ''
--   -- local langData = self.notes[lang]

--   -- if not langData then
--     -- return txt
--   -- end

--   -- local note = langData[self.noteFields.note].freeform
--   -- local before = langData[self.noteFields.before]
--   -- local after = langData[self.noteFields.after]

--   local note = self:getNoteFieldFreeform(lang)
--   local before = self:getNoteFieldBefore(lang)
--   local after = self:getNoteFieldAfter(lang)

--   if rallyUtil.useNote(note) then
--     txt = note
--   else
--     -- if theres no usable note, dont bother with distance calls
--     return txt
--   end

--   -- add before and after vars to the note if they dont already exist
--   if not string.find(txt, rallyUtil.var_db) then
--     txt = rallyUtil.var_db..' '..txt
--   end

--   if not string.find(txt, rallyUtil.var_da) then
--     txt = txt..' '..rallyUtil.var_da
--   end

--   txt = rallyUtil.trimString(txt)

--   return txt
-- end

local function _noteOutputFreeformWithVarsHelper(note, before, after)
  -- lang = lang or self:selectedCodriverLanguage()
  local txt = ''
  -- local langData = self.notes[lang]

  -- if not langData then
    -- return txt
  -- end

  -- local note = langData[self.noteFields.note].freeform
  -- local before = langData[self.noteFields.before]
  -- local after = langData[self.noteFields.after]

  -- local note = self:getNoteFieldFreeform(lang)
  -- local before = self:getNoteFieldBefore(lang)
  -- local after = self:getNoteFieldAfter(lang)

  if rallyUtil.useNote(note) then
    txt = note
  else
    -- if theres no usable note, dont bother with distance calls
    return txt
  end

  -- add before and after vars to the note if they dont already exist
  if not string.find(txt, rallyUtil.var_db) then
    txt = rallyUtil.var_db..' '..txt
  end

  if not string.find(txt, rallyUtil.var_da) then
    txt = txt..' '..rallyUtil.var_da
  end

  txt = rallyUtil.trimString(txt)

  return txt
end

local function _interpolateFreeformVars(txt, before, after, punc)
  if rallyUtil.useNote(before) then
    txt = string.gsub(txt, rallyUtil.var_db, before)
  else
    txt = string.gsub(txt, rallyUtil.var_db, '')
  end

  if rallyUtil.useNote(after) then
    txt = string.gsub(txt, rallyUtil.var_da, after)
    txt = txt..punc
  else
    txt = string.gsub(txt, rallyUtil.var_da, '')
  end

  txt = rallyUtil.trimString(txt)

  return txt
end

function C:noteOutputFreeform(lang)
  if self._compileFailed then
    return ''
  end

  local note = self:getNoteFieldFreeform(lang)
  local before = self:getNoteFieldBefore(lang)
  local after = self:getNoteFieldAfter(lang)
  local txt = _noteOutputFreeformWithVarsHelper(note, before, after)
  local punc = ''
  txt = _interpolateFreeformVars(txt, before, after, punc)

  -- txt = normalizer.replaceWords(SettingsManager.getMainSettings():getFreeformSubstitutions(), txt)

  return txt
end

local function parseVariantCsv(variant)
  local out = {}
  if type(variant) ~= 'string' then return out end

  for token in string.gmatch(variant, "[^,]+") do
    token = rallyUtil.trimString(token)
    local n = tonumber(token)
    if n and n > 0 then
      table.insert(out, tostring(math.floor(n)))
    end
  end

  return out
end

local function phraseEntriesToText(entries)
  local out = {}
  for _, entry in ipairs(entries or {}) do
    table.insert(out, entry.text)
  end
  return out
end

local function copyPhraseEntry(entry)
  local out = {}
  for k, v in pairs(entry or {}) do
    out[k] = v
  end
  return out
end

local function makeVariantResolver(compositor, metadata, audioFnameForBasename, opts)
  opts = opts or {}
  metadata = metadata or {}
  if not compositor then return nil end

  return function(entry)
    if not entry then return nil end

    local allowed = parseVariantCsv(entry.variant)
    local pacenoteHash = compositor:pacenoteHash(entry.text)
    local baseBasename = rallyUtil.makePacenoteAudioFilename(pacenoteHash)
    local candidates = voicepackMod.getAudioCandidates(
      metadata,
      baseBasename,
      audioFnameForBasename,
      #allowed > 0 and allowed or nil
    )

    if #candidates == 0 then
      if opts.includeMissingVariant and #allowed > 0 then
        local resolved = copyPhraseEntry(entry)
        local missingBasename = rallyUtil.makePacenoteVariantAudioFilename(pacenoteHash, allowed[1])
        resolved.audioFname = audioFnameForBasename(missingBasename)
        return resolved
      end
      if opts.includeMissingVariant then
        local resolved = copyPhraseEntry(entry)
        resolved.audioFname = audioFnameForBasename(baseBasename)
        return resolved
      end
      return entry
    end

    local resolved = copyPhraseEntry(entry)
    resolved.audioCandidates = candidates
    if #candidates == 1 then
      resolved.audioFname = candidates[1].fname
    end
    return resolved
  end
end

function C:structuredPhraseEntriesOnline(lang, distBefore, distAfter, opts)
  opts = opts or {}
  local compositor = self.notebook:getTextCompositor()
  if not compositor then return nil end

  local resolver = nil
  if opts.resolveVariants then
    local metadata = self.notebook:loadOnlineStructuredPacenoteMetadata() or {}
    local pacenotesDir = self.notebook:missionPacenotesDir(rallyUtil.structuredDir)
    if not pacenotesDir then return {} end
    resolver = makeVariantResolver(compositor, metadata, function(basename)
      return pacenotesDir..'/'..basename
    end, { includeMissingVariant = opts.includeMissingVariant })
  end

  return compositor:compositePhraseEntries(
    self:structuredForProjection(),
    distBefore ~= nil and distBefore or self:getNoteFieldBefore(lang),
    distAfter ~= nil and distAfter or self:getNoteFieldAfter(lang),
    {
      variantResolver = resolver,
      distanceAfterBeforePostModifier = self.distanceBeforeModifier == true,
    }
  ) or {}
end

function C:structuredPhraseEntriesOffline(opts)
  opts = opts or {}
  local voicepack, voicepackEntry = self.notebook:resolveActiveVoicepack()
  local compositor = self.notebook:getOfflineTextCompositor()
  if not voicepack or not compositor then return nil end

  local resolver = nil
  if opts.resolveVariants then
    local metadata = self.notebook:loadOfflineStructuredPacenoteMetadata() or {}
    resolver = makeVariantResolver(compositor, metadata, function(basename)
      if voicepackEntry and voicepackEntry.dir then
        return voicepackMod.getEntryAudioFile(voicepackEntry, basename)
      end
      return voicepackMod.getAudioFile(voicepack, basename)
    end, { includeMissingVariant = opts.includeMissingVariant })
  end

  return compositor:compositePhraseEntries(
    self:structuredForProjection(),
    self:getNoteFieldBefore(),
    self:getNoteFieldAfter(),
    {
      variantResolver = resolver,
      distanceAfterBeforePostModifier = self.distanceBeforeModifier == true,
    }
  ) or {}
end

function C:noteOutputStructuredOnline(lang)
  lang = lang or self:selectedCodriverLanguage()
  local entries = self:structuredPhraseEntriesOnline(lang)
  if entries then
    return phraseEntriesToText(entries)
  end

  local notesOut = {}
  local langData = self.notes[lang]

  if not langData then
    langData = {
      note = {
        structured = {},
      },
      before = '',
      after = ''
    }

    self.notes[lang] = langData
  end

  local notesArray = langData[self.noteFields.note].structured
  notesArray = deepcopy(notesArray)
  local before = langData[self.noteFields.before]
  local after = langData[self.noteFields.after]

  -- if there are no notes, then dont bother with distance calls.
  if notesArray == nil or #notesArray == 0 then
    return notesOut
  end

  -- local substitutions = SettingsManager.getMainSettings():getStructuredSubstitutions()

  for _,txt in ipairs(notesArray) do
    -- if rallyUtil.useNote(before) then
    --   txt = string.gsub(txt, rallyUtil.var_db, before)
    -- else
    --   txt = string.gsub(txt, rallyUtil.var_db, '')
    -- end

    -- if rallyUtil.useNote(after) then
    --   txt = string.gsub(txt, rallyUtil.var_da, after)
    -- else
    --   txt = string.gsub(txt, rallyUtil.var_da, '')
    -- end

    -- txt = rallyUtil.trimString(txt)
    -- txt = normalizer.replaceWords(substitutions, txt)
    table.insert(notesOut, txt)
  end

  return notesOut
end

local function directionFromMeasurement(measurement)
  if not measurement then return nil end
  if measurement.direction == 'left' then return -1 end
  if measurement.direction == 'right' then return 1 end
  return measurement.direction
end

function C:measurementTypeForCorner(corner)
  return geoPacenotes.normalizeMeasurementType(corner and corner.measurementType or nil)
end

function C:measurementVariantForType(measurementType)
  local measurements = self.measurements or {}
  local variants = measurements.variants or {}
  local normalized = geoPacenotes.normalizeMeasurementType(measurementType)
  return variants[normalized] or variants[geoPacenotes.defaultMeasurementType] or measurements.corner1
end

function C:selectedMeasurementVariant()
  return self:measurementVariantForType(self:measurementTypeForCorner(self:corner()))
end

function C:structuredForProjection()
  local projected = {
    schemaVersion = self.structured.schemaVersion,
    items = self.structured:slotItems(),
  }
  local fallbackMeasurement = self:selectedMeasurementVariant()
  if not fallbackMeasurement then return projected end

  local corner = Structured.slotItem(projected, 4)
  if corner then
    local measurement = self:measurementVariantForType(corner.measurementType) or fallbackMeasurement

    corner.direction = directionFromMeasurement(measurement)
    corner.intensity = measurement.diameter
    corner.arcDegrees = measurement.arcDegrees
    corner.arcMeters = measurement.arcMeters or measurement.pointsLength or measurement.arcDistance
    corner.chordMeters = measurement.chordMeters or measurement.straightLineDistance
  end

  return projected
end

function C:noteOutputStructuredOffline()
  local entries = self:structuredPhraseEntriesOffline()
  if entries then
    return phraseEntriesToText(entries)
  end
  return {}
end

function C:currentStructuredOutput()
  local entries = self:structuredPhraseEntriesOnline()
  if entries then
    return phraseEntriesToText(entries)
  end
  return self:getNoteFieldStructured()
end

function C:currentStructuredContentOutput()
  local entries = self:structuredPhraseEntriesOnline(nil, '', '')
  if entries then
    return phraseEntriesToText(entries)
  end
  return {}
end

function C:getNoteFieldBefore(lang)
  lang = lang or self:selectedCodriverLanguage()
  local lang_data = self.notes[lang]
  if not lang_data then return '' end
  local val = lang_data[self.noteFields.before]
  if not val then
    return ''
  end
  return val
end

function C:getNoteFieldBeforeMeters(lang)
  lang = lang or self:selectedCodriverLanguage()
  local lang_data = self.notes[lang]
  if not lang_data then return -1 end
  local val = lang_data[self.noteFields.beforeMeters]
  if not val then
    return -1
  end
  return val
end

function C:getNoteFieldFreeform(lang)
  lang = lang or self:selectedCodriverLanguage()
  local lang_data = self.notes[lang]
  if not lang_data then return '' end
  local val = lang_data[self.noteFields.note].freeform
  if not val then
    return ''
  end
  return val
end

function C:getNoteFieldStructured(lang)
  lang = lang or self:selectedCodriverLanguage()
  local lang_data = self.notes[lang]
  if not lang_data then return {} end
  local val = lang_data[self.noteFields.note].structured
  if not val then
    return {}
  end
  return val
end

function C:getNoteFieldAfter(lang)
  lang = lang or self:selectedCodriverLanguage()
  local lang_data = self.notes[lang]
  if not lang_data then return '' end
  local val = lang_data[self.noteFields.after]
  if not val then
    return ''
  end
  return val
end

function C:getNoteFieldAfterMeters(lang)
  lang = lang or self:selectedCodriverLanguage()
  local lang_data = self.notes[lang]
  if not lang_data then return -1 end
  local val = lang_data[self.noteFields.afterMeters]
  if not val then
    return -1
  end
  return val
end

function C:setNoteFieldBefore(val, meters)
  local lang = self:selectedCodriverLanguage()
  local lang_data = self.notes[lang]
  if not lang_data then return end
  lang_data[self.noteFields.before] = val
  lang_data[self.noteFields.beforeMeters] = meters
end

function C:setNoteFieldFreeform(val, lang)
  lang = lang or self:selectedCodriverLanguage()
  local lang_data = self.notes[lang]
  if not lang_data then return end
  if not lang_data[self.noteFields.note] then
    lang_data[self.noteFields.note] = {}
  end
  lang_data[self.noteFields.note].freeform = val
end

function C:setNoteFieldStructured(val, lang)
  lang = lang or self:selectedCodriverLanguage()
  local lang_data = self.notes[lang]
  if not lang_data then return end
  if not lang_data[self.noteFields.note] then
    lang_data[self.noteFields.note] = {}
  end
  lang_data[self.noteFields.note].structured = val
end

function C:setNoteFieldAfter(val, meters)
  local lang = self:selectedCodriverLanguage()
  local lang_data = self.notes[lang]
  if not lang_data then return end
  lang_data[self.noteFields.after] = val
  lang_data[self.noteFields.afterMeters] = meters
end

-- custom-mode audio files: the notebook computes the assignment of clip basenames to
-- pacenotes (live even-distribution plus persisted manual pins). this resolves each
-- basename to a full path via the owner voicepack (honouring reuseAudioFrom fallback).
function C:getCustomAudioFiles()
  if not self.notebook or not self.notebook.customAudioBasenamesFor then return {} end
  local basenames = self.notebook:customAudioBasenamesFor(self)
  local out = {}
  for _, base in ipairs(basenames) do
    local full = self.notebook:resolveCustomAudioBasename(base)
    if full then table.insert(out, full) end
  end
  return out
end

function C:getCustomAudioFile()
  local matches = self:getCustomAudioFiles()
  return matches[1] or ''
end

function C:getCustomDescription()
  local first = self:getCustomAudioFile()
  if first == '' then return '' end
  local base = string.match(first, "([^/\\]+)$") or first
  local transcriptions = self.notebook and self.notebook.loadCustomPacenoteTranscriptions
    and self.notebook:loadCustomPacenoteTranscriptions() or {}
  local entry = transcriptions[base]
  return (entry and entry.description) or ''
end

function C:clearResolvedAudioObjs()
  self._resolvedAudioObjsByMode = nil
end

function C:clearCachedFgData()
  self._cachedCompiledData = nil
  self:clearResolvedAudioObjs()
end

function C:clearCompilationFailures()
  self._compileFailed = false
end

function C:didCompileFail()
  return self._compileFailed
end

local function isStructuredAudioMode(mode)
  return mode == 'structuredOnline' or mode == 'structuredOffline'
end

local function createAudioObjs(mode, metadata, pacenote, items)
  if not metadata then
    -- log('E', logTag, "createAudioObjs: no metadata provided")
    return nil, nil, nil
  end

  local total = 0
  local audioObjs = {}

  for i, item in ipairs(items) do
    local audioCandidates = nil
    local concreteFname = nil
    local audioLen = 0
    local category = nil
    local nextCategory = nil

    if type(item) == 'table' then
      category = item.category
    end
    if type(items[i + 1]) == 'table' then
      nextCategory = items[i + 1].category
    end

    if type(item) == 'table' and item.candidates then
      audioCandidates = {}
      for _, candidate in ipairs(item.candidates) do
        local audioLen = tonumber(candidate.audioLen)
        if type(candidate.fname) == 'string' and candidate.fname ~= '' and audioLen then
          table.insert(audioCandidates, {
            fname = candidate.fname,
            audioLen = audioLen,
            basename = candidate.basename,
            variantIndex = candidate.variantIndex,
          })
        end
      end
      if #audioCandidates == 0 then audioCandidates = nil end
    end

    if audioCandidates then
      concreteFname = audioCandidates[1].fname
      audioLen = audioCandidates[1].audioLen
    elseif type(item) == 'table' and type(item.fname) == 'string' then
      concreteFname = item.fname
      local _, basename, _ = path.split(concreteFname)
      local metadataVal = metadata[basename]
      audioLen = metadataVal and metadataVal.audioLen or 0
    elseif type(item) == 'string' then
      concreteFname = item
      local _, basename, _ = path.split(concreteFname)
      local metadataVal = metadata[basename]
      audioLen = metadataVal and metadataVal.audioLen or 0
    end

    if audioLen and audioLen > 0 then
      total = total + audioLen
    end

    local structuredTimingAfter = nil
    if isStructuredAudioMode(mode) then
      structuredTimingAfter = i == #items and 'pacenote' or 'clip'
    end

    local audioObj = {
      audioType = 'pacenote',
      pacenoteFname = concreteFname,
      audioLen = audioLen,
      audioCandidates = audioCandidates,
      audioMode = mode,
      pacenoteId = pacenote and pacenote.id,
      category = category,
      nextCategory = nextCategory,
      structuredTimingAfter = structuredTimingAfter,
      time = nil,  -- set during playback
      timeout = nil,  -- set during playback
      pacenote = pacenote,  -- reference to entire pacenote object
    }

    table.insert(audioObjs, audioObj)
  end

  return total, audioObjs
end

local function copyAudioObj(audioObj)
  local out = {}
  for k, v in pairs(audioObj or {}) do
    if k ~= 'audioCandidates' then
      out[k] = v
    end
  end
  return out
end

local function resolveAudioObj(audioObj)
  if not audioObj or not audioObj.audioCandidates then return audioObj end

  local candidates = audioObj.audioCandidates
  if #candidates == 0 then return nil end
  local candidate = candidates[math.random(#candidates)]
  local resolved = copyAudioObj(audioObj)
  resolved.pacenoteFname = candidate.fname
  resolved.audioLen = candidate.audioLen
  return resolved
end

local function resolveAudioObjsUncached(audioObjs)
  if not audioObjs then return nil end

  local resolved = {}
  for _, audioObj in ipairs(audioObjs) do
    local concrete = resolveAudioObj(audioObj)
    if concrete then
      table.insert(resolved, concrete)
    end
  end
  return resolved
end

function C:resolveAudioObjs(mode, audioObjs)
  if not audioObjs then return nil end
  self._resolvedAudioObjsByMode = self._resolvedAudioObjsByMode or {}
  if self._resolvedAudioObjsByMode[mode] then
    return self._resolvedAudioObjsByMode[mode]
  end

  local resolved = resolveAudioObjsUncached(audioObjs)
  self._resolvedAudioObjsByMode[mode] = resolved
  return resolved
end

local function audioObjsTotal(audioObjs)
  local total = 0
  for _, audioObj in ipairs(audioObjs or {}) do
    total = total + (tonumber(audioObj.audioLen) or 0)
  end
  return total
end

function C:audioLenTotal()
  return audioObjsTotal(self:audioObjs())
end

function C:checkFilesExist(audioMode, fnames)
  for _,fname in ipairs(fnames) do
    if not fname or fname == '' then
      return false
    end
    if not FS:fileExists(fname) then
      -- log('E', logTag, "checkFilesExist: cant find "..audioMode.." file for pacenote=" .. self.name .. " fname=" .. fname)
      return false
    end
  end
  return true
end

function C:audioObjs()
  local compiledPacenote = self:asCompiled()
  if not compiledPacenote then return nil end
  if self:isAudioModeFreeform() then
    return self:resolveAudioObjs('freeform', compiledPacenote.audioObjsFreeform)
  elseif self:isAudioModeStructuredOnline() then
    return self:resolveAudioObjs('structuredOnline', compiledPacenote.audioObjsStructuredOnline)
  elseif self:isAudioModeStructuredOffline() then
    return self:resolveAudioObjs('structuredOffline', compiledPacenote.audioObjsStructuredOffline)
  elseif self:isAudioModeCustom() then
    return self:resolveAudioObjs('custom', compiledPacenote.audioObjsCustom)
  else
    return nil
  end
end

function C:audioObjsFresh()
  local audioObjs = nil

  if self:isAudioModeFreeform() then
    local fnameFreeform = self:audioFnameFreeform()
    local metadata = self.notebook:loadFreeformPacenoteMetadata()
    _, audioObjs = createAudioObjs('freeform', metadata, self, { fnameFreeform })
  elseif self:isAudioModeStructuredOnline() then
    local items = self:audioItemsStructuredOnline()
    local metadata = self.notebook:loadOnlineStructuredPacenoteMetadata()
    _, audioObjs = createAudioObjs('structuredOnline', metadata, self, items)
  elseif self:isAudioModeStructuredOffline() then
    local items = self:audioItemsStructuredOffline()
    local metadata = self.notebook:loadOfflineStructuredPacenoteMetadata()
    _, audioObjs = createAudioObjs('structuredOffline', metadata, self, items)
  elseif self:isAudioModeCustom() then
    local fnames = self:getCustomAudioFiles()
    local metadata = self.notebook:loadCustomPacenoteMetadata()
    _, audioObjs = createAudioObjs('custom', metadata, self, fnames)
  end

  return resolveAudioObjsUncached(audioObjs)
end

function C:asCompiled()
  -- TODO reuse validations here.
  if self._compileFailed then
    return nil
  end
  if self._cachedCompiledData then
    return self._cachedCompiledData
  end

  -- Calculate audio lengths and objects for ALL modes, not just the active one
  local audioLenFreeform = 0
  local audioObjsFreeform = nil
  local fnameFreeform = self:audioFnameFreeform()
  local pacenoteMetadataFreeform = self.notebook:loadFreeformPacenoteMetadata()
  audioLenFreeform, audioObjsFreeform = createAudioObjs('freeform', pacenoteMetadataFreeform, self, {fnameFreeform})

  local audioLenStructuredOnline = 0
  local audioObjsStructuredOnline = nil
  local fnamesStructuredOnline = self:audioItemsStructuredOnline()
  local pacenoteMetadataOnlineStructured = self.notebook:loadOnlineStructuredPacenoteMetadata()
  audioLenStructuredOnline, audioObjsStructuredOnline = createAudioObjs('structuredOnline', pacenoteMetadataOnlineStructured, self, fnamesStructuredOnline)

  local audioLenStructuredOffline = 0
  local audioObjsStructuredOffline = nil
  local fnamesStructuredOffline = self:audioItemsStructuredOffline()
  local pacenoteMetadataOfflineStructured = self.notebook:loadOfflineStructuredPacenoteMetadata()
  audioLenStructuredOffline, audioObjsStructuredOffline = createAudioObjs('structuredOffline', pacenoteMetadataOfflineStructured, self, fnamesStructuredOffline)

  local audioLenCustom = 0
  local audioObjsCustom = nil
  local fnamesCustom = self:getCustomAudioFiles()
  local pacenoteMetadataCustom = self.notebook:loadCustomPacenoteMetadata()
  audioLenCustom, audioObjsCustom = createAudioObjs('custom', pacenoteMetadataCustom, self, fnamesCustom)

  local noteText = self:noteOutputPreview()

  local distBefore = self:getNoteFieldBefore()
  local distBeforeMeters = self:getNoteFieldBeforeMeters()
  local distAfter = self:getNoteFieldAfter()
  local distAfterMeters = self:getNoteFieldAfterMeters()

  local vc = self.notebook:getVisualCompositor2()
  local visualPacenotes2 = nil
  if not vc then
    -- custom audio notebooks dont emit visual pacenotes; missing compositor is expected.
    if not self.notebook:isAudioModeCustom() then
      log('E', logTag, 'asCompiled: no visual compositor')
    end
    -- self._compileFailed = true
    -- return nil
  else
    visualPacenotes2 = vc:compositeVisual(self, self:structuredForProjection(), distBeforeMeters, distAfterMeters)
  end

  local compiledPacenote = {
    id = self.id,
    name = self.name,
    noteText = noteText,
    audioObjsFreeform = audioObjsFreeform,
    audioObjsStructuredOnline = audioObjsStructuredOnline,
    audioObjsStructuredOffline = audioObjsStructuredOffline,
    audioObjsCustom = audioObjsCustom,
    audioLenFreeform = audioLenFreeform,
    audioLenStructuredOnline = audioLenStructuredOnline,
    audioLenStructuredOffline = audioLenStructuredOffline,
    audioLenCustom = audioLenCustom,
    visualPacenoteEvent = {
      pacenoteId = self.id,
      pacenoteName = self.name,
      visualPacenotes = visualPacenotes2,
      serialNo = self.visualSerialNo,
    },
    distanceBefore = distBefore,
    distanceAfter = distAfter,
  }
  self._cachedCompiledData = compiledPacenote
  return compiledPacenote
end

function C:validate()
  self.validation_issues = {}

  if not self:getCornerStartWaypoint() then
    table.insert(self.validation_issues, 'missing CornerStart waypoint')
  end

  if not self:getCornerEndWaypoint() then
    table.insert(self.validation_issues, 'missing CornerEnd waypoint')
  end

  if self.name == '' then
    table.insert(self.validation_issues, 'missing pacenote name')
  end

  if self:useStructured() then
    local note_field_structured = self:currentStructuredOutput()
    if #note_field_structured == 0 then
      table.insert(self.validation_issues, 'pacenote is empty')
    end
  elseif self:isAudioModeCustom() then
    if #self:getCustomAudioFiles() == 0 then
      table.insert(self.validation_issues, 'missing custom audio file')
    end
  else
    local note_field_freeform = self:getNoteFieldFreeform()
    if note_field_freeform ~= rallyUtil.autofill_blocker then
      local last_char = note_field_freeform:sub(-1)
      if note_field_freeform == '' then
        table.insert(self.validation_issues, 'missing freeform note for '..self:selectedCodriverLanguage())
      elseif note_field_freeform == rallyUtil.unknown_transcript_str then
        table.insert(self.validation_issues, "'"..rallyUtil.unknown_transcript_str.."' freeform note")
      -- elseif not rallyUtil.hasPunctuation(last_char) then
        -- table.insert(self.validation_issues, 'missing freeform puncuation')
      end
    end
  end
end

function C:getAudioModeSetting()
  return self.audioMode
end

function C:getAudioMode()
  local audioMode = self:getAudioModeSetting()

  -- local audioMode = RallyEnums.pacenoteAudioMode.auto
  -- local audioMode = RallyEnums.pacenoteAudioMode.freeform
  -- local audioMode = RallyEnums.pacenoteAudioMode.structuredOnline
  -- local audioMode = RallyEnums.pacenoteAudioMode.structuredOffline

  if audioMode == RallyEnums.pacenoteAudioMode.auto then
    return self.notebook:getAudioMode()
  else
    return audioMode
  end
end

function C:getAudioModeString()
  local audioMode = self:getAudioMode()
  return RallyEnums.pacenoteAudioModeNames[audioMode]
end

function C:isAudioModeStructuredOnline()
  return self:getAudioMode() == RallyEnums.pacenoteAudioMode.structuredOnline
end

function C:isAudioModeStructuredOffline()
  return self:getAudioMode() == RallyEnums.pacenoteAudioMode.structuredOffline
end

function C:isAudioModeFreeform()
  return self:getAudioMode() == RallyEnums.pacenoteAudioMode.freeform
end

function C:isAudioModeCustom()
  return self:getAudioMode() == RallyEnums.pacenoteAudioMode.custom
end

function C:setAudioMode(mode)
  self.audioMode = mode
end

function C:useStructured()
  if self.metadata.system then
    return false
  else
    return self:isAudioModeStructuredOnline() or self:isAudioModeStructuredOffline()
  end
end

function C:selectedCodriverLanguage()
  return self.notebook:selectedCodriverLanguage()
end

function C:selectedCodriver()
  return self.notebook:selectedCodriver()
end

function C:is_valid()
  return #self.validation_issues == 0
end

function C:pacenoteTextForSelect()
  local txtForSelectionItem = ''
  local preview = self:noteOutputPreview()

  local tokens = split(self.name, " ")
  if #tokens >= 2 then
    txtForSelectionItem = tokens[2]
  end

  -- if self.slowCorner then
  --   txtForSelectionItem = txtForSelectionItem..' [S]'
  -- end

  txtForSelectionItem = txtForSelectionItem..' - '..preview

  return txtForSelectionItem
end

function C:slowCornerAsText()
  if self.slowCorner then
    return '[S] slow corner'
  else
    return ''
  end
end

function C:triggerTypeAsText()
  local ttShort = self:triggerTypeAsSmallIndicator()
  local ttShortStr = ''
  if ttShort then
    ttShortStr = '['..ttShort..'] '
  end
  return 'triggerType: '..ttShortStr..RallyEnums.triggerTypeName[self.triggerType]
end

function C:triggerTypeAsSmallIndicator()
  if self.triggerType == RallyEnums.triggerType.csImmediate then
    return 'I'
  elseif self.triggerType == RallyEnums.triggerType.csStatic then
    return 'csS'
  elseif self.triggerType == RallyEnums.triggerType.csHalf then
    return 'cs+50%'
  elseif self.triggerType == RallyEnums.triggerType.ceMinus5 then
    return 'ce-5m'
  elseif self.triggerType == RallyEnums.triggerType.ceStatic then
    return 'ceS'
  else
    return nil
  end
end

function C:getCornerStartWaypoint()
  for i,wp in ipairs(self.pacenoteWaypoints.sorted) do
    if wp.waypointType == waypointTypes.wpTypeCornerStart then
      return wp
    end
  end
  return nil
end

function C:getCornerEndWaypoint()
  for i,wp in ipairs(self.pacenoteWaypoints.sorted) do
    if wp.waypointType == waypointTypes.wpTypeCornerEnd then
      return wp
    end
  end
  return nil
end

function C:onSerialize()
  -- the per-language `notes` cache is no longer persisted: structured text is rebuilt
  -- from `self.structured` via the active compositor at load time, distance-call fields
  -- are recomputed by autofillDistanceCalls(), and custom-mode audio filenames are
  -- derived by convention from `self.name`. freeform-mode text would be lost on save;
  -- warn so it doesn't go silently missing.
  if self.notebook and self.notebook.isAudioModeFreeform and self.notebook:isAudioModeFreeform() then
    log('W', logTag, 'onSerialize: freeform-mode notebook will lose `notes` text on save (not yet migrated to a new on-disk home)')
  end

  local ret = {
    oldId = self.id,
    name = self.name,
    pk = self.pk,
    playback_rules = self.playback_rules,
    isolate = self.isolate or false,
    triggerType = self.triggerType or RallyEnums.triggerType.dynamic,
    slowCornerReleaseType = self.slowCornerReleaseType or defaultSlowCornerReleaseType,
    audioMode = self.audioMode or RallyEnums.pacenoteAudioMode.auto,
    todo = self.todo or false,
    metadata = self.metadata,
    pacenoteWaypoints = self.pacenoteWaypoints:onSerialize(),
    structured = self.structured:onSerialize(),
    slowCorner = self.slowCorner,
    ignoreDistanceCalls = self.ignoreDistanceCalls,
    includeLinkWord = self.includeLinkWord ~= false,
    distanceBeforeModifier = self.distanceBeforeModifier == true,
  }
  if self:getDistanceMeasureWaypoint() ~= defaultDistanceMeasureWaypoint then
    ret.distanceMeasureWaypoint = self:getDistanceMeasureWaypoint()
  end

  -- custom-mode audio: only manual anchors are persisted. The computed assignment is
  -- rebuilt from those anchors and the current audio folder.
  if self.customAudioAnchors and #self.customAudioAnchors > 0 then
    ret.customAudioAnchors = self.customAudioAnchors
  end

  return ret
end

function C:onDeserialized(data, oldIdMap)
  self.name = data.name
  self.pk = data.pk or rallyUtil.randomId()
  self.playback_rules = data.playback_rules
  self.isolate = data.isolate or false
  self.slowCorner = data.slowCorner or false
  self.slowCornerReleaseType = data.slowCornerReleaseType or defaultSlowCornerReleaseType
  self.ignoreDistanceCalls = data.ignoreDistanceCalls or false
  self.includeLinkWord = data.includeLinkWord ~= false
  self.distanceBeforeModifier = data.distanceBeforeModifier == true
  self:setDistanceMeasureWaypoint(data.distanceMeasureWaypoint)

  if data.codriverWait then
    if data.codriverWait == 'none' then
      data.triggerType = RallyEnums.triggerType.dynamic
    end
    if data.codriverWait == 'small' then
      data.triggerType = RallyEnums.triggerType.dynamic
    end
    if data.codriverWait == 'medium' then
      data.triggerType = RallyEnums.triggerType.dynamic
    end
    if data.codriverWait == 'large' then
      data.triggerType = RallyEnums.triggerType.csHalf
    end
  end
  self.triggerType = data.triggerType or RallyEnums.triggerType.dynamic

  self.todo = data.todo or false

  -- self.notes is no longer persisted; it's a transient in-memory cache. init()
  -- already set up empty per-language slots. for legacy notebooks (or freeform
  -- mode), copy any saved `data.notes` so the in-memory shape isn't lost; the
  -- structured text will be overwritten at load time by refreshAllStructuredNotes()
  -- and distance fields by autofillDistanceCalls(), both invoked from path:onDeserialized().
  if data.notes then
    for lang, langData in pairs(data.notes) do
      self.notes[lang] = langData
    end
  end

  self.metadata = data.metadata or {}

  -- legacy `fwdAudioTrigger` waypoints are no longer supported; drop them on load
  -- so they never enter the in-memory model and aren't re-emitted on save.
  local wps = data.pacenoteWaypoints
  if wps then
    local filtered = {}
    for _, wp in ipairs(wps) do
      if wp.waypointType ~= "fwdAudioTrigger" then
        table.insert(filtered, wp)
      end
    end
    wps = filtered
  end
  self.pacenoteWaypoints:onDeserialized(wps, oldIdMap)
  self.audioMode = data.audioMode or RallyEnums.pacenoteAudioMode.auto

  self.customAudioAnchors = data.customAudioAnchors

  self.structured:onDeserialized(data.structured)
end

function C:upgradeFromV2ToV3()
  for lang,langData in pairs(self.notes) do
    local freeformnote = langData.note
    langData.note = {
      freeform = freeformnote,
      structured = {},
    }
  end
end

function C:markTodo()
  self.todo = true
end

function C:clearTodo()
  self.todo = false
end

function C:setNavgraph(navgraphName, fallback)
  log('W', logTag, 'setNavgraph() not implemented')
end

function C:setAdjacentNotes(prevNote, nextNote)
  self.prevNote = prevNote
  self.nextNote = nextNote
end

function C:clearAdjacentNotes()
  self:setAdjacentNotes(nil, nil)
end

local function textForDrawDebug(drawConfig, selection_state, wp, dist_text, hover)
  local shift = selection_state.shift
  local noteText = wp.pacenote:noteTextForDrawDebug()
  local txt = nil

  if drawConfig.cs_text and wp:isCs() then
    txt = noteText

    if editor_rallyEditor and editor_rallyEditor.getPrefLockWaypoints() and selection_state.selected_pn_id then
      txt = '[LOCK] '..txt
    end

    if shift and hover then
      txt = '[CAMERA LOCK] '..txt
    end

    if not txt or txt == '' then
      txt = '<empty pacenote>'
    end
  elseif drawConfig.ce_text and wp:isCe() then
    txt = '['..waypointTypes.shortenWaypointType(wp.waypointType)
    if dist_text then
      txt = txt..','..dist_text
    end
    txt = txt..']'
  end

  return txt
end

local function drawWaypoint(drawConfig, selection_state, wp, dist_text, pulse)
  if not wp then return end

  pulse = pulse == nil and false or pulse -- default to false if not specified

  local hover_wp_id = selection_state.hover_wp_id
  local selected_wp_id = selection_state.selected_wp_id
  local shift = selection_state.shift
  local hover = hover_wp_id and hover_wp_id == wp.id
  local clr = nil
  local globalOpacity = drawConfig.globalOpacity or 1.0

  local pn_drawMode = drawConfig.pn_drawMode

  local alpha_shape = drawConfig.base_alpha * globalOpacity
  local alpha_text = drawConfig.base_alpha
  local clr_textFg = nil
  local clr_textBg = nil
  local radius_factor = nil

  local pn = wp.pacenote
  local valid = pn:is_valid()

  if pn_drawMode == pn_drawMode_selected then
    alpha_text = cc.pacenote_alpha_text_selected
    if selected_wp_id and selected_wp_id == wp.id then
      clr = wp:colorForWpType(pn_drawMode)
      alpha_shape = cc.waypoint_alpha_selected * globalOpacity
    else
      clr = wp:colorForWpType(pn_drawMode)
    end

    if not valid then
      clr_textFg = cc.clr_white
      clr_textBg = cc.clr_red_dark
    end
  elseif pn_drawMode == pn_drawMode_previous then
    clr = wp:colorForWpType(pn_drawMode)
    if wp:isCs() then
      radius_factor = drawConfig.cs_radius
    elseif wp:isCe() then
      radius_factor = drawConfig.ce_radius
    end

    if not valid then
      clr_textFg = cc.clr_white
      clr_textBg = cc.clr_red_dark
    end
  elseif pn_drawMode == pn_drawMode_next then
    clr = wp:colorForWpType(pn_drawMode)
    if wp:isCs() then
      radius_factor = drawConfig.cs_radius
    elseif wp:isCe() then
      radius_factor = drawConfig.ce_radius
    end

    if not valid then
      clr_textFg = cc.clr_white
      clr_textBg = cc.clr_red_dark
    end
  elseif pn_drawMode == pn_drawMode_partitionedSnaproad then
    alpha_text = 1.0
    clr = wp:colorForWpType(pn_drawMode_previous)
    if not valid then
      clr_textFg = cc.clr_white
      clr_textBg = cc.clr_red_dark
    end
    radius_factor = cc.pacenote_adjacent_radius_factor
  elseif pn_drawMode == pn_drawMode_background then
    if valid then
      -- clr = cc.waypoint_clr_background
      clr = wp:colorForWpType(pn_drawMode)
    else
      clr = cc.clr_red_dark
      clr_textFg = cc.clr_white
      clr_textBg = cc.clr_red_dark
    end
    radius_factor = cc.pacenote_adjacent_radius_factor
  elseif pn_drawMode == pn_drawMode_noSelection then
    alpha_text = 1.0
    if valid then
      -- dark theme
      clr = cc.waypoint_clr_background
      clr_textFg = cc.clr_white
      clr_textBg = cc.clr_black
    else
      clr = cc.clr_red_dark
      clr_textFg = cc.clr_white
      clr_textBg = cc.clr_red_dark
    end
    if wp:isCs() and drawConfig.cs_shape_color then
      clr = drawConfig.cs_shape_color
    end
  end

  if valid and pn.todo then
    clr_textFg = cc.clr_black
    clr_textBg = cc.clr_orange
  end

  if wp:isCs() and drawConfig.cs_text_bg_color then
    clr_textBg = drawConfig.cs_text_bg_color
    clr_textFg = drawConfig.cs_text_fg_color or clr_textFg
  end

  -- Apply pulsating effect to radius_factor (scale between 0.85 and 1.15)
  if pulse and selection_state.pulseTime then
    local pulseScale = 0.85 + 0.3 * (math.sin(selection_state.pulseTime * 4) * 0.5 + 0.5)
    radius_factor = (radius_factor or 1.0) * pulseScale
  end

  local text = textForDrawDebug(drawConfig, selection_state, wp, dist_text, hover)
  wp:drawDebug(hover, text, clr, alpha_shape, alpha_text, clr_textFg, clr_textBg, radius_factor, globalOpacity)
end

local function drawCamPoint(pos, drawConfig, pacenoteToolsState)
  local snaproad = pacenoteToolsState.snaproad
  local clr = cc.clr_grey
  -- if snaproad and snaproad:isRouteSourced() then
  --   clr = cc.snaproads_clr_route
  -- end
  local alphaShape = cc.snaproads_alpha_cameraPoint * drawConfig.globalOpacity
  -- local wp_selected = pacenoteToolsState.selected_wp_id

  -- if wp_selected then
  --   alphaShape = cc.waypoint_alpha_selected * drawConfig.globalOpacity
  -- end
  debugDrawer:drawSphere(
    pos,
    1.5,
    ColorF(clr[1],clr[2],clr[3], alphaShape)
  )
end

local function formatDistanceStringMeters(dist)
  return tostring(round(dist))..'m'
end

local function prettyDistanceStringMeters(from, to)
  if not (from and to) then return "?m" end
  local d = from.pos:distance(to.pos)
  return formatDistanceStringMeters(d)
end

local function lowerBound(entries, distance)
  local lo = 1
  local hi = #entries + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if entries[mid].distanceAlongRoute < distance then
      lo = mid + 1
    else
      hi = mid
    end
  end
  return lo
end

local function snaproadForPacenote(pacenote)
  if pacenote.notebook and pacenote.notebook.getSnaproad then
    local snaproad = pacenote.notebook:getSnaproad()
    if snaproad then return snaproad end
  end

  if editor_rallyEditor and editor_rallyEditor.getPacenotesWindow then
    local pacenotesWindow = editor_rallyEditor.getPacenotesWindow()
    if pacenotesWindow and pacenotesWindow.getSnaproad then
      return pacenotesWindow:getSnaproad()
    end
  end

  return nil
end

local function pacenoteLabelMode()
  if editor_rallyEditor and editor_rallyEditor.getPrefPacenoteLabelMode then
    return editor_rallyEditor.getPrefPacenoteLabelMode()
  end
  if editor_rallyEditor and editor_rallyEditor.getPrefShowAllPacenoteLabels and editor_rallyEditor.getPrefShowAllPacenoteLabels() then
    return pacenoteLabelModeAll
  end
  return pacenoteLabelModeDistance
end

local function pacenoteLabelDistance()
  if editor_rallyEditor and editor_rallyEditor.getPrefPacenoteLabelDistance then
    return editor_rallyEditor.getPrefPacenoteLabelDistance()
  end
  return 100
end

local function pacenoteLabelNearCameraCount()
  if editor_rallyEditor and editor_rallyEditor.getPrefPacenoteLabelNearCameraCount then
    return editor_rallyEditor.getPrefPacenoteLabelNearCameraCount()
  end
  return 3
end

local function buildPacenoteLabelEntries(notebook, snaproad)
  local entries = {}
  if not (notebook and notebook.pacenotes and snaproad and snaproad.closestSnapResult) then return entries end

  for index,pacenote in ipairs(notebook.pacenotes.sorted) do
    if pacenote and not pacenote.missing then
      local wpCs = pacenote:getCornerStartWaypoint()
      local wpCe = pacenote:getCornerEndWaypoint()
      if wpCs or wpCe then
        local csLoc = wpCs and snaproad:closestSnapResult(wpCs.pos, true) or nil
        local ceLoc = wpCe and snaproad:closestSnapResult(wpCe.pos, true) or nil
        if (csLoc and csLoc.distanceAlongRoute) or (ceLoc and ceLoc.distanceAlongRoute) then
          table.insert(entries, {
            pacenoteId = pacenote.id,
            index = index,
            csDistanceAlongRoute = csLoc and csLoc.distanceAlongRoute or nil,
            ceDistanceAlongRoute = ceLoc and ceLoc.distanceAlongRoute or nil,
            csPos = wpCs and vec3(wpCs.pos) or nil,
            cePos = wpCe and vec3(wpCe.pos) or nil,
          })
        end
      end
    end
  end

  return entries
end

local function getPacenoteLabelEntries(pacenoteToolsState, notebook, snaproad)
  return buildPacenoteLabelEntries(notebook, snaproad)
end

local function minRouteDistanceToEntry(entry, cameraDistanceAlongRoute)
  local minDist = math.huge
  if entry.csDistanceAlongRoute then
    minDist = math.min(minDist, math.abs(entry.csDistanceAlongRoute - cameraDistanceAlongRoute))
  end
  if entry.ceDistanceAlongRoute then
    minDist = math.min(minDist, math.abs(entry.ceDistanceAlongRoute - cameraDistanceAlongRoute))
  end
  return minDist
end

local function minCameraDistanceToEntry(entry, cameraPos)
  local minDistSq = math.huge
  if entry.csPos then
    minDistSq = math.min(minDistSq, cameraPos:squaredDistance(entry.csPos))
  end
  if entry.cePos then
    minDistSq = math.min(minDistSq, cameraPos:squaredDistance(entry.cePos))
  end
  return math.sqrt(minDistSq)
end

local function visiblePacenoteLabelIds(pacenoteToolsState, notebook, snaproad, maxDistance, nearCameraCount)
  if not (pacenoteToolsState and snaproad and core_camera and core_camera.getPosition and snaproad.closestSnapResult) then
    return nil
  end

  local camPos = core_camera.getPosition()
  local pivotLoc = FocusedNearDraw.getCameraLookSnaproadLocation(pacenoteToolsState, snaproad, camPos)
  if not (pivotLoc and pivotLoc.distanceAlongRoute) then return nil end
  nearCameraCount = tonumber(nearCameraCount) or 3

  local cache = pacenoteToolsState._pacenoteLabelVisibleCache
  if cache
      and cache.notebook == notebook
      and cache.snaproad == snaproad
      and cache.maxDistance == maxDistance
      and cache.nearCameraCount == nearCameraCount
      and cache.pivotDistanceAlongRoute == pivotLoc.distanceAlongRoute
      and cache.cameraPosX == camPos.x
      and cache.cameraPosY == camPos.y
      and cache.cameraPosZ == camPos.z then
    pacenoteToolsState._pacenoteLabelRaycastCursorPos = cache.cursorPos
    return cache.visibleIds
  end

  local entries = getPacenoteLabelEntries(pacenoteToolsState, notebook, snaproad)
  local visibleIds = {}

  local closestPhysicalDistance = math.huge
  local pivotIndex = nil
  local pivotRouteDistance = math.huge

  for i,entry in ipairs(entries) do
    closestPhysicalDistance = math.min(closestPhysicalDistance, minCameraDistanceToEntry(entry, camPos))
    local routeDistance = minRouteDistanceToEntry(entry, pivotLoc.distanceAlongRoute)
    if routeDistance < pivotRouteDistance then
      pivotRouteDistance = routeDistance
      pivotIndex = i
    end
  end

  pacenoteToolsState._pacenoteLabelRaycastCursorPos = pivotLoc.pos

  if closestPhysicalDistance <= maxDistance and pivotIndex then
    local startIndex = math.max(1, pivotIndex - nearCameraCount)
    local endIndex = math.min(#entries, pivotIndex + nearCameraCount)
    for i = startIndex, endIndex do
      visibleIds[entries[i].pacenoteId] = true
    end
  end

  pacenoteToolsState._pacenoteLabelVisibleCache = {
    notebook = notebook,
    snaproad = snaproad,
    maxDistance = maxDistance,
    nearCameraCount = nearCameraCount,
    pivotDistanceAlongRoute = pivotLoc.distanceAlongRoute,
    cameraPosX = camPos.x,
    cameraPosY = camPos.y,
    cameraPosZ = camPos.z,
    cursorPos = pivotLoc.pos,
    visibleIds = visibleIds,
  }

  return visibleIds
end

local function showPacenoteLabel(pacenote, pacenoteToolsState)
  local mode = pacenoteLabelMode()
  if mode == pacenoteLabelModeAll then return true end

  local snaproad = snaproadForPacenote(pacenote)
  local visibleIds = visiblePacenoteLabelIds(pacenoteToolsState, pacenote.notebook, snaproad, pacenoteLabelDistance(), pacenoteLabelNearCameraCount())
  return visibleIds and visibleIds[pacenote.id] == true
end

function C:drawDebugPacenoteHelper(drawConfig, pacenoteToolsState)
  local text_dist = nil
  local wp_cs = self:getCornerStartWaypoint()
  local wp_ce = self:getCornerEndWaypoint()

  -- (3) draw the CS
  if drawConfig.cs then
    text_dist = nil
    local isSelectedPacenote = self.id == pacenoteToolsState.selected_pn_id
    local pulse = isSelectedPacenote and (pacenoteToolsState.selected_wp_id == nil or pacenoteToolsState.selected_wp_id == wp_cs.id)
    drawWaypoint(drawConfig, pacenoteToolsState, wp_cs, text_dist, pulse)
  end

  -- (3.1) draw the camera point
  if drawConfig.campoint then
    local camPos = self:getPosForOrbitCamera()
    drawCamPoint(camPos, drawConfig, pacenoteToolsState)
  end

  -- (5) draw the CE
  if drawConfig.ce then
    text_dist = nil
    local isSelectedPacenote = self.id == pacenoteToolsState.selected_pn_id
    local pulse = isSelectedPacenote and (pacenoteToolsState.selected_wp_id == nil or pacenoteToolsState.selected_wp_id == wp_ce.id)
    drawWaypoint(drawConfig, pacenoteToolsState,  wp_ce, text_dist, pulse)
  end

  -- (8) draw the measurement geometry if available
  if drawConfig.measurement then
    self:drawDebugMeasurement()
  end
end

function C:drawDebugMeasurement()
  if not self.measurements then return end

  local variant = self:selectedMeasurementVariant()
  if not variant then return end

  local segments = variant.segments
  if not segments or #segments == 0 then
    segments = { variant }
  end

  local maxDrawRadius = 750
  local segmentColors = {
    cc.clr_purple,
    cc.clr_teal,
    cc.clr_orange,
  }

  for i, measurement in ipairs(segments) do
    if measurement and measurement.center and measurement.radius and measurement.p1 and measurement.p2 and measurement.p3 then
      local prefix = #segments > 1 and string.format("%d/%d: ", i, #segments) or ""
      local clr = segmentColors[i] or cc.clr_purple
      local alpha = 0.7

      -- Avoid drawing unusably large fitted arcs.
      if measurement.radius * 2 < maxDrawRadius then
        geoPacenotes.drawPacenoteMeasurement(
          measurement.center,
          measurement.radius,
          measurement.arcDistance,
          measurement.p1,
          measurement.p2,
          measurement.p3,
          clr,
          alpha,
          prefix,
          measurement.fitQuality,
          measurement.arcDegrees
        )
      end
    end
  end

  for i = 1, #segments - 1 do
    local splitPoint = segments[i] and segments[i].p3
    if splitPoint then
      debugDrawer:drawSphere(
        splitPoint,
        cc.snaproads_radius * 1.1,
        ColorF(1, 1, 1, 0.9),
        false, false
      )
    end
  end
end

function C:waypointForBeforeLink()
  local to_wp = self:getCornerStartWaypoint()
  return to_wp
end

function C:getDistanceMeasureWaypoint()
  return normalizeDistanceMeasureWaypoint(self.distanceMeasureWaypoint)
end

function C:setDistanceMeasureWaypoint(value)
  local normalized = normalizeDistanceMeasureWaypoint(value)
  self.distanceMeasureWaypoint = normalized ~= defaultDistanceMeasureWaypoint and normalized or nil
end

function C:waypointForAfterLink()
  local from_wp = self:getDistanceMeasureWaypoint() == distanceMeasureWaypointCornerStart
    and self:getCornerStartWaypoint()
    or self:getCornerEndWaypoint()
  return from_wp
end

function C:distanceCornerEndToCornerStart(toPacenote)
  local startWp = self:waypointForAfterLink()
  local endWp = toPacenote:getCornerStartWaypoint()

  if not startWp or not endWp then
    return 0.0
  end

  -- Source snaproad from the parent notebook (set lazily by either the editor's
  -- pacenotes window or the runtime RallyManager once road geometry is ready).
  -- Editor singleton kept as a fallback for legacy callers.
  local snaproad = (self.notebook and self.notebook.getSnaproad and self.notebook:getSnaproad())
    or (editor_rallyEditor and editor_rallyEditor.getPacenotesWindow() and editor_rallyEditor.getPacenotesWindow():getSnaproad())
  if not snaproad then
    return nil
  end

  return snaproad:distanceBetweenPositions(startWp.pos, endWp.pos, true)
end

function C:noteOutputCustom()
  if not self.notebook or not self.notebook.customAudioBasenamesFor then return nil end
  local basenames = self.notebook:customAudioBasenamesFor(self)
  if #basenames == 0 then return nil end

  local transcriptions = self.notebook.loadCustomPacenoteTranscriptions
    and self.notebook:loadCustomPacenoteTranscriptions() or {}

  local parts = {}
  for _, base in ipairs(basenames) do
    local entry = transcriptions[base]
    local desc = entry and entry.description
    if desc and desc ~= '' then
      table.insert(parts, desc)
    end
  end

  if #parts == 0 then return nil end
  return table.concat(parts, " | ")
end

function C:noteOutputPreview()
  local preview = nil

  if self:useStructured() then
    local struc
    if self:isAudioModeStructuredOffline() then
      struc = self:noteOutputStructuredOffline()
    else
      struc = self:noteOutputStructuredOnline()
    end
    if #struc > 0 then
      preview = dumps(struc)
      preview = string.gsub(preview, "\n", " ")
    end
  elseif self:isAudioModeFreeform() then
    preview = self:noteOutputFreeform()
  elseif self:isAudioModeCustom() then
    -- custom pacenotes never fall back to a structured preview; an unassigned/empty
    -- custom pacenote just shows <empty>.
    preview = self:noteOutputCustom() or self:getCustomDescription()
  end

  if not preview then
    preview = '<empty>'
  end

  if self.slowCorner then
    preview = '[S] '..preview
  end

  return preview
end

function C:noteTextForDrawDebug()
  return self:noteOutputPreview()
end

-- used when creating a new pacenote
function C:drawDebugPacenotePartitionAllSnaproad(pacenoteToolsState)
  local drawConfig = {
    pn_drawMode = pn_drawMode_partitionedSnaproad,
    cs = true,
    ce = true,
    base_alpha = cc.pacenote_base_alpha_no_sel,
    cs_text = showPacenoteLabel(self, pacenoteToolsState),
    ce_text = false,
    cs_radius = cc.pacenote_adjacent_radius_factor,
    ce_radius = cc.pacenote_adjacent_radius_factor,
  }
  self:drawDebugPacenoteHelper(drawConfig, pacenoteToolsState)
end

-- used when no pacenote is selected
function C:drawDebugPacenoteNoSelection(pacenoteToolsState, globalOpacity)
  local drawConfig = {
    pn_drawMode = pn_drawMode_noSelection,
    cs = true,
    ce = false,
    base_alpha = cc.pacenote_base_alpha_no_sel,
    cs_text = showPacenoteLabel(self, pacenoteToolsState),
    ce_text = false,
    globalOpacity = globalOpacity,
  }
  self:drawDebugPacenoteHelper(drawConfig, pacenoteToolsState)
end

function C:drawDebugPacenoteNoSelectionRainbow(pacenoteToolsState, globalOpacity, csColor, showLabel, textColor)
  local drawConfig = {
    pn_drawMode = pn_drawMode_noSelection,
    cs = true,
    ce = false,
    base_alpha = cc.pacenote_base_alpha_no_sel,
    cs_text = showLabel == true,
    ce_text = false,
    globalOpacity = globalOpacity,
    cs_shape_color = csColor,
    cs_text_bg_color = showLabel and csColor or nil,
    cs_text_fg_color = showLabel and textColor or nil,
  }
  self:drawDebugPacenoteHelper(drawConfig, pacenoteToolsState)
end

function C:drawDebugPacenoteBackground(pacenoteToolsState, globalOpacity, showTextOverride)
  local showText = showTextOverride
  if showText == nil then
    showText = showPacenoteLabel(self, pacenoteToolsState)
  end

  local drawConfig = {
    pn_drawMode = pn_drawMode_background,
    cs = true,
    ce = true,
    base_alpha = cc.pacenote_base_alpha_background,
    cs_text = showText,
    ce_text = false,
    globalOpacity = globalOpacity,
  }
  self:drawDebugPacenoteHelper(drawConfig, pacenoteToolsState)
end

function C:drawDebugPacenoteNext(pacenoteToolsState, pn_sel, globalOpacity)
  local showText = not editor_rallyEditor or not editor_rallyEditor.getPrefShowAdjacentPacenoteText or editor_rallyEditor.getPrefShowAdjacentPacenoteText()
  local drawConfig = {
    pn_drawMode = pn_drawMode_next,
    cs = true,
    ce = true,
    base_alpha = cc.pacenote_base_alpha_next,
    cs_text = showText,
    ce_text = false,
    cs_radius = cc.pacenote_adjacent_radius_factor,
    ce_radius = cc.pacenote_adjacent_radius_factor,
    globalOpacity = globalOpacity,
  }
  self:drawDebugPacenoteHelper(drawConfig, pacenoteToolsState)
end

function C:drawDebugPacenotePrev(pacenoteToolsState, pn_sel, globalOpacity)
  local showText = not editor_rallyEditor or not editor_rallyEditor.getPrefShowAdjacentPacenoteText or editor_rallyEditor.getPrefShowAdjacentPacenoteText()
  local drawConfig = {
    pn_drawMode = pn_drawMode_previous,
    cs = true,
    ce = true,
    base_alpha = cc.pacenote_base_alpha_prev,
    cs_text = showText,
    ce_text = false,
    cs_radius = cc.pacenote_adjacent_radius_factor,
    ce_radius = cc.pacenote_adjacent_radius_factor,
    globalOpacity = globalOpacity,
  }
  self:drawDebugPacenoteHelper(drawConfig, pacenoteToolsState)
end

function C:drawDebugPacenoteSelected(pacenoteToolsState, globalOpacity)
  local drawConfig = {
    pn_drawMode = pn_drawMode_selected,
    cs = true,
    campoint = core_camera.getActiveGlobalCameraName() == "pacenoteOrbit",
    ce = true,
    base_alpha = cc.pacenote_base_alpha_selected,
    cs_text = true,
    ce_text = false,
    measurement = pacenoteToolsState and pacenoteToolsState.showMeasurements ~= false,
    globalOpacity = globalOpacity,
  }
  self:drawDebugPacenoteHelper(drawConfig, pacenoteToolsState)
end

function C:audioFnameFreeform()
  local noteStr = self:noteOutputFreeform()
  local fname = self.notebook:missionPacenoteAudioFile(rallyUtil.freeformDir, noteStr)
  return fname
end

local function audioItemForEntry(entry, fallbackFname)
  if entry.audioCandidates and #entry.audioCandidates > 0 then
    return { candidates = entry.audioCandidates, category = entry.category }
  end
  return { fname = entry.audioFname or fallbackFname, category = entry.category }
end

function C:audioItemsStructuredOnline(opts)
  opts = opts or {}
  local entries = self:structuredPhraseEntriesOnline(nil, nil, nil, {
    resolveVariants = true,
    includeMissingVariant = opts.includeMissingVariant,
  }) or {}
  local itemsOut = {}

  for _, entry in ipairs(entries) do
    local fallbackFname = self.notebook:missionPacenoteAudioFile(rallyUtil.structuredDir, entry.text)
    table.insert(itemsOut, audioItemForEntry(entry, fallbackFname))
  end

  return itemsOut
end

function C:audioFnamesStructuredOnline(opts)
  opts = opts or {}
  local fnamesOut = {}

  for _, item in ipairs(self:audioItemsStructuredOnline(opts)) do
    if type(item) == 'table' and item.candidates and item.candidates[1] then
      table.insert(fnamesOut, item.candidates[1].fname)
    elseif type(item) == 'table' and item.fname then
      table.insert(fnamesOut, item.fname)
    else
      table.insert(fnamesOut, item)
    end
  end

  return fnamesOut
end

function C:audioItemsStructuredOffline(opts)
  opts = opts or {}
  local entries = self:structuredPhraseEntriesOffline({
    resolveVariants = true,
    includeMissingVariant = opts.includeMissingVariant,
  }) or {}
  local voicepack, voicepackEntry = self.notebook:resolveActiveVoicepack()
  local compositor = self.notebook:getOfflineTextCompositor()
  local itemsOut = {}

  if not voicepack or not compositor then
    return itemsOut
  end

  for _, entry in ipairs(entries) do
    local pacenoteHash = compositor:pacenoteHash(entry.text)
    local fallbackFname
    if voicepackEntry and voicepackEntry.dir then
      fallbackFname = voicepackMod.getEntryAudioFile(voicepackEntry, rallyUtil.makePacenoteAudioFilename(pacenoteHash))
    else
      fallbackFname = voicepackMod.getPacenoteFile(voicepack, pacenoteHash)
    end
    table.insert(itemsOut, audioItemForEntry(entry, fallbackFname))
  end

  return itemsOut
end

function C:audioFnamesStructuredOffline(opts)
  opts = opts or {}
  local notesOut = {}

  for _, item in ipairs(self:audioItemsStructuredOffline(opts)) do
    if type(item) == 'table' and item.candidates and item.candidates[1] then
      table.insert(notesOut, item.candidates[1].fname)
    elseif type(item) == 'table' and item.fname then
      table.insert(notesOut, item.fname)
    else
      table.insert(notesOut, item)
    end
  end

  return notesOut
end

function C:playbackAllowed(currLap, maxLap)
  -- local context = { currLap = currLap, maxLap = maxLap }
  local condition = self.playback_rules
  currLap = currLap or -1
  maxLap = maxLap or -1

  -- log('D', logTag,
  --   "playbackAllowed name='"..self.name..
  --   "' condition='"..tostring(condition)..
  --   "' currLap="..tostring(currLap..
  --   " maxLap="..tostring(maxLap)))

  -- If condition is nil or empty/whitespace string, return true
  if condition == nil or condition:match("^%s*$") then
    return true, nil
  end

  -- Lowercase the condition for case-insensitive comparison
  local lowerCondition = condition:lower()

  -- Check for 'true' or 't'
  if lowerCondition == 'true' or lowerCondition == 't' then
    return true, nil
  end

  -- Check for 'false' or 'f'
  if lowerCondition == 'false' or lowerCondition == 'f' then
    return false, nil
  end

  -- Attempt to load the condition as Lua code
  local func, err = loadstring("return " .. condition)
  if func then
    -- Function compiled successfully, now execute it safely
    setfenv(func, context)
    local status, result = pcall(func, context)
    if status then
      return result, nil
    else
      -- Handle runtime error in the function
      return false, "Runtime error in condition: " .. result
    end
  else
    -- Handle syntax error in the condition
    return false, "Syntax error in condition: " .. err
  end
end

function C:vehiclePlacementPosAndRot(distAway)
  distAway = distAway or 15
  local cs = self:getCornerStartWaypoint()
  local ce = self:getCornerEndWaypoint()

  local wp_pos = cs
  local wp_dir = ce

  if wp_dir and wp_pos then
    local pos1 = wp_pos.pos + (wp_pos.normal * distAway)
    local pos2 = wp_pos.pos + (-wp_pos.normal * distAway)
    local pos = nil

    if wp_dir.pos:distance(pos1) > wp_dir.pos:distance(pos2) then
      pos = pos1
    else
      pos = pos2
    end

    local fwd = wp_pos.pos - pos
    local up = vec3(0,0,1)
    local rot = quatFromDir(fwd, up):normalized()

    return pos, rot
  else
    return nil, nil
  end
end

function C:nameComponents()
  local baseName, number = string.match(self.name, "(.-)%s*([%d%.]+)$")
  return baseName, number
end

function C:matchesSearchPattern(searchPattern)
  for lang,note in pairs(self.notes) do
    local fullNote = self:noteOutputFreeform(lang)
    -- log('D', 'wtf', 'matching "'..fullNote..'" against "'..searchPattern..'"')
    if rallyUtil.matchSearchPattern(searchPattern, fullNote) then
      return true
    end
  end

  return false
end

function C:_moveWaypointTowardsStepper(snaproad, wp, fwd)
  local newSnapResult = snaproad:advanceAlongRoute(wp.pos, 2.0, fwd)

  if newSnapResult then
    wp:setPos(newSnapResult.pos)
    wp.pacenote.notebook:autofillDistanceCalls()
    local normalVec = snaproad:normalForSnapResult(newSnapResult)
    if normalVec then
      wp:setNormal(normalVec)
    end

    -- if wp:isCs() then
    --   local pn_sel = wp.pacenote
    --   local wp_sel = wp
    --   local point_cs = snaproad:closestSnapPoint(wp_sel.pos)
    -- end
  end
end

function C:moveWaypointTowards(snaproads, wp, fwd, step)
  step = step or 1
  for _ = 1,step do
    self:_moveWaypointTowardsStepper(snaproads, wp, fwd)
  end
end

function C:isLastPacenote()
  return self.id == self.notebook.pacenotes.sorted[#self.notebook.pacenotes.sorted].id
end

function C:refreshFreeform()
  local lang = self:selectedCodriverLanguage()
  local note = self:getNoteFieldFreeform()

  note = rallyUtil.trimString(note)

  if note == rallyUtil.autofill_blocker then return end
  if note == '' then return end
  if note == rallyUtil.unknown_transcript_str then return end

  self:setNoteFieldFreeform(note)
end

function C:toggleSlowCorner()
  self.slowCorner = not self.slowCorner
end

function C:toggleIgnoreDistanceCalls()
  self.ignoreDistanceCalls = not self.ignoreDistanceCalls
end

function C:toggleIncludeLinkWord()
  self.includeLinkWord = not (self.includeLinkWord ~= false)
end

function C:toggleDistanceBeforeModifier()
  self.distanceBeforeModifier = not (self.distanceBeforeModifier == true)
end

function C:toggleIsolate()
  self.isolate = not self.isolate

  if self.isolate then
    if self:getNoteFieldBefore() ~= rallyUtil.autofill_blocker then
      self:setNoteFieldBefore(rallyUtil.autodist_internal_level1, -1)
    end
    if self:getNoteFieldAfter() ~= rallyUtil.autofill_blocker then
      self:setNoteFieldAfter(rallyUtil.autodist_internal_level1, -1)
    end
  else
    if self:getNoteFieldBefore() ~= rallyUtil.autofill_blocker then
      -- setting to an empty string will allow autoFillDistanceCalls to do it's thing.
      self:setNoteFieldBefore('', -1)
    end
    if self:getNoteFieldAfter() ~= rallyUtil.autofill_blocker then
      self:setNoteFieldAfter('', -1)
    end
  end
end

function C:setTriggerType(val)
  self.triggerType = val
end

function C:getTriggerType()
  return self.triggerType
end

function C:setSlowCornerReleaseType(val)
  self.slowCornerReleaseType = val
end

function C:getSlowCornerReleaseType()
  return self.slowCornerReleaseType
end

function C:isSlowCornerReleaseCsStaticMinus40()
  return self.slowCorner and self.slowCornerReleaseType == RallyEnums.slowCornerReleaseType.csStaticMinus40
end

function C:isSlowCornerReleaseCsHalf()
  return self.slowCorner and self.slowCornerReleaseType == RallyEnums.slowCornerReleaseType.csHalf
end

function C:isSlowCornerReleaseCsStatic()
  return self.slowCorner and self.slowCornerReleaseType == RallyEnums.slowCornerReleaseType.csStatic
end

function C:isSlowCornerReleaseCeStatic()
  return self.slowCorner and self.slowCornerReleaseType == RallyEnums.slowCornerReleaseType.ceStatic
end

function C:isSlowCornerReleaseCeMinus5()
  return self.slowCorner and self.slowCornerReleaseType == RallyEnums.slowCornerReleaseType.ceMinus5
end

function C:refreshStructured()
  local entries = self:structuredPhraseEntriesOnline()
  if not entries then return end
  local humanReadable = phraseEntriesToText(entries)
  self:setNoteFieldStructured(humanReadable)
end

function C:getPosForOrbitCamera()
  -- Return cached value if available
  if self._cachedCamPos then
    return self._cachedCamPos
  end

  -- Calculate camera position
  local wp_cs = self:getCornerStartWaypoint()
  local wp_ce = self:getCornerEndWaypoint()

  local camPos = nil
  if self.halfpoint and wp_cs and wp_ce then
    -- Calculate centroid of triangle formed by halfpoint, CS, and CE
    local halfPos = vec3(self.halfpoint.pos)
    local csPos = vec3(wp_cs.pos)
    local cePos = vec3(wp_ce.pos)

    camPos = vec3(
      (halfPos.x + csPos.x + cePos.x) / 3,
      (halfPos.y + csPos.y + cePos.y) / 3,
      (halfPos.z + csPos.z + cePos.z) / 3
    )
  elseif wp_cs and wp_ce then
    -- Fallback to midpoint between CS and CE
    local csPos = vec3(wp_cs.pos)
    local cePos = vec3(wp_ce.pos)

    camPos = vec3(
      (csPos.x + cePos.x) / 2,
      (csPos.y + cePos.y) / 2,
      (csPos.z + cePos.z) / 2
    )
  else
    -- Last resort fallback to corner start
    local wp = self:getCornerStartWaypoint()
    camPos = wp and vec3(wp.pos) or vec3(0, 0, 0)
  end

  -- Cache and return the result
  self._cachedCamPos = camPos
  return camPos
end

function C:setCachedLength(len)
  self._cachedLength = len
end

function C:invalidateCamPosCache()
  self._cachedCamPos = nil
end

function C:getCachedLength()
  return self._cachedLength
end

function C:generateFreeformFromStructured()
  local note = self:getNoteFieldFreeform()
  local distBefore = self:getNoteFieldBefore()
  local distAfter = self:getNoteFieldAfter()
  local compositor = self.notebook:getTextCompositor()
  local punc = ''

  local varEscapedStructured = compositor:compositeTextEscaped(self.structured, distBefore, distAfter)
  local generatedFreeform = table.concat(varEscapedStructured, ' ')

  local varEscapedFreeform = _noteOutputFreeformWithVarsHelper(note, distBefore, distAfter)

  local specialBefore = ''
  local specialAfter = ''
  if rallyUtil.useNote(distBefore) then
    specialBefore = rallyUtil.var_db
  end
  if rallyUtil.useNote(distAfter) then
    specialAfter = rallyUtil.var_da
  end

  varEscapedFreeform = _interpolateFreeformVars(varEscapedFreeform, specialBefore, specialAfter, punc)

  -- if no custom var placement, then remove them.
  if varEscapedFreeform == generatedFreeform then
    generatedFreeform = string.gsub(generatedFreeform, rallyUtil.var_db, '')
    generatedFreeform = string.gsub(generatedFreeform, rallyUtil.var_da, '')
    generatedFreeform = rallyUtil.trimString(generatedFreeform)
  end

  self:setNoteFieldFreeform(generatedFreeform)
end

function C:canDeleteAudioFiles()
  return self:getAudioMode() == RallyEnums.pacenoteAudioMode.structuredOnline or
         self:getAudioMode() == RallyEnums.pacenoteAudioMode.freeform
end

function C:deleteAudioFiles()
  if not self:canDeleteAudioFiles() then return end
  if self:getAudioMode() == RallyEnums.pacenoteAudioMode.structuredOnline then
    local fnames = self:audioFnamesStructuredOnline()
    for _,fname in ipairs(fnames) do
      FS:removeFile(fname)
      log('I', logTag, 'deleted StructuredOnline audio file: '..fname)
    end
  elseif self:getAudioMode() == RallyEnums.pacenoteAudioMode.freeform then
    local fnameFreeform = self:audioFnameFreeform()
    FS:removeFile(fnameFreeform)
    log('I', logTag, 'deleted Freeform audio file: '..fnameFreeform)
  end
end

function C:deleteLanguage(lang)
  self.notes[lang] = nil
end

function C:customAudioFileDir()
  return self.notebook:customPacenotesAudioDir()
end

-- ---------------------------------------------------------------------------
-- structured items: ordered output view
-- ---------------------------------------------------------------------------

function C:items()
  return self.structured:orderedItems()
end

function C:findItem(itemType)
  for _, item in ipairs(self:items()) do
    if item.type == itemType then
      return item
    end
  end
  return nil
end

function C:findItems(itemType)
  local out = {}
  for _, item in ipairs(self:items()) do
    if item.type == itemType then
      table.insert(out, item)
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- structured items: slot-view convenience
-- The structured form maps directly to fixed structured slots:
-- 1 = caution, 2/3 = pre modifiers, 4 = corner, 5/6 = post modifiers.
-- ---------------------------------------------------------------------------

function C:caution()
  local item = Structured.slotItem(self.structured, 1)
  if item and item.type == 'caution' then return item end
  return nil
end

function C:cautionLevel()
  local c = self:caution()
  return c and c.level or nil
end

function C:hasCorner()
  return self:corner() ~= nil
end

function C:corner()
  local item = Structured.slotItem(self.structured, 4)
  if item and item.type == 'corner' then return item end
  return nil
end

function C:hasModifier(itemType)
  return self:findItem(itemType) ~= nil
end

function C:applyMeasurements()
  -- Measurements are runtime projection data now; applying them only refreshes
  -- rendered text/preview and must not mutate canonical structured.items.
  self:refreshStructured()
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
