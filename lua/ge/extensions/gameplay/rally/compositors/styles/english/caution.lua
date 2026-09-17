-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local clr = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/colors')

return {
  levels = {
    [1] = "care",
    [2] = "caution",
    [3] = "double caution",
  },
  levelVisuals = {
    [1] = { colorBg = clr.careBg, colorStroke = clr.careStroke, colorNoteIcon = clr.careIcon, colorNoteText = clr.careIcon },
    [2] = { colorBg = clr.cautionBg, colorStroke = clr.cautionStroke, colorNoteIcon = clr.cautionIcon, colorNoteText = clr.cautionIcon },
    [3] = { colorBg = clr.doubleCautionBg, colorStroke = clr.doubleCautionStroke, colorNoteIcon = clr.doubleCautionIcon, colorNoteText = clr.doubleCautionIcon },
  },
}
