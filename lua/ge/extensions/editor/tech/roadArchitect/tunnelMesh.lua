-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Control parameters.
local material = 'm_asphalt_new_01'                                                                 -- The material to use for the mesh.

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module state.
local meshes = {}
local meshIdx = 1

-- Module constants.
local min, max, cos, sin = math.min, math.max, math.cos, math.sin
local twoPi = 2.0 * math.pi
local uvs = {                                                                                       -- Fixed UV-map corner points (used in all road meshes).
  { u = 0.0, v = 0.0 },
  { u = 0.0, v = 1.0 },
  { u = 1.0, v = 0.0 },
  { u = 1.0, v = 1.0 } }
local origin = vec3(0, 0, 0)                                                                        -- A vec3 used for representing the scene origin.
local scaleVec = vec3(1, 1, 1)                                                                      -- A vec3 used for representing uniform scale.
local up = vec3(0, 0, 1)


-- Rotates vector v around unit axis k, by angle theta (in radians).
-- [This function uses the standard Rodrigues formula].
local function rotateVecAroundAxis(v, k, theta)
  local c = cos(theta)
  return v * c + k:cross(v) * sin(theta) + k * k:dot(v) * (1.0 - c)
end

-- Create a procedural tunnel mesh.
local function createTunnel(name, rData, t)

  -- Determine the pipe center and lateral edge indices.
  local rD1, cIdx1, cIdx2, lIdx, rIdx = rData[1], -1, 3, nil, nil
  if not rD1[-1] then
    cIdx1, cIdx2 = 1, 4
  end
  for i = -20, 20 do
    if rD1[i] then
      lIdx = i
      break
    end
  end
  for i = 20, -20, -1 do
    if rD1[i] then
      rIdx = i
      break
    end
  end

  -- Compute the ring at each longitudinal point in the given section.
  local iStart, iEnd, radGran, radOffset = t.s, t.e, t.radGran, t.radOffset
  local thickness, zOffsetFromRoad = t.thickness, t.zOffsetFromRoad
  local protrudeS, protrudeE = t.protrudeS, t.protrudeE
  local theta, zVec, roadLen, rGranP1 = twoPi / radGran, up * zOffsetFromRoad, #rData, radGran + 1
  local ringsI, ringsO, normals = {}, {}, {}
  local numRings = iEnd - iStart + 1
  for i = 1, numRings do
    local idx = iStart - 1 + i
    local rD = rData[idx]
    local rTan = rData[min(roadLen, idx + 1)][cIdx1][cIdx2] - rData[max(1, idx - 1)][cIdx1][cIdx2]
    rTan:normalize()                                                                                -- The road unit tangent vector.
    local rDLeft = rD[lIdx]
    local rNorm = rDLeft[5]                                                                         -- The road unit normal vector.
    local rLeft, rRight = rDLeft[4], rD[rIdx][3]                                                    -- The left-most and right-most lateral road points.
    local rCen = (rLeft + rRight) * 0.5                                                             -- The road lateral center.
    if i == 1 then
      rCen = rCen - rTan * protrudeS                                                                -- Protrude the start point, if required.
    elseif i == numRings then
      rCen = rCen + rTan * protrudeE                                                                -- Protrude the end point, if required.
    end
    local rWidth = rLeft:distance(rRight)                                                           -- The (lateral) road width at this longitudinal point.
    local nOff = rWidth + radOffset                                                                 -- The normal offset, based on the radii.
    local normWithRInner, normWithROuter = rNorm * (nOff - thickness), rNorm * (nOff + thickness)   -- The full normal offset vectors.
    local pCen = rCen + zVec                                                                        -- The pipe center.
    local ringI, ringO = {}, {}
    local zI = min(rLeft.z, rRight.z)
    local zO = zI - thickness
    for j = 1, rGranP1 do                                                                           -- Compute the cross-sectional rings of points aroung this lon. point.
      local angle = (j - 1) * theta
      ringI[j] = pCen + rotateVecAroundAxis(normWithRInner, rTan, angle)
      ringO[j] = pCen + rotateVecAroundAxis(normWithROuter, rTan, angle)
      ringI[j].z = max(ringI[j].z, zI)
      ringO[j].z = max(ringO[j].z, zO)
    end
    ringsI[i], ringsO[i], normals[i] = ringI, ringO, rNorm
  end

  -- Create the vertices and their corresponding normals and uv map values.
  local numRings = #ringsI
  local vertsO, vertsI, normsO, normsI, ctr = {}, {}, {}, {}, 1
  for i = 1, numRings do
    local ringI, ringO, norm = ringsI[i], ringsO[i], normals[i]
    for j = 1, rGranP1 do
      local inner, outer = ringI[j], ringO[j]
      vertsO[ctr] = { x = outer.x, y = outer.y, z = outer.z }
      vertsI[ctr] = { x = inner.x, y = inner.y, z = inner.z }
      normsO[ctr] = { x = norm.x, y = norm.y, z = norm.z }
      normsI[ctr] = { x = -norm.x, y = -norm.y, z = -norm.z }
      ctr = ctr + 1
    end
  end

  -- Create the faces.
  local facesO, facesI, ctr, numRingsMinus1, rGranP1 = {}, {}, 1, numRings - 1, radGran + 1
  for i = 1, numRingsMinus1 do
    local i1 = (i - 1) * rGranP1
    local i2 = i1 + 1
    local i3 = i1 + rGranP1
    local i4 = i2 + rGranP1
    for j = 1, rGranP1 do
      local ctr1, ctr2, ctr3, ctr4, ctr5 = ctr + 1, ctr + 2, ctr + 3, ctr + 4, ctr + 5
      facesO[ctr] = { v = i1, n = i1, u = 0 }                                                       -- General: Outer triangle 1-3-2.
      facesO[ctr1] = { v = i3, n = i3, u = 2 }
      facesO[ctr2] = { v = i2, n = i2, u = 1 }
      facesO[ctr3] = { v = i3, n = i3, u = 2 }                                                      -- General: Outer triangle 3-4-2.
      facesO[ctr4] = { v = i4, n = i4, u = 3 }
      facesO[ctr5] = { v = i2, n = i2, u = 1 }

      facesI[ctr] = { v = i2, n = i2, u = 0 }                                                       -- General: Inner triangle 2-3-1.
      facesI[ctr1] = { v = i3, n = i3, u = 2 }
      facesI[ctr2] = { v = i1, n = i1, u = 1 }
      facesI[ctr3] = { v = i2, n = i2, u = 2 }                                                      -- General: Inner triangle 2-4-3.
      facesI[ctr4] = { v = i4, n = i4, u = 3 }
      facesI[ctr5] = { v = i3, n = i3, u = 1 }

      ctr = ctr + 6
      i1, i2, i3, i4 = i1 + 1, i2 + 1, i3 + 1, i4 + 1
    end
  end

  -- Start cap vertices.
  local capVertsS, ctr = {}, 1
  for i = 1, rGranP1 do
    capVertsS[ctr] = { x = vertsO[i].x, y = vertsO[i].y, z = vertsO[i].z }
    capVertsS[ctr + 1] = { x = vertsI[i].x, y = vertsI[i].y, z = vertsI[i].z }
    ctr = ctr + 2
  end

  -- Start cap faces.
  local normS = normals[1]
  local capSnormal = { { x = normS.x, y = normS.y, z = normS.z } }                                  -- The start normal is the same for all start cap triangles.
  local capFacesS, ctr, vIdx = {}, 1, 1
  for i = 1, radGran do
    local vIdxM1, vIdxP1, vIdxP2 = vIdx - 1, vIdx + 1, vIdx + 2
    capFacesS[ctr] = { v = vIdxP1, n = 0, u = 1 }                                                   -- Start cap: quad triangle A.
    capFacesS[ctr + 1] = { v = vIdx, n = 0, u = 2 }
    capFacesS[ctr + 2] = { v = vIdxM1, n = 0, u = 0 }
    capFacesS[ctr + 3] = { v = vIdxP2, n = 0, u = 1 }                                               -- Start cap: quad triangle B.
    capFacesS[ctr + 4] = { v = vIdx, n = 0, u = 0 }
    capFacesS[ctr + 5] = { v = vIdxP1, n = 0, u = 3 }
    ctr, vIdx = ctr + 6, vIdx + 2
  end

  -- End cap vertices
  local capVertsE, ctr, numVertsO = {}, 1, #vertsO
  for i = 1, rGranP1 do
    local idx = numVertsO - i + 1
    capVertsE[ctr] = { x = vertsO[idx].x, y = vertsO[idx].y, z = vertsO[idx].z }
    capVertsE[ctr + 1] = { x = vertsI[idx].x, y = vertsI[idx].y, z = vertsI[idx].z }
    ctr = ctr + 2
  end

  -- End cap faces.
  local normE = normals[#normals]
  local capEnormal = { { x = normE.x, y = normE.y, z = normE.z } }
  local capFacesE, ctr = {}, 1
  local vIdx = 1
  for i = 1, radGran do
    local vIdxM1, vIdxP1, vIdxP2 = vIdx - 1, vIdx + 1, vIdx + 2
    capFacesE[ctr] = { v = vIdxP1, n = 0, u = 1 }                                                   -- End cap: quad triangle A.
    capFacesE[ctr + 1] = { v = vIdx, n = 0, u = 2 }
    capFacesE[ctr + 2] = { v = vIdxM1, n = 0, u = 0 }
    capFacesE[ctr + 3] = { v = vIdxP2, n = 0, u = 1 }                                               -- End cap: quad triangle B.
    capFacesE[ctr + 4] = { v = vIdx, n = 0, u = 0 }
    capFacesE[ctr + 5] = { v = vIdxP1, n = 0, u = 3 }
    ctr, vIdx = ctr + 6, vIdx + 2
  end

  -- Create the primitives structures.
  local pOuter = { verts = vertsO, faces = facesO, normals = normsO, uvs = uvs, material = material }
  local pInner = { verts = vertsI, faces = facesI, normals = normsI, uvs = uvs, material = material }
  local pSCap = { verts = capVertsS, faces = capFacesS, normals = capSnormal, uvs = uvs, material = material }
  local pECap = { verts = capVertsE, faces = capFacesE, normals = capEnormal, uvs = uvs, material = material }

  local mesh = { pOuter, pInner, pSCap, pECap }

  -- Generate the procedural mesh.
  local proc = createObject('ProceduralMesh')
  proc:registerObject('Proc_Mesh_' .. tonumber(meshIdx))
  meshIdx = meshIdx + 1
  proc.canSave = true
  scenetree.MissionGroup:add(proc.obj)
  proc:createMesh({ mesh })
  proc:setPosition(origin)
  proc.scale = scaleVec

  meshes[name] = proc
end

-- Attempts to removes the given mesh from the scene (if it exists).
local function tryRemove(name)
  if name then
    local mesh = meshes[name]
    if mesh then
      mesh:delete()
    end
    meshes[name] = nil
  end
end


-- Public interface.
M.createTunnel =                                          createTunnel
M.tryRemove =                                             tryRemove

return M