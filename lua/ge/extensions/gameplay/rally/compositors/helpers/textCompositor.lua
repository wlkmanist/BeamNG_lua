-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local voicepackMod = require('/lua/ge/extensions/gameplay/rally/voicepack')
local util = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/compositorUtil')
local styleValidator = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/styleValidator')
local calibrationOverrides = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/calibrationOverrides')

local logTag = ''

local C = {}

function C:init(compositorName, missionDir)
  if not compositorName then
    log('E', logTag, 'compositorName is nil')
  end
  self.compositorName = compositorName
  self.missionDir = missionDir
  self.compositor = nil
  self.cachedSystemPacenotes = {}
  self.voicepackEntry = nil
  self.voicepackEntryCacheKey = nil
end

function C:load()
  if FS:fileExists(self:compositorPath()..'.lua') then
    local compositor = deepcopy(self:_requireCompositor())
    if compositor then
      calibrationOverrides.applyToConfig(compositor, self.compositorName, self.missionDir)
    end
    if not styleValidator.validate(compositor, self.compositorName) then
      log('E', logTag, 'style failed validation: '..self.compositorName)
      self.compositor = nil
      return false
    end
    self.compositor = compositor
    self.cachedSystemPacenotes = {}
    return true
  else
    log('E', logTag, 'compositor not found: '..self.compositorName)
    return false
  end
end

local function voicepackEntryCacheKey(entry)
  if not entry then return '<none>' end
  return tostring(entry.id or entry.dir or entry.dirname or '<none>')
end

function C:setVoicepackEntry(entry)
  local cacheKey = voicepackEntryCacheKey(entry)
  if cacheKey ~= self.voicepackEntryCacheKey then
    self.cachedSystemPacenotes = {}
    self.voicepackEntryCacheKey = cacheKey
  end
  self.voicepackEntry = entry
end

function C:compositorPath()
  return '/lua/ge/extensions/gameplay/rally/compositors/styles/'..self.compositorName
end

function C:_requireCompositor()
  if not self.compositorName then return nil end
  local fname = self:compositorPath()
  return require(fname)
end

function C:compositeText(structured, distBefore, distAfter)
  if not self.compositor then return nil end
  return self.compositor.composite(self:getConfig(), structured, distBefore, distAfter)
end

function C:compositeTextEscaped(structured, distBefore, distAfter)
  if not self.compositor then return nil end
  return self.compositor.composite(self:getConfig(), structured, distBefore, distAfter, true)
end

function C:compositePhraseEntries(structured, distBefore, distAfter, opts)
  if not self.compositor then return nil end
  return util.compositePhraseEntries(self:getConfig(), structured, distBefore, distAfter, opts)
end

function C:getConfig()
  if not self.compositor then return nil end
  return self.compositor
end

function C:distanceCallsEnabled()
  if not self.compositor then return false end
  return util.distanceCallsEnabled(self:getConfig())
end

-- Returns the ordered { name, variants } array as authored by the style.
function C:getSystemPacenotesOrdered()
  if not self.compositor then return {} end
  return self.compositor.system or {}
end

-- Returns a `{ name -> variants[] }` map (each variant has audioFname filled in).
-- Iteration order via pairs() is undefined; use `getSystemPacenotesOrdered()` when
-- order matters (script reader, audio generation, etc.).
function C:getSystemPacenotes(missionPacenotesDirname, voicepackEntry)
  if not self.compositor then return nil end

  if voicepackEntry ~= nil then
    self:setVoicepackEntry(voicepackEntry)
  end

  -- set it to a <none> value to use as a cache key
  missionPacenotesDirname = missionPacenotesDirname or '<none>'

  if self.cachedSystemPacenotes[missionPacenotesDirname] then
    return self.cachedSystemPacenotes[missionPacenotesDirname]
  end

  local systemArray = deepcopy(self.compositor.system) or {}
  local activeVoicepackEntry = self.voicepackEntry
  local voicepack = nil
  if not activeVoicepackEntry then
    voicepack = voicepackMod.resolveDir(voicepackMod.getCascadeKeys())
  end

  local sysNotes = {}

  for _, entry in ipairs(systemArray) do
    local name = entry.name
    sysNotes[name] = {}
    for variantIndex, variant in ipairs(entry.variants or {}) do
      local basename = rallyUtil.makeSystemPacenoteAudioFilename(name, variantIndex)
      local pacenoteFname = nil
      if missionPacenotesDirname ~= '<none>' then
        pacenoteFname = missionPacenotesDirname..'/'..basename
      elseif activeVoicepackEntry then
        pacenoteFname = voicepackMod.getEntrySystemPacenoteFile(activeVoicepackEntry, name, variantIndex)
      elseif voicepack then
        pacenoteFname = voicepackMod.getSystemPacenoteFile(voicepack, name, variantIndex)
      end
      variant.audioFname = pacenoteFname
      variant.audioBasename = basename

      if pacenoteFname and not FS:fileExists(pacenoteFname) then
        log('D', logTag, "getSystemPacenotes: couldnt find file for static pacenote with name '"..name.."'")
      end
      table.insert(sysNotes[name], variant)
    end
  end

  self.cachedSystemPacenotes[missionPacenotesDirname] = sysNotes
  return self.cachedSystemPacenotes[missionPacenotesDirname]
end

function C:getSystemPacenote(name, i)
  if not self.compositor then return nil end
  i = i or 1 -- default to the first variant
  local sys = self:getSystemPacenotes()
  return sys[name][i]
end

function C:enumerateDistanceEntries()
  if not self:distanceCallsEnabled() then return {} end

  local min = self:getMaxLinkDistance()
  local max = self:getMaxDistance()
  local step = self:getRoundingSmall()

  -- print(string.format("Enumerating from %d to %d with step %d", self.min, self.max, self.step))
  local out = {}
  for n = min, max, step do
    local distStr = self:distanceToString(n)
    out[distStr] = n
  end

  local compacted = {}
  for distStr,n in pairs(out) do
    compacted[n] = distStr
  end

  local keys = {}
  for k in pairs(compacted) do table.insert(keys, k) end
  table.sort(keys)

  local sorted = {}
  for _, k in ipairs(keys) do
    table.insert(sorted, {
      phrase = compacted[k],
      distance = k,
    })
  end

  return sorted
end

function C:enumerateDistances()
  local sorted = {}
  for _, entry in ipairs(self:enumerateDistanceEntries()) do
    table.insert(sorted, entry.phrase)
  end
  return sorted
end

function C:enumeratePacenotes()
  if not self.compositor then return {} end
  return self.compositor.enumerate(self, self:getConfig())
end

function C:enumerateScriptEntries()
  if not self.compositor then return {} end

  local entries = {}
  local function addEntry(entry)
    if not entry or not entry.phrase or entry.phrase == '' then return end
    entry.hash = entry.hash or self:pacenoteHash(entry.phrase)
    entry.audioFname = entry.audioFname or rallyUtil.makePacenoteAudioFilename(entry.hash)
    if not entry.recordingSlug or entry.recordingSlug == '' then
      entry.recordingSlug = entry.hash
      if entry.variant and entry.variant ~= '' then
        entry.recordingSlug = entry.recordingSlug..'_'..entry.variant
      end
    end
    table.insert(entries, entry)
  end

  local systemNotesMap = self:getSystemPacenotes()
  for i, entry in ipairs(self:getSystemPacenotesOrdered()) do
    local variants = systemNotesMap[entry.name] or {}
    for variantIndex, variant in ipairs(variants) do
      addEntry({
        phrase = variant.text,
        audioFname = rallyUtil.makeSystemPacenoteAudioFilename(entry.name, variantIndex),
        recordingSlug = 'system_'..entry.name..'_'..tostring(variantIndex),
        category = 'system',
        subcategory = entry.name,
        sourceContext = 'system pacenote: '..entry.name,
        sortGroup = 10,
        sortSubgroup = string.format("%03d", i),
      })
    end
  end

  for _, dist in ipairs(self:enumerateDistanceEntries()) do
    addEntry({
      phrase = dist.phrase,
      category = 'distance',
      subcategory = 'distance',
      sourceContext = 'distance call',
      sortGroup = 20,
      sortSubgroup = string.format("%08d", dist.distance or 0),
    })
  end

  for _, entry in ipairs(util.enumerateScriptEntries(self, self:getConfig())) do
    addEntry(entry)
  end

  return entries
end

function C:enumerateAll()
  local distances = self:enumerateDistances()
  local pacenotes = self:enumeratePacenotes()

  local combined = {}
  local groups = { distances = {}, pacenotes = {}, system = {} }
  local totalChars = 0

  local function addPhrase(phrase, group, systemName, opts)
    opts = opts or {}
    local item = { phrase = phrase, hash = self:pacenoteHash(phrase), group = group }
    if systemName then item.systemName = systemName end
    if opts.systemVariantIndex then item.systemVariantIndex = opts.systemVariantIndex end
    if opts.audioFname then item.audioFname = opts.audioFname end
    table.insert(combined, item)
    table.insert(groups[group], item)
    totalChars = totalChars + #phrase
  end

  for _, dist in ipairs(distances) do
    addPhrase(dist, 'distances')
  end

  for _, note in ipairs(pacenotes) do
    addPhrase(note, 'pacenotes')
  end

  -- iterate the style's ordered system array so script readers see them in
  -- the order the style author specified.
  local systemCount = 0
  local systemNotesMap = self:getSystemPacenotes()
  for _, entry in ipairs(self:getSystemPacenotesOrdered()) do
    local variants = systemNotesMap[entry.name] or {}
    systemCount = systemCount + #variants
    for variantIndex, variant in ipairs(variants) do
      addPhrase(variant.text, 'system', entry.name, {
        systemVariantIndex = variantIndex,
        audioFname = rallyUtil.makeSystemPacenoteAudioFilename(entry.name, variantIndex),
      })
    end
  end

  -- Check for duplicate phrases and remove them
  local seen = {}
  for _, item in ipairs(combined) do
    if not seen[item.phrase] then
      seen[item.phrase] = true
    else
      log('E', logTag, 'Duplicate phrase found: "'..item.phrase..'"')
      error('Duplicate phrase found: "'..item.phrase..'"')
    end
  end

  local out = {
    stats = {
      totalChars = totalChars,
      totalPhrases = #combined,
      distancePhrases = #distances,
      notePhrases = #pacenotes,
      systemPhrases = systemCount,
    },
    phrases = combined,
    groups = groups,
  }

  log('I', logTag, string.format('Enumerated %d phrases (%d chars) for compositor "%s" (%s.lua)',
    out.stats.totalPhrases, out.stats.totalChars, self.compositorName, self:compositorPath()))
  log('I', logTag, string.format('Details: %d distance calls, %d pacenotes, %d system pacenotes',
    out.stats.distancePhrases, out.stats.notePhrases, out.stats.systemPhrases))

  return out
end

function C:writeEnumerated(fname, enumerated)
  jsonWriteFile(fname, enumerated, true)
end

function C:roundDistance(dist)
  if dist >= self:getRoundingLargeThreshold() then
    local roundedVal = rallyUtil.customRound(dist, self:getRoundingLarge()) / self:getRoundingLargeThreshold()
    return roundedVal, self:getLargeUnit()
  elseif dist >= self:getRoundingMediumThreshold() then
    local val = rallyUtil.customRound(dist, self:getRoundingMedium())
    if val == self:getRoundingLargeThreshold() then
      val = rallyUtil.customRound(dist, self:getRoundingLarge()) / self:getRoundingLargeThreshold()
      return val, self:getLargeUnit()
    end
    return val, self:getBaseUnit()
  else
    return rallyUtil.customRound(dist, self:getRoundingSmall()), self:getBaseUnit()
  end
end

local function replacePeriodWithPoint(inputString, pointTranslation)
  if string.find(inputString, "%.") then
    local firstPart, secondPart = inputString:match("(%d+)%.(%d+)")
    if firstPart and secondPart then
      local digits = {}
      for digit in secondPart:gmatch("%d") do
        table.insert(digits, digit)
      end
      inputString = firstPart .. " " .. pointTranslation .. " " .. table.concat(digits, " ")
    end
  end
  return inputString
end

function C:distanceToString(dist)
  dist = math.floor(dist)
  local roundedDist, unit = self:roundDistance(dist)
  local distStr = tostring(roundedDist)

  if unit == self:getLargeUnit() then
    distStr = replacePeriodWithPoint(distStr, self:getPointTranslation())
    distStr = distStr .. " " .. unit
  end

  return distStr
end

function C:getDistanceCallShorthand(dist)
  if not self:distanceCallsEnabled() then return nil, false end

  for _, link in ipairs(self:getDistanceLinks()) do
    if dist < link.threshold then
      return link.text, true
    end
  end
  return nil, false
end

function C:getDistanceLinks()
  return self.compositor.distance.links or {}
end

function C:getMaxLinkDistance()
  local links = self:getDistanceLinks()
  local last = links[#links]
  return last and last.threshold or 0
end

function C:getBaseUnit()
  return self.compositor.distance.units.base
end
function C:getLargeUnit()
  return self.compositor.distance.units.large
end
function C:getPointTranslation()
  return self.compositor.distance.units.point
end

function C:getRoundingSmall()
  return self.compositor.distance.rounding.small
end
function C:getRoundingMedium()
  return self.compositor.distance.rounding.medium
end
function C:getRoundingMediumThreshold()
  return self.compositor.distance.rounding.mediumThreshold
end

function C:getRoundingLarge()
  return self.compositor.distance.rounding.large
end
function C:getRoundingLargeThreshold()
  return self.compositor.distance.rounding.largeThreshold
end
function C:getMaxDistance()
  return self.compositor.distance.max
end

function C:pacenoteHash(text)
  return util.pacenoteHash(text)
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
