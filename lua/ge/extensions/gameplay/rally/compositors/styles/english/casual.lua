-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--------------------------------WARNING----------------------------------
--------------------------------WARNING----------------------------------
--------------------------------WARNING----------------------------------
--                                                                     --
-- If you change any strings in this file that are used for pacenotes, --
-- you must regenerate the audio files.                                --
--                                                                     --
--------------------------------WARNING----------------------------------
--------------------------------WARNING----------------------------------
--------------------------------WARNING----------------------------------

local util = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/compositorUtil')
local clr = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/colors')
local numbering = require('/lua/ge/extensions/gameplay/rally/compositors/styles/english/numbering/easy_medium_hard')
local systemPacenotes = require('/lua/ge/extensions/gameplay/rally/compositors/styles/english/systemPacenotes')
local distance = require('/lua/ge/extensions/gameplay/rally/compositors/styles/english/distance')
local visual = require('/lua/ge/extensions/gameplay/rally/compositors/styles/english/visual')
local caution = require('/lua/ge/extensions/gameplay/rally/compositors/styles/english/caution')
local modifiers = require('/lua/ge/extensions/gameplay/rally/compositors/styles/english/modifiers')

local M = {}

local casualDistance = {
  callsEnabled = false,
  links = distance.links,
  units = distance.units,
  rounding = distance.rounding,
  max = distance.max,
}

local casualModifiers = {
  overJump = modifiers.overJump,

  crest = modifiers.crest,

  watersplash = modifiers.watersplash,

  ontoGravel = modifiers.ontoGravel,
  ontoIce = modifiers.ontoIce,
  ontoTarmac = modifiers.ontoTarmac,
  ontoMud = modifiers.ontoMud,
  slippy = modifiers.slippy,

  stop = modifiers.stop,
  toStop = modifiers.toStop,
  finish = modifiers.finish,

  chicaneLeftEntry = modifiers.chicaneLeftEntry,
  chicaneRightEntry = modifiers.chicaneRightEntry,
}

local casualModifierAliases = {
  jump = "overJump",
  badDipJump = "overJump",
  badJump = "overJump",
  bigJump = "overJump",

  brakeOverCrest = "crest",
  middleOverCrest = "crest",
  keepLeftOverCrest = "crest",
  keepMiddleOverCrest = "crest",
  keepRightOverCrest = "crest",
  overCrest = "crest",
  crestOnly = "crest",
  intoCrest = "crest",
  longCrest = "crest",
  bigCrest = "crest",
  smallCrest = "crest",

  water = "watersplash",
  intoWater = "watersplash",

  overFinish = "finish",
}

M.composite = util.compositeFromPhrases
M.enumerate = util.enumerateConcise

M.distance = casualDistance
M.visualGeneral = visual

M.componentTypes = {
    corner = {
      numberingSystem = numbering.id,
      numbering = numbering,
      direction = {
        [-1] = "left",
        [1] = "right",
      },
      descriptors = {
        flat   = { text = "flat",   visual = { icon = "turn6",  text = "FL", colorBg = clr.neonGreen,   colorStroke = clr.deepGreen,   colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
        square = { text = "square", visual = { icon = "turnSq", text = "SQ", colorBg = clr.neonOrange,  colorStroke = clr.deepOrange,  colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
        hairpin = { text = "hairpin", visual = { icon = "turnHp", text = "HP", colorBg = clr.neonCrimson, colorStroke = clr.deepCrimson, colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
      },
      descriptorAliases = {
        openHairpin = "hairpin",
        tightHairpin = "hairpin",
      },
      -- casual style intentionally omits length / shape details from spoken output.
    },

    caution = caution,

    modifiers = casualModifiers,
    modifierAliases = casualModifierAliases,
}

M.system = systemPacenotes

return M
