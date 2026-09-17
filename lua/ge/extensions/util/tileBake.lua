-- Dev-only: bakes distant-city tile proxies. Buckets every static mesh + big forest item in
-- the level into 200m tiles, packs each tile into one mesh, GPU-bakes it to a shared atlas and
-- writes a tile glTF (via the C++ bakeTileToGltf). Feed the output to DevTools/instalod to make
-- the simplified LODs. Load via:  extensions.load('util/tileBake')
-- Output: /temp/tileBake/<level>/tile_<tx>_<ty>/  (atlas PNGs + tile_<tx>_<ty>.gltf + tile.json)
local M = {}

local TILE_SIZE = 200          -- world meters per tile edge (matches SceneTileCache)
local RESOLUTION = 4096        -- atlas page size. Doesn't change total dilate/save cost (that's set
                              -- by the density floor -> total texels); a bigger page just means
                              -- fewer pages = less per-page overhead.
local GUTTER = 8              -- seam dilation (px). dilate cost scales linearly with this (was 16).
local BIG_FOREST_MIN_RADIUS = 4 -- only forest items whose world box half-diagonal >= this (m)
-- Vegetation has its own forest LOD/imposter system, so it's wasteful in a distant proxy. Skip any
-- shape (static OR forest) whose path matches one of these (case-insensitive substring). Tunable.
local SKIP_PATTERNS = { "/trees/", "/vegetation/", "/foliage/", "/plants/", "bush", "shrub", "fern", "grass", "hedge", "weed" }

local pending = false
local warmup = 0
local tiles = nil              -- { [key] = { tx, ty, insts = { {shape, m}, ... }, statics, forest } }
local tileKeys = nil
local cursor = 0
local okCount, failCount = 0, 0

local function levelName()
  local ok, fn = pcall(function() return getMissionFilename() end)
  if ok and type(fn) == "string" and fn ~= "" then
    return fn:match("/levels/([^/]+)/") or "level"
  end
  return "level"
end

-- Vegetation (trees/bushes/...) is skipped: it has its own forest imposter/LOD system.
local function isVegetation(path)
  local p = path:lower()
  for _, pat in ipairs(SKIP_PATTERNS) do
    if p:find(pat, 1, true) then return true end
  end
  return false
end

local function tileKey(tx, ty) return tx .. "_" .. ty end

local function getTile(tx, ty)
  local k = tileKey(tx, ty)
  local t = tiles[k]
  if not t then
    t = { tx = tx, ty = ty, insts = {}, statics = 0, forest = 0 }
    tiles[k] = t
    table.insert(tileKeys, k)
  end
  return t
end

-- Copy a (possibly const) transform into a fresh mutable matrix and fold scale into it. Forest
-- items' getTransform() returns a const matrix, so the non-const MatrixF:scale can't be called on
-- it directly; getColumn is const-safe, so rebuild into an owned matrix first.
local function scaledTransform(m, scale)
  local out = MatrixF(true)
  out:setColumn(0, m:getColumn(0))
  out:setColumn(1, m:getColumn(1))
  out:setColumn(2, m:getColumn(2))
  out:setColumn(3, m:getColumn(3))
  out:scale(scale)
  return out
end

-- One global pass: assign each instance to the tile containing its center.
local function gather()
  tiles, tileKeys = {}, {}

  for _, obj in ipairs(findAllObjects(SOTStaticShape)) do
    if obj:isSubClassOf("TSStatic") then
      local shape = obj:getField("shapeName", 0)
      if shape and shape ~= "" and not isVegetation(shape) then
        local c = obj:getWorldBox():getCenter()
        local tx, ty = math.floor(c.x / TILE_SIZE), math.floor(c.y / TILE_SIZE)
        local m = scaledTransform(obj:getTransform(), obj:getScale())
        local t = getTile(tx, ty)
        table.insert(t.insts, { shape = shape, m = m })
        t.statics = t.statics + 1
      end
    end
  end

  local forest = core_forest and core_forest.getForestObject and core_forest.getForestObject()
  local data = forest and forest:getData()
  if data then
    local world = Box3F()
    world.minExtents = Point3F(-1e6, -1e6, -1e6)
    world.maxExtents = Point3F(1e6, 1e6, 1e6)
    for _, item in ipairs(data:getItemsBox(world)) do
      local wb = item:getWorldBox()
      local mn, mx = wb.minExtents, wb.maxExtents
      local dx, dy, dz = mx.x - mn.x, mx.y - mn.y, mx.z - mn.z
      -- half-diagonal is the item radius; skip small stuff (grass/bushes)
      if math.sqrt(dx * dx + dy * dy + dz * dz) * 0.5 >= BIG_FOREST_MIN_RADIUS then
        local shape = item:getData():getShapeFile()
        if shape and shape ~= "" and not isVegetation(shape) then
          local c = wb:getCenter()
          local tx, ty = math.floor(c.x / TILE_SIZE), math.floor(c.y / TILE_SIZE)
          local s = item:getScale()
          local m = scaledTransform(item:getTransform(), Point3F(s, s, s))
          local t = getTile(tx, ty)
          table.insert(t.insts, { shape = shape, m = m })
          t.forest = t.forest + 1
        end
      end
    end
  end

  log("I", "tileBake", string.format("gathered %d tiles from level '%s'", #tileKeys, levelName()))
end

local function bakeOne(t)
  local origin = Point3F(t.tx * TILE_SIZE, t.ty * TILE_SIZE, 0)
  local name = "tile_" .. t.tx .. "_" .. t.ty
  local outDir = "/temp/tileBake/" .. levelName() .. "/" .. name

  local ok = bakeTileToGltf(t.insts, origin, outDir, RESOLUTION, GUTTER)
  if ok then okCount = okCount + 1 else failCount = failCount + 1 end

  -- sidecar so a runtime can place the tile back at its world origin
  pcall(function()
    jsonWriteFile(outDir .. "/tile.json", {
      level = levelName(), tx = t.tx, ty = t.ty, tileSize = TILE_SIZE,
      origin = { origin.x, origin.y, origin.z },
      statics = t.statics, forest = t.forest, instances = #t.insts,
    }, true)
  end)

  log("I", "tileBake", string.format("[%d/%d] %s : %d static + %d forest -> %s",
    cursor, #tileKeys, name, t.statics, t.forest, ok and "OK" or "FAIL"))
end

local function arm()
  -- warmup lets the renderer + async bake-permutation shaders settle before the first bake
  pending, warmup, tiles, cursor, okCount, failCount = true, 60, nil, 0, 0, 0
end

M.onExtensionLoaded = arm            -- re-run on (re)load when a level is already up
M.onClientPostStartMission = arm     -- and when a level finishes loading

M.onUpdate = function()
  if not pending then return end
  if warmup > 0 then warmup = warmup - 1; return end

  if not tiles then gather(); cursor = 0; return end

  if cursor >= #tileKeys then
    pending = false
    log("I", "tileBake", string.format("=== tileBake DONE: %d ok, %d failed of %d tiles",
      okCount, failCount, #tileKeys))
    return
  end

  -- one tile per frame so the game keeps breathing between heavy bakes
  cursor = cursor + 1
  bakeOne(tiles[tileKeys[cursor]])
end

return M
