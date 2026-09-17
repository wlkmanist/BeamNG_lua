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

local clr = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/colors')

-- Text-only / no-tile modifiers still need an explicit visual marker so the
-- style intent is clear while the visual compositor skips them.
local function noVisual()
  return {}
end

local function iconVisual(icon)
  return { icon = icon, colorIcon = clr.mainPaletteFg, colorNoteText = clr.mainPaletteFg, colorBg = clr.modifierBg, colorStroke = clr.modifierStroke }
end

local function additionalNoteVisual(icon, color, colorBg, colorStroke)
  return { additionalNote = { icon = icon, color = color, colorBg = colorBg, colorStroke = colorStroke } }
end

return {
  -- atomic: pace / braking
  slowing          = { text = "slowing",          tags = { "pace" }, visual = noVisual() },
  brake            = { text = "brake",            tags = { "pace" }, visual = noVisual() },
  brakeOverBumps   = { text = "brake over bumps", tags = { "pace" }, visual = noVisual() },
  brakeOverCrest   = { text = "brake over crest", tags = { "pace" }, visual = noVisual() },
  braking          = { text = "braking",          tags = { "pace" }, visual = noVisual() },
  stop             = { text = "stop",             tags = { "pace" }, visual = noVisual() },
  beBrave          = { text = "be brave",         tags = { "pace" }, visual = noVisual() },
  getsFasterNow    = { text = "gets faster now",  tags = { "pace" }, visual = noVisual() },
  intoTurn         = { text = "into turn",        tags = { "pace" }, visual = noVisual() },
  turn             = { text = "turn",             tags = { "pace" }, visual = noVisual() },

  -- atomic: line guidance
  narrows              = { text = "narrows",                tags = { "line" }, visual = iconVisual("narrows") },
  dontGoWide           = { text = "don't go wide",          tags = { "line" }, visual = noVisual() },
  early                = { text = "early",                  tags = { "line" }, visual = noVisual() },
  goWide               = { text = "go wide",                tags = { "line" }, visual = noVisual() },
  late                 = { text = "late",                   tags = { "line" }, visual = noVisual() },
  middle               = { text = "middle",                 tags = { "line" }, visual = noVisual() },
  middleOverCrest      = { text = "middle over crest",      tags = { "line" }, visual = noVisual() },
  nips                 = { text = "nips",                   tags = { "line" }, visual = noVisual() },
  twisty               = { text = "twisty",                 tags = { "line" }, visual = noVisual() },
  wide                 = { text = "wide",                   tags = { "line" }, visual = noVisual() },

  -- atomic: cut guidance
  bigCut       = { text = "big cut",        tags = { "cut" }, visual = additionalNoteVisual("scissors", clr.mainPaletteFg, clr.cutBg, clr.cutStroke) },
  cut          = { text = "cut",            tags = { "cut" }, visual = additionalNoteVisual("scissors", clr.mainPaletteFg, clr.cutBg, clr.cutStroke) },
  dont         = { text = "don't",          tags = { "cut" }, visual = additionalNoteVisual("scissorsSlashed", clr.mainPaletteFg, clr.dontCutBg, clr.dontCutStroke) },
  dontCut      = { text = "don't cut",      tags = { "cut" }, visual = additionalNoteVisual("scissorsSlashed", clr.mainPaletteFg, clr.dontCutBg, clr.dontCutStroke) },
  dontCutLate  = { text = "don't cut late", tags = { "cut" }, visual = additionalNoteVisual("scissorsSlashed", clr.mainPaletteFg, clr.dontCutBg, clr.dontCutStroke) },
  earlyCut     = { text = "early cut",      tags = { "cut" }, visual = additionalNoteVisual("scissors", clr.mainPaletteFg, clr.cutBg, clr.cutStroke) },
  lateCut      = { text = "late cut",       tags = { "cut" }, visual = additionalNoteVisual("scissors", clr.mainPaletteFg, clr.cutBg, clr.cutStroke) },
  smallCut     = { text = "small cut",      tags = { "cut" }, visual = additionalNoteVisual("scissors", clr.mainPaletteFg, clr.cutBg, clr.cutStroke) },

  -- atomic: keep guidance
  keepIn              = { text = "keep in",                tags = { "keep" }, visual = noVisual() },
  keepLeft            = { text = "keep left",              tags = { "keep" }, visual = noVisual() },
  keepLeftOverCrest   = { text = "keep left over crest",   tags = { "keep" }, visual = noVisual() },
  keepMiddle          = { text = "keep middle",            tags = { "keep" }, visual = noVisual() },
  keepMiddleOverCrest = { text = "keep middle over crest", tags = { "keep" }, visual = noVisual() },
  keepRight           = { text = "keep right",             tags = { "keep" }, visual = noVisual() },
  keepRightOverCrest  = { text = "keep right over crest",  tags = { "keep" }, visual = noVisual() },

  -- atomic: chicanes
  chicaneLeftEntry  = { text = "chicane left entry",  tags = { "chicane" }, visual = noVisual() },
  chicaneRightEntry = { text = "chicane right entry", tags = { "chicane" }, visual = noVisual() },

  -- atomic: jumps
  overJump   = { text = "over jump",    tags = { "jump" }, visual = iconVisual("jumpOverBump") },
  jump       = { text = "jump",         tags = { "jump" }, visual = iconVisual("jumpOverBump") },
  badDipJump = { text = "bad dip jump", tags = { "jump" }, visual = iconVisual("jumpOverBump") },
  badJump    = { text = "bad jump",     tags = { "jump" }, visual = iconVisual("jumpOverBump") },
  bigJump    = { text = "big jump",     tags = { "jump" }, visual = iconVisual("jumpOverBump") },

  -- atomic: crests
  overCrest  = { text = "over crest",  tags = { "crest" }, variant = "1", visual = iconVisual("crest") },
  crest      = { text = "crest",       tags = { "crest" }, visual = iconVisual("crest") },
  intoCrest  = { text = "into crest",  tags = { "crest" }, visual = iconVisual("crest") },
  longCrest  = { text = "long crest",  tags = { "crest" }, visual = iconVisual("crest") },
  bigCrest   = { text = "big crest",   tags = { "crest" }, visual = iconVisual("crest") },
  smallCrest = { text = "small crest", tags = { "crest" }, visual = iconVisual("crest") },

  -- atomic: dips
  badDip     = { text = "bad dip",     tags = { "dip" }, visual = iconVisual("pothole") },
  dip        = { text = "dip",         tags = { "dip" }, visual = iconVisual("pothole") },
  overDip    = { text = "over dip",    tags = { "dip" }, visual = iconVisual("pothole") },
  throughDip = { text = "through dip", tags = { "dip" }, visual = iconVisual("pothole") },

  -- atomic: bumps / grade
  bump         = { text = "over bump",     tags = { "bump" }, visual = iconVisual("bump") },
  bumpy        = { text = "bumpy",         tags = { "bump" }, visual = iconVisual("bumps") },
  badDrop      = { text = "bad drop",      tags = { "bump" }, visual = iconVisual("bump") },
  badKick      = { text = "bad kick",      tags = { "bump" }, visual = iconVisual("bump") },
  kick         = { text = "kick",          tags = { "bump" }, visual = iconVisual("bump") },
  drop         = { text = "drop",          tags = { "bump" }, visual = iconVisual("bump") },
  down         = { text = "down",          tags = { "grade" }, visual = noVisual() },
  up           = { text = "up",            tags = { "grade" }, visual = noVisual() },

  -- atomic: surface changes
  ontoGravel  = { text = "onto gravel", tags = { "surface" }, visual = noVisual() },
  ontoIce     = { text = "onto ice",    tags = { "surface" }, visual = noVisual() },
  ontoTarmac  = { text = "onto tarmac", tags = { "surface" }, visual = noVisual() },
  ontoMud     = { text = "onto mud",    tags = { "surface" }, visual = noVisual() },
  slippy      = { text = "slippy",      tags = { "surface" }, visual = noVisual() },

  -- atomic: water
  watersplash = { text = "watersplash", tags = { "water" }, visual = iconVisual("water") },
  water       = { text = "water",       tags = { "water" }, visual = iconVisual("water") },
  intoWater   = { text = "into water",  tags = { "water" }, visual = iconVisual("water") },

  -- atomic: landmarks / roadside features
  atJunction     = { text = "at junction",     tags = { "landmark" }, visual = noVisual() },
  atRock         = { text = "at rock",         tags = { "landmark" }, visual = noVisual() },
  atTree         = { text = "at tree",         tags = { "landmark" }, visual = noVisual() },
  intoBridge     = { text = "into bridge",     tags = { "landmark" }, visual = iconVisual("bridge") },
  narrowBridge   = { text = "narrow bridge",   tags = { "landmark" }, visual = iconVisual("bridge") },
  overBridge     = { text = "over bridge",     tags = { "landmark" }, visual = iconVisual("bridge") },
  pastFence      = { text = "past fence",      tags = { "landmark" }, visual = noVisual() },
  pastHouse      = { text = "past house",      tags = { "landmark" }, visual = noVisual() },
  pastJunction   = { text = "past junction",   tags = { "landmark" }, visual = noVisual() },
  pastRock       = { text = "past rock",       tags = { "landmark" }, visual = noVisual() },
  pastTree       = { text = "past tree",       tags = { "landmark" }, visual = noVisual() },
  pastWall       = { text = "past wall",       tags = { "landmark" }, visual = noVisual() },
  throughBridge  = { text = "through bridge",  tags = { "landmark" }, visual = iconVisual("bridge") },
  throughGate    = { text = "through gate",    tags = { "landmark" }, visual = noVisual() },
  throughTunnel  = { text = "through tunnel",  tags = { "landmark" }, visual = noVisual() },
  underBridge    = { text = "under bridge",    tags = { "landmark" }, visual = iconVisual("bridge") },

  -- atomic: flow / timing
  deceptive = { text = "deceptive", tags = { "flow" }, visual = noVisual() },
  sudden    = { text = "sudden",    tags = { "flow" }, visual = noVisual() },

  -- atomic: stage calls
  toStop  = { text = "to stop",     tags = { "stage" }, visual = noVisual() },
  finish  = { text = "over finish", tags = { "stage" }, visual = { icon = "finish", colorIcon = clr.offWhite, colorBg = clr.offBlack, colorStroke = clr.offWhite } },
}
