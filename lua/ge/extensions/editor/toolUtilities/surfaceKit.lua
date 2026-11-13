-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared "surface kit" for painting physics groundmodels onto mesh roads (Hero Road Editor groundmodel mode, reusable by
-- other mesh-road tools later). A groundmodel is a PHYSICS property looked up from a triangle's MATERIAL name -- the grip
-- variants are visually identical to the base (same textures/normal map) and differ ONLY in groundType, so a painted patch
-- changes grip without any visible seam. The visible ice/wet/snow look, if wanted, is a separate decalroad on top.
--
-- Materials follow a NAMING CONVENTION rather than being hardcoded: the paint variants are the road's own carriageway (base)
-- material with a suffix -- `<base>_wet`, `<base>_snow` (or `_snowy`), `<base>_ice`. Dry IS the base material and doubles as
-- the eraser. A surface state is only paintable when its variant material actually exists in the level; otherwise the tool
-- greys it out. This lets a map ship its own asphalt family without touching this code -- just name the variants to match.
--
-- Paint is stored as WORLD-SPACE stamps { x, y, r, m } (m = 1-based palette index; 1 = Dry = base/erase). World-space keeps it
-- robust: it survives resolution/width changes and re-splining (paint is pinned to the ground, re-rasterised each build, never
-- resets). This module owns the palette AND the stamp spatial lookup so both the mesh builder and the editor overlay agree.

local M = {}

-- Module constants.
local floor = math.floor

-- Palette. Index 1 is the base/dry surface and doubles as the eraser. `suffixes` are the material-name suffixes appended to the
-- road's base material to locate the grip variant (first existing one wins; snow accepts `_snow` or the legacy `_snowy`). Colours
-- are soft (not 8-bit primaries) and are the editor OVERLAY colour only -- they never affect the rendered road.
local palette = {
  { id = 'dry',  label = 'Dry',  groundmodel = 'ASPHALT1',    col = { 214, 168, 92 },  suffixes = nil },              -- base material itself
  { id = 'wet',  label = 'Wet',  groundmodel = 'ASPHALT_WET', col = { 40, 120, 205 },  suffixes = { '_wet' } },       -- deep water blue
  { id = 'snow', label = 'Snow', groundmodel = 'SNOW',        col = { 236, 240, 248 }, suffixes = { '_snow', '_snowy' } }, -- soft snow white
  { id = 'ice',  label = 'Ice',  groundmodel = 'ICE',         col = { 96, 208, 224 },  suffixes = { '_ice' } },       -- icy cyan
}
local baseIndex = 1 -- Dry / carriageway base material; a stamp with this index means "erase back to base".


-- Palette accessors.
local function count() return #palette end
local function get(i) return palette[i] end
local function isBase(i) return (i or baseIndex) == baseIndex end
local function labelOf(i) local e = palette[i]; return e and e.label or '?' end
local function colOf(i) local e = palette[i]; return e and e.col or palette[baseIndex].col end

-- True when a material of this name is present in the level.
local function materialExists(name)
  return name ~= nil and name ~= '' and scenetree ~= nil and scenetree.findObject(name) ~= nil
end

-- Resolved variant material name for surface `i` given the road's base (carriageway) material, or nil when this state has no
-- existing variant (so it isn't paintable on this road). Dry (base) always resolves to the base material itself.
local function variantMaterial(i, baseMat)
  local e = palette[i]
  if not e or not baseMat then return nil end
  if not e.suffixes then return baseMat end -- Dry = the base material.
  for k = 1, #e.suffixes do
    local cand = baseMat .. e.suffixes[k]
    if materialExists(cand) then return cand end
  end
  return nil
end

-- Whether surface `i` can be painted on a road with this base material (Dry always; others only when a variant material exists).
local function isAvailable(i, baseMat)
  if i == baseIndex then return true end
  return variantMaterial(i, baseMat) ~= nil
end

-- Material actually applied to a painted quad of surface `i`: the variant when it exists, else the base material (so a missing
-- variant degrades to base rather than referencing a material that isn't there).
local function materialOf(i, baseMat)
  return variantMaterial(i, baseMat) or baseMat or palette[baseIndex].id
end

-- Resolve every surface's material against one base material in a single pass (called once per mesh build, so the per-quad
-- routing is a plain array lookup rather than a scene-tree query).
local function resolveMaterials(baseMat)
  local t = {}
  for i = 1, #palette do t[i] = materialOf(i, baseMat) end
  return t
end

-- Build a uniform spatial hash over the stamps so a per-quad lookup is ~O(1) instead of O(#stamps). Cell size = the largest
-- brush radius, so any stamp covering a query point has its centre within one cell of the point's cell (3x3 neighbourhood).
-- Returns nil when there's nothing painted (callers then treat every quad as base). Cheap: rebuilt per full mesh build only.
local function buildGrid(stamps)
  if not stamps or #stamps == 0 then return nil end
  local cell = 0.5
  for i = 1, #stamps do local r = stamps[i].r or 0; if r > cell then cell = r end end
  local map = {}
  for i = 1, #stamps do
    local s = stamps[i]
    local k = floor(s.x / cell) .. ':' .. floor(s.y / cell)
    local list = map[k]; if not list then list = {}; map[k] = list end
    list[#list + 1] = i
  end
  return { cell = cell, map = map }
end

-- Palette index of the surface painted at world (px, py): the HIGHEST-index (last-painted) stamp covering the point wins, so a
-- later stroke -- including a Dry erase stroke -- overrides earlier ones. Returns baseIndex when nothing covers it. Orphan
-- stamps far from the road live in cells no quad ever queries, so they cost nothing here.
local function materialAt(grid, stamps, px, py)
  if not grid then return baseIndex end
  local cell = grid.cell
  local cx, cy = floor(px / cell), floor(py / cell)
  local best = 0
  for gx = cx - 1, cx + 1 do
    for gy = cy - 1, cy + 1 do
      local list = grid.map[gx .. ':' .. gy]
      if list then
        for li = 1, #list do
          local idx = list[li]
          if idx > best then
            local s = stamps[idx]
            local dx, dy = px - s.x, py - s.y
            if dx * dx + dy * dy <= s.r * s.r then best = idx end
          end
        end
      end
    end
  end
  if best == 0 then return baseIndex end
  return stamps[best].m or baseIndex
end


-- Public interface.
M.count = count
M.get = get
M.isBase = isBase
M.materialOf = materialOf
M.variantMaterial = variantMaterial
M.isAvailable = isAvailable
M.resolveMaterials = resolveMaterials
M.materialExists = materialExists
M.labelOf = labelOf
M.colOf = colOf
M.buildGrid = buildGrid
M.materialAt = materialAt

return M