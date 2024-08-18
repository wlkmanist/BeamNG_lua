-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Control parameters.
local foldername = 'terrain'                                                                -- The name of the temporary folder into which the heightmap will be stored.
local materialsPath = 'levels/template_tech/art/terrains/main.materials.json'               -- The path for the terrain materials.

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

local min, max, floor, ceil = math.min, math.max, math.floor, math.ceil

-- Computes the smallest square size above a value, which is also a power of two.
local function findBoundingSquare(s)
  local testSize = 64
  for i = 1, 20 do
    testSize = testSize * 2
    if testSize > s then
      return testSize
    end
  end
  return nil
end

-- Imports a heightmap from a 2D array of 'pixel' values in the range given by [zMin, zMax].  The array should be indexable as [x][y].
-- The scale describes the resolution of the final generated heightmap - in both x and y, in metres-per-pixel. The scale is isotropic.
-- Heightmaps must ultimately satisfy the following conditions, which this function will ensure (by cropping, if required):
--  i)    They must be square.
--  ii)   They must be a power of two in size.
--  iii)  They must be no larger than 8192 in size.
-- The generated heightmap will assume the vertical range [0, zMax - zMin] to ensure maximum granularity in its height.
local function importHeightmap(data, w, h, scale, zMin, zMax, isYFlipped)

  -- Initialise a bitmap which will represent the heightmap data.
  local bmpSize = min(8192, findBoundingSquare(max(w, h)))
  local bmp = GBitmap()
  bmp:init(bmpSize, bmpSize)
  bmp:allocateBitmap(bmpSize, bmpSize, false, "GFXFormatR16")
  for x = 0, bmpSize do
    for y = 0, bmpSize do
      bmp:setTexel(x, y, 0, 0, 0, 0)
    end
  end

  -- Populate the bitmap with the heightmap data, then save it somewhere.
  local xSize, ySize = min(w, bmpSize) - 1, min(h, bmpSize) - 1
  local prominence = zMax - zMin
  local uint16Scale = 65535 / prominence
  for x = 0, xSize do
    local dataX = data[x]
    for y = 0, ySize do
      local val = floor((dataX[y] - zMin) * uint16Scale)
      bmp:setTexel(x, y, val, val, val, 65535)
    end
  end
  bmp:saveFile(foldername .. '/temp_heightmap.png')

  -- Generate a terrain block from the saved heightmap .png file.
  local tg = extensions.util_terrainGenerator.new()
  tg:setPngData(foldername .. '/temp_heightmap.png', bmpSize, prominence, scale or 1, isYFlipped or true)
  tg:setUserDir(foldername)
  tg:setMaterials({filePath = materialsPath})
  tg:createTerrain()
end


-- Public interface.
M.importHeightmap =                                         importHeightmap

return M