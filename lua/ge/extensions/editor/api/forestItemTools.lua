-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared forest-item placement / selection / transform helpers, factored out of forestEditor.lua so a
-- second tool (parallaxInteriorEditor.lua) can place and edit forest items with the same machinery.
-- Everything is parameterized by the Forest / ForestData handle (no module-owned scene state) and rides
-- the same shared editor APIs the Forest Editor uses (editor.createForestItem / updateForestItem, the
-- global axis gizmo, forest:castRayRendered, editor.history). Selection is the canonical global store
-- editor.selection.forestItem, so only one tool interacts with it at a time (one active edit mode).

local M = {}

-- Drag/selection scratch. Only one editor drags at a time, so module-locals are safe here.
local selectionCentroid = vec3(0, 0, 0)
local objectHeights = {}
local originalTransforms = {}
local originalTransformsLua = {}
local originalScales = {}
local dragForestData          -- ForestData in use for the active gizmo drag
local dragForestTable         -- { forest } - the translate gizmo helper wants a list
local dragAndDuplicate        -- shift was held when this drag began: clone on the first drag frame
local duplicationDrag         -- this drag already cloned, so it commits as "added" instead of "moved"

-- Highlight colours for the shared select interaction: hovered item white, selection orange - same
-- as the Forest Editor's Select tool.
local colorWhite = ColorF(1, 1, 1, 1)
local colorOrange = ColorF(1, 0.6, 0, 0.5)
-- Pivot (cursor cell) highlight for the instantiate preview: solid BeamNG orange (255,102,0).
local colorPivot = ColorF(1, 0.4, 0, 1)
-- Red: the preview's facing (forward/outward) vector and the small sphere marking its end, the
-- displacement (surface -> placement) line when a surface offset pushes windows off the wall, and the
-- rectangle-select marquee outline.
local colorRed = ColorF(1, 0, 0, 1)
-- Blue: the preview's up basis vector, drawn shorter than the facing line so the two read apart at a glance.
local colorBlue = ColorF(0, 0, 1, 1)

-- Rectangle (box) select drag state for updateSelectMode. Module-level because a drag spans frames.
local rectDragStartPos      -- screen position where the marquee drag began (nil = not dragging)
local rectDragItems = {}    -- items currently inside the marquee (highlighted, committed on release)
local rectDragging = false  -- the press turned into a real drag (vs. a plain click)

local function getSelection()
  return (editor.selection and editor.selection.forestItem) or {}
end
M.getSelection = getSelection

local function updateCentroid(forestData)
  selectionCentroid = vec3(0, 0, 0)
  local sel = getSelection()
  if not sel[1] then return end
  local n = 0
  for _, item in ipairs(sel) do
    local obj = forestData:getItem(item:getKey(), item:getPosition())
    if obj and obj.getTransform then
      local wPos = obj:getTransform():getColumn(3)
      selectionCentroid.x = selectionCentroid.x + wPos.x
      selectionCentroid.y = selectionCentroid.y + wPos.y
      selectionCentroid.z = selectionCentroid.z + wPos.z
      n = n + 1
    end
  end
  if n > 0 then
    selectionCentroid.x = selectionCentroid.x / n
    selectionCentroid.y = selectionCentroid.y / n
    selectionCentroid.z = selectionCentroid.z / n
  end
end

local function clearSelection(forestData)
  if editor.selection and editor.selection.forestItem then
    for _, item in ipairs(editor.selection.forestItem) do
      editor.setForestItemSelected(forestData, item:getKey(), false)
    end
    worldEditorCppApi.rebuildForestManagerInstanceData()
    editor.selection.forestItem = {}
  end
end
M.clearSelection = clearSelection

-- Select the given forest items (nil/empty clears). addToSelection keeps the current selection.
-- Mirrors the Forest Editor's selection, minus its mesh-preview side effect.
local function select(forestData, forestItems, addToSelection)
  if not addToSelection and editor.selection and editor.selection.forestItem then
    for _, item in ipairs(editor.selection.forestItem) do
      editor.setForestItemSelected(forestData, item:getKey(), false)
    end
    if not forestItems then
      worldEditorCppApi.rebuildForestManagerInstanceData()
    end
  end

  if not addToSelection or not editor.selection or not editor.selection.forestItem then
    editor.selection = {}
    editor.selection.forestItem = {}
  end

  if not forestItems then return end

  for _, item in ipairs(forestItems) do
    editor.setForestItemSelected(forestData, item:getKey(), true)
    table.insert(editor.selection.forestItem, item)
  end

  if #forestItems > 0 then
    updateCentroid(forestData)
  end

  if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local and #forestItems == 1 then
    editor.setAxisGizmoTransform(forestItems[1]:getTransform(), vec3(1, 1, 1))
  else
    local mat = MatrixF(true)
    mat:setColumn(3, selectionCentroid)
    editor.setAxisGizmoTransform(mat, vec3(1, 1, 1))
  end

  worldEditorCppApi.rebuildForestManagerInstanceData()
  extensions.hook("onEditorObjectSelectionChanged")
end
M.select = select

-- Add / remove history (forestData travels in actionData so undo works whatever tool is active later).
local function addItemsUndo(actionData)
  for _, item in ipairs(actionData.items) do
    editor.removeForestItem(actionData.forestData, item)
  end
  select(actionData.forestData)
end

local function addItemsRedo(actionData)
  for _, item in ipairs(actionData.items) do
    editor.addForestItem(actionData.forestData, item)
  end
  -- Restore the selection so redoing a placement (or undoing a delete) leaves the items highlighted, the
  -- same as right after they were placed. addItem re-inserts under the same key, so these handles select.
  select(actionData.forestData, actionData.items)
end

local function addItems(forestData, items, dontCallRedo)
  if dontCallRedo == nil then dontCallRedo = false end
  return editor.history:commitAction("AddForestItems", {forestData = forestData, items = items}, addItemsUndo, addItemsRedo, dontCallRedo)
end
M.addItems = addItems

local function removeItems(forestData, items, dontCallRedo)
  if tableIsEmpty(items) then return end
  if dontCallRedo == nil then dontCallRedo = false end
  return editor.history:commitAction("RemoveForestItems", {forestData = forestData, items = items}, addItemsRedo, addItemsUndo, dontCallRedo)
end
M.removeItems = removeItems

-- Transform history. updateItem may return a fresh handle (the key can change), so we write the
-- returned item back into actionData.items and re-select.
local function setItemTransformUndo(actionData)
  for index, item in ipairs(actionData.items) do
    actionData.items[index] = editor.updateForestItem(actionData.forestData, item:getKey(), item:getPosition(), item:getData(), editor.tableToMatrix(actionData.oldTransforms[index]), actionData.oldScales[index], item:getUid())
  end
  select(actionData.forestData, actionData.items)
end

local function setItemTransformRedo(actionData)
  for index, item in ipairs(actionData.items) do
    actionData.items[index] = editor.updateForestItem(actionData.forestData, item:getKey(), item:getPosition(), item:getData(), editor.tableToMatrix(actionData.newTransforms[index]), actionData.newScales[index], item:getUid())
  end
  select(actionData.forestData, actionData.items)
end

-- Instantiate one item from a datablock template at the given transform and return the final handle.
-- afterCreate(item, forestData) optionally mutates the fresh item (e.g. set per-instance parallax data)
-- and returns the final handle. This does NOT record undo history: the caller commits (updateInstantiate-
-- Mode batches a whole array into a single addItems action so one undo removes the lot). The final handle
-- is what the caller stores, so redo (via addItem) restores those per-instance fields.
local function place(forest, itemData, transform, scale, afterCreate)
  local forestData = forest:getData()
  local item = editor.createForestItem(forestData, itemData, transform, scale)
  if afterCreate then
    local finalItem = afterCreate(item, forestData)
    if finalItem then item = finalItem end
  end
  return item
end
M.place = place

-- Click-pick the rendered forest item under the mouse. filterFn(item) can reject items that aren't
-- ours (e.g. keep the parallax tool from selecting ordinary forest items).
local function pick(forest, rayRange, filterFn)
  local cam = getCameraMouseRay()
  local res = forest:castRayRendered(cam.pos, cam.pos + cam.dir * rayRange)
  local item = res and res.forestItem
  if not item then return nil end
  if filterFn and not filterFn(item) then return nil end
  return item
end
M.pick = pick

-- Shift-drag duplicate: clone the current selection in place and select the clones, so the drag that is
-- already running carries the copies off and leaves the originals where they were.
--
-- createNewItem cannot take custom data, so the per-instance assignment (for parallax windows the texture
-- set id + flags) is copied onto each clone afterwards - and that re-keys the item, so the handle it hands
-- back is the one to keep. No history is recorded here; gizmoEndDrag commits the whole batch as one action.
local function duplicateSelection(forestData)
  local copies = {}
  for _, item in ipairs(getSelection()) do
    local copy = editor.createForestItem(forestData, item:getData(), item:getTransform(), item:getScale())
    local customData = item:getCustomData()
    if customData and customData >= 0 then
      copy = editor.setForestItemCustomData(forestData, copy:getKey(), customData) or copy
    end
    table.insert(copies, copy)
  end
  select(forestData, copies)
  return copies
end

-- Gizmo drag callbacks (translate / rotate / uniform-scale), same behaviour as the Forest Editor.
local function gizmoBeginDrag()
  objectHeights = {}
  originalTransforms = {}
  originalTransformsLua = {}
  originalScales = {}

  local objectBBs = {}
  for _, item in ipairs(getSelection()) do
    table.insert(originalTransforms, item:getTransform())
    table.insert(originalTransformsLua, editor.matrixToTable(item:getTransform()))
    table.insert(objectBBs, item:getWorldBox())
    table.insert(objectHeights, item:getObjBox().maxExtents.z)
    table.insert(originalScales, item:getScale())
  end

  -- Shift held as the drag starts arms a duplicate. The clone itself waits for the first drag frame, so a
  -- shift-click that never moves doesn't leave a copy stacked on the original. Assigned either way, so a
  -- plain drag following a shift-click can't inherit a stale arm.
  dragAndDuplicate = editor.keyModifiers.shift and getSelection()[1] ~= nil

  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
    editor.beginGizmoTranslate(originalTransforms, objectBBs, objectHeights, dragForestTable)
  end
end

local function gizmoDragging()
  local forestData = dragForestData
  -- First frame of a shift-drag: swap the selection for fresh clones so the rest of this drag moves those.
  -- The clones start on the originals' transforms, so the gizmo's delta math carries over untouched.
  -- Disarmed right away, so one drag clones once rather than every frame.
  if dragAndDuplicate and editor.keyModifiers.shift then
    dragAndDuplicate = false
    duplicationDrag = true
    duplicateSelection(forestData)
  end
  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
    local newTransforms = editor.getTransformsGizmoTranslate(dragForestTable, objectHeights)
    for index, transform in ipairs(newTransforms) do
      local item = editor.selection.forestItem[index]
      editor.selection.forestItem[index] = editor.updateForestItem(forestData, item:getKey(), item:getPosition(), item:getData(), transform, item:getScale(), item:getUid())
    end
  elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then
    local delta = vec3(worldEditorCppApi.getAxisGizmoTotalRotateOffset())
    editor.rotateForestSelection(forestData, delta, selectionCentroid, originalTransforms)
  elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Scale then
    for index, obj in ipairs(getSelection()) do
      local delta = vec3(worldEditorCppApi.getAxisGizmoScaleOffset())
      local mul = (delta.x < 0) and -1 or ((delta.y < 0) and -1 or (delta.z < 0 and -1 or 1))
      local deltaMax = math.max(math.abs(delta.x), math.abs(delta.y), math.abs(delta.z))
      deltaMax = math.min(deltaMax, 0.1) * mul
      local scale = obj:getScale() + deltaMax
      editor.selection.forestItem[index] = editor.updateForestItem(forestData, obj:getKey(), obj:getPosition(), obj:getData(), obj:getTransform(), scale, obj:getUid())
    end
  end
end

local function gizmoEndDrag()
  -- A duplicate drag ends as a single "items added" action. The clones already exist, so the redo is
  -- suppressed on commit; undoing removes them outright rather than moving them back onto the originals.
  if duplicationDrag then
    duplicationDrag = false
    dragAndDuplicate = false
    addItems(dragForestData, getSelection(), true)
    return
  end

  local newTransforms = {}
  local newScales = {}
  for _, item in ipairs(getSelection()) do
    table.insert(newTransforms, editor.matrixToTable(item:getTransform()))
    table.insert(newScales, item:getScale())
  end
  editor.history:commitAction("SetForestItemTransform",
    {forestData = dragForestData, items = editor.selection.forestItem, newTransforms = newTransforms, oldTransforms = originalTransformsLua, newScales = newScales, oldScales = originalScales},
    setItemTransformUndo, setItemTransformRedo)
end

-- Drive + draw the axis gizmo for the current selection. Call once per frame from the tool's onUpdate.
local function handleGizmo(forest)
  local sel = getSelection()
  if not sel[1] then return end
  dragForestData = forest:getData()
  dragForestTable = {forest}
  editor.updateAxisGizmo(gizmoBeginDrag, gizmoEndDrag, gizmoDragging)
  editor.drawAxisGizmo()
end
M.handleGizmo = handleGizmo

-- The marquee for rectangle select: rebuild the drag frustum's near-plane corners in world space and
-- outline them. Mirrors the Forest Editor's drawFrustumRect.
local function drawSelectionRect(frustum)
  local tl = vec3(frustum:getNearLeft() * 2, frustum:getNearDist() * 2, frustum:getNearTop() * 2)
  local tr = vec3(frustum:getNearRight() * 2, frustum:getNearDist() * 2, frustum:getNearTop() * 2)
  local bl = vec3(frustum:getNearLeft() * 2, frustum:getNearDist() * 2, frustum:getNearBottom() * 2)
  local br = vec3(frustum:getNearRight() * 2, frustum:getNearDist() * 2, frustum:getNearBottom() * 2)
  local pos = core_camera.getPosition()
  local q = core_camera.getQuat()
  local tlW, brW = (q * tl) + pos, (q * br) + pos
  local trW, blW = (q * tr) + pos, (q * bl) + pos
  debugDrawer:drawLine(tlW, trW, colorRed)
  debugDrawer:drawLine(trW, brW, colorRed)
  debugDrawer:drawLine(brW, blW, colorRed)
  debugDrawer:drawLine(blW, tlW, colorRed)
end

-- One frame of the shared "select forest items" interaction, restricted to items that pass filterFn
-- (item -> bool; nil = all). Highlights the hovered item, left-click selects it (Ctrl adds to the
-- selection, empty click clears), drag-select a screen rectangle (Ctrl adds), draws the current
-- selection's boxes and drives the transform gizmo. This is the Forest Editor's Select tool, reused so a
-- second tool can select the same items with its own filter. rayRange defaults to the working-distance pref.
local function updateSelectMode(forest, filterFn, rayRange)
  if not forest then return end
  local forestData = forest:getData()
  if not forestData then return end
  rayRange = rayRange or editor.getPreference("forestEditor.general.toolWorkingDistance") or 2000

  handleGizmo(forest)

  local cam = getCameraMouseRay()
  local res = forest:castRayRendered(cam.pos, cam.pos + cam.dir * rayRange)
  local hovered = res and res.forestItem
  if hovered and filterFn and not filterFn(hovered) then hovered = nil end

  -- Hide the single-item hover box while dragging a marquee (the rectangle draws its own highlights).
  if hovered and not rectDragStartPos then
    worldEditorCppApi.renderForestBBs({hovered}, colorWhite)
  end

  local canInteract = editor.isViewportHovered() and not editor.isAxisGizmoHovered()

  -- Mouse down: click-select the hovered item (Ctrl adds, empty click clears) and arm a possible drag.
  if ui_imgui.IsMouseClicked(0) and canInteract then
    if hovered then
      select(forestData, {hovered}, editor.keyModifiers.ctrl)
    elseif not editor.keyModifiers.ctrl then
      select(forestData)
    end
    rectDragStartPos = ui_imgui.GetMousePos()
    rectDragging = false
  end

  -- Drag: grow a screen rectangle and highlight every (filtered) item whose projection falls inside it.
  if rectDragStartPos and ui_imgui.IsMouseDragging(0) then
    rectDragging = true
    local delta = ui_imgui.GetMouseDragDelta(0)
    local tl2I = editor.screenToClient(Point2I(rectDragStartPos.x, rectDragStartPos.y))
    local topLeft = vec3(tl2I.x, tl2I.y, 0)
    local bottomRight = topLeft + vec3(delta.x, delta.y, 0)
    local frustum
    rectDragItems, frustum = editor.getObjectsByRectangle({topLeft = topLeft, bottomRight = bottomRight}, forestData)
    -- M.filterItems (not the bare local, which is declared later in the file so it isn't in scope here).
    if filterFn then rectDragItems = M.filterItems(rectDragItems, filterFn) end
    drawSelectionRect(frustum)
    worldEditorCppApi.renderForestBBs(rectDragItems, colorOrange)
  end

  -- Release: commit the marquee (Ctrl adds to the current selection). A plain click already selected on down.
  if ui_imgui.IsMouseReleased(0) then
    if rectDragStartPos and rectDragging and rectDragItems[1] then
      select(forestData, rectDragItems, editor.keyModifiers.ctrl)
    end
    rectDragStartPos = nil
    rectDragging = false
    rectDragItems = {}
  end

  local sel = getSelection()
  if sel[1] then
    worldEditorCppApi.renderForestBBs(sel, colorOrange)
  end
end
M.updateSelectMode = updateSelectMode

-- Object-space AABB of each shape file, read once and cached by path. Cached to {center, extents} (both
-- vec3, in the mesh's local axes) so the placement preview can box the real mesh footprint instead of a
-- fixed square. First read only.
local meshBoxCache = {}

-- Read a shape file's local AABB via a throwaway TSStatic (registering it loads the shape; getObjBox then
-- has valid bounds), then delete it. Cached by path, so the create/delete only happens on the first use of
-- a mesh. Returns nil for an empty path. Mirrors editor/toolUtilities/util.lua's getMeshBox.
local function getMeshBox(shapeFile)
  if not shapeFile or shapeFile == "" then return nil end
  if shapeFile:sub(1, 1) ~= '/' then shapeFile = '/' .. shapeFile end
  local cached = meshBoxCache[shapeFile]
  if cached then return cached end
  local obj = createObject('TSStatic')
  if not obj then return nil end
  obj.cansave = false
  obj:setField('shapeName', 0, shapeFile)
  obj:registerObject(Sim.getUniqueName('forestItemTools_tempMeshBox'))
  local objBox = obj:getObjBox()
  local extents = objBox:getExtents()
  local center = objBox:getCenter()
  obj:delete()
  local box = {
    center = vec3(center.x, center.y, center.z),
    extents = vec3(extents.x, extents.y, extents.z),
  }
  meshBoxCache[shapeFile] = box
  return box
end

-- A wireframe box for `box` ({center, extents} in mesh-local axes) placed at `origin` with the item basis:
-- mesh-local X maps to right, Y to forward (facing), Z to up - the same mapping the placed transform uses,
-- so the box outlines exactly where the mesh will sit (footprint + depth). Drawn as its 12 edges.
local function drawMeshBox(origin, right, forward, up, box, color)
  local c, e = box.center, box.extents
  local hx, hy, hz = e.x * 0.5, e.y * 0.5, e.z * 0.5
  local function corner(sx, sy, sz)
    return origin + right * (c.x + sx * hx) + forward * (c.y + sy * hy) + up * (c.z + sz * hz)
  end
  local p000, p100 = corner(-1, -1, -1), corner(1, -1, -1)
  local p110, p010 = corner(1, 1, -1), corner(-1, 1, -1)
  local p001, p101 = corner(-1, -1, 1), corner(1, -1, 1)
  local p111, p011 = corner(1, 1, 1), corner(-1, 1, 1)
  debugDrawer:drawLine(p000, p100, color) -- bottom
  debugDrawer:drawLine(p100, p110, color)
  debugDrawer:drawLine(p110, p010, color)
  debugDrawer:drawLine(p010, p000, color)
  debugDrawer:drawLine(p001, p101, color) -- top
  debugDrawer:drawLine(p101, p111, color)
  debugDrawer:drawLine(p111, p011, color)
  debugDrawer:drawLine(p011, p001, color)
  debugDrawer:drawLine(p000, p001, color) -- verticals
  debugDrawer:drawLine(p100, p101, color)
  debugDrawer:drawLine(p110, p111, color)
  debugDrawer:drawLine(p010, p011, color)
end

-- Placement basis for the array + each item's orientation. Returns unit (right, up, forward); the item
-- transform columns are X=right, Y=forward (the window's facing), Z=up (the forest item convention), and
-- the array steps along right (columns) and up (rows). World mode is the identity axes yawed around world
-- Z, so a row runs along +X rotated by yawRad. alignToNormal instead faces the window along the surface
-- normal, lays the array in that surface's plane and treats yawRad as an in-plane spin. flip reverses the
-- facing (window faces the other way) - the fix when a wall's normal points the wrong side.
local function placementBasis(hitNormal, yawRad, alignToNormal, flip)
  if alignToNormal and hitNormal then
    local forward = vec3(hitNormal):normalized()
    if flip then forward = forward * -1 end
    local upRef = (math.abs(forward.z) > 0.99) and vec3(0, 1, 0) or vec3(0, 0, 1)
    local right = forward:cross(upRef):normalized()
    local up = right:cross(forward):normalized()
    if yawRad ~= 0 then
      local co, si = math.cos(yawRad), math.sin(yawRad)
      right, up = right * co + up * si, up * co - right * si
    end
    return right, up, forward
  end
  local y = yawRad + (flip and math.pi or 0) -- flip in world mode is just a 180 deg yaw (keeps handedness)
  local co, si = math.cos(y), math.sin(y)
  return vec3(co, si, 0), vec3(0, 0, 1), vec3(-si, co, 0) -- right, up, forward
end
M.placementBasis = placementBasis

-- One frame of the shared "instantiate item" interaction: raycast under the cursor and, on left click,
-- create forest item(s) from the datablock `itemDataId` at the hit (scale 1, undoable in one step). This
-- is the Forest Editor's Instantiate tool, reused so a second tool can place its own meshes.
--
-- opts (all optional):
--   rayRange                              pick distance (defaults to the forest tool preference).
--   cols, rows                            array size. The cursor cell is the pivot; columns grow along the
--                                         basis' right, rows along its up. Default 1x1 (single placement).
--   colGap, rowGap                        metres of empty space between neighbouring cells, measured edge
--                                         to edge on the mesh's own bounds (default 0, i.e. flush).
--   yaw                                   array rotation in degrees (see placementBasis).
--   alignToNormal                         face placed items along the surface normal under the cursor.
--   flipNormal                            reverse the facing (see placementBasis).
--   normalOffset                          metres to push each item off the surface along its facing (so a
--                                         wall-aligned window sits in front of the wall instead of inside).
--   scale                                 uniform scale applied to each placed item (default 1); the preview
--                                         box grows with it too.
--   afterCreate(item, forestData, index)  per-instance hook (e.g. stamp parallax customData); returns the
--                                         final handle stored in history. index is 1-based over the array.
-- Preview per cell: a small sphere + the mesh's real bounding box (read once via getMeshBox, cached) + a
-- facing line, with the pivot cell in orange, plus a red line from the surface to the offset position. On
-- click the whole array is committed as a single undo action and returned as a list, else nil.
local function updateInstantiateMode(forest, itemDataId, opts)
  if not forest then return end
  local forestData = forest:getData()
  if not forestData then return end
  opts = opts or {}
  local rayRange = opts.rayRange or editor.getPreference("forestEditor.general.toolWorkingDistance") or 2000
  local cols = math.max(1, math.floor(opts.cols or 1))
  local rows = math.max(1, math.floor(opts.rows or 1))
  local colGap = opts.colGap or 0.0
  local rowGap = opts.rowGap or 0.0
  local yawRad = math.rad(opts.yaw or 0)
  local alignToNormal = opts.alignToNormal or false
  local flipNormal = opts.flipNormal or false
  local normalOffset = opts.normalOffset or 0.0
  local scale = math.max(0.01, opts.scale or 1.0)
  local afterCreate = opts.afterCreate

  -- Keep the current selection boxed. Instantiate selects what it places (below), and a parallax window
  -- mesh is one-sided, so this box is often the only way to spot a freshly placed window.
  local sel = getSelection()
  if sel[1] then
    worldEditorCppApi.renderForestBBs(sel, colorOrange)
  end

  if ui_imgui.GetIO().WantCaptureMouse then return end

  local hit = cameraMouseRayCast(false, nil, rayRange)
  if not hit then return end

  local right, up, forward = placementBasis(hit.normal, yawRad, alignToNormal, flipNormal)

  -- The picked mesh's real bounds for the preview box (cached per shape). Fall back to a rough window-sized
  -- box when nothing is picked yet, so the preview still shows a footprint.
  local itemData = itemDataId and scenetree.findObjectById(itemDataId)
  local meshBox = itemData and itemData.getShapeFile and getMeshBox(itemData:getShapeFile())
  local box = meshBox or { center = vec3(0, 0, 0), extents = vec3(2, 0.2, 2) }

  -- Pivot-to-pivot step: the mesh's own footprint plus the gap, so the gap is the space left between two
  -- neighbours' edges whatever mesh is picked. The box is in mesh-local axes, which the item transform maps
  -- X -> right (columns) and Z -> up (rows), and it grows with the placement scale like the mesh does.
  local colStep = box.extents.x * scale + colGap
  local rowStep = box.extents.z * scale + rowGap

  -- The offset a cell is displaced from the surface along the facing, so each window can sit in front of
  -- the wall it aligns to. surfacePos -> placePos = surfacePos + forward * normalOffset.
  local placePos = function(c, r)
    return hit.pos + right * (c * colStep) + up * (r * rowStep) + forward * normalOffset
  end

  -- Preview per cell: a small marker sphere + the mesh's real bounding box (right/up/forward basis, so the
  -- box shows footprint and depth) + short basis lines (facing/outward in red, up in blue). The pivot cell
  -- (0,0) is drawn in orange. A red line from the surface to the offset position shows the displacement when
  -- a surface offset is set.
  local rrg = extensions.editor_roadRiverGui
  local sizeFactor = (rrg and rrg.nodeSizeFactor) or 0.01
  local sphereColor = (rrg and rrg.highlightColors and rrg.highlightColors.selectedNode) or colorWhite
  local camPos = core_camera.getPosition()
  for r = 0, rows - 1 do
    for c = 0, cols - 1 do
      local surfacePos = hit.pos + right * (c * colStep) + up * (r * rowStep)
      local p = surfacePos + forward * normalOffset
      local radius = (camPos - p):length() * sizeFactor
      local col = (r == 0 and c == 0) and colorPivot or sphereColor
      debugDrawer:drawSphere(p, radius * 0.5, col, false)
      drawMeshBox(p, right * scale, forward * scale, up * scale, box, col) -- box grows with the placement scale
      local fwdTip = p + forward * (radius * 6)
      debugDrawer:drawLine(p, fwdTip, colorRed)                     -- facing / outward
      debugDrawer:drawSphere(fwdTip, radius * 0.3, colorRed, false) -- small marker at the front, so it reads apart from the up line
      debugDrawer:drawLine(p, p + up * (radius * 3), colorBlue)     -- up (shorter than the facing line)
      if normalOffset ~= 0 then
        debugDrawer:drawLine(surfacePos, p, colorRed)
      end
    end
  end

  if ui_imgui.IsMouseClicked(0) then
    if not itemData then
      local msg = "Instantiate: select a mesh first."
      log('W', 'forestItemTools', msg)
      if editor.showNotification then editor.showNotification(msg) end
      return
    end
    local placed = {}
    local index = 0
    for r = 0, rows - 1 do
      for c = 0, cols - 1 do
        index = index + 1
        local m = MatrixF(true)
        m:setColumn(0, right)
        m:setColumn(1, forward)
        m:setColumn(2, up)
        m:setPosition(placePos(c, r))
        local ac = afterCreate and function(it, fd) return afterCreate(it, fd, index) end or nil
        placed[#placed + 1] = place(forest, itemData, m, scale, ac)
      end
    end
    addItems(forestData, placed, true) -- one undoable action for the whole array (items already created)
    select(forestData, placed)         -- select them so the one-sided meshes are immediately visible
    return placed
  end
end
M.updateInstantiateMode = updateInstantiateMode

-- ForestItemData datablock discovery, filtered by a name prefix. matchPrefix=true returns only
-- datablocks whose name (or internalName) starts with `prefix` - the Parallax Interior Editor lists
-- these; matchPrefix=false returns the rest - the Forest Editor, so parallax windows stay out of its
-- mesh palette. Returns a name-sorted list of { id, name }.
local function listItemDatas(prefix, matchPrefix)
  local pat = "^" .. prefix
  local out = {}
  for _, id in ipairs(scenetree.findClassObjects("ForestItemData") or {}) do
    local cobj = scenetree.findObject(id)
    if cobj then
      local name = cobj.name
      local iname = cobj.internalName
      local matches = (type(name) == "string" and string.find(name, pat) ~= nil)
        or (type(iname) == "string" and string.find(iname, pat) ~= nil)
      if matches == matchPrefix then
        out[#out + 1] = { id = cobj:getId(), name = tostring(name or iname or id) }
      end
    end
  end
  table.sort(out, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
  return out
end
M.listItemDatas = listItemDatas

-- Shared mesh-list row for both the Forest Editor and the Parallax Interior Editor: a datablock icon
-- plus a full-width selectable that highlights when selected. Returns true on click; the caller owns
-- selection state. `uniqueId` (the datablock id) disambiguates the imgui id. `icon` optionally
-- overrides the default datablock icon (the Parallax Interior Editor passes crop_din for its windows).
local function itemDataSelectable(uniqueId, label, isSelected, icon)
  local im = ui_imgui
  local fontSize = math.ceil(im.GetFontSize())
  editor.uiIconImage(icon or editor.icons.forest_brushelement, im.ImVec2(fontSize, fontSize))
  im.SameLine()
  local cPos = im.GetCursorPos()
  im.PushStyleColor2(im.Col_Button, isSelected and im.GetStyleColorVec4(im.Col_ButtonActive) or im.GetStyleColorVec4(im.Col_Button))
  local clicked = im.Button("##forestItemData_" .. tostring(uniqueId), im.ImVec2(im.GetContentRegionAvailWidth(), fontSize))
  im.PopStyleColor()
  im.SetCursorPos(im.ImVec2(cPos.x + im.GetStyle().FramePadding.x, cPos.y))
  im.TextUnformatted(tostring(label or ""))
  return clicked
end
M.itemDataSelectable = itemDataSelectable

-- Datablock name prefix that marks a forest item as a parallax "fake interior" window. The Parallax
-- Interior Editor only touches items with this prefix; the Forest Editor only touches the rest.
local PARALLAX_ITEM_PREFIX = "parallax_"
M.PARALLAX_ITEM_PREFIX = PARALLAX_ITEM_PREFIX

-- True when a forest item's datablock name (or internalName) starts with `prefix`. Checks both to
-- match listItemDatas, since a datablock can be identified by either.
local function itemMatchesPrefix(item, prefix)
  local data = item and item.getData and item:getData()
  if not data then return false end
  local pat = "^" .. prefix
  local name = data.getName and data:getName()
  if type(name) == "string" and string.find(name, pat) then return true end
  local iname = data.getInternalName and data:getInternalName()
  if type(iname) == "string" and string.find(iname, pat) then return true end
  return false
end
M.itemMatchesPrefix = itemMatchesPrefix

-- Convenience predicate for the select filters: is this a parallax window item?
local function isParallaxItem(item)
  return itemMatchesPrefix(item, PARALLAX_ITEM_PREFIX)
end
M.isParallaxItem = isParallaxItem

-- Same test on a ForestItemData datablock object (from scenetree.findObject), for filtering the mesh
-- palette: true when the datablock's name / internalName starts with the parallax_ prefix.
local function isParallaxDataObject(cobj)
  if not cobj then return false end
  local pat = "^" .. PARALLAX_ITEM_PREFIX
  local name = cobj.name
  if type(name) == "string" and string.find(name, pat) then return true end
  local iname = cobj.internalName
  if type(iname) == "string" and string.find(iname, pat) then return true end
  return false
end
M.isParallaxDataObject = isParallaxDataObject

-- Returns a new list with only the items for which keep(item) is true (nil list -> empty list).
local function filterItems(items, keep)
  local out = {}
  for _, item in ipairs(items or {}) do
    if keep(item) then out[#out + 1] = item end
  end
  return out
end
M.filterItems = filterItems

-- Parallax per-instance packing over the ForestItem generic customData i32. The parallax interior
-- material reads customData as: bits[0..23] = texture set id (0xFFFFFF, i.e. the default -1, = none /
-- disabled / not serialized), bits[24..31] = flags (bit 0 = emissive). Must stay in sync with
-- shaders/common/examples/parallaxInterior.h.hlsl.
local PARALLAX_SETID_MASK = 0xFFFFFF
local PARALLAX_SETID_NONE = 0xFFFFFF
local PARALLAX_FLAGS_SHIFT = 24
local PARALLAX_FLAG_EMISSIVE = 1

-- customData -> (setId, emissive). setId is -1 when no parallax set is assigned (disabled).
local function unpackParallaxData(customData)
  customData = customData or -1
  if customData < 0 then return -1, false end
  local setId = bit.band(customData, PARALLAX_SETID_MASK)
  if setId == PARALLAX_SETID_NONE then return -1, false end
  local emissive = bit.band(bit.rshift(customData, PARALLAX_FLAGS_SHIFT), PARALLAX_FLAG_EMISSIVE) ~= 0
  return setId, emissive
end
M.unpackParallaxData = unpackParallaxData

-- (setId, emissive) -> customData. setId < 0 yields -1 (disabled; the C++ save drops customData < 0).
local function packParallaxData(setId, emissive)
  if not setId or setId < 0 then return -1 end
  local v = bit.band(setId, PARALLAX_SETID_MASK)
  if emissive then v = bit.bor(v, bit.lshift(PARALLAX_FLAG_EMISSIVE, PARALLAX_FLAGS_SHIFT)) end
  return v
end
M.packParallaxData = packParallaxData

return M
