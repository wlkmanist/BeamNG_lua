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

local systemPacenotes = require('/lua/ge/extensions/gameplay/rally/notebook/systemPacenotes')

return systemPacenotes.localized({
  precountdown = {
    { text = "Good luck!", weight = 0.5 },
    { text = "Best of luck!", weight = 0.1 },
  },
  countdown5 = "five",
  countdown4 = "four",
  countdown3 = "three",
  countdown2 = "two",
  countdown1 = "one",
  countdowngo = "go",
  warningSeconds60 = "60 seconds",
  warningSeconds30 = "30 seconds",
  warningSeconds15 = "15 seconds",
  warningSeconds10 = "10 seconds",
  commsCheck = "intercom check",
  beltsCheck = "check your belts are tight.",
  rescheduled = "We've been given a new start minute. Make sure the car is staged at the start line.",
  falseStart = "You jumped the start.",
})
