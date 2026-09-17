-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Per-style internal-consistency checks for compositor style configs.
--
-- There is intentionally NO cross-style schema enforcement: a style is free
-- to define any subset, superset, or different set of item types from any
-- other style. Compositors gracefully degrade on unknown types/values.
--
-- System pacenote names are still validated against systemPacenotes.lua so
-- the canonical set of system names lives in one place.

local systemPacenotes = require('/lua/ge/extensions/gameplay/rally/notebook/systemPacenotes')

local M = {}

local logTag = 'styleValidator'

local function isList(t)
  if type(t) ~= 'table' then return false end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n > 0 and n == #t
end

local function err(name, msg)
  log('E', logTag, "style '"..tostring(name).."': "..msg)
end

local function validateOrderedRanges(name, list, lookupKey, label)
  local expectedMin = 0
  for i, entry in ipairs(list) do
    local range = entry[lookupKey]
    local isLast = i == #list
    if type(range) ~= 'table' then
      err(name, "componentTypes.corner."..label.."["..i.."] missing range '"..lookupKey.."'")
      return false
    end
    if range[1] ~= nil or range[2] ~= nil then
      err(name, "componentTypes.corner."..label.."["..i.."] range must use explicit min/max fields")
      return false
    end

    local min = tonumber(range.min)
    local max = range.max ~= nil and tonumber(range.max) or nil
    if not min then
      err(name, "componentTypes.corner."..label.."["..i.."] range must define numeric min")
      return false
    end
    if min ~= expectedMin then
      err(name, "componentTypes.corner."..label.."["..i.."] range min must equal previous max ("..tostring(expectedMin)..")")
      return false
    end
    if not max and not isLast then
      err(name, "componentTypes.corner."..label.."["..i.."] range max may only be omitted on the final range")
      return false
    end
    if max and max <= min then
      err(name, "componentTypes.corner."..label.."["..i.."] range max must be greater than min")
      return false
    end
    expectedMin = max
  end
  return true
end

local function validateLookupList(name, list, lookupKey, label)
  if not isList(list) then
    err(name, "componentTypes.corner."..label.." must be a non-empty array")
    return false
  end

  for i, entry in ipairs(list) do
    if type(entry) ~= 'table' then
      err(name, "componentTypes.corner."..label.."["..i.."] must be a table")
      return false
    end
    local value = entry[lookupKey]
    if type(value) ~= 'table' then
      err(name, "componentTypes.corner."..label.."["..i.."] missing range '"..lookupKey.."'")
      return false
    end
  end

  return validateOrderedRanges(name, list, lookupKey, label)
end

local function validateIntensityList(name, list)
  if not validateLookupList(name, list, 'diameter', 'numbering.intensity') then
    return false
  end

  local seenIds = {}
  for i, entry in ipairs(list) do
    if type(entry.id) ~= 'string' or entry.id == '' then
      err(name, "componentTypes.corner.numbering.intensity["..i.."] missing string `id`")
      return false
    end
    if seenIds[entry.id] then
      err(name, "componentTypes.corner.numbering.intensity["..i.."] duplicate id '"..entry.id.."'")
      return false
    end
    seenIds[entry.id] = true

    if type(entry.text) ~= 'string' or entry.text == '' then
      err(name, "componentTypes.corner.numbering.intensity["..i.."] missing string `text`")
      return false
    end
    if entry.afterDirection ~= nil and type(entry.afterDirection) ~= 'string' then
      err(name, "componentTypes.corner.numbering.intensity["..i.."].afterDirection must be a string")
      return false
    end
  end

  return true
end

local function validateLengthsForIntensity(name, list, intensityId)
  if not isList(list) then
    err(name, "componentTypes.corner.numbering.lengthsByIntensity."..tostring(intensityId).." must be a non-empty array")
    return false
  end

  local seenIds = {}
  for i, entry in ipairs(list) do
    if type(entry) ~= 'table' then
      err(name, "componentTypes.corner.numbering.lengthsByIntensity."..tostring(intensityId).."["..i.."] must be a table")
      return false
    end

    if type(entry.id) ~= 'string' or entry.id == '' then
      err(name, "componentTypes.corner.numbering.lengthsByIntensity."..tostring(intensityId).."["..i.."] missing string `id`")
      return false
    end

    if seenIds[entry.id] then
      err(name, "componentTypes.corner.numbering.lengthsByIntensity."..tostring(intensityId).."["..i.."] duplicate id '"..entry.id.."'")
      return false
    end
    seenIds[entry.id] = true

    if entry.text ~= nil and type(entry.text) ~= 'string' then
      err(name, "componentTypes.corner.numbering.lengthsByIntensity."..tostring(intensityId).."["..i.."].text must be a string")
      return false
    end

    if type(entry.arcMeters) ~= 'table' then
      err(name, "componentTypes.corner.numbering.lengthsByIntensity."..tostring(intensityId).."["..i.."] missing range `arcMeters`")
      return false
    end
  end

  return validateOrderedRanges(name, list, 'arcMeters', "numbering.lengthsByIntensity."..tostring(intensityId))
end

local function validateLengthsByIntensity(name, numbering)
  local lengthsByIntensity = numbering.lengthsByIntensity
  if lengthsByIntensity == nil then return true end
  if type(lengthsByIntensity) ~= 'table' then
    err(name, "componentTypes.corner.numbering.lengthsByIntensity must be a table")
    return false
  end

  local validIntensityIds = {}
  for _, entry in ipairs(numbering.intensity or {}) do
    if entry.id then validIntensityIds[entry.id] = true end
  end

  for intensityId in pairs(lengthsByIntensity) do
    if next(validIntensityIds) and not validIntensityIds[intensityId] then
      err(name, "componentTypes.corner.numbering.lengthsByIntensity has unknown intensity '"..tostring(intensityId).."'")
      return false
    end
  end

  for intensityId in pairs(validIntensityIds) do
    if lengthsByIntensity[intensityId] == nil then
      err(name, "componentTypes.corner.numbering.lengthsByIntensity missing intensity '"..tostring(intensityId).."'")
      return false
    end
  end

  for intensityId, list in pairs(lengthsByIntensity) do
    if not validateLengthsForIntensity(name, list, intensityId) then
      return false
    end
  end

  return true
end

local function validateVisual(name, visual, ctx)
  if visual == nil then return true end
  if type(visual) ~= 'table' then
    err(name, ctx.." visual must be a table")
    return false
  end
  if visual.icon ~= nil and type(visual.icon) ~= 'string' then
    err(name, ctx.." visual.icon must be a string")
    return false
  end
  if visual.turnModifier ~= nil and type(visual.turnModifier) ~= 'string' then
    err(name, ctx.." visual.turnModifier must be a string")
    return false
  end
  if visual.additionalNote ~= nil then
    if type(visual.additionalNote) ~= 'table' then
      err(name, ctx.." visual.additionalNote must be a table")
      return false
    end
    if visual.additionalNote.icon ~= nil and type(visual.additionalNote.icon) ~= 'string' then
      err(name, ctx.." visual.additionalNote.icon must be a string")
      return false
    end
    if visual.additionalNote.text ~= nil and type(visual.additionalNote.text) ~= 'string' then
      err(name, ctx.." visual.additionalNote.text must be a string")
      return false
    end
    if visual.additionalNote.color ~= nil and type(visual.additionalNote.color) ~= 'string' then
      err(name, ctx.." visual.additionalNote.color must be a string")
      return false
    end
    if visual.additionalNote.colorBg ~= nil and type(visual.additionalNote.colorBg) ~= 'string' then
      err(name, ctx.." visual.additionalNote.colorBg must be a string")
      return false
    end
    if visual.additionalNote.colorStroke ~= nil and type(visual.additionalNote.colorStroke) ~= 'string' then
      err(name, ctx.." visual.additionalNote.colorStroke must be a string")
      return false
    end
  end
  return true
end

local function validateCornerComponent(name, corner)
  if type(corner) ~= 'table' then
    err(name, "componentTypes.corner must be a table")
    return false
  end

  if corner.numbering ~= nil then
    if type(corner.numbering) ~= 'table' then
      err(name, "componentTypes.corner.numbering must be a table")
      return false
    end
    if corner.numbering.intensity ~= nil and not validateIntensityList(name, corner.numbering.intensity) then
      return false
    end
    if not validateLengthsByIntensity(name, corner.numbering) then
      return false
    end
  end

  if corner.direction ~= nil then
    if type(corner.direction) ~= 'table' then
      err(name, "componentTypes.corner.direction must be a table")
      return false
    end
    if corner.direction[0] ~= nil then
      err(name, "componentTypes.corner.direction must define corner directions only; direction 0 emits no corner call")
      return false
    end
  end

  if corner.shapes ~= nil then
    if type(corner.shapes) ~= 'table' then
      err(name, "componentTypes.corner.shapes must be a table")
      return false
    end
    for k, entry in pairs(corner.shapes) do
      if type(k) ~= 'string' then
        err(name, "componentTypes.corner.shapes must be keyed by string")
        return false
      end
      if type(entry) ~= 'table' or type(entry.text) ~= 'string' then
        err(name, "componentTypes.corner.shapes["..tostring(k).."] missing string `text`")
        return false
      end
      if not validateVisual(name, entry.visual, "componentTypes.corner.shapes["..tostring(k).."]") then
        return false
      end
    end
  end

  if corner.descriptors ~= nil then
    if type(corner.descriptors) ~= 'table' then
      err(name, "componentTypes.corner.descriptors must be a table")
      return false
    end
    for k, entry in pairs(corner.descriptors) do
      if type(k) ~= 'string' then
        err(name, "componentTypes.corner.descriptors must be keyed by string")
        return false
      end
      if type(entry) ~= 'table' or type(entry.text) ~= 'string' then
        err(name, "componentTypes.corner.descriptors."..k.." missing string `text`")
        return false
      end
      if not validateVisual(name, entry.visual, "componentTypes.corner.descriptors."..k) then
        return false
      end
    end
  end

  if corner.descriptorAliases ~= nil then
    if type(corner.descriptorAliases) ~= 'table' then
      err(name, "componentTypes.corner.descriptorAliases must be a table")
      return false
    end
    for alias, target in pairs(corner.descriptorAliases) do
      if type(alias) ~= 'string' or type(target) ~= 'string' then
        err(name, "componentTypes.corner.descriptorAliases must map string aliases to string descriptor keys")
        return false
      end
      if not (corner.descriptors and corner.descriptors[target]) then
        err(name, "componentTypes.corner.descriptorAliases."..alias.." targets unknown descriptor '"..target.."'")
        return false
      end
    end
  end

  return validateVisual(name, corner.visual, "componentTypes.corner")
end

local function validateCautionComponent(name, caution)
  if type(caution) ~= 'table' then
    err(name, "componentTypes.caution must be a table")
    return false
  end
  if type(caution.levels) ~= 'table' then
    err(name, "componentTypes.caution.levels must be a table")
    return false
  end
  for k, v in pairs(caution.levels) do
    if type(k) ~= 'number' then
      err(name, "componentTypes.caution.levels must be keyed by integer level")
      return false
    end
    if type(v) ~= 'string' then
      err(name, "componentTypes.caution.levels["..tostring(k).."] must be a string label")
      return false
    end
  end
  if caution.levelVisuals == nil and caution.visual == nil then
    err(name, "componentTypes.caution must define either levelVisuals or visual")
    return false
  end
  if caution.levelVisuals ~= nil then
    if type(caution.levelVisuals) ~= 'table' then
      err(name, "componentTypes.caution.levelVisuals must be a table")
      return false
    end
    for level in pairs(caution.levels) do
      if caution.levelVisuals[level] == nil then
        err(name, "componentTypes.caution.levelVisuals missing level "..tostring(level))
        return false
      end
    end
    for k, visual in pairs(caution.levelVisuals) do
      if type(k) ~= 'number' then
        err(name, "componentTypes.caution.levelVisuals must be keyed by integer level")
        return false
      end
      if caution.levels[k] == nil then
        err(name, "componentTypes.caution.levelVisuals["..tostring(k).."] targets unknown level")
        return false
      end
      if not validateVisual(name, visual, "componentTypes.caution.levelVisuals["..tostring(k).."]") then
        return false
      end
    end
  end
  return validateVisual(name, caution.visual, "componentTypes.caution")
end

local function validateAtomicComponent(name, key, entry)
  if type(entry) ~= 'table' then
    err(name, "componentTypes."..key.." must be a table")
    return false
  end
  if type(entry.text) ~= 'string' then
    err(name, "componentTypes."..key.." missing string `text`")
    return false
  end
  if entry.tags ~= nil then
    if type(entry.tags) ~= 'table' then
      err(name, "componentTypes."..key..".tags must be a table")
      return false
    end
    for i, tag in ipairs(entry.tags) do
      if type(tag) ~= 'string' then
        err(name, "componentTypes."..key..".tags["..tostring(i).."] must be a string")
        return false
      end
    end
  end
  return validateVisual(name, entry.visual, "componentTypes."..key)
end

local function validateModifiersComponent(name, modifiers)
  if type(modifiers) ~= 'table' then
    err(name, "componentTypes.modifiers must be a table")
    return false
  end
  for key, entry in pairs(modifiers) do
    if type(key) ~= 'string' then
      err(name, "componentTypes.modifiers must be keyed by string")
      return false
    end
    if not validateAtomicComponent(name, 'modifiers.'..key, entry) then
      return false
    end
  end
  return true
end

local function validateModifierAliases(name, componentTypes)
  local aliases = componentTypes.modifierAliases
  if aliases == nil then return true end
  if type(aliases) ~= 'table' then
    err(name, "componentTypes.modifierAliases must be a table")
    return false
  end

  local modifiers = componentTypes.modifiers or {}
  for alias, target in pairs(aliases) do
    if type(alias) ~= 'string' or type(target) ~= 'string' then
      err(name, "componentTypes.modifierAliases must map string aliases to string modifier keys")
      return false
    end
    if not modifiers[target] then
      err(name, "componentTypes.modifierAliases."..alias.." targets unknown modifier '"..target.."'")
      return false
    end
  end
  return true
end

local function validateDistanceConfig(name, distance)
  if type(distance) ~= 'table' then
    err(name, "missing distance table")
    return false
  end

  if distance.callsEnabled ~= nil and type(distance.callsEnabled) ~= 'boolean' then
    err(name, "distance.callsEnabled must be a boolean when set")
    return false
  end

  if not isList(distance.links) then
    err(name, "distance.links must be a non-empty ordered array")
    return false
  end
  local previousThreshold = nil
  for i, entry in ipairs(distance.links) do
    if type(entry) ~= 'table' or type(entry.threshold) ~= 'number' or (entry.text ~= nil and type(entry.text) ~= 'string') then
      err(name, "distance.links["..i.."] must define numeric threshold and optional string text")
      return false
    end
    if previousThreshold ~= nil and entry.threshold <= previousThreshold then
      err(name, "distance.links["..i.."].threshold must be greater than the previous threshold")
      return false
    end
    previousThreshold = entry.threshold
  end

  if type(distance.units) ~= 'table'
    or type(distance.units.base) ~= 'string'
    or type(distance.units.large) ~= 'string'
    or type(distance.units.point) ~= 'string' then
    err(name, "distance.units must define base, large, and point strings")
    return false
  end

  local rounding = distance.rounding
  if type(rounding) ~= 'table'
    or type(rounding.small) ~= 'number'
    or type(rounding.medium) ~= 'number'
    or type(rounding.mediumThreshold) ~= 'number'
    or type(rounding.large) ~= 'number'
    or type(rounding.largeThreshold) ~= 'number' then
    err(name, "distance.rounding must define numeric small, medium, mediumThreshold, large, and largeThreshold")
    return false
  end

  if type(distance.max) ~= 'number' then
    err(name, "distance.max must be a number")
    return false
  end

  return true
end

function M.validate(style, name)
  name = name or '?'

  if type(style) ~= 'table' then
    err(name, "style is not a table")
    return false
  end

  if not validateDistanceConfig(name, style.distance) then
    return false
  end

  if type(style.componentTypes) ~= 'table' then
    err(name, "missing componentTypes table")
    return false
  end

  for key, entry in pairs(style.componentTypes) do
    if key == 'corner' then
      if not validateCornerComponent(name, entry) then return false end
    elseif key == 'caution' then
      if not validateCautionComponent(name, entry) then return false end
    elseif key == 'modifiers' then
      if not validateModifiersComponent(name, entry) then return false end
    elseif key == 'modifierAliases' then
      -- validated after modifiers, so aliases can be checked against targets.
    else
      err(name, "unsupported top-level componentTypes."..tostring(key).."; atomic modifiers belong under componentTypes.modifiers")
      return false
    end
  end

  if not validateModifierAliases(name, style.componentTypes) then
    return false
  end

  if not systemPacenotes.validate(style.system, name) then
    return false
  end

  return true
end

return M
