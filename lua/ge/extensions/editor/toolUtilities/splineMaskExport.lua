-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logtag = 'splineMaskExport'

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')

-- Module state.
local gMin, gMax = Point2I(0, 0), Point2I(0, 0)
local tmpPoint2I = Point2I(0, 0)
local tmp1, tmp2 = vec3(), vec3()


-- Exports the given sources as a .PNG mask file (GFXFormatR16).
-- [Sources are a table of table of quadrilaterals, used to represent ribbon polyline surfaces.]
local function export(filepath, sources, margin)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  if not tb or not te then
    log('E', logtag, 'Terrain Block or Terrain Editor not found.')
    return
  end

  -- Compute the size of the terrain block in grid coordinates.
  local extents = tb:getWorldBox():getExtents()
  local center = tb:getWorldBox():getCenter()
  local centerX, centerY = center.x, center.y
  local xHalf, yHalf = extents.x * 0.5, extents.y * 0.5
  local tXMin, tXMax = centerX - xHalf, centerX + xHalf
  local tYMin, tYMax = centerY - yHalf, centerY + yHalf
  tmp1:set(tXMin, tYMin, 0)
  tmp2:set(tXMax, tYMax, 0)
  te:worldToGridByPoint2I(tmp1, gMin, tb)
  te:worldToGridByPoint2I(tmp2, gMax, tb)
  local xSize, ySize = gMax.x - gMin.x + 1, gMax.y - gMin.y + 1 -- Terrain grid size.

  -- Build a kd-tree of all the quads.
  local quads = geom.getAllQuadrilaterals(sources, margin or 0.0)
  local tree = geom.populateTreeQuads(quads)

  -- Initialise a bitmap which is the size of the terrain block.
  local bmp = GBitmap()
  bmp:init(xSize, ySize)
  bmp:allocateBitmap(xSize, ySize, false, "GFXFormatR16")

  -- Fill the bitmap with the sources data, to create a mask.
  for x = 0, xSize - 1 do
    for y = 0, ySize - 1 do
      tmpPoint2I.x, tmpPoint2I.y = x, y
      local pWS = te:gridToWorldByPoint2I(tmpPoint2I, tb)
      local inside = false
      for tIdx in tree:queryNotNested(pWS.x, pWS.y, pWS.x, pWS.y) do
        if geom.pointInQuadBarycentric(pWS, quads[tIdx]) then
          inside = true
          break
        end
      end
      local val = inside and 65535 or 0
      bmp:setTexel(x, y, val, val, val, 65535)
    end
  end

  -- Save the bitmap as a .PNG file.
  local ok = bmp:saveFile(filepath)
  if ok then
    log('I', logtag, 'Spline mask exported to: '..filepath)
  else
    log('E', logtag, 'Failed to export spline mask to: '..filepath)
  end
end


-- Public interface
M.export =                                              export

return M