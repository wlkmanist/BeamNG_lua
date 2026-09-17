-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Owns the canonical list of system pacenote names and validates a style's
-- `system` array. Every name listed in `M.required` must be provided by every
-- style; unknown names are rejected. Iteration order is the `M.required` order.

local M = {}

local logTag = 'systemPacenotes'

M.required = {
  'precountdown',
  'countdown5',
  'countdown4',
  'countdown3',
  'countdown2',
  'countdown1',
  'countdowngo',
  'warningSeconds60',
  'warningSeconds30',
  'warningSeconds15',
  'warningSeconds10',
  'commsCheck',
  'beltsCheck',
  'rescheduled',
  'falseStart',
}

local requiredSet = {}
for _, name in ipairs(M.required) do
  requiredSet[name] = true
end

local function isList(t)
  if type(t) ~= 'table' then return false end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n == #t
end

local function variantsFrom(value)
  if type(value) == 'string' then
    return { { text = value } }
  end

  if type(value) ~= 'table' then
    return {}
  end

  if type(value.text) == 'string' then
    return { value }
  end

  local variants = {}
  for _, variant in ipairs(value) do
    if type(variant) == 'string' then
      table.insert(variants, { text = variant })
    elseif type(variant) == 'table' then
      table.insert(variants, variant)
    end
  end
  return variants
end

-- Builds the ordered system pacenote array used by styles from a compact
-- language-specific text map. This keeps required ids/order here while style
-- language folders own the actual localized phrases.
function M.localized(localized)
  localized = localized or {}
  local out = {}
  for _, name in ipairs(M.required) do
    table.insert(out, {
      name = name,
      variants = variantsFrom(localized[name]),
    })
  end
  return out
end

function M.validate(systemArray, styleName)
  styleName = styleName or '?'

  if not isList(systemArray) then
    log('E', logTag, "style '"..styleName.."': system must be an ordered array of { name, variants }")
    return false
  end

  local seen = {}
  for i, entry in ipairs(systemArray) do
    if type(entry) ~= 'table' then
      log('E', logTag, "style '"..styleName.."': system["..i.."] must be a table")
      return false
    end

    local name = entry.name
    if type(name) ~= 'string' then
      log('E', logTag, "style '"..styleName.."': system["..i.."] missing string `name`")
      return false
    end

    if M.required[i] and name ~= M.required[i] then
      log('E', logTag, "style '"..styleName.."': system["..i.."] must be '"..tostring(M.required[i]).."'")
      return false
    end

    if not requiredSet[name] then
      log('E', logTag, "style '"..styleName.."': unrecognized system pacenote name '"..name.."'")
      return false
    end

    if seen[name] then
      log('E', logTag, "style '"..styleName.."': duplicate system pacenote name '"..name.."'")
      return false
    end
    seen[name] = true

    local variants = entry.variants
    if not isList(variants) or #variants == 0 then
      log('E', logTag, "style '"..styleName.."': system pacenote '"..name.."' must have a non-empty `variants` list")
      return false
    end

    for vi, variant in ipairs(variants) do
      if type(variant) ~= 'table' or type(variant.text) ~= 'string' or variant.text == '' then
        log('E', logTag, "style '"..styleName.."': system pacenote '"..name.."' variant "..vi.." missing `text`")
        return false
      end
    end
  end

  for _, name in ipairs(M.required) do
    if not seen[name] then
      log('E', logTag, "style '"..styleName.."': missing required system pacenote '"..name.."'")
      return false
    end
  end

  return true
end

return M
