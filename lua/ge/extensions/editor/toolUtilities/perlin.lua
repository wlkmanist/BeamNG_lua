-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- Module constants.
local band = bit.band
local floor = math.floor

-- Precompute perm table (static permutation for deterministic noise).
local perm = {}
local p = {
  151,160,137,91,90,15,
  131,13,201,95,96,53,194,233,7,225,
  140,36,103,30,69,142,8,99,37,240,21,10,23,
  190, 6,148,247,120,234,75,0,26,197,62,94,252,219,203,117,
  35,11,32,57,177,33,88,237,149,56,87,174,20,125,136,171,
  168, 68,175,74,165,71,134,139,48,27,166,77,146,158,231,83,
  111,229,122,60,211,133,230,220,105,92,41,55,46,245,40,244,
  102,143,54, 65,25,63,161,1,216,80,73,209,76,132,187,208,
  89,18,169,200,196,135,130,116,188,159,86,164,100,109,198,173,
  186, 3,64,52,217,226,250,124,123,5,202,38,147,118,126,255,
  82,85,212,207,206,59,227,47,16,58,17,182,189,28,42,223,
  183,170,213,119,248,152, 2,44,154,163,70,221,153,101,155,167,
  43,172,9,129,22,39,253,19,98,108,110,79,113,224,232,178,
  185,112,104,218,246,97,228,251,34,242,193,238,210,144,12,191,
  179,162,241,81,51,145,235,249,14,239,107,49,192,214,31,181,
  199,106,157,184, 84,204,176,115,121,50,45,127, 4,150,254,138,
  236,205,93,222,114,67,29,24,72,243,141,128,195,78,66,215,
  61,156,180
  }

for i = 0, 255 do
  local val = p[i + 1]
  perm[i], perm[i + 256] = val, val
end

local function fade(t) return t * t * t * (t * (t * 6 - 15) + 10) end

local function grad(hash, x, y)
  local h = band(hash, 7)  -- hash & 7
  local u = h < 4 and x or y
  local v = h < 4 and y or x
  local res = ((band(h, 1) ~= 0) and -u or u) + ((band(h, 2) ~= 0) and -v or v)
  return res
end

function M.noise(x, y)
  local X, Y = band(floor(x), 255), band(floor(y), 255)
  local xf, yf = x - floor(x), y - floor(y)
  local u, v = fade(xf), fade(yf)

  local A  = band(perm[X] + Y, 255)
  local AA = perm[A]
  local AB = perm[band(A + 1, 255)]
  local B  = band(perm[band(X + 1, 255)] + Y, 255)
  local BA = perm[B]
  local BB = perm[band(B + 1, 255)]

  return lerp(
    lerp(grad(perm[AA], xf, yf), grad(perm[BA], xf - 1, yf), u),
    lerp(grad(perm[AB], xf, yf - 1), grad(perm[BB], xf - 1, yf - 1), u),
    v
  )
end

return M