-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local selectionQuery = require("editor/ezObjectSelect/selectionQuery")

local state = {
  automaticTargetId = nil,
  activeTargetId = nil,
  cycleActive = false,
  cycleAnchor = nil,
  cycleCamera = nil,
  frozenTargetId = nil,
  frozenPick = nil,
  preferUnselected = false,
  snapshot = nil
}

local depthTieDistance = 0.05
local nearDistanceHysteresis = 2
local overDepthHysteresis = 0.1

local function clearTemporalState()
  state.automaticTargetId = nil
  state.activeTargetId = nil
  state.cycleActive = false
  state.cycleAnchor = nil
  state.cycleCamera = nil
  state.frozenTargetId = nil
  state.frozenPick = nil
  state.preferUnselected = false
  state.snapshot = nil
end

local function quantized(value, step)
  if value == math.huge or value == -math.huge then return value end
  return math.floor(value / step + 0.5)
end

local function compareNumber(first, second)
  if first == second then return nil end
  return first < second
end

local function proxyComesBefore(first, second)
  if not second then return true end
  if first.cameraInside ~= second.cameraInside then return not first.cameraInside end
  if first.relation ~= second.relation then return first.relation == "over" end

  local comparison
  if first.relation == "over" then
    comparison = compareNumber(
      quantized(first.area, 0.01),
      quantized(second.area, 0.01))
    if comparison ~= nil then return comparison end
    comparison = compareNumber(
      quantized(first.rayEntry, depthTieDistance),
      quantized(second.rayEntry, depthTieDistance))
    if comparison ~= nil then return comparison end
  else
    comparison = compareNumber(
      quantized(first.cursorDistance, 0.01),
      quantized(second.cursorDistance, 0.01))
    if comparison ~= nil then return comparison end
    comparison = compareNumber(
      quantized(first.cameraDistance, depthTieDistance),
      quantized(second.cameraDistance, depthTieDistance))
    if comparison ~= nil then return comparison end
  end

  comparison = compareNumber(
    quantized(first.centerBias, 0.0001),
    quantized(second.centerBias, 0.0001))
  if comparison ~= nil then return comparison end
  if first.relation ~= "over" then
    comparison = compareNumber(
      quantized(first.area, 0.01),
      quantized(second.area, 0.01))
    if comparison ~= nil then return comparison end
  end
  return first.sourceId < second.sourceId
end

local function candidateComesBefore(first, second, preferUnselected)
  local firstSelected = editor.isObjectSelected(first.targetId) == true
  local secondSelected = editor.isObjectSelected(second.targetId) == true
  if firstSelected ~= secondSelected then
    if preferUnselected then return not firstSelected end
    return firstSelected
  end
  if first.proxy.cameraInside ~= second.proxy.cameraInside then
    return not first.proxy.cameraInside
  end
  if first.relation ~= second.relation then return first.relation == "over" end
  if proxyComesBefore(first.proxy, second.proxy) then return true end
  if proxyComesBefore(second.proxy, first.proxy) then return false end
  return first.targetId < second.targetId
end

local function groupedCandidates(proxies, preferUnselected)
  local groups = {}

  for _, proxy in ipairs(proxies) do
    local group = groups[proxy.targetId]
    if not group then
      group = {target = proxy.target, targetId = proxy.targetId}
      groups[proxy.targetId] = group
    end

    if proxy.cameraInside then
      if proxyComesBefore(proxy, group.containing) then group.containing = proxy end
    elseif proxy.relation == "over" then
      if proxyComesBefore(proxy, group.over) then group.over = proxy end
    else
      if proxyComesBefore(proxy, group.near) then group.near = proxy end
    end
  end

  local candidates = {}
  for _, group in pairs(groups) do
    local proxy = group.over or group.near or group.containing
    if proxy then
      candidates[#candidates + 1] = {
        target = group.target,
        targetId = group.targetId,
        proxy = proxy,
        relation = proxy.relation
      }
    end
  end
  table.sort(candidates, function(first, second)
    return candidateComesBefore(first, second, preferUnselected)
  end)
  return candidates
end

local function findCandidateIndex(candidates, targetId)
  if not targetId then return nil end
  for index, candidate in ipairs(candidates) do
    if candidate.targetId == targetId then return index end
  end
  return nil
end

local function cameraMoved(camera, reference)
  if not reference then return true end
  if (camera.pos - reference.pos):length() > 0.05 then return true end
  return camera.forward:dot(reference.forward) < 0.99995
end

local function cycleShouldReset(query, deadZone)
  if not state.cycleActive or not state.cycleAnchor then return false end
  local dx = query.mouse.x - state.cycleAnchor.x
  local dy = query.mouse.y - state.cycleAnchor.y
  return dx * dx + dy * dy > deadZone * deadZone
    or cameraMoved(query.camera, state.cycleCamera)
end

local function preserveAutomaticWinner(candidates)
  local top = candidates[1]
  if not top then return nil end
  local previousIndex = findCandidateIndex(candidates, state.automaticTargetId)
  if not previousIndex or previousIndex == 1 then return top.targetId end

  local previous = candidates[previousIndex]
  local topSelected = editor.isObjectSelected(top.targetId) == true
  local previousSelected = editor.isObjectSelected(previous.targetId) == true
  if topSelected ~= previousSelected then return top.targetId end
  if previous.relation ~= top.relation
    or previous.proxy.cameraInside ~= top.proxy.cameraInside then
    return top.targetId
  end
  if top.relation == "over" and top.proxy.area < previous.proxy.area * 0.99 then
    return top.targetId
  end

  if top.relation == "near"
    and previous.proxy.cursorDistance <= top.proxy.cursorDistance + nearDistanceHysteresis then
    return previous.targetId
  end
  if top.relation == "over"
    and previous.proxy.rayEntry <= top.proxy.rayEntry + overDepthHysteresis then
    return previous.targetId
  end
  return top.targetId
end

local function emptySnapshot()
  return {
    candidates = {},
    stackCount = 0,
    activeIndex = 0,
    pick = nil,
    discovery = {},
    filteredLarge = {},
    queryStats = {screen = 0, nearCamera = 0, nearOnly = 0, total = 0},
    rejected = {},
    sourceCount = 0
  }
end

function M.activate()
  clearTemporalState()
  selectionQuery.activate()
end

function M.deactivate()
  clearTemporalState()
end

function M.update(options)
  options = options or {}
  local query = selectionQuery.gather(options)
  if not query then
    state.snapshot = emptySnapshot()
    return state.snapshot
  end

  local preferUnselected = options.preferUnselected == true
  if state.preferUnselected ~= preferUnselected then
    state.preferUnselected = preferUnselected
    state.automaticTargetId = nil
    state.activeTargetId = nil
    state.cycleActive = false
    state.cycleAnchor = nil
    state.cycleCamera = nil
  end
  local candidates = groupedCandidates(query.proxies, preferUnselected)
  local maxStackDistance = options.maxStackDistance or math.huge
  local topViewDistance = candidates[1]
    and (candidates[1].proxy.viewDistance or candidates[1].proxy.cameraDistance)
    or 0
  local stackLimited = #candidates > 1 and topViewDistance > maxStackDistance
  if stackLimited then
    candidates = {candidates[1]}
    state.cycleActive = false
    state.activeTargetId = nil
    state.cycleAnchor = nil
    state.cycleCamera = nil
  end
  table.sort(query.discoveryProxies, function(first, second)
    if first.cursorDistance ~= second.cursorDistance then
      return first.cursorDistance < second.cursorDistance
    end
    if first.cameraDistance ~= second.cameraDistance then
      return first.cameraDistance < second.cameraDistance
    end
    return first.targetId < second.targetId
  end)
  if cycleShouldReset(query, options.cycleDeadZone or 6) then
    state.cycleActive = false
    state.activeTargetId = nil
  end
  if state.cycleActive
    and preferUnselected
    and state.activeTargetId
    and editor.isObjectSelected(state.activeTargetId) then
    state.cycleActive = false
    state.activeTargetId = nil
    state.cycleAnchor = nil
    state.cycleCamera = nil
  end

  local activeIndex
  if state.frozenPick then
    activeIndex = findCandidateIndex(candidates, state.frozenTargetId)
    if not activeIndex then
      candidates = {state.frozenPick}
      activeIndex = 1
    end
  end
  if not activeIndex and state.cycleActive then
    activeIndex = findCandidateIndex(candidates, state.activeTargetId)
    if not activeIndex then
      state.cycleActive = false
      state.activeTargetId = nil
    end
  end
  if not activeIndex then
    state.automaticTargetId = preserveAutomaticWinner(candidates)
    activeIndex = findCandidateIndex(candidates, state.automaticTargetId) or (#candidates > 0 and 1 or 0)
    state.activeTargetId = activeIndex > 0 and candidates[activeIndex].targetId or nil
  end

  state.snapshot = {
    camera = query.camera,
    mouse = query.mouse,
    queryRadius = query.queryRadius,
    discoveryRadius = query.discoveryRadius,
    nearQueryDistance = query.nearQueryDistance,
    candidates = candidates,
    discovery = query.discoveryProxies,
    filteredLarge = query.filteredLarge,
    queryStats = query.queryStats,
    rejected = query.rejected,
    sourceCount = query.sourceCount,
    stackCount = #candidates,
    stackLimited = stackLimited,
    activeIndex = activeIndex,
    pick = activeIndex > 0 and candidates[activeIndex] or nil,
    cycleActive = state.cycleActive,
    cycleAnchor = state.cycleAnchor,
    cycleDeadZone = options.cycleDeadZone or 6,
    frozenTargetId = state.frozenTargetId
  }
  return state.snapshot
end

function M.cycle(wheelDelta)
  local snapshot = state.snapshot
  if not snapshot or snapshot.stackCount < 2 or wheelDelta == 0 then return snapshot end

  local direction = wheelDelta > 0 and -1 or 1
  local currentIndex = snapshot.activeIndex > 0 and snapshot.activeIndex or 1
  local nextIndex = (currentIndex - 1 + direction) % snapshot.stackCount + 1
  snapshot.activeIndex = nextIndex
  snapshot.pick = snapshot.candidates[nextIndex]
  snapshot.cycleActive = true

  state.cycleActive = true
  state.activeTargetId = snapshot.pick.targetId
  state.cycleAnchor = {x = snapshot.mouse.x, y = snapshot.mouse.y}
  state.cycleCamera = {
    pos = vec3(snapshot.camera.pos),
    forward = vec3(snapshot.camera.forward)
  }
  return snapshot
end

function M.freezePick()
  local pick = state.snapshot and state.snapshot.pick or nil
  state.frozenTargetId = pick and pick.targetId or nil
  state.frozenPick = pick
  if state.snapshot then state.snapshot.frozenTargetId = state.frozenTargetId end
  return pick
end

function M.releasePick()
  state.frozenTargetId = nil
  state.frozenPick = nil
  if state.snapshot then state.snapshot.frozenTargetId = nil end
end

function M.getSnapshot()
  return state.snapshot
end

function M.invalidateCache(reason)
  selectionQuery.invalidateCache(reason)
end

return M
