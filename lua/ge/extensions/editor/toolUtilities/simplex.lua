-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- Module constants.
local floor, sqrt = math.floor, math.sqrt

-- Gradients for 2D.
local grad3 = {
  {1,1}, {-1,1}, {1,-1}, {-1,-1},
  {1,0}, {-1,0}, {0,1}, {0,-1},
}

-- Permutation table.
local perm = {}
local p = {
  151,160,137,91,90,15,
  131,13,201,95,96,53,194,233,7,225,
  140,36,103,30,69,142,8,99,37,240,21,10,23,
  190,6,148,247,120,234,75,0,26,197,62,94,252,219,203,117,
  35,11,32,57,177,33,88,237,149,56,87,174,20,125,136,171,
  168,68,175,74,165,71,134,139,48,27,166,77,146,158,231,83,
  111,229,122,60,211,133,230,220,105,92,41,55,46,245,40,244,
  102,143,54,65,25,63,161,1,216,80,73,209,76,132,187,208,
  89,18,169,200,196,135,130,116,188,159,86,164,100,109,198,173,
  186,3,64,52,217,226,250,124,123,5,202,38,147,118,126,255,
  82,85,212,207,206,59,227,47,16,58,17,182,189,28,42,223,
  183,170,213,119,248,152,2,44,154,163,70,221,153,101,155,167,
  43,172,9,129,22,39,253,19,98,108,110,79,113,224,232,178,
  185,112,104,218,246,97,228,251,34,242,193,238,210,144,12,191,
  179,162,241,81,51,145,235,249,14,239,107,49,192,214,31,181,
  199,106,157,184,84,204,176,115,121,50,45,127,4,150,254,138,
  236,205,93,222,114,67,29,24,72,243,141,128,195,78,66,215,
  61,156,180
}
for i = 0, 255 do
  local val = p[i + 1]
  perm[i] = val
  perm[i + 256] = val
end

-- Dot product.
local function dot(g, x, y)
  return g[1] * x + g[2] * y
end

-- Simplex noise.
function M.noise(xin, yin)
  local s = (xin + yin) * 0.5 * (sqrt(3) - 1)
  local i = floor(xin + s)
  local j = floor(yin + s)
  local t = (i + j) * ((3 - sqrt(3)) / 6)
  local X0 = i - t
  local Y0 = j - t
  local x0 = xin - X0
  local y0 = yin - Y0

  local i1, j1
  if x0 > y0 then i1, j1 = 1, 0 else i1, j1 = 0, 1 end

  local x1 = x0 - i1 + ((3 - sqrt(3)) / 6)
  local y1 = y0 - j1 + ((3 - sqrt(3)) / 6)
  local x2 = x0 - 1 + 2 * ((3 - sqrt(3)) / 6)
  local y2 = y0 - 1 + 2 * ((3 - sqrt(3)) / 6)

  local ii = i % 256
  local jj = j % 256
  local gi0 = perm[ii + perm[jj]] % 8 + 1
  local gi1 = perm[ii + i1 + perm[jj + j1]] % 8 + 1
  local gi2 = perm[ii + 1 + perm[jj + 1]] % 8 + 1

  local n0, n1, n2

  local t0 = 0.5 - x0 * x0 - y0 * y0
  if t0 < 0 then n0 = 0 else
    t0 = t0 * t0
    n0 = t0 * t0 * dot(grad3[gi0], x0, y0)
  end

  local t1 = 0.5 - x1 * x1 - y1 * y1
  if t1 < 0 then n1 = 0 else
    t1 = t1 * t1
    n1 = t1 * t1 * dot(grad3[gi1], x1, y1)
  end

  local t2 = 0.5 - x2 * x2 - y2 * y2
  if t2 < 0 then n2 = 0 else
    t2 = t2 * t2
    n2 = t2 * t2 * dot(grad3[gi2], x2, y2)
  end

  return 70 * (n0 + n1 + n2)
end

return M