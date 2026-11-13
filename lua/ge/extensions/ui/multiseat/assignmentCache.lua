local M = {}

local assignments = nil
local logTag = "multiseatAssignmentCache"

function M.onInit()
  setExtensionUnloadMode(M, "manual")
  log("I", logTag, "initialized with manual unload mode")
end

function M.set(value, reason)
  assignments = deepcopy(value)
  log("I", logTag, "set: reason=" .. tostring(reason) .. " value=" .. dumps(assignments))
end

function M.get(reason)
  local result = deepcopy(assignments)
  log("I", logTag, "get: reason=" .. tostring(reason) .. " value=" .. dumps(result))
  return result
end

return M
