-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui

local C = {}

C.name = 'List Description'
C.color = ui_flowgraph_editor.nodeColors.ui
C.icon = ui_flowgraph_editor.nodeIcons.ui
C.description = "Builds a list from translation keys or context translation objects."
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'out', type = 'string', name = 'value', description = 'The translated list.' },
}

C.tags = {}

function C:init()
  self.count = 1
end

function C:postInit()
  self:updatePins(0, self.count)
end

function C:drawCustomProperties()
  local reason = nil
  im.PushID1("LAYOUT_COLUMNS")
  im.Columns(2, "layoutColumns")
  im.Text("List Item Count")
  im.NextColumn()
  local ptr = im.IntPtr(self.count)
  if im.InputInt('##count'..self.id, ptr) then
    if ptr[0] < 1 then ptr[0] = 1 end
    self:updatePins(self.count, ptr[0])
    reason = "Changed list item count to " .. ptr[0]
  end

  im.Columns(1)
  im.PopID()
  return reason
end

function C:updatePins(old, new)
  if new < old then
    for i = old, new + 1, -1 do
      for _, lnk in pairs(self.graph.links) do
        if lnk.sourcePin == self.pinInLocal['item_'..i] then
          self.graph:deleteLink(lnk)
        end
      end
      self:removePin(self.pinInLocal['item_'..i])
    end
  else
    for i = old + 1, new do
      self:createPin('in', {'string', 'table'}, 'item_'..i)
    end
  end
  self.count = new
end

function C:_onSerialize(res)
  res.count = self.count
end

function C:_onDeserialized(res)
  self.count = res.count or 1
  self:updatePins(1, self.count)
end

function C:work()
  local items = {}
  for i = 1, self.count do
    local item = self.pinIn['item_'..i].value
    if item then
      local translatedItem = core_locales.translateWithOrWithoutContext(item)
      if translatedItem ~= '' then
        table.insert(items, translatedItem)
      end
    end
  end
  self.pinOut.value.value = table.concat(self.mgr.modules.ui:buildListText(items))
end

return _flowgraph_createNode(C)
