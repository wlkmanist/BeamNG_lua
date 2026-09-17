-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Compositor dispatcher: walks structured items in fixed slot order and emits phrases
-- per item type. Item type rendering is owned by the active style's
-- componentTypes registry. Unknown item types and unmappable enum values
-- degrade silently (no error, no warning) so style swaps never crash.

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local Structured = require('/lua/ge/extensions/gameplay/rally/notebook/structured')

local M = {}

local phraseCategory = {
  distance = 'distance',
  linkword = 'linkword',
  corner = 'corner',
  caution = 'caution',
  modifier = 'modifier',
  other = 'other',
}

M.getNearestValue = function(valuesList, targetValue, key)
  key = key or 'value'
  local closest = nil
  local minDiff = math.huge

  for _,entry in ipairs(valuesList) do
    local value = tonumber(entry[key])
    if value then
      local diff = math.abs(value - targetValue)
      if diff < minDiff then
        minDiff = diff
        closest = entry
      end
    end
  end

  return closest
end

local function rangeBounds(value)
  if type(value) ~= 'table' then return nil, nil end
  local min = tonumber(value.min)
  local max = value.max ~= nil and tonumber(value.max) or nil
  return min, max
end
M.rangeBounds = rangeBounds

local function rangeContains(value, targetValue)
  local min, max = rangeBounds(value)
  if not min then return false end
  return targetValue >= min and (max == nil or targetValue < max)
end
M.rangeContains = rangeContains

M.getRangeValue = function(valuesList, targetValue, key)
  key = key or 'value'
  targetValue = tonumber(targetValue)
  if not (valuesList and targetValue) then return nil end

  for _, entry in ipairs(valuesList) do
    if rangeContains(entry[key], targetValue) then
      return entry
    end
  end
  return nil
end

M.getClosestEntry = function(valuesList, targetValue, key, filterFn)
  key = key or 'value'
  targetValue = tonumber(targetValue)
  if not (valuesList and targetValue) then return nil end

  local closest = nil
  local minDiff = math.huge
  for _, entry in ipairs(valuesList) do
    if not filterFn or filterFn(entry) then
      local diff = nil
      local min, max = rangeBounds(entry[key])
      if min then
        if targetValue < min then
          diff = min - targetValue
        elseif max and targetValue >= max then
          diff = targetValue - max
        else
          diff = 0
        end
      end

      if diff and diff < minDiff then
        minDiff = diff
        closest = entry
      end
    end
  end

  return closest
end

-- ---------------------------------------------------------------------------
-- Per-type helpers. Each returns either a string phrase or nil.
-- They are also used by the visual compositor to look up matching visuals.
-- ---------------------------------------------------------------------------

local function cornerNumbering(cornerCfg)
  if not cornerCfg then return {} end
  return cornerCfg.numbering or cornerCfg
end
M.cornerNumbering = cornerNumbering

local function cornerIntensityList(cornerCfg)
  return cornerNumbering(cornerCfg).intensity
end
M.cornerIntensityList = cornerIntensityList

local function cornerLengthList(cornerCfg, intensityId)
  local byIntensity = cornerNumbering(cornerCfg).lengthsByIntensity
  if not (byIntensity and intensityId) then return nil end
  return byIntensity[intensityId]
end
M.cornerLengthList = cornerLengthList

local function cornerLengthEntryById(cornerCfg, intensityId, lengthId)
  for index, entry in ipairs(cornerLengthList(cornerCfg, intensityId) or {}) do
    if entry.id == lengthId then return entry, index end
  end
  return nil, nil
end
M.cornerLengthEntryById = cornerLengthEntryById

local function modifierComponents(componentTypes)
  return componentTypes and componentTypes.modifiers or {}
end
M.modifierComponents = modifierComponents

local function lookupComponentType(componentTypes, itemType)
  if itemType == 'corner' or itemType == 'caution' then
    return componentTypes and componentTypes[itemType] or nil
  end
  local modifierKey = componentTypes and componentTypes.modifierAliases and componentTypes.modifierAliases[itemType] or itemType
  return modifierComponents(componentTypes)[modifierKey]
end
M.lookupComponentType = lookupComponentType

local function cornerLengthEntryText(entry)
  return entry and entry.text or nil
end
M.cornerLengthEntryText = cornerLengthEntryText

local function cornerLengthEntryLabel(entry)
  if not entry then return nil end
  return entry.label or entry.text or entry.id
end
M.cornerLengthEntryLabel = cornerLengthEntryLabel

local function intensityEntryId(entry)
  return entry and entry.id or nil
end
M.intensityEntryId = intensityEntryId

local function intensityEntryText(entry)
  return entry and entry.text or nil
end
M.intensityEntryText = intensityEntryText

local function intensityEntryLabel(entry)
  if not entry then return nil end
  return entry.label or entry.text or entry.id
end
M.intensityEntryLabel = intensityEntryLabel

local function signedStep(value)
  local n = tonumber(value) or 0
  if n > 0 then return 1 end
  if n < 0 then return -1 end
  return 0
end
M.signedStep = signedStep

local function clampIndex(index, count)
  if index < 1 then return 1 end
  if index > count then return count end
  return index
end

local function phraseFromParts(parts)
  local out = {}
  for _, part in ipairs(parts or {}) do
    if part and part ~= '' then
      table.insert(out, part)
    end
  end
  if #out == 0 then return nil end
  return table.concat(out, ' ')
end

local function lookupIntensityEntryWithIndex(cornerCfg, intensity)
  local intensityList = cornerIntensityList(cornerCfg)
  if not intensityList or #intensityList == 0 then return nil, nil end
  local target = tonumber(intensity)
  if not target or target < 0 then return nil, nil end
  for i, entry in ipairs(intensityList) do
    if rangeContains(entry.diameter, target) then
      return entry, i
    end
  end
  return nil, nil
end

-- Returns the matching style intensity entry (or nil) for a measured physical diameter.
M.lookupIntensityEntry = function(cornerCfg, intensity)
  local entry = lookupIntensityEntryWithIndex(cornerCfg, intensity)
  return entry
end

M.lookupRiskAdjustedIntensityEntry = function(cornerCfg, item)
  local intensityList = cornerIntensityList(cornerCfg)
  local entry, index = lookupIntensityEntryWithIndex(cornerCfg, item and item.intensity)
  if not (entry and index and intensityList and #intensityList > 0) then return entry end

  local riskStep = signedStep(item and item.riskIntensity)
  if riskStep == 0 then return entry end

  -- Intensity lists are ordered from highest risk to lowest risk. A positive
  -- risk adjustment therefore moves toward the start of the style's ladder.
  return intensityList[clampIndex(index - riskStep, #intensityList)] or entry
end

-- Returns the descriptor entry (or nil) for a corner item.
M.lookupDescriptorEntry = function(cornerCfg, descriptor)
  if not descriptor or not cornerCfg or not cornerCfg.descriptors then return nil end
  local descriptorKey = cornerCfg.descriptorAliases and cornerCfg.descriptorAliases[descriptor] or descriptor
  return cornerCfg.descriptors[descriptorKey]
end

M.lookupShapeEntry = function(cornerCfg, shape)
  if not shape or not cornerCfg then return nil end
  if cornerCfg.shapes and cornerCfg.shapes[shape] then
    return cornerCfg.shapes[shape]
  end
  return nil
end

local function getCornerCall(cornerCfg, item)
  if not cornerCfg then return nil, nil end

  local direction = item.direction
  if direction == nil or direction == 0 then return nil, nil end
  local dirStr = cornerCfg.direction and cornerCfg.direction[direction] or nil
  if not dirStr or dirStr == '' then return nil end

  -- descriptor wins over intensity name (descriptor implies a non-numeric corner type)
  local descEntry = M.lookupDescriptorEntry(cornerCfg, item.descriptor)
  if descEntry then
    return phraseFromParts({ descEntry.text, dirStr })
  end

  local intEntry = M.lookupRiskAdjustedIntensityEntry(cornerCfg, item)
  if not intEntry then return nil end
  return phraseFromParts({ intensityEntryText(intEntry), dirStr, intEntry.afterDirection })
end
M.getCornerCall = getCornerCall

local function getCornerLengthForIntensity(cornerCfg, item, intensityEntry)
  local intensityId = intensityEntryId(intensityEntry)
  if not (item and intensityId) then return nil end
  if item.lengthMode == 'skip' then return nil end

  local arcMeters = tonumber(item.arcMeters)
  if not arcMeters then return nil end

  local list = cornerLengthList(cornerCfg, intensityId)
  if type(list) ~= 'table' then return nil end
  for i, entry in ipairs(list) do
    if rangeContains(entry.arcMeters, arcMeters) then
      local lengthStep = item.lengthMode == 'shorter' and -1 or (item.lengthMode == 'longer' and 1 or 0)
      if lengthStep ~= 0 then
        entry = list[clampIndex(i + lengthStep, #list)]
      end
      return cornerLengthEntryText(entry)
    end
  end

  return nil
end
M.getCornerLengthForIntensity = getCornerLengthForIntensity

local function getCornerLengthForItem(cornerCfg, item)
  local intensityEntry = M.lookupIntensityEntry(cornerCfg, item and item.intensity)
  return getCornerLengthForIntensity(cornerCfg, item, intensityEntry)
end
M.getCornerLengthForItem = getCornerLengthForItem

local function getCornerShape(cornerCfg, shape)
  local entry = M.lookupShapeEntry(cornerCfg, shape)
  return entry and entry.text or nil
end
M.getCornerShape = getCornerShape

local function getCaution(cautionCfg, item)
  if not cautionCfg or not cautionCfg.levels or not item or not item.level then return nil end
  return cautionCfg.levels[item.level]
end
M.getCaution = getCaution

local function phraseEntry(text, sourceEntry)
  if not text or text == '' then return nil end
  local entry = { text = text }
  if sourceEntry and sourceEntry.variant and sourceEntry.variant ~= '' then
    entry.variant = sourceEntry.variant
  end
  return entry
end

local function postProcessPhraseEntry(entry)
  if type(entry) == 'string' then
    entry = { text = entry }
  end
  if type(entry) ~= 'table' then return nil end

  local text = M.postProcessPhrase(entry.text)
  if not text or text == '' then return nil end

  local out = { text = text }
  if entry.variant and entry.variant ~= '' then
    out.variant = entry.variant
  end
  if entry.category and entry.category ~= '' then
    out.category = entry.category
  end
  if entry.audioFname then
    out.audioFname = entry.audioFname
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Per-item phrase emitters. Each returns an array of phrase entries.
-- ---------------------------------------------------------------------------

local function emitCaution(typeConf, item)
  local txt = getCaution(typeConf, item)
  if not txt or txt == '' then return {} end
  return { phraseEntry(txt) }
end

local function emitCorner(typeConf, item)
  local out = {}
  local descEntry = M.lookupDescriptorEntry(typeConf, item.descriptor)
  local cornerCall = getCornerCall(typeConf, item)
  if not cornerCall then return out end

  table.insert(out, phraseEntry(cornerCall))

  if not descEntry then
    local lengthStr = getCornerLengthForItem(typeConf, item)
    if lengthStr then table.insert(out, phraseEntry(lengthStr)) end
  end

  local shapeEntry = M.lookupShapeEntry(typeConf, item.shape)
  if shapeEntry and shapeEntry.text then
    table.insert(out, phraseEntry(shapeEntry.text, shapeEntry))
  end

  return out
end

local function emitAtomic(typeConf)
  if not typeConf or not typeConf.text or typeConf.text == '' then return {} end
  return { phraseEntry(typeConf.text, typeConf) }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

M.postProcessPhrase = function(phrase)
  phrase = rallyUtil.trimString(phrase)
  phrase = rallyUtil.trimString(phrase)
  return phrase
end

M.pacenoteHash = function(text)
  if not text then return nil end
  local hash = string.lower(text)
  hash = string.gsub(hash, "'", "")
  hash = string.gsub(hash, "[^a-z0-9]", "_")
  hash = string.gsub(hash, "(_+)", "_")
  hash = string.gsub(hash, "^_", "")
  hash = string.gsub(hash, "_$", "")
  return hash
end

M.getRandomWeightedItem = function(items)
  local totalWeight = 0
  for _, item in ipairs(items) do
    totalWeight = totalWeight + (item.weight or 1)
  end

  local randomValue = math.random()

  local cumulativeWeight = 0
  for _, item in ipairs(items) do
    local normalizedWeight = (item.weight or 1) / totalWeight
    cumulativeWeight = cumulativeWeight + normalizedWeight

    if randomValue <= cumulativeWeight then
      return item
    end
  end

  return items[#items]
end

local function distanceCallsEnabled(config)
  local distance = config and config.distance
  return not (distance and distance.callsEnabled == false)
end
M.distanceCallsEnabled = distanceCallsEnabled

local function distancePlaceholder(config, rawDistance, escape, varName)
  if not distanceCallsEnabled(config) then return nil end
  if not rawDistance or not rallyUtil.useNote(rawDistance) then return nil end
  if escape then return varName end
  return rawDistance
end

local function isDistanceLinkWord(config, text)
  if type(text) ~= 'string' or text == '' then return false end
  local normalizedText = M.postProcessPhrase(text)
  if not normalizedText or normalizedText == '' then return false end

  local links = config.distance and config.distance.links or {}
  for _, link in ipairs(links) do
    local linkText = type(link) == 'table' and link.text or nil
    if type(linkText) == 'string' and M.postProcessPhrase(linkText) == normalizedText then
      return true
    end
  end

  return false
end

local function distancePlaceholderCategory(config, text)
  return isDistanceLinkWord(config, text) and phraseCategory.linkword or phraseCategory.distance
end

-- Walks structured items in fixed slot order, dispatches per type, and prepends/appends distance-call
-- placeholders. Unknown item types and unrenderable values silently drop their
-- sub-phrase. Items are spoken back-to-back with no auto-inserted item-to-item
-- connective; cross-pacenote links ("into" / "and") come from the
-- distance-driven link list when the active style enables distance calls.
M.compositePhraseEntries = function(config, structured, rawDistanceBefore, rawDistanceAfter, opts)
  opts = opts or {}
  config = config or {}
  local escapeVars = opts.escapeVars or false
  local variantResolver = opts.variantResolver

  local componentTypes = config.componentTypes or {}

  local result = {}

  local function addPhraseEntry(phrase, category)
    local entry = postProcessPhraseEntry(phrase)
    if entry and not entry.category then
      entry.category = category or phraseCategory.other
    end
    if entry and variantResolver then
      entry = variantResolver(entry)
    end
    if entry then
      table.insert(result, entry)
    end
  end

  local distanceBefore = distancePlaceholder(config, rawDistanceBefore, escapeVars, rallyUtil.var_db)
  local distanceAfter  = distancePlaceholder(config, rawDistanceAfter,  escapeVars, rallyUtil.var_da)
  local moveDistanceAfterBeforePostModifier = opts.distanceAfterBeforePostModifier == true
  local distanceAfterInserted = false
  local sawCorner = false
  local modifiersBeforeCorner = 0
  local postModifierSlotItems = {
    Structured.slotItem(structured, 5),
    Structured.slotItem(structured, 6),
  }

  if distanceBefore then
    addPhraseEntry(distanceBefore, distancePlaceholderCategory(config, distanceBefore))
  end

  local items = Structured.orderedItems(structured)
  local hasCorner = false
  for _, item in ipairs(items) do
    if type(item) == 'table' and item.type == 'corner' then
      hasCorner = true
      break
    end
  end

  for _, item in ipairs(items) do
    local typeConf = lookupComponentType(componentTypes, item.type)
    if typeConf then
      local subPhrases
      if item.type == 'corner' then
        subPhrases = emitCorner(typeConf, item)
      elseif item.type == 'caution' then
        subPhrases = emitCaution(typeConf, item)
      else
        subPhrases = emitAtomic(typeConf)
      end

      local category = phraseCategory.modifier
      if item.type == 'corner' then
        category = phraseCategory.corner
      elseif item.type == 'caution' then
        category = phraseCategory.caution
      elseif not modifierComponents(componentTypes)[item.type] and not (componentTypes.modifierAliases and componentTypes.modifierAliases[item.type]) then
        category = phraseCategory.other
      end

      local isModifier = category == phraseCategory.modifier and #subPhrases > 0
      local isPostModifier = false
      if postModifierSlotItems[1] or postModifierSlotItems[2] then
        isPostModifier = item == postModifierSlotItems[1] or item == postModifierSlotItems[2]
      else
        isPostModifier = sawCorner or (not hasCorner and modifiersBeforeCorner > 0)
      end

      if moveDistanceAfterBeforePostModifier and distanceAfter and not distanceAfterInserted and isModifier and isPostModifier then
        addPhraseEntry(distanceAfter, distancePlaceholderCategory(config, distanceAfter))
        distanceAfterInserted = true
      end

      for _, p in ipairs(subPhrases) do
        addPhraseEntry(p, category)
      end

      if item.type == 'corner' then
        sawCorner = true
      elseif isModifier and not sawCorner then
        modifiersBeforeCorner = modifiersBeforeCorner + 1
      end
    end
    -- unknown type: graceful degrade, no entry emitted
  end

  if distanceAfter and not distanceAfterInserted then
    addPhraseEntry(distanceAfter, distancePlaceholderCategory(config, distanceAfter))
  end

  return result
end

M.compositeFromPhrases = function(config, structured, rawDistanceBefore, rawDistanceAfter, escapeVars)
  local entries = M.compositePhraseEntries(config, structured, rawDistanceBefore, rawDistanceAfter, {
    escapeVars = escapeVars or false,
  })
  local result = {}
  for _, entry in ipairs(entries) do
    table.insert(result, entry.text)
  end
  return result
end

local function sortedKeys(tbl)
  local keys = {}
  for key in pairs(tbl or {}) do table.insert(keys, key) end
  table.sort(keys)
  return keys
end

local function scriptDirectionKeys(direction)
  local keys = {}
  local seen = {}

  for _, key in ipairs({ 1, -1 }) do
    if direction and direction[key] then
      table.insert(keys, key)
      seen[key] = true
    end
  end

  for _, key in ipairs(sortedKeys(direction)) do
    if key ~= 0 and not seen[key] then
      table.insert(keys, key)
    end
  end

  return keys
end

local function scriptNumberingSortKey(cornerCfg)
  -- Script-reader convenience sort only. This is intentionally narrow for the
  -- current built-in styles; move this into style-owned metadata if more
  -- numbering systems need custom recording order.
  local numberingSystem = cornerCfg and cornerCfg.numberingSystem or nil
  if numberingSystem == 'easy_medium_hard' then return 10 end
  if numberingSystem == 'one_to_six' then return 20 end
  return 50
end

local function variantValues(variant)
  if type(variant) ~= 'string' or variant == '' then return { false } end
  local out = {}
  for token in string.gmatch(variant, "[^,]+") do
    token = rallyUtil.trimString(token)
    local n = tonumber(token)
    if n and n > 0 then
      table.insert(out, tostring(math.floor(n)))
    end
  end
  if #out == 0 then return { false } end
  return out
end

local function audioFilenameForPhrase(phrase, variant)
  local basename = rallyUtil.makePacenoteAudioFilename(M.pacenoteHash(phrase))
  if variant then
    return string.gsub(basename, "%.ogg$", "_"..variant..".ogg")
  end
  return basename
end

local function recordingSlugForPhrase(phrase, variant)
  local slug = M.pacenoteHash(phrase)
  if variant then
    return slug.."_"..variant
  end
  return slug
end

local function addScriptEntry(out, phrase, opts)
  opts = opts or {}
  if not phrase or phrase == '' then return end
  phrase = M.postProcessPhrase(phrase)
  if phrase == '' then return end

  for _, variant in ipairs(variantValues(opts.variant)) do
    table.insert(out, {
      phrase = phrase,
      hash = M.pacenoteHash(phrase),
      audioFname = audioFilenameForPhrase(phrase, variant),
      recordingSlug = recordingSlugForPhrase(phrase, variant),
      category = opts.category,
      subcategory = opts.subcategory,
      sourceContext = opts.sourceContext,
      variant = variant or nil,
      sortGroup = opts.sortGroup or 999,
      sortSubgroup = opts.sortSubgroup or opts.subcategory or '',
      sortPhrase = phrase,
    })
  end
end

-- Enumerates script-reader entries with category and variant metadata. This is
-- intentionally richer than enumerateConcise, which remains the compact runtime
-- phrase list used by existing audio validation flows.
M.enumerateScriptEntries = function(textCompositor, config)
  local out = {}

  if distanceCallsEnabled(config) then
    local links = config.distance and config.distance.links or {}
    for _, link in ipairs(links) do
      if link.text and rallyUtil.useNote(link.text) then
        addScriptEntry(out, link.text, {
          category = 'distance',
          subcategory = 'link',
          sourceContext = 'distance link',
          sortGroup = 20,
        })
      end
    end
  end

  local componentTypes = config.componentTypes or {}
  local cornerCfg = componentTypes.corner
  if cornerCfg then
    local intensityList = cornerIntensityList(cornerCfg)
    if intensityList and cornerCfg.direction then
      local numberingSort = scriptNumberingSortKey(cornerCfg)
      for intIndex = #intensityList, 1, -1 do
        local intEntry = intensityList[intIndex]
        local intensitySort = #intensityList - intIndex + 1
        for dirIndex, dirVal in ipairs(scriptDirectionKeys(cornerCfg.direction)) do
          if dirVal ~= 0 then
            addScriptEntry(out, phraseFromParts({ intensityEntryText(intEntry), cornerCfg.direction[dirVal], intEntry.afterDirection }), {
              category = 'corner',
              subcategory = 'call',
              sourceContext = 'corner intensity: '..tostring(cornerCfg.numberingSystem or '?'),
              sortGroup = 30,
              sortSubgroup = string.format("%03d_%03d_%03d", numberingSort, intensitySort, dirIndex),
            })
          end
        end
      end
    end

    if cornerCfg.descriptors and cornerCfg.direction then
      for _, descKey in ipairs(sortedKeys(cornerCfg.descriptors)) do
        local descEntry = cornerCfg.descriptors[descKey]
        for _, dirVal in ipairs(sortedKeys(cornerCfg.direction)) do
          if dirVal ~= 0 and descEntry.text then
            addScriptEntry(out, phraseFromParts({ descEntry.text, cornerCfg.direction[dirVal] }), {
              category = 'corner',
              subcategory = 'descriptor',
              sourceContext = 'corner descriptor: '..descKey,
              sortGroup = 40,
            })
          end
        end
      end
    end

    local lengthNames = {}
    for _, intEntry in ipairs(cornerIntensityList(cornerCfg) or {}) do
      local intensityId = intensityEntryId(intEntry)
      for i, lengthEntry in ipairs(cornerLengthList(cornerCfg, intensityId) or {}) do
        local name = cornerLengthEntryText(lengthEntry)
        if name and not lengthNames[name] then
          lengthNames[name] = true
          addScriptEntry(out, name, {
            category = 'corner',
            subcategory = 'length',
            sourceContext = 'corner length',
            sortGroup = 50,
            sortSubgroup = string.format("%03d", i),
          })
        end
      end
    end

    if cornerCfg.shapes then
      for _, shapeKey in ipairs(sortedKeys(cornerCfg.shapes)) do
        local entry = cornerCfg.shapes[shapeKey]
        if entry.text then
          addScriptEntry(out, entry.text, {
            category = 'corner',
            subcategory = 'shape',
            sourceContext = 'corner shape: '..shapeKey,
            variant = entry.variant,
            sortGroup = 60,
          })
        end
      end
    end
  end

  local cautionCfg = componentTypes.caution
  if cautionCfg and cautionCfg.levels then
    for _, level in ipairs(sortedKeys(cautionCfg.levels)) do
      addScriptEntry(out, cautionCfg.levels[level], {
        category = 'caution',
        subcategory = 'level',
        sourceContext = 'caution level '..tostring(level),
        sortGroup = 70,
      })
    end
  end

  for _, key in ipairs(sortedKeys(modifierComponents(componentTypes))) do
    local entry = modifierComponents(componentTypes)[key]
    if type(entry) == 'table' and entry.text then
      local tag = 'other'
      if type(entry.tags) == 'table' and entry.tags[1] then
        tag = entry.tags[1]
      end
      addScriptEntry(out, entry.text, {
        category = 'modifier',
        subcategory = tag,
        sourceContext = 'modifier: '..key,
        variant = entry.variant,
        sortGroup = 80,
      })
    end
  end

  return out
end

-- Enumerates every renderable phrase for the active style. Used by audio
-- pipeline + script reader to know what files to look up / generate.
M.enumerateConcise = function(textCompositor, config)
  local enumeratedPhrases = {}
  local seen = {}

  local function addPhrase(phrase)
    if not phrase or phrase == '' then return end
    phrase = M.postProcessPhrase(phrase)
    if phrase == '' or seen[phrase] then return end
    seen[phrase] = true
    table.insert(enumeratedPhrases, phrase)
  end

  if distanceCallsEnabled(config) then
    local links = config.distance and config.distance.links or {}
    for _, link in ipairs(links) do
      if link.text and rallyUtil.useNote(link.text) then
        addPhrase(link.text)
      end
    end
  end

  local componentTypes = config.componentTypes or {}

  local cornerCfg = componentTypes.corner
  if cornerCfg then
    local intensityList = cornerIntensityList(cornerCfg)
    if intensityList and cornerCfg.direction then
      for _, intEntry in ipairs(intensityList) do
        for dirVal, dirStr in pairs(cornerCfg.direction) do
          if dirVal ~= 0 then
            addPhrase(phraseFromParts({ intensityEntryText(intEntry), dirStr, intEntry.afterDirection }))
          end
        end
      end
    end
    if cornerCfg.descriptors and cornerCfg.direction then
      for _, descEntry in pairs(cornerCfg.descriptors) do
        for dirVal, dirStr in pairs(cornerCfg.direction) do
          if dirVal ~= 0 and descEntry.text then
            addPhrase(phraseFromParts({ descEntry.text, dirStr }))
          end
        end
      end
    end
    local lengthNames = {}
    for _, intEntry in ipairs(cornerIntensityList(cornerCfg) or {}) do
      local intensityId = intensityEntryId(intEntry)
      for _, lengthEntry in ipairs(cornerLengthList(cornerCfg, intensityId) or {}) do
        local name = cornerLengthEntryText(lengthEntry)
        if name and not lengthNames[name] then
          lengthNames[name] = true
          addPhrase(name)
        end
      end
    end
    if cornerCfg.shapes then
      for _, entry in pairs(cornerCfg.shapes) do
        if entry.text then addPhrase(entry.text) end
      end
    end
  end

  local cautionCfg = componentTypes.caution
  if cautionCfg and cautionCfg.levels then
    for _, txt in pairs(cautionCfg.levels) do
      addPhrase(txt)
    end
  end

  for key, entry in pairs(modifierComponents(componentTypes)) do
    if type(entry) == 'table' and entry.text then
      addPhrase(entry.text)
    end
  end

  return enumeratedPhrases
end

return M
