-- Zone editing for drag strip zone and lane zones (crawl boundary-style).
-- Uses gameplay/sites/zone and same vertex manipulation as crawl boundaries.

local ZoneClass = require('/lua/ge/extensions/gameplay/sites/zone')
local state = require('/lua/ge/extensions/editor/dragRaceEditor/state')
local utils = require('/lua/ge/extensions/editor/dragRaceEditor/utils')

local C = {}

local function manipulateVerticesUndo(data)
  if data.zone then
    for index, pos in pairs(data.old) do
      if data.zone.vertices[index] then
        data.zone.vertices[index].pos = vec3(pos)
      end
    end
    data.zone:processVertices()
  end
end

local function manipulateVerticesRedo(data)
  if data.zone then
    for index, pos in pairs(data.new) do
      if data.zone.vertices[index] then
        data.zone.vertices[index].pos = vec3(pos)
      end
    end
    data.zone:processVertices()
  end
end

local function addVertexUndo(data)
  if data.zone then data.zone:removeVertex(data.index) end
end

local function addVertexRedo(data)
  if data.zone then data.zone:addVertex(data.position, data.index) end
end

--- Build Zone instance from serialized zone data (strip.stripZone or lane.zone table). Allows empty vertices for editor.
function C.zoneFromData(data)
  if not data then return nil end
  local safe = deepcopy(data)
  safe.vertices = safe.vertices or {}
  safe.customFields = safe.customFields or {}
  local zone = ZoneClass(nil, safe.name or "Zone")
  zone:onDeserialized(safe)
  return zone
end

--- Serialize Zone to table (for writing back to strip/lane).
function C.zoneToData(zone)
  if not zone or not zone.onSerialize then return nil end
  return zone:onSerialize()
end

function C:init()
  self.zone = nil
  self.target = nil
  self.currentVertices = {}
  self.currentPlane = nil
  self._prevGizmoPos = vec3(0, 0, 0)
  self._prevVerticesPos = {}
  self.beginDragRotation = quat(1, 0, 0, 0)
  self.snapToTerrain = true
end

function C:setZone(zoneInstance, target)
  self.zone = zoneInstance
  self.target = target
  self.currentVertices = {}
  self.currentPlane = nil
end

function C:clearZone()
  self.zone = nil
  self.target = nil
  self.currentVertices = {}
  self.currentPlane = nil
end

--- Write zone back to strip.stripZone or lane.zone and mark strip dirty.
function C:syncBack()
  if not self.zone or not self.target then return end
  local serialized = C.zoneToData(self.zone)
  if not serialized then return end
  local t = self.target
  if t.type == 'stripZone' and t.strip then
    t.strip.stripZone = serialized
    t.strip._dirty = true
    utils.markUnsavedChanges()
  elseif t.type == 'laneZone' and t.strip and t.lane then
    t.lane.zone = serialized
    t.strip._dirty = true
    utils.markUnsavedChanges()
  end
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
      if vertex.index == idx then selected = true break end
    end

    if selected then
      debugDrawer:drawSphere(obj.pos, sphereRadius, clrSelected)
    else
      debugDrawer:drawSphere(obj.pos, sphereRadius, clrF)
    end

    if nodeRayDistance <= sphereRadius and distNodeToCam < minNodeDist then
      minNodeDist = distNodeToCam
      closest = obj
    end
  end
  return closest
end

function C:dropToTerrain(pos)
  local p = vec3(pos)
  if core_terrain then
    p.z = (core_terrain.getTerrainHeight(p) or p.z)
    return p, true
  end
  return p, false
end

function C:tryInsert(mouseInfo)
  if not self.zone or #self.zone.vertices < 2 then return end
  local objs = {}
  for i, v in ipairs(self.zone.vertices) do
    local nextIdx = v.next or (i == #self.zone.vertices and 1 or i + 1)
    table.insert(objs, {
      pos = (v.pos + self.zone.vertices[nextIdx].pos) / 2,
      radius = 3,
      orig = i
    })
  end
  local hit = self:findVert(mouseInfo, objs)
  if hit and mouseInfo.down and editor.history then
    editor.history:commitAction("Insert Zone Vertex",
      {zone = self.zone, position = hit.pos, index = hit.orig + 1},
      addVertexUndo, addVertexRedo)
  end
end

function C:input(mouseInfo)
  if not self.zone then return end

  -- When zone has no vertices, first click (or Shift+click) adds the first vertex.
  local isEmpty = #self.zone.vertices == 0
  local wantAdd = editor.keyModifiers.shift or isEmpty
  local placePos = mouseInfo._downPos or (mouseInfo.camPos and mouseInfo.rayDir and (mouseInfo.camPos + mouseInfo.rayDir * 100))
  if wantAdd and not editor.isAxisGizmoHovered() and mouseInfo.down and placePos then
    local newIndex = #self.zone.vertices + 1
    if editor.history and not isEmpty then
      editor.history:commitAction("Add Zone Vertex",
        {zone = self.zone, position = placePos, index = newIndex},
        addVertexUndo, addVertexRedo)
    else
      self.zone:addVertex(placePos, newIndex)
    end
  elseif editor.keyModifiers.alt then
    self:tryInsert(mouseInfo)
  else
    local objects = {}
    for i, vertex in ipairs(self.zone.vertices) do
      table.insert(objects, {
        pos = vertex.pos,
        index = i,
        radius = (mouseInfo.camPos - vertex.pos):length() / 40
      })
    end
    local hit = self:findVert(mouseInfo, objects)
    if not editor.isAxisGizmoHovered() and mouseInfo.down then
      if editor.keyModifiers.ctrl then
        if hit then table.insert(self.currentVertices, hit) end
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
  if not self.zone then return end
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
  if not self.zone then return end
  local posOffset = (vec3(editor.getAxisGizmoTransform():getColumn(3)) - self._prevGizmoPos) / 2

  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
    if #self.currentVertices > 0 then
      for i, vertex in ipairs(self.currentVertices) do
        self.zone.vertices[vertex.index].pos = self.zone.vertices[vertex.index].pos + posOffset
        vertex.pos = vertex.pos + posOffset
        if self.snapToTerrain then
          local newPos, succ = self:dropToTerrain(self.zone.vertices[vertex.index].pos)
          self.zone.vertices[vertex.index].pos = newPos
          vertex.pos = newPos
          if not succ then
            self.zone.vertices[vertex.index].pos.z = self._prevVerticesPos[vertex.index].z
            vertex.pos.z = self._prevVerticesPos[vertex.index].z
          end
        end
      end
      self.zone:processVertices()
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
        self.zone.vertices[vertex.index].pos = newPos
        vertex.pos = newPos
      end
      self.zone:processVertices()
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

function C:endDragging()
  if not self.zone then return end
  if self.snapToTerrain then
    for _, vertex in ipairs(self.currentVertices) do
      local newPos = self:dropToTerrain(vertex.pos)
      self.zone.vertices[vertex.index].pos = newPos
      vertex.pos = newPos
    end
  end
  if #self.currentVertices > 0 and editor.history then
    local oldPositions = {}
    local newPositions = {}
    for _, vertex in ipairs(self.currentVertices) do
      oldPositions[vertex.index] = self._prevVerticesPos[vertex.index]
      newPositions[vertex.index] = vertex.pos
    end
    editor.history:commitAction("Manipulate Zone Vertices",
      {zone = self.zone, old = oldPositions, new = newPositions},
      manipulateVerticesUndo, manipulateVerticesRedo)
  end
  self.zone:processVertices()
end

function C:draw(mouseInfo)
  if not self.zone then return end
  editor.updateAxisGizmo(
    function() self:beginDrag() end,
    function() self:endDragging() end,
    function() self:dragging() end
  )
  editor.drawAxisGizmo()
  self:input(mouseInfo)
  self:updateTransform()
  self.zone:drawDebug('normal')
end

local M = {}
M.zoneFromData = C.zoneFromData
M.zoneToData = C.zoneToData
M.init = function()
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init()
  return o
end
return M
