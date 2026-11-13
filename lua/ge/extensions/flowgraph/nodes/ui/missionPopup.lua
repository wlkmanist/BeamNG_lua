-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Popup'
C.color = ui_flowgraph_editor.nodeColors.ui
C.icon = ui_flowgraph_editor.nodeIcons.ui
C.description = "Shows a Popup that can only be dismissed using buttons."
C.todo = "Showing two of these at the same time will queue them after another"
C.behaviour = { once = true, singleActive = true}
C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = 'Inflow for this node.' },
  { dir = 'in', type = 'flow', name = 'reset', description = 'Resets this node.', impulse = true },
  { dir = 'in', type = {'string', 'table'}, name = 'title', description = 'Title.' },
  { dir = 'in', type = {'string', 'table'}, name = 'text', description = 'Text.' },
  { dir = 'in', type = 'string', name = 'buttonText', hardcoded = true, hidden = true, default = 'ui.scenarios.start.start', description = 'Text to display on the button.' },
  { dir = 'out', type = 'flow', name = 'flow', description = 'Outflow for this node.' },
}
C.dependencies = {'core_input_bindings', 'ui_popup'}

function C:init()
  self.open = false
  self.done = false
end

function C:_executionStarted()
  for _, p in pairs(self.pinOut) do
    p.value = false
  end
  self.open = false
  self.done = false
  self._active = false
end

function C:postInit()

end

function C:_executionStarted()
  for _, p in pairs(self.pinOut) do
    p.value = false
  end
  self._active = false
end

function C:_executionStopped()
  if self.open then
    self:closeDialogue()
  end
  self:reset()
end

function C:reset()
  self.done = false
  self.open = false
  self._active = false
end

function C:getPopupId()
  return string.format("flowgraphMissionPopup_%s_%s_%s", tostring(self.mgr.id), tostring(self.graph.id), tostring(self.id))
end

function C:closeDialogue()
  if self.open then
    extensions.ui_popup.closeTutorialPopup()
  end
  self.open = false
  self._active = false
end

function C:openDialogue()
  self.open = true
  -- dump("opening dialogue!")
  local entry = {
    id = self:getPopupId(),
    type = "info",
    isPopup = true,
    title = core_locales.translateWithOrWithoutContext(self.pinIn.title.value) or "",
    text = core_locales.translateWithOrWithoutContext(self.pinIn.text.value) or "",
    buttonLabel = self.pinIn.buttonText.value or "ui.scenarios.start.start",
  }

  self._active = true
  extensions.ui_popup.openPopupEntries({entry})
end

function C:onIntroPopupCareerClosed(id)
  if not self.open or id ~= self:getPopupId() then return end
  self.open = false
  self._active = false
  self.done = true
  self.pinOut.flow.value = true
end

function C:onFilteredInputChanged(devName, action, value)

end

function C:onClientEndMission()
  self.open = false
  self._active = false
end

function C:work()
  if self.pinIn.reset.value == true then
    if self.open then
      self:closeDialogue()
    end
    self:reset()
    for _,pn in pairs(self.pinOut) do
      pn.value = false
    end
    return
  else
    if self.done then return end
    if self.pinIn.flow.value and not self.open then
      self:openDialogue()
    end
  end
end

return _flowgraph_createNode(C)
