-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Provides an optional routing layer in front of the existing camera input
-- path. Registered controllers can consume selected inputs when enabled, while
-- unhandled input continues to the active camera as before.

local M = {}

local controllers = {}
local ordered = {}
local captureOwner = nil
local dispatchCandidate = nil

local function rebuildOrder()
  table.clear(ordered)
  for id, entry in pairs(controllers) do
    ordered[#ordered + 1] = {
      id = id,
      controller = entry.controller,
      priority = entry.priority
    }
  end
  table.sort(ordered, function(first, second)
    if first.priority ~= second.priority then return first.priority > second.priority end
    return first.id < second.id
  end)
end

function M.register(id, controller, priority)
  if type(id) ~= "string" or id == "" or type(controller) ~= "table" then return false end
  if controllers[id] then return false end
  controllers[id] = {
    controller = controller,
    priority = tonumber(priority) or 0
  }
  rebuildOrder()
  return true
end

function M.unregister(id, controller)
  local entry = controllers[id]
  if not entry or controller and entry.controller ~= controller then return false end
  controllers[id] = nil
  if captureOwner == id then captureOwner = nil end
  rebuildOrder()
  return true
end

function M.dispatch(method, ...)
  if captureOwner then
    local entry = controllers[captureOwner]
    local callback = entry and entry.controller[method]
    dispatchCandidate = captureOwner
    local consumed = callback and callback(...) == true or false
    dispatchCandidate = nil
    return consumed
  end
  for _, entry in ipairs(ordered) do
    local callback = entry.controller[method]
    dispatchCandidate = entry.id
    local consumed = callback and callback(...) == true
    dispatchCandidate = nil
    if consumed then return true end
  end
  return false
end

function M.acquire(id)
  if not controllers[id] or captureOwner and captureOwner ~= id then return false end
  if not captureOwner
    and dispatchCandidate ~= id
    and ordered[1]
    and ordered[1].id ~= id then
    return false
  end
  captureOwner = id
  return true
end

function M.release(id)
  if captureOwner ~= id then return false end
  captureOwner = nil
  return true
end

function M.isOwner(id)
  return captureOwner == id
end

function M.isRegistered(id, controller)
  local entry = controllers[id]
  return entry ~= nil and (not controller or entry.controller == controller)
end

return M
