-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local C = {}
C.moduleOrder = 1000 -- low first, high later
C.idCounter = 0
function C:getFreeId()
  self.idCounter = self.idCounter + 1
  return self.idCounter
end

function C:init()
  self:clear()
end

function C:clear()

end

function C:setGameState(...)
  core_gamestate.setGameState(...)
end

function C:keepGameState(keep)
  self.recoverGameStateWhenExecutionStopped = not keep
end

function C:startUIBuilding(uiMode)
  self.uiLayout = { mode = uiMode, layout = { {} } }
  self.pageCounter = 1
  self.isBuilding = true
end

function C:finishUIBuilding()
  if not self.isBuilding then
    return
  end

  self.isBuilding = false

  log("I", "", dumps(self.uiLayout))

  if self.uiLayout.mode == 'startScreen' then
    for _,page in ipairs(self.uiLayout.layout) do
      for _,elem in ipairs(page) do
        -- BUILD UI
      end
    end
  elseif self.uiLayout.mode == 'failureScreen' then
    for _,page in ipairs(self.uiLayout.layout) do
      for _,elem in ipairs(page) do
        -- BUILD UI
      end
    end
  elseif self.uiLayout.mode == 'successScreen' then
    for _,page in ipairs(self.uiLayout.layout) do
      for _,elem in ipairs(page) do
        -- BUILD UI
      end
    end
  end
end

function C:addUIElement(elementType, elementData)
  if self.isBuilding then
    table.insert(self.uiLayout.layout[self.pageCounter], {type = elementType, data = elementData})
  end
end

-- will probably only be used by startPage
function C:nextPage()
  self.pageCounter = self.pageCounter + 1
  table.insert(self.uiLayout.layout,self.pageCounter,{})
end

function C:executionStarted()
  self.serializedRecoveryPromptState = core_recoveryPrompt.serializeState()
  self.gameStateBeginning = deepcopy(core_gamestate.state)
  self.recoverGameStateWhenExecutionStopped = true
  self.genericMissionDataChanged = false
  core_recoveryPrompt.setActive(false)

  if self.mgr.activity then
    guihooks.trigger('ClearTasklist')
  end
end

function C:executionStopped()
  if self.genericMissionDataChanged then
    guihooks.trigger('SetGenericMissionDataResetAll')
  end

  if self.serializedRecoveryPromptState then
    core_recoveryPrompt.deserializeState(self.serializedRecoveryPromptState)
  end
  self.serializedRecoveryPromptState = nil

  if self.recoverGameStateWhenExecutionStopped and self.gameStateBeginning then
    core_gamestate.setGameState(self.gameStateBeginning.state, self.gameStateBeginning.appLayout, self.gameStateBeginning.menuItems, self.gameStateBeginning.options)
  end
  self.recoverGameStateWhenExecutionStopped = nil
  self.gameStateBeginning = nil

  if self.mgr.activity then
    guihooks.trigger('ClearTasklist')
  end
end

return _flowgraph_createModule(C)