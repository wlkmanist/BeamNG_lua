-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Module constants.
local dowelLength = 0.1                                                                                     -- The length of the dowel sections used in link roads, in meters.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}


-- External modules used.
local profileMgr = require('editor/tech/roadArchitect/profiles')                                            -- Manages the profiles structure/handles profile calculations.

-- Private constants.
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max

-- Module state.
local meshes = {}                                                                                           -- The collection of road (procedural) meshes.

-- Module constants.
local uvs = { { u = 0.0, v = 0.0 }, { u = 0.0, v = 1.0 }, { u = 1.0, v = 0.0 }, { u = 1.0, v = 1.0 } }      -- Fixed uv-map corner points (used in all road meshes).
local origin = vec3(0, 0, 0)                                                                                -- A vec3 used for representing the scene origin.
local scaleVec = vec3(1, 1, 1)                                                                              -- A vec3 used for representing uniform scale.
local tmp1, tmp2, tmp3 = vec3(0, 0), vec3(0, 0), vec3(0, 0)                                                 -- Some temporary vectors.
local materials =  {                                                                                        -- The mesh materials, per type.
  road_lane = 'm_asphalt_new_01',
  cycle_lane = 'm_asphalt_new_01',
  sidewalk = 'slabs_large',
  curb = 'slabs_large' }
local curbMaterial = 'm_sidewalk_curb_trim_01'                                                              -- The material for the special faces of the curb.
local defaultMaterial = 'm_asphalt_new_01'


-- Identifies the different lateral sections of the road, by lane indexing.
local function computeSections(r)
  local sections, sCtr = {}, 1
  local lMin, lMax = r.laneKeys[1], r.laneKeys[#r.laneKeys]
  local rData = r.renderData
  local tCur = rData[1][lMin][8]
  local tBuild = { min = lMin, type = tCur }
  for i = lMin + 1, lMax do
    if i ~= 0 then
      local tHere = rData[1][i][8]
      if tHere ~= tBuild.type then
        tBuild.max = i - 1
        sections[sCtr] = tBuild
        sCtr = sCtr + 1
        tBuild = { min = i, type = tHere }
      end
    end
  end

  -- Add the final lateral section.
  tBuild.max = lMax
  sections[sCtr] = tBuild

  return sections
end

-- Creates a road mesh from the given rendering data.
-- [The index of the road is used outside this module to reference the mesh later].
local function createRoad(r, roadMeshIdx)

  local rData = r.renderData
  local numDivs = #rData

  local sections = computeSections(r)
  meshes[r.name] = {}
  for s = 1, #sections do

    local sec = sections[s]
    local ty = sec.type
    if not (ty == 'road_lane' and not r.isMesh) and ty ~= 'island' then                             -- Do not create meshes for any island sections.
      local material = materials[ty] or defaultMaterial
      local lMin, lMax = sec.min, sec.max

      -- Compute the ring indices.
      local ringRaw, ctr = {}, 1
      for i = lMin, lMax do                                                                         -- Add top face vertices, clockwise around lanes.
        if rData[1][i] then
          ringRaw[ctr] = { idx1 = i, idx2 = 1 }
          ringRaw[ctr + 1] = { idx1 = i, idx2 = 2 }
          ctr = ctr + 2
        end
      end
      for i = lMax, lMin, -1 do                                                                     -- Add bottom face vertices, clockwise around lanes.
        if rData[1][i] then
          ringRaw[ctr] = { idx1 = i, idx2 = 3 }
          ringRaw[ctr + 1] = { idx1 = i, idx2 = 4 }
          ctr = ctr + 2
        end
      end

      local ring, ctr = { ringRaw[1] }, 2                                                           -- Remove duplicate points from ring.
      for i = 2, #ringRaw do
        local r1, r2 = ringRaw[i - 1], ringRaw[i]
        local p1, p2 = rData[1][r1.idx1][r1.idx2], rData[1][r2.idx1][r2.idx2]
        if p1:squaredDistance(p2) > 0.01 then
          ring[ctr] = ringRaw[i]
          ctr = ctr + 1
        end
      end

      -- Compute the vertices.
      local verts, ctr, ringLen = {}, 1, #ring
      for i = 1, numDivs do
        local div = rData[i]
        for k = 1, ringLen do
          local dRing = ring[k]
          local p = div[dRing.idx1][dRing.idx2]
          verts[ctr] = { x = p.x, y = p.y, z = p.z }
          ctr = ctr + 1
        end
        local dRing = ring[1]                                                                       -- Repeat the first ring point at the end of the ring.
        local p = div[dRing.idx1][dRing.idx2]
        verts[ctr] = { x = p.x, y = p.y, z = p.z }
        ctr = ctr + 1
      end

      -- If dowels are required, then adjust the start/end points appropriately.
      local ringLenPlus1 = ringLen + 1
      if r.isDowelS then
        for i = 1, ringLenPlus1 do
          local vv1, vv2 = verts[i], verts[i + ringLenPlus1]
          if not vv2 then
            vv2 = vv1
          end
          tmp1:set(vv1.x, vv1.y, vv1.z)
          tmp2:set(vv2.x, vv2.y, vv2.z)
          local v = tmp1 - tmp2
          v:normalize()
          tmp3 = tmp1 + v * dowelLength
          verts[i] = { x = tmp3.x, y = tmp3.y, z = tmp3.z }
        end
      end
      if r.isDowelE then
        for i = #verts, #verts - ringLenPlus1, -1 do
          local vv1, vv2 = verts[i], verts[i - ringLenPlus1]
          if not vv2 then
            vv2 = vv1
          end
          tmp1:set(vv1.x, vv1.y, vv1.z)
          tmp2:set(vv2.x, vv2.y, vv2.z)
          local v = tmp1 - tmp2
          v:normalize()
          tmp3 = tmp1 + v * dowelLength
          verts[i] = { x = tmp3.x, y = tmp3.y, z = tmp3.z }
        end
      end

      -- Compute the faces and normals.
      local surfaceMesh = {}
      if ty == 'curb_L' then
        local curbuvs = {}
        local faces, normals, fCtr, nCtr = {}, {}, 1, 1
        for i = 2, numDivs do
          local rowB = (i - 2) * ringLenPlus1
          local rowF = (i - 1) * ringLenPlus1
          for j = 2, ringLenPlus1 do

            local jMinus1 = j - 1
            local i1, i2, i3, i4 = rowB + jMinus1, rowB + j, rowF + jMinus1, rowF + j
            local vv1, vv2, vv3 = verts[i1], verts[i2], verts[i3]
            tmp1:set(vv1.x, vv1.y, vv1.z)
            tmp2:set(vv2.x, vv2.y, vv2.z)
            tmp3:set(vv3.x, vv3.y, vv3.z)

            local n = -(tmp2 - tmp1):cross(tmp3 - tmp1)
            n:normalize()
            normals[nCtr] = { x = n.x, y = n.y, z = n.z }

            faces[fCtr] = { v = i1 - 1, n = nCtr - 1, u = fCtr - 1 }
            faces[fCtr + 1] = { v = i2 - 1, n = nCtr - 1, u = fCtr }
            faces[fCtr + 2] = { v = i3 - 1, n = nCtr - 1, u = fCtr + 1 }
            faces[fCtr + 3] = { v = i2 - 1, n = nCtr - 1, u = fCtr + 2 }
            faces[fCtr + 4] = { v = i4 - 1, n = nCtr - 1, u = fCtr + 3 }
            faces[fCtr + 5] = { v = i3 - 1, n = nCtr - 1, u = fCtr + 4 }

            local vHere = (j - 2) * 0.1
            curbuvs[fCtr] = { u = 0.5, v = vHere }
            curbuvs[fCtr + 1] = { u = 0.5, v = vHere + 0.1 }
            curbuvs[fCtr + 2] = { u = 1.0, v = vHere }
            curbuvs[fCtr + 3] = { u = 0.5, v = vHere + 0.1 }
            curbuvs[fCtr + 4] = { u = 1.0, v = vHere + 0.1 }
            curbuvs[fCtr + 5] = { u = 1.0, v = vHere }

            fCtr = fCtr + 6
            nCtr = nCtr + 1
          end
        end
        surfaceMesh = { verts = verts, faces = faces, normals = normals, uvs = curbuvs, material = curbMaterial }
      elseif ty == 'curb_R' then
        local curbuvs = {}
        local faces, normals, fCtr, nCtr = {}, {}, 1, 1
        for i = 2, numDivs do
          local rowB = (i - 2) * ringLenPlus1
          local rowF = (i - 1) * ringLenPlus1
          for j = 2, ringLenPlus1 do

            local jMinus1 = j - 1
            local i1, i2, i3, i4 = rowB + jMinus1, rowB + j, rowF + jMinus1, rowF + j
            local vv1, vv2, vv3 = verts[i1], verts[i2], verts[i3]
            tmp1:set(vv1.x, vv1.y, vv1.z)
            tmp2:set(vv2.x, vv2.y, vv2.z)
            tmp3:set(vv3.x, vv3.y, vv3.z)

            local n = -(tmp2 - tmp1):cross(tmp3 - tmp1)
            n:normalize()
            normals[nCtr] = { x = n.x, y = n.y, z = n.z }

            faces[fCtr] = { v = i1 - 1, n = nCtr - 1, u = fCtr - 1 }
            faces[fCtr + 1] = { v = i2 - 1, n = nCtr - 1, u = fCtr }
            faces[fCtr + 2] = { v = i3 - 1, n = nCtr - 1, u = fCtr + 1 }
            faces[fCtr + 3] = { v = i2 - 1, n = nCtr - 1, u = fCtr + 2 }
            faces[fCtr + 4] = { v = i4 - 1, n = nCtr - 1, u = fCtr + 3 }
            faces[fCtr + 5] = { v = i3 - 1, n = nCtr - 1, u = fCtr + 4 }

            local vHereLeft = (j - 2) * 0.1
            local vHere = 3 - vHereLeft
            if vHere < 1 then
              vHere = vHere + 3
            end
            curbuvs[fCtr] = { u = 0.5, v = vHere }
            curbuvs[fCtr + 1] = { u = 0.5, v = vHere + 0.1 }
            curbuvs[fCtr + 2] = { u = 1.0, v = vHere }
            curbuvs[fCtr + 3] = { u = 0.5, v = vHere + 0.1 }
            curbuvs[fCtr + 4] = { u = 1.0, v = vHere + 0.1 }
            curbuvs[fCtr + 5] = { u = 1.0, v = vHere }

            fCtr = fCtr + 6
            nCtr = nCtr + 1
          end
        end
        surfaceMesh = { verts = verts, faces = faces, normals = normals, uvs = curbuvs, material = curbMaterial }
      else
        local faces, normals, fCtr, nCtr = {}, {}, 1, 1
        for i = 2, numDivs do
          local rowB = (i - 2) * ringLenPlus1
          local rowF = (i - 1) * ringLenPlus1
          for j = 2, ringLenPlus1 do
            local jMinus1 = j - 1
            local i1, i2, i3, i4 = rowB + jMinus1, rowB + j, rowF + jMinus1, rowF + j
            local vv1, vv2, vv3 = verts[i1], verts[i2], verts[i3]
            tmp1:set(vv1.x, vv1.y, vv1.z)
            tmp2:set(vv2.x, vv2.y, vv2.z)
            tmp3:set(vv3.x, vv3.y, vv3.z)
            local n = -(tmp2 - tmp1):cross(tmp3 - tmp1)
            n:normalize()
            normals[nCtr] = { x = n.x, y = n.y, z = n.z }
            faces[fCtr] = { v = i1 - 1, n = nCtr - 1, u = 0 }
            faces[fCtr + 1] = { v = i2 - 1, n = nCtr - 1, u = 2 }
            faces[fCtr + 2] = { v = i3 - 1, n = nCtr - 1, u = 1 }
            faces[fCtr + 3] = { v = i2 - 1, n = nCtr - 1, u = 2 }
            faces[fCtr + 4] = { v = i4 - 1, n = nCtr - 1, u = 3 }
            faces[fCtr + 5] = { v = i3 - 1, n = nCtr - 1, u = 1 }
            fCtr = fCtr + 6
            nCtr = nCtr + 1
          end
        end
        surfaceMesh = { verts = verts, faces = faces, normals = normals, uvs = uvs, material = material }
      end

      -- Add end caps.
      local vertsLane, facesLane, normalsLane, vCtr, fCtr, nCtr = {}, {}, {}, 1, 1, 1
      for k = lMin, lMax do
        if k ~= 0 then
          local b, f = rData[1][k], rData[numDivs][k]

          -- Append the vertices.
          local b1, b2, b3, b4, f1, f2, f3, f4 = b[1], b[2], b[3], b[4], f[1], f[2], f[3], f[4]
          local i1, i2, i3, i4, i5, i6, i7, i8 = vCtr, vCtr + 1, vCtr + 2, vCtr + 3, vCtr + 4, vCtr + 5, vCtr + 6, vCtr + 7
          vertsLane[i1] = { x = b1.x, y = b1.y, z = b1.z }
          vertsLane[i2] = { x = b2.x, y = b2.y, z = b2.z }
          vertsLane[i3] = { x = b3.x, y = b3.y, z = b3.z }
          vertsLane[i4] = { x = b4.x, y = b4.y, z = b4.z }
          vertsLane[i5] = { x = f1.x, y = f1.y, z = f1.z }
          vertsLane[i6] = { x = f2.x, y = f2.y, z = f2.z }
          vertsLane[i7] = { x = f3.x, y = f3.y, z = f3.z }
          vertsLane[i8] = { x = f4.x, y = f4.y, z = f4.z }

          -- Append the normals.
          local n, l = b[5], b[6]
          local t = n:cross(l)
          local n1, n2 = nCtr, nCtr + 1
          normalsLane[n1] = { x = t.x, y = t.y, z = t.z }
          normalsLane[n2] = { x = -t.x, y = -t.y, z = -t.z }

          -- Reduce the vertex and normal indices by one, since face indexing starts at zero.
          i1, i2, i3, i4, i5, i6, i7, i8 = i1 - 1, i2 - 1, i3 - 1, i4 - 1, i5 - 1, i6 - 1, i7 - 1, i8 - 1
          n1, n2 = n1 - 1, n2 - 1

          -- Append the front cap faces [f1 - f3 - f2, f3 - f1 - f4].
          facesLane[fCtr] = { v = i1, n = n1, u = 0 }
          facesLane[fCtr + 1] = { v = i3 , n = n1, u = 3 }
          facesLane[fCtr + 2] = { v = i2, n = n1, u = 1 }
          facesLane[fCtr + 3] = { v = i3, n = n1, u = 3 }
          facesLane[fCtr + 4] = { v = i1, n = n1, u = 0 }
          facesLane[fCtr + 5] = { v = i4, n = n1, u = 2 }

          -- Append the back cap faces [b1 - b3 - b2, b3 - b1 - b4].
          facesLane[fCtr + 6] = { v = i5, n = n2, u = 0 }
          facesLane[fCtr + 7] = { v = i6 , n = n2, u = 1 }
          facesLane[fCtr + 8] = { v = i7, n = n2, u = 3 }
          facesLane[fCtr + 9] = { v = i7, n = n2, u = 3 }
          facesLane[fCtr + 10] = { v = i8, n = n2, u = 2 }
          facesLane[fCtr + 11] = { v = i5, n = n2, u = 0 }

          vCtr = vCtr + 8
          fCtr = fCtr + 12
          nCtr = nCtr + 2
        end
      end
      local endCaps = { verts = vertsLane, faces = facesLane, normals = normalsLane, uvs = uvs, material = material }

      -- Generate the procedural meshes for the road.
      local mesh = createObject('ProceduralMesh')
      mesh:registerObject('Road_' .. tostring(roadMeshIdx) .. '_section_' .. tostring(s))
      mesh.canSave = true
      scenetree.MissionGroup:add(mesh.obj)
      mesh:createMesh({ { surfaceMesh, endCaps } })
      mesh:setPosition(origin)
      mesh.scale = scaleVec

      meshes[r.name][#meshes[r.name] + 1] = mesh

    end
  end
end

-- Attempts to removes the meshes of the road with the given name, from the scene (if it exists).
local function tryRemove(roadName)
  local mesh = meshes[roadName]
  if mesh then
    for s = 1, #mesh do
      mesh[s]:delete()
    end
  end
  meshes[roadName] = nil
end


-- Public interface.
M.createRoad =                                            createRoad
M.tryRemove =                                             tryRemove

return M