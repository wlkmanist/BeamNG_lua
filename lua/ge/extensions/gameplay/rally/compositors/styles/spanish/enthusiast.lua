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
local numbering = require('/lua/ge/extensions/gameplay/rally/compositors/styles/spanish/numbering/one_to_six')
local systemPacenotes = require('/lua/ge/extensions/gameplay/rally/notebook/systemPacenotes')

local M = {}

M.composite = util.compositeFromPhrases
M.enumerate = util.enumerateConcise

M.distance = {
  links = {
    { threshold = 10, text = "en" },
    { threshold = 20, text = "para" },
    { threshold = 25, text = "para" },
  },
  units = {
    base = "m",
    large = "km",
    point = "punto"
  },
  rounding = {
    small = 10,
    medium = 50,
    mediumThreshold = 100,
    large = 250,
    largeThreshold = 1000
  },
  max = 5000,
}

M.visualGeneral = {
  intoColor = clr.iconAndTextDefault,
  distanceColor = clr.offWhite
}

M.componentTypes = {
    corner = {
      numberingSystem = numbering.id,
      numbering = numbering,
      direction = {
        [-1] = "izquierda",
        [1] = "derecha",
      },
      shapes = {
        opens = { text = "se abre", visual = { icon = "mathLessThan", colorIcon = clr.iconAndTextDefault } },
        tightens = { text = "se cierra", visual = { icon = "mathGreaterThan", colorIcon = clr.iconAndTextDefault } },
        opensThenTightens = { text = "se abre y se cierra" },
        tightensThenOpens = { text = "se cierra y se abre" },
      },
      descriptors = {
        bare   = { text = "", label = "bare" },
        square = { text = "ka",      visual = { icon = "turnSq", text = "SQ", colorBg = clr.orange,   colorStroke = clr.orange500, colorNoteIcon = clr.iconAndTextDefault, colorNoteText = clr.iconAndTextDefault }},
        hairpin = { text = "horquilla", visual = { icon = "turnHp", text = "HP", colorBg = clr.red550, colorStroke = clr.red650, colorNoteIcon = clr.iconAndTextDefault, colorNoteText = clr.iconAndTextDefault }},
        flat   = { text = "a fondo", visual = { icon = "turn6",  text = "FL", colorBg = clr.green500, colorStroke = clr.green600,  colorNoteIcon = clr.iconAndTextDefault, colorNoteText = clr.iconAndTextDefault }},
      },
    },

    caution = {
      levels = {
        [1] = "cuidado",
        [2] = "ojo",
        [3] = "peligro",
      },
      visual = { colorBg = clr.red550, colorStroke = clr.red650, colorNoteIcon = clr.iconAndTextDefault },
    },

    modifiers = {
      -- atomic: pre-corner instructions
      slowing = { text = "frenando", tags = { "pace" }, visual = { colorBg = clr.modifierBg, colorStroke = clr.modifierStroke, colorNoteIcon = clr.iconAndTextDefault } },
      brake   = { text = "freno",    tags = { "pace" }, visual = { colorBg = clr.modifierBg, colorStroke = clr.modifierStroke, colorNoteIcon = clr.iconAndTextDefault } },

      -- atomic: road features / hazards
      narrows = { text = "se estrecha",   tags = { "line" }, visual = { icon = "narrows",      colorIcon = clr.iconAndTextDefault, colorBg = clr.modifierBg, colorStroke = clr.modifierStroke } },
      water   = { text = "agua",          tags = { "surface", "hazard" }, visual = { icon = "water",        colorIcon = clr.iconAndTextDefault, colorBg = clr.modifierBg, colorStroke = clr.modifierStroke } },
      jump    = { text = "salto",         tags = { "jump", "air", "hazard" }, visual = { icon = "jumpOverBump", colorIcon = clr.iconAndTextDefault, colorBg = clr.modifierBg, colorStroke = clr.modifierStroke } },
      crest   = { text = "rasante",       tags = { "visibility", "vertical" }, visual = { icon = "crest",        colorIcon = clr.iconAndTextDefault, colorBg = clr.modifierBg, colorStroke = clr.modifierStroke } },
      bumpy   = { text = "zona bacheada", tags = { "surface" }, visual = { icon = "bumps",        colorIcon = clr.iconAndTextDefault, colorBg = clr.modifierBg, colorStroke = clr.modifierStroke } },
      bump    = { text = "con bache",     tags = { "surface", "vertical" }, visual = { icon = "bump",         colorIcon = clr.iconAndTextDefault, colorBg = clr.modifierBg, colorStroke = clr.modifierStroke } },

      -- atomic: line guidance / events
      dontCut = { text = "no cortar",  tags = { "line", "constraint" }, visual = { icon = "scissorsSlashed", colorIcon = clr.iconAndTextDefault } },
      finish  = { text = "cruzar meta", tags = { "event" }, visual = { icon = "finish",         colorIcon = clr.offWhite, colorBg = clr.offBlack, colorStroke = clr.offWhite } },
    },
}

M.system = systemPacenotes.localized({
  precountdown = "Buena suerte!",
  countdown5 = "cinco",
  countdown4 = "cuatro",
  countdown3 = "tres",
  countdown2 = "dos",
  countdown1 = "uno",
  countdowngo = "ya",
  warningSeconds60 = "60 segundos",
  warningSeconds30 = "30 segundos",
  warningSeconds15 = "15 segundos",
  warningSeconds10 = "10 segundos",
  commsCheck = "control de radio",
  beltsCheck = "revisa los cinturones",
  rescheduled = "Nuestra hora de salida ha sido reprogramada. Asegurate de que el coche este en la linea de salida.",
  falseStart = "Nos van a penalizar por salida en falso.",
})

return M
