-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local im = ui_imgui

local C = {}
C.windowDescription = 'Sites'

function C:init(sitesEditor, key, elementEditor)
  self.key = key
  self.index = nil
  self.mouseInfo = {}
  self.sitesEditor = sitesEditor
  self.elementEditor = elementEditor
  self.customFieldsUtil = require('/lua/ge/extensions/editor/util/customFieldsUtil')(key)
  self.createByShift = true
  self.selectByClick = true
  self.search = im.ArrayChar(256, "")
  editor.selection[self.key] = {}
  self.selections = editor.selection[self.key]
  self.activeTags = {}
end

function C:setSites(sites)
  self.sites = sites
  self.objects = sites[self.key].objects
  self.sorted = sites[self.key].sorted
  self.elementEditor:setSites(sites)
  self:updateActiveTags()
end

function C:updateActiveTags()
  table.clear(self.activeTags)
  for _, o in pairs(self.objects) do
    for _, tag in ipairs(o.customFields.sortedTags) do
      if not self.activeTags[tag] then
        self.activeTags[tag] = 1
      else
        self.activeTags[tag] = self.activeTags[tag] + 1
      end
    end
  end
end

function C:selected()
  self.index = nil
  table.clear(self.selections)

  if not self.sites then
    return
  end
  for _, o in pairs(self.objects) do
    o._drawMode = 'normal'
  end
end

function C:unselect()
  table.clear(self.selections)

  for _, o in pairs(self.objects) do
    o._drawMode = 'faded'
  end
  -- self.elementEditor:unselect()
end

function C:selectElement(id, mode)
  if not mode then
    table.clear(self.selections)
  end

  local idx = mode ~= 'add' and arrayFindValueIndex(self.selections, id)
  if idx then
    table.remove(self.selections, idx)
  else
    table.insert(self.selections, id)
  end

  self.index = self.selections[#self.selections]

  for _, o in pairs(self.objects) do
    o._drawMode = 'normal'
    for _, s in ipairs(self.selections) do
      if o.id == s then
        o._drawMode = 'highlight'
      end
    end
  end
  local elem = self.objects[self.index]
  if not elem or elem.missing then
    elem = nil
  end

  --if self.sitesEditor.allowGizmo() then
  self.elementEditor:select(elem)
  self:updateActiveTags()
  --end

  if elem then
    self.nameText = im.ArrayChar(1024, elem.name)
    self.color = im.ArrayFloat(4)
    self.color[0] = im.Float(elem.color.x)
    self.color[1] = im.Float(elem.color.y)
    self.color[2] = im.Float(elem.color.z)
    self.color[3] = im.Float(1)
    self.fields = {}
    self.customFieldsUtil:setFields(elem.customFields)
    self.customFieldsUtil.presetTags = tableKeysSorted(self.activeTags)
  end
end

function C:draw(mouseInfo)
  if self.sitesEditor.allowGizmo() then
    self.mouseInfo = mouseInfo
    self:input()
  end
  self:drawList()
end

function C:input()
  if not self.mouseInfo.valid then
    return
  end

  if self.selectByClick then
    if editor.keyModifiers.shift and self.createByShift then
      if self.mouseInfo.down and not editor.isAxisGizmoHovered() then
        local elem = self.elementEditor:create(self.mouseInfo._downPos)
        self:selectElement(elem and elem.id)
      end
    else
      if self.mouseInfo.down and not editor.isAxisGizmoHovered() then
        local selected = self.elementEditor:hitTest(self.mouseInfo, self.objects)
        if selected then
          self:selectElement(selected.id)
        else
          self:selectElement(nil)
        end
      end
    end
  else
    if self.elementEditor.input then
      self.elementEditor:input(self.mouseInfo)
    end
  end
end

local function setFieldUndo(data)
  for _, id in ipairs(data.sel) do
    data.objects[id][data.field] = data.old
  end
end

local function setFieldRedo(data)
  for _, id in ipairs(data.sel) do
    data.objects[id][data.field] = data.new
  end
end

function C:setField(name, value)
  local old = self.sites[self.key].objects[self.selections[#self.selections]][name]
  editor.history:commitAction("Change " .. name .. " of " .. self.key,
    { objects = self.sites[self.key].objects, sel = deepcopy(self.selections), field = name, old = old, new = value },
    setFieldUndo, setFieldRedo)
end

function C:drawList()
  --local avail = im.GetContentRegionAvail()
  local disabled = self.selections[2] and true or false

  im.BeginChild1(self.key, im.ImVec2(180 * im.uiscale[0], 0), im.WindowFlags_ChildWindow)
  if editor.uiInputText('', self.search) then
  end
  im.SameLine()
  if im.SmallButton("x") then
    self.search = im.ArrayChar(256, '')
  end
  im.Separator()
  local filter = string.lower(ffi.string(self.search))
  if filter == '' then
    filter = nil
  end
  local remove = nil
  for i, obj in ipairs(self.sorted) do
    if not obj.isProcedural and ((filter == nil) or (filter and string.find(string.lower(obj.name), filter) or self.currentElement == obj)) then
      if tableContains(self.selections, obj.id) then
        if im.SmallButton("X##" .. obj.id) then
          remove = obj
        end
        im.SameLine()
      end
      local selected = arrayFindValueIndex(self.selections, obj.id) and true or false
      local mode
      if editor.keyModifiers.ctrl or editor.keyModifiers.shift then
        mode = "toggle"
      elseif editor.keyModifiers.shift then
        mode = "add"
      end

      if im.Selectable1(obj.name .. '##' .. obj.id, selected) then
        self:selectElement(obj.id, mode)
      end
    end
  end
  if remove then
    self.elementEditor:remove(remove)
    self:selectElement(nil)
  end
  im.Separator()
  if self.createByShift then
    if im.Selectable1('New...', self.index == nil) then
      self:selectElement(nil)
    end
    im.tooltip("Shift-Drag in the world to place and rotate a new element.")
  else
    if im.Selectable1('Create...', false) then
      local elem = self.elementEditor:create(nil)
      self:selectElement(elem and elem.id)
    end
  end
  im.EndChild()

  im.SameLine()
  im.BeginChild1("currentElement", im.ImVec2(0, 0), im.WindowFlags_ChildWindow)
  if self.index then
    if self.objects[self.index] and not self.objects[self.index].missing then
      local o = self.objects[self.index]
      local editEnded = im.BoolPtr(false)
      if disabled then
        im.BeginDisabled()
      end

      editor.uiInputText("Name", self.nameText, nil, nil, nil, nil, editEnded)
      if editEnded[0] then
        self:setField('name', ffi.string(self.nameText))
      end
      editEnded = im.BoolPtr(false)
      editor.uiColorEdit3("Color", self.color, nil, editEnded)
      if editEnded[0] then
        self:setField('color', vec3(self.color[0], self.color[1], self.color[2]))
      end

      if disabled then
        im.EndDisabled()
      end

      im.Separator()
      --editor.drawAxisGizmo()
      self.elementEditor:drawElement(o, self.mouseInfo)

      im.Separator()

      self:drawCustomFields(o.customFields)
    else
      self:selectElement(nil)
    end
  end
  im.EndChild()
end

function C:drawCustomFields(fields)
  self.customFieldsUtil:widget()

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

function C:getCurrentSelected()
  return self.objects and self.objects[self.index] or nil
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end

