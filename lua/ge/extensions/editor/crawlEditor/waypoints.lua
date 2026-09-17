-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local im = ui_imgui
local ffi = require('ffi')



local function setFieldUndo(data)
  local node = data.self.path.pathnodes.objects[data.index]
  if node then
    node[data.field] = data.old
    if data.field == 'radius' then
      node:setManual(node.pos, data.old, node.normal)
    end
    data.self:updateTransform(data.index)
  end
end

local function setFieldRedo(data)
  local node = data.self.path.pathnodes.objects[data.index]
  if node then
    node[data.field] = data.new
    if data.field == 'radius' then
      node:setManual(node.pos, data.new, node.normal)
    end
    data.self:updateTransform(data.index)
  end
end

function C:init(crawlEditorParam)
  self.crawlEditor = crawlEditorParam
  self.path = nil
  self.index = -1
  self.mouseInfo = {}
  self.fields = {}
  self.beginDragNodeData = nil
  self.beginDragRotation = quat(1, 0, 0, 0)
  self.beginDragRadius = 1.0
end

function C:setPath(pathParam)
  self.path = pathParam
end

function C:selectPathnode(id)
  if not id then return end
  self.index = id
  if not self.path or not self.path.pathnodes or not self.path.pathnodes.objects then
    self.fields = {}
    return
  end

  for _, node in pairs(self.path.pathnodes.objects) do
    node._drawMode = (id == node.id) and 'highlight' or 'normal'
  end
  if id then
    self:updateTransform(id)
  end
  self.fields = {}
end

function C:updateTransform(index)
  if not self.crawlEditor.allowGizmo() then return end
  if not self.path or not self.path.pathnodes or not self.path.pathnodes.objects then return end
  local node = self.path.pathnodes.objects[index]
  if not node then return end

  local rotation = QuatF(0,0,0,1)
  if node.hasNormal then
    if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
      local q = quatFromDir(node.normal, vec3(0,0,1))
      rotation = QuatF(q.x, q.y, q.z, q.w)
    else
      rotation = QuatF(0, 0, 0, 1)
    end
  end

    local transform = rotation:getMatrix()
  transform:setPosition(node.pos)
  editor.setAxisGizmoTransform(transform)
end

function C:beginDrag()
  if not self.path or not self.path.pathnodes or not self.path.pathnodes.objects then return end
  local node = self.path.pathnodes.objects[self.index]
  if not node or node.missing then return end
  self.beginDragNodeData = node:onSerialize()
  if node.hasNormal and node.normal then
    self.beginDragRotation = deepcopy(quatFromDir(node.normal, vec3(0,0,1)))
  end
  self.beginDragRadius = node.radius
end

function C:dragging()
  if not self.path or not self.path.pathnodes or not self.path.pathnodes.objects then return end
  local node = self.path.pathnodes.objects[self.index]
  if not node or node.missing then return end

  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
    node.pos = vec3(editor.getAxisGizmoTransform():getColumn(3))
  elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then
    if not node.hasNormal then
      return
    else
      local gizmoTransform = editor.getAxisGizmoTransform()
      local rotation = QuatF(0,0,0,1)
      if node.normal then
        rotation:setFromMatrix(gizmoTransform)

        if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
          local newNormal = quat(rotation)*vec3(0,1,0)
          node:setNormal(newNormal)
        else
          local newNormal = self.beginDragRotation * quat(rotation)*vec3(0,1,0)
          node:setNormal(newNormal)
        end
      end
    end
  elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Scale then
    local sclVec = vec3(worldEditorCppApi.getAxisGizmoScale())
    local scl = 1
    if sclVec.x ~= 1 then
      scl = sclVec.x
    elseif sclVec.y ~= 1 then
      scl = sclVec.y
    elseif sclVec.z ~= 1 then
      scl = sclVec.z
    end
    if scl < 0 then
      scl = 0
    end
    node:setManual(node.pos, self.beginDragRadius * scl, node.normal)
  end
end

function C:endDragging()
  if not self.path or not self.path.pathnodes or not self.path.pathnodes.objects then return end
  local node = self.path.pathnodes.objects[self.index]
  if not node or node.missing then return end
      editor.history:commitAction("Manipulated Pathnode via Gizmo",
    {old = self.beginDragNodeData,
     new = node:onSerialize(),
     index = self.index, self = self},
    function(data)
      local node = data.self.path.pathnodes.objects[data.index]
      node:onDeserialized(data.old)
      data.self:selectPathnode(data.index)
    end,
    function(data)
      local node = data.self.path.pathnodes.objects[data.index]
      node:onDeserialized(data.new)
      data.self:selectPathnode(data.index)
    end)
end

function C:selectedPathnode()
  if not self.index then return nil end
  if not self.path or not self.path.pathnodes or not self.path.pathnodes.objects then return nil end
  local node = self.path.pathnodes.objects[self.index]
  if not node or node.missing then return nil end
  return node
end

function C:handleMouseDown(hovered)
  if not self.path or not self.path.pathnodes or not self.path.pathnodes.objects then return end

  if hovered then
    self:selectPathnode(hovered.id)
  else
    if not editor.isAxisGizmoHovered() then
      self:selectPathnode(nil)
    end
  end
end

function C:createManualPathnode()
  if not self.path or not self.path.pathnodes then
    return
  end

  if not self.mouseInfo.rayCast then
    return
  end

  local txt = "Add manual Pathnode (Click to place)"
  debugDrawer:drawTextAdvanced(vec3(self.mouseInfo.rayCast.pos), String(txt), ColorF(1,1,1,1), true, false, ColorI(0,0,0,255))

  if self.mouseInfo.down then
    local bestId = self.path.pathnodes.sorted[#self.path.pathnodes.sorted] and self.path.pathnodes.sorted[#self.path.pathnodes.sorted].id
    local radius = 5.0

    editor.history:commitAction("Create Manual Pathnode",
    {mouseInfo = deepcopy(self.mouseInfo), index = bestId, radius = radius, self = self},
    function(data)
      if data.nodeId then
        data.self.path.pathnodes:remove(data.nodeId)
      end
      if data.segId then
        data.self.path.segments:remove(data.segId)
      end
      data.self:selectPathnode(data.index)
    end,
    function(data)
      local node = data.self.path.pathnodes:create(nil, data.nodeId or nil)
      data.nodeId = node.id
      node:setManual(data.mouseInfo.rayCast.pos, data.radius, nil)
      node.name = "Pathnode"
      if data.index ~= nil then
        local seg = data.self.path.segments:create(nil, data.segId or nil)
        seg:setFrom(data.index)
        seg:setTo(node.id)
        data.segId = seg.id
      end
      data.self:selectPathnode(node.id)
    end)
  end
end

function C:mouseOverPathnodes()
  if not self.path or not self.path.pathnodes or not self.path.pathnodes.objects then
    return nil
  end

  local minNodeDist = 4294967295
  local closestNode = nil
  for idx, node in pairs(self.path.pathnodes.objects) do
    if node.pos then
      local distNodeToCam = (node.pos - self.mouseInfo.camPos):length()
      local nodeRayDistance = (node.pos - self.mouseInfo.camPos):cross(self.mouseInfo.rayDir):length() / self.mouseInfo.rayDir:length()

      local selectionRadius = 1.0

      if nodeRayDistance <= selectionRadius then
        if distNodeToCam < minNodeDist then
          minNodeDist = distNodeToCam
          closestNode = node
        end
      end
    end
  end
  return closestNode
end

function C:drawPathnodeSelectionIndicators()
  if not self.path or not self.path.pathnodes or not self.path.pathnodes.objects then
    return
  end

  local selectedPathnode = self:selectedPathnode()
  local isPathnodeMode = editor.editMode and editor.editMode.displayName == "Edit Pathnodes"

  for idx, node in pairs(self.path.pathnodes.objects) do
    if node.pos then
      if selectedPathnode and node.id == selectedPathnode.id then
        node._drawMode = 'highlight'
      elseif isPathnodeMode then
        node._drawMode = 'normal'
      else
        node._drawMode = 'faded'
      end

      node:drawDebug(node._drawMode)
    end
  end

  self:drawPathnodeSegments()

  if selectedPathnode then
    debugDrawer:drawTextAdvanced(vec3(10, 10, 0), String("Selected Pathnode: " .. selectedPathnode.name .. " " .. selectedPathnode.id), ColorF(1, 1, 1, 1), false, false, ColorI(0, 0, 0, 255))
  else
    debugDrawer:drawTextAdvanced(vec3(10, 10, 0), String("No pathnode selected"), ColorF(1, 1, 1, 1), false, false, ColorI(0, 0, 0, 255))
  end
end

function C:drawPathnodeSegments()
  if not self.path or not self.path.pathnodes or not self.path.pathnodes.sorted then
    return
  end

  local sortedPathnodes = self.path.pathnodes.sorted
  if #sortedPathnodes < 2 then
    return
  end

  local isPathnodeMode = editor.editMode and editor.editMode.displayName == "Edit Pathnodes"
  local segmentColor, textColor, textBgColor

  if isPathnodeMode then
    segmentColor = ColorF(0.5, 0.5, 1.0, 0.6)
    textColor = ColorF(1, 1, 1, 0.8)
    textBgColor = ColorI(0, 0, 0, 200)
  else
    segmentColor = ColorF(0.5, 0.5, 1.0, 0.3)
    textColor = ColorF(1, 1, 1, 0.4)
    textBgColor = ColorI(0, 0, 0, 100)
  end

  for i = 1, #sortedPathnodes - 1 do
    local fromNode = sortedPathnodes[i]
    local toNode = sortedPathnodes[i + 1]

    if fromNode.pos and toNode.pos then
      debugDrawer:drawSquarePrism(
        fromNode.pos,
        toNode.pos,
        Point2F(2, 4),
        Point2F(0, 0),
        segmentColor
      )

      local midPoint = (fromNode.pos + toNode.pos) / 2
      local segmentName = string.format("Segment %d-%d", fromNode.id, toNode.id)
      debugDrawer:drawTextAdvanced(
        midPoint,
        String(segmentName),
        textColor,
        true,
        false,
        textBgColor
      )
    end
  end
end

function C:draw(mouseInfo)
  self.mouseInfo = mouseInfo
  if self.crawlEditor.allowGizmo() then
    editor.updateAxisGizmo(function() self:beginDrag() end, function() self:endDragging() end, function() self:dragging() end)
    self:input()
  end
end

function C:input()
  if not self.mouseInfo.valid then return end

  if not self.path or not self.path.pathnodes then
    return
  end

  self:drawPathnodeSelectionIndicators()

  if editor.keyModifiers.shift then
    self:createManualPathnode()
    return
  end

  local selected = self:mouseOverPathnodes()

  if selected then
    local hoverColor = ColorF(1, 1, 1, 0.9)
    debugDrawer:drawSphere(selected.pos, 1.0, hoverColor)

    if not self:selectedPathnode() or selected.id ~= self:selectedPathnode().id then
      debugDrawer:drawTextAdvanced(self.mouseInfo.rayCast.pos, String("Click to select pathnode"), ColorF(0,0,0,1), true, false, ColorI(255,255,255,255))
    end
  end

  if self.mouseInfo.down then
    self:handleMouseDown(selected)
  end
end

function C:drawPathnodeList(trail)
  if not trail or not trail.path then return end

  local hasPathnodes = trail.path.pathnodes.sorted and #trail.path.pathnodes.sorted > 0
  local hasSelectedPathnode = self.index and trail.path.pathnodes.objects[self.index]

  im.Text("Pathnodes:")
  im.SameLine()
  if im.Button("Add Pathnode") then
    local newPathnode = trail.path.pathnodes:create()
    newPathnode:setManual(core_camera.getPosition(), 5.0, nil)
    newPathnode.name = "Pathnode"
    self:selectPathnode(newPathnode.id)
  end

  if hasPathnodes and hasSelectedPathnode then
    im.SameLine()
    if im.Button("Remove Pathnode") then
      if self.index and trail.path.pathnodes.objects[self.index] then
        local deletedIndex = self.index
        local sortedWaypoints = trail.path.pathnodes.sorted
        local currentPosition = nil
        local nextIndex = nil

        for i, pathnode in ipairs(sortedWaypoints) do
          if pathnode.id == deletedIndex then
            currentPosition = i
            break
          end
        end

        if #sortedWaypoints > 1 then
          if currentPosition and currentPosition < #sortedWaypoints then
            nextIndex = sortedWaypoints[currentPosition + 1].id
          elseif currentPosition and currentPosition > 1 then
            nextIndex = sortedWaypoints[currentPosition - 1].id
          end
        end

        trail.path.pathnodes:remove(self.index)

        if nextIndex and trail.path.pathnodes.objects[nextIndex] then
          self:selectPathnode(nextIndex)
        else
          self:selectPathnode(nil)
        end
      end
    end

    im.SameLine()
    if im.Button("↑##waypointUp") then
      if self.index and trail.path.pathnodes.objects[self.index] then
        trail.path.pathnodes:move(self.index, -1)
      end
    end
    im.SameLine()
    if im.Button("↓##waypointDown") then
      if self.index and trail.path.pathnodes.objects[self.index] then
        trail.path.pathnodes:move(self.index, 1)
      end
    end
  end

  im.Separator()

  for i, pathnode in ipairs(trail.path.pathnodes.sorted) do
    local isSelected = pathnode.id == self.index
    local displayText = string.format("%s %d", pathnode.name, i)

    if pathnode.isRecovery then
      displayText = "[Recovery] " .. displayText
    end

    if im.Selectable1(displayText, isSelected) then
      self:selectPathnode(pathnode.id)
    end

    if im.IsItemHovered() then
      im.BeginTooltip()
      if pathnode.missing or not pathnode.pos then
        im.Text("Invalid or missing pathnode")
      else
        im.Text(string.format("Position: (%.1f, %.1f, %.1f)", pathnode.pos.x, pathnode.pos.y, pathnode.pos.z))
        im.Text(string.format("Radius: %.1f", pathnode.radius))
        if pathnode.isRecovery then
          im.Text("Type: Recovery Point")
        else
          im.Text("Type: Normal")
        end
      end
      im.EndTooltip()
    end
  end
end

function C:drawPathnodeDetail(pathnode, index)
  if not pathnode then return end

  local sequentialIndex = 1
  if self.path and self.path.pathnodes and self.path.pathnodes.sorted then
    for i, node in ipairs(self.path.pathnodes.sorted) do
      if node.id == index then
        sequentialIndex = i
        break
      end
    end
  end

  if pathnode.missing or not pathnode.pos then
    im.Text("Pathnode " .. sequentialIndex .. " Details")
    im.Separator()
    im.TextColored(im.ImVec4(1, 0, 0, 1), "Invalid or missing pathnode")
    return
  end

  if self.crawlEditor.allowGizmo() then
    editor.drawAxisGizmo()
  end

  im.Text("Pathnode " .. sequentialIndex .. " Details")
  im.Separator()

  local pathnodeNameText = im.ArrayChar(256, pathnode.name or "")
  local editEnded = im.BoolPtr(false)
  editor.uiInputText("Name", pathnodeNameText, nil, nil, nil, nil, editEnded)
  if editEnded[0] then
    editor.history:commitAction("Change Name of Pathnode",
      {index = index, old = pathnode.name, new = ffi.string(pathnodeNameText), field = 'name', self = self},
      setFieldUndo, setFieldRedo)
  end

  local pathnodePosition = im.ArrayFloat(3)
  pathnodePosition[0] = pathnode.pos.x
  pathnodePosition[1] = pathnode.pos.y
  pathnodePosition[2] = pathnode.pos.z
  if im.InputFloat3("Position", pathnodePosition, "%.1f", im.InputTextFlags_EnterReturnsTrue) then
    editor.history:commitAction("Change Pathnode Position",
      {index = index, old = pathnode.pos, new = vec3(pathnodePosition[0], pathnodePosition[1], pathnodePosition[2]), field = 'pos', self = self},
      setFieldUndo, setFieldRedo)
  end

  if scenetree.findClassObjects("TerrainBlock") and im.Button("Down to Terrain") then
    editor.history:commitAction("Drop Pathnode to Ground",
      {index = index, old = pathnode.pos, self = self, new = vec3(pathnodePosition[0], pathnodePosition[1], core_terrain.getTerrainHeight(pathnode.pos)), field = 'pos'},
      setFieldUndo, setFieldRedo)
  end

  local pathnodeRadius = im.FloatPtr(pathnode.radius or 5.0)
  if im.InputFloat("Radius", pathnodeRadius, 0.1, 1.0, "%.1f", im.InputTextFlags_EnterReturnsTrue) then
    if pathnodeRadius[0] < 0 then
      pathnodeRadius[0] = 0
    end
    local oldPos = pathnode.pos
    local oldNormal = pathnode.normal
    pathnode:setManual(oldPos, pathnodeRadius[0], oldNormal)
    editor.history:commitAction("Change Pathnode Radius",
      {index = index, old = pathnode.radius, new = pathnodeRadius[0], field = 'radius', self = self},
      setFieldUndo, setFieldRedo)
  end

  local isRecovery = im.BoolPtr(pathnode.isRecovery or false)
  if im.Checkbox("Is Recovery Point", isRecovery) then
    editor.history:commitAction("Change Pathnode Recovery Status",
      {index = index, old = pathnode.isRecovery, new = isRecovery[0], field = 'isRecovery', self = self},
      setFieldUndo, setFieldRedo)
  end

  im.Separator()
  im.Text("Custom Fields")
  self:drawCustomFields(pathnode.customFields or {})
end

function C:getSelectedPathnodeIndex()
  return self.index
end

function C:setSelectedPathnodeIndex(indexParam)
  self.index = indexParam
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
      end
    elseif fields.types[name] == 'number' then
      if not self.fields[name] then self.fields[name] = im.FloatPtr(fields.values[name]) end

      local editEnded = im.BoolPtr(false)
      editor.uiInputFloat(name, self.fields[name], nil, nil, nil, nil, editEnded)
      if editEnded[0] then
        fields.values[name] = (self.fields[name])[0]
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
  end

  if not self.addFieldText then
    self.addFieldText = im.ArrayChar(256, "")
  end
  editor.uiInputText("##new", self.addFieldText)
  if im.Button("New String") then
    fields:add(ffi.string(self.addFieldText),'string',"value")
    self.addFieldText = im.ArrayChar(256,"")
  end
  im.SameLine()
  if im.Button("New Number") then
    fields:add(ffi.string(self.addFieldText),'number',0)
    self.addFieldText = im.ArrayChar(256,"")
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