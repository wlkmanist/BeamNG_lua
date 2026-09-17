-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Root route registry.
-- This is the single explicit entry point for top-level route registration.
-- Each entry mounts a route module (its Root + Children) as a top-level route
-- family. There is no filesystem auto-discovery; a module only registers if it
-- is listed here (or added at runtime via routeManager.addVueRoutes).
-- The route config modules themselves live under the routes/ directory.
local M = {}

M.Children = {
  { include = "bigmap" },
  { include = "campaign" },
  { include = "career" },
  { include = "debug" },
  { include = "default" },
  { include = "freeroamLevels" },
  { include = "freeroamWizard" },
  { include = "garage" },
  { include = "legal" },
  { include = "livery" },
  { include = "menu" },
  { include = "mission" },
  { include = "mods" },
  { include = "multiplayer" },
  { include = "options" },
  { include = "pause" },
  { include = "radial" },
  { include = "scenario" },
  { include = "taxi" },
}

-- Flat one-segment global routes (play, /mainmenu, etc.) live in global.lua.
M.Global = { include = "global" }

return M
