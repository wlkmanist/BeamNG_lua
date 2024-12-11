-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local re_util = require('/lua/ge/extensions/editor/rallyEditor/util')
local im  = ui_imgui
local logTag = 'rally'

local VisualPacenotesManager = require('/lua/ge/extensions/gameplay/notebook/structured/visualPacenotesManager')

local M = {}

local selectedStyle = re_util.getStructuredPacenoteStyle()

local mapping = nil
local galCorners = nil
local reverseMapping = nil
local vp = nil

local function readPacenotesTranslation(lang)
  local json = re_util.loadPacenotesTranslationFile(lang)

  if not json then
    log('E', logTag, 'couldnt find pacenotesTranslation file')
    error('couldnt find pacenotesTranslation file')
  end

  return json
end

local function dumpPacenote(pacenote)
  dump(pacenote.structured.fields)
end

-- Function to generate galCorners based on selected style and direction
local function generateGalCorners(style)
  local galCorners = {}

  table.insert(galCorners, { "<none>", "-1" })

  for i, cornerCall in ipairs(mapping.styles[style]) do
    table.insert(galCorners, { cornerCall.name, tostring(cornerCall.cornerSeverity) })
  end

  return galCorners
end

local function generateReverseMapping(mapping)
  local reverseMapping = {}
  for _, cornerCall in ipairs(mapping) do
    reverseMapping[tostring(cornerCall.cornerSeverity)] = cornerCall.name
  end
  return reverseMapping
end

local function loadMapping(lang, pacenote)
  mapping = readPacenotesTranslation(lang)
  galCorners = generateGalCorners(selectedStyle)

  reverseMapping = generateReverseMapping(mapping.styles[selectedStyle])
  dump(reverseMapping)

  vp = VisualPacenotesManager()
  vp:load()

  -- dump(mapping)
  -- dump(galCorners)
end

local function updateDirection(pacenote, val)
  pacenote.structured.fields.cornerDirection = val
  pacenote:updateStructured()
  -- dumpPacenote(pacenote)
end

local function noteTextPreview(pacenote)
  local lang = pacenote.notebook:selectedCodriverLanguage()
  local note = pacenote:joinedStructured(lang)
  return dumps(note)
end

M.draw = function(pacenote, lang)
  if not mapping then
    loadMapping(lang, pacenote)
  end

  im.HeaderText("Structured - Corner")

  im.PushFont3("cairo_semibold_large")
  im.Text(noteTextPreview(pacenote))
  im.PopFont()

  -- TODO: use radio buttons. Direction toggle buttons (Right/Left).
  if im.Button("Left") then
    updateDirection(pacenote, -1)
  end
  im.SameLine()
  if im.Button("Straight") then
    updateDirection(pacenote, 0)
  end
  im.SameLine()
  if im.Button("Right") then
    updateDirection(pacenote, 1)
  end

  im.SetNextItemWidth(250)
  if im.BeginCombo('##structuredCorner', (reverseMapping or {})[pacenote.structured.fields.cornerSeverity] or "-") then
    for i, cornerCall in ipairs(galCorners) do
      local name, severity = cornerCall[1], cornerCall[2]
      if im.Selectable1(name, name == (reverseMapping)[pacenote.structured.fields.cornerSeverity]) then
        pacenote.structured.fields.cornerSeverity = severity
        pacenote.structured.fields.cornerChange = 0
        pacenote.structured.fields.cornerLength = 0
        if pacenote.structured.fields.cornerDirection == nil then
          pacenote.structured.fields.cornerDirection = 0
        end
        pacenote:updateStructured()
      end
    end
    im.EndCombo()
  end

  if vp then
    local visualPacenotes = vp:determineVisualPacenotes(pacenote.structured.fields)
    im.Text(string.format("Icons: %s", dumps(visualPacenotes)))
  end

  im.HeaderText("Structured - Modifiers")

  local addModifier = function(pacenote, uiLabel, fieldName)
    if im.Checkbox(uiLabel, im.BoolPtr(pacenote.structured.fields[fieldName] or false)) then
      pacenote.structured.fields[fieldName] = not pacenote.structured.fields[fieldName]
      pacenote:updateStructured()
    end
  end
  addModifier(pacenote, "Square",        "modSquare")
  addModifier(pacenote, "Don't Cut",     "modDontCut")
  addModifier(pacenote, "Narrows",       "modNarrows")
  addModifier(pacenote, "Bumps",         "modBumps")
  addModifier(pacenote, "Jump",          "modJump")
  addModifier(pacenote, "Over Crest",    "modCrest")
  addModifier(pacenote, "Water",         "modWater")
  addModifier(pacenote, "Caution",       "modCaution1")
  addModifier(pacenote, "Double Caution","modCaution2")
  addModifier(pacenote, "Triple Caution","modCaution3")
end

return M
