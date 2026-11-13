-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local deployFilterPath = "/DevTools/deployfilters/shared_prepack.txt"
local deployFilterRules
local shippedPathCache = {}

local function deployGlobToLuaPattern(rule)
  local result = {}
  local index = 1
  while index <= #rule do
    local char = rule:sub(index, index)
    if char == "*" then
      if rule:sub(index + 1, index + 1) == "*" then
        result[#result + 1] = ".*"
        index = index + 2
      else
        result[#result + 1] = "[^/]*"
        index = index + 1
      end
    elseif char == "?" then
      result[#result + 1] = "[^/]"
      index = index + 1
    else
      result[#result + 1] = char:gsub("([%^%$%(%)%%%.%[%]%+%-])", "%%%1")
      index = index + 1
    end
  end
  return table.concat(result)
end

local function loadDeployFilterRules()
  deployFilterRules = {}
  local content = readFile(deployFilterPath)
  if not content then return end

  for line in content:gmatch("[^\r\n]+") do
    local rule = line:match("^%s*(.-)%s*$")
    if rule ~= "" and rule:sub(1, 1) ~= "#" then
      rule = rule:lower()
      deployFilterRules[#deployFilterRules + 1] = {
        rule = rule,
        pattern = deployGlobToLuaPattern(rule)
      }
    end
  end
end

local function deployRuleMatches(path, rule)
  if path:find(rule.rule, 1, true) == 1 then return true end
  if rule.rule:sub(1, 1) ~= "/" then
    return path:match("^" .. rule.pattern .. "$") ~= nil
  end
  return path:match("^" .. rule.pattern .. "$") ~= nil
    or path:match("^" .. rule.pattern .. "/.*$") ~= nil
end

local function isPathShipped(path)
  if not deployFilterRules then loadDeployFilterRules() end
  path = path:lower()
  local cached = shippedPathCache[path]
  if cached ~= nil then return cached end

  local shipped = true
  for _, rule in ipairs(deployFilterRules) do
    if deployRuleMatches(path, rule) then
      shipped = false
      break
    end
  end
  shippedPathCache[path] = shipped
  return shipped
end

function M.isModelShipped(modelName)
  return isPathShipped("/vehicles/" .. modelName .. "/")
end

function M.isConfigShipped(modelName, configName)
  return M.isModelShipped(modelName)
    and isPathShipped("/vehicles/" .. modelName .. "/" .. configName .. ".pc")
end

function M.clearCache()
  deployFilterRules = nil
  shippedPathCache = {}
end

return M
