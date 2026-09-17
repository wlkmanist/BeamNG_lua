-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  PendingTransition Model

  Represents an active navigation transition in progress.
  Created when navigation starts, cleared when complete/cancelled.

  PendingTransition = {
    -- Transition identity
    transitionId: string        -- Unique ID for this transition

    -- Navigation intent
    action: string              -- "push"|"replace"|"back"|"forward"

    -- Routes
    toRoute: ResolvedRoute      -- Where we're going
    fromRoute: HistoryEntry     -- Where we came from (or nil for initial)

    -- Options
    options: table              -- Original navigation options
  }
]]

local Constants = require("ge/extensions/ui/router/constants")

local M = {}

-- Counter for generating unique IDs
local transitionCounter = 0

--[[
  Generate a unique transition ID.

  @return string
]]
local function generateTransitionId()
  transitionCounter = transitionCounter + 1
  return "transition_" .. transitionCounter .. "_" .. Engine.generateUUID()
end

--[[
  Create a new PendingTransition.

  @param action - Navigation action ("push"|"replace"|"back"|"forward")
  @param toRoute - ResolvedRoute we're navigating to
  @param fromRoute - HistoryEntry we're navigating from (optional)
  @param options - Navigation options (optional)
  @return PendingTransition
]]
M.create = function(action, toRoute, fromRoute, options)
  if not toRoute then
    log("E", "PendingTransition", "Cannot create transition without toRoute")
    return nil
  end

  local validActions = {
    [Constants.NavigationAction.PUSH] = true,
    [Constants.NavigationAction.REPLACE] = true,
    [Constants.NavigationAction.BACK] = true,
    [Constants.NavigationAction.FORWARD] = true,
  }

  if not validActions[action] then
    log("W", "PendingTransition", "Invalid action: " .. tostring(action) .. ", defaulting to push")
    action = Constants.NavigationAction.PUSH
  end

  return {
    transitionId = generateTransitionId(),
    action = action,
    toRoute = toRoute,
    fromRoute = fromRoute,
    options = options or {},
  }
end

--[[
  Check if a PendingTransition is valid.

  @param transition - The PendingTransition to validate
  @return isValid, errors
]]
M.validate = function(transition)
  local errors = {}

  if transition == nil then
    table.insert(errors, "PendingTransition is nil")
    return false, errors
  end

  if not transition.transitionId then
    table.insert(errors, "transitionId is required")
  end

  if not transition.action then
    table.insert(errors, "action is required")
  end

  if not transition.toRoute then
    table.insert(errors, "toRoute is required")
  end

  return #errors == 0, errors
end

--[[
  Check if this is a backward navigation.

  @param transition - The PendingTransition
  @return boolean
]]
M.isBackward = function(transition)
  return transition and transition.action == Constants.NavigationAction.BACK
end

--[[
  Check if this is a forward navigation.

  @param transition - The PendingTransition
  @return boolean
]]
M.isForward = function(transition)
  return transition and transition.action == Constants.NavigationAction.FORWARD
end

--[[
  Check if this navigation should update history.

  @param transition - The PendingTransition
  @return boolean
]]
M.shouldUpdateHistory = function(transition)
  if not transition then
    return false
  end

  -- Push adds to history
  -- Replace modifies current
  -- Back/Forward navigate existing history
  return transition.action == Constants.NavigationAction.PUSH
end

--[[
  Check if this navigation should clear forward stack.

  @param transition - The PendingTransition
  @return boolean
]]
M.shouldClearForward = function(transition)
  if not transition then
    return false
  end

  -- Push and Replace clear forward stack
  -- Back and Forward do not
  return transition.action == Constants.NavigationAction.PUSH or
         transition.action == Constants.NavigationAction.REPLACE
end

return M

