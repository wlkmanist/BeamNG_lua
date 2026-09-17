-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Runtime coordinator for Audio Forest emitters.
-- Main emitter RTPCs: volume=loudness, pitch=node density, color=vegetation size, texture=unused.
-- Global RTPC: g_ForestHeight is listener height relative to the forest centroid/fallback terrain.

local M = {}

-- Module dependencies.
local audioForestCommon = require('core/audioForest/audioForestCommon')

-- Module constants.
local abs, sqrt, min, huge = math.abs, math.sqrt, math.min, math.huge
local diskFileName = "forestData.audioSFX.json"
local forestHeightEps = 0.05 -- RTPC write threshold in meters
local zLift = 0.05 -- keeps the emitter just above the centroid
local loudnessEps = 0.5 -- inverse-distance smoothing
local volGainBase = 10.0
local volGainMul = 3
local volGain = volGainBase * volGainMul
local runtimeLoadStepCount = 10000

-- Module state.
local persistedToolState = nil
local enabled = false
local sphereRadiusIn = 150.0 -- listener query radius
local sphereInSq = sphereRadiusIn * sphereRadiusIn
local mainEventName = ''
local nodeCount = 0
local nodeX, nodeY, nodeZ, nodeDepth, nodeAvgNormVol, nodeSourceCount
local kdNodes
local pitchDensityInvAuto = 0.0
local pitchDensityInvOverride = nil
local lPosition = vec3()
local tmpPos = vec3()
local identityTransform = MatrixF(true)
local roomtoneEnabled = false -- Roomtone state.
local roomtoneEventName = ''
local roomtoneZ = 0.0
local roomtoneEmitter = nil
local roomtoneEmitterId = 0
local roomtonePos = vec3(0, 0, 0)
local emitters = {} -- Main emitter state. [1] = SFXEmitter
local emitterNodeId = { 0 } -- [1] = representative nodeId (for editor highlight)
local mainEmitterId = 0
local sumW, sumX, sumY, sumZ = 0.0, 0.0, 0.0, 0.0 -- Accumulators (reused each frame).
local sumWL, sumCW, sumPD = 0.0, 0.0, 0.0
local repNode, repD2 = 0, huge
local mainEmitterActive = false
local mainEmitterX, mainEmitterY, mainEmitterZ = 0.0, 0.0, 0.0
local globalParams = nil -- Global RTPC cache for signed listener-to-forest height.
local lastForestHeight = huge
local terrainBlock = nil
local runtimePrepass, runtimePrepassForestObj, runtimePrepassState, runtimePrepassMainEvent
local runtimePrepassStartTime = 0.0
local runtimePrepassFrames, runtimePrepassStepTotal, runtimePrepassStepMax = 0, 0.0, 0.0


-- Ensures the per-level audio forest folder exists before saving.
local function ensureDirectoryForFile(filename)
  if not FS or not FS.directoryExists or not FS.directoryCreate then
    return
  end
  local dir = filename and filename:match("^(.*)/[^/]*$") or nil
  if dir and dir ~= '' and (not FS:directoryExists(dir)) then
    FS:directoryCreate(dir, true)
  end
end

-- Writes the editor tool state as deterministic JSON lines.
local function writeToolStateToFile(filename, st)
  ensureDirectoryForFile(filename)
  local file = io.open(filename, "w")
  if not file then
    log('E', 'audioForest', "Could not open file for writing: " .. filename)
    return
  end

  local version = tonumber(st and st.version) or 1
  local mainEvent = tostring(st and st.mainEvent or '')
  local nodeVisDrawRadius = tonumber(st and st.nodeVisDrawRadius) or 500.0
  local nodeVisSphereRadius = tonumber(st and st.nodeVisSphereRadius) or 2.25
  local showNodes = (st and st.showNodes) and 1 or 0
  local selectedRow = tonumber(st and st.selectedRow) or 1
  local roomtoneOn = (st and st.roomtoneEnabled) and 1 or 0
  local roomtoneEvent = tostring(st and st.roomtoneEvent or '')
  local roomtoneZ0 = tonumber(st and st.roomtoneZ) or 0.0

  local metaLine = string.format(
    '{"type":"meta","version":%d,"mainEvent":"%s","nodeVisDrawRadius":%.10g,"nodeVisSphereRadius":%.10g,"showNodes":%d,"selectedRow":%d,"roomtoneEnabled":%d,"roomtoneEvent":"%s","roomtoneZ":%.10g}',
    version, mainEvent, nodeVisDrawRadius, nodeVisSphereRadius, showNodes, selectedRow, roomtoneOn, roomtoneEvent, roomtoneZ0
  )
  file:write(metaLine .. "\n")

  local inc = (st and st.includeByShape) or {}
  local sel = (st and st.classSelByShape) or {}
  local ovr = (st and st.classOverrideByShape) or {}

  local shapes = {}
  local n = 0
  for shape, _ in pairs(inc) do
    n = n + 1
    shapes[n] = shape
  end
  for shape, _ in pairs(sel) do
    if inc[shape] == nil then
      n = n + 1
      shapes[n] = shape
    end
  end
  for shape, _ in pairs(ovr) do
    if inc[shape] == nil and sel[shape] == nil then
      n = n + 1
      shapes[n] = shape
    end
  end

  table.sort(shapes, function(a, b) return (a or '') < (b or '') end)

  local lastShape = nil
  for i = 1, n do
    local shape = shapes[i]
    if shape ~= lastShape then
      lastShape = shape
      local includeV = (inc[shape] == nil or inc[shape]) and 1 or 0
      local classSel = tonumber(sel[shape]) or 0
      local classOvr = (ovr[shape]) and 1 or 0
      local shapeLine = string.format(
        '{"type":"shape","shape":"%s","include":%d,"classSel":%d,"classOvr":%d}',
        shape, includeV, classSel, classOvr
      )
      file:write(shapeLine .. "\n")
    end
  end

  file:close()
end

-- Reads the per-level editor tool state from JSON lines.
local function readToolStateFromFile(filename)
  local file = io.open(filename, "r")
  if not file then
    return nil
  end

  local st = { version = 1, includeByShape = {}, classSelByShape = {}, classOverrideByShape = {} }
  for line in file:lines() do
    local data = jsonDecode(line)
    if data and data.type == "meta" then
      st.version = tonumber(data.version) or 1
      st.mainEvent = data.mainEvent or ''
      st.nodeVisDrawRadius = tonumber(data.nodeVisDrawRadius) or st.nodeVisDrawRadius
      st.nodeVisSphereRadius = tonumber(data.nodeVisSphereRadius) or st.nodeVisSphereRadius
      st.showNodes = (data.showNodes and data.showNodes > 0.5) and true or false
      st.selectedRow = tonumber(data.selectedRow) or st.selectedRow
      st.roomtoneEnabled = (data.roomtoneEnabled and data.roomtoneEnabled > 0.5) and true or false
      st.roomtoneEvent = data.roomtoneEvent or ''
      st.roomtoneZ = tonumber(data.roomtoneZ) or st.roomtoneZ
    elseif data and data.type == "shape" then
      local shape = data.shape or ''
      if shape ~= '' then
        st.includeByShape[shape] = (data.include and data.include > 0.5) and true or false
        st.classSelByShape[shape] = tonumber(data.classSel) or st.classSelByShape[shape]
        st.classOverrideByShape[shape] = (data.classOvr and data.classOvr > 0.5) and true or false
      end
    end
  end
  file:close()
  return st
end

-- Stores editor state for save hooks and editor reactivation.
local function setPersistedToolState(st)
  persistedToolState = st
end

-- Returns the currently loaded editor state.
local function getPersistedToolState()
  return persistedToolState
end

-- Writes forest height only when the value meaningfully changes.
local function setGlobalForestHeight(v)
  if abs(v - lastForestHeight) < forestHeightEps then
    return -- No change, so no need to set the global parameter.
  end
  lastForestHeight = v
  globalParams:setParameterValue("g_ForestHeight", v)
end

-- Creates and starts one unsaved SFX emitter.
local function createSfxEmitter(eventName)
  local emitter = createObject("SFXEmitter")
  emitter = Sim.upcast(emitter)
  emitter:setTransform(identityTransform)
  emitter:setField("track", 0, eventName)
  emitter.canSave = false
  emitter:registerObject('DynamicSFXEmitter_' .. Engine.generateUUID())
  emitter:setVolumePitchCT(0.0, 1.0, 0.0, 0.0)
  emitter:play()
  return emitter
end

-- Deletes a scene object id if it still exists.
local function deleteObjectById(id)
  if id == 0 then
    return
  end
  local obj = scenetree.findObjectById(id)
  if obj then
    obj:delete()
  end
end

-- Deletes only the independent roomtone emitter.
local function deleteRoomtoneEmitter()
  if roomtoneEmitterId ~= 0 then
    deleteObjectById(roomtoneEmitterId)
  end
  roomtoneEmitter = nil
  roomtoneEmitterId = 0
end

-- Creates the independent roomtone emitter.
local function createRoomtoneEmitter()
  roomtoneEmitter = createSfxEmitter(roomtoneEventName)
  roomtoneEmitterId = roomtoneEmitter:getId()
  roomtonePos:set(0.0, 0.0, roomtoneZ)
  roomtoneEmitter:setPosition(roomtonePos)
end

-- Creates the main forest centroid emitter.
local function createMainEmitter()
  local em = createSfxEmitter(mainEventName)
  emitters[1] = em
  mainEmitterId = em:getId()
  emitterNodeId[1] = 0
end

-- Deletes only the main forest centroid emitter.
local function deleteMainEmitter()
  if mainEmitterId ~= 0 then
    deleteObjectById(mainEmitterId)
  end
  emitters[1] = nil
  mainEmitterId = 0
  emitterNodeId[1] = 0
end

-- Installs a valid shared graph cloud for runtime use.
local function setNodeCloud(cloud)
  if not cloud or not cloud.nodeCount or cloud.nodeCount < 1 or not cloud.kdNodes then
    nodeCount = 0
    nodeX, nodeY, nodeZ, nodeDepth, nodeAvgNormVol, nodeSourceCount = nil, nil, nil, nil, nil, nil
    kdNodes = nil
    pitchDensityInvAuto = 0.0
    return false
  end

  nodeCount = cloud.nodeCount
  nodeX, nodeY, nodeZ = cloud.nodeX, cloud.nodeY, cloud.nodeZ
  nodeDepth = cloud.nodeDepth
  nodeAvgNormVol = cloud.nodeAvgNormVol
  nodeSourceCount = cloud.nodeSourceCount
  kdNodes = cloud.kdNodes

  terrainBlock = core_terrain.getTerrain()
  if not terrainBlock then
    nodeCount = 0
    nodeX, nodeY, nodeZ, nodeDepth, nodeAvgNormVol, nodeSourceCount = nil, nil, nil, nil, nil, nil
    kdNodes = nil
    pitchDensityInvAuto = 0.0
    return false
  end

  globalParams = Engine.Audio.getGlobalParams()
  pitchDensityInvAuto = cloud.pitchDensityInv or 0.0
  return true
end

-- Sets the main forest event without disturbing roomtone.
local function setMainEvent(eventName)
  mainEventName = eventName or ''
  if mainEventName == '' then
    deleteMainEmitter()
    return
  end
  if emitters[1] then
    emitters[1]:setField("track", 0, mainEventName)
    emitters[1]:play()
  elseif enabled and nodeCount > 0 and kdNodes then
    createMainEmitter()
  end
end

-- Updates the main forest emitter from nearby thinned KD nodes.
local function onUpdate(dtReal, dtSim, dtRaw)
  if runtimePrepass then
    local stepT0 = os.clockhp()
    local prepassReady = audioForestCommon.stepRuntimePrepass(runtimePrepass, runtimeLoadStepCount)
    local stepDt = os.clockhp() - stepT0
    runtimePrepassFrames = runtimePrepassFrames + 1
    runtimePrepassStepTotal = runtimePrepassStepTotal + stepDt
    if stepDt > runtimePrepassStepMax then
      runtimePrepassStepMax = stepDt
    end
    if prepassReady then
      local cloud = audioForestCommon.buildNodeCloudFromForest(runtimePrepassForestObj, runtimePrepassState, nil, { prepass = runtimePrepass })
      runtimePrepass, runtimePrepassForestObj, runtimePrepassState = nil, nil, nil
      if setNodeCloud(cloud) then
        enabled = true
        setMainEvent(runtimePrepassMainEvent)
      end
      runtimePrepassMainEvent = nil
    end
  end

  if not enabled then
    return
  end
  if nodeCount < 1 or not kdNodes then
    enabled = false
    deleteMainEmitter()
    return
  end

  lPosition:set(SFXSystem.getPositionXYZ())

  sumW, sumX, sumY, sumZ = 0.0, 0.0, 0.0, 0.0
  sumWL, sumCW, sumPD = 0.0, 0.0, 0.0
  repNode, repD2 = 0, huge

  local lx, ly, lz = lPosition.x, lPosition.y, lPosition.z
  local qx0, qx1 = lx - sphereRadiusIn, lx + sphereRadiusIn
  local qy0, qy1 = ly - sphereRadiusIn, ly + sphereRadiusIn
  local qz0, qz1 = lz - sphereRadiusIn, lz + sphereRadiusIn
  local radiusSq = sphereInSq
  local loudEps = loudnessEps
  local nodeXL, nodeYL, nodeZL, nodeDepthL = nodeX, nodeY, nodeZ, nodeDepth
  local nodeAvgNormVolL, nodeSourceCountL = nodeAvgNormVol, nodeSourceCount

  for nid in kdNodes:queryNotNested(qx0, qy0, qz0, qx1, qy1, qz1) do
    local nx, ny, nz = nodeXL[nid], nodeYL[nid], nodeZL[nid] + nodeDepthL[nid]
    local dx, dy, dz = nx - lx, ny - ly, nz - lz
    local dSquared = dx * dx + dy * dy + dz * dz
    if dSquared < radiusSq then
      local dist = sqrt(dSquared)
      local w = sphereRadiusIn - dist
      sumW, sumX, sumY, sumZ = sumW + w, sumX + nx * w, sumY + ny * w, sumZ + nz * w
      sumCW = sumCW + nodeAvgNormVolL[nid] * w
      sumPD = sumPD + nodeSourceCountL[nid] * w
      sumWL = sumWL + w * loudEps / (dist + loudEps)
      if dSquared < repD2 then
        repD2, repNode = dSquared, nid
      end
    end
  end

  local em = emitters[1]

  if sumW > 0.0 then
    local invW = 1.0 / sumW
    local px = sumX * invW
    local py = sumY * invW
    local pz = sumZ * invW + zLift
    local vol = min(sumWL * invW * volGain, 1.0)
    local invPitch = pitchDensityInvOverride or pitchDensityInvAuto
    local pitch = min(sumPD * invW * invPitch, 1.0)
    local col = sumCW * invW

    tmpPos:set(px, py, pz)
    em:setPosition(tmpPos)
    mainEmitterActive = true
    mainEmitterX, mainEmitterY, mainEmitterZ = px, py, pz
    setGlobalForestHeight(lz - pz)
    em:setVolumePitchCT(vol, pitch, col, 0.0)

    emitterNodeId[1] = repNode
  else
    mainEmitterActive = false
    local invPitch = pitchDensityInvOverride or pitchDensityInvAuto
    local pitch = min(sumPD * invPitch, 1.0)
    setGlobalForestHeight(lPosition.z - terrainBlock:getHeight(lPosition))
    em:setVolumePitchCT(0.0, pitch, 0.0, 0.0)
    emitterNodeId[1] = 0
  end
end

-- Runtime/editor feed API.
local function setEnabled(v)
  enabled = v and true or false
  if enabled then
    if mainEventName ~= '' and nodeCount > 0 and kdNodes and not emitters[1] then
      createMainEmitter()
    end
  else
    deleteMainEmitter()
  end
end

-- Overrides or clears the source-density pitch normalization factor.
local function setPitchDensityInv(v)
  if v == nil or v <= 0.0 then
    pitchDensityInvOverride = nil
    return
  end
  pitchDensityInvOverride = v
end

-- Enables or disables the independent roomtone emitter.
local function setRoomtoneEnabled(v)
  roomtoneEnabled = v and true or false
  if (not roomtoneEnabled) or roomtoneEventName == '' then
    deleteRoomtoneEmitter()
  elseif not roomtoneEmitter then
    createRoomtoneEmitter()
  end
end

-- Sets the independent roomtone event.
local function setRoomtoneEvent(eventName)
  roomtoneEventName = eventName or ''
  if not roomtoneEnabled then
    return
  end
  if roomtoneEventName == '' then
    deleteRoomtoneEmitter()
    return
  end
  if roomtoneEmitter then
    roomtoneEmitter:setField("track", 0, roomtoneEventName)
    roomtoneEmitter:play()
    roomtonePos:set(0.0, 0.0, roomtoneZ)
    roomtoneEmitter:setPosition(roomtonePos)
  else
    createRoomtoneEmitter()
  end
end

-- Sets the independent roomtone emitter height.
local function setRoomtoneZ(v)
  roomtoneZ = tonumber(v) or 0.0
  if roomtoneEmitter then
    roomtonePos:set(0.0, 0.0, roomtoneZ)
    roomtoneEmitter:setPosition(roomtonePos)
  end
end

-- Clears level-owned playback objects and generated node data before rebuilding.
local function clearLoadedLevelRuntime()
  deleteMainEmitter()
  deleteRoomtoneEmitter()
  enabled = false
  nodeCount = 0
  nodeX, nodeY, nodeZ, nodeDepth, nodeAvgNormVol, nodeSourceCount = nil, nil, nil, nil, nil, nil
  kdNodes = nil
  runtimePrepass, runtimePrepassForestObj, runtimePrepassState = nil, nil, nil
  runtimePrepassMainEvent = nil
  runtimePrepassFrames, runtimePrepassStepTotal, runtimePrepassStepMax = 0, 0.0, 0.0
  pitchDensityInvAuto = 0.0
  emitterNodeId[1] = 0
  mainEmitterActive = false
  mainEmitterX, mainEmitterY, mainEmitterZ = 0.0, 0.0, 0.0
  terrainBlock = nil
  globalParams = nil
  lastForestHeight = huge
end

-- Loads saved per-level audio forest config and builds runtime state.
local function loadRuntimeFromLevelFile()
  clearLoadedLevelRuntime()
  local levelName = getCurrentLevelIdentifier()
  if not levelName then
    return -- No level, so leave immediately.
  end

  local filepath = "levels/" .. levelName .. "/dynamicAudioEmitters/" .. diskFileName
  local st = readToolStateFromFile(filepath)
  if not st then
    return -- No tool state, so leave immediately.
  end

  terrainBlock = core_terrain.getTerrain()
  if not terrainBlock then
    return
  end

  persistedToolState = st
  setRoomtoneZ(st.roomtoneZ)
  setRoomtoneEvent(st.roomtoneEvent or '')
  setRoomtoneEnabled(st.roomtoneEnabled == true)

  local mainEvent = st.mainEvent or ''
  if mainEvent == '' then
    return
  end

  local forestObj = extensions.core_forest.getForestObject()
  if not forestObj then
    return
  end

  runtimePrepass = audioForestCommon.startRuntimePrepass(forestObj, st)
  runtimePrepassForestObj = forestObj
  runtimePrepassState = st
  runtimePrepassMainEvent = mainEvent
  runtimePrepassStartTime = os.clockhp()
  runtimePrepassFrames, runtimePrepassStepTotal, runtimePrepassStepMax = 0, 0.0, 0.0
end

-- Level load/save hooks.
local function onClientCustomObjectSpawning()
  loadRuntimeFromLevelFile()
end

-- Runtime state is reconstructed from the level file after Lua reload.
local function onSerialize()
  return {}
end

local function onDeserialized(data)
  loadRuntimeFromLevelFile()
end

-- Saves persisted tool state before the editor saves the level.
local function onEditorBeforeSaveLevel()
  local levelName = getCurrentLevelIdentifier()
  if levelName and persistedToolState then
    local filepath = "levels/" .. levelName .. "/dynamicAudioEmitters/" .. diskFileName
    writeToolStateToFile(filepath, persistedToolState)
  end
end

-- Returns representative node ids for editor highlighting.
local function getEmitterNodeIds()
  return emitterNodeId, 1
end

-- Returns the current blended main emitter position for editor visualization.
local function getMainEmitterDebugState()
  return mainEmitterActive, mainEmitterX, mainEmitterY, mainEmitterZ, emitterNodeId[1]
end

-- Clears only the main forest audio path.
local function clearMainAudio()
  deleteMainEmitter()
  mainEventName = ''
  mainEmitterActive = false
end

-- Resets all runtime state for level transitions.
local function resetRuntime()
  deleteMainEmitter()
  deleteRoomtoneEmitter()
  enabled = false
  persistedToolState = nil
  mainEventName = ''
  roomtoneEnabled = false
  roomtoneEventName = ''
  roomtoneZ = 0.0
  nodeCount = 0
  nodeX, nodeY, nodeZ, nodeDepth, nodeAvgNormVol, nodeSourceCount = nil, nil, nil, nil, nil, nil
  kdNodes = nil
  runtimePrepass, runtimePrepassForestObj, runtimePrepassState = nil, nil, nil
  runtimePrepassMainEvent = nil
  runtimePrepassFrames, runtimePrepassStepTotal, runtimePrepassStepMax = 0, 0.0, 0.0
  pitchDensityInvAuto = 0.0
  pitchDensityInvOverride = nil
  emitterNodeId[1] = 0
  mainEmitterActive = false
  terrainBlock = nil
  globalParams = nil
  lastForestHeight = huge
end

-- Clears all runtime state through the public API.
local function clear()
  resetRuntime()
end

-- Resets runtime state when the mission ends.
local function onClientEndMission()
  resetRuntime()
end

-- Public interface.
M.setEnabled = setEnabled
M.setNodeCloud = setNodeCloud
M.setMainEvent = setMainEvent
M.setRoomtoneEnabled = setRoomtoneEnabled
M.setRoomtoneEvent = setRoomtoneEvent
M.setRoomtoneZ = setRoomtoneZ
M.setPitchDensityInv = setPitchDensityInv
M.getEmitterNodeIds = getEmitterNodeIds
M.getMainEmitterDebugState = getMainEmitterDebugState
M.clearMainAudio = clearMainAudio
M.clear = clear
M.setPersistedToolState = setPersistedToolState
M.getPersistedToolState = getPersistedToolState

M.onUpdate = onUpdate
M.onClientCustomObjectSpawning = onClientCustomObjectSpawning
M.onClientEndMission = onClientEndMission
M.onEditorBeforeSaveLevel = onEditorBeforeSaveLevel
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M