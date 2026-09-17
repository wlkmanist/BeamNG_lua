-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local im = ui_imgui
local ffi = require('ffi')

local lastStartingPosition = nil
local editEnded = im.BoolPtr(false)

local function setFieldUndo(data)
  local startingPosition = data.startingPosition
  if startingPosition then
    startingPosition[data.field] = data.old
  end
end

local function setFieldRedo(data)
  local startingPosition = data.startingPosition
  if startingPosition then
    startingPosition[data.field] = data.new
  end
end

local function setTransformUndo(data)
  local startingPosition = data.startingPosition
  if startingPosition then
    startingPosition.transform.position = data.old.position
    startingPosition.transform.rotation = data.old.rotation
    startingPosition.transform.radius = data.old.radius
  end
end

local function setTransformRedo(data)
  local startingPosition = data.startingPosition
  if startingPosition then
    startingPosition.transform.position = data.new.position
    startingPosition.transform.rotation = data.new.rotation
    startingPosition.transform.radius = data.new.radius
  end
end

local function teleportCameraTo(pos)
  if not pos then return end
  core_camera.setPosition(0, pos + vec3(0, 0, 15))
end

local function markStartingPositionAsDirty(startingPosition)
  if startingPosition then
    startingPosition._dirty = true
  end
end

function C:init()
  self.startingPosition = nil
  self.currentTransform = nil -- "area" or "icon"
  self._prevGizmoPos = vec3(0, 0, 0)
  self._prevTransformPos = vec3(0, 0, 0)
  self.snapToTerrain = true
  self._placingWithRotation = false -- Track if we're placing with rotation
  self._placementTemp = nil -- Temporary data for placement
end

function C:setFields(startingPosition)
  if not startingPosition then return end
  self.name = im.ArrayChar(256, startingPosition.name or "")
  self.fileName = im.ArrayChar(256, startingPosition._fileName or "")
  self.description = im.ArrayChar(1024, startingPosition.description or "")
end

function C:drawStartingPositionsList(allStartingPositions, selection)
  if im.Button("Add Starting Position") then
    local newStartingPosition = self:getNewStartingPosition()
    table.insert(allStartingPositions, newStartingPosition)
    selection.index = #allStartingPositions
  end

  for i, startingPosition in ipairs(allStartingPositions) do
    local isSelected = (i == selection.index)
    local displayName = startingPosition.name or "Unnamed Starting Position"

    if im.Selectable1(displayName, isSelected) then
      if selection.index == i then
        selection.index = -1
      end
      selection.index = i
      selection.clicked = true
    end

    -- Right-click context menu
    if im.BeginPopupContextItem("starting_position_context_" .. i) then
      if im.MenuItem1("Delete") then
        table.remove(allStartingPositions, i)
        if selection.index >= i then
          selection.index = selection.index - 1
        end
      end
      im.EndPopup()
    end
  end

  if #allStartingPositions == 0 then
    im.Text("No starting positions available")
  end
end

function C:drawStartingPositionDetail(startingPosition)
  if not startingPosition then return end

  if lastStartingPosition ~= startingPosition then
    self:setFields(startingPosition)
    lastStartingPosition = startingPosition
  end

  im.Text("Starting Position Details")
  im.SameLine()
  if im.Button("Goto") then
    teleportCameraTo(startingPosition.transform and startingPosition.transform.position)
  end
  im.Separator()

  -- Name
  im.Text("Name")
  editEnded[0] = false
  editor.uiInputText("##StartingPositionName", self.name, nil, nil, nil, nil, editEnded)
  if editEnded[0] then
    editor.history:commitAction("Change Starting Position Name",
      {startingPosition = startingPosition, old = startingPosition.name, new = ffi.string(self.name), field = 'name'},
      setFieldUndo, setFieldRedo)
    markStartingPositionAsDirty(startingPosition)
  end

  -- File Name (rename functionality)
  im.Separator()
  im.Text("File Name")
  im.SameLine()
  if im.Button("Rename") then
    local newFileName = ffi.string(self.fileName)
    if newFileName ~= startingPosition._fileName and newFileName ~= "" then
      local oldFilePath = startingPosition._filePath
      local dir, _, ext = path.splitWithoutExt(oldFilePath, true)
      local newFilePath = dir .. newFileName .. "." .. ext

      -- Use the rename function from the main editor
      if editor_crawlEditor and editor_crawlEditor.renameObjectFile then
        editor_crawlEditor.renameObjectFile(oldFilePath, newFilePath, "startingPosition")
      end
    end
  end

  editor.uiInputText("##FileName", self.fileName, nil, nil, nil, nil, nil)

  -- Description
  im.Text("Description")
  editEnded[0] = false
  editor.uiInputText("##StartingPositionDescription", self.description, nil, nil, nil, nil, editEnded)
  if editEnded[0] then
    editor.history:commitAction("Change Starting Position Description",
      {startingPosition = startingPosition, old = startingPosition.description, new = ffi.string(self.description), field = 'description'},
      setFieldUndo, setFieldRedo)
    markStartingPositionAsDirty(startingPosition)
  end

  -- Area Transform
  im.Separator()
  im.Text("Area Transform")

  -- Position
  local pos = im.ArrayFloat(3)
  pos[0] = startingPosition.transform.position.x
  pos[1] = startingPosition.transform.position.y
  pos[2] = startingPosition.transform.position.z
  local posEditEnded = im.BoolPtr(false)
  editor.uiInputFloat3("Position", pos, nil, nil, posEditEnded)
  if posEditEnded[0] then
    local newPos = vec3(pos[0], pos[1], pos[2])
    editor.history:commitAction("Change Starting Position Area Position",
      {startingPosition = startingPosition, old = {position = startingPosition.transform.position, rotation = startingPosition.transform.rotation, radius = startingPosition.transform.radius}, new = {position = newPos, rotation = startingPosition.transform.rotation, radius = startingPosition.transform.radius}},
      setTransformUndo, setTransformRedo)
    markStartingPositionAsDirty(startingPosition)
  end

  -- Rotation
  local rot = im.ArrayFloat(4)
  rot[0] = startingPosition.transform.rotation.x
  rot[1] = startingPosition.transform.rotation.y
  rot[2] = startingPosition.transform.rotation.z
  rot[3] = startingPosition.transform.rotation.w
  local rotEditEnded = im.BoolPtr(false)
  editor.uiInputFloat4("Rotation", rot, nil, nil, rotEditEnded)
  if rotEditEnded[0] then
    local newRot = quat(rot[0], rot[1], rot[2], rot[3])
    editor.history:commitAction("Change Starting Position Area Rotation",
      {startingPosition = startingPosition, old = {position = startingPosition.transform.position, rotation = startingPosition.transform.rotation, radius = startingPosition.transform.radius}, new = {position = startingPosition.transform.position, rotation = newRot, radius = startingPosition.transform.radius}},
      setTransformUndo, setTransformRedo)
    markStartingPositionAsDirty(startingPosition)
  end

  -- Radius
  local radius = im.FloatPtr(startingPosition.transform.radius or 10.0)
  local radiusEditEnded = im.BoolPtr(false)
  editor.uiInputFloat("Radius", radius, nil, nil, nil, nil, radiusEditEnded)
  if radiusEditEnded[0] then
    editor.history:commitAction("Change Starting Position Area Radius",
      {startingPosition = startingPosition, old = {position = startingPosition.transform.position, rotation = startingPosition.transform.rotation, radius = startingPosition.transform.radius}, new = {position = startingPosition.transform.position, rotation = startingPosition.transform.rotation, radius = radius[0]}},
      setTransformUndo, setTransformRedo)
    markStartingPositionAsDirty(startingPosition)
  end

  -- Icon Position
  im.Separator()
  im.Text("Icon Position")

  local iconPos = im.ArrayFloat(3)
  iconPos[0] = startingPosition.iconPosition.x
  iconPos[1] = startingPosition.iconPosition.y
  iconPos[2] = startingPosition.iconPosition.z
  local iconPosEditEnded = im.BoolPtr(false)
  editor.uiInputFloat3("Icon Position", iconPos, nil, nil, iconPosEditEnded)
  if iconPosEditEnded[0] then
    local newIconPos = vec3(iconPos[0], iconPos[1], iconPos[2])
    editor.history:commitAction("Change Starting Position Icon Position",
      {startingPosition = startingPosition, old = startingPosition.iconPosition, new = newIconPos, field = 'iconPosition'},
      setFieldUndo, setFieldRedo)
    markStartingPositionAsDirty(startingPosition)
  end


end

function C:getNewStartingPosition()
  return {
    name = "New Starting Position",
    description = "A new starting position",
    transform = {
      position = vec3(0, 0, 0),
      rotation = quat(1, 0, 0, 0),
      radius = 4.0
    },
    iconPosition = vec3(0, 0, 0),
    metadata = {
      created = os.date(),
      version = "1.0"
    }
  }
end

function C:setStartingPosition(startingPositionParam)
  self.startingPosition = startingPositionParam
end

function C:clearSelection()
  self.currentTransform = nil
end

function C:input(mouseInfo)
  if not self.startingPosition then return end

  -- Shift+click to place icon position (quick placement, no rotation)
  if not editor.isAxisGizmoHovered() and mouseInfo.down and mouseInfo._downPos and editor.keyModifiers.shift then
    local oldIconPos = self.startingPosition.iconPosition and vec3(self.startingPosition.iconPosition) or nil
    local mousePos = vec3(mouseInfo._downPos)
    self.startingPosition.iconPosition = mousePos
    editor.history:commitAction("Place Starting Position Icon",
      {startingPosition = self.startingPosition, old = oldIconPos, new = mousePos, field = 'iconPosition'},
      setFieldUndo, setFieldRedo)
    markStartingPositionAsDirty(self.startingPosition)
    return
  end

  -- Handle placement with rotation (Ctrl+click and drag)
  if editor.keyModifiers.ctrl and not editor.isAxisGizmoHovered() then
    if mouseInfo.down and mouseInfo._downPos then
      -- Start placement with rotation
      self._placingWithRotation = true
      self._placementTemp = {
        oldPosition = vec3(self.startingPosition.transform.position),
        oldRotation = quat(self.startingPosition.transform.rotation),
        downPos = vec3(mouseInfo._downPos),
        downNormal = mouseInfo._downNormal and vec3(mouseInfo._downNormal) or vec3(0, 0, 1),
        moved = false
      }
      -- Set initial position
      local mousePos = mouseInfo._downPos
      self.startingPosition.transform.position = mousePos
      if self.snapToTerrain then
        local newPos, _ = self:dropToTerrain(mousePos)
        self.startingPosition.transform.position = newPos
        self._placementTemp.downPos = newPos
      end
    elseif mouseInfo.hold and self._placingWithRotation and self._placementTemp then
      -- Update rotation based on mouse drag direction
      if mouseInfo._holdPos then
        local len = (mouseInfo._holdPos - self._placementTemp.downPos):length()
        if len > 0.1 then
          self._placementTemp.moved = true
          -- Calculate direction from initial click to current mouse position
          local fwd = (mouseInfo._holdPos - self._placementTemp.downPos):normalized()
          -- Create rotation from direction and surface normal
          local rot = quatFromDir(fwd, self._placementTemp.downNormal):normalized()
          self.startingPosition.transform.rotation = rot
        end
      end
    elseif mouseInfo.up and self._placingWithRotation then
      -- Commit placement action
      if self._placementTemp then
        editor.history:commitAction("Place Starting Position Area",
          {startingPosition = self.startingPosition,
           old = {position = self._placementTemp.oldPosition, rotation = self._placementTemp.oldRotation, radius = self.startingPosition.transform.radius},
           new = {position = self.startingPosition.transform.position, rotation = self.startingPosition.transform.rotation, radius = self.startingPosition.transform.radius}},
          setTransformUndo, setTransformRedo)
        markStartingPositionAsDirty(self.startingPosition)
        self._placingWithRotation = false
        self._placementTemp = nil
      end
      return
    end
  else
    -- If Ctrl is released while placing, commit the action
    if self._placingWithRotation and self._placementTemp then
      editor.history:commitAction("Place Starting Position Area",
        {startingPosition = self.startingPosition,
         old = {position = self._placementTemp.oldPosition, rotation = self._placementTemp.oldRotation, radius = self.startingPosition.transform.radius},
         new = {position = self.startingPosition.transform.position, rotation = self.startingPosition.transform.rotation, radius = self.startingPosition.transform.radius}},
        setTransformUndo, setTransformRedo)
      markStartingPositionAsDirty(self.startingPosition)
      self._placingWithRotation = false
      self._placementTemp = nil
    end
  end

  -- Handle transform selection (only if not clicking on gizmo and not placing)
  if not editor.isAxisGizmoHovered() and mouseInfo.down and not editor.keyModifiers.ctrl then
    -- Check if clicking on area position or icon position
    local areaPos = self.startingPosition.transform.position
    local iconPos = self.startingPosition.iconPosition
    local mousePos = mouseInfo._downPos

    if mousePos then
      local areaDist = (mousePos - areaPos):length()
      local iconDist = (mousePos - iconPos):length()

      -- Scale selection radius with camera distance
      local camPos = mouseInfo.camPos
      local areaSelectionRadius = math.sqrt(areaPos:distance(camPos)) * 0.1
      local iconSelectionRadius = math.sqrt(iconPos:distance(camPos)) * 0.1

      if areaDist < areaSelectionRadius then
        self.currentTransform = "area"
        self:updateTransform()
        self:beginDrag()
      elseif iconDist < iconSelectionRadius then
        self.currentTransform = "icon"
        self:updateTransform()
        self:beginDrag()
      else
        self.currentTransform = nil
        self:updateTransform()
      end
    end
  end
end

function C:updateTransform()
  if not self.startingPosition then return end

  if self.currentTransform == "area" then
    local rotation = QuatF(self.startingPosition.transform.rotation.x, self.startingPosition.transform.rotation.y, self.startingPosition.transform.rotation.z, self.startingPosition.transform.rotation.w)
    local transform = rotation:getMatrix()
    transform:setPosition(self.startingPosition.transform.position)
    editor.setAxisGizmoTransform(transform)
  elseif self.currentTransform == "icon" then
    local rotation = QuatF(0, 0, 0, 1)
    local transform = rotation:getMatrix()
    transform:setPosition(self.startingPosition.iconPosition)
    editor.setAxisGizmoTransform(transform)
  end
end

function C:beginDrag()
  if not self.startingPosition then return end

  self._prevGizmoPos = vec3(editor.getAxisGizmoTransform():getColumn(3))

  if self.currentTransform == "area" then
    self._prevTransformPos = deepcopy(self.startingPosition.transform.position)
    self.beginDragRotation = deepcopy(self.startingPosition.transform.rotation)
  elseif self.currentTransform == "icon" then
    self._prevTransformPos = deepcopy(self.startingPosition.iconPosition)
  end
end

function C:dragging()
  if not self.startingPosition then return end

  -- Handle gizmo dragging (for rotation and precise positioning)
  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
    local posOffset = (vec3(editor.getAxisGizmoTransform():getColumn(3)) - self._prevGizmoPos)

    if self.currentTransform == "area" then
      self.startingPosition.transform.position = self.startingPosition.transform.position + posOffset
    elseif self.currentTransform == "icon" then
      self.startingPosition.iconPosition = self.startingPosition.iconPosition + posOffset
    end

    if self.snapToTerrain and self.currentTransform == "area" then
      local newPos, succ = self:dropToTerrain(self.startingPosition.transform.position)
      self.startingPosition.transform.position = newPos
      if not succ then
        self.startingPosition.transform.position.z = self._prevTransformPos.z
      end
    end
  elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate and self.currentTransform == "area" then
    local gizmoTransform = editor.getAxisGizmoTransform()
    local rotation = QuatF(0,0,0,1)
    rotation:setFromMatrix(gizmoTransform)

    if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
      self.startingPosition.transform.rotation = quat(rotation)
    else
      self.startingPosition.transform.rotation = self.beginDragRotation * quat(rotation)
    end
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

function C:endDragging()
  if not self.startingPosition then return end

  if self.snapToTerrain and self.currentTransform == "area" then
    local newPos = self:dropToTerrain(self.startingPosition.transform.position)
    self.startingPosition.transform.position = newPos
  end

  local oldPos = self._prevTransformPos
  local newPos = self.currentTransform == "area" and self.startingPosition.transform.position or self.startingPosition.iconPosition

  if self.currentTransform == "area" then
    editor.history:commitAction("Manipulate Starting Position Area",
      {startingPosition = self.startingPosition, old = {position = oldPos, rotation = self.startingPosition.transform.rotation, radius = self.startingPosition.transform.radius}, new = {position = newPos, rotation = self.startingPosition.transform.rotation, radius = self.startingPosition.transform.radius}},
      setTransformUndo, setTransformRedo)
  elseif self.currentTransform == "icon" then
    editor.history:commitAction("Manipulate Starting Position Icon",
      {startingPosition = self.startingPosition, old = oldPos, new = newPos, field = 'iconPosition'},
      setFieldUndo, setFieldRedo)
  end
end

function C:draw(mouseInfo)
  if not self.startingPosition then return end

  self:input(mouseInfo)

  -- Show visual preview when placing with rotation
  if self._placingWithRotation and self._placementTemp and mouseInfo then
    local txt = "Drag to Set Rotation"
    if mouseInfo.rayCast then
      debugDrawer:drawTextAdvanced(vec3(mouseInfo.rayCast.pos), String(txt), ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 96, 255))
    end

    -- Draw arrow preview showing rotation direction
    if self._placementTemp.moved then
      local pos = self.startingPosition.transform.position
      local rot = self.startingPosition.transform.rotation
      local forwardDir = rot * vec3(0, 1, 0)
      local rightDir = rot * vec3(1, 0, 0)

      -- Draw cross shape
      local crossSize = 1.0
      debugDrawer:drawSquarePrism(
        pos + rightDir * crossSize,
        pos - rightDir * crossSize,
        Point2F(0.2, 0.2),
        Point2F(0.2, 0.2),
        ColorF(1, 1, 1, 0.5))

      -- Draw arrow pointing in forward direction
      local arrowLength = 2.0
      debugDrawer:drawSquarePrism(
        pos + rightDir * 0.3,
        pos + rightDir * 0.3 + forwardDir * arrowLength,
        Point2F(0.2, 0.2),
        Point2F(0.1, 0.1),
        ColorF(0, 1, 0, 0.8))
      debugDrawer:drawSquarePrism(
        pos - rightDir * 0.3,
        pos - rightDir * 0.3 + forwardDir * arrowLength,
        Point2F(0.2, 0.2),
        Point2F(0.1, 0.1),
        ColorF(0, 1, 0, 0.8))
    end
  end

  -- Show gizmo when transform is selected
  if self.currentTransform then
    editor.updateAxisGizmo(function()
      self:beginDrag()
    end, function()
      self:endDragging()
    end, function()
      self:dragging()
    end)
    editor.drawAxisGizmo()
  end

  self:updateTransform()
end

function C:drawStartingPositionIndicators(mouseInfo)
  if not self.startingPosition then
    return
  end

  -- Safety check for mouseInfo
  if not mouseInfo or not mouseInfo.camPos then
    return
  end

  local camPos = mouseInfo.camPos
  local areaPos = self.startingPosition.transform.position
  local iconPos = self.startingPosition.iconPosition

  -- Calculate camera distance-based scaling
  local areaDist = math.sqrt(areaPos:distance(camPos))
  local iconDist = math.sqrt(iconPos:distance(camPos))

  -- Draw actual starting position radius at constant size
  local areaColor = ColorF(0, 1, 0, 0.3) -- Green with transparency
  debugDrawer:drawSphere(areaPos, self.startingPosition.transform.radius, areaColor)

  -- Draw area center point with camera distance scaling (for selection)
  local centerColor = ColorF(0, 1, 0, 0.8)
  debugDrawer:drawSphere(areaPos, areaDist * 0.05, centerColor)

  -- Draw icon position with camera distance scaling (for selection)
  local iconColor = ColorF(1, 1, 0, 0.8) -- Yellow
  debugDrawer:drawSphere(iconPos, iconDist * 0.1, iconColor)

  -- Draw direction arrow to show orientation
  local rotation = self.startingPosition.transform.rotation
  if rotation then
    -- Get forward direction from rotation (Y is forward in BeamNG)
    local forwardDir = rotation * vec3(0, 1, 0)
    local arrowLength = 3.0 -- Arrow length in meters
    local arrowStartPos = areaPos
    local arrowEndPos = areaPos + forwardDir * arrowLength

    -- Arrow sizes: tail is wider, tip is narrower
    local arrowSize1 = Point2F(0.3, 0.3) -- Tail size
    local arrowSize2 = Point2F(0.1, 0.1) -- Tip size
    local arrowColor = ColorF(0, 1, 0, 0.8) -- Green to match area color

    debugDrawer:drawSquarePrism(arrowStartPos, arrowEndPos, arrowSize1, arrowSize2, arrowColor)
  end

  -- Draw text labels
  if self.startingPosition.name then
    debugDrawer:drawTextAdvanced(areaPos, String("Area: " .. self.startingPosition.name), ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 192))
    debugDrawer:drawTextAdvanced(iconPos, String("Icon: " .. self.startingPosition.name), ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 192))
  end
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
