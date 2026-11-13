-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- One deterministic draw in [0,1) off an address: a seed, a salt telling apart the several decisions one address makes, and
-- up to five numbers saying WHERE - a volume, an elevation, a bay, a storey, a piece index, whatever the caller counts in.

local M = {}


--- A draw in [0,1). Absent address slots count as zero, so a caller with two of them need not pass five.
local function roll(seed, salt, a, b, c, d, e)
  local h = ((seed or 0) * 2654435761 + (a or 0) * 40503 + (b or 0) * 12289 + (c or 0) * 6151
             + (d or 0) * 769 + (e or 0) * 97 + (salt or 0) * 31337) % 2147483647
  for _ = 1, 2 do
    local lo = h % 67108864
    h = (lo * lo + h) % 2147483647
    h = (h * 48271) % 2147483647
  end
  return ((h * 69621) % 2147483647) / 2147483647
end

--- The same draw, mapped to -1 .. 1. What a jitter wants: how far out of place a thing was left, either way.
local function spread(seed, salt, a, b, c, d, e)
  return roll(seed, salt, a, b, c, d, e) * 2 - 1
end


-- Public interface.
M.roll = roll
M.spread = spread

return M