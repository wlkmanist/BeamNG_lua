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
local numbering = require('/lua/ge/extensions/gameplay/rally/compositors/styles/english/numbering/one_to_six')
local systemPacenotes = require('/lua/ge/extensions/gameplay/rally/compositors/styles/english/systemPacenotes')
local distance = require('/lua/ge/extensions/gameplay/rally/compositors/styles/english/distance')
local visual = require('/lua/ge/extensions/gameplay/rally/compositors/styles/english/visual')
local caution = require('/lua/ge/extensions/gameplay/rally/compositors/styles/english/caution')
local modifiers = require('/lua/ge/extensions/gameplay/rally/compositors/styles/english/modifiers')

local M = {}

M.composite = util.compositeFromPhrases
M.enumerate = util.enumerateConcise

M.distance = distance
M.visualGeneral = visual

M.componentTypes = {
  -- structured: corner. Stored fields are physical units / canonical enums;
  -- this style maps them to language-specific labels and visuals.
  corner = {
    numberingSystem = numbering.id,
    numbering = numbering,
    direction = {
      [-1] = "left",
      [1] = "right",
    },
    shapes = {
      opens = { text = "opens", visual = { icon = "mathLessThan", colorIcon = clr.iconAndTextDefault } },
      tightens = { text = "tightens", visual = { icon = "mathGreaterThan", colorIcon = clr.iconAndTextDefault } },
      opensOverCrest = { text = "opens over crest", label = "opens over crest", visual = { icon = "crest", colorIcon = clr.iconAndTextDefault } },
      opensAndTightens = { text = "opens and tightens" },
      overCrest = { text = "over crest", label = "over crest", variant = "2", visual = { icon = "crest", colorIcon = clr.iconAndTextDefault } },
      tightensDown = { text = "tightens down", label = "tightens down", visual = { icon = "mathGreaterThan", colorIcon = clr.iconAndTextDefault } },
      tightensOverCrest = { text = "tightens over crest", label = "tightens over crest", visual = { icon = "crest", colorIcon = clr.iconAndTextDefault } },
      tightensAndOpens = { text = "tightens and opens" },
    },
    descriptors = {
      bare   = { text = "", label = "bare" },
      flat   = { text = "flat",   visual = { icon = "turn6",  text = "FL", colorBg = clr.neonGreen,   colorStroke = clr.deepGreen,   colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
      square = { text = "square", visual = { icon = "turnSq", text = "SQ", colorBg = clr.neonOrange,  colorStroke = clr.deepOrange,  colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
      hairpin = { text = "hairpin", visual = { icon = "turnHp", text = "HP", colorBg = clr.neonCrimson, colorStroke = clr.deepCrimson, colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
      openHairpin = { text = "open hairpin", label = "open hairpin", visual = { icon = "turnHp", text = "HP", colorBg = clr.neonCrimson, colorStroke = clr.deepCrimson, colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
      tightHairpin = { text = "tight hairpin", label = "tight hairpin", visual = { icon = "turnHp", text = "HP", colorBg = clr.neonCrimson, colorStroke = clr.deepCrimson, colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
    },
  },

  caution = caution,

  modifiers = modifiers,
}

M.system = systemPacenotes

return M
