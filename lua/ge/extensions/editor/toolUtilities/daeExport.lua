-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- COLLADA (.dae) exporter for baked kit pieces. Serializes one meshPart part { verts, normals, uvs, faces(0-based v/n/u) }
-- to a COLLADA 1.4.1 document that BeamNG's Torque loader reads as a plain static shape, so the instanced path can place
-- it as a TSStatic. Shared by every kit baker so all baked shapes use ONE proven format.

-- Baked shapes live under one of two roots, and which one a kit is in is the whole of what "released" means here: the
-- released root goes out with the build, the working root is filtered out of it (DevTools/deployfilters/shared_prepack.txt),
-- and promoting a kit is moving its folder across and naming it in RELEASED. Everything that resolves a baked path goes
-- through outDir(), so that list is the only place the decision is written down.

local M = {}

-- Module constants.
local PROC_ROOT = '/assets/procedural_meshes/'
local WIP_ROOT = '/assets/procedural_meshes_wip/'
local RELEASED = {} -- Nothing is promoted yet; add a kit's folder name here when its shapes ship.
local WHITE = { 1, 1, 1 }
local CACHE_ROOT = '/temp'
local floor = math.floor

-- Module state.
local prepped = {}


local function fnum(x)
  return string.format('%.6f', x)
end

-- Length -> filesystem/id-safe tag: 16.0 -> "16", 0.5 -> "0_5", 0.125 -> "0_125".
local function lenTag(L)
  local s = string.format('%.3f', L)
  s = s:gsub('0+$', ''):gsub('%.$', '') -- trim trailing zeros / dot
  return (s:gsub('%.', '_'))
end

-- Append one <geometry id="<geomId>-mesh"> block for `part` (bound to `matId`) to the string list `out`. (ox,oy,oz)
-- (optional, default 0) is a local origin subtracted from every position, so a far-from-world-origin road bakes SMALL
-- local coords (the caller places the TSStatic at that origin) -- keeping each shape well under the engine's 2048 m range.
local function appendGeometry(out, geomId, matId, part, ox, oy, oz)
  ox, oy, oz = ox or 0, oy or 0, oz or 0
  local V, N, U, F = part.verts, part.normals, part.uvs, part.faces
  local nV, nN, nU, nT = #V, #N, #U, floor(#F / 3)

  local pos = {}
  for i = 1, nV do local v = V[i]; pos[i] = fnum(v.x - ox) .. ' ' .. fnum(v.y - oy) .. ' ' .. fnum(v.z - oz) end
  local nrm = {}
  for i = 1, nN do local v = N[i]; nrm[i] = fnum(v.x) .. ' ' .. fnum(v.y) .. ' ' .. fnum(v.z) end
  local uvs = {}
  for i = 1, nU do local t = U[i]; uvs[i] = fnum(t.u) .. ' ' .. fnum(t.v) end
  -- `part.tint` is one colour for the whole part, written as a COLOR channel.
  local tint = part.tint
  local col
  if tint then
    local c = fnum(tint[1] or 1) .. ' ' .. fnum(tint[2] or 1) .. ' ' .. fnum(tint[3] or 1)
    col = {}
    for i = 1, nV do col[i] = c end
  end

  local p, pi = {}, 0
  for i = 1, #F, 3 do -- emit corner order 1,3,2 to flip winding to the standard DAE front-face convention
    local a, b, c = F[i], F[i + 2], F[i + 1]
    if tint then
      p[pi + 1] = a.v .. ' ' .. a.n .. ' ' .. a.u .. ' ' .. a.v
      p[pi + 2] = b.v .. ' ' .. b.n .. ' ' .. b.u .. ' ' .. b.v
      p[pi + 3] = c.v .. ' ' .. c.n .. ' ' .. c.u .. ' ' .. c.v
    else
      p[pi + 1] = a.v .. ' ' .. a.n .. ' ' .. a.u
      p[pi + 2] = b.v .. ' ' .. b.n .. ' ' .. b.u
      p[pi + 3] = c.v .. ' ' .. c.n .. ' ' .. c.u
    end
    pi = pi + 3
  end

  local n = #out
  out[n + 1] = '    <geometry id="' .. geomId .. '-mesh" name="' .. geomId .. '">\n      <mesh>\n'
  out[n + 2] = '        <source id="' .. geomId .. '-mesh-positions"><float_array id="' .. geomId .. '-mesh-positions-array" count="' .. tostring(nV * 3) .. '">'
  out[n + 3] = table.concat(pos, ' ') .. '</float_array>\n'
  out[n + 4] = '          <technique_common><accessor source="#' .. geomId .. '-mesh-positions-array" count="' .. tostring(nV) .. '" stride="3">'
  out[n + 5] = '<param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source>\n'
  out[n + 6] = '        <source id="' .. geomId .. '-mesh-normals"><float_array id="' .. geomId .. '-mesh-normals-array" count="' .. tostring(nN * 3) .. '">'
  out[n + 7] = table.concat(nrm, ' ') .. '</float_array>\n'
  out[n + 8] = '          <technique_common><accessor source="#' .. geomId .. '-mesh-normals-array" count="' .. tostring(nN) .. '" stride="3">'
  out[n + 9] = '<param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source>\n'
  out[n + 10] = '        <source id="' .. geomId .. '-mesh-map-0"><float_array id="' .. geomId .. '-mesh-map-0-array" count="' .. tostring(nU * 2) .. '">'
  out[n + 11] = table.concat(uvs, ' ') .. '</float_array>\n'
  out[n + 12] = '          <technique_common><accessor source="#' .. geomId .. '-mesh-map-0-array" count="' .. tostring(nU) .. '" stride="2">'
  out[n + 13] = '<param name="S" type="float"/><param name="T" type="float"/></accessor></technique_common></source>\n'
  if col then
    out[#out + 1] = '        <source id="' .. geomId .. '-mesh-colors"><float_array id="' .. geomId .. '-mesh-colors-array" count="' .. tostring(nV * 3) .. '">'
    out[#out + 1] = table.concat(col, ' ') .. '</float_array>\n'
    out[#out + 1] = '          <technique_common><accessor source="#' .. geomId .. '-mesh-colors-array" count="' .. tostring(nV) .. '" stride="3">'
    out[#out + 1] = '<param name="R" type="float"/><param name="G" type="float"/><param name="B" type="float"/></accessor></technique_common></source>\n'
  end
  out[#out + 1] = '        <vertices id="' .. geomId .. '-mesh-vertices"><input semantic="POSITION" source="#' .. geomId .. '-mesh-positions"/></vertices>\n'
  out[#out + 1] = '        <triangles material="' .. matId .. '" count="' .. tostring(nT) .. '">\n'
  out[#out + 1] = '          <input semantic="VERTEX" source="#' .. geomId .. '-mesh-vertices" offset="0"/>\n'
  out[#out + 1] = '          <input semantic="NORMAL" source="#' .. geomId .. '-mesh-normals" offset="1"/>\n'
  out[#out + 1] = '          <input semantic="TEXCOORD" source="#' .. geomId .. '-mesh-map-0" offset="2" set="0"/>\n'
  if col then
    out[#out + 1] = '          <input semantic="COLOR" source="#' .. geomId .. '-mesh-colors" offset="3" set="0"/>\n'
  end
  out[#out + 1] = '          <p>' .. table.concat(p, ' ') .. '</p>\n'
  out[#out + 1] = '        </triangles>\n      </mesh>\n    </geometry>\n'
end

-- One <geometry> holding every part in `parts`, a <triangles> block each bound to the part's own material, over shared
-- sources. For the collision mesh: the engine drops a collision mesh whose bounds are flat, so a level slab top written on
-- its own collides with nothing. Together with the faces under it, it is kept.
local function appendGeometryParts(out, geomId, parts, ox, oy, oz)
  ox, oy, oz = ox or 0, oy or 0, oz or 0
  local pos, nrm, uvs, tris = {}, {}, {}, {}
  for i = 1, #parts do
    local part = parts[i]
    local V, N, U, F = part.verts, part.normals, part.uvs, part.faces
    local v0, n0, u0 = #pos, #nrm, #uvs
    for k = 1, #V do local v = V[k]; pos[v0 + k] = fnum(v.x - ox) .. ' ' .. fnum(v.y - oy) .. ' ' .. fnum(v.z - oz) end
    for k = 1, #N do local v = N[k]; nrm[n0 + k] = fnum(v.x) .. ' ' .. fnum(v.y) .. ' ' .. fnum(v.z) end
    for k = 1, #U do local t = U[k]; uvs[u0 + k] = fnum(t.u) .. ' ' .. fnum(t.v) end
    if #F >= 3 then
      local p = {}
      for k = 1, #F - 2, 3 do -- corner order 1,3,2, as appendGeometry writes it
        local a, b, c = F[k], F[k + 2], F[k + 1]
        p[#p + 1] = (a.v + v0) .. ' ' .. (a.n + n0) .. ' ' .. (a.u + u0)
        p[#p + 1] = (b.v + v0) .. ' ' .. (b.n + n0) .. ' ' .. (b.u + u0)
        p[#p + 1] = (c.v + v0) .. ' ' .. (c.n + n0) .. ' ' .. (c.u + u0)
      end
      tris[#tris + 1] = { mat = part.material .. '-material', n = floor(#F / 3), p = table.concat(p, ' ') }
    end
  end

  out[#out + 1] = '    <geometry id="' .. geomId .. '-mesh" name="' .. geomId .. '">\n      <mesh>\n'
  out[#out + 1] = '        <source id="' .. geomId .. '-mesh-positions"><float_array id="' .. geomId .. '-mesh-positions-array" count="' .. tostring(#pos * 3) .. '">'
  out[#out + 1] = table.concat(pos, ' ') .. '</float_array>\n'
  out[#out + 1] = '          <technique_common><accessor source="#' .. geomId .. '-mesh-positions-array" count="' .. tostring(#pos) .. '" stride="3">'
  out[#out + 1] = '<param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source>\n'
  out[#out + 1] = '        <source id="' .. geomId .. '-mesh-normals"><float_array id="' .. geomId .. '-mesh-normals-array" count="' .. tostring(#nrm * 3) .. '">'
  out[#out + 1] = table.concat(nrm, ' ') .. '</float_array>\n'
  out[#out + 1] = '          <technique_common><accessor source="#' .. geomId .. '-mesh-normals-array" count="' .. tostring(#nrm) .. '" stride="3">'
  out[#out + 1] = '<param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source>\n'
  out[#out + 1] = '        <source id="' .. geomId .. '-mesh-map-0"><float_array id="' .. geomId .. '-mesh-map-0-array" count="' .. tostring(#uvs * 2) .. '">'
  out[#out + 1] = table.concat(uvs, ' ') .. '</float_array>\n'
  out[#out + 1] = '          <technique_common><accessor source="#' .. geomId .. '-mesh-map-0-array" count="' .. tostring(#uvs) .. '" stride="2">'
  out[#out + 1] = '<param name="S" type="float"/><param name="T" type="float"/></accessor></technique_common></source>\n'
  out[#out + 1] = '        <vertices id="' .. geomId .. '-mesh-vertices"><input semantic="POSITION" source="#' .. geomId .. '-mesh-positions"/></vertices>\n'
  for i = 1, #tris do
    local t = tris[i]
    out[#out + 1] = '        <triangles material="' .. t.mat .. '" count="' .. tostring(t.n) .. '">\n'
    out[#out + 1] = '          <input semantic="VERTEX" source="#' .. geomId .. '-mesh-vertices" offset="0"/>\n'
    out[#out + 1] = '          <input semantic="NORMAL" source="#' .. geomId .. '-mesh-normals" offset="1"/>\n'
    out[#out + 1] = '          <input semantic="TEXCOORD" source="#' .. geomId .. '-mesh-map-0" offset="2" set="0"/>\n'
    out[#out + 1] = '          <p>' .. t.p .. '</p>\n'
    out[#out + 1] = '        </triangles>\n'
  end
  out[#out + 1] = '      </mesh>\n    </geometry>\n'
end

-- A level identical to the next one down is one mesh drawn over a longer range, so the run is written once at its smallest
-- size: a detail draws from its size upward, and keeping the largest instead would leave a gap where the copies were.
local function mergeSameLevels(lods)
  local out, prev = {}, nil
  for i = 1, #lods do
    local ps, geo = lods[i].parts, {}
    for p = 1, #ps do appendGeometry(geo, 'g' .. p, ps[p].material, ps[p]) end
    local key = table.concat(geo)
    if key == prev then
      out[#out].size = lods[i].size
    else
      out[#out + 1] = { size = lods[i].size, parts = ps }
      prev = key
    end
  end
  return out
end

-- Append one scene <node id="nodeId"> instancing geometry `<geomId>-mesh` (bound to `matId`, or to each id in a list of
-- them), indented by `pad` spaces.
local function appendNode(out, nodeId, geomId, matId, pad)
  out[#out + 1] = pad .. '<node id="' .. nodeId .. '" name="' .. nodeId .. '" type="NODE">\n'
  out[#out + 1] = pad .. '  <matrix sid="transform">1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1</matrix>\n'
  out[#out + 1] = pad .. '  <instance_geometry url="#' .. geomId .. '-mesh" name="' .. nodeId .. '">\n'
  out[#out + 1] = pad .. '    <bind_material><technique_common>\n'
  if type(matId) == 'table' then
    for i = 1, #matId do
      out[#out + 1] = pad .. '      <instance_material symbol="' .. matId[i] .. '" target="#' .. matId[i] .. '"/>\n'
    end
  else
    out[#out + 1] = pad .. '      <instance_material symbol="' .. matId .. '" target="#' .. matId .. '"/>\n'
  end
  out[#out + 1] = pad .. '    </technique_common></bind_material>\n'
  out[#out + 1] = pad .. '  </instance_geometry>\n'
  out[#out + 1] = pad .. '</node>\n'
end

-- Append an EMPTY scene node named `nulldetail<size>` (identity matrix, no geometry). Torque reads this as a null detail
-- level: below `size` on-screen pixels the shape renders NOTHING. This is how a baked road's far LOD vanishes (the terrain +
-- draped decals carry the look at distance) instead of clamping to -- and forever drawing -- the coarsest visible mesh.
local function appendNullNode(out, size, pad)
  local nm = 'nulldetail' .. tostring(size)
  local n = #out
  out[n + 1] = pad .. '<node id="' .. nm .. '" name="' .. nm .. '" type="NODE">\n'
  out[n + 2] = pad .. '  <matrix sid="transform">1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1</matrix>\n'
  out[n + 3] = pad .. '</node>\n'
end

-- One phong <effect> block (the proven grey default -- the real look comes from the bound game material). effId is the
-- effect element id; kept a parameter so multi-material docs can give each part a unique effect id.
local function phongEffect(effId)
  return '    <effect id="' .. effId .. '"><profile_COMMON><technique sid="common"><phong>\n' ..
    '      <emission><color sid="emission">0 0 0 1</color></emission>\n' ..
    '      <ambient><color sid="ambient">0 0 0 1</color></ambient>\n' ..
    '      <diffuse><color sid="diffuse">0.64 0.64 0.64 1</color></diffuse>\n' ..
    '      <specular><color sid="specular">0.5 0.5 0.5 1</color></specular>\n' ..
    '      <shininess><float sid="shininess">50</float></shininess>\n' ..
    '    </phong></technique></profile_COMMON></effect>\n'
end

local function docHeader()
  return '<?xml version="1.0" encoding="utf-8"?>\n' ..
    '<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">\n' ..
    '  <asset>\n' ..
    '    <contributor><authoring_tool>BeamNG heroRoadEditor daeExport</authoring_tool></contributor>\n' ..
    '    <created>2020-01-01T00:00:00</created><modified>2020-01-01T00:00:00</modified>\n' ..
    '    <unit name="meter" meter="1"/>\n    <up_axis>Z_UP</up_axis>\n  </asset>\n'
end

-- Serialize one baked part to a COLLADA document. matName is the game material (bound by name); gid is the geometry/node
-- id (also the file base name). Emits a plain single-node shape (no Colmesh -- see collision note at the top).
local function colladaDoc(part, matName, gid)
  local matId = matName .. '-material'
  local out = {
    docHeader(),
    '  <library_effects>\n', phongEffect(matName .. '-effect'), '  </library_effects>\n',
    '  <library_images/>\n',
    '  <library_materials>\n',
    '    <material id="' .. matId .. '" name="' .. matName .. '"><instance_effect url="#' .. matName .. '-effect"/></material>\n',
    '  </library_materials>\n',
    '  <library_geometries>\n',
  }

  appendGeometry(out, gid, matId, part)

  out[#out + 1] = '  </library_geometries>\n  <library_visual_scenes>\n    <visual_scene id="Scene" name="Scene">\n'
  appendNode(out, gid, gid, matId, '      ')
  out[#out + 1] = '    </visual_scene>\n  </library_visual_scenes>\n  <scene><instance_visual_scene url="#Scene"/></scene>\n</COLLADA>\n'

  return table.concat(out)
end

-- Serialize MULTIPLE material parts into ONE COLLADA doc (one <effect>/<material>/<geometry>/<node> per part). Each part
-- carries its own `.material` (the game material, bound by name). Parts may share a material name -- element IDs are keyed
-- by part index ('mat<i>...') so they never collide, while the <material name=...> still resolves the same game material.
-- Used for multi-material shapes like a road chunk (carriageway + shoulder bands in one object). Returns the doc string.
local function colladaDocMulti(parts, gid, ox, oy, oz)
  local out = { docHeader(), '  <library_effects>\n' }
  for i = 1, #parts do out[#out + 1] = phongEffect('mat' .. i .. '-effect') end
  out[#out + 1] = '  </library_effects>\n  <library_images/>\n  <library_materials>\n'
  for i = 1, #parts do
    out[#out + 1] = '    <material id="mat' .. i .. '-material" name="' .. parts[i].material ..
      '"><instance_effect url="#mat' .. i .. '-effect"/></material>\n'
  end
  out[#out + 1] = '  </library_materials>\n  <library_geometries>\n'
  for i = 1, #parts do appendGeometry(out, gid .. '_' .. i, 'mat' .. i .. '-material', parts[i], ox, oy, oz) end
  out[#out + 1] = '  </library_geometries>\n  <library_visual_scenes>\n    <visual_scene id="Scene" name="Scene">\n'
  for i = 1, #parts do appendNode(out, gid .. '_' .. i, gid .. '_' .. i, 'mat' .. i .. '-material', '      ') end
  out[#out + 1] = '    </visual_scene>\n  </library_visual_scenes>\n  <scene><instance_visual_scene url="#Scene"/></scene>\n</COLLADA>\n'
  return table.concat(out)
end

-- Serialize a MULTI-LOD + collision shape into ONE COLLADA doc, matching the Torque/BeamNG shape conventions so a single
-- TSStatic renders the right detail with distance AND collides against a dedicated mesh (collisionType 'Collision Mesh'):
--   * lods = { {size=S, parts={part,...}}, ... } (descending S). Each visible LOD's nodes are named '<gid>_p<i>_L<S>'. Torque
--     strips the TRAILING number (S) to group same-base nodes into one object with several detail levels; S is the detail
--     size (on-screen pixel threshold, bigger = shown when nearer/larger). LOD0 (largest S) is the full-detail close-up mesh.
--   * colParts = { part, ... } (deck only, no chamfer) -> one node 'Colmesh-1' holding them all. A name starting with
--     'Colmesh' + a NEGATIVE trailing size (-1) marks a collision mesh: never rendered, used only for physics. The visible
--     LODs add NO collision.
--   * nullSize (optional) -> an empty 'nulldetail<nullSize>' node so the shape vanishes below that size (far LOD = no mesh).
-- ALL of these nodes are nested under a start01 -> base00 empty hierarchy, which the importer REQUIRES to build the LOD +
-- collision sets (a flat node list imports as an empty shape: invisible mesh and zero collision).
-- Materials are de-duplicated by game-material NAME (bound by name, like the other bakers). (ox,oy,oz) is the local origin
-- subtracted from every vertex (place the TSStatic there) so a far-from-origin road bakes small local coords. Returns the doc.
local function colladaDocLODs(lods, colParts, gid, ox, oy, oz, nullSize)
  lods = mergeSameLevels(lods)
  -- Unique game materials across every LOD + collision part (each part carries its own .material).
  local matOrder, matSeen = {}, {}
  local function addMat(name)
    if name and not matSeen[name] then matSeen[name] = true; matOrder[#matOrder + 1] = name end
  end
  for li = 1, #lods do local ps = lods[li].parts; for i = 1, #ps do addMat(ps[i].material) end end
  if colParts then for i = 1, #colParts do addMat(colParts[i].material) end end
  if #matOrder == 0 then addMat('m_asphalt_new_01') end -- safety: never emit a doc with zero materials.

  local out = { docHeader(), '  <library_effects>\n' }
  for i = 1, #matOrder do out[#out + 1] = phongEffect(matOrder[i] .. '-effect') end
  out[#out + 1] = '  </library_effects>\n  <library_images/>\n  <library_materials>\n'
  for i = 1, #matOrder do
    out[#out + 1] = '    <material id="' .. matOrder[i] .. '-material" name="' .. matOrder[i] ..
      '"><instance_effect url="#' .. matOrder[i] .. '-effect"/></material>\n'
  end
  out[#out + 1] = '  </library_materials>\n  <library_geometries>\n'

  -- Geometries + the scene nodes that instance them (collected so the geometry + visual_scene passes stay separate blocks).
  local nodes = {}
  for li = 1, #lods do
    local S, ps = lods[li].size, lods[li].parts
    for p = 1, #ps do
      local geomId = gid .. '_L' .. tostring(S) .. '_p' .. p
      local matId = ps[p].material .. '-material'
      appendGeometry(out, geomId, matId, ps[p], ox, oy, oz)
      nodes[#nodes + 1] = { name = gid .. '_p' .. p .. '_L' .. tostring(S), geom = geomId, mat = matId } -- trailing S = detail size.
    end
  end
  if colParts and #colParts > 0 then
    local geomId, colMats, seen = gid .. '_col', {}, {}
    appendGeometryParts(out, geomId, colParts, ox, oy, oz)
    for c = 1, #colParts do
      local matId = colParts[c].material .. '-material'
      if not seen[matId] then seen[matId] = true; colMats[#colMats + 1] = matId end
    end
    nodes[#nodes + 1] = { name = 'Colmesh-1', geom = geomId, mat = colMats } -- 'Colmesh...-1' = the collision mesh.
  end

  -- BeamNG's importer only assembles detail levels + collision when the meshes sit under a start01 -> base00 empty hierarchy
  -- (base00 = shape root, start01 = object container). WITHOUT it the shape imports but is EMPTY -- invisible mesh AND no
  -- collision -- because the '_L<size>' detail nodes and the 'Colmesh-1' node are never grouped into the shape's LOD/collision
  -- sets. Every LOD, the Colmesh(es) and the nulldetail marker are children of start01 (identity matrices, so verts are unmoved).
  local ID = '1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1'
  out[#out + 1] = '  </library_geometries>\n  <library_visual_scenes>\n    <visual_scene id="Scene" name="Scene">\n'
  out[#out + 1] = '      <node id="base00" name="base00" type="NODE">\n        <matrix sid="transform">' .. ID .. '</matrix>\n'
  out[#out + 1] = '        <node id="start01" name="start01" type="NODE">\n          <matrix sid="transform">' .. ID .. '</matrix>\n'
  for i = 1, #nodes do appendNode(out, nodes[i].name, nodes[i].geom, nodes[i].mat, '          ') end
  if nullSize then appendNullNode(out, nullSize, '          ') end -- nulldetail comes after all real levels.
  out[#out + 1] = '        </node>\n      </node>\n'
  out[#out + 1] = '    </visual_scene>\n  </library_visual_scenes>\n  <scene><instance_visual_scene url="#Scene"/></scene>\n</COLLADA>\n'
  return table.concat(out)
end

-- Serialize `part` and write it to the VFS `path` as a plain static shape. Returns true on success.
local function writeDae(path, part, matName, gid)
  return writeFile(path, colladaDoc(part, matName, gid))
end

local function anyTint(parts)
  for j = 1, #(parts or {}) do if parts[j].tint then return true end end
  return false
end

local function whiten(parts)
  for j = 1, #(parts or {}) do if not parts[j].tint then parts[j].tint = WHITE end end
end

-- Both writers get this, not just the LOD one: a front door is a single level of seven parts written through writeDaeParts,
-- and it was left half coloured for exactly as long as this only guarded writeDaeLODs.
local function evenTintsLODs(lods)
  local any = false
  for i = 1, #lods do if anyTint(lods[i].parts) then any = true; break end end
  if not any then return end
  for i = 1, #lods do whiten(lods[i].parts) end
end

-- Serialize a multi-LOD + collision shape (see colladaDocLODs) and write it to the VFS `path`. Returns true on success.
local function writeDaeLODs(path, lods, colParts, gid, ox, oy, oz, nullSize)
  evenTintsLODs(lods)
  return writeFile(path, colladaDocLODs(lods, colParts, gid, ox, oy, oz, nullSize))
end

-- Serialize a list of material `parts` (each with .material) and write them to the VFS `path` as one multi-material static
-- shape. gid is the geometry/node id base. (ox,oy,oz) (optional) is a local origin subtracted from every vertex so the shape
-- stays near its own origin (place the TSStatic at that origin). Returns true on success.
local function writeDaeParts(path, parts, gid, ox, oy, oz)
  if anyTint(parts) then whiten(parts) end
  return writeFile(path, colladaDocMulti(parts, gid, ox, oy, oz))
end


--- Start a bake run, so the next prepDir on each folder empties it again.
local function beginBake()
  prepped = {}
end

local function emptyDir(dir)
  if not FS:directoryExists(dir) then return end
  local files = FS:findFiles(dir, '*', -1, true, false)
  if files then for i = 1, #files do FS:removeFile(files[i]) end end
end

local function prepDir(dir)
  if not FS then return end
  -- prepDir EMPTIES the folder, so it only ever gets pointed at one this module owns. A kit built with a hand-written path,
  -- or one whose folder was moved between the two roots without being renamed in RELEASED, would otherwise wipe whatever it
  -- happened to land on.
  if dir:sub(1, #PROC_ROOT) ~= PROC_ROOT and dir:sub(1, #WIP_ROOT) ~= WIP_ROOT then
    log('E', 'daeExport', 'refusing to prep ' .. tostring(dir) .. ': not under a procedural mesh root')
    return
  end
  local seen = prepped[dir]
  prepped[dir] = true
  if seen then return end
  if FS:directoryExists(dir) then emptyDir(dir) else FS:directoryCreate(dir, true) end
  emptyDir(CACHE_ROOT .. dir)
end

--- Where one kit's baked shapes live, released root or working root. Takes the folder name alone.
local function outDir(folder) return (RELEASED[folder] and PROC_ROOT or WIP_ROOT) .. folder .. '/' end


-- Public interface.
M.procRoot = PROC_ROOT
M.wipRoot = WIP_ROOT

M.outDir = outDir
M.beginBake = beginBake
M.prepDir = prepDir
M.lenTag = lenTag
M.writeDae = writeDae
M.writeDaeParts = writeDaeParts
M.writeDaeLODs = writeDaeLODs

return M