-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This is a utility class for handling mouse and keyboard events across various spline-editing tools.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local isMouseMoveTolSq = 0.0001 -- The tolerance for determining if the mouse is moving, in squared meters per frame.
local pairNode2MarkupTolSq = 10.0 -- The squared distance at which the markup for placing the second pair node is shown.
local timeUntilTextAppears = 1.0 -- The time it takes for the text to appear when adding a new node, in seconds.
local depthSensitivity = 0.1 -- The sensitivity of depth adjustment, in meters per pixel.
local depthMin, depthMax = 1.0, 500.0 -- The minimum and maximum depth values, in meters.
local depthHandleScale = 0.5 -- Visual scale for depth handle height (stored depth is unscaled).

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')
local render = require('editor/toolUtilities/render')
local gizmo = require('editor/toolUtilities/gizmo')
local util = require('editor/toolUtilities/util')

-- Module constants.
local im = ui_imgui
local min, max, floor = math.min, math.max, math.floor
local shiftKeyIdx = im.GetKeyIndex(im.Key_ModShift)
local zExtra = 0.05
local altKeyIdx = im.GetKeyIndex(im.Key_ModAlt)
local delKeyIdx = im.GetKeyIndex(im.Key_Delete)

-- Module state.
local mouseLast, mouseVel2D, pMouse_2D = vec3(), vec3(), vec3()
local mouseLastRawY = 0.0
local isLeftNodePlaced, placedLeftNode, placedLeftDepth = false, vec3(), 1.0
local bestCursorSeg = 1
local cursorPos = vec3()
local cursorBN = 0.0
local isNodeDrag, dragNodeIdx, dragStatePre = false, 1, nil
local dragStartMousePos, dragStartNodePos = vec3(), vec3()
local isDepthDrag, dragBarIdx, dragDepthStatePre = false, 1, nil
local c1_2D, c2_2D, c3_2D, c4_2D = vec3(), vec3(), vec3(), vec3()
local lastAltDown, hasDeletePressedRecently = false, false
local markupTimer, markupTime, restTimer, restTime = hptimer(), 0.0, hptimer(), 0.0


local function updateDepthBarPoints(ribbon)
  local nodes, depths = ribbon.nodes, ribbon.depths
  local numNodes = #nodes
  if numNodes < 1 or not depths or #depths ~= numNodes then
    ribbon.barPoints = nil
    return
  end

  local barPoints = ribbon.barPoints
  if not barPoints then
    barPoints = {}
    ribbon.barPoints = barPoints
  end

  local isUpRibbon = ribbon.isUpRibbon
  for i = 1, numNodes do
    local p = barPoints[i] or vec3()
    barPoints[i] = p
    local node = nodes[i]
    local d = depths[i] or 0.0
    local topZ = node.z
    if not isUpRibbon then
      topZ = topZ + d
    end
    p:set(node.x, node.y, topZ + d * depthHandleScale)
  end
  for i = numNodes + 1, #barPoints do
    barPoints[i] = nil
  end
end

local function handleDepthDragging(ribbon, mouseRawY, isShiftDown, isLockShape, updateRibbonDataFn)
  local delta = (mouseLastRawY - mouseRawY) * depthSensitivity
  if isShiftDown then
    delta = delta * 0.1
  end
  local depths = ribbon.depths
  local dNew = nil
  if isLockShape then
    for i = 1, #depths do
      depths[i] = max(depthMin, min(depthMax, (depths[i] or depthMin) + delta))
    end
    dNew = depths[dragBarIdx] or 0.0
  else
    local pairIdx = dragBarIdx
    if pairIdx % 2 == 0 then
      pairIdx = pairIdx - 1
    end
    local d0 = depths[pairIdx] or depthMin
    dNew = max(depthMin, min(depthMax, d0 + delta))
    depths[pairIdx] = dNew
    depths[pairIdx + 1] = dNew
  end

  updateDepthBarPoints(ribbon)
  if ribbon.barPoints and ribbon.barPoints[dragBarIdx] then
    render.drawSphereHighlight(ribbon.barPoints[dragBarIdx])
    render.markupAdjustDepth(ribbon.barPoints[dragBarIdx])
    render.markupDepthDisplay(ribbon.barPoints[dragBarIdx], dNew)
  end
  updateRibbonDataFn(ribbon)
end

-- Places a pair of nodes on the ribbon.
local function placePair(pMouse, ribbon, pRight, depthRight)
  -- Place the pair depending on the case (add to start, add to end, or insert in middle).
  local nodes, depths, numSegs = ribbon.nodes, ribbon.depths, ribbon.numSegs
  if bestCursorSeg <= numSegs then
    -- CASE #1: Only 1 segment exists on the ribbon.
    if #nodes == 4 then
      local dSq1 = placedLeftNode:squaredDistance(nodes[1])
      local dSq2 = placedLeftNode:squaredDistance(nodes[3])
      if dSq1 < dSq2 then
        -- Extend at the beginning of the ribbon.
        local isInt = geom.isLineSegIntersect(placedLeftNode, nodes[1], pRight, nodes[2])
        if isInt then
          table.insert(nodes, 1, pRight)
          table.insert(nodes, 2, placedLeftNode)
          table.insert(depths, 1, depthRight)
          table.insert(depths, 2, placedLeftDepth)
        else
          table.insert(nodes, 1, placedLeftNode)
          table.insert(nodes, 2, pRight)
          table.insert(depths, 1, placedLeftDepth)
          table.insert(depths, 2, depthRight)
        end
        return
      else
        -- Extend at the end of the ribbon.
        local isInt = geom.isLineSegIntersect(placedLeftNode, nodes[#nodes - 1], pRight, nodes[#nodes])
        if isInt then
          table.insert(nodes, pRight)
          table.insert(nodes, placedLeftNode)
          table.insert(depths, depthRight)
          table.insert(depths, placedLeftDepth)
        else
          table.insert(nodes, placedLeftNode)
          table.insert(nodes, pRight)
          table.insert(depths, placedLeftDepth)
          table.insert(depths, depthRight)
        end
        return
      end
    end

    -- CASE #2: Multiple segments exist on the ribbon, and mouse is not hovering over any segment.
    local twoSegIdx = bestCursorSeg * 2
    local i1, i2, i3, i4 = twoSegIdx - 1, twoSegIdx, twoSegIdx + 1, twoSegIdx + 2
    local c1, c2, c3, c4 = nodes[i1], nodes[i2], nodes[i3], nodes[i4]
    pMouse_2D:set(pMouse.x, pMouse.y, 0.0)
    c1_2D:set(c1.x, c1.y, 0.0)
    c2_2D:set(c2.x, c2.y, 0.0)
    c3_2D:set(c3.x, c3.y, 0.0)
    c4_2D:set(c4.x, c4.y, 0.0)
    local isPointInQuad = geom.isPointInTriangle(pMouse_2D, c1_2D, c2_2D, c3_2D) or geom.isPointInTriangle(pMouse_2D, c2_2D, c3_2D, c4_2D)
    if not isPointInQuad then
      if bestCursorSeg == numSegs or numSegs < 1 then
        -- CASE #2A: Last segment is the closest, but pair outside of quad. Extend at the end of the ribbon.
        local isInt = geom.isLineSegIntersect(placedLeftNode, nodes[#nodes - 1], pRight, nodes[#nodes])
        if isInt then
          table.insert(nodes, pRight)
          table.insert(nodes, placedLeftNode)
          table.insert(depths, depthRight)
          table.insert(depths, placedLeftDepth)
        else
          table.insert(nodes, placedLeftNode)
          table.insert(nodes, pRight)
          table.insert(depths, placedLeftDepth)
          table.insert(depths, depthRight)
        end
        return
      elseif bestCursorSeg == 1 then
        -- CASE #2B: First segment is the closest, but pair outside of quad. Extend at the beginning of the ribbon.
        local isInt = geom.isLineSegIntersect(placedLeftNode, nodes[1], pRight, nodes[2])
        if isInt then
          table.insert(nodes, 1, pRight)
          table.insert(nodes, 2, placedLeftNode)
          table.insert(depths, 1, depthRight)
          table.insert(depths, 2, placedLeftDepth)
        else
          table.insert(nodes, 1, placedLeftNode)
          table.insert(nodes, 2, pRight)
          table.insert(depths, 1, placedLeftDepth)
          table.insert(depths, 2, depthRight)
        end
        return
      end
    end

    -- CASE #3: Mouse is hovering over a segment. Insert the pair into the middle of the segment.
    local idx = bestCursorSeg * 2 + 1
    local isInt = geom.isLineSegIntersect(placedLeftNode, nodes[idx], pRight, nodes[idx + 1])
    if isInt then
      table.insert(nodes, idx, pRight)
      table.insert(nodes, idx + 1, placedLeftNode)
      table.insert(depths, idx, depthRight)
      table.insert(depths, idx + 1, placedLeftDepth)
    else
      table.insert(nodes, idx, placedLeftNode)
      table.insert(nodes, idx + 1, pRight)
      table.insert(depths, idx, placedLeftDepth)
      table.insert(depths, idx + 1, depthRight)
    end
    return
  else
    table.insert(nodes, placedLeftNode)
    table.insert(nodes, pRight)
    table.insert(depths, placedLeftDepth)
    table.insert(depths, depthRight)
  end
end

-- Update the given cursor position.
-- [We attempt to find a closer 'best segment index' by comparing current with both neighbours and a random segment. Then we jump if closer.]
-- [This is quick because the brute force searching is distributed over multiple frames, so convergence can be slightly delayed].
local function updateCursor(ribbon, p)
  local pClosest, bestSqDist = geom.closestRibbonSegPointToPoint(bestCursorSeg, ribbon, p)
  if pClosest then
    cursorPos:set(pClosest)

    -- First, try the segment directly below the current segment.
    if bestCursorSeg > 1 then
      local pClosest, dSq = geom.closestRibbonSegPointToPoint(bestCursorSeg - 1, ribbon, p)
      if dSq < bestSqDist then
        bestSqDist = dSq
        cursorPos:set(pClosest)
        bestCursorSeg = bestCursorSeg - 1
      end
    end

    -- Second, try the segment directly above the current segment.
    local numSegs = ribbon.numSegs
    if bestCursorSeg < numSegs then
      local pClosest, dSq = geom.closestRibbonSegPointToPoint(bestCursorSeg + 1, ribbon, p)
      if dSq < bestSqDist then
        bestSqDist = dSq
        cursorPos:set(pClosest)
        bestCursorSeg = bestCursorSeg + 1
      end
    end

    -- Third, try a random segment.
    cursorBN = getBlueNoise1d(cursorBN)
    local segSample = max(1, floor(cursorBN * numSegs))
    local pClosest, dSq = geom.closestRibbonSegPointToPoint(segSample, ribbon, p)
    if segSample ~= bestCursorSeg then
      if dSq < bestSqDist then
        bestSqDist = dSq
        cursorPos:set(pClosest)
        bestCursorSeg = segSample
      end
    end
  end
end

-- Handles the user input events for ribbon splines.
-- [ribbons - The array of ribbons to edit.]
-- [out - A table with the following common fields (will be updated as the user interacts with the ribbons):]
  -- [ribbonIdx - The index of the ribbon to edit.]
  -- [nodeIdx - The index of the node to edit.]
  -- [isGizmoActive - Whether the gizmo is active.]
-- [useGizmo - Whether the gizmo is useable or not.]
-- [isRigidTranslation - Whether the translation is rigid (all nodes move by the same amount on drag), or free (each node moves independently).]
-- [masterDepth - The depth to use for new pairs of nodes.]
-- [updateRibbonDataFn - A callback function to update the ribbon data after a change has been made.]
-- [deepCopyFn - A callback function to deep copy ALL the ribbon data (full state of collection of ribbons).]
-- [undoFn - A callback function to undo ALL the ribbon data (full state of collection of ribbons).]
-- [redoFn - A callback function to redo ALL the ribbon data (full state of collection of ribbons).]
-- [Returns - The best found segment for the cursor segment search, on the selected ribbon.]
local function handleRibbonEvents(ribbons, out, useGizmo, isRigidTranslation, masterDepth, updateRibbonDataFn, deepCopyFn, undoFn, redoFn)
  local activeIdx = out.ribbonIdx or out.prismIdx
  if out.ribbonIdx == nil and activeIdx ~= nil then
    out.ribbonIdx = activeIdx
  end

  local ribbon = ribbons[activeIdx]
  if not ribbon then
    return -- The selected ribbon is not valid, so exit.
  end

  updateDepthBarPoints(ribbon)

  -- Update the mouse position and velocity, and cache the current mouse state.
  local mousePos = util.mouseOnMapPos() -- The current mouse position.
  mouseVel2D:set(mousePos.x - mouseLast.x, mousePos.y - mouseLast.y, 0.0) -- The 2D mouse velocity.
  local isMouseMoving = mouseVel2D:squaredLength() > isMouseMoveTolSq
  if isMouseMoving then
    restTime = timeUntilTextAppears -- Reset the rest time when the mouse is moving.
  end

  -- Draw the mouse cursor.
  render.drawSphereCursor(mousePos)
  local mouseRawY = im.GetMousePos().y

  -- Update the cursor position.
  if bestCursorSeg < 1 or bestCursorSeg > ribbon.numSegs then
    bestCursorSeg = 1
  end
  updateCursor(ribbon, mousePos)

  -- Draw the left pair node, if it exists.
  local nodes = ribbon.nodes
  local numNodes = #nodes
  if isLeftNodePlaced then
    render.drawSphereNode(placedLeftNode)
    render.drawSphereHighlight(placedLeftNode)
    if numNodes ~= 2 then
      render.markupPairFirstNode(placedLeftNode)
    end
    render.drawRibLine(placedLeftNode, mousePos)
    if mousePos:squaredDistance(placedLeftNode) > pairNode2MarkupTolSq then
      render.markupPairSecondNode(mousePos)
    end
  end

  -- If there are less than 4 nodes, draw some guidelines.
  if numNodes < 3 then
    if numNodes > 1 then
      local p1, p2 = nodes[1], nodes[2]
      render.drawSplineLine(p1, p2) -- A first pair already exists, so draw a solid between them.
      render.markupNode1(p1)
      render.markupNode2(p2)
      if isLeftNodePlaced then
        render.drawSphereNode(placedLeftNode)
        render.drawSplineLineDull(p1, placedLeftNode) -- User is placing the fourth node, so draw the proposed quadrilateral.
        render.drawSplineLineDull(p2, mousePos)
        render.drawSplineLineDull(placedLeftNode, mousePos)
        render.markupNode3(placedLeftNode)
      else
        render.drawSplineLineDull(p1, mousePos) -- User is placing the third node, so draw a line from the first node to the mouse position.
      end
    end
  end

  -- Mouse right-click removes any placed left node.
  if im.IsMouseClicked(1) and isLeftNodePlaced then
    isLeftNodePlaced, placedLeftNode, placedLeftDepth = false, nil, 1.0
  end

  -- Handle the adding of new nodes and dragging of existing nodes.
  if util.isMouseHoveringOverTerrain() then
    -- Depth bar interaction (selected ribbon only).
    if not isLeftNodePlaced and not isNodeDrag then
      updateDepthBarPoints(ribbon)
      local isOverBar, rIdx, barIdx = geom.isMouseOverBar(ribbons)
      if isOverBar and rIdx == activeIdx and ribbon.barPoints and ribbon.barPoints[barIdx] then
        if not isDepthDrag then
          render.drawSphereBarHover(ribbon.barPoints[barIdx])
          render.markupAdjustDepth(ribbon.barPoints[barIdx])
          render.markupDepthDisplay(ribbon.barPoints[barIdx], ribbon.depths[barIdx] or 0.0)
          if im.IsMouseDown(0) then
            out.nodeIdx = barIdx
            isDepthDrag, dragBarIdx, dragDepthStatePre = true, barIdx, deepCopyFn()
            mouseLastRawY = mouseRawY
            return bestCursorSeg, isNodeDrag
          end
        end
      end
    end

    if isDepthDrag then
      handleDepthDragging(ribbon, mouseRawY, im.IsKeyDown(shiftKeyIdx), isRigidTranslation, updateRibbonDataFn)
      if not im.IsMouseDown(0) then
        editor.history:commitAction("Drag Depth", { old = dragDepthStatePre, new = deepCopyFn() }, undoFn, redoFn)
        isDepthDrag, dragBarIdx, dragDepthStatePre = false, 1, nil
      end
      mouseLastRawY = mouseRawY
      mouseLast = mousePos
      return bestCursorSeg, isNodeDrag
    end

    -- Handle the mouse events.
    local isOverNode, rIdx, nodeIdx = geom.isMouseOverNode(ribbons)
    if isOverNode then
      if not isNodeDrag then
        render.drawSphereHighlight(ribbons[rIdx].nodes[nodeIdx]) -- User is over a node, so highlight that.
        if im.IsMouseDown(0) then
          out.ribbonIdx, out.prismIdx, out.nodeIdx = rIdx, rIdx, nodeIdx -- User is starting to drag a node.
          activeIdx = rIdx
          isNodeDrag, dragNodeIdx, dragStatePre = true, nodeIdx, deepCopyFn()
          dragStartMousePos:set(mousePos)
          dragStartNodePos:set(ribbons[rIdx].nodes[nodeIdx])
          return bestCursorSeg, isNodeDrag -- Leave early to prevent the case when selected ribbon has changed - the old selected ribbon must remain intact.
        else
          if not isNodeDrag and not im.IsMouseDown(0) and markupTime < 0.0 then
            render.markupDrag(ribbons[rIdx].nodes[nodeIdx]) -- Draw a special markup when the mouse is over a node.
          end
        end
      end
    else
      if not isNodeDrag and not isLeftNodePlaced and restTime < 0.0 then
        render.markupAddPairLeft(mousePos) -- Draw a special markup when the mouse is over free space.
      end
      if im.IsMouseClicked(0) and not im.IsKeyDown(altKeyIdx) then
        if not isLeftNodePlaced then
          placedLeftNode = vec3(mousePos.x, mousePos.y, mousePos.z + zExtra) -- The user is placing the left node of a new pair.
          placedLeftDepth, isLeftNodePlaced = masterDepth, true
          markupTime = timeUntilTextAppears -- Reset the markup delay time when a node is added.
        else
          local statePre = deepCopyFn()
          placePair(mousePos, ribbon, vec3(mousePos.x, mousePos.y, mousePos.z + zExtra), masterDepth) -- The user is placing the right node of a new pair. Add to ribbon.
          updateRibbonDataFn(ribbon)
          updateDepthBarPoints(ribbon)
          out.nodeIdx = #ribbon.nodes
          editor.history:commitAction("Add Node", { old = statePre, new = deepCopyFn() }, undoFn, redoFn)
          placedLeftNode, isLeftNodePlaced = nil, false
          markupTime = timeUntilTextAppears -- Reset the markup delay time when a node is added.
        end
      end
    end
    if isNodeDrag then
      if isRigidTranslation then
        for i = 1, #nodes do
          nodes[i] = nodes[i] + mouseVel2D -- Dragging with rigid translation mode.
        end
      else
        -- Calculate offset from initial positions to prevent jumping
        local offset = mousePos - dragStartMousePos
        nodes[dragNodeIdx]:set(dragStartNodePos + offset)
      end
      if not im.IsMouseDown(0) then
        editor.history:commitAction("Drag Node", { old = dragStatePre, new = deepCopyFn() }, undoFn, redoFn)
        isNodeDrag, dragNodeIdx, dragStatePre = false, 1, nil -- User has stopped dragging, so reset the drag state.
      end
      updateRibbonDataFn(ribbon)
      updateDepthBarPoints(ribbon)
    end
  end

  -- Handle node deletion events.
  if not isLeftNodePlaced and not isNodeDrag and im.IsKeyDown(delKeyIdx) then
    if not hasDeletePressedRecently and out.nodeIdx > 0 and out.nodeIdx <= #nodes then
      local statePre = deepCopyFn()
      if out.nodeIdx % 2 == 0 then
        table.remove(nodes, out.nodeIdx - 1)
        table.remove(nodes, out.nodeIdx - 1) -- The selected node is a right node, so its matching left is the previous node. We delete both.
      else
        table.remove(nodes, out.nodeIdx)
        table.remove(nodes, out.nodeIdx) -- The selected node is a left node, so its matching right is the next node. We delete both.
      end
      updateRibbonDataFn(ribbon)
      updateDepthBarPoints(ribbon)
      out.nodeIdx = max(1, min(#nodes, out.nodeIdx))
      hasDeletePressedRecently = true
      editor.history:commitAction("Delete Node", { old = statePre, new = deepCopyFn() }, undoFn, redoFn)
    end
  else
    hasDeletePressedRecently = false -- Reset the delete key flag when it is released. Ensures one time use only for the delete key (once released, it resets).
  end

  -- If requested, manage the ALT key for toggling the gizmo on/off.
  if useGizmo and not isLeftNodePlaced then
    local isAltDown = im.IsKeyDown(altKeyIdx)
    if isAltDown and isAltDown ~= lastAltDown then
      out.isGizmoActive = not out.isGizmoActive
    end
    if out.isGizmoActive then
      gizmo.handleGizmo(false, activeIdx, out.nodeIdx, ribbons, false, isRigidTranslation, deepCopyFn, undoFn, redoFn) -- Handle the gizmo for translation, if it is active.
      updateDepthBarPoints(ribbon)
    end
    lastAltDown = isAltDown
  end

  -- Manage the markup event timers.
  -- [Timers run from some positive value when set, then decrement until they reach -1.0. Events are triggered when the timers drop below 0.0]
  markupTime = max(-1.0, markupTime - markupTimer:stopAndReset() * 0.001)
  restTime = max(-1.0, restTime - restTimer:stopAndReset() * 0.001)

  -- Update the mouse position.
  mouseLast = mousePos
  mouseLastRawY = mouseRawY

  return bestCursorSeg, isNodeDrag
end


-- Public interface.
M.handleRibbonEvents =                                  handleRibbonEvents
M.handlePrismEvents =                                   handleRibbonEvents

return M