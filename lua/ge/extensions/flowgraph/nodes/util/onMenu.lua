-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui

local C = {}

C.name = 'On Menu'
C.description = "Detects when any UI menu is open"
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'flow', impulse = true, name = 'reset', description = 'Resets the impulse output pins' },

  { dir = 'out', type = 'flow', name = 'open', description = 'The menu is open' },
  { dir = 'out', type = 'flow', name = 'close', description = 'The menu is closed' },
  { dir = 'out', type = 'flow', name = 'onOpened', impulse = true, hidden = true, description = 'The menu just opened' },
  { dir = 'out', type = 'flow', name = 'onClosed', impulse = true, hidden = true, description = 'The menu just closed' },
  { dir = 'out', type = 'bool', name = 'openOrClosed', hidden = true, description = 'A boolean reflecting the open state of the menu' },
}

C.tags = {}

function C:reset()
  self.lastState = "none"
end

function C:_executionStarted()
  self:reset()
end

function C:work()
  if self.pinIn.reset.value then
    self:reset()
  end

  -- Check if ESC menu is open using the reliable menu action map method
  local isMenuOpen = false

  if core_input_bindings and core_input_bindings.getMenuActionMapEnabled then
    isMenuOpen = core_input_bindings.getMenuActionMapEnabled() and (not core_gamestate.loading())
  end

  local newState = isMenuOpen and "opened" or "closed"

  -- Update pin values
  self.pinOut.open.value = isMenuOpen
  self.pinOut.close.value = not isMenuOpen
  self.pinOut.openOrClosed.value = isMenuOpen

  if self.lastState ~= newState then
    if newState == "opened" then
      self.pinOut.onOpened.value = true
      print("OnMenu Debug - Triggering onOpened impulse")
    elseif newState == "closed" then
      self.pinOut.onClosed.value = true
      print("OnMenu Debug - Triggering onClosed impulse")
    end
    self.lastState = newState
  else
    -- Reset impulses after they've been triggered
    self.pinOut.onOpened.value = false
    self.pinOut.onClosed.value = false
  end
end

return _flowgraph_createNode(C)