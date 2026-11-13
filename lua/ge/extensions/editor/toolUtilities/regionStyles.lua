-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Road marking paint style (USA, right-hand traffic).

local M = {}

local USA = {
  centerLineMaterial = 'm_line_yellow_double',
  centerLineWidthM = 0.4,
  centerLineTexLen = 5.0,
  laneLineMaterial = 'm_line_white_discontinue',
  edgeLineMaterial = 'm_line_white',
  leftEdgeLineMaterial = 'm_line_yellow', -- the travel-left edge of a divided or one-way carriageway
  stopLineMaterial = 'm_line_white',
  giveWayMaterial = 'm_line_white', -- shark teeth aren't a DecalRoad material yet, so a solid white bar
  stopLineWidthM = 0.35,
  giveWayWidthM = 0.35,
  -- Same-direction gore: diagonal slash hatch (not V-chevrons).
  goreSepMaterial = 'italy_road_markings_zebra_diagonal',
  goreSepTexLen = 4.0,
}

local function getRegion()
  return USA
end


-- Public interface.
M.getRegion = getRegion

return M