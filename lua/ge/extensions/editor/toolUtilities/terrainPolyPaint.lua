-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Terrain material painting over a polygon ring, with a revert record for undo/teardown.
-- A record is { xs, ys, prev, cnt }: world x/y of each painted cell and its ORIGINAL material index, so revert
-- restores exactly what was there. Painting batches a single grid update over the touched bounds.
-- Every record is a live overlay until reverted or released (handed to the level): records stack in the order they were
-- painted, over the network paint, and liftAll / layAll take them all off and put them back (a terrain save, a network
-- repaint under them).

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')

-- Module constants.
local min, max, huge = math.min, math.max, math.huge
local holeIdx = 255 -- a terrain hole: never painted over, nor put back over

-- Module state.
local live = {} -- live records, oldest first
local liftDepth = 0
local tmpV, tmpWS = vec3(), vec3()
local p2i, gA, gB = Point2I(0, 0), Point2I(0, 0), Point2I(0, 0)
local sXMin, sXMax, sY = {}, {}, {}


-- Rebuilds the terrain over a world box (updateGrid takes grid coords, as in terrainPainter).
local function refreshBox(tb, x0, y0, x1, y1)
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  if not te or x0 > x1 then return end
  tmpV:set(x0, y0, 0) te:worldToGridByPoint2I(tmpV, gA, tb)
  tmpV:set(x1, y1, 0) te:worldToGridByPoint2I(tmpV, gB, tb)
  tmpV:set(min(gA.x, gB.x) - 1, min(gA.y, gB.y) - 1, 0)
  local hi = vec3(max(gA.x, gB.x) + 1, max(gA.y, gB.y) + 1, 0)
  tb:updateGridMaterials(tmpV, hi)
  tb:updateGrid(tmpV, hi)
end

local function track(rec, tb, x0, y0, x1, y1)
  rec.tb, rec.x0, rec.y0, rec.x1, rec.y1 = tb:getID(), x0, y0, x1, y1
  live[#live + 1] = rec
  return rec
end

local function indexOf(rec)
  for i = #live, 1, -1 do
    if live[i] == rec then return i end
  end
end

local function overlaps(a, b)
  return a.x0 <= b.x1 and b.x0 <= a.x1 and a.y0 <= b.y1 and b.y0 <= a.y1
end

-- Takes one record's paint off, keeping what it painted.
local function liftOne(tb, rec)
  rec.mat = rec.mat or {}
  for i = 1, rec.cnt do
    tmpWS:set(rec.xs[i], rec.ys[i], 0)
    local cur = tb:getMaterialIdxWs(tmpWS)
    rec.mat[i] = cur
    if cur ~= holeIdx then tb:setMaterialIdxWs(tmpWS, rec.prev[i]) end
  end
end

-- Puts it back over whatever is there now, which is what each cell goes back to when it comes off.
local function layOne(tb, rec)
  for i = 1, rec.cnt do
    tmpWS:set(rec.xs[i], rec.ys[i], 0)
    local cur = tb:getMaterialIdxWs(tmpWS)
    if cur ~= holeIdx and rec.mat[i] ~= holeIdx then
      rec.prev[i] = cur
      tb:setMaterialIdxWs(tmpWS, rec.mat[i])
    end
  end
end

-- Paint the terrain cells inside `ring` (scanline fill). `mat` is one layer index for the whole ring, or a function asked
-- per cell for a caller that varies it across the fill -- which returns nil for a cell it wants left alone.
local function paintRing(ring, mat)
  local matFn = (type(mat) == 'function') and mat or nil
  if #ring < 3 then return nil end
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  if not tb or not te then return nil end
  local aabb = geom.getAABB(ring)
  tmpV:set(aabb.xMin, aabb.yMin, 0); te:worldToGridByPoint2I(tmpV, p2i, tb); local gY0 = p2i.y
  tmpV:set(aabb.xMax, aabb.yMax, 0); te:worldToGridByPoint2I(tmpV, p2i, tb); local gY1 = p2i.y
  geom.getScanlineSpans(min(gY0, gY1), max(gY0, gY1), te, tb, ring, sXMin, sXMax, sY)
  local xs, ys, prev, cnt = {}, {}, {}, 0
  for i = 1, #sY do
    local x0, x1, y = min(sXMin[i], sXMax[i]), max(sXMin[i], sXMax[i]), sY[i]
    for x = x0, x1 do
      p2i.x, p2i.y = x, y
      tmpWS:set(te:gridToWorldByPoint2I(p2i, tb))
      local m = mat
      if matFn then m = matFn(x, y, tmpWS.x, tmpWS.y) end
      if m then
        cnt = cnt + 1
        xs[cnt], ys[cnt], prev[cnt] = tmpWS.x, tmpWS.y, tb:getMaterialIdxWs(tmpWS)
        tb:setMaterialIdxWs(tmpWS, m)
      end
    end
  end
  if cnt == 0 then return nil end
  refreshBox(tb, aabb.xMin, aabb.yMin, aabb.xMax, aabb.yMax)
  return track({ xs = xs, ys = ys, prev = prev, cnt = cnt }, tb, aabb.xMin, aabb.yMin, aabb.xMax, aabb.yMax)
end

-- Paint an explicit list of cells (world xs/ys) all to `matIdx`.
local function paintCells(xs, ys, matIdx, prev)
  local cnt = #xs
  if cnt == 0 then return nil end
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  if not tb then return nil end
  local capture = prev == nil or #prev == 0
  prev = prev or {}
  local minX, minY, maxX, maxY = huge, huge, -huge, -huge
  for i = 1, cnt do
    local x, y = xs[i], ys[i]
    tmpWS:set(x, y, 0)
    if capture then prev[i] = tb:getMaterialIdxWs(tmpWS) end
    tb:setMaterialIdxWs(tmpWS, matIdx)
    if x < minX then minX = x end; if x > maxX then maxX = x end
    if y < minY then minY = y end; if y > maxY then maxY = y end
  end
  refreshBox(tb, minX, minY, maxX, maxY)
  return track({ xs = xs, ys = ys, prev = prev, cnt = cnt }, tb, minX, minY, maxX, maxY)
end

-- Restore a record's captured cells to their original materials, then batch one grid update over the touched bounds.
-- Records painted over it since come off first and go back on after, so each cell gets back what was really under it.
local function revert(rec)
  if not rec then return end
  local k = indexOf(rec)
  if k then table.remove(live, k) end
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  if not tb then return end
  local above = {}
  local x0, y0, x1, y1 = huge, huge, -huge, -huge
  if k and rec.x0 then
    x0, y0, x1, y1 = rec.x0, rec.y0, rec.x1, rec.y1
    for i = #live, k, -1 do
      local r = live[i]
      if overlaps(r, rec) then
        liftOne(tb, r)
        above[#above + 1] = r
        x0, y0, x1, y1 = min(x0, r.x0), min(y0, r.y0), max(x1, r.x1), max(y1, r.y1)
      end
    end
  end
  for i = 1, rec.cnt do
    local x, y = rec.xs[i], rec.ys[i]
    tmpWS:set(x, y, 0)
    if tb:getMaterialIdxWs(tmpWS) ~= holeIdx then tb:setMaterialIdxWs(tmpWS, rec.prev[i]) end
    if x < x0 then x0 = x end; if x > x1 then x1 = x end
    if y < y0 then y0 = y end; if y > y1 then y1 = y end
  end
  for i = #above, 1, -1 do layOne(tb, above[i]) end
  refreshBox(tb, x0, y0, x1, y1)
end

-- Hands a record's paint to the terrain (burn, bake): it stays painted, and is no longer taken off with the rest.
local function release(rec)
  local k = rec and indexOf(rec)
  if k then table.remove(live, k) end
end

-- Takes every live record's paint off, newest first. Nests: only the outermost call does the work. No grid refresh: layAll
-- always follows in the same frame and refreshes the same box.
local function liftAll()
  liftDepth = liftDepth + 1
  if liftDepth > 1 or #live == 0 then return end
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  if not tb then return end
  local id = tb:getID()
  for i = #live, 1, -1 do
    local r = live[i]
    if r.tb ~= id then
      table.remove(live, i) -- painted on a terrain that is gone
    else
      liftOne(tb, r)
      r.up = true
    end
  end
end

-- And puts it back, oldest first, over whatever is under it now.
local function layAll()
  if liftDepth == 0 then return end
  liftDepth = liftDepth - 1
  if liftDepth > 0 then return end
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  if not tb then return end
  local x0, y0, x1, y1 = huge, huge, -huge, -huge
  for i = 1, #live do
    local r = live[i]
    if r.up then
      r.up = nil
      layOne(tb, r)
      x0, y0, x1, y1 = min(x0, r.x0), min(y0, r.y0), max(x1, r.x1), max(y1, r.y1)
    end
  end
  refreshBox(tb, x0, y0, x1, y1)
end


-- Public interface.
M.paintRing = paintRing
M.paintCells = paintCells
M.revert = revert
M.release = release
M.liftAll = liftAll
M.layAll = layAll

return M
