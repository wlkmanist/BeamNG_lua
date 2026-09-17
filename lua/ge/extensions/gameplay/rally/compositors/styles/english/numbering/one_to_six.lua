-- Shared English 1-6 corner numbering metadata.
-- Existing style files own final string/audio compatibility; this module is
-- intended for new composed styles and calibration tooling.

local clr = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/colors')

return {
  id = "one_to_six",
  intensity = {
    { id = "one",   text = "one",   diameter = { min = 0,   max = 35 },  visual = { icon = "turn1", text = "1", colorBg = clr.neonCrimson, colorStroke = clr.deepCrimson, colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
    { id = "two",   text = "two",   diameter = { min = 35,  max = 65 },  visual = { icon = "turn2", text = "2", colorBg = clr.neonOrange, colorStroke = clr.deepOrange, colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
    { id = "three", text = "three", diameter = { min = 65,  max = 116 }, visual = { icon = "turn3", text = "3", colorBg = clr.neonGold, colorStroke = clr.deepGold, colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
    { id = "four",  text = "four",  diameter = { min = 116, max = 190 }, visual = { icon = "turn4", text = "4", colorBg = clr.neonCyan, colorStroke = clr.deepCyan, colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
    { id = "five",  text = "five",  diameter = { min = 190, max = 260 }, visual = { icon = "turn5", text = "5", colorBg = clr.neonBlue, colorStroke = clr.deepBlue, colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
    { id = "six",   text = "six",   diameter = { min = 260 },            visual = { icon = "turn6", text = "6", colorBg = clr.neonGreen, colorStroke = clr.deepGreen, colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
  },
  -- Length bucket ids are defined by this style, not referenced from a separate
  -- registry. Use the same id across intensities for the same semantic length.
  -- note: do not change the hand tuned values without consulting the user.
  lengthsByIntensity = {
    one = {
      { id = "short",     text = "short",      arcMeters = { min = 0,   max = 6  } }, -- hand tuned
      { id = "standard",  text = nil,          arcMeters = { min = 6,   max = 35 } }, -- hand tuned
      { id = "halfLong",  text = "half long",  arcMeters = { min = 35,  max = 47 } },
      { id = "long",      text = "long",       arcMeters = { min = 47,  max = 60 } },
      { id = "extraLong", text = "extra long", arcMeters = { min = 60           } },
    },
    two = {
      { id = "short",     text = "short",      arcMeters = { min = 0,   max = 6  } }, -- hand tuned
      { id = "standard",  text = nil,          arcMeters = { min = 6,   max = 55 } }, -- hand tuned
      { id = "halfLong",  text = "half long",  arcMeters = { min = 55,  max = 65 } },
      { id = "long",      text = "long",       arcMeters = { min = 65,  max = 75 } }, -- hand tuned
      { id = "extraLong", text = "extra long", arcMeters = { min = 75           } },
    },
    three = {
      { id = "short",     text = "short",      arcMeters = { min = 0,   max = 28 } },
      { id = "standard",  text = nil,          arcMeters = { min = 28,  max = 60 } },
      { id = "halfLong",  text = "half long",  arcMeters = { min = 60,  max = 77 } },
      { id = "long",      text = "long",       arcMeters = { min = 77,  max = 95 } },
      { id = "extraLong", text = "extra long", arcMeters = { min = 95           } },
    },
    four = {
      { id = "short",     text = "short",      arcMeters = { min = 0,   max = 37  } }, -- hand tuned
      { id = "standard",  text = nil,          arcMeters = { min = 37,  max = 85  } }, -- hand tuned
      { id = "halfLong",  text = "half long",  arcMeters = { min = 85,  max = 107 } },
      { id = "long",      text = "long",       arcMeters = { min = 107, max = 130 } },
      { id = "extraLong", text = "extra long", arcMeters = { min = 130            } },
    },
    five = {
      { id = "short",     text = "short",      arcMeters = { min = 0,   max = 42  } },
      { id = "standard",  text = nil,          arcMeters = { min = 42,  max = 100 } }, -- hand tuned
      { id = "halfLong",  text = "half long",  arcMeters = { min = 100, max = 125 } },
      { id = "long",      text = "long",       arcMeters = { min = 125, max = 150 } }, -- hand tuned
      { id = "extraLong", text = "extra long", arcMeters = { min = 150            } },
    },
    six = {
      { id = "short",     text = "short",      arcMeters = { min = 0,   max = 50  } },
      { id = "standard",  text = nil,          arcMeters = { min = 50,  max = 100 } },
      { id = "halfLong",  text = "half long",  arcMeters = { min = 100, max = 140 } },
      { id = "long",      text = "long",       arcMeters = { min = 140, max = 180 } },
      { id = "extraLong", text = "extra long", arcMeters = { min = 180            } },
    },
  },
}
