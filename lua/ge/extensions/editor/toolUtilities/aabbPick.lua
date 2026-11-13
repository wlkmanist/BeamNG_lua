-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Ray vs axis-aligned bounding box picking. A small, allocation-free helper for tools that need to pick world items by their
-- AABB (e.g. placed building instances): the slab test returns the ray's entry distance to a box, and pickNearest walks a
-- provider callback and returns the id of the nearest box the ray enters. Linear over the items - fine for realistic counts;
-- a broadphase (kdtree) can wrap this later without changing callers.

local M = {}

local huge = math.huge

-- Ray (origin o*, direction d*, d need not be normalized) vs AABB [min*, max*]. Returns the entry distance t along the ray
-- (>= 0) if it hits, else nil. Standard slab method; a ray starting inside the box returns 0.
local function rayAabb(ox, oy, oz, dx, dy, dz, minx, miny, minz, maxx, maxy, maxz)
  local tmin, tmax = -huge, huge
  -- X slab
  if dx ~= 0 then
    local inv = 1 / dx
    local t1, t2 = (minx - ox) * inv, (maxx - ox) * inv
    if t1 > t2 then t1, t2 = t2, t1 end
    if t1 > tmin then tmin = t1 end
    if t2 < tmax then tmax = t2 end
  elseif ox < minx or ox > maxx then return nil end
  -- Y slab
  if dy ~= 0 then
    local inv = 1 / dy
    local t1, t2 = (miny - oy) * inv, (maxy - oy) * inv
    if t1 > t2 then t1, t2 = t2, t1 end
    if t1 > tmin then tmin = t1 end
    if t2 < tmax then tmax = t2 end
  elseif oy < miny or oy > maxy then return nil end
  -- Z slab
  if dz ~= 0 then
    local inv = 1 / dz
    local t1, t2 = (minz - oz) * inv, (maxz - oz) * inv
    if t1 > t2 then t1, t2 = t2, t1 end
    if t1 > tmin then tmin = t1 end
    if t2 < tmax then tmax = t2 end
  elseif oz < minz or oz > maxz then return nil end

  if tmax < tmin or tmax < 0 then return nil end -- box behind the ray, or no overlap
  return tmin >= 0 and tmin or 0                 -- 0 when the ray starts inside the box
end

-- Nearest box the ray (origin o*, dir d*) enters, chosen by entry distance. `provider(visit)` must call
-- visit(id, minx, miny, minz, maxx, maxy, maxz) once per candidate box. Returns the winning id (or nil) and its distance.
local function pickNearest(ox, oy, oz, dx, dy, dz, provider)
  local bestId, bestT = nil, huge
  provider(function(id, minx, miny, minz, maxx, maxy, maxz)
    local t = rayAabb(ox, oy, oz, dx, dy, dz, minx, miny, minz, maxx, maxy, maxz)
    if t and t < bestT then bestT = t; bestId = id end
  end)
  if bestId then return bestId, bestT end
  return nil
end


-- Public interface.
M.rayAabb = rayAabb
M.pickNearest = pickNearest

return M