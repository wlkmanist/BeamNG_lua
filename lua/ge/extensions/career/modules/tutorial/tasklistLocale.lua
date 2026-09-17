-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function isTranslationKey(value)
  return type(value) == "string" and value:sub(1, 3) == "ui."
end

local function translateField(value)
  if isTranslationKey(value) then
    return _tr(value)
  end
  if type(value) == "table" and value.txt then
    return core_locales.translateWithOrWithoutContext(value)
  end
  return value
end

local function copyAndResolve(entry)
  if not entry then return entry end
  if entry.clear then return entry end

  local result = {}
  for key, value in pairs(entry) do
    result[key] = value
  end
  result.label = translateField(result.label)
  result.subtext = translateField(result.subtext)
  result.labelController = translateField(result.labelController)
  result.subtextController = translateField(result.subtextController)
  if type(result.actionItems) == "table" then
    fillActionLabels(result.actionItems)
  end
  return result
end

function M.resolveHeader(header)
  return copyAndResolve(header)
end

function M.resolveTask(task)
  return copyAndResolve(task)
end

function M.setTasklistHeader(header)
  guihooks.trigger("SetTasklistHeader", M.resolveHeader(header))
end

function M.setTasklistTask(task)
  guihooks.trigger("SetTasklistTask", M.resolveTask(task))
end

return M
