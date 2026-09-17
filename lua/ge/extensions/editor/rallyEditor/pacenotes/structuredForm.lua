-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Slot-view editor over the fixed structured.items slot map. Sections:
--   Caution / Pre modifiers / Corner / Post modifiers / Distance
-- On every edit, surfaced slots are written back to schema slots "1".."6".

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local voicepack = require('/lua/ge/extensions/gameplay/rally/voicepack')
local RallyEnums = require('/lua/ge/extensions/gameplay/rally/enums')
local Structured = require('/lua/ge/extensions/gameplay/rally/notebook/structured')

local im  = ui_imgui
local logTag = ''

local M = {}

local lastPacenoteId = nil

local mapping = nil
local componentTypes = nil
local modifierTypes = nil
local cornerCfg = nil
local cautionCfg = nil
local atomicTypes = nil
local atomicGroups = nil
local shapeOptions = nil
local descriptorOptions = nil
local activePacenoteToolsWindow = nil

local FIELD_WIDTH = 250
local RECENT_MODIFIER_LIMIT = 10
local MODIFIER_SEARCH_INPUT_LEN = 128
local MODIFIER_SEARCH_RESULT_HEIGHT = 240
local headerTextColor = im.ImVec4(1.0, 0.64, 0.0, 1.0)
local recentModifierTypes = {}
local modifierSearchStates = {}

local function markValidationDirty()
  if activePacenoteToolsWindow and activePacenoteToolsWindow.markValidationDirty then
    activePacenoteToolsWindow:markValidationDirty()
  end
end

-- ---------------------------------------------------------------------------
-- Style introspection (cached per loaded style)
-- ---------------------------------------------------------------------------

local function displayLabel(entry, fallback)
  if not entry then return fallback end
  if entry.label and entry.label ~= "" then return entry.label end
  if entry.text and entry.text ~= "" then return entry.text end
  if entry.id and entry.id ~= "" then return entry.id end
  return fallback
end

local function buildAtomicTypes()
  local out = {}
  for key, _ in pairs(modifierTypes or {}) do
    table.insert(out, key)
  end
  table.sort(out)
  return out
end

local function modifierLabel(typeName)
  return displayLabel(modifierTypes and modifierTypes[typeName], typeName)
end

local function rememberModifier(typeName)
  for i = #recentModifierTypes, 1, -1 do
    if recentModifierTypes[i] == typeName then
      table.remove(recentModifierTypes, i)
    end
  end

  table.insert(recentModifierTypes, 1, typeName)
  while #recentModifierTypes > RECENT_MODIFIER_LIMIT do
    table.remove(recentModifierTypes)
  end
end

local function recentModifierOptions()
  local out = {}
  for _, typeName in ipairs(recentModifierTypes) do
    if modifierTypes and modifierTypes[typeName] then
      table.insert(out, typeName)
    end
  end
  return out
end

local function buildAtomicGroups()
  local groupsById = {}

  for _, typeName in ipairs(atomicTypes or {}) do
    local entry = modifierTypes[typeName] or {}
    local tags = entry.tags
    if type(tags) ~= 'table' or #tags == 0 then
      tags = { 'other' }
    end

    for _, tag in ipairs(tags) do
      local group = groupsById[tag]
      if not group then
        group = { id = tag, label = tag, items = {} }
        groupsById[tag] = group
      end
      table.insert(group.items, typeName)
    end
  end

  local groupIds = {}
  for id in pairs(groupsById) do table.insert(groupIds, id) end
  table.sort(groupIds, function(a, b)
    if a == 'other' then return false end
    if b == 'other' then return true end
    return a < b
  end)

  local out = {}
  for _, id in ipairs(groupIds) do
    local group = groupsById[id]
    table.sort(group.items, function(a, b)
      return modifierLabel(a) < modifierLabel(b)
    end)
    table.insert(out, group)
  end
  return out
end

local function buildShapeOptions()
  local out = { { label = '-', value = nil } }
  if cornerCfg and cornerCfg.shapes then
    local keys = {}
    for key in pairs(cornerCfg.shapes) do table.insert(keys, key) end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local entry = cornerCfg.shapes[key]
      table.insert(out, { label = displayLabel(entry, key), value = key })
    end
  end
  return out
end

local function buildDescriptorOptions()
  if not (cornerCfg and cornerCfg.descriptors) then return nil end
  local out = { { label = '-', value = nil } }
  local preferredOrder = {
    'bare',
    'flat',
    'square',
    'hairpin',
    'openHairpin',
    'tightHairpin',
  }
  local added = {}
  local keys = {}
  local extraKeys = {}
  for _, k in ipairs(preferredOrder) do
    if cornerCfg.descriptors[k] then
      table.insert(keys, k)
      added[k] = true
    end
  end
  for k in pairs(cornerCfg.descriptors) do
    if not added[k] then table.insert(extraKeys, k) end
  end
  table.sort(extraKeys)
  for _, k in ipairs(extraKeys) do
    table.insert(keys, k)
  end
  for _, k in ipairs(keys) do
    local entry = cornerCfg.descriptors[k]
    table.insert(out, { label = displayLabel(entry, k), value = k })
  end
  return out
end

local function load(pacenote)
  local tc = pacenote.notebook:getTextCompositor()
  if not tc then
    log('E', logTag, 'load: no text compositor')
    return
  end
  mapping = tc:getConfig()
  componentTypes = mapping.componentTypes or {}
  modifierTypes = componentTypes.modifiers or {}
  cornerCfg = componentTypes.corner
  cautionCfg = componentTypes.caution
  atomicTypes = buildAtomicTypes()
  atomicGroups = buildAtomicGroups()
  shapeOptions = buildShapeOptions()
  descriptorOptions = buildDescriptorOptions()
end

-- ---------------------------------------------------------------------------
-- Items <-> slot view
-- ---------------------------------------------------------------------------

local function isSlotModifier(item)
  return type(item) == 'table' and item.type ~= 'caution' and item.type ~= 'corner'
end

local function readSlots(pn)
  local slots = {
    caution = nil,
    preMods = {},
    corner  = nil,
    postMods = {},
  }

  local caution = Structured.slotItem(pn.structured, 1)
  local preMod1 = Structured.slotItem(pn.structured, 2)
  local preMod2 = Structured.slotItem(pn.structured, 3)
  local corner = Structured.slotItem(pn.structured, 4)
  local postMod1 = Structured.slotItem(pn.structured, 5)
  local postMod2 = Structured.slotItem(pn.structured, 6)

  if caution and caution.type == 'caution' then slots.caution = caution end
  if isSlotModifier(preMod1) then slots.preMods[1] = preMod1 end
  if isSlotModifier(preMod2) then slots.preMods[2] = preMod2 end
  if corner and corner.type == 'corner' then slots.corner = corner end
  if isSlotModifier(postMod1) then slots.postMods[1] = postMod1 end
  if isSlotModifier(postMod2) then slots.postMods[2] = postMod2 end

  return slots
end

local function writeCanonical(pn, slots)
  pn.structured:setSlotItems({
    ["1"] = slots.caution or {},
    ["2"] = slots.preMods[1] or {},
    ["3"] = slots.preMods[2] or {},
    ["4"] = slots.corner or {},
    ["5"] = slots.postMods[1] or {},
    ["6"] = slots.postMods[2] or {},
  })
  pn:refreshStructured()
  markValidationDirty()
end

local function setSlot(pn, slotName, item)
  local slots = readSlots(pn)
  if slotName == 'preMod1' then
    slots.preMods[1] = item
  elseif slotName == 'preMod2' then
    slots.preMods[2] = item
  elseif slotName == 'postMod1' then
    slots.postMods[1] = item
  elseif slotName == 'postMod2' then
    slots.postMods[2] = item
  else
    slots[slotName] = item
  end
  writeCanonical(pn, slots)
end

local function selectModifier(pacenote, slotName, typeName)
  setSlot(pacenote, slotName, { type = typeName })
  rememberModifier(typeName)
end

local function getModifierSearchState(idSuffix)
  local state = modifierSearchStates[idSuffix]
  if not state then
    state = {
      query = im.ArrayChar(MODIFIER_SEARCH_INPUT_LEN, ""),
      highlightedIdx = 1,
      focusInput = false,
      lastQuery = "",
    }
    modifierSearchStates[idSuffix] = state
  end
  return state
end

local function modifierSearchWords(text)
  local normalized = tostring(text or ''):gsub('([a-z0-9])([A-Z])', '%1 %2'):lower()
  normalized = normalized:gsub('[^%w]+', ' ')

  local words = {}
  for word in normalized:gmatch('%S+') do
    table.insert(words, word)
  end
  return words
end

local function wordsMatchInOrder(candidateWords, queryWords)
  if #queryWords == 0 then return true end

  local candidateIdx = 1
  for _, queryWord in ipairs(queryWords) do
    local matched = false
    while candidateIdx <= #candidateWords do
      local candidateWord = candidateWords[candidateIdx]
      candidateIdx = candidateIdx + 1
      if candidateWord:sub(1, #queryWord) == queryWord then
        matched = true
        break
      end
    end
    if not matched then return false end
  end

  return true
end

local function modifierMatchesSearch(typeName, queryWords)
  return wordsMatchInOrder(modifierSearchWords(modifierLabel(typeName)), queryWords)
    or wordsMatchInOrder(modifierSearchWords(typeName), queryWords)
end

local function orderedModifierTypes()
  local out = {}
  local added = {}

  for _, group in ipairs(atomicGroups or {}) do
    for _, typeName in ipairs(group.items or {}) do
      if not added[typeName] then
        table.insert(out, typeName)
        added[typeName] = true
      end
    end
  end

  for _, typeName in ipairs(atomicTypes or {}) do
    if not added[typeName] then
      table.insert(out, typeName)
      added[typeName] = true
    end
  end

  return out
end

local function modifierSearchResults(query)
  local queryWords = modifierSearchWords(query)
  local out = {}
  local added = {}

  local function appendIfMatched(typeName)
    if not added[typeName] and modifierTypes and modifierTypes[typeName] and modifierMatchesSearch(typeName, queryWords) then
      table.insert(out, typeName)
      added[typeName] = true
    end
  end

  for _, typeName in ipairs(recentModifierOptions()) do
    appendIfMatched(typeName)
  end

  for _, typeName in ipairs(orderedModifierTypes()) do
    appendIfMatched(typeName)
  end

  return out
end

local function commitModifierSearchResult(pacenote, slotName, state, results)
  local typeName = results[state.highlightedIdx]
  if not typeName then return end

  selectModifier(pacenote, slotName, typeName)
  state.highlightedIdx = 1
  state.lastQuery = ''
  ffi.copy(state.query, '')
  im.CloseCurrentPopup()
end

local function closeModifierSearchPopup(state)
  state.highlightedIdx = 1
  state.lastQuery = ''
  ffi.copy(state.query, '')
  im.CloseCurrentPopup()
end

local function refreshAfterCornerEdit(pn)
  -- in-place edits to the corner item; order is unchanged so just refresh phrases
  pn:refreshStructured()
  markValidationDirty()
end

-- ---------------------------------------------------------------------------
-- Audio preview
-- ---------------------------------------------------------------------------

local function noteTextPreview(pacenote)
  if pacenote:isAudioModeStructuredOffline() then
    return pacenote:noteOutputStructuredOffline()
  end
  return pacenote:noteOutputStructuredOnline()
end

local function drawPreview(pacenote)
  local noteText = noteTextPreview(pacenote)

  im.PushFont3("cairo_semibold_large")
  im.Text(dumps(noteText))
  im.PopFont()

  local audioItems = nil
  if pacenote:getAudioMode() == RallyEnums.pacenoteAudioMode.structuredOnline then
    audioItems = pacenote:audioItemsStructuredOnline({ includeMissingVariant = true })
  elseif pacenote:getAudioMode() == RallyEnums.pacenoteAudioMode.structuredOffline then
    audioItems = pacenote:audioItemsStructuredOffline({ includeMissingVariant = true })
  end

  if not audioItems then return end

  for i, audioItem in ipairs(audioItems) do
    local candidates = type(audioItem) == 'table' and audioItem.candidates or nil
    local fname = candidates and candidates[1] and candidates[1].fname or audioItem
    local displayFname = type(fname) == 'string' and fname or ''
    local file_exists = candidates and #candidates > 0 or (type(fname) == 'string' and FS:fileExists(fname))
    local voicePlayClr = file_exists and im.ImVec4(1, 1, 1, 1) or im.ImVec4(1, 0, 0, 1)
    local tooltipStr
    if candidates and #candidates > 0 then
      tooltipStr = string.format("\"%s\"\nPlay one of %d pacenote audio variants.\nFirst candidate: %s\n\nClick to copy chosen path to clipboard.", noteText[i], #candidates, displayFname)
    elseif file_exists then
      tooltipStr = "\""..noteText[i].."\"\nPlay pacenote audio file:\n"..displayFname.."\n\nClick to copy path to clipboard."
    else
      tooltipStr = "\""..noteText[i].."\"\nPacenote audio file not found:\n"..displayFname.."\n\nClick to copy path to clipboard."
    end

    if editor.uiIconImageButton(editor.icons.play_circle_filled, im.ImVec2(20, 20), voicePlayClr) then
      if candidates and #candidates > 0 then
        local candidate = voicepack.chooseAudioCandidate(candidates)
        fname = candidate and candidate.fname or fname
      end
      fname = type(fname) == 'string' and fname or ''
      im.SetClipboardText(fname)
      if file_exists then
        Engine.Audio.intercomPlayPacenote({ filename=fname })
      end
    end
    im.tooltip(tooltipStr)
    if i < #audioItems then
      im.SameLine()
    end
  end
end

local function slotSpacing()
  im.Spacing()
  im.Spacing()
  im.Spacing()
end

local function drawSegmentedRow(id, currentValue, options, onSelect, clearValue, tooltip)
  for i, opt in ipairs(options or {}) do
    local selected = currentValue == opt.value
    if selected then
      im.PushStyleColor2(im.Col_Button, im.GetStyleColorVec4(im.Col_ButtonActive))
      im.PushStyleColor2(im.Col_ButtonHovered, im.GetStyleColorVec4(im.Col_ButtonActive))
    end

    if im.Button(opt.label .. '##' .. id .. tostring(i)) then
      if selected and clearValue ~= nil then
        onSelect(clearValue)
      elseif not selected then
        onSelect(opt.value)
      end
    end
    if tooltip then im.tooltip(tooltip) end

    if selected then
      im.PopStyleColor(2)
    end

    if i < #options then
      im.SameLine()
    end
  end
end

-- ---------------------------------------------------------------------------
-- Section drawers
-- ---------------------------------------------------------------------------

local function drawCautionSection(pacenote)
  if not cautionCfg or not cautionCfg.levels then return end

  local current = pacenote:cautionLevel()
  local levels = {}
  for k in pairs(cautionCfg.levels) do table.insert(levels, k) end
  table.sort(levels)

  local options = {}
  for _, level in ipairs(levels) do
    table.insert(options, { label = cautionCfg.levels[level] or tostring(level), value = level })
  end

  drawSegmentedRow('structuredCaution', current, options, function(value)
    if value == nil or value == false then
      setSlot(pacenote, 'caution', nil)
    else
      setSlot(pacenote, 'caution', { type = 'caution', level = value })
    end
  end, false)
end

local function drawModifierSearchPopup(pacenote, slotName, idSuffix, current)
  local state = getModifierSearchState(idSuffix)
  local popupName = 'structuredModSearchPopup'..idSuffix

  if im.BeginPopup(popupName) then
    im.Text('Search modifier')
    if state.focusInput then
      im.SetKeyboardFocusHere()
      state.focusInput = false
    end

    im.SetNextItemWidth(FIELD_WIDTH + 40)
    local entered = im.InputText('##structuredModSearchInput'..idSuffix, state.query, nil, im.flags(im.InputTextFlags_EnterReturnsTrue))
    local query = ffi.string(state.query)
    if state.lastQuery ~= query then
      state.highlightedIdx = 1
      state.lastQuery = query
    end

    local results = modifierSearchResults(query)
    if #results > 0 and state.highlightedIdx > #results then
      state.highlightedIdx = #results
    elseif state.highlightedIdx < 1 then
      state.highlightedIdx = 1
    end

    local movedSelection = false
    if #results > 0 then
      if im.IsKeyPressed(im.GetKeyIndex(im.Key_DownArrow)) then
        state.highlightedIdx = state.highlightedIdx + 1
        if state.highlightedIdx > #results then
          state.highlightedIdx = 1
        end
        movedSelection = true
      elseif im.IsKeyPressed(im.GetKeyIndex(im.Key_UpArrow)) then
        state.highlightedIdx = state.highlightedIdx - 1
        if state.highlightedIdx < 1 then
          state.highlightedIdx = #results
        end
        movedSelection = true
      end
    end

    if entered then
      commitModifierSearchResult(pacenote, slotName, state, results)
    end

    if im.Selectable1('-##structuredModSearchClear'..idSuffix, current == nil) then
      setSlot(pacenote, slotName, nil)
      closeModifierSearchPopup(state)
    end
    im.Separator()

    if #results == 0 then
      im.Text('No matches')
    else
      im.BeginChild1('##structuredModSearchResults'..idSuffix, im.ImVec2(FIELD_WIDTH + 40, MODIFIER_SEARCH_RESULT_HEIGHT), false)
      for i, typeName in ipairs(results) do
        local label = modifierLabel(typeName)
        if current and current.type == typeName then
          label = label .. ' (current)'
        end

        if im.Selectable1(label..'##structuredModSearchResult'..idSuffix..typeName, state.highlightedIdx == i) then
          selectModifier(pacenote, slotName, typeName)
          closeModifierSearchPopup(state)
        end
        if movedSelection and state.highlightedIdx == i then
          im.SetScrollHereY(0.5)
        end
        if im.IsItemHovered() then
          state.highlightedIdx = i
        end
      end
      im.EndChild()
    end

    im.EndPopup()
  end
end

local function drawModifierMenu(pacenote, slotName, label, idSuffix)
  if not atomicTypes or #atomicTypes == 0 then return end

  local slots = readSlots(pacenote)
  local current = nil
  if slotName == 'preMod1' then
    current = slots.preMods[1]
  elseif slotName == 'preMod2' then
    current = slots.preMods[2]
  elseif slotName == 'postMod1' then
    current = slots.postMods[1]
  elseif slotName == 'postMod2' then
    current = slots.postMods[2]
  else
    current = slots[slotName]
  end

  local currentLabel = current and modifierLabel(current.type) or '-'

  im.SetNextItemWidth(FIELD_WIDTH)
  if im.BeginCombo('##structuredMod'..idSuffix, currentLabel, im.ComboFlags_HeightLargest) then
    if im.Selectable1('-', current == nil) then
      setSlot(pacenote, slotName, nil)
    end
    local recentOptions = recentModifierOptions()
    if #recentOptions > 0 and im.BeginMenu('<recent>##structuredModRecent'..idSuffix) then
      for _, typeName in ipairs(recentOptions) do
        local isSelected = current and current.type == typeName
        if im.Selectable1(modifierLabel(typeName)..'##structuredModRecent'..idSuffix..typeName, isSelected) then
          selectModifier(pacenote, slotName, typeName)
        end
      end
      im.EndMenu()
    end
    for _, group in ipairs(atomicGroups or {}) do
      if im.BeginMenu(group.label .. '##structuredModGroup'..idSuffix..group.id) then
        for _, typeName in ipairs(group.items) do
          local isSelected = current and current.type == typeName
          if im.Selectable1(modifierLabel(typeName), isSelected) then
            selectModifier(pacenote, slotName, typeName)
          end
        end
        im.EndMenu()
      end
    end
    im.EndCombo()
  end
  im.SameLine()
  if editor.uiIconImageButton(editor.icons.search, im.ImVec2(20, 20), nil, nil, nil, 'structuredModSearchButton'..idSuffix) then
    local state = getModifierSearchState(idSuffix)
    state.highlightedIdx = 1
    state.focusInput = true
    state.lastQuery = ''
    ffi.copy(state.query, '')
    im.OpenPopup('structuredModSearchPopup'..idSuffix)
  end
  im.tooltip('Search modifiers')
  drawModifierSearchPopup(pacenote, slotName, idSuffix, current)
  if label and label ~= '' then
    im.SameLine()
    im.Text(label)
  end
end

local function findOptionByValue(options, value)
  if not options then return nil end
  for _, opt in ipairs(options) do
    if opt.value == value then return opt end
  end
  return nil
end

local function setCornerShape(corner, shape)
  corner.shape = shape
end

local coreShapeValues = {
  tightens = true,
  opens = true,
}

local function hasShapeOption(value)
  return findOptionByValue(shapeOptions, value) ~= nil
end

local function drawShapeButton(pacenote, corner, id, label, value, tooltip)
  local selected = corner.shape == value
  if selected then
    im.PushStyleColor2(im.Col_Button, im.GetStyleColorVec4(im.Col_ButtonActive))
    im.PushStyleColor2(im.Col_ButtonHovered, im.GetStyleColorVec4(im.Col_ButtonActive))
  end

  if im.Button(label .. '##structuredCornerShape' .. id) then
    if selected then
      setCornerShape(corner, nil)
    else
      setCornerShape(corner, value)
    end
    refreshAfterCornerEdit(pacenote)
  end
  if tooltip then im.tooltip(tooltip) end

  if selected then
    im.PopStyleColor(2)
  end
end

local function canDrawPrimaryShapeButtons()
  return hasShapeOption('tightens') or hasShapeOption('opens')
end

local function drawPrimaryShapeButtons(pacenote, corner)
  local drewButton = false
  if hasShapeOption('tightens') then
    drawShapeButton(pacenote, corner, 'Tightens', 'tightens', 'tightens')
    drewButton = true
  end
  if hasShapeOption('opens') then
    if drewButton then im.SameLine() end
    drawShapeButton(pacenote, corner, 'Opens', 'opens', 'opens')
  end
end

local function drawExtraShapeDropdown(pacenote, corner)
  local options = {}
  for _, opt in ipairs(shapeOptions or {}) do
    if opt.value ~= nil and not coreShapeValues[opt.value] then
      table.insert(options, opt)
    end
  end
  if #options == 0 then return end

  local current = corner.shape
  local match = findOptionByValue(options, current)
  local currLabel = match and match.label or '-'
  im.SetNextItemWidth(FIELD_WIDTH)
  if im.BeginCombo('##structuredCornerExtraShape', currLabel) then
    if im.Selectable1('-', match == nil) then
      setCornerShape(corner, nil)
      refreshAfterCornerEdit(pacenote)
    end
    for _, opt in ipairs(options) do
      if im.Selectable1(opt.label, current == opt.value) then
        setCornerShape(corner, opt.value)
        refreshAfterCornerEdit(pacenote)
      end
    end
    im.EndCombo()
  end
  im.Spacing()
end

local function setSignedCornerStep(corner, fieldName, value)
  local step = tonumber(value) or 0
  if step == 0 then
    corner[fieldName] = nil
  else
    corner[fieldName] = step > 0 and 1 or -1
  end
end

local function drawCornerStepRow(pacenote, corner, fieldName, options, tooltip)
  local current = tonumber(corner[fieldName]) or 0
  drawSegmentedRow('structuredCorner'..fieldName, current, options, function(value)
    setSignedCornerStep(corner, fieldName, value)
    refreshAfterCornerEdit(pacenote)
  end, 0, tooltip)
end

local function lengthModeForCorner(corner)
  if corner.lengthMode == 'shorter' or corner.lengthMode == 'longer' or corner.lengthMode == 'skip' then
    return corner.lengthMode
  end
  return nil
end

local function setCornerLengthMode(corner, mode)
  if mode == 'shorter' or mode == 'longer' or mode == 'skip' then
    corner.lengthMode = mode
  else
    corner.lengthMode = nil
  end
end

local function drawCornerLengthModeRow(pacenote, corner)
  local current = lengthModeForCorner(corner)
  drawSegmentedRow(
    'structuredCornerLengthMode',
    current,
    {
      { label = 'feels shorter', value = 'shorter' },
      { label = 'feels longer', value = 'longer' },
      { label = 'skip length', value = 'skip' },
    },
    function(value)
      setCornerLengthMode(corner, value)
      refreshAfterCornerEdit(pacenote)
    end,
    false,
    "Controls how much corner length detail is spoken without changing measured geometry."
  )
end

local distanceMeasureWaypointOptions = {
  { label = 'corner start (green)', value = 'cs' },
  { label = 'corner end (red)', value = 'ce' },
}

local function distanceMeasureWaypointLabel(value)
  for _, opt in ipairs(distanceMeasureWaypointOptions) do
    if opt.value == value then return opt.label end
  end
  return 'corner end (red)'
end

local function refreshDistanceCalls(pacenote)
  if pacenote.notebook and pacenote.notebook.autofillDistanceCalls then
    pacenote.notebook:autofillDistanceCalls()
    pacenote.notebook:refreshAllPacenotes()
  end
  markValidationDirty()
end

local function dropdownSlowReleaseTypes()
  local keys = {}
  for k, _ in pairs(RallyEnums.slowCornerReleaseTypeName) do
    table.insert(keys, k)
  end

  table.sort(keys)

  local types = {}
  for _, k in ipairs(keys) do
    table.insert(types, { k, RallyEnums.slowCornerReleaseTypeName[k] })
  end

  return types
end

local function drawSlowCornerReleaseType(pacenote)
  local currReleaseType = pacenote:getSlowCornerReleaseType()
  local currVal = RallyEnums.slowCornerReleaseTypeName[currReleaseType]
  im.SetNextItemWidth(FIELD_WIDTH)
  if im.BeginCombo('Slow Corner Release Type##slowCornerReleaseType', currVal) then
    for _, triggerType in ipairs(dropdownSlowReleaseTypes()) do
      local k = triggerType[1]
      local v = triggerType[2]
      if im.Selectable1(v, k == currReleaseType) then
        pacenote:setSlowCornerReleaseType(k)
        markValidationDirty()
      end
    end
    im.EndCombo()
  end
  im.SameLine()
  im.TextColored(im.ImVec4(0, 1, 1, 1), "(?)")
  im.tooltip("The point along this corner at which the slow corner is considered done.\nUntil that point is reached, the next pacenote's call is delayed.")
end

local function drawCornerSection(pacenote)
  if not cornerCfg then return end

  local hasCorner = pacenote:hasCorner()
  local checkedPtr = im.BoolPtr(hasCorner)
  if im.Checkbox("Has Corner", checkedPtr) then
    if checkedPtr[0] and not hasCorner then
      setSlot(pacenote, 'corner', { type = 'corner' })
    elseif not checkedPtr[0] and hasCorner then
      setSlot(pacenote, 'corner', nil)
    end
  end
  im.tooltip("This pacenote has a corner.")
  im.SameLine()
  if im.Checkbox("Slow Corner", im.BoolPtr(pacenote.slowCorner)) then
    pacenote:toggleSlowCorner()
    if pacenote.notebook and pacenote.notebook.autofillDistanceCalls then
      pacenote.notebook:autofillDistanceCalls()
    end
    if pacenote.notebook and pacenote.notebook.refreshAllPacenotes then
      pacenote.notebook:refreshAllPacenotes()
    end
    markValidationDirty()
  end
  im.tooltip("Default: unchecked\nWhen checked, the next corner will be delayed until this corner is reached.")

  local corner = pacenote:corner()
  if not corner then
    return
  end

  -- Shape/change controls
  if shapeOptions and #shapeOptions > 0 then
    if canDrawPrimaryShapeButtons() then
      drawPrimaryShapeButtons(pacenote, corner)
      drawExtraShapeDropdown(pacenote, corner)
    else
      local current = corner.shape
      local match = findOptionByValue(shapeOptions, current)
      local currLabel = match and match.label or '-'
      im.SetNextItemWidth(FIELD_WIDTH)
      if im.BeginCombo('##structuredCornerShape', currLabel) then
        for _, opt in ipairs(shapeOptions) do
          if im.Selectable1(opt.label, current == opt.value) then
            setCornerShape(corner, opt.value)
            refreshAfterCornerEdit(pacenote)
          end
        end
        im.EndCombo()
      end
    end
  end

  -- Descriptor controls
  if descriptorOptions and #descriptorOptions > 0 then
    local buttonOptions = {}
    for _, opt in ipairs(descriptorOptions) do
      if opt.value ~= nil then
        table.insert(buttonOptions, opt)
      end
    end

    drawSegmentedRow('structuredCornerDescriptor', corner.descriptor, buttonOptions, function(value)
      corner.descriptor = value ~= false and value or nil
      refreshAfterCornerEdit(pacenote)
    end, false)
    im.Spacing()
  end

  drawCornerStepRow(
    pacenote,
    corner,
    'riskIntensity',
    {
      { label = 'more risky', value = 1 },
      { label = 'less risky', value = -1 },
    },
    "Adjusts the spoken/visual corner intensity by one style step without changing measured geometry."
  )

  drawCornerLengthModeRow(pacenote, corner)

end

local function drawDistanceSection(pacenote)
  local includeLinkPtr = im.BoolPtr(pacenote.includeLinkWord ~= false)
  if im.Checkbox("Include link word", includeLinkPtr) then
    pacenote:toggleIncludeLinkWord()
    refreshDistanceCalls(pacenote)
  end
  im.SameLine()
  im.TextColored(im.ImVec4(0, 1, 1, 1), "(?)")
  im.tooltip("Default: checked\nControls the incoming link word spoken before this pacenote, such as \"into\" or \"and\".")

  local includeDistance = not pacenote.ignoreDistanceCalls
  local ptr = im.BoolPtr(includeDistance)
  if im.Checkbox("Include distance call", ptr) then
    pacenote:toggleIgnoreDistanceCalls()
    refreshDistanceCalls(pacenote)
  end
  im.SameLine()
  im.TextColored(im.ImVec4(0, 1, 1, 1), "(?)")
  im.tooltip("Default: checked\nControls the distance/link call from this pacenote to the next pacenote.")

  local distanceBeforeModifierPtr = im.BoolPtr(pacenote.distanceBeforeModifier == true)
  if im.Checkbox("Distance before modifier", distanceBeforeModifierPtr) then
    pacenote:toggleDistanceBeforeModifier()
    pacenote:refreshStructured()
    markValidationDirty()
  end
  im.SameLine()
  im.TextColored(im.ImVec4(0, 1, 1, 1), "(?)")
  im.tooltip("Default: unchecked\nWhen checked, long distance calls are spoken before the after modifier.")

  local resetOdometerPtr = im.BoolPtr(not pacenote.isolate)
  if im.Checkbox("Reset Odometer", resetOdometerPtr) then
    if pacenote.isolate == resetOdometerPtr[0] then
      pacenote:toggleIsolate()
    end
    refreshDistanceCalls(pacenote)
  end
  im.SameLine()
  im.TextColored(im.ImVec4(0, 1, 1, 1), "(?)")
  im.tooltip("Default: checked\nReset the automatic odometer after the pacenote used for calculating distance calls.\n\nWhen unchecked, this pacenote will be skipped and the distance\ncall will be calculated between the previous and next pacenotes.")

  local current = pacenote.getDistanceMeasureWaypoint and pacenote:getDistanceMeasureWaypoint() or 'ce'
  im.SetNextItemWidth(FIELD_WIDTH)
  if im.BeginCombo("Distance measure waypoint##distanceMeasureWaypoint", distanceMeasureWaypointLabel(current)) then
    for _, opt in ipairs(distanceMeasureWaypointOptions) do
      if im.Selectable1(opt.label, opt.value == current) then
        pacenote:setDistanceMeasureWaypoint(opt.value)
        refreshDistanceCalls(pacenote)
      end
    end
    im.EndCombo()
  end
  im.tooltip("Default: corner end (red)\nControls which waypoint is used as the start point for the distance call to the next pacenote.")

  drawSlowCornerReleaseType(pacenote)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

M.draw = function(pacenote, pacenoteToolsWindow)
  activePacenoteToolsWindow = pacenoteToolsWindow

  if pacenote.id ~= lastPacenoteId then
    lastPacenoteId = pacenote.id
  end

  if not mapping then
    load(pacenote)
  end

  drawPreview(pacenote)

  im.Separator()

  im.HeaderText("Caution")
  drawCautionSection(pacenote)

  im.HeaderText("Modifiers Before")
  drawModifierMenu(pacenote, 'preMod1', "", "Pre1")
  drawModifierMenu(pacenote, 'preMod2', "", "Pre2")

  im.HeaderText("Corner")
  drawCornerSection(pacenote)

  im.HeaderText("Modifiers After")
  drawModifierMenu(pacenote, 'postMod1', "", "Post1")
  drawModifierMenu(pacenote, 'postMod2', "", "Post2")

  im.HeaderText("Distance")
  drawDistanceSection(pacenote)
end

M.clear = function()
  activePacenoteToolsWindow = nil
  mapping = nil
  componentTypes = nil
  modifierTypes = nil
  cornerCfg = nil
  cautionCfg = nil
  atomicTypes = nil
  atomicGroups = nil
  shapeOptions = nil
  descriptorOptions = nil
  modifierSearchStates = {}
end

return M
