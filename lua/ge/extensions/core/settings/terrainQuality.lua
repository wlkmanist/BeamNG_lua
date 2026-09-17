-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.qualityLevels = {
  Lowest = {
  },
  Low = {
  },
  Normal = {
  },
  High = {
  }
}

M.qualityLevels.Lowest["$pref::Terrain::lodScale"] = 2.0
M.qualityLevels.Lowest["$pref::Terrain::detailScale"] = 0.5

M.qualityLevels.Low["$pref::Terrain::lodScale"] = 1.5
M.qualityLevels.Low["$pref::Terrain::detailScale"] = 0.75

M.qualityLevels.Normal["$pref::Terrain::lodScale"] = 1.0
M.qualityLevels.Normal["$pref::Terrain::detailScale"] = 1

M.qualityLevels.High["$pref::Terrain::lodScale"] = 0.75
M.qualityLevels.High["$pref::Terrain::detailScale"] = 1.5

local function updateTerrainBlocks()
  local terrainNames = scenetree.findClassObjects("TerrainBlock") or {}
  for _, name in ipairs(terrainNames) do
    local terrain = scenetree.findObject(name)
    if terrain and terrain.updateAllTextures then
      terrain:updateAllTextures()
    end
  end
end

M.onApply = function()
  updateTerrainBlocks()
end

return M