-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Import mesh-weight diagnostic. A single import creates two kinds of geometry:
--   * UNIQUE ProceduralMeshes (buildings, bridge/tunnel decks, gantries) -- each is its own vertex buffer with its
--     own super-linear collision build, so this is the cost we want to shrink with kit pieces.
--   * INSTANCED props (TSStatic .dae -- sidewalk/kerb + bridge soffit/pier kit pieces, barriers, fences, signs, lamps, rails, bollards)
--     which the engine's static-shape manager already batches by shape, and Forest items batched harder still.
-- The generators call recordMesh() as they build each ProceduralMesh; the importer calls begin() at the start and
-- report() at the very end. report() re-checks every recorded name against the live scene (so a mesh that was
-- rebuilt/renamed/dropped mid-import is counted once, from its final state) and enumerates the instanced props +
-- Forest + water directly, then logs a per-family rollup so we can see what is heaviest before compressing it.
--

local M = {}

local logTag = 'meshStats'

-- Collection is only live between begin() and report() (i.e. during an import). Outside that window every record
-- call is a no-op, so ordinary editing (which also rebuilds these meshes) never touches the tally.
local active = false
local meshes = {}   -- name -> { family, verts, tris } : one live ProceduralMesh, validated by name at report time
local parts = {}    -- category -> { verts, tris }     : fine per-part split for the merged bridge/tunnel meshes


local function begin()
  active = true
  meshes = {}
  parts = {}
end

-- Record one ProceduralMesh by its scene-tree NAME (so a later rebuild under the same name overwrites, and a
-- render pass that renamed/dropped it is caught by the existence check in report()). family groups the rollup.
local function recordMesh(name, family, nVerts, nTris)
  if not active or not name then return end
  meshes[name] = { family = family or 'other', verts = nVerts or 0, tris = nTris or 0 }
end

-- Record the geometry of ONE part inside a merged mesh, by its structural category (bridge.deck, tunnel.floor /
-- tunnel.shell; soffit + pier are now instanced TSStatics, counted in the instanced-props scan). Additive: a bridge/tunnel cluster remeshes exactly once per import,
-- so the running sum is accurate for the import (this is a breakdown of, not a duplicate of, the mesh totals).
local function recordParts(category, nVerts, nTris)
  if not active or not category then return end
  local p = parts[category]
  if not p then p = { verts = 0, tris = 0 }; parts[category] = p end
  p.verts = p.verts + (nVerts or 0)
  p.tris = p.tris + (nTris or 0)
end

local function baseName(path)
  if not path or path == '' then return '?' end
  return (tostring(path):gsub('\\', '/'):match('([^/]+)$')) or tostring(path)
end

-- Sorted array of { key, verts, tris } (or { key, count }) from a map, heaviest first, for a stable readable log.
local function sortedByTris(map)
  local out = {}
  for k, v in pairs(map) do out[#out + 1] = { key = k, verts = v.verts, tris = v.tris } end
  table.sort(out, function(a, b) return a.tris > b.tris end)
  return out
end

local function sortedByCount(map)
  local out = {}
  for k, v in pairs(map) do out[#out + 1] = { key = k, count = v } end
  table.sort(out, function(a, b) return a.count > b.count end)
  return out
end

-- Aggregate everything and log the rollup. Ends the collection window.
local function report(tag)
  tag = tag or logTag
  if not active then
    log('I', tag, '[mesh] no active mesh-stats session'); return
  end
  active = false

  -- 1) Unique ProceduralMesh geometry, per family, validated against the live scene (drops stale names).
  local fam = {}
  local totMesh, totVerts, totTris = 0, 0, 0
  for name, rec in pairs(meshes) do
    if scenetree.findObject(name) then
      local f = fam[rec.family]
      if not f then f = { verts = 0, tris = 0, meshes = 0 }; fam[rec.family] = f end
      f.meshes = f.meshes + 1; f.verts = f.verts + rec.verts; f.tris = f.tris + rec.tris
      totMesh = totMesh + 1; totVerts = totVerts + rec.verts; totTris = totTris + rec.tris
    end
  end

  -- 2) Instanced props: every TSStatic left after the import's stock-wipe is ours; group by shape file.
  local shapes = {}
  local totInst, totShapes = 0, 0
  local ok, names = pcall(scenetree.findClassObjects, 'TSStatic')
  if ok and names then
    for i = 1, #names do
      local o = scenetree.findObject(names[i])
      if o then
        local sh = baseName(o:getField('shapeName', 0))
        if not shapes[sh] then shapes[sh] = 0; totShapes = totShapes + 1 end
        shapes[sh] = shapes[sh] + 1
        totInst = totInst + 1
      end
    end
  end

  -- 3) Forest instances (vegetation + hedges) and water objects, best-effort.
  local forestN = 0
  local okf, forest = pcall(core_forest.getForestObject)
  if okf and forest then
    local okd, fd = pcall(function() return forest:getData() end)
    if okd and fd then
      local oki, items = pcall(function() return fd:getItems() end)
      if oki and items then forestN = #items end
    end
  end
  local waterN = 0
  for _, cls in ipairs({ 'WaterBlock', 'WaterPlane' }) do
    local okw, ws = pcall(scenetree.findClassObjects, cls)
    if okw and ws then waterN = waterN + #ws end
  end

  -- Log the rollup.
  log('I', tag, '[mesh] ===================== import mesh summary =====================')
  log('I', tag, '[mesh] unique ProceduralMesh geometry (each = its own collision build):')
  for _, e in ipairs(sortedByTris(fam)) do
    local f = fam[e.key]
    log('I', tag, string.format('[mesh]   %-14s %5d meshes  %9d tris  %9d verts', e.key, f.meshes, f.tris, f.verts))
  end
  log('I', tag, string.format('[mesh]   %-14s %5d meshes  %9d tris  %9d verts', 'TOTAL', totMesh, totTris, totVerts))
  if next(parts) then
    local segs = {}
    for _, e in ipairs(sortedByTris(parts)) do segs[#segs + 1] = string.format('%s %dt', e.key, e.tris) end
    log('I', tag, '[mesh]   merged-mesh breakdown: ' .. table.concat(segs, '  '))
  end
  log('I', tag, '[mesh] instanced props (TSStatic, engine-batched by shape):')
  for _, e in ipairs(sortedByCount(shapes)) do
    log('I', tag, string.format('[mesh]   %-32s x %d', e.key, e.count))
  end
  log('I', tag, string.format('[mesh]   TOTAL instanced: %d objects across %d shapes', totInst, totShapes))
  log('I', tag, string.format('[mesh] forest items: %d   |   water objects: %d', forestN, waterN))
  log('I', tag, string.format('[mesh] HEADLINE: %d unique tris in %d meshes  vs  %d instanced props (%d shapes), %d forest',
    totTris, totMesh, totInst, totShapes, forestN))
  log('I', tag, '[mesh] ===============================================================')
end


-- Public interface.
M.begin = begin
M.recordMesh = recordMesh
M.recordParts = recordParts
M.report = report

return M