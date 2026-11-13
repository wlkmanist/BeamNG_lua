-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local selectionCache = require("editor/ezObjectSelect/selectionCache")
local geometry = require("editor/ezObjectSelect/selectionGeometry")

local objectFlags = bit.bor(SOTStaticShape, SOTStaticObject, SOTVehicle)
local staticObjectFlags = bit.bor(SOTStaticShape, SOTStaticObject)
local broadQueryLogicalPixels = 128
local defaultNearQueryDistance = 40

local function reject(rejected, reason)
  rejected[reason] = (rejected[reason] or 0) + 1
end

local function upcastObject(obj)
  return obj and (Sim.upcast(obj) or obj) or nil
end

local function resolveSelectionObject(source)
  local prefab = getOwningPrefab(source)
  if prefab then return upcastObject(prefab) end

  prefab = getOwningPrefabInstance(source)
  prefab = upcastObject(prefab)
  if prefab and prefab:getClassName() == "PrefabInstance" then return prefab end
  return source
end

local function hasUsableBounds(obj)
  if obj.getObjBox and geometry.validBox(obj:getObjBox()) then return true end
  return obj.getWorldBox and geometry.validBox(obj:getWorldBox()) or false
end

local function candidateSourceReason(obj)
  if not obj or not obj.getID or not obj.getClassName or not obj.getTransform then
    return "unsupported"
  end

  local className = obj:getClassName()
  if className == "TerrainBlock" or className == "WaterPlane" or className == "Forest" then
    return "excludedClass"
  end
  if obj.getName and obj:getName() == "gameCamera" then return "cameraObject" end
  if obj.isHidden and obj:isHidden() then return "hidden" end
  if not editor.getObjectTypeSelectable(className) then return "classDisabled" end
  if obj.isLocked and obj:isLocked() then return "locked" end
  if not editor.isObjectSelectable(obj) then return "selectionDisabled" end
  if not hasUsableBounds(obj) then return "invalidBounds" end
  return nil
end

local function selectionTexts(obj)
  local name = obj.getName and obj:getName() or nil
  local internalName = obj.getInternalName and obj:getInternalName() or nil
  local shapeName = obj.getField and obj:getField("shapeName", 0) or nil
  local modelFile = obj.getModelFile and obj:getModelFile() or nil
  return {
    name and tostring(name) or "",
    internalName and tostring(internalName) or "",
    shapeName and tostring(shapeName) or "",
    modelFile and tostring(modelFile) or ""
  }
end

local function parsePatternList(value)
  local patterns = {}
  local entryIndex = 0
  for rawPattern in string.gmatch((value or "") .. ",", "(.-),") do
    entryIndex = entryIndex + 1
    local pattern = string.match(rawPattern, "^%s*(.-)%s*$")
    if pattern ~= "" then
      local valid, patternError = pcall(string.find, "", pattern)
      if not valid then
        return nil, string.format("entry %d: %s", entryIndex, tostring(patternError))
      end
      patterns[#patterns + 1] = pattern
    end
  end
  return patterns, nil
end

local function matchesPattern(obj, patterns)
  if #patterns == 0 then return true end
  for _, text in ipairs(selectionTexts(obj)) do
    if text ~= "" then
      for _, pattern in ipairs(patterns) do
        if string.find(text, pattern) ~= nil then return true end
      end
    end
  end
  return false
end

local function patternRejectionReason(obj, patterns, ignorePatterns)
  if not matchesPattern(obj, patterns) then return "patternFilter" end
  if #ignorePatterns > 0 and matchesPattern(obj, ignorePatterns) then return "ignorePattern" end
  return nil
end

local function passesPatterns(obj, patterns, ignorePatterns)
  return patternRejectionReason(obj, patterns, ignorePatterns) == nil
end

local function gatherObjects(camera, mousePosition, queryRadius, nearQueryDistance)
  local objects, objectIds, origins = {}, {}, {}
  local stats = {screen = 0, nearCamera = 0, nearOnly = 0}
  local function add(sourceObjects, isNearCamera)
    for _, rawObject in ipairs(sourceObjects or {}) do
      local obj = upcastObject(rawObject)
      if isNearCamera then
        stats.nearCamera = stats.nearCamera + 1
      else
        stats.screen = stats.screen + 1
      end
      local id = obj:getID()
      local origin = origins[id] or {}
      if isNearCamera then origin.nearCamera = true else origin.screen = true end
      origins[id] = origin
      if not objectIds[id] then
        objectIds[id] = true
        objects[#objects + 1] = obj
        if isNearCamera then stats.nearOnly = stats.nearOnly + 1 end
      end
    end
  end

  add(editor.getObjectsByRectangle({
    topLeft = vec3(mousePosition.x - queryRadius, mousePosition.y - queryRadius, 0),
    bottomRight = vec3(mousePosition.x + queryRadius, mousePosition.y + queryRadius, 0)
  }, nil, objectFlags), false)

  local closeBox = Box3F()
  local diameter = nearQueryDistance * 2
  closeBox:setExtents(vec3(diameter, diameter, diameter))
  closeBox:setCenter(camera.pos)
  add(findObjectList(closeBox, objectFlags, 0), true)
  stats.total = #objects
  return objects, stats, origins
end

local function buildRangeCache(camera, maxDistance)
  local rangeBox = Box3F()
  local diameter = maxDistance * 2
  rangeBox:setExtents(vec3(diameter, diameter, diameter))
  rangeBox:setCenter(camera.rangeOrigin or camera.pos)

  local sources = findObjectList(rangeBox, staticObjectFlags, 0) or {}
  local entries, entriesByTargetId = {}, {}
  local targetCount = 0
  for _, rawSource in ipairs(sources) do
    local source = upcastObject(rawSource)
    if not candidateSourceReason(source) then
      local target = resolveSelectionObject(source)
      local targetId = target and target.getID and target:getID() or nil
      if targetId and not candidateSourceReason(target) then
        local entry = entriesByTargetId[targetId]
        if not entry then
          targetCount = targetCount + 1
          local boundsSignature = geometry.getBoundsSignature(target)
          local proxy = geometry.createProjectedProxy(target, camera, boundsSignature)
          if proxy then
            proxy.target = target
            proxy.targetId = targetId
          end
          entry = {
            targetId = targetId,
            sourceIds = {},
            boundsSignature = boundsSignature,
            scratchBoundsSignature = {},
            proxy = proxy
          }
          entriesByTargetId[targetId] = entry
          entries[#entries + 1] = entry
        end
        entry.sourceIds[#entry.sourceIds + 1] = source:getID()
      end
    end
  end
  return {
    entries = entries,
    proxies = {},
    filteredLarge = {},
    sourceCount = #sources,
    targetCount = targetCount
  }
end

local function cachedSourceReason(entry)
  local rejectionReason = "invalidSource"
  local missingSource = false
  for _, sourceId in ipairs(entry.sourceIds or {}) do
    local source = scenetree.findObjectById(sourceId)
    if source then
      local reason = candidateSourceReason(source)
      if not reason then
        local target = resolveSelectionObject(source)
        if target and target.getID and target:getID() == entry.targetId then return nil, false end
        reason = "changedTarget"
      end
      rejectionReason = reason
    else
      missingSource = true
    end
  end
  return rejectionReason, missingSource
end

local function classifyCached(
  cache,
  mousePosition,
  rayOrigin,
  rayDirection,
  discoveryPixels,
  camera,
  maxDistance,
  maxVolume,
  patterns,
  ignorePatterns)
  local proxies, discoveryProxies, filteredLarge = {}, {}, {}
  local rejected = {}
  local missingTarget = false
  local timer = hptimer()
  cache.proxies = {}
  cache.filteredLarge = {}
  for _, entry in ipairs(cache.entries or {}) do
    local target = scenetree.findObjectById(entry.targetId)
    if target then
      local eligibilityReason = candidateSourceReason(target)
      if not eligibilityReason then
        local sourceMissing
        eligibilityReason, sourceMissing = cachedSourceReason(entry)
        missingTarget = missingTarget or sourceMissing
      end
      if eligibilityReason then
        reject(rejected, eligibilityReason)
      else
        local boundsSignature = geometry.getBoundsSignature(target, entry.scratchBoundsSignature)
        if not boundsSignature then
          reject(rejected, "invalidBounds")
        else
          if not geometry.boundsSignaturesEqual(boundsSignature, entry.boundsSignature) then
            entry.boundsSignature, entry.scratchBoundsSignature =
              boundsSignature, entry.boundsSignature
            entry.proxy = geometry.createProjectedProxy(target, camera, boundsSignature)
          end

          local proxy = entry.proxy
          if proxy then
            proxy.target = target
            proxy.targetId = entry.targetId
            local patternReason = patternRejectionReason(target, patterns, ignorePatterns)
            if patternReason then
              reject(rejected, patternReason)
            elseif proxy.cameraDistance > maxDistance then
              reject(rejected, "outsideRange")
            elseif proxy.volume > maxVolume then
              cache.filteredLarge[#cache.filteredLarge + 1] = proxy
              filteredLarge[#filteredLarge + 1] = proxy
            else
              cache.proxies[#cache.proxies + 1] = proxy
              geometry.updateCursorMetrics(proxy, mousePosition)
              if proxy.cursorDistance <= 0.0001 then
                geometry.updateRayEntry(proxy, rayOrigin, rayDirection)
                proxy.relation = "over"
                proxies[#proxies + 1] = proxy
              elseif proxy.cursorDistance <= discoveryPixels then
                proxy.relation = "discovery"
                discoveryProxies[#discoveryProxies + 1] = proxy
              end
            end
          end
        end
      end
    else
      missingTarget = true
    end
  end
  selectionCache.setClassificationTime(timer:stopAndReset())
  if missingTarget then selectionCache.invalidate("deletedTarget") end
  return proxies, discoveryProxies, filteredLarge, rejected
end

local function classifyDynamicVehicles(
  camera,
  mousePosition,
  rayOrigin,
  rayDirection,
  discoveryPixels,
  maxDistance,
  maxVolume,
  patterns,
  ignorePatterns,
  proxies,
  discoveryProxies,
  filteredLarge,
  rejected)
  local rangeBox = Box3F()
  local diameter = maxDistance * 2
  rangeBox:setExtents(vec3(diameter, diameter, diameter))
  rangeBox:setCenter(camera.rangeOrigin or camera.pos)
  local sources = findObjectList(rangeBox, SOTVehicle, 0) or {}
  local processedTargetIds = {}
  for _, proxy in ipairs(proxies) do processedTargetIds[proxy.targetId] = true end
  for _, proxy in ipairs(discoveryProxies) do processedTargetIds[proxy.targetId] = true end
  for _, proxy in ipairs(filteredLarge) do processedTargetIds[proxy.targetId] = true end

  for _, rawSource in ipairs(sources) do
    local source = upcastObject(rawSource)
    local reason = candidateSourceReason(source)
    local target = not reason and resolveSelectionObject(source) or nil
    local targetId = target and target.getID and target:getID() or nil
    if not reason and targetId and not processedTargetIds[targetId] then
      reason = candidateSourceReason(target)
      if not reason then reason = patternRejectionReason(target, patterns, ignorePatterns) end
      if reason then
        reject(rejected, reason)
      else
        processedTargetIds[targetId] = true
        local proxy, proxyReason = geometry.createProxy(
          target,
          camera,
          mousePosition,
          rayOrigin,
          rayDirection)
        if not proxy then
          reject(rejected, proxyReason or "invalidProxy")
        elseif proxy.cameraDistance > maxDistance then
          reject(rejected, "outsideRange")
        else
          proxy.target = target
          proxy.targetId = targetId
          if proxy.volume > maxVolume then
            filteredLarge[#filteredLarge + 1] = proxy
          elseif proxy.cursorDistance <= 0.0001 then
            proxy.relation = "over"
            proxies[#proxies + 1] = proxy
          elseif proxy.cursorDistance <= discoveryPixels then
            proxy.relation = "discovery"
            discoveryProxies[#discoveryProxies + 1] = proxy
          else
            reject(rejected, "outsideDiscovery")
          end
        end
      end
    end
  end
  return #sources
end

local function gatherFilteredLarge(
  camera,
  mousePosition,
  rayOrigin,
  rayDirection,
  maxDistance,
  maxVolume,
  patterns,
  ignorePatterns)
  local filtered, processedTargetIds = {}, {}
  local rangeBox = Box3F()
  local diameter = maxDistance * 2
  rangeBox:setExtents(vec3(diameter, diameter, diameter))
  rangeBox:setCenter(camera.rangeOrigin or camera.pos)

  for _, rawSource in ipairs(findObjectList(rangeBox, objectFlags, 0) or {}) do
    local source = upcastObject(rawSource)
    if not candidateSourceReason(source) then
      local target = resolveSelectionObject(source)
      local targetId = target and target.getID and target:getID() or nil
      if targetId
        and not processedTargetIds[targetId]
        and not candidateSourceReason(target)
        and passesPatterns(target, patterns, ignorePatterns) then
        processedTargetIds[targetId] = true
        local proxy = geometry.createProxy(
          target,
          camera,
          mousePosition,
          rayOrigin,
          rayDirection)
        if proxy and proxy.volume > maxVolume and proxy.cameraDistance <= maxDistance then
          proxy.target = target
          proxy.targetId = targetId
          filtered[#filtered + 1] = proxy
        end
      end
    end
  end
  return filtered
end

function M.gather(options)
  options = options or {}
  local camera = geometry.createCameraContext()
  if not camera then return nil end

  local screenMouse = ui_imgui.GetMousePos()
  local clientMouse = editor.screenToClient(Point2I(screenMouse.x, screenMouse.y))
  local mousePosition = {x = clientMouse.x, y = clientMouse.y}
  local discoveryPixels = math.max(options.discoveryPixels or 48, 0)
  local queryRadius = math.max(
    discoveryPixels + 8,
    broadQueryLogicalPixels * ui_imgui.uiscale[0])
  local nearQueryDistance = options.nearQueryDistance or defaultNearQueryDistance
  local maxDistance = options.maxDistance or math.huge
  local maxVolume = options.maxVolume or math.huge
  local pattern = options.namePattern or ""
  local ignorePattern = options.ignorePattern or ""
  local patterns, patternError = parsePatternList(pattern)
  local ignorePatterns, ignorePatternError = parsePatternList(ignorePattern)
  local patternValid = patterns ~= nil
  local ignorePatternValid = ignorePatterns ~= nil
  local patternsValid = patternValid and ignorePatternValid
  local ray = getCameraMouseRay()
  local rayOrigin = ray and vec3(ray.pos) or nil
  local rayDirection = ray and vec3(ray.dir) or nil
  if rayDirection then
    local rayLength = rayDirection:length()
    rayDirection = rayLength > 0.000001 and rayDirection / rayLength or nil
  end

  local configKey = string.format(
    "%.3f|%.3f|%.3f",
    maxDistance,
    maxVolume,
    discoveryPixels)
  local cache = selectionCache.update(camera, configKey, function()
    return buildRangeCache(camera, maxDistance)
  end)
  local cacheStatus = selectionCache.getStatus()
  if cache then
    local proxies, discoveryProxies, filteredLarge = {}, {}, {}
    local rejected = {}
    local dynamicSourceCount = 0
    if patternsValid then
      proxies, discoveryProxies, filteredLarge, rejected = classifyCached(
        cache,
        mousePosition,
        rayOrigin,
        rayDirection,
        discoveryPixels,
        camera,
        maxDistance,
        maxVolume,
        patterns,
        ignorePatterns)
      dynamicSourceCount = classifyDynamicVehicles(
        camera,
        mousePosition,
        rayOrigin,
        rayDirection,
        discoveryPixels,
        maxDistance,
        maxVolume,
        patterns,
        ignorePatterns,
        proxies,
        discoveryProxies,
        filteredLarge,
        rejected)
    else
      selectionCache.setClassificationTime(0)
      if not patternValid then reject(rejected, "invalidPattern") end
      if not ignorePatternValid then reject(rejected, "invalidIgnorePattern") end
    end
    cacheStatus = selectionCache.getStatus()
    return {
      camera = camera,
      mouse = mousePosition,
      queryRadius = queryRadius,
      discoveryRadius = discoveryPixels,
      nearQueryDistance = nearQueryDistance,
      proxies = proxies,
      discoveryProxies = discoveryProxies,
      filteredLarge = filteredLarge,
      queryStats = {
        mode = "cache",
        broadRadius = queryRadius,
        screen = 0,
        nearCamera = 0,
        nearOnly = 0,
        qualifyingNearOnly = 0,
        total = cache.sourceCount + dynamicSourceCount,
        pattern = pattern,
        patternError = patternError,
        ignorePattern = ignorePattern,
        ignorePatternError = ignorePatternError,
        cache = cacheStatus
      },
      rejected = rejected,
      sourceCount = cache.sourceCount + dynamicSourceCount
    }
  end

  local proxies = {}
  local discoveryProxies = {}
  local rejected = {}
  local processedTargetIds = {}
  local objects, queryStats, origins = gatherObjects(
    camera,
    mousePosition,
    queryRadius,
    nearQueryDistance)
  local targetSeenOnScreen = {}
  for _, source in ipairs(objects) do
    if origins[source:getID()] and origins[source:getID()].screen then
      local target = resolveSelectionObject(source)
      if target and target.getID then targetSeenOnScreen[target:getID()] = true end
    end
  end
  queryStats.mode = "broad"
  queryStats.broadRadius = queryRadius
  queryStats.qualifyingNearOnly = 0
  queryStats.pattern = pattern
  queryStats.patternError = patternError
  queryStats.ignorePattern = ignorePattern
  queryStats.ignorePatternError = ignorePatternError
  queryStats.cache = cacheStatus
  if not patternValid then reject(rejected, "invalidPattern") end
  if not ignorePatternValid then reject(rejected, "invalidIgnorePattern") end
  for _, source in ipairs(patternsValid and objects or {}) do
    local reason = candidateSourceReason(source)
    if reason then
      reject(rejected, reason)
    else
      local target = resolveSelectionObject(source)
      local targetReason = target and target.getID and candidateSourceReason(target) or "invalidTarget"
      local patternReason = not targetReason
        and patternRejectionReason(target, patterns, ignorePatterns) or nil
      if targetReason then
        reject(rejected, targetReason)
      elseif patternReason then
        reject(rejected, patternReason)
      else
        local targetId = target:getID()
        if not processedTargetIds[targetId] then
          processedTargetIds[targetId] = true
          local proxy, proxyReason = geometry.createProxy(
            target,
            camera,
            mousePosition,
            rayOrigin,
            rayDirection)
          if not proxy then
            reject(rejected, proxyReason or "invalidProxy")
          else
            proxy.target = target
            proxy.targetId = targetId
            if proxy.volume > (options.maxVolume or math.huge) then
              reject(rejected, "outsideVolume")
            elseif proxy.cameraDistance > (options.maxDistance or math.huge) then
              reject(rejected, "outsideRange")
            elseif proxy.cursorDistance <= 0.0001 then
              proxy.relation = "over"
              proxies[#proxies + 1] = proxy
              if not targetSeenOnScreen[targetId] then
                queryStats.qualifyingNearOnly = queryStats.qualifyingNearOnly + 1
              end
            elseif proxy.cursorDistance <= discoveryPixels then
              proxy.relation = "discovery"
              discoveryProxies[#discoveryProxies + 1] = proxy
              if not targetSeenOnScreen[targetId] then
                queryStats.qualifyingNearOnly = queryStats.qualifyingNearOnly + 1
              end
            else
              reject(rejected, "outsideDiscovery")
            end
          end
        end
      end
    end
  end

  local filteredLarge = {}
  if options.collectFilteredLarge and patternsValid then
    filteredLarge = gatherFilteredLarge(
      camera,
      mousePosition,
      rayOrigin,
      rayDirection,
      maxDistance,
      maxVolume,
      patterns,
      ignorePatterns)
  end

  return {
    camera = camera,
    mouse = mousePosition,
    queryRadius = queryRadius,
    discoveryRadius = discoveryPixels,
    nearQueryDistance = nearQueryDistance,
    proxies = proxies,
    discoveryProxies = discoveryProxies,
    filteredLarge = filteredLarge,
    queryStats = queryStats,
    rejected = rejected,
    sourceCount = #objects
  }
end

function M.activate()
  selectionCache.activate()
end

function M.invalidateCache(reason)
  selectionCache.invalidate(reason)
end

function M.getCacheStatus()
  return selectionCache.getStatus()
end

function M.validatePatternList(value)
  local patterns, patternError = parsePatternList(value)
  return patterns ~= nil, patternError
end

return M
