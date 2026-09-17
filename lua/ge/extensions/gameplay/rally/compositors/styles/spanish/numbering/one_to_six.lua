-- Shared Spanish 1-6 corner numbering metadata.

local clr = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/colors')

return {
  id = "one_to_six",
  intensity = {
    { id = "one",   text = "uno",    diameter = { min = 0,   max = 35 },  visual = { icon = "turn1", text = "1", colorBg = clr.red550,    colorStroke = clr.red650,    colorNoteIcon = clr.iconAndTextDefault, colorNoteText = clr.iconAndTextDefault }},
    { id = "two",   text = "dos",    diameter = { min = 35,  max = 65 },  visual = { icon = "turn2", text = "2", colorBg = clr.orange,    colorStroke = clr.orange500, colorNoteIcon = clr.iconAndTextDefault, colorNoteText = clr.iconAndTextDefault }},
    { id = "three", text = "tres",   diameter = { min = 65,  max = 116 }, visual = { icon = "turn3", text = "3", colorBg = clr.yellow400, colorStroke = clr.yellow500, colorNoteIcon = clr.iconAndTextDefault, colorNoteText = clr.iconAndTextDefault }},
    { id = "four",  text = "cuatro", diameter = { min = 116, max = 190 }, visual = { icon = "turn4", text = "4", colorBg = clr.peach300,  colorStroke = clr.peach400,  colorNoteIcon = clr.iconAndTextDefault, colorNoteText = clr.iconAndTextDefault }},
    { id = "five",  text = "cinco",  diameter = { min = 190, max = 260 }, visual = { icon = "turn5", text = "5", colorBg = clr.blue500,   colorStroke = clr.blue600,   colorNoteIcon = clr.iconAndTextDefault, colorNoteText = clr.iconAndTextDefault }},
    { id = "six",   text = "seis",   diameter = { min = 260 },            visual = { icon = "turn6", text = "6", colorBg = clr.green500,  colorStroke = clr.green600,  colorNoteIcon = clr.iconAndTextDefault, colorNoteText = clr.iconAndTextDefault }},
  },
  lengthsByIntensity = {
    one = {
      { id = "short", text = "corta", arcMeters = { min = 0, max = 6 } },
      { id = "standard", arcMeters = { min = 6, max = 35 } },
      { id = "halfLong", text = "media larga", arcMeters = { min = 35, max = 47.5 } },
      { id = "long", text = "larga", arcMeters = { min = 47.5, max = 60 } },
      { id = "extraLong", text = "extra larga", arcMeters = { min = 60 } },
    },
    two = {
      { id = "short", text = "corta", arcMeters = { min = 0, max = 6 } },
      { id = "standard", arcMeters = { min = 6, max = 55 } },
      { id = "halfLong", text = "media larga", arcMeters = { min = 55, max = 65 } },
      { id = "long", text = "larga", arcMeters = { min = 65, max = 75 } },
      { id = "extraLong", text = "extra larga", arcMeters = { min = 75 } },
    },
    three = {
      { id = "short", text = "corta", arcMeters = { min = 0, max = 28 } },
      { id = "standard", arcMeters = { min = 28, max = 60 } },
      { id = "halfLong", text = "media larga", arcMeters = { min = 60, max = 77.5 } },
      { id = "long", text = "larga", arcMeters = { min = 77.5, max = 95 } },
      { id = "extraLong", text = "extra larga", arcMeters = { min = 95 } },
    },
    four = {
      { id = "short", text = "corta", arcMeters = { min = 0, max = 35 } },
      { id = "standard", arcMeters = { min = 35, max = 80 } },
      { id = "halfLong", text = "media larga", arcMeters = { min = 80, max = 105 } },
      { id = "long", text = "larga", arcMeters = { min = 105, max = 130 } },
      { id = "extraLong", text = "extra larga", arcMeters = { min = 130 } },
    },
    five = {
      { id = "short", text = "corta", arcMeters = { min = 0, max = 42 } },
      { id = "standard", arcMeters = { min = 42, max = 90 } },
      { id = "halfLong", text = "media larga", arcMeters = { min = 90, max = 120 } },
      { id = "long", text = "larga", arcMeters = { min = 120, max = 150 } },
      { id = "extraLong", text = "extra larga", arcMeters = { min = 150 } },
    },
    six = {
      { id = "short", text = "corta", arcMeters = { min = 0, max = 50 } },
      { id = "standard", arcMeters = { min = 50, max = 100 } },
      { id = "halfLong", text = "media larga", arcMeters = { min = 100, max = 140 } },
      { id = "long", text = "larga", arcMeters = { min = 140, max = 180 } },
      { id = "extraLong", text = "extra larga", arcMeters = { min = 180 } },
    },
  },
}
