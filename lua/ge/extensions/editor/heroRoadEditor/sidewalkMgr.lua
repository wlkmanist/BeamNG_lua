-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Procedural sidewalks / kerbs for a Hero Road group. Thin adapter over the shared footway sweeper
-- (toolUtilities/walkRibbon): it reads the group's real banked mesh edge (meshEdgeL/R + meshEdgeDirL/R, set by mesh.lua)
-- and, per enabled side, sweeps the kerb + paving along it as UNIQUE geometry, so the walk sits ON the road edge and rolls
-- with the banking (never floating) without being chopped into rigid pieces to get round a bend. No junction/crossing
-- geometry here beyond the dropped kerbs -- this is the plain-run case.
--
-- The walk is a ProceduralMesh while the road is being edited, which costs nothing to rebuild, and a bake writes it out to a
-- .dae beside the road's own baked chunks and stands a persistent TSStatic on it -- the same two states the road surface has.

local M = {}

-- Module dependencies.
local walkRibbon = require('editor/toolUtilities/walkRibbon')
local meshPart = require('editor/toolUtilities/meshPart')
local daeExport = require('editor/toolUtilities/daeExport')

-- Module constants.
local max = math.max
local NEAR_PX = 400           -- the one detail level a baked walk has; a kerb is too little geometry to be worth decimating

-- Module state. Keyed by group id: { mesh, parts }. Kept module-side (NOT on the group) so the live scene objects never get
-- buffer.encoded on save or deep-copied by undo/redo -- they are pure runtime state, rebuilt from the mesh edge.
local walks = {}


-- The scene-object name of a group's walk. Stable, so a rebake never leaves a double.
local function walkName(group) return 'HeroWalk_' .. tostring(group.id) end

-- Sweep one side's walk off the banked edge rail into `parts`. edge/dir are per-station {x,y,z}; the inner rail sits offsetM
-- out from the edge, the outer rail a full walk width further. Returns the triangles laid.
local function buildSide(group, parts, edge, dir)
  local n = edge and #edge or 0
  if n < 2 or not dir then return 0 end

  local offsetM = max(0.0, group.sidewalkOffsetM or 0.0)
  local d1 = offsetM + walkRibbon.width()
  local inner, outer = table.new(n, 0), table.new(n, 0)
  for i = 1, n do
    local p, d = edge[i], dir[i]
    -- Z = the deck-edge height at the closest road point (p.z), NOT p.z + d.z*offset. `d` is the BANKED lateral (-R'/R'), so its
    -- d.z lifts the walk up along the tilted corridor -- ~width/2 * sin(bank) above the edge, opposite-signed per side, so one
    -- walk rides high on a superelevated bend. The walk is level across its width and seats on the road at the point next to it.
    inner[i] = { x = p.x + d.x * offsetM, y = p.y + d.y * offsetM, z = p.z }
    outer[i] = { x = p.x + d.x * d1, y = p.y + d.y * d1, z = p.z }
  end

  -- Pedestrian-crossing dips: take the kerb down to flush across each crossing band. Densifies the rail inside each band (so
  -- a coarse mesh edge still gets a full flush dip, not a single-vertex notch or nothing) and returns the matching
  -- per-station height multiplier. No crossings => original rails + nil.
  local scale
  inner, outer, scale = walkRibbon.crossingDips(group.crossings, group.divPoints, inner, outer)

  return walkRibbon.build(inner, outer, { parts = parts, scale = scale })
end

-- Delete a group's walk mesh and forget it.
local function removeGroup(group)
  if not group or not group.id then return end
  local rec = walks[group.id]
  if rec and rec.mesh and rec.mesh.delete then rec.mesh:delete() end
  walks[group.id] = nil
end

-- (Re)builds the group's sidewalks to match the current mesh edge + toggles. Called right after the mesh rebuild. Both sides
-- go into ONE mesh: they are the same two stones, so a road's whole footway is two draws whichever sides are on.
local function updateGroup(group)
  if not group or not group.id then return end
  local folder = group.sceneTreeFolderId and scenetree.findObjectById(group.sceneTreeFolderId)
  if not folder then return end
  removeGroup(group)

  local parts, tris = {}, 0
  if group.sidewalkLeft == true then tris = tris + buildSide(group, parts, group.meshEdgeL, group.meshEdgeDirL) end
  if group.sidewalkRight == true then tris = tris + buildSide(group, parts, group.meshEdgeR, group.meshEdgeDirR) end
  if tris == 0 then return end

  -- Collidable, via the mesh's own hull: the kerb is a step a car feels, and the walk is something it can climb onto.
  -- Transient while editing (canSave=false); a bake writes it out and stands a persistent static on it.
  walks[group.id] = { mesh = meshPart.emitObject(folder, walkName(group), parts, true), parts = parts, tris = tris }
end

--- The triangles this group's walk stands as, for the tool's own tally.
local function tris(group)
  local rec = group and walks[group.id]
  return rec and rec.tris or 0
end

--- Bake: write the group's walk to `dir` as a .dae and stand a persistent TSStatic on it, in place of the mesh. The geometry
--- is written around its own centre and the static placed there, so a road far out on the map still bakes small local
--- coordinates. Returns the scene-object name manifest, which is what un-baking removes it by.
local function burnGroup(group, dir)
  local names = {}
  local rec = group and walks[group.id]
  if not rec or not dir then return names end
  if not FS:directoryExists(dir) then FS:directoryCreate(dir) end
  local name = walkName(group)
  local path = dir .. name .. '.dae'
  local ox, oy, oz = meshPart.partsCentre(rec.parts)
  -- The mesh comes down first: it holds the name the static is about to take.
  removeGroup(group)
  if not daeExport.writeDaeLODs(path, { { size = NEAR_PX, parts = rec.parts } }, rec.parts, name, ox, oy, oz) then
    log('E', 'heroSidewalk', 'could not write ' .. path .. ': the footway is gone from this bake')
    return names
  end
  local folder = group.sceneTreeFolderId and scenetree.findObjectById(group.sceneTreeFolderId)
  local ts = createObject('TSStatic')
  ts:setField('shapeName', 0, path)
  -- Collide against the .dae's own Colmesh only, so physics is not read off the render geometry.
  ts:setField('collisionType', 0, 'Collision Mesh')
  -- Decals project onto the rendered surface, not the Colmesh.
  ts:setField('decalType', 0, 'Visible Mesh Final')
  ts.canSave = true
  ts:registerObject(name)
  if folder then folder:addObject(ts.obj) end
  ts:setPosRot(ox, oy, oz, 0, 0, 0, 1)
  names[1] = name
  return names
end


-- Public interface.
M.updateGroup = updateGroup
M.removeGroup = removeGroup
M.burnGroup = burnGroup
M.tris = tris

return M