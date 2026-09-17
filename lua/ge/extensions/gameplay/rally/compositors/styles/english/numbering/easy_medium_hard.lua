-- Shared English easy/medium/hard corner numbering metadata.

local clr = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/colors')

return {
  id = "easy_medium_hard",
  intensity = {
    { id = "hard",   text = "hard",   diameter = { min = 0,  max = 65 },  visual = { icon = "turn1", text = "", colorBg = clr.neonCrimson, colorStroke = clr.deepCrimson, colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
    { id = "medium", text = "medium", diameter = { min = 65, max = 190 }, visual = { icon = "turn3", text = "", colorBg = clr.neonGold,    colorStroke = clr.deepGold,    colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
    { id = "easy",   text = "easy",   diameter = { min = 190 },           visual = { icon = "turn6", text = "", colorBg = clr.neonGreen,   colorStroke = clr.deepGreen,   colorNoteIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg }},
  },
}
