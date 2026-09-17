-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

local defaultCheckWindowBehindMeters = 80
local defaultCheckWindowAheadMeters = 120
local defaultMissWindowBehindMeters = 120

local function roundTime(time)
  if not time then return nil end
  return math.floor(time * 10 + 0.5) / 10
end

local function splitIsFinish(splitData)
  return splitData and splitData.pathnodeType == 'finish'
end

local function raceVehicleState(raceData, vehId)
  if not raceData or not vehId or not raceData.states then return nil end
  return raceData.states[vehId]
end

local function raceStageTime(raceData, vehId)
  local state = raceVehicleState(raceData, vehId)
  if state and state.complete and state.historicTimes and state.historicTimes[#state.historicTimes] then
    return state.historicTimes[#state.historicTimes].endTime
  end
  return raceData and raceData.time or nil
end

local function ensureFootprintStorage(observer)
  if observer.previousCorners then return end
  observer.previousCorners = {vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3()}
  observer.currentCorners = {vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3()}
  observer.oobbCenter = vec3()
  observer.oobbHalfAxis0 = vec3()
  observer.oobbHalfAxis1 = vec3()
  observer.oobbHalfAxis2 = vec3()
  observer.splitPlanePos = vec3()
  observer.splitPlaneNormal = vec3()
  observer.rayDirScratch = vec3()
  observer.cornerScratch = vec3()
end

local function copyCorners(dst, src)
  for i = 1, #src do
    dst[i]:set(src[i])
  end
end

local function setFootprintCorners(observer, vehId, corners)
  if not vehId then return false end
  if be.getObjectOOBBIsInitialized and not be:getObjectOOBBIsInitialized(vehId) then return false end

  local veh = scenetree.findObjectById(vehId)
  local oobb = veh and veh:getSpawnWorldOOBB()
  if oobb and oobb.getPoint then
    for i = 1, 8 do
      corners[i]:set(oobb:getPoint(i - 1))
    end
    return true
  end

  observer.oobbCenter:set(be:getObjectOOBBCenterXYZ(vehId))
  observer.oobbHalfAxis0:set(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
  observer.oobbHalfAxis1:set(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
  observer.oobbHalfAxis2:set(be:getObjectOOBBHalfAxisXYZ(vehId, 2))

  local center = observer.oobbCenter
  local halfAxis0 = observer.oobbHalfAxis0
  local halfAxis1 = observer.oobbHalfAxis1
  local halfAxis2 = observer.oobbHalfAxis2
  local scratch = observer.cornerScratch

  scratch:set(center); scratch:setSub(halfAxis1); scratch:setAdd(halfAxis0); scratch:setSub(halfAxis2); corners[1]:set(scratch)
  scratch:set(center); scratch:setSub(halfAxis1); scratch:setSub(halfAxis0); scratch:setSub(halfAxis2); corners[2]:set(scratch)
  scratch:set(center); scratch:setAdd(halfAxis1); scratch:setAdd(halfAxis0); scratch:setSub(halfAxis2); corners[3]:set(scratch)
  scratch:set(center); scratch:setAdd(halfAxis1); scratch:setSub(halfAxis0); scratch:setSub(halfAxis2); corners[4]:set(scratch)
  scratch:set(center); scratch:setSub(halfAxis1); scratch:setAdd(halfAxis0); scratch:setAdd(halfAxis2); corners[5]:set(scratch)
  scratch:set(center); scratch:setSub(halfAxis1); scratch:setSub(halfAxis0); scratch:setAdd(halfAxis2); corners[6]:set(scratch)
  scratch:set(center); scratch:setAdd(halfAxis1); scratch:setAdd(halfAxis0); scratch:setAdd(halfAxis2); corners[7]:set(scratch)
  scratch:set(center); scratch:setAdd(halfAxis1); scratch:setSub(halfAxis0); scratch:setAdd(halfAxis2); corners[8]:set(scratch)
  return true
end

local function splitHasPlane(splitData)
  return splitData
    and splitData.pathnodePosX
    and splitData.pathnodePosY
    and splitData.pathnodePosZ
    and splitData.pathnodeRadius
end

local function intersectSplitPlane(observer, splitData)
  if not splitHasPlane(splitData) then return false end

  observer.splitPlanePos:set(splitData.pathnodePosX, splitData.pathnodePosY, splitData.pathnodePosZ)
  if splitData.pathnodeHasNormal then
    observer.splitPlaneNormal:set(splitData.pathnodeNormalX or 0, splitData.pathnodeNormalY or 0, splitData.pathnodeNormalZ or 0)
  end

  local minT = math.huge
  local rDir = observer.rayDirScratch
  for i = 1, #observer.previousCorners do
    local rPos = observer.previousCorners[i]
    rDir:setSub2(observer.currentCorners[i], observer.previousCorners[i])
    local len = rDir:length()
    if len > 0 then
      len = 1 / len
      rDir:normalize()
      if splitData.pathnodeHasNormal then
        local sMin, sMax = intersectsRay_Sphere(rPos, rDir, observer.splitPlanePos, splitData.pathnodeRadius)
        sMin = sMin * len
        sMax = sMax * len
        if sMin <= 0 and sMax >= 1 then
          local t = intersectsRay_Plane(rPos, rDir, observer.splitPlanePos, observer.splitPlaneNormal)
          t = t * len
          if t <= 1 and t >= 0 then
            minT = math.min(t, minT)
          end
        end
      else
        local t = intersectsRay_Sphere(rPos, rDir, observer.splitPlanePos, splitData.pathnodeRadius)
        t = t * len
        if t <= 1 and t >= 0 then
          minT = math.min(t, minT)
        end
      end
    end
  end

  return minT <= 1, minT
end

function C:init(options)
  options = options or {}
  self.authorityMode = options.authorityMode or 'shadow'
  self.checkWindowBehindMeters = options.checkWindowBehindMeters or defaultCheckWindowBehindMeters
  self.checkWindowAheadMeters = options.checkWindowAheadMeters or defaultCheckWindowAheadMeters
  self.missWindowBehindMeters = options.missWindowBehindMeters or defaultMissWindowBehindMeters
  ensureFootprintStorage(self)
  self:reset()
end

function C:setAuthorityMode(mode)
  self.authorityMode = mode == 'tracker' and 'tracker' or 'shadow'
end

function C:getAuthorityMode()
  return self.authorityMode
end

function C:reset()
  ensureFootprintStorage(self)
  self.previousDistFromStart = nil
  self.observationStartIndex = 1
  self.hasPreviousFootprint = false
  self.stageComplete = false
  self.stageFinishTime = nil
  self.lastStageTime = nil
  self.lastStageTimeSample = nil
  self.lastTrackerState = nil
  self.lastRaceState = nil
  self.updateSerial = 0
end

function C:resetFootprint()
  self.hasPreviousFootprint = false
end

function C:resetAfterTeleport()
  self.previousDistFromStart = nil
  self.hasPreviousFootprint = false
end

local function isInCheckWindow(observer, pathnodeData, currentDistFromStart)
  if not currentDistFromStart or not pathnodeData or not pathnodeData.distFromStart then return true end
  return pathnodeData.distFromStart >= currentDistFromStart - observer.checkWindowBehindMeters
    and pathnodeData.distFromStart <= currentDistFromStart + observer.checkWindowAheadMeters
end

local function isBehindMissWindow(observer, pathnodeData, currentDistFromStart)
  if not currentDistFromStart or not pathnodeData or not pathnodeData.distFromStart then return false end
  return pathnodeData.distFromStart < currentDistFromStart - observer.missWindowBehindMeters
end

local function updateObservationStartIndex(observer, pathnodeObservationList, currentDistFromStart)
  if not currentDistFromStart then return nil, nil end

  local windowStartDist = currentDistFromStart - observer.missWindowBehindMeters
  local windowEndDist = currentDistFromStart + observer.checkWindowAheadMeters
  local idx = observer.observationStartIndex or 1

  while idx > 1 do
    local prevData = pathnodeObservationList[idx - 1]
    if not prevData or not prevData.distFromStart or prevData.distFromStart < windowStartDist then break end
    idx = idx - 1
  end

  while idx <= #pathnodeObservationList do
    local pathnodeData = pathnodeObservationList[idx]
    if not pathnodeData or not pathnodeData.distFromStart then break end
    if pathnodeData.distFromStart >= windowStartDist then break end
    if not pathnodeData.trackerObserved and not pathnodeData.trackerMissed then
      pathnodeData.trackerMissed = true
      pathnodeData.trackerMissedUpdateSerial = observer.updateSerial
      if pathnodeData.isSplitTiming then
        pathnodeData.missingReason = 'missedWindow'
      end
    end
    idx = idx + 1
  end

  observer.observationStartIndex = idx
  return idx, windowEndDist
end

function C:recordRaceSplit(splitData, time)
  if not splitData then return end
  splitData.time = splitData.time or time
  splitData.source = splitData.source or 'race'
end

function C:update(context)
  context = context or {}
  self.updateSerial = self.updateSerial + 1
  local tracker = context.tracker
  local pathnodeObservationList = context.pathnodeObservationList or context.splitList
  local vehId = context.vehId
  local raceData = context.raceData
  local stageTimeSample = context.stageTime or raceStageTime(raceData, vehId)
  local stageFrameStartTime = context.stageFrameStartTime
  local stageFrameDt = context.stageFrameDt or 0
  local stageTimingState = context.stageTimingState

  self.lastTrackerState = tracker
  self.lastStageTimeSample = stageTimeSample
  self.lastStageTime = stageTimeSample or self.stageFinishTime
  local raceState = raceVehicleState(raceData, vehId)
  self.lastRaceState = raceState and {
    active = raceState.active,
    complete = raceState.complete,
  } or nil

  if not pathnodeObservationList or not setFootprintCorners(self, vehId, self.currentCorners) then
    return
  end

  if not self.hasPreviousFootprint then
    copyCorners(self.previousCorners, self.currentCorners)
    self.hasPreviousFootprint = true
    return
  end

  local currentDistFromStart = tracker and tracker.distFromStart or nil
  self.previousDistFromStart = currentDistFromStart
  local startIdx, windowEndDist = updateObservationStartIndex(self, pathnodeObservationList, currentDistFromStart)
  if not startIdx then
    copyCorners(self.previousCorners, self.currentCorners)
    return
  end

  for i = startIdx, #pathnodeObservationList do
    local pathnodeData = pathnodeObservationList[i]
    if pathnodeData.distFromStart and pathnodeData.distFromStart > windowEndDist then break end
    if not pathnodeData.trackerObserved and isInCheckWindow(self, pathnodeData, currentDistFromStart) then
      local crossed, crossingT = intersectSplitPlane(self, pathnodeData)
      if crossed then
        local observedTime = self.lastStageTime
        if stageFrameStartTime and crossingT and stageFrameDt > 0 then
          observedTime = stageFrameStartTime + crossingT * stageFrameDt
        end
        pathnodeData.trackerObserved = true
        pathnodeData.trackerMissed = nil
        pathnodeData.trackerMissedUpdateSerial = nil
        pathnodeData.trackerObservedState = tracker and tracker.state or nil
        pathnodeData.trackerCrossingMode = pathnodeData.pathnodeHasNormal and 'plane' or 'sphere'
        pathnodeData.trackerCrossingT = crossingT
        pathnodeData.trackerObservedUpdateSerial = self.updateSerial
        pathnodeData.trackerTime = observedTime

        if tracker and tracker.state == 'offRoute' then
          pathnodeData.missingReason = 'offRoute'
          if stageTimingState and pathnodeData.isSplitTiming and not splitIsFinish(pathnodeData) then
            stageTimingState:markSplitMissing(pathnodeData, 'offRoute')
          end
        else
          pathnodeData.missingReason = nil
          if stageTimingState and pathnodeData.isSplitTiming then
            stageTimingState:recordSplit(pathnodeData, observedTime, 'tracker')
          else
            pathnodeData.time = pathnodeData.time or observedTime
            pathnodeData.source = pathnodeData.source or 'tracker'
          end
        end

        if splitIsFinish(pathnodeData) then
          self.stageComplete = true
          self.stageFinishTime = observedTime
          if stageTimingState then
            stageTimingState:recordSplit(pathnodeData, observedTime, 'tracker')
            stageTimingState:completeAt(observedTime)
          end
          pathnodeData.trackerTime = pathnodeData.trackerTime or self.stageFinishTime
          pathnodeData.time = pathnodeData.time or self.stageFinishTime
        end
      end
    elseif not pathnodeData.trackerObserved and not pathnodeData.trackerMissed and isBehindMissWindow(self, pathnodeData, currentDistFromStart) then
      pathnodeData.trackerMissed = true
      pathnodeData.trackerMissedUpdateSerial = self.updateSerial
      if pathnodeData.isSplitTiming then
        pathnodeData.missingReason = 'missedWindow'
        if stageTimingState then
          stageTimingState:markSplitMissing(pathnodeData, 'missedWindow')
        end
      end
    end
  end

  copyCorners(self.previousCorners, self.currentCorners)
end

function C:getStageTime()
  if self.stageFinishTime then return self.stageFinishTime end
  return self.lastStageTime
end

function C:getState()
  return {
    authorityMode = self.authorityMode,
    stageComplete = self.stageComplete,
    stageFinishTime = self.stageFinishTime,
    currentStageTime = self:getStageTime(),
    currentStageTimeRounded = roundTime(self:getStageTime()),
    trackerState = self.lastTrackerState and self.lastTrackerState.state or nil,
    raceActive = self.lastRaceState and self.lastRaceState.active or false,
    raceComplete = self.lastRaceState and self.lastRaceState.complete or false,
  }
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
