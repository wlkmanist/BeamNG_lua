-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Repair-patch clusters for Hero Road: each placed cluster (group.repairs[i], authored in the Features tab + the shared
-- roadPlaceables controller) is rendered as a SEEDED SCATTER of asphalt-patch decal INSTANCES on the road surface -- not a
-- DecalRoad. This mirrors roadArchitect/decals.lua's "unique decal patch" path: a shared DecalData template per material +
-- editor.addDecalInstanceWithTan per patch. Surface-only: no mesh / sidewalk / collision impact, so a rebuild just restamps
-- the decals. The whole arrangement is a pure function of the cluster's shaping knobs + seed, so it rebuilds identically
-- after save / undo.
--
-- The live scene handles are kept HERE (module store, keyed by group.id), NOT on the group: addDecalInstanceWithTan returns
-- userdata, and the group table gets buffer-encoded for undo/session snapshots (which can't serialize userdata). The group
-- itself only ever holds plain data (group.repairs), and this scatter is rebuilt from it by the dirty pass.

local M = {}

-- Module constants.
local min, max, floor, sqrt, sin, cos, pi = math.min, math.max, math.floor, math.sqrt, math.sin, math.cos, math.pi
local random, randomseed = math.random, math.randomseed
local patchRenderPriority = 6 -- above the asphalt, below the painted markings (12+) so lane lines still read over a patch.
local patchLift = 0.03        -- tiny lift along the surface normal so a patch doesn't z-fight the road mesh.
local maxPatchesPerCluster = 300 -- hard cap so a silly density on a long band can't spawn thousands of decals.

-- Atlas layout (rows x cols = number of tile variants the scatter picks a frame from) for the patch material. This MUST be a
-- true "decal" material (a tiled atlas stamped per instance), NOT a DecalRoad ribbon material like road_patches1 -- a ribbon
-- texture (texLen ~80m, full road width) maps its UVs wrong on a small square instance. Layout matches roadArchitect.
local atlas = {
  asphalt_patches = { rows = 4, cols = 2 }, -- repair patches (8 frames)
}
-- Only the square / rectangular patch cells look right stamped as a decal; frames 0 and 4 are skipped.
local patchFrames = { 1, 2, 3, 5, 6, 7 }

-- Module state.
-- Live scene handles per group: store[group.id] = { instances = { <decal userdata> }, templateIds = { <DecalData id> } }.
local store = {}


-- Delete a group's live repair decal instances + DecalData templates, and forget the bucket. Called on every rebuild + on
-- teardown.
local function clearRepairs(group)
  if not group then return end
  local b = store[group.id]
  if not b then return end
  for i = 1, #b.instances do editor.deleteDecalInstance(b.instances[i]) end
  for i = 1, #b.templateIds do
    local obj = scenetree.findObjectById(b.templateIds[i])
    if obj and simObjectExists(obj) then obj:delete() end
  end
  store[group.id] = nil
end

-- Interpolated centreline frame at normalized arc-length t01: point (px,py,pz), unit binormal (bx,by,bz, +right of travel)
-- and unit forward tangent (tx,ty,tz), or nil. total is the precomputed plan-view length.
local function stationFrame(div, binormals, total, t01)
  local n = #div
  local target = min(max(t01, 0), 1) * total
  local acc = 0
  for i = 1, n - 1 do
    local a, b = div[i], div[i + 1]
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    local segLen = sqrt(dx * dx + dy * dy)
    if acc + segLen >= target or i == n - 1 then
      local tt = segLen > 1e-9 and min(max((target - acc) / segLen, 0), 1) or 0
      local b0, b1 = binormals[i], binormals[i + 1]
      local bx = b0.x + (b1.x - b0.x) * tt
      local by = b0.y + (b1.y - b0.y) * tt
      local bz = b0.z + (b1.z - b0.z) * tt
      local bl = sqrt(bx * bx + by * by + bz * bz)
      if bl > 1e-9 then bx, by, bz = bx / bl, by / bl, bz / bl end
      local tl = sqrt(dx * dx + dy * dy + dz * dz)
      if tl > 1e-9 then dx, dy, dz = dx / tl, dy / tl, dz / tl end
      return a.x + (b.x - a.x) * tt, a.y + (b.y - a.y) * tt, a.z + (b.z - a.z) * tt, bx, by, bz, dx, dy, dz
    end
    acc = acc + segLen
  end
  return nil
end

-- Ensure a DecalData template exists for a material (cached per build in local map; ids tracked in the bucket for teardown).
local function ensureTemplate(b, folder, cache, material)
  local t = cache[material]
  if t then return t end
  local lay = atlas[material] or { rows = 1, cols = 1 }
  t = createObject('DecalData')
  t:setField('renderPriority', 0, patchRenderPriority)
  t:setField('textureLength', 0, 1.0)
  t:setField('texRows', 0, lay.rows)
  t:setField('texCols', 0, lay.cols)
  t:setField('size', 0, 1.0)
  t:setField('material', 0, material)
  t:registerObject(Sim.getUniqueName('HeroRoad_RepairTemplate'))
  folder:addObject(t)
  cache[material] = t
  b.templateIds[#b.templateIds + 1] = t:getId()
  return t
end

-- Scatter one cluster's patches. Count comes from density x footprint area; every patch's station / lateral / size / frame /
-- yaw is drawn from the seeded RNG so the layout is deterministic.
local function buildCluster(b, folder, cache, rc, div, binormals, total, leftExt, rightExt)
  local fullWidth = leftExt + rightExt
  local spread = max(0.1, (rc.coverage or 0.7)) * fullWidth      -- lateral extent of the scatter band (m)
  local centreLat = (rc.offset or 0.0) * (fullWidth * 0.5)       -- lateral shift of the band centre (m)
  local lengthM = max(0.5, rc.lengthM or 8.0)
  local sizeMin = min(rc.sizeMin or 0.6, rc.sizeMax or 1.4)
  local sizeMax = max(rc.sizeMin or 0.6, rc.sizeMax or 1.4)
  local count = floor((rc.density or 0.6) * lengthM * spread + 0.5)
  count = min(max(count, 1), maxPatchesPerCluster)

  local template = ensureTemplate(b, folder, cache, rc.material)
  randomseed(rc.seed or 1)
  for _ = 1, count do
    local deltaS = (random() - 0.5) * lengthM
    local t01 = min(max((rc.t or 0.5) + deltaS / total, 0), 1)
    local px, py, pz, bx, by, bz, tx, ty, tz = stationFrame(div, binormals, total, t01)
    if px then
      -- Lateral position across the road, clamped just inside the carriageway edges.
      local lat = centreLat + (random() - 0.5) * spread
      lat = min(max(lat, -leftExt + 0.15), rightExt - 0.15)
      -- Surface normal from the frame (forward x right -> up), z-corrected; falls back to world up if degenerate.
      local nx, ny, nz = by * tz - bz * ty, bz * tx - bx * tz, bx * ty - by * tx
      if nz < 0 then nx, ny, nz = -nx, -ny, -nz end
      local nl = sqrt(nx * nx + ny * ny + nz * nz)
      if nl < 1e-6 then nx, ny, nz, nl = 0, 0, 1, 1 end
      nx, ny, nz = nx / nl, ny / nl, nz / nl
      -- Yaw the tangent in-plane by the rotation jitter to break up alignment.
      local yaw = (random() * 2 - 1) * pi * (rc.rotJitter or 1.0)
      local c, s = cos(yaw), sin(yaw)
      local tgt = vec3(tx * c - ty * s, tx * s + ty * c, tz)
      local pos = vec3(px + bx * lat + nx * patchLift,
                       py + by * lat + ny * patchLift,
                       pz + bz * lat + nz * patchLift)
      local nml = vec3(nx, ny, nz)
      local size = sizeMin + (sizeMax - sizeMin) * random()
      local frame = patchFrames[1 + floor(random() * #patchFrames)]
      local inst = editor.addDecalInstanceWithTan(pos, nml, tgt, template, size, frame, 0, 1)
      if inst then b.instances[#b.instances + 1] = inst end
    end
  end
end

-- (Re)build every placed repair cluster's decal scatter. No-op (past the clear) when the road has none / isn't ready.
local function updateRepairs(group)
  clearRepairs(group)
  if not group then return end
  local repairs = group.repairs
  if not repairs or #repairs == 0 then return end
  local div, binormals = group.divPoints, group.binormals
  if not div or #div < 2 or not binormals then return end
  local folder = group.sceneTreeFolderId and scenetree.findObjectById(group.sceneTreeFolderId)
  if not folder then return end
  local leftExt = group.leftExtM or ((group.divWidths and group.divWidths[1] or 5) * 0.5)
  local rightExt = group.rightExtM or leftExt
  local total = 0
  for i = 2, #div do total = total + sqrt((div[i].x - div[i - 1].x) ^ 2 + (div[i].y - div[i - 1].y) ^ 2) end
  if total <= 1e-6 then return end
  local b = { instances = {}, templateIds = {} }
  store[group.id] = b
  local cache = {}
  for c = 1, #repairs do
    buildCluster(b, folder, cache, repairs[c], div, binormals, total, leftExt, rightExt)
  end
end


-- Public interface.
M.updateRepairs = updateRepairs
M.clearRepairs = clearRepairs

return M