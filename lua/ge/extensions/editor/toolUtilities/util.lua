-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This is a utility class containing common functions used across various spline-editing tools.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local defaultMinWidth, defaultMaxWidth = 10.0, 10.0 -- The default min and max widths for a spline.

local fixedWidthTolerance = 0.01 -- The tolerance for the width of a node to be considered fixed.

local maxRayDist = 5000 -- The maximum distance for the camera -> mouse ray, in meters.
local vertRayRaise = 10.0 -- The amount to raise the point for the vertical raycast, in meters.
local veryRayPostFloat = 0.05 -- A small z-increase, applied after the vertical raycast to keep the point above the surface.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}
local logTag = 'toolUtilities'

-- Module dependencies.
local ffi = require("ffi")
local mime = require('mime')

-- Module constants.
local im = ui_imgui
local abs, min, max, floor = math.abs, math.min, math.max, math.floor
local sqrt, tan, huge = math.sqrt, math.tan, math.huge
local globalDown = vec3(0, 0, -1)
local camLookDownRot = quatFromDir(globalDown)

-- Module state.
local tmp1, tmp2 = vec3(), vec3()


-- Tests if mouse is hovering over the terrain (as opposed to any windows, etc).
local function isMouseHoveringOverTerrain()
  return not im.IsAnyItemHovered() and not im.IsWindowHovered(im.HoveredFlags_AnyWindow) and not editor.isAxisGizmoHovered()
end

-- Computes the position on the map at which the mouse points.
local function mouseOnMapPos()
  local ray = getCameraMouseRay()
  local rayPos, rayDir = ray.pos, ray.dir
  return rayPos + rayDir * castRayStatic(rayPos, rayDir, maxRayDist)
end

-- Downward vertical raycast which modifies the point's Z value in-place.
-- Keeps the point slightly above the terrain surface to prevent sinking.
local function vertRaycast(pos, rayRaise)
  rayRaise = rayRaise or vertRayRaise
  pos.z = pos.z + rayRaise
  local dDown = castRayStatic(pos, globalDown, maxRayDist)
  pos.z = pos.z - min(dDown, maxRayDist) + veryRayPostFloat
end

-- Fast copy function for simple arrays.
local function fastArrayCopy(arr)
  local copy = {}
  for i = 1, #arr do
    copy[i] = arr[i]
  end
  return copy
end

-- Conversion functions for velocities in meters per second.
local function msToMph(ms) return ms * 2.236936 end
local function msToKph(ms) return ms * 3.6 end

-- Returns the sum of all values in the given non-array table.
local function sumOverNonArrayTable(t)
  local sum = 0.0
  for _, v in pairs(t) do
    sum = sum + v
  end
  return sum
end

-- Returns mesh bounding box info for a TSStatic shape path.
local function getMeshBox(meshPath)
  local obj = createObject('TSStatic')
  obj.cansave = false
  obj:setField('shapeName', 0, meshPath)
  obj:registerObject('temp_getMeshBox')
  local objBox = obj:getObjBox()
  local extents = objBox:getExtents()
  local center = objBox:getCenter()
  obj:delete()
  local halfExtents = extents * 0.5
  return {
    minExtents = center - halfExtents,
    maxExtents = center + halfExtents,
    center = center,
    extents = extents,
  }
end

-- Computes a blue to red color by interpolating between blue [minValue] and red [maxValue].
local function getBlueToRedColour(value, minValue, maxValue)
  local t = max(0, min(1, (value - minValue) / (maxValue - minValue))) -- Clamp and normalise.
  return color(floor(t * 255 + 0.5), 0, floor((1.0 - t) * 255 + 0.5), 255)
end

-- Converts HSV to RGB (all in range [0,255]).
local function hsvToRgb255(h, s, v)
  local c = v * s
  local x = c * (1 - abs((h * 0.016666666666666667) % 2 - 1))
  local m = v - c
  local r, g, b = 0, 0, 0

  if h < 60 then r, g, b = c, x, 0
  elseif h < 120 then r, g, b = x, c, 0
  elseif h < 180 then r, g, b = 0, c, x
  elseif h < 240 then r, g, b = 0, x, c
  elseif h < 300 then r, g, b = x, 0, c
  else r, g, b = c, 0, x
  end

  return floor((r + m) * 255 + 0.5), floor((g + m) * 255 + 0.5), floor((b + m) * 255 + 0.5)
end

-- Generates a hue-based colour, based on the given value.
local function getHueBasedColour255(t) return hsvToRgb255(lerp(240, 0, clamp(t, 0, 1)), 1.0, 1.0) end

-- Generates a unique name, so it will not clash with any existing names in the scene tree.
local function generateUniqueName(baseName, prefixIn)
  local prefix = prefixIn .. " - "
  local name = baseName
  local fullName = prefix .. name
  local i = 1
  while scenetree.findObject(fullName) do
    name = baseName .. " - " .. i
    fullName = prefix .. name
    i = i + 1
  end
  return name
end

-- Computes a map of spline IDs to their indices.
local function computeIdToIdxMap(splines, map)
  table.clear(map)
  for i = 1, #splines do
    map[splines[i].id] = i
  end
end

-- Returns the number of materials in the terrain block.
local function getNumMaterials()
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local mtls = tb:getMaterials()
  return #mtls
end

-- Returns the length of the given polyline.
local function getPolyLength(pts)
  local length = 0.0
  for i = 1, #pts - 1 do
    length = length + pts[i]:distance(pts[i + 1])
  end
  return length
end

-- Returns the minimum and maximum widths of the given spline.
local function getMinMaxWidth(spline)
  local widths = spline.widths
  if not widths or #widths < 1 then
    return defaultMinWidth, defaultMaxWidth -- If no nodes in group spline, return the default min and max widths.
  end
  local wMin, wMax = huge, -huge
  for i = 1, #widths do
    local w = widths[i]
    wMin, wMax = min(wMin, w), max(wMax, w)
  end
  return wMin, wMax
end

-- Returns true if the width of the nodes is fixed, to some tolerance.
local function isWidthFixed(nodes)
  local wMin, wMax = huge, -huge
  for _, node in ipairs(nodes) do
    local width = node.width or 0
    wMin, wMax = min(wMin, width), max(wMax, width)
  end
  return abs(wMax - wMin) < fixedWidthTolerance, wMin
end

-- Removes consecutive points that are closer than minDist in XY-plane.
local function filterClosePointsXY(points, minDist)
  if #points < 2 then
    return points -- No points to filter.
  end

  -- Create a new table to store the filtered points.
  local numPoints = #points
  local filtered, ctr = table.new(numPoints, 0), 2
  filtered[1] = points[1]

  -- Iterate through the points, and filter out consecutive points that are closer than minDist in XY-plane.
  local minDistSq = minDist * minDist
  for i = 2, numPoints do
    local prev, curr = filtered[#filtered], points[i]
    local dx, dy = curr.x - prev.x, curr.y - prev.y
    if (dx * dx + dy * dy) >= minDistSq then
      filtered[ctr] = curr
      ctr = ctr + 1
    end
  end

  return filtered
end

-- Estimates average XY-plane spacing between nodes, simulating Catmull-Rom interpolation but excluding mesh extents.
local function calculateAverageSpacingXY(positions, minSpacing)
  if #positions < 2 then
    return minSpacing or 1.0
  end

  -- Simulate Catmull-Rom interpolation to estimate the path length.
  local totalLength = 0
  for i = 1, #positions - 1 do
    local p0 = positions[max(1, i - 1)]
    local p1 = positions[i]
    local p2 = positions[i + 1]
    local p3 = positions[min(#positions, i + 2)]

    -- Sample intermediate points for more accurate length.
    local lastPt = p1
    for t = 0.1, 1.0, 0.1 do
      local pt = catmullRomCentripetal(p0, p1, p2, p3, t, 0.5)
      local dx, dy = pt.x - lastPt.x, pt.y - lastPt.y  -- XY-plane only.
      totalLength = totalLength + sqrt(dx * dx + dy * dy)
      lastPt = pt
    end
  end

  -- Estimate average spacing between nodes based on total path length.
  local avgSpacing = totalLength / (#positions - 1)
  if minSpacing then
    avgSpacing = max(avgSpacing, minSpacing)
  end
  return avgSpacing
end

-- Returns true/idx if the path contains the given node key, otherwise false/nil.
local function doesPathContainNode(path, nodeKey)
  for i = 1, #path do
    if path[i] == nodeKey then
      return true, i
    end
  end
  return false, nil
end

-- Flips the direction of the given spline.
local function flipSplineDirection(spline)
  local nodes, widths, nmls = spline.nodes, spline.widths, spline.nmls
  local newNodes, newWidths, newNmls = {}, {}, {}
  for i = #nodes, 1, -1 do
    table.insert(newNodes, nodes[i])
    table.insert(newWidths, widths[i])
    table.insert(newNmls, nmls[i])
  end
  spline.nodes, spline.widths, spline.nmls = newNodes, newWidths, newNmls
  spline.isDirty = true
end

-- Moves the camera directly above the spline with the given index.
local function goToSpline(points)
  -- Compute the 2D AABB of the spline, and the max height.
  local xMin, xMax, yMin, yMax, zMax = huge, -huge, huge, -huge, -huge
  for i = 1, #points do
    local p = points[i]
    local px, py = p.x, p.y
    xMin, xMax = min(xMin, px), max(xMax, px)
    yMin, yMax = min(yMin, py), max(yMax, py)
    zMax = max(zMax, p.z)
  end

  -- If the spline is too small (eg one node), do nothing and leave immediately.
  if max(abs(xMax - xMin), abs(yMax - yMin)) < 0.1 then
    return
  end

  -- Compute the mid-point of the 2D AABB.
  local midX, midY = (xMin + xMax) * 0.5, (yMin + yMax) * 0.5
  tmp1:set(midX, midY, 0.0)
  tmp2:set(xMax, yMax, 0.0)

  -- Determine the required distance at which the camera should be positioned.
  local groundDist = tmp1:distance(tmp2) -- The largest distance from the center of the AABB to the outside.
  local halfFov = core_camera.getFovRad() * 0.5 -- Half the camera field-of-view (in radians).
  local height = groundDist / tan(halfFov) + zMax + 5.0 -- The height at which the camera should be positioned, to fit the spline in view.

  -- Move the camera to the appropriate pose.
  commands.setFreeCamera()
  core_camera.setPosRot(0, midX, midY, height, camLookDownRot.x, camLookDownRot.y, camLookDownRot.z, camLookDownRot.w)
end

-- Converts a ribbon polyline to a triangle mesh.
-- Returns: { vertices = {vec3, ...}, indices = {int, ...} }
local function buildRibbonMeshFromPolyline(points, widths, binormals)
  local vertices, indices = {}, {}
  for i = 1, #points do
    local node = points[i]
    local halfWidth = widths[i] * 0.5
    local binormal = binormals[i]
    local left = node - binormal * halfWidth
    local right = node + binormal * halfWidth
    table.insert(vertices, left)
    table.insert(vertices, right)

    if i > 1 then
      local base = (i - 2) * 2 + 1
      table.insert(indices, base)     -- L0
      table.insert(indices, base + 1) -- R0
      table.insert(indices, base + 2) -- L1
      table.insert(indices, base + 2) -- L1
      table.insert(indices, base + 1) -- R0
      table.insert(indices, base + 3) -- R1
    end
  end
  return { vertices = vertices, indices = indices }
end

-- Converts BeamNG coords to GLTF (x, z, -y).
local function convertToGLTFCoords(x, y, z) return x, z, -y end

-- Append 3 floats to bin and return new byte length.
local function packf(x, y, z, bin, byteLen)
  local f3 = ffi.new("float[3]", {x, y, z})
  table.insert(bin, ffi.string(f3, 12))
  return byteLen + 12
end

-- Append a uint16 and return new byte length.
local function packu16(i, bin, byteLen)
  local u16 = ffi.new("uint16_t[1]", i)
  table.insert(bin, ffi.string(u16, 2))
  return byteLen + 2
end

-- Converts a ribbon polyline to GLTF JSON with embedded buffer.
local function buildRibbonGLTF(points, widths, binormals)
  local mesh = buildRibbonMeshFromPolyline(points, widths, binormals)
  local vertices, indices = mesh.vertices, mesh.indices

  local bin = {}
  local binByteLength = 0

  local minPos, maxPos = { 1e9, 1e9, 1e9 }, { -1e9, -1e9, -1e9 }

  local posStart = 0
  for _, v in ipairs(vertices) do
    local gx, gy, gz = convertToGLTFCoords(v.x, v.y, v.z)
    binByteLength = packf(gx, gy, gz, bin, binByteLength)
    minPos[1] = min(minPos[1], gx)
    minPos[2] = min(minPos[2], gy)
    minPos[3] = min(minPos[3], gz)
    maxPos[1] = max(maxPos[1], gx)
    maxPos[2] = max(maxPos[2], gy)
    maxPos[3] = max(maxPos[3], gz)
  end
  local posLength = binByteLength

  local idxStart = binByteLength
  for _, i in ipairs(indices) do
    binByteLength = packu16(i - 1, bin, binByteLength)
  end
  local idxLength = binByteLength - idxStart

  local binBlob = table.concat(bin)
  local base64Data = mime.b64(binBlob)
  if not base64Data then
    log('E', logTag, 'Base64 encoding failed — binBlob may be invalid or too large')
  end

  local gltf = {
    asset = { version = "2.0" },
    buffers = {
      {
        byteLength = #binBlob,
        uri = "data:application/octet-stream;base64," .. base64Data
      }
    },
    bufferViews = {
      {
        buffer = 0,
        byteOffset = posStart,
        byteLength = posLength,
        target = 34962
      },
      {
        buffer = 0,
        byteOffset = idxStart,
        byteLength = idxLength,
        target = 34963
      }
    },
    accessors = {
      {
        bufferView = 0,
        byteOffset = 0,
        componentType = 5126,
        count = #vertices,
        type = "VEC3",
        min = minPos,
        max = maxPos
      },
      {
        bufferView = 1,
        byteOffset = 0,
        componentType = 5123,
        count = #indices,
        type = "SCALAR"
      }
    },
    meshes = {
      {
        primitives = {
          {
            attributes = { POSITION = 0 },
            indices = 1,
            mode = 4
          }
        }
      }
    },
    nodes = {
      {
        mesh = 0,
        translation = { 0, 0, 0 },
        rotation = { 0, 0, 0, 1 },
        scale = { 1, 1, 1 }
      }
    },
    scenes = {
      { nodes = { 0 } }
    },
    scene = 0
  }

  return gltf
end

-- Returns the sources from the given spline.
local function getSourcesSingle(spline)
  local divPoints, divWidths, binormals = spline.divPoints, spline.divWidths, spline.binormals
  local sData = table.new(#divPoints, 0)
  local numDivPoints, ctr = #divPoints, 1
  for i = 1, numDivPoints do
    sData[ctr] = { pos = divPoints[i], width = divWidths[i], binormal = binormals[i] }
    ctr = ctr + 1
  end
  return { sData }
end

-- Returns the sources from all given splines.
local function getAllSources(splines)
  local numSplines = #splines
  local allSources = table.new(numSplines, 0)
  local ctr = 1
  for i = 1, numSplines do
    local spline = splines[i]
    if spline.isEnabled then
      local divPoints, divWidths, binormals = spline.divPoints, spline.divWidths, spline.binormals
      local sData = table.new(#divPoints, 0)
      for j = 1, #divPoints do
        sData[j] = { pos = divPoints[j], width = divWidths[j], binormal = binormals[j] }
      end
      allSources[ctr] = sData
      ctr = ctr + 1
    end
  end
  return allSources
end

-- Converts HSV to RGB (all in range [0,1]).
local function hsvToRgb(h, s, v)
  local r, g, b
  local i = floor(h * 6)
  local f = h * 6 - i
  local p = v * (1 - s)
  local q = v * (1 - f * s)
  local t = v * (1 - (1 - f) * s)
  i = i % 6

  if i == 0 then r, g, b = v, t, p
  elseif i == 1 then r, g, b = q, v, p
  elseif i == 2 then r, g, b = p, v, t
  elseif i == 3 then r, g, b = p, q, v
  elseif i == 4 then r, g, b = t, p, v
  elseif i == 5 then r, g, b = v, p, q end

  return r, g, b
end

-- Flip the bitmap vertically, in-place.
local function flipBitmapY(bmpIn)
  local width, height = bmpIn:getWidth(), bmpIn:getHeight()
  local bmp = GBitmap()
  bmp:allocateBitmap(width, height, false, "GFXFormatR16")
  local heightMinus1 = height - 1
  for x = 0, width - 1 do
    for y = 0, heightMinus1 do
      local val = bmpIn:getTexel(x, heightMinus1 - y)
      bmp:setTexel(x, y, val, val, val, val)
    end
  end
  return bmp
end

-- Writes a binary mask to a .png file in RGBA format. Debug utility.
local function writeMaskToPng(mask, path)
  local height = #mask
  if height == 0 then return end
  local width = #mask[1]

  local bmp = GBitmap()
  bmp:allocateBitmap(width, height, false, "GFXFormatR16") -- 16-bit greyscale.

  for y = 1, height do
    for x = 1, width do
      local v = mask[y][x] == 1 and 65535 or 0
      bmp:setTexel(x - 1, y - 1, v, v, v, 65535) -- only white if mask is 1
    end
  end

  if bmp:saveFile(path) then
    log('I', logTag, 'Wrote RGBA mask PNG to: ' .. tostring(path))
  else
    log('E', logTag, 'Failed to write mask PNG to: ' .. tostring(path))
  end
end

-- Writes a set of vectorized paths to a .png file in 16-bit greyscale format.
-- Each path gets a distinct greyscale intensity for visual differentiation.
local function writePathsToPng(paths, width, height, path)
  local bmp = GBitmap()
  bmp:allocateBitmap(width, height, false, "GFXFormatR16") -- 16-bit grayscale

  -- Clear to black
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      bmp:setTexel(x, y, 0, 0, 0, 65535)
    end
  end

  -- Use repeating high-contrast intensities for each path
  local levels = { 10000, 20000, 30000, 40000, 50000, 60000 }
  local nLevels = #levels

  for i, path in ipairs(paths) do
    local intensity = levels[(i - 1) % nLevels + 1] -- Cycle if too many

    for j = 1, #path do
      local pt = path[j]
      local x, y = floor(pt.x + 0.5), floor(pt.y + 0.5)
      if x >= 0 and x < width and y >= 0 and y < height then
        bmp:setTexel(x, y, intensity, intensity, intensity, 65535)
      end
    end
  end

  if bmp:saveFile(path) then
    log('I', logTag, 'writePathsToPng(): wrote to ' .. tostring(path))
  else
    log('E', logTag, 'writePathsToPng(): failed to save image to ' .. tostring(path))
  end
end

-- Updated: writeWidthsToPng using continuous thick strokes.
local function writeWidthsToPng(paths, widths, width, height, outPath)
  local bmp = GBitmap()
  bmp:allocateBitmap(width, height, false, "GFXFormatR16")

  -- Clear to black
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      bmp:setTexel(x, y, 0, 0, 0, 65535)
    end
  end

  -- Draw each path using filled circles based on computed width
  for i, path in ipairs(paths) do
    local wPath = widths[i]
    for j = 1, #path do
      local p = path[j]
      local w = wPath[j] or 1
      local radius = max(1, floor(w * 0.5))

      -- Draw a filled circle centered at (p.x, p.y)
      local cx = floor(p.x + 0.5)
      local cy = floor(p.y + 0.5)
      for y = cy - radius, cy + radius do
        for x = cx - radius, cx + radius do
          if x >= 0 and x < width and y >= 0 and y < height then
            local dx, dy = x - cx, y - cy
            if dx * dx + dy * dy <= radius * radius then
              bmp:setTexel(x, y, 65535, 65535, 65535, 65535)
            end
          end
        end
      end
    end
  end

  -- Save
  if bmp:saveFile(outPath) then
    log('I', logTag, 'writeWidthsToPng(): wrote to ' .. tostring(outPath))
  else
    log('E', logTag, 'writeWidthsToPng(): failed to save image to ' .. tostring(outPath))
  end
end


-- Public interface.
M.isMouseHoveringOverTerrain =                          isMouseHoveringOverTerrain
M.mouseOnMapPos =                                       mouseOnMapPos

M.vertRaycast =                                         vertRaycast

M.fastArrayCopy =                                       fastArrayCopy

M.msToMph =                                             msToMph
M.msToKph =                                             msToKph

M.sumOverNonArrayTable =                                sumOverNonArrayTable

M.getMeshBox =                                          getMeshBox

M.getBlueToRedColour =                                  getBlueToRedColour
M.getHueBasedColour255 =                                getHueBasedColour255
M.hsvToRgb255 =                                         hsvToRgb255

M.generateUniqueName =                                  generateUniqueName
M.computeIdToIdxMap =                                   computeIdToIdxMap
M.getNumMaterials =                                     getNumMaterials
M.getPolyLength =                                       getPolyLength
M.getMinMaxWidth =                                      getMinMaxWidth
M.isWidthFixed =                                        isWidthFixed
M.filterClosePointsXY =                                 filterClosePointsXY
M.calculateAverageSpacingXY =                           calculateAverageSpacingXY
M.doesPathContainNode =                                 doesPathContainNode

M.flipSplineDirection =                                 flipSplineDirection
M.goToSpline =                                          goToSpline

M.buildRibbonMeshFromPolyline =                         buildRibbonMeshFromPolyline
M.buildRibbonGLTF =                                     buildRibbonGLTF

M.getSourcesSingle =                                    getSourcesSingle
M.getAllSources =                                       getAllSources

M.hsvToRgb =                                            hsvToRgb
M.flipBitmapY =                                         flipBitmapY
M.writeMaskToPng =                                      writeMaskToPng
M.writePathsToPng =                                     writePathsToPng
M.writeWidthsToPng =                                    writeWidthsToPng

return M