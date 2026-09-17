-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt


local M = {}

local im = ui_imgui
local ffi = require('ffi')

-- extensions.load('core_ropeVisualTest')

-- Rope sandbox UI state
local selectedRope = nil  -- Selected rope object (contains id property)
local openSaveModalPopup = nil
local openLoadModalPopup = nil

-- Animation state
local anchorAAnimation = 0  -- 0 = none, 1 = wiggle, 2 = circle, 3 = bumpy ride, 4 = rectangle, 5 = random walk, 6 = sin wave
local anchorBAnimation = 0
local animationTime = 0
local animationScale = 1.0  -- Global animation scale factor
local animationTimeScale = 1.0  -- Global animation time scale factor
local ropeBasePositions = {}  -- Store base positions for each rope {ropeId = {anchorA = vec3, anchorB = vec3}}
local cloneYOffset = 0  -- Current Y offset for rope cloning (in meters)
local ropeDebugSettings = {}  -- Store debug settings for each rope {ropeId = {debugDraw, debugNodes, debugDir, debugText}}

-- Performance tracking
local perfStats = {
  lastFrameId = 0,
  frameCount = 0,
  fps = 0,
  frameTime = 0,
  ropesPerFrame = {},
  totalSimTime = 0,
  totalRenderTime = 0,
  totalSimTimes = {},    -- History of total sim times
  totalRenderTimes = {}, -- History of total render times
  avgTotalSimTime = 0,   -- Average total sim time
  avgTotalRenderTime = 0, -- Average total render time
  ropeSimTimes = {},  -- {ropeId = {times = {}, avg = 0, max = 0, spikes = 0}}
  ropeRenderTimes = {}, -- {ropeId = {times = {}, avg = 0, max = 0, spikes = 0}}
  historySize = 60,  -- Keep 60 frames of history
  spikeThreshold = 2.0 -- 2x average = spike
}

-- Node interaction state
local hoveredNode = nil  -- {ropeId, nodeIndex} or nil
local draggedNode = nil  -- {ropeId, nodeIndex} or nil
local dragPlaneNormal = vec3(0, 0, 1)  -- Plane normal for dragging
local dragPlaneDist = 0  -- Plane distance for dragging


-- UI buffers
local materialNamePtr = im.ArrayChar(256, "")
local saveFilePathPtr = im.ArrayChar(512, "rope_parameters.json")
local loadFilePathPtr = im.ArrayChar(512, "rope_parameters.json")

-- Cached UI pointers for performance (initialized with defaults)
local uiPtrs = {
  anchorAX = im.FloatPtr(0),
  anchorAY = im.FloatPtr(0),
  anchorAZ = im.FloatPtr(3),
  anchorBX = im.FloatPtr(5),
  anchorBY = im.FloatPtr(0),
  anchorBZ = im.FloatPtr(3),
  dirAX = im.FloatPtr(0),
  dirAY = im.FloatPtr(0),
  dirAZ = im.FloatPtr(-1),
  dirBX = im.FloatPtr(0),
  dirBY = im.FloatPtr(0),
  dirBZ = im.FloatPtr(-1),
  nodeCount = im.IntPtr(32),
  lengthScale = im.FloatPtr(1.0),
  diameter = im.FloatPtr(0.12),
  damping = im.FloatPtr(0.995),
  bendStiffness = im.FloatPtr(0.6),
  useXPBD = im.BoolPtr(true),
  useBending = im.BoolPtr(true),
  bendSegmentLength = im.IntPtr(3),
  useWorldCollision = im.BoolPtr(false),
  useSelfCollision = im.BoolPtr(false),
  useStrainLimit = im.BoolPtr(true),
  maxStrainLimit = im.FloatPtr(1.0),
  youngsModulus = im.FloatPtr(1e7),
  renderRope = im.BoolPtr(true),
  debugDraw = im.BoolPtr(true),
  debugNodes = im.BoolPtr(true),
  debugDir = im.BoolPtr(true),
  debugText = im.BoolPtr(false),
  debugMass = im.BoolPtr(false),
  windScale = im.FloatPtr(1.0),
  windDrag = im.FloatPtr(1.0),
  totalMass = im.FloatPtr(1.0),
  massFalloff = im.FloatPtr(0.0),
  iterations = im.IntPtr(1),
  gravityX = im.FloatPtr(0.0),
  gravityY = im.FloatPtr(0.0),
  gravityZ = im.FloatPtr(-9.81),
  c1 = im.FloatPtr(0.0),
  c2 = im.FloatPtr(0.0),
  c3 = im.FloatPtr(0.0),
  anchorAFixed = im.BoolPtr(true),
  anchorBFixed = im.BoolPtr(true),
  animationScale = im.FloatPtr(1.0),
  animationTimeScale = im.FloatPtr(1.0),
  anchorAAnimation = im.IntPtr(0),
  anchorBAnimation = im.IntPtr(0),
  simFPS = im.IntPtr(60)
}

-- Update cached UI pointers from selected rope
local function updateUIPtrs()
  if selectedRope then
    uiPtrs.anchorAX[0] = selectedRope.anchorA.x
    uiPtrs.anchorAY[0] = selectedRope.anchorA.y
    uiPtrs.anchorAZ[0] = selectedRope.anchorA.z
    uiPtrs.anchorBX[0] = selectedRope.anchorB.x
    uiPtrs.anchorBY[0] = selectedRope.anchorB.y
    uiPtrs.anchorBZ[0] = selectedRope.anchorB.z
    uiPtrs.dirAX[0] = selectedRope.dirA.x
    uiPtrs.dirAY[0] = selectedRope.dirA.y
    uiPtrs.dirAZ[0] = selectedRope.dirA.z
    uiPtrs.dirBX[0] = selectedRope.dirB.x
    uiPtrs.dirBY[0] = selectedRope.dirB.y
    uiPtrs.dirBZ[0] = selectedRope.dirB.z
    uiPtrs.nodeCount[0] = selectedRope.nodeCount
    uiPtrs.lengthScale[0] = selectedRope.lengthScale
    uiPtrs.diameter[0] = selectedRope.diameter
    uiPtrs.damping[0] = selectedRope.damping
    uiPtrs.bendStiffness[0] = selectedRope.bendStiffness
    uiPtrs.useXPBD[0] = selectedRope.useXPBD
    uiPtrs.useBending[0] = selectedRope.useBending
    uiPtrs.bendSegmentLength[0] = selectedRope.bendSegmentLength or 2
    uiPtrs.useWorldCollision[0] = selectedRope.useWorldCollision or false
    uiPtrs.useSelfCollision[0] = selectedRope.useSelfCollision or false
    uiPtrs.useStrainLimit[0] = selectedRope.useStrainLimit
    uiPtrs.maxStrainLimit[0] = selectedRope.maxStrainLimit
    uiPtrs.totalMass[0] = selectedRope.totalMass or 1.0
    uiPtrs.massFalloff[0] = selectedRope.massFalloff or 0.0
    uiPtrs.iterations[0] = selectedRope.iterations or 8
    if selectedRope.gravity then
      uiPtrs.gravityX[0] = selectedRope.gravity.x
      uiPtrs.gravityY[0] = selectedRope.gravity.y
      uiPtrs.gravityZ[0] = selectedRope.gravity.z
    end
    uiPtrs.renderRope[0] = selectedRope.renderRope
    uiPtrs.youngsModulus[0] = selectedRope.youngsModulus
    -- Load debug settings from local storage
    local debugSettings = ropeDebugSettings[selectedRope.id]
    if debugSettings then
      uiPtrs.debugDraw[0] = debugSettings.debugDraw
      uiPtrs.debugNodes[0] = debugSettings.debugNodes
      uiPtrs.debugDir[0] = debugSettings.debugDir
      uiPtrs.debugText[0] = debugSettings.debugText
      uiPtrs.debugMass[0] = debugSettings.debugMass
    end
    uiPtrs.windScale[0] = selectedRope.windScale
    uiPtrs.windDrag[0] = selectedRope.windDrag
    uiPtrs.anchorAFixed[0] = selectedRope.anchorAFixed
    uiPtrs.anchorBFixed[0] = selectedRope.anchorBFixed
    -- uiPtrs.c1[0] = selectedRope.c1  -- TODO: Figure out correct type
    -- uiPtrs.c2[0] = selectedRope.c2  -- TODO: Figure out correct type
    -- uiPtrs.c3[0] = selectedRope.c3  -- TODO: Figure out correct type
    materialNamePtr = im.ArrayChar(256, selectedRope.materialName)
    uiPtrs.animationScale[0] = animationScale
    uiPtrs.animationTimeScale[0] = animationTimeScale
    uiPtrs.anchorAAnimation[0] = anchorAAnimation
    uiPtrs.anchorBAnimation[0] = anchorBAnimation
    uiPtrs.simFPS[0] = selectedRope.simFPS
  end
end


-- Node interaction functions
local function rayIntersectsSphere(rayOrigin, rayDir, sphereCenter, sphereRadius)
  local oc = rayOrigin - sphereCenter
  local a = rayDir:dot(rayDir)
  local b = 2.0 * oc:dot(rayDir)
  local c = oc:dot(oc) - sphereRadius * sphereRadius
  local discriminant = b * b - 4 * a * c
  return discriminant >= 0
end

-- Rope node drawing colors (matching C++ implementation)
local ropeColors = {
  nodeFixed = ColorF(0.8, 0.2, 0.2, 1.0),    -- Red for fixed anchors
  nodeFree = ColorF(0.2, 0.8, 0.2, 1.0),     -- Green for free anchors
  nodeCalc = ColorF(0.5, 0.5, 0.8, 1.0),     -- Blue for calculated nodes
  nodeHighlight = ColorF(1.0, 1.0, 0.0, 1.0), -- Yellow for highlighted
  nodeDragged = ColorF(1.0, 0.5, 0.0, 1.0),  -- Orange for dragged
  nodeMass = ColorF(1.0, 0.5, 0.0, 1.0),    -- Orange tint for mass weighting overlay
  strainLow = ColorF(0.2, 1.0, 0.2, 1.0),    -- Green for low strain
  strainHigh = ColorF(1.0, 0.2, 0.2, 1.0)    -- Red for high strain
}

-- Draw rope nodes and debug visualization in Lua
local function drawRopeNodes(rope)
  if not rope then return end

  -- Get nodes (pos + mass) from the rope
  local nodes = rope:getNodes()
  if not nodes or #nodes == 0 then return end

  -- Get debug settings for this rope
  local debugSettings = ropeDebugSettings[rope.id]
  if not debugSettings then return end

  -- Draw rope segments colored by strain
  if debugSettings.debugDraw then
    for i = 1, #nodes - 1 do
      local a = nodes[i].pos
      local b = nodes[i + 1].pos
      local segmentLength = (b - a):length()
      local restLength = rope.restLength / (rope.nodeCount - 1) -- Approximate per-segment rest length

      local strain = (restLength > 0) and ((segmentLength / restLength) - 1.0) or 0.0
      strain = math.max(0.0, math.min(strain, 0.2)) * 5.0 -- Clamp and scale

      -- Interpolate color from green (low strain) to red (high strain)
      local r = ropeColors.strainLow.r + (ropeColors.strainHigh.r - ropeColors.strainLow.r) * strain
      local g = ropeColors.strainLow.g + (ropeColors.strainHigh.g - ropeColors.strainLow.g) * strain
      local b_color = ropeColors.strainLow.b + (ropeColors.strainHigh.b - ropeColors.strainLow.b) * strain
      local col = ColorF(r, g, b_color, 1.0)

      debugDrawer:drawLineInstance(a, b, 6, col)
    end
  end

  -- Draw nodes as spheres
  if debugSettings.debugNodes then
    -- Determine mass range for scaling (exclude anchors if desired)
    local minMass, maxMass = math.huge, 0
    for _, node in ipairs(nodes) do
      if node.mass then
        if node.mass < minMass then minMass = node.mass end
        if node.mass > maxMass then maxMass = node.mass end
      end
    end
    if minMass == math.huge then
      minMass, maxMass = 0, 0
    end

    local baseRadius = math.max(0.002, rope.diameter * (rope.renderRope and 0.6 or 0.2))
    local minRadius = baseRadius * 0.5
    local maxRadius = baseRadius * 1.5

    -- Draw all nodes (anchors are first/last positions in nodes)
    for i = 1, #nodes do
      local nodeCol

      -- Determine base color based on position
      if i == 1 then
        -- Anchor A
        nodeCol = rope.anchorAFixed and ropeColors.nodeFixed or ropeColors.nodeFree
      elseif i == #nodes then
        -- Anchor B
        nodeCol = rope.anchorBFixed and ropeColors.nodeFixed or ropeColors.nodeFree
      else
        -- Intermediate node
        nodeCol = ropeColors.nodeCalc
      end

      -- Override with interaction colors
      if draggedNode and draggedNode.ropeId == rope.id and draggedNode.nodeIndex == i then
        nodeCol = ropeColors.nodeDragged
      elseif hoveredNode and hoveredNode.ropeId == rope.id and hoveredNode.nodeIndex == i then
        nodeCol = ropeColors.nodeHighlight
      end

      local radius = baseRadius
      if nodes[i].mass and maxMass > minMass then
        local t = (nodes[i].mass - minMass) / (maxMass - minMass)
        radius = minRadius + (maxRadius - minRadius) * t
      end

      debugDrawer:drawSphere(nodes[i].pos, radius, nodeCol, true)

      if debugSettings.debugMass and nodes[i].mass then
        local massText = string.format("%.3f kg", nodes[i].mass)
        debugDrawer:drawText(nodes[i].pos, massText, ColorF(1.0, 0.7, 0.3, 1.0))
      end
    end
  end

  -- Draw direction arrows for anchors
  if debugSettings.debugDir then
    if rope.dirA:length() > 0.001 then
      debugDrawer:drawArrow(rope.anchorA, rope.anchorA + rope.dirA, ColorI(255, 0, 255, 255), true)
    end
    if rope.dirB:length() > 0.001 then
      debugDrawer:drawArrow(rope.anchorB, rope.anchorB + rope.dirB, ColorI(0, 255, 255, 255), true)
    end
  end

  -- (Debug forces removed)

  -- Draw debug text
  if debugSettings.debugText then
    local text = string.format("Rope %d | %d nodes | len: %.2fm | rest: %.2fm | strain max: %.1f%%, avg %.1f%% | sim: %.3fms @ %dHz",
      rope.id, rope.nodeCount, rope.currentLength, rope.restLength,
      rope.maxStrain * 100.0, rope.avgStrain * 100.0, rope.simTime, rope.simFPS)

    debugDrawer:drawTextAdvanced(rope.anchorA, text, ColorF(0, 0, 0, 1), true, false, ColorI(255,255,255,192), false, false)

    -- Anchor status text
    local anchorAText = rope.anchorAFixed and "Anchor A: FIXED" or "Anchor A: FREE"
    local anchorBText = rope.anchorBFixed and "Anchor B: FIXED" or "Anchor B: FREE"

    debugDrawer:drawTextAdvanced(rope.anchorA, anchorAText, ColorF(0, 0, 0, 1), true, false, ColorI(255,255,255,192), false, false)
    debugDrawer:drawTextAdvanced(rope.anchorB, anchorBText, ColorF(0, 0, 0, 1), true, false, ColorI(255,255,255,192), false, false)
  end
end

local function findHoveredNode()
  -- Check if node interaction is globally enabled or if any rope has debug nodes enabled
  if not uiPtrs or not uiPtrs.debugNodes[0] then
    local anyRopeHasDebugNodes = false
    for _, settings in pairs(ropeDebugSettings) do
      if settings.debugNodes then
        anyRopeHasDebugNodes = true
        break
      end
    end
    if not anyRopeHasDebugNodes then return nil end
  end

  local ray = getCameraMouseRay()
  if not ray then return nil end

  local rayOrigin = vec3(ray.pos.x, ray.pos.y, ray.pos.z)
  local rayDir = vec3(ray.dir.x, ray.dir.y, ray.dir.z)

  -- Check all ropes and their nodes (anchors are first/last positions)
  local allRopes = getAllRopeVisuals()
  for _, entry in ipairs(allRopes) do
    local rope = getRopeVisual(entry.id)
    if rope then
      local nodes = rope:getNodes()
      for i, node in ipairs(nodes) do
        if rayIntersectsSphere(rayOrigin, rayDir, node.pos, 0.1) then
          return {ropeId = entry.id, nodeIndex = i}
        end
      end
    end
  end
  return nil
end

local function handleNodeDragging()
  if not draggedNode then return end

  local ray = getCameraMouseRay()
  if not ray then return end

  local rayOrigin = vec3(ray.pos.x, ray.pos.y, ray.pos.z)
  local rayDir = vec3(ray.dir.x, ray.dir.y, ray.dir.z)

  -- Intersect ray with drag plane
  local denom = dragPlaneNormal:dot(rayDir)
  if math.abs(denom) > 0.0001 then
    local t = -(dragPlaneNormal:dot(rayOrigin) - dragPlaneDist) / denom
    if t > 0 then
      local intersectionPoint = rayOrigin + rayDir * t

      -- Update the position
      local rope = getRopeVisual(draggedNode.ropeId)
      if rope then
        local nodes = rope:getNodes()
        local numNodes = #nodes

        if draggedNode.nodeIndex == 1 then
          -- Dragging anchor A (first position)
          rope.anchorA = intersectionPoint
          -- Update base position for animations
          if ropeBasePositions[draggedNode.ropeId] then
            ropeBasePositions[draggedNode.ropeId].anchorA = intersectionPoint
          end
        elseif draggedNode.nodeIndex == numNodes then
          -- Dragging anchor B (last position)
          rope.anchorB = intersectionPoint
          -- Update base position for animations
          if ropeBasePositions[draggedNode.ropeId] then
            ropeBasePositions[draggedNode.ropeId].anchorB = intersectionPoint
          end
        else
          -- Update intermediate node position using the new API
          rope:setNodePosition(draggedNode.nodeIndex, intersectionPoint)
        end

        -- Update UI if this rope is selected
        if selectedRope and selectedRope.id == draggedNode.ropeId then
          updateUIPtrs()
        end
      end
    end
  end
end

-- Animation functions (return vec3 offset within [-0.5, 0.5] bounds)
local function getAnimationOffset(animationType, time)
  if animationType == 0 then -- none
    return vec3(0, 0, 0)
  elseif animationType == 1 then -- wiggle
    return vec3(math.sin(time * 8) * 0.3, math.sin(time * 6) * 0.2, math.sin(time * 4) * 0.1)
  elseif animationType == 2 then -- circle
    local radius = 0.4
    return vec3(math.cos(time * 2) * radius, math.sin(time * 2) * radius, 0)
  elseif animationType == 3 then -- bumpy ride
    return vec3(math.sin(time * 3) * 0.3, math.sin(time * 5) * 0.2, math.abs(math.sin(time * 4)) * 0.3)
  elseif animationType == 4 then -- rectangle
    local speed = 2
    local size = 0.4
    local t = time * speed
    local phase = math.floor(t / 4) % 4
    if phase == 0 then
      return vec3(math.fmod(t, 1) * size * 2 - size, -size, 0)
    elseif phase == 1 then
      return vec3(size, math.fmod(t, 1) * size * 2 - size, 0)
    elseif phase == 2 then
      return vec3(size - math.fmod(t, 1) * size * 2, size, 0)
    else
      return vec3(-size, size - math.fmod(t, 1) * size * 2, 0)
    end
  elseif animationType == 5 then -- random walk
    -- Simple pseudo-random walk using time-based seed
    local seed1 = math.floor(time * 10) % 100
    local seed2 = math.floor(time * 8) % 100
    local seed3 = math.floor(time * 6) % 100
    return vec3((seed1 / 100 - 0.5) * 0.8, (seed2 / 100 - 0.5) * 0.8, (seed3 / 100 - 0.5) * 0.8)
  elseif animationType == 6 then -- sin wave
    return vec3(math.sin(time) * 0.4, math.sin(time * 1.5) * 0.3, math.sin(time * 0.5) * 0.2)
  end
  return vec3(0, 0, 0)
end

-- Direction animation: smoothly varies direction on a unit sphere
local function getAnimatedDirection(time)
  -- Elevation oscillates, azimuth spins
  local azimuth = time * 0.8
  local elevation = math.sin(time * 0.7) * 0.7 -- ~±40 degrees
  local cosEl = math.cos(elevation)
  return vec3(math.cos(azimuth) * cosEl, math.sin(azimuth) * cosEl, math.sin(elevation))
end

local function saveParametersToFile(filePath)
  -- Save UI state and settings only
  local uiState = {
    -- Anchor positions
    anchorAX = uiPtrs.anchorAX[0],
    anchorAY = uiPtrs.anchorAY[0],
    anchorAZ = uiPtrs.anchorAZ[0],
    anchorBX = uiPtrs.anchorBX[0],
    anchorBY = uiPtrs.anchorBY[0],
    anchorBZ = uiPtrs.anchorBZ[0],

    -- Direction vectors
    dirAX = uiPtrs.dirAX[0],
    dirAY = uiPtrs.dirAY[0],
    dirAZ = uiPtrs.dirAZ[0],
    dirBX = uiPtrs.dirBX[0],
    dirBY = uiPtrs.dirBY[0],
    dirBZ = uiPtrs.dirBZ[0],

    -- Core rope properties
    nodeCount = uiPtrs.nodeCount[0],
    lengthScale = uiPtrs.lengthScale[0],
    diameter = uiPtrs.diameter[0],
    damping = uiPtrs.damping[0],
    bendStiffness = uiPtrs.bendStiffness[0],

    -- Simulation toggles
    useXPBD = uiPtrs.useXPBD[0],
    useBending = uiPtrs.useBending[0],
    bendSegmentLength = uiPtrs.bendSegmentLength[0],
    useWorldCollision = uiPtrs.useWorldCollision[0],
    useSelfCollision = uiPtrs.useSelfCollision[0],
    useStrainLimit = uiPtrs.useStrainLimit[0],
    maxStrainLimit = uiPtrs.maxStrainLimit[0],

    -- Physics properties
    totalMass = uiPtrs.totalMass[0],
    massFalloff = uiPtrs.massFalloff[0],
    iterations = uiPtrs.iterations[0],
    gravityX = uiPtrs.gravityX[0],
    gravityY = uiPtrs.gravityY[0],
    gravityZ = uiPtrs.gravityZ[0],
    youngsModulus = uiPtrs.youngsModulus[0],

    -- Rendering
    renderRope = uiPtrs.renderRope[0],
    windScale = uiPtrs.windScale[0],
    windDrag = uiPtrs.windDrag[0],
    materialName = materialNamePtr[0] ~= "" and ffi.string(materialNamePtr) or "",

    -- Anchor constraints (the "anchor pinned thing")
    anchorAFixed = uiPtrs.anchorAFixed[0],
    anchorBFixed = uiPtrs.anchorBFixed[0],

    -- Simulation
    simFPS = uiPtrs.simFPS[0],

    -- Animation
    animationScale = animationScale,
    animationTimeScale = animationTimeScale,
    anchorAAnimation = anchorAAnimation,
    anchorBAnimation = anchorBAnimation,

    -- Debug settings (global defaults, per-rope settings are not saved)
    debugDraw = uiPtrs.debugDraw[0],
    debugNodes = uiPtrs.debugNodes[0],
    debugDir = uiPtrs.debugDir[0],
    debugText = uiPtrs.debugText[0],
    debugMass = uiPtrs.debugMass[0],

    -- Unused fields (included for completeness)
    c1 = uiPtrs.c1[0],
    c2 = uiPtrs.c2[0],
    c3 = uiPtrs.c3[0]
  }

  local data = {
    uiState = uiState,
    version = "1.0",
    timestamp = os.time()
  }

  local success = jsonWriteFile(filePath, data, true)
  if success then
    log('I', 'ropeSandbox', 'Successfully saved rope parameters to: ' .. filePath)
  else
    log('E', 'ropeSandbox', 'Failed to save rope parameters to: ' .. filePath)
  end
  return success
end

local function loadParametersFromFile(filePath)
  local data = jsonReadFile(filePath)
  if not data or not data.uiState then
    log('W', 'ropeSandbox', 'No valid rope parameters found in: ' .. filePath)
    return false
  end

  log('I', 'ropeSandbox', 'Loading rope parameters from: ' .. filePath)

  local ui = data.uiState

  -- Restore all UI state
  uiPtrs.anchorAX[0] = ui.anchorAX or 0
  uiPtrs.anchorAY[0] = ui.anchorAY or 0
  uiPtrs.anchorAZ[0] = ui.anchorAZ or 3
  uiPtrs.anchorBX[0] = ui.anchorBX or 5
  uiPtrs.anchorBY[0] = ui.anchorBY or 0
  uiPtrs.anchorBZ[0] = ui.anchorBZ or 3

  uiPtrs.dirAX[0] = ui.dirAX or 0
  uiPtrs.dirAY[0] = ui.dirAY or 0
  uiPtrs.dirAZ[0] = ui.dirAZ or -1
  uiPtrs.dirBX[0] = ui.dirBX or 0
  uiPtrs.dirBY[0] = ui.dirBY or 0
  uiPtrs.dirBZ[0] = ui.dirBZ or -1

  uiPtrs.nodeCount[0] = ui.nodeCount or 32
  uiPtrs.lengthScale[0] = ui.lengthScale or 1.0
  uiPtrs.diameter[0] = ui.diameter or 0.12
  uiPtrs.damping[0] = ui.damping or 0.995
  uiPtrs.bendStiffness[0] = ui.bendStiffness or 0.6

  uiPtrs.useXPBD[0] = ui.useXPBD
  uiPtrs.useBending[0] = ui.useBending
  uiPtrs.bendSegmentLength[0] = ui.bendSegmentLength or 3
  uiPtrs.useWorldCollision[0] = ui.useWorldCollision
  uiPtrs.useSelfCollision[0] = ui.useSelfCollision
  uiPtrs.useStrainLimit[0] = ui.useStrainLimit
  uiPtrs.maxStrainLimit[0] = ui.maxStrainLimit or 1.0

  uiPtrs.totalMass[0] = ui.totalMass or 1.0
  uiPtrs.massFalloff[0] = ui.massFalloff or 0.0
  uiPtrs.iterations[0] = ui.iterations or 1
  uiPtrs.gravityX[0] = ui.gravityX or 0.0
  uiPtrs.gravityY[0] = ui.gravityY or 0.0
  uiPtrs.gravityZ[0] = ui.gravityZ or -9.81
  uiPtrs.youngsModulus[0] = ui.youngsModulus or 1e7

  uiPtrs.renderRope[0] = ui.renderRope
  uiPtrs.windScale[0] = ui.windScale or 1.0
  uiPtrs.windDrag[0] = ui.windDrag or 1.0

  if ui.materialName and ui.materialName ~= "" then
    materialNamePtr = im.ArrayChar(256, ui.materialName)
  end

  uiPtrs.anchorAFixed[0] = ui.anchorAFixed
  uiPtrs.anchorBFixed[0] = ui.anchorBFixed

  uiPtrs.simFPS[0] = ui.simFPS or 60

  animationScale = ui.animationScale or 1.0
  animationTimeScale = ui.animationTimeScale or 1.0
  anchorAAnimation = ui.anchorAAnimation or 0
  anchorBAnimation = ui.anchorBAnimation or 0

  uiPtrs.debugDraw[0] = ui.debugDraw
  uiPtrs.debugNodes[0] = ui.debugNodes
  uiPtrs.debugDir[0] = ui.debugDir
  uiPtrs.debugText[0] = ui.debugText
  uiPtrs.debugMass[0] = ui.debugMass

  uiPtrs.c1[0] = ui.c1 or 0.0
  uiPtrs.c2[0] = ui.c2 or 0.0
  uiPtrs.c3[0] = ui.c3 or 0.0

  log('I', 'ropeSandbox', 'Successfully loaded rope parameters from: ' .. filePath)
  return true
end

local function onSerialize()
  -- Save ALL UI state and settings
  local uiState = {
    -- Anchor positions
    anchorAX = uiPtrs.anchorAX[0],
    anchorAY = uiPtrs.anchorAY[0],
    anchorAZ = uiPtrs.anchorAZ[0],
    anchorBX = uiPtrs.anchorBX[0],
    anchorBY = uiPtrs.anchorBY[0],
    anchorBZ = uiPtrs.anchorBZ[0],

    -- Direction vectors
    dirAX = uiPtrs.dirAX[0],
    dirAY = uiPtrs.dirAY[0],
    dirAZ = uiPtrs.dirAZ[0],
    dirBX = uiPtrs.dirBX[0],
    dirBY = uiPtrs.dirBY[0],
    dirBZ = uiPtrs.dirBZ[0],

    -- Core rope properties
    nodeCount = uiPtrs.nodeCount[0],
    lengthScale = uiPtrs.lengthScale[0],
    diameter = uiPtrs.diameter[0],
    damping = uiPtrs.damping[0],
    bendStiffness = uiPtrs.bendStiffness[0],

    -- Simulation toggles
    useXPBD = uiPtrs.useXPBD[0],
    useBending = uiPtrs.useBending[0],
    bendSegmentLength = uiPtrs.bendSegmentLength[0],
    useWorldCollision = uiPtrs.useWorldCollision[0],
    useSelfCollision = uiPtrs.useSelfCollision[0],
    useStrainLimit = uiPtrs.useStrainLimit[0],
    maxStrainLimit = uiPtrs.maxStrainLimit[0],

    -- Physics properties
    totalMass = uiPtrs.totalMass[0],
    massFalloff = uiPtrs.massFalloff[0],
    iterations = uiPtrs.iterations[0],
    gravityX = uiPtrs.gravityX[0],
    gravityY = uiPtrs.gravityY[0],
    gravityZ = uiPtrs.gravityZ[0],
    youngsModulus = uiPtrs.youngsModulus[0],

    -- Rendering
    renderRope = uiPtrs.renderRope[0],
    windScale = uiPtrs.windScale[0],
    windDrag = uiPtrs.windDrag[0],
    materialName = materialNamePtr[0] ~= "" and ffi.string(materialNamePtr) or "",

    -- Anchor constraints (the "anchor pinned thing")
    anchorAFixed = uiPtrs.anchorAFixed[0],
    anchorBFixed = uiPtrs.anchorBFixed[0],

    -- Simulation
    simFPS = uiPtrs.simFPS[0],

    -- Animation
    animationScale = animationScale,
    animationTimeScale = animationTimeScale,
    anchorAAnimation = anchorAAnimation,
    anchorBAnimation = anchorBAnimation,

    -- Debug settings (global defaults, per-rope settings are not saved)
    debugDraw = uiPtrs.debugDraw[0],
    debugNodes = uiPtrs.debugNodes[0],
    debugDir = uiPtrs.debugDir[0],
    debugText = uiPtrs.debugText[0],
    debugMass = uiPtrs.debugMass[0],

    -- Unused fields (included for completeness)
    c1 = uiPtrs.c1[0],
    c2 = uiPtrs.c2[0],
    c3 = uiPtrs.c3[0]
  }

  local data = {
    uiState = uiState
  }
  return data
end


local function onExtensionUnloaded()
  --clearAllRopeVisuals()
  ropeBasePositions = {}
  ropeDebugSettings = {}
  cloneYOffset = 0
  -- Reset performance stats
  perfStats = {
    lastFrameId = 0,
    frameCount = 0,
    fps = 0,
    frameTime = 0,
    ropesPerFrame = {},
    totalSimTime = 0,
    totalRenderTime = 0,
    totalSimTimes = {},
    totalRenderTimes = {},
    avgTotalSimTime = 0,
    avgTotalRenderTime = 0,
    ropeSimTimes = {},
    ropeRenderTimes = {},
    historySize = 60,
    spikeThreshold = 2.0
  }
end

-- Rope sandbox UI functions
local function cloneRope(sourceRope, yOffset)
  if not sourceRope then return nil end

  local id = createRopeVisual()
  if id then
    local rope = getRopeVisual(id)
    if rope then
      -- Use current UI parameters for cloning, with position offset
      rope.anchorA = vec3(uiPtrs.anchorAX[0], uiPtrs.anchorAY[0] + yOffset, uiPtrs.anchorAZ[0])
      rope.anchorB = vec3(uiPtrs.anchorBX[0], uiPtrs.anchorBY[0] + yOffset, uiPtrs.anchorBZ[0])
      rope.dirA = vec3(uiPtrs.dirAX[0], uiPtrs.dirAY[0], uiPtrs.dirAZ[0])
      rope.dirB = vec3(uiPtrs.dirBX[0], uiPtrs.dirBY[0], uiPtrs.dirBZ[0])
      rope.nodeCount = uiPtrs.nodeCount[0]
      rope.lengthScale = uiPtrs.lengthScale[0]
      rope.diameter = uiPtrs.diameter[0]
      rope.damping = uiPtrs.damping[0]
      rope.bendStiffness = uiPtrs.bendStiffness[0]
      rope.useXPBD = uiPtrs.useXPBD[0]
      rope.useBending = uiPtrs.useBending[0]
      rope.bendSegmentLength = uiPtrs.bendSegmentLength[0]
      rope.useWorldCollision = uiPtrs.useWorldCollision[0]
      rope.useSelfCollision = uiPtrs.useSelfCollision[0]
      rope.useStrainLimit = uiPtrs.useStrainLimit[0]
      rope.maxStrainLimit = uiPtrs.maxStrainLimit[0]
      rope.totalMass = uiPtrs.totalMass[0]
      rope.massFalloff = uiPtrs.massFalloff[0]
      rope.iterations = uiPtrs.iterations[0]
      rope.gravity = vec3(uiPtrs.gravityX[0], uiPtrs.gravityY[0], uiPtrs.gravityZ[0])
      rope.youngsModulus = uiPtrs.youngsModulus[0]
      rope.renderRope = uiPtrs.renderRope[0]
      rope.windScale = uiPtrs.windScale[0]
      rope.windDrag = uiPtrs.windDrag[0]
      rope.materialName = materialNamePtr[0] ~= "" and ffi.string(materialNamePtr) or ""
      rope.anchorAFixed = uiPtrs.anchorAFixed[0]
      rope.anchorBFixed = uiPtrs.anchorBFixed[0]
      rope.simFPS = uiPtrs.simFPS[0]
      rope:rebuild()

      -- Cache this rope and store base positions
      ropeBasePositions[id] = {
        anchorA = vec3(uiPtrs.anchorAX[0], uiPtrs.anchorAY[0] + yOffset, uiPtrs.anchorAZ[0]),
        anchorB = vec3(uiPtrs.anchorBX[0], uiPtrs.anchorBY[0] + yOffset, uiPtrs.anchorBZ[0]),
        dirA = vec3(uiPtrs.dirAX[0], uiPtrs.dirAY[0], uiPtrs.dirAZ[0]),
        dirB = vec3(uiPtrs.dirBX[0], uiPtrs.dirBY[0], uiPtrs.dirBZ[0])
      }

      -- Copy debug settings from source rope
      local sourceDebugSettings = ropeDebugSettings[sourceRope.id] or {
        debugDraw = false,
        debugNodes = false,
        debugDir = false,
        debugText = false,
        debugMass = false
      }
      ropeDebugSettings[id] = {
        debugDraw = sourceDebugSettings.debugDraw,
        debugNodes = sourceDebugSettings.debugNodes,
        debugDir = sourceDebugSettings.debugDir,
        debugText = sourceDebugSettings.debugText,
        debugMass = sourceDebugSettings.debugMass
      }
    end
  end
  return id
end

local function createRopeFromUI()
  local id = createRopeVisual()
  if id then
    local rope = getRopeVisual(id)
    if rope then
      -- Use current UI values (don't reset to defaults!)
      -- Keep the existing anchor and direction values for positioning

      rope.anchorA = vec3(uiPtrs.anchorAX[0], uiPtrs.anchorAY[0], uiPtrs.anchorAZ[0])
      rope.anchorB = vec3(uiPtrs.anchorBX[0], uiPtrs.anchorBY[0], uiPtrs.anchorBZ[0])
      rope.dirA = vec3(uiPtrs.dirAX[0], uiPtrs.dirAY[0], uiPtrs.dirAZ[0])
      rope.dirB = vec3(uiPtrs.dirBX[0], uiPtrs.dirBY[0], uiPtrs.dirBZ[0])
      rope.nodeCount = uiPtrs.nodeCount[0]
      rope.lengthScale = uiPtrs.lengthScale[0]
      rope.diameter = uiPtrs.diameter[0]
      rope.damping = uiPtrs.damping[0]
      rope.bendStiffness = uiPtrs.bendStiffness[0]
      rope.useXPBD = uiPtrs.useXPBD[0]
      rope.useBending = uiPtrs.useBending[0]
      rope.bendSegmentLength = uiPtrs.bendSegmentLength[0]
      rope.useWorldCollision = uiPtrs.useWorldCollision[0]
      rope.useSelfCollision = uiPtrs.useSelfCollision[0]
      rope.useStrainLimit = uiPtrs.useStrainLimit[0]
      rope.maxStrainLimit = uiPtrs.maxStrainLimit[0]
      rope.totalMass = uiPtrs.totalMass[0]
      rope.massFalloff = uiPtrs.massFalloff[0]
      rope.iterations = uiPtrs.iterations[0]
      -- rope gravity is set to level's gravity on creation...
      --rope.gravity = vec3(uiPtrs.gravityX[0], uiPtrs.gravityY[0], uiPtrs.gravityZ[0])
      rope.youngsModulus = uiPtrs.youngsModulus[0]
      rope.renderRope = uiPtrs.renderRope[0]
      rope.windScale = uiPtrs.windScale[0]
      rope.windDrag = uiPtrs.windDrag[0]
      rope.materialName = ""
      rope.anchorAFixed = uiPtrs.anchorAFixed[0]
      rope.anchorBFixed = uiPtrs.anchorBFixed[0]
      -- rope.c1 = uiPtrs.c1[0]  -- TODO: Figure out correct type
      -- rope.c2 = uiPtrs.c2[0]  -- TODO: Figure out correct type
      -- rope.c3 = uiPtrs.c3[0]  -- TODO: Figure out correct type
      rope:rebuild()

      -- Cache this rope and store base positions
      selectedRope = rope
      ropeBasePositions[id] = {
        anchorA = vec3(uiPtrs.anchorAX[0], uiPtrs.anchorAY[0], uiPtrs.anchorAZ[0]),
        anchorB = vec3(uiPtrs.anchorBX[0], uiPtrs.anchorBY[0], uiPtrs.anchorBZ[0]),
        dirA = vec3(uiPtrs.dirAX[0], uiPtrs.dirAY[0], uiPtrs.dirAZ[0]),
        dirB = vec3(uiPtrs.dirBX[0], uiPtrs.dirBY[0], uiPtrs.dirBZ[0])
      }
      if rope.gravity then
        uiPtrs.gravityX[0] = rope.gravity.x
        uiPtrs.gravityY[0] = rope.gravity.y
        uiPtrs.gravityZ[0] = rope.gravity.z
      end
      -- Initialize debug settings for new rope
      ropeDebugSettings[id] = {
        debugDraw = uiPtrs.debugDraw[0],
        debugNodes = uiPtrs.debugNodes[0],
        debugDir = uiPtrs.debugDir[0],
        debugText = uiPtrs.debugText[0],
        debugMass = uiPtrs.debugMass[0]
      }
    end
  end
  return id
end

-- Performance tracking functions
local function updatePerfStats()
  local currentFrame = Engine.Render.getFrameId()
  if currentFrame == perfStats.lastFrameId then return end

  perfStats.frameCount = perfStats.frameCount + 1
  perfStats.lastFrameId = currentFrame

  -- Update FPS every 10 frames
  if perfStats.frameCount % 10 == 0 then
    perfStats.fps = 10 / (Engine.Platform.getRuntime() - (perfStats.lastRuntime or Engine.Platform.getRuntime()))
    perfStats.lastRuntime = Engine.Platform.getRuntime()
  end

  -- Get manager stats (if available)
  if getRopeVisualManagerStats then
    local mgrStats = getRopeVisualManagerStats()
    perfStats.totalSimTime = mgrStats.simMs or 0
    perfStats.totalRenderTime = mgrStats.renderMs or 0
  else
    perfStats.totalSimTime = 0
    perfStats.totalRenderTime = 0
  end

  -- Track history of total times for averaging
  table.insert(perfStats.totalSimTimes, perfStats.totalSimTime)
  table.insert(perfStats.totalRenderTimes, perfStats.totalRenderTime)

  if #perfStats.totalSimTimes > perfStats.historySize then
    table.remove(perfStats.totalSimTimes, 1)
  end
  if #perfStats.totalRenderTimes > perfStats.historySize then
    table.remove(perfStats.totalRenderTimes, 1)
  end

  -- Calculate averages
  local simSum = 0
  for _, t in ipairs(perfStats.totalSimTimes) do
    simSum = simSum + t
  end
  perfStats.avgTotalSimTime = simSum / #perfStats.totalSimTimes

  local renderSum = 0
  for _, t in ipairs(perfStats.totalRenderTimes) do
    renderSum = renderSum + t
  end
  perfStats.avgTotalRenderTime = renderSum / #perfStats.totalRenderTimes

  -- Track per-rope performance
  local allRopes = getAllRopeVisuals()
  perfStats.ropesPerFrame[currentFrame] = #allRopes

  for _, entry in ipairs(allRopes) do
    local ropeId = entry.id
    local rope = entry.rope

    -- Initialize tracking for new ropes
    if not perfStats.ropeSimTimes[ropeId] then
      perfStats.ropeSimTimes[ropeId] = {times = {}, avg = 0, max = 0, spikes = 0}
      perfStats.ropeRenderTimes[ropeId] = {times = {}, avg = 0, max = 0, spikes = 0}
    end

    -- Track simulation time
    local simTime = rope.simTime
    local simStats = perfStats.ropeSimTimes[ropeId]
    table.insert(simStats.times, simTime)
    if #simStats.times > perfStats.historySize then
      table.remove(simStats.times, 1)
    end

    -- Calculate average and detect spikes
    local sum = 0
    simStats.max = 0
    for _, t in ipairs(simStats.times) do
      sum = sum + t
      if t > simStats.max then simStats.max = t end
    end
    simStats.avg = sum / #simStats.times

    -- Count spikes (frames where time > threshold * average)
    simStats.spikes = 0
    for _, t in ipairs(simStats.times) do
      if t > perfStats.spikeThreshold * simStats.avg then
        simStats.spikes = simStats.spikes + 1
      end
    end
  end

  -- Clean up stats for removed ropes
  local activeRopeIds = {}
  for _, entry in ipairs(allRopes) do
    activeRopeIds[entry.id] = true
  end

  for ropeId, _ in pairs(perfStats.ropeSimTimes) do
    if not activeRopeIds[ropeId] then
      perfStats.ropeSimTimes[ropeId] = nil
      perfStats.ropeRenderTimes[ropeId] = nil
    end
  end
end

local function getRopePerfStats(ropeId)
  local simStats = perfStats.ropeSimTimes[ropeId]
  if not simStats then return nil end

  local totalFrameTime = 16.67 -- Assume 60 FPS target
  local simPercent = (simStats.avg / totalFrameTime) * 100
  local maxPercent = (simStats.max / totalFrameTime) * 100

  return {
    avgTime = simStats.avg,
    maxTime = simStats.max,
    spikeCount = simStats.spikes,
    framePercent = simPercent,
    maxFramePercent = maxPercent,
    historyCount = #simStats.times
  }
end

local function onUpdate(dt)
  -- Update performance statistics
  updatePerfStats()

  -- Update animation time
  animationTime = animationTime + dt

  -- Update base positions for selected rope
  if selectedRope then
    if not ropeBasePositions[selectedRope.id] then
      ropeBasePositions[selectedRope.id] = {}
    end
    ropeBasePositions[selectedRope.id].anchorA = vec3(uiPtrs.anchorAX[0], uiPtrs.anchorAY[0], uiPtrs.anchorAZ[0])
    ropeBasePositions[selectedRope.id].anchorB = vec3(uiPtrs.anchorBX[0], uiPtrs.anchorBY[0], uiPtrs.anchorBZ[0])
    ropeBasePositions[selectedRope.id].dirA = vec3(uiPtrs.dirAX[0], uiPtrs.dirAY[0], uiPtrs.dirAZ[0])
    ropeBasePositions[selectedRope.id].dirB = vec3(uiPtrs.dirBX[0], uiPtrs.dirBY[0], uiPtrs.dirBZ[0])
  end

  -- Apply animations to all ropes
  local allRopes = getAllRopeVisuals()
  for _, entry in ipairs(allRopes) do
    local ropeId = entry.id
    local bases = ropeBasePositions[ropeId]
    if bases then
      -- Get mutable rope reference
      local rope = getRopeVisual(ropeId)
      if rope then
        -- Apply anchor A animation (7 = Dir Sweep)
        if anchorAAnimation == 7 then
          rope.anchorA = bases.anchorA
          local baseLenA = bases.dirA and bases.dirA:length() or 0
          if baseLenA > 0 then
            rope.dirA = getAnimatedDirection(animationTime * animationTimeScale) * baseLenA
          else
            rope.dirA = vec3(0, 0, 0)
          end
        elseif anchorAAnimation > 0 then
          local animA = getAnimationOffset(anchorAAnimation, animationTime * animationTimeScale)
          rope.anchorA = bases.anchorA + animA * animationScale
          rope.dirA = bases.dirA or rope.dirA
        else
          rope.anchorA = bases.anchorA
          rope.dirA = bases.dirA or rope.dirA
        end

        -- Apply anchor B animation (7 = Dir Sweep)
        if anchorBAnimation == 7 then
          rope.anchorB = bases.anchorB
          local baseLenB = bases.dirB and bases.dirB:length() or 0
          if baseLenB > 0 then
            rope.dirB = getAnimatedDirection(animationTime * animationTimeScale) * baseLenB
          else
            rope.dirB = vec3(0, 0, 0)
          end
        elseif anchorBAnimation > 0 then
          local animB = getAnimationOffset(anchorBAnimation, animationTime * animationTimeScale)
          rope.anchorB = bases.anchorB + animB * animationScale
          rope.dirB = bases.dirB or rope.dirB
        else
          rope.anchorB = bases.anchorB
          rope.dirB = bases.dirB or rope.dirB
        end
      end
    end
  end

  -- Handle node interaction (only when debug nodes are enabled)
  local nodeInteractionEnabled = false
  if uiPtrs and uiPtrs.debugNodes[0] then
    nodeInteractionEnabled = true
  else
    for _, settings in pairs(ropeDebugSettings) do
      if settings.debugNodes then
        nodeInteractionEnabled = true
        break
      end
    end
  end

  if nodeInteractionEnabled then
    -- Update hovered node
    hoveredNode = findHoveredNode()

    -- Handle mouse input
    local mousePressed = im.IsMouseClicked(0)  -- Left mouse button
    local mouseReleased = im.IsMouseReleased(0)
    local mouseDown = im.IsMouseDown(0)

    if mousePressed and hoveredNode then
      -- Start dragging
      draggedNode = hoveredNode
      -- Set up drag plane (use XY plane at node's Z height for simplicity)
      local rope = getRopeVisual(draggedNode.ropeId)
      if rope then
        local nodes = rope:getNodes()
        if nodes and nodes[draggedNode.nodeIndex] then
          dragPlaneNormal = vec3(0, 0, 1)  -- XY plane normal
          dragPlaneDist = nodes[draggedNode.nodeIndex].pos.z  -- Z height of the node
          -- Begin dragging
          rope:setDraggedNode(draggedNode.nodeIndex)
        end
      end
    elseif mouseReleased then
      -- Stop dragging
      if draggedNode then
        local rope = getRopeVisual(draggedNode.ropeId)
        if rope then
          rope:setDraggedNode(-1) -- End dragging
        end
      end
      draggedNode = nil
    elseif mouseDown and draggedNode then
      -- Continue dragging
      handleNodeDragging()
    end
  else
    hoveredNode = nil
    draggedNode = nil
  end

  -- Draw rope nodes for all ropes
  local allRopes = getAllRopeVisuals()
  for _, entry in ipairs(allRopes) do
    local rope = getRopeVisual(entry.id)
    if rope then
      drawRopeNodes(rope)
    end
  end

  im.SetNextWindowSize(im.ImVec2(400, 600), im.Cond_FirstUseEver)
  if im.Begin("Rope Visual Sandbox", nil, im.WindowFlags_MenuBar) then

    -- Main menu bar
    if im.BeginMenuBar() then

      -- Rope Operations Menu
      if im.BeginMenu("Rope") then
        if im.MenuItem1("Create Rope", nil, false, true) then
          createRopeFromUI()
        end
        if im.IsItemHovered() then
          im.SetTooltip("Create a new rope with the current parameter settings")
        end

        if im.MenuItem1("Focus Camera", nil, false, selectedRope ~= nil) then
          if selectedRope then
            -- Ensure free camera mode
            commands.setFreeCamera()

            -- Calculate rope bounds
            local xMin = math.min(selectedRope.anchorA.x, selectedRope.anchorB.x)
            local xMax = math.max(selectedRope.anchorA.x, selectedRope.anchorB.x)
            local yMin = math.min(selectedRope.anchorA.y, selectedRope.anchorB.y)
            local yMax = math.max(selectedRope.anchorA.y, selectedRope.anchorB.y)
            local zMin = math.min(selectedRope.anchorA.z, selectedRope.anchorB.z)
            local zMax = math.max(selectedRope.anchorA.z, selectedRope.anchorB.z)

            -- Calculate center point
            local centerX = (xMin + xMax) * 0.5
            local centerY = (yMin + yMax) * 0.5
            local centerZ = (zMin + zMax) * 0.5

            -- Calculate the largest distance from center to rope bounds
            local groundDist = math.max(
              math.abs(xMax - centerX),
              math.abs(yMax - centerY)
            ) * 1.5 -- Add some padding

            -- Calculate camera distance based on FOV to fit the rope in view
            local halfFov = core_camera.getFovRad() * 0.5
            local cameraDist = groundDist / math.tan(halfFov) + 5.0

            -- Position camera in front (along positive Y axis) and look toward rope center
            -- Create rotation looking toward the rope center from the front
            local cameraPos = vec3(centerX, centerY + cameraDist, centerZ + cameraDist * 0.3)
            local lookDir = (vec3(centerX, centerY, centerZ) - cameraPos):normalized()
            local camLookFrontRot = quatFromDir(lookDir)

            -- Position camera in front of the rope center
            core_camera.setPosRot(0,
              cameraPos.x, cameraPos.y, cameraPos.z,
              camLookFrontRot.x, camLookFrontRot.y, camLookFrontRot.z, camLookFrontRot.w)
          end
        end
        if im.IsItemHovered() then
          im.SetTooltip("Move camera to focus on the selected rope")
        end

        if im.MenuItem1("Rebuild Selected", nil, false, selectedRope ~= nil) then
          if selectedRope then
            selectedRope:rebuild()
            updateUIPtrs()
          end
        end
        if im.IsItemHovered() then
          im.SetTooltip("Rebuild the selected rope with current parameters")
        end

        im.EndMenu()
      end

      -- Management Menu
      if im.BeginMenu("Management") then
        if im.MenuItem1("Delete Selected", nil, false, selectedRope ~= nil) then
          if selectedRope then
            destroyRopeVisual(selectedRope.id)
            ropeBasePositions[selectedRope.id] = nil
            ropeDebugSettings[selectedRope.id] = nil
            selectedRope = nil
          end
        end
        if im.IsItemHovered() then
          im.SetTooltip("Delete the currently selected rope")
        end

        if im.MenuItem1("Clone 10", nil, false, selectedRope ~= nil) then
          if selectedRope then
            for i = 1, 10 do
              cloneRope(selectedRope, cloneYOffset + (i - 1) * 0.2)
            end
            cloneYOffset = cloneYOffset + 2.0  -- Increment by 2 meters (10 * 0.2m)
          end
        end
        if im.IsItemHovered() then
          im.SetTooltip("Clone the selected rope 10 times with 20cm Y spacing each")
        end

        im.Separator()

        if im.MenuItem1("Clear All", nil, false, true) then
          clearAllRopeVisuals()
          ropeBasePositions = {}
          ropeDebugSettings = {}
          selectedRope = nil
          cloneYOffset = 0  -- Reset clone offset
          -- Reset performance stats
          perfStats.ropeSimTimes = {}
          perfStats.ropeRenderTimes = {}
          perfStats.ropesPerFrame = {}
          perfStats.totalSimTimes = {}
          perfStats.totalRenderTimes = {}
          perfStats.frameCount = 0
        end
        if im.IsItemHovered() then
          im.SetTooltip("Delete all ropes and reset the simulation")
        end

        if im.MenuItem1("Keep First", nil, false, true) then
          local allRopes = getAllRopeVisuals()
          if #allRopes > 1 then
            -- Keep track of the first rope's ID
            local firstRopeId = allRopes[1].id

            -- Destroy all ropes except the first one
            for i = 2, #allRopes do
              local ropeId = allRopes[i].id
              destroyRopeVisual(ropeId)
              ropeBasePositions[ropeId] = nil
              ropeDebugSettings[ropeId] = nil
              perfStats.ropeSimTimes[ropeId] = nil
              perfStats.ropeRenderTimes[ropeId] = nil
            end

            -- Select the remaining rope and reset clone offset
            selectedRope = getRopeVisual(firstRopeId)
            cloneYOffset = 0  -- Reset clone offset
            updateUIPtrs()
          end
        end
        if im.IsItemHovered() then
          im.SetTooltip("Delete all ropes except the first one")
        end

        if im.MenuItem1("Reset All", nil, false, true) then
          clearAllRopeVisuals()
          ropeBasePositions = {}
          ropeDebugSettings = {}
          selectedRope = nil
          cloneYOffset = 0  -- Reset clone offset
          -- Reset performance stats
          perfStats.ropeSimTimes = {}
          perfStats.ropeRenderTimes = {}
          perfStats.ropesPerFrame = {}
          perfStats.totalSimTimes = {}
          perfStats.totalRenderTimes = {}
          perfStats.frameCount = 0
        end
        if im.IsItemHovered() then
          im.SetTooltip("Delete all ropes and reset the simulation")
        end

        im.Separator()

        if im.MenuItem1("Quit", nil, false, true) then
          --clearAllRopeVisuals()
          extensions.unload('core_ropeVisualTest')
        end
        if im.IsItemHovered() then
          im.SetTooltip("Delete all ropes, reset everything, and unload the extension")
        end

        im.EndMenu()
      end

      -- File Menu
      if im.BeginMenu("File") then
        if im.MenuItem1("Save Parameters", nil, false, true) then
          if editor_fileDialog and editor and editor.active then
            -- Use editor file dialog if editor is active
            editor_fileDialog.saveFile(
              function(data)
                saveParametersToFile(data.filepath)
              end,
              {{"JSON files", ".json"}},
              false,
              "/"
            )
          else
            -- Fallback: use simple file path input
            openSaveModalPopup = true
          end
        end
        if im.IsItemHovered() then
          im.SetTooltip("Save current rope parameters to JSON file")
        end

        if im.MenuItem1("Load Parameters", nil, false, true) then
          if editor_fileDialog and editor and editor.active then
            -- Use editor file dialog if editor is active
            editor_fileDialog.openFile(
              function(data)
                loadParametersFromFile(data.filepath)
              end,
              {{"JSON files", ".json"}},
              false,
              "/"
            )
          else
            -- Fallback: use simple file path input
            openLoadModalPopup = true
          end
        end
        if im.IsItemHovered() then
          im.SetTooltip("Load rope parameters from JSON file")
        end

        im.EndMenu()
      end

      im.EndMenuBar()
    end

    if openSaveModalPopup then
      openSaveModalPopup = nil
      im.OpenPopup("Save Parameters")
    end

    if openLoadModalPopup then
      openLoadModalPopup = nil
      im.OpenPopup("Load Parameters")
    end

        -- Fallback file dialogs for when editor is not active
    if im.BeginPopupModal("Save Parameters") then
      im.Text("Enter file path to save parameters:")
      im.SameLine()
      im.PushItemWidth(300)
      if im.InputText("##savePath", saveFilePathPtr) then
        -- Path updated
      end
      im.PopItemWidth()

      if im.Button("Save") then
        local filePath = ffi.string(saveFilePathPtr)
        if filePath ~= "" then
          saveParametersToFile(filePath)
          im.CloseCurrentPopup()
        end
      end
      im.SameLine()
      if im.Button("Cancel") then
        im.CloseCurrentPopup()
      end
      im.EndPopup()
    end

    if im.BeginPopupModal("Load Parameters") then
      im.Text("Enter file path to load parameters:")
      im.SameLine()
      im.PushItemWidth(300)
      if im.InputText("##loadPath", loadFilePathPtr) then
        -- Path updated
      end
      im.PopItemWidth()

      if im.Button("Load") then
        local filePath = ffi.string(loadFilePathPtr)
        if filePath ~= "" then
          loadParametersFromFile(filePath)
          im.CloseCurrentPopup()
        end
      end
      im.SameLine()
      if im.Button("Cancel") then
        im.CloseCurrentPopup()
      end
      im.EndPopup()
    end

    -- Rope selection
    local allRopes = getAllRopeVisuals()
    im.Text("Active Ropes: " .. #allRopes)
    if #allRopes > 0 then
      local currentItem = 0
      for i, entry in ipairs(allRopes) do
        if selectedRope and entry.rope.id == selectedRope.id then
          currentItem = i - 1
          break
        end
      end

      local items = {}
      for _, entry in ipairs(allRopes) do
        table.insert(items, "Rope " .. entry.rope.id)
      end

      if im.Combo1("Selected Rope", im.IntPtr(currentItem), items, #items) then
        local selectedEntry = allRopes[currentItem + 1]
        selectedRope = selectedEntry.rope
        updateUIPtrs()
      end
      if im.IsItemHovered() then
        im.SetTooltip("Select which rope to edit and view parameters for")
      end
    end

    if selectedRope then
      im.Separator()
      im.Text("Rope Parameters")
      im.Separator()

      -- Animation controls
      if im.SliderFloat("Animation Scale", uiPtrs.animationScale, 0.0, 5.0) then
        animationScale = uiPtrs.animationScale[0]
      end
      if im.IsItemHovered() then
        im.SetTooltip("Controls the amplitude/intensity of rope endpoint animations (0 = no movement, 5x = maximum movement)")
      end
      if im.SliderFloat("Animation Time Scale", uiPtrs.animationTimeScale, 0.0, 5.0) then
        animationTimeScale = uiPtrs.animationTimeScale[0]
      end
      if im.IsItemHovered() then
        im.SetTooltip("Controls the speed of rope endpoint animations (0 = paused, 1.0 = normal speed, 5.0 = 5x speed)")
      end

      -- Anchor positions
      if im.BeginTable("##Anchors", 6, im.TableFlags_BordersInnerV) then
        im.TableSetupColumn("Label", im.TableColumnFlags_WidthFixed, 80)
        im.TableSetupColumn("X", im.TableColumnFlags_WidthFixed, 60)
        im.TableSetupColumn("Y", im.TableColumnFlags_WidthFixed, 60)
        im.TableSetupColumn("Z", im.TableColumnFlags_WidthFixed, 60)
        im.TableSetupColumn("Fixed", im.TableColumnFlags_WidthFixed, 30)
        im.TableSetupColumn("Animation", im.TableColumnFlags_WidthFixed, 100)

        im.TableNextRow()
        im.TableSetColumnIndex(0)
        im.Text("Anchor A:")
        if im.IsItemHovered() then
          im.SetTooltip("Starting point of the rope - where it attaches")
        end
        im.TableSetColumnIndex(1)
        if im.InputFloat("##AnchorAX", uiPtrs.anchorAX, 0, 0, "%.1f") then
          selectedRope.anchorA = vec3(uiPtrs.anchorAX[0], uiPtrs.anchorAY[0], uiPtrs.anchorAZ[0])

        end
        im.TableSetColumnIndex(2)
        if im.InputFloat("##AnchorAY", uiPtrs.anchorAY, 0, 0, "%.1f") then
          selectedRope.anchorA = vec3(uiPtrs.anchorAX[0], uiPtrs.anchorAY[0], uiPtrs.anchorAZ[0])
        end
        im.TableSetColumnIndex(3)
        if im.InputFloat("##AnchorAZ", uiPtrs.anchorAZ, 0, 0, "%.1f") then
          selectedRope.anchorA = vec3(uiPtrs.anchorAX[0], uiPtrs.anchorAY[0], uiPtrs.anchorAZ[0])
        end
        im.TableSetColumnIndex(4)
        if im.Checkbox("##AnchorAFixed", uiPtrs.anchorAFixed) then
          selectedRope.anchorAFixed = uiPtrs.anchorAFixed[0]
        end
        if im.IsItemHovered() then
          im.SetTooltip("Fix/unfix the starting anchor point (prevents movement if fixed)")
        end
        im.TableSetColumnIndex(5)
        local animationNames = {"None", "Wiggle", "Circle", "Bumpy Ride", "Rectangle", "Random Walk", "Sin Wave", "Dir Sweep"}
        if im.Combo1("##AnchorAAnim", uiPtrs.anchorAAnimation, animationNames, #animationNames) then
          anchorAAnimation = uiPtrs.anchorAAnimation[0]
        end
        if im.IsItemHovered() then
          im.SetTooltip("Select animation pattern for the starting anchor point")
        end

        im.TableNextRow()
        im.TableSetColumnIndex(0)
        im.Text("Anchor B:")
        if im.IsItemHovered() then
          im.SetTooltip("Ending point of the rope - where it attaches")
        end
        im.TableSetColumnIndex(1)
        if im.InputFloat("##AnchorBX", uiPtrs.anchorBX, 0, 0, "%.1f") then
          selectedRope.anchorB = vec3(uiPtrs.anchorBX[0], uiPtrs.anchorBY[0], uiPtrs.anchorBZ[0])
        end
        im.TableSetColumnIndex(2)
        if im.InputFloat("##AnchorBY", uiPtrs.anchorBY, 0, 0, "%.1f") then
          selectedRope.anchorB = vec3(uiPtrs.anchorBX[0], uiPtrs.anchorBY[0], uiPtrs.anchorBZ[0])
        end
        im.TableSetColumnIndex(3)
        if im.InputFloat("##AnchorBZ", uiPtrs.anchorBZ, 0, 0, "%.1f") then
          selectedRope.anchorB = vec3(uiPtrs.anchorBX[0], uiPtrs.anchorBY[0], uiPtrs.anchorBZ[0])
        end
        im.TableSetColumnIndex(4)
        if im.Checkbox("##AnchorBFixed", uiPtrs.anchorBFixed) then
          selectedRope.anchorBFixed = uiPtrs.anchorBFixed[0]
        end
        if im.IsItemHovered() then
          im.SetTooltip("Fix/unfix the ending anchor point (prevents movement if fixed)")
        end
        im.TableSetColumnIndex(5)
        if im.Combo1("##AnchorBAnim", uiPtrs.anchorBAnimation, animationNames, #animationNames) then
          anchorBAnimation = uiPtrs.anchorBAnimation[0]
        end
        if im.IsItemHovered() then
          im.SetTooltip("Select animation pattern for the ending anchor point")
        end

        im.TableNextRow()
        im.TableSetColumnIndex(0)
        im.Text("Direction A:")
        if im.IsItemHovered() then
          im.SetTooltip("Initial direction vector at the starting anchor point")
        end
        im.TableSetColumnIndex(1)
        if im.InputFloat("##DirAX", uiPtrs.dirAX, 0, 0, "%.2f") then
          local prevLength = selectedRope.dirA:length()
          selectedRope.dirA = vec3(uiPtrs.dirAX[0], uiPtrs.dirAY[0], uiPtrs.dirAZ[0])
          local newLength = selectedRope.dirA:length()
          if (prevLength == 0 and newLength > 0) or (prevLength > 0 and newLength == 0) then
            selectedRope:rebuild()
          end
        end
        im.TableSetColumnIndex(2)
        if im.InputFloat("##DirAY", uiPtrs.dirAY, 0, 0, "%.2f") then
          local prevLength = selectedRope.dirA:length()
          selectedRope.dirA = vec3(uiPtrs.dirAX[0], uiPtrs.dirAY[0], uiPtrs.dirAZ[0])
          local newLength = selectedRope.dirA:length()
          if (prevLength == 0 and newLength > 0) or (prevLength > 0 and newLength == 0) then
            selectedRope:rebuild()
          end
        end
        im.TableSetColumnIndex(3)
        if im.InputFloat("##DirAZ", uiPtrs.dirAZ, 0, 0, "%.2f") then
          local prevLength = selectedRope.dirA:length()
          selectedRope.dirA = vec3(uiPtrs.dirAX[0], uiPtrs.dirAY[0], uiPtrs.dirAZ[0])
          local newLength = selectedRope.dirA:length()
          if (prevLength == 0 and newLength > 0) or (prevLength > 0 and newLength == 0) then
            selectedRope:rebuild()
          end
        end
        im.TableSetColumnIndex(4)
        if im.Button("X##DirA") then
          uiPtrs.dirAX[0] = 0
          uiPtrs.dirAY[0] = 0
          uiPtrs.dirAZ[0] = 0
          selectedRope.dirA = vec3(0, 0, 0)
          selectedRope:rebuild()
        end
        if im.IsItemHovered() then
          im.SetTooltip("Reset starting direction vector to zero")
        end

        im.TableNextRow()
        im.TableSetColumnIndex(0)
        im.Text("Direction B:")
        if im.IsItemHovered() then
          im.SetTooltip("Initial direction vector at the ending anchor point")
        end
        im.TableSetColumnIndex(1)
        if im.InputFloat("##DirBX", uiPtrs.dirBX, 0, 0, "%.2f") then
          local prevLength = selectedRope.dirB:length()
          selectedRope.dirB = vec3(uiPtrs.dirBX[0], uiPtrs.dirBY[0], uiPtrs.dirBZ[0])
          local newLength = selectedRope.dirB:length()
          if (prevLength == 0 and newLength > 0) or (prevLength > 0 and newLength == 0) then
            selectedRope:rebuild()
          end
        end
        im.TableSetColumnIndex(2)
        if im.InputFloat("##DirBY", uiPtrs.dirBY, 0, 0, "%.2f") then
          local prevLength = selectedRope.dirB:length()
          selectedRope.dirB = vec3(uiPtrs.dirBX[0], uiPtrs.dirBY[0], uiPtrs.dirBZ[0])
          local newLength = selectedRope.dirB:length()
          if (prevLength == 0 and newLength > 0) or (prevLength > 0 and newLength == 0) then
            selectedRope:rebuild()
          end
        end
        im.TableSetColumnIndex(3)
        if im.InputFloat("##DirBZ", uiPtrs.dirBZ, 0, 0, "%.2f") then
          local prevLength = selectedRope.dirB:length()
          selectedRope.dirB = vec3(uiPtrs.dirBX[0], uiPtrs.dirBY[0], uiPtrs.dirBZ[0])
          local newLength = selectedRope.dirB:length()
          if (prevLength == 0 and newLength > 0) or (prevLength > 0 and newLength == 0) then
            selectedRope:rebuild()
          end
        end
        im.TableSetColumnIndex(4)
        if im.Button("X##DirB") then
          uiPtrs.dirBX[0] = 0
          uiPtrs.dirBY[0] = 0
          uiPtrs.dirBZ[0] = 0
          selectedRope.dirB = vec3(0, 0, 0)
          selectedRope:rebuild()
        end
        if im.IsItemHovered() then
          im.SetTooltip("Reset ending direction vector to zero")
        end
        im.EndTable()
      end

      -- Parameters
      if im.InputInt("Node Count", uiPtrs.nodeCount, 1, 10) then
        -- Clamp the value to valid range
        uiPtrs.nodeCount[0] = math.max(0, math.min(5000, uiPtrs.nodeCount[0]))
        selectedRope.nodeCount = uiPtrs.nodeCount[0]
        selectedRope:rebuild()
      end
      if im.IsItemHovered() then
        im.SetTooltip("Number of simulation nodes in the rope (higher = more detailed but slower)")
      end
      if im.SliderFloat("Length Scale", uiPtrs.lengthScale, 0.01, 10.0) then
        selectedRope.lengthScale = uiPtrs.lengthScale[0]
      end
      if im.IsItemHovered() then
        im.SetTooltip("Scales the rest length between anchor points (affects rope tension)")
      end
      if im.SliderFloat("Diameter", uiPtrs.diameter, 0.01, 0.5) then
        selectedRope.diameter = uiPtrs.diameter[0]
      end
      if im.IsItemHovered() then
        im.SetTooltip("Thickness of the rope (visual only, doesn't affect physics)")
      end
      if im.SliderFloat("Damping", uiPtrs.damping, 0.9, 1.0) then
        selectedRope.damping = uiPtrs.damping[0]
      end
      if im.IsItemHovered() then
        im.SetTooltip("How much energy is lost per frame (higher = less bouncy, more stable)")
      end
      if im.SliderFloat("Total Mass (kg)", uiPtrs.totalMass, 0.01, 1000.0) then
        selectedRope.totalMass = uiPtrs.totalMass[0]
        if selectedRope.recalculateMasses then
          selectedRope:recalculateMasses()
        end
      end
      if im.IsItemHovered() then
        im.SetTooltip("Total mass of the rope in kilograms")
      end
      if im.SliderFloat("Mass Falloff", uiPtrs.massFalloff, -1.0, 1.0) then
        selectedRope.massFalloff = uiPtrs.massFalloff[0]
        if selectedRope.recalculateMasses then
          selectedRope:recalculateMasses()
        end
      end
      if im.IsItemHovered() then
        im.SetTooltip("Mass distribution along the rope (-1 = heavier at start, 1 = heavier at end)")
      end
      if im.SliderInt("Iterations", uiPtrs.iterations, 1, 10) then
        selectedRope.iterations = uiPtrs.iterations[0]
      end
      if im.IsItemHovered() then
        im.SetTooltip("Solver iterations per update (1-10)")
      end
      if im.BeginTable("##Gravity", 4, im.TableFlags_BordersInnerV) then
        im.TableSetupColumn("Label", im.TableColumnFlags_WidthFixed, 80)
        im.TableSetupColumn("X", im.TableColumnFlags_WidthFixed, 60)
        im.TableSetupColumn("Y", im.TableColumnFlags_WidthFixed, 60)
        im.TableSetupColumn("Z", im.TableColumnFlags_WidthFixed, 60)

        im.TableNextRow()
        im.TableSetColumnIndex(0)
        im.Text("Gravity:")
        if im.IsItemHovered() then
          im.SetTooltip("Per-rope gravity override (XYZ components)")
        end
        im.TableSetColumnIndex(1)
        if im.InputFloat("##GravityX", uiPtrs.gravityX, 0, 0, "%.2f") then
          selectedRope.gravity = vec3(uiPtrs.gravityX[0], uiPtrs.gravityY[0], uiPtrs.gravityZ[0])
        end
        if im.IsItemHovered() then
          im.SetTooltip("Gravity X component")
        end
        im.TableSetColumnIndex(2)
        if im.InputFloat("##GravityY", uiPtrs.gravityY, 0, 0, "%.2f") then
          selectedRope.gravity = vec3(uiPtrs.gravityX[0], uiPtrs.gravityY[0], uiPtrs.gravityZ[0])
        end
        if im.IsItemHovered() then
          im.SetTooltip("Gravity Y component")
        end
        im.TableSetColumnIndex(3)
        if im.InputFloat("##GravityZ", uiPtrs.gravityZ, 0, 0, "%.2f") then
          selectedRope.gravity = vec3(uiPtrs.gravityX[0], uiPtrs.gravityY[0], uiPtrs.gravityZ[0])
        end
        if im.IsItemHovered() then
          im.SetTooltip("Gravity Z component")
        end

        im.EndTable()
      end
      if im.Checkbox("Use XPBD", uiPtrs.useXPBD) then
        selectedRope.useXPBD = uiPtrs.useXPBD[0]
      end
      if im.IsItemHovered() then
        im.SetTooltip("Extended Position Based Dynamics - more stable but slower simulation")
      end
      if im.Checkbox("Use World Collision", uiPtrs.useWorldCollision) then
        selectedRope.useWorldCollision = uiPtrs.useWorldCollision[0]
      end
      if im.IsItemHovered() then
        im.SetTooltip("Enable collision detection with world geometry")
      end
      if im.Checkbox("Use Self Collision", uiPtrs.useSelfCollision) then
        selectedRope.useSelfCollision = uiPtrs.useSelfCollision[0]
      end
      if im.IsItemHovered() then
        im.SetTooltip("Enable collision detection between rope segments")
      end

      -- Bending controls
      if im.Checkbox("Use Bending", uiPtrs.useBending) then
        selectedRope.useBending = uiPtrs.useBending[0]
      end
      if im.IsItemHovered() then
        im.SetTooltip("Enable bending constraints in the rope simulation")
      end
      if uiPtrs.useBending[0] then
        im.SameLine()
        -- keep the slider compact to avoid overflowing the row
        im.SetNextItemWidth(200)
        if im.SliderFloat("##BendStiffness", uiPtrs.bendStiffness, 0.0, 2.0) then
          selectedRope.bendStiffness = uiPtrs.bendStiffness[0]
        end
        if im.IsItemHovered() then
          im.SetTooltip("How resistant the rope is to bending (0 = flexible, 1 = rigid)")
        end
        im.SameLine()
        im.Text("Bend Stiffness")

        im.SameLine()
        im.SetNextItemWidth(120)
        if im.InputInt("##BendSegmentLength", uiPtrs.bendSegmentLength, 1, 1) then
          uiPtrs.bendSegmentLength[0] = math.max(1, math.min(uiPtrs.bendSegmentLength[0], 10))
          selectedRope.bendSegmentLength = uiPtrs.bendSegmentLength[0]
        end
        if im.IsItemHovered() then
          im.SetTooltip("Number of segments spanned by bending constraints")
        end
        im.SameLine()
        im.Text("Segments")
      end

      -- Strain limit controls
      if im.Checkbox("Use Strain Limit", uiPtrs.useStrainLimit) then
        selectedRope.useStrainLimit = uiPtrs.useStrainLimit[0]
      end
      if im.IsItemHovered() then
        im.SetTooltip("Limit maximum strain to prevent rope breaking")
      end
      if uiPtrs.useStrainLimit[0] then
        im.SameLine()
        -- keep the slider compact to avoid overflowing the row
        im.SetNextItemWidth(200)
        if im.SliderFloat("##MaxStrain", uiPtrs.maxStrainLimit, 0.1, 5.0) then
          selectedRope.maxStrainLimit = uiPtrs.maxStrainLimit[0]
        end
        if im.IsItemHovered() then
          im.SetTooltip("Maximum allowed strain before rope breaks (1.0 = 100% stretch)")
        end
        im.SameLine()
        im.Text("Max Strain")
      end
      if im.InputFloat("Young's Modulus", uiPtrs.youngsModulus, 1e5, 1e9, "%.0f") then
        selectedRope.youngsModulus = uiPtrs.youngsModulus[0]
      end
      if im.IsItemHovered() then
        im.SetTooltip("Material stiffness (higher = less stretchy, more like steel)")
      end
      if im.Checkbox("Render Rope", uiPtrs.renderRope) then
        selectedRope.renderRope = uiPtrs.renderRope[0]
      end
      if im.IsItemHovered() then
        im.SetTooltip("Toggle rope geometry rendering on/off")
      end
      if im.SliderFloat("Wind Scale", uiPtrs.windScale, 0.0, 10.0) then
        selectedRope.windScale = uiPtrs.windScale[0]
      end
      if im.IsItemHovered() then
        im.SetTooltip("Strength of wind force applied to the rope")
      end
      if im.SliderFloat("Wind Drag", uiPtrs.windDrag, 0.0, 1.0) then
        selectedRope.windDrag = uiPtrs.windDrag[0]
      end
      if im.IsItemHovered() then
        im.SetTooltip("How much wind drag affects the rope movement")
      end
      if im.SliderInt("Simulation FPS", uiPtrs.simFPS, 1, 300) then
        if selectedRope then
          selectedRope.simFPS = uiPtrs.simFPS[0]
        end
      end
      if im.IsItemHovered() then
        im.SetTooltip("Target simulation frames per second for rope physics")
      end
      if im.InputText("Material Name", materialNamePtr) then
        selectedRope.materialName = ffi.string(materialNamePtr)
      end
      if im.IsItemHovered() then
        im.SetTooltip("Name of the material to use for rope rendering")
      end
      -- C1, C2, C3 inputs disabled - TODO: Figure out correct type
      -- if im.InputFloat("C1", uiPtrs.c1) then
      --   ropeParams.c1 = uiPtrs.c1[0]
      -- end
      -- if im.InputFloat("C2", uiPtrs.c2) then
      --   ropeParams.c2 = uiPtrs.c2[0]
      -- end
      -- if im.InputFloat("C3", uiPtrs.c3) then
      --   ropeParams.c3 = uiPtrs.c3[0]
      -- end

      -- Debug section (kept at bottom) with columns
      im.Separator()
      im.Text("Debug")
      if im.IsItemHovered() then
        im.SetTooltip("Debug visualization toggles")
      end
      if im.BeginTable("##DebugOptions", 2, im.TableFlags_BordersInnerV) then
        im.TableSetupColumn("Visualization", im.TableColumnFlags_WidthStretch, 0.5)
        im.TableSetupColumn("Information", im.TableColumnFlags_WidthStretch, 0.5)

        -- Row 1
        im.TableNextRow()
        im.TableSetColumnIndex(0)
        if im.Checkbox("Debug Draw", uiPtrs.debugDraw) then
          if selectedRope and ropeDebugSettings[selectedRope.id] then
            ropeDebugSettings[selectedRope.id].debugDraw = uiPtrs.debugDraw[0]
          end
        end
        if im.IsItemHovered() then
          im.SetTooltip("Show basic debug visualization of the rope")
        end

        im.TableSetColumnIndex(1)
        if im.Checkbox("Debug Text", uiPtrs.debugText) then
          if selectedRope and ropeDebugSettings[selectedRope.id] then
            ropeDebugSettings[selectedRope.id].debugText = uiPtrs.debugText[0]
          end
        end
        if im.IsItemHovered() then
          im.SetTooltip("Show debug text information for rope nodes")
        end

        -- Row 2
        im.TableNextRow()
        im.TableSetColumnIndex(0)
        if im.Checkbox("Debug Nodes", uiPtrs.debugNodes) then
          if selectedRope and ropeDebugSettings[selectedRope.id] then
            ropeDebugSettings[selectedRope.id].debugNodes = uiPtrs.debugNodes[0]
          end
        end
        if im.IsItemHovered() then
          im.SetTooltip("Show individual rope nodes as spheres")
        end

        im.TableSetColumnIndex(1)
        if im.Checkbox("Debug Dir", uiPtrs.debugDir) then
          if selectedRope and ropeDebugSettings[selectedRope.id] then
            ropeDebugSettings[selectedRope.id].debugDir = uiPtrs.debugDir[0]
          end
        end
        if im.IsItemHovered() then
          im.SetTooltip("Show direction vectors at rope nodes")
        end

        -- Row 3
        im.TableNextRow()
        im.TableSetColumnIndex(0)
        if im.Checkbox("Debug Mass", uiPtrs.debugMass) then
          if selectedRope and ropeDebugSettings[selectedRope.id] then
            ropeDebugSettings[selectedRope.id].debugMass = uiPtrs.debugMass[0]
          end
        end
        if im.IsItemHovered() then
          im.SetTooltip("Visualize node mass values")
        end

        im.TableSetColumnIndex(1)
        -- Empty cell for alignment
        im.Text("")

        im.EndTable()
      end

      -- Manual rebuild button
      if im.Button("Rebuild Rope") then
        selectedRope:rebuild()
      end
      if im.IsItemHovered() then
        im.SetTooltip("Manually rebuild the rope physics simulation")
      end

      im.Separator()
      im.Text("Rope Info (ID: " .. selectedRope.id .. ")")
      if im.IsItemHovered() then
        im.SetTooltip("Real-time rope simulation statistics")
      end
      im.Text(string.format("Max Strain: %.4f", selectedRope.maxStrain))
      if im.IsItemHovered() then
        im.SetTooltip("Maximum strain (stretch) in any rope segment")
      end
      im.Text(string.format("Avg Strain: %.4f", selectedRope.avgStrain))
      if im.IsItemHovered() then
        im.SetTooltip("Average strain across all rope segments")
      end
      im.Text(string.format("Current Length: %.4f", selectedRope.currentLength))
      if im.IsItemHovered() then
        im.SetTooltip("Current total length of the rope")
      end
      im.Text(string.format("Segment (Rest) Length: %.4f", selectedRope.restLength))
      if im.IsItemHovered() then
        im.SetTooltip("Target length of the rope when at rest")
      end
      im.Text(string.format("Sim Time: %.3f ms", selectedRope.simTime))
      if im.IsItemHovered() then
        im.SetTooltip("Time taken for the last physics simulation step")
      end
    end

    im.Separator()
    im.Text("Overall Performance Stats")
    if im.IsItemHovered() then
      im.SetTooltip("Advanced performance metrics and frame analysis")
    end

    -- Global performance
    local mgrStats = nil
    local hasManagerStats = false
    if getRopeVisualManagerStats then
      mgrStats = getRopeVisualManagerStats()
      hasManagerStats = true
    end

    im.Text(string.format("FPS: %.1f", perfStats.fps))
    if im.IsItemHovered() then
      im.SetTooltip("Current frames per second")
    end

    if hasManagerStats then
      local totalFrameTime = 16.67 -- 60 FPS target
      local avgSimPercent = (perfStats.avgTotalSimTime / totalFrameTime) * 100
      local avgRenderPercent = (perfStats.avgTotalRenderTime / totalFrameTime) * 100

      im.Text(string.format("Frame Time: Sim %.1f%% + Render %.1f%% = %.1f%%",
        avgSimPercent, avgRenderPercent, avgSimPercent + avgRenderPercent))
      if im.IsItemHovered() then
        im.SetTooltip("Percentage of target frame time (16.67ms @ 60FPS) used by ropes")
      end

      im.Text(string.format("Objects: %d", mgrStats.objectsRendered))
      if im.IsItemHovered() then
        im.SetTooltip("Total number of rope objects simulated and rendered")
      end

      im.Text(string.format("Total Sim: %.3f ms avg (%.1f%% frame)",
        perfStats.avgTotalSimTime, avgSimPercent))
      if im.IsItemHovered() then
        im.SetTooltip(string.format("Average time spent simulating all rope physics (%.3f ms current)",
          perfStats.totalSimTime))
      end

      im.Text(string.format("Total Render: %.3f ms avg (%.1f%% frame)",
        perfStats.avgTotalRenderTime, avgRenderPercent))
      if im.IsItemHovered() then
        im.SetTooltip(string.format("Average time spent rendering all rope visuals (%.3f ms current)",
          perfStats.totalRenderTime))
      end
    else
      im.Text("Manager stats not available")
      if im.IsItemHovered() then
        im.SetTooltip("getRopeVisualManagerStats function not available")
      end
    end

    -- Per-rope performance (for all ropes)
    local allRopes = getAllRopeVisuals()
    if #allRopes > 0 then
      im.Separator()
      im.Text("Per-Rope Performance")
      if im.IsItemHovered() then
        im.SetTooltip("Performance stats for each individual rope")
      end

      -- Calculate average sim time per object
      local totalRopeSimTime = 0
      local ropesWithStats = 0

      for _, entry in ipairs(allRopes) do
        local ropeStats = getRopePerfStats(entry.id)
        if ropeStats then
          totalRopeSimTime = totalRopeSimTime + ropeStats.avgTime
          ropesWithStats = ropesWithStats + 1
        end
      end

      local avgSimPerObject = 0
      if ropesWithStats > 0 then
        avgSimPerObject = totalRopeSimTime / ropesWithStats
      end

      im.Text(string.format("Avg Sim per Object: %.3f ms", avgSimPerObject))
      if im.IsItemHovered() then
        im.SetTooltip(string.format("Average simulation time per rope object (%d ropes with stats)",
          ropesWithStats))
      end
    end

    im.End()
  end
end

-- Initialize ropes on module load
local function onExtensionLoaded(serializedData)
  -- Restore UI state from serialized data
  if serializedData and serializedData.uiState then
    local ui = serializedData.uiState

    -- Anchor positions
    uiPtrs.anchorAX[0] = ui.anchorAX or 0
    uiPtrs.anchorAY[0] = ui.anchorAY or 0
    uiPtrs.anchorAZ[0] = ui.anchorAZ or 3
    uiPtrs.anchorBX[0] = ui.anchorBX or 5
    uiPtrs.anchorBY[0] = ui.anchorBY or 0
    uiPtrs.anchorBZ[0] = ui.anchorBZ or 3

    -- Direction vectors
    uiPtrs.dirAX[0] = ui.dirAX or 0
    uiPtrs.dirAY[0] = ui.dirAY or 0
    uiPtrs.dirAZ[0] = ui.dirAZ or -1
    uiPtrs.dirBX[0] = ui.dirBX or 0
    uiPtrs.dirBY[0] = ui.dirBY or 0
    uiPtrs.dirBZ[0] = ui.dirBZ or -1

    -- Core rope properties
    uiPtrs.nodeCount[0] = ui.nodeCount or 32
    uiPtrs.lengthScale[0] = ui.lengthScale or 1.0
    uiPtrs.diameter[0] = ui.diameter or 0.12
    uiPtrs.damping[0] = ui.damping or 0.995
    uiPtrs.bendStiffness[0] = ui.bendStiffness or 0.6

    -- Simulation toggles
    uiPtrs.useXPBD[0] = ui.useXPBD
    uiPtrs.useBending[0] = ui.useBending
    uiPtrs.bendSegmentLength[0] = ui.bendSegmentLength or 3
    uiPtrs.useWorldCollision[0] = ui.useWorldCollision
    uiPtrs.useSelfCollision[0] = ui.useSelfCollision
    uiPtrs.useStrainLimit[0] = ui.useStrainLimit
    uiPtrs.maxStrainLimit[0] = ui.maxStrainLimit or 1.0

    -- Physics properties
    uiPtrs.totalMass[0] = ui.totalMass or 1.0
    uiPtrs.massFalloff[0] = ui.massFalloff or 0.0
    uiPtrs.iterations[0] = ui.iterations or 1
    uiPtrs.gravityX[0] = ui.gravityX or 0.0
    uiPtrs.gravityY[0] = ui.gravityY or 0.0
    uiPtrs.gravityZ[0] = ui.gravityZ or -9.81
    uiPtrs.youngsModulus[0] = ui.youngsModulus or 1e7

    -- Rendering
    uiPtrs.renderRope[0] = ui.renderRope
    uiPtrs.windScale[0] = ui.windScale or 1.0
    uiPtrs.windDrag[0] = ui.windDrag or 1.0

    -- Material name
    if ui.materialName and ui.materialName ~= "" then
      materialNamePtr = im.ArrayChar(256, ui.materialName)
    end

    -- Anchor constraints (the "anchor pinned thing" the user mentioned)
    uiPtrs.anchorAFixed[0] = ui.anchorAFixed
    uiPtrs.anchorBFixed[0] = ui.anchorBFixed

    -- Simulation
    uiPtrs.simFPS[0] = ui.simFPS or 60

    -- Animation
    animationScale = ui.animationScale or 1.0
    animationTimeScale = ui.animationTimeScale or 1.0
    anchorAAnimation = ui.anchorAAnimation or 0
    anchorBAnimation = ui.anchorBAnimation or 0

    -- Debug settings
    uiPtrs.debugDraw[0] = ui.debugDraw
    uiPtrs.debugNodes[0] = ui.debugNodes
    uiPtrs.debugDir[0] = ui.debugDir
    uiPtrs.debugText[0] = ui.debugText
    uiPtrs.debugMass[0] = ui.debugMass

    -- Unused fields
    uiPtrs.c1[0] = ui.c1 or 0.0
    uiPtrs.c2[0] = ui.c2 or 0.0
    uiPtrs.c3[0] = ui.c3 or 0.0
  end

  -- Reset clone offset (not saved)
  cloneYOffset = 0

  -- Initialize with existing ropes if any
  local allRopes = getAllRopeVisuals()
  if #allRopes > 0 then
    -- Load existing ropes into our tracking system
    for _, entry in ipairs(allRopes) do
      local ropeId = entry.id
      local rope = getRopeVisual(ropeId)
      if rope and not ropeBasePositions[ropeId] then
        ropeBasePositions[ropeId] = {
          anchorA = vec3(rope.anchorA.x, rope.anchorA.y, rope.anchorA.z),
          anchorB = vec3(rope.anchorB.x, rope.anchorB.y, rope.anchorB.z),
          dirA = vec3(rope.dirA.x, rope.dirA.y, rope.dirA.z),
          dirB = vec3(rope.dirB.x, rope.dirB.y, rope.dirB.z)
        }
        -- Initialize debug settings for existing ropes (use defaults)
        ropeDebugSettings[ropeId] = {
          debugDraw = false,
          debugNodes = false,
          debugDir = false,
          debugText = false,
          debugMass = false
        }
      end
    end
    -- Select the first rope
    local firstRope = getRopeVisual(allRopes[1].id)
    if firstRope then
      selectedRope = firstRope
      updateUIPtrs()
    end
  end
end

-- Exports
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onSerialize = onSerialize
M.onUpdate = onUpdate

return M