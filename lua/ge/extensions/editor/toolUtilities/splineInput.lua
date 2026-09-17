-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This is a utility class for handling mouse and keyboard events across various spline-editing tools.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local isMouseMoveTolSq = 0.0001 -- The tolerance for determining if the mouse is moving, in squared meters per frame.
local heightSensitivity = 1 -- The sensitivity of the height adjustment, in meters per pixel.

local joinDist = 15.0 -- The max distance considered, for loop/join formation, in meters.

local minSplineWidth, maxSplineWidth = 3.0, 200.0 -- The minimum and maximum widths for a spline, in meters.
local minSplineHeight, maxSplineHeight = 0.0, 70.0 -- The minimum and maximum heights for a spline, in meters.
local defaultSplineVel, defaultSplineVelLimit = 13.5, 70.0 -- The default velocity and velocity limit for a spline node, in meters per second.

local timeUntilTextAppears = 1.0 -- The time it takes for the text to appear when adding a new node, in seconds.

local intsctTol = 10000.0 -- The tolerance for hit detection, in meters.
local baseHitScale = 0.2  -- A base factor used to scale the hit detection tolerance.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')
local render = require('editor/toolUtilities/render')
local gizmo = require('editor/toolUtilities/gizmo')
local util = require('editor/toolUtilities/util')

-- Module constants.
local im = ui_imgui
local min, max, ceil, sqrt, abs = math.min, math.max, math.ceil, math.sqrt, math.abs
local globalUp = vec3(0, 0, 1)
local joinDistSq = joinDist * joinDist
local altKeyIdx, ctrlKeyIdx, shiftKeyIdx = im.GetKeyIndex(im.Key_ModAlt), im.GetKeyIndex(im.Key_ModCtrl), im.GetKeyIndex(im.Key_ModShift)
local delKeyIdx, cKeyIdx, vKeyIdx = im.GetKeyIndex(im.Key_Delete), im.GetKeyIndex(im.Key_C), im.GetKeyIndex(im.Key_V)
local typeScales = { -- The scale factors for the different hit types.
  node = 0.9,
  rib = 1.1,
  bar = 1.1,
}

-- Module state.
local registeredTools = {}
local registeredToolList = {}
local mouseLastRawY = 0.0
local lastAltDown, hasDeletePressedRecently = false, false
local dragSplineIdx, dragNodeIdx, dragStatePre, isDragRib, isDragBar, isDragAux, dragRibIsFirstHandle = nil, nil, nil, nil, nil, nil, nil
local dragAuxIdx, dragTipKind = nil, nil -- tipKind: 'start'|'finish'|nil — survives junction node-array edits
local isLoopAvailable, isJoinAvailable, isMidJoinAvailable = false, false, false
local joinSplineIdx1, joinNodeIdx1, joinSplineIdx2, joinNodeIdx2 = nil, nil, nil, nil
local midJoinDragSplineIdx, midJoinDragNodeIdx, midJoinTargetSplineIdx, midJoinHitPos = nil, nil, nil, nil
local ctrlCProfile = nil
local hasPastePressedRecently = false
local markupTimer, markupTime, restTimer, restTime = hptimer(), 0.0, hptimer(), 0.0
local candType, candDist, candSplineIdx, candNodeIdx, candRibIdx, candAuxIdx = {}, {}, {}, {}, {}, {}
local candIdxLower, candPHit, candPriority, hitCandidates, tmpTable = {}, {}, {}, {}, {}
local allSplines, splineToolNames = {}, {}
local mouseVel2D, mouseLast, binVec = vec3(), vec3(), vec3()
local lastDragMousePos = vec3()
local midJoinClosest = vec3()


local function clearDragState()
  dragStatePre, isDragRib, isDragBar, isDragAux = nil, nil, nil, nil
  dragSplineIdx, dragNodeIdx, dragAuxIdx, dragRibIsFirstHandle, dragTipKind = nil, nil, nil, nil, nil
end

-- Tip drags must track start/finish, not a raw index (junction mouth rebuild can reindex nodes).
local function tipKindForNode(nodes, nodeIdx)
  if not nodes or not nodeIdx then return nil end
  if nodeIdx == 1 then return 'start' end
  if nodeIdx == #nodes then return 'finish' end
  return nil
end

local function resolveDragNodeIdx(nodes)
  if dragTipKind == 'start' then return 1 end
  if dragTipKind == 'finish' then return #nodes end
  return dragNodeIdx
end

local function isDragging()
  return dragSplineIdx ~= nil or isDragAux == true
end

local function getActiveTool()
  local name = editor.editMode and editor.editMode.displayName
  return name and registeredTools[name] or nil
end

local function isNodeLockedByTool(spline, nodeIdx)
  local tool = getActiveTool()
  return tool and tool.isNodeLocked and tool.isNodeLocked(spline, nodeIdx) or false
end

-- Handles end drag events (loop formation, joins, cleanup).
-- afterEndDragFn(selSpline, wasAuxDrag, auxIdx, dragSplineIdx, dragNodeIdx)
local function handleEndDragEvents(splines, selSpline, copyFn, copyStateFn, joinFn, undoFn, redoFn, undoStateFn, redoStateFn, afterEndDragFn, isShiftDown, midJoinFn)
  if dragStatePre then
    -- Aux-node drag (e.g. junction centre) uses full session state undo.
    if isDragAux then
      -- Flush/mouth rebuild first, then snapshot `new` so undo matches what the user sees.
      local auxIdx, oldState = dragAuxIdx, dragStatePre
      clearDragState()
      if afterEndDragFn then afterEndDragFn(selSpline, true, auxIdx, nil, nil) end
      if copyStateFn and undoStateFn and redoStateFn and oldState then
        editor.history:commitAction("Drag Aux Node", { old = oldState, new = copyStateFn() }, undoStateFn, redoStateFn, true)
      end
      return true
    end

    -- If there is a loop available and SHIFT is held, form the loop.
    if isLoopAvailable and isShiftDown then
      local fullStatePre = copyFn(selSpline)
      local lastIdx = #selSpline.nodes
      table.remove(selSpline.nodes, lastIdx)
      table.remove(selSpline.widths, lastIdx)
      table.remove(selSpline.nmls, lastIdx)
      selSpline.isLoop = true
      selSpline.isDirty = true
      isLoopAvailable = false
      editor.history:commitAction("Drag Loop", { old = fullStatePre, new = copyFn(selSpline) }, undoFn, redoFn, true)
      clearDragState()
      return false
    end

    -- End↔end join. Tools that pass midJoinFn (transportNetwork) join on release;
    -- other tools keep the legacy SHIFT requirement.
    local joinNoShift = midJoinFn ~= nil
    if isJoinAvailable and (joinNoShift or isShiftDown) and joinFn and copyStateFn then
      local fullStatePre = copyStateFn()
      joinFn(joinSplineIdx1, joinNodeIdx1, joinSplineIdx2, joinNodeIdx2)
      isJoinAvailable = false
      joinSplineIdx1, joinNodeIdx1, joinSplineIdx2, joinNodeIdx2 = nil, nil, nil, nil
      editor.history:commitAction("Drag Join", { old = fullStatePre, new = copyStateFn() }, undoStateFn, redoStateFn, true)
      clearDragState()
      return true
    end

    -- End→mid join on release (transportNetwork).
    if isMidJoinAvailable and midJoinFn and copyStateFn then
      local fullStatePre = copyStateFn()
      midJoinFn(midJoinDragSplineIdx, midJoinDragNodeIdx, midJoinTargetSplineIdx, midJoinHitPos)
      isMidJoinAvailable = false
      midJoinDragSplineIdx, midJoinDragNodeIdx, midJoinTargetSplineIdx, midJoinHitPos = nil, nil, nil, nil
      editor.history:commitAction("Drag Mid Join", { old = fullStatePre, new = copyStateFn() }, undoStateFn, redoStateFn, true)
      clearDragState()
      return true
    end

    -- End the drag. Pass the node that was actually dragged (remap tip after junction edits).
    local endedSplineIdx = dragSplineIdx
    local endedNodeIdx = resolveDragNodeIdx(splines[dragSplineIdx].nodes)
    editor.history:commitAction("Drag", { old = dragStatePre, new = copyFn(splines[dragSplineIdx]) }, undoFn, redoFn, true)
    if afterEndDragFn then
      afterEndDragFn(selSpline, false, nil, endedSplineIdx, endedNodeIdx)
    end
  end

  -- Reset the drag state.
  clearDragState()
  isMidJoinAvailable = false
  midJoinDragSplineIdx, midJoinDragNodeIdx, midJoinTargetSplineIdx, midJoinHitPos = nil, nil, nil, nil

  return false
end

-- Handles bar dragging operations.
local function handleBarDragging(selSpline, mouseRawY, isBarsLimits, isLockShape, isShiftDown)
  local vals = isBarsLimits and selSpline.velLimits or selSpline.vels -- Determine which data the bars represent.
  local delta = (mouseLastRawY - mouseRawY) * heightSensitivity -- Calculate the magnitude of the drag.
  if isShiftDown then
    delta = delta * 0.1 -- Apply precision scaling when SHIFT is held.
  end
  if isLockShape then -- Rigid translation.
    for i = 1, #vals do
      vals[i] = max(minSplineHeight, min(maxSplineHeight, vals[i] + delta))
    end
  else -- A single bar is being dragged.
    vals[dragNodeIdx] = max(minSplineHeight, min(maxSplineHeight, vals[dragNodeIdx] + delta))
  end
  local barPts = selSpline.barPoints
  if barPts and barPts[dragNodeIdx] then
    render.drawSphereHighlight(barPts[dragNodeIdx])
  end
  selSpline.isDirty = true
end

-- Handles rib dragging operations.
local function handleRibDragging(selSpline, isLockShape, isShiftDown)
  -- Calculate the magnitude of the drag.
  dragNodeIdx = resolveDragNodeIdx(selSpline.nodes)
  local widths = selSpline.widths
  local ribPoints, dragNodeIdxTimesTwo, delta = selSpline.ribPoints, dragNodeIdx * 2, 0.0
  local isHalfSpline = selSpline.tileSet ~= nil or selSpline.spacing ~= nil
  if isHalfSpline then -- Half-spline.
    local ribPoint = ribPoints[dragNodeIdxTimesTwo]
    render.drawSphereHighlight(ribPoint)
    render.markupWidthDisplay(ribPoint, widths[dragNodeIdx])
    local divIdx = selSpline.discMap[dragNodeIdx]
    delta = mouseVel2D:dot(selSpline.binormals[divIdx])
  else -- Full spline.
    local p1, p2 = ribPoints[dragNodeIdxTimesTwo], ribPoints[dragNodeIdxTimesTwo - 1]
    render.drawSphereHighlight(p1)
    render.drawSphereHighlight(p2)
    render.markupWidthDisplay(p1, widths[dragNodeIdx])
    binVec:setSub2(p2, p1)
    binVec:normalize()
    local handleSign = dragRibIsFirstHandle and -1 or 1
    delta = handleSign * mouseVel2D:dot(binVec)
  end

  -- Apply precision scaling when SHIFT is held.
  if isShiftDown then
    delta = delta * 0.1
  end

  -- Move the widths appropriately.
  if isLockShape then -- Move all widths by the same amount.
    for i = 1, #widths do
      widths[i] = max(minSplineWidth, min(maxSplineWidth, widths[i] + delta))
    end
  else -- Move a single width.
    widths[dragNodeIdx] = max(minSplineWidth, min(maxSplineWidth, widths[dragNodeIdx] + delta))
  end

  selSpline.isDirty = true
end

-- Handles node dragging and formation detection (loops/joins).
-- canJoinFn(dragSplineIdx, otherSplineIdx) / canJoinAuxFn(dragSplineIdx, auxIdx): optional
-- predicates letting a tool keep separate networks apart (e.g. paths never join roads). When
-- absent every candidate is joinable (default for tools with a single network).
local function handleNodeDragging(splines, out, mousePos, isLockShape, midJoinFn, canJoinFn, canJoinAuxFn)
  -- Translate the nodes appropriately.
  local spline = splines[dragSplineIdx]
  local nodes = spline.nodes
  dragNodeIdx = resolveDragNodeIdx(nodes)
  out.node = dragNodeIdx
  if isLockShape then -- Rigid translation (all nodes).
    for i = 1, #nodes do
      nodes[i]:setAdd(mouseVel2D)
    end
  else -- A single node is being dragged.
    local node = nodes[dragNodeIdx]
    if node and not isNodeLockedByTool(spline, dragNodeIdx) then
      node:setAdd(mousePos - mouseLast)
    end
  end

  -- Check for loop candidate (start to end/end to start of the same spline).
  local numNodes = #nodes
  isLoopAvailable = false
  if (dragNodeIdx == 1 or dragNodeIdx == numNodes) and numNodes > 3 and not splines[out.spline].isLoop then
    local nodeStart, nodeEnd = nodes[1], nodes[numNodes]
    if nodeStart:squaredDistance(nodeEnd) < joinDistSq then
      render.renderCandidateLoop(nodeStart, nodeEnd) -- Show a line joining the start and end nodes, to indicate a loop is possible.
      isLoopAvailable = true -- Mark that we have a loop candidate.
    end
  end

  -- Check for join candidate (between two separate splines of the same tool).
  -- End↔end uses XY distance so elevated tips still match; mid-join uses tip↔centerline proximity.
  -- When midJoinFn is set, pick the closest of end / mid / junction — otherwise any tip within
  -- joinDist of an end (common on short roads) permanently blocks T-joins.
  isJoinAvailable = false
  isMidJoinAvailable = false
  midJoinDragSplineIdx, midJoinDragNodeIdx, midJoinTargetSplineIdx, midJoinHitPos = nil, nil, nil, nil
  if (dragNodeIdx == 1 or dragNodeIdx == numNodes) and not isLoopAvailable and numNodes > 1 then
    local draggedNode, isDraggingStart = nodes[dragNodeIdx], dragNodeIdx == 1
    local joinNoShift = midJoinFn ~= nil
    local bestEndDistSq, endHitPos = joinDistSq, nil

    for i = 1, #splines do
      local otherSpline = splines[i]
      if i ~= dragSplineIdx and otherSpline.isEnabled and not otherSpline.isLink and not otherSpline.isLoop
        and (not canJoinFn or canJoinFn(dragSplineIdx, i)) then
        local otherNodes = otherSpline.nodes
        if #otherNodes > 1 then
          local otherStart, otherEnd = otherNodes[1], otherNodes[#otherNodes]
          local dStart = geom.squaredDistance2D(draggedNode, otherStart)
          local dEnd = geom.squaredDistance2D(draggedNode, otherEnd)
          if dStart < bestEndDistSq then
            bestEndDistSq, endHitPos = dStart, otherStart
            joinSplineIdx1 = dragSplineIdx
            joinNodeIdx1 = isDraggingStart and 1 or numNodes
            joinSplineIdx2, joinNodeIdx2 = i, 1
          end
          if dEnd < bestEndDistSq then
            bestEndDistSq, endHitPos = dEnd, otherEnd
            joinSplineIdx1 = dragSplineIdx
            joinNodeIdx1 = isDraggingStart and 1 or numNodes
            joinSplineIdx2, joinNodeIdx2 = i, #otherNodes
          end
        end
      end
    end

    if midJoinFn then
      local bestMidDistSq, bestMidIdx = joinDistSq, nil
      for i = 1, #splines do
        local otherSpline = splines[i]
        -- 2+ nodes is enough (insert-at-mid then split yields two open roads).
        if i ~= dragSplineIdx and otherSpline.isEnabled and not otherSpline.isLink and not otherSpline.isLoop and #otherSpline.nodes > 1
          and (not canJoinFn or canJoinFn(dragSplineIdx, i)) then
          -- Tip stubs excluded on first/last segment only (see geom.closestPointOnPolyline2D).
          local d = geom.closestPointOnPolyline2D(otherSpline.nodes, draggedNode, midJoinClosest, 0.05, 0.95)
          if d < bestMidDistSq then
            bestMidDistSq, bestMidIdx = d, i
            if not midJoinHitPos then midJoinHitPos = vec3() end
            midJoinHitPos:set(midJoinClosest)
          end
        end
      end

      local bestJctDistSq, bestJctPos = joinDistSq, nil
      local tool = getActiveTool()
      local auxNodes = tool and tool.getAuxNodes and tool.getAuxNodes() or nil
      if auxNodes then
        for ai = 1, #auxNodes do
          local ap = auxNodes[ai]
          if ap and (not canJoinAuxFn or canJoinAuxFn(dragSplineIdx, ai)) then
            local d = geom.squaredDistance2D(draggedNode, ap)
            if d < bestJctDistSq then
              bestJctDistSq, bestJctPos = d, ap
            end
          end
        end
      end

      if bestJctPos and bestJctDistSq <= bestMidDistSq and bestJctDistSq <= bestEndDistSq then
        render.renderCandidateJoin(draggedNode, bestJctPos, true)
      elseif bestMidIdx and midJoinHitPos and bestMidDistSq < bestEndDistSq then
        render.renderCandidateJoin(draggedNode, midJoinHitPos, true)
        isMidJoinAvailable = true
        midJoinDragSplineIdx = dragSplineIdx
        midJoinDragNodeIdx = dragNodeIdx
        midJoinTargetSplineIdx = bestMidIdx
      elseif endHitPos then
        render.renderCandidateJoin(draggedNode, endHitPos, joinNoShift)
        isJoinAvailable = true
      end
    elseif endHitPos then
      render.renderCandidateJoin(draggedNode, endHitPos, false)
      isJoinAvailable = true
    end
  end

  -- Only set dirty flag if mouse has moved enough to warrant an update.
  local mouseMoveDistanceSq = mousePos:squaredDistance(lastDragMousePos)
  if mouseMoveDistanceSq > isMouseMoveTolSq then
    splines[dragSplineIdx].isDirty = true
    lastDragMousePos:set(mousePos) -- Update last position for next frame.
  end
end

-- Updates timers and mouse state
local function updateTimersAndMouseState(mouseRawY, mousePos)
  -- Update the markup timer.
  local deltaTime = markupTimer:stopAndReset() * 0.001
  markupTime = markupTime > deltaTime and markupTime - deltaTime or -1.0

  -- Update the rest timer.
  local restDelta = restTimer:stopAndReset() * 0.001
  restTime = restTime > restDelta and restTime - restDelta or -1.0

  -- Update the mouse state.
  mouseLastRawY, mouseLast = mouseRawY, mousePos
end

-- Calculates distance-adaptive tolerance for hit detection
-- [rayPos - Camera ray position]
-- [targetPos - Position of the target (node/rib/bar)]
-- [targetType - 'node', 'rib', or 'bar' for different scaling]
local function getAdaptiveTolerance(rayPos, targetPos, targetType)
  local distance = rayPos:distance(targetPos)
  local visualScale = sqrt(distance) -- Scale the tolerance as distance increases.
  local typeScale = typeScales[targetType] -- Get the type-specific scaling.
  return baseHitScale * visualScale * typeScale
end

-- Sort function for hit candidates by priority and distance.
local function sortCandidatesByPriorityAndDistance(a, b)
  if candPriority[a] ~= candPriority[b] then
    return candPriority[a] < candPriority[b] -- Lower priority number = higher actual priority.
  end
  -- Co-located tip + junction centre: same ray depth. Prefer aux so the hub stays selectable.
  local distEps = 1e-3
  if abs(candDist[a] - candDist[b]) <= distEps then
    if candType[a] == 'aux' and candType[b] ~= 'aux' then return true end
    if candType[b] == 'aux' and candType[a] ~= 'aux' then return false end
  end
  return candDist[a] < candDist[b] -- Closer distance wins.
end

-- Aggregates splines from all tools into module-scope arrays for cross-tool hit detection.
-- [Returns the total number of splines collected.]
local function getAllSplines()
  table.clear(allSplines)
  table.clear(splineToolNames)
  local ctr = 1

  for i = 1, #registeredToolList do
    local tool = registeredToolList[i]
    local getSplines = tool.getSplines
    if getSplines then
      local splines = getSplines()
      if splines then
        for j = 1, #splines do
          allSplines[ctr], splineToolNames[ctr] = splines[j], tool.prefix
          ctr = ctr + 1
        end
      end
    end
  end

  return ctr
end

-- Optimized hit detection that prioritizes by distance to resolve selection conflicts.
-- Returns the best hit target based on closest distance to camera ray.
-- Always checks splines from all tools for cross-tool selection.
-- [SelSpline - The currently selected spline.]
-- [MousePos - The 3D mouse position.]
-- [UseRibs - Whether to check rib handles.]
-- [UseBars - Whether to check bar handles.]
local function getBestHitTarget(selSpline, mousePos, useRibs, useBars)
  -- Get the latest camera-to-mouse ray.
  local ray = getCameraMouseRay()
  local rayPos, rayDir = ray.pos, ray.dir

  -- Get all splines from all compatible tools.
  getAllSplines()

  -- Check nodes first (highest priority).
  table.clear(candType); table.clear(candDist); table.clear(candSplineIdx)
  table.clear(candNodeIdx); table.clear(candRibIdx); table.clear(candAuxIdx)
  table.clear(candIdxLower); table.clear(candPHit); table.clear(candPriority)
  local numSplines, ctr = #allSplines, 1
  for i = 1, numSplines do
    local spline = allSplines[i]
    if spline.isEnabled and not spline.isLink then
      local nodes = spline.nodes
      for j = 1, #nodes do
        local adaptiveTol = getAdaptiveTolerance(rayPos, nodes[j], 'node')
        local intA, intB = intersectsRay_Sphere(rayPos, rayDir, nodes[j], adaptiveTol)
        if intA and intB then
          local dist = min(intA, intB)
          if dist < intsctTol then
            -- Locked tips: priority 0. Free nodes: 1. Aux centres use -1 so a centre-sphere
            -- hit always beats a nearer linked tip (tips still win when the centre is not hit).
            local pri = isNodeLockedByTool(spline, j) and 0 or 1
            candType[ctr], candDist[ctr], candSplineIdx[ctr], candNodeIdx[ctr], candPriority[ctr] = 'node', dist, i, j, pri
            ctr = ctr + 1
          end
        end
      end
    end
  end

  -- Aux nodes (e.g. junction centres) — beat locked tips whenever the centre sphere is hit.
  local activeTool = getActiveTool()
  local auxNodes = activeTool and activeTool.getAuxNodes and activeTool.getAuxNodes() or nil
  if auxNodes then
    for j = 1, #auxNodes do
      local pos = auxNodes[j]
      if pos then
        local adaptiveTol = getAdaptiveTolerance(rayPos, pos, 'node')
        local intA, intB = intersectsRay_Sphere(rayPos, rayDir, pos, adaptiveTol)
        if intA and intB then
          local dist = min(intA, intB)
          if dist < intsctTol then
            candType[ctr], candDist[ctr], candAuxIdx[ctr], candPriority[ctr] = 'aux', dist, j, -1
            ctr = ctr + 1
          end
        end
      end
    end
  end

  -- Check ribs (width handles) - only for the selected spline.
  if useRibs and selSpline and selSpline.isEnabled and not selSpline.isLink then
    local ribPoints = selSpline.ribPoints
    if ribPoints then
      local numRibPoints = #ribPoints
      if numRibPoints > 0 then
        -- Find the selected spline index in allSplines array.
        local selSplineIdx = nil
        for i = 1, numSplines do
          if allSplines[i] == selSpline then
            selSplineIdx = i
            break
          end
        end
        if selSplineIdx then
          local isHalfSpline = selSpline.tileSet ~= nil or selSpline.spacing ~= nil -- Check if the spline is a half-spline.
          if isHalfSpline then -- For half-splines, only check even-indexed ribs.
            for j = 2, numRibPoints, 2 do
              local adaptiveTol = getAdaptiveTolerance(rayPos, ribPoints[j], 'rib')
              local intA, intB = intersectsRay_Sphere(rayPos, rayDir, ribPoints[j], adaptiveTol)
              if intA and intB then
                local dist = min(intA, intB)
                if dist < intsctTol then
                  candType[ctr], candDist[ctr], candSplineIdx[ctr], candRibIdx[ctr], candPriority[ctr] = 'rib', dist, selSplineIdx, j, 2
                  ctr = ctr + 1
                end
              end
            end
          else -- For full splines, check all rib points.
            for j = 1, numRibPoints do
              local adaptiveTol = getAdaptiveTolerance(rayPos, ribPoints[j], 'rib')
              local intA, intB = intersectsRay_Sphere(rayPos, rayDir, ribPoints[j], adaptiveTol)
              if intA and intB then
                local dist = min(intA, intB)
                if dist < intsctTol then
                  candType[ctr], candDist[ctr], candSplineIdx[ctr], candRibIdx[ctr], candPriority[ctr] = 'rib', dist, selSplineIdx, j, 2
                  ctr = ctr + 1
                end
              end
            end
          end
        end
      end
    end
  end

  -- Check bars (height handles) - only for the selected spline.
  if useBars and selSpline and selSpline.isEnabled and not selSpline.isLink then
    local barPoints = selSpline.barPoints
    if barPoints then
      local numBarPoints = #barPoints
      if numBarPoints > 0 then
        -- Find the selected spline index in allSplines array.
        local selSplineIdx = nil
        for i = 1, numSplines do
          if allSplines[i] == selSpline then
            selSplineIdx = i
            break
          end
        end
        if selSplineIdx then
          for j = 1, numBarPoints do
            local adaptiveTol = getAdaptiveTolerance(rayPos, barPoints[j], 'bar')
            local intA, intB = intersectsRay_Sphere(rayPos, rayDir, barPoints[j], adaptiveTol)
            if intA and intB then
              local dist = min(intA, intB)
              if dist < intsctTol then
                candType[ctr], candDist[ctr], candSplineIdx[ctr], candNodeIdx[ctr], candPriority[ctr] = 'bar', dist, selSplineIdx, j, 3
                ctr = ctr + 1
              end
            end
          end
        end
      end
    end
  end

  -- Check spline for node insertion (only for selected spline).
  if selSpline and selSpline.isEnabled and not selSpline.isLink then
    local isOverSpline, idxLower, pHit = geom.isMouseOverSpline(selSpline)
    if isOverSpline and pHit then
      candType[ctr], candDist[ctr], candIdxLower[ctr], candPHit[ctr], candPriority[ctr] = 'spline', pHit:distance(rayPos), idxLower, pHit, 4
      ctr = ctr + 1
    end
  end

  -- Early return if no candidates were found.
  if ctr == 1 then
    return nil
  end

  -- Build indices array for sorting.
  local numCandidates = ctr - 1
  table.clear(hitCandidates)  -- Clear any stale indices from previous frames.
  for i = 1, numCandidates do
    hitCandidates[i] = i
  end

  -- Sort indices by priority first, then by distance.
  table.sort(hitCandidates, sortCandidatesByPriorityAndDistance)

  -- Return best candidate.
  local bestIdx = hitCandidates[1]
  tmpTable.type = candType[bestIdx]
  tmpTable.dist = candDist[bestIdx]
  tmpTable.splineIdx = candSplineIdx[bestIdx]
  tmpTable.nodeIdx = candNodeIdx[bestIdx]
  tmpTable.ribIdx = candRibIdx[bestIdx]
  tmpTable.auxIdx = candAuxIdx[bestIdx]
  tmpTable.idxLower = candIdxLower[bestIdx]
  tmpTable.pHit = candPHit[bestIdx]
  tmpTable.priority = candPriority[bestIdx]

  -- Include tool information for cross-tool detection.
  if bestIdx and candSplineIdx[bestIdx] then
    tmpTable.toolName = splineToolNames[candSplineIdx[bestIdx]]
  else
    tmpTable.toolName = nil
  end

  return tmpTable
end


-- Registers a spline-editing tool for use with the shared spline input utilities.
-- [prefix]           - Tool display prefix (from splineMgr.getToolPrefixStr()).
-- [getSplinesFn]     - Function returning the tool's spline array.
-- [getEditModeKeyFn] - Function returning the editor editMode key for this tool.
-- [deepCopyFn]       - Function deep-copying a single spline.
-- [deepCopyStateFn]  - Function deep-copying the full spline tool state.
-- [uiModuleName]     - Name of the UI module (e.g. 'editor_meshSpline').
-- [getAuxNodesFn]    - Optional: returns extra selectable node positions (vec3 array), same hit rules as road nodes.
-- [isNodeLockedFn]   - Optional: isNodeLockedFn(spline, nodeIdx) → true to allow select but not drag/gizmo/delete.
local function registerSplineTool(prefix, getSplinesFn, getEditModeKeyFn, deepCopyFn, deepCopyStateFn, uiModuleName, getAuxNodesFn, isNodeLockedFn)
  if not prefix then
    return
  end
  -- Hot-reload: update callbacks on an existing registration.
  local existing = registeredTools[prefix]
  if existing then
    existing.getSplines = getSplinesFn or existing.getSplines
    existing.getEditModeKey = getEditModeKeyFn or existing.getEditModeKey
    existing.deepCopySpline = deepCopyFn or existing.deepCopySpline
    existing.deepCopyState = deepCopyStateFn or existing.deepCopyState
    existing.uiModuleName = uiModuleName or existing.uiModuleName
    existing.getAuxNodes = getAuxNodesFn
    existing.isNodeLocked = isNodeLockedFn
    return
  end
  local tool = {
    prefix = prefix,
    getSplines = getSplinesFn,
    getEditModeKey = getEditModeKeyFn,
    deepCopySpline = deepCopyFn,
    deepCopyState = deepCopyStateFn,
    uiModuleName = uiModuleName,
    getAuxNodes = getAuxNodesFn,
    isNodeLocked = isNodeLockedFn,
  }
  registeredTools[prefix] = tool
  registeredToolList[#registeredToolList + 1] = tool
end


-- Handles the user input events for spline-editing tools.
-- Splines are user-editable polylines along the centerline of a variable width. They can be used to create roads, paths, etc.
-- [Splines - The collection of splines to handle events for.]
-- [Out - A table which contains the following common fields (will be updated as the user interacts with the splines):]
  -- [SelSplineIdx - The index of the selected spline.]
  -- [SelNodeIdx - The index of the selected node.]
  -- [SelLayerIdx - The index of the selected layer. NOTE: This is only used for the 'decal placement' case.]
  -- [IsGizmoActive - A flag which indicates whether the gizmo is active.]
-- [IsRotEnabled - A flag which indicates whether the rotation gizmo is enabled.]
-- [IsConformToTerrain - A flag which indicates whether the spline should be conform to the surface below, or not. Used for vertical gizmo control.]
-- [UseRibs - A flag which indicates whether to use ribs (handles for width adjustment).]
-- [UseBars - A flag which indicates whether to use bars (handles for height adjustment).]
-- [IsBarsLimits - A flag which indicates whether the bars are limits (true) or velocities (false).]
-- [UseCopyPaste - A flag which indicates whether to use the copy/paste profile feature.]
-- [UseGizmo - A flag which indicates whether to use gizmo.]
-- [IsLockShape - A flag which indicates whether the shape of the spline is locked, or not.]
-- [DefaultSplineWidth - The default width for a spline when adding a new node, in meters.]
-- [DeepCopyFunct - A function which deep copies a spline.]
-- [DeepCopyStateFunct - A function which deep copies the state of a spline.]
-- [CopyProfileFunct - A function which copies a profile.]
-- [PasteProfileFunct - A function which pastes a profile.]
-- [RibStartDragCallback - A function which is called when the user starts dragging a rib.]
-- [AfterEndDragCallback - A function which is called when the user ends dragging.]
-- [JoinFunct - A function which is called when the user forms a join.]
-- [UndoFunct - The undo callback function for a single spline edit.]
-- [RedoFunct - The redo callback function for a single spline edit.]
-- [UndoStateFunct - The undo callback function for the full spline state edit.]
-- [RedoStateFunct - The redo callback function for the full spline state edit.]
local function handleSplineEvents(
  splines, out,
  isRotEnabled, isConformToTerrain, useRibs, useBars, isBarsLimits, useCopyPaste, useGizmo, isLockShape,
  defaultSplineWidth,
  deepCopyFunct, deepCopyStateFunct, copyProfileFunct, pasteProfileFunct, afterEndDragCallback, joinFunct,
  undoFunct, redoFunct, undoStateFunct, redoStateFunct, midJoinFunct, canJoinFunct, canJoinAuxFunct)

  -- Update the mouse position and velocity.
  local mousePos = util.mouseOnMapPos()
  local mouseRawY = im.GetMousePos().y
  mouseVel2D:set(mousePos.x - mouseLast.x, mousePos.y - mouseLast.y, 0.0)
  local isShiftDown, isAltDown, isCtrlDown = im.IsKeyDown(shiftKeyIdx), im.IsKeyDown(altKeyIdx), im.IsKeyDown(ctrlKeyIdx)
  local isCDown, isVDown, isDelDown = im.IsKeyDown(cKeyIdx), im.IsKeyDown(vKeyIdx), im.IsKeyDown(delKeyIdx)

  -- Manage the rest timer.
  if mouseVel2D:squaredLength() > isMouseMoveTolSq then
    restTime = timeUntilTextAppears
  end

  -- Get the selected spline (may be nil if no splines or invalid selection).
  local selSpline = splines[out.spline]

  -- Finalize drag on mouse-up even if the cursor left the terrain (ImGui / sky).
  if dragStatePre and not im.IsMouseDown(0) then
    local joinHandled = handleEndDragEvents(splines, selSpline, deepCopyFunct, deepCopyStateFunct, joinFunct, undoFunct, redoFunct, undoStateFunct, redoStateFunct, afterEndDragCallback, isShiftDown, midJoinFunct)
    if joinHandled then return end
  end

  -- Scene-only events (when mouse is hovering over the terrain).
  if util.isMouseHoveringOverTerrain() then
    -- Draw the mouse cursor (inactive if no selection or selected spline disabled) and show appropriate delayed markup.
    local isActive = selSpline ~= nil and selSpline.isEnabled == true
    render.drawSphereCursor(mousePos, isActive)
    if restTime < 0.0 then
      if selSpline and not selSpline.isEnabled then
        render.markupSelectedSplineDisabled(mousePos)
      elseif not selSpline then
        render.markupSelectOrAdd(mousePos)
      end
    end

    -- Handle active dragging events.
    if isDragAux and dragAuxIdx then
      local tool = getActiveTool()
      local auxNodes = tool and tool.getAuxNodes and tool.getAuxNodes() or nil
      local pos = auxNodes and auxNodes[dragAuxIdx]
      if pos then
        -- Offset drag (same as road nodes) — never snap-teleport the centre to the cursor.
        local offset = mousePos - mouseLast
        pos.x, pos.y = pos.x + offset.x, pos.y + offset.y
        out.aux = dragAuxIdx
      end
      mouseLast, mouseLastRawY = mousePos, mouseRawY
      return
    end
    if dragSplineIdx then
      if isDragBar then -- User is dragging a bar.
        handleBarDragging(selSpline, mouseRawY, isBarsLimits, isLockShape, isShiftDown)
      elseif isDragRib then -- User is dragging a rib.
        handleRibDragging(selSpline, isLockShape, isShiftDown)
      else -- User is dragging a node.
        handleNodeDragging(splines, out, mousePos, isLockShape, midJoinFunct, canJoinFunct, canJoinAuxFunct)
      end
      mouseLast, mouseLastRawY = mousePos, mouseRawY
      return -- Early return if currently dragging.
    end

    -- Handle 'add node' and 'start dragging' events.
    local bestHit = getBestHitTarget(selSpline, mousePos, useRibs, useBars)
    if bestHit then
      local bestHitType = bestHit.type
      if bestHitType == 'aux' then -- Aux nodes (junction centres, etc.) — same hover/select as road nodes.
        local tool = getActiveTool()
        local auxNodes = tool and tool.getAuxNodes and tool.getAuxNodes() or nil
        local auxIdx = bestHit.auxIdx
        local pos = auxNodes and auxNodes[auxIdx]
        if pos then
          render.drawSphereHighlightHover(pos)
          if not im.IsMouseDown(0) and markupTime < 0.0 then
            render.markupDrag(pos)
          end
          if im.IsMouseClicked(0) then
            out.aux = auxIdx
            -- Select-only when tool locks drag (e.g. force field owns soft-select).
            if deepCopyStateFunct and not isNodeLockedByTool(nil, 0) then
              dragStatePre = deepCopyStateFunct()
              isDragAux, dragAuxIdx = true, auxIdx
              mouseLast = mousePos
            end
          end
        end
      elseif bestHitType == 'node' then -- 'Hover-Over-Node' events.
        local hoverSplineIdx, hoverNodeIdx = bestHit.splineIdx, bestHit.nodeIdx

        -- Check if this is a cross-tool hit (from another spline tool).
        if bestHit.toolName and bestHit.toolName ~= editor.editMode.displayName then
          local targetSpline = allSplines[hoverSplineIdx]
          local tool = bestHit.toolName and registeredTools[bestHit.toolName] or nil
          if targetSpline and targetSpline.isEnabled and tool then
            render.drawSphereHighlightHover(targetSpline.nodes[hoverNodeIdx])
            render.markupSelectSpline(targetSpline.nodes[hoverNodeIdx]) -- Show selection prompt.
            if im.IsMouseClicked(0) then -- Only switch tools on click, not hover.
              local getSplinesFn = tool.getSplines
              local getModeKeyFn = tool.getEditModeKey
              if getSplinesFn and getModeKeyFn then
                local modeKey = getModeKeyFn() -- Call the function to get the actual mode key
                local targetSplines = getSplinesFn()
                if targetSplines and modeKey then
                  local actualSplineIdx = nil -- Find the actual index within the target tool's splines.
                  for i = 1, #targetSplines do
                    if targetSplines[i] == targetSpline then
                      actualSplineIdx = i
                      break
                    end
                  end
                  if actualSplineIdx then
                    editor.selectEditMode(editor.editModes[modeKey])
                    local uiModuleName = tool.uiModuleName
                    local toolUIModule = uiModuleName and extensions[uiModuleName] or nil -- Get the UI module of the tool which is being switched to.
                    if toolUIModule and toolUIModule.setSelectedSplineIdx and toolUIModule.setSelectedNodeIdx then
                      toolUIModule.setSelectedSplineIdx(actualSplineIdx) -- Set the selected spline index in the tool.
                      toolUIModule.setSelectedNodeIdx(hoverNodeIdx) -- Set the selected node index in the tool.
                    end
                    if not targetSpline.isLink then -- Initialise drag state only if the spline is not linked.
                      local targetDeepCopyFn = tool.deepCopySpline
                      if targetDeepCopyFn then
                        dragStatePre = targetDeepCopyFn(targetSplines[actualSplineIdx])
                        isDragRib, dragSplineIdx, dragNodeIdx = false, actualSplineIdx, hoverNodeIdx
                        dragTipKind = tipKindForNode(targetSpline.nodes, hoverNodeIdx)
                        mouseLast = mousePos
                      end
                    end
                  end
                end
              end
            end
          end
          return -- Don't process further in this frame.
        end

        -- Regular same-tool hit detection.
        -- Convert allSplines index to current tool's splines index.
        local targetSpline = allSplines[hoverSplineIdx]
        local actualSplineIdx = nil
        for i = 1, #splines do
          if splines[i] == targetSpline then
            actualSplineIdx = i
            break
          end
        end

        if actualSplineIdx and splines[actualSplineIdx].isEnabled then
          local actualHoverSplineIdx = actualSplineIdx
          local hoverSpline = splines[actualHoverSplineIdx]
          local nodeLocked = isNodeLockedByTool(hoverSpline, hoverNodeIdx)
          render.drawSphereHighlightHover(hoverSpline.nodes[hoverNodeIdx])
          if actualHoverSplineIdx ~= out.spline then
            render.markupSelectSpline(hoverSpline.nodes[hoverNodeIdx])
          elseif not dragSplineIdx and not im.IsMouseDown(0) and markupTime < 0.0 then
            if nodeLocked then
              render.markupLinkedTip(hoverSpline.nodes[hoverNodeIdx])
            else
              render.markupDrag(hoverSpline.nodes[hoverNodeIdx])
            end
          end
          if im.IsMouseClicked(0) then
              out.spline, out.node, out.aux = actualHoverSplineIdx, hoverNodeIdx, nil
              -- Select only when Master-Spline linked or junction-tip locked.
              if not hoverSpline.isLink and not nodeLocked then
                dragStatePre = deepCopyFunct(hoverSpline)
                isDragRib, dragSplineIdx, dragNodeIdx = false, actualHoverSplineIdx, hoverNodeIdx
                dragTipKind = tipKindForNode(hoverSpline.nodes, hoverNodeIdx)
              end
          end
        end
      elseif bestHitType == 'rib' then -- 'Hover-Over-Rib' events.
        -- Rib hit detection (ribs are only shown for selected spline in current tool).
        local ribSplineIdx, ribIdx = bestHit.splineIdx, bestHit.ribIdx
        local spline = allSplines[ribSplineIdx] -- Use allSplines index, not current tool's splines
        if spline and spline.isEnabled then
          local ribPts = spline.ribPoints
          render.drawSphereHighlightHover(ribPts[ribIdx])
          local isHalfSpline = spline.tileSet ~= nil or spline.spacing ~= nil -- Check if the spline is a half-spline.
          if not isHalfSpline then
            local idx2 = ribIdx % 2 == 0 and ribIdx - 1 or ribIdx + 1
            render.drawSphereHighlightHover(ribPts[idx2]) -- Only highlight the odd rib if we have a full spline.
          end
          if not dragSplineIdx then
            render.markupAdjustWidth(ribPts[ribIdx])
          end
          if im.IsMouseClicked(0) then
            local nodeIdx = ceil(ribIdx * 0.5)
            -- Only allow rib dragging if the spline is not linked.
            if not spline.isLink then
              dragStatePre = deepCopyFunct(spline)
              isDragRib, dragSplineIdx, dragNodeIdx = true, out.spline, nodeIdx
              dragTipKind = tipKindForNode(spline.nodes, nodeIdx)
              dragRibIsFirstHandle = ribIdx % 2 == 0
              mouseLastRawY = mouseRawY
              out.node = nodeIdx
            end
            mouseLast = mousePos
            return
          end
        end
      elseif bestHitType == 'bar' then -- 'Hover-Over-Bar' events.
        -- Bar hit detection (bars are only shown for selected spline in current tool).
        local barSplineIdx, barNodeIdx = bestHit.splineIdx, bestHit.nodeIdx
        local spline = allSplines[barSplineIdx] -- Use allSplines index, not current tool's splines
        if spline and spline.isEnabled then
          local barPts = spline.barPoints
          render.drawSphereHighlightHover(barPts[barNodeIdx])
          if not dragSplineIdx then
            render.markupAdjustBar(barPts[barNodeIdx])
          end
          if im.IsMouseClicked(0) then
            if not spline.isLink then -- Only allow bar dragging if the spline is not linked.
              dragStatePre = deepCopyFunct(spline)
              isDragBar, dragSplineIdx, dragNodeIdx = true, out.spline, barNodeIdx
              mouseLastRawY = mouseRawY
              out.node = barNodeIdx
            end
            mouseLast = mousePos
            return
          end
        end
      elseif bestHitType == 'spline' then -- 'Hover-Over-Spline' events.
        if selSpline and selSpline.isEnabled and not selSpline.isLink then
          local idxLower, pHit = bestHit.idxLower, bestHit.pHit
          render.drawSphereHighlightHover(pHit)
          render.drawSphereNode(pHit)
          if not dragSplineIdx and not im.IsMouseDown(0) and markupTime < 0.0 then
            render.markupInsertNode(pHit)
          end
          if im.IsMouseClicked(0) then
            local splinePre = deepCopyFunct(selSpline)
            local tableIdx = idxLower + 1
            table.insert(selSpline.nodes, tableIdx, vec3(pHit))
            local widths, nmls = selSpline.widths, selSpline.nmls
            local isLoop = selSpline.isLoop
            local n = #widths
            local iPrev = tableIdx - 1
            local iNext = tableIdx
            if isLoop then
              iPrev, iNext = ((iPrev - 1) % n) + 1, ((iNext - 1) % n) + 1
            end
            local lerpWidth = (widths[iPrev] + widths[iNext]) * 0.5
            table.insert(widths, tableIdx, lerpWidth)
            local lerpNormal = lerp(nmls[iPrev], nmls[iNext], 0.5)
            table.insert(nmls, tableIdx, lerpNormal)
            if useBars then
              local vels, velLimits = selSpline.vels, selSpline.velLimits
              local lerpVel = (vels[iPrev] + vels[iNext]) * 0.5
              local lerpVelLimit = (velLimits[iPrev] + velLimits[iNext]) * 0.5
              table.insert(vels, tableIdx, lerpVel)
              table.insert(velLimits, tableIdx, lerpVelLimit)
            end
            out.node = tableIdx
            markupTime = timeUntilTextAppears
            selSpline.isDirty = true
            editor.history:commitAction("Insert Node", { old = splinePre, new = deepCopyFunct(selSpline) }, undoFunct, redoFunct)
          end
        end
      end
    else -- 'Hover-Over-Free-Space' events.
      if selSpline and selSpline.isEnabled then
        if restTime < 0.0 then
          if selSpline.isLink then
            render.markupLinkedSplineCannotAdd(mousePos)
          elseif selSpline.isLoop then
            render.markupLoopedSplineCannotAdd(mousePos)
          else
            render.markupAddNode(mousePos)
          end
        end
        if im.IsMouseClicked(0) and not selSpline.isLoop and not selSpline.isLink then
          local statePre = deepCopyFunct(selSpline)
          local selNodes, selWidths, selNmls, selVels, selVelLimits = selSpline.nodes, selSpline.widths, selSpline.nmls, selSpline.vels, selSpline.velLimits
          if #selNodes > 1 then
            if mousePos:squaredDistance(selNodes[1]) < mousePos:squaredDistance(selNodes[#selNodes]) then
              table.insert(selNodes, 1, vec3(mousePos))
              table.insert(selWidths, 1, selWidths[1])
              table.insert(selNmls, 1, vec3(selNmls[1] or globalUp))
              if useBars then
                table.insert(selVels, 1, selVels[1])
                table.insert(selVelLimits, 1, selVelLimits[1])
              end
              out.node = 1
            else
              table.insert(selNodes, vec3(mousePos))
              table.insert(selWidths, selWidths[#selWidths])
              table.insert(selNmls, vec3(selNmls[#selNmls]))
              if useBars then
                table.insert(selVels, selVels[#selVels])
                table.insert(selVelLimits, selVelLimits[#selVelLimits])
              end
              out.node = #selNodes
            end
          else
            selNodes[#selNodes + 1] = vec3(mousePos)
            table.insert(selWidths, #selWidths > 0 and selWidths[#selWidths] or defaultSplineWidth)
            table.insert(selNmls, vec3(selNmls[#selNmls] or globalUp))
            if useBars then
              table.insert(selVels, selVels[#selVels] or defaultSplineVel)
              table.insert(selVelLimits, selVelLimits[#selVelLimits] or defaultSplineVelLimit)
            end
            out.node = #selNodes
          end
          out.aux = nil
          markupTime = timeUntilTextAppears
          selSpline.isDirty = true
          editor.history:commitAction("Add Node", { old = statePre, new = deepCopyFunct(selSpline) }, undoFunct, redoFunct, true)
        end
      end
    end
  end

  -- Handle node deletion using the delete key.
  if selSpline and not selSpline.isLink and selSpline.isEnabled then
    if isDelDown then
      if not hasDeletePressedRecently and out.node > 0 and out.node <= #selSpline.nodes
          and not isNodeLockedByTool(selSpline, out.node) then
        local splinePre = deepCopyFunct(selSpline)
        table.remove(selSpline.nodes, out.node)
        table.remove(selSpline.widths, out.node)
        table.remove(selSpline.nmls, out.node)
        out.node = max(1, min(#selSpline.nodes, out.node))
        selSpline.isDirty = true
        editor.history:commitAction("Delete Node", { old = splinePre, new = deepCopyFunct(selSpline) }, undoFunct, redoFunct, true)
        hasDeletePressedRecently = true
      end
    else
      hasDeletePressedRecently = false -- Only allows one time use of the delete key.
    end
  end

  -- If requested, manage the ALT key for toggling the gizmo on/off.
  if useGizmo then
    if isAltDown and isAltDown ~= lastAltDown then
      out.isGizmoActive = not out.isGizmoActive
    end
    if out.isGizmoActive and not isNodeLockedByTool(selSpline, out.node) then
      gizmo.handleGizmo(isRotEnabled, out.spline, out.node, splines, isConformToTerrain, isLockShape, deepCopyFunct, undoFunct, redoFunct)
    end
    lastAltDown = isAltDown
  end

  -- Check if the user is attempting to copy/paste a profile.
  if useCopyPaste then
    if isCtrlDown and isCDown and out.spline then
      ctrlCProfile = copyProfileFunct(splines[out.spline])
    end
    if isCtrlDown and isVDown and ctrlCProfile and out.spline and not hasPastePressedRecently then
      local splinePre = deepCopyFunct(splines[out.spline])
      pasteProfileFunct(splines[out.spline], ctrlCProfile)
      editor.history:commitAction("Paste Profile", { old = splinePre, new = deepCopyFunct(splines[out.spline]) }, undoFunct, redoFunct, true)
      hasPastePressedRecently = true
    end
    if not isVDown then
      hasPastePressedRecently = false -- Only allows one time use of the paste key.
    end
  end

  -- Update timers and mouse state.
  updateTimersAndMouseState(mouseRawY, mousePos)
end

-- Handles the user input events for spline-editing tools.
-- Splines are user-editable polylines along the centerline of a variable width. They can be used to create roads, paths, etc.
-- [SelSpline - The selected spline.]
-- [Nodes - The collection of navigation graph nodes to handle events for.]
-- [DeepCopyFunct - A function which deep copies a spline.]
-- [UndoFunct - The undo callback function for a single spline edit.]
-- [RedoFunct - The redo callback function for a single spline edit.]
-- [isBarsLimit - Whether to use velLimits (true) or vels (false) for bar heights.]
-- [useBars - Whether to allow bar interactions (defaults to true).]
local function handleNavGraphEvents(selSpline, nodes, deepCopyFunct, undoFunct, redoFunct, isBarsLimit, useBars)
  if useBars == nil then
    useBars = true
  end
  -- Update the mouse position and velocity, and cache the current mouse state.
  local mouseRawY = im.GetMousePos().y -- The current raw mouse y-position (2D).
  local mousePos = util.mouseOnMapPos() -- The current mouse position on the map (3D).
  mouseVel2D:set(mousePos.x - mouseLast.x, mousePos.y - mouseLast.y, 0.0) -- The 2D mouse velocity (XY).
  if mouseVel2D:squaredLength() > isMouseMoveTolSq then
    restTime = timeUntilTextAppears -- Reset the rest time when the mouse is moving.
  end

  -- Scene-only events (when mouse is hovering over the terrain).
  if util.isMouseHoveringOverTerrain() then
    -- Draw the mouse cursor (inactive when no selection).
    render.drawSphereCursor(mousePos, selSpline ~= nil)

    -- Handle 'end bar drag' events.
    if not im.IsMouseDown(0) then
      if dragStatePre then
        editor.history:commitAction("Drag Bar", { old = dragStatePre, new = deepCopyFunct(selSpline) }, undoFunct, redoFunct, true)
        dragStatePre = nil
      end
      isDragBar, dragNodeIdx = nil, nil
    end

    -- Handle any active bar dragging events.
    if isDragBar and useBars then
      local vals = isBarsLimit and selSpline.velLimits or selSpline.vels -- The velocities of the spline nodes.
      if not vals then
        vals = selSpline.vels
      end
      if not vals or #vals == 0 then
        vals = {}
        for i = 1, #selSpline.barPoints do
          vals[i] = defaultSplineVel
        end
        if isBarsLimit then
          selSpline.velLimits = vals
        else
          selSpline.vels = vals
        end
      end
      local delta = (mouseLastRawY - mouseRawY) * heightSensitivity -- The vertical mouse velocity.
      vals[dragNodeIdx] = max(minSplineHeight, min(maxSplineHeight, vals[dragNodeIdx] + delta)) -- Move bar of the selected node by rel. amount.
      selSpline.isDirty = true
    elseif isDragBar and not useBars then
      isDragBar, dragNodeIdx = nil, nil
    end

    -- Handle 'add node' and 'start dragging' events.
    local isMouseOverHandle = false
    local isOverNode, hoverNodeKey = geom.isMouseOverGraphNode(nodes)
    isMouseOverHandle = isMouseOverHandle or isOverNode
    if isOverNode then -- 'Hover-Over-Node' events.
      render.drawSphereHighlight(nodes[hoverNodeKey]) -- Draw a highlight when the mouse is over a graph node.
      if not im.IsMouseDown(0) and markupTime < 0.0 then
        render.markupGraphNodeHover(nodes[hoverNodeKey]) -- Draw a special markup when the mouse is over a graph node.
      end
      if im.IsMouseClicked(0) then
        local statePre = deepCopyFunct(selSpline)
        local doesContain, idx = util.doesPathContainNode(selSpline.graphNodes, hoverNodeKey)
        if doesContain then
          table.remove(selSpline.graphNodes, idx) -- Path contains the node already, so remove it.
          table.remove(selSpline.vels, idx) -- Remove the velocity for the node.
          if selSpline.velLimits then
            table.remove(selSpline.velLimits, idx) -- Remove the velocity limit for the node.
          end
        else
          table.insert(selSpline.graphNodes, hoverNodeKey) -- Path does not contain the node, so add it (to end).
          table.insert(selSpline.vels, defaultSplineVel) -- Add a default velocity for the new node.
          if selSpline.velLimits then
            table.insert(selSpline.velLimits, defaultSplineVel) -- Add a default velocity limit for the new node.
          end
        end
        if useBars then
          -- Immediately update barPoints to match the new graphNodes array.
          local graphData = { nodes = nodes }
          geom.updateBarPointsGraph(selSpline, graphData, isBarsLimit)
        else
          table.clear(selSpline.barPoints)
        end
        selSpline.isDirty = true
        editor.history:commitAction("Change Path", { old = statePre, new = deepCopyFunct(selSpline) }, undoFunct, redoFunct)
        markupTime = timeUntilTextAppears
      end
    else -- Not over a node.
      if useBars then
        tmpTable[1] = selSpline
        local isOverBar, _, barNodeIdx = geom.isMouseOverBar(tmpTable)
        isMouseOverHandle = isMouseOverHandle or isOverBar
        if isOverBar then -- 'Hover-Over-Bar' events.
          local barPts = selSpline.barPoints
          render.drawSphereHighlightHover(barPts[barNodeIdx]) -- Pulsing highlight (same as ribs).
          if not dragSplineIdx then
            render.markupAdjustBar(barPts[barNodeIdx]) -- Markup when the mouse is over a bar.
          end
          if im.IsMouseClicked(0) then
            dragStatePre = deepCopyFunct(selSpline)
            isDragBar, dragNodeIdx = true, barNodeIdx
            mouseLastRawY = mouseRawY
            mouseLast = mousePos
            return
          end
        else -- 'Hover-Over-Free-Space' events.
          if restTime < 0.0 and not isMouseOverHandle then
            render.markupGraphFreeSpace(mousePos) -- Markup when the mouse is over free space.
          end
        end
      else
        if restTime < 0.0 and not isMouseOverHandle then
          render.markupGraphFreeSpace(mousePos) -- Markup when the mouse is over free space.
        end
      end
    end
  end

  -- Manage the markup event timers.
  -- [Timers run from some positive value when set, then decrement beyond zero. Events are triggered when the timers drop below zero.]
  local deltaTime = markupTimer:stopAndReset() * 0.001
  markupTime = markupTime > deltaTime and markupTime - deltaTime or -1.0
  local restDelta = restTimer:stopAndReset() * 0.001
  restTime = restTime > restDelta and restTime - restDelta or -1.0

  -- Update the mouse position data.
  mouseLast, mouseLastRawY = mousePos, mouseRawY
end


-- Public interface.
M.handleSplineEvents =                                  handleSplineEvents
M.handleNavGraphEvents =                                handleNavGraphEvents
M.registerSplineTool =                                  registerSplineTool
M.isDragging =                                          isDragging

return M