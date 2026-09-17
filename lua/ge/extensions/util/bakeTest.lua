-- Dev-only: drives the GPU material baker + glTF exporter over a hardcoded set of
-- complex, multi-material meshes to validate the pipeline end to end. Load via:
--   -lua "extensions.load('util/bakeTest')"
-- Outputs go to /temp/bakeTest/<name>/ (atlas PNGs + <name>.gltf, co-located).
local M = {}

-- Bake at 4k for a batch of heavy meshes (8k is only sane for a single asset).
-- Gutter scales roughly with resolution.
local resolution = 4096
local gutter = 16

-- Hardcoded test set: static level buildings - multi-material and complex, but
-- (unlike vehicles) no skinning/flex/LODs and usually a shared trim-sheet UV
-- layout, which is what the single-atlas baker is built for.
local meshes = {
  "/levels/west_coast_usa/art/shapes/buildings/operahouse.dae",
  "/levels/west_coast_usa/art/shapes/buildings/tower_office6.dae",
  "/levels/west_coast_usa/art/shapes/buildings/s_bld_grand_hotel.dae",
  "/levels/west_coast_usa/art/shapes/buildings/s_bld_fire_dept.dae",
  "/levels/west_coast_usa/art/shapes/buildings/s_bld_church.dae",
  "/levels/west_coast_usa/art/shapes/buildings/s_port_warehouse.dae",
  "/levels/west_coast_usa/art/shapes/buildings/s_bld_mall_cinema.dae",
  "/levels/west_coast_usa/art/shapes/buildings/tower_pyramid.dae",
  "/levels/west_coast_usa/art/shapes/buildings/s_bld_fuel_station_trilobite_001.dae",
  "/levels/west_coast_usa/art/shapes/buildings/s_bld_chinatown_001.dae",
}

local pending = false
local warmup = 0
local idx = 0        -- index of the next mesh to process (0 = not started)
local okCount, failCount = 0, 0

local function baseName(p)
  return p:match("([^/]+)%.[dD][aA][eE]$") or p
end

local function processOne(inPath)
  local name = baseName(inPath)
  local outDir = "/temp/bakeTest/" .. name
  local gltf = outDir .. "/" .. name .. ".gltf"

  local bok, mats = pcall(function() return bakeShapeMaterialsPBR(inPath, outDir, resolution, gutter) end)
  local eok, eres = pcall(function() return exportShapeToGltf(inPath, gltf, 0, outDir) end)
  local good = bok and eok and eres == true
  if good then okCount = okCount + 1 else failCount = failCount + 1 end
  log("I", "bakeTest", string.format("[%d/%d] %s : bake(ok=%s mats=%s) export(ok=%s ret=%s) -> %s",
    idx, #meshes, name, tostring(bok), tostring(mats), tostring(eok), tostring(eres), good and "OK" or "FAIL"))
end

M.onClientPostStartMission = function()
  pending = true
  warmup = 60 -- let the renderer + async bake-permutation shaders warm up
end

M.onUpdate = function()
  if not pending then return end
  if warmup > 0 then warmup = warmup - 1; return end
  if idx >= #meshes then
    pending = false
    log("I", "bakeTest", string.format("=== bakeTest DONE: %d ok, %d failed of %d", okCount, failCount, #meshes))
    return
  end
  -- one mesh per frame so the game keeps breathing between heavy bakes
  idx = idx + 1
  processOne(meshes[idx])
end

return M
