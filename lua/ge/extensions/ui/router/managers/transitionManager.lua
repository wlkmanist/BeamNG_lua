-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
--[[
  TransitionManager

  Manages the lifecycle of route transitions. Tracks whether a transition
  is in progress, owns the active transition session (progress milestones,
  phase, phase/total elapsed time, handoff resend timing) and classifies
  timeouts. Determines behavior when new navigation requests arrive during
  an active transition.

  Time is tracked using accumulated dtReal from the game's onGuiUpdate hook,
  not os.clock() or os.time(). The main router extension must call update(dtReal)
  each frame for proper time tracking.

  Boundary: this manager owns transition session/progress state and timing
  decisions. It never performs router side effects itself; update() returns
  events (resend/timeout) and router.lua reacts to them (FrameworkManager,
  route data emission, lifecycle hooks, loading screen).
]] local Constants = require("ge/extensions/ui/router/constants")
local Config = require("ge/extensions/ui/router/config")

local M = {}

local errorTimeoutOccurred = false

-- Internal state
local state = {
  status = Constants.TransitionStatus.IDLE,
  transitionId = nil,
  elapsedTime = 0, -- Accumulated from dtReal, not os.clock()

  -- transition context
  kind = nil, -- push, pushAndResetHistory, replace, back, forward
  toRoute = nil,
  fromRoute = nil,

  -- Active transition session. Created by router.lua (createTransitionMeta) and
  -- handed to start(); owned here for its lifetime. Shape:
  --   routeName             -- base route name of the transition
  --   routeData             -- route data table (read by router side effects)
  --   navigationContext     -- nav context (read by router for onMount)
  --   pendingEntry          -- exact entry to re-emit on handoff resend
  --   skipOnMount           -- skip onMount when enter failed
  --   mounted               -- routeMounted ack received
  --   routeChangeCommitted  -- routeChangeComplete promoted the entry
  --   expectsMountAck       -- transition finishes at routeMounted (phased only)
  --   phase                 -- nil for flat (Angular/legacy); phase name for handoff transitions
  --   phaseElapsed          -- accumulated dtReal in the current phase
  --   totalElapsed          -- accumulated dtReal across all phases
  --   timeSinceLastEmit     -- accumulated dtReal since the last route-change emit
  --   handoffAttempts       -- number of route-change emits so far (initial + resends)
  --   progress              -- { routeChangeReceived, routeNavigationStarted, routeChangeCommitted, routeMounted }
  session = nil
}

-- Generate unique transition ID
local transitionCounter = 0
local function generateTransitionId()
  transitionCounter = transitionCounter + 1
  return "transition_" .. transitionCounter .. "_" .. Engine.generateUUID()
end

-- The route name an acknowledgement is expected to reference. Prefers the exact
-- pending entry's resolved name, then the session base route name, then the active
-- transition target route.
local function getExpectedRouteName()
  local session = state.session
  if session then
    local pendingEntry = session.pendingEntry
    if pendingEntry and pendingEntry.resolved and pendingEntry.resolved.name then
      return pendingEntry.resolved.name
    end
    if session.routeName then
      return session.routeName
    end
  end
  if state.toRoute then
    return state.toRoute.name
  end
  return nil
end

-- Optional transition-id match. Missing ids fall back to route-name validation for
-- compatibility, so nil is treated as "no id supplied" and always matches.
local function transitionIdMatches(transitionId)
  return transitionId == nil or state.transitionId == nil or transitionId == state.transitionId
end

-- Get current status
M.getStatus = function()
  return state.status
end

-- Check if currently transitioning
M.isTransitioning = function()
  return state.status == Constants.TransitionStatus.TRANSITIONING
end

-- Get current transition ID
M.getTransitionId = function()
  return state.transitionId
end

-- Get elapsed time since transition started (accumulated from dtReal)
M.getElapsedTime = function()
  return state.elapsedTime
end

-- Check if hard timeout reached
M.isTimeoutReached = function()
  return state.elapsedTime >= Config.Timeout
end

M.getKind = function()
  return state.kind
end

M.getToRoute = function()
  return state.toRoute
end

M.getFromRoute = function()
  return state.fromRoute
end

M.getTransitionContext = function()
  return {
    transitionId = state.transitionId,
    kind = state.kind,
    toRoute = state.toRoute,
    fromRoute = state.fromRoute
  }
end

--[[
  Validate an acknowledgement against the active transition.

  Rules:
    - There must be an active transition.
    - If transitionId is provided (and one is active), it must match state.transitionId.
    - If routeName is provided, it must match the expected pending/session route name.
    - If transitionId is omitted, validation falls back to route-name only (compatibility).

  @param routeName - Route name the framework is acknowledging (optional)
  @param transitionId - Active transition id being echoed back (optional)
  @return { success, reason? }
]]
M.validateAcknowledgement = function(routeName, transitionId)
  if not M.isTransitioning() then
    return { success = false, reason = "no_active_transition" }
  end

  if not transitionIdMatches(transitionId) then
    return { success = false, reason = "transition_id_mismatch" }
  end

  if routeName ~= nil then
    local expectedRouteName = getExpectedRouteName()
    if expectedRouteName ~= nil and routeName ~= expectedRouteName then
      return { success = false, reason = "route_mismatch" }
    end
  end

  return { success = true }
end

-- Get the active transition session (nil when idle).
M.getSession = function()
  return state.session
end

--[[
  Mark a progress milestone reported by the UI framework.

  @param routeName - Route name the framework is acknowledging
  @param milestone - Progress key (routeChangeReceived | routeNavigationStarted)
  @param transitionId - Active transition id being echoed back (optional)
  @return { success, reason? }
]]
M.markProgress = function(routeName, milestone, transitionId)
  local validation = M.validateAcknowledgement(routeName, transitionId)
  if not validation.success then
    return validation
  end

  local session = state.session
  if not session or not session.progress then
    return { success = false, reason = "no_active_transition" }
  end

  session.progress[milestone] = true
  return { success = true }
end

--[[
  Mark the transition as committed (routeChangeComplete promoted the entry).
  Router owns the promotion and validation; this only records session state.

  @param routeName - Route name being committed (kept for API symmetry)
  @param transitionId - Active transition id being echoed back (optional)
  @return { success, reason? }
]]
M.markCommitted = function(routeName, transitionId)
  local session = state.session
  if not session then
    return { success = false, reason = "no_active_transition" }
  end

  if not transitionIdMatches(transitionId) then
    log("W", "TransitionManager", "Transition ID mismatch on commit. Expected: " ..
        tostring(state.transitionId) .. ", Got: " .. tostring(transitionId))
    return { success = false, reason = "transition_id_mismatch" }
  end

  session.routeChangeCommitted = true
  if session.progress then
    session.progress.routeChangeCommitted = true
  end
  return { success = true }
end

--[[
  Mark the transition as mounted (routeMounted ack processed by router).

  @param routeName - Route name being mounted (kept for API symmetry)
  @param transitionId - Active transition id being echoed back (optional)
  @return { success, reason? }
]]
M.markMounted = function(routeName, transitionId)
  local session = state.session
  if not session then
    return { success = false, reason = "no_active_transition" }
  end

  if not transitionIdMatches(transitionId) then
    log("W", "TransitionManager", "Transition ID mismatch on mount. Expected: " ..
        tostring(state.transitionId) .. ", Got: " .. tostring(transitionId))
    return { success = false, reason = "transition_id_mismatch" }
  end

  session.mounted = true
  if session.progress then
    session.progress.routeMounted = true
  end
  return { success = true }
end

-- Classify a flat (non-phased) timeout from the progress milestones reached.
local function classifyTransitionTimeout(progress)
  if not progress or not progress.routeChangeReceived then
    return "route_change_not_received"
  end
  if not progress.routeNavigationStarted then
    return "route_navigation_not_started"
  end
  if not progress.routeChangeCommitted then
    return "route_change_not_completed"
  end
  if not progress.routeMounted then
    return "route_mounted_not_acknowledged"
  end
  return "transition_timeout"
end

-- Map a phase name to the timeout classification reported when its budget expires.
local PHASE_TIMEOUT_CLASSIFICATION = {
  handoff = "route_change_not_accepted",
  routerStart = "route_navigation_not_started",
  routeCommit = "route_change_not_completed",
  mountReady = "route_mounted_not_acknowledged",
}

-- Derive the current phase from the progress acks recorded on the session.
local function computeTransitionPhase(session)
  local progress = session.progress or {}
  if not progress.routeChangeReceived then
    return "handoff"
  end
  if not progress.routeNavigationStarted then
    return "routerStart"
  end
  if not progress.routeChangeCommitted then
    return "routeCommit"
  end
  if session.expectsMountAck and not progress.routeMounted then
    return "mountReady"
  end
  return "done"
end

--[[
  Timing/classification snapshot for the router's timeout handler.

  @param classification - Optional pre-computed classification (phased path).
                          When nil, it is derived from the flat progress acks.
  @return { classification, phase, phaseElapsed, totalElapsed, handoffAttempts }
]]
M.getTimeoutInfo = function(classification)
  local session = state.session
  local progress = session and session.progress or nil
  return {
    transitionId = state.transitionId,
    classification = classification or classifyTransitionTimeout(progress),
    phase = session and session.phase or nil,
    phaseElapsed = session and session.phaseElapsed or 0,
    totalElapsed = session and session.totalElapsed or 0,
    handoffAttempts = session and session.handoffAttempts or nil,
  }
end

-- Phased regime: Vue handoff transitions (session.phase set). Advances through the
-- per-phase budgets, requests a route-change resend while waiting for the handoff ack,
-- and reports the first exceeded budget. Returns an event table or nil.
local function updatePhasedTransition(dtReal)
  local session = state.session

  session.totalElapsed = session.totalElapsed + dtReal
  session.phaseElapsed = session.phaseElapsed + dtReal
  session.timeSinceLastEmit = session.timeSinceLastEmit + dtReal

  -- advance-phases: recompute the phase from progress acks and reset the phase timer on change.
  local nextPhase = computeTransitionPhase(session)
  if nextPhase ~= session.phase then
    log("D", "Router", "Router phase " .. tostring(session.phase) .. " -> " .. tostring(nextPhase) ..
        " for route: " .. tostring(session.routeName) ..
        " after " .. string.format("%.2f", session.phaseElapsed) .. "s")
    session.phase = nextPhase
    session.phaseElapsed = 0
  end

  local cfg = Config.PhaseTimeouts

  if session.phase == "handoff" then
    if session.handoffAttempts <= cfg.handoffMaxResends and session.timeSinceLastEmit >= cfg.handoffResendDelay then
      local pendingEntry = session.pendingEntry
      if pendingEntry then
        session.handoffAttempts = session.handoffAttempts + 1
        session.timeSinceLastEmit = 0
        log("D", "Router", "Handoff resend attempt " .. session.handoffAttempts ..
            " for route: " .. tostring(session.routeName))
        return { type = "resendRouteChange", entry = pendingEntry }
      end
    end
  end

  -- classify-phase-timeouts: prefer the specific phase budget, then the emergency total cap.
  local phaseBudget = cfg[session.phase]
  if phaseBudget and session.phaseElapsed >= phaseBudget then
    local classification = PHASE_TIMEOUT_CLASSIFICATION[session.phase] or "transition_timeout"
    return { type = "timeout", reason = classification, classification = classification }
  end

  if cfg.total and session.totalElapsed >= cfg.total then
    return { type = "timeout", reason = "transition_total_timeout", classification = "transition_total_timeout" }
  end

  return nil
end

-- Flat regime: Angular/legacy transitions (no phase) rely on a single dtReal-accumulated
-- timeout. Returns a timeout event on expiry, otherwise nil.
local function updateFlatTransition(dtReal)
  state.elapsedTime = state.elapsedTime + dtReal

  -- Check for hard timeout
  if state.elapsedTime >= Config.Timeout then
    if not errorTimeoutOccurred then
      -- Report the timeout but preserve transition context so the router
      -- can own the cancellation flow. Do not clear state here.
      log("E", "Router", "Transition hard timeout reached")
      extensions.hook(Constants.RouterHooks.TRANSITION_TIMEOUT, {
        type = "hard",
        context = M.getTransitionContext()
      })
      errorTimeoutOccurred = true
      return { type = "timeout", reason = "timeout_reached" }
    end
  end

  return nil
end

--[[
  Update transition timing. Called by the main router extension from onGuiUpdate.

  Handles both timeout regimes:
    - Phased: Vue handoff transitions advance per-phase budgets and resend the
      route-change event while waiting for the handoff ack.
    - Flat: Angular/legacy transitions use a single dtReal-accumulated timeout.

  @param dtReal - Real time delta from game's onGuiUpdate hook
  @return event table or nil. Event shapes:
    { type = "resendRouteChange", entry = <pendingEntry> }
    { type = "timeout", reason = <reason>, classification = <classification?> }
]]
M.update = function(dtReal)
  if state.status ~= Constants.TransitionStatus.TRANSITIONING then
    return nil
  end

  local session = state.session
  if session and session.phase then
    return updatePhasedTransition(dtReal)
  end

  return updateFlatTransition(dtReal)
end

M.canStartTransition = function()
  return state.status ~= Constants.TransitionStatus.TRANSITIONING
end

--[[
  Start a new transition.

  @return transitionId, success
]]
M.start = function(context)
  if state.status == Constants.TransitionStatus.TRANSITIONING then
    log("W", "TransitionManager", "Starting transition while one is already in progress")
    return false, "transition_already_in_progress"
  end

  local toRoute = context.toRoute or context.resolved
  if not toRoute then
    log("E", "TransitionManager", "Cannot start transition: no target route provided")
    return false, "no_target_route"
  end

  -- Identity is a generated id, not the route name. Route context is tracked
  -- separately on state.toRoute so acknowledgements can still validate by route name.
  state.transitionId = generateTransitionId()
  state.kind = context.kind or "navigate"
  state.toRoute = toRoute
  state.fromRoute = context.fromRoute
  state.elapsedTime = 0
  state.session = context.session
  state.status = Constants.TransitionStatus.TRANSITIONING

  log("D", "TransitionManager", "Transition started: " .. toRoute.name .. " (" .. tostring(state.transitionId) .. ")")
  return true, state.transitionId
end

--[[
  Complete the current transition successfully.

  @param routeName - Route name being completed (validated against the pending/session route)
  @param transitionId - Active transition id being echoed back (optional, validated when provided)
  @return success, reason
]]
M.complete = function(routeName, transitionId)
  if state.status ~= Constants.TransitionStatus.TRANSITIONING then
    return false, "no_active_transition"
  end

  if not transitionIdMatches(transitionId) then
    log("W", "TransitionManager",
        "Transition ID mismatch on complete. Expected: " .. tostring(state.transitionId) .. ", Got: " .. tostring(transitionId))
    return false, "transition_id_mismatch"
  end

  if routeName ~= nil then
    local expectedRouteName = getExpectedRouteName()
    if expectedRouteName ~= nil and routeName ~= expectedRouteName then
      log("W", "TransitionManager",
          "Route name mismatch. Expected: " .. tostring(expectedRouteName) .. ", Got: " .. tostring(routeName))
      return false, "route_name_mismatch"
    end
  end

  local completedId = state.transitionId
  state.status = Constants.TransitionStatus.IDLE
  state.transitionId = nil
  state.elapsedTime = 0
  state.kind = nil
  state.toRoute = nil
  state.fromRoute = nil
  state.session = nil
  errorTimeoutOccurred = false

  log("D", "TransitionManager", "Transition completed: " .. completedId)
  return true, "completed"
end

--[[
  Cancel the current transition.

  @param reason - Reason for cancellation
  @return wasTransitioning, transitionId
]]
M.cancel = function(reason)
  reason = reason or "cancelled"

  if state.status ~= Constants.TransitionStatus.TRANSITIONING then
    return false, nil
  end

  local cancelledId = state.transitionId
  state.status = Constants.TransitionStatus.CANCELLED
  state.transitionId = nil
  state.elapsedTime = 0
  state.kind = nil
  state.toRoute = nil
  state.fromRoute = nil
  state.session = nil
  errorTimeoutOccurred = false

  -- Reset to IDLE after cancel
  state.status = Constants.TransitionStatus.IDLE

  log("D", "TransitionManager", "Transition cancelled: " .. tostring(cancelledId) .. " reason: " .. reason)
  return true, cancelledId
end

-- Reset state (for testing or recovery)
M.reset = function()
  state.status = Constants.TransitionStatus.IDLE
  state.transitionId = nil
  state.elapsedTime = 0
  state.session = nil
  errorTimeoutOccurred = false
  log("D", "TransitionManager", "State reset")
end

-- Get debug info
M.getDebugInfo = function()
  return {
    status = state.status,
    transitionId = state.transitionId,
    elapsedTime = M.getElapsedTime()
  }
end

return M
