-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Stateless module of voicepack-related helpers: file paths, info parsing, scanning,
-- inventory caching, settings-backed preferences, resolution, picker entry building,
-- and pretty labels. No instances, no editor state. Imports rallyUtil only for
-- shared filename/metadata helpers.

local logTag = 'rally.voicepack'

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local audioTiming = require('/lua/ge/extensions/gameplay/rally/audioTiming')

local M = {}

-- constants -----------------------------------------------------------------

-- not 'info.json' to avoid clashing with the BeamNG missions system, which scans
-- /gameplay/missions/**/info.json and treats anything it finds as a mission.
M.infoBasename  = 'voicepack.json'
M.audioSubdir   = 'audio'
M.globalDir     = '/lua/ge/extensions/gameplay/rally/compositors/voicepacks/'
M.missionSubdir = 'rally/voicepacks'
M.defaultVoicepackId = 'mission:pro'
M.mruLimit = 10

local settingsKeys = {
  voicepackMRU = 'rallyCodriverVoicepackMRU',
}

-- file paths for a voicepack directory name --------------------------------

function M.getFile(voicepack, basename)
  return string.format('%s%s/%s', M.globalDir, voicepack, basename)
end

function M.getAudioFile(voicepack, basename)
  return M.getFile(voicepack, M.audioSubdir..'/'..basename)
end

local function entryAudioFile(entry, basename)
  return entry.dir..'/'..M.audioSubdir..'/'..basename
end

function M.getEntryAudioFile(entry, basename)
  if not entry or not basename then return nil end

  local localFname = entryAudioFile(entry, basename)
  if FS:fileExists(localFname) then return localFname end

  local firstSourceFname = nil
  for _, sourceEntry in ipairs(M.getEntryAudioSourceEntries(entry)) do
    local sourceFname = entryAudioFile(sourceEntry, basename)
    firstSourceFname = firstSourceFname or sourceFname
    if FS:fileExists(sourceFname) then return sourceFname end
  end

  if FS:directoryExists(entry.dir..'/'..M.audioSubdir) then
    return localFname
  end
  return firstSourceFname or localFname
end

local function audioStem(basename)
  return (basename or ''):gsub("%.ogg$", "")
end

local audioCandidateIndexes = setmetatable({}, { __mode = 'k' })

local function addIndexedCandidate(index, stem, basename, metadataEntry, variantIndex)
  local candidates = index[stem]
  if not candidates then
    candidates = {}
    index[stem] = candidates
  end
  table.insert(candidates, {
    basename = basename,
    metadata = metadataEntry,
    variantIndex = variantIndex,
  })
end

local function getAudioCandidateIndex(metadata)
  local cached = audioCandidateIndexes[metadata]
  if cached then return cached end

  local index = {}
  for basename, metadataEntry in pairs(metadata) do
    if type(basename) == 'string' and type(metadataEntry) == 'table' and basename:match("%.ogg$") then
      addIndexedCandidate(index, audioStem(basename), basename, metadataEntry, 1)

      local numberedStem, variantIndex = basename:match("^(.*)_(%d+)%.ogg$")
      variantIndex = tonumber(variantIndex)
      if numberedStem and variantIndex and variantIndex > 0 then
        addIndexedCandidate(index, numberedStem, basename, metadataEntry, variantIndex)
      end
    end
  end

  for _, candidates in pairs(index) do
    table.sort(candidates, function(a, b)
      if a.variantIndex ~= b.variantIndex then
        return a.variantIndex < b.variantIndex
      end
      return a.basename < b.basename
    end)
  end

  audioCandidateIndexes[metadata] = index
  return index
end

local function normalizeAllowedVariants(allowedVariants)
  local out = {}
  local seen = {}
  if type(allowedVariants) == 'table' then
    for _, variant in ipairs(allowedVariants) do
      local variantIndex = tonumber(variant)
      if variantIndex and variantIndex > 0 then
        variantIndex = math.floor(variantIndex)
        if not seen[variantIndex] then
          seen[variantIndex] = true
          table.insert(out, variantIndex)
        end
      end
    end
  end
  table.sort(out)
  return out
end

local function variantBasenamesForStem(stem, variantIndex)
  local out = {}
  if variantIndex == 1 then
    table.insert(out, stem..'.ogg')
  end
  table.insert(out, stem..'_'..tostring(variantIndex)..'.ogg')
  return out
end

function M.getAudioCandidates(metadata, basename, pathForBasename, allowedVariants)
  local candidates = {}
  if type(metadata) ~= 'table' or not basename or basename == '' then return candidates end

  local function addCandidate(candidateBasename, metadataEntry, variantIndex)
    if type(metadataEntry) ~= 'table' then return end
    table.insert(candidates, {
      basename = candidateBasename,
      fname = pathForBasename and pathForBasename(candidateBasename) or candidateBasename,
      audioLen = metadataEntry.audioLen,
      metadata = metadataEntry,
      variantIndex = variantIndex,
    })
  end

  local stem = audioStem(basename)
  local allowed = normalizeAllowedVariants(allowedVariants)
  if #allowed == 0 then
    for _, candidate in ipairs(getAudioCandidateIndex(metadata)[stem] or {}) do
      addCandidate(candidate.basename, candidate.metadata, candidate.variantIndex)
    end
  else
    local seenBasenames = {}
    for _, variantIndex in ipairs(allowed) do
      for _, candidateBasename in ipairs(variantBasenamesForStem(stem, variantIndex)) do
        if not seenBasenames[candidateBasename] then
          seenBasenames[candidateBasename] = true
          addCandidate(candidateBasename, metadata[candidateBasename], variantIndex)
        end
      end
    end
  end

  table.sort(candidates, function(a, b)
    if (a.variantIndex or 0) ~= (b.variantIndex or 0) then
      return (a.variantIndex or 0) < (b.variantIndex or 0)
    end
    return (a.basename or '') < (b.basename or '')
  end)

  return candidates
end

function M.getAudioCandidatesForEntry(entry, metadata, basename, allowedVariants)
  return M.getAudioCandidates(metadata, basename, function(candidateBasename)
    return M.getEntryAudioFile(entry, candidateBasename)
  end, allowedVariants)
end

function M.getAudioCandidatesForVoicepack(voicepack, metadata, basename, allowedVariants)
  return M.getAudioCandidates(metadata, basename, function(candidateBasename)
    return M.getAudioFile(voicepack, candidateBasename)
  end, allowedVariants)
end

function M.chooseAudioCandidate(candidates)
  if type(candidates) ~= 'table' or #candidates == 0 then return nil end
  return candidates[math.random(#candidates)]
end

function M.getPacenoteFile(voicepack, pacenoteHash)
  return M.getAudioFile(voicepack, rallyUtil.makePacenoteAudioFilename(pacenoteHash))
end

function M.getSystemPacenoteFile(voicepack, systemKey, variantIndex)
  return M.getAudioFile(voicepack, rallyUtil.makeSystemPacenoteAudioFilename(systemKey, variantIndex))
end

function M.getEntrySystemPacenoteFile(entry, systemKey, variantIndex)
  return M.getEntryAudioFile(entry, rallyUtil.makeSystemPacenoteAudioFilename(systemKey, variantIndex))
end

function M.getMetadataFile(voicepack)
  return M.getFile(voicepack, rallyUtil.pacenotesMetadataBasename)
end

function M.getInfo(voicepack)
  local infoFname = M.getFile(voicepack, M.infoBasename)
  if FS:fileExists(infoFname) then
    return jsonReadFile(infoFname)
  end
  return nil
end

function M.getLanguage(voicepack)
  local info = M.getInfo(voicepack)
  if info and info.language then return info.language end
  return nil
end

function M.getStyles(voicepack)
  local info = M.getInfo(voicepack)
  if info and info.styles then return info.styles end
  return {}
end

-- index / cache -------------------------------------------------------------

local voicepackIndex = nil
local missionVoicepackIndex = {}

-- Dev/test hook only. Normal preference changes and picker changes must not invalidate this;
-- the expensive directory scan should run once per Lua/module reload unless the toolbox asks
-- for an explicit refresh after content files changed.
function M.invalidateCache()
  voicepackIndex = nil
end

local function missionCacheKey(missionDir, missionId)
  if not missionDir then return nil end
  return tostring(missionDir)..'|'..tostring(missionId or '')
end

function M.invalidateMissionCache(missionDir)
  if missionDir then
    local prefix = tostring(missionDir)..'|'
    for key, _ in pairs(missionVoicepackIndex) do
      if key == missionDir or string.startswith(key, prefix) then
        missionVoicepackIndex[key] = nil
      end
    end
  else
    missionVoicepackIndex = {}
  end
end

-- ids / setting helpers -----------------------------------------------------

function M.makeId(scope, dirname, missionId)
  if scope == 'mission' then
    return missionId and ('mission:'..tostring(missionId)..':'..tostring(dirname)) or ('mission:'..tostring(dirname))
  end
  return 'global:'..tostring(dirname)
end

function M.parseId(id)
  if type(id) ~= 'string' then return nil end
  local scope, rest = id:match('^([^:]+):(.+)$')
  if scope == 'global' then
    return { scope = 'global', dirname = rest }
  end
  if scope == 'mission' then
    local missionId, dirname = rest:match('^([^:]+):(.+)$')
    if dirname then
      return { scope = 'mission', missionId = missionId, dirname = dirname }
    end
    return { scope = 'mission', dirname = rest }
  end
  return nil
end

local function decodeJsonList(raw)
  if type(raw) ~= 'string' or raw == '' then return {} end
  local ok, decoded = pcall(json.decode, raw)
  if ok and type(decoded) == 'table' then return decoded end
  return {}
end

local function getJsonListSetting(key)
  if not settings or not settings.getValue then return {} end
  return decodeJsonList(settings.getValue(key))
end

local function splitCsvList(raw)
  local out = {}
  if type(raw) ~= 'string' or raw == '' then return out end
  -- Backwards-compatible read for rich JSON MRU values created by earlier WIP builds.
  if raw:sub(1, 1) == '[' then
    for _, item in ipairs(decodeJsonList(raw)) do
      if type(item) == 'string' and item ~= '' then
        table.insert(out, item)
      elseif type(item) == 'table' and item.id and item.id ~= '' then
        table.insert(out, item.id)
      end
    end
    return out
  end
  for item in raw:gmatch('[^,]+') do
    if item ~= '' then table.insert(out, item) end
  end
  return out
end

local function setCsvListSetting(key, list)
  if settings and settings.setValue then
    settings.setValue(key, table.concat(list or {}, ','))
  end
end

function M.getVoicepackMRU()
  if not settings or not settings.getValue then return {} end
  return splitCsvList(settings.getValue(settingsKeys.voicepackMRU))
end

local function normalizeMruEntry(item)
  if type(item) == 'string' then
    local parsed = M.parseId(item) or {}
    parsed.id = item
    return parsed
  end
  if type(item) == 'table' then
    if item.id then
      local parsed = M.parseId(item.id)
      if parsed then
        item.scope = item.scope or parsed.scope
        item.dirname = item.dirname or parsed.dirname
        item.missionId = item.missionId or parsed.missionId
      end
    end
    return item
  end
  return nil
end

-- entry parsing -------------------------------------------------------------

local function normalizeReuseAudioFrom(value)
  local out = {}
  if type(value) == 'string' then value = { value } end
  if type(value) ~= 'table' then return out end
  for _, dirname in ipairs(value) do
    if type(dirname) == 'string' then
      dirname = dirname:gsub("^%s+", ""):gsub("%s+$", "")
      if dirname ~= '' then table.insert(out, dirname) end
    end
  end
  return out
end

local function readInfoEntry(infoFname, vpDir, scope, dirname, missionId, missionDir)
  if not FS:fileExists(infoFname) then return nil end
  local info = jsonReadFile(infoFname)
  if not (info and info.persona and info.language and info.styleLabel
          and type(info.notebooks) == 'table' and #info.notebooks > 0) then
    return nil
  end
  -- pre-translate display strings once at scan time so hot paths (picker labels,
  -- toolbox info block) can render without per-frame _tr calls.
  local styleLabelRaw = info.styleLabel
  local styleDetailLevel = tonumber(info.styleDetailLevel)
  local phraseGapMs = audioTiming.clampPhraseGapMs(info.phraseGapMs)
  local enableSpeedScaling = info.enableSpeedScaling
  if type(enableSpeedScaling) ~= 'boolean' then
    enableSpeedScaling = scope == 'global'
  end
  local codriverTimingOffsetSeconds = tonumber(info.codriverTimingOffsetSeconds)
  if not codriverTimingOffsetSeconds then
    codriverTimingOffsetSeconds = scope == 'global' and 0 or 0.2
  end
  local entry = {
    id           = M.makeId(scope, dirname, missionId),
    localId      = M.makeId(scope, dirname),
    scope        = scope,
    dirname      = dirname,
    dir          = vpDir,
    rootDir      = vpDir,
    missionId    = missionId,
    missionDir   = missionDir,
    persona      = info.persona,
    language     = info.language,
    dialect      = info.dialect,
    -- optional compositor module path under compositors/styles/ (no .lua suffix). Present =
    -- text-generated pack; nil = pre-recorded pack (no text compositor).
    compositorStyle = info.compositorStyle,
    styleLabel   = info.styleLabel,
    styleDetailLevel = styleDetailLevel,
    enableAnimalCodrivers = info.enableAnimalCodrivers,
    enableSpeedScaling = enableSpeedScaling,
    codriverTimingOffsetSeconds = codriverTimingOffsetSeconds,
    personaTr    = _tr(info.persona, info.persona),
    languageTr   = _tr(info.language, info.language),
    dialectTr    = (info.dialect and info.dialect ~= '') and _tr(info.dialect, info.dialect) or nil,
    styleLabelTr = _tr(styleLabelRaw, styleLabelRaw),
    -- required ordered list of notebook basenames (no .notebook.json suffix), in preference order.
    notebooks    = info.notebooks,
    -- Optional ordered list of global voicepack dirnames to reuse audio/metadata from.
    reuseAudioFrom = normalizeReuseAudioFrom(info.reuseAudioFrom),
    cornerGapMs = audioTiming.clampCornerGapMs(info.cornerGapMs),
    phraseGapMs = phraseGapMs,
    linkWordGapMs = audioTiming.clampLinkWordGapMs(info.linkWordGapMs ~= nil and info.linkWordGapMs or phraseGapMs),
    pacenoteGapMs = audioTiming.clampPacenoteGapMs(info.pacenoteGapMs),
  }
  entry.label = M.labelForEntry(entry, dirname, scope == 'mission' and '(mission)' or nil)
  return entry
end

local function isValidGlobalSourceDirname(dirname)
  return type(dirname) == 'string'
     and dirname ~= ''
     and dirname ~= '.'
     and dirname ~= '..'
     and not dirname:find('/', 1, true)
     and not dirname:find('\\', 1, true)
     and not dirname:find(':', 1, true)
end

local function readGlobalInfoEntry(dirname)
  if not isValidGlobalSourceDirname(dirname) then
    return nil, 'invalid global voicepack dirname'
  end
  local vpDir = M.globalDir..dirname
  if not FS:directoryExists(vpDir) then
    return nil, 'global voicepack dir does not exist'
  end
  local entry = readInfoEntry(vpDir..'/'..M.infoBasename, vpDir, 'global', dirname)
  if not entry then
    return nil, 'missing or invalid voicepack.json'
  end
  return entry
end

function M.getEntryAudioSourceEntries(entry)
  if not entry then return {} end
  if entry.audioSourceEntries ~= nil then return entry.audioSourceEntries end

  local out = {}
  local seen = {}
  if entry.scope == 'global' and entry.dirname then
    seen[entry.dirname] = true
  end

  for _, dirname in ipairs(entry.reuseAudioFrom or {}) do
    if seen[dirname] then
      log('W', logTag, 'skipping duplicate/self reuseAudioFrom entry: '..tostring(dirname))
    else
      local sourceEntry, reason = readGlobalInfoEntry(dirname)
      if sourceEntry then
        table.insert(out, sourceEntry)
        seen[dirname] = true
      else
        log('W', logTag, 'skipping invalid reuseAudioFrom entry "'..tostring(dirname)..'": '..tostring(reason))
      end
    end
  end

  entry.audioSourceEntries = out
  return out
end

function M.getEntryAssetDirs(entry)
  local out = {}
  if not entry then return out end
  table.insert(out, entry.dir)
  for _, sourceEntry in ipairs(M.getEntryAudioSourceEntries(entry)) do
    table.insert(out, sourceEntry.dir)
  end
  return out
end

function M.getEntryMetadataFile(entry)
  if not entry then return nil end
  local localFname = entry.dir..'/'..rallyUtil.pacenotesMetadataBasename
  if FS:fileExists(localFname) then return localFname end

  local firstSourceFname = nil
  for _, sourceEntry in ipairs(M.getEntryAudioSourceEntries(entry)) do
    local sourceFname = sourceEntry.dir..'/'..rallyUtil.pacenotesMetadataBasename
    firstSourceFname = firstSourceFname or sourceFname
    if FS:fileExists(sourceFname) then return sourceFname end
  end
  return firstSourceFname or localFname
end

function M.getEntryMetadata(entry)
  if not entry then return {} end
  if entry._mergedAudioMetadata then return entry._mergedAudioMetadata end

  local merged = {}
  local function mergeMetadata(assetEntry)
    local fname = assetEntry.dir..'/'..rallyUtil.pacenotesMetadataBasename
    if not FS:fileExists(fname) then return end
    local metadata = jsonReadFile(fname)
    if type(metadata) ~= 'table' then return end
    for basename, metadataEntry in pairs(metadata) do
      if merged[basename] == nil then
        merged[basename] = metadataEntry
      end
    end
  end

  mergeMetadata(entry)
  for _, sourceEntry in ipairs(M.getEntryAudioSourceEntries(entry)) do
    mergeMetadata(sourceEntry)
  end

  entry._mergedAudioMetadata = merged
  return merged
end

function M.scan()
  if voicepackIndex ~= nil then
    return voicepackIndex
  end
  local index = {}
  local voiceDirs = FS:directoryList(M.globalDir, false, true) or {}
  for _, voiceDir in ipairs(voiceDirs) do
    local _, voiceName, _ = path.split(voiceDir)
    -- hide voicepacks with leading underscore
    if voiceName and not voiceName:match("^_") then
      local vpDir = M.globalDir..voiceName
      local entry = readInfoEntry(vpDir..'/'..M.infoBasename, vpDir, 'global', voiceName)
      if entry then index[voiceName] = entry end
    end
  end
  voicepackIndex = index
  return voicepackIndex
end

function M.missionFullDir(missionDir)
  if not missionDir then return nil end
  return missionDir..'/'..M.missionSubdir
end

function M.scanMission(missionDir, missionId)
  if not missionDir then return {} end
  local cacheKey = missionCacheKey(missionDir, missionId)
  if missionVoicepackIndex[cacheKey] ~= nil then
    return missionVoicepackIndex[cacheKey]
  end
  local index = {}
  local root = M.missionFullDir(missionDir)
  if root and FS:directoryExists(root) then
    local voiceDirs = FS:directoryList(root, false, true) or {}
    for _, voiceDir in ipairs(voiceDirs) do
      local _, voiceName, _ = path.split(voiceDir)
      if voiceName and not voiceName:match("^_") then
        local vpDir = root..'/'..voiceName
        local entry = readInfoEntry(vpDir..'/'..M.infoBasename, vpDir, 'mission', voiceName, missionId, missionDir)
        if entry then index[voiceName] = entry end
      end
    end
  end
  missionVoicepackIndex[cacheKey] = index
  return index
end

-- resolution ----------------------------------------------------------------

local function pickToParts(pick)
  if not pick then return nil end
  if type(pick) == 'string' then
    return M.parseId(pick)
  end
  if pick.id then
    local parsed = M.parseId(pick.id)
    if parsed then
      parsed.type = pick.type
      return parsed
    end
  end
  return {
    type = pick.type,
    scope = pick.scope,
    missionId = pick.missionId,
    dirname = pick.dirname,
  }
end

-- Returns (entry, dirname) for the given pick. Mission-scope picks resolve from the
-- mission-local voicepack index; everything else from the global index.
function M.resolveEntry(missionDir, pick, missionId)
  local parts = pickToParts(pick)
  if not parts or not parts.dirname then return nil, nil end
  if parts.scope == 'mission' then
    if parts.missionId and missionId and parts.missionId ~= missionId then return nil, nil end
    local entry = M.scanMission(missionDir, missionId or parts.missionId)[parts.dirname]
    if entry then return entry, parts.dirname end
    return nil, nil
  end
  local entry = M.scan()[parts.dirname]
  if entry then return entry, parts.dirname end
  return nil, nil
end

-- Returns (dirname, entry) for the first voicepack matching the given (language, persona,
-- styleLabel) keys. Any of the args may be nil, in which case the first match wins.
function M.resolveDir(language, persona, styleLabel)
  local index = M.scan()
  for dirname, entry in pairs(index) do
    if (not language   or entry.language   == language)
   and (not persona    or entry.persona    == persona)
   and (not styleLabel or entry.styleLabel == styleLabel) then
      return dirname, entry
    end
  end
  return nil, nil
end

function M.listInventory(missionDir, opts)
  opts = opts or {}
  local entries = {}
  for _, entry in pairs(M.scan() or {}) do
    if entry.enableAnimalCodrivers ~= false then
      table.insert(entries, entry)
    end
  end
  if missionDir and not opts.globalOnly then
    for _, entry in pairs(M.scanMission(missionDir, opts.missionId) or {}) do
      if entry.enableAnimalCodrivers ~= false then
        table.insert(entries, entry)
      end
    end
  end
  if missionDir and opts.requireMissionNotebook ~= false then
    local filtered = {}
    for _, entry in ipairs(entries) do
      if #M.listMissionNotebookCandidates(missionDir, entry) > 0 then
        table.insert(filtered, entry)
      end
    end
    entries = filtered
  end
  table.sort(entries, function(a, b)
    return (a.label or a.id or '') < (b.label or b.id or '')
  end)
  return entries
end

local function notebookCandidates(vpInfo)
  if vpInfo and type(vpInfo.notebooks) == 'table' then
    return vpInfo.notebooks
  end
  return {}
end

-- Resolves which notebook file in the given mission to use, based on the active voicepack info.
--
-- The voicepack info.json declares a required "notebooks" array of basenames (no .notebook.json
-- suffix), in preference order.
--
-- Returns the absolute path to the first existing <missionDir>/rally/notebooks/<name>.notebook.json,
-- or nil if none of the candidates exist.
function M.resolveMissionNotebook(missionDir, vpInfo)
  if not missionDir then return nil end
  for _, name in ipairs(notebookCandidates(vpInfo)) do
    if name and name ~= '' then
      local full = missionDir..'/'..rallyUtil.notebooksPath..'/'..name..'.notebook.json'
      if FS:fileExists(full) then return full end
    end
  end
  return nil
end

-- Like resolveMissionNotebook, but returns the full ordered list of candidate basenames whose
-- .notebook.json actually exists in the mission. Used by the rally editor's notebook dropdown
-- to show all loadable notebooks for the chosen voicepack (not just the first one).
function M.listMissionNotebookCandidates(missionDir, vpInfo)
  if not missionDir then return {} end
  local out = {}
  for _, name in ipairs(notebookCandidates(vpInfo)) do
    if name and name ~= '' then
      local full = missionDir..'/'..rallyUtil.notebooksPath..'/'..name..'.notebook.json'
      if FS:fileExists(full) then table.insert(out, name) end
    end
  end
  return out
end

-- picks / picker entries ----------------------------------------------------

-- Pretty label for a voicepack info entry, suitable for display in picker dropdowns.
-- Format: "<persona> [(<dialect>)] - <style>[ <suffix>]". Falls back to dirname/style basename
-- when fields are missing.
function M.labelForEntry(entry, dirname, suffix)
  local persona = entry.personaTr or dirname
  local style   = entry.styleLabelTr or (entry.compositorStyle or '?')
  local label   = entry.dialectTr
    and (persona..' ('..entry.dialectTr..') - '..style)
    or  (persona..' - '..style)
  if suffix then label = label..' '..suffix end
  return label
end

function M.ensureSettingsInitialized(opts)
  opts = opts or {}
  if opts.writeSettings == false then return end
  if not settings or not settings.getValue or not settings.setValue then return end

  local mru = M.getVoicepackMRU()
  if #mru == 0 then
    setCsvListSetting(settingsKeys.voicepackMRU, { M.defaultVoicepackId })
  end
end

local function mruMatchesEntry(mru, entry, matchMode)
  if not mru or not entry then return false end
  if matchMode == 'exact' then
    return mru.id and mru.id == entry.id
  end
  if matchMode == 'portableDirname' then
    return mru.scope == entry.scope and mru.dirname and mru.dirname == entry.dirname
  end
  return false
end

local function sortForPreferences(candidates)
  table.sort(candidates, function(a, b)
    local aDetail = a.styleDetailLevel or 9999
    local bDetail = b.styleDetailLevel or 9999
    if aDetail ~= bDetail then return aDetail < bDetail end

    return (a.label or a.id or '') < (b.label or b.id or '')
  end)
end

local function resolveFromPreferences(candidates, opts)
  M.ensureSettingsInitialized(opts)

  local filtered = candidates or {}
  if #filtered == 0 then
    return nil, {
      mode = 'preferences',
      reason = 'No compatible voicepacks',
      candidates = candidates,
    }
  end

  -- Single pass in MRU order so list position wins: for each MRU entry, prefer an
  -- exact id match, else a portableDirname (scope+dirname) match, before moving on to
  -- the next (lower-priority) MRU entry. This ensures a dirname match earlier in the
  -- list beats an exact match later in the list.
  local mru = M.getVoicepackMRU()
  for _, raw in ipairs(mru) do
    local normalized = normalizeMruEntry(raw)
    local exactEntry, dirnameEntry = nil, nil
    for _, entry in ipairs(filtered) do
      if not exactEntry and mruMatchesEntry(normalized, entry, 'exact') then
        exactEntry = entry
      elseif not dirnameEntry and mruMatchesEntry(normalized, entry, 'portableDirname') then
        dirnameEntry = entry
      end
    end
    if exactEntry then
      return exactEntry, {
        mode = 'preferences',
        reason = 'MRU exact match',
        matchedMRU = normalized,
        candidates = filtered,
      }
    end
    if dirnameEntry then
      return dirnameEntry, {
        mode = 'preferences',
        reason = 'MRU dirname match',
        matchedMRU = normalized,
        candidates = filtered,
      }
    end
  end
  sortForPreferences(filtered)
  return filtered[1], {
    mode = 'preferences',
    reason = 'Detail fallback',
    candidates = filtered,
  }
end

function M.resolve(missionDir, pick, opts)
  opts = opts or {}
  local candidates = M.listInventory(missionDir, {
    missionId = opts.missionId,
    globalOnly = opts.globalOnly,
    requireMissionNotebook = opts.requireMissionNotebook,
  })

  if pick and pick.type == 'voicepack' then
    local exactEntry = nil
    for _, entry in ipairs(candidates) do
      if M.picksMatch({ type = 'voicepack', id = entry.id, scope = entry.scope, dirname = entry.dirname, missionId = entry.missionId }, pick) then
        exactEntry = entry
        break
      end
    end
    if exactEntry then
      return {
        entry = exactEntry,
        dirname = exactEntry.dirname,
        reason = 'Exact pick',
        mode = 'exact',
        candidates = candidates,
      }
    end
    local fallbackEntry, detail = resolveFromPreferences(candidates, opts)
    detail.invalidPick = pick
    detail.reason = 'Exact pick unavailable; using preferences fallback'
    return {
      entry = fallbackEntry,
      dirname = fallbackEntry and fallbackEntry.dirname or nil,
      reason = detail.reason,
      mode = 'invalidExactFallback',
      detail = detail,
      candidates = candidates,
    }
  end

  local entry, detail = resolveFromPreferences(candidates, opts)
  return {
    entry = entry,
    dirname = entry and entry.dirname or nil,
    reason = detail.reason,
    mode = 'preferences',
    detail = detail,
    candidates = candidates,
  }
end

-- Backwards-compatible cascade accessors. Existing callers can keep using the old
-- tuple shape while the resolver itself is now preference/MRU based.
function M.getCascadeKeys()
  local entry = (M.resolve(nil, { type = 'preferences' }, { globalOnly = true }) or {}).entry
  if not entry then return nil, nil, nil end
  return entry.language, entry.persona, entry.styleLabel
end

-- Resolves a pick into (dirname, entry, result):
--   pick.type == 'voicepack' -> exact pick, visible fallback if invalid
--   pick nil/preferences/auto -> accepted-language/MRU preference resolver
-- Returns (nil, nil, result) when nothing resolves.
function M.resolveEffectiveEntry(missionDir, pick, opts)
  opts = opts or {}
  if pick and pick.type == 'auto' then pick = { type = 'preferences' } end
  local result = M.resolve(missionDir, pick or { type = 'preferences' }, opts)
  return result.dirname, result.entry, result
end

-- Builds picker entries for a mission. Returns an array of { label, pick }.
-- Filter: a voicepack appears iff at least one of its candidate notebooks resolves in this mission.
-- opts:
--   includePreferences = true -> prepends the auto/settings entry.
--   missionSuffix          -> string appended to mission-scoped voicepack labels (default '(mission)')
function M.buildPickerEntries(missionDir, opts)
  opts = opts or {}
  M.ensureSettingsInitialized(opts)
  local entries = {}
  if opts.includePreferences or opts.includeAuto then
    table.insert(entries, { label = 'Resolve from Settings', pick = { type = 'preferences' } })
  end
  local missionSuffix = opts.missionSuffix or '(mission)'
  for _, entry in ipairs(M.listInventory(missionDir, {
    missionId = opts.missionId,
    globalOnly = opts.globalOnly,
    requireMissionNotebook = opts.requireMissionNotebook,
  })) do
    local suffix = entry.scope == 'mission' and missionSuffix or nil
    table.insert(entries, {
      label = M.labelForEntry(entry, entry.dirname, suffix),
      entry = entry,
      pick  = { type = 'voicepack', id = entry.id, scope = entry.scope, missionId = entry.missionId, dirname = entry.dirname },
    })
  end
  return entries
end

local function optionShortLabel(entry)
  if not entry then return nil end
  local persona = entry.personaTr or entry.persona or entry.dirname
  local style = entry.styleLabelTr or entry.compositorStyle or entry.dirname
  return persona..' - '..style
end

local function optionDetail(entry)
  if not entry then return nil end
  local parts = {}
  table.insert(parts, entry.dialectTr or entry.languageTr)
  return table.concat(parts, ' - ')
end

local function familyKeyPart(value)
  value = tostring(value or '')
  return value:gsub("\\", "\\\\"):gsub("|", "\\p")
end

local function reuseAudioFromKey(entry)
  return table.concat(entry.reuseAudioFrom or {}, ',')
end

local function loopFamilyKeyForEntry(entry)
  if not entry then return nil end
  if entry.scope == 'global' then
    return table.concat({ 'global', familyKeyPart(entry.dirname) }, '|')
  end
  return table.concat({
    'mission',
    familyKeyPart(entry.dirname),
    familyKeyPart(entry.persona),
    familyKeyPart(entry.language),
    familyKeyPart(entry.dialect),
    familyKeyPart(entry.compositorStyle),
    familyKeyPart(entry.styleLabel),
    familyKeyPart(reuseAudioFromKey(entry)),
  }, '|')
end

local function loopSettingValueForFamilyKey(familyKey)
  return familyKey and ('loop:'..familyKey) or ''
end

local function extractMissionId(value)
  if not value or value == '' or value == '<none>' then return nil end
  return value:match("%((.+)%)$") or value
end

local function getLoopStageMissions(missionTypeData)
  local stageMissions = {}
  if not missionTypeData or not gameplay_missions_missions then return stageMissions end
  for i = 1, 4 do
    local missionId = extractMissionId(missionTypeData['stage'..i..'_rallyStage'])
    local mission = missionId and gameplay_missions_missions.getMissionById(missionId) or nil
    if mission and mission.missionFolder and (not mission.missionType or mission.missionType == 'rallyStage') then
      table.insert(stageMissions, mission)
    end
  end
  return stageMissions
end

local function sortedEntriesFromIndex(index)
  local entries = {}
  for _, entry in pairs(index or {}) do
    if entry.enableAnimalCodrivers ~= false then
      table.insert(entries, entry)
    end
  end
  table.sort(entries, function(a, b)
    return (a.label or a.id or '') < (b.label or b.id or '')
  end)
  return entries
end

local function concretePickForEntry(entry)
  if not entry then return nil end
  return {
    type = 'voicepack',
    id = entry.id,
    scope = entry.scope,
    missionId = entry.missionId,
    dirname = entry.dirname,
  }
end

local function findMissionEntryByLoopFamily(missionDir, missionId, familyKey)
  if not missionDir or not familyKey then return nil end
  for _, entry in ipairs(sortedEntriesFromIndex(M.scanMission(missionDir, missionId))) do
    if loopFamilyKeyForEntry(entry) == familyKey then
      return entry
    end
  end
  return nil
end

local function buildLoopVoicepackEntries(missionTypeData)
  M.ensureSettingsInitialized()
  local entries = {}

  for _, entry in ipairs(sortedEntriesFromIndex(M.scan())) do
    table.insert(entries, {
      label = M.labelForEntry(entry, entry.dirname),
      entry = entry,
      pick = concretePickForEntry(entry),
    })
  end

  local stageMissions = getLoopStageMissions(missionTypeData)
  if #stageMissions == 0 then return entries end

  local missionFamilies = nil
  for stageIndex, mission in ipairs(stageMissions) do
    local stageFamilies = {}
    for _, entry in ipairs(sortedEntriesFromIndex(M.scanMission(mission.missionFolder, mission.id))) do
      local familyKey = loopFamilyKeyForEntry(entry)
      if familyKey and not stageFamilies[familyKey] then
        stageFamilies[familyKey] = entry
      end
    end

    if stageIndex == 1 then
      missionFamilies = {}
      for familyKey, entry in pairs(stageFamilies) do
        missionFamilies[familyKey] = {
          label = M.labelForEntry(entry, entry.dirname, '(mission)'),
          entry = entry,
          familyKey = familyKey,
        }
      end
    else
      for familyKey, family in pairs(missionFamilies) do
        if stageFamilies[familyKey] then
          family.entry = family.entry or stageFamilies[familyKey]
        else
          missionFamilies[familyKey] = nil
        end
      end
    end
  end

  for _, family in pairs(missionFamilies or {}) do
    table.insert(entries, {
      label = family.label,
      entry = family.entry,
      pick = { type = 'loopVoicepack', familyKey = family.familyKey },
    })
  end

  table.sort(entries, function(a, b)
    return (a.label or '') < (b.label or '')
  end)
  return entries
end

function M.resolveLoopVoicepackPick(missionDir, missionId, value)
  local pick = M.pickFromSettingValue(value)
  if not pick or pick.type == 'preferences' then return nil end
  if pick.type == 'voicepack' then return pick end
  if pick.type ~= 'loopVoicepack' then return nil end

  local entry = findMissionEntryByLoopFamily(missionDir, missionId, pick.familyKey)
  return concretePickForEntry(entry)
end

function M.addLoopMissionSettingToMRU(missionTypeData, value)
  local pick = M.pickFromSettingValue(value)
  if not pick or pick.type == 'preferences' then return end
  if pick.type == 'voicepack' then
    M.addToMRU(pick)
    return
  end
  if pick.type ~= 'loopVoicepack' then return end

  for _, mission in ipairs(getLoopStageMissions(missionTypeData)) do
    local resolvedPick = M.resolveLoopVoicepackPick(mission.missionFolder, mission.id, value)
    if resolvedPick then
      M.addToMRU(resolvedPick, mission.missionFolder, mission.id)
      return
    end
  end
end

local function loopEntryMatchesMRU(loopEntry, normalizedMRU)
  return mruMatchesEntry(normalizedMRU, loopEntry.entry, 'exact')
      or mruMatchesEntry(normalizedMRU, loopEntry.entry, 'portableDirname')
end

function M.buildLoopMissionUserSetting(missionTypeData, currentValue)
  local entries = buildLoopVoicepackEntries(missionTypeData)
  if #entries == 0 then return nil end

  local values = {}
  local currentOption = nil
  local value = currentValue or ''
  for _, loopEntry in ipairs(entries) do
    local optionValue = M.settingValueForPick(loopEntry.pick)
    local option = {
      l = loopEntry.label,
      v = optionValue,
      shortLabel = optionShortLabel(loopEntry.entry),
      detail = optionDetail(loopEntry.entry),
    }
    table.insert(values, option)
    if optionValue == value then currentOption = option end
  end

  if not currentOption then
    for _, raw in ipairs(M.getVoicepackMRU()) do
      local normalized = normalizeMruEntry(raw)
      for index, loopEntry in ipairs(entries) do
        if loopEntryMatchesMRU(loopEntry, normalized) then
          currentOption = values[index]
          break
        end
      end
      if currentOption then break end
    end
  end

  currentOption = currentOption or values[1]

  return {
    key = 'rallyVoicepackPick',
    label = 'ui.options.rally.textCompositor.voice',
    type = 'select',
    values = values,
    value = currentOption.v,
    currentOption = currentOption,
  }
end

-- Returns the ordered list of notebook basenames (no .notebook.json suffix) loadable for the
-- pick in this mission. Empty list if pick is nil or has no matches.
function M.notebookBasenamesForPick(missionDir, pick)
  if not pick or not missionDir then return {} end
  if pick.type == 'voicepack' and pick.dirname then
    local entry = M.resolveEntry(missionDir, pick)
    if not entry then return {} end
    return M.listMissionNotebookCandidates(missionDir, entry)
  end
  return {}
end

function M.picksMatch(a, b)
  if not a or not b then return false end
  local aType = a.type == 'auto' and 'preferences' or a.type
  local bType = b.type == 'auto' and 'preferences' or b.type
  if aType ~= bType then return false end
  if aType == 'preferences' then return true end
  if a.id and b.id then return a.id == b.id end
  local aParts = pickToParts(a) or a
  local bParts = pickToParts(b) or b
  return aParts.dirname == bParts.dirname
     and (aParts.scope or 'global') == (bParts.scope or 'global')
     and (aParts.scope ~= 'mission' or not aParts.missionId or not bParts.missionId or aParts.missionId == bParts.missionId)
end

function M.addToMRU(entryOrPick, missionDir, missionId)
  if not entryOrPick then return end
  local entry = entryOrPick.id and entryOrPick.scope and entryOrPick.dirname and entryOrPick
  if not entry or not entry.language then
    entry = M.resolveEntry(missionDir, entryOrPick, missionId)
  end
  if not entry then return end

  local newId = entry.id
  local out = { newId }
  for _, raw in ipairs(M.getVoicepackMRU()) do
    if raw and raw ~= '' and raw ~= newId then
      table.insert(out, raw)
    end
    if #out >= M.mruLimit then break end
  end
  setCsvListSetting(settingsKeys.voicepackMRU, out)
end

function M.pickFromSettingValue(value)
  if not value or value == '' or value == 'preferences' or value == 'auto' then
    return { type = 'preferences' }
  end
  if type(value) == 'string' and value:sub(1, 5) == 'loop:' then
    return { type = 'loopVoicepack', familyKey = value:sub(6) }
  end
  local parsed = M.parseId(value)
  if parsed and parsed.dirname then
    return {
      type = 'voicepack',
      id = value,
      scope = parsed.scope,
      missionId = parsed.missionId,
      dirname = parsed.dirname,
    }
  end
  return { type = 'preferences' }
end

function M.settingValueForPick(pick)
  if not pick or pick.type == 'preferences' or pick.type == 'auto' then return '' end
  if pick.type == 'loopVoicepack' then return loopSettingValueForFamilyKey(pick.familyKey) end
  if pick.id then return pick.id end
  if pick.type == 'voicepack' then
    return M.makeId(pick.scope or 'global', pick.dirname, pick.missionId)
  end
  return ''
end

function M.buildMissionUserSetting(missionDir, missionId, currentValue)
  local entries = M.buildPickerEntries(missionDir, {
    missionId = missionId,
    missionSuffix = '(mission)',
  })
  if #entries == 0 then return nil end

  local values = {}
  local currentOption = nil
  local value = currentValue or ''
  for _, entry in ipairs(entries) do
    local optionValue = M.settingValueForPick(entry.pick)
    local option = {
      l = entry.label,
      v = optionValue,
      shortLabel = optionShortLabel(entry.entry),
      detail = optionDetail(entry.entry),
    }
    table.insert(values, option)
    if optionValue == value then currentOption = option end
  end

  if not currentOption then
    local _, resolvedEntry = M.resolveEffectiveEntry(missionDir, M.pickFromSettingValue(currentValue), { missionId = missionId })
    if resolvedEntry then
      local resolvedValue = M.settingValueForPick({
        type = 'voicepack',
        id = resolvedEntry.id,
        scope = resolvedEntry.scope,
        missionId = resolvedEntry.missionId,
        dirname = resolvedEntry.dirname,
      })
      for _, option in ipairs(values) do
        if option.v == resolvedValue then
          currentOption = option
          break
        end
      end
    end
  end
  currentOption = currentOption or values[1]

  return {
    key = 'rallyVoicepackPick',
    label = 'ui.options.rally.textCompositor.voice',
    type = 'select',
    values = values,
    value = currentOption.v,
    currentOption = currentOption,
  }
end

return M
