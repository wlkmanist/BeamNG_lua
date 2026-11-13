-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- The one kerb and footway section every tool builds to, and the stone both are cut from.
--
-- A kerb is a real object with real dimensions, and a car riding one has to feel the same step whether it met it on a street,
-- at a car park apron, on a bridge deck or across a plaza. So the figures live HERE rather than in any one builder: whoever
-- lays a kerb asks this module what one is.

local M = {}

-- Module constants.
local min, max, floor = math.min, math.max, math.floor

-- The stone. The footway is laid in one paving and only one -- the area pavings read badly at a footway's width -- and the
-- kerb comes off a trim sheet of five kerbs stacked in V.
local slabMaterial = 'slabs_large'
local kerbMaterial = 'm_sidewalk_curb_trim_01'
local kerbVariantsN = 5 -- a fifth of the sheet each: one run uses one row.
local kerbVGap = 0.00332

-- The section itself. A footway is one slab wide and a kerb stands 12 cm out of the road.
local spec = {
  slabW = 1.65, slabThick = 0.12,
  kerbW = 0.15, kerbH = 0.12,
  buryM = 0.30, -- how far an edge carries on below the ground before it is called buried
  slabMaterial = slabMaterial, kerbMaterial = kerbMaterial,
}


-- The three rows one kerb variant occupies: the back of its tread, the arris, and the foot of its face. The arris row matters
-- -- the normal map carries a bullnose baked across the middle of every band, so putting the real 90 degree edge anywhere
-- else throws the roll off the corner it belongs on.
local function kerbRows(variant)
  local s = (min(kerbVariantsN - 1, max(0, floor(tonumber(variant) or 0)))) * 0.2
  return s, s + 0.1, s + 0.2 - kerbVGap
end


-- Public interface.
M.spec = spec

M.kerbRows = kerbRows

return M