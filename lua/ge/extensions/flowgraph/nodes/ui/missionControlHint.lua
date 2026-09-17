-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Mission Control Hints'
C.color = ui_flowgraph_editor.nodeColors.ui
C.icon = ui_flowgraph_editor.nodeIcons.ui
C.behaviour = { duration = true }
C.description = "Shows one or more control hints (e.g. shift up/down, clutch) in the Mission Controls HUD app. Use the Hint Count property to add more slots."
C.category = 'repeat_instant'
C.author = 'BeamNG'
C.dependencies = {'ui_apps_missionControls'}

C.pinSchema = {
  {dir = 'in', type = 'flow', name = 'reset', description = "Clears all hints and resets the Mission Controls app.", impulse = true},
}
C.tags = {'ui', 'controls'}

-- Presets are just convenience shortcuts - any pin here can also be typed/personalized freely.
local ACTION_PRESETS = {
  {label = "Shift Up", value = "shiftUp"},
  {label = "Shift Down", value = "shiftDown"},
  {label = "Clutch", value = "clutch"},
  {label = "Throttle", value = "throttle"},
  {label = "Brake", value = "brake"},
  {label = "Parking Brake", value = "parkingbrake"},
  {label = "Horn", value = "horn"},
}

local LABEL_PRESETS = {
  {label = "Shift Up", value = "ui.inputActions.vehicle.shiftUp.title"},
  {label = "Shift Down", value = "ui.inputActions.vehicle.shiftDown.title"},
  {label = "Clutch", value = "ui.inputActions.vehicle.clutch.title"},
}

function C:init()
  self.count = self.count or 1
end

function C:postInit()
  self:updatePins(0, self.count)
  extensions.load('ui_apps_missionControls')
end

function C:updatePins(old, new)
  if new < old then
    for i = old, new + 1, -1 do
      self:removePin(self.pinInLocal['action_'..i])
      self:removePin(self.pinInLocal['uiEvent_'..i])
      self:removePin(self.pinInLocal['label_'..i])
    end
  else
    for i = old + 1, new do
      local actionPin = self:createPin('in', 'string', 'action_'..i, nil, "Hint "..i..": input action to show the current binding for (e.g. shiftUp). Pick a preset or type your own.")
      actionPin.hardTemplates = ACTION_PRESETS

      local uiEventPin = self:createPin('in', 'string', 'uiEvent_'..i, nil, "Hint "..i..": UI nav event name instead of an input action.")
      uiEventPin.hidden = true

      local labelPin = self:createPin('in', 'string', 'label_'..i, nil, "Hint "..i..": label text or translation key shown next to the binding.")
      labelPin.hardTemplates = LABEL_PRESETS
    end
  end
  self.count = new
end

function C:drawCustomProperties()
  local reason = nil
  im.PushID1("MISSION_CONTROL_HINT_COUNT")
  im.Columns(2, "layoutColumns")
  im.Text("Hint Count")
  im.NextColumn()
  local ptr = im.IntPtr(self.count)
  if im.InputInt('##count'..self.id, ptr) then
    if ptr[0] < 1 then ptr[0] = 1 end
    self:updatePins(self.count, ptr[0])
    reason = "Changed Mission Control Hint count to " .. ptr[0]
  end
  im.Columns(1)
  im.PopID()
  return reason
end

function C:_onSerialize(res)
  res.count = self.count
end

function C:_onDeserialized(res)
  self.count = res.count or 1
  self:updatePins(1, self.count)
end

function C:work()
  extensions.load('ui_apps_missionControls')
  if not ui_apps_missionControls then return end

  if self.pinIn.reset.value then
    ui_apps_missionControls.clearControls()
    return
  end

  for i = 1, self.count do
    local action = self.pinIn['action_'..i].value
    local uiEvent = self.pinIn['uiEvent_'..i].value
    local label = self.pinIn['label_'..i].value
    local category = 'flowgraph_'..self.id..'_'..i

    if action or uiEvent then
      ui_apps_missionControls.setControl({
        category = category,
        action = action,
        uiEvent = uiEvent,
        label = label,
        order = i,
      })
    else
      ui_apps_missionControls.setControl({category = category, clear = true})
    end
  end
end

return _flowgraph_createNode(C)
