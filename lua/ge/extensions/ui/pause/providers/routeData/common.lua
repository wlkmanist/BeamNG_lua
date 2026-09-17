-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

function M.bool(value)
  return value and true or false
end

function M.tryPushStateSequence(states)
  if not states then return false end
  if type(states) == "string" then states = {states} end
  for _, stateName in ipairs(states) do
    local ok, result = pcall(ui_router.navigate, stateName, nil)
    if ok and result and result.result ~= false then return true end
  end
  return false
end

function M.registerPauseButton(button)
  if not button then return nil end
  local callback = button.callback or function() return false end
  local metadata = deepcopy(button)
  metadata.callback = nil
  return ui_pause_actions.registerButton(metadata, callback)
end

-- Skip empty action lists so JSON encodes rail actions as arrays, not objects.
function M.asRailGroup(id, actions)
  if not actions or #actions == 0 then return nil end
  return {
    id = id,
    actions = actions,
  }
end

return M
