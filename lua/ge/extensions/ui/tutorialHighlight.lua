local M = {}

local streamName = "tutorialHighlight"
local activeIds = {}
local activeIdOrder = {}
local activeOptions = {}
local revision = 0

local function normalizeOptions(options)
  if type(options) ~= "table" then return {} end
  local normalized = {}
  if options.focus == true then normalized.focus = true end
  if options.scroll == true then normalized.scroll = true end
  return normalized
end

local function buildPayload()
  local ids = {}
  local options = {}
  for _, id in ipairs(activeIdOrder) do
    if activeIds[id] then
      table.insert(ids, id)
      if not tableIsEmpty(activeOptions[id]) then
        options[id] = activeOptions[id]
      end
    end
  end
  return {
    ids = ids,
    options = options,
    revision = revision,
  }
end

local function broadcast()
  -- dump("broadcast: " .. dumps(buildPayload()))
  guihooks.triggerStream(streamName, buildPayload())
end

local function isValidId(id)
  return type(id) == "string" and id ~= ""
end

local function show(id, options)
  if not isValidId(id) then
    -- dump("tutorialHighlight.show rejected invalid id: " .. dumps(id))
    return false
  end

  local changed = not activeIds[id]
  if changed then
    activeIds[id] = true
    table.insert(activeIdOrder, id)
  end
  revision = revision + 1
  activeOptions[id] = normalizeOptions(options)
  if not tableIsEmpty(activeOptions[id]) then
    activeOptions[id].requestId = revision
  end
  -- dump("tutorialHighlight.show: " .. id .. ", changed: " .. tostring(changed) .. ", options: " .. dumps(activeOptions[id]))
  broadcast()
  return changed
end

local function hide(id)
  if not isValidId(id) or not activeIds[id] then
    -- dump("tutorialHighlight.hide ignored id: " .. dumps(id))
    return false
  end

  activeIds[id] = nil
  activeOptions[id] = nil
  for index, activeId in ipairs(activeIdOrder) do
    if activeId == id then
      table.remove(activeIdOrder, index)
      break
    end
  end
  revision = revision + 1
  -- dump("tutorialHighlight.hide: " .. id)
  broadcast()
  return true
end

local function hideAll()
  if tableIsEmpty(activeIds) then return false end

  table.clear(activeIds)
  table.clear(activeIdOrder)
  table.clear(activeOptions)
  revision = revision + 1
  broadcast()
  return true
end

local function onUiReady()
  broadcast()
end

local function onInit()
  setExtensionUnloadMode(M, "manual")
end

M.show = show
M.hide = hide
M.hideAll = hideAll
M.getState = buildPayload
M.onUiReady = onUiReady
M.onInit = onInit

return M
