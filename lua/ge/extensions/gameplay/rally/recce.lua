-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Recce (reconnaissance) - high-level manager for recce recordings
--
-- This module coordinates loading and processing of recce recording files:
-- 1. Driveline: A series of timestamped position/orientation points recorded during a recce run
--    - Loaded via recce/drivelineRecording.lua
--    - Returns a PointList object for downstream processing
--
-- 2. Cuts: Waypoint markers where the co-driver made voice recordings during the recce
--    - Loaded via recce/cutsRecording.lua
--    - Includes associated transcript data from speech-to-text processing
--
-- The Recce object is primarily used in the worldEditor's Rally Editor to:
-- - Import recce recordings and visualize them
-- - Generate a snaproad (path) from the driveline for placing pacenotes
-- - Convert cuts and transcripts into structured pacenotes for the notebook
--
-- Other systems can load driveline data directly without creating a Recce instance:
--   local drivelineRecording = require('/lua/ge/extensions/gameplay/rally/recce/drivelineRecording')
--   local pointList = drivelineRecording.load(missionDir)

local C = {}
local logTag = ''

local cc = require('/lua/ge/extensions/gameplay/rally/util/colors')
local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local waypointTypes = require('/lua/ge/extensions/gameplay/rally/notebook/waypointTypes')
-- local RecceSettings = require('/lua/ge/extensions/gameplay/rally/recceSettings')
local Snaproad = require('/lua/ge/extensions/gameplay/rally/snaproad')
local drivelineRecording = require('/lua/ge/extensions/gameplay/rally/recce/drivelineRecording')
local cutsRecording = require('/lua/ge/extensions/gameplay/rally/recce/cutsRecording')

function C:init(missionDir)
  self.missionDir = missionDir
  self._loadedDrivelineAndCuts = false
  self.driveline = nil
  self.cuts = nil
  self:_resetState()
  -- self.settings = RecceSettings()
  -- self.settings:load()
end

function C:drivelineAndCutsLoaded()
  return self._loadedDrivelineAndCuts
end

function C:_resetState()
  self.driveline = nil
  self.cuts = nil
end

function C:loadDrivelineAndCuts()
  -- self:_resetState()
  -- self.settings:load()
  local drivelineLoaded = self:loadDriveline()
  local cutsLoaded = self:loadCuts()

  if not drivelineLoaded then
    log('W', logTag, 'recce driveline not found - this is expected for new recordings')
  end
  if not cutsLoaded then
    log('W', logTag, 'recce cuts not found - this is expected for new recordings')
  end

  -- Only consider it fully loaded if both driveline and cuts exist
  self._loadedDrivelineAndCuts = drivelineLoaded and cutsLoaded

  -- Return true if at least the basic structure can be set up (even with empty data)
  return true
end

function C:loadCuts()
  self.cuts = cutsRecording.load(self.missionDir)
  return self.cuts and #self.cuts > 0
end

function C:loadDriveline()
  self.driveline = drivelineRecording.load(self.missionDir)
  if not self.driveline then
    log('W', logTag, 'recce driveline file not found - this is expected for new recordings')
    return false
  end
  return true
end

function C:drawDebugRecce(drawLabels, mouseInfo)
  if not self.driveline then return end
  self.driveline:drawDebug(drawLabels)
  self:drawDebugCuts()
end

function C:drawDebugCuts()
  if not self.cuts then return end

  for _,point in ipairs(self.cuts) do
    local pos = point.pos
    local quat = point.quat
    local txt = point.transcript.text
    self:drawLittleCar(pos, quat, txt)
  end
end

function C:drawLittleCar(pos, quat, txt)
  local h = 1.6
  local w = 1.8
  local l = 4.4

  local forwardVector = vec3(0,1,0)
  local rotatedForwardVector = quat * forwardVector * (l/2) -- assume pos is the center of car so divide length by 2
  local frontOfCar = pos + rotatedForwardVector
  local backOfCar = pos - rotatedForwardVector

  local raise = vec3(0,0,h/2)
  frontOfCar = frontOfCar + raise
  backOfCar = backOfCar + raise

  local wheelPositions = {
    {0.5, vec3(-(w/2*0.9),   l/2 * 0.6,  0.4)}, -- Front left
    {0.5, vec3( (w/2*0.9),   l/2 * 0.6,  0.4)}, -- Front right
    {0.6, vec3(-(w/2*1.1), -(l/2 * 0.6), 0.4)}, -- Rear left
    {0.6, vec3( (w/2*1.1), -(l/2 * 0.6), 0.4)}, -- Rear right
  }

  -- Function to rotate and translate a local position to a world position
  local function toWorldPosition(localPos)
    local rotatedPos = quat * localPos  -- Rotate by car's orientation
    return pos + rotatedPos            -- Translate to car's world position
  end

  -- Draw the wheels
  for _, wheelPos in ipairs(wheelPositions) do
    local worldWheelPos = toWorldPosition(wheelPos[2])
    debugDrawer:drawSphere(worldWheelPos, wheelPos[1], ColorF(0,0,0,1))
  end

  local clr_base = cc.clr_teal
  local clr = clr_base
  local textAlpha = 1.0
  local clr_text_fg = cc.clr_black
  local clr_text_bg = cc.clr_teal

  debugDrawer:drawSquarePrism(
    frontOfCar,
    backOfCar,
    Point2F(h*0.7, w*0.7), -- make the car look more aero
    Point2F(h, w),
    ColorF(clr[1], clr[2], clr[3], 1)
  )

  if txt then
    debugDrawer:drawTextAdvanced(
      backOfCar + vec3(0,0,h/2),
      String(txt),
      ColorF(clr_text_fg[1], clr_text_fg[2], clr_text_fg[3], textAlpha),
      true,
      false,
      ColorI(clr_text_bg[1]*255, clr_text_bg[2]*255, clr_text_bg[3]*255, textAlpha*255)
    )
  end
end

function C:createPacenotesData(notebook)
  if not self:drivelineAndCutsLoaded() then return end
  -- if not self.cuts then return end

  log('I', logTag, 'import pacenotes to notebook')

  local importIdent = notebook:nextImportIdent()
  local import_language = rallyUtil.default_codriver_language

  local snaproad = Snaproad(self)

  local pacenotes = {}
  local prevPacenote = nil
  local prevCePoint = nil
  local foundDup = false

  -- local cutCount = #self.cuts

  for i,cut in ipairs(self.cuts) do
    local note = cut.transcript.text
    local pos = cut.pos
    local radius = editor_rallyEditor.getPrefDefaultRadius()

    -- set the pacenote name
    local pacenoteNewId = notebook:getNextUniqueIdentifier()
    local name = "Pacenote "..pacenoteNewId
    if importIdent then
      name = "Import_"..importIdent.." " .. pacenoteNewId
    end

    -- set some metadata
    local metadata = {}
    -- if transcript.beamng_file then
    -- metadata['success'] = transcript.success
    -- metadata['beamng_file'] = transcript.beamng_file
    -- end

    local firstSnapPoint = snaproad:firstSnapPoint()
    local pointCe = nil
    local pointCs = nil
    local ceLoc = nil
    local csLoc = nil

    ceLoc = snaproad:closestSnapResult(pos, true)
    pointCe = ceLoc and ceLoc.nearestPoint or nil

    if pointCe and pointCe.id == firstSnapPoint.id then
      pointCe = snaproad:pointsForwards(pointCe, 3)
      pointCs = snaproad:pointsBackwards(pointCe, 1)
      ceLoc = snaproad:routeLocationForPoint(pointCe)
      csLoc = snaproad:routeLocationForPoint(pointCs)
    else
      local csLimits = {firstSnapPoint}
      if prevCePoint then
        table.insert(csLimits, prevCePoint)
      end
      csLoc = snaproad:distanceBackwardsResult(ceLoc and ceLoc.pos or pos, 2*radius, csLimits)
      pointCs = csLoc and csLoc.nearestPoint or nil
    end

    -- after we've determined the points, see if there is a dup.
    if prevCePoint and pointCe and pointCe.id == prevCePoint.id then
      foundDup = true
      if note and prevPacenote then
        local prevTxt = prevPacenote.notes[import_language].note

        local mergedTxt = nil

        if prevTxt then
          mergedTxt = prevTxt..' '..note
        else
          mergedTxt = note
        end

        prevPacenote.notes[import_language].note = mergedTxt
      end
    end

    local posCe = ceLoc and ceLoc.pos or (pointCe and pointCe.pos)
    local posCs = csLoc and csLoc.pos or (pointCs and pointCs.pos)
    if posCe and posCs then
      local normalCe = ceLoc and snaproad:normalForSnapResult(ceLoc) or vec3(0.0, 1.0, 0.0)
      local normalCs = csLoc and snaproad:normalForSnapResult(csLoc) or vec3(0.0, 1.0, 0.0)

      local pn = {
        name = name,
        notes = { [import_language] = {note = note}},
        metadata = metadata,
        oldId = pacenoteNewId,
        pacenoteWaypoints = {
          {
            name = "corner start",
            normal = {normalCs.x, normalCs.y, normalCs.z},
            oldId = notebook:getNextUniqueIdentifier(),
            pos = posCs,
            radius = radius,
            waypointType = waypointTypes.wpTypeCornerStart,
          },
          {
            name = "corner end",
            normal = {normalCe.x, normalCe.y, normalCe.z},
            oldId = notebook:getNextUniqueIdentifier(),
            pos = posCe,
            radius = radius,
            waypointType = waypointTypes.wpTypeCornerEnd,
          }
        }
      }

      if not foundDup then
        prevPacenote = pn
        prevCePoint = pointCe
        table.insert(pacenotes, pn)
      end
    end

    foundDup = false
  end

  return pacenotes
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end

