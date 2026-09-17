local M = {}

local Constants = require("ge/extensions/ui/router/constants")

M.isRelativeRoute = function(route)
  if type(route) ~= "string" then
    return false
  end

  -- Check for Angular style (^.)
  if string.sub(route, 1, 1) == "^" then
    return true
  end

  -- Check for Vue style (./ or ../)
  if string.sub(route, 1, 1) == "." then
    return true
  end

  return false
end

M.resolveRelativeRoute = function(route, currentState)
  if not M.isRelativeRoute(route) then
    return route -- Already absolute
  end

  -- Get current state parts
  local currentParts = {}
  for part in string.gmatch(currentState, "[^%.]+") do
    table.insert(currentParts, part)
  end

  -- Detect which style of relative path and process accordingly
  local upCount = 0
  local remaining = route

  -- Handle Angular style (^.)
  if string.sub(route, 1, 1) == "^" then
    while string.sub(remaining, 1, 1) == "^" do
      upCount = upCount + 1
      remaining = string.sub(remaining, 2) -- Remove the ^
    end

    if string.sub(remaining, 1, 1) == "." then
      remaining = string.sub(remaining, 2) -- Remove leading dot if present
    end

  -- Handle Vue style (./ or ../)
  elseif string.sub(route, 1, 1) == "." then
    -- Handle current level (./)
    if string.sub(route, 1, 2) == "./" then
      remaining = string.sub(route, 3) -- Skip ./ and keep at current level
      upCount = 0
    else
      -- Count ../ sequences for parent navigation
      remaining = route
      while string.sub(remaining, 1, 3) == "../" do
        upCount = upCount + 1
        remaining = string.sub(remaining, 4) -- Remove ../
      end

      -- Also handle .. without trailing slash
      while string.sub(remaining, 1, 2) == ".." and (string.len(remaining) == 2 or string.sub(remaining, 3, 3) == "." or string.sub(remaining, 3, 3) == "/") do
        upCount = upCount + 1
        remaining = string.sub(remaining, 3) -- Remove ..

        -- Remove separator if present
        if string.sub(remaining, 1, 1) == "/" then
          remaining = string.sub(remaining, 2)
        end
      end
    end

    -- Convert slashes to dots for internal consistency
    remaining = string.gsub(remaining, "/", ".")
  end

  -- Remove parts based on upCount
  for i = 1, upCount do
    if #currentParts > 0 then
      table.remove(currentParts)
    end
  end

  -- Build the full path
  local parentPath = table.concat(currentParts, ".")

  -- Handle edge cases with empty strings
  if remaining == "" then
    return parentPath
  elseif parentPath == "" then
    return remaining
  else
    return parentPath .. "." .. remaining
  end
end

-- TODO: Need to clean up or remove above functions
-- ======================================================
local function deepMerge(target, source)
  if type(source) ~= "table" then
    return source ~= nil and source or target
  end
  if type(target) ~= "table" then
    target = {}
  end

  for key, sourceValue in pairs(source) do
    local targetValue = target[key]
    if type(sourceValue) == "table" and type(targetValue) == "table" then
      -- Recursively merge nested tables
      target[key] = deepMerge(targetValue, sourceValue)
    else
      -- Override with source value
      target[key] = sourceValue
    end
  end

  return target
end

local function resolveFunctionReference(reference, contextLabel)
  if reference == nil then
    return nil, nil, nil
  end

  local label = contextLabel
  if type(label) ~= "string" or label == "" then
    label = "Function reference"
  end

  if type(reference) ~= "string" then
    return nil, string.format("%s must be a string, got %s", label, type(reference)), true
  end

  -- Split on the last dot: everything before is the module name, after is the function name
  local lastDot = reference:match("^.*()%.")
  if not lastDot then
    return nil, string.format("%s: invalid format %q (expected 'module.func')", label, reference), true
  end

  local moduleName = reference:sub(1, lastDot - 1)
  local funcName = reference:sub(lastDot + 1)
  if moduleName == "" or funcName == "" then
    return nil, string.format("%s: invalid format %q (empty module or function name)", label, reference), true
  end

  -- extensions[moduleName] auto-loads the extension via __index metamethod
  local mod = extensions[moduleName]
  if not mod then
    return nil, string.format("%s: module %q not found", label, moduleName), true
  end

  local func = mod[funcName]
  if type(func) ~= "function" then
    return nil, string.format("%s: %q is not a function in module %q", label, funcName, moduleName), true
  end

  return func, nil, nil
end

M.deepMerge = deepMerge
M.resolveFunctionReference = resolveFunctionReference

return M