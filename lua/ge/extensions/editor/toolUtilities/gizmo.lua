-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This is a utility module to manage the gizmo for various spline-editing tools.

local M = {}

-- Module constants.
local min, max = math.min, math.max
local zeroQuatF = QuatF(0, 0, 0, 1)

-- Module state.
local splines = nil -- The array of splines to control.
local deepCopyFunct = nil -- The cached function which deep copies the state of a spline.
local undoFunct, redoFunct = nil, nil -- The cached undo and redo callback functions.
local gizmoDragPre = nil -- State to store the spline before the gizmo drag begins.
local splineIdx, nodeIdx = nil, nil -- The cached index of the selected spline and node.
local isRotEnabled = false -- A flag which indicates if the rotation gizmo is enabled.
local isConformToTerrain = false -- A flag which indicates if the controlled spline should conform to the surface below, or not.
local isRigid = false -- A flag which indicates if the controlled spline should have rigid translation, or not
local beginDragRot = nil
local isDragActive = false -- True between gizmoBeginDrag and gizmoEndDrag; lets tools defer heavy rebuilds during a gizmo drag.
local commitHistoryOverride = nil -- Allows the owning spline tool to group this drag into a broader history action.
local delta, tmpTan = vec3(), vec3()
local tmpQuatF = QuatF(0, 0, 0, 1)
local lastGizmoMode = nil -- Track the last gizmo mode to detect changes
local anchorPos = nil
local dragOffset = vec3()  -- (anchor - node) captured at drag-begin, so gizmoPos - dragOffset is the node's new position.
local tmpNew = vec3()      -- scratch: the node's new position during a translate drag.


-- The callback function for begin axis gizmo dragging.
local function gizmoBeginDrag()
  isDragActive = true
  local spline = splines[splineIdx]
  gizmoDragPre = deepCopyFunct(spline) -- Store the spline state upon beginning the drag.

  -- Lock in the anchor->node offset so translation follows the cursor as a delta (gizmo drawn at the anchor, node trails by this).
  if anchorPos then dragOffset:setSub2(anchorPos, spline.nodes[nodeIdx]) else dragOffset:set(0, 0, 0) end

  if isRotEnabled then
    local nodes = spline.nodes
    local p1, p2 = nodes[max(1, nodeIdx - 1)], nodes[min(#nodes, nodeIdx + 1)]
    tmpTan:setSub2(p2, p1)
    tmpTan:normalize()
    beginDragRot = quatFromDir(tmpTan, spline.nmls[nodeIdx])
  end
end

-- The callback function for end axis gizmo dragging.
local function gizmoEndDrag()
  if commitHistoryOverride then
    commitHistoryOverride("Gizmo Drag", { old = gizmoDragPre, new = deepCopyFunct(splines[splineIdx]) }, undoFunct, redoFunct, true)
  else
    editor.history:commitAction("Gizmo Drag", { old = gizmoDragPre, new = deepCopyFunct(splines[splineIdx]) }, undoFunct, redoFunct, true)
  end
  beginDragRot = nil
  isDragActive = false
  -- Re-flag dirty on release: gizmoDragging only sets isDirty on frames the axis actually moves, so the final
  -- release frame leaves nothing for the tool's dirty pipeline to pick up. Deferred-while-dragging rebuilds (e.g.
  -- bridge deck remesh) then never run against the final position until the node is touched again. Marking here
  -- mirrors the mouse-drag end path so the last edit always rebuilds.
  local spline = splines[splineIdx]
  if spline then spline.isDirty = true end
end

-- The callback function for handling dragging of the gizmo.
local function gizmoDragging()
  -- Handle the gizmo for translation.
  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate and splineIdx > 0 and splineIdx <= #splines then
    local spline = splines[splineIdx]
    local nodes = spline.nodes
    local selNode = nodes[nodeIdx]
    local gizmoPos = editor.getAxisGizmoTransform():getColumn(3) -- Update the node position to where the gizmo is.
    tmpNew:setSub2(gizmoPos, dragOffset) -- the node's target (== gizmoPos when there's no display anchor, dragOffset = 0).
    if isRigid then
      delta:setSub2(tmpNew, selNode)
      for i = 1, #nodes do
        nodes[i]:setAdd(delta)
      end
    else
      selNode:set(tmpNew)
    end
    spline.isDirty = true -- Mark the spline as dirty to trigger a re-render.
  end

  -- Handle the gizmo for rotation.
  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then
    local spline = splines[splineIdx]
    local rotMat = editor.getAxisGizmoTransform()
    tmpQuatF:setFromMatrix(rotMat)
    local q = nil
    if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
      q = quat(tmpQuatF)
    else
      q = beginDragRot * quat(tmpQuatF)
    end
    local _, up = q:toDirUp()
    if isRigid then
      for i = 1, #spline.nodes do
        spline.nmls[i] = vec3(up)
      end
    else
      spline.nmls[nodeIdx] = vec3(up)
    end
    spline.isDirty = true
  end
end

-- Handles the gizmo for translation.
local function handleGizmo(isRotEnabledIn, selectedSplineIdx, selectedNodeIdx, splinesIn, isConformToTerrainIn, isRigidIn, deepCopyFunctIn, undoFunctIn, redoFunctIn, commitHistoryOverrideIn, anchorPosIn)
  splines, splineIdx, nodeIdx = splinesIn, selectedSplineIdx, selectedNodeIdx -- Keep the spline/node target in state.
  isRotEnabled, isConformToTerrain, isRigid = isRotEnabledIn, isConformToTerrainIn, isRigidIn
  deepCopyFunct, undoFunct, redoFunct =deepCopyFunctIn, undoFunctIn, redoFunctIn -- Keep the relevant callback functions in state.
  commitHistoryOverride = commitHistoryOverrideIn
  anchorPos = anchorPosIn -- optional DISPLAY position (drawn here instead of on the node); nil = on the node.
  if #splines > 0 then
    local spline = splines[selectedSplineIdx]
    local nodes = spline.nodes
    local selNode = nodes[nodeIdx]
    if selNode then
      -- Compute and set the gizmo transform.
      local rotation = zeroQuatF
      if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
        local p1, p2 = nodes[max(1, nodeIdx - 1)], nodes[min(#nodes, nodeIdx + 1)]
        tmpTan:setSub2(p2, p1)
        tmpTan:normalize()
        local q = quatFromDir(tmpTan, spline.nmls[nodeIdx])
        rotation.x, rotation.y, rotation.z, rotation.w = q.x, q.y, q.z, q.w
      end
      local transform = rotation:getMatrix()
      -- Draw at the anchor when one's supplied (a hairpin's on-road apex). Mid-drag, keep it glued to the cursor at node+offset
      -- (which equals the live gizmo pos), so resetting it each frame never fights the drag. No anchor -> draw on the node.
      if anchorPos then
        if isDragActive then tmpNew:setAdd2(selNode, dragOffset); transform:setPosition(tmpNew) else transform:setPosition(anchorPos) end
      else
        transform:setPosition(selNode)
      end
      editor.setAxisGizmoTransform(transform)

      -- Update the gizmo.
      editor.updateAxisGizmo(gizmoBeginDrag, gizmoEndDrag, gizmoDragging)

      -- Draw the gizmo.
      editor.drawAxisGizmo()

      -- Lock the appropriate axes.
      editor.setAxisGizmoRotateLock(false, isRotEnabled, false) -- We only allow rotation around the local tangent.
      editor.setAxisGizmoTranslateLock(true, true, not isConformToTerrain) -- Z is locked if conforming to terrain.

      -- Force local alignment for rotation.
      local currentGizmoMode = editor.getAxisGizmoMode()
      if currentGizmoMode == editor.AxisGizmoMode_Rotate then
        editor.setAxisGizmoAlignment(editor.AxisGizmoAlignment_Local) -- Force local alignment for rotation
      end

      -- Force world alignment when switching to translation.
      if currentGizmoMode ~= lastGizmoMode then
        if currentGizmoMode == editor.AxisGizmoMode_Translate then
          editor.setAxisGizmoAlignment(editor.AxisGizmoAlignment_World) -- Default to world alignment for translation
        end
        lastGizmoMode = currentGizmoMode
      end
    end
  end
end

-- True while an axis-gizmo drag (translate/rotate) is in progress.
local function isDragging() return isDragActive end


-- Public interface.
M.handleGizmo =                                         handleGizmo
M.isDragging =                                          isDragging

return M