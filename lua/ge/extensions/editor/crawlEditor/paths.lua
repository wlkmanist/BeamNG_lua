-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local im = ui_imgui
local ffi = require('ffi')
local utilPath = path

local lastPath = nil
local editEnded = im.BoolPtr(false)

local function setFieldUndo(data)
  local pathnode = data.pathnode
  if pathnode then
    pathnode[data.field] = data.old
  end
end

local function setFieldRedo(data)
  local pathnode = data.pathnode
  if pathnode then
    pathnode[data.field] = data.new
  end
end

local function setTransformUndo(data)
  local pathnode = data.pathnode
  if pathnode then
    pathnode.pos = data.old.pos
    if data.old.rotation then
      pathnode.rotation = data.old.rotation
    end
  end
end

local function setTransformRedo(data)
  local pathnode = data.pathnode
  if pathnode then
    pathnode.pos = data.new.pos
    if data.new.rotation then
      pathnode.rotation = data.new.rotation
    end
  end
end

local function teleportCameraTo(pos)
  if not pos then return end
  core_camera.setPosition(0, pos + vec3(0, 0, 15))
end

local function markPathAsDirty(path)
  -- The path table is the same reference stored in both level and mission lists,
  -- so setting the flag directly works for level and mission paths alike.
  if path then
    path._dirty = true
  end
end

function C:init(crawlEditorParam)
  self.crawlEditor = crawlEditorParam
  self.path = nil
  self.selectedPathnodeIndex = -1
  self.currentPathnode = nil
  self._prevGizmoPos = vec3(0, 0, 0)
  self._prevPathnodePos = {}
  self._prevPathnodeRotation = quat(1, 0, 0, 0)
  self.beginDragRotation = quat(1, 0, 0, 0)
  self.snapToTerrain = true
  self._isDragging = false
end

function C:setFields(path)
  if not path then return end
  self.name = im.ArrayChar(256, path.name or "")
  self.fileName = im.ArrayChar(256, path._fileName or "")
  self.description = im.ArrayChar(1024, path.description or "")
end

function C:setPath(pathParam)
  self.path = pathParam
end

function C:selectPathnode(index)
  self.selectedPathnodeIndex = index
  if index and index > 0 and self.path and self.path.nodes and self.path.nodes[index] then
    self.currentPathnode = self.path.nodes[index]
  else
    self.currentPathnode = nil
  end
end

function C:getSelectedPathnodeIndex()
  return self.selectedPathnodeIndex
end

function C:setSelectedPathnodeIndex(index)
  self:selectPathnode(index)
end

function C:drawPathsList(allPaths, selection)

  if im.Button("Add Path") then
    local newPath = self:getNewPath()
    table.insert(allPaths, newPath)
    selection.index = #allPaths
  end

  for i, path in ipairs(allPaths) do
    local isSelected = (i == selection.index)
    local displayName = path.name or "Unnamed Path"
    local pathnodeCount = path.nodes and #path.nodes or 0
    displayName = displayName .. " (" .. pathnodeCount .. " nodes)"

    if im.Selectable1(displayName, isSelected) then
      if selection.index == i then
        selection.index = -1
      end
      selection.index = i
      selection.clicked = true
    end

    -- Right-click context menu
    if im.BeginPopupContextItem("path_context_" .. i) then
      if im.MenuItem1("Delete") then
        table.remove(allPaths, i)
        if selection.index >= i then
          selection.index = selection.index - 1
        end
      end
      im.EndPopup()
    end
  end

  if #allPaths == 0 then
    im.Text("No paths available")
  end
end

function C:drawPathDetail(path)
  if not path then return end

  if lastPath ~= path then
    self:setFields(path)
    lastPath = path
  end

  im.Text("Path Details")
  im.SameLine()
  local teleportPos = path.nodes and path.nodes[1] and path.nodes[1].pos
  if not teleportPos then im.BeginDisabled() end
  if im.Button("Goto") then
    teleportCameraTo(teleportPos)
  end
  if not teleportPos then im.EndDisabled() end
  im.Separator()

  -- Name
  im.Text("Name")
  editEnded[0] = false
  editor.uiInputText("##PathName", self.name, nil, nil, nil, nil, editEnded)
  if editEnded[0] then
    path.name = ffi.string(self.name)
    markPathAsDirty(path)
  end

  -- File Name (rename functionality)
  im.Separator()
  im.Text("File Name")
  im.SameLine()
  if im.Button("Rename") then
    local newFileName = ffi.string(self.fileName)
    if newFileName ~= path._fileName and newFileName ~= "" then
      local oldFilePath = path._filePath
      local dir, _, ext = utilPath.splitWithoutExt(oldFilePath, true)
      local newFilePath = dir .. newFileName .. "." .. ext

      -- Use the rename function from the main editor
      if editor_crawlEditor and editor_crawlEditor.renameObjectFile then
        editor_crawlEditor.renameObjectFile(oldFilePath, newFilePath, "path")
      end
    end
  end

  editor.uiInputText("##FileName", self.fileName, nil, nil, nil, nil, nil)

  -- Description
  im.Text("Description")
  editEnded[0] = false
  editor.uiInputText("##PathDescription", self.description, nil, nil, nil, nil, editEnded)
  if editEnded[0] then
    path.description = ffi.string(self.description)
    markPathAsDirty(path)
  end

  im.Separator()

  -- Nodes
  if not path.nodes then
    path.nodes = {}
  end

  -- Live path statistics (computed from current nodes so edits are reflected immediately)
  do
    local nodeCount = #path.nodes
    local totalDistance = 0
    local elevationGain = 0
    local elevationLoss = 0
    for i = 1, nodeCount - 1 do
      local a = path.nodes[i].pos
      local b = path.nodes[i + 1].pos
      if a and b then
        totalDistance = totalDistance + a:distance(b)
        local dz = b.z - a.z
        if dz > 0 then elevationGain = elevationGain + dz else elevationLoss = elevationLoss - dz end
      end
    end
    im.Text(string.format("Nodes: %d   Length: %.1f m   Elev +%.1f / -%.1f m", nodeCount, totalDistance, elevationGain, elevationLoss))
  end

  if im.Button("Add Node") then
    self:getNewPathnode()
    markPathAsDirty(path)
  end
  im.SameLine()
  if im.Button("Add Node At Camera") then
    self:addNodeAtCamera()
  end

  -- Path Tools: bulk operations that speed up authoring
  if im.CollapsingHeader1("Path Tools") then
    if im.Button("Reverse Order") then
      self:reversePathOrder()
    end
    im.SameLine()
    if im.Button("Auto-Orient Nodes") then
      self:autoOrientNodes()
    end
    im.SameLine()
    if im.Button("Renumber") then
      self:renumberNodes()
    end

    if im.Button("Snap All To Terrain") then
      self:snapAllToTerrain()
    end

    if not self._bulkRadius then
      self._bulkRadius = im.FloatPtr(4.0)
    end
    im.PushItemWidth(120)
    im.InputFloat("##bulkRadius", self._bulkRadius)
    im.PopItemWidth()
    im.SameLine()
    if im.Button("Set All Radii") then
      self:setAllRadii(self._bulkRadius[0])
    end

    if im.Button("Validate Path") then
      self._validationReport = self:validatePath()
    end
    if self._validationReport then
      for _, line in ipairs(self._validationReport) do
        local isOk = line == "No problems found."
        im.TextColored(isOk and im.ImVec4(0.4, 1.0, 0.4, 1.0) or im.ImVec4(1.0, 0.6, 0.2, 1.0), line)
      end
    end
  end

  im.Separator()
  local removeIdx = nil
  for i, pathnode in ipairs(path.nodes) do
    im.PushID1(i.."_pathnode")
    local isSelected = (i == self.selectedPathnodeIndex)
    local isRecoveryCheckpoint = pathnode.flags and pathnode.flags.isRecoveryCheckpoint
    local isBonusCheckpoint = pathnode.flags and pathnode.flags.isBonusCheckpoint
    local displayName = pathnode.name or ("Node " .. i)

    if isRecoveryCheckpoint then
      displayName = displayName .. " [RECOVERY]"
      im.PushStyleColor2(im.Col_Text, im.ImVec4(0.2, 0.8, 0.2, 1.0)) -- Green text for recovery checkpoints
    elseif isBonusCheckpoint then
      displayName = displayName .. " [BONUS]"
      im.PushStyleColor2(im.Col_Text, im.ImVec4(1.0, 0.8, 0.0, 1.0)) -- Gold text for bonus checkpoints
    end

    if im.Selectable1(displayName, isSelected) then
      self:selectPathnode(i)
    end

    if isRecoveryCheckpoint or isBonusCheckpoint then
      im.PopStyleColor()
    end

    if im.SmallButton("Delete##" .. i) then
      removeIdx = i
    end
    im.PopID()
  end
  if removeIdx then
    table.remove(path.nodes, removeIdx)
    markPathAsDirty(path)
  end

  -- Selected node details
  if self.currentPathnode then
    im.Separator()
    im.Text("Selected Node:")

    local pathnodeName = im.ArrayChar(256, self.currentPathnode.name or "")
    im.Text("Name")
    local nameEditEnded = im.BoolPtr(false)
    editor.uiInputText("##NodeName", pathnodeName, nil, nil, nil, nil, nameEditEnded)
    if nameEditEnded[0] then
      self.currentPathnode.name = ffi.string(pathnodeName)
      markPathAsDirty(path)
    end

    -- Position
    local pos = im.ArrayFloat(3)
    pos[0] = self.currentPathnode.pos.x
    pos[1] = self.currentPathnode.pos.y
    pos[2] = self.currentPathnode.pos.z

    local posEditEnded = im.BoolPtr(false)
    editor.uiInputFloat3("Position", pos, nil, nil, posEditEnded)
    if posEditEnded[0] then
      self.currentPathnode.pos = vec3(pos[0], pos[1], pos[2])
      markPathAsDirty(path)
    end

    -- Rotation
    local rotation = self.currentPathnode.rotation or quat(1, 0, 0, 0)
    local rot = im.ArrayFloat(4)
    rot[0] = rotation.x
    rot[1] = rotation.y
    rot[2] = rotation.z
    rot[3] = rotation.w

    local rotEditEnded = im.BoolPtr(false)
    editor.uiInputFloat4("Rotation (x y z w)", rot, nil, nil, rotEditEnded)
    if rotEditEnded[0] then
      self.currentPathnode.rotation = quat(rot[0], rot[1], rot[2], rot[3])
      markPathAsDirty(path)
    end

    -- Human-readable forward heading derived from the rotation (gate facing direction)
    do
      local fwd = rotation * vec3(0, 1, 0)
      local yawDeg = math.deg(math.atan2(fwd.x, fwd.y))
      im.Text(string.format("Forward heading: %.1f deg", yawDeg))
    end

    -- Radius
    do
      local radiusPtr = im.FloatPtr(self.currentPathnode.radius or 6.0)
      local radiusEditEnded = im.BoolPtr(false)
      editor.uiInputFloat("Radius", radiusPtr, nil, nil, nil, nil, radiusEditEnded)
      if radiusEditEnded[0] then
        self.currentPathnode.radius = radiusPtr[0]
        markPathAsDirty(path)
      end
    end

    -- Flags (as JSON string for simplicity)
    self.currentPathnode.flags = self.currentPathnode.flags or {}

    -- Recovery Checkpoint Flag
    im.Text("Recovery Checkpoint")
    local isRecoveryCheckpoint = im.BoolPtr(self.currentPathnode.flags.isRecoveryCheckpoint or false)
    if im.Checkbox("Is Recovery Checkpoint", isRecoveryCheckpoint) then
      self.currentPathnode.flags.isRecoveryCheckpoint = isRecoveryCheckpoint[0]
      markPathAsDirty(path)
    end

    -- Bonus Checkpoint Flag
    im.Text("Bonus Checkpoint")
    local isBonusCheckpoint = im.BoolPtr(self.currentPathnode.flags.isBonusCheckpoint or false)
    if im.Checkbox("Is Bonus Checkpoint", isBonusCheckpoint) then
      self.currentPathnode.flags.isBonusCheckpoint = isBonusCheckpoint[0]
      markPathAsDirty(path)
    end

    -- Other flags (as JSON string for advanced users)
    local flagsStr = (json and json.encode and json.encode(self.currentPathnode.flags)) or "{}"
    local flagsBuf = im.ArrayChar(512, flagsStr)
    local flagsEditEnded = im.BoolPtr(false)
    editor.uiInputText("Flags (json)", flagsBuf, nil, nil, nil, nil, flagsEditEnded)
    if flagsEditEnded[0] then
      local ok, decoded = pcall(function(s)
        return (json and json.decode and json.decode(s)) or {}
      end, ffi.string(flagsBuf))
      if ok and type(decoded) == 'table' then
        self.currentPathnode.flags = decoded
        markPathAsDirty(path)
      end
    end
  end
end

function C:getNewPath()
  local path = {
    name = "New Path",
    description = "A new path",
    nodes = {}
  }
  return path
end

function C:getNewPathnode()
  local path = self.path
  if not path then
    path = self:getNewPath()
    self.path = path
  end
  local node = {
    name = "Node " .. tostring(#path.nodes + 1),
    pos = vec3(0, 0, 0),
    rotation = quat(1, 0, 0, 0),
    radius = 4.0,
    flags = {}
  }
  table.insert(path.nodes, node)
  return node
end

function C:findPathnode(mouseInfo, objects)
  local minNodeDist = 4294967295
  local closest = nil
  local clrF = ColorF(1, 1, 1, 0.75)
  local clrSelected = ColorF(0.91, 0.49, 0.24, 0.75)

  for idx, obj in pairs(objects) do
    local distNodeToCam = (obj.pos - mouseInfo.camPos):length()
    local nodeRayDistance = (obj.pos - mouseInfo.camPos):cross(mouseInfo.rayDir):length() / mouseInfo.rayDir:length()
    local sphereRadius = (mouseInfo.camPos - obj.pos):length() / 40

    local selected = false
    if self.selectedPathnodeIndex == idx then
      selected = true
    end

    if selected then
      debugDrawer:drawSphere(obj.pos, sphereRadius, clrSelected)
    else
      debugDrawer:drawSphere(obj.pos, sphereRadius, clrF)
    end

    if nodeRayDistance <= sphereRadius then
      if distNodeToCam < minNodeDist then
        minNodeDist = distNodeToCam
        closest = obj
      end
    end
  end
  return closest
end

function C:tryInsert(mouseInfo)
  if not self.path or not self.path.nodes or #self.path.nodes < 2 then
    return
  end

  local objs = {}
  for i, pn in ipairs(self.path.nodes) do
    local nextIdx = i == #self.path.nodes and 1 or i + 1
    table.insert(objs, {
      pos = (pn.pos + self.path.nodes[nextIdx].pos) / 2,
      radius = 3,
      orig = i
    })
  end

  local hit = self:findPathnode(mouseInfo, objs)
  if hit and mouseInfo.down then
    local newPathnode = self:getNewPathnode()
    newPathnode.pos = hit.pos

    -- getNewPathnode() already appended the node at the end; move it to the
    -- correct position between the two segment endpoints instead of duplicating it.
    table.remove(self.path.nodes)
    local insertIndex = hit.orig + 1
    table.insert(self.path.nodes, insertIndex, newPathnode)

    -- Select the newly inserted node
    self:selectPathnode(insertIndex)

    markPathAsDirty(self.path)
  end
end

function C:input(mouseInfo)
  if not self.path then return end

  if editor.keyModifiers.shift then
    if not editor.isAxisGizmoHovered() and mouseInfo.down then
      local newPathnode = self:getNewPathnode()
      newPathnode.pos = mouseInfo._downPos
      if self.snapToTerrain then
        local newPos, _ = self:dropToTerrain(newPathnode.pos)
        newPathnode.pos = newPos
      end
      self:selectPathnode(#self.path.nodes)
      markPathAsDirty(self.path)
    end
  elseif editor.keyModifiers.alt then
    self:tryInsert(mouseInfo)
  else
    local objects = {}
    for i, pathnode in ipairs(self.path.nodes) do
      table.insert(objects, {
        pos = pathnode.pos,
        index = i,
        radius = (mouseInfo.camPos - pathnode.pos):length() / 40
      })
    end

    local hit = self:findPathnode(mouseInfo, objects)
    if not editor.isAxisGizmoHovered() and mouseInfo.down then
      if editor.keyModifiers.ctrl then
        if hit then
          self:selectPathnode(hit.index)
        end
      else
        if hit then
          self:selectPathnode(hit.index)
        else
          self:selectPathnode(-1)
        end
      end
    end
  end
end

function C:updateTransform()
  if not self.path or not self.currentPathnode then return end

  local rotation = self.currentPathnode.rotation or quat(1, 0, 0, 0)
  local rotationQuatF = QuatF(rotation.x, rotation.y, rotation.z, rotation.w)
  local transform = rotationQuatF:getMatrix()
  transform:setPosition(self.currentPathnode.pos)
  editor.setAxisGizmoTransform(transform)
end

function C:beginDrag()
  if not self.currentPathnode then return end

  self._isDragging = true
  self._prevGizmoPos = vec3(editor.getAxisGizmoTransform():getColumn(3))
  self._prevPathnodePos = deepcopy(self.currentPathnode.pos)
  self._prevPathnodeRotation = quat(self.currentPathnode.rotation or quat(1, 0, 0, 0))
end

function C:dragging()
  if not self.path or not self.currentPathnode then return end

  local posOffset = (vec3(editor.getAxisGizmoTransform():getColumn(3)) - self._prevGizmoPos) / 2

  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
    self.currentPathnode.pos = self.currentPathnode.pos + posOffset

    if self.snapToTerrain then
      local newPos, succ = self:dropToTerrain(self.currentPathnode.pos)
      self.currentPathnode.pos = newPos
      if not succ then
        self.currentPathnode.pos.z = self._prevPathnodePos.z
      end
    end
  elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then
    -- Handle rotation via gizmo
    local newRotation = quat(editor.getAxisGizmoTransform():toQuatF())
    self.currentPathnode.rotation = newRotation
  end

  self._prevGizmoPos = vec3(editor.getAxisGizmoTransform():getColumn(3))
end

function C:dropToTerrain(pos)
  local p = vec3(pos)
  if core_terrain then
    p.z = (core_terrain.getTerrainHeight(p) or p.z)
    return p, true
  end
  return p, false
end

-- Adds a node in front of the camera, dropped onto the terrain, so new nodes don't spawn at the origin.
function C:addNodeAtCamera()
  if not self.path then return end
  local node = self:getNewPathnode()
  local camPos = core_camera.getPosition()
  local camDir = core_camera.getForward()
  local target = camPos + camDir * 15
  if self.snapToTerrain then
    target = self:dropToTerrain(target)
  end
  node.pos = target
  self:selectPathnode(#self.path.nodes)
  markPathAsDirty(self.path)
end

-- Reverses node order (so the trail can be authored in either direction).
function C:reversePathOrder()
  if not self.path or not self.path.nodes then return end
  local n = #self.path.nodes
  for i = 1, math.floor(n / 2) do
    self.path.nodes[i], self.path.nodes[n - i + 1] = self.path.nodes[n - i + 1], self.path.nodes[i]
  end
  self:selectPathnode(nil)
  markPathAsDirty(self.path)
end

-- Sets each node's rotation to face the next node, fixing gate orientations in one click.
function C:autoOrientNodes()
  if not self.path or not self.path.nodes then return end
  local nodes = self.path.nodes
  local n = #nodes
  if n < 2 then return end
  for i = 1, n do
    local a = nodes[i].pos
    local b = (i < n) and nodes[i + 1].pos or nodes[i - 1].pos
    local dir
    if i < n then
      dir = (b - a)
    else
      dir = (a - b) -- last node keeps the incoming direction
    end
    if dir:length() > 0.001 then
      nodes[i].rotation = quatFromDir(dir:normalized(), vec3(0, 0, 1))
    end
  end
  markPathAsDirty(self.path)
end

-- Applies a single radius to every node.
function C:setAllRadii(radius)
  if not self.path or not self.path.nodes or not radius or radius <= 0 then return end
  for _, node in ipairs(self.path.nodes) do
    node.radius = radius
  end
  markPathAsDirty(self.path)
end

-- Renames every node to a clean sequential "Node N".
function C:renumberNodes()
  if not self.path or not self.path.nodes then return end
  for i, node in ipairs(self.path.nodes) do
    node.name = "Node " .. i
  end
  markPathAsDirty(self.path)
end

-- Drops every node onto the terrain.
function C:snapAllToTerrain()
  if not self.path or not self.path.nodes then return end
  for _, node in ipairs(self.path.nodes) do
    if node.pos then
      node.pos = self:dropToTerrain(node.pos)
    end
  end
  markPathAsDirty(self.path)
end

-- Returns a list of human-readable problems found in the current path.
function C:validatePath()
  local report = {}
  if not self.path or not self.path.nodes then
    return { "No path / nodes." }
  end
  local nodes = self.path.nodes
  local n = #nodes
  if n < 2 then
    table.insert(report, string.format("Only %d node(s); a path needs at least 2.", n))
  end
  for i, node in ipairs(nodes) do
    if not node.radius or node.radius <= 0 then
      table.insert(report, string.format("Node %d has zero/negative radius.", i))
    end
    if not node.pos or (node.pos.x == 0 and node.pos.y == 0 and node.pos.z == 0) then
      table.insert(report, string.format("Node %d is at the origin (0,0,0).", i))
    end
    if not node.rotation then
      table.insert(report, string.format("Node %d has no rotation (no direction gate).", i))
    end
    if i < n and node.pos and nodes[i + 1].pos then
      local segLen = node.pos:distance(nodes[i + 1].pos)
      if segLen < 0.5 then
        table.insert(report, string.format("Segment %d->%d is very short (%.2f m).", i, i + 1, segLen))
      end
    end
  end
  if #report == 0 then
    table.insert(report, "No problems found.")
  end
  return report
end

function C:endDragging()
  if not self.currentPathnode then return end

  self._isDragging = false

  if self.snapToTerrain and editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
    local newPos = self:dropToTerrain(self.currentPathnode.pos)
    self.currentPathnode.pos = newPos
  end

  local oldPos = self._prevPathnodePos
  local newPos = self.currentPathnode.pos
  local oldRot = self._prevPathnodeRotation
  local newRot = self.currentPathnode.rotation or quat(1, 0, 0, 0)

  editor.history:commitAction("Manipulate Pathnode",
    {pathnode = self.currentPathnode, old = {pos = oldPos, rotation = oldRot}, new = {pos = newPos, rotation = newRot}},
    setTransformUndo, setTransformRedo)

  markPathAsDirty(self.path)
end

function C:draw(mouseInfo)
  if not self.path then return end
  if self.currentPathnode then
    editor.updateAxisGizmo(function()
      self:beginDrag()
    end, function()
      self:endDragging()
    end, function()
      self:dragging()
    end)
    editor.drawAxisGizmo()
  end

  self:input(mouseInfo)
  -- Only update transform when not dragging to avoid feedback loop
  if not self._isDragging then
    self:updateTransform()
  end
end

function C:drawPathnodeSelectionIndicators(mouseInfo)
  if not self.path or not self.path.nodes then
    return
  end

  -- Safety check for mouseInfo
  if not mouseInfo or not mouseInfo.camPos then
    return
  end

  for i, pathnode in ipairs(self.path.nodes) do
    local isSelected = (i == self.selectedPathnodeIndex)
    local isRecoveryCheckpoint = pathnode.flags and pathnode.flags.isRecoveryCheckpoint
    local isBonusCheckpoint = pathnode.flags and pathnode.flags.isBonusCheckpoint

    local color
    if isSelected then
      color = ColorF(0.91, 0.49, 0.24, 0.75) -- Orange for selected
    elseif isRecoveryCheckpoint then
      color = ColorF(0.2, 0.8, 0.2, 0.75) -- Green for recovery checkpoint
    elseif isBonusCheckpoint then
      color = ColorF(1.0, 0.8, 0.0, 0.75) -- Gold for bonus checkpoint
    else
      color = ColorF(1, 1, 1, 0.75) -- White for normal
    end

    debugDrawer:drawSphere(pathnode.pos, pathnode.radius, color)

    -- Draw direction arrow to show orientation
    local rotation = pathnode.rotation
    if rotation then
      -- Get forward direction from rotation (Y is forward in BeamNG)
      local forwardDir = rotation * vec3(0, 1, 0)
      local arrowLength = 3.0 -- Arrow length in meters
      local arrowStartPos = pathnode.pos
      local arrowEndPos = arrowStartPos + forwardDir * arrowLength

      -- Arrow sizes: tail is wider, tip is narrower
      local arrowSize1 = Point2F(0.3, 0.3) -- Tail size
      local arrowSize2 = Point2F(0.1, 0.1) -- Tip size
      local arrowColor = ColorF(0, 1, 0, 0.8) -- Green to match path color

      debugDrawer:drawSquarePrism(arrowStartPos, arrowEndPos, arrowSize1, arrowSize2, arrowColor)
    end

    -- Draw recovery checkpoint indicator
    if isRecoveryCheckpoint then
      debugDrawer:drawSphere(pathnode.pos, pathnode.radius + 1, ColorF(0.2, 0.8, 0.2, 0.3))
    end

    -- Draw bonus checkpoint indicator
    if isBonusCheckpoint then
      debugDrawer:drawSphere(pathnode.pos, pathnode.radius + 1, ColorF(1.0, 0.8, 0.0, 0.3))
    end

    if pathnode.name then
      local displayName = pathnode.name .. " (" .. i .. ")"
      if isRecoveryCheckpoint then
        displayName = displayName .. " [RECOVERY]"
      elseif isBonusCheckpoint then
        displayName = displayName .. " [BONUS]"
      end
      debugDrawer:drawTextAdvanced(pathnode.pos, String(displayName), ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 192))
    end
  end

  -- Draw direction triangles between pathnodes, with cumulative distance labels
  local cumDist = 0
  for i = 1, #self.path.nodes - 1 do
    local fromNode = self.path.nodes[i]
    local toNode = self.path.nodes[i + 1]

    if fromNode and toNode then
      debugDrawer:drawSquarePrism(
        fromNode.pos,
        toNode.pos,
        Point2F(2, 4),
        Point2F(0, 0),
        ColorF(0, 1, 0, 0.4))

      cumDist = cumDist + fromNode.pos:distance(toNode.pos)
      local mid = (fromNode.pos + toNode.pos) * 0.5
      debugDrawer:drawTextAdvanced(mid, String(string.format("%.0f m", cumDist)), ColorF(0.7, 0.9, 1, 1), true, false, ColorI(0, 0, 0, 150))
    end
  end
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end