-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This is a utility class for managing the drawing of a user-defined polygon on the map.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local isMouseMoveTolSq = 0.0001 -- The tolerance for determining if the mouse is moving, in squared meters per frame.
local dragArmDist = 0.5 -- How far the cursor must travel from where it went down before a grab counts as a drag, in meters.
local timeUntilTextAppears = 1.0 -- The time it takes for the text to appear when adding a new node, in seconds.
local lineSegGran = 10 -- The number of segments to use for the line segments of the polygon, in meters.
local lineRaiseHeight = 0.1 -- The height by which the polygon edges are raised above the terrain, in meters.
local squareTol = 0.0175 -- How far off square a corner may be and still be marked as square: the cosine of about one degree.
local squareMarkM = 0.7 -- How far along each edge the square-corner mark is set out, in meters.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')
local rSpheres = require('editor/toolUtilities/render/spheres')
local rLines = require('editor/toolUtilities/render/lines')
local rMarkup = require('editor/toolUtilities/render/markup')
local gizmo = require('editor/toolUtilities/gizmo')
local util = require('editor/toolUtilities/util')

-- Module constants.
local im = ui_imgui
local abs, min, max, floor, sqrt = math.abs, math.min, math.max, math.floor, math.sqrt
local delKeyIdx, altKeyIdx = im.GetKeyIndex(im.Key_Delete), im.GetKeyIndex(im.Key_ModAlt)
local lineSegGranInv = 1.0 / lineSegGran

-- Module state.
local polygon = {}
local lastMousePos = vec3()
local selectedNodeIdx = 1
local hasDeletePressedRecently, lastAltDown = false, false
local isGizmoActive = false
local dragNodeIdx = nil
local dragArmed = false  -- whether the cursor has pulled far enough from where it went down to mean a drag, not a click
local dragPress = vec3() -- and where that was
local isDirty = false
local groundOnly = false -- whether this polygon lies on the ground, so the cursor is taken to the ground and not to a roof
local openLine = false -- whether this is an open polyline (a path) rather than a closed outline: no closure edge, two ends
local tmpTable = { { nodes = nil } }
local markupTimer, markupTime = hptimer(), 0.0
local tmp1, tmp2, tmp3, tmp4 = vec3(), vec3(), vec3(), vec3()
local snapScr = vec3()


-- Where the cursor is working.
local function workPos()
  if not groundOnly then return util.mouseOnMapPos() end
  local seed = polygon[dragNodeIdx or selectedNodeIdx] or polygon[1]
  return util.mouseOnTerrainPos(seed and seed.z) or util.mouseOnMapPos()
end

-- A point taken to the working grid, if the caller gave one to work to.
local function snapTo(x, y, snap)
  if not (snap and snap.step and snap.step > 0) then return x, y end
  return snap.ox + floor((x - snap.ox) / snap.step + 0.5) * snap.step,
         snap.oy + floor((y - snap.oy) / snap.step + 0.5) * snap.step
end

-- The point on segment a->b nearest `p`, sat back on the terrain. Inserting a node ON the edge is what makes the insert
-- free: put it where a snapped cursor actually is and the outline kinks the moment you add a node to it.
local function onSeg(a, b, p)
  local dx, dy = b.x - a.x, b.y - a.y
  local l2 = dx * dx + dy * dy
  local t = (l2 > 1e-12) and (((p.x - a.x) * dx + (p.y - a.y) * dy) / l2) or 0
  t = min(1, max(0, t))
  local x, y = a.x + dx * t, a.y + dy * t
  tmp1:set(x, y, 0)
  return vec3(x, y, core_terrain.getTerrainHeight(tmp1))
end

-- Deep copies the polygon.
local function deepCopyPolygon()
  local copy = {}
  for i = 1, #polygon do
    copy[i] = vec3(polygon[i])
  end
  return copy
end

-- Returns the current polygon.
local function getPolygon() return polygon end

-- Sets/replaces the current polygon (deep copy).
-- nodes: array of vec3-like (x,y,z). Passing nil/empty clears the polygon.
local function setPolygon(nodes)
  table.clear(polygon)
  if nodes then
    for i = 1, #nodes do
      polygon[i] = vec3(nodes[i])
    end
  end
  selectedNodeIdx = max(1, min(#polygon, selectedNodeIdx or 1))
  dragNodeIdx = nil
  isGizmoActive = false
  isDirty = true
end

-- Endpoint node index for edge i (node i -> this), wrapping the closure edge back to node 1.
local function edgeEndIdx(i) return (i % #polygon) + 1 end

-- An edge is "handled" (gets a segment label) for the open edges 1..n-1, plus the closure edge once the polygon is a real
-- closed shape (n > 2). An open polyline has no closure edge at all.
local function edgeHandled(i, n) return i < n or (not openLine and n > 2) end

-- Chord midpoint of edge i into `out` (z=0). Used to position each segment's length label.
local function edgeMidpoint(i, out)
  local A, B = polygon[i], polygon[edgeEndIdx(i)]
  out:set((A.x + B.x) * 0.5, (A.y + B.y) * 0.5, 0)
end

-- Checks if the polygon is valid.
local function isPolygonValid() return #polygon > 2 end

-- Clears the polygon.
local function clearPolygon()
  if #polygon > 0 then
    table.clear(polygon)
    isDirty = true
  end
end

-- Returns and clears the dirty flag.
local function consumeDirty()
  local d = isDirty
  isDirty = false
  return d
end

-- Draw edge i to the scene, terrain-lifted: the straight chord, subdivided for clarity.
local function drawEdge(i, lineFn)
  local A, B = polygon[i], polygon[edgeEndIdx(i)]
  tmp1:set(A.x, A.y, A.z); tmp2:set(B.x, B.y, B.z)
  for j = 1, lineSegGran do
    tmp3:set(lerp(tmp1, tmp2, (j - 1) * lineSegGranInv))
    tmp4:set(lerp(tmp1, tmp2, j * lineSegGranInv))
    tmp3.z = core_terrain.getTerrainHeight(tmp3) + lineRaiseHeight
    tmp4.z = core_terrain.getTerrainHeight(tmp4) + lineRaiseHeight
    lineFn(tmp3, tmp4)
  end
end

-- The draughtsman's mark inside every corner that turns a true right angle.
local function drawSquareCorners(lineFn)
  local n = #polygon
  if n < 3 then return end
  -- An open polyline turns no corner at either end: there is only one edge there to measure against.
  local first, last = openLine and 2 or 1, openLine and n - 1 or n
  for i = first, last do
    local B = polygon[i]
    local A, C = polygon[(i - 2) % n + 1], polygon[i % n + 1]
    local ax, ay = A.x - B.x, A.y - B.y
    local cx, cy = C.x - B.x, C.y - B.y
    local la, lc = sqrt(ax * ax + ay * ay), sqrt(cx * cx + cy * cy)
    if la > 1e-6 and lc > 1e-6 then
      ax, ay, cx, cy = ax / la, ay / la, cx / lc, cy / lc
      if abs(ax * cx + ay * cy) < squareTol then
        -- A short edge takes a smaller mark rather than one that runs past the far end of it.
        local r = min(squareMarkM, la * 0.4, lc * 0.4)
        tmp1:set(B.x + ax * r, B.y + ay * r, 0)
        tmp2:set(B.x + (ax + cx) * r, B.y + (ay + cy) * r, 0)
        tmp3:set(B.x + cx * r, B.y + cy * r, 0)
        tmp1.z = core_terrain.getTerrainHeight(tmp1) + lineRaiseHeight
        tmp2.z = core_terrain.getTerrainHeight(tmp2) + lineRaiseHeight
        tmp3.z = core_terrain.getTerrainHeight(tmp3) + lineRaiseHeight
        lineFn(tmp1, tmp2)
        lineFn(tmp2, tmp3)
      end
    end
  end
end

-- Renders the polygon. segmentLabels: draw a length label at each segment's midpoint (incl. the closure edge) instead of
-- the start/end markups - the caller's polygon is a closed footprint where start/end mean nothing.
local function renderPolygon(foreground, segmentLabels)
  local sphereFn = foreground and rSpheres.drawSphereNodeForeground or rSpheres.drawSphereNode
  local lineFn = foreground and rLines.drawSplineLineForeground or rLines.drawSplineLine
  local highlightFn = foreground and rSpheres.drawSphereHighlightForeground or rSpheres.drawSphereHighlight
  local numNodes = #polygon
  -- Render the nodes.
  for i = 1, numNodes do
    sphereFn(polygon[i])
  end

  -- Markups: either a per-segment length label at each midpoint, or the start/end pair.
  if segmentLabels then
    for i = 1, numNodes do
      if edgeHandled(i, numNodes) then
        edgeMidpoint(i, tmp1); tmp1.z = core_terrain.getTerrainHeight(tmp1) + lineRaiseHeight
        rMarkup.markupText(tmp1, string.format('%.1f m', polygon[i]:distance(polygon[edgeEndIdx(i)])))
      end
    end
  elseif numNodes > 1 then
    rMarkup.markupStart(polygon[1])
    rMarkup.markupEnd(polygon[numNodes])
  end

  -- Render the edges.
  for i = 1, numNodes - 1 do
    drawEdge(i, lineFn)
  end
  -- Closure edge (first<->last), shown dull while drawing. An open polyline has none: its two ends are ends.
  if numNodes > 2 and not openLine then
    local p1, p2 = polygon[1], polygon[numNodes]
    tmp1:set(p1.x, p1.y, p1.z + lineRaiseHeight)
    tmp2:set(p2.x, p2.y, p2.z + lineRaiseHeight)
    if foreground then rLines.drawSplineLineForeground(tmp1, tmp2) else rLines.drawSplineLineDull(tmp1, tmp2) end
  end

  drawSquareCorners(foreground and rLines.drawSquareCornerLineForeground or rLines.drawSquareCornerLine)

  -- Render the selected node highlight.
  if selectedNodeIdx and selectedNodeIdx > 0 and selectedNodeIdx <= numNodes then
    highlightFn(polygon[selectedNodeIdx])
  end
end

-- Undo/redo callbacks for polygon edits (dummy).
local function undoPolyEdit(data) end
local function redoPolyEdit(data) end

-- Handles the lifecycle of the user polygon. Calling this function allows the user to draw/edit a polygon on the map with the mouse.
-- opts (optional):
-- - clearOnComplete: boolean (default true)  -> clear polygon after double-click completion
-- - doRender: boolean (default true)         -> render the polygon + cursor
-- - foreground: boolean (default false)      -> draw polygon through scene geometry
-- - snap: { ox, oy, step }                   -> snap the working point to a grid of `step`, origin (ox,oy) (nodes land on it)
-- - segmentLabels: boolean (default false)   -> label each segment's length instead of drawing start/end markups
-- - rigid: boolean (default false)           -> dragging a node translates the WHOLE polygon rigidly (whole shape moves)
local function handleUserPolygon(doubleClickCallback, opts)
  opts = opts or {}
  local clearOnComplete = opts.clearOnComplete
  if clearOnComplete == nil then clearOnComplete = true end
  local doRender = opts.doRender
  if doRender == nil then doRender = true end
  local highlightFn = opts.foreground and rSpheres.drawSphereHighlightForeground or rSpheres.drawSphereHighlight

  -- The working point (drives the cursor, node placement, edge inserts and node drags). Optionally snapped to a grid so
  -- every placed / dragged node lands on it; z is re-sampled from the terrain at the snapped x,y. rawPos stays unsnapped
  -- so edge-hover picking still works (a snapped point sits off the line, which would make mid-edge inserts impossible).
  groundOnly = opts.ground == true
  openLine = opts.open == true
  local rawPos = workPos()
  local mousePos = rawPos
  local snap = opts.snap
  if snap and snap.step and snap.step > 0 then
    local sx, sy = snapTo(rawPos.x, rawPos.y, snap)
    snapScr:set(sx, sy, 0)
    mousePos = vec3(sx, sy, core_terrain.getTerrainHeight(snapScr))
  end
  if doRender then
    rSpheres.drawSphereCursor(mousePos)
  end

  -- Render the polygon.
  if doRender then
    renderPolygon(opts.foreground == true, opts.segmentLabels == true)
  end

  -- Manage the toggling of the gizmo on/off using the ALT key.
  local isAltDown = im.IsKeyDown(altKeyIdx)
  if isAltDown and isAltDown ~= lastAltDown then
    isGizmoActive = not isGizmoActive
  end
  lastAltDown = isAltDown

  -- Manage the translation gizmo.
  if isGizmoActive then
    -- Rigid mode: the gizmo only moves the node it's attached to, so remember that node's spot and shift the rest of the
    -- polygon by its delta afterwards (mirrors the mouse-drag rigid path below).
    local rx, ry
    if opts.rigid then local s = polygon[selectedNodeIdx]; if s then rx, ry = s.x, s.y end end
    tmpTable[1].nodes = polygon
    gizmo.handleGizmo(false, 1, selectedNodeIdx, tmpTable, true, false, deepCopyPolygon, undoPolyEdit, redoPolyEdit)
    if im.IsMouseDown(0) then
      if rx then
        local s = polygon[selectedNodeIdx]
        local dx, dy = s.x - rx, s.y - ry
        if dx ~= 0 or dy ~= 0 then
          for i = 1, #polygon do
            if i ~= selectedNodeIdx then
              local p = polygon[i]
              local nx, ny = p.x + dx, p.y + dy
              tmp1:set(nx, ny, 0)
              p:set(nx, ny, core_terrain.getTerrainHeight(tmp1))
            end
          end
        end
      end
      isDirty = true
    end
  end

  -- If the mouse is moving, then reset the markup delay timer.
  local isMouseMoving = mousePos:squaredDistance(lastMousePos) > isMouseMoveTolSq
  if isMouseMoving then
    markupTime = timeUntilTextAppears
  end

  -- Handle the mouse events.
  if util.isMouseHoveringOverTerrain() then

    -- Handle the double click event.
    if im.IsMouseDoubleClicked(0) and #polygon > 2 then
      if doubleClickCallback then
        doubleClickCallback(deepCopyPolygon()) -- Call the callback if it exists.
      end
      if clearOnComplete then
        table.clear(polygon) -- Clear the polygon.
        selectedNodeIdx = 1
        isDirty = true
        return
      end
    end

    -- Handle 'end drag' events.
    if not im.IsMouseDown(0) then
      dragNodeIdx = nil -- Keep this empty any time the mouse button is not held down.
      dragArmed = false
    end

    -- Handle any active dragging events.
    if dragNodeIdx then
      -- A grab only becomes a drag once the cursor has pulled clear of where it went down; short of that it is a click, and a
      -- click must leave the node exactly where it stood.
      if not dragArmed and rawPos:squaredDistance(dragPress) > dragArmDist * dragArmDist then dragArmed = true end
      -- Driven by where the cursor IS rather than by it having just moved.
      if dragArmed then
        local base = polygon[dragNodeIdx]
        local tx, ty = snapTo(rawPos.x, rawPos.y, snap)
        -- Nothing actually moved, so nothing changed. Saying otherwise costs a host tool real work: reshaping a footprint in
        -- the massing editor retires the extrusions standing on the stretch of wall that moved.
        if tx ~= base.x or ty ~= base.y then
          if opts.rigid then
            -- Whole-shape move: shift every node by the grabbed node's delta so the polygon translates rigidly, re-sampling
            -- each node's z from the terrain at its new spot.
            local dx, dy = tx - base.x, ty - base.y
            for i = 1, #polygon do
              local p = polygon[i]
              local nx, ny = p.x + dx, p.y + dy
              tmp1:set(nx, ny, 0)
              p:set(nx, ny, core_terrain.getTerrainHeight(tmp1))
            end
          else
            tmp1:set(tx, ty, 0)
            base:set(tx, ty, core_terrain.getTerrainHeight(tmp1))
          end
          isDirty = true
        end
      end
      lastMousePos = mousePos
      return -- Return to prevent any checking any other mouse events in this frame.
    end

    -- CASE #1: Check if the mouse is over a polygon node.
    tmpTable[1].nodes = polygon
    local isOverNode, _, nodeIdx = geom.isMouseOverNode(tmpTable)
    if isOverNode then
      highlightFn(polygon[nodeIdx]) -- Draw a highlight when the mouse is over a node.
      rMarkup.markupDrag(polygon[nodeIdx]) -- Draw a special markup when the mouse is over a node.
      if im.IsMouseClicked(0) then
        selectedNodeIdx = nodeIdx
        dragNodeIdx = nodeIdx -- Start dragging when mouse btn is held over a highlighted node.
        dragPress:set(rawPos)
        dragArmed = false
        lastMousePos = mousePos
        return -- Return to prevent any checking any other mouse events in this frame.
      end
    else
      -- CASE #2: Check if the mouse is over a polygon edge (but not a node).
      local isOverEdge, idxLower = geom.isMouseOverPolyline(polygon, rawPos, not openLine)
      if isOverEdge then
        local at = onSeg(polygon[idxLower], polygon[idxLower % #polygon + 1], mousePos)
        highlightFn(at) -- Draw a highlight when the mouse is over a polygon edge.
        rMarkup.markupInsertNode(at) -- Draw a special markup when the mouse is over a polygon edge.
        if im.IsMouseClicked(0) then
          table.insert(polygon, idxLower + 1, at) -- Insert the new node at the correct intermediate position.
          markupTime = timeUntilTextAppears
          selectedNodeIdx = idxLower + 1
          dragNodeIdx = idxLower + 1 -- Start dragging so user can drag straight away after inserting the node.
          dragArmed = true -- Armed at once, since a node just put down is meant to be draggable in the same gesture.
          lastMousePos = mousePos
          isDirty = true
          return -- Return to prevent any checking any other mouse events in this frame.
        end
      else
        -- CASE #3: The mouse is not over a node or edge, so check for the adding of new nodes.
        if not isOverNode and markupTime < 0.0 then
          rMarkup.markupAddPolygonNode(mousePos) -- Show the delayed 'add node' markup.
        end
        if im.IsMouseClicked(0) then
          polygon[#polygon + 1] = vec3(mousePos)
          selectedNodeIdx = #polygon
          markupTime = timeUntilTextAppears
          dragNodeIdx = #polygon -- Start dragging so user can drag straight away after inserting the node.
          dragArmed = true -- As with an insert: it went down deliberately, so it is draggable in the same gesture.
          lastMousePos = mousePos
          isDirty = true
          return -- Return to prevent any checking any other mouse events in this frame.
        end
      end
    end
  end

  -- Handle node deletion using the delete key.
  if im.IsKeyDown(delKeyIdx) then
    if not hasDeletePressedRecently and selectedNodeIdx > 0 and selectedNodeIdx <= #polygon then
      local k = selectedNodeIdx
      table.remove(polygon, k)
      selectedNodeIdx = max(1, min(#polygon, selectedNodeIdx))
      hasDeletePressedRecently = true
      isDirty = true
    end
  else
    hasDeletePressedRecently = false -- Only allows one time use of the delete key.
  end

  -- Update the last mouse position.
  lastMousePos = mousePos

  -- Manage event timers.
  markupTime = max(-1.0, markupTime - markupTimer:stopAndReset() * 0.001)
end

-- Draw-only pass (no input): renders the current polygon's nodes, edges and (optionally) per-segment length labels. Used
-- when a host tool drives its own interaction (e.g. a rigid whole-shape move) but still wants the polygon drawn normally.
-- opts.hover: also pulse the node under the cursor, matching the hover feedback of the normal editing path.
local function render(opts)
  opts = opts or {}
  openLine = opts.open == true
  local fg = opts.foreground == true
  renderPolygon(fg, opts.segmentLabels == true)
  if opts.hover and #polygon > 0 then
    tmpTable[1].nodes = polygon
    local isOverNode, _, nodeIdx = geom.isMouseOverNode(tmpTable)
    if isOverNode then
      (fg and rSpheres.drawSphereHighlightForeground or rSpheres.drawSphereHighlight)(polygon[nodeIdx])
    end
  end
end

-- True while a node is being dragged (lets a host tool suppress its own scene interaction during a drag).
local function isDragging() return dragNodeIdx ~= nil end

-- Begins dragging the given node immediately, in the current mouse-down (no fresh click needed). Lets a host tool that
-- picks/selects a node with its own logic continue straight into a drag, matching the spline tools' select-and-drag.
local function beginDragNode(nodeIdx)
  if nodeIdx and nodeIdx >= 1 and nodeIdx <= #polygon then
    selectedNodeIdx = nodeIdx
    dragNodeIdx = nodeIdx
    dragArmed = false
    dragPress:set(workPos())
    lastMousePos = vec3(dragPress)
  end
end

-- True if the mouse is over one of the polygon's own nodes or edges (i.e. an edit target). Lets a host tool give
-- its polygon priority over cross-tool selection when deciding what a click means.
local function isMouseOverEditable()
  if #polygon < 1 then return false end
  tmpTable[1].nodes = polygon
  if geom.isMouseOverNode(tmpTable) then return true end
  return (geom.isMouseOverPolyline(polygon, util.mouseOnMapPos(), true)) == true
end


-- Public interface.
M.isDragging =                                          isDragging
M.beginDragNode =                                       beginDragNode
M.isMouseOverEditable =                                 isMouseOverEditable
M.getPolygon =                                          getPolygon
M.setPolygon =                                          setPolygon
M.isPolygonValid =                                      isPolygonValid
M.clearPolygon =                                        clearPolygon
M.consumeDirty =                                        consumeDirty
M.render =                                              render

M.handleUserPolygon =                                   handleUserPolygon

return M