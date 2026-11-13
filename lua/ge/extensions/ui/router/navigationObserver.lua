-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
--[[
  NavigationObserver

  Non-shipping diagnostics for the Lua router. It attributes each navigate() call to
  the external Lua caller that triggered it and warns when one navigation preempts
  another that is still in flight (an active transition being replaced, or a navigate()
  whose epoch was bumped by a re-entrant navigate() during its guards/onEnter).

  It classifies each preemption from the two resolved requests involved:
    - duplicate_navigation    - the two requests are identical (route, params, scope, options)
    - conflicting_navigation  - the requests differ in any of those

  This module owns no router behavior: it only records attempts and emits warnings. It
  must only be required and invoked when shipping_build ~= true.
]]

local M = {}

M.ModuleName = "navigationObserver"

-- The most recent attempt begun by navigate(). A re-entrant navigate() during an older
-- navigate()'s guards/onEnter overwrites this, so the older call can compare itself against
-- the newer "current" attempt when its epoch check fails.
local currentAttempt = nil
local attemptCounter = 0

-- Guards against double-reporting: keyed by the preempted attempt id.
local reportedAttempts = {}

-- Frames belonging to the router subsystem (this module included) are skipped when walking
-- the stack, so the captured source is the external caller and not a router wrapper.
local function isRouterInternalSource(source)
  if not source then
    return true
  end
  return source:find("ui/router/", 1, true) ~= nil
end

local function normalizeSource(source)
  if type(source) ~= "string" then
    return nil
  end
  return (source:gsub("^@", ""):gsub("\\", "/"))
end

local function toModuleName(file)
  if not file then
    return nil
  end
  local moduleName = file:gsub("%.lua$", "")
  moduleName = moduleName:gsub("^lua/", "")
  moduleName = moduleName:gsub("^ge/extensions/", "")
  moduleName = moduleName:gsub("/", ".")
  return moduleName
end

-- Walk up the stack and return the first frame outside the router subsystem. Falls back to
-- bridge/unknown when the navigate() came from a non-Lua caller (bridge/engine) or no Lua
-- frame is available.
local function captureSource()
  for level = 2, 24 do
    local info = debug.getinfo(level, "nSl")
    if not info then
      break
    end
    local file = normalizeSource(info.source)
    if file and not isRouterInternalSource(file) then
      return {
        module = toModuleName(file),
        file = file,
        func = info.name,
        line = info.currentline,
      }
    end
  end

  return {
    module = "bridge/unknown",
    file = nil,
    func = nil,
    line = nil,
  }
end

-- Recursive value equality. Functions and other non-table values compare by identity, which is
-- what we want for option values such as decorator callbacks.
local function deepEqual(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for key, value in pairs(a) do
    if not deepEqual(value, b[key]) then
      return false
    end
  end
  for key in pairs(b) do
    if a[key] == nil then
      return false
    end
  end
  return true
end

-- Two attempts describe the same navigation when their resolved route, scope, effective params
-- and options all match.
local function requestsAreIdentical(a, b)
  if a.route ~= b.route then
    return false
  end
  if a.scope ~= b.scope then
    return false
  end
  if not deepEqual(a.params or {}, b.params or {}) then
    return false
  end
  if not deepEqual(a.options or {}, b.options or {}) then
    return false
  end
  return true
end

local function describeSource(attempt)
  local source = attempt and attempt.source or nil
  if not source then
    return "bridge/unknown"
  end
  if source.file then
    return string.format("%s (%s)",
      tostring(source.module or source.file),
      tostring(source.func or "?"))
  end
  return tostring(source.module or "bridge/unknown")
end

local function describeRequest(attempt)
  if not attempt or not attempt.route then
    return "route=<unresolved>"
  end
  return string.format("route=%s scope=%s",
    tostring(attempt.route),
    tostring(attempt.scope or "none"))
end

local function formatWarning(record)
  return string.format(
    "%s: navigation from %s [%s] preempted by %s [%s] (phase: %s); check and fix duplicate navigation",
    record.category,
    describeSource(record.preempted), describeRequest(record.preempted),
    describeSource(record.replacement), describeRequest(record.replacement),
    tostring(record.phase))
end

--[[
  Begin a new attempt at navigate() entry, capturing the external Lua caller. Must be called
  before any router wrapper obscures the caller. Returns the attempt so the navigate() call can
  hold its own reference across re-entrant navigations.
]]
M.beginAttempt = function()
  attemptCounter = attemptCounter + 1
  currentAttempt = {
    id = attemptCounter,
    source = captureSource(),
    route = nil,
    params = nil,
    scope = nil,
    options = nil,
  }
  return currentAttempt
end

-- Attach the resolved navigation target (canonical route, effective params, scope, options) to
-- an attempt after resolveNavigationTarget() succeeds.
M.attachResolvedTarget = function(attempt, target)
  if not attempt or not target then
    return
  end
  attempt.route = target.fullRouteName
  attempt.params = target.params
  attempt.scope = target.options and target.options.routeScopeId or nil
  attempt.options = target.options
end

M.getCurrentAttempt = function()
  return currentAttempt
end

--[[
  Report a proven preemption: preemptedAttempt was in flight when replacementAttempt superseded
  it. Classifies the pair, emits a single warning, and returns the record. Skips no-op cases
  (missing attempts, self-preemption) and never reports the same preempted attempt twice.

  @param preemptedAttempt - the older navigation that was cut short
  @param replacementAttempt - the navigation that superseded it
  @param phase - diagnostic label for where the preemption was detected
  @return the warning record, or nil when nothing was reported
]]
M.reportPreemption = function(preemptedAttempt, replacementAttempt, phase)
  if not preemptedAttempt or not replacementAttempt then
    return nil
  end
  if preemptedAttempt.id == replacementAttempt.id then
    return nil
  end
  if reportedAttempts[preemptedAttempt.id] then
    return nil
  end
  reportedAttempts[preemptedAttempt.id] = true

  local record = {
    category = requestsAreIdentical(preemptedAttempt, replacementAttempt)
      and "duplicate_navigation" or "conflicting_navigation",
    phase = phase,
    preempted = preemptedAttempt,
    replacement = replacementAttempt,
  }

  log("W", "LuaRouterObserver", formatWarning(record))
  return record
end

M.reset = function()
  currentAttempt = nil
  attemptCounter = 0
  reportedAttempts = {}
end

return M
