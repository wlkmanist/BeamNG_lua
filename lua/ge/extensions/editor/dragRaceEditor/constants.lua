-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local im = ui_imgui

M.CONSTANTS = {
  WINDOW_NAME = "Drag Race Editor",
  WINDOW_SIZE = {x = 1800, y = 900},

  DEFAULT_FILE_DIR = "/levels/",
  FILE_EXTENSION = ".dragSettings.json",

  DRAG_TYPES = {
    "headsUpRace", "bracketRace"
  },

  RACE_PHASES = {"stage", "countdown", "race", "stop"},

  TREE_TYPES = {".400", ".500"},

  CONTEXT_TYPES = {"freeroam", "activity"},

  DEFAULT_TRANSFORM = {
    position = {x = 0, y = 0, z = 0},
    rotation = {x = 0, y = 0, z = 0, w = 1},
    scale = {x = 1, y = 1, z = 1}
  },

  DEFAULT_WAYPOINT = {
    speed = 5,
    mode = "limit"
  },

  COLORS = {
    WHITE = ColorF(1, 1, 1, 1),
    BLACK = ColorI(0, 0, 0, 192),
    RED = ColorF(1, 0, 0, 0.8),
    GREEN = ColorF(0, 1, 0, 0.8),
    BLUE = ColorF(0, 0, 1, 0.8),
    YELLOW = ColorF(1, 1, 0, 0.8),
    SUCCESS = im.ImVec4(0.0, 1.0, 0.0, 1.0),
    WARNING = im.ImVec4(1.0, 1.0, 0.0, 1.0),
    ERROR = im.ImVec4(1.0, 0.0, 0.0, 1.0)
  },

  UI = {
    INPUT_WIDTH = 120,
    BUTTON_HEIGHT = 20,
    SPACING = 5
  }
}

return M
