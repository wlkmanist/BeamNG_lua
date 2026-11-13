-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared world-space fractal noise for editor terrain/mesh tools. Single source of truth so different tools (terraform,
-- heroRoadEditor mesh) sample the SAME field with the SAME roughness/scale mapping -- a mesh road and the terrain shaped
-- around it then agree bump-for-bump at their shared edge (no per-tool seed, coordinates are raw world XY).

local M = {}

local simplex = require('editor/toolUtilities/simplex')

local floor = math.floor -- clamp() and lerp() are globals from common/mathlib.lua.

local defaultFbmLacunarity = 2.0 -- Frequency multiplier per octave.
local defaultFbmGain = 0.5 -- Amplitude multiplier per octave.


-- Fractal Brownian Motion at world point (x, y). Returns a normalised value in ~[-1, 1].
local function fbm(x, y, octaves, lacunarity, gain)
  local total, frequency, amplitude, maxAmplitude = 0, 1, 1, 0
  for _ = 1, octaves do
    total = total + simplex.noise(x * frequency, y * frequency) * amplitude
    maxAmplitude = maxAmplitude + amplitude
    amplitude = amplitude * gain
    frequency = frequency * lacunarity
  end
  return total / maxAmplitude
end

-- Maps user roughness/scale in [0,1] to low-level fbm parameters, tuned for LARGE terrain undulations (terraforming).
-- Returns: noiseFreq, noiseStrength (metres), fbmOctaves, fbmLacunarity, fbmGain.
local function mapNoiseParameters(roughness, scale)
  roughness, scale = clamp(roughness, 0, 1), clamp(scale, 0, 1)
  local noiseStrength = lerp(0.0, 1.0, roughness) -- Amplitude mapping (0 -> 1 m).
  local noiseFreq = lerp(0.02, 0.2, scale) -- Frequency: large bumps ~50 m wavelength (freq ~0.02) -> small bumps ~5 m (freq ~0.2).
  local fbmOctaves = floor(lerp(3, 6, scale) + 0.5) -- Octaves: fewer avoids flicker, more adds fine detail.
  return noiseFreq, noiseStrength, fbmOctaves, defaultFbmLacunarity, defaultFbmGain
end

-- Same fbm field, but mapped for a ROAD SURFACE (rally bumpiness): a much finer, higher-frequency band and a much lower,
-- drivable amplitude, so it reads as bumps/ruts rather than the big rolling dunes the terrain mapping above produces.
-- Base wavelength ~16 m (rolling) at scale 0 down to ~2 m (choppy) at scale 1. fbm returns ~[-1,1], so noiseStrength is a
-- PEAK height: caps ~0.18 m (so ~0.35 m peak-to-trough at full roughness) -- a rough dirt road, not driveable-over whoops.
-- Octaves kept modest so the fine detail stays near the mesh vertex spacing instead of aliasing into per-vertex grain.
local function mapRoadNoiseParameters(roughness, scale)
  roughness, scale = clamp(roughness, 0, 1), clamp(scale, 0, 1)
  local noiseStrength = lerp(0.0, 0.18, roughness)
  local noiseFreq = lerp(0.06, 0.5, scale)
  local fbmOctaves = floor(lerp(3, 5, scale) + 0.5)
  return noiseFreq, noiseStrength, fbmOctaves, defaultFbmLacunarity, defaultFbmGain
end


-- Public interface.
M.defaultFbmLacunarity = defaultFbmLacunarity
M.defaultFbmGain = defaultFbmGain

M.fbm = fbm
M.mapNoiseParameters = mapNoiseParameters
M.mapRoadNoiseParameters = mapRoadNoiseParameters

return M