-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local im = ui_imgui
local ffi = require('ffi')

local function setFieldUndo(data)
  local boundary = data.boundary
  if boundary then
    boundary[data.field] = data.old
    if data.field == 'name' then
    elseif data.field == 'vertices' then
      for i, vertex in ipairs(data.old) do
        if boundary.vertices[i] then
          boundary.vertices[i].pos = vertex.pos
        end
      end
      boundary:processVertices()
    end
  end
end

local function setFieldRedo(data)
  local boundary = data.boundary
  if boundary then
    boundary[data.field] = data.new
    if data.field == 'name' then
    elseif data.field == 'vertices' then
      for i, vertex in ipairs(data.new) do
        if boundary.vertices[i] then
          boundary.vertices[i].pos = vertex.pos
        end
      end
      boundary:processVertices()
    end
  end
end

local function addVertexUndo(data)
  if data.boundary then
    data.boundary:removeVertex(data.index)
  end
end

local function addVertexRedo(data)
  if data.boundary then
    data.boundary:addVertex(data.position, data.index)
  end
end

local function manipulateVerticesUndo(data)
  if data.boundary then
    for index, pos in pairs(data.old) do
      if data.boundary.vertices[index] then
        data.boundary.vertices[index].pos = pos
      end
    end
    data.boundary:processVertices()
  end
end

local function manipulateVerticesRedo(data)
  if data.boundary then
    for index, pos in pairs(data.new) do
      if data.boundary.vertices[index] then
        data.boundary.vertices[index].pos = pos
      end
    end
    data.boundary:processVertices()
  end
end

local function teleportCameraTo(pos)
  if not pos then return end
  core_camera.setPosition(0, pos + vec3(0, 0, 15))
end

local function markBoundaryAsDirty(boundary)
  -- The boundary table is the same reference stored in both level and mission lists,
  -- so setting the flag directly works for level and mission boundaries alike.
  if boundary then
    boundary._dirty = true
  end
end

function C:init(crawlEditorParam)
  self.crawlEditor = crawlEditorParam
  self.boundary = nil
  self.currentVertices = {}
  self.currentPlane = nil
  self._prevGizmoPos = vec3(0, 0, 0)
  self._prevVerticesPos = {}
  self.beginDragRotation = quat(1, 0, 0, 0)
  self.snapToTerrain = true
  self.fields = {}
  self.addFieldText = im.ArrayChar(256, "")
end

local lastBoundary = nil
function C:setFields(boundary)
  if not boundary then return end
  self.name = im.ArrayChar(256, boundary.name or "")
  self.fileName = im.ArrayChar(256, boundary._fileName or "")
end
local editEnded = im.BoolPtr(false)

function C:setBoundary(boundaryParam)
  self.boundary = boundaryParam
end

function C:clearSelection()
  self.currentVertices = {}
  self.currentPlane = nil
end

function C:drawBoundariesList(allBoundaries, selection)

  if im.Button("Add Boundary") then
    local newBoundary = self:getNewBoundary()
    table.insert(allBoundaries, newBoundary)
    selection.index = #allBoundaries
  end


  for i, boundary in ipairs(allBoundaries) do
    local isSelected = (i == selection.index)
    local displayName = boundary.name or "Unnamed Boundary"
    local vertexCount = boundary.vertices and #boundary.vertices or 0
    displayName = displayName .. " (" .. vertexCount .. " vertices)"

    if im.Selectable1(displayName, isSelected) then
      if selection.index == i then
        selection.index = -1
      end
      selection.index = i
      selection.clicked = true
    end

    -- Right-click context menu
    if im.BeginPopupContextItem("boundary_context_" .. i) then
      if im.MenuItem1("Delete") then
        table.remove(allBoundaries, i)
        if selection.index >= i then
          selection.index = selection.index - 1
        end
      end
      im.EndPopup()
    end
  end

  if #allBoundaries == 0 then
    im.Text("No boundaries available")
  end
end

function C:drawBoundaryDetail(boundary)
  if not boundary then return end

  if lastBoundary ~= boundary then
    self:setFields(boundary)
    lastBoundary = boundary
  end

  im.Text("Boundary Details")
  im.SameLine()
  local teleportPos = boundary.vertices and boundary.vertices[1] and boundary.vertices[1].pos
  if not teleportPos then im.BeginDisabled() end
  if im.Button("Goto") then
    teleportCameraTo(teleportPos)
  end
  if not teleportPos then im.EndDisabled() end
  im.Separator()

  -- Live boundary stats
  do
    local vertCount = boundary.vertices and #boundary.vertices or 0
    local area = 0
    if boundary.zoneArea and vertCount >= 3 then
      local ok, result = pcall(function() return boundary:zoneArea() end)
      if ok and result then area = result end
    end
    im.Text(string.format("Vertices: %d   Area: %.1f m2", vertCount, area))
    im.Separator()
  end

  im.Text("Name")
  editEnded[0] = false
  editor.uiInputText("##BoundaryName", self.name, nil, nil, nil, nil, editEnded)
  if editEnded[0] then
    boundary.name = ffi.string(self.name)
    markBoundaryAsDirty(boundary)
  end

  im.Separator()
  im.Text("File Name")
  im.SameLine()
  if im.Button("Rename") then
    local newFileName = ffi.string(self.fileName)
    if newFileName ~= boundary._fileName and newFileName ~= "" then
      local oldFilePath = boundary._filePath
      local dir, _, ext = path.splitWithoutExt(oldFilePath, true)
      local newFilePath = dir ..  newFileName .. "." .. ext

      if editor_crawlEditor and editor_crawlEditor.renameObjectFile then
        editor_crawlEditor.renameObjectFile(oldFilePath, newFilePath, "boundary")
      end
    end
  end

  editor.uiInputText("##FileName", self.fileName, nil, nil, nil, nil, nil)

  im.Text("Vertex Count: " .. (#boundary.vertices or 0))
  if boundary.vertices and #boundary.vertices >= 3 then
    local area = boundary:zoneArea()
    im.Text("Area: " .. string.format("%.2f m²", area))
  end



  im.Separator()
  im.Text("Vertices:")
  im.SameLine()
  if im.Button("Add Vertex") then
    local pos = vec3(0, 0, 0)
    if #boundary.vertices > 0 then
      local lastVertex = boundary.vertices[#boundary.vertices]
      pos = lastVertex.pos + vec3(10, 0, 0)
    end
    boundary:addVertex(pos)
    markBoundaryAsDirty(boundary)
  end

  im.SameLine()
  if im.Button("Remove Selected") then
    local verticesToDelete = {}
    for i, vertex in ipairs(boundary.vertices) do
      if vertex.selected then
        table.insert(verticesToDelete, {index = i, vertex = vertex})
      end
    end
    for i = #verticesToDelete, 1, -1 do
      boundary:removeVertex(verticesToDelete[i].index)
    end
    markBoundaryAsDirty(boundary)
  end

  im.Separator()

  if im.Button("Auto Planes") then
    local oldState = boundary:onSerialize()
    boundary:autoPlanes()
    editor.history:commitAction("Auto Planes",
      {boundary = boundary, old = oldState, new = boundary:onSerialize()},
      function(data)
        boundary:onDeserialized(data.old)
      end,
      function(data)
        boundary:onDeserialized(data.new)
        markBoundaryAsDirty(data.boundary)
      end)
  end

  im.SameLine()
  if im.Button("High Res Fence") then
    local oldState = boundary:onSerialize()
    boundary:makeHighResolutionFence()
    editor.history:commitAction("High Resolution Fence",
      {boundary = boundary, old = oldState, new = boundary:onSerialize()},
      function(data)
        boundary:onDeserialized(data.old)
      end,
      function(data)
        boundary:onDeserialized(data.new)
        markBoundaryAsDirty(data.boundary)
      end)
  end

  im.Separator()

  if im.Button("Create Decal Road") then
    if boundary.vertices and #boundary.vertices >= 3 then
      local decalRoad = createObject("DecalRoad")
      decalRoad:setField("material", 0, "a_asphalt_01_a")
      decalRoad:setField("looped", 0, "1")
      decalRoad:setField("smoothness", 0, "0.1")
      decalRoad:setField("improvedSpline", 0, "true")
      decalRoad:setField("overObjects", 0, "true")
      decalRoad:setField("drivability", 0, "1.0")

      local roadName = boundary.name and (boundary.name .. "_decal_road") or "boundary_decal_road"
      decalRoad:registerObject(roadName)
      editor.updateRoadVertices(decalRoad)
      scenetree.MissionGroup:add(decalRoad)

      for i, vertex in ipairs(boundary.vertices) do
        editor.addRoadNode(decalRoad:getID(), {
          pos = vertex.pos,
          width = 0.1,
          index = i-1
        })
      end

      log('I', 'BoundaryEditor', "Created decal road from boundary: " .. roadName)
    else
      log('W', 'BoundaryEditor', "Cannot create decal road: boundary needs at least 3 vertices")
    end
  end

  im.Separator()

  im.Text("Height Limits:")
  im.NewLine()

  local topActive = im.BoolPtr(boundary.top.active)
  im.Checkbox("Top Limit", topActive)
  if topActive[0] ~= boundary.top.active then
    editor.history:commitAction("Toggle Top Limit",
      {boundary = boundary, old = boundary.top.active, new = topActive[0], plane = 'top'},
      function(data)
        data.boundary[data.plane].active = data.old
      end,
      function(data)
        data.boundary[data.plane].active = data.new
        markBoundaryAsDirty(data.boundary)
      end)
  end

  if boundary.top.active then
    im.SameLine()
    im.Text("Height: " .. string.format("%.2f", boundary.top.pos.z))
    self.currentPlane = boundary.top
  end

  im.NewLine()

  local botActive = im.BoolPtr(boundary.bot.active)
  im.Checkbox("Bottom Limit", botActive)
  if botActive[0] ~= boundary.bot.active then
    editor.history:commitAction("Toggle Bottom Limit",
      {boundary = boundary, old = boundary.bot.active, new = botActive[0], plane = 'bot'},
      function(data)
        data.boundary[data.plane].active = data.old
      end,
      function(data)
        data.boundary[data.plane].active = data.new
        markBoundaryAsDirty(data.boundary)
      end)
  end

  if boundary.bot.active then
    im.SameLine()
    im.Text("Height: " .. string.format("%.2f", boundary.bot.pos.z))
    self.currentPlane = boundary.bot
  end

  im.Separator()

  -- Debug info
  if self.mouseInfo and self.mouseInfo.rayCast and self.mouseInfo.rayCast.pos then
    local pos = self.mouseInfo.rayCast.pos
    local inside = boundary:containsPoint2D(pos)
    im.Text("Mouse Position: " .. string.format("%.2f, %.2f, %.2f", pos.x, pos.y, pos.z))
    im.Text("Inside Boundary: " .. (inside and "Yes" or "No"))
  end

  im.Separator()

  self:drawCustomFields(boundary.customFields or {})
  -- Note: the boundary fence is drawn by the editor's always-draw pass to avoid double-drawing.
end

function C:getNewBoundary()
  return require('/lua/ge/extensions/gameplay/sites/zone')(nil, "New Boundary")
end

function C:findVert(mouseInfo, objects)
  local minNodeDist = 4294967295
  local closest = nil
  local clrF = ColorF(1, 1, 1, 0.75)
  local clrSelected = ColorF(0.91, 0.49, 0.24, 0.75)

  for idx, obj in pairs(objects) do
    local distNodeToCam = (obj.pos - mouseInfo.camPos):length()
    local nodeRayDistance = (obj.pos - mouseInfo.camPos):cross(mouseInfo.rayDir):length() / mouseInfo.rayDir:length()
    local sphereRadius = (mouseInfo.camPos - obj.pos):length() / 40

    local selected = false
    for _, vertex in ipairs(self.currentVertices) do
      if vertex.index == idx then
        selected = true
        break
      end
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
  if not self.boundary or #self.boundary.vertices < 2 then
    return
  end

  local objs = {}
  for i, v in ipairs(self.boundary.vertices) do
    local nextIdx = v.next or (i == #self.boundary.vertices and 1 or i + 1)
    table.insert(objs, {
      pos = (v.pos + self.boundary.vertices[nextIdx].pos) / 2,
      radius = 3,
      orig = i
    })
  end

  local hit = self:findVert(mouseInfo, objs)
  if hit and mouseInfo.down then
    editor.history:commitAction("Insert Boundary Vertex",
      {boundary = self.boundary, position = hit.pos, index = hit.orig + 1},
      addVertexUndo, addVertexRedo)
  end
end

function C:input(mouseInfo)
  if not self.boundary then return end

  if editor.keyModifiers.shift then
    if not editor.isAxisGizmoHovered() and mouseInfo.down then
      local newIndex = #self.boundary.vertices + 1
      editor.history:commitAction("Add Boundary Vertex",
        {boundary = self.boundary, position = mouseInfo._downPos, index = newIndex},
        addVertexUndo, addVertexRedo)
    end
  elseif editor.keyModifiers.alt then
    self:tryInsert(mouseInfo)
  else
    local objects = {}
    for i, vertex in ipairs(self.boundary.vertices) do
      table.insert(objects, {
        pos = vertex.pos,
        index = i,
        radius = (mouseInfo.camPos - vertex.pos):length() / 40
      })
    end

    local hit = self:findVert(mouseInfo, objects)
    if not editor.isAxisGizmoHovered() and mouseInfo.down then
      if editor.keyModifiers.ctrl then
        if hit then
          table.insert(self.currentVertices, hit)
        end
      else
        if hit then
          self.currentVertices = { hit }
        else
          self.currentVertices = {}
        end
      end

      self.currentPlane = nil
      self:updateTransform()
    end
  end
end

function C:updateTransform()
  if not self.boundary then return end

  local transform = QuatF(0, 0, 0, 0):getMatrix()
  if #self.currentVertices > 0 then
    local centroid = vec3(0, 0, 0)
    for _, vertex in ipairs(self.currentVertices) do
      centroid = centroid + vertex.pos
    end
    centroid = centroid / #self.currentVertices
    transform:setPosition(centroid)
  end

  if self.currentPlane then
    local rotation
    if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
      local q = quatFromDir(quatFromEuler(0, math.pi / 2, 0) * self.currentPlane.normal, vec3(0, 0, 1))
      rotation = QuatF(q.x, q.y, q.z, q.w)
    else
      rotation = QuatF(0, 0, 0, 1)
    end
    transform = rotation:getMatrix()
    transform:setPosition(self.currentPlane.pos)
  end

  editor.setAxisGizmoTransform(transform)
end

function C:beginDrag()
  self._prevGizmoPos = vec3(editor.getAxisGizmoTransform():getColumn(3))

  self._prevVerticesPos = {}
  for _, vertex in ipairs(self.currentVertices) do
    self._prevVerticesPos[vertex.index] = deepcopy(vertex.pos)
  end

  if self.currentPlane then
    self.beginDragRotation = deepcopy(quatFromDir(quatFromEuler(0, math.pi / 2, 0) * self.currentPlane.normal, vec3(0, 0, 1)))
  end
end

function C:dragging()
  if not self.boundary then return end

  local posOffset = (vec3(editor.getAxisGizmoTransform():getColumn(3)) - self._prevGizmoPos) / 2

  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
    if #self.currentVertices > 0 then
      for i, vertex in ipairs(self.currentVertices) do
        self.boundary.vertices[vertex.index].pos = self.boundary.vertices[vertex.index].pos + posOffset
        vertex.pos = vertex.pos + posOffset
        if self.snapToTerrain then
          local newPos, succ = self:dropToTerrain(self.boundary.vertices[vertex.index].pos)
          self.boundary.vertices[vertex.index].pos = newPos
          vertex.pos = newPos
          if not succ then
            self.boundary.vertices[vertex.index].pos.z = self._prevVerticesPos[vertex.index].z
            vertex.pos.z = self._prevVerticesPos[vertex.index].z
          end
          debugDrawer:drawLine((vertex.pos + vec3(0, 0, -1000)), (vertex.pos + vec3(0, 0, 1000)), ColorF(0, 0, 1, 1))
        end
      end
      self.boundary:processVertices()
    end

    if self.currentPlane then
      self.currentPlane.pos = vec3(editor.getAxisGizmoTransform():getColumn(3))
    end
    self:updateTransform()

  elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then
    if #self.currentVertices > 1 then
      local centroid = vec3(0, 0, 0)
      for _, vertex in ipairs(self.currentVertices) do
        centroid = centroid + vertex.pos
      end
      centroid = centroid / #self.currentVertices

      for i, vertex in ipairs(self.currentVertices) do
        local gizmoTransform = editor.getAxisGizmoTransform()
        local rotation = QuatF(0, 0, 0, 1)
        rotation:setFromMatrix(gizmoTransform)

        local diff = self._prevVerticesPos[vertex.index] - centroid
        diff = diff:rotated(quat(rotation))
        local newPos = centroid + diff
        self.boundary.vertices[vertex.index].pos = newPos
        vertex.pos = newPos
      end
      self.boundary:processVertices()
    end

    if self.currentPlane then
      local gizmoTransform = editor.getAxisGizmoTransform()
      local rotation = QuatF(0, 0, 0, 1)
      rotation:setFromMatrix(gizmoTransform)

      if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
        self.currentPlane.normal = quat(rotation) * vec3(0, 0, 1)
      else
        self.currentPlane.normal = self.beginDragRotation * quat(rotation) * vec3(0, 0, 1)
      end
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
  if not self.boundary then return end

  if self.snapToTerrain then
    for _, vertex in ipairs(self.currentVertices) do
      local newPos = self:dropToTerrain(vertex.pos)
      self.boundary.vertices[vertex.index].pos = newPos
      vertex.pos = newPos
    end
  end

  if #self.currentVertices > 0 then
    local oldPositions = {}
    local newPositions = {}

    for _, vertex in ipairs(self.currentVertices) do
      oldPositions[vertex.index] = self._prevVerticesPos[vertex.index]
      newPositions[vertex.index] = vertex.pos
    end

    editor.history:commitAction("Manipulate Boundary Vertices",
      {boundary = self.boundary, old = oldPositions, new = newPositions},
      manipulateVerticesUndo, manipulateVerticesRedo)

    markBoundaryAsDirty(self.boundary)
  end

  self.boundary:processVertices()
end

function C:draw(mouseInfo)
  if not self.boundary then return end
  self.mouseInfo = mouseInfo
  editor.updateAxisGizmo(function()
    self:beginDrag()
  end, function()
    self:endDragging()
  end, function()
    self:dragging()
  end)
  editor.drawAxisGizmo()
  self:input(mouseInfo)
  self:updateTransform()
end

function C:drawBoundaryEditor()
  if not self.boundary then
    im.Text("No boundary selected")
    return
  end

  self:drawBoundaryDetail(self.boundary)
end

function C:drawCustomFields(fields)
  if not fields.names then
    fields.names = {}
    fields.types = {}
    fields.values = {}
  end

  local remove
  for i, name in ipairs(fields.names) do
    if fields.types[name] == 'string' then
      if not self.fields[name] then self.fields[name] = im.ArrayChar(4096, fields.values[name]) end
      local editEnded = im.BoolPtr(false)
      editor.uiInputText(name, self.fields[name], nil, nil, nil, nil, editEnded)
      if editEnded[0] then
        fields.values[name] = ffi.string(self.fields[name])

        markBoundaryAsDirty(self.boundary)
      end
    elseif fields.types[name] == 'number' then
      if not self.fields[name] then self.fields[name] = im.FloatPtr(fields.values[name]) end

      local editEnded = im.BoolPtr(false)
      editor.uiInputFloat(name, self.fields[name], nil, nil, nil, nil, editEnded)
      if editEnded[0] then
        fields.values[name] = (self.fields[name])[0]

        markBoundaryAsDirty(self.boundary)
      end

    elseif fields.types[name] == 'vec3' then
      debugDrawer:drawTextAdvanced((fields.values[name]),
        String(name),
        ColorF(1,1,1,1),true, false,
        ColorI(0,0,0,1*255))
      debugDrawer:drawSphere((fields.values[name]), 1, ColorF(1,0,0,0.5))
      if not self.fields[name] then
        self.fields[name] = im.ArrayFloat(3)
        self.fields[name][0] = fields.values[name].x
        self.fields[name][1] = fields.values[name].y
        self.fields[name][2] = fields.values[name].z
      end
      local editEnded = im.BoolPtr(false)
      editor.uiInputFloat3(name, self.fields[name], nil, nil, editEnded)
      if editEnded[0] then
        local tbl = {self.fields[name][0],self.fields[name][1],self.fields[name][2]}
        fields.values[name] = vec3(tbl)

        markBoundaryAsDirty(self.boundary)
      end
    end
    im.SameLine()
    if im.SmallButton("X##"..i) then
      remove = name
      self.fields[name] = nil
    end
  end
  if remove then
    fields:remove(remove)

    markBoundaryAsDirty(self.boundary)
  end

  editor.uiInputText("##new", self.addFieldText)
  if im.Button("New String") then
    fields:add(ffi.string(self.addFieldText),'string',"value")
    self.addFieldText = im.ArrayChar(256,"")

    markBoundaryAsDirty(self.boundary)
  end
  im.SameLine()
  if im.Button("New Number") then
    fields:add(ffi.string(self.addFieldText),'number',0)
    self.addFieldText = im.ArrayChar(256,"")

    markBoundaryAsDirty(self.boundary)
  end
  im.Separator()
  if im.Button("Copy Fields") then
    self.cfData = fields:onSerialize()
  end
  im.tooltip("Copies the custom fields of this object to use for other objects.")
  im.SameLine()
  if not self.cfData then
    im.BeginDisabled()
  end
  if im.Button("Paste Fields") then
    fields:onDeserialized(self.cfData)

    markBoundaryAsDirty(self.boundary)
  end
  if not self.cfData then
    im.EndDisabled()
  end
  im.tooltip("Pastes the stored custom fields into this object.")
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end