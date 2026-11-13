-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = 'MissionInfo'
local interactConflictsFilterGroup = 'activityPromptInteractConflicts'
local interactConflictsBlocked = false
local activityPromptHasContent = false
M.buttonsTable = nil
M.openState = nil

-- actions bound to the same controls as gameplay_interact (e.g. vehicle-specific ones) are processed first and would swallow the input meant for the prompt
local function setInteractConflictsBlocked(blocked)
  interactConflictsBlocked = blocked
  core_input_actionFilter.setGroup(interactConflictsFilterGroup, blocked and core_input_bindings.getActionsSharingControls('gameplay_interact') or {})
  core_input_actionFilter.addAction(0, interactConflictsFilterGroup, blocked)
end

-- the filter blocks these actions on every device, so it must only be active while the prompt is on screen, which is only on the play route
local function shouldBlockInteractConflicts(routeEntry)
  local routeName = routeEntry and routeEntry.resolved and routeEntry.resolved.name
  return activityPromptHasContent and routeName == 'play'
end

M.performAction = function(actionName)
  -- log('I', logTag, tostring(actionName) .. " action triggered. Looking for " .. tostring(actionName) .. " action in "..dumps(M.buttonsTable))
  if M.buttonsTable then
    for i,button in ipairs(M.buttonsTable) do
      if button.action == actionName then
        loadstring(button.cmd)()
        return
      end
    end
  end
end

M.openDialogue = function(content)
  content = content or {}
  -- do not push the actionmap if content says so
  if content.actionMap ~= false then
    local am = scenetree.findObject("MissionUIActionMap")
    if am then am:push() end
  end
  M.buttonsTable = content.buttons or {}
  guihooks.trigger('MissionInfoUpdate', content)
  Engine.Audio.playOnce('AudioGui','event:>UI>Missions>Info_Open')
end


M.performActivityAction = function(id)
  log('I', logTag, tostring(id) .. " action triggered. Looking for " .. tostring(id) .. " action in "..dumps(M.buttonsTable))
  if M.buttonsTable then
    (M.buttonsTable[id] or nop)()
  end
end

M.openActivityAcceptDialogue = function(content)
  content = content or {}
  -- do not push the actionmap if content says so
  --if content.actionMap ~= false then
  --  local am = scenetree.findObject("MissionUIActionMap")
  --  if am then am:push() end
  --end
  M.buttonsTable = {}
  M.elemDataTable = {}
  for i, elem in ipairs(content) do
    M.buttonsTable[i] = elem.buttonFun
    elem.missionInfoPerformActionIndex = i
    M.elemDataTable[i] = elem.data
  end
  activityPromptHasContent = #content > 0
  setInteractConflictsBlocked(shouldBlockInteractConflicts(ui_router.getCurrent()))
  extensions.hook('onActivityAcceptUpdate', content)
  guihooks.trigger('ActivityAcceptUpdate', content)

  local oldState = M.openState
  M.openState = "opened"
  extensions.hook('onMissionInfoChangedState', oldState, M.openState, content)
end

M.closeDialogue = function()
  local am = scenetree.findObject("MissionUIActionMap")
  if am then am:pop() end
  M.buttonsTable = nil
  activityPromptHasContent = false
  setInteractConflictsBlocked(false)
  guihooks.trigger('MissionInfoUpdate', nil)
  guihooks.trigger('ActivityAcceptClose', nil)

  local oldState = M.openState
  M.openState = "closed"
  extensions.hook('onMissionInfoChangedState', oldState, M.openState)
end

M.setActivityIndexVisible = function(index)
  if index == -1 then
    extensions.hook('onActivityIndexVisible', nil)
  else
    local data = M.elemDataTable[index+1]
    extensions.hook('onActivityIndexVisible', data)
  end
end

M.onInputBindingsChanged = function()
  if interactConflictsBlocked then setInteractConflictsBlocked(true) end
end

M.onAfterRouteChange = function(routeEntry)
  local blocked = shouldBlockInteractConflicts(routeEntry)
  if blocked ~= interactConflictsBlocked then setInteractConflictsBlocked(blocked) end
end

return M
