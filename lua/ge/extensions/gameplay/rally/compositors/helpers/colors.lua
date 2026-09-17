-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared color palette for visual pacenote styles.
-- Values are CSS custom property references consumed by the visual pacenotes app.

local M = {}

-- general
M.offBlack = "var(--bng-off-black)"
M.offWhite = "var(--bng-off-white)"
M.iconAndTextDefault = M.offWhite
M.black = "#000000"
M.white = "#ffffff"

-- corners - intensity heat map
M.red550    = "var(--bng-add-red-550)"
M.red650    = "var(--bng-add-red-650)"
M.red750    = "var(--bng-add-red-750)"

M.orange    = "var(--bng-orange)"
M.orange500 = "var(--bng-orange-500)"

M.yellow400 = "var(--bng-ter-yellow-400)"
M.yellow500 = "var(--bng-ter-yellow-500)"

M.peach300  = "var(--bng-ter-peach-300)"
M.peach400  = "var(--bng-ter-peach-400)"

M.blue500   = "var(--bng-add-blue-500)"
M.blue600   = "var(--bng-add-blue-600)"

M.indigoblue650 = "var(--bng-add-indigoblue-650)"
M.indigoblue750 = "var(--bng-add-indigoblue-750)"

M.green500  = "var(--bng-add-green-500)"
M.green600  = "var(--bng-add-green-600)"

-- high contrast neon spectrum
M.neonCrimson = "#ff1744"
M.deepCrimson = "#c4002f"
M.neonOrange = "#ff8a00"
M.deepOrange = "#c96500"
M.neonGold = "#ffd600"
M.deepGold = "#c7a500"
M.neonCyan = "#00d5ff"
M.deepCyan = "#008fb3"
M.neonBlue = "#33a6ff"
M.deepBlue = "#005ecb"
M.neonGreen = "#00e676"
M.deepGreen = "#00a152"
M.mainPaletteFg = M.offBlack

-- cut guidance badges
M.cutBg = M.neonGreen
M.cutStroke = M.deepGreen
M.dontCutBg = M.neonCrimson
M.dontCutStroke = M.deepCrimson

-- caution visual pacenotes
M.careBg = M.offBlack
M.careStroke = "#ffff00"
M.careIcon = M.careStroke

M.cautionBg = M.offBlack
M.cautionStroke = "#ff0000"
M.cautionIcon = M.cautionStroke

M.doubleCautionBg = M.offBlack
M.doubleCautionStroke = "#ff0000"
M.doubleCautionIcon = M.doubleCautionStroke

-- modifiers
M.modifierBg = "#a855f7"
M.modifierStroke = "#7e22ce"

return M
