-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local C = {}

C.name = 'Drag Race State'

C.description = 'Monitor drag race state and provide real-time status information. Pure monitoring node with no actions.'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'out', type = 'flow', name = 'flow', description = 'Outflow for this node.'},

  { dir = 'out', type = 'flow', name = 'started', description = 'Impulse when race transitions to started', impulse = true },
  { dir = 'out', type = 'flow', name = 'completed', description = 'Impulse when race transitions to completed', impulse = true },
  { dir = 'out', type = 'flow', name = 'staged', description = 'Impulse when the local racer finishes staging (leaves the stage phase for the countdown phase)', impulse = true },
  { dir = 'out', type = 'flow', name = 'countdownOver', description = 'Impulse when the local racer leaves the countdown phase (tree drops / race starts)', impulse = true },

  { dir = 'out', type = 'bool', name = 'isStarted', description = 'Current started state (true if race is active)'},
  { dir = 'out', type = 'bool', name = 'isCompleted', description = 'Current completed state (true if race finished)'},
  { dir = 'out', type = 'bool', name = 'isStaged', description = 'True once the local racer has finished staging (is in or past the countdown phase)'},

  { dir = 'out', type = 'string', name = 'dragType', description = 'Type of drag race (drag, bracketRace, headsUpRace)'},
  { dir = 'out', type = 'string', name = 'context', description = 'Context (freeroam, activity, etc.)'},
  { dir = 'out', type = 'string', name = 'localPhase', description = 'Current phase name of the local racer (stage, countdown, race, stop)'},
}

C.tags = {'gameplay', 'utils'}

function C:_executionStarted()
  self.data = {}
  self._lastStartedState = false
  self._lastCompletedState = false
  self._lastLocalPhase = nil
end

--- Returns the current phase name (e.g. "stage", "countdown", "race", "stop") of the local/playable racer, or nil.
local function getLocalRacerPhaseName(data)
  if not data or not data.racers then return nil end
  for _, racer in pairs(data.racers) do
    if racer.isPlayable then
      local phase = racer.phases and racer.currentPhase and racer.phases[racer.currentPhase]
      return phase and phase.name or nil
    end
  end
  return nil
end

function C:work()
  -- Always refresh data to handle retry scenarios
  self.data = gameplay_drag_dragBridge.getData() or {}

  -- Check if data exists
  -- During retry, data may be temporarily unavailable - don't spam errors
  if not self.data or not next(self.data) then
    if not self._dataWaiting then
      self._dataWaiting = true
    end
    -- Clear outputs when data is unavailable
    self.pinOut.isStarted.value = false
    self.pinOut.isCompleted.value = false
    self.pinOut.isStaged.value = false
    self.pinOut.started.value = false
    self.pinOut.completed.value = false
    self.pinOut.staged.value = false
    self.pinOut.countdownOver.value = false
    self.pinOut.dragType.value = ""
    self.pinOut.context.value = ""
    self.pinOut.localPhase.value = ""
    self._lastLocalPhase = nil
    return
  end

  -- Clear waiting flag and error if data is now available
  self._dataWaiting = false
  self:__setNodeError(nil, nil)

  -- Update outputs with proper impulse handling
  if self.data then
    local isStarted = self.data.isStarted or false
    local isCompleted = self.data.isCompleted or false

    -- Output started impulse when race transitions to started
    if isStarted and not self._lastStartedState then
      self.pinOut.started.value = true
    else
      self.pinOut.started.value = false
    end

    -- Output completed impulse when race transitions to completed
    if isCompleted and not self._lastCompletedState then
      self.pinOut.completed.value = true
    else
      self.pinOut.completed.value = false
    end

    -- Always output current state as bool
    self.pinOut.isStarted.value = isStarted
    self.pinOut.isCompleted.value = isCompleted

    -- Track state for next frame
    self._lastStartedState = isStarted
    self._lastCompletedState = isCompleted

    self.pinOut.dragType.value = self.data.dragType or ""
    self.pinOut.context.value = self.data.context or ""

    -- Track local racer phase transitions (stage -> countdown -> race -> stop)
    local localPhase = getLocalRacerPhaseName(self.data)

    -- Output staged impulse when the local racer leaves the stage phase for countdown
    self.pinOut.staged.value = (localPhase == "countdown" and self._lastLocalPhase == "stage")

    -- Output countdownOver impulse when the local racer leaves the countdown phase
    self.pinOut.countdownOver.value = (localPhase ~= "countdown" and localPhase ~= nil and self._lastLocalPhase == "countdown")

    self.pinOut.isStaged.value = localPhase ~= nil and localPhase ~= "stage"
    self.pinOut.localPhase.value = localPhase or ""

    self._lastLocalPhase = localPhase
  end
end

return _flowgraph_createNode(C)

