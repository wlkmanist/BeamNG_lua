-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  routeReference

  Pure helpers to normalize decorated navigation references of the form:

    route[?key=value&...][:scope]

  The route part may still be relative (e.g. "./options"); this module does not
  resolve relative names. It only splits the decoration (inline query + scope)
  off the raw route reference and decodes the inline params.

  Inline param values stay strings. Explicit params passed programmatically win
  over inline params on collision (see mergeParams).
]]

local M = {}

-- Percent-decode a query component and turn '+' into a space, matching the
-- application/x-www-form-urlencoded convention used when the reference is built.
local function urlDecode(value)
  if type(value) ~= "string" then
    return value
  end
  value = string.gsub(value, "+", " ")
  value = string.gsub(value, "%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  return value
end

-- Parse the "a=1&b=2" segment into a params table. Values remain strings.
-- Repeated keys keep the last value and emit a warning. Bare keys ("flag")
-- resolve to an empty string value.
local function parseQuery(query)
  local params = {}
  if type(query) ~= "string" or query == "" then
    return params
  end

  for pair in string.gmatch(query, "[^&]+") do
    local eqIndex = string.find(pair, "=", 1, true)
    local rawKey, rawValue
    if eqIndex then
      rawKey = string.sub(pair, 1, eqIndex - 1)
      rawValue = string.sub(pair, eqIndex + 1)
    else
      rawKey = pair
      rawValue = ""
    end

    local key = urlDecode(rawKey)
    if key ~= "" then
      if params[key] ~= nil then
        log("W", "routeReference", "Duplicate inline param '" .. key .. "', keeping last value")
      end
      params[key] = urlDecode(rawValue)
    end
  end

  return params
end

-- Split "route[?query][:scope]" into its parts.
-- Returns { route = string, scope = string|nil, params = table }.
-- Non-string references pass through untouched with empty params.
M.parse = function(reference)
  if type(reference) ~= "string" then
    return { route = reference, scope = nil, params = {} }
  end

  local routePart = reference
  local scopeId = nil
  local query = nil

  local queryIndex = string.find(reference, "?", 1, true)
  if queryIndex then
    routePart = string.sub(reference, 1, queryIndex - 1)
    local rest = string.sub(reference, queryIndex + 1)
    -- Scope follows the query, so the first ':' after '?' separates them.
    local scopeIndex = string.find(rest, ":", 1, true)
    if scopeIndex then
      query = string.sub(rest, 1, scopeIndex - 1)
      scopeId = string.sub(rest, scopeIndex + 1)
    else
      query = rest
    end
  else
    -- No inline query: fall back to plain "route[:scope]" splitting.
    local scopeIndex = string.find(reference, ":", 1, true)
    if scopeIndex then
      routePart = string.sub(reference, 1, scopeIndex - 1)
      scopeId = string.sub(reference, scopeIndex + 1)
    end
  end

  -- Guard against malformed splits (empty route or empty scope); treat the
  -- whole reference as an undecorated route name, matching legacy behavior.
  if routePart == "" then
    return { route = reference, scope = nil, params = {} }
  end
  if scopeId == "" then
    scopeId = nil
  end

  return {
    route = routePart,
    scope = scopeId,
    params = parseQuery(query),
  }
end

-- Overlay explicit params on top of inline params. Explicit params win on
-- collision and log a warning. Inline values are copied as-is (strings).
M.mergeParams = function(inlineParams, explicitParams)
  local merged = {}
  if type(inlineParams) == "table" then
    for k, v in pairs(inlineParams) do
      merged[k] = v
    end
  end
  if type(explicitParams) == "table" then
    for k, v in pairs(explicitParams) do
      if merged[k] ~= nil and merged[k] ~= v then
        log("W", "routeReference", "Explicit param '" .. tostring(k) .. "' overrides inline value")
      end
      merged[k] = v
    end
  end
  return merged
end

M.urlDecode = urlDecode
M.parseQuery = parseQuery

return M
