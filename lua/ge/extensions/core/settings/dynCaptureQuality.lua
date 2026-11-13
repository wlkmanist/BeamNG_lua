-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

-- Profiling: restore the 0.39 Normal/High/Ultra capture settings.

M.reflectionLevels = {
  Disabled = { enabled = false, textureSize = 128, facesPerUpdate = 1, detail = 0,   distance = 50  },
  Lowest   = { enabled = true,  textureSize = 128, facesPerUpdate = 1, detail = 0.1, distance = 50  },
  Low      = { enabled = true,  textureSize = 256, facesPerUpdate = 1, detail = 0.1, distance = 50 },
  Normal   = { enabled = true,  textureSize = 256, facesPerUpdate = 1, detail = 0.5, distance = 100 },
  High     = { enabled = true,  textureSize = 512, facesPerUpdate = 2, detail = 0.75, distance = 200 },
  Ultra    = { enabled = true,  textureSize = 1024, facesPerUpdate = 2, detail = 0.75, distance = 300 },
}

M.mirrorLevels = {
  Disabled = { enabled = false, textureSize = 128, detail = 0,    distance = 50  },
  Lowest   = { enabled = true,  textureSize = 128, detail = 0.1,  distance = 50  },
  Low      = { enabled = true,  textureSize = 256, detail = 0.1,  distance = 50 },
  Normal   = { enabled = true,  textureSize = 256, detail = 0.5, distance = 100 },
  High     = { enabled = true,  textureSize = 512, detail = 0.75, distance = 200 },
  Ultra    = { enabled = true,  textureSize = 1024, detail = 0.75, distance = 300 },
}

local function applyReflection(level)
  local p = M.reflectionLevels[level]
  if not p then return end
  VariableRegistry.set("$pref::BeamNGVehicle::dynamicReflection::enabled", p.enabled)
  VariableRegistry.set("$pref::BeamNGVehicle::dynamicReflection::textureSize", p.textureSize)
  VariableRegistry.set("$pref::BeamNGVehicle::dynamicReflection::facesPerUpdate", p.facesPerUpdate)
  VariableRegistry.set("$pref::BeamNGVehicle::dynamicReflection::detail", p.detail)
  VariableRegistry.set("$pref::BeamNGVehicle::dynamicReflection::distance", p.distance)
end

local function applyMirrors(level)
  local p = M.mirrorLevels[level]
  if not p then return end
  VariableRegistry.set("$pref::BeamNGVehicle::dynamicMirrors::enabled", p.enabled)
  VariableRegistry.set("$pref::BeamNGVehicle::dynamicMirrors::textureSize", p.textureSize)
  VariableRegistry.set("$pref::BeamNGVehicle::dynamicMirrors::detail", p.detail)
  VariableRegistry.set("$pref::BeamNGVehicle::dynamicMirrors::distance", p.distance)
end

M.applyReflection = applyReflection
M.applyMirrors = applyMirrors

return M
