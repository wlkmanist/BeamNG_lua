-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.onInit = function() setExtensionUnloadMode(M, "manual") end

-- Control hints, keyed by category so individual hints can be added/removed
-- (e.g. by the flowgraph node) without disturbing the others.
local controls = {}

local function sendAll()
  local list = {}
  for _, entry in pairs(controls) do
    table.insert(list, entry)
  end
  table.sort(list, function(a, b) return (a.order or 0) < (b.order or 0) end)
  guihooks.trigger('SetMissionControls', list)
end

-- Adds/updates/removes a single hint, keyed by category (defaults to action/uiEvent).
local function setControl(args)
  local category = args and (args.category or args.action or args.uiEvent)
  if not category then return end

  if args.clear then
    controls[category] = nil
  else
    controls[category] = {
      action = args.action,
      uiEvent = args.uiEvent,
      label = args.label,
      order = args.order or 0,
    }
  end
  sendAll()
end

-- Bulk replace of all hints, for direct Lua/gamemode callers.
local function setControls(list)
  controls = {}
  for i, item in ipairs(list or {}) do
    local category = item.category or item.action or item.uiEvent or tostring(i)
    controls[category] = {
      action = item.action,
      uiEvent = item.uiEvent,
      label = item.label,
      order = item.order or i,
    }
  end
  sendAll()
end

local function clearControls()
  controls = {}
  guihooks.trigger('SetMissionControlsResetAll')
end

local function sendAllData()
  sendAll()
end

M.setControl = setControl
M.setControls = setControls
M.clearControls = clearControls
M.sendAllData = sendAllData

return M
