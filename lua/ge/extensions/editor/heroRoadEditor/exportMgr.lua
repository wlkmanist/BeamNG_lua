-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- DAE bake + baked-state lifecycle for Hero Road groups. Bake writes the group's current drive mesh (deck + chamfers, every
-- material band) to .dae(s) under the level's art/heroRoad/<id> folder and switches the group to its DISABLED state, where a
-- persistent (canSave=true) TSStatic built from those files stands in for the live ProceduralMesh -- matching how TN bridges/
-- sidewalks persist. Re-enabling the group deletes the static and restores the live editable procedural surface.
--
-- State is driven by group.isEnabled (the tool's existing enable/disable, which already hides all editing UI):
--   enabled  -> live ProceduralMesh (rebuilt by the dirty pipeline); any baked static removed.
--   disabled -> baked static shown IF this group has a bake; otherwise nothing (e.g. a spline disabled before it was baked).
-- Verts are baked RELATIVE to a per-shape origin (the mesh AABB centre) and the TSStatic is placed there, so a road far from
-- world origin still bakes small local coords (well under the engine's 2048 m local range).

local M = {}

local mesh = require('editor/heroRoadEditor/mesh')
local daeExport = require('editor/toolUtilities/daeExport')
local sidewalkMgr = require('editor/heroRoadEditor/sidewalkMgr')
local barrierMgr = require('editor/heroRoadEditor/barrierMgr')
local kitPlacer = require('editor/toolUtilities/kitPlacer')
local layerMgr = require('editor/heroRoadEditor/layerMgr')

-- Module constants.
local subRoot = 'art/heroRoad/' -- level-relative root for baked shapes.


-- Current level's VFS root, or nil if no level is loaded.
local function levelDir()
  local p = getMissionPath and getMissionPath() or nil
  if not p or p == '' then return nil end
  if p:sub(-1) ~= '/' then p = p .. '/' end
  return p
end

-- This group's own bake folder (its own subfolder so a rebake can wipe just this road's chunks). nil if no level is loaded.
local function roadBakeDir(group)
  local root = levelDir()
  if not root then return nil end
  return root .. subRoot .. 'heroRoad_' .. tostring(group.id) .. '/'
end

-- The stable scene-object name of baked chunk n for this group.
local function bakedName(group, n) return 'HeroRoadBaked_' .. tostring(group.id) .. '_' .. n end

-- Delete every baked TSStatic this group placed (by stable name), so a rebake / re-enable never leaves a double. Walks n up
-- from 1 until a gap, which also catches instances reloaded from a saved level (canSave=true keeps the same names).
local function removeBaked(group)
  local n = 1
  while true do
    local o = scenetree.findObject(bakedName(group, n))
    if not o then break end
    o:delete()
    n = n + 1
  end
end

-- Wipe the group's bake folder (all files) so a rebake with FEWER chunks leaves no stale .dae/.cdae behind.
local function wipeFolder(dir)
  if not FS or not FS:directoryExists(dir) then return end
  local files = FS:findFiles(dir, '*', -1, true, false)
  if files then for i = 1, #files do FS:removeFile(files[i]) end end
end

-- Spawn the baked static(s) from this group's manifest (path + origin per chunk), placed at their origins under the group's
-- folder. canSave=true so they persist in the level like TN bridges/sidewalks. Returns the count spawned.
local function spawnBaked(group)
  local man = group.bakedManifest
  if not man or #man == 0 then return 0 end
  local folder = group.sceneTreeFolderId and scenetree.findObjectById(group.sceneTreeFolderId)
  if not folder then return 0 end
  for n = 1, #man do
    local c = man[n]
    local ts = createObject('TSStatic')
    ts:setField('shapeName', 0, c.path)
    -- Collide against the dedicated Colmesh baked into the DAE ONLY -- the visible LODs add no collision. This both fixes the
    -- old 'Visible Mesh Final' cost (per-shape collision off the render geometry) and decouples physics from render detail.
    ts:setField('collisionType', 0, 'Collision Mesh')
    -- Decals (road edges, overlays) project onto the rendered surface; the Colmesh is narrower than the visible LODs.
    ts:setField('decalType', 0, 'Visible Mesh Final')
    ts.canSave = true
    ts:registerObject(bakedName(group, n))
    folder:addObject(ts.obj)
    ts:setPosRot(c.x, c.y, c.z, 0, 0, 0, 1)
  end
  return #man
end

-- True if this group has a bake (its finalised state can be shown while disabled).
local function hasBaked(group)
  if group.isMesh == false then return group.terrainFinalized == true end
  return group.bakedManifest ~= nil and #group.bakedManifest > 0
end

-- True if every .dae in the manifest still exists on disk (guard: a baked road whose files were deleted -- or an undo that
-- restored the Live state after an unbake -- must revert to Edit rather than show a static that points at nothing).
local function bakedArtifactsExist(manifest)
  if not manifest or #manifest == 0 or not FS then return false end
  for i = 1, #manifest do
    if not FS:fileExists(manifest[i].path) then return false end
  end
  return true
end

-- Un-burn the group's persistent sidewalk + furniture pieces (made persistent by a bake) and clear their manifests, so the
-- live transient preview can rebuild them with no duplicates.
local function unburnFurniture(group)
  local changed = false
  if group.swBurnedManifest then
    kitPlacer.removeBurned(group.swBurnedManifest); group.swBurnedManifest = nil; changed = true
  end
  if group.propBurnedManifest then
    kitPlacer.removeBurned(group.propBurnedManifest); group.propBurnedManifest = nil; changed = true
  end
  if changed then kitPlacer.markDirty() end
end

-- Reconcile the group's mesh to its Edit/Live (enabled/disabled) state. Called after bake and after the toggle. This is also
-- the level-save split: everything a group owns is set transient in Edit and persistent in Live, so a level save writes a
-- road IFF it is Live -- nothing from a road you're still editing leaks into the map file.
--   enabled (Edit)  -> drop any baked static + burned sidewalks/furniture; rebuild the live procedural surface (canSave=false)
--                      + transient preview; decals canSave=false. Nothing here survives a level save.
--   disabled (Live) -> drop the live procedural surface + any lingering transient preview; show the baked static (canSave=true)
--                      and burned sidewalks (persistent TSStatics owned by the manifests); decals canSave=true.
local function applyState(group)
  -- Live requires a valid bake.
  if not group.isEnabled then
    local liveOk = hasBaked(group) and (group.isMesh == false or bakedArtifactsExist(group.bakedManifest))
    if not liveOk then group.isEnabled = true end
  end
  -- The scene-tree folder joins the same transient/persistent split as its contents, so an Edit road's (empty) folder is never
  -- written to the level (no ghost folder), while a Live/baked road's folder persists with its static + decals.
  local folder = group.sceneTreeFolderId and scenetree.findObjectById(group.sceneTreeFolderId)
  if group.isEnabled then
    removeBaked(group)
    unburnFurniture(group) -- remove the persistent (burned) sidewalks/furniture so the transient rebuild owns them again.
    layerMgr.setGroupDecalsCanSave(group, false) -- Edit: painted lines are transient -- a level save writes nothing for this road.
    if folder then folder.canSave = false end
    group.isDirty = true
  else
    mesh.removeMesh(group)
    removeBaked(group)
    layerMgr.setGroupDecalsCanSave(group, true) -- Live/baked: painted lines persist into the level with the baked static + burned sidewalks.
    if folder then folder.canSave = true end
    -- Clear any lingering TRANSIENT preview pieces. A bake already burned + DETACHED its pieces (so this finds none, and the
    -- burned Forest items -- owned by the manifests -- are untouched); a plain disable has no bake, so this is what removes
    -- the preview sidewalks/furniture that would otherwise be orphaned on screen.
    sidewalkMgr.removeGroup(group)
    barrierMgr.removeGroup(group)
    spawnBaked(group)
    -- Always rebuild collision: we just deleted the procedural surface (and maybe added a baked static), so the physics
    -- world must be rebuilt or the old procedural collision lingers on a now-invisible / replaced surface.
    if be and be.reloadCollision then be:reloadCollision() end
  end
end

-- AABB centre of a parts list -- the local origin we bake each chunk around (verts written relative to it, the TSStatic placed
-- there), so local coords stay small even for a road far from world origin (keeps every chunk well under the 2048 m range).
local function partsCentre(parts)
  local minx, miny, minz = math.huge, math.huge, math.huge
  local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
  for p = 1, #parts do
    local V = parts[p].verts
    for i = 1, #V do
      local v = V[i]
      if v.x < minx then minx = v.x end
      if v.y < miny then miny = v.y end
      if v.z < minz then minz = v.z end
      if v.x > maxx then maxx = v.x end
      if v.y > maxy then maxy = v.y end
      if v.z > maxz then maxz = v.z end
    end
  end
  return (minx + maxx) * 0.5, (miny + maxy) * 0.5, (minz + maxz) * 0.5
end

-- Bake: (re)write the DAE chunk(s) for the group's current geometry, then switch it to the baked/disabled state.
local function bakeGroup(group)
  if not group or not group.nodes or #group.nodes < 2 then return false, 'need at least 2 nodes' end

  -- Terrain road (isMesh=false): there is no deck to write. Its surface (paint) and shape (terraform) already live in the level
  -- terrain, so "finalise" just burns the sidewalks/furniture + makes the markings persistent and flips to the disabled/Live
  -- state -- exactly the mesh path minus the .dae. terrainFinalized stands in for the manifest (see hasBaked).
  if group.isMesh == false then
    unburnFurniture(group) -- drop any previous burn (re-finalise), so we never leave a double set.
    -- The road itself writes no .dae, but its footway still has to: the walk is geometry either way, and the group's own
    -- bake folder is where it goes.
    group.swBurnedManifest = sidewalkMgr.burnGroup(group, roadBakeDir(group))
    group.propBurnedManifest = barrierMgr.burnGroup(group)
    kitPlacer.markDirty()
    group.terrainFinalized = true
    group.isEnabled = false -- reuse the tool's disabled state (hides all editing UI); paint + terraform stay in the terrain.
    applyState(group)
    return true, 'terrain road finalised (paint + terraform + decals + furniture)'
  end

  local dir = roadBakeDir(group)
  if not dir then return false, 'no level loaded (cannot resolve level path)' end

  local chunks, nullSize = mesh.buildChunkLODs(group, group.chunkLenM or 120)
  if not chunks then return false, 'mesh has no geometry' end

  removeBaked(group)  -- drop old instances first (releases the shapes before we delete their files).
  wipeFolder(dir)     -- clear stale .dae/.cdae so a smaller rebake leaves nothing behind.
  if not FS:directoryExists(dir) then FS:directoryCreate(dir) end

  local base = 'heroRoad_' .. tostring(group.id)
  local manifest = {} -- nullSize (far 'nulldetail' px, or nil) comes from buildChunkLODs = the far LOD slot when set to 'no mesh'.
  for k = 1, #chunks do
    local ch = chunks[k] -- { lods = { {size, parts}, ... }, col = { part, ... } }
    local ox, oy, oz = partsCentre(ch.lods[1].parts) -- origin from LOD0 (full detail); every LOD/collision shares it.
    local path = string.format('%s%s_%03d.dae', dir, base, k - 1)
    if not daeExport.writeDaeLODs(path, ch.lods, ch.col, base .. '_' .. (k - 1), ox, oy, oz, nullSize) then
      return false, 'write failed: ' .. path
    end
    manifest[k] = { path = path, x = ox, y = oy, z = oz }
  end
  group.bakedManifest = manifest

  -- Burn the sidewalks + roadside furniture as part of the same finalize. The walk writes its own .dae into the same folder,
  -- after the wipe above, so a rebake with no footway leaves none behind.
  group.swBurnedManifest = sidewalkMgr.burnGroup(group, dir)
  group.propBurnedManifest = barrierMgr.burnGroup(group)
  kitPlacer.markDirty()

  group.isEnabled = false -- reuse the tool's disabled state (hides all editing UI).
  applyState(group)       -- remove the procedural surface, spawn the baked static(s).
  return true, string.format('%d chunk(s) -> %s', #chunks, dir)
end

-- Unbake: the ONLY way to leave Live.
local function unbakeGroup(group)
  group.isEnabled = true
  applyState(group)   -- removeBaked + unburnFurniture + decals transient + isDirty (rebuild live procedural + preview)
  group.bakedManifest = nil
  group.terrainFinalized = nil -- terrain-road equivalent of clearing the manifest (see hasBaked).
end


-- Public interface.
M.bakeGroup = bakeGroup
M.unbakeGroup = unbakeGroup
M.applyState = applyState
M.hasBaked = hasBaked

return M