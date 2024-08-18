-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local advancedCsvReader

--function used as a case selector, input can be both int and bool as the first argument, any number of arguments after that
--in case it's a bool, it works like a ternary if, returning the second param if true, the third if false
--if the selector is an int n, it simply returns the nth+1 param it was given, if n > #params it returns the last given param
local function case(selector, ...)
  local index = 0
  local selectorType = type(selector)

  if selectorType == "boolean" then
    index = selector and 1 or 2
  elseif selectorType == "number" then
    index = math.floor(selector) --make sure we have an int for table access
  else
    log('E', "jbeam.expressionParser.parse", "Only booleans and numbers are supported as case selectors! Defaulting to last argument... Type: " .. tostring(selectorType))
  end

  local arg = {...}
  return arg[index] or arg[select("#", ...)] --fetch value from given index or from the last index
end

local function includeExternalResource(resourceURI)
  if type(resourceURI) ~= 'string' then return end

  -- TODO: URL, URI, etc

  local _, _, ext = path.split(resourceURI:lower(), true)
  if ext == '.csv' then
    if not advancedCsvReader then advancedCsvReader = require('advancedCsvReader') end
    if not advancedCsvReader then
      log('E', '', 'CSV parser not available')
      return nil, 'CSV parser not available'
    end
    return advancedCsvReader.parseCSVFile()
  end
  log('E', '', 'Unsupported file format: ' .. tostring(filename))
  return nil, 'Unsupported file format: ' .. tostring(filename)
end

local varWrapper = {}
local context = {
  round = round,
  square = square,
  clamp = clamp,
  smoothstep = smoothstep,
  smootherstep = smootherstep,
  smoothmin = smoothmin,
  sign = sign,
  case = case,
  vec3 = vec3,
  quat = quat,
  concat = table.concat,
  include = includeExternalResource,
  print = function(val, label)
    if label then
      print(tostring(label) ..' = ' .. tostring(val))
    else
      print(tostring(val))
    end
    return val
  end
}
for k, v in pairs(math) do
  context[k] = v
end

setmetatable(context, {
  __index = function(tbl, key)
    local val = varWrapper.vars['$' .. key:sub(5)]
    if type(val) == "table" then return val.val else return val end
  end,
  __newindex = function(tbl, key, value) error(string.format("Attempt to modify read-only table entry: %s = %s", key, value)) end,
  __metatable = false
})

local function parseSafe(expr, vars)
  local originalExpr = expr
  varWrapper.vars = vars
  --strip leading "$=" from expression and replace all occurences of "$" with "_" (as these are used for lua variable names)
  expr = expr:sub(3):gsub('%$', 'var_')

  --check if we find a *single standalone* "=" sign and abort parsing if found. >=, <=, == and ~= are allowed to support boolean operations
  if expr:find("[^<>~=]=[^=]") then
    log('E', "jbeam.expressionParser.parse", "Assignments are not supported inside expressions!")
    return nil
  end

  --load the now sanitized and sandbox checked code with our custom environment
  local exprFunc, message = load("return " .. expr, nil, 't', context)
  if exprFunc then
    --execute the loaded code in protected mode to catch any non syntax errors
    local success, result = pcall(exprFunc)
    if not success then
      log('E', "jbeam.expressionParser.parse", "Failed executing expression")
      log('E', "jbeam.expressionParser.parse", '  Original:  "' .. tostring(originalExpr).. '"')
      log('E', "jbeam.expressionParser.parse", '  Processed: "return ' .. expr .. '"')
      log('E', "jbeam.expressionParser.parse", "  Error:     " .. tostring(result))
      return nil
    end
    --dump{'expr = ', expr, ' = ', result}
    return result
  else
    --syntax error most likely
    log('E', "jbeam.expressionParser.parse", "Parsing expression failed, message: " .. tostring(message))
    return nil
  end
end

local function parse(expr, vars)
  varWrapper.vars = vars


  --strip leading "$=" from expression and replace all occurences of "$" with "_" (as these are used for lua variable names)
  expr = expr:sub(3):gsub('%$', 'var_')

  --check if we find a *single standalone* "=" sign and abort parsing if found. >=, <=, == and ~= are allowed to support boolean operations
  if expr:find("[^<>~=]=[^=]") then
    log('E', "jbeam.expressionParser.parse", "Assignments are not supported inside expressions!")
    return nil
  end

  --load the now sanitized and sandbox checked code with our custom environment
  local exprFunc, message = load("return " .. expr, nil, 't', context)
  return exprFunc()
end

M.parseSafe = parseSafe
M.parse = parse


-- compiles a function so that it can be re-used, instead of compile+evaluate in one step

local function compileSafe(expr)
  local varWrapper = {vars = {}}
  local context = {
    round = round,
    square = square,
    clamp = clamp,
    smoothstep = smoothstep,
    smootherstep = smootherstep,
    smoothmin = smoothmin,
    sign = sign,
    case = case,
    include = includeExternalResource,
    print = function(val, label)
      if label then
        print(tostring(label) ..' = ' .. tostring(val))
      else
        print(tostring(val))
      end
      return val
    end
  }
  for k, v in pairs(math) do
    context[k] = v
  end

  setmetatable(context, {
    __index = function(tbl, key)
      local val = varWrapper.vars['$' .. key:sub(5)]
      if type(val) == "table" then return val.val else return val end
    end,
    __newindex = function(tbl, key, value) error(string.format("Attempt to modify read-only table entry: %s = %s", key, value)) end,
    __metatable = false
  })


  --strip leading "$=" from expression and replace all occurences of "$" with "_" (as these are used for lua variable names)
  expr = expr:sub(3):gsub('%$', 'var_')

  --check if we find a *single standalone* "=" sign and abort parsing if found. >=, <=, == and ~= are allowed to support boolean operations
  if expr:find("[^<>~=]=[^=]") then
    log('E', "jbeam.expressionParser.parse", "Assignments are not supported inside expressions!")
    return nil, nil
  end

  --load the now sanitized and sandbox checked code with our custom environment
  local exprFunc, message = load("return " .. expr, nil, 't', context)
  if exprFunc then
    return exprFunc, varWrapper.vars
  else
    --syntax error most likely
    log('E', "jbeam.expressionParser.parse", "Parsing expression failed, message: " .. tostring(message))
    return nil, nil
  end
end
M.compileSafe = compileSafe


return M