-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- this extension draws the debug representation of paths

local M = {}

local defaultSplineSmoothing = 0.5
local paths = {}

-- Temporal Bézier families. 'motion' retimes position, 'rotMotion' retimes the
-- whole orientation, and the three axis families retime one Euler axis each so
-- a pan can hold while the tilt keeps easing.
M.motionPrefixes = { 'motion', 'rotMotion', 'yawMotion', 'pitchMotion', 'rollMotion' }
M.transformChannels = { 'posX', 'posY', 'posZ', 'yaw', 'pitch', 'roll', 'fov' }

local function cubicBezier(a, b, t)
  local inv = 1 - t
  return 3 * inv * inv * t * a + 3 * inv * t * t * b + t * t * t
end

local function cubicBezierDeriv(a, b, t)
  local inv = 1 - t
  return 3 * inv * inv * a + 6 * inv * t * (b - a) + 3 * t * t * (1 - b)
end

-- Inverse of a monotonic cubic Bézier x(t) = cubicBezier(a, b, t) on [0, 1].
-- Exact at the endpoints so adjacent track segments meet at the key value; a
-- 12-step bisection stops ~2^-12 short and shows up as a one-frame facing pop.
local function invertCubicBezier(a, b, u)
  u = clamp(u, 0, 1)
  if u <= 0 then return 0 end
  if u >= 1 then return 1 end
  local x = u
  for _ = 1, 8 do
    local f = cubicBezier(a, b, x) - u
    if math.abs(f) < 1e-12 then break end
    local d = cubicBezierDeriv(a, b, x)
    if math.abs(d) < 1e-12 then break end
    x = clamp(x - f / d, 0, 1)
  end
  return x
end

local function keyBezierProgress(u, fromKey, toKey)
  u = clamp(u, 0, 1)
  local outTime = clamp(tonumber(fromKey.timeOut) or (1 / 3), 0.02, 0.96)
  local inTime = clamp(tonumber(toKey.timeIn) or (1 / 3), 0.02, 0.96)
  if outTime + inTime > 0.98 then
    local scale = 0.98 / (outTime + inTime)
    outTime, inTime = outTime * scale, inTime * scale
  end
  -- Transform tracks allow signed manual tangents and intentional overshoot.
  -- Automatic smoothing remains shape-preserving; only authored handles can leave
  -- the segment's value range.
  local outProgress = outTime * clamp(tonumber(fromKey.slopeOut) or 1, -50, 50)
  local inProgress = inTime * clamp(tonumber(toKey.slopeIn) or 1, -50, 50)
  if u <= 0 then return 0 end
  if u >= 1 then return 1 end
  local curveT = invertCubicBezier(outTime, 1 - inTime, u)
  return cubicBezier(outProgress, 1 - inProgress, curveT)
end

local function loopDuration(path)
  if not (path and path.looped) then return 0 end
  local d = tonumber(path.loopTime)
  if d == nil then return 2 end
  return math.max(0, d)
end

local function shortestDegDelta(fromV, toV)
  local d = (toV or 0) - (fromV or 0)
  while d > 180 do d = d - 360 end
  while d < -180 do d = d + 360 end
  return d
end

-- A cut is a hard step: up to and including T only keys at or before T play (the
-- outgoing shot's last frame); after T only keys strictly after T play. Windows
-- are built only when the path has cuts.
local function shotWindow(keys, t, cuts)
  local lo, hi
  for _, c in ipairs(cuts) do
    if c < t then lo = c
    else hi = c; break end
  end
  local out = {}
  for _, k in ipairs(keys) do
    local kt = k.t or 0
    if (not lo or kt > lo) and (not hi or kt <= hi) then
      out[#out + 1] = k
    end
  end
  return out
end

local function evalTransformTrack(keys, t, wrap, cuts)
  if type(keys) ~= 'table' or #keys == 0 or t == nil then return nil end
  local window = (cuts and #cuts > 0) and shotWindow(keys, t, cuts) or keys
  if #window == 0 then return nil end
  if t <= window[1].t then return window[1].v end
  local last = window[#window]
  local dur = wrap and tonumber(wrap.duration)
  -- Wrap is last-marker → first, not last-key → first. A key sitting in the
  -- loop window would otherwise start this channel's wrap later than the others.
  -- The join still lands on the path's first key, not the first key of this shot.
  local fromT = wrap and wrap.fromT
  if fromT == nil then fromT = last.t end
  local toKey = keys[1]
  if dur and dur > 1e-6 and #keys >= 2 and t >= fromT then
    local fromKey = last
    for i = #window, 1, -1 do
      if (window[i].t or 0) <= fromT + 1e-3 then fromKey = window[i]; break end
    end
    local u = (t - fromT) / dur
    if u <= 0 then return fromKey.v end
    if u >= 1 then return toKey.v end
    local dv = wrap.unwrapDeg and shortestDegDelta(fromKey.v, toKey.v) or ((toKey.v or 0) - (fromKey.v or 0))
    return fromKey.v + dv * keyBezierProgress(u, fromKey, toKey)
  end
  if t >= last.t then return last.v end
  local i = 1
  while i < #window and window[i + 1].t < t do i = i + 1 end
  local a, b = window[i], window[i + 1]
  local dt = (b.t or 0) - (a.t or 0)
  if dt <= 1e-6 then return b.v end
  local u = (t - a.t) / dt
  return a.v + ((b.v or 0) - (a.v or 0)) * keyBezierProgress(u, a, b)
end

local function cloneTransformTracks(tracks)
  if type(tracks) ~= 'table' then return nil end
  local out = {}
  for _, name in ipairs(M.transformChannels) do
    local src = tracks[name]
    if type(src) == 'table' then
      local list = {}
      for i, k in ipairs(src) do
        list[i] = {
          t = k.t, v = k.v,
          slopeIn = k.slopeIn, slopeOut = k.slopeOut,
          timeIn = k.timeIn, timeOut = k.timeOut,
        }
      end
      out[name] = list
    end
  end
  return out
end

local function cutTimes(path)
  local markers = path and path.markers
  if not markers then return nil end
  local cuts
  for i = 1, #markers - 1 do
    if markers[i].cut then
      cuts = cuts or {}
      cuts[#cuts + 1] = markers[i].time or 0
    end
  end
  return cuts
end

-- Sample independent Position / Facing / FOV tracks. Nil if the path has none.
local function evalTransform(path, t)
  local tracks = path and path.transformTracks
  if type(tracks) ~= 'table' then return nil end
  local wrapDur = loopDuration(path)
  local cuts = cutTimes(path)
  local ev = {}
  local any = false
  for _, name in ipairs(M.transformChannels) do
    local wrap = wrapDur > 1e-6 and {
      duration = wrapDur,
      fromT = path.markers and path.markers[#path.markers] and path.markers[#path.markers].time,
      unwrapDeg = (name == 'yaw' or name == 'roll'),
    } or nil
    local v = evalTransformTrack(tracks[name], t, wrap, cuts)
    ev[name] = v
    if v ~= nil then any = true end
  end
  if not any then return nil end
  return ev
end

M.evalTransformTrack = evalTransformTrack
M.evalTransform = evalTransform
M.cloneTransformTracks = cloneTransformTracks
M.invertCubicBezier = invertCubicBezier
M.loopDuration = loopDuration

local function getNewId()
  local id = 1

  while true do
    local foundId
    for _, path in ipairs(paths) do
      if path.id == id then
        foundId = true
      end
    end
    if not foundId then return id end
    id = id + 1
  end
end

local function getUniquePathName(name)
  local names = {}
  for _, path in ipairs(paths) do
    names[path.name] = true
  end

  local testName = name
  local nameCounter = 1
  while names[testName] do
    testName = name .. nameCounter
    nameCounter = nameCounter + 1
  end
  return testName
end

local function getMarkerIds(path, idx)
  local markerCount = #path.markers
  local index1 = math.max(idx - 1, 1)
  local index2 = idx
  local index3 = math.min(idx + 1, markerCount)
  local index4 = math.min(idx + 2, markerCount)
  if path.looped then
    index1 = ((idx - 2) % markerCount) + 1
    index2 = ((idx - 1) % markerCount) + 1
    index3 = ((idx) % markerCount) + 1
    index4 = ((idx + 1) % markerCount) + 1
  end
  if path.markers[index1].cut then index1 = index2 end
  if path.markers[index3].cut then index4 = index3 end

  return index1, index2, index3, index4
end

local function addPath(path)
  path.id = getNewId()
  table.insert(paths, path)
end

local function createPath(name)
  addPath({name = name, markers = {}, manualFov = true, dirty = true})
  return paths[#paths]
end

local function deletePath(path)
  local deletionIndex
  for i, p in ipairs(paths) do
    if p.name == path.name then
      deletionIndex = i
      break
    end
  end

  if deletionIndex then
    table.remove(paths, deletionIndex)
  end
end

local function getPaths()
  return paths
end

local function getEndIdx(path)
  if path.looped then
    return #path.markers
  else
    return #path.markers - 1
  end
end

local function savePath(cameraPath, filename)
  local pathCopy = deepcopy(cameraPath)
  for index, marker in ipairs(pathCopy.markers) do
    marker.pos = {x = marker.pos.x, y = marker.pos.y, z = marker.pos.z}
    marker.rot = {x = marker.rot.x, y = marker.rot.y, z = marker.rot.z, w = marker.rot.w}
    marker.fov = marker.fov or 60
    marker.trackPosition = marker.trackPosition or false
    marker.attachToVehicle = marker.attachToVehicle or false
    if not marker.attachToVehicle then marker.attachToVehicle = nil end
    if marker.trackOffset then
      marker.trackOffset = {
        x = marker.trackOffset.x or 0,
        y = marker.trackOffset.y or 0,
        z = marker.trackOffset.z or 0,
      }
      if marker.trackOffset.x == 0 and marker.trackOffset.y == 0 and marker.trackOffset.z == 0 then
        marker.trackOffset = nil -- keep files tidy when unused
      end
    end
    if marker.positionSmooth == defaultSplineSmoothing then
      marker.positionSmooth = nil
    end
    for _, prefix in ipairs(M.motionPrefixes) do
      if marker[prefix .. 'In'] == 1 then marker[prefix .. 'In'] = nil end
      if marker[prefix .. 'Out'] == 1 then marker[prefix .. 'Out'] = nil end
      local inTime, outTime = marker[prefix .. 'InTime'], marker[prefix .. 'OutTime']
      if inTime and math.abs(inTime - (1 / 3)) < 1e-6 then marker[prefix .. 'InTime'] = nil end
      if outTime and math.abs(outTime - (1 / 3)) < 1e-6 then marker[prefix .. 'OutTime'] = nil end
    end
    if marker.bullettime == 1 then
      marker.bullettime = nil
    end
  end

  -- Filter out things that dont have to be saved
  pathCopy.filename = nil
  pathCopy.dirty = nil
  pathCopy.id = nil

  pathCopy.version = "6"
  pathCopy.manualFov = pathCopy.manualFov or false
  pathCopy.looped = pathCopy.looped or false
  if pathCopy.transformTracks then
    pathCopy.transformTracks = cloneTransformTracks(pathCopy.transformTracks)
  end
  if not pathCopy.advancedMode then pathCopy.advancedMode = nil end

  jsonWriteFile(filename, pathCopy, true)
  cameraPath.filename = filename
  cameraPath.dirty = false
end

local function loadPath(pathFileName)
  if not pathFileName then
    return
  end
  for _, path in ipairs(paths) do
    if path.filename == pathFileName then
      return path
    end
  end

  local pathJsonObj = jsonReadFile(pathFileName)
  if not pathJsonObj then
    log('E', 'core_paths.loadPath', 'unable to find path file: ' .. tostring(pathFileName))
    return
  end

  local res = { markers = {}}

  res.looped = pathJsonObj.looped or false
  res.loopTime = pathJsonObj.loopTime

  -- extract all its markers
  for i, markerData in ipairs(pathJsonObj.markers) do
    local marker = {
      pos = vec3(markerData.pos.x, markerData.pos.y, markerData.pos.z),
      rot = quat(markerData.rot.x, markerData.rot.y, markerData.rot.z, markerData.rot.w),
      time = markerData.time,
      fov = markerData.fov,
      trackPosition = markerData.trackPosition,
      attachToVehicle = markerData.attachToVehicle or false,
      trackOffset = markerData.trackOffset and {
        x = markerData.trackOffset.x or 0,
        y = markerData.trackOffset.y or 0,
        z = markerData.trackOffset.z or 0,
      } or nil,
      positionSmooth = markerData.positionSmooth or defaultSplineSmoothing,
      bullettime = markerData.bullettime or 1,
      cut = markerData.cut,
      movingStart = markerData.movingStart,
      movingEnd = markerData.movingEnd
    }
    for _, prefix in ipairs(M.motionPrefixes) do
      for _, key in ipairs({ 'In', 'Out', 'InTime', 'OutTime' }) do
        marker[prefix .. key] = markerData[prefix .. key]
      end
    end
    if marker.movingStart == nil then marker.movingStart = true end
    if marker.movingEnd == nil then marker.movingEnd = true end

    table.insert(res.markers, marker)
  end
  -- fix up the rotations
  local markerCount = tableSize(pathJsonObj.markers)
  for i = 2, markerCount do
    if res.markers[i] then
      if res.markers[i].rot:dot(res.markers[i - 1].rot) < 0 then
        res.markers[i].rot = -res.markers[i].rot
      end
    end
  end
  res.rotFixId = markerCount

  res.filename = pathFileName
  res.replay = pathJsonObj.replay
  res.name = pathJsonObj.name
  res.advancedMode = pathJsonObj.advancedMode == true
  if pathJsonObj.transformTracks then
    res.transformTracks = cloneTransformTracks(pathJsonObj.transformTracks)
  end
  addPath(res)
  return res
end

local function onExtensionLoaded()
end

local function onSerialize()
  return {
    paths = deepcopy(paths)
  }
end

local function onDeserialized(data)
  paths = deepcopy(data.paths)
end

local function onClientStartMission()
  local camPathFolder = (path.split(getMissionFilename()) or '') .. "camPaths"
  local camPathFiles = FS:findFiles(camPathFolder, "*.camPath.json", 0, true, true)

  paths = {}
  local counter = 0
  local namesCounter = {}
  for _, filename in pairs(camPathFiles) do
    local path = loadPath(filename)

    if not namesCounter[path.name] then namesCounter[path.name] = 0 end
    namesCounter[path.name] = namesCounter[path.name] + 1
    if namesCounter[path.name] > 1 then
      path.name = path.name .. "(" .. namesCounter[path.name] .. ")"
    end

    counter = counter + 1
  end

  if counter > 0 then
    log('D', 'core_paths.loadPath', "" .. counter .. " Camera Path(s) loaded.")
  end
end

local function getPath_Deprecated(pathName)
  -- find any path (chooses first)
  if not pathName then
    local objNames = scenetree.findClassObjects('SimPath')
    if not objNames or #objNames == 0 then
      -- if not SimPath on level return
      --log('E', 'core_paths.getPath', 'unable to find any path')
      return
    end
    pathName = objNames[1]
  end
  local pathObj = scenetree.findObject(pathName)
  if not pathObj then
    log('E', 'core_paths.getPath', 'unable to find path: ' .. tostring(pathName))
    return
  end

  local res = { markers = {}}

  res.looped = false
  if pathObj.looped then
    res.looped = pathObj.looped == '1'
  end

  -- extract all its markers
  --pathObj:sortMarkers()
  res.nodeCount = pathObj:size()
  for i = 0, res.nodeCount do
    local markerId = pathObj:idAt(i)
    if markerId >= 0 then
      local marker = scenetree.findObjectById(markerId)
      if marker then
        local d = {
          pos = vec3(marker:getPosition()),
          rot = quat(marker:getRotation()),
          time = marker.timeToNext or marker.seconds,
          positionSmooth = marker.positionSmooth
        }
        res.markers[marker.seqNum + 1] = d
      end
    end
  end
  -- fix up the rotations
  for i = 2, res.nodeCount - 1 do
    if res.markers[i].rot:dot(res.markers[i - 1].rot) < 0 then
      res.markers[i].rot = -res.markers[i].rot
    end
  end

  return res
end

local function playPath(path, offset, initData)
  local initData = initData or {}
  initData.useJsonVersion = true
  initData.hasIntro = true
  initData.path = path
  initData.offset = offset or 0
  initData.reset = initData.reset or (function(this) end)
  initData.getNextPath = initData.getNextPath or (function(this) return initData.path end)

  core_camera.setByName(0, "path", false, initData)
end

local function stopCurrentPath()
  -- switch to free cam
  if core_camera.getActiveCamName() == "path" then
    commands.setFreeCamera()
  end
end

-- callbacks
M.onClientStartMission = onClientStartMission
M.onExtensionLoaded = onExtensionLoaded
M.loadPath = loadPath
M.savePath = savePath
M.getPaths = getPaths
M.addPath = addPath
M.createPath = createPath
M.deletePath = deletePath
M.getUniquePathName = getUniquePathName
M.getMarkerIds = getMarkerIds
M.getEndIdx = getEndIdx
M.playPath = playPath
M.stopCurrentPath = stopCurrentPath

M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.getPath = getPath_Deprecated

return M
